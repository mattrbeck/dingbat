# =============================================================================
# MP2K / M4A ("Sappy") sound-engine HLE  (included by gba.nim)
# =============================================================================
# Re-renders the GBA's common MP2K music mixer at the APU's 32768 Hz instead
# of the game's ~13 kHz FIFO stream. The engine is detected at runtime from
# its SoundInfo work area in RAM (no ROM signature — see "Runtime detection"
# below) and the SoundInfo struct is re-read at every mixer pass.
#
# EXPERIMENTAL and OFF BY DEFAULT (gba.mp2k_hle; "Improve audio quality" in
# both frontends). Not cycle-accurate. Shadow state is deliberately NOT
# serialized (save states are identical with the HLE on or off); every
# state/rollback load calls mp2k_state_loaded to rebuild it from emulated RAM.
#
# Provenance / license: this file is this project's own MIT-licensed code. No
# driver code is reproduced; it relies on interface facts about the
# "MusicPlayer2000" (M4A / "Sappy") driver — the layout of its RAM work area,
# its flag bits, the compressed-sample block format and the behaviour of its
# mixer — observed by running the driver in this emulator and cross-checked
# against public documentation:
#   * loveemu vgmdocs, "Summary of GBA Standard Sound Driver MusicPlayer2000":
#     https://loveemu.github.io/vgmdocs/Summary_of_GBA_Standard_Sound_Driver_MusicPlayer2000.html
#   * SoundInfo / SoundChannel / WaveData field names are the pret header
#     names for those fields; the byte offsets are what the driver reads and
#     writes at runtime.
#   * agbplay (ipatix, GPL — documentation only, no code) corroborates the
#     compressed block format.
#   * GBATEK — the DirectSound FIFO hardware sink we substitute for.
# The resampler kernel is this project's own; the kernel before commit
# 28be88c7 followed NanoBoyAdvance's (BSD-2-Clause since 2026-06).
#
# Design:
#   * SHADOW mode: the real mixer still runs; we consume the per-channel
#     envelope volumes it computes (on_frame) instead of reimplementing ADSR.
#   * Output lags the mixer pass by one frame to match the driver's
#     DirectSound double-buffering (render_sample).
#   * 8-bit PCM, looping, BDPCM ("compressed waveform") and every
#     channel.type mode-bit combination are mixed (TYPE_* table below).

const
  # ---- Runtime detection constants (mechanism: "Runtime detection" below) --
  # Every m4a build publishes a pointer to its SoundInfo work area at IWRAM
  # 0x03007FF0 (inside the 0x03007F00..FF block GBATEK reserves as system
  # space; the loveemu MP2K summary's RAM map shows the work area). The first
  # SoundInfo field, ident, is ID_NUMBER = 0x68736D53 ("Smsh" reversed) and
  # doubles as the lock word: SoundMain holds ID_NUMBER+1 for the whole pass
  # (sequencer, CGB update, PCM mixer) and restores it afterwards.
  MP2K_SOUNDINFO_PTR_ADDR = 0x03007FF0'u32   # IWRAM slot holding the SoundInfo pointer
  MP2K_IDENT_IDLE         = 0x68736D53'u32   # SoundInfo.ident = ID_NUMBER ("Smsh")
  MP2K_IDENT_LOCK         = 0x68736D54'u32   # ID_NUMBER+1: lock held while SoundMain mixes
  # VSyncOff parks ident at +10 (VSyncOn subtracts it back). A stock driver's
  # SoundMain refuses to run in that state, but modified vintages (Mother 3)
  # do their own V-blank DMA maintenance and run the whole engine parked, so
  # their lock dance is +10 <-> +11. Both forms are accepted everywhere; a
  # stock driver never mixes at +10, so the widening cannot mislearn from it.
  MP2K_IDENT_IDLE_VOFF    = 0x68736D5D'u32   # ID_NUMBER+10: idle, VSync off
  MP2K_IDENT_LOCK_VOFF    = 0x68736D5E'u32   # ID_NUMBER+11: locked, VSync off
  MP2K_PROBE_MAX_FAILS    = 8                # give up learning after this many mislearns
  MP2K_MAX_CHANNELS       = 12
  # Frames the learned hook may go silent before substitution steps aside
  # (mixer_live). A live SoundMain fires every V-blank, so the stale counter
  # oscillates 0..1; the grace tolerates lag-frame skipped passes.
  MP2K_HOOK_STALE_MAX     = 4'i32

  # SoundChannel field offsets (pret field names; see the header)
  SC_STATUS   = 0x00
  SC_TYPE     = 0x01
  SC_VOL_R    = 0x02
  SC_VOL_L    = 0x03
  SC_ATTACK   = 0x04   # ADSR attack rate (added to envelopeVolume per frame)
  SC_ENV_VOL {.used.} = 0x09
  SC_ENV_VR   = 0x0A   # envelopeVolumeRight
  SC_ENV_VL   = 0x0B   # envelopeVolumeLeft
  SC_COUNT    = 0x18   # count/ct: the note-on sample start offset while START
                       # is set; afterwards the source samples remaining until
                       # sample/loop end (position resync + resume: on_frame)
  SC_FREQ     = 0x20   # frequency (per-note playback rate, Hz)
  SC_WAVE     = 0x24   # wav pointer -> WaveData
  SC_SIZE     = 64

  # SoundInfo field offsets
  SI_MAGIC        = 0x00   # ident
  SI_DMA_COUNTER  = 0x04   # pcmDmaCounter: V-blanks left before the DMA restarts
                           # at pcmBuffer start (the V-blank handler reloads it
                           # from pcmDmaPeriod at 0)
  SI_REVERB       = 0x05   # reverb (0 = off)
  SI_MAX_CHANS    = 0x06   # maxChans
  SI_MASTER_VOL   = 0x07   # masterVolume
  SI_DMA_PERIOD   = 0x0B   # pcmDmaPeriod: pcmBuffer ring length in V-blank frames
  SI_SPV          = 0x10   # pcmSamplesPerVBlank
  SI_PCM_RATE     = 0x14   # pcmFreq (DirectSound base sample rate)
  SI_CHANNELS     = 0x50   # chans[MAX_DIRECTSOUND_CHANNELS]
  SI_PCM_BUFFER {.used.} = 0x350  # s8 pcmBuffer[PCM_DMA_BUF_SIZE*2] — follows the 12
                           # 64-byte chans slots (0x50 + 12*64); the DMA1SAD
                           # every standard driver programs

  # channel.type bits (the sequencer copies the instrument's type byte verbatim
  # into SoundChannel.type at note-on). Canonical semantics — the mixer code
  # below only cross-references this table:
  #   TYPE_CGB (0x07): nonzero low bits select a CGB (PSG) channel 1-4; such
  #     notes go to the CgbChans array and never reach a DirectSound
  #     SoundChannel, so a DirectSound channel always has these bits clear.
  #   TYPE_FIX (0x08): fixed-rate playback — the phase step is forced to 1.0
  #     source sample per output sample, i.e. the sample plays at exactly
  #     SoundInfo.pcmFreq with channel.frequency ignored.
  #   TYPE_REV (0x10): reversed playback — the mixer reflects the read pointer
  #     to the END of the data and reads with descending addresses. The
  #     reversed paths never consult the loop registers: on count exhaustion
  #     the channel is stopped (statusFlags = 0), so REV is always one-shot.
  #   TYPE_CMP (0x20): compressed (BDPCM) waveform. CMP or REV route the mixer
  #     into its special-case renderer; within it compressed decode is engaged
  #     only when WaveData.type != 0 (the u16 at wave+0: 1 = DPCM, 0 = plain
  #     PCM) — so a CMP-flagged channel with a plain header plays uncompressed
  #     and a REV-only channel with a DPCM header decodes. All CMP/REV/FIX
  #     combinations are valid; CMP+REV plays the stream backward (one-shot),
  #     forward CMP supports looping.
  #   TYPE_SPL (0x40, key split) and TYPE_RHY (0x80, rhythm): instrument-table
  #     lookup flags for the sequencer; they may remain set in
  #     SoundChannel.type but the mixer ignores them.
  TYPE_CGB {.used.} = 0x07'u8
  TYPE_FIX = 0x08'u8
  TYPE_REV = 0x10'u8
  TYPE_CMP = 0x20'u8
  TYPE_SPL {.used.} = 0x40'u8
  TYPE_RHY {.used.} = 0x80'u8

  # status bits (SoundChannel.statusFlags):
  #   START (0x80): note-on request from the sequencer; the mixer consumes it.
  #   STOP (0x40): note-off request; envelope enters release.
  #   SPECIAL (0x20): mixer-internal latch — "CMP/REV pointer already
  #     initialised" (set on the first mixer pass of such a channel).
  #   LOOP (0x10): set at note start when WaveData.flags carries the loop bits
  #     (0xC0 at wave+3).
  #   IEC (0x04): pseudo-echo tail — when the release envelope decays below
  #     SoundChannel.pseudoEchoVolume the driver holds it there and counts
  #     pseudoEchoLength down once per frame, killing the channel at zero.
  #     Shadow mode inherits this for free: envelopeVolumeRight/Left are
  #     computed AFTER the release/IEC handling each frame.
  #   ENV (0x03): envelope phase (3=attack, 2=decay, 1=sustain, 0=release).
  CH_START = 0x80'u8
  CH_STOP {.used.} = 0x40'u8
  CH_ON    = 0xC7'u8   # SOUND_CHANNEL_SF_ON = START|STOP|IEC|ENV — "producing sound"

  # m4a compressed-waveform (BDPCM) 4-bit differential LUT: 16 signed deltas
  # added to a running s8 accumulator. The table is the squares: nibble n < 8
  # adds n^2, n >= 8 subtracts (16-n)^2 (agbplay documents the same table).
  BDPCM_LUT: array[16, int8] = block:
    var t: array[16, int8]
    for n in 0 ..< 16:
      t[n] = (if n < 8: int8(n * n) else: int8(-((16 - n) * (16 - n))))
    t
  # Block format (canonical; bdpcm_decode_block implements it): 33 bytes /
  # 64 samples = 1 s8 base byte + 32 nibble bytes. Sample 0 is the RAW base
  # byte; sample 1 takes the LOW nibble of the first delta byte (its high
  # nibble is never read); each subsequent byte supplies its high nibble then
  # its low nibble (63 used nibbles for samples 1..63). The accumulator wraps
  # at 8 bits (the driver decodes through a byte store / signed byte load).
  BDPCM_BLOCK_BYTES  = 33'u32
  BDPCM_BLOCK_SAMPS  = 64'u32

  # Reverb frame-ring slot capacity, in stereo samples at the 32768 Hz render
  # rate. One mixer pass spans one V-blank = 32768 / 59.7275 Hz ~ 549 output
  # samples; 1024 leaves headroom for frame-length jitter, and cells beyond a
  # pass's real length are simply never read back (intra-frame indexing).
  MP2K_REV_SLOT_LEN = 1024

