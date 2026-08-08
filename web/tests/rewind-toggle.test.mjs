// Rewind is the most expensive default the emulator carries (a state snapshot
// plus a thumbnail every REWIND_INTERVAL frames, ~6% of the core's own frame
// work), so the web frontend now has the on/off switch native always had.
//
// Two promises are under test, and they pull in opposite directions:
//   * ON is the default, for fresh installs AND for every install that
//     predates the setting — upgrading must never quietly take rewind away.
//   * OFF actually removes the feature: the wasm ring is dropped, and every
//     rewind control leaves the DOM's reach rather than sitting there inert.
//
// The harness is node:vm with a fake DOM, so these assert on state and on the
// body class that drives the CSS — never on anything visual.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle, eq } from "./helpers.mjs";

// A Module stub that records every _setRewindEnabled argument, so "the ring is
// really being dropped" is checked at the wasm boundary rather than inferred.
const withModule = (app) =>
  app.runIn(`
    globalThis.rewindSetCalls = [];
    globalThis.Module = {
      _setRewindEnabled: (v) => { rewindSetCalls.push(v); },
      _wasm_rewind_scrub_generate: () => 0,
    };
    rewindSetCalls`);

const setCalls = (app) => app.runIn("rewindSetCalls");
const rewindOn = (app) => app.runIn("rewindOn");
const hidden = (app) => app.document.body.classList.contains("rewind-off");

// Seed the "system" record the way a previous session would have left it, then
// run the real loader over it.
const bootWith = async (systemRecord) => {
  const app = await loadApp();
  withModule(app);
  if (systemRecord !== undefined) await app.api.dbPut("system", systemRecord);
  await app.runIn("loadSystemSettings()");
  await settle();
  return app;
};

test("a fresh install has rewind on, and says so to wasm", async () => {
  const app = await bootWith(undefined);
  assert.equal(rewindOn(app), true);
  assert.equal(hidden(app), false, "nothing should be hidden with rewind on");
  assert.equal(app.document.getElementById("rewind-toggle").checked, true);
  eq(setCalls(app), [1]);
});

// The regression this setting could most easily cause: everyone who ever
// opened the app before it existed has a "system" record with no rewindOn key,
// and reading it as `undefined` would turn rewind off for all of them.
test("a system record written before this setting existed stays on", async () => {
  const app = await bootWith({ gbFifo: true, gbaBiosMode: 1, gbaRunBios: false });
  assert.equal(rewindOn(app), true, "a missing key must resolve to ON, not undefined");
  assert.equal(hidden(app), false);
  eq(setCalls(app), [1]);
  // ...and the neighbours in the same record still load, i.e. this did not
  // just short-circuit the loader.
  assert.equal(app.runIn("gbaBiosMode"), 1);
  assert.equal(app.runIn("gbaRunBios"), false);
});

test("a saved OFF is honoured, and hides the UI from the first frame", async () => {
  const app = await bootWith({ rewindOn: false });
  assert.equal(rewindOn(app), false);
  assert.equal(hidden(app), true);
  assert.equal(app.document.getElementById("rewind-toggle").checked, false);
  eq(setCalls(app), [0], "the ring must never be allocated");
});

test("toggling off takes effect immediately — no reload", async () => {
  const app = await bootWith(undefined);
  const toggle = app.document.getElementById("rewind-toggle");
  toggle.checked = false;
  await toggle.dispatch("change");
  await settle();

  assert.equal(rewindOn(app), false);
  assert.equal(hidden(app), true, "the controls go on the same turn as the switch");
  assert.equal(setCalls(app).at(-1), 0, "wasm is told to drop the ring now");
  assert.deepEqual(
    (await app.api.dbGet("system")).rewindOn, false,
    "and it persists in the same system record as its neighbours");

  // ...and back on again, same turn.
  toggle.checked = true;
  await toggle.dispatch("change");
  await settle();
  assert.equal(hidden(app), false);
  assert.equal(setCalls(app).at(-1), 1);
  assert.equal((await app.api.dbGet("system")).rewindOn, true);
});

test("with rewind off the button gesture does nothing at all", async () => {
  const app = await bootWith({ rewindOn: false });
  app.runIn(`currentRomName = "game.gba"; currentOriginalName = "game.gba";`);
  const button = app.document.getElementById("rewind");
  const P = { clientX: 40, clientY: 20, pointerType: "touch", pointerId: 1 };

  await button.dispatch("pointerdown", { ...P });
  assert.equal(app.runIn("rewindHeld"), false, "a press must not start rewinding");
  await button.dispatch("pointerup", { ...P });
  // The double tap is the other gesture on the same target; it must not find a
  // back door to the film strip either.
  await button.dispatch("pointerdown", { ...P });
  await button.dispatch("pointerup", { ...P });
  assert.equal(
    app.document.getElementById("rewind-modal").classList.contains("open"), false,
    "the scrubber must not open with no ring behind it");
});

test("with rewind off the ` key is left to the page", async () => {
  const app = await bootWith({ rewindOn: false });
  app.runIn(`currentRomName = "game.gba"; currentOriginalName = "game.gba";`);
  let prevented = false;
  await app.dispatchDoc("keydown", {
    code: "Backquote", preventDefault: () => { prevented = true; },
  });
  assert.equal(app.runIn("kbRewindHeld"), false);
  assert.equal(app.runIn("rewindHeld"), false);
  assert.equal(prevented, false, "an unclaimed shortcut must not be swallowed");
});

test("the film strip closes if rewind is switched off while it is open", async () => {
  const app = await bootWith(undefined);
  app.runIn(`currentRomName = "game.gba"; currentOriginalName = "game.gba";`);
  app.runIn("openRewindScrubber()");
  const modal = app.document.getElementById("rewind-modal");
  assert.equal(modal.classList.contains("open"), true);

  const toggle = app.document.getElementById("rewind-toggle");
  toggle.checked = false;
  await toggle.dispatch("change");
  assert.equal(modal.classList.contains("open"), false,
    "the strip must not outlive the ring it is reading");
});

// Report-a-Bug can still attach the LIVE moment with rewind off; what it
// cannot do is address an earlier one. The timeline goes (via the body class)
// and the hint explains itself instead of pointing at a longer timeline that
// is not coming.
test("Report a Bug drops its timeline but keeps the live attachment", async () => {
  const app = await bootWith({ rewindOn: false });
  app.runIn(`currentRomName = "game.gba"; currentOriginalName = "game.gba";`);
  app.runIn("openReportModal()");
  const hint = app.document.getElementById("report-scrub-hint");
  assert.equal(hidden(app), true, "#report-slider is hidden by body.rewind-off");
  assert.equal(hint.hidden, false, "the hint must replace it, not vanish too");
  assert.match(hint.textContent, /Rewind is off/);
  assert.equal(app.document.getElementById("report-when").textContent, "now");
});

test("Reset all settings puts rewind back on", async () => {
  const app = await bootWith({ rewindOn: false });
  assert.equal(hidden(app), true);
  await app.api.resetAllSettings();
  await settle();
  assert.equal(rewindOn(app), true);
  assert.equal(hidden(app), false);
  assert.equal(setCalls(app).at(-1), 1);
});
