// The iOS app and the web build as two devices of one Google Drive account:
// a browser (the real web build, web/e2e/devices.mjs) and the app in a
// headless iOS simulator, both talking to one fake Drive
// (web/e2e/fakedrive.mjs). The browser reaches it through Playwright's
// routing; the app through this script's HTTP server and the app's debug
// `-drive-stub` flag. Nothing leaves the machine, and the app runs muted.
//
//   ios/build-core.sh sim && (cd ios && xcodegen generate)
//   xcodebuild ... -sdk iphonesimulator -derivedDataPath <dd> build   # Debug
//   nim c -d:emscripten src/dingbat_wasm.nim       # web/em.wasm
//   node ios/e2e/drive-sync.mjs <path to Dingbat.app> [simulator udid]
//
// Cases: a game started on the web resumes on the iPhone at the web's
// moment; the iPhone's session then goes up, and the web device, holding
// the game paused, hands off to it ("played on your iPhone since"); a quiet
// round rewrites no library file (the app writes it byte-identical); a
// rename on the web moves the iPhone's records; a delete on the web takes
// the game off the iPhone and leaves nothing of it on Drive.

import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import assert from "node:assert/strict";
import {
  startRig, builtWeb, GAME, sleep, addGame, play, mainMenu, syncNow, idle, toasts,
} from "../../web/e2e/devices.mjs";

const APP = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV || "20B3E400-B140-4C0D-A981-A87BDBEDAEF9";
const BUNDLE = "com.mattrb.dingbat";
if (!APP) { console.error("usage: node ios/e2e/drive-sync.mjs <Dingbat.app> [udid]"); process.exit(2); }
if (!builtWeb()) { console.error("web/em.wasm not built"); process.exit(2); }

const simctl = (...a) => execFileSync("xcrun", ["simctl", ...a], { encoding: "utf8" });
const trySimctl = (...a) => { try { return simctl(...a); } catch { return ""; } };

