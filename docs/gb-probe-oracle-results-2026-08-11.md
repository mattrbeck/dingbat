# The three hardware experiments, read in three emulators

**2026-08-11.** `docs/gb-failure-triage.md` ends with three experiments the
mode-3 campaign specified and could not run, because each of them needs a real
Game Boy. A flashcart is on order. This document is what the three experiments
say when the probe ROMs that were written for them are run in the three
emulators we have — dingbat, SameBoy and DocBoy — while we wait.

Read the standing of that evidence before the numbers. **SameBoy and DocBoy are
behavioural oracles.** We run a ROM in them and read the pixels out; nothing is
copied from either implementation. Three oracles agreeing is corroborating
evidence — good enough to justify building a mechanism behind a flag pending the
photograph — and it is never itself the citable derivation. Two oracles
agreeing *against* dingbat is a reason to go and look, not a reason to change
the renderer, and nothing in dingbat's renderer was changed for this document.

The probes and the harness are `tools/gbprobe/`. The ROMs report raw values and
contain no expectation anywhere; they render their results on screen as well as
to WRAM, and their cartridge headers are correct, so the identical `.gb` files
that produced every table below go to the flashcart when it arrives and
`tools/gbprobe/readout.py` reads the photograph.

---

## (a) Does the STAT mode field report differently to two read idioms?

`probe_a_statidiom.gb`. BG only, objects off, window parked, `SCY = 0`, one
halt anchor per measurement on line `$47`. Two read idioms, with their **IO
cycles equalised** — `LD A,(C)` reads on its M2 and `LDH A,($41)` on its M3, so
the `LD A,(C)` arm carries one more preceding NOP and the two sample the same
PPU dot. `SCX = 3` is the measurement, `SCX = 0` the control. The sweep is 16
M-cycle steps about the mode-0 boundary; the table is the step `N` at which
each column first reads mode 0.

| engine | model | `LD A,(C)` @3 | `LDH` @3 | `LD A,(C)` @0 | `LDH` @0 |
|---|---|---|---|---|---|
| dingbat | DMG | **0A** | 09 | 09 | 09 |
| dingbat | CGB 0 / AB / C / D / E, AGB | 09 | 09 | 09 | 09 |
| SameBoy | DMG | 09 | 09 | 09 | 09 |
| SameBoy | CGB 0 / A / C / D / E, AGB | 08 | 08 | 08 | 08 |
| DocBoy | DMG | 09 | 09 | 09 | 09 |
| DocBoy | CGB | 08 | 08 | 08 | 08 |

**The control validates the instrument.** In every row where an engine has no
per-idiom rule, the two idioms flip at the *same* step — which is exactly what
equalised IO cycles predict, and it is what would break first if the
equalisation were off by one. So the one cell that differs is a statement about
the model, not about the ROM.

**Verdict.** Two of three oracles say the idiom does **not** matter: SameBoy and
DocBoy return the same STAT byte to both instructions at every dot, on every
model. dingbat's `STAT_M0_FIELD_TAIL` shows up in exactly one cell of the whole
table — DMG, `SCX = 3` — and disappears at `SCX = 0` and on every CGB revision.

That is a narrower footprint than the rule's write-up implies, and it is the
first direct evidence that the rule is confounded rather than real: idiom and
suite are perfectly confounded in every existing test ROM (every `LD A,(C)`
witness is gambatte's, every `LDH A,($41)` witness is GBMicrotest's), and this
is the first ROM that separates them.

**What the hardware photo will settle.** If both columns flip at the same `N` on
silicon, `STAT_M0_TAIL_MAX_MC` should be deleted and the field tail with it, and
the sixty-odd rows it reconciles go back to being open. Note that this outcome
is what *both* oracles already predict.

**A second reading, free.** Both oracles put the CGB's mode-0 boundary one
M-cycle EARLIER than the DMG's (08 against 09), on the same ROM, at the same
`SCX`. dingbat puts them at the same dot. That DMG/CGB split is a separate,
cleanly bracketed question this probe answers as a by-product, and probe (b)
below reproduces it independently (flip column 3 against 4).

---

## (b) How much does a mid-line SCX store lengthen mode 3?

`probe_b_scxm3.gb`. `SCX = 7` written during mode 2 so the line latches a fine
scroll of 7. Then, from one anchor: a slide of `BASE_M + M` NOPs, the store
(`ld a,$05` / `ldh [c],a` with `C = LOW(rSCX)`), a slide, and a `LDH A,($41)`.

