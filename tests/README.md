# tests/

The test entry points and their gotchas. Verify commands against the sources
cited; this file summarizes, it is not the authority.

## Building: `-d:test_harness` is a LINK flag first

Every headless binary here builds with `-d:test_harness`. Its real job is not
the harness-only code it gates (APU capture, `common/test_output.nim`,
savestate test hooks) — it is what stops `nim.cfg` from appending the GUI's
SDL2/OpenGL link flags (`@if not test_harness:` at the top of `nim.cfg`; the
comment above the per-suite tasks in `dingbat.nimble` spells this out).
Without it a headless binary links fine on a dev Mac with Homebrew SDL2 and
fails to link on every CI runner. Leave the flag on for any new test binary.

```
nimble test_build    # -> ./dingbat_test  ./dingbat_test_runner
nimble bench_build   # -> ./dingbat_bench
```

## `dingbat_test` — single-ROM harness (`tests/dingbat_test.nim`)

```
./dingbat_test <rom> [rom2] --mode=<mode> [options]
```

Modes (the authority is the arg parsing at the bottom of `dingbat_test.nim`):
`serial`, `sram`, `mooneye`, `mgba`, `mgba-suite`, `jsmolka`, `fuzzarm`,
`magen-green`, `magen-nored`, `gambatte`, `microtest`,
`screenshot`, `stateroundtrip`, `rewindtest`, `linktest`, `normlinktest`,
`norm32linktest`, `attachtest`, `netlink`, `speclink`, `speclinkbench`,
`rollback`, `rollbacknet`, `gblinktest`.

Options: `--timeout=<frames>`, `--frames=<warmup>`, `--screenshot=<path.ppm>`,
`--max-fails=<n>` (fuzzarm),
`--color`, `--cgb`, `--model=<dmg0|mgb|sgb|...>` (mooneye boot-state tables),
`--nosave`, `--ed-breakpoint`, `--bb-breakpoint`, `--screen-check`,
`--bios=<path>`,
`--sio=null|loopback`, and for the link modes `--listen`, `--connect`,
`--netlink-delay-ms`, `--link-contract=multi|normal|normal32`,
`--attach-after`.

These four GB flags exist because different suites end a run differently, and
each is opt-in so it cannot change how another suite is scored on the same
binary:

- `--nosave` blanks cart RAM and detaches the `.sav`. Battery-backed suite
  ROMs otherwise drop a save next to the ROM **in the shared cache dir**, and
  the next run loads it back as power-on state — non-reproducible locally, and
  in CI the `actions/cache` would carry one run's SRAM into the next.
- `--ed-breakpoint` makes the undefined opcode `0xED` end the run with the
  mooneye verdict. That was mooneye-gb's magic breakpoint in 2016, which is
  what wilbertpol's fork is built against.
- `--screen-check` adds one assertion about the panel to a run that is
  otherwise scored without looking at it: within 240 frames of the verdict the
  framebuffer must go 10 frames unchanged, and it must not be a single flat
  colour. It is deliberately *not* a glyph check — see "blargg's on-screen text
  is NOT an oracle" below for why one would be wrong. The runner turns it on
  for the eleven `blargg/cpu_instrs` rows.
- `--bb-breakpoint` makes `LD B,B` end the run whatever the registers hold.
  AGE signals failure as "any register values other than the Fibonacci ones",
  with no dedicated failure signature — without this a failing AGE ROM never
  stops and burns its whole timeout. It must stay opt-in: blargg executes
  `LD B,B` mid-test as an ordinary instruction.

`--mode=microtest` scores GBMicrotest: run `--timeout` frames, then read the
Game Boy's HRAM — `$FF80` actual, `$FF81` expected, `$FF82` verdict
(`$01` pass / `$FF` fail). Only `$FF82` is scored, per the suite's howto: some
of its tests leave `$FF80 == $FF81` on a failure. There is no completion
signal at all — the ROMs write their result and keep running — so the frame
count is the exit condition.

Typical single run (mGBA suite, ~1.5 s when waitloop detection is healthy,
~70 s when it is broken):

```
./dingbat_test /tmp/dingbat-test-roms/mgba-suite.gba --mode=mgba-suite --timeout=36000
```

