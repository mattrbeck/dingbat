// Linked (online rollback) pause must freeze BOTH sides, exactly like 2x
// drives both cores: a one-sided pause just stalls the peer at the rollback
// prediction limit with nothing on their screen explaining why. These tests
// drive the real togglePause paths (local button, peer relay) in the vm
// harness, mirroring pitch-correct-2x.test.mjs.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

test("a local pause relays to the peer while linked", async () => {
  const app = await loadApp();
  app.runIn(`
    var __relayed = [];
    window.rbSendPause = (on) => __relayed.push(on);
    rollbackMode = true;
    // The click path has a 350ms lockout vs the pointerup handler; a fresh vm's
    // performance.now() is still inside it, so back-date the pointer stamp.
    pausePointerTs = -10000;
  `);
  await app.document.getElementById("pause").dispatch("click");
  assert.equal(app.runIn("paused"), true);
  assert.deepEqual(JSON.parse(app.runIn("JSON.stringify(__relayed)")), [true],
    "the pause must reach the other screen");
  await app.document.getElementById("pause").dispatch("click");
  assert.deepEqual(JSON.parse(app.runIn("JSON.stringify(__relayed)")), [true, false],
    "and so must the resume");
});

test("a peer's pause applies here without echoing back", async () => {
  const app = await loadApp();
  app.runIn(`
    var __relayed = [];
    window.rbSendPause = (on) => __relayed.push(on);
    rollbackMode = true;
  `);
  app.runIn("window.applyRemotePause(true)");
  assert.equal(app.runIn("paused"), true, "peer's pause froze this side");
  app.runIn("window.applyRemotePause(true)"); // duplicate delivery is a no-op
  assert.equal(app.runIn("paused"), true);
  app.runIn("window.applyRemotePause(false)");
  assert.equal(app.runIn("paused"), false, "peer's resume unfroze this side");
  assert.deepEqual(JSON.parse(app.runIn("JSON.stringify(__relayed)")), [],
    "remote-applied changes never echo back (relay loop)");
});

test("solo pause never touches the relay", async () => {
  const app = await loadApp();
  app.runIn(`
    var __relayed = [];
    window.rbSendPause = (on) => __relayed.push(on);
    rollbackMode = false;
    pausePointerTs = -10000;
  `);
  await app.document.getElementById("pause").dispatch("click");
  assert.equal(app.runIn("paused"), true);
  assert.deepEqual(JSON.parse(app.runIn("JSON.stringify(__relayed)")), []);
});
