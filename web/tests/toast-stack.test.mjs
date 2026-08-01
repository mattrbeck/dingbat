// The toast stack. #toast used to be a single element that every new message
// overwrote, and that one slot cost real features: the Game Boy Camera's
// "use your real camera?" offer — the only route to enabling the webcam —
// was destroyed by the auto-resume "Last session saved" toast 98 ms later,
// leaving the user with a corrupted-looking synthetic viewfinder and no way
// out. Reset's "Undo" offer collided with the same prompt. So the invariant
// under test is simply: no toast may silently destroy another.
//
// Strings here are the genuine longest/most-collided ones from web/index.js,
// not invented copy.
import test from "node:test";
import assert from "node:assert/strict";
import { eq, loadApp } from "./helpers.mjs";

const CAMERA = "Game Boy Camera cart — use your real camera?";
const RESUME = "Last session saved 2m ago";
const LONGEST = "This game's ROM is no longer stored — load the file again";

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// Fire an action toast whose callback records into a vm-side array.
const armed = (app, msg, label, ms) => app.runIn(
  `showActionToast(${JSON.stringify(msg)}, ${JSON.stringify(label)},` +
  ` () => globalThis.__taps.push(${JSON.stringify(label)})` +
  (ms === undefined ? "" : ", " + ms) + ")");

const setup = async () => {
  const app = await loadApp();
  app.runIn("globalThis.__taps = []");
  return app;
};

// The pill carrying an action, newest first, ignoring ones already retired.
const offerPill = (app) => app.toastEl.children.find((c) =>
  c.classList.contains("has-action") && !c.classList.contains("leaving"));

test("the harness still sees what the app shows", async () => {
  // Guard on the guard: every other toast assertion in the suite reads
  // `app.toasts`, so a silently-empty list would turn them all into no-ops.
  const app = await setup();
  app.runIn(`showToast(${JSON.stringify(LONGEST)})`);
  assert.deepEqual(app.toasts, [LONGEST]);
  assert.deepEqual(app.liveToasts(), [LONGEST]);
});

test("two toasts coexist", async () => {
  const app = await setup();
  app.runIn(`showToast(${JSON.stringify(LONGEST)})`);
  app.runIn('showToast("State loaded")');
  // Newest first: the stack is bottom-anchored and grows upward, so the
  // older pill keeps the position it already occupies.
  assert.deepEqual(app.liveToasts(), ["State loaded", LONGEST]);
});

test("an action toast survives a plain toast arriving after it", async () => {
  // The reported bug, exactly: the camera offer, then the auto-resume toast
  // 98 ms later. Both must be on screen, and the offer must still be armed.
  const app = await setup();
  armed(app, CAMERA, "Enable camera");
  await wait(100);
  app.runIn(`showToast(${JSON.stringify(RESUME)})`);

  const pill = offerPill(app);
  assert.ok(pill, "the camera offer is still a mounted, actionable pill");
  assert.equal(typeof pill.onclick, "function", "and is still armed");
  assert.equal(pill.children[0].textContent, CAMERA);
  assert.equal(pill.children[1].textContent, "Enable camera",
    "and still shows its button");
  assert.deepEqual(app.liveToasts(), [RESUME, CAMERA],
    "the later toast joins the stack instead of replacing the offer");
});

test("an action toast survives another action toast", async () => {
  // Reset's "Undo" and the camera offer fire in the same millisecond.
  const app = await setup();
  armed(app, CAMERA, "Enable camera");
  armed(app, "Game reset", "Undo");
  assert.deepEqual(app.liveToasts(), ["Game reset", CAMERA]);
});

test("tapping an action toast runs its callback, synchronously", async () => {
  const app = await setup();
  armed(app, CAMERA, "Enable camera");
  app.runIn(`showToast(${JSON.stringify(RESUME)})`);
  const pill = offerPill(app);

  pill.onclick();
  // Read the flag with nothing awaited in between. Several callers use this
  // tap to satisfy iOS's user-gesture requirement for
  // DeviceOrientationEvent.requestPermission() / getUserMedia(), so anything
  // asynchronous between the click and fn() would break the activation chain.
  eq(app.runIn("__taps.slice()"), ["Enable camera"],
    "the callback ran in the click's own task");

  assert.equal(offerPill(app), undefined, "and the offer retires on tap");
  assert.deepEqual(app.liveToasts(), [RESUME], "the other toast is untouched");
});

test("the × dismisses only its own toast", async () => {
  const app = await setup();
  app.runIn('showToast("State loaded")');
  armed(app, CAMERA, "Enable camera");
  const close = offerPill(app).children[2];
  assert.equal(close.getAttribute("aria-label"), "Dismiss");

  await close.dispatch("click");
  assert.deepEqual(app.liveToasts(), ["State loaded"]);
  eq(app.runIn("__taps.slice()"), [],
    "dismissing is not accepting — the action never ran");
});

test("the cap retires oldest-first", async () => {
  const app = await setup();
  assert.equal(app.runIn("TOAST_MAX"), 3);
  for (const m of ["one", "two", "three", "four"]) {
    app.runIn(`showToast(${JSON.stringify(m)})`);
  }
  assert.deepEqual(app.liveToasts(), ["four", "three", "two"],
    "the fourth pushes out the first, not the newest");
  assert.deepEqual(app.toasts, ["one", "two", "three", "four"],
    "all four were shown; only the oldest was retired");
});

test("duplicates do not pile up", async () => {
  const app = await setup();
  app.runIn('showToast("Tilt recentered")');
  app.runIn('showToast("Tilt recentered")');
  app.runIn('showToast("Tilt recentered")');
  assert.deepEqual(app.liveToasts(), ["Tilt recentered"],
    "a repeated message refreshes in place rather than stacking");
});

test("a repeated offer keeps the freshest callback", async () => {
  const app = await setup();
  app.runIn('globalThis.__taps = []');
  app.runIn('showActionToast("Game reset", "Undo", () => __taps.push("stale"))');
  app.runIn('showActionToast("Game reset", "Undo", () => __taps.push("fresh"))');
  assert.deepEqual(app.liveToasts(), ["Game reset"], "one pill, not two");
  offerPill(app).onclick();
  eq(app.runIn("__taps.slice()"), ["fresh"],
    "the tap runs the newer closure, which closes over the newer game state");
});

test("auto-dismiss timers are per toast", async () => {
  // One shared timer meant a 2.2 s status message could cut an 8 s offer
  // short (or the offer could hold the status message on screen).
  const app = await setup();
  armed(app, "Photo printed", "View", 5000);
  armed(app, CAMERA, "Enable camera", 30);
  assert.deepEqual(app.liveToasts(), [CAMERA, "Photo printed"]);

  await wait(120);
  assert.deepEqual(app.liveToasts(), ["Photo printed"],
    "the short one expired on its own schedule; the long one is untouched");
});

test("a retired toast is unmounted, not just hidden", async () => {
  const app = await setup();
  armed(app, "Photo printed", "View", 20);
  await wait(400); // > the toast's life + TOAST_FADE_MS
  assert.deepEqual(app.toastEl.children, [], "the stack is empty again");
  eq(app.runIn("toastItems.length"), 0);
});
