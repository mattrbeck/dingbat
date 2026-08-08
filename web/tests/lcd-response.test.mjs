// "Motion blur" — a 50/50 average of the last two frames — was replaced by the
// LCD response model (src/dingbat/common/lcd_response.nim), which is a
// per-pixel panel simulation with a real asymmetry rather than a fixed alpha.
// The setting changed shape with it: a checkbox became a panel picker.
//
// The regression that costs the most and is easiest to cause is the migration.
// Everyone who ever turned motion blur on has `{motionBlur: true}` in the
// "video" record and no `lcdResponse` key; reading the new key straight off
// that record would silently take the feature away from exactly the people who
// had asked for it. The other direction matters too — a stored value the build
// no longer understands has to fall back to off, not to `undefined` sliding
// into the wasm call as NaN.
//
// The harness is node:vm with a fake DOM, so these assert on state and on what
// reaches the wasm boundary, never on anything visual.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadApp, settle, eq } from "./helpers.mjs";

// Record every ordinal handed to the core, so "the setting reached wasm" is
// checked at the boundary instead of inferred from a JS variable.
const withModule = (app) =>
  app.runIn(`
    globalThis.lcdCalls = [];
    globalThis.Module = { _wasm_set_lcd_response: (v) => { lcdCalls.push(v); } };
    lcdCalls`);

const calls = (app) => app.runIn("lcdCalls");
const mode = (app) => app.runIn("lcdResponse");
const select = (app) => app.document.getElementById("lcd-response-select");

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
  assert.equal(mode(app), "off");
  assert.equal(select(app).value, "off");
  eq(calls(app), [0]);
});

test("motion blur on migrates to the machine's own panel", async () => {
  const app = await bootWith({ integerScale: false, scanlines: false, motionBlur: true });
  assert.equal(mode(app), "auto", "someone who wanted panel ghosting keeps it");
  assert.equal(select(app).value, "auto");
  eq(calls(app), [1]);
});

test("motion blur off migrates to off", async () => {
  const app = await bootWith({ integerScale: false, scanlines: false, motionBlur: false });
  assert.equal(mode(app), "off");
  eq(calls(app), [0]);
});

test("a video record written before either setting existed stays off", async () => {
  const app = await bootWith({ integerScale: true, scanlines: true });
  assert.equal(mode(app), "off");
  eq(calls(app), [0]);
  // ...and the neighbours in the same record still load, i.e. this did not
  // just swallow the whole record.
  assert.equal(app.runIn("integerScale"), true);
  assert.equal(app.runIn("scanlines"), true);
});

test("an explicit panel wins over a leftover motionBlur key", async () => {
  const app = await bootWith({ lcdResponse: "ags", motionBlur: true });
  assert.equal(mode(app), "ags");
  eq(calls(app), [5]);
});

test("a value this build does not understand falls back to off", async () => {
  // A newer build's panel name, or a corrupted record. The ordinal handed to
  // wasm must be a real one either way.
  const app = await bootWith({ lcdResponse: "plasma" });
  assert.equal(mode(app), "off");
  eq(calls(app), [0]);
});

test("every option in the picker is a mode the app accepts", async () => {
  // Read the real markup: the fake DOM has no HTML parser, and this is exactly
  // the pairing that would rot silently. The <option> order IS the wire
  // format — the index into LCD_MODES is what gets handed to the core.
  const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  const block = html.slice(html.indexOf('id="lcd-response-select"'));
  const options = [...block.slice(0, block.indexOf("</select>"))
    .matchAll(/<option value="([^"]+)"/g)].map((m) => m[1]);
  const app = await bootWith(undefined);
  eq(options, app.runIn("LCD_MODES"),
     "the markup and the ordinal table have to agree, in the same order");
});

test("changing the picker pushes the new panel through and persists it", async () => {
  const app = await bootWith(undefined);
  const sel = select(app);
  sel.value = "dmg";
  await sel.dispatch("change");
  await settle();
  assert.equal(mode(app), "dmg");
  eq(calls(app), [0, 2]);
  const saved = await app.api.dbGet("video");
  assert.equal(saved.lcdResponse, "dmg", "the choice has to survive a reload");
});
