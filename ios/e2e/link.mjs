// Online link between the iOS app and the web build: the app in a headless
// iOS simulator and the real web build in headless Chromium pair through a
// local signaling server (web/signaling/server.js) and link over a WebRTC
// data channel, as an iPhone and a browser do over the internet. Both play
// scripted buttons (so each mispredicts the other and rolls back), stop at
// the same frame, and must then hold byte-identical states for both
// players' cores: the native core and the wasm core running in lockstep.
// Nothing leaves the machine but a STUN query; both run muted. The app
// writes its hashes to tmp/linkdump.txt in its container.
//
//   ios/build-core.sh sim && ios/build-webrtc.sh sim && (cd ios && xcodegen generate)
//   xcodebuild ... -sdk iphonesimulator -derivedDataPath <dd> build   # Debug
//   nim c -d:emscripten src/dingbat_wasm.nim       # web/em.wasm
//   node ios/e2e/link.mjs <path to Dingbat.app> [simulator udid]
//
// Cases: the same GBA game on both sides (no transfer); the same GB game;
// two different GBA games (each side sends the other its ROM first), and
// the same with the friend's game already in one side's library (it says
// so, and that ROM never crosses); and the manual code exchange with no
// server at all (each side pastes the other's code; the app's goes through
// tmp/linkcode.txt and tmp/friendcode.txt).

