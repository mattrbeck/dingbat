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
