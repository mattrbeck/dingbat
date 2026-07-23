## MC in-game HLE-vs-REAL diagnostic: load state, run frames, dump everything.
import std/[os, strutils, math, streams]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  if not emu.load_state(paramStr(2)):
    echo "LOAD STATE FAILED"; quit(1)
  emu.mp2k_hle = true
  if getEnv("DINGBAT_RSMODE") != "": emu.mp2k.resample_mode = parseInt(getEnv("DINGBAT_RSMODE"))
  if getEnv("DINGBAT_REVSC") != "": emu.mp2k.rev_scale = parseFloat(getEnv("DINGBAT_REVSC"))
  if getEnv("DINGBAT_ENVMODE") != "": emu.mp2k.env_mode = parseInt(getEnv("DINGBAT_ENVMODE"))
  if getEnv("DINGBAT_MAKEUP") != "": emu.mp2k.makeup = parseFloat(getEnv("DINGBAT_MAKEUP"))
  let frames = if paramCount() >= 3: parseInt(paramStr(3)) else: 600
  for f in 0 ..< frames:
    emu.step_frame()
    if f == frames div 2:
      # mid-run live SoundInfo dump
      let sip = emu.bus.read_word_internal(0x03007FF0'u32)
      echo "SoundInfo @", toHex(sip),
        " ident=", toHex(emu.bus.read_word_internal(sip)),
        " reverb=", int(emu.bus.read_byte_internal(sip + 5)),
        " maxChans=", int(emu.bus.read_byte_internal(sip + 6)),
        " masterVol=", int(emu.bus.read_byte_internal(sip + 7)),
        " pcmFreq=", int(emu.bus.read_word_internal(sip + 0x14))
      echo "SOUNDCNT_H: aVol=", int(emu.apu.soundcnt_h.dma_sound_a_volume),
        " aR=", int(emu.apu.soundcnt_h.dma_sound_a_right),
        " aL=", int(emu.apu.soundcnt_h.dma_sound_a_left),
        " aTimer=", int(emu.apu.soundcnt_h.dma_sound_a_timer),
        " bVol=", int(emu.apu.soundcnt_h.dma_sound_b_volume),
        " bR=", int(emu.apu.soundcnt_h.dma_sound_b_right),
        " bL=", int(emu.apu.soundcnt_h.dma_sound_b_left),
        " bTimer=", int(emu.apu.soundcnt_h.dma_sound_b_timer)
      echo "DMA1 dad=", toHex(emu.dma.dmadad[1]), " en=", int(emu.dma.dmacnt_h[1].enable),
           "  DMA2 dad=", toHex(emu.dma.dmadad[2]), " en=", int(emu.dma.dmacnt_h[2].enable)
      var hexrow = ""
      for off in 0'u32 ..< 0x20'u32:
        hexrow.add toHex(int(emu.bus.read_byte_internal(sip + off)), 2) & " "
      echo "SoundInfo[0x00..0x1F]: ", hexrow
      # live channel table
      for i in 0 ..< 12:
        let base = sip + uint32(0x50 + i * 64)
        let st = emu.bus.read_byte_internal(base)
        if (st and 0xC7'u8) == 0: continue
        echo "  ch", i, " st=", toHex(int(st), 2),
          " type=", toHex(int(emu.bus.read_byte_internal(base + 1)), 2),
          " rV=", int(emu.bus.read_byte_internal(base + 2)),
          " lV=", int(emu.bus.read_byte_internal(base + 3)),
          " evol=", int(emu.bus.read_byte_internal(base + 9)),
          " evr=", int(emu.bus.read_byte_internal(base + 10)),
          " evl=", int(emu.bus.read_byte_internal(base + 11)),
          " freq=", int(emu.bus.read_word_internal(base + 0x20)),
          " wave=", toHex(emu.bus.read_word_internal(base + 0x24))
  mp2k_write_wav("/tmp/mc_hle.wav")
  block:
    let s = newFileStream("/tmp/mc_real.wav", fmWrite)
    let nn = realDmaCapture.len
    s.write("RIFF"); s.write(uint32(36 + nn*2)); s.write("WAVE")
    s.write("fmt "); s.write(uint32(16)); s.write(uint16(1)); s.write(uint16(2))
    s.write(uint32(32768)); s.write(uint32(32768*4)); s.write(uint16(4)); s.write(uint16(16))
    s.write("data"); s.write(uint32(nn*2))
    for v in realDmaCapture: s.write(v)
    s.close()
  proc rms(s: seq[int16]): float =
    if s.len == 0: return 0
    var a = 0.0
    for v in s: a += float(v) * float(v)
    sqrt(a / float(s.len))
  echo "engaged=", emu.mp2k.engaged, "  retriggers=", dbgRetrigCount,
       "  hook_fires=", emu.mp2k.dbg_hook_fires
  echo "reverb_strength=", int(emu.mp2k.reverb_strength),
       "  pcm_rate=", emu.mp2k.pcm_sample_rate,
       "  dbgMaster=", dbgMaster
  echo "HLE rms=", rms(mp2kWavCapture), "  REAL rms=", rms(realDmaCapture)
  mp2k_dump_voices()
  mp2k_dump_attack()

main()
