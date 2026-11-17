// The app's library core (ios/Dingbat/Sources/LibraryCore.swift) against
// the web's own code: mergeLibrary byte for byte (fixed cases for a zip's
// `title`, then seeded random libraries), the entry an import or a play
// writes, recent.json's entries, titleOf and the title a zip import sets;
// then Drive's library file between two web devices and the app: a title
// the web wrote survives the app's pull, play and write, and the app's
// bare-ROM import drops it on the web too.
//
//   node ios/e2e/library-core.mjs        # macOS, Xcode command line tools
//
// The Swift side is LibraryCore.swift and JSObject.swift with
// library-core/main.swift, built by swiftc on the Mac (Foundation only).

import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";

const ROOT = new URL("../..", import.meta.url).pathname;
const { loadApp, settle } = await import(join(ROOT, "web/tests/helpers.mjs"));
const { makeDrive, makeClock, useClock } = await import(join(ROOT, "web/tests/drivefake.mjs"));

const dir = mkdtempSync(join(tmpdir(), "library-core-"));
const bin = join(dir, "library-core");
execFileSync("xcrun", ["swiftc", "-O", "-o", bin, join(ROOT, "ios/Dingbat/Sources/LibraryCore.swift"),
                       join(ROOT, "ios/Dingbat/Sources/JSObject.swift"),
                       join(ROOT, "ios/e2e/library-core/main.swift")], { stdio: "inherit" });
const swift = (cases) => {
  writeFileSync(join(dir, "cases.json"), JSON.stringify(cases));
  execFileSync(bin, [dir], { stdio: "inherit" });
  return JSON.parse(readFileSync(join(dir, "out.json"), "utf8"));
};

const app = await loadApp();
const web = app.runIn("({ mergeLibrary, titleOf, stripExt, fileTitle, withGen })");
const wmerge = (a, b) => JSON.stringify(web.mergeLibrary(JSON.parse(a), JSON.parse(b)));
const L = (recents, tomb = [], ren = []) => JSON.stringify({ recents, tomb, ren });

let failed = 0;
const check = async (what, fn) => {
  try { await fn(); console.log("ok   " + what); } catch (e) { failed++; console.log("FAIL " + what + ": " + e.message); }
};

const ROM = "Pokemon - Emerald Version (USA).gba";
const T = "Pokemon Collection";
const titled = { name: ROM, ts: 10, imp: 5, title: T };

// --- mergeLibrary --------------------------------------------------------
const fixed = [
  ["a build that knows no titles wrote the same claim back", L([{ name: ROM, ts: 20, imp: 5 }]), L([titled])],
  ["... in either order", L([titled]), L([{ name: ROM, ts: 20, imp: 5 }])],
  ["a later bare import drops it", L([titled]), L([{ name: ROM, ts: 30, imp: 30 }])],
  ["a later zip import wins", L([titled]), L([{ name: ROM, ts: 8, imp: 8, title: "GBA Pack" }])],
  ["an older zip import loses", L([{ name: ROM, ts: 8, imp: 8, title: "GBA Pack" }]), L([{ name: ROM, ts: 40, imp: 3, title: "Old" }])],
  ["a rename drops it", L([titled]), L([], [], [{ from: ROM, to: "Emerald.gba", ts: 50 }])],
  ["a title that is not a string", L([{ name: ROM, ts: 1, imp: 1, title: 7 }]), L([])],
  ["blank and padded titles", L([{ name: ROM, ts: 1, imp: 1, title: "   " }, { name: "B.gb", ts: 2, imp: 2, title: "  Pad  " }]), L([])],
  ["a long title is cut to 100", L([{ name: ROM, ts: 1, imp: 1, title: "x".repeat(140) }]), L([])],
  ["a title with no import claim", L([{ name: ROM, ts: 3, title: "NoClaim" }]), L([{ name: ROM, ts: 9, imp: 4 }])],
  ["a newer generation, the title with its claim", L([{ name: ROM, ts: 50, imp: 2, title: T }]),
   L([{ name: ROM, ts: 5, imp: 9, gen: 2, title: "Second" }])],
  ["a tombstone beside a titled entry", L([{ name: ROM, ts: 60, imp: 60, gen: 1, title: T }], [{ name: ROM, ts: 50 }]), L([])],
];