import { spawn, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, copyFileSync, mkdirSync, existsSync, rmSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import assert from "node:assert/strict";
import { serveWeb, builtWeb, WEB, sleep } from "../../web/e2e/devices.mjs";

const APP = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV || "20B3E400-B140-4C0D-A981-A87BDBEDAEF9";
const BUNDLE = "com.mattrb.dingbat";
// Muted through the launch arguments, which the app's defaults always read
// (a `defaults write` from outside can land beside its container).
const MUTED = ["-audio.muted", "YES"];
const ROOT = new URL("../..", import.meta.url).pathname;
const SHOTS = process.env.SHOTS || "/tmp";
if (!APP) { console.error("usage: node ios/e2e/link.mjs <Dingbat.app> [udid]"); process.exit(2); }
if (!builtWeb()) { console.error("web/em.wasm not built"); process.exit(2); }
const playwright = createRequire(join(WEB, "package.json"))("playwright");

const simctl = (...a) => execFileSync("xcrun", ["simctl", ...a], { encoding: "utf8" });
const trySimctl = (...a) => { try { return simctl(...a); } catch { return ""; } };

const fnv = (bytes) => {
  let h = 0x811c9dc5 >>> 0;
  for (const b of bytes) h = Math.imul(h ^ b, 0x01000193) >>> 0;
  return h.toString(16);
};

const PORT = 18790 + Math.floor(Math.random() * 1000);
const signal = spawn(process.execPath, [join(WEB, "signaling/server.js"), String(PORT)],
                     { stdio: ["ignore", "ignore", "inherit"] });
await sleep(500);

const web = await serveWeb();
const browser = await playwright.chromium.launch({ headless: true, args: ["--mute-audio"] });

// The app, freshly installed and muted, with `rom` in its library.
const launchApp = (rom, args, log, extra = []) => {
  trySimctl("boot", UDID);
  simctl("bootstatus", UDID);
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("uninstall", UDID, BUNDLE);
  simctl("install", UDID, APP);
  const data = simctl("get_app_container", UDID, BUNDLE, "data").trim();
  mkdirSync(join(data, "Documents/roms"), { recursive: true });
  for (const r of [...extra, rom]) copyFileSync(r, join(data, "Documents/roms", r.split("/").pop()));
  simctl("spawn", UDID, "defaults", "write", BUNDLE, "audio.muted", "-bool", "true");
  if (existsSync(log)) rmSync(log);
  simctl("launch", "--stderr=" + log, UDID, BUNDLE, ...MUTED, ...args);
};

const STOP = 600;

const runCase = async (name, { webRom, appRom, appGame, manual = false, webHas = [], appHas = [], expect }) => {
  console.log(`\n${name}`);
  const code = "T" + Math.random().toString(36).slice(2, 8).toUpperCase();
  const log = join(SHOTS, `link-${name.replace(/\W+/g, "-")}.log`);
  const ctx = await browser.newContext({ serviceWorkers: "block", viewport: { width: 1000, height: 800 } });
  const page = await ctx.newPage();
  page.on("console", (m) => { if (/netplay/.test(m.text())) console.log("  web:", m.text()); });
  // The manual case points both at a server that is not there.
  const sig = "ws://127.0.0.1:" + (manual ? 9 : PORT);
  await page.goto(web.url + "?signal=" + sig);
  await page.waitForFunction(() => typeof Module !== "undefined" && !!Module._rollback_tick, null, { timeout: 30000 });
  // Games already in the browser's library: each added, then Main Menu.
  for (const r of webHas) {
    const [c] = await Promise.all([page.waitForEvent("filechooser"),
      page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click()]);
    await c.setFiles({ name: r.split("/").pop(), mimeType: "application/octet-stream", buffer: readFileSync(r) });
    await page.waitForFunction(() => document.body.classList.contains("running") && !paused, null, { timeout: 20000 });
    await page.evaluate(() => document.getElementById("main-menu").click());
    await page.waitForFunction(() => !document.body.classList.contains("running"), null, { timeout: 10000 });
  }
  const [chooser2] = await Promise.all([
    page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click(),
  ]);
  await chooser2.setFiles({ name: webRom.split("/").pop(), mimeType: "application/octet-stream",
                           buffer: readFileSync(webRom) });
  await page.waitForFunction(() => document.body.classList.contains("running") && !paused, null, { timeout: 20000 });
  // Scripted buttons by frame, and a stop at STOP: set inside the tick so
  // what is simulated is what netplay.js sends.
  await page.evaluate((stop) => {
    const tick = Module._rollback_tick;
    Module._rollback_tick = () => {
      const h = Module._rollback_head();
      if (h >= stop) return -1;
      localButtons = ((h / 29) | 0) % 2 ? 1 << 4 : ((h / 41) | 0) % 2 ? 1 << 7 : 0;
      return tick(localButtons);
    };
  }, STOP);

  launchApp(appRom, ["-autoplay", appGame, "-signal", sig,
                     ...(manual ? ["-link-manual"] : ["-link", code]),
                     "-link-stop-at", String(STOP), "-link-press"], log, appHas);
  await sleep(1500);
  await page.click("#menu-btn");
  await page.click("#net-connect");
  if (manual) {
    // The page's own probe found no server: it may already be there.
    await sleep(300);
    if (await page.isVisible("#net-to-manual")) await page.click("#net-to-manual");
    const webCode = await page.waitForFunction(() => net?.manualCode, null, { timeout: 20000 })
      .then((h) => h.jsonValue());
    const tmp = join(simctl("get_app_container", UDID, BUNDLE, "data").trim(), "tmp");
    let appCode = "";
    for (let i = 0; i < 100 && !appCode; i++) {
      await sleep(200);
      if (existsSync(join(tmp, "linkcode.txt"))) appCode = readFileSync(join(tmp, "linkcode.txt"), "utf8").trim();
    }
    assert.ok(appCode, "the app minted a code");
    console.log(`  codes: app ${appCode.length} chars, web ${webCode.length} chars`);
    writeFileSync(join(tmp, "friendcode.txt"), webCode);
    await page.fill("#net-manual-in", appCode);
    await page.click("#net-manual-confirm");
  } else {
    await page.fill("#net-code-input", code);
    await page.click("#net-join-go");
  }

  // Linked on both sides, then both at the stop with every input in.
  await page.waitForFunction(() => rollbackMode, null, { timeout: 60000 });
  console.log("  web linked");
  await page.waitForFunction((stop) => Module._rollback_head() >= stop &&
    Module._rollback_confirmed() === stop - 1, STOP, { timeout: 60000 });
  let appLine = "", appState = "";
  for (let i = 0; i < 100 && !appLine; i++) {
    await sleep(200);
    const f = join(simctl("get_app_container", UDID, BUNDLE, "data").trim(), "tmp/linkdump.txt");
    appState = existsSync(f) ? readFileSync(f, "utf8").trim() : "";
    appLine = appState.startsWith("LINKDUMP") ? appState : "";
  }
  trySimctl("io", UDID, "screenshot", join(SHOTS, `link-${name.replace(/\W+/g, "-")}.png`));
  const xfer = await page.evaluate(() => ({ fromLibrary: net.rb.romFromLibrary, friendHas: net.rb.friendHasRom,
                                            got: net.rb.romGot }));
  const webDump = await page.evaluate(() => {
    const out = { head: Module._rollback_head(), confirmed: Module._rollback_confirmed(), p: [] };
    for (let p = 0; p < 2; p++) {
      const n = Module._rollback_dump_size(p);
      out.p.push(Array.from(new Uint8Array(Module.memory.buffer, Module._rollback_dump_data(), n)));
    }
    return out;
  });
  const webLine = `LINKDUMP head=${webDump.head} confirmed=${webDump.confirmed} ` +
    webDump.p.map((b, i) => `p${i}=${b.length}:${fnv(b)}`).join(" ");
  console.log("  app " + (appLine || "(no dump: " + appState + ")"));
  console.log("  web " + webLine);
  // The web peer's own end: Disconnect, two taps; the app keeps its game.
  await page.click("#rb-disconnect");
  await page.click("#rb-disconnect");
  await sleep(1500);
  const after = join(SHOTS, `link-${name.replace(/\W+/g, "-")}-after.png`);
  trySimctl("io", UDID, "screenshot", after);
  const alive = trySimctl("spawn", UDID, "launchctl", "list").includes(BUNDLE);
  const appLog = readFileSync(log, "utf8");
  trySimctl("terminate", UDID, BUNDLE);
  await ctx.close();
  assert.ok(appLine, "the app reached the stop frame with every input in");
  assert.equal(appLine, webLine, "both players' cores identical on both sides");
  if (expect) {
    const x = xfer;
    console.log("  web transfer " + JSON.stringify(x));
    assert.deepEqual({ fromLibrary: x.fromLibrary, friendHas: x.friendHas }, expect, "who already had which game");
    if (x.fromLibrary) assert.equal(x.got, 0, "the browser was sent nothing it had");
  }
  assert.ok(alive, "the app plays on after the browser disconnects (" + after + ")");
  assert.ok(!/netlink: /.test(appLog) || !/failed|lost/i.test(appLog), "no link failure logged");
  console.log("  ok");
};

let failed = 0;
const cases = [
  ["same GBA game", { webRom: join(ROOT, "tests/roms/linktest.gba"), appRom: join(ROOT, "tests/roms/linktest.gba"),
                      appGame: "linktest.gba" }],
  ["same GB game", { webRom: join(ROOT, "tests/roms/gblinktest.gb"), appRom: join(ROOT, "tests/roms/gblinktest.gb"),
                     appGame: "gblinktest.gb" }],
  ["two GBA games, sent both ways", { webRom: join(ROOT, "tests/roms/linktest.gba"),
                                      appRom: join(ROOT, "tests/roms/gbaedge.gba"), appGame: "gbaedge.gba" }],
  ["two GBA games, the app already has the browser's", { webRom: join(ROOT, "tests/roms/linktest.gba"),
                                      appRom: join(ROOT, "tests/roms/gbaedge.gba"), appGame: "gbaedge.gba",
                                      appHas: [join(ROOT, "tests/roms/linktest.gba")],
                                      expect: { fromLibrary: false, friendHas: true } }],
  ["two GBA games, the browser already has the app's", { webRom: join(ROOT, "tests/roms/linktest.gba"),
                                      appRom: join(ROOT, "tests/roms/gbaedge.gba"), appGame: "gbaedge.gba",
                                      webHas: [join(ROOT, "tests/roms/gbaedge.gba")],
                                      expect: { fromLibrary: true, friendHas: false } }],
  ["manual codes, no server", { webRom: join(ROOT, "tests/roms/linktest.gba"), appRom: join(ROOT, "tests/roms/linktest.gba"),
                                appGame: "linktest.gba", manual: true }],
];
const only = process.env.ONLY;
for (const [name, c] of cases) {
  if (only && !name.includes(only)) continue;
  try { await runCase(name, c); } catch (e) { failed++; console.log("  FAIL " + e.message); }
}
await browser.close();
web.close();
signal.kill();
trySimctl("terminate", UDID, BUNDLE);
trySimctl("shutdown", UDID);
console.log(failed ? `\n${failed} case(s) failed` : "\nall passed");
process.exit(failed ? 1 : 0);
