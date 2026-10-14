## Timed joypad input (tests/gb_timed_input.nim, dingbat_test --input): an
## event at dot t is seen from the M-cycle that starts on the first 4-dot step
## at or after t, by a P1 read, by an IF read and by HALT and STOP, across
## frame rebases and in double speed. Run standalone:
##   nimble test_gbtimedinput
##
## No ROM on disk: each program is assembled here from bytes. M-cycle counts
## are from the hand-off (M0 = the fetch at $0100, dot 0..3); every program
## starts `jp $0150` (M0-M3).

import std/[os, strutils]
import dingbat/gb/gb
import gb_timed_input

var failures = 0
var checks = 0
proc check(cond: bool; msg: string) =
  inc checks
  if not cond:
    inc failures
    if failures <= 40: echo "  [FAIL] ", msg

proc make_rom(code: openArray[int]; cgb = false;
              isr: openArray[int] = []): string =
  result = newString(0x8000)
  for i, b in [0xC3, 0x50, 0x01]: result[0x100 + i] = char(b)  # jp $0150
  for i, b in code: result[0x150 + i] = char(b)
  for i, b in isr: result[0x60 + i] = char(b)                   # joypad vector
  if cgb: result[0x143] = char(0x80)
  var sum = 0
  for a in 0x134 .. 0x14C: sum = sum - int(uint8(result[a])) - 1
  result[0x14D] = char(sum and 0xFF)

var rom_seq = 0
var rom_files: seq[string]
proc rom_file(code: openArray[int]; cgb = false; isr: openArray[int] = []): string =
  inc rom_seq
  result = getTempDir() / ("dingbat_timed_input_" & $getCurrentProcessId() &
                           "_" & $rom_seq & (if cgb: ".gbc" else: ".gb"))
  writeFile(result, make_rom(code, cgb, isr))
  rom_files.add(result)

proc run(rom: string; spec: string; frames: int): GB =
  result = new_gb("", rom, headless = true, run_bios = false)
  result.post_init()
  arm_timed_inputs(result, parse_timed_inputs(spec))
  for _ in 0 ..< frames: result.step_frame()

proc wram(emu: GB; a: int): int = int(emu.memory.wram[0][a - 0xC000])

proc step_m(t: int): int = (t + 3) div 4   # the M-cycle an event at dot t lands on (single speed)

# ---------------------------------------------------------------------------
# 1. Sampling program: P1 and IF read every 10 M-cycles into $C000.
#    3E 10 E0 00   P1 = $10 (buttons)     M4-M8
#    AF E0 0F      IF = 0                 M9-M12
#    E0 FF         IE = 0                 M13-M15
#    21 00 C0      hl = $C000             M16-M18
#    [40]          ld b,b (variant)       M19
#    block j (10 M): F0 00 22 F0 0F 22 -> P1 read on its 3rd M-cycle, IF on its 8th
const Blocks = 60
proc sampler(ldbb: bool): (seq[int], int) =
  var code = @[0x3E, 0x10, 0xE0, 0x00, 0xAF, 0xE0, 0x0F, 0xE0, 0xFF,
               0x21, 0x00, 0xC0]
  if ldbb: code.add(0x40)
  for _ in 0 ..< Blocks: code.add([0xF0, 0x00, 0x22, 0xF0, 0x0F, 0x22])
  code.add([0x18, 0xFE])
  (code, if ldbb: 20 else: 19)   # M-cycle the first block starts on

proc p1_at(emu: GB; j: int): int = emu.wram(0xC000 + 2 * j)
proc if_at(emu: GB; j: int): int = emu.wram(0xC001 + 2 * j)

