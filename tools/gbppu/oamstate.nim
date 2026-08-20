## Dump OAM and the OAM DMA unit's state after running a ROM.
##
## For mooneye madness/mgb_oam_dma_halt_sprites, which halts two M-cycles into
## an OAM DMA and never wakes: the questions are whether the transfer FROZE
## (dma_position stuck near 2 with dma_busy still set) or ran to completion
## (position past $A0, OAM all $FF), and what the first OAM bytes actually hold.
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

main()
