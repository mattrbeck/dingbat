// Tilt in screen space, not device space: beta/gamma are defined against the
// natural orientation, so in landscape the hold angle reads as a full lean.
// Rotating also drops the neutral pose. One handler serves GB MBC7 and GBA tilt.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

// The state enableOrientationTilt() leaves behind, minus the iOS permission dance.
const armTilt = (app) =>
  app.runIn(`
    tiltActive = true; tiltKind = 1; tiltOrientationOn = true;
    tiltNeutral = null; tiltTargetX = 0; tiltTargetY = 0;
  `);

const lean = (app, beta, gamma) =>
  app.runIn(`
    orientationTiltHandler({ alpha: 0, beta: ${beta}, gamma: ${gamma} });
    [Math.round(tiltTargetX * 1000) / 1000, Math.round(tiltTargetY * 1000) / 1000];
  `);

const HOLD = 40; // a normal 40-degree hold angle
const LEAN = 22; // then lean ~22 degrees, which is most of full deflection

test("portrait: leaning right drives X and leaves Y centred", async () => {
  const app = await loadApp();
  armTilt(app);
  lean(app, HOLD, 0); // first reading baselines the hold pose
  const [x, y] = lean(app, HOLD, LEAN);
  assert.ok(x > 0.8, `expected a strong right lean, got ${x}`);
  assert.ok(Math.abs(y) < 0.02, `expected Y centred, got ${y}`);
});

test("landscape reports the same tilt as portrait for the same lean", async () => {
  const app = await loadApp();
  armTilt(app);
  lean(app, HOLD, 0);
  const [portraitX] = lean(app, HOLD, LEAN);

  app.state.screenAngle = 90;
  app.runIn("tiltNeutral = null;");
  lean(app, 0, -HOLD);
  const [lx, ly] = lean(app, LEAN, -HOLD);
  assert.ok(Math.abs(lx - portraitX) < 0.03,
    `landscape 90 X ${lx} should match portrait ${portraitX}`);
  assert.ok(Math.abs(ly) < 0.03, `landscape 90 Y should stay centred, got ${ly}`);

  app.state.screenAngle = 270;
  app.runIn("tiltNeutral = null;");
  lean(app, 0, HOLD);
  const [rx, ry] = lean(app, -LEAN, HOLD);
  assert.ok(Math.abs(rx - portraitX) < 0.03,
    `landscape 270 X ${rx} should match portrait ${portraitX}`);
  assert.ok(Math.abs(ry) < 0.03, `landscape 270 Y should stay centred, got ${ry}`);
});

test("a rotated hold angle does not leak in as a constant lean", async () => {
  const app = await loadApp();
  armTilt(app);
  app.state.screenAngle = 90;
  lean(app, 0, -HOLD);            // baseline in landscape
  const [x, y] = lean(app, 0, -HOLD); // still holding still
  assert.ok(Math.abs(x) < 0.05 && Math.abs(y) < 0.05,
    `holding steady must read as neutral, got ${x},${y}`);
});

// Turning the phone is a large linear acceleration, indistinguishable from
// the flick that makes Kirby jump.
test("rotating is not mistaken for a flick", async () => {
  const app = await loadApp();
  armTilt(app);

  // Control.
  app.runIn("tiltJoltX = 0; motionJoltHandler({ acceleration: { x: 20, y: 0 } });");
  assert.ok(Math.abs(app.runIn("tiltJoltX")) > 0.5,
    "a real flick must still register, or the jump is dead");

  await app.dispatchWin("orientationchange");
  app.runIn("tiltJoltX = 0; motionJoltHandler({ acceleration: { x: 20, y: 0 } });");
  assert.equal(app.runIn("tiltJoltX"), 0,
    "turning the phone must not read as a flick");

  // Orientation readings are held level during the turn.
  app.runIn("orientationTiltHandler({ alpha: 0, beta: 70, gamma: 60 });");
  assert.equal(app.runIn("tiltTargetX"), 0, "tilt is held level mid-rotation");
  assert.equal(app.runIn("tiltTargetY"), 0, "tilt is held level mid-rotation");
});

test("flicks work again once the rotation has settled", async () => {
  const app = await loadApp();
  armTilt(app);
  await app.dispatchWin("orientationchange");
  await new Promise((r) => setTimeout(r, 800)); // past the settle window
  app.runIn("tiltJoltX = 0; motionJoltHandler({ acceleration: { x: 20, y: 0 } });");
  assert.ok(Math.abs(app.runIn("tiltJoltX")) > 0.5,
    "suppression must be a window, not a latch");
});

