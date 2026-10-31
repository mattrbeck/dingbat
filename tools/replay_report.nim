## Replay a bug report the iOS app made after a core fault (FaultView ›
## Send a bug report, report version 2): start where the device's game last
## started fresh (power-on, or the state it last loaded: the report's
## `state`), hold the report's buttons frame by frame, and stop where the
## core raises. That re-runs the player's frames exactly, state a save does
## not hold included (it starts out the same here as on the device), and
## lands on the faulting frame with a stack trace from a debug-able build:
##
##   nim c -d:release --stackTrace:on --lineTrace:on --path:src \
##     -o:replay_report tools/replay_report.nim
##   ./replay_report <rom> <report.json> [--after N] [--shot out.ppm]
##
## The ROM is never in a report: pass the same game. GB and GBA reports
## only (the DS keeps no input log). GBA runs the HLE BIOS, as the app does
## without a BIOS file; the report's `settings` say what the device ran.
## --after N keeps running N frames past the log with no buttons (a fault
## that a fix moved, or a report without a replay); --shot writes the
## framebuffer where it stopped as a binary PPM (BGR555 widened to RGB).
##
## The report's `replay.checks` fingerprint the whole state once a second on
## the device; the replay compares its own at each, so a replay that leaves
## the device's path says where. Bit 15 of a frame's buttons marks run-ahead:
## the device put the core's own state back onto it after that frame, and so
## does this. A report from a stand-in start (the clip anchor, when the app
## had no record back to a fresh one) cannot carry what a save state leaves
## out: all checks matching and the faulting frame running clean then means
## the cause is there (the 2026-10-31 PPU bug: a sprite-abort window that
## outlived its line) or the build has the fix.

import std/[os, strutils, strformat, json, base64]
import dingbat/common/input
import dingbat/common/serialize
import dingbat/gb/gb
import dingbat/gb/printer
import dingbat/gba/gba

proc usage() =
  echo "usage: replay_report <rom> <report.json> [--after N] [--shot out.ppm]"
  quit(2)

proc write_ppm(path: string; fb: openArray[uint16]; w, h: int) =
  var f = open(path, fmWrite)
  f.write(&"P6\n{w} {h}\n255\n")
  for p in fb:
    for sh in [0, 5, 10]:
      let c = int((p shr sh) and 0x1F)
      f.write(char((c shl 3) or (c shr 2)))
  f.close()

