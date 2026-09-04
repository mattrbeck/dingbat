# GBA probe pages v7 — OBJBUDGET, OBJGEOM, DMAOPENBUS, PSGBIAS

Four probes for the four open GBA rows in `docs/hwprobe-questions.md`
("Probe ROMs still to write"). Three are new `gbaedge.gba` pages (37-39);
the fourth is a separate audio ROM, `psgbias.gba`, that is photographed
**and recorded**.

Nothing here encodes an expected value. "dingbat predicts" below is what
the emulator produces today (captured with `hwprobe_capture.py`, see
`expected/predicted-2026-09/`) — it is the hypothesis on trial, not the
answer key.

## Build

```
python3 tests/roms/gbaedge.py     # -> gbaedge.gba, gbaedge-auto.gba (40 pages)
python3 tests/roms/psgbias.py     # -> psgbias.gba, psgbias-auto.gba
```
Both need `arm-none-eabi-{as,ld,objcopy}` (Homebrew). Flash the **manual**
builds; the `-auto` ones are for the emulator-side capture.

Landing on a visual page repaints it under forced blank, which takes a
little over one frame: the screen flashes white. Photograph a settled
page, not the flash — and the capture script below deliberately shoots
12 frames into each page's window for the same reason.

Capture dingbat's own prediction of every page:

```
python3 tests/roms/hwprobe_capture.py ./dingbat_test \
        tests/roms/gbaedge-auto.gba tests/roms/expected/predicted-2026-09
```
It writes `pNN.ppm` + `pNN.png` per page and a `pages.txt` in
`hwprobe_expected.py`'s transcription format (visual pages get a
`visual` line and their picture). It finds the viewer's start frame
itself and walks page by page, so a ROM whose boot probes get slower does
not need the frame numbers re-derived.

## Slots did not move

Pages 0-36 are byte-identical to the session-4 build: the v7 probes hang
off a single `bl probe_tail` at the end of `main`'s probe list, all their
code sits *after* the data block, and the boot-time slot-clearing loop
still zeroes exactly 37 slots (the v7 slots are cleared inside
`probe_tail`, so the frame phase PPUSTAT/IRQLAT sample is unchanged).
Verified by capturing the session-4 binary and this one through the same
harness and diffing: all 37 old pages (`00`-`24` hex) identical, every
per-page CRC unchanged. `hwprobe_expected.py` also still re-renders
`expected/agb-sp-{1,2,3,4}/` to byte-identical PNGs with the grown
`PAGES` list.

`ALL` for the v7 build was **F1AF** (manual) / **38FC** (`-auto`); the two
binaries differ in a few pipeline/open-bus bytes, as they always have.
(v8 adds ten slots and moves both — see the v8 section below. The v7
per-page CRCs in this section are still current; only `ALL` changed.)

**`ALL` moves**, as it did at every earlier version bump: it is the CRC
over every slot and there are three more. Hardware transcriptions of
pages 0-36 (`expected/agb-sp-*.txt`) stay valid page by page; only the
`ALL` line differs from a v7 photograph.

---

## Page 37 OBJBUDGET (visual)

**Photograph** the whole screen on the OBJBUDGET page. Three bands, each
"FILL block | TEST sprite | NEXT sprite", with a 0-7 ruler under each
TEST sprite (one digit per 8-pixel group of the sprite).

* Band A (top, y=16): 18 identical 64-wide grey sprites, then TEST, then
  NEXT. 18x64 = 1152 of the 1210 per-line OBJ cycles, so TEST starts with
  58 cycles left. TEST's top half is a repeating 8-colour ramp (black,
  red, blue, green, yellow, magenta, cyan, grey), its bottom half solid
  black.
* Band B (middle, y=56): the same, TEST horizontally flipped.
* Band C (bottom, y=96): control — one filler, so everything fits.

**What each outcome means**

| picture | conclusion |
|---|---|
| TEST complete, NEXT missing (bands A/B) | the sprite that exhausts the budget still draws in full; the budget is only checked *between* OAM entries |
| TEST cut partway, NEXT missing | hardware truncates mid-sprite. The cut column (read off the ruler + the ramp colour) **is** the budget left, so it measures the 1210 constant directly: cut at column 58 confirms 1210, any other column pins a different number |
| TEST and NEXT both complete | there is no per-line budget at this load |
| band B cut on the opposite side from band A | the truncation follows the *texture*, not screen order |

Band C must show a complete TEST and NEXT whatever happens; if it does
not, the page is measuring something else.

**Constant pinned** `src/dingbat/gba/ppu.nim`, `render_sprites_impl`:
`obj_cycles = if hblank_interval_free: 954 else: 1210`, and the comment
"The sprite that exhausts the budget still draws fully: Assumed;
hardware likely truncates it".

**dingbat predicts** (verified on `expected/predicted-2026-09/p37.png`)
bands A and B: the grey filler block, TEST drawn **complete** — all eight
ramp colours across all 64 columns, top half ramp, bottom half black —
and **NEXT absent**. Band B's TEST is the ramp reversed (grey, cyan,
magenta, yellow, green, blue, red, black). Band C: filler, complete TEST
and the blue NEXT. So dingbat says "the exhausting sprite draws fully",
and a hardware photo that cuts TEST short refutes it.

## Page 38 OBJGEOM (visual)

**Photograph** the whole screen. Five groups, each labelled:

* `X504-511` — eight 8x8 sprites at X = 504..511 (screen x = -8..-1),
  one per row band. Under the signed reading, sprite k shows its
  rightmost k columns against the left screen edge: a staircase, nothing
  for k=0. Any other pattern (all eight fully visible at the right edge,
  say) means X is not sign-extended at 9 bits.
* `Y248-255` — eight 8x8 sprites at Y = 248..255, X stepping right.
  Same staircase, at the top edge.
* `Y200` — a 32x64 sprite at Y=200 whose texture rows 56-63 are yellow:
  the yellow strip must appear at screen rows 0-7 under *both* the
  "y -= 256" and the "mod 256" readings. It is the control that says the
  page's sprites are drawing at all.
* `Y130 DBL` — a 32x64 texture in a 64x128 affine double-size box at
  Y=130 (2x scale). Texture rows 0-15 cyan, 16-47 black, 48-63 green.
  The box spans lines 130..257:
  | picture | conclusion |
  |---|---|
  | cyan at rows 130-159, nothing at the top | `y > 159 -> y - 256` (dingbat) |
  | cyan at 130-159 **and** green at rows 0-1 | the box wraps: `(line - Y) mod 256` |
  | green at rows 0-1 only | GBATEK's "a 128-tall OBJ at Y>128 is treated as Y>-128" taken literally |
