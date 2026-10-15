# tests/

The test entry points and their gotchas. This file summarises; the sources it cites are
the authority.

## Building: `-d:test_harness` is a link flag first

Every headless binary builds with `-d:test_harness`. Besides gating harness-only code
(APU capture, `common/test_output.nim`, savestate hooks) it stops `nim.cfg` from
appending the GUI's SDL 3/OpenGL link flags (`@if not test_harness:`). Without it a
headless binary links on a dev Mac with Homebrew SDL 3 and fails on every CI runner.

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
`magen-nored`, `gambatte`, `microtest`, `docboy`, `screenshot`, `stateroundtrip`, `rewindtest`,
`linktest`, `normlinktest`, `norm32linktest`, `attachtest`, `netlink`, `speclink`,
`speclinkbench`, `rollback`, `rollbacknet`, `gblinktest`, `mbc30test`.

Options: `--timeout=<frames>`, `--frames=<warmup>`, `--screenshot=<path.ppm>`,
`--max-fails=<n>` (fuzzarm), `--color`, `--dmg`, `--cgb`, `--sgb`, `--cgb-rev=<0|A|B|C|D|E>`,
`--model=<dmg0|mgb|sgb|cgb0|...>` (boot table + `GbQuirks` revision), `--nosave`,
`--ed-breakpoint`, `--bb-breakpoint`, `--screen-check`, `--bios=<path>`,
`--press=<frame>:<btn>[+<btn>],...` (GB: hold the buttons from that frame for six frames,
for ROMs with a menu; applied between frames, as the frontend does),
`--serial-pass=<text>` / `--serial-fail=<text>` (serial mode: a ROM's own verdict text in
place of blargg's `Passed`/`Failed`), `--mbc30-screen=rom|sram` (mbc30test mode),
`--input=<when>:<btn>[+<btn>]:press|release,...` (GB: key changes at an exact machine
time; see "Timed joypad input" below),
`--sio=null|loopback`, and for the link modes `--listen`, `--connect`,
`--netlink-delay-ms`, `--link-contract=multi|normal|normal32`, `--attach-after`.

Four GB flags exist because suites end a run differently; each is opt-in so it cannot
change how another suite is scored:

- `--nosave` blanks cart RAM and detaches the `.sav`, on GB and GBA alike. Battery-backed
  suite ROMs otherwise drop a save in the shared cache dir and the next run loads it as
  power-on state (in CI `actions/cache` would carry it between runs).
  **Never point the harness straight at a ROM library.** `new_gba` loads `<rom>.sav` when
  one exists and a saving run writes one back, so a library ROM boots from whatever save
  sits beside it and the run leaves a file in someone's archive. Symlink the ROM into a
  scratch directory (what `tools/playtest` and the library sweeps do) or pass `--nosave`.
  A harness that skips this agrees with one that does not until the frame the game first
  reads its save, and then diverges completely — which reads like a core bug and is not.

**Frame numbering against `tools/playtest`.** The playtest driver's frame N is this
harness's `--timeout=N+1`, verified byte-identical on a GBA title at driver frames 300
and 549. The sweep's findings are recorded in the driver's numbering, so that is the side
to convert from.
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

`--mode=mbc30test` scores ZoomTen's mbc30test on the screen it draws, the ROM's own
verdict ("No X's are to be seen"). The ROM marks each bank with tile `$00` (`.`, the
bank's byte at `$4000`/`$A000` matched) or `$01` (`X`) in a 16x16 table, then replaces its
header with `MBC30 ROM OK!` / `MBC3 ROM OK!` / `UNKNOWN ROM FAIL` and holds the screen
for 240 frames; the SRAM screen does the same for banks 0-7. The mode reads the displayed
frame cell by cell against the ROM's own tiles as loaded in VRAM, takes the verdict once
the header names an outcome and the frame has held for 10 frames (ROM screen frame ~271,
SRAM ~545), and passes on the `MBC30 ... OK!` header with every bank marked `.`. One
`MBC30TEST: PASS|FAIL <header>: n/256 banks '.', 'X' at <ranges>` line on stdout; a
failing run dumps the decoded screen to stderr. Always a fresh chip, no `.sav`.

### Timed joypad input (`--input`)

`--press` applies keys between frames, so every press lands at the same point of the
frame. ROMs that measure when the joypad interrupt fires (tellinglys, DocBoy's
`joypad/` and `stop_*` ROMs) need the key change at a chosen machine time. `--input`
(GB only; `tests/gb_timed_input.nim`) does that:

```
--input=WHEN:KEY[+KEY]:ACTION[,WHEN:KEY[+KEY]:ACTION...]
  WHEN    N    dots (4.194304 MHz) after the hand-off; dot 0 is the first dot of the
               M-cycle that fetches the opcode at $0100
          @HH  when opcode HH (hex) is fetched
  KEY     a b select start up down left right; `+` changes several in one event
  ACTION  press | pressed | release | released
```

Semantics, which are DocBoy's test runner's (`tests/testutils/testutils/runners.h`):

- Time advances in 4-dot steps. A timed event is applied on the first step at or after
  its time at which it is the first due event in list order, and at most one event is
  applied per step. So `0:a:press,0:right:press` presses A on dot 0 and Right on dot 4,
  and a backlog drains one per step. Order of the list, not of the times, breaks ties.
- An event applied on step `s` is in place before anything else in the M-cycle that
  starts on dot `s`: a P1 read, an IF read or the interrupt check in that M-cycle sees
  it, and none earlier does.
- `@HH` is applied when the opcode is fetched, before the next M-cycle, i.e. on the
  M-cycle after the one that read the opcode byte (DocBoy compares the CPU's latched
  opcode at the top of each 4-tick cycle, and latches it at the end of the fetch). The
  first pending `@HH` event for that opcode in list order is the one applied. `@HH`
  events are not part of the step queue: one due on the same step as a timed event
  does not delay it.
- Time keeps running in STOP mode (one step of STOP is the 4 cycles of the M-cycle it
  stands for), so a press can end STOP. Across a CGB speed switch it is real time: in
  double speed a step is two M-cycles.
- Events never applied by the end of the run are reported on stderr (`INPUT: n of m
  --input event(s) never applied`).

Granularity: every event lands on an M-cycle boundary, a step is 4 dots. That is one
M-cycle at single speed — the finest a program can observe a key change, since the CPU
sees P1 and IF only through M-cycle bus reads and checks interrupts at M-cycle
boundaries, and the core raises the joypad interrupt on the falling P10-P13 edge the
moment the line changes (Pan Docs, "Joypad Input"; `joypad_update` in
`src/dingbat/gb/joypad.nim`). In double speed a step is two M-cycles, which is also
DocBoy's resolution, so a DocBoy expectation never depends on the odd M-cycle.

Mechanism, zero cost to shipping builds (every hook is `when defined(test_harness)`):
the module books one scheduler event at a time, `etHandleInput` (an ordinal the GB core
never books, so no save-state ordinal moves), in real time with `schedule_gb`. The
scheduler carries it through the per-frame rebase and rescales it at a speed switch, and
every fast path stops on it (the idle-loop and HALT skips, the speed-switch stall).
`mem_tick_stopped` hands STOP's steps to the module; `cpu_exec_fetched` tests the
fetched opcode against a set (`gb_harness_ops`) for `@HH`. `tests/gb_timed_input_test.nim`
(`nimble test_gbtimedinput`) pins all of this on programs assembled in the test: the
P1/IF boundary at every dot of a 600-M-cycle window for press and release (and no IRQ
on release), the step queue and ties, `@40` against the equivalent time, frame
crossings, double speed, an idle poll loop against a busy one, HALT, and STOP.

**DocBoy manifest mapping** (`tests/config/*.json`, `"inputs"` of an entry), 1:1 in list
order, joined with `,`:

| DocBoy | dingbat |
|---|---|
| `"trigger_at_tick": N` | `N`. DocBoy's ticks are dots counted from `Core::reset`; its CI builds without `ENABLE_BOOTROM`, so `BOOT_DURATION` is 0 and the reset CPU stands on the last micro-op of the boot ROM's `LDH ($50),A`, the one that fetches $0100 (`Cpu::reset`): tick 0 is this harness's dot 0. |
| `"trigger_at_instruction": "ld b,b"` / `"ld c,c"` / a number | `@40` / `@49` / `@` + the number in hex (an `LD r,r'` mnemonic is `$40 + 8*r + r'`, B=0 C=1 D=2 E=3 H=4 L=5 A=7) |
| `"key": "a"` (`b`, `select`, `start`, `up`, `down`, `left`, `right`) | the same word |
| `"state": "pressed"` / `"released"` | `pressed` / `released` (or `press` / `release`) |

Example: `{"trigger_at_tick": 0, "key": "a", "state": "pressed"}, {"trigger_at_tick":
131072, "key": "a", "state": "released"}` is `--input=0:a:pressed,131072:a:released`.
One DocBoy model difference to expect when triaging: DocBoy raises the joypad interrupt
on a release as well as a press (it models switch bounce, `joypad.cpp`); dingbat raises it
on the falling edge only, as Pan Docs specifies.

### mGBA suite

```
./dingbat_test /tmp/dingbat-test-roms/mgba-suite.gba --mode=mgba-suite --timeout=36000
```

~1.5 s with waitloop detection healthy, ~70 s without. `DINGBAT_NO_WAITLOOP=1` turns
idle-loop fast-forward off. The fast-forward is exact (whole iterations of the loop's
measured period, never past an event; `waitloop.nim` "Transparency"), so every row must
read the same either way — a difference is a detector bug, not a timing result. Per-row
verdicts: `docs/mgba-suite-verdicts.md`.

**Video tests.** The auto-run build skips the interactive Video suite. `tests/mgba_video.nim`
drives upstream's interactive `suite.gba` through its menus and diffs each test's actual
frame against its expected one (exit 1 on any difference; PPMs with a second argument):

```
nim c -d:test_harness -d:release --path:src -o:mgba_video tests/mgba_video.nim
./mgba_video <interactive suite.gba> [ppm dir]
```

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
"H-blank bit start" constants, `@2a8eca1`, `@fbe6156`/`@aac98dc`). The "H-blank bit
start" constants time compiler output, so the fork's `docker-build.sh` pins
`devkitpro/devkitarm:20260221` — the image that was `latest` when they were measured.
Built by any other gcc those eight rows disagree with their own expected values; built by
that one they all pass. The single row left is "DMA Prefetch Break", which cannot pass as
the core dispatches: its exit is a per-line lottery on a window narrower than an
instruction (`docs/mgba-suite-verdicts.md`).

### jsmolka, FuzzARM, MagenTests

`--mode=jsmolka`: every ROM reports through `lib/macros.inc` — the verdict is in `r12`,
the ROM branches to a common `eval` on the first failing check and spins in `b idle`. The
mode runs until the PC stops moving and reads `r12`. It detaches the battery file because
`save/sram.gba` reads an untouched chip. All-or-nothing per ROM.

```
./dingbat_test /tmp/dingbat-test-roms/gba-tests-a6447c5/gba-tests-<rev>/arm/arm.gba --mode=jsmolka --timeout=600
```

**alyosha-tas/gba-tests** (and png183's fork) extend the same framework with DMA, IRQ,
prefetcher, bus, FIFO, LDM, serial and timer timing ROMs. They are scored in screenshot
mode on the verdict line the framework draws ("All tests passed" / "Failed test NNN" at
y = 76, read with the font from the repo's own `lib/glyphs.asm`: `read_verdict_text` in
the runner), because the r12 protocol misreads the LDM and halt ROMs. Copies of jsmolka's
ROMs and the three draw-only ROMs are skipped, and so are `unsafe/prefetcher_branch_thumb_arm_2`,
which the suite's own `unsafe/README.md` says crashes on a console, so its expected values
never came off one, and `fifo_dma/fifo`, whose source marks its one failing check "gives
unexpected results on hardware" (both NotScored). Many rows are red: they are the open GBA timing gaps, not
harness faults.

**PeterLemon BIOS, gba-rtc-test, Hades-Tests, SwpTestsGBA, AGBEEG** (screenshot mode,
downloaded at pinned revisions or release SHA-1s, never committed). PeterLemon's BIOS ROMs
ship the frame they draw as a PNG and are compared exactly; they run on the HLE BIOS, and
the red rows show where its SWI cycle counts differ from the real BIOS's. ROMs that only
print their verdicts are scored on a pinned hash of the all-pass frame, checked by eye when
pinned; a ROM that has never drawn that frame here is `unpinned` and red until it does.
SwpBusLocking's verdict is its backdrop colour (`pass_rgb`). AGBEEG reports each check
through its CI port (a byte register at `0x04999990`: name, `PASS`/`FAIL`, ..., `DONE`);
`dingbat_test` prints one `AGBEEG <name> <verdict>` line per check and the runner scores one
row per check (`agbeeg_check`).

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

Flags: `--bios=<path>` (the mGBA suite and every GBA screenshot row run on that BIOS image
instead of the HLE), `--apu` (runs only Blargg dmg_sound/cgb_sound + SameSuite APU and prints
tallies without rewriting results files), `--suite=gba` (the same for every GBA suite: mGBA,
jsmolka, FuzzARM, alyosha, PeterLemon, Other, SingleStepTests ARM7TDMI; about a
minute), `--suite=singlestep` (both SingleStepTests sets, see below), `--suite=docboy`
(the DocBoy suite alone, tallies only).

### Which suites run, and how each is scored

Each suite ships a `game-boy-test-roms-howto.md` beside its ROMs; that file is the
authority on device, exit condition and verdict.

| Suite | Verdict | Notes |
|---|---|---|
| Blargg `cpu_instrs`, `mem_timing` | serial text | `tmSerial` |
| Blargg `instr_timing`, `mem_timing-2`, `oam_bug`, `halt_bug`, `interrupt_time` | `$A000` status + `DEB061` | `tmSram`; `interrupt_time` is CGB-only; `oam_bug` needs ~21 emulated seconds |
| Mooneye (Gekkio) | `LD B,B` + Fibonacci regs | `manual-only/sprite_priority` is a screenshot |
| Mooneye (wilbertpol) | opcode `0xED` + Fibonacci regs | `--ed-breakpoint`; `utils/`, `logic-analysis/` have no verdict |
| AGE | `LD B,B` + Fibonacci regs, or screenshot | `--bb-breakpoint`; `ncm*` (CGB in non-CGB mode) runs the DMG-flagged cart with `--cgb`, one arm per revision |
| GBMicrotest | HRAM `$FF82` | 2 frames (30 for `is_if_set_during_ime0`); 31 ROMs never write `$FF82` (`MicrotestNoVerdict`), 2 assert a byte no Game Boy produces (`MicrotestBrokenExpected`); scored out of 480 |
| Mealybug, Acid2, cgb-acid-hell, bully, strikethrough, scribbltests, turtle-tests, little-things-gb, mbc3-tester | framebuffer vs bundled PNG | exact match; see below |
| SameSuite `dma`, `ppu`, `interrupt`, `sgb`, `apu` | `LD B,B` + Fibonacci regs | `--cgb` except `sgb/` (`--sgb`); `apu/` alone via `--apu` |
| rtc3test, CasualPokePlayer MBC3, daid | framebuffer vs shootout PNG | scored with the shootout's tolerance, see below |
| MagenTests | screen colour | see above |
| MBC (ZoomTen mbc30test, deltabeard simple-mbc3O-test) | on-screen bank table (`tmMbc30Test`); serial `All banks OK` | release assets pinned by SHA-1; header device (CGB) and `--dmg` |
| gambatte | glyph OCR of the on-screen result | batched; one row per subdirectory |
| DocBoy | HRAM `$FFF0` (1 pass / 2 fail) or framebuffer vs reference PNG, DocBoy's own runner rules | batched (`--mode=docboy`); one row per manifest section; see "The DocBoy suite" |
| mGBA suite, jsmolka, FuzzARM | GBA | see above |
| SingleStepTests SM83, ARM7TDMI | per-instruction state and bus vs the vectors | `./singlestep_test`; see "SingleStepTests" below |

**The device each suite is scored on** (`Device` column in `results.md`): `cart` = the
cart header picks (DMG-ABC when `$0143` bit 7 is clear, CPU CGB C when it is set); a trailing
token is a specific `--model`. A ROM whose name declares several machines (AGE's
`ei-halt-dmgC-cgbBCE`, mealybug's `_cgb_c`/`_cgb_d` pair, mooneye's `-GS` family) gets one
row per revision. SameSuite APU rows default to **cgbE** (its README states CGB-E passes
everything and CGB-C fails most channel 1/2/4 tests — `GbQuirks.pcm_read_edge_zero`), with
a `-cgb0B`/`-cgbDE`/`-A` filename token resolving to its highest member. Mealybug's
`dma/*-C` rows carry `model: "cgbc"`. wilbertpol's `-C`/`-cgb` rows run on **cgbE**: the
fork's sources name no revision and six of its gpu ROMs assert what gambatte's `cgb04c` rows
and AGE's `cgbBC`/`cgbE` pairs place after CGB C (`WilbertpolCgbRep` in the runner). gambatte's `dmg08`/`cgb04c` tags name capture
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
- `little-things-gb/tellinglys` runs DocBoy's timed schedule for it (`--input`, eight
  presses 1310720 dots apart, which is not a whole number of frames) and is scored against
  the bundle's pass screens on DMG and in CGB compatibility mode. With `--press` it fails,
  as it should: every press lands on the same line.
- Not integrated: `scribbltests` `fairylake`/`winpos` and Mooneye's `logic-analysis/` (no
  reference).

