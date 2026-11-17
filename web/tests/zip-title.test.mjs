// A game added from a zip is shown under the zip's name ("Pokemon
// Collection" for Pokemon Collection.zip), as on the desktop. Display only:
// every record of the game stays under the ROM's own name, so a zip of a
// game already in the library is that game, saves, states and all.

import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { loadApp, u8, eq, settle, gameTiles } from "./helpers.mjs";
import { makeDrive, makeClock, useClock } from "./drivefake.mjs";

const ROM = "Pokemon - Emerald Version (USA).gba";
const ZIP = "Pokemon Collection.zip";
const drain = async (n = 12) => { for (let i = 0; i < n; i++) await settle(); };
const gba = (id) => u8(id, 0, 0, 0xea); // an ARM branch at 3: passes the ROM check

// The stand-in core of game-switch.test.mjs: boots on the FS's ROM and
// battery file; a state is [rom, battery] and applies only to its own ROM.
const boot = async () => {
  const app = await loadApp();
  app.runIn(`
    globalThis.core = { rom: 0, ram: null, applied: 0 };
    Object.assign(Module, {
      ccall: (fn, ret, types, args) => {
        if (fn !== "initFromEmscripten") return 0;
        const rom = FS.files.get(args[0]);
        const sav = FS.files.get(args[0].slice(0, args[0].lastIndexOf(".")) + ".sav");
        core.rom = rom ? rom[0] : 0;
        core.ram = sav ? Array.from(sav) : null;
        return 0;
      },
      _wasm_state_size: () => 2,
      _wasm_state_data: () => {
        const m = new Uint8Array(Module.memory.buffer);
        m[8] = core.rom; m[9] = core.ram ? core.ram[1] : 0;
        return 8;
      },
      _wasm_load_state: (ptr) => {
        const m = new Uint8Array(Module.memory.buffer);
        if (m[ptr] !== core.rom) return 0;
        core.applied++;
        return 1;
      },
      _malloc: () => 32, _free: () => {},
      memory: { buffer: new ArrayBuffer(64) },
    });
    storageReadyResolve();
  `);
  await app.runIn("Module.onRuntimeInitialized()");
  return app;
};

const zipOf = async (app, entries) => {
  app.sandbox.__entries = entries;
  const blob = app.runIn("ZipWrite.blob(__entries, new Date(2026, 10, 16))");
  return blob.arrayBuffer();
};
const drop = async (app, fileName, entries) => {
  const buf = await zipOf(app, entries);
  await vm.runInContext("handleZipFile", app.context)({ name: fileName, arrayBuffer: async () => buf });
  await drain();
};
const tileOf = (app, rom) => gameTiles(app).find((t) => t.dataset.rom === rom);
const caption = (tile) => tile.children[0].children[1].children[0].textContent;
const cartLabel = (tile) => tile.children[0].children[0].children[0].children[0].textContent;
const search = async (app, q) => {
  const el = app.document.getElementById("lib-search");
  el.value = q;
  el.dispatch("input");
  await settle();
};
const visible = (app) => gameTiles(app).filter((t) => !t.hidden).map((t) => t.dataset.rom);

test("a zip's game is shown under the zip's name and stored under the ROM's", async () => {
  const app = await boot();
  await drop(app, ZIP, [{ name: ROM, data: gba(7) }]);
  assert.equal(app.api.currentOriginalName, ROM, "the game is the ROM's name");
  eq(Array.from(app.idb.get("rom:" + ROM).data), [7, 0, 0, 0xea]);
  assert.equal(app.idb.get("rom:Pokemon Collection.gba"), undefined);
  const entry = app.idb.get("recent").find((r) => r.name === ROM);
  assert.equal(entry.title, "Pokemon Collection");

  await app.api.refreshHomeRecent();
  await drain();
  const tile = tileOf(app, ROM);
  assert.equal(caption(tile), "Pokemon Collection");
  assert.equal(tile.children[0].title, ROM, "the hover still names the file");
  assert.equal(cartLabel(tile), "PC", "the cartridge's initials are the zip's");

  app.runIn(`setHeroMode("paused", ${JSON.stringify(ROM)})`);
  assert.equal(app.document.getElementById("hero-name").textContent, "Pokemon Collection");
  assert.equal(app.document.getElementById("hero-name").title, ROM);
});

test("the closed hero shows the zip's name too", async () => {
  const app = await loadApp();
  app.runIn("playedThisVisit = true");
  app.idb.set("recent", [{ name: ROM, ts: 2, imp: 2, title: "Pokemon Collection" },
                         { name: "Tetris.gb", ts: 1 }]);
  for (const n of [ROM, "Tetris.gb"]) app.idb.set("rom:" + n, { name: n, data: u8(1) });
  await app.api.refreshHomeRecent();
  await drain();
  assert.equal(app.document.getElementById("hero-name").textContent, "Pokemon Collection");
  assert.match(app.document.getElementById("hero-shot").getAttribute("aria-label"), /Pokemon Collection$/);
});

