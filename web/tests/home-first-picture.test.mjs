// The home screen's first picture is the real one. The library comes out of
// IndexedDB after the page paints; where the last visit had games (a hint in
// localStorage, read by index.html's head into html.home-pending), the home's
// content is held until the first render has its top game, then shown once.
// With no hint the empty state is not held at all.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
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

test("held: the page has the library's side at once, and what goes under the brand waits", async () => {
  const app = await loadApp({ htmlClasses: ["home-pending"], localStorageSeed: { dingbat_library: "games" } });
  assert.ok(pending(app), "held from the start");
  assert.ok(app.document.body.classList.contains("lib-has-games"), "no empty state underneath");
  seed(app, ["A.gba", "B.gba"]);
  await app.api.refreshHomeRecent();
  await drain();
  assert.ok(!pending(app), "shown once the first render is done");
  assert.equal(app.document.getElementById("hero").hidden, false, "a fresh visit: the last game played heads the page");
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

// --- The height the home screen holds while it reads ------------------------
// index.html's head reserves the last first picture's height (at the same
// width), so the brand does not start centred alone and then jump up.

test("the first picture notes its height at this width; an empty library does not", async () => {
  const app = await loadApp({ htmlClasses: ["home-pending"], localStorageSeed: { dingbat_library: "games" } });
  app.document.getElementById("home-inner").offsetHeight = 612.4;
  seed(app, ["A.gba"]);
  await app.api.refreshHomeRecent();
  await drain();
  assert.deepEqual(JSON.parse(app.lsMap.get("dingbat_home_h")),
                   { w: app.runIn("window.innerWidth"), px: 612 });

  // A library taller than the screen is held at the screen's height.
  const tall = await loadApp({ htmlClasses: ["home-pending"], localStorageSeed: { dingbat_library: "games" } });
  tall.document.getElementById("home-inner").offsetHeight = 2400;
  tall.document.getElementById("home").clientHeight = 760;
  seed(tall, ["A.gba"]);
  await tall.api.refreshHomeRecent();
  await drain();
  assert.equal(JSON.parse(tall.lsMap.get("dingbat_home_h")).px, 760);

  const empty = await loadApp({ htmlClasses: ["home-pending"], localStorageSeed: { dingbat_library: "games" } });
  empty.document.getElementById("home-inner").offsetHeight = 300;
  await empty.api.refreshHomeRecent();
  await drain();
  assert.equal(empty.lsMap.get("dingbat_home_h"), undefined);
});

const HEAD_SCRIPT = [...readFileSync(new URL("../index.html", import.meta.url), "utf8")
  .matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]).find((s) => s.includes("dingbat_home_h"));

const runHead = (store, innerWidth) => {
  const classes = new Set();
  const props = {};
  vm.runInNewContext(HEAD_SCRIPT, {
    localStorage: { getItem: (k) => store[k] ?? null },
    window: { innerWidth }, JSON,
    document: { documentElement: { classList: { add: (c) => classes.add(c) },
                                   style: { setProperty: (k, v) => { props[k] = v; } } } },
  });
  return { pending: classes.has("home-pending"), h: props["--home-pending-h"] };
};

test("index.html's head holds the noted height only at the same width", () => {
  const store = { dingbat_library: "games", dingbat_home_h: JSON.stringify({ w: 390, px: 612 }) };
  assert.deepEqual(runHead(store, 390), { pending: true, h: "612px" });
  assert.deepEqual(runHead(store, 844), { pending: true, h: undefined }, "turned: other columns");
  assert.deepEqual(runHead({ ...store, dingbat_library: "empty" }, 390), { pending: false, h: undefined });
  assert.deepEqual(runHead({ dingbat_library: "games", dingbat_home_h: "junk" }, 390),
                   { pending: true, h: undefined });
});
