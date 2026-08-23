// End-to-end guard for the symmetric manual code exchange: both sides offer,
// each rewrites the peer's code into an answer (SDPCodec.answerFrom) with the
// DTLS role netplay.js picks on Confirm. Drives real RTCPeerConnections in
// headless Chromium (no STUN: host candidates only, so no network needed) and
// asserts the host's DataChannel opens on both sides and a message round-trips.
//
// Run:  node web/manualpair.test.mjs   (after: npx playwright install chromium)

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

let chromium;
try {
  ({ chromium } = await import("playwright"));
} catch {
  console.error(
    "Playwright is not installed. From web/: `npm ci` (or npm install) then " +
    "`npx playwright install --with-deps chromium`, then re-run this test."
  );
  process.exit(2);
}

const here = dirname(fileURLToPath(import.meta.url));
const sdputilSrc = readFileSync(join(here, "sdputil.js"), "utf8");

let failures = 0;
const assert = (cond, msg) => {
  if (cond) { console.log(`  ok: ${msg}`); return; }
  failures++;
  console.error(`  FAIL: ${msg}`);
};

const run = async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.addScriptTag({ content: sdputilSrc });

  const result = await page.evaluate(async () => {
    const out = { steps: [] };
    try {
      const gather = (pc) =>
        new Promise((resolve) => {
          if (pc.iceGatheringState === "complete") return resolve();
          let done = false;
          const finish = () => { if (done) return; done = true; resolve(); };
          pc.addEventListener("icegatheringstatechange", () => {
            if (pc.iceGatheringState === "complete") finish();
          });
          pc.addEventListener("icecandidate", (e) => { if (!e.candidate) finish(); });
          setTimeout(finish, 3500);
        });

      // As netplay's manualPrepare: offer with a pre-created channel, full
      // gather, encode.
      const mkSide = async () => {
        const pc = new RTCPeerConnection({ iceServers: [] });
        const chan = pc.createDataChannel("link", { ordered: true });
        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        await gather(pc);
        const code = SDPCodec.encode(pc.localDescription);
        return { pc, chan, code };
      };

      const A = await mkSide();
      const B = await mkSide();
      out.codeLenA = A.code ? A.code.length : 0;
      out.codeLenB = B.code ? B.code.length : 0;
      if (!A.code || !B.code) throw new Error("encode failed");
      out.steps.push("encoded both offers");

      // As netplay's Confirm: role from the code strings; host rewrites the
      // peer's blob with setup:active, guest with setup:passive.
      const aIsHost = A.code > B.code;
      const host = aIsHost ? A : B;
      const guest = aIsHost ? B : A;

      const hostRemote = SDPCodec.answerFrom(guest.code, "active");
      const guestRemote = SDPCodec.answerFrom(host.code, "passive");
      if (!hostRemote || !guestRemote) throw new Error("answerFrom failed");
      out.remoteTypes = [hostRemote.type, guestRemote.type];

      const guestChan = new Promise((resolve) =>
        guest.pc.addEventListener("datachannel", (e) => resolve(e.channel))
      );

      await host.pc.setRemoteDescription(hostRemote);
      await guest.pc.setRemoteDescription(guestRemote);
      out.steps.push("both remote descriptions accepted");

      const timeout = (ms, what) =>
        new Promise((_, rej) => setTimeout(() => rej(new Error("timeout: " + what)), ms));

      const opened = (ch) =>
        ch.readyState === "open"
          ? Promise.resolve(ch)
          : new Promise((resolve, reject) => {
              ch.onopen = () => resolve(ch);
              ch.onerror = (e) => reject(new Error("channel error: " + (e.error || e)));
            });

      const hostChan = await Promise.race([opened(host.chan), timeout(10000, "host channel open")]);
      const gChan = await Promise.race([
        guestChan.then(opened),
        timeout(10000, "guest datachannel"),
      ]);
      out.steps.push("host channel open on both sides");

      const echoed = new Promise((resolve) => {
        gChan.onmessage = (e) => gChan.send("pong:" + e.data);
      });
      const reply = await Promise.race([
        new Promise((resolve) => {
          hostChan.onmessage = (e) => resolve(e.data);
          hostChan.send("ping");
        }),
        timeout(5000, "message round-trip"),
      ]);
      out.roundTrip = reply;
      out.connStates = [host.pc.connectionState, guest.pc.connectionState];
      host.pc.close();
      guest.pc.close();
      out.ok = true;
    } catch (e) {
      out.error = String((e && e.message) || e);
    }
    return out;
  });

  console.log("symmetric manual-code pairing in headless Chromium:");
  assert(!result.error, `no errors (${result.error || "none"}) [${result.steps.join(" -> ")}]`);
  assert(result.codeLenA > 0 && result.codeLenA < 400, `code A is compact (${result.codeLenA} chars)`);
  assert(result.codeLenB > 0 && result.codeLenB < 400, `code B is compact (${result.codeLenB} chars)`);
  assert(result.roundTrip === "pong:ping", `message round-trips (${result.roundTrip})`);
  assert(
    result.connStates && result.connStates.every((s) => s === "connected"),
    `both peers reached connected (${result.connStates})`
  );

  await browser.close();
  if (failures) {
    console.error(`\n${failures} manual-pair test(s) FAILED`);
    process.exit(1);
  }
  console.log("\nall manual-pair tests passed");
};

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
