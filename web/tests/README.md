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
