// Home recents grid rendering (web/index.js refreshHomeRecent), via the vm
// harness. The first-sign-in flow fires refreshHomeRecent several times
// back-to-back (library merge, per-game downloads); overlapping calls must
// not each append a full tile set — that doubled every game in the grid.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle } from "./helpers.mjs";

const signIn = (app) => {
  app.api.gdriveToken = "test-token";
  app.api.syncState = { queueUp: [], queueDel: [], tomb: [], sigs: {}, rmt: {}, connected: true };
};

const tileCount = (app) =>
  app.document.getElementById("home-recent").children.length;

test("overlapping refreshHomeRecent calls render the grid once", async () => {
  const app = await loadApp();
  signIn(app); // signed-in path has the extra dbKeys() await that interleaves
  app.idb.set("recent", [
    { name: "A.gba", ts: 2 },
    { name: "B.gba", ts: 1 },
  ]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: new Uint8Array([1]) });

  // Fire two renders without awaiting the first — the second starts (and
  // clears the grid) while the first is parked on its dbKeys() await.
  const p1 = app.api.refreshHomeRecent();
  const p2 = app.api.refreshHomeRecent();
  await p1; await p2; await settle();

  assert.equal(tileCount(app), 2,
    "two games must render exactly two tiles, not one per concurrent call");
});

test("sequential refreshHomeRecent still renders every game", async () => {
  const app = await loadApp();
  signIn(app);
  app.idb.set("recent", [
    { name: "A.gba", ts: 3 },
    { name: "B.gba", ts: 2 },
    { name: "C.gba", ts: 1 },
  ]);
  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(tileCount(app), 3);
});
