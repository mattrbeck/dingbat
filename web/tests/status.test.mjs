// status.json: announcements shown once each, and a required update that
// only blocks when the live build meets it and can be fetched.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const settle = async (n = 30) => {
  for (let i = 0; i < n; i++) await new Promise((r) => setTimeout(r, 0));
};

const text = (s) => ({ ok: true, status: 200, text: async () => s, json: async () => JSON.parse(s) });
const missing = { ok: false, status: 404, text: async () => "", json: async () => ({}) };

const OLD = "2026-11-01T00:00:00Z";
const FIX = "2026-11-10T00:00:00Z";
const NEW = "2026-11-12T00:00:00Z";

// The running build `current` (built `built`), and the origin serving
// `status`, a live build `latest` built `liveBuilt`, its sw.js `deployed`.
const serve = (app, { status, built = OLD, current = "aaa1111", latest = "bbb2222",
                      deployed = latest, liveBuilt = NEW }) => {
  app.runIn(`BUILD_TIME = ${JSON.stringify(built)}; statusCheckedAt = 0; requiredShown = false`);
  app.setFetch(async (url, opts = {}) => {
    const u = String(url);
    if (u === "status.json") return status === undefined ? missing : text(JSON.stringify(status));
    if (u === "version.txt") return text(opts.cache === "no-store" ? latest : current);
    if (u === "sw.js") return text(`const CACHE_VERSION = "${deployed}";`);
    if (u === "build-id.txt") return text(`0123456789abcdef ${latest} ${liveBuilt}`);
    return missing;
  });
};

// A core whose own state is a 64-byte DGBSTATE image.
const snapshotModule = () => {
  const memory = { buffer: new ArrayBuffer(4096) };
  new Uint8Array(memory.buffer, 1024, 8).set([..."DGBSTATE"].map((c) => c.charCodeAt(0)));
  return {
    _malloc: () => 8, _free() {},
    _wasm_state_size: () => 64, _wasm_state_data: () => 1024,
    UTF8ToString: () => "", memory,
  };
};

const modalOpen = (app) => app.elements.get("required-modal").classList.contains("open");

test("an announcement shows once, then never again in this browser", async () => {
  const app = await loadApp();
  serve(app, { status: { announcements: [{ id: "a1", text: "Online link is down tonight" }] } });
  await app.runIn("checkStatus()");
  assert.equal(app.toasts.filter((t) => /Online link is down/.test(t)).length, 1);
  await app.runIn("checkStatus()");
  assert.equal(app.toasts.filter((t) => /Online link is down/.test(t)).length, 1, "seen ids are remembered");
  assert.deepEqual(JSON.parse(app.localStorage.getItem("dingbat_seen_announcements")), ["a1"]);
});

test("platforms, the from/until window and builtBefore pick who sees an announcement", async () => {
  const app = await loadApp();
  const now = Date.now();
  const iso = (ms) => new Date(now + ms).toISOString();
  serve(app, {
    built: FIX,
    status: {
      announcements: [
        { id: "ios", text: "iOS only", platforms: ["ios"] },
        { id: "later", text: "Not yet", from: iso(3600e3) },
        { id: "over", text: "Too late", until: iso(-3600e3) },
        { id: "older", text: "Old builds only", builtBefore: OLD },
        { id: "both", text: "Web and iOS", platforms: ["web", "ios"], until: iso(3600e3) },
        { id: "fixed", text: "Builds before the fix", builtBefore: NEW },
      ],
    },
  });
  await app.runIn("checkStatus()");
  const shown = app.toasts.join("\n");
  assert.match(shown, /Web and iOS/);
  assert.match(shown, /Builds before the fix/);
  assert.doesNotMatch(shown, /iOS only|Not yet|Too late|Old builds only/);
});

test("a development build (no build time) sees no builtBefore announcement and is never required to update", async () => {
  const app = await loadApp();
  serve(app, {
    built: "",
    status: {
      announcements: [{ id: "b", text: "Your build has a bug", builtBefore: NEW }],
      required: { web: { minBuild: FIX } },
    },
  });
  await app.runIn("checkStatus()");
  assert.doesNotMatch(app.toasts.join("\n"), /Your build has a bug/);
  assert.equal(modalOpen(app), false);
});

test("a required update blocks with its message, and Update now saves and updates", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  app.runIn("currentRomName = 'rom.gba'; currentOriginalName = 'A.gba'");
  app.sandbox.Module = snapshotModule();
  serve(app, { status: { required: { web: { minBuild: FIX, message: "Saves can be lost on this build." } } } });
  await app.runIn("checkStatus()");
  assert.equal(modalOpen(app), true);
  assert.equal(app.elements.get("required-text").textContent, "Saves can be lost on this build.");
  assert.equal(app.runIn("paused"), true, "the game waits behind the card");
  app.elements.get("required-update").click();
  await settle();
  assert.ok(app.idb.get("stateauto:A.gba"), "the session was saved before the reload");
  assert.equal(app.state.reloads, 1);
});

test("a required update waits while the live build doesn't meet it, or isn't fetchable yet", async () => {
  for (const opts of [
    { liveBuilt: OLD },                       // minBuild ahead of every deploy
    { deployed: "aaa1111" },                  // sw.js still propagating
    { latest: "aaa1111" },                    // this is the live build
    { built: NEW },                           // this build already meets it
  ]) {
    const app = await loadApp();
    serve(app, { status: { required: { web: { minBuild: FIX } } }, ...opts });
    await app.runIn("checkStatus()");
    assert.equal(modalOpen(app), false, JSON.stringify(opts));
  }
});

test("a link session holds a required update off; offline and a broken status.json say nothing", async () => {
  const linked = await loadApp();
  linked.runIn("linkMode = true");
  serve(linked, { status: { required: { web: { minBuild: FIX } } } });
  await linked.runIn("checkStatus()");
  assert.equal(modalOpen(linked), false);

  const offline = await loadApp();
  serve(offline, {});
  await offline.runIn("checkStatus()");
  assert.equal(modalOpen(offline), false);

  const broken = await loadApp();
  broken.setFetch(async (url) => (String(url) === "status.json"
    ? { ok: true, status: 200, json: async () => { throw new SyntaxError("bad"); } } : missing));
  await broken.runIn("checkStatus()");
  assert.equal(modalOpen(broken), false);
});
