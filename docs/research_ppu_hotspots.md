# Research: PPU hotspots across five real-gameplay save states

**Date:** 2026-07-27
**Question:** `docs/research_dshba_comparison.md` measured that deleting PPU rendering
entirely is worth +20% to +85% (mean ~+47%), five times the +9% the 2026-07-24 round
had inferred. That round's per-component verdicts — "the compositor is the only
structural PPU item left" and "`render_reg_bg` is near optimal (+4.8% ceiling)" — were
both derived from a single Pokemon FireRed save state that turns out to be 100%
windowed compositing. This is the redo: per-component ceilings and leaf-weighted
profiles across five varied gameplay scenes.

**Short answer:** the ranking flips. **`render_reg_bg` is the single largest PPU item
at a +15.2% mean ceiling**, more than three times the +4.8% it was retired on, and
about 60% of that (**+9.4%**) is the per-pixel tile-row unpack rather than the span
walk. The compositor's +9.4% mean roughly confirms the old number but is now second,
not first. The genuinely new item is **`render_sprites`' per-line 128-entry OAM scan**:
it costs ~5% of total runtime to look at 128 sprites per scanline when 0.2-1.7 of them
are actually on the line. Three probes came back as noise and are recorded so the
effort is not spent twice.

---

## Method

Native only, Apple M2, `nim c -d:test_harness -d:danger -d:lto --opt:speed --path:src`
(so `-mno-outline` from `nim.cfg` is in effect), via `tests/dingbat_bench.nim`,
**600 frames after 120 warmup, best-of-9**.

- **Interleaved sweep.** Every repetition runs every (build, game) pair before the
  next repetition starts, so thermal drift hits all builds equally. All ceilings in
  one table come from a single sweep against a single baseline.
- **Per-build ROM copies.** Each build got its own directory containing its own copy
  of all five ROMs, so build A's `.sav` writes cannot change what build B boots into
  (the trap recorded in `performance.md`).
- **Noise floor.** Single runs of the same binary spread 5-10% best-to-worst on this
  machine. Best-of-9 is stable to roughly ±0.5%; **treat anything under ~1% as noise**,
  and the tables below say so explicitly where that applies.
- Probes are `when defined(probeX)` guards in a throwaway working copy of
  `src/dingbat/gba/ppu.nim`; the tree is reverted, `git diff` is empty apart from this
  file.

**Probe validity.** Stub-out probes that delete render work are valid: the emulated CPU
never reads the framebuffer, so removing rendering cannot change what the game
executes. Two of the probes below are additionally **pixel-exact** and were gated on
`DINGBAT_BENCH_HASH=1` producing byte-identical rolling framebuffer hashes across all
five states; those are called out where they appear. No probe touches CPU, IRQ or
scheduler behaviour.

### The five workloads, verified

Every state loaded (no `state load REJECTED`), and every one was dumped to a PNG and
looked at before it was measured:

| Workload | State | Scene | baseline fps | realtime |
|---|---|---|---|---|
| Pokemon Emerald | `PokemonEmerald.state` | Littleroot-style overworld, player between two houses | 1167.7 | 19.6x |
| Pokemon FireRed | `PokemonFireRed (1).state` | Pallet-style town crossroads, Poke Mart + Center visible | 910.3 | 15.2x |
| Kirby: Nightmare in Dream Land | `KirbyNightmareInDreamland.state` | Level 1 side-scroller, multi-layer parallax sky/mountains | 1241.9 | 20.8x |
| Zelda: The Minish Cap | `... (USA) (1).state` | Link's house interior, HUD + button prompts | 1472.5 | 24.7x |
| Golden Sun | `GoldenSun.state` | Vale overworld in rain, weather overlay active | 1353.0 | 22.7x |

Note the FireRed state used here is a **different, in-game** one from the state the
2026-07-24 round was tuned against.

A counter build confirms all five are **DISPCNT mode 0** (text BGs only, no affine, no
bitmap) and that **all 160 visible lines render on every frame** in all five — the
render-skip path never fires on any of these scenes, so nothing here is measuring a
static screen.

---

## 1. Per-game leaf-weighted profile

macOS `sample`, 10 s at 1 ms, `Sort by top of stack` section (leaf-weighted), Nim
mangling stripped and generic instantiations of the same proc summed. ~8500 samples
per game.

