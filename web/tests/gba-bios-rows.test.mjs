// Settings > Game Boy Advance with no BIOS file: the core boots HLE with no
// intro whatever is stored (make_gba), so the intro switch shows off and
// disabled; the stored choices are kept and come back with a BIOS.
// (The fake DOM has no querySelectorAll, so the call-mode radios are covered
// in the browser, not here.)

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle } from "./helpers.mjs";

const bootWith = async (systemRecord, bios) => {
  const app = await loadApp();
  await app.api.dbPut("system", systemRecord);
  if (bios) await app.api.dbPut("bios:gba", { name: "gba_bios.bin", data: new Uint8Array(16) });
  await app.runIn("loadSystemSettings()");
  await app.runIn("updateBiosStatusText()");
  await settle();
  return app;
};

const intro = (app) => app.document.getElementById("gba-run-bios-toggle");
const introRow = (app) => app.document.getElementById("gba-run-bios-row");

test("with no BIOS the intro shows off and disabled, though it is stored on", async () => {
  const app = await bootWith({ gbaBiosMode: 1, gbaRunBios: true }, false);
  assert.equal(intro(app).checked, false, "no BIOS means no intro plays");
  assert.equal(intro(app).disabled, true);
  assert.equal(introRow(app).classList.contains("row-disabled"), true);
  // What is shown is not written back.
  assert.equal(app.runIn("gbaRunBios"), true);
  assert.equal(app.runIn("gbaBiosMode"), 1);
  const stored = await app.api.dbGet("system");
  assert.equal(stored.gbaRunBios, true);
  assert.equal(stored.gbaBiosMode, 1);
});

test("with a BIOS the stored intro shows, and is enabled", async () => {
  const app = await bootWith({ gbaBiosMode: 2, gbaRunBios: true }, true);
  assert.equal(intro(app).checked, true);
  assert.equal(intro(app).disabled, false);
  assert.equal(introRow(app).classList.contains("row-disabled"), false);
});

test("choosing a BIOS while Settings is open brings the stored intro back; removing it hides it again", async () => {
  const app = await bootWith({ gbaBiosMode: 0, gbaRunBios: true }, false);
  assert.equal(intro(app).checked, false);
  await app.api.dbPut("bios:gba", { name: "gba_bios.bin", data: new Uint8Array(16) });
  await app.runIn("updateBiosStatusText()");
  await settle();
  assert.equal(intro(app).checked, true);
  assert.equal(intro(app).disabled, false);
  await app.api.dbDelete("bios:gba");
  await app.runIn("updateBiosStatusText()");
  await settle();
  assert.equal(intro(app).checked, false);
  assert.equal(intro(app).disabled, true);
});

test("Reset all settings with no BIOS still shows the intro off", async () => {
  const app = await bootWith({ gbaBiosMode: 1, gbaRunBios: false }, false);
  await app.runIn("resetAllSettings()");
  await settle();
  assert.equal(app.runIn("gbaRunBios"), true, "the default is on");
  assert.equal(intro(app).checked, false, "but with no BIOS none plays");
  assert.equal(intro(app).disabled, true);
});
