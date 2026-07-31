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
`serial`, `sram`, `mooneye`, `mgba`, `mgba-suite`, `screenshot`,
`stateroundtrip`, `rewindtest`, `linktest`, `normlinktest`, `norm32linktest`,
`attachtest`, `netlink`, `speclink`, `speclinkbench`, `rollback`,
`rollbacknet`, `gblinktest`.

Options: `--timeout=<frames>`, `--frames=<warmup>`, `--screenshot=<path.ppm>`,
`--color`, `--cgb`, `--model=<dmg0|mgb|sgb|...>` (mooneye boot-state tables),
`--bios=<path>`, `--sio=null|loopback`, and for the link modes `--listen`,
`--connect`, `--netlink-delay-ms`, `--link-contract=multi|normal|normal32`,
`--attach-after`.

Typical single run (mGBA suite, ~1.5 s when waitloop detection is healthy,
~70 s when it is broken):

```
./dingbat_test /tmp/dingbat-test-roms/mgba-suite.gba --mode=mgba-suite --timeout=36000
```

Gotcha: piping through `tail`/`head` masks the exit code — a segfault (139)
looks like success. Check `$?` on the harness itself, or use `set -o pipefail`.

## `dingbat_test_runner` — full suite

Shells out to **`./dingbat_test` in the current working directory**
(`getCurrentDir()`, see `main()` in `dingbat_test_runner.nim`) — run it from
the repo root right after `nimble test_build`, or it quits with
"dingbat_test not found".

- Downloads external suites into `$DINGBAT_ROM_CACHE` (default
  `/tmp/dingbat-test-roms`): game-boy-test-roms v7.0 (Blargg, Mooneye,
  Mealybug, SameSuite), dmg-acid2 v1.0, cgb-acid2 v1.1, and the mGBA suite
  ROM from `mattrbeck/mgba-suite-auto`. CI backs this dir with
  `actions/cache` (`.github/workflows/test.yml`) so a flaky fetch can't fail
  the run; the cache key must be bumped when a URL/version changes.
- Flags: `--bios=<path>` (mGBA suite only — the other suites are HLE/boot
  -table only in this harness), `--apu` / `--suite=apu` (opt-in Blargg
  dmg_sound/cgb_sound + SameSuite APU; deliberately outside the default run
  and it does NOT rewrite results files).

**Exit-code pitfall:** the runner exits non-zero only on *regressions* —
tests that pass in the committed `tests/results.md` and fail now. Exit 0 does
**not** mean everything passed (the baseline carries known failures: Total
169, Pass 137 as of the current committed `results.md`).

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
