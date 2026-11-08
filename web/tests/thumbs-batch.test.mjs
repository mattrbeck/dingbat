// The one-time "Add pictures to your library?" offer and the batch behind
// it: every game without a picture is booted in the core (never as the
// loaded game), its last session restored where one exists, stepped, and
// its screen stored as "frame:<name>". Drive-only games, when asked for,
// are fetched into memory and never written to the device.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, jsonRes, bytesRes } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";

// A wasm stand-in: counts ticks and state loads, logs the silent switch; a
// 240x160 framebuffer at offset 16 of `memory`, with something on it (a
// blank one is not kept); a canvas whose toBlob yields a JPEG. The page's
// clock is a core that takes __clockStep ms a frame: the run reads it once
// a frame, so it moves by that much each read.
const stubModule = (app) => app.runIn(`
  globalThis.__ticks = 0; globalThis.__inits = []; globalThis.__loads = 0;
  globalThis.__silent = [];
  globalThis.__clock = 0; globalThis.__clockStep = 1;
  globalThis.performance = { now: () => (__clock += __clockStep) };
  globalThis.Module = {
    ccall: (fn, ret, types, args) => { __inits.push(args[0]); },
    _benchFrames: (n) => { __ticks += n; },
    _wasm_set_audio_silent: (on) => { __silent.push(on); },
    _clearAudioBuffer: () => {},
    _wasm_fb_ptr: () => 16,
    _wasm_load_state: () => { __loads++; return 1; },
    _malloc: () => 8, _free: () => {},
    memory: { buffer: new Uint8Array(16 + 240 * 160 * 4).map((_, i) => i * 7).buffer },
  };
  const realCreate = document.createElement.bind(document);
  document.createElement = (tag) => {
    const el = realCreate(tag);
    if (tag === "canvas") el.toBlob = (cb, type) => cb(new Blob([new Uint8Array([0xff, 0xd8])], { type }));
    return el;
  };
`);

const seedLibrary = (app, names) => {
  app.idb.set("recent", names.map((name, i) => ({ name, ts: 100 - i })));
  for (const n of names) app.idb.set("rom:" + n, { name: n, data: u8(1, 2, 3, 4) });
};

const framesOf = (app) => [...app.idb.keys()].filter((k) => k.startsWith("frame:")).sort();
const modalOpen = (app) => app.document.getElementById("thumbs-modal").classList.contains("open");

// ── The offer ───────────────────────────────────────────────────────────────

test("the offer opens once when a game has no picture, and records itself", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba", "B.gb"]);
  assert.equal(await app.api.maybeOfferThumbnails(), true);
  assert.ok(modalOpen(app));
  assert.ok(app.idb.get("thumbs_offered"), "the offer is recorded whatever the answer");

  app.document.getElementById("thumbs-not-now").click();
  assert.ok(!modalOpen(app));
  assert.equal(await app.api.maybeOfferThumbnails(), false, "never a second time");
});

test("no offer when every game already has a picture, and none is recorded", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  app.idb.set("frame:A.gba", new Blob([u8(1)]));
  assert.equal(await app.api.maybeOfferThumbnails(), false);
  assert.equal(app.idb.get("thumbs_offered"), undefined);
});

test("no offer while a game is loaded (the batch would re-init its core)", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "A.gba";
  assert.equal(await app.api.maybeOfferThumbnails(), false);
  assert.equal(app.idb.get("thumbs_offered"), undefined, "not spent: offered later");
});

test("the Drive row shows only when signed in with a Drive-only game", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  await app.api.maybeOfferThumbnails();
  assert.equal(app.document.getElementById("thumbs-drive-row").hidden, true);

  const app2 = await loadApp();
  seedLibrary(app2, ["A.gba"]);
  app2.idb.set("recent", [{ name: "A.gba", ts: 2 }, { name: "D.gba", ts: 1 }]);
  app2.api.gdriveToken = "t";
  app2.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                         sigs: { "rom:D.gba": "x" }, rmt: {}, connected: true }; // D's ROM is on Drive
  await app2.api.maybeOfferThumbnails();
  assert.equal(app2.document.getElementById("thumbs-drive-row").hidden, false);
  assert.equal(app2.document.getElementById("thumbs-drive-toggle").checked, false, "off by default");
});

