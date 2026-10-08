// Big games down from Drive at once: three 32 MB ROMs (the largest a GBA
// cart is, e.g. the GBA Video carts) from the fake Drive into a fresh app,
// all started together as three taps on their tiles. The app must stay
// responsive (the main thread never waits long: -stall-log), keep its memory
// near the size of what it holds, stay alive, and land every ROM byte for
// byte. Nothing leaves the machine; the app runs muted.
//
//   node ios/e2e/drive-big.mjs <Dingbat.app (Debug)> [simulator udid]
//
// COUNT=<n> and MB=<size> change the load (default 3 x 32).

import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import { join } from "node:path";
import assert from "node:assert/strict";
import { makeDrive } from "../../web/e2e/fakedrive.mjs";

const APP = process.argv[2];
const UDID = process.argv[3] || process.env.SIMDEV || "20B3E400-B140-4C0D-A981-A87BDBEDAEF9";
const BUNDLE = "com.mattrb.dingbat";
const COUNT = Number(process.env.COUNT || 3);
const MB = Number(process.env.MB || 32);
if (!APP) { console.error("usage: node ios/e2e/drive-big.mjs <Dingbat.app> [udid]"); process.exit(2); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const simctl = (...a) => execFileSync("xcrun", ["simctl", ...a], { encoding: "utf8" });
const trySimctl = (...a) => { try { return simctl(...a); } catch { return ""; } };
const sha = (b) => createHash("sha256").update(b).digest("hex");

// The fake Drive over HTTP, for the app: /<host>/<path> is https://<host>/<path>.
const serveDrive = (drive) => new Promise((resolve) => {
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks);
    const [, host, ...rest] = req.url.split("/");
    const url = "https://" + host + "/" + rest.join("/");
    await drive.handle({
      request: () => ({ url: () => url, method: () => req.method, postDataBuffer: () => body, headers: () => req.headers }),
      fulfill: async ({ status = 200, contentType, body: b, headers = {} }) => {
        res.writeHead(status, { "Content-Type": contentType || "application/octet-stream", ...headers });
        res.end(b);
      },
      abort: async () => { res.writeHead(502); res.end(); },
    }, "ios");
  });
  server.listen(0, "127.0.0.1", () => resolve({ base: `http://127.0.0.1:${server.address().port}`, close: () => server.close() }));
});

const drive = makeDrive();
const games = [];
for (let i = 1; i <= COUNT; i++) {
  const name = `Big Video ${i}.gba`;
  const bytes = randomBytes(MB << 20);
  const t = new Date(Date.parse("2026-10-01T10:00:00Z") + i * 1000).toISOString();
  drive.files.push({ id: "big" + i, name: "rom:" + name, bytes, modifiedTime: t, createdTime: t });
  games.push({ name, sum: sha(bytes) });
}
const stub = await serveDrive(drive);

trySimctl("boot", UDID);
simctl("bootstatus", UDID);
trySimctl("terminate", UDID, BUNDLE);
trySimctl("uninstall", UDID, BUNDLE);
simctl("install", UDID, APP);
const data = simctl("get_app_container", UDID, BUNDLE, "data").trim();
const tmp = join(data, "tmp");
simctl("launch", UDID, BUNDLE, "-audio.muted", "YES", "-drive-stub", stub.base, "-stall-log",
       "-drive-download", games.map((g) => g.name).join(","));

// The app's resident memory (a simulator app is a Mac process).
const rss = () => {
  try {
    const pid = execFileSync("pgrep", ["-f", "Dingbat.app/Dingbat"], { encoding: "utf8" }).trim().split("\n")[0];
    return Number(execFileSync("ps", ["-o", "rss=", "-p", pid], { encoding: "utf8" }).trim()) / 1024;
  } catch { return 0; }
};
const alive = () => trySimctl("spawn", UDID, "launchctl", "list").includes(BUNDLE);

const t0 = Date.now();
let peak = 0, done = "", died = false;
while (Date.now() - t0 < 300000) {
  peak = Math.max(peak, rss());
  const f = join(tmp, "download.txt");
  done = existsSync(f) ? readFileSync(f, "utf8") : "";
  if (done.includes("DONE")) break;
  if (Date.now() - t0 > 5000 && !alive()) { died = true; break; }
  await sleep(250);
}
// Main-thread waits from the downloads' start on (launch is not this test's).
const start = Number(/start (\d+)/.exec(done)?.[1] || 0);
const waits = (existsSync(join(tmp, "stall.txt")) ? readFileSync(join(tmp, "stall.txt"), "utf8") : "")
  .trim().split("\n").filter(Boolean).map((l) => l.split(" ").map(Number))
  .filter(([at]) => at >= start);
const stall = Math.max(0, ...waits.map(([, ms]) => ms));
console.log(`${COUNT} x ${MB} MB: ${((Date.now() - t0) / 1000).toFixed(1)} s, peak memory ${peak.toFixed(0)} MB, ` +
            `longest main-thread wait ${stall} ms${died ? ", THE APP DIED" : ""}`);
console.log(done.trim().split("\n").filter((l) => l !== "DONE" && !l.startsWith("start")).map((l) => "  " + l).join("\n"));
if (waits.length) console.log("  main-thread waits over 100 ms after the start: " +
  waits.map(([at, ms]) => `${ms} ms at +${at - start} ms`).join(", "));

let failed = 0;
const check = (what, fn) => { try { fn(); console.log("ok   " + what); } catch (e) { failed++; console.log("FAIL " + what + ": " + e.message); } };
check("the app stayed alive", () => assert.ok(!died && alive()));
check("every download finished", () => {
  assert.ok(done.includes("DONE"), "no DONE");
  for (const g of games) assert.ok(done.includes(g.name + " ok"), g.name);
});
check("every ROM landed byte for byte", () => {
  for (const g of games) assert.equal(sha(readFileSync(join(data, "Documents/roms", g.name))), g.sum, g.name);
});
check("the main thread never waited over 250 ms", () => assert.ok(stall <= 250, stall + " ms"));
// What it holds at once is at most the ROMs themselves; a buffer or copy per
// byte or per download on top shows here.
check(`memory stayed under ${COUNT * MB + 250} MB`, () => assert.ok(peak <= COUNT * MB + 250, peak.toFixed(0) + " MB"));

trySimctl("terminate", UDID, BUNDLE);
trySimctl("shutdown", UDID);
stub.close();
console.log(failed ? `\n${failed} check(s) failed` : "\nall passed");
process.exit(failed ? 1 : 0);
