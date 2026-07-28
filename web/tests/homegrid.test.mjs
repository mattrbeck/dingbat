// Home recents grid rendering (web/index.js refreshHomeRecent), via the vm
// harness. The first-sign-in flow fires refreshHomeRecent several times
// back-to-back (library merge, per-game downloads); overlapping calls must
// not each append a full tile set — that doubled every game in the grid.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, bytesRes, u8, settle } from "./helpers.mjs";

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

// --- Scroll preservation ----------------------------------------------------
// #home is the scroll container. A render that empties the grid first collapses
// its scrollHeight to the viewport, and the browser clamps scrollTop to 0 — the
// tiles arriving a tick later don't bring the offset back. So the grid must go
// from the old tiles to the new ones in ONE atomic swap, never through an empty
// state. There's no layout in the vm harness, so the test asserts the invariant
// that causes the jump: the number of children never dips.

// Records the grid's child count after every mutation the app makes.
const watchGrid = (app) => {
  const grid = app.document.getElementById("home-recent");
  const sizes = [];
  const proto = Object.getPrototypeOf(grid);
  for (const m of ["appendChild", "replaceChildren", "removeChild"]) {
    grid[m] = (...args) => {
      const r = proto[m].apply(grid, args);
      sizes.push(grid.children.length);
      return r;
    };
  }
  Object.defineProperty(grid, "innerHTML", {
    set(v) { proto.__lookupSetter__("innerHTML").call(grid, v); sizes.push(grid.children.length); },
    get() { return proto.__lookupGetter__("innerHTML").call(grid); },
  });
  return sizes;
};

// Serves just enough Drive for downloadGame: the file list and one alt=media
// fetch per file.
const driveWith = (names) => async (url) => {
  url = String(url);
  if (url.includes("spaces=appDataFolder")) {
    return jsonRes({ files: names.map((n, i) => ({
      id: "f" + i, name: n, size: "3", modifiedTime: "2026-01-01T00:00:00Z",
    })) });
  }
  if (url.includes("alt=media")) return bytesRes(u8(65, 66, 67));
  return jsonRes({});
};

test("downloading a Drive-only game never empties the grid", async () => {
  const app = await loadApp();
  signIn(app);
  app.idb.set("recent", [
    { name: "A.gba", ts: 3 },
    { name: "B.gba", ts: 2 },
    { name: "C.gba", ts: 1 },
  ]);
  app.setFetch(driveWith(["rom:A.gba", "rom:B.gba", "rom:C.gba"]));
  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(tileCount(app), 3);

  const sizes = watchGrid(app);
  await app.api.downloadGame("B.gba"); // fires a busy render and a done render
  await settle();

  assert.ok(sizes.length > 0, "the download did re-render the grid");
  assert.ok(!sizes.includes(0),
    "the grid must never be emptied mid-render — that clamps #home's scrollTop " +
    "to 0 and throws the user back to the top of their library (saw " +
    JSON.stringify(sizes) + ")");
  assert.equal(tileCount(app), 3, "and the grid still holds every game");
});

test("bulk downloads keep the grid whole through every render", async () => {
  const app = await loadApp();
  signIn(app);
  const games = ["A.gba", "B.gba", "C.gba", "D.gba", "E.gba"];
  app.idb.set("recent", games.map((name, i) => ({ name, ts: 10 - i })));
  app.setFetch(driveWith(games.map((g) => "rom:" + g)));
  await app.api.refreshHomeRecent();
  await settle();

  const sizes = watchGrid(app);
  // Overlapping downloads, the way tapping several glyphs in a row behaves.
  await Promise.all(games.map((g) => app.api.downloadGame(g)));
  await settle();

  assert.ok(!sizes.includes(0),
    "concurrent downloads must not empty the grid either (saw " +
    JSON.stringify(sizes) + ")");
  assert.equal(tileCount(app), games.length);
});
