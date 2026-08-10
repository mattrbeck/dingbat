# The parked bundle, measured against main — 2026-08-10

Base commit `d8ef3b1` (`docs/gb: hdma_late_disable is not an SCX row, and it
contradicts lycirq_m2stat`), i.e. after the runtime CGB-revision axis landed.
No source was changed for any of this: every world below is the same tree
built with different `{.intdefine.}` values.

Measurements only. This note takes no position on whether to ship.

## The knobs, verified

All four names in the brief are real, and the brief's values are all changes
from the shipping default:

| constant | home | ships at | bundle value |
|---|---|---|---|
| `HALT_IF_SAMPLE_T` | `src/dingbat/gb/cpu.nim:355` | 4 | 2 |
| `STAT_M2_LEAD` | `src/dingbat/gb/ppu.nim:903` | 0 | 1 |
| `M3_PIPE_AHEAD` | `src/dingbat/gb/fifo_ppu.nim:1794` | 0 | 1 |
| `LY0_PIPE_MCYCLES` | `src/dingbat/gb/fifo_ppu.nim:1765` | **1** | 0 |

`M3_PIPE_AHEAD` and `LY0_PIPE_MCYCLES` are not `*`-exported; `-d:` still
reaches them. `LY0_PIPE_MCYCLES` is the one that ships **on**, so the bundle
turns it off.

Two knobs named for the combination round resolve differently than the brief
assumed: `CGB_HALT_PPU_LEAD_DOTS` (`gb.nim:332`) is derived as
`4 * CGB_HALT_PPU_LEAD` and so is **0** by default, not 4 — setting it to 4 is
a change, and setting it to 2 is the sub-M-cycle value.

## Worlds

| tag | flags |
|---|---|
| `control` | none |
| `halt2` | `HALT_IF_SAMPLE_T=2` |
| `ppu3` | `STAT_M2_LEAD=1 M3_PIPE_AHEAD=1 LY0_PIPE_MCYCLES=0` |
| `bundle` | all four |
| `bundle+DOTS4` | bundle + `CGB_HALT_PPU_LEAD_DOTS=4 SPEED_SWITCH_STALL_T=65544` |

`control` reproduces the committed `tests/results.md` exactly (981 / 769,
gambatte 3876), which is the sanity check that the harness was set up right.

## 1. Headline totals

| world | local runner | gambatte | GBMicrotest |
|---|---|---|---|
| control | **769**/981 | **3876**/5005 | **430**/513 |
| halt2 | 770 (+1) | 3878 (+2) | 434 (+4) |
| ppu3 | 776 (+7) | 3991 (+115) | 434 (+4) |
| **bundle** | **789 (+20)** | **3999 (+123)** | **440 (+10)** |
| bundle+DOTS4 | 789 (+20) | 3981 (+105) | 440 (+10) |

The bundle is worth +20 runner rows and +123 gambatte rows against main today.
The two halves are **not** additive and they are not independent: `halt2`
alone is +1 runner / +2 gambatte, `ppu3` alone is +7 / +115, and together they
are +20 / +123. The halt knob is worth 13 runner rows *only* in the presence
of the PPU trio.

Against the 2026-08-09 figures in the constants' own notes (786 / 3972 / 439),
the bundle has gained 3 runner rows and 27 gambatte rows purely from main
moving underneath it — the `--cgb-rev` work.

## 2. Every moved row, control → bundle

### FAIL → PASS (27)

| suite | rows |
|---|---|
| GBMicrotest (12) | `int_hblank_halt_scx0` ($61→$62), `_scx3` ($62→$63), `_scx4` ($62→$63), `_scx7` ($63→$64), `int_oam_incs` ($70→$6F), `int_oam_nops` ($94→$93), `lcdon_to_oam_int_l0` ($70→$6F), `_l1` ($65→$64), `_l2` ($65→$64), `oam_int_if_edge_d` ($E2→$E0), `oam_int_inc_sled` ($65→$64), `oam_int_nops_a` ($02→$01) |
| Mooneye (wilbertpol) (13) | `acceptance/gpu/hblank_ly_scx_timing-C`, `intr_2_mode0_scx{1..8}_timing_nops` (8 rows), `intr_2_mode0_timing_sprites_nops`, `..._sprites_scx{2,3,4}_nops` |
| AGE (2) | `stat-mode-sprites/stat-mode-sprites-dmgC-cgbBCE`, `stat-mode-sprites-ds-cgbBCE` |

### PASS → FAIL (10)

