# LCD response: replacing interframe blending with a panel model

`src/dingbat/common/lcd_response.nim`, `tests/lcdresponse_test.nim`,
`tests/roms/lcdflicker.py`.

## What was there, and why it had to go

Both front ends used to present the average of the last two frames — mGBA's
"interframe blending", offered to the user as **Motion blur**. Per 5-bit
channel, `(a + b) / 2`, every pixel, every frame.

It exists for a real reason. Game Boy and Game Boy Color have no blending
hardware at all, so the only way to draw something half-transparent is to draw
it every other frame and let the screen average it. The Link's Awakening
disassembly says so outright:

> Neither the GB or the GBC have half-transparent rendering – but they have the
> latency of the LCD screen. So the good old 50% transparency trick is used:
> displaying the portrait only every other frame.
> — zladx.github.io/posts/links-awakening-partial-translucency

A 50/50 average of consecutive frames nulls a 30 Hz alternation *perfectly*,
which is why it makes those effects look right. But it is not what a panel
does, and the ways it differs are all visible:

* **It is symmetric.** A moving dark object gets exactly as much ghost in front
  of it as behind it. Real panels do not work that way (see below), and the
  difference is the single most recognisable thing about a DMG screen.
* **It is level-independent.** Black-to-white and a one-shade nudge in the
  mid-greys settle at the same rate. On an LCD they differ by a lot; the whole
  reason the industry quotes grey-to-grey numbers is that the mid-range is the
  slow part.
* **It has a one-frame memory, exactly.** A real cell is still moving three or
  four frames later.
* **A scene cut becomes a literal double exposure** — one frame at exactly 50%
  of each image, the same whichever way the cut went.
* It is a fixed alpha, so there is nothing to say about which *machine* is being
  emulated. The DMG's screen and an AGS-101's are not remotely the same device.

## What a panel actually does

### Normally white, so the two directions are different processes

Every Game Boy screen is a twisted-nematic cell run in positive (normally
white) mode: with no field across it the liquid crystal passes light — a DMG
with the CPU halted is a uniform pale field — and driving the cell darkens it.
That makes darkening and lightening physically different events:

| direction | mechanism | speed |
|---|---|---|
| toward **darker** | the applied field twists the director | **fast**, and faster the harder it is driven: `τ_on ∝ γ₁d² / (ε₀Δε(V² − V_th²))` |
| toward **lighter** | the field is reduced and the cell relaxes elastically on its own | **slow**, `τ_off = γ₁d² / (π²K)` — material and cell gap only, so it does **not** depend on voltage, level, or step size |

Direction confirmed independently:

* EPFL Display-Corner: *"Usually, the transitions toward the voltage-driven
  state … can be made faster than transitions toward the 'no voltage' state."*
* TN literature: *"Normally white monitors usually switch faster from white to
  black than from black to white."*
* The Newhaven NHD-0420H1Z STN datasheet — the only primary document found with
  a rise/fall pair — gives TR 150 ms typ / TF 200 ms typ at 25 °C. Fall
  (relaxation) slower, by 1.33×.
* brickboy's `ghost.slang`, the only other emulator shader that models
  direction at all, states it as its core cue and warns that getting the sign
  backwards *"is easily misread as input lag."*

The visible consequence is the DMG's signature artifact: **a moving dark object
has a crisp leading edge and a dark trail behind it**, because the pixels it
vacated are the ones taking the slow way home. A white object on a dark field
does the mirror image — a soft, dim leading edge and a clean trailing one. A
symmetric blend cannot express either.

### Grey-to-grey falls out of the same formula

Because the driven time constant depends on the *voltage*, and the voltage is
set by the target, darkening all the way to black is quick while nudging a
near-white pixel one shade down is not. That is where the grey-to-grey slowness
every LCD review measures comes from, and it is why the model has a
target-dependent driven τ rather than a step-dependent one.

