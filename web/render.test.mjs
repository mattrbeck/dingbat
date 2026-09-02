// WebGL2 readback guard: compiles the shipped present shaders (via
// glshaders.mjs) in headless Chromium, uploads a corner-distinguishable
// 240x160 pattern exactly as glRenderer.draw() does (R16UI BGR555), and
// asserts each canvas corner shows the right source corner. Catches quadrant
// sampling, Y-flips, scale errors and wrong upload dims. Needs WebGL2
// (GLSL ES 300, usampler2D), so Playwright's Chromium, not headless-gl.
//
// Pattern (texture row 0 = top): TL red, TR green, BL blue, BR white,
// center yellow. A PNG of the filter=none render is written to the temp dir.
//
// Run:  node web/render.test.mjs   (after: npx playwright install chromium)

import { writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readShaders } from "./glshaders.mjs";

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

let failures = 0;
function assert(cond, msg) {
  if (cond) { console.log(`  ok: ${msg}`); return; }
  failures++;
  console.error(`  FAIL: ${msg}`);
}

// BGR555 pattern, the core's raw framebuffer format.
const NW = 240, NH = 160;                 // native GBA resolution
const CW = 480, CH = 320;                 // canvas: 2x, so scaling is exercised
const RED = 0x001f, GREEN = 0x03e0, BLUE = 0x7c00, WHITE = 0x7fff, YELLOW = 0x03ff;

function buildPattern() {
  const px = new Uint16Array(NW * NH);
  const hx = NW >> 1, hy = NH >> 1;
  for (let y = 0; y < NH; y++) {
    for (let x = 0; x < NW; x++) {
      const top = y < hy, left = x < hx;
      px[y * NW + x] = top ? (left ? RED : GREEN) : (left ? BLUE : WHITE);
    }
  }
  for (let y = hy - 12; y < hy + 12; y++)
    for (let x = hx - 12; x < hx + 12; x++)
      px[y * NW + x] = YELLOW;
  return Array.from(px); // Playwright serializes plain arrays reliably
}

// Runs inside the page. Returns corner/center RGBA samples (canvas top-left
// origin) and, when asked, a PNG data URL.
function renderInPage(cfg) {
  const { VERT, FRAG, cw, ch, nw, nh, pattern, opts, wantPng } = cfg;
  const canvas = document.getElementById("c");
  canvas.width = cw; canvas.height = ch;
  const gl = canvas.getContext("webgl2", {
    alpha: false, antialias: false, depth: false, stencil: false,
    preserveDrawingBuffer: true, premultipliedAlpha: false,
  });
  if (!gl) return { error: "WebGL2 unavailable in this browser" };

  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS))
      throw new Error("compile: " + gl.getShaderInfoLog(s));
    return s;
  };
  const prog = gl.createProgram();
  gl.attachShader(prog, compile(gl.VERTEX_SHADER, VERT));
  gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS))
    throw new Error("link: " + gl.getProgramInfoLog(prog));

  // Same upload as glRenderer.draw().
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 2);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16UI, nw, nh, 0,
    gl.RED_INTEGER, gl.UNSIGNED_SHORT, new Uint16Array(pattern));

  gl.viewport(0, 0, cw, ch);
  gl.useProgram(prog);
  gl.uniform1i(gl.getUniformLocation(prog, "u_color_correct"), opts.colorCorrect ? 1 : 0);
  gl.uniform1i(gl.getUniformLocation(prog, "u_panel_gbc"), opts.panelGbc ? 1 : 0);
  gl.uniform1i(gl.getUniformLocation(prog, "u_grid"), opts.grid ? 1 : 0);
  gl.uniform1i(gl.getUniformLocation(prog, "u_subpixel"), opts.subpixel ? 1 : 0);
  gl.uniform1f(gl.getUniformLocation(prog, "u_scan_width"), nw);
  gl.uniform1f(gl.getUniformLocation(prog, "u_tex_height"), nh);
  gl.uniform2f(gl.getUniformLocation(prog, "u_tex_size"), nw, nh);
  gl.uniform1i(gl.getUniformLocation(prog, "u_filter"),
    opts.filter === "hq4x" ? 1 : opts.filter === "xbr" ? 2 : 0);
  gl.drawArrays(gl.TRIANGLES, 0, 3);

  // readPixels row 0 is the bottom row; samples are given top-left origin.
  const buf = new Uint8Array(cw * ch * 4);
  gl.readPixels(0, 0, cw, ch, gl.RGBA, gl.UNSIGNED_BYTE, buf);
  const sample = (fx, fy) => {
    const x = Math.min(cw - 1, Math.max(0, Math.round(fx * (cw - 1))));
    const topRow = Math.min(ch - 1, Math.max(0, Math.round(fy * (ch - 1))));
    const glRow = ch - 1 - topRow;
    const i = (glRow * cw + x) * 4;
    return [buf[i], buf[i + 1], buf[i + 2], buf[i + 3]];
  };
  const out = {
    topLeft: sample(0, 0), topRight: sample(1, 0),
    bottomLeft: sample(0, 1), bottomRight: sample(1, 1),
    center: sample(0.5, 0.5),
    q_tl: sample(0.25, 0.25), q_tr: sample(0.75, 0.25),
    q_bl: sample(0.25, 0.75), q_br: sample(0.75, 0.75),
  };
  if (wantPng) out.png = canvas.toDataURL("image/png");
  return out;
}

