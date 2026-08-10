# The GB renderer's structure, read against two other cores — 2026-08-10

Research round. No renderer code was changed. What is committed alongside this
note is four instruments under `tools/gbedge/` and the measurements below.

> **Implemented later the same day.** The design in §7 shipped, and the one
> thing §7.5 called "the whole risk" — the CGB mealybug corpus — closed
> completely. The gap was not the LY-vs-OAM-source ordering this note predicted:
> the residue was **line 0 alone**, because `LY0_PIPE_MCYCLES` is a *difference*
> between line 0 and its neighbours and was being ADDED to a term every line now
> has. Spelling it as a `max` returns the whole corpus to byte-identity.
> Final: runner 769 -> **770**, gambatte 3876 -> **3940 (+64)**, mealybug
> unmoved on both devices, daid-GBC exact. The one open item is
> `CGB_TDSEL_LATENCY`, worth 2 pixels of `cgb-acid-hell`; see the 2026-08-10
> addendum in `docs/gb-failure-triage.md` and that constant's own note.

The question this round was asked to answer:

> `daid/ppu_scanline_bgp` on CGB needs the CPU's writes to land 4 dots later
> relative to PIXEL EMISSION than dingbat has them; `hacktix/strikethrough` on
> CGB needs the OAM-DMA-vs-SPRITE-FETCH race exactly where dingbat has it;
> `cgb-acid-hell` needs the write-vs-BG-FETCH-GRID displacement at 0 or 8 dots,
> never 4. In dingbat these are ONE quantity. Hardware satisfies all three, so
> hardware's structure separates something our model fuses — *what*?

**The answer is that hardware does not separate anything our model fuses, and
neither SameBoy nor DocBoy contains the structure the question was looking
for.** Both were read in full; neither has an output stage, and in both of them
the fetcher, the FIFO, the mixer and the screen write share one counter and one
dot. What they have that dingbat has less of is a **per-register-class CPU write
arrival phase** — and dingbat already has that mechanism and already agrees with
both of them on its one measured value.

The contradiction turned out not to be structural at all. It is three
constants, two of which are *derived* rather than fitted, and the world in which
all three witnesses are simultaneously correct is built and measured in §5.
This is the cheaper world the brief asked to be told about explicitly (item 5),
and it is the finding of the round.

What the round did **not** buy is the mealybug CGB corpus, which pays 22 rows
for the pipeline advance and only partly comes back. That is the real remaining
obstacle, it is now cleanly isolated, and §7 says what it would take.

---

## 1. SameBoy's mode 3 as an architecture

Read at `LIJI32/SameBoy` @ `213a12c`. Files: `Core/display.c`, `Core/gb.h`,
`Core/memory.c`, `Core/timing.c`, `Core/sm83_cpu.c`.

### 1.1 The units

**One coroutine, one counter.** `GB_display_run()` is a computed-goto state
machine over 41 states driven by `GB_BATCHABLE_STATE_MACHINE(gb, display,
cycles, 2, !force)`. The divisor 2 means `display_cycles` counts 8 MHz ticks and
every `GB_SLEEP(gb, display, n, X)` argument is **in dots**. `cycles_for_line`
is the within-line dot index. OAM scan, sprite evaluation, sprite fetch, BG
fetcher, both FIFOs, pixel emission, STAT mode edges and LY updates are all
inlined into that one coroutine and all read that one counter.

