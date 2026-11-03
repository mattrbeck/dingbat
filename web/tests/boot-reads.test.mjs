// The boot's settings reads come out of IndexedDB in one transaction
// (index.js prefetchBootReads): initStorage's reads before the library's
// first render are served from it, each once, and a write in between wins.

import { test } from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

// Every get the fake IndexedDB answers, in order, with the transaction it
// came in on (the fake makes one per db.transaction call).
const watchGets = (app) => {
  const gets = [];
  let n = 0;
  const watch = (db) => {
    const open = db.transaction;
    db.transaction = (...a) => {
      const tx = ++n;
      const t = open(...a);
      const store = t.objectStore;
      t.objectStore = (...s) => {
        const os = store(...s);
        const get = os.get;
        os.get = (key) => { gets.push({ key, tx }); return get(key); };
        return os;
      };
      return t;
    };
  };
  watch(app.runIn("db"));
  // And a database opened from here (initStorage opens its own).
  const idb = app.sandbox.indexedDB;
  const openDb = idb.open;
  idb.open = (...a) => {
    const req = openDb.apply(idb, a);
    let done;
    Object.defineProperty(req, "onsuccess", {
      get: () => done,
      set: (fn) => { done = () => { watch(req.result); fn(); }; },
    });
    return req;
  };
  return gets;
};

test("initStorage's reads before the first render come from one transaction", async () => {
  const app = await loadApp();
  const keys = [...app.runIn("BOOT_READ_KEYS")];
  const gets = watchGets(app);
  await app.runIn("initStorage()");
  // (The migrations before it read "recent" on their own.)
  const prefetchTx = gets.find((g) => g.key === keys[0]).tx;
  assert.deepEqual(gets.filter((g) => g.tx === prefetchTx).map((g) => g.key), keys);
  // Read on their own after it: only "recent" again (each prefetched read
  // is served once) and per-game records ("bios:gba", "frame:<game>") - so
  // a setting initStorage reads that the list misses shows up here.
  const own = gets.filter((g) => g.tx > prefetchTx && g.key !== "recent" && !String(g.key).includes(":"));
  assert.deepEqual(own.map((g) => g.key), [], "a boot read missing from BOOT_READ_KEYS");
  assert.equal(app.runIn("bootReads"), null, "dropped once the first render has its list");
});

test("a prefetched read is served once, and a write before it wins", async () => {
  const app = await loadApp();
  app.idb.set("runahead", 1);
  app.idb.set("video", { a: 1 });
  await app.runIn("prefetchBootReads()");
  await app.api.dbPut("video", { a: 2 });
  assert.deepEqual(await app.api.dbGet("video"), { a: 2 }, "the write, not the prefetch");
  const gets = watchGets(app);
  assert.equal(await app.api.dbGet("runahead"), 1);
  assert.deepEqual(gets, [], "served from the prefetch");
  app.idb.set("runahead", 3);
  assert.equal(await app.api.dbGet("runahead"), 3, "the second read goes to the store");
  await app.runIn("dbDelete('audio')");
  assert.equal(app.runIn("bootReads.has('audio')"), false);
});
