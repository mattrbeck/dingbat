## LCD response — a per-pixel model of how a Game Boy panel actually settles.
##
## This replaces "interframe blending" (present the average of the last two
## frames). That trick nulls a 30 Hz alternation perfectly, which is why it
## makes flicker-transparency look right, but it is not what a panel does: it
## is symmetric, magnitude-independent, and it smears a scene cut into a
## one-frame double exposure.
##
## WHAT A PANEL DOES (see docs/research_lcd_response.md for the derivation)
##
## Every Game Boy screen is a normally-white twisted-nematic cell: with no
## field across it the liquid crystal passes light (the DMG is uniformly pale
## green with the CPU halted), and driving the cell darkens it. That makes the
## two directions physically different processes:
##
##   * toward DARKER — the field does the work, so this is the FAST direction,
##     and the more field the faster: TN turn-on goes as
##     1/(V^2 - Vth^2). The drive is set by the target, not by the size of the
##     step, so darkening all the way to black is quick while nudging a white
##     pixel one shade down is not. That is where the grey-to-grey slowness
##     everyone measures on LCDs comes from, and `drive_knee` is its size.
##   * toward LIGHTER — the field is reduced and the cell relaxes elastically
##     on its own. SLOW, and its time constant gamma_1*d^2 / (pi^2 * K) is a
##     material and cell-gap property: it does not depend on the voltage, so it
##     does not depend on the level or on the size of the step either. One
##     constant, `tau_relax`, covers every lightening transition.
##
## The visible consequence is the DMG's signature artifact: a moving dark
## object has a crisp leading edge and a dark trail behind it, because the
## pixels it vacated are the ones taking the slow way home. A symmetric blend
## puts equal ghost on both sides. Getting this sign backwards is a documented
## trap — it reads as input lag rather than as ghosting.
##
## One more effect the model carries: the observer integrates. What an eye or a
## camera accumulates over a frame is the time-average of the cell's
## transmittance across that frame, not its value at the end. We therefore
## carry the end-of-frame state but display the average. This is not a fudge
## factor — our own display holds whatever we hand it for the whole frame, so
## handing it the average is what delivers the same photons.
##
## The relaxation runs in LINEAR LIGHT (transmittance), not in the 5-bit code:
## it is the cell's optical output that decays, and the observer's average has
## to be in light anyway because photons add linearly. `gamma` is the
## code->light exponent, and it is the only place a display curve enters.
##
## IMPLEMENTATION
##
## All of the above is precomputed into one fused lookup table, so the
## per-pixel cost is three table reads and some packing — the same order as
## the blend it replaces. The table is indexed by (panel state, target code)
## and yields both the next state and the value to display:
##
##   lut[state8 * 32 + target5] = (next_state8 shl 8) or displayed8
##
## `state8` is the cell's settled-code value in 5.3 fixed point (0..248, so
## `state8 shr 3` is the 5-bit code). A settled pixel has state8 == target*8,
## for which the table returns itself and the target unchanged: static content
## is bit-exact, with no residual smear and no arithmetic drift. Where the
## exponential would round to a zero step the table is nudged by one, so a
## pixel always reaches its target instead of sticking a fraction short.
##
## This is presentation-only: nothing here is visible to the cores, so the
## toggle is safe to flip mid-frame and emulation output stays bit-exact.
## The per-pixel state is deliberately NOT part of a save state (see reset).

import std/math

