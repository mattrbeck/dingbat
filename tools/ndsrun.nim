## Headless DS runner: boot a ROM, run N frames, write both screens to one
## PNG (top above bottom, 256x384). The iteration loop for DS bring-up.
##
##   nim c -d:release --path:src -o:ndsrun tools/ndsrun.nim
##   ./ndsrun tests/nds/roms/fb_hello.nds --frames 10 --out /tmp/fb.png
##       [--bios DIR] [--press A@10,DOWN@20-25,TOUCH:128:96@30-40]
##
## --bios defaults to $DINGBAT_NDS_BIOS (bios9.bin, bios7.bin, firmware.bin).
##
## Debug flags (build with -d:ndsdebug):
##   --trace9 N / --trace7 N   print N instructions of that CPU (pc + regs),
##                             starting at frame --trace-from F (default 0)
##   --iolog                   log every I/O access (repeats folded), from
##                             frame --iolog-from F
##   --pcs                     print both CPUs' pc / halted state each frame
##   --watch HEX               log every write to that word (pc, line)
## --text B0[,A0..]  print a text BG's tile map as characters (tile index =
##                   ASCII, as the libnds console font; --text-offset N)

import std/[os, strutils, parseopt]
import zippy
import dingbat/nds/nds

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
  x, y: int
  first, last: int

proc parse_presses(spec: string): seq[Press] =
  ## "A@10,DOWN@20-25,TOUCH:128:96@30-40": held over frames first..last.
  for item in spec.split(','):
    if item.len == 0: continue
    let at = item.split('@')
    var p = Press()
    let frames = at[1].split('-')
    p.first = parseInt(frames[0])
    p.last = if frames.len > 1: parseInt(frames[1]) else: p.first + 1
    let what = at[0].toUpperAscii
    if what.startsWith("TOUCH:"):
      let xy = what.split(':')
      p.touch = true
      p.x = parseInt(xy[1]); p.y = parseInt(xy[2])
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

when isMainModule:
  var rom = ""
  var frames = 60
  var outp = "nds_out.png"
  var bios = ""
  var trace9, trace7 = 0
  var trace_from, iolog_from = 0
  var iolog, pcs = false
  var watch = 0'u32
  var text = ""
  var text_offset = 0
  var presses: seq[Press]
  var p = initOptParser(commandLineParams(), shortNoVal = {'h'},
                        longNoVal = @["help", "iolog", "pcs"])
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument: rom = key
    of cmdLongOption, cmdShortOption:
      case key
      of "frames": frames = parseInt(val)
      of "out": outp = val
      of "bios": bios = val
      of "trace9": trace9 = parseInt(val)
      of "trace7": trace7 = parseInt(val)
      of "trace-from": trace_from = parseInt(val)
      of "iolog": iolog = true
      of "iolog-from": iolog_from = parseInt(val)
      of "pcs": pcs = true
      of "watch": watch = uint32(parseHexInt(val))
      of "text": text = val
      of "text-offset": text_offset = parseInt(val)
      of "press": presses.add parse_presses(val)
      else: quit("unknown option --" & key)
    of cmdEnd: discard
  if rom.len == 0: quit("usage: ndsrun ROM [--frames N] [--out PNG] [--bios DIR]")
  let n = load_nds(rom, bios)
  n.watch = watch
  for f in 0 ..< frames:
    if f == trace_from:
      n.trace9 = trace9
      n.trace7 = trace7
    if f == iolog_from: n.iolog = iolog
    for p in presses:
      if f == p.first or f == p.last:
        if p.touch: n.set_touch(p.x, p.y, f == p.first)
        else: n.set_button(p.button, f == p.first)
    n.run_frame()
    if pcs:
      echo "frame ", f, " arm9 pc=", toHex(n.arm9.next_pc, 8),
           (if n.arm9.halted: " H" else: "  "), " arm7 pc=", toHex(n.arm7.next_pc, 8),
           (if n.arm7.halted: " H" else: "")
  write_png(outp, 256, 384, n.screens_rgba())
  echo "frames=", frames, " arm9 instrs=", n.arm9.instr_count, " pc=0x",
       toHex(n.arm9.next_pc, 8), " arm7 instrs=", n.arm7.instr_count, " pc=0x",
       toHex(n.arm7.next_pc, 8), " -> ", outp
  for spec in text.split(','):
    # A0..A3 / B0..B3: engine and BG number
    if spec.len == 2:
      echo "--- engine ", spec[0], " BG", spec[1]
      stdout.write(n.bg_text(spec[0] == 'B', ord(spec[1]) - ord('0'), text_offset))
  echo "arm9 ", n.arm9.reg_dump()
  echo "arm7 ", n.arm7.reg_dump()
