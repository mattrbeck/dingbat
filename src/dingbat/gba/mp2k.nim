# =============================================================================
# MP2K / M4A ("Sappy") sound-engine HLE  (included by gba.nim)
# =============================================================================
# High-level-emulate the GBA's common MP2K music mixer: detect the engine at
# runtime via its SoundInfo work area in guest RAM (no ROM signature — see the
# "Runtime detection" section below), read the SoundInfo struct each audio
# frame, and render the DirectSound audio ourselves at a higher quality than
# the game's ~13 kHz FIFO stream.
#
# EXPERIMENTAL and OFF BY DEFAULT (gba.mp2k_hle; the "Improve audio quality"
# setting in both frontends). It is NOT cycle-accurate. Shadow state is
# deliberately NOT serialized into save states (files are identical with the
# HLE on or off); every state/rollback load instead calls mp2k_state_loaded
# to rebuild it from emulated RAM.
#
# Provenance / license: this file is an independent, MIT-licensed implementation
# built from PUBLIC, non-copyrightable facts about Nintendo's "MusicPlayer2000"
# (M4A / "Sappy") sound driver. The engine, its detection, its SoundInfo /
# SoundChannel / WaveData structs, the compressed-waveform block layout, and the
# reverb are all documented independently of any emulator source:
#   * loveemu vgmdocs, "Summary of GBA Standard Sound Driver MusicPlayer2000":
#     https://loveemu.github.io/vgmdocs/Summary_of_GBA_Standard_Sound_Driver_MusicPlayer2000.html
#     (engine overview, saptapper-based detection, "a simple reverb (echo)
#      effect with fixed delay", pointers to m4a_internal.h and sappy.txt).
#   * pret decompilations (pokeemerald/pokefirered/pokeruby) include/gba/
#     m4a_internal.h — authoritative SoundInfo / SoundChannel / WaveData field
#     names and order (the byte offsets below are derived from that layout).
#   * agbplay (ipatix) independently documents the same GFDPCM/BDPCM delta LUT
#     and 33-byte / 64-sample compressed block (corroboration of format facts).
#   * GBATEK — the DirectSound FIFO hardware sink we substitute for.
#   * Paul Bourke, "Cubic Interpolation" — the Catmull-Rom resampling formula.
# The 8-bit-PCM / BDPCM decode, resampler, and reverb are all expressed in our
# own way; no third-party emulator code was copied.
#
# Design notes (this PoC's own choices):
#   * SHADOW mode: the real SoundMainRAM still runs, so we consume the engine's
#     already-computed per-channel envelope volumes at +0x0A/+0x0B (which
#     already fold in masterVolume + pan; see m4a_internal.h SoundChannel
#     envelopeVolumeRight/Left) rather than reimplementing MP2K's ADSR chain.
#     Reading them at the hook (m4a updates them in the sequencer, before this
#     mixer runs) gives no frame lag; we ramp previous->current across a frame.
#   * Renders at the APU's 32768 Hz output rate.
#   * DirectSound double-buffer: the real driver mixes each pcmBuffer one frame
#     ahead of the DMA that drains it to the FIFO, so hardware audio lags the mixer
#     pass by ~one frame. We render at the mixer pass, so we delay our output by one
#     frame (init_mp2k / render_sample) to line up with the hardware FIFO.
#   * 8-bit PCM, looping, AND m4a BDPCM ("compressed waveform", channel.type
#     bit5) — the latter is decoded to s8 and mixed at PCM parity (not skipped).
#   * All DirectSound channel.type mode bits are handled: TYPE_FIX (fixed-rate
#     playback at SoundInfo.pcmFreq), TYPE_REV (reversed, one-shot playback —
#     e.g. Pokémon faint cries), TYPE_CMP (BDPCM), and their combinations, plus
#     note-on sample start offsets (SoundChannel.count). See the TYPE_* table
#     below for the per-flag reference semantics.