#### The gbdev shootout's ROMs and its tolerance

`build_shootout_tests` fetches `ax6/rtc3test`, CasualPokePlayer's MBC3 tests and daid's
STOP/speed-switch tests file by file at `ShootoutRev`. Their references are scored with
the shootout's rule (`util.py: compareImage`: 8-bit luma, every pixel within 50) because
they are screen captures carrying an emulator's colour correction — rtc3test's green is
`#009100`, unreachable from `(X<<3)|(X>>2)`. `grey_tolerance` on `TestDef` implements it;
everything else stays exact, so a shootout row's percentage is not comparable to a
mealybug or gambatte row's. `cpp/sgb-ext-test` runs with `--sgb` on the shootout's polling
budget (its `runtime=0.5` is a lower bound; the report is blank at 30 frames). Skipped with
a stated reason: `acid/which.gb` and `daid/rom_and_ram.gb` (no reference; the shootout
scores them INFO).

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
- `results.md`, `results_mgba_suite.md`, `results_gambatte.md` and `results_docboy.md`
  are committed baselines and every run rewrites them; `git checkout -- tests/results*.md` after a local run
  unless you mean to update them. `results.md` lists Game Boy suites before GBA ones,
  each console alphabetical; a suite with every row green has only its Summary row (the
  gate reads that row as "all green"), and a suite with a detail page links it from its
  Summary name. It ends with a "Deliberately not scored" section listing each
  intentional skip with its reason.
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
  masked to 0xF8F8F8, in the integer CGB colour conversion the reference PNGs are encoded in.
  One exception on DMG rows: at a pixel dingbat painted as a palette write's transition
  pixel, the reference may hold either clean colour. The pixel is a race on hardware, and
  gambatte's DMG PNGs are its own framebuffer dumps (docs/gb-failure-triage.md C7). The
  verdict counts the pixels accepted this way.

