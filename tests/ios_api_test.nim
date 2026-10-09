## The iOS app's C API (src/dingbat_ios.nim), driven the way the Swift shell
## drives it: through the exported C symbols, on committed ROMs. Covers load,
## frames, state round trips and refusals, hold-to-rewind, the rewind
## scrubber's commit, clip replay, run-ahead, cheats, the LCD response and the Super Game
## Boy border.
## Run standalone: nimble test_iosapi   (or ./dingbat_ios_api_test)
##
## Built with -d:test_harness like every test, so the APUs skip the SDL
## queue the iOS audio ring stands in for; the ring itself is not covered.

import std/[os, strutils]
import dingbat_ios

proc dingbat_load_rom(rom, bios: cstring): cint {.importc, cdecl.}
proc dingbat_unload(flush: cint) {.importc, cdecl.}
proc dingbat_reset(): cint {.importc, cdecl.}
proc dingbat_loaded(): cint {.importc, cdecl.}
proc dingbat_is_gb(): cint {.importc, cdecl.}
proc dingbat_set_sgb(on: cint) {.importc, cdecl.}
proc dingbat_run_frame() {.importc, cdecl.}
proc dingbat_run_frame_ahead(n: cint) {.importc, cdecl.}
proc dingbat_unseen_next() {.importc, cdecl.}
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
proc dingbat_clip_begin(startAgo, endAgo: cint): cint {.importc, cdecl.}
proc dingbat_clip_tick(): cint {.importc, cdecl.}
proc dingbat_clip_scrub_generate(n: cint): cint {.importc, cdecl.}
proc dingbat_rollback_init(rom0, rom1: cstring; local: cint; epoch: cdouble): cint {.importc, cdecl.}
proc dingbat_rollback_load_state(player: cint; data: pointer; len: cint): cint {.importc, cdecl.}
proc dingbat_rollback_tick(bits: cint): cint {.importc, cdecl.}
proc dingbat_rollback_feed(frame, bits: cint) {.importc, cdecl.}
proc dingbat_rollback_active(): cint {.importc, cdecl.}
proc dingbat_rollback_exit_to_single(): cint {.importc, cdecl.}
proc dingbat_link_init(rom0, rom1: cstring): cint {.importc, cdecl.}
proc dingbat_link_tick() {.importc, cdecl.}
proc dingbat_link_fb(player: cint): ptr uint16 {.importc, cdecl.}
proc dingbat_link_input(player, id, pressed: cint) {.importc, cdecl.}
proc dingbat_link_active(): cint {.importc, cdecl.}
proc dingbat_link_exit() {.importc, cdecl.}

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
  check dingbat_load_rom(cstring(staged("tests/roms/gbaedge.gba")), nil) == 0, "loads"
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

echo "GBA: frames nobody sees are not drawn, and run the same"
block:
  # Three in four frames marked unseen (docs/frame-skip.md), as a tick that
  # runs four shows one: the shown frames and the machine must be those of
  # 60 frames all drawn.
  let s = takeState()
  var shown: seq[uint64] = @[]
  for f in 0 ..< 60:
    dingbat_set_input(4, cint((f div 7) mod 2))
    dingbat_run_frame()
    if f mod 4 == 3: shown.add frameHash()
  let plain = takeState()
  check applyState(s), "back to the start"
  var same = true
  for f in 0 ..< 60:
    dingbat_set_input(4, cint((f div 7) mod 2))
    if f mod 4 != 3: dingbat_unseen_next()
    dingbat_run_frame()
    if f mod 4 == 3 and frameHash() != shown[f div 4]: same = false
  dingbat_set_input(4, 0)
  check same, "every shown frame matches"
  check takeState() == plain, "the same machine after 60 frames"
  check applyState(s), "back to the start"
  for f in 0 ..< 60:
    dingbat_set_input(4, cint((f div 7) mod 2))
    if f mod 4 != 3: dingbat_unseen_next()
    dingbat_run_frame_ahead(2)
  dingbat_set_input(4, 0)
  check takeState() == plain, "with run-ahead 2 too (lookahead skipped when unseen)"

echo "GBA: a clip replays the frames the player saw"
block:
  # 3 s of play with inputs changing, every frame's picture hashed.
  var seen: seq[uint64] = @[]
  for f in 0 ..< 180:
    dingbat_set_input(4, cint((f div 7) mod 2))
    dingbat_set_input(3, cint((f div 23) mod 2))
    dingbat_run_frame()
    seen.add frameHash()
  dingbat_set_input(4, 0); dingbat_set_input(3, 0)
  let live = takeState()
  # The frames 150..90 frames back: seen[30 ..< 90].
  let n = dingbat_clip_begin(150, 90)
  check n == 60, "the replay runs the 60 frames asked for (got " & $n & ")"
  var same = true
  for i in 0 ..< int(n):
    if dingbat_clip_tick() < 0: same = false; break
    if frameHash() != seen[30 + i]: same = false
  check same, "every replayed frame matches what was seen"
  check dingbat_clip_tick() == -1, "the replay ends"
  check takeState() == live, "the live game is back, untouched"
  check dingbat_clip_scrub_generate(16) >= 3, "the clip strip has a thumbnail per second"

