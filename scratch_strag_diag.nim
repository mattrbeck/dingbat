# Straggler diagnosis harness: boot a ROM, and at intervals dump the raw
# SoundInfo work area + HLE internals (foreign detector, channel table).
#   nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc -o:/tmp/strag_diag --path:src scratch_strag_diag.nim
#   /tmp/strag_diag <rom> [frames=900] [dump_every=60]
import std/[os, strutils, math]
import dingbat/gba/gba
import dingbat/common/test_output
import dingbat/common/input

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = true
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 900
  let every = if paramCount() >= 3: parseInt(paramStr(3)) else: 60
  let drive = getEnv("DINGBAT_SWEEP_DRIVE") == "1"
  for f in 0 ..< frames:
    if drive:
      let phase = (f div 8) mod 4
      let btn = (if (f div 32) mod 2 == 0: A else: START)
      emu.keypad.handle_input(btn, phase < 2)
    emu.step_frame()
    if f mod every != 0 and f != frames - 1: continue
    let m = emu.mp2k
    let sip = emu.bus.read_word_internal(0x03007FF0'u32)
    if (sip shr 24) != 0x02'u32 and (sip shr 24) != 0x03'u32:
      echo "f=", f, " no soundinfo ptr sip=", toHex(sip, 8)
      continue
    let ident = emu.bus.read_word_internal(sip)
    echo "f=", f, " sip=", toHex(sip,8), " ident=", toHex(ident,8),
      " engaged=", m.engaged, " fires=", m.dbg_hook_fires,
      " foreign=", m.fifo_foreign, " streak=", m.foreign_streak,
      " quiet_age=", m.shadow_quiet_age,
      " realavg=", m.dbg_real_avg.formatFloat(ffDecimal,2),
      " hleavg=", m.dbg_hle_avg.formatFloat(ffDecimal,2),
      " cpu_fifo=", m.fifo_cpu_bytes
    # SoundInfo header bytes
    var hdr = ""
    for i in 0'u32 ..< 0x20'u32:
      hdr.add toHex(emu.bus.read_byte_internal(sip + i), 2)
      if (i and 3) == 3: hdr.add " "
    echo "  hdr: ", hdr
    echo "  dmaCnt=", emu.bus.read_byte_internal(sip+4),
      " reverb=", emu.bus.read_byte_internal(sip+5),
      " maxChans=", emu.bus.read_byte_internal(sip+6),
      " masterVol=", emu.bus.read_byte_internal(sip+7),
      " dmaPeriod=", emu.bus.read_byte_internal(sip+0xB),
      " spv=", emu.bus.read_word_internal(sip+0x10),
      " pcmFreq=", emu.bus.read_word_internal(sip+0x14)
    # DMA1/2 registers
    for c in 1 .. 2:
      echo "  dma", c, " en=", emu.dma.dmacnt_h[c].enable,
        " timing=", emu.dma.dmacnt_h[c].start_timing,
        " dad=", toHex(emu.dma.dmadad[c], 8),
        " sad=", toHex(emu.dma.dmasad[c], 8)
    # channel table at +0x50
    for i in 0 ..< 12:
      let base = sip + uint32(0x50 + i * 64)
      let status = emu.bus.read_byte_internal(base)
      if status == 0: continue
      echo "  ch", i, " st=", toHex(status,2),
        " ty=", toHex(emu.bus.read_byte_internal(base+1),2),
        " rV=", emu.bus.read_byte_internal(base+2),
        " lV=", emu.bus.read_byte_internal(base+3),
        " evol=", emu.bus.read_byte_internal(base+9),
        " evr=", emu.bus.read_byte_internal(base+10),
        " evl=", emu.bus.read_byte_internal(base+11),
        " ct=", emu.bus.read_word_internal(base+0x18),
        " freq=", emu.bus.read_word_internal(base+0x20),
        " wav=", toHex(emu.bus.read_word_internal(base+0x24),8),
        " cp=", toHex(emu.bus.read_word_internal(base+0x28),8)

main()
