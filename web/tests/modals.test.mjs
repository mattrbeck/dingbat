// Modal keyboard behavior. The net modal is closed by netplay.js, which is
// not loaded here.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const MODAL_IDS = [
  "settings-modal", "saves-modal", "roms-modal", "update-modal",
  "states-modal", "cheats-modal", "report-modal",
];

test("Escape closes every index.js-owned modal", async () => {
  const app = await loadApp();
  for (const id of MODAL_IDS) {
    const modal = app.document.getElementById(id);
    modal.classList.add("open");
    await app.dispatchDoc("keydown", { key: "Escape" });
    assert.equal(modal.classList.contains("open"), false,
      id + " should close on Escape");
  }
});

test("Escape closes all open modals in one press", async () => {
  const app = await loadApp();
  for (const id of MODAL_IDS) app.document.getElementById(id).classList.add("open");
  await app.dispatchDoc("keydown", { key: "Escape" });
  for (const id of MODAL_IDS) {
    assert.equal(app.document.getElementById(id).classList.contains("open"), false,
      id + " should close");
  }
});

test("blind closeReportModal keeps the current pause state", async () => {
  const app = await loadApp();
  // Report modal used once while running, then closed; then the user pauses.
  app.runIn("reportWasPaused = false; paused = true;");
  // A blind closeReportModal must not resume the game off a stale reportWasPaused.
  await app.dispatchDoc("keydown", { key: "Escape" });
  assert.equal(app.runIn("paused"), true,
    "stale reportWasPaused must not leak into paused");
});

test("releaseFocus ignores overlays that don't own the trap", async () => {
  const app = await loadApp();
  const states = app.document.getElementById("states-modal");
  const settings = app.document.getElementById("settings-modal");
  app.runIn("trapFocus(document.getElementById('states-modal'))");
  states.classList.add("open");
  // A release for a different overlay must be a no-op.
  app.runIn("releaseFocus(document.getElementById('settings-modal'))");
  assert.notEqual(app.runIn("modalTrapOverlay"), null,
    "foreign releaseFocus must not clear the trap");
  app.runIn("releaseFocus(document.getElementById('states-modal'))");
  assert.equal(app.runIn("modalTrapOverlay"), null);
  assert.equal(settings.classList.contains("open"), false);
});
