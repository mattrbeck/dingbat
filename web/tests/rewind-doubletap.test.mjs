// Two gestures on the rewind button: hold rewinds immediately (nothing waits
// for a possible second press), double tap opens the scrubber after the fact.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

// RW_TAP_MAX_MS = 250 and RW_DBLTAP_MS = 300 in web/index.js.
const RW_HOLD_MS = 320;            // comfortably a hold, not a tap
const RW_WINDOW_OVERSHOOT = 360;   // comfortably outside the double-tap window

// An empty rewind ring is the cheapest state that still runs the real open path.
const withGame = async () => {
  const app = await loadApp();
  app.runIn(`
    currentRomName = "game.gba"; currentOriginalName = "game.gba";
    globalThis.Module = { _wasm_rewind_scrub_generate: () => 0 };
  `);
  return app;
};

const button = (app) => app.document.getElementById("rewind");
const modalOpen = (app) =>
  app.document.getElementById("rewind-modal").classList.contains("open");
const held = (app) => app.runIn("rewindHeld");

const POINT = { clientX: 40, clientY: 20, pointerType: "touch", pointerId: 1 };
const down = (app, ev = {}) => button(app).dispatch("pointerdown", { ...POINT, ...ev });
const up = (app, ev = {}) => button(app).dispatch("pointerup", { ...POINT, ...ev });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const tap = async (app, ev = {}) => {
  await down(app, ev);
  await up(app, ev);
};

test("a single tap rewinds and opens nothing", async () => {
  const app = await withGame();
  await down(app);
  assert.equal(held(app), true, "the press must rewind on pointerdown, not later");
  await up(app);
  assert.equal(held(app), false);
  await sleep(RW_WINDOW_OVERSHOOT);
  assert.equal(modalOpen(app), false, "a single tap must not open the scrubber");
});

test("a double tap opens the scrubber", async () => {
  const app = await withGame();
  await tap(app);
  assert.equal(modalOpen(app), false);
  await tap(app);
  assert.equal(modalOpen(app), true);
  assert.equal(held(app), false, "the gesture must not leave the rewind stuck on");
});

test("the hold is never delayed by the gesture", async () => {
  const app = await withGame();
  // The first pointerdown must have started rewinding by the time it returns.
  await down(app);
  assert.equal(held(app), true);
  await sleep(RW_HOLD_MS);
  assert.equal(held(app), true, "holding must keep rewinding, not time out");
  await up(app);
  assert.equal(modalOpen(app), false, "a hold is not half a double tap");
});

test("hold, release, tap does not open the scrubber", async () => {
  const app = await withGame();
  await down(app);
  await sleep(RW_HOLD_MS);       // a deliberate rewind
  await up(app);
  await tap(app);                // ...then a tap right after it
  assert.equal(modalOpen(app), false);
});

test("two taps too far apart are two taps", async () => {
  const app = await withGame();
  await tap(app);
  await sleep(RW_WINDOW_OVERSHOOT);
  await tap(app);
  assert.equal(modalOpen(app), false);
});

test("two taps in different places are not a double tap", async () => {
  const app = await withGame();
  await tap(app);
  await tap(app, { clientX: 40 + 80 });
  assert.equal(modalOpen(app), false);
});

test("a third tap starts a fresh pair", async () => {
  const app = await withGame();
  await tap(app);
  await tap(app);
  assert.equal(modalOpen(app), true);
  await app.document.getElementById("rewind-scrub-close").click();
  assert.equal(modalOpen(app), false);
  await tap(app);
  assert.equal(modalOpen(app), false, "the third tap must not re-open on its own");
});


test("a second finger does not cut a rewind the first is still holding", async () => {
  const app = await withGame();
  await down(app, { pointerId: 1 });
  assert.equal(held(app), true);
  await down(app, { pointerId: 2 });          // second finger lands on the button
  assert.equal(held(app), true);
  await up(app, { pointerId: 2 });            // ...and lifts again
  assert.equal(held(app), true, "the first finger is still down: keep rewinding");
  await up(app, { pointerId: 1 });
  assert.equal(held(app), false);
  assert.equal(modalOpen(app), false, "two fingers are not a double tap");
});

test("a press dragged off the button ends the rewind and arms nothing", async () => {
  const app = await withGame();
  await down(app);
  await button(app).dispatch("pointerleave", { ...POINT });
  assert.equal(held(app), false);
  await tap(app);
  assert.equal(modalOpen(app), false);
});

test("a right-click neither rewinds nor counts as a tap", async () => {
  const app = await withGame();
  await down(app, { pointerType: "mouse", button: 2 });
  assert.equal(held(app), false);
  await up(app, { pointerType: "mouse", button: 2 });
  assert.equal(modalOpen(app), false);
});
