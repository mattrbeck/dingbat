// filtershot renderer: push a raw BGR555 frame dump (tools/filtershot/
// dump_frames.nim) through the REAL web present shader (web/glpresent.js,
// extracted by web/glshaders.mjs) once per upscale filter, in headless
// Chromium, and write one PNG per filter. This is the same
// extract-and-readback method as web/render.test.mjs, so what these PNGs show
// is exactly what ships.
//
//   node tools/filtershot/render.mjs <dump.rgb555> <w> <h> <scale> <outdir> <base>
//
// writes <outdir>/<base>.<filter>.png for none / hq4x / xbr / xbrz.
// Colour correction and scanlines are left OFF: both apply uniformly after the
// upscale stage, so they would shift every image identically without changing
// the comparison.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import { readShaders } from "../../web/glshaders.mjs";

const requireWeb = createRequire(new URL("../../web/package.json", import.meta.url));
const { chromium } = requireWeb("playwright");

const FILTERS = ["none", "hq4x", "xbr", "xbrz"];

function renderInPage({ VERT, FRAG, w, h, scale, pixels, filter }) {
  const canvas = document.getElementById("c");
  canvas.width = w * scale;
  canvas.height = h * scale;
  const gl = canvas.getContext("webgl2", {
    alpha: false, antialias: false, depth: false, stencil: false,
    preserveDrawingBuffer: true, premultipliedAlpha: false,
  });
  if (!gl) return { error: "WebGL2 unavailable" };
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
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 2);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16UI, w, h, 0,
    gl.RED_INTEGER, gl.UNSIGNED_SHORT, new Uint16Array(pixels));
  gl.viewport(0, 0, canvas.width, canvas.height);
  gl.useProgram(prog);
  const u1i = (n, v) => gl.uniform1i(gl.getUniformLocation(prog, n), v);
  u1i("u_color_correct", 0);
  u1i("u_panel_gbc", 0);
  u1i("u_scanlines", 0);
  u1i("u_dmg_remap", 0);
  u1i("u_sgb_border", 0);
  gl.uniform1f(gl.getUniformLocation(prog, "u_scan_height"), h);
  gl.uniform2f(gl.getUniformLocation(prog, "u_tex_size"), w, h);
  u1i("u_filter", filter === "hq4x" ? 1 : filter === "xbr" ? 2
    : filter === "xbrz" ? 3 : 0);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  return { png: canvas.toDataURL("image/png") };
}

async function main() {
  const [dump, wS, hS, scaleS, outdir, base] = process.argv.slice(2);
  if (!base) {
    console.error("usage: render.mjs <dump.rgb555> <w> <h> <scale> <outdir> <base>");
    process.exit(2);
  }
  const w = Number(wS), h = Number(hS), scale = Number(scaleS);
  const raw = readFileSync(dump);
  const pixels = Array.from(new Uint16Array(raw.buffer, raw.byteOffset, w * h));
  const { VERT, FRAG } = readShaders();
  mkdirSync(outdir, { recursive: true });
  const browser = await chromium.launch({ args: ["--enable-unsafe-swiftshader"] });
  const page = await browser.newPage();
  await page.setContent("<!doctype html><canvas id=c></canvas>");
  try {
    for (const filter of FILTERS) {
      const r = await page.evaluate(renderInPage,
        { VERT, FRAG, w, h, scale, pixels, filter });
      if (r.error) throw new Error(r.error);
      const out = join(outdir, `${base}.${filter}.png`);
      writeFileSync(out, Buffer.from(r.png.split(",")[1], "base64"));
      console.log(out);
    }
  } finally {
    await browser.close();
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
