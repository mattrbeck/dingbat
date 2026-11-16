# GBA probe pages v7 — OBJBUDGET, OBJGEOM, DMAOPENBUS, PSGBIAS

Four probes for four GBA questions in `docs/dev/hwprobe-questions.md`. Three
are `gbaedge.gba` pages (37-39); the fourth is a separate audio ROM,
`psgbias.gba`, that is photographed **and recorded**.

Pages 37-39 were run on the AGB SP in session 5 (2026-09-04); each has a
**Result** line below. PSGBIAS has not been recorded yet.

Nothing here encodes an expected value. PSGBIAS's "dingbat predicts" is
what the emulator produced when the ROM was written (captured with
`hwprobe_capture.py`, see `expected/predicted-2026-09/`) — it is the
hypothesis on trial, not the answer key.

## Build

```
python3 tests/roms/gbaedge.py     # -> gbaedge.gba, gbaedge-auto.gba (40 pages at v7, 54 since v10)
python3 tests/roms/psgbias.py     # -> psgbias.gba, psgbias-auto.gba
```
Both need `arm-none-eabi-{as,ld,objcopy}` (Homebrew) on PATH, and `gbafix`
from `/opt/devkitpro/tools/bin` for the header logo. Flash the **manual**
builds; the `-auto` ones are for the emulator-side capture.

Landing on a visual page repaints it under forced blank, which takes a
little over one frame: the screen flashes white. Photograph a settled
page, not the flash — and the capture script below deliberately shoots
12 frames into each page's window for the same reason.

Capture dingbat's own prediction of every page:

```
python3 tests/roms/hwprobe_capture.py ./dingbat_test \
        tests/roms/gbaedge-auto.gba <outdir>
```
It writes `pNN.ppm` + `pNN.png` per page and a `pages.txt` in
`hwprobe_expected.py`'s transcription format (visual pages get a
`visual` line and their picture). It finds the viewer's start frame
itself and walks page by page, so a ROM whose boot probes get slower does
not need the frame numbers re-derived. Write to a new directory:
`expected/predicted-2026-09/` is the capture the hardware sessions were
diffed against and is kept as it was; `expected/predicted-2026-09-17/` is
all 54 pages at that date.

## Slots did not move

Pages 0-36 are byte-identical to the session-4 build: the v7 probes hang
off a single `bl probe_tail` at the end of `main`'s probe list, all their
code sits *after* the data block, and the boot-time slot-clearing loop
still zeroes exactly 37 slots (the v7 slots are cleared inside
`probe_tail`, so the frame phase PPUSTAT/IRQLAT sample is unchanged).
Verified by capturing both builds and diffing every per-page CRC.

**`ALL` moves** at every version bump: it is the CRC over every slot.
Hardware transcriptions (`expected/agb-sp-*.txt`) stay valid page by page;
only the `ALL` line differs. `ALL` for the v7 build was **F1AF** (manual) /
**38FC** (`-auto`); later values are in the v8 and v10 sections.

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

**Constant tested** `src/dingbat/gba/ppu.nim`, `render_sprites_impl`:
`obj_cycles = if hblank_interval_free: 954 else: 1210`, and the comment
"The sprite that exhausts the budget still draws fully: Assumed;
hardware likely truncates it".

**Result** (session 5, 2026-09-04): the photo is the same picture as
dingbat's `expected/predicted-2026-09/p37.png` — in bands A and B TEST
draws complete (all eight ramp colours, band B reversed) and NEXT is
missing; band C complete. The sprite that exhausts the budget draws in
full. dingbat matches. Recorded in `docs/dev/hwprobe-results-agb.md`,
"Session 5", and `expected/agb-sp-5.txt`.

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

