// Renaming a game (web/index.js renameGame + the Manage ROMs pencil).
//
// A rename is not a label change: every record this app stores for a game is
// keyed by its name, so this is a migration of the whole record and is tested
// like one. The assertions are written as "here is every key stored for the
// game; after the rename these exact keys exist and no others", so a per-game
// record that nobody taught the rename about shows up here as an orphan
// instead of quietly staying behind pointing at a game that no longer exists.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle } from "./helpers.mjs";

// ── Fixtures ────────────────────────────────────────────────────────────────

// Every IndexedDB key web/index.js writes FOR one game, spelled out here rather
// than imported: these tests are the independent statement of the contract.
// (game-delete.test.mjs keeps the same list for the destructive paths; the
// "index.js agrees with this list" test below ties the two together.)
const perGameKeys = (n) => [
  "rom:" + n,
  "art:" + n,
  "save:" + n,
  "save:" + n + "-p2",
  "stateauto:" + n,
  "cheats:" + n,
  "state:" + n, "statemeta:" + n,
  ...[1, 2, 3, 4, 5, 6, 7, 8].flatMap((s) =>
    ["state:" + n + ":slot" + s, "statemeta:" + n + ":slot" + s]),
];

// The subset Drive mirrors — parseDriveFileName recognises these and only
// these, so they are the ones a rename can queue remote work for.
const syncableKeys = (n) =>
  perGameKeys(n).filter((k) =>
    !k.startsWith("art:") && !k.startsWith("stateauto:") && !k.startsWith("cheats:"));

const seedValue = (key, name) => {
  if (key.startsWith("rom:")) return { name, data: u8(1, 2, 3, 4) };
  if (key.startsWith("statemeta:")) return { thumb: "data:image/png;base64,AA==", ts: 1000 };
  if (key.startsWith("stateauto:")) return { bytes: u8(5, 5), ts: 1000 };
  if (key.startsWith("cheats:")) return "[x] Infinite HP\n01ABCD01\n";
  return u8(7, 7);
};

// One game with EVERY kind of per-game data attached, plus its recents entry.
const seedGame = (app, name, ts = 100) => {
  for (const k of perGameKeys(name)) app.idb.set(k, seedValue(k, name));
  const recents = app.idb.get("recent") || [];
  app.idb.set("recent", [...recents, { name, ts }]);
};

// A sparser game: ROM + one battery save + two save states, which is what a
// real library row usually looks like.
const seedTypicalGame = (app, name, ts = 100) => {
  app.idb.set("rom:" + name, { name, data: u8(1, 2, 3, 4) });
  app.idb.set("save:" + name, u8(9, 9));
  app.idb.set("state:" + name, u8(6));
  app.idb.set("statemeta:" + name, { thumb: "x", ts: 1 });
  app.idb.set("state:" + name + ":slot3", u8(6));
  app.idb.set("statemeta:" + name + ":slot3", { thumb: "x", ts: 1 });
  const recents = app.idb.get("recent") || [];
  app.idb.set("recent", [...recents, { name, ts }]);
};

const signIn = (app, extra = {}) => {
  app.api.syncState = {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], sigs: {}, rmt: {},
    connected: true, ...extra,
  };
};

const keysFor = (app, name) =>
  [...app.idb.keys()].filter((k) => typeof k === "string" && k.includes(name)).sort();

const OLD = "Goodboy Demo.gb";
const NEW = "Good Boy (EN).gb";

// ── The migration ───────────────────────────────────────────────────────────

test("every stored key moves to the new name, and none stays behind", async () => {
  const app = await loadApp();
  seedGame(app, OLD);

  const res = await app.api.renameGame(OLD, NEW);
  assert.equal(res.ok, true);
  assert.equal(res.moved, perGameKeys(OLD).length, "every seeded key moved");

  eq(keysFor(app, "Goodboy"), [], "nothing is left under the old name");
  eq(keysFor(app, "Good Boy"), perGameKeys(NEW).sort(),
     "every key exists under the new name");
});

test("the moved values are the originals, byte for byte", async () => {
  const app = await loadApp();
  seedGame(app, OLD);
  const before = new Map(perGameKeys(OLD).map((k) => [k, app.idb.get(k)]));

  await app.api.renameGame(OLD, NEW);

  for (const [k, v] of before) {
    const moved = k.replace(OLD, NEW);
    assert.deepEqual(app.idb.get(moved), v, "value survived the move: " + moved);
  }
});

