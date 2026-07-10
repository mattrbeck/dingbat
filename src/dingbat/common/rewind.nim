# Rewind history: a bounded ring of zlib-compressed XOR deltas between
# consecutive state snapshots, plus the newest snapshot kept whole.
#
# Rewind only ever steps backward from the newest state, so each entry needs
# to decode against its *successor* only: prev = inflate(delta) XOR cur.
# Popping is O(delta) with no keyframes, and because consecutive snapshots
# differ in a small fraction of bytes (most emulator memory is static over a
# 10-frame window), deltas deflate to a few percent of the ~500 KB payload —
# that is what makes long histories affordable.

import std/deques
import zippy

type
  Rewind* = ref object
    deltas: Deque[string]  # compressed XOR delta bodies, oldest first
    latest: string         # newest snapshot payload, uncompressed
    total: int             # compressed bytes retained across deltas
    cap: int               # eviction threshold for total
    interval: int          # emulated frames between snapshots
    frame_count: int

const
  REWIND_CAP_BYTES* = 64 * 1024 * 1024
  REWIND_INTERVAL*  = 10  # ~6 snapshots/second

proc new_rewind*(cap = REWIND_CAP_BYTES; interval = REWIND_INTERVAL): Rewind =
  Rewind(cap: cap, interval: interval)

proc len*(rw: Rewind): int =
  rw.deltas.len + (if rw.latest.len > 0: 1 else: 0)

proc mem_used*(rw: Rewind): int =
  rw.total + rw.latest.len

proc clear*(rw: Rewind) =
  rw.deltas.clear()
  rw.latest = ""
  rw.total = 0
  rw.frame_count = 0

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

proc encode_delta(prev, cur: string): string =
  ## Delta body reconstructs `prev` given `cur`: XOR over the overlapping
  ## prefix, raw tail where prev extends past cur (payload lengths vary
  ## slightly — e.g. the scheduler's event count)
  var body = prev
  xor_bytes(body, cur, min(prev.len, cur.len))
  compress(body, BestSpeed, dfZlib)

proc decode_delta(cur, packed: string): string =
  result = uncompress(packed, dfZlib)
  xor_bytes(result, cur, min(result.len, cur.len))

proc push*(rw: Rewind; payload: string) =
  ## Record a new snapshot (frame-boundary payloads only)
  if rw.latest.len > 0:
    let packed = encode_delta(rw.latest, payload)
    rw.deltas.addLast(packed)
    rw.total += packed.len
    while rw.total > rw.cap and rw.deltas.len > 0:
      rw.total -= rw.deltas.popFirst().len
  rw.latest = payload

proc maybe_push*(rw: Rewind; payload: proc(): string): bool =
  ## Call once per emulated frame; serializes every `interval` frames.
  ## Returns true when a snapshot was taken.
  inc rw.frame_count
  if rw.frame_count >= rw.interval:
    rw.frame_count = 0
    rw.push(payload())
    return true
  false

proc pop*(rw: Rewind): string =
  ## The next snapshot to apply when stepping backward ("" when exhausted).
  ## Each call rewinds history by one snapshot (`interval` frames).
  if rw.latest.len == 0:
    return ""
  result = rw.latest
  if rw.deltas.len > 0:
    let packed = rw.deltas.popLast()
    rw.total -= packed.len
    rw.latest = decode_delta(rw.latest, packed)
  else:
    rw.latest = ""
