// A real Pokémon trade between the iOS app and the web build, over a bad
// network. FireRed runs in headless Chromium and LeafGreen in the iOS
// simulator, each loaded from a save state standing at the Cable Club
// counter; they link online (each side sends the other its ROM first) with
// every WebRTC packet going through a relay that delays, jitters and drops
// it (netem.mjs). Both players then play the same scripted trade: talk to
// the attendant, save, enter the Trade Center, sit at the table, offer the
// first Pokémon, confirm, and sit through the trade, the evolution and the
// save after it. At the stop frame both peers must hold byte-identical
// states for both cores, and the screenshots show the swapped parties.
//
// NOT IN CI: it needs the real games (copyrighted) and the two states,
// passed in by path:
//   FR=<FireRed.gba> FR_STATE=<counter.state> LG=<LeafGreen.gba> LG_STATE=<counter.state> \
//     node ios/e2e/trade.mjs <Dingbat.app (Debug)> [simulator udid]
// NETEM="delay,jitter,loss" sets the network (default 40,15,0.02: ~80 ms
// RTT, 2% loss each way); NETEM=off links straight. NETEM_PLAY, the same
// form, switches to another once linked: the setup's two 16 MB ROMs are
// loss- and RTT-bound bulk transfers (minutes at 300 ms RTT), the trade is
// not. SHOTS=<dir> keeps the screenshots (default /tmp). The script is the one trade_repro proved
// (tests/trade_repro.nim): `node ios/e2e/trade.mjs --nav out.txt` writes it
// in that harness's format.

