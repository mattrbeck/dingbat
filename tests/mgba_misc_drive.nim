## mGBA suite "Misc. edge case tests", driven through the INTERACTIVE ROM's
## menus the way a person does: A on the suite runs it (the verdicts the
## auto-run fork reports), then A on each test opens its results page, which
## RUNS THE TEST AGAIN from inside the menu loop -- a second run the fork never
## makes, starting from whatever the first left behind (a stale H-blank IF bit
## after `H-blank bit start`). Prints the suite run's debug lines and each
## results page's text, read from the ROM's textGrid in IWRAM.
##
##   nim c -d:test_harness -d:release --path:src -o:mgba_misc_drive tests/mgba_misc_drive.nim
##   ./mgba_misc_drive <interactive suite.gba> [bios.bin] [boot frames] [frames between keys]
##
## PRE=3,4 runs those suites (menu index) first: suites that register IRQ
## handlers leave them in libgba's table, and each one makes VBlankIntrWait
## return later, so `DMA Prefetch Break` moves -- on hardware too; the fork
## calls irqInit() between suites for this reason. NOWL=1 turns the waitloop
## skip off. The ROM's own "Got X vs Y" log lines print expected first.
## Exit 1 if the suite run or any results page shows a failure.
import std/[os, strutils, strformat]
import dingbat/gba/gba
import dingbat/common/test_output
import dingbat/common/input

var gap = 3
var failed = false

proc tap(emu: GBA; key: Input) =
  emu.handle_input(key, true)
  for _ in 0 ..< 3: emu.step_frame()
  emu.handle_input(key, false)
  for _ in 0 ..< gap: emu.step_frame()

proc wait(emu: GBA; n: int) =
  for _ in 0 ..< n: emu.step_frame()

proc find_grid(emu: GBA): int =
  ## textGrid[32..] holds the suite / page title; search IWRAM for it
  let w = emu.bus.wram_chip
  for needle in ["Misc. edge case", "Miscellaneous"]:
    for i in 0 .. w.len - needle.len:
      var ok = true
      for k, c in needle:
        if char(w[i + k]) != c: ok = false; break
      if ok and i >= 32: return i - 32
  -1

proc grid_text(emu: GBA): seq[string] =
  let g = emu.find_grid()
  if g < 0: return
  let w = emu.bus.wram_chip
  for row in 0 ..< 20:
    var s = ""
    for col in 0 ..< 32:
      let c = w[g + row * 32 + col]
      s.add(if c == 0: ' ' else: char(c))
    if s.strip.len > 0: result.add s.strip(leading = false)

proc dump(emu: GBA; label: string) =
  ## the page is cleared and redrawn every loop pass: keep the fullest capture
  var best: seq[string]
  for _ in 0 ..< 20:
    let t = emu.grid_text()
    if t.len > best.len: best = t
    emu.step_frame()
  echo &"--- {label}"
  for l in best:
    echo "  |", l
    if "!=" in l: failed = true

proc ends(emu: GBA): int = emu.test_output.mgba_debug_output.count("END:")

proc run_suite(emu: GBA) =
  let n = emu.ends()
  emu.tap(A)
  var f = 0
  while emu.ends() == n and f < 60 * 600:
    emu.step_frame(); inc f
  emu.wait(10)

proc main() =
  let rom_src = paramStr(1)
  let bios = if paramCount() >= 2: paramStr(2) else: ""
  let pre = if paramCount() >= 3: parseInt(paramStr(3)) else: 30
  if paramCount() >= 4: gap = parseInt(paramStr(4))
  let work = getTempDir() / &"misc_drive_{getCurrentProcessId()}"
  createDir(work)
  defer: removeDir(work)
  let rom = work / "suite.gba"
  copyFile(rom_src, rom)
  let lle = bios.len > 0
  let emu = new_gba(bios, rom, run_bios = lle, use_hle = not lle)
  emu.test_output = new_test_output()
  emu.post_init()
  if getEnv("NOWL") == "1": emu.cpu.attempt_waitloop_detection = false
  emu.wait(if lle: pre + 400 else: pre)
  var cur = 0
  let pre_suites = getEnv("PRE")
  if pre_suites.len > 0:
    for p in pre_suites.split(','):
      let idx = parseInt(p)
      while cur < idx: emu.tap(DOWN); inc cur
      emu.run_suite()
      echo &"--- ran suite {idx}: " & emu.test_output.mgba_debug_output.splitLines[^2]
      emu.tap(B); emu.wait(10)
  while cur < 12: emu.tap(DOWN); inc cur
  emu.test_output.mgba_debug_output = ""
  emu.run_suite()                 # Misc. edge case tests
  echo "--- run-phase debug output"
  for l in emu.test_output.mgba_debug_output.splitLines:
    if l.strip.len > 0: echo "  ", l
    if l.startsWith("FAIL:"): failed = true
  emu.dump("list")
  for t in 0 ..< 3:
    emu.tap(A)                    # show page: re-runs the test
    emu.wait(120)
    emu.dump(&"show #{t}")
    emu.tap(B)
    emu.wait(10)
    emu.tap(DOWN)
  if failed: quit(1)

main()