proc main() =
  let args = commandLineParams()
  if args.len < 2: usage()
  let romPath = args[0]
  let report = parseJson(readFile(args[1]))
  var after = 0
  var shot = ""
  var i = 2
  while i < args.len:
    case args[i]
    of "--after": after = parseInt(args[i + 1]); inc i, 2
    of "--shot": shot = args[i + 1]; inc i, 2
    else: usage()
  if report{"kind"}.getStr != "dingbat-bug-report": quit "not a dingbat bug report"
  let powerOn = report{"replay"} != nil and report["replay"]{"fromPowerOn"}.getBool
  if report{"state"}.kind != JString and not powerOn: quit "the report has nothing to start from"
  let image = if powerOn: "" else: decode(report["state"].getStr)
  var buttons: seq[uint16]
  var fromFrame = -1
  if report{"replay"} != nil:
    let raw = decode(report["replay"]["buttons"].getStr)
    for k in 0 ..< raw.len div 2:
      buttons.add(uint16(uint8(raw[2 * k])) or (uint16(uint8(raw[2 * k + 1])) shl 8))
    fromFrame = report["replay"]["fromFrame"].getInt
  var checks: seq[(int, string)]
  if report{"replay"} != nil and report["replay"]{"checks"} != nil:
    for item in report["replay"]["checks"].getStr.split(','):
      let kv = item.split(':')
      if kv.len == 2: checks.add((parseInt(kv[0]), kv[1]))
  let fault = report{"fault"}
  if fault != nil:
    echo "reported: ", fault["message"].getStr, " on frame ", fault["frame"].getInt,
         " (stop ", fault["count"].getInt, ")"
  echo "game: ", report{"game"}.getStr, " · from ",
       (if powerOn: "power-on" else: report{"savedFrom"}.getStr), " · ", buttons.len, " frames of buttons"

  let isGb = romPath.splitFile.ext.toLowerAscii in [".gb", ".gbc", ".sgb"]
  var gbCore: GB
  var gbaCore: GBA
  if isGb:
    gbCore = new_gb("", romPath, headless = true, run_bios = false)
    gbCore.post_init()
    gbCore.cartridge.sav_path = ""   # never write the game's save
    # The app keeps a Game Boy Printer on every GB game's link port.
    gbCore.set_serial_driver(GbPrinterDriver(printer: new_gb_printer()))
    if not powerOn and not gbCore.load_state_bytes(image):
      quit "the state does not load: " & last_state_error
  else:
    gbaCore = new_gba("", romPath, run_bios = false, use_hle = true)
    gbaCore.post_init()
    if not powerOn and not gbaCore.load_state_bytes(image):
      quit "the state does not load: " & last_state_error

  proc hold(mask: uint16) =
    for b in 0 .. ord(Input.high):
      let down = (mask and (1'u16 shl b)) != 0
      if isGb: gbCore.handle_input(Input(b), down) else: gbaCore.handle_input(Input(b), down)

  proc fnv64(s: string): uint64 =
    result = 14695981039346656037'u64
    for c in s: result = (result xor uint64(uint8(c))) * 1099511628211'u64

  var matched = 0
  var lastMatch = -1
  var firstMiss = -1
  var ci = 0
  proc check_state(frame: int) =
    while ci < checks.len and checks[ci][0] < frame: inc ci
    if ci < checks.len and checks[ci][0] == frame:
      let p = if isGb: gbCore.state_payload() else: gbaCore.state_payload()
      if toHex(fnv64(p)) == checks[ci][1]:
        inc matched
        lastMatch = frame
      elif firstMiss < 0: firstMiss = frame

  proc verdict() =
    if checks.len == 0: return
    if firstMiss >= 0:
      echo &"left the device's path: state differs from the device's at frame {firstMiss}" &
           (if lastMatch >= 0: &" (matched through frame {lastMatch})" else: "")
    else:
      echo &"matched the device's state at all {matched} of {checks.len} checks" &
           (if lastMatch >= 0: &" (last at frame {lastMatch})" else: "")

  let total = buttons.len + after
  var f = 0
  try:
    while f < total:
      if fromFrame >= 0: check_state(fromFrame + f)
      let mask = if f < buttons.len: buttons[f] else: 0'u16
      hold(mask)
      if isGb: gbCore.step_frame() else: gbaCore.step_frame()
      if (mask and 0x8000'u16) != 0:  # run-ahead: its own state back on
        if isGb: gbCore.apply_state_payload(gbCore.state_payload())
        else: gbaCore.apply_state_payload(gbaCore.state_payload())
      inc f
  except Exception as e:
    let at = if fromFrame >= 0: &" (frame {fromFrame + f})" else: ""
    verdict()
    echo &"stopped on replay frame {f}{at}: {e.name}: {e.msg}"
    let trace = e.getStackTrace()
    if trace.len > 0: echo trace
    else: echo "(build with --stackTrace:on --lineTrace:on for where)"
    if shot.len > 0:
      if isGb: write_ppm(shot, gbCore.ppu.framebuffer, GB_WIDTH, GB_HEIGHT)
      else: write_ppm(shot, gbaCore.ppu.framebuffer, 240, 160)
    quit(0)
  verdict()
  echo &"replayed {f} frames without a fault"
  if fault != nil and fault{"count"}.getInt > 0 and firstMiss < 0 and checks.len > 0 and f >= buttons.len:
    echo "the device faulted on the last of them; the replay matched it all the way and ran it clean:"
    if powerOn: echo "this build does not reach the fault (fixed, or another setting: see the report's settings)"
    else: echo "this build has the fix, or what stopped the device is core state a save state does not hold"
  if shot.len > 0:
    if isGb: write_ppm(shot, gbCore.ppu.framebuffer, GB_WIDTH, GB_HEIGHT)
    else: write_ppm(shot, gbaCore.ppu.framebuffer, 240, 160)
  quit(1)

main()
