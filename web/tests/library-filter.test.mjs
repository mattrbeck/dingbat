// The library bar: one sort shared by the grid and the Manage list, a
// search box, system chips and (signed in) location chips. Filtering hides
// tiles in place; the count and the "No games match" note follow.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, gameTiles } from "./helpers.mjs";

const seed = (app, names, { local = names, ts } = {}) => {
  app.idb.set("recent", names.map((name, i) => ({ name, ts: ts ? ts[i] : 100 - i })));
  for (const n of local) app.idb.set("rom:" + n, { name: n, data: u8(1, 2) });
};
// Signed in, with a listing that has seen every library ROM on Drive - what
// makes a game this device lacks a Drive-only game rather than a lost one.
const signIn = (app, onDrive = LIB) => {
  app.api.gdriveToken = "t";
  const rmt = {};
  for (const n of onDrive) rmt["rom:" + n] = "t0";
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt, connected: true };
};
const grid = (app) => app.document.getElementById("home-recent");
const order = (app) => gameTiles(app).map((t) => t.dataset.system + ":" + t.children[0].children[1].children[0].textContent);
const visible = (app) => gameTiles(app).filter((t) => !t.hidden).map((t) => t.children[0].children[1].children[0].textContent);
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

test("the field's clear button empties the search and shows every game", async () => {
  const app = await loadApp();
  seed(app, LIB);
  await app.api.refreshHomeRecent();
  await settle();
  await search(app, "tet");
  eq(visible(app), ["Tetris"]);

  await app.document.getElementById("lib-search-clear").click();
  await settle();
  assert.equal(app.document.getElementById("lib-search").value, "");
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

test("search is forgiving: spacing, punctuation, word order, a dropped letter", async () => {
  const app = await loadApp();
  const m = (q, name) => app.api.libSearchMatch(q, app.api.libFold(name));
  const FR = "Pokemon FireRed", LA = "Link's Awakening DX", AW = "Advance Wars";

  // Spaces and punctuation never matter, either side.
  assert.ok(m("firered", FR));
  assert.ok(m("fire red", FR));
  assert.ok(m("Fire-Red", FR));
  assert.ok(m("pokemonfire", FR));
  assert.ok(m("links awakening", LA));
  assert.ok(m("linksawakening", LA));
  assert.ok(m("link's", LA));

  // Words in any order.
  assert.ok(m("wars advance", AW));
  assert.ok(m("red pokemon", FR));

  // A dropped or swapped letter still lands (three characters or more).
  assert.ok(m("pokmon", FR));
  assert.ok(m("zlda", "Zelda"));
  assert.ok(m("adwars", AW));
  assert.ok(m("law", LA), "initials, in order");

  // ...but short words stay exact, and out-of-order characters do not match.
  assert.ok(!m("ar", "Zelda"));
  assert.ok(m("ar", AW));
  assert.ok(!m("derif", FR));
  assert.ok(!m("wars advance x", AW), "every word has to land");
  assert.ok(m("", AW), "nothing typed matches everything");
  assert.ok(m("   ", AW));
});

test("the grid filters through the forgiving match", async () => {
  const app = await loadApp();
  seed(app, ["Pokemon FireRed.gba", "Link's Awakening DX.gbc", "Advance Wars.gba", "Tetris.gb"]);
  await app.api.refreshHomeRecent();
  await settle();
  await search(app, "fire red");
  eq(visible(app), ["Pokemon FireRed"]);
  await search(app, "linksawak");
  eq(visible(app), ["Link's Awakening DX"]);
  await search(app, "wars adv");
  eq(visible(app), ["Advance Wars"]);
  await search(app, "tetrs");
  eq(visible(app), ["Tetris"]);
  await search(app, ".gba");
  eq(visible(app), [], "the extension is not part of the name; the system chips are for that");
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
  eq(chips(app), ["GBA2", "GBC1", "GB2", "On device2", "On Drive3"]);

  chip(app, "On Drive").click();
  await settle();
  eq(visible(app), ["Advance Wars", "Crystal", "Mario"]);
  chip(app, "On device").click(); // one location at a time
  await settle();
  eq(visible(app), ["Zelda", "Tetris"]);
  eq(chips(app).filter((c) => c.endsWith("*")), ["On device2*"]);
  chip(app, "On device").click(); // off
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


// ── The add tile ────────────────────────────────────────────────────────────
// The grid's first cell is the way in from a file. It is not a game, and
// everything that counts, filters or names games has to know that.

test("the add tile leads the grid, counts as no game, and steps aside for a filter", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc", "Metroid.gba"]);
  await app.api.refreshHomeRecent();
  await settle();

  const cells = app.document.getElementById("home-recent").children;
  assert.ok(cells[0].classList.contains("add-tile"), "first cell");
  assert.ok(!cells[0].classList.contains("home-tile"), "and not a game");
  assert.equal(gameTiles(app).length, 2);
  assert.equal(count(app), "2 games", "the count is of games, not cells");
  assert.equal(cells[0].hidden, false);

  // Searching asks a question about the games that are there; a cell that is
  // not a game is in the way of the answer.
  await search(app, "zel");
  assert.equal(cells[0].hidden, true, "gone while a search runs");
  assert.equal(count(app), "1 of 2");

  await search(app, "");
  assert.equal(cells[0].hidden, false, "and back when the grid is the library again");
});
