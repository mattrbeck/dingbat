// Modal keyboard/consistency behavior (web/index.js), via the vm harness:
//   - Escape closes EVERY index.js-owned modal (the net modal is closed by
//     netplay.js, which isn't loaded here);
//   - a blind closeReportModal (Escape with the modal shut) must not clobber
//     the current pause state with a stale reportWasPaused;
//   - releaseFocus only acts for the overlay that owns the focus trap, so a
//     blind closer can't release a different modal's trap.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

// Every index.js modal the global Escape handler must close.
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
  // Simulate: report modal was used once while running (reportWasPaused=false),
  // then closed; later the user pauses the game.
  app.runIn("reportWasPaused = false; paused = true;");
  // Escape with the report modal NOT open must not resume the game.
  await app.dispatchDoc("keydown", { key: "Escape" });
  assert.equal(app.runIn("paused"), true,
    "stale reportWasPaused must not leak into paused");
});

test("releaseFocus ignores overlays that don't own the trap", async () => {
  const app = await loadApp();
  const states = app.document.getElementById("states-modal");
  const settings = app.document.getElementById("settings-modal");
  // Open the states modal for real so it takes the focus trap.
  app.runIn("trapFocus(document.getElementById('states-modal'))");
  states.classList.add("open");
  // A blind release for a DIFFERENT overlay must be a no-op...
  app.runIn("releaseFocus(document.getElementById('settings-modal'))");
  assert.notEqual(app.runIn("modalTrapOverlay"), null,
    "foreign releaseFocus must not clear the trap");
  // ...while the owner's release clears it.
  app.runIn("releaseFocus(document.getElementById('states-modal'))");
  assert.equal(app.runIn("modalTrapOverlay"), null);
  assert.equal(settings.classList.contains("open"), false);
});