echo "GBA: cheats"
block:
  check $dingbat_load_cheats("[x] Good\n82000000 0001\n\n") == "", "a valid code parses"
  check ($dingbat_load_cheats("[x] Bad\nnot a code\n\n")).startsWith("Bad:"), "a bad code is named"
  check $dingbat_load_cheats("") == "", "clearing"

echo "GBA: online link rollback"
block:
  # Two sessions from the same states: one hears the friend at once, one
  # 6 frames late (predicting, then rolling back). They must end identical.
  let rom = staged("tests/roms/gbaedge.gba")
  let friendRom = tmp / "friend.gba"
  copyFile(rom, friendRom)
  check dingbat_load_rom(cstring(rom), nil) == 0, "loads"
  for _ in 0 ..< 120: dingbat_run_frame()
  let mine = takeState()
  for _ in 0 ..< 30: dingbat_run_frame()
  let theirs = takeState()
  proc lb(f: int): cint = cint(if (f div 9) mod 2 == 0: 1 shl 4 else: 1 shl 3)
  proc rb(f: int): cint = cint(if (f div 5) mod 3 == 0: 1 shl 7 else: 1 shl 2)
  proc run(delay: int): string =
    doAssert dingbat_rollback_init(cstring(rom), cstring(friendRom), 0, 1_700_000_000) == 1
    doAssert dingbat_rollback_load_state(0, unsafeAddr mine[0], cint(mine.len)) == 1
    doAssert dingbat_rollback_load_state(1, unsafeAddr theirs[0], cint(theirs.len)) == 1
    var f = 0
    var fed = 0
    while f < 240:
      while fed <= f - delay:
        dingbat_rollback_feed(cint(fed), rb(fed)); inc fed
      let got = dingbat_rollback_tick(lb(f))
      doAssert got == cint(f), "tick " & $f & " gave " & $got
      inc f
    while fed < 240:
      dingbat_rollback_feed(cint(fed), rb(fed)); inc fed
    result = takeState()
  let direct = run(0)
  check dingbat_rollback_active() == 1, "a session runs"
  dingbat_run_frame()
  check takeState() == direct, "solo frames refuse while linked"
  check not applyState(mine), "states refuse while linked"
  let late = run(6)
  check late == direct, "6 frames of prediction + rollback = the inputs on time"
  check dingbat_rollback_exit_to_single() == 1 and dingbat_rollback_active() == 0, "back to solo"
  dingbat_run_frame()
  check takeState() != late, "the kept core plays on"
  check dingbat_rollback_init(cstring(rom), cstring(friendRom), 1, 1) == 1, "a second session"
  check dingbat_load_rom(cstring(rom), nil) == 0 and dingbat_rollback_active() == 0,
    "loading a game ends a session"

echo "Local 2P link"
block:
  proc fbHash(p: cint; n: int): uint64 =
    let fb = cast[ptr UncheckedArray[uint16]](dingbat_link_fb(p))
    result = 1469598103934665603'u64
    for i in 0 ..< n: result = (result xor uint64(fb[i])) * 1099511628211'u64
  let one = staged("tests/roms/linktest.gba")
  let two = tmp / "linktest-p2.gba"
  copyFile(one, two)
  check dingbat_link_init(cstring(one), cstring(two)) == 1 and dingbat_link_active() == 1, "two cores linked"
  for _ in 0 ..< 240: dingbat_link_tick()
  check dingbat_game_fb() != nil and dingbat_link_fb(1) != nil, "both pictures"
  let before = takeState()
  dingbat_run_frame()
  check takeState() == before, "solo frames refuse while linked"
  dingbat_link_input(1, 7, 1)
  for _ in 0 ..< 10: dingbat_link_tick()
  dingbat_link_input(1, 7, 0)
  for _ in 0 ..< 60: dingbat_link_tick()
  dingbat_link_exit()
  check dingbat_link_active() == 0 and dingbat_loaded() == 0, "exit leaves nothing loaded"
  let g1 = staged("tests/roms/gblinktest.gb")
  let g2 = tmp / "gblinktest-p2.gb"
  copyFile(g1, g2)
  check dingbat_link_init(cstring(g1), cstring(g2)) == 1 and dingbat_is_gb() == 1, "a GB pair"
  for _ in 0 ..< 240: dingbat_link_tick()
  check fbHash(0, 160 * 144) != 0'u64, "GB frames run"
  check dingbat_load_rom(cstring(g1), nil) == 0 and dingbat_link_active() == 0, "loading a game ends the pair"

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
  dingbat_unload(1)
  check dingbat_loaded() == 0 and dingbat_game_fb() == nil, "unload drops the core"

if failures > 0:
  echo failures, " failure(s)"
  quit 1
echo "all passed"
