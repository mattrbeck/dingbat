// The away card's Disconnect, tapped for real: an XCUITest
// (ios/e2e/uitest/LinkAwayUITests.swift) drives the app in the simulator
// while this script drives the web build in headless Chromium as the friend,
// over the local signaling server and WebRTC. The browser links, goes away
// (rAF held, visibilitychange); the test finds the card, checks one tap only
// arms Disconnect and that it disarms after 3.5 s, then disconnects; here
// the browser's session must end, and on its return it must hear the link
// ended while it was away. Both run muted.
//
//   ios/build-core.sh sim && ios/build-webrtc.sh sim
//   xcodegen generate --spec ios/e2e/uitest/project.yml --project ios --project-root ios
//   xcodebuild -project ios/DingbatUITest.xcodeproj -scheme DingbatUITest \
//     -sdk iphonesimulator -destination id=<udid> -derivedDataPath <dd> build-for-testing
//   nim c -d:emscripten src/dingbat_wasm.nim       # web/em.wasm
//   node ios/e2e/link-away-ui.mjs <dd> [simulator udid]
//
// The test's screenshots (card, armed, after) are in $SHOTS/link-away-ui.xcresult.

import { spawn, execFileSync } from "node:child_process";
import { readFileSync, copyFileSync, mkdirSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, WEB, sleep } from "../../web/e2e/devices.mjs";

const DD = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV || "20B3E400-B140-4C0D-A981-A87BDBEDAEF9";
const ROOT = new URL("../..", import.meta.url).pathname;
const SHOTS = process.env.SHOTS || "/tmp";
if (!DD) { console.error("usage: node ios/e2e/link-away-ui.mjs <derivedData> [udid]"); process.exit(2); }
if (!builtWeb()) { console.error("web/em.wasm not built"); process.exit(2); }
const playwright = createRequire(join(WEB, "package.json"))("playwright");
const BUNDLE = "com.mattrb.dingbat";
const ROM = join(ROOT, "tests/roms/linktest.gba");
const simctl = (...a) => execFileSync("xcrun", ["simctl", ...a], { encoding: "utf8" });
const trySimctl = (...a) => { try { return simctl(...a); } catch { return ""; } };
const until = async (cond, what, ms) => {
  const end = Date.now() + ms;
  while (!(await cond())) { if (Date.now() > end) throw new Error("timed out: " + what); await sleep(250); }
};

