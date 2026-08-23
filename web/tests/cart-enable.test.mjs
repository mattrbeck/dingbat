// The cartridge top-bar buttons' "Enable" state (#cam-flip, #tilt-recenter)
// keys off genuine liveness, not a non-null handle: a MediaStream whose video
// track has ended is not live (iOS ends tracks on backgrounding), and tilt is
// on only once the orientation listener is attached.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

// A Game Boy Camera cart whose _wasm_camera_frame_ptr stays null, so the
// notice path stops before it needs a real 2D canvas.
const armCameraCart = (app, { hasCamera = 1 } = {}) =>
  app.runIn(`
    globalThis.Module = {
      _wasm_cart_has_camera: () => ${hasCamera},
      _wasm_camera_attach: () => 128 * 120,
      _wasm_camera_frame_ptr: () => 0,
    };
  `);

const liveStream = `{ getVideoTracks: () => [{ readyState: "live" }] }`;
const deadStream = `{ getVideoTracks: () => [{ readyState: "ended" }] }`;

const camBtn = (app) => app.elements.get("cam-flip");
const camLabel = (app) => app.elements.get("cam-flip-label");
const tiltBtn = (app) => app.elements.get("tilt-recenter");
const tiltLabel = (app) => app.elements.get("tilt-recenter-label");

// --- Which notice belongs in the viewfinder ---------------------------------

test("no camera yet points at the button that turns one on", async () => {
  const app = await loadApp();
  assert.equal(app.runIn("camNoticeFor()"), "prompt");
});

test("a live track means real frames, so no notice at all", async () => {
  const app = await loadApp();
  app.runIn(`camStream = ${liveStream};`);
  assert.equal(app.runIn("camNoticeFor()"), null);
});

test("a stream whose track ended is not live", async () => {
  const app = await loadApp();
  app.runIn(`camStream = ${deadStream}; camEnded = true;`);
  assert.equal(app.runIn("camNoticeFor()"), "ended");
});

test("a browser refusal outranks every softer explanation", async () => {
  const app = await loadApp();
  app.runIn("camEnded = true; camMissing = true; camDenied = true;");
  assert.equal(app.runIn("camNoticeFor()"), "blocked");
});

test("asked, allowed, and there was no camera to open", async () => {
  const app = await loadApp();
  app.runIn("camMissing = true;");
  assert.equal(app.runIn("camNoticeFor()"), "missing");
});

test("without getUserMedia the page itself is the problem", async () => {
  const app = await loadApp({ mediaDevices: false });
  app.runIn("camDenied = true;"); // even so: nothing here could have asked
  assert.equal(app.runIn("camNoticeFor()"), "insecure");
});

test("every notice is short lines of real text", async () => {
  const app = await loadApp();
  for (const kind of ["prompt", "blocked", "missing", "ended", "insecure"]) {
    for (const touch of [false, true]) {
      const lines = app.runIn(`camNoticeLines("${kind}", ${touch})`);
      assert.ok(Array.isArray(lines) && lines.length >= 2 && lines.length <= 5,
        `${kind}: expected 2-5 lines, got ${JSON.stringify(lines)}`);
      for (const l of lines) {
        assert.equal(typeof l, "string");
        // Longer text auto-shrinks below what the cart's dither matrix can
        // hold together; tools/cammsg.mjs measures this properly.
        assert.ok(l.length > 0 && l.length <= 14, `${kind}: "${l}" is too long`);
      }
    }
  }
});

// The notices that name the top-bar button take it from CAM_ENABLE_LABEL via
// the {label} placeholder; fails if one is renamed and not the other.
test("the notices quote the button's real label", async () => {
  const app = await loadApp();
  armCameraCart(app);
  app.runIn("camCartBtnUpdate()");
  const label = camLabel(app).textContent;
  assert.equal(label, app.runIn("CAM_ENABLE_LABEL"));
  assert.equal(camBtn(app).title, app.runIn("CAM_ENABLE_LABEL"));
  for (const kind of ["prompt", "ended"]) {
    const raw = app.runIn(`CAM_NOTICES["${kind}"]`);
    assert.ok(raw.includes("{label}"),
      `${kind} must name the button through {label}, not a literal: ${raw}`);
    for (const touch of [false, true]) {
      assert.ok(app.runIn(`camNoticeLines("${kind}", ${touch})`).includes(label),
        `${kind} should render the button's actual label`);
    }
  }
  for (const kind of ["prompt", "blocked", "missing", "ended", "insecure"]) {
    assert.ok(!app.runIn(`CAM_NOTICES["${kind}"]`).includes(label),
      `${kind} hardcodes "${label}" instead of using {label}`);
  }
});

// --- The camera button's two states -----------------------------------------

test("a camera cart with nothing attached offers Enable camera", async () => {
  const app = await loadApp();
  armCameraCart(app);
  app.runIn("camCartBtnUpdate()");
  assert.equal(camBtn(app).hidden, false);
  assert.equal(camLabel(app).textContent, "Enable camera");
  assert.equal(camBtn(app).title, "Enable camera");
  assert.equal(camBtn(app).getAttribute("aria-label"), "Enable camera");
  assert.ok(camBtn(app).classList.contains("needs-enable"),
    "the icon swap keys off .needs-enable — a phone shows no label at all");
});

