## The iOS app's C API (src/dingbat_ios.nim), driven the way the Swift shell
## drives it: through the exported C symbols, on committed ROMs. Covers load,
## frames, state round trips and refusals, hold-to-rewind, the rewind
## scrubber's commit, clip replay, run-ahead, cheats, the LCD response and the Super Game
## Boy border; and DS games on the DS test ROMs, where they are built
## (~/.cache/dingbat-nds/roms): both screens, the stylus, X/Y, the lid, the
## battery and flash files, power-off, states, sound, the switch between
## cores, and the frame time of a commercial game when one is at hand.
## Run standalone: nimble test_iosapi   (or ./dingbat_ios_api_test)
##
## Built with -d:test_harness like every test, so the GB/GBA APUs skip the
## SDL queue the iOS audio ring stands in for. The DS's sound is queued by
## dingbat_ios.nim itself, so its part of the ring is covered.

import std/[os, strutils, monotimes, times]
import dingbat_ios
import dingbat/nds/nds except Input
import dingbat/nds/io/input as nds_input

proc dingbat_load_rom(rom, bios: cstring): cint {.importc, cdecl.}
proc dingbat_unload(flush: cint) {.importc, cdecl.}
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
proc dingbat_rewind_scrub_thumb_h(): cint {.importc, cdecl.}
proc dingbat_rewind_scrub_state_size(s: cint): cint {.importc, cdecl.}
proc dingbat_rewind_scrub_save_differs(s: cint): cint {.importc, cdecl.}
proc dingbat_load_cheats(text: cstring): cstring {.importc, cdecl.}
proc dingbat_set_input(id, pressed: cint) {.importc, cdecl.}
proc dingbat_clip_begin(startAgo, endAgo: cint): cint {.importc, cdecl.}
proc dingbat_clip_tick(): cint {.importc, cdecl.}
proc dingbat_clip_scrub_generate(n: cint): cint {.importc, cdecl.}
proc dingbat_clip_abort() {.importc, cdecl.}
proc dingbat_set_turbo(on: cint) {.importc, cdecl.}
proc dingbat_set_volume(volume, mute: cint) {.importc, cdecl.}
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

echo "GBA: a clip replays at 1x whatever the player's speed"
block:
  # 2x halves the samples a frame and is not in a state: a replay that kept
  # it gave a clip half the sound of its pictures. ClipExporter sets the
  # volume (apply_audio) after clip_begin, so that must not bring 2x back.
  dingbat_set_turbo(1)
  for _ in 0 ..< 120: dingbat_run_frame()
  check core_turbo(), "2x is on the live core"
  var n = dingbat_clip_begin(90, 0)
  check n > 0 and not core_turbo(), "the replay runs at 1x"
  dingbat_set_volume(100, 0)
  check not core_turbo(), "and stays at 1x when the exporter sets its volume"
  for _ in 0 ..< int(n): discard dingbat_clip_tick()
  check dingbat_clip_tick() == -1 and core_turbo(), "2x is back once it ends"
  dingbat_set_turbo(0)
  n = dingbat_clip_begin(90, 0)
  dingbat_set_turbo(1)
  check n > 0 and not core_turbo(), "2x picked during a replay waits for its end"
  dingbat_clip_abort()
  check core_turbo(), "a cancelled replay leaves the speed picked during it"
  dingbat_set_turbo(0)

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

# --- Nintendo DS ---
# Homebrew test ROMs from ~/.cache/dingbat-nds/roms (built by
# tests/nds/tools; never in the repo), copied into a temp dir so the battery
# and flash files land there. Skipped where they are missing (CI).

