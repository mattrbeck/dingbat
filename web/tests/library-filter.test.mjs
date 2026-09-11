// The library bar: one sort shared by the grid and the Manage list, a
// search box, system chips and (signed in) location chips. Filtering hides
// tiles in place; the count and the "No games match" note follow.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle } from "./helpers.mjs";

const seed = (app, names, { local = names, ts } = {}) => {
  app.idb.set("recent", names.map((name, i) => ({ name, ts: ts ? ts[i] : 100 - i })));
  for (const n of local) app.idb.set("rom:" + n, { name: n, data: u8(1, 2) });
};
const signIn = (app) => {
  app.api.gdriveToken = "t";
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true };
};
const grid = (app) => app.document.getElementById("home-recent");
const order = (app) => grid(app).children.map((t) => t.dataset.system + ":" + t.children[0].children[1].children[0].textContent);
const visible = (app) => grid(app).children.filter((t) => !t.hidden).map((t) => t.children[0].children[1].children[0].textContent);
const chips = (app) => app.document.getElementById("lib-chips").children.map((c) =>
  c.textContent + (c.children[0]?.textContent ?? "") +
  (c.getAttribute("aria-pressed") === "true" ? "*" : ""));
const chip = (app, label) => app.document.getElementById("lib-chips").children.find((c) => c.textContent === label);
const count = (app) => app.document.getElementById("lib-count").textContent;
const search = async (app, q) => {
  const el = app.document.getElementById("lib-search");
  el.value = q;
  el.dispatch("input");
  await settle();
};

const LIB = ["Zelda.gba", "Tetris.gb", "Advance Wars.gba", "Crystal.gbc", "Mario.gb"];

// ── Sort ────────────────────────────────────────────────────────────────────

test("the default sort is play order; A–Z and System are the other two", async () => {
  const app = await loadApp();
  seed(app, LIB);
  await app.api.refreshHomeRecent();
  await settle();
  eq(order(app), ["GBA:Zelda", "GB:Tetris", "GBA:Advance Wars", "GBC:Crystal", "GB:Mario"]);

  await app.api.setRomsSort("alpha");
  await settle();
  eq(order(app), ["GBA:Advance Wars", "GBC:Crystal", "GB:Mario", "GB:Tetris", "GBA:Zelda"]);

  await app.api.setRomsSort("system");
  await settle();
  eq(order(app), ["GBA:Advance Wars", "GBA:Zelda", "GBC:Crystal", "GB:Mario", "GB:Tetris"],
    "GBA, GBC, GB; names within");
  assert.equal(app.idb.get("roms_sort"), "system", "kept for next time");
  assert.equal(app.document.getElementById("lib-sort").value, "system");
});

test("the Manage list follows the same sort", async () => {
  const app = await loadApp();
  seed(app, LIB);
  await app.api.setRomsSort("alpha");
  const rows = await app.api.romsForManagement();
  eq(rows.map((r) => r.name), ["Advance Wars.gba", "Crystal.gbc", "Mario.gb", "Tetris.gb", "Zelda.gba"]);
  await app.api.setRomsSort("system");
  eq((await app.api.romsForManagement()).map((r) => r.name),
     ["Advance Wars.gba", "Zelda.gba", "Crystal.gbc", "Mario.gb", "Tetris.gb"]);
});

test("an unknown stored sort falls back to play order", async () => {
  const app = await loadApp();
  app.idb.set("roms_sort", "bogus");
  await app.runIn("loadRomsSort()");
  assert.equal(app.api.romsSort, "recent");
});

// ── Search ──────────────────────────────────────────────────────────────────

