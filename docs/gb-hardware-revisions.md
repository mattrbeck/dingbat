# Game Boy hardware revisions in dingbat: what needs them, and the axis that
# carries them

**Date:** 2026-08-07 · **Branch:** `agent-gbmodels`, cut from `main` @ `28f4929`
· **Commit:** `a38c1be`

The premise of this round was that "this behaviour differs across revisions and
we can only model one" had blocked several clusters, and that building
multi-revision support was now allowed. It was worth building. It was **not**
the reason most of those clusters were stuck.

## The one-paragraph answer

Of the five clusters that were parked behind "it's revision-dependent", **one
genuinely is** (SameSuite's extra-length-clocking split, 5 local rows, 0
shootout rows), **three are not** (zombie mode, `channel_1_sweep_restart_2`,
the two worst mealybug DMG rows — 4 shootout rows recovered by simply modelling
the behaviour correctly), and **one is a suite-internal contradiction that no
revision can resolve** (GBMicrotest's SCX family, 20 rows, still "do not
spend"). The mechanism is built and proven, the mis-modelled behaviour is
fixed, and the honest headline is that revision support was worth **5 local
rows**, while the *investigation* that produced it was worth **4 shootout
rows** for reasons that have nothing to do with revisions.

---

# 1. The survey: what actually differs, and what it buys

## 1.1 NRx2 "zombie mode" — 4 shootout rows, and it is NOT revision-dependent

This was the flagship case. Two previous agents implemented the documented DMG
rule, measured it, and reverted it, on the strength of
`channel_1_nrx2_glitch.asm`'s own line:

> This tests the NRx2 write glitch ("Zombie Mode"). **It appears to be
> different across revisions**

That sentence is true and it is not an excuse, because the suite says which
revision it tests. `apu/README.md`, "To Do":

> The NRX2 glitch (aka "Zombie Mode") behaves differently across CPU-CGB
> revisions. **Currently, only revision E is tested and documented.**

and, in "Results":

> CPU-CGB-E – passes all tests

So the four ROMs have exactly one correct answer, it is the CGB E answer, and
CGB E is the revision dingbat is already scored against everywhere else. There
was never a second variant to model — there was one variant, modelled wrong.

**What the rule actually is.** `channel_1_volume.asm` publishes a 128-byte
`CorrectResults` table. Its subtest triggers CH1 and writes NRx2 again two
M-cycles later, sweeping `{old volume 0,1,4,7,8,10,14,15} x {old period 0,1} x
{old direction} x {new value $F0,$F1,$F8,$F9}`, and reads `PCM12` immediately —
so the volume never has time to move on its own and every byte is a direct
readout of the glitch. Solving all 128 for the increment `d` applied *before*
the `16 - volume` direction flip gives:

| old period / direction | new = dec, period 0 | new = dec, period ≠ 0 | new = inc |
|---|---|---|---|
| period 0, decrease  | 0 | **−1** | +1 |
| period ≠ 0, decrease| 0 |  0 | +2 |
| period 0, increase  | 0 | **+1** | +1 |
| period ≠ 0, increase| 0 |  0 |  0 |

The rule everyone quotes (Pan Docs, Obscure Behavior: *+1 when the old period
was zero and the envelope was still updating, else +2 when the old direction
was decrease*) is **exactly and only the right-hand column**. dingbat was
applying a third variant (`+1` in both of those cases) to all three columns.
That is why neither the old behaviour nor the documented one passes: both are
one column of a three-column table.

The other two columns are keyed on the value being **written**, which is the
part no prose source states:

* writing a *decreasing* envelope with period 0 suppresses the glitch
  completely;
* writing a *decreasing* envelope with a live period replaces it with a single
  step in the **old** direction.

`channel_1_nrx2_glitch.asm` is the independent check, not a second fit: its
second write lands 1024 M-cycles after the trigger instead of 2, and its old
periods are 2 and 7 rather than 0 and 1. All 16 of its bytes fall out of the
same three columns. Before the change dingbat's error was `+1` on exactly the
6 of 16 bytes those columns predict, in both of its 8-byte rows identically.

**Result: 144/144 bytes on both ROMs, both pulse channels. Four shootout rows**
(`samesuite/apu/channel_{1,2}/channel_{1,2}_{nrx2_glitch,volume}`), which were
967/967/5868/726 wrong pixels. `blargg/dmg_sound` and `blargg/cgb_sound` stay
12/12 and 12/12.

**Verdict: revision support buys zero rows here.** It is the right call to
*not* model the DMG or CGB ≤ D zombie variants: no ROM in any suite asserts
them, so a second variant would be unverifiable code.

## 1.2 mealybug's `DMG-CPU B` set — 0 rows, confirmed

Measured, decoding both PNGs directly (greyscale, colour type 0; cross-checked
against a `sips`-transcoded BMP path):

| test | `_dmg_blob` vs `_dmg_b` | dingbat vs `_dmg_blob` |
|---|---|---|
| `m3_lcdc_bg_en_change` | **228 px** | 2193 px |
| `m3_lcdc_win_en_change_multiple_wx` | **3 px** | 4215 px |

Exact-RGB and shootout-luma (±50) counts are identical for both pairs — every
differing pixel is a full grey-level jump, so no tolerance choice softens it.
The spread is 9.6x and 1405x smaller than dingbat's own error.

Two more facts from the same measurement, both of which tighten the negative:

* those are the **only two** `*_dmg_b.png` in the suite (73 PNGs total:
  `_cgb_c` 27, `_dmg_blob` 24, `_cgb_d` 20, `_dmg_b` 2);
* `m3_lcdc_bg_en_change`'s `_cgb_c` and `_cgb_d` references are **pixel
  identical**, and `m3_lcdc_win_en_change_multiple_wx` has no CGB reference at
  all (it is a DMG-only ROM).

So on the two tests dingbat fails worst, *every* revision mealybug shipped
agrees to within 228 px. **Do not sell revision support on these rows**, and do
not let "it's the DMG revision" survive as an explanation for them. (Revision
spread in that suite is real in general — `m3_scy_change` differs by 6217 px
between CGB C and CGB D — it is just not available here.)

## 1.3 `channel_1_sweep_restart_2` — 0 rows, and the ceiling is 3 not 2

`docs/gb-shootout-status.md` §9 prices CH1's sweep cluster at "2 reachable
rows" because SameSuite's README records CPU-CGB-D failing
`channel_1_sweep_restart_2`. The same README's next line is:

> CPU-CGB-E – passes all tests

dingbat's default revision is CGB E (see §2.3), so **all three sweep rows are
reachable on the default** and none of them is excused. The README's To Do
list confirms the intent: *"Understand why `channel_1_sweep_restart_2` fails on
SameBoy and CPU-CGB-D. Once understood, write a test ROM for CPU-CGB-D."* —
i.e. the CGB-D behaviour has no ROM yet, so there is nothing to model even if
someone wanted to.

**Settled: all three sweep rows are green on the default**, and none of them
needed a revision. `channel_1_sweep_restart_2` went 95 -> 128/128 as a side
effect of the sweep unit obeying the same reload-race rule NR13/NR14 writes
already did; see `notes/samesuite-apu.md`, "The sweep writes NR13/NR14 too".

## 1.4 SameSuite's per-revision ROMs — 5 local rows, 0 shootout rows

Nine of the 70 APU ROMs carry a revision suffix. **None of the nine is a
shootout row**, so everything here is dingbat-local (`--apu`) score. What they
are worth, measured:

### Extra length clocking — 5 rows, the real case

`channel_{1,2,4}_extra_length_clocking-cgb0B`,
`channel_3_extra_length_clocking-cgb0`, `channel_3_extra_length_clocking-cgbB`.
Their shared header states the split verbatim:

> Extra length clocking occurs when writing to NRx4 when the frame sequencer's
> next step is one that doesn't clock the length counter. In this case, if the
> length counter was PREVIOUSLY disabled and now enabled and the length counter
> is not zero, it is decremented. **On revisions <= CPU CGB B, the length
> counter only has to have been disabled before; the current length enable
> state doesn't matter.** This breaks at least one game (Prehistorik Man), and
> was fixed on CPU CGB C.

The ROMs write `NRx4 = $00` (CH3: `$03`) — bit 6 **clear** — and still expect
the counter to move. dingbat's `(not ch.length_enable) and len_enable` guard is
the CGB C+ rule and is right; the ROMs are unpassable on the default *by
construction*, and dingbat's output before this round was the exactly-correct
CGB C+ answer for all three rows of `-cgb0B`.

This is the one cluster where the mechanism pays: it is two-sided, the source
states both sides, dingbat already has one side, and the other side is a
one-term change. **4 rows land** (`channel_{1,2,4}-cgb0B` and `channel_3-cgb0`)
and the fifth is sketched in §3.2.

### `freq_change_timing` — 0 rows today, 1 row later

Three ROMs, three revisions. Their `CorrectResults` tables, decoded:

| ROM | table |
|---|---|
| `-A` (AGB) | `00 00 00 0f ff ff ff f0` |
| `-cgbDE` | `00 00 00 0f ff ff ff f0` |
| `-cgb0BC` | `00 00 00 0f **0f** ff ff f0` |

`-A` and `-cgbDE` are **identical**, and `-cgb0BC` differs in one byte, which
its own comment explains: *"Left digit: Sample right after the write. Affected
by the PCM read glitch on CGB-C and older."* So this is not three behaviours,
it is one behaviour plus the PCM12/PCM34 read glitch that `apu/README.md`
already describes as the reason most CGB ≤ C rows fail.

dingbat fails **all three**, including `-cgbDE`, which is its own default
revision. That is a plain frequency-change-timing bug in the default machine,
not a revision problem, and it has to be fixed before the revision axis can buy
the `-cgb0BC` row. Priced as: 1 default-machine bug worth 2 rows (`-A`,
`-cgbDE` share a table), then 1 more row behind the PCM read glitch (§3.3).

## 1.5 GBMicrotest's SCX family — 20 rows, and NO revision can rescue them

Confirmed at source. `tests/500-scx-timing.s` and `tests/minimal.s` carry, verbatim:

```
; ags overhead 70?
; 0 0 0 1 1 1 1 2

; dmg overhead 65
; 0 1 1 1 1 2 2 2
```

and the four scored families' `test_finish` arguments, extracted from the ROMs'
own sources:

| family | scx0..7 | delta from scx0 | which header row |
|---|---|---|---|
| `int_hblank_incs_scx*` | 61,62,62,62,62,63,63,63 | 0 1 1 1 1 2 2 2 | **DMG** |
| `int_hblank_nops_scx*` | 97,98,98,98,98,99,99,99 | 0 1 1 1 1 2 2 2 | **DMG** |
| `int_hblank_halt_scx*` | 98,98,98,99,99,99,99,100 | 0 0 0 1 1 1 1 2 | **AGS** |
| `hblank_int_scx*` | 45,45,45,·,46,46,46,47 | 0 0 0 · 1 1 1 2 | **AGS** |

Half the suite is assembled against each row of its own header, and every ROM
is built `-DDMG`. dingbat reconstructs `0 1 1 1 1 2 2 2` — the DMG row its own
header names — and the failures land exactly where the AGS row differs.

The measured cost is **larger than previously priced**, not smaller. From
`tests/results.md`:

* `int_hblank_incs_scx0..7` — **8/8 pass**
* `int_hblank_nops_scx0..7` — **8/8 pass**
* `int_hblank_halt_scx{0,3,4,7}` — 4 fail, each off by exactly **1**
* `hblank_int_scx{1,2,5,6}` — 4 fail, each off by exactly **1**
* `hblank_int_scx{1,2,5,6}_{if_d,nops_a,nops_b}` — 12 more, same 4 SCX values

That is **20 rows tracking the split**. (A further 8, `hblank_int_scx*_if_b`,
fail at *all eight* SCX values and are therefore an independent defect, not
part of this.)

**Revision support cannot buy any of them.** The only way to take those 20 is
to run half the suite as a DMG and half as an AGS, on ROMs that all declare
`-DDMG` — that is per-ROM fitting with no source behind it, and it would put
the 16 currently-green rows at risk. `docs/gb-test-suite-sources.md` §8.1's
"do not spend" verdict stands; the correction is only that the label should
read 20 rows rather than 8-12.

## 1.6 Everything else, so the survey is closed

| candidate | source | rows | needs revisions? |
|---|---|---|---|
| DMG 0 vs DMG ABC | mooneye `stat_irq_blocking.s`: "pass: DMG ABC, MGB, CGB, AGB, AGS / fail: DMG 0" | 0 — dingbat passes it | no; the axis already existed as `bmDmgABC` |
| CGB pre-D vs D+ LCD-on | mooneye `lcdon_timing-GS.s`: "CGB before D: failure / CGB D, E, AGB, AGS: different failure" | 0 scored | not until a ROM scores it |
| CGB SCY per-bitplane latch | `gb.nim` comment: "CGB-D and later use the same Y coordinate for both" | 0 | already handled by scoring against CGB C |
| CGB-only DI delay | mooneye `di_timing-GS.s`: "On CGB/GBA DI has a delay" | 0 | already keyed on `cgb_enabled` |
| CH3 wave-RAM locked write on AGB | SameSuite `channel_3_wave_ram_locked_write`: "Except on AGB, where the write is simply ignored" | 0 | a free future flag; no ROM asks |
| SGB | 3 rows outside the 261 | 0 | needs a subsystem, not a revision |

---

# 2. The design

## 2.1 A revision enum *and* behaviour flags — both, with different jobs

The two candidates in the brief are not alternatives; they are the selector and
the implementation, and the right answer is to have one of each with a single
resolution step between them.

* **`GbRevision`** is the selector. One token, orderable, matches how every
  suite in the tree already names things (mooneye `boot_regs-cgb0`, AGE
  `ei-halt-dmgC-cgbBCE`, SameSuite `-cgb0B`). A user or a test row picks one
  value and is done. Members:
  `grDmg0, grDmgABC, grMgb, grSgb, grSgb2, grCgb0, grCgbAB, grCgbC, grCgbD, grCgbE, grAgb`.
* **`GbQuirks`** is the implementation: a plain (non-`ref`) object of `bool`s on
  the `GB`, filled once by `gb_quirks_for(rev)`.

Emulation code reads flags, never the revision. Three reasons, in the order
they mattered:

1. **It documents itself at the site.** `if gb.quirks.length_clock_any_nrx4`
   reads as an assertion about hardware; `if gb.revision <= grCgbAB` reads as
   trivia, and the reader has to go and find out what CGB B did.
2. **It composes.** Two revisions that share a behaviour share a flag rather
   than repeating a set literal that will be wrong the next time a revision is
   inserted in the middle. Adding `grCgbC` between `grCgbAB` and `grCgbD` is a
   one-line change *only* because nothing compares ordinals.
3. **It is cheaper.** A flag is a load off an object the caller already
   dereferences. A revision comparison in the same place is a range check, and
   in a hot path a range check is the kind of thing that moves clang's inline
   decision (see `docs/perf-measurement-inline-cliff` territory — a one-compare
   edit to `mem_read`/`mem_write` has historically moved ~0.9% of retired
   instructions by flipping an inlining coin).

The whole revision→behaviour table is one proc, so "what is different about CGB
B" has exactly one answer to read:

```nim
proc gb_quirks_for*(rev: GbRevision): GbQuirks =
  GbQuirks(
    length_clock_any_nrx4: rev in {grCgb0, grCgbAB},
  )
```

A revision that names no flag behaves exactly like the default machine, so
adding a revision costs nothing until a test ROM proves it differs. That is the
property that makes the enum safe to fill out ahead of the evidence.

## 2.2 How it relates to `GbBootModel`: derived, not parallel

`GbBootModel` already names hardware, so a second axis naming hardware would be
a bug waiting to happen. But it is **not** a revision axis — it is a
*boot-handoff table* selector, and mooneye's own filenames prove the table is
coarser than the silicon: one `boot_regs-dmgABC` for three DMG revisions, one
`boot_regs-cgbABCDE` for five CGB revisions. Behaviour splits at CGB C
(extra length clocking), CGB D (LCD-on failure mode, SCY latching) and CGB E
(zombie mode) with *identical* handoff registers on either side.

So the resolution is: **`GbRevision` is the axis; `GbBootModel` is a function of
it.** `gb_boot_model_for(rev)` is many-to-one on purpose, and
`gb_set_revision(gb, rev)` is the only way to change the machine's identity —
it sets `revision`, derives `boot_model`, and computes `quirks` together, so
the three can never disagree. `GbBootModel` itself is untouched: renaming
`bmCgbABCDE` to something more honest would be pure churn across
`ppu.nim`/`memory.nim`/`timer.nim`/`cpu.nim` for no behaviour, and this branch
is being rebased against two other agents working in the same files.

## 2.3 Selection and the default

**Selection today is `--model=`**, unchanged in spelling and extended in
vocabulary. `gb_revision_from_name` lives in `gb.nim` (not in the harness) and
accepts the tokens the suites themselves use: `dmg0`, `mgb`, `S`, `A`, `cgb0`
(mooneye), `dmgC`/`cgbBCE` (AGE), `cgb0B`/`cgbDE`/`cgb0BC` (SameSuite). A range
token resolves to its **lowest** member, because a ROM named for a range
asserts the behaviour those revisions share and the lowest is the one no other
token also reaches.

**The default is `grCgbC` on CGB hardware and `grDmgABC` on DMG** (changed from
`grCgbE` on 2026-08-10, see below). This is not a guess — it is the revision
dingbat is *already scored against*:

* the mealybug PPU references the local runner scores are the **`_cgb_c`** set,
  and mealybug ships a `_cgb_d` set beside it that genuinely differs;
* `CGB_MIXER_LATENCY = 1` — the value that ships — is pixel-exact on
  `m3_bgp_change_cgb_c.png` and 864 pixels out on the `_cgb_d` one;
* `cgb-acid-hell`'s bundled reference is a C-class capture, and the ROM picks
  its tile data off a `$FEA0` readback that only a CGB-C answers that way;
* `docs/gb-derivations.md` has said "every reference it is scored against is
  CPU CGB C" since before this axis existed;
* mooneye `boot_regs-dmgABC` and `boot_div-dmgABCmgb` are green, and
  `stat_irq_blocking.s` reads "pass: DMG ABC … fail: DMG 0".

**Why it was `grCgbE` first, and why that is now wrong.** The original reading
was SameSuite `apu/README.md`: "CPU-CGB-E – passes all tests" (C and D do not).
That does not survive contact with the pixel references above, and it never
bound anything: SameSuite's nine per-revision APU ROMs each carry their own
`--model=` token, so they never ran on the default. The move from E to C is
behaviour-neutral by construction — both resolve to `bmCgbABCDE` and to
`length_clock_any_nrx4 = false` — and was measured to be so (§4). What it
changes is which side of the two 2026-08-10 quirks the default machine lands
on, and on both of them C is the side the references are captured from.

**Every *flag* is `false` at both defaults.** `unusable_region` is the one
member that is not a flag and not `false`: it has three states, no natural
"off", and its CGB default (`urRamMasked`) is the first thing on this axis that
a *game* could see. That was a deliberate, measured change and it is the
subject of the 2026-08-10 section of `docs/gb-failure-triage.md`.

**There is still no config field and no GUI selector, and as of 2026-08-10 that
is a harder rule than it was, not a softer one.** The original reason was that
the axis changed nothing a game could see, so a dropdown would be a knob with
no upside. That reason has now expired — the palette dot and `$FEA0` are both
game-visible — but the §2.5 blocker has correspondingly *tightened*: a state
carries no revision byte, so a config field would let a user save on one
revision and load on another with no warning and a real pixel difference
between them. **The field must not be added before the payload bump.** The
wiring, when the bump happens, is unchanged and small: one `Config` field
(`config.nim`, beside `gb_fifo`/`sgb_enable` — declaration, default, the `gb:`
parse block and the `gb:` save block) plus one `gb_set_revision` call next to
`app.gb_emu.sgb_requested` in `src/dingbat.nim`'s `load_rom`, with
`gb_revision_from_name` as the parser.

## 2.4 Cost

Resolution happens once, at construction. Nothing per-access, nothing per-frame,
no branch added to a rendering or CPU path — the two flag reads that exist are
in `write_NRx2` and the NRx4 register-write path, which run at software's
whim, not per dot. Measured in §4: at or below the measurement floor.

## 2.5 Save states

A state must record which machine produced it, and this one does not, **on
purpose and with a documented consequence**, because `GB_PAYLOAD_VERSION` is
being batched.

What the revision needs from the payload: **one byte**, `revision`, next to
`cgb_enabled` in `GB_SEC_MEM`, with older states reading back the default. On
load it would go through `gb_set_revision` so the quirks follow. That is the
whole design; it is small precisely because everything is derived.

Until the batched bump:

* `revision` and `quirks` are **not serialized**. The precedent is exact —
  `boot_model` next door is not serialized either, and never has been: both are
  construction-time properties of the *machine*, and a state is loaded into a
  machine that was already constructed.
* **What breaks:** a state saved on `--model=cgb0` and loaded by a
  default-revision process runs on a CGB E, silently. Nothing warns.
* **Blast radius today: the test harness only.** No shipping frontend can reach
  a non-default revision (§2.3 — there is no config field and no UI), and the
  harness does not save states. So the defect is currently unreachable outside
  a deliberate experiment.
* **This becomes a real bug the moment a `Config` field is added**, and the
  field must not be added before the payload bump.
* **2026-08-10 raises the stakes without changing the rule.** When this was
  written the axis was unobservable, so "a state saved on `--model=cgb0` runs
  on a CGB E" cost nothing. It now costs a pixel (the palette dot, C vs D) and
  96 bytes of `$FEA0-$FEFF`. The unserialized-field list gained both `revision`
  and `GbMemory.unusable` — see `notes/samesuite-apu.md`, which now names
  fourteen fields waiting on one bump.
* The declaration in `gb.nim` says all of this at the field, and
  `notes/samesuite-apu.md` "Unserialized state" — which already lists six
  waiting APU fields — now lists this as the seventh.

## 2.6 Testing: how the runner says "this ROM passes on revision X"

`TestDef.model` already existed and already becomes `--model=`; `mooneye_model_for`
already reads mooneye's filename suffixes and `age_device_tokens` already reads
AGE's. The only thing missing was that SameSuite's nine per-revision ROMs were
scored on the default. `samesuite_model_for` is the third instance of the same
pattern, ten lines, same shape as the other two.

Three properties this keeps, which matter more than the four rows:

* **The default revision is not the only tested one.** After this change the
  runner exercises `grCgb0`, `grCgbAB`, `grCgbC`, `grCgbD`, `grAgb`,
  `grDmg0`, `grMgb`, `grSgb`, `grSgb2` and `grCgbE` across mooneye, AGE and
  SameSuite rows.
* **A green default row would now be a bug signal.** `-cgb0B` asserts the rule
  CPU CGB C *fixed*; if it ever passes on the default, the default is wrong.
  Before this change it was simply red and looked like debt.
* **Unsuffixed ROMs are untouched.** `samesuite_model_for` returns `""` unless
  the token after the last `-` looks like a device list, so
  `channel_1_freq_change` and `div_write_trigger_10` still run on the default.

The one thing this design does **not** express is a ROM that should pass on
*several* revisions and fail on others — the runner scores each ROM once, at
one revision. Nothing in the tree needs that yet (every per-revision ROM names
a single behaviour), and the cheap extension when something does is to emit one
`TestDef` per named device, which is exactly what `build_age_tests` already
does for its screenshot rows.

---

# 3. What was built, and what was deliberately left as a sketch

## 3.1 Built

* `GbRevision`, `GbQuirks`, `gb_quirks_for`, `gb_boot_model_for`,
  `gb_set_revision`, `gb_revision_from_name` — `src/dingbat/gb/gb.nim`.
* `GB.revision` / `GB.quirks`, with the non-serialization consequence written
  at the declaration.
* One flag: `length_clock_any_nrx4`, applied in
  `src/dingbat/gb/apu/channel{1,2,3,4}.nim` as one extra term in a condition
  each.
* `--model=` in `tests/dingbat_test.nim` routed through
  `gb_revision_from_name` + `gb_set_revision` (the old boot-model-only `case`
  is gone; every string it accepted resolves to the same boot table).
* `samesuite_model_for` in `tests/dingbat_test_runner.nim`.
* The zombie-mode rule in `src/dingbat/gb/apu/abstract_channels.nim`, with the
  three-column table in the comment.

Behaviour by revision, measured on the five extra-length ROMs:

| ROM | `--model=cgb` (default) | `--model=cgb0` | `--model=cgb0B` |
|---|---|---|---|
| `channel_1_extra_length_clocking-cgb0B` | FAIL | PASS | **PASS** |
| `channel_2_extra_length_clocking-cgb0B` | FAIL | PASS | **PASS** |
| `channel_4_extra_length_clocking-cgb0B` | FAIL | PASS | **PASS** |
| `channel_3_extra_length_clocking-cgb0`  | FAIL | **PASS** | PASS |
| `channel_3_extra_length_clocking-cgbB`  | FAIL | FAIL | FAIL |

Bold is the revision the runner now selects from the filename. The default
column is all-FAIL, which is the correct answer for a CPU CGB C or later.

## 3.2 Sketched, not built: `ch3_length_clock_needs_extra_write` (CGB B)

`channel_3_extra_length_clocking-cgbB` is the fifth row and the one flag not
landed. Its header states the observable:

> On CPU CGB, CH3 requires ONE write to disable the channel when the length
> counter is 1. On CPU CGB B, CH3 requires TWO writes.

and the two `CorrectResults` tables confirm it exactly: **`-cgbB`'s row N is
`-cgb0`'s row N−1**, across all four rows. So CGB B needs precisely one more
NRx4 write than CGB 0, everywhere.

It was not implemented because the header states the *observable* and not the
*mechanism*, and two mechanisms fit this ROM identically: CH3's length counter
loading one higher on CGB B, or CH3's first extra-length clock after a trigger
being swallowed. They differ in ordinary length-counter behaviour, and nothing
in the suite discriminates them. Fitting either one to make a row green is the
failure mode `notes/samesuite-apu.md` opens by warning about
("sweeping a constant until a ROM goes green is slower AND wronger than reading
the paragraph the ROM's author wrote"). The flag slot is free whenever a second
ROM or a source sentence arrives.

Note this also means `grCgbAB` currently passes `channel_3_extra_length_clocking-cgb0`,
which a real CGB B would fail. That is the missing flag, not a mis-set revision.

## 3.3 Sketched: `pcm_read_glitch` (CGB ≤ C)

`apu/README.md`:

> A quirk in CPU-CGB revisions C and older makes registers PCM12 and PCM34
> report a glitched PCM amplitude for channels 1, 2 and 4 if they're read in
> the same M-cycle they change. **This behavior needs to be understood, tested
> and documented.**

Worth exactly **1 row** today (`channel_1_freq_change_timing-cgb0BC`), and only
after `-cgbDE` is fixed on the default. The suite's author does not know the
rule; do not invent one.

---

# 4. No regressions, and the perf cost

## 4.1 The default machine is unchanged, three ways

**Scored suites** — `./dingbat_test_runner`, full default run:

| | before | after |
|---|---|---|
| `tests/results.md` | 978 total / **700** pass | 978 total / **700** pass |
| gambatte | **3656**/5005 | **3656**/5005 |

`tests/results.md`, `tests/results_gambatte.md` and
`tests/results_mgba_suite.md` regenerate **byte-identical except their
timestamps** (the timestamp-only diffs were reverted, so the branch does not
touch them).

**Real games** — `tools/gbgate` framebuffer-hash gate, base `28f4929` vs
`a38c1be`, 1800 frames after 120 warmup, 26 ROMs (Crystal, Silver, Blue,
Shantae, four Link's Awakening builds, Kirby Tilt 'n' Tumble, Prehistorik Man,
Game Boy Camera, Super Mario Land, blargg cpu_instrs, homebrew):

```
--- 26 ROMs, tag=default, frames=1800 warmup=120 ---
IDENTICAL 26
```

**Opt-in APU suites** — `./dingbat_test_runner --apu`, and this is the gain:

| suite | before | after |
|---|---|---|
| blargg `dmg_sound` | 12/12 | 12/12 |
| blargg `cgb_sound` | 12/12 | 12/12 |
| SameSuite APU | 49/70 | **57/70** |
| total | 73/94 | **81/94** |

The eight: four zombie rows (§1.1, all four are shootout rows) and four
extra-length rows (§1.4, none of them shootout rows). No row moved backwards.

## 4.2 Perf

`DINGBAT_BENCH_COUNTERS=1 DINGBAT_NO_WAITLOOP=1`, retired instructions, 2400
frames after 300 warmup, **minimum of six interleaved runs per arm**, both arms
built by `tools/gbgate/build.sh` from `git archive` so neither can see the
other's artifacts.

| ROM | A (`28f4929`) min | B (`a38c1be`) min | delta | A's own 6-run spread |
|---|---|---|---|---|
| Pokemon Crystal (CGB) | 23,464,704,810 | 23,465,018,801 | **+0.0013%** | 0.005% |
| Shantae (CGB) | 35,452,802,363 | 35,454,092,921 | **+0.0036%** | 0.003% |
| Link's Awakening (DMG) | 23,934,129,566 | 23,934,433,225 | **+0.0013%** | 0.008% |

Emulated `cycles=` is **identical in every one of the 36 runs** per ROM-arm
pair, which is the control that says both arms did the same work. Every delta
is at or below each arm's own run-to-run spread, i.e. **not resolvable, let
alone significant**. Load average was 3.6-5.5 rather than idle (two other
agents were building), so these are upper bounds: `ri_instructions` charges
kernel work to the process and a contended run reads high.

This is the expected shape. The design's whole point is that the revision is
resolved at construction; the only per-run additions are one `bool` read in
`write_NRx2` and one in each channel's NRx4 path, neither of which is reached
more than a few thousand times a second, and the `GB` object grew by two bytes.

---

# 5. Recommendations

1. **Land the zombie fix on its own merit.** It is 4 shootout rows
   (218 → 222) and has nothing to do with revisions. If the revision axis is
   rejected, this change should still ship.
2. **Do not build any more revisions speculatively.** The enum is filled out
   because empty members are free; the flags are not, and every flag without a
   ROM behind it is unverifiable code. There are exactly two candidate flags
   left in the whole tree (§3.2, §3.3), worth 2 local rows between them.
3. **Fix `channel_1_freq_change_timing-cgbDE` before touching the PCM read
   glitch.** It fails on the default revision; that is a default-machine bug,
   and its `-A` twin shares the table so it is worth 2 rows before any revision
   work.
4. **Add `revision` to the batched GB payload bump.** One byte in
   `GB_SEC_MEM`; older states read back the default. Do not add a `Config`
   field for the revision until that bump lands.
5. **Update `docs/gb-shootout-status.md` §7 and §9.** The zombie pair is no
   longer "land it behind the SameSuite CGB-E model or not at all", and the
   sweep cluster is 3 reachable rows, not 2.
6. **Relabel GBMicrotest's SCX cluster as 20 rows, still "do not spend".**
   Revision support cannot reach them; the suite disagrees with itself.