| suite | row | control → bundle |
|---|---|---|
| Screenshot | `strikethrough/strikethrough-dmg` | 23040/23040 → **23033**/23040 |
| Screenshot | `strikethrough/strikethrough-cgb` | 23040/23040 → **23033**/23040 |
| Screenshot | `cgb-acid-hell/cgb-acid-hell` | 23040/23040 → **23038**/23040 |
| Shootout | `daid/ppu_scanline_bgp-dmg` | 23040/23040 vs `_1.dmg.png` → 20848/23040 (90.5%) vs `_0` |
| GBMicrotest | `lcdon_to_if_oam_a` | $E0 ✓ → $E2 ✗ |
| GBMicrotest | `oam_int_if_edge_a` | $E0 ✓ → $E2 ✗ |
| Mooneye | `acceptance/ppu/hblank_ly_scx_timing-GS` | pass → fail |
| Mooneye | `misc/ppu/vblank_stat_intr-C` | pass → fail |
| Mooneye (wilbertpol) | `acceptance/gpu/hblank_ly_scx_timing-GS` | pass → fail |
| Mooneye (wilbertpol) | `misc/gpu/vblank_stat_intr-C` | pass → fail |

Net non-gambatte: AGE +2, GBMicrotest +12/−2, Mooneye −2, wilbertpol +13/−2,
Screenshot −3, Shootout −1 — **+17**.

Reconciling that with the +20 in section 1: the runner's 981 rows include the
48 gambatte *group* rows, and a group row is green only when every ROM under
it is. Three groups reach 100% in the bundle and so flip — `m2int_m3stat`
22/44 → 44/44, `m2int_m0stat` 3/6 → 6/6, `m2int_m2stat` 4/8 → 8/8. 17 + 3 = 20.

**Attribution.** Every one of the four screenshot losses belongs to the PPU
trio, not the halt knob: `halt2` holds `strikethrough-dmg`, `strikethrough-cgb`,
`cgb-acid-hell` and `daid/ppu_scanline_bgp-dmg` at 23040/23040 apiece, and
`ppu3` alone shows the identical 23033 / 23033 / 23038 / 20848 the bundle
does. Conversely all four `int_hblank_halt_scx*` gains belong to the halt
knob alone.

### gambatte groups that moved

| group | control | bundle | Δ |
|---|---|---|---|
| `window` | 293/476 | 373/476 | **+80** |
| `m2int_m3stat` | 22/44 | 44/44 | **+22** |
| `halt` | 124/158 | 136/158 | +12 |
| `speedchange` | 109/208 | 116/208 | +7 |
| `m2int_m0irq` | 45/72 | 49/72 | +4 |
| `m2int_m2stat` | 4/8 | 8/8 | +4 |
| `sprites` | 436/476 | 440/476 | +4 |
| `m2int_m0stat` | 3/6 | 6/6 | +3 |
| `dmgpalette_during_m3` | 7/17 | 9/17 | +2 |
| `lycm2int` | 10/18 | 12/18 | +2 |
| `oam_access` | 52/69 | 54/69 | +2 |
| `vram_m3` | 35/50 | 36/50 | +1 |
| `m0enable` | 153/167 | 152/167 | −1 |
| `dma` | 124/229 | 122/229 | −2 |
| `ly0` | 75/96 | 73/96 | −2 |
| `enable_display` | 135/184 | 132/184 | −3 |
| `irq_precedence` | 46/64 | 42/64 | −4 |
| `m2enable` | 94/120 | 86/120 | −8 |
| **total** | **3876** | **3999** | **+123** |

## 3. The specific gambatte rows named in the brief

**These do not move.** Byte-for-byte identical failure lines in both worlds:

| row | control | bundle |
|---|---|---|
| `halt/lycirq_m2stat_1` | pass | pass |
| `halt/lycirq_m2stat_2_dmg08_out2_cgb04c_out3` `[cgb]` | got 2, expected 3 | got 2, expected 3 |
| `halt/lycirq_m2stat_3` | pass | pass |
| `halt/m1int_ly_1` | pass | pass |
| `halt/m1int_ly_2_dmg08_out90_cgb04c_out91` `[cgb]` | got 90, expected 91 | got 90, expected 91 |
| `halt/m1int_ly_3` | pass | pass |
| `dma/hdma_late_disable_1`, `_2` | pass | pass |
| `dma/hdma_late_disable_ds_1` `[cgb]` | got 7, expected 0 | got 7, expected 0 |
| `dma/hdma_late_disable_ds_2` `[cgb]` | got 7, expected 1 | got 7, expected 1 |
| `dma/hdma_late_disable_scx5_2` `[cgb]` | got 0, expected 1 | got 0, expected 1 |
| `dma/hdma_late_disable_scx5_ds_2` `[cgb]` | got 7, expected 1 | got 7, expected 1 |