This is not idle on the DMG specifically: its four shades are **four distinct
drive voltages**, not dither patterns. Scope work on gbdev.gg8.se (thread #80)
traces the −19 V rail through the IR3E02 contrast chip into V1–V5 reference
levels, with the CPU emitting two bits per dot (`DATAOUT0`/`DATAOUT1`) to select
among four levels. Shade-to-shade transitions genuinely have different drive
magnitudes.

### A passive STN *has* to be slow

The DMG panel is a passive-matrix STN with 144 multiplexed rows, i.e. an
RMS-responding device under Alt–Pleshko addressing. If the liquid crystal could
respond within the row-select repetition period it would stop averaging the RMS
waveform and produce the classic "frame response" defect — non-uniform leakage
in the OFF state and non-uniform transmission in the ON state. τ ≫ 16.7 ms is a
**design requirement** for that panel, not an accident.

That argument does not apply to the CGB or either GBA, which are active-matrix
TFTs and sample-and-hold. Their persistence is genuinely much shorter — which is
why the DMG flicker tricks already looked wrong on a real GBC in 1998. Konami
removed Castlevania II's flickered intro crawl for the GBC re-release for
exactly that reason.

### The observer integrates

What an eye or a camera accumulates over one frame is the *time-average* of the
cell's transmittance across that frame, not its value at the end. The model
therefore carries the end-of-frame state but displays the average. This is not
a fudge factor: our own display holds whatever value we hand it for the whole
frame, so handing it the average is what delivers the same photons. Skipping it
would under-report every transition by roughly half a frame.

The relaxation and the average both run in **linear light**, not in the 5-bit
code. SameBoy (`MasterShader.fsh`, `#define GAMMA 2.2`, `_texture()` raises to
gamma before blending) and brickboy (`bb_ghost_gamma`) arrived at that
independently.

## The model

Per pixel, per channel, once per emulated frame, with `x` in linear light:

```
τ = τ_drive · (1 + knee · x_target)      when darkening   (x_target < x_state)
τ = τ_relax                              when lightening
a = 1 − exp(−T / τ)                      T = 16.742 ms, one frame
x_end = x_state + a · (x_target − x_state)         → carried as the new state
x_avg = x_target + (x_state − x_target) · τ · a    → what is displayed
```

Four parameters per panel: `τ_drive` (the fastest case, driving to full black),
`knee` (how much slower a barely-driven target is — the `1/(V² − V_th²)` shape
collapsed to one number), `τ_relax`, and the code→light exponent `γ = 2.2`.

### Panels modelled, and what the numbers rest on

**Nobody has ever published an instrument measurement of a Game Boy panel** —
no oscilloscope trace, no photodiode, no high-speed capture. (The one article
that looks like it, retrorgb's "Comparing Lag and Ghosting for Every GBA
handheld", measures *input lag* with an LED and a 1000 fps camera and contains
no pixel-response numbers at all.) These are a fit, and the fit is constrained
by the evidence above rather than by a datasheet:

| panel | τ_drive | knee | τ_relax | technology |
|---|---|---|---|---|
| `dmg` DMG / MGB | 12.0 ms | 2.0 | 61.0 ms | reflective STN, passive matrix |
| `cgb` Game Boy Color | 6.0 ms | 1.5 | 24.0 ms | reflective TFT |
| `agb` AGB-001 (unlit GBA) | 9.0 ms | 1.8 | 42.0 ms | reflective TFT |
| `ags` AGS-101 (backlit SP) | 3.5 ms | 1.0 | 12.0 ms | backlit TFT |

* The **DMG** pair is anchored to brickboy's tuned 21 ms driven / 61 ms relaxing.
  `τ_drive` here is the full-black case, so the mid-level darkening the model
  actually produces lands near brickboy's single 21 ms figure.
* The **ordering** (STN slowest; AGS-101 quickest) is the part that is
  documented rather than fitted.
* The **CGB** numbers have to leave a 30 Hz flicker perceptible — Castlevania II
  is the evidence — while the DMG's must not.
* The **AGB-001** has to hide 30 Hz flicker well: Golden Sun's world-map jitter
  and F-Zero: Maximum Velocity's minimap are the cases mGBA cites, and
  nerdlypleasures reports the AGB-001 flicker as "nearly imperceptible to the
  human eye". The AGS-101's reputation is contested (some GBAtemp threads insist
  it ghosts as much or more); this treats it as the quick panel, which is the
  version the same article supports.