**Constant tested** `ppu.nim` `obj_geometry` ("The exact thresholds
(X>239, Y>159) are assumed") and `render_sprites_impl`'s "OBJ character
fetches wrap within the 32K of OBJ VRAM. Assumed; no ROM pins this."

**Result** (session 5, 2026-09-04): the same picture as dingbat's
`expected/predicted-2026-09/p38.png` — both staircases exactly k pixels
wide/tall for X=504+k / Y=248+k (k=1 is a single pixel column, so
photograph close), the Y200 strip at rows 0-7, `Y130 DBL` cyan at rows
130-159 with nothing at the top (`y > 159 -> y - 256`), and `T1020` green
at rows 56-71 (the fetch wraps within OBJ VRAM). dingbat matches. Recorded
in `docs/dev/hwprobe-results-agb.md`, "Session 5".

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

**Constant tested** `src/dingbat/gba/bus.nim` `read_open_bus_value` —
"The exact window — the DMA's own reads plus exactly one CPU instruction
after the burst — is Assumed; no ROM pins its length."

**Result** (session 5, 2026-09-04): the grant at store+3 is confirmed; a
DMA3 from unmapped space repeats its own latch (`A5A5A5A5` twice); and the
one word dingbat had wrong showed that an opcode fetch also replaces the
DMA's word on the bus. dingbat read the page byte for byte as the console
did (CRC **2CB2**) from `55c79b9f` (a DMA's word is open bus only for the
CPU's first access after the burst; see
`expected/predicted-2026-09-17/README.md`). Recorded in
`docs/dev/hwprobe-results-agb.md`, "Session 5". dingbat's pre-run prediction
was CRC **8A4F** (`expected/predicted-2026-09/`).

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

All ten pages were run on the AGB SP in session 5 (2026-09-04); each has a
**Result** line below.

Ten `gbaedge.gba` pages (40-49) for nine GBA questions in
`docs/dev/hwprobe-questions.md` (the timer/PSG question needs two pages), plus
two "Assumed" comments in the emulator that no ROM pinned. All ten are hex
pages: photograph the 32-byte slot.

dingbat's pre-run captures of these pages are in
`expected/predicted-2026-09/`; the hardware column is
`expected/agb-sp-5.txt`, and the per-page verdicts are in
`docs/dev/hwprobe-results-agb.md`, "Session 5 (2026-09-04): pages 37–49".

## Build

As in the v7 section above (this build had 50 pages).

## Slots did not move

Pages 0-39 are byte-identical to the v7 build. The v8 probes hang off a
single `bl probe_tail3` at the very end of `probe_tail`, all their code
sits after everything v1-v7 assembles, and they clear their own slots
(40-49) themselves, so neither the boot-time zeroing loop nor the frame
phase that PPUSTAT/IRQLAT sample changes. Verified by capturing the v7
binary and this one through `hwprobe_capture.py` and diffing the two
`pages.txt`: all 40 old pages identical, every per-page CRC unchanged.

`ALL` for this build was **5060** (manual) / **BA6C** (`-auto`, HLE BIOS) /
**53C7** (`-auto`, real BIOS); on the console (session 5, build `ad6af27a`)
it read **05C6**.

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
  interrupt as a one-write arm. dingbat modelled one path.
* `+4` and `+6` differing from `+0` by anything other than their own
  arithmetic (`+4 - +0` should be 0 mod 2^16 if the reload only sets the
  count): the reload value feeds the *delivery*, not just the counter.
* `(+8 - +0)`, `(+12 - +10)`, `(+16 - +14)`, `(+20 - +18)`: the halt-exit
  cost, per source. If all four agree, halt exit is one constant; if they
  differ, waking is per-source and dingbat's single `IRQ_SYNC_DELAY` /
  `HBLANK_IRQ_SYNC_DELAY` pair could not carry it. (On hardware HALTCNT
  written from cartridge code does not halt; see the Result.)
* The race bytes read `20` while the acknowledge lands before the request
  and `00` after it; the step between them is the acknowledge instant.
  A `00` earlier than the step, or a `20` later, is a same-cycle race
  where clear beats set (or set beats clear) — the case a "write 1 to
  acknowledge" model has to choose and dingbat chose silently.

**Constants tested** `src/dingbat/gba/interrupts.nim` `IRQ_SYNC_DELAY`
and `HBLANK_IRQ_SYNC_DELAY` (each fitted to one mGBA-suite test), and the
halt-wake path in `cpu.nim`.

**Result** (session 5, 2026-09-04): the IF-ack race and the "halted"
timer, V-blank and DMA3 rows matched dingbat; the "halted" H-blank row read
989 against dingbat's 970, and the running-CPU rows differed by +4 to +30
cycles (sub-instruction attribution). The H-blank row was never a halt: a
HALTCNT write from cartridge code is ignored on hardware, only BIOS code can
halt (`docs/dev/playtest-bugs.md` §18, §79), so none of the four "halted" rows
measures a halt-exit cost. dingbat read the whole page as the console
did, 32/32 bytes, as of `7875eaf9` (an interrupt taken in gamepak code pays for its in-flight
fetch as N or S, less a cycle). Recorded in `docs/dev/hwprobe-results-agb.md`,
"Session 5"; in dbsuite as `irq/irqlat-*` and `irq/if-ack-race-*`.
dingbat's pre-run prediction was CRC **953C**.

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
  the CPU, by that many cycles over sixteen accesses. dingbat then charged
  a flat per-region constant and modelled no renderer contention, so it
  predicted `loaded == blank` for every region.
* `+24` against `+2`: whether hblank-interval-free changes the *visible*
  period's contention as well as hblank's.
* `+22` against `+14`: whether an instruction fetch from VRAM is charged
  contention the way a data read is. (They are a matched pair — the same
  stub, the same call — so the difference is clean; `+22` against `+6`
  is not, because the call overhead differs.)
* mode 2 against mode 0 on the same region: whether an affine background's
  fetch pattern costs the CPU more than a text background's.

**Constant tested** `src/dingbat/gba/bus.nim` `ACCESS_TIMING_TABLE` — the
constant PRAM/VRAM/OAM charge, and the absence of any renderer-load term.

**Result** (session 5, 2026-09-04): renderer contention is real. OAM:
none in any configuration. PRAM: +1 over 16 reads. VRAM in mode 0: +1 per
CPU halfword read, with or without the OBJ layer or H-blank-free. VRAM in
mode 2 with two affine BGs: the CPU is locked out until H-blank (1066
against 230). Code run from VRAM under forced blank costs 220, not 183.
dingbat then modelled no contention (its pre-run prediction, CRC **A682**,
read 230 on every data row). Since `47d0907f` an access to palette RAM, VRAM
or OAM waits for the dots the renderer holds, and dingbat passes the page's
sixteen readings as dbsuite tests (`bus/contend-*`; two of them take the
console's values from a parked run, `c2040909`). Recorded in
`docs/dev/hwprobe-results-agb.md`, "Session 5".

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

**Constant tested** `src/dingbat/gba/arm/` — the multiply carry rule
(MULFLAGS had dingbat setting C where hardware cleared it) and the m-cycle
count.

**Result** (session 5, 2026-09-04): byte-exact with dingbat's pre-run
prediction, CRC **149C** — carry vectors `2818` (MULS and MLAS at both
presets, SMULLS, SMLALS) and `2812` (UMULLS, UMLALS), the C preset changing
nothing, and the sweep 220 / 236 / 252 / 268 cycles for the positive classes
and the same four for the negatives (leading ones terminate too). This
closed the MULFLAGS (page 7) question. Recorded in
`docs/dev/hwprobe-results-agb.md`, "Session 5"; in dbsuite as `cpu/muls-*`.

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
  for phase, which is what dingbat assumed.
* `+24..+27` staircasing four times slower than `+0..+7`: the 256 tap is
  the same chain divided further, not an independent counter.
* `+28` equal to `+29`: a freshly enabled timer inherits the running
  one's phase — the strongest single statement of "one shared divider".

**Constant tested** `src/dingbat/gba/timer.nim` — `cycle_enabled` per
timer, i.e. a per-timer phase origin rather than a global divider.

**Result** (session 5, 2026-09-04): one free-running divider is shared by
all timers, a reload write does not realign it, and a freshly enabled timer
inherits a running one's phase (the "TM3 already running" pair `06` / `19`
exact). The staircase shapes are dingbat's; the base phase differs by 1-7
cycles, which is accumulated boot drift. No change followed. Recorded in
`docs/dev/hwprobe-results-agb.md`, "Session 5". dingbat's pre-run capture was
CRC **93F4**.

**These staircases and PSGPHASE's counts move with the run's absolute
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

**Constants tested** `src/dingbat/gba/apu.nim` — the frame sequencer's
phase origin and whether the master enable resets it, and the length
counter's step.

**Result** (session 5, 2026-09-04): where both channels live, the 256 Hz
length clock matches dingbat to one poll. But every ch1 trigger that is the
first after a SOUNDCNT_X 0→1 dies at once, for lengths 1, 2 and 4 ticks
alike (no poll timed out; SOUNDCNT_X reads `80` right after the trigger),
while ch2 triggered two stores later lives 486 polls. Pages 51 PSGFIRST and
52 PSGWHY followed it up: it is ch1 only, and these ch1 rows trigger at
frequency `0x400`, where ch1's trigger-time sweep check computes f + f =
`0x800` and kills the channel. dingbat models that check since the PSG
changes of 2026-09-25 (`60219abb`, `2f1024d3`); this page itself has not
been re-scored. Recorded in `docs/dev/hwprobe-results-agb.md`, "Session 5".
dingbat's pre-run capture was CRC **1376**.

## Page 45 MEMCTL (hex)

**Photograph** the page. Three reads of `0x04000800`, its access widths,
its mirrors, and three EWRAM timing rows.

IDENT read `0D000020` on hardware; `mmio.nim` then kept the value for readback
and implemented none of its effects. Only the documented WS field (bits
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
  of IO space, which is what dingbat implemented.
* `+12`/`+14` and `+16..+19` reading the register's bytes rather than open
  bus: 8- and 16-bit accesses work, which GBATEK says they may not.
* `+22` well below `+20`, and `+24` well above: the WS field is live
  silicon and EWRAM really is 2 waits by default. `+20 == +22 == +24`
  means the field is readback-only on this console — the same thing
  dingbat then did, but for a different reason.
* `+26`/`+27` echoing 0E and 04: the field is writable. `+29` = `0D`: a
  write through the mirror reached the register.

**Constants tested** `src/dingbat/gba/mmio.nim` `memctrl` ("readback only;
the waitstate/WRAM-disable effects are unimplemented") and the EWRAM
access cost in `bus.nim`.

**Result** (session 5, 2026-09-04): the EWRAM wait field is live — 16
word reads cost 321 / 289 / 609 cycles at WS 13 / 14 / 4, i.e.
`waits = 15 − WS`, `2·(1+waits)` per word — and the 8/16-bit reads and the
64K mirrors all work. dingbat had the field as readback only (321 for every
setting; pre-run prediction CRC **5EC2**). Since `0ace19db`
`update_waitcnt` applies it and the page matches byte for byte. Recorded in
`docs/dev/hwprobe-results-agb.md`, "Session 5"; in dbsuite as `bus/memctl-*`.

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

**Constants tested** `src/dingbat/gba/dma.nim` — the start delay, the
hblank/vblank trigger instants, and the order of the completion interrupt
against the CPU's resume.

**Result** (session 5, 2026-09-04): the start delays and the IWRAM, OAM,
palette, EWRAM and ROM bursts are exact to the cycle. The VRAM burst is +21
on hardware (renderer contention), and the completion interrupt reaches a
**running** CPU 15 cycles later than dingbat had it (the halted case exact).
Both have since been modelled — renderer contention in `47d0907f`, and
`7875eaf9` turned the completion-interrupt test green — and dingbat passes
the page's dbsuite tests (`dma/dmatime-*`). Recorded in
`docs/dev/hwprobe-results-agb.md`, "Session 5". dingbat's pre-run prediction
was CRC **A154**.

## Page 47 IWCYCLE (hex)

**Photograph** the page. **This page needs the real BIOS**, which is what
a flashcart gives it; dingbat's pre-run capture was taken twice, with its
HLE BIOS and with `--bios=<gba_bios.bin>`.

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

**Constants tested** `src/dingbat/gba/hle_bios.nim` `hle_intr_wait` /
`check_intr_wait` — `INTRWAIT_TUNE = 44`, the mirror clear rule, and the
r0/r2/r3/r4/r12/lr/sp protocol.

**Result** (session 5, 2026-09-04): the immediate-return IntrWait costs
**192**, the real BIOS's figure; the mirror clear (only the matched bit),
r12, sp and IME residues are all as modelled. The HLE's 160 became 192 in
`eaef5a78`. The `+18`/`+20` wake-path rows read 259 on the console against
dingbat's 262; moving `INTRWAIT_TUNE` from 44 to 41 fixes them but costs 70
Timer count-up tests, so the residual sits before the handler, not
after it, and no later re-check of these two rows is on record. `+10` moves
by one anchor iteration between builds (poll-anchor phase, not a cost;
`docs/dev/playtest-bugs.md` §79). Recorded in `docs/dev/hwprobe-results-agb.md`,
"Session 5". dingbat's pre-run captures were CRC **06BC** (HLE BIOS) and
**8E6F** (real BIOS).

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

**Constant tested** `src/dingbat/gba/dma.nim` `run_pending`, the
`sizes[ch-1] >= 16` guard.

**Result** (session 5, 2026-09-04): the grant is level-conditioned — one
4-word burst per 16 overflows, and the single-shot channel leaves nothing
latched behind — which confirms the `run_pending` guard. Each
timer-triggered burst costs about 1 cycle more on hardware than in dingbat,
and FIFO B on DMA2 costs exactly what FIFO A does, where dingbat had it one
burst cheaper. Recorded in `docs/dev/hwprobe-results-agb.md`, "Session 5"; no
later re-check of this page is on record. dingbat's pre-run prediction was
CRC **7897**.

## Page 49 UNDMODE (hex)

**Photograph** the page. **Hold SELECT at power-on to skip it** (see
above); a skipped page reads `99` at +0 and `EE` at +31.

`cpu.nim`'s `mode_bank` sent every pattern that is not one of the seven
ARM modes to the user bank — "Assumed; no ROM pins this" — and its comment
named the game that gets there: Prince of Tennis 2004 returns with SPSR
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
  as `mode_bank` assumed.
* Any other constant: the pattern maps onto a real bank (very likely by
  the low bits of the mode field), and `mode_bank`'s `else: 0` is wrong
  for that pattern.
* The CPSR low bytes say whether the written mode number is even
  retained: a value that reads back as something else means the mode
  field is not fully writable.

**Result** (session 5, 2026-09-04): in all three undefined modes (`15`,
`1A`, `1E`) banked r13 and r14 read **0**, the mode field holds the pattern
as written, and the system-mode r13 survives the round trip. dingbat had
sent the patterns to the user bank (`51515151`, leaking user r14; pre-run
prediction CRC **25D2**). Since `670a34a4` they select an empty bank
(`UNDEF_BANK`, zeroed on entry) and the page matches byte for byte.
Recorded in `docs/dev/hwprobe-results-agb.md`, "Session 5"; in dbsuite as
`cpu/mode-*`.

---

## Reading a page's counts off the link rig

Standing note for every page here that counts poll iterations. These pages
were written for a cartridge, where the poll loop runs at roughly 59 cycles an
iteration. The same rows re-run as a payload over the link rig execute from
RAM at about ten cycles, six times faster, and the counts they were sized for
overflow their fields:

* **PSGFIRST (51)** stores a 16-bit count. A live row wraps: 104856 polls
  reads as `0x9998`, a plausible number rather than an obvious overflow. Add
  `0x10000` to any row too small for its length.
* **PSGWHY (52)** stores the count divided by 256 and saturated, so a healthy
  tone reads `00 FF` and `FF` stops meaning "never expired"; `+30` is what
  says that.

Check any unwrapping by ratio rather than by eye: halve a row's length and its
count must halve. That is how the wrap above was caught -- a bumped row
appeared to *gain* a third, and unwrapped it was exactly 2.0000.

# GBA probe page v9 — when is an H-blank DMA granted the bus?

Run on the AGB SP in session 6 (2026-09-16); the **Result** is below.

One `gbaedge.gba` page, **50 HDMAPHASE**, hex. It asks a single question
that nothing else in this ROM or the mGBA suite separates.

A DMA armed for H-blank has to be granted the bus at *some* instant in the
scanline. dingbat granted it on the end-of-draw edge, cycle 960 of 1232.
The alternative is that the DMA start signal is the same latched DISPSTAT
condition that raises the H-blank interrupt — cycle 960 + 46 (the flag)
+ 6 (the IRQ synchroniser) = 1012 — so the DMA rides the flag rather than
the edge. The two differ by about 52 cycles, and every H-blank DMA in
every game lands at a different point in the instruction stream it
interrupts depending on which is right.

The mGBA suite's Misc "DMA Prefetch Break" test is sensitive to exactly
this: it exits on the one iteration of a 36-cycle loop where an H-blank
DMA's word is still the last thing on the bus when an unmapped read
happens. dingbat read `0x100026D4` against hardware's `0x10002A94`;
moving the grant from 960 to 1012 closed that test and moved nothing else
in the 1219-test runner. That is a one-parameter fit to a single test, which
is why this page exists.

**Page 46 DMATIME does not already answer it.** Its `+24` — cycles from
the polled rise of the H-blank flag to the DMA's word appearing in memory
— reads `0025` (37) on both the AGS and dingbat. Both ends of that
measurement are ROM-resident polls tens of cycles wide, so it reports ~37
whether the DMA fired before the flag or after it. The agreement is
granularity, not evidence.

## How this page measures it

Two timers, started back to back and never restarted inside a trial.

**TM0 belongs to the DMA.** The DMA under test copies one halfword of
*zero* into `TM0CNT_H`. That clears the timer's own enable bit, so TM0
freezes on the cycle of the DMA's write and `TM0CNT_L` reads that stamp
back afterwards. No polling and no granularity — the DMA timestamps
itself.

**TM2 belongs to the CPU**, which polls DISPSTAT and reads `TM2CNT_L` on
the way past. Reading a timer does not disturb it, so the flag is
bracketed on a clock the DMA cannot stop.

Every timed loop runs from IWRAM (`hp_stub`, copied to `0x03000700`, with
no literal pools — a pc-relative load would still point into ROM after the
copy). That puts the VCOUNT anchor within a few cycles of the line
boundary and makes the flag bracket ~10 cycles instead of the ~46 a
ROM-resident poll gives.

**The answer is `(+0 + +6) - +2`, signed, in cycles:**

* **negative** — the DMA's write landed before the CPU could see the
  H-blank flag rise. The DMA is granted on the cycle-960 edge (dingbat's
  model when the page was written).
* **positive** — the flag rose first and the DMA followed. The DMA rides
  the latched flag; subtract `+10 - +8` (the DMA's own request-to-write
  latency, measured on the same page) to get the grant instant itself.

`+4` is the poll before `+2`, so the flag's rise is bracketed to
`[+4, +2]` and the answer inherits that width. `+30` is how far the answer
moved over eight more trials.

## Slot

```
+0  (h) TM0 frozen by an H-blank DMA0's write, line 100 anchor
+2  (h) TM2 at the first poll that saw DISPSTAT bit 1 set
+4  (h) TM2 at the poll iteration before that one
+6  (h) TM2 - TM0 read back to back, no DMA armed: the start skew
+8  (h) TM2 right before the store that enables an IMMEDIATE DMA0
+10 (h) TM0 frozen by that immediate DMA's write
+12 (h) +0 for a V-blank DMA0, line 159 anchor
+14 (h) +2 for DISPSTAT bit 0
+16 (h) cycles between two VCOUNT changes (~1232; ROM-polled, so +/- one
        poll period — a sanity check on the clock, not a measurement)
+18 (h) +0 with a line-50 anchor      +20 (h) +2 with a line-50 anchor
+22 (h) +0 with the poll loop's load pointed at ROM   +24 (h) +2 likewise
+26 (h) +0 with that load at WS0 = 8 waits   +28 (h) +2 likewise
+30 (b) max-min of the answer over 8 more line-100 trials (255 = more)
+31 (b) marker 50
```

`+18`/`+20` say whether the grant is the same on every line.

`+22`-`+28` ask the question the sign test cannot: **is the grant quantised
to CPU bus cycles at all?** Each poll iteration issues one load, at IWRAM
for the normal trials and at `0x08000000` for these two — nine cycles long
once WS0 is at 8 waits — so the CPU is inside a long gamepak access for
most of the line while the anchor and the flag bracket stay in IWRAM and
stay tight. Compute the answer for each pair: if the DMA has to wait for
the end of whatever bus cycle is in flight, `+22` and especially `+26`
drift away from `+0`; if it is granted off the PPU regardless of what the
CPU is doing, all three agree inside the bracket. That distinction matters
as much as the sign does — a grant quantised to bus cycles is not a fixed
cycle in the line at all, and no single constant can model it.

The absolute stamps ride the cycle at which the boot probes reach this
page, so they may shift between consoles or builds even when the model is
identical. **Read the differences, not the absolute numbers**; the page
CRC is not a gate.

**Result** (session 6, 2026-09-16; transcription `expected/agb-sp-6.txt`,
page CRC `6E69` on the console): the answer is **-14**, bracketed by `+4`
to **[-14, +3]** — the write lands at the flag, not ~60 cycles before it.
The H-blank flag and the V-blank DMA agreed with dingbat to within a cycle
while the H-blank DMA's write came **48 cycles later**, identically on two
lines with zero spread: the grant follows the latched flag (cycle
1008-1009), not the cycle-960 edge and not the suite-fit 1012. With the
CPU loading from ROM the write moved +5, at 8 waits +2 (`+22`/`+26`), and
an immediate DMA wrote one cycle earlier than dingbat (`+10 - +8` = 7, not
8). Full table: `docs/dev/hwprobe-results-agb.md`, "32 HDMAPHASE".

dingbat's pre-run prediction was CRC **D459** (answer -62, the cycle-960
edge). `78d2a5631` moved the H-blank request to flag + 2, after which
`+0`, `+4`, `+18` and `+28` matched exactly (CRC **E217**). Later the
bus-cycle deferral was modelled (`DMA_ACCESS_WINDOW`,
`docs/dev/playtest-bugs.md` §26) and the flag moved to cycle 1007 with both DMA
requests at flag + 2 (§25). The last recorded comparison of this page
against the console had 3 bytes off (`671d1162`).

Pages 0-49 are byte-identical to the v8 build under the same emulator,
verified by capturing both and diffing every per-page CRC. The page's own
absolute stamps drift a few cycles between builds of this ROM, which is the
boot-phase sensitivity above — the answers do not.

---

# GBA probe page v9b — whose first PSG trigger dies?

Run on the AGB SP in session 6 (2026-09-16); the **Result** is below.

**51 PSGFIRST**, hex. It follows up the one question session 5 left
open.

Page 44 PSGPHASE found that every ch1 trigger which is the **first trigger
after a SOUNDCNT_X 0→1** dies at once — for lengths 1, 2 and 4 ticks alike,
with SOUNDCNT_X reading `80` right after — while a ch2 trigger two stores
later lived its full 486 polls. That rules out a length-unit effect and
leaves two candidates, which `docs/dev/hwprobe-results-agb.md` recorded as "one
follow-up page decides": is it **ch1 specific** (the sweep unit is what ch1
has and ch2 has not), or does the **first trigger of any channel** after a
master-on die?

Every row is the same poll count as page 44 — one `ldrh SOUNDCNT_X`, a test
and an increment, ~5.5 cycles on hardware — so the two pages are directly
comparable.

**One thing deliberately differs from page 44: the length.** Page 44 used
length 63, i.e. a counter of one 256 Hz tick, which makes every row a knife
edge on the frame sequencer's phase — a single spurious clock at the trigger
is the difference between the whole tone and none of it. Every row here
loads a counter of **16** ticks instead, so a spurious clock costs a
sixteenth and "died at once" (a few hundred polls or fewer) is
unmistakable against "lived" (~17 600).

## Slot

```
+0  (h) ch1 counter 16, the first trigger after a master off/on
+2  (h) ch2, likewise      +4  (h) ch3, likewise     +6  (h) ch4, likewise
+8  (h) ch1 as +0 with NR10 written 0 (sweep off, the reset state)
+10 (h) ch1 as +0 with NR10 = 0x11 (sweep period 1, shift 1: unit running)
+12 (h) ch1 triggered SECOND, after a ch2 trigger took the first slot
+14 (h) that ch2 trigger's own count
+16 (h) ch1's second trigger, its own first one discarded
+18 (h) ch1 again with no master toggle at all in front of it
+20 (b) SOUNDCNT_X as the BIOS left it, read in main before any probe
        wrote IO: does the boot state already have bit 7 set?
+21/+22/+23 (b) SOUNDCNT_X right after the +0, +2 and +6 triggers
+24 (h) ch1's first trigger with the length counter DISABLED
+26 (h) ch2's first trigger with the length counter DISABLED
+28 (h) rows that hit the poll cap; a capped row itself reads FFFF
+31 (b) marker 51
```

## How to read it

* `+2`/`+4`/`+6` all short like `+0` — the first trigger of **any** channel
  dies; a master-on leaves the whole PSG unready for one trigger.
* `+2`/`+4`/`+6` long while `+0` is short — **ch1 specific**, and then
  `+10` against `+8` says whether the sweep unit running is what does it.
* `+12` long while `+0` is short — it is the **first trigger** that dies,
  not ch1: the same channel lives once another channel has gone first.
  Together with `+16` that separates "first trigger after master-on" from
  "first trigger of this channel".
* `+24`/`+26` short — the channel is being silenced by something other than
  its length counter, since length is disabled there and nothing should ever
  clear the active bit. `FFFF` in those two is the healthy answer.
* `+20` is free evidence either way: if the BIOS hands over with bit 7
  already set, a game's own master-on is a 1→1 write, not 0→1, and the
  effect may never fire in practice.

**Result** (session 6, 2026-09-16; `expected/agb-sp-6.txt`, page CRC
`4549` on the console): **ch1 only**, and not only its first trigger. ch1's
first trigger after a master-on reads **0** (`+0`, and `+8` with NR10 = 0)
while ch2 / ch3 / ch4 live (17758 / 18807 / 18808). ch1's second trigger,
straight after its first, dies too (`+16` = 0), while a third a few dozen
cycles later lives (`+18` = 18804), as does ch1 after ch2's whole tone
(`+12`). ch1 lives with the sweep running (`+10`, NR10 = 0x11, until the
sweep overflows) and with the length enable clear (`+24` = `FFFF`).
SOUNDCNT_X reads `80` right after the `+0` trigger. Full table:
`docs/dev/hwprobe-results-agb.md`, "33 PSGFIRST".

dingbat then had no such effect (pre-run prediction CRC **FC8E**, every
channel alive). Page 52 PSGWHY found the cause, and dingbat now passes this
page's readings as dbsuite tests run from the cartridge (`apu/psg-*`,
`tests/results_dbsuite.md`); `+8`, `+12` and `+16` accept either answer
there, because the console's depends on phase (`c2040909`,
`docs/dev/playtest-bugs.md` §79).

