// The per-game menu on a library tile (index.js "Per-game menu"): which
// items appear for which game, why an item is disabled, arm-to-confirm,
// and the actions behind them. Pins the rule that an item never applicable
// to a game is absent, while one that cannot apply right now is present
// but disabled with its reason.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, gameTiles } from "./helpers.mjs";

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

const tiles = (app) => gameTiles(app);
const tileOf = (app, name) =>
  tiles(app).find((t) => t.children[0].title.startsWith(name));
const moreBtn = (tile) => tile.children.find((c) => c.classList.contains("home-tile-more"));
const menu = (app) => app.document.getElementById("tile-menu");
const items = (app) => app.document.getElementById("tile-menu-items").children;
// The session items carry a glyph in front of the label, so a row's children
// are not [label, sub] at fixed indexes any more. By class, then.
const kid = (b, cls) => b.children.find((c) => c.classList.contains(cls));
const labelOf = (b) => kid(b, "tile-menu-label").textContent;
const subOf = (b) => kid(b, "tile-menu-sub");
// [label, sub or reason, disabled?]
const rows = (app) => items(app).map((b) => [
  labelOf(b), subOf(b).hidden ? "" : subOf(b).textContent, b.disabled,
]);
const labels = (app) => rows(app).map((r) => r[0]);
const item = (app, label) => items(app).find((b) => labelOf(b) === label);
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
  assert.equal(labelOf(rm), "Close and remove?");
  app.api.closeTileMenu();
  await open(app, "Zelda.gbc");
  const del = item(app, "Delete");
  await del.click();
  assert.equal(labelOf(del), "Close and delete everything?");
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
  assert.equal(labelOf(del), "Delete ROM and save data?");
  assert.equal(subOf(del).textContent, "Tap again to confirm");
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
  assert.equal(labelOf(reset), "Reset save data");
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


// ── The paused card's ⋯ is this same menu ───────────────────────────────────
// One menu per game, opened from two places. The card's entry point adds the
// session section on top; the grid's tiles never do, so the library menu is
// exactly what it always was.

test("the card's ⋯ is the session's; a tile's is the file's; neither is both", async () => {
  const app = await loadApp();
  seed(app, ["Zelda.gbc"], { saves: ["Zelda.gbc"] });
  await boot(app);

  await app.api.openTileMenu("Zelda.gbc", app.document.createElement("button"),
                             null, null, true);
  await settle();
  eq(labels(app),
     ["Save states", "Manage saves", "Link cable", "Cheats", "Report a bug"],
     "what you do to the game you are in the middle of");
  // Screenshot and Clip that! are about the frame going past, and the
  // frame here is the card's own picture of a game that stopped.
  for (const gone of ["Screenshot", "Clip that!"]) {
    assert.ok(!labels(app).includes(gone), gone + " is a running-game action");
  }
  assert.equal(app.document.getElementById("tile-menu-head").hidden, true,
               "the card said which game, an inch above");
  assert.ok(items(app).every((b) => kid(b, "tile-menu-icon")),
            "every session item wears the glyph the hamburger gives it");
  app.api.closeTileMenu();

  await open(app, "Zelda.gbc");
  eq(labels(app), ["Rename", "Reset save data", "Delete"],
     "what you do to its file, and nothing about the session");
  assert.ok(items(app).every((b) => !kid(b, "tile-menu-icon")),
            "the file items have never had a glyph anywhere");
  assert.equal(app.document.getElementById("tile-menu-head").hidden, false,
               "a tile in a grid of them still has to name its game");
  app.api.closeTileMenu();
});