**There is no output stage.** `render_pixel_if_possible()` pops the BG FIFO,
pops the OAM FIFO, mixes, applies the palette and stores into `gb->screen` — in
the same function, on the same dot. `lcd_x` is not a delayed `position_in_line`;
the two are incremented back to back, and `lcd_x` exists only to absorb *desync*
(its own comment: "the LCD can go out of sync since the push signal is skipped
in some cases", e.g. the DMG WX-1 case). A save-state invariant enforces
`lcd_x <= position_in_line`.

**The OAM DMA is the one genuinely separate clock.** `GB_dma_run()` is driven by
`gb->dma_cycles`, which is assigned the **CPU's un-doubled T-cycle count**
before the PPU's `cycles` is doubled for single speed, and it runs *after*
`GB_display_run()` in each `GB_advance_cycles()`. It is pulled to the PPU's
exact dot by `dma_sync()` at exactly **six call sites — three BG fetcher T2
states and three object-fetch states**. It is called from neither the OAM scan
nor from pixel emission.

**Two smaller separate phases.** The mode-2 scan evaluates object *i* at dot
`4+2i` on CGB and `6+2i` on DMG — a real 2-dot model split. And the WY
comparison is phased off its own counter `wy_check_modulo` with a per-model
constant (0 CGB, 2 DMG, 6 CGB-double), the only PPU decision in the core taken
off a counter other than the line counter.

### 1.2 The line, in dots

Dot 0 = `cycles_for_line == 0`, single speed, `s = SCX & 7`:

```
  0    2     3      4        4..82/84       84   87  89       97+s        256+s
  |    |     |      |            |           |    |   |         |           |
line  OAM   LY:=   STAT:=2   OAM scan,     STAT  pal ENGINE  PIXEL 0     PIXEL 159
start blk   line   ly_for_cmp  40 x 2 dots  :=3  blk  START  -> screen   -> screen
                   wy_check    CGB 4+2i                |                 STAT:=0 (reg)
                               DMG 6+2i                |                 IRQ @ 257+s
                                                       |
                                    mode_3_start: both FIFOs cleared,
                                    8 JUNK BG PIXELS pushed, lcd_x := 0
                                                       |
                                         +---- 8 + s dots ----+
                                         (8 junk pixels + the SCX discard)
```

Mode 2 = 80 dots, mode 3 = 172+s, line = 456. The slow FIFO path consumes
`256 − 89 = 167` dots, exactly what SameBoy's own fast whole-line renderer
charges (`167 + (SCX & 7)`) — the model closes on itself.

The **8+s dots between the engine starting and pixel 0 reaching the screen** are
the only thing in SameBoy resembling an output delay, and they are not a stage:
they are 8 junk pixels pushed at `mode_3_start` plus the SCX fractional discard.

### 1.3 Where CPU writes enter

Every PPU-visible write goes `GB_advance_cycles` (PPU catches up) →
`GB_write_memory` → `sync_ppu_if_needed` → `GB_display_sync` (defeat batching) →
store. Because the state machine returns with its counter owing a debt, "the
write happens at dot T" is exact, not approximate. What differs per register is
**how much of `pending_cycles` is advanced first**:

| arrival | registers |
|---|---|
| **t = −2** | BGP / OBP0 / OBP1, SCX (DMG and CGB-double), LCDC (DMG), BGP (CGB ≥ D) |
| t = −1 | SCY (DMG), BGP (CGB < D), the second half of the DMG palette write pair |
| **t = 0** | **BGPD/OBPD (the CGB palette RAM)**, FF46, OAM/VRAM, LCDC (CGB single) |
| **t = +1** | IF, LYC (CGB), WX (CGB) |

A 3-T-cycle spread, **palette side earliest, IRQ/LY side latest**. The author
states the reason in the source: there is an off-by-one-T-cycle error in the PPU
and the compensation is applied at the register-write boundary rather than in
the PPU. The arithmetic in §1.2 exposes the same off-by-one independently —
pixel 159 is written one dot *after* the STAT register already reads mode 0.

There is **no queue, no "apply at next pixel", and no PPU-side latency state**
for palette writes. The CGB palette RAM write converts RGB15 → host immediately.

---

## 2. DocBoy's mode 3 as an architecture

Read at `Docheinstein/docboy`. Files: `core/core.cpp`, `ppu/ppu.cpp` (3914
lines), `lcd/lcd.cpp`, `dma/dma.cpp`, `bus/oambus.tpp`, `cpu/cpu.cpp`.

### 2.1 The units

**The PPU ticks every T-cycle; 1 dot ≡ 1 T-cycle regardless of speed.** The
per-T order is CPU → PPU → LCD → HDMA → (DMA) → APU → buses. The CPU latches a
write's *address* at T0 and **commits the write at T1, before that T-cycle's PPU
tick** — so the T0 dot sees the old value and T1/T2/T3 see the new one.

**No output stage, but a row latch.** `Lcd::push_pixel()` writes an
already-palette-resolved RGB565 value into `row_pixels[row_cursor++]` on the
same dot the BG FIFO is popped. The 160-entry row is then memcpy'd into the
visible framebuffer **atomically**, when the LCD's *own* counter reaches
`row_ticks == 452`. The LCD has three counters of its own (`row`, `row_ticks`,
`frame_ticks`), `row_ticks` leads the PPU's `dots` by **+2**, and resync with
the PPU is soft — a handshake on a free-running 67488-tick frame counter. Any
*within-line* phase error is therefore invisible to a framebuffer comparison.

**Sprite hit detection is on the emission grid by construction.** `oam_entries`
is a **168-entry array indexed by `lx`**, and
`is_obj_ready_to_be_fetched() == oam_entries[lx].is_not_empty() && lcdc.obj_enable`.
Since LX = X + 8, the object trigger cannot drift from emission at all. This is
a genuinely different factoring from dingbat's (and SameBoy's) X-comparison, and
it is the strongest structural statement in either core: **DocBoy makes object
triggering definitionally in-phase with emission rather than with the dot
counter.**

