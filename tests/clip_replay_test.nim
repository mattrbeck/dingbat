## Clip-capture replay determinism. The clip exporter (clip_* in
## src/dingbat_wasm.nim) keeps one compressed state anchor per second plus a
## 2-byte-per-frame input log and RE-EMULATES a requested range, which is
## only a clip of what happened if the replay is bit-identical. Run a core
## live hashing every frame, replay an interior range from the anchor+input
## log, and require every frame to match on the whole SERIALIZED MACHINE
## STATE (a pixel-only check misses a RAM/CPU divergence until it surfaces).
## Two negative controls (wrong anchor; one flipped button bit on an
## input-sensitive ROM) stop it passing vacuously.
##
## The wasm clip_* procs cannot be built natively, so this exercises the same
## core APIs in the same order with the same convention: the anchor at frame
## F is the state BEFORE frame F steps, inputs[F] is the mask held DURING
## frame F, and anchors are stored deflated.
##
## Build/run: nimble test_clipreplay

import std/[strformat, os]
import dingbat/gb/gb
import dingbat/gba/gba
import dingbat/common/input
import dingbat/common/test_output
import zippy

const
  Frames = 420          ## live frames to run
  AnchorEvery = 60      ## the shipping CLIP_SNAP_INTERVAL
  RangeStart = 155      ## deliberately NOT on an anchor: exercises the pre-roll
  RangeEnd = 390

var failures = 0

proc check(cond: bool; msg: string) =
  if not cond:
    echo "FAIL: ", msg
    inc failures

proc fnv(s: string): uint64 =
  result = 0xcbf29ce484222325'u64
  for c in s:
    result = (result xor uint64(uint8(c))) * 0x100000001b3'u64

proc fbHash(fb: openArray[uint16]): uint64 =
  ## FNV-1a over the framebuffer. Any pixel differing anywhere changes it.
  result = 0xcbf29ce484222325'u64
  for v in fb:
    result = (result xor uint64(v)) * 0x100000001b3'u64