Family totals: `tima` **218/232 in both worlds — unmoved**;
`speedchange` 109/208 → **116/208 (+7)**.

So the brief's hypothesis is half right, and the half that is wrong is worth
stating plainly: the bundle does **not** touch the CGB halt-phase family. The
`lycirq_m2stat_2` / `m1int_ly_2` / `hdma_late_disable` contradiction that
`CGB_HALT_PPU_LEAD` was built for is exactly where main left it. Whatever the
bundle does for halt-adjacent rows, it does somewhere else.

## 4. Screenshot pixel counts

| row | control | halt2 | ppu3 | bundle | bundle+DOTS4 |
|---|---|---|---|---|---|
| `strikethrough-dmg` | 23040 ✓ | 23040 ✓ | 23033 | 23033 | 23033 |
| `strikethrough-cgb` | 23040 ✓ | 23040 ✓ | 23033 | 23033 | 23033 |
| `cgb-acid-hell` | 23040 ✓ | 23040 ✓ | 23038 | 23038 | **23040 ✓** |
| `acid2/dmg-acid2` | 23040 ✓ | 23040 ✓ | 23040 ✓ | 23040 ✓ | 23040 ✓ |
| `acid2/cgb-acid2` | 23040 ✓ | 23040 ✓ | 23040 ✓ | 23040 ✓ | 23040 ✓ |
| `daid/ppu_scanline_bgp-dmg` | 23040 ✓ | 23040 ✓ | 20848 | 20848 | 20848 |
| `daid/stop_instr-dmg` | 23040 ✓ | 23040 ✓ | 23040 ✓ | 23040 ✓ | 23040 ✓ |

`cgb-acid-hell` coming back to 23040/23040 in `bundle+DOTS4` is worth its own
line. The 2026-08-10 triage entry ("the write-to-fetch phase is not the answer
either") concluded that row needs **8 dots, not 4**, and that the second 4 had
no source. The bundle supplies 4 (section 5) and `CGB_HALT_PPU_LEAD_DOTS=4`
supplies the other 4. That is the first build in which both halves of
`cgb-acid-hell`'s 8 dots come from somewhere derived.

## 5. daid `ppu_scanline_bgp` on CGB — the row is EXACT in the bundle

ROM run `--cgb --color --mode=screenshot --timeout=400`, compared against
`ppu_scanline_bgp.gbc.png` at the shootout's own rule (per-pixel luma delta
≤ 50). The frame is flat horizontal bands, so a whole-frame shift is the wrong
instrument — the number that means something is the **per-band-edge offset**,
measured by pairing colour-transition columns row by row (576 of the 2130
edges are the ones that move; the rest are structure that never moves).

| world | default rev (CGB-C) | `--cgb-rev=D` |
|---|---|---|
| control | 21312/23040 (92.50%), **3 dots early** | 20736/23040 (90.00%), **4 dots early** |
| halt2 | 21312/23040 (92.50%), 3 dots early | 20736/23040 (90.00%), 4 dots early |
| **ppu3** | 22464/23040 (97.50%), **+1 dot late** | **23040/23040 (100.00%) — EXACT** |
| **bundle** | 22464/23040 (97.50%), +1 dot late | **23040/23040 (100.00%) — EXACT** |
| bundle+DOTS4 | 20160/23040 (87.50%), +5 dots late | 20736/23040 (90.00%), +4 dots late |

Control at 92.50% / 3 dots early reproduces the figure already recorded in
`build_shootout_tests` and in the triage doc, so the instrument agrees with the
existing measurement before it says anything new.

The decomposition is exact arithmetic on this row, and every cell above is
consistent with it:

* the **PPU trio is worth exactly +4 dots** (control −3 → ppu3 +1; and
  bundle+DOTS4 is +5 = +1 + 4, the double-count);
* **`--cgb-rev=D` is worth exactly −1 dot** (every rev-C cell minus one in the
  rev-D column, on all five worlds);
* `HALT_IF_SAMPLE_T=2` is worth **0 dots** here — `halt2` is bit-identical to
  `control` on this row at both revisions;
* −3 + 4 − 1 = **0**.

At `bundle` + `--cgb-rev=D` the band-edge histogram is a single bucket:
`+0 dots : 2130 edges`, 0/144 rows with a structural mismatch.

