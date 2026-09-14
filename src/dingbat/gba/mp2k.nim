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
#   * SHADOW mode: the real mixer still runs; its channel table is
#     snapshotted at the mixer entry hook (snapshot_pass) and the envelope
#     the pass is about to compute is predicted from the driver's own state
#     by the rules the probe songs pinned (P3: attack/decay/sustain/release
#     and the pseudo-echo floor), then the frame is rendered at once
#     (apply_pending / render_frame) into a FIFO that holds it until the
#     hardware would play it (measure_latency: the sound DMA's cursor
#     crossing the slot). Every prediction is checked against the real
#     bytes one hook later; a vintage that misses drops back to rendering
#     each pass one hook late from the bytes it left behind.
#   * Mixer facts below marked P1..P10 come from the probe songs in
#     tools/mp2kprobe played by the driver itself (tests/mp2k_probe.nim
#     reads its pcmBuffer).
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
  SC_DECAY    = 0x05
  SC_SUSTAIN  = 0x06
  SC_RELEASE  = 0x07
  SC_ENV_VOL  = 0x09   # envelopeVolume (the pass's ADSR state)
  SC_ECHO_VOL = 0x0C   # pseudoEchoVolume: the release floors here (status IEC)
  SC_ECHO_LEN = 0x0D   # pseudoEchoLength: frames the floor is held, then dropped
  SC_ENV_VR   = 0x0A   # envelopeVolumeRight
  SC_ENV_VL   = 0x0B   # envelopeVolumeLeft
  SC_COUNT    = 0x18   # count/ct: source samples remaining until sample/loop
                       # end (position resync + resume: apply_pending); stale
                       # while START is set
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
  CH_STOP  = 0x40'u8
  CH_IEC   = 0x04'u8
  CH_ENV   = 0x03'u8
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
  # Output FIFO (render_frame): capacity in stereo samples, and the level
  # aimed for at the moment a frame is pushed. The hardware plays a pass's
  # frame one V-blank after the pass plus a few samples of FIFO pipeline
  # (P2: 553 APU samples on Emerald). The guard is the headroom that keeps
  # a late V-blank handler from running the FIFO dry, at the price of that
  # much extra latency (half a millisecond); a later one holds the last
  # sample for the few samples it is late.
  MP2K_FIFO_CAP   = 4096
  MP2K_FIFO_GUARD = 16
  # From a byte's FIFO transfer to its sample at the DAC, beyond its place
  # in the queue (the DMA refills 16 bytes when 15 remain, so a transfer's
  # first byte plays 15 samples later), in DMA-rate samples. Fitted on the
  # library sweep (lag-0 waveform correlation against the emulator's cubic
  # FIFO reconstruction, 780 music titles): 4 is best at every engine rate
  # from 5.7 to 27 kHz (2 and 5 lose at nearly all of them; a constant in
  # output samples loses at 13.4 kHz and above 30 kHz). Above 35 kHz
  # (Castlevania's 42 kHz configuration and two 40 kHz titles) 2 wins: the
  # two differ by 1.6 output samples there, which content reaching 16 kHz
  # still resolves. (10, until 2026-09-14, was fitted while the frame
  # FIFO's level control parked every title up to 24 samples early.)
  MP2K_FIFO_PIPELINE      = 4.0'f32
  MP2K_FIFO_PIPELINE_FAST = 2.0'f32
  MP2K_FIFO_FAST_RATE     = 35000.0'f32
  # Sampler tap window: taps[k] holds the source sample at cursor + k -
  # MP2K_TAP_OFF. Catmull-Rom uses the four around the cursor; the quality
  # tier's windowed sinc uses up to all of them: its kernel is 8 source
  # samples wide at the sample's own rate and stretches with the playback
  # step (a voice played at three source samples per output sample needs a
  # kernel three times as wide to keep its cutoff below the output
  # Nyquist), up to MP2K_SINC_MAX_STEP.
  MP2K_TAPS          = 64
  MP2K_TAP_OFF       = 31
  MP2K_SINC_HALF     = 8.0'f32           # kernel half-width, source samples, at step <= 1
  MP2K_SINC_MAX_STEP = 4.0'f32           # 8 * 4 = 32 = the window's reach
  MP2K_SINC_CUTOFF   = 0.46'f32          # of the (narrower) rate: 92 % of its Nyquist
  MP2K_SINC_RES      = 512               # prototype table points per source sample
  MP2K_FIFO_REFILL   = 16'u32          # bytes per FIFO DMA transfer (GBATEK)

# Mp2kSampler / Mp2kHle are declared in gba.nim (the GBA object references them).

# Windowed-sinc prototype for the quality tier: sinc at MP2K_SINC_CUTOFF
# under a Hann window of half-width MP2K_SINC_HALF, tabulated over
# x in [0, MP2K_SINC_HALF] (symmetric). At playback step s <= 1 a voice is
# reconstructed with the prototype as is: the sample's own band, none of
# the images the driver's linear interpolation and the DAC's hold leave
# above the sample's Nyquist. At s > 1 (Breath of Fire plays every voice
# at up to three source samples per output sample; Beast Shooter a fifth
# of its) the kernel is stretched by s — cutoff at the OUTPUT Nyquist — so
# the decimation is band-limited instead of folding the sample's top
# octaves back into the music as the driver's does. Weights are
# normalised per output sample, so DC gain is exact at every phase and
# step.
var mp2kSincProto: array[int(MP2K_SINC_HALF) * MP2K_SINC_RES + 2, float32]
var mp2kSincReady = false

proc build_sinc_table() =
  if mp2kSincReady: return
  let fc = 2.0 * float64(MP2K_SINC_CUTOFF)
  for i in 0 ..< mp2kSincProto.len:
    let x = float64(i) / float64(MP2K_SINC_RES)
    let arg = PI * fc * x
    let sinc = (if abs(arg) < 1e-9: 1.0 else: sin(arg) / arg)
    let wn = (if x >= float64(MP2K_SINC_HALF): 0.0
              else: 0.5 + 0.5 * cos(PI * x / float64(MP2K_SINC_HALF)))
    mp2kSincProto[i] = float32(fc * sinc * wn)
  mp2kSincReady = true