`auto` resolves from the running machine — GBA → `agb`, CGB game → `cgb`, a game
running as a DMG → `dmg` — which is the only setting that is right for every
game without being told. It also resolves to **off under a Super Game Boy**,
and that is the same rule rather than an exception: the SGB is a SNES
cartridge, its picture leaves through the console's video output, and there is
no Game Boy LCD anywhere in the path to be slow. (A CRT's phosphor decay is a
different effect with a different shape, and is not this one.) Choosing a panel
by hand still forces it, for anyone who wants the look regardless.

### Deliberately not modelled

* **Per-scanline alternate dimming.** GBCC documents it ("every second line is
  much dimmer, and each frame this alternates between even and odd lines") and
  SameBoy encodes it as its ACCURATE blending mode (`BLEND_BIAS = 1/3` plus
  per-frame parity tracking). It is real, and it is a *different* mechanism from
  persistence — it changes static content, which this feature must not.
  A separate setting, if ever.
* **Warm-up and temperature.** brickboy eases its ghost strength 1.6 → 1.0 over
  the first ~45 s from power-on, and response time is strongly temperature
  dependent. Both are real; neither is something a user would ask for.
* **Sub-frame timing.** The model advances exactly one frame per presented
  frame. A cell physically keeps moving during VBlank and mid-frame, but the
  core hands over whole frames.
* **Two-player link and rollback netplay.** Those modes present through
  `linkRgba` (already colour-corrected RGBA, one buffer per player), not
  through `prepare_game_frame`, so the model does not run there. Wiring it up
  needs one cell-state buffer per player — sharing a single one between two
  cores alternating each frame would produce garbage — and the two-pane view is
  not where anyone is hunting flicker transparency. Known gap, not a bug.

## Implementation: one fused table

Everything above is precomputed per panel into a single lookup table, so the
per-pixel cost is three table reads and some packing:

```
lut[state8 * 32 + target5] = (next_state8 shl 8) or displayed8
```

`state8` is the cell's settled-code value in 5.3 fixed point (0..248, so
`state8 shr 3` is the 5-bit code). Two properties fall out of that layout and
they are what make this a panel model rather than a smear:

* **A settled pixel is a fixed point.** `state8 == target * 8` maps to itself
  and to the target unchanged, so static content is bit-exact — no residual
  smear, no arithmetic drift, and no need for brickboy's `smoothstep` "snap"
  gate.
* **Every transition finishes.** Where the exponential would round to a zero
  step the table is nudged by one, so a pixel always reaches its target instead
  of sticking a fraction short. Without this, an approach slower than 1/8 LSB
  per frame would leave a permanent ghost on a static screen.

The same fixed point gives a fast path: a pixel whose state already equals
`settled(colour)` is skipped entirely. Most of the screen is in that state in
most frames, which is why the model ends up **cheaper than the blend it
replaces** (below).

The model lives in the present path of both front ends, not in the PPU. It runs
once per **emulated** frame, not per present, so a 120 Hz display or a dropped
present cannot change how the screen settles. Emulation output is untouched and
bit-exact; the setting is safe to change mid-frame.

## Save states

The per-pixel cell state is **not serialized** and `GB_PAYLOAD_VERSION` is not
touched. A panel's contents are not machine state.

Consequence, stated plainly: loading a state does *not* reset the cells, so the
picture cross-fades into the loaded scene over three or four frames exactly as
it would for any in-game scene cut. That is deliberate — a real panel does not
know a state was loaded, and resetting would make state loads behave
differently from cuts. The cells are only re-seeded on ROM load, core switch,
and resolution change, where a ghost of the *previous game* would be wrong.
Rewind scrubbing smears for the same reason fast-forwarding a real handheld
does.

