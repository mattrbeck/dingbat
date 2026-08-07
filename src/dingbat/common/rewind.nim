# Rewind history: a bounded ring of zlib-compressed XOR deltas between
# consecutive state snapshots, plus the newest snapshot kept whole.
#
# Rewind only ever steps backward from the newest state, so each entry needs
# to decode against its *successor* only: prev = inflate(delta) XOR cur.
# Popping is O(delta) with no keyframes, and because consecutive snapshots
# differ in a small fraction of bytes (most emulator memory is static over a
# 10-frame window), deltas deflate to a few percent of the ~500 KB payload —
# that is what makes long histories affordable.
#
# Three things exist on top of that chain, all for the scrubber (jump to an
# arbitrary moment instead of only holding the rewind button):
#
#  * Absolute IDs. The deque evicts from the front, so an entry's positional
#    index shifts under any caller that remembers it — index 900 means a
#    different moment one second later. Every pushed snapshot gets a
#    monotonically increasing ID instead, and IDs are never reused, so a stale
#    ID resolves to "gone" rather than to the wrong moment.
#  * Thumbnails captured at PUSH time. Rendering a timeline by applying
#    sampled snapshots to the live core costs a full walk of history (every
#    delta inflated) for a handful of pictures. The framebuffer is already in
#    hand at push time, so one downscale there gives the strip for free.
#  * Keyframes. A delta chain anchored only at `latest` makes reaching the
#    k-th snapshot O(k) inflations — a second of freeze at the oldest end of a
#    full ring. A whole compressed payload every `key_every` pushes bounds a
#    seek to that many inflations.
#
# Thumbnails and keyframes are counted in mem_used and evicted with the deltas
# they belong to. That is not bookkeeping tidiness: the cap is a real memory
# budget (64 MB, and 16 MB on iOS where process-level pressure gets the wasm
# JIT demoted), and side tables outside it would silently make the budget a
# lie on exactly the platform that can least afford it.

import std/deques
import zippy

when defined(rewindprof):
  # EXPLORATORY (-d:rewindprof): where the per-snapshot cost goes. Nanoseconds
  # and call counts, printed by tests/dingbat_bench.nim. Pushes happen ~6/s, so
  # the getMonoTime pairs are far below the noise of what they measure.
  import std/monotimes, std/times
  const
    RpSerialize* = 0   ## the caller's state_payload()
    RpXor* = 1         ## XOR of the new payload against the previous one
    RpCompress* = 2    ## zlib of the delta body
    RpThumbGrab* = 3   ## the caller's framebuffer downscale
    RpThumbZlib* = 4   ## zlib of the downscaled thumbnail
    RpKeyZlib* = 5     ## zlib of a whole keyframe payload
    RpEvict* = 6       ## eviction at the cap
    RpPushTotal* = 7   ## the whole push, serialize included
    RpPops* = 8        ## pop(): inflate + XOR
  var rewindprof*: array[16, int64]
  var rewindprof_n*: array[16, int]
  var rewindprof_bytes*: array[16, int64]
  template rp(slot: int; body: untyped) =
    let t0 = getMonoTime()
    body
    rewindprof[slot] += (getMonoTime() - t0).inNanoseconds
    rewindprof_n[slot].inc
else:
  template rp(slot: int; body: untyped) = body