* `T1020` — a 16x32 8bpp sprite named tile 1020, at X=192, Y=40. Its
  first two tile rows (screen rows 40-55) are yellow and sit in the last
  256 bytes of OBJ VRAM; rows 56-71 address 0x8000-0x80FF, past the 32K
  end. The legend swatches say what those rows came from:
  | rows 56-71 | conclusion |
  |---|---|
  | green (`T0`) | the fetch wraps within OBJ VRAM (`and 0x7FFF`) |
  | red (`B0`) | it ran on into the first 4K of BG VRAM |
  | blue (`BL`) | into the last 4K of BG VRAM |
  | magenta (`BM`) | into BG VRAM somewhere else |
  | white / nothing | the fetch is suppressed (transparent) |
  (BG VRAM is pre-filled with those palette indices; the BG0 font and map
  occupy 0x8000-0xC7FF, so a fetch landing *there* shows glyph noise
  rather than a flat colour — also an answer.)

**Constant pinned** `ppu.nim` `obj_geometry` ("The exact thresholds
(X>239, Y>159) are assumed") and `render_sprites_impl`'s "OBJ character
fetches wrap within the 32K of OBJ VRAM. Assumed; no ROM pins this."

**dingbat predicts** (verified on `expected/predicted-2026-09/p38.png`)
both staircases present and exactly k pixels wide/tall for X=504+k /
Y=248+k (so k=1 is a single pixel column — photograph close);
the Y200 yellow strip at rows 0-7; `Y130 DBL` cyan at rows 130-159 with
nothing at the top of the screen; `T1020` yellow at rows 40-55 and
**green** at rows 56-71, i.e. the fetch wrapped to OBJ tile 0.

## Page 39 DMAOPENBUS (hex)

**Photograph** the page. A DMA0 burst moves 4 words EWRAM->EWRAM, the
last one `C0FFEE42`; stubs running from IWRAM then read the unmapped
`0x10000000` at known instruction distances behind the enabling store.
All stubs are 32-bit IWRAM code, so the spacing is exact (cycle counts
are in the source comment).

| offset | read |
|---|---|
| +0 / +4 / +8 / +12 | four back-to-back `ldr`s after the enable (data cycles t0+2, +5, +8, +11) |
| +16 / +20 | the same with one `nop` first (t0+3, t0+6) |
| +24 / +28 | the two words a **DMA3 whose source is `0x10000000`** wrote, enabled by the instruction right after DMA0's enable. DMA3's own latch is primed with `A5A5A5A5` first |

**What each outcome means** `C0FFEE42` = the last DMA word was still on
the bus for that read. An ARM instruction encoding (`E5953000` =
`ldr r3,[r5]`, `E886020E` = the stub's `stmia`, `E12FFF1E` = `bx lr`) =
the latch was gone and the read fell back to the prefetched opcode. The
**number of `C0FFEE42`s** is the window length in instructions.
On +24/+28: `C0FFEE42` = the DMA engine reads the shared bus latch;
`A5A5A5A5` = each channel repeats its own last word; `00000000` = an
unmapped DMA read delivers zero.

**Constant pinned** `src/dingbat/gba/bus.nim` `read_open_bus_value` —
"The exact window — the DMA's own reads plus exactly one CPU instruction
after the burst — is Assumed; no ROM pins its length."

**dingbat predicts** page CRC **8A4F**:

```
00 30 95 E5  42 EE FF C0  0E 02 86 E8  1E FF 2F E1
42 EE FF C0  1E FF 2F E1  A5 A5 A5 A5  A5 A5 A5 A5
```

read #1 = `E5953000` (the prefetched `ldr r3,[r5]`), read #2 =
`C0FFEE42`, reads #3/#4 = prefetched opcodes; with the `nop` first,
read #1 = `C0FFEE42` and #2 = prefetch. So dingbat's window covers
exactly one read, and *which* read it is moves with the instruction
spacing — a one-instruction window anchored on the burst's end, not on
the enabling store. On the DMA3 row dingbat answers `A5A5A5A5` twice:
each channel repeats **its own** last word, not the bus's. That is the
row most likely to be wrong.

---

## PSGBIAS — the audio probe (separate ROM)

`psgbias.gba` plays one tone per STEP and shows the step in 4x glyphs, so
a photo of the screen names the segment in the recording. **A** = next
step, **B** = previous, **START** = replay. Every step opens with 15
frames of silence: that gap is the segment delimiter in the recording.

| step | screen | what it is |
|---|---|---|
| 0 | `PSG V2` | ch1 square 440 Hz, envelope 15, SOUNDCNT_H PSG volume 2 (GBATEK 100%) — the reference level |
| 1 | `PSG V3` | PSG volume **3**, the "prohibited" value |
| 2 | `PSG V1` | 50% |
| 3 | `PSG V0` | 25% |
| 4-7 | `DS SQ` + `BIAS R0..R3` | DirectSound A, full-scale square (+127/-128) at 18157.6 Hz, SOUNDBIAS amplitude resolution 0,1,2,3 |
| 8-11 | `DS TRI` + `BIAS R0..R3` | the same with a small triangle (±16 LSB, 141.9 Hz): the resolution mask turns it into a visible staircase whose step count is the mask depth |

DirectSound plumbing: timer 0 at 924 cycles/sample, FIFO A fed by DMA1
from EWRAM; the whole 256K of EWRAM holds the waveform and the DMA walks
the EWRAM mirrors, so a step runs ~15 minutes without re-arming and the
stream has no seams.

### Recording procedure

1. Flash `psgbias.gba`. Headphone/line-out from the GBA into a laptop
   input; set the console volume wheel to **maximum** and **do not touch
   it again** — every step is compared to step 0.
2. Record one continuous take. Start recording, power on, wait for the
   first tone.
3. Walk the steps in order with **A**, about 5 s each; photograph the
   screen at least once per step (the screen names the step, and the
   silence gaps delimit them). 12 steps, roughly one minute.
4. Steps 4-11 are quiet-ish square/triangle tones; do not adjust the
   input gain mid-take. If the input clips on step 4, restart the take
   with lower gain rather than changing it later.
5. Keep the take, the photos, and the console/flashcart names together.

### What the recording answers

* **How many tones are in the take?** 11 (step 1 silent) or 12. That
  single count answers the volume-3 question before any level is measured.
* **Does PSG volume 3 mute?** Compare step 1's level with steps 0/2/3.
  Silence = mute. Equal to step 0 = it behaves as 100%. Anything else
  (e.g. 4x step 3) is a fourth level nobody has documented.
  Constant pinned: `src/dingbat/gba/apu.nim` — "Value 3 is modelled as
  silence: Assumed (prohibited value)" (`psg_muted`).
* **What are 0/1/2 worth?** Steps 3, 2, 0 should sit 6 dB apart if
  25/50/100% is right.
* **How deep is the SOUNDBIAS resolution mask?** In steps 8-11 count the
  staircase steps in the triangle: the level count halves per resolution
  step if the mask is 1/2/3 bits. Constant pinned: `apu.nim`'s `dac_mask`
  — "the model keeps one more bit than the table at each step. Assumed
  (inaudible)". Steps 4-7 answer the same question coarsely (the square's
  edges) and also show whether hardware clips a full-scale DirectSound
  tone.

### dingbat predicts

Full table with the measurement method:
`expected/predicted-2026-09/psgbias-audio.txt`, produced by

```
DINGBAT_GBA_AUDIO_DUMP=/tmp/psg.s16 ./dingbat_test tests/roms/psgbias-auto.gba \
    --mode=screenshot --color --timeout=2200 --screenshot=/tmp/psg.ppm
```

(left channel, s16le 32768 Hz; segments cut on the silence gaps, middle
60% of each measured).

| step | dingbat |
|---|---|
| 0 `PSG V2` | RMS 105, square ±105 |
| 1 `PSG V3` | **silent — no segment at all** |
| 2 `PSG V1` | RMS 52 (half of step 0) |
| 3 `PSG V0` | RMS 26 (quarter) |
| 4-7 `DS SQ R0..R3` | RMS 402/402/402/400; **asymmetric**, +658 against -256; 49/47/40/38 distinct levels |
| 8-11 `DS TRI R0..R3` | RMS 36 throughout; distinct levels 64/64/32/16 — the mask only bites at R2 and R3 |

**Count the tone segments first.** dingbat produces **11 tones for 12
steps** because it mutes volume 3; 12 tones on hardware refutes that
outright and re-aligns everything after step 1.

Two dingbat-side notes for the comparison: the negative half of the
full-scale square clips at -256 because `dma_channels.nim` scales a FIFO
byte `shl 1` before the SOUNDCNT_H volume shift (a symmetric hardware
recording would say that scaling is 2x too large), and the FIFO cubic
interpolation smooths the staircase, so dingbat's level counts are a
lower bound on how visible the mask is.

The `-auto` build's step period drifts a frame or two per step (a redraw
outlasts a frame), so segment on the silence gaps rather than on frame
numbers — which is what the hardware recording needs anyway.

