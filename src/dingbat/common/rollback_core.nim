# Input-rollback netplay session (GGPO-style), shared by both cores.
#
# Both peers run BOTH emulated cores locally (each core's link.nim resolves the
# cable at full speed); only the two players' button inputs cross the network.
# Each peer owns one session: it drives its link one frame at a time, feeding
# the local player's real input and a PREDICTION of the remote player's input,
# and rolls back + re-simulates when a late remote input arrives mispredicted.
# The result is bit-identical to knowing every input upfront (proven by the
# --mode=rollback harness), so both peers stay in lockstep with no per-round
# RTT — latency only delays the remote input, which prediction hides.
#
# Transport-agnostic: the transport calls `tick(local_bits)` once per display
# frame and ships the returned frame's input to the peer, and calls
# `feed_remote(frame, bits)` as peer inputs arrive. Determinism prerequisites:
# identical build + ROM + save on both sides, and a deterministic clock (the
# GBA needs enable_deterministic_rtc; the GB's MBC3 RTC already is).
#
# This is generic over the link and snapshot types rather than duplicated per
# core: the GB and GBA versions were previously the same file twice, differing
# only in those two type names. Each core's rollback.nim instantiates it and
# re-exports the concrete names. The link type L must provide:
#
#   cores: seq[Core]  (each with handle_input)
#   capture_state(): S
#   restore_state(S)
#   step_frame()
#   state_checksum(): uint64

import input
import util

const INPUT_COUNT* = 10  # Input enum cardinality (UP..R)

type
  RollbackStatus* = enum
    rbAdvanced   ## simulated one new frame
    rbStalled    ## at the prediction-window limit; wait for remote input

  RollbackSessionBase*[L, S] = ref object
    link*: L
    local*: int                  ## local player index (0 or 1); remote = 1-local
    head*: int                   ## next frame to simulate; frames [0, head) done
    confirmed*: int              ## highest frame with real remote input (contiguous); -1 = none
    max_ahead*: int              ## prediction window: head may lead confirmed by this many
    rollbacks*: int              ## telemetry: rollbacks performed
    stalls*: int                 ## telemetry: ticks that stalled on the window
    replaying*: bool             ## true while re-simulating rolled-back frames
                                 ## (the transport suppresses audio/render churn)
    local_in: seq[uint16]        ## local player's input per frame
    remote_in: seq[uint16]       ## remote player's input per frame (valid iff remote_known)
    remote_known: seq[bool]
    used_remote: seq[uint16]     ## what we actually fed for the remote player
    ring: seq[S]                 ## checkpoint ring; slot (f mod cap) holds state BEFORE frame f
    ring_frame: seq[int]         ## which frame each ring slot holds (-1 = empty)
    cap: int

proc init_session*[L, S](link: L; local: int; max_ahead: int):
    RollbackSessionBase[L, S] =
  ## `link` must be a fresh 2-core link at frame 0 (both cores post_init from
  ## the two players' ROM+save). `local` is which core this peer's buttons
  ## drive. `max_ahead` bounds prediction depth — pick it above the round-trip
  ## in frames (50 ms ~ 3 frames; 12 leaves comfortable margin).
  doAssert local in 0 .. 1, "rollback local player must be 0 or 1"
  doAssert link.cores.len == 2, "rollback session needs exactly two cores"
  let cap = max_ahead + 4
  result = RollbackSessionBase[L, S](
    link: link, local: local, head: 0, confirmed: -1, max_ahead: max_ahead,
    ring: newSeq[S](cap), ring_frame: newSeq[int](cap), cap: cap)
  for i in 0 ..< cap: result.ring_frame[i] = -1

proc grow[L, S](sess: RollbackSessionBase[L, S]; f: int) =
  if f >= sess.local_in.len:
    let n = f + 1
    sess.local_in.setLen(n)
    sess.remote_in.setLen(n)
    sess.remote_known.setLen(n)
    sess.used_remote.setLen(n)

