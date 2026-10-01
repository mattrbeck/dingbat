## Headless DS runner: boot a ROM, run N frames, write both screens to one
## PNG (top above bottom, 256x384). The iteration loop for DS bring-up.
##
##   nim c -d:release --path:src -o:ndsrun tools/ndsrun.nim
##   ./ndsrun ~/.cache/dingbat-nds/roms/fb_hello.nds --frames 10 --out /tmp/fb.png
##       [--bios DIR] [--trace9 N] [--trace7 N] [--press START@30,DOWN@40+3]
##       [--shots 60,120] [--wav OUT.wav]
##
## --bios defaults to $DINGBAT_NDS_BIOS (bios9.bin, bios7.bin, firmware.bin).
## --boot firmware starts from power-on in the real BIOS and firmware (needs
## all three dumps; the ROM may then be left out: an empty card slot, the
## firmware menu); --boot direct (default) starts the card's binaries.
## --traceN prints the first N instructions of that CPU (pc, opcode, regs) to
## stderr, starting at frame --trace-at F (default 0).
## --press KEY@F[+D] holds KEY from frame F for D frames (default 2), or
## KEY@F-L from frame F to L; keys are A B SELECT START RIGHT LEFT UP DOWN R L
## X Y, and TOUCH:x:y holds the stylus at bottom-screen pixel (x, y).
## --shots also writes <out>_<frame>.png after each listed frame, plus
## <out>_shots.png: the top screens of every shot side by side.
## --peek9 / --peek7 A,B,... print 32-bit words read through that CPU's bus
## at the end (I/O reads may have side effects).
## --text B0[,A0..] prints a text BG's tile map as characters (tile index =
## ASCII, as the libnds console font; --text-offset N).
## --bgshot A0 draws that text BG straight from VRAM into the PNG's top half
## (no scroll/priority/blending).
## --dump9/--dump7 ADDR:LEN:FILE writes LEN bytes read through that CPU's bus at the
## end of the run to FILE (hex ADDR/LEN), for disassembly.
## --wav writes the sound output of the whole run (16-bit stereo, 32728 Hz).
## --mic FILE.wav[@F] feeds a 16-bit PCM WAV (mono, or stereo mixed down) to
## the microphone from frame F (default 0), at the file's rate.
## LID@F[+D|-L] in --press closes the hinge for those frames (opening it
## raises the ARM7's lid IRQ; a game may sleep while it is shut).
##
## --save FILE loads the card's save chip from FILE (its size picks the
## chip) and writes it back when the run changed it.
## --slot2 gba:FILE[,SAVE] puts a GBA cartridge in the GBA slot (its .sav
## loaded from SAVE and written back when the run changed it); --slot2
## rumble / --slot2 expansion insert the Rumble Pak / Memory Expansion Pak.
## --rumble-log prints each frame where the slot-2 rumble strength changes.
## --rtc YYYY-MM-DD[THH:MM:SS] starts the RTC at that time and clocks it from
## emulated time, so runs are reproducible (default: host local time).
## --perf-from F times frames F..end (printed as fps; default the whole run).
## --state-save FILE@F[,FILE@F...] writes a save state (packed, with a
## thumbnail) after frame F. --state-load FILE[@F] starts from a state: the
## run goes on from frame F (default: the V-blanks the state has counted,
## which is its frame number when it came from --state-save), so --frames,
## --press and --shots keep their frame numbers. --state-layout prints the
## state's field layout (docs/nds/savestate.md) and exits.
## --pcs prints both CPUs' pc / halted state after each frame.
##
## Debug flags (build with -d:ndsdebug):
##   --iolog            log every I/O access (repeats folded), from frame
##                      --iolog-from F
##   --watch HEX        log every write to that word (pc, line)
##   --prof F0-F1       count instructions and master cycles per 64-byte code
##                      block over frames F0..F1-1; print the costliest blocks
##   --spilog           log every card-SPI (save chip) byte: sent -> reply, pc
##   --cartlog          log every card ROM transfer: mode, ROMCTRL, plain
##                      command, length, first reply bytes as the CPU sees them