**Two real anchor offsets.** The OAM scan's zero point is **dot 453 of the
previous line** (−3 dots), not dot 0. And the BG fetch grid is anchored at **dot
83**, not 80 — dots 80–82 are a fetcher-less dummy phase that also latches
`SCX % 8`. First visible pixel at dot 91.

### 2.2 Where CPU writes enter

| register | latency after the T1 commit |
|---|---|
| BGP (DMG) | **0 dots**, with a 1-dot `bgp \| last_bgp` OR glitch |
| BGP (CGB compat) | **0 dots**, no OR glitch |
| BCPD / OCPD | **0 dots**, no mode gating at all |
| LCDC bits 0–6 (DMG) | 0 dots |
| **LCDC bits 0–6 (CGB)** | **2 dots** (`pending_write.lcdc.countdown = 2`) |
| **SCX / SCY / WX (CGB)** | **2 dots** |
| SCX / SCY (DMG) | 0 dots |

### 2.3 The OAM DMA race — this *is* strikethrough

DocBoy resolves it at the **address bus**, with a comment naming the ROM:

> *"PPU does not overwrite the address in the address bus. i.e. if DMA write is
> in progress we end up reading from such address instead. [hacktix/strikethrough]"*

During the 2-dot window between the DMA's `Prepare` and `Flush`, a PPU OAM read
returns whatever the DMA has on the bus. The two PPU consumers differ, and the
asymmetry is the whole effect:

* the **OAM scan** short-circuits — if OAM is acquired by the DMA it does not
  read at all and keeps its stale latch;
* the **OBJ prefetcher** does **not** check, so it takes the hijacked address.

---

## 3. Answering the brief's question #2

> In SameBoy's and DocBoy's factoring, WHAT makes daid-GBC's writes land 4 dots
> later relative to emission while the OAM-DMA race stays put?

**Nothing does, because neither core contains the separation.** Taking the
brief's four candidate shapes in turn, against the structure rather than
against an assumption:

| candidate shape | verdict |
|---|---|
| pixel output delayed behind the fetcher by a real N-dot output stage | **Absent from both.** SameBoy: pop, mix and screen-write are one function, one dot. DocBoy: `push_pixel` is on the pop's dot; its row latch is a whole-row copy 200 dots later and is phase-invisible. |
| OAM scan / sprite fetch clocked from line start while BG fetch and emission start later on CGB | **Present but tiny and the wrong size.** SameBoy has a real DMG/CGB 2-dot split in the OAM scan's phase (object *i* at 4+2i vs 6+2i), and DocBoy anchors the OAM scan at −3 dots and the fetch grid at +83. Neither is a CGB-only 4-dot separation between the fetch grid and emission. |
| CPU-write arrival latency into palette/pipeline registers distinct from engine phase | **Present in both, and it is the real structural mechanism.** SameBoy spreads arrivals over 3 T-cycles; DocBoy gives CGB fetcher registers a 2-dot countdown and palettes zero. **Both put the palette ~2 dots ahead of the fetcher registers.** |
| mode-3 penalties accounted at different points | Not a phase mechanism in either; SameBoy's fast renderer charges a flat mode-3 length but only when nothing can observe it. |

The convergence on the third row is worth stating as a hardware claim, because
two independent codebases reached the same number with opposite sign
conventions:

> **On CGB, a write to a register the MIXER reads reaches its consumer about two
> dots earlier than a write to a register the FETCHER reads reaches its.**

dingbat already models exactly this and already agrees on the value:
`CGB_SCX_LATENCY = 2` and `CGB_SCY_LATENCY = 2` against a palette latency of 0.
So this axis is not where daid's 4 dots are hiding — dingbat is already on the
oracles' side of it.

### 3.1 What the OAM-DMA race actually measures

DocBoy's bus-arbitration model is the clearest statement of the mechanism, and
it settles what `strikethrough` is a witness *of*. The race is between the
object fetch's own OAM read dot and the DMA unit's **machine-time** bus. dingbat
models that as `OBJ_DMA_BUS_LEAD`, "M-cycles the object fetch leads the OAM DMA
unit's bus by", and that constant's own note already says what it is:

> *"That is a phase between the pipeline and the bus half of an M-cycle, and it
> is the same quantity `M3_PIPE_MCYCLES` names for the CPU... the OAM DMA unit
> writes through its own path and was never given that compensation, so the term
> is still owed here and this is where it lands."*

