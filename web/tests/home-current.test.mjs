// The hero heads the home screen with the library's most recent game - the
// paused one while a game is loaded, else the last one played - and that
// game is shown once, at every width: its tile stands down from the grid
// (.is-current) and a library holding nothing but it folds away
// (body.home-solo). The grid's track count (#home-inner[data-n]) must follow,
// or the tiles centre on an empty column.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle, gameTiles, u8 } from "./helpers.mjs";

const drain = async (n = 8) => { for (let i = 0; i < n; i++) await settle(); };

const seed = (app, names) => {
  app.idb.set("recent", names.map((name, i) => ({ name, ts: names.length - i })));
  for (const name of names) app.idb.set("rom:" + name, { name, data: new Uint8Array([1]) });
};

// A loaded game with the paused card up, as showMainMenu leaves it.
const pausedOn = async (names, current = names[0]) => {
  const app = await loadApp();
  seed(app, names);
  app.api.currentOriginalName = current;
  app.api.currentRomName = "rom.gba";
  app.runIn(`setHeroMode("paused", ${JSON.stringify(current)})`);
  await app.api.refreshHomeRecent();
  await drain();
  return app;
};

// Nothing loaded: the hero is the last game played, from the library alone.
const closedOn = async (names) => {
  const app = await loadApp();
  seed(app, names);
  await app.api.refreshHomeRecent();
  await drain();
  return app;
};

const body = (app) => app.document.body.classList;
const hero = (app) => app.document.getElementById("hero");
const fit = (app) => app.document.getElementById("home-inner").dataset.n;
const current = (app) =>
  gameTiles(app).filter((t) => t.classList.contains("is-current")).map((t) => t.dataset.rom);
const shown = (id, app) => !app.document.getElementById(id).hidden;

test("paused: the loaded game's tile stands down and the fit drops by one", async () => {
  const app = await pausedOn(["A.gba", "B.gba", "C.gba"]);
  assert.equal(hero(app).dataset.mode, "paused");
  assert.deepEqual(current(app), ["A.gba"]);
  assert.equal(fit(app), "2", "B + C");
  assert.ok(!body(app).contains("home-solo"));
  assert.ok(shown("hero-close", app));
  assert.ok(!shown("hero-play", app));
});

test("a library of only the hero's game folds away", async () => {
  const app = await pausedOn(["A.gba"]);
  assert.ok(body(app).contains("home-solo"));
});

test("nothing loaded: the hero is the most recently played game, closed", async () => {
  const app = await loadApp();
  // Play order, not the grid's sort: the newest timestamp wins wherever it is.
  app.idb.set("recent", [{ name: "A.gba", ts: 5 }, { name: "B.gba", ts: 9 }, { name: "C.gba", ts: 1 }]);
  for (const n of ["A.gba", "B.gba", "C.gba"]) app.idb.set("rom:" + n, { name: n, data: u8(1) });
  await app.api.refreshHomeRecent();
  await drain();
  assert.equal(hero(app).hidden, false);
  assert.equal(hero(app).dataset.mode, "closed");
  assert.equal(app.document.getElementById("hero-name").textContent, "B");
  assert.deepEqual(current(app), ["B.gba"]);
  assert.equal(fit(app), "2");
  assert.equal(app.document.getElementById("hero-state").textContent, "Last played");
});

test("closed, with no session to go back into: Play, and no Restart", async () => {
  const app = await closedOn(["A.gba", "B.gba"]);
  assert.equal(app.document.getElementById("hero-resume-label").textContent, "Play");
  assert.ok(!shown("hero-play", app));
  assert.ok(!shown("hero-close", app));
});

test("closed, with a session that matches the save: Resume and Restart", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"]);
  app.idb.set("save:A.gba", u8(1, 2, 3));
  const sig = app.runIn("saveSignature(new Uint8Array([1, 2, 3]))");
  app.idb.set("stateauto:A.gba", { bytes: u8(9), ts: 1, saveSig: sig });
  await app.api.refreshHomeRecent();
  await drain();
  assert.equal(app.document.getElementById("hero-resume-label").textContent, "Resume");
  assert.ok(shown("hero-play", app));

  // The game saved since: the session is not the game any more.
  app.idb.set("save:A.gba", u8(4, 5, 6));
  await app.api.refreshHomeRecent();
  await drain();
  assert.equal(app.document.getElementById("hero-resume-label").textContent, "Play");
  assert.ok(!shown("hero-play", app));
});

test("a session the card cannot draw (2P link): no hero, nothing stands down", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"]);
  app.runIn("linkMode = true");
  await app.api.refreshHomeRecent();
  await drain();
  assert.equal(hero(app).hidden, true);
  assert.deepEqual(current(app), []);
  assert.equal(fit(app), "2");
  assert.ok(!body(app).contains("home-solo"));
  app.runIn("linkMode = false");
});

test("an empty library has no hero", async () => {
  const app = await closedOn([]);
  assert.equal(hero(app).hidden, true);
  assert.ok(!body(app).contains("home-card"));
});

test("a search marks the page so the stood-down tile can come back", async () => {
  const app = await closedOn(["A.gba", "B.gba"]);
  assert.ok(!body(app).contains("lib-filtering"));
  app.runIn(`libFilter.q = "a"; applyLibFilter()`);
  assert.ok(body(app).contains("lib-filtering"));
  app.runIn(`libFilter.q = ""; applyLibFilter()`);
  assert.ok(!body(app).contains("lib-filtering"));
});