# Mp2kSampler / Mp2kHle are declared in gba.nim (the GBA object references them).

when defined(mp2kwav):
  import std/[streams, math, strutils]
  # Per-voice diagnostic accumulators (index by channel 0..11).
  var dbgVoiceRawSq*:   array[12, float64]   # sum of (raw s8/128)^2
  var dbgVoiceRawPk*:   array[12, float32]   # peak |raw s8/128|
  var dbgVoiceOutSq*:   array[12, float64]   # sum of post-volume contribution^2 (L+R)
  var dbgVoiceOutPk*:   array[12, float32]   # peak post-volume contribution
  var dbgVoiceN*:       array[12, int]       # samples where voice was active
  var dbgVoiceComp*:    array[12, bool]      # last-seen compressed flag
  # Split by compressed flag: [0]=PCM, [1]=BDPCM.
  var dbgKindRawSq*: array[2, float64]
  var dbgKindRawPk*: array[2, float32]
  var dbgKindN*:     array[2, int]
  var dbgRetrigLog*: int
  var dbgAttackSq*: float64   # summed output energy on attack (age==0) frames
  var dbgAttackPk*: float32
  var dbgAttackN*:  int
  var dbgStepN*: int
  var dbgStepDecimN*: int
  var dbgStepMax*: float32
  var dbgMaster*: int
  proc mp2k_dump_attack*() =
    if dbgAttackN > 0:
      echo "ATTACK-frame outRMS=", sqrt(dbgAttackSq/float64(dbgAttackN)).formatFloat(ffDecimal,5),
        " outPeak=", dbgAttackPk.formatFloat(ffDecimal,4), " n=", dbgAttackN
  proc mp2k_dump_voices*() =
    echo "voice  comp   activeN     rawRMS   rawPeak     outRMS   outPeak"
    for i in 0 ..< 12:
      if dbgVoiceN[i] == 0: continue
      let rr = sqrt(dbgVoiceRawSq[i] / float64(dbgVoiceN[i]))
      let orr = sqrt(dbgVoiceOutSq[i] / float64(dbgVoiceN[i]))
      echo i, "\t", dbgVoiceComp[i], "\t", dbgVoiceN[i], "\t",
        rr.formatFloat(ffDecimal, 4), "\t", dbgVoiceRawPk[i].formatFloat(ffDecimal, 3), "\t",
        orr.formatFloat(ffDecimal, 5), "\t", dbgVoiceOutPk[i].formatFloat(ffDecimal, 4)
    echo "kind   N          rawRMS(s8)   rawPeak(s8)"
    for k in 0 ..< 2:
      if dbgKindN[k] == 0: continue
      let rr = sqrt(dbgKindRawSq[k] / float64(dbgKindN[k])) * 128.0
      echo (if k == 0: "PCM " else: "BDPCM"), "\t", dbgKindN[k], "\t",
        rr.formatFloat(ffDecimal, 3), "\t", (dbgKindRawPk[k]*128.0).formatFloat(ffDecimal, 2)
  proc mp2k_write_wav*(path: string) =
    ## Dump the captured HLE stereo samples (32768 Hz, s16) as a WAV.
    let n = mp2kWavCapture.len
    let s = newFileStream(path, fmWrite)
    let byteRate = 32768 * 2 * 2
    s.write("RIFF"); s.write(uint32(36 + n * 2)); s.write("WAVE")
    s.write("fmt "); s.write(uint32(16)); s.write(uint16(1)); s.write(uint16(2))
    s.write(uint32(32768)); s.write(uint32(byteRate)); s.write(uint16(4)); s.write(uint16(16))
    s.write("data"); s.write(uint32(n * 2))
    for v in mp2kWavCapture: s.write(v)
    s.close()