---

# GBA probe pages v8 — the nine remaining open rows

Ten new `gbaedge.gba` pages (40-49) close the nine GBA rows still marked
**open** in `docs/hwprobe-questions.md` (the timer/PSG row needs two
pages), plus two "Assumed" comments in the emulator that no ROM pinned.
All ten are hex pages: photograph the 32-byte slot.

The same rule as always: nothing here encodes an expected value.
"dingbat predicts" is what the emulator produces today, captured with
`hwprobe_capture.py` into `expected/predicted-2026-09/`. It is the
hypothesis on trial.

## Build

```
python3 tests/roms/gbaedge.py     # -> gbaedge.gba, gbaedge-auto.gba (50 pages)
```
(needs `arm-none-eabi-{as,ld,objcopy}` on PATH, and `gbafix` from
`/opt/devkitpro/tools/bin` for the header logo). Flash the **manual**
build; `-auto` is for the emulator-side capture.

## Slots did not move

Pages 0-39 are byte-identical to the v7 build. The v8 probes hang off a
single `bl probe_tail3` at the very end of `probe_tail`, all their code
sits after everything v1-v7 assembles, and they clear their own slots
(40-49) themselves, so neither the boot-time zeroing loop nor the frame
phase that PPUSTAT/IRQLAT sample changes. Verified by capturing the v7
binary and this one through `hwprobe_capture.py` and diffing the two
`pages.txt`: all 40 old pages identical, every per-page CRC unchanged.

**`ALL` moves**, as at every version bump: it is the CRC over every slot
and there are ten more. `ALL` for this build is **5060** (manual) /
**BA6C** (`-auto`, HLE BIOS) / **53C7** (`-auto`, real BIOS). Per-page
hardware transcriptions in `expected/agb-sp-*.txt` stay valid page by
page; only their `ALL` line differs from a v8 photograph.

Two of the new pages measure phase against free-running clocks and are
**not reproducible run to run** — TIMPHASE (43) and PSGPHASE (44) shift
with the absolute cycle at which the boot probes reach them, and IWCYCLE
(47) drifts a few cycles for the same reason. Their CRCs are not a gate;
read their shape.

## Holding SELECT at power-on

Page 49 (UNDMODE) deliberately writes an undefined CPSR mode number. If a
console wedges there it never reaches the viewer and *no* page can be
read. **Hold SELECT while powering on** to skip that page: its slot then
reads `99` at +0 and `EE` at +31 and every other page runs normally. Do
one normal run and one SELECT-held run if the console survives; do the
SELECT-held run first if you would rather not risk the session.

---

## Page 40 IRQDECOMP (hex)

**Photograph** the page. Eleven interrupt-latency rows plus an eight-step
acknowledge race.

The page installs **its own interrupt handler** for its duration (the
shared `irq_handler` leaves the source running, and a TM2 reload of
`FFF0` re-overflows every 16 cycles — faster than the BIOS dispatcher can
return — so the console makes no forward progress at all). It stamps TM0
in its first two instructions, exactly as `irq_handler` does, then kills
IME and TM2 so each row takes exactly one interrupt.

Each latency row is `(the handler's TM0 entry stamp) - (a TM0 stamp taken
by the instruction immediately before the arming store)`. Every row pays
the same fixed cost — BIOS dispatch, pipeline refill, the handler's own
two instructions — so the **differences between rows** are the pipeline
being decomposed, and no row is a number to match on its own.

| offset | row |
|---|---|
| +0 | TM2 reload `FFF0`, one 32-bit CNT write, CPU running |
| +2 | the same armed as two halfword writes (CNT_L reload, then CNT_H) |
| +4 | TM2 reload `0000` | 
| +6 | TM2 reload `0001` |
| +8 | TM2 reload `FFF0`, then HALTCNT two instructions later |
| +10 / +12 | hblank, running / halted |
| +14 / +16 | vblank, running / halted |
| +18 / +20 | DMA3 complete, running / halted |
| +22..+29 | IF low byte read one instruction after `strh 0xFFFF,[IF]`, at eight spacings across a TM2 overflow |
| +30 | progress marker (`FF` = the page finished) |
| +31 | rows whose interrupt never arrived |

TM2 runs at prescaler 1, so the reload states the delay exactly: `FFF0`
overflows 16 ticks after the enable, `0000` 65536 ticks (TM0 wraps in the
same 65536, so the mod-2^16 delta *is* the latency) and `0001` one tick
sooner again. The hblank and vblank rows are anchored — IME off while the
code waits for the hblank flag to fall or for VCOUNT 158, IF acked, TM0
stamped, and then the **IME write is the arming store** — so an hblank
row is ~1006 cycles plus latency and a vblank row two lines plus latency.

**What each outcome pins**

* `+2 - +0` non-zero: the reload write and the enable write reach the
  delivery path at different times, i.e. a two-write arm is not the same
  interrupt as a one-write arm. dingbat models one path.
* `+4` and `+6` differing from `+0` by anything other than their own
  arithmetic (`+4 - +0` should be 0 mod 2^16 if the reload only sets the
  count): the reload value feeds the *delivery*, not just the counter.
* `(+8 - +0)`, `(+12 - +10)`, `(+16 - +14)`, `(+20 - +18)`: the halt-exit
  cost, per source. If all four agree, halt exit is one constant; if they
  differ, waking is per-source and dingbat's single `IRQ_SYNC_DELAY` /
  `HBLANK_IRQ_SYNC_DELAY` pair cannot carry it.