// The bug this pins: the library keys a game by the name it was added under
// (currentOriginalName), while currentRomName is the emulator filesystem's
// sanitised one. Open the menu under the wrong key and every flag reads
// false - the menu decides the file is missing and offers to go and find a
// file the player is, demonstrably, playing.
test("the card's ⋯ finds the loaded game under the library's own key", async () => {
  const app = await loadApp();
  seed(app, ["Zelda (U) [!].gbc"]);
  await boot(app);
  app.api.currentRomName = "zelda_u.gbc";          // the FS name
  app.api.currentOriginalName = "Zelda (U) [!].gbc"; // the library key
  await app.document.getElementById("home-paused-more").click();
  await settle();
  assert.equal(app.api.tileMenuFor, "Zelda (U) [!].gbc");
  assert.ok(!labels(app).includes("Find the file…"),
            "the game is loaded, so its file is here");
  app.api.closeTileMenu();
  app.api.currentRomName = null;
  app.api.currentOriginalName = null;
});

// The three items leave the hamburger only while the card is up (body.home-card
// in styles.css), so the class has to mean exactly "the card is on screen" —
// never "a game is loaded", which is also true of the link modes the card
// cannot draw and where the menu is the only way to end a session.
test("body.home-card tracks the card itself, and clears with it", async () => {
  const app = await loadApp();
  const body = app.document.body;
  assert.equal(body.classList.contains("home-card"), false, "nothing on screen yet");
  app.api.setPausedCardShown(true);
  assert.equal(body.classList.contains("home-card"), true);
  assert.equal(app.document.getElementById("home-paused").hidden, false);
  app.api.setPausedCardShown(false);
  assert.equal(body.classList.contains("home-card"), false);
  assert.equal(app.document.getElementById("home-paused").hidden, true);
});

// body.lib-has-games decides which way in from a file is on screen: the hero's
// button or the library head's. Stated the positive way round so that the
// pre-first-render state — neither class set — shows the hero's.
test("body.lib-has-games follows the library, and is unset before the first render", async () => {
  const app = await loadApp();
  const body = app.document.body;
  assert.equal(body.classList.contains("lib-has-games"), false, "nothing rendered yet");
  seed(app, ["Zelda.gbc"]);
  await boot(app);
  assert.equal(body.classList.contains("lib-has-games"), true);
  app.idb.set("recent", []);
  await boot(app);
  assert.equal(body.classList.contains("lib-has-games"), false, "back to the empty state");
});


// ── The brand, twice ────────────────────────────────────────────────────────
// The hero's brand and the bar's are two elements now; what ties them is one
// number, --brand-p, which index.js drives off the scroll. The harness has no
// layout, so the crossover itself is checked in a browser; what is pinned here
// is the contract the stylesheet reads.

test("a loaded game pins the bar's brand on, whatever the scroll says", async () => {
  const app = await loadApp();
  const slot = app.document.getElementById("brand-slot");

  app.api.syncBrand();
  assert.equal(app.api.brandP, 0, "nothing scrolled, nothing loaded");
  assert.equal(slot.classList.contains("on"), false);

  app.document.body.classList.add("has-game");
  app.api.syncBrand();
  assert.equal(app.api.brandP, 1, "a game means the hero is not on screen at all");
  assert.equal(slot.classList.contains("on"), true);

  // And with no game and nothing measurable - which is this harness, and is
  // also a real browser mid-layout - it keeps what it had rather than snapping
  // the brand off the bar.
  app.document.body.classList.remove("has-game");
  app.api.syncBrand();
  assert.equal(app.api.brandP, 1, "no measurement, no change");
});

// Opacity 0 still takes a tap, so the slot has to be inert until the brand is
// really there - otherwise an invisible "back to the top" sits over the bar.
test("the bar's brand is inert, and out of the tab order, until it is showing",
     async () => {
  const app = await loadApp();
  const slot = app.document.getElementById("brand-slot");
  const btn = app.document.getElementById("bar-brand");

  app.api.setBrandP(0);
  assert.equal(slot.classList.contains("on"), false);
  assert.equal(btn.tabIndex, -1);

  app.api.setBrandP(0.3);
  assert.equal(slot.classList.contains("on"), true, "visible enough to hit");
  assert.equal(btn.tabIndex, -1, "but not yet worth a tab stop");

  app.api.setBrandP(1);
  assert.equal(btn.tabIndex, 0);
});


