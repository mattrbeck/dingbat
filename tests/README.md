# tests/

The test entry points and their gotchas. This file summarises; the sources it cites are
the authority.

## Building: `-d:test_harness` is a link flag first

Every headless binary builds with `-d:test_harness`. Besides gating harness-only code
(APU capture, `common/test_output.nim`, savestate hooks) it stops `nim.cfg` from
appending the GUI's SDL2/OpenGL link flags (`@if not test_harness:`). Without it a
headless binary links on a dev Mac with Homebrew SDL2 and fails on every CI runner.

```
nimble test_build    # -> ./dingbat_test  ./dingbat_test_runner
nimble bench_build   # -> ./dingbat_bench
```

## `dingbat_test` — single-ROM harness (`tests/dingbat_test.nim`)

```
./dingbat_test <rom> [rom2] --mode=<mode> [options]
```

Modes (authority: the arg parsing at the bottom of `dingbat_test.nim`): `serial`,
`sram`, `mooneye`, `mgba`, `mgba-suite`, `jsmolka`, `fuzzarm`, `magen-green`,
`magen-nored`, `gambatte`, `microtest`, `screenshot`, `stateroundtrip`, `rewindtest`,
`linktest`, `normlinktest`, `norm32linktest`, `attachtest`, `netlink`, `speclink`,
`speclinkbench`, `rollback`, `rollbacknet`, `gblinktest`.

Options: `--timeout=<frames>`, `--frames=<warmup>`, `--screenshot=<path.ppm>`,
`--max-fails=<n>` (fuzzarm), `--color`, `--dmg`, `--cgb`, `--sgb`, `--cgb-rev=<0|A|B|C|D|E>`,
`--model=<dmg0|mgb|sgb|cgb0|...>` (boot table + `GbQuirks` revision), `--nosave`,
`--ed-breakpoint`, `--bb-breakpoint`, `--screen-check`, `--bios=<path>`,
`--sio=null|loopback`, and for the link modes `--listen`, `--connect`,
`--netlink-delay-ms`, `--link-contract=multi|normal|normal32`, `--attach-after`.

Four GB flags exist because suites end a run differently; each is opt-in so it cannot
change how another suite is scored:

- `--nosave` blanks cart RAM and detaches the `.sav`. Battery-backed suite ROMs otherwise
  drop a save in the shared cache dir and the next run loads it as power-on state (in CI
  `actions/cache` would carry it between runs).
- `--ed-breakpoint` makes undefined opcode `0xED` end the run with the mooneye verdict
  (mooneye-gb's 2016 magic breakpoint, which wilbertpol's fork targets).
- `--screen-check` asserts the panel settles (10 unchanged frames within 240 of the
  verdict) and is not one flat colour. Deliberately not a glyph check — see "blargg's
  on-screen text is not an oracle". On for the eleven `blargg/cpu_instrs` rows.
- `--bb-breakpoint` makes `LD B,B` end the run whatever the registers hold. AGE signals
  failure as "registers not Fibonacci" with no failure signature, so a failing AGE ROM
  otherwise burns its timeout. Must stay opt-in: blargg executes `LD B,B` mid-test.

`--mode=microtest` runs `--timeout` frames then reads HRAM `$FF82` (`$01` pass / `$FF`
fail; `$FF80`/`$FF81` are actual/expected but the howto says only `$FF82` is reliable).
The ROMs never stop, so the frame count is the exit condition.

### mGBA suite

```
./dingbat_test /tmp/dingbat-test-roms/mgba-suite.gba --mode=mgba-suite --timeout=36000
```

~1.5 s with waitloop detection healthy, ~70 s without. `DINGBAT_NO_WAITLOOP=1` turns
idle-loop fast-forward off. The fast-forward snaps `scheduler.cycles` to the next pending
event, so any row that times a spin loop (the Misc "H-blank bit start" flips poll DISPSTAT
and time gaps with TM0) reads back the skip's sampling resolution; set it before
concluding a row is a timing bug. With the skip off the six flips' residuals are
non-uniform in sign, so the remainder is real DISPSTAT/H-blank timing error, unattributed.
`-d:gbaskipcap=<n>` bounds the skip by a constant instead of the PSG's next deadline.

**Argument order differs in one section.** Every section prints failures through a local
`doResult()` (`mattrbeck/mgba-suite-auto`, one per `src/*.c`). `src/misc-edge.c` passes
`(expected, measured)`, so in the **Misc** section `Got X vs Y` means X is the hardware
constant and Y dingbat's value. Everywhere else — including Timing, where rows are a cycle
or two apart — `Got` is dingbat's measurement and `vs` the hardware constant.
`results_mgba_suite.md`'s Actual/Expected columns are parsed from these lines and inherit
the asymmetry.