test("this test's key list is the one index.js actually uses", async () => {
  const app = await loadApp();
  eq(app.api.allPerGameKeys(OLD).sort(), perGameKeys(OLD).sort());
});

test("the library entry follows the rename, to the front of the list", async () => {
  const app = await loadApp();
  seedTypicalGame(app, "Other.gba", 500);
  seedTypicalGame(app, OLD, 100);

  await app.api.renameGame(OLD, NEW);

  const recents = app.idb.get("recent");
  eq(recents.map((r) => r.name), [NEW, "Other.gba"],
     "renamed game is first; a fresh timestamp is what stops a stale remote " +
     "tombstone for the new name from deleting it on the next merge");
  assert.ok(recents[0].ts > 500, "the entry carries a fresh timestamp");
});

test("a save-data-only game (no recents entry) renames without inventing one", async () => {
  const app = await loadApp();
  app.idb.set("recent", []);
  app.idb.set("save:" + OLD, u8(3, 3));

  const res = await app.api.renameGame(OLD, NEW);
  assert.equal(res.ok, true);
  assert.deepEqual(app.idb.get("save:" + NEW), u8(3, 3));
  assert.equal(app.idb.has("save:" + OLD), false);
  eq(app.idb.get("recent"), []);
});

test("printed photos are re-tagged with the new name", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  app.idb.set("prints", [
    { png: "data:1", ts: 1, game: OLD },
    { png: "data:2", ts: 2, game: "Other.gb" },
  ]);
  await app.api.loadPrinterPhotos();

  await app.api.renameGame(OLD, NEW);

  eq(app.idb.get("prints").map((p) => p.game), [NEW, "Other.gb"]);
  eq(app.api.printerPhotos.map((p) => p.game), [NEW, "Other.gb"],
     "the in-memory gallery agrees with storage");
});

// ── Collisions ──────────────────────────────────────────────────────────────

test("renaming onto a name already in the library is refused, and changes nothing", async () => {
  const app = await loadApp();
  seedGame(app, OLD);
  seedTypicalGame(app, NEW, 200);
  const before = [...app.idb.keys()].sort();

  const res = await app.api.renameGame(OLD, NEW);
  assert.equal(res.ok, false);
  assert.match(res.error, /already exists in your library/);
  assert.match(res.error, /Nothing was changed/);
  eq([...app.idb.keys()].sort(), before, "not one key moved");
  assert.deepEqual(app.idb.get("save:" + NEW), u8(9, 9),
                   "the existing game's save was not overwritten or merged");
});

test("a name whose only trace is leftover save data still counts as taken", async () => {
  const app = await loadApp();
  seedGame(app, OLD);
  app.idb.set("save:" + NEW, u8(4, 4)); // orphaned save, no recents entry

  const res = await app.api.renameGame(OLD, NEW);
  assert.equal(res.ok, false);
  assert.deepEqual(app.idb.get("save:" + NEW), u8(4, 4));
  assert.deepEqual(app.idb.get("save:" + OLD), u8(7, 7));
});

test("a record under the new name that the library cannot see still blocks the move", async () => {
  const app = await loadApp();
  seedGame(app, OLD);
  // cheats: is not part of romsWithSaveData, so only the key-level check sees
  // it. Overwriting it would silently hand one game another's cheat list.
  app.idb.set("cheats:" + NEW, "someone else's codes");

  const res = await app.api.renameGame(OLD, NEW);
  assert.equal(res.ok, false);
  assert.equal(app.idb.get("cheats:" + NEW), "someone else's codes");
  assert.equal(app.idb.get("cheats:" + OLD), seedValue("cheats:" + OLD, OLD));
});

// ── Failure part-way through ────────────────────────────────────────────────

test("a write that fails half-way leaves the original whole", async () => {
  const app = await loadApp();
  seedGame(app, OLD);
  const before = new Map([...app.idb.entries()]);

  // Fail the tenth write of the transaction: several keys have already been
  // copied and their originals deleted by then.
  let writes = 0;
  app.state.idbFail = (op) => op === "put" && ++writes === 10;

  const res = await app.api.renameGame(OLD, NEW);
  app.state.idbFail = null;

  assert.equal(res.ok, false);
  assert.match(res.error, /fake IndexedDB failure: put/,
               "the move really did die in the middle, not before it started");
  assert.match(res.error, /Nothing was changed/);
  eq([...app.idb.keys()].sort(), [...before.keys()].sort(),
     "the store holds exactly the keys it held before");
  for (const [k, v] of before) {
    assert.deepEqual(app.idb.get(k), v, "value untouched: " + k);
  }
  eq(keysFor(app, "Good Boy"), [], "no half-written copy under the new name");
});

