// A dropped link resumes: the iOS app (simulator) and the web build
// (headless Chromium) link over the local signaling server and WebRTC, both
// pressing scripted buttons on a game that counts frames with A held (so an
// input lost or doubled in the resend changes the game). The app goes to the
// background; 30 s in, as iOS does once the background time runs out, its
// process is frozen (the simulator never suspends on its own), and it stays
// frozen for 2 minutes (FREEZE_SECS). The browser's connection fails, so it
// shows "Reconnecting…" and waits on the retry code. The app is thawed and
// brought back; it finds its connection dead, redials the same code, and
// both swap RESUME and play on to a stop frame, where every core on both
// sides must be byte-identical. Both run muted.
//
//   (build as in ios/e2e/link.mjs: core, WebRTC lib, xcodegen, xcodebuild, web wasm)
//   node ios/e2e/link-resume.mjs <path to Dingbat.app> [simulator udid]

import { spawn, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, copyFileSync, mkdirSync, existsSync, rmSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import assert from "node:assert/strict";
import { serveWeb, builtWeb, WEB, sleep } from "../../web/e2e/devices.mjs";
import { synctestRom, SYNCTEST_NAME as GAME } from "../../web/e2e/synctest-rom.mjs";

const APP = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV || "20B3E400-B140-4C0D-A981-A87BDBEDAEF9";
const BUNDLE = "com.mattrb.dingbat";
const SHOTS = process.env.SHOTS || "/tmp";
const FREEZE_SECS = Number(process.env.FREEZE_SECS || 120);
const STOP = 1500; // frames: a few seconds before the drop, the rest after
if (!APP) { console.error("usage: node ios/e2e/link-resume.mjs <Dingbat.app> [udid]"); process.exit(2); }
if (!builtWeb()) { console.error("web/em.wasm not built"); process.exit(2); }
const playwright = createRequire(join(WEB, "package.json"))("playwright");
const simctl = (...a) => execFileSync("xcrun", ["simctl", ...a], { encoding: "utf8" });
const trySimctl = (...a) => { try { return simctl(...a); } catch { return ""; } };
const until = async (cond, what, ms) => {
  const end = Date.now() + ms;
  for (;;) {
    if (await cond()) return;
    if (Date.now() > end) assert.fail("timed out waiting for " + (typeof what === "function" ? await what() : what));
    await sleep(250);
  }
};
const fnv = (bytes) => {
  let h = 0x811c9dc5 >>> 0;
  for (const b of bytes) h = Math.imul(h ^ b, 0x01000193) >>> 0;
  return h.toString(16);
};

const PORT = 18790 + Math.floor(Math.random() * 1000);
const signal = spawn(process.execPath, [join(WEB, "signaling/server.js"), String(PORT)], { stdio: "ignore" });
await sleep(500);
const web = await serveWeb();
const browser = await playwright.chromium.launch({ headless: true, args: ["--mute-audio"] });
const romFile = join(SHOTS, GAME);
writeFileSync(romFile, Buffer.from(synctestRom()));
const log = join(SHOTS, "link-resume.log");
let ok = false;
try {
  const code = "R" + Math.random().toString(36).slice(2, 8).toUpperCase();
  const page = await (await browser.newContext({ serviceWorkers: "block" })).newPage();
  await page.goto(web.url + "?signal=ws://127.0.0.1:" + PORT);
  await page.waitForFunction(() => typeof Module !== "undefined" && !!Module._rollback_tick && runtimeReady, null, { timeout: 30000 });
  const [chooser] = await Promise.all([page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click()]);
  await chooser.setFiles({ name: GAME, mimeType: "application/octet-stream", buffer: readFileSync(romFile) });
  await page.waitForFunction(() => document.body.classList.contains("running") && !paused, null, { timeout: 20000 });
  // Scripted buttons by frame and a stop, inside the tick so what is
  // simulated is what netplay.js sends.
  await page.evaluate((stop) => {
    const tick = Module._rollback_tick;
    Module._rollback_tick = () => {
      const h = Module._rollback_head();
      if (h >= stop) return -1;
      localButtons = ((h / 29) | 0) % 2 ? 1 << 4 : ((h / 41) | 0) % 2 ? 1 << 7 : 0;
      return tick(localButtons);
    };
  }, STOP);

  // The app, freshly installed and muted, with the game, dialing the code.
  trySimctl("boot", UDID);
  simctl("bootstatus", UDID);
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("uninstall", UDID, BUNDLE);
  simctl("install", UDID, APP);
  const data = simctl("get_app_container", UDID, BUNDLE, "data").trim();
  mkdirSync(join(data, "Documents/roms"), { recursive: true });
  copyFileSync(romFile, join(data, "Documents/roms", GAME));
  simctl("spawn", UDID, "defaults", "write", BUNDLE, "audio.muted", "-bool", "true");
  if (existsSync(log)) rmSync(log);
  simctl("launch", "--stderr=" + log, UDID, BUNDLE, "-audio.muted", "YES", "-autoplay", GAME,
         "-signal", "ws://127.0.0.1:" + PORT, "-link", code, "-link-stop-at", String(STOP), "-link-press");
  const appLog = () => (existsSync(log) ? readFileSync(log, "utf8") : "");
  const netlink = () => appLog().split("\n").filter((l) => l.includes("netlink: ")).map((l) => l.replace(/^.*netlink: /, ""));
  const webLog = () => page.evaluate(() => [...document.querySelectorAll("#log-entries p")]
    .map((e) => e.textContent).filter((t) => t.includes("netplay")).map((t) => t.replace(/^\[[^\]]*\] netplay: /, "")));
  const title = () => page.evaluate(() =>
    document.getElementById("net-away").hidden ? "" : document.getElementById("net-away-title").textContent);
  await sleep(1500);
  await page.click("#menu-btn");
  await page.click("#net-connect");
  await page.fill("#net-code-input", code);
  await page.click("#net-join-go");
  await page.waitForFunction(() => rollbackMode && net?.rb?.resumeOk, null, { timeout: 60000 });
  await until(() => page.evaluate(() => Module._rollback_head() > 200), "some play first", 30000);
  const before = await page.evaluate(() => Module._rollback_head());
  console.log(`linked; frame ${before} when the app goes away`);

  // The app to the background; 30 s in its process freezes, for FREEZE_SECS.
  const t0 = Date.now();
  const at = () => ((Date.now() - t0) / 1000).toFixed(0) + " s";
  simctl("launch", UDID, "com.apple.Preferences");
  const pid = execFileSync("pgrep", ["-f", "Dingbat.app/Dingbat"], { encoding: "utf8" }).trim().split("\n")[0];
  await sleep(30000);
  execFileSync("kill", ["-STOP", pid]);
  console.log(`app frozen at ${at()}`);
  await until(async () => (await title()) === "Reconnecting…", "the browser's reconnecting card", 30000);
  console.log(`browser reconnecting at ${at()}: ${(await webLog()).slice(-2).join(" | ")}`);
  await page.screenshot({ path: join(SHOTS, "link-resume-web-reconnecting.png") });
  await sleep(FREEZE_SECS * 1000 - (Date.now() - t0 - 30000));
  assert.ok(await page.evaluate(() => rollbackMode && !!net?.started), "the browser kept the session through the freeze");
  console.log(`thawed at ${at()}`);
  execFileSync("kill", ["-CONT", pid]);
  simctl("launch", UDID, BUNDLE);

  await until(async () => (await webLog()).some((t) => t.startsWith("resumed after")) &&
                          netlink().some((l) => l.startsWith("resumed after")),
    async () => "both resumed; browser: " + (await webLog()).slice(-5).join(" | ") + " // app: " + netlink().slice(-5).join(" | "),
    90000);
  console.log(`resumed at ${at()}`);
  console.log("  browser: " + (await webLog()).filter((t) => /redial|resumed|dropped|failed|closed/.test(t)).join(" | "));
  console.log("  app: " + netlink().join(" | "));
  await sleep(1500);
  trySimctl("io", UDID, "screenshot", join(SHOTS, "link-resume-app-resumed.png"));

  // Both play on to the stop with every input in; every core must match.
  await page.waitForFunction((stop) => Module._rollback_head() >= stop && Module._rollback_confirmed() === stop - 1,
    STOP, { timeout: 90000 });
  let appLine = "";
  for (let i = 0; i < 150 && !appLine; i++) {
    await sleep(200);
    const f = join(data, "tmp/linkdump.txt");
    const st = existsSync(f) ? readFileSync(f, "utf8").trim() : "";
    if (st.startsWith("LINKDUMP")) appLine = st;
  }
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
  console.log("  app " + (appLine || "(no dump)"));
  console.log("  web " + webLine);
  assert.equal(appLine, webLine, "both players' cores identical on both sides after the resume");
  ok = true;
} catch (e) {
  console.log("FAILED: " + e.message);
} finally {
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("shutdown", UDID);
  await browser.close();
  signal.kill();
  web.close();
}
console.log(ok ? "resume ok" : "resume FAILED");
process.exit(ok ? 0 : 1);
