// The per-game menu on a library tile (index.js "Per-game menu"): which
// items appear for which game, why an item is disabled, arm-to-confirm,
// and the actions behind them. Pins the rule that an item never applicable
// to a game is absent, while one that cannot apply right now is present
// but disabled with its reason.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle } from "./helpers.mjs";

const signIn = (app, sigs = {}, rmt = {}) => {
  app.api.gdriveToken = "test-token";
  app.api.gdriveTokenExp = Date.now() + 3600e3;
  app.api.syncState =
    { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], sigs, rmt, connected: true };
};

// Enrolled but not signed in: the account is known, and so is what its Drive
// holds; there is no token this minute.
const signedOutEnrolled = (app, sigs = {}) => {
  app.api.syncState =
    { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], sigs, rmt: {},
      connected: false, acct: "acct-1" };
};

const seed = (app, names, { local = names, saves = [] } = {}) => {
  app.idb.set("recent", names.map((name, i) => ({ name, ts: 100 - i })));
  for (const n of local) app.idb.set("rom:" + n, { name: n, data: u8(1, 2, 3, 4) });
  for (const n of saves) app.idb.set("save:" + n, u8(7));
  app.idb.set("thumbs_offered", 1);
};

const tiles = (app) => app.document.getElementById("home-recent").children;
const tileOf = (app, name) =>
  tiles(app).find((t) => t.children[0].title.startsWith(name));
const moreBtn = (tile) => tile.children.find((c) => c.classList.contains("home-tile-more"));
const menu = (app) => app.document.getElementById("tile-menu");
const items = (app) => app.document.getElementById("tile-menu-items").children;
// [label, sub or reason, disabled?]
const rows = (app) => items(app).map((b) => [
  b.children[0].textContent,
  b.children[1].hidden ? "" : b.children[1].textContent,
  b.disabled,
]);
const labels = (app) => rows(app).map((r) => r[0]);
const item = (app, label) => items(app).find((b) => b.children[0].textContent === label);
const status = (app) =>
  app.document.getElementById("tile-menu-head").children[1].children[1].textContent;

const open = async (app, name) => {
  const tile = tileOf(app, name);
  await moreBtn(tile).click();
  await settle();
  return tile;
};

const boot = async (app) => {
  await app.api.refreshHomeRecent();
  await settle();
};

// ── Which items, for which game ─────────────────────────────────────────────
// Every listed item says what it does in its own label. Only a blocked item
// carries a line, and only to say why.

test("every tile carries the ⋯ glyph; the download glyph moved to the left corner", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"], { local: ["A.gba"] });
  signIn(app, { "rom:B.gba": "sig" });
  await boot(app);
  for (const t of tiles(app)) {
    const more = moreBtn(t);
    assert.ok(more, "a ⋯ on " + t.children[0].title);
    assert.equal(more.attributes["aria-haspopup"], "menu");
  }
  assert.ok(tileOf(app, "B.gba").children.some((c) => c.classList.contains("home-tile-dl")),
            "the Drive-only tile keeps its download glyph");
  assert.ok(!tileOf(app, "A.gba").children.some((c) => c.classList.contains("home-tile-dl")));
});

test("never signed in: Rename, Reset, Delete — and nothing that needs explaining", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc"]);
  await boot(app);
  const tile = await open(app, "Zelda.gbc");
  assert.equal(menu(app).hidden, false);
  assert.equal(app.api.tileMenuFor, "Zelda.gbc");
  assert.ok(tile.classList.contains("menu-open"));
  eq(rows(app), [
    ["Rename", "", false],
    ["Reset save data", "No save data yet", true],
    ["Delete", "", false],
  ]);
  assert.equal(status(app), "GBC · 4 B", "the system, and what it costs");
});

test("a local game with a save: Reset is live, and still says nothing", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc"], { saves: ["Zelda.gbc"] });
  await boot(app);
  await open(app, "Zelda.gbc");
  eq(rows(app)[1], ["Reset save data", "", false]);
});

test("signed in and backed up to Drive: Remove joins, no descriptions anywhere", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc"], { saves: ["Zelda.gbc"] });
  signIn(app, { "rom:Zelda.gbc": "sig" });
  await boot(app);
  await open(app, "Zelda.gbc");
  eq(rows(app), [
    ["Rename", "", false],
    ["Reset save data", "", false],
    ["Remove from this device", "", false],
    ["Delete", "", false],
  ]);
  assert.equal(status(app), "GBC · 4 B", "where it lives is left to the items");
});

