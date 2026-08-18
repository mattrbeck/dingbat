# probe (d) — when does LCDC.4 reach the background fetcher?

**Date:** 2026-08-17. The experiment that decides the GBEmulatorShootout's
last failing row. Built as `tools/gbprobe/roms/probe_d_tdsel.asm`; four
committed builds (`probe_d_tdsel.gb`, `_scx3`, `_scx7`, `_compat`); read
with `tools/gbprobe/read_probe_d.py <frame.ppm> [--compact]`, or by eye.

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
`SCX_FINE_BORROW`), so the three SCX builds cover the 4-dot ambiguity the
CPU grid leaves — which is exactly the gap acid-hell and change2 disagree
across.

**The main builds carry the CGB flag**, unlike probe (c). Probe (c) has to
run in DMG-compatibility mode because BGP — its emission ruler — is dead in
true CGB mode; this probe reads SHADES, and `common.inc` gives CGB palette 0
the same four greys as the DMG palette, so the readout looks identical
either way. That frees the flag to match the EVIDENCE, and the evidence is
native-mode: `cgb-acid-hell` is a CGB-flagged cart that selects its CGB path
through its own `$FEA0` gate, and mealybug's `tile_sel` CGB references are
native-mode captures.

`probe_d_tdsel_compat.gb` is the same source with the flag off. dingbat
gates `CGB_TDSEL_LATENCY` on the HARDWARE being a CGB rather than on the
mode, so it predicts the same answer for both — an assumption nothing in the
tree tests, and one this build checks for free. A DMG runs every build (the
flag is ignored) and is the control.

## Registered predictions, and why this is a clean two-way test

Per band 0..15, bar shade, from the shipping tree:

| build | device | bands 0-15 |
|---|---|---|
| `probe_d_tdsel` / `_scx3` / `_scx7` / `_compat` | CGB | `#2#2#2#2#2#2#2#2` |
| `probe_d_tdsel` / `_scx3` / `_scx7` / `_compat` | DMG | `################` |

So dingbat says: **on CGB the write alternates between reaching both planes
and reaching only the HIGH plane as the offset steps one M-cycle; on DMG it
always reaches both.**

The alternation's PHASE is the measurement, and the probe was checked
against the two candidate worlds before being handed to hardware — same
ROM, dingbat rebuilt at each value:

| `CGB_TDSEL_LATENCY` | CGB reading | acid-hell | mealybug `tile_sel` ×4 |
|---|---|---|---|
| **1** (shipping) | `#2#2#2#2#2#2#2#2` | 2 px wrong | exact |
| **5** | `2#2#2#2#2#2#2#2#` | **exact** | broken |

One M-cycle of latency moves the pattern by exactly one band, and nothing
else about the frame changes — the DMG control is `################` in
both worlds. So the photograph picks a side directly: **whichever string
the hardware shows names the latency**, with no interpretation in between.
That is also the instrument's own calibration check; a probe that could not
tell the two worlds apart would be measuring something else.

## RESULT — 2026-08-17, GBA SP (photos IMG_3810-3814)

**`CGB_TDSEL_LATENCY = 1`, the shipping value, is confirmed on silicon.
Latency 5 is refuted, and with it the world that made `cgb-acid-hell`
pixel-exact.**

The cart was verified first: `probe_cart` read `00 6971 / 01 6971 /
02 6971 / 03 00 / 04 11` — all three access orders agreeing with this
tree, zero read disagreements, so the bytes reaching the CPU are the
ROM's.

All four probe (d) builds then read **`#2#2#2#2#2#2#2#2`**, matching the
shipping prediction exactly. Registration was by `photowarp.py`, and the
bars were located as blobs rather than by assuming band boundaries (a warp
a row or two out otherwise catches the neighbouring band's bar — the first
reading of IMG_3812 did exactly that and had to be discarded). Sixteen bars
per frame, on the designed 9-row pitch:

| photo | build (by bar column) | hardware | dingbat | bar column |
|---|---|---|---|---|
| IMG_3811 | `probe_d_tdsel` (SCX 0) | `#2#2#2#2#2#2#2#2` | same | 96-103 / 96-103 |
| IMG_3812 | `_scx3` | `#2#2#2#2#2#2#2#2` | same | 93-100 / 93-100 |
| IMG_3813 | `_scx7` | `#2#2#2#2#2#2#2#2` | same | 97-104 / 97-104 |
| IMG_3814 | `_compat` | `#2#2#2#2#2#2#2#2` | same | 95-102 / 96-103 |

Three things fall out, two of them new:

1. **The write-to-fetcher latency is 1**, so acid-hell's two pixels are not
   a latency error. The `latency = 5` world — the only one that made
   acid-hell exact — is dead, and the four mealybug `tile_sel` rows it
   would have cost stay green on the value silicon actually shows.
2. **The latency is not mode-dependent.** `_compat` (no CGB flag, so
   DMG-compatibility mode on the same silicon) reads identically to the
   CGB-flagged builds. dingbat gates `CGB_TDSEL_LATENCY` on the hardware
   being a CGB rather than on the mode, and nothing in the tree had ever
   tested that; it is now measured.
