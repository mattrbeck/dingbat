// The gamepad beyond the game's ten inputs: the triggers hold fast-forward
// and rewind, R3 / Guide / Select+Start held open the menu paused (closing
// it resumes), and away from the game view nothing the pad does reaches the
// core. Drives the real pollGamepads with a scripted pad.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

// Standard-mapping indices.
const A = 0, B = 1, LT = 6, RT = 7, BACK = 8, START = 9, R3 = 11, GUIDE = 16;
// Core input ids.
const CORE_A = 4, CORE_L = 8, CORE_R = 9;

const inGame = async () => {
  const app = await loadApp();
  app.runIn(`
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    document.body.classList.add("has-game", "running");
    menuDropdown.hidden = true; // as the markup has it (the fake DOM starts it shown)
    globalThis.setInputCalls = [];
    globalThis.Module = { _setInput: (id, d) => setInputCalls.push([id, d]) };
    globalThis.padDown = new Set();
    navigator.getGamepads = () => [{
      index: 0, id: "pad", mapping: "standard",
      buttons: Array.from({ length: 17 }, (_, i) => ({ pressed: padDown.has(i) })),
      axes: [0, 0],
    }];
    0`);
  return app;
};

const press = (app, ...bs) => app.runIn(`${bs.map((b) => `padDown.add(${b});`).join("")} pollGamepads()`);
const release = (app, ...bs) => app.runIn(`${bs.map((b) => `padDown.delete(${b});`).join("")} pollGamepads()`);
const sent = (app) => app.runIn("JSON.stringify(setInputCalls)");
const speed = (app) =>
  app.runIn(`fastForward ? "ffw" : speed2x ? "2x" : slowMotion ? "slow" : "normal"`);

test("RT holds fast-forward and gives the speed back; it is not R", async () => {
  const app = await inGame();
  await press(app, RT);
  assert.equal(speed(app), "ffw");
  await release(app, RT);
  assert.equal(speed(app), "normal");
  assert.ok(!JSON.parse(sent(app)).some(([id]) => id === CORE_R), "the trigger reached the core");
});

test("RT over a latched 2x returns to 2x", async () => {
  const app = await inGame();
  app.runIn("setSpeed2x(true)");
  await press(app, RT);
  assert.equal(speed(app), "ffw");
  await release(app, RT);
  assert.equal(speed(app), "2x");
});

test("LT holds rewind; it is not L", async () => {
  const app = await inGame();
  await press(app, LT);
  assert.equal(app.runIn("rewindHeld"), true);
  await release(app, LT);
  assert.equal(app.runIn("rewindHeld"), false);
  assert.ok(!JSON.parse(sent(app)).some(([id]) => id === CORE_L));
});

for (const [name, btn] of [["R3", R3], ["Guide", GUIDE]]) {
  test(`${name} opens the menu paused; B closes it and the game runs again`, async () => {
    const app = await inGame();
    await press(app, btn);
    assert.equal(app.runIn("menuDropdown.hidden"), false, "the menu opened");
    assert.equal(app.runIn("paused"), true, "the game paused under it");
    await release(app, btn);
    await press(app, B);
    assert.equal(app.runIn("menuDropdown.hidden"), true, "B closed it");
    await release(app, B);
    assert.equal(app.runIn("paused"), false, "back in the game, it runs");
    assert.ok(!JSON.parse(sent(app)).some(([id, d]) => id === 5 && d === 1),
              "the B that closed the menu is not the game's");
  });
}

test("the pad's menu leaves a game the player had paused paused", async () => {
  const app = await inGame();
  app.runIn("togglePause()");
  await press(app, R3);
  await release(app, R3);
  await press(app, B);
  await release(app, B);
  assert.equal(app.runIn("paused"), true);
});

test("Select+Start opens the menu only once held", async () => {
  const app = await inGame();
  await press(app, BACK, START);
  assert.equal(app.runIn("menuDropdown.hidden"), true, "a tap of the pair is the game's");
  app.runIn("padChordSince -= 600");
  await app.runIn("pollGamepads()");
  assert.equal(app.runIn("menuDropdown.hidden"), false);
  // What the game was holding is let go.
  const calls = JSON.parse(sent(app));
  assert.deepEqual(calls.slice(-2).sort(), [[6, 0], [7, 0]]);
});