proc dingbat_is_nds(): cint {.importc, cdecl.}
proc dingbat_set_nds_bios(b9, b7, fw: cstring) {.importc, cdecl.}
proc dingbat_set_nds_flash_path(path: cstring) {.importc, cdecl.}
proc dingbat_nds_touch(x, y, down: cint) {.importc, cdecl.}
proc dingbat_nds_set_lid(closed: cint) {.importc, cdecl.}
proc dingbat_nds_push_mic(samples: ptr int16; n, rate: cint) {.importc, cdecl.}
proc dingbat_nds_powered_off(): cint {.importc, cdecl.}
proc dingbat_nds_top_rgba(): ptr uint32 {.importc, cdecl.}
proc dingbat_framebuffer_rgba(): ptr uint32 {.importc, cdecl.}
proc dingbat_glow_sample(gw, gh, remap: cint; p0, p1, p2, p3: uint32): ptr uint32 {.importc, cdecl.}
proc dingbat_out_height(): cint {.importc, cdecl.}
proc dingbat_flush_save() {.importc, cdecl.}
proc dingbat_is_stopped(): cint {.importc, cdecl.}
proc dingbat_rumble(): cint {.importc, cdecl.}
proc dingbat_set_fast_forward(on: cint) {.importc, cdecl.}
proc dingbat_set_channel_mutes(bits: cint) {.importc, cdecl.}
proc dingbat_audio_ahead(): cint {.importc, cdecl.}
proc dingbat_audio_read(dst: ptr float32; max: cint): cint {.importc, cdecl.}
proc dingbat_audio_set_free(on: cint) {.importc, cdecl.}
proc dingbat_audio_clear() {.importc, cdecl.}
proc dingbat_audio_sample_rate(): cint {.importc, cdecl.}
proc dingbat_clip_history_frames(): cint {.importc, cdecl.}
proc dingbat_frame_static(): cint {.importc, cdecl.}

let ndsRoms = getEnv("DINGBAT_NDS_ROMS", getHomeDir() / ".cache/dingbat-nds/roms")
let ndsTmp = tmp / "nds"
createDir(ndsTmp)

proc ndsStaged(name: string; save = ""): string =
  ## A copy of test ROM `name` in the temp dir, its battery file removed (or
  ## `save` written as it).
  result = ndsTmp / name.extractFilename
  copyFile(ndsRoms / name, result)
  removeFile(result.changeFileExt("sav"))
  if save.len > 0: writeFile(result.changeFileExt("sav"), save)

proc ndsHave(names: varargs[string]): bool =
  for n in names:
    if not fileExists(ndsRoms / n):
      echo "  skip (no ", ndsRoms / n, ")"
      return false
  true

proc ndsFrames(): int = ios_nds_core().gpu.frame_count

proc px(x, y: int): uint16 =
  ## The composite's BGR555 pixel (top screen rows 0..191, bottom 192..383).
  cast[ptr UncheckedArray[uint16]](dingbat_game_fb())[y * 256 + x] and 0x7FFF

proc bottomRows(n: int): seq[uint16] =
  let fb = cast[ptr UncheckedArray[uint16]](dingbat_game_fb())
  for i in 0 ..< 256 * n: result.add fb[192 * 256 + i]

proc utf16(s: string): string =
  for c in s: result.add c & '\0'

echo "DS: boot, both screens in one picture"
if ndsHave("fb_both.nds"):
  dingbat_set_fast_forward(1)   # nothing drains the audio ring here
  let rom = ndsStaged("fb_both.nds")
  check dingbat_load_rom(cstring(rom), nil) == 0, "loads"
  check dingbat_is_nds() == 1 and dingbat_is_gb() == 0 and dingbat_loaded() == 1, "a DS core runs"
  check dingbat_fb_width() == 256 and dingbat_fb_height() == 384 and
        dingbat_out_width() == 256 and dingbat_out_height() == 384, "256x384 out"
  let f0 = ndsFrames()
  for _ in 0 ..< 10: dingbat_run_frame()
  check ndsFrames() == f0 + 10, "ten frames ran"
  check dingbat_game_fb() == dingbat_framebuffer(), "the picture is the composite"
  # fb_both: top = a gradient from blue (left) to red (right), bottom =
  # solid magenta 0x7C1F.
  let tl = px(1, 1)
  let tr = px(254, 1)
  check (tl shr 10) > 24 and (tl and 0x1F) < 6, "top screen's top left is blue: " & tl.toHex
  check (tr and 0x1F) > 24 and (tr shr 10) < 6, "top screen's top right is red: " & tr.toHex
  check px(128, 192) == 0x7C1F and px(255, 383) == 0x7C1F, "rows 192..383 are the bottom screen"
  let rgba = cast[ptr UncheckedArray[uint32]](dingbat_framebuffer_rgba())
  let top = cast[ptr UncheckedArray[uint32]](dingbat_nds_top_rgba())
  var same = true
  for i in 0 ..< 256 * 192:
    if rgba[i] != top[i]: same = false
  check same and rgba[200 * 256] == 0xFFFF00FF'u32, "RGBA: the composite, and the top screen alone"
  let glow = cast[ptr UncheckedArray[uint32]](dingbat_glow_sample(4, 8, 0, 0, 0, 0, 0))
  check glow != nil and glow[7 * 4] == 0xFFFF00FF'u32, "the glow samples the composite"
  check dingbat_frame_static() == 0, "frame_static: always 0 on the DS"

