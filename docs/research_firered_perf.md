# Pokémon FireRed performance: native, Chrome, Safari

**Date:** 2026-08-06/07
**Branch:** `agent-fireredperf` (nothing here is merged)
**Reads with:** `docs/performance.md`, `docs/research_ppu_next_steps.md`,
`docs/research_ppu_hotspots.md`, `web/bench/README.md`

Five bit-exact wins are implemented, one per commit, worth **+6.6% fps
natively (−8.8% retired instructions), +8.7% in Chrome and +9.2% in Safari** on
Pokémon FireRed resumed from an in-game overworld state. One build-flag change is measured and
left as the user's call. Six candidates were tried and rejected on
measurement, including two of this document's own earlier recommendations.

The headline correction to the existing record is that **this workload is
CPU/bus-bound, not PPU-bound** — the PPU is ~16% of native runtime and ~9% of
wasm runtime here, against the ~44% `docs/performance.md` still implies.

---

## 1. Benchmark and baselines

**Scene.** The save state resumes on the Viridian City crossroads — a real
overworld scene, not a menu, with the character standing still. A second
measurement point holds `DOWN` for the whole run (`"0:DOWN:2000"` as the bench
harness's input script), which walks south onto Route 1. **They cost the
same:** 827.3 vs 824.5 fps, 14.2697e9 vs 14.2442e9 retired instructions. So the
idle state is representative, every A/B below is reported on it, and the
walking scene is used as a second hash gate.

**Native harness.** `nimble bench_build` (`-d:test_harness -d:release`),
`DINGBAT_BENCH_STATE=<state> ./dingbat_bench <rom> 600 120`. Interleaved
best-of-5/9 with per-build ROM copies (the core writes `.sav` next to the ROM —
confirmed before the first run).

**The metric that actually resolves a percent.** `DINGBAT_BENCH_COUNTERS=1`
gives retired instructions and CPU cycles from `proc_pid_rusage`. Measured
spread across 7 repetitions of the identical binary: **0.003%** on instructions
against ±2-3% on wall-clock fps — and this machine carried concurrent load from
other agents for much of the session, which moved absolute fps by ±25%.
**Every native claim below is anchored on retired instructions**; fps is quoted
only for scale and only from interleaved rounds.

**Web harness.** `web/bench/bench.html` + `web/bench/cdp.mjs` against a
**visible** Chrome (`--remote-debugging-port=9333`, own `--user-data-dir`).
600 frames, median of 7, builds swapped on disk and the page reloaded, rounds
interleaved, and every round records `benchBuildId()` so the measured build is
identified rather than assumed (see §6).

**Baselines (stock, commit `2291784`)**

| target | HLE off | HLE on | notes |
|---|---|---|---|
| Native `-d:release` | **827.3 fps** (13.85x realtime) | — | 14.2697e9 instructions, 2.483e9 CPU cycles |
| Native `-d:danger` | **866.5 fps** | — | 11.834e9 instructions |
| Chrome (visible window) | 404-437 under load, 515-563 idle | 370-412 | interleave; see the load caveat |
| Safari 26.6 | 487-553 | 478-529 | ±14% run to run under load |

All three targets produce the **same emulated frames**: the browser
`benchHash(400)` is `155d983d` in Chrome and Safari for every build tested, and
the native rolling FNV-64 is identical across every build pair.

### Where the frame budget goes in the real web app

Measured in the live app (not the bench page) by wrapping `Module._loop_tick`
and `requestAnimationFrame`, FireRed from the same save state, Chrome, visible
window, default settings:

| | ms per frame |
|---|---|
| whole rAF callback | 1.981 |
| `loop_tick` (emulation + audio generation, inside wasm) | 1.973 |
| everything else on the main thread (present, audio scheduling, glow, rumble, overlays) | **0.019** |
| GPU time for the present draw (WebGL2 timer query, 960x640) | 0.186 |

**The present path is ~1% of the main-thread frame cost.** `web/glpresent.js`,
audio pacing and main-thread scheduling are not the bottleneck in a desktop
browser; wasm execution is 98-99% of it. Web wins have to come from core
throughput — which is what §3 delivers.

---

## 2. Profiles

### Native (`sample`, 15 s, 12 653 samples, leaf/self time, mid-session)

| component | share |
|---|---|
| `cpu.tick` self | 26.7% |
| `bus.fetch_half` (incl. the now-inlined ROM waitstate math) | 17.2% |
| `composite_span_opaque` | 5.6% |
| `unpack_bg4_span` | 4.1% |
| `render_reg_bg_impl` | 3.9% |
| `bus.fetch_word` | 3.2% |
| `arm_execute` | 2.2% |
| `apu_catchup_all` | 2.1% |
| `clear_pipeline` | 1.8% |
| `arm_multiply`, `rotate_register`, `scanline`, `analyze_loop`, scheduler | 1.3-1.5% each |

The **stock** profile had `rom_access_cycles` standing alone at **7.9%** — 569
of its 600 samples reached from `fetch_half`, i.e. the instruction-fetch slow
path — plus `contains` (HashSet lookup) at 1.5% reached from `analyze_loop`.
Both are gone.

### Wasm / V8 (Chrome CPU profile of a `--profiling-funcs` build, 30 050 samples)

| component | share |
|---|---|
| `cpu.tick` self | **46.5%** |
| `bus.fetch_half` | 9.3% |
| `composite_span` | 4.1% |
| `render_reg_bg_impl` | 3.7% |
| `bus.fetch_word` | 3.0% |
| `step_frame` | 3.0% |
| `apu_catchup_all` | 2.1% |
| scheduler dispatch closure | 1.9% |
| `clear_pipeline` | 1.6% |
| `get_sample` | 1.6% |

Two things to read off this. First, **Binaryen/LLVM inline far more
aggressively than clang does on native**: `rom_access_cycles`,
`unpack_bg4_span` and `composite_span_opaque` do not appear at all — they are
inside their callers — which is why win W1 is worth 2.6% of instructions
natively and near-nothing on the web, while W3/W4/W5, which remove *work*
rather than a call, transfer fully. Second, `cpu.tick` at 46.5% is where the
browser's time is, and §3 spends most of its wins there.

### Safari

Not profiled. Safari cannot be driven from the shell here (Apple Events to it
are refused: `-1743`, i.e. Develop > "Allow JavaScript from Apple Events" is
off) and it exposes no `EXT_disjoint_timer_query_webgl2` (probed:
`timerQuery=false`), so neither a JS CPU profile nor GPU timing was available.
What was measured in Safari is throughput and framebuffer hash, via a
self-reporting page (§6).

### The PPU share, corrected

Summing the PPU leaves: **~15.7% of native runtime and ~8.8% of wasm runtime**
on this state. `docs/performance.md` and the "PPU ≈ 44%" memory describe a
different situation — before the SWAR BG unpack and per-line OBJ candidate list
shipped, and on other states. On FireRed overworld the renderer is not where
the time is.

---

## 3. What landed, in order (each its own commit)

All five are byte-identical on both scenes and leave every suite unchanged.
Deltas are retired instructions, each measured against the commit before it.

| # | commit | change | native instructions | cumulative from stock |
|---|---|---|---|---|
| W1 | `23f6567` | `rom_fetch_cycles`: fetch-specialised, inlinable ROM waitstate path | **−2.62%** | 14.2697e9 → 13.8958e9 |
| W2 | `6a9a733` | `last_waitloop`: one-entry positive cache in front of `identified_waitloops` | **−1.60%** | → 13.6711e9 |
| W3 | `518df51` | `hle_gate`: the audio-HLE sentinel becomes one word | **−1.24%** | → 13.5060e9 |
| W4 | `54e09bb` | frame-progress readout derived from the scheduler instead of counted per instruction | **−2.23%** | → 13.2095e9 |
| W5 | `c72aa66` | prefetch-buffer fill floor hoisted into the only case that can reach it | **−1.47%** | → 13.0240e9 |
| | | **total** | | **−8.81%** (fps +6.6%, CPU cycles −6.0%) |

Three tooling commits carry the instruments: `fb6a003` (`-d:fetchprof`),
`160d679` (browser bench build-identity + Safari self-report), `a248dbd`
(`-d:gputime` native GL timer).

### W1 — fetch-specialised ROM waitstate path

`rom_access_cycles` is marked `{.inline.}` and is far too large for clang to
honour it, so every slow-path *instruction fetch* paid a real call.
`-d:fetchprof` (W1's companion commit) shows why that matters, per 600 frames:

```
fh_hot 13 846 511   fetch_half fast path
fh_slow 20 845 235  fetch_half slow path        <- 60% of all fetches
rac_pfhit 14 595 420  prefetch-buffer-hit branch
rac_went_hot 11 815 365
```

`rom_cool()` fires on every I-cycle, branch refill and data access, so
straight-line execution is repeatedly knocked off the fast path. Two of the
three branch clusters in `rom_access_cycles` are dead on a fetch (the DMA
burst trackers; the prefetch hand-off, which is `not fetch` by construction);
`rom_fetch_cycles` keeps the rest, takes `is32` as a `static bool`, routes
`dma_active` back to the general proc, and inlines.

### W2 — positive waitloop cache

`analyze_loop` had a one-entry cache in front of `identified_non_waitloops` but
not in front of `identified_waitloops` — and a loop that *is* a waitloop
re-enters `analyze_loop` on every iteration. `contains` was 1.4% of all
samples. Verdicts cannot change: the cache is consulted only for ROM addresses,
and ROM is immutable.

### W3 — one-word audio-HLE gate

The "collapsed" hook sentinel was two loads and two branches per instruction
(`hle_hook_pc != NO_HLE_HOOK` **or** `hle_probing`), not the one the comment
claimed. `hle_gate: uint32` encodes all three states in one word — 0 disarmed
(and it is the zero-init value, which `hle_hook_pc` was not), `NO_HLE_HOOK`
probing, anything else the hook PC. Verified with audio HLE **on** as well:
`hook_fires` 420, `engaged` true, `avg_out_energy` 0.1616, all identical.

### W4 — derive the frame-progress readout

`CPU.count_cycles` accumulated `max(1, total)` on **every** emulated
instruction so that one ImGui progress bar in the Experimental Settings debug
window could divide it by 280896. `step_frame` now stamps
`gba.frame_start_cycles = scheduler.cycles` and the bar subtracts. The field
was never serialised, so the save-state format is untouched. **2.2% of all
retired instructions for a debug widget.**

### W5 — the prefetch fill floor only binds after a full-buffer gap

`new_free_since = max(rom_free_since + need, done - cap)` can only take the
second term when the CPU has been off the ROM bus longer than a full buffer.
Proof is in the commit message; equivalence was also checked exhaustively over
**388 520** combinations of (`s` = 1..11, `is32`, `rom_free_since`, `now`) with
0 mismatches. Four operations leave the two common paths, and `fetch_half`'s
slow path runs 20.8M times per 600 frames.

### Cross-target verification of the whole stack (stock `2291784` vs tip)

| target | stock | tip | delta | evidence |
|---|---|---|---|---|
| Native `-d:release`, retired instructions | 14.2738e9 | 13.0157e9 | **−8.81%** | 9 interleaved rounds, 0.003% spread |
| Native `-d:release`, CPU cycles | 2.4862e9 | 2.3369e9 | **−6.00%** | same rounds |
| Native `-d:release`, fps | 777.6 | 829.1 | **+6.6%** | same rounds |
| **Chrome**, HLE off | 415.3 fps | 451.4 fps | **+8.7%** | 4 interleaved rounds, mean; 8/8 rounds favour tip |
| **Chrome**, HLE on | 398.0 fps | 411.5 fps | **+3.4%** | same rounds |
| **Safari 26.6**, HLE off | 512.5 fps | 559.4 fps | **+9.2%** | 3 alternating pairs, mean (+14.4%, +0.3%, +13.0%) |
| wasm bundle | — | +390 bytes | | |

Every Chrome round and every Safari run recorded its `em.wasm` byte length, so
the build being measured is identified, not assumed; and every one produced
`benchHash(400) = 155d983d`.

**Honest reading of the browser numbers.** The machine carried concurrent load
for most of this session and Safari cannot be interleaved automatically, so its
run-to-run spread reached 14%. Chrome's four rounds are interleaved and all
eight paired comparisons favour the tip, which is the stronger evidence; the
Safari series is 3/3 in the same direction with one near-zero pair. Read the
web gain as **"clearly positive, most likely +5 to +9%"** rather than as a
number good to one decimal place.

**Suites, run on every one of the five commits:** mGBA suite identical
sub-suite for sub-suite (1552/1552, 130/130, 1988/2020, 935/936, 90/90,
140/140, 93/93, 72/72, 615/615, 1244/1244, 90/90, 4/4, 4/12 — matching
`tests/results.md`); all ten jsmolka gba-tests ROMs pass; the seven Nim
unit-test tasks pass; the SDL/ImGui GUI builds (W4 touches a debug widget).

---

## 4. Explicit trade: native `-d:danger`

Not a cheap win under the "no accuracy loss" rule, so it stays here for the
user to decide.

| | fps | instructions | CPU cycles |
|---|---|---|---|
| native `-d:release` (what ships) | 766.8 | 14.270e9 | 2.473e9 |
| native `-d:danger` | **866.5 (+13.0%)** | 11.834e9 (−17.1%) | 2.191e9 (−11.4%) |

Four-way interleaved, same session, same ROM copies, measured on stock.

- **It is not an accuracy trade.** Framebuffer hashes are byte-identical on
  both scenes; the mGBA suite and jsmolka scores are identical to `-d:release`.
- **It is a memory-safety trade**: `-d:danger` turns off bounds, range and
  overflow checks. `bus.nim` documents at least one place where an unsigned
  subtraction *would* have wrapped and was caught as a `RangeDefect` during
  development; under `-d:danger` such a bug wraps silently.
- **The web build has shipped `-d:danger` since it existed**
  (`src/dingbat_wasm.nims`). So this makes the native build match the check
  semantics every browser user already runs, rather than introducing a new risk
  class.
- **Gate:** a full `dingbat_test_runner` run with the harness built
  `-d:danger`. That run is reported in §7 below.

Note the interaction with §3: much of W1's and W2's native gain was
bounds-check overhead that `-d:danger` removes anyway, so the two are partly
substitutes on native (W1+W2 measured +2.7% under `-d:release` but only +0.66%
under `-d:danger`). W3, W4 and W5 remove real work and stack with it — which is
also why they, and not W1/W2, are what moved the browsers.

---

## 5. Tried and rejected — with the measurement

Every row here was built and measured, not reasoned about. Negative results are
the point.

| candidate | measured | verdict |
|---|---|---|
| **Frame-loop specialisation on the HLE gate** — `tick_impl(hle: static bool)`, `step_frame` picking the instantiation once per frame (provably safe: a frame starting with `hle_gate == 0` cannot see it change) | **+3.74% instructions** | **Rejected.** The residual ceiling it was chasing is only −1.28%, and duplicating `tick` in the binary costs far more than the branch it removes. A warning against "specialise the hot loop" as a tactic in this codebase. |
| **Pin the native present to a fixed offscreen target** (this document's own previous top recommendation) | see below | **Rejected on measurement.** |
| **Resume-guard restructure** — hoisting the two `not cpu.halted` retests under one outer test | +0.071% | Rejected; reproduces the previous round's "CPU dispatch prologue is neutral". |
| **Conditional `dma_open_bus_armed` store** — load-and-branch instead of an unconditional per-instruction store | −0.012% | Rejected; the store was already free. |
| **Inline gate for `analyze_loop`** — split the two-sighting test out so the common case is two compares instead of a call | −0.119%, bit-exact | Measured but **not landed**: real, free, and too small to justify splitting the proc. Recorded so it is not re-attempted expecting more. |
| **`-s EXPORT_ALL=1` removal** from the emcc link line | `em.wasm` **byte-identical** | No-op for performance; only the JS glue differs. Nothing to measure. |
| **wasm SIMD128** | not retested | Prior round measured +1.6% and rejected it on iOS 15 compatibility; nothing here changes that. |
| **Present-path / audio-pacing work for browser throughput** | 0.019 ms of 1.98 ms per frame | Wrong target. |
| **PPU work on this state** | 15.7% native / 8.8% wasm | `docs/performance.md`'s 44% does not describe this workload. |

### The native present: measured, then rejected

The previous version of this document called pinning the native present to a
fixed offscreen target "the most actionable item found", on an **extrapolation**
that fullscreen xBR costs ~3.9 ms of GPU per frame. `-d:gputime` (commit
`a248dbd`) measures it instead. GPU ms for the game draw, FireRed, M-series:

| viewport | fragments | none | hq4x | xBR | xBR delta |
|---|---|---|---|---|---|
| 720x480 | 345.6k | 0.149 | 0.207 | 0.309 | +0.160 |
| 1440x960 | 1382.4k | 0.294 | 0.511 | 0.921 | +0.627 |
| 2160x1041 (as large as the window gets here) | 2248.6k | 0.415 | 0.769 | 1.429 | **+1.014** |

Linear in fragment count to within 2% (0.451-0.463 ns per 1000 fragments). So
the real ceiling is **1.0 ms above no filter, 6% of a 60 Hz frame, not 23%**.
The extrapolation was 2.7x too high because it assumed the drawable is in
Retina physical pixels; `SDL_WINDOW_ALLOW_HIGHDPI` is not set, so the drawable
is the point size.

**Rejected**, and not only on size: pinning the present to a fixed 4x offscreen
target and stretching would make the picture *blurrier* at large windows, which
is the entire point of running the filter at output resolution. It would trade
image quality for GPU time that is not scarce. If it is ever revisited it
should be for a weak integrated GPU, and that case has not been measured.

Two other rows fell out of the same run: **scanlines are free on native**
(0.4181 vs 0.4152 at 2160x1041, inside the noise) and so is **colour
correction** (0.4152 vs 0.4152) — which the web build is not, where it measures
+21%. Frame blending shows no GPU cost, correctly: it is a CPU-side blend
before the texture upload.

### The MP2K "skip" anomaly: refuted as a win

`DINGBAT_MP2K_SKIP=1` measured **+40.6% retired instructions** — the most
suspicious number in the previous report, and the hypothesis was a waitloop
shape `analyze_loop` misses. **That hypothesis is wrong, and the setting is not
a setting.**

1. **It is not user-reachable.** `mp2k.skip` is written from exactly one place
   in the tree: the `DINGBAT_MP2K_SKIP` branch of `tests/dingbat_bench.nim`.
   Neither frontend exposes it. Its own comment in `cpu.nim` calls it an
   "EXPERIMENTAL perf probe … NOT correct … measures the performance ceiling of
   an aggressive HLE only, not a shippable path". Listing it in a settings
   matrix was my error.
2. **The mechanism is a broken loop exit, not a missed idle loop.** With skip
   on, the mixer hook fires **569 293 times in 300 frames — 1898 per frame**,
   against 420 in 300 frames (1.4 per frame) with the HLE on normally. A
   throwaway histogram of the return address at each forced return shows **one
   caller with 569 292 of them**: `LR = 0x081DC0D9`. Disassembling FireRed
   there, the code after that return reloads `[r0, #4]`, subtracts 1, and on
   the branch-not-taken path does `ldr r3, [pc, #0x0C]` — literal
   `0x030028E1`, the mixer entry — followed by `bx r3`, re-entering the mixer
   without linking. That is m4a's per-buffer re-entry loop, and its exit
   condition is a counter **the mixer body itself decrements**. The probe
   force-returns before the body runs, so the counter never moves and the loop
   never exits. `avg_out_energy` collapsing from 0.1616 to 0.0024 is the same
   fact from the audio side.
3. **A waitloop detector must not "fix" this.** The loop is real work whose
   exit condition the probe deleted, not an idle spin;
   `analyze_loop`'s loop-carried-dependency test correctly refuses it.

There is no win here. (Caveat on a related number: the `-d:pcprofile` region
split reports 64.8% "BIOS" in skip mode and that figure is unreliable — a
forced return makes `tick` return before the profile accounting at
`cpu.nim:84`, so those cycles land in whatever instruction completes next.)

---

## 6. Method notes that cost real time

**A file-swap web A/B is invalid without unregistering the service worker.**
`web/sw.js` precaches `./em.js` and `./em.wasm` by fixed name at root scope, so
it also controls `/bench/`. Swapping the files on disk and reloading measures
whichever build the worker cached **first**, twice — and the framebuffer hashes
match, which reads as confirmation rather than as the tell it is. This produced
a clean-looking "no change on web" for a change that is worth ~1.3% there.
`bench.html` now unregisters service workers before anything loads and exposes
`benchBuildId()`, which reads `em.wasm`'s byte length out of resource timing;
the two builds differ in size, so it is a positive identification. **Every web
number in this document carries that check.**

**And check the server is alive.** `web/serve.py` died three times during this
work (once taking a whole measurement round with it). With the service worker
still registered the page kept loading and behaving normally from cache, so
"the app works" is not evidence the server is up. `curl -w '%{size_download}'`
is.

**Safari reports itself.** It cannot be driven from the shell — `osascript`
gets `-1743` unless Develop > "Allow JavaScript from Apple Events" is enabled.
`bench.html?auto=1` runs the trial, prints it on screen large enough to read
off a photo, and reports it back through the dev server's request log as
`/__benchresult?<text>`. That is also how a phone would report.

---

## 7. `-d:danger`: the full-suite gate

See §4 for the measurement. The gate the user asked for is a full
`dingbat_test_runner` run with `dingbat_test` built `-d:danger`.

**Result: it passes, cleanly.** `dingbat_test` built `-d:danger`, on top of all
five wins in §3, driven by `./dingbat_test_runner` — the mGBA suite, jsmolka,
FuzzARM, and the whole Game Boy side (blargg, mooneye/wilbertpol, Acid2,
MagenTests, Mealybug Tearoom, GBMicrotest, AGE, SameSuite, the shootout ROMs
and gambatte's 5005 cases).

```
Total: 978, Pass: 691, Fail: 287
gambatte total: 3618/5005 passed
```

which is the committed baseline exactly. All three regenerated result files —
`tests/results.md`, `tests/results_gambatte.md`, `tests/results_mgba_suite.md` —
diff against the committed versions at **one line each: the `*Generated:*`
timestamp**. Every row, every count, every actual-vs-expected cell is
unchanged. The runner reported no regressions and exited 0.

So `-d:danger` plus the five wins is a no-op for correctness across every suite
this project runs, and the remaining objection to `-d:danger` is purely the
memory-safety one in §4 — a future bug that would have raised a defect now
wraps silently — not an observed behaviour change.

Measured with `-d:danger` on top of the tip, same 9 interleaved rounds:

| | fps | retired instructions | CPU cycles |
|---|---|---|---|
| stock `-d:release` | 777.6 | 14.2738e9 | 2.4862e9 |
| tip `-d:release` | 829.1 (+6.6%) | 13.0157e9 (−8.81%) | 2.3369e9 (−6.00%) |
| tip `-d:danger` | **880.1 (+13.2% over stock)** | 11.2307e9 (−21.3%) | 2.1940e9 (−11.8%) |

---

## 8. What I would do next, in order

1. **Decide on native `-d:danger`** (§4, §7). One flag, +6.2% on top of the
   wins already landed (+13.2% over stock), already the semantics the web build
   ships, and now gated on a clean full-suite run.
2. **Stop here on `cpu.tick` micro-work.** After W3 and W4 the residual
   stub-out ceiling for the whole per-instruction guard set is −5.0% native, of
   which the HLE gate is −1.28% and the rest is layout-sensitive noise that
   three separate attempts (§5) failed to convert. The one structural idea with
   a clean safety proof — specialising the frame loop — measured **+3.74%**.
   Anything further in `tick` needs a different mechanism, not another
   rearrangement.
3. **If more browser throughput is wanted, re-profile the wasm build first.**
   The `--profiling-funcs` + CDP `Profiler` recipe in the appendix takes about
   two minutes and the wasm attribution is genuinely different from native's —
   `tick` was 46.5% there against 26.7% here.
4. **Leave the renderer alone on this workload** (15.7% / 8.8%), and do not
   plan work off `docs/performance.md`'s 44% without re-measuring.
5. **Still open, not measurable here: HLE vs LLE BIOS**, on any target. It
   needs a BIOS image; the only one on this machine is under
   `~/Documents/emu/gba/`, outside the sandbox. Mechanism (inferred): LLE runs
   the real ARM BIOS for every SWI, so `CpuFastSet`/`CpuSet`/LZ77 become
   emulated instruction streams instead of native loops — expect it to cost
   more than any other single setting on decompression-heavy scenes and nothing
   at all on a scene that issues no SWIs.

---

## Appendix A: settings cost matrix

Unchanged from the first pass except where §5 corrects it. **`DINGBAT_MP2K_SKIP`
has been removed from this table** — it is a developer probe, not a setting
(§5).

### Web — GPU cost of the present draw (Chrome, 960x640 backing store)

| setting | GPU ms/frame | delta |
|---|---|---|
| upscale filter = **none** (default) | 0.185 | — |
| upscale filter = **hq4x** | 0.346 | +0.161 (+87%) |
| upscale filter = **xBR** | 0.763 | +0.578 (+312%) |
| colour correction **on** (default) vs off | 0.186 vs 0.153 | +0.033 (+21%) |
| scanlines on vs off | 0.1857 vs 0.1855 | free |

### Native — GPU cost of the present draw (`-d:gputime`)

| setting | 720x480 | 1440x960 | 2160x1041 |
|---|---|---|---|
| filter none | 0.149 | 0.294 | 0.415 |
| hq4x | 0.207 | 0.511 | 0.769 |
| xBR | 0.309 | 0.921 | 1.429 |
| scanlines | free | free | free |
| colour correction | free | free | free |

Native scales with the window (it draws into the window viewport); web does not
(it draws into a fixed 960x640 backing store and lets CSS stretch). Per
fragment the native shader is about twice as cheap as the WebGL2 one.

### Web — emulation cost (`loop_tick`, ms per emulated frame)

| setting | ms/frame | delta | accuracy trade? |
|---|---|---|---|
| baseline | ~1.95 | — | |
| **motion blur / interframe blending** on | 2.037 (vs 1.938) | +0.099 (+5.1%) | presentation only |
| **MP2K audio HLE** on | 2.087 (vs 1.978) | +0.110 (+5.5%) | **yes** — HLE mixer, not the game's |
| **audio low-pass** on | 1.985 (vs 1.976) | +0.009 (+0.5%) | no (at the noise floor) |
| **run-ahead = 1 / 2 / 3** | 4.393 / 6.258 / 7.998 | **2.23x / 3.17x / 4.06x** | no (rollback of emulated state) |
| scanlines, glow, integer scale, colour correction, filters | no effect | — | |

Run-ahead is the most expensive switch in the product and behaves exactly as
`docs/run-ahead.md` predicts. At N=3 FireRed needs 8.0 ms of a 16.7 ms frame on
an M-series Mac; a device at 3x realtime headroom cannot run it at all.

### Web — main-thread present cost (rAF − tick, ms/frame)

| setting | ms/frame |
|---|---|
| ambient glow off | 0.027 |
| ambient glow on (default) | 0.040 (+0.013) |
| everything else | 0.017-0.045, inside the noise band |

### Native — emulation-side settings

| setting | retired instructions | vs default | fps | vs default |
|---|---|---|---|---|
| default (HLE BIOS, waitloop on, MP2K off) | 13.673e9 | — | 712.8 | — |
| **MP2K audio HLE on** | 14.321e9 | +4.7% | 660.6 | −7.3% |
| **waitloop detection off** | 16.992e9 | +24.3% | 579.8 | −18.7% |

Idle-loop fast-forward is worth **+23% fps** on FireRed and is the most
valuable behaviour in the emulator that has no user switch — correctly.

### Not measurable in this sandbox

| setting | status |
|---|---|
| HLE vs LLE BIOS | Needs a BIOS image outside the sandbox. Open on every target. |
| Native GUI rewind capture, cheats, fast-forward, 2x/slow-mo, pitch-correct FF | Not measured. Rewind is the one worth doing next: it serialises a full state payload — framebuffer included — every 10 frames. |
| Safari present-path settings | `EXT_disjoint_timer_query_webgl2` absent (measured). |
| GB-only settings (pixel FIFO vs scanline PPU, palettes, boot ROM) | Not applicable to FireRed. `DINGBAT_BENCH_RENDERER=fifo\|scanline` is the hook. |

---

## Appendix B: reproducing the headline numbers

```sh
# ---- native: the -8.73% -------------------------------------------------
nimble bench_build                       # -> ./dingbat_bench
cp <rom> /tmp/bench/ ; cp <state> /tmp/bench/          # per-build ROM copy:
                                                       # the core writes .sav
                                                       # next to the ROM
DINGBAT_BENCH_STATE=/tmp/bench/<state> DINGBAT_BENCH_COUNTERS=1 \
  ./dingbat_bench /tmp/bench/<rom> 600 120
#   -> "instructions=..." is the number; best-of-5, spread 0.003%
#   stock 2291784: 14 269 700 536      tip: 13 024 022 151

# bit-exactness gate (both scenes)
DINGBAT_BENCH_STATE=... DINGBAT_BENCH_HASH=1 ./dingbat_bench <rom> 400 0
DINGBAT_BENCH_STATE=... DINGBAT_BENCH_HASH=1 ./dingbat_bench <rom> 400 0 "0:DOWN:2000"

# where the ROM fetch path goes
nim c -d:test_harness -d:release -d:fetchprof --path:src -o:bench_fp tests/dingbat_bench.nim

# ---- native present GPU cost -------------------------------------------
nimble build -d:release -d:gputime
HOME=/tmp/fakehome DINGBAT_GPUTIME_SWEEP=1 DINGBAT_SCALE=9 \
  ./dingbat --skip-bios /tmp/bench/<rom>          # one line per setting, ~16 s
#   HOME is overridden so the run cannot touch the real config.
#   DINGBAT_SCALE, not a window size: load_rom resets the window to
#   GBA_W * scale, so an initial size is discarded when a game loads.

# ---- Chrome: the +8.7% --------------------------------------------------
python3 web/serve.py &                   # port 8765 on main
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9333 --user-data-dir=/tmp/chrome-bench \
  http://localhost:8765/bench/bench.html            # VISIBLE window, not headless
CDP_PORT=9333 node web/bench/cdp.mjs 'window.benchInit()'
CDP_PORT=9333 node web/bench/cdp.mjs 'JSON.stringify(window.benchBuildId())'
#   -> {"size":1292769,...} is stock, {"size":1293159,...} is the tip.
#      If size does not change when you swap em.wasm, the service worker is
#      serving it and the whole A/B is void.
CDP_PORT=9333 node web/bench/cdp.mjs 'JSON.stringify(window.benchHash(400))'
#   -> "155d983d" on every build, every browser
CDP_PORT=9333 node web/bench/cdp.mjs \
  '(()=>{const t=(f,r,h)=>{window.benchSetHle(h);const a=[];for(let i=0;i<r;i++){window.benchLoadState();a.push(window.benchRun(f).fps);}a.sort((x,y)=>x-y);return a[(a.length/2)|0];};return JSON.stringify({off:t(600,7,false),on:t(600,7,true)});})()'
# swap web/em.js + web/em.wasm, reload, repeat; interleave rounds

# ---- Safari: the +9.2% --------------------------------------------------
open -a Safari 'http://localhost:8765/bench/bench.html?auto=1&reps=5'
#   result appears on the page AND in the dev server's request log as
#   /__benchresult?<text>. serve.py must not silence log_message.

# ---- wasm CPU profile with real function names --------------------------
#   add --profiling-funcs to the emcc line in src/dingbat_wasm.nims, rebuild,
#   then drive Profiler.enable/start/stop over CDP around benchRun(2000) and
#   histogram profile.samples by node callFrame.functionName.
```

---

## 9. What the default configuration costs (2026-08-07)

The question was the cost of the **defaults**, not of the maximum
configuration. Short answer: the defaults are well chosen, with exactly one
expensive item.

**Default config vs bare minimum, native, 7 interleaved rounds, FireRed from
the in-game state:**

| | fps | retired instructions | CPU cycles |
|---|---|---|---|
| bare minimum (rewind off) | **819.0** | 13.0173e9 | 2.4006e9 |
| shipped default (rewind on) | 769.8 | 13.5485e9 | 2.5279e9 |
| **cost of the default config** | **−6.0%** | **+4.1%** | **+5.3%** |

All of that is rewind. Every other default is off, free, or a win.

### 9.1 Rewind, broken down

**Cadence:** `REWIND_INTERVAL = 10` emulated frames — **6 snapshots/second**,
confirmed by the counters (60 pushes over 600 frames). Not every frame.

**Per push** (native; `-d:rewindprof`, 604 132-byte payload deflating to
50 099):

| stage | ms/push | share |
|---|---|---|
| `state_payload()` serialize | 0.2136 | 35% |
| XOR against the previous snapshot | 0.0180 | 3% |
| **zlib `BestSpeed` of the delta** | **0.3400** | **56%** |
| keyframe zlib (1 push in 60, amortized) | 0.0155 | 3% |
| eviction at the cap | 0.0000 | 0% |
| **total** | **0.6104** | |
| web only: thumbnail downscale + zlib | +0.0161 | +3% (total 0.6295) |

**Compression is the majority of rewind's cost**, serialization is a third,
and the XOR, the keyframes, the thumbnails and the eviction are all noise.

**As a share of time, two ways, both true:**

- **0.061 ms per emulated frame** = **0.37% of a 16.7 ms realtime frame.**
  Invisible on a desktop.
- **6.0% of the emulator's own CPU work.** On a device with little headroom
  that is 6% of the compute there is, and it is the framing that matters for
  the phones the frontend targets.

**What rewind-off buys, measured on both targets:**

| target | default | rewind off | delta |
|---|---|---|---|
| Native `-d:release`, fps | 769.8 | 819.0 | **+6.4%** |
| Chrome, emulation fps (tight loop, one session, 7 reps) | 526.8 | 558.6 | **+6.0%** |

The Chrome figure is internally consistent: with rewind, the clip-capture note
and the frame prepare all disabled the loop measures 557.3 fps, and bare
`benchFrames` measures 562.7 — so rewind is essentially the entire gap between
what the bench page has always reported and what the shipping frame loop costs.

**Memory and history length.** 3.59 MB after 10 s. At ~50 KB per push and
6 pushes/s the 64 MB cap holds **~3.5 minutes** of history; the iOS 16 MB cap
(`setRewindCapBytes`, applied only when `IS_IOS`) holds **~53 s**. The cap does
**not** change the per-push cost — measured: a 16 MB ring pushes for the same
instruction count as a 64 MB one, because eviction is O(1) amortized and
measured 0.00 ms.

**Correctness note:** framebuffer hashes are byte-identical with the ring off,
in native mode and in web mode, so the ring observes the core rather than
perturbing it.

### 9.2 Run-ahead: OFF by default, on both frontends

`web/index.js`: `let runaheadFrames = 0`, and the stored value only overrides
it if the user picked one. Native has no run-ahead at all. So the 2.23x / 3.17x
/ 4.06x figures for N = 1/2/3 are **opt-in** and are not part of the default
cost. Good — at N=3 it would be 8.0 ms of a 16.7 ms frame on an M-series Mac.

### 9.3 The shipped defaults, priced

Read from `new_config()` in `src/dingbat/common/config.nim` and the variable
initialisers in `web/index.js` (the IDB records only override them), not
assumed.

**Native**

| setting | default | cost of the default | cost if flipped |
|---|---|---|---|
| `rewind` | **true** | **−6.0% throughput** | off: **+6.4%** |
| waitloop detection | on (**no user switch**) | **buys +23% fps** | off: −18.7% |
| `color_correction` | true | **free** (0.4152 vs 0.4152 ms GPU at 2160x1041) | — |
| `video_filter` | `none` | free | hq4x +0.35 ms, xBR **+1.01 ms** GPU at 2160x1041 |
| `mp2k_hle` | false | — | on: −7.3% fps / +4.7% instructions |
| `frame_blend` | false | — | on: a 38 400-pixel CPU blend per present |
| `scanlines` | false | — | on: free |
| `audio_lowpass` | false | — | on: a core APU filter (GBA only, unmeasured) |
| `pitch_correct_ff` | false | — | only during 2x fast-forward |
| `run_bios` / `use_hle` | false / true | the cheap path | LLE unmeasured — no BIOS in this sandbox |
| `gb_fifo` | true | GB only | — |
| `gb_rumble` | true | free unless the cart rumbles | — |
| `volume` / `mute` | 100 / false | frontend gain only | — |
| cheats | none loaded | `apply_cheats` early-outs on a nil/empty check once per frame | — |
| ImGui pass | skipped when no UI is visible | free | — |

**Web**

| setting | default | cost of the default | cost if flipped |
|---|---|---|---|
| rewind | **on, and there is no switch** | **−5.7% throughput** | **cannot be turned off** |
| clip capture (`clip_note_frame`) | on, no switch | −0.9% | n/a |
| frame prepare (`prepare_game_frame`) | on, no switch | −0.4% | n/a |
| `runaheadFrames` | **0 (off)** | free | 1/2/3 = **2.23x / 3.17x / 4.06x** emulation |
| `colorCorrect` | true | +0.033 ms GPU (+21% of the present draw) | off: −0.033 ms |
| `upscaleFilter` | `"none"` | free | hq4x +0.161 ms, xBR +0.578 ms GPU |
| `motionBlur` | false | — | on: +5.1% emulation |
| `ambientGlow` | false | — | on: +0.013 ms/frame main thread |
| `scanlines`, `integerScale` | false | — | free |
| `mp2kHle` | false | — | on: +5.5% emulation |
| `audioLowpass`, `pitchCorrectFF` | false | — | WebAudio node / FF only |
| `gbFifo` | true | GB only | — |
| `gbaBiosMode` | 0 (HLE) | the cheap path | — |
| `gbaRunBios` | **true** | free with no BIOS present | with a BIOS: plays the boot intro |
| `gbRumble` | true | free unless the cart rumbles | — |
| rewind cap | 64 MB, 16 MB on iOS | no per-push difference (measured) | shorter history only |
| everything else per frame (present, audio scheduling, glow, rumble, overlays) | — | 0.019 ms/frame, ~1% of the rAF callback | — |

### 9.4 Where native and web default differently

1. **Rewind has a switch on native and none on web.** `dingbat_wasm.nim`
   allocates the ring at both ROM-load sites (`loadRom` and `netlink_exit`)
   with no gate, and `loop_tick` pushes whenever it is non-nil. So the most
   expensive default in the product is unavoidable on the platform with the
   least headroom — and the one where memory pressure gets the wasm JIT
   demoted, which costs far more than 6%.
2. **Native rewind captures no thumbnails, web does.** `src/dingbat.nim` passes
   no `thumb` proc to `maybe_push`; `dingbat_wasm.nim` does. Only 0.016 ms/push,
   but the web ring also carries a thumbnail strip inside the same memory cap.
3. **`gbaRunBios` defaults `true` on web, `run_bios` defaults `false` on
   native.** No effect without a BIOS file (`make_gba` folds it to
   `have_bios and optGbaRunBios`), but with one installed, web plays the GBA
   boot intro on every load and native skips it. **This looks unintentional.**
4. **Ambient glow and run-ahead are web-only**; interframe blending exists on
   both but is a frontend CPU blend natively and core-side on web, which is why
   it shows up in `loop_tick` on the web measurements and in the present path
   on native.
5. **Audio low-pass** is a core APU filter natively and a WebAudio node on web.
   Same default (off), different mechanism and different cost if enabled.

### 9.5 What to reconsider

1. **Give the web frontend a rewind toggle.** It is the single most expensive
   default in the product, it costs 5.7% on the platform with the least
   headroom, and it is the only default a web user cannot escape. Native
   already has the switch and the menu item. This is the actionable finding.
2. **The delta compression is 56% of rewind's cost** — the obvious lever if
   rewind stays unconditional. Unmeasured options: skip zlib when the XOR delta
   is overwhelmingly zeros and store a sparse/run-length form instead, or drop
   to a cheaper codec. Both trade retained history against CPU, because the cap
   is a real memory budget — so neither is free, and neither should be
   attempted without measuring history length as well as throughput.
3. **Fix the `gbaRunBios` default divergence** (§9.4.3), which costs nothing
   but surprises anyone who installs a BIOS on both frontends.
4. **Everything else is fine.** Run-ahead is off, every cosmetic effect is off,
   the one default-on shader feature (colour correction) is free on native and
   0.033 ms on web, and the two defaults with no user switch that do cost
   something — the clip-capture note and the frame prepare — are 0.9% and 0.4%.
   The instinct that the defaults are performance-conscious is borne out
   everywhere except rewind.

**Not a saving, so recorded separately:** turning colour correction off, or
running the GB scanline renderer instead of the pixel FIFO, would buy time at
the cost of fidelity. Neither is recommended as a default change.

**Forward risk.** A parallel branch adds bounds-checking to the save-state
loader. Rewind shares `state_payload`/`apply_state_payload` with that path, and
serialization is already 35% of rewind's cost — so if those checks land on the
*write* side, rewind's cost goes up with them. Worth re-running
`-d:rewindprof` after that merge. (Measured here against this branch only.)

---

## 10. Rewind compression: what the delta is, and what beats zlib (2026-08-07)

Base for every number here: **this branch** (`agent-fireredperf`, `6ddcbe9`),
not `main` — `main` has since taken the five §3 wins and a save-state loader
fix. Numbers are self-consistent; treat the absolutes as branch-relative.

The brief was Pareto improvements — denser **and** faster — with trades
reported separately. There is one large Pareto win, and it is not a codec.

### 10.1 The delta is 87% zeros, and 40% of that is an alignment bug

Characterising before choosing a codec killed most of the candidate list in ten
minutes. FireRed, in-game overworld, snapshots on the ring's cadence:

| | shipped | after the alignment fix |
|---|---|---|
| zero bytes | 87.46% | **99.15%** |
| dirty 64 B blocks | 14.91% | 2.05% |
| dirty 4 KB pages | 27.45% | 12.97% |
| changed bytes per delta | 75 782 | **5 158** |

**The zeros are not in long runs.** The zero-run histogram is dominated by
1-byte and 2-byte runs (166 593 and 88 608 of ~326 000). Changed bytes are
*scattered*, not clustered — which is why a dirty-page scheme loses badly
(`sparse4k` encodes to 340% of zlib's size) and why "ship only changed 4 KB
pages" is dead on arrival.

**Where the changed bytes were, and the bug that put them there.** Attributing
the delta by payload section showed 41 264 B in the PPU section and 31 079 B in
the 128 KB save chip — on an idle overworld, where the save chip cannot be
changing at all. Tracing per push showed why:

```
push  4 len=604135  ppu=2328    storage=0
push  5 len=604126  ppu=104119  storage=80402
push  6 len=604135  ppu=104041  storage=80400
push  7 len=604135  ppu=2319    storage=0
```

The payload alternates between **604 135 and 604 126 bytes — 9 bytes, exactly
one scheduler event** (`u8` kind + `u64` cycles). The scheduler section is the
only variable-length part of a GBA payload, and it sits *before* 300 KB of
fixed-size arrays. One event coming or going shifts all of them, the XOR then
compares misaligned VRAM, framebuffer and flash, and ~184 KB of unchanged data
lights up. On FireRed this happens on **40% of pushes**, silently.

It is workload-dependent: goodboy-demo's event count does not oscillate and its
delta is unaffected (11 559 B shipped vs 11 553 B aligned). So it is free when
it does not bite and 8.5x when it does, and which one a user gets is timing
luck.

### 10.2 Candidates, all three targets

Every codec round-trips bit-exactly on every delta or the harness aborts.
Native is `-d:release` on an M-series Mac; Chrome and Safari run the *same*
Nim code compiled to wasm (`-d:codecbench`), over the same deltas, because the
ranking does not survive the move between engines.

**Shipped payload (variable length), FireRed idle:**

| codec | bytes | native enc | Chrome enc | Safari enc |
|---|---|---|---|---|
| zlib:BestSpeed (shipped) | 48 380 | 0.355 | 0.661 | 0.739 |
| lz4 | 34 906 (78%) | 0.124 | 0.246 | 0.217 |
| sparse64+zlib | 43 027 (97%) | 0.165 | 0.491 | 0.449 |
| sparse64+lz4 | 33 020 (74%) | 0.117 | 0.325 | 0.174 |
| sparse4k | 78 677 (163%) | 0.147 | — | — |

**Fixed-length payload (alignment fixed) — the state that matters:**

| codec | bytes | ratio | native enc | Chrome enc | Safari enc | native dec |
|---|---|---|---|---|---|---|
| **zlib:BestSpeed (shipped)** | 5 693 | 100% | 0.165 | 0.354 | 0.362 | 0.203 |
| zlib:Default | 5 438 | 96% | 0.701 | 0.955 | 1.029 | 0.196 |
| lz4 | 7 798 | 137% | 0.124 | 0.086 | 0.087 | 0.700 |
| sparse64 (no zlib) | 13 346 | 235% | 0.089 | 0.042 | 0.101 | 0.012 |
| **sparse64+zlib** | **4 504** | **79%** | **0.165** | **0.132** | **0.145** | **0.047** |
| sparse32+zlib | 4 537 | 79% | 0.178 | 0.151 | 0.101 | 0.054 |
| sparse256+zlib | 4 598 | 80% | 0.167 | 0.158 | 0.073 | 0.043 |
| sparse64+zlib:Default | 4 354 | 77% | 0.274 | 0.193 | 0.174 | 0.045 |
| sparse64+lz4 | 5 579 | 98% | 0.117 | 0.077 | 0.087 | 0.029 |

**The ranking genuinely differs by engine.** On native, `sparse64+zlib` merely
breaks even on encode (0.165 vs 0.165) — its whole value is density and a 4.3x
faster decode. Under wasm, zippy's deflate is far slower relative to a flat
scan, so the same codec is **2.7x faster on Chrome and 2.5x faster on Safari**.
A table taken on the desktop would have called this a trade; Safari calls it a
clear win, and Safari is the tiebreaker.

`lz4` is the reverse story: 137% of zlib's size once the delta is aligned. It
only looked good on the *unaligned* delta, where its long-match encoding
handled the 184 KB of shift damage that should not have been there. Fixing the
alignment removed its advantage.

### 10.3 Pareto wins, end to end

| | delta bytes | native push | Chrome: rewind's share | Safari: rewind's share |
|---|---|---|---|---|
| shipped | 48 380 | 0.666 ms | 6.48% | 7.14% |
| + alignment fix | 5 693 (−88%) | 0.472 ms (−29%) | — | — |
| **+ sparse64 pre-pass** | **4 504 (−90.7%)** | **0.456 ms (−32%)** | **1.53%** | **3.23%** |

Both axes improve on all three targets. Per-stage native minima, interleaved:

| stage | shipped | +align | +align+sparse |
|---|---|---|---|
| serialize | 0.2336 | 0.2305 | 0.2319 |
| xor | 0.0196 | 0.0195 | 0.0195 |
| **compress** | **0.3546** | **0.1648** | **0.1467** |
| thumbnail (grab+zlib) | 0.0171 | 0.0170 | 0.0171 |
| keyframe zlib (amortized) | 0.0162 | 0.0165 | 0.0165 |
| **total** | **0.6662** | **0.4723** | **0.4557** |

Padding costs nothing measurable in serialize (0.2336 → 0.2319), so the 486
extra bytes are free.

### 10.4 History at cap — the axis that matters on the SE 1

The ring is a memory budget, so density *is* history. Amortized per push:
delta + keyframe/60 (157 286 B each) + thumbnail/6 (2 621 B each), against the
cap minus the 604 KB uncompressed `latest`.

| | bytes/push | **64 MB desktop** | **16 MB iOS** |
|---|---|---|---|
| shipped | 51 438 | 3.6 min | **52 s** |
| + alignment | 8 751 | 21.1 min | **5.1 min** |
| + alignment + sparse64 | 7 562 | 24.4 min | **5.9 min** |
| + `REWIND_KEY_EVERY` 60→180 | 5 815 | 31.8 min | **7.7 min** |

**On the iOS cap the fix turns 52 seconds of history into nearly six minutes.**
That is the number to weigh for the SE 1, and it costs less CPU rather than
more.

The last row is a new consequence, not a pre-existing option: once the delta
drops 10x, the **keyframe becomes 35% of the ring's memory**. Raising
`REWIND_KEY_EVERY` to 180 buys another 30% of history, and a scrub seek stays
*faster than today* despite walking 3x more deltas, because sparse decode is
4.3x cheaper (180 × 0.047 = 8.5 ms against today's 60 × 0.203 = 12.2 ms).

### 10.5 Trades and non-starters

| candidate | verdict |
|---|---|
| `sparse64+zlib:Default` | **Trade.** 3% denser than `sparse64+zlib`, 66% slower to encode on native. Not worth it. |
| `sparse64+lz4` | **Trade.** Fastest encode everywhere (0.077 ms Chrome) but 24% larger than `sparse64+zlib` — and on a memory-capped ring, size is history. Pick it only if CPU is the binding constraint and history is not. |
| plain `lz4` | **Rejected.** 137% of zlib's size on aligned deltas. Kept in-tree because the bake-off needs it and it may suit other payloads. |
| dirty 4 KB page bitmap | **Rejected on the data.** 340% of zlib's size — changed bytes are scattered, not page-clustered. |
| `sparse64` with no entropy stage | **Rejected.** 235% of zlib. The bitmap removes zeros; it does not compress what is left. |
| **Dirty tracking at the source** | **Not attempted, and I recommend against.** It would have to instrument every write to EWRAM/IWRAM/VRAM/PRAM/OAM/flash. Those paths are `bus.write_*`, which the §2 profile puts at the centre of the hot loop, and §3 measured a *single extra load and branch* there at 1.2% of all retired instructions. A dirty-bit set per write would cost multiples of the 0.34 ms it aims to save, every frame, to save it 6 times a second. The XOR is already only 0.02 ms — 3% of the push — so diffing is not the expensive part. |
| **`CompressionStream`** | **Not a candidate, on two independent grounds.** It is asynchronous: it yields a `ReadableStream`, and the rewind push happens inside a synchronous wasm call from rAF. Using it means copying 604 KB out of wasm memory, awaiting a microtask, and keeping the raw payload alive meanwhile — an async ring, more peak memory, on the device with the least. And per MDN it needs **Safari 16.4+**, while an iPhone SE 1 tops out at iOS 15, so the fallback is what would actually run there — which makes the fallback the number that matters. I measured `CompressionStream: true` on desktop Safari 26.6 and Chrome; I could not test iOS 15 and did not. |
| Cadence (`REWIND_INTERVAL` 10 → 12) | Not measured. Worth knowing it is a lever, but after the fix the delta is small enough that cadence is no longer where the money is. |
| Skipping a push when nothing changed | Not implemented. After the alignment fix an idle frame's delta is ~5 KB, not ~0, because the framebuffer and EWRAM always move a little; a true "nothing changed" case is rare in a running game. Low value. |

### 10.6 Allocation behaviour, which matters more on the SE 1 than ms/push

`sparse_encode` allocates one output string per call (~13 KB after the fix,
against the 604 KB the XOR body already allocates) and zlib allocates its own
output. So the pre-pass adds one small transient allocation per push, 6 times a
second — small next to what `encode_delta` already does, but it is not zero,
and on a 2 GB device with a demotable JIT that is worth saying out loud. Both
`sparse_encode` and `sparse_decode` can be rewritten against a preallocated
scratch buffer without changing the format; the LZ4 encoder already keeps its
hash table in a reused `threadvar` for exactly this reason. The codecs that
*cannot* work in a scratch buffer are the zlib levels, because zippy owns its
allocation.

### 10.7 What I prototyped, and what shipping still needs

Both prototypes are on this branch behind defines, off by default
(`6ddcbe9`): `-d:schedpad` (fixed-length payload) and `-d:rewindsparse`
(sparse pre-pass). The default build's framebuffer hash is unchanged.

Correctness evidence: the rewind property tests pass with either define and
with both; `DINGBAT_BENCH_REWIND_VERIFY=1` pops all 120 retained snapshots,
applies each to the live core and re-serializes with **0 mismatches** in every
configuration; the bake-off round-trips every delta of three workloads across
two ROMs.

**The one thing shipping needs that the prototype does not carry.** The
prototype pads via a global switch flipped after the state load, because a
padded payload cannot be read by an unpadded build. The shipping form should
thread a `pad` flag through the **in-process** serialization path only — the
rewind ring and rollback snapshots never outlive the process (`savestate.nim`
says so), so padding them costs **no format change, no payload-revision bump,
and file save states stay byte-identical**. Making the padding unconditional
instead would need `GBA_PAYLOAD_VERSION` 5 → 6 plus a migration. The GB core
shares the scheduler and therefore shares the hazard; it is unmeasured.

### 10.8 Recommendation

1. **Take the alignment fix.** It is the whole prize: 8.5x smaller deltas, 29%
   less push time, 52 s → 5.1 min of iOS history, and it removes a silent
   pathological case rather than tuning a good one. Ship it as an in-process
   flag so no save-state format changes.
2. **Take the sparse64 pre-pass with it.** A further 21% density, and on the
   two engines that matter it is also 2.5-2.7x faster to encode and 4-6x
   faster to decode. Native breaks even on encode and still wins on both other
   axes.
3. **Then reconsider `REWIND_KEY_EVERY`** — 60 → 180 buys 30% more history and
   seeks *faster* than today.
4. **Do not build source-side dirty tracking, and do not build on
   `CompressionStream`.** §10.5 has the reasons.
5. **Check the GB core for the same alignment hazard.** Same scheduler, same
   shape of payload, unmeasured.

### Reproducing

```sh
# native: characterisation + bake-off (add -d:schedpad for the aligned case)
nim c -d:test_harness -d:release -d:deltachar --path:src \
      -o:rewind_codec tests/rewind_codec_test.nim
./rewind_codec <rom> 1200 120 <state>          # DELTA_TRACE=1 for per-push

# native: end-to-end push cost, three configurations
nim c -d:test_harness -d:release -d:rewindprof [-d:schedpad] [-d:rewindsparse] \
      --path:src -o:rwb tests/dingbat_bench.nim
DINGBAT_BENCH_REWIND=web DINGBAT_BENCH_REWIND_VERIFY=1 \
  DINGBAT_BENCH_STATE=<state> ./rwb <rom> 1200 120

# browser: same codecs, same deltas, in-page
nim c -d:emscripten -d:codecbench -d:schedpad src/dingbat_wasm.nim
open http://localhost:8765/bench/bench.html?codecs=1     # Safari reports itself
#   -> result also lands in the dev server log as /__benchresult?<text>

# ON A REAL DEVICE the origin must be https. A plain-http LAN origin makes
# iOS withhold the JIT and every number comes out ~10x slow.
```