test("Manage ROMs and Saves opens the same box any time, without spending the offer", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  app.idb.set("thumbs_offered", 1); // the one-time offer is long gone
  assert.equal(await app.api.openThumbsRun(), true);
  assert.ok(modalOpen(app));
  assert.ok(!app.document.getElementById("roms-modal").classList.contains("open"),
    "the manage box gives way to the offer");

  // Nothing to do: a toast, no box.
  app.document.getElementById("thumbs-not-now").click();
  app.idb.set("frame:A.gba", new Blob([u8(1)]));
  assert.equal(await app.api.openThumbsRun(), false);
  assert.ok(!modalOpen(app));
  assert.ok(app.toasts.some((t) => /already has a picture/.test(t)), app.toasts.join(" | "));

  // A loaded game has to close first.
  app.idb.delete("frame:A.gba");
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "A.gba";
  assert.equal(await app.api.openThumbsRun(), false);
  assert.ok(app.toasts.some((t) => /Close the running game/.test(t)));
});

test("at boot, signed in, the offer waits for the first pull — which may picture everything", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]); // no picture here...
  app.api.gdriveToken = "t";
  app.api.gdriveTokenExp = Date.now() + 3600e3;
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true };
  // ...but Drive has one, and the pull is what brings it down.
  app.setFetch(async (url) => {
    url = String(url);
    if (url.startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: [
        { id: "p1", name: "frame:A.gba", size: "4", modifiedTime: "2026-01-01T00:00:00Z" },
      ] });
    }
    if (/alt=media/.test(url)) return bytesRes(new TextEncoder().encode("FACE"));
    return jsonRes({});
  });

  let offered = null;
  const pending = app.api.offerThumbnailsAfterBoot().then((v) => { offered = v; });
  await settle();
  assert.equal(offered, null, "still waiting on the pull");
  assert.ok(!modalOpen(app));

  await app.api.pullSync({ silent: true });
  await pending;
  assert.equal(offered, false, "the pull pictured the game: nothing to offer");
  assert.ok(!modalOpen(app));
  assert.equal(app.idb.get("thumbs_offered"), undefined, "and the offer is not spent");
});

// The guard for the test below, which is the only one here that waits on a
// timer of the page's own. The harness unrefs the page's timers so that the
// ones no test ever clears cannot hold the suite open, and exempts short
// one-shots because those are the only kind a test waits on. Lose the
// exemption and this file does not fail an assertion: it stops dead, the loop
// drains, and every test from here down is cancelled - which is how it read
// on CI while passing on a developer's machine, where something else always
// happened to be pending.
test("the harness leaves a short page timer able to hold the loop open", async () => {
  const app = await loadApp();
  const short = app.runIn("setTimeout(() => {}, 20)");
  const long = app.runIn("setTimeout(() => {}, 5000)");
  assert.equal(short.hasRef(), true, "a test can wait on this one");
  assert.equal(long.hasRef(), false, "and this one cannot outlive the file");
  clearTimeout(short);
  clearTimeout(long);
});

test("at boot, signed in with no pull coming, the offer gives up waiting", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  app.api.gdriveToken = null; // a stale token: the pull waits on a gesture
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true };
  assert.equal(await app.api.offerThumbnailsAfterBoot(20), true);
  assert.ok(modalOpen(app));
});

test("signed out, the boot offer does not wait at all", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  app.api.gdriveToken = null;
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: false };
  let done = false;
  const p = app.api.offerThumbnailsAfterBoot(60000).then(() => { done = true; });
  await settle();
  await settle();
  assert.ok(done, "resolved without any pull");
  assert.equal(await p, undefined);
  assert.ok(modalOpen(app));
});

// ── The way in, above the library ───────────────────────────────────────────

test("the Add pictures button shows only while a game is missing one", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba", "B.gba"]);
  const btn = app.document.getElementById("home-thumbs");

  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(btn.hidden, false, "two games, no pictures");

  app.idb.set("frame:A.gba", new Blob([u8(1)]));
  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(btn.hidden, false, "one still has none");

  app.idb.set("frame:B.gba", new Blob([u8(1)]));
  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(btn.hidden, true, "a fully pictured library offers nothing");
});

test("an empty library offers no pictures link", async () => {
  const app = await loadApp();
  app.idb.set("recent", []);
  const btn = app.document.getElementById("home-thumbs");
  btn.hidden = false;
  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(btn.hidden, true);
});

test("signed out, a Drive-only game does not keep the link up on its own", async () => {
  const app = await loadApp();
  // In the library, but its bytes are elsewhere and there is no session to
  // fetch them with, so the run has nothing it could picture.
  app.idb.set("recent", [{ name: "Cloud.gba", ts: 1 }]);
  const btn = app.document.getElementById("home-thumbs");
  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(btn.hidden, true);
});

// ── The batch ───────────────────────────────────────────────────────────────

