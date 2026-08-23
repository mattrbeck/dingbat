# Rewind history: a bounded ring of compressed XOR deltas between consecutive
# state snapshots, plus the newest snapshot kept whole. Rewind only steps
# backward from the newest state, so each delta decodes against its successor:
# prev = inflate(delta) XOR cur. Consecutive snapshots differ in a small
# fraction of bytes, so deltas deflate to a few percent of the payload.
#
# For the scrubber: absolute snapshot IDs (positional indexes shift under
# eviction; IDs are never reused, so a stale ID resolves to "gone"), thumbnails
# captured at push time (rendering the strip from history would walk every
# delta), and keyframes every `key_every` pushes bounding a seek to that many
# inflations. Thumbnails and keyframes count toward mem_used and are evicted
# with the deltas they belong to: the cap is a real budget (16 MB on iOS,
# where memory pressure gets the wasm JIT demoted).

import std/deques
import zippy

when defined(rewindprof):
  # -d:rewindprof: per-snapshot cost in nanoseconds and call counts, printed
  # by tests/dingbat_bench.nim.
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
    ## One downscaled frame captured at push time: little-endian BGR555, 2
    ## bytes per pixel, the save-state thumbnail trailer's layout.
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
    ## so a seek costs at most ~60 inflations.

proc thumbs_per_second(interval: int): int =
  ## One thumbnail per second of history (pushes are `interval` frames apart
  ## at ~60 fps); the strip is sampled down to ~48 for display anyway.
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
  # next_id survives: an ID handed out before the clear must not come back
  # attached to a different moment.

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


# Sparse-block pre-pass on the delta (the ring's codec). The delta is an XOR,
# so "unchanged" is a zero byte and the payload is ~99% zeros; a bitmap of
# which 64-byte blocks contain any non-zero byte, followed by only those
# blocks, skips the rest with a word-at-a-time scan, and zlib then compresses
# what survives. Format: u32 original length, u32 block size, ceil(nblocks/8)
# bitmap bytes, then the set blocks back to back (the last may be short; its
# length follows from the original length). Smaller and faster than plain
# zlib, by far the most under wasm (the bake-off in common/rewind_codecs.nim
# runs in-page for that reason). In-process only: nothing persists or
# transmits a delta, so there is no format version.

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
  ## prefix, raw tail where prev extends past cur.
  var body = prev
  rp(0 + 1):  # RpXor
    xor_bytes(body, cur, min(prev.len, cur.len))
  rp(0 + 2):  # RpCompress
    result = compress(sparse_encode(body), BestSpeed, dfZlib)
  when defined(rewindprof):
    rewindprof_bytes[2] += result.len
    rewindprof_bytes[1] += body.len

proc decode_delta(cur, packed: string): string =
  result = sparse_decode(uncompress(packed, dfZlib))
  xor_bytes(result, cur, min(result.len, cur.len))

proc oldest_id*(rw: Rewind): int =
  ## ID of the oldest still-reconstructable snapshot (-1 when empty).
  if rw.deltas.len > 0: rw.deltas[0].id else: rw.latest_id

proc newest_id*(rw: Rewind): int = rw.latest_id

proc drop_stale_sides(rw: Rewind) =
  ## Thumbnails and keyframes only mean anything while their snapshot is
  ## reconstructable; eviction raises the oldest ID and pop() lowers the newest.
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
  ## only on the pushes that store one.
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
        # Raw BGR555 is 19-26 KB a picture, on GB three times the whole delta
        # stream; game frames are flat-coloured, so BestSpeed takes them to
        # 4-22% of raw.
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
  # Rewinding discards the newest keyframe/thumbnail with their snapshots;
  # re-anchor on the next push so the gap cannot grow past key_every.
  rw.key_due = 0
  rw.thumb_due = 0

# --- Non-destructive access (scrubber, bug report): reconstruct snapshots
# without disturbing the ring or the live core.

proc snapshot_interval*(rw: Rewind): int = rw.interval

iterator snapshots_newest_first*(rw: Rewind): string =
  ## Every retained snapshot, newest to oldest, without mutating the ring.
  ## Walks the raw chain; snapshot_at's keyframe shortcut must agree byte for
  ## byte.
  if rw.latest.len > 0:
    var cur = rw.latest
    yield cur
    for i in countdown(rw.deltas.len - 1, 0):
      cur = decode_delta(cur, rw.deltas[i].packed)
      yield cur

proc find_delta_pos(rw: Rewind; id: int): int =
  ## Deque position of the delta that reconstructs `id`, or -1. IDs ascend
  ## across the deque but a pop/push seam leaves gaps, so binary search.
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
  ## Snapshot at deque position `target_pos` (== deltas.len means `latest`)
  ## from the cheapest anchor: `latest`, or the nearest newer keyframe.
  if target_pos == rw.deltas.len:
    return rw.latest
  var start_pos = rw.deltas.len
  var cur = rw.latest
  if rw.keys.len > 0:
    # Nearest keyframe at or newer than the target (keys ascend by ID)
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
  ## Same, by absolute ID; empty when the ID is no longer retained.
  let index = rw.index_of_id(id)
  if index < 0: "" else: rw.snapshot_at(index)

proc rewind_to_id*(rw: Rewind; id: int): string =
  ## Commit to a moment: return `id`'s payload and discard every newer
  ## snapshot, so hold-to-rewind continues backward from it and the next push
  ## deltas against it. Empty string (no mutation) when the ID is gone. Unlike
  ## popping there, the payload comes keyframe-anchored and the discarded
  ## deltas are dropped unread.
  let payload = rw.snapshot_by_id(id)
  if payload.len == 0: return ""
  # Deltas are keyed by the snapshot they reconstruct: `id`'s own is redundant
  # once its payload is `latest`, and the newer ones are the future.
  while rw.deltas.len > 0 and rw.deltas.peekLast.id >= id:
    rw.total -= rw.deltas.popLast().packed.len
  rw.latest = payload
  rw.latest_id = id
  rw.drop_stale_sides()
  # Same re-anchoring as pop().
  rw.key_due = 0
  rw.thumb_due = 0
  payload

# --- Thumbnail strip (captured at push time): constant cost per picture.

proc thumb_count*(rw: Rewind): int = rw.thumbs.len

proc thumb_at*(rw: Rewind; i: int): RewindThumb =
  ## Thumbnail `i` counting back from the newest (0 = newest). Empty when out
  ## of range. Newest-first to match the scrubber's own ordering.
  if i < 0 or i >= rw.thumbs.len: return RewindThumb()
  let e = rw.thumbs[rw.thumbs.len - 1 - i]
  try:
    RewindThumb(w: e.w, h: e.h, pixels: uncompress(e.packed, dfZlib))
  except CatchableError:
    # In-process bytes; unreachable. An empty thumbnail drops one strip sample.
    RewindThumb()

proc thumb_id*(rw: Rewind; i: int): int =
  ## Absolute snapshot ID behind thumbnail `i` (newest-first), or -1.
  if i < 0 or i >= rw.thumbs.len: -1
  else: rw.thumbs[rw.thumbs.len - 1 - i].id
