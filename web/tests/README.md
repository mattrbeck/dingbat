# web/tests

Unit tests for the storage / Google Drive backup layer of `web/index.js`.

Run (no dependencies, plain `node:test`):

```
node --test web/tests/*.test.mjs
```

(Node 24's runner needs file patterns; a bare `node --test web/tests/` directory
argument is treated as an entry module and fails.)

Approach: `helpers.mjs` evaluates the **real, unmodified** `web/index.js` in a
`node:vm` context with stubbed browser globals (fake DOM, a Map-backed fake
IndexedDB with real async request semantics, controllable `fetch` for the Drive
API), then harvests the app's top-level functions from the context's shared
global lexical scope — so tests exercise the actual app code and break when its
behavior changes.

### Canvas and `ImageData`

The fake 2D context is a permissive no-op Proxy, with two exceptions:
`getImageData` and `createImageData` return a real `FakeImageData` whose
`.data` is a zeroed `Uint8ClampedArray`. Those two are *read from* rather than
drawn into — the film-strip scrubber bakes its desaturated copy by reading
pixels back out — so returning `undefined` there is not "nothing happens", it
is `undefined.data` at module-eval time, which takes every test in the suite
down with it. `ImageData` itself is stubbed in the sandbox for the same reason
(`bgr555ToImageData` constructs one directly).

### Observing toasts

`app.toasts` is every message the app has shown, `app.liveToasts()` only the
ones currently on screen. Both are read from the real DOM the app builds:
`#toast` is a stack container and each message is a `.toast-item` child, so the
harness hooks the container's `prepend`/`append`/`appendChild` and records the
`.toast-msg` text at the moment a pill is mounted. If a node is mounted with no
`.toast-msg`, the harness **throws** rather than recording nothing — a silently
empty `toasts` list would turn every toast assertion in the suite into a no-op.
Change the toast DOM shape in `web/index.js` and you must update `toastMsgOf`
in `helpers.mjs` to match.

## Static typecheck gate (JSDoc + `tsc --checkJs`)

CI also typechecks the front-end as-is — the shipped `.js` files are checked
directly (`allowJs`+`checkJs`+`noEmit`, non-strict), no build step and zero
shipped bytes change. tsc treats plain scripts as one shared global scope,
which matches the script-tag architecture exactly. Three projects under
`web/types/` mirror the real `<script>` tags:

```
npx tsc -p web/types/tsconfig.main.json    # index.html: glpresent, index, sdputil, netplay
npx tsc -p web/types/tsconfig.embed.json   # embed.html: glpresent, embed
npx tsc -p web/types/tsconfig.sw.json      # sw.js (WebWorker lib)
```

What it catches: renaming/removing a wasm export (`Module._foo`) or a
cross-file `window.*` global now fails CI instead of dying silently at
runtime, plus the usual wrong-element/wrong-argument slips.

Two declaration files back it:

- `web/types/em.d.ts` — **generated** from the `{.exportc.}` procs in
  `src/dingbat_wasm.nim`. Regenerate after changing wasm exports:
  `node web/types/gen-emdts.mjs` (CI runs `--check` and fails if it's stale).
- `web/types/globals.d.ts` — hand-written cross-file contracts. Rule: any new
  cross-file global (a `window.<name> = ...` consumed by another file, a UMD
  export, an expando property on a DOM element) gets declared here;
  file-local symbols never do.

## Several devices in real browsers (`web/e2e/`)

The node:vm harness above cannot run the wasm core, lay out a page, or be
two devices at once. `web/e2e/` can: each "device" is a Playwright browser
context (its own IndexedDB and localStorage) running the real build, in
Chromium or WebKit, and every device in a test shares one fake Google Drive
(`e2e/fakedrive.mjs`, routed in by Playwright, so nothing leaves the
machine). A generated test ROM (`e2e/synctest-rom.mjs`) writes its battery
save while A is held and shows the saved value on screen, so a save and a
picture can be checked across devices. Actions go through the visible UI;
`e2e/devices.mjs` holds them and the observations.

```
cd web && npm ci && npx playwright install chromium webkit
nim c -d:emscripten src/dingbat_wasm.nim       # from the repo root: em.js/em.wasm
node --test e2e/*.e2e.mjs                      # from web/
```

Two files: `handoff.e2e.mjs` (the hand-off's cases one by one) and
`fourteen-steps.e2e.mjs` (Matt's 14-step story, play on one device, pick up
on the other and back, for every way the second device can be opened and
with and without an in-game save; "the same place" is the whole
framebuffer, exactly). `DINGBAT_E2E_PAIRS=iphone+mac` narrows the device pairs (kinds: `iphone`,
`iphone-private`, `mac`, `mac-webkit`); `DINGBAT_E2E_NO_CHROMIUM=1` makes
the Mac WebKit too (CI does: its runners draw Chromium's WebGL in software
at about three frames a second - `node e2e/speed-probe.mjs` measures it);
`DINGBAT_E2E_SLOW=4` slows the Chromium devices' CPU; `DINGBAT_WEB=<dir>` serves another
copy of web/, e.g. one with an older index.js, to see a test fail on the
code it guards. Two WebKit quirks the rig works around: it does not show
Playwright a Blob request body (the rig reads bodies bound for Google into
bytes first), and a context with no profile on disk keeps no Blob in
IndexedDB, as Safari's private browsing does (so `iphone` has a profile and
`iphone-private` does not). CI runs it as the `web-e2e` job.
