// Recent-ROM library: addRecentRom / bumpRecentIndex / getRomBytes, and the
// ROM byte budget, which bounds the files this device holds and never the
// library - plus the pressure path, for when the browser's own limit bites
// first.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, fakeFile } from "./helpers.mjs";

test("addRecentRom stores rom:, art: and the metadata index", async () => {
  const app = await loadApp();
  const art = { fake: "blob" };
  await app.api.addRecentRom("A.gba", u8(1, 2, 3), art);
  await settle();

  eq(app.idb.get("rom:A.gba"), { name: "A.gba", data: u8(1, 2, 3) });
  eq(app.idb.get("art:A.gba"), art);
  eq(app.idb.get("recent").map((r) => r.name), ["A.gba"]);
  eq(await app.api.getRomBytes("A.gba"), u8(1, 2, 3));

  assert.equal(app.elements.get("home-recent-wrap").hidden, false);
});

test("re-adding an existing name moves it to the front, no duplicate", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("A.gba", u8(1));
  await app.api.addRecentRom("B.gba", u8(2));
  await app.api.addRecentRom("A.gba", u8(1));
  eq(app.idb.get("recent").map((r) => r.name), ["A.gba", "B.gba"]);
});

test("the budget is bytes, not games: 25 small ROMs all keep their files", async () => {
  const app = await loadApp();
  assert.equal(app.api.ROM_BUDGET, 2 * 1024 * 1024 * 1024);
  for (let i = 0; i < 25; i++) await app.api.addRecentRom(`Game${i}.gba`, u8(i, i));
  assert.equal(app.idb.get("recent").length, 25);
  for (let i = 0; i < 25; i++) {
    assert.ok(app.idb.get(`rom:Game${i}.gba`), `Game${i} keeps its file`);
  }
});

const GB = 1024 * 1024 * 1024;

test("over budget the oldest files go, and nothing else of those games does",
  async () => {
    const app = await loadApp();
    app.idb.set("save:Game0.gba", u8(9, 9));
    app.idb.set("state:Game0.gba", u8(8));
    app.idb.set("frame:Game0.gba", u8(6));
    // Three games at 1 GB each against a 2 GB budget: the third one played
    // pushes the first one's file out. Sizes are declared, not stored.
    for (const n of ["Game0.gba", "Game1.gba", "Game2.gba"]) {
      await app.api.addRecentRom(n, u8(1, 1), { art: n });
    }
    for (const n of ["Game0.gba", "Game1.gba", "Game2.gba"]) {
      await app.api.noteRomSize(n, GB);
    }
    await app.api.bumpRecentIndex("Game2.gba");
    await settle();

    const names = app.idb.get("recent").map((r) => r.name);
    assert.equal(names.length, 3, "the budget bounds bytes, not the library");
    assert.ok(names.includes("Game0.gba"), "the oldest game keeps its entry");
    assert.equal(app.idb.get("rom:Game0.gba"), undefined, "its file is gone");
    assert.ok(app.idb.get("rom:Game1.gba"), "and no further than needed");
    eq(app.idb.get("art:Game0.gba"), { art: "Game0.gba" }, "the tile keeps its art");
    eq(app.idb.get("frame:Game0.gba"), u8(6), "and its last frame");
    eq(app.idb.get("save:Game0.gba"), u8(9, 9), "save survives eviction");
    eq(app.idb.get("state:Game0.gba"), u8(8), "state survives eviction");
    // Re-read from the record on the way out, so what is left on file is the
    // true size and the menu can still say what the file is worth.
    assert.equal(app.idb.get("romsizes")["Game0.gba"], 2);
  });