* The race bytes read `20` while the acknowledge lands before the request
  and `00` after it; the step between them is the acknowledge instant.
  A `00` earlier than the step, or a `20` later, is a same-cycle race
  where clear beats set (or set beats clear) — the case a "write 1 to
  acknowledge" model has to choose and dingbat chooses silently.

**Constants pinned** `src/dingbat/gba/interrupts.nim` `IRQ_SYNC_DELAY`
and `HBLANK_IRQ_SYNC_DELAY` (each fitted to one mGBA-suite row), and the
halt-wake path in `cpu.nim`.

**dingbat predicts** page CRC **953C**:

```
7C 00 85 00  6E 00 6E 00  80 00 BD 03  CA 03 6B 09
75 09 A3 00  AC 00 00 00  00 00 00 00  20 00 FF 00
```

| row | dingbat |
|---|---|
| +0 TM2 `FFF0`, one write | **124** |
| +2 the same as two writes | **133** (nine cycles more — the extra store) |
| +4 reload `0000` | **110** |
| +6 reload `0001` | **110** |
| +8 `FFF0`, halted | **128** (halt exit costs **+4**) |
| +10 / +12 hblank | **957** / **970** (halt exit **+13**) |
| +14 / +16 vblank | **2411** / **2421** (halt exit **+10**) |
| +18 / +20 DMA3 | **163** / **172** (halt exit **+9**) |
| +22..+29 the race | `00 00 00 00 00 00 20 00` |

Read the timer rows against their own arithmetic: `124 - 110 = 14`, which
is the 16 ticks the `FFF0` reload is supposed to add (dingbat is two
cycles under), and reload `0001` lands on the same 110 as reload `0000`
instead of one tick sooner. **Four different halt-exit costs for four
sources** is the loudest claim on the page — hardware answering with one
constant, or with four different ones, decides whether the wake path can
be a single number.

The race column reads `20` at exactly one spacing (j = 6, the ack write
at about t0+18) and `00` everywhere else, including j = 7 where the ack
should still be landing ahead of the request. That single-step window is
narrower than the model has any reason to be, and it is the first thing
to check against silicon.

## Page 41 CONTEND2 (hex)

**Photograph** the page. Sixteen cycle counts, all of them 16 back-to-back
`ldrh` from one region, TM0/TM1-bracketed, started at the top of the
visible part of line 40 — with the PPU loaded as hard as the hardware
allows: **128 OBJs of 64x64 at Y=40, X = 0..127**, all overlapping the
sampled line, plus every background the mode has.

| offset | region, configuration |
|---|---|
| +0 / +2 / +4 / +6 | PRAM / VRAM / OAM / IWRAM — mode 0, BG0-3 + OBJ, 128 OBJs |
| +8 / +10 / +12 | PRAM / VRAM / OAM in mode 2 (affine BG2+BG3) + OBJ |
| +16 / +18 / +20 | PRAM / VRAM / OAM — mode 0, BG0-3, OBJ layer off |
| +22 | the same sixteen reads **executed from a stub in VRAM** (reading IWRAM), mode 0 + 128 OBJs: code-fetch contention |
| +14 | that same VRAM-executed row under forced blank — the baseline +22 is read against |
| +24 / +26 | VRAM / OAM with hblank-interval-free (DISPCNT.5) set |
| +28 / +30 | VRAM / IWRAM under forced blank: the free-access baseline |

The IWRAM rows are the controls: the PPU never touches IWRAM, so anything
that moves there is measurement drift, not contention. CONTEND (page 14)
already measured the unloaded machine and dingbat matched it exactly, so
the interesting quantity is `loaded - blank` per region.

**What each outcome pins**

* `+2` (or `+4`, `+0`) larger than `+28`: the renderer really does stall
  the CPU, by that many cycles over sixteen accesses. dingbat charges a
  flat per-region constant and models no renderer contention at all, so
  it must predict `loaded == blank` for every region.
* `+24` against `+2`: whether hblank-interval-free changes the *visible*
  period's contention as well as hblank's.
* `+22` against `+14`: whether an instruction fetch from VRAM is charged
  contention the way a data read is. (They are a matched pair — the same
  stub, the same call — so the difference is clean; `+22` against `+6`
  is not, because the call overhead differs.)
* mode 2 against mode 0 on the same region: whether an affine background's
  fetch pattern costs the CPU more than a text background's.

**Constant pinned** `src/dingbat/gba/bus.nim` `ACCESS_TIMING_TABLE` — the
constant PRAM/VRAM/OAM charge, and the absence of any renderer-load term.

**dingbat predicts** page CRC **A682**:

```
E6 00 E6 00  E6 00 E6 00  E6 00 E6 00  E6 00 B7 00
E6 00 E6 00  E6 00 B7 00  E6 00 E6 00  E6 00 E6 00
```

Every data row is **00E6 = 230 cycles**, identically: PRAM, VRAM, OAM and
IWRAM, mode 0, mode 2, with and without the OBJ layer, with and without
hblank-interval-free, loaded with 128 sprites or under forced blank. And
the VRAM-executed pair is **00B7 = 183** in both the loaded row (+22) and
the blank row (+14). So dingbat says the renderer costs the CPU *exactly
nothing*, and that all four regions cost the same. Any hardware row where
`loaded > blank` refutes it, and the size of the gap is the term the bus
model is missing.

## Page 42 MULTIME (hex)

**Photograph** the page. Eight carry bit-vectors and an eight-step cycle
sweep.

MULFLAGS (page 7) caught hardware clearing C where dingbat sets it on six
of eight operand pairs; one op and eight pairs cannot fit the function.
Here six ops run the **same sixteen (Rm, Rs) pairs** and only the C bit is
kept — one bit per pair, LSB = pair 0 — so a 16-pair matrix costs two
bytes. Pairs 0-7 are MULFLAGS' table byte for byte, so page 7 cross-checks
this one; pairs 8-15 hold `Rm = 12345678` and sweep `Rs` through every
early-termination class.

| pair | Rm | Rs | pair | Rm | Rs |
|---|---|---|---|---|---|
| 0 | 00000000 | 00000000 | 8 | 12345678 | 00000001 |
| 1 | FFFFFFFF | FFFFFFFF | 9 | 12345678 | 000000FF |
| 2 | 000000FF | FF00FF00 | 10 | 12345678 | 00000100 |
| 3 | 12345678 | 9ABCDEF0 | 11 | 12345678 | 0000FFFF |
| 4 | 0000FFFF | 0000FFFF | 12 | 12345678 | 00010000 |
| 5 | 80000000 | 00000002 | 13 | 12345678 | 00FFFFFF |
| 6 | FFFFFF00 | 00000100 | 14 | 12345678 | 01000000 |
| 7 | 00000001 | FFFFFFFF | 15 | 12345678 | FFFFFFFF |