echo "DS: HD 3D"
proc dingbat_nds_set_hd(k: cint) {.importc, cdecl.}
proc dingbat_nds_hd_scale(): cint {.importc, cdecl.}
proc dingbat_nds_hd_fb(): ptr uint16 {.importc, cdecl.}
proc dingbat_nds_hd_fb_width(): cint {.importc, cdecl.}
proc dingbat_nds_hd_fb_height(): cint {.importc, cdecl.}

proc hdAsUpscale(k: int): tuple[same, differs: int] =
  ## The HD picture against the 1x one scaled up k x (nearest): how many
  ## HD pixels match and how many do not.
  let lo = cast[ptr UncheckedArray[uint16]](dingbat_game_fb())
  let hd = cast[ptr UncheckedArray[uint16]](dingbat_nds_hd_fb())
  let w = 256 * k
  for y in 0 ..< 384 * k:
    for x in 0 ..< w:
      if (hd[y * w + x] and 0x7FFF) == (lo[(y div k) * 256 + x div k] and 0x7FFF): inc result.same
      else: inc result.differs

if ndsHave("fb_both.nds"):
  check dingbat_load_rom(cstring(ndsStaged("fb_both.nds")), nil) == 0, "loads"
  for _ in 0 ..< 10: dingbat_run_frame()
  check dingbat_nds_hd_scale() == 1 and dingbat_nds_hd_fb() == nil and
        dingbat_nds_hd_fb_width() == 0, "HD off by default: no HD picture"
  let lo = frameHash()
  dingbat_nds_set_hd(2)
  check dingbat_nds_hd_scale() == 2 and dingbat_nds_hd_fb() != nil and
        dingbat_nds_hd_fb_width() == 512 and dingbat_nds_hd_fb_height() == 768,
        "2x: a 512x768 HD picture at once"
  check hdAsUpscale(2).differs == 0, "until a frame runs, the 1x picture scaled up"
  for _ in 0 ..< 5: dingbat_run_frame()
  check dingbat_fb_width() == 256 and dingbat_fb_height() == 384 and frameHash() == lo,
        "the 1x picture is unchanged"
  check hdAsUpscale(2).differs == 0, "no 3D: every 2x2 block is the 1x pixel"
  let s = takeState()
  for _ in 0 ..< 5: dingbat_run_frame()
  check applyState(s) and dingbat_nds_hd_scale() == 2 and hdAsUpscale(2).differs == 0,
        "a state load keeps HD"
  check dingbat_reset() == 0 and dingbat_nds_hd_scale() == 2, "a reset keeps HD"
  for _ in 0 ..< 5: dingbat_run_frame()
  check dingbat_nds_hd_fb_width() == 512 and hdAsUpscale(2).differs == 0, "and draws it"
  dingbat_nds_set_hd(1)
  check dingbat_nds_hd_scale() == 1 and dingbat_nds_hd_fb() == nil and
        dingbat_fb_width() == 256 and dingbat_fb_height() == 384, "1: back to 256x384 alone"

if ndsHave("built/Simple_Quad.nds"):
  let rom = ndsStaged("built/Simple_Quad.nds")
  check dingbat_load_rom(cstring(rom), nil) == 0, "a 3D game loads"
  for _ in 0 ..< 60: dingbat_run_frame()
  let plain = frameHash()
  dingbat_nds_set_hd(3)
  check dingbat_load_rom(cstring(rom), nil) == 0 and dingbat_nds_hd_scale() == 3,
        "a scale set before a load is the next game's"
  for _ in 0 ..< 60: dingbat_run_frame()
  check frameHash() == plain, "the 1x picture is the one HD off draws"
  let up = hdAsUpscale(3)
  check dingbat_nds_hd_fb_width() == 768 and up.differs > 0 and up.same > up.differs,
        "3x: the 3D drawn sharper than the 1x scaled up: " & $up.differs & " of " & $(up.same + up.differs)
  dingbat_set_rewind(1, 0)
  for _ in 0 ..< 120: dingbat_run_frame()
  check dingbat_rewind_pop() == 1 and dingbat_nds_hd_scale() == 3 and
        dingbat_nds_hd_fb_width() == 768, "a rewind keeps HD"
  dingbat_run_frame()
  check hdAsUpscale(3).differs > 0, "and draws 3D in HD again"
  dingbat_nds_set_hd(1)
  check dingbat_nds_hd_fb() == nil, "off"

