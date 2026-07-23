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
      line.add " pcmFreq=" & $emu.bus.read_word_internal(sip + 0x14) &
               " divFreq=" & $emu.bus.read_word_internal(sip + 0x18)
    line.add " dmaSrcInternal[1]=" & toHex(emu.dma.src[1], 8) &
             " [2]=" & toHex(emu.dma.src[2], 8)
    line.add " sndh[Avol=" & $emu.apu.soundcnt_h.dma_sound_a_volume &
             " A_L=" & $emu.apu.soundcnt_h.dma_sound_a_left &
             " A_R=" & $emu.apu.soundcnt_h.dma_sound_a_right &
             " Bvol=" & $emu.apu.soundcnt_h.dma_sound_b_volume &
             " B_L=" & $emu.apu.soundcnt_h.dma_sound_b_left &
             " B_R=" & $emu.apu.soundcnt_h.dma_sound_b_right &
             " Atmr=" & $emu.apu.soundcnt_h.dma_sound_a_timer &
             " Btmr=" & $emu.apu.soundcnt_h.dma_sound_b_timer & "]" &
             " tm0d=" & $emu.timer.tmd[0] & " tm1d=" & $emu.timer.tmd[1]
    if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
      var ea = 0.0
      var eb = 0.0
      for off in 0 ..< 0x630:
        let a = float(cast[int8](emu.bus.read_byte_internal(sip + 0x350'u32 + uint32(off))))
        let b = float(cast[int8](emu.bus.read_byte_internal(sip + 0x350'u32 + 0x630'u32 + uint32(off))))
        ea += a*a; eb += b*b
      line.add " bufArms=" & $sqrt(ea/1584.0) & " bufBrms=" & $sqrt(eb/1584.0)
    echo line
    # full channel-struct dump
    if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
      for i in 0 ..< 12:
        let base = sip + 0x50'u32 + uint32(i)*64
        let st = emu.bus.read_byte_internal(base)
        if (st and 0xC7'u8) == 0: continue
        echo "  ch", i, " st=", toHex(st,2),
          " type=", toHex(emu.bus.read_byte_internal(base+1),2),
          " rV=", emu.bus.read_byte_internal(base+2),
          " lV=", emu.bus.read_byte_internal(base+3),
          " atk=", emu.bus.read_byte_internal(base+4),
          " evol=", emu.bus.read_byte_internal(base+9),
          " evr=", emu.bus.read_byte_internal(base+10),
          " evl=", emu.bus.read_byte_internal(base+11),
          " ct=", emu.bus.read_word_internal(base+0x18),
          " fw=", emu.bus.read_word_internal(base+0x1C),
          " freq=", emu.bus.read_word_internal(base+0x20),
          " wave=", toHex(emu.bus.read_word_internal(base+0x24),8),
          " cp=", toHex(emu.bus.read_word_internal(base+0x28),8),
          " sampActive=", emu.mp2k.samplers[i].active,
          " srcIdx=", emu.mp2k.samplers[i].src_index,
          " sampCnt=", emu.mp2k.samplers[i].sample_count,
          " sampLoop=", emu.mp2k.samplers[i].looping,
          " sampVolR=", emu.mp2k.samplers[i].vol_r1
  # raw pcmBuffer B-half slice dump at a mid-run frame
  var lastN = 0
  var sliceDone = false
  var lastWB = 0
  var lastDB = 0
  var lastSB = 0
  for f in 0 ..< frames:
    emu.step_frame()
    if f >= 395 and f < 415:
      let sip2 = emu.bus.read_word_internal(0x03007FF0'u32)
      if (sip2 shr 24) == 0x02'u32 or (sip2 shr 24) == 0x03'u32:
        echo "f=", f, " pcmDmaCounter=", emu.bus.read_byte_internal(sip2 + 4),
             " src2=", toHex(emu.dma.src[2],8),
             " wB=", dbgFifoWrites[1] - lastWB, " drB=", dbgFifoDrop[1] - lastDB,
             " served=", dbgFifoServed[1] - lastSB
        lastWB = dbgFifoWrites[1]; lastDB = dbgFifoDrop[1]; lastSB = dbgFifoServed[1]
    if f == 450 and not sliceDone:
      sliceDone = true
      let sip = emu.bus.read_word_internal(0x03007FF0'u32)
      if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
        var lineA = "bufA slice: "
        var lineB = "bufB slice: "
        for off in 0 ..< 96:
          lineA.add $int(cast[int8](emu.bus.read_byte_internal(sip + 0x350'u32 + uint32(off)))) & " "
          lineB.add $int(cast[int8](emu.bus.read_byte_internal(sip + 0x350'u32 + 0x630'u32 + uint32(off)))) & " "
        echo lineA
        echo lineB
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
  echo "fifoServed A=", dbgFifoServed[0], " B=", dbgFifoServed[1],
       "  fifoEmpty A=", dbgFifoEmpty[0], " B=", dbgFifoEmpty[1]
  echo "fifoWrites A=", dbgFifoWrites[0], " B=", dbgFifoWrites[1],
       " drops A=", dbgFifoDrop[0], " B=", dbgFifoDrop[1]
  block:
    let fh = open("/tmp/real_capture.bin", fmWrite)
    if realDmaCapture.len > 0:
      discard fh.writeBuffer(addr realDmaCapture[0], realDmaCapture.len * 2)
    fh.close()
    let fh2 = open("/tmp/hle_capture.bin", fmWrite)
    if mp2kWavCapture.len > 0:
      discard fh2.writeBuffer(addr mp2kWavCapture[0], mp2kWavCapture.len * 2)
    fh2.close()
  # Dump the learned mixer body (IWRAM around the hook) for offline disasm.
  if emu.mp2k.entry_addr != 0xFFFFFFFF'u32:
    var buf = newSeq[byte](0x800)
    for i in 0 ..< buf.len:
      buf[i] = emu.bus.read_byte_internal(emu.mp2k.entry_addr + uint32(i))
    let fh3 = open("/tmp/mixer_body.bin", fmWrite)
    discard fh3.writeBuffer(addr buf[0], buf.len)
    fh3.close()
    echo "mixer body dumped from ", toHex(emu.mp2k.entry_addr, 8)

main()