test("search finds a zip's game by the zip's name; A-Z sorts it there", async () => {
  const app = await loadApp();
  const names = ["Zelda.gba", "Tetris.gb", "Advance Wars.gba", "Crystal.gbc", "Mario.gb",
                 "Metroid.gba", "Kirby.gb", "Wario.gba", ROM];
  app.idb.set("recent", names.map((name, i) =>
    name === ROM ? { name, ts: 100 - i, imp: 1, title: "Pokemon Collection" } : { name, ts: 100 - i }));
  for (const n of names) app.idb.set("rom:" + n, { name: n, data: u8(1) });
  await app.api.refreshHomeRecent();
  await settle();
  await search(app, "collection");
  eq(visible(app), [ROM]);
  await search(app, "pokemon coll");
  eq(visible(app), [ROM]);
  await search(app, "zelda");
  eq(visible(app), ["Zelda.gba"]);
  await search(app, "");
  await app.api.setRomsSort("alpha");
  await settle();
  eq(gameTiles(app).map(caption), ["Advance Wars", "Crystal", "Kirby", "Mario", "Metroid",
                                   "Pokemon Collection", "Tetris", "Wario", "Zelda"]);
});

test("a plain ROM is unchanged, and adding it bare drops a zip's name", async () => {
  const app = await boot();
  const file = { name: ROM, _bytes: gba(7) };
  app.runIn(`globalThis.FileReader = class { addEventListener(t, f) { this.f = f; }
    readAsArrayBuffer(file) { this.result = file._bytes.buffer; setTimeout(() => this.f()); } }`);
  app.api.handleRomFile(file);
  await drain();
  let entry = app.idb.get("recent").find((r) => r.name === ROM);
  assert.equal(entry.title, undefined);
  await app.api.refreshHomeRecent();
  await drain();
  assert.equal(caption(tileOf(app, ROM)), "Pokemon - Emerald Version (USA)");

  await drop(app, ZIP, [{ name: ROM, data: gba(7) }]);
  assert.equal(app.idb.get("recent").find((r) => r.name === ROM).title, "Pokemon Collection");
  app.api.handleRomFile(file);
  await drain();
  entry = app.idb.get("recent").find((r) => r.name === ROM);
  assert.equal(entry.title, undefined, "the newest import is the bare file");
});

test("a zip named as its ROM keeps no title; a play keeps the zip's", async () => {
  const app = await boot();
  await drop(app, "Pokemon - Emerald Version (USA).zip", [{ name: ROM, data: gba(7) }]);
  assert.equal(app.idb.get("recent").find((r) => r.name === ROM).title, undefined);
  await drop(app, ZIP, [{ name: ROM, data: gba(7) }]);
  await app.runIn(`touchRecent(${JSON.stringify(ROM)})`);
  await drain();
  assert.equal(app.idb.get("recent").find((r) => r.name === ROM).title, "Pokemon Collection");
});

test("the game's save and session load the same when it comes in a zip", async () => {
  const app = await boot();
  // Already in the library from the bare ROM, with a save and a session.
  const save = u8(7, 42);
  app.idb.set("recent", [{ name: ROM, ts: 1, imp: 1 }]);
  app.idb.set("rom:" + ROM, { name: ROM, data: gba(7) });
  app.idb.set("save:" + ROM, save);
  app.idb.set("stateauto:" + ROM, {
    bytes: u8(7, 42), ts: Date.now(),
    saveSig: app.runIn(`saveSignature(new Uint8Array([7, 42]))`),
  });
  await drop(app, ZIP, [{ name: ROM, data: gba(7) }]);
  assert.equal(app.api.currentOriginalName, ROM);
  eq(app.runIn("core.ram"), [7, 42], "booted on its own save");
  const pill = app.document.getElementById("toast").children.find((c) =>
    c.classList.contains("has-action") && !c.classList.contains("leaving"));
  assert.ok(pill, "its session is offered, as for a dropped ROM");
  pill.onclick();
  await drain();
  assert.equal(app.runIn("core.applied"), 1, "the session went back in");
  eq(app.idb.get("save:" + ROM), save);
  assert.ok(app.idb.get("stateauto:" + ROM)?.bytes);
  for (const k of app.idb.keys()) assert.ok(!String(k).includes("Pokemon Collection"), k);
  eq(app.idb.get("recent").map((r) => [r.name, r.title]), [[ROM, "Pokemon Collection"]]);
});

