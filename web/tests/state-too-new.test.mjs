// A save state from a newer dingbat (StateRejectKind srkTooNew): the core
// reads every older revision, so the only refusal a format bump leaves is
// a newer state on an older build, and its cure is the update. The refusal
// probes for a newer build, says what it is doing, saves where the game is,
// records what to load again, and runs the Update; after the reload the
// load is offered again, one tap. Where there's nothing to update to it
// says why instead.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const MAGIC = [..."DGBSTATE"].map((c) => c.charCodeAt(0));
const SRK_TOO_NEW = 4;
const SRK_CORRUPT = 6;

const settle = async (n = 30) => {
  for (let i = 0; i < n; i++) await new Promise((r) => setTimeout(r, 0));
};

const realState = (fill = 0) => {
  const bytes = new Uint8Array(64).fill(fill);
  bytes.set(MAGIC, 0);
  return bytes;
};

// A core that refuses every state with `kind`, and hands out `snap` when
// asked for its own.
const refusingModule = (kind, snap = realState(9)) => {
  const memory = { buffer: new ArrayBuffer(4096) };
  new Uint8Array(memory.buffer, 1024, snap.length).set(snap);
  return {
    _malloc: () => 8,
    _free() {},
    _wasm_load_state: () => 0,
    _wasm_state_error_kind: () => kind,
    _wasm_state_error: () => 1,
    _wasm_state_size: () => snap.length,
    _wasm_state_data: () => 1024,
    UTF8ToString: () => "",
    memory,
  };
};

const text = (s) => ({ ok: true, status: 200, text: async () => s, json: async () => ({}) });

// The running build `current`; the origin serving `latest`, its sw.js
// stamped `deployed`.
const builds = (app, { current, latest, deployed = latest }) => {
  app.setFetch(async (url, opts = {}) => {
    const u = String(url);
    if (u === "version.txt") return text(opts.cache === "no-store" ? latest : current);
    if (u === "sw.js") return text(`const CACHE_VERSION = "${deployed}";`);
    return { ok: false, status: 404, text: async () => "", json: async () => ({}) };
  });
};

const inGame = async (name = "A.gba") => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  app.runIn(`currentRomName = 'rom.gba'; currentOriginalName = '${name}'`);
  return app;
};

test("an import from a newer dingbat updates, saying so, and keeps the state to load after", async () => {
  const app = await inGame();
  builds(app, { current: "aaa1111", latest: "bbb2222" });
  app.sandbox.Module = refusingModule(SRK_TOO_NEW);
  const bytes = realState(3);
  app.api.applyImportedState(bytes);
  await settle();
  assert.match(app.toasts.at(-1), /newer version of dingbat\. Updating dingbat/);
  const rec = app.idb.get("updateretry");
  assert.ok(rec, "the retry is recorded before the reload");
  assert.equal(rec.kind, "bytes");
  assert.equal(rec.name, "A.gba");
  assert.equal(rec.from, "aaa1111");
  assert.deepEqual([...rec.bytes], [...bytes]);
  assert.equal(app.runIn("paused"), true, "the game waits out the download");
  // No service worker here: applyUpdate's clean-slate path is the reload.
  assert.equal(app.state.reloads, 1);
  assert.equal(app.elements.get("update-label").textContent, "Updating…");
  // Where the game was went down first, for the retry's resume.
  assert.ok(app.idb.get("stateauto:A.gba"), "the session was saved before the reload");
});

test("a slot from a newer dingbat records the slot, not its bytes", async () => {
  const app = await inGame();
  builds(app, { current: "aaa1111", latest: "bbb2222" });
  app.sandbox.Module = refusingModule(SRK_TOO_NEW);
  app.idb.set("state:A.gba:slot3", realState(5));
  await app.runIn("loadFromSlot(3)");
  await settle();
  const rec = app.idb.get("updateretry");
  assert.equal(rec?.kind, "slot");
  assert.equal(rec.slot, 3);
  assert.equal(rec.bytes, undefined);
  assert.equal(app.state.reloads, 1);
});