Every row is a 16-bit poll count sized for the cartridge-resident loop; off
the cartridge see "Reading a page's counts off the link rig" above.

---

# GBA probe pages v10 — narrowing session 6's two answers

Both pages were run on 2026-09-18 over the link rig, as payloads from IWRAM
rather than from the cartridge; each has a **Result** line below.

Two hex pages, **52 PSGWHY** and **53 HDMASWEEP**. Session 6 answered the
questions pages 50 and 51 asked, and each answer left a narrower one behind.
Both pages state in advance what each candidate explanation predicts, row by
row.

## Page 52 PSGWHY — which condition kills ch1's trigger?

Pages 44 and 51 agree that a ch1 trigger soon after a SOUNDCNT_X master-on
dies while ch2, ch3 and ch4 live, that NR10 = `0x11` saves it, and that the
first two ch1 triggers die while a third lives. Re-reading them for other
causes turned up a confound neither page could see: **every ch1 row that died
on either page triggered at frequency `0x400`**, exactly half the sweep's
overflow limit `0x800`, and page 51's "lives with the length enable clear" row
wrote NR14 = `0x80`, which also dropped the frequency to 0. One candidate
covers the frequency, NR10 and channel pattern at once — ch1's sweep overflow
check runs on trigger even with shift 0, computes f + f, and at f = `0x400`
overflows — but not the trigger-count pattern.