`GambatteGlyphs` was harvested, not vendored (gambatte-core is GPL-2.0): `--dump-tiles=N`
prints the top-row tiles, and a few hundred ROMs whose names state their digits resolve
all 16 shapes by majority vote.

The 220 `_outaudio0/1` rows use gambatte's own rule (`test/testrunner.cpp`): after the run,
`audio0` iff all 35,112 samples of the final frame are identical, `audio1` otherwise. Its
stream is the raw mix at 2 MHz with no output filter, so `--mode=gambatte` arms a probe on
the mixer (`GbApu.probe_*`) that runs the sample event every 2 T-cycles over the final frame
and compares the pre-DC-blocker mix; the presented 32,768 Hz stream is not involved.
`DINGBAT_GAM_AUDIO_SHIFT=<T-cycles>` slides that window (a ±456 sweep moved no verdict).
Not scored: gambatte's AGB column (its own runner marks it "FIXME" and feeds it CGB
expectations).

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

## The DocBoy suite

Docheinstein/docboy (MIT) keeps its emulator's test ROMs under `tests/` with
four JSON manifests naming each ROM's verdict: `config/dmg.json`, `cgb.json`,
`cgb_dmg_mode.json`, `cgb_dmg_ext_mode.json`; ROM sources are in
Docheinstein/docboy-test-suite. The runner fetches the archive at `DocboyRev`
(19 MB) and extracts only the manifests, `results/` and the ROMs under
`roms/*/docboy/` (~355 MB, ~10,000 ROMs). Only `docboy/` is DocBoy's own: the
manifests also vendor other suites (725 entries), which are scored from
upstream, and DocBoy disables 645 of its own entries; both are in the
`NotScored` ledger. So are 99 of DocBoy's own rows whose expectation is not
established hardware behaviour (`DocboyNotScored` in the runner: row-name
globs, one ledger entry per family with its evidence).