test("a refused session resume holds the session: the boot is never snapshotted over it", async () => {
  const app = await inGame();
  // Offline: no update happens, and the hold must still stand.
  app.sandbox.Module = refusingModule(SRK_TOO_NEW, realState(0xee));
  const newer = { bytes: realState(1), ts: 1, saveSig: null, by: "other", dev: "Mac" };
  app.idb.set("stateauto:A.gba", newer);
  app.runIn("sessionMoved = true");
  app.runIn("refuseState(new Uint8Array([" + [...realState(1)] + "]), { kind: 'session' })");
  await app.runIn("persistAutoState()");
  await settle();
  assert.equal(app.idb.get("stateauto:A.gba"), newer, "the newer session is untouched");
  assert.match(app.toasts.at(-1), /Connect to the internet/);
  assert.equal(app.state.reloads, 0);
  assert.equal(app.idb.get("updateretry"), undefined);
});

test("the same build on the origin: says the newer one isn't here, no reload", async () => {
  const app = await inGame();
  builds(app, { current: "dev", latest: "dev" });
  app.sandbox.Module = refusingModule(SRK_TOO_NEW);
  app.api.applyImportedState(realState());
  await settle();
  assert.match(app.toasts.at(-1), /isn't available here yet/);
  assert.equal(app.state.reloads, 0);
  assert.equal(app.idb.get("updateretry"), undefined);
});

test("an update still propagating (sw.js behind version.txt): try again soon, no reload", async () => {
  const app = await inGame();
  builds(app, { current: "aaa1111", latest: "bbb2222", deployed: "aaa1111" });
  app.sandbox.Module = refusingModule(SRK_TOO_NEW);
  app.api.applyImportedState(realState());
  await settle();
  assert.match(app.toasts.at(-1), /still on its way/);
  assert.equal(app.state.reloads, 0);
});

test("other refusals never start an update", async () => {
  const app = await inGame();
  builds(app, { current: "aaa1111", latest: "bbb2222" });
  app.sandbox.Module = refusingModule(SRK_CORRUPT);
  await settle(); // the boot's own update check fetches too
  const fetches = app.fetchCalls.length;
  app.api.applyImportedState(realState());
  await settle();
  assert.match(app.toasts.at(-1), /damaged/);
  assert.equal(app.state.reloads, 0);
  assert.equal(app.fetchCalls.length, fetches, "no build probe");
});

test("linked, a newer state keeps the plain message: a reload would drop the link", async () => {
  const app = await inGame();
  builds(app, { current: "aaa1111", latest: "bbb2222" });
  app.sandbox.Module = refusingModule(SRK_TOO_NEW);
  app.runIn("linkMode = true");
  app.api.applyImportedState(realState());
  await settle();
  assert.match(app.toasts.at(-1), /Reload the page to update/);
  assert.equal(app.state.reloads, 0);
});

test("after the update: the load is offered once, one tap", async () => {
  const app = await loadApp();
  builds(app, { current: "bbb2222", latest: "bbb2222" });
  app.idb.set("updateretry", { kind: "slot", slot: 2, name: "A.gba", from: "aaa1111", ts: Date.now() });
  await app.runIn("offerStateRetry()");
  assert.match(app.toasts.at(-1), /dingbat updated — that save state can load now/);
  const pill = app.document.getElementById("toast").children
    .find((c) => c.classList.contains("has-action"));
  assert.ok(pill, "the offer has its action");
  assert.equal(app.idb.get("updateretry"), undefined, "offered once");
});

test("after the update, a session's offer says Resume", async () => {
  const app = await loadApp();
  builds(app, { current: "bbb2222", latest: "bbb2222" });
  app.idb.set("updateretry", { kind: "session", name: "A.gba", from: "aaa1111", ts: Date.now() });
  await app.runIn("offerStateRetry()");
  assert.match(app.toasts.at(-1), /your session can load now/);
});

test("a reload that didn't change the build says the update failed", async () => {
  const app = await loadApp();
  builds(app, { current: "aaa1111", latest: "bbb2222" });
  app.idb.set("updateretry", { kind: "session", name: "A.gba", from: "aaa1111", ts: Date.now() });
  await app.runIn("offerStateRetry()");
  assert.match(app.toasts.at(-1), /couldn't update/);
  assert.equal(app.idb.get("updateretry"), undefined);
});

test("a stale retry (an update that never landed) is dropped silently", async () => {
  const app = await loadApp();
  builds(app, { current: "bbb2222", latest: "bbb2222" });
  app.idb.set("updateretry", { kind: "session", name: "A.gba", from: "aaa1111",
                               ts: Date.now() - 60 * 60 * 1000 });
  const before = app.toasts.length;
  await app.runIn("offerStateRetry()");
  assert.equal(app.toasts.length, before);
  assert.equal(app.idb.get("updateretry"), undefined);
});
