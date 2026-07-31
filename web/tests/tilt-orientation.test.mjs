// Device-motion tilt must be expressed in SCREEN space, not device space.
// beta/gamma are defined against the device's natural orientation, so in
// landscape the game's left/right axis would become the phone's pitch and
// the player's comfortable hold angle would read as a hard constant lean
// (measured: a full -1.0 deflection). Rotating the device must also drop the
// neutral pose, since the old baseline describes a grip nobody is holding.
// Shared by GB MBC7 (Kirby) and GBA tilt (Yoshi) — one handler serves both.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

// Put the app in the state enableOrientationTilt() leaves behind, without
// needing the iOS permission dance.
const armTilt = (app) =>
  app.runIn(`
    tiltActive = true; tiltKind = 1; tiltOrientationOn = true;
    tiltNeutral = null; tiltTargetX = 0; tiltTargetY = 0;
  `);

// Feed one reading through the real handler and read back the tilt target.
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

  // Rotated 90°, the same physical pose swaps onto the other device axis.
  app.state.screenAngle = 90;
  app.runIn("tiltNeutral = null;");
  lean(app, 0, -HOLD);
  const [lx, ly] = lean(app, LEAN, -HOLD);
  assert.ok(Math.abs(lx - portraitX) < 0.03,
    `landscape 90 X ${lx} should match portrait ${portraitX}`);
  assert.ok(Math.abs(ly) < 0.03, `landscape 90 Y should stay centred, got ${ly}`);

  // ...and the same the other way round.
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

// Turning the phone is a large linear acceleration. The jolt channel exists
// to turn a sharp flick into Kirby's jump, and it cannot tell the two apart —
// so rotating the device used to make him jump.
test("rotating is not mistaken for a flick", async () => {
  const app = await loadApp();
  armTilt(app);

  // Control: a genuine flick still registers.
  app.runIn("tiltJoltX = 0; motionJoltHandler({ acceleration: { x: 20, y: 0 } });");
  assert.ok(Math.abs(app.runIn("tiltJoltX")) > 0.5,
    "a real flick must still register, or the jump is dead");

  // The identical spike, while the device is being turned, must not.
  await app.dispatchWin("orientationchange");
  app.runIn("tiltJoltX = 0; motionJoltHandler({ acceleration: { x: 20, y: 0 } });");
  assert.equal(app.runIn("tiltJoltX"), 0,
    "turning the phone must not read as a flick");

  // Orientation readings are held level meanwhile, so the ball does not lurch.
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

// orientationchange fires only once the OS has decided the orientation
// changed — too late, the turn's acceleration already reached the core and
// Kirby already jumped. The turn has to be recognised from the motion while
// it is still happening. Real time is required here: the detector integrates
// rotation rate over elapsed time, so samples must actually be spaced out.
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
  // ~90 degrees over 0.4s, with a flick-sized acceleration riding along.
  // orientationchange is never fired — this must stand on its own.
  await spin(app, 400, 225, 20);
  assert.equal(app.runIn("tiltJoltX"), 0,
    "a 90-degree turn must not reach the jump channel");
});

test("a flick is still a flick: rotation alone is what's rejected", async () => {
  const app = await loadApp();
  armTilt(app);
  app.runIn("tiltJoltX = 0;");
  // Same acceleration, but the wrist barely rotates about the screen normal.
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
  // The reset is deliberately deferred so it does not sample mid-rotation.
  await new Promise((r) => setTimeout(r, 600));
  assert.equal(app.runIn("tiltNeutral"), null,
    "rotating must drop the stale neutral so the next reading re-baselines");
});