| Component | Emerald | FireRed | Kirby | MinishCap | GoldenSun |
|---|---|---|---|---|---|
| `step_frame` self (= `cpu.tick` fully inlined) | 25.5% | 29.0% | 24.5% | 32.0% | 20.5% |
| **`render_reg_bg`** | **14.6%** | **11.1%** | **11.0%** | **12.7%** | **17.3%** |
| `composite_span` (all three inner loops inlined) | 6.5% | 5.6% | 7.8% | 8.3% | 11.3% |
| `render_sprites` | 6.0% | 4.2% | 5.6% | 4.9% | 9.7% |
| scheduler dispatch closure (`scanline` body inlined) | 7.0% | 4.9% | 4.2% | 4.1% | 4.4% |
| `fetch_half` | 9.0% | 12.5% | 12.1% | 5.2% | 7.4% |
| `fetch_word` | 3.5% | 2.5% | 2.0% | 4.9% | 2.2% |
| ARM/THUMB instruction handlers | 17.0% | 15.3% | 14.2% | 17.4% | 16.4% |
| *(named PPU subtotal)* | *27.1%* | *21.0%* | *24.4%* | *25.9%* | *38.2%* |

`render_aff_bg` and `render_bitmap` do not appear: all five states are mode 0.
`composite`, `compute_line_enables`, `compute_layer_walk` and `fill_window_cols` are
fully inlined — into `composite_span` and into the scheduler dispatch closure — so they
have no separate leaf entry. Everything else was below 1.0% in every game except
`apu_catchup_all` (0.1-2.9%), `get_sample` (1.2-2.4%) and `analyze_loop` (0.5-2.3%).

**`render_reg_bg` is the largest named PPU component in all five games**, by a factor
of 1.4-2.6x over the compositor. The FireRed-derived profile in `performance.md`
(compositor 11.8%, `render_reg_bg` 8.5%) had them the other way round.

---

## 2. Per-component stub-out ceilings

One interleaved sweep, best-of-9, all against the same baseline. Every row is a
separate build from one source tree.

| Probe | Emerald | FireRed | Kirby | MinishCap | GoldenSun | mean |
|---|---|---|---|---|---|---|
| whole `scanline` body removed | +45.3% | +32.4% | +34.5% | +41.6% | +66.3% | **+44.0%** |
| `render_reg_bg` removed | +16.0% | +12.1% | +12.4% | +15.9% | +19.7% | **+15.2%** |
| `composite` removed | +10.5% | +7.7% | +6.6% | +9.0% | +13.1% | **+9.4%** |
| `render_sprites` removed | +6.1% | +4.5% | +5.8% | +5.0% | +13.0% | **+6.9%** |
| per-scanline BG palette clears removed | +0.2% | +0.3% | −0.3% | +0.2% | +0.2% | +0.1% *(noise)* |
| per-scanline `sprite_pixels` clear removed | +1.8% | +1.2% | +1.1% | +3.9% | +9.4% | +3.5% *(**confounded** — see §5)* |

The whole-renderer figure reproduces `research_dshba_comparison.md`'s result on a
disjoint set of scenes: +32% to +66%, mean +44% against its +20% to +85%, mean +47%.
Emerald lands on +45.3% here against +44.8% there, which is the same save state.

Note how far boot sequences are from gameplay: FireRed measured +19.8% from boot in
that document and **+32.4%** from this in-game state; Kirby measured +46.8% from boot
and **+34.5%** in-game. Boot workloads are not a substitute in either direction.

**Consistency check.** Converting each ceiling `c` to a time fraction `c/(1+c)` and
comparing against the profile: `render_reg_bg` predicts 13.8 / 10.8 / 11.1 / 13.7 /
16.5% against a measured 14.6 / 11.1 / 11.0 / 12.7 / 17.3%; `render_sprites` predicts
5.8 / 4.3 / 5.5 / 4.7 / 11.5% against 6.0 / 4.2 / 5.6 / 4.9 / 9.7%. The two independent
instruments agree, which is the main reason to trust either.

---

## 3. Which compositor path each game actually uses

`performance.md` has a version of this table taken from 400-frame boot sequences. This
is the real-gameplay version, counted over the measured 600-frame window.

There are two independent axes in the current code, and the old fast/blend-only/windowed
table conflates them:

- **`composite` outer:** whole-line (no window applies to this line — one
  `composite_span` over all 240 columns) vs windowed (build `line_enables` per column,
  then split the line into runs of identical window state).
