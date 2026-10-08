// Save states are stored packed (pack_state in src/dingbat/common/serialize.nim:
// the header as it was, flagged in byte 15, the rest deflated). Slots stored
// before that are packed once at boot and sent up again; sessions are left
// for their next natural rewrite. The stand-in core "packs" by setting the
// flag and keeping the first 20 bytes.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle } from "./helpers.mjs";
import { makeDrive } from "./drivefake.mjs";

const MAGIC = [..."DGBSTATE"].map((c) => c.charCodeAt(0));
const state = (len = 64, flags = 0) => {
  const b = new Uint8Array(len);
  b.set(MAGIC, 0);
  for (let i = 32; i < len; i++) b[i] = i & 0xff;
  b[15] = flags;
  return b;
};

const boot = async () => {
  const app = await loadApp();
  app.runIn(`
    globalThis.packCalls = 0;
    Object.assign(Module, {
      _malloc: () => 64, _free: () => {},
      memory: { buffer: new ArrayBuffer(4096) },
      _wasm_pack_state: (ptr, len) => {
        packCalls++;
        const m = new Uint8Array(Module.memory.buffer);
        m.copyWithin(1024, ptr, ptr + 20);
        m[1024 + 15] |= 0x80;
        return 20;
      },
      _wasm_state_data: () => 1024,
    });
  `);
  app.setFetch(makeDrive().fetch);
  app.api.gdriveToken = "tok";
  app.api.gdriveTokenExp = Date.now() + 3600e3;
  app.api.syncState = {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], delTs: {},
    sigs: {}, rmt: {}, acct: "a1", parked: {}, connected: true, email: "e@x",
  };
  return app;
};

test("boot packs the slots stored plain, queues them up, and leaves the rest", async () => {
  const app = await boot();
  const session = { bytes: state(), ts: 1, saveSig: null };
  app.idb.set("state:A.gba", state());
  app.idb.set("state:A.gba:slot3", state(64, 0x01).buffer); // stored as an ArrayBuffer
  app.idb.set("state:B.gb", state(40, 0x80));               // packed already
  app.idb.set("stateauto:A.gba", session);
  app.idb.set("save:A.gba", new Uint8Array(64));
  app.idb.set("state:C.gba", new Uint8Array([1, 2, 3]));    // not a state at all

  const n = await app.runIn("packStoredStates()");
  assert.equal(n, 2);
  const a = app.idb.get("state:A.gba");
  assert.equal(a.length, 20);
  assert.equal(a[15] & 0x80, 0x80);
  const slot3 = app.idb.get("state:A.gba:slot3");
  assert.equal(slot3.length, 20);
  assert.equal(slot3[15], 0x81, "the thumbnail flag stays");
  assert.equal(app.idb.get("state:B.gb").length, 40);
  assert.equal(app.idb.get("stateauto:A.gba"), session, "a session is never repacked");
  assert.deepEqual(Array.from(app.idb.get("state:C.gba")), [1, 2, 3]);
  const q = app.api.syncState.queueUp;
  assert.ok(q.includes("state:A.gba") && q.includes("state:A.gba:slot3"));
  assert.ok(!q.includes("state:B.gb") && !q.includes("stateauto:A.gba"));

  await settle();
  assert.equal(await app.runIn("packStoredStates()"), 0, "once packed, boot leaves it");
});

test("isPackedState reads the flag in byte 15 of a real state only", async () => {
  const app = await loadApp();
  const is = (b) => app.runIn("isPackedState")(b);
  assert.equal(is(state(64, 0x80)), true);
  assert.equal(is(state(64, 0x03)), false);
  const notState = new Uint8Array(64);
  notState[15] = 0x80;
  assert.equal(is(notState), false);
});
