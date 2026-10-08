// The app's export core (ios/Dingbat/Sources/ExportCore.swift) against the
// web's own functions, byte for byte: the stored ZIP writer, Game Boy Camera
// photos read out of a save (the album and its backup copy) as 2-bit PNGs,
// info.json, file-name cleaning and the date stamps. An export from either
// must open the same way, and a zip from one must add back on the other.
//
//   node ios/e2e/export-core.mjs        # macOS, Xcode command line tools
//
// The Swift side is ExportCore.swift and ZipReader.swift with
// export-core/main.swift, built by swiftc on the Mac (Foundation, zlib and
// Compression only, nothing of the app).

import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import vm from "node:vm";
import assert from "node:assert/strict";

const ROOT = new URL("../..", import.meta.url).pathname;
const { loadApp } = await import(join(ROOT, "web/tests/helpers.mjs"));
const app = await loadApp();
const web = vm.runInContext(`({ cameraPhotos, greyPng2, exportSafeName, exportStamp, exportDay,
                                 ZipWrite: globalThis.ZipWrite ?? ZipWrite })`, app.context);

const dir = mkdtempSync(join(tmpdir(), "export-core-"));
const put = (name, data) => writeFileSync(join(dir, name), data);

// A seeded PRNG for the fixture bytes.
let seed = 12345;
const rnd = () => { seed = (Math.imul(seed, 1103515245) + 12345) >>> 0; return seed >>> 24; };
const random = (n) => Uint8Array.from({ length: n }, rnd);

// Game Boy Camera: a cart header that says so, and a 128 KB save with five
// photos in the album (numbers out of slot order, one slot empty between).
const rom = new Uint8Array(0x150);
rom[0x147] = 0xfc;
const album = (at) => {
  const sav = random(0x20000);
  const table = new Uint8Array(30).fill(0xff);
  [[0, 4], [1, 0], [3, 2], [7, 1], [29, 3]].forEach(([slot, n]) => { table[slot] = n; });
  sav.set(table, at);
  sav.set(new TextEncoder().encode("Magic"), at + 30);
  return sav;
};
const main = album(0x11b2);
const backup = album(0x11d7);
backup.fill(0, 0x11b2 + 30, 0x11b2 + 35); // the main copy's "Magic" gone
put("camera.rom", rom);
put("camera-main.sav", main);
put("camera-backup.sav", backup);

// A zip: info.json, a name with a folder and non-ASCII, an empty file, a
// bigger one.
const ms = new Date(2026, 9, 7, 11, 48, 31, 250).getTime();
const zipFiles = [
  { name: "info.json", data: new TextEncoder().encode('{"app":"dingbat"}\n') },
  { name: "dingbat save states/Moments/2026-10-07 11-48 (2).state", data: random(3000) },
  { name: "pictures/Box art é — ☃.png", data: random(17) },
  { name: "Crystal.sav", data: random(32768) },
];
zipFiles.forEach((f, i) => put(`zip${i}.bin`, f.data));

const names = ['a/b:c*?"<>|d', "  spaced  ", "\u0001ctl\u001f", "", "   ", "Pokémon — Crystal (Rev 1)"];
const files = [{ path: "Crystal.gbc", kind: "rom" }, { path: 'odd "quote" \\ path/é.png', kind: "art" }];
// Adding a zip back as a game: one of ours names its ROM and box art (the
// library thumbnail, bigger, must not become the cover); anyone else's
// gives the largest image.
const addRom = random(4096), thumb = random(900), art = random(300);
const addInfo = { app: "dingbat", format: 1, game: "Crystal.gbc", system: "GBC", exported: "x",
                  files: [{ path: "Crystal.gbc", kind: "rom" }, { path: "pictures/Thumbnail.jpg", kind: "thumb" },
                          { path: "pictures/Box art.png", kind: "art" }] };
