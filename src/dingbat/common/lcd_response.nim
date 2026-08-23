## LCD response: a per-pixel model of how a Game Boy panel settles, replacing
## symmetric interframe blending. Derivation and citations: docs/lcd_response.md.
##
## A normally-white TN cell darkens when driven and relaxes back on its own, so
## the two directions differ: darkening is fast and faster the harder it is
## driven (1/(V^2 - Vth^2), set by the target level; `drive_knee` is the
## near-white slowdown), lightening is a level-independent elastic relaxation
## with one time constant (`tau_relax`). Hence the DMG's crisp leading edge and
## dark trail; getting the sign backwards reads as input lag. The observer
## integrates, so the end-of-frame state is carried but the frame's
## time-average is displayed; both run in linear light (`gamma` is the
## code->light exponent).
##
## Everything is precomputed into one table indexed by (panel state, target
## code): lut[state8 * 32 + target5] = (next_state8 shl 8) or displayed8, with
## state8 the settled code in 5.3 fixed point. A settled pixel maps to itself,
## so static content is bit-exact; where the exponential would round to a zero
## step the table is nudged by one so a pixel always reaches its target.
## Presentation-only: invisible to the cores, not in save states (see reset).

import std/math

type
  LcdPanel* = enum
    ## The panels are different hardware, so one curve cannot serve them all.
    lpOff = "off"
    lpDmg = "dmg"      ## DMG / MGB reflective STN: slowest, most asymmetric
    lpCgb = "cgb"      ## Game Boy Color reflective TFT
    lpAgb = "agb"      ## AGB-001 reflective TFT, the smeary one
    lpAgs = "ags"      ## AGS-101 backlit TFT, close to no ghosting

  PanelSpec = object
    ## Times in milliseconds (comparable with panel datasheets).
    tau_drive:  float  ## toward darker, driven to full black: the fastest case
    drive_knee: float  ## near-white slowdown vs full black (1/(V^2 - Vth^2))
    tau_relax:  float  ## toward lighter: elastic relaxation, level-independent
    gamma:      float  ## code -> linear-light exponent

  LcdResponse* = object
    ## Owned by each frontend; module-scope instances stay unallocated until a
    ## JS-invoked proc touches them (wasm global-teardown rule).
    panel*:  LcdPanel
    disp_gamma: float      ## code->photon exponent the table was built for
    lut:     seq[uint16]   ## 256*32 fused (next_state8 shl 8) or displayed8
    state:   seq[uint32]   ## per-pixel packed 8-bit cell state (r, g, b)
    outbuf:  seq[uint16]   ## BGR555 handed to the uploader

const
  # Both cores run at ~59.73 Hz (70224 dots / 4194304 Hz)
  FRAME_MS = 16.742

  # Panel parameters are a fit: no instrument measurement of a Game Boy panel
  # has been published (docs/lcd_response.md has the citations). Constraints:
  # the DMG is a passive-matrix STN and must be slow (an RMS device with 144
  # multiplexed rows, tau >> 16.7 ms); the CGB and both GBAs are TFTs;
  # relaxation is the slow direction by ~2-3x; the CGB must leave 30 Hz
  # flicker perceptible (Castlevania II's GBC re-release dropped its flickered
  # intro) and the DMG must not; the AGB-001 must hide 30 Hz flicker well
  # (Golden Sun's world map, F-Zero's minimap), the AGS-101 much less so.
  SPECS: array[LcdPanel, PanelSpec] = [
    # lpOff — never consulted
    PanelSpec(tau_drive: 0.0, drive_knee: 0.0, tau_relax:  0.0, gamma: 2.2),
    # lpDmg  reflective STN
    PanelSpec(tau_drive: 12.0, drive_knee: 2.0, tau_relax: 61.0, gamma: 2.2),
    # lpCgb  reflective TFT — active matrix, the quick one of the two STN-era
    PanelSpec(tau_drive:  6.0, drive_knee: 1.5, tau_relax: 24.0, gamma: 2.2),
    # lpAgb  AGB-001 reflective TFT. A stronger fit read as a brightness drop
    # mid-scroll rather than ghosting; tau_relax must stay clear of the CGB's
    # 24 ms so the ordering dmg > agb > cgb > ags holds (28 ms ties it).
    PanelSpec(tau_drive: 12.0, drive_knee: 1.5, tau_relax: 32.0, gamma: 2.2),
    # lpAgs  AGS-101 backlit TFT
    PanelSpec(tau_drive:  3.5, drive_knee: 1.0, tau_relax: 12.0, gamma: 2.2),
  ]

  STATE_MAX = 248'i32   ## 31 * 8: the settled state of a full-scale code