const PORT = 18790 + Math.floor(Math.random() * 1000);
const signal = spawn(process.execPath, [join(WEB, "signaling/server.js"), String(PORT)], { stdio: "ignore" });
await sleep(500);
const web = await serveWeb();
const browser = await playwright.chromium.launch({ headless: true, args: ["--mute-audio"] });
const code = "U" + Math.random().toString(36).slice(2, 8).toUpperCase();
let xc = null, ok = true;
try {
  // The app installed with the ROM in its library, muted.
  trySimctl("boot", UDID);
  simctl("bootstatus", UDID);
  trySimctl("uninstall", UDID, BUNDLE);
  simctl("install", UDID, join(DD, "Build/Products/Debug-iphonesimulator/Dingbat.app"));
  const data = simctl("get_app_container", UDID, BUNDLE, "data").trim();
  mkdirSync(join(data, "Documents/roms"), { recursive: true });
  copyFileSync(ROM, join(data, "Documents/roms/linktest.gba"));
  simctl("spawn", UDID, "defaults", "write", BUNDLE, "audio.muted", "-bool", "true");

  const page = await (await browser.newContext({ serviceWorkers: "block" })).newPage();
  await page.goto(web.url + "?signal=ws://127.0.0.1:" + PORT);
  await page.waitForFunction(() => typeof Module !== "undefined" && !!Module._rollback_tick && runtimeReady, null, { timeout: 30000 });
  const [chooser] = await Promise.all([page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click()]);
  await chooser.setFiles({ name: "linktest.gba", mimeType: "application/octet-stream", buffer: readFileSync(ROM) });
  await page.waitForFunction(() => document.body.classList.contains("running") && !paused, null, { timeout: 20000 });
  await page.evaluate(() => {
    const tick = Module._rollback_tick;
    let n = 0;
    Module._rollback_tick = (b) => { const f = tick(b); if (f >= 0) n += 9; return f; };
    Module._rollback_transfers = () => n;
    window.__toasts = [];
    new MutationObserver((ms) => { for (const m of ms) for (const nd of m.addedNodes) if (nd.textContent) window.__toasts.push(nd.textContent); })
      .observe(document.getElementById("toast"), { childList: true });
  });

  // The UI test launches the app, which dials the code.
  const result = join(SHOTS, "link-away-ui.xcresult");
  if (existsSync(result)) rmSync(result, { recursive: true });
  xc = new Promise((resolve) => {
    const p = spawn("xcodebuild", ["test-without-building", "-project", join(ROOT, "ios/DingbatUITest.xcodeproj"),
      "-scheme", "DingbatUITest", "-destination", "id=" + UDID, "-derivedDataPath", DD, "-resultBundlePath", result],
      { env: { ...process.env, TEST_RUNNER_DB_GAME: "linktest.gba", TEST_RUNNER_DB_SIGNAL: "ws://127.0.0.1:" + PORT,
               TEST_RUNNER_DB_CODE: code }, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    p.stdout.on("data", (d) => { out += d; });
    p.stderr.on("data", (d) => { out += d; });
    p.on("exit", (c) => resolve({ code: c, out }));
  });
  await page.click("#menu-btn");
  await page.click("#net-connect");
  await page.fill("#net-code-input", code);
  await page.click("#net-join-go");
  await page.waitForFunction(() => rollbackMode && !!net?.started, null, { timeout: 120000 });
  console.log("linked");
  await until(() => page.evaluate(() => rbLinkWasActive), "cable in use", 10000);

  // The browser goes away; the UI test finds the card and disconnects.
  await page.evaluate(() => {
    window.__raf = window.requestAnimationFrame; window.__rafHeld = [];
    window.requestAnimationFrame = (cb) => { window.__rafHeld.push(cb); return 0; };
    Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  const t0 = Date.now();
  await until(async () => !(await page.evaluate(() => !!net?.started)), "the app's disconnect to end the session", 90000);
  console.log(`browser session ended ${((Date.now() - t0) / 1000).toFixed(1)} s after going away`);
  await page.evaluate(() => {
    window.requestAnimationFrame = window.__raf;
    for (const cb of window.__rafHeld) window.__raf(cb);
    Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await sleep(1000);
  const toasts = await page.evaluate(() => window.__toasts);
  const log = await page.evaluate(() => [...document.querySelectorAll("#log-entries p")].map((e) => e.textContent).filter((t) => t.includes("netplay")));
  console.log("browser log: " + log.slice(-3).join(" | "));
  console.log("browser toasts: " + toasts.join(" | "));
  if (!toasts.some((t) => t.startsWith("Peer disconnected while you were away"))) { ok = false; console.log("MISSING the away toast"); }
  if (await page.evaluate(() => rollbackMode || paused)) { ok = false; console.log("browser not back to solo play"); }
  const r = await xc;
  const summary = r.out.split("\n").filter((l) => /Test Case|error:|TEST (SUCCEEDED|FAILED)|XCTAssert/.test(l));
  console.log(summary.join("\n"));
  if (r.code !== 0) ok = false;
} catch (e) {
  ok = false;
  console.log("ERROR " + e.message);
  if (xc) { const r = await xc; console.log(r.out.split("\n").filter((l) => /Test Case|error:|TEST/.test(l)).join("\n")); }
} finally {
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("shutdown", UDID);
  await browser.close();
  signal.kill();
  web.close();
}
console.log(ok ? "UITEST OK" : "UITEST FAILED");
process.exit(ok ? 0 : 1);