| offset | row |
|---|---|
| +0 / +2 | MULS, C preset 1 / 0 |
| +4 / +6 | MLAS, C preset 1 / 0 |
| +8 / +10 | UMULLS / SMULLS, C preset 1 |
| +12 / +14 | UMLALS / SMLALS, C preset 1 |
| +16..+31 | cycles for sixteen back-to-back `muls r0, r1, r2` with `r1 = 12345678` and `r2` = `00000012`, `00001234`, `00123456`, `12345678`, then `FFFFFFEE`, `FFFFEDCC`, `FFEDCBAA`, `EDCBA988` |

The carry preset is pinned by `subs r10, r6, #0` (C := 1) or `adds r10,
r6, #0` (C := 0) immediately before the multiply; the accumulating ops
start from zero in both halves. The timed window also holds `tm_start`,
`tm_stop` and two `mov`s — the same constant in all eight sweep rows — so
`(row - row) / 16` is the m-cycle step between classes.

**What each outcome pins**

* The bit vectors say, per op, exactly which operand pairs clear C. If
  MULS and MLAS agree bit for bit, C is a function of the multiply alone;
  if the long forms differ, the accumulate stage touches it too.
* The C preset rows (`+0` vs `+2`, `+4` vs `+6`) say whether the incoming
  C survives anywhere: if `+2` is the complement pattern of `+0`, C is
  partly preserved; if they are equal, it is fully overwritten.
* The sweep gives m = 1, 2, 3, 4 for the four positive classes if
  termination looks at leading zeros. The four negatives then say whether
  leading *ones* terminate too: the same four counts means yes (Booth on
  a signed multiplier), rising to 4 for all of them means the multiplier
  is treated as unsigned.

**Constant pinned** `src/dingbat/gba/arm/` — the multiply carry rule
(dingbat sets C where hardware clears it) and the m-cycle count.

**dingbat predicts** page CRC **149C**:

```
18 28 18 28  18 28 18 28  12 28 18 28  12 28 18 28
DC 00 EC 00  FC 00 0C 01  DC 00 EC 00  FC 00 0C 01
```

Carry vectors: `2818` for MULS at both presets, MLAS at both presets,
SMULLS and SMLALS — C set for pairs 3, 4, 11 and 13 and clear everywhere
else — and `2812` for UMULLS and UMLALS (pair 1 clear instead of pair 2).
The C preset makes no difference at all in dingbat: `+0 == +2` and
`+4 == +6`. MULFLAGS already showed hardware clearing C on six pairs
where dingbat sets it, so the MULS rows should disagree on sight; the
question these vectors answer is whether the *other five* ops follow the
same rule.

Sweep: **220 / 236 / 252 / 268** cycles for the four positive magnitude
classes — a clean 16-cycle step, i.e. exactly one extra m-cycle per class
over sixteen multiplies — and **the same four numbers again** for the
negatives. So dingbat terminates on leading ones as well as leading
zeros. If hardware's negative rows are 268 throughout, the multiplier is
scanned unsigned.

## Page 43 TIMPHASE (hex)

**Photograph** the page. Two eight-step staircases and three shorter ones.

TIMERS (page 4) already showed a staircase (hw `07 07 07 06 06 06`) when
TM2 is enabled k cycles later against a moving sample point: the
prescaler is not reset by the enable, it free-runs. What that cannot say
is whether the four timers share **one** divider. Every row here comes out
of the same IWRAM stub, which enables TM2, enables TM3 two cycles later,
and samples both after an identical delay — entered at eight sled offsets
12 cycles apart, 96 cycles of stagger in all (one and a half
prescaler-64 periods). IWRAM is 32-bit and zero-wait, so a sled offset of
48 bytes is exactly 12 cycles.

| offset | row |
|---|---|
| +0..+7 | TM2 (prescaler 64) count, sled offsets j = 0..7 |
| +8..+15 | TM3 (prescaler 64) count at those same instants |
| +16..+23 | TM2 again, with `strh reload, [TM2CNT_L]` one instruction behind the enable |
| +24..+27 | TM2 at prescaler 256, j = 0, 2, 4, 6 |
| +28 / +29 | TM2's count, and TM3's, when TM3 was **already running** |
| +30 | marker `54` |
| +31 | TM0 (prescaler 1) low byte at the j = 0 sample — the absolute phase anchor |

**What each outcome pins**

* `+0..+7` and `+8..+15` stepping at the **same** j, never differing by
  more than one: one divider feeds both timers. Stepping at unrelated j:
  each timer runs its own free-running divider.
* `+16..+23` flat where `+0..+7` staircases: a write to `TMxCNT_L`
  realigns the divider. Identical staircases: the reload write is inert
  for phase, which is what dingbat assumes.
* `+24..+27` staircasing four times slower than `+0..+7`: the 256 tap is
  the same chain divided further, not an independent counter.
* `+28` equal to `+29`: a freshly enabled timer inherits the running
  one's phase — the strongest single statement of "one shared divider".

**Constant pinned** `src/dingbat/gba/timer.nim` — `cycle_enabled` per
timer, i.e. a per-timer phase origin rather than a global divider.

**dingbat predicts** page CRC **93F4** (this run):

```
07 06 06 06  06 06 06 07  07 06 06 06  06 06 06 06
06 06 07 06  06 07 07 06  01 02 01 01  06 19 54 26
```

TM2 `07 06 06 06 06 06 06 07`, TM3 `07 06 06 06 06 06 06 06` — nearly the
same shape, differing only in the last step; the reload-write staircase
`06 06 07 06 06 07 07 06` has a different shape again; prescaler 256
gives `01 02 01 01`; the "TM3 already running" pair is `06` / `19` (25 —
TM3 has been counting since before the stub).

**These two staircases and PSGPHASE's counts move with the run's absolute
phase**, because that is exactly what they measure: this page's CRC
changed between two builds that differ only in *other* probes' code. Read
the *shape* — where the steps fall, whether the TM2 and TM3 rows step
together, whether the reload row is flat — not the absolute value, and do
not expect a hardware transcription to reproduce a CRC.

## Page 44 PSGPHASE (hex)

**Photograph** the page. Eleven poll counts.

PSGSTAT (page 10) polled ch1's active flag down from a length-63 trigger:
hardware `2E1E`, dingbat `283A` — 14 % early. One number cannot say
whether dingbat's length clock runs fast or merely starts at the wrong
phase, because the 256 Hz length tick belongs to a free-running frame
sequencer and a trigger lands somewhere inside its period. Every row here
is that same poll count (one `ldrh SOUNDCNT_X`, a test and an increment
per iteration; about 5.5 cycles on hardware), from triggers placed at four
offsets inside one period, with and without a `SOUNDCNT_X` master off/on
in front.

| offset | row |
|---|---|
| +0 / +2 / +4 / +6 | ch1 length 63, master off then on, trigger delayed 0 / 4000 / 8000 / 12000 loop iterations after the master-on write |
| +8 / +10 / +12 / +14 | the same four delays with the master left on |
| +16 | length 62 (two 256 Hz steps), master toggled |
| +18 | length 60 (four steps), master toggled |
| +20 | ch1's count with ch2 triggered by the very next store and both polled in one loop |
| +26 | (ch2's count - ch1's count) in that same row |
| +22 | ch1 length 63 retriggered while the previous tone still runs |
| +24 / +25 | SOUNDCNT_X right after the +0 trigger / right after its expiry |
| +28 | ch1 length 63 after SOUNDCNT_X was toggled off/on/off/on |
| +30 / +31 | marker `50` / rows that hit the poll cap |

