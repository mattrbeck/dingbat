// The save webhook's URL (Settings > General > Advanced) syncs across a
// Drive account's devices in its own Drive file: the newest change wins.

import test from "node:test";
import { loadApp, settle, eq } from "./helpers.mjs";
import { makeDrive, makeClock, useClock } from "./drivefake.mjs";

const device = async (drive, clock) => {
  const app = await loadApp();
  useClock(app, clock);
  app.setFetch(drive.fetch);
  app.api.gdriveToken = "tok";
  app.api.gdriveTokenExp = clock.peek() + 3600e3;
  app.api.syncState = {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], delTs: {},
    sigs: {}, rmt: {}, acct: "a1", parked: {}, connected: true, email: "e@x",
  };
  return app;
};
const onDrive = (drive) => JSON.parse(new TextDecoder().decode(drive.get("save-hook").bytes));
const set = async (app, url) => { await app.api.setSaveHookUrl(url); await app.api.pullSync(); await settle(); };

test("a URL set on one device reaches the other, and so does clearing it", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);

  await set(d0, "http://localhost:9000/hook");
  eq(onDrive(drive).url, "http://localhost:9000/hook", "on Drive");
  eq(d0.api.saveHook.dirty, false, "and no longer pending");

  await d1.api.pullSync();
  await settle();
  eq(d1.api.saveHook.url, "http://localhost:9000/hook", "the other device has it");
  eq(d1.idb.get("save-hook").url, "http://localhost:9000/hook", "kept across reloads");

  await set(d1, "");
  await d0.api.pullSync();
  await settle();
  eq(d0.api.saveHook.url, "", "cleared on the first device too");
});

test("a change made offline loses to a newer one from another device", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);

  d0.api.gdriveToken = null;                       // d0 offline: kept, not sent
  await d0.api.setSaveHookUrl("http://old.example/hook");
  eq(d0.api.saveHook.dirty, true);
  await set(d1, "http://new.example/hook");        // later, on d1

  d0.api.gdriveToken = "tok";
  await d0.api.pullSync();
  await settle();
  eq(d0.api.saveHook.url, "http://new.example/hook", "the newer change wins");
  eq(onDrive(drive).url, "http://new.example/hook", "and the older one is not sent over it");
  eq(drive.named("save-hook").length, 1);
});

test("an older build ignores the file (not a game file)", async () => {
  const app = await loadApp();
  eq(app.api.parseDriveFileName(app.api.SAVE_HOOK_FILE), null);
});
