// A dropped link resumes: the iOS app (simulator) and the web build
// (headless Chromium) link over the local signaling server and WebRTC, both
// pressing scripted buttons on a game that counts frames with A held (so an
// input lost or doubled in the resend changes the game), and each case ends
// with every core on both sides byte-identical at a stop frame. iOS
// suspends an app (freezes its process) once its background time runs out;
// the simulator never does, so the cases freeze the app's process
// themselves. Both run muted.
//
//   (build as in ios/e2e/link.mjs: core, WebRTC lib, xcodegen, xcodebuild, web wasm)
//   node ios/e2e/link-resume.mjs <path to Dingbat.app> [simulator udid]
//
// Cases (CASES=substring to pick):
//   - the app in the background, frozen 2 minutes from 30 s in (the app
//     hosts the session; the browser's connection fails first and it waits
//     on the retry code; the app redials on its return);
//   - the browser links first (the app is the guest, the echo side); the
//     browser's connection drops while its server is out of reach, so the
//     app is first on the retry code (the app offers); then the browser's
//     redialed channel dies just as it would say RESUME, and both dial
//     again;
//   - the app paused in the background, its pause lost, and the link
//     dropped while it is still there: both stay paused, and both run
//     when it comes back;
//   - the browser's Disconnect while both redial (its server out of reach):
//     its goodbye note reaches the app waiting on the retry code at once;
//   - the app's give-up (shortened) while the browser can't reach the
//     server: the browser's next rendezvous gets the app's "gave-up" note;
//   - the app frozen past the browser's give-up: the browser ends it, and
//     the app, back, ends at once instead of redialing a friend long gone.
//   - the app killed mid-session (SIGKILL: nothing runs, no BYE, no note):
//     the browser redials; the app's next launch leaves the goodbye it
//     couldn't, and the browser ends with "Peer disconnected".

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
const STOP = 1500; // frames: a few seconds before the drops, the rest after
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

// One session; `webFirst`: the browser is at the server first (it hosts).
const link = async (name, { webFirst = false, appArgs = [] } = {}) => {
  const code = "R" + Math.random().toString(36).slice(2, 8).toUpperCase();
  const log = join(SHOTS, `link-resume-${name}.log`);
  const ctx = await browser.newContext({ serviceWorkers: "block" });
  const page = await ctx.newPage();
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
    window.__toasts = [];
    new MutationObserver((ms) => {
      for (const m of ms) for (const n of m.addedNodes) if (n.textContent) window.__toasts.push(n.textContent);
    }).observe(document.getElementById("toast"), { childList: true });
  }, STOP);
  const webConnect = async () => {
    await page.click("#menu-btn");
    await page.click("#net-connect");
    await page.fill("#net-code-input", code);
    await page.click("#net-join-go");
  };
  if (webFirst) {
    await webConnect();
    await page.waitForFunction(() => net?.ws?.readyState === 1, null, { timeout: 10000 });
    await sleep(800);
  }
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
         "-signal", "ws://127.0.0.1:" + PORT, "-link", code, "-link-stop-at", String(STOP), "-link-press",
         ...appArgs);
  if (!webFirst) { await sleep(1500); await webConnect(); }
  await page.waitForFunction(() => rollbackMode && net?.rb?.resumeOk, null, { timeout: 60000 });
  const appLog = () => (existsSync(log) ? readFileSync(log, "utf8") : "");
  const s = {
    page, ctx, data,
    netlink: () => appLog().split("\n").filter((l) => l.includes("netlink: ")).map((l) => l.replace(/^.*netlink: /, "")),
    netlinkRaw: () => appLog().split("\n"),
    toastsApp: () => appLog().split("\n").filter((l) => l.includes("] toast: ")).map((l) => l.replace(/^.*\] toast: /, "")),
    webLog: () => page.evaluate(() => [...document.querySelectorAll("#log-entries p")]
      .map((e) => e.textContent).filter((t) => t.includes("netplay")).map((t) => t.replace(/^\[[^\]]*\] netplay: /, ""))),
    toasts: () => page.evaluate(() => window.__toasts),
    title: () => page.evaluate(() =>
      document.getElementById("net-away").hidden ? "" : document.getElementById("net-away-title").textContent),
    linked: () => page.evaluate(() => rollbackMode && !!net?.started),
    pid: () => execFileSync("pgrep", ["-f", "Dingbat.app/Dingbat"], { encoding: "utf8" }).trim().split("\n")[0],
    resumes: async () => [(await s.webLog()).filter((t) => t.startsWith("resumed after")).length,
                          s.netlink().filter((l) => l.startsWith("resumed after")).length],
    // Both at the stop with every input in; every core must match.
    sameGames: async () => {
      await page.waitForFunction((stop) => Module._rollback_head() >= stop && Module._rollback_confirmed() === stop - 1,
        STOP, { timeout: 120000 });
      let appLine = "";
      for (let i = 0; i < 150 && !appLine; i++) {
        await sleep(200);
        const f = join(data, "tmp/linkdump.txt");
        const st = existsSync(f) ? readFileSync(f, "utf8").trim() : "";
        if (st.startsWith("LINKDUMP")) appLine = st;
      }
      const d = await page.evaluate(() => {
        const out = { head: Module._rollback_head(), confirmed: Module._rollback_confirmed(), p: [] };
        for (let p = 0; p < 2; p++) {
          const n = Module._rollback_dump_size(p);
          out.p.push(Array.from(new Uint8Array(Module.memory.buffer, Module._rollback_dump_data(), n)));
        }
        return out;
      });
      const webLine = `LINKDUMP head=${d.head} confirmed=${d.confirmed} ` + d.p.map((b, i) => `p${i}=${b.length}:${fnv(b)}`).join(" ");
      console.log("  app " + (appLine || "(no dump)") + "\n  web " + webLine);
      assert.equal(appLine, webLine, "both players' cores identical on both sides");
    },
    end: async () => { trySimctl("terminate", UDID, BUNDLE); await ctx.close(); },
  };
  return s;
};