type
  RewindThumb* = object
    ## One downscaled frame captured at push time: little-endian BGR555,
    ## 2 bytes per pixel — the same layout as the save-state thumbnail
    ## trailer, so the same JS decoder reads both.
    w*, h*: int
    pixels*: seq[byte]

  Delta = object
    id: int         # absolute ID of the snapshot this body reconstructs
    packed: string  # zlib XOR delta against the next-newer snapshot

  KeyFrame = object
    id: int
    packed: string  # whole snapshot payload, zlib

  ThumbEntry = object
    id: int
    w, h: int
    packed: seq[byte]  # zlib'd pixels — see the note in push()

  Rewind* = ref object
    deltas: Deque[Delta]        # oldest first
    thumbs: Deque[ThumbEntry]   # oldest first, sparse (one per thumb_every)
    keys: Deque[KeyFrame]       # oldest first, sparse (one per key_every)
    latest: string              # newest snapshot payload, uncompressed
    latest_id: int              # ID of `latest` (-1 when empty)
    next_id: int                # never reset, never reused
    total: int                  # compressed bytes retained across deltas
    thumb_total: int
    key_total: int
    cap: int                    # eviction threshold for mem_used
    interval: int               # emulated frames between snapshots
    frame_count: int
    thumb_every: int            # pushes between thumbnails (0 = never)
    key_every: int              # pushes between keyframes (0 = never)
    thumb_due: int              # pushes remaining until the next thumbnail
    key_due: int                # pushes remaining until the next keyframe

const
  REWIND_CAP_BYTES* = 64 * 1024 * 1024
  REWIND_INTERVAL*  = 10  # ~6 snapshots/second
  REWIND_KEY_EVERY* = 60
    ## Snapshots between keyframes: ~10 s of history at the default interval,
    ## so a seek costs at most ~60 inflations. Measured cost of the extra
    ## traffic is 8.5 KB/s on GBA (80-86 KB a keyframe) and 0.9 KB/s on GB
    ## (9.5 KB) — 3.7% and 9% of what those cores' delta streams retain.

proc thumbs_per_second(interval: int): int =
  ## One thumbnail per second of history. Pushes are `interval` frames apart
  ## at ~60 fps, so that is every 60/interval pushes (6 at the default).
  ## Dense enough to scrub against, and the strip is sampled down to ~48 for
  ## display anyway. Compressed (see push) this costs 2.6-4.1 KB/s on GBA and
  ## 1.0 KB/s on GB.
  max(1, 60 div max(1, interval))

proc new_rewind*(cap = REWIND_CAP_BYTES; interval = REWIND_INTERVAL;
                 key_every = REWIND_KEY_EVERY): Rewind =
  Rewind(cap: cap, interval: interval, latest_id: -1,
         thumb_every: thumbs_per_second(interval), key_every: key_every)

proc len*(rw: Rewind): int =
  rw.deltas.len + (if rw.latest.len > 0: 1 else: 0)

proc mem_used*(rw: Rewind): int =
  rw.total + rw.latest.len + rw.thumb_total + rw.key_total

proc mem_breakdown*(rw: Rewind): tuple[deltas, latest, thumbs, keyframes: int] =
  ## What mem_used is made of (debug overlays, tests).
  (rw.total, rw.latest.len, rw.thumb_total, rw.key_total)

proc clear*(rw: Rewind) =
  rw.deltas.clear()
  rw.thumbs.clear()
  rw.keys.clear()
  rw.latest = ""
  rw.latest_id = -1
  rw.total = 0
  rw.thumb_total = 0
  rw.key_total = 0
  rw.frame_count = 0
  rw.thumb_due = 0
  rw.key_due = 0
  # next_id deliberately survives: an ID handed out before the clear must not
  # come back attached to a different moment.

proc xor_bytes(dst: var string; src: string; k: int) =
  ## dst[0..<k] ^= src[0..<k], in word-sized chunks
  let words = k div 8
  if words > 0:
    let d = cast[ptr UncheckedArray[uint64]](addr dst[0])
    let s = cast[ptr UncheckedArray[uint64]](unsafeAddr src[0])
    for i in 0 ..< words:
      d[i] = d[i] xor s[i]
  for i in (words * 8) ..< k:
    dst[i] = char(uint8(dst[i]) xor uint8(src[i]))