test("with frames flowing it becomes the front/back switch", async () => {
  const app = await loadApp();
  armCameraCart(app);
  app.runIn(`camStream = ${liveStream}; camDevices = ["a", "b"];`);
  app.runIn("camCartBtnUpdate()");
  assert.equal(camBtn(app).hidden, false);
  assert.equal(camLabel(app).textContent, "Camera");
  assert.equal(camBtn(app).title, "Switch camera");
  assert.equal(camBtn(app).classList.contains("needs-enable"), false);
});

test("one camera is nothing to switch between, so the button goes", async () => {
  const app = await loadApp();
  armCameraCart(app);
  app.runIn(`camStream = ${liveStream}; camDevices = ["a"];`);
  app.runIn("camCartBtnUpdate()");
  assert.equal(camBtn(app).hidden, true);
});

test("a dead track re-arms Enable camera rather than leaving a flip control",
  async () => {
    const app = await loadApp();
    armCameraCart(app);
    app.runIn(`camStream = ${deadStream}; camDevices = ["a", "b"];`);
    app.runIn("camCartBtnUpdate()");
    assert.equal(camBtn(app).hidden, false);
    assert.equal(camLabel(app).textContent, "Enable camera");
    assert.ok(camBtn(app).classList.contains("needs-enable"));
  });

test("no getUserMedia, no Enable button — there would be nothing to enable",
  async () => {
    const app = await loadApp({ mediaDevices: false });
    armCameraCart(app);
    app.runIn("camCartBtnUpdate()");
    assert.equal(camBtn(app).hidden, true);
  });

test("a non-camera cart shows no camera button", async () => {
  const app = await loadApp();
  armCameraCart(app, { hasCamera: 0 });
  app.runIn("camCartBtnUpdate()");
  assert.equal(camBtn(app).hidden, true);
});

test("tapping the un-enabled button asks for the camera, not a switch",
  async () => {
    const app = await loadApp();
    armCameraCart(app);
    app.runIn("camCartBtnUpdate()");
    // Not awaited: the harness's getUserMedia never settles, which is what
    // lets the in-flight state be observed. camPending set proves the request
    // went out from the click itself, with no await before it (iOS requires this).
    camBtn(app).dispatch("click");
    await new Promise((r) => setImmediate(r));
    assert.equal(app.runIn("camPending"), true);
  });

// --- The tilt button's two states -------------------------------------------

const armTiltCart = (app) => app.runIn(`
  globalThis.DeviceOrientationEvent = class {};
  tiltActive = true; tiltKind = 1; tiltOrientationOn = false;
`);

test("a tilt cart on a phone offers Enable tilt", async () => {
  const app = await loadApp({ touch: true });
  armTiltCart(app);
  app.runIn("tiltCartBtnUpdate()");
  assert.equal(tiltBtn(app).hidden, false);
  assert.equal(tiltLabel(app).textContent, "Enable tilt");
  assert.equal(tiltBtn(app).title, "Enable tilt");
  assert.equal(tiltBtn(app).getAttribute("aria-label"), "Enable tilt");
  assert.ok(tiltBtn(app).classList.contains("needs-enable"));
});

test("no orientation sensor means no dead Enable-tilt button", async () => {
  const app = await loadApp({ touch: false });   // desktop: D-pad and stick
  armTiltCart(app);
  app.runIn("tiltCartBtnUpdate()");
  assert.equal(tiltBtn(app).hidden, true);
});

test("tapping Enable tilt attaches the listener and becomes Recenter",
  async () => {
    const app = await loadApp({ touch: true });
    armTiltCart(app);
    app.runIn("tiltCartBtnUpdate()");
    await tiltBtn(app).dispatch("click");
    assert.equal(app.runIn("tiltOrientationOn"), true,
      "the orientation listener is the real signal, not a flag we set hopefully");
    assert.ok((app.winListeners.deviceorientation || []).length > 0);
    assert.equal(tiltLabel(app).textContent, "Recenter");
    assert.equal(tiltBtn(app).title, "Recenter tilt");
    assert.equal(tiltBtn(app).classList.contains("needs-enable"), false);
    assert.equal(tiltBtn(app).hidden, false);
  });

test("once tilt is on, the same button recenters instead of re-enabling",
  async () => {
    const app = await loadApp({ touch: true });
    armTiltCart(app);
    app.runIn("tiltOrientationOn = true; tiltCartBtnUpdate();");
    app.runIn("tiltNeutral = { beta: 40, gamma: 0 };");
    await tiltBtn(app).dispatch("click");
    assert.equal(app.runIn("tiltNeutral"), null,
      "recentring drops the old neutral pose");
    assert.equal(app.toasts.at(-1), "Tilt recentered");
  });

test("a cart with no tilt hardware shows no tilt button", async () => {
  const app = await loadApp({ touch: true });
  armTiltCart(app);
  app.runIn("tiltActive = false; tiltCartBtnUpdate();");
  assert.equal(tiltBtn(app).hidden, true);
});
