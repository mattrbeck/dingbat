# gbdiff — differential GB/GBC oracle against docboy

A black-box differential harness between dingbat and
[docboy](https://github.com/Docheinstein/docboy), currently the most accurate
emulator on the [gbdev shootout](https://gbdev.io/GBEmulatorShootout/).
It is the CGB-capable second opinion this repo did not have: our Mealybug and
GBMicrotest references are DMG-only, so nothing in the suite could arbitrate a
CGB question on its own.

Same shape as `tools/gbfuzz` (cross-emulator screenshot comparison) and
`tools/gbgate` (per-frame framebuffer A/B); it reuses gbfuzz's
`dingbat_gb_nav` as the dingbat side rather than adding a second runner that
could drift out of step with it.

## Ground rules

docboy is **MIT licensed** — permissive, not copyleft. That is not a licence to
copy from it, and this harness does not:

* **No code is taken from docboy**, adapted or otherwise. The only file here
  that is compiled against it, `docboy_gb_runner.cpp`, is written from scratch
  against its public `Core`/`Lcd` interface, and does nothing but drive frames
  and write screenshots.
* **"docboy does it this way" is not a reason for a change.** A divergence is
  *evidence that something is worth looking at*, nothing more. The behaviour
  that lands in `src/` has to be derived from Pan Docs, from datasheets, and
  from the test ROMs' own bracketing families, and the commit has to cite
  *that*. This is the standing rule for the project (see `tests/README.md`);
  reading docboy's source to work out where to look is private investigation
  and stays out of the repo.
* On several of the divergences found so far **docboy is the one that is
  wrong**, which is the practical reason the rule is not merely bureaucratic.

## Build

    git clone https://github.com/Docheinstein/docboy --recurse-submodules ~/code/docboy
    tools/gbdiff/build.sh          # GBDIFF_DOCBOY=<path> to point elsewhere

This produces `docboy_gb_runner_dmg` and `docboy_gb_runner_cgb` (docboy picks
its model at compile time, so it needs two binaries; the drivers route each ROM
by the cartridge CGB flag at `$143` bit 7) and rebuilds
`tools/gbfuzz/dingbat_gb_nav`.

The runner is staged into the docboy checkout as an extra frontend target
rather than compiled standalone, so it inherits the exact `PUBLIC` compile
definitions `libdocboy` was built with. Several of them (`ENABLE_CGB`,
`ENABLE_BOOTROM`) change struct layouts, and a standalone compile that got one
wrong would link cleanly and then read garbage.

Two build settings are correctness requirements, not preferences:

* `ENABLE_RTC_SYSTEM_TIME=OFF` — it defaults **on** and seeds the MBC3 clock
  from the wall clock. Left on, an RTC title differs from itself between runs.
* `ENABLE_BOOTROM=ON` — see below.

Boot ROMs are **never committed** (`.gitignore` blocks them). Put `dmg_boot.bin`
and `cgb_boot.bin` in a directory outside the repo and pass it as `--boot`.

## What makes the comparison mean anything

**Boot ROM parity.** Both emulators play the boot ROM from power-on and count
frame 0 from there. This is the lesson `tools/gbfuzz` records: each emulator's
skip-boot shortcut lands on a different cycle, and the resulting animation
phase drift swamps every real difference, so a skip-boot comparison is worth
nothing. docboy's boot ROM support is compile-time, so there is no skip-boot
mode here at all.

**Palette normalisation.** Every runner emits the same bytes for the same
picture, so a difference is a difference and not a house style:

* DMG — docboy's LCD palette is set to the identity, so the shade index comes
  back out of the framebuffer untouched and the runner writes the shared
  `FF/AD/52/00` grey ramp for it (the same ramp gbfuzz's three runners use;
  the values survive the 8→5→8 bit round trip mGBA applies to its DMG
  palette). No emulator's idea of what a DMG screen looks like enters the
  comparison.
* CGB — docboy's palette is a 32768-entry RGB555→output LUT, so it is set to
  the identity too. The framebuffer word is then the raw CGB palette word, red
  in the low 5 bits, which is bit-for-bit the layout dingbat's framebuffer
  already uses.

**Determinism.** docboy zero-fills power-up RAM, which is what dingbat does
too, so neither needs SameBoy's `GB_random_set_enabled(false)` treatment.

## Tools

| | |
|---|---|
| `build.sh` | build both docboy runners and `dingbat_gb_nav` |
| `sweep.py` | run a ROM list in both, compare screenshots per frame, classify |
| `probe.py` | reduce one divergence: is it PHASE or CONTENT? |
| `ppmdiff.py` | differing pixel count, bounding box, 3-panel PNG |
| `readout.py` | read a gambatte ROM's on-screen hex result out of a screenshot |
| `gambatte_ab.py` | cross-tabulate both emulators against gambatte's *filename* |
| `gdma_sweep.sh` | measure `GDMA_SETUP_MCYCLES` against its whole ROM family |

Typical use:

    tools/gbdiff/sweep.py roms.txt /tmp/w --frames 1200 --step 30 --keep-ppm
    tools/gbdiff/probe.py "$ROM" 420 --window 3 --png
    tools/gbdiff/gambatte_ab.py cgb-roms.txt /tmp/ab --dev cgb

## PHASE vs CONTENT, and why it has to be asked first

`probe.py` shoots a window of frames in both emulators and reports which
dingbat frame equals which docboy frame:

* **PHASE** — dingbat frame `F` equals docboy frame `F+k` for a constant `k`.
  The two render the same thing; one is running ahead.
* **CONTENT** — no offset matches. Genuinely different pixels; a candidate bug.

**A PHASE result is usually a harness artifact, not a dingbat bug**, and on the
LCD-off path it is *always* one. With the LCD off, docboy's `Core::frame()`
runs a fixed 16416 M-cycles and returns — an artificial frame, 65664 T-cycles
against a real frame's 70224, and by its own comment a way to keep the UI
responsive rather than a claim about hardware. Real hardware produces no frames
at all with the LCD off. So "how many frames pass while the LCD is off" is a
frontend convention on both sides, and a title that toggles the LCD accumulates
a frame of skew that means nothing.

This is why the commercial-title sweep reports CGB titles like Pokémon Crystal,
Pokémon Silver and Shantae as `+1` PHASE while every DMG title is byte
identical for 1200 frames: not a pacing bug, a convention difference that only
bites titles which blank the screen. **Frame-indexed comparison is only sound
while the LCD stays on.** For genuine frame-pacing questions the oracle is
SameBoy via `tools/gbfuzz/{sameboy,dingbat_gb}_fps`, which measure presents per
second of emulated time and were built for exactly that.

## gambatte ROMs: the filename is the oracle, not docboy

gambatte's test ROMs render their result as hex glyphs and encode the expected
value per device in the filename (`..._cgb04c_out3`), so a screenshot plus a
filename adjudicates itself. `gambatte_ab.py` scores **both** emulators against
that filename and reports a four-way verdict:

| verdict | meaning |
|---|---|
| `BOTH_PASS` | nothing to see |
| `DOCBOY_ONLY` | **the valuable column** — correct behaviour is demonstrably reachable, so dingbat is worth investigating |
| `DINGBAT_ONLY` | a docboy bug; no action here |
| `BOTH_FAIL` | neither matches hardware |

`BOTH_FAIL` is worth reading closely when the ROM belongs to a `_1`/`_2`
bracketing family: if the two emulators give the family's two different
answers they **bracket** the hardware transition point, and neither can be
used to correct the other. `window/late_disable_ds_{1,2}` is exactly that —
dingbat answers `0` to both members, docboy answers `3` to both, hardware
changes answer between them, so the two are wrong in opposite directions and
docboy is no oracle for it.

A row is only scored if the reading is the same at two different frames, so a
still-settling display is reported `UNSTABLE` rather than scored off a
half-drawn screen.

## Measuring a constant from a family

When a divergence reduces to "dingbat is N M-cycles off", the family measures
N; do not fit it to one row. `gdma_sweep.sh` is the worked example: it rebuilds
at each setting of `GDMA_SETUP_MCYCLES` and reads out all nine
`gdma_cycles_*` pairs, and a setting only counts if **every** pair lands on the
right side of its own flip point at that one value. A value that fixes the
`_2` members by pushing the `_1` members past their edge has measured nothing.
`tools/gbppu/famflip.py` does the same job for the PPU write-latency families.

## Hygiene this encodes

Both of these have burned this project before, so they are built in:

* ROMs are **symlinked** into a per-emulator directory, never copied, and each
  emulator gets its own — dingbat derives the `.sav` path from the ROM path, so
  a battery-backed game writes its save next to the *symlink*. Saves are
  deleted before every ROM so a sweep cannot carry state between titles.
* Each child runs under its own `TMPDIR`, with a timeout, killed by process
  group, so a hung ROM cannot wedge the harness.
* ROM lists are read line by line, so a path with a space cannot truncate a
  sweep.
* Parallel workers take scratch directories from a free list rather than
  indexing by ROM number — a thread pool gives no guarantee which task lands on
  which thread, and two live tasks sharing a directory would overwrite each
  other's screenshots.

## What the first sweep found

Over the **503 CGB rows dingbat fails** in the seven priority directories
(`window`, `oamdma`, `dma`, `scx_during_m3`, `sprites`, `speedchange`, `scy`),
scored against the filenames:

| verdict | rows |
|---|---|
| `DOCBOY_ONLY` | 296 |
| `BOTH_FAIL` | 191 |
| `BOTH_PASS` | 14 |
| `DINGBAT_ONLY` | 2 |

So on **59% of the CGB rows dingbat gets wrong, the correct answer is
demonstrably reachable** — these are dingbat bugs, not unknowable hardware.
Where that work is, by directory:

| directory | `DOCBOY_ONLY` / failing CGB rows |
|---|---|
| `sprites` | 62 / 65 |
| `speedchange` | 83 / 102 |
| `dma` | 71 / 117 |
| `window` | 63 / 103 |
| `oamdma` | 17 / 114 |

`oamdma` is the outlier and the reading is the useful part: it is mostly
`BOTH_FAIL`, and 92 of those rows are ones where the two emulators give
*different* wrong answers — dominated by the `oamdma_src*_busypop/busypush`
bus-conflict family. Nobody has that right, so docboy is not an oracle there.
`scx_during_m3` and `scy` contribute almost nothing here because nearly all of
their failures are on the **DMG** row, not the CGB one.

Caveats on those numbers: 10 of the 296 `DOCBOY_ONLY` rows are ones where
dingbat's glyph did not decode (`?`), which always scores as a miss, so treat
296 as an upper bound with a ~3% margin. The 14 `BOTH_PASS` rows are ROMs
`tests/results_gambatte.md` lists as failing but which pass here — four are the
HDMA1-4 fix, the rest are framing differences between this harness (boot ROM,
read at frames 200/300) and the suite's own runner, and are worth a look before
trusting a single row either way.

## Known limits

* docboy rejects cartridge types it does not implement (`unknown MBC type:
  0xFC` for the Game Boy Camera), reported as `ERROR`, not a divergence.
* SGB is not comparable; neither runner emits the bordered 256x224 output.
* Audio is not compared here — `ENABLE_AUDIO` is off in both docboy builds.
  `tools/gbfuzz`'s PCM path and `tools/pcmdiff.py` cover that against SameBoy.
* The `.mem` triage dump (`GBDIFF_DUMP=1`) omits the palette blocks that
  gbfuzz's dumps carry: they are private to docboy's `Ppu` and reaching them
  would mean building against its test-only friend declarations.
