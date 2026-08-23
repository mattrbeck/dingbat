# ============================================================================
# GB scripted navigation driver (MANUAL tool, not part of CI)
# ============================================================================
#
# Drives one GB/GBC core with a per-frame held-button script and dumps
# screenshots; used to build the Cable Club saves for gb_trade_repro.nim.
# Deterministic: every run replays the script from power-on.
#
# Nav line: "<frame> <core> <tok...>" sets HELD buttons from <frame> onward.
# <core> is ignored (single core) but kept format-compatible with trade_repro
# scripts. Tokens: A B UP DOWN LEFT RIGHT START SELECT NONE(-).
#
# BUILD
#   nim c -d:test_harness -d:release --path:src -o:gb_nav tests/gb_nav.nim
# RUN
#   ./gb_nav <rom> <script.txt> <frames> <shotdir> [--shots=N]
# The cart's battery save (.sav next to the ROM) is loaded at boot and
# flushed on exit; run against a COPY of the ROM.
# ============================================================================

import std/[os, strutils]
import dingbat/gb/gb
import dingbat/common/input

type Cmd = object
  frame: int
  held: set[Input]

proc parseButtons(toks: seq[string]): set[Input] =
  for t in toks:
    case t.toUpperAscii()
    of "A": result.incl A
    of "B": result.incl B
    of "UP": result.incl UP
    of "DOWN": result.incl DOWN
    of "LEFT": result.incl LEFT
    of "RIGHT": result.incl RIGHT
    of "START": result.incl START
    of "SELECT": result.incl SELECT
    of "NONE", "-": discard
    else: discard

proc loadScript(path: string): seq[Cmd] =
  if not fileExists(path):
    raise newException(IOError, "nav script not found: " & path)
  for line in lines(path):
    let s = line.strip()
    if s.len == 0 or s.startsWith("#"): continue
    let parts = s.splitWhitespace()
    if parts.len < 3: continue
    result.add Cmd(frame: parseInt(parts[0]), held: parseButtons(parts[2 .. ^1]))

proc bgr555_to_rgb(c: uint16): array[3, uint8] =
  let r5 = int(c and 0x1F)
  let g5 = int((c shr 5) and 0x1F)
  let b5 = int((c shr 10) and 0x1F)
  [uint8((r5 shl 3) or (r5 shr 2)),
   uint8((g5 shl 3) or (g5 shr 2)),
   uint8((b5 shl 3) or (b5 shr 2))]

proc write_ppm(path: string; buf: seq[uint16]) =
  var f = open(path, fmWrite)
  f.write("P6\n" & $GB_WIDTH & " " & $GB_HEIGHT & "\n255\n")
  for pixel in buf:
    let rgb = bgr555_to_rgb(pixel)
    f.write(char(rgb[0])); f.write(char(rgb[1])); f.write(char(rgb[2]))
  f.close()

proc main() =
  var rom, script, shotdir = ""
  var frames = 0
  var shot_every = 0
  var positional = 0
  for arg in commandLineParams():
    if arg.startsWith("--shots="):
      shot_every = parseInt(arg[8 .. ^1])
    else:
      case positional
      of 0: rom = arg
      of 1: script = arg
      of 2: frames = parseInt(arg)
      of 3: shotdir = arg
      else: discard
      inc positional
  if shotdir.len == 0:
    echo "usage: gb_nav <rom> <script.txt> <frames> <shotdir> [--shots=N]"
    quit(1)
  createDir(shotdir)

  let cmds = loadScript(script)
  let emu = new_gb("", rom, fifo = true, headless = true, run_bios = false)
  emu.post_init()

  var held: set[Input]
  var si = 0
  for f in 0 ..< frames:
    while si < cmds.len and cmds[si].frame <= f:
      for inp in Input:
        if inp in cmds[si].held and inp notin held: emu.handle_input(inp, true)
        if inp notin cmds[si].held and inp in held: emu.handle_input(inp, false)
      held = cmds[si].held
      inc si
    emu.step_frame()
    if shot_every > 0 and f mod shot_every == 0:
      write_ppm(shotdir / ("f" & align($f, 6, '0') & ".ppm"), emu.ppu.framebuffer)
  write_ppm(shotdir / "final.ppm", emu.ppu.framebuffer)
  emu.cartridge.mbc_save()
  echo "ran ", frames, " frames; final screenshot + save flushed"

main()
