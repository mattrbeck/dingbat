# What the GB test suites say about the hardware, and where dingbat disagrees

**Date:** 2026-08-07 · **Tree:** `agent-gbstop` @ `8049548` · **Scored against:**
`tests/results.md` (generated 2026-08-07), which agrees with the gbdev shootout
row for row.

## Why this document exists

Two recent rounds found the same thing twice: **the test ROMs' own sources state
the hardware behaviour they measure, in cycles, and reading them beats fitting
numbers to a reference image.** SameSuite's `.asm` headers supplied a corrected
pulse-channel model in four sentences after a previous investigation had spent a
long time fitting magic numbers and getting it wrong; Pan Docs' STOP flowchart
turned out to be an SVG with no text layer, and parsing its geometry took five
rows from failing to zero pixels wrong.

This is the sweep of everything else. It is a catalogue of **assertions**, each
with its source, the dingbat rows it governs, and whether dingbat's code agrees.
It is not a fix list. Where a test's source contradicts a comment in
`src/dingbat/gb/` that explains *why* dingbat does something, that is called out
explicitly — those are the entries worth reading first.

Sorted throughout by rows-at-stake × confidence.

## The ranked index

Shootout rows only (dingbat's local suites are noted where they differ). Read
down until the cost column stops being worth it.

| § | The claim vs. what dingbat does | rows | cost | conf |
|---|---|---|---|---|
| **0.2** | The shootout passes a frame at **±50 luma in greyscale**; dingbat compares the bundled suites pixel-exact. `cgb-acid-hell` (2 px) and `strikethrough` (53 px) may already be green upstream | **0-2** | rescore two rows | high |
| **1.6 / 10.1** | bully's reference is 22893 white + 147 black and dingbat matches **exactly the 147 black** — it renders a solid black frame, because `skip_boot` seeds CGB palette RAM only on the DMG-compat path | **1-2** | ~4 lines | high |
| **9.1** | "The RAMB register for MBC3+RTC is a **4 bit register**" — `mbc3.nim` stores all 8 | **1** | one token | certain |
| **9.2** | The RTC latch is a **1-bit** register; dingbat requires the full byte `$00` then `$01`, so it never re-latches against random writes | **1** | one line (+ decode the PNG first) | high |
| **1.5** | `stop_instr_gbc_mode3`'s reference **has content** (unlike `stop_instr (GBC)`'s black frame), so it discriminates; dingbat skips it as if it did not | **1** | one `TestDef` | high |
| **1.1** | "When the window is disabled during mode 3, the tile fetcher will read from the background tiles… at the start of the next tile fetcher cycle" — on **DMG**. dingbat has no path that clears `fetching_window` mid-line, and files the behaviour as CGB-only | **2** (+1 local) | small code, medium risk | high |
| **7.2** | "starting the APU while bit 4 of DIV is set causes the APU to **skip the first DIV-APU event**" — dingbat's NR52 power-on never reads the tap | **3** | low | high |
| **1.2** | daid's mid-scanline BGP: the three legitimate hardware outcomes differ by **464-576 px**; dingbat is **6180 px** wrong. Not an ambiguity, a phase error | **1** (+2 mealybug) | medium | high |
| **7.3** | channel 4's trigger delay is "sample length + 3 M-cycles"; dingbat has **no addend**. And NR43 `$09` vs `$18` must differ; dingbat collapses divisor×shift to one scalar | **2** / **2** | low / high | high |
| **7.4, 7.5** | channel 3 and the channel-4 LFSR rows already match the sources — expect ~16 free passes on first run. **Do not "fix" the LFSR polarity** | **~16** | wire them up | high |
| **1.7** | mooneye `intr_2_mode0_timing_sprites`: dingbat's OBJ table matches all 90 testcases; the residual is one dot of mode-3 end phase, with **zero slack** and a known conflict against GBMicrotest | **1** | measurement | high |
| **1.3** | `m3_wx_6_change` is 60% wrong; gambatte pins only WX 0 and 7, so **nothing outside mealybug constrains WX 4/5/6** and the three references are structurally unrelated | **1** | a sweep | med |
| **1.4** | dingbat has **no OAM-bug emulation at all** (zero hits). 3 of the 4 rows only assert *that* OAM changed and *when* | **3** + 1 | small+medium / large | certain |
| **7.7, 10.6** | SGB `MLT_REQ` and the packet protocol — no SGB state anywhere in `src/dingbat/gb/` | **3** | high (new subsystem) | high |
| **10.2** | strikethrough: dingbat models the CPU side of OAM-DMA conflict thoroughly and the **PPU side not at all** (`dma_busy` has 0 hits in the PPU files) | **1** | medium-high | high |
| — | the mealybug tail: 8 DMG rows wrong by ≤106 px out of 23040 | **8** | unknown | — |

**Do not spend:** §8.1 (GBMicrotest's SCX table contradicts itself DMG-vs-AGS and
its own `500-scx-timing.s` header backs dingbat), §8.6 (`halt_op_dupe_delay`'s
expected `$55` is physically unattainable and dingbat's `$01` is right), §8.7
(`dma_basic` / `400-dma` / `cpu_bus_1` have no verdict by construction),
§4.1's two blargg CRC rows (the fill pattern they hash is not recoverable from
the shipped source). `samesuite/apu/channel_4/channel_4_freq_change` used to be
on this list — SameBoy fails it and its own header says the logic is unknown —
and it was wrong to be: the header is an honest report that one test needs a
mechanism no other test can see, not that the mechanism does not exist. It is
64/64 as of the noise channel's two-stage timer; see `notes/samesuite-apu.md`.
**"Its author gave up" is not evidence about the hardware.**

**Sections 3 and 7.4-7.6 exist to stop regressions:** they record behaviours
dingbat gets *right*, with the ROM author's own sentence explaining why.

## Pinned sources

Everything quoted below can be re-found at these revisions.

| Suite | Upstream | Revision | Where the docs are |
|---|---|---|---|
| gbdev shootout | `gbdev/GBEmulatorShootout` | `38b926b` (2026-07-13) | `testroms/*.py` `description=`, `test.py`, `util.py` |
| Mealybug Tearoom | `mattcurrie/mealybug-tearoom-tests` | `70e88fb` (2020-12-20) | `the-comprehensive-game-boy-ppu-documentation.md`, per-test `src/ppu/*.asm` headers, `expected/`, `photos/` |
| daid | in-shootout, `testroms/daid/` | `38b926b` | `*.asm` + `expect:` byte tables |
| Mooneye | `Gekkio/mooneye-test-suite` | bundled `8d742b9d55` (2022-03-17) | per-test `.s` headers, `README.markdown` "Test naming" |
| blargg | `retrio/gb-test-roms` | HEAD | `oam_bug/readme.txt`, `oam_bug/source/*.s` |
| SameSuite | `LIJI32/SameSuite` | bundled `f71b4b3c37` (2022-04-10) | per-test `.asm` headers |
| GBMicrotest | `aappleby/GBMicrotest` | bundled `f3b55497c1` (2023-05-07) | per-test `.asm` headers, `README.md` |
| rtc3test | `aaaaaa123456789/rtc3test` | bundled `80ae792bf1` (2020-12-02) | `README.md`, `tests.md` |
| BullyGB | `Ashiepaws/BullyGB` | bundled `e24fe6fd7f` (2021-02-26) | `README.md`, repo wiki |
| strikethrough | `Ashiepaws/strikethrough.gb` | bundled `7cd01bf916` (2021-03-05) | `README.md` |
| acid | `mattcurrie/{dmg,cgb}-acid2`, `cgb-acid-hell` | `8a98ce731f` / `04c6ca40cf` / `107b7c5a87` | `README.md` feature maps |
| CasualPokePlayer | `CasualPokePlayer/test-roms` | per-test branches | branch `README.md` |

The c-sp bundle in `/tmp/dingbat-test-roms/game-boy-test-roms/` additionally
ships a `game-boy-test-roms-howto.md` per suite, which is where the **hardware
revision each suite was verified on** is recorded. That is section 5.

---

# 0. First, what the shootout actually scores

Facts about the harness that change how every row below should be weighted.
Nothing here is a hardware claim; all of it is arithmetic anyone can redo.

### 0.1 The denominator is 264 rows, of which 3 are unscoreable — hence 261

`testroms/*.py` define, with the commented-out lines removed:

| suite | rows |
|---|---|
| mooneye | 97 |
| samesuite | 68 |
| blargg | 51 |
| mealybug | 24 |
| daid | 9 |
| acid | 5 |
| cpp | 4 |
| ashiepaws | 3 |
| ax6 | 3 |
| **total** | **264** |

Three of those ship no reference PNG at all, so `Test.getDefaultResult()`
returns `INFO` rather than `PASS`/`FAIL`: `acid/which.gb` on DMG and on CGB, and
`daid/rom_and_ram.gb`. 264 − 3 = **261**, which is the denominator dingbat is
scored against. dingbat's runner already skips all three, and its stated reason
for skipping `rom_and_ram` ("it ships no reference image at all — the shootout
classes it INFO") is correct.

### 0.2 The shootout's pass criterion is greyscale with a ±50 tolerance

`util.py`, at `38b926b`:

```python
def compareImage(a, b):
    a = a.convert(mode="L", dither=PIL.Image.NONE)
    b = b.convert(mode="L", dither=PIL.Image.NONE)
    result = PIL.ImageChops.difference(a, b)
    for count, color in result.getcolors():
        if color > 50:
            return False
    return True
```

Colour is discarded entirely and a pixel passes while its **luma** is within 50
of the reference's. dingbat implements exactly this, but **only where
`TestDef.grey_tolerance > 0`** — which is the shootout-fetched rows (ax6, cpp,
daid). The bundled suites (mealybug, acid, bully, strikethrough, firstwhite,
mbc3-tester) are compared **pixel-exact** in
`tests/dingbat_test_runner.nim:309-319`.

For DMG rows this makes no difference: DMG shades are 0/85/170/255, so a
one-shade error is 85 > 50 and fails either way. **For CGB colour rows it makes a
large difference**, and two shootout rows sit inside it:

* `acid/cgb-acid-hell.gbc` — dingbat is **2 pixels** off exact
  (`cgb-acid-hell/cgb-acid-hell | 👀 100.0% (23038/23040)`). If those two pixels
  are within 50 luma, **the shootout already scores this row green** and
  dingbat's local red row is over-strict.
* `ashiepaws/strikethrough.gb` — **53 pixels** off exact, CGB colour, same
  question.

**Worth up to 2 rows for the cost of re-scoring two existing rows under the
criterion the runner already implements.** No emulator change, no new ROM. This
is the cheapest item in the whole document. (The shootout's `cgb-acid-hell.png`
and the c-sp bundle's are byte-identical images — verified, 0 pixels differ — so
the reference is not the variable.)

### 0.3 Seven scoreable shootout rows are not in `tests/results.md` at all

Diffing the 261 against dingbat's row names:

| shootout row | dingbat | note |
|---|---|---|
| `daid/stop_instr_gbc_mode3.gb` | not run | **see 1.5 — its reference discriminates, unlike `stop_instr (GBC)`** |
| `daid/ppu_scanline_bgp.gb (GBC)` | not run | deliberate, and **the reason is now measured**: it is 92.50%, a uniform 3 pixels early, and the 3 = one M-cycle at the halt-woken handler entry MINUS one dot of the CGB-C→CGB-D palette step. Its reference is a **later device** than the `_cgb_c` set the 27 mealybug CGB rows score against. See gb-failure-triage.md and `CGB_HALT_EXIT_MCYCLES` |
| `daid/stop_instr.gb (GBC)` | not run | deliberate and correct: reference is a uniform black frame (147-byte PNG), so the row cannot fail |
| `ashiepaws/bully.gb (GBC)` | one `bully` row only | dingbat runs the cart CGB (flag `$80`), so its single row is the CGB one |
| `cpp/sgb-ext-test.gb` | skipped | no SGB model |
| `samesuite/sgb/command_mlt_req.gb` | skipped | no SGB model |
| `samesuite/sgb/command_mlt_req_1_incrementing.gb` | skipped | no SGB model |

### 0.4 Only 24 mealybug rows count, and all 24 are DMG

`testroms/mealybug.py` ends with `all = dmgs` — the `cgbcs` and `cgbds` lists are
built and then not used. So of the ~30 mealybug rows dingbat currently fails,
**13 are `mealybug-cgb/*` and carry zero shootout weight**, including all seven
`*2` variants (which exist only in the CPU CGB C reference set upstream).

The 24 that do count, and dingbat's exact pixel error on each:

| row | wrong px | |
|---|---|---|
| `m3_wx_6_change` | 13810 | §1.3 |
| `m3_lcdc_win_en_change_multiple` | 8874 | §1.1 |
| `m3_lcdc_win_en_change_multiple_wx` | 4215 | §1.1 |
| `m3_lcdc_bg_en_change` | 2193 | §1.4 |
| `m3_bgp_change` | 1508 | §1.2 |
| `m3_bgp_change_sprites` | 1044 | §1.2 |
| `m3_window_timing_wx_0` | 902 | §3.2 |
| `m3_lcdc_tile_sel_change` | 776 | §2.1 |
| `m3_scy_change` | 417 | §3.4 |
| `m3_lcdc_obj_en_change_variant` | 380 | |
| `m3_window_timing` | 299 | §3.1 |
| `m3_lcdc_bg_map_change` | 192 | |
| `m3_lcdc_tile_sel_win_change` | 106 | |
| `m3_obp0_change` | 74 | |
| `m3_lcdc_obj_en_change` | 60 | |
| `m3_lcdc_obj_size_change` | 57 | |
| `m3_lcdc_win_map_change` | 34 | |
| `m3_lcdc_obj_size_change_scx` | 30 | |
| `m3_wx_4_change_sprites` | 2 | §3.3 |
| `m2_win_en_toggle`, `m3_scx_high_5_bits`, `m3_scx_low_3_bits`, `m3_wx_4_change`, `m3_wx_5_change` | pass | §3 |

**19 of the 24 are red — the single largest recoverable cluster in the shootout.**
Eight of the 19 are wrong by ≤ 106 pixels out of 23040.

### 0.5 mealybug's `expected/` images are an emulator's output; `photos/` is the hardware

From `README.md`:

> You can check in the ```expected``` directory for screenshots from my Game Boy
> emulator (which I believe to be correct), and the ```photos``` directory
> contains blurry photos of the ROMs running on real devices.

This is the "documentation present but unreadable in the obvious way" case for
this suite. The scoring reference is **Beaten Dying Moon's output**, not a
capture. Where dingbat and `expected/` disagree by a handful of pixels and the
disagreement is structural rather than positional, `photos/<device>/<test>.jpg`
is the only hardware evidence, and it exists for 21 of the 24 DMG rows. Nobody
has looked at them. A blurry JPEG of an LCD cannot settle one pixel, but it can
settle "is there a black band here or not", which is the shape of §1.1 and §1.3.

---

# 1. Contradictions: the test's source says X, dingbat does Y

## 1.1 A mid-mode-3 `WIN_EN` clear must return the fetcher to the background. dingbat has no such path at all.

**Rows: `mealybug/m3_lcdc_win_en_change_multiple` (8874 px), `.../_wx` (4215 px)
— 2 shootout rows, plus `mealybug-cgb/m3_lcdc_win_en_change_multiple`. Highest
pixel error of any structural claim in the suite. Confidence: high.**

`src/ppu/m3_lcdc_win_en_change_multiple.asm`, header comment:

> Turns bit 5 (WIN_EN) of LCDC register on and off multiple times during mode 3.
> If WX is set to activate at a pixel that has not been drawn yet, and WIN_EN is
> toggled then the window can be turned on and off multiple times on a single
> row, with background tiles displaying in between.
> **The current row of the window is incremented each time the window is
> activated**, so the second time the window is activated on the row, the next
> row of window pixels are displayed.
> **When the window is disabled during mode 3, the tile fetcher will read from
> the background tiles instead of the window tiles at the start of the next tile
> fetcher cycle.** This means that when the window is turned on and off it will
> always display a multiple of 8 pixels, except when the window begins off the
> left edge of the screen.

`the-comprehensive-game-boy-ppu-documentation.md`, LCDC `WIN_EN` (bit 5), adds
three more constraints:

> - WIN_EN can be disabled during mode 3. The disabling will take effect at the
>   end of the current window tile being drawn. When the current window tile has
>   finished being drawn, the PPU will start drawing background tiles again.
> - **When the background resumes drawing it is on a tile boundary. The low 3
>   bits of SCX have no effect.**
> - Setting WIN_EN again during mode 3 on the same scanline will have no effect
>   unless WX has been updated to set the window to activate on a pixel that
>   hasn't been drawn yet.
> - If WX has been updated correctly and WIN_EN is set again then the PPU stops
>   drawing the background, and will activate the window again, but it will
>   start drawing the **next row** of the window, on the same scanline.

**dingbat does none of this.** `ppu.fetching_window` is written in exactly two
places — `reset_render_scratch` (line reset) and `fifo_reset_bg` — and the only
caller that passes `true` is the window trigger at `fifo_ppu.nim:811`. **No path
sets it back to `false` mid-line.** `tick_bg_fetcher`'s `fsGetTile` picks the
window map on `if ppu.fetching_window:` with no `window_enabled(ppu)` term
(`fifo_ppu.nim:166`), and `fsGetTileDataLow/High` picks the window row the same
way (`:195`). Once the window starts, dingbat draws window tiles for the rest of
the line whatever LCDC.5 does.

**This contradicts a deliberate dingbat comment.** `memory.nim:240-247`:

> Two further model-specific window behaviours live next to this one and are
> deliberately NOT here, because each is its own mechanism rather than a
> latency: **SameBoy's CGB-only fetcher-abort on a late window disable** (which
> is what the late_disable families want, and which an LCDC latency alone makes
> worse) […]