Every row is two bytes: polls until the active bit **rose** (00 = already set
on the first read, FF = never rose within 255 polls), then polls it stayed set
÷ 256, **saturated at FF**. So a trigger that never enables reads `FF 00`, a
late one `nn xx`, and a healthy counter-16 tone `00 49` from this ROM. Because
the fall byte saturates, a faster poll loop (the same rows run as a payload
from RAM over the link rig) puts a healthy tone at `00 FF`, and there `FF` does
not mean "never expired" — `+30`, the number of rows that hit the 0x60000 poll
cap, is what says that. Page 44 and page 51 polled
only for the fall, which is why they could not tell "never enables" from
"enables late".

| row | what varies | overflow candidate predicts |
|---|---|---|
| +0 | f `0x400`, NR10 0, length on (p51 +0 again) | dies |
| +2 | f `0x3FF` | lives |
| +4 | f `0x000`, length on (de-confounds p51 +24) | lives |
| +6 | f `0x400`, length off | dies (a living tone with length off reads `00 FF`) |
| +8 | NR10 `0x08` (negate, shift 0: f − f) | lives |
| +10 | NR10 `0x10` (period 1, shift 0) | dies |
| +12 | NR10 `0x01` (shift 1: f + f/2 = `0x600`) | lives |
| +14 | f `0x7FF`, NR10 `0x01` (overflows) | dies |
| +16 | +0 two frames after the master-on | time |
| +18 | +0 sixteen frames after the master-on | time |
| +20 | ch1 retriggered straight after +0 | count |
| +22 | ch2 triggered, then ch1 at once | does ch2 count? |
| +24 | NR14 written with length on, no trigger, then triggered | does a write count? |
| +26 | +0 with SOUNDCNT_L = 0 | rules out the mixer |
| +28 | sixteen frames after master-on, SOUNDCNT_X = `0x80` again, then +0 | 0→1 edge or any write? |
| +30 | (b) rows that hit the cap | |