test("a dingbat export adds back under its game's title, not the export's file name", async () => {
  const app = await boot();
  await drop(app, ZIP, [{ name: ROM, data: gba(7) }]);
  const { exportInventory, exportPackage } = vm.runInContext("({ exportInventory, exportPackage })", app.context);
  app.idb.set("save:" + ROM, u8(7, 1)); // two files: a zip, not the bare ROM
  const inv = await exportInventory(ROM);
  const pkg = exportPackage(ROM, inv.filter((i) => i.kind === "rom" || i.kind === "save"));
  app.idb.set("recent", []);
  app.idb.delete("rom:" + ROM);
  assert.match(pkg.fileName, /\.zip$/);
  const buf = await pkg.blob.arrayBuffer();
  await vm.runInContext("handleZipFile", app.context)({ name: pkg.fileName, arrayBuffer: async () => buf });
  await drain();
  assert.equal(app.idb.get("recent").find((r) => r.name === ROM).title, "Pokemon Collection");

  // An export of a game with no title adds back with none.
  const bare = exportPackage("Tetris.gb", [{ kind: "rom", files: [{ path: "Tetris.gb", data: u8(1) }] },
                                           { kind: "save", files: [{ path: "Tetris.sav", data: u8(2) }] }]);
  const z = await app.runIn("unzip")(await bare.blob.arrayBuffer());
  const info = JSON.parse(new TextDecoder().decode(
    await z.extract(z.entries.find((e) => e.name === "info.json"))));
  assert.equal(info.title, undefined);
});

test("the title travels in Drive's library with the import that set it", async () => {
  const app = await loadApp();
  const merge = (a, b) => app.api.mergeLibrary(a, b);
  const lib = (...recents) => ({ recents, tomb: [], ren: [] });
  const titled = { name: ROM, ts: 10, imp: 5, title: "Pokemon Collection" };
  // A build that knows no titles wrote the same claim back without it.
  const stripped = { name: ROM, ts: 20, imp: 5 };
  eq(merge(lib(stripped), lib(titled)).recents, [{ name: ROM, ts: 20, imp: 5, title: "Pokemon Collection" }]);
  eq(merge(lib(titled), lib(stripped)).recents, [{ name: ROM, ts: 20, imp: 5, title: "Pokemon Collection" }]);
  // A later import of the bare ROM is a new claim with none.
  eq(merge(lib(titled), lib({ name: ROM, ts: 30, imp: 30 })).recents, [{ name: ROM, ts: 30, imp: 30 }]);
  // A later zip import wins over an older one.
  eq(merge(lib(titled), lib({ name: ROM, ts: 8, imp: 8, title: "GBA Pack" })).recents,
     [{ name: ROM, ts: 10, imp: 8, title: "GBA Pack" }]);
  // A rename is the person naming it: the title goes.
  const renamed = merge({ recents: [titled], tomb: [], ren: [] },
                        { recents: [], tomb: [], ren: [{ from: ROM, to: "Emerald.gba", ts: 50 }] });
  eq(renamed.recents, [{ name: "Emerald.gba", ts: 10, imp: 50 }]);
  // Not a string: ignored.
  eq(merge(lib({ name: ROM, ts: 1, imp: 1, title: 7 }), lib()).recents, [{ name: ROM, ts: 1, imp: 1 }]);
});

test("another device's pull shows the zip's name, and its download keeps it", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const device = async () => {
    const app = await loadApp();
    useClock(app, clock);
    app.setFetch(drive.fetch);
    app.api.gdriveToken = "tok";
    app.api.gdriveTokenExp = clock() + 3600e3;
    app.api.syncState = {
      queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], delTs: {},
      sigs: {}, rmt: {}, acct: "a1", parked: {}, connected: true, email: "e@x",
    };
    app.idb.set("recent", []);
    return app;
  };
  const d0 = await device();
  const d1 = await device();
  await d0.api.addRecentRom(ROM, gba(7), null, "Pokemon Collection");
  await d0.api.dbPut("save:" + ROM, u8(7, 3));
  d0.api.markUpload("save:" + ROM);
  await d0.api.flushSync();
  await settle();
  assert.equal(drive.lib().recents[0].title, "Pokemon Collection");

  await d1.api.pullSync();
  await drain();
  await d1.api.refreshHomeRecent();
  await drain();
  assert.equal(caption(tileOf(d1, ROM)), "Pokemon Collection", "the Drive-only tile");
  assert.equal(await d1.api.downloadGame(ROM), true);
  await drain();
  eq(d1.idb.get("recent").map((r) => [r.name, r.title]), [[ROM, "Pokemon Collection"]]);
  eq(d1.idb.get("save:" + ROM), u8(7, 3), "the save under the ROM's name");
});
