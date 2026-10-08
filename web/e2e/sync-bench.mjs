// How long a sync takes, and which Drive requests it spends that time on.
// One device holds a library of GAMES games (ROMs, battery saves, a Resume
// snapshot, a picture, a save-state slot each), seeded straight into its
// IndexedDB; every Drive request takes DINGBAT_E2E_DRIVE_MS (a phone's round
// trip to Google is ~100-300 ms). Then:
//   1. Sync now with nothing changed
//   2. Sync now after one battery save changed
//   3. a second device holding the same ROMs opens and pulls everything
//
// Run: DINGBAT_E2E_DRIVE_MS=150 node e2e/sync-bench.mjs [games] [kind]

import { startRig, idle } from "./devices.mjs";

const GAMES = Number(process.argv[2] || 20);
const KIND = process.argv[3] || "mac";
const LAG = Number(process.env.DINGBAT_E2E_DRIVE_MS || 0);

const seed = (page, games) => page.evaluate(async (games) => {
  const rnd = (n, s) => {
    const b = new Uint8Array(n);
    let x = s * 2654435761 >>> 0;
    for (let i = 0; i < n; i += 4) { x = (x * 1103515245 + 12345) >>> 0; b[i] = x >>> 24; }
    return b;
  };
  const recent = [];
  for (let i = 0; i < games; i++) {
    const gba = i % 2 === 0;
    const name = `Game ${i}.${gba ? "gba" : "gbc"}`;
    recent.push({ name, ts: 1000 + i });
    await dbPut("rom:" + name, { name, data: rnd(gba ? 8 << 20 : 1 << 20, i) });
    const save = rnd(gba ? 128 << 10 : 32 << 10, i + 100);
    await dbPut("save:" + name, save);
    await dbPut("stateauto:" + name, { bytes: rnd(55 << 10, i + 200), ts: 5000 + i,
      saveSig: saveSignature(save), by: deviceId, dev: deviceLabel });
    await dbPut("frame:" + name, new Blob([rnd(20 << 10, i + 300)], { type: "image/jpeg" }));
    await dbPut("state:" + name, rnd(55 << 10, i + 400));
    await dbPut("statemeta:" + name, { thumb: "data:image/webp;base64,AAAA", ts: 6000 + i });
  }
  await dbPut("recent", recent);
}, games);

const timed = async (d, drive, label, fn) => {
  const before = drive.log.length;
  const ms = await d.page.evaluate(fn);
  await idle(d);
  const reqs = drive.log.slice(before);
  const kinds = {};
  for (const r of reqs) {
    const what = r.method === "GET" && r.path.endsWith("/files") ? "list"
      : r.method === "GET" ? "download" : r.method === "DELETE" ? "delete" : "upload";
    kinds[what] = (kinds[what] || 0) + 1;
  }
  console.log(`${label}: ${(ms / 1000).toFixed(2)} s, ${reqs.length} requests ` +
              JSON.stringify(kinds));
  return { ms, reqs };
};

const fullSync = async () => {
  const t = performance.now();
  await runFullSync();
  return performance.now() - t;
};

const rig = await startRig();
try {
  const drive = rig.drive();
  console.log(`${GAMES} games on ${KIND}, ${LAG} ms a Drive request`);
  const a = await rig.device(drive, "A", KIND);
  await seed(a.page, GAMES);
  await timed(a, drive, "first Sync now (uploads everything)", fullSync);
  await timed(a, drive, "Sync now, nothing changed", fullSync);
  await a.page.evaluate(() => dbPut("save:Game 3.gbc", new Uint8Array(32 << 10).fill(7)));
  await timed(a, drive, "Sync now, one save changed", fullSync);

  const b = await rig.device(drive, "B", KIND);   // pulls on its own when it opens
  await b.page.evaluate(async (games) => {
    for (let i = 0; i < games; i++) {
      const name = `Game ${i}.${i % 2 === 0 ? "gba" : "gbc"}`;
      await dbPut("rom:" + name, { name, data: new Uint8Array(16) });
    }
  }, GAMES);
  await timed(b, drive, "second device, Sync now (pulls every save)", fullSync);
  await rig.endTest();
} finally {
  await rig.close();
}
