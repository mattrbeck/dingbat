// A tap on the iPhone while its boot pull is out, end to end: the iPhone
// holds an older moment of the game than Drive, relaunches with the fake
// Drive held back, and is tapped into the game at once. The tap waits
// ("Checking Drive…") and the game opens on the web's newer moment - so the
// session the iPhone sends next carries the web's save, not its own older
// one (DriveSync.holdForBootPull; docs/home-screen.md, "The first sync").
//
//   ios/build-core.sh sim && (cd ios && xcodegen generate)
//   xcodebuild ... -sdk iphonesimulator -derivedDataPath <dd> build   # Debug
//   nim c -d:emscripten src/dingbat_wasm.nim       # web/em.wasm
//   node ios/e2e/boot-hold.mjs <path to Dingbat.app> [simulator udid]

import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";
import {
  startRig, builtWeb, GAME, sleep, addGame, play, mainMenu, syncNow, front,
} from "../../web/e2e/devices.mjs";

const APP = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV || "20B3E400-B140-4C0D-A981-A87BDBEDAEF9";
const BUNDLE = "com.mattrb.dingbat";
const MUTED = ["-audio.muted", "YES"];
if (!APP) { console.error("usage: node ios/e2e/boot-hold.mjs <Dingbat.app> [udid]"); process.exit(2); }
if (!builtWeb()) { console.error("web/em.wasm not built"); process.exit(2); }

const simctl = (...a) => execFileSync("xcrun", ["simctl", ...a], { encoding: "utf8" });
const trySimctl = (...a) => { try { return simctl(...a); } catch { return ""; } };

// The fake Drive over HTTP, for the app (as drive-sync.mjs), with a gate:
// while it is shut, every request waits.
let gate = Promise.resolve();
const serveDrive = (drive) => new Promise((resolve) => {
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    await gate;
    const body = Buffer.concat(chunks);
    const [, host, ...rest] = req.url.split("/");
    const url = "https://" + host + "/" + rest.join("/");
    const route = {
      request: () => ({ url: () => url, method: () => req.method, postDataBuffer: () => body,
                        headers: () => req.headers }),
      fulfill: async ({ status = 200, contentType, body: b, headers = {} }) => {
        res.writeHead(status, { "Content-Type": contentType || "application/octet-stream", ...headers });
        res.end(b);
      },
      abort: async () => { res.writeHead(502); res.end(); },
    };
    await drive.handle(route, "ios");
  });
  server.listen(0, "127.0.0.1", () =>
    resolve({ base: `http://127.0.0.1:${server.address().port}`, close: () => server.close() }));
});

const shot = (name) => {
  const out = `${process.env.SHOTS || "/tmp"}/${name}.png`;
  trySimctl("io", UDID, "screenshot", out);
  return out;
};
const launchApp = (args, { fresh = false } = {}) => {
  trySimctl("boot", UDID);
  simctl("bootstatus", UDID);
  trySimctl("terminate", UDID, BUNDLE);
  if (fresh) {
    trySimctl("uninstall", UDID, BUNDLE);
    simctl("install", UDID, APP);
  }
  simctl("launch", UDID, BUNDLE, ...MUTED, ...args);
};
const stopApp = () => { trySimctl("terminate", UDID, BUNDLE); trySimctl("shutdown", UDID); };
const until = async (what, fn, ms = 30000) => {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error("timed out waiting for " + what);
    await sleep(500);
  }
};

const rig = await startRig();
const drive = rig.drive();
const stub = await serveDrive(drive);
let failed = false;
let open = null;
try {
  // 1. The web starts the game and leaves it.
  const web = await rig.device(drive, "web", "mac");
  await addGame(web);
  await play(web, 40);
  await mainMenu(web);
  await syncNow(web);

  // 2. The iPhone takes it up, and goes home: its session goes up.
  launchApp(["-drive-stub", stub.base, "-autoplay", GAME, "-resume", "-home-after", "4"], { fresh: true });
  const first = await until("the iPhone's first session", () => {
    const s = drive.session(GAME);
    return s && s.dev === "iPhone" ? s : null;
  }, 60000);
  console.log("iPhone's first session:", first);
  trySimctl("terminate", UDID, BUNDLE);

  // 3. The web picks it up and plays on: Drive's moment is newer than the
  //    iPhone's own.
  await syncNow(web);
  await front(web);
  await web.page.click("#hero-resume");
  await sleep(800);
  await play(web, 120);
  await mainMenu(web);
  await syncNow(web);
  const newer = drive.session(GAME);
  console.log("the web's newer session:", newer);
  assert.equal(newer.dev, "Mac");
  assert.notEqual(newer.saveSig, first.saveSig, "the web's save moved on");

  // 4. The iPhone relaunches with Drive held back, and is tapped into the
  //    game 1.5 s in (-tap -from tile: as a tap on its tile).
  gate = new Promise((r) => { open = r; });
  const sent = drive.log.length;
  launchApp(["-drive-stub", stub.base, "-autoplay", GAME, "-tap", "-resume", "-from", "tile",
             "-home-after", "4"]);
  await sleep(3500);
  console.log("screenshot (held):", shot("ios-boot-hold"));
  open();

  // 5. Its next session carries the web's save: the game opened on it.
  const after = await until("the iPhone's next session", () => {
    const s = drive.session(GAME);
    return s && s.dev === "iPhone" && s.ts > newer.ts ? s : null;
  }, 60000);
  console.log("iPhone's session after the hold:", after);
  console.log("iPhone fetched:", [...new Set(drive.log.slice(sent).filter((e) => e.who === "ios" && e.name)
    .map((e) => e.method + " " + e.name))].join(", "));
  assert.equal(after.saveSig, newer.saveSig, "opened on the web's newer save, not its own older one");
  console.log("PASS");
} catch (e) {
  failed = true;
  console.error(e);
} finally {
  open?.();
  stopApp();
  stub.close();
  await rig.endTest();
  await rig.close();
}
process.exit(failed ? 1 : 0);