import std/[os, strutils, parseopt, tables, sequtils, monotimes, times]
import zippy
import dingbat/nds/[nds, savestate]
import dingbat/nds/io/rtc
import dingbat/gba/rtc_calendar

proc crc32(data: openArray[uint8]): uint32 =
  var table {.global.}: array[256, uint32]
  if table[1] == 0:
    for i in 0'u32 .. 255:
      var c = i
      for _ in 0..7: c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
      table[i] = c
  result = 0xFFFFFFFF'u32
  for b in data: result = table[(result xor b) and 0xFF] xor (result shr 8)
  result = not result

proc be32(s: var seq[uint8]; v: uint32) =
  s.add uint8(v shr 24); s.add uint8(v shr 16); s.add uint8(v shr 8); s.add uint8(v)

proc chunk(png: var seq[uint8]; kind: string; data: seq[uint8]) =
  png.be32(uint32(data.len))
  var body: seq[uint8]
  for c in kind: body.add uint8(c)
  body.add data
  png.add body
  png.be32(crc32(body))

proc write_png*(path: string; w, h: int; rgba: seq[uint32]) =
  var raw: seq[uint8]
  for y in 0 ..< h:
    raw.add 0
    for x in 0 ..< w:
      let p = rgba[y * w + x]
      raw.add uint8(p); raw.add uint8(p shr 8); raw.add uint8(p shr 16)
  var png = @[0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  var ihdr: seq[uint8]
  ihdr.be32(uint32(w)); ihdr.be32(uint32(h))
  ihdr.add [8'u8, 2, 0, 0, 0]   # 8-bit RGB
  png.chunk("IHDR", ihdr)
  let z = compress(cast[seq[uint8]](raw), dataFormat = dfZlib)
  png.chunk("IDAT", cast[seq[uint8]](z))
  png.chunk("IEND", @[])
  writeFile(path, cast[string](png))

proc screens_rgba*(n: NDS): seq[uint32] =
  result = newSeq[uint32](256 * 384)
  for i in 0 ..< 256 * 192:
    result[i] = bgr555_to_rgba(n.gpu.top[i])
    result[256 * 192 + i] = bgr555_to_rgba(n.gpu.bottom[i])

type Press = object
  button: NdsButton
  touch: bool
  lid: bool
  x, y: int
  first, last: int

proc parse_presses(spec: string): seq[Press] =
  ## "A@10,DOWN@20+3,B@30-35,TOUCH:128:96@40-60": released at frame `last`.
  for item in spec.split(','):
    if item.len == 0: continue
    let at = item.split('@')
    if at.len != 2: quit("--press wants KEY@FRAME[+DUR|-LAST]")
    var p = Press()
    if '+' in at[1]:
      let fd = at[1].split('+')
      p.first = parseInt(fd[0])
      p.last = p.first + parseInt(fd[1])
    else:
      let fl = at[1].split('-')
      p.first = parseInt(fl[0])
      p.last = if fl.len > 1: parseInt(fl[1]) else: p.first + 2
    let what = at[0].toUpperAscii
    if what.startsWith("TOUCH:"):
      let xy = what.split(':')
      p.touch = true
      p.x = parseInt(xy[1]); p.y = parseInt(xy[2])
    elif what == "LID":
      p.lid = true
    else:
      p.button = case what
        of "A": nbA
        of "B": nbB
        of "SELECT": nbSelect
        of "START": nbStart
        of "RIGHT": nbRight
        of "LEFT": nbLeft
        of "UP": nbUp
        of "DOWN": nbDown
        of "R": nbR
        of "L": nbL
        of "X": nbX
        of "Y": nbY
        else: quit("unknown button " & what)
    result.add p

proc read_wav_mono(path: string; rate: var int): seq[int16] =
  ## 16-bit PCM WAV -> mono samples (channels averaged).
  let d = readFile(path)
  template u16(o: int): int = int(uint8(d[o])) or (int(uint8(d[o + 1])) shl 8)
  template u32(o: int): int = u16(o) or (u16(o + 2) shl 16)
  if d.len < 12 or d[0 ..< 4] != "RIFF" or d[8 ..< 12] != "WAVE": quit("--mic: not a WAV file")
  var o = 12
  var channels, bits = 0
  while o + 8 <= d.len:
    let id = d[o ..< o + 4]
    let size = u32(o + 4)
    if id == "fmt ":
      channels = u16(o + 10); rate = u32(o + 12); bits = u16(o + 22)
    elif id == "data":
      if bits != 16 or channels < 1: quit("--mic: needs 16-bit PCM")
      let frames = min(size, d.len - o - 8) div (2 * channels)
      for f in 0 ..< frames:
        var acc = 0
        for c in 0 ..< channels: acc += int(cast[int16](u16(o + 8 + (f * channels + c) * 2)))
        result.add int16(acc div channels)
      return
    o += 8 + size + (size and 1)
  quit("--mic: no data chunk")

proc bg_text*(n: NDS; engine_b: bool; bg: int; offset: int): string =
  ## A text BG's 32x24 tile map as characters (tile index + `offset`): the
  ## libnds console maps tile n to character n, so offset 0 reads it back.
  let bus = Arm9Bus(nds: n)
  let io = if engine_b: 0x0400_1000'u32 else: 0x0400_0000'u32
  let vram = if engine_b: 0x0620_0000'u32 else: 0x0600_0000'u32
  let dispcnt = bus.read32(io)
  let bgcnt = bus.read16(io + 8 + uint32(bg) * 2)
  var base = vram + ((bgcnt shr 8) and 0x1F) * 0x800
  if not engine_b: base += ((dispcnt shr 27) and 7) * 0x10000
  for y in 0 ..< 24:
    var line = ""
    for x in 0 ..< 32:
      let t = int(bus.read16(base + uint32(y * 32 + x) * 2) and 0x3FF) + offset
      line.add(if t >= 32 and t < 127: char(t) else: '.')
    result.add(line.strip(leading = false) & "\n")

proc bg_shot*(n: NDS; engine_b: bool; bg: int): seq[uint16] =
  ## A text BG drawn straight from VRAM (no scroll, priority or blending):
  ## lets a ROM's text be read before the 2D engine renders it.
  let bus = Arm9Bus(nds: n)
  let io = if engine_b: 0x0400_1000'u32 else: 0x0400_0000'u32
  let vram = if engine_b: 0x0620_0000'u32 else: 0x0600_0000'u32
  let pal = if engine_b: 0x0500_0400'u32 else: 0x0500_0000'u32
  let dispcnt = bus.read32(io)
  let bgcnt = bus.read16(io + 8 + uint32(bg) * 2)
  var map = vram + ((bgcnt shr 8) and 0x1F) * 0x800
  var chars = vram + ((bgcnt shr 2) and 0xF) * 0x4000
  if not engine_b:
    map += ((dispcnt shr 27) and 7) * 0x10000
    chars += ((dispcnt shr 24) and 7) * 0x10000
  let bpp8 = (bgcnt and 0x80) != 0
  result = newSeq[uint16](256 * 192)
  for y in 0 ..< 192:
    for x in 0 ..< 256:
      let e = bus.read16(map + uint32((y div 8) * 32 + x div 8) * 2)
      var tx = x and 7
      var ty = y and 7
      if (e and 0x400) != 0: tx = 7 - tx
      if (e and 0x800) != 0: ty = 7 - ty
      let t = e and 0x3FF
      var c: uint32
      if bpp8:
        c = bus.read8(chars + t * 64 + uint32(ty * 8 + tx))
      else:
        let b = bus.read8(chars + t * 32 + uint32(ty * 4 + tx div 2))
        c = (if (tx and 1) != 0: b shr 4 else: b and 0xF)
        if c != 0: c += (e shr 12) * 16
      result[y * 256 + x] = uint16(bus.read16(pal + c * 2))

when isMainModule:
  var rom = ""
  var frames = 60
  var outp = "nds_out.png"
  var bios = ""
  var boot = nbDirect
  var trace9, trace7, trace_at = 0
  var iolog_from = 0
  var iolog, pcs, spilog, cartlog = false
  var prof_from, prof_to = -1
  var watch = 0'u32
  var text = ""
  var text_offset = 0
  var presses: seq[Press]
  var shot = ""
  var shots: seq[int]
  var tops: seq[seq[uint32]]
  var peek9, peek7: seq[uint32]
  var dumps: seq[(bool, uint32, int, string)]
  var wav = ""
  var save = ""
  var slot2 = ""
  var rumble_log = false
  var rtc_at = ""
  var mic_path = ""
  var mic_at = 0
  var perf_from = 0
  var state_saves: seq[(string, int)]
  var state_load = ""
  var state_load_frame = -1
  var state_layout = false
  var perf_t0: MonoTime
  var p = initOptParser(commandLineParams(), shortNoVal = {'h'},
                        longNoVal = @["help", "iolog", "pcs", "spilog", "rumble-log", "cartlog",
                                     "state-layout"])
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument: rom = key
    of cmdLongOption, cmdShortOption:
      case key
      of "frames": frames = parseInt(val)
      of "out": outp = val
      of "bios": bios = val
      of "boot":
        boot = case val
          of "firmware": nbFirmware
          of "direct": nbDirect
          else: quit("--boot firmware|direct")
      of "trace9": trace9 = parseInt(val)
      of "trace7": trace7 = parseInt(val)
      of "trace-at": trace_at = parseInt(val)
      of "wav": wav = val
      of "save": save = val
      of "slot2": slot2 = val
      of "rumble-log": rumble_log = true
      of "rtc": rtc_at = val
      of "mic":
        let m = val.split('@')
        mic_path = m[0]
        if m.len > 1: mic_at = parseInt(m[1])
      of "perf-from": perf_from = parseInt(val)
      of "state-save":
        for item in val.split(','):
          let at = item.rsplit('@', maxsplit = 1)
          if at.len != 2: quit("--state-save wants FILE@FRAME")
          state_saves.add (at[0], parseInt(at[1]))
      of "state-load":
        let at = val.rsplit('@', maxsplit = 1)
        if at.len == 2 and at[1].allCharsInSet(Digits):
          state_load = at[0]
          state_load_frame = parseInt(at[1])
        else: state_load = val
      of "state-layout": state_layout = true
      of "press": presses.add parse_presses(val)
      of "peek9":
        for a in val.split(','): peek9.add uint32(parseHexInt(a))
      of "dump9", "dump7":
        let d = val.split(':')
        dumps.add (key == "dump7", uint32(parseHexInt(d[0])), parseHexInt(d[1]), d[2])
      of "peek7":
        for a in val.split(','): peek7.add uint32(parseHexInt(a))
      of "shots":
        for f in val.split(','): shots.add parseInt(f)
      of "iolog": iolog = true
      of "spilog": spilog = true
      of "cartlog": cartlog = true
      of "prof":
        let r = val.split('-')
        prof_from = parseInt(r[0]); prof_to = parseInt(r[1])
      of "iolog-from": iolog_from = parseInt(val)
      of "pcs": pcs = true
      of "watch": watch = uint32(parseHexInt(val))
      of "text": text = val
      of "text-offset": text_offset = parseInt(val)
      of "bgshot": shot = val
      else: quit("unknown option --" & key)
    of cmdEnd: discard
  if rom.len == 0 and boot != nbFirmware:
    quit("usage: ndsrun ROM [--frames N] [--out PNG] [--bios DIR] [--boot firmware|direct]")
  let n = load_nds(rom, bios, boot)
  n.watch = watch
  n.cart.spilog = spilog
  n.cart.cartlog = cartlog
  if rtc_at.len > 0:
    # --rtc YYYY-MM-DD[THH:MM:SS]: the RTC starts there and follows emulated time
    let d = rtc_at.replace('T', '-').replace(':', '-').split('-')
    var f: array[6, int]
    for i in 0 ..< min(6, d.len): f[i] = parseInt(d[i])
    n.rtc.set_fixed_clock(n.sched, to_calendar_seconds(f[0], f[1], f[2], f[3], f[4], f[5]))
  if save.len > 0 and fileExists(save):
    n.cart.backup.set_data(cast[seq[uint8]](readFile(save)))
  var slot2_save = ""
  if slot2.len > 0:
    if slot2 == "rumble": n.insert_slot2(s2RumblePak)
    elif slot2 == "expansion": n.insert_slot2(s2ExpansionPak)
    elif slot2.startsWith("gba:"):
      let parts = slot2[4 .. ^1].split(',')
      if parts.len > 1: slot2_save = parts[1]
      let sav = if slot2_save.len > 0 and fileExists(slot2_save):
                  cast[seq[uint8]](readFile(slot2_save)) else: @[]
      n.insert_slot2(s2GbaCart, cast[seq[uint8]](readFile(parts[0])), sav)
      echo "slot2: GBA cart ", parts[0].extractFilename, ", ", n.slot2.save_type,
           (if n.slot2.has_rtc: " + RTC" else: "")
    else: quit("--slot2 wants gba:FILE[,SAVE], rumble or expansion")
  if state_layout:
    stdout.write n.state_layout()
    quit(0)
  var first_frame = 0
  if state_load.len > 0:
    if not n.load_state_bytes(readFile(state_load)):
      quit("--state-load " & state_load & ": " & $last_state_reject_kind & ": " &
           last_state_error)
    first_frame = if state_load_frame >= 0: state_load_frame else: n.gpu.frame_count
    # keys and stylus held at the state's frame are in the state (input)
    echo "state: ", state_load, " -> frame ", first_frame
    perf_from = max(perf_from, first_frame)
  var last_rumble = 0
  var audio: seq[float32]
  var mic_rate = 0
  let mic_samples = if mic_path.len > 0: read_wav_mono(mic_path, mic_rate) else: @[]
  for f in first_frame ..< frames:
    if mic_path.len > 0 and f == mic_at: n.push_mic(mic_samples, mic_rate)
    if f == perf_from: perf_t0 = getMonoTime()
    if f == trace_at:
      n.arm9.trace = trace9
      n.arm7.trace = trace7
    if f == iolog_from: n.iolog = iolog
    when defined(ndsdebug):
      if f == prof_from: n.arm9.profiling = true; n.arm7.profiling = true
      if f == prof_to:
        n.arm9.profiling = false; n.arm7.profiling = false
        for (name, ip, cp) in [("arm9", n.arm9.profile, n.arm9.cprofile),
                               ("arm7", n.arm7.profile, n.arm7.cprofile)]:
          var p = cp
          p.sort()
          var total, itotal = 0
          for _, c in p: total += c
          for _, c in ip: itotal += c
          echo name, " profile: ", itotal, " instrs, ", total, " busy master cycles (",
               formatFloat(total / ((prof_to - prof_from) * FRAME_CYCLES) * 100, ffDecimal, 1),
               "% of the frames)"
          var k = 0
          for blk, c in p:
            echo "  ", toHex(blk, 8), " ", formatFloat(100 * c / max(total, 1), ffDecimal, 1),
                 "% cycles, ", ip.getOrDefault(blk), " instrs, ",
                 formatFloat(c / max(ip.getOrDefault(blk), 1), ffDecimal, 2), " cyc/instr"
            inc k
            if k == 25: break
    for p in presses:
      if f == p.first or f == p.last:
        if p.touch: n.set_touch(p.x, p.y, f == p.first)
        elif p.lid: n.set_lid(f == p.first)
        else: n.set_button(p.button, f == p.first)
    n.run_frame()
    if rumble_log and n.slot2_rumble() != last_rumble:
      last_rumble = n.slot2_rumble()
      echo "rumble frame=", f, " strength=", last_rumble
    if pcs:
      echo "frame ", f, " arm9 pc=", toHex(n.arm9.next_pc, 8),
           (if n.arm9.halted: " H" else: "  "), " arm7 pc=", toHex(n.arm7.next_pc, 8),
           (if n.sleeping: " S" elif n.arm7.halted: " H" else: "")
    if wav.len > 0: audio.add n.spu.take_samples()
    for (file, at) in state_saves:
      if f + 1 == at:
        let image = n.state_bytes(thumbnail = true)
        writeFile(file, pack_state(image))
        echo "state: frame ", at, " -> ", file, " (", image.len, " bytes, ",
             readFile(file).len, " packed)"
    if f + 1 in shots:
      let px = n.screens_rgba()
      write_png(outp.changeFileExt("") & "_" & $(f + 1) & ".png", 256, 384, px)
      tops.add px[0 ..< 256 * 192]
  if frames > perf_from:
    let secs = (getMonoTime() - perf_t0).inNanoseconds.float / 1e9
    echo "speed: frames ", perf_from, "-", frames, " in ", formatFloat(secs, ffDecimal, 2), " s = ",
         formatFloat(float(frames - perf_from) / secs, ffDecimal, 1), " fps"
  if tops.len > 0:
    let cols = min(tops.len, 4)
    let rows = (tops.len + cols - 1) div cols
    let w = cols * 258
    var sheet = newSeq[uint32](w * rows * 194)
    for i, t in tops:
      let x0 = (i mod cols) * 258
      let y0 = (i div cols) * 194
      for y in 0 ..< 192:
        for x in 0 ..< 256: sheet[(y0 + y) * w + x0 + x] = t[y * 256 + x]
    write_png(outp.changeFileExt("") & "_shots.png", w, rows * 194, sheet)
  if wav.len > 0:
    writeFile(wav, wav_bytes(audio))
    echo "audio: ", audio.len div 2, " frames -> ", wav
  if save.len > 0:
    echo "save chip: ", n.cart.backup.kind, " ", n.cart.backup.data.len, " bytes",
         (if n.cart.backup.dirty: " (written -> " & save & ")" else: "")
    if n.cart.backup.dirty: writeFile(save, cast[string](n.cart.backup.data))
  if slot2_save.len > 0 and n.slot2.dirty:
    writeFile(slot2_save, cast[string](n.slot2_save()))
    echo "slot2 save: ", n.slot2.save.len, " bytes written -> ", slot2_save
  if shot.len == 2:
    # --bgshot A0: that BG replaces the top half of the PNG
    let px = n.bg_shot(shot[0] == 'B', ord(shot[1]) - ord('0'))
    for i in 0 ..< 256 * 192: n.gpu.top[i] = px[i]
  write_png(outp, 256, 384, n.screens_rgba())
  echo "frames=", frames, " arm9 instrs=", n.arm9.instr_count, " pc=0x",
       toHex(n.arm9.next_pc, 8), " arm7 instrs=", n.arm7.instr_count, " pc=0x",
       toHex(n.arm7.next_pc, 8), " -> ", outp
  for spec in text.split(','):
    # A0..A3 / B0..B3: engine and BG number
    if spec.len == 2:
      echo "--- engine ", spec[0], " BG", spec[1]
      stdout.write(n.bg_text(spec[0] == 'B', ord(spec[1]) - ord('0'), text_offset))
  if pcs:
    echo "cp15 control=", toHex(n.cp15.control, 8), " icache=", n.tm.ic_on, " dcache=", n.tm.dc_on,
         " regions=", n.cp15.prot_regions.mapIt(toHex(it, 8)).join(","),
         " ic=", toHex(n.cp15.icache_cfg, 2), " dc=", toHex(n.cp15.dcache_cfg, 2),
         " wb=", toHex(n.cp15.wbuf_cfg, 2)
  echo "arm9 ", n.arm9.reg_dump()
  echo "arm7 ", n.arm7.reg_dump()
  for (is7, a, len, file) in dumps:
    var bytes = newString(len)
    for i in 0 ..< len:
      bytes[i] = char(if is7: read8(n.arm7.bus, a + uint32(i)) else: read8(n.arm9.bus, a + uint32(i)))
    writeFile(file, bytes)
  for a in peek9: echo "arm9 [", toHex(a, 8), "] = ", toHex(read32(n.arm9.bus, a), 8)
  for a in peek7: echo "arm7 [", toHex(a, 8), "] = ", toHex(read32(n.arm7.bus, a), 8)