`DINGBAT_NO_WAITLOOP=1` turns idle-loop fast-forward off here as it does in
`dingbat_bench`. The fast-forward SNAPS `scheduler.cycles` to the next pending
event, so any suite row that measures a *spin loop* (the Misc "H-blank bit
start" flips poll DISPSTAT and time the gaps with TM0) reads back the skip's
sampling resolution, not the emulator's timing. Set it before concluding a row
is a timing bug.

### Reading mGBA-suite rows: the columns are swapped

`doResult()` in the suite's sources takes `(preface, testName, value, expected)`
but every caller passes `(…, expected[j], measured[j])`. So in
`Foo: Got 0xAAA vs 0xBBB: FAIL` — and in the Actual/Expected columns of
`results_mgba_suite.md`, which are parsed from it — **"Got" is the ROM's
hardcoded hardware constant and "vs" is what dingbat measured.** Reading them
the natural way inverts every conclusion.

### The pinned suite ROM has two known-stale rows

`dingbat_test_runner` pins `mattrbeck/mgba-suite-auto` **v1.0**, which predates
two upstream fixture fixes and is built with a modern devkitARM. Both make rows
fail that no emulator can pass:

- `mgba-emu/suite@8c97f2c9` changed `dmaPrefetch`'s source array from `u32 a[8]`
  to `vu32 a[8]`. Without `volatile` a modern gcc dead-store-eliminates the
  initializer (its address only escapes into a volatile store), so the DMA
  moves stack garbage and "DMA Prefetch Read" can never equal `0xDEAD0000`.
- `mgba-emu/suite@a58437f3` re-measured the "H-blank bit start" constants for
  modern gcc codegen: `{0x4D1, 0x85, 0x3EC, 0xE4, 0x3EC, 0xE4, 0x3F5}` became
  `{0x4D0, 0x87, 0x3EC, 0xE5, 0x3EB, 0xE3, 0x3F3}`. v1.0 carries the old
  constants with new codegen.

Before treating a Misc row as an emulator bug, rebuild the suite (devkitARM is
enough: `make` in a checkout of the fork with those two commits applied) and
score against that. Against a corrected build dingbat is 9/10 on Misc; the
remaining "DMA Prefetch Break" is a ROM-code-layout-dependent loop iteration
count and is not comparable across builds at all. Bumping the pinned release is
the real fix.

`--mode=jsmolka` scores jsmolka/gba-tests. Every ROM in that suite reports
through one protocol (`lib/macros.inc`): the verdict lives in `r12`, the ROM
branches to a common `eval` on the **first** failing check with `r12` = that
check's number, and then spins in `b idle`. The mode runs until the PC stops
moving and reads `r12` — "All tests passed" or "Failed test N", matching what
the ROM prints on screen. It also detaches the battery file, because
`save/sram.gba`'s first check reads an untouched chip. All-or-nothing per ROM
by construction: nothing after check N runs.

```
./dingbat_test /tmp/dingbat-test-roms/gba-tests-a6447c5/gba-tests-<rev>/arm/arm.gba \
  --mode=jsmolka --timeout=600
```

`--mode=fuzzarm` scores DenSinH/FuzzARM (GPL-3.0), five prebuilt ROMs of
10 000 **randomly generated** ARM/Thumb tests each — data processing with every
shift type and shift amount, multiplies, load/stores — run from arbitrary
starting CPSR flags. Unlike jsmolka's hand-written checks this ROM does not
stop at the first failure: it reports one, waits for a button, and continues.
The mode drives that gate (holding A for one frame, releasing it the next) so
**every** failing test is reported, and reads each verdict out of the ROM's own
structured 16-word dump at `0x02000000` — state (ARM/Thumb), the opcode +
shift text, the inputs, and got-vs-expected `r3` (the shifted operand), `r4`
(the result) and CPSR. No BIOS, no PPU and no pinned frame hash sit between the
CPU and the score. "Done" is the ROM's `b .` self-branch, located by scanning
the image for its unique `0xEAFFFFFE`; do **not** substitute "PC unchanged for
two frames" (the jsmolka mode's signal) — this ROM never waits on vblank, so a
repeated frame-boundary PC is common and silently truncates the run.

Per-failure lines and a rollup by failure class (state + opcode + which of
r3/r4/CPSR disagreed, and for CPSR which flags) go to **stderr**; stdout is a
single `FUZZARM: N/10000 passed` line, which is what the runner puts in
`results.md` (it merges the two streams — unread, stderr is both lost and a
deadlock once the triage outgrows the pipe buffer — and finds the verdict by
that marker, never by position, since a block-buffered stdout can flush after
an unbuffered stderr). On a failure the runner replays the triage into its own
log.
`--max-fails=<n>` (default 500) caps the report — each failure costs two
emulated frames of button-ack.

```
./dingbat_test /tmp/dingbat-test-roms/fuzzarm-a675329-ARM_Any.gba \
  --mode=fuzzarm --timeout=20000
```

`--mode=magen-green` / `--mode=magen-nored` score alloncm/MagenTests (MIT), CGB
ROMs whose verdict is the **screen colour**, not a reference image:
`src/common.asm` fixes WHITE `$FFFF`, RED `$001F`, GREEN `$03E0`, BLUE `$7C00`,
and each test's README entry says what they mean ("the screen should be all
green"; for `hblank_vram_dma`, red = the HBlank HDMA never ran, blue = it ran
while the CPU was halted). `magen-green` requires every pixel green;
`magen-nored` requires zero red pixels, which is `bg_oam_priority`'s stated
criterion ("... with no red lines") and is the weaker of the two by design.
Both print a mealybug-style `N% correct (...)` line with the full colour
histogram, so a failure names its own cause.

