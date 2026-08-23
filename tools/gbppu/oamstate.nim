## Dump OAM, the OAM DMA unit's state, the object registers and a few tile
## bitmaps after running a ROM. Written for mooneye
## madness/mgb_oam_dma_halt_sprites (halts two M-cycles into an OAM DMA).
import std/[os, strutils, strformat]
import dingbat/gb/gb

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    echo "usage: oamstate <rom> [frames] [model]"
    quit(1)
  let frames = if args.len > 1: parseInt(args[1]) else: 120
  let model  = if args.len > 2: args[2] else: "mgb"
  let emu = new_gb("", args[0], fifo = true, headless = true, run_bios = false)
  let (rev, _) = gb_revision_from_name(model)
  emu.gb_set_revision(rev)
  emu.post_init()
  for _ in 0 ..< frames: emu.step_frame()

  let mem = emu.memory
  echo &"model={model} frames={frames}"
  echo &"  cpu.halted      = {emu.cpu.halted}"
  echo &"  dma_position    = 0x{mem.dma_position:02X}   (>0xA0 means finished)"
  echo &"  dma_busy        = {mem.dma_busy}"
  echo &"  requested_oam_dma = {mem.requested_oam_dma}"
  echo &"  current_dma_source = 0x{int(mem.current_dma_source):04X}"
  var line = "  OAM[00..0F]     ="
  for i in 0 ..< 16:
    line.add(&" {emu.ppu.sprite_table[i]:02X}")
  echo line
  # Object registers and candidate tile bitmaps, to compare against the dark
  # pixels of mgb_oam_dma_halt_sprites_expected.png (x 83..88, y 42..47).
  echo &"  LCDC = 0x{emu.ppu.lcd_control:02X}   BGP = {emu.ppu.bgp}   " &
       &"OBP0 = {emu.ppu.obp0}   OBP1 = {emu.ppu.obp1}"
  let tiles = if args.len > 3: args[3 .. ^1] else: @["0x30", "0x38", "0x3A"]
  for t in tiles:
    let n = parseHexInt(t.replace("0x", ""))
    var rows: seq[string] = @[]
    for r in 0 ..< 8:
      let lo = emu.ppu.vram[0][n * 16 + r * 2]
      let hi = emu.ppu.vram[0][n * 16 + r * 2 + 1]
      var s = ""
      for b in countdown(7, 0):
        let v = ((lo shr b) and 1) or (((hi shr b) and 1) shl 1)
        s.add(if v == 0: '.' else: char(ord('0') + int(v)))
      rows.add(s)
    echo &"  tile 0x{n:02X}        = " & rows.join("  ")

main()
