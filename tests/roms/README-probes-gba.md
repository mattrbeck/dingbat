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

`ALL` for this build is **F1AF** (manual) / **38FC** (`-auto`); the two
binaries differ in a few pipeline/open-bus bytes, as they always have.

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