test("signed in but the ROM is not on Drive yet: Remove is blocked, and says why", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc"]);
  signIn(app); // no sig for the ROM
  await boot(app);
  await open(app, "Zelda.gbc");
  eq(rows(app)[2], ["Remove from this device", "Not backed up to Drive yet — this is your only copy", true]);
});

test("a ROM this device never uploaded, but a pull saw on Drive, can be removed", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc"]);
  signIn(app);
  app.api.syncState.rmt["rom:Zelda.gbc"] = "2026-01-01T00:00:00Z"; // what a pull records
  await boot(app);
  await open(app, "Zelda.gbc");
  eq(rows(app)[2], ["Remove from this device", "", false]);
});

test("a delete queued for the ROM also counts as not on Drive", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc"]);
  signIn(app, { "rom:Zelda.gbc": "sig" });
  app.api.syncState.queueDel.push("rom:Zelda.gbc");
  await boot(app);
  await open(app, "Zelda.gbc");
  assert.equal(item(app, "Remove from this device").disabled, true);
});

test("the paused game: Remove and Delete close it themselves, and the question says so", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc"]);
  signIn(app, { "rom:Zelda.gbc": "sig" });
  app.api.currentOriginalName = "Zelda.gbc";
  await boot(app);
  await open(app, "Zelda.gbc");
  eq(rows(app)[2], ["Remove from this device", "", false], "no longer blocked");
  const rm = item(app, "Remove from this device");
  await rm.click(); // arm only
  assert.equal(rm.children[0].textContent, "Close and remove?");
  app.api.closeTileMenu();
  await open(app, "Zelda.gbc");
  const del = item(app, "Delete");
  await del.click();
  assert.equal(del.children[0].textContent, "Close and delete everything?");
  app.api.closeTileMenu();
  app.api.currentOriginalName = null;
});

test("an online session holds every item, naming the session", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc"], { saves: ["Zelda.gbc"] });
  signIn(app, { "rom:Zelda.gbc": "sig" });
  app.api.currentOriginalName = "Zelda.gbc";
  app.api.rollbackMode = true; // an internet link, not the ?2p debug rig
  await boot(app);
  await open(app, "Zelda.gbc");
  eq(rows(app), [
    ["Rename", "Exit the online session first", true],
    ["Reset save data", "Exit the online session first", true],
    ["Remove from this device", "Exit the online session first", true],
    ["Delete", "Exit the online session first", true],
  ]);
  app.api.rollbackMode = false;
  app.api.currentOriginalName = null;
});

test("the same-browser 2P rig holds them too", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc"], { saves: ["Zelda.gbc"] });
  signIn(app, { "rom:Zelda.gbc": "sig" });
  app.api.linkMode = true;
  app.api.linkRomEntry = { name: "Zelda.gbc" };
  await boot(app);
  await open(app, "Zelda.gbc");
  eq(rows(app).map((r) => r[2]), [true, true, true, true]);
  app.api.linkMode = false;
  app.api.linkRomEntry = null;
});

test("a Drive-only game, signed in: Download leads; Remove is absent", async () => {
  const app = await loadApp();
  seed(app, ["Cloud.gba"], { local: [] });
  signIn(app, { "rom:Cloud.gba": "sig" });
  await boot(app);
  await open(app, "Cloud.gba");
  eq(rows(app), [
    ["Download to this device", "", false],
    ["Rename", "", false],
    ["Reset save data", "No save data yet", true],
    ["Delete", "", false],
  ]);
  assert.equal(status(app), "GBA", "no size: the bytes have never been here");
});

test("a game freed from this device keeps saying the save stayed", async () => {
  const app = await loadApp();
  seed(app, ["Cloud.gba"], { local: [], saves: ["Cloud.gba"] });
  signIn(app, { "rom:Cloud.gba": "sig" });
  await boot(app);
  await open(app, "Cloud.gba");
  assert.equal(status(app), "GBA · your save is still on this device");
  eq(rows(app)[2], ["Reset save data", "", false], "and that save is what Reset wipes");
});

test("saves that live only on Drive are not claimed to be on this device", async () => {
  const app = await loadApp();
  seed(app, ["Cloud.gba"], { local: [] });
  signIn(app, { "rom:Cloud.gba": "sig" }, { "save:Cloud.gba": "sig" });
  await boot(app);
  await open(app, "Cloud.gba");
  assert.equal(status(app), "GBA");
  assert.equal(item(app, "Reset save data").disabled, false, "but there is still a save to reset");
});

