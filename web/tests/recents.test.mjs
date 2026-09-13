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
  // The harness reports a 4 GB quota, so the line sits at 2 GB.
  assert.equal(await app.api.romBudget(), 2 * 1024 * 1024 * 1024);
  for (let i = 0; i < 25; i++) await app.api.addRecentRom(`Game${i}.gba`, u8(i, i));
  assert.equal(app.idb.get("recent").length, 25);
  for (let i = 0; i < 25; i++) {
    assert.ok(app.idb.get(`rom:Game${i}.gba`), `Game${i} keeps its file`);
  }
});

const GB = 1024 * 1024 * 1024;

test("the budget is a share of what the browser says it will allow", async () => {
  const app = await loadApp();
  const at = async (quota) => {
    app.state.storageQuota = quota;
    app.runIn("quotaBytes = 0"); // the reading is cached for a minute
    return app.api.romBudget();
  };
  assert.equal(await at(20 * GB), 10 * GB, "half the allowance");
  assert.equal(await at(300 * 1024 * 1024), app.api.ROM_BUDGET_MIN,
    "a nearly-full disk still keeps a few games rather than none, the quota\n" +
    "    path taking over from there");
  assert.equal(await at(900 * GB), app.api.ROM_BUDGET_MAX,
    "and a large one is not hoarded just because it would be allowed");
  assert.equal(app.api.ROM_BUDGET_SHARE, 0.5);
});

test("the storage line stays away until the room is nearly gone", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("A.gba", u8(1));
  const line = () => app.elements.get("storage-info").textContent;

  app.state.storageQuota = 10 * GB; // 12 KB used: nothing to say
  await app.api.updateStorageInfo();
  assert.equal(line(), "", "no figure in the head when there is room");

  const at = async (pct) => {
    app.state.storageQuota = Math.round(12345 / pct);
    await app.api.updateStorageInfo();
    const el = app.elements.get("storage-info");
    return { text: el.textContent, warn: el.className.includes("warn") };
  };

  let r = await at(0.85);
  assert.match(r.text, /^12\.1 KB \/ .* used$/, "the figure, and nothing else");
  assert.equal(r.warn, false, "at 85% it is a label, not an alarm");

  r = await at(0.92);
  assert.equal(r.warn, true, "at 92% the same words in the colour that means it");
  assert.doesNotMatch(r.text, /nearly full/, "still no explanation needed");

  r = await at(0.97);
  assert.equal(r.text,
    "Storage nearly full. Old ROMs are removed to make room. Saves are kept.",
    "at 97% it says what goes and, more to the point, what does not");
  assert.doesNotMatch(r.text, /\d/, "and drops the figures, which decide nothing here");
  assert.equal(r.warn, true);
});

test("a smaller allowance means fewer files kept", async () => {
  const app = await loadApp();
  app.state.storageQuota = 6 * GB; // a 3 GB budget
  const all = ["A.gba", "B.gba", "C.gba", "D.gba"];
  for (const n of all) await app.api.addRecentRom(n, u8(1, 1));
  for (const n of all) await app.api.noteRomSize(n, GB);
  app.runIn("quotaBytes = 0");
  await app.api.bumpRecentIndex("D.gba");

  assert.ok(app.idb.get("rom:B.gba"), "three 1 GB games fit a 3 GB budget");
  assert.equal(app.idb.get("rom:A.gba"), undefined, "the fourth does not");
});

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

// What the line may never take, however far over budget the device is.

const enrolled = (app, queueUp = []) => {
  app.api.syncState =
    { queueUp, queueDel: [], queueRen: [], tomb: [], ren: [], sigs: {}, rmt: {},
      connected: false, acct: "acct-1" };
};

test("the running game is never evicted, however far down the index it sinks",
  async () => {
    const app = await loadApp();
    const all = ["Playing.gba", "New0.gba", "New1.gba", "New2.gba"];
    for (const n of all) await app.api.addRecentRom(n, u8(1, 1));
    for (const n of all) await app.api.noteRomSize(n, GB);
    // Downloads land in front of it, so by the index it is the oldest thing
    // here - but it is the game on screen.
    app.api.currentOriginalName = "Playing.gba";
    await app.api.bumpRecentIndex("New2.gba");

    assert.ok(app.idb.get("rom:Playing.gba"), "the game being played kept its file");
    assert.equal(app.idb.get("rom:New0.gba"), undefined, "something else paid");
  });

test("a file the account has not been sent yet is not what the budget takes",
  async () => {
    const app = await loadApp();
    const all = ["Old.gba", "A.gba", "B.gba", "C.gba"];
    for (const n of all) await app.api.addRecentRom(n, u8(1, 1));
    for (const n of all) await app.api.noteRomSize(n, GB);
    enrolled(app, ["rom:Old.gba"]); // queued, never uploaded
    await app.api.bumpRecentIndex("C.gba");

    assert.ok(app.idb.get("rom:Old.gba"),
      "giving this up before Drive has it would leave no copy anywhere");
    assert.equal(app.idb.get("rom:A.gba"), undefined, "a sent file paid instead");
  });

test("with only unsent files left, pressure takes one rather than lose the write",
  async () => {
    const app = await loadApp();
    for (const n of ["A.gba", "B.gba"]) await app.api.addRecentRom(n, u8(1));
    enrolled(app, ["rom:A.gba", "rom:B.gba"]);
    fullUntilFreed(app, "rom:C.gba", 1);
    await app.api.addRecentRom("C.gba", u8(3, 3));
    await settle();

    eq(app.idb.get("rom:C.gba"), { name: "C.gba", data: u8(3, 3) });
    assert.equal(app.idb.get("rom:A.gba"), undefined,
      "losing a copy the person can find again beats losing the write");
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