test("a failed rename leaves the library index and the sync queue alone", async () => {
  const app = await loadApp();
  seedGame(app, OLD);
  signIn(app);
  app.state.idbFail = (op, key) => op === "put" && key === "state:" + NEW;

  const res = await app.api.renameGame(OLD, NEW);
  app.state.idbFail = null;

  assert.equal(res.ok, false);
  eq(app.idb.get("recent").map((r) => r.name), [OLD]);
  eq(app.api.syncState.queueDel, [], "nothing queued for remote deletion");
  eq(app.api.syncState.queueUp, []);
  eq(app.api.syncState.tomb, [], "no tombstone for a rename that did not happen");
});

// ── Drive ───────────────────────────────────────────────────────────────────

test("signed in, a rename queues in-place remote renames — no delete, no re-upload", async () => {
  const app = await loadApp();
  seedGame(app, OLD);
  signIn(app, {
    sigs: { ["rom:" + OLD]: "sig", ["save:" + OLD]: "sig" },
    rmt: { ["save:" + OLD]: "2026-01-01T00:00:00Z" },
  });

  await app.api.renameGame(OLD, NEW);
  const s = app.api.syncState;

  eq(s.queueRen.map((r) => r.from).sort(), syncableKeys(OLD).sort(),
     "every remote file under the old name is queued for an in-place rename");
  eq(s.queueRen.map((r) => r.to).sort(), syncableKeys(NEW).sort());
  eq(s.queueDel, [], "nothing is deleted from Drive");
  eq(s.queueUp, [], "nothing is re-uploaded — the files only change name");
  eq(s.sigs, { ["rom:" + NEW]: "sig", ["save:" + NEW]: "sig" },
     "signatures follow their files to the new names");
  eq(s.rmt, { ["save:" + NEW]: "2026-01-01T00:00:00Z" });
  eq(s.tomb, [], "a rename is not a delete: no tombstone");
  assert.equal(s.ren.length, 1);
  assert.equal(s.ren[0].from, OLD);
  assert.equal(s.ren[0].to, NEW,
               "the ren marker is what tells other devices to migrate their copies");
});

test("the queue survives the tab: it is written in the same transaction as the move", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  signIn(app);

  await app.api.renameGame(OLD, NEW);

  // Not "the in-memory object was updated" — what a reload will find on disk.
  const persisted = app.idb.get("gdrive_sync");
  assert.ok(persisted.queueRen.some(
    (r) => r.from === "save:" + OLD && r.to === "save:" + NEW));
  assert.equal(persisted.ren[0].from, OLD);
  assert.deepEqual(app.idb.get("save:" + NEW), u8(9, 9),
                   "…and the data it describes is there too");
});

test("files this device does not hold still get their remote rename", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD); // no P2 save, no slot-7 state, …
  signIn(app);

  await app.api.renameGame(OLD, NEW);
  const s = app.api.syncState;

  // Every syncable key is offered, held here or not: the rename is an
  // in-place metadata change on Drive, so a remote file with no local copy
  // renames instead of being stranded under the old name (the flush skips
  // the names Drive doesn't hold).
  eq(s.queueRen.map((r) => r.from).sort(), syncableKeys(OLD).sort());
  eq(s.queueDel, []);
  eq(s.queueUp, []);
});

test("a Drive-only game renames without its bytes ever being here", async () => {
  const app = await loadApp();
  // The shape "Remove from this device" leaves behind: saves here, ROM only on
  // Drive. The remote ROM renames in place, so its only copy is never touched.
  app.idb.set("recent", [{ name: OLD, ts: 100 }]);
  app.idb.set("save:" + OLD, u8(9, 9));
  signIn(app, { sigs: { ["rom:" + OLD]: "s" } });

  const res = await app.api.renameGame(OLD, NEW);

  assert.equal(res.ok, true);
  assert.deepEqual(app.idb.get("save:" + NEW), u8(9, 9), "the local save moved");
  assert.ok(app.api.syncState.queueRen.some(
    (r) => r.from === "rom:" + OLD && r.to === "rom:" + NEW),
    "the ROM this device never held is renamed on Drive");
  eq(app.api.syncState.sigs, { ["rom:" + NEW]: "s" });
  eq(app.api.syncState.queueDel, [], "its only copy is never queued for deletion");
  eq(app.idb.get("recent").map((r) => r.name), [NEW]);
});