## Evidence

### A controlled test ROM

`tests/roms/lcdflicker.py` builds `lcdflicker.gb` (hand-assembled SM83, same
approach as `gblinktest.py`). Real games hide their flicker-transparency deep
inside a save file, which makes an on/off comparison a screenshot of two
different moments. This ROM puts every case on one screen from a cold boot with
no input:

* rows 0–4: solid shade 0 — **static light reference**
* rows 5–8: palette index 1, white on even frames, black on odd
* rows 9–12: palette index 2, the **opposite phase**
* rows 13–17: solid shade 3 — **static dark reference**
* a black sprite crossing the static light band at 2 px/frame, and a white
  sprite crossing the static dark band

Nothing is written to VRAM per frame — the bands flicker purely by alternating
`BGP` between `$F0` and `$CC` — so the flicker is exactly 30 Hz and exactly two
states, with no sprite motion confusing the measurement. Both static bands are
on screen in the same frame as the flickering ones, so a model that smears
static content is caught next to the thing that is supposed to smear.

Dump a sequence with the shipping model applied:

```
DINGBAT_BENCH_LCD=dmg DINGBAT_BENCH_DUMP_SEQ=60:8 \
  DINGBAT_BENCH_DUMP_PATH=/tmp/seq.bin ./dingbat_bench tests/roms/lcdflicker.gb 1 0
```

`DINGBAT_BENCH_DUMP_SEQ=<first>:<count>` and `DINGBAT_BENCH_LCD=<panel>` were
added to `tests/dingbat_bench.nim` for this. The response runs on every frame of
the run-up, not just the dumped ones, so the first dumped frame is mid-response
rather than freshly seeded.

### Flicker transparency, measured

Alternating full black and full white every frame, the displayed value after it
settles (`tests/lcdresponse_test.nim` prints these):

| | displayed range | swing |
|---|---|---|
| off | 0 / 31 | **31** — a strobe |
| old 50/50 blend | 15 / 15 | 0 |
| `dmg` | 13..14 | **1** |
| `agb` | 13..15 | 2 |
| `cgb` | 14..18 | 4 |
| `ags` | 13..21 | 8 |

The DMG knocks a full-range 30 Hz alternation down to a one-code shimmer around
a mid-tone — the "50% transparency" the games were written against. For the
*actual* DMG case, shade 0 alternating with shade 3, the swing is 0.11/31: flat.
And the ordering is the point: the panels the tricks were written for hide the
flicker, the panels that came later increasingly do not, which is what Konami
found in 1998.

### Static content is untouched, in a real game

48 frames of Link's Awakening (DMG) walking around Mabe Village, model off vs
`dmg`:

* pixels unchanged for ≥ 16 frames: 1 083 225 of 1 105 920 (97.9%)
* of those, **bit-identical with the model on: 1 083 225 (100.0000%)**
* pixels the model alters at all: 19 006 (1.72%)

The model touches the 1.7% of the screen that is moving and provably nothing
else.

### Figures

Generated into the scratch dir (paths listed in the handover), all from the
shipping code path via `dingbat_bench`:

* `fig_flicker_4row.png` — six consecutive frames of `lcdflicker.gb`, four rows:
  off (both bands strobe), 50/50 blend (both bands collapse to the *same* flat
  mid-tone), `dmg` (steady, and the two phases settle at slightly *different*
  levels — a symmetric blend cannot do that), `ags` (still visibly alternating).
* `fig_trail_zoom.png` — the black sprite on the static light band. Off: crisp.
  Blend: a symmetric one-pixel halo on **both** sides. `dmg`: a long trail
  behind it and a crisp leading edge.
* `fig_trail_zoom_white.png` — the white sprite on the static dark band, the
  mirror case: never reaches full white while moving, soft leading edge, clean
  trailing edge. The blend renders it identically to the black sprite, mirrored;
  the panel does not.
* `fig_la_walk.png` — Link's Awakening, four consecutive frames, off / blend /
  `dmg`. The room is pixel-identical; Link and Marin carry a directional trail.