echo "DS: things the DS core lacks refuse cleanly"
if ndsHave("fb_both.nds"):
  let rom = ndsStaged("fb_both.nds")
  check dingbat_load_rom(cstring(rom), nil) == 0, "loads"
  dingbat_set_rewind(1, 0)
  let f0 = ndsFrames()
  for _ in 0 ..< 200: dingbat_run_frame_ahead(2)
  check ndsFrames() == f0 + 200, "run-ahead runs plain frames"
  check dingbat_clip_history_frames() == 0 and dingbat_clip_begin(60, 0) == 0 and
        dingbat_clip_tick() == -1, "no clips"
  check $dingbat_load_cheats("[x] Good\n82000000 0001\n\n") == "", "cheats: nothing to load into"
  check dingbat_sgb_border() == 0 and dingbat_rumble() == 0, "no SGB, no rumble"
  dingbat_set_channel_mutes(0x3F); dingbat_set_lcd_response(1)
  dingbat_run_frame()
  check dingbat_game_fb() == dingbat_framebuffer(), "LCD response leaves the DS picture alone"
  dingbat_set_channel_mutes(0); dingbat_set_lcd_response(0)
  check dingbat_rollback_init(cstring(rom), cstring(rom), 0, 1) == 0 and
        dingbat_link_init(cstring(rom), cstring(rom)) == 0, "link refuses a DS game"
  check dingbat_is_nds() == 1 and dingbat_rollback_active() == 0 and dingbat_link_active() == 0,
        "and leaves it running"
  dingbat_run_frame()
  check ndsFrames() == f0 + 202, "frames still run"
  let s = takeState()
  check s.startsWith("DGBSTATE"), "a DS state"
  let stamp = frameHash()
  check dingbat_reset() == 0 and dingbat_is_nds() == 1 and ndsFrames() == 0, "reset reboots in place"
  check applyState(s) and frameHash() == stamp, "the state loads after the reset"
  var junk = "not a state at all"
  check not applyState(junk) and dingbat_state_error_kind() == 1, "junk refused as not a state"

echo "DS: hold-to-rewind, the scrubber and Report a Bug's timeline"
if ndsHave("fb_both.nds"):
  dingbat_set_rewind(1, 0)
  check dingbat_load_rom(cstring(ndsStaged("fb_both.nds")), nil) == 0, "loads"
  for _ in 0 ..< 300: dingbat_run_frame()
  let f1 = ndsFrames()
  check dingbat_rewind_pop() == 1 and dingbat_rewind_pop() == 1 and ndsFrames() < f1,
        "rewind pops snapshots: an earlier frame"
  let n = dingbat_rewind_scrub_generate(16)
  check n > 1 and dingbat_rewind_scrub_thumb_w() == 80 and dingbat_rewind_scrub_thumb_h() == 120,
        "a strip of 80x120 thumbs (both screens): " & $n
  let oldest = n - 1
  check dingbat_rewind_scrub_seconds_ago(oldest) > 0, "the oldest sample is in the past"
  let live = takeState()
  let at = ndsFrames()
  let size = dingbat_rewind_scrub_state_size(oldest)
  var old = newString(size)
  if size > 0: copyMem(addr old[0], dingbat_state_data(), size)
  check old.startsWith("DGBSTATE") and ndsFrames() == at, "a sample's state, the live core put back"
  check dingbat_rewind_scrub_save_differs(oldest) == 0 and ndsFrames() == at,
        "the save chip is unchanged across it"
  check dingbat_rewind_commit(oldest) == 1 and ndsFrames() < at - 100, "commit to the oldest moment"
  let back = frameHash()
  check dingbat_rewind_scrub_generate(16) <= 2, "commit drops the newer history"
  check applyState(live, keep = true) and ndsFrames() == at, "undo: the state from before"
  check applyState(old) and frameHash() == back, "the sample's state is that moment"
  dingbat_set_rewind(0, 0)
  for _ in 0 ..< 20: dingbat_run_frame()
  check dingbat_rewind_pop() == 0 and dingbat_rewind_scrub_generate(16) == 0, "rewind off: no ring"
  dingbat_set_rewind(1, 0)

