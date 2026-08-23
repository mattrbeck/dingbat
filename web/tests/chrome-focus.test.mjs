// After a pointer-activated top-bar control, focus returns to the game
// surface (else the next keystroke walks the top bar). Keyboard activation
// must keep focus, or a keyboard user lands at the top of the tab order.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

// Real clicks usually hit the button's inner <svg>; the handler resolves the
// control through closest(), so `target` is a descendant of `ctl`.
const chromeTarget = ({ inTopbar = true, inModal = false, tag = "BUTTON" } = {}) => {
  const ctl = { tagName: tag, blurs: 0, blur() { ctl.blurs++; } };
  const target = {
    tagName: "svg",
    closest(sel) {
      if (sel.includes(".modal-overlay")) return inModal ? { tagName: "DIV" } : null;
      if (sel.includes("#topbar")) return inTopbar ? { tagName: "HEADER" } : null;
      return ctl; // the "button, [href], [tabindex]" control lookup
    },
  };
  return { ctl, target };
};

const watchCanvas = (app) => {
  const canvas = app.elements.get("canvas");
  const focuses = [];
  canvas.focus = (opts) => { focuses.push(opts); };
  return focuses;
};

test("a mouse click on a top-bar control hands focus back to the game", async () => {
  const app = await loadApp();
  const focuses = watchCanvas(app);
  const { ctl, target } = chromeTarget();

  await app.dispatchDoc("click", { target, detail: 1 });

  assert.equal(ctl.blurs, 1, "the button gives up focus");
  assert.equal(focuses.length, 1, "and the game surface takes it");
  assert.deepEqual({ ...focuses[0] }, { preventScroll: true },
    "without scrolling the library out from under the user");
});

test("keyboard activation (Enter/Space) keeps focus on the button", async () => {
  const app = await loadApp();
  const focuses = watchCanvas(app);
  const { ctl, target } = chromeTarget();

  // A click synthesised by Enter/Space (or el.click()) reports detail 0.
  await app.dispatchDoc("click", { target, detail: 0 });

  assert.equal(ctl.blurs, 0, "the focus ring stays where the keyboard user put it");
  assert.equal(focuses.length, 0);
});

test("controls outside the main chrome are left alone", async () => {
  const app = await loadApp();
  const focuses = watchCanvas(app);
  const { ctl, target } = chromeTarget({ inTopbar: false });

  await app.dispatchDoc("click", { target, detail: 1 });

  assert.equal(ctl.blurs, 0, "home-screen / stage controls keep their focus");
  assert.equal(focuses.length, 0);
});

test("a control inside an open modal keeps focus (the modal owns its trap)", async () => {
  const app = await loadApp();
  const focuses = watchCanvas(app);
  const { ctl, target } = chromeTarget({ inModal: true });

  await app.dispatchDoc("click", { target, detail: 1 });

  assert.equal(ctl.blurs, 0);
  assert.equal(focuses.length, 0);
});

test("text fields and sliders keep focus so typing still works", async () => {
  const app = await loadApp();
  const focuses = watchCanvas(app);

  for (const tag of ["INPUT", "TEXTAREA", "SELECT"]) {
    const { ctl, target } = chromeTarget({ tag });
    await app.dispatchDoc("click", { target, detail: 1 });
    assert.equal(ctl.blurs, 0, tag + " must stay focused");
  }
  assert.equal(focuses.length, 0);
});