### What could not be validated

* **No hardware oracle.** `mealybug-tearoom-tests` has no `photos/` directory in
  either checkout on this machine, and the sibling agent's photo-recovery
  pipeline had not landed anything by the time this was written. Even with it,
  the photos are stills: they would constrain the endpoints of the curve, not
  the time constants.
* **No time constant is measured.** Everything in the τ column is a fit against
  qualitative constraints. If a high-speed capture of a DMG ever appears, that
  is the number to replace.
* **No canonical test ROM was available.** The games the emulator-dev literature
  actually cites for this — Chikyuu Kaihou Gun ZAS, Wave Race (which has a
  `Select` toggle to make its translucent status bar solid, i.e. free ground
  truth), Serpent, Ballistic, F-Zero: Maximum Velocity — are none of them in the
  ROM set here. Of the eight that were: Link's Awakening (DMG) is documented as
  drawing shadows and cut grass every other frame but needs the sword first;
  Golden Sun's world-map jitter is mGBA's headline GBA example but is 45–90
  minutes in; Shantae's developers confirm a "sprite-interlacing trick" for
  translucency but no source names a scene. An automated sweep over 900 frames
  of each ROM's boot and attract mode (scoring strict 2-cycle pixel runs) found
  no sustained localised flicker to photograph. Hence the purpose-built ROM.
* **The native GUI was compile-verified, not run.** It needs a real GL context;
  `SDL_VIDEODRIVER=dummy` refuses one. The model itself is covered by unit tests
  and driven end-to-end through `dingbat_bench`, and the native present path is
  a three-line call into the same module. The web front end *was* driven
  end-to-end in headless Chromium (the real `<select>`, canvas pixels read back).

## Cost

The first pass at this section claimed the model was flatly cheaper than the
blend — 0.53x on GB, 0.34x on GBA in the browser, 0.29x native. **Those figures
were wrong**, in two separate ways, and both are worth recording because they
are easy traps:

1. The native arm compared against the *web* blend's per-channel unpack
   (25 instr/px) rather than the native SWAR one (14 instr/px without checks),
   and it gave the blend `seq` indexing — i.e. bounds checks — while the new
   module used `UncheckedArray`. Half of what looked like an algorithmic win
   was a checks asymmetry.
2. The web arm was an end-to-end `loop_tick` A/B across two *different* wasm
   builds. The quantity being measured is ~3% of a tick, and the cross-build
   difference in code layout swamped it: the deltas it reported (+0.145 vs
   +0.076 ms) are four times larger than the pixel loops actually cost when
   measured in isolation.

### What it actually costs

The honest answer is that the cost depends entirely on how much of the screen
is **still settling**, and the model is cheaper on quiet screens and dearer on
busy ones. The crossover is around 30% of pixels unsettled.

Note "unsettled", not "changed". A pixel leaves the fast path when its cell is
not yet at its target and stays off it until it arrives — several frames after
it last changed. **The model's own slowness enlarges its own working set**, by
roughly 4x for content where the changes move around the screen.

**Browser** — both algorithms compiled into ONE wasm binary, replayed over a
captured ring of real core frames, interleaved within a single page on a single
origin, batch size auto-calibrated so every timing window is >= 60 ms (well
clear of `performance.now()` coarsening), median of 11. One binary means there
is no file swap for a stale service worker to void, and no cross-build layout
luck; measured spreads are under 2%. Absolute ms drift ~20% between *runs* with
machine load, so only within-run ratios are meaningful.

| content | pixels changed/frame | still settling | blend | response | ratio |
|---|---|---|---|---|---|
| Golden Sun, GBA (a static screen) | 0.0% | 0.3% | 0.0551 | 0.0389 | **0.71x** |
| Pokémon Crystal, GBC | 1.5% | 7.2% | 0.0331 | 0.0292 | **0.88x** |
| Link's Awakening, GB (title, wave) | 4.2% | 17.8% | 0.0398 | 0.0392 | **0.98x** |
| `lcdflicker.gb` (two bands at 30 Hz) | 44.7% | 46.3% | 0.0331 | 0.0386 | **1.17x** |
| pathological: every pixel, every frame | 100% | 100% | 0.0343 | 0.0586 | **1.71x** |