**Known-unpassable rows.** The runner fetches `mattrbeck/mgba-suite-auto`'s
`releases/latest`, guarded by `MgbaSuiteSha1` so a new upstream release is reported
rather than silently re-baselined. That build carries the upstream fixture fixes
(`mgba-emu/suite@8c97f2c9` volatile `dmaPrefetch` source, `@a58437f3` re-measured
"H-blank bit start" constants, `@2a8eca1`, `@fbe6156`/`@aac98dc`). "DMA Prefetch Break"
expects `0x10000000 + 4 * iterations` with the count set by where gcc placed the loop, so
nobody passes it.

### jsmolka, FuzzARM, MagenTests

`--mode=jsmolka`: every ROM reports through `lib/macros.inc` — the verdict is in `r12`,
the ROM branches to a common `eval` on the first failing check and spins in `b idle`. The
mode runs until the PC stops moving and reads `r12`. It detaches the battery file because
`save/sram.gba` reads an untouched chip. All-or-nothing per ROM.

```
./dingbat_test /tmp/dingbat-test-roms/gba-tests-a6447c5/gba-tests-<rev>/arm/arm.gba --mode=jsmolka --timeout=600
```

`--mode=fuzzarm`: five DenSinH/FuzzARM ROMs of 10 000 randomly generated ARM/Thumb tests.
The ROM reports a failure, waits for a button and continues; the mode drives that gate and
reads each verdict out of the ROM's 16-word dump at `0x02000000`. "Done" is the ROM's
`b .` self-branch, found by scanning for `0xEAFFFFFE` — not "PC unchanged for two
frames", which this ROM (never waiting on vblank) trips early. Per-failure triage goes to
stderr; stdout is one `FUZZARM: N/10000 passed` line the runner finds by marker.
`--max-fails=<n>` (default 500) caps the report.

```
./dingbat_test /tmp/dingbat-test-roms/fuzzarm-a675329-ARM_Any.gba --mode=fuzzarm --timeout=20000
```

