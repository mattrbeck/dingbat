# Sweep-triage diagnostic: boot N frames with the HLE armed and dump the m4a
# SoundInfo topology — SOUND_INFO_PTR, ident, where the FIFO DMAs actually
# source from vs. the SoundInfo.pcmBuffer, per-channel status — to root-cause
# detection misses and foreign-FIFO games.
#   nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc -o:sweepdiag --path:src scratch_sweepdiag.nim
#   ./sweepdiag <rom> [frames=900] [dump_every=0]
import std/[os, strutils, math]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = getEnv("DINGBAT_NOHLE") != "1"
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 900
  let every = if paramCount() >= 3: parseInt(paramStr(3)) else: 0
  proc dump(f: int) =
    let sip = emu.bus.read_word_internal(0x03007FF0'u32)
    var line = "f=" & $f & " sip=" & toHex(sip, 8)
    if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
      line.add " ident=" & toHex(emu.bus.read_word_internal(sip), 8)
      line.add " maxChans=" & $emu.bus.read_byte_internal(sip + 6)
      line.add " pcmBuf=" & toHex(sip + 0x350'u32, 8)
      var active = 0
      for i in 0 ..< 12:
        let st = emu.bus.read_byte_internal(sip + 0x50'u32 + uint32(i)*64)
        if (st and 0xC7'u8) != 0: active.inc
      line.add " activeCh=" & $active
    for c in 1 .. 2:
      if emu.dma.dmacnt_h[c].enable:
        line.add " dma" & $c & "[sad=" & toHex(emu.dma.dmasad[c], 8) &
                 " dad=" & toHex(emu.dma.dmadad[c], 8) &
                 " timing=" & $emu.dma.dmacnt_h[c].start_timing & "]"
    line.add " engaged=" & $emu.mp2k.engaged &
             " hook=" & toHex(emu.mp2k.hook_addr, 8) &
             " fires=" & $emu.mp2k.dbg_hook_fires
    line.add " foreign=" & $emu.mp2k.fifo_foreign &
             " streak=" & $emu.mp2k.foreign_streak &
             " cpuFifoBytes=" & $emu.mp2k.fifo_cpu_bytes &
             " realAvg=" & $emu.mp2k.dbg_real_avg &
             " hleAvg=" & $emu.mp2k.dbg_hle_avg
    if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
      let spv = emu.bus.read_word_internal(sip + 0x10)
      let period = emu.bus.read_byte_internal(sip + 0x0B)
      var pk = 0
      for off in 0 ..< 0xC60:
        let b = cast[int8](emu.bus.read_byte_internal(sip + 0x350'u32 + uint32(off)))
        if abs(int(b)) > pk: pk = abs(int(b))
      line.add " spv=" & $spv & " period=" & $period & " bufPeak(0xC60)=" & $pk
    line.add " dmaSrcInternal[1]=" & toHex(emu.dma.src[1], 8) &
             " [2]=" & toHex(emu.dma.src[2], 8)
    echo line
  var lastN = 0
  for f in 0 ..< frames:
    emu.step_frame()
    if every > 0 and f mod every == 0:
      dump(f)
      var a = 0.0
      for i in lastN ..< realDmaCapture.len:
        a += float(realDmaCapture[i]) * float(realDmaCapture[i])
      if realDmaCapture.len > lastN:
        echo "  segRealRms=", sqrt(a / float(realDmaCapture.len - lastN)),
             " n=", realDmaCapture.len - lastN
      lastN = realDmaCapture.len
  dump(frames)
  proc rms(s: seq[int16]): float =
    if s.len == 0: return 0
    var a = 0.0
    for v in s: a += float(v) * float(v)
    sqrt(a / float(s.len))
  echo "HLE rms=", rms(mp2kWavCapture), "  REAL rms=", rms(realDmaCapture),
       "  retrig=", dbgRetrigCount

main()