End-to-end, which is what the user pays — the same shipped build, the setting
toggled off vs `auto`, interleaved, median of 15 x 900 `loop_tick` calls,
spreads under 1%:

| ROM | off | auto | cost of the feature |
|---|---|---|---|
| Link's Awakening (GB → `dmg`) | 0.5288 ms | 0.5634 ms | **+0.0347 ms/frame (+6.6%)** |
| Golden Sun (GBA → `agb`) | 1.2491 ms | 1.2889 ms | **+0.0398 ms/frame (+3.2%)** |

Those deltas agree with the isolated pixel-loop numbers above to within 6%,
which is the cross-check that says the end-to-end measurement is measuring the
pixel loop and not build noise.

**Native**, by RETIRED INSTRUCTIONS (`proc_pid_rusage` RUSAGE_INFO_V4, the same
counter `DINGBAT_BENCH_COUNTERS=1` uses) as well as wall clock, because
wall-clock A/B on this codebase is unreliable below ~1.3%. Four arms, so the
checks asymmetry is visible rather than hidden:

| arm | instr/px |
|---|---|
| native blend as shipped (SWAR, `seq` indexing, `-d:release` bounds checks) | 28.00 |
| the same SWAR arithmetic on `UncheckedArray` | 14.00 |
| the web blend's per-channel unpack, no checks (what wasm shipped) | 25.00 |
| LCD response, fast path only (fully static screen) | 17.00 |
| LCD response, slow path only (pathological) | 35.94 |
| LCD response, Link's Awakening walking (2.0% of pixels changing) | 17.39 |

Half the old *native* blend's cost was bounds checking. Against the algorithm
alone the model is 1.2x on quiet content and 2.6x pathological; against what
actually shipped it is 0.6x and 1.3x.

Wall clock native (median of 9 x 300, 160x144 / 240x160):

| regime | shipped blend | response | ratio |
|---|---|---|---|
| fully static | 0.0306 | 0.0157 | 0.51x |
| LA walking (2.0% changing) | 0.0247 | 0.0175 | 0.71x |
| pathological | 0.0246 | 0.0419 | 1.70x |
| Golden Sun busy transition, 240x160 (32.7% changing) | 0.0441 | 0.0761 | 1.73x |

That last row is the one to keep in mind: the response executes **fewer**
instructions than the shipped blend there (26.10 vs 28.00 per pixel) and still
takes 1.73x the time. The slow path is memory- and latency-bound, not
instruction-bound — it moves a 4-byte cell state per pixel where the blend
moved 2, and its three table loads are dependent on that state, so they cannot
be hoisted or vectorised the way the blend's arithmetic can.

### Why those numbers, from the operation counts

The instruction counts are not a black box; they follow from the loops, which
is the check that says the measurement is believable rather than lucky.

* **fast path (17/px)**: two loads (frame, state), eight ops to rebuild
  `settled(colour)` from the frame pixel, a compare and a well-predicted
  branch, one mask and one store, three for the loop.
* **slow path (36/px)**: the same prologue, then three table-index
  computations and three loads, seven ops to repack the state, ten to repack
  the output, two stores.
* **native SWAR blend (14/px)**: two loads, eight ops (`and`/`shr`/`add` on
  the packed word — no unpacking at all), two stores, three for the loop.
* **web per-channel blend (25/px)**: two loads, eight ops to unpack six
  channels, three adds, three shifts, two shifts and two ors to repack, two
  stores, three for the loop.

So per pixel the model IS dearer than the native blend — it has to be, it does
more — and the only reason it comes out ahead in ordinary use is that most of
the screen never reaches the slow path. That is a real win and it is the one
that matters for a user, but it is a different claim from "the model is cheaper
per pixel", which is false.