test("every unpictured local game is booted, resumed where it can be, and pictured", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba", "B.gb", "C.gba"]);
  app.idb.set("stateauto:A.gba", { bytes: u8(9, 9, 9), ts: 1 });
  app.idb.set("save:B.gb", u8(5, 5));
  const cPicture = new Blob([u8(7)]);
  app.idb.set("frame:C.gba", cPicture);
  const recentBefore = JSON.stringify(app.idb.get("recent"));

  const n = await app.api.runThumbnailBatch();
  assert.equal(n, 2);
  eq(framesOf(app), ["frame:A.gba", "frame:B.gb", "frame:C.gba"]);
  assert.ok(app.idb.get("frame:A.gba") instanceof Blob);
  assert.equal(app.idb.get("frame:C.gba"), cPicture, "an existing picture is left alone");

  // A resumed from its session (one render); B booted through its logo.
  assert.equal(app.runIn("__loads"), 1);
  assert.equal(app.runIn("__ticks"), app.api.THUMBS_RESUME_FRAMES + app.api.THUMBS_BOOT_FRAMES);
  eq(app.runIn("__inits"), ["thumb.gba", "thumb.gb"], "scratch names, never rom.gba");

  // Nothing about the games themselves moved.
  assert.equal(JSON.stringify(app.idb.get("recent")), recentBefore, "play order untouched");
  assert.equal(app.api.currentRomName, null, "no game became the loaded game");
  assert.ok(!app.sandbox.FS.files.has("thumb.sav"), "the scratch battery save is gone");
  assert.ok(!modalOpen(app), "the box closes when the run ends");
  assert.ok(app.toasts.some((t) => /2 pictures added/.test(t)), app.toasts.join(" | "));
});

test("a blank screen is not a picture: the run waits for one that isn't, or keeps the cartridge", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba"]);
  // White through the boot and 60 frames past it, then something on screen.
  app.runIn(`
    new Uint8Array(Module.memory.buffer).fill(255);
    Module._benchFrames = () => {
      if (++__ticks === THUMBS_BOOT_FRAMES + 60) {
        const m = new Uint8Array(Module.memory.buffer);
        for (let i = 0; i < m.length; i++) m[i] = i * 7;
      }
    };`);
  assert.equal(await app.api.runThumbnailBatch(), 1);
  assert.ok(app.idb.get("frame:A.gba") instanceof Blob);
  assert.equal(app.runIn("__ticks"), app.api.THUMBS_BOOT_FRAMES + 60, "stopped at the first real screen");

  // White for good: no picture, and the tile keeps its cartridge.
  app.idb.delete("frame:A.gba");
  app.runIn("new Uint8Array(Module.memory.buffer).fill(255); Module._benchFrames = () => { __ticks++; };");
  assert.equal(await app.api.runThumbnailBatch(), 0);
  assert.equal(app.idb.get("frame:A.gba"), undefined);
  assert.ok(!app.sandbox.FS.files.has("thumb.sav"), "the scratch battery save is gone");
});

test("Drive-only games are fetched, pictured, and never written to the device", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba"]);
  app.idb.set("frame:A.gba", new Blob([u8(1)]));
  app.idb.set("recent", [{ name: "A.gba", ts: 2 }, { name: "D.gba", ts: 1 }]);
  app.api.gdriveToken = "t";
  app.api.gdriveTokenExp = Date.now() + 3600e3;
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: { "rom:D.gba": "x" }, rmt: {}, connected: true }; // from the last pull
  const downloads = [];
  app.setFetch(async (url, opts = {}) => {
    url = String(url);
    if (url.startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: [
        { id: "r1", name: "rom:D.gba", size: "4", modifiedTime: "2026-01-01T00:00:00Z" },
        { id: "s1", name: "save:D.gba", size: "2", modifiedTime: "2026-01-01T00:00:00Z" },
      ] });
    }
    const dm = url.match(/\/files\/([^/?]+)\?alt=media/);
    if (dm) { downloads.push(dm[1]); return bytesRes(dm[1] === "r1" ? u8(1, 2, 3, 4) : u8(5, 5)); }
    return jsonRes({});
  });

  // Not asked for: skipped.
  assert.equal(await app.api.runThumbnailBatch({ includeDrive: false }), 0);
  eq(framesOf(app), ["frame:A.gba"]);

  assert.equal(await app.api.runThumbnailBatch({ includeDrive: true }), 1);
  eq(framesOf(app), ["frame:A.gba", "frame:D.gba"]);
  eq(downloads.sort(), ["r1", "s1"], "ROM and battery save were fetched");
  assert.equal(app.idb.get("rom:D.gba"), undefined, "the ROM never landed on this device");
  assert.equal(app.idb.get("save:D.gba"), undefined, "nor the save");
  eq(app.idb.get("recent").map((r) => r.name), ["A.gba", "D.gba"], "order untouched");
});