**Result** (run 2026-09-18 over the link rig as `psgwhy.s`, four times;
not yet run from a cartridge): "never enables" against "enables late" was a
false choice — the active bit is already set on the first poll after the
store and has fallen by the next, so the channel enables and is then
killed. The f + f candidate holds on every stable row: f = `0x400` dies,
`0x3FF` lives, `0` lives — the `0x800` boundary. On `+14` (f = `0x7FF`,
NR10 `0x01`), where the sweep overflow is unambiguous, hardware accepts the
trigger and then kills it; both emulators rejected it at the trigger and
never enabled the channel.
**Six of the fifteen rows varied between the four runs**: the payload
polls from IWRAM faster than this cartridge-resident loop was calibrated
for, so only the repeatable rows are reported, and the rest want a
cartridge run or a rate-matched delay. Recorded in
`docs/dev/hwprobe-questions.md` (the timer/PSG question) and
`docs/dev/playtest-bugs.md` §12 (`4c763b25`). dingbat's pre-run prediction was
CRC **F0A4** (every row alive except `+10` and `+14`); the PSG changes of
2026-09-25 (`60219abb`, `2f1024d3`) model ch1's shift-0 check against the
console's link-rig tables, and this page has not been re-scored since.

## Page 53 HDMASWEEP — does the DMA wait for the CPU's bus cycle?

