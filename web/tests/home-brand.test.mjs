// A fresh visit with games opens on the last one played (the closed hero),
// the library under it; the big brand is the empty library's.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle, u8, gameTiles } from "./helpers.mjs";

const drain = async (n = 12) => { for (let i = 0; i < n; i++) await settle(); };
const seed = (app, names) => {
  app.idb.set("recent", names.map((name, i) => ({ name, ts: names.length - i })));
  for (const name of names) app.idb.set("rom:" + name, { name, data: u8(1) });
};

test("a fresh load opens on the last game played: the hero, closed, its tile standing down", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"]);
  await app.api.refreshHomeRecent();
  await drain();
  assert.equal(app.document.getElementById("hero").hidden, false);
  assert.equal(app.document.getElementById("hero").dataset.mode, "closed");
  assert.ok(app.document.body.classList.contains("home-card"));
  assert.deepEqual(gameTiles(app).filter((t) => t.classList.contains("is-current"))
    .map((t) => t.dataset.rom), ["A.gba"]);
  assert.equal(app.document.getElementById("home-inner").dataset.n, "1");
});
