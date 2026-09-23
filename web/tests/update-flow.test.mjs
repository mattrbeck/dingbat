// The SW Update flow: Update must visibly land (reload) or visibly fail.
// Pins: a session that begins uncontrolled becomes controlled by the first
// claim, and a later Update click must still reload.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const settle = () => new Promise((r) => setTimeout(r, 0));

// Returns the waiting worker so the caller can activate it.
const clickUpdateWithWaiting = async (app) => {
  const waiting = app.sw.makeWorker("installed");
  app.sw.registration.waiting = waiting;
  await app.elements.get("update-btn").dispatch("click");
  await settle(); // applyUpdate runs detached from the click handler
  // Field compare: the payload is born in the vm realm.
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
  const waiting = await clickUpdateWithWaiting(app);
  app.sw.takeControl(waiting);
  await settle();
  assert.equal(app.state.reloads, 1); // the old latch left this at 0
});

test("shift-reload shape: Update handover is this page's first claim, still reloads", async () => {
  // Uncontrolled page: no claim fires until the Update click's worker activates.
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

// ServiceWorker.lean's bug_update_in_one_tab_reloads_the_other_midgame: the
// Update click in one tab activates the new worker, which claims every tab.
test("another tab's update does not reload this tab mid-game; it offers the reload", async () => {
  const app = await loadApp({ serviceWorker: { controlled: true } });
  await settle();
  app.api.currentRomName = "rom.gba";
  app.sw.takeControl(); // the handover another tab's Update click triggered
  await settle();
  assert.equal(app.state.reloads, 0, "the game in this tab must not be reloaded under the player");
  const btn = app.elements.get("update-btn");
  assert.equal(btn.hidden, false, "the button says an update is waiting for this tab");
  assert.equal(app.elements.get("update-label").textContent, "Reload");
  // The player's own click, through the usual confirm, is what reloads.
  await btn.dispatch("click");
  assert.ok(app.elements.get("update-modal").classList.contains("open"));
  await app.elements.get("update-confirm").dispatch("click");
  await settle();
  assert.equal(app.state.reloads, 1);
  assert.equal(app.sw.registration.unregisterCalls, 0, "the new worker is already in charge: no reset");
});

test("a rollback session counts as a game in progress", async () => {
  const app = await loadApp({ serviceWorker: { controlled: true } });
  await settle();
  app.api.rollbackMode = true;
  app.sw.takeControl();
  await settle();
  assert.equal(app.state.reloads, 0);
});

test("this tab's own Update still reloads it with a game loaded", async () => {
  const app = await loadApp({ serviceWorker: { controlled: true } });
  await settle();
  app.api.currentRomName = "rom.gba";
  const waiting = app.sw.makeWorker("installed");
  app.sw.registration.waiting = waiting;
  await app.elements.get("update-btn").dispatch("click"); // opens the confirm
  await app.elements.get("update-confirm").dispatch("click");
  await settle();
  app.sw.takeControl(waiting);
  await settle();
  assert.equal(app.state.reloads, 1);
});