Page 50 put the H-blank DMA's request exactly 2 cycles after the flag while
the CPU sat on 1-cycle IWRAM accesses; inside a ROM load the write moved +5,
at 8 waits +2 — one sample each, so a deferral that depends on where in the
CPU's bus cycle the request lands could not be told from a constant. Page 39
DMAOPENBUS says the same from another side: no single DMA start delay
matches both of its words (2 fixes one and breaks the other, and drops 64
mGBA Timing tests).

The page sweeps that phase one cycle at a time and measures **without an
anchor**. An H-blank DMA0 on line 159 freezes TM0 with its write; the
V-blank DMA1 at the start of line 160 freezes TM1. The CPU loops on a 32-bit
ROM load at WS0 = 8 waits until TM0 stops — so the H-blank request lands
inside that loop — then on 1-cycle IWRAM accesses until TM1 stops. A
pre-delay of k one-cycle NOPs, k = 0–13, moves where the H-blank request
lands. Every row is TM1 − TM0, the V-blank write minus the H-blank write, so
the line anchor's poll lag — which a first version of this page showed
varies by 5 cycles with the previous trial's length — cancels completely.

```
+0..+26 (14 h) TM1 - TM0, pre-delay k = 0..13, ROM load at WS0 = 8 waits
+28 (h)        the same with the loop loading from IWRAM, k = 0
+30 (b)        (IWRAM k = 7) - (IWRAM k = 0), signed
+31 (b)        marker 53
```