- **`composite_span` inner:** `composite_span_opaque` (no colour math can apply —
  first opaque pixel in priority order wins), `composite_span_shade`
  (brighten/darken only), or the general blend loop.

Percentages are of composited columns:

| Game | whole-line | windowed | opaque | shade | blend | BGs in walk |
|---|---|---|---|---|---|---|
| Pokemon Emerald | — | **100%** | **100%** | — | — | 4 |
| Pokemon FireRed | — | **100%** | **100%** | — | — | 4 |
| Kirby | **100%** | — | **100%** | — | — | 3 |
| Minish Cap | **100%** | — | **100%** | — | — | 3 |
| Golden Sun | **100%** | — | 31.6% | — | **68.4%** | 4 |

Two things fall out of this that the boot-derived table could not show:

**Both Pokemon titles take the windowed path on every single line, and every one of
those lines resolves to exactly one uniform 240-column span** (96000 lines, 96000
spans). The window configuration is win0 only, vertically covering the line and
horizontally covering the full width — so `compute_line_enables` writes 240 enable
entries and 240 effect flags, and the run-length loop then reads all 240 back, purely
to rediscover that they are all the same. Cost is measured in §4.

**Golden Sun runs 68.4% of its columns through the general blend loop, but only 0.9% of
those pixels ever search for a blend bottom layer.** The other 99.1% do the top-layer
walk and store it unmodified — the same work the opaque loop does. Cost is also
measured in §4, and it is nil.

The `shade` loop was never entered by any of the five.

---

## 4. Where inside each component the time goes

Second-tier probes, same sweep, same baseline.

| Probe | Emerald | FireRed | Kirby | MinishCap | GoldenSun | mean |
|---|---|---|---|---|---|---|
| `render_reg_bg` pixel emission removed, span walk + screen-entry fetch kept | +9.5% | +7.4% | +8.0% | +9.9% | +11.9% | **+9.4%** |
| `render_sprites` pixel loop removed, full OAM scan kept | +0.1% | +0.6% | −0.4% | +2.0% | +5.0% | +1.5% |
| OAM scan visits 8 entries per line instead of 128 | +5.3% | +4.1% | +5.2% | +3.7% | +7.7% | **+5.2%** |
| uniform-window fast path *(pixel-exact, hash-gated)* | +2.6% | +1.9% | −0.7% | +0.1% | −0.5% | +0.7% |
| every span forced through `composite_span_opaque` | −0.3% | −0.3% | −0.4% | −0.3% | +1.3% | +0.0% *(noise)* |
| OBJ y-range test hoisted above the affine-parameter loads *(pixel-exact, hash-gated)* | +1.2% | +0.8% | +0.8% | −0.3% | +1.4% | +0.8% |
| `sprite_pixels` clear done **twice** *(pixel-exact, hash-gated)* | +0.3% | +0.0% | −0.2% | −0.5% | −0.1% | −0.1% *(noise)* |

### `render_reg_bg` splits roughly 60/40 into unpack vs walk

Of the component's +15.2% mean ceiling, **+9.4% is the per-pixel tile-row unpack** and
only ~+5.6% is the span walk, screen-entry fetch and loop setup. The unpack is the
4bpp inner loop: shift a nibble out of the pre-loaded row word, XOR the flip mask,
conditionally OR the palette bank, store one byte — eight times per tile.

Counters say that loop is almost always a **full, tile-aligned 8-pixel span**:
`px_per_span` is exactly 8.00 for Emerald, FireRed, Kirby and Minish Cap (their BG
scroll offsets are multiples of 8, so all 30 spans per line per BG are whole tiles),
and 7.80 for Golden Sun (~29 whole tiles plus 2 partial edge spans out of 30.8). So a
specialised "whole aligned 4bpp tile row" path would cover ~97% of spans.

### Almost all of `render_sprites` is the OAM scan, not pixel work

| Game | OAM entries examined per line | sprites actually on the line |
|---|---|---|
| Pokemon Emerald | 128.0 | 0.3 |
| Pokemon FireRed | 128.0 | 0.2 |
| Kirby | 128.0 | 0.3 |
| Minish Cap | 128.0 | 1.2 |
| Golden Sun | 128.0 | 1.7 |

Deleting the entire per-pixel sprite loop is **noise** on Emerald, FireRed and Kirby
(+0.1 / +0.6 / −0.4%) — all of `render_sprites`' cost in those three is the 128-entry
scan. Visiting 8 entries instead of 128 recovers **+5.2% mean, which is 76% of the
component's whole +6.9% ceiling.**