echo "DS: the stylus, X and Y, the lid"
if ndsHave("built/touch_test.nds"):
  check dingbat_load_rom(cstring(ndsStaged("built/touch_test.nds")), nil) == 0, "loads"
  let core = ios_nds_core()
  for _ in 0 ..< 120: dingbat_run_frame()
  # touch_test prints the touch position on the bottom screen's console
  # (its first rows, before the console scrolls).
  proc settle() = (for _ in 0 ..< 8: dingbat_run_frame())
  dingbat_nds_touch(100, 80, 1); settle()
  let at = bottomRows(9)
  check core.input.touching and core.input.touch_x == 100 and core.input.touch_y == 80,
        "a touch reaches the core"
  dingbat_nds_touch(0, 0, 0); settle()
  dingbat_nds_touch(30, 150, 1); settle()
  let elsewhere = bottomRows(9)
  check at != elsewhere, "the game reads the point: its readout moves"
  dingbat_nds_touch(0, 0, 0)
  dingbat_set_input(10, 1)
  check (core.input.extkeyin() and 1) == 0, "X reaches EXTKEYIN"
  dingbat_set_input(11, 1)
  check (core.input.extkeyin() and 2) == 0, "Y reaches EXTKEYIN"
  dingbat_set_input(10, 0); dingbat_set_input(11, 0)
  check (core.input.extkeyin() and 3) == 3, "and let go"
  dingbat_set_input(4, 1)
  check (core.input.keyinput() and 1) == 0, "A reaches KEYINPUT"
  dingbat_set_input(4, 0)
  let open = takeState()
  dingbat_nds_set_lid(1)
  check core.input.lid_closed, "the lid closes"
  dingbat_nds_touch(50, 50, 1)
  check not core.input.touching, "no touch lands on a closed console"
  check applyState(open) and ios_nds_core().input.lid_closed, "a state load keeps the lid shut"
  dingbat_nds_set_lid(0)
  check not ios_nds_core().input.lid_closed, "and it opens"
  var hum = newSeq[int16](1600)
  for i in 0 ..< hum.len: hum[i] = int16((i mod 40) * 800 - 16000)
  dingbat_nds_push_mic(addr hum[0], cint(hum.len), 16000)
  dingbat_run_frame()
  check dingbat_is_nds() == 1, "microphone samples go in"

echo "DS: the battery save comes back"
if ndsHave("save_write.nds"):
  # save_write counts its boots in a 0.5K EEPROM ("DGB" + count).
  let rom = ndsStaged("save_write.nds", save = '\xFF'.repeat(512))
  let sav = rom.changeFileExt("sav")
  check dingbat_load_rom(cstring(rom), nil) == 0, "loads"
  for _ in 0 ..< 30: dingbat_run_frame()
  dingbat_flush_save()
  check readFile(sav).len == 512 and readFile(sav)[0 .. 3] == "DGB\x01", "the first boot's write is on disk"
  dingbat_unload(1)
  check dingbat_loaded() == 0 and dingbat_is_nds() == 0 and dingbat_game_fb() == nil, "unloaded"
  check dingbat_load_rom(cstring(rom), nil) == 0, "loads again"
  for _ in 0 ..< 30: dingbat_run_frame()
  dingbat_unload(1)
  check readFile(sav)[0 .. 3] == "DGB\x02", "the second boot read it and counted on"

