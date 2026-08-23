// The LCD response switch (src/dingbat/common/lcd_response.nim; the core
// resolves the panel from the running machine). Pins the two stored-record
// migrations: `{motionBlur: true}` in "video" and a panel name under
// `lcdResponse` both mean on; an unknown value falls back to off, never to
// NaN at the wasm boundary.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadApp, settle, eq } from "./helpers.mjs";

// Record every value handed to the core.
const withModule = (app) =>
  app.runIn(`
    globalThis.lcdCalls = [];
    globalThis.Module = { _wasm_set_lcd_response: (v) => { lcdCalls.push(v); } };
    lcdCalls`);

const calls = (app) => app.runIn("lcdCalls");
const mode = (app) => app.runIn("lcdResponse");
const toggle = (app) => app.document.getElementById("lcd-response-toggle");

const bootWith = async (videoRecord) => {
  const app = await loadApp();
  withModule(app);
  if (videoRecord !== undefined) await app.api.dbPut("video", videoRecord);
  await app.runIn("loadVideoSettings()");
  await settle();
  return app;
};

test("a fresh install has the model off, and says so to wasm", async () => {
  const app = await bootWith(undefined);
  assert.equal(mode(app), false);
  assert.equal(toggle(app).checked, false);
  eq(calls(app), [0]);
});

test("motion blur on migrates to the model on", async () => {
  const app = await bootWith({ integerScale: false, scanlines: false, motionBlur: true });
  assert.equal(mode(app), true, "someone who wanted panel ghosting keeps it");
  assert.equal(toggle(app).checked, true);
  eq(calls(app), [1]);
});

test("motion blur off migrates to off", async () => {
  const app = await bootWith({ integerScale: false, scanlines: false, motionBlur: false });
  assert.equal(mode(app), false);
  eq(calls(app), [0]);
});

test("a video record written before either setting existed stays off", async () => {
  const app = await bootWith({ integerScale: true, scanlines: true });
  assert.equal(mode(app), false);
  eq(calls(app), [0]);
  // The neighbours in the record still load; the old scanlines toggle
  // migrates into the Filter selector's LCD-grid option.
  assert.equal(app.runIn("integerScale"), true);
  assert.equal(app.runIn("upscaleFilter"), "grid");
});

test("a legacy scanlines toggle loses to a stored smoothing filter", async () => {
  // The old UI suspended scanlines under a filter, so a record with both
  // means the user was seeing the filter.
  const app = await bootWith({ scanlines: true, upscaleFilter: "xbr" });
  assert.equal(app.runIn("upscaleFilter"), "xbr");
});

test("every panel name the old picker could store migrates to on", async () => {
  // The picker's values plus the aliases parse_enabled (lcd_response.nim)
  // accepts; the two lists must agree.
  for (const name of ["auto", "dmg", "cgb", "agb", "ags"]) {
    const app = await bootWith({ lcdResponse: name });
    assert.equal(mode(app), true, `"${name}" was a request for panel response`);
    eq(calls(app), [1]);
  }
});

test("the picker's own off value stays off", async () => {
  const app = await bootWith({ lcdResponse: "off", motionBlur: true });
  assert.equal(mode(app), false, "an explicit off outranks a leftover motionBlur");
  eq(calls(app), [0]);
});

test("a stored boolean is taken as-is", async () => {
  const app = await bootWith({ lcdResponse: true, motionBlur: false });
  assert.equal(mode(app), true);
  eq(calls(app), [1]);
});

test("a value this build does not understand falls back to off", async () => {
  // A newer build's name, or a corrupted record: wasm must get a real 0/1.
  const app = await bootWith({ lcdResponse: "plasma" });
  assert.equal(mode(app), false);
  eq(calls(app), [0]);
});

test("the control is a switch, and the panel names are gone from the markup", async () => {
  // Read the real markup (the fake DOM has no HTML parser). No panel model
  // name belongs in this row.
  const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  assert.match(html, /<input type="checkbox" id="lcd-response-toggle"/,
               "the row has to carry the checkbox index.js looks up");
  assert.ok(!html.includes("lcd-response-select"),
            "the six-way picker must be gone, not merely unused");
  const row = html.slice(html.lastIndexOf('<div class="modal-toggle-row',
                                          html.indexOf("lcd-response-toggle")));
  const block = row.slice(0, row.indexOf("</div>"));
  for (const name of ["AGB-001", "AGS-101", "DMG", "Game Boy Color"]) {
    assert.ok(!block.includes(name), `"${name}" is not the user's problem`);
  }
});

test("flipping the switch pushes it through and persists it", async () => {
  const app = await bootWith(undefined);
  const el = toggle(app);
  el.checked = true;
  await el.dispatch("change");
  await settle();
  assert.equal(mode(app), true);
  eq(calls(app), [0, 1]);
  const saved = await app.api.dbGet("video");
  assert.equal(saved.lcdResponse, true, "the choice has to survive a reload");
});