// ── The brand's flight ──────────────────────────────────────────────────────
// The bug these guard against: the flight used to fill FORWARDS, so a finished
// animation went on describing its element, and it was tracked in a variable
// that the flight cleared when it settled — which made those leftovers
// invisible to the next flight. Play the sequence load → menu → close a few
// times and one of them would be left holding opacity 0 with nothing able to
// clear it, and the brand was simply gone for the rest of the session.

const givenBoxes = (app) => {
  // Two logos in the two places, so a flight has something to measure.
  app.document.getElementById("home-logo").setBox(460, 300, 76, 76);
  app.document.getElementById("bar-logo").setBox(660, 14, 22, 22);
  app.document.getElementById("bar-brand").setBox(660, 12, 120, 28);
  app.document.getElementById("home-brand").setBox(420, 290, 160, 140);
};

const flightOn = (app, id) =>
  app.document.getElementById(id).getAnimations();

test("nothing the flight makes outlives it: every animation fills backwards",
     async () => {
  const app = await loadApp();
  givenBoxes(app);
  app.api.flyBrand(false);

  const all = [...flightOn(app, "bar-brand"), ...flightOn(app, "bar-logo"),
               ...flightOn(app, "bar-word"), ...flightOn(app, "home-brand")];
  assert.ok(all.length >= 3, "a closing flight moves more than one thing");
  for (const a of all) {
    assert.equal(a.id, app.api.BRAND_FLY_ID, "tagged, so the next flight finds it");
    assert.equal(a.opts.fill, "backwards",
                 "forwards fill is how the brand got stranded");
  }
});

test("a second flight cancels the first, even after the first has settled",
     async () => {
  const app = await loadApp();
  givenBoxes(app);

  app.api.flyBrand(false);
  const first = [...flightOn(app, "bar-logo"), ...flightOn(app, "home-brand")];
  assert.ok(first.length >= 2);

  // Let it land. This is the state the old code lost track of: finished, and
  // still attached.
  first.forEach((a) => a.finish());
  await settle();

  app.api.flyBrand(true);
  assert.ok(first.every((a) => a.playState === "idle"),
            "the landed flight was cancelled, not left describing the brand");
  assert.ok(flightOn(app, "bar-logo").length > 0, "and a new one is up");
});

// What flies is the logo, alone. The bar's word sits to the RIGHT of its logo
// where the hero's sits UNDER it, so any transform that aims the logo properly
// carries the word off to one side - fading it on the way down did not fix
// that, it only made a fainter thing sail past the mark. It stays put and
// dissolves where it is.
test("only the logo is given a transform; the word never moves", async () => {
  const app = await loadApp();
  givenBoxes(app);

  for (const up of [false, true]) {
    app.api.flyBrand(up);
    const moved = (id) => flightOn(app, id)
      .some((a) => a.frames.some((f) => f.transform !== undefined));
    assert.equal(moved("bar-logo"), true, "the logo is aimed");
    assert.equal(moved("bar-word"), false, "the word is not carried along");
    assert.equal(moved("bar-brand"), false, "nor is the row it sits in");
  }
});

test("the word is only solid at the end it belongs to", async () => {
  const app = await loadApp();
  givenBoxes(app);

  app.api.flyBrand(false);
  let word = flightOn(app, "bar-word")[0];
  assert.equal(word.frames[0].opacity, 1, "solid in the bar it is leaving");
  assert.equal(word.frames[word.frames.length - 1].opacity, 0, "gone by the hero");
  assert.equal(word.opts.easing, "linear",
               "iteration easing would move the offsets off the wall clock");
  assert.equal(word.opts.duration, app.api.BRAND_MOVE_MS,
               "full length, so finishing cannot hand it back mid-flight");

  app.api.flyBrand(true);
  word = flightOn(app, "bar-word")[0];
  assert.equal(word.frames[0].opacity, 0, "and the other way round coming up");
  assert.equal(word.frames[word.frames.length - 1].opacity, 1);
});