`--mode=magen-green` / `magen-nored`: alloncm/MagenTests, CGB ROMs whose verdict is the
screen colour (`src/common.asm`: WHITE `$FFFF`, RED `$001F`, GREEN `$03E0`, BLUE `$7C00`).
`magen-green` requires every pixel green; `magen-nored` zero red pixels
(`bg_oam_priority`'s stated criterion). Not run through `--mode=screenshot`: the repo
ships no 160x144 reference. `oam_internal_priority` is skipped (prose-only criterion).

`--mode=gambatte` is batched — a list, not a ROM (see "The gambatte suite").

```
./dingbat_test --mode=gambatte --list=/tmp/gam.tsv [--gambatte-frames=15] [--dump-tiles=N]
```

Piping through `tail`/`head` masks the exit code (a segfault looks like success): check
`$?` on the harness or use `set -o pipefail`.

## `dingbat_test_runner` — full suite

Shells out to `./dingbat_test` in the current directory; run from the repo root after
`nimble test_build`.

Downloads into `$DINGBAT_ROM_CACHE` (default `/tmp/dingbat-test-roms`): game-boy-test-roms
v7.0 (Blargg, Mooneye + wilbertpol fork, Mealybug, SameSuite, gambatte, GBMicrotest, AGE,
the small screenshot suites), dmg-acid2, cgb-acid2, the mGBA suite ROM, `jsmolka/gba-tests`
at `JsmolkaRev`, FuzzARM at `FuzzArmRev` (tests are generated at build time, so bumping the
SHA is a re-baseline), MagenTests at `MagenRelease`, and ~30 shootout files at
`ShootoutRev`. CI backs the dir with `actions/cache`; bump the key when a URL changes.

Flags: `--bios=<path>` (mGBA suite only), `--apu` (runs only Blargg dmg_sound/cgb_sound +
SameSuite APU and prints tallies without rewriting results files).

### Which suites run, and how each is scored

Each suite ships a `game-boy-test-roms-howto.md` beside its ROMs; that file is the
authority on device, exit condition and verdict.

| Suite | Verdict | Notes |
|---|---|---|
| Blargg `cpu_instrs`, `mem_timing` | serial text | `tmSerial` |
| Blargg `instr_timing`, `mem_timing-2`, `oam_bug`, `halt_bug`, `interrupt_time` | `$A000` status + `DEB061` | `tmSram`; `interrupt_time` is CGB-only; `oam_bug` needs ~21 emulated seconds |
| Mooneye (Gekkio) | `LD B,B` + Fibonacci regs | `manual-only/sprite_priority` is a screenshot |
| Mooneye (wilbertpol) | opcode `0xED` + Fibonacci regs | `--ed-breakpoint`; `utils/`, `logic-analysis/` have no verdict |
| AGE | `LD B,B` + Fibonacci regs, or screenshot | `--bb-breakpoint`; `ncm*` (CGB in non-CGB mode) skipped |
| GBMicrotest | HRAM `$FF82` | 2 frames (30 for `is_if_set_during_ime0`); 31 ROMs never write `$FF82` (`MicrotestNoVerdict`), 2 assert a byte no Game Boy produces (`MicrotestBrokenExpected`); scored out of 480 |
| Mealybug, Acid2, cgb-acid-hell, bully, strikethrough, scribbltests, turtle-tests, little-things-gb, mbc3-tester | framebuffer vs bundled PNG | exact match; see below |
| SameSuite `dma`, `ppu`, `interrupt`, `sgb`, `apu` | `LD B,B` + Fibonacci regs | `--cgb` except `sgb/` (`--sgb`); `apu/` alone via `--apu` |
| rtc3test, CasualPokePlayer MBC3, daid | framebuffer vs shootout PNG | scored with the shootout's tolerance, see below |
| MagenTests | screen colour | see above |
| gambatte | glyph OCR of the on-screen result | batched; one row per subdirectory |
| mGBA suite, jsmolka, FuzzARM | GBA | see above |

**The device each suite is scored on** (`Device` column in `results.md`): `cart` = the
cart header picks (DMG-ABC for `$0143 = $00`, CPU CGB C for `$80`/`$C0`); a trailing
token is a specific `--model`. A ROM whose name declares several machines (AGE's
`ei-halt-dmgC-cgbBCE`, mealybug's `_cgb_c`/`_cgb_d` pair, mooneye's `-GS` family) gets one
row per revision. SameSuite APU rows default to **cgbE** (its README states CGB-E passes
everything and CGB-C fails most channel 1/2/4 tests — `GbQuirks.pcm_read_edge_zero`), with
a `-cgb0B`/`-cgbDE`/`-A` filename token resolving to its highest member. Mealybug's
`dma/*-C` rows carry `model: "cgbc"`. gambatte's `dmg08`/`cgb04c` tags name capture
provenance (a DMG-CPU-08 board, CPU CGB C), which are the runner's defaults; no `--model`
axis exists for that mode.

The local runner's default CGB is CPU CGB C (gambatte's references are `cgb04c`); the
gbdev shootout adapter passes `--cgb-rev=E` (`cgb-acid-hell` and
`daid/ppu_scanline_bgp.gbc.png` pull in opposite directions across the C/D boundary and
only E clears both; the split is `GbQuirks.mixer_write_immediate`). Every reference that
names a revision is scored at that revision, so there is nothing to reconcile.

#### blargg's on-screen text is not an oracle — score on serial only

Blargg's runtime switches the CGB to double speed during init (`init_crc` calls
`set_double_speed` and never switches back) and its "wait for VBlank" is a bounded poll
(1250 iterations of 14 M-cycles) that covers a frame at single speed but half a frame at
double, so it times out whenever a print starts in the wrong half and the console blits
its row into the tile map with the LCD on, straddling mode 3. Those writes are refused
(Pan Docs, "Accessing VRAM and OAM"), and which cells are lost depends on the sub-scanline
phase of the blit — a screen check fails on correct emulation and can be "fixed" by any
constant that nudges the phase. The runner asserts only `--screen-check`. The gate for
this class of bug is differential (`tools/gbfuzz`, `tools/gbgate`,
`tools/gbppu/blargg_canary.sh`); the constant it guards, `SPEED_SWITCH_STALL_T`, is
ROM-bracketed but not ROM-pinned (`docs/oracles.md`).

Screenshot notes:

- Reference PNGs already match `write_ppm` (DMG `#000000/#555555/#AAAAAA/#FFFFFF`, CGB
  channels `(X<<3)|(X>>2)`). A suite comparing at ~0% is a frame count, a device, or a PNG
  format problem — `png_reader.nim` raises on anything it cannot decode.
