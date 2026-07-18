// Drive backup: the real collectLocalBackupEntries / gdriveBackup /
// driveUploadFile from web/index.js against a fake fetch that plays the
// Drive v3 API. Verifies the create-vs-update paths, the ROM size-skip,
// overwrite-always for saves, and that no delete is ever issued.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, u8, eq } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";
const UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files";

// Fake Drive backend: `remote` is the file listing; records uploads.
const wireDrive = (app, remote) => {
  const ops = { creates: [], updates: [] };
  let nextId = 100;
  app.api.gdriveToken = "test-token";
  app.setFetch(async (url, opts = {}) => {
    const method = opts.method || "GET";
    if (url.startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: remote });
    }
    if (url.startsWith(UPLOAD_URL + "?uploadType=multipart") && method === "POST") {
      // Multipart create: metadata JSON part carries the file name
      const text = await new Response(opts.body).text();
      const meta = JSON.parse(text.slice(text.indexOf("{"), text.indexOf("\r\n--", text.indexOf("{"))));
      const bodyStart = text.indexOf("\r\n\r\n", text.indexOf("octet-stream")) + 4;
      const size = text.lastIndexOf("\r\n--") - bodyStart;
      ops.creates.push({ name: meta.name, size, parents: meta.parents });
      return jsonRes({ id: "new" + nextId++ });
    }
    if (url === FILES_URL && method === "POST") {
      // Bare metadata create (big-file path)
      const meta = JSON.parse(opts.body);
      ops.creates.push({ name: meta.name, size: 0, parents: meta.parents, empty: true });
      return jsonRes({ id: "empty" + nextId++ });
    }
    if (url.startsWith(UPLOAD_URL + "/") && method === "PATCH") {
      const id = url.slice((UPLOAD_URL + "/").length, url.indexOf("?"));
      const buf = await new Response(opts.body).arrayBuffer();
      ops.updates.push({ id, size: buf.byteLength });
      return jsonRes({ id });
    }
    throw new Error("unexpected Drive request: " + method + " " + url);
  });
  return ops;
};

test("collectLocalBackupEntries: eager saves/states first, lazy ROMs from recents only", async () => {
  const app = await loadApp();
  app.idb.set("save:A.gba", u8(1, 2));
  app.idb.set("save:A.gba-p2", u8(3));
  app.idb.set("state:A.gba", u8(4));
  app.idb.set("save:Empty.gba", u8());              // skipped: empty
  app.idb.set("save:Buf.gba", u8(9).buffer);        // ArrayBuffer converted
  app.idb.set("save:Orphan.gb", u8(5));             // no recents entry: still backed up
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(7, 7) });
  app.idb.set("rom:Loose.gba", { name: "Loose.gba", data: u8(8) }); // orphan rom: NOT backed up
  app.idb.set("recent", [{ name: "A.gba", ts: 2 }, { name: "Gone.gba", ts: 1 }]);

  const entries = await app.api.collectLocalBackupEntries();
  const names = entries.map((e) => e.name);
  eq(names, [
    "save:A.gba", "save:A.gba-p2", "save:Buf.gba", "save:Orphan.gb", "state:A.gba",
    "rom:A.gba", "rom:Gone.gba",
  ]);
  // Saves/states carry bytes; ROM entries are lazy
  for (const e of entries) {
    if (e.rom) {
      assert.equal(e.bytes, undefined);
      assert.equal(typeof e.load, "function");
    } else {
      assert.ok(e.bytes.length > 0);
    }
  }
  // Lazy load pulls real bytes; a missing rom: record yields null (upload skips it)
  eq(await entries.find((e) => e.name === "rom:A.gba").load(), u8(7, 7));
  assert.equal(await entries.find((e) => e.name === "rom:Gone.gba").load(), null);
});

