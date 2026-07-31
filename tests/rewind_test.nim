## Rewind-ring property tests. Run standalone:
##   nim c -r -d:test_harness -d:release --path:src -o:dingbat_rewind_test \
##     tests/rewind_test.nim
##
## The dangerous failure mode in this ring is not a crash or a corrupt
## payload — it is index/eviction bookkeeping that hands back a state from the
## WRONG MOMENT, byte-perfect and indistinguishable from the right one. So the
## bar here is byte equality against a reference walk of the delta chain
## (`snapshots_newest_first`, which knows nothing about IDs or keyframes) at
## every depth, before and after eviction, with and without keyframes, and
## across a pop/push seam (where snapshot IDs stop being contiguous).
##
## No ROM, no emulator: payloads are synthetic buffers that change a small
## fraction of their bytes per step, which is what a real state payload does
## over a 10-frame window and what makes the deltas compress at all.

import std/[sequtils, strformat]
import dingbat/common/rewind

var failures = 0
template check(label: string; cond: untyped) =
  if cond:
    echo "  ok  ", label
  else:
    echo "  FAIL ", label
    inc failures

# --- Synthetic core -------------------------------------------------------

const PAYLOAD_BYTES = 48 * 1024

type FakeCore = object
  mem: string
  rng: uint32
  step: int

proc next(c: var FakeCore): uint32 =
  # xorshift32: deterministic across platforms, no std/random dependency
  c.rng = c.rng xor (c.rng shl 13)
  c.rng = c.rng xor (c.rng shr 17)
  c.rng = c.rng xor (c.rng shl 5)
  c.rng