proc new_mp2k*(gba: GBA): Mp2kHle =
  Mp2kHle(gba: gba, hook_addr: 0xFFFFFFFF'u32, engaged: false)

proc mixer_live*(m: Mp2kHle): bool =
  ## True while the learned hook fired within MP2K_HOOK_STALE_MAX frames.
  ## A stopped SoundMain (stock VSyncOff parks ident at +10; or the engine is
  ## torn down without touching ident) cannot be producing the FIFO stream,
  ## so substitution steps aside for the game's own stream (Lilo & Stitch
  ## VSyncOffs its idle m4a at the title and streams the soundtrack through
  ## its own DMA1 buffer). Unlike fifo_foreign this is fully reversible: the
  ## next pass re-latches every channel and the ct resync snaps staleness.
  m.hook_stale <= MP2K_HOOK_STALE_MAX

proc rd8(m: Mp2kHle; a: uint32): uint8  {.inline.} = m.gba.bus.read_byte_internal(a)
proc rd16(m: Mp2kHle; a: uint32): uint16 {.inline.} = m.gba.bus.read_half_internal(a)
proc rd32(m: Mp2kHle; a: uint32): uint32 {.inline.} = m.gba.bus.read_word_internal(a)

proc wave_u8(m: Mp2kHle; s: ptr Mp2kSampler; rom: ptr seq[byte]; rmask: uint32;
             byteoff: uint32): uint8 {.inline.} =
  ## Read one raw byte of the sample bank (fast ROM path or bus fallback).
  if s.in_rom: rom[][(s.rom_off + byteoff) and rmask]
  else:        m.rd8(s.wave_data + byteoff)

proc bdpcm_decode_block(m: Mp2kHle; s: ptr Mp2kSampler; rom: ptr seq[byte];
                        rmask: uint32; blk: uint32) =
  ## Decode one whole BDPCM block into the sampler's block cache (format and
  ## nibble order: BDPCM_BLOCK_BYTES above). The driver also decodes
  ## block-at-a-time, keyed by block index. Whole-block decode keeps the
  ## stream correct however the resampler lands on it: decimating steps,
  ## reversed reads and loop wrap-backs all just index into the block.
  let base = blk * BDPCM_BLOCK_BYTES
  var acc = cast[int8](m.wave_u8(s, rom, rmask, base))
  s.blk[0] = acc
  for i in 1 ..< int(BDPCM_BLOCK_SAMPS):
    let b = m.wave_u8(s, rom, rmask, base + uint32(i shr 1) + 1'u32)
    let nib = (if (i and 1) != 0: b and 0x0F'u8 else: b shr 4)
    acc = cast[int8](int(acc) + int(BDPCM_LUT[nib]))
    s.blk[i] = acc
  s.blk_index = blk

proc decode_at(m: Mp2kHle; s: ptr Mp2kSampler; rom: ptr seq[byte];
               rmask: uint32; play_pos: uint32): float32 {.inline.} =
  ## Decode the source sample at an explicit play position, in raw s8 units.
  ## A reversed channel (TYPE_REV) maps play position p to source index
  ## sample_count-1-p (sample_count already excludes any note start offset;
  ## see on_frame).
  let pos = (if s.reversed: s.sample_count - 1'u32 - play_pos
             else: play_pos)
  if s.compressed:
    if (pos shr 6) != s.blk_index:
      m.bdpcm_decode_block(s, rom, rmask, pos shr 6)
    float32(s.blk[int(pos and (BDPCM_BLOCK_SAMPS - 1'u32))])
  else:
    float32(cast[int8](m.wave_u8(s, rom, rmask, pos)))

proc decode_src(m: Mp2kHle; s: ptr Mp2kSampler; rom: ptr seq[byte];
                rmask: uint32): float32 {.inline.} =
  ## Decode the source sample at the sampler's current play position.
  m.decode_at(s, rom, rmask, s.src_index)

proc mp2k_state_loaded*(m: Mp2kHle) =
  ## Save-state / rollback load hook. Shadow state is not serialized, so
  ## everything timeline-derived (sampler positions, history taps, the delay
  ## ring, the reverb line) is dropped and a resync is marked: the next mixer
  ## pass re-latches every channel from the restored SoundInfo, resuming
  ## mid-note channels at the engine's own position (on_frame). The learned
  ## hook_addr is kept — states are per-ROM and restore the IWRAM it was
  ## learned from, and a stale PC fails the lock validation anyway. `engaged`
  ## is kept; render_sample emits silence until the first post-load pass.
  for i in 0 ..< MP2K_MAX_CHANNELS:
    m.samplers[i] = Mp2kSampler()      # inactive, zero taps/phase/volumes
  for v in m.out_delay.mitems: v = 0
  m.out_delay_w = 0
  for v in m.reverb_ring.mitems: v = 0
  m.rev_slot = 0
  m.rev_pos = 0
  m.rev_phase = 0
  m.rev_cell = -1
  m.rev_seed = 0
  m.frame_pos = 0
  m.resync_pending = true
  # Foreign-feeder streak/baseline are timeline-derived: drop them. The
  # fifo_foreign LATCH describes the ROM's driver usage, not the timeline, so
  # it is kept (re-latching would substitute silence over the game's streamed
  # music for several frames after every load).
  m.foreign_streak = 0
  m.fifo_cpu_last = m.fifo_cpu_bytes
  m.real_abs_a = 0
  m.real_abs_b = 0
  m.hle_abs_l = 0
  m.hle_abs_r = 0
  m.ab_n = 0
  m.overlay_hold = 0
  m.unlatch_watch = false   # samplers were just dropped
  m.unlatch_agree = 0
  m.shadow_quiet_age = 0   # the restored pcmBuffer may hold audio our reset
                           # shadow doesn't: give it the drain-tail grace
  m.hook_stale = 0         # assume the restored engine is live; a parked one
                           # regrows the counter within the grace

# =============================================================================
# Runtime detection (canonical; mp2k_frame_poll / probe_pc / mixer_hook /
# unlearn_hook implement it): learn the SoundMainRAM entry PC instead of
# matching a ROM signature.
#   * SOUND_INFO_PTR (0x03007FF0) -> SoundInfo, whose ident is ID_NUMBER at
#     rest and ID_NUMBER+1 while SoundMain holds its lock (constants above).
#     That identifies the engine with no ROM pattern on every m4a revision;
#     custom drivers (e.g. Camelot's) never publish the magic.
#   * The PCM mixer ("SoundMainRAM", per its name and the loveemu RAM map) is
#     copied to RAM at init and jumped to from SoundMain while the lock is
#     held, with the SoundInfo pointer in r0 (the ABI argument register;
#     observed on several m4a vintages by this project's harnesses).
#   * So: once the frame poll sees the ident magic, watch execution until an
#     instruction is fetched from RAM (0x02/0x03 region) with r0 == &SoundInfo
#     while ident == ID_NUMBER+1. The first such PC is the mixer entry; hook
#     it every frame from then on.
#   * Self-validating: the real entry can ONLY execute with the lock held, so
#     a learned PC that fires without it (nested-IRQ dispatcher in IWRAM,
#     engine torn down and the buffer reused...) is blocklisted and re-learnt.
# Hot-path cost: once learned, one PC compare per instruction; while probing
# (engine init to first mixer pass, typically <2 frames) each RAM-fetched
# instruction adds one register compare. With the HLE off nothing runs.
# =============================================================================

proc unlearn_hook*(m: Mp2kHle) =
  ## The learned PC fired without the engine lock — impossible for the real
  ## mixer entry. Blocklist it and let the frame poll re-arm probing.
  if m.hook_addr != 0xFFFFFFFF'u32 and m.probe_block_n < m.probe_block.len:
    m.probe_block[m.probe_block_n] = m.hook_addr
    inc m.probe_block_n
  inc m.probe_fails
  m.hook_addr  = 0xFFFFFFFF'u32
  m.entry_addr = 0xFFFFFFFF'u32
  m.engaged = false
  for i in 0 ..< MP2K_MAX_CHANNELS: m.samplers[i].active = false

proc on_frame(m: Mp2kHle; sound_info: uint32) =
  ## Called once per mixer pass (at the learned hook, before the real mixer
  ## runs). Re-reads the SoundInfo channel table and refreshes each sampler's
  ## parameters and envelope endpoints.
  # DIAG: master_apply != 0 re-applies SoundInfo.masterVolume on top of the
  # per-side volumes, which already include it (wrong; default 0).
  let master_mult =
    if m.master_apply != 0:
      float32(int(m.rd8(sound_info + SI_MASTER_VOL)) + 1) / 16.0'f32
    else:
      1.0'f32
  var maxc = int(m.rd8(sound_info + SI_MAX_CHANS))
  if maxc > MP2K_MAX_CHANNELS: maxc = MP2K_MAX_CHANNELS
  # FIFO topology, from the live sound-DMA registers (DMA1/2 are the only
  # FIFO-capable channels — GBATEK). The standard stereo driver runs
  # DMA1->FIFO A (left) and DMA2->FIFO B (right); some vintages mix MONO — one
  # pcmBuffer through a single FIFO (Minish Cap: DMA1->FIFO A routed to both
  # speakers, DMA2 disabled) with a single per-channel volume (see the
  # volume read below). Keying on the DMA registers is what the real signal
  # path does, so it is vintage-independent: substitute only the fed FIFO(s).
  block:
    var fed_a = false
    var fed_b = false
    for c in 1 .. 2:
      if m.gba.dma.dmacnt_h[c].enable and
         m.gba.dma.dmacnt_h[c].start_timing == 3:   # special = FIFO timing
        if   m.gba.dma.dmadad[c] == 0x040000A0'u32: fed_a = true
        elif m.gba.dma.dmadad[c] == 0x040000A4'u32: fed_b = true
    m.mono_mode = (if fed_a and not fed_b: 1
                   elif fed_b and not fed_a: 2
                   else: 0)
  m.reverb_strength = m.rd8(sound_info + SI_REVERB)
  m.pcm_sample_rate = int(m.rd32(sound_info + SI_PCM_RATE))
  m.dbg_reverb = m.reverb_strength
  m.dbg_pcm_rate = m.pcm_sample_rate
  when defined(mp2kwav): dbgMaster = int(m.rd8(sound_info + SI_MASTER_VOL))
  # Reverb frame ring — the shadow of the engine's pcmBuffer slot ring
  # (algorithm and rate rationale: the "MP2K reverb" block in render_sample).
  # pcmDmaPeriod is the ring length in V-blank frames. The ring is maintained
  # whenever engaged, not just while reverb > 0: the real pcmBuffer holds the
  # last pcmDmaPeriod frames unconditionally, so a mid-song reverb-on echoes
  # real history rather than silence.
  m.rev_period = int(m.rd8(sound_info + SI_DMA_PERIOD))
  if m.rev_period < 1: m.rev_period = 1     # degenerate guard; real drivers
  elif m.rev_period > 16: m.rev_period = 16 # use 2..12 (PCM_DMA_BUF_SIZE/spv)
  # Cells per slot = pcmSamplesPerVBlank: the ring runs at the ENGINE rate.
  m.rev_spv = int(m.rd16(sound_info + SI_SPV))
  if m.rev_spv < 16: m.rev_spv = 16
  elif m.rev_spv > MP2K_REV_SLOT_LEN: m.rev_spv = MP2K_REV_SLOT_LEN
  if m.reverb_ring.len != m.rev_period * MP2K_REV_SLOT_LEN * 2:
    m.reverb_ring = newSeq[float32](m.rev_period * MP2K_REV_SLOT_LEN * 2)
  # Slot cursor, derived from pcmDmaCounter the way SoundMain derives its
  # pcmBuffer frame cursor: slot = pcmDmaPeriod - (pcmDmaCounter - 1) when
  # pcmDmaCounter >= 2, else 0. This tracks the real ring phase verbatim,
  # including across skipped mixer passes.
  block:
    let cnt = int(m.rd8(sound_info + SI_DMA_COUNTER))
    m.rev_slot = (if cnt <= 1: 0 else: m.rev_period - (cnt - 1))
    if m.rev_slot < 0 or m.rev_slot >= m.rev_period: m.rev_slot = 0
    when defined(mp2kwav):
      if getEnv("DINGBAT_SLOTTRACE") == "1" and m.dbg_hook_fires < 40:
        echo "pass ", m.dbg_hook_fires, " cnt=", cnt, " slot=", m.rev_slot,
          " period=", m.rev_period, " spv=", m.rev_spv
  m.rev_pos = 0
  m.rev_phase = 0
  m.rev_cell = -1
  m.frame_pos = 0
  for i in 0 ..< MP2K_MAX_CHANNELS:
    let s = addr m.samplers[i]
    if i >= maxc:
      s.active = false
      continue
    let base   = sound_info + uint32(SI_CHANNELS + i * SC_SIZE)
    let status = m.rd8(base + SC_STATUS)
    if (status and CH_ON) == 0:
      s.active = false
      continue
    let ctype = m.rd8(base + SC_TYPE)
    let wave = m.rd32(base + SC_WAVE)
    if wave == 0 or (wave shr 24) == 0: # null / bogus pointer
      s.active = false
      continue
    # Mode bits: TYPE_* table. Compressed decode is selected by WaveData.type
    # != 0 under CMP or REV, not by the channel bit alone.
    let reversed   = (ctype and TYPE_REV) != 0
    let compressed = (ctype and (TYPE_CMP or TYPE_REV)) != 0 and
                     m.rd16(wave + 0) != 0'u16
    let loop_status = m.rd16(wave + 2)
    let looping = (loop_status and 0xC000'u16) != 0
    let new_wave_data = wave + 16
    # Note-on = the START bit in the live status byte: the sequencer sets it
    # and the mixer consumes it, and this hook runs at the mixer's entry, so
    # it is still visible here. It MUST restart the sample: a drum pattern
    # re-keys the SAME sample every beat, so keying on wave_data change alone
    # would drop repeated hits while the previous one is still sounding.
    var use_start = true
    when defined(mp2kwav):
      var checked {.global.} = false
      var envStart {.global.} = true
      if not checked:
        checked = true
        envStart = getEnv("DINGBAT_NOSTART") != "1"
      use_start = envStart
    let started = (status and CH_START) != 0
    let retrig = (started and use_start) or
                 not s.active or s.wave_data != new_wave_data or
                 s.compressed != compressed or s.reversed != reversed
    when defined(mp2kwav):
      let dumpsel = getEnv("DINGBAT_CHDUMP")
      if (dumpsel == $i or dumpsel == "all") and retrig and dbgRetrigLog < 200:
        echo "ch", i, " st=", toHex(int(status), 2),
          " ct=", int(m.rd32(base + SC_COUNT)),
          " evol=", int(m.rd8(base + SC_ENV_VOL)),
          " evr=", int(m.rd8(base + SC_ENV_VR)),
          " evl=", int(m.rd8(base + SC_ENV_VL)),
          " rV=", int(m.rd8(base + SC_VOL_R)),
          " lV=", int(m.rd8(base + SC_VOL_L)),
          " freq=", int(m.rd32(base + SC_FREQ)),
          " nsamp=", int(m.rd32(wave + 12))
        dbgRetrigLog.inc
    when defined(mp2kwav):
      if retrig: inc dbgRetrigCount
    var resumed = false
    if retrig:
      if m.resync_pending and not started:
        # First mixer pass after a state/rollback load: the channel is already
        # mid-note in the engine (CH_ON without START) and must not restart
        # from the sample start — an audible burst hardware doesn't produce.
        # Resume at the engine's own position: the mixer sets ct = size -
        # offset at note-on and decrements it per source sample consumed, so
        # size - ct is the forward cursor AND, for a reversed channel (whose
        # start offset is unrecoverable post-hoc — assume 0), the consumed
        # count that reversed src_index tracks. The volume endpoints then
        # ramp from the freshly reset 0 to the engine's current value over
        # this one frame — a ~16 ms fade-in that also masks the rebuilt
        # interpolation history.
        s.phase_frac = 0
        s.need_fetch = true
        s.tap0 = 0; s.tap1 = 0; s.tap2 = 0; s.tap3 = 0
        s.start_off = 0
        s.blk_index = 0xFFFFFFFF'u32
        s.active = true
        s.age = 1                       # mid-note: NOT an attack frame
        let total     = m.rd32(wave + 12)          # WaveData.size
        let remaining = m.rd32(base + SC_COUNT)    # SoundChannel.ct
        s.src_index =
          if remaining >= 1'u32 and remaining <= total: total - remaining
          else: 0'u32   # implausible ct: start over, still faded in from 0
        resumed = true
      else:
        # (re)trigger: reset the resampler + decode state to the note's start.
        # At note-on SoundChannel.count holds a sample start offset that the
        # mixer's START handler consumes as data + count (and count = size -
        # count), so honour it when START keyed this retrigger.
        var start_off = 0'u32
        if started:
          start_off = m.rd32(base + SC_COUNT)
          if start_off >= m.rd32(wave + 12): start_off = 0
        s.start_off = start_off
        # Forward playback begins at the offset; reversed playback begins at the
        # END of the (offset-trimmed) data and src_index counts samples consumed.
        s.src_index = (if reversed: 0'u32 else: start_off)
        s.phase_frac = 0
        s.need_fetch = true
        s.tap0 = 0; s.tap1 = 0; s.tap2 = 0; s.tap3 = 0
        s.blk_index = 0xFFFFFFFF'u32
        s.active = true
        s.age = 0
    else:
      s.age.inc
      # Continuous position resync against the engine's cursor. Some driver
      # builds keep MORE than the mixer in RAM (ALttP Four Swords: SoundMain
      # itself), so the learned hook can fire a stage BEFORE the sequencer —
      # a note-on then shows a stale SoundChannel.count and the sampler starts
      # thousands of samples off. ct is ground truth on every later pass:
      # consumed = size - ct (same coordinate across the loop reload). Snap
      # only on gross divergence (> 1024 source samples) so resampler jitter
      # and loop-wrap transients never trigger it; a stale note-on is then
      # corrected within one frame, keyed purely on engine state.
      let ctv = m.rd32(base + SC_COUNT)
      let total_sz = m.rd32(wave + 12)
      if ctv >= 1'u32 and ctv <= total_sz:
        let engine_pos = total_sz - ctv
        let our_pos = (if s.reversed: s.start_off + s.src_index
                       else: s.src_index)
        let diff = (if engine_pos > our_pos: engine_pos - our_pos
                    else: our_pos - engine_pos)
        if diff > 1024'u32:
          if s.reversed:
            s.src_index = (if engine_pos >= s.start_off:
                             engine_pos - s.start_off else: 0'u32)
          else:
            s.src_index = engine_pos
          s.phase_frac = 0
          s.need_fetch = true
          s.hist_gap = 0
          s.blk_index = 0xFFFFFFFF'u32
          if s.src_index > 0'u32 and s.src_index < s.sample_count:
            # Seed the interpolation history from the preceding sample (as
            # the resume path does below).
            let rom0 = addr m.gba.cartridge.rom
            let rmask0 = m.gba.cartridge.rom_mask
            let pv = m.decode_at(s, rom0, rmask0, s.src_index - 1'u32)
            s.tap0 = pv; s.tap1 = pv; s.tap2 = pv; s.tap3 = pv
    s.wave_data   = new_wave_data
    s.compressed  = compressed
    s.reversed    = reversed
    if compressed: m.dbg_compressed_used.inc
    s.use_pcm_rate = (ctype and TYPE_FIX) != 0
    # Resample rate = the CHANNEL's per-note playback frequency (Hz), NOT the
    # sample header's base frequency at wave+4 (a fixed-point value in other
    # units). step = freq / output_rate.
    s.freq        = m.rd32(base + SC_FREQ)
    s.loop_start  = m.rd32(wave + 8)    # WaveData.loopStart
    # WaveData.size = source sample count; a reversed channel plays
    # size - offset of them (from data + size - offset DOWN to data[0]).
    let total = m.rd32(wave + 12)
    s.sample_count = (if reversed and s.start_off < total: total - s.start_off
                      else: total)
    s.looping     = looping and not reversed   # REV is one-shot (TYPE_* table)
    # Fast path: a direct ROM offset lets the per-sample mixer bypass the bus
    # address decoder. m4a sample banks live in ROM (0x08000000..0x0DFFFFFF).
    let wave_region = new_wave_data shr 24
    s.in_rom = wave_region >= 0x08'u32 and wave_region <= 0x0D'u32
    if s.in_rom:
      s.rom_off = (new_wave_data and 0x01FFFFFF'u32)
    if resumed and s.src_index > 0'u32 and s.src_index < s.sample_count:
      # Seed the resampler history at the resume point with the preceding
      # source sample (needs in_rom/rom_off, hence after they are set). The
      # block-cache decoder lands on a mid-block BDPCM position natively.
      let rom = addr m.gba.cartridge.rom
      let rmask = m.gba.cartridge.rom_mask
      s.src_index.dec
      s.tap0 = m.decode_src(s, rom, rmask)
      s.src_index.inc
      s.tap1 = s.tap0; s.tap2 = s.tap0; s.tap3 = s.tap0
    # +0x0A/+0x0B are the engine's per-side volumes: envelopeVolume *
    # (masterVolume+1)/16 * (rightVolume|leftVolume) >> 8 — masterVolume is
    # folded in here, so consume them as-is and never re-apply it. The mixer
    # writes them once per pass (a per-frame constant); shift last frame's
    # value into vol_*0 and ramp toward this frame's, mirroring the driver's
    # per-sample interpolation from the previous endpoint. MONO vintages fold
    # pan away: ONE volume, envelopeVolume * avg(rV, lV) >> 8, at +0x0A and
    # +0x0B left at 0 (observed live) — use it for both sides; the output
    # router then feeds the one fed FIFO.
    let vr = float32(m.rd8(base + SC_ENV_VR)) / 255.0'f32 * master_mult
    let vl = (if m.mono_mode != 0: vr
              else: float32(m.rd8(base + SC_ENV_VL)) / 255.0'f32 * master_mult)
    if retrig and started and not resumed:
      # Note-on attack frame. The engine computes this pass's envelope INSIDE
      # the mixer, after our entry hook reads, so +0x0A/+0x0B still hold the
      # previous (usually released, zero) values and would silence the first
      # frame of every note — where a short percussive hit carries most of
      # its energy. Reproduce the driver's first attack step instead, as
      # observed from the driver running in this emulator (FireRed): the
      # START path zeroes envelopeVolume and falls into the attack add
      # (+attack, clamped 255), then per side = env * (masterVolume+1)/16 *
      # rV|lV >> 8 (mono: avg(rV, lV)). The pass mixes FLAT at that value,
      # not a ramp from zero.
      let atk = min(int(m.rd8(base + SC_ATTACK)), 255)
      let mvs = (atk * (int(m.rd8(sound_info + SI_MASTER_VOL)) + 1)) shr 4
      let rvb = int(m.rd8(base + SC_VOL_R))
      let lvb = int(m.rd8(base + SC_VOL_L))
      var svr = float32((mvs * rvb) shr 8) / 255.0'f32 * master_mult
      var svl = float32((mvs * lvb) shr 8) / 255.0'f32 * master_mult
      if m.mono_mode != 0:
        let v = float32((mvs * ((rvb + lvb) shr 1)) shr 8) / 255.0'f32 * master_mult
        svr = v
        svl = v
      s.vol_l0 = svl
      s.vol_r0 = svr
      s.vol_l1 = svl
      s.vol_r1 = svr
    else:
      s.vol_l0 = s.vol_l1
      s.vol_r0 = s.vol_r1
      s.vol_l1 = vl
      s.vol_r1 = vr
  # --- Foreign FIFO feeder detection -------------------------------------------
  # Some games ship m4a for SFX but stream their MUSIC around the engine's
  # channel structs (Batman Vengeance: the streamer fills pcmBuffer
  # just-in-time mid-frame and erases it after the DMA drains, so no
  # SoundChannel is ever active and a state poll sees a silent buffer);
  # substituting the shadow would replace that music with silence. Three
  # engine/bus-state signals latch substitution off for the session (never
  # keyed on game ID):
  #   * FIFO bytes written by anything but special-timing DMA1/2
  #     (fifo_cpu_bytes) — the driver only feeds the FIFOs through those DMAs;
  #   * a special-timing FIFO DMA sourcing OUTSIDE the SoundInfo work area
  #     (pcmBuffer is embedded in SoundInfo at +0x350);
  #   * the catch-all: the real stream persistently audible while the shadow
  #     is persistently silent — an engine-owned stream cannot sound while
  #     every mirrored channel is idle, and if the shadow were wrongly silent
  #     for another reason the game's own audio is the right fallback anyway.
  # Foreign audio is BURSTY, so a consecutive-streak rule never accumulates:
  # evidence = provenance hit or real-audible-while-shadow-silent; refutation
  # = the shadow producing audio with no provenance hit (reset); neutral =
  # both silent (hold the count).
  block:
    if m.fifo_foreign:
      # --- Latched: earn the way back ---------------------------------------
      # For many games the latch was ONE boot-time streamed voice clip played
      # while an ordinary m4a engine idled (Rockman EXE 3 at its title).
      # Losing enhancement for the session over that is the wrong trade, but
      # only provably so once the engine DEMONSTRABLY owns the stream: while
      # latched with any m4a channel active, apu.get_sample keeps the shadow
      # rendering un-emitted (unlatch_watch); sustained agreement with the
      # real stream (each side within 2x, real audible, channels active, 60
      # CONSECUTIVE passes = one second) re-arms substitution. A true-foreign
      # game never keys an m4a channel, so it never qualifies; a hybrid
      # mid-clip has real >> shadow on a side and resets the counter; a wrong
      # unlatch is covered by the overlay passthrough and re-latched.
      var any_active = false
      for i in 0 ..< MP2K_MAX_CHANNELS:
        if m.samplers[i].active: any_active = true
      m.unlatch_watch = any_active
      if m.ab_n > 0:
        let agree_l = m.hle_abs_l * 2 >= m.real_abs_a and
                      m.real_abs_a * 2 >= m.hle_abs_l
        let agree_r = m.hle_abs_r * 2 >= m.real_abs_b and
                      m.real_abs_b * 2 >= m.hle_abs_r
        let audible = m.real_abs_a + m.real_abs_b >= int64(m.ab_n) * 2
        if any_active and audible and agree_l and agree_r:
          inc m.unlatch_agree
          if m.unlatch_agree >= 60:
            m.fifo_foreign = false
            m.foreign_streak = 0
            m.unlatch_agree = 0
            m.shadow_quiet_age = 0
            inc m.dbg_unlatches
        else:
          m.unlatch_agree = 0
        m.real_abs_a = 0
        m.real_abs_b = 0
        m.hle_abs_l = 0
        m.hle_abs_r = 0
        m.ab_n = 0
      else:
        m.unlatch_agree = 0
    if not m.fifo_foreign:
      var provenance = m.fifo_cpu_bytes - m.fifo_cpu_last >= 64
      m.fifo_cpu_last = m.fifo_cpu_bytes
      for c in 1 .. 2:
        if m.gba.dma.dmacnt_h[c].enable and
           m.gba.dma.dmacnt_h[c].start_timing == 3 and
           (m.gba.dma.dmadad[c] == 0x040000A0'u32 or
            m.gba.dma.dmadad[c] == 0x040000A4'u32):
          let sad = m.gba.dma.dmasad[c]
          if sad < sound_info or sad >= sound_info + 0x4000'u32:
            provenance = true
      # Real-vs-shadow energy since the last mixer pass (accumulated in
      # apu.get_sample), in FIFO latch units (s8*2): real avg(|L|+|R|) >= 4
      # is clearly audible; shadow avg < 0.25 is genuinely silent.
      var real_loud = false
      var shadow_loud = false
      if m.ab_n > 0:
        let real_sum = m.real_abs_a + m.real_abs_b
        let hle_sum  = m.hle_abs_l + m.hle_abs_r
        when defined(mp2kwav):
          m.dbg_real_avg = float32(real_sum) / float32(m.ab_n)
          m.dbg_hle_avg  = float32(hle_sum) / float32(m.ab_n)
        real_loud   = real_sum >= int64(m.ab_n) * 4
        shadow_loud = hle_sum >= int64(m.ab_n) div 4
        # --- Transient foreign-overlay passthrough ---------------------------
        # Hybrid games overlay their OWN stream on the engine's output
        # (Kinniku Banzuke 2 streams announcer speech into the pcmBuffer B
        # half while m4a music plays). The shadow cannot render audio that
        # never passes through the SoundChannels. Per-side test: a real FIFO
        # side carrying more than TWICE the shadow's same side plus an
        # audibility floor cannot be the engine's own mix (both halves come
        # from the same channel loop with byte-bounded volumes we mirror).
        # While held, apu.get_sample emits the REAL stream and the shadow
        # keeps rendering underneath — reversible per pass, unlike
        # fifo_foreign; the 30-pass hold spans sentence-cadence gaps so it
        # cannot flap mid-speech.
        let over_l = m.real_abs_a >= m.hle_abs_l * 3 + int64(m.ab_n) * 4
        let over_r = m.real_abs_b >= m.hle_abs_r * 3 + int64(m.ab_n) * 4
        if over_l or over_r:
          if m.overlay_hold == 0: inc m.dbg_overlay_triggers
          m.overlay_hold = 30
        elif m.overlay_hold > 0:
          dec m.overlay_hold
        if m.overlay_hold > 0: inc m.dbg_overlay_passes
        m.real_abs_a = 0
        m.real_abs_b = 0
        m.hle_abs_l = 0
        m.hle_abs_r = 0
        m.ab_n = 0
      if shadow_loud: m.shadow_quiet_age = 0
      elif m.shadow_quiet_age < 1000: inc m.shadow_quiet_age
      # Energy evidence requires ALL engine channels idle: with one active
      # the engine owns whatever is sounding, and any shadow silence is our
      # own problem (e.g. a note-on envelope lag), never foreignness. It also
      # only counts once the shadow has been silent longer than the real ring
      # could still be draining engine-mixed audio (pcmBuffer holds up to
      # pcmDmaPeriod <= 16 frames; our delay line holds 1): a song-stop drain
      # tail is not foreign.
      var any_active = false
      for i in 0 ..< MP2K_MAX_CHANNELS:
        if m.samplers[i].active: any_active = true
      if provenance or
         (real_loud and not any_active and m.shadow_quiet_age > 16):
        inc m.foreign_streak
        # 3 evidence passes suffice: a full frame of clearly audible audio
        # while the shadow (voices AND reverb tail) is bit-silent outside any
        # drain-tail window is essentially impossible for an engine-owned
        # stream, and sparse stingers still latch within seconds.
        if m.foreign_streak >= 3:
          m.fifo_foreign = true
      elif shadow_loud:
        m.foreign_streak = 0
      # else: both silent — neutral, hold the evidence count
  m.frame_seen = true
  m.engaged = true
  m.hook_stale = 0           # the mixer demonstrably ran this frame
  m.resync_pending = false   # one full re-latch pass done; back to normal keying

proc mixer_hook*(m: Mp2kHle) =
  ## PC-hook entry, called from cpu.tick when r15 reaches the learned mixer
  ## entry. With the engine lock held, refresh the mixer state (the channel
  ## status still carries START here: on_frame). Without it the learned PC
  ## was wrong ("Runtime detection"): unlearn and re-probe.
  let sip = m.rd32(MP2K_SOUNDINFO_PTR_ADDR)
  if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
    let ident = m.rd32(sip + SI_MAGIC)
    if ident == MP2K_IDENT_LOCK or ident == MP2K_IDENT_LOCK_VOFF:
      m.on_frame(sip)
      return
  m.unlearn_hook()

proc probe_pc*(m: Mp2kHle; pc: uint32) {.noinline.} =
  ## Learning probe, called from cpu.tick only while probing is armed and only
  ## for RAM-fetched instructions with r0 == &SoundInfo (both prefiltered
  ## inline). Lock held => this PC is the mixer entry: learn it and run the
  ## first shadow pass now (the entry has not executed yet, so channel state
  ## is exactly what the hook would see).
  let ident = m.rd32(m.probe_sound_info + SI_MAGIC)
  inc m.dbg_probe_hits
  m.dbg_probe_ident = ident
  if ident != MP2K_IDENT_LOCK and ident != MP2K_IDENT_LOCK_VOFF: return
  for i in 0 ..< m.probe_block_n:
    if m.probe_block[i] == pc: return          # previously invalidated
  m.hook_addr  = pc                            # pc may carry the Thumb bit; the
  m.entry_addr = pc and not 1'u32              # hook compare uses it verbatim
  m.probing = false
  # The hook just moved from "probing" to "armed" mid-frame; re-fold it into
  # the CPU sentinel now rather than waiting for the next frame poll.
  m.gba.refresh_hle_hook()
  m.dbg_hook_fires.inc
  m.mixer_hook()

proc mp2k_frame_poll*(m: Mp2kHle) =
  ## Once-per-frame presence check (2 IWRAM reads; called from step_frame only
  ## while mp2k_hle is enabled). Arms PC probing until the mixer entry is
  ## learned; disengages the HLE if the ident magic ever disappears (engine
  ## torn down) so stale samplers cannot keep looping.
  let sip = m.rd32(MP2K_SOUNDINFO_PTR_ADDR)
  var ident = 0'u32
  if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
    ident = m.rd32(sip + SI_MAGIC)
  if m.hook_addr != 0xFFFFFFFF'u32:
    if m.engaged and ident != MP2K_IDENT_IDLE and ident != MP2K_IDENT_LOCK and
       ident != MP2K_IDENT_IDLE_VOFF and ident != MP2K_IDENT_LOCK_VOFF:
      m.engaged = false
      for i in 0 ..< MP2K_MAX_CHANNELS: m.samplers[i].active = false
    # Frames since the hook last fired (mixer_live); on_frame zeroes it.
    if m.engaged and m.hook_stale < 1000'i32: inc m.hook_stale
    return
  # Arm probing only when the engine is at rest (ident == ID_NUMBER, in
  # either VSync form): arming mid-pass could learn a mid-mixer PC instead of
  # the entry.
  m.probing = (ident == MP2K_IDENT_IDLE or ident == MP2K_IDENT_IDLE_VOFF) and
              m.probe_fails < MP2K_PROBE_MAX_FAILS
  if m.probing: m.probe_sound_info = sip

proc push_tap(s: ptr Mp2kSampler; v: float32) {.inline.} =
  ## Shift a decoded source sample into the 4-sample history (tap0 newest).
  (s.tap3, s.tap2, s.tap1, s.tap0) = (s.tap2, s.tap1, s.tap0, v)

proc catmull_rom(p0, p1, p2, p3, mu: float32): float32 {.inline.} =
  ## Catmull-Rom spline between p1 and p2 (mu in 0..1); p0/p3 are the
  ## neighbouring samples.
  let mu2 = mu * mu
  0.5'f32 * (2.0'f32 * p1 + (p2 - p0) * mu +
             (2.0'f32 * p0 - 5.0'f32 * p1 + 4.0'f32 * p2 - p3) * mu2 +
             (3.0'f32 * p1 - p0 - 3.0'f32 * p2 + p3) * mu2 * mu)

proc advance_cursor(s: ptr Mp2kSampler; step: float32) =
  ## Move the read cursor by `step` source samples. Whole samples crossed go
  ## to src_index (and, beyond the first, to hist_gap so the next fetch can
  ## backfill the tap history); the remainder is the new phase. A looping
  ## sample wraps modulo its loop length. A one-shot sample — or a reversed
  ## one, whose driver path never consults the loop registers — holds its last
  ## sample until the game clears CH_ON.
  let p = s.phase_frac + step
  let whole = uint32(p)
  s.phase_frac = p - float32(whole)
  if whole == 0'u32: return
  s.src_index += whole
  s.need_fetch = true
  s.hist_gap = min(s.hist_gap + whole - 1'u32, 3'u32)
  if s.src_index < s.sample_count: return
  if s.looping and not s.reversed and s.loop_start < s.sample_count:
    let span = s.sample_count - s.loop_start
    s.src_index = s.loop_start + (s.src_index - s.sample_count) mod span
  else:
    s.src_index = s.sample_count
    s.need_fetch = false

proc render_sample*(m: Mp2kHle): tuple[l: int16, r: int16] =
  ## One stereo output sample at the APU rate (32768 Hz), replacing the
  ## DirectSound FIFO A/B contribution while engaged. Values are in the FIFO
  ## latch range (about -256..254) so the APU's DirectSound scaling applies.
  ## Per channel: a 4-tap source-sample history plus a fractional phase; a
  ## new source sample is decoded only when the cursor crosses a sample
  ## boundary, and the output is interpolated from the history.
  if not m.engaged: return (0'i16, 0'i16)
  var accl = 0.0'f32
  var accr = 0.0'f32
  let t = (if m.frame_len > 0: float32(m.frame_pos) / float32(m.frame_len) else: 0.0'f32)
  let rom = addr m.gba.cartridge.rom
  let rmask = m.gba.cartridge.rom_mask
  let cubic = m.use_cubic
  for i in 0 ..< MP2K_MAX_CHANNELS:
    let s = addr m.samplers[i]
    if not s.active: continue
    # Fetch a fresh source sample into the history when the phase advanced.
    # A decimating advance (step > 1) skipped hist_gap source samples: first
    # backfill the history with the samples ADJACENT to the new position so
    # the interpolation always spans neighbouring source samples, as the real
    # mixer's does. Interpolating stride-spaced fetches would act as a
    # triangle lowpass over the stride and gut bright decimated voices.
    if s.need_fetch and s.src_index < s.sample_count:
      if s.hist_gap > 0'u32:
        var j = min(s.hist_gap, 3'u32)
        while j >= 1'u32:
          if s.src_index >= j:
            s.push_tap(m.decode_at(s, rom, rmask, s.src_index - j))
          dec j
        s.hist_gap = 0
      s.push_tap(m.decode_src(s, rom, rmask))
      s.need_fetch = false
    var sample: float32
    if m.resample_mode == 2:
      sample = s.tap0                       # zero-order hold (raw FIFO parity)
    elif m.resample_mode == 1 or not cubic:
      sample = s.tap1 + (s.tap0 - s.tap1) * s.phase_frac
    else:
      # One sample of extra latency buys a neighbour on each side of the segment.
      sample = catmull_rom(s.tap3, s.tap2, s.tap1, s.tap0, s.phase_frac)
    sample = sample / 128.0'f32
    var vl, vr: float32
    case m.env_mode
    of 1:                       # constant at current (this-frame) envelope
      vl = s.vol_l1; vr = s.vol_r1
    else:                       # 0: linear ramp across the frame (original)
      vl = s.vol_l0 * (1.0'f32 - t) + s.vol_l1 * t
      vr = s.vol_r0 * (1.0'f32 - t) + s.vol_r1 * t
    accl += sample * vl
    accr += sample * vr
    when defined(mp2kwav):
      let cl = sample * vl
      let cr = sample * vr
      dbgVoiceRawSq[i] += float64(sample) * float64(sample)
      dbgVoiceRawPk[i] = max(dbgVoiceRawPk[i], abs(sample))
      dbgVoiceOutSq[i] += float64(cl)*float64(cl) + float64(cr)*float64(cr)
      dbgVoiceOutPk[i] = max(dbgVoiceOutPk[i], max(abs(cl), abs(cr)))
      dbgVoiceN[i].inc
      dbgVoiceComp[i] = s.compressed
      let k = (if s.compressed: 1 else: 0)
      dbgKindRawSq[k] += float64(sample) * float64(sample)
      dbgKindRawPk[k] = max(dbgKindRawPk[k], abs(sample))
      dbgKindN[k].inc
      if s.age == 0:            # attack frame (first frame after note-on)
        dbgAttackSq += float64(cl)*float64(cl) + float64(cr)*float64(cr)
        dbgAttackPk = max(dbgAttackPk, max(abs(cl), abs(cr)))
        dbgAttackN.inc
    # Advance the resample phase; step = playback-rate / output-rate, where a
    # TYPE_FIX channel's playback rate is pcmFreq (TYPE_* table).
    let rate = (if s.use_pcm_rate: float32(m.pcm_sample_rate) else: float32(s.freq))
    when defined(mp2kwav):
      dbgStepN.inc
      if rate > float32(APU_SAMPLE_RATE):
        dbgStepDecimN.inc
        dbgStepMax = max(dbgStepMax, rate/float32(APU_SAMPLE_RATE))
    s.advance_cursor(rate / float32(APU_SAMPLE_RATE))
  m.frame_pos.inc
  if m.frame_len > 0 and m.frame_pos >= m.frame_len: m.frame_pos = m.frame_len
  # --- MP2K reverb: the driver's buffer-seed echo (canonical) -------------------
  # Driver behaviour, observed at runtime (loveemu's summary: "a simple
  # reverb (echo) effect with fixed delay"). pcmBuffer is two s8 halves, one
  # per FIFO, each a ring of pcmDmaPeriod one-V-blank slots; the slot the
  # mixer is about to fill holds the audio mixed pcmDmaPeriod V-blanks ago —
  # the frame the DMA just finished playing (slot cursor: on_frame). Before
  # any voice is mixed the driver seeds that slot, sample by sample: it sums
  # the four signed bytes at the same index in both halves of the slot being
  # overwritten and of the following slot (one frame younger, wrapping to
  # slot 0), scales the sum by reverb/512, rounds negative results one LSB
  # toward zero, and stores the one mono result to both halves. Voices are
  # accumulated on top, so the stored slot is the wet frame and the seed is
  # the feedback path: a two-tap (P and P-1 frames) feedback comb with gain
  # reverb/512 per sample pair, stable for reverb <= 127. With reverb == 0
  # the slot is zero-filled and holds the dry mix.
  #
  # Mapping to the 32768 Hz render: the seed addressing is per-slot and
  # intra-frame-indexed (sample i of this pass pairs with sample i of the
  # passes P and P-1 V-blanks ago), not a fixed sample-count delay, and the
  # buffer runs at the ENGINE's pcmFreq. reverb_ring is therefore kept at
  # that rate: rev_period slots of rev_spv stereo cells. rev_phase advances
  # pcmFreq/32768 cells per output sample; on cell entry the seed is computed
  # from the same cell of the P- and (P-1)-pass-old slots and this pass's wet
  # output is point-sampled into the cell, then the seed is held across the
  # cell's remaining output samples — the zero-order hold the DMA/DAC replay
  # applies. The ring MUST run at pcmFreq: the seed sums two consecutive
  # frames, so the buffer's band-limited self-correlation is the loop gain,
  # and a 32768 Hz ring under-echoes (FireRed forced-reverb A/B against the
  # real FIFO). Floats are in s8-buffer/128 units (a voice contributes
  # sample/128 * envelopeVolume/255, the driver's byte-lane scale), so the
  # seed is sum_f * reverb / 512. Omitted, each sub-LSB on the s8 scale: the
  # negative nudge and the s8 store quantization/wrap. MONO vintages keep the
  # same formula: both sides are identical, so the four-read sum degrades to
  # 2*(cur + next) with the same /512 (A/B RMS against the real FIFO).
  var outl_f = accl
  var outr_f = accr
  if m.reverb_ring.len > 0:
    let cap  = MP2K_REV_SLOT_LEN
    var i    = int(m.rev_phase)
    if i >= m.rev_spv: i = m.rev_spv - 1
    let cur  = (m.rev_slot * cap + i) * 2
    if i != m.rev_cell:
      # Cell entry: seed from the old ring content, then store this pass's
      # wet value (the cell's first output sample = the point-sampling the
      # engine's pcmFreq mixing implies).
      let nxts = (if m.rev_slot + 1 >= m.rev_period: 0 else: m.rev_slot + 1)
      let nxt  = (nxts * cap + i) * 2
      if m.reverb_strength > 0'u8:
        let sum  = m.reverb_ring[cur] + m.reverb_ring[cur + 1] +
                   m.reverb_ring[nxt] + m.reverb_ring[nxt + 1]
        m.rev_seed = sum * float32(m.reverb_strength) * (1.0'f32 / 512.0'f32)
      else:
        m.rev_seed = 0
      # With reverb == 0 rev_seed is 0 and this store only maintains the dry
      # history (the driver's zero-fill + voice accumulation).
      m.reverb_ring[cur]     = accl + m.rev_seed
      m.reverb_ring[cur + 1] = accr + m.rev_seed
      m.rev_cell = i
    outl_f = accl + m.rev_seed
    outr_f = accr + m.rev_seed
    m.rev_phase += float32(m.pcm_sample_rate) * (1.0'f32 / float32(APU_SAMPLE_RATE))
    m.rev_pos.inc
  # Scale to the DirectSound latch range the APU expects. Makeup gain 2.025:
  # centres the HLE/real RMS A/B at 1.0 (the pure ÷256 mixer scale would be
  # ~2.0). `makeup` overrides it for diagnostics.
  let MP2K_MAKEUP_GAIN = (if m.makeup > 0'f32: m.makeup else: 2.025'f32)
  let li = int32(outl_f * 127.0'f32 * MP2K_MAKEUP_GAIN)
  let ri = int32(outr_f * 127.0'f32 * MP2K_MAKEUP_GAIN)
  m.dbg_out_energy += abs(outl_f) + abs(outr_f)
  m.dbg_out_count.inc
  var outl = int16(clamp(li, -512, 511))
  var outr = int16(clamp(ri, -512, 511))
  # Route to the FIFO(s) the engine feeds (on_frame); the result is (FIFO A,
  # FIFO B). A mono driver's other FIFO never receives data on hardware, so
  # it gets silence — the game may still have it routed to a speaker.
  case m.mono_mode
  of 1: outr = 0            # mono via FIFO A (outl == outr already; B silent)
  of 2: outl = 0            # mono via FIFO B
  else: discard
  # DirectSound double-buffer (canonical): the driver mixes each pcmBuffer
  # frame one V-blank ahead of the DMA that drains it, so hardware audio lags
  # the mixer pass by one frame (the HLE/real cross-correlation peaks at a
  # one-frame lag). Emit the sample from db_delay samples ago to match: the
  # ring slot about to be overwritten holds the value written db_delay
  # samples earlier.
  var eoutl = outl
  var eoutr = outr
  if m.db_delay > 0 and m.out_delay.len >= 2:
    let slots = m.out_delay.len shr 1
    if m.out_delay_w >= slots: m.out_delay_w = 0
    let wi = m.out_delay_w shl 1
    eoutl = m.out_delay[wi]
    eoutr = m.out_delay[wi + 1]
    m.out_delay[wi]     = outl
    m.out_delay[wi + 1] = outr
    m.out_delay_w = m.out_delay_w + 1
  when defined(mp2kwav):
    mp2kWavCapture.add eoutl
    mp2kWavCapture.add eoutr
  (eoutl, eoutr)

proc init_mp2k*(m: Mp2kHle) =
  ## Initialise mixer state. Nothing to scan: the hook is learned at runtime
  ## ("Runtime detection").
  m.frame_len = APU_SAMPLE_RATE div 60
  m.use_cubic = true   # cubic (Catmull-Rom, per Paul Bourke) resampling by default
  # One frame of double-buffer latency (render_sample).
  m.db_delay = m.frame_len
  m.out_delay = newSeq[int16](m.frame_len * 2)
  m.out_delay_w = 0