echo "DS: the firmware flash and power-off"
if ndsHave("fw_power.nds"):
  # fw_power writes the nickname FWTEST<n> each boot (n = one more than the
  # flash it booted on said) and switches the DS off on START.
  let flash = ndsTmp / "flash.bin"
  removeFile(flash)
  dingbat_set_nds_flash_path(cstring(flash))
  let rom = ndsStaged("fw_power.nds")
  check dingbat_load_rom(cstring(rom), nil) == 0, "loads"
  for _ in 0 ..< 30: dingbat_run_frame()
  dingbat_flush_save()
  check fileExists(flash) and utf16("FWTEST1") in readFile(flash), "the flash it wrote is kept"
  check readFile(flash).endsWith("built-in\x08\x00\x00\x00DGBNDSFW"), "with its base"
  dingbat_set_input(7, 1)
  for _ in 0 ..< 10: dingbat_run_frame()
  dingbat_set_input(7, 0)
  check dingbat_nds_powered_off() == 1, "START switches it off"
  check dingbat_state_size() == 0, "no state of a console that is off"
  check px(10, 10) == 0 and px(10, 300) == 0, "both screens black"
  check dingbat_reset() == 0 and dingbat_nds_powered_off() == 0, "reset switches it on"
  for _ in 0 ..< 30: dingbat_run_frame()
  dingbat_unload(1)
  check utf16("FWTEST2") in readFile(flash), "a reset keeps the flash: the second boot counted on"
  check dingbat_load_rom(cstring(rom), nil) == 0, "loads again"
  for _ in 0 ..< 30: dingbat_run_frame()
  dingbat_flush_save()
  check utf16("FWTEST3") in readFile(flash), "the next load boots on the kept flash"
  # A firmware dump is another base: the record written on the built-in
  # firmware does not apply to it. (The dump here is this build's own
  # synthesized image, no console's.)
  let dump = ndsTmp / "firmware.bin"
  writeFile(dump, cast[string](synth_firmware()))
  dingbat_set_nds_bios(nil, nil, cstring(dump))
  check dingbat_load_rom(cstring(rom), nil) == 0, "loads on the dump"
  for _ in 0 ..< 30: dingbat_run_frame()
  dingbat_flush_save()
  let rec = readFile(flash)
  check utf16("FWTEST1") in rec and not rec.endsWith("built-in\x08\x00\x00\x00DGBNDSFW"),
        "a dump starts from its own settings, kept under its own base"
  dingbat_set_nds_bios(nil, nil, nil)
  dingbat_unload(1)
  dingbat_set_nds_flash_path(nil)

echo "DS: sound into the ring at the DS's rate"
if ndsHave("snd_tone.nds"):
  check dingbat_load_rom(cstring(ndsStaged("snd_tone.nds")), nil) == 0, "loads"
  check dingbat_audio_sample_rate() == 32728, "the ring runs at the DS's rate: " &
        $dingbat_audio_sample_rate()
  for _ in 0 ..< 20: dingbat_run_frame()
  dingbat_set_fast_forward(0)
  dingbat_audio_set_free(1)   # plain pops: count what arrives
  dingbat_audio_clear()
  var buf = newSeq[float32](2 * 8192)
  proc drain(): (int, float32, float32) =
    var n, got = 0
    var l, r = 0'f32
    while (got = int(dingbat_audio_read(addr buf[0], 8192)); got > 0):
      for i in 0 ..< got:
        l = max(l, abs(buf[2 * i])); r = max(r, abs(buf[2 * i + 1]))
      n += got
    (n, l, r)
  var total = 0
  var peakL, peakR = 0'f32
  for _ in 0 ..< 60:
    dingbat_run_frame()
    let (n, l, r) = drain()
    total += n; peakL = max(peakL, l); peakR = max(peakR, r)
  # 60 frames of 1120380 master cycles, a sample every 2048: 60 x 547.06.
  check total >= 60 * 546 and total <= 60 * 548, "a frame's worth of samples a frame: " & $total
  check peakL > 0.01 and peakR > 0.01, "both channels sound"
  check dingbat_audio_ahead() == 0, "drained: not ahead"
  dingbat_run_frame()
  check dingbat_audio_ahead() == 1, "a frame queued: ahead (the pacing contract)"
  discard drain()
  dingbat_set_turbo(1)
  for _ in 0 ..< 4: dingbat_run_frame(); discard drain()
  total = 0
  for _ in 0 ..< 20:
    dingbat_run_frame()
    total += drain()[0]
  check abs(total - 20 * 547 div 2) <= 2, "2x: half the samples: " & $total
  dingbat_set_turbo(0)
  dingbat_set_volume(0, 0)
  dingbat_run_frame()
  let (n, l, _) = drain()
  check n > 500 and l == 0, "volume 0: silence, still paced"
  dingbat_set_volume(100, 0)
  dingbat_nds_set_lid(1)   # snd_tone does not sleep; a sleeping DS pads silence
  dingbat_nds_set_lid(0)
  dingbat_set_fast_forward(1)
  dingbat_audio_set_free(0)

