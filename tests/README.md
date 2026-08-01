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
`serial`, `sram`, `mooneye`, `mgba`, `mgba-suite`, `jsmolka`, `microtest`,
`screenshot`, `stateroundtrip`, `rewindtest`, `linktest`, `normlinktest`,
`norm32linktest`, `attachtest`, `netlink`, `speclink`, `speclinkbench`,
`rollback`, `rollbacknet`, `gblinktest`.

Options: `--timeout=<frames>`, `--frames=<warmup>`, `--screenshot=<path.ppm>`,
`--color`, `--cgb`, `--model=<dmg0|mgb|sgb|...>` (mooneye boot-state tables),
`--nosave`, `--bb-breakpoint`, `--bios=<path>`,
`--sio=null|loopback`, and for the link modes `--listen`, `--connect`,
`--netlink-delay-ms`, `--link-contract=multi|normal|normal32`,
`--attach-after`.

The two GB flags exist because different suites end a run differently, and
each is opt-in so it cannot change how another suite is scored on the same
binary:

- `--nosave` blanks cart RAM and detaches the `.sav`. Battery-backed suite
  ROMs otherwise drop a save next to the ROM **in the shared cache dir**, and
  the next run loads it back as power-on state — non-reproducible locally, and
  in CI the `actions/cache` would carry one run's SRAM into the next.
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

Gotcha: piping through `tail`/`head` masks the exit code — a segfault (139)
looks like success. Check `$?` on the harness itself, or use `set -o pipefail`.

## `dingbat_test_runner` — full suite

Shells out to **`./dingbat_test` in the current working directory**
(`getCurrentDir()`, see `main()` in `dingbat_test_runner.nim`) — run it from
the repo root right after `nimble test_build`, or it quits with
"dingbat_test not found".

- Downloads external suites into `$DINGBAT_ROM_CACHE` (default
  `/tmp/dingbat-test-roms`): game-boy-test-roms v7.0, dmg-acid2 v1.0,
  cgb-acid2 v1.1, the mGBA suite ROM from `mattrbeck/mgba-suite-auto`, and
  `jsmolka/gba-tests` pinned to the commit in `JsmolkaRev` (the upstream repo
  ships assembled `.gba`s, so nothing is built). CI backs this dir with
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
| AGE (`age-test-roms`) | `LD B,B` + Fibonacci regs, or screenshot | `--bb-breakpoint`; the `ncm*` (CGB in non-CGB mode) variants are skipped — that device is not modeled |
| GBMicrotest | HRAM `$FF82` | `--mode=microtest`, 2 frames (30 for `is_if_set_during_ime0`) |
| Mealybug Tearoom, Acid2, cgb-acid-hell, bully, strikethrough, scribbltests, turtle-tests, little-things-gb, mbc3-tester | framebuffer vs bundled PNG | see below |
| mGBA suite, jsmolka gba-tests | GBA; unchanged | see above |

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
(Total 757, Pass 399 as of the current committed `results.md`, most of them
the PPU-timing suites added on purpose to measure them). All 13 jsmolka rows
are green in it, so any of them going red *is* a CI failure.

The regression key is the **full** test name — `blargg/oam_bug/1-lcd_sync`,
not `1-lcd_sync` — matching the row exactly as `results.md` writes it. With
several forks of the same suite in here (`mem_timing` vs `mem_timing-2`,
`age` vs `mooneye`) anything shorter collides across suites and
silently mis-keys the gate. A name absent from the baseline is simply not
gated, which is why adding suites means regenerating and committing
`results.md` in the same change.

**Results-file caveat:** `tests/results.md` and `tests/results_mgba_suite.md`
are committed baselines, and every run **rewrites both in place** (that is
also where the regression comparison reads from). After a local run,
`git checkout -- tests/results.md tests/results_mgba_suite.md` unless you are
intentionally updating the baseline.

`tests/golden/` holds per-row mGBA-suite captures (passing *and* failing
rows) for diff-based timing work — see `tests/golden/README.md`.

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