test("a Drive-only game while it downloads: Download is blocked with 'Downloading…'", async () => {
  const app = await loadApp();
  seed(app, ["Cloud.gba"], { local: [] });
  signIn(app, { "rom:Cloud.gba": "sig" });
  app.api.syncDownloading.add("Cloud.gba");
  await boot(app);
  await open(app, "Cloud.gba");
  eq(rows(app)[0], ["Download to this device", "Downloading…", true]);
  app.api.syncDownloading.delete("Cloud.gba");
});

test("a Drive-only game, signed out: Download is offered and signs in when tapped", async () => {
  const app = await loadApp();
  seed(app, ["Cloud.gba"], { local: [] });
  signedOutEnrolled(app, { "rom:Cloud.gba": "sig" });
  await boot(app);
  await open(app, "Cloud.gba");
  eq(labels(app), ["Download to this device", "Rename", "Reset save data", "Delete"]);
  eq(rows(app)[0], ["Download to this device", "", false]);
});

test("the size is read from the ROM once, then remembered", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc"]);
  await boot(app);
  await open(app, "Zelda.gbc");
  assert.equal(status(app), "GBC · 4 B");
  eq(app.idb.get("romsizes"), { "Zelda.gbc": 4 }, "noted for next time");
});

test("a game that leaves the library takes its size note with it", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"]);
  await boot(app);
  await open(app, "A.gba");
  await open(app, "B.gba");
  app.api.closeTileMenu();
  eq(Object.keys(app.idb.get("romsizes")).sort(), ["A.gba", "B.gba"]);

  app.idb.set("recent", [{ name: "B.gba", ts: 1 }]);
  await boot(app);
  eq(Object.keys(app.idb.get("romsizes")), ["B.gba"]);
});

test("the flags agree with the tile's own inventory reading", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"], { local: ["A.gba"], saves: ["A.gba"] });
  signIn(app, { "rom:A.gba": "s" });
  const f = app.api.gameFlags("A.gba", new Set(["A.gba"]), new Set(["A.gba"]));
  eq({ ...f }, { linked: true, driveOnly: false, missing: false, hasSaves: true,
                 hasLocalSaves: true, romOnDrive: true, loaded: false, busy: false,
                 downloading: false });
  // B is in the library, held nowhere: not on this device, and no sig or
  // listing entry saying Drive has it either.
  const g = app.api.gameFlags("B.gba", new Set(["A.gba"]), new Set(["A.gba"]));
  eq({ ...g }, { linked: true, driveOnly: true, missing: true, hasSaves: false,
                 hasLocalSaves: false, romOnDrive: false, loaded: false, busy: false,
                 downloading: false });
});

test("a game whose file is nowhere: Find the file leads, and the status says why", async () => {
  const app = await loadApp();
  seed(app, ["Lost.gba"], { local: [], saves: ["Lost.gba"] });
  await boot(app);
  await open(app, "Lost.gba");
  eq(labels(app), ["Find the file…", "Rename", "Reset save data", "Delete"]);
  assert.match(status(app), /the file is not here, but your save is/);
  // Neither location chip claims it, so neither filter shows it.
  assert.equal(tileOf(app, "Lost.gba").dataset.loc, "missing");
});

// ── Opening, closing, the shortcuts ─────────────────────────────────────────

test("the glyph toggles; opening another tile's menu moves it; Escape and the scrim close it", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"]);
  await boot(app);
  const a = await open(app, "A.gba");
  assert.equal(app.api.tileMenuFor, "A.gba");
  await moreBtn(a).click();
  await settle();
  assert.equal(menu(app).hidden, true, "the same glyph again closes");
  assert.equal(app.api.tileMenuFor, null);
  assert.ok(!a.classList.contains("menu-open"));

  await open(app, "A.gba");
  const b = await open(app, "B.gba");
  assert.equal(app.api.tileMenuFor, "B.gba");
  assert.ok(!a.classList.contains("menu-open"));
  assert.ok(b.classList.contains("menu-open"));

  await app.dispatchDoc("keydown", { key: "Escape" });
  await settle();
  assert.equal(menu(app).hidden, true);

  await open(app, "A.gba");
  await app.document.getElementById("tile-menu-scrim").click();
  assert.equal(menu(app).hidden, true);
});

