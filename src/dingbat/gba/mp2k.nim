# =============================================================================
# EXPLORATORY: MP2K / M4A ("Sappy") sound-engine HLE  (included by gba.nim)
# =============================================================================
# High-level-emulate the GBA's common MP2K music mixer, the way NanoBoyAdvance
# does: detect the engine in the ROM, read its SoundInfo struct out of guest
# RAM each audio frame, and render the DirectSound audio ourselves at a higher
# quality than the game's ~13 kHz FIFO stream.
#
# This is a PROOF OF CONCEPT, OFF BY DEFAULT (gba.mp2k_hle). It is NOT
# cycle-accurate and NOT wired into save-states / rollback / netplay. See the
# feasibility report accompanying this branch for the full design + risk notes.
#
# Technique credit: NanoBoyAdvance (fleroviux),
#   src/nba/src/core.cc  (detection + PC hook)
#   src/nba/src/hw/apu/hle/mp2k.{hh,cc}  (SoundInfo struct + mixer)
#
# Differences from NBA in this PoC (deliberate, for tractability):
#   * SHADOW mode only: the real SoundMainRAM still runs, so we piggyback on
#     the engine's already-computed per-channel envelope volumes (which already
#     include masterVolume + pan) instead of reimplementing MP2K's ADSR/volume
#     chain. NBA reimplements ADSR so it can PREDICT the next frame and ramp
#     current->next; we read the current frame's envelope at the hook (m4a
#     updates it in the sequencer, before this mixer) so there is no frame lag,
#     and ramp previous->current across the frame.
#   * Renders at the APU's 32768 Hz output rate, not NBA's 65536 Hz ring.
#   * 8-bit PCM, looping, AND m4a BDPCM ("compressed waveform", channel.type
#     bit5) — the latter is decoded to s8 and mixed at PCM parity (not skipped).

const
  MP2K_SOUNDMAIN_CRC32*   = 0x27EA7FCF'u32   # CRC-32 of SoundMain()'s first 48 bytes
  MP2K_SOUNDMAIN_LEN      = 48
  MP2K_SOUNDMAINRAM_OFF   = 0x74             # literal-pool offset to SoundMainRAM ptr
  MP2K_SOUNDINFO_PTR_ADDR = 0x03007FF0'u32   # IWRAM slot holding the SoundInfo pointer
  MP2K_MAGIC              = 0x68736D54'u32   # "Tmsh" little-endian
  MP2K_MAX_CHANNELS       = 12

  # SoundChannel field offsets (see NBA mp2k.hh)
  SC_STATUS   = 0x00
  SC_TYPE     = 0x01
  SC_VOL_R    = 0x02
  SC_VOL_L    = 0x03
  SC_ENV_VOL  = 0x09
  SC_ENV_VR   = 0x0A
  SC_ENV_VL   = 0x0B
  SC_FREQ     = 0x20
  SC_WAVE     = 0x24
  SC_SIZE     = 64

  # SoundInfo field offsets (see NBA mp2k.hh SoundInfo)
  SI_MAGIC        = 0x00
  SI_REVERB       = 0x05
  SI_MAX_CHANS    = 0x06
  SI_MASTER_VOL   = 0x07
  SI_PCM_RATE     = 0x14   # s32 pcm_sample_rate (DirectSound base rate)
  SI_CHANNELS     = 0x50

  # channel.type bits (NBA)
  TYPE_PCM_RATE = 0x08'u8  # step at SoundInfo.pcm_sample_rate, not channel.freq
  TYPE_COMPRESS = 0x20'u8  # m4a BDPCM compressed waveform

  # status bits
  CH_STOP = 0x40'u8
  CH_ON   = 0xC7'u8   # START|STOP|ECHO|ENV_MASK — "channel is producing sound"

  # m4a BDPCM 4-bit differential LUT (running s8 accumulator deltas). From the
  # m4a "compressed waveform" format; identical to NanoBoyAdvance's
  # kDifferentialLUT (there stored pre-divided by 127 — we keep raw s8 and
  # divide once at output, matching the uncompressed /128 path).
  BDPCM_LUT: array[16, float32] = [
    0.0'f32, 1, 4, 9, 16, 25, 36, 49,
    -64, -49, -36, -25, -16, -9, -4, -1
  ]
  # Compressed blocks are 33 bytes / 64 samples: 1 s8 base byte + 32 nibble
  # bytes (64 packed 4-bit LUT indices).
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