test("typing hides the tiles that do not match; the count and the note follow", async () => {
  const app = await loadApp();
  seed(app, LIB);
  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(count(app), "5 games");

  await search(app, "ar");
  eq(visible(app), ["Advance Wars", "Mario"]);
  assert.equal(count(app), "2 of 5");
  assert.equal(app.document.getElementById("lib-none").hidden, true);

  await search(app, "  ZEL ");
  eq(visible(app), ["Zelda"], "trimmed, case-insensitive");

  await search(app, "pokemon");
  eq(visible(app), []);
  assert.equal(app.document.getElementById("lib-none").hidden, false);
  assert.equal(count(app), "0 of 5");

  await search(app, "");
  eq(visible(app).length, 5);
  assert.equal(count(app), "5 games");
});

test("a re-render keeps the filter (no flash of the full grid)", async () => {
  const app = await loadApp();
  seed(app, LIB);
  await app.api.refreshHomeRecent();
  await settle();
  await search(app, "tet");
  await app.api.refreshHomeRecent(); // a sync, a download, a picture landing
  await settle();
  eq(visible(app), ["Tetris"]);
});

// ── Chips ───────────────────────────────────────────────────────────────────

test("system chips carry counts, toggle, and combine with search", async () => {
  const app = await loadApp();
  seed(app, LIB);
  await app.api.refreshHomeRecent();
  await settle();
  eq(chips(app), ["GBA2", "GBC1", "GB2"]);

  chip(app, "GB").click();
  await settle();
  eq(chips(app), ["GBA2", "GBC1", "GB2*"]);
  eq(visible(app), ["Tetris", "Mario"]);

  chip(app, "GBA").click(); // two systems: either
  await settle();
  eq(visible(app), ["Zelda", "Tetris", "Advance Wars", "Mario"]);

  await search(app, "m");
  eq(visible(app), ["Mario"]);

  chip(app, "GB").click();
  chip(app, "GBA").click(); // both off again
  await settle();
  eq(visible(app), ["Mario"], "search alone");
});

test("no system chips for a one-system library; no bar for one game", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"]);
  await app.api.refreshHomeRecent();
  await settle();
  eq(chips(app), []);
  assert.equal(app.document.getElementById("lib-bar").hidden, false);

  seed(app, ["A.gba"]);
  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(app.document.getElementById("lib-bar").hidden, true);
});

test("location chips appear signed in with games on both sides, and filter", async () => {
  const app = await loadApp();
  seed(app, LIB, { local: ["Zelda.gba", "Tetris.gb"] });
  await app.api.refreshHomeRecent();
  await settle();
  eq(chips(app).filter((c) => /device|Drive/.test(c)), [], "signed out: no location chips");

  signIn(app);
  await app.api.refreshHomeRecent();
  await settle();
  eq(chips(app), ["GBA2", "GBC1", "GB2", "On this device2", "On Drive3"]);

  chip(app, "On Drive").click();
  await settle();
  eq(visible(app), ["Advance Wars", "Crystal", "Mario"]);
  chip(app, "On this device").click(); // one location at a time
  await settle();
  eq(visible(app), ["Zelda", "Tetris"]);
  eq(chips(app).filter((c) => c.endsWith("*")), ["On this device2*"]);
  chip(app, "On this device").click(); // off
  await settle();
  eq(visible(app).length, 5);
});

test("a filter that stops meaning anything is dropped, not stuck", async () => {
  const app = await loadApp();
  seed(app, LIB, { local: ["Zelda.gba"] });
  signIn(app);
  await app.api.refreshHomeRecent();
  await settle();
  chip(app, "On Drive").click();
  chip(app, "GBC").click();
  await settle();
  eq(visible(app), ["Crystal"]);

  // Everything downloaded and the GBC game gone: both chips vanish, and
  // the grid is not left filtered by a choice that no longer exists.
  seed(app, ["Zelda.gba", "Tetris.gb"]);
  await app.api.refreshHomeRecent();
  await settle();
  eq(chips(app), ["GBA1", "GB1"]);
  eq(visible(app), ["Zelda", "Tetris"]);
  assert.equal(app.api.libFilter.loc, "all");
  assert.equal(app.api.libFilter.systems.size, 0);
});
