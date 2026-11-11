// The SW Update flow: Update must visibly land (reload) or visibly fail.
// Pins: a session that begins uncontrolled becomes controlled by the first
// claim, and a later Update click must still reload.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadApp, fakeFile } from "./helpers.mjs";

const settle = () => new Promise((r) => setTimeout(r, 0));

// The page as it is once the core is in: index.js registers the worker
// then (registerServiceWorker), never at load.
const bootApp = async (opts) => {
  const app = await loadApp(opts);
  app.runIn("registerServiceWorker()");
  return app;
};

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
  const app = await bootApp({ serviceWorker: true }); // uncontrolled boot
  await settle();
  app.sw.takeControl(); // fresh install's clients.claim()
  await settle();
  assert.equal(app.state.reloads, 0);
});

test("controlled session: Update click reloads on handover", async () => {
  const app = await bootApp({ serviceWorker: { controlled: true } });
  await settle();
  const waiting = await clickUpdateWithWaiting(app);
  app.sw.takeControl(waiting); // skipWaiting → activate → claim
  await settle();
  assert.equal(app.state.reloads, 1);
});

test("session that began uncontrolled: Update click after the first claim reloads", async () => {
  const app = await bootApp({ serviceWorker: true });
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
  const app = await bootApp({ serviceWorker: true });
  await settle();
  const waiting = await clickUpdateWithWaiting(app);
  app.sw.takeControl(waiting);
  await settle();
  assert.equal(app.state.reloads, 1);
});

test("another tab's update reloads this tab too, even after an initial claim", async () => {
  const app = await bootApp({ serviceWorker: true });
  await settle();
  app.sw.takeControl(); // this tab's boot claim
  await settle();
  app.sw.takeControl(); // handover triggered from a second tab's Update click
  await settle();
  assert.equal(app.state.reloads, 1);
});

test("clicking Update shows the busy state while the install runs", async () => {
  const app = await bootApp({ serviceWorker: { controlled: true } });
  await settle();
  await clickUpdateWithWaiting(app);
  const btn = app.elements.get("update-btn");
  assert.equal(btn.disabled, true); // no double-click racing a second update
  assert.ok(btn.classList.contains("updating")); // CSS hides the pulsating dot
  assert.equal(app.elements.get("update-label").textContent, "Updating…");
});

test("failed install (redundant worker) falls back to the clean-slate reset", async () => {
  const app = await bootApp({ serviceWorker: { controlled: true } });
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
  const app = await bootApp({ serviceWorker: { controlled: true } });
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
  const app = await bootApp({ serviceWorker: { controlled: true } });
  await settle();
  app.api.rollbackMode = true;
  app.sw.takeControl();
  await settle();
  assert.equal(app.state.reloads, 0);
});

