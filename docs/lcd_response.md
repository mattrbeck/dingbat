# LCD response: the panel model

`src/dingbat/common/lcd_response.nim`, `tests/lcdresponse_test.nim`
(`nimble test_lcdresponse`), `tests/roms/lcdflicker.py`.

## What it replaces

The 50/50 interframe blend ("Motion blur") nulls a 30 Hz alternation
perfectly, which is why the every-other-frame transparency trick looked right
under it (GB/GBC have no blending hardware; the trick relies on LCD latency —
[Link's Awakening disassembly notes](https://zladx.github.io/posts/links-awakening-partial-translucency)).
But a blend is symmetric, level-independent, remembers exactly one frame, and
turns a scene cut into a double exposure. A panel does none of those.

## What a panel does

Every Game Boy screen is a twisted-nematic cell in normally-white mode, so
the two directions are different processes:

| direction | mechanism | speed |
|---|---|---|
| toward darker | the applied field twists the director | fast, faster the harder it is driven: `τ_on ∝ γ₁d² / (ε₀Δε(V² − V_th²))` |
| toward lighter | the cell relaxes elastically | slow, `τ_off = γ₁d² / (π²K)` — independent of voltage, level and step size |

(TN physics; the Newhaven NHD-0420H1Z STN datasheet is the one primary source
found with a rise/fall pair, TR 150 / TF 200 ms.) Visible consequence: a
moving dark object has a crisp leading edge and a dark trail; a light object
on a dark field the mirror image. Grey-to-grey slowness falls out of the same
formula because the drive voltage is set by the target. The DMG's four shades
are four drive voltages, not dither (gbdev.gg8.se thread #80 traces the
IR3E02 contrast rails to V1–V5).

A passive-matrix STN with 144 multiplexed rows must respond slower than the
row-select period or it stops RMS-averaging (Alt–Pleshko "frame response"),
so τ ≫ 16.7 ms is a design requirement on the DMG. The CGB and both GBAs are
active-matrix TFTs, so their persistence is genuinely shorter — the DMG
flicker tricks already looked wrong on a GBC in 1998 (Konami removed
Castlevania II's flickered crawl for the GBC release).

The observer integrates: what an eye or camera accumulates over a frame is
the time-average of the cell's transmittance. The model carries the
end-of-frame state and displays the average. Relaxation and averaging run in
linear light (`γ = 2.2`). Assumed; no instrument measurement of a Game Boy
panel exists.

## The model

Per pixel, per channel, once per emulated frame, `x` in linear light:

```
τ = τ_drive · (1 + knee · x_target)      when darkening
τ = τ_relax                              when lightening
a = 1 − exp(−T / τ)                      T = 16.742 ms
x_end = x_state + a · (x_target − x_state)         carried
x_avg = x_target + (x_state − x_target) · τ · a    displayed
```

Four panels (`LcdPanel`: `dmg` DMG/MGB, `cgb`, `agb` AGB-001, `ags` AGS-101);
the numbers are `SPECS` in the module. They are a fit, not a measurement —
constrained by the ordering (STN slowest, AGS-101 quickest), by the CGB
having to leave 30 Hz flicker perceptible (Castlevania II) and the DMG/AGB
having to hide it (Link's Awakening shadows, Golden Sun's world map, F-Zero
MV's minimap). `ags` is the least-attested panel (its ghosting reputation is
contested). Replace the τ column if a high-speed capture of a DMG ever
appears.

### Panel selection

One switch, "LCD response", in both frontends; the panel is resolved from the
machine: GBA → `agb`, CGB game → `cgb`, DMG → `dmg`, **off under an SGB**
(the picture leaves through a SNES; there is no Game Boy LCD in the path).
GBA resolves to AGB-001 because it is the panel GBA games were signed off
against and the one their alternate-frame effects work on — `ags` measures
an 8/31 swing on a full-range 30 Hz alternation where `agb` gives 2/31
(`tests/lcdresponse_test.nim`). `DINGBAT_BENCH_LCD=<off|on|dmg|cgb|agb|ags>`
forces a panel in `dingbat_bench`.

### Not modelled

* Per-scanline alternate dimming (a different mechanism; it changes static
  content, which this feature must not). Assumed; no ROM pins this.
* Warm-up and temperature dependence.
* Sub-frame timing: the model advances one step per emulated frame.
* Two-player link and rollback netplay present through `linkRgba`, not
  `prepare_game_frame`; wiring them needs one cell-state buffer per player.

## Implementation

One fused table per panel:

```
lut[state8 * 32 + target5] = (next_state8 shl 8) or displayed8
```

`state8` is the settled code in 5.3 fixed point. A settled pixel is a fixed
point of the table (static content is bit-exact, no drift), and every
transition finishes (a zero-rounding step is nudged by one, so nothing sticks
a fraction short). A pixel already at `settled(colour)` is skipped entirely,
which is why the model is cheaper than the blend on quiet screens.

It runs in the present path of both frontends, once per **emulated** frame,
so 120 Hz displays and dropped presents cannot change how the screen settles.
Emulation output is untouched. The cell state is **not serialized**: loading
a state cross-fades into the loaded scene like any cut; cells re-seed on ROM
load, core switch and resolution change.

The web DMG shade palette (`glpresent.js`, `u_dmg_remap`) mixes between the
pair of shades a settling pixel lies between (green is strictly decreasing
across the four shades) instead of exact-matching `DMG_COLORS`; otherwise
every moving pixel would drop back to panel green under a custom palette.

## Evidence

`tests/roms/lcdflicker.gb`: from a cold boot, static shade-0 and shade-3
bands, two bands flickering at exactly 30 Hz in opposite phase (by toggling
`BGP` between `$F0` and `$CC`, nothing written to VRAM), a black sprite
crossing the light band and a white one crossing the dark band. Dump with:

```
DINGBAT_BENCH_LCD=dmg DINGBAT_BENCH_DUMP_SEQ=60:8 \
  DINGBAT_BENCH_DUMP_PATH=/tmp/seq.bin ./dingbat_bench tests/roms/lcdflicker.gb 1 0
```

Full black/white alternating every frame, displayed swing after settling
(`tests/lcdresponse_test.nim` prints these): off 31, blend 0, `dmg` 1, `agb`
2, `cgb` 4, `ags` 8. Link's Awakening walking (48 frames): 100 % of pixels
static for ≥ 16 frames are bit-identical with the model on; 1.7 % of pixels
are altered at all.

No hardware oracle: mealybug photos would constrain endpoints, not time
constants, and no canonical test ROM for the effect is in the local set.

## Cost

Depends on how much of the screen is still settling (not "changed" — a cell
stays off the fast path until it arrives, ~4x the changed set). Crossover is
around 30 % unsettled: cheaper than the blend on quiet screens, up to 1.7x
dearer when every pixel moves. End to end in the browser: +0.035 ms/frame on
GB (+6.6 %), +0.040 ms/frame on GBA (+3.2 %). The slow path is memory-bound
(a 4-byte cell state and three dependent table loads per pixel), so it does
not vectorise the way the blend did. Measure wall clock A/B with both
algorithms in one wasm binary and interleaved; cross-build layout differences
swamp a 3 %-of-tick quantity. Native: use retired instructions.

## Settings migration

`parse_enabled` (native `lcd_response:`) and `LCD_LEGACY_ON` (web
`loadVideoSettings`) must agree:

| stored | becomes |
|---|---|
| nothing / `frame_blend: false` / `motionBlur: false` / `off` | off |
| `frame_blend: true` / `motionBlur: true` / `auto` / `dmg` / `cgb` / `agb` / `ags` | on |
| `true` / `false` | as written |
| anything else | off |

An `ags` user now gets `agb`. The wasm export is `_wasm_set_lcd_response(0|1)`;
`web/types/em.d.ts` is generated (`node web/types/gen-emdts.mjs`).
`web/tests/lcd-response.test.mjs` covers every row.