proc detect_mp2k*(rom: openArray[byte]): tuple[hook: uint32, entry: uint32] =
  ## Slide a 48-byte CRC window over the ROM looking for SoundMain(), then
  ## follow the SoundMainRAM pointer at offset 0x74. Returns (hook, entry):
  ## `hook` is past the 2-instruction prologue (safe shadow-read point) and
  ## `entry` is the first instruction (skip-mode return point). Both are
  ## 0xFFFFFFFF if this isn't an MP2K ROM.
  if rom.len < MP2K_SOUNDMAIN_LEN: return (0xFFFFFFFF'u32, 0xFFFFFFFF'u32)
  let amax = rom.len - MP2K_SOUNDMAIN_LEN
  var a = 0
  while a <= amax:
    # crc32 expects openArray[char]; reinterpret the byte slice
    let crc = crc32(cast[ptr UncheckedArray[char]](unsafeAddr rom[a]).toOpenArray(0, MP2K_SOUNDMAIN_LEN - 1))
    if crc == MP2K_SOUNDMAIN_CRC32:
      let raw = uint32(rom[a + MP2K_SOUNDMAINRAM_OFF]) or
                (uint32(rom[a + MP2K_SOUNDMAINRAM_OFF + 1]) shl 8) or
                (uint32(rom[a + MP2K_SOUNDMAINRAM_OFF + 2]) shl 16) or
                (uint32(rom[a + MP2K_SOUNDMAINRAM_OFF + 3]) shl 24)
      if (raw and 1) != 0:                 # Thumb pointer
        let entry = raw and not 1'u32
        return (entry + 4, entry)          # +4 = skip 2 Thumb instructions
      else:                                 # ARM pointer
        let entry = raw and not 3'u32
        return (entry + 8, entry)          # +8 = skip 2 ARM instructions
    a += 2
  (0xFFFFFFFF'u32, 0xFFFFFFFF'u32)

proc rd8(m: Mp2kHle; a: uint32): uint8  {.inline.} = m.gba.bus.read_byte_internal(a)
proc rd16(m: Mp2kHle; a: uint32): uint16 {.inline.} = m.gba.bus.read_half_internal(a)
proc rd32(m: Mp2kHle; a: uint32): uint32 {.inline.} = m.gba.bus.read_word_internal(a)

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
  # Lazily allocate the reverb delay ring the first frame a game asks for it.
  # 8 frames of stereo history, rounded to a power of two for cheap masking.
  if m.reverb_strength > 0'u8 and m.reverb_ring.len == 0:
    m.reverb_ring = newSeq[float32](8192 * 2)
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
    let retrig = not s.active or s.wave_data != new_wave_data or s.compressed != compressed
    when defined(mp2kwav):
      if retrig and dbgRetrigLog < 40:
        let el = int(m.rd8(base + SC_ENV_VL))
        let er = int(m.rd8(base + SC_ENV_VR))
        let ev = int(m.rd8(base + SC_ENV_VOL))
        echo "RETRIG ch=", i, " comp=", compressed, " env_vl=", el, " env_vr=", er, " env_vol=", ev
        dbgRetrigLog.inc
    if retrig:
      # (re)trigger: reset the resampler + decode state to the sample start.
      s.cur_pos = 0
      s.resample_phase = 0
      s.should_fetch = true
      s.hist0 = 0; s.hist1 = 0; s.hist2 = 0; s.hist3 = 0
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
    s.loop_pos    = m.rd32(wave + 8)
    s.num_samples = m.rd32(wave + 12)
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
    # Pokémon FR/Em at 12/16 — render ~19% too quiet). Shift last frame's end
    # value into vol_*0 and ramp toward this frame's value across the frame.
    let vl = float32(m.rd8(base + SC_ENV_VL)) / 255.0'f32 * master_mult
    let vr = float32(m.rd8(base + SC_ENV_VR)) / 255.0'f32 * master_mult
    s.vol_l0 = s.vol_l1
    s.vol_r0 = s.vol_r1
    s.vol_l1 = vl
    s.vol_r1 = vr
  m.frame_seen = true
  m.engaged = true

