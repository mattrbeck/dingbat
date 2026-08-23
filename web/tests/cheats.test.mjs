// Cheats modal add/validate UX (web/index.js), via the vm harness. The fake
// core mirrors load_cheats' contract: takes the serialized ".cht" blob,
// returns "" or newline-separated `name: "line": message` errors, one per
// failed cheat, first bad line wins. A line is valid iff it is 8+8 hex.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle } from "./helpers.mjs";

const GOOD = "32001234 00000063";
const GOOD2 = "82003FE4 00000005";

const fakeCore = () => {
  const calls = [];
  return {
    calls,
    ccall: (fn, _ret, _types, args) => {
      if (fn !== "load_cheats") return "";
      const text = String(args[0]);
      calls.push(text);
      const errs = [];
      let name = "?";
      let failed = false;
      for (const raw of text.split("\n")) {
        const line = raw.trim();
        if (!line) continue;
        if (line.length >= 3 && line[0] === "[" && line[2] === "]") {
          name = line.slice(3).trim() || "?";
          failed = false;
          continue;
        }
        if (failed) continue;
        if (!/^[0-9A-Fa-f]{8} [0-9A-Fa-f]{8}$/.test(line)) {
          errs.push(name + ': "' + line + '": GBA code must be 8+8 hex');
          failed = true;
        }
      }
      return errs.join("\n");
    },
  };
};

const setup = async () => {
  const app = await loadApp();
  const core = fakeCore();
  app.sandbox.Module = core;
  app.api.currentOriginalName = "game.gba";
  const el = (id) => app.document.getElementById(id);
  // The real markup ships `<p id="cheat-error" hidden>`; the fake DOM
  // defaults to hidden=false.
  el("cheat-error").hidden = true;
  const add = async (name, codes) => {
    el("cheat-name").value = name;
    el("cheat-codes").value = codes;
    await el("cheat-add").dispatch("click");
    await settle();
  };
  return { app, core, el, add };
};

test("valid add inserts an enabled cheat, clears the form, persists", async () => {
  const { app, core, el, add } = await setup();
  await add("Rare Candy", GOOD);
  assert.equal(app.api.cheatList.length, 1);
  assert.equal(app.api.cheatList[0].name, "Rare Candy");
  assert.equal(app.api.cheatList[0].enabled, true);
  assert.equal(app.api.cheatList[0].error, "");
  assert.equal(el("cheat-error").hidden, true);
  assert.equal(el("cheat-name").value, "");
  assert.equal(el("cheat-codes").value, "");
  assert.match(String(app.idb.get("cheats:game.gba")), /Rare Candy/);
  assert.equal(core.calls[core.calls.length - 1],
    app.api.serializeCheats(app.api.cheatList));
});

test("invalid add is rejected: no insert, error at form, text kept, core restored", async () => {
  const { app, core, el, add } = await setup();
  await add("", "NOTACODE");
  assert.equal(app.api.cheatList.length, 0);
  assert.equal(app.idb.has("cheats:game.gba"), false);
  assert.equal(el("cheat-error").hidden, false);
  assert.match(el("cheat-error").textContent, /NOTACODE/);
  assert.equal(el("cheat-codes").getAttribute("aria-invalid"), "true");
  assert.equal(el("cheat-codes").value, "NOTACODE");
  // The probe replaced the core's set, so the real list must be re-pushed.
  assert.equal(core.calls[core.calls.length - 1], "");
});

test("a multi-line add mixing valid and invalid lines is rejected as a whole", async () => {
  const { app, el, add } = await setup();
  await add("Mixed", GOOD + "\nNOTACODE");
  assert.equal(app.api.cheatList.length, 0,
    "per-cheat parsing is all-or-nothing: one bad line rejects the whole add");
  assert.equal(el("cheat-error").hidden, false);
  assert.match(el("cheat-error").textContent, /NOTACODE/);
});

test("editing either input clears the form error", async () => {
  const { el, add } = await setup();
  await add("", "NOTACODE");
  assert.equal(el("cheat-error").hidden, false);
  await el("cheat-codes").dispatch("input");
  assert.equal(el("cheat-error").hidden, true);
  assert.equal(el("cheat-codes").getAttribute("aria-invalid"), null);
  await add("", "NOTACODE");
  assert.equal(el("cheat-error").hidden, false);
  await el("cheat-name").dispatch("input");
  assert.equal(el("cheat-error").hidden, true);
});

test("the next successful add clears a previous error", async () => {
  const { app, el, add } = await setup();
  await add("", "NOTACODE");
  assert.equal(el("cheat-error").hidden, false);
  await add("Fixed", GOOD);
  assert.equal(el("cheat-error").hidden, true);
  assert.equal(app.api.cheatList.length, 1);
  assert.equal(app.api.cheatList[0].name, "Fixed");
});

test("restoreCheats badges legacy entries that no longer parse", async () => {
  const { app, el } = await setup();
  app.idb.set("cheats:game.gba",
    "[x] Good\n" + GOOD + "\n\n[x] Broken\nNOTACODE\n\n");
  await app.api.restoreCheats();
  const list = app.api.cheatList;
  assert.equal(list.length, 2);
  assert.equal(list[0].error, "");
  assert.match(list[1].error, /NOTACODE/);
  // Rendered rows: [checkbox, info, delete].
  const rows = el("cheats-list").children;
  assert.equal(rows.length, 2);
  assert.equal(rows[0].classList.contains("cheat-row-invalid"), false);
  assert.equal(rows[0].children[0].disabled, false);
  assert.equal(rows[1].classList.contains("cheat-row-invalid"), true);
  assert.equal(rows[1].children[0].disabled, true);
  assert.equal(rows[1].children[0].checked, false);
  const badge = rows[1].children[1].children[0].children[0];
  assert.equal(badge.className, "cheat-badge-invalid");
  assert.equal(badge.textContent, "Invalid");
  assert.match(badge.title, /NOTACODE/);
});

test("list operations never route errors into the add form", async () => {
  const { app, el, add } = await setup();
  app.idb.set("cheats:game.gba",
    "[x] Good\n" + GOOD + "\n\n[x] Broken\nNOTACODE\n\n");
  await app.api.restoreCheats();
  assert.equal(el("cheat-error").hidden, true,
    "restoring a legacy broken entry must not light up the add form");
  // The pushed blob still contains the broken legacy entry; its error must
  // not land in the add form.
  const cb = el("cheats-list").children[0].children[0];
  cb.checked = false;
  await cb.dispatch("change");
  await settle();
  assert.equal(el("cheat-error").hidden, true);
  // A live form error survives list operations.
  await add("", "NOTACODE");
  assert.equal(el("cheat-error").hidden, false);
  const cb2 = el("cheats-list").children[0].children[0];
  cb2.checked = true;
  await cb2.dispatch("change");
  await settle();
  assert.equal(el("cheat-error").hidden, false);
  assert.equal(el("cheat-codes").value, "NOTACODE");
});

test("deleting a legacy invalid entry drops it for good", async () => {
  const { app, el } = await setup();
  app.idb.set("cheats:game.gba",
    "[x] Good\n" + GOOD + "\n\n[x] Broken\nNOTACODE\n\n[x] Also good\n" + GOOD2 + "\n\n");
  await app.api.restoreCheats();
  const delBtn = el("cheats-list").children[1].children[2];
  await delBtn.dispatch("click");
  await settle();
  assert.equal(app.api.cheatList.length, 2);
  assert.equal(app.api.cheatList.every((c) => !c.error), true);
  assert.doesNotMatch(String(app.idb.get("cheats:game.gba")), /NOTACODE/);
});