const
  # ---- Version-independent runtime detection --------------------------------
  # Every m4a/MP2K build publishes a pointer to its SoundInfo work area at the
  # fixed IWRAM slot 0x03007FF0 — the driver's SOUND_INFO_PTR, an m4a
  # convention inside the 0x03007F00..0x03007FFF block GBATEK documents as
  # reserved system space (the loveemu MP2K summary's RAM data map shows the
  # sound work area; the slot address is corroborated by the driver's own
  # behaviour, observed at runtime on every m4a game tested). The first
  # field of SoundInfo is `ident`, ID_NUMBER = 0x68736D53 ("Smsh" reversed —
  # per pret m4a_internal.h: "This field is normally equal to ID_NUMBER but it
  # is set to other values during sensitive operations for locking purposes").
  # SoundMain takes that lock by incrementing ident to ID_NUMBER+1 for the
  # duration of its processing — sequencer, CGB update and the SoundMainRAM PCM
  # mixer — and restores it afterwards. Both values therefore identify the
  # engine, and the +1 value identifies "a mixer pass is in flight".
  #
  # Detection needs no ROM signature at all (the old approach — a CRC-32 of one
  # specific SoundMain build plus a fixed literal-pool offset — only matched a
  # single m4a revision): we poll the SOUND_INFO_PTR slot once per frame, and
  # once the ident magic appears we LEARN the SoundMainRAM entry PC at runtime
  # (see mp2k_frame_poll / probe_pc below).
  MP2K_SOUNDINFO_PTR_ADDR = 0x03007FF0'u32   # IWRAM slot holding the SoundInfo pointer
  MP2K_IDENT_IDLE         = 0x68736D53'u32   # SoundInfo.ident = ID_NUMBER ("Smsh", pret m4a_internal.h)
  MP2K_IDENT_LOCK         = 0x68736D54'u32   # ID_NUMBER+1: lock held while SoundMain mixes
  # m4aSoundVSyncOff parks ident at +10 (pret pokeemerald src/m4a.c: "if ident
  # is ID_NUMBER or ID_NUMBER+1, ident += 10"; VSyncOn subtracts it back).
  # A stock driver's SoundMain refuses to run in that state, but modified m4a
  # vintages (Mother 3, the bit Generations series) do their own V-blank DMA
  # maintenance and run the whole engine with ident parked at +10 — the
  # SoundMain lock dance then happens as +10 <-> +11. Accept both forms
  # everywhere; for a stock driver the +10 state simply never mixes, so the
  # widened acceptance can never mislearn from it.
  MP2K_IDENT_IDLE_VOFF    = 0x68736D5D'u32   # ID_NUMBER+10: idle, VSync off
  MP2K_IDENT_LOCK_VOFF    = 0x68736D5E'u32   # ID_NUMBER+11: locked, VSync off
  MP2K_PROBE_MAX_FAILS    = 8                # give up learning after this many mislearns
  MP2K_MAX_CHANNELS       = 12

  # SoundChannel field offsets, derived from m4a_internal.h (pret):
  #   statusFlags(0) type(1) rightVolume(2) leftVolume(3) ... envelopeVolume(9)
  #   envelopeVolumeRight(10) envelopeVolumeLeft(11) ... ct(0x18) fw(0x1C)
  #   frequency(0x20) wav(0x24) currentPointer(0x28)
  SC_STATUS   = 0x00
  SC_TYPE     = 0x01
  SC_VOL_R    = 0x02
  SC_VOL_L    = 0x03
  SC_ENV_VOL  = 0x09
  SC_ENV_VR   = 0x0A   # envelopeVolumeRight
  SC_ENV_VL   = 0x0B   # envelopeVolumeLeft
  SC_COUNT    = 0x18   # count/ct: at note-on (START set) this holds the sample
                       # start offset ply_note stored there; the mixer then
                       # rewrites it to the source samples remaining until
                       # sample/loop end (used for save-state resume)
  SC_FREQ     = 0x20   # frequency (per-note playback rate, Hz)
  SC_WAVE     = 0x24   # wav pointer -> WaveData
  SC_SIZE     = 64

  # SoundInfo field offsets, derived from m4a_internal.h (pret):
  #   ident(0) pcmDmaCounter(4) reverb(5) maxChans(6) masterVolume(7) ...
  #   pcmSamplesPerVBlank(0x10) pcmFreq(0x14) ... chans[](0x50)
  SI_MAGIC        = 0x00   # ident
  SI_DMA_COUNTER  = 0x04   # pcmDmaCounter: V-blanks left before the DMA restarts
                           # at pcmBuffer start (m4aSoundVSync reloads it from
                           # pcmDmaPeriod at 0 — pret pokeemerald src/m4a_1.s)
  SI_REVERB       = 0x05   # reverb (0 = off)
  SI_MAX_CHANS    = 0x06   # maxChans
  SI_MASTER_VOL   = 0x07   # masterVolume
  SI_DMA_PERIOD   = 0x0B   # pcmDmaPeriod: pcmBuffer ring length in V-blank frames
  SI_SPV          = 0x10   # pcmSamplesPerVBlank
  SI_PCM_RATE     = 0x14   # pcmFreq (DirectSound base sample rate)
  SI_CHANNELS     = 0x50   # chans[MAX_DIRECTSOUND_CHANNELS]
  SI_PCM_BUFFER   = 0x350  # s8 pcmBuffer[PCM_DMA_BUF_SIZE*2] — follows the 12
                           # fixed 64-byte chans slots (0x50 + 12*64), matching
                           # the DMA1SAD every standard driver programs

  # channel.type bits. The sequencer copies the instrument's ToneData.type byte
  # verbatim into SoundChannel.type at note-on (pret pokeemerald m4a_1.s, ply_note),
  # so these are the TONEDATA_TYPE_* flags of constants/m4a_constants.inc:
  #   TYPE_CGB (0x07): nonzero low bits select a CGB (PSG) channel 1-4; such notes
  #     are allocated to the CgbChans array and never reach a DirectSound
  #     SoundChannel, so a DirectSound channel always has these bits clear.
  #   TYPE_FIX (0x08): fixed-rate playback — the mixer's phase step is forced to
  #     1.0 source sample per output sample (m4a_1.s: "movne r8, 0x800000" in
  #     SoundMainRAM_Unk1, and the raw copy loop in the plain path), i.e. the
  #     sample plays at exactly SoundInfo.pcmFreq with channel.frequency ignored.
  #   TYPE_REV (0x10): reversed playback — the mixer reflects the read pointer to
  #     the END of the sample data and reads with descending addresses, so the
  #     last source sample plays first (SoundMainRAM_Unk1 init + its backward
  #     read loops). The reversed paths never consult the loop registers: when
  #     the sample count is exhausted the channel is stopped (statusFlags = 0),
  #     so reversed playback is always one-shot.
  #   TYPE_CMP (0x20): compressed (BDPCM) waveform. CMP or REV route the mixer
  #     into its special-case renderer; within it, compressed decode is engaged
  #     only when WaveData.type != 0 (the u16 at wave+0 — pret's wav2agb writes
  #     1 for DPCM data, 0 for plain PCM). All four CMP/REV/FIX combinations are
  #     valid: CMP+REV plays the compressed stream backward (one-shot), FIX with
  #     either forces the 1.0 step. Forward CMP playback does support looping.
  #   TYPE_SPL (0x40, key split) and TYPE_RHY (0x80, rhythm): instrument-table
  #     lookup flags consumed by the sequencer when picking the sub-instrument;
  #     they can remain set in SoundChannel.type but the mixer ignores them.
  TYPE_CGB = 0x07'u8
  TYPE_FIX = 0x08'u8
  TYPE_REV = 0x10'u8
  TYPE_CMP = 0x20'u8
  TYPE_SPL = 0x40'u8
  TYPE_RHY = 0x80'u8

  # status bits (m4a SoundChannel.statusFlags — SOUND_CHANNEL_SF_* in pret
  # pokeemerald constants/m4a_constants.inc):
  #   START (0x80): note-on request from the sequencer; the mixer consumes it.
  #   STOP (0x40): note-off request; envelope enters release.
  #   SPECIAL (0x20): mixer-internal latch — "CMP/REV pointer already
  #     initialised" (set on the first mixer pass of such a channel).
  #   LOOP (0x10): set at note start when WaveData.flags carries the loop bits
  #     (0xC0 at wave+3).
  #   IEC (0x04): pseudo-echo tail — when the release envelope decays below
  #     SoundChannel.pseudoEchoVolume, the driver holds the envelope at that
  #     volume and counts pseudoEchoLength down once per frame, killing the
  #     channel at zero (m4a_1.s envelope prologue). Shadow mode inherits all of
  #     this for free: we consume envelopeVolumeRight/Left, which the real
  #     driver computes AFTER the release/IEC handling each frame.
  #   ENV (0x03): envelope phase (3=attack, 2=decay, 1=sustain, 0=release).
  CH_START = 0x80'u8
  CH_STOP  = 0x40'u8
  CH_ON    = 0xC7'u8   # SOUND_CHANNEL_SF_ON = START|STOP|IEC|ENV — "producing sound"

  # m4a compressed-waveform ("GFDPCM"/BDPCM) 4-bit differential LUT: the 16
  # signed deltas added to a running s8 accumulator. These values are a fixed
  # property of Nintendo's format (gDeltaEncodingTable in pret pokeemerald
  # src/m4a_tables.c; agbplay independently corroborates):
  #   [0, 1, 4, 9, 16, 25, 36, 49, -64, -49, -36, -25, -16, -9, -4, -1].
  BDPCM_LUT: array[16, int8] = [
    0'i8, 1, 4, 9, 16, 25, 36, 49,
    -64, -49, -36, -25, -16, -9, -4, -1
  ]
  # Compressed blocks are 33 bytes / 64 samples: 1 s8 base byte + 32 nibble
  # bytes. Per the shipped decoder (SoundMainRAM_Unk2 in pret pokeemerald
  # src/m4a_1.s): sample 0 of a block is the RAW base byte; sample 1 takes the
  # LOW nibble of the first delta byte (its high nibble is never read); each
  # subsequent byte then supplies its high nibble followed by its low nibble
  # (63 used nibbles for samples 1..63). The accumulator wraps at 8 bits (the
  # driver decodes through strb/ldrsb).
  BDPCM_BLOCK_BYTES  = 33'u32
  BDPCM_BLOCK_SAMPS  = 64'u32

  # Reverb frame-ring slot capacity, in stereo samples at our 32768 Hz render
  # rate. One engine mixer pass spans one V-blank = 32768 / 59.7275 Hz ~ 549
  # output samples (the reference's own pcmFreq derivation uses the same
  # 59.7275 Hz refresh: pret pokeemerald src/m4a.c SampleFreqSet). 1024 gives
  # comfortable headroom for frame-length jitter; samples beyond a pass's
  # actual length are simply never read back (the taps index by intra-frame
  # position, and consecutive passes have near-identical lengths).
  MP2K_REV_SLOT_LEN = 1024

