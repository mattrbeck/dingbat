// The service-worker Update flow: clicking Update must always visibly land
// (reload into the new version) or visibly fail — never silently activate.
//
// Regression: the controllerchange reload used to be gated on a hadController
// CONSTANT captured at page load. A session that begins uncontrolled (first
// visit, shift-reload, the load right after a Re-download reset) becomes
// controlled by the first claim, but the latch stayed false — so a later
// Update click activated the new worker and then... nothing. The button
// stayed lit and only a second click (via the full-reset fallback) worked.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const settle = () => new Promise((r) => setTimeout(r, 0));

// Click Update with a waiting worker planted, and check the page told it to
// skipWaiting. Returns the waiting worker so the caller can activate it.
const clickUpdateWithWaiting = async (app) => {
  const waiting = app.sw.makeWorker("installed");
  app.sw.registration.waiting = waiting;
  await app.elements.get("update-btn").dispatch("click");
  await settle(); // applyUpdate runs detached from the click handler
  // Field compare, not deepEqual: the payload object is born inside the vm
  // realm, whose Object.prototype deepStrictEqual treats as foreign.
  assert.equal(waiting.messages.length, 1);
  assert.equal(waiting.messages[0].type, "skipWaiting");
  return waiting;
};

test("the very first claim still never reloads mid-boot", async () => {
  const app = await loadApp({ serviceWorker: true }); // uncontrolled boot
  await settle();
  app.sw.takeControl(); // fresh install's clients.claim()
  await settle();
  assert.equal(app.state.reloads, 0);
});

test("controlled session: Update click reloads on handover", async () => {
  const app = await loadApp({ serviceWorker: { controlled: true } });
  await settle();
  const waiting = await clickUpdateWithWaiting(app);
  app.sw.takeControl(waiting); // skipWaiting → activate → claim
  await settle();
  assert.equal(app.state.reloads, 1);
});

test("session that began uncontrolled: Update click after the first claim reloads", async () => {
  const app = await loadApp({ serviceWorker: true });
  await settle();
  app.sw.takeControl(); // first install claims the page; no reload
  await settle();
  assert.equal(app.state.reloads, 0);
  // A deploy lands later in the same session and the user clicks Update.
  const waiting = await clickUpdateWithWaiting(app);
  app.sw.takeControl(waiting);
  await settle();
  assert.equal(app.state.reloads, 1); // the old latch left this at 0
});

test("shift-reload shape: Update handover is this page's first claim, still reloads", async () => {
  // Uncontrolled page over a live registration: no claim ever fires until
  // the Update click's new worker activates.
  const app = await loadApp({ serviceWorker: true });
  await settle();
  const waiting = await clickUpdateWithWaiting(app);
  app.sw.takeControl(waiting);
  await settle();
  assert.equal(app.state.reloads, 1);
});

test("another tab's update reloads this tab too, even after an initial claim", async () => {
  const app = await loadApp({ serviceWorker: true });
  await settle();
  app.sw.takeControl(); // this tab's boot claim
  await settle();
  app.sw.takeControl(); // handover triggered from a second tab's Update click
  await settle();
  assert.equal(app.state.reloads, 1);
});

test("clicking Update shows the busy state while the install runs", async () => {
  const app = await loadApp({ serviceWorker: { controlled: true } });
  await settle();
  await clickUpdateWithWaiting(app);
  const btn = app.elements.get("update-btn");
  assert.equal(btn.disabled, true); // no double-click racing a second update
  assert.ok(btn.classList.contains("updating")); // CSS hides the pulsating dot
  assert.equal(app.elements.get("update-label").textContent, "Updating…");
});

test("failed install (redundant worker) falls back to the clean-slate reset", async () => {
  const app = await loadApp({ serviceWorker: { controlled: true } });
  await settle();
  // update() discovers a new worker still installing
  const installing = app.sw.makeWorker("installing");
  app.state.swUpdateImpl = async () => { app.sw.registration.installing = installing; };
  await app.elements.get("update-btn").dispatch("click");
  await settle();
  assert.equal(app.state.reloads, 0); // still waiting on the install
  installing.state = "redundant"; // an asset fetch failed; install died
  installing.dispatch("statechange");
  await settle();
  assert.equal(app.sw.registration.unregisterCalls, 1);
  assert.equal(app.state.reloads, 1); // fullResetReload, not silence
});
