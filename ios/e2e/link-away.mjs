// A linked friend who goes away, between the iOS app (simulator) and the web
// build (headless Chromium), over the local signaling server and WebRTC. The
// app goes to the background for real (Settings comes forward); the browser
// holds its rAF, as a background tab does, and says so. Both run muted.
//
//   (build as in ios/e2e/link.mjs: core, WebRTC lib, xcodegen, xcodebuild, web wasm)
//   node ios/e2e/link-away.mjs <path to Dingbat.app> [simulator udid]
//
// Cases:
//   - the browser away past the 20 s idle window: the app shows the card
//     and keeps the session;
//   - nobody away, the cable gone quiet: the idle window still ends it;
//   - the app in the background 25 s (past the window; no ticks run there):
//     the browser shows the card, both play on, the app hears it waited;
//   - the browser disconnects while the app is in the background: the app
//     hears it on return;
//   - the browser closes its page: the app plays on, no card;
//   - a stall with no away message: the app's badge;
//   - the app suspended (its process frozen from 30 s in, as iOS does once
//     the background time runs out) and thawed at 42 s: the link recovers;
//     thawed at 90 s: the browser ends it at its "failed" (~46 s), and the
//     app says so on return, never "your friend waited".
// The card's Disconnect, tapped for real, is ios/e2e/link-away-ui.mjs.
// Each case reads the app's log (netlink: …) and the page's state.
//
// The test ROMs settle their link roles at boot, unlinked, and stay quiet,
// so both sides count nine serial transfers per linked frame below frame
// `busy` (the app: -link-busy-cable, a Debug-build argument), as a GBA link
// game clocks its cable, and none after.

import { spawn, execFileSync } from "node:child_process";
import { readFileSync, copyFileSync, mkdirSync, existsSync, rmSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import assert from "node:assert/strict";
import { serveWeb, builtWeb, WEB, sleep } from "../../web/e2e/devices.mjs";

const APP = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV || "20B3E400-B140-4C0D-A981-A87BDBEDAEF9";
const BUNDLE = "com.mattrb.dingbat";
const MUTED = ["-audio.muted", "YES"];
const ROOT = new URL("../..", import.meta.url).pathname;
const SHOTS = process.env.SHOTS || "/tmp";
const LINKTEST = join(ROOT, "tests/roms/linktest.gba");
if (!APP) { console.error("usage: node ios/e2e/link-away.mjs <Dingbat.app> [udid]"); process.exit(2); }
if (!builtWeb()) { console.error("web/em.wasm not built"); process.exit(2); }
const playwright = createRequire(join(WEB, "package.json"))("playwright");

const simctl = (...a) => execFileSync("xcrun", ["simctl", ...a], { encoding: "utf8" });
const trySimctl = (...a) => { try { return simctl(...a); } catch { return ""; } };

const PORT = 18790 + Math.floor(Math.random() * 1000);
const signal = spawn(process.execPath, [join(WEB, "signaling/server.js"), String(PORT)],
                     { stdio: ["ignore", "ignore", "inherit"] });
await sleep(500);
const web = await serveWeb();
const browser = await playwright.chromium.launch({ headless: true, args: ["--mute-audio"] });

const until = async (cond, what, ms) => {
  const end = Date.now() + ms;
  for (;;) {
    if (await cond()) return;
    if (Date.now() > end) assert.fail("timed out waiting for " + (typeof what === "function" ? await what() : what));
    await sleep(200);
  }
};

// One session: the page and the app on the same game, linked on a fresh code.
const BUSY = 1e9;
const link = async (name, rom, busy = BUSY) => {
  const code = "A" + Math.random().toString(36).slice(2, 8).toUpperCase();
  const log = join(SHOTS, `link-away-${name}.log`);
  const ctx = await browser.newContext({ serviceWorkers: "block", viewport: { width: 1000, height: 800 } });
  const page = await ctx.newPage();
  await page.goto(web.url + "?signal=ws://127.0.0.1:" + PORT);
  await page.waitForFunction(() => typeof Module !== "undefined" && !!Module._rollback_tick && runtimeReady,
    null, { timeout: 30000 });
  const [chooser] = await Promise.all([page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click()]);
  await chooser.setFiles({ name: rom.split("/").pop(), mimeType: "application/octet-stream", buffer: readFileSync(rom) });
  await page.waitForFunction(() => document.body.classList.contains("running") && !paused, null, { timeout: 20000 });
  await page.evaluate((busy) => {
    const tick = Module._rollback_tick;
    let n = 0;
    Module._rollback_tick = (b) => { const f = tick(b); if (f >= 0 && f < busy) n += 9; return f; };
    Module._rollback_transfers = () => n;
    window.__toasts = [];
    new MutationObserver((ms) => {
      for (const m of ms) for (const n of m.addedNodes) if (n.textContent) window.__toasts.push(n.textContent);
    }).observe(document.getElementById("toast"), { childList: true });
  }, busy);

  trySimctl("boot", UDID);
  simctl("bootstatus", UDID);
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("uninstall", UDID, BUNDLE);
  simctl("install", UDID, APP);
  const data = simctl("get_app_container", UDID, BUNDLE, "data").trim();
  mkdirSync(join(data, "Documents/roms"), { recursive: true });
  copyFileSync(rom, join(data, "Documents/roms", rom.split("/").pop()));
  simctl("spawn", UDID, "defaults", "write", BUNDLE, "audio.muted", "-bool", "true");
  if (existsSync(log)) rmSync(log);
  simctl("launch", "--stderr=" + log, UDID, BUNDLE, ...MUTED,
         "-autoplay", rom.split("/").pop(), "-signal", "ws://127.0.0.1:" + PORT, "-link", code,
         "-link-busy-cable", String(busy));
  await sleep(1500);
  await page.click("#menu-btn");
  await page.click("#net-connect");
  await page.fill("#net-code-input", code);
  await page.click("#net-join-go");
  await page.waitForFunction(() => rollbackMode && !!net?.started, null, { timeout: 60000 });
  const s = {
    page, ctx, log,
    appLog: () => (existsSync(log) ? readFileSync(log, "utf8") : ""),
    netlink: () => s.appLog().split("\n").filter((l) => l.includes("netlink: ")).map((l) => l.replace(/^.*netlink: /, "")),
    toastsApp: () => s.appLog().split("\n").filter((l) => l.includes("] toast: ")).map((l) => l.replace(/^.*\] toast: /, "")),
    linked: () => page.evaluate(() => !!net?.started && rollbackMode),
    webLog: () => page.evaluate(() => [...document.querySelectorAll("#log-entries p")]
      .map((e) => e.textContent).filter((t) => t.includes("netplay"))),
    toasts: () => page.evaluate(() => window.__toasts),
    card: () => page.evaluate(() => !document.getElementById("net-away").hidden),
    shot: (n) => trySimctl("io", UDID, "screenshot", join(SHOTS, `link-away-${name}-${n}.png`)),
    // The browser to the background and back: rAF held, and (announce)
    // visibilitychange.
    hide: (h, announce = true) => page.evaluate(([h, ann]) => {
      if (h) {
        window.__raf = window.requestAnimationFrame;
        window.__rafHeld = [];
        window.requestAnimationFrame = (cb) => { window.__rafHeld.push(cb); return 0; };
      } else {
        window.requestAnimationFrame = window.__raf;
        for (const cb of window.__rafHeld) window.__raf(cb);
      }
      if (!ann) return;
      Object.defineProperty(document, "hidden", { configurable: true, get: () => h });
      Object.defineProperty(document, "visibilityState", { configurable: true, get: () => (h ? "hidden" : "visible") });
      document.dispatchEvent(new Event("visibilitychange"));
    }, [h, announce]),
    // The app to the background (Settings forward) and back.
    appAway: () => simctl("launch", UDID, "com.apple.Preferences"),
    appBack: () => simctl("launch", UDID, BUNDLE),
    end: async () => { trySimctl("terminate", UDID, BUNDLE); await ctx.close(); },
  };
  return s;
};

