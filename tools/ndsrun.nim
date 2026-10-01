## Headless DS runner: boot a ROM, run N frames, write both screens to one
## PNG (top above bottom, 256x384). The iteration loop for DS bring-up.
##
##   nim c -d:release --path:src -o:ndsrun tools/ndsrun.nim
##   ./ndsrun tests/nds/roms/fb_hello.nds --frames 10 --out /tmp/fb.png
##       [--bios DIR] [--trace9 N] [--trace7 N] [--press START@30,DOWN@40+3]
##       [--shots 60,120]
##
## --bios defaults to $DINGBAT_NDS_BIOS (bios9.bin, bios7.bin, firmware.bin).
## --traceN prints the first N instructions of that CPU (pc, opcode, regs) to
## stderr, starting at frame --trace-at F (default 0). --press holds KEY from frame F for D frames (default 2); keys are
## A B SELECT START RIGHT LEFT UP DOWN R L X Y. --shots also writes
## --peek9 / --peek7 A,B,... print 32-bit words read through that CPU's bus
## at the end (I/O reads may have side effects). Also writes
## <out>_<frame>.png after each listed frame, plus <out>_shots.png: the top
## screens of every shot side by side (one image to look at).

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

when isMainModule:
  var rom = ""
  var frames = 60
  var outp = "nds_out.png"
  var bios = ""
  var trace9, trace7, trace_at = 0
  var presses: seq[tuple[b: NdsButton, at, dur: int]]
  var shots: seq[int]
  var tops: seq[seq[uint32]]
  var peek9, peek7: seq[uint32]
  var p = initOptParser(commandLineParams(), shortNoVal = {'h'}, longNoVal = @["help"])
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
      of "trace-at": trace_at = parseInt(val)
      of "press":
        for item in val.split(','):
          let at = item.split('@')
          if at.len != 2: quit("--press wants KEY@FRAME[+DUR]")
          let fd = at[1].split('+')
          let b = case at[0].toUpperAscii
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
            else: quit("unknown key " & at[0])
          presses.add((b, parseInt(fd[0]), if fd.len > 1: parseInt(fd[1]) else: 2))
      of "peek9":
        for a in val.split(','): peek9.add uint32(parseHexInt(a))
      of "peek7":
        for a in val.split(','): peek7.add uint32(parseHexInt(a))
      of "shots":
        for f in val.split(','): shots.add parseInt(f)
      else: quit("unknown option --" & key)
    of cmdEnd: discard
  if rom.len == 0: quit("usage: ndsrun ROM [--frames N] [--out PNG] [--bios DIR]")
  let n = load_nds(rom, bios)
  for f in 0 ..< frames:
    if f == trace_at:
      n.arm9.trace = trace9
      n.arm7.trace = trace7
    for p in presses:
      if f == p.at: n.set_button(p.b, true)
      elif f == p.at + p.dur: n.set_button(p.b, false)
    n.run_frame()
    if f + 1 in shots:
      let px = n.screens_rgba()
      write_png(outp.changeFileExt("") & "_" & $(f + 1) & ".png", 256, 384, px)
      tops.add px[0 ..< 256 * 192]
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
  write_png(outp, 256, 384, n.screens_rgba())
  echo "frames=", frames, " arm9 instrs=", n.arm9.instr_count, " pc=0x",
       toHex(n.arm9.next_pc, 8), " arm7 instrs=", n.arm7.instr_count, " pc=0x",
       toHex(n.arm7.next_pc, 8), " -> ", outp
  echo "arm9 ", n.arm9.reg_dump()
  echo "arm7 ", n.arm7.reg_dump()
  for a in peek9: echo "arm9 [", toHex(a, 8), "] = ", toHex(read32(n.arm9.bus, a), 8)
  for a in peek7: echo "arm7 [", toHex(a, 8), "] = ", toHex(read32(n.arm7.bus, a), 8)