proc new_core(seed: uint32 = 0x1234_5678'u32): FakeCore =
  result = FakeCore(mem: newString(PAYLOAD_BYTES), rng: seed)
  for i in 0 ..< PAYLOAD_BYTES:
    result.mem[i] = char(result.next() and 0xFF)

proc advance(c: var FakeCore) =
  ## One "snapshot interval" of emulation: touch ~1% of the buffer.
  inc c.step
  for _ in 0 ..< (PAYLOAD_BYTES div 100):
    let at = int(c.next() mod uint32(PAYLOAD_BYTES))
    c.mem[at] = char(c.next() and 0xFF)

proc payload(c: FakeCore): string =
  # Stamp the step number into the head so a payload from the wrong moment is
  # identifiable even when the rest of the buffer looks plausible.
  result = c.mem
  # Payload lengths wobble in the real thing (the scheduler serializes a
  # variable event count), and the delta encoder has a raw-tail path for it.
  if c.step mod 17 == 0:
    result.setLen(PAYLOAD_BYTES - (c.step mod 5))
  for i in 0 ..< 4:
    result[i] = char((c.step shr (i * 8)) and 0xFF)

const THUMB_W = 12
const THUMB_H = 8

proc thumb_of(c: FakeCore): RewindThumb =
  ## Pixels encode the step, so a thumbnail can be traced back to the frame it
  ## was captured on (that is what "evicted in lockstep" has to mean).
  result = RewindThumb(w: THUMB_W, h: THUMB_H,
                       pixels: newSeq[byte](THUMB_W * THUMB_H * 2))
  for i in 0 ..< 4:
    result.pixels[i] = byte((c.step shr (i * 8)) and 0xFF)

proc thumb_step(t: RewindThumb): int =
  for i in countdown(3, 0):
    result = (result shl 8) or int(t.pixels[i])

proc payload_step(p: string): int =
  for i in countdown(3, 0):
    result = (result shl 8) or int(uint8(p[i]))

# --- The property --------------------------------------------------------

proc verify_all(rw: Rewind; label: string; every = 1) =
  ## snapshot_at(k) must equal the k-th entry of the reference chain walk, and
  ## the ID round-trip must land on the same bytes. `every` samples k when the
  ## ring is too deep to check exhaustively in reasonable time.
  let refs = toSeq(rw.snapshots_newest_first())
  var bad_at = -1
  var bad_id = -1
  var bad_idx = -1
  var k = 0
  while k < refs.len:
    if rw.snapshot_at(k) != refs[k] and bad_at < 0: bad_at = k
    let id = rw.id_at_index(k)
    if rw.index_of_id(id) != k and bad_idx < 0: bad_idx = k
    if rw.snapshot_by_id(id) != refs[k] and bad_id < 0: bad_id = k
    k += (if k < 4: 1 else: every)
  # The newest and oldest ends are where off-by-one bookkeeping shows up.
  if refs.len > 1:
    if rw.snapshot_at(refs.len - 1) != refs[^1] and bad_at < 0: bad_at = refs.len - 1
  check &"{label}: snapshot_at matches the chain (depth {refs.len})", bad_at < 0
  check &"{label}: index_of_id round-trips", bad_idx < 0
  check &"{label}: snapshot_by_id matches the chain", bad_id < 0

# --- 1. IDs, ordering, basic shape ---------------------------------------

echo "== IDs and ordering =="
block:
  let rw = new_rewind(cap = 8 * 1024 * 1024, interval = 10)
  var c = new_core()
  check "empty ring has no IDs", rw.newest_id == -1 and rw.oldest_id == -1
  check "empty ring: snapshot_at(0) is empty", rw.snapshot_at(0).len == 0
  check "empty ring: snapshot_by_id(0) is empty", rw.snapshot_by_id(0).len == 0
  var ids: seq[int] = @[]
  for i in 0 ..< 40:
    c.advance()
    rw.push(c.payload(), proc(): RewindThumb = thumb_of(c))
    ids.add rw.newest_id
  check "IDs increase by one per push", ids == toSeq(0 ..< 40)
  check "newest_id is the last push", rw.newest_id == 39
  check "oldest_id is the first push", rw.oldest_id == 0
  check "len counts latest + deltas", rw.len == 40
  check "index 0 is the newest ID", rw.id_at_index(0) == 39
  check "index 39 is the oldest ID", rw.id_at_index(39) == 0
  check "out-of-range index has no ID", rw.id_at_index(40) == -1
  check "unknown ID has no index", rw.index_of_id(1000) == -1
  verify_all(rw, "40 pushes")

# --- 2. Every depth, exhaustively, small ---------------------------------

echo "== every depth (exhaustive, no eviction) =="
block:
  let rw = new_rewind(cap = 8 * 1024 * 1024, interval = 10)
  var c = new_core(0x55AA_0001'u32)
  var bad = -1
  for depth in 1 .. 45:
    c.advance()
    rw.push(c.payload(), proc(): RewindThumb = thumb_of(c))
    let refs = toSeq(rw.snapshots_newest_first())
    if refs.len != depth and bad < 0: bad = depth
    for k in 0 ..< refs.len:
      if rw.snapshot_at(k) != refs[k] and bad < 0: bad = depth
      if rw.snapshot_by_id(rw.id_at_index(k)) != refs[k] and bad < 0: bad = depth
  check "all k at all depths 1..45 match the chain", bad < 0

  # Negative control: the comparison above must be capable of failing.
  let refs = toSeq(rw.snapshots_newest_first())
  check "negative control: neighbouring snapshots differ", refs[0] != refs[1]
  check "negative control: a wrong index is detected",
        rw.snapshot_at(1) != refs[0]

# --- 3. Keyframes must be invisible --------------------------------------

echo "== keyframes change cost, never content =="
block:
  # Same payloads into two rings: one with keyframes, one without. Every
  # reconstruction must agree byte for byte at every depth.
  let with_kf = new_rewind(cap = 32 * 1024 * 1024, interval = 10, key_every = 7)
  let no_kf = new_rewind(cap = 32 * 1024 * 1024, interval = 10, key_every = 0)
  var c = new_core(0x0BAD_C0DE'u32)
  var bad = -1
  for i in 0 ..< 120:
    c.advance()
    let p = c.payload()
    with_kf.push(p)
    no_kf.push(p)
    if i mod 13 == 0:
      for k in 0 ..< with_kf.len:
        if with_kf.snapshot_at(k) != no_kf.snapshot_at(k) and bad < 0: bad = i
  check "keyframe seek == plain chain walk at every depth", bad < 0
  check "keyframes cost memory", with_kf.mem_breakdown.keyframes > 0
  check "no keyframes when disabled", no_kf.mem_breakdown.keyframes == 0
  verify_all(with_kf, "120 pushes, keyframes on")

# --- 4. Eviction: IDs stay put, thumbnails go with their snapshot --------

echo "== eviction =="
block:
  # A cap small enough that the ring turns over several times.
  let rw = new_rewind(cap = 1024 * 1024, interval = 10, key_every = 11)
  var c = new_core(0xFEED_BEEF'u32)
  var seen: seq[tuple[id: int, payload: string]] = @[]
  var evicted = 0
  var bad_stable = -1
  var bad_order = -1
  var bad_thumb = -1
  var bad_cap = -1
  const CAP = 1024 * 1024
  for i in 0 ..< 400:
    c.advance()
    let p = c.payload()
    rw.push(p, proc(): RewindThumb = thumb_of(c))
    seen.add (rw.newest_id, p)
    if rw.mem_used > CAP and bad_cap < 0: bad_cap = i
    if i mod 25 == 0 and i > 0:
      # Every ID ever handed out either still reconstructs its ORIGINAL bytes
      # or is gone. Never someone else's bytes.
      for (id, want) in seen:
        let got = rw.snapshot_by_id(id)
        if got.len == 0:
          inc evicted
        elif got != want and bad_stable < 0:
          bad_stable = id
      # Thumbnails: none orphaned (every thumb's snapshot must still
      # reconstruct), none outliving its snapshot, ordering newest-first.
      var prev_id = high(int)
      for t in 0 ..< rw.thumb_count:
        let tid = rw.thumb_id(t)
        if rw.index_of_id(tid) < 0 and bad_thumb < 0: bad_thumb = tid
        let snap = rw.snapshot_by_id(tid)
        let thumb = rw.thumb_at(t)  # inflates: the pixels must come back whole
        if snap.len == 0 or thumb.pixels.len != THUMB_W * THUMB_H * 2:
          if bad_thumb < 0: bad_thumb = tid
        # The picture must be of the moment its ID names: both carry the
        # step number they were captured on.
        elif thumb_step(thumb) != payload_step(snap):
          if bad_thumb < 0: bad_thumb = tid
        if tid >= prev_id and bad_order < 0: bad_order = tid
        prev_id = tid
  check "the ring actually evicted", rw.oldest_id > 0
  check "IDs never resolve to another moment's bytes", bad_stable < 0
  check "evicted IDs were seen (the test exercised eviction)", evicted > 0
  check "no orphaned or outliving thumbnails", bad_thumb < 0
  check "thumbnail IDs are newest-first", bad_order < 0
  check "mem_used never exceeds the cap", bad_cap < 0
  verify_all(rw, "after eviction", every = 7)

  # The oldest thumbnail must not predate the oldest snapshot, and the
  # newest must not postdate the newest one.
  check "thumbnails inside the retained ID range",
        rw.thumb_count > 0 and rw.thumb_id(0) <= rw.newest_id and
        rw.thumb_id(rw.thumb_count - 1) >= rw.oldest_id

# --- 5. mem_used tells the truth -----------------------------------------

echo "== memory accounting =="
block:
  const MEM_CAP = 1024 * 1024
  let rw = new_rewind(cap = MEM_CAP, interval = 10, key_every = 20)
  var c = new_core(0xC0FF_EE01'u32)
  for _ in 0 ..< 800:
    c.advance()
    rw.push(c.payload(), proc(): RewindThumb = thumb_of(c))
  let b = rw.mem_breakdown
  check "mem_used == deltas + latest + thumbs + keyframes",
        rw.mem_used == b.deltas + b.latest + b.thumbs + b.keyframes
  check "thumbnails are accounted", b.thumbs > 0
  check "thumbnails are stored compressed",
        b.thumbs < rw.thumb_count * THUMB_W * THUMB_H * 2
  check "keyframes are accounted", b.keyframes > 0
  check "the cap includes them", rw.mem_used <= MEM_CAP
  # Without the side tables in the accounting the ring would hold strictly
  # more history at the same cap — that difference is the bug this guards.
  let loose = new_rewind(cap = MEM_CAP, interval = 10, key_every = 0)
  var c2 = new_core(0xC0FF_EE01'u32)
  for _ in 0 ..< 800:
    c2.advance()
    loose.push(c2.payload())
  check "side tables shorten the ring (they are inside the budget)",
        loose.len > rw.len
  echo &"    depth with thumbs+keyframes {rw.len}, without {loose.len} " &
       &"(thumbs {b.thumbs}, keyframes {b.keyframes} bytes)"

# --- 6. Thumbnail cadence ------------------------------------------------

echo "== thumbnail cadence =="
block:
  # One per second of history: at interval 10 (~6 pushes/s) that is every 6th
  # push, not every push.
  let rw = new_rewind(cap = 64 * 1024 * 1024, interval = 10)
  var c = new_core(0x7777_0001'u32)
  for _ in 0 ..< 60:
    c.advance()
    rw.push(c.payload(), proc(): RewindThumb = thumb_of(c))
  check &"60 pushes -> 10 thumbnails (got {rw.thumb_count})", rw.thumb_count == 10
  var spacing_ok = true
  for t in 1 ..< rw.thumb_count:
    if rw.thumb_id(t - 1) - rw.thumb_id(t) != 6: spacing_ok = false
  check "thumbnails are 6 snapshots apart", spacing_ok
  check "the first push is a thumbnail", rw.thumb_id(rw.thumb_count - 1) == 0
  # No thumbnail proc (the native GUI has no scrubber) must cost nothing.
  let bare = new_rewind(cap = 64 * 1024 * 1024, interval = 10)
  var c3 = new_core(0x7777_0001'u32)
  for _ in 0 ..< 60:
    c3.advance()
    bare.push(c3.payload())
  check "no thumbnail proc -> no thumbnails", bare.thumb_count == 0
  check "no thumbnail proc -> no thumbnail bytes", bare.mem_breakdown.thumbs == 0

# --- 7. pop() seam: IDs stop being contiguous -----------------------------

echo "== pop/push seam =="
block:
  # Hold-to-rewind pops destructively, then the game resumes and pushes
  # again. Fresh IDs are NOT the ones just popped (reusing them would let a
  # stale scrubber selection resolve to a different moment), so the retained
  # ID sequence has a gap in it — everything that maps ID <-> position has to
  # survive that.
  let rw = new_rewind(cap = 64 * 1024 * 1024, interval = 10, key_every = 9)
  var c = new_core(0x1357_9BDF'u32)
  for _ in 0 ..< 80:
    c.advance()
    rw.push(c.payload(), proc(): RewindThumb = thumb_of(c))
  let before_id = rw.newest_id
  var popped_ids: seq[int] = @[]
  for _ in 0 ..< 30:
    popped_ids.add rw.newest_id
    discard rw.pop()
  check "pop rewinds the newest ID", rw.newest_id == before_id - 30
  var thumbs_ok = true
  for t in 0 ..< rw.thumb_count:
    if rw.thumb_id(t) > rw.newest_id: thumbs_ok = false
  check "pop drops thumbnails newer than the new head", thumbs_ok
  verify_all(rw, "after 30 pops")

  for _ in 0 ..< 40:
    c.advance()
    rw.push(c.payload(), proc(): RewindThumb = thumb_of(c))
  check "new IDs are not recycled", rw.newest_id > before_id
  check "a popped ID does not resolve", popped_ids.allIt(rw.snapshot_by_id(it).len == 0)
  verify_all(rw, "across the seam")
  var seam_thumbs = true
  for t in 0 ..< rw.thumb_count:
    if rw.index_of_id(rw.thumb_id(t)) < 0: seam_thumbs = false
  check "no orphaned thumbnails across the seam", seam_thumbs

echo ""
if failures == 0:
  echo "ALL REWIND TESTS PASSED"
else:
  echo failures, " FAILURES"
  quit(1)