test("gdriveBackup to empty Drive creates every file via multipart", async () => {
  const app = await loadApp();
  app.idb.set("save:A.gba", u8(1, 2, 3));
  app.idb.set("state:A.gba", u8(4));
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(5, 6) });
  app.idb.set("recent", [{ name: "A.gba", ts: 1 }]);
  const ops = wireDrive(app, []);

  await app.api.gdriveBackup();
  eq(ops.creates.map((c) => c.name).sort(), ["rom:A.gba", "save:A.gba", "state:A.gba"]);
  for (const c of ops.creates) eq(c.parents, ["appDataFolder"]);
  assert.equal(ops.updates.length, 0);
  assert.match(app.toasts.at(-1), /Backed up 3 files/);
});

test("gdriveBackup overwrites existing saves always, but skips same-size ROMs", async () => {
  const app = await loadApp();
  app.idb.set("save:A.gba", u8(1, 2, 3));
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(5, 6) });
  app.idb.set("recent", [{ name: "A.gba", ts: 1 }]);
  const ops = wireDrive(app, [
    { id: "s1", name: "save:A.gba", size: "3" },   // identical size — still overwritten
    { id: "r1", name: "rom:A.gba", size: "2" },    // same size — skipped ("immutable")
  ]);

  await app.api.gdriveBackup();
  assert.equal(ops.creates.length, 0);
  eq(ops.updates, [{ id: "s1", size: 3 }]);
  assert.match(app.toasts.at(-1), /Backed up 1 file/);
});

test("gdriveBackup overwrites a Drive ROM whose size differs (name collision loses)", async () => {
  const app = await loadApp();
  app.idb.set("rom:X.gba", { name: "X.gba", data: u8(1, 2, 3, 4) });
  app.idb.set("recent", [{ name: "X.gba", ts: 1 }]);
  // Drive holds a DIFFERENT 2-byte "X.gba" (e.g. from another device)
  const ops = wireDrive(app, [{ id: "r9", name: "rom:X.gba", size: "2" }]);

  await app.api.gdriveBackup();
  // No timestamp comparison, no rename: the other device's ROM is replaced in place
  eq(ops.updates, [{ id: "r9", size: 4 }]);
});

test("gdriveBackup sends big ROMs as metadata-create + content PATCH", async () => {
  const app = await loadApp();
  const big = new Uint8Array(4 * 1024 * 1024 + 1);
  app.idb.set("rom:Big.gba", { name: "Big.gba", data: big });
  app.idb.set("recent", [{ name: "Big.gba", ts: 1 }]);
  const ops = wireDrive(app, []);

  await app.api.gdriveBackup();
  eq(ops.creates, [{ name: "rom:Big.gba", size: 0, parents: ["appDataFolder"], empty: true }]);
  assert.equal(ops.updates.length, 1);
  assert.equal(ops.updates[0].size, big.length);
});

test("gdriveBackup never deletes: local deletions leave stale Drive files", async () => {
  const app = await loadApp();
  // Everything local was deleted; Drive still has old files
  const ops = wireDrive(app, [
    { id: "s1", name: "save:Deleted.gba", size: "8" },
    { id: "r1", name: "rom:Deleted.gba", size: "100" },
  ]);
  await app.api.gdriveBackup();
  assert.equal(ops.creates.length + ops.updates.length, 0);
  assert.equal(app.fetchCalls.filter((c) => c.method === "DELETE").length, 0);
  // ...and there is no DELETE code path at all in any recorded traffic
  assert.match(app.toasts.at(-1), /Everything is already on Drive/);
});

test("gdriveBackup skips empty saves and missing ROM records", async () => {
  const app = await loadApp();
  app.idb.set("save:A.gba", u8());                      // empty — filtered at collect
  app.idb.set("recent", [{ name: "Evicted.gba", ts: 1 }]); // rom: record missing
  const ops = wireDrive(app, []);
  await app.api.gdriveBackup();
  assert.equal(ops.creates.length + ops.updates.length, 0);
});
