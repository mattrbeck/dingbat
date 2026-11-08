// Add pictures against Drive's own pictures, end to end, in two cases. Drive
// already has a picture of each game, which a fresh install holds with none.
//
// 1. The boot's pull held back: the first-run offer does not come (the game
//    may yet get its picture), a run started from the library head says
//    "Waiting for Drive…" and its Stop ends it at once; once Drive answers,
//    its picture comes down, no offer comes (nothing is left unpictured),
//    and no picture of the game goes up (AddPictures.offerAfterBoot,
//    DriveSync.waitForFirstPull).
// 2. Drive down at boot: the pull fails, a run pictures the game's boot
//    screen; Drive back and the app back in front, which sends what is
//    queued before it pulls: the boot screen does not go up over Drive's
//    picture, and Drive's comes down instead (DriveSync.uploadOne).
//
// The app's tmp/addpictures.txt (with -debug-events) says what Add pictures
// did; its debug notifications pictures-run and pictures-stop are the head's
// Add pictures and the run's Stop.
//
//   ios/build-core.sh sim && (cd ios && xcodegen generate)
//   xcodebuild ... -sdk iphonesimulator -derivedDataPath <dd> build   # Debug
//   node ios/e2e/pictures-hold.mjs <path to Dingbat.app> [simulator udid]

import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, copyFileSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";
import { makeDrive } from "../../web/e2e/fakedrive.mjs";

const APP = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV || "20B3E400-B140-4C0D-A981-A87BDBEDAEF9";
const BUNDLE = "com.mattrb.dingbat";
const GAME = "linktest.gba";  // a blank screen: a run never pictures it
const GAME2 = "gbedge.gb";    // a real screen, which a run does picture
const ROOT = new URL("../..", import.meta.url).pathname;
if (!APP) { console.error("usage: node ios/e2e/pictures-hold.mjs <Dingbat.app> [udid]"); process.exit(2); }

