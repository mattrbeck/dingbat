// Every static file index.html loads must be in sw.js's ASSETS: the
// production SW is cache-first with no runtime caching, so a missing script
// fails offline and index.js dies at its first global (b92e72e shipped that).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

// ASSETS normalized to bare file names ("./" kept as "").
const swAssets = () => {
  const m = read("sw.js").match(/const ASSETS = \[([^\]]+)\]/);
  assert.ok(m, "ASSETS list not found in sw.js");
  return new Set(
    [...m[1].matchAll(/"\.\/([^"]*)"/g)].map((x) => x[1]),
  );
};

// Only <script src> and stylesheet/manifest links are enforced; conditional
// loads (?probe) and icons are not offline-critical.
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
    // em.js / em.wasm are build outputs, absent in a fresh checkout.
    if (f === "em.js" || f === "em.wasm") continue;
    assert.doesNotThrow(() => read(f), f + " is in ASSETS but not on disk");
  }
});