test("right-click on a tile opens its menu and suppresses the browser's", async () => {
  const app = await loadApp();
  seed(app, ["A.gba"]);
  await boot(app);
  let prevented = false;
  await tileOf(app, "A.gba").dispatch("contextmenu",
    { clientX: 100, clientY: 100, preventDefault: () => { prevented = true; } });
  await settle();
  assert.ok(prevented);
  assert.equal(app.api.tileMenuFor, "A.gba");
});

test("a long press opens the menu, and the tap that ends it does not launch the game", async () => {
  const app = await loadApp();
  seed(app, ["A.gba"]);
  // A launch touches the recents index before it reaches the core; that
  // bump is the signal. The core itself is a stub.
  app.runIn(`globalThis.Module = { ccall: () => {}, _loop_tick: () => {}, _clearAudioBuffer: () => {},
    _wasm_fb_ptr: () => 16, _malloc: () => 8, _free: () => {},
    memory: { buffer: new ArrayBuffer(16 + 240 * 160 * 4) } };`);
  await boot(app);
  const launch = tileOf(app, "A.gba").children[0];
  const ts = () => app.idb.get("recent")[0].ts;
  await launch.dispatch("pointerdown", { pointerType: "touch", clientX: 10, clientY: 10 });
  await new Promise((r) => setTimeout(r, app.api.LONG_PRESS_MS + 60));
  await settle();
  assert.equal(app.api.tileMenuFor, "A.gba", "opened by the press");
  await launch.dispatch("pointerup", { pointerType: "touch" });
  await launch.click();
  await settle();
  assert.equal(ts(), 100, "that click was the press's");
  app.api.closeTileMenu();
  try { await launch.click(); } catch {} // the stub core may balk past the bump
  await settle();
  assert.ok(ts() > 100, "the next tap plays as usual");
});

test("a press that moves (a scroll) or lifts early opens nothing; a mouse press never does", async () => {
  const app = await loadApp();
  seed(app, ["A.gba"]);
  await boot(app);
  const launch = tileOf(app, "A.gba").children[0];
  await launch.dispatch("pointerdown", { pointerType: "touch", clientX: 10, clientY: 10 });
  await launch.dispatch("pointermove", { pointerType: "touch", clientX: 10, clientY: 40 });
  await new Promise((r) => setTimeout(r, app.api.LONG_PRESS_MS + 60));
  assert.equal(app.api.tileMenuFor, null, "moved: a scroll");

  await launch.dispatch("pointerdown", { pointerType: "touch", clientX: 10, clientY: 10 });
  await launch.dispatch("pointerup", { pointerType: "touch" });
  await new Promise((r) => setTimeout(r, app.api.LONG_PRESS_MS + 60));
  assert.equal(app.api.tileMenuFor, null, "lifted early: a tap");

  await launch.dispatch("pointerdown", { pointerType: "mouse", clientX: 10, clientY: 10 });
  await new Promise((r) => setTimeout(r, app.api.LONG_PRESS_MS + 60));
  assert.equal(app.api.tileMenuFor, null, "a mouse has right-click");
});

test("the menu closes when its game leaves the library under it", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"]);
  await boot(app);
  await open(app, "A.gba");
  app.idb.set("recent", [{ name: "B.gba", ts: 1 }]);
  await boot(app);
  assert.equal(menu(app).hidden, true);
  assert.equal(app.api.tileMenuFor, null);
});

test("a re-render keeps the open state on the game's new tile", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"]);
  await boot(app);
  await open(app, "A.gba");
  await boot(app);
  assert.equal(app.api.tileMenuFor, "A.gba");
  assert.ok(tileOf(app, "A.gba").classList.contains("menu-open"));
});

// ── The actions ─────────────────────────────────────────────────────────────

test("Delete arms, then deletes: ROM, saves and the tile go; the menu closes", async () => {
  const app = await loadApp();
  seed(app, ["A.gba", "B.gba"], { saves: ["A.gba"] });
  await boot(app);
  await open(app, "A.gba");
  const del = item(app, "Delete");
  await del.click();
  assert.ok(del.classList.contains("armed"));
  assert.equal(del.children[0].textContent, "Delete ROM and save data?");
  assert.equal(del.children[1].textContent, "Tap again to confirm");
  assert.equal(menu(app).hidden, false, "arming does not close");
  await del.click();
  await settle();
  assert.equal(menu(app).hidden, true);
  assert.equal(app.idb.get("rom:A.gba"), undefined);
  assert.equal(app.idb.get("save:A.gba"), undefined);
  eq(app.idb.get("recent").map((r) => r.name), ["B.gba"]);
  eq(tiles(app).map((t) => t.children[0].title), ["B.gba"]);
  eq(app.toasts.slice(-1), ["Removed from this browser"]);
});