const cases = {
  async "the app frozen 2 minutes in the background"() {
    const s = await link("freeze");
    await until(() => s.page.evaluate(() => Module._rollback_head() > 200), "some play first", 30000);
    const t0 = Date.now();
    const at = () => ((Date.now() - t0) / 1000).toFixed(0) + " s";
    simctl("launch", UDID, "com.apple.Preferences");
    const pid = s.pid();
    await sleep(30000);
    execFileSync("kill", ["-STOP", pid]);
    // The app said it was away before it froze: the card waits on it.
    await until(() => s.page.evaluate(() => net?.rb?.reconnecting), "the browser redialing", 30000);
    assert.equal(await s.title(), "Friend switched away");
    assert.match(await s.page.evaluate(() => document.getElementById("net-away-time").textContent), /^Waiting for /);
    console.log(`  browser reconnecting at ${at()}`);
    await sleep(150000 - (Date.now() - t0));
    assert.ok(await s.linked(), "the browser kept the session through the freeze");
    execFileSync("kill", ["-CONT", pid]);
    simctl("launch", UDID, BUNDLE);
    await until(async () => (await s.resumes()).every((n) => n >= 1),
      async () => "both resumed; browser: " + (await s.webLog()).slice(-4).join(" | ") + " // app: " + s.netlink().slice(-4).join(" | "), 90000);
    console.log(`  resumed at ${at()}; app: ` + s.netlink().filter((l) => /redial|resumed/.test(l)).join(" | "));
    await s.sameGames();
    await s.end();
  },
  async "roles swapped: the app is the guest, first on the retry code, and a channel dies before RESUME"() {
    const s = await link("swapped", { webFirst: true });
    await until(() => s.page.evaluate(() => Module._rollback_head() > 200), "some play first", 30000);
    assert.ok(await s.page.evaluate(() => net.isHost), "the browser hosts");
    // Drop 1: the browser's connection dies while its server is out of reach
    // for a few seconds, so the app is first on the retry code.
    await s.page.evaluate(() => {
      const WS = window.WebSocket;
      window.WebSocket = class { constructor() { throw new Error("offline"); } };
      setTimeout(() => { window.WebSocket = WS; }, 5000);
      net.pc.close();
    });
    await until(async () => (await s.resumes()).every((n) => n >= 1),
      async () => "resume 1; browser: " + (await s.webLog()).slice(-4).join(" | ") + " // app: " + s.netlink().slice(-4).join(" | "), 60000);
    assert.ok(s.netlink().some((l) => l === "redial: paired host"), "the app was first on the retry code: " + s.netlink());
    // Drop 2: the browser's next redialed channel dies just as it would say RESUME.
    await sleep(1500);
    await s.page.evaluate(() => {
      const send = RTCDataChannel.prototype.send;
      let killed = false;
      RTCDataChannel.prototype.send = function (buf) {
        const kind = buf instanceof ArrayBuffer ? new Uint8Array(buf)[0] : buf?.[0];
        if (kind === 13 && !killed) { killed = true; this.close(); return; }
        return send.call(this, buf);
      };
      net.pc.close();
    });
    await until(async () => (await s.resumes()).every((n) => n >= 2),
      async () => "resume 2; browser: " + (await s.webLog()).slice(-5).join(" | ") + " // app: " + s.netlink().slice(-5).join(" | "), 90000);
    console.log("  app: " + s.netlink().filter((l) => /redial|resumed/.test(l)).join(" | "));
    await s.sameGames();
    await s.end();
  },
  // formal/WebState/LinkResume.lean bug_resume_pause_swap_ios: each side
  // used to answer a resume with its own pause state, and the answers
  // crossed. Here the app's background pause never reaches the browser (as
  // when the connection dies under it) and the link drops while the app is
  // still in the background, where it won't unpause.
  async "the app paused in the background across a drop: both stay paused, then both run"() {
    const s = await link("bg-pause");
    await until(() => s.page.evaluate(() => Module._rollback_head() > 200), "some play first", 30000);
    // The app logs every change of its pause state ("game: paused/running")
    // and its trips to the background ("netlink: away").
    const appPaused = () => {
      const g = s.netlinkRaw().filter((l) => l.includes("game: ")).map((l) => l.replace(/^.*game: /, ""));
      return g.at(-1) === "paused";
    };
    assert.ok(!appPaused(), "the app is playing");
    // The browser loses pause messages on this channel only.
    await s.page.evaluate(() => {
      const dc = net.dc;
      const on = dc.onmessage;
      dc.onmessage = (e) => { if (new Uint8Array(e.data)[0] !== 8) on(e); };
    });
    const awayBefore = s.netlink().filter((l) => l === "away").length;
    simctl("launch", UDID, "com.apple.Preferences");
    await until(() => s.netlink().filter((l) => l === "away").length > awayBefore && appPaused(),
      "the app in the background, paused", 15000);
    assert.ok(!(await s.page.evaluate(() => paused)), "the browser never heard it");
    await s.page.evaluate(() => net.pc.close());
    await until(async () => (await s.resumes()).every((n) => n >= 1),
      async () => "both resumed; browser: " + (await s.webLog()).slice(-4).join(" | ") + " // app: " + s.netlink().slice(-4).join(" | "), 60000);
    await sleep(2000); // anything either side sends after resuming lands
    const browserPaused = await s.page.evaluate(() => paused);
    console.log(`  after the resume: browser ${browserPaused ? "paused" : "running"}, app ${appPaused() ? "paused" : "running"}`);
    assert.ok(browserPaused && appPaused(), "both paused (the app was paused and away)");
    simctl("launch", UDID, BUNDLE);
    await until(async () => !appPaused() && !(await s.page.evaluate(() => paused)),
      async () => `both running after the app's return (browser paused: ${await s.page.evaluate(() => paused)}, app paused: ${appPaused()})`, 15000);
    await s.sameGames();
    await s.end();
  },
  // The goodbye note (POST /bye on the retry code): a side that ends while
  // the link is down tells the redialing friend through the server.
  async "the browser's Disconnect while reconnecting reaches the redialing app"() {
    const s = await link("bye-to-app");
    await until(() => s.page.evaluate(() => Module._rollback_head() > 200), "some play first", 30000);
    // The browser's redials can't reach the server: the app waits on the code.
    await s.page.evaluate(() => {
      window.WebSocket = class { constructor() { throw new Error("offline"); } };
      net.pc.close();
    });
    await until(() => s.netlink().some((l) => l === "redial: waiting for the friend"),
      () => "the app waiting on the retry code: " + s.netlink().slice(-4).join(" | "), 30000);
    const t0 = Date.now();
    await s.page.click("#net-away-disconnect");
    await s.page.click("#net-away-disconnect");
    await until(() => s.netlink().some((l) => l === "redial: the friend left"),
      () => "the app told: " + s.netlink().slice(-4).join(" | "), 10000);
    await until(() => s.toastsApp().some((t) => t.startsWith("Peer disconnected")),
      () => "the app's toast: " + s.toastsApp().slice(-3).join(" | "), 5000);
    console.log(`  told in ${((Date.now() - t0) / 1000).toFixed(1)} s; app: ` + s.netlink().slice(-3).join(" | "));
    assert.ok(!s.netlink().some((l) => l.startsWith("goodbye note")), "the app left no note of its own");
    await s.end();
  },
  async "the app's give-up reaches the browser as \"Couldn't reconnect\""() {
    const s = await link("bye-from-app", { appArgs: ["-link-give-up", "12"] });
    await until(() => s.page.evaluate(() => Module._rollback_head() > 200), "some play first", 30000);
    // The browser can't reach the server until the app has given up.
    await s.page.evaluate(() => {
      window.__WS = window.WebSocket;
      window.WebSocket = class { constructor() { throw new Error("offline"); } };
      net.pc.close();
    });
    await until(() => s.netlink().some((l) => l.startsWith("goodbye note on the retry code (gave-up)")),
      () => "the app gave up: " + s.netlink().slice(-4).join(" | "), 60000);
    assert.ok(await s.linked(), "the browser still redialing");
    await sleep(1000); // the note lands
    await s.page.evaluate(() => { window.WebSocket = window.__WS; });
    await until(async () => !(await s.linked()), "the browser told", 30000);
    assert.ok((await s.toasts()).some((t) => t.startsWith("Couldn't reconnect")), (await s.toasts()).join(" | "));
    assert.ok((await s.webLog()).some((t) => t === "redial: the friend gave up"), (await s.webLog()).slice(-4).join(" | "));
    await s.end();
  },
  async "the app killed mid-session: its next launch says goodbye"() {
    const s = await link("killed");
    await until(() => s.page.evaluate(() => Module._rollback_head() > 200), "some play first", 30000);
    execFileSync("kill", ["-KILL", s.pid()]);
    await until(async () => (await s.title()) === "Reconnecting…", "the browser redialing", 60000);
    await sleep(2000);
    assert.ok(await s.linked(), "still waiting on the friend");
    const log2 = join(SHOTS, "link-resume-killed-relaunch.log");
    if (existsSync(log2)) rmSync(log2);
    const t0 = Date.now();
    simctl("launch", "--stderr=" + log2, UDID, BUNDLE, "-audio.muted", "YES", "-signal", "ws://127.0.0.1:" + PORT);
    await until(async () => !(await s.linked()), "the browser told", 20000);
    console.log(`  told ${((Date.now() - t0) / 1000).toFixed(1)} s after the relaunch`);
    assert.ok((await s.toasts()).some((t) => t.startsWith("Peer disconnected")), (await s.toasts()).join(" | "));
    const relaunch = existsSync(log2) ? readFileSync(log2, "utf8") : "";
    assert.ok(relaunch.includes("the last session never ended"), "the app's goodbye on launch");
    await s.end();
  },
  async "the app away longer than the browser waits"() {
    const s = await link("gave-up");
    // Shortened, but past the ~46 s it takes the browser to notice.
    await s.page.evaluate(() => { rbResumeGiveUpMs = 60000; });
    await until(() => s.page.evaluate(() => Module._rollback_head() > 200), "some play first", 30000);
    const t0 = Date.now();
    simctl("launch", UDID, "com.apple.Preferences");
    const pid = s.pid();
    await sleep(30000);
    execFileSync("kill", ["-STOP", pid]);
    // The browser's connection fails (~16 s), it redials, gives up 60 s in.
    await until(async () => !(await s.linked()), "the browser gave up", 120000);
    assert.ok((await s.toasts()).some((t) => t.startsWith("Couldn't reconnect")), (await s.toasts()).join(" | "));
    // The app wakes long after: its last message from the browser came ~30 s
    // in, so 220 s in is past its own 180 s give-up.
    await sleep(Math.max(0, 220000 - (Date.now() - t0)));
    execFileSync("kill", ["-CONT", pid]);
    simctl("launch", UDID, BUNDLE);
    await until(() => s.netlink().some((l) => l.includes("the friend has given up") || l.includes("Couldn't reconnect")),
      () => "the app ended it: " + s.netlink().join(" | "), 30000);
    await sleep(1500);
    console.log("  app: " + s.netlink().slice(-3).join(" | ") + "; toasts: " + s.toastsApp().slice(-2).join(" | "));
    assert.ok(!s.netlink().some((l) => l.startsWith("redial: waiting")), "the app didn't wait on a friend long gone");
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
console.log(failed ? `\n${failed} case(s) failed` : "\nall passed");
process.exit(failed ? 1 : 0);