**Device.** DocBoy emulates one revision per family. CGB: the maintainer,
docboy#42: "I'm supporting only CGB-E at the moment" (and the manifest's
`cgb-acid-hell` entry: "This does not pass even on real CGB-E!"). DMG: its
skip-boot state is the DMG ABC/MGB hand-off (`timers.cpp`: DIV `$ABCC`,
"[mooneye/boot_div-dmgABCmgb.gb]"; `cpu.cpp`: AF `$01B0`), which with `A = $01`
is DMG ABC. So `dmg` rows run on `--model=dmgABC` (forced DMG) and the three
CGB manifests on `--cgb-rev=E` with the cart header picking the operating
mode, as DocBoy's CGB build does: `cgb_dmg_mode` carts are DMG-flagged (compat
mode), `cgb_dmg_ext_mode` carts carry `$0143 = $88..$8F`, which the CGB boot
ROM copies to KEY0 and which enters what Pan Docs calls PGB mode (KEY0 bit 3).
dingbat does not model PGB mode (it reads such a header as a DMG cart), so
that manifest's rows are scored and red rather than skipped: the hardware they
assert is a CPU CGB E with that cart, which is what the row runs.

**Verdict** (`tests/testutils/testutils/runners.h` at the pin, reproduced by
`docboy_batch` in `dingbat_test.nim`). No boot ROM (DocBoy's CI builds
without `ENABLE_BOOTROM`). A *tick* is one 4,194,304 Hz clock in both speed
modes; ticks count from the hand-off at `$0100`, the run stops at 100,000,000.
- `check_at_instruction` (`ld b,b` = `$40`, `ld c,c` = `$49`): one forced
  check when the CPU reaches that opcode, nothing else.