The delays are loop iterations, not cycles (a ROM `subs`/`bne` pair), and
the four of them span roughly one 65536-cycle length step.

**What each outcome pins**

* `+0..+6` all equal while `+8..+14` staircase: `SOUNDCNT_X` master off/on
  **resets** the frame sequencer, so a trigger's phase is measured from
  the master-on write.
* both blocks staircasing alike: the sequencer free-runs through the
  master bit, and dingbat's 14 % is a phase error, not a rate error.
* `+16` ~2x and `+18` ~4x the length-63 count: the length unit is one
  256 Hz step, and the ratio between them is a rate measurement that is
  independent of phase — this is what separates "fast clock" from "wrong
  phase" outright.
* `+26` = 0: one length clock stands behind both channels.
* `+22` against `+0`: whether a retrigger restarts the length counter or
  leaves it where it was.

**Constants pinned** `src/dingbat/gba/apu.nim` — the frame sequencer's
phase origin and whether the master enable resets it, and the length
counter's step.

**dingbat predicts** page CRC **1376** (this run):

```
07 01 00 00  19 01 00 00  00 00 0D 03  E7 03 20 01
5A 02 D6 0B  00 00 F6 01  81 80 00 00  00 00 50 00
```

Master-toggled: **263 / 0 / 281 / 0** iterations. Master left on:
**0 / 781 / 999 / 288**. Length 62: **602**. Length 60: **3030**. The
two-channel row: ch1 **0**, ch2 - ch1 **0**. Retrigger: **502**.
SOUNDCNT_X `81` after the trigger, `80` after expiry.

Two things are worth stating plainly. First, all of these are one to two
orders of magnitude **below** the ~11800 iterations one 256 Hz step
should take at ~5.5 cycles an iteration — and the same build's PSGSTAT
(page 10) now polls **0** iterations for the identical stimulus, against
`2E1E` on hardware. dingbat's ch1 length flag drops almost immediately.
Second, the values still scale with the length (602 for two steps, 3030
for four), so the page is measuring a length clock, just a very fast one.

On hardware the expected shape is: four roughly equal counts near 11800
in the master-toggled block if the master enable resets the frame
sequencer, four staggered ones if it does not; ~2x and ~4x for lengths 62
and 60; and 0 for `+26` if one length clock serves both channels.

## Page 45 MEMCTL (hex)

**Photograph** the page. Three reads of `0x04000800`, its access widths,
its mirrors, and three EWRAM timing rows.

IDENT read `0D000020` on hardware; `mmio.nim` keeps the value for readback
and implements none of its effects. Only the documented WS field (bits
24-27) is written here, and only through a read-modify-write, so bit 0
(disable WRAM) and bit 4 (enable the 256K WRAM) keep whatever the console
booted with. **WS = 15 locks the console up and is never written.**

| offset | read |
|---|---|
| +0 | `0x04000800` (word) |
| +4 / +8 | the same register through `0x04010800` and `0x04FF0800` |
| +12 / +14 | halfword reads at `0x04000800` / `0x04000802` |
| +16..+19 | byte reads at `0x04000800`..`803` |
| +20 / +22 / +24 | 16 EWRAM word reads at the boot WS / WS = 14 / WS = 4 |
| +26 / +27 / +28 | the register's top byte after writing WS = 14 / 4 / the boot value |
| +29 | the top byte at `0x04000800` after the boot value went in through the `0x04010800` mirror |
| +30 / +31 | progress marker (`FF` = finished) / the register's low byte at the end (`20` = restored) |

**What each outcome pins**

* `+4` and `+8` equal to `+0`: the register really is mirrored every 64K
  of IO space, which is what dingbat implements.
* `+12`/`+14` and `+16..+19` reading the register's bytes rather than open
  bus: 8- and 16-bit accesses work, which GBATEK says they may not.
* `+22` well below `+20`, and `+24` well above: the WS field is live
  silicon and EWRAM really is 2 waits by default. `+20 == +22 == +24`
  means the field is readback-only on this console — the same thing
  dingbat does today, but for a different reason.
* `+26`/`+27` echoing 0E and 04: the field is writable. `+29` = `0D`: a
  write through the mirror reached the register.

