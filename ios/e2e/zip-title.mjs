// A game added from a zip on the iPhone is shown under the zip's name, and
// the title travels through Drive's library with the web's: the app (a
// headless simulator, muted) signed in to a fake Drive (web/e2e/fakedrive.mjs
// through the app's debug `-drive-stub`) that holds a library the web wrote
// with a titled game. No browser: the web's side is its own code in node:vm.
//
//   ios/build-core.sh sim && (cd ios && xcodegen generate)
//   xcodebuild ... -sdk iphonesimulator -derivedDataPath <dd> build   # Debug
//   node ios/e2e/zip-title.mjs <path to Dingbat.app> [simulator udid]
//
// Cases: the app adds "Pokemon Collection.zip" (`-import`): its entry and
// Drive's carry the zip's name as `title`, beside the web's titled game,
// which the app's write keeps; a relaunch reads them back and a quiet
// round writes no library; adding the bare ROM drops the title, here and on
// Drive. Then another ROM of the same name from a zip (`-answer-rom-clash`):
// Replace gives the game the zip's name, Keep both puts the new one beside
// it under the zip's name, numbered when it would read as the other's. A
// title Drive holds with control characters and past 100 is cleaned here
// and on the app's write. Screenshots of the home screen go to $SHOTS
// (default /tmp).

import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import assert from "node:assert/strict";
import { makeDrive } from "../../web/e2e/fakedrive.mjs";
import { synctestRom, SYNCTEST_NAME as ROM } from "../../web/e2e/synctest-rom.mjs";

const APP = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV;
const BUNDLE = "com.mattrb.dingbat";
const MUTED = ["-audio.muted", "YES"];
if (!APP || !UDID) { console.error("usage: node ios/e2e/zip-title.mjs <Dingbat.app> <udid>"); process.exit(2); }

const ROOT = new URL("../..", import.meta.url).pathname;
const { loadApp } = await import(join(ROOT, "web/tests/helpers.mjs"));
const web = (await loadApp()).runIn("({ mergeLibrary, driveLibraryOf, ZipWrite: globalThis.ZipWrite ?? ZipWrite })");

const simctl = (...a) => execFileSync("xcrun", ["simctl", ...a], { encoding: "utf8" });
const trySimctl = (...a) => { try { return simctl(...a); } catch { return ""; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (what, fn, ms = 40000) => {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error("timed out waiting for " + what);
    await sleep(500);
  }
};

const serveDrive = (drive) => new Promise((resolve) => {
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks);
    const [, host, ...rest] = req.url.split("/");
    const url = "https://" + host + "/" + rest.join("/");
    await drive.handle({
      request: () => ({ url: () => url, method: () => req.method, postDataBuffer: () => body, headers: () => req.headers }),
      fulfill: async ({ status = 200, contentType, body: b, headers = {} }) => {
        res.writeHead(status, { "Content-Type": contentType || "application/octet-stream", ...headers });
        res.end(b);
      },
      abort: async () => { res.writeHead(502); res.end(); },
    }, "ios");
  });
  server.listen(0, "127.0.0.1", () =>
    resolve({ base: `http://127.0.0.1:${server.address().port}`, close: () => server.close() }));
});

const shots = process.env.SHOTS || "/tmp";
mkdirSync(shots, { recursive: true });
const shot = (name) => { const out = join(shots, name + ".png"); trySimctl("io", UDID, "screenshot", out); return out; };
const launch = (args) => {
  trySimctl("terminate", UDID, BUNDLE);
  simctl("launch", UDID, BUNDLE, ...MUTED, ...args);
};
const container = () => simctl("get_app_container", UDID, BUNDLE, "data").trim();
const recent = () => {
  try {
    return JSON.parse(readFileSync(join(container(), "Library/Application Support/dingbat/recent.json"), "utf8"));
  } catch { return []; }
};
const titleIn = (list, name) => list.find((r) => r.name === name)?.title;

// Drive as the web left it: a game added there from "Web Pack.zip".
const WEBGAME = "Web Game.gb";
const drive = makeDrive();
const now = Date.now() - 60000;
// And one whose title only an odd writer would leave: raw, not merged.
const ODDGAME = "Odd Game.gb";
const SMILE = "\u{1F600}";
const ODD = "\u001b[1m Odd\r\nPack " + SMILE.repeat(60);
const ODD_CLEAN = "[1m Odd  Pack " + SMILE.repeat(43);
const webLibObj = web.driveLibraryOf(web.mergeLibrary(
  { recents: [{ name: WEBGAME, ts: now, imp: now, title: "Web Pack" }], tomb: [], ren: [] },
  { recents: [], tomb: [], ren: [] }));
webLibObj.recents.push({ name: ODDGAME, ts: now - 1000, imp: now - 1000, title: ODD });
const webLib = JSON.stringify(webLibObj);
const t0 = new Date(now).toISOString();
drive.files.push({ id: "w0", name: "library", bytes: Buffer.from(webLib), modifiedTime: t0, createdTime: t0 },
                 { id: "w1", name: "rom:" + WEBGAME, bytes: Buffer.from(synctestRom()), modifiedTime: t0, createdTime: t0 },
                 { id: "w2", name: "rom:" + ODDGAME, bytes: Buffer.from(synctestRom()), modifiedTime: t0, createdTime: t0 });
// Another game under the ROM's name: the same ROM, one byte past its code changed.
const otherRom = (b) => { const r = synctestRom(); r[r.length - 1] = b; return r; };
const zipAt = (path, rom) => writeFileSync(path, Buffer.concat(
  web.ZipWrite.build([{ name: ROM, data: rom }], new Date(now)).map((p) => Buffer.from(p))));