Hoisting the y-range test above the four strided affine-parameter loads is pixel-exact
and byte-identical on all five states, but only worth +0.8% mean — barely above noise.
The cost is not the work per rejected entry, it is the 20480 iterations per frame.
**Capturing this needs a candidate list, not a reordering.**

### The uniform-window fast path is worth ~2%, not ~5%

The first version of this probe skipped `compute_line_enables` and composited the line
with the `winout` mask instead, and measured +5.1% / +4.6% on the two Pokemon titles.
That was wrong: `winout` enables fewer layers, so the probe was also making the
compositing itself cheaper. The pixel-exact version — answer the uniform case from the
window registers, since win0 is painted last and a full-width win0 makes every column
identical — is byte-identical to baseline on all five states and measures **+2.6% /
+1.9%**, noise on the other three. Recorded because the confounded number is the sort
that gets quoted.

---

## 5. Negative results

Four things measured as noise or were confounded. All are recorded so they are not
re-attempted.

**The per-scanline buffer clears cost nothing.** Removing the BG palette clears is
+0.1% mean, which reproduces the `research_dshba_comparison.md` result on new scenes.
Removing the `sprite_pixels` clear *appears* to be worth +3.5% mean (+9.4% on Golden
Sun) — **and that number is an artefact**. With the clear gone, stale sprite pixels
from previous lines persist, and the compositor's per-pixel layer walk short-circuits
on them (`if sprio <= w.prio[i]` hits at i=0 far more often), skipping BG layers it
would otherwise have to test. The probe was measuring cheaper compositing, not a
cheaper clear.

The confound-free version — keep the real clear, add a **second** identical clear into
a dummy buffer, so output is byte-identical by construction — measures **−0.1% mean**.
One clear costs nothing. clang turns both loops into wide stores over a 1440-byte
L1-resident buffer. Neither clear is worth touching.

**Specialising the "blend enabled but nothing selected" case is worth nothing.**
Forcing every span through `composite_span_opaque` measures +0.0% mean and +1.3% on
Golden Sun, the only game that reaches the blend loop at all. Despite 99.1% of Golden
Sun's blend-loop pixels never searching for a bottom layer, the general loop's extra
per-pixel bookkeeping (`idx`, `top_blends`, `top_selected`) is essentially free next to
the layer walk they share. A fourth specialised inner loop would buy ~1% on one game.

**Affine BG rendering is irrelevant to these workloads.** All five states are mode 0;
stubbing `render_aff_bg` measured −0.2% mean, i.e. nothing, as it must.

---

## 6. Ranked list of what to attack

Ceilings are mean over the five games; per-game spread in brackets.

### 1. `render_reg_bg` whole-tile 4bpp unpack — ceiling **+9.4%** [+7.4 to +11.9%]

The largest single capturable item, and the one the previous round explicitly retired.
~97% of spans are whole, tile-aligned, 8-pixel 4bpp rows, and the row is already loaded
as one aligned `uint32`. Expanding 8 nibbles to 8 bytes is a fixed SWAR sequence
(shift/mask interleave into a `uint64`), horizontal flip is a byte reverse, and the
"add the palette bank unless the index is 0" step is a mask-and-add. The partial-span
and 8bpp cases keep the current loop.

**Risk: moderate but well-bounded.** It changes one leaf function with a purely local
contract (write 240 palette indices into `layer_palettes[bg]`), the transparent-index-0
rule is the only subtlety, and `DINGBAT_BENCH_HASH=1` over the ROM set catches any
error immediately. Realistic capture is well under the ceiling — say +4-6% — because
the SWAR path still has to do the load, expand and store.

### 2. Per-line OBJ candidate list — ceiling **+5.2%** [+3.7 to +7.7%] measured directly

Stop visiting 128 OAM entries on every scanline when 0.2-1.7 are on the line. The
natural shape is a prepass that buckets sprites by y-range, rebuilt when OAM has been
written since the last rebuild. The hardware OBJ cycle budget is preserved exactly as
long as the candidate list keeps OAM order, because `obj_cycles` is only charged for
sprites that pass the on-line and x-visibility tests, and the `break` on exhaustion
happens before an entry is examined.