# --- Sparse-block pre-pass on the delta -----------------------------------
#
# The delta is an XOR, so "unchanged" is literally a zero byte, and after the
# fixed-length-payload fix it is 99% zeros. zlib still has to walk every one of
# those zeros to rediscover that it is a zero. A bitmap of which 64-byte blocks
# contain ANY non-zero byte, followed by only those blocks, costs one bit per
# block and skips the rest with a word-at-a-time scan.
#
# Format: u32 original length, u32 block size, ceil(nblocks/8) bitmap bytes,
# then the set blocks back to back. The last block may be short; its length
# falls out of the original length, so nothing else needs storing. The result
# is then zlib'd as before, which still gets to exploit whatever redundancy
# survives inside the changed blocks.
#
# Measured on Pokemon FireRed from an in-game state, fixed-length payloads:
#   native   4542 B vs 5741 B, encode 0.165 ms vs 0.167 ms, decode 4.3x faster
#   Chrome   4480 B vs 5678 B, encode 2.7x faster, decode 6.4x faster
#   Safari   4480 B vs 5678 B, encode 2.5x faster
# The browsers gain far more than native because zippy's deflate is much
# slower relative to a flat scan under wasm than it is compiled natively.

const SparseBlock* = 64

proc sparse_encode*(src: string; bs = SparseBlock): string =
  let n = src.len
  if n == 0: return ""
  let nblocks = (n + bs - 1) div bs
  let bitmapBytes = (nblocks + 7) div 8
  var bitmap = newString(bitmapBytes)
  var body = newStringOfCap(n div 8 + 64)
  let s = cast[ptr UncheckedArray[byte]](unsafeAddr src[0])
  for b in 0 ..< nblocks:
    let lo = b * bs
    let hi = min(lo + bs, n)
    var any = false
    var i = lo
    while i + 8 <= hi:
      if cast[ptr uint64](addr s[i])[] != 0: any = true; break
      i += 8
    if not any:
      while i < hi:
        if s[i] != 0: any = true; break
        i.inc
    if any:
      bitmap[b div 8] = char(uint8(bitmap[b div 8]) or (1'u8 shl (b mod 8)))
      body.add(src[lo ..< hi])
  result = newStringOfCap(8 + bitmapBytes + body.len)
  var hdr = newString(8)
  cast[ptr uint32](addr hdr[0])[] = uint32(n)
  cast[ptr uint32](addr hdr[4])[] = uint32(bs)
  result.add hdr
  result.add bitmap
  result.add body

proc sparse_decode*(src: string): string =
  if src.len == 0: return ""
  if src.len < 8: raise newException(ValueError, "rewind: truncated sparse delta")
  let n = int(cast[ptr uint32](unsafeAddr src[0])[])
  let bs = int(cast[ptr uint32](unsafeAddr src[4])[])
  if bs <= 0 or n < 0: raise newException(ValueError, "rewind: bad sparse header")
  let nblocks = (n + bs - 1) div bs
  let bitmapBytes = (nblocks + 7) div 8
  result = newString(n)          # zero-filled: unset blocks are already right
  var p = 8 + bitmapBytes
  for b in 0 ..< nblocks:
    if (uint8(src[8 + b div 8]) and (1'u8 shl (b mod 8))) != 0:
      let lo = b * bs
      let hi = min(lo + bs, n)
      if p + (hi - lo) > src.len:
        raise newException(ValueError, "rewind: sparse body past end")
      copyMem(addr result[lo], unsafeAddr src[p], hi - lo)
      p += hi - lo

proc encode_delta(prev, cur: string): string =
  ## Delta body reconstructs `prev` given `cur`: XOR over the overlapping
  ## prefix, raw tail where prev extends past cur (payload lengths vary
  ## slightly — e.g. the scheduler's event count)
  var body = prev
  rp(0 + 1):  # RpXor
    xor_bytes(body, cur, min(prev.len, cur.len))
  rp(0 + 2):  # RpCompress
    when defined(rewindsparse):
      result = compress(sparse_encode(body), BestSpeed, dfZlib)
    else:
      result = compress(body, BestSpeed, dfZlib)
  when defined(rewindprof):
    rewindprof_bytes[2] += result.len
    rewindprof_bytes[1] += body.len

proc decode_delta(cur, packed: string): string =
  when defined(rewindsparse):
    result = sparse_decode(uncompress(packed, dfZlib))
  else:
    result = uncompress(packed, dfZlib)
  xor_bytes(result, cur, min(result.len, cur.len))

proc oldest_id*(rw: Rewind): int =
  ## ID of the oldest still-reconstructable snapshot (-1 when empty).
  if rw.deltas.len > 0: rw.deltas[0].id else: rw.latest_id

proc newest_id*(rw: Rewind): int = rw.latest_id

proc drop_stale_sides(rw: Rewind) =
  ## Thumbnails and keyframes only mean anything while their snapshot is
  ## reconstructable. Both ends move: eviction raises the oldest ID, pop()
  ## lowers the newest one, and a side entry surviving either would hand out
  ## a picture (or an anchor) for a moment the ring can no longer produce.
  let lo = rw.oldest_id
  let hi = rw.latest_id
  while rw.thumbs.len > 0 and rw.thumbs.peekFirst.id < lo:
    rw.thumb_total -= rw.thumbs.popFirst().packed.len
  while rw.thumbs.len > 0 and rw.thumbs.peekLast.id > hi:
    rw.thumb_total -= rw.thumbs.popLast().packed.len
  while rw.keys.len > 0 and rw.keys.peekFirst.id < lo:
    rw.key_total -= rw.keys.popFirst().packed.len
  while rw.keys.len > 0 and rw.keys.peekLast.id > hi:
    rw.key_total -= rw.keys.popLast().packed.len

proc evict_oldest(rw: Rewind) =
  rw.total -= rw.deltas.popFirst().packed.len
  rw.drop_stale_sides()

proc push*(rw: Rewind; payload: string; thumb: proc(): RewindThumb = nil) =
  ## Record a new snapshot (frame-boundary payloads only). `thumb` is called
  ## only on the pushes that actually store one — the caller pays a downscale
  ## once a second, not once a push.
  let id = rw.next_id
  inc rw.next_id
  if rw.latest.len > 0:
    let packed = encode_delta(rw.latest, payload)
    rw.deltas.addLast(Delta(id: rw.latest_id, packed: packed))
    rw.total += packed.len
  rw.latest = payload
  rw.latest_id = id
  if rw.thumb_every > 0 and thumb != nil:
    if rw.thumb_due <= 0:
      rw.thumb_due = rw.thumb_every - 1
      var t: RewindThumb
      rp(3): t = thumb()
      if t.pixels.len > 0:
        # Raw BGR555 is 19-26 KB a picture, which on GB is THREE TIMES the
        # whole delta stream — the strip would have become the ring's biggest
        # tenant and cut GB history by ~3.6x at the same cap. Game frames are
        # flat-coloured, so BestSpeed takes them to 4% (GB) / 14-22% (GBA) of
        # raw for 0.06-0.09 ms once a second, and ~0.03 ms to inflate one when
        # the strip is read. Measured, both cores.
        var packed: seq[byte]
        rp(4): packed = compress(t.pixels, BestSpeed, dfZlib)
        rw.thumbs.addLast(ThumbEntry(id: id, w: t.w, h: t.h, packed: packed))
        rw.thumb_total += packed.len
    else:
      dec rw.thumb_due
  if rw.key_every > 0:
    if rw.key_due <= 0:
      rw.key_due = rw.key_every - 1
      var packed: string
      rp(5): packed = compress(payload, BestSpeed, dfZlib)
      rw.keys.addLast(KeyFrame(id: id, packed: packed))
      rw.key_total += packed.len
    else:
      dec rw.key_due
  rp(6):
    while rw.mem_used > rw.cap and rw.deltas.len > 0:
      rw.evict_oldest()

proc maybe_push*(rw: Rewind; payload: proc(): string;
                 thumb: proc(): RewindThumb = nil): bool =
  ## Call once per emulated frame; serializes every `interval` frames.
  ## Returns true when a snapshot was taken.
  inc rw.frame_count
  if rw.frame_count >= rw.interval:
    rw.frame_count = 0
    rp(7):
      var p: string
      rp(0): p = payload()
      when defined(rewindprof): rewindprof_bytes[0] += p.len
      rw.push(p, thumb)
    return true
  false

proc pop*(rw: Rewind): string =
  ## The next snapshot to apply when stepping backward ("" when exhausted).
  ## Each call rewinds history by one snapshot (`interval` frames).
  if rw.latest.len == 0:
    return ""
  result = rw.latest
  if rw.deltas.len > 0:
    let d = rw.deltas.popLast()
    rw.total -= d.packed.len
    rw.latest = decode_delta(rw.latest, d.packed)
    rw.latest_id = d.id
  else:
    rw.latest = ""
    rw.latest_id = -1
  rw.drop_stale_sides()
  # Rewinding discards the newest keyframe/thumbnail along with the snapshots
  # they belonged to. Re-anchor on the next push rather than finishing the
  # interrupted countdown, so the gap left behind can't grow past key_every.
  rw.key_due = 0
  rw.thumb_due = 0

# --- Non-destructive access (scrubber, bug report) ------------------------
# pop() consumes history; the scrubber needs to look at snapshots without
# disturbing the ring or the live core, so it can present a timeline and let
# the user pick one moment. These reconstruct snapshots from a local copy.

proc snapshot_interval*(rw: Rewind): int = rw.interval

iterator snapshots_newest_first*(rw: Rewind): string =
  ## Reconstruct every retained snapshot, newest to oldest, without mutating
  ## the ring. Snapshot 0 is the newest (== the live frame's last push).
  ## Walks the raw chain — this is what snapshot_at's keyframe shortcut has
  ## to agree with, byte for byte.
  if rw.latest.len > 0:
    var cur = rw.latest
    yield cur
    for i in countdown(rw.deltas.len - 1, 0):
      cur = decode_delta(cur, rw.deltas[i].packed)
      yield cur

proc find_delta_pos(rw: Rewind; id: int): int =
  ## Deque position of the delta that reconstructs `id`, or -1. IDs ascend
  ## across the deque (each push appends the previous latest_id, which is
  ## larger than every ID already in there), so this can binary search — and
  ## it must, because a pop/push seam leaves gaps in the ID sequence.
  var lo = 0
  var hi = rw.deltas.len - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    let v = rw.deltas[mid].id
    if v == id: return mid
    elif v < id: lo = mid + 1
    else: hi = mid - 1
  -1

proc index_of_id*(rw: Rewind; id: int): int =
  ## Steps back from the newest snapshot to `id`, or -1 when that ID has been
  ## evicted, rewound past, or never existed.
  if rw.latest.len == 0: return -1
  if id == rw.latest_id: return 0
  let pos = rw.find_delta_pos(id)
  if pos < 0: -1 else: rw.deltas.len - pos

proc id_at_index*(rw: Rewind; index: int): int =
  ## Absolute ID of the snapshot `index` steps back from the newest, or -1.
  if rw.latest.len == 0 or index < 0 or index > rw.deltas.len: return -1
  if index == 0: rw.latest_id else: rw.deltas[rw.deltas.len - index].id

proc reconstruct(rw: Rewind; target_pos: int): string =
  ## Snapshot at deque position `target_pos` (== deltas.len means `latest`),
  ## rebuilt from the cheapest anchor: `latest` costs one inflation per step
  ## back, a keyframe costs one inflation plus the steps from there. Both
  ## produce the same bytes; only the walk length differs.
  if target_pos == rw.deltas.len:
    return rw.latest
  var start_pos = rw.deltas.len
  var cur = rw.latest
  if rw.keys.len > 0:
    # Nearest keyframe at or newer than the target: keys ascend by ID, and
    # position order follows ID order, so binary search for the first key
    # whose ID is >= the target's.
    let target_id = rw.deltas[target_pos].id
    var lo = 0
    var hi = rw.keys.len - 1
    var pick = -1
    while lo <= hi:
      let mid = (lo + hi) div 2
      if rw.keys[mid].id >= target_id:
        pick = mid
        hi = mid - 1
      else:
        lo = mid + 1
    if pick >= 0:
      let kid = rw.keys[pick].id
      let kpos = if kid == rw.latest_id: rw.deltas.len else: rw.find_delta_pos(kid)
      # +1 for inflating the keyframe itself; skip it when `latest` is closer.
      if kpos >= target_pos and kpos + 1 < start_pos:
        start_pos = kpos
        cur = uncompress(rw.keys[pick].packed, dfZlib)
  for pos in countdown(start_pos - 1, target_pos):
    cur = decode_delta(cur, rw.deltas[pos].packed)
  cur

proc snapshot_at*(rw: Rewind; index: int): string =
  ## Snapshot `index` steps back from the newest (0 = newest), reconstructed
  ## non-destructively. Empty string when out of range.
  if rw.latest.len == 0 or index < 0 or index > rw.deltas.len:
    return ""
  rw.reconstruct(rw.deltas.len - index)

proc snapshot_by_id*(rw: Rewind; id: int): string =
  ## Same, addressed by absolute ID. Empty string when the ID is no longer
  ## retained — which is the point: an index would have kept resolving, to
  ## the wrong moment.
  let index = rw.index_of_id(id)
  if index < 0: "" else: rw.snapshot_at(index)

proc rewind_to_id*(rw: Rewind; id: int): string =
  ## Commit to a moment: return `id`'s payload and DISCARD every snapshot
  ## newer than it, so the ring's newest becomes `id`. That is what makes the
  ## scrubber's "you cannot move forward again" true at the ring level too —
  ## after this, hold-to-rewind continues backward from the chosen moment and
  ## the next push deltas against it, instead of both still reaching into a
  ## future the player just threw away.
  ##
  ## Empty string (and no mutation) when the ID is no longer retained.
  ##
  ## Equivalent to popping until latest_id == id, but without paying for it:
  ## pop() inflates one delta per step, so committing to the far end of a full
  ## ring would cost thousands of inflations. The payload comes from
  ## snapshot_by_id (keyframe-anchored, bounded by key_every) and the deltas in
  ## between are dropped unread — nothing needs to look at what it discards.
  let payload = rw.snapshot_by_id(id)
  if payload.len == 0: return ""
  # Deltas are keyed by the snapshot they RECONSTRUCT, so everything with an
  # ID >= the target reconstructs a moment at or after it: `id`'s own delta is
  # redundant once its payload is `latest`, and the newer ones are the future.
  while rw.deltas.len > 0 and rw.deltas.peekLast.id >= id:
    rw.total -= rw.deltas.popLast().packed.len
  rw.latest = payload
  rw.latest_id = id
  rw.drop_stale_sides()
  # Same re-anchoring as pop(): the discarded snapshots took their keyframe
  # and thumbnail countdowns with them.
  rw.key_due = 0
  rw.thumb_due = 0
  payload

# --- Thumbnail strip (captured at push time, not rebuilt) ----------------
# Constant cost per picture, independent of how deep in history it sits —
# which is the whole point: rendering the strip used to mean walking the
# entire delta chain.

proc thumb_count*(rw: Rewind): int = rw.thumbs.len

proc thumb_at*(rw: Rewind; i: int): RewindThumb =
  ## Thumbnail `i` counting back from the newest (0 = newest). Empty when out
  ## of range. Newest-first to match the scrubber's own ordering.
  if i < 0 or i >= rw.thumbs.len: return RewindThumb()
  let e = rw.thumbs[rw.thumbs.len - 1 - i]
  try:
    RewindThumb(w: e.w, h: e.h, pixels: uncompress(e.packed, dfZlib))
  except CatchableError:
    # In-process bytes; unreachable. An empty thumbnail drops one sample from
    # the strip rather than taking the tab down with it.
    RewindThumb()

proc thumb_id*(rw: Rewind; i: int): int =
  ## Absolute snapshot ID behind thumbnail `i` (newest-first), or -1.
  if i < 0 or i >= rw.thumbs.len: -1
  else: rw.thumbs[rw.thumbs.len - 1 - i].id