**A constant that is defined as the pipeline's phase against the bus cannot stay
fixed when the pipeline's phase moves.** That is the whole of §5.

---

## 4. Answering the brief's question #3 — the bisection

The cross-emulator split was: SameBoy and Emulicious pass all three; DocBoy
passes daid-GBC and strikethrough and fails only cgb-acid-hell; gambatte and BGB
pass daid-GBC and fail both others; BDM and GSE fail only strikethrough.

**What the gambatte-family cores lack** is not a phase — it is two *mechanisms*,
and the bisection separates them exactly:

* **strikethrough** needs an OAM **bus arbitration** model in which the object
  fetch's mode-3 OAM read returns the byte the DMA unit has in flight rather
  than the array's contents. A core whose mode-2 scan snapshots all four OAM
  bytes and whose mode 3 uses that snapshot cannot express it at all, because
  every object on the line would take the same DMA byte. (dingbat's own note
  records this: the scanline renderer cannot mirror it, and only a renderer with
  a dot per object fetch can.) BDM and GSE fail only this row, which is exactly
  the signature of "everything else is right, the OAM bus is not modelled".
* **cgb-acid-hell** needs a CGB LCDC.4 **mid-fetch address-decode glitch**.

**What DocBoy lacks versus SameBoy is entirely inside the second of those**, and
it isolates cleanly:

* DocBoy has no latched tile-data address. `tile_data_vram_address` is
  recomputed from scratch at *both* bitplane reads from the live
  `lcdc.bg_win_tile_data`.
* Its glitch correction is **edge-triggered on a 1-dot window** (`last_lcdc !=
  lcdc`, a strictly one-dot condition), fired only at the Low1/High1 states. A
  change landing on any other fetch phase produces no glitch at all.
* The SET branch substitutes `last_unsigned_fetch_data`, a **single global 8-bit
  latch** written indiscriminately by BG low, BG high, OBJ low and OBJ high —
  the author notes that sprite data can leak into a background fetch through it,
  and flags two of the four writers as unproven.
* The `$8800–$8FFF` guard is a hand-fitted single-bit address test, not a
  decode model.
* And **DocBoy's entire CGB tile-sel model is calibrated only against
  CGB-in-DMG-compat-mode ROMs.** Its `cgb.json` contains no mealybug entries at
  all; every `m3_lcdc_tile_sel_*` row lives in `cgb_dmg_mode.json`.

So the DocBoy-vs-SameBoy difference **does** isolate the TILE_SEL-glitch
structure from the emission-phase structure, as the brief hoped — but the
conclusion runs the other way from the hypothesis. The thing DocBoy is missing
is glitch *fidelity*, not a phase. It reaches daid-GBC and strikethrough with
the same fused one-counter engine dingbat has.

**One caution, and it is load-bearing for §7.** DocBoy disables cgb-acid-hell in
its own suite with the note *"This does not pass even on real CGB-E!"*. The
author's position is that the reference PNG and his silicon disagree. That does
not invalidate the row — dingbat is pixel-exact on it today, and mattcurrie's
capture is a real machine — but it does mean cgb-acid-hell may be a
*revision-specific* witness, and dingbat now has a runtime revision axis to hang
that on.

---

## 5. The measurement — the contradiction is three constants, not a restructure

Everything in this section is `main` built with different `{.intdefine.}`
values. No source changed. Instruments: `tools/gbedge/build-world.sh`,
`witness.sh`, `run-world.sh`, `diffshots.py`, `bandedge.py`.

The primary comparison is deliberately **world against world on the same
witness, not world against reference**: a constant that is genuinely a
compensation for a moved pipeline must return its witness to *byte identity*
with `control`, and that statement needs no reference image and no tolerance
rule to mean something.

### 5.1 The result

`control` reproduces the committed `tests/results.md` exactly (**769/981**),
which is the sanity check that the harness is set up right.

World **`M3_PIPE_AHEAD_CGB=1` + `OBJ_DMA_BUS_LEAD=2` + `CGB_TDSEL_LATENCY=5`**:

| witness | vs `control` |
|---|---|
| `strikethrough-cgb` | **byte-identical** (23040/23040) |
| `cgb-acid-hell` | **byte-identical** (23040/23040) |
| `cgb-acid2` | **byte-identical** |
| `dmg-acid2` | **byte-identical** |
| `daid/ppu_scanline_bgp` DMG | **byte-identical** (still exact vs `_1.dmg.png`) |
| `daid/ppu_scanline_bgp` CGB, `--cgb-rev=D` | **EXACT — 2130/2130 band edges at +0** |

