# PPU performance: what to build next

**Date:** 2026-07-28
**Follows:** `docs/research_ppu_hotspots.md` (ceilings), `docs/research_dshba_comparison.md`,
`docs/performance.md`
**Purpose:** a decision, not a survey. What to do first, second, third, and what not to do.

## Summary

Three changes are recommended, and all three have been **built, measured, and proved
byte-identical** rather than estimated. Together they are worth **+12.4% native
(mean over five gameplay states) and ~+7% in a real Chrome window**, for roughly 100
lines of code across three self-contained sites.

| | measured native capture | measured web capture | risk | effort |
|---|---|---|---|---|
| 1. SWAR whole-tile BG unpack | **+6.1%** | ~+3% | low | ~35 lines, one function |
| 2. Per-line OBJ candidate list | **+4.6%** | ~+2% | medium | ~45 lines + 1 field + 3 hooks |
| 3. Uniform-window fast path | **+0.8%** (+2.3% Emerald) | ~+0.7% | medium-high | ~15 lines + a test |
| **all three together** | **+12.4%** | **+6.6 to +7.3%** | | |

After all three, the whole-PPU ceiling falls from **+44.4% to +28.5%** — so they capture
about a third of the entire renderer prize. **The compositor's ceiling does not shrink**
(+9.8% before, +10.4% after): it is orthogonal, and it stays the only large item left.

Four things are recommended **against**, three of them newly measured this session: a
coverage-stop lazy BG renderer (+1.4% realistic), a per-line render skip (huge ceiling,
no safe implementation), the SIMD compositor (unchanged verdict), and a GPU renderer —
whose usual objection I found is partly wrong, but which fails on a stronger one.

---

## Method and standards

Native: Apple M2, `nim c -d:test_harness -d:danger -d:lto --opt:speed --path:src`,
`tests/dingbat_bench.nim`, 600 frames after 120 warmup, **best-of-9, interleaved** (every
repetition runs every build×game pair, so drift hits all builds equally), **per-build ROM
copies** so no build boots from another's `.sav`. Five gameplay save states, all verified
to load and all confirmed to be real gameplay (see `research_ppu_hotspots.md`).

Web: a **visible** Chrome window driven over CDP (`web/bench/cdp.mjs`), FireRed from the
same in-game state, `benchTrial(600, 9)`, builds swapped and the page reloaded between
rounds so the A/B is interleaved. Headless was not used — it halves the numbers.

Every prototype below was gated on `DINGBAT_BENCH_HASH=1` rolling framebuffer hashes:

- **5 gameplay states**, 400 frames each — byte-identical.
- **26 local GBA ROMs**, 400 frames from boot each — byte-identical, 0 mismatches. Boot
  sequences reach modes 1-5, affine BGs, affine and double-size sprites, OBJ windows and
  mosaic, none of which the five gameplay states touch.
- **mGBA suite: 6910/7008, sub-suite for sub-suite identical** to baseline
  (1552/1552, 130/130, 1974/2020, 893/936, 90/90, 140/140, 93/93, 72/72, 615/615,
  1256/1256, 90/90, 4/4, 1/10).

### The cautionary example, kept on the record

In the previous round the first version of the uniform-window probe skipped
`compute_line_enables` and composited the line with the `winout` mask instead of the
correct one. It measured **+5.1% / +4.6%** on the two Pokemon titles and was wrong:
`winout` enables fewer layers, so the probe was also making the compositing itself
cheaper. The pixel-exact version measures **+2.3% / +1.8%**.

The rule that follows: **any probe that can change which layers are enabled is not a
ceiling probe until it is hash-gated byte-identical.** Deleting render work is safe to
probe loosely; changing which work is done is not. Every number in this document that
concerns a candidate implementation comes from a byte-identical build.

---

## 1. SWAR whole-tile BG unpack — DO THIS FIRST

