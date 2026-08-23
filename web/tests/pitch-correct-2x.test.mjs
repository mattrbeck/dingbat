// rollback_init builds fresh cores that never saw the pitch-correct
// preference (solo cores get it at loadRom), so setSpeed2x must re-push it.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const spyAudioExports = (app) => {
  app.runIn(`
    var __audioCalls = [];
    Module._wasm_set_turbo = (v) => __audioCalls.push(["turbo", v]);
    Module._wasm_set_pitch_correct_ff = (v) => __audioCalls.push(["pcff", v]);
  `);
  return () => JSON.parse(app.runIn("JSON.stringify(__audioCalls)"));
};

test("a peer's 2x toggle re-pushes pitch-correct onto the cores", async () => {
  const app = await loadApp();
  const calls = spyAudioExports(app);
  // A live linked session with pitch-correct on and fresh rollback cores.
  app.runIn("pitchCorrectFF = true; rollbackMode = true;");
  app.runIn("window.applyRemoteSpeed2x(true)");
  assert.deepEqual(calls(), [["turbo", 1], ["pcff", 1]],
    "turbo alone would play pitched-up: the preference must ride along");
});

test("the local 2x button does the same, and relays to the peer", async () => {
  const app = await loadApp();
  const calls = spyAudioExports(app);
  app.runIn(`
    var __relayed = [];
    window.rbSendSpeed = (on) => __relayed.push(on);
    pitchCorrectFF = true; rollbackMode = true;
  `);
  await app.document.getElementById("speed-2x-btn").dispatch("click");
  assert.deepEqual(calls(), [["turbo", 1], ["pcff", 1]]);
  assert.deepEqual(JSON.parse(app.runIn("JSON.stringify(__relayed)")), [true],
    "one-sided 2x desyncs the pair — the toggle must relay");
});

test("leaving 2x keeps the preference pushed (off stays off-pitch-clean)", async () => {
  const app = await loadApp();
  app.runIn("pitchCorrectFF = false; rollbackMode = true;");
  const calls = spyAudioExports(app);
  app.runIn("window.applyRemoteSpeed2x(true); window.applyRemoteSpeed2x(false)");
  assert.deepEqual(calls(),
    [["turbo", 1], ["pcff", 0], ["turbo", 0], ["pcff", 0]]);
});
