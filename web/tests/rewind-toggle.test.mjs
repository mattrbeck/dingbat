// The rewind switch: on by default, including for installs that predate the
// setting; off drops the wasm ring and hides every rewind control.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle, eq } from "./helpers.mjs";

// Records every _setRewindEnabled argument.
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

// A "system" record with no rewindOn key (pre-setting installs) must read as on.
test("a system record written before this setting existed stays on", async () => {
  const app = await bootWith({ gbFifo: true, gbaBiosMode: 1, gbaRunBios: false });
  assert.equal(rewindOn(app), true, "a missing key must resolve to ON, not undefined");
  assert.equal(hidden(app), false);
  eq(setCalls(app), [1]);
  // The neighbours in the record still load.
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
  // The double tap must not find a back door to the film strip either.
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

// Report-a-Bug still attaches the live moment with rewind off; the timeline
// goes and the hint says so.
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