One refinement over the doc's sketch: the post-store slide carries a `(7 - M)`
term, so the READ lands on the same dot for every row while the STORE walks.
Without it the read would walk along with the store and the late rows would be
past the boundary before their sweep began — the top of the grid would carry no
information at all.

The table is the sweep step `N` at which each row first reads mode 0. Rows are
store positions `M = 0..7`; row `$07` is the control that stores the value SCX
**already holds**; row `none` is the control with no store at all.

`BASE_M = 16`, i.e. the store's write cycle walks dots ≈ 79 → 107:

| engine | model | M0 | M1 | M2 | M3 | M4 | M5 | M6 | M7 | ctl `$07` | none |
|---|---|---|---|---|---|---|---|---|---|---|---|
| dingbat | DMG, CGB C/D/E | 4 | 4 | 4 | 4 | 4 | 4 | 4 | 4 | 4 | 4 |
| SameBoy | DMG | 4 | 4 | 4 | 4 | 4 | 4 | 4 | 4 | 4 | 4 |
| SameBoy | CGB C/D/E | 3 | 3 | **5** | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| DocBoy | DMG | 4 | 4 | 4 | 4 | 4 | 4 | 4 | 4 | 4 | 4 |
| DocBoy | CGB | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |

The store window was then walked over the rest of the line by rebuilding at
other `BASE_M` (the read dot is held fixed automatically, see the ROM's
comment). Only SameBoy-CGB ever moves, and it moves in exactly one place:

| `BASE_M` | store write dots | SameBoy CGB C/D/E, rows M0..M7 |
|---|---|---|
| 8 | 47 → 75 | 3 3 3 3 3 3 3 3 |
| 12 | 63 → 91 | 3 3 3 3 3 3 **5** 3 |
| 16 | 79 → 107 | 3 3 **5** 3 3 3 3 3 |
| 20 | 95 → 123 | 3 3 3 3 3 3 3 3 |
| 24 | 111 → 139 | 3 3 3 3 3 3 3 3 |

`BASE_M = 12, M = 6` and `BASE_M = 16, M = 2` are the *same dot* (≈ 87). So:

**Verdict.** The extension is not a growing function of how late the store
lands. In SameBoy it is a **single one-M-cycle-wide window** at a store write
dot of ≈ 87 — the eighth dot of mode 3, i.e. the dot the seven-dot fine-scroll
discard is spent on — worth **+2 M-cycles = 8 dots**, on CGB only, identically
on revisions C, D and E, and **only when the store changes the value**: the
`$07 → $07` control never extends anything.

That 8 is inside gambatte's CGB bracket of 7–10 dots. It is *not* inside
gambatte's DMG bracket of 11–14: SameBoy's DMG extends by zero everywhere in
the swept range, as do dingbat and DocBoy on every machine. So the two rows the
campaign could not explain do not agree with each other in the oracles, and the
CGB one is the one that survives.

**What dingbat does at these points:** nothing, on any machine, at any store
position — its mode 3 is 172 + fine-scroll dots and a store does not lengthen
it. DocBoy agrees with dingbat exactly. The disagreement is one engine wide and
one dot wide, which is the smallest and most testable form this question has
ever been in.

---

## (c) acid-hell against daid, on one frame

`probe_c_arbitrate.gb` (plus `_scx3` and `_scx7`). One halt anchor at
`LY = LYC = 0`, then a loop whose body is exactly 115 M-cycles — one dot more
than a scanline — so each iteration starts four dots later in its line than the
last. Each iteration puts two features on its own line:

* one **BGP write** against a flat background, so the resulting band **edge**'s
  column reads out emission's phase — daid's ruler;
* one **LCDC.4 pulse** eight dots wide over a map whose tile index reads back
  different data in the two addressing modes, so the glitched bitplane fetch
  shows up as a column that is unambiguously the other mode's data —
  acid-hell's residue.

Two staircases descend across the frame. The measurement is not either
staircase's absolute position — both carry the halt-wake latency, which no two
engines have to share — it is the **map from one to the other within a single
frame**, which is the whole reason the two features are on one frame.

Band edge → glitch-column start, lines 2..9, `SCX = 0`:

