// Muted or at volume 0 the core skips mixing (APU.silent): every way the
// player silences the game must reach wasm_set_audio_silent, and every way
// back must clear it.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const spySilent = (app) => {
  app.runIn(`
    var __silent = [];
    Module._wasm_set_audio_silent = (v) => __silent.push(v);
  `);
  return () => JSON.parse(app.runIn("JSON.stringify(__silent)"));
};

test("the mute button silences the core and unmuting brings it back", async () => {
  const app = await loadApp();
  const calls = spySilent(app);
  const mute = app.document.getElementById("mute-btn");
  await mute.dispatch("click");
  await mute.dispatch("click");
  assert.deepEqual(calls(), [1, 0]);
});

test("volume 0 silences the core; any volume above it does not", async () => {
  const app = await loadApp();
  const calls = spySilent(app);
  app.runIn("setVolume(0); setVolume(35)");
  assert.deepEqual(calls(), [1, 0]);
});