# NOTE: Mp2kSampler / Mp2kHle types live in gba.nim's main type section (Nim
# requires types referenced by the GBA object to be declared before use).

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
  ## Decode one whole 33-byte/64-sample BDPCM block into the sampler's block
  ## cache — the same strategy as the real driver, which decodes block-at-a-
  ## time into sDecodingBuffer keyed by a cached block index (SoundMainRAM_Unk2
  ## in pret pokeemerald src/m4a_1.s). Nibble order per that routine: sample 0
  ## is the raw s8 base byte; sample 1 uses the LOW nibble of the first delta
  ## byte (its high nibble is never read); each subsequent byte supplies its
  ## high nibble then its low nibble. The accumulator wraps at 8 bits, exactly
  ## like the driver's strb/ldrsb round trip. Decoding whole blocks (rather
  ## than sample-at-a-time) keeps the stream correct however the resampler
  ## lands on it: decimating steps that skip source samples, reversed reads,
  ## and loop wrap-backs all just index into the decoded block.
  let base = blk * BDPCM_BLOCK_BYTES
  var acc = cast[int8](m.wave_u8(s, rom, rmask, base))
  s.blk[0] = acc
  for i in 1 ..< int(BDPCM_BLOCK_SAMPS):
    let b = m.wave_u8(s, rom, rmask, base + uint32(i shr 1) + 1'u32)
    let nib = (if (i and 1) != 0: b and 0x0F'u8 else: b shr 4)
    acc = cast[int8](int(acc) + int(BDPCM_LUT[nib]))
    s.blk[i] = acc
  s.blk_index = blk

proc decode_src(m: Mp2kHle; s: ptr Mp2kSampler; rom: ptr seq[byte];
                rmask: uint32): float32 {.inline.} =
  ## Decode the source sample at the sampler's current play position, returned
  ## in raw s8 units (~ -128..127). Reversed channels (TONEDATA_TYPE_REV) read
  ## the wave back-to-front: the real mixer reflects its read pointer to the
  ## sample end and reads with descending addresses (SoundMainRAM_Unk1 in pret
  ## pokeemerald src/m4a_1.s), so play position p maps to source index
  ## sample_count-1-p (sample_count already excludes any note start offset;
  ## see on_frame).
  let pos = (if s.reversed: s.sample_count - 1'u32 - s.src_index
             else: s.src_index)
  if s.compressed:
    if (pos shr 6) != s.blk_index:
      m.bdpcm_decode_block(s, rom, rmask, pos shr 6)
    float32(s.blk[int(pos and (BDPCM_BLOCK_SAMPS - 1'u32))])
  else:
    float32(cast[int8](m.wave_u8(s, rom, rmask, pos)))

proc mp2k_state_loaded*(m: Mp2kHle) =
  ## Save-state / rollback load hook. The shadow mixer's state is deliberately
  ## NOT serialized (state files are identical with the HLE on or off), so
  ## everything derived from the pre-load timeline is stale: sampler positions,
  ## cubic history taps, the DirectSound double-buffer delay ring, and the
  ## reverb feedback line. Drop it all and mark a resync so the next mixer-pass
  ## hook re-latches every channel from the engine's SoundInfo in the restored
  ## RAM — resuming mid-note channels at the engine's own playback position
  ## (SoundChannel.ct) rather than retriggering them from the sample start.
  ## Detection state (the learned hook_addr / entry_addr) is kept: states are
  ## per-ROM, the state restores the IWRAM the mixer was learned from, and if
  ## the learned PC is somehow stale for the restored timeline the lock
  ## validation unlearns it and the frame poll re-arms probing (see
  ## unlearn_hook below). `engaged` is kept, and render_sample simply emits
  ## silence until the first post-load mixer pass refills the channels.
  for i in 0 ..< MP2K_MAX_CHANNELS:
    m.samplers[i] = Mp2kSampler()      # inactive, zero taps/phase/volumes
  for v in m.out_delay.mitems: v = 0
  m.out_delay_w = 0
  for v in m.reverb_ring.mitems: v = 0
  m.rev_slot = 0
  m.rev_pos = 0
  m.frame_pos = 0
  m.resync_pending = true
  # Foreign-feeder detection: the streak/counter baseline are timeline-derived
  # — drop them. The fifo_foreign LATCH is kept: it describes the ROM's driver
  # usage, not the timeline, and re-latching would substitute our silence over
  # the game's streamed music for several frames after every load.
  m.foreign_streak = 0
  m.fifo_cpu_last = m.fifo_cpu_bytes
  m.real_abs_acc = 0
  m.hle_abs_acc = 0
  m.ab_n = 0
  m.shadow_quiet_age = 0   # the restored ring may hold pre-load engine audio
                           # our reset shadow doesn't: give it the tail grace

# =============================================================================
# Runtime detection: learn the SoundMainRAM entry PC instead of matching a ROM
# signature.
#
# How it works (all facts from pret m4a_internal.h + the loveemu MP2K summary,
# plus this emulator's own runtime observation of the guest):
#   * SOUND_INFO_PTR (0x03007FF0) -> SoundInfo, whose ident field is ID_NUMBER
#     0x68736D53 at rest and ID_NUMBER+1 while SoundMain holds its lock. This
#     identifies the engine with no ROM pattern whatsoever, on every m4a
#     revision (custom drivers — e.g. Camelot's — never publish this magic).
#   * The PCM mixer ("SoundMainRAM", per its name and the loveemu data map) is
#     copied to RAM at init and jumped to from SoundMain while the lock is
#     held, with the SoundInfo pointer in r0 (verified empirically on multiple
#     m4a vintages by this project's harnesses; the mixer must receive the
#     work-area pointer, and r0 is the ABI argument register).
#   * So: once the ident magic is seen (frame poll), watch execution until an
#     instruction is fetched from RAM (0x02/0x03 region) with r0 == &SoundInfo
#     while ident == ID_NUMBER+1. The first such PC is the mixer entry — learn
#     it and hook it every frame from then on, exactly like the old fixed hook.
#   * Self-validating: the real mixer entry can ONLY execute with the lock
#     held (SoundMain takes it before jumping). If a learned PC ever fires
#     without the lock (nested-IRQ dispatcher in IWRAM, engine torn down and
#     buffer reused...), the learn was wrong: blocklist it and re-learn.
#
# Hot-path cost: once learned, the per-instruction work is the same single PC
# compare the fixed-address hook always did. While probing (from engine init
# to first mixer pass, typically <2 frames) each RAM-fetched instruction adds
# one register compare before the out-of-line probe. When HLE is off, nothing
# runs at all.
# =============================================================================

proc unlearn_hook*(m: Mp2kHle) =
  ## The learned PC fired without the engine lock held — impossible for the
  ## real SoundMainRAM entry — so the learn was wrong. Blocklist the PC and
  ## let the frame poll re-arm probing.
  if m.hook_addr != 0xFFFFFFFF'u32 and m.probe_block_n < m.probe_block.len:
    m.probe_block[m.probe_block_n] = m.hook_addr
    inc m.probe_block_n
  inc m.probe_fails
  m.hook_addr  = 0xFFFFFFFF'u32
  m.entry_addr = 0xFFFFFFFF'u32
  m.engaged = false
  for i in 0 ..< MP2K_MAX_CHANNELS: m.samplers[i].active = false

proc on_frame(m: Mp2kHle; sound_info: uint32) =
  ## Called once per engine audio frame (at the SoundMainRAM hook). Re-reads
  ## the SoundInfo channel table and refreshes each sampler's parameters and
  ## envelope endpoints. Shadow mode: envelope_volume_l/r are already computed
  ## by the real mixer, so we just consume them.
  # DIAG toggle: master_apply != 0 re-applies SoundInfo.masterVolume on top of the
  # engine's per-side volumes (WRONG — they already include it). Default 0.
  let master_mult =
    if m.master_apply != 0:
      float32(int(m.rd8(sound_info + SI_MASTER_VOL)) + 1) / 16.0'f32
    else:
      1.0'f32
  var maxc = int(m.rd8(sound_info + SI_MAX_CHANS))
  if maxc > MP2K_MAX_CHANNELS: maxc = MP2K_MAX_CHANNELS
  # FIFO topology: observe which FIFO(s) the engine actually feeds, from the
  # live sound-DMA registers (channels 1/2 are the only FIFO-capable ones —
  # GBATEK). The standard stereo driver runs DMA1->FIFO A (left) and
  # DMA2->FIFO B (right); some m4a vintages mix MONO instead — one pcmBuffer
  # through a single FIFO (e.g. Minish Cap: DMA1->FIFO A with SOUNDCNT_H
  # routing A to both speakers and DMA2 disabled), and a single per-channel
  # volume in the +0x0A slot with +0x0B unused (observed live: +0x0A ==
  # envelopeVolume * avg(rightVolume, leftVolume) >> 8, +0x0B always 0).
  # Keying on the DMA registers is exactly what the real signal path does, so
  # it is vintage-independent: substitute only the FIFO(s) the driver drives.
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
  # Reverb frame ring — our shadow of the engine's pcmBuffer slot ring (see the
  # "MP2K reverb" block in render_sample for the seed algorithm and citations).
  # SoundInfo.pcmDmaPeriod (+0x0B, pret m4a_internal.h) is the ring length in
  # V-blank frames: SampleFreqSet sets pcmDmaPeriod = PCM_DMA_BUF_SIZE /
  # pcmSamplesPerVBlank (pret pokeemerald src/m4a.c) — 7 in pokeemerald,
  # 6 in Minish Cap. The ring is kept ALWAYS (once engaged), not just while
  # reverb > 0: the real pcmBuffer holds the last pcmDmaPeriod frames of
  # output unconditionally, so a mid-song reverb-on immediately echoes real
  # history rather than silence.
  m.rev_period = int(m.rd8(sound_info + SI_DMA_PERIOD))
  if m.rev_period < 1: m.rev_period = 1     # degenerate guard; real drivers
  elif m.rev_period > 16: m.rev_period = 16 # use 2..12 (PCM_DMA_BUF_SIZE/spv)
  if m.reverb_ring.len != m.rev_period * MP2K_REV_SLOT_LEN * 2:
    m.reverb_ring = newSeq[float32](m.rev_period * MP2K_REV_SLOT_LEN * 2)
  # Slot cursor: derived from the engine's own pcmDmaCounter exactly as
  # SoundMain derives its pcmBuffer frame cursor (label SoundMain_5 in pret
  # pokeemerald src/m4a_1.s: r5 = pcmBuffer + pcmSamplesPerVBlank *
  # (pcmDmaPeriod - (pcmDmaCounter - 1)) when pcmDmaCounter >= 2, else slot 0),
  # so we track the real ring phase verbatim — including across skipped
  # mixer passes — rather than assuming one advance per hook fire.
  block:
    let cnt = int(m.rd8(sound_info + SI_DMA_COUNTER))
    m.rev_slot = (if cnt <= 1: 0 else: m.rev_period - (cnt - 1))
    if m.rev_slot < 0 or m.rev_slot >= m.rev_period: m.rev_slot = 0
  m.rev_pos = 0
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
    # DirectSound mode bits (see the TYPE_* table above). CMP or REV route the
    # real mixer into its special-case renderer (SoundMainRAM_Unk1 in pret
    # pokeemerald m4a_1.s); inside it, compressed decode is selected by
    # WaveData.type != 0 (the u16 at wave+0), NOT by the channel bit alone —
    # so a REV-only channel with a plain wave plays uncompressed backward, and
    # a CMP-flagged channel with a plain wave header plays uncompressed.
    let reversed   = (ctype and TYPE_REV) != 0
    let compressed = (ctype and (TYPE_CMP or TYPE_REV)) != 0 and
                     m.rd16(wave + 0) != 0'u16
    let loop_status = m.rd16(wave + 2)
    let looping = (loop_status and 0xC000'u16) != 0
    let new_wave_data = wave + 16
    # A note-on (a fresh drum hit / re-keyed note) is flagged by the START bit
    # (0x80) in the channel status — the m4a sequencer sets it and the mixer
    # consumes it. We MUST restart the sample on it: a drum pattern re-keys the
    # SAME snare sample every beat, so keying on wave_data change alone drops
    # repeated hits while the previous one is still playing/looping. (m4a status
    # bits per m4a_internal.h / sappy.txt.)
    var use_start = true
    when defined(mp2kwav):
      var checked {.global.} = false
      var envStart {.global.} = true
      if not checked:
        checked = true
        envStart = getEnv("DINGBAT_NOSTART") != "1"
      use_start = envStart
    # A note-on (fresh drum hit / re-keyed note) is flagged by the START bit (0x80)
    # in the channel status. on_frame runs at the mixer's ENTRY, before the real
    # mixer consumes and clears START, so the live status byte is the reliable
    # note-on signal.
    let started = (status and CH_START) != 0
    let retrig = (started and use_start) or
                 not s.active or s.wave_data != new_wave_data or
                 s.compressed != compressed or s.reversed != reversed
    when defined(mp2kwav):
      let dumpsel = getEnv("DINGBAT_CHDUMP")
      if (dumpsel == $i or dumpsel == "all") and retrig and dbgRetrigLog < 200:
        echo "ch", i, " st=", toHex(int(status), 2),
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
        # First mixer pass after a save-state / rollback load: this channel was
        # already mid-note in the engine (CH_ON without the START bit), so it
        # must NOT restart from the sample start at full volume — that would be
        # an audible retrigger burst the real hardware doesn't produce. The m4a
        # SoundChannel exposes its playback position: `ct` (SC_COUNT, offset
        # 0x18 per m4a_internal.h) holds the source samples remaining until the
        # sample (or loop) end. The mixer set count = size - offset at note-on
        # and decrements it per source sample consumed, so size - ct is the
        # forward cursor AND (for a reversed channel, whose note start offset
        # is unrecoverable post-hoc — assume 0) the consumed-sample count our
        # reversed src_index tracks: one formula covers both directions. Resume
        # there; the volume endpoints below then ramp from 0 (the freshly reset
        # vol_*1) to the engine's current volume across this one frame — a
        # ~16 ms fade-in that also masks the rebuilt interpolation history.
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
        # ply_note stores a sample start offset in SoundChannel.count at note-on
        # and the mixer's START handler consumes it as currentPointer =
        # wav->data + count, count = wav->size - count (pret pokeemerald m4a_1.s),
        # so honor it when the START bit keyed this retrigger.
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
    s.wave_data   = new_wave_data
    s.compressed  = compressed
    s.reversed    = reversed
    if compressed: m.dbg_compressed_used.inc
    s.use_pcm_rate = (ctype and TYPE_FIX) != 0
    # Resample rate = the CHANNEL's per-note playback frequency (SoundChannel
    # +0x20, in Hz), NOT the sample header's base freq at wave+4 (a large
    # fixed-point value). Using the latter advanced the cursor ~200 samples per
    # output sample — the high-pitch whine. step = freq / output_rate.
    s.freq        = m.rd32(base + SC_FREQ)
    s.loop_start  = m.rd32(wave + 8)    # WaveData.loopStart
    # WaveData.size = number of source samples. A reversed channel covers
    # [0, size-offset): the real mixer reflects currentPointer to
    # data + size - offset and walks DOWN to data[0] (SoundMainRAM_Unk1 REV
    # init in pret pokeemerald m4a_1.s), so its playable length is
    # size - offset and play position p maps to source index
    # (size - offset - 1) - p (see decode_src).
    let total = m.rd32(wave + 12)
    s.sample_count = (if reversed and s.start_off < total: total - s.start_off
                      else: total)
    # The reference driver's reversed paths never consult the loop registers —
    # count exhaustion silences the channel (m4a_1.s, the special renderer's
    # end-of-data branch writes statusFlags = 0) — so REV is always one-shot.
    s.looping     = looping and not reversed
    # Fast path: cache a direct ROM offset so the per-sample mixer can read the
    # cartridge buffer without going through the bus address decoder. m4a sample
    # banks live in ROM (0x08000000..0x0DFFFFFF).
    let wave_region = new_wave_data shr 24
    s.in_rom = wave_region >= 0x08'u32 and wave_region <= 0x0D'u32
    if s.in_rom:
      s.rom_off = (new_wave_data and 0x01FFFFFF'u32)
    if resumed and s.src_index > 0'u32 and s.src_index < s.sample_count:
      # Seed the resampler history at the resume point (needs in_rom/rom_off,
      # so this runs after they are set) with the source sample preceding it
      # in play order. The block-cache BDPCM decoder (decode_src) lands on a
      # mid-block position natively — decoding the whole block on demand — so
      # no differential-accumulator re-seeding is needed.
      let rom = addr m.gba.cartridge.rom
      let rmask = m.gba.cartridge.rom_mask
      s.src_index.dec
      s.tap0 = m.decode_src(s, rom, rmask)
      s.src_index.inc
      s.tap1 = s.tap0; s.tap2 = s.tap0; s.tap3 = s.tap0
    # SC_ENV_VL/VR (0x0B/0x0A) are the engine's per-side volumes: envelopeVolume
    # * (leftVolume|rightVolume) >> 8, and leftVolume/rightVolume ALREADY fold in
    # SoundInfo.masterVolume. So we consume them directly and must NOT re-apply
    # master (doing so double-applied it, making games with masterVol<15 — e.g.
    # Pokémon FR/Em at 12/16 — render ~19% too quiet). The real mixer writes these
    # once per SoundMainRAM pass, so they are a per-frame constant; the hook reads
    # the value in force for this frame. Shift last frame's endpoint into vol_*0 and
    # ramp toward this frame's value across the frame, mirroring the real driver's
    # per-sample volume interpolation from the previous endpoint.
    # MONO vintages (see the FIFO-topology block above) fold pan away entirely:
    # the mixer computes ONE volume — envelopeVolume * avg(rV, lV) >> 8 — into
    # the +0x0A slot and leaves +0x0B at 0. Consume that single volume for both
    # accumulator sides (they stay identical; the output router below then
    # feeds the one fed FIFO). Reading +0x0B as "left" there would silence the
    # mix — that was the Minish Cap "HLE way quieter" bug.
    let vr = float32(m.rd8(base + SC_ENV_VR)) / 255.0'f32 * master_mult
    let vl = (if m.mono_mode != 0: vr
              else: float32(m.rd8(base + SC_ENV_VL)) / 255.0'f32 * master_mult)
    s.vol_l0 = s.vol_l1
    s.vol_r0 = s.vol_r1
    s.vol_l1 = vl
    s.vol_r1 = vr
  # --- Foreign FIFO feeder detection -------------------------------------------
  # Some games ship m4a (SFX/jingles) but stream their MUSIC around the
  # engine's channel structs (observed: Batman Vengeance, Altered Beast,
  # Army Men — their streamer fills pcmBuffer just-in-time mid-frame and
  # erases it after the DMA drains, so no SoundChannel is ever active and any
  # state poll sees a silent buffer). Substituting our shadow render would
  # replace their music with silence. Three engine/bus-state signals, each
  # sustained over consecutive mixer passes, latch substitution off for the
  # session (never keyed on game ID):
  #   * FIFO register bytes written by anything but special-timing DMA1/2
  #     (fifo_cpu_bytes, counted at the FIFO write port) — the m4a driver
  #     only ever feeds the FIFOs through those DMAs;
  #   * a special-timing FIFO DMA sourcing OUTSIDE the SoundInfo work area
  #     (m4a's pcmBuffer is embedded in SoundInfo at +0x350);
  #   * the catch-all: the real drained FIFO stream persistently carries
  #     energy while our shadow render is persistently silent. A genuinely
  #     engine-owned stream cannot sound while every channel we mirror is
  #     idle — and if the shadow were ever wrongly silent for another
  #     reason, falling back to the game's own audio is the right failure
  #     mode anyway.
  # Evidence model (foreign audio is BURSTY — Batman's stingers alternate with
  # silence — so a consecutive-streak rule never accumulates):
  #   evidence — provenance hit (CPU bytes / bad SAD), or the real stream
  #     audible while our shadow render is silent;
  #   refutation — the shadow itself is producing audio with no provenance
  #     hit (the engine demonstrably owns the stream): reset;
  #   neutral — both silent: hold the count.
  # A few evidence passes (frames of un-renderable audible audio) latch
  # substitution off for the session.
  block:
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
      # Real-vs-shadow energy over the samples since the last mixer pass
      # (accumulated in apu.get_sample). Units are FIFO latch units (s8*2):
      # real avg(|L|+|R|) >= 4 is clearly audible; shadow avg < 0.25 is
      # genuinely silent (not merely quiet).
      var real_loud = false
      var shadow_loud = false
      if m.ab_n > 0:
        when defined(mp2kwav):
          m.dbg_real_avg = float32(m.real_abs_acc) / float32(m.ab_n)
          m.dbg_hle_avg  = float32(m.hle_abs_acc) / float32(m.ab_n)
        real_loud   = m.real_abs_acc >= int64(m.ab_n) * 4
        shadow_loud = m.hle_abs_acc >= int64(m.ab_n) div 4
        m.real_abs_acc = 0
        m.hle_abs_acc = 0
        m.ab_n = 0
      if shadow_loud: m.shadow_quiet_age = 0
      elif m.shadow_quiet_age < 1000: inc m.shadow_quiet_age
      # Energy evidence only counts once the shadow has been silent longer
      # than the real ring could still be draining engine-mixed audio (the
      # pcmBuffer holds up to pcmDmaPeriod <= 16 frames our shadow's 1-frame
      # delay line does not): a song-stop drain tail is not foreign.
      if provenance or (real_loud and m.shadow_quiet_age > 16):
        inc m.foreign_streak
        # 3 evidence passes: an evidence pass is a full frame of clearly
        # audible foreign audio while our shadow (voices AND reverb tail) is
        # bit-silent outside any drain-tail window — essentially impossible
        # for an engine-owned stream, so a few hits suffice. Games with very
        # sparse foreign stingers (Altered Beast's title hits) still latch
        # within seconds.
        if m.foreign_streak >= 3:
          m.fifo_foreign = true
      elif shadow_loud:
        m.foreign_streak = 0
      # else: both silent — neutral, hold the evidence count
  m.frame_seen = true
  m.engaged = true
  m.resync_pending = false   # one full re-latch pass done; back to normal keying

proc mixer_hook*(m: Mp2kHle) =
  ## PC-hook entry: called from cpu.tick when r15 reaches the learned
  ## SoundMainRAM entry. Reads the SoundInfo pointer and, if the engine lock is
  ## held (ident == ID_NUMBER+1 — always true at the real mixer entry, since
  ## SoundMain takes the lock before jumping here), refreshes the mixer state.
  ## The hook fires at the mixer's entry, where the channel status still
  ## carries the START bit (the real mixer clears it as it processes each
  ## note-on), so this is where we detect (re)triggers. A fire WITHOUT the
  ## lock means the learned PC was wrong: unlearn and re-probe.
  let sip = m.rd32(MP2K_SOUNDINFO_PTR_ADDR)
  if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
    let ident = m.rd32(sip + SI_MAGIC)
    if ident == MP2K_IDENT_LOCK or ident == MP2K_IDENT_LOCK_VOFF:
      m.on_frame(sip)
      return
  m.unlearn_hook()

proc probe_pc*(m: Mp2kHle; pc: uint32) {.noinline.} =
  ## Learning probe, called from cpu.tick only while probing is armed and only
  ## for instructions fetched from RAM with r0 == &SoundInfo (both prefiltered
  ## inline). If the engine lock is held right now, this PC is the SoundMainRAM
  ## mixer entry: learn it and run the first shadow pass immediately (the entry
  ## has not executed yet, so channel state is exactly what the hook would see).
  let ident = m.rd32(m.probe_sound_info + SI_MAGIC)
  inc m.dbg_probe_hits
  m.dbg_probe_ident = ident
  if ident != MP2K_IDENT_LOCK and ident != MP2K_IDENT_LOCK_VOFF: return
  for i in 0 ..< m.probe_block_n:
    if m.probe_block[i] == pc: return          # previously invalidated
  m.hook_addr  = pc                            # pc may carry the Thumb bit; the
  m.entry_addr = pc and not 1'u32              # hook compare uses it verbatim
  m.probing = false
  m.dbg_hook_fires.inc
  m.mixer_hook()

proc mp2k_frame_poll*(m: Mp2kHle) =
  ## Once-per-frame presence check (2 IWRAM reads; called from step_frame only
  ## while mp2k_hle is enabled). Version-independent: follows SOUND_INFO_PTR
  ## (0x03007FF0) and looks for the SoundInfo ident magic. Arms PC probing
  ## until the mixer entry is learned; disengages the HLE if the magic ever
  ## disappears (engine torn down) so stale samplers cannot keep looping.
  let sip = m.rd32(MP2K_SOUNDINFO_PTR_ADDR)
  var ident = 0'u32
  if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
    ident = m.rd32(sip + SI_MAGIC)
  if m.hook_addr != 0xFFFFFFFF'u32:
    if m.engaged and ident != MP2K_IDENT_IDLE and ident != MP2K_IDENT_LOCK and
       ident != MP2K_IDENT_IDLE_VOFF and ident != MP2K_IDENT_LOCK_VOFF:
      m.engaged = false
      for i in 0 ..< MP2K_MAX_CHANNELS: m.samplers[i].active = false
    return
  # Arm probing only when the engine is at rest (ident == ID_NUMBER, in
  # either VSync form): arming mid-pass could learn a mid-mixer PC instead of
  # the entry.
  m.probing = (ident == MP2K_IDENT_IDLE or ident == MP2K_IDENT_IDLE_VOFF) and
              m.probe_fails < MP2K_PROBE_MAX_FAILS
  if m.probing: m.probe_sound_info = sip

when defined(mp2kwav):
  proc mp2k_decode_bdpcm*(data: openArray[byte]; num_samples: int): seq[float32] =
    ## Standalone reference decode of an m4a BDPCM ("compressed waveform")
    ## buffer, in raw s8 units. Mirrors bdpcm_decode_block() below (and the
    ## shipped decoder, SoundMainRAM_Unk2 in pret pokeemerald src/m4a_1.s):
    ## per 33-byte/64-sample block, sample 0 is the raw s8 base byte, sample 1
    ## uses the LOW nibble of the first delta byte (its high nibble is unused),
    ## and each later byte supplies high then low nibble; the accumulator wraps
    ## at 8 bits. Used by the test harness to validate the block layout against
    ## hand-computed values.
    result = newSeq[float32](num_samples)
    var acc = 0'i8
    for pos in 0 ..< num_samples:
      let block_offset  = uint32(pos) and (BDPCM_BLOCK_SAMPS - 1)
      let block_address = (uint32(pos) shr 6) * BDPCM_BLOCK_BYTES
      if block_offset == 0'u32:
        acc = cast[int8](data[block_address])
      else:
        var lut = data[block_address + (block_offset shr 1) + 1'u32]
        if (block_offset and 1'u32) != 0'u32: lut = lut and 0x0F'u8
        else:                                 lut = lut shr 4
        acc = cast[int8](int(acc) + int(BDPCM_LUT[lut]))
      result[pos] = float32(acc)

proc render_sample*(m: Mp2kHle): tuple[l: int16, r: int16] =
  ## Produce one stereo output sample at the APU's rate (32768 Hz). Replaces
  ## the DirectSound FIFO A/B contribution when engaged. Returns signed values
  ## roughly in the FIFO latch range (~ -128*2 .. 127*2) so the existing APU
  ## DirectSound scaling path applies unchanged.
  ##
  ## Each channel uses a straightforward forward-stepping polyphase resampler:
  ## keep a 4-tap sample history plus a fractional phase, decode a fresh source
  ## sample only when the phase crosses an integer boundary, and interpolate
  ## (cubic Catmull-Rom per Paul Bourke, or linear).
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
    if s.need_fetch and s.src_index < s.sample_count:
      let ns = m.decode_src(s, rom, rmask)
      s.tap3 = s.tap2; s.tap2 = s.tap1; s.tap1 = s.tap0; s.tap0 = ns
      s.need_fetch = false
    let mu = s.phase_frac
    var sample: float32
    if m.resample_mode == 2:
      sample = s.tap0                       # zero-order hold (matches raw FIFO)
    elif m.resample_mode == 1 or not cubic:
      sample = s.tap0 * mu + s.tap1 * (1.0'f32 - mu)
    elif cubic:
      # Catmull-Rom / cubic (Paul Bourke, "Cubic Interpolation").
      # tap0 = newest .. tap3 = oldest.
      let mu2 = mu * mu
      let a0 = s.tap0 - s.tap1 - s.tap3 + s.tap2
      let a1 = s.tap3 - s.tap2 - a0
      let a2 = s.tap1 - s.tap3
      let a3 = s.tap2
      sample = a0 * mu * mu2 + a1 * mu2 + a2 * mu + a3
    else:
      sample = s.tap0 * mu + s.tap1 * (1.0'f32 - mu)
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
    # Advance the resample phase; step = playback-rate / output-rate. A
    # TYPE_FIX channel plays at exactly SoundInfo.pcmFreq — the real mixer
    # forces its step to 1.0 source sample per pcmFreq output sample and
    # ignores channel.frequency entirely (pret pokeemerald m4a_1.s: the plain
    # path's raw copy loop, and "movne r8, 0x800000" in SoundMainRAM_Unk1) —
    # so its rate here is the engine's pcmFreq, not the per-note frequency.
    let rate = (if s.use_pcm_rate: float32(m.pcm_sample_rate) else: float32(s.freq))
    when defined(mp2kwav):
      dbgStepN.inc
      if rate > float32(APU_SAMPLE_RATE):
        dbgStepDecimN.inc
        dbgStepMax = max(dbgStepMax, rate/float32(APU_SAMPLE_RATE))
    s.phase_frac += rate / float32(APU_SAMPLE_RATE)
    if s.phase_frac >= 1.0'f32:
      let n = uint32(s.phase_frac)
      s.phase_frac -= float32(n)
      s.src_index += n
      s.need_fetch = true
      if s.src_index >= s.sample_count:
        # Reversed playback is one-shot: the reference driver's REV paths never
        # consult the loop registers and stop the channel when the sample count
        # is exhausted (pret pokeemerald m4a_1.s, SoundMainRAM_Unk1).
        if s.looping and not s.reversed:
          s.src_index = s.loop_start + n - 1'u32
        else:
          # Hold the last decoded sample; the game clears the channel's status
          # (CH_ON) when the note ends, which deactivates us on the next frame.
          s.src_index = s.sample_count
          s.need_fetch = false
  m.frame_pos.inc
  if m.frame_len > 0 and m.frame_pos >= m.frame_len: m.frame_pos = m.frame_len
  # --- MP2K reverb: the m4a SoundMainRAM buffer-seed algorithm -----------------
  # Reference: pret pokeemerald src/m4a_1.s + include/gba/m4a_internal.h (with
  # loveemu's MP2K summary corroborating the "echo with fixed delay" design).
  # SoundInfo.pcmBuffer is s8 pcmBuffer[PCM_DMA_BUF_SIZE * 2]: the first half
  # is the FIFO-A (left) stream, the second the FIFO-B (right) stream (m4a.c
  # SoundInit: REG_DMA1SAD = pcmBuffer, REG_DMA2SAD = pcmBuffer +
  # PCM_DMA_BUF_SIZE). Each half is a ring of pcmDmaPeriod one-V-blank slots,
  # and the slot SoundMain is about to fill holds the audio mixed pcmDmaPeriod
  # V-blanks ago — the frame the DMA just finished playing (cursor derivation:
  # see on_frame). SoundMainRAM seeds that slot BEFORE any voice is mixed
  # (label SoundMainRAM_Reverb, ARM loop _081DCEC4): for each sample i of the
  # frame slot,
  #     sum = curL[i] + curR[i] + nextL[i] + nextR[i]
  #       — four signed-byte reads ("ldrsb"): BOTH stereo halves of the slot
  #         being overwritten (age pcmDmaPeriod frames) and of the FOLLOWING
  #         slot (age pcmDmaPeriod-1 frames; r7 = r5 + pcmSamplesPerVBlank,
  #         wrapping to slot 0 when pcmDmaCounter == 2: "cmp r4, 2 /
  #         addeq r7, r0, o_SoundInfo_pcmBuffer");
  #     out = (sum * reverb) asr 9        ("mul r1, r0, r3 / mov r0, r1, asr 9")
  #     if (out and 0x80) != 0: out += 1  ("tst r0, 0x80 / addne r0, r0, 1" —
  #         nudges negative results up one LSB toward zero)
  #     curL[i] = out; curR[i] = out      (ONE mono seed stored to both halves:
  #         "strb r0, [r5, r6] / strb r0, [r5], 1")
  # The channel loop then ACCUMULATES every voice on top of the seed — it loads
  # the existing buffer words and adds ("ldr r6, [r5] ... add r6, r1, r6,
  # ror 8 ... str r6, [r5], 0x4") — so the stored slot is the WET frame and
  # the seed is the feedback path: a two-tap (P and P-1 frames) feedback comb
  # with per-tap gain reverb/512 per sample pair. With reverb <= 127 the total
  # feedback gain is 4*127/512 < 1, so the loop is BIBO-stable, exactly like
  # the original. When reverb == 0 SoundMainRAM_NoReverb zero-fills the slot
  # instead and the voices accumulate onto silence — the buffer then simply
  # holds the dry mix.
  #
  # Mapping to this HLE's 32768 Hz render: the reference's seed addressing is
  # per-SLOT and intra-frame-indexed (sample i of this pass pairs with sample i
  # of the passes P and P-1 V-blanks ago), NOT a fixed sample-count delay. We
  # reproduce that shape directly at our rate: reverb_ring is rev_period slots
  # of MP2K_REV_SLOT_LEN stereo float samples; on_frame advances the slot
  # cursor once per mixer pass (as the real pcmDmaCounter-derived cursor does)
  # and rev_pos walks the slot per output sample, reading both taps at the
  # same intra-frame index before overwriting the current slot with this
  # pass's wet output. Our floats are in s8-buffer/128 units (a voice
  # contributes sample/128 * envelopeVolume/255, matching the reference's
  # byte-lane vol*sample accumulation scale), so "(sum * reverb) asr 9" maps
  # verbatim to sum_f * reverb / 512. Conscious deviations, each sub-LSB on
  # the reference's s8 scale (< 1/128 per tap, invisible in a float pipeline):
  # the bit7 +1 negative nudge and the s8 store quantization/wrap are omitted.
  # MONO vintages (see on_frame; e.g. Minish Cap) keep the same formula: our
  # two accumulator sides are identical there, so the four-read sum degrades
  # to 2*(cur + next) with the same /512 — the natural mono form of the
  # reference arithmetic (verified against the real FIFO by A/B RMS).
  var outl_f = accl
  var outr_f = accr
  if m.reverb_ring.len > 0:
    let cap  = MP2K_REV_SLOT_LEN
    let i    = (if m.rev_pos < cap: m.rev_pos else: cap - 1)
    let cur  = (m.rev_slot * cap + i) * 2
    let nxts = (if m.rev_slot + 1 >= m.rev_period: 0 else: m.rev_slot + 1)
    let nxt  = (nxts * cap + i) * 2
    if m.reverb_strength > 0'u8:
      let sum  = m.reverb_ring[cur] + m.reverb_ring[cur + 1] +
                 m.reverb_ring[nxt] + m.reverb_ring[nxt + 1]
      let seed = sum * float32(m.reverb_strength) * (1.0'f32 / 512.0'f32)
      outl_f = accl + seed
      outr_f = accr + seed
    # reverb == 0 must stay bit-identical to the no-reverb path: outl_f/outr_f
    # are untouched above, and this store only maintains the (dry) history —
    # matching the real NoReverb zero-fill + voice accumulation, after which
    # the pcmBuffer holds the dry frame.
    m.reverb_ring[cur]     = outl_f
    m.reverb_ring[cur + 1] = outr_f
    m.rev_pos.inc
  # Scale to the DirectSound latch range the APU expects. With the master-volume
  # double-apply fixed (see on_frame), the per-side envelope volumes already carry
  # the full engine gain, so this makeup is close to the pure linear ÷256 mixer
  # scale (~2.0). 2.1 centres the residual: HLE RMS lands within ~5% of the real
  # FIFO for FireRed (+4%), Emerald (+2%) and Advance Wars (-4%), peaks < 230 (the
  # clamp is +-512). Previously 2.3 with a masterVol double-apply left Pokémon
  # (masterVol 12/16) ~15-19% quiet — the "quiet snares" report.
  let MP2K_MAKEUP_GAIN = (if m.makeup > 0'f32: m.makeup else: 2.1'f32)
  let li = int32(outl_f * 127.0'f32 * MP2K_MAKEUP_GAIN)
  let ri = int32(outr_f * 127.0'f32 * MP2K_MAKEUP_GAIN)
  m.dbg_out_energy += abs(outl_f) + abs(outr_f)
  m.dbg_out_count.inc
  var outl = int16(clamp(li, -512, 511))
  var outr = int16(clamp(ri, -512, 511))
  # Route to the FIFO(s) the engine actually feeds (see on_frame). render_sample
  # returns (FIFO A, FIFO B). A mono driver drives a single FIFO; the other one
  # never receives data on real hardware, so it must be substituted with
  # silence — injecting our second accumulator there would add sound on a FIFO
  # the game may still have routed to a speaker.
  case m.mono_mode
  of 1: outr = 0            # mono via FIFO A (outl == outr already; B silent)
  of 2: outl = 0            # mono via FIFO B
  else: discard
  # DirectSound double-buffer: emit the sample from db_delay samples ago so the HLE
  # stream lags the mixer pass by one frame, exactly as the real driver's DMA lags
  # its pcmBuffer fill. Without this the HLE leads the hardware FIFO by ~one frame
  # (measured: best HLE/real cross-correlation sits at a one-frame lag). A plain
  # ring of db_delay stereo slots: the slot we are about to overwrite holds the
  # value written db_delay samples earlier.
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
  ## Initialise mixer state. Detection is fully runtime-driven (see
  ## mp2k_frame_poll / probe_pc): nothing to scan here — the hook address is
  ## learned once the game's sound engine initialises and runs its first pass.
  m.frame_len = APU_SAMPLE_RATE div 60
  m.use_cubic = true   # cubic (Catmull-Rom, per Paul Bourke) resampling by default
  # One output frame of DirectSound double-buffer latency (see render_sample). A
  # ring of frame_len stereo slots delays the HLE stream by exactly frame_len.
  m.db_delay = m.frame_len
  m.out_delay = newSeq[int16](m.frame_len * 2)
  m.out_delay_w = 0
