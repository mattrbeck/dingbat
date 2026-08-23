# Input-rollback netplay session (GGPO-style) over the local 2-core link.
#
# Both peers run both GBA cores locally (link.nim resolves the SIO cable);
# only button inputs cross the network. Each frame the session feeds the
# local input plus a prediction of the remote input, and when a late remote
# input arrives mispredicted it restores that frame's checkpoint and
# re-simulates. Transport-agnostic: call `tick(localBits)` once per display
# frame and ship the returned frame's input; call `feed_remote` as peer
# inputs arrive. Determinism needs identical build + ROM + save on both
# sides and a deterministic RTC (enable_deterministic_rtc).

import ../common/input
import link
import gba

const INPUT_COUNT = 10  # Input enum cardinality (UP..R)

type
  RollbackStatus* = enum
    rbAdvanced   ## simulated one new frame
    rbStalled    ## at the prediction-window limit; wait for remote input

  RollbackSession* = ref object
    link*: Link
    local*: int                  ## local player index (0 or 1); remote = 1-local
    head*: int                   ## next frame to simulate; frames [0, head) done
    confirmed*: int              ## highest frame with real remote input (contiguous); -1 = none
    maxAhead*: int               ## head may lead confirmed by at most this (window)
    rollbacks*: int              ## telemetry: rollbacks performed
    stalls*: int                 ## telemetry: ticks that stalled on the window
    replaying*: bool             ## re-simulating rolled-back frames (transport mutes audio/render)
    localIn: seq[uint16]         ## local player's input per frame
    remoteIn: seq[uint16]        ## remote player's input per frame (valid iff remoteKnown)
    remoteKnown: seq[bool]
    usedRemote: seq[uint16]      ## remote input actually applied per frame (misprediction check)
    ring: seq[LinkSnapshot]      ## checkpoint ring; slot (f mod cap) holds state BEFORE frame f
    ringFrame: seq[int]          ## frame each ring slot currently holds (-1 = empty)
    cap: int                     ## ring capacity (> maxAhead so the frontier never evicts)

proc bit(v: uint16; i: int): bool {.inline.} = ((v shr i) and 1) != 0

proc new_rollback_session*(link: Link; local: int; maxAhead = 12): RollbackSession =
  ## `link` must be a fresh 2-core Link at frame 0. `local` is the core this
  ## peer's buttons drive. `maxAhead` bounds prediction depth; pick it above
  ## the round-trip in frames.
  doAssert local in {0, 1}, "local player must be 0 or 1"
  doAssert link.cores.len == 2, "rollback session needs exactly two cores"
  let cap = maxAhead + 4
  result = RollbackSession(
    link: link, local: local, head: 0, confirmed: -1, maxAhead: maxAhead,
    ring: newSeq[LinkSnapshot](cap), ringFrame: newSeq[int](cap), cap: cap)
  for i in 0 ..< cap: result.ringFrame[i] = -1

proc grow(sess: RollbackSession; f: int) =
  if f >= sess.localIn.len:
    let n = f + 1
    sess.localIn.setLen(n)
    sess.remoteIn.setLen(n)
    sess.remoteKnown.setLen(n)
    sess.usedRemote.setLen(n)

proc apply_inputs(sess: RollbackSession; f: int) =
  # Remote word: the real input if known, else the last confirmed remote
  # input (button states change rarely, so the prediction usually holds).
  let lb = sess.localIn[f]
  let rb =
    if sess.remoteKnown[f]: sess.remoteIn[f]
    elif sess.confirmed >= 0: sess.remoteIn[sess.confirmed]
    else: 0'u16
  sess.usedRemote[f] = rb
  let lc = sess.link.cores[sess.local]
  let rc = sess.link.cores[1 - sess.local]
  for i in 0 ..< INPUT_COUNT:
    lc.handle_input(Input(i), lb.bit(i))
    rc.handle_input(Input(i), rb.bit(i))

proc store_ckpt(sess: RollbackSession; f: int) =
  let idx = f mod sess.cap
  sess.ring[idx] = sess.link.capture_state()
  sess.ringFrame[idx] = f

proc load_ckpt(sess: RollbackSession; f: int) =
  let idx = f mod sess.cap
  doAssert sess.ringFrame[idx] == f,
    "rollback: checkpoint for frame " & $f & " evicted (window too small?)"
  sess.link.restore_state(sess.ring[idx])

proc sim(sess: RollbackSession; f: int) =
  # Checkpoint the state entering frame f, then apply its inputs and step.
  sess.store_ckpt(f)
  sess.apply_inputs(f)
  sess.link.step_frame()

proc reconcile(sess: RollbackSession) =
  ## Extend the confirmed frontier over contiguously-known remote frames; if
  ## any was mispredicted, restore the frontier checkpoint and re-simulate to
  ## `head` with the corrected inputs.
  var g = sess.confirmed
  while g + 1 < sess.head and g + 1 < sess.remoteKnown.len and sess.remoteKnown[g + 1]:
    inc g
  if g <= sess.confirmed: return
  var mispredicted = false
  for k in sess.confirmed + 1 .. g:
    if sess.usedRemote[k] != sess.remoteIn[k]: mispredicted = true; break
  let base = sess.confirmed        # frontier checkpoint is the state before base+1
  sess.confirmed = g
  if mispredicted:
    inc sess.rollbacks
    sess.load_ckpt(base + 1)
    sess.replaying = true
    for k in base + 1 ..< sess.head: sess.sim(k)
    sess.replaying = false

proc feed_remote*(sess: RollbackSession; frame: int; bits: uint16) =
  ## Ingest the remote input for `frame`: reconciles an already-predicted
  ## frame, buffers a future one. Duplicates are ignored.
  if frame < 0: return
  sess.grow(frame)
  if sess.remoteKnown[frame]: return
  sess.remoteIn[frame] = bits
  sess.remoteKnown[frame] = true
  sess.reconcile()

proc tick*(sess: RollbackSession; localBits: uint16): RollbackStatus =
  ## Simulate one frame with the local input and a remote prediction. Stalls
  ## (rbStalled) once `maxAhead` frames past the confirmed remote input; the
  ## transport re-presents the last frame. On rbAdvanced the caller ships
  ## (`head-1`, localBits) to the peer.
  if sess.head - sess.confirmed > sess.maxAhead:
    inc sess.stalls
    return rbStalled
  sess.grow(sess.head)
  sess.localIn[sess.head] = localBits
  sess.sim(sess.head)
  inc sess.head
  rbAdvanced

proc checksum*(sess: RollbackSession): uint64 =
  ## Desync-detection fingerprint; compare only at a confirmed frame.
  sess.link.state_checksum()