* **A sawtooth** — rows stepping one cycle per k and jumping back by one
  access length — means the grant waits for the end of the CPU's bus access in
  flight, and where the jumps fall says whether it waits for the whole
  32-bit load or for each halfword access.
* **A flat line** means the grant comes off the PPU and the +5/+2 on page 50
  came from something else.

**Result** (run 2026-09-18 over the link rig as `hdmasweep.s`, six
times): neither shape. k = 4, 5 and 7-13 sit at 227 with no deferral, k = 6
loses a stable **11 cycles** in all six runs, and k = 0-3 tip between the
two from run to run; the IWRAM control (`+28`) reads 227 with spread 0. So
the grant does wait on the CPU's bus access at some phases. dingbat read
226 flat (its pre-run prediction, CRC **1BA6**). A companion payload,
`hdmamul.s` (the loop on a multiply, bus idle), read 227 on every k with no
variation: the grant waits for a bus cycle and never for an internal one.
`hdmastamp.s` later showed the deferral's shape — one cycle more per cycle
the request lands earlier inside the access in flight, up to 15
(`docs/dev/playtest-bugs.md` §15). dingbat's undeferred rows reached 227 in
`bac61767`, and "grant at the end of the bus access in flight" is modelled
since §26 (`DMA_ACCESS_WINDOW`, measured with `dmaphase.s`). This page's
rows move between runs, so it is not in dbsuite and has not been re-scored
since. Recorded in `docs/dev/hwprobe-questions.md` (the H-blank DMA question)
and `docs/dev/playtest-bugs.md` §10, §12.