All four CGB witnesses of the "permanent" contradiction are satisfied at once.

### 5.2 Why the two extra constants are derived, not fitted

Neither was swept in the 2026-08-10 grid, which moved `STAT_M2_LEAD`,
`LY0_PIPE_MCYCLES` and `M3_PIPE_AHEAD` only. Both follow from what the constants
*are*:

* **`OBJ_DMA_BUS_LEAD` 1 → 2.** It counts M-cycles by which the object fetch
  leads the DMA unit's machine-time bus. Advancing the CGB pipeline by one
  M-cycle moves the fetch one M-cycle earlier in machine time, so it must look
  one M-cycle further ahead to land on the same source byte. 1 + 1 = 2.
  The sign is confirmed from the other side: at 2 the DMG frame breaks by the
  same 7 pixels, because the DMG pipeline did not move.
* **`CGB_TDSEL_LATENCY` 1 → 5.** Its own note records that cgb-acid-hell writes
  LCDC every 8 dots at dot 8n+1 with the bitplane reads at 8n+0 and 8n+2.
  Advancing the pipeline 4 dots moves the write to 8n+5 on the fetch lattice;
  restoring its position on that lattice costs exactly 4. 1 + 4 = 5.

The step sizes are one M-cycle and one M-cycle. Nothing was searched.

### 5.3 What the witness table now looks like

`P` is `M3_PIPE_AHEAD_CGB` with the two compensations tracking it:

| row | control | `P=1` bare | `P=1` + both compensations |
|---|---|---|---|
| `strikethrough-cgb` | 23040 ✓ | 23033 | **23040 ✓** |
| `strikethrough-dmg` | 23040 ✓ | 23040 ✓ | 23040 ✓ *(needs the CGB gate, §6)* |
| `cgb-acid-hell` | 23040 ✓ | 23038 | **23040 ✓** |
| daid CGB `revD` | 3 dots early | **exact** | **exact** |
| daid DMG | exact | exact | exact |

The 2026-08-10 entry's "minimal contradiction, stated to be permanent" is
**not permanent**. Its two-sided bracket was real, but only for a *bare* move of
`P`: `strikethrough` and `cgb-acid-hell` are not rulers, they are single
boundary crossings inside two sub-models whose constants were fitted at `P = 0`.
That is precisely why `strikethrough`'s 7 pixels are identical at `P = 1` and
`P = 2` — the recorded "signature" of the alleged separation is in fact the
signature of a **saturated boundary crossing in a fitted compensation**.

---

## 6. What this says about the documented alternative — it is refuted

The surviving hypothesis on record was:

> The consumers may not share one phase. A world in which the OAM scan keeps
> machine time while pixel emission moves one M-cycle satisfies both.

**Two independent refutations, one from hardware references and one from the
oracles.**

**(a) From the mealybug references, using `tools/gbedge/bandedge.py`.** The
corpus is anchored on **mode 2** and contains both a family that measures
emission (`m3_bgp_change`) and a family that measures the fetch grid
(`m3_lcdc_tile_sel_change`), and both are pixel-exact today. If emission and the
fetch grid were 4 dots apart, one mode-2 anchor would have to move for one
family and not the other. It cannot. **Emission and the BG fetch grid move
together.**

**(b) From the oracles.** Neither SameBoy nor DocBoy has an output stage; both
run fetch and emission off one counter and one dot. DocBoy goes further and
keys the object trigger off `lx` itself, making it *impossible* for its sprite
machinery to leave emission's phase.

### 6.1 A third refutation, of the cheapest world, also from hardware

A CGB-only *palette-write arrival latency* would have given daid its 4 dots with
one constant and no engine motion. It is refuted directly by hardware
references, not by our model. Comparing mealybug's own captures with
`bandedge.py`:

| reference pair | band-edge offset |
|---|---|
| `m3_bgp_change` DMG blob vs CGB-C | **+0 on 240 edges, +1 on 240** |
| `m3_bgp_change_sprites` DMG blob vs CGB-C | **+0 on 1536 edges, +1 on 316** |
| `m3_bgp_change` CGB-C vs CGB-D | **−1 on all 864 edges, uniformly** |

A BGP write reaches the emitted pixel stream at the **same phase** on DMG and
CGB, to within the one dot `CGB_MIXER_LATENCY = 1` already models. There is no
4-dot CGB palette latency. The third row is a bonus: it confirms independently
that mealybug's C→D step and daid's `--cgb-rev=D` term are the same physical
quantity, one dot, in the same direction.

### 6.2 Why daid and mealybug can disagree at all, given 6.1

