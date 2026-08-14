// The input-display overlay (Settings -> Controls -> "Show inputs on screen",
// or the I key): a DOM controller over the stage that lights each button while
// it is held, for stream viewers and for debugging.
//
// The thing worth guarding is the CHOKEPOINT. Keyboard, touch and gamepad
// reach the core by three different routes, and the overlay is only ever
// trustworthy if all three notify it — an overlay that agrees with the core
// for two sources out of three is worse than no overlay, because it looks
// authoritative while dropping presses. So these tests drive the REAL entry
// points (a synthetic keydown through the document handler, setInputs as the
// touch buttons call it, routeP1Input) and assert on the cells, never on a
// convenience function invented for the test.
//
// The harness is node:vm with a fake DOM, so nothing here asserts on pixels —
// only on which cell carries the lit class, and on what was persisted.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadApp, settle, eq } from "./helpers.mjs";

// Core input ids, in the order setInput uses (src/dingbat_wasm.nim).
const UP = 0, DOWN = 1, LEFT = 2, RIGHT = 3, A = 4, B = 5, SELECT = 6,
      START = 7, L = 8, R = 9;

const CELL = ["io-up", "io-down", "io-left", "io-right", "io-a", "io-b",
              "io-select", "io-start", "io-l", "io-r"];

const boot = async ({ on = true } = {}) => {
  const app = await loadApp();
  // A core has to look present or gameKeyHandler declines to route anything.
  app.runIn(`globalThis.setInputCalls = [];
             globalThis.Module = { _setInput: (id, d) => setInputCalls.push([id, d]) };`);
  if (on) await app.runIn("setInputDisplay(true)");
  await settle();
  return app;
};

const lit = (app) =>
  CELL.map((id, i) => [i, app.document.getElementById(id)])
      .filter(([, el]) => el.classList.contains("io-on"))
      .map(([i]) => i);

test("a press lights exactly its own cell, and the release puts it out", async () => {
  const app = await boot();
  app.runIn(`routeP1Input(${A}, true)`);
  assert.deepEqual(lit(app), [A]);
  app.runIn(`routeP1Input(${A}, false)`);
  assert.deepEqual(lit(app), []);
});

test("the keyboard path lights the overlay — the same event that reaches the core", async () => {
  const app = await boot();
  // The real handler, via the real document listener: KeyZ is the default
  // binding for A, so this is what a player pressing Z actually produces.
  await app.dispatchDoc("keydown", { code: "KeyZ", target: app.document.body });
  assert.deepEqual(lit(app), [A]);
  eq(app.runIn("setInputCalls"), [[A, 1]],
     "the core and the overlay must have been told the same thing");
  await app.dispatchDoc("keyup", { code: "KeyZ", target: app.document.body });
  assert.deepEqual(lit(app), []);
});

test("held-key repeats do not churn, and the cell stays lit", async () => {
  const app = await boot();
  for (let i = 0; i < 3; i++)
    await app.dispatchDoc("keydown", { code: "ArrowLeft", repeat: i > 0,
                                       target: app.document.body });
  assert.deepEqual(lit(app), [LEFT]);
});

test("the touch path lights the overlay too (setInputs, as the buttons call it)", async () => {
  const app = await boot();
  // A diagonal touch cell carries two ids; both arms have to light.
  app.runIn(`setInputs([${UP}, ${LEFT}], true)`);
  assert.deepEqual(lit(app), [UP, LEFT]);
  app.runIn(`setInputs([${UP}, ${LEFT}], false)`);
  assert.deepEqual(lit(app), []);
});

test("the gamepad path lights the overlay (it never touches routeP1Input)", async () => {
  const app = await boot();
  // Standard-mapping indices: 9 = Start, 5 = RB -> R shoulder.
  app.runIn(`
    globalThis.padDown = new Set();
    navigator.getGamepads = () => [{
      buttons: Array.from({ length: 16 }, (_, i) => ({ pressed: padDown.has(i) })),
      axes: [0, 0],
    }];`);
  app.runIn("padDown.add(9); padDown.add(5); pollGamepads()");
  assert.deepEqual(lit(app), [START, R]);
  app.runIn("padDown.clear(); pollGamepads()");
  assert.deepEqual(lit(app), [],
                   "a pad release has to put the cell out as surely as a keyup");
});

test("the analog stick lights the d-pad, the same way it feeds the core", async () => {
  const app = await boot();
  app.runIn(`
    globalThis.padAxes = [0, 0];
    navigator.getGamepads = () => [{
      buttons: Array.from({ length: 16 }, () => ({ pressed: false })),
      get axes() { return padAxes; },
    }];`);
  app.runIn("padAxes = [-1, 0]; pollGamepads()");
  assert.deepEqual(lit(app), [LEFT]);
});

test("several buttons light at once", async () => {
  const app = await boot();
  for (const id of [RIGHT, B, START, R]) app.runIn(`routeP1Input(${id}, true)`);
  assert.deepEqual(lit(app), [RIGHT, B, START, R]);
});

