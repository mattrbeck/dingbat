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
