## Unit tests for the LCD response model (src/dingbat/common/lcd_response.nim).
##
## These are the invariants the feature has to hold to be a panel model rather
## than a smear: static content must come out bit-exact, every transition must
## actually finish, the two directions must differ in the direction real TN
## cells differ, and an alternate-frame flicker must settle to something close
## to its average instead of strobing.

import std/[math, strutils, strformat]
import dingbat/common/lcd_response

var failures = 0

proc check(cond: bool; msg: string) =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg
    failures.inc

const W = 4
const H = 4
const N = W * H

proc mk(c: uint16): array[N, uint16] =
  for i in 0 ..< N: result[i] = c

proc rgb(r, g, b: int): uint16 =
  uint16(r) or (uint16(g) shl 5) or (uint16(b) shl 10)

proc push(r: var LcdResponse; frame: var array[N, uint16]): uint16 =
  ## One frame in, the displayed value of pixel 0 out.
  let p = r.apply(cast[ptr UncheckedArray[uint16]](addr frame[0]), N)
  p[0]

# ─────────────────────────── the table itself ───────────────────────────
echo "=== fixed points and convergence ==="
block:
  for panel in [lpDmg, lpCgb, lpAgb, lpAgs]:
    var r: LcdResponse
    r.set_panel(panel)
    # A settled cell must map to itself for every code, or static content
    # would drift.
    var exact = true
    for code in 0 .. 31:
      var f = mk(rgb(code, code, code))
      discard r.push(f)                      # seeds the state
      for _ in 0 ..< 8:
        if r.push(f) != rgb(code, code, code): exact = false
      r.reset()
    check(exact, &"{panel}: a static frame is bit-exact for all 32 codes")

    # Every transition must land exactly on the target, both ways, and in a
    # bounded number of frames — an exponential that rounds to a zero step
    # would leave a permanent fractional ghost.
    var worst = 0
    var stuck = -1
    for a in 0 .. 31:
      for b in 0 .. 31:
        if a == b: continue
        r.reset()
        var fa = mk(rgb(a, a, a))
        discard r.push(fa)
        var fb = mk(rgb(b, b, b))
        var n = 0
        while n < 400 and r.push(fb) != rgb(b, b, b): n.inc
        if n >= 400: stuck = a * 100 + b
        if n > worst: worst = n
    check(stuck < 0, &"{panel}: every code-to-code transition reaches its target")
    check(worst <= 120, &"{panel}: slowest transition settles in {worst} frames (<= 120)")

# ─────────────────────────── off is a no-op ───────────────────────────
echo "=== off ==="
block:
  var r: LcdResponse
  r.set_panel(lpOff)
  check(not r.active(), "lpOff reports inactive")
  var f = mk(rgb(9, 9, 9))
  let p = r.apply(cast[ptr UncheckedArray[uint16]](addr f[0]), N)
  check(cast[pointer](p) == cast[pointer](addr f[0]),
        "lpOff hands back the core's own framebuffer (zero copy)")

# ─────────────────────────── the asymmetry ───────────────────────────
echo "=== asymmetry: relaxing toward light is the slow direction ==="
block:
  # Datasheet-style: a transition counts as arrived when the displayed value
  # crosses 90% of the step in LINEAR LIGHT (TR/TF are specified 10%-90%).
  # Waiting for the exact 5-bit code instead would let gamma hide the tail —
  # near white one code spans ~14% of linear light, so a correctly-rounded
  # display snaps the last code early in both directions and the exact-code
  # frame counts collapse to a tie on the fast panels.
  proc lum(c: uint16): float = pow(float(c and 31) / 31.0, 2.2)
  for panel in [lpDmg, lpCgb, lpAgb, lpAgs]:
    var r: LcdResponse
    r.set_panel(panel)
    var white = mk(rgb(31, 31, 31))
    var black = mk(rgb(0, 0, 0))

    r.reset()
    discard r.push(white)
    var to_dark = 0
    while to_dark < 400 and lum(r.push(black)) > 0.1: to_dark.inc

    r.reset()
    discard r.push(black)
    var to_light = 0
    while to_light < 400 and lum(r.push(white)) < 0.9: to_light.inc

    check(to_light > to_dark,
          &"{panel}: black->white ({to_light} frames to 90% light) is " &
          &"slower than white->black ({to_dark} frames to 10%)")

