# Dump SoundInfo-area memory + pcmBuffer energy per frame window, plus FIFO
# write provenance counters, to classify silent-but-engaged games.
#   nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc -o:/tmp/strag_mem --path:src scratch_strag_mem.nim
#   /tmp/strag_mem <rom> <frames> <dump_frame>
import std/[os, strutils, math]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = true
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 600
  let dumpf = if paramCount() >= 3: parseInt(paramStr(3)) else: 300
  var lastReal = 0
  for f in 0 ..< frames:
    emu.step_frame()
    # per-frame real DS energy from the capture tail
    let n = realDmaCapture.len
    var e = 0.0
    var cnt = 0
    if n > lastReal:
      for i in lastReal ..< n:
        e += abs(float(realDmaCapture[i]))
        cnt.inc
    lastReal = n
    let avg = (if cnt > 0: e / float(cnt) else: 0.0)
    if avg > 0.5:
      echo "f=", f, " realavg=", avg.formatFloat(ffDecimal,2),
        " streak=", emu.mp2k.foreign_streak
    if f == dumpf:
      let sip = emu.bus.read_word_internal(0x03007FF0'u32)
      echo "== f=", f, " sip=", toHex(sip,8), " realavg=", avg.formatFloat(ffDecimal,2)
      # dump 0x00..0x350 of SoundInfo in rows of 16
      for row in 0 ..< 0x35:
        var line = toHex(uint32(row*16), 4) & ": "
        var nonzero = false
        for i in 0 ..< 16:
          let b = emu.bus.read_byte_internal(sip + uint32(row*16 + i))
          if b != 0: nonzero = true
          line.add toHex(b, 2)
          if (i and 3) == 3: line.add " "
        if nonzero: echo line
      # pcmBuffer energy (first half = FIFO A stream)
      var pe = 0.0
      let spv = int(emu.bus.read_word_internal(sip + 0x10))
      let period = int(emu.bus.read_byte_internal(sip + 0x0B))
      let buflen = spv * period
      for i in 0 ..< buflen:
        pe += abs(float(cast[int8](emu.bus.read_byte_internal(sip + 0x350'u32 + uint32(i)))))
      echo "pcmBuffer[A] len=", buflen, " avgabs=", (pe/float(buflen)).formatFloat(ffDecimal,3)
  echo "fires=", emu.mp2k.dbg_hook_fires, " cpu_fifo=", emu.mp2k.fifo_cpu_bytes,
    " streak=", emu.mp2k.foreign_streak, " foreign=", emu.mp2k.fifo_foreign

main()