proc apply_inputs[L, S](sess: RollbackSessionBase[L, S]; f: int) =
  # Remote word: the real input if we have it (even ahead of the confirmed
  # frontier — it just hasn't been reconciled yet), else predict "same as the
  # last confirmed remote input" (button states change rarely, so this hits).
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

proc store_ckpt[L, S](sess: RollbackSessionBase[L, S]; f: int) =
  let idx = f mod sess.cap
  sess.ring[idx] = sess.link.capture_state()
  sess.ring_frame[idx] = f

proc load_ckpt[L, S](sess: RollbackSessionBase[L, S]; f: int) =
  let idx = f mod sess.cap
  doAssert sess.ring_frame[idx] == f,
    "rollback: checkpoint for frame " & $f & " evicted (window too small?)"
  sess.link.restore_state(sess.ring[idx])

proc sim[L, S](sess: RollbackSessionBase[L, S]; f: int) =
  # Snapshot the state ENTERING frame f (so a rollback to f restores here), then
  # apply that frame's inputs and advance one video frame.
  sess.store_ckpt(f)
  sess.apply_inputs(f)
  sess.link.step_frame()

proc reconcile[L, S](sess: RollbackSessionBase[L, S]) =
  ## Extend the confirmed frontier over contiguously-known remote frames. If any
  ## of them was mispredicted, restore the frontier checkpoint and re-simulate
  ## forward to `head` with the corrected inputs. Only a genuine misprediction
  ## (the remote player actually changed buttons) costs a rollback.
  var g = sess.confirmed
  while g + 1 < sess.head and g + 1 < sess.remote_known.len and sess.remote_known[g + 1]:
    inc g
  if g <= sess.confirmed: return
  var mispredicted = false
  for k in sess.confirmed + 1 .. g:
    if sess.used_remote[k] != sess.remote_in[k]: mispredicted = true; break
  let base = sess.confirmed        # frontier checkpoint is the state before base+1
  sess.confirmed = g
  if mispredicted:
    inc sess.rollbacks
    sess.load_ckpt(base + 1)
    sess.replaying = true
    for k in base + 1 ..< sess.head: sess.sim(k)
    sess.replaying = false

proc feed_remote*[L, S](sess: RollbackSessionBase[L, S]; frame: int; bits: uint16) =
  ## Ingest a remote player's input for `frame` (from the transport). May be for
  ## a frame we already predicted (→ reconcile/rollback) or a future frame we
  ## haven't reached yet (→ buffered until we do). Duplicates are ignored.
  if frame < 0: return
  sess.grow(frame)
  if sess.remote_known[frame]: return
  sess.remote_in[frame] = bits
  sess.remote_known[frame] = true
  sess.reconcile()

proc tick*[L, S](sess: RollbackSessionBase[L, S]; local_bits: uint16): RollbackStatus =
  ## Simulate one presentation frame with the local input and prediction. If we
  ## are already `max_ahead` frames past the confirmed remote input, STALL instead
  ## of predicting deeper (bounds rollback distance) — the transport should just
  ## re-present the last frame and try again once remote input arrives. On
  ## rbAdvanced the caller ships (`head-1`, local_bits) to the peer.
  if sess.head - sess.confirmed > sess.max_ahead:
    inc sess.stalls
    return rbStalled
  sess.grow(sess.head)
  sess.local_in[sess.head] = local_bits
  sess.sim(sess.head)
  inc sess.head
  rbAdvanced

proc checksum*[L, S](sess: RollbackSessionBase[L, S]): uint64 =
  ## State fingerprint for periodic desync detection between peers. Compare only
  ## at a CONFIRMED frame (both peers agree there); a mismatch means a
  ## determinism gap — surface it instead of letting the trade corrupt.
  sess.link.state_checksum()

# Rendering is the transport's job: it reads sess.link.cores[player] and
# converts the core's framebuffer to RGBA. A peer shows its OWN player
# (sess.local).
