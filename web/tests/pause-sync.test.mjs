// Linked pause must freeze both sides (a one-sided pause stalls the peer at
// the prediction limit). Drives the real togglePause paths.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

test("a local pause relays to the peer while linked", async () => {
  const app = await loadApp();
  app.runIn(`
    var __relayed = [];
    window.rbSendPause = (on) => __relayed.push(on);
    rollbackMode = true;
    // The click path has a 350ms lockout vs pointerup; back-date the stamp.
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