**What.** `render_reg_bg` already loads a 4bpp tile row as one aligned `uint32`, then
shifts eight nibbles out of it one at a time, XORing the flip mask and conditionally
OR-ing the palette bank per pixel. Counters show the span is a whole, tile-aligned
8-pixel row for essentially all of it: `px_per_span` is exactly 8.00 for Emerald,
FireRed, Kirby and Minish Cap and 7.80 for Golden Sun. So expand all eight nibbles at
once instead:

```
v = ((v shl 16) or v) and 0x0000FFFF0000FFFF
v = ((v shl 8)  or v) and 0x00FF00FF00FF00FF
v = ((v shl 4)  or v) and 0x0F0F0F0F0F0F0F0F
```

then byte-reverse for horizontal flip, and OR the bank into every non-zero byte with a
carry-free mask (`(v + 0x0F0F…) and 0xF0F0…` is 0x10 per non-zero index and 0x00 per
zero one; `*0x0F` widens that to the bank mask without crossing byte boundaries). One
8-byte store replaces eight 1-byte stores. The 8bpp whole-tile case becomes a single
`uint64` load and store.

**Ceiling and capture — both measured.**

| | Emerald | FireRed | Kirby | MinishCap | GoldenSun | mean |
|---|---|---|---|---|---|---|
| ceiling: `render_reg_bg` deleted | +15.2% | +11.8% | +12.8% | +16.0% | +19.5% | +15.1% |
| ceiling: pixel emission deleted, walk kept | +9.2% | +7.2% | +8.8% | +10.4% | +10.7% | +9.3% |
| **capture: SWAR prototype** | **+6.4%** | **+5.1%** | **+5.3%** | **+6.3%** | **+7.3%** | **+6.1%** |

> **Re-measured on the shipped implementation (2026-07-28): +4.3% native, not
> +6.1%.** Best-of-9 interleaved, per-build ROM copies, same five states, same
> machine — and the baselines reproduce this table's stock numbers to within
> 0.5%, so the gap is the change, not the setup: Emerald +4.64%, FireRed +3.32%,
> Kirby +3.46%, Minish Cap +4.58%, Golden Sun +5.59%. The difference from the
> prototype is that **the shipped version does 4bpp only**. This section also
> proposed collapsing the 8bpp whole-tile span to one uint64 load/store; that
> was deliberately left out (8bpp was required to stay untouched), and it is the
> obvious place to look for the missing ~1.8%. Web re-measured at **+5.2%**
> (visible Chrome, FireRed, best of 4 interleaved rounds of 7; per-round +2.9%
> to +6.7% — noisier than native, but every round favoured SWAR). Bundle cost
> +213 bytes. See `tests/ppubgunpack_test.nim`.

**65% of the pixel-emission ceiling, 40% of the whole component.** That is a far better
capture ratio than the 2026-07-24 round's experience would predict, because this is a
structural change (do the work once instead of eight times) rather than a re-tidying of
the same work.

**Risk: low, and the lowest of the three.** It touches one leaf function whose entire
contract is "write 240 palette indices into `layer_palettes[bg]`". It does **not** touch
blending, windows, priority or semi-transparent objects. The failure mode is wrong BG
pixels — loud, immediate, and exactly what the hash gate catches. The one subtle
invariant is that palette index 0 is transparent in every bank and so must not take the
bank offset; that is what the `nz` mask encodes, and it is worth a dedicated equivalence
test (the shape of `tests/ppucomposite_test.nim`) asserting the SWAR path equals the
scalar path over every nibble value × bank × flip combination.

**Web: yes, verified in the generated wasm.** The three-step expansion survives
compilation as literal `i64.shl` / `i64.or` / `i64.and` with the expected constants
(0x0000FFFF0000FFFF, 0x00FF00FF00FF00FF, 0x0F0F0F0F0F0F0F0F, 0xF0F0F0F0F0F0F0F0) present
in `em.wasm` and absent from the baseline build. It needs no SIMD, so **iOS 15 devices
get it too** — the objection that killed the SIMD compositor does not apply. One honest
caveat: wasm has no byte-swap instruction, so the horizontal-flip path expands to ~14
shift/mask ops instead of AArch64's single `rev`. Still far cheaper than eight loop
iterations, and the measured web gain (~+3% on FireRed) confirms it. Bundle cost: **+522
bytes**, versus the doubled 1.2 MB payload the SIMD proposal implied.

