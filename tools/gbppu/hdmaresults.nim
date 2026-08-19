## Dump mealybug `dma/hdma_timing-C`'s own result buffer, sub-test by sub-test.
##
## The ROM renders its results, but base.asm wraps text at 32 columns while the
## screen shows 20, so a third of the cells are off-screen and the picture
## cannot be read. The buffer itself is exact. `Results` is a WRAM0 section
## with ALIGN[8], 254 bytes, followed by ResultCounter and TestResult ('P'/'F'),
## so it is found by scanning 256-aligned WRAM pages for one whose +254 byte is
## the expected sub-test count and whose +255 is 'P' or 'F'.
##
## Usage: hdmaresults <rom> [frames] [model]
import std/[os, strutils, strformat]
import dingbat/gb/gb

const Expected: array[48, uint8] = [
  # SCX = 1
  0x83'u8, 0x80, 0x80, 0x82,  0x00, 0xff, 0xff, 0xff,
  # SCX = 2 -- HDMA delayed by the longer mode 3
  0x83,     0x80, 0x80, 0x82,  0x00, 0x00, 0xff, 0xff,
  # HDMA duration measured with DIV
  0x01,     0x02, 0x01, 0x02,  0x03, 0x04, 0x03, 0x04,
  # SCX = 1, double speed
  0x83,     0x80, 0x80, 0x82,  0x00, 0xff, 0xff, 0xff,
  # SCX = 2, double speed
  0x83,     0x80, 0x80, 0x82,  0x00, 0x00, 0xff, 0xff,
  # duration with DIV, double speed
  0x03,     0x04, 0x03, 0x04,  0x07, 0x08, 0x07, 0x08,
]

const GroupNames = [
  "SCX=1            STAT x4 / HDMA5 x4",
  "SCX=2            STAT x4 / HDMA5 x4",
  "DIV duration     16B x4 / 32B x4",
  "SCX=1 2x speed   STAT x4 / HDMA5 x4",
  "SCX=2 2x speed   STAT x4 / HDMA5 x4",
  "DIV duration 2x  16B x4 / 32B x4",
]

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    echo "usage: hdmaresults <rom> [frames] [model]"
    quit(1)
  let frames = if args.len > 1: parseInt(args[1]) else: 400
  let model  = if args.len > 2: args[2] else: "cgbc"

  let emu = new_gb("", args[0], fifo = true, headless = true, run_bios = false)
  let (rev, _) = gb_revision_from_name(model)
  emu.gb_set_revision(rev)
  emu.post_init()
  for _ in 0 ..< frames:
    emu.step_frame()

  # Find the results page.
  var found = -1
  var bank = 0
  for b in 0 ..< emu.memory.wram.len:
    if emu.memory.wram[b].len == 0: continue
    var off = 0
    while off + 256 <= emu.memory.wram[b].len:
      let cnt = emu.memory.wram[b][off + 254]
      let res = emu.memory.wram[b][off + 255]
      if cnt == 48'u8 and (res == uint8('P') or res == uint8('F')):
        found = off; bank = b
      off += 256
  if found < 0:
    echo "results buffer not located (ROM may not have finished; try more frames)"
    quit(2)

  let verdict = char(emu.memory.wram[bank][found + 255])
  echo &"model={model}  frames={frames}  bank={bank}  offset=0x{found:04X}  verdict={verdict}"
  var wrong = 0
  for g in 0 ..< 6:
    var line = ""
    var bad = 0
    for i in 0 ..< 8:
      let idx = g*8 + i
      let got = emu.memory.wram[bank][found + idx]
      let exp = Expected[idx]
      if got == exp:
        line.add(&"  {got:02X}    ")
      else:
        line.add(&"  {got:02X}!={exp:02X}")
        inc bad
        inc wrong
      if i == 3: line.add(" |")
    echo &"  [{g}] {GroupNames[g]}"
    echo &"      {line}   ({bad} wrong)"
  echo &"TOTAL WRONG: {wrong} / 48"

main()