test("a key already queued for remote deletion is not renamed back to life", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  signIn(app, { queueDel: ["state:" + OLD] });

  await app.api.renameGame(OLD, NEW);
  const s = app.api.syncState;

  assert.ok(s.queueDel.includes("state:" + OLD),
            "the condemned file keeps its fate, under its old name");
  assert.ok(!s.queueRen.some((r) => r.from === "state:" + OLD),
            "renaming it would resurrect it under the new name");
});

test("signed out, that same game renames — there is no remote copy to lose", async () => {
  const app = await loadApp();
  app.idb.set("recent", [{ name: OLD, ts: 100 }]);
  app.idb.set("save:" + OLD, u8(9, 9));

  const res = await app.api.renameGame(OLD, NEW);
  assert.equal(res.ok, true);
  assert.deepEqual(app.idb.get("save:" + NEW), u8(9, 9));
});

test("the pencil is enabled on a Drive-only row", async () => {
  const app = await loadApp();
  app.idb.set("recent", [{ name: OLD, ts: 100 }]);
  app.idb.set("save:" + OLD, u8(9, 9)); // saves here, ROM only on Drive
  signIn(app, { sigs: { ["rom:" + OLD]: "s" } });
  await openManageList(app);

  const btn = renameButtonFor(app, OLD);
  assert.equal(btn.disabled, false,
    "Drive renames its files in place, so the bytes never need to be here");
  assert.match(btn.title, /Rename this game/);
});

test("a stale tombstone on the new name is cleared, not left to delete the game", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  // Another device deleted a game of this name last year; the tombstone is
  // still in the merged library. Without clearing it, the very next pull would
  // offer to delete the game we just renamed.
  signIn(app, { tomb: [{ name: NEW, ts: Date.now() }] });

  await app.api.renameGame(OLD, NEW);

  eq(app.api.syncState.tomb, [], "…and no tombstone is raised: a rename is not a delete");
});

test("a delete queued for the new name is dropped, and a pending upload follows the rename", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  signIn(app, { queueDel: ["save:" + NEW], queueUp: ["save:" + OLD] });

  await app.api.renameGame(OLD, NEW);
  const s = app.api.syncState;

  assert.equal(s.queueDel.includes("save:" + NEW), false);
  assert.equal(s.queueUp.includes("save:" + OLD), false,
               "an upload of a key that no longer exists is dropped");
  assert.ok(s.queueUp.includes("save:" + NEW),
            "…its unsent bytes deliver under the new name instead");
});

test("signed out, a rename is purely local", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  const before = JSON.stringify(app.api.syncState);

  const res = await app.api.renameGame(OLD, NEW);

  assert.equal(res.ok, true);
  assert.equal(JSON.stringify(app.api.syncState), before, "no queues, no tombstone");
  assert.equal(app.idb.has("gdrive_sync"), false);
});

// ── The running game ────────────────────────────────────────────────────────

test("renaming the loaded game moves the session with it", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  app.api.currentRomName = "rom.gb";
  app.api.currentOriginalName = OLD;

  const res = await app.api.renameGame(OLD, NEW);

  assert.equal(res.ok, true);
  assert.equal(app.api.currentOriginalName, NEW);
});

test("the next autosave of a renamed running game lands on the new key", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  app.api.currentRomName = "rom.gb";
  app.api.currentOriginalName = OLD;
  app.sandbox.FS.files.set("rom.sav", u8(1, 2, 3));

  await app.api.renameGame(OLD, NEW);
  await app.api.persistSave(app.api.currentRomName, app.api.currentOriginalName);

  assert.deepEqual(app.idb.get("save:" + NEW), u8(1, 2, 3));
  assert.equal(app.idb.has("save:" + OLD), false,
               "the old key did not come back under the autosave");
});

test("a failed rename hands the session back to the old name", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  app.api.currentRomName = "rom.gb";
  app.api.currentOriginalName = OLD;
  app.state.idbFail = (op, key) => op === "put" && key === "save:" + NEW;

  const res = await app.api.renameGame(OLD, NEW);
  app.state.idbFail = null;

  assert.equal(res.ok, false);
  assert.equal(app.api.currentOriginalName, OLD,
               "the game is still attached to the data that is still there");
});