import { spawn, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, copyFileSync, mkdirSync, existsSync, rmSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import assert from "node:assert/strict";

// Each player's buttons, by linked frame: [from, to, buttons, every] taps
// every `every` frames (held 4), or "hold" for the whole span. Player 0 (the
// link's host) sits on the left of the table, player 1 on the right; the
// rest is the same for both, whichever game each plays.
const STEPS = (seat) => [
  [10, 1750, "A", 30],          // the attendant, Trade Center, save, link, enter
  [1830, 1890, "UP", "hold"],   // up to the trade machine
  [1920, 1930, seat, "hold"],   // one step aside
  [1960, 1970, "UP", "hold"],   // onto the chair
  [2720, 2721, "A", 10],        // the first Pokémon
  [2760, 2761, "DOWN", 10],     // Summary -> Trade
  [2790, 2791, "A", 10],
  [2900, 6900, "A", 40],        // confirm, the trade, the evolution, the save
];
const STOP = 7800;
// The cores' button bits (src/dingbat/common/input.nim Input), not KEYINPUT's.
const BIT = { UP: 1, DOWN: 2, LEFT: 4, RIGHT: 8, A: 16, B: 32, SELECT: 64, START: 128, L: 256, R: 512 };

// [[frame, mask]] change points.
const script = (player) => {
  const ev = new Map();
  for (const [a, b, btn, every] of STEPS(player === 0 ? "LEFT" : "RIGHT")) {
    if (every === "hold") { ev.set(a, BIT[btn]); if (!ev.has(b)) ev.set(b, 0); continue; }
    for (let f = a; f < b; f += every) { ev.set(f, BIT[btn]); ev.set(f + 4, 0); }
  }
  return [[0, 0], ...[...ev].sort((x, y) => x[0] - y[0])];
};

if (process.argv[2] === "--nav") {
  const names = Object.entries(BIT);
  const lines = [];
  for (const p of [0, 1]) for (const [f, m] of script(p)) {
    const btns = names.filter(([, b]) => m & b).map(([n]) => n);
    lines.push([f, p, btns.join(" ") || "-"]);
  }
  lines.sort((x, y) => x[0] - y[0] || x[1] - y[1]);
  writeFileSync(process.argv[3], lines.map((l) => l.join(" ")).join("\n") + "\n");
  process.exit(0);
}

const { serveWeb, builtWeb, WEB, sleep } = await import("../../web/e2e/devices.mjs");
const { impair } = await import("./netem.mjs");

const APP = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV || "20B3E400-B140-4C0D-A981-A87BDBEDAEF9";
const BUNDLE = "com.mattrb.dingbat";
const MUTED = ["-audio.muted", "YES"];
const SHOTS = process.env.SHOTS || "/tmp";
const { FR, FR_STATE, LG, LG_STATE } = process.env;
if (!APP || !FR || !FR_STATE || !LG || !LG_STATE) {
  console.error("usage: FR= FR_STATE= LG= LG_STATE= node ios/e2e/trade.mjs <Dingbat.app> [udid]");
  process.exit(2);
}
if (!builtWeb()) { console.error("web/em.wasm not built"); process.exit(2); }
const [delay, jitter, loss] = (process.env.NETEM || "40,15,0.02").split(",").map(Number);
const play = process.env.NETEM_PLAY?.split(",").map(Number);
const netOn = process.env.NETEM !== "off";
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
const browser = await playwright.chromium.launch({
  headless: true, args: ["--mute-audio", "--disable-features=WebRtcHideLocalIpsWithMdns"] });
const sig = "ws://127.0.0.1:" + PORT;
const code = "T" + Math.random().toString(36).slice(2, 8).toUpperCase();
const t0 = Date.now();
const secs = () => ((Date.now() - t0) / 1000).toFixed(0) + "s";

let failed = false, net = null;
try {
  console.log(netOn ? `network: ${delay} ms ±${jitter} each way, ${(loss * 100).toFixed(1)}% loss each way`
                    : "network: direct");
  const ctx = await browser.newContext({ serviceWorkers: "block", viewport: { width: 1000, height: 800 } });
  const page = await ctx.newPage();
  if (netOn) net = await impair(page, { delay, jitter, loss, seed: +(process.env.NETEM_SEED || 1) });
  page.on("console", (m) => { if (/netplay/.test(m.text())) console.log("  web:", m.text()); });
  await page.goto(web.url + "?signal=" + sig);
  await page.waitForFunction(() => typeof Module !== "undefined" && !!Module._rollback_tick, null, { timeout: 30000 });

  // The browser: FireRed, at the counter.
  const [chooser] = await Promise.all([
    page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click(),
  ]);
  await chooser.setFiles({ name: "PokemonFireRed.gba", mimeType: "application/octet-stream", buffer: readFileSync(FR) });
  await page.waitForFunction(() => document.body.classList.contains("running") && !paused, null, { timeout: 30000 });
  assert.ok(await page.evaluate((b) => applyStateBytes(new Uint8Array(b)), [...readFileSync(FR_STATE)]),
            "the browser took FireRed's state");
  await page.evaluate(({ scripts, stop }) => {
    const tick = Module._rollback_tick;
    Module._rollback_tick = () => {
      const h = Module._rollback_head();
      if (h >= stop) return -1;
      const s = scripts[net.rb.localPlayer];
      let b = 0;
      for (const [f, m] of s) { if (f <= h) b = m; else break; }
      localButtons = b;
      return tick(b);
    };
  }, { scripts: [script(0), script(1)], stop: STOP });

  // The app: LeafGreen, at the counter, linking with the code.
  trySimctl("boot", UDID);
  simctl("bootstatus", UDID);
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("uninstall", UDID, BUNDLE);
  simctl("install", UDID, APP);
  const data = simctl("get_app_container", UDID, BUNDLE, "data").trim();
  mkdirSync(join(data, "Documents/roms"), { recursive: true });
  copyFileSync(LG, join(data, "Documents/roms/PokemonLeafGreen.gba"));
  copyFileSync(LG_STATE, join(data, "Documents/lg.state"));
  for (const p of [0, 1]) {
    writeFileSync(join(data, `Documents/trade.p${p}.txt`), script(p).map((e) => e.join(" ")).join("\n") + "\n");
  }
  const log = join(SHOTS, "trade-app.log");
  if (existsSync(log)) rmSync(log);
  simctl("launch", "--stderr=" + log, UDID, BUNDLE, ...MUTED, "-autoplay", "PokemonLeafGreen.gba",
         "-load-state", "lg.state", "-signal", sig, "-link", code,
         "-link-script", "trade", "-link-stop-at", String(STOP));
  await sleep(3000);
  await page.click("#menu-btn");
  await page.click("#net-connect");
  await page.fill("#net-code-input", code);
  await page.click("#net-join-go");

  // Setup: each side sends the other its ROM and its state.
  for (let i = 0; !(await page.evaluate(() => rollbackMode)); i++) {
    assert.ok(i < 180, "linked within 15 minutes");
    if (i % 4 === 0) {
      const x = await page.evaluate(() => net?.rb && [net.rb.romSent, net.rb.romGot, net.rb.romLen, net.rb.remoteRomLen]);
      if (x) console.log(`  ${secs()} setup: sent ${(x[0] / 1048576).toFixed(1)}/${(x[2] / 1048576).toFixed(1)} MB,` +
                         ` got ${(x[1] / 1048576).toFixed(1)}/${(x[3] / 1048576).toFixed(1)} MB`);
    }
    await sleep(5000);
  }
  console.log(`  linked after ${secs()} (ROMs and states exchanged); browser is player ` +
              await page.evaluate(() => net.rb.localPlayer));
  if (net && play) {
    net.set({ delay: play[0], jitter: play[1], loss: play[2] });
    console.log(`  network now: ${play[0]} ms ±${play[1]} each way, ${(play[2] * 100).toFixed(1)}% loss each way`);
  }
  // Progress every 20 s, until both are at the stop with every input in.
  const shot = (name) => trySimctl("io", UDID, "screenshot", join(SHOTS, `trade-${name}-app.png`));
  const marks = [[1400, "room"], [2400, "table"], [3600, "trading"], [5400, "evolving"]];
  for (let i = 0; i < 90; i++) {
    const [h, c] = await page.evaluate(() => [Module._rollback_head(), Module._rollback_confirmed()]);
    while (marks.length && h >= marks[0][0]) {
      const [, name] = marks.shift();
      shot(name);
      await page.screenshot({ path: join(SHOTS, `trade-${name}-web.png`) });
    }
    if (h >= STOP && c === STOP - 1) break;
    if (i % 4 === 0) console.log(`  ${secs()} frame ${h} confirmed ${c}` + (net ? ` relayed ${JSON.stringify(net.stats())}` : ""));
    await sleep(5000);
  }
  await page.waitForFunction((stop) => Module._rollback_head() >= stop &&
    Module._rollback_confirmed() === stop - 1, STOP, { timeout: 30000 });

  let appLine = "", appState = "";
  for (let i = 0; i < 150 && !appLine; i++) {
    await sleep(200);
    const f = join(data, "tmp/linkdump.txt");
    appState = existsSync(f) ? readFileSync(f, "utf8").trim() : "";
    appLine = appState.startsWith("LINKDUMP") ? appState : "";
  }
  shot("done");
  await page.screenshot({ path: join(SHOTS, "trade-done-web.png") });
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
  if (net) console.log("  relayed " + JSON.stringify(net.stats()));
  const appLog = readFileSync(log, "utf8");
  assert.ok(appLine, "the app reached the stop frame with every input in");
  assert.equal(appLine, webLine, "both players' cores identical on both sides");
  assert.ok(!/netlink: .*(failed|lost)/i.test(appLog), "no link failure logged");
  console.log(`ok after ${secs()}; screenshots in ${SHOTS}/trade-*.png`);
  await ctx.close();
} catch (e) {
  failed = true;
  console.log("FAIL " + e.message);
} finally {
  net?.close();
  await browser.close();
  web.close();
  signal.kill("SIGKILL"); // SIGTERM drains gracefully and outlives the test
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("shutdown", UDID);
}
process.exit(failed ? 1 : 0);
