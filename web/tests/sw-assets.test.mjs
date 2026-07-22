// Tripwire: every static file index.html actually loads must be in the
// service worker's precache ASSETS list. The production SW is cache-first
// with no runtime caching, so any script/stylesheet missing from ASSETS is
// served from the network only — and offline, its load fails and index.js
// dies at the first use of the missing script's globals. This shipped once:
// glpresent.js was added to index.html (b92e72e) but not to sw.js, so the
// deployed PWA half-booted offline ("createGlRenderer is not defined").
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

// The SW ASSETS entries, normalized to bare file names ("./" -> index.html's
// navigation entry, kept as "").
const swAssets = () => {
  const m = read("sw.js").match(/const ASSETS = \[([^\]]+)\]/);
  assert.ok(m, "ASSETS list not found in sw.js");
  return new Set(
    [...m[1].matchAll(/"\.\/([^"]*)"/g)].map((x) => x[1]),
  );
};

// Static, same-origin, unconditionally-loaded references in index.html.
// Conditional loads (pacing-probe.js behind ?probe) and icons that only
// matter at install/bookmark time (favicons, touch icons) are not offline-
// critical, so only <script src> and stylesheet/manifest links are enforced.
const htmlRefs = () => {
  const html = read("index.html");
  const refs = [];
  for (const m of html.matchAll(/<script src="([^"]+)"/g)) refs.push(m[1]);
  for (const m of html.matchAll(
    /<link rel="(?:stylesheet|manifest)"[^>]*href="([^"]+)"/g,
  )) refs.push(m[1]);
  for (const m of html.matchAll(/<link[^>]*href="([^"]+)"[^>]*rel="(?:stylesheet|manifest)"/g))
    refs.push(m[1]);
  return refs.filter((r) => !/^(https?:)?\/\//.test(r));
};

test("every script/stylesheet/manifest index.html loads is precached by sw.js", () => {
  const assets = swAssets();
  const missing = htmlRefs().filter((r) => !assets.has(r));
  assert.deepEqual(
    missing,
    [],
    "index.html references files the service worker never precaches — " +
      "these 404 offline and break the app: " + missing.join(", "),
  );
});

test("wasm module files are precached", () => {
  const assets = swAssets();
  for (const f of ["em.js", "em.wasm"]) {
    assert.ok(assets.has(f), f + " missing from sw.js ASSETS");
  }
});

test("precached files all exist on disk", () => {
  for (const f of swAssets()) {
    if (f === "") continue; // "./" navigation entry
    // em.js / em.wasm are emscripten build outputs, absent in a fresh checkout
    if (f === "em.js" || f === "em.wasm") continue;
    assert.doesNotThrow(() => read(f), f + " is in ASSETS but not on disk");
  }
});