test("Stop ends the run after the game in hand", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba", "B.gba", "C.gba"]);
  // Cancel from inside the first game's frame loop (a task boundary).
  const p = app.api.runThumbnailBatch();
  await settle();
  app.document.getElementById("thumbs-stop").click();
  const n = await p;
  assert.equal(n, 0);
  eq(framesOf(app), []);
  assert.ok(app.toasts.some((t) => /No pictures added/.test(t)));
  assert.ok(!modalOpen(app));
});

test("the run is unheard: the core is silenced, the frame loop kept off it, the player's sound back after", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba", "B.gb"]);
  // A page that has not had a game yet: nothing was ever paused, so the frame
  // loop would step (and play) the pictures core between the run's slices.
  app.runIn(`paused = false; globalThis.__heard = 0;
    Module._benchFrames = () => { __ticks++; if (!paused || __silent.at(-1) !== 1) __heard++; };`);
  assert.equal(await app.api.runThumbnailBatch(), 2);
  assert.equal(app.runIn("__ticks"), 2 * app.api.THUMBS_BOOT_FRAMES);
  assert.equal(app.runIn("__heard"), 0, "every frame paused for the frame loop, and silent");
  eq(app.runIn("[...__silent]"), [1, 0], "silenced for the run, then the player's volume");
  assert.equal(app.runIn("paused"), true, "the last game is left frozen, as after a close");

  // A player who had it muted gets it muted back.
  app.idb.delete("frame:A.gba");
  app.runIn("muted = true; __silent.length = 0;");
  assert.equal(await app.api.runThumbnailBatch(), 1);
  eq(app.runIn("[...__silent]"), [1, 1]);
});

test("the player's sound comes back however the run ends: Stop, a launch, a core fault", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba", "B.gba"]);
  const run = async (tick) => {
    for (const n of ["A.gba", "B.gba"]) app.idb.delete("frame:" + n);
    app.runIn(`__ticks = 0; __silent.length = 0; Module._benchFrames = ${tick};`);
    const n = await app.api.runThumbnailBatch();
    return { n, silent: app.runIn("[...__silent]"), ticks: app.runIn("__ticks") };
  };

  // Stop, from inside the first game's frames.
  let r = await run(`() => { if (++__ticks === 50) document.getElementById("thumbs-stop").click(); }`);
  assert.equal(r.n, 0);
  assert.ok(r.ticks < app.api.THUMBS_BOOT_FRAMES, "ended at the next slice, not the game's end");
  eq(r.silent, [1, 0], "stopped");

  // A launch takes the core.
  r = await run(`() => { if (++__ticks === 50) currentRomName = "rom.gba"; }`);
  assert.equal(r.n, 0);
  eq(r.silent, [1, 0], "a launch");
  assert.equal(app.api.currentRomName, "rom.gba", "the launched game keeps the core");
  app.api.currentRomName = null;

  // The core faults on every frame: no pictures, and still the player's sound.
  r = await run(`() => { throw new Error("unreachable"); }`);
  assert.equal(r.n, 0);
  eq(r.silent, [1, 0], "a fault");
  assert.ok(!modalOpen(app));
});

test("a launch that lands while the run is getting ready keeps the core", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba"]);
  app.runIn("paused = false;");
  const p = app.api.runThumbnailBatch(); // waits on the runtime and the library
  app.runIn(`loadingName = "A.gba";`);  // ...meanwhile a tile tap starts a load
  assert.equal(await p, 0);
  assert.equal(app.runIn("__inits.length"), 0, "the core was not re-initialised");
  eq(app.runIn("[...__silent]"), [], "nor silenced");
  assert.equal(app.runIn("paused"), false, "nor paused under the game coming in");
  app.runIn("loadingName = null;");
});

test("frames, not the wall clock, end a game's run: a slow core still gets its whole boot", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba"]);
  app.runIn("__clockStep = 10;"); // 100 frames a second: 600 frames take 6 s
  assert.equal(await app.api.runThumbnailBatch(), 1);
  assert.equal(app.runIn("__ticks"), app.api.THUMBS_BOOT_FRAMES);
  assert.ok(app.idb.get("frame:A.gba") instanceof Blob);
});

test("a batch refuses to run over a loaded game", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba"]);
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Other.gba";
  assert.equal(await app.api.runThumbnailBatch(), 0);
  eq(framesOf(app), []);
  assert.equal(app.runIn("__inits.length"), 0, "the core was not re-initialised");
});