test("a game whose size was never noted counts as nothing, not as a guess",
  async () => {
    const app = await loadApp();
    for (const n of ["Big0.gba", "Big1.gba", "Old.gba"]) {
      await app.api.addRecentRom(n, u8(1, 1));
    }
    await app.api.noteRomSize("Big0.gba", GB);
    await app.api.noteRomSize("Big1.gba", GB);
    delete app.idb.get("romsizes")["Old.gba"]; // imported before sizes were noted
    await app.api.bumpRecentIndex("Old.gba");

    // Exactly 2 GB accounted for. Counting the unmeasured game as anything at
    // all would tip that over and cost the oldest game its file.
    assert.ok(app.idb.get("rom:Big0.gba"), "nothing evicted on a guess");
    assert.ok(app.idb.get("rom:Old.gba"));
  });

test("playing a game notes its size, which is what keeps the budget honest",
  async () => {
    const app = await loadApp();
    await app.api.addRecentRom("A.gba", u8(1, 2, 3, 4));
    delete app.idb.get("romsizes")["A.gba"];
    await app.api.getRomBytes("A.gba");
    assert.equal(app.idb.get("romsizes")["A.gba"], 4);
  });

// The browser has a limit of its own, under ours and unannounced. It is only
// ever reported by a write failing, so that is where these tests put it.

const quotaError = () => {
  const e = new Error("full");
  e.name = "QuotaExceededError";
  return e;
};

// `key` fails to write until this many ROM files have been given up.
const fullUntilFreed = (app, key, needFreed) => {
  const err = quotaError();
  let freed = 0;
  const del = app.idb.delete.bind(app.idb);
  app.idb.delete = (k) => {
    if (typeof k === "string" && k.startsWith("rom:")) freed++;
    return del(k);
  };
  app.state.idbFail = (op, k) => op === "put" && k === key && freed < needFreed && err;
};

test("a full disk gives up the oldest files rather than losing the write",
  async () => {
    const app = await loadApp();
    for (const n of ["A.gba", "B.gba", "C.gba"]) await app.api.addRecentRom(n, u8(1));
    fullUntilFreed(app, "rom:D.gba", 2);
    await app.api.addRecentRom("D.gba", u8(4, 4));
    await settle();

    eq(app.idb.get("rom:D.gba"), { name: "D.gba", data: u8(4, 4) },
      "the write went through once there was room");
    assert.equal(app.idb.get("rom:A.gba"), undefined, "oldest file given up");
    assert.equal(app.idb.get("rom:B.gba"), undefined, "then the next oldest");
    assert.ok(app.idb.get("rom:C.gba"), "and no further than needed");
    assert.equal(app.idb.get("recent").length, 4, "every game keeps its entry");
    assert.ok(app.toasts.some((t) => /full/i.test(t)), "and the person is told");
  });

test("a save is never what gets given up to make room", async () => {
  const app = await loadApp();
  for (const n of ["A.gba", "B.gba"]) await app.api.addRecentRom(n, u8(1));
  app.idb.set("save:A.gba", u8(7, 7));
  app.sandbox.FS.files.set("rom.sav", u8(1, 2, 3));
  fullUntilFreed(app, "save:B.gba", 1);
  await app.api.persistSave("rom.gba", "B.gba");
  await settle();

  eq(app.idb.get("save:B.gba"), u8(1, 2, 3), "the save was written");
  eq(app.idb.get("save:A.gba"), u8(7, 7), "the other game's save is untouched");
  assert.equal(app.idb.get("rom:A.gba"), undefined, "a ROM file paid for it");
  assert.ok(app.idb.get("rom:B.gba"), "not the file of the game being saved");
});

test("nothing left to give: the write fails and says so, adding no entry",
  async () => {
    const app = await loadApp();
    app.state.idbFail = (op, k) => op === "put" && k === "rom:Big.gba" && quotaError();
    await app.api.addRecentRom("Big.gba", u8(1, 2, 3));
    await settle();

    assert.equal(app.idb.get("rom:Big.gba"), undefined);
    eq(app.idb.get("recent") || [], [],
      "no tile offering to find a file the person is holding");
    assert.ok(app.toasts.some((t) => /No room/i.test(t)));
  });

