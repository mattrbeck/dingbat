// Wide screens show the paused game once: the card at the top is that game,
// so its tile stands down from the grid (.is-current) and a library holding
// nothing but it folds away (body.home-solo). The grid's track count
// (#home-inner[data-n]) must follow, or the tiles centre on an empty column.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle, gameTiles } from "./helpers.mjs";

const setup = async (names, { wide = true, current = names[0], card = true } = {}) => {
  const app = await loadApp();
  app.idb.set("recent", names.map((name, i) => ({ name, ts: names.length - i })));
  for (const name of names) app.idb.set("rom:" + name, { name, data: new Uint8Array([1]) });
  app.runIn(`homeWideQuery.matches = ${wide}`);
  app.api.currentOriginalName = current;
  if (card) app.document.body.classList.add("home-card");
  await app.api.refreshHomeRecent();
  await settle();
  return app;
};

const body = (app) => app.document.body.classList;
const fit = (app) => app.document.getElementById("home-inner").dataset.n;
const current = (app) =>
  gameTiles(app).filter((t) => t.classList.contains("is-current")).map((t) => t.dataset.rom);

test("wide, card up: the paused game's tile stands down and the fit drops by one", async () => {
  const app = await setup(["A.gba", "B.gba", "C.gba"]);
  assert.deepEqual(current(app), ["A.gba"]);
  assert.equal(fit(app), "3", "add tile + B + C");
  assert.ok(!body(app).contains("home-solo"));
});

test("wide, a library of only the paused game folds away", async () => {
  const app = await setup(["A.gba"]);
  assert.ok(body(app).contains("home-solo"));
});

test("narrow: the tile is marked but the fit still counts it", async () => {
  const app = await setup(["A.gba", "B.gba"], { wide: false });
  assert.deepEqual(current(app), ["A.gba"]);
  assert.equal(fit(app), "3", "add tile + A + B: styles.css only hides it wide");
});

test("no card up (a link session, or nothing loaded): nothing stands down", async () => {
  const app = await setup(["A.gba", "B.gba"], { card: false });
  assert.deepEqual(current(app), []);
  assert.equal(fit(app), "3");
  assert.ok(!body(app).contains("home-solo"));
});

test("a paused game that is not in the library changes nothing", async () => {
  const app = await setup(["A.gba"], { current: "Other.gba" });
  assert.deepEqual(current(app), []);
  assert.ok(!body(app).contains("home-solo"));
  assert.equal(fit(app), "2");
});

test("closing the card brings the tile back and unfolds the library", async () => {
  const app = await setup(["A.gba"]);
  assert.ok(body(app).contains("home-solo"));
  app.runIn("setPausedCardShown(false)");
  assert.ok(!body(app).contains("home-solo"));
  assert.deepEqual(current(app), []);
  assert.equal(fit(app), "2");
});

test("a search marks the page so the stood-down tile can come back", async () => {
  const app = await setup(["A.gba", "B.gba"]);
  assert.ok(!body(app).contains("lib-filtering"));
  app.runIn(`libFilter.q = "a"; applyLibFilter()`);
  assert.ok(body(app).contains("lib-filtering"));
  app.runIn(`libFilter.q = ""; applyLibFilter()`);
  assert.ok(!body(app).contains("lib-filtering"));
});