proc build_lut(p: LcdPanel; gamma: float): seq[uint16] =
  ## Precompute the (state, target) -> (next state, displayed) table. `gamma`
  ## is the code->photon exponent of the whole chain downstream, not
  ## necessarily the spec's 2.2: the physics must run in the light the viewer
  ## receives.
  let s = SPECS[p]
  # Into frame units: the model advances exactly one frame per call.
  let tau_drive = s.tau_drive / FRAME_MS
  let tau_relax = s.tau_relax / FRAME_MS
  let inv_g = 1.0 / gamma
  result = newSeq[uint16](256 * 32)
  for st in 0 .. 255:
    let s_code = clamp(float(st) / 8.0, 0.0, 31.0)   # 5.3 fixed point -> 0..31
    let ls = pow(s_code / 31.0, gamma)               # cell transmittance now
    for tg in 0 .. 31:
      let lt = pow(float(tg) / 31.0, gamma)          # transmittance asked for
      # Darkening is driven, its speed set by the target; lightening is a free
      # relaxation with one time constant.
      let tau = if lt < ls: tau_drive * (1.0 + s.drive_knee * lt)
                else: tau_relax
      let a = 1.0 - exp(-1.0 / tau)
      let l_end = ls + a * (lt - ls)
      # Mean transmittance across the frame (closed form for an exponential)
      let l_avg = lt + (ls - lt) * tau * a
      var nxt = int32(round(pow(clamp(l_end, 0.0, 1.0), inv_g) * 31.0 * 8.0))
      # Round to 5 bits here and pre-shift: flooring the 5.3 state instead dims
      # every settling pixel by ~0.44 codes per frame.
      let dsp = int32(round(pow(clamp(l_avg, 0.0, 1.0), inv_g) * 31.0))
                  .clamp(0'i32, 31'i32) shl 3
      nxt = nxt.clamp(0'i32, STATE_MAX)
      # Never stall short of the target (a zero step would leave a permanent ghost)
      let goal = int32(tg) * 8
      if nxt == int32(st) and nxt != goal:
        nxt += (if goal > nxt: 1'i32 else: -1'i32)
      result[st * 32 + tg] = uint16((nxt shl 8) or dsp)

proc set_panel*(r: var LcdResponse; p: LcdPanel; display_gamma = 0.0) =
  ## Select the panel (or lpOff); a rebuild drops the cell state so a live
  ## switch starts clean. `display_gamma` is the code->photon exponent of
  ## whatever follows this model; 0 keeps the spec's 2.2. The GBA
  ## color-correction shader linearizes with lcdGamma 4.0, so while it is
  ## active the AGB table must be built at 4.0 (at 2.2 every settling code
  ## lands darker than computed).
  let g = if display_gamma > 0.0: display_gamma else: SPECS[p].gamma
  if r.panel == p and r.disp_gamma == g and (p == lpOff or r.lut.len > 0):
    return
  r.panel = p
  r.disp_gamma = g
  r.state.setLen(0)
  if p == lpOff:
    r.lut.setLen(0)
    r.outbuf.setLen(0)
  else:
    r.lut = build_lut(p, g)

proc reset*(r: var LcdResponse) =
  ## Drop the cell state so the next frame seeds the cells directly. Called
  ## where a ghost would be from a different machine (ROM load, core switch,
  ## resolution change) but NOT on a state load or rewind: a panel cross-fades
  ## into a new picture exactly as for a scene cut, which is also why none of
  ## this is in the save-state payload.
  r.state.setLen(0)

proc active*(r: LcdResponse): bool {.inline.} = r.panel != lpOff

proc settled(c: uint16): uint32 {.inline.} =
  ## Packed cell state of a pixel already settled on `c` (code * 8 per
  ## channel). The table maps it to itself, so recognising it skips the lookups.
  (uint32(c and 31) shl 3) or
  (uint32((c shr 5) and 31) shl 11) or
  (uint32((c shr 10) and 31) shl 19)

proc apply*(r: var LcdResponse; fb: ptr UncheckedArray[uint16];
            pixels: int): ptr UncheckedArray[uint16] =
  ## Advance every cell one frame toward this frame's pixels and return what
  ## to display; with the model off this is the core's own framebuffer.
  if r.panel == lpOff or r.lut.len == 0: return fb
  if r.outbuf.len != pixels: r.outbuf.setLen(pixels)
  if r.state.len != pixels:
    # First frame after a reset: the cells start settled, nothing ghosts in.
    r.state.setLen(pixels)
    for i in 0 ..< pixels: r.state[i] = settled(fb[i])
  let lut = cast[ptr UncheckedArray[uint16]](addr r.lut[0])
  let st = cast[ptr UncheckedArray[uint32]](addr r.state[0])
  let outb = cast[ptr UncheckedArray[uint16]](addr r.outbuf[0])
  for i in 0 ..< pixels:
    let c = fb[i]
    let s = st[i]
    # Settled and asked to stay: skip the lookups (most of the screen most
    # frames; settled and moving pixels come in runs, so the branch predicts).
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

proc resolve*(on: bool; gba: bool; cgb: bool; sgb = false): LcdPanel =
  ## The panel follows the machine: AGB-001 for GBA, the colour TFT for CGB,
  ## the DMG's screen for a game running as a DMG. GBA picks the AGB-001 over
  ## the AGS-101 because no ROM says which its player owned, and the AGB-001
  ## is the panel the flicker tricks (Golden Sun's world map, F-Zero's
  ## minimap) were written for. Off under a Super Game Boy: the picture leaves
  ## through the SNES video output with no Game Boy LCD in the path.
  if not on: lpOff
  elif sgb: lpOff
  elif gba: lpAgb
  elif cgb: lpCgb
  else:     lpDmg

proc parse_enabled*(s: string): bool =
  ## Tolerant parse for config files. The setting used to be a six-way picker
  ## (off / auto / dmg / cgb / agb / ags): `auto` and the four panel names are
  ## all ON (naming a panel asked for that machine's response). Unknown is off,
  ## not an error.
  case s
  of "auto", "on", "true", "yes",
     "dmg", "cgb", "gbc", "agb", "agb001", "gba", "ags", "ags101", "sp": true
  else: false

proc parse_panel*(s: string; gba: bool; cgb: bool; sgb = false): LcdPanel =
  ## Drive a panel by name for harnesses (DINGBAT_BENCH_LCD, -d: builds). The
  ## four panel names force themselves; everything else goes through resolve.
  case s
  of "dmg": lpDmg
  of "cgb", "gbc": lpCgb
  of "agb", "agb001", "gba": lpAgb
  of "ags", "ags101", "sp": lpAgs
  else: resolve(parse_enabled(s), gba, cgb, sgb)
