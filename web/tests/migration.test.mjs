// Migration paths: localStorage -> IndexedDB, and the old single-record
// "recent" format -> per-ROM records. Runs the real migrateFromLocalStorage /
// migrateRecentFormat from web/index.js.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq } from "./helpers.mjs";

const b64 = (bytes) => Buffer.from(bytes).toString("base64");

test("migrateFromLocalStorage moves bios, roms, and saves into IndexedDB", async () => {
  const app = await loadApp({
    localStorageSeed: {
      dingbat_bios: b64([1, 2, 3]),
      dingbat_bios_name: "gba_bios.bin",
      dingbat_gbc_bootrom: b64([9, 9]),
      dingbat_recent_roms: JSON.stringify([
        { name: "A.gba", data: b64([10, 11]) },
        { name: "B.gb", data: b64([12]) },
      ]),
      dingbat_saves: JSON.stringify({ "A.gba": b64([77, 78]) }),
    },
  });
  await app.api.migrateFromLocalStorage();

  eq(app.idb.get("bios:gba"), { name: "gba_bios.bin", data: u8(1, 2, 3) });
  // No stored name for the bootrom -> null name recorded
  eq(app.idb.get("bios:gbc"), { name: null, data: u8(9, 9) });
  eq(app.idb.get("rom:A.gba"), { name: "A.gba", data: u8(10, 11) });
  eq(app.idb.get("rom:B.gb"), { name: "B.gb", data: u8(12) });
  eq(app.idb.get("save:A.gba"), u8(77, 78));

  const recent = app.idb.get("recent");
  eq(recent.map((r) => r.name), ["A.gba", "B.gb"]);
  // Order encodes recency: first entry has the larger timestamp
  assert.ok(recent[0].ts > recent[1].ts);

  // localStorage source keys are consumed
  for (const k of ["dingbat_bios", "dingbat_bios_name", "dingbat_gbc_bootrom",
                   "dingbat_recent_roms", "dingbat_saves"]) {
    assert.equal(app.localStorage.getItem(k), null, k + " should be removed");
  }
});

test("migrateFromLocalStorage is a no-op on second run", async () => {
  const app = await loadApp({
    localStorageSeed: { dingbat_saves: JSON.stringify({ "A.gba": b64([1]) }) },
  });
  await app.api.migrateFromLocalStorage();
  const snapshot = new Map(app.idb);
  await app.api.migrateFromLocalStorage();
  eq([...app.idb.entries()], [...snapshot.entries()]);
});

test("migrateRecentFormat converts inline rom bytes to per-ROM records", async () => {
  const app = await loadApp();
  const art = { blob: "fake-art" };
  app.idb.set("recent", [
    { name: "A.gba", data: u8(1, 2), art },
    { name: "B.gb", data: u8(3) },
  ]);
  await app.api.migrateRecentFormat();

  eq(app.idb.get("rom:A.gba"), { name: "A.gba", data: u8(1, 2) });
  eq(app.idb.get("art:A.gba"), art);
  eq(app.idb.get("rom:B.gb"), { name: "B.gb", data: u8(3) });
  const meta = app.idb.get("recent");
  eq(meta.map((r) => r.name), ["A.gba", "B.gb"]);
  for (const r of meta) {
    assert.equal(r.data, undefined);
    assert.equal(typeof r.ts, "number");
  }
});

test("migrateRecentFormat leaves new-format metadata untouched (idempotent)", async () => {
  const app = await loadApp();
  const meta = [{ name: "A.gba", ts: 1234 }];
  app.idb.set("recent", meta);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1) });
  await app.api.migrateRecentFormat();
  // Early-returns: identical object, no rewrite with new timestamps
  eq(app.idb.get("recent"), [{ name: "A.gba", ts: 1234 }]);
});

test("migrateRecentFormat recovers from an interrupted earlier run", async () => {
  const app = await loadApp();
  // Interrupted run: rom:/art: records were written but the "recent" index
  // still holds the old inline format.
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1, 2) });
  app.idb.set("recent", [{ name: "A.gba", data: u8(1, 2), ts: 55 }]);
  await app.api.migrateRecentFormat();
  eq(app.idb.get("rom:A.gba"), { name: "A.gba", data: u8(1, 2) });
  eq(app.idb.get("recent"), [{ name: "A.gba", ts: 55 }]);
});