// Seeded random libraries over three names.
let seed = 20261117;
const rnd = (n) => { seed = (Math.imul(seed, 1103515245) + 12345) >>> 0; return (seed >>> 8) % n; };
const NAMES = ["A.gba", "B.gb", "C.gbc"];
const TITLES = [undefined, undefined, "Zip One", "Zip Two", "  Zip One ", "", 7, "Pokémon ☃ pack"];
const entry = () => {
  const e = { name: NAMES[rnd(3)], ts: 1 + rnd(40) };
  if (rnd(3)) e.imp = 1 + rnd(40);
  if (rnd(3) === 0) e.gen = 1 + rnd(2);
  const t = TITLES[rnd(TITLES.length)];
  if (t !== undefined) e.title = t;
  return e;
};
const randomLib = () => {
  const recents = Array.from({ length: rnd(4) }, entry);
  const tomb = Array.from({ length: rnd(2) }, () => ({ name: NAMES[rnd(3)], ts: 1 + rnd(40), ...(rnd(2) ? { gen: 1 + rnd(2) } : {}) }));
  const ren = rnd(4) ? [] : [{ from: NAMES[rnd(3)], to: NAMES[rnd(3)], ts: 1 + rnd(40) }];
  return L(recents, tomb, ren);
};
const random = Array.from({ length: 600 }, (_, i) => ["random " + i, randomLib(), randomLib()]);

await check(`mergeLibrary: ${fixed.length} title cases and ${random.length} random libraries`, () => {
  const all = [...fixed, ...random];
  const got = swift(all.map(([, a, b]) => ({ op: "merge", a, b })));
  all.forEach(([what, a, b], i) => assert.equal(got[i], wmerge(a, b), what));
});

await check("titleOf", () => {
  const xs = ["Pokemon Collection", "  padded\t", "", "   ", "x".repeat(101), "é".repeat(120), "Zelda: ☃"];
  const got = swift([...xs, 7, null].map((s) => ({ op: "titleOf", s })));
  [...xs, 7, null].forEach((s, i) => assert.equal(got[i], web.titleOf(s), JSON.stringify(s)));
});

// The title a zip import sets (web handleZipFile): a dingbat export's is its
// game's (or none), anyone else's the zip's name, none when that is the ROM's.
await check("the title a zip import sets", () => {
  const cs = [
    { zip: "Pokemon Collection.zip", rom: ROM, isExport: false },
    { zip: "Pokemon - Emerald Version (USA).zip", rom: ROM, isExport: false },
    { zip: "  Spaced  .zip", rom: ROM, isExport: false },
    { zip: "noext", rom: "Tetris.gb", isExport: false },
    { zip: "Tetris.zip", rom: "Tetris.gb", isExport: false },
    { zip: "Pokemon Collection — dingbat 2026-11-16.zip", rom: ROM, isExport: true, exportTitle: T },
    { zip: "Tetris — dingbat 2026-11-16.zip", rom: "Tetris.gb", isExport: true },
  ];
  const got = swift(cs.map((c) => ({ op: "zipTitle", ...c })));
  cs.forEach((c, i) => {
    let t = c.isExport ? web.titleOf(c.exportTitle) : web.titleOf(web.stripExt(c.zip));
    if (t === web.fileTitle(c.rom)) t = null;
    assert.equal(got[i], t, c.zip);
  });
  assert.equal(got[0], T);
});

// The entry an import or a play writes: the web's own bumpRecentIndex, then
// the Swift one with the same stamps.
await check("the entry an import or a play writes", async () => {
  const cs = [
    { prev: titled, fresh: false },
    { prev: titled, fresh: true },
    { prev: titled, fresh: true, title: "GBA Pack" },
    { prev: { name: ROM, ts: 3, imp: 3, gen: 2, title: T }, fresh: false },
    { prev: null, fresh: true, title: "  New zip " },
    { prev: null, fresh: false },
  ];
  const wrote = [];
  for (const c of cs) {
    app.idb.set("recent", c.prev ? [c.prev] : []);
    await app.runIn(`bumpRecentIndex(${JSON.stringify(ROM)}, ${JSON.stringify({ fresh: c.fresh, title: c.title ?? null })})`);
    wrote.push(app.idb.get("recent")[0]);
  }
  const got = swift(cs.map((c, i) => ({ op: "bumped", name: ROM, ts: wrote[i].ts, imp: wrote[i].imp ?? null,
                                         gen: wrote[i].gen ?? 0, prev: c.prev && JSON.stringify(c.prev),
                                         fresh: c.fresh, title: c.title ?? null })));
  cs.forEach((c, i) => assert.equal(got[i], JSON.stringify(wrote[i]), JSON.stringify(c)));
});

