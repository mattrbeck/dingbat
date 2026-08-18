# Folder 9 — g1: does the CGB carry a halt-wake PPU phase?

Two ROMs, two photographs, ten minutes. This is the highest-value shot in
`docs/hwprobe-questions.md` right now: it arbitrates a constant that is **already
shipping on main** and that two of our own instruments disagree about.

## What to do

1. Flash **`g1_scx0.gb`**. Run it on the **GBA SP** — the same console as the
   probe (e)/(f) sessions (IMG_3803-3808, IMG_3833-3840), so the readings are
   directly comparable.
2. It boots straight into the picture. **Do not touch the d-pad** — the ROM has
   its settings baked in, and the two hex bytes in the top-left should read
   `00 FF`. Photograph the whole screen, square-on, screen filling the frame.
3. Flash **`g1_scx4.gb`**, confirm the header reads `04 FF`, photograph again.
4. Send me the two photos, or drop them in a folder and tell me where.

No button presses, no timing, nothing to hold down.

## What it settles

The picture is a staircase of vertical bars. What matters is the **x column of
each bar**, which the reader takes relative to the header glyphs in the same
frame — so the photo needs no registration and a hand-held phone shot is fine.

Three candidates, **8 pixels apart** — a whole tile, tellable by eye against the
PNGs in this folder:

| SCX | `CGB_HALT_PPU_LEAD=0` | `=1` — what main ships | SameBoy |
|---|---|---|---|
| 0 | `32 40 40 48 48 56 ...` | `40 40 48 48 56 56 ...` | `24 32 32 40 40 48 ...` |
| 4 | `28 36 36 44 44 52 ...` | `36 36 44 44 52 52 ...` | `20 28 28 36 36 44 ...` |

`predicted-*.png` are those three screens rendered at 3x. The first bar's left
edge is the quickest thing to compare.

## Why it is worth your time

`cgb-acid-hell` is the 261st shootout row and it closed on
`CGB_HALT_PPU_LEAD = 1` — the CGB's PPU running an M-cycle ahead of the CPU
after a STAT/LYC halt wake, except on the LY 153->0 snapback. Two published
ROMs agree (acid-hell itself, and daid's `ppu_scanline_bgp` swept over its
anchor line), and the shootout is 261/261 with it.

**But probe (e) — this ROM — disagrees.** Scored against SameBoy it says the
lead moves us *away* from the oracle on a normal line. It also carries an
unexplained 2-3 M offset from SameBoy that predates all of this work, which is
why it does not currently get a vote. Notice in the table above that **neither
dingbat build matches SameBoy even with the lead off**: that gap is the
unexplained offset, and it is 8 px wide here.

So one photograph answers two questions at once:

* **reads 24 / 20** — SameBoy is right, both dingbat builds are wrong on this
  probe, and the thing to chase is probe (e)'s own baseline rather than the
  halt lead. This is the most likely outcome, and it would mean several older
  conclusions drawn from this probe's numbers need re-reading.
* **reads 32 / 28** — lead 0 is right here, which contradicts daid and puts the
  shipped constant back in question. The honest response would be to revert it
  and take `cgb-acid-hell` back to 2 px: 261/261 is not worth a constant
  hardware refuses.
* **reads 40 / 36** — the shipping build is right and SameBoy is wrong here,
  which would be the first time the oracle has missed anything in this work.

## Rebuilding these

    tools/gbprobe/mk.sh probe_e_objgrid -DSCX_DEFAULT=0 -DOBJX_DEFAULT='$FF'
    tools/gbprobe/mk.sh probe_e_objgrid -DSCX_DEFAULT=4 -DOBJX_DEFAULT='$FF'

Everything else is the shipping default, including `ANCHOR_LINE = 16` — the
STAT-LYC halt whose phase is the whole question.

## Reading a photo

    python3 tools/gbprobe/read_probe_e.py <photo.jpg>

and compare its `raw cols` line to the table above.