test("this tab's own Update still reloads it with a game loaded", async () => {
  const app = await bootApp({ serviceWorker: { controlled: true } });
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

test("the worker registers once the core is in, not while the page loads", async () => {
  // A first visit's install downloads every asset again; registered at load
  // it shared the link with the page's own first load.
  const app = await loadApp({ serviceWorker: true });
  await settle();
  assert.equal(app.sw.container.registerCalls, 0);
  app.runIn("storageReadyResolve()");
  await app.runIn("Module.onRuntimeInitialized()");
  await settle();
  assert.equal(app.sw.container.registerCalls, 1);
  app.runIn("registerServiceWorker()"); // a second call is a no-op
  assert.equal(app.sw.container.registerCalls, 1);
});

test("a page already controlled registers at load, ahead of the core", async () => {
  // A returning visit's registration costs no download, and Update leans on
  // swRegistration from the start (without it applyUpdate takes the reset).
  const app = await loadApp({ serviceWorker: { controlled: true } });
  await settle();
  assert.equal(app.sw.container.registerCalls, 1);
});

// --- The updating card (index.js "Updating") ---------------------------------
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

test("Update holds every tap at once, and shows its card only past half a second", async () => {
  const app = await bootApp({ serviceWorker: { controlled: true } });
  await settle();
  await clickUpdateWithWaiting(app); // the new worker told to take over; no handover yet
  const el = app.elements.get("updating");
  assert.equal(el.hidden, false, "the shield is up from the tap");
  assert.ok(!el.classList.contains("shown"), "and nothing shows yet");
  await wait(600);
  assert.ok(el.classList.contains("shown"), "past half a second, the card");
});

test("a quick Update reloads before its card, which never shows", async () => {
  const app = await bootApp({ serviceWorker: { controlled: true } });
  await settle();
  const waiting = await clickUpdateWithWaiting(app);
  app.sw.takeControl(waiting);
  await settle();
  assert.equal(app.state.reloads, 1);
  await wait(600);
  assert.ok(!app.elements.get("updating").classList.contains("shown"),
            "the reload took the card's timer with it");
});

test("a game can't be started behind an update: its reload would take it", async () => {
  // The control: the same file, no update under way, is taken in.
  // A real Game Boy ROM (the repo's own test ROM), so the not-a-ROM prompt
  // never comes up.
  const rom = new Uint8Array(readFileSync(new URL("../../tests/roms/lcdflicker.gb", import.meta.url)));
  const before = await bootApp({ serviceWorker: { controlled: true } });
  await settle();
  before.runIn("Module.ccall = () => 0"); // the boot after it: no core here
  await before.api.handleRomFile(fakeFile("G.gb", rom));
  await wait(50);
  assert.equal(before.idb.has("rom:G.gb"), true, "taken in with no update");

  const app = await bootApp({ serviceWorker: { controlled: true } });
  await settle();
  app.runIn("Module.ccall = () => 0");
  await clickUpdateWithWaiting(app);
  assert.equal(app.runIn("appUpdating"), true);
  await app.api.handleRomFile(fakeFile("G.gb", rom));
  await wait(50);
  assert.equal(app.idb.has("rom:G.gb"), false, "the file was not taken in");
});

test("Force update shows its card at once; one the worker can't finish shows the failed card, " +
     "nothing reset, however often it is tried again", async () => {
  const app = await bootApp({ serviceWorker: { controlled: true } });
  await settle();
  app.setConfirmResult(true);
  await app.elements.get("force-update").dispatch("click");
  await settle();
  const el = app.elements.get("updating");
  assert.ok(el.classList.contains("shown"), "a whole download: the card at once");
  assert.ok(app.sw.container.controller.messages.some((m) => m.type === "reinstall"));
  app.sw.container.dispatch("message", { data: { type: "reinstalled", ok: false } });
  await settle();
  assert.ok(el.classList.contains("failed"));
  assert.equal(app.sw.registration.unregisterCalls, 0, "nothing reset: the app's copy is as it was");
  assert.equal(app.state.reloads, 0);
  assert.equal(app.runIn("appUpdating"), false, "Drive renewals may go on");
  await app.elements.get("updating-retry").dispatch("click");
  await settle();
  assert.ok(!el.classList.contains("failed"), "Try Again: downloading again");
  app.sw.container.dispatch("message", { data: { type: "reinstalled", ok: false } });
  await settle();
  await settle();
  // On Matt's phone, with the server's manifest gone, a second failure's
  // full reset threw away a working offline copy: a failure the worker
  // reports never resets now.
  assert.ok(el.classList.contains("failed"), "the failed card again");
  assert.equal(app.sw.registration.unregisterCalls, 0, "still nothing reset");
  assert.equal(app.state.reloads, 0);
});

test("a Force update whose worker never answers still takes the full reset", async () => {
  // No reply and no progress for forceSilenceMs: the worker is what is
  // broken. Shortened here.
  const app = await bootApp({ serviceWorker: { controlled: true } });
  await settle();
  app.runIn("forceSilenceMs = 30");
  app.setConfirmResult(true);
  await app.elements.get("force-update").dispatch("click");
  await wait(80);
  await settle();
  assert.equal(app.sw.registration.unregisterCalls, 1, "the full reset");
  assert.equal(app.state.reloads, 1);
});

// ServiceWorker.lean's bug_force_failure_mid_update_reloads_midgame: an
// Update under way (its reload certain), a Force update started over it
// fails; taking appUpdating down then let a game start, and the Update's own
// end (here a failed install's full reset) reloaded it away.
test("a Force update failing while an Update's reload is on its way keeps the shield, " +
     "and no game starts (regress_force_failure_mid_update_reloads_midgame)", async () => {
  const app = await bootApp({ serviceWorker: { controlled: true } });
  await settle();
  app.runIn("Module.ccall = () => 0");
  const installing = app.sw.makeWorker("installing");
  app.state.swUpdateImpl = async () => { app.sw.registration.installing = installing; };
  await app.elements.get("update-btn").dispatch("click"); // the Update, watching its install
  await settle();
  app.setConfirmResult(true);
  await app.elements.get("force-update").dispatch("click");
  await settle();
  app.sw.container.dispatch("message", { data: { type: "reinstalled", ok: false } });
  await settle();
  const el = app.elements.get("updating");
  assert.equal(app.runIn("appUpdating"), true, "still updating: the Update's reload is coming");
  assert.ok(!el.classList.contains("failed"), "no \"nothing has changed\": something is about to");
  const rom = new Uint8Array(readFileSync(new URL("../../tests/roms/lcdflicker.gb", import.meta.url)));
  await app.api.handleRomFile(fakeFile("G.gb", rom));
  await wait(50);
  assert.equal(app.idb.has("rom:G.gb"), false, "no game started for the reload to take");
});

test("Close puts the page back after a failed Force update", async () => {
  const app = await bootApp({ serviceWorker: { controlled: true } });
  await settle();
  app.setConfirmResult(true);
  await app.elements.get("force-update").dispatch("click");
  await settle();
  app.sw.container.dispatch("message", { data: { type: "reinstalled", ok: false } });
  await settle();
  await app.elements.get("updating-close").dispatch("click");
  const el = app.elements.get("updating");
  assert.equal(el.hidden, true);
  assert.ok(!el.classList.contains("shown"));
});
