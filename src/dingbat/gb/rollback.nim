# Input-rollback netplay (GGPO-style) over the local 2-core GB link, like
# gba/rollback.nim. Both peers run both cores; only inputs cross the network.
# The transport calls `tick(localBits)` per frame and ships the result, and
# `feed_remote(frame, bits)` as peer inputs arrive. Needs identical build, ROM
# and save on both sides.

import ../common/input
import ../common/linksync
import link
import gb

const INPUT_COUNT = 10  # Input enum cardinality (UP..R)

type
  HeldKeys = object
    ## What a state image leaves out of a joypad (live host input, and the
    ## interrupt edge detector a load re-seeds from it). A checkpoint keeps
    ## them: restored from the image alone, the detector would be seeded from
    ## the keys of the newest frame simulated, and the re-simulated frame's
    ## press would raise the joypad interrupt (IF bit 4) or not depending on
    ## when the rollback came, so two peers' cores drift apart.
    down, up, left, right, start, jselect, b, a: bool
    prev_lines: uint8

  GbRbStatus* = enum
    grbAdvanced   ## simulated one new frame
    grbStalled    ## at the prediction-window limit; wait for remote input

  GbRollbackSession* = ref object
    link*: GbLink
    local*: int                  ## local player index (0 or 1); remote = 1-local
    head*: int                   ## next frame to simulate; frames [0, head) done
    confirmed*: int              ## highest frame with real remote input (contiguous); -1 = none
    maxAhead*: int               ## head may lead confirmed by at most this (window)
    rollbacks*: int              ## telemetry: rollbacks performed
    stalls*: int                 ## telemetry: ticks that stalled on the window
    replaying*: bool             ## true while re-simulating rolled-back frames
    localIn: seq[uint16]         ## local player's input per frame
    remoteIn: seq[uint16]        ## remote player's input per frame (valid iff remoteKnown)
    remoteKnown: seq[bool]
    usedRemote: seq[uint16]      ## remote input actually applied per frame (misprediction check)
    ring: seq[GbLinkSnapshot]    ## checkpoint ring; slot (f mod cap) holds state BEFORE frame f
    ringFrame: seq[int]          ## frame each ring slot currently holds (-1 = empty)
    ringKeys: seq[array[2, HeldKeys]]  ## each core's HeldKeys entering that frame
    cap: int                     ## ring capacity (> maxAhead so the frontier never evicts)
    syncEvery*: int              ## fingerprint every this many frames (0 = never)
    syncNext: int                ## the next frame whose state-before is fingerprinted
    syncOut*: seq[(int, uint64)] ## final fingerprints, oldest first (the transport ships them)

proc bit(v: uint16; i: int): bool {.inline.} = ((v shr i) and 1) != 0

proc new_gb_rollback_session*(link: GbLink; local: int; maxAhead = 12;
                              syncEvery = 120): GbRollbackSession =
  ## `link` must be a fresh 2-core GbLink at frame 0 (both cores post_init from
  ## the two players' ROM+save). `local` is which core this peer's buttons drive.
  ## `maxAhead` bounds prediction depth — pick it above the round-trip in frames.
  doAssert local in {0, 1}, "local player must be 0 or 1"
  doAssert link.cores.len == 2, "rollback session needs exactly two cores"
  let cap = maxAhead + 4
  result = GbRollbackSession(
    link: link, local: local, head: 0, confirmed: -1, maxAhead: maxAhead,
    ring: newSeq[GbLinkSnapshot](cap), ringFrame: newSeq[int](cap),
    ringKeys: newSeq[array[2, HeldKeys]](cap), cap: cap,
    syncEvery: syncEvery, syncNext: syncEvery)
  for i in 0 ..< cap: result.ringFrame[i] = -1

proc grow(sess: GbRollbackSession; f: int) =
  if f >= sess.localIn.len:
    let n = f + 1
    sess.localIn.setLen(n)
    sess.remoteIn.setLen(n)
    sess.remoteKnown.setLen(n)
    sess.usedRemote.setLen(n)

proc apply_inputs(sess: GbRollbackSession; f: int) =
  # Real remote input if known, else predict "same as the last confirmed".
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

proc store_ckpt(sess: GbRollbackSession; f: int) =
  let idx = f mod sess.cap
  sess.ring[idx] = sess.link.capture_state()
  sess.ringFrame[idx] = f
  for p in 0 .. 1:
    let j = sess.link.cores[p].joypad
    sess.ringKeys[idx][p] = HeldKeys(down: j.down, up: j.up, left: j.left,
      right: j.right, start: j.start, jselect: j.jselect, b: j.b, a: j.a,
      prev_lines: j.prev_lines)