dingbat has this filed as a **CGB-only** behaviour learned from SameBoy. Matt
Currie's ROM says it on **DMG**, and the two rows it governs are scored against
`_dmg_blob.png`. The gambatte `window/late_disable_*` families that motivated
the "CGB-only" framing measure a different quantity — *when* the disable is
sampled, one M-cycle either way — while mealybug measures *what the fetcher does
once it is sampled*, which is 8874 pixels' worth.

**Note the two behaviours compose for free.** Because dingbat already increments
`current_window_line` inside `fifo_reset_bg` when `fetching_window` is true
(`fifo_ppu.nim:119`), a correct disable path that runs
`fifo_reset_bg(ppu, false)` and later re-triggers through the existing
`lx == win_lx` compare would get the "next row of the window" rule and the
"no effect unless WX moved" rule for nothing: after a disable, `win_lx` becomes
`wx - 7`, which the shifter has already passed, so only a WX write can re-arm it.
That is exactly the doc's third bullet.

**The one thing that is not free:** `fifo_reset_bg` sets `fetcher_x = 0`. That is
right for a window start (the window has its own tile 0) and **wrong** for a
background resume, which must continue from the BG tile covering the current
`lx`. The doc's "resumes on a tile boundary, the low 3 bits of SCX have no
effect" says what that index is.

**Cost:** a `fetching_window`/`window_enabled` reconciliation at the top of the
fetch cycle, plus a resume-`fetcher_x`. Small in lines, medium in risk — the
whole `window` family in gambatte (dingbat's largest PPU instrument) sits on
this code. Do it behind an `{.intdefine.}` and sweep, the way the CGB latency
constants are handled.

## 1.2 daid's mid-scanline BGP error is 13× larger than the entire hardware ambiguity

**Rows: `daid/ppu_scanline_bgp-dmg` (1 shootout row), and the same mechanism
under `mealybug/m3_bgp_change` (1508 px) and `m3_bgp_change_sprites` (1044 px) —
3 shootout rows. Confidence: high.**

`testroms/daid/daid.py`:

> Mid scanline BGP register changes. Requires accurate PPU timing. Changing the
> BGP register has three possible effects for one pixel: the previous BGP is
> used, the next BGP is used, or the OR result of the previous and next BGP is
> used, the last case causing a black line. **Which case occurs seems to be
> hardware and instance dependent** as some DMGs do not do a consistent single
> case.

Hence three accepted references, and dingbat's runner accepts all three too. It
currently scores **73.2% (6180 pixels wrong)** against the best of them,
`ppu_scanline_bgp_2.dmg.png`.

**Decoded, the three references differ from each other by 464–576 pixels:**

| | px differing |
|---|---|
| `_0` vs `_1` | 464 |
| `_1` vs `_2` | 464 |
| `_0` vs `_2` | 576 |

`_1` is the "OR" case: it is the only one containing black (352 px of `#000000`);
`_0` and `_2` have identical colour histograms (5880 white / 9480 light / 7680
mid) and differ only in where the bands sit.

**So "we picked the wrong one of the three legitimate hardware outcomes" cannot
be the explanation.** dingbat's error is 6180 px against a total ambiguity of
576. Whatever is wrong is an order of magnitude bigger than the thing the test
is nominally about.

The ROM is a phase measurement and nothing else. Its STAT handler is exactly one
scanline long — `REPT 10 { ld a,[hl+] ; ld [c],a }` is 40 M-cycles, plus
`REPT 98-12-16` = 70 NOPs, plus the `jp` = 114 M-cycles = 456 dots — and it
free-runs from a single LYC=0 interrupt for the whole frame. Every band edge in
the picture is therefore `(entry phase) + k` M-cycles. A constant phase error of
one M-cycle moves every edge by 4 pixels.

**Suggested diagnostic, cheap:** capture dingbat's frame and cross-correlate it
horizontally against all three references over a ±16-pixel shift. If a shift
minimises the error, the whole row is one number — the STAT-entry phase or the
BGP sample dot — and the mealybug `m3_bgp_change` pair is very likely the same
number.

### Answered 2026-08-09: it was one number, and it was 444 dots

The cross-correlation was run and it does minimise, at **−12 pixels on 97 of the
144 lines** (the other 47 are lines whose bands are wide enough that several
shifts tie). That reading is a trap, and the trap is worth recording: a −12
shift and a −456−12 shift are indistinguishable from one line's run-lengths, and
the truth was the second. Reconstructing the write train from the ROM's own
palette table settles it — model the frame as `V[j]` written on dot
`φ + 456·⌊j/10⌋ + 16·(j mod 10)`, colour every pixel from the largest `j` whose
dot is ≤ `456·LY + x + 96`, and sweep `φ`:

* `φ = −362` reproduces `_0` **exactly**, 23040/23040;
* `φ = −363` reproduces `_2` **exactly** — the same write, the two conventions
  for its transition pixel (old, or new), which is what daid's own note means by
  "hardware and instance dependent";
* `_1` is those two with the OR pixel between them, and it is the one this tree
  models (`MIXER_PALETTE_OR`).

φ negative means the handler starts **inside line 153**, not line 0: the LYC=0
interrupt this ROM syncs on belongs to the LY 153 → 0 snapback. dingbat entered
it at line 0 dot 1 — 444 dots late — because the snapback ran no STAT edge
detector at all (§8.2) and the comparator's blind window was not modelled. Both
fixed; the row is now pixel-exact against `_1`, 0 of 23040 wrong. The prediction
that `m3_bgp_change`'s residual is "very likely the same number" is **falsified**
— it is unaffected, because its handler is re-entered per line off a mode-2 STAT
interrupt rather than free-running from one LYC=0 a frame.

## 1.3 `m3_wx_6_change` is 60% wrong, and nothing outside mealybug constrains WX 4/5/6

**Row: `mealybug/m3_wx_6_change` (13810 px, the worst mealybug row). Confidence:
medium-high on the diagnosis, medium on the fix.**

`src/ppu/m3_wx_6_change.asm`:

> Tests changing the value of WX during mode 3
> Initiated by STAT mode 2 LCDC interrupt in a field of NOPs.
> Changes to WX are: WX = 6, WX = LY, WX = 80.

Its two siblings carry one extra sentence that `m3_wx_6_change` **does not**:

> (`m3_wx_4_change.asm`, `m3_wx_5_change.asm`) Window reactivation zero pixels
> should be present when window is already activated and the pixel that the
> window reactivates on is on the same cycle as the window tile nametable read.

and `m3_wx_4_change_sprites.asm` adds:

> Sprites with priority bit set should show through window reactivation zero
> pixels.

dingbat implements the reactivation rule verbatim in `window_reactivate`
(`fifo_ppu.nim:673-715`) and **passes `m3_wx_4_change` and `m3_wx_5_change`**.
It fails `m3_wx_6_change` at 40.1%.

Two facts that make this tractable:

1. **The three references are not shifts of one another.** Best horizontal
   alignment over ±3 px: `wx_5` vs `wx_6` bottoms out at 12823 px differing,
   `wx_4` vs `wx_6` at 13638. They are structurally different pictures. dingbat
   being 13810 wrong on `wx_6` is the same magnitude as rendering a *different
   test's* picture — consistent with dingbat producing its `wx_4`/`wx_5`-shaped
   output for `wx_6`.
2. **dingbat's WX threshold is uniform over 4/5/6 and nothing else pins it
   there.** `fifo_ppu.nim:1149-1160` starts the line as a window line for
   `ppu.wx < 7`, and its comment cites `gambatte m2int_wx00_m3stat_1/2` and
   `gbmicrotest win0_scx3_a/_b` — **both WX = 0** — plus `m2int_wx07` for the
   exclusion of 7. Confirmed against the bundle: the gambatte `window/` directory
   contains `m2int_wx00_*` and `m2int_wx07_*` families and **nothing at WX
   04/05/06**. mealybug is the only oracle in the tree for those three values,
   and it says 4, 5 and 6 are three different pictures.

**What to test, not a conclusion:** whether WX = 6 takes the ordinary
window-start path rather than the `wx < 7` "line starts as a window line"
special case. Moving the threshold to `wx < 6` cannot move any gambatte or
GBMicrotest row (they only probe 0 and 7), so it is a free experiment. Note the
naive version does not obviously work — with the ordinary path and SCX = 0, `lx`
starts at 0 while `win_lx` would be `wx - 7 = -1`, unreachable — so the right
model is probably "WX = 6 starts the window at the first emitted pixel but pays
the restart", i.e. a third case rather than a threshold move.

**Cost:** one afternoon of sweeping, one row, low risk of collateral damage
because the evidence base for the region is empty.

## 1.4 dingbat has no OAM-bug emulation at all

**Rows: `blargg/oam_bug/{2-causes, 4-scanline_timing, 5-timing_bug,
8-instr_effect}` — 4 shootout rows. Confidence: certain.**

`grep -rniE 'oam.?bug|corrupt' src/dingbat/gb/` returns six hits, none of them an
OAM bug: three are about CH3 wave RAM, the header logo and a link desync, and
three are save-state comments. There is no 16-bit inc/dec hook and no OAM row
corruption anywhere in the tree. `docs/gb-derivations.md:1284` already says so in
passing: *"Blargg was only partially wired — `oam_bug` (8 ROMs, and we had ZERO
OAM-bug coverage)"*.

This explains the row split exactly: `1-lcd_sync` is pure LCD-on timing, and
`3-non_causes` / `6-timing_no_bug` assert that OAM is **unchanged**, so all three
pass trivially on a no-op. `2/4/5/7/8` assert that OAM **did** change.

`oam_bug/readme.txt`, in full on the mechanism:

