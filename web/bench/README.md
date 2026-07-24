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