test("a button held as the menu opens is released in the core", async () => {
  const app = await inGame();
  await press(app, A);
  assert.deepEqual(JSON.parse(sent(app)).at(-1), [CORE_A, 1]);
  await press(app, R3);
  assert.deepEqual(JSON.parse(sent(app)).at(-1), [CORE_A, 0]);
});

test("on the home screen the pad does not play the hidden game", async () => {
  const app = await inGame();
  app.runIn(`document.body.classList.remove("running")`);
  // (Start there is the hero's Resume, so not that one.)
  await press(app, A, BACK, RT);
  assert.equal(sent(app), "[]");
  assert.equal(speed(app), "normal");
});

test("in Settings, RB steps the section and B closes it; nothing reaches the core", async () => {
  const app = await inGame();
  app.runIn("openSettingsModal()");
  const first = app.runIn("settingsSection");
  await press(app, 5); // RB
  assert.notEqual(app.runIn("settingsSection"), first, "RB moved to the next section");
  await release(app, 5);
  await press(app, B);
  assert.equal(app.runIn(`settingsModal.classList.contains("open")`), false, "B closed Settings");
  assert.equal(sent(app), "[]");
});

test("a controller showing up is said: a toast and its name in Settings; going, the same", async () => {
  const app = await inGame();
  app.runIn(`
    globalThis.padList = [];
    navigator.getGamepads = () => padList;
    pollGamepads();`);
  assert.match(app.runIn("padStatusEl.textContent"), /press any button/);
  app.runIn(`padList = [{ index: 0, id: "Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e Product: 0b13)",
    mapping: "standard", buttons: Array.from({ length: 17 }, () => ({ pressed: false })), axes: [0, 0] }];
    pollGamepads();`);
  assert.ok(app.toasts.includes("Controller connected: Xbox Wireless Controller"));
  assert.equal(app.runIn("padStatusEl.textContent"), "Connected: Xbox Wireless Controller");
  // Polled every frame, said once.
  app.runIn("pollGamepads(); pollGamepads()");
  assert.equal(app.toasts.filter((t) => t.startsWith("Controller connected")).length, 1);
  app.runIn("padList = []; pollGamepads()");
  assert.ok(app.toasts.includes("Controller disconnected: Xbox Wireless Controller"));
  assert.match(app.runIn("padStatusEl.textContent"), /press any button/);
});

test("Settings shows the buttons held, by the browser's numbers", async () => {
  const app = await inGame();
  app.runIn("openSettingsModal()");
  await press(app, BACK, START);
  assert.equal(app.runIn("padTestEl.textContent"), "holding 8 (Select), 9 (Start)");
  assert.equal(app.runIn("padTestEl.hidden"), false);
  await release(app, BACK, START);
  assert.equal(app.runIn("padTestEl.textContent"), "press a button to test it");
});

test("a pad without the standard layout never rewinds or fast-forwards from 6 and 7", async () => {
  const app = await inGame();
  // An SNES-style pad: Select and Start come as 6 and 7.
  app.runIn(`navigator.getGamepads = () => [{ index: 0, id: "USB Gamepad", mapping: "",
    buttons: Array.from({ length: 12 }, (_, i) => ({ pressed: padDown.has(i) })), axes: [0, 0] }];`);
  await press(app, LT, RT);
  assert.equal(app.runIn("rewindHeld"), false);
  assert.equal(speed(app), "normal");
  await press(app, R3);
  assert.equal(app.runIn("menuDropdown.hidden"), true);
});

test("a pad without the standard layout says so", async () => {
  const app = await inGame();
  app.runIn(`navigator.getGamepads = () => [{ index: 0, id: "054c-0ce6-Wireless Controller", mapping: "",
    buttons: Array.from({ length: 17 }, () => ({ pressed: false })), axes: [0, 0] }];
    pollGamepads();`);
  assert.ok(app.toasts.some((t) => t.startsWith("Controller connected: Wireless Controller (no standard layout")));
});

test("on the home screen a bound key is the page's, not the core's", async () => {
  const app = await inGame();
  app.runIn(`document.body.classList.remove("running")`);
  const code = app.runIn("Object.keys(codeLookup)[0]");
  await app.dispatchDoc("keydown", { code, target: app.document.body, repeat: false });
  assert.equal(sent(app), "[]");
});