**Risk: moderate.** The invalidation is the whole problem — OAM is legitimately written
mid-frame (H-blank DMA sprite updates), and getting invalidation wrong produces sprites
that are one line stale, which is exactly the class of bug the pixel A/B is good at
catching. Note the ceiling here is not an estimate: the 8-entry probe measured +5.2%
directly, so this is the best-understood item on the list.

Related and worth knowing before designing it: `research_dshba_comparison.md` flags
that we do not model DSHBA's OAM update delay. A prepass is exactly where that would
live if a test ROM ever shows we need it — cheap to get right if it is designed in,
expensive to retrofit.

### 3. Uniform-window fast path — ceiling **+2.6% / +1.9%** on the two Pokemon titles, noise elsewhere

Both Pokemon states run the full per-column window machinery on all 96000 measured
lines and get one uniform span every time. The check is O(1) from the window registers.
Already **demonstrated pixel-exact and hash-gated byte-identical** on all five states,
so this is close to a free +2%, on two of the highest-selling GBA titles, in about
fifteen lines.

**Risk: low, but the correctness surface is wider than the probe.** The probe only
covers "win0 on, spans the full width, no OBJ window". A shipped version wants the
general uniformity test (win1, wrap-around ranges where `x1 > x2`, both windows active,
OBJ window forcing the slow path) and its own unit test, not just the case that happens
to fire on Emerald.

### 4. Compositor structural rewrite — ceiling **+9.4%** [+6.6 to +13.1%]

Roughly confirms the `performance.md` number (+11.4% native, +9.2% web) on
representative scenes, so **that verdict survives** even though the FireRed state it
was measured on does not. It is now second-largest, not largest. Everything in the
2026-07-24 SIMD no-go still applies — three inner loops, dual scalar/SIMD maintenance
of the renderer's most correctness-sensitive code, wasm SIMD unavailable on the iOS 15
targets, doubled offline payload — and §5 adds that the obvious cheap win inside it
(a fourth specialised loop for Golden Sun's blend-but-nothing-selected case) measures
as noise. **Do items 1-3 first**; they are cheaper, safer and sum to a comparable
number.

### Not worth attacking

- **Per-scanline buffer clears.** −0.1% measured confound-free. Closed.
- **`render_sprites` pixel loop.** Noise on 3 of 5 games. The scan is the cost.
- **Reordering inside the OAM scan.** +0.8% mean; the iteration count is the cost.
- **A fourth compositor inner loop.** +0.0% mean.
- **`render_aff_bg` / `render_bitmap`.** Not exercised by any mode-0 gameplay scene.

---

## 7. Where this contradicts `performance.md`

Stated plainly, because both of the superseded conclusions are still written there as
settled:

**"`render_reg_bg` is done: 8.5% of profile with a 4.8% ceiling means it is already
near optimal" — WRONG, by a factor of three.** The real-gameplay ceiling is **+15.2%
mean (+12.1% to +19.7%)** and its profile share is 11.0-17.3%, the largest named PPU
component in all five games. The +4.8% came from a FireRed state that is 100% windowed
compositing — a scene that inflates the compositor's share and correspondingly
understates the BG renderer's. Furthermore **+9.4% of the +15.2% is in one inner loop**
(the 4bpp nibble unpack) that has a specific, bounded, cache-friendly rewrite available.

**"Layer-at-a-time compositing is the only structural PPU item left worth attempting" —
WRONG in the exclusive, right in the estimate.** The compositor's ceiling does
reproduce at +9.4% mean, but it is now the *second* PPU item, behind `render_reg_bg`,
and a third item (the OAM scan, +5.2%) was not on the list at all. The SIMD no-go
decision itself stands unchanged on its own reasoning.

**The compositor path table from boot sequences is not usable for gameplay.**
`performance.md` records Emerald as 78% fast / 21% blend-only and FireRed as 24% fast /
75% windowed. In real gameplay Emerald is **100% windowed on the outer axis and 100%
opaque on the inner axis** — no blend-only columns at all — and FireRed is identical to
it. Golden Sun goes from 2% fast / 97% blend-only at boot to 31.6% opaque / 68.4% blend
in-game. Boot-sequence path mixes are not a proxy for gameplay path mixes.

**Not contradicted, and worth repeating:** the general lesson from 2026-07-24 holds
everywhere it was tested here. Every micro-optimisation-shaped probe in this round
(hoisting the OBJ y-test, specialising a fourth compositor loop, removing either
per-scanline clear) came back as noise. The three items that survive are all
*structural* — do less work, not the same work more tidily.
