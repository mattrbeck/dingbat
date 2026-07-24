# Browser throughput bench

Measures pure emulation throughput in the browser — `_benchFrames` steps the
core without presenting, so the number is emulation only, with no rAF pacing,
texture upload or audio scheduling in the way.

## Running

Drop a ROM and a matching `.state` next to `bench.html` (both are gitignored),
then serve `web/` and open the page:

```sh
cp ~/roms/PokemonFireRed.gba web/bench/
cp ~/PokemonFireRed.state    web/bench/
python3 web/serve.py                       # http://localhost:8765
```

`bench.html` exposes `window.benchInit()`, `benchLoadState()`,
`benchSetHle(bool)`, `benchRun(frames)` and `benchTrial(frames, reps)`.
Reload the state before every rep so each rep measures the identical workload —
`benchFrames` advances the game, so back-to-back reps otherwise drift into
different scenes.

`cdp.mjs` drives the page from the shell over the Chrome DevTools Protocol:

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 --user-data-dir=/tmp/chrome-bench \
  http://localhost:8765/bench/bench.html &
node web/bench/cdp.mjs 'window.benchTrial(300, 7)'
```

## Measure in a real window, not headless

**Headless Chrome roughly halves these numbers on Apple Silicon.** A headless
(or fully occluded) renderer gets background QoS from macOS and is scheduled
onto efficiency cores; the same build measured 185 fps headless and 441 fps in
a visible window on an M2, with the pure-JS spin probe confirming the whole
renderer was ~30% slower, not just wasm. Automation harnesses that launch
Chrome headless — including most MCP/Puppeteer setups — will report numbers
that look like a catastrophic regression and are purely an artifact.

Always benchmark against a Chrome launched with a visible window, and sanity
check `navigator.webdriver === false` plus the JS spin time before trusting a
result.

## Simulating an old device

`cdp.mjs` honours `CDP_THROTTLE=<n>`, which applies
`Emulation.setCPUThrottlingRate` — a rough stand-in for slower hardware.
Measured on an M2, FireRed from the in-game save state with audio HLE on:

| throttle | fps | realtime |
|---|---|---|
| 1x | 447.9 | 7.50x |
| 2x | 213.9 | 3.58x |
| 4x | 105.5 | 1.77x |
| 6x | 70.3 | 1.18x |
| 8x | 52.5 | 0.88x |

So full speed needs hardware no more than ~7x slower than an M2 performance
core. Read that as the headroom budget, not a device compatibility list —
throttling scales compute but not cache or memory latency.

## Memory over a session

`session.js` adds `window.benchSession()`, which loads several ROMs back to
back and reports wasm heap plus how many ROM bytes are still sitting in the
Emscripten FS. Note that MEMFS keeps file contents on the **JS** heap, so
`Module.memory.buffer.byteLength` does not account for them — check
`FS.stat()` sizes, and treat `performance.memory.usedJSHeapSize` as too
GC-noisy to attribute megabytes with.
