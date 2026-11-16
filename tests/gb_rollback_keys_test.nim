## GB input rollback with buttons changing every frame (gb/rollback.nim):
## two sessions, each rolling back at its own latency, must end
## byte-identical to each other and to a straight run. A checkpoint restored
## without the joypad's held keys and edge detector (a state image leaves
## them out) raised the joypad interrupt by when the rollback came, and the
## two peers drifted apart on IF bit 4 at uneven latencies.

import dingbat/common/input
import dingbat/gb/[gb, link, rollback]

const ROM = "tests/roms/gblinktest.gb"
const FRAMES = 600

proc make_link(): GbLink =
  var cores: seq[GB]
  for i in 0 .. 1:
    let c = new_gb("", ROM, headless = true, run_bios = false)
    c.post_init()
    cores.add c
  new_gb_link(cores)

proc mask(player, f: int): uint16 =
  var h = uint32(f) * 2654435761'u32 + uint32(player) * 40503'u32
  h = h xor (h shr 15)
  h = h * 0x2c1b3c6d'u32
  h = h xor (h shr 12)
  uint16(h and 0x3ff)

proc run(delay_a, delay_b: int; want: uint64): bool =
  let a = new_gb_rollback_session(make_link(), 0, 12)
  let b = new_gb_rollback_session(make_link(), 1, 12)
  var to_b, to_a: seq[(int, int, uint16)]  # (deliver at step, frame, bits)
  var step = 0
  while (a.head < FRAMES or b.head < FRAMES or a.confirmed < FRAMES - 1 or
         b.confirmed < FRAMES - 1) and step < FRAMES * 20:
    inc step
    var keep: seq[(int, int, uint16)]
    for m in to_b:
      if m[0] <= step: b.feed_remote(m[1], m[2]) else: keep.add m
    to_b = keep
    keep = @[]
    for m in to_a:
      if m[0] <= step: a.feed_remote(m[1], m[2]) else: keep.add m
    to_a = keep
    if a.head < FRAMES and a.tick(mask(0, a.head)) == grbAdvanced:
      to_b.add((step + delay_a, a.head - 1, mask(0, a.head - 1)))
    if b.head < FRAMES and b.tick(mask(1, b.head)) == grbAdvanced:
      to_a.add((step + delay_b, b.head - 1, mask(1, b.head - 1)))
  let ok = a.checksum() == b.checksum() and a.checksum() == want
  echo "  [", (if ok: "PASS" else: "FAIL"), "] latency ", delay_a, "/", delay_b,
       ": peers agree ", a.checksum() == b.checksum(), ", straight run ",
       a.checksum() == want, " (rollbacks ", a.rollbacks, "/", b.rollbacks, ")"
  ok

proc main(): int =
  let truth = make_link()
  for f in 0 ..< FRAMES:
    for p in 0 .. 1:
      let m = mask(p, f)
      for i in 0 ..< 10: truth.cores[p].handle_input(Input(i), ((m shr i) and 1) != 0)
    truth.step_frame()
  let want = truth.state_checksum()
  for (da, db) in [(1, 5), (5, 1), (3, 3), (2, 9), (7, 2)]:
    if not run(da, db, want): inc result

let failures = main()
if failures > 0:
  echo failures, " FAILED"
  quit(1)
echo "ALL PASS"
