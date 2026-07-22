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
#     the engine's already-computed per-channel envelope volumes instead of
#     reimplementing MP2K's ADSR state machine. (NBA reimplements ADSR so it
#     can predict the next frame; we lag one frame and linearly ramp.)
#   * Renders at the APU's 32768 Hz output rate, not NBA's 65536 Hz ring.
#   * Raw 8-bit PCM + looping only. BDPCM-compressed samples (channel.type
#     bit5) are detected and skipped (silenced) — flagged, not mixed.

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

  # SoundInfo field offsets
  SI_MAGIC        = 0x00
  SI_MAX_CHANS    = 0x06
  SI_MASTER_VOL   = 0x07
  SI_CHANNELS     = 0x50

  # status bits
  CH_STOP = 0x40'u8
  CH_ON   = 0xC7'u8   # START|STOP|ECHO|ENV_MASK — "channel is producing sound"

# NOTE: Mp2kSampler / Mp2kHle types live in gba.nim's main type section (Nim
# requires types referenced by the GBA object to be declared before use).

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
  let master = float32(int(m.rd8(sound_info + SI_MASTER_VOL)) + 1) / 16.0'f32
  var maxc = int(m.rd8(sound_info + SI_MAX_CHANS))
  if maxc > MP2K_MAX_CHANNELS: maxc = MP2K_MAX_CHANNELS
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
    if (ctype and 0x20) != 0:           # BDPCM-compressed — not handled in PoC
      if s.active: discard
      s.active = false
      m.compressed_skipped.inc
      continue
    let wave = m.rd32(base + SC_WAVE)
    if wave == 0 or (wave shr 24) == 0: # null / bogus pointer
      s.active = false
      continue
    let loop_status = m.rd16(wave + 2)
    let looping = (loop_status and 0xC000'u16) != 0
    let new_wave_data = wave + 16
    if not s.active or s.wave_data != new_wave_data:
      # (re)trigger: reset the cursor to the sample start
      s.position = 0
      s.active = true
    s.wave_data   = new_wave_data
    s.freq        = m.rd32(wave + 4)
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
    # Envelope volumes already scaled by the real mixer (0..255-ish). Ramp
    # from last frame's end value to this frame's value across the frame.
    let vl = float32(m.rd8(base + SC_ENV_VL)) / 255.0'f32 * master
    let vr = float32(m.rd8(base + SC_ENV_VR)) / 255.0'f32 * master
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

proc render_sample*(m: Mp2kHle): tuple[l: int16, r: int16] =
  ## Produce one stereo output sample at the APU's rate (32768 Hz). Replaces
  ## the DirectSound FIFO A/B contribution when engaged. Returns signed values
  ## roughly in the FIFO latch range (~ -128*2 .. 127*2) so the existing APU
  ## DirectSound scaling path applies unchanged.
  if not m.engaged: return (0'i16, 0'i16)
  var accl = 0.0'f32
  var accr = 0.0'f32
  let t = (if m.frame_len > 0: float32(m.frame_pos) / float32(m.frame_len) else: 0.0'f32)
  let rom = addr m.gba.cartridge.rom
  let rmask = m.gba.cartridge.rom_mask
  for i in 0 ..< MP2K_MAX_CHANNELS:
    let s = addr m.samplers[i]
    if not s.active: continue
    let idx = uint32(s.position)
    if idx >= s.num_samples:
      if s.looping:
        s.position = float32(s.loop_pos)
      else:
        s.active = false
      continue
    # linear interpolation between sample[idx] and sample[idx+1]
    let frac = s.position - float32(idx)
    var nxt = idx + 1
    if nxt >= s.num_samples: nxt = (if s.looping: s.loop_pos else: idx)
    var s0, s1: float32
    if s.in_rom:
      # Fast path: read signed 8-bit PCM straight from the cartridge buffer.
      s0 = float32(cast[int8](rom[][(s.rom_off + idx) and rmask]))
      s1 = float32(cast[int8](rom[][(s.rom_off + nxt) and rmask]))
    else:
      s0 = float32(cast[int8](m.rd8(s.wave_data + idx)))
      s1 = float32(cast[int8](m.rd8(s.wave_data + nxt)))
    let sample = (s0 * (1.0'f32 - frac) + s1 * frac) / 128.0'f32
    let vl = s.vol_l0 * (1.0'f32 - t) + s.vol_l1 * t
    let vr = s.vol_r0 * (1.0'f32 - t) + s.vol_r1 * t
    accl += sample * vl
    accr += sample * vr
    # advance the sample cursor by freq / output-rate
    s.position += float32(s.freq) / float32(APU_SAMPLE_RATE)
  m.frame_pos.inc
  if m.frame_len > 0 and m.frame_pos >= m.frame_len: m.frame_pos = m.frame_len
  # Scale to the DirectSound latch range the APU expects (int8 << 1)
  let li = int32(accl * 127.0'f32)
  let ri = int32(accr * 127.0'f32)
  m.dbg_out_energy += abs(accl) + abs(accr)
  m.dbg_out_count.inc
  (int16(clamp(li, -512, 511)), int16(clamp(ri, -512, 511)))

proc init_mp2k*(m: Mp2kHle) =
  ## Run detection against the loaded cartridge. Safe to call after the ROM is
  ## in memory. Leaves hook_addr = 0xFFFFFFFF when the engine isn't found.
  m.frame_len = APU_SAMPLE_RATE div 60
  let (hook, entry) = detect_mp2k(m.gba.cartridge.rom)
  m.hook_addr = hook
  m.entry_addr = entry