| model | line 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|
| DMG | 5→56 | 9→56 | 13→64 | 17→64 | 21→72 | 25→72 | 29→80 | 33→80 |
| CGB-D, CGB-E, DocBoy-CGB | 9→56 | 13→64 | 17→64 | 21→72 | 25→72 | 29→80 | 33→80 | 37→88 |
| CGB-C | 10→56 | 14→64 | 18→64 | 22→72 | 26→72 | 30→80 | 34→80 | 38→88 |

**Every engine produces exactly these numbers.** dingbat, SameBoy and DocBoy
are identical, cell for cell, at every model and at `SCX = 0`, `3` and `7`
(the `SCX = 3` and `SCX = 7` frames are the `SCX = 0` frame with both staircases
shifted left by 3 and by 7 — the fetch grid and the emission grid move together
with the fine scroll, in all three engines).

**The probe's resolution is demonstrated inside its own results.** CGB-C puts
the band edge one pixel further right than CGB-D/E — 10 against 9 — with the
glitched column *unchanged* at 56. That is a one-dot separation between
emission and the fetch grid, it is revision-specific, and dingbat and SameBoy
reproduce it independently and exactly. So a four-dot separation would be
unmissable on this frame.

**Verdict.** None of the three oracles separates emission from the fetch grid
by four dots on one frame. All three place the band edge and the glitched
column on one grid, and dingbat is already in that agreement. If the hardware
photograph shows the same relationship, then acid-hell and daid cannot both be
describing this machine out of the same anchor, the 2-pixel `cgb-acid-hell`
residue is a **reference** question rather than a model one, and the renderer
should not be asked to express a split that no device produces. If the
photograph shows the two staircases four pixels apart where all three engines
put them together, then the split is real, and this frame is the derivation the
four rounds of constants could not supply.

That is the whole value of the experiment: for the first time the two sides of
the contradiction are a single measurement with a single number, and the
oracles have committed to a prediction before the answer arrives.

---

## Summary

| experiment | dingbat | SameBoy | DocBoy | what the photo decides |
|---|---|---|---|---|
| (a) idiom | idiom matters, DMG @ SCX=3 only | idiom never matters | idiom never matters | whether `STAT_M0_FIELD_TAIL` survives at all |
| (a) DMG/CGB boundary | same dot on both | CGB one M-cycle earlier | CGB one M-cycle earlier | a split dingbat does not model |
| (b) SCX extension | 0 dots always | 0 on DMG; +8 dots on CGB, one dot wide, value-dependent | 0 dots always | whether the extension exists, and whether it is a window or a ramp |
| (c) arbitration | emission and fetch on one grid | same | same | whether the 4-dot split exists at all |

Three things to carry forward whatever the photograph says. First, (a) and (b)
each hand back a **DMG/CGB boundary split** that two oracles agree on and
dingbat does not model — that is a separate, cheap, independently testable
finding. Second, (b)'s extension is now a *one-dot window*, not a ramp, which
is a far smaller thing to model than "grows with how late the store lands".
Third, (c) has been reduced from two irreconcilable reference frames to one
photograph with one number on it.

## Caveats

* Probe (c) carries **no CGB flag**, so on a CGB it runs in DMG-compatibility
  mode. This is forced, not a shortcut: BGP is the emission ruler and BGP is
  dead in true CGB mode, where colour comes from CRAM and CRAM is not writable
  during mode 3. DMG-compat is the machine `daid/ppu_scanline_bgp` itself runs
  on, so the ruler is the reference frame's ruler; but a mechanism that exists
  only in true CGB mode would be invisible to this frame.
* Probe (c)'s LCDC.4 pulse is eight dots wide, which is the shortest gap two
  2-M-cycle stores can leave, so it always redirects **both** bitplane reads of
  one fetch. A half-glitched fetch — one plane from each address — is what
  acid-hell's finest residue is about, and this ROM cannot produce one. The
  colour indices are laid out so that a half-glitch would read out as index 1 or
  2 if a machine ever produced one.
* DocBoy has no CGB revision axis (`ENABLE_CGB` is compile-time), so its CGB
  column is one number for C, D and E by construction, not by measurement.
* The DMG legs are byte-comparable across all three engines; the CGB legs are
  not, because DocBoy stores RGB565 where the other two keep RGB555. Every
  comparison above is structural — which column, which step — and none of it
  depends on a colour value.