**This closes the row's open question.** The triage doc's decomposition said
daid's 3 pixels were one M-cycle at the handler's entry minus one palette dot,
and reached them with `CGB_HALT_PPU_LEAD_DOTS=4` + `CGB_MIXER_LATENCY=0`. The
same +4 dots is already inside the PPU trio, and the palette dot is now the
runtime `--cgb-rev=D`. Adding `CGB_HALT_PPU_LEAD_DOTS=4` on top of the bundle
does not improve the row, it **over-shoots it by exactly 4 dots** — which is
the cleanest available confirmation that the two knobs supply the same
quantity on this row and must not both be on.

### The daid DMG row moves the other way

`daid/ppu_scanline_bgp-dmg` is a local-runner row and it **regresses**: exact
against `ppu_scanline_bgp_1.dmg.png` (the OR-variant) in control and halt2,
20848/23040 = 90.5% against `_0` in ppu3/bundle. Same +4 dots, but DMG's
reference wants them where they already were. (The matching DMG reference
`ppu_scanline_bgp_1.dmg.png` comes from the shootout cache, not from the
scratchpad copy, which ships only the `.gbc.png`.)

## 6. The two speed_switch rows

The brief expected these to be shootout-only; they are **not**.
`daid/speed_switch_timing_div`, `_ly` and `_stat` are all local-runner rows
(`build_shootout_tests`, and they are native CGB carts, `$143 = $C0`), so no
approximation via the gambatte `speedchange` family was needed.

All three are **23040/23040 in every world measured** — control, halt2, ppu3,
bundle, bundle+DOTS4. The bundle does not move them.

For completeness the family the brief offered as a proxy did move:
gambatte `speedchange` 109/208 → 116/208 (+7).

## 7. Bucket 24 in the bundle world

The contradiction flips sides completely, and it is driven by
`HALT_IF_SAMPLE_T=2` **alone** — `ppu3` is identical to `control` on every row
below, and `halt2` is identical to `bundle`.

| row | control | halt2 | ppu3 | bundle |
|---|---|---|---|---|
| `mooneye/acceptance/ppu/hblank_ly_scx_timing-GS` | ✓ | ✗ | ✓ | **✗** |
| `mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing-GS` | ✓ | ✗ | ✓ | **✗** |
| `mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing-C` | ✗ | ✓ | ✗ | **✓** |
| `mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing_nops` | ✗ | ✗ | ✗ | ✗ |
| `mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing_variant_nops` | ✗ | ✗ | ✗ | ✗ |
| `gbmicrotest/int_hblank_halt_scx0` | ✗ $61/$62 | ✓ | ✗ | **✓ $62** |
| `gbmicrotest/int_hblank_halt_scx1` | ✓ | ✓ | ✓ | ✓ |
| `gbmicrotest/int_hblank_halt_scx2` | ✓ | ✓ | ✓ | ✓ |
| `gbmicrotest/int_hblank_halt_scx3` | ✗ $62/$63 | ✓ | ✗ | **✓ $63** |
| `gbmicrotest/int_hblank_halt_scx4` | ✗ $62/$63 | ✓ | ✗ | **✓ $63** |
| `gbmicrotest/int_hblank_halt_scx5` | ✓ | ✓ | ✓ | ✓ |
| `gbmicrotest/int_hblank_halt_scx6` | ✓ | ✓ | ✓ | ✓ |
| `gbmicrotest/int_hblank_halt_scx7` | ✗ $63/$64 | ✓ | ✗ | **✓ $64** |
| `gbmicrotest/int_hblank_nops_scx0` (the sled endpoint) | ✓ | ✓ | ✓ | ✓ |

**Standing: +5 / −2, net +3.** The bundle takes all four
`int_hblank_halt_scx*` rows plus wilbertpol's `-C`, and pays the two `-GS`
rows. `int_hblank_halt_scx{0,3,4,7}` go green at exactly the four SCX steps
the triage section predicted, and the sled endpoint `int_hblank_nops_scx0`
stays green in every world, so the halt latch moved and the non-halt path did
not. The two `_nops` variants are red in every world at either latch, as the
section already recorded.

The contradiction is **not resolved** — it is inverted. There is still no
build in which both `hblank_ly_scx_timing-GS` and `int_hblank_halt_scx0` pass.

## 8. Perf

`DINGBAT_BENCH_COUNTERS=1 DINGBAT_NO_WAITLOOP=1`, 2400 frames / 300 warmup,
retired instructions, **minimum of 3 runs**, each world with its own symlinked
ROM so no `.sav` crosses builds. `cycles=` is identical across every arm of
each table, so the arms did the same emulated work.