proc load_ckpt(sess: GbRollbackSession; f: int) =
  let idx = f mod sess.cap
  doAssert sess.ringFrame[idx] == f,
    "rollback: checkpoint for frame " & $f & " evicted (window too small?)"
  sess.link.restore_state(sess.ring[idx])
  for p in 0 .. 1:
    let j = sess.link.cores[p].joypad
    let k = sess.ringKeys[idx][p]
    j.down = k.down; j.up = k.up; j.left = k.left; j.right = k.right
    j.start = k.start; j.jselect = k.jselect; j.b = k.b; j.a = k.a
    j.prev_lines = k.prev_lines

proc fingerprint*(sess: GbRollbackSession): uint64 =
  ## Both cores' portable state images, hashed (linksync.sync_hash): what the
  ## two peers compare, as gba/rollback.nim.
  result = 0
  for core in sess.link.cores:
    result = sync_hash(core.state_bytes(), result)

proc sim(sess: GbRollbackSession; f: int) =
  # Snapshot the state entering frame f, apply its inputs, advance one frame.
  sess.store_ckpt(f)
  sess.apply_inputs(f)
  sess.link.step_frame()

proc sync_flush(sess: GbRollbackSession) =
  ## Fingerprint the state before each syncEvery-th frame once it is final:
  ## every input before it known (confirmed >= f-1), so no replay can change
  ## it. Once each, here, not as frames are simulated: a replay through f
  ## would pay for another (measured: 9 ms ticks on Emerald in wasm). The
  ## state is the live one at f == head, else ring slot f, put in for the
  ## fingerprint and taken out again. The window keeps f in the ring: f-1
  ## <= confirmed and head - confirmed <= maxAhead + 1 < cap.
  if sess.syncEvery <= 0: return
  while sess.syncNext <= sess.head and sess.confirmed >= sess.syncNext - 1:
    let f = sess.syncNext
    var h: uint64
    if f == sess.head:
      h = sess.fingerprint()
    else:
      # The live HeldKeys go back too: load_ckpt puts frame f's in, and the
      # next frame's joypad interrupt edge reads them.
      let live = sess.link.capture_state()
      var keys: array[2, HeldKeys]
      for p in 0 .. 1:
        let j = sess.link.cores[p].joypad
        keys[p] = HeldKeys(down: j.down, up: j.up, left: j.left, right: j.right,
          start: j.start, jselect: j.jselect, b: j.b, a: j.a, prev_lines: j.prev_lines)
      sess.load_ckpt(f)
      h = sess.fingerprint()
      sess.link.restore_state(live)
      for p in 0 .. 1:
        let j = sess.link.cores[p].joypad
        let k = keys[p]
        j.down = k.down; j.up = k.up; j.left = k.left; j.right = k.right
        j.start = k.start; j.jselect = k.jselect; j.b = k.b; j.a = k.a
        j.prev_lines = k.prev_lines
    sess.syncOut.add((f, h))
    sess.syncNext = f + sess.syncEvery

proc reconcile(sess: GbRollbackSession) =
  ## Extend the confirmed frontier over contiguously-known remote frames, rolling
  ## back + re-simulating only on a genuine misprediction.
  var g = sess.confirmed
  while g + 1 < sess.head and g + 1 < sess.remoteKnown.len and sess.remoteKnown[g + 1]:
    inc g
  if g <= sess.confirmed: return
  var mispredicted = false
  for k in sess.confirmed + 1 .. g:
    if sess.usedRemote[k] != sess.remoteIn[k]: mispredicted = true; break
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
  if sess.remoteKnown[frame]: return
  sess.remoteIn[frame] = bits
  sess.remoteKnown[frame] = true
  sess.reconcile()
  sess.sync_flush()

proc tick*(sess: GbRollbackSession; localBits: uint16): GbRbStatus =
  ## Simulate one presentation frame with the local input and prediction. STALL
  ## if we are already `maxAhead` past the confirmed remote input. On grbAdvanced
  ## the caller ships (`head-1`, localBits) to the peer.
  if sess.head - sess.confirmed > sess.maxAhead:
    inc sess.stalls
    return grbStalled
  sess.grow(sess.head)
  sess.localIn[sess.head] = localBits
  sess.sim(sess.head)
  inc sess.head
  # Extend the frontier over remote inputs that arrived early (nothing
  # re-runs); waiting for the next arrival would stall this side at the window
  # if the peer goes quiet.
  sess.reconcile()
  sess.sync_flush()
  grbAdvanced

proc checksum*(sess: GbRollbackSession): uint64 =
  ## State fingerprint for periodic desync detection between peers. Compare only
  ## at a CONFIRMED frame; a mismatch means a determinism gap.
  sess.link.state_checksum()

# Rendering is the transport's job; a peer shows its own player (sess.local).