type
  LcdPanel* = enum
    ## Which screen we are pretending to be. The panels really are different
    ## hardware, so one curve cannot serve them all.
    lpOff = "off"
    lpDmg = "dmg"      ## DMG / MGB. Reflective passive-matrix STN: the slow
                       ## technology, and the most asymmetric of the four.
    lpCgb = "cgb"      ## Game Boy Color. Reflective TFT — active matrix, and
                       ## visibly quicker than the DMG it replaced.
    lpAgb = "agb"      ## AGB-001, the unlit GBA. Reflective TFT, but the one
                       ## everyone remembers as smeary.
    lpAgs = "ags"      ## AGS-101, the backlit SP. Quick: a light touch of
                       ## response, close to no ghosting.

  LcdMode* = enum
    ## What the USER picked. `lmAuto` is the interesting one: it resolves to
    ## the panel the running machine actually shipped with, which is the only
    ## setting that is right for every game without being told.
    lmOff  = "off"
    lmAuto = "auto"
    lmDmg  = "dmg"
    lmCgb  = "cgb"
    lmAgb  = "agb"
    lmAgs  = "ags"

  PanelSpec = object
    ## Times are in milliseconds so they can be compared with panel datasheets
    ## directly; frames only enter when the table is built.
    tau_drive:  float  ## toward darker, driven to full black: the fastest case
    drive_knee: float  ## how much slower a barely-driven (near-white) target
                       ## is than full black — the 1/(V^2 - Vth^2) shape,
                       ## collapsed to one number
    tau_relax:  float  ## toward lighter: elastic relaxation, level-independent
    gamma:      float  ## code -> linear-light exponent

  LcdResponse* = object
    ## Owned by each frontend; module-scope instances must stay unallocated
    ## until a JS-invoked proc touches them (the wasm global-teardown rule).
    panel*:  LcdPanel
    lut:     seq[uint16]   ## 256*32 fused (next_state8 shl 8) or displayed8
    state:   seq[uint32]   ## per-pixel packed 8-bit cell state (r, g, b)
    outbuf:  seq[uint16]   ## BGR555 handed to the uploader

const
  # Both cores run at ~59.73 Hz (70224 dots / 4194304 Hz), so one frame period
  # serves for all panels.
  FRAME_MS = 16.742

  # Panel parameters. Nobody has ever published an instrument measurement of a
  # Game Boy panel — no oscilloscope trace, no high-speed capture — so these
  # are a fit. What the evidence DOES pin down, and what these numbers are
  # therefore chosen to satisfy (docs/research_lcd_response.md has the
  # citations):
  #
  #   * the DMG is a reflective STN, the CGB and both GBAs are TFTs. STN is
  #     the slow technology; that is the whole ordering.
  #   * a passive-matrix STN *must* be slow: with 144 multiplexed rows it is an
  #     RMS-responding device, so a cell that could follow the row-select
  #     period would stop averaging and break the picture. tau >> 16.7 ms is a
  #     design requirement, not an accident.
  #   * relaxation is the slow direction, by roughly 2-3x. The one primary
  #     document with a rise/fall pair is a Newhaven STN character module
  #     (TR 150 ms / TF 200 ms, 1.33x); brickboy, the only other emulator that
  #     models direction at all, tunes the DMG to 21 ms driven / 61 ms relaxing
  #     (2.9x). tau_drive here is the FULL-BLACK case, so the mid-level
  #     darkening it produces lands near brickboy's single 21 ms figure.
  #   * the CGB's speed is attested by consequence: Konami removed Castlevania
  #     II's flickered intro crawl for the GBC re-release because the faster
  #     panel made it visibly strobe. The CGB numbers have to leave a 30 Hz
  #     flicker perceptible; the DMG's must not.
  #   * the AGB-001 has to hide 30 Hz flicker well (Golden Sun's world-map
  #     jitter, F-Zero's minimap), the AGS-101 much less so.
  SPECS: array[LcdPanel, PanelSpec] = [
    # lpOff — never consulted
    PanelSpec(tau_drive: 0.0, drive_knee: 0.0, tau_relax:  0.0, gamma: 2.2),
    # lpDmg  reflective STN
    PanelSpec(tau_drive: 12.0, drive_knee: 2.0, tau_relax: 61.0, gamma: 2.2),
    # lpCgb  reflective TFT — active matrix, the quick one of the two STN-era
    PanelSpec(tau_drive:  6.0, drive_knee: 1.5, tau_relax: 24.0, gamma: 2.2),
    # lpAgb  AGB-001 reflective TFT, the smeary one
    PanelSpec(tau_drive:  9.0, drive_knee: 1.8, tau_relax: 42.0, gamma: 2.2),
    # lpAgs  AGS-101 backlit TFT
    PanelSpec(tau_drive:  3.5, drive_knee: 1.0, tau_relax: 12.0, gamma: 2.2),
  ]

  STATE_MAX = 248'i32   ## 31 * 8: the settled state of a full-scale code