**Effort:** one self-contained edit inside the existing 4bpp/8bpp branches, plus a
fallback to today's loop for partial spans. No new state, no new invalidation.

---

## 2. Per-line OBJ candidate list — DO THIS SECOND

**What.** `render_sprites` walks all 128 OAM entries on every scanline while
**0.2-1.7 sprites per line are actually on the line**. Build a per-visible-line 128-bit
bitmap of the entries whose vertical extent covers that line, rebuilt only when OAM has
been written since the last rebuild, and iterate its set bits.

**Ceiling and capture — both measured.**

| | Emerald | FireRed | Kirby | MinishCap | GoldenSun | mean |
|---|---|---|---|---|---|---|
| ceiling: `render_sprites` deleted | +5.6% | +4.4% | +6.4% | +5.1% | +12.8% | +6.8% |
| ceiling: pixel loop deleted, scan kept | +0.1% | +0.6% | −0.4% | +2.0% | +5.0% | +1.5% |
| **capture: candidate-list prototype** | **+4.9%** | **+3.9%** | **+5.9%** | **+2.0%** | **+6.4%** | **+4.6%** |

**68% of the whole component's ceiling.** Note the middle row: on Emerald, FireRed and
Kirby the sprite *pixel* work is noise, so essentially all of `render_sprites` is the
scan, and the candidate list harvests almost all of it. After this change the component's
residual ceiling falls from +6.8% to **+2.1%**, and what is left is Golden Sun's and
Minish Cap's genuine pixel work.

**Why it is exact.** The per-line loop charges OBJ time only to sprites that pass the
same y test, and breaks on budget exhaustion *before* examining an entry — so visiting
only the covering entries, in OAM order, produces the identical sequence of charges,
drops and pixel writes. The Famicom Mini masking-sprite behaviour (`obj_cycles`
exhaustion dropping later OAM entries) is preserved by construction.

**Rebuild frequency is the design risk, and it measures well.** All five states need
**exactly 1.00 rebuild per frame**, against 160 scans per frame today. But a game that
DMAs OAM during every H-blank would rebuild 160 times a frame and end up *slower* than
baseline. A shipped version needs a guard: count rebuilds per frame and fall back to the
straight scan for the rest of the frame past a threshold. That guard is not in the
prototype and its absence is the main gap between what was measured and what would ship.

**Risk: medium, and it is invalidation, not arithmetic.** The failure mode is a sprite
that is one frame stale or missing on some lines — subtle, intermittent, and much easier
to ship than a wrong BG tile. There are exactly three places to hook: the halfword and
word OAM writes in `bus.nim` (byte writes to OAM are discarded by hardware, so there is
no third write path) and the save-state load. DMA reaches OAM through
`bus.write_word`/`write_half`, so it is covered by the same two hooks — that is worth
re-verifying rather than trusting, because a missed path is exactly the bug this design
invites. It does not touch blending, windows or priority.

**Web: yes.** No host-specific mechanism — a 2×`uint64` bitmap and
`countTrailingZeroBits`, which is wasm's native `i64.ctz`. Measured ~+2% on FireRed in
Chrome. Bundle cost **+1552 bytes**.

**Interaction with the OAM update delay.** `research_dshba_comparison.md` flags that we
do not model DSHBA's one-scanline OAM update delay, and that DSHBA got it nearly free
from its object-batching flags. This prepass is exactly where that would live. **Design
it in now if it is ever going to happen** — retrofitting a delay onto a per-line
candidate structure later means redoing the invalidation reasoning.

---

## 3. Uniform-window fast path — OPTIONAL, THIRD