**Constants pinned** `src/dingbat/gba/mmio.nim` `memctrl` ("readback only;
the waitstate/WRAM-disable effects are unimplemented") and the EWRAM
access cost in `bus.nim`.

**dingbat predicts** page CRC **5EC2**:

```
20 00 00 0D  20 00 00 0D  20 00 00 0D  20 00 00 0D
20 00 00 0D  41 01 41 01  41 01 0E 04  0D 0D FF 20
```

`0D000020` at the register and at both mirrors; the halfword and byte
reads all return the register's own bytes; **all three EWRAM timing rows
are 0141 = 321 cycles** — the WS field is pure readback in dingbat, so
the overclock buys nothing; the field itself echoes `0E` and `04` and
comes back to `0D`, and a write through the `0x04010800` mirror lands on
the register. So the one row where hardware can disagree is +22/+24: if
WS = 14 makes 16 EWRAM word reads measurably faster on silicon, the
`memctrl` comment ("effects unimplemented") becomes a real bug with a
measured size.

## Page 46 DMATIME (hex)

**Photograph** the page.

| offset | row |
|---|---|
| +0 | TM0 read by the instruction right after the store that enables a 1-word immediate DMA0 (EWRAM -> EWRAM) |
| +2 | the identical instruction stream with the enable bit **clear**: the baseline |
| +4 / +6 | the same for 4 and 16 words |
| +8..+18 | `tm_start`/`tm_stop` around a 16-word DMA3 in EWRAM (+8), IWRAM (+10), VRAM (+12), palette (+14), OAM (+16), ROM -> EWRAM (+18) |
| +20 / +21 | DISPSTAT low byte and VCOUNT at the moment an hblank-started DMA's word was first seen in memory |
| +22 / +23 | the same pair for a vblank-started DMA |
| +24 / +26 | TM0 cycles from the polled rise of the hblank / vblank flag to that word appearing |
| +28 | (handler entry stamp) - (the stamp taken by the instruction after the enabling store) for a 16-word DMA3 with IRQ |
| +30 | 1 if the burst's last destination word was already in memory when the instruction after the enabling store read it |
| +31 | marker `44` |

**What each outcome pins**

* `+0 - +2` is the start delay in cycles, measured with the DMA's own
  work held to one word. `+4 - +0` and `+6 - +4` then separate the fixed
  start cost from the per-word cost, which is what `+8..+18` measure per
  region.
* `+30`: `1` means the CPU does not see the bus again until the burst is
  complete; `0` means the CPU resumed with words still in flight.
* `+28` positive means the completion interrupt arrives *after* the CPU
  has already executed the instruction following the enable; zero or
  negative means the interrupt is delivered inside the stall.
* `+20`/`+22` say which side of the DISPSTAT edge the transfer lands on,
  and `+24`/`+26` how far behind the flag it is. Both flags are polled
  from ROM, so a few cycles of poll granularity are baked into every
  number and only the differences between +24 and +26 are clean.

**Constants pinned** `src/dingbat/gba/dma.nim` — the start delay, the
hblank/vblank trigger instants, and the order of the completion interrupt
against the CPU's resume.

**dingbat predicts** page CRC **A154**:

```
38 00 2A 00  67 00 F7 00  1C 01 7C 00  9C 00 9C 00
7C 00 1E 01  02 26 01 A0  25 00 25 00  5E 00 01 44
```

Start delay: **56** cycles for a 1-word DMA against a **42**-cycle
baseline, so the enable cost the CPU **14** cycles; 4 words **103**, 16
words **247** — about 9.6 cycles a word after a fixed start. 16-word
bursts: EWRAM **284**, IWRAM **124**, VRAM **156**, palette **156**, OAM
**124**, ROM -> EWRAM **286**. The hblank-started DMA lands with DISPSTAT
`02` (hblank set) at VCOUNT 38 and the vblank-started one with DISPSTAT
`01` at VCOUNT 160 — both on the right side of their edge — **37** cycles
behind the polled flag in each case (that is mostly poll granularity).
`+30 = 01`: the last destination word is already in memory when the
instruction after the enable reads it, i.e. dingbat stalls the CPU for
the whole burst. `+28 = 5E = 94`: the completion interrupt arrives 94
cycles after the CPU resumed.

## Page 47 IWCYCLE (hex)

**Photograph** the page. **This page needs the real BIOS**, which is what
a flashcart gives it; dingbat's prediction is recorded twice, once with
its HLE BIOS and once with `--bios=<gba_bios.bin>`, and the two differ.

`hle_bios.nim` rebuilds IntrWait by hand, down to a hard-coded 44-cycle
wake path (`INTRWAIT_TUNE`) and a reconstructed register protocol. The
page installs **its own IRQ handler** — the shared one never touches the
BIOS flag mirror at `0x03007FF8`, and IntrWait cannot return without a
handler that does — and puts the shared one back at the end. Every wait is
masked with the timer-3 watchdog bit as well as the source under test, so
a wait that would hang returns anyway and `+12` names the source that
ended it (`0001` vblank, `0040` the watchdog rescued the row).

| offset | row |
|---|---|
| +0 | cycles for `swi 4` with r0 = 0, r1 = `0001` and the mirror pre-set to `0001` — the pure return path, no halt |
| +2 | the mirror right after that call |
| +4 / +6 | r0 / r3 it returned |
| +8 | the mirror after the same call with the mirror pre-set to `FFFF` |
| +10 / +12 | cycles for `swi 4` r0 = 1 (discard), r1 = `0041`, two lines before vblank / the r0 it returned |
| +14 / +16 | cycles for `swi 5` (VBlankIntrWait) from the same anchor / the mirror after it |
| +18 / +20 | (the stamp after the call returned) - (the handler's entry stamp), for +10 and +14 |
| +22 | low half of (sp after - sp before) across the +10 call |
| +24 | low half of r12 after it (pre-set to `1234`) |
| +26 | low half of r2 after it |
| +28 | cycles for `swi 4` r0 = 0, r1 = `0041`, mirror pre-set to 0, same anchor |
| +30 / +31 | IME read back after the +0 call / progress marker (`49` = finished) |

**What each outcome pins**

* `+18` and `+20` are the wake path measured from *inside* the interrupt:
  they are exactly what `INTRWAIT_TUNE`'s 44 models, with none of the
  vblank wait in them.
* `+2` and `+8` say which bits the BIOS clears: only the matched ones, or
  the whole mask, or the whole mirror.
* `+22` = 0, `+24` = `1234`, `+26` = a documented residue: the frame
  protocol dingbat reconstructs from the disassembly. Any of them wrong
  is a game-visible bug (the comment names Prince of Tennis 2004 and
  Bubble Bobble Old & New).
* `+28 - +10` is the discard path on its own.
* `+30`: whether IntrWait forces IME = 1 even on the immediate-return
  path.

**Constants pinned** `src/dingbat/gba/hle_bios.nim` `hle_intr_wait` /
`check_intr_wait` — `INTRWAIT_TUNE = 44`, the mirror clear rule, and the
r0/r2/r3/r4/r12/lr/sp protocol.

**dingbat predicts**, HLE BIOS — page CRC **06BC**:

```
A0 00 00 00  01 00 00 00  FE FF 53 0A  01 00 6F 0A
00 00 06 01  06 01 00 00  34 12 00 00  5D 0A 01 49
```

and under the **real BIOS** (`--bios gba_bios.bin`), page CRC **8E6F**:

```
C0 00 00 00  01 00 00 00  FE FF 62 0A  01 00 6F 0A
00 00 05 01  05 01 00 00  34 12 00 00  5D 0A 01 49
```

| row | HLE | real BIOS |
|---|---|---|
| +0 immediate return | **160** | **192** |
| +2 mirror after it | `0000` | `0000` |
| +4 / +6 r0 / r3 | `0001` / `0000` | same |
| +8 mirror from `FFFF` | `FFFE` | `FFFE` — only the matched bit cleared |
| +10 / +12 the vblank wait | **2643**, r0 = `0001` | **2658**, r0 = `0001` |
| +14 VBlankIntrWait | **2671** | **2671** |
| +18 / +20 the wake path | **262** / **262** | **261** / **261** |
| +22 sp delta | `0000` | `0000` |
| +24 r12 | `1234` | `1234` |
| +26 r2 | `0000` | `0000` |
| +28 without discard | **2653** | **2653** |
| +30 IME afterwards | `01` | `01` |

Both agree that the BIOS clears only the matched bit, hands r12 back, and
leaves sp balanced and IME set. The one place they part is the
immediate-return path: dingbat's HLE takes **160** cycles where its own
real-BIOS run takes **192**, so the HLE is 32 cycles fast on the
no-halt path while `INTRWAIT_TUNE`'s wake path (`+18`/`+20`) is within a
cycle. Hardware always runs the real BIOS, so it is the second column
that has to match; the first column says how far the HLE would then be
off.

## Page 48 DMAFIFO (hex)

**Photograph** the page. Twelve loop timings and two interrupt counts.

`dma.nim`'s `run_pending` drops a FIFO grant whose FIFO already holds 16
bytes — "FIFO requests are level-conditioned on the FIFO, not
edge-latched ... Assumed; no ROM pins this" — a rule that came out of
Densetsu no Sutafi 3 losing stream bytes, not out of hardware. A FIFO
destination cannot be read back and `DMA1SAD` is write-only, so the
observable here is the **bus**: every row times the same 256-iteration ROM
loop with the TM2/TM3 cascade while DMA1 feeds FIFO A from EWRAM, and the
cycles the loop lost are the transfers that happened. Timer 0 drives the
FIFO, and its reload sets how many overflows fall inside one 4-word burst
(a burst is roughly 16-20 cycles, so reload `FFF8` already puts two
inside it and `FFFC` four).

| offset | row |
|---|---|
| +0 / +2 / +4 / +6 / +8 / +10 | loop cycles at TM0 reload `FC00` / `FF00` / `FFC0` / `FFF0` / `FFF8` / `FFFC` |
| +12 | the same loop with DMA1 disabled and TM0 still at `FFFC`: the timer's own cost |
| +14 | the loop with DMA1 disabled and TM0 stopped: the bare loop |
| +16 | a single-shot (repeat off) DMA1 at reload `FFFC` |
| +18 | DMA1CNT_H read back after that row (`8000` set = still enabled) |
| +20 / +22 | DMA1-complete interrupts counted over one loop at reload `FFC0` / `FC00` — deliberately slow rates (see below) |
| +24 | the same experiment on DMA2 / FIFO B driven by timer 1 at `FFF8` |
| +26 | SOUNDCNT_H read back |
| +28 | reload `FFF8` again with the DMA source in ROM instead of EWRAM |
| +30 / +31 | marker `46` / OR of every IF bit the counting handler saw |

**What each outcome pins**

* Subtract `+12` from `+10` (and `+14` from `+12`) and the remainder is
  DMA stealing. `+8` and `+28` differ only in the per-word source cost, so
  the pair gives the cycles-per-transfer scale that turns every other row
  into a transfer count.
* If the request is **level-conditioned**, the rows saturate: past some
  reload the FIFO stays full and extra overflows buy no extra bursts,
  so `+6`, `+8` and `+10` converge.
* If it is **edge-latched**, every overflow queues a grant and `+8`/`+10`
  keep climbing roughly in proportion to the overflow rate — and `+20`
  climbs with them.
* `+16`/`+18`: with repeat off the channel disables itself after one
  burst. A second latched grant would either re-run it (more stolen
  cycles than one burst can explain) or leave `+18` showing the enable
  bit still set.
* `+24` says whether channel 2 behaves like channel 1.

The two interrupt-counted rows run at `FFC0` and `FC00`, not at the fast
reloads: one interrupt per burst at `FFF8` arrives every ~128 cycles,
which is less than a ROM handler plus the BIOS dispatcher costs, and the
console makes no forward progress at all (dingbat wedges outright). They
calibrate interrupts-per-burst at a rate the CPU survives; the fast rows
are read off the bus, not off the interrupt.

**Constant pinned** `src/dingbat/gba/dma.nim` `run_pending`, the
`sizes[ch-1] >= 16` guard.

**dingbat predicts** page CRC **7897**:

```
76 1A 56 1A  F2 1A D0 1D  70 22 3A 32  38 1A 38 1A
38 1A 00 00  0A 00 00 00  52 22 06 73  46 23 46 00
```

The bare loop is **1A38 = 6712** cycles, and TM0 hammering at reload
`FFFC` with DMA1 off costs **nothing** (+12 is 6712 too). With the FIFO
DMA armed the loop grows **6774 / 6742 / 6898 / 7632 / 8816 / 12858** as
the reload goes `FC00` -> `FFFC`. At `FFFC` that is 6146 stolen cycles
for 1678 overflows: **one 4-word burst per 16 overflows**, ~58 cycles
each — exactly the level-conditioned rule, arithmetic included. The
single-shot row is **6712**, indistinguishable from the bare loop, and
`+18 = 0000`: the channel disabled itself after its one burst with
nothing latched behind it. Interrupt counts **10** at `FFC0` and **0** at
`FC00`. FIFO B on DMA2/timer 1 steals a comparable **8786**. The ROM-source
row is **9030** against `+8`'s 8816, so a ROM-sourced word costs about
214/105 ~ 2 cycles more than an EWRAM one.

If hardware's fast rows climb past dingbat's — in particular if `+8` and
`+10` do not sit on the same one-burst-per-16-overflows line — the grant
is edge-latched and the guard in `run_pending` is papering over it.

## Page 49 UNDMODE (hex)

**Photograph** the page. **Hold SELECT at power-on to skip it** (see
above); a skipped page reads `99` at +0 and `EE` at +31.

`cpu.nim`'s `mode_bank` sends every pattern that is not one of the seven
ARM modes to the user bank — "Assumed; no ROM pins this" — and its comment
names the game that gets there: Prince of Tennis 2004 returns with SPSR
mode `1E`. Each banked r13 is loaded with a constant that names its bank,
then `CPSR_c` is written with an undefined mode number and r13 read
straight back, so **the value is the answer**:

| r13 read back | bank |
|---|---|
| `51515151` | user / system |
| `52525252` | FIQ |
| `53535353` | abort |
| `54545454` | undefined |
| `03007Fxx` | one of the BIOS's own stacks (IRQ or supervisor) |

| offset | row |
|---|---|
| +0 / +4 / +5 | r13 in mode `15` / CPSR low byte there / r14 low byte |
| +8 / +12 / +13 | the same for mode `1A` |
| +16 / +20 / +21 | the same for mode `1E` (the Prince of Tennis pattern) |
| +24 | r13 read back in system mode afterwards (`51515151` = the round trip left the system bank alone) |
| +28 | progress marker: the last step started |
| +29 | the in-flight word as the recovery found it: `1` = the page walked out on its own, `2` = the watchdog had to divert it |
| +30 | `AA` once the page ran to the end |

Interrupts stay unmasked across the mode change with TM3 armed as a
watchdog through the same MARKER protocol `run_msr_probe` uses, so an
interrupt can divert execution to the recovery path if a pattern wedges
the pipeline; the progress byte is written **before** each mode write, so
a page that comes back with `+28` = 2 and `+30` = 00 says mode `1A` was
where it died.

**What each outcome pins**

* `+0`/`+8`/`+16` = `51515151`: undefined patterns select the user bank,
  and dingbat's assumption is right.
* Any other constant: the pattern maps onto a real bank (very likely by
  the low bits of the mode field), and `mode_bank`'s `else: 0` is wrong
  for that pattern.
* The CPSR low bytes say whether the written mode number is even
  retained: a value that reads back as something else means the mode
  field is not fully writable.

**dingbat predicts** page CRC **25D2**:

```
51 51 51 51  15 8C 00 00  51 51 51 51  1A 8C 00 00
51 51 51 51  1E 8C 00 00  51 51 51 51  04 01 AA 00
```

All three undefined patterns read `51515151` — the user/system bank —
with the mode field reading back exactly as written (`15`, `1A`, `1E`)
and the same user r14 low byte (`8C`) each time. `+24` confirms the
system bank came back untouched, `+29 = 01` says the page walked out on
its own, `+30 = AA` that it finished. That is `mode_bank`'s `else: 0`
stated as a measurement; any other constant in `+0`, `+8` or `+16` on
hardware names the bank the pattern really selects.
