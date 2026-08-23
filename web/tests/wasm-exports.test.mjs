// Every wasm function the front-end calls must be in EXPORTED_FUNCTIONS: a
// missing export fails silently behind the `!Module._name` guards (the clip
// picker shipped that way). EXPORT_ALL does not save it: at -O3 the names
// are minified and em.js only wires `Module["_name"]` for the listed ones.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");

const exported = () => {
  const nims = read("../../src/dingbat_wasm.nims");
  const m = nims.match(/EXPORTED_FUNCTIONS=([^\s"]+)/);
  assert.ok(m, "EXPORTED_FUNCTIONS not found in src/dingbat_wasm.nims");
  return new Set(m[1].split(","));
};

// Module.ccall / cwrap take bare names, but nothing uses them for clip or
// rewind, so an identifier scan is the whole surface.
const used = (file) => {
  const src = read("../" + file);
  const names = new Map();   // name -> first line it appears on
  const note = (name, index) => {
    if (!names.has(name)) names.set(name, src.slice(0, index).split("\n").length);
  };
  for (const m of src.matchAll(/Module\.(_[A-Za-z0-9_]+)/g)) note(m[1], m.index);
  for (const m of src.matchAll(/Module\["(_[A-Za-z0-9_]+)"\]/g)) note(m[1], m.index);
  return names;
};

const FRONTEND = ["index.js", "embed.js", "netplay.js", "glpresent.js", "sw.js"];

test("every Module._* the front-end calls is in EXPORTED_FUNCTIONS", () => {
  const exp = exported();
  const missing = [];
  for (const file of FRONTEND) {
    if (!existsSync(fileURLToPath(new URL("../" + file, import.meta.url)))) continue;
    for (const [name, line] of used(file)) {
      if (!exp.has(name)) missing.push(`${file}:${line} ${name}`);
    }
  }
  assert.deepEqual(missing, [],
    "these are called but never exported, so they are undefined at runtime:\n  " +
    missing.join("\n  "));
});

// Named outright: catches an export dropped from the list while the calls stay.
const CLIP_API = [
  "_clip_history_frames", "_clip_scrub_generate", "_clip_scrub_count",
  "_clip_scrub_thumb_w", "_clip_scrub_thumb_h", "_clip_scrub_thumbs_ptr",
  "_clip_scrub_frames_ago", "_clip_begin", "_clip_tick", "_clip_abort",
  "_setClipCapBytes",
];

test("the clip API is exported in full", () => {
  const exp = exported();
  assert.deepEqual(CLIP_API.filter((n) => !exp.has(n)), []);
});

// Against the built em.js when present (gitignored; no-op on a fresh
// checkout), the only place the minified-names failure is visible.
test("the built em.js wires the clip API onto Module", (t) => {
  const emPath = fileURLToPath(new URL("../em.js", import.meta.url));
  if (!existsSync(emPath)) {
    t.skip("web/em.js not built here (run `nimble wasm`)");
    return;
  }
  const em = readFileSync(emPath, "utf8");
  const missing = CLIP_API.filter((n) => !em.includes(`Module["${n}"]`));
  assert.deepEqual(missing, [],
    "built but not reachable from JS — rebuild after editing EXPORTED_FUNCTIONS");
});