> * Verifies OAM corruption bug on DMG.
>
> * Occurs when 16-bit increment/decrement is made of value in range $FE00 to
>   $FEFF, during around the first 20 cycles of a visible scanline while LCD is
>   on, where 114 cycles = 1 scanline.
>
> * Causes several bytes of OAM to be copied from one place to another.
>
> * Occurs with instructions that do increment: INC rp (including SP) / DEC rp /
>   POP rp (counts as two increments) / PUSH rp (counts as two increments) /
>   LD A,(HL+) / LD A,(HL-)
>
> * Doesn't occur with instructions that do 16-bit add: LD HL,SP+n / ADD HL,rp /
>   ADD SP,n
>
> * Doesn't occur anytime during the 10 vblank scanlines.
>
> * Doesn't occur when LCD is off, no matter when it happens.
>
> * Corruption depends on when it occurs.

"cycles" here are M-cycles (`source/common/delay.s` forwards `n/4` from
`delay_clocks` to the same routine `delay` uses).

**The sources pin the window tighter than the readme.**
`source/4-scanline_timing.s` measures it against the LCD-on write rather than
against LY, and closes it at 19 M-cycles, not "around 20":

```
     set_test 2,"INC DE just before first corruption"   ... delay 70224-3
     set_test 3,"INC DE at first corruption"            ... delay 70224-2
     set_test 4,"INC DE at last corruption"             ... delay 70224-2+18
     set_test 5,"INC DE just after last corruption"     ... delay 70224-2+19
```

`source/5-timing_bug.s` then asserts the same window recurs on every visible
line and stops after line 143:

> ; Verifies corruption at timing edges:
> ; * Beginning of first scanline, and 18 cycles later
> ; * Beginning of second scanline
> ; * End of last scanline

with `delay 114` and `delay 114*143+18`.

**Two boundary facts that will trip a first implementation:**

* `LD DE,$FDFF : INC DE` does **not** corrupt (`3-non_causes`) but
  `LD SP,$FDFF : POP BC` **does** (`2-causes`), while `LD SP,$FDFE : POP BC`
  does not. The address that matters is the **pre-increment** operand, and POP's
  *second* increment is the one that fires.
* `2-causes` subtest 2 uses `LD DE,$FE00 : INC DE` — **row 0** — and demands
  corruption. The Pan Docs / AntonioND write-and-increment patterns are defined
  against a *preceding* row and cannot express a row-0 corruption. blargg's
  `cp_oam` only checks that OAM changed, so whatever hardware does at row 0, it
  is not a no-op.

**Negative result worth recording (§4.1):** blargg documents no corruption
*pattern*. "Causes several bytes of OAM to be copied from one place to another"
is the entire statement. Every row/increment/read/write pattern in circulation
comes from Pan Docs and AntonioND's *Cycle-Accurate GB Docs*, not from anything
blargg shipped. Worse, **`oam_bug.inc` is absent from the repository** — all
eight tests `.include` it and `find . -iname 'oam_bug*'` finds only the directory
and the built ROM — so the OAM **fill pattern the CRCs are taken over is not
recoverable from source**.

**Cost, split by row:**

* `2-causes`, `4-scanline_timing`, `5-timing_bug` — **small to medium, 3 rows.**
  These assert only *whether* OAM changed and *when*. A hook on the M-cycle of a
  16-bit inc/dec whose pre-increment operand is in `$FE00-$FEFF`, gated on DMG +
  LCD on + a 19-M-cycle window at the head of lines 0..143, writing *anything*
  deterministic, passes all three without regressing `3-non_causes` /
  `6-timing_no_bug`.
* `8-instr_effect` — **large, 1 row.** Needs the exact per-instruction patterns
  bit-for-bit against a CRC whose input fill is unrecoverable. Its four CRCs:
  `$EF0C266A` (INC/DEC rp), `$8C62EE7D` (POP), `$B3693CEE` (PUSH), `$06BE41A4`
  (`LD A,(HL±)`).
* `7-timing_effect` — **skip.** The shootout has it commented out (`# This test
  is broken.`), so it is not one of the 261; its CRC `$7D792E7C` sweeps 116
  timings and compounds the same unrecoverable-fill problem.

## 1.5 `daid/stop_instr_gbc_mode3` is a discriminating row, and dingbat skips it as if it were not

**Row: `daid/stop_instr_gbc_mode3.gb` — 1 shootout row. Confidence: high.**

`tests/dingbat_test_runner.nim:1012-1027` skips three daid GBC rows together, and
gives a good reason for two of them and a wrong one for the third:

> `stop_instr` "(GBC)" is the trap worth naming, because it would have gone in
> GREEN for the wrong reason. Its reference is an all-black frame, which is also
> what a blanked panel produces however STOP got there, so the row cannot
> distinguish a correct implementation from several wrong ones.

That is exactly right for `stop_instr.gbc.png` — it is a 147-byte PNG, i.e.
uniform. It is **not** right for `stop_instr_gbc_mode3.png`, which is a 384-byte
4-bit-colormap image with actual content. The two ROMs differ by design:

```asm
; stop_instr.asm
stopTestStrFail:  db "LCD on: FAILED", 0     ; printed BEFORE the stop
...
  stop
; stop_instr_gbc_mode3.asm
stopTestStrOk:    db "LCD on: PASS", 0       ; printed BEFORE the stop
...
.waitMode3:
  ld a, [rSTAT]
  and $03
  cp  $03
  jr  nz, .waitMode3
  stop
```

and `daid.py`:

> STOP instruction is usually not used, but doing a STOP during mode 3 on Color
> Gameboy will keep the screen displaying the same data, as the PPU keeps
> running, and during mode3 it can access VRAM.

So the mode-3 row's reference is *the text still on screen*, and a
blank-the-panel implementation fails it. It is a real gate on the STOP work that
just landed. It is a DMG-flagged cart run on a CGB (compatibility mode) like its
siblings, which is the runner's other stated reason for skipping — but unlike
them, this one can only be passed by getting the behaviour right.

**Cost:** one `TestDef`. The behaviour may already be correct.

## 1.6 `bully` does not fail a hundred checks — dingbat renders a uniform black frame

**Row: `bully/bully` (`ashiepaws/bully.gb`, 1–2 shootout rows). Confidence:
high on the diagnosis.**

`tests/results.md` reports `bully/bully | 👀 0.6% correct (147/23040 pixels
match)`. Decoding the reference:

```
bully.png  160x144  2 colours: (255,255,255) x 22893, (0,0,0) x 147
```

**dingbat's 147 matching pixels are exactly the reference's 147 black pixels.**
A uniform frame of any other colour would match zero. So dingbat's output for
this ROM is an all-black screen — not a torture test scoring 0.6%, but a blank
frame. The brief's framing ("22893/23040 wrong, essentially nothing correct") is
literally true and has a single cause.

Candidates, in order: the ROM is hung or crashed before drawing; the frame is
captured while the LCD is off; or the CGB palette is left at all-zero. The
shootout's `ashiepaws/bully.png` and the c-sp bundle's are the same image, so the
reference is not the variable. Note also, from the bundle's
`bully/game-boy-test-roms-howto.md`, that the DMG run is *expected* to fail on
real hardware:

> I double-checked this for my own devices […] and it fails on my DMG-C with
> error `Bad Echo RAM Reads`. CGB results are fine though.

dingbat runs the cart as CGB (its flag is `$80`), which is the right choice.

**Cost:** an hour with a frame dump. Almost certainly a setup or hang bug rather
than a hundred accuracy bugs, and worth 1–2 shootout rows.

## 1.7 mooneye `intr_2_mode0_timing_sprites`: dingbat's penalty table already matches all 90 testcases; the residual is a one-dot mode-3 phase that is already contested in-tree

**Row: `mooneye/acceptance/ppu/intr_2_mode0_timing_sprites` — 1 shootout row, and
the only one keeping dingbat off 66/66 on mooneye acceptance. Confidence: high on
the analysis, medium on the fix.**

Header, `acceptance/ppu/intr_2_mode0_timing_sprites.s:21-26`:

```
; Tests how long does it take to get from STAT=mode2 interrupt to mode0
; Includes sprites in various configurations
; Verified results:
;   pass: DMG, MGB, SGB, SGB2, CGB, AGB, AGS
;   fail: -
```

No model suffix — this row is expected to pass on **every** device, so there is
no revision excuse available for it.

The rig: each testcase is `ld d, 41 + extra` / `ld e, 40 + extra`, two NOP fields
terminated by `RET`, and round A must see mode 0 on the first STAT poll while
round B must not see it until the second. The path from the mode-2 interrupt is
`20 + N + 3` M-cycles, against the no-sprite sibling's 63, so **`extra` is
literally "how many extra M-cycles of mode 3 the objects cost, on the same phase
`intr_2_mode0_timing` (a passing row) already pins."** Setup is fixed: sprite
Y = `$52`, flags 0, SCX = SCY = 0, OBJ enabled after `enable_ppu`.

Because the answer is quantised to M-cycles, each testcase asserts a 4-dot
window: `extra_M` ⟺ true penalty `T ∈ [4·extra_M, 4·extra_M + 3]`.

**What the 90 testcases assert**, quoting the source's own section headings:

* `; ==> sprite count affects cycles` — 1..10 objects all at X = 0 give
  `extra = 2,4,5,7,8,10,11,13,14,16`, which fits **`11 + 6·(N−1)` dots uniquely**.
  This is the sole hardware evidence anywhere for "first object 11 dots, each
  further object at the same X exactly 6".
* `; ==> sprite location affects cycles` — ten objects at a common X, sweeping X
  = 1..167, gives the 8-residue ramp `6 + max(0, 5 − ((X+SCX) mod 8))` for the
  first plus 9×6, with the flat-11 exception at X = 0. **X ≥ 168 costs zero.**
* `; ==> non-overlapping locations affect cycles` — two groups of five at
  different X: `testcase 17, 0×5, 160×5` = 11+11+8×6 = 70 dots. The dedup key is
  **per distinct BG tile**, not global.
* `; ==> sprite order does not affect cycles` — the reverse-ordered pair
  (`72,64,…,0` scoring the same as `0,8,…,72`) requires the selected objects to
  be **sorted ascending by X**.

**dingbat's model matches all 90 on paper.** `fifo_ppu.nim:298-321` states the
same table (`6 + max(0, 5 - ((X + SCX) mod 8))`, flat 11 at X = 0);
`fifo_ppu.nim:717-761` implements it with the trigger dot as the +1;
`fifo_ppu.nim:346-357` charges a flat 6 for same-tile chaining;
`fifo_ppu.nim:81-84` sorts ascending by X, stably; and `fifo_ppu.nim:899` makes
objects at X ≥ 168 free by letting mode 3 end without them.

**So what the row actually pins is a single dot of mode-3 end phase, and it has
no slack.** `testcase 2, 0` asserts `T ∈ [8,11]` and the model gives **11** (top
of the window); `testcase 2, 3` asserts `T ∈ [8,11]` and gives **8** (bottom).
A uniform +1 dot breaks the first, a uniform −1 breaks the second. That collides
head-on with `fifo_ppu.nim:616-665`, whose own comment records GBMicrotest
solving for a mode-3 length **two dots shorter** than dingbat ships and mooneye
refusing it:

> `#   mooneye          112 -> 111   acceptance/ppu/hblank_ly_scx_timing-GS`
> `# Solving 'c + (SCX&7)' against those seven windows leaves exactly one c, and
> it is not 172: c = 170.`

**Cost: medium investigation, near-zero code churn.** Build with
`-d:gb_m3_trace`, dump the `OBJTRIG` and mode-3-end dots per testcase, and read
off which case is off by how much. Two other candidates if the phase theory
fails: BG-FIFO occupancy at the trigger dot (`try_push_bg_pixels` only fires on
`size == 0`, so an object landing before the push sees a stale `idx`), and the
line-start `lx` (`-(7 and scx)` rather than `-8`, with the `lag` term at `:735`
compensating).

**Doc correction found on the way:** `docs/gb-derivations.md:1429` still says
*"the rest needs the per-object alignment penalty from (OBJ.x + SCX) mod 8, which
this fetcher cannot express … left alone"*. That predates `cb2aaa6` / `151b952`;
the fetcher does express it now.

---

# 2. Assertions dingbat does not implement, where the row is not (yet) at stake

## 2.1 CGB `TILE_SEL` glitches

`the-comprehensive-game-boy-ppu-documentation.md`, LCDC bit 4:

> On the CGB, there is strange behaviour if the value of this bit changes on
> particular T-cycles of the background tile data fetch. The following behaviour
> has been observed:
> - On all CGB revisions, setting `TILE_SEL` on the same T-cycle as a bitplane
>   data read will cause it to use either: bitplane 1 data from the most recently
>   drawn sprite as bitplane data, if any, or bitplane 1 data from the most
>   recently drawn tile as when `TILE_SEL` was last reset, if any, or bitplane 0
>   or 1 data from the read in progress during pixel 159/160 (?) on the previous
>   row when the tile fetcher is interrupted. The timing of which bitplane is
>   selected differs between CGB revisions.
> - On all CGB revisions, excluding CPU CGB D, resetting `TILE_SEL` on the same
>   T-cycle as a bitplane data read will cause the **tile index** to be instead
>   used as the data for that bitplane.
> - On CPU CGB D, resetting `TILE_SEL` on the same T-cycle as the bitplane 1 data
>   read will cause the PPU to instead read the bitplane data from the address
>   for bitplane 0.

dingbat has none of this: `tick_bg_fetcher`'s `fsGetTileDataLow/High` reads
`bg_window_tile_data(ppu)` fresh each stage and takes the ordinary path
(`fifo_ppu.nim:190-192`). That is correct for DMG — where the same document says
only "changing its value during background tile data fetch allows for mixing tile
bitplane data from two different tile patterns", which per-stage re-reading gives
you — and it is why `mealybug/m3_lcdc_tile_sel_change` is only 776 px wrong while
`mealybug-cgb/m3_lcdc_tile_sel_change` is 968.