const suspended = async (name, thaw) => {
  const s = await link(name, LINKTEST);
  await until(() => s.page.evaluate(() => rbLinkWasActive), "the cable in real use", 10000);
  const t0 = Date.now();
  const at = () => (Date.now() - t0) / 1000;
  s.appAway();
  const pid = execFileSync("pgrep", ["-f", "Dingbat.app/Dingbat"], { encoding: "utf8" }).trim().split("\n")[0];
  let frozen = false;
  s.endedAt = null;
  while (at() < thaw) {
    await sleep(500);
    if (!frozen && at() >= 30) { execFileSync("kill", ["-STOP", pid]); frozen = true; }
    if (s.endedAt === null && !(await s.linked())) s.endedAt = at();
  }
  execFileSync("kill", ["-CONT", pid]);
  s.appBack();
  await sleep(5000);
  s.shot("back");
  s.web = await s.webLog();
  console.log("  app: " + s.netlink().join(" / "));
  console.log("  app toasts: " + s.toastsApp().join(" / "));
  return s;
};

const cases = {
  async "browser away past the app's idle window"() {
    const s = await link("idle-guard", LINKTEST);
    await until(() => s.page.evaluate(() => rbLinkWasActive), "the cable in real use", 10000);
    await s.hide(true);
    await until(() => s.netlink().includes("friend switched away"), () => "app told: " + s.netlink(), 5000);
    await sleep(27000); // past the 20 s window
    s.shot("after-27s");
    assert.ok(!s.netlink().some((l) => l.includes("idle")), "the app didn't idle out: " + s.netlink());
    await s.hide(false);
    await until(() => s.netlink().some((l) => l.startsWith("friend back after 0:2")), () => "app: " + s.netlink(), 5000);
    await sleep(2000);
    assert.ok(await s.linked(), "still linked: " + s.netlink());
    await s.end();
  },
  async "nobody away, cable quiet: the idle window still ends it"() {
    const s = await link("idle-fires", LINKTEST, 600);
    await until(() => s.page.evaluate(() => Module._rollback_head() >= 600), "the cable gone quiet", 30000);
    const t0 = Date.now();
    await until(async () => !(await s.linked()), "the session's idle end", 40000);
    const secs = (Date.now() - t0) / 1000;
    console.log(`  ended ${secs.toFixed(0)} s after the cable went quiet; app: ${s.netlink().join(" / ")}`);
    assert.ok(secs > 17, "not before the 20 s window");
    const why = s.netlink().some((l) => l.includes("link idle")) ||
                (await s.toasts()).includes("Link idle — disconnected");
    assert.ok(why, "an idle end, on one side or the other");
    await s.end();
  },
  async "app in the background 25 s"() {
    const s = await link("app-away", LINKTEST);
    await until(() => s.page.evaluate(() => rbLinkWasActive), "the cable in real use", 10000);
    s.appAway();
    await until(() => s.card(), "the browser's away card", 8000);
    for (let i = 0; i < 25; i++) {
      await sleep(1000);
      if (!(await s.linked())) break;
    }
    assert.ok(await s.linked(), "still linked while away; browser: " + (await s.webLog()).join(" | ") +
              " toasts: " + (await s.toasts()).join(" | "));
    s.appBack();
    await until(async () => !(await s.card()), "the browser's card gone", 8000);
    await sleep(1500);
    s.shot("back");
    assert.ok(await s.linked(), "still linked after: " + s.netlink() + "; browser: " +
              (await s.webLog()).join(" | ") + " toasts: " + (await s.toasts()).join(" | "));
    assert.ok(!s.netlink().some((l) => l.includes("idle")), "the app didn't count its time away: " + s.netlink());
    assert.ok(!(await s.page.evaluate(() => paused)), "the app's relayed pause resumed too");
    assert.ok((await s.toasts()).includes("Friend's back — link resumed"), "browser toasts: " + (await s.toasts()));
    await s.end();
  },
  async "browser disconnects while the app is in the background"() {
    const s = await link("gone-while-away", LINKTEST);
    s.appAway();
    await until(() => s.card(), "the browser's away card", 8000);
    await s.page.click("#net-away-disconnect");
    await s.page.click("#net-away-disconnect");
    await until(async () => !(await s.linked()), "the browser's session ended", 5000);
    await until(() => s.netlink().some((l) => l.startsWith("Peer")), () => "app: " + s.netlink(), 15000);
    await sleep(2000);
    s.appBack();
    await sleep(1500);
    s.shot("back");
    console.log("  app: " + s.netlink().join(" / "));
    await s.end();
  },
  async "browser closes its page"() {
    const s = await link("page-closed", LINKTEST);
    await s.page.close({ runBeforeUnload: true });
    await until(() => s.netlink().some((l) => l.startsWith("Peer")), () => "app: " + s.netlink(), 15000);
    await sleep(800);
    s.shot("after");
    console.log("  app: " + s.netlink().join(" / "));
    await s.end();
  },
  // iOS suspends an app (freezes its process) once its background time runs
  // out, about 30 s on a device; the simulator doesn't, so the case freezes
  // the app's process itself, from 30 s in until `thaw`.
  async "app suspended briefly: the link recovers"() {
    const s = await suspended("suspend-brief", 42);
    assert.ok(s.endedAt === null, "the browser kept the session");
    assert.ok(s.web.some((l) => l.includes("connection disconnected while the friend is away")), s.web.join(" | "));
    assert.ok(s.web.some((l) => l.includes("connection back while the friend is away")), s.web.join(" | "));
    assert.ok(await s.linked(), "still linked after the return");
    assert.ok(!(await s.card()), "card gone");
    assert.ok(s.toastsApp().some((t) => t.startsWith("Your game was paused for 0:4")), "app: " + s.toastsApp());
    await s.end();
  },
  async "app suspended past the browser's patience"() {
    const s = await suspended("suspend-long", 90);
    console.log(`  browser ended it at ${s.endedAt?.toFixed(0)} s`);
    assert.ok(s.endedAt > 40 && s.endedAt < 55, "after its 'failed', not its 'disconnected'");
    assert.ok((await s.toasts()).includes("Peer connection lost — your game keeps running"));
    assert.ok(!s.toastsApp().some((t) => t.includes("your friend waited")), "app: " + s.toastsApp());
    assert.ok(s.toastsApp().some((t) => t.startsWith("Peer")), "the app says the link ended: " + s.toastsApp());
    await s.end();
  },
  async "stall with no away message"() {
    const s = await link("no-message", LINKTEST);
    await s.hide(true, false);
    await sleep(4500);
    s.shot("badge");
    assert.ok(!s.netlink().includes("friend switched away"));
    await s.hide(false, false);
    await sleep(1500);
    assert.ok(await s.linked());
    await s.end();
  },
};

let failed = 0;
const only = process.env.CASES ? process.env.CASES.split(",") : null;
try {
  for (const [name, run] of Object.entries(cases)) {
    if (only && !only.some((o) => name.includes(o))) continue;
    console.log(`\n${name}`);
    try { await run(); console.log("  ok"); }
    catch (e) { failed++; console.log("  FAILED: " + e.message); }
  }
} finally {
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("shutdown", UDID);
  await browser.close();
  signal.kill();
  web.close();
}
process.exit(failed ? 1 : 0);
