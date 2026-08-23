// storePrint writes the whole printerPhotos array back over its record, so
// boot must load the existing array or the first print wipes the rest.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const KEY = "prints";

test("photos already in storage are loaded by the BOOT path", async () => {
  const app = await loadApp();
  // Re-run the real boot sequence: calling loadPrinterPhotos() directly
  // would pass whether or not boot invokes it.
  app.idb.set(KEY, [{ ts: 1, w: 160, h: 144, png: "a", game: "g.gb" }]);
  app.runIn("printerPhotos = []");
  await app.runIn("initStorage()");
  assert.equal(app.runIn("printerPhotos.length"), 1,
    "initStorage must read the stored photos into printerPhotos");
});

test("a new print does not destroy earlier sessions' photos", async () => {
  const app = await loadApp();
  app.idb.set(KEY, [
    { ts: 1, w: 160, h: 144, png: "old-1", game: "g.gb" },
    { ts: 2, w: 160, h: 144, png: "old-2", game: "g.gb" },
  ]);
  app.runIn("printerPhotos = []");
  await app.runIn("initStorage()");
  assert.equal(app.runIn("printerPhotos.length"), 2, "two photos restored by boot");

  app.runIn(`printerPhotos.unshift({ ts: 3, w: 160, h: 144, png: "new", game: "g.gb" });`);
  await app.runIn(`dbPut("${KEY}", printerPhotos)`);
  const stored = app.idb.get(KEY);
  assert.equal(stored.length, 3, "the stored record kept the earlier photos");
  assert.deepEqual(stored.map((p) => p.png), ["new", "old-1", "old-2"]);
});
