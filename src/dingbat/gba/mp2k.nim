# =============================================================================
# EXPLORATORY: MP2K / M4A ("Sappy") sound-engine HLE  (included by gba.nim)
# =============================================================================
# High-level-emulate the GBA's common MP2K music mixer: detect the engine at
# runtime via its SoundInfo work area in guest RAM (no ROM signature — see the
# "Runtime detection" section below), read the SoundInfo struct each audio
# frame, and render the DirectSound audio ourselves at a higher quality than
# the game's ~13 kHz FIFO stream.
#
# This is a PROOF OF CONCEPT, OFF BY DEFAULT (gba.mp2k_hle). It is NOT
# cycle-accurate and NOT wired into save-states / rollback / netplay.
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
  MP2K_PROBE_MAX_FAILS    = 8                # give up learning after this many mislearns
  MP2K_MAX_CHANNELS       = 12

  # SoundChannel field offsets, derived from m4a_internal.h (pret):
  #   statusFlags(0) type(1) rightVolume(2) leftVolume(3) ... envelopeVolume(9)
  #   envelopeVolumeRight(10) envelopeVolumeLeft(11) ... frequency(0x20) wav(0x24)
  SC_STATUS   = 0x00
  SC_TYPE     = 0x01
  SC_VOL_R    = 0x02
  SC_VOL_L    = 0x03
  SC_ENV_VOL  = 0x09
  SC_ENV_VR   = 0x0A   # envelopeVolumeRight
  SC_ENV_VL   = 0x0B   # envelopeVolumeLeft
  SC_FREQ     = 0x20   # frequency (per-note playback rate, Hz)
  SC_WAVE     = 0x24   # wav pointer -> WaveData
  SC_SIZE     = 64

  # SoundInfo field offsets, derived from m4a_internal.h (pret):
  #   ident(0) pcmDmaCounter(4) reverb(5) maxChans(6) masterVolume(7) ...
  #   pcmSamplesPerVBlank(0x10) pcmFreq(0x14) ... chans[](0x50)
  SI_MAGIC        = 0x00   # ident
  SI_REVERB       = 0x05   # reverb (0 = off)
  SI_MAX_CHANS    = 0x06   # maxChans
  SI_MASTER_VOL   = 0x07   # masterVolume
  SI_PCM_RATE     = 0x14   # pcmFreq (DirectSound base sample rate)
  SI_CHANNELS     = 0x50   # chans[MAX_DIRECTSOUND_CHANNELS]

  # channel.type bits (m4a SoundChannel.type)
  TYPE_PCM_RATE = 0x08'u8  # step at SoundInfo.pcmFreq, not channel.frequency
  TYPE_COMPRESS = 0x20'u8  # m4a BDPCM compressed waveform

  # status bits (m4a SoundChannel.statusFlags)
  CH_STOP = 0x40'u8
  CH_ON   = 0xC7'u8   # START|STOP|ECHO|ENV_MASK — "channel is producing sound"

  # m4a compressed-waveform ("GFDPCM"/BDPCM) 4-bit differential LUT: the 16
  # signed deltas added to a running s8 accumulator. These values are a fixed
  # property of Nintendo's format, independently documented by agbplay (ipatix):
  #   [0, 1, 4, 9, 16, 25, 36, 49, -64, -49, -36, -25, -16, -9, -4, -1].
  # We store them as raw s8 deltas and divide once at output (/128), so the
  # compressed and uncompressed paths share the same output scaling.
  BDPCM_LUT: array[16, float32] = [
    0.0'f32, 1, 4, 9, 16, 25, 36, 49,
    -64, -49, -36, -25, -16, -9, -4, -1
  ]
  # Compressed blocks are 33 bytes / 64 samples: 1 s8 base byte + 32 nibble
  # bytes (64 packed 4-bit LUT indices). (agbplay corroborates this layout.)
  BDPCM_BLOCK_BYTES  = 33'u32
  BDPCM_BLOCK_SAMPS  = 64'u32

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
  m.reverb_strength = m.rd8(sound_info + SI_REVERB)
  m.pcm_sample_rate = int(m.rd32(sound_info + SI_PCM_RATE))
  m.dbg_reverb = m.reverb_strength
  m.dbg_pcm_rate = m.pcm_sample_rate
  when defined(mp2kwav): dbgMaster = int(m.rd8(sound_info + SI_MASTER_VOL))
  # Lazily allocate the reverb echo line the first frame a game asks for it.
  # MP2K's reverb is "a simple reverb (echo) effect with fixed delay" (loveemu),
  # so a single delay line one output frame long is all we need. Size it to a
  # power of two >= one frame of stereo samples for cheap index masking.
  if m.reverb_strength > 0'u8 and m.reverb_ring.len == 0:
    var slots = 1'u32
    while slots < uint32(max(1, m.frame_len)): slots = slots shl 1
    m.reverb_ring = newSeq[float32](int(slots) * 2)
    m.reverb_w = 0
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
    let compressed = (ctype and TYPE_COMPRESS) != 0
    let wave = m.rd32(base + SC_WAVE)
    if wave == 0 or (wave shr 24) == 0: # null / bogus pointer
      s.active = false
      continue
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
    let started = (status and 0x80'u8) != 0
    let retrig = (started and use_start) or
                 not s.active or s.wave_data != new_wave_data or s.compressed != compressed
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
    if retrig:
      # (re)trigger: reset the resampler + decode state to the sample start.
      s.src_index = 0
      s.phase_frac = 0
      s.need_fetch = true
      s.tap0 = 0; s.tap1 = 0; s.tap2 = 0; s.tap3 = 0
      s.active = true
      s.age = 0
    else:
      s.age.inc
    s.wave_data   = new_wave_data
    s.compressed  = compressed
    if compressed: m.dbg_compressed_used.inc
    s.use_pcm_rate = (ctype and TYPE_PCM_RATE) != 0
    # Resample rate = the CHANNEL's per-note playback frequency (SoundChannel
    # +0x20, in Hz), NOT the sample header's base freq at wave+4 (a large
    # fixed-point value). Using the latter advanced the cursor ~200 samples per
    # output sample — the high-pitch whine. step = freq / output_rate.
    s.freq        = m.rd32(base + SC_FREQ)
    s.loop_start  = m.rd32(wave + 8)    # WaveData.loopStart
    s.sample_count = m.rd32(wave + 12)  # WaveData.size
    s.looping     = looping
    # Fast path: cache a direct ROM offset so the per-sample mixer can read the
    # cartridge buffer without going through the bus address decoder. m4a sample
    # banks live in ROM (0x08000000..0x0DFFFFFF).
    let wave_region = new_wave_data shr 24
    s.in_rom = wave_region >= 0x08'u32 and wave_region <= 0x0D'u32
    if s.in_rom:
      s.rom_off = (new_wave_data and 0x01FFFFFF'u32)
    # SC_ENV_VL/VR (0x0B/0x0A) are the engine's per-side volumes: envelopeVolume
    # * (leftVolume|rightVolume) >> 8, and leftVolume/rightVolume ALREADY fold in
    # SoundInfo.masterVolume. So we consume them directly and must NOT re-apply
    # master (doing so double-applied it, making games with masterVol<15 — e.g.
    # Pokémon FR/Em at 12/16 — render ~19% too quiet). The real mixer writes these
    # once per SoundMainRAM pass, so they are a per-frame constant; the hook reads
    # the value in force for this frame. Shift last frame's endpoint into vol_*0 and
    # ramp toward this frame's value across the frame, mirroring the real driver's
    # per-sample volume interpolation from the previous endpoint.
    let vl = float32(m.rd8(base + SC_ENV_VL)) / 255.0'f32 * master_mult
    let vr = float32(m.rd8(base + SC_ENV_VR)) / 255.0'f32 * master_mult
    s.vol_l0 = s.vol_l1
    s.vol_r0 = s.vol_r1
    s.vol_l1 = vl
    s.vol_r1 = vr
  m.frame_seen = true
  m.engaged = true

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
    if m.rd32(sip + SI_MAGIC) == MP2K_IDENT_LOCK:
      m.on_frame(sip)
      return
  m.unlearn_hook()

proc probe_pc*(m: Mp2kHle; pc: uint32) {.noinline.} =
  ## Learning probe, called from cpu.tick only while probing is armed and only
  ## for instructions fetched from RAM with r0 == &SoundInfo (both prefiltered
  ## inline). If the engine lock is held right now, this PC is the SoundMainRAM
  ## mixer entry: learn it and run the first shadow pass immediately (the entry
  ## has not executed yet, so channel state is exactly what the hook would see).
  if m.rd32(m.probe_sound_info + SI_MAGIC) != MP2K_IDENT_LOCK: return
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
    if ident != MP2K_IDENT_IDLE and ident != MP2K_IDENT_LOCK and m.engaged:
      m.engaged = false
      for i in 0 ..< MP2K_MAX_CHANNELS: m.samplers[i].active = false
    return
  # Arm probing only when the engine is at rest (ident == ID_NUMBER): arming
  # mid-pass could learn a mid-mixer PC instead of the entry.
  m.probing = ident == MP2K_IDENT_IDLE and m.probe_fails < MP2K_PROBE_MAX_FAILS
  if m.probing: m.probe_sound_info = sip

when defined(mp2kwav):
  proc mp2k_decode_bdpcm*(data: openArray[byte]; num_samples: int): seq[float32] =
    ## Standalone reference decode of an m4a BDPCM ("compressed waveform")
    ## buffer, in raw s8 units. Mirrors decode_src() below exactly (the running
    ## accumulator there is carried in the newest history slot). Used by the
    ## test harness to validate the LUT + 33-byte/64-sample block layout against
    ## hand-computed values.
    result = newSeq[float32](num_samples)
    var running = 0.0'f32
    for pos in 0 ..< num_samples:
      let block_offset  = uint32(pos) and (BDPCM_BLOCK_SAMPS - 1)
      let block_address = (uint32(pos) shr 6) * BDPCM_BLOCK_BYTES
      var samp: float32
      if block_offset == 0'u32: samp = float32(cast[int8](data[block_address]))
      else:                     samp = running
      let address = block_address + (block_offset shr 1) + 1'u32
      var lut = data[address]
      if (block_offset and 1'u32) != 0'u32: lut = lut and 0x0F'u8
      else:                                 lut = lut shr 4
      samp += BDPCM_LUT[lut]
      running = samp
      result[pos] = samp

proc wave_u8(m: Mp2kHle; s: ptr Mp2kSampler; rom: ptr seq[byte]; rmask: uint32;
             byteoff: uint32): uint8 {.inline.} =
  ## Read one raw byte of the sample bank (fast ROM path or bus fallback).
  if s.in_rom: rom[][(s.rom_off + byteoff) and rmask]
  else:        m.rd8(s.wave_data + byteoff)

proc decode_src(m: Mp2kHle; s: ptr Mp2kSampler; rom: ptr seq[byte];
                rmask: uint32): float32 {.inline.} =
  ## Decode the source sample at s.src_index, returned in raw s8 units
  ## (~ -128..127). For BDPCM the running accumulator is carried in s.tap0 (the
  ## newest history entry) and re-synced to each 64-sample block's s8 base byte,
  ## per the m4a compressed-waveform format (see BDPCM_LUT / block constants).
  if s.compressed:
    let pos = s.src_index
    let block_offset  = pos and (BDPCM_BLOCK_SAMPS - 1)      # pos % 64
    let block_address = (pos shr 6) * BDPCM_BLOCK_BYTES      # (pos/64)*33
    var samp: float32
    if block_offset == 0'u32:
      samp = float32(cast[int8](m.wave_u8(s, rom, rmask, block_address)))
    else:
      samp = s.tap0                                           # running value
    let address = block_address + (block_offset shr 1) + 1'u32
    var lut_index = m.wave_u8(s, rom, rmask, address)
    if (block_offset and 1'u32) != 0'u32: lut_index = lut_index and 0x0F'u8
    else:                                 lut_index = lut_index shr 4
    samp += BDPCM_LUT[lut_index]
    samp
  else:
    float32(cast[int8](m.wave_u8(s, rom, rmask, s.src_index)))

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
    # Advance the resample phase; step = playback-rate / output-rate.
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
        if s.looping:
          s.src_index = s.loop_start + n - 1'u32
        else:
          # Hold the last decoded sample; the game clears the channel's status
          # (CH_ON) when the note ends, which deactivates us on the next frame.
          s.src_index = s.sample_count
          s.need_fetch = false
  m.frame_pos.inc
  if m.frame_len > 0 and m.frame_pos >= m.frame_len: m.frame_pos = m.frame_len
  # --- MP2K reverb: simple fixed-delay feedback echo ---------------------------
  # loveemu documents MP2K's reverb as "a simple reverb (echo) effect with fixed
  # delay", and the real m4a SoundMainRAM implements it as a feedback average
  # over the DirectSound (pcmBuffer) samples one buffer-drain behind. We model
  # that directly with a single delay line exactly one output frame long: read
  # the signal from one frame ago, average the two channels into a single mono
  # echo value (the real driver applies one shared reverb value to both sides),
  # scale it by SoundInfo.reverb, add it to the dry mix, and store the wet result
  # back so the echo feeds back and decays over successive frames.
  #
  # The feedback gain k = reverb/128 is clamped strictly below unity, so the
  # single-tap loop is unconditionally BIBO-stable (the tail decays as k^n) —
  # no runaway. Engaged only when SoundInfo.reverb > 0; it is a minor part of
  # the mix. All coefficients and structure here are our own.
  var outl_f = accl
  var outr_f = accr
  if m.reverb_strength > 0'u8 and m.reverb_ring.len >= 2:
    let slots = uint32(m.reverb_ring.len shr 1)   # stereo slots (power of two)
    let mask  = slots - 1'u32
    let w     = uint32(m.reverb_w)
    let delay = uint32(m.frame_len)               # fixed delay: one output frame
    let ri    = ((w - delay) and mask) shl 1
    let wet   = 0.5'f32 * (m.reverb_ring[ri] + m.reverb_ring[ri + 1])  # mono echo
    let rsc   = (if m.rev_scale < 0'f32: 0.0'f32
                 elif m.rev_scale > 0'f32: m.rev_scale else: 1.0'f32)
    let k     = min(0.75'f32, float32(m.reverb_strength) / 128.0'f32 * rsc)
    outl_f = accl + wet * k
    outr_f = accr + wet * k
    let wi = (w and mask) shl 1
    m.reverb_ring[wi]     = outl_f
    m.reverb_ring[wi + 1] = outr_f
    m.reverb_w = int((w + 1'u32) and mask)
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
  let outl = int16(clamp(li, -512, 511))
  let outr = int16(clamp(ri, -512, 511))
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