- Otherwise every 100,000 ticks: memory rows read their addresses (all of
  DocBoy's own: `$FFF0`) and pass on `value` (1) or stop failed on
  `fail_value` (2); framebuffer rows arm a check for the next M-cycle in which
  the PPU is in mode 1 and pass when the frame matches.
- Framebuffers compare exactly in RGB565 (the PNG's RGB888 truncated,
  `r>>3, g>>2, b>>3`). DMG shades are DocBoy's `$84A0 $4B40 $2AA0 $1200`;
  CGB colours are the raw BGR555 widened (`G6 = G5*2 + G5>>4`), no colour
  correction. DocBoy also has a blank-panel colour (`$AD00`, Pan Docs'
  "whiter than color #0" with the LCD off); dingbat draws a blank panel as
  shade 0, so a reference showing it cannot match.
- `check_at_tick` appears in the manifests but DocBoy's `RunnerAdapter` never
  passes it on, so it is ignored here too. `color_tolerance` and `palette`
  appear only on vendored entries. `limit_speed` only paces RTC rows to the
  wall clock when DocBoy is built with system time, which its CI is not.
- The two two-player rows (`serial_two_players_*`) run both carts on the
  in-process cable and check both screens at frame granularity.
- 71 rows script joypad input (`inputs`: a key `pressed`/`released` at
  `trigger_at_tick` N or at `trigger_at_instruction`). The runner turns each
  list 1:1 into `--input` syntax (`N:key:state`, or `@HH` for the opcode,
  `ld r,r'` = `$40 + 8r + r'`) and `--mode=docboy` arms it per row through
  `gb_timed_input`, the same machinery and timing as `--input` (see "Timed
  joypad input"); the tick and the dot share an origin, the hand-off.

`results.md` carries one row per manifest section
(`docboy/<manifest>/<section>`, gated on its pass count like gambatte's);
every failing ROM, with the first differing pixel or the `$FFF0` value, is in
`results_docboy.md`. Failing framebuffer rows run the full 100M ticks (about
1,400 frames each): 350 of the suite's ~390 CPU-seconds (8,800 rows cost the
other 40). CI sets `DINGBAT_DOCBOY_FB_MAX_TICKS=10000000`, which stops
framebuffer rows at 10M ticks (~35 CPU-s for the red ones); every green
framebuffer row passes by tick 4.84M, and the committed baseline comes from
the uncapped local run, so a row that only passes between the two limits
would show up in CI as a regression rather than hide.

Two diagnostics for one red row (`--mode=docboy --list=<one line>`):
`DINGBAT_DOCBOY_DUMP=<file>` writes each framebuffer check as shade digits
(`0`-`3`; CGB colours as letters per reference colour), the frame then the
reference, and `DINGBAT_DOCBOY_MEMDUMP=<hex addr>:<len>` prints those bytes
when a memory row reaches its verdict.

## SingleStepTests — per-instruction CPU vectors (`tests/singlestep_test.nim`)

SingleStepTests/sm83 and SingleStepTests/ARM7TDMI (both MIT): each case is one
instruction from a full register and memory state, with the final state and the
bus activity it made. `singlestep_test` runs them straight against the cores:

```
nimble test_build                    # also builds ./singlestep_test
./dingbat_test_runner --suite=singlestep
./singlestep_test sm83 <dir of v1/*.json>          [--only=<stem>] [--show=N] [--match=<s>]
./singlestep_test arm7tdmi <dir of v1/*.json.bin>  [--only=<stem>] [--show=N] [--match=<s>]
```

It builds with `-d:cpu_testbus`, which swaps the memory map out for a flat test
bus the driver serves (`gb_testbus_*` in gb.nim, `gba_testbus_*` in gba.nim) and
adds `testbus_step` to cpu.nim. The hooks are `when` branches: no other build has
them, so the hot path is untouched. The CPU still runs inside a real `GB`/`GBA`
built from a blank cart: the GB side is dingbat's own `tick` (fetch, execute, the
padding M-cycles, the interrupt check, with IE = 0), the GBA side `read_instr` and
`arm_execute`/`thumb_execute`.

**Downloads.** Into `$DINGBAT_SINGLESTEP_CACHE` (default `~/.cache/dingbat-singlestep`;
CI points it into the cached `rom-cache`), pinned at `Sm83TestsRev` and
`Arm7tdmiTestsRev`, never committed. SM83 is whole: 500 files of 1,000 cases (31 MB
zipped, 161 MB extracted). ARM7TDMI is 45 files of 50,000 cases, 20 MB each; the
runner takes the first `Arm7tdmiPrefixBytes` (2 MB, ~5,000 cases a file, 90 MB in
all) by HTTP range. The cases are random, so a prefix is a random sample. A local
deep run takes the whole files (`raw.githubusercontent.com/SingleStepTests/ARM7TDMI/<rev>/v1/<file>`,
891 MB) and `./singlestep_test arm7tdmi <dir>`: all 2.25 M cases in about 2 s, and
all 500 k SM83 cases in about 5 s.

**The vectors are an emulator's model, not hardware captures.** The SM83 set was
translated from an emulator's SM83 core, and the ARM7TDMI set was generated by
running another emulator. A disagreement is a lead to check against Pan Docs,
GBATEK and this project's AGB SP measurements, not a verdict. `docs/hwprobe-sst.md`
is the probe that puts each ARM7TDMI divergence to the AGB SP
(`tests/roms/payloads/sst.s`, `sstrisk.s`, run by `tools/hwlink/sst.py`).

### What is scored

- **State.** SM83: A F B C D E H L SP PC, IME, a pending EI (dingbat books EI's
  delayed IME as an `etIME` event) and every RAM byte the case lists. ARM7TDMI:
  r0-r15, every bank (the vectors' `R` is the User bank, `R_fiq` etc. the banked
  registers), CPSR and the five SPSRs. In Thumb state r15's bit 0 is masked on
  both sides. The ARM pipeline words are not scored: dingbat's pipeline is lazy.
- **Bus.** SM83: the M-cycle sequence, each a read, a write or neither; reads and
  writes compare address and data. A `---` cycle's address is not compared (dingbat
  drives none on internal M-cycles; the OAM bug's IDU address is modelled apart).
  ARM7TDMI: the transactions in order, each kind, size, address (to the size's
  alignment) and, for loads and stores, data. dingbat fetches lazily at the executing
  address, one fetch per instruction as the console does, so that fetch is scored at
  r15, where the console's first-cycle fetch is. After a branch `clear_pipeline`
  charges the refill without making it; it is scored as the console's refill, the
  destination and the next word or halfword, in the state the instruction leaves.
  A misaligned LDRSH is scored as the halfword access dingbat models it as
  (`ldrsh_odd`).
- **Access type** (ARM7TDMI). The refill is N then S (`clear_pipeline`'s `n + s`); a
  load or store is S when it continues the access before it in the same
  instruction (an LDM/STM burst), N otherwise: the address-continuity rule
  `rom_access_cycles` prices gamepak accesses by. The instruction's own fetch is not
  scored (the vectors set its type from the case's initial state). dingbat holds the
  bus for both of SWP's accesses (`swp_lock`) where the vectors mark only the write
  that ends the pair, so an access the vectors mark locked must be one dingbat holds.
  Internal cycles are not scored: the vectors list none, and their `cycle` field is
  documented upstream as unreliable.

A case passes when every check agrees. Each failure is classified
(`known_divergence` in `singlestep_sm83.nim` / `singlestep_arm7.nim`) or reported as
unexplained. A results.md row is green when nothing is unexplained, and its pass
count is gated from `results_singlestep.md` (`load_singlestep_counts`), so a case
sliding into a known bucket is still a regression; with every row green the suite
shows only its Summary row in results.md. The ARM7TDMI rows are one
per vector file, the SM83 rows one per unprefixed high nibble plus four for the CB
page; `results_singlestep.md` has every row's checks and divergences.

### Known divergences

| Case | dingbat | The vectors | Evidence for dingbat |
|---|---|---|---|
| SM83 `10` STOP | two bytes and STOP mode with no interrupt pending | one byte, three M-cycles | Pan Docs, "Reducing Power Consumption" (STOP chart) |
| SM83 `76` HALT | the HALT's fetch M-cycle; halted M-cycles are later ticks | three M-cycles | convention only: registers and PC agree |
| ARM S-bit data processing to r15 in User/System | NZCV kept (no SPSR to restore) | flags from the ALU | AGB SP: `sysmovs.s`; hwprobe-sst r.sysmovs.\*, r.usermovs.\* |
| ARM TST/TEQ/CMP/CMN with Rd = r15 (ARMv2 `TSTP`), User/System | NZCV kept, as the S-bit write above | the compare's flags (in the exception modes both restore CPSR from SPSR) | AGB SP: hwprobe-sst u.tstp.sys etc. |
| ARM LDR/STR with base r15 and writeback | PC := writeback address (+4 for a load, load suppressed) | writeback + 4, the load done | AGB SP: gbaedge THUMBPC2/PCWB2; hwprobe-sst r.ldr_pc_\*, r.str_pc_\* |
| ARM LDM/STM with base r15 and writeback | no writeback | writes back and branches | AGB SP: gbaedge PCWB2; hwprobe-sst r.ldmia_pc!, r.stmia_pc! |
| ARM MRC/MCR to coprocessor 14 | answers (MRC reads the prefetch, MCR is ignored) | Undefined Instruction trap | AGB SP: hwprobe-sst x.mrc14_\*, x.mcr14_c1; GBATEK; alyosha `arm/Coprocessor_14` |
| ARM MRS to r15 | a branch | r15 written without a refill | AGB SP: hwprobe-sst x.mrs_r15 |
| ARM MSR: PSR bits 8-27, SPSR bit 4 | bits 8-27 read 0; SPSR bit 4 reads 1 | latched as written | AGB SP: gbaedge CPSRBITS; hwprobe-sst r.cpsr_\*, r.spsr_\* |
| ARM MUL/MLA/UMULL.. with a destination of r15 | result dropped, no branch | writes r15 and branches | AGB SP: hwprobe-sst u.mul_rd15 etc.; png183 `arm/multiply` |
| ARM multiply with r15 as an operand | r15 = PC+8 | PC+12 | AGB SP: hwprobe-sst u.mul_rm15, u.mul_rs15, u.mla_rn15, u.umull_rm15 |
| ARM SWP with a base of r15 | the address is PC+8 | PC+12 | AGB SP: hwprobe-sst u.swp_rn15 |
| Thumb `CMP` hi-register with Rd = r15 | CPSR := SPSR, no compare | a plain compare | AGB SP: gbaedge THUMBPC/THUMBPC2; hwprobe-sst r.thumb_cmp_pc.\* |
| Thumb `Bcc` with cond 1110 (`DExx`) | Undefined Instruction trap | a branch | AGB SP: hwprobe-sst x.thumb_dexx; GBATEK THUMB.16 |

Every ARM7TDMI row is settled on an AGB SP by `docs/hwprobe-sst.md` (the
cell named). It also settled one the other way: a register-specified shift
by r15 reads PC+8, the vectors' answer, which dingbat now follows.

Not covered: interrupts and their dispatch (the vectors take none), the GBA's
waitstates and prefetcher (the vectors' bus is flat), and ARMv5 forms.

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
(clip-capture replay determinism with two negative controls), `test_statesoak`
(both cores built with checks on, a payload into a real rewind ring every frame with
rewinds, replays and loads into a newly built core, over every committed ROM and a seeded
random register-writing program per core; known core issues print `[KNOWN]`,
`DINGBAT_SOAK_STRICT=1` fails on them; an argument filters the cases),
`test_silentaudio` (a core toggling `APU.silent`, the muted no-mix path, must match a
mixing twin's payload every frame: committed ROMs, the soak's random programs and
channel-1 stop storms), `test_gbtimedinput` (`--input` lands on its M-cycle; see
"Timed joypad input"), `test_printer`,
`test_lcdresponse`, `test_mbc3` (MBC3/MBC30 bank registers, 64 KiB RAM, `.sav` and
save-state round trips on synthetic carts), `test_sgb`, `test_gbartc` (GBA cartridge RTC protocol and the
battery-save RTC trailer), `test_swihalt` (Halt and Stop from the cartridge
return intact in every GBA BIOS mode, over the stub, a stand-in image the test
writes, and Nintendo's image where it exists), `test_desktop` (the desktop frontend's logic that
builds without SDL: held input and key routing, the config file, the
Link Cable over loopback sockets, battery/state/cheat writes, game loading,
each replaying a `formal/DesktopState` trace, and the modal notices in a real
Dear ImGui context with no window, which needs imguin). The link-acceptance battery (`linktest`, `speclink`,
`netlink`, `rollback` modes over `tests/roms/*.gba`) is invoked directly in
`.github/workflows/test.yml`.

`tests/desktop_gui_test.sh` (needs SDL 3 and a display; CI runs it on Linux
under Xvfb, test.yml's `desktop-gui` job) drives the desktop app itself through
its SDL 3 event loop with `-d:gui_driver`, hidden and muted: keys as SDL 3
reports them under Shift and Caps Lock, a virtual SDL gamepad (hotplug,
buttons, stick, unplugged mid-press), the game picture filling the back buffer
(twice the window's points on a Retina display), a picture that changed
between fast-forward's presents and then held reaching the screen, the menus
and window under `DINGBAT_UI_SCALE=1.5` (the app's stand-in for a Windows or
X11 display at 150%: the menu bar and the window half as big again) and a
generated MBC5 rumble cart buzzing it. `GUI_TEST_FULLSCREEN=1` adds a visible
macOS window taken fullscreen by AppKit's own toggle, as the green button does.

`.github/scripts/smoke-desktop.sh` runs each release binary on its own OS
before the Build and Release workflows can publish it (Linux under Xvfb,
Windows with Mesa's llvmpipe `opengl32.dll`): 600 frames of
`tests/roms/blendprobe.gba`, then `--capture` must write
`tests/golden/desktop-blendprobe.png` to within 4 levels a channel (Mesa
renders it exactly; the present shader's float math rounds 1-2 levels apart on
Apple's GL). Regenerate that file only for a deliberate change to the picture,
from the Linux job's capture (default settings, muted):
`xvfb-run dingbat --capture=600:tests/golden/desktop-blendprobe.png tests/roms/blendprobe.gba`.
`--capture` is in device pixels, so on a Retina display it is twice the
golden's size and the compare fails there; CI's runners are 1x.

`tests/roms/hwverified/`: twelve GBA ROMs (this repo's own, committed with their `.s`)
carrying the values an AGS-001 gave, each painting a verdict pixel at (239,159): green if
every checked cell matched, red otherwise, white if it never finished. The runner scores
them as "GBA - hwverified (AGS-001)" on that pixel (`pass_rgb`); `python3
tests/roms/hwverified/run.py` runs them alone. `irqstorm` is a crash repro: a timer
interrupt raised every 1-256 cycles under a DMA burst of up to 4096 words, which an
emulator booking one event per raise cannot survive (see its header).

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