This is deliberately **not** run through `--mode=screenshot`: the repo ships no
160x144 reference frame (`images/` is a 641x574 upscale, a 318x295 SameBoy
window grab, two 15x17 swatches and a photo of real hardware), and a pinned
frame hash would be a golden of dingbat's own output with nothing behind it.
`oam_internal_priority` is not run for the same reason — its only stated
criterion is prose, and red is a legitimate colour in it.

`--mode=gambatte` is the odd one out: it is **batched**, taking a list of tests
rather than a ROM (see the gambatte section below).

```
./dingbat_test --mode=gambatte --list=/tmp/gam.tsv [--gambatte-frames=15] [--dump-tiles=N]
```

Gotcha: piping through `tail`/`head` masks the exit code — a segfault (139)
looks like success. Check `$?` on the harness itself, or use `set -o pipefail`.

## `dingbat_test_runner` — full suite

Shells out to **`./dingbat_test` in the current working directory**
(`getCurrentDir()`, see `main()` in `dingbat_test_runner.nim`) — run it from
the repo root right after `nimble test_build`, or it quits with
"dingbat_test not found".

- Downloads external suites into `$DINGBAT_ROM_CACHE` (default
  `/tmp/dingbat-test-roms`): game-boy-test-roms v7.0 (Blargg, Mooneye and the
  wilbertpol fork, Mealybug, SameSuite, gambatte, GBMicrotest, age-test-roms
  and the small screenshot suites), dmg-acid2 v1.0, cgb-acid2 v1.1, the mGBA
  suite ROM from `mattrbeck/mgba-suite-auto`, and `jsmolka/gba-tests` pinned to
  the commit in `JsmolkaRev` (the upstream repo ships assembled `.gba`s, so
  nothing is built), and the five `DenSinH/FuzzARM` ROMs pinned to the commit
  in `FuzzArmRev` (`a675329cd57da48e3e406216ba2d79dd7e09ee20`; that repo has
  no release tag, so the ROMs come from raw.githubusercontent at that SHA).
  **FuzzARM's tests are randomly generated at build time**, so the committed
  pass/fail baseline is only meaningful for the pinned SHA — bumping it means
  a different 10 000 tests and a re-baseline, not a regression. Seven
  `alloncm/MagenTests` `.gbc`s also come down, from the release tag in
  `MagenRelease`. CI backs this dir with
  `actions/cache` (`.github/workflows/test.yml`) so a flaky fetch can't fail
  the run; the cache key must be bumped when a URL/version changes.
- Flags: `--bios=<path>` (mGBA suite only — the other suites are HLE/boot
  -table only in this harness), `--apu` / `--suite=apu` (opt-in Blargg
  dmg_sound/cgb_sound + SameSuite APU; deliberately outside the default run
  and it does NOT rewrite results files).