**What.** Both Pokemon states take the windowed compositing path on **every** line
(96000/96000) and every one of those lines resolves to a **single uniform 240-column
span**: win0 is on, covers the line vertically, and spans the full width. So
`compute_line_enables` writes 240 enable entries and 240 effect flags and the run-length
loop reads all 240 back, to rediscover that they are all the same. Because win0 is
painted last, a full-width win0 makes the whole line its mask — answerable in O(1) from
the registers.

**Capture — measured, byte-identical:** +2.29% Emerald, +1.83% FireRed, and noise on the
other three (**+0.75% mean**). Against the pixel-exact ceiling probe of +2.6% / +1.9%,
that is ~89% capture, i.e. there is nothing left in it.

**Risk: medium-high relative to its size, and this is why it ranks third.** It sits in
window resolution — part of the renderer's hardest code, alongside blending and
priority. The failure mode is a whole line composited with the wrong layer set, which is
loud, but the correctness surface is wider than the prototype: the prototype only covers
"win0 on, full width, no OBJ window". A shipped version wants the general uniformity
test — win1, wrap-around ranges where `x1 > x2`, both windows active, and the OBJ window
forcing the slow path — and its own unit test, not just the case that happens to fire on
Emerald. Do not ship the prototype's special case and call it done.

**Web:** ~+0.7% on FireRed. Bundle cost +192 bytes.

**Honest framing:** +0.8% mean is barely above this machine's noise floor, and it is
worth doing only because (a) the gain is concentrated on two of the best-selling GBA
titles, at +2%, and (b) it is fifteen lines. If the window code is ever being touched for
another reason, fold it in then. On its own it is the weakest of the three.

---

## Sequencing and interaction

**They compose cleanly — measured, not assumed.** Individually +6.06%, +4.63% and
+0.75%; compounded that predicts +11.8%; all three together measure **+12.4%**. Slightly
*above* the compound, so there is no overlap between them (the small excess is
second-order cache effects and is inside the noise band).

**They do not erode the compositor's ceiling.** Deleting the compositor was worth +9.8%
on stock and **+10.4% on top of all three** — unchanged in absolute terms, slightly
larger in relative terms because the denominator shrank. The compositor is orthogonal to
all three items and stays the largest single thing left.

Recommended order: **1 → 2 → 3**, which is also easiest-to-hardest and
biggest-to-smallest. Item 1 has no new state; item 2 introduces the only new invalidation
in the set; item 3 touches the most sensitive code for the least gain.

### What the PPU looks like afterwards — measured

| | stock | after all three | remaining PPU headroom |
|---|---|---|---|
| Emerald | 1181.2 | 1363.0 (+15.4%) | +26.1% (was +45.3%) |
| FireRed | 919.9 | 1024.0 (+11.3%) | +19.1% (was +32.6%) |
| Kirby | 1247.1 | 1394.8 (+11.8%) | +21.8% (was +36.0%) |
| Minish Cap | 1480.9 | 1611.2 (+8.8%) | +30.8% (was +41.7%) |
| Golden Sun | 1364.7 | 1569.6 (+15.0%) | +44.6% (was +66.1%) |
| **mean** | | **+12.4%** | **+28.5%** (was +44.4%) |

Residual per-component ceilings after all three: `render_reg_bg` +9.1% (was +15.1%),
`composite` +10.4% (was +9.8%), `render_sprites` +2.1% (was +6.8%).

### The realistic total, honestly

If items 1-3 ship and a compositor rewrite then captures the ~40-50% of its ceiling that
its three inner loops and data-dependent blend search realistically allow, the aggregate
is roughly **+17 to +18% native** over today (1.124 × ~1.05), leaving perhaps +23% of PPU
headroom untouched. **The PPU's ~44% does not become zero.** Most of the remainder is
the compositor's per-pixel layer walk and `render_reg_bg`'s span/screen-entry work, and
those are only reachable by structural rewrites of the kind the SIMD investigation
already priced and rejected.

