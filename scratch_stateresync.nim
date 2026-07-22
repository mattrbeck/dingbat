# Save/load-state resync test for the MP2K HLE shadow mixer (see mp2k.nim).
# Build:  nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc \
#           -o:scratch_stateresync --path:src scratch_stateresync.nim
# Run:    ./scratch_stateresync ~/Downloads/PokemonEmeraldShiny1.gba \
#           ~/Downloads/PokemonEmeraldShiny1.state [tests/roms/attachtest.gba]
#
# Verifies that a state load mid-run resets + resyncs the HLE shadow state:
#   A) save to memory, keep running, load back: engaged stays true, no crash,
#      and the 10 post-load frames have no absurd transient vs the 10 frames
#      before the save (mid-note channels resume at the engine position with a
#      one-frame fade-in; they must NOT retrigger at full scale).
#   B) HLE toggled OFF before the load and back ON after: re-engages cleanly.
#   C) load on a non-MP2K ROM where the HLE never engaged: no crash, stays
#      disengaged.
import std/[os, strutils, math]
import dingbat/gba/gba
import dingbat/common/test_output

var failures = 0

proc check(cond: bool; what: string) =
  if cond:
    echo "  ok   ", what
  else:
    echo "  FAIL ", what
    failures.inc

proc peak(a, b: int): int =
  ## Peak |sample| in mp2kWavCapture[a ..< b].
  for i in a ..< min(b, mp2kWavCapture.len):
    result = max(result, abs(int(mp2kWavCapture[i])))

proc make(rom: string): GBA =
  result = new_gba("", rom, run_bios = false, use_hle = true)
  result.test_output = new_test_output()
  result.post_init()

proc test_a(rom, state: string) =
  echo "A) mid-run save -> run -> load, HLE on throughout"
  mp2kWavCapture.setLen(0)
  let emu = make(rom)
  doAssert emu.load_state(state), "initial .state load failed"
  emu.mp2k_hle = true
  for _ in 0 ..< 50: emu.step_frame()
  let pre10 = mp2kWavCapture.len          # start of the 10 frames before save
  for _ in 0 ..< 10: emu.step_frame()
  let save_idx = mp2kWavCapture.len
  let saved = emu.state_bytes()
  for _ in 0 ..< 30: emu.step_frame()
  check(emu.load_state_bytes(saved), "load_state_bytes succeeds")
  check(emu.mp2k.engaged, "engaged stays true across load")
  check(emu.mp2k.resync_pending, "resync_pending set by load")
  var active_after_load = 0
  for s in emu.mp2k.samplers:
    if s.active: active_after_load.inc
  check(active_after_load == 0, "all sampler channels deactivated by load")
  let post0 = mp2kWavCapture.len
  for _ in 0 ..< 10: emu.step_frame()
  let post10 = mp2kWavCapture.len
  for _ in 0 ..< 50: emu.step_frame()
  check(not emu.mp2k.resync_pending, "resync_pending cleared by first mixer pass")
  check(emu.mp2k.engaged, "engaged still true after 60 post-load frames")
  var active_end = 0
  for s in emu.mp2k.samplers:
    if s.active: active_end.inc
  check(active_end > 0, "channels re-latched from SoundInfo after load")
  let pre_peak  = peak(pre10, save_idx)
  let post_peak = peak(post0, post10)
  echo "  pre-save 10-frame peak=", pre_peak, "  post-load 10-frame peak=", post_peak
  check(post_peak <= max(3 * pre_peak, 64),
        "post-load transient same order of magnitude as pre-save (no retrigger burst)")
  check(post_peak < 500, "no full-scale click after load (clamp is 512)")

proc test_b(rom, state: string) =
  echo "B) HLE off around the load, re-enabled after"
  mp2kWavCapture.setLen(0)
  let emu = make(rom)
  doAssert emu.load_state(state), "initial .state load failed"
  emu.mp2k_hle = true
  for _ in 0 ..< 60: emu.step_frame()
  let saved = emu.state_bytes()
  emu.mp2k_hle = false
  for _ in 0 ..< 30: emu.step_frame()
  check(emu.load_state_bytes(saved), "load with HLE off succeeds")
  for _ in 0 ..< 10: emu.step_frame()   # runs with the hook disabled
  emu.mp2k_hle = true
  for _ in 0 ..< 60: emu.step_frame()
  check(emu.mp2k.engaged, "re-engaged after OFF->load->ON")
  check(not emu.mp2k.resync_pending, "resync consumed once HLE back on")
  var active = 0
  for s in emu.mp2k.samplers:
    if s.active: active.inc
  check(active > 0, "channels playing after OFF->load->ON")

proc test_c(rom: string) =
  echo "C) load on a non-MP2K ROM (HLE never engaged): ", rom
  mp2kWavCapture.setLen(0)
  let emu = make(rom)
  emu.mp2k_hle = true
  for _ in 0 ..< 30: emu.step_frame()
  check(not emu.mp2k.engaged, "never engages on non-MP2K ROM")
  let saved = emu.state_bytes()
  for _ in 0 ..< 10: emu.step_frame()
  check(emu.load_state_bytes(saved), "load succeeds with HLE never engaged")
  for _ in 0 ..< 30: emu.step_frame()
  check(not emu.mp2k.engaged, "still disengaged after load")

proc main() =
  let rom   = paramStr(1)
  let state = paramStr(2)
  let plain_rom = if paramCount() >= 3: paramStr(3) else: "tests/roms/attachtest.gba"
  test_a(rom, state)
  test_b(rom, state)
  test_c(plain_rom)
  if failures == 0:
    echo "ALL PASS"
  else:
    echo failures, " FAILURES"
    quit(1)

main()