const simctl = (...a) => execFileSync("xcrun", ["simctl", ...a], { encoding: "utf8" });
const trySimctl = (...a) => { try { return simctl(...a); } catch { return ""; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (what, fn, ms = 30000) => {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error("timed out waiting for " + what);
    await sleep(250);
  }
};

// The fake Drive over HTTP, for the app (as boot-hold.mjs), with a gate:
// while it is shut, every request waits; while `down`, every request fails.
let gate = Promise.resolve();
let down = false;
const serveDrive = (drive) => new Promise((resolve) => {
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    await gate;
    if (down) { res.writeHead(503); res.end(); return; }
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

// Drive's side: the library with both games in it, and a picture of each
// this device has never seen (a JPEG of the app's icon, 240x160).
const drive = makeDrive();
const scratch = mkdtempSync(join(tmpdir(), "pictures-hold-"));
const jpgPath = join(scratch, "frame.jpg");
execFileSync("sips", ["-s", "format", "jpeg", "-z", "160", "240", join(ROOT, "web/flap.png"), "--out", jpgPath],
             { stdio: "ignore" });
const picture = readFileSync(jpgPath);
const seeded = "2026-09-30T09:00:00.000Z";
const seed = (name, bytes) => drive.files.push({
  id: "seed-" + drive.files.length, name, bytes, modifiedTime: seeded, createdTime: seeded,
});
seed("library", Buffer.from(JSON.stringify({
  recents: [GAME, GAME2].map((name) => ({ name, ts: Date.parse(seeded) })), tomb: [], ren: [],
})));
seed("frame:" + GAME, picture);
seed("frame:" + GAME2, picture);
const stub = await serveDrive(drive);

const launch = () =>
  simctl("launch", UDID, BUNDLE, "-audio.muted", "YES", "-debug-events", "-drive-stub", stub.base);
// A fresh install holding `game`, with no picture of it, launched.
const freshLaunch = (game) => {
  trySimctl("boot", UDID);
  simctl("bootstatus", UDID);
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("uninstall", UDID, BUNDLE);
  simctl("install", UDID, APP);
  const data = simctl("get_app_container", UDID, BUNDLE, "data").trim();
  mkdirSync(join(data, "Documents/roms"), { recursive: true });
  copyFileSync(join(ROOT, "tests/roms", game), join(data, "Documents/roms", game));
  const logFile = join(data, "tmp/addpictures.txt");
  launch();
  return {
    frame: join(data, "Library/Application Support/dingbat/games", game, "frame.jpg"),
    log: () => (existsSync(logFile) ? readFileSync(logFile, "utf8").trim().split("\n") : [])
      .map((l) => { const i = l.indexOf(" "); return { t: Number(l.slice(0, i)), what: l.slice(i + 1) }; }),
  };
};
const post = (name) => simctl("spawn", UDID, "notifyutil", "-p", "com.mattrb.dingbat.debug." + name);
const uploads = (game, from = 0) => drive.log.slice(from)
  .filter((e) => e.who === "ios" && e.name === "frame:" + game && e.method !== "GET");
const calls = (from = 0) => [...new Set(drive.log.slice(from).filter((e) => e.who === "ios")
  .map((e) => e.method + " " + (e.name || e.path)))].join(", ");

let open = null;
let failed = false;
try {
  // Case 1: the boot's pull held back.
  gate = new Promise((r) => { open = r; });
  const one = freshLaunch(GAME);

  // Held: no offer, though the home screen has long settled (and the gate
  // still opens well before launch + 15 s, the wait's cap).
  await sleep(8000);
  assert.ok(!one.log().some((e) => e.what === "offer"),
            "no offer while Drive's pull is held: " + JSON.stringify(one.log()));
  assert.ok(!existsSync(one.frame), "no picture of the game yet");

  // The library head's Add pictures, held: the run waits, and Stop ends it
  // at once.
  post("pictures-run");
  await until("the run to wait for Drive", () => one.log().some((e) => e.what === "wait"), 5000);
  post("pictures-stop");
  const end = await until("the run to end", () => one.log().find((e) => e.what.startsWith("end ")), 5000);
  const stop = one.log().find((e) => e.what === "stop");
  const tookMs = end.t - stop.t;  // the app's own clock
  console.log("run during the hold:", one.log().map((e) => e.what).join(" | "),
              `(ended ${tookMs} ms after Stop)`);
  assert.equal(end.what, "end Stopped", "a Stop before the first says so");
  assert.ok(tookMs < 1000, "Stop ends the wait at once, not at the cap");
  assert.ok(!existsSync(one.frame), "the stopped run pictured nothing");

  // Drive answers: its picture comes down, and nothing is left to offer.
  open();
  await until("Drive's picture on the device",
              () => existsSync(one.frame) && readFileSync(one.frame).equals(picture), 30000);
  await sleep(5000);  // past the offer's settle
  console.log("iPhone's Drive calls:", calls());
  assert.ok(!one.log().some((e) => e.what === "offer"), "no offer: the game has its picture from Drive");
  assert.ok(readFileSync(one.frame).equals(picture), "still Drive's picture");
  assert.equal(uploads(GAME).length, 0, "no picture of the game went up");
  assert.ok(drive.get("frame:" + GAME).bytes.equals(picture), "Drive keeps its picture");
  console.log("PASS: the pull held back");

  // Case 2: Drive down at boot.
  down = true;
  const from = drive.log.length;
  const two = freshLaunch(GAME2);
  await sleep(4000);
  post("pictures-run");
  const end2 = await until("the run while Drive is down",
                           () => two.log().find((e) => e.what.startsWith("end ")), 30000);
  console.log("run while Drive was down:", two.log().map((e) => e.what).join(" | "));
  assert.equal(end2.what, "end 1 picture added", "the run pictured the game's own screen");
  assert.ok(!readFileSync(two.frame).equals(picture), "a boot screen, not Drive's picture");
  await sleep(2000);
  down = false;
  // Away and back: willEnterForeground sends what is queued, then pulls.
  simctl("launch", UDID, "com.apple.Preferences");
  await sleep(2000);
  launch();
  await until("Drive's picture on the device", () => readFileSync(two.frame).equals(picture), 30000);
  await sleep(3000);
  console.log("iPhone's Drive calls, back in front:", calls(from));
  assert.equal(uploads(GAME2, from).length, 0, "the boot screen did not go up over Drive's picture");
  assert.ok(drive.get("frame:" + GAME2).bytes.equals(picture), "Drive keeps its picture");
  console.log("PASS: Drive down at boot");
} catch (e) {
  failed = true;
  console.error(e);
} finally {
  open?.();
  trySimctl("terminate", UDID, "com.apple.Preferences");
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("shutdown", UDID);
  stub.close();
  rmSync(scratch, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
