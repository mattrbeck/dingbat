// Settings' BIOS / boot ROM / firmware rows: Remove is there only while a
// file is set (index.js setRemovable). With nothing set it is disabled - not
// clickable, drawn disabled, passed over by Tab and the controller
// (modalFocusables skips disabled) - and it follows a file being chosen or
// removed, and Reset all settings, which keeps the files.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle } from "./helpers.mjs";

const remove = (app, kind) => app.document.getElementById("remove-" + kind);
const status = (app, id) => app.document.getElementById(id).textContent;
const file = (n) => ({ name: n, data: new Uint8Array(16) });

const refresh = async (app) => {
  await app.runIn("updateBiosStatusText()");
  await app.runIn("updateNdsBiosStatus()");
  await settle();
};

test("with nothing set, every row's Remove is disabled", async () => {
  const app = await loadApp();
  await refresh(app);
  assert.equal(status(app, "gba-bios-status"), "Not set");
  assert.equal(status(app, "gbc-bootrom-status"), "Not set");
  for (const kind of ["gba-bios", "gbc-bootrom", "nds-bios9", "nds-bios7", "nds-firmware"]) {
    assert.equal(remove(app, kind).disabled, true, kind + ": nothing to remove");
  }
});

test("choosing a GBA BIOS or GBC boot ROM enables its Remove only; removing disables it again", async () => {
  const app = await loadApp();
  await app.api.dbPut("bios:gba", file("gba_bios.bin"));
  await refresh(app);
  assert.equal(remove(app, "gba-bios").disabled, false, "a BIOS is set");
  assert.equal(remove(app, "gbc-bootrom").disabled, true, "the boot ROM is still not set");

  await app.api.dbPut("bios:gbc", file("cgb_boot.bin"));
  await refresh(app);
  assert.equal(remove(app, "gbc-bootrom").disabled, false);

  // Remove, through its own handler.
  await remove(app, "gba-bios").dispatch("click");
  await settle();
  assert.ok(!(await app.api.dbGet("bios:gba")), "the BIOS is gone");
  assert.equal(status(app, "gba-bios-status"), "Not set");
  assert.equal(remove(app, "gba-bios").disabled, true, "and its Remove with it");
  assert.equal(remove(app, "gbc-bootrom").disabled, false, "the boot ROM's stays");

  await remove(app, "gbc-bootrom").dispatch("click");
  await settle();
  assert.equal(remove(app, "gbc-bootrom").disabled, true);
});

test("the DS rows: Remove follows each dump", async () => {
  const app = await loadApp();
  await app.api.dbPut(app.runIn("NDS_BIOS_KEYS.bios7"), file("bios7.bin"));
  await refresh(app);
  assert.equal(remove(app, "nds-bios7").disabled, false);
  assert.equal(remove(app, "nds-bios9").disabled, true);
  assert.equal(remove(app, "nds-firmware").disabled, true);

  await remove(app, "nds-bios7").dispatch("click");
  await settle();
  assert.equal(status(app, "nds-bios7-status"), "HLE");
  assert.equal(remove(app, "nds-bios7").disabled, true);
});

test("Reset all settings keeps the files, and each Remove as it stands", async () => {
  const app = await loadApp();
  await app.api.dbPut("bios:gba", file("gba_bios.bin"));
  await refresh(app);
  await app.runIn("resetAllSettings()");
  await settle();
  assert.equal(remove(app, "gba-bios").disabled, false, "the BIOS is still set");
  assert.equal(remove(app, "gbc-bootrom").disabled, true, "the boot ROM still is not");
});