await check("recent.json entries keep the title", () => {
  const os = [titled, { name: ROM, ts: 1 }, { name: ROM, ts: 1, imp: 1, title: "  " }, { ts: 1, title: T }];
  const got = swift(os.map((o) => ({ op: "stored", o: JSON.stringify(o) })));
  assert.equal(got[0], JSON.stringify({ name: ROM, ts: 10, imp: 5, title: T }));
  assert.equal(got[1], JSON.stringify({ name: ROM, ts: 1 }));
  assert.equal(got[2], JSON.stringify({ name: ROM, ts: 1, imp: 1 }));
  assert.equal(got[3], null);
});

// --- Drive's library between the web and the app -------------------------
await check("a web-written title through the app's pull, play and write", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const device = async () => {
    const d = await loadApp();
    useClock(d, clock);
    d.setFetch(drive.fetch);
    d.api.gdriveToken = "tok";
    d.api.gdriveTokenExp = clock() + 3600e3;
    d.api.syncState = {
      queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], delTs: {},
      sigs: {}, rmt: {}, acct: "a1", parked: {}, connected: true, email: "e@x",
    };
    d.idb.set("recent", []);
    return d;
  };
  const gba = new Uint8Array([7, 0, 0, 0xea]);
  const drain = async () => { for (let i = 0; i < 12; i++) await settle(); };
  const libText = () => new TextDecoder().decode(drive.get("library").bytes);
  // The app's write of the library file, as its flush or pull does it.
  const appWrites = (text) => { const f = drive.get("library"); f.bytes = new TextEncoder().encode(text); };
  const titleOn = (d) => d.idb.get("recent").find((r) => r.name === ROM)?.title;

  const w0 = await device();
  await w0.api.addRecentRom(ROM, gba, null, { title: T });
  await w0.api.addRecentRom("Tetris.gb", new Uint8Array([1]), null);
  await w0.api.flushSync();
  await drain();
  const W = libText();
  assert.equal(JSON.parse(W).recents.find((r) => r.name === ROM).title, T, "the web wrote the title");

  // The app's first pull: nothing here yet, so nothing to write back.
  const [pulled] = swift([{ op: "merge", a: W, b: L([]) }]);
  assert.equal(pulled, W, "the app's merge of the web's file is the web's file, byte for byte");
  const here = JSON.parse(pulled).recents;

  // A play on the app (a new ts, the same claim), then its flush.
  const prev = here.find((r) => r.name === ROM);
  const [played] = swift([{ op: "bumped", name: ROM, ts: prev.ts + 5000, imp: prev.imp, gen: 0,
                            prev: JSON.stringify(prev), fresh: false, title: null }]);
  const local = [JSON.parse(played), ...here.filter((r) => r.name !== ROM)];
  const [S1] = swift([{ op: "merge", a: W, b: L(local) }]);
  assert.equal(S1, wmerge(W, L(local)), "the app's write is the web's merge");
  assert.equal(JSON.parse(S1).recents[0].title, T, "the app's write keeps the title");
  appWrites(S1);

  // Back on the web: the device that added it, and one that never had it.
  await w0.api.pullSync();
  await drain();
  assert.equal(titleOn(w0), T, "the web keeps it after the app's write");
  const w1 = await device();
  await w1.api.pullSync();
  await drain();
  assert.equal(titleOn(w1), T, "another web device gets it");
  assert.equal(w1.runIn(`displayName(${JSON.stringify(ROM)})`), T);

  // The app adds the bare ROM: a new claim with no title, everywhere.
  const [bare] = swift([{ op: "bumped", name: ROM, ts: clock() + 1000, imp: clock() + 1000, gen: 0,
                          prev: played, fresh: true, title: null }]);
  const [S2] = swift([{ op: "merge", a: libText(), b: L([JSON.parse(bare)]) }]);
  assert.equal(JSON.parse(S2).recents.find((r) => r.name === ROM).title, undefined, "the app's write drops it");
  appWrites(S2);
  await w1.api.pullSync();
  await drain();
  assert.equal(titleOn(w1), undefined, "the web drops it after the app's bare import");
});

rmSync(dir, { recursive: true, force: true });
console.log(failed ? `\n${failed} check(s) failed` : "\nall passed");
process.exit(failed ? 1 : 0);
