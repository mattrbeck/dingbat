# probe (d) — when does LCDC.4 reach the background fetcher?

**Date:** 2026-08-17. The experiment that decides the GBEmulatorShootout's
last failing row. Built as `tools/gbprobe/roms/probe_d_tdsel.asm`; three
committed builds (`probe_d_tdsel.gb`, `_scx3`, `_scx7`); read with
`tools/gbprobe/read_probe_d.py <frame.ppm> [--compact]`.

## Why it exists

`cgb-acid-hell` and mealybug's `m3_lcdc_tile_sel_change2` run the same
experiment — pulse LCDC.4 across a background bitplane fetch, photograph
which byte came back — and **dingbat cannot satisfy both**. Traced on the
shipping tree, 2026-08-17:

| ROM | map read | plane 0 | plane 1 | LCDC write |
|---|---|---|---|---|
| `m3_lcdc_tile_sel_change2` line 43 | 142 | 144 | 146 | **145** |
| `cgb-acid-hell` line 68 | 170 | 172 | 174 | **177** |

Both write on the same phase (dot ≡ 1 mod 8); their fetch grids sit **four
dots apart**. So one latency from the write to the fetcher cannot serve
both:

* `CGB_TDSEL_LATENCY = 1` (shipping): change2's write lands exactly on its
  plane-1 read — glitch, four mealybug rows pixel-exact — while acid-hell's
  lands on a **map** read, no glitch fires at all, and its two disputed
  pixels come out wrong.
* `CGB_TDSEL_LATENCY = 5`: measured this session — **acid-hell goes
  pixel-exact (0/23040 wrong)** and the four mealybug `tile_sel` CGB rows,
  two AGE rows and one gambatte row break. Net −7 rows for +1.

Neither ROM can arbitrate: each is self-consistent, and the campaign's
`CGB_TDSEL_IDX_DOTS` window (bracketed 8..15 dots) is irrelevant here — the
window never opens, because with latency 1 acid-hell's write never lands on
a data read at all. Swept 8..20 dots this session: acid-hell is 2 px wrong
at every value.

The AGS photograph of 2026-08-17 (session 2) already closed the other
escape: acid-hell's published reference **is** what silicon draws, so the
2 px are a model defect, not a reference artefact.

## What the probe measures

The latency directly, as a function a photograph can read: for a write at a
known offset, *which read of the fetch cycle comes back glitched*.

Sixteen bands, top to bottom; band k writes k M-cycles (4k dots) later than
band 0. Unlike probe (c) — whose staircase moves four dots per line and has
to be measured geometrically — the offset is held constant for **eight
identical scanlines**, then one blank line separates the bands. The answer
is a colour block eight pixels tall, so it survives a hand-held photo and
needs no registration.

The background is probe (c)'s trick: map entry `$01` everywhere, whose data
differs in every bit between the two addressing modes. So the bar's SHADE
is the reading:

| bar | index | meaning |
|---|---|---|
| white | 0 | the write missed the fetch's data reads (map read or sleep dot) |
| light | 1 | only the LOW bitplane was redirected |
| dark | 2 | only the HIGH bitplane was redirected |
| black | 3 | BOTH bitplanes came from the wrong mode |

Every band is one offset, the pattern repeats with the fetch cycle (8 dots
= 2 M-cycles), and the bar steps 4 px right per band — all three are
built-in consistency checks on the photograph.

`SCXVAL` shifts the fetch grid against the CPU's M-cycle grid (the campaign's
`SCX_FINE_BORROW`), so the three builds cover the 4-dot ambiguity the CPU
grid leaves — which is exactly the gap acid-hell and change2 disagree
across. **The cart carries no CGB flag**, like probe (c): the disputed
constant is CGB silicon in DMG-compatibility mode, which is what acid-hell
measures through its own `$FEA0` gate and what daid's frames are. The same
cart runs on a DMG for free, and that is the control.

## Registered predictions (dingbat, shipping tree, before hardware)

Per band 0..15, bar shade:

| build | device | bands 0-15 |
|---|---|---|
| `probe_d_tdsel` | CGB | `2#2#2#2#2#2#2#2#` |
| `probe_d_tdsel` | DMG | `################` |
| `probe_d_tdsel_scx3` | CGB | `2#2#2#2#2#2#2#2#` |
| `probe_d_tdsel_scx3` | DMG | `################` |
| `probe_d_tdsel_scx7` | CGB | `2#2#2#2#2#2#2#2#` |
| `probe_d_tdsel_scx7` | DMG | `################` |

So dingbat says: **on CGB the write alternates between reaching only the
HIGH plane and reaching both planes as the offset steps one M-cycle; on DMG
it always reaches both.** That DMG/CGB difference *is* `CGB_TDSEL_LATENCY`,
and the CGB alternation's phase is the quantity under test.

## How to run it, and what each outcome decides

Flash all three builds; photograph each on the **GBA SP** (CGB silicon,
compat mode) and, if available, a **CGB** and the **Game Boy Pocket** (the
DMG-family control). One photo per build per device, screen filling the
frame. Read with `read_probe_d.py`, or straight off the photo by eye —
counting sixteen bands and noting light/dark is the whole measurement.

* **Hardware alternates in the same phase as dingbat's CGB column** — the
  shipping latency is right, and acid-hell's two pixels are NOT a latency
  error. The remaining suspect is then the fetch grid's own position for
  acid-hell's line (SCX/mode-3-start), and the `_scx3`/`_scx7` columns say
  which way it is off.
* **Hardware alternates one band out of phase** — the latency is one
  M-cycle longer than shipping, i.e. `CGB_TDSEL_LATENCY = 5`, which is
  exactly what makes acid-hell pixel-exact. The four mealybug `tile_sel`
  rows that break under it are then re-derived against this measurement
  rather than against the shipping phase — the first time that family has
  had an independent ruler.
* **Hardware shows white bands anywhere** — the write misses the data reads
  entirely at that offset, which no dingbat build predicts, and the fetch
  cycle's shape (not its phase) is wrong.
* **DMG and CGB agree** — there is no CGB tile-select latency at all, and
  both `CGB_TDSEL_LATENCY` and the mealybug rows derived at latency 1 are
  measuring something else.

Record the readings in `docs/flashcart-runbook.md` next to the session-2
results, then re-derive `CGB_TDSEL_LATENCY` and re-run the four mealybug
`m3_lcdc_tile_sel*` CGB rows, `cgb-acid-hell`, and the shootout.
