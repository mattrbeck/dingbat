// Save-state import toast copy: a file that isn't a dingbat save state at all
// must NOT be reported as "didn't match this game" — that copy is reserved for
// real state images the core rejected (wrong ROM/core, newer version, corrupt
// payload). The distinction is a JS-side sniff of the "DGBSTATE" header magic
// (src/dingbat/common/serialize.nim) because wasm_load_state only returns a
// boolean.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const MAGIC = [..."DGBSTATE"].map((c) => c.charCodeAt(0));

// A fake Emscripten Module whose _wasm_load_state returns `result`.
const fakeModule = (result) => ({
  _malloc: () => 8,
  _free() {},
  _wasm_load_state: () => result,
  memory: { buffer: new ArrayBuffer(4096) },
});

test("importing a garbage file says it's not a save state file", async () => {
  const app = await loadApp();
  app.sandbox.Module = fakeModule(0); // never reached: magic sniff fails first
  app.api.applyImportedState(new Uint8Array([0x50, 0x4b, 0x03, 0x04, 9, 9]));
  assert.equal(app.toasts.at(-1), "Not a dingbat save state file");
});

test("an empty/truncated file also gets the not-a-state copy", async () => {
  const app = await loadApp();
  app.api.applyImportedState(new Uint8Array(0));
  assert.equal(app.toasts.at(-1), "Not a dingbat save state file");
});

test("a real state image the core rejects keeps the wrong-game copy", async () => {
  const app = await loadApp();
  app.sandbox.Module = fakeModule(0);
  const bytes = new Uint8Array(64);
  bytes.set(MAGIC, 0);
  app.api.applyImportedState(bytes);
  assert.equal(app.toasts.at(-1), "State didn't match this game");
});

test("an accepted state image toasts State loaded", async () => {
  const app = await loadApp();
  app.sandbox.Module = fakeModule(1);
  const bytes = new Uint8Array(64);
  bytes.set(MAGIC, 0);
  app.api.applyImportedState(bytes);
  assert.equal(app.toasts.at(-1), "State loaded");
});