echo "=== panel ordering: DMG slowest, AGS-101 quickest ==="
block:
  proc settle_frames(panel: LcdPanel): int =
    var r: LcdResponse
    r.set_panel(panel)
    var black = mk(rgb(0, 0, 0))
    var white = mk(rgb(31, 31, 31))
    discard r.push(black)
    while result < 400 and r.push(white) != rgb(31, 31, 31): result.inc
  let d = settle_frames(lpDmg)
  let c = settle_frames(lpCgb)
  let a = settle_frames(lpAgb)
  let s = settle_frames(lpAgs)
  echo &"    dmg={d} agb={a} cgb={c} ags={s} frames to full white"
  check(d > a and a > c and c > s,
        "settling time orders dmg > agb > cgb > ags")

# ─────────────────────── flicker transparency ───────────────────────
echo "=== alternate-frame flicker reads as a steady mid-tone ==="
block:
  for panel in [lpDmg, lpCgb, lpAgb, lpAgs]:
    var r: LcdResponse
    r.set_panel(panel)
    var white = mk(rgb(31, 31, 31))
    var black = mk(rgb(0, 0, 0))
    discard r.push(white)
    var lo = 999
    var hi = -1
    for i in 0 ..< 60:
      let v = int((if i mod 2 == 0: r.push(black) else: r.push(white)) and 31)
      if i >= 40:
        if v < lo: lo = v
        if v > hi: hi = v
    let swing = hi - lo
    echo &"    {panel}: displayed {lo}..{hi} (swing {swing}/31)"
    # Raw, the pixel would swing the full 31. The panels that games actually
    # relied on for this have to knock that down to a few codes.
    if panel in [lpDmg, lpAgb]:
      check(swing <= 2, &"{panel}: 30 Hz flicker swing {swing} <= 2 codes")
    else:
      check(swing < 31, &"{panel}: 30 Hz flicker swing {swing} is attenuated")

# ─────────────── a scene cut is not a symmetric double exposure ───────────────
echo "=== scene cut ==="
block:
  # A 50/50 blend puts BOTH directions at exactly 15/31 one frame after a cut:
  # a literal double exposure, and the same one whichever way the cut went.
  # The panel does not do that. Measure how far each direction has left to go
  # in light terms — darkening should be the one that is nearly finished.
  var r: LcdResponse
  r.set_panel(lpDmg)
  var white = mk(rgb(31, 31, 31))
  var black = mk(rgb(0, 0, 0))
  # Progress has to be read in LIGHT, not in codes: the display gamma squashes
  # the bright end, so a code halfway between black and white is nowhere near
  # halfway in photons.
  proc light(code: int): float = pow(float(code) / 31.0, 2.2)
  r.reset(); discard r.push(white)
  let dark_done = 1.0 - light(int(r.push(black) and 31))
  r.reset(); discard r.push(black)
  let light_done = light(int(r.push(white) and 31))
  echo &"    one frame after a cut, in light: white->black is " &
       &"{int(dark_done * 100)}% done, black->white is {int(light_done * 100)}% done"
  check(dark_done > 2.0 * light_done,
        "darkening is more than twice as far along as lightening after one frame")
  # A 50/50 blend would report the SAME number for both directions. That the
  # two disagree at all is the property a symmetric blend cannot have.
  check(abs(dark_done - light_done) > 0.2,
        "the two directions of a cut do not land in the same place")

echo ""
if failures == 0:
  echo "lcd_response: all checks passed"
else:
  echo &"lcd_response: {failures} check(s) FAILED"
  quit(1)
