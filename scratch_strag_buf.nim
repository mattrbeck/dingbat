# Sample the m4a pcmBuffer halves per frame: RMS of the A half (sip+0x350)
# and the B half (DMA2 SAD offset), to see whether a game overlays its own
# stream into one half.
#   nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc -o:/tmp/strag_buf --path:src scratch_strag_buf.nim
#   /tmp/strag_buf <rom> <frames> <from_frame>
import std/[os, strutils, math]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = true
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 700
  let fromf = if paramCount() >= 3: parseInt(paramStr(3)) else: 540
  for f in 0 ..< frames:
    emu.step_frame()
    if f < fromf: continue
    let sip = emu.bus.read_word_internal(0x03007FF0'u32)
    if (sip shr 24) != 0x02'u32 and (sip shr 24) != 0x03'u32: continue
    let asad = emu.dma.dmasad[1]
    let bsad = emu.dma.dmasad[2]
    let spv = int(emu.bus.read_word_internal(sip + 0x10))
    let period = int(emu.bus.read_byte_internal(sip + 0x0B))
    let n = spv * period
    var ea, eb: float
    for i in 0 ..< n:
      let va = float(cast[int8](emu.bus.read_byte_internal(asad + uint32(i))))
      let vb = float(cast[int8](emu.bus.read_byte_internal(bsad + uint32(i))))
      ea += va*va
      eb += vb*vb
    echo "f=", f, " Ahalf rms=", sqrt(ea/float(n)).formatFloat(ffDecimal,1),
      " Bhalf rms=", sqrt(eb/float(n)).formatFloat(ffDecimal,1),
      " asad=", toHex(asad,8), " bsad=", toHex(bsad,8)

main()
