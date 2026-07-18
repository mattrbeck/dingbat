// Drive restore: the real gdriveRestoreGame from web/index.js. Saves/states
// overwrite local unconditionally; the ROM goes through addRecentRom (so the
// home grid updates without a reload) and is skipped when an identically-sized
// local copy exists.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, bytesRes, u8, eq, settle } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";

// Fake Drive download backend: id -> bytes.
const wireDownloads = (app, blobs) => {
  const downloads = [];
  app.api.gdriveToken = "test-token";
  app.setFetch(async (url) => {
    const m = String(url).match(/\/drive\/v3\/files\/([^/?]+)\?alt=media/);
    if (m) {
      downloads.push(m[1]);
      if (!(m[1] in blobs)) throw new Error("no such file: " + m[1]);
      return bytesRes(blobs[m[1]]);
    }
    if (String(url).startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: [] });
    }
    throw new Error("unexpected request: " + url);
  });
  return downloads;
};

const fakeBtn = () => ({ disabled: false, textContent: "", disarm() {} });

test("restore downloads saves+state+ROM and lands the game in recents", async () => {
  const app = await loadApp();
  const downloads = wireDownloads(app, {
    s1: u8(1, 1), s2: u8(2, 2), st: u8(3, 3), r1: u8(9, 9, 9, 9),
  });
  const group = {
    game: "A.gba",
    files: {
      save: { id: "s1", size: "2" },
      save2: { id: "s2", size: "2" },
      state: { id: "st", size: "2" },
      rom: { id: "r1", size: "4" },
    },
  };
  const btn = fakeBtn();
  await app.api.gdriveRestoreGame(group, btn);
  await settle();

  eq(app.idb.get("save:A.gba"), u8(1, 1));
  eq(app.idb.get("save:A.gba-p2"), u8(2, 2));
  eq(app.idb.get("state:A.gba"), u8(3, 3));
  eq(app.idb.get("rom:A.gba"), { name: "A.gba", data: u8(9, 9, 9, 9) });
  eq(app.idb.get("recent").map((r) => r.name), ["A.gba"]);
  eq(downloads, ["s1", "s2", "st", "r1"]);
  assert.equal(btn.textContent, "Restored");
  // The home grid refreshed without a reload
  assert.equal(app.elements.get("home-recent-wrap").hidden, false);
  assert.match(app.toasts.at(-1), /Restored A\.gba from Drive/);
});

test("restore overwrites an existing local save (no timestamp comparison)", async () => {
  const app = await loadApp();
  app.idb.set("save:A.gba", u8(42, 42)); // possibly newer local progress
  wireDownloads(app, { s1: u8(7) });
  await app.api.gdriveRestoreGame(
    { game: "A.gba", files: { save: { id: "s1", size: "1" } } }, fakeBtn());
  eq(app.idb.get("save:A.gba"), u8(7), "Drive copy wins unconditionally");
});

test("restore skips the ROM download when local bytes have the same size", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("A.gba", u8(9, 9, 9, 9));
  const downloads = wireDownloads(app, { r1: u8(1, 2, 3, 4) });
  await app.api.gdriveRestoreGame(
    { game: "A.gba", files: { rom: { id: "r1", size: "4" } } }, fakeBtn());
  eq(downloads, [], "no download issued");
  eq(app.idb.get("rom:A.gba").data, u8(9, 9, 9, 9), "local ROM kept");
});

test("restore replaces a local ROM whose size differs (name collision: Drive wins)", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("X.gba", u8(1, 2));
  wireDownloads(app, { r1: u8(5, 5, 5) });
  await app.api.gdriveRestoreGame(
    { game: "X.gba", files: { rom: { id: "r1", size: "3" } } }, fakeBtn());
  eq(app.idb.get("rom:X.gba").data, u8(5, 5, 5));
});

test("save-only restore produces an orphan save (no ROM, not in recents)", async () => {
  const app = await loadApp();
  wireDownloads(app, { s1: u8(1) });
  await app.api.gdriveRestoreGame(
    { game: "Lost.gba", files: { save: { id: "s1", size: "1" } } }, fakeBtn());
  eq(app.idb.get("save:Lost.gba"), u8(1));
  assert.equal(app.idb.get("rom:Lost.gba"), undefined);
  assert.equal(app.idb.get("recent"), undefined, "recents untouched");
  // Reachable only through the manage list, as an orphan row
  eq(await app.api.romsForManagement(), [{ name: "Lost.gba", inRecent: false }]);
});

test("a failed download surfaces as a toast and re-arms the button", async () => {
  const app = await loadApp();
  app.api.gdriveToken = "t";
  app.setFetch(async () => ({ ok: false, status: 500, json: async () => ({}), text: async () => "" }));
  const btn = fakeBtn();
  btn.disabled = true; // as the confirm flow leaves it
  await app.api.gdriveRestoreGame(
    { game: "A.gba", files: { save: { id: "s1", size: "1" } } }, btn);
  assert.match(app.toasts.at(-1), /Restore failed/);
  assert.equal(btn.disabled, false);
  assert.equal(app.idb.get("save:A.gba"), undefined);
});