3. **The fetch grid's phase against the CPU is right at SCX ≡ 0, 3 and 7**
   — the bar columns match, not just the shades.

### What is left, and the next measurement

`cgb-acid-hell` runs at **SCX = 180, i.e. SCX & 7 = 4** — a fine-scroll
phase this round did not cover. The three tested phases all agree with
dingbat, so the surviving hypothesis is narrow and testable: dingbat's
fetch-grid position is wrong specifically at some fine-scroll phase, and
acid-hell sits on one of them while mealybug's `change2` does not.

`probe_d_tdsel_scx{1,2,4,5,6}.gb` complete the sweep. dingbat predicts
`#2#2#2#2#2#2#2#2` at **every** phase 0-7, so any hardware frame that
alternates the other way names the phase where the grid is off — and
SCX 4 is the one acid-hell actually uses.

## Does a cheap flash cartridge invalidate this?

Short answer: it cannot skew the measurement, only corrupt it visibly — and
`probe_cart.gb` checks for that directly.

The architectural reason is that **the Game Boy bus has no wait states**.
A cartridge cannot stretch an M-cycle; the CPU latches whatever is on the
bus when the cycle ends. So slow or marginal flash cannot move an
instruction's timing, which is the entire quantity these probes measure —
it can only return the *wrong byte*. That failure mode is loud here rather
than quiet: a wrong opcode inside the timed loop breaks the band structure
(a bar in the wrong place, or a missing blank separator line), and the
eight identical scanlines per band mean a single bad read shows up as one
odd line against seven agreeing ones, not as a shifted answer.

Audited mechanically across all five probes (`probe_a`, `probe_b`,
`probe_c`, `probe_d`, `probe_cart`) — every one is clean on each axis:

| axis | why it would matter | status |
|---|---|---|
| writes into $0000-$7FFF | a flashcart's mapper registers live there; a stray write can remap the ROM mid-measurement | **none**, direct or via HL |
| cart RAM $A000-$BFFF | save-RAM emulation is where cheap carts are flakiest | **never touched** |
| KEY1 / double speed | doubles the ROM read rate — the classic marginal-flash failure | **never entered** |
| open-bus reads | the answer is the cart's, not the console's | **none**; only ROM fetch and VRAM |
| banking | a mis-mapped bank is undetectable from inside | **no MBC** (`rgbfix -m 0x00`, 32 KiB flat) |

Two residual caveats worth knowing rather than papering over:

* If the flashcart **soft-launches from a menu** instead of hard-resetting,
  `probe_cart`'s row 04 shows the loader's A, not the boot ROM's. The other
  rows, and every measurement in probe (d), are unaffected — they set up
  their own PPU state from scratch.
* `probe_cart` proves the ROM's bytes survive sequential, reverse and
  long-jump access. A cart that fails only under some pattern it does not
  use remains possible; nothing short of a logic analyser rules that out.

Run `probe_cart.gb` first. Expected on a healthy cart, and identical on
every device (it is the same ROM):

    00 6971      forward sum
    01 6971      reverse sum
    02 6971      stride sum      <- all three MUST agree
    03 00        read disagreements: must be 00
    04 01 or 11  boot A: $01 DMG-family, $11 CGB-family

If rows 00-02 agree and row 03 is `00`, the cart is feeding the CPU
correctly and every other probe's reading stands.

## How to run it, and what each outcome decides

Flash all four builds; photograph each on the **GBA SP** (CGB silicon)
and, if available, a **CGB** and the **Game Boy Pocket** (the DMG-family
control). Run `probe_cart.gb` first (see above). One photo per build per device, screen filling the
frame. Read with `read_probe_d.py`, or straight off the photo by eye —
counting sixteen bands and noting light/dark is the whole measurement.

* **`#2#2…` — same phase as the shipping tree.** The latency is 1, and
  acid-hell's two pixels are NOT a latency error. The remaining suspect is
  the fetch grid's own position on acid-hell's line (SCX / mode-3 start),
  and the `_scx3`/`_scx7` columns say which way it is off.
* **`2#2#…` — one band out of phase.** The latency is 5, which is exactly
  what makes acid-hell pixel-exact. The four mealybug `tile_sel` rows that
  break under it are then re-derived against this measurement instead of
  against the shipping phase — the first time that family has had a ruler
  independent of itself.
* **`_compat` disagrees with the CGB-flagged builds.** The latency is
  mode-dependent, which dingbat does not model at all (it gates on the
  hardware being a CGB, not on the mode) — a finding in its own right, and
  it would mean acid-hell (native) and any compat-mode evidence must be
  fitted separately.
* **Hardware shows white bands anywhere** — the write misses the data reads
  entirely at that offset, which no dingbat build predicts, and the fetch
  cycle's shape (not its phase) is wrong.
* **DMG and CGB agree** — there is no CGB tile-select latency at all, and
  both `CGB_TDSEL_LATENCY` and the mealybug rows derived at latency 1 are
  measuring something else.

Record the readings in `docs/flashcart-runbook.md` next to the session-2
results, then re-derive `CGB_TDSEL_LATENCY` and re-run the four mealybug
`m3_lcdc_tile_sel*` CGB rows, `cgb-acid-hell`, and the shootout.