### Which suites run, and how each one is scored

Every one of these is bundled in the single game-boy-test-roms v7.0 download,
so adding them cost nothing at fetch time. **Each suite ships its own
`game-boy-test-roms-howto.md` next to its ROMs, and that file is the authority
on device, exit condition and verdict** — check it before changing a timeout or
a `--cgb`/model flag here.

| Suite | Verdict | Notes |
|---|---|---|
| Blargg `cpu_instrs`, `mem_timing` | serial text | `tmSerial` |
| Blargg `instr_timing`, `mem_timing-2`, `oam_bug`, `halt_bug`, `interrupt_time` | `$A000` status + `DEB061` | `tmSram`; `interrupt_time` is CGB-only (`--cgb`), `oam_bug` needs ~21 emulated seconds |
| Mooneye (Gekkio) | `LD B,B` + Fibonacci regs | `tmMooneye`; `manual-only/sprite_priority` is a screenshot |
| Mooneye (wilbertpol fork) | opcode `0xED` + Fibonacci regs | `--ed-breakpoint`; `utils/` and `logic-analysis/` have no verdict and are skipped |
| AGE (`age-test-roms`) | `LD B,B` + Fibonacci regs, or screenshot | `--bb-breakpoint`; the `ncm*` (CGB in non-CGB mode) variants are skipped — that device is not modeled |
| GBMicrotest | HRAM `$FF82` | `--mode=microtest`, 2 frames (30 for `is_if_set_during_ime0`) |
| Mealybug Tearoom, Acid2, cgb-acid-hell, bully, strikethrough, scribbltests, turtle-tests, little-things-gb, mbc3-tester | framebuffer vs bundled PNG | see below |
| MagenTests | screen colour | `--mode=magen-green` / `--mode=magen-nored`, see above |
| gambatte | glyph OCR of the on-screen result | batched via `--mode=gambatte --list=`; aggregated one row per subdirectory, see below |
| mGBA suite, jsmolka gba-tests, FuzzARM | GBA; unchanged | see above |

#### blargg's on-screen text is NOT an oracle — score these on serial only

