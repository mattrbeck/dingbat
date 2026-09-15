## mGBA suite "Video tests": each test draws an "actual" screen through the
## hardware behaviour under test and an "expected" screen built from plain
## tiles. The suite only shows them side by side (no automated verdict), so
## this harness drives the interactive ROM's menus and diffs the two frames.
##
##   nim c -d:test_harness -d:release --path:src -o:mgba_video tests/mgba_video.nim
##   ./mgba_video <interactive suite.gba> [out dir for PPMs]
##
## The ROM must be upstream's interactive build (a menu, no "ALL DONE"); the
## auto-run fork the CI uses skips the Video suite. Exit 1 if any test
## differs.

import std/[os, strutils, strformat]
import dingbat/gba/gba
import dingbat/common/test_output
import dingbat/common/input

const Tests = ["Basic Mode 3", "Basic Mode 4", "Degenerate OBJ transforms",
               "Layer toggle", "Layer toggle 2", "OAM Update Delay",
               "Window offscreen reset"]
const VideoSuiteIndex = 13  # last entry of the suite menu: UP from the top

proc tap(emu: GBA; key: Input) =
  emu.handle_input(key, true)
  for _ in 0 ..< 3: emu.step_frame()
  emu.handle_input(key, false)
  for _ in 0 ..< 3: emu.step_frame()

proc settle(emu: GBA) =
  for _ in 0 ..< 12: emu.step_frame()

proc write_ppm(path: string; fb: seq[uint16]) =
  var s = "P6\n240 160\n255\n"
  for c in fb:
    for sh in [0, 5, 10]:
      let v = int((c shr sh) and 0x1F)
      s.add char((v shl 3) or (v shr 2))
  writeFile(path, s)

proc ranges(xs: seq[int]): string =
  var i = 0
  while i < xs.len:
    var j = i
    while j + 1 < xs.len and xs[j + 1] == xs[j] + 1: inc j
    if result.len > 0: result.add ","
    result.add(if i == j: $xs[i] else: &"{xs[i]}-{xs[j]}")
    i = j + 1

proc main(): int =
  if paramCount() < 1:
    echo "usage: mgba_video <interactive suite.gba> [out dir]"
    return 2
  let src = paramStr(1)
  let out_dir = if paramCount() >= 2: paramStr(2) else: ""
  # A private copy, so the ROM's SRAM log never lands beside the original
  let work = getTempDir() / &"mgba_video_{getCurrentProcessId()}"
  createDir(work)
  defer: removeDir(work)
  let rom = work / "suite.gba"
  copyFile(src, rom)
  if out_dir.len > 0: createDir(out_dir)
  for t, name in Tests:
    let emu = new_gba("", rom, run_bios = false, use_hle = true)
    emu.test_output = new_test_output()
    emu.post_init()
    if getEnv("DINGBAT_NO_WAITLOOP") == "1":
      emu.cpu.attempt_waitloop_detection = false
    for _ in 0 ..< 30: emu.step_frame()
    for _ in 0 ..< (14 - VideoSuiteIndex): emu.tap(UP)  # wrap to the Video suite
    emu.tap(A)
    for _ in 0 ..< t: emu.tap(DOWN)
    emu.tap(A)       # show "actual"
    emu.tap(START)   # hide the Actual/Expected label sprite
    emu.settle()
    let actual = emu.ppu.framebuffer
    emu.tap(RIGHT)   # show "expected"
    emu.settle()
    let expected = emu.ppu.framebuffer
    var rows: seq[int]
    var n = 0
    for y in 0 ..< 160:
      var row_diff = false
      for x in 0 ..< 240:
        # 15-bit colour: a mode 3 pixel can carry the unused bit 15
        if ((actual[y * 240 + x] xor expected[y * 240 + x]) and 0x7FFF) != 0:
          inc n
          row_diff = true
      if row_diff: rows.add y
    let slug = name.toLowerAscii.replace(" ", "_").replace(".", "")
    if out_dir.len > 0:
      write_ppm(out_dir / slug & ".actual.ppm", actual)
      write_ppm(out_dir / slug & ".expected.ppm", expected)
    if n == 0:
      echo &"PASS  {name}"
    else:
      result = 1
      echo &"FAIL  {name}: {n} pixels on lines {ranges(rows)}"

quit(main())