Pages 0-51 are byte-identical to the v9b ROM under the same emulator
build; `ALL` at the 2026-09-17 capture was **1CA7** (`-auto`, HLE BIOS).

---

# BLENDPROBE — colour special effects to the exact 5-bit value

Photographed on an AGB SP (session 1, 2026-09-16); the **Result** is under
"What the emulators output".

A separate ROM, `blendprobe.gba` (`python3 tests/roms/blendprobe.py`; the
method is in that file's docstring, the per-row layout and candidate
formulas in `blendprobe_layout.json`). It asks what alpha blend (EVA/EVB),
brighten and darken (EVY) output, and what a coefficient above 16 does,
down to the last 5-bit step.

Candidate formulas for these effects differ by **one** step, which a photo
cannot read as an absolute colour. So each patch is vertical 4-pixel stripes
alternating the effect's output (BG0 over BG1, blended by the hardware) with
a raw candidate value (BG2, never a blend target). **In the patch whose
number equals the hardware's output the stripes vanish; a step off, faint
bars show.** All colours are grey, so a step moves R, G and B together.

## Photograph

Flash `blendprobe.gba`. RIGHT/A = next page, LEFT/B = previous, 11 pages
(the number is in the footer). Photograph each page straight on.

* Page 00 CONTROL has no effect: in every row the first patch is flat by
  construction and the next two show a one- and two-step stripe. If the
  one-step patch is not visibly striped in the photo, the other pages can't
  be read from it — change exposure or console before going on.
* Pages 01-10: in each row write down the number under the **flat** patch.
  Exactly one should be flat. None flat would mean the output is not a
  plain 5-bit value per channel; several flat means the photo cannot
  resolve a step.

## What the emulators output

`python3 tests/roms/blendprobe_read.py` runs `blendprobe-auto.gba` in the
playtest drivers and prints every row's output and the formulas that match.

**Result** (session 1, 11 photos, `expected/blendprobe-agb-sp-1.txt`,
`7ee7bcfb`): per 5-bit channel, alpha is `min(31, (t·EVA + b·EVB) >> 4)`
(one truncating shift over the sum), darken `t·(16−EVY) >> 4`, brighten
`t + ((31−t)·EVY >> 4)`, and coefficients above 16 act as 16 (page 04). The
2026-09 dingbat truncated each alpha term, `(t·EVA>>4) + (b·EVB>>4)` (a
step dark), and darkened as `t − (t·EVY>>4)` (a step light); `1361b5a1`
changed both in `ppu.nim` `blend_colors`, and `blendprobe_read` now shows
dingbat flat on the hardware patch in every row. Open: on the four brighten
rows whose exact result has a fraction ≥ 0.8125 (EVY 7 t=4, t=6; EVY 3
t=10; EVY 11 t=2) red and blue null at the truncated value but green does
not (`f6c4930e`; "Brighten green anomaly" in `docs/dev/hwprobe-questions.md`).
A photo shows which 5-bit candidate matches, not the pixel value itself, so
an exact capture of the video signal is still wanted.

Both reference emulators return non-grey pixels from grey inputs on
several rows (e.g. `(17,16,17)`), i.e. they blend at finer than 5-bit
precision, so they are not evidence for any 5-bit rule. The playtest
differences that led to this ROM (Onimusha's windows, Wario Land 4's
darkened file select, Ruby's menu backdrop) were one-step rounding
differences of this kind.
