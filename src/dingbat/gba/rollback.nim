# Input-rollback netplay session (GGPO-style) over the local 2-core link.
#
# Both peers run BOTH GBA cores locally (link.nim resolves the SIO cable at full
# speed); only the two players' button inputs cross the network. Each peer owns
# one RollbackSession: it drives its Link one frame at a time, feeding the local
# player's real input and a PREDICTION of the remote player's input, and rolls
# back + re-simulates when a late remote input arrives mispredicted. The result
# is bit-identical to knowing every input upfront (proven by the --mode=rollback
# harness), so both peers stay in lockstep with no per-round RTT — latency only
# delays the remote input, which prediction hides.
#
# Transport-agnostic (like netcore): the transport calls `tick(localBits)` once
# per display frame and ships the returned frame's input to the peer, and calls
# `feed_remote(frame, bits)` as peer inputs arrive. Determinism prerequisites:
# identical build + ROM + save on both sides, and a deterministic RTC
# (enable_deterministic_rtc) — the SIO cable and everything else is local.

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
    replaying*: bool             ## true while re-simulating rolled-back frames
                                 ## (the transport suppresses audio/render churn)
    localIn: seq[uint16]         ## local player's input per frame
    remoteIn: seq[uint16]        ## remote player's input per frame (valid iff remoteKnown)
    remoteKnown: seq[bool]
    usedRemote: seq[uint16]      ## remote input actually applied per frame (misprediction check)
    ring: seq[LinkSnapshot]      ## checkpoint ring; slot (f mod cap) holds state BEFORE frame f
    ringFrame: seq[int]          ## frame each ring slot currently holds (-1 = empty)
    cap: int                     ## ring capacity (> maxAhead so the frontier never evicts)

proc bit(v: uint16; i: int): bool {.inline.} = ((v shr i) and 1) != 0

proc new_rollback_session*(link: Link; local: int; maxAhead = 12): RollbackSession =
  ## `link` must be a fresh 2-core Link at frame 0 (both cores post_init from the
  ## two players' ROM+save, deterministic RTC set). `local` is which core this
  ## peer's buttons drive. `maxAhead` bounds prediction depth — pick it above the
  ## round-trip in frames (50 ms ≈ 3 frames; 12 leaves comfortable margin).
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
  # Remote word: the real input if we have it (even ahead of the confirmed
  # frontier — it just hasn't been reconciled yet), else predict "same as the
  # last confirmed remote input" (button states change rarely, so this hits).
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
  # Snapshot the state ENTERING frame f (so a rollback to f restores here), then
  # apply that frame's inputs and advance one video frame.
  sess.store_ckpt(f)
  sess.apply_inputs(f)
  sess.link.step_frame()

proc reconcile(sess: RollbackSession) =
  ## Extend the confirmed frontier over contiguously-known remote frames. If any
  ## of them was mispredicted, restore the frontier checkpoint and re-simulate
  ## forward to `head` with the corrected inputs. Only a genuine misprediction
  ## (the remote player actually changed buttons) costs a rollback.
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
  ## Ingest a remote player's input for `frame` (from the transport). May be for
  ## a frame we already predicted (→ reconcile/rollback) or a future frame we
  ## haven't reached yet (→ buffered until we do). Duplicates are ignored.
  if frame < 0: return
  sess.grow(frame)
  if sess.remoteKnown[frame]: return
  sess.remoteIn[frame] = bits
  sess.remoteKnown[frame] = true
  sess.reconcile()

proc tick*(sess: RollbackSession; localBits: uint16): RollbackStatus =
  ## Simulate one presentation frame with the local input and prediction. If we
  ## are already `maxAhead` frames past the confirmed remote input, STALL instead
  ## of predicting deeper (bounds rollback distance) — the transport should just
  ## re-present the last frame and try again once remote input arrives. On
  ## rbAdvanced the caller ships (`head-1`, localBits) to the peer.
  if sess.head - sess.confirmed > sess.maxAhead:
    inc sess.stalls
    return rbStalled
  sess.grow(sess.head)
  sess.localIn[sess.head] = localBits
  sess.sim(sess.head)
  inc sess.head
  rbAdvanced

proc checksum*(sess: RollbackSession): uint64 =
  ## State fingerprint for periodic desync detection between peers. Compare only
  ## at a CONFIRMED frame (both peers agree there); a mismatch means a
  ## determinism gap — surface it instead of letting the trade corrupt.
  sess.link.state_checksum()

# Rendering is the transport's job: it reads sess.link.cores[player] and
# converts the native-format framebuffer to RGBA (the wasm layer already does
# this for local 2P mode). A peer shows its OWN player (sess.local).