Because they do not share an anchor, and the ROM sources say so.

`daid/ppu_scanline_bgp.asm` takes **one** STAT LYC=0 interrupt out of `halt`,
pops its return address and never returns — it then free-runs a loop of
10×(`ld a,[hl+]` + `ld [c],a`) + 70 `nop` + `jp`, which is 114 M-cycles, exactly
one scanline, for the whole frame. It is a ruler anchored **once**, on the
LY 153 → 0 snapback's LYC edge, reached **through a HALT wake**.

`mealybug/m3_bgp_change.asm` re-anchors **every line** on a **mode-2** STAT
interrupt taken from a 1200-`nop` slide, and `reti`s back into it. It also
carries its own hardware-derived correction — `ldh a,[rLY]; and a; jr nz` with
the label immediately following, a deliberate 1-M-cycle swing whose comment
reads *"line 0 timing is different by 4 cycles"*. That is an outside
confirmation of dingbat's `LY0_PIPE_MCYCLES = 1`, measured on silicon by the
ROM's author.

So the two rows measure the same register against **different anchors**, and the
4 dots live in the anchor relationship, not in the write path.

---

## 7. The dingbat mapping, and the design

### 7.1 What is actually fused

Not "the OAM scan and pixel emission". The real fusion, in `fifo_ppu.nim`, is:

**dingbat has exactly one pipeline phase, and three separate consumers each hold
a constant that silently encodes that phase.** `fifo_pipeline_dot` ticks the
fetcher and then `tick_shifter` on the same dot; `m3_lead` delays them together;
`M3_PIPE_AHEAD` advances them together. That much is correct and the oracles
agree with it. What is *not* correct is that `OBJ_DMA_BUS_LEAD` and
`CGB_TDSEL_LATENCY` are written as free constants when each is arithmetically
`f(pipeline phase) + (a real hardware delta)`. Move the phase and they go stale,
and their witnesses go red for a reason that has nothing to do with the phase
being wrong.

That is a **bookkeeping** defect, not a structural one, and it is why every
previous sweep read the phase as two-sided.

### 7.2 The design

Not a restructure. Four changes, all local.

1. **Derive the two compensations from the phase instead of storing them.**
   Introduce the CGB pipeline advance as one named quantity — call it
   `CGB_PIPE_MCYCLES` — and express both dependants against it:
   * `OBJ_DMA_BUS_LEAD` becomes `OBJ_DMA_BUS_LEAD_BASE + CGB_PIPE_MCYCLES` on
     CGB and `OBJ_DMA_BUS_LEAD_BASE` on DMG. It is device-independent today and
     **must gain a CGB gate**: at 2 on DMG `strikethrough-dmg` breaks by the
     same 7 pixels, measured.
   * `CGB_TDSEL_LATENCY` becomes `CGB_TDSEL_LATENCY_BASE + 4·CGB_PIPE_MCYCLES`.
     It is already CGB-only by construction, so no new gate.
   Each keeps its existing sweep and derivation note; what changes is that the
   note now says which part is the phase and which part is the hardware delta.

2. **Gate `STAT_M2_LEAD` per device.** It is required to keep the mode-2-anchored
   corpus scoreable beside a moved CGB pipeline, and it is independently
   measured true on CGB by seven GBMicrotest OAM rows. Left device-independent
   it makes the DMG mode-2 families pay, which is a property of the half-applied
   gate and not of the physics.

3. **Do not add an output stage, a second dot counter, or an OAM-scan phase.**
   §6 refutes all three, twice each.

4. **Leave the register-class arrival mechanism alone.** dingbat's
   `mem_apply_pipeline` already implements SameBoy's and DocBoy's per-register
   arrival idea and already agrees with both on its one measured value
   (`CGB_SCX_LATENCY = CGB_SCY_LATENCY = 2`, palettes 0). The one gap worth
   noting for a later round is that the mechanism is *positive-delay only* —
   "a negative latency is not expressible here" — where SameBoy uses negative
   offsets freely. That is a known limit, not this round's business.

### 7.3 Every named constant, and its fate