test("a live link session refuses the rename", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  app.api.linkMode = true;
  app.api.linkRomEntry = { name: OLD };

  const res = await app.api.renameGame(OLD, NEW);

  assert.equal(res.ok, false);
  assert.match(res.error, /link or online session/);
  assert.ok(app.idb.has("save:" + OLD));
});

// ── Names ───────────────────────────────────────────────────────────────────

const err = (app, input, old = OLD, taken = new Set()) =>
  app.api.renameNameError(input, old, taken);

test("empty, blank and over-long names are refused", async () => {
  const app = await loadApp();
  assert.match(err(app, ""), /Enter a name/);
  assert.match(err(app, "   "), /Enter a name/);
  assert.match(err(app, "x".repeat(app.api.RENAME_MAX_LEN + 1)), /characters or fewer/);
  assert.equal(err(app, "x".repeat(app.api.RENAME_MAX_LEN)), null);
});

test("characters that would break a key or a file name are refused", async () => {
  const app = await loadApp();
  assert.match(err(app, "a/b"), /can't contain \/ or/);
  assert.match(err(app, "a\\b"), /can't contain \/ or/);
  assert.match(err(app, "state:slot1"), /colon/);
  assert.match(err(app, "a\u0007b"), /control characters/);
  assert.match(err(app, "Link Save-p2", "no-extension"), /-p2/);
  // With an extension after it, "-p2" is harmless: the reserved key shape is
  // "save:<full name>-p2", and the full name ends in ".gb".
  assert.equal(err(app, "Link Save-p2"), null);
});

test("a name is trimmed, not mangled, and keeps its extension", async () => {
  const app = await loadApp();
  assert.equal(app.api.renameFullName("  Pocket Monster  ", OLD), "Pocket Monster.gb");
  assert.equal(err(app, "  Pocket Monster  "), null);
  // Typing the extension out is not punished with a doubled one.
  assert.equal(app.api.renameFullName("Pocket Monster.gb", OLD), "Pocket Monster.gb");
  assert.equal(app.api.renameFullName("Pocket Monster.GB", OLD), "Pocket Monster.gb");
  // An extensionless game stays extensionless.
  assert.equal(app.api.renameFullName("Thing", "Nameless"), "Thing");
  // Unusual but legal: spaces, brackets, unicode.
  assert.equal(err(app, "ゼルダの伝説 (J) [!]"), null);
});

test("the game's own name and an existing name are both refused, differently", async () => {
  const app = await loadApp();
  assert.match(err(app, "Goodboy Demo"), /already this game's name/);
  assert.match(err(app, "Good Boy (EN)", OLD, new Set([NEW])), /already in your library/);
});

// ── The Manage ROMs row ─────────────────────────────────────────────────────

const openManageList = async (app) => {
  app.document.getElementById("roms-sort").parentElement = { hidden: false };
  await app.api.refreshRomsManageList();
  await settle();
};

const rowFor = (app, name) =>
  app.document.getElementById("roms-manage-list").children
    .find((r) => r.children[0].title === name) || null;

const renameButtonFor = (app, name) => {
  const row = rowFor(app, name);
  return row ? row.children[0].children.find((c) => c.tagName === "BUTTON") : null;
};

test("every row carries a rename button that names its game", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  seedTypicalGame(app, "Other.gba", 200);
  await openManageList(app);

  for (const [name, label] of [[OLD, "Rename Goodboy Demo"], ["Other.gba", "Rename Other"]]) {
    const btn = renameButtonFor(app, name);
    assert.ok(btn, "row has a rename button: " + name);
    assert.equal(btn.getAttribute("aria-label"), label);
    assert.equal(btn.disabled, false);
    assert.ok(btn.innerHTML.includes("<svg"), "it is the pencil");
  }
  // The row's shape is unchanged for everything else: name first, then the
  // action buttons.
  assert.ok(rowFor(app, OLD).children[1].className.includes("roms-manage-actions"));
});

test("the rename button is disabled while a link session holds the game", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  app.api.linkMode = true;
  app.api.linkRomEntry = { name: OLD };
  await openManageList(app);

  const btn = renameButtonFor(app, OLD);
  assert.equal(btn.disabled, true);
  assert.match(btn.title, /Exit link mode/);
});

// ── The modal ───────────────────────────────────────────────────────────────

const walk = (el, out = []) => {
  for (const c of el.children || []) { out.push(c); walk(c, out); }
  return out;
};
const overlay = (app) =>
  app.document.body.children.filter((c) => c.className.includes("sync-modal")).pop();
const modalText = (app) =>
  walk(overlay(app)).map((n) => String(n.textContent || "")).join(" | ");
const modalButton = (app, label) =>
  walk(overlay(app)).find((n) => n.tagName === "BUTTON" && n.textContent === label);
const modalInput = (app) => walk(overlay(app)).find((n) => n.tagName === "INPUT");

const openRename = async (app, name) => {
  await openManageList(app);
  await renameButtonFor(app, name).dispatch("click");
  await settle();
};

test("the confirmation says what will be renamed, itemised", async () => {
  const app = await loadApp();
  seedGame(app, OLD); // one of everything
  app.idb.set("prints", [{ png: "d", ts: 1, game: OLD }]);
  await openRename(app, OLD);

  modalInput(app).value = "Good Boy (EN)";
  await modalButton(app, "Continue").dispatch("click");

  const text = modalText(app);
  assert.ok(text.includes(OLD), "the old name is stated");
  assert.ok(text.includes(NEW), "the new name is stated");
  assert.ok(text.includes("The ROM file and its box art"), text);
  assert.ok(text.includes("1 save file"), text);
  assert.ok(text.includes("The 2-player link save"), text);
  assert.ok(text.includes("9 save states"), text);
  assert.ok(text.includes("Your cheat list"), text);
  assert.ok(text.includes("1 printed photo"), text);
  assert.ok(modalButton(app, "Rename"), "and it is the confirmation that renames");
});

test("the counts are of what is actually stored, not of what could be", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD); // ROM, one save, two states, no cheats/art
  await openRename(app, OLD);
  modalInput(app).value = "Good Boy (EN)";
  await modalButton(app, "Continue").dispatch("click");

  const text = modalText(app);
  assert.ok(text.includes("The ROM file"), text);
  assert.ok(!text.includes("box art"), text);
  assert.ok(text.includes("2 save states"), text);
  assert.ok(!text.includes("cheat list"), text);
  assert.ok(!text.includes("printed photo"), text);
});