proc mixer_hook*(m: Mp2kHle) =
  ## PC-hook entry: called from cpu.tick when r15 reaches SoundMainRAM. Reads
  ## the SoundInfo pointer and, if valid, refreshes the mixer state.
  let sip = m.rd32(MP2K_SOUNDINFO_PTR_ADDR)
  if (sip shr 24) == 0: return                 # not yet initialised
  if m.rd32(sip + SI_MAGIC) != MP2K_MAGIC: return
  m.on_frame(sip)

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
  ## Decode the source sample at s.cur_pos, returned in raw s8 units
  ## (~ -128..127). For BDPCM the running accumulator is carried in s.hist0
  ## (the newest history entry) and re-synced to the block base byte every 64
  ## samples, exactly as NanoBoyAdvance / m4a do.
  if s.compressed:
    let pos = s.cur_pos
    let block_offset  = pos and (BDPCM_BLOCK_SAMPS - 1)      # pos % 64
    let block_address = (pos shr 6) * BDPCM_BLOCK_BYTES      # (pos/64)*33
    var samp: float32
    if block_offset == 0'u32:
      samp = float32(cast[int8](m.wave_u8(s, rom, rmask, block_address)))
    else:
      samp = s.hist0                                          # running value
    let address = block_address + (block_offset shr 1) + 1'u32
    var lut_index = m.wave_u8(s, rom, rmask, address)
    if (block_offset and 1'u32) != 0'u32: lut_index = lut_index and 0x0F'u8
    else:                                 lut_index = lut_index shr 4
    samp += BDPCM_LUT[lut_index]
    samp
  else:
    float32(cast[int8](m.wave_u8(s, rom, rmask, s.cur_pos)))

proc render_sample*(m: Mp2kHle): tuple[l: int16, r: int16] =
  ## Produce one stereo output sample at the APU's rate (32768 Hz). Replaces
  ## the DirectSound FIFO A/B contribution when engaged. Returns signed values
  ## roughly in the FIFO latch range (~ -128*2 .. 127*2) so the existing APU
  ## DirectSound scaling path applies unchanged.
  ##
  ## Per-channel resampler follows NBA's forward-stepping model: keep a 4-tap
  ## sample history + fractional phase, fetch a new source sample only when the
  ## phase crosses an integer, and interpolate (cubic Catmull-Rom or linear).
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
    if s.should_fetch and s.cur_pos < s.num_samples:
      let ns = m.decode_src(s, rom, rmask)
      s.hist3 = s.hist2; s.hist2 = s.hist1; s.hist1 = s.hist0; s.hist0 = ns
      s.should_fetch = false
    let mu = s.resample_phase
    var sample: float32
    if m.resample_mode == 2:
      sample = s.hist0                      # zero-order hold (matches raw FIFO)
    elif m.resample_mode == 1 or not cubic:
      sample = s.hist0 * mu + s.hist1 * (1.0'f32 - mu)
    elif cubic:
      # Catmull-Rom / cubic (paulbourke). hist0=newest .. hist3=oldest.
      let mu2 = mu * mu
      let a0 = s.hist0 - s.hist1 - s.hist3 + s.hist2
      let a1 = s.hist3 - s.hist2 - a0
      let a2 = s.hist1 - s.hist3
      let a3 = s.hist2
      sample = a0 * mu * mu2 + a1 * mu2 + a2 * mu + a3
    else:
      sample = s.hist0 * mu + s.hist1 * (1.0'f32 - mu)
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
    s.resample_phase += rate / float32(APU_SAMPLE_RATE)
    if s.resample_phase >= 1.0'f32:
      let n = uint32(s.resample_phase)
      s.resample_phase -= float32(n)
      s.cur_pos += n
      s.should_fetch = true
      if s.cur_pos >= s.num_samples:
        if s.looping:
          s.cur_pos = s.loop_pos + n - 1'u32
        else:
          # Hold the last decoded sample; the game clears the channel's status
          # (CH_ON) when the note ends, which deactivates us on the next frame.
          s.cur_pos = s.num_samples
          s.should_fetch = false
  m.frame_pos.inc
  if m.frame_len > 0 and m.frame_pos >= m.frame_len: m.frame_pos = m.frame_len
  # --- MP2K reverb (NBA multi-tap over a stereo delay ring) --------------------
  # Only engaged when the game sets SoundInfo.reverb > 0. The ring stores the
  # post-mix (dry+wet) signal so the taps feed back, matching NBA's frame ring.
  var outl_f = accl
  var outr_f = accr
  if m.reverb_strength > 0'u8 and m.reverb_ring.len >= 2:
    let ringN = uint32(m.reverb_ring.len shr 1)   # stereo slots (power of two)
    let mask  = ringN - 1'u32
    let fl    = uint32(m.frame_len)
    let w     = uint32(m.reverb_w)
    template tapL(df: uint32): float32 = m.reverb_ring[(((w - df*fl) and mask) shl 1)]
    template tapR(df: uint32): float32 = m.reverb_ring[(((w - df*fl) and mask) shl 1) + 1]
    const earlyC = 0.0015'f32
    const norm   = 1.0'f32 / 2.65'f32   # 1/sum of late coefficients
    let el = tapL(1'u32) * earlyC
    let er = tapR(1'u32) * earlyC
    # late reflections 5,6,7 frames back, cross-mixed (coeffs {1,.1}{.6,.25}{.35,.35})
    let l0 = tapL(5'u32); let r0 = tapR(5'u32)
    let l1 = tapL(6'u32); let r1 = tapR(6'u32)
    let l2 = tapL(7'u32); let r2 = tapR(7'u32)
    let ll = (l0*1.0'f32 + r0*0.1'f32 + l1*0.6'f32 + r1*0.25'f32 + l2*0.35'f32 + r2*0.35'f32) * norm
    let rr = (l0*0.1'f32 + r0*1.0'f32 + l1*0.25'f32 + r1*0.6'f32 + l2*0.35'f32 + r2*0.35'f32) * norm
    let rsc = (if m.rev_scale < 0'f32: 0.0'f32
               elif m.rev_scale > 0'f32: m.rev_scale else: 1.0'f32)
    let factor = float32(m.reverb_strength) / 128.0'f32 * rsc
    outl_f = accl + (el + ll) * factor
    outr_f = accr + (er + rr) * factor
    let idx = (w and mask) shl 1
    m.reverb_ring[idx]     = outl_f
    m.reverb_ring[idx + 1] = outr_f
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
  when defined(mp2kwav):
    mp2kWavCapture.add outl
    mp2kWavCapture.add outr
  (outl, outr)

proc init_mp2k*(m: Mp2kHle) =
  ## Run detection against the loaded cartridge. Safe to call after the ROM is
  ## in memory. Leaves hook_addr = 0xFFFFFFFF when the engine isn't found.
  m.frame_len = APU_SAMPLE_RATE div 60
  m.use_cubic = true   # cubic (Catmull-Rom) resampling by default (NBA-style)
  let (hook, entry) = detect_mp2k(m.gba.cartridge.rom)
  m.hook_addr = hook
  m.entry_addr = entry