// The cart derives acceleration from the sensor value, so a step in it is a
// flick. Recentring mid-roll would step the target from full deflection to zero.
const armModule = (app) => app.runIn(`
  globalThis.__sent = [];
  globalThis.Module = { _wasm_set_tilt: (x, y) => { globalThis.__sent.push([x, y]); } };
`);
const lastSent = (app) => app.runIn("__sent.length ? __sent[__sent.length - 1][0] : null");

test("recentring eases the value instead of stepping it", async () => {
  const app = await loadApp();
  armTilt(app);
  armModule(app);
  lean(app, HOLD, 0);        // baseline
  lean(app, HOLD, 25);       // then lean hard over
  app.runIn("updateTilt();");
  const before = lastSent(app);
  assert.ok(Math.abs(before) > 0.8, `expected a hard lean, got ${before}`);

  app.runIn("tiltRecenterBtn.click();");
  lean(app, HOLD, 25);       // same pose: the new neutral, so target -> 0
  app.runIn("updateTilt();");
  const after = lastSent(app);
  assert.ok(Math.abs(after - before) < Math.abs(before) * 0.5,
    `the value must ease, not step: ${before} -> ${after}`);

  app.runIn("for (let i = 0; i < 90; i++) updateTilt();");
  assert.ok(Math.abs(lastSent(app)) < 0.05,
    `should settle at the new neutral, got ${lastSent(app)}`);
});

test("a turn freezes the tilt rather than snapping it level", async () => {
  const app = await loadApp();
  armTilt(app);
  armModule(app);
  lean(app, HOLD, 0);
  lean(app, HOLD, 25);
  const held = app.runIn("tiltTargetX");
  await app.dispatchWin("orientationchange");
  app.runIn("orientationTiltHandler({ alpha: 0, beta: 5, gamma: -80 });");
  assert.equal(app.runIn("tiltTargetX"), held,
    "mid-rotation readings must be ignored, not zeroed");
});

// orientationchange fires too late (the turn's acceleration already reached
// the core), so the turn is recognised from the motion. Real time: the
// detector integrates rotation rate over elapsed time.
const spin = async (app, ms, degPerSec, accelX) => {
  for (let t = 0; t < ms; t += 20) {
    await new Promise((r) => setTimeout(r, 20));
    app.runIn(`motionJoltHandler({ rotationRate: { alpha: ${degPerSec}, beta: 0,` +
      ` gamma: 0 }, acceleration: { x: ${accelX}, y: 0 } });`);
  }
};

test("turning the device suppresses the jolt without orientationchange", async () => {
  const app = await loadApp();
  armTilt(app);
  app.runIn("tiltJoltX = 0;");
  // ~90 degrees over 0.4s with a flick-sized acceleration; no orientationchange.
  await spin(app, 400, 225, 20);
  assert.equal(app.runIn("tiltJoltX"), 0,
    "a 90-degree turn must not reach the jump channel");
});

// A hard flick twists the wrist and straight back; integrating rotation as
// an absolute value would count both halves and trip the turn detector.
test("a hard flick that twists and returns is not a turn", async () => {
  const app = await loadApp();
  armTilt(app);
  app.runIn("tiltJoltX = 0;");
  await spin(app, 140, 260, 20);    // twist hard one way...
  await spin(app, 140, -260, 20);   // ...and straight back
  assert.ok(Math.abs(app.runIn("tiltJoltX")) > 0.5,
    "an out-and-back twist must still reach the jump channel");
});

test("a flick is still a flick: rotation alone is what's rejected", async () => {
  const app = await loadApp();
  armTilt(app);
  app.runIn("tiltJoltX = 0;");
  await spin(app, 100, 20, 20);
  assert.ok(Math.abs(app.runIn("tiltJoltX")) > 0.5,
    "a translation-dominated flick must still register");
});

test("rotating the device re-baselines the neutral pose", async () => {
  const app = await loadApp();
  armTilt(app);
  lean(app, HOLD, 0);
  assert.notEqual(app.runIn("tiltNeutral"), null, "a neutral was captured");

  app.state.screenAngle = 90;
  await app.dispatchWin("orientationchange");
  // The reset is deferred so it does not sample mid-rotation.
  await new Promise((r) => setTimeout(r, 600));
  assert.equal(app.runIn("tiltNeutral"), null,
    "rotating must drop the stale neutral so the next reading re-baselines");
});