| constant | fate |
|---|---|
| `M3_PIPE_AHEAD` | **survives**, device-independent, stays 0 |
| `M3_PIPE_AHEAD_CGB` | **becomes the axis** — renamed `CGB_PIPE_MCYCLES`, ships at 1 |
| `M3_PIPE_DELAY`, `M3_PIPE_MCYCLES`, `M3_END_EARLY` | **survive unchanged**; they are the head/tail bookkeeping and cancel exactly, as measured |
| `LY0_PIPE_MCYCLES` | **survives at 1**; independently confirmed by mealybug's own ROM comment (§6.2) |
| `OBJ_DMA_BUS_LEAD` | **re-expressed** as base + `CGB_PIPE_MCYCLES`, and **gains a device gate** |
| `CGB_TDSEL_LATENCY` | **re-expressed** as base + 4·`CGB_PIPE_MCYCLES` |
| `CGB_TDSEL_IDX_DOTS`, `CGB_TDSEL_GLITCH` | **survive unchanged** — untouched by the phase, byte-identical in every world built here |
| `MIXER_TAIL_DOTS`, `MIXER_TAIL_HBLANK`, `MIXER_PALETTE_OR`, `MIXER_DOT_LAG`, `MIXER_HEAD_LINGER` | **survive unchanged.** They are repaint *depth*, not phase; the oracles have no equivalent and nothing here moves them |
| `WIN_TAIL_FETCH`, `CGB_WIN_TAIL_LAST` | **survive unchanged** |
| `CGB_MIXER_LATENCY` | **survives at 1**, and §6.1 newly *confirms* it from the reference pair rather than from our own fit |
| `STAT_M2_LEAD` | **survives, gains a device gate** |
| `STAT_LYC_LEAD` | **stays refused** — six GBMicrotest LYC sleds, unchanged by any of this |
| `CGB_HALT_PPU_LEAD*`, `LYC_SETTLE_DOTS` | **stay where they are.** Both doors stay shut; this round does not reopen them and does not need them |

### 7.4 Predicted outcome per witness

Measured unless marked *predicted*.

| witness | prediction |
|---|---|
| daid `ppu_scanline_bgp` CGB `revD` | **exact, measured** (2130/2130 edges) |
| daid `ppu_scanline_bgp` CGB default rev | +1 dot late, measured — the row wants `revD`, as §6.1 independently confirms |
| daid `ppu_scanline_bgp` DMG | **unchanged, measured byte-identical** |
| `strikethrough-cgb` | **23040, measured byte-identical** |
| `strikethrough-dmg` | 23040 *predicted*, conditional on the `OBJ_DMA_BUS_LEAD` device gate — measured red without it, and that red is the gate's absence |
| `cgb-acid-hell` | **23040, measured byte-identical** |
| `dmg-acid2` / `cgb-acid2` | **unchanged, measured byte-identical** |
| mealybug CGB `tile_sel` ×4 + `tile_sel_win` ×2 | **the open risk.** Red in every world built here; `CGB_TDSEL_LATENCY=5` costs ~1 of them and the pipeline advance the rest |
| mealybug CGB palette rows | **the open risk**, same cause |
| mealybug DMG (whole corpus) | unchanged *predicted* — every change is CGB-gated by design |
| `lycirq_m2stat_2`, `m1int_ly_2`, `hdma_late_disable*` | **unmoved** *predicted*. The bundle measurement already showed this family is untouched by the PPU trio, and this world is a strict subset of it |
| the GBMicrotest LYC and OAM sleds | unmoved by the pipeline; `STAT_M2_LEAD`'s gate is the only thing that touches them, and it moves them the way its own seven rows want |
| gambatte totals | **not yet established** — see §8 |

### 7.5 Risk assessment

**The endangered rows, in order.**

Every world below is one build; `control` reproduces the committed results
exactly, so the columns are comparable. The two device gates the design calls
for do **not** exist yet, so the DMG side of every non-control column is paying
for their absence — see §8.

| world | flags on top of `main` | runner | gambatte | mealybug-CGB green |
|---|---|---|---|---|
| `control` | — | **769** | **3876** | **23** |
| `ahead` | `M3_PIPE_AHEAD_CGB=1` | 740 | 3773 | 1 |
| `a_d2_t5` | + `OBJ_DMA_BUS_LEAD=2` `CGB_TDSEL_LATENCY=5` | 741 | — | 1 |
| `m2_t1` | `ahead` + `OBJ_DMA=2` + `STAT_M2_LEAD=1` | 739 | — | 10 |
| `m2_t5` | `m2_t1` + `CGB_TDSEL_LATENCY=5` | 737 | 3809 | 9 |

Reading it: the pipeline advance alone costs 29 runner rows and 103 gambatte
rows; `STAT_M2_LEAD=1` buys 36 gambatte rows back and 9 mealybug-CGB rows;
`CGB_TDSEL_LATENCY=5` costs about one mealybug-CGB row and buys `cgb-acid-hell`;
`OBJ_DMA_BUS_LEAD=2` buys `strikethrough-cgb` and, ungated, costs
`strikethrough-dmg`. **The four exact witnesses are bought and the corpus is not
yet paid for.**