---

## Structural hunt: what else is being done and thrown away

Two new candidates surfaced. **Both are recommended against**, and both were worth
measuring because the answer was not obvious.

### A. BG layers rendered but never visible — real, and almost entirely unexploitable

`BG0 is rendered on 100% of scanlines and wins 0% of columns` in **three of five games**
(Emerald, FireRed, Golden Sun). Minish Cap's BG0 is visible on 11.2% of lines, Kirby's on
8.1%. The backdrop wins 0.0% of columns in all five, i.e. the layers above always achieve
full coverage. That looks like a quarter of `render_reg_bg` thrown away.

The exploit would be a top-down compositor that renders the next layer only while some
column is still unresolved. Measured directly — how many BG renders would such a
compositor never have had to perform:

| | Emerald | FireRed | Kirby | MinishCap | GoldenSun |
|---|---|---|---|---|---|
| idle | 20.0% | 10.0% | 8.8% | **0.0%** | **0.0%** |
| moving | 20.0% | 16.3% | 8.8% | **0.0%** | **0.0%** |

Mean ~9% of BG renders, and `render_reg_bg`'s whole ceiling is +15.1%, so the prize is
**~1.4% overall** — for inverting the compositor's control flow, which is the highest-risk
code in the renderer. **Don't.**

The reason the intuition fails is worth recording: the invisible layers are not the
trailing ones in priority order. Minish Cap's BG0 is nearly always invisible *and* nearly
always first in the walk (it is the HUD layer), so nothing after it can be skipped —
0.0% skippable despite 88.8% of its renders being invisible. Occlusion and walk position
are different things.

### B. Scanlines re-rendered to identical pixels — the biggest unexploited prize, and no safe way to take it

Fraction of visible scanlines whose 240 output pixels are **byte-identical to the same
line of the previous frame**:

| | Emerald | FireRed | Kirby | MinishCap | GoldenSun |
|---|---|---|---|---|---|
| idle | 99.6% | 98.4% | 99.9% | 100.0% | 16.2% |
| moving (holding a direction) | 84.8% | 83.4% | 85.4% | 94.7% | 16.2% |

The idle figures are flattering and should not be quoted on their own — a standing-still
scene is not a workload. But **83-95% while the camera is actually scrolling** is the
real number, and it says the renderer reproduces the same scanline four times out of five
during active play. The ceiling here is the whole +44%.

The existing render-skip is frame-granular and driven by `render_dirty`, which any
VRAM/PRAM/OAM/register write sets — and games write OAM every single frame (measured:
exactly 1.00 OAM-dirty transition per frame in all five). So the skip essentially never
fires while 84% of the output is unchanged. **The granularity is the bug, not the idea.**

It is still a **no** for now, because there is no known safe implementation. Knowing a
line is unchanged requires knowing that nothing feeding it changed: the tilemap and
character bytes the line reads (which depend on scroll), PRAM, OAM, and every window and
blend register. That is a dirty-region problem over VRAM with a scroll-dependent
address→line mapping, and the failure mode — a stale scanline held for frames — is the
worst kind for an emulator: silent, intermittent, and invisible to a hash gate that only
compares against itself. Anyone who wants to attempt it should first answer, on paper,
what invalidates a line, and be able to prove it covers H-blank DMA and mid-frame
register writes. Recorded here as the measured ceiling that such work would be aiming at,
not as a recommendation.

---

## What NOT to do

### The GPU renderer — no, but the usual reason is partly wrong

The stated objection has been that our framebuffer is read back every frame by
`frame_static`, the rewind ring, save-state thumbnails and screenshots. Having read the
paths: **the single-player web present path does not read the framebuffer back at all.**
`wasm_fb_ptr`'s comment says so explicitly — colour correction moved into the shader, and
the per-frame path hands the raw BGR555 buffer straight to the texture upload;
`wasm_fb_ptr`'s CPU conversion now runs only for the ~10 Hz ambient-glow sampler and
one-shot thumbnails. `frame_static` is a bool, not a readback. For ordinary single-player
play a GPU renderer would *help* the present path, not fight it.