echo "DS -> GBA -> DS"
if ndsHave("fb_both.nds"):
  let ds = ndsStaged("fb_both.nds")
  check dingbat_load_rom(cstring(ds), nil) == 0 and dingbat_is_nds() == 1, "a DS game"
  for _ in 0 ..< 5: dingbat_run_frame()
  check dingbat_load_rom(cstring(staged("tests/roms/gbaedge.gba")), nil) == 0, "a GBA game"
  check dingbat_is_nds() == 0 and ios_nds_core() == nil and dingbat_fb_width() == 240 and
        dingbat_fb_height() == 160, "the DS core is gone"
  for _ in 0 ..< 30: dingbat_run_frame()
  dingbat_set_input(10, 1); dingbat_set_input(11, 1)   # DS-only ids: ignored
  dingbat_run_frame()
  check dingbat_nds_top_rgba() == nil and dingbat_nds_powered_off() == 0, "DS calls are no-ops"
  dingbat_nds_touch(10, 10, 1); dingbat_nds_set_lid(1); dingbat_nds_set_lid(0)
  check dingbat_load_rom(cstring(ds), nil) == 0 and dingbat_is_nds() == 1 and
        dingbat_fb_height() == 384, "and a DS game again"
  for _ in 0 ..< 5: dingbat_run_frame()
  check px(128, 300) == 0x7C1F, "drawing"
  let gbaState = block:
    discard dingbat_load_rom(cstring(staged("tests/roms/gbaedge.gba")), nil)
    takeState()
  discard dingbat_load_rom(cstring(ds), nil)
  check not applyState(gbaState) and dingbat_state_error_kind() == 2, "a GBA state is the wrong core"
  dingbat_unload(1)

echo "DS: the real BIOS"
let biosDir = getEnv("DINGBAT_NDS_BIOS", getHomeDir() / "Documents/emu/nds/NDS Bios & Firmware")
if ndsHave("fb_both.nds") and fileExists(biosDir / "bios9.bin") and fileExists(biosDir / "bios7.bin"):
  dingbat_set_nds_bios(cstring(biosDir / "bios9.bin"), cstring(biosDir / "bios7.bin"), nil)
  check dingbat_load_rom(cstring(ndsStaged("fb_both.nds")), nil) == 0, "loads on the dumps"
  check not ios_nds_core().hle_bios9 and not ios_nds_core().hle_bios7, "the real BIOS"
  for _ in 0 ..< 10: dingbat_run_frame()
  check px(128, 300) == 0x7C1F, "drawing"
  dingbat_set_nds_bios(nil, nil, nil)
  dingbat_unload(1)
else:
  echo "  skip (no BIOS dumps)"

echo "DS: frame time"
block:
  let ss = getEnv("DINGBAT_NDS_BENCH_ROM", getHomeDir() / "Documents/emu/nds/PokemonSoulSilver.nds")
  if not fileExists(ss):
    echo "  skip (no ", ss, ")"
  else:
    # A link in the temp dir, so the battery file would land there.
    let link = ndsTmp / "bench.nds"
    removeFile(link)
    createSymlink(ss, link)
    removeFile(link.changeFileExt("sav"))
    check dingbat_load_rom(cstring(link), nil) == 0, "loads " & ss.extractFilename
    for _ in 0 ..< 600: dingbat_run_frame()
    let t0 = getMonoTime()
    for _ in 0 ..< 900: dingbat_run_frame()
    let ms = float((getMonoTime() - t0).inMicroseconds) / 1000.0 / 900.0
    echo "  note ", ss.extractFilename, " frames 600..1500 (intro, HLE BIOS): ",
         formatFloat(ms, ffDecimal, 2), " ms/frame (", formatFloat(1000.0 / ms, ffDecimal, 0), " fps)"
    dingbat_unload(0)
    removeFile(link)

if failures > 0:
  echo failures, " failure(s)"
  quit 1
echo "all passed"
