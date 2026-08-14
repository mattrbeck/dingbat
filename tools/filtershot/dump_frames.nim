## filtershot: dump raw BGR555 frames from a headless run, so the web
## presenter's actual GLSL upscale filters can be applied to them offline
## (tools/filtershot/render.mjs) for side-by-side filter comparisons.
##
##   dump_frames <rom(.gb|.gbc|.gba)> <outprefix> <script> <shots>
##
##   script: comma-separated FRAME:KEY[:HOLD] ("" for none) — same contract as
##           tools/romfuzz/dingbat_nav.nim / tools/gbfuzz/dingbat_gb_nav.nim
##   shots:  comma-separated frame numbers; each writes
##           <outprefix>.f<frame>.rgb555 — raw little-endian uint16 pixels,
##           row-major from the top-left, exactly the buffer the presenters
##           upload. Prints "W H" once so the renderer knows the shape.
##
## Build: nim c -d:test_harness -d:release --path:src \
##          -o:tools/filtershot/dump_frames tools/filtershot/dump_frames.nim

import std/[os, strutils, strformat]
import dingbat/gba/gba
import dingbat/gb/gb
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

proc write_raw(path: string; buf: seq[uint16]) =
  var f = open(path, fmWrite)
  discard f.writeBuffer(addr buf[0], buf.len * 2)
  f.close()

proc main() =
  let args = commandLineParams()
  if args.len != 4:
    echo "usage: dump_frames <rom> <outprefix> <script> <shots>"
    quit(2)
  let rom_path = args[0]
  let prefix = args[1]
  let script = parse_script(args[2])
  var shots: seq[int]
  for tok in args[3].split(','):
    if tok.len > 0: shots.add(parseInt(tok))
  var max_frame = 0
  for s in shots: max_frame = max(max_frame, s)

  if rom_path.toLowerAscii().endsWith(".gba"):
    let emu = new_gba("", rom_path, run_bios = false, use_hle = true)
    emu.test_output = new_test_output()
    emu.post_init()
    echo "240 160"
    for f in 0 .. max_frame:
      for ev in script:
        if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
      emu.step_frame()
      if f in shots: write_raw(&"{prefix}.f{f:04}.rgb555", emu.ppu.framebuffer)
  else:
    let emu = new_gb("", rom_path, fifo = true, headless = true,
                     run_bios = false)
    emu.post_init()
    echo "160 144"
    for f in 0 .. max_frame:
      for ev in script:
        if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
      emu.step_frame()
      if f in shots: write_raw(&"{prefix}.f{f:04}.rgb555", emu.ppu.framebuffer)

main()
