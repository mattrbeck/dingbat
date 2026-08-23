## Unit tests for the WSOLA time-stretch helper (src/dingbat/common/timestretch).
## Run: nim c -r --path:src tests/timestretch_test.nim
## (a) count-exactness: pulling exactly half as many frames as pushed is
##     sustainable with no drift and a one-time warm-up gap; (b) pitch is
##     preserved, not doubled as plain decimation would; plus finiteness and
##     mono/stereo correctness.

import std/[math, strformat]
import dingbat/common/timestretch

const SR = 32768.0

var failures = 0
proc check(cond: bool; msg: string) =
  if cond:
    echo "  ok: ", msg
  else:
    echo "  FAIL: ", msg
    inc failures

# (a) Feed a continuous sine in fixed buffers, pull exactly half after each:
# the output FIFO must neither underflow after warm-up nor grow.
block count_exactness:
  echo "test: count-exactness (2:1, no drift)"
  let ts = new_time_stretch()
  const P = 512          # native GBA buffer = 512 stereo frames
  const BUFFERS = 200
  var f = 440.0
  var phase = 0.0
  var totalSilent = 0
  var totalReal = 0
  var maxAvail = 0
  var warmupSilent = 0
  for b in 0 ..< BUFFERS:
    for i in 0 ..< P:
      let s = sin(phase).float32
      phase += 2.0 * PI * f / SR
      ts.push(s, s)
    # Pull exactly half — the pacing contract.
    var bufSilent = 0
    for i in 0 ..< (P div 2):
      let (l, r) = ts.pull()
      if l == 0.0'f32 and r == 0.0'f32: inc bufSilent
      else: inc totalReal
    totalSilent += bufSilent
    if b == 0: warmupSilent = bufSilent
    if ts.available() > maxAvail: maxAvail = ts.available()

  check(warmupSilent <= FRAME,
        &"warm-up silence bounded to one segment (got {warmupSilent} <= {FRAME})")
  # After the first buffer there must be no further underflow: continuous input,
  # exactly-half pull, exact 2:1 production => steady state.
  check(totalSilent == warmupSilent,
        &"no underflow after warm-up (extra silent frames = {totalSilent - warmupSilent})")
  check(maxAvail < FRAME * 3,
        &"FIFO bounded, no drift/growth (max available = {maxAvail} frames)")
  let expectedReal = P div 2 * BUFFERS - warmupSilent
  check(totalReal == expectedReal,
        &"produced real frame count is exact ({totalReal} == {expectedReal})")

# (b) Dominant output frequency ~= input frequency, by zero-crossing rate.
proc zeroCrossFreq(samples: seq[float32]; nFrames: int): float =
  var crossings = 0
  for i in 1 ..< nFrames:
    if (samples[i-1] < 0.0'f32) != (samples[i] < 0.0'f32):
      inc crossings
  # crossings per output-sample = 2*f/SR  =>  f = crossings * SR / (2*N)
  result = float(crossings) * SR / (2.0 * float(nFrames))

proc runSine(f: float): tuple[freq: float; anyNaN: bool; maxAbs: float32] =
  let ts = new_time_stretch()
  const N = 32768 * 2    # ~2 s of input
  var phase = 0.0
  var outv: seq[float32] = @[]
  var anyNaN = false
  var maxAbs = 0.0'f32
  # Drive push/pull interleaved at the emscripten cadence (pull every 2nd push)
  var parity = false
  for i in 0 ..< N:
    let s = sin(phase).float32
    phase += 2.0 * PI * f / SR
    ts.push(s, s)
    parity = not parity
    if parity:
      let (l, r) = ts.pull()
      if classify(l) in {fcNan, fcInf, fcNegInf}: anyNaN = true
      outv.add(l)
      if abs(l) > maxAbs: maxAbs = abs(l)
  # Skip the warm-up region (first FRAME output frames) when measuring pitch.
  let skip = FRAME * 2
  var trimmed: seq[float32] = @[]
  for i in skip ..< outv.len: trimmed.add(outv[i])
  result = (zeroCrossFreq(trimmed, trimmed.len), anyNaN, maxAbs)

block pitch_preservation:
  echo "test: pitch-preservation (frequency not doubled)"
  for f in [220.0, 440.0, 1000.0, 3000.0]:
    let (measured, anyNaN, maxAbs) = runSine(f)
    let ratio = measured / f
    check(not anyNaN, &"no NaN/Inf in output at {f:.0f} Hz")
    check(maxAbs <= 1.05'f32, &"no clipping blow-up at {f:.0f} Hz (max |x| = {maxAbs:.3f})")
    check(ratio > 0.9 and ratio < 1.1,
          &"output ~{f:.0f} Hz preserved (measured {measured:.0f} Hz, ratio {ratio:.3f}), " &
          &"NOT doubled ({2.0*f:.0f} Hz)")

# (d) Identical L/R in => identical L/R out; distinct channels stay
# distinct and finite.
block mono_stereo:
  echo "test: mono/stereo handling"
  block mono:
    let ts = new_time_stretch()
    var phase = 0.0
    var mismatches = 0
    for i in 0 ..< 40000:
      let s = sin(phase).float32
      phase += 2.0 * PI * 440.0 / SR
      ts.push(s, s)
      if (i and 1) == 1:
        let f = ts.pull()
        if f.l != f.r: inc mismatches
    check(mismatches == 0, "mono input (R=L) yields R==L output")
  block stereo:
    let ts = new_time_stretch()
    var pl = 0.0
    var pr = 0.0
    var anyNaN = false
    var distinctSeen = false
    for i in 0 ..< 40000:
      let sl = sin(pl).float32
      let sr = (0.7 * sin(pr)).float32   # different amplitude + frequency
      pl += 2.0 * PI * 440.0 / SR
      pr += 2.0 * PI * 660.0 / SR
      ts.push(sl, sr)
      if (i and 1) == 1:
        let (l, r) = ts.pull()
        if classify(l) in {fcNan, fcInf} or classify(r) in {fcNan, fcInf}: anyNaN = true
        if abs(l - r) > 1e-4'f32: distinctSeen = true
    check(not anyNaN, "stereo output finite")
    check(distinctSeen, "distinct L/R channels stay distinct")

echo ""
if failures == 0:
  echo "ALL TIMESTRETCH TESTS PASSED"
  quit(0)
else:
  echo &"{failures} TIMESTRETCH TEST(S) FAILED"
  quit(1)
