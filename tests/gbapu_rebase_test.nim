## GB APU deadlines across the per-frame scheduler rebase. Run standalone:
##   nimble test_gbapurebase
##
## The noise channel's divisor stage (GbChannel4.div_next) is the one APU
## deadline the catch-up leaves in the past, so gb_rebase must settle it
## before the scheduler's clock moves back, or the subtraction wraps it. A
## wrapped stage looks like a far-future deadline: the next NR43 write while
## the channel runs rebuilds the LFSR deadline from it, the noise stops
## shifting, and the next state payload (the rewind ring's, every few frames)
## dies on `int(next_step - cycles)` in apu_arm_state_events.
##
## No ROM on disk: a 32 KB program is assembled here. It triggers channel 4
## (divisor code 0, shift 0, no length), spins for several frames so rebases
## pass with the channel running, writes NR43 = 0x03, and spins forever.

import std/os
import dingbat/common/scheduler
import dingbat/gb/gb

var failures = 0
proc check(cond: bool; name: string) =
  if cond: echo "  [PASS] ", name
  else:
    echo "  [FAIL] ", name
    inc failures

proc build_rom(): string =
  result = newString(0x8000)
  let code = [
    0x00, 0xC3, 0x50, 0x01,       # 0100: nop; jp $0150
  ]
  for i, b in code: result[0x100 + i] = char(b)
  let body = [
    0xF3,                         # di
    0x3E, 0x80, 0xE0, 0x26,       # NR52 = $80: APU on
    0x3E, 0xF0, 0xE0, 0x21,       # NR42 = $F0: volume 15, DAC on
    0xAF,       0xE0, 0x22,       # NR43 = $00: divisor code 0, shift 0
    0x3E, 0x80, 0xE0, 0x23,       # NR44 = $80: trigger, length off
    0x01, 0x00, 0x40,             # ld bc, $4000 (~6.5 frames of 28 T)
    0x0B, 0x78, 0xB1, 0x20, 0xFB, # loop: dec bc; ld a,b; or c; jr nz, loop
    0x3E, 0x03, 0xE0, 0x22,       # NR43 = $03 while the channel runs
    0x18, 0xFE,                   # jr @
  ]
  for i, b in body: result[0x150 + i] = char(b)
  # Header: ROM only, 32 KB, no RAM, DMG; header checksum over $134-$14C.
  var sum = 0
  for a in 0x134 .. 0x14C: sum = sum - int(uint8(result[a])) - 1
  result[0x14D] = char(sum and 0xFF)

let rom_path = getTempDir() / "dingbat_gbapurebase.gb"
writeFile(rom_path, build_rom())
let emu = new_gb("", rom_path, fifo = true, headless = true, run_bios = false)
emu.post_init()

var payload_ok = true
var deadline_ok = true
var wrote_nr43 = false
var lfsr_moved = false
var last_lfsr = 0'u16
for f in 1 .. 20:
  emu.step_frame()
  # The rewind ring's call: must not raise for any reachable state.
  try:
    discard emu.state_payload()
  except RangeDefect:
    if payload_ok: echo "  state_payload raised RangeDefect at frame ", f
    payload_ok = false
  let ch = emu.apu.channel4
  if ch.divisor_code == 3:
    # After the write, the next LFSR shift is at most one period away.
    emu.apu.apu_catchup_all(emu)
    let period = CycleCount(3 shl 4)   # DMG, single speed: 16 * code T-cycles
    let ahead = ch.next_step - emu.scheduler.cycles
    if not ch.enabled or ch.next_step == GB_NO_STEP or ahead == 0 or ahead > period:
      if deadline_ok: echo "  frame ", f, ": next LFSR shift ", ahead,
                           " cycles ahead, period ", period
      deadline_ok = false
    if wrote_nr43 and ch.lfsr != last_lfsr: lfsr_moved = true
    wrote_nr43 = true
    last_lfsr = ch.lfsr
removeFile(rom_path)

check(wrote_nr43, "the program reached its NR43 write")
check(payload_ok, "state_payload succeeds every frame")
check(deadline_ok, "channel 4's next shift stays within one period after NR43")
check(lfsr_moved, "the LFSR keeps shifting after NR43")

if failures == 0: echo "ALL GB APU REBASE CHECKS PASS"
else:
  echo failures, " FAILURES"
  quit(1)
