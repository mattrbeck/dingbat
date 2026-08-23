## WSOLA (waveform-similarity overlap-add) 2:1 time compression for
## pitch-preserving fast-forward, shared by the GBA and GB APUs.
##
## Both APUs pace emulation off the output sample count, so at 2x they must
## emit exactly half as many frames. Count-exactness holds by construction:
## the analysis pointer advances on a fixed grid of HA input frames per step
## and each step emits HS = HA/2 output frames; the similarity search only
## picks which segment to grab within a bounded window and never moves the
## grid. Callers push every input frame and pull exactly half as many; a short
## output FIFO absorbs the HS-frame chunking, and the only transient is a
## ~4 ms warm-up at turbo-on where pull() returns silence. Reset the stretcher
## when turbo toggles on.
##
## Frames are interleaved stereo float32 (mono callers pass R = L).
## Presentation-only: never on the bit-exact 1x path, never serialised.

import std/math

const
  HS*     = 128           ## synthesis hop: output frames emitted per step
  HA*     = HS * 2         ## analysis hop: input frames consumed per step (2x)
  FRAME*  = HS * 2         ## window / segment length (50% overlap, Hann COLA)
  OVL     = FRAME - HS     ## overlap region length (= HS here)
  SEARCH  = 64             ## similarity search radius, ± frames (~2 ms @32768)
  CAP     = 2048           ## input ring capacity in frames (power of two)
  CAPMASK = CAP - 1

type
  TimeStretch* = ref object
    inL, inR: array[CAP, float32]   ## interleaved-by-array input ring
    writePos: int                    ## total frames pushed (absolute)
    anNominal: int                   ## fixed analysis grid position (absolute)
    prevGrab: int                    ## absolute start of the last grabbed segment
    started: bool                    ## has the first segment been placed?
    accL, accR: array[FRAME, float32]## OLA accumulator (frames)
    outL, outR: seq[float32]         ## output FIFO (frames)
    outHead: int                     ## FIFO read cursor
    win: array[FRAME, float32]       ## precomputed periodic Hann window

proc new_time_stretch*(): TimeStretch =
  result = TimeStretch(outL: @[], outR: @[])
  # Periodic Hann: w[n] + w[n+HS] == 1 at 50% overlap (unity COLA).
  for n in 0 ..< FRAME:
    result.win[n] = 0.5'f32 - 0.5'f32 * cos(2.0'f32 * PI * float32(n) / float32(FRAME))

proc reset*(ts: TimeStretch) =
  ## Drop all buffered state (call when turbo toggles on).
  ts.writePos = 0
  ts.anNominal = 0
  ts.prevGrab = 0
  ts.started = false
  for i in 0 ..< FRAME:
    ts.accL[i] = 0.0'f32
    ts.accR[i] = 0.0'f32
  ts.outL.setLen(0)
  ts.outR.setLen(0)
  ts.outHead = 0

proc push*(ts: TimeStretch; l, r: float32) {.inline.} =
  ## Feed one full-rate stereo input frame.
  let idx = ts.writePos and CAPMASK
  ts.inL[idx] = l
  ts.inR[idx] = r
  inc ts.writePos

proc canProduce(ts: TimeStretch): bool {.inline.} =
  ## Enough input buffered for the segment at the grid position plus its
  ## search window.
  ts.writePos >= ts.anNominal + SEARCH + FRAME

proc bestOffset(ts: TimeStretch): int =
  ## Search +-SEARCH around the grid position for the segment whose overlap
  ## best continues the previous one (normalised cross-correlation, mono mix).
  if not ts.started:
    return 0
  # Reference = samples that naturally follow the previous grab by HS.
  let refBase = ts.prevGrab + HS
  var d = 0
  var best = -1e30'f32
  var lo = -SEARCH
  if ts.anNominal + lo < 0: lo = -ts.anNominal
  for cand in lo .. SEARCH:
    let cbase = ts.anNominal + cand
    var dot = 0.0'f32
    var energy = 0.0'f32
    for n in 0 ..< OVL:
      let rIdx = (refBase + n) and CAPMASK
      let cIdx = (cbase + n) and CAPMASK
      let rv = ts.inL[rIdx] + ts.inR[rIdx]
      let cv = ts.inL[cIdx] + ts.inR[cIdx]
      dot += rv * cv
      energy += cv * cv
    let score = dot / (sqrt(energy) + 1e-6'f32)
    if score > best:
      best = score
      d = cand
  d

proc produceStep(ts: TimeStretch) =
  ## Overlap-add one windowed segment, emit HS frames, advance the grid by HA.
  let d = ts.bestOffset()
  let grab = ts.anNominal + d
  # Windowed overlap-add of the grabbed FRAME-length segment.
  for n in 0 ..< FRAME:
    let sIdx = (grab + n) and CAPMASK
    let w = ts.win[n]
    ts.accL[n] += ts.inL[sIdx] * w
    ts.accR[n] += ts.inR[sIdx] * w
  # First HS frames are final (never touched again); push them out.
  for n in 0 ..< HS:
    ts.outL.add(ts.accL[n])
    ts.outR.add(ts.accR[n])
  # Shift accumulator left by HS; zero the exposed tail.
  for n in 0 ..< (FRAME - HS):
    ts.accL[n] = ts.accL[n + HS]
    ts.accR[n] = ts.accR[n + HS]
  for n in (FRAME - HS) ..< FRAME:
    ts.accL[n] = 0.0'f32
    ts.accR[n] = 0.0'f32
  ts.prevGrab = grab
  ts.started = true
  ts.anNominal += HA          # fixed grid: exactly HA input per HS output

proc available*(ts: TimeStretch): int {.inline.} =
  ## Output frames currently ready in the FIFO.
  ts.outL.len - ts.outHead

proc pull*(ts: TimeStretch): tuple[l, r: float32] {.inline.} =
  ## Emit one output frame; silence only during the warm-up before the first
  ## segment is ready. The caller must pull exactly half as many as it pushes.
  while ts.outHead >= ts.outL.len and ts.canProduce():
    ts.produceStep()
  if ts.outHead < ts.outL.len:
    result = (ts.outL[ts.outHead], ts.outR[ts.outHead])
    inc ts.outHead
    # Compact the FIFO once fully drained to bound memory.
    if ts.outHead >= ts.outL.len:
      ts.outL.setLen(0)
      ts.outR.setLen(0)
      ts.outHead = 0
  else:
    result = (0.0'f32, 0.0'f32)
