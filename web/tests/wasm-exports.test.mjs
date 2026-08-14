// Tripwire: every wasm function the front-end calls must be in the linker's
// EXPORTED_FUNCTIONS list.
//
// This shipped twice in one feature. "Clip that!" was written against
// clip_scrub_* and clip_history_frames, none of which were added to
// EXPORTED_FUNCTIONS, and the picker's own `!Module._clip_scrub_generate`
// guard then swallowed it: the menu item opened nothing and said nothing.
// setClipCapBytes went the same way, so the iOS memory cap silently never
// applied. Neither showed up anywhere else, because this is exactly the
// failure mode that has no symptom other than the feature not happening.
//
// `-s EXPORT_ALL=1` is on and does NOT save it: at -O3 the wasm export names
// are minified, and em.js only wires `Module["_name"]` for the names in the
// list. So the list is the contract, and this asserts against it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");

// The names emscripten will actually expose on Module.
const exported = () => {
  const nims = read("../../src/dingbat_wasm.nims");
  const m = nims.match(/EXPORTED_FUNCTIONS=([^\s"]+)/);
  assert.ok(m, "EXPORTED_FUNCTIONS not found in src/dingbat_wasm.nims");
  return new Set(m[1].split(","));
};

// The names the front-end reaches for, in either spelling. Module.ccall /
// cwrap take bare names, but nothing in the app uses them for clip or rewind,
// so a plain identifier scan is the whole surface.
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

// The picker's whole API, named outright: the list above catches a NEW call
// that was never exported, and this catches an export being dropped from the
// list while the calls stay (a rename, a rebase, a hand-edited line).
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

// And the same list against the artifact that actually ships, when there is
// one. web/em.js is generated and gitignored, so this is a no-op on a fresh
// checkout and a real check on any machine (or CI job) that has built it —
// which is the only place the "-O3 minifies the names" failure can be seen.
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
