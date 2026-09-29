// A fresh visit opens on the brand with the whole library under it; the
// hero appears only once a game has been played in this visit.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle, u8, gameTiles } from "./helpers.mjs";

const drain = async (n = 12) => { for (let i = 0; i < n; i++) await settle(); };
const seed = (app, names) => {
  app.idb.set("recent", names.map((name, i) => ({ name, ts: names.length - i })));
  for (const name of names) app.idb.set("rom:" + name, { name, data: u8(1) });
};

test("a fresh load: no hero, every game a tile, the brand crossing over on the scroll", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"]);
  await app.api.refreshHomeRecent();
  await drain();
  assert.equal(app.document.getElementById("hero").hidden, true);
  assert.ok(!app.document.body.classList.contains("home-card"));
  assert.deepEqual(gameTiles(app).filter((t) => t.classList.contains("is-current")), [], "nothing stands down");
  assert.equal(app.document.getElementById("home-inner").dataset.n, "2");
});

test("once a game has been played this visit, the hero is back", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"]);
  app.runIn("playedThisVisit = true");
  await app.api.refreshHomeRecent();
  await drain();
  assert.equal(app.document.getElementById("hero").hidden, false);
  assert.equal(app.document.getElementById("hero").dataset.mode, "closed");
});