const zipOf = (entries) => Buffer.concat(web.ZipWrite.build(entries, new Date(ms)).map((p) => Buffer.from(p)));
put("addback-export.zip", zipOf([{ name: "info.json", data: new TextEncoder().encode(JSON.stringify(addInfo)) },
  { name: "Crystal.gbc", data: addRom }, { name: "pictures/Thumbnail.jpg", data: thumb },
  { name: "pictures/Box art.png", data: art }]));
put("addback-other.zip", zipOf([{ name: "Crystal.gbc", data: addRom }, { name: "small.png", data: art },
  { name: "big.jpg", data: thumb }]));

put("spec.json", JSON.stringify({ ms, zipNames: zipFiles.map((f) => f.name), names, game: "Pokémon \"Crystal\".gbc",
                                  system: "GBC", files }));

// The Swift side.
const bin = join(dir, "export-core");
execFileSync("xcrun", ["swiftc", "-O", "-o", bin, join(ROOT, "ios/Dingbat/Sources/ExportCore.swift"),
                       join(ROOT, "ios/Dingbat/Sources/ZipReader.swift"),
                       join(ROOT, "ios/e2e/export-core/main.swift")], { stdio: "inherit" });
execFileSync(bin, [dir], { stdio: "inherit" });
const swift = (name) => new Uint8Array(readFileSync(join(dir, "swift-" + name)));

let failed = 0;
const check = (what, fn) => {
  try { fn(); console.log("ok   " + what); } catch (e) { failed++; console.log("FAIL " + what + ": " + e.message); }
};
const same = (a, b, what) => {
  assert.equal(a.length, b.length, what + ": lengths " + a.length + " vs " + b.length);
  const i = a.findIndex((v, k) => v !== b[k]);
  assert.equal(i, -1, what + ": first difference at byte " + i);
};

for (const [c, sav] of [["camera-main", main], ["camera-backup", backup]]) {
  check(c + " photos", () => {
    const parts = [];
    for (const p of web.cameraPhotos(rom, sav)) {
      parts.push(new TextEncoder().encode(p.number + ":"), web.greyPng2(p.pixels, 128, 112));
    }
    assert.equal(parts.length, 10, "five photos on the web side");
    const joined = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
    let o = 0;
    for (const p of parts) { joined.set(p, o); o += p.length; }
    same(swift(c + ".bin"), joined, c);
  });
}
check("zip", () => {
  const parts = web.ZipWrite.build(zipFiles, new Date(ms));
  const joined = Buffer.concat(parts.map((p) => Buffer.from(p)));
  same(swift("zip.zip"), new Uint8Array(joined), "zip");
  // And it opens: unzip -t on the Swift one.
  writeFileSync(join(dir, "check.zip"), swift("zip.zip"));
  execFileSync("unzip", ["-tq", join(dir, "check.zip")]);
});
check("info.json", () => {
  const info = { app: "dingbat", format: 1, game: 'Pokémon "Crystal".gbc', system: "GBC",
                 exported: new Date(ms).toISOString(), files };
  same(swift("info.json"), new TextEncoder().encode(JSON.stringify(info, null, 2) + "\n"), "info.json");
});
check("names and stamps", () => {
  const t = JSON.parse(readFileSync(join(dir, "swift-text.json"), "utf8"));
  assert.deepEqual(t.safe, names.map(web.exportSafeName));
  assert.equal(t.stamp, web.exportStamp(ms));
  assert.equal(t.day, web.exportDay(ms));
});

check("adding a zip back", () => {
  const p = JSON.parse(readFileSync(join(dir, "swift-addback.json"), "utf8"));
  assert.deepEqual(p["addback-export"], { rom: "Crystal.gbc", romLen: addRom.length, artLen: art.length },
                   "our export: its box art, not the bigger thumbnail");
  assert.deepEqual(p["addback-other"], { rom: "Crystal.gbc", romLen: addRom.length, artLen: thumb.length },
                   "anyone else's zip: the largest image");
});

rmSync(dir, { recursive: true, force: true });
console.log(failed ? `\n${failed} check(s) failed` : "\nall passed");
process.exit(failed ? 1 : 0);