**Governs no shootout row** (the shootout's mealybug set is DMG only), so this is
recorded for completeness, not as work. If the CGB set is ever scored, this
paragraph is the specification, and note that it names a **CPU CGB D** split —
dingbat scores against `_cgb_c`.

## 2.2 `LD B,B` is the screenshot trigger, and DMG shades must be exactly `$00/$55/$AA/$FF`

mealybug `README.md`:

> - The screenshot from the emulator should be generated when the ```LD B,B```
>   software breakpoint is encountered.
> - A DMG emulator should use these 8-bit values in greyscale images or in RGB
>   components to ensure the images can be compared correctly: ```$00```,
>   ```$55```, ```$AA```, ```$FF```
> - A CGB emulator should use this formula to convert 5-bit CGB palette
>   components to 8-bit: ```(r << 3) | (r >> 2)```

dingbat matches all three (`dingbat_test_runner.nim:693-696` records the same
conventions). Recorded so nobody "fixes" the palette expansion.

---

# 3. Behaviours dingbat gets right, and the source's reason why

These are the entries that stop a future agent from "fixing" something correct.

## 3.1 The window's startup cost is 6 T-cycles, and the palette change lands inside it

`src/ppu/m3_window_timing.asm`:

> On each row, WX is set to the value of LY, and then the background palette is
> changed to black during mode 3. For rows with smaller values of WX, there are
> fewer white pixels visible due to the palette change happening after the **6
> T-cycle window startup fetch**. For rows with larger values of WX, there are
> more white pixels visible due to the palette change happening before the 6
> T-cycle window startup fetch. The stair step pattern is visible due to the
> palette being changed during the 6 T-cycle window startup fetch. Then when the
> window pixels are pushed out, the palette has been changed already.

dingbat's window restart resumes at fetcher step 1 (`fetch_counter = 0`) so the
three reads land on counters 1, 3 and 5 and the push happens six dots in —
`fifo_ppu.nim:797-808` derives exactly that and cites the same 6 dots via Pan
Docs. Row is 299 px wrong (98.7%), i.e. the structure is right and the residual
is small.

## 3.2 WX = 0 with SCX > 0 activates the window one T-cycle later

`src/ppu/m3_window_timing_wx_0.asm`:

> WX is set to 0. On each row, SCX is set to the value of LY, and then the
> background palette is changed to black during mode 3. The stair pattern is
> visible due to the delay from the lowest 3 bits of SCX, and due to **window
> activating one T-cycle later when WX = 0 and SCX > 0**.

dingbat implements this literally, in `fifo_sample_smooth_scroll`
(`fifo_ppu.nim:92-97`):

```nim
  if ppu.fetching_window:
    ppu.lx = int32(-max(0, 7 - int(ppu.wx)))
    if ppu.wx == 0 and (ppu.scx and 7) > 0:
      ppu.lx += 1
```

The row is still 902 px wrong, so something *else* in that test is off — but this
clause is the ROM's own sentence and must not be removed while chasing it.

## 3.3 Window-reactivation pixels are colour 0, which is why a priority sprite shows through

`m3_wx_4_change_sprites.asm`:

> Window reactivation zero pixels should be present when window is already
> activated and the pixel that the window reactivates on is on the same cycle as
> the window tile nametable read. **Sprites with priority bit set should show
> through window reactivation zero pixels.**

`window_reactivate` (`fifo_ppu.nim:673-715`) inserts a
`GbPixel(color: 0, palette: 0, ...)` behind the FIFO head precisely so an
OBJ-behind-BG sprite wins there, and its comment says so. dingbat is **2 pixels**
from green on this row and passes `m3_wx_4_change` / `m3_wx_5_change` outright.
The eight-position fetcher phase (`WIN_REACT_PHASE`) was swept rather than
derived, which the comment is honest about; the ROM names the surviving step as
the window nametable read but not which of dingbat's counters that is.

## 3.4 SCY is read at fetch stages B, 0 and 1 — and that is the CGB ≤ C behaviour, which is the reference dingbat scores against

`the-comprehensive-game-boy-ppu-documentation.md`, SCY:

> On the DMG and CGB revisions up to and including the "CPU GBC C" revision, the
> `SCY` register is read during the background tile fetch `B`, `0` and `1`
> stages. Changing the value during background tile data fetch allows for mixing
> tile bitplane data from different rows of the tile.
>
> On the AGB and CGB revisions "CPU GBC D" and greater, the `SCY` register is
> only read during the `B` stage, so no tile bitplane data mixing can occur.

dingbat reads SCY at `fsGetTile` (the map row) and again at both
`fsGetTileDataLow` and `fsGetTileDataHigh` (`(ly + scy) and 7`,
`fifo_ppu.nim:176-198`) — B, 0 and 1. Correct for DMG and for CPU CGB C.

**This is measurable, not just arguable.** Decoding mealybug's own reference sets,
`m3_scy_change.png` differs between `CPU CGB C` and `CPU CGB D` by **6217 pixels**
— 27% of the screen, by far the largest revision split in the suite (the next
largest is `m3_bgp_change` at 864). dingbat wires the `_cgb_c` image
(`dingbat_test_runner.nim:614-632`, which also explains why `_cgb_d` is
deliberately not wired), so its three-stage read is scored against the matching
silicon.

The same document's other SCY claim — "Writes will take effect immediately on the
DMG. On CGB and AGB devices, writes appear to take effect 2 T-cycles later" — is
already the subject of the `CGB_SCY_LATENCY` sweep table in `gb.nim:55-175`,
which ships it at 0 with a measured justification. Nothing new here; recorded so
the two are known to be the same claim.

## 3.5 The window line counter increments only on activation

`src/ppu/m2_win_en_toggle.asm`:

> Toggles bit 5 (WIN_EN) of LCDC register on each row of the screen during STAT
> mode 2. **The current window line is only incremented when the window is
> actually activated**, so on rows when the window is off, the window line should
> not be incremented.

dingbat increments `current_window_line` inside `fifo_reset_bg` and only when
`fetching_window` is true (`fifo_ppu.nim:119`). **Row passes on both devices.**
This is also the mechanism §1.1 would reuse.

## 3.6 SCX's high 5 bits are read per tile fetch

`src/ppu/m3_scx_high_5_bits.asm`:

> Sets SCX to LY on each row during mode 3. Sprites are used to affect the
> timing. **SCX is read at the start of each tile fetch.**

dingbat computes the map offset as
`((fetcher_x + (scx shr 3)) and 0x1F) + …` inside `fsGetTile`, i.e. fresh per
fetch (`fifo_ppu.nim:176-178`). Row passes on DMG and CGB.

## 3.7 Soft contradiction: where SCX's low 3 bits are latched

`src/ppu/m3_scx_low_3_bits.asm`:

> Tests how late SCX can be written to and have the lowest 3 bits of SCX still
> affect the rendering. **The lowest 3 bits appear to be read at the start of the
> "B" of the first "B01s" read cycle.**

dingbat latches them at the **end** of the throw-away first fetch, not at its
start — `fifo_ppu.nim:206-216`, whose comment says:

> The fine scroll is the FETCHER's, not the shifter's: the throw-away first
> fetch IS the mechanism that implements the SCX & 7 discard, so SCX is latched
> when that fetch completes rather than several dots later when the shifter first
> finds a pixel to look at. mealybug m3_scx_low_3_bits brackets the latch with two
> SCX writes one M-cycle apart -- one has to reach it and the other must not --
> and only the fetcher-side point sits between them.

The two points are ~6 dots apart and **the row passes either way**, so the ROM
cannot discriminate them at the granularity its two writes provide. Recorded
because it is a genuine disagreement with the ROM author's stated model that is
currently invisible, and because if this ever needs to move, the ROM's sentence
is the target.

**RESOLVED 2026-08-09, and the sentence was right.** A different ROM decided it:
`m3_scy_change`'s reference inverts into the (B, 0, 1) SCY triple each fetch saw,
and all eighteen of its bands put the first on-screen tile's map read one 2-dot
slot earlier than this tree had it. What that costs is the length of the
discarded fetch — four dots (`B0`), not six (`B01`), with the 12-dot head budget
unchanged (`M3_THROWAWAY_DOTS` in `gb/gb.nim`; derivation at `tick_bg_fetcher`).
The discarded fetch is then **not** a `B01s` cycle, so "the first `B01s` read
cycle" is the first real tile's, whose `B` is the dot this tree was already
latching on. The latch moved to the step the author names, its dot did not move,
and the two models stopped disagreeing.

---

# 4. Negative results — suites with no useful source documentation

Recorded so nobody repeats the dig.

## 4.1 blargg documents no OAM corruption pattern, and the include file is missing

See §1.4. `readme.txt`'s entire statement of the mechanism is *"Causes several
bytes of OAM to be copied from one place to another."* No row structure, no
increment/read/write patterns, no `((a ^ c) & (b ^ c)) ^ c`. All of that comes
from Pan Docs and AntonioND. And **`oam_bug.inc` — which defines `fill_oam`,
`cp_oam`, `corrupt_oam`, `delay_a_20_cycles` — is not in the repository**, so the
OAM fill pattern that `7-timing_effect` and `8-instr_effect` CRC over cannot be
reconstructed from source. `source/readme.txt` admits the family is incomplete
("Building such a multi-test is complex and the necessary files aren't included")
but does not name this file. Practical consequence: the two CRC rows can only be
closed by matching a reference implementation bit-for-bit, not by reading a spec.

## 4.2 The other blargg suites ship no per-test rationale

`gb-test-roms` has `readme.txt` files that describe *how to run* and *what the
verdict codes mean*, not what the hardware does, except for `oam_bug`. dingbat
passes all of them anyway.

## 4.3 daid's non-STOP sources are byte tables, not prose

`speed_switch_timing_{div,ly,stat}.asm` carry no explanatory comment beyond one
line each (`; We wait till DIV is $40, to we can see very well that DIV gets
reset on a speed toggle.`). What they *do* carry is better: a literal `expect:`
table of the exact byte sequence the register must produce after the switch —
32 bytes for DIV, 128 for LY, 64 for STAT, read back with `REPT TEST_SIZE { ld a,
[CHECK_REG] ; ld [hl+], a }`. dingbat passes all three. If any regresses, those
tables localise the failure to a specific M-cycle without any image comparison;
they are reproduced in the sources at
`shootout/testroms/daid/speed_switch_timing_*.asm`.

## 4.4 The acid ROMs and the small screenshot suites have feature maps, not timing claims

`dmg-acid2` / `cgb-acid2` READMEs enumerate which part of the drawn face
corresponds to which PPU feature — useful for **diagnosing a partial failure**,
not for deriving timing. dingbat passes both. `cgb-acid-hell` has no
compatibility information at all (per the bundle howto: *"I could not find any
compatibility information […] My guess is, that it is compatible to any Game Boy
Color device"*), and is 2 pixels from green — see §0.2.

## 4.5 `little-things-gb/firstwhite` is not a shootout row but its README is a one-line diagnosis

Not one of the 261, but dingbat scores it 89.2% and the README says exactly what
that means:

> This program should display a white screen. In fact, on a monochrome Game Boy,
> it should display the same whiter-than-white shade that it displays when the
> power is off. **If you get text, your emulator needs to be fixed and probably
> shows 1-frame glitches in _Pokémon Pinball_.**

The reference `firstwhite-dmg-cgb.png` decodes to 23040 pure-white pixels and
nothing else. dingbat matches 20552 of them, so it is drawing ~2488 pixels of
text — i.e. it is in the documented failure mode. One first-frame behaviour,
named consequence in a real game.

---

# 5. Which silicon each oracle was taken on

This matters because dingbat's PPU derivations trade suites against each other —
e.g. `fifo_ppu.nim:806-808` settles a fetcher phase on "gambatte 3587 → 3609 and
mealybug DMG +361 pixels, against one GBMicrotest row". If those oracles are
different revisions, such a trade can be scoring two correct answers against each
other.

From the c-sp bundle's per-suite `game-boy-test-roms-howto.md`:

| suite | verified on |
|---|---|
| blargg | DMG-CPU-08 (DMG-CPU C blob), CPU-CGB-02 (CGB B), CPU-CGB-06 (CGB E) |
| GBMicrotest | "believed to be a DMG-CPU-08 … a DMG-CPU B or a DMG-CPU C" |
| gambatte | `dmg08` and `cgb04c`, i.e. DMG-CPU-08 and CPU CGB C |
| AGE | DMG-CPU-08 (DMG-CPU C blob), CGB B, CGB C, CGB E |
| scribbltests | MGB 9638 D and CPU CGB D, by the author |
| mealybug | per-device reference sets: `DMG-blob`, **`DMG-CPU B`**, `CPU CGB C`, `CPU CGB D` |
| strikethrough | no statement; the bundler's DMG-C, CGB B/C/E all pass |
| BullyGB | "most test cases are compatible to all Game Boy devices" — but *"it fails on my DMG-C with error `Bad Echo RAM Reads`. CGB results are fine though."* |
| rtc3test, cpp, mbc3-tester | cartridge tests, device-independent |
| dmg-acid2 / cgb-acid2 | "does not require any T-cycle accurate timing and thus *probably* works on any" — unverified |
| mooneye | encoded in the filename; see the `README.markdown` table below |

**The DMG oracles are not all the same DMG.** GBMicrotest, gambatte, blargg and
AGE are all DMG-CPU-08 (a DMG-CPU C blob); mealybug's scored set is `DMG-blob`,
a different part, and it ships a separate **`DMG-CPU B`** reference set for
exactly two tests.

**Which two is the interesting part:**

| `DMG-CPU B` reference | px differing from `DMG-blob` |
|---|---|
| `m3_lcdc_bg_en_change.png` | **228** |
| `m3_lcdc_win_en_change_multiple_wx.png` | **3** |

Those are two of dingbat's three worst DMG mealybug rows. Matt Currie shipped a
second-revision reference for precisely the tests he found to be
revision-dependent — but **the spread is 228 and 3 pixels, against dingbat's 2193
and 4215.** So DMG revision does *not* explain either failure. That is a clean
negative that removes a whole class of excuse.

For completeness, the CGB C ↔ CGB D spread across the 24 shared references
(decoded, not guessed): `m3_scy_change` 6217, `m3_bgp_change` 864,
`m3_bgp_change_sprites` 716, `m3_window_timing_wx_0` 144,
`m3_lcdc_obj_en_change_variant` 144, `m3_window_timing` 138, `m3_obp0_change` 42,
and **zero for the other seventeen**. Seven tests exist only in the CGB C set
(the `*2` variants).

## Mooneye's filename convention, from `README.markdown` "Test naming"

> `dmg` = Game Boy, `mgb` = Game Boy Pocket, `sgb` = Super Game Boy, `sgb2` =
> Super Game Boy 2, `cgb` = Game Boy Color, `agb` = Game Boy Advance, `ags` =
> Game Boy Advance SP
>
> Revision 0 refers always to the initial version of a SoC (e.g. CPU CGB). …
> DMG: 0, A, B, C / CGB: 0, A, B, C, D, E / AGB: 0, A, A E, B, B E.
>
> * G = dmg+mgb / * S = sgb+sgb2 / * C = cgb+agb+ags / * A = agb+ags … For
> example, a test with GS in the name is expected to pass on dmg+mgb + sgb+sgb2.
>
> **For now, the focus is on DMG/MGB/SGB/SGB2, so not all tests pass on
> CGB/AGB/AGS or emulators emulating those devices.**

Verdict protocol: the Fibonacci numbers 3/5/8/13/21/34 in B/C/D/E/H/L followed by
`LD B,B`; failure writes `0x42` six times.

---

# 6. Mooneye acceptance headers worth knowing about

Every mooneye `.s` carries a `; Verified results:` block naming the models it
passes and fails on, plus a rationale. Most restate the filename. These do not,
and each states a number or a quirk that is invisible from the test's name.

| Claim, quoted | Source |
|---|---|
| `(SCX mod 8) = 0 => LY increments 51 cycles after STAT interrupt` / `= 1-4 => 50 cycles` / `= 5-7 => 49 cycles` | `acceptance/ppu/hblank_ly_scx_timing-GS.s` — a **three-band** table, not a linear ramp. This is the sibling instrument to §1.7 and the row `fifo_ppu.nim:654` records dingbat losing under a uniform −2 dots. |
| `line 0 starts with mode 0 and goes straight to mode 3` / `line 0 has different timings because the PPU is late by 2 T-cycles` / `CGB before D: failure` / `CGB D, E, AGB, AGS: different failure than pre-D CGBs` | `acceptance/ppu/lcdon_timing-GS.s` — names the **2 T-cycle** LCD-on lateness outright, and states there are **two distinct CGB failure modes split at revision D**. Directly relevant to `LCD_ON_LINE0_TRIM` in `gb.nim`. |
| `M = 0: write to $FF46 happens` / `M = 1: nothing (OAM still accessible)` / `M = 2: new DMA starts, OAM reads will return $FF`; and for a *restarted* DMA, `M = 1: previous DMA is running (OAM *not* accessible)` | `acceptance/oam_dma_start.s` — **two different M-cycle tables** depending on whether a DMA was already in flight. |
| `Apparently the TIMA register contains 00 for 4 cycles before being reloaded with the value from the TMA register. The TIMA increments do still happen every 64 cycles, there is no additional 4 cycle delay.` | `acceptance/timer/tima_reload.s` — the "no additional delay" clause is the half emulators get wrong. |
| `the timer circuit design causes some unexpected timer increases` / `BC < $FFF8 — Your emulator does not emulate the unexpected timer increases, so the interrupt happens too late.` | `acceptance/timer/rapid_toggle.s` — ships its own failure decoder with a numeric threshold. |
| `These instructions take 12 cycles and also trigger the mentioned behaviour.` (of `ldh (<DIV),a`) | `acceptance/timer/tim01_div_trigger.s` — falling edge on internal-counter bit 3, and the write instruction itself re-triggers it. |
| `serial clock is divided from the main clock with a big counter, so clock edges align based on the *reset time*, not the time when SC is written to` | `acceptance/serial/boot_sclk_align-dmgABCmgb.s` — a global free-running divider. Passes DMG **ABC** + MGB, fails **DMG 0**. |
| `On CGB/GBA DI has a delay and this test fails in round 2!!` | `acceptance/di_timing-GS.s` — a **CGB-only DI delay**, documented almost nowhere else. |
| `If bit 5 (mode 2 OAM interrupt) is set, an interrupt is also triggered at line 144 when vblank starts.` / `Expected behaviour: vblank and stat_m2_144 are triggered at the same time` | `acceptance/ppu/vblank_stat_intr-GS.s` — dingbat models this (`5edfe2d`, "the OAM STAT source is a pulse at the top of a line"). |
| `The written value is $02, which clears the INTR_TIMER bit and cancels the interrupt dispatch. PC is set to $0000 instead of the normal jump address.` | `acceptance/interrupts/ie_push.s` — the `PC = $0000` outcome is the whole test. |
| `On DMG the sprite flags have unused bits, but they are still writable and readable normally` | `acceptance/bits/mem_oam.s` — an explicit *anti*-quirk. |
| `Bootrom duration on real SGB/SGB2 depends on the header bytes, including the global checksum, which in turn depends on every byte in the ROM.` | `acceptance/boot_div-S.s`, `boot_div2-S.s` — why the pair exists and why it uses a deliberately invalid checksum. |
| `pass: DMG ABC, MGB, CGB, AGB, AGS` / `fail: DMG 0` | `acceptance/ppu/stat_irq_blocking.s` — the only acceptance row whose expectation splits DMG 0 from DMG ABC **without** a filename suffix saying so. |
| `Serving an interrupt is supposed to take 5 M-cycles.` plus the full `x=50`/`x=51` equivalence derivation | `acceptance/intr_timing.s` |

dingbat passes every row in this table today.

---

# 7. SameSuite, non-APU-channel-1/2

**33 of the 261 rows** (channel 3 ×14, channel 4 ×12, the `div_*` five, DMA ×4,
`ppu/blocking_bgpi_increase`, SGB ×2 — minus the 26 channel_1/2 rows another
round owns). dingbat currently runs and passes 5 of them and does not run the
rest.

Every `.asm` in this suite carries a header comment stating the behaviour in
M-cycles, which is the property the previous round found so valuable. **There is
no README under `dma/`, `ppu/`, `sgb/` or `interrupt/`** — `apu/README.md` and the
three-line top-level `README.md` are the only prose, so the per-file headers are
the whole documentation for the non-APU half.

Scoring plumbing (`include/base.inc`): a `CorrectResults:` table is byte-compared
against a RAM buffer, the six registers are set to the Fibonacci numbers
3/5/8/13/21/34 on success and `$42` on failure, sent over serial, then `ld b, b`
and `halt`. Same protocol dingbat already scores 5 rows with.

## 7.1 Which revision each SameSuite row targets

`apu/README.md`:

> * Pre-CGB devices – pass `div_write_trigger` and `div_write_trigger_10`
>   (Tested: DMG-B, blob). Other tests fail because they rely on the CGB-only
>   PCM registers.
> * CPU-CGB-C – passes the channel 3 tests and non-channel-specific tests. Most
>   other tests fail (see To Do)
> * CPU-CGB-D - passes all tests, except `channel_1_sweep_restart_2`
> * CPU-CGB-E – passes all tests
> * SameBoy – when emulating CGB-CPU-E, passes all tests except
>   `channel_4_freq_change` and `channel_1_sweep_restart_2`.

and the reason the channel-4 rows are the hard ones:

> A quirk in CPU-CGB revisions C and older makes registers PCM12 and PCM34
> report a glitched PCM amplitude for channels 1, 2 and 4 if they're read in the
> same M-cycle they change. […] This quirk is what causes tests testing those
> channels fail.

All 26 channel_3/channel_4 ROMs and 3 of the 5 `div_*` ROMs are `CGB_MODE` and
read `rPCM12`/`rPCM34`; dingbat implements both (`memory.nim:350-358`), so they
are runnable today. `channel_4_freq_change` was written off here on the strength
of its own header (*"Unfortunately the logic behind it is still unclear"*) and
the README recording SameBoy failing it. **That was wrong** — the test is the
only one in the suite that can distinguish the noise timer's divisor stage from
its shift stage, which is exactly why it reads as unclear, and it passes 64/64
once both exist. See `notes/samesuite-apu.md`, "The noise timer is two counters".

## 7.2 CONTRADICTION — the APU must skip its first DIV-APU event if DIV bit 4 is set at power-on

**3 rows: `div_write_trigger_10`, `div_trigger_volume_10`,
`div_write_trigger_volume_10`. Confidence: high. Cost: low.**

`apu/div_write_trigger_10.asm`:

> This test verifies that **starting the APU while bit 4 of the DIV register is
> set causes the APU to skip the first DIV-APU event**

dingbat's NR52 power-on branch (`apu.nim`) sets
`apu.frame_sequencer_stage = 0` and re-arms the event without ever looking at the
DIV tap. **dingbat does not match.**

The *other* half of this family dingbat gets right and names in a comment.
`apu/div_write_trigger.asm`:

> This test verifies that writing to DIV while bit 4 is set triggers a DIV-APU
> event.

`timer.nim:161-173`:

```nim
# Resetting DIV drops every divider bit at once. If the APU tap was high,
# that is a falling edge and the frame sequencer steps EARLY — this is what
# SameSuite's apu/div_* tests check…
let apu_before = (t.tdiv shr apu_div_bit(gb)) and 1
t.tdiv = 0
if apu_before == 1: tick_frame_sequencer(gb.apu, gb)
```

The fix is the mirror of that read, in the power-on branch, setting a one-shot
skip.

## 7.3 CONTRADICTION — channel 4 has no trigger delay and no divisor/shift split

**5-6 rows: `channel_4_delay`, `channel_4_align`, `channel_4_frequency_alignment`,
`channel_4_equivalent_frequencies`, `freq_change`. Confidence: high on the
diagnosis — and the divisor/shift split in this heading was the right call, which
the round that shipped the first four talked itself out of. All 13 channel_4 rows
are green.**

`apu/channel_4/channel_4_delay.asm`:

> This test measures the delay between between the NR44 write and the first
> sample. Although SameBoy does pass this test, I'm not completely sure about
> this logic yet. It appears to be related to how the noise frequency is made out
> of two different values. **Generally speaking, the delay is `sample length + 3`
> M-cycles, but it might be one M-cycle more or less.** For more details, see
> channel_4_frequency_alignment.

dingbat's `channel4.nim` trigger is `ch.next_step = gb.scheduler.cycles +
ch4_period(ch, gb)` — **no addend at all**. Compare `channel3.nim`, which does
carry one (`+ 6`) and cites the same shape of claim. **dingbat does not match.**
Cost: low for the constant.

The harder half. `channel_4_frequency_alignment.asm` has no prose header; its
assertion is the annotation on its expected table:

```
db $00, $00, $00, $F0, $F0, $F0, $F0, $F0 ; $09, affected
db $00, $00, $F0, $F0, $F0, $F0, $F0, $F0 ; $18, not affected
db $00, $00, $00, $00, $F0, $F0, $F0, $F0 ; $28, not affected
db $00, $00, $00, $00, $00, $F0, $F0, $F0 ; $0b, affected
```

NR43 encodings that produce the **same** period ($09 vs $18, $0a vs $28, $1a vs
$0c vs $29 vs $38) land the first sample on **different** dots. Corroborated by
`channel_4_equivalent_frequencies.asm`:

> This test verifies that identical frequencies that are expressed differently
> generate the same output, **other than a potential off-by-one sample caused by
> the start delay.**

dingbat collapses the two fields into one scalar:

```nim
proc ch4_frequency_timer(ch: GbChannel4): uint32 =
  (if ch.divisor_code == 0: 8'u32 else: uint32(ch.divisor_code) shl 4) shl ch.clock_shift
```

so $09 and $18 are literally indistinguishable. **Cost: high** — needs the
divisor and the shift as two real counters rather than their product.

## 7.4 Channel 4's LFSR is already right, including the polarity that looks wrong

**6 rows expected free. Confidence: high. Do not "fix" any of this.**

| source claim | dingbat |
|---|---|
| `channel_4_lfsr`: "verifies the LFSR algorithm used is correct. For convinence, it proccesses the results into reconsructed LFSR values." | matches in substance — `new_bit = bit0 xor bit1; lfsr >>= 1; lfsr \|= new_bit shl 14`, output `not lfsr and 1`. The **bit-complement** of SameBoy's convention, so `$7FFF` init ≡ SameBoy's 0. |
| `channel_4_lfsr15` | same argument |
| `channel_4_lfsr_restart`: "verifies the contents of the LFSR register **are cleared on restart**" | `ch.lfsr = 0x7FFF` on trigger **is** "cleared" in dingbat's representation. **Setting it to 0 would break the row.** |
| `channel_4_lfsr_restart_fast`: "…even on a fast restart" | reset is unconditional on every trigger |
| `channel_4_lfsr_15_7`: "verifies the contents of the LFSR are **retained correctly when switching from 15-bit LFSR to 7-bit LFSR**" | dingbat keeps the full 15 bits and only forces bit 6 per shift; it never truncates, so the upper bits survive a mode flip |
| `channel_4_lfsr_7_15` | same |

## 7.5 Channel 3 — mostly already correct, and the reasons are quotable

**14 rows, most expected to pass on first run. Confidence: high on the matches.**

| test | claim, verbatim | dingbat |
|---|---|---|
| `channel_3_first_sample` | "When channel 3 starts, it **skips the very first wave sample and starts with the second** (after the sample-long delay). Together with channel_3_delay, it seems that the delay is actually just one tick, but the output of channel 3 updates only after a first sample \"phantom\" sample is played." | **matches** — `wave_ram_position = 0` on trigger and `ch3_catchup_slow` advances *before* sampling, so the first observable nibble is index 1 |
| `channel_3_restart_delay` | "**The previous sample remains playing until the first \"phantom\" sample finishes**, then the new pulse starts with sample 2" | **matches**, and dingbat's own comment says so: *"Index resets, but wave_ram_sample_buffer deliberately does NOT: the last byte read keeps being output until CH3 next reads one (Pan Docs), so the pre-trigger buffer is observable"* |
| `channel_3_shift_delay` | "Modifying the channel 3 shift while the channel is playing **affects PCM34 instantly**, or at most after 2 ticks, even if done in the middle of a sample." | **matches** — `ch3_dac_input` applies the shift live |
| `channel_3_shift_skip_delay` | "verifies **the delay cannot be skipped or shortened** by modifying the shift value" | **matches** — the shift write does not touch `next_step` |
| `channel_3_stop_delay` | "Stopping channel 3 manually using the NR30 register **affects PCM34 instantly**" | **matches** |
| `channel_3_freq_change_delay` | "Modifying the wave length while the channel is playing will take effect only for the next sample. i.e., **it cannot shorten or extend the length of the currently playing sample.**" | likely matches — `next_step` is an absolute deadline. Risk: `apu_write` catches CH3 up on the NR33/NR34 write; verify the pending deadline is not recomputed |
| `channel_3_wave_ram_locked_write` | "**The byte is written at the offset CH3 is currently reading.** Except on AGB, where the write is simply ignored." | **matches** — `if ch.enabled: ch.wave_ram[ch.wave_ram_position div 2] = val` |
| `channel_3_and_glitch` | "**Channel 3 is not affected by the PCM34 AND glitch in neither single not double speed mode**" | **matches by omission** — dingbat models no PCM glitch anywhere (`memory.nim:355-358` is a plain OR of the two DAC inputs). Free pass |
| `channel_3_stop_div` | "Channel 3's stop timer is ticked by the DIV register at 512Hz. **The sound stops instantly in the same cycle DIV's bit 5 turns from 1 to 0.** (Or bit 4 in when in single speed mode). **The length of the sound is `((255 - NR31) * 2 + 1)` DIV-APU ticks.**" | partly — the tap is speed-aware (`apu_div_bit`), the count is right, the extra-clock-at-enable quirk is implemented. The per-cycle "instantly" is the risk |
| `channel_3_delay` | "It takes `(wavelength / 32)` (i.e sample length) `+ 3` ticks from the moment channel 3 is enabled until PCM34 is affected. (The read operation itself takes 2 cycles)." | probably matches — dingbat encodes this as `+ 6` scheduler cycles; confirm the units |
| `channel_3_restart_during_delay` | **no header comment** — the only channel_3 file without one; expected table only | unknown |

## 7.6 DMA and BGPI — dingbat already matches, and cites the ROMs by name

**5 rows, all currently green. Recorded so they are not disturbed.**

`dma/gdma_addr_mask.asm`:

> **Addresses written to HDMA1-4 are masked. The lowest 4 bits of addresses are
> always ignored**

`ppu.nim:1294-1308` implements it and quotes Pan Docs for the same sentence, with
`let dst_base = 0x8000 or int(ppu.hdma_dst and 0x1FF0'u16)`.

`dma/hdma_lcd_off.asm` (and `hdma_mode0.asm`, which carries the identical
copy-pasted header despite enabling the LCD):

> Test what happens when performing a HDMA with LCD off. **A single tile should
> get copied, and the count should decrement once**

Expected tail `db $02, $80` — HDMA5 reads `$02` right after the write, then `$80`
(bit 7 set = stopped) after `$00`. `ppu.nim:844-875` names the ROM in its own
comments.

`dma/gbc_dma_cont.asm`:

> Test what happens when **partially initializing a new GDMA after the previous
> one ends normally**

`ppu/blocking_bgpi_increase.asm` — the assertion is the expected table plus the
mode sweep. Four sub-tests fire the BCPD write in modes 0, 1, 2 and 3 and **all
four read back `$C5`**:

```
CorrectResults:
; Bit 6 is always set, bits 0-5 reflect the current value, TODO: what about bit 7?
db $C4, $C5, $C4, $C5, $C4, $C5, $C4, $C5
```

i.e. **the palette index auto-increments even in mode 3, where the palette write
itself is blocked**, and BCPS reads back with bit 6 forced. dingbat matches on
both counts (`ppu.nim:1107-1119`, `1311-1319`): `0x40'u8 or …` for the read, and
the increment is ungated by mode.

## 7.7 SGB `MLT_REQ` — the assertions are inline, and dingbat has no SGB state at all

**2 rows. Cost: medium-high (net-new subsystem).**

Neither file has a behavioural header beyond one line, but both annotate the
packet sequence, which is what makes them usable.
`sgb/command_mlt_req.asm`:

> `; Initial value always reads out as controller 1`
> `; Test to see if the controller value is reset by going back to 1 player`
> `; Test to see the controller value in unsupported MLT_REQ 2`
> `SgbPacket MLT_REQ_1 ; Each of these increments the player 5 times before it gets ANDed`
> `SgbPacket MLT_REQ_3 ; This should increment the player 6 times before it gets ANDed`
> `; Test if invalid mode 2 has a glitched player 3`

`sgb/command_mlt_req_1_incrementing.asm` ships a per-write truth table for which
P1 sequences advance the player index: `$10→$30` increments; `$20→$30` does not;
`$10,$20,$30` increments; `$10,$20,$10,$30` does not; `$10,$10,$30` increments;
`$00,$10,$30`, `$10,$00,$30` and `$00,$30` all increment. Expected
`db $FE, $FE, $FF, $FF, $FE, $FF, $FE, $FF`.

There is no SGB player-index state anywhere in `src/dingbat/gb/` — see §8.6 for
the third SGB row and the shared cost.

---

# 8. GBMicrotest

**Zero shootout weight** — GBMicrotest is not one of the 261. It is dingbat's own
gate and, more importantly, one of the oracles the PPU derivations in
`fifo_ppu.nim` are traded against, so its claims matter to the mealybug work in
§1 even though its rows do not score.

`README.md`:

> All tests in this repo have been checked on real hardware (**version
> DMG-CPU-08** I believe).

> These tests instead check exactly one register or memory address at one
> specific cycle after boot and then write a pass/fail value to VRAM…

> - 0xFF80 - Test result / - 0xFF81 - Expected result / - 0xFF82 - 0x01 if the
>   test passed, 0xFF if the test failed.

`build.sh` builds the shipped ROMs `-DDMG`, which is load-bearing: eight files
branch on `.ifdef DMG` and **only the DMG arm is in the binary**. Per-file tags:
128 files say `; pass - dmg`, 12 `; pass - ags`, 25 `; pass - ags, dmg`.

## 8.1 The suite contradicts *itself* on the SCX mode-3 penalty, and dingbat picked the half its own header supports

**≈8-12 dingbat rows. Recommendation: do not spend. Confidence: high.**

Two ROMs state the DMG penalty table outright. `tests/500-scx-timing.s` and
`tests/minimal.s`, identical header:

```
; ags overhead 70?
; 0 0 0 1 1 1 1 2

; dmg overhead 65
; 0 1 1 1 1 2 2 2
```

(extra M-cycles of mode 3 for SCX = 0..7). Now the four scored families,
extracted from their `test_finish_*` arguments:

| family | scx0..7 expected | which row of the header |
|---|---|---|
| `int_hblank_incs_scx0..7` | 61,62,62,62,62,63,63,63 | **DMG** |
| `int_hblank_nops_scx0..7` | 97,98,98,98,98,99,99,99 | **DMG** |
| `int_hblank_halt_scx0..7` | 98,98,98,99,99,99,99,100 | **AGS** |
| `hblank_int_scx0..7` | 45,45,45,—,—,46,46,47 | **AGS** |

**Half the suite is built against the AGS table and half against the DMG table,
in ROMs that were all assembled `-DDMG`.** dingbat reconstructs to
`0 1 1 1 1 2 2 2` — the DMG row — passes all 16 `int_hblank_incs_*` /
`int_hblank_nops_*` rows, and fails exactly where the AGS row differs:
`hblank_int_scx{1,2,5,6}` and `int_hblank_halt_scx{0,3,4,7}`.

dingbat already diagnosed and priced this, at `ppu.nim:264-276`:

> The GBMicrotest hblank_int_scx0..7 family measures the same thing at DOT
> resolution […] **12 of its rows want the PPU two dots later against the CPU
> than 397 puts it.** […] **the whole (D, L) grid was swept against this seed at
> 397 and at 399 and no cell buys those 12 rows without spending more
> elsewhere.**

The new information is that the suite's *own* `500-scx-timing.s` header sides
with dingbat, and that the split is a DMG/AGS one. Mark these rows
"suite-internal contradiction" rather than leaving them looking like a
20-row debt.

## 8.2 Line 153: the LY snapback is one M-cycle late and the LYC comparator misses the whole window

**≈8 dingbat rows. Confidence: high. Cost: medium.**
**SHIPPED 2026-08-09 (the comparator half); see the closing note at the end of
this section for what it bought and what is left.**

`line_153_ly_{a,b,c,d}.s` pin the DMG sequence at M-cycle resolution: `nops 4` →
LY 152, `nops 5` → 153, `nops 6` → `.ifdef DMG / .define RESULT 0 / .else /
.define RESULT 153`, `nops 7` → 0. **On DMG, LY reads 153 for exactly one
M-cycle.** dingbat gives `line_153_ly_c: actual=0x99 expected=0x00` — one
M-cycle late. `fifo_ppu.nim:1265` has `if ppu.ly == 153 and ppu.cycle_counter >
4: ppu.ly = 0`; the threshold wants to be ~3.

`line_153_lyc153_stat_timing_*.s` (`; pass - dmg`, LYC = 153) repeats a full
table as a header in every file of the family:

```
; line 152
; 100 - C1
; line 153
; 101 - C5
; 102 - C1
; 213 - C1
; 214 - C0
; line 0
; 215 - C2
```

dingbat fails `_c` and `_d` (wants `$C1`, gets `$C5`) — **it holds the LYC=153
coincidence flag for the whole line where hardware asserts it for one M-cycle.**

`line_153_lyc0_stat_timing_*.s` is the complement:

```
; 106 - c1
; 107 - c1
; 108 - c5
; 218 - c5
; 219 - c4
```

dingbat fails `_d` and `_e` (wants `$C5`, gets `$C1`) — **the LYC=0 match never
appears during line 153 at all**, over a 110-M-cycle window. Two more rows fall
out of the same defect: `lcdon_to_stat1_c` (`actual=0x81 expected=0x85`, missing
bit 2 = the LYC=0 match) and `line_153_lyc0_int_inc_sled`
(`actual=0x62 expected=0xFF` — it reached `test_fail` with A = 98, so its
*timing* is right and only the interrupt is missing).

dingbat already has the two-clock machinery (`fifo_ppu.nim:1257-1266`, `irq_ly`
snapping back a `lead` ahead of the readable `ly`), so this is a threshold and
coverage bug, not a missing feature — but the same comment records gambatte
`lyc0int_*` / `lyc153int_*` pinning it, so it has to be swept, not nudged.

### Closed 2026-08-09, and the diagnosis above was half right

The **coverage** half was the whole of it, and it was worse than "misses the
window": the snapback assigned `ppu.ly = 0` and ran **no edge detector at all**,
so the comparator's next look was the line boundary 451 dots later. Every
consequence listed above follows from that one missing call, and so does one the
list never connected to it — `daid/ppu_scanline_bgp-dmg`, whose entire frame is
laid out by the arrival of this interrupt (§ the shootout notes).

Restoring the call, plus the read path's own one-M-cycle blind window
(`LYC_SETTLE_DOTS` in `gb/ppu.nim`, where the derivation and the sweep table
live), takes the `line_153_*` set from 19/24 to **23/24** and closes
`lcdon_to_stat1_c`, both `mooneye-wilbertpol ly_lyc_{0,153}_write-GS`, and the
daid row (68.8% → pixel-exact). gambatte `ly0` 66 → 74, `lycEnable` 172 → 179,
`lycm2int` 8 → 10, `m1` 122 → 123, `m2enable` 93 → 94 — whole suite 3837 →
3856, whole runner 735 → 743, zero PASS → FAIL, against `a4a3a46`.

The ten gambatte rows it costs are all `*_ifw_*`, `*_late_retrigger*` or
`lyc0_late_m2enable_lycdisable_1`, i.e. the STAT edge-detector re-trigger
bucket, and `tools/gbppu/famflip.py` shows why: at the old dot `_ifw` read
`E2,E0` and now reads `E2,E2`, which is what its `_late_retrigger` sibling read
at BOTH settings. That gap and this one used to cancel.

The **threshold** half — `line_153_ly_c`, "the threshold wants to be ~3" — is
NOT shipped, and this pass added the measurement that says it is not a threshold
question either. `line_153_ly_c`, `line_153_lyc0_int_inc_sled` and
`line_153_lyc0_stat_timing_c` all move together with `LCD_ON_LINE0_TRIM` and
trade 1:1 against each other on it (built: at `=2` the first two pass and the
third fails, at `=0` the reverse), while nothing else in the tree — including
the daid frame, which does not sync off an LCD enable — moves at all. They are
three readings of the LCD-on dot phase (bucket 17 / bucket 15), not of the
line-153 snapback, and they should be scored there.

## 8.3 The mode-2 / OAM STAT edge is uniformly one M-cycle late

**9 dingbat rows. Confidence: high. Cost: low-medium.**

Every failing member is `+1` and every passing member is one where `+1` does not
cross an observation boundary: `lcdon_to_oam_int_l0` (wants 111, gets 112),
`_l1`/`_l2` (100 → 101), `int_oam_incs` (111 → 112), `int_oam_nops` (147 → 148),
`oam_int_inc_sled` (100 → 101), `oam_int_nops_a` (`test_finish_div 1` → 2),
`oam_int_if_edge_d` (`$E0` → `$E2`), `lyc1_int_if_edge_a` (`$E0` → `$E2`).
`int_oam_halt` (`test_finish_cycle 148`) and `oam_int_nops_b` (DELAY 22) pass,
which brackets the error to exactly one M-cycle. `oam_int_nops_a/b` and
`oam_int_halt_a/b` have *identical* DMG and non-DMG arms, so there is no revision
ambiguity here.

## 8.4 Line 144: the VBlank IF flag is raised before the OAM STAT flag; hardware is the other way round

**3 dingbat rows. Cost: medium.**

`line_144_oam_int_{a,b,c,d}.s` differ only in nop count and each states its intent
in its first line: `; di happens before interrupt` (→ `$E0`), `; ld happens before
interrupt and before if change, di not hit` (→ `$E0`), `; …and after if change…`
(→ `$E2`), `; ld happens after interrupt` (→ `$00`). dingbat: `a` passes, `b`
falls through to `test_fail` (interrupt did not fire in time), `c` gives `$E3`
for `$E2`, `d` gives `$E3` for `$00`. **`$E3` vs `$E2` means dingbat has IF bit 0
(VBlank) set on an M-cycle where hardware has only bit 1 (STAT).**

## 8.5 Two timer-interrupt rows never fire at all — the highest value-per-row item in this suite

**3 dingbat rows, 2 of them total misses rather than off-by-ones. Cost: medium.**

`int_timer_incs.s` annotates its target M-cycle inline:

```
  ld a, $FE
  ldh (TIMA), a
  ld a, %00000101
  ldh (TAC), a
  ei    // 4
  inc a // 5
  ...
  // 9 - int fires on A
  ...
  di
  test_fail
.org TIMER_INT_VECTOR
  test_finish_a 9
```

dingbat gives `actual=0x09 expected=0xFF` — A reached 9 at `test_fail`, i.e. the
interrupt **never arrived** inside the 13-M-cycle window. `int_timer_nops` is the
same shape and the same total miss. `int_timer_halt` and `int_timer_nops_div_b`
pass; `int_timer_nops_div_a` is `+1`. Both failures enable the timer by writing
TAC with TIMA = `$FE` and DIV freshly zeroed — suspect the TAC-enable edge phase.

## 8.6 `halt_op_dupe_delay`'s expected value is physically unattainable

**1 dingbat row. Recommendation: do not spend.**

```
  xor a
  ldh (DIV), a
  halt   ; halt takes two cycles, next op is duped on second cycle
  nop
  ; 57/58
  nops 58
  test_finish_div $55
```

DIV increments every 64 M-cycles and there are ~62 M-cycles between the reset and
the read, so **DIV cannot exceed 1** unless HALT blocks for ~5,440 M-cycles, which
the HBlank-every-line setup rules out. `$55` is also the scratch marker in
`cpu_bus_1.s` (`ld a, $55`) and in a commented-out block of `400-dma.s`. The
correctly-written sibling `halt_op_dupe.s` (`xor a / halt / inc a / nop /
test_finish_a 2`) **dingbat passes**. dingbat's `0x01` is the right answer.

## 8.7 Why 31 ROMs are unscoreable, in the sources' own terms

dingbat already knows 31 GBMicrotest ROMs never write `$FF82`. The sources say
*why*, and two of them explain dingbat's odd reported bytes exactly:

* `dma_basic.s` and `400-dma.s` **assemble HRAM code at `$FF80`**, so the
  "results" bytes are opcodes. `dma_basic` writes `$E0,$46,$18,$FE`
  (`ldh ($46),a` + `jr -2`) to `$FF80-$FF83` — which is byte-for-byte dingbat's
  `actual=0xE0 expected=0x46 verdict=0x18`. **These two can never be scored and
  should be excluded, not debugged.**
* `cpu_bus_1.s` is a four-instruction bus probe (`ld hl, BASE / ld a, $55 / -
  ld (hl), a / jr -`) that writes `$55` to `$FF80` forever — dingbat's
  `actual=0x55 expected=0x00 verdict=0x00` is literally that.

## 8.8 Free oracles hiding in the unscoreable ROMs

The verdict-less ROMs carry the best tables in the suite. They are worth keeping
even though no row depends on them.

`lcdon_write_timing.s` — an explicit dot table, and it says **AGS**, not DMG:

```
; ags
;   0 - dots
;  17 - dots  (last cycle of oam line 0)
;  18 - white (first cycle of vram on line 0)
;  60 - white (last cycle of vram on line 0)
;  61 - dots  (first cycle of hblank on line 0)
; 111 - white (last cycle of line)
; 112 - white (first cycle of oam on line 1)
; 131 - white (last cycle of oam on line 1, no hole between oam and vram)
; 132 - white (first cycle of vram on line 1)
; 174 - white (last cycle of vram on line 1)
; 175 - dots  (first cycle of hblank on line 1)
; 225 - white (last cycle of hblank on line 1)
```

`002-vram_locked.s` — a per-M-cycle DMG STAT table for lines 0-1, **including a
hardware glitch the suite documents nowhere else**:

```
;   6 - stat 10000101
;   7 - stat 10000100 - glitch stat reads as hblank?
;   8 - stat 10000110 - oam line 0 starts here
;  27 - stat 10000110 - oam line 0 ends here
;  28 - stat 10000111 - vram line 0 starts here
;  70 - stat 10000111 - vram line 0 ends here
;  71 - stat 10000100 - hblank line 0 starts here
; 121 - stat 10000000 - lyc goes 0 on last cycle of hblank
; 122 - stat 10000010 - oam line 1 starts here
```

`000-oam_lock.s` carries a DMG OAM-lock dot table with `;   0 - 01100010 ? oam
not clean on boot?` and `;  69 - black / ;  70 - garbage`.
`mode2_stat_int_to_oam_unlock.s` names both the correct answer and a wrong
emulator's: `; correct - / ; 54 - black / ; 55 - white` versus
`; ticktocc - / ; 53 - black / ; 54 - white`.

---

# 9. MBC3 RTC: two one-line contradictions worth two shootout rows

## 9.1 CONTRADICTION — MBC3's RAM-bank register is 4 bits wide; dingbat stores all 8

**Row: `cpp/rtc-invalid-banks-test` (91.7%, 1920 px wrong) — 1 shootout row.
Confidence: certain. Cost: one token.**

`CasualPokePlayer/test-roms`, branch `rtc-invalid-banks-test`, `README.md`:

> The RAMB register for MBC3+RTC is a **4 bit register. The upper 4 bits do not
> affect the bank selected.**
>
> When RTC is present, all 4 bits must be used, thus all are connected.
>
> There is a range of 16 combinations that can be mapped. However, only up to 4
> RAM banks can be mapped to the MBC3, and there are only 5 RTC registers
> present, leaving only **9 possible valid combinations**. This leaves **"banks"
> 04-07 and 0D-0F never mapping to anything.**
>
> The test seems to show that these invalid "banks" appear to produce **open
> bus** behavior.
>
> Disclaimer: This test was originally ran within ROM. […] The test now does
> **reads from HRAM to consistently read `$FF`**.

The ROM sweeps `e = $00..$FF` into `$4000` and reads `$A000` from an
HRAM-resident routine, printing 256 bytes — so the expected image is a 16-entry
pattern repeated 16 times.

`src/dingbat/gb/mbc/mbc3.nim`:

```nim
  of 0x4000..0x5FFF:
    cart.ram_bank_num = val
```

No mask. Reads then test `ram_bank_num <= 3` and `>= 0x08 and <= 0x0C`, so every
`e >= $10` falls to the `else: 0xFF` arm instead of aliasing. **Fix:
`cart.ram_bank_num = val and 0x0F`.** Check MBC1/MBC5 separately — only MBC3 was
inspected.

## 9.2 CONTRADICTION — the RTC latch is a 1-bit register; dingbat compares the whole byte

**Row: `cpp/latch-rtc-test` (90.1%, 2270 px wrong) — 1 shootout row. Confidence:
high on the defect, medium on the exact replacement rule.**

`testroms/cpp.py`:

> Writes random values to RTC regs, reports them back, then latches the RTC
> using a **single write** to the 0x6000-0x7FFF region.

The ROM does 52 iterations of randomise-RTC → report → `call rand; ld [rRTCL],a`
— **one random byte per iteration into `$6000`**.

`mbc3.nim`:

```nim
  of 0x6000..0x7FFF:
    # Writing 0x00 then 0x01 latches the live clock into the readable registers
    if cart.has_rtc:
      if cart.rtc_latch_prev == 0 and val == 1:
        cart.rtc_latched = cart.rtc_live
      cart.rtc_latch_prev = val
```

This requires the full byte to be exactly `$00` then exactly `$01`. With uniformly
random bytes that is ~1/65536 per iteration, so **dingbat effectively never
re-latches** and all 260 reported bytes stay at their initial zeros — which is
what 90.1% looks like. Hardware latches on the 0→1 edge of a **1-bit** register,
~1/4 of iterations.

**Caveat before writing the fix.** The branch README says only *"This test aims
to research MBC3 RTC latching"* and **publishes no conclusion**. Two candidate
rules survive — bit-0 edge, or "any write latches" — and they are distinguishable
by decoding `shootout/testroms/cpp/latch-rtc-test.png`: under "any write" all 52
reports are fresh randoms; under the bit-0 edge about 3/4 of reports repeat the
previous one. Resolve that first, then apply
`let b = val and 1; if cart.rtc_latch_prev == 0 and b == 1: …; cart.rtc_latch_prev = b`.

## 9.3 `cpp/ramg-mbc3-test` passes for the reason the README gives

`ramg-mbc3-test` `README.md`, the whole conclusion:

> A simple test to deduce how many bits wide the MBC3's RAM gate register is.
>
> **rRAMG is a 4 bit register, where 0xA enables RAM, and other values disable
> RAM.**

`mbc3.nim`: `let enabling = (val and 0x0F) == 0x0A`. Matches exactly. The branch
also sets `SRAMSIZE := 0x02` ("Don't use \"2KiB\" SRAM (instead use the more
defined 8KiB SRAM)"), so the shipped `.gb` has `$0149 = $02`.

## 9.4 rtc3test: `tests.md` is the document, and dingbat already implements all of it

**3 shootout rows: `-1` 97.5%, `-2` green, `-3` 98.0%.**

The `README.md` is a stub; `tests.md` is the specification, and every sub-test
PASSes on hardware (all 8 rows are green in both reference images). Conventions
first:

> The control register actually contains one bit of the day counter (as well as
> the on/off toggle and the overflow flag), but for simplicity it is still
> referred to as the control register.

> all such tests have some tolerance for measurement error. However, **these
> tests will fail if carried out in a platform with a significantly inaccurate
> clock, such as the Super Game Boy.**

**Basic (`rtc3test-1`):** *Tick* — "evaluates the time taken between successive
ticks. (expected: 1000ms, tolerance: 1ms)" (dingbat: `RTC_SECOND_CYCLES = 4194304`,
scheduled exactly). *RTC off* — "waits approximately four seconds for it to tick.
The test fails if the RTC ticks" (dingbat clears `etRtcSecond` on halt).
*Register writes* — "will pass if the state read back is equal to the new state,
**or to the new state plus one second**". *Rollovers* — "sets the RTC state to 255
days, 23:59:59 […] passes if the new value is 256 days, 00:00:00". *Overflow* —
"sets the RTC state to 511 days (without overflow), 23:59:59 […] passes if the
overflow flag is set after it ticks". *Overflow stickiness* — "passes if the
overflow flag remains set". All eight read as correct against `gb.nim:1427-1456`.

**Range (`rtc3test-2`, green):** "writes values to the RTC registers with all
valid bits set (`$3F` to the seconds and minutes registers, `$1F` to the hours
register, `$FF` to the days register and `$C1` to the control register)" — the
exact array in `mbc3.nim` (`const masks = [0x3F, 0x3F, 0x1F, 0xFF, 0xC1]`). And
the invalid-rollover rule, which dingbat implements:

> tests rollovers where the seconds, minutes and hours registers roll past the
> maximum value that will fit in them (63 for seconds and minutes and 31 for
> hours); in all cases, this should set the affected register to zero **without**
> causing the next register to increment.

**Sub-second (`rtc3test-3`):**

> These tests check the behavior of the **sub-second counter** in the RTC when a
> register is written to. […] These tests are named after the register that is
> written to and the time remaining (in milliseconds) until the next tick at the
> time of writing. […] The tolerance is **1.5ms** for all tests.

| test | expected | implied rule | dingbat |
|---|---|---|---|
| RTCS/500, RTCS/900 | 1000 ms | writing **seconds resets** the sub-second divider | `rtc_schedule_full()` ✔ |
| RTCM/50, RTCM/600 | 50 / 600 ms | minutes do **not** touch it | bare store ✔ |
| RTCH/200, RTCDL/800 | 200 / 800 ms | hours and day-low: no reset | ✔ |
| RTCDH/300 | 300 ms | control/day-high: no reset **when the halt bit does not change** | only the halt transition touches the scheduler ✔ |
| RTC off/400 | 400 ms | the **sub-second remainder is frozen across a halt** | saves `rtc_remaining()`, re-schedules it ✔ |

**Negative result: there is no "512-cycle latch" claim anywhere in rtc3test.**
The whole sub-second model is expressed in milliseconds-to-next-tick.

Source review found no defect that explains the ~581 px lost across `-1` and
`-3` (≈1-2 result lines each); that needs a run and a row diff. One genuine smell
found on the way: `mbc3.nim:15` assigns the GB-cycle constant
`RTC_SECOND_CYCLES` into `rtc_halt_remaining`, which everywhere else holds
*scheduler* units from `rtc_remaining()` and is re-armed with plain
`scheduler.schedule` while the non-halted path uses `schedule_gb`. Harmless at
single speed; a unit bug at double speed.

---

# 10. bully, strikethrough, and the acid feature maps

## 10.1 bully's black frame, traced to one branch

Extending §1.6. The reference is 22893 white + 147 black; dingbat matches exactly
the 147, i.e. it renders solid black.

* `bully.gb` has `$0143 = $80`, so dingbat sets `cgb_native = true`.
* `new_gb_ppu` seeds `pram`/`obj_pram` **only `if not cgb`** (`ppu.nim:161-173`),
  so on a CGB boot every one of the 32 colours starts at `$0000` = black.
* `ppu.skip_boot` re-seeds them **only in the `if not gb.cgb_native` branch**
  (`ppu.nim:227-238`) — the DMG-compatibility path. Its own comment states the
  exact failure mode for the *other* device: *"without it a compatibility cart
  renders through an all-zero palette, i.e. a black screen"*. **The CGB-native
  path has no equivalent.**
* BullyGB never fixes it. Its only palette write, repeated in `RunTests`,
  `.breakTestLoop` and `CrashHandler`, is `ld a, BCPSF_AUTOINC | 6 / ldh [rBCPS],
  a / xor a / ldh [rBCPD], a / ldh [rBCPD], a` — **BG palette 0, colour 3 only**,
  set to black. Colours 0-2 are inherited from the boot ROM.

**The controlled comparison is in the same results table.** `strikethrough.gb` is
also `$0143 = $80` and also CGB-native under this harness, and it scores 99.8% —
because it writes all four of its own colours (`rBCPD` ×8, `rOCPD` ×8) before
enabling the LCD. bully is the only row in the tree that depends on post-boot CGB
palette RAM.

**Cost: low** — seed `pram`/`obj_pram` for the `cgb_native` case, which every
other emulator does as all-`$FF` (white). **Worth 1-2 shootout rows** (the
shootout scores bully on DMG *and* CGB; dingbat has one row).

**A second, independent blocker sits behind it.** `src/tests/initram.asm`, third
in BullyGB's list and marked compatible with all models:

> `; Check if DE is $2000 (all RAM values either $FF or $00)` …
> `strNonRandomRAM: db "Uninitialized RAM not randomized", 0`

dingbat zero-initialises WRAM (`memory.nim:9`), so this must fail and the ROM
stops there. Seeding WRAM pseudo-randomly is determinism-sensitive
(savestates, rollback, the byte-identical screenshot gate) — **medium cost, and
it should be decided deliberately rather than as part of the palette fix.**

**Harness note to correct:** `dingbat_test_runner.nim:719-722` calls the bundled
`bully.png` "a CGB capture". It is pure `#FFFFFF`/`#000000` with identical
22893/147 counts in both the bundle and the shootout — device-agnostic, and the
shootout scores both devices against it.

## 10.2 strikethrough publishes no claim at all; the assertion has to be read out of the ROM

**Row: `ashiepaws/strikethrough.gb` (53 px wrong, 99.8%) — 1 shootout row. See
also §0.2: this may already be green under the shootout's luma criterion.**

`README.md` in full: *"A Gameboy test ROM for some weird OAM DMA behavior."* The
bundle howto adds only *"I could not find any compatibility information on
Strikethrough. It works on all of my devices though."* The shootout's one-line
description ("Abuse of OAM DMA transfers during PPU modes 2 and 3 causing
interference with data reads from the PPU") is **not from the author**.

Reconstructed from `src/main.asm`: 40 identical sprites at `Y = $54`,
`X = 23 + 8n` — a full-width row of strikethrough bars. A `STATF_LYC` interrupt
at `LYC = $54-$11` spins until mode 0, waits `REPT 28 nop`, then starts OAM DMA,
so the transfer straddles the next line's **mode 2 and mode 3**. The DMA source
is 160 bytes of `$01` with **one `$00`** at byte 46, carrying the only mechanism
comment in the repository:

> `db $01, $01, $00, $01 ; The $00 byte in this line seems to affect the tile
> number of the sprite thats shown`

The expected image reads **`Everyth+ng is OK!`** — of 40 candidate bars exactly
one survives, landing on the `i`. So the assertion is: while OAM DMA is active
across modes 2/3, the PPU's OAM fetch does not see shadow OAM; what it draws is
determined by what the DMA is putting on the bus.

**dingbat models the CPU side of the OAM-DMA conflict unusually well** —
`dma_bus_of` / `dma_drive_of` with the
`DriveTristate`/`DriveSource`/`DriveZero`/`DriveIsolated` taxonomy
(`memory.nim:370-397`) and `mem_read_busy`/`mem_write_busy`. **The PPU side is
absent**: `dma_busy` / `dma_position` / `dma_latch` have **zero hits** in
`ppu.nim`, `scanline_ppu.nim` and `fifo_ppu.nim`. The sprite scan reads
`sprite_table` directly and so sees OAM as it is progressively rewritten.
53 px ≈ a handful of extra or misplaced 8-pixel bars. **Cost: medium-high**, and
there is no documentation to validate a fix against — only this one image.

## 10.3 The acid feature maps — how to read a partial failure

Both READMEs bound the cost of the row up front. `dmg-acid2`:

> A simple line based renderer is sufficient to generate the correct output. This
> is NOT a PPU timing torture test requiring T-cycle accuracy, and does NOT
> perform register writes during the PPU's mode 3.

> The test uses **LY=LYC coincidence interrupts to perform register writes on
> specific rows of the screen during mode 2 (OAM scan)**.

`cgb-acid2` adds: *"Double speed mode and WRAM banking emulation are not
required."* dingbat passes both rows; this table is the diagnostic map if either
regresses.

**dmg-acid2** — face part → what it asserts:

| part | asserts |
|---|---|
| "Hello World!" / the `!` | 10 objects plus a solid-white 11th; the **10-object-per-line limit** must drop the white one (failure: `!` missing) |
| mohawk hair | **LCDC bit 0** — rows 8-15 have BG disabled, so colour 0 from BGP is drawn (failure: hair visible) |
| eye whites, left half | **OAM bit 7** (OBJ-to-BG priority) over BG colour 0 |
| eye whites, top-left quadrant | **LCDC bit 4** — top half from `$8000-8fff`, bottom half from `$8800-97ff` with *signed* indexes `$a1`/`$a2` |
| right eye | the **window**, with WX moved off-screen at its bottom |
| mole beside left eye | *"visible if the background tile data is read from `$8000-8fff` instead of `$8800-97ff`"* |
| mole left of nose | *"not visible because a blank object with a **lower X-coordinate** has priority, even though it is defined later in OAM"* |
| mole right of nose | *"not visible because a blank object at the **same X coordinate** has priority because it occurs **earlier in OAM**"* |
| nose | **OAM bits 5/6** (H/V flip), unflipped top-left; a missing nose means **OBJ palette bit 4** |
| mouth | eight **8×16** objects: *"the objects specify tile index 12, and the right side… 13. Because **bit 0 of the tile index is ignored for 8x16 objects**, the whole mouth effectively uses tile index 12"*; also **LCDC bit 2** |
| right chin | **LCDC bit 6** + the **window internal line counter**: *"Because 16 rows of window have already been drawn for the eye, the right side of the chin is rendered starting from address `$9840`"* (failure: the eye is displayed instead) |
| footer | **LCDC bit 3** (BG map `$9c00`) and **bit 5** (window enable) |
| tongue | **LCDC bit 1** |

**cgb-acid2** — the CGB-specific ones:

| part | asserts |
|---|---|
| eyes | BG **map attribute bits 5/6** (V/H flip of one tile), unflipped top-left |
| eye top-left corner | **OAM bit 7** — green object shows through BG colour 0 only |
| eye top-right corner | **BG map attribute bit 7** (BG-to-OAM priority) — same visual, different register |
| nose | **OAM bit 3** (OBJ tile from VRAM bank 1), over BG with BG-to-OAM priority set, but **LCDC bit 0 master priority reset for the band, so objects are always on top** |
| mole | **`$FF6C` OPRI bit 0** — *"The blank yellow square object OAM entry is before the mole, so effectively covers the mole even though the mole object has a lower X coordinate"* |
| footer | **BG map attribute bit 3** (BG tile VRAM bank), plus map/tile-data/window-enable as DMG |

Failure images not covered above: `master-priority.png`,
`master-priority-dmg-white.png`, `master-priority-dmg-green.png` (three distinct
wrong renderings of LCDC bit 0 on CGB), `obj-vram-bank.png`, `obj-enable.png`,
`obj-size.png`.

## 10.4 `cgb-acid-hell` documents nothing, deliberately

`README.md`, in full:

> 😈 Your Game Boy Color emulator does not pass this test. 😈
> ## ROM Download — This is not a day care.
> ## Emulator Requirements — Not telling. 🤫
> ## Guide — Nope.

The repo ships `cgb-acid-hell.asm`, a **15,340-line uncommented RGBDS
disassembly** with auto-generated labels. **Nothing to mine.** The only usable
artefacts are `img/reference.png` and `img/photo.jpg`. dingbat is **2 pixels**
off — see §0.2, where the shootout's own criterion may already accept it.

## 10.5 `acid/which.gb` is a hardware-identification ROM, not a test

Two of the 264 rows. `acid.py` declares it with no `result=`, and no `which.png`
exists, so `getDefaultResult()` returns `INFO`. Its strings are `which.gb v0.3` /
`seems to be a...` / `SGB-CPU 01`, `DMG-CPU`, `DMG-CPU A/B/C`, `CPU SGB2`,
`CPU MGB`, `CPU CGB A/B`, `CPU CGB C`, `CPU CGB D`, `CPU CGB E`,
`CPU AGB 0/A/A E`, `CPU AGB B/B E`, `Unknown!`. **It only reports which SoC
revision your model claims to be** — which makes it, incidentally, the fastest
way to sanity-check §5's revision map against dingbat's own boot models.

## 10.6 `cpp/sgb-ext-test` — what an SGB row would actually cost

**1 shootout row, plus SameSuite's 2 (§7.7) for the same subsystem.**

`README.md` in full: *"This test aims to research the SGB packet protocol."*
**No conclusion published** — the correct answers exist only as pixels in
`sgb-ext-test.png` (a 160×144 grid of binary digits, 13084 white / 9956 black:
the 256-byte `wTestOutput` rendered as bits). The assertions live in
`src/intro.asm`, which runs 25 cases: each sends an `MLT_REQ` packet by a
deliberately malformed method, then polls `$00`→`$30` on `rP1` counting
iterations until `P1 and $0F == $0F`, and stores the recovered player count
(1/2/4) as the oracle. The malformations, with the author's own comments:

* `SendPacketBasic` — control.
* `SendPacketCorruptStop` — *"Packets are normally terminated by a "STOP" 0 bit /
  We'll send a "corrupt" STOP 1 bit"*.
* `SendPacketAvoid30` — *"Packet transmission normally begins by sending $00 then
  $30 / Maybe it actually begins with both bits going high to low at the same
  time"*.
* `SendPacket20To10` / `10To20` / `00To10` / `00To20` / `10To00` / `20To00` — the
  first bit of the joypad-mask byte driven through an intermediate P1 value,
  probing whether the SGB samples an edge or a level.
* `SendPacketShortStart` — *"Try omitting that `$30` write"*.

To score this dingbat needs a P1-write edge decoder (`$00`→`$30` start pulse,
`$10` = 1 / `$20` = 0 per bit, `$30` terminate, 16-byte packets), `MLT_REQ`
handling that changes how many pads are multiplexed onto P1, and the
`P1 and $0F == $0F` rotation. dingbat has `bmSgb`/`bmSgb2` boot models and a
careful SGB boot-DIV model (`timer.nim:19-38`) but **no packet layer at all**.
**High cost, 3 rows** across this and SameSuite. Its runner comment
(`dingbat_test_runner.nim:539-542`) already says exactly this.

---

# 11. More negative results

Recorded so nobody re-digs. See also §4.

* **`BullyGB/README.md`** points at a GitHub wiki and ships no test list. The
  list is the `TestRoutines::` table in `src/tests.asm` and the eight files under
  `src/tests/`.
* **`strikethrough.gb/README.md`** is one sentence (§10.2).
* **`cgb-acid-hell/README.md`** is deliberately empty and the source is an
  uncommented disassembly (§10.4).
* **CasualPokePlayer's `latch-rtc-test` and `sgb-ext-test` branch READMEs** are
  one sentence each with **no conclusions** — unlike `ramg-mbc3-test` and
  `rtc-invalid-banks-test`, which both publish a `# Conclusion` section. The
  distinction matters: the two with conclusions are one-line fixes (§9.1, §9.3),
  the two without require reverse-engineering the oracle from a PNG.
* **SameSuite has no README under `dma/`, `ppu/`, `sgb/` or `interrupt/`** — only
  the per-file headers and `apu/README.md`.
* **`channel_3_restart_during_delay.asm`** is the one channel_3 source with no
  header comment.
* **`channel_4_align.asm`'s header is wrong**: it says *"This test verifies that
  **channel 1** ticks at 1MHz"* while the test writes NR42/NR43/NR44 and reads
  PCM34's high nibble. Quote it with the caveat.
* **`channel_4_volume_div.asm`'s header names the wrong register** too: *"The
  volume envelope is triggered by the DIV register after it ticks the APU
  `(8 * (NR12 & 7))` times (at 512Hz)"* — the test writes NR42.
* **`hdma_mode0.asm` carries `hdma_lcd_off.asm`'s header verbatim** ("with LCD
  off") while actually enabling the LCD and halting for mode 0. Copy-paste, not a
  claim about the LCD.