// ── Games that come up blank, and games the run can't open ─────────────────

const signedIn = (app) => {
  app.api.gdriveToken = "t";
  app.api.gdriveTokenExp = Date.now() + 3600e3;
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true };
};
const thumbsBtnShown = async (app) => {
  await app.api.refreshHomeRecent();
  await settle();
  return !app.document.getElementById("home-thumbs").hidden;
};

test("a game that comes up blank is left out until it is played, and the button goes away", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba", "B.gba"]);
  app.idb.set("frame:B.gba", new Blob([u8(1)]));
  app.runIn("new Uint8Array(Module.memory.buffer).fill(255);"); // white for good
  assert.equal(await thumbsBtnShown(app), true, "A has no picture yet");

  assert.equal(await app.api.runThumbnailBatch(), 0);
  assert.ok(app.idb.get("thumbsblank")?.["A.gba"], "the blank game is remembered on this device");
  assert.equal(await thumbsBtnShown(app), false, "nothing left a run would picture");

  // A second run (the offer, say) does not boot it again.
  const inits = app.runIn("__inits.length");
  assert.equal(await app.api.runThumbnailBatch(), 0);
  assert.equal(app.runIn("__inits.length"), inits, "A was not opened again");

  // Opening it clears the mark: the next run may try again.
  await app.runIn(`touchRecent("A.gba")`);
  assert.equal(app.idb.get("thumbsblank")?.["A.gba"], undefined);
  assert.equal(await thumbsBtnShown(app), true);
});

test("a picture from play, or a game leaving the library, drops its blank mark", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba", "B.gba"]);
  app.idb.set("thumbsblank", { "A.gba": 1, "B.gba": 1, "Gone.gba": 1 });
  app.idb.set("frame:A.gba", new Blob([u8(1)])); // played on another device, pulled down
  await app.api.refreshHomeRecent();
  await settle();
  eq(Object.keys(app.idb.get("thumbsblank")), ["B.gba"], "only the one still blank and unplayed");
});

test("Drive-only games keep Add pictures up only while the box's Drive switch is on", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  app.idb.set("frame:A.gba", new Blob([u8(1)]));
  app.idb.set("recent", [{ name: "A.gba", ts: 2 }, { name: "D.gba", ts: 1 }]);
  signedIn(app);
  app.api.syncState.sigs = { "rom:D.gba": "x" }; // D's ROM is on Drive
  assert.equal(await thumbsBtnShown(app), false,
    "with the switch off a run cannot open D, so it does not count");

  // The box still offers D behind the switch (the one-time offer finds it).
  assert.equal(await app.api.maybeOfferThumbnails(), true);
  const toggle = app.document.getElementById("thumbs-drive-toggle");
  assert.equal(app.document.getElementById("thumbs-drive-row").hidden, false);
  assert.equal(toggle.checked, false);
  toggle.checked = true;
  await toggle.dispatch("change");
  await settle();
  assert.equal(app.idb.get("thumbs-drive"), true, "the switch is remembered");
  assert.equal(await thumbsBtnShown(app), true, "now a run would fetch D");

  app.document.getElementById("thumbs-not-now").click();
  assert.equal(await app.api.openThumbsRun(), true);
  assert.equal(toggle.checked, true, "the box opens with the switch as it was left");
});

test("a game on neither this device nor Drive never counts, even with the Drive switch on", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  app.idb.set("frame:A.gba", new Blob([u8(1)]));
  // M was removed from this device with no Drive copy: a missing tile.
  app.idb.set("recent", [{ name: "A.gba", ts: 2 }, { name: "M.gba", ts: 1 }]);
  signedIn(app);
  app.idb.set("thumbs-drive", true);
  assert.equal(app.runIn(`driveHasRom("M.gba")`), false);
  assert.equal(await thumbsBtnShown(app), false, "no run can open it, so no button");
  assert.equal(await app.api.openThumbsRun(), false, "and the box has nothing to offer");
});

test("Reset all settings turns the Drive switch off, and the button follows", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  app.idb.set("frame:A.gba", new Blob([u8(1)]));
  app.idb.set("recent", [{ name: "A.gba", ts: 2 }, { name: "D.gba", ts: 1 }]);
  signedIn(app);
  app.api.syncState.sigs = { "rom:D.gba": "x" };
  app.idb.set("thumbs-drive", true);
  assert.equal(await thumbsBtnShown(app), true);
  await app.runIn("resetAllSettings()");
  await settle();
  assert.equal(app.idb.get("thumbs-drive"), undefined);
  assert.equal(app.document.getElementById("home-thumbs").hidden, true);
});