Blargg's suites are scored by their serial output, and it is tempting to add a
screenshot check on top ("the ROM prints the same string to both, so the screen
must say Passed too"). **It does not, and hardware agrees.** Measured
2026-08-02 against SameBoy (CGB-E, real CGB boot ROM, `tools/gbfuzz`
`sameboy_runner` plus an execution-callback probe):

- Blargg's runtime switches the CGB to **double speed** during init
  (`init_crc` calls `set_double_speed` and never switches back), so everything
  the console prints afterwards is printed at double speed.
- The console's "wait for VBlank" is a **bounded** poll — `ld bc,$FB1E` /
  `inc bc` / `ldh a,($44)` / `cp $90`, 1250 iterations of 14 M-cycles. At
  single speed that budget is 70 000 T-cycles, marginally more than one
  70 224-dot frame, so it effectively always succeeds. At double speed the same
  1250 iterations are only **35 000 dots — half a frame** — so it times out
  whenever the print is entered in the wrong half, and the console then blits
  its 20-byte row straight into the tile map with the LCD on, straddling
  mode 3.
- Those writes are then correctly refused (Pan Docs: VRAM is not CPU-accessible
  in mode 3). **SameBoy loses them too**: on `06-ld r,r` it drops 28 of the
  160 blitted cells, on `03-op sp,hl` it drops 32 including the `P`, `a` and
  `s` of "Passed" — that ROM's result line never reaches the screen on SameBoy
  at all, at any frame count.
- *Which* cells are lost is decided by the sub-scanline phase of the console
  blit, so it differs between any two emulators that are not bit-identical in
  timing. A screen check would therefore fail on correct emulation, and it can
  be "fixed" by any constant that nudges the phase — which is exactly the trap.

There is consequently **no honest in-repo oracle for the blargg screen**: a
captured golden would be a golden of our own behaviour, and comparing the glyph
area to the serial text asserts something hardware does not do. What the runner
does assert is the weaker thing that *is* true regardless of the race: the
panel settles and is not blank (`--screen-check`, above).

The real gate for this class of bug is cross-emulator: `tools/gbfuzz` for the
full library, `tools/gbgate` for a two-build framebuffer diff, and for blargg
specifically, `sameboy_runner <rom> <bootdir> <prefix> "" 1200` against
`dingbat_test --mode=screenshot --timeout=1200 --bios=<cgb_boot.bin>`. At the
current `SPEED_SWITCH_STALL_T` dingbat's frame is pixel-identical to SameBoy's
on all eleven `cpu_instrs` ROMs; that comparison is what caught the stall being
eight times short, and it is the check to re-run after any GB timing change.

Screenshot notes:

- The reference PNGs already match what `write_ppm` produces (DMG shades
  `#000000/#555555/#AAAAAA/#FFFFFF`, CGB channels expanded `(X<<3)|(X>>2)`),
  so no palette work is needed. A screenshot suite comparing at ~0% is a frame
  count, a device, or a **PNG format** problem, not a color one —
  `png_reader.nim` covers greyscale (1/2/4/8-bit), greyscale+alpha, RGB, RGBA
  and indexed, and anything outside that now raises rather than silently
  decoding to noise.
- "CGB compatibility mode" references (a CGB booting a non-CGB cart: the AGE
  `ncm*` images, `mbc3-tester-cgb`, `rtc3test`'s CGB set) use a third palette
  and are **not** scored — dingbat has no such device mode.
- `strikethrough` and `bully` are `$80` CGB-capable carts, so they always boot
  CGB here; their `-dmg` references would need a CGB cart forced into DMG mode,
  which `--cgb` (force CGB *on*) cannot express.

Not integrated: `rtc3test` and `little-things-gb/tellinglys` both need scripted
button presses (rtc3test uses A / ↓A / ↓↓A to pick one of three sub-tests) and
`dingbat_test` has no input scripting — only `dingbat_bench` does, via its
`"600:START,700:A"` script format. Porting that parser across would unblock
both, and rtc3test is worth it: dingbat has a real MBC3 RTC. `scribbltests`
`fairylake`/`winpos` and Mooneye's `logic-analysis/` ship no reference at all.

**Exit-code pitfall:** the runner exits non-zero only on *regressions* —
tests that pass in the committed `tests/results.md` and fail now. Exit 0 does
**not** mean everything passed: the baseline carries a lot of known failures
(Total 934, Pass 476 as of the current committed `results.md`, most of them the
PPU-timing suites added on purpose to measure them). 48 of those rows are
aggregated gambatte subdirectories, standing for 2,632/5,005 individual tests
passing — and those 48 gate on the pass COUNT, not just the pass/fail bit. All 13 jsmolka rows, all 5 FuzzARM rows
and 6 of the 7 MagenTests rows are green in it, so any of them going red *is* a
CI failure. `magen/hblank_vram_dma` is baselined failing: dingbat runs the
HBlank VRAM DMA while the CPU is halted.

The regression key is the **full** test name — `blargg/oam_bug/1-lcd_sync`,
not `1-lcd_sync` — matching the row exactly as `results.md` writes it. With
several forks of the same suite in here (mooneye vs mooneye-wilbertpol,
`mem_timing` vs `mem_timing-2`) anything shorter collides across suites and
silently mis-keys the gate. A name absent from the baseline is simply not
gated, which is why adding suites means regenerating and committing
`results.md` in the same change.

**Parallel-agent hazard:** the runner shards the gambatte batch through
`$TMPDIR/dingbat-gambatte` and wipes that directory on entry. Two runners going
at once in different worktrees therefore delete each other's shard output, and
the victim scores every not-yet-flushed row 0 ("harness produced no verdict").
Run with a private `TMPDIR` if anything else may be running the suite.

**Results-file caveat:** `tests/results.md`, `tests/results_mgba_suite.md` and
`tests/results_gambatte.md` are committed baselines, and every run **rewrites
all three in place** (that is also where the regression comparison reads
from). After a local run, `git checkout -- tests/results.md
tests/results_mgba_suite.md tests/results_gambatte.md` unless you are
intentionally updating the baseline.

`tests/golden/` holds per-row mGBA-suite captures (passing *and* failing
rows) for diff-based timing work — see `tests/golden/README.md`.

## The gambatte suite

3,524 ROMs inside the same game-boy-test-roms bundle as Blargg/Mooneye/
Mealybug/SameSuite (no extra download, no cache-key bump), expanding to
**5,005 scored rows**. Default-on in the runner. Verdict mechanism, per the
bundle's own `gambatte/game-boy-test-roms-howto.md` and gambatte-core's
`test/testrunner.cpp`:

- **Fixed exit condition.** Every ROM runs exactly **15 LCD frames**
  (1,053,360 clocks, ~252 ms emulated) from the post-boot state, then the
  frame is read. Not "run until something happens". The suite is insensitive
  to the exact count — 14, 16 and 30 frames all score identically — because
  every ROM has settled and holds its result.
- **The device is in the filename.** `dmg08` = run as a DMG, `cgb04c` = run as
  a CGB; most ROMs carry both tags and are two rows. Nearly all of them ship a
  CGB cart header even for their DMG half, which is why `new_gb` grew
  `force_dmg` (gambatte selects the device from its loader flag, not the
  header).
- **The expected value is in the filename too**, as `_out<hex>` (1 to 20 hex
  digits), and can differ per device
  (`..._dmg08_out2_cgb04c_out0.gbc`). The ROM draws that hex string as 8×8
  glyphs along the top-left row of the screen; scoring compares those tiles
  against the glyph table in `dingbat_test.nim`. An `x` in front of a tag
  (`_xout0`, `_xdmg08`) means "not a test" and is skipped.
- **Some ROMs ship a reference PNG** instead, named `<rom>_dmg08.png` /
  `_cgb04c.png` / `_dmg08_cgb04c.png`, scored on the whole 160×144 frame.
  Colours are compared the way gambatte compares them: masked to 0xF8F8F8
  (the top 5 bits per channel — exactly what a BGR555 framebuffer carries),
  with gambatte's CGB colour-correction formulae applied on the CGB side and
  the plain `#000000/#555555/#AAAAAA/#FFFFFF` shades on the DMG side.

**Debugging a `png` row.** Its verdict is a single integer, so set
`DINGBAT_GAM_DUMP=<dir>` to also write every scored frame as a PPM in the
comparison's own colour space, and diff that against the bundled reference.
For the mid-scanline-write families (`bgtiledata`, `bgtilemap`,
`scx_during_m3`, `scy`) pair it with `-d:gb_m3_trace -d:GB_TRACE_LY=<n>`,
which prints one line per mode-3 dot of line `n` plus the LCDC writes landing
inside it: the reference tells you which pixel the write reached, the trace
tells you which fetcher step consumed it, and the two together give the
pipeline's phase against the CPU. `-d:M3_PIPE_DELAY=<n>` then sweeps that
phase. See the KNOWN RESIDUAL note in `src/dingbat/gb/fifo_ppu.nim`.

**Glyph table provenance.** gambatte-core is GPL-2.0 and this tree is MIT, so
its table is not ours to vendor. `GambatteGlyphs` was *harvested* instead:
`--dump-tiles=N` prints the raw top-row tiles, and running it over a few
hundred ROMs whose filenames name the digits they display resolves all 16
shapes by majority vote. Regenerate that way if a future bundle changes the
font (only 4 rows out of 5,005 currently decode to an unrecognised glyph).

**Not scored:** the 220 `_outaudio0/1` rows and gambatte's AGB column. Gambatte
decides an audio row by asking whether all 35,112 samples of the final frame
are identical — a 2 MHz stream, one sample per two clocks — and several of
those ROMs turn on a difference lasting a handful of clocks. dingbat's APU
emits at 32,768 Hz, 64× coarser, so a faithful verdict is not available from
the sample path as it stands. gambatte's own runner marks the AGB column
"FIXME: Actual AGB results" and feeds it the CGB expectations.

**Batching.** One `dingbat_test` process per ROM would cost more than the
emulation (each row is 15 frames, a few ms). The runner shards the rows
round-robin across `countProcessors()` processes, each running one
`--mode=gambatte --list=...` batch in-process with a fresh `GB` per row. The
whole suite is ~34 s in one process, ~7 s sharded, and adds ~7 s to the full
runner (8 s → 15 s here). Independence was verified two ways: a shuffled list
reproduces every verdict *and every detail string* exactly, and the sharded
run's totals match the single-process run's.

**Reporting.** 5,005 rows would drown `results.md`, so it carries one row per
gambatte subdirectory (`| oamdma | 👀 223/811 passed |`) and the per-test
detail goes to `tests/results_gambatte.md`. Those aggregated rows gate on the
pass **count**, not just the pass/fail bit — `load_previous_counts` parses
`N/M passed` back out of the committed `results.md`, so 223 → 222 is a
regression even though the row was already red. (`always_detail` on
`TestResult` is what keeps the count in the file for rows that pass.)

## `dingbat_bench` — headless benchmark

```
./dingbat_bench <rom> [frames] [warmup_frames] [input_script]
```

Input scripts drive the keypad (`"600:START,700:A,900:RIGHT:120"`). Env vars
(see the top of `dingbat_bench.nim` for the full, commented list):
`DINGBAT_BENCH_HASH=1` (per-frame FNV framebuffer hash for pixel-exact A/B),
`DINGBAT_BENCH_BIOS`, `DINGBAT_BENCH_STATE` (start from a save state),
`DINGBAT_NO_WAITLOOP=1` (hold waitloop fast-forward constant when A/B-ing
scheduler changes), `DINGBAT_MP2K*` (audio-HLE experiments).

## Nimble tasks (`dingbat.nimble`)

`test_build`, `bench_build`, plus compile-and-run per-suite tasks (each is
also a CI step with a rationale comment in `.github/workflows/test.yml`):

- `test_timestretch` — WSOLA unit test.
- `test_ppucomposite` — GBA compositor invariants (self-comparing, no ROMs).
- `test_ppubgunpack` — 4bpp BG SWAR unpack vs scalar oracle
  (`DINGBAT_BG4_EXHAUSTIVE=1` for the full 2^32 sweep).
- `test_ppuobjlist` — per-line OBJ candidate list differential fuzz.
- `test_savestate_compat` — loads the reference states in `tests/states/`
  and pins EventType ordinals / payload revisions at compile time.
- `test_cheats` — cheat engine unit + integration tests.
- `test_rewind` — rewind-ring properties: `snapshot_at(k)` byte-equal to the
  k-th chain walk at every depth (through eviction and across a pop/push
  seam), keyframe seeks reproducing the walk, thumbnails evicted in lockstep
  with their snapshots, `mem_used` covering the side tables. No ROMs.

Not in tasks but in CI: the link-acceptance battery (`linktest`,
`speclink`, `netlink`, `rollback` modes over `tests/roms/*.gba`) — copy the
exact invocations from `.github/workflows/test.yml`.

## Where test ROMs come from

- `tests/roms/` — committed homebrew ROMs **with their sources**: GBA `.s`
  files (build line in each header: `arm-none-eabi-as` + `objcopy`; they run
  headerless under the HLE BIOS) and GB `.py` generators (hand-assembled
  SM83, no toolchain needed — run the script to regenerate the ROM next to
  it).
- External suites — never committed; downloaded/cached by the runner as
  above. CI's cache and key rules are in `.github/workflows/test.yml`.
- Official BIOS/boot ROMs are **never** in the repo (.gitignore blocks them);
  pass paths via `--bios=`.

## Web test suite

Runs from the repo root, no npm install needed for the unit tier:

```
node --test web/tests/*.test.mjs   # node:vm harness over the REAL web/index.js
```

`web/tests/helpers.mjs` evaluates the unmodified `index.js` with stubbed
browser globals. **Stub rule:** any new module-scope browser global used by
`index.js` must be stubbed in `helpers.mjs`, or every test in the suite dies
at eval time. Details + the fake-IndexedDB/fetch approach:
`web/tests/README.md`.

The static gate: `npx tsc -p web/types/tsconfig.{main,embed,sw}.json` checks
the shipped JS as-is (JSDoc + checkJs); `node web/types/gen-emdts.mjs
--check` fails if `em.d.ts` is stale against `src/dingbat_wasm.nim`'s
`{.exportc.}` exports. Browser-only tiers (`web/render.test.mjs`,
`web/manualpair.test.mjs` via Playwright Chromium, `web/uv.test.mjs`,
`web/signaling/server.test.mjs`) — invocations in the workflow file.
