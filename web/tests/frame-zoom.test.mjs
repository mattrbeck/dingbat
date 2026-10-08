// Pinch zoom on the picture, and the mouse pointer hiding when it rests on it.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

// An 800x600 stage at the origin with a 600x400 picture centred in it: the
// picture's home centre is (400, 300), with 100 px of letterbox each side.
const withGame = async () => {
  const app = await loadApp();
  app.runIn(`currentRomName = "game.gba";`);
  app.document.body.classList.add("running");
  const stage = app.document.getElementById("stage").setBox(0, 0, 800, 600);
  Object.assign(stage, { clientLeft: 0, clientTop: 0 });
  const canvas = app.document.getElementById("canvas");
  Object.assign(canvas, { offsetLeft: 100, offsetTop: 100, offsetWidth: 600, offsetHeight: 400 });
  return { app, stage, canvas };
};

const zoom = (app) => JSON.parse(app.runIn("JSON.stringify([zoomS, zoomX, zoomY])"));
const touch = (canvas, id, x, y) =>
  ({ pointerType: "touch", pointerId: id, clientX: x, clientY: y, target: canvas });

// Where client point (px, py) is in the unzoomed picture.
const picturePoint = (app, px, py) => {
  const [s, x, y] = zoom(app);
  return [400 + (px - 400 - x) / s, 300 + (py - 300 - y) / s];
};

const near = (a, b, msg) =>
  assert.ok(Math.abs(a - b) < 1e-6, `${msg}: ${a} != ${b}`);

test("spreading two fingers zooms about them", async () => {
  const { app, canvas } = await withGame();
  await app.dispatchDoc("pointerdown", touch(canvas, 1, 300, 250));
  await app.dispatchDoc("pointerdown", touch(canvas, 2, 400, 250));
  const [ax, ay] = picturePoint(app, 350, 250);
  await app.dispatchDoc("pointermove", touch(canvas, 1, 250, 250));
  await app.dispatchDoc("pointermove", touch(canvas, 2, 450, 250));
  const [s] = zoom(app);
  near(s, 2, "a doubled finger spread doubles the picture");
  const [bx, by] = picturePoint(app, 350, 250);
  near(bx, ax, "the picture under the fingers stays under them (x)");
  near(by, ay, "the picture under the fingers stays under them (y)");
  assert.equal(canvas.style.scale, "2");
  assert.ok(app.document.body.classList.contains("frame-zoomed"));
});

test("a zoomed picture pans with one finger but never uncovers the stage", async () => {
  const { app, canvas } = await withGame();
  app.runIn("setFrameZoom(2, 0, 0)");
  await app.dispatchDoc("pointerdown", touch(canvas, 1, 400, 300));
  await app.dispatchDoc("pointermove", touch(canvas, 1, 450, 280));
  assert.deepEqual(zoom(app), [2, 50, -20]);
  await app.dispatchDoc("pointermove", touch(canvas, 1, 2000, 2000));
  // 1200x800 over an 800x600 stage: at most 200 px either way, 100 up/down.
  assert.deepEqual(zoom(app), [2, 200, 100]);
});

test("pinching back past 1x puts the picture home", async () => {
  const { app, canvas } = await withGame();
  app.runIn("setFrameZoom(2, 150, 50)");
  await app.dispatchDoc("pointerdown", touch(canvas, 1, 300, 300));
  await app.dispatchDoc("pointerdown", touch(canvas, 2, 500, 300));
  await app.dispatchDoc("pointermove", touch(canvas, 2, 320, 300));
  assert.deepEqual(zoom(app), [1, 0, 0]);
  assert.equal(canvas.style.scale, "");
  assert.equal(canvas.style.translate, "");
});

test("a double tap on a zoomed picture resets it; one tap does not", async () => {
  const { app, canvas } = await withGame();
  app.runIn("setFrameZoom(3, 0, 0)");
  const tap = async () => {
    await app.dispatchDoc("pointerdown", touch(canvas, 7, 400, 300));
    await app.dispatchDoc("pointerup", touch(canvas, 7, 400, 300));
  };
  await tap();
  assert.equal(zoom(app)[0], 3);
  await tap();
  assert.deepEqual(zoom(app), [1, 0, 0]);
});

test("touches on the controls, mouse presses and paused games never zoom", async () => {
  const { app, canvas } = await withGame();
  const pad = app.document.getElementById("dpad");
  await app.dispatchDoc("pointerdown", { ...touch(canvas, 1, 300, 250), target: pad });
  await app.dispatchDoc("pointerdown", { ...touch(canvas, 2, 400, 250), target: pad });
  await app.dispatchDoc("pointermove", { ...touch(canvas, 2, 600, 250), target: pad });
  assert.equal(zoom(app)[0], 1);
  app.document.body.classList.remove("running");
  await app.dispatchDoc("pointerdown", touch(canvas, 3, 300, 250));
  await app.dispatchDoc("pointerdown", touch(canvas, 4, 400, 250));
  await app.dispatchDoc("pointermove", touch(canvas, 4, 600, 250));
  assert.equal(zoom(app)[0], 1);
});

test("a trackpad pinch (ctrl+wheel) zooms about the pointer and keeps the page still", async () => {
  const { app, stage, canvas } = await withGame();
  let prevented = false;
  // Small enough that the clamp has nothing to do: 1.22x of 600x400 still
  // fits the stage.
  const [ax, ay] = picturePoint(app, 450, 320);
  await stage.dispatch("wheel", {
    ctrlKey: true, deltaY: -20, deltaX: 0, deltaMode: 0, clientX: 450, clientY: 320,
    target: canvas, preventDefault: () => { prevented = true; },
  });
  assert.ok(prevented, "the browser's page zoom must be cancelled");
  near(zoom(app)[0], Math.exp(0.2), "zoom factor");
  const [bx, by] = picturePoint(app, 450, 320);
  near(bx, ax, "anchor x");
  near(by, ay, "anchor y");
});

test("the zoom is dropped when another game is on screen", async () => {
  const { app } = await withGame();
  app.runIn(`zoomRom = currentRomName; setFrameZoom(2, 10, 10)`);
  app.runIn(`currentRomName = "other.gba"; refitFrameZoom()`);
  assert.deepEqual(zoom(app), [1, 0, 0]);
});

test("a resting mouse hides only over the picture itself", async () => {
  const { app, canvas } = await withGame();
  const timers = [];
  app.sandbox.setTimeout = (fn, ms) => { timers.push({ fn, ms }); return timers.length; };
  const body = app.document.body;
  let under = canvas;
  app.document.elementFromPoint = () => under;

  await app.dispatchDoc("pointermove", { pointerType: "mouse", clientX: 400, clientY: 300 });
  assert.equal(timers.at(-1).ms, 3000);
  timers.at(-1).fn();
  assert.ok(body.classList.contains("cursor-idle"), "resting on the picture hides it");

  await app.dispatchDoc("pointermove", { pointerType: "mouse", clientX: 50, clientY: 300 });
  assert.ok(!body.classList.contains("cursor-idle"), "any move brings it back");
  under = app.document.getElementById("stage");   // the letterbox
  timers.at(-1).fn();
  assert.ok(!body.classList.contains("cursor-idle"), "the letterbox keeps the pointer");

  const before = timers.length;
  await app.dispatchDoc("pointermove", { pointerType: "touch", clientX: 400, clientY: 300 });
  assert.equal(timers.length, before, "touch has no pointer to hide");
});