proc build_lut(p: LcdPanel): seq[uint16] =
  ## Precompute the (state, target) -> (next state, displayed) table.
  let s = SPECS[p]
  # Into frame units: the model advances exactly one frame per call.
  let tau_drive = s.tau_drive / FRAME_MS
  let tau_relax = s.tau_relax / FRAME_MS
  let inv_g = 1.0 / s.gamma
  result = newSeq[uint16](256 * 32)
  for st in 0 .. 255:
    let s_code = clamp(float(st) / 8.0, 0.0, 31.0)   # 5.3 fixed point -> 0..31
    let ls = pow(s_code / 31.0, s.gamma)             # cell transmittance now
    for tg in 0 .. 31:
      let lt = pow(float(tg) / 31.0, s.gamma)        # transmittance asked for
      # Darkening is driven and its speed is set by how hard it is driven,
      # i.e. by the target; lightening is a free elastic relaxation with one
      # time constant. That asymmetry is the whole model.
      let tau = if lt < ls: tau_drive * (1.0 + s.drive_knee * lt)
                else: tau_relax
      let a = 1.0 - exp(-1.0 / tau)
      let l_end = ls + a * (lt - ls)
      # What the observer accumulates across the frame: the mean transmittance
      # while the cell moves, which for an exponential is closed form.
      let l_avg = lt + (ls - lt) * tau * a
      var nxt = int32(round(pow(clamp(l_end, 0.0, 1.0), inv_g) * 31.0 * 8.0))
      let dsp = int32(round(pow(clamp(l_avg, 0.0, 1.0), inv_g) * 31.0 * 8.0))
                  .clamp(0'i32, STATE_MAX)
      nxt = nxt.clamp(0'i32, STATE_MAX)
      # Never stall short of the target: an exponential that rounds to a zero
      # step would leave a permanent fractional ghost on static content.
      let goal = int32(tg) * 8
      if nxt == int32(st) and nxt != goal:
        nxt += (if goal > nxt: 1'i32 else: -1'i32)
      result[st * 32 + tg] = uint16((nxt shl 8) or dsp)

proc set_panel*(r: var LcdResponse; p: LcdPanel) =
  ## Select the panel (or lpOff). Rebuilding drops the cell state, so a live
  ## switch starts clean rather than carrying the old panel's ghost.
  if r.panel == p and (p == lpOff or r.lut.len > 0): return
  r.panel = p
  r.state.setLen(0)
  if p == lpOff:
    r.lut.setLen(0)
    r.outbuf.setLen(0)
  else:
    r.lut = build_lut(p)

proc reset*(r: var LcdResponse) =
  ## Drop the cell state, so the next frame seeds the cells directly instead of
  ## ghosting into them. Called where a ghost would be from a DIFFERENT machine
  ## — ROM load, core switch, resolution change.
  ##
  ## Deliberately NOT called on a save-state load or a rewind. A panel does not
  ## know a state was loaded: it cross-fades into the new picture over a few
  ## frames exactly as it would for any in-game scene cut, and resetting would
  ## make state loads behave differently from cuts. That is also why none of
  ## this is in the save-state payload — it is not machine state.
  r.state.setLen(0)

proc active*(r: LcdResponse): bool {.inline.} = r.panel != lpOff

proc settled(c: uint16): uint32 {.inline.} =
  ## The packed cell state of a pixel that has already finished settling on
  ## `c`: each 5-bit channel sitting at its own fixed point, code * 8. The
  ## table maps this state to itself, so recognising it lets a settled pixel
  ## skip the lookups entirely — which is most of the screen, most of the
  ## time, in most games.
  (uint32(c and 31) shl 3) or
  (uint32((c shr 5) and 31) shl 11) or
  (uint32((c shr 10) and 31) shl 19)

proc apply*(r: var LcdResponse; fb: ptr UncheckedArray[uint16];
            pixels: int): ptr UncheckedArray[uint16] =
  ## Advance every cell one frame toward this frame's pixels and return what
  ## to display. With the model off (or before it has a table) this is the
  ## core's own framebuffer, unchanged and zero-copy.
  if r.panel == lpOff or r.lut.len == 0: return fb
  if r.outbuf.len != pixels: r.outbuf.setLen(pixels)
  if r.state.len != pixels:
    # First frame after a reset: the cells start already settled on it, so
    # nothing ghosts in from the previous ROM (or from before a state load).
    r.state.setLen(pixels)
    for i in 0 ..< pixels: r.state[i] = settled(fb[i])
  let lut = cast[ptr UncheckedArray[uint16]](addr r.lut[0])
  let st = cast[ptr UncheckedArray[uint32]](addr r.state[0])
  let outb = cast[ptr UncheckedArray[uint16]](addr r.outbuf[0])
  for i in 0 ..< pixels:
    let c = fb[i]
    let s = st[i]
    # Already there and being asked to stay: the table would return the same
    # state and this same colour, so skip it. Games leave most of the screen
    # alone most frames, and the branch predicts well because settled and
    # moving pixels come in runs.
    if s == settled(c):
      outb[i] = c and 0x7FFF
      continue
    let er = lut[(int(s and 0xFF) shl 5) or int(c and 31)]
    let eg = lut[(int((s shr 8) and 0xFF) shl 5) or int((c shr 5) and 31)]
    let eb = lut[(int((s shr 16) and 0xFF) shl 5) or int((c shr 10) and 31)]
    st[i] = uint32(er shr 8) or (uint32(eg shr 8) shl 8) or
            (uint32(eb shr 8) shl 16)
    outb[i] = ((er and 0xFF) shr 3) or
              (((eg and 0xFF) shr 3) shl 5) or
              (((eb and 0xFF) shr 3) shl 10)
  return outb

proc resolve*(m: LcdMode; gba: bool; cgb: bool; sgb = false): LcdPanel =
  ## Turn the user's choice into a panel. Auto follows the machine: a GBA game
  ## gets the AGB-001, a CGB game the colour TFT, and a game running as a DMG
  ## gets the DMG's screen — which is the one that actually matters, since it
  ## is the DMG's slow panel the flicker tricks were written for.
  ##
  ## Auto also turns the model OFF under a Super Game Boy, and that is not a
  ## special case so much as the same rule: the SGB is a SNES cartridge, its
  ## picture leaves through the console's video output, and there is no Game
  ## Boy LCD anywhere in the signal path to be slow. (A CRT's phosphor decay
  ## is a different effect with a different shape — not this one.) Picking a
  ## panel by hand still forces it, for anyone who wants the look regardless.
  case m
  of lmOff:  lpOff
  of lmDmg:  lpDmg
  of lmCgb:  lpCgb
  of lmAgb:  lpAgb
  of lmAgs:  lpAgs
  of lmAuto: (if sgb: lpOff elif gba: lpAgb elif cgb: lpCgb else: lpDmg)

proc parse_mode*(s: string): LcdMode =
  ## Tolerant parse for config files and stored settings; anything unknown is
  ## off rather than an error, so a stale config cannot brick the present path.
  case s
  of "auto", "on", "true": lmAuto
  of "dmg": lmDmg
  of "cgb", "gbc": lmCgb
  of "agb", "agb001", "gba": lmAgb
  of "ags", "ags101", "sp": lmAgs
  else: lmOff
