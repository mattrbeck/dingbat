## Headless DS runner: boot a ROM, run N frames, write both screens to one
## PNG (top above bottom, 256x384). The iteration loop for DS bring-up.
##
##   nim c -d:release --path:src -o:ndsrun tools/ndsrun.nim
##   ./ndsrun tests/nds/roms/fb_hello.nds --frames 10 --out /tmp/fb.png
##       [--bios DIR] [--trace9 N] [--trace7 N] [--press A,START@frame]
##
## --bios defaults to $DINGBAT_NDS_BIOS (bios9.bin, bios7.bin, firmware.bin).
## --traceN prints the first N instructions of that CPU (pc + regs).

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
  var trace9, trace7 = 0
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
      else: quit("unknown option --" & key)
    of cmdEnd: discard
  if rom.len == 0: quit("usage: ndsrun ROM [--frames N] [--out PNG] [--bios DIR]")
  let n = load_nds(rom, bios)
  n.arm9.trace = trace9 > 0
  n.arm7.trace = trace7 > 0
  for f in 0 ..< frames:
    n.run_frame()
  write_png(outp, 256, 384, n.screens_rgba())
  echo "frames=", frames, " arm9 instrs=", n.arm9.instr_count, " pc=0x",
       toHex(n.arm9.next_pc, 8), " arm7 instrs=", n.arm7.instr_count, " pc=0x",
       toHex(n.arm7.next_pc, 8), " -> ", outp
  echo "arm9 ", n.arm9.reg_dump()
  echo "arm7 ", n.arm7.reg_dump()
