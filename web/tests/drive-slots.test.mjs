// Drive sync of the 9 save-state slots + their thumbnail/timestamp metadata.
// Full round-trip through the REAL collectLocalBackupEntries → groupDriveFiles
// → gdriveRestoreGame from web/index.js, proving:
//   - slot metadata ("statemeta:...") is collected for backup (it used to be
//     silently dropped because it doesn't start with "state:");
//   - numbered slots fold into the base game (no phantom ":slotN" game rows);
//   - every present slot's state + metadata is restored under the right keys,
//     with the metadata objects decoded back intact.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, bytesRes, jsonRes, u8, eq, settle } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";

// Simulate "upload to Drive": turn collectLocalBackupEntries output (the eager
// save/state/meta blobs; lazy ROM entries are out of scope here) into a Drive
// file listing plus an id -> bytes download map.
const uploadToFakeDrive = (entries) => {
  const files = [];
  const blobs = {};
  let id = 0;
  for (const e of entries) {
    if (!e.bytes) continue; // lazy ROM entry — not exercised in this test
    const fid = "f" + id++;
    files.push({
      id: fid, name: e.name, size: String(e.bytes.length),
      modifiedTime: "2026-01-01T00:00:00Z",
    });
    blobs[fid] = e.bytes;
  }
  return { files, blobs };
};

const wireDownloads = (app, blobs) => {
  app.api.gdriveToken = "test-token";
  app.setFetch(async (url) => {
    const m = String(url).match(/\/drive\/v3\/files\/([^/?]+)\?alt=media/);
    if (m) {
      if (!(m[1] in blobs)) throw new Error("no such file: " + m[1]);
      return bytesRes(blobs[m[1]]);
    }
    if (String(url).startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: [] });
    }
    throw new Error("unexpected request: " + url);
  });
};

const fakeBtn = () => ({ disabled: false, textContent: "", disarm() {} });

const NAME = "Pokemon.gba";

// Local state on the "source" device: a battery save, slot 0 (legacy key),
// and slots 3 and 7 — each state blob paired with a { thumb, ts } meta object.
const seedSource = (app) => {
  app.idb.set("save:" + NAME, u8(1, 2, 3));
  app.idb.set("state:" + NAME, u8(10));
  app.idb.set("statemeta:" + NAME, { thumb: "data:img,0", ts: 1000 });
  app.idb.set("state:" + NAME + ":slot3", u8(30, 31));
  app.idb.set("statemeta:" + NAME + ":slot3", { thumb: "data:img,3", ts: 3000 });
  app.idb.set("state:" + NAME + ":slot7", u8(70, 71, 72));
  app.idb.set("statemeta:" + NAME + ":slot7", { thumb: "data:img,7", ts: 7000 });
};

test("collectLocalBackupEntries captures slot states AND their metadata", async () => {
  const app = await loadApp();
  seedSource(app);

  const entries = await app.api.collectLocalBackupEntries();
  const names = entries.map((e) => e.name).sort();
  eq(names, [
    "save:Pokemon.gba",
    "state:Pokemon.gba", "state:Pokemon.gba:slot3", "state:Pokemon.gba:slot7",
    "statemeta:Pokemon.gba", "statemeta:Pokemon.gba:slot3",
    "statemeta:Pokemon.gba:slot7",
  ], "statemeta:* is no longer dropped from backup");

  // Metadata is JSON-encoded to bytes so it rides the byte-blob upload path.
  const meta3 = entries.find((e) => e.name === "statemeta:Pokemon.gba:slot3");
  assert.ok(meta3.bytes instanceof Uint8Array);
  eq(JSON.parse(new TextDecoder().decode(meta3.bytes)),
    { thumb: "data:img,3", ts: 3000 });
});

test("battery save + state slots 0/3/7 + metadata round-trip backup→parse→restore", async () => {
  // --- source device: collect + "upload" ---
  const src = await loadApp();
  seedSource(src);
  const { files, blobs } = uploadToFakeDrive(await src.api.collectLocalBackupEntries());

  // --- parse/group: exactly one game row, no phantom ":slotN" rows ---
  const groups = src.api.groupDriveFiles(files);
  eq(groups.map((g) => g.game), [NAME], "no phantom :slotN game rows");
  const f = groups[0].files;
  eq(Object.keys(f).sort(), [
    "save", "state", "state:3", "state:7",
    "statemeta", "statemeta:3", "statemeta:7",
  ]);

  // --- restore onto a fresh device ---
  const dst = await loadApp();
  wireDownloads(dst, blobs);
  const btn = fakeBtn();
  await dst.api.gdriveRestoreGame(groups[0], btn);
  await settle();

  // Battery save + every present slot's state came back under the exact keys.
  eq(dst.idb.get("save:" + NAME), u8(1, 2, 3));
  eq(dst.idb.get("state:" + NAME), u8(10));
  eq(dst.idb.get("state:" + NAME + ":slot3"), u8(30, 31));
  eq(dst.idb.get("state:" + NAME + ":slot7"), u8(70, 71, 72));

  // Metadata objects decoded back intact (NOT left as raw bytes).
  eq(dst.idb.get("statemeta:" + NAME), { thumb: "data:img,0", ts: 1000 });
  eq(dst.idb.get("statemeta:" + NAME + ":slot3"), { thumb: "data:img,3", ts: 3000 });
  eq(dst.idb.get("statemeta:" + NAME + ":slot7"), { thumb: "data:img,7", ts: 7000 });

  // Slots that were never saved stay empty.
  assert.equal(dst.idb.get("state:" + NAME + ":slot1"), undefined);
  assert.equal(dst.idb.get("statemeta:" + NAME + ":slot5"), undefined);

  assert.equal(btn.textContent, "Restored");
  assert.match(dst.toasts.at(-1), /Restored Pokemon\.gba from Drive/);
});
