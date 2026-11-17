// Online link between the iOS app and the desktop's online link: the app in
// a headless iOS simulator and the desktop's headless player
// (tests/online_peer.nim, the same src/dingbat/frontend/online_link.nim the
// desktop app runs) pair through a local signaling server and link over
// WebRTC. Both play buttons that change (the app -link-press, the player
// random ones), stop at the same frame, and must then hold byte-identical
// states for both players' cores. Both run muted.
//
//   (build the app as in ios/e2e/link.mjs)
//   nim c -d:release -d:test_harness --path:src -o:online_peer tests/online_peer.nim
//   ONLINE_PEER_BIN=online_peer node ios/e2e/link-native.mjs <Dingbat.app> [simulator udid]
//
// Cases: the same GBA game, the app hosting and the desktop hosting; the
// same GB game; two different GBA games (each side sends the other its ROM).

import { spawn, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, copyFileSync, mkdirSync, existsSync, rmSync, mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import assert from "node:assert/strict";

const APP = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV || "20B3E400-B140-4C0D-A981-A87BDBEDAEF9";
const PEER = process.env.ONLINE_PEER_BIN;
const BUNDLE = "com.mattrb.dingbat";
const MUTED = ["-audio.muted", "YES"];
const ROOT = new URL("../..", import.meta.url).pathname;
const ROMS = join(ROOT, "tests/roms");
if (!APP || !PEER) {
  console.error("usage: ONLINE_PEER_BIN=<online_peer> node ios/e2e/link-native.mjs <Dingbat.app> [udid]");
  process.exit(2);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const simctl = (...a) => execFileSync("xcrun", ["simctl", ...a], { encoding: "utf8" });
const trySimctl = (...a) => { try { return simctl(...a); } catch { return ""; } };

const PORT = 19790 + Math.floor(Math.random() * 1000);
const signal = spawn(process.execPath, [join(ROOT, "web/signaling/server.js"), String(PORT)],
                     { stdio: ["ignore", "ignore", "inherit"] });
await sleep(500);
const STOP = 600;
const LOGS = mkdtempSync("/tmp/dingbat-link-native-");

const launchApp = (rom, args, log) => {
  trySimctl("boot", UDID);
  simctl("bootstatus", UDID);
  trySimctl("terminate", UDID, BUNDLE);
  trySimctl("uninstall", UDID, BUNDLE);
  simctl("install", UDID, APP);
  const data = simctl("get_app_container", UDID, BUNDLE, "data").trim();
  mkdirSync(join(data, "Documents/roms"), { recursive: true });
  copyFileSync(rom, join(data, "Documents/roms", rom.split("/").pop()));
  if (existsSync(log)) rmSync(log);
  simctl("launch", "--stderr=" + log, UDID, BUNDLE, ...MUTED, ...args);
  return data;
};

const runPeer = (rom, code) => {
  const p = spawn(PEER, [rom, code, `--signal=ws://127.0.0.1:${PORT}`, `--frames=${STOP}`,
    "--warmup=20", "--timeout=150"], { stdio: ["ignore", "pipe", "pipe"] });
  let out = "";
  p.stdout.on("data", (d) => { out += d; });
  p.stderr.on("data", (d) => { out += d; });
  return { p, log: () => out, done: new Promise((res) => p.on("exit", (rc) => res(rc))) };
};

// `appFirst`: the app reaches the server first and hosts.
const runCase = async (name, { appRom, peerRom, appFirst }) => {
  console.log(`\n${name}`);
  const code = "N" + Math.random().toString(36).slice(2, 8).toUpperCase();
  // A host path the simulator can write (not $TMPDIR's /var/folders).
  const log = join(LOGS, `link-native-${name.replace(/\W+/g, "-")}.log`);
  let peer = null;
  if (!appFirst) { peer = runPeer(peerRom, code); await sleep(1500); }
  const data = launchApp(appRom, ["-autoplay", appRom.split("/").pop(), "-signal", `ws://127.0.0.1:${PORT}`,
                                  "-link", code, "-link-stop-at", String(STOP), "-link-press"], log);
  if (appFirst) { await sleep(15000); peer = runPeer(peerRom, code); }
  const dumpFile = join(data, "tmp/linkdump.txt");
  let appDump = "";
  for (let i = 0; i < 1200 && !(appDump.startsWith("LINKDUMP") && /ONLINE DUMP/.test(peer.log())); i++) {
    await sleep(100);
    if (existsSync(dumpFile)) appDump = readFileSync(dumpFile, "utf8").trim();
  }
  const pm = peer.log().match(/ONLINE DUMP (\d+) (\d+) (\S+) (\S+)/);
  const am = appDump.match(/LINKDUMP head=(\d+) confirmed=(\d+) p0=(\S+) p1=(\S+)/);
  console.log("  app:  " + (appDump || "(no dump)"));
  console.log("  peer: " + (pm ? pm[0] : "(no dump) " + peer.log().slice(-400)));
  const hosted = /started as host/.test(peer.log()) ? "desktop" : "app";
  console.log("  host: " + hosted);
  trySimctl("terminate", UDID, BUNDLE);
  const rc = await Promise.race([peer.done, sleep(15000).then(() => "timeout")]);
  if (rc === "timeout") peer.p.kill("SIGKILL");
  assert.ok(am && pm, "both sides dumped");
  assert.deepEqual([am[1], am[2], am[3], am[4]], [pm[1], pm[2], pm[3], pm[4]], "app and desktop cores identical");
  assert.equal(hosted, appFirst ? "app" : "desktop", "the first to arrive hosts");
  // terminate kills the app with no goodbye: the desktop redials (as for
  // a vanished friend) until the peer process is stopped below.
  console.log("  ok");
};

const GBA = join(ROMS, "attachtest.gba");
const GB = join(ROMS, "gblinktest.gb");
const dir = mkdtempSync(join(tmpdir(), "dingbat-native-ios-"));
const OTHER = join(dir, "attachtest-b.gba");
writeFileSync(OTHER, Buffer.concat([readFileSync(GBA), Buffer.from([0xff, 0xff, 0xff, 0xff])]));

let failed = 0;
for (const [name, c] of [
  ["GBA, the app hosts", { appRom: GBA, peerRom: GBA, appFirst: true }],
  ["GBA, the desktop hosts", { appRom: GBA, peerRom: GBA, appFirst: false }],
  ["GB", { appRom: GB, peerRom: GB, appFirst: false }],
  ["cross-game GBA", { appRom: GBA, peerRom: OTHER, appFirst: false }],
]) {
  try { await runCase(name, c); } catch (e) { failed++; console.log("  FAIL: " + e.message); }
}
trySimctl("terminate", UDID, BUNDLE);
trySimctl("shutdown", UDID);
signal.kill();
console.log(failed ? `\n${failed} FAILED` : "\nall passed");
process.exit(failed ? 1 : 0);