echo "P1 / IF visibility, single speed"
block:
  let (code, base) = sampler(false)
  let rom = rom_file(code)
  # A press at every dot from M20 to the end of the samples.
  for t in 80 .. 4 * (base + 10 * 25):
    let emu = run(rom, $t & ":a:press", 1)
    let m = step_m(t)
    for j in 0 ..< Blocks:
      let p1_m = base + 10 * j + 2
      let if_m = base + 10 * j + 7
      check(((emu.p1_at(j) and 1) == 0) == (p1_m >= m),
            "press at dot " & $t & ": P1 read on M" & $p1_m & " = $" & emu.p1_at(j).toHex(2))
      check(((emu.if_at(j) and 0x10) != 0) == (if_m >= m),
            "press at dot " & $t & ": IF read on M" & $if_m & " = $" & emu.if_at(j).toHex(2))
  # Release: A held from dot 0, so selecting the buttons at M8 is the edge
  # (cleared by the IF write); the release is a rising edge and raises nothing.
  for t in countup(80, 4 * (base + 10 * 25), 3):
    let emu = run(rom, "0:a:press," & $t & ":a:release", 1)
    let m = step_m(t)
    for j in 0 ..< Blocks:
      let p1_m = base + 10 * j + 2
      check(((emu.p1_at(j) and 1) != 0) == (p1_m >= m),
            "release at dot " & $t & ": P1 read on M" & $p1_m)
      check((emu.if_at(j) and 0x10) == 0, "release at dot " & $t & " raised IF bit 4")

echo "One event per 4-dot step, in list order; KEY+KEY is one event"
block:
  let (code, base) = sampler(false)
  let rom = rom_file(code)
  let j = 20
  let m = base + 10 * j + 2   # the P1 read of block j
  let tie = run(rom, $(4 * m) & ":a:press," & $(4 * m) & ":b:press", 1)
  check((tie.p1_at(j) and 3) == 2, "tied presses: A on M" & $m & ", B a step later")
  check((tie.p1_at(j + 1) and 3) == 0, "tied presses: both by the next read")
  let both = run(rom, $(4 * m) & ":a+b:press", 1)
  check((both.p1_at(j) and 3) == 0, "a+b lands on one M-cycle")
  # List order breaks the tie, not the key.
  let order = run(rom, $(4 * m) & ":b:press," & $(4 * m) & ":a:press", 1)
  check((order.p1_at(j) and 3) == 1, "tied presses: B first when listed first")
  # A backlog drains one per step: three tied presses take M, M+1, M+2.
  let three = $(4 * (m - 2)) & ":a:press," & $(4 * (m - 2)) & ":b:press," &
              $(4 * (m - 2)) & ":select:press"
  check((run(rom, three, 1).p1_at(j) and 7) == 0, "a backlog of three by M+2")
  let late = $(4 * (m - 1)) & ":a:press," & $(4 * (m - 1)) & ":b:press," &
             $(4 * (m - 1)) & ":select:press"
  check((run(rom, late, 1).p1_at(j) and 7) == 4, "the third of three one step late")
  # A later-listed event due earlier is not held up by one not yet due.
  let ahead = run(rom, $(4 * m + 4) & ":b:press," & $(4 * m) & ":a:press", 1)
  check((ahead.p1_at(j) and 3) == 2, "an event due earlier goes first")

echo "@op: applied on the M-cycle after the opcode fetch"
block:
  let (code, base) = sampler(true)
  let rom = rom_file(code)
  # ld b,b is fetched on M19, so @40 is the same as a timed event at M20.
  let by_op = run(rom, "@40:a:press", 1)
  let by_time = run(rom, $(4 * 20) & ":a:press", 1)
  var same = true
  for j in 0 ..< Blocks:
    if by_op.p1_at(j) != by_time.p1_at(j) or by_op.if_at(j) != by_time.if_at(j):
      same = false
  check(same, "@40 matches a press at dot 80")
  check(timed_inputs_left() == 0 and (by_time.p1_at(0) and 1) == 0 and base == 20,
        "the first sample after ld b,b sees the press")
  let rom2 = rom_file(sampler(false)[0])
  discard run(rom2, "@40:a:press", 1)
  check(timed_inputs_left() == 1, "an opcode that never runs leaves its event pending")