- CGB-compatibility-mode references (a CGB booting a non-CGB cart) use mealybug's
  documented palette: background `#000000/#0063C6/#7BFF31/#FFFFFF`, objects
  `#000000/#943939/#FF8484/#FFFFFF`. Every mealybug cart is DMG-flagged, so its `_cgb_c`
  captures are this mode; the 27 `_cgb_c` rows run as `mealybug-cgb/*` and the `_cgb_d`
  set as its own arm. Two daid "GBC" rows are really compat mode and are skipped.
- `strikethrough` and `bully` are `$80` carts; `--mode=screenshot` reads the absence of
  `--cgb` as "run on a DMG", so their `-dmg` references are scored too.
- Not integrated: `little-things-gb/tellinglys` (needs a scripted button press);
  `scribbltests` `fairylake`/`winpos` and Mooneye's `logic-analysis/` (no reference).

#### The gbdev shootout's ROMs and its tolerance

`build_shootout_tests` fetches `ax6/rtc3test`, CasualPokePlayer's MBC3 tests and daid's
STOP/speed-switch tests file by file at `ShootoutRev`. Their references are scored with
the shootout's rule (`util.py: compareImage`: 8-bit luma, every pixel within 50) because
they are screen captures carrying an emulator's colour correction — rtc3test's green is
`#009100`, unreachable from `(X<<3)|(X>>2)`. `grey_tolerance` on `TestDef` implements it;
everything else stays exact, so a shootout row's percentage is not comparable to a
mealybug or gambatte row's. Skipped with a stated reason: `acid/which.gb` and
`daid/rom_and_ram.gb` (no reference; the shootout scores them INFO), `cpp/sgb-ext-test`
(no `--sgb` row is built for it; the adapter in `docs/sgb.md` passes it byte-exact outside
the runner, so the skip is a runner gap, not a model gap), and the compat-mode daid rows.

### Exit code, baselines, hazards

- The runner exits non-zero only on **regressions**: rows that pass in the committed
  `tests/results.md` and fail now. Exit 0 does not mean everything passed. Aggregated
  gambatte rows gate on the pass **count** (`load_previous_counts`), so 223 → 222 is a
  regression on a red row.
- The regression key is the full name (`blargg/oam_bug/1-lcd_sync`); anything shorter
  collides across forks. A name absent from the baseline is not gated, so adding a suite
  means regenerating and committing `results.md` in the same change.
- `magen/hblank_vram_dma` is baselined failing: dingbat runs the HBlank VRAM DMA while
  the CPU is halted.
- Parallel runners delete each other's gambatte shard output (`$TMPDIR/dingbat-gambatte`
  is wiped on entry) and the victim scores every unflushed row 0. Use a private `TMPDIR`.
- `$DINGBAT_ROM_CACHE` reuses any present file by name, so a different build dropped at a
  cached path silently changes what later runs score. Use a private cache before
  generating a baseline to commit, and check `git diff tests/results.md` for rows the
  change has no business touching.
- `results.md`, `results_mgba_suite.md` and `results_gambatte.md` are committed baselines
  and every run rewrites all three; `git checkout -- tests/results*.md` after a local run
  unless you mean to update them. `results.md` ends with a "Deliberately not scored"
  section listing each intentional skip with its reason.
- `tests/golden/` holds per-row mGBA-suite captures for diff-based timing work
  (`tests/golden/README.md`).

## The gambatte suite

3,524 ROMs in the game-boy-test-roms bundle, expanding to 5,005 scored rows. Verdict
mechanism per the bundle's howto and gambatte-core's `test/testrunner.cpp`:

- Every ROM runs exactly 15 LCD frames from the post-boot state, then the frame is read
  (14, 16 and 30 score identically; every ROM has settled).
- The device is in the filename: `dmg08` = DMG, `cgb04c` = CGB; most ROMs are two rows.
  Nearly all ship a CGB header even for the DMG half, hence `new_gb`'s `force_dmg`.
- The expected value is in the filename as `_out<hex>`, per device
  (`..._dmg08_out2_cgb04c_out0.gbc`); the ROM draws it as 8x8 glyphs on the top row and
  scoring compares those tiles with `GambatteGlyphs`. An `x` prefix (`_xout0`) means "not
  a test".
- Some ROMs ship a reference PNG (`<rom>_dmg08.png` etc.), scored on the whole frame,
  masked to 0xF8F8F8 with gambatte's CGB colour-correction formulae on the CGB side.