test("arming one item disarms another; the arm times out on its own", async () => {
  const app = await loadApp();
  seed(app, ["A.gba"], { saves: ["A.gba"] });
  await boot(app);
  await open(app, "A.gba");
  const reset = item(app, "Reset save data"), del = item(app, "Delete");
  await reset.click();
  assert.ok(reset.classList.contains("armed"));
  await del.click();
  assert.ok(del.classList.contains("armed"));
  assert.ok(!reset.classList.contains("armed"), "the sibling disarmed");
  assert.equal(reset.children[0].textContent, "Reset save data");
  assert.equal(app.idb.get("save:A.gba") !== undefined, true, "nothing ran");
  app.api.closeTileMenu();
});

test("Reset save data wipes the saves and keeps the ROM and the tile", async () => {
  const app = await loadApp();
  seed(app, ["A.gba"], { saves: ["A.gba"] });
  app.idb.set("state:A.gba", u8(6));
  await boot(app);
  await open(app, "A.gba");
  const reset = item(app, "Reset save data");
  await reset.click();
  await reset.click();
  await settle();
  assert.equal(app.idb.get("save:A.gba"), undefined);
  assert.equal(app.idb.get("state:A.gba"), undefined);
  assert.ok(app.idb.get("rom:A.gba"));
  eq(app.toasts.slice(-1), ["Save data deleted"]);
  await boot(app);
  await open(app, "A.gba");
  eq(rows(app)[1], ["Reset save data", "No save data yet", true]);
});

test("Rename opens the rename box for that game", async () => {
  const app = await loadApp();
  seed(app, ["A.gba"]);
  await boot(app);
  await open(app, "A.gba");
  await item(app, "Rename").click();
  await settle();
  assert.equal(menu(app).hidden, true);
  const hasText = (el, t) => el.textContent === t || (el.children || []).some((c) => hasText(c, t));
  assert.ok(hasText(app.document.body, "Rename game"), "the rename box is up");
});

test("Remove from this device frees the ROM bytes, keeps the save, and the tile turns Drive-only", async () => {
  const app = await loadApp();
  seed(app, ["A.gba"], { saves: ["A.gba"] });
  signIn(app, { "rom:A.gba": "sig" });
  // removeGameFromDevice re-checks Drive's live listing.
  app.setFetch(async (url) => {
    url = String(url);
    if (url.includes("spaces=appDataFolder")) {
      return new Response(JSON.stringify({ files: [{ id: "f1", name: "rom:A.gba", size: "4",
        modifiedTime: "2026-01-01T00:00:00Z" }] }), { status: 200 });
    }
    return new Response("{}", { status: 200 });
  });
  await boot(app);
  await open(app, "A.gba");
  const rm = item(app, "Remove from this device");
  await rm.click();
  await rm.click();
  await settle();
  assert.equal(app.idb.get("rom:A.gba"), undefined);
  assert.ok(app.idb.get("save:A.gba"), "the save stays");
  assert.ok(tileOf(app, "A.gba").classList.contains("home-tile-cloud"));
  eq(app.toasts.slice(-1), ["ROM removed from this device — save kept, still on Drive"]);
});

test("Download to this device fetches the ROM, and the tile turns local", async () => {
  const app = await loadApp();
  seed(app, ["A.gba"], { local: [] });
  signIn(app, { "rom:A.gba": "sig" });
  app.setFetch(async (url) => {
    url = String(url);
    if (url.includes("spaces=appDataFolder")) {
      return new Response(JSON.stringify({ files: [{ id: "f1", name: "rom:A.gba", size: "3",
        modifiedTime: "2026-01-01T00:00:00Z" }] }), { status: 200 });
    }
    if (url.includes("alt=media")) return new Response(u8(65, 66, 67), { status: 200 });
    return new Response("{}", { status: 200 });
  });
  await boot(app);
  await open(app, "A.gba");
  await item(app, "Download to this device").click();
  await settle();
  await settle();
  assert.equal(menu(app).hidden, true);
  eq(app.idb.get("rom:A.gba")?.data, u8(65, 66, 67));
  assert.ok(!tileOf(app, "A.gba").classList.contains("home-tile-cloud"));
  eq(app.toasts.slice(-1), ["Synced to this device"]);
});