// The fake Drive over HTTP, for the app: /<host>/<path> is https://<host>/<path>.
const serveDrive = (drive) => new Promise((resolve) => {
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
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

// A fresh install, muted, launched with `args`.
const launchApp = (args, { fresh = false } = {}) => {
  trySimctl("boot", UDID);
  simctl("bootstatus", UDID);
  trySimctl("terminate", UDID, BUNDLE);
  if (fresh) {
    trySimctl("uninstall", UDID, BUNDLE);
    simctl("install", UDID, APP);
  }
  // Settings as launch arguments (the app's argument domain): a
  // `defaults write` through simctl can land outside the app's container.
  simctl("launch", UDID, BUNDLE, "-audio.muted", "YES", "-hide-touch-on-gamepad", "NO", ...args);
};

// The games the app holds records of (its per-game folders).
const gamesOnPhone = () => {
  const data = simctl("get_app_container", UDID, BUNDLE, "data").trim();
  try {
    return readdirSync(join(data, "Library/Application Support/dingbat/games"))
      .filter((n) => existsSync(join(data, "Library/Application Support/dingbat/games", n, "rom.sav")) ||
                     existsSync(join(data, "Documents/roms", n)));
  } catch { return []; }
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
try {
  // 1. The web device starts the game, saves in it, leaves it (the session).
  const web = await rig.device(drive, "web", "mac");
  await addGame(web);
  await play(web, 40);
  await mainMenu(web);
  await syncNow(web);
  const webSession = drive.session(GAME);
  assert.ok(drive.get("rom:" + GAME) && drive.get("save:" + GAME) && webSession, "the web's files are on Drive");
  console.log("web session:", webSession);

  // 2. The iPhone: a fresh install pulls the library, opens the game from
  // Drive and resumes the web's session.
  launchApp(["-drive-stub", stub.base, "-autoplay", GAME, "-resume", "-home-after", "8"], { fresh: true });
  await until("the app to fetch the ROM", () =>
    drive.log.some((e) => e.who === "ios" && e.method === "GET" && e.name === "rom:" + GAME), 40000);
  console.log("ios fetched:", [...new Set(drive.log.filter((e) => e.who === "ios" && e.name).map((e) => e.name))].join(", "));
  await sleep(6000);
  console.log("screenshot (resumed):", shot("ios-resumed"));

  // 3. Main Menu on the iPhone (14 s in): its session goes up.
  const iosSession = await until("the iPhone's session on Drive", () => {
    const s = drive.session(GAME);
    return s && s.dev === "iPhone" ? s : null;
  }, 40000);
  console.log("ios session:", iosSession);
  console.log("screenshot (home):", shot("ios-home"));
  assert.ok(iosSession.ts > webSession.ts, "the iPhone's session is the newer");
  const lib = JSON.parse(drive.get("library").bytes.toString("utf8"));
  assert.ok(lib.recents.some((e) => e.name === GAME), "the library still lists the game");

  // 4. Back on the web device, holding the game paused: the pull hands off.
  await syncNow(web);
  await idle(web);
  const said = await until("the hand-off toast", async () =>
    (await toasts(web)).find((t) => t.includes("played on your iPhone")), 20000);
  console.log("web says:", said);

  // 5. No churn: a second round of syncs on both sides writes no library.
  const writes = () => drive.log.filter((e) => e.name === "library" && e.method !== "GET").length;
  const before = writes();
  await syncNow(web);
  await idle(web);
  launchApp(["-drive-stub", stub.base]);
  await sleep(12000);
  const after = writes();
  console.log("library writes in a quiet round:", after - before);
  assert.equal(after - before, 0, "a quiet round rewrites the library");

  // 6. A rename on the web reaches the iPhone: its records move to the new
  // name, and nothing goes back up under the old one.
  const NEW = "synctest renamed.gb";
  const r = await web.page.evaluate(async ([g, n]) => {
    if (currentOriginalName === g) await unloadGame({});
    return renameGame(g, n);
  }, [GAME, NEW]);
  assert.ok(r.ok, "the web renamed it: " + JSON.stringify(r));
  await syncNow(web);
  await idle(web);
  const mark = drive.log.length;
  launchApp(["-drive-stub", stub.base]);
  await sleep(12000);
  const games = gamesOnPhone();
  console.log("games on the iPhone:", games.join(", "));
  assert.ok(games.includes(NEW) && !games.includes(GAME), "the iPhone's records moved");
  const oldNames = drive.files.filter((f) => f.name.endsWith(":" + GAME) || f.name.includes(":" + GAME + ":"));
  assert.equal(oldNames.length, 0, "no file under the old name: " + oldNames.map((f) => f.name));
  assert.ok(!drive.log.slice(mark).some((e) => e.who === "ios" && e.method !== "GET" && e.name?.includes(GAME + "")
    && !e.name.includes(NEW)), "the iPhone sent nothing under the old name");

  // 7. A delete on the web: the iPhone (told "Continue") lets the game go,
  // and Drive keeps nothing of it.
  await web.page.evaluate((n) => deleteGameEverywhere(n), NEW);
  await syncNow(web);
  await idle(web);
  launchApp(["-drive-stub", stub.base, "-answer-tombstones", "continue"]);
  await sleep(12000);
  const left = gamesOnPhone();
  console.log("games on the iPhone after the delete:", left.join(", "));
  assert.ok(!left.includes(NEW), "the iPhone dropped the deleted game");
  const lingering = drive.files.filter((f) => f.name.includes(NEW));
  assert.equal(lingering.length, 0, "Drive holds nothing of it: " + lingering.map((f) => f.name));
  console.log("PASS");
} catch (e) {
  failed = true;
  console.error("FAIL:", e.message);
  console.error("drive log tail:", JSON.stringify(drive.log.slice(-25)));
  console.error("screenshot:", shot("ios-fail"));
} finally {
  stopApp();
  stub.close();
  await rig.endTest();
  await rig.close();
}
process.exit(failed ? 1 : 0);