test("with the overlay off nothing lights, but switching it on mid-hold is honest", async () => {
  const app = await boot({ on: false });
  app.runIn(`routeP1Input(${START}, true)`);
  assert.deepEqual(lit(app), [], "off means off");
  await app.runIn("setInputDisplay(true)");
  // Deliberate: a toggle clears rather than back-fills. The alternative is a
  // cell that lights for a button whose keyup already went missing, and a
  // stuck-on cell is the one failure a viewer would notice.
  assert.deepEqual(lit(app), []);
  app.runIn(`routeP1Input(${START}, false)`);
  app.runIn(`routeP1Input(${START}, true)`);
  assert.deepEqual(lit(app), [START]);
});

test("switching the overlay off puts every lit cell out", async () => {
  const app = await boot();
  app.runIn(`routeP1Input(${B}, true)`);
  await app.runIn("setInputDisplay(false)");
  assert.deepEqual(lit(app), []);
});

test("a window blur clears the lights — the keyup never arrives", async () => {
  const app = await boot();
  app.runIn(`routeP1Input(${DOWN}, true)`);
  assert.deepEqual(lit(app), [DOWN]);
  await app.dispatchWin("blur");
  assert.deepEqual(lit(app), [],
                   "otherwise alt-tabbing leaves a direction stuck on forever");
});

test("the I shortcut toggles the setting and persists it", async () => {
  const app = await boot({ on: false });
  await app.dispatchDoc("keydown", { code: "KeyI", target: app.document.body });
  await settle();
  assert.equal(app.runIn("inputDisplay"), true);
  assert.equal(app.document.getElementById("input-display-toggle").checked, true);
  assert.equal(await app.api.dbGet("input-display"), true, "it has to survive a reload");

  await app.dispatchDoc("keydown", { code: "KeyI", target: app.document.body });
  await settle();
  assert.equal(app.runIn("inputDisplay"), false);
  assert.equal(await app.api.dbGet("input-display"), false);
});

test("a game key bound to I still wins over the shortcut", async () => {
  const app = await boot({ on: false });
  // 105 == SDL keycode for 'i'. Rebinding A to I makes KeyI a game key, and a
  // game key must never be eaten by a shortcut (the rule the whole shortcut
  // handler opens with).
  const bindings = app.runIn("activeBindings.slice()");
  bindings[A] = 105;
  app.runIn(`applyKeybindings(${JSON.stringify(Array.from(bindings))})`);
  await app.dispatchDoc("keydown", { code: "KeyI", target: app.document.body });
  await settle();
  assert.equal(app.runIn("inputDisplay"), false, "the shortcut must have stood down");
  eq(app.runIn("setInputCalls"), [[A, 1]]);
});

test("the switch persists, and a stored value comes back on boot", async () => {
  const app = await loadApp();
  const el = app.document.getElementById("input-display-toggle");
  el.checked = true;
  await el.dispatch("change");
  await settle();
  assert.equal(app.runIn("inputDisplay"), true);
  assert.equal(await app.api.dbGet("input-display"), true);

  const app2 = await loadApp();
  await app2.api.dbPut("input-display", true);
  await app2.runIn("loadInputDisplayFromStorage()");
  await settle();
  assert.equal(app2.runIn("inputDisplay"), true);
  assert.equal(app2.document.getElementById("input-display-toggle").checked, true);
});

test("a fresh install has it off", async () => {
  const app = await loadApp();
  await app.runIn("loadInputDisplayFromStorage()");
  await settle();
  assert.equal(app.runIn("inputDisplay"), false,
               "an overlay nobody asked for must not appear over the game");
});

test("Reset all settings turns it back off and forgets the key", async () => {
  const app = await boot();
  assert.ok(app.runIn('SETTINGS_KEYS.includes("input-display")'),
            "otherwise Reset leaves the record behind and it returns on reload");
  await app.runIn("resetAllSettings()");
  await settle();
  assert.equal(app.runIn("inputDisplay"), false);
  assert.equal(await app.api.dbGet("input-display") ?? null, null);
});

test("the markup carries every cell the code looks up, and the L/R row is gated", async () => {
  // The fake DOM invents an element for any id asked of it, so a typo'd id
  // would go unnoticed here forever. Read the real HTML/CSS instead.
  const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  for (const id of CELL)
    assert.ok(html.includes(`id="${id}"`), `#${id} is missing from index.html`);
  assert.match(html, /<input type="checkbox" id="input-display-toggle"/);

  const css = readFileSync(new URL("../styles.css", import.meta.url), "utf8");
  assert.match(css, /body\.gb-mode #io-shoulders/,
               "GB/GBC has no shoulder buttons — the row must be gated off");
  assert.match(css, /body\.link-mode #input-overlay\.on\s*\{\s*display:\s*none/,
               "one overlay cannot speak for two linked consoles");
});