# ---------------------------------------------------------------------------
# 2. Counting poll loop across frame rebases: bc = iterations until A reads
#    pressed. 3E 10 E0 00 (M4-M8); 01 00 00 (M9-M11); loop i (9 M, from
#    M12+9i): 03 | F0 00 (P1 read on M16+9i) | 1F | 38 FA; then bc -> $C000.
proc counter_code(prefix: openArray[int] = []): seq[int] =
  result = @prefix
  result.add([0x3E, 0x10, 0xE0, 0x00, 0x01, 0x00, 0x00,
              0x03, 0xF0, 0x00, 0x1F, 0x38, 0xFA,
              0x78, 0xEA, 0x00, 0xC0, 0x79, 0xEA, 0x01, 0xC0, 0x18, 0xFE])

proc count_of(emu: GB): int = emu.wram(0xC000) * 256 + emu.wram(0xC001)

echo "Across frame boundaries (counting loop)"
block:
  let rom = rom_file(counter_code())
  for f in [1, 2, 5]:
    for k in countup(-400, 400, 7):
      let t = f * 70224 + k
      let emu = run(rom, $t & ":a:press", f + 2)
      let m = step_m(t)
      let want = (m - 16 + 8) div 9 + 1
      check(emu.count_of == want, "press at dot " & $t & ": " & $emu.count_of &
            " iterations, want " & $want)

echo "Double speed: 2 dots per M-cycle after a KEY1 switch"
block:
  # 3E 01 E0 4D 10 00: KEY1 = 1; stop -> double speed; then the counting loop.
  let rom = rom_file(counter_code([0x3E, 0x01, 0xE0, 0x4D, 0x10, 0x00]), cgb = true)
  var prev = -1
  for k in countup(0, 36 * 6, 4):
    let t = 3 * 70224 + k
    let emu = run(rom, $t & ":a:press", 6)
    check(emu.memory.current_speed == 1, "the switch ran")
    let n = emu.count_of
    if prev >= 0: check(n - prev in 0 .. 1, "4 dots move the count by at most one")
    prev = n
  let a = run(rom, $(3 * 70224) & ":a:press", 6).count_of
  let b = run(rom, $(3 * 70224 + 36) & ":a:press", 6).count_of
  let c = run(rom, $(3 * 70224 + 36 * 5) & ":a:press", 6).count_of
  check(b - a == 2, "36 dots = 18 M-cycles = 2 iterations (" & $a & " -> " & $b & ")")
  check(c - a == 10, "180 dots = 10 iterations (" & $a & " -> " & $c & ")")
  # Booked before the switch and carried through its rescale.
  let d = run(rom, "100000:a:press", 6).count_of
  let e = run(rom, "100036:a:press", 6).count_of
  check(e - d == 2, "an event booked before the switch keeps real time")

# ---------------------------------------------------------------------------
# 3. Idle poll loop vs the same loop with a register change in it (which no
#    idle skip can take): the exit time, read off TIMA at 4 M-cycles a tick,
#    must agree for every press time. 3E 10 E0 00 (P1); E0 04 (DIV reset);
#    3E 05 E0 07 (TAC = 262144 Hz); AF E0 05 (TIMA = 0);
#    idle: F0 00 | CB 47 | 20 FA     busy: F0 00 | 1F | 1C | 38 FA   (8 M each)
#    then F0 05 EA 00 C0 18 FE.
echo "Idle-loop skip and HALT keep the event's M-cycle"
block:
  let head = @[0x3E, 0x10, 0xE0, 0x00, 0xE0, 0x04, 0x3E, 0x05, 0xE0, 0x07,
               0xAF, 0xE0, 0x05]
  let tail = @[0xF0, 0x05, 0xEA, 0x00, 0xC0, 0x18, 0xFE]
  let idle = rom_file(head & @[0xF0, 0x00, 0xCB, 0x47, 0x20, 0xFA] & tail)
  let busy = rom_file(head & @[0xF0, 0x00, 0x1F, 0x1C, 0x38, 0xFA] & tail)
  for k in countup(-1500, 1500, 11):
    let t = 70224 + k
    let a = run(idle, $t & ":a:press", 3).wram(0xC000)
    let b = run(busy, $t & ":a:press", 3).wram(0xC000)
    check(a == b, "press at dot " & $t & ": idle loop TIMA $" & a.toHex(2) &
          ", busy loop $" & b.toHex(2))
  # HALT with IE = joypad: the handler reads TIMA. 3E 10 E0 00; AF E0 0F;
  # 3E 10 E0 FF (IE); E0 04; 3E 05 E0 07; AF E0 05; FB 76 00 18 FE.
  let halt = rom_file(@[0x3E, 0x10, 0xE0, 0x00, 0xAF, 0xE0, 0x0F,
                        0x3E, 0x10, 0xE0, 0xFF, 0xE0, 0x04, 0x3E, 0x05, 0xE0, 0x07,
                        0xAF, 0xE0, 0x05, 0xFB, 0x76, 0x00, 0x18, 0xFE],
                      isr = tail)
  var prev = -1
  var steps = 0
  for k in countup(0, 4 * 400, 4):
    let t = 70224 + k
    let v = run(halt, $t & ":a:press", 3).wram(0xC000)
    if prev >= 0:
      let d = (v - prev + 256) mod 256
      check(d in 0 .. 1, "HALT wake at dot " & $t & " moved TIMA by " & $d)
      steps += d
    prev = v
  check(steps == 100, "HALT: 400 M-cycles of press time = 100 TIMA ticks (" & $steps & ")")

