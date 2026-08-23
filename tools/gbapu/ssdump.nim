## Dump a SameSuite APU ROM's result buffer out of dingbat, on a chosen
## revision.
##
##     tools/gbapu/ssdump <rom.gb> [frames] [model] [count]
##
## Every SameSuite APU ROM stores its measurements as raw bytes at `$C000` and
## only *then* renders them as a hex grid, so reading WRAM is the whole test at
## byte resolution rather than a pass/fail bit. `$CFFE` is the ROM's own
## verdict: `$50` while every comparison has matched, `$46` once one has not,
## so `count = 4096` and the byte at offset `$0FFE` is a PASS/FAIL that does not
## depend on knowing where this particular ROM's table lives.
##
## `frames` must be large enough for the ROM to finish (400 is safe for all
## 70; 60 is not). `model` is any `gb_revision_from_name` token: cgb0, cgbAB,
## cgbC, cgbD, cgbE, agb. The oracle half is tools/gbfuzz/sameboy_ssdump.c.
import std/[os, strutils]
import dingbat/gb/gb

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    echo "usage: ssdump <rom> [frames] [model] [count]"
    quit(1)
  let frames = if args.len > 1: parseInt(args[1]) else: 400
  let model  = if args.len > 2: args[2] else: "cgbE"
  let count  = if args.len > 3: parseInt(args[3]) else: 16
  let emu = new_gb("", args[0], fifo = true, headless = true, run_bios = false)
  let (rev, ok) = gb_revision_from_name(model)
  if not ok:
    echo "unknown model: ", model
    quit(1)
  emu.gb_set_revision(rev)
  emu.post_init()
  for _ in 0 ..< frames: emu.step_frame()
  var line = ""
  for i in 0 ..< count:
    line.add(toHex(emu.memory.wram[0][i], 2).toLowerAscii)
  echo line

main()
