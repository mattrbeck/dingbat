// "Hide the top bar while playing" (fold-bar-upright): on by default, kept,
// forgotten by Reset all settings, and the phone-upright layout it drives
// (the bar folds away, one row for L / Select / Start / R, the picture a
// window in from the sides) is in the stylesheet.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadApp, settle } from "./helpers.mjs";

test("a fresh install folds the bar away", async () => {
  const app = await loadApp();
  await app.runIn("loadFoldBarFromStorage()");
  await settle();
  assert.equal(app.runIn("foldBarUpright"), true);
  assert.equal(app.document.body.classList.contains("bar-fold"), true);
});

test("switched off it stays off, and Reset all settings brings it back", async () => {
  const app = await loadApp();
  await app.runIn("loadFoldBarFromStorage()");
  const toggle = app.document.getElementById("fold-bar-toggle");
  toggle.checked = false;
  await toggle.dispatch("change");
  await settle();
  assert.equal(await app.api.dbGet("fold-bar-upright"), false);
  assert.equal(app.document.body.classList.contains("bar-fold"), false);

  const app2 = await loadApp();
  await app2.api.dbPut("fold-bar-upright", false);
  await app2.runIn("loadFoldBarFromStorage()");
  await settle();
  assert.equal(app2.runIn("foldBarUpright"), false);
  assert.ok(app2.runIn('SETTINGS_KEYS.includes("fold-bar-upright")'));
  await app2.runIn("resetAllSettings()");
  await settle();
  assert.equal(app2.runIn("foldBarUpright"), true);
  assert.equal(await app2.api.dbGet("fold-bar-upright") ?? null, null);
});

test("the stylesheet folds the bar and shares one row between L, Select, Start and R", () => {
  const css = readFileSync(new URL("../styles.css", import.meta.url), "utf8");
  const at = css.indexOf("Phone held upright: the picture gets the room.");
  assert.ok(at > 0, "the phone-upright block");
  const block = css.slice(at, css.indexOf("\n}\n", at));
  for (const rule of ["body.running.bar-fold #topbar", "#lr {\n    display: contents;",
                      "#select-start {\n    grid-area: 1 / 2;", "--stage-inset"]) {
    assert.ok(block.includes(rule), rule);
  }
  const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  assert.equal((html.match(/data-fold-bar/g) || []).length, 2,
               "Settings > Controls and the DS Screens panel carry the switch");
});
