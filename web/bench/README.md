# Browser throughput bench

Measures pure emulation throughput in the browser: `_benchFrames` steps the core without
presenting, so the number is emulation only — no rAF pacing, texture upload or audio
scheduling.

## Running

Drop a ROM and a matching `.state` next to `bench.html` (both gitignored), serve `web/`
and open the page:

```sh
cp ~/roms/PokemonFireRed.gba ~/PokemonFireRed.state web/bench/
python3 web/serve.py                       # http://localhost:8765
```

`bench.html` exposes `window.benchInit()`, `benchLoadState()`, `benchSetHle(bool)`,
`benchRun(frames)` and `benchTrial(frames, reps)`. Reload the state before every rep —
`benchFrames` advances the game, so back-to-back reps drift into different scenes.

`cdp.mjs` drives the page from the shell over the Chrome DevTools Protocol:

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 --user-data-dir=/tmp/chrome-bench http://localhost:8765/bench/bench.html &
node web/bench/cdp.mjs 'window.benchTrial(300, 7)'
```

`CDP_THROTTLE=<n>` applies `Emulation.setCPUThrottlingRate`, a rough stand-in for slower
hardware (it scales compute, not cache or memory latency). Full speed on FireRed with
audio HLE holds to roughly a 7x throttle on an M2 performance core; read that as headroom,
not a device list. `nbench.sh` is the native counterpart with noise rejection.

## Measure in a real window, not headless

Headless (or fully occluded) Chrome gets background QoS from macOS and lands on
efficiency cores, roughly halving these numbers on Apple Silicon — the whole renderer,
not just wasm. Automation that launches Chrome headless (most MCP/Puppeteer setups)
reports what looks like a catastrophic regression. Benchmark in a visible window, and
check `navigator.webdriver === false` and the JS spin time before trusting a result.

## Memory over a session

`session.js` adds `window.benchSession()`: loads several ROMs back to back and reports
wasm heap plus ROM bytes still in the Emscripten FS. MEMFS keeps file contents on the JS
heap, so `Module.memory.buffer.byteLength` does not account for them — check `FS.stat()`
sizes, and treat `performance.memory.usedJSHeapSize` as too GC-noisy to attribute
megabytes with.
