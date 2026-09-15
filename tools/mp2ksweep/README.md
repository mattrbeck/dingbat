# MP2K HLE library sweeps and timing analysis

The tooling behind `tests/mp2k_sweep_results/SUMMARY.md`. It measures the MP2K
HLE (`src/dingbat/gba/mp2k.nim`) against the game's own DirectSound FIFO
stream, over the whole archive and then title by title. Nothing here is built
or run in CI; it needs the ROM archive.

The HLE's known limitations, and what was tried against them, are in
`tools/mp2kprobe/README.md` under "Known limitations".

## Pieces

| File | What it does |
|---|---|
| `build_at.sh` | Builds the sweep, probe, census or bench harness from any commit (`git archive`, checkout untouched) or the working tree. |
| `sweep.sh` | Runs a sweep binary over `picked.txt` (via `tools/mp2k_sweep.py`), 8 workers, about 6 minutes. |
| `runs.py` | Reports on sweep JSONL: `summary`, `regressions`, `byrate`, `triage`, `engagement`, `census`, `starts`. |
| `capture.sh` | Per title and build tag: both audio captures, the harness JSON and the pass dump. |
| `wavs.py` | Per-title timing: `segments`, `buildlag`, `framelag`, `passes`, `calib`. |
| `bench_ab.sh` | Retired-instruction A/B of two bench binaries on Emerald and Beast Shooter, HLE off and on. |
| `picked.txt` | The 2354 ROMs every sweep in SUMMARY.md ran: one per title, from `tools/mp2k_dedupe.py`. |
| `experiments/` | Patches for approaches that were measured and dropped, kept so they can be revisited. |

`tools/mp2k_sweep.py` (the parallel driver), `tools/mp2k_dedupe.py`,
`tools/mp2k_compare.py` and `tools/mp2k_triage.py` predate this directory and
are still used as they are.

The ROM archive is `$MP2K_ROMS` (default `~/Documents/emu/gba/archive/roms`).
ROMs are copied beside the harness for each run and deleted afterwards, so a
save file never lands in the archive.

## The metric

Each harness run boots a ROM for 900 frames with the HLE armed. It captures
the HLE's render and the real FIFO stream over the same span, from the
frames the HLE is engaged. `xcorr0` is their lag-0 sample correlation. A
"music" title is one that is engaged at the end with an audible real stream
(`real_rms >= 3`); regressions are counted over those 780 titles.

The real stream is the emulator's own FIFO with its cubic reconstruction,
not hardware. Lag-0 correlation is very sensitive to timing on bright
content: 2 output samples (60 µs) takes Steel Empire from 0.98 to 0.64. A
change of a few hundredths is a sample of timing, not something audible.

Until 2026-09-15 the harnesses kept one real-stream sample from before the
HLE was armed, so the two captures sat a sample apart. `build_at.sh` patches
that into every build it makes. Compare only runs built that way, and
re-sweep an old baseline rather than reusing its old results.

## Regression workflow

```sh
T=/tmp/mp2k    # anywhere outside the repo
tools/mp2ksweep/build_at.sh 15d418042 sweep $T/sweep_base
tools/mp2ksweep/build_at.sh WORKTREE  sweep $T/sweep_new
tools/mp2ksweep/sweep.sh $T/sweep_base $T/run_base
tools/mp2ksweep/sweep.sh $T/sweep_new  $T/run_new
tools/mp2ksweep/runs.py summary     $T/run_base/results.jsonl $T/run_new/results.jsonl
tools/mp2ksweep/runs.py regressions $T/run_base/results.jsonl $T/run_new/results.jsonl --list-out $T/worse.txt

# title by title
tools/mp2ksweep/capture.sh $T/sweep_base base $T/cap --list $T/worse.txt
tools/mp2ksweep/capture.sh $T/sweep_new  new  $T/cap --list $T/worse.txt
tools/mp2ksweep/wavs.py segments base,new $T/cap/*
tools/mp2ksweep/wavs.py passes new $T/cap/*
```

`segments` gives each build's lag against its own reference per half second
(positive means the HLE is late). Two patterns separate the causes:
- **Jumps and slides** in a few seconds after a song start point at
  placement.
- **A steady walk** points at the render itself. `buildlag` compares two
  builds' HLE outputs directly, and `framelag` holds placement fixed while
  the content lag moves.

## The pass dump

A `-d:mp2kwav` build with `DINGBAT_PASSDUMP=file` writes one line per
rendered pass. Each line has:
- the pass number;
- the capture index where the HLE put the frame's first sample;
- the capture index where the byte the pass's first ring store wrote left
  the FIFO, then the same for the model's slot start;
- the kind: `N` level control, `S` slot timing, `R` replacement;
- diagnostics.

Placed minus pop is the frame's placement error before the reconstruction
delay. The ideal is two DMA periods less half a sample, which `wavs.py
calib` fits per rate.

## Harness switches (-d:mp2kwav builds)

| Variable | Effect |
|---|---|
| `DINGBAT_SWEEP_WAV=prefix` | write `prefix.hle.wav` / `prefix.real.wav` |
| `DINGBAT_PASSDUMP=file` | the pass dump above |
| `DINGBAT_POSDUMP=<channel>` | per pass, the engine's sample position (size − count) against the HLE cursor, on stdout |
| `DINGBAT_LATDUMP=1` | the first 40 latency crossings (the estimate used before a slot has been heard) |
| `DINGBAT_PREDDUMP=1` | envelope prediction misses |
| `DINGBAT_CHDUMP=<channel>\|all` | note-on retriggers |
| `DINGBAT_MP2K_BAND=<samples>` | the level-control trim band while no slot has been heard |
| `DINGBAT_MP2K_PIPE_SRC=<samples>` | the estimate's FIFO pipeline constant |
| `DINGBAT_MP2K_LATE=1` | render each pass one pass late (no envelope prediction) |
| `DINGBAT_NOHLE=1` | boot with the HLE disarmed |
| `DINGBAT_SWEEP_DRIVE=1` | mash A/START (menu-gated titles) |

## Benchmarks

```sh
tools/mp2ksweep/build_at.sh main     bench $T/bench_main
tools/mp2ksweep/build_at.sh WORKTREE bench $T/bench_new
MP2K_BENCH_EMERALD=... MP2K_BENCH_BEAST=... tools/mp2ksweep/bench_ab.sh $T/bench_main $T/bench_new 5
```

Emerald needs its `.sav` beside the ROM: the script walks from the title
screen into Littleroot. Compare the minimum retired instructions. Wall-clock
differences under about 1.3 % are code layout, not the change
(`docs/performance.md`).

## Experiments

`experiments/rate-lock.patch` (`git apply`) plays each voice at the rate its
engine sample position has averaged since the note began, once 16 passes
are in. It fixes Disney Sports American Football (0.915 → 0.974) and Don-chan
Puzzle (0.970 → 0.991). It breaks Bass Tsuri Shiyouze (0.993 → 0.961) and
J.League Winning Eleven 2002 (0.848 → 0.761), whose count fields advance
slower than the waveform they play. See "Known limitations".