`GambatteGlyphs` was harvested, not vendored (gambatte-core is GPL-2.0): `--dump-tiles=N`
prints the top-row tiles, and a few hundred ROMs whose names state their digits resolve
all 16 shapes by majority vote.

Not scored: the 220 `_outaudio0/1` rows (gambatte decides them on whether all 35,112
samples of the final frame are identical at 2 MHz; dingbat's APU emits at 32,768 Hz) and
gambatte's AGB column (its own runner marks it "FIXME" and feeds it CGB expectations).

Rows are sharded across `countProcessors()` processes, each a `--mode=gambatte --list=`
batch with a fresh `GB` per row (~7 s). `results.md` carries one row per subdirectory;
per-test detail is in `results_gambatte.md`.

### Debugging a row

`DINGBAT_GAM_DUMP=<dir>` writes every scored frame as a PPM in the comparison's colour
space. The `-d:gb_*` trace builds and the per-family readers that wrap them are catalogued
in [`tools/gbppu/README.md`](../tools/gbppu/README.md) ("Trace flags"). For the `m2int_*`,
`m0int_*`, `lycm2int`, `m2enable` and `halt` families — a STAT interrupt, a NOP run, one
STAT/IF read, and a sibling differing by one NOP — `d.find(b'\xf2', 0x1000) - 0x1000` is
the NOP count.

A second-emulator scorer exists for this suite: `tools/gbfuzz/sameboy_gambatte` runs a
gambatte ROM under SameBoy and prints the same decoded hex (`--rom <dmg|cgb> <rom>` or a
list; `SAMEBOY_CGB_MODEL=0|A|B|C|D|E`, C by default). It plays the real boot ROM where
dingbat skips it, which is a one-M-cycle post-boot phase offset; use it differentially
(modify the ROM and ask whether the answer moves as the model predicts).

## `dingbat_bench` — headless benchmark

```
./dingbat_bench <rom> [frames] [warmup_frames] [input_script]
```

Input scripts drive the keypad (`"600:START,700:A,900:RIGHT:120"`). Env vars (full list
at the top of `dingbat_bench.nim`): `DINGBAT_BENCH_HASH=1` (per-frame framebuffer hash for
pixel-exact A/B), `DINGBAT_BENCH_COUNTERS=1` (retired instructions), `DINGBAT_BENCH_BIOS`,
`DINGBAT_BENCH_STATE`, `DINGBAT_NO_WAITLOOP=1`, `DINGBAT_MP2K*`.

## Nimble tasks (`dingbat.nimble`)

`test_build`, `bench_build`, `statefuzz_build`, plus compile-and-run tasks, each also a
CI step: `test_timestretch` (WSOLA), `test_ppucomposite` (GBA compositor invariants),
`test_ppubgunpack` (4bpp SWAR unpack vs scalar; `DINGBAT_BG4_EXHAUSTIVE=1` for the full
sweep), `test_ppuobjlist`, `test_savestate_compat` (loads `tests/states/` and pins
EventType ordinals / payload revisions), `test_cheats`, `test_rewind`, `test_clipreplay`
(clip-capture replay determinism with two negative controls), `test_printer`,
`test_lcdresponse`, `test_sgb`. The link-acceptance battery (`linktest`, `speclink`,
`netlink`, `rollback` modes over `tests/roms/*.gba`) is invoked directly in
`.github/workflows/test.yml`.

`tests/roms/hwverified/`: eleven GBA ROMs carrying hardware-verified expected values with
a self-painted verdict pixel; `python3 tests/roms/hwverified/run.py` (local only).

## Where test ROMs come from

- `tests/roms/` — committed homebrew ROMs with sources: GBA `.s` (build line in each
  header) and GB `.py` generators (hand-assembled SM83, no toolchain).
- External suites are never committed; the runner downloads them as above.
- Official BIOS/boot ROMs are never in the repo (`.gitignore`); pass `--bios=`.

## Web test suite

```
node --test web/tests/*.test.mjs   # node:vm harness over the real web/index.js
```

`web/tests/helpers.mjs` evaluates the unmodified `index.js` with stubbed browser globals;
any new module-scope browser global in `index.js` must be stubbed there or every test
dies at eval time (`web/tests/README.md`). Static gate: `npx tsc -p
web/types/tsconfig.{main,embed,sw}.json`, and `node web/types/gen-emdts.mjs --check` for
a stale `em.d.ts`. Browser-only tiers (`web/render.test.mjs`, `web/manualpair.test.mjs`,
`web/uv.test.mjs`, `web/signaling/server.test.mjs`) — invocations in the workflow file.
