// The home screen's first picture is the real one. The library comes out of
// IndexedDB after the page paints; where the last visit had games (a hint in
// localStorage, read by index.html's head into html.home-pending), the home's
// content is held until the first render has its top game, then shown once.
// With no hint the empty state is not held at all.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle, u8 } from "./helpers.mjs";

const drain = async (n = 12) => { for (let i = 0; i < n; i++) await settle(); };
const pending = (app) => app.document.documentElement.classList.contains("home-pending");
const seed = (app, names) => {
  app.idb.set("recent", names.map((name, i) => ({ name, ts: names.length - i })));
  for (const name of names) app.idb.set("rom:" + name, { name, data: u8(1) });
};

test("a library render writes the hint; an empty one takes it back", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"]);
  await app.api.refreshHomeRecent();
  await drain();
  assert.equal(app.lsMap.get("dingbat_library"), "games");
  app.idb.set("recent", []);
  await app.api.refreshHomeRecent();
  await drain();
  assert.equal(app.lsMap.get("dingbat_library"), "empty");
});

test("held: the bar has the library's side at once, the content waits for the top game", async () => {
  const app = await loadApp({ htmlClasses: ["home-pending"], localStorageSeed: { dingbat_library: "games" } });
  assert.ok(pending(app), "held from the start");
  assert.ok(app.document.body.classList.contains("lib-has-games"), "no empty state underneath");
  seed(app, ["A.gba", "B.gba"]);
  await app.api.refreshHomeRecent();
  await drain();
  assert.ok(!pending(app), "shown once the first render is done");
  assert.equal(app.document.getElementById("hero").hidden, false, "with its top game");
});

test("held, but the library turned out empty: the empty state shows at once", async () => {
  const app = await loadApp({ htmlClasses: ["home-pending"], localStorageSeed: { dingbat_library: "games" } });
  await app.api.refreshHomeRecent();
  await drain();
  assert.ok(!pending(app));
  assert.ok(!app.document.body.classList.contains("lib-has-games"));
  assert.equal(app.lsMap.get("dingbat_library"), "empty");
});

test("no hint: nothing is held", async () => {
  const app = await loadApp();
  assert.ok(!pending(app));
  assert.ok(!app.document.body.classList.contains("lib-has-games"), "the empty state, as early as ever");
});

// The sync UI refreshes at boot, before the library is read. It must not
// decide the library either way: it once marked an empty one as having
// games, and the empty state blinked out.
test("before the library is read, a sync refresh decides nothing", async () => {
  const app = await loadApp();
  app.runIn("refreshSyncUI()");
  assert.ok(!app.document.body.classList.contains("lib-has-games"), "the empty state stays");
  assert.equal(app.lsMap.get("dingbat_library"), undefined, "and no hint is written");
});
