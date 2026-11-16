// status.json: announcements as toasts (once each) and home-screen banners
// (until dismissed), and required updates that only block when the live
// build meets them and can be fetched.

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
  app.runIn(`BUILD_TIME = ${JSON.stringify(built)}; statusCheckedAt = 0`);
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
const notes = (app) => app.elements.get("home-notes").children;
const noteText = (n) => n.children[0].textContent;

test("a toast announcement shows once, then never again in this browser", async () => {
  const app = await loadApp();
  serve(app, { status: { announcements: [{ id: "a1", text: "Online link is down tonight" }] } });
  await app.runIn("checkStatus()");
  assert.equal(app.toasts.filter((t) => /Online link is down/.test(t)).length, 1);
  await app.runIn("checkStatus()");
  assert.equal(app.toasts.filter((t) => /Online link is down/.test(t)).length, 1, "seen ids are remembered");
  assert.equal(notes(app).length, 0, "a toast is not a banner");
});

test("several at once: banners all show; toasts one per check, never pushing out the boot's offers", async () => {
  const app = await loadApp();
  app.runIn("showActionToast('Last session saved just now', 'Resume', () => {}, 20000)");
  const announcements = [
    ...[1, 2, 3].map((i) => ({ id: "t" + i, text: "Toast " + i })),
    { id: "b1", text: "Banner one", show: ["banner"] },
    { id: "b2", text: "Banner two", show: ["banner"], url: "https://dingbat.gg/news", label: "News" },
    { id: "both", text: "Both ways", show: ["toast", "banner"] },
  ];
  serve(app, { status: { announcements } });
  await app.runIn("checkStatus()");
  assert.deepEqual(app.toasts.filter((t) => /Toast \d|Both ways/.test(t)), ["Toast 1"]);
  assert.ok(app.liveToasts().some((t) => /Last session saved/.test(t)), "the Resume offer is still up");
  assert.deepEqual(notes(app).map(noteText), ["Banner one", "Banner two", "Both ways"]);
  assert.equal(notes(app)[1].children[2].children[0].href, "https://dingbat.gg/news");
  assert.equal(notes(app)[1].children[2].children[0].textContent, "News");
  for (let i = 0; i < 3; i++) await app.runIn("checkStatus()");
  assert.deepEqual(app.toasts.filter((t) => /Toast \d|Both ways/.test(t)),
    ["Toast 1", "Toast 2", "Toast 3", "Both ways"], "the rest follow, one a check");
  assert.equal(notes(app).length, 3, "banners stay until dismissed");
});

test("the last check's banners are drawn at boot, before status.json answers", async () => {
  const banners = [{ id: "kept", text: "Kept from last time" }, { id: "old", text: "Over", until: "2020-01-01T00:00:00Z" }];
  const app = await loadApp({ localStorageSeed: { dingbat_banners: JSON.stringify(banners) } });
  assert.deepEqual(notes(app).map(noteText), ["Kept from last time"], "past its until, a cached banner stays gone");
  serve(app, { status: { announcements: [] } });
  await app.runIn("checkStatus()");
  assert.equal(notes(app).length, 0, "a banner taken out of status.json goes at the next check");
});

test("a dismissed banner stays dismissed; a banner past its until goes", async () => {
  const app = await loadApp();
  const soon = new Date(Date.now() + 3600e3).toISOString();
  serve(app, { status: { announcements: [
    { id: "keep", text: "Keep me", show: ["banner"] },
    { id: "close", text: "Close me", show: ["banner"], until: soon },
  ] } });
  await app.runIn("checkStatus()");
  assert.equal(notes(app).length, 2);
  await notes(app)[1].children.at(-1).click();
  assert.deepEqual(notes(app).map(noteText), ["Keep me"]);
  await app.runIn("checkStatus()");
  assert.deepEqual(notes(app).map(noteText), ["Keep me"], "dismissal survives the next check");
  assert.equal(app.elements.get("home-notes").hidden, false);
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
        { id: "fixed", text: "Builds before the fix", builtBefore: NEW, show: ["banner"] },
        { id: "future", text: "A place this build doesn't know", show: ["sky"] },
      ],
    },
  });
  for (let i = 0; i < 4; i++) await app.runIn("checkStatus()");
  const shown = app.toasts.join("\n");
  assert.match(shown, /Web and iOS/);
  assert.match(shown, /A place this build doesn't know/, "an unknown show falls back to a toast");
  assert.doesNotMatch(shown, /iOS only|Not yet|Too late|Old builds only/);
  assert.deepEqual(notes(app).map(noteText), ["Builds before the fix"]);
});

test("a development build (no build time) sees no builtBefore announcement and is never required to update", async () => {
  const app = await loadApp();
  serve(app, {
    built: "",
    status: {
      announcements: [{ id: "b", text: "Your build has a bug", builtBefore: NEW }],
      required: [{ minBuild: FIX }],
    },
  });
  await app.runIn("checkStatus()");
  assert.doesNotMatch(app.toasts.join("\n"), /Your build has a bug/);
  assert.equal(modalOpen(app), false);
});

test("an app-wide required update blocks with its message, and Update now saves and updates", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  app.runIn("currentRomName = 'rom.gba'; currentOriginalName = 'A.gba'");
  app.sandbox.Module = snapshotModule();
  serve(app, { status: { required: [
    { platforms: ["ios"], minBuild: NEW, message: "Not this one." },
    { minBuild: FIX, message: "Saves can be lost on this build." },
  ] } });
  await app.runIn("checkStatus()");
  assert.equal(modalOpen(app), true);
  assert.equal(app.elements.get("required-text").textContent, "Saves can be lost on this build.");
  assert.equal(app.elements.get("required-foot").textContent, "Your game is saved before the update.");
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
    serve(app, { status: { required: [{ minBuild: FIX }] }, ...opts });
    await app.runIn("checkStatus()");
    assert.equal(modalOpen(app), false, JSON.stringify(opts));
  }
});

test("a link session holds a required update off; offline and a broken status.json say nothing", async () => {
  const linked = await loadApp();
  linked.runIn("linkMode = true");
  serve(linked, { status: { required: [{ minBuild: FIX }] } });
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

test("turned away by the signaling server: the update is offered over the link screen", async () => {
  const app = await loadApp();
  serve(app, { status: {} });
  await app.runIn("onServerWantsUpdate()");
  assert.ok(app.liveToasts().some((t) => /A newer dingbat is ready/.test(t)));
  assert.equal(app.elements.get("update-btn").hidden, false, "and the bar's Update");

  const none = await loadApp();
  serve(none, { status: {}, latest: "aaa1111" });
  await none.runIn("onServerWantsUpdate()");
  assert.ok(!none.liveToasts().some((t) => /newer dingbat/.test(t)), "nothing to update to: the link screen's message alone");
});