1. **The mealybug CGB corpus — this is the whole risk and it is not small.**
   Green mealybug-CGB rows: control **23**, pipeline advance alone **1**, with
   `STAT_M2_LEAD=1` **10**. These rows are mode-2-anchored and the pipeline moved
   under them. `STAT_M2_LEAD` is the right *kind* of compensation and recovers
   nine rows, but it does not recover them all, and there is a named reason to
   suspect it cannot in its current spelling: mealybug's handlers read `rLY`
   as their first action and derive the band's palette from it, so raising the
   OAM source across the LY increment changes the *value written*, not just its
   dot. **The next round's first job is to establish where the LY increment sits
   relative to the OAM STAT source, and to move the source without crossing it.**
2. `gambatte/scx_during_m3`, `window`, `m2int_*` — all mode-2 or SCX anchored,
   all plausible collateral of the same anchor question. Not yet measured here.
3. `strikethrough-dmg` — only endangered by forgetting the device gate, and it
   fails loudly if forgotten.

**What is demonstrably safe:** both acid2 frames, both daid frames, both
strikethrough frames and cgb-acid-hell are byte-identical or exact in the
measured world, and `CGB_TDSEL_IDX_DOTS` / `CGB_TDSEL_GLITCH` never moved.

### 7.6 The verification ladder for an implementation round

1. `tools/gbedge/witness.sh` on the new build — all seven frames byte-identical
   to `control` except daid-CGB, which must be exact against
   `ppu_scanline_bgp.gbc.png` at `--cgb-rev=D` via `bandedge.py`. Cheap, seconds.
2. `-d:gb_m3_len` over the mealybug, `sprites`, `window`, `scx_during_m3`,
   `m0enable`, `vram_m3` and `oam_access` corpora, both devices, byte-compared
   against `control`. Mode 3's length must not move by a dot on DMG at all, and
   on CGB it must move only where the advance is paid back.
3. The **DMG** half of the local runner must be bit-identical to `control`.
   Everything in the design is CGB-gated; any DMG movement is a missing gate.
4. Full local runner + gambatte + GBMicrotest, against §7.4.
5. The mealybug CGB corpus, row by row, against the 23 baseline — the gate on
   whether the round ships at all.
6. Retired instructions on Pokemon Crystal. The bundle measured the PPU trio at
   ~+1.7%; this world is a strict subset of it and should cost less, but it must
   be measured, not assumed.

---

## 8. What was NOT established

Stated plainly so the next round does not assume it.

* **The totals for the winning world.** No world built here has the two device
  gates the design calls for, so every non-control total in §7.5 measures the
  *missing gates* as much as the physics — `STAT_M2_LEAD` ungated makes the DMG
  mode-2 families pay in full, which is most of the gambatte deficit. Those
  numbers are attribution, not a verdict. **On the evidence in hand this design
  buys four exact CGB witnesses and currently costs more than it buys**, and it
  should not ship until §7.5's first item is settled.
* **Whether the mealybug CGB corpus can be fully recovered.** §7.5 names the
  suspected obstacle and the experiment. Until that is answered this design is
  a strong hypothesis with four exact witnesses, not a shippable change.
* **Whether cgb-acid-hell is revision-specific.** DocBoy's author says it fails
  on his CGB-E. dingbat now has a runtime revision axis; nobody has asked this
  ROM which revision it is.
* The two other CGB structural details found in the oracles and absent here —
  SameBoy's DMG/CGB 2-dot OAM-scan phase split, and its CGB-only fetcher-abort
  path on a mid-fetch window disable (already named in `CGB_LCDC_LATENCY`'s note
  as the missing piece worth ~10 gambatte rows). Both are independent of this
  round and both are now sourced.

## 9. Instruments committed

| tool | what it does |
|---|---|
| `tools/gbedge/build-world.sh` | builds one `{.intdefine.}` world into `.worlds/<tag>/`, holding both binaries, with its own `TMPDIR`; `NORUNNER=1` builds the driver only |
| `tools/gbedge/witness.sh` | captures the seven screenshot witnesses of this axis from one world |
| `tools/gbedge/run-world.sh` | a full local-runner pass for one world, isolated `TMPDIR` |
| `tools/gbedge/diffshots.py` | world-against-world pixel diff of captured frames — the byte-identity test §5 rests on |
| `tools/gbedge/bandedge.py` | per-row colour-transition column pairing between two frames (PNG incl. sub-byte palette depths, or PPM). The right instrument for banded frames, where a whole-frame shift metric understates a uniform dot error |