## The settings surface

There is now one control, not two. **Motion blur** (a checkbox) became **LCD
response** (a picker: Off / Auto / DMG / Game Boy Color / GBA AGB-001 / GBA SP
AGS-101), in both front ends. Two settings that both mean "ghost the previous
frame" would have been indefensible.

Migration, in both directions, is that anyone who had motion blur **on** gets
`auto` — they had asked for panel ghosting and they keep it, now matching their
machine — and anyone who had it off gets `off`:

* native, `config.nim`: a `lcd_response:` key wins; failing that, a legacy
  `frame_blend: true` maps to `auto`. Verified for both values, an unknown
  string, an absent key, and a save/load round trip.
* web, `index.js` `loadVideoSettings`: `v.lcdResponse` wins; failing that,
  `v.motionBlur` maps to `"auto"`. An unrecognised stored value falls back to
  `off` rather than sliding into the wasm call as `NaN`.
  `web/tests/lcd-response.test.mjs` covers all of it, including that the
  `<option>` order in the markup still matches `LCD_MODES` — that index *is* the
  wire format.

The wasm export `_wasm_set_frame_blend(0|1)` was replaced by
`_wasm_set_lcd_response(ordinal)`; both `dingbat_wasm.nims`' export list and the
one JS caller moved with it.

### One thing the response forced open

The web presenter's Game Boy shade palette (`glpresent.js`, `u_dmg_remap`) used
to substitute the four `DMG_COLORS` by exact match. A settling pixel sits
*between* two shades for a few frames, so with a custom palette every moving
pixel would have dropped back to the built-in green while the rest of the screen
wore the chosen colours — a latent bug the old blend had too, just less often.
`fetchRGB` now finds which pair of shades a pixel lies between (green is
strictly decreasing across the four, so it is a usable key) and mixes the
corresponding pair of palette entries. Exactly-a-shade still lands exactly on
its entry, and a pixel that is not near the ramp is left alone — which is what
keeps a mis-gated colour title safe.

## Recommendation

**Default it to `auto`.** It is shipped `off`, because that was the instruction,
but off is the wrong default and here is the case:

1. It is an accuracy feature. With it off, a documented class of games renders
   in a way the developers never saw and never intended — Link's Awakening's
   shadows strobe instead of being translucent, Golden Sun's world map shakes.
   mGBA's own release notes call the flicker "an intended effect on hardware".
   Every other display-accuracy default in this emulator (colour correction, the
   FIFO renderer) is already on.
2. It is affordable, and about the same price as the feature it replaces: it
   costs **+0.035 ms/frame on GB (+6.6%) and +0.040 ms/frame on GBA (+3.2%)**
   end to end, and its pixel loop is cheaper than the old blend's on quiet
   screens, level on ordinary ones, and up to 1.7x dearer only while the whole
   screen is moving. Interframe blending was already considered affordable at
   a comparable price, and the worst case here lasts as long as a screen
   transition does.
3. `auto` means nobody has to know what an AGS-101 is. The machine picks.
4. ares enables interframe blending by default for DMG, CGB and GBA. SameBoy
   defaults to its ACCURATE blending mode. Defaulting this off is the outlier.

There are two counter-arguments and they are worth stating.

* `dmg` is a strong look — the trail behind a fast sprite is several frames
  long, which is faithful but is a bigger visual change than colour correction
  was. The panel that produces the heaviest smear is also the one whose smear
  is best attested, so the answer to that is not to weaken the curve.
* The cost is not free and it is worst exactly when the machine is busiest: a
  full-screen transition is both the most expensive frame to emulate and the
  frame where the model does the most work. On the measurements here that is
  ~0.08 ms on a 240x160 frame, against a ~1.25 ms tick, so it does not
  threaten the frame budget — but it is the number to watch if the model ever
  moves somewhere hotter.

**Naming**: keep "LCD response". "Motion blur" described a video effect;
"interframe blending" described an implementation. This one describes the
hardware, and the tooltip can carry the rest.