# ---------------------------------------------------------------------------
# 4. STOP: the scheduler stands still, the input clock does not.
#    3E 10 E0 00 (P1); AF E0 0F E0 FF (IF = IE = 0); 10 00 (stop);
#    3E 01 EA 00 C0 (marker); 21 10 C0 (hl); then sampling blocks of P1 only:
#    F0 00 22 (5 M).
echo "STOP mode"
block:
  var code = @[0x3E, 0x10, 0xE0, 0x00, 0xAF, 0xE0, 0x0F, 0xE0, 0xFF, 0x10, 0x00,
               0x3E, 0x01, 0xEA, 0x00, 0xC0, 0x21, 0x10, 0xC0]
  for _ in 0 ..< 200: code.add([0xF0, 0x00, 0x22])
  code.add([0x18, 0xFE])
  let rom = rom_file(code)
  let idle = run(rom, "", 4)
  check(idle.cpu.stopped and idle.wram(0xC000) != 1, "STOP waits without a press")
  check(run(rom, "100000:a:press", 4).wram(0xC000) == 1, "a press ends STOP")
  # After the wake the clock runs on: a release swept in 4-dot steps moves the
  # first released sample by one every 5 M-cycles.
  proc first_released(emu: GB): int =
    for j in 0 ..< 200:
      if (emu.wram(0xC010 + j) and 1) != 0: return j
    -1
  var idx: seq[int]
  for k in countup(0, 4 * 5 * 40, 4):
    let emu = run(rom, "100000:a:press," & $(100000 + 2000 + k) & ":a:release", 4)
    idx.add(emu.first_released)
  check(idx[0] > 0, "the release lands inside the samples (" & $idx[0] & ")")
  for i in 5 ..< idx.len:
    check(idx[i] == idx[i - 5] + 1, "STOP release step " & $i & ": " & $idx[i - 5] &
          " -> " & $idx[i])

echo "Parsing"
block:
  let evs = parse_timed_inputs("0:a:press, 131072:a:released,@49:up+down:release")
  check(evs.len == 3 and evs[0].at == 0 and evs[0].down and
        evs[1].at == 131072 and not evs[1].down and evs[2].op == 0x49 and
        evs[2].keys.len == 2, "three events parsed")
  var bad = 0
  for s in ["1:a", "x:a:press", "1:q:press", "1:a:hold", "@100:a:press"]:
    try: discard parse_timed_inputs(s)
    except ValueError: inc bad
  check(bad == 5, "malformed items are refused (" & $bad & "/5)")

for f in rom_files: removeFile(f)
if failures > 0:
  echo "FAILED: ", failures, " of ", checks, " checks"
  quit(1)
echo "all ", checks, " checks passed"