test("confirming performs the rename and the list re-renders under the new name", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  await openRename(app, OLD);
  modalInput(app).value = "Good Boy (EN)";
  await modalButton(app, "Continue").dispatch("click");
  await modalButton(app, "Rename").dispatch("click");
  await settle();

  assert.deepEqual(app.idb.get("save:" + NEW), u8(9, 9));
  assert.equal(app.idb.has("save:" + OLD), false);
  assert.ok(app.toasts.some((t) => t.includes("Renamed to")), app.toasts.join("|"));
  assert.ok(rowFor(app, NEW), "the row is there under the new name");
  assert.equal(rowFor(app, OLD), null);
});

test("a colliding name is refused in the modal, before anything is touched", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  seedTypicalGame(app, NEW, 200);
  await openRename(app, OLD);

  const input = modalInput(app);
  input.value = "Good Boy (EN)";
  await input.dispatch("input");

  assert.match(modalText(app), /already in your library/);
  assert.equal(modalButton(app, "Continue").disabled, true);
  assert.equal(modalButton(app, "Rename"), undefined, "no way through to the confirmation");
  assert.deepEqual(app.idb.get("save:" + NEW), u8(9, 9), "untouched");
});

test("the modal shows what the new name will be stored as", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  await openRename(app, OLD);

  const input = modalInput(app);
  input.value = "  Good Boy (EN)  ";
  await input.dispatch("input");

  assert.match(modalText(app), /Stored as “Good Boy \(EN\)\.gb”/);
});

test("a rename that fails says so, and says nothing changed", async () => {
  const app = await loadApp();
  seedTypicalGame(app, OLD);
  await openRename(app, OLD);
  modalInput(app).value = "Good Boy (EN)";
  await modalButton(app, "Continue").dispatch("click");

  app.state.idbFail = (op, key) => op === "put" && key === "save:" + NEW;
  await modalButton(app, "Rename").dispatch("click");
  await settle();
  app.state.idbFail = null;

  const text = modalText(app);
  assert.match(text, /fake IndexedDB failure/, text);
  assert.match(text, /is unchanged/, text);
  assert.ok(modalButton(app, "Try again"), "and offers another go");
  assert.deepEqual(app.idb.get("save:" + OLD), u8(9, 9));
});