const ROM2 = ROM.replace(/\.gb$/, " (2).gb");
const driveLib = () => JSON.parse(drive.get("library").bytes.toString("utf8"));
const libWrites = () => drive.log.filter((e) => e.name === "library" && e.method !== "GET").length;

const stub = await serveDrive(drive);
let failed = false;
try {
  trySimctl("boot", UDID);
  simctl("bootstatus", UDID);
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("uninstall", UDID, BUNDLE);
  simctl("install", UDID, APP);
  const tmp = join(container(), "tmp");
  mkdirSync(tmp, { recursive: true });
  const zip = join(tmp, "Pokemon Collection.zip");
  writeFileSync(zip, Buffer.concat(web.ZipWrite.build([{ name: ROM, data: synctestRom() }], new Date(now))
    .map((p) => Buffer.from(p))));

  // 1. The zip, added on the iPhone.
  launch(["-drive-stub", stub.base, "-import", zip]);
  await until("the iPhone's game in Drive's library", () =>
    driveLib().recents.some((r) => r.name === ROM) && drive.get("rom:" + ROM));
  await sleep(3000);
  let lib = driveLib();
  console.log("Drive's library:", JSON.stringify(lib.recents));
  assert.equal(titleIn(lib.recents, ROM), "Pokemon Collection", "Drive has the zip's name");
  assert.equal(titleIn(lib.recents, WEBGAME), "Web Pack", "the app's write kept the web's title");
  assert.ok(!drive.files.some((f) => f.name.includes("Pokemon Collection")), "no file under the zip's name");
  let here = recent();
  console.log("recent.json:", JSON.stringify(here));
  assert.equal(titleIn(here, ROM), "Pokemon Collection", "the app's index has it");
  assert.equal(titleIn(here, WEBGAME), "Web Pack", "and the web's");
  console.log("screenshot (home):", shot("zip-title-home"));

  // 2. Relaunched: read back from recent.json; a quiet round writes nothing.
  const before = libWrites();
  launch(["-drive-stub", stub.base]);
  await sleep(12000);
  assert.equal(libWrites() - before, 0, "a quiet round rewrites the library");
  assert.equal(titleIn(recent(), ROM), "Pokemon Collection");
  console.log("screenshot (relaunched):", shot("zip-title-relaunched"));

  // 3. The bare ROM added again: a new claim, no title, here and on Drive.
  const bare = join(tmp, ROM);
  writeFileSync(bare, synctestRom());
  launch(["-drive-stub", stub.base, "-import", bare]);
  await until("Drive's library without the title", () =>
    driveLib().recents.some((r) => r.name === ROM && r.title === undefined));
  await sleep(2000);
  lib = driveLib();
  console.log("Drive's library after the bare ROM:", JSON.stringify(lib.recents));
  assert.equal(titleIn(recent(), ROM), undefined, "the app's index dropped it");
  assert.equal(titleIn(lib.recents, WEBGAME), "Web Pack", "the web's game keeps its own");
  console.log("screenshot (bare):", shot("zip-title-bare"));

  // 4. Drive's odd title, cleaned here and in the app's write.
  assert.equal(titleIn(recent(), ODDGAME), ODD_CLEAN, "the app's index has Drive's odd title cleaned");
  assert.equal(titleIn(lib.recents, ODDGAME), ODD_CLEAN, "and wrote it back cleaned");

  // 5. Another ROM under the name, from "GBA Pack.zip", Replace: the game
  // takes the zip's name, at the next generation.
  const genBefore = recent().find((r) => r.name === ROM)?.gen || 0;
  const pack = join(tmp, "GBA Pack.zip");
  zipAt(pack, otherRom(1));
  launch(["-drive-stub", stub.base, "-answer-rom-clash", "replace", "-import", pack]);
  await until("Drive's library with the replaced game's title", () =>
    titleIn(driveLib().recents, ROM) === "GBA Pack");
  here = recent();
  assert.equal(titleIn(here, ROM), "GBA Pack", "Replace: the zip's name");
  assert.equal(here.find((r) => r.name === ROM).gen, genBefore + 1, "Replace: the next generation");
  assert.ok(!here.some((r) => r.name === ROM2), "Replace: one game");
  console.log("screenshot (replaced):", shot("zip-title-replaced"));

  // 6. And again, Keep both: beside it, numbered as its file is since the
  // two would read the same.
  zipAt(pack, otherRom(2));
  launch(["-drive-stub", stub.base, "-answer-rom-clash", "both", "-import", pack]);
  await until("Drive's library with the kept game", () => driveLib().recents.some((r) => r.name === ROM2));
  await sleep(2000);
  here = recent();
  assert.equal(titleIn(here, ROM2), "GBA Pack (2)", "Keep both: numbered as its file");
  assert.equal(titleIn(here, ROM), "GBA Pack", "the first game keeps its own");
  assert.equal(titleIn(driveLib().recents, ROM2), "GBA Pack (2)");
  console.log("screenshot (kept both):", shot("zip-title-both"));
  console.log("PASS");
} catch (e) {
  failed = true;
  console.error("FAIL:", e.message);
  console.error("drive log tail:", JSON.stringify(drive.log.slice(-20)));
  console.error("screenshot:", shot("zip-title-fail"));
} finally {
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("shutdown", UDID);
  stub.close();
}
process.exit(failed ? 1 : 0);