const isRed = (p) => p[0] > 200 && p[1] < 55 && p[2] < 55;
const isGreen = (p) => p[1] > 200 && p[0] < 55 && p[2] < 55;
const isBlue = (p) => p[2] > 200 && p[0] < 55 && p[1] < 55;
const isWhite = (p) => p[0] > 200 && p[1] > 200 && p[2] > 200;
const isYellow = (p) => p[0] > 200 && p[1] > 200 && p[2] < 55;
const nonBlack = (p) => Math.max(p[0], p[1], p[2]) > 40;
const distinct = (a, b) =>
  Math.abs(a[0] - b[0]) + Math.abs(a[1] - b[1]) + Math.abs(a[2] - b[2]) > 40;

async function run() {
  const { VERT, FRAG } = readShaders();
  const pattern = buildPattern();
  const browser = await chromium.launch({ args: ["--enable-unsafe-swiftshader"] });
  const page = await browser.newPage();
  await page.setContent("<!doctype html><canvas id=c></canvas>");
  page.on("console", (m) => { if (m.type() === "error") console.error("  [page] " + m.text()); });

  const render = (opts, wantPng = false) =>
    page.evaluate(renderInPage,
      { VERT, FRAG, cw: CW, ch: CH, nw: NW, nh: NH, pattern, opts, wantPng });

  try {
    // filter=none, color-correct off, grid off: the mapping is pure, so
    // corners must be exactly the source corners.
    console.log("filter=none, plain: canvas corners map 1:1 to source corners:");
    const base = await render({ colorCorrect: false, grid: false, filter: "none" }, true);
    assert(!base.error, `WebGL2 context created${base.error ? " -- " + base.error : ""}`);
    if (base.error) throw new Error(base.error);
    assert(isRed(base.topLeft), `canvas TOP-LEFT is RED  (${base.topLeft})`);
    assert(isGreen(base.topRight), `canvas TOP-RIGHT is GREEN  (${base.topRight})`);
    assert(isBlue(base.bottomLeft), `canvas BOTTOM-LEFT is BLUE  (${base.bottomLeft})`);
    assert(isWhite(base.bottomRight), `canvas BOTTOM-RIGHT is WHITE  (${base.bottomRight})`);
    assert(isYellow(base.center), `canvas CENTER is YELLOW  (${base.center})`);
    assert(isRed(base.q_tl), `interior top-left quadrant RED  (${base.q_tl})`);
    assert(isGreen(base.q_tr), `interior top-right quadrant GREEN  (${base.q_tr})`);
    assert(isBlue(base.q_bl), `interior bottom-left quadrant BLUE  (${base.q_bl})`);
    assert(isWhite(base.q_br), `interior bottom-right quadrant WHITE  (${base.q_br})`);

    // Best-effort diagnostic PNG: a failed write must not fail the test.
    try {
      const pngPath = join(tmpdir(), "dingbat-render-correct.png");
      writeFileSync(pngPath, Buffer.from(base.png.split(",")[1], "base64"));
      console.log(`  (wrote correct-render PNG -> ${pngPath})`);
    } catch (e) {
      console.log(`  (skipped correct-render PNG dump: ${e.message})`);
    }

    // Other paths: full-frame only (corners non-black and distinct).
    const structural = async (label, opts) => {
      console.log(`${label}: full-frame (corners non-black + distinct):`);
      const r = await render(opts);
      if (r.error) { assert(false, `${label}: ${r.error}`); return; }
      const c = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight];
      assert(c.every(nonBlack), `${label}: all four corners non-black`);
      let allDistinct = true;
      for (let i = 0; i < 4; i++)
        for (let j = i + 1; j < 4; j++)
          if (!distinct(c[i], c[j])) allDistinct = false;
      assert(allDistinct, `${label}: four corners are mutually distinct`);
      assert(nonBlack(r.center), `${label}: center non-black`);
    };
    await structural("color-correct ON (AGB)", { colorCorrect: true, panelGbc: false, grid: false, filter: "none" });
    await structural("color-correct ON (GBC)", { colorCorrect: true, panelGbc: true, grid: false, filter: "none" });
    await structural("LCD grid ON", { colorCorrect: false, grid: true, filter: "none" });
    await structural("RGB-subpixel mask ON", { colorCorrect: false, grid: false, subpixel: true, filter: "none" });
    await structural("filter=hq4x", { colorCorrect: false, grid: false, filter: "hq4x" });
    await structural("filter=xBR", { colorCorrect: false, grid: false, filter: "xbr" });
  } finally {
    await browser.close();
  }

  if (failures) { console.error(`\n${failures} assertion(s) failed`); process.exit(1); }
  console.log("\nall WebGL2 render tests passed");
}

run().catch((e) => { console.error(e); process.exit(1); });