proc scriptMask(frame: int): uint16 =
  ## A deterministic, busy input pattern: buttons come and go at coprime
  ## periods so the replay has real transitions to reproduce rather than a
  ## constant mask (which every broken replay would also reproduce).
  var m: uint16 = 0
  if (frame div 7) mod 3 == 0: m = m or (1'u16 shl ord(Input.A))
  if (frame div 11) mod 4 == 0: m = m or (1'u16 shl ord(Input.B))
  if (frame div 13) mod 5 == 0: m = m or (1'u16 shl ord(Input.RIGHT))
  if (frame div 17) mod 5 == 1: m = m or (1'u16 shl ord(Input.DOWN))
  if (frame div 23) mod 7 == 0: m = m or (1'u16 shl ord(Input.START))
  if (frame div 29) mod 6 == 0: m = m or (1'u16 shl ord(Input.SELECT))
  m

# The two cores are separate types with no common base, so this is a generic.
# `hasPicture`: the ROM animates, so the framebuffer comparison constrains
# something. `readsInput`: the ROM's state depends on WHICH buttons are
# held, so the wrong-input control is meaningful.
proc clipCase[T](lbl: string; emu: T; hasPicture, readsInput: bool) =
  emu.test_output = new_test_output()
  emu.post_init()

  var liveHash: seq[uint64] = newSeq[uint64](Frames)     # framebuffer
  var stateHash: seq[uint64] = newSeq[uint64](Frames)    # whole machine
  var inputs: seq[uint16] = newSeq[uint16](Frames)
  var anchors: seq[tuple[frame: int, packed: string]] = @[]

  proc applyMask(e: T; mask: uint16) =
    for i in 0 .. ord(Input.high):
      e.handle_input(Input(i), (mask and (1'u16 shl i)) != 0)

  # --- live run: exactly what clip_note_frame + loop_tick do, in order -----
  for f in 0 ..< Frames:
    if f mod AnchorEvery == 0:
      anchors.add((f, compress(emu.state_payload(), BestSpeed, dfZlib)))
    inputs[f] = scriptMask(f)
    emu.applyMask(inputs[f])
    emu.step_frame()
    liveHash[f] = fbHash(emu.ppu.framebuffer)
    stateHash[f] = fnv(emu.state_payload())

  let liveStash = emu.state_payload()
  let liveEndHash = fbHash(emu.ppu.framebuffer)

  proc countDistinct(hs: seq[uint64]): int =
    var seen: seq[uint64] = @[]
    for h in hs:
      if h notin seen:
        seen.add h
        inc result

  let distinctFrames = countDistinct(liveHash)
  let distinctStates = countDistinct(stateHash)
  if hasPicture:
    check(distinctFrames > 1,
          &"{lbl}: the live run never changed the screen — the framebuffer " &
          "comparison would pass vacuously")
  check(distinctStates > Frames div 2,
        &"{lbl}: only {distinctStates} distinct machine states over {Frames} " &
        "frames — the state comparison is not constraining much")

  # Negative control 1: replaying from the PREVIOUS anchor is a shifted
  # history and must be caught on every ROM whose state evolves.
  block:
    let probe = anchors[anchors.high]
    let wrong = anchors[anchors.high - 1]
    emu.apply_state_payload(uncompress(wrong.packed, dfZlib))
    var diverged = false
    for f in probe.frame ..< Frames:
      emu.applyMask(inputs[f])
      emu.step_frame()
      if fnv(emu.state_payload()) != stateHash[f]:
        diverged = true
        break
    check(diverged,
          &"{lbl}: NEGATIVE CONTROL — replaying from the WRONG anchor still " &
          "matched the live run, so this test cannot detect divergence")

  # Negative control 2: one wrong button bit, on a ROM that reads the keypad;
  # proves the input log is load-bearing.
  if readsInput:
    let probe = anchors[anchors.high]
    emu.apply_state_payload(uncompress(probe.packed, dfZlib))
    var diverged = false
    for f in probe.frame ..< Frames:
      emu.applyMask(if f == probe.frame: inputs[f] xor 1'u16 else: inputs[f])
      emu.step_frame()
      if fnv(emu.state_payload()) != stateHash[f]:
        diverged = true
        break
    check(diverged,
          &"{lbl}: NEGATIVE CONTROL — a replay fed one wrong button bit " &
          "still matched the live run, so the input log is not being tested")

  # --- the replay clip_begin performs -------------------------------------
  var pick = 0
  for i in 0 ..< anchors.len:
    if anchors[i].frame <= RangeStart: pick = i
    else: break
  check(anchors[pick].frame <= RangeStart and
        RangeStart - anchors[pick].frame < AnchorEvery,
        &"{lbl}: anchor pick {anchors[pick].frame} is not the newest one " &
        &"at or before {RangeStart}")

  var restored = false
  try:
    emu.apply_state_payload(uncompress(anchors[pick].packed, dfZlib))
    restored = true
  except CatchableError as e:
    check(false, &"{lbl}: anchor {anchors[pick].frame} would not load: " & e.msg)
  if not restored: return

  var mismatch = -1
  var mismatchKind = ""
  var compared = 0
  for f in anchors[pick].frame ..< RangeEnd:
    emu.applyMask(inputs[f])
    emu.step_frame()
    inc compared
    if fnv(emu.state_payload()) != stateHash[f]:
      mismatch = f
      mismatchKind = "machine state"
      break
    if fbHash(emu.ppu.framebuffer) != liveHash[f]:
      mismatch = f
      mismatchKind = "framebuffer"
      break
  check(mismatch < 0,
        &"{lbl}: replay diverged ({mismatchKind}) at frame {mismatch} " &
        &"(anchor {anchors[pick].frame}, pre-roll to {RangeStart}, end {RangeEnd})")
  check(compared >= RangeEnd - RangeStart,
        &"{lbl}: replay only covered {compared} frames")

  # clip_tick restores the live state when the range runs out; if that were
  # lossy the player would silently resume from the past.
  emu.apply_state_payload(liveStash)
  check(emu.state_payload() == liveStash,
        &"{lbl}: live-state restore did not round-trip")
  check(fbHash(emu.ppu.framebuffer) == liveEndHash,
        &"{lbl}: live-state restore did not bring back the live frame")

  echo &"{lbl}: {compared} frames replayed bit-identically " &
       &"({distinctFrames} distinct live frames, {distinctStates} distinct " &
       &"states, anchor {anchors[pick].frame} -> {RangeEnd})"

let roms = currentSourcePath().parentDir / "roms"

# gbaedge animates but idles waiting for START, so a stray UP changes
# nothing and the input control would be a false alarm.
clipCase("GBA gbaedge", new_gba("", roms / "gbaedge.gba", run_bios = false,
                                use_hle = true),
         hasPicture = true, readsInput = false)
# inputrec folds every KEYINPUT sample into a time-weighted accumulator, so
# its state depends on the exact input timeline. It draws nothing.
clipCase("GBA inputrec", new_gba("", roms / "inputrec.gba", run_bios = false,
                                 use_hle = true),
         hasPicture = false, readsInput = true)
clipCase("GB gbedge", new_gb("", roms / "gbedge.gb", fifo = true,
                             headless = true, run_bios = false),
         hasPicture = true, readsInput = true)

if failures > 0:
  echo &"clip replay: {failures} check(s) FAILED"
  quit(1)
echo "clip replay: all checks passed"
