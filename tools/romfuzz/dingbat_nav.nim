## Headless dingbat runner for cross-emulator screenshot comparison.
## Same CLI contract as mgba_runner.c / nba_runner.cpp, plus save states.
##
## Usage: dingbat_nav <rom.gba> <bios.bin|hle> <outprefix> <script> <shots> [--state]
##   script: comma-separated FRAME:KEY[:HOLD] ("" for none)
##   shots:  comma-separated frames; writes <outprefix>.f<frame>.ppm
##   --state: also save_state to <outprefix>.f<frame>.state at each shot
##
## Build: nim c -d:test_harness -d:release --path:src -o:tools/romfuzz/dingbat_nav tools/romfuzz/dingbat_nav.nim

import std/[os, strutils, strformat]
import dingbat/gba/gba
import dingbat/common/input
import dingbat/common/test_output

type InputEvent = tuple[frame: int, key: Input, pressed: bool]

proc parse_script(script: string): seq[InputEvent] =
  for entry in script.split(','):
    if entry.len == 0: continue
    let parts = entry.split(':')
    let frame = parseInt(parts[0])
    let key = parseEnum[Input](parts[1].toUpperAscii())
    let hold = if parts.len > 2: parseInt(parts[2]) else: 10
    result.add((frame, key, true))
    result.add((frame + hold, key, false))

proc write_ppm(path: string; buf: seq[uint16]) =
  var f = open(path, fmWrite)
  f.write("P6\n240 160\n255\n")
  for pixel in buf:
    let r5 = pixel and 0x1F
    let g5 = (pixel shr 5) and 0x1F
    let b5 = (pixel shr 10) and 0x1F
    f.write(char(uint8((r5 shl 3) or (r5 shr 2))))
    f.write(char(uint8((g5 shl 3) or (g5 shr 2))))
    f.write(char(uint8((b5 shl 3) or (b5 shr 2))))
  f.close()

proc main() =
  let args = commandLineParams()
  if args.len < 5:
    echo "Usage: dingbat_nav <rom> <bios|hle> <outprefix> <script> <shots> [--state]"
    quit(2)
  let rom_path = args[0]
  let bios = args[1]
  let prefix = args[2]
  let script = parse_script(args[3])
  var shots: seq[int]
  for tok in args[4].split(','):
    if tok.len > 0: shots.add(parseInt(tok))
  let want_state = args.len > 5 and args[5] == "--state"

  let use_hle = bios == "hle"
  # run_bios=false skips the boot logo so frame 0 is the first game frame,
  # matching the skip-bios configs of the mGBA/NBA runners.
  let emu = new_gba(if use_hle: "" else: bios, rom_path,
                    run_bios = false, use_hle = use_hle)
  emu.test_output = new_test_output()
  emu.post_init()

  var max_frame = 0
  for s in shots: max_frame = max(max_frame, s)

  for f in 0 .. max_frame:
    for ev in script:
      if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
    emu.step_frame()
    if f in shots:
      write_ppm(&"{prefix}.f{f:04}.ppm", emu.ppu.framebuffer)
      if want_state:
        if not emu.save_state(&"{prefix}.f{f:04}.state"):
          stderr.writeLine "save_state failed at frame " & $f

main()
