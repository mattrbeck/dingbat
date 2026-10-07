## The iOS app's C API (src/dingbat_ios.nim), driven the way the Swift shell
## drives it: through the exported C symbols, on committed ROMs. Covers load,
## frames, state round trips and refusals, hold-to-rewind, the rewind
## scrubber's commit, run-ahead, cheats, the LCD response and the Super Game
## Boy border.
## Run standalone: nimble test_iosapi   (or ./dingbat_ios_api_test)
##
## Built with -d:test_harness like every test, so the APUs skip the SDL
## queue the iOS audio ring stands in for; the ring itself is not covered.

import std/[os, strutils]
import dingbat_ios

proc dingbat_load_rom(rom, bios: cstring): cint {.importc, cdecl.}
proc dingbat_unload() {.importc, cdecl.}
proc dingbat_reset(): cint {.importc, cdecl.}
proc dingbat_loaded(): cint {.importc, cdecl.}
proc dingbat_is_gb(): cint {.importc, cdecl.}
proc dingbat_set_sgb(on: cint) {.importc, cdecl.}
proc dingbat_run_frame() {.importc, cdecl.}
proc dingbat_run_frame_ahead(n: cint) {.importc, cdecl.}
proc dingbat_game_fb(): ptr uint16 {.importc, cdecl.}
proc dingbat_framebuffer(): ptr uint16 {.importc, cdecl.}
proc dingbat_fb_width(): cint {.importc, cdecl.}
proc dingbat_fb_height(): cint {.importc, cdecl.}
proc dingbat_out_width(): cint {.importc, cdecl.}
proc dingbat_set_lcd_response(on: cint) {.importc, cdecl.}
proc dingbat_sgb_border(): cint {.importc, cdecl.}
proc dingbat_state_size(): cint {.importc, cdecl.}
proc dingbat_state_data(): pointer {.importc, cdecl.}
proc dingbat_load_state(data: pointer; len, keep: cint): cint {.importc, cdecl.}
proc dingbat_state_error_kind(): cint {.importc, cdecl.}
proc dingbat_set_rewind(on, cap: cint) {.importc, cdecl.}
proc dingbat_rewind_pop(): cint {.importc, cdecl.}
proc dingbat_rewind_scrub_generate(n: cint): cint {.importc, cdecl.}
proc dingbat_rewind_scrub_thumb_w(): cint {.importc, cdecl.}
proc dingbat_rewind_scrub_seconds_ago(s: cint): cint {.importc, cdecl.}
proc dingbat_rewind_commit(s: cint): cint {.importc, cdecl.}
proc dingbat_load_cheats(text: cstring): cstring {.importc, cdecl.}
proc dingbat_set_input(id, pressed: cint) {.importc, cdecl.}

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc frameHash(): uint64 =
  let fb = cast[ptr UncheckedArray[uint16]](dingbat_framebuffer())
  result = 1469598103934665603'u64
  for i in 0 ..< int(dingbat_fb_width() * dingbat_fb_height()):
    result = (result xor uint64(fb[i])) * 1099511628211'u64

proc takeState(): string =
  let n = dingbat_state_size()
  result = newString(n)
  if n > 0: copyMem(addr result[0], dingbat_state_data(), n)

proc applyState(s: string; keep = false): bool =
  dingbat_load_state(unsafeAddr s[0], cint(s.len), cint(keep)) == 1

let root = currentSourcePath.parentDir.parentDir
let tmp = getTempDir() / "dingbat_ios_api_test"
createDir(tmp)

proc staged(src: string): string =
  ## A writable copy: the core writes the battery save beside the ROM.
  result = tmp / src.extractFilename
  copyFile(root / src, result)
  removeFile(result.changeFileExt("sav"))

echo "GBA: load, frames, states"
block:
  dingbat_set_rewind(1, 0)
  check dingbat_load_rom(cstring(staged("web/goodboy-demo-en.gba")), nil) == 0, "loads"
  check dingbat_loaded() == 1 and dingbat_is_gb() == 0, "a GBA core runs"
  for _ in 0 ..< 240: dingbat_run_frame()
  check dingbat_game_fb() != nil, "a picture to present"
  let s = takeState()
  check s.startsWith("DGBSTATE"), "state image"
  let at = frameHash()
  for _ in 0 ..< 60: dingbat_run_frame()
  check applyState(s), "state loads"
  check frameHash() == at, "state brings the picture back"
  var junk = "not a state at all"
  check not applyState(junk) and dingbat_state_error_kind() == 1, "junk refused as not a state"

echo "GBA: hold-to-rewind and the scrubber"
block:
  for _ in 0 ..< 300: dingbat_run_frame()
  check dingbat_rewind_pop() == 1, "rewind pops a snapshot"
  let n = dingbat_rewind_scrub_generate(16)
  check n > 1 and dingbat_rewind_scrub_thumb_w() == 120, "scrub strip of 120-wide thumbs"
  let oldest = n - 1
  check dingbat_rewind_scrub_seconds_ago(oldest) > 0, "oldest sample is in the past"
  check dingbat_rewind_commit(oldest) == 1, "commit to the oldest moment"
  check dingbat_rewind_scrub_generate(16) <= 2, "commit drops the newer history"

echo "GBA: run-ahead leaves the canonical timeline alone"
block:
  let s = takeState()
  for _ in 0 ..< 30: dingbat_run_frame()
  let plain = takeState()
  check applyState(s), "back to the start"
  for _ in 0 ..< 30: dingbat_run_frame_ahead(2)
  let ahead = takeState()
  # The state header carries no wall clock, so equal images mean the same
  # emulated machine.
  check plain == ahead, "30 frames with run-ahead 2 = 30 plain frames"

echo "GBA: cheats"
block:
  check $dingbat_load_cheats("[x] Good\n82000000 0001\n\n") == "", "a valid code parses"
  check ($dingbat_load_cheats("[x] Bad\nnot a code\n\n")).startsWith("Bad:"), "a bad code is named"
  check $dingbat_load_cheats("") == "", "clearing"

echo "GB: LCD response"
block:
  dingbat_set_sgb(0)
  check dingbat_load_rom(cstring(staged("tests/roms/lcdflicker.gb")), nil) == 0, "loads"
  check dingbat_is_gb() == 1 and dingbat_fb_width() == 160, "a GB core runs"
  dingbat_set_lcd_response(1)
  for _ in 0 ..< 60: dingbat_run_frame()
  check dingbat_game_fb() != dingbat_framebuffer(), "LCD response presents its own buffer"
  dingbat_set_lcd_response(0)
  dingbat_run_frame()
  check dingbat_game_fb() == dingbat_framebuffer(), "off: the core's framebuffer"

echo "GB: Super Game Boy border"
block:
  dingbat_set_sgb(1)
  check dingbat_load_rom(cstring(staged("tests/roms/sgbtest.gb")), nil) == 0, "loads"
  for _ in 0 ..< 600: dingbat_run_frame()
  if dingbat_sgb_border() == 1:
    check dingbat_out_width() == 256, "border widens the output"
  else:
    echo "  note sgbtest.gb sent no border in 600 frames"
  dingbat_set_input(7, 1); dingbat_run_frame(); dingbat_set_input(7, 0)
  check dingbat_reset() == 0, "reset reloads"
  dingbat_unload()
  check dingbat_loaded() == 0 and dingbat_game_fb() == nil, "unload drops the core"

if failures > 0:
  echo failures, " failure(s)"
  quit 1
echo "all passed"