test("deleting the last game empties the library and the hero takes over", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("A.gba", u8(1), { a: 1 });
  app.idb.set("save:A.gba", u8(5));
  await app.api.deleteGameEverywhere("A.gba");
  await app.api.refreshHomeRecent();
  await settle();
  eq(app.idb.get("recent"), []);
  assert.equal(app.idb.get("rom:A.gba"), undefined);
  assert.equal(app.idb.get("art:A.gba"), undefined);
  assert.equal(app.idb.get("save:A.gba"), undefined, "Delete takes the save too");
  // An empty library has no head, no bar and no tiles, so the whole section
  // leaves; the hero above it carries the Drive way in instead.
  await settle();
  assert.equal(app.elements.get("home-recent-wrap").hidden, true);
  assert.equal(app.elements.get("home-drive").hidden, false);
  assert.equal(app.elements.get("home-drive").textContent, "Sign in");
});

test("a library with games withdraws the hero's Drive slot", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("A.gba", u8(1));
  await settle();
  assert.equal(app.elements.get("home-recent-wrap").hidden, false);
  assert.equal(app.elements.get("home-drive").hidden, true);
});

test("the grid draws only the columns it fills, and stops at five", async () => {
  const app = await loadApp();
  const wrap = app.elements.get("home-recent-wrap");
  for (let i = 1; i <= 7; i++) {
    await app.api.addRecentRom(`G${i}.gba`, u8(i));
    await settle();
    assert.equal(wrap.dataset.n, i <= 5 ? String(i) : undefined,
      `${i} games`);
  }
});

test("X.gb and X.gbc key separately everywhere (full-name keying)", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("X.gb", u8(1));
  await app.api.addRecentRom("X.gbc", u8(2));
  eq(app.idb.get("rom:X.gb").data, u8(1));
  eq(app.idb.get("rom:X.gbc").data, u8(2));

  app.idb.set("save:X.gb", u8(11));
  app.idb.set("save:X.gbc", u8(22));
  eq(await app.api.romsWithSaveData(), ["X.gb", "X.gbc"]);
  await app.api.deleteSaveData("X.gb");
  assert.equal(app.idb.get("save:X.gb"), undefined);
  eq(app.idb.get("save:X.gbc"), u8(22), "sibling extension untouched");
});

test("getRomBytes returns null for missing or empty records", async () => {
  const app = await loadApp();
  assert.equal(await app.api.getRomBytes("Nope.gba"), null);
  app.idb.set("rom:Empty.gba", { name: "Empty.gba", data: u8() });
  assert.equal(await app.api.getRomBytes("Empty.gba"), null);
  app.idb.set("rom:Buf.gba", { name: "Buf.gba", data: u8(1, 2).buffer });
  eq(await app.api.getRomBytes("Buf.gba"), u8(1, 2));
});

test("handleRomFile rejects .sav/.state files — no path stores a mismatched-name save", async () => {
  const app = await loadApp();
  app.api.handleRomFile(fakeFile("OldName.sav", u8(1, 2)));
  app.api.handleRomFile(fakeFile("OldName.state", u8(1, 2)));
  await settle();
  assert.equal(app.alerts.length, 2);
  assert.match(app.alerts[0], /Unsupported file/);
  assert.equal(app.idb.size, 0, "nothing stored");
});

test("handleRomFile stores an accepted ROM under its full original file name", async () => {
  const app = await loadApp();
  app.runIn("Module.ccall = () => {}"); // stub the wasm boot
  // Byte 3 = 0xEA: an ARM branch at the entry point passes the header check.
  app.api.handleRomFile(fakeFile("Some Game (U).gba", u8(1, 2, 3, 0xea)));
  await settle();
  await settle();
  eq(app.idb.get("rom:Some Game (U).gba"), { name: "Some Game (U).gba", data: u8(1, 2, 3, 0xea) });
  eq(app.idb.get("recent").map((r) => r.name), ["Some Game (U).gba"]);
});