proc sinc_sample(s: ptr Mp2kSampler; step: float32): float32 {.inline.} =
  ## The tier's interpolated sample at the cursor's fractional phase, with
  ## the prototype kernel stretched by max(step, 1) (capped at
  ## MP2K_SINC_MAX_STEP: the tap window's reach).
  let st = clamp(step, 1.0'f32, MP2K_SINC_MAX_STEP)
  let inv = 1.0'f32 / st
  let half = MP2K_SINC_HALF * st
  let frac = s.phase_frac
  var acc = 0.0'f32
  var wsum = 0.0'f32
  let k0 = max(0, int(float32(MP2K_TAP_OFF) + frac - half) + 1)
  let k1 = min(MP2K_TAPS - 1, int(float32(MP2K_TAP_OFF) + frac + half))
  for k in k0 .. k1:
    let x = abs(float32(k - MP2K_TAP_OFF) - frac) * inv
    let w = mp2kSincProto[int(x * float32(MP2K_SINC_RES))]
    acc += s.taps[k] * w
    wsum += w
  if wsum > 1e-6'f32: acc / wsum else: s.taps[MP2K_TAP_OFF]

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
  ## see apply_pending).
  let pos = (if s.reversed: s.sample_count - 1'u32 - play_pos
             else: play_pos)
  if s.compressed:
    if (pos shr 6) != s.blk_index:
      m.bdpcm_decode_block(s, rom, rmask, pos shr 6)
    float32(s.blk[int(pos and (BDPCM_BLOCK_SAMPS - 1'u32))])
  else:
    float32(cast[int8](m.wave_u8(s, rom, rmask, pos)))

proc mp2k_state_loaded*(m: Mp2kHle) =
  ## Save-state / rollback load hook. Shadow state is not serialized, so
  ## everything timeline-derived (sampler positions, history taps, the delay
  ## ring, the reverb line) is dropped and a resync is marked: the next mixer
  ## pass re-latches every channel from the restored SoundInfo, resuming
  ## mid-note channels at the engine's own position (apply_pending). The learned
  ## hook_addr is kept — states are per-ROM and restore the IWRAM it was
  ## learned from, and a stale PC fails the lock validation anyway. `engaged`
  ## is kept; render_sample emits silence until the first post-load pass.
  for i in 0 ..< MP2K_MAX_CHANNELS:
    m.samplers[i] = Mp2kSampler()      # inactive, zero taps/phase/volumes
  m.pend_valid = false                 # the restored pass is snapshotted afresh
  m.fifo_r = 0
  m.fifo_w = 0
  m.fifo_acc = 0
  m.fifo_err_avg = 0
  m.lat_n = 0
  m.cnt_max = 0
  m.ring_copy_valid = false
  m.ring_prev_slot = -1
  m.fifo_last_a = 0
  m.fifo_last_b = 0
  m.fifo_primed = false
  for v in m.reverb_ring.mitems: v = 0
  m.rev_slot = 0
  m.rev_pos = 0
  m.rev_phase = 0
  m.rev_cell = -1
  m.rev_seed = 0
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
#   * So: once the frame poll sees the ident magic, watch execution for
#     instructions fetched from RAM (0x02/0x03 region) with r0 == &SoundInfo
#     while ident == ID_NUMBER+1. Every such instruction that is the target
#     of a call (looks_called: a Thumb or ARM BL aimed at it, a BL to a
#     `bx rN` stub — how a compiled SoundMain reaches a function pointer —
#     or `mov lr, pc; bx rN`, the two register forms keyed by a fresh return
#     address) is a candidate. Eight passes are tallied (a pass ends when
#     the poll sees the lock released, or when an entry is sighted again);
#     the candidates that fired in every pass are ranked in pass order and
#     the first is hooked: SoundMainRAM alone on the stock builds (Emerald,
#     Minish Cap, ...), SoundMain itself on the builds that keep it in RAM.
#   * That second class (EZ-Talk, Super Dodgeball, Battle Network,
#     Castlevania, Advance GTA) runs its sequencer AFTER the hook, so its
#     note-ons reach the snapshot a pass late. check_predictions sees that
#     two ways — an envelope that does not match one hook later, or a
#     channel first seen ON without START (the mixer clears START; a hook
#     after the sequencer always sees it) — and moves the hook to the next
#     candidate of the pass, the mixer proper. A move that predicts no
#     better returns to the entry.
#   * Self-validating: the real entry can ONLY execute with the lock held, and
#     once per pass, so a learned PC that fires without it (nested-IRQ
#     dispatcher in IWRAM, engine torn down and the buffer reused...) or many
#     times a frame (a per-channel helper inside the mixer) is blocklisted
#     and re-learnt.
# Hot-path cost: once learned, one PC compare per instruction; while probing
# (engine init to the eighth mixer pass) each RAM-fetched instruction adds
# one register compare. With the HLE off nothing runs.
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
  m.pend_valid = false
  m.fifo_primed = false
  m.cand_n = 0
  m.cand_pick_n = 0
  m.cand_idx = 0
  m.probe_passes = 0
  m.pred_ok = 0
  m.pred_bad = 0
  m.seq_late = 0
  m.seq_locked = false
  m.predict = getEnv("DINGBAT_MP2K_LATE") != "1"
  for i in 0 ..< MP2K_MAX_CHANNELS: m.samplers[i].active = false

proc fifo_topology(m: Mp2kHle): int =
  ## Which FIFO(s) the engine feeds, from the live sound-DMA registers
  ## (DMA1/2 are the only FIFO-capable channels — GBATEK): 0 = stereo, 1 =
  ## mono through FIFO A, 2 = mono through FIFO B. The standard driver runs
  ## DMA1->FIFO A and DMA2->FIFO B; some vintages mix MONO — one pcmBuffer
  ## through a single FIFO (Minish Cap: DMA1->FIFO A routed to both
  ## speakers, DMA2 disabled) with a single per-channel volume (the volume
  ## read in apply_pending). Keying on the DMA registers is what the real
  ## signal path does, so it is vintage-independent: substitute only the fed
  ## FIFO(s).
  var fed_a = false
  var fed_b = false
  for c in 1 .. 2:
    if m.gba.dma.dmacnt_h[c].enable and
       m.gba.dma.dmacnt_h[c].start_timing == 3:   # special = FIFO timing
      if   m.gba.dma.dmadad[c] == 0x040000A0'u32: fed_a = true
      elif m.gba.dma.dmadad[c] == 0x040000A4'u32: fed_b = true
  (if fed_a and not fed_b: 1
   elif fed_b and not fed_a: 2
   else: 0)

proc snapshot_pass(m: Mp2kHle; sound_info: uint32) =
  ## Capture, at the mixer entry, the state the pass about to run mixes
  ## from: the channel table's note-on / sample / rate fields and the
  ## pass-wide SoundInfo fields. Applied one hook later (apply_pending),
  ## when the envelope this pass computes can be read back.
  var maxc = int(m.rd8(sound_info + SI_MAX_CHANS))
  if maxc > MP2K_MAX_CHANNELS: maxc = MP2K_MAX_CHANNELS
  m.pend_maxc = maxc
  for i in 0 ..< MP2K_MAX_CHANNELS:
    let p = addr m.pend[i]
    if i >= maxc:
      p.status = 0
      continue
    let base = sound_info + uint32(SI_CHANNELS + i * SC_SIZE)
    p.status = m.rd8(base + SC_STATUS)
    p.ctype  = m.rd8(base + SC_TYPE)
    p.wave   = m.rd32(base + SC_WAVE)
    p.freq   = m.rd32(base + SC_FREQ)
    p.ct     = m.rd32(base + SC_COUNT)
  m.pend_reverb = m.rd8(sound_info + SI_REVERB)
  m.pend_rate   = int(m.rd32(sound_info + SI_PCM_RATE))
  m.pend_period = int(m.rd8(sound_info + SI_DMA_PERIOD))
  m.pend_spv    = int(m.rd16(sound_info + SI_SPV))
  m.pend_cnt    = int(m.rd8(sound_info + SI_DMA_COUNTER))
  # The ring's real length is what pcmDmaCounter cycles through, learnt per
  # configuration: a rate change (Castlevania's intro runs nine 176-byte
  # slots at 10.5 kHz, then two 704-byte slots at 42 kHz in the same half)
  # starts the count over, or the old ring's slots would misplace the new.
  if m.pend_rate != m.cnt_rate or m.pend_spv != m.cnt_spv:
    m.cnt_rate = m.pend_rate
    m.cnt_spv = m.pend_spv
    m.cnt_max = 0
    m.slot_locked = false
    m.slot_off = 0
    m.slot_votes = 0
    m.ring_copy_valid = false
  if m.pend_cnt > m.cnt_max and m.pend_cnt <= 16: m.cnt_max = m.pend_cnt
  if m.cnt_max > m.pend_period: m.pend_period = m.cnt_max
  m.pend_mono = m.fifo_topology()
  m.pend_dma_src = m.gba.dma.src[1]
  m.pend_valid = true
  if m.predict:
    let master = int(m.rd8(sound_info + SI_MASTER_VOL)) + 1
    for i in 0 ..< maxc:
      let p = addr m.pend[i]
      p.pvalid = false
      if (p.status and CH_ON) == 0: continue
      let base = sound_info + uint32(SI_CHANNELS + i * SC_SIZE)
      var ev = int(m.rd8(base + SC_ENV_VOL))
      let atk = int(m.rd8(base + SC_ATTACK))
      let dec = int(m.rd8(base + SC_DECAY))
      let sus = int(m.rd8(base + SC_SUSTAIN))
      let rel = int(m.rd8(base + SC_RELEASE))
      let phase = p.status and CH_ENV
      let echo = int(m.rd8(base + SC_ECHO_VOL))
      let echo_len = int(m.rd8(base + SC_ECHO_LEN))
      # The pass's envelope step (P3, nine vintages): note-on starts at the
      # attack rate; attack adds the rate and clamps at 255 (into decay);
      # decay multiplies by rate/256 down to sustain; a STOP multiplies by
      # the release rate/256 and drops the channel at 0 — unless the note's
      # pseudo-echo volume catches it first: the release then holds at that
      # volume (status IEC) for pseudo-echo-length passes (Beast Shooter's
      # voices; the self-check pins the rule). Applied once for this pass
      # (the bytes checked one hook later) and once more for the next, the
      # far end of the quality tier's continuous envelope.
      proc env_rule(ev, phase: int; status: uint8): (int, int) =
        if (status and CH_START) != 0:
          let e = min(atk, 255)
          (e, (if e >= 255: 2 else: 3))
        elif (status and CH_IEC) != 0:
          # holding at the echo volume; the pass that finds the length at 0
          # drops the channel (rig scenario iec: length 8 holds 8 passes)
          ((if echo_len == 0: 0 else: echo), phase)
        elif (status and CH_STOP) != 0:
          var e = (ev * rel) shr 8
          if echo > 0 and e <= echo: e = echo
          (e, phase)
        elif phase == 3:
          let e = min(ev + atk, 255)
          (e, (if e >= 255: 2 else: 3))
        elif phase == 2:
          var e = (ev * dec) shr 8
          if e <= sus: (sus, 1) else: (e, 2)
        else:
          (ev, phase)
      let (ev1, phase1) = env_rule(ev, int(phase), p.status)
      let (ev2, _) = env_rule(ev1, phase1, p.status and not CH_START)
      ev = ev1
      let mvs = (ev * master) shr 4
      let vr = int(m.rd8(base + SC_VOL_R))
      let vl = int(m.rd8(base + SC_VOL_L))
      # The bytes the driver computes (checked one hook later) and, for the
      # quality tier, the same product without its two truncations: a quiet
      # voice's tail otherwise steps by 5–10 % per frame on the byte grid.
      let mvs_f = float32(ev * master) * (1.0'f32 / 16.0'f32)
      let mvs_f2 = float32(ev2 * master) * (1.0'f32 / 16.0'f32)
      if m.pend_mono != 0:
        p.pr = uint8((mvs * ((vr + vl) shr 1)) shr 8)
        p.pl = 0
        p.prf = mvs_f * float32(vr + vl) * (1.0'f32 / 131072.0'f32)
        p.plf = 0
        p.prf2 = mvs_f2 * float32(vr + vl) * (1.0'f32 / 131072.0'f32)
        p.plf2 = 0
      else:
        p.pr = uint8((mvs * vr) shr 8)
        p.pl = uint8((mvs * vl) shr 8)
        p.prf = mvs_f * float32(vr) * (1.0'f32 / 65536.0'f32)
        p.plf = mvs_f * float32(vl) * (1.0'f32 / 65536.0'f32)
        p.prf2 = mvs_f2 * float32(vr) * (1.0'f32 / 65536.0'f32)
        p.plf2 = mvs_f2 * float32(vl) * (1.0'f32 / 65536.0'f32)
      p.pvalid = true

proc apply_pending(m: Mp2kHle; sound_info: uint32) =
  ## Turn the pending snapshot (the pass that has just run) plus the
  ## envelope that pass left behind into the sampler state for the frame
  ## rendered until the next hook. Timeline (probe ROMs, tools/mp2kprobe,
  ## against the driver's own pcmBuffer): the pass mixes its whole frame
  ## FLAT at the per-side volumes it computes inside the pass — no ramp
  ## from the previous frame, on attack, decay or release — and a note-on
  ## starts at sample 0 of that frame. At the entry hook +0x0A/+0x0B still
  ## hold the PREVIOUS pass's values, so the frame is rendered one hook
  ## late, when its own values are readable; the render then sits one hook
  ## interval behind the pass, which is also the hardware's double-buffer
  ## latency (the DMA reaches the freshly mixed slot one V-blank later).
  m.mono_mode = m.pend_mono
  m.reverb_strength = m.pend_reverb
  m.pcm_sample_rate = m.pend_rate
  m.dbg_reverb = m.reverb_strength
  m.dbg_pcm_rate = m.pcm_sample_rate
  when defined(mp2kwav): dbgMaster = int(m.rd8(sound_info + SI_MASTER_VOL))
  # Reverb frame ring — the shadow of the engine's pcmBuffer slot ring
  # (algorithm and rate rationale: the "MP2K reverb" block in render_sample).
  # pcmDmaPeriod is the ring length in V-blank frames. The ring is maintained
  # whenever engaged, not just while reverb > 0: the real pcmBuffer holds the
  # last pcmDmaPeriod frames unconditionally, so a mid-song reverb-on echoes
  # real history rather than silence.
  m.rev_period = m.pend_period
  if m.rev_period < 1: m.rev_period = 1     # degenerate guard; real drivers
  elif m.rev_period > 16: m.rev_period = 16 # use 2..12 (PCM_DMA_BUF_SIZE/spv)
  # Cells per slot = pcmSamplesPerVBlank: the ring runs at the ENGINE rate.
  m.rev_spv = m.pend_spv
  if m.rev_spv < 16: m.rev_spv = 16
  elif m.rev_spv > MP2K_REV_SLOT_LEN: m.rev_spv = MP2K_REV_SLOT_LEN
  if m.reverb_ring.len != m.rev_period * MP2K_REV_SLOT_LEN * 2:
    m.reverb_ring = newSeq[float32](m.rev_period * MP2K_REV_SLOT_LEN * 2)
  # Slot cursor, derived from pcmDmaCounter the way SoundMain derives its
  # pcmBuffer frame cursor: slot = pcmDmaPeriod - (pcmDmaCounter - 1) when
  # pcmDmaCounter >= 2, else 0. This tracks the real ring phase verbatim,
  # including across skipped mixer passes (probe harness: 0 mismatches
  # against the slot whose bytes changed, over 386 Emerald passes).
  block:
    let cnt = m.pend_cnt
    m.rev_slot = (if cnt <= 1: 0 else: m.rev_period - (cnt - 1))
    if m.rev_slot < 0 or m.rev_slot >= m.rev_period: m.rev_slot = 0
  m.rev_pos = 0
  m.rev_phase = 0
  m.rev_cell = -1
  for i in 0 ..< MP2K_MAX_CHANNELS:
    let s = addr m.samplers[i]
    let p = addr m.pend[i]
    if i >= m.pend_maxc or (p.status and CH_ON) == 0:
      s.active = false
      continue
    let wave = p.wave
    if wave == 0 or (wave shr 24) == 0: # null / bogus pointer
      s.active = false
      continue
    let base = sound_info + uint32(SI_CHANNELS + i * SC_SIZE)
    let live = m.rd8(base + SC_STATUS)
    if not m.predict and (live and CH_ON) == 0 and (p.status and CH_STOP) != 0:
      # The pass killed a note-off with nothing left to release (release
      # rate 0, or the release/pseudo-echo countdown hit zero): it mixed
      # nothing. (A channel whose sample ran out is the other way to go
      # off; that pass mixed the tail, and the sampler ends on its own.)
      s.active = false
      continue
    # +0x0A/+0x0B are the pass's per-side volumes: envelopeVolume *
    # (masterVolume+1)/16 * (rightVolume|leftVolume) >> 8 — masterVolume is
    # folded in, so consume them as-is. The pass's byte per channel is
    # floor(sample * side / 256) (P1: DC 64 at 101 -> 25, 127 at 100 -> 49),
    # so the gain is side/256 on the s8 scale. MONO vintages fold pan away:
    # ONE volume, envelopeVolume * avg(rV, lV) >> 8, at +0x0A and +0x0B
    # left at 0 (observed live) — use it for both sides; the output router
    # then feeds the one fed FIFO. A killed channel keeps its bytes.
    var vr, vl: float32
    var vr_to, vl_to: float32   # quality tier: the next pass's, else unused
    if m.predict and p.pvalid:
      if m.quality:
        vr = p.prf
        vl = (if m.mono_mode != 0: vr else: p.plf)
        vr_to = p.prf2
        vl_to = (if m.mono_mode != 0: vr_to else: p.plf2)
      else:
        vr = float32(p.pr) / 256.0'f32
        vl = (if m.mono_mode != 0: vr else: float32(p.pl) / 256.0'f32)
        vr_to = vr
        vl_to = vl
      if p.pr == 0 and (m.mono_mode != 0 or p.pl == 0) and (p.status and CH_STOP) != 0:
        s.active = false   # released to nothing: the pass drops it
        continue
    else:
      vr = float32(m.rd8(base + SC_ENV_VR)) / 256.0'f32
      vl = (if m.mono_mode != 0: vr
            else: float32(m.rd8(base + SC_ENV_VL)) / 256.0'f32)
      vr_to = vr
      vl_to = vl
    let ctype = p.ctype
    # Mode bits: TYPE_* table. Compressed decode is selected by WaveData.type
    # != 0 under CMP or REV, not by the channel bit alone.
    let reversed   = (ctype and TYPE_REV) != 0
    let compressed = (ctype and (TYPE_CMP or TYPE_REV)) != 0 and
                     m.rd16(wave + 0) != 0'u16
    let loop_status = m.rd16(wave + 2)
    let looping = (loop_status and 0xC000'u16) != 0
    let new_wave_data = wave + 16
    # Note-on = the START bit in the status byte at the entry hook: the
    # sequencer sets it and the mixer consumes it. It MUST restart the
    # sample: a drum pattern re-keys the SAME sample every beat, so keying
    # on wave_data change alone would drop repeated hits while the previous
    # one is still sounding.
    let started = (p.status and CH_START) != 0
    let retrig = started or
                 not s.active or s.wave_data != new_wave_data or
                 s.compressed != compressed or s.reversed != reversed
    when defined(mp2kwav):
      let dumpsel = getEnv("DINGBAT_CHDUMP")
      if (dumpsel == $i or dumpsel == "all") and retrig and dbgRetrigLog < 200:
        echo "ch", i, " st=", toHex(int(p.status), 2),
          " ct=", int(p.ct),
          " evr=", int(m.rd8(base + SC_ENV_VR)),
          " evl=", int(m.rd8(base + SC_ENV_VL)),
          " freq=", int(p.freq),
          " nsamp=", int(m.rd32(wave + 12))
        dbgRetrigLog.inc
      if retrig: inc dbgRetrigCount
    if retrig:
      if m.resync_pending and not started:
        # First applied snapshot after a state/rollback load: the channel is
        # already mid-note in the engine (CH_ON without START) and must not
        # restart from the sample start — an audible burst hardware doesn't
        # produce. Resume at the engine's own position: the mixer sets ct =
        # size - offset at note-on and decrements it per source sample
        # consumed, so size - ct is the forward cursor AND, for a reversed
        # channel (whose start offset is unrecoverable post-hoc — assume 0),
        # the consumed count that reversed src_index tracks.
        s.phase_frac = 0
        s.tap_i = 0xFFFFFFFF'u32
        s.start_off = 0
        s.blk_index = 0xFFFFFFFF'u32
        s.active = true
        s.ended = false
        s.age = 1                       # mid-note: NOT an attack frame
        let total     = m.rd32(wave + 12)          # WaveData.size
        let remaining = p.ct                       # SoundChannel.ct
        s.src_index =
          if remaining >= 1'u32 and remaining <= total: total - remaining
          else: 0'u32
      else:
        # (re)trigger: reset the resampler + decode state to the note's start.
        # SoundChannel.count at note-on is whatever the channel's previous
        # note left there, not a start offset: the driver starts every note
        # at sample 0 (Minish Cap carries such counts on most note-ons and the
        # engine ignored all of them; Emerald's are always 0). The census in
        # tests/mp2k_sweep.nim (start_honoured / start_ignored) keeps watch.
        when defined(mp2kwav):
          s.chk_off = (if started and p.ct < m.rd32(wave + 12): p.ct else: 0'u32)
        s.start_off = 0
        # Forward playback begins at sample 0; reversed playback begins at the
        # END of the data and src_index counts samples consumed.
        s.src_index = 0
        s.phase_frac = 0
        s.tap_i = 0xFFFFFFFF'u32
        s.blk_index = 0xFFFFFFFF'u32
        s.active = true
        s.ended = false
        s.age = 0
    else:
      s.age.inc
      when defined(mp2kwav):
        if s.chk_off != 0'u32 and s.age == 1:
          # One pass after a note-on that carried a count: where did the
          # engine actually start? (see gba.nim dbgStartHonoured)
          let total0 = m.rd32(wave + 12)
          if p.ct >= 1'u32 and p.ct <= total0:
            let epos = int(total0 - p.ct)
            let adv = int(float32(m.pend_spv) * float32(s.freq) / float32(max(m.pcm_sample_rate, 1)))
            let d_hon = abs(epos - (int(s.chk_off) + adv))
            let d_ign = abs(epos - adv)
            if d_hon <= 4 and d_ign > 4: inc dbgStartHonoured
            elif d_ign <= 4 and d_hon > 4: inc dbgStartIgnored
            else: inc dbgStartUnclear
          s.chk_off = 0
      # Continuous position resync against the engine's cursor. Some driver
      # builds keep MORE than the mixer in RAM (ALttP Four Swords: SoundMain
      # itself), so the learned hook can fire a stage BEFORE the sequencer —
      # a note-on then shows a stale SoundChannel.count and the sampler starts
      # thousands of samples off. ct is ground truth on every later pass:
      # consumed = size - ct (same coordinate across the loop reload). Snap
      # only on gross divergence (> 1024 source samples) so resampler jitter
      # and loop-wrap transients never trigger it; a stale note-on is then
      # corrected within one frame, keyed purely on engine state.
      let ctv = p.ct
      let total_sz = m.rd32(wave + 12)
      if ctv >= 1'u32 and ctv <= total_sz:
        let engine_pos = total_sz - ctv
        let our_pos = (if s.reversed: s.start_off + s.src_index
                       else: s.src_index)
        when defined(mp2kwav):
          if getEnv("DINGBAT_POSDUMP") == $i and dbgRetrigLog < 400:
            echo "pos ch", i, " pass=", m.dbg_hook_fires, " engine=", engine_pos,
              " ours=", our_pos, "+", s.phase_frac.formatFloat(ffDecimal, 2),
              " diff=", int(engine_pos) - int(our_pos)
            dbgRetrigLog.inc
        let diff = (if engine_pos > our_pos: engine_pos - our_pos
                    else: our_pos - engine_pos)
        # Snap on a divergence of at least half a pass (a note latched a
        # pass late while the hook still sat before the sequencer stays a
        # pass behind for its whole life otherwise: Castlevania's streamed
        # track); resampler jitter is a sample or two.
        let adv = uint32(float32(m.pend_spv) * float32(p.freq) / float32(max(m.pcm_sample_rate, 1)))
        if diff > max(adv div 2, 32'u32):
          if s.reversed:
            s.src_index = (if engine_pos >= s.start_off:
                             engine_pos - s.start_off else: 0'u32)
          else:
            s.src_index = engine_pos
          s.phase_frac = 0
          s.tap_i = 0xFFFFFFFF'u32
          s.ended = false
          s.blk_index = 0xFFFFFFFF'u32
    s.wave_data   = new_wave_data
    s.compressed  = compressed
    s.reversed    = reversed
    if compressed: m.dbg_compressed_used.inc
    s.use_pcm_rate = (ctype and TYPE_FIX) != 0
    # Resample rate = the CHANNEL's per-note playback frequency (Hz), NOT the
    # sample header's base frequency at wave+4 (a fixed-point value in other
    # units). step = freq / output_rate (P2: 26758 -> every other source
    # sample, 6689 -> each source sample twice, interpolated).
    s.freq        = p.freq
    s.loop_start  = m.rd32(wave + 8)    # WaveData.loopStart
    # WaveData.size = source sample count (P7: a 128-sample wave plays
    # indices 0..127, then the loop returns to loopStart). A reversed channel
    # plays size - offset of them (from data + size - offset DOWN to data[0]).
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
    # Quality tier: the frame runs from this pass's gain to the next pass's
    # (render_one), so the envelope is the continuous curve through the
    # driver's per-frame values — including the run down to zero on the
    # frame before a released note is dropped. A (re)triggered note starts
    # at its attack value, as the driver's does.
    s.vol_l = vl
    s.vol_r = vr
    s.vol_l_to = vl_to
    s.vol_r_to = vr_to
  m.render_frame()

proc fifo_dma(m: Mp2kHle): int =
  ## The sound DMA channel feeding a FIFO (1 or 2), or -1.
  for k in 1 .. 2:
    if m.gba.dma.dmacnt_h[k].enable and m.gba.dma.dmacnt_h[k].start_timing == 3 and
       (m.gba.dma.dmadad[k] == 0x040000A0'u32 or m.gba.dma.dmadad[k] == 0x040000A4'u32):
      return k
  -1

proc ring_slot_bytes(m: Mp2kHle): int =
  ## Bytes per V-blank slot of the sound DMA's ring. Normally
  ## pcmSamplesPerVBlank; Castlevania's driver mixes 704 samples a frame at
  ## 42 kHz but feeds the FIFO from nine 176-byte slots (a 4:1 downsample),
  ## so when period*spv does not fit the half (the two DMA sources' spacing)
  ## the slot is the half split by the period.
  let spv = m.pend_spv
  let period = m.pend_period
  if spv <= 0 or period <= 0: return 0
  if m.gba.dma.dmacnt_h[1].enable and m.gba.dma.dmacnt_h[2].enable and
     m.gba.dma.dmacnt_h[1].start_timing == 3 and m.gba.dma.dmacnt_h[2].start_timing == 3:
    let a = m.gba.dma.dmasad[1]
    let b = m.gba.dma.dmasad[2]
    if b > a and b - a <= 8192'u32 and int(b - a) < spv * period:
      return int(b - a) div period
  spv

proc dma_rate(m: Mp2kHle; slot_bytes: int): float32 =
  ## Samples per second the DMA replays: one slot per V-blank.
  float32(slot_bytes) * float32(APU_SAMPLE_RATE) / 548.625'f32

proc pipeline_src(m: Mp2kHle): float32 =
  ## The residual FIFO pipeline in DMA-rate samples (MP2K_FIFO_PIPELINE;
  ## MP2K_FIFO_PIPELINE_FAST above MP2K_FIFO_FAST_RATE). -d:mp2kwav builds
  ## take DINGBAT_MP2K_PIPE_SRC=<n> for A/B sweeps.
  when defined(mp2kwav):
    let fixed = getEnv("DINGBAT_MP2K_PIPE_SRC")
    if fixed.len > 0: return float32(parseFloat(fixed))
  let sb = m.ring_slot_bytes()
  if sb > 0 and m.dma_rate(sb) >= MP2K_FIFO_FAST_RATE: MP2K_FIFO_PIPELINE_FAST
  else: MP2K_FIFO_PIPELINE

proc pipeline_apu(m: Mp2kHle; sb: int): float32 =
  ## Cursor-to-DAC in APU samples for the phase estimate (hw_latency): a
  ## byte the cursor has just passed sits about a refill deep in the queue.
  (float32(MP2K_FIFO_REFILL) + m.pipeline_src()) * float32(APU_SAMPLE_RATE) / m.dma_rate(sb)

proc hw_latency(m: Mp2kHle): int =
  ## The hardware's pass-to-DAC latency in APU samples, from where the sound
  ## DMA's replay cursor sits in the pcmBuffer ring at the hook: the samples
  ## it still has to replay before it reaches the slot this pass fills, plus
  ## the FIFO pipeline (the DMA moves 16 bytes at a time into a 32-byte
  ## FIFO). Measured against the real stream: Emerald 553 = 208 + 18 source
  ## samples, Minish Cap 228 = 88 + 22. 0 = unknown (no FIFO DMA yet).
  let period = m.pend_period
  let sb = m.ring_slot_bytes()
  if sb <= 0 or period <= 0: return 0
  let c = m.fifo_dma()
  if c < 0: return 0
  let base = m.gba.dma.dmasad[c]
  let src = (if c == 1: m.pend_dma_src else: m.gba.dma.src[c])
  if src < base: return 0
  let ring = period * sb
  let off = int(src - base)
  if off >= ring: return 0
  let cnt = m.pend_cnt
  let slot = ((if cnt <= 1: 0 else: period - (cnt - 1)) + m.slot_off) mod period
  let ahead = ((slot * sb - off) mod ring + ring) mod ring
  int(float32(ahead) * float32(APU_SAMPLE_RATE) / m.dma_rate(sb) + m.pipeline_apu(sb))

proc learn_slot_offset(m: Mp2kHle) =
  ## Which ring slot the pass writes, against the counter formula. The DMA
  ## half is snapshotted at every hook and diffed at the next: exactly one
  ## slot changing names the previous pass's slot. Castlevania's driver
  ## writes two slots ahead of the formula (its 42 kHz mix is downsampled
  ## into the ring later); Emerald, Minish Cap, Ochaken write the formula's
  ## slot. Eight agreeing votes lock the offset.
  if m.slot_locked: return
  let sb = m.ring_slot_bytes()
  let period = m.pend_period
  if sb <= 0 or period <= 0 or sb * period > m.ring_copy.len: return
  let c = m.fifo_dma()
  if c < 0: return
  let base = m.gba.dma.dmasad[c]
  let n = sb * period
  if m.ring_copy_valid:
    var changed = -1
    var nchanged = 0
    for s in 0 ..< period:
      var diff = false
      for i in s * sb ..< (s + 1) * sb:
        if m.gba.bus.read_byte_internal(base + uint32(i)) != m.ring_copy[i]:
          diff = true
          break
      if diff:
        inc nchanged
        changed = s
    if nchanged == 1 and m.ring_prev_slot >= 0:
      let off = (changed - m.ring_prev_slot + period) mod period
      if off == m.slot_off_vote:
        inc m.slot_votes
        if m.slot_votes >= 8:
          m.slot_off = off
          m.slot_locked = true
      else:
        m.slot_off_vote = off
        m.slot_votes = 1
  for i in 0 ..< n: m.ring_copy[i] = m.gba.bus.read_byte_internal(base + uint32(i))
  m.ring_copy_valid = true
  let cnt = m.pend_cnt
  m.ring_prev_slot = (if cnt <= 1: 0 else: period - (cnt - 1))

proc measure_latency(m: Mp2kHle) =
  ## Called at every hook after snapshot_pass. Remembers the start address
  ## of the slot this pass fills and, at later hooks, watches for the sound
  ## DMA's replay cursor to cross it: the APU samples from that pass's hook
  ## to the crossing, less the cursor's overshoot, is the latency the
  ## hardware gives that pass, whatever the vintage's DMA arrangement
  ## (Emerald lets the DMA run round the ring, Ochaken reprograms it every
  ## V-blank). Averaged; hw_latency's phase estimate seeds the FIFO target
  ## until enough crossings are in.
  let c = m.fifo_dma()
  let sb = m.ring_slot_bytes()
  if c < 0 or sb <= 0: return
  let base = m.gba.dma.dmasad[c]
  let ring = uint32(m.pend_period * sb)
  let cur = m.gba.dma.src[c]
  if cur < base or cur - base >= ring: return
  let curoff = cur - base
  let prevoff = (if m.lat_prev_src >= base and m.lat_prev_src - base < ring: m.lat_prev_src - base
                 else: curoff)
  m.lat_prev_src = cur
  # resolve pending slots: crossed when the start lies in (prev, cur]
  let moved = (curoff + ring - prevoff) mod ring
  let rate = m.dma_rate(sb)
  let src_cycles = float32(CPU_CLOCK_SPEED) / rate          # cycles per source sample
  let now_cyc = int64(m.gba.scheduler.cycles)
  var i = 0
  while i < m.lat_n:
    let start = m.lat_slot[i]
    let dist = (curoff + ring - start) mod ring      # cursor past the start by this much
    let waited = now_cyc - m.lat_at[i]
    if moved > 0'u32 and dist < moved:
      # The cursor moves a refill at a time, so the transfer that carried
      # byte `start` began at the refill grid below it, `n` transfers before
      # the last one (whose cycle the DMA recorded); the transfers are a
      # refill of timer periods apart. That byte then sits queue-deep in the
      # FIFO behind the 15 the refill found there.
      # A vintage that reprograms the DMA every V-blank (Estopolis, Metal
      # Max, Beast Shooter, Super Dodgeball) is seen with the cursor AT the
      # slot start: the transfer carrying it is the NEXT one (n = -1). The
      # transfers keep their cadence across the restart — the FIFO's refill
      # requests are the timer's, not the DMA's. (Until 2026-09-14 that
      # case computed n = ring/16 - 1, a negative latency, and was dropped,
      # so those titles never measured and stayed on the seed.)
      let xoff = start - (start mod MP2K_FIFO_REFILL)
      let past = (curoff + ring - xoff) mod ring
      let n = (if past == 0'u32: -1 else: int((past - MP2K_FIFO_REFILL) div MP2K_FIFO_REFILL))
      let cross = float32(m.gba.dma.fifo_xfer_cycle[c] - m.lat_at[i]) -
                  float32(n) * float32(MP2K_FIFO_REFILL) * src_cycles
      let queue = float32(MP2K_FIFO_REFILL - 1) + float32(start - xoff) + m.pipeline_src()
      let lat = cross / float32(APU_SAMPLE_PERIOD) +
                queue * float32(APU_SAMPLE_RATE) / rate
      when defined(mp2kwav):
        if getEnv("DINGBAT_LATDUMP") == "1" and dbgLatDump < 40:
          inc dbgLatDump
          echo "lat start=", start, " curoff=", curoff, " prevoff=", prevoff, " xoff=", xoff, " n=", n,
               " xfer-now=", m.gba.dma.fifo_xfer_cycle[c] - now_cyc, " hook-now=", m.lat_at[i] - now_cyc,
               " cross=", cross, " queue=", queue, " lat=", lat, " ring=", ring, " sb=", sb
      if lat > 0:
        if m.lat_count == 0: m.lat_avg = lat
        else: m.lat_avg += (lat - m.lat_avg) * 0.125'f32
        inc m.lat_count
      # drop entry i
      for j in i ..< m.lat_n - 1:
        m.lat_slot[j] = m.lat_slot[j + 1]
        m.lat_at[j] = m.lat_at[j + 1]
      dec m.lat_n
    elif waited > 6 * 550 * int64(APU_SAMPLE_PERIOD):
      for j in i ..< m.lat_n - 1:
        m.lat_slot[j] = m.lat_slot[j + 1]
        m.lat_at[j] = m.lat_at[j + 1]
      dec m.lat_n
    else:
      inc i
  # remember this pass's slot
  let cnt = m.pend_cnt
  let slot = ((if cnt <= 1: 0 else: m.pend_period - (cnt - 1)) + m.slot_off) mod m.pend_period
  if m.lat_n < m.lat_slot.len:
    m.lat_slot[m.lat_n] = uint32(slot * sb)
    m.lat_at[m.lat_n] = int64(m.gba.scheduler.cycles)
    inc m.lat_n

proc check_predictions(m: Mp2kHle; sound_info: uint32) =
  ## One hook after a predicted pass its per-side bytes are readable:
  ## count hits and misses (channels the pass dropped cannot be checked),
  ## and abandon prediction for this session once at least eight misses
  ## make up more than 5 % of the checks (a vintage whose sequencer runs
  ## after the hook, like EZ-Talk's, misses on every note-on and note-off;
  ## a game that pokes a channel struct itself misses once).
  for i in 0 ..< m.pend_maxc:
    let p = addr m.pend[i]
    let base = sound_info + uint32(SI_CHANNELS + i * SC_SIZE)
    let st = m.rd8(base + SC_STATUS)
    # A note is first seen at a hook with START set: the sequencer raised it
    # and the mixer, which clears START as it initialises the channel, has
    # not run yet. A channel that was off at the last hook and is now ON
    # without START was started by a sequencer that ran AFTER that hook — the
    # hook sits before the pass's sequencer (SoundMain in RAM: EZ-Talk,
    # Castlevania), and every note-on reaches the render a frame late.
    # Three sightings move the hook to the pass's next call target.
    if (p.status and CH_ON) == 0 and (st and CH_ON) != 0 and (st and CH_START) == 0:
      inc m.seq_late
    if not p.pvalid: continue
    # Re-triggered by the next sequencer run, or dropped by the pass (a
    # kill, or the sample running out): the bytes are stale, nothing to check
    if (st and CH_START) != 0 or (st and CH_ON) == 0: continue
    let r = int(m.rd8(base + SC_ENV_VR))
    let l = int(m.rd8(base + SC_ENV_VL))
    if abs(r - int(p.pr)) <= 1 and (m.pend_mono != 0 or abs(l - int(p.pl)) <= 1):
      inc m.pred_ok
    else:
      inc m.pred_bad
      when defined(mp2kwav):
        if getEnv("DINGBAT_PREDDUMP") == "1" and m.pred_bad <= 40:
          echo "predmiss ch", i, " snap st=", toHex(int(p.status), 2), " pred r", int(p.pr), " l", int(p.pl),
            " actual r", r, " l", l, " now st=", toHex(int(m.rd8(base + SC_STATUS)), 2),
            " ev=", int(m.rd8(base + SC_ENV_VOL)),
            " a", int(m.rd8(base + SC_ATTACK)), " d", int(m.rd8(base + SC_DECAY)),
            " s", int(m.rd8(base + SC_SUSTAIN)), " r", int(m.rd8(base + SC_RELEASE)),
            " rV", int(m.rd8(base + SC_VOL_R)), " lV", int(m.rd8(base + SC_VOL_L)),
            " +C..F ", int(m.rd8(base + 0x0C)), "/", int(m.rd8(base + 0x0D)), "/", int(m.rd8(base + 0x0E)), "/", int(m.rd8(base + 0x0F)),
            " +10..13 ", int(m.rd8(base + 0x10)), "/", int(m.rd8(base + 0x11)), "/", int(m.rd8(base + 0x12)), "/", int(m.rd8(base + 0x13))
  let failed = m.pred_bad >= 8 and m.pred_bad * 20 > m.pred_ok + m.pred_bad
  let late = m.seq_late >= 2 and not m.seq_locked
  if (failed or late) and m.cand_idx + 1 < m.cand_pick_n:
    # The hook sits before this pass's sequencer (SoundMain in RAM: EZ-Talk
    # misses its note-ons and note-offs in the envelope check, Castlevania's
    # streamed track only in the START check): move to the next call target
    # of the pass and try again.
    inc m.cand_idx
    m.hook_addr  = m.cand[m.cand_pick[m.cand_idx]]
    m.entry_addr = m.hook_addr and not 1'u32
    m.pred_ok = 0
    m.pred_bad = 0
    m.seq_late = 0
    m.pend_valid = false
    m.resync_pending = true      # re-latch every channel from the new vantage
    m.gba.refresh_hle_hook()
  elif failed:
    if m.cand_idx > 0:
      # A later candidate did not predict either. Back to the entry, still
      # predicting: the START sightings that moved us were the game's own
      # (a channel it starts outside the sequencer), so they no longer count.
      m.cand_idx = 0
      m.hook_addr  = m.cand[m.cand_pick[0]]
      m.entry_addr = m.hook_addr and not 1'u32
      m.pred_ok = 0
      m.pred_bad = 0
      m.seq_late = 0
      m.seq_locked = true
      m.pend_valid = false
      m.gba.refresh_hle_hook()
    else:
      m.predict = false

proc on_frame(m: Mp2kHle; sound_info: uint32) =
  ## Called once per mixer pass (at the learned hook, before the real mixer
  ## runs). Predictive mode: snapshot this pass, predict the envelope it is
  ## about to compute (snapshot_pass), render its frame now and let the FIFO
  ## hold it until the hardware would play it (hw_latency); the prediction
  ## is checked against the real bytes at the next hook. Otherwise (a
  ## vintage whose envelope rule the prediction misses) the PREVIOUS pass's
  ## frame is rendered from its snapshot and the bytes it left behind, one
  ## hook late — which on Emerald is also the hardware's latency.
  var done = false
  if m.predict:
    if m.pend_valid: m.check_predictions(sound_info)
    if m.predict:
      m.snapshot_pass(sound_info)
      m.learn_slot_offset()
      m.measure_latency()
      m.fifo_target = max((if m.lat_count >= 4: int(m.lat_avg) else: m.hw_latency()), MP2K_FIFO_GUARD)
      m.apply_pending(sound_info)
      m.resync_pending = false
      done = true
    else:
      # falsified just now: late mode from this hook on
      m.pend_valid = false
  if not done:
    if m.pend_valid:
      m.fifo_target = MP2K_FIFO_GUARD
      m.apply_pending(sound_info)
      m.resync_pending = false   # one full re-latch pass done; back to normal keying
    else:
      for i in 0 ..< MP2K_MAX_CHANNELS: m.samplers[i].active = false
    m.snapshot_pass(sound_info)
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
      # pcmDmaPeriod <= 16 frames; our FIFO holds about 1): a song-stop drain
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
  when defined(mp2kwav):
    block:
      let c = m.fifo_dma()
      if c > 0:
        let base = m.gba.dma.dmasad[c]
        dbgHookRing.setLen(0)
        for i in 0 ..< 1584: dbgHookRing.add m.rd8(base + uint32(i))
    dbgHookDmaSrc.add m.gba.dma.src[1]
    dbgHookDmaSrc2.add m.gba.dma.src[2]
    dbgHookSad.add m.gba.dma.dmasad[1]
    dbgHookSad2.add m.gba.dma.dmasad[2]
    dbgHookCnt.add int(m.rd8(sound_info + SI_DMA_COUNTER))
  m.frame_seen = true
  m.engaged = true
  m.hook_stale = 0           # the mixer demonstrably ran this frame

proc mixer_hook*(m: Mp2kHle) =
  ## PC-hook entry, called from cpu.tick when r15 reaches the learned mixer
  ## entry. With the engine lock held, refresh the mixer state (the channel
  ## status still carries START here: snapshot_pass). Without it the learned PC
  ## was wrong ("Runtime detection"): unlearn and re-probe.
  let sip = m.rd32(MP2K_SOUNDINFO_PTR_ADDR)
  if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
    let ident = m.rd32(sip + SI_MAGIC)
    if ident == MP2K_IDENT_LOCK or ident == MP2K_IDENT_LOCK_VOFF:
      inc m.fires_this_frame
      if m.fires_this_frame == 1: m.on_frame(sip)
      return
  m.unlearn_hook()

proc lr_taken(m: Mp2kHle; lr: uint32): bool =
  ## A return address already owned by a candidate: lr keeps its value through
  ## the whole callee, so every later instruction of it would look like a
  ## call target otherwise.
  for i in 0 ..< m.cand_n:
    if m.cand_lr[i] == lr: return true
  false

proc looks_called(m: Mp2kHle; pc: uint32): bool =
  ## Is the instruction about to execute the target of a call? At a function
  ## entry lr holds the return address, so the instruction before it is the
  ## call. Forms seen in the library:
  ##   * Thumb BL (pair at lr-4/lr-2) whose target is this PC;
  ##   * Thumb BL to a `bx rN` stub (the compiler's call through a function
  ##     pointer, how SoundMain reaches the mixer in RAM): the target is not
  ##     recoverable, so the return address must be new;
  ##   * `mov lr, pc; bx rN` (lr even, from Thumb): same, by return address;
  ##   * ARM BL whose target is this PC, or a `bx rN` stub.
  let lr = m.gba.cpu.r[14]
  let target = pc and not 1'u32
  if (lr and 1'u32) != 0:
    let ra = lr and not 1'u32
    let h = m.rd16(ra - 2'u32)
    if (h and 0xF800'u16) != 0xF800'u16: return false
    let hi = m.rd16(ra - 4'u32)
    if (hi and 0xF800'u16) != 0xF000'u16: return false
    var off = (uint32(hi and 0x7FF'u16) shl 12) or (uint32(h and 0x7FF'u16) shl 1)
    if (off and 0x400000'u32) != 0: off = off or 0xFF800000'u32
    let dest = ra + off
    if dest == target: return true
    if (m.rd16(dest) and 0xFF87'u16) == 0x4700'u16: return not m.lr_taken(lr)
    return false
  let h = m.rd16(lr - 2'u32)
  if (h and 0xFF87'u16) == 0x4700'u16 and m.rd16(lr - 4'u32) == 0x46FE'u16:
    return not m.lr_taken(lr)
  let w = m.rd32(lr - 4'u32)
  if (w and 0x0F000000'u32) != 0x0B000000'u32: return false
  var off = (w and 0x00FFFFFF'u32) shl 2
  if (off and 0x02000000'u32) != 0: off = off or 0xFC000000'u32
  let dest = lr + 4'u32 + off
  if dest == target: return true
  if (m.rd32(dest) and 0x0FFFFFF0'u32) == 0x012FFF10'u32: return not m.lr_taken(lr)
  false

proc probe_pass_end(m: Mp2kHle): bool =
  ## A probed pass ended: tally which candidates it hit. After eight passes
  ## the candidates that fired in every pass are ranked in pass order and
  ## the first is hooked (a helper the mixer calls only on some passes drops
  ## out). Returns true once a hook is chosen.
  var any = false
  for i in 0 ..< m.cand_n:
    if m.cand_seen[i]:
      inc m.cand_hits[i]
      m.cand_seen[i] = false
      any = true
  m.probe_order = 0
  if any: inc m.probe_passes
  if m.probe_passes >= 8:
    # Candidates that fired in every pass, in the order they come within a
    # pass. The FIRST is the mixer entry on every vintage probed (Emerald,
    # Minish Cap, ...: SoundMainRAM; helpers it calls come later). A
    # vintage whose first candidate is SoundMain itself (EZ-Talk) fails
    # the prediction check there, and check_predictions moves to the next
    # candidate — the mixer proper — before giving up.
    var best_hits = 0
    for i in 0 ..< m.cand_n:
      if m.cand_hits[i] > best_hits: best_hits = m.cand_hits[i]
    m.cand_pick_n = 0
    for order in 0 ..< m.cand_n:
      for i in 0 ..< m.cand_n:
        if m.cand_hits[i] == best_hits and m.cand_order[i] == order and m.cand_pick_n < m.cand_pick.len:
          m.cand_pick[m.cand_pick_n] = i
          inc m.cand_pick_n
    if m.cand_pick_n > 0:
      m.cand_idx = 0
      let pc = m.cand[m.cand_pick[0]]
      m.probe_passes = 0
      m.hook_addr  = pc                            # pc may carry the Thumb bit; the
      m.entry_addr = pc and not 1'u32              # hook compare uses it verbatim
      m.probing = false
      m.fires_this_frame = 0
      m.gba.refresh_hle_hook()
      return true
  false

proc probe_pc*(m: Mp2kHle; pc: uint32) {.noinline.} =
  ## Learning probe, called from cpu.tick only while probing is armed and only
  ## for RAM-fetched instructions with r0 == &SoundInfo (both prefiltered
  ## inline). While the lock is held, every such instruction that is a call
  ## target is a candidate for the mixer entry; the frame poll picks the LAST
  ## one of the pass. Vintages that keep SoundMain itself in RAM (EZ-Talk)
  ## enter it first, run the sequencer, then call the mixer: hooking the
  ## first candidate would see the channel table before that pass's
  ## note-ons and note-offs.
  let ident = m.rd32(m.probe_sound_info + SI_MAGIC)
  inc m.dbg_probe_hits
  m.dbg_probe_ident = ident
  if ident != MP2K_IDENT_LOCK and ident != MP2K_IDENT_LOCK_VOFF: return
  for i in 0 ..< m.probe_block_n:
    if m.probe_block[i] == pc: return          # previously invalidated
  for i in 0 ..< m.cand_n:
    if m.cand[i] == pc:
      if m.cand_seen[i]:
        # An entry is called once per pass: seeing it again is the next
        # pass, on a game whose passes never end at an idle frame poll.
        if m.probe_pass_end(): return
      m.cand_seen[i] = true
      m.cand_order[i] = m.probe_order
      inc m.probe_order
      return
  if not m.looks_called(pc):
    when defined(mp2kwav):
      if dbgProbeMiss.len < 64:
        let lr = m.gba.cpu.r[14]
        dbgProbeMiss.add (pc, lr, m.rd32(lr - 4'u32))
    return
  if m.cand_n < m.cand.len:
    m.cand[m.cand_n] = pc
    m.cand_lr[m.cand_n] = m.gba.cpu.r[14]
    m.cand_seen[m.cand_n] = true
    m.cand_order[m.cand_n] = m.probe_order
    m.cand_hits[m.cand_n] = 0
    inc m.probe_order
    inc m.cand_n

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
    # A mixer entry fires once per pass (a game may run two passes in a
    # frame); a PC that fired more often is a helper inside the mixer, run
    # per channel: invalidate it and pick again.
    if m.fires_this_frame > 3:
      m.unlearn_hook()
      m.fires_this_frame = 0
      m.probing = (ident == MP2K_IDENT_IDLE or ident == MP2K_IDENT_IDLE_VOFF) and
                  m.probe_fails < MP2K_PROBE_MAX_FAILS
      if m.probing: m.probe_sound_info = sip
      m.gba.refresh_hle_hook()
      return
    m.fires_this_frame = 0
    # Frames since the hook last fired (mixer_live); on_frame zeroes it.
    if m.engaged and m.hook_stale < 1000'i32: inc m.hook_stale
    return
  # A probed pass ended (the lock is released): tally it.
  if m.probing and (ident == MP2K_IDENT_IDLE or ident == MP2K_IDENT_IDLE_VOFF):
    if m.probe_pass_end(): return
  # Arm probing only when the engine is at rest (ident == ID_NUMBER, in
  # either VSync form): arming mid-pass could learn a mid-mixer PC instead of
  # the entry. Once candidates are being collected, stay armed whatever the
  # poll sees: a driver whose ident reads locked at every V-blank (BB Ball)
  # delimits its passes by re-sighting an entry, not by an idle poll.
  if m.probing and m.cand_n > 0 and m.probe_fails < MP2K_PROBE_MAX_FAILS:
    return
  m.probing = (ident == MP2K_IDENT_IDLE or ident == MP2K_IDENT_IDLE_VOFF) and
              m.probe_fails < MP2K_PROBE_MAX_FAILS
  if m.probing: m.probe_sound_info = sip

proc catmull_rom(p0, p1, p2, p3, mu: float32): float32 {.inline.} =
  ## Catmull-Rom spline between p1 and p2 (mu in 0..1); p0/p3 are the
  ## neighbouring samples.
  let mu2 = mu * mu
  0.5'f32 * (2.0'f32 * p1 + (p2 - p0) * mu +
             (2.0'f32 * p0 - 5.0'f32 * p1 + 4.0'f32 * p2 - p3) * mu2 +
             (3.0'f32 * p1 - p0 - 3.0'f32 * p2 + p3) * mu2 * mu)

proc src_at(m: Mp2kHle; s: ptr Mp2kSampler; rom: ptr seq[byte]; rmask: uint32;
            pos: int64): float32 {.inline.} =
  ## Source sample at a play position that may lie outside the data: before
  ## the note there is silence, past the end a looping sample wraps and a
  ## one-shot reads silence — the driver's linear interpolation runs toward
  ## the loop target at the wrap (P7: 127 -> 96) and toward zero at the end.
  if pos < 0: return 0
  if pos >= int64(s.sample_count):
    if s.looping and s.loop_start < s.sample_count:
      let span = int64(s.sample_count - s.loop_start)
      return m.decode_at(s, rom, rmask, uint32(int64(s.loop_start) + (pos - int64(s.sample_count)) mod span))
    return 0
  m.decode_at(s, rom, rmask, uint32(pos))

proc fetch_taps(m: Mp2kHle; s: ptr Mp2kSampler; rom: ptr seq[byte]; rmask: uint32) {.inline.} =
  ## taps = play positions cursor-MP2K_TAP_OFF .. cursor+8 (the kernel is
  ## centred on the cursor: the output at phase mu lies between
  ## taps[MP2K_TAP_OFF] and the next, so a voice lands where the driver's
  ## does — P2: the driver's impulse at source index 200 answers at the
  ## same index). A one-step advance shifts and fetches one; anything else
  ## refetches the window.
  let i = s.src_index
  if s.tap_i != 0xFFFFFFFF'u32 and i > s.tap_i and i - s.tap_i < uint32(MP2K_TAPS):
    # advanced by d < window: shift, fetch the d new positions at the end
    let d = int(i - s.tap_i)
    for t in 0 ..< MP2K_TAPS - d: s.taps[t] = s.taps[t + d]
    for t in MP2K_TAPS - d ..< MP2K_TAPS:
      s.taps[t] = m.src_at(s, rom, rmask, int64(i) + int64(t) - int64(MP2K_TAP_OFF))
  else:
    for t in 0 ..< MP2K_TAPS:
      s.taps[t] = m.src_at(s, rom, rmask, int64(i) + int64(t) - int64(MP2K_TAP_OFF))
  s.tap_i = i

proc advance_cursor(s: ptr Mp2kSampler; step: float32) =
  ## Move the read cursor by `step` source samples. A looping sample wraps
  ## modulo its loop length; a one-shot (or reversed — its driver path never
  ## consults the loop registers) sample goes silent at its end, as the
  ## driver's does (P7: the frame's remaining bytes are 0 and the channel
  ## is then dropped).
  let p = s.phase_frac + step
  let whole = uint32(p)
  s.phase_frac = p - float32(whole)
  if whole == 0'u32: return
  s.src_index += whole
  if s.src_index < s.sample_count: return
  if s.looping and not s.reversed and s.loop_start < s.sample_count:
    let span = s.sample_count - s.loop_start
    s.src_index = s.loop_start + (s.src_index - s.sample_count) mod span
    s.tap_i = 0xFFFFFFFF'u32   # the run of positions broke: refetch
  else:
    s.ended = true

proc render_one(m: Mp2kHle): tuple[a: float32, b: float32] =
  ## One (FIFO A, FIFO B) sample of the frame being rendered, in the FIFO
  ## latch range (twice the driver's s8 byte) so the APU's DirectSound
  ## scaling applies. Per channel: four source samples around a fractional
  ## cursor, interpolated (cubic by default; the driver itself is linear —
  ## P2 — and `resample_mode` 1/2 select linear/hold for parity checks).
  ##
  ## Quality tier (m.quality, the default; off for parity checks): the
  ## render matches the driver's envelopes, gains and timing but not its
  ## arithmetic, where that arithmetic is a limit of the hardware rather
  ## than the music — three deliberate departures, each sub-LSB or sub-frame
  ## on the driver's scale:
  ##   * gains run linearly across the frame from this pass's value to the
  ##     next pass's, predicted by the same rules — the continuous envelope
  ##     through the driver's per-V-blank values (the driver mixes each
  ##     pass flat; a decaying note's staircase is a 60 Hz buzz on
  ##     hardware), and they are the exact written product, not the
  ##     driver's twice-truncated byte;
  ##   * the echo seed is interpolated between engine-rate cells instead
  ##     of held (the hold is the DMA/DAC's zero-order replay);
  ##   * the sample is not truncated to the FIFO's integer latch — the
  ##     remainder rides in fine_a/fine_b past the 10-bit DAC (apu.nim).
  var accl = 0.0'f32
  var accr = 0.0'f32
  let rom = addr m.gba.cartridge.rom
  let rmask = m.gba.cartridge.rom_mask
  let cubic = m.use_cubic
  for i in 0 ..< MP2K_MAX_CHANNELS:
    let s = addr m.samplers[i]
    if not s.active or s.ended: continue
    if s.tap_i != s.src_index:
      m.fetch_taps(s, rom, rmask)
    var sample: float32
    let rate0 = (if s.use_pcm_rate: float32(m.pcm_sample_rate) else: float32(s.freq))
    const T = MP2K_TAP_OFF
    if m.resample_mode == 2:
      sample = s.taps[T]                    # hold
    elif m.resample_mode == 1 or not cubic:
      sample = s.taps[T] + (s.taps[T + 1] - s.taps[T]) * s.phase_frac
    elif m.quality:
      # Quality tier: windowed sinc, stretched by the playback step
      # (sinc_sample) — the sample's own band, no images, no aliasing.
      sample = sinc_sample(s, rate0 / float32(APU_SAMPLE_RATE))
    else:
      sample = catmull_rom(s.taps[T - 1], s.taps[T], s.taps[T + 1], s.taps[T + 2], s.phase_frac)
    # s8 units in, the driver's per-channel byte out: sample * side / 256.
    # Quality tier: the gain runs linearly across the frame from this
    # pass's value to the next pass's predicted one.
    var gl = s.vol_l
    var gr = s.vol_r
    if m.quality and m.frame_n > 0:
      let k = float32(m.ramp_i) / float32(m.frame_n)
      gl = s.vol_l + (s.vol_l_to - s.vol_l) * k
      gr = s.vol_r + (s.vol_r_to - s.vol_r) * k
    let cl = sample * gl
    let cr = sample * gr
    accl += cl
    accr += cr
    when defined(mp2kwav):
      let sn = sample / 128.0'f32
      dbgVoiceRawSq[i] += float64(sn) * float64(sn)
      dbgVoiceRawPk[i] = max(dbgVoiceRawPk[i], abs(sn))
      dbgVoiceOutSq[i] += float64(cl)*float64(cl) + float64(cr)*float64(cr)
      dbgVoiceOutPk[i] = max(dbgVoiceOutPk[i], max(abs(cl), abs(cr)))
      dbgVoiceN[i].inc
      dbgVoiceComp[i] = s.compressed
      let k = (if s.compressed: 1 else: 0)
      dbgKindRawSq[k] += float64(sn) * float64(sn)
      dbgKindRawPk[k] = max(dbgKindRawPk[k], abs(sn))
      dbgKindN[k].inc
      if s.age == 0:            # attack frame (first frame after note-on)
        dbgAttackSq += float64(cl)*float64(cl) + float64(cr)*float64(cr)
        dbgAttackPk = max(dbgAttackPk, max(abs(cl), abs(cr)))
        dbgAttackN.inc
    # Advance the resample phase; step = playback-rate / output-rate, where a
    # TYPE_FIX channel's playback rate is pcmFreq (TYPE_* table).
    let rate = rate0
    when defined(mp2kwav):
      dbgStepN.inc
      if rate > float32(APU_SAMPLE_RATE):
        dbgStepDecimN.inc
        dbgStepMax = max(dbgStepMax, rate/float32(APU_SAMPLE_RATE))
    s.advance_cursor(rate / float32(APU_SAMPLE_RATE))
  # --- MP2K reverb: the driver's buffer-seed echo (canonical) -------------------
  # Driver behaviour, observed at runtime (loveemu's summary: "a simple
  # reverb (echo) effect with fixed delay"). pcmBuffer is two s8 halves, one
  # per FIFO, each a ring of pcmDmaPeriod one-V-blank slots; the slot the
  # mixer is about to fill holds the audio mixed pcmDmaPeriod V-blanks ago —
  # the frame the DMA just finished playing (slot cursor: apply_pending).
  # Before any voice is mixed the driver seeds that slot, sample by sample:
  # it sums the four signed bytes at the same index in both halves of the
  # slot being overwritten and of the following slot (one frame younger,
  # wrapping to slot 0), scales the sum by reverb/512, rounds negative
  # results one LSB toward zero, and stores the one mono result to both
  # halves. Voices are accumulated on top, so the stored slot is the wet
  # frame and the seed is the feedback path: a two-tap (P and P-1 frames)
  # feedback comb with gain reverb/512 per sample pair, stable for reverb
  # <= 127. With reverb == 0 the slot is zero-filled and holds the dry mix.
  # (P6, reverb 64, period 7: an impulse of 50 echoes as 12 at 6 and 7
  # frames, then 3 / 6 / 3 at 12 / 13 / 14 — this model to the byte.)
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
  # real FIFO). Floats are on the s8-buffer scale (a voice contributes
  # sample * side/256, the driver's byte), so the seed is sum * reverb/512.
  # Omitted, each sub-LSB on the s8 scale: the negative nudge and the s8
  # store quantization/wrap. MONO vintages keep the same formula: both sides
  # are identical, so the four-read sum degrades to 2*(cur + next) with the
  # same /512.
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
      m.rev_seed_prev = m.rev_seed
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
    var seed = m.rev_seed
    if m.quality:
      # Interpolate the echo between cells rather than hold it: the hold is
      # the DMA/DAC's zero-order replay, not part of the music.
      let frac = clamp(m.rev_phase - float32(i), 0.0'f32, 1.0'f32)
      seed = m.rev_seed_prev + (m.rev_seed - m.rev_seed_prev) * frac
    outl_f = accl + seed
    outr_f = accr + seed
    m.rev_phase += float32(m.pcm_sample_rate) * (1.0'f32 / float32(APU_SAMPLE_RATE))
    m.rev_pos.inc
  # The FIFO latch is the driver's s8 byte doubled. The driver's buffer
  # wraps past the s8 range (P10: three full-scale voices sum to 150 and
  # come out -106), which no game relies on; clamp there instead. The value
  # stays fractional here; render_sample truncates it to the latch.
  let li = clamp(outl_f * 2.0'f32, -256.0'f32, 254.0'f32)
  let ri = clamp(outr_f * 2.0'f32, -256.0'f32, 254.0'f32)
  m.dbg_out_energy += abs(outl_f) + abs(outr_f)
  m.dbg_out_count.inc
  # The result is (FIFO A, FIFO B). The driver's FIRST pcmBuffer half — the
  # one DMA1 feeds FIFO A from — carries the RIGHT-volume mix and the second
  # the left (P5: a hard-left pan puts the note in the second half only, and
  # the game's SOUNDCNT_H routes A right / B left), so the speakers come
  # out right only if A gets the +0x0A mix. A mono driver's other FIFO never
  # receives data on hardware, so it gets silence — the game may still have
  # it routed to a speaker.
  var fa = ri
  var fb = li
  case m.mono_mode
  of 1: fb = 0              # mono via FIFO A (fa == fb already; B silent)
  of 2: fa = 0              # mono via FIFO B
  else: discard
  inc m.ramp_i
  (fa, fb)

proc render_frame(m: Mp2kHle) =
  ## Render the pending pass's whole frame into the output FIFO — the
  ## double buffer the driver itself keeps. The frame is exactly the pass's
  ## pcmSamplesPerVBlank source-rate samples long (fractional remainder
  ## carried), so every cursor advances by exactly what the driver's did,
  ## however early or late the game's V-blank handler called the mixer: that
  ## jitter (±20 samples on Emerald, more on others) lands in the FIFO level
  ## — as it lands in the hardware's DMA latency — instead of in the voices'
  ## phase.
  var level = m.fifo_w - m.fifo_r
  if level < 0: level = 0
  let cap = m.fifo.len div 2
  if not m.fifo_primed:
    # First frame after engaging or a state load: start at the target level
    # with silence, so the frame lands where the hardware would play it.
    m.fifo_primed = true
    var pre = m.fifo_target
    if pre > cap div 2: pre = cap div 2
    for i in 0 ..< pre:
      let wi = (m.fifo_w mod cap) * 2
      m.fifo[wi] = 0
      m.fifo[wi + 1] = 0
      inc m.fifo_w
    level = m.fifo_w - m.fifo_r
  let nominal = float32(m.rev_spv) * float32(APU_SAMPLE_RATE) / float32(max(m.pcm_sample_rate, 1))
  if level > m.fifo_target + int(nominal) * 2:
    # Nobody is draining (substitution stepped aside for a foreign stream,
    # or the game's own audio is being passed through): drop the stale
    # audio so the frame that IS heard next is a current one, not one from
    # up to a FIFO-full of frames ago.
    m.fifo_r = m.fifo_w - m.fifo_target
    level = m.fifo_target
  # Level control. The frame length is never trimmed: it is what advances
  # every cursor by exactly the driver's spv source-rate samples, and the
  # V-blank jitter is zero-mean, so shortening frames whenever the level
  # runs high (and never lengthening them, an underrun merely holds) would
  # walk the cursors behind the engine one sample per late hook. Instead a
  # slow average of the level error drives one dropped or duplicated
  # OUTPUT sample per frame — a 30 µs slide, only when the offset persists
  # (the pcmFreq-vs-frame-rate drift is about a sample a second). The
  # average is the 1/32 EMA, so the V-blank jitter (±20 samples) leaves a
  # few samples of noise in it; the trim engages past 6 and, once engaged,
  # runs on until the average is back within half a sample (hysteresis:
  # fifo_trimming). A plain band (24, until 2026-09-14) left every title
  # parked up to 24 samples off its target on the side it approached from
  # — the whole residual the A/B listening set measured (Emerald 11 early,
  # Minish Cap 20, Metal Max 28, Castlevania 24 late).
  m.fifo_err_avg += (float32(level - m.fifo_target) - m.fifo_err_avg) * (1.0'f32 / 32.0'f32)
  # A target that moved by more than a frame's jitter (the measured latency
  # replacing the phase estimate, or a vintage that re-times its DMA) is
  # taken up in one step; the slow single-sample trim handles the rest.
  let step_err = level - m.fifo_target
  if step_err > 96 and level > step_err:
    m.fifo_r += step_err
    level -= step_err
    m.fifo_err_avg = 0
  elif step_err < -96 and level > 0 and level - step_err < cap - 2:
    let li = ((m.fifo_w - 1) mod cap) * 2
    for i in 0 ..< -step_err:
      let wi = (m.fifo_w mod cap) * 2
      m.fifo[wi] = m.fifo[li]
      m.fifo[wi + 1] = m.fifo[li + 1]
      inc m.fifo_w
    level -= step_err
    m.fifo_err_avg = 0
  elif (m.fifo_err_avg > 6.0'f32 or (m.fifo_trimming and m.fifo_err_avg > 0.5'f32)) and level > 1:
    m.fifo_trimming = true
    inc m.fifo_r
    dec level
    m.fifo_err_avg -= 1
  elif (m.fifo_err_avg < -6.0'f32 or (m.fifo_trimming and m.fifo_err_avg < -0.5'f32)) and
       level > 0 and level < cap - 2:
    m.fifo_trimming = true
    # duplicate the newest sample
    let li = ((m.fifo_w - 1) mod cap) * 2
    let wi = (m.fifo_w mod cap) * 2
    m.fifo[wi] = m.fifo[li]
    m.fifo[wi + 1] = m.fifo[li + 1]
    inc m.fifo_w
    inc level
    m.fifo_err_avg += 1
  else:
    m.fifo_trimming = false
  when defined(mp2kwav):
    # capture index at which this frame's first sample will be emitted
    dbgHookCapIdx.add mp2kWavCapture.len div 2 + level
  m.ramp_i = 0
  m.fifo_acc += nominal
  var n = int(m.fifo_acc)
  m.fifo_acc -= float32(n)
  if n > cap - level - 1: n = cap - level - 1
  m.frame_n = n
  for i in 0 ..< n:
    let (a, b) = m.render_one()
    let wi = (m.fifo_w mod cap) * 2
    m.fifo[wi] = a
    m.fifo[wi + 1] = b
    inc m.fifo_w
  # keep the indices small
  if m.fifo_r >= cap:
    m.fifo_r -= cap
    m.fifo_w -= cap

proc render_sample*(m: Mp2kHle): tuple[l: int16, r: int16] =
  ## One (FIFO A, FIFO B) sample at the APU rate (32768 Hz), replacing the
  ## DirectSound FIFO contribution while engaged: the next sample of the
  ## rendered frame FIFO (render_frame). An empty FIFO (a late V-blank
  ## handler, or a pass that never came — the driver's DMA replays its
  ## stale ring slot then) holds the last sample.
  if not m.engaged:
    m.fine_a = 0
    m.fine_b = 0
    return (0'i16, 0'i16)
  inc m.apu_clock
  var fa = m.fifo_last_a
  var fb = m.fifo_last_b
  if m.fifo_w > m.fifo_r and m.fifo.len > 0:
    let cap = m.fifo.len div 2
    let ri = (m.fifo_r mod cap) * 2
    fa = m.fifo[ri]
    fb = m.fifo[ri + 1]
    inc m.fifo_r
    m.fifo_last_a = fa
    m.fifo_last_b = fb
  # The latch is an integer: truncate toward zero, as the driver's byte
  # store does. The quality tier keeps the remainder (fine_a/fine_b) for
  # apu.nim to add after the DAC stage; off, the remainder is zero.
  let ia = int16(int32(fa))
  let ib = int16(int32(fb))
  if m.quality:
    m.fine_a = fa
    m.fine_b = fb
  else:
    m.fine_a = float32(ia)
    m.fine_b = float32(ib)
  when defined(mp2kwav):
    mp2kWavCapture.add ia
    mp2kWavCapture.add ib
  (ia, ib)

proc init_mp2k*(m: Mp2kHle) =
  ## Initialise mixer state. Nothing to scan: the hook is learned at runtime
  ## ("Runtime detection").
  m.use_cubic = true   # cubic (Catmull-Rom, per Paul Bourke) resampling by default
  m.quality = true     # quality tier on (render_one); parity checks turn it off
  build_sinc_table()
  m.fifo = newSeq[float32](MP2K_FIFO_CAP * 2)
  m.ring_copy = newSeq[uint8](8192)
  m.ring_prev_slot = -1
  m.predict = getEnv("DINGBAT_MP2K_LATE") != "1"
