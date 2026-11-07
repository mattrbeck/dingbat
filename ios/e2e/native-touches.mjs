// The native touches (docs/manual-verification.md, "iOS: native touches")
// in the simulator: ios/e2e/uitest/NativeTouchesUITests.swift, with the app
// installed and tests/roms/linktest.gba in its library, and a fake Drive
// (web/e2e/fakedrive.mjs) for the pull to refresh. The test posts the system
// events to the app through its `-debug-events` hook (DebugEvents.swift).
//
//   ios/build-core.sh sim && ios/build-webrtc.sh sim
//   xcodegen generate --spec ios/e2e/uitest/project.yml --project ios --project-root ios
//   xcodebuild -project ios/DingbatUITest.xcodeproj -scheme DingbatUITest \
//     -sdk iphonesimulator -destination id=<udid> -derivedDataPath <dd> build-for-testing
//   node ios/e2e/native-touches.mjs <dd> [simulator udid]
//
// Knobs for single tests (each runs only that test, so its library and
// launch arguments reach no other):
//   DB_ROMS=a,b         more ROMs (paths) copied into the library beside
//                       linktest.gba
//   DB_PICTURES="…"     testAddPicturesSkipsBlank: the toast its Add
//                       pictures run must end on
//   DB_GAME=name        testTopBarFits only: the game it launches (default
//                       linktest.gba; give its path in DB_ROMS)
//   DB_BAR_ARGS="…", DB_MUTE=1, DB_TIGHT=1
//                       testTopBarFits: extra launch arguments (the sync
//                       icon: -drive-stub http://127.0.0.1:9), the
//                       channel-mute pill, the row with no room for a reading
//
// A pad paired with the Mac passes through to the simulator; the last-pad
// test then checks the virtual pad's going does not stop the game.

import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { copyFileSync, mkdirSync } from "node:fs";
import { join, basename } from "node:path";
import { makeDrive } from "../../web/e2e/fakedrive.mjs";

const DD = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV || "20B3E400-B140-4C0D-A981-A87BDBEDAEF9";
const ROOT = new URL("../..", import.meta.url).pathname;
const BUNDLE = "com.mattrb.dingbat";
if (!DD) { console.error("usage: node ios/e2e/native-touches.mjs <derivedData> [udid]"); process.exit(2); }
// Extra ROMs are for one test: say which (see the top).
const barKnobs = ["DB_BAR_ARGS", "DB_MUTE", "DB_TIGHT"].some((k) => process.env[k] !== undefined);
if (process.env.DB_ROMS && process.env.DB_PICTURES === undefined && !barKnobs && !process.env.DB_GAME) {
  console.error("DB_ROMS needs DB_PICTURES (testAddPicturesSkipsBlank) or DB_GAME / DB_BAR_ARGS / DB_MUTE / DB_TIGHT (testTopBarFits)");
  process.exit(2);
}
const simctl = (...a) => execFileSync("xcrun", ["simctl", ...a], { encoding: "utf8" });
const trySimctl = (...a) => { try { return simctl(...a); } catch { return ""; } };

// The fake Drive over HTTP for `-drive-stub`, its requests timed.
const requests = [];
const drive = makeDrive();
const server = createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = Buffer.concat(chunks);
  const [, host, ...rest] = req.url.split("/");
  const url = "https://" + host + "/" + rest.join("/");
  requests.push(Date.now());
  await drive.handle({
    request: () => ({ url: () => url, method: () => req.method, postDataBuffer: () => body,
                      headers: () => req.headers }),
    fulfill: async ({ status = 200, contentType, body: b, headers = {} }) => {
      res.writeHead(status, { "Content-Type": contentType || "application/octet-stream", ...headers });
      res.end(b);
    },
    abort: async () => { res.writeHead(502); res.end(); },
  }, "ios");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const stub = `http://127.0.0.1:${server.address().port}`;

trySimctl("boot", UDID);
simctl("bootstatus", UDID);
trySimctl("uninstall", UDID, BUNDLE);
simctl("install", UDID, join(DD, "Build/Products/Debug-iphonesimulator/Dingbat.app"));
const data = simctl("get_app_container", UDID, BUNDLE, "data").trim();
mkdirSync(join(data, "Documents/roms"), { recursive: true });
copyFileSync(join(ROOT, "tests/roms/linktest.gba"), join(data, "Documents/roms/linktest.gba"));
const extraRoms = (process.env.DB_ROMS || "").split(",").filter(Boolean);
for (const r of extraRoms) copyFileSync(r, join(data, "Documents/roms", basename(r)));
// A knob picks its one test (see the top).
const only = process.env.DB_PICTURES !== undefined ? "NativeTouchesUITests/testAddPicturesSkipsBlank"
  : barKnobs || process.env.DB_GAME ? "NativeTouchesUITests/testTopBarFits" : "NativeTouchesUITests";
const forward = Object.fromEntries(["DB_PICTURES", "DB_BAR_ARGS", "DB_MUTE", "DB_TIGHT"]
  .filter((k) => process.env[k] !== undefined).map((k) => ["TEST_RUNNER_" + k, process.env[k]]));

let out = "";
const code = await new Promise((resolve) => {
  const p = spawn("xcodebuild", ["test-without-building", "-project", join(ROOT, "ios/DingbatUITest.xcodeproj"),
    "-scheme", "DingbatUITest", "-destination", `id=${UDID}`, "-derivedDataPath", DD,
    "-only-testing:DingbatUITests/" + only],
    { env: { ...process.env, ...forward, TEST_RUNNER_DB_GAME: process.env.DB_GAME || "linktest.gba",
             TEST_RUNNER_DB_DRIVE: stub },
      stdio: ["ignore", "pipe", "pipe"] });
  p.stdout.on("data", (d) => { out += d; });
  p.stderr.on("data", (d) => { out += d; });
  p.on("close", resolve);
});
server.close();
for (const line of out.split("\n")) {
  if (/NATIVE:|error:|Test Case .*(passed|failed|skipped)|Executed/.test(line)) console.log(line);
}
// The pull to refresh: a sync after the pull, within 5 s.
const pull = Number((out.match(/NATIVE: pull at (\d+)/) || [])[1]);
const after = requests.filter((t) => t > pull && t < pull + 5000).length;
console.log(pull ? `pull to refresh: ${after} Drive requests after the pull` : "pull to refresh: not run");
process.exit(code === 0 && (!pull || after > 0) ? 0 : 1);