The readback objection is real but narrower than stated, and it lands here:

- **Rollback netplay reads the whole framebuffer back every frame, twice.**
  `capture_state` calls `state_payload()` for *both* cores every frame, and
  `savestate.nim` serialises all 76,800 bytes of `ppu.framebuffer` into it. Re-simulation
  after a misprediction re-renders on top of that.
- **The rewind ring** pushes a full state payload every `REWIND_INTERVAL` = 10 frames
  (~6/s), each carrying the framebuffer.
- **2P link and rollback present paths** convert to RGBA on the CPU every frame
  (`linkRgba`), unlike the single-core path.
- Thumbnails and screenshots downscale the framebuffer, occasionally.

So: correct conclusion, imprecise mechanism. Worth fixing in the record.

**The decisive objection is a different one, and it is stronger.** A GPU renderer would
**destroy the regression gate this entire investigation depends on.** The primary
correctness evidence in this document — 26 ROMs and 5 states, byte-identical framebuffer
hashes — exists because rendering is deterministic. GPU rasterisation is not
bit-reproducible across drivers, GPU generations or WebGL implementations, so the pixel
A/B would have to become a tolerance comparison, permanently, on the most
correctness-sensitive code in the emulator. Every future renderer change would be
verified more weakly forever. That is a much larger loss than any of the costs previously
listed.

Behind it, unchanged and still sufficient on their own:

- **It is the whole renderer implemented two or three times** — native GL, WebGL2, and a
  scalar fallback for iOS 15 and for correctness. The SIMD investigation rejected dual
  maintenance for the *compositor alone*; this is the compositor plus all four BG
  renderers plus sprites.
- **WebGL2 has no SSBOs**, so DSHBA's design (per-scanline register snapshots in shader
  storage buffers) does not port directly; it would need a UBO/texture re-encoding.
- **The prize is +28.5%, not +44%**, once items 1-3 ship — and a GPU renderer captures
  well under all of it, since per-scanline register uploads and draw-call overhead do not
  vanish.

### The SIMD compositor — verdict unchanged

`performance.md`'s reasoning stands and this session adds nothing that changes it. The
compositor's ceiling reproduced at +9.8% (and +10.4% after items 1-3), the three inner
loops are still three implementations, and wasm SIMD still needs Safari 16.4+. Note the
contrast that items 1 and 2 draw: both get most of a component's ceiling with **no SIMD,
one implementation, and under 2 KB of bundle** — which is the standard the SIMD proposal
should be held to if it is ever revisited.

### Already measured as noise — do not re-attempt

From `research_ppu_hotspots.md` and `research_dshba_comparison.md`, all measured, all
recorded so the effort is not spent twice: the per-scanline BG clears (+0.1%) and the
`sprite_pixels` clear (−0.1% when measured confound-free); a fourth specialised
compositor inner loop for the blend-but-nothing-selected case (+0.0%); hoisting the OBJ
y-range test above the affine-parameter loads (+0.8%); branchless condition codes
(negative); `render_sprites` invariant hoisting (neutral); the CPU dispatch prologue
(neutral).

---

## Reproducing this

The prototypes were `when defined(...)` guards in a throwaway working copy and are not in
the tree. To rebuild them: `optSwarTile` in `render_reg_bg`'s 4bpp/8bpp inner loops,
`optObjList` as a `PPU.obj_line_mask` field plus an `oam_dirty` flag hooked at the two
`of 0x7:` OAM write sites in `bus.nim` and at save-state load, and `optUniformWindow` as
an early return in `composite` before `compute_line_enables`. Each is 15-45 lines. The
structural counters (`probeStruct`) attribute each column's winning layer, compare each
line against a shadow copy of the previous frame, and count OAM-dirty transitions.
