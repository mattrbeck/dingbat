// Holding the fast-forward key is an overlay: release restores the latched
// speed. Holding the key for the speed already in force lands on 1x.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const withGame = async () => {
  const app = await loadApp();
  app.runIn(`currentRomName = "game.gba"; currentOriginalName = "game.gba";`);
  return app;
};

// Read the three speed flags raw, not through the app's own helper.
const speed = (app) =>
  app.runIn(`fastForward ? "ffw" : speed2x ? "2x" : slowMotion ? "slow" : "normal"`);

const key = (app, type, extra = {}) =>
  app.dispatchDoc(type, { code: "Tab", shiftKey: false, repeat: false, target: null, ...extra });

const holdTab = (app) => key(app, "keydown");
const releaseTab = (app) => key(app, "keyup");

const click = (app, id) => app.document.getElementById(id).click();

test("hold+release Tab returns to a latched 2x", async () => {
  const app = await withGame();
  await click(app, "speed-2x-btn");
  assert.equal(speed(app), "2x");

  await holdTab(app);
  assert.equal(speed(app), "ffw", "the hold must actually fast-forward");
  await releaseTab(app);
  assert.equal(speed(app), "2x");
});

test("hold+release Tab returns to latched slow motion", async () => {
  const app = await withGame();
  await click(app, "slow-motion");
  assert.equal(speed(app), "slow");

  await holdTab(app);
  assert.equal(speed(app), "ffw");
  await releaseTab(app);
  assert.equal(speed(app), "slow");
});

test("hold+release Tab from 1x returns to 1x", async () => {
  const app = await withGame();
  assert.equal(speed(app), "normal");

  await holdTab(app);
  assert.equal(speed(app), "ffw");
  await releaseTab(app);
  assert.equal(speed(app), "normal");
});

test("hold+release Tab while already fast-forwarding turns it off", async () => {
  const app = await withGame();
  await click(app, "fast-forward");
  assert.equal(speed(app), "ffw");

  await holdTab(app);
  assert.equal(speed(app), "ffw");
  await releaseTab(app);
  assert.equal(speed(app), "normal", "holding your current speed then letting go = off");
});

test("key repeat during the hold does not re-snapshot the speed", async () => {
  const app = await withGame();
  await click(app, "speed-2x-btn");

  await holdTab(app);
  await holdTab(app);                    // some browsers repeat without the flag
  await key(app, "keydown", { repeat: true });
  await releaseTab(app);
  assert.equal(speed(app), "2x");
});

test("the speed buttons stay toggles", async () => {
  const app = await withGame();
  await click(app, "fast-forward");
  assert.equal(speed(app), "ffw");
  await click(app, "fast-forward");
  assert.equal(speed(app), "normal");

  await click(app, "speed-2x-btn");
  assert.equal(speed(app), "2x");
  await click(app, "speed-2x-btn");
  assert.equal(speed(app), "normal");

  await click(app, "speed-2x-btn");
  await click(app, "fast-forward");
  assert.equal(speed(app), "ffw");
});

test("losing the keyup (window blur) still restores the latched speed", async () => {
  const app = await withGame();
  await click(app, "speed-2x-btn");
  await holdTab(app);
  await app.dispatchWin("blur", {});
  assert.equal(speed(app), "2x");
});

test("a speed latched during the hold wins over the snapshot", async () => {
  const app = await withGame();
  await holdTab(app);                    // 1x -> held fast-forward
  await click(app, "speed-2x-btn");      // deliberate change mid-hold
  assert.equal(speed(app), "2x");
  await releaseTab(app);
  assert.equal(speed(app), "2x", "the newer choice must survive the release");
});

test("Shift+Tab still toggles 2x without arming the hold", async () => {
  const app = await withGame();
  await key(app, "keydown", { shiftKey: true });
  assert.equal(speed(app), "2x");
  await key(app, "keyup", { shiftKey: true });
  assert.equal(speed(app), "2x");
  await key(app, "keydown", { shiftKey: true });
  assert.equal(speed(app), "normal");
});
