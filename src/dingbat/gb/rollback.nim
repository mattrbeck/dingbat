# Input-rollback netplay session for GB/GBC (GGPO-style) over the local 2-core
# GB link. The GB analog of gba/rollback.nim — see there for the full rationale.
#
# Both peers run BOTH GB cores locally (link.nim resolves the serial cable at
# full speed); only the two players' button inputs cross the network. Each peer
# owns one RollbackSession: it drives its GbLink one frame at a time, feeding the
# local player's real input and a PREDICTION of the remote player's input, and
# rolls back + re-simulates when a late remote input arrives mispredicted.
#
# Transport-agnostic: the transport calls `tick(local_bits)` once per display
# frame and ships the returned frame's input to the peer, and calls
# `feed_remote(frame, bits)` as peer inputs arrive. Determinism prerequisites:
# identical build + ROM + save on both sides (the RTC — MBC3 — is already
# deterministic in the GB core).

import ../common/input
import link
import gb

const INPUT_COUNT = 10  # Input enum cardinality (UP..R)

type
  GbRbStatus* = enum
    grbAdvanced   ## simulated one new frame
    grbStalled    ## at the prediction-window limit; wait for remote input

  GbRollbackSession* = ref object
    link*: GbLink
    local*: int                  ## local player index (0 or 1); remote = 1-local
    head*: int                   ## next frame to simulate; frames [0, head) done
    confirmed*: int              ## highest frame with real remote input (contiguous); -1 = none
    max_ahead*: int               ## head may lead confirmed by at most this (window)
    rollbacks*: int              ## telemetry: rollbacks performed
    stalls*: int                 ## telemetry: ticks that stalled on the window
    replaying*: bool             ## true while re-simulating rolled-back frames
    local_in: seq[uint16]         ## local player's input per frame
    remote_in: seq[uint16]        ## remote player's input per frame (valid iff remote_known)
    remote_known: seq[bool]
    used_remote: seq[uint16]      ## remote input actually applied per frame (misprediction check)
    ring: seq[GbLinkSnapshot]    ## checkpoint ring; slot (f mod cap) holds state BEFORE frame f
    ring_frame: seq[int]          ## frame each ring slot currently holds (-1 = empty)
    cap: int                     ## ring capacity (> max_ahead so the frontier never evicts)

proc bit(v: uint16; i: int): bool {.inline.} = ((v shr i) and 1) != 0

proc new_gb_rollback_session*(link: GbLink; local: int; max_ahead = 12): GbRollbackSession =
  ## `link` must be a fresh 2-core GbLink at frame 0 (both cores post_init from
  ## the two players' ROM+save). `local` is which core this peer's buttons drive.
  ## `max_ahead` bounds prediction depth — pick it above the round-trip in frames.
  doAssert local in {0, 1}, "local player must be 0 or 1"
  doAssert link.cores.len == 2, "rollback session needs exactly two cores"
  let cap = max_ahead + 4
  result = GbRollbackSession(
    link: link, local: local, head: 0, confirmed: -1, max_ahead: max_ahead,
    ring: newSeq[GbLinkSnapshot](cap), ring_frame: newSeq[int](cap), cap: cap)
  for i in 0 ..< cap: result.ring_frame[i] = -1

proc grow(sess: GbRollbackSession; f: int) =
  if f >= sess.local_in.len:
    let n = f + 1
    sess.local_in.setLen(n)
    sess.remote_in.setLen(n)
    sess.remote_known.setLen(n)
    sess.used_remote.setLen(n)

proc apply_inputs(sess: GbRollbackSession; f: int) =
  # Remote word: the real input if we have it (even ahead of the confirmed
  # frontier), else predict "same as the last confirmed remote input".
  let lb = sess.local_in[f]
  let rb =
    if sess.remote_known[f]: sess.remote_in[f]
    elif sess.confirmed >= 0: sess.remote_in[sess.confirmed]
    else: 0'u16
  sess.used_remote[f] = rb
  let lc = sess.link.cores[sess.local]
  let rc = sess.link.cores[1 - sess.local]
  for i in 0 ..< INPUT_COUNT:
    lc.handle_input(Input(i), lb.bit(i))
    rc.handle_input(Input(i), rb.bit(i))

proc store_ckpt(sess: GbRollbackSession; f: int) =
  let idx = f mod sess.cap
  sess.ring[idx] = sess.link.capture_state()
  sess.ring_frame[idx] = f

proc load_ckpt(sess: GbRollbackSession; f: int) =
  let idx = f mod sess.cap
  doAssert sess.ring_frame[idx] == f,
    "rollback: checkpoint for frame " & $f & " evicted (window too small?)"
  sess.link.restore_state(sess.ring[idx])

proc sim(sess: GbRollbackSession; f: int) =
  # Snapshot the state ENTERING frame f, apply that frame's inputs, advance one
  # video frame.
  sess.store_ckpt(f)
  sess.apply_inputs(f)
  sess.link.step_frame()

proc reconcile(sess: GbRollbackSession) =
  ## Extend the confirmed frontier over contiguously-known remote frames, rolling
  ## back + re-simulating only on a genuine misprediction.
  var g = sess.confirmed
  while g + 1 < sess.head and g + 1 < sess.remote_known.len and sess.remote_known[g + 1]:
    inc g
  if g <= sess.confirmed: return
  var mispredicted = false
  for k in sess.confirmed + 1 .. g:
    if sess.used_remote[k] != sess.remote_in[k]: mispredicted = true; break
  let base = sess.confirmed
  sess.confirmed = g
  if mispredicted:
    inc sess.rollbacks
    sess.load_ckpt(base + 1)
    sess.replaying = true
    for k in base + 1 ..< sess.head: sess.sim(k)
    sess.replaying = false

proc feed_remote*(sess: GbRollbackSession; frame: int; bits: uint16) =
  ## Ingest a remote player's input for `frame`. May reconcile/rollback a
  ## predicted frame or buffer a future one. Duplicates ignored.
  if frame < 0: return
  sess.grow(frame)
  if sess.remote_known[frame]: return
  sess.remote_in[frame] = bits
  sess.remote_known[frame] = true
  sess.reconcile()

proc tick*(sess: GbRollbackSession; local_bits: uint16): GbRbStatus =
  ## Simulate one presentation frame with the local input and prediction. STALL
  ## if we are already `max_ahead` past the confirmed remote input. On grbAdvanced
  ## the caller ships (`head-1`, local_bits) to the peer.
  if sess.head - sess.confirmed > sess.max_ahead:
    inc sess.stalls
    return grbStalled
  sess.grow(sess.head)
  sess.local_in[sess.head] = local_bits
  sess.sim(sess.head)
  inc sess.head
  grbAdvanced

proc checksum*(sess: GbRollbackSession): uint64 =
  ## State fingerprint for periodic desync detection between peers. Compare only
  ## at a CONFIRMED frame; a mismatch means a determinism gap.
  sess.link.state_checksum()

# Rendering is the transport's job: it reads sess.link.cores[player] and converts
# the 160x144 BGR555 framebuffer to RGBA. A peer shows its OWN player (sess.local).