### Pokemon Blue (DMG, halt-heavy) — `cycles=168,515,104` in all arms

| world | retired instructions | vs control |
|---|---|---|
| control | 24,060,718,088 | — |
| ppu3 | 24,450,691,656 | **+1.62%** |
| bundle | 25,775,634,074 | **+7.13%** |

bundle vs ppu3 (i.e. the halt knob on top of the trio): **+5.42%**.

### Pokemon Crystal (CGB) — `cycles=168,537,600` in all arms

| world | retired instructions | vs control |
|---|---|---|
| control | 23,698,293,395 | — |
| ppu3 | 24,098,559,482 | **+1.69%** |
| bundle | 24,840,660,288 | **+4.82%** |

bundle vs ppu3: **+3.08%**.

The halt knob's cost is larger than the +4.79% recorded at the constant on
2026-08-09, because that figure was the knob alone; measured on top of the PPU
trio, on the same title, it is +5.42%. The PPU trio carries a real cost of its
own (~+1.6–1.7%) that had not been separated out before.

The fix path recorded at `cpu.nim:342-354` is still untried and still applies:

> most halted M-cycles cannot raise anything at all: the PPU's own idle-skip
> already knows the next dot on which something can happen, so a halted
> M-cycle that ends before it needs no split and no second call.

## 9. Combination round

The brief made this round conditional on the pure bundle leaving daid-GBC
inexact. **It does not** — `bundle` + `--cgb-rev=D` is 23040/23040 — so the
single-knob sweep over `CGB_HALT_EXIT_MCYCLES=1`, `CGB_HALT_PPU_LEAD_DOTS` at
2 and 4, and `SPEED_SWITCH_STALL_T=65544` was not the question any more.

One combination was built anyway, to test the over-shoot prediction directly:
`bundle + CGB_HALT_PPU_LEAD_DOTS=4 + SPEED_SWITCH_STALL_T=65544` (the two move
together per `memory.nim:850-851`). Result: runner 789/981 (unchanged),
gambatte **3981 (−18 against the bundle)**, GBMicrotest 440 (unchanged), daid
over-shot to +4 dots late at rev D. It buys back `cgb-acid-hell`
(23038 → 23040) and costs 18 gambatte rows and the daid row.

## 10. Minimal set for an exact daid-GBC, and what it costs

**Minimal set: `STAT_M2_LEAD=1`, `M3_PIPE_AHEAD=1`, `LY0_PIPE_MCYCLES=0`, plus
runtime `--cgb-rev=D`.** `HALT_IF_SAMPLE_T=2` is not required for this row and
neither is any of the three CGB-halt knobs.

That set (`ppu3`) costs, against control:

* local runner **776/981 (+7)**, gambatte **3991 (+115)**, GBMicrotest 434 (+4);
* the four screenshot rows: `strikethrough-dmg` and `-cgb` −7 pixels each,
  `cgb-acid-hell` −2 pixels, `daid/ppu_scanline_bgp-dmg` 23040 → 20848;
* retired instructions **+1.62%** (Pokemon Blue), **+1.69%** (Pokemon Crystal);
* bucket 24: **no change at all** — `ppu3` is identical to control on all 14
  rows in section 7.

Adding `HALT_IF_SAMPLE_T=2` on top (the full bundle) does not change the daid
row in either direction. It buys +13 runner rows, +8 gambatte, +6 GBMicrotest
and bucket 24's +5/−2 inversion, and costs a further +5.42% / +3.08% retired
instructions.

## Method notes

* **Two concurrent runner passes must not share `TMPDIR`.** `run_sharded_batch`
  puts its shard list/verdict files in `getTempDir()/dingbat-gambatte` and
  `removeDir`s it on entry, so a second world starting mid-run deletes the
  first one's shard directory and *every* gambatte row comes back "harness
  produced no verdict (crash or timeout in its shard)". That reads as a
  uniform `0/5005`, which looks like an accuracy catastrophe and is not one.
  It is the same hazard as the recorded "worktrees do not isolate /tmp" trap.
  Give each world `TMPDIR=<worktree>/.tmp/tmp-<world>`.
* Each world needs its own directory holding **both** `dingbat_test` and
  `dingbat_test_runner`, because the runner shells out to
  `getCurrentDir()/dingbat_test`.
* The daid CGB row is measured by band-edge pairing, not by best whole-frame
  shift: at 3 dots early the whole-frame metric reads 93.13% at its best shift
  against 92.50% at zero, which understates a uniform 3-dot error because
  shifting the frame also breaks the interior that already matches.
