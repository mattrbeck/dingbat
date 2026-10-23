// Host-GPU 3D harness (docs/nds/gpu3d.md): renders `ndsrun --gpu-dump`
// frames with web/nds/gpu3d.js in Chromium (or WebKit) and compares them
// with the software HD renderer's frames dumped beside them (--hd K).
//
//   node tools/gpu3d/run.mjs DUMPDIR [OUTDIR] [--engine webkit] [--headed]
//
// For each fN_meta.json in DUMPDIR: the GPU's 3D frame against hd3d.bin
// (dots equal), the GPU composite of the software HD 3D frame against
// hdtop/hdbottom.bin (checks the composite alone), the GPU composite of
// its own 3D frame against them (the whole path), the "just upscale"
// variants, and timings. Writes PNGs (software, GPU, diff) to OUTDIR.
// Needs Playwright (web/: npm ci; npx playwright install chromium).

import { createServer } from "node:http";
import { readFileSync, readdirSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, resolve, dirname, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync } from "node:zlib";
import { createRequire } from "node:module";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const args = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args.splice(i, 2)[1] : null; };
const engine = flag("--engine") || "chromium";
const headed = args.includes("--headed") ? (args.splice(args.indexOf("--headed"), 1), true) : false;
const dumpDir = resolve(args[0] || ".");
const outDir = resolve(args[1] || join(dumpDir, "gpu3d-out"));
mkdirSync(outDir, { recursive: true });

// Playwright from web/node_modules (this checkout's or the main one's)
const req = createRequire(join(root, "web", "package.json"));
let pw;
try { pw = req("playwright"); } catch {
  pw = createRequire(join(root, "..", "..", "..", "web", "package.json"))("playwright");
}

const types = { ".js": "text/javascript", ".mjs": "text/javascript", ".html": "text/html", ".json": "application/json" };
const server = createServer((rq, rs) => {
  const url = decodeURIComponent(new URL(rq.url, "http://x").pathname);
  const file = url.startsWith("/dumps/") ? join(dumpDir, url.slice(7)) : join(root, url);
  if (url === "/") {
    rs.writeHead(200, { "content-type": "text/html" });
    rs.end("<!doctype html><canvas id=c></canvas>");
    return;
  }
  if (!existsSync(file)) { rs.writeHead(404); rs.end(); return; }
  rs.writeHead(200, { "content-type": types[extname(file)] || "application/octet-stream" });
  rs.end(readFileSync(file));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

const browser = await pw[engine].launch({
  headless: !headed,
  args: engine === "chromium" ? ["--enable-gpu", "--ignore-gpu-blocklist", "--use-angle=metal", "--mute-audio"] : [],
});
const page = await browser.newPage();
page.on("console", (m) => console.log("  [page]", m.text()));
page.on("pageerror", (e) => console.log("  [page error]", e.message));
await page.goto(base + "/");

const png = (w, h, rgba) => {
  const crcT = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; return c; });
  const crc = (b) => { let c = -1; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
  const chunk = (t, d) => { const b = Buffer.alloc(12 + d.length); b.writeUInt32BE(d.length, 0); b.write(t, 4); d.copy(b, 8); b.writeUInt32BE(crc(b.subarray(4, 8 + d.length)), 8 + d.length); return b; };
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1);
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
};

const metas = readdirSync(dumpDir).filter((f) => f.endsWith("_meta.json"))
  .sort((a, b) => parseInt(a.slice(1)) - parseInt(b.slice(1)));
for (const m of metas) {
  const pre = m.replace("meta.json", "");
  const meta = JSON.parse(readFileSync(join(dumpDir, m), "utf8"));
  console.log(`${pre} (hd ${meta.hd})`);
  const r = await page.evaluate(async ({ pre, k }) => {
    const { NdsGpu3d } = await import("/web/nds/gpu3d.js");
    const get = async (n) => new Uint8Array(await (await fetch(`/dumps/${pre}${n}.bin`)).arrayBuffer());
    const u32 = (b) => new Uint32Array(b.buffer, b.byteOffset, b.byteLength >> 2);
    const u16 = (b) => new Uint16Array(b.buffer, b.byteOffset, b.byteLength >> 1);
    const scene = u32(await get("scene")), tex = await get("tex"), pal = await get("pal");
    const plane = u32(await get("plane")), plane2 = u32(await get("plane2")), lines = u32(await get("lines"));
    const top = u16(await get("top")), bottom = u16(await get("bottom"));
    const frame3d = u32(await get("frame3d"));
    const hd3d = u32(await get("hd3d"));
    const hdtop = u16(await get("hdtop")), hdbottom = u16(await get("hdbottom"));
    const screens1x = new Uint16Array(256 * 384); screens1x.set(top); screens1x.set(bottom, 256 * 192);
    const hdScreens = new Uint16Array(hdtop.length * 2); hdScreens.set(hdtop); hdScreens.set(hdbottom, hdtop.length);
    const cv = document.getElementById("c");
    const gl = window.__gl || (window.__gl = cv.getContext("webgl2", { antialias: false, preserveDrawingBuffer: true }));
    const dbg = gl.getExtension("WEBGL_debug_renderer_info");
    const renderer = dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
    // one renderer for the run: display capture's HD copies carry from
    // frame to frame, so consecutive dumps must go in order
    if (!window.__g || window.__g.k !== k) { window.__g = new NdsGpu3d(gl); window.__g.setScale(k); }
    const g = window.__g;
    const out = { renderer, polys: scene[1], verts: scene[2] };
    const cmpScreens = (s) => { let e = 0; for (let i = 0; i < s.length; i++) if (s[i] === hdScreens[i]) e++; return e; };
    // first the variants, which leave the banks' HD copies alone: the
    // composite over the software HD 3D frame, and "just upscale"
    g.set3d(hd3d);
    g.composite(screens1x, plane, plane2, lines, false);
    out.eqScreensSw3d = cmpScreens(g.read(g.screens));
    g.upscale(frame3d, false); g.composite(screens1x, plane, plane2, lines, false);
    out.eqUpNearest = cmpScreens(g.read(g.screens));
    g.upscale(frame3d, true); g.composite(screens1x, plane, plane2, lines, false);
    const upSmooth = g.read(g.screens);
    out.eqUpSmooth = cmpScreens(upSmooth);
    // the whole path: GPU 3D, the composite, display capture
    out.jsMs = g.setScene(scene, tex, pal);
    out.bins = g.binTotal;
    g.render();
    const mine3d = g.read(g.out3d);
    let eq = 0, eqVisible = 0, vis = 0; const firstDiff = [];
    for (let i = 0; i < mine3d.length; i++) {
      if (mine3d[i] === hd3d[i]) eq++;
      else if (firstDiff.length < 8) firstDiff.push([i % (256 * k), Math.floor(i / (256 * k)), hd3d[i].toString(16), mine3d[i].toString(16)]);
      if (hd3d[i] >>> 24) { vis++; if (mine3d[i] === hd3d[i]) eqVisible++; }
    }
    out.dots3d = mine3d.length; out.eq3d = eq; out.vis3d = vis; out.eqVis3d = eqVisible; out.firstDiff = firstDiff;
    g.composite(screens1x, plane, plane2, lines);
    const gpuScreens = g.read(g.screens);
    out.eqScreens = cmpScreens(gpuScreens);
    out.dotsScreens = gpuScreens.length;
    // timings: unpaced, each waited for (a pass leaves its target bound:
    // one dot read back waits for it); no captures
    const px = new Uint32Array(4);
    const sync = () => gl.readPixels(0, 0, 1, 1, gl.RGBA_INTEGER, gl.UNSIGNED_INT, px);
    const time = (fn, n) => {
      fn(); sync();
      const t0 = performance.now();
      for (let i = 0; i < n; i++) { fn(); sync(); }
      return (performance.now() - t0) / n;
    };
    out.msRender = time(() => g.render(), 20);
    out.ablate = [1, 2, 4, 6].map((a) => time(() => g.render(a), 20).toFixed(2));
    out.msUpscale = time(() => g.upscale(frame3d, true), 20);
    out.msComposite = time(() => g.composite(screens1x, plane, plane2, lines, false), 20);
    out.msCompositePass = time(() => g.composite(null, null, null, null, false), 20);
    out.msSetScene = time(() => { g.setScene(scene, null, null); g.render(); }, 20) - out.msRender;
    out.msEmpty = time(() => {}, 20);
    // pictures: software, GPU (whole path), diff, smooth upscale
    const rgba = (s) => { const o = new Uint8Array(s.length * 4); for (let i = 0; i < s.length; i++) { const c = s[i]; o[i * 4] = (c & 31) * 255 / 31; o[i * 4 + 1] = ((c >> 5) & 31) * 255 / 31; o[i * 4 + 2] = ((c >> 10) & 31) * 255 / 31; o[i * 4 + 3] = 255; } return o; };
    const diff = new Uint8Array(gpuScreens.length * 4);
    for (let i = 0; i < gpuScreens.length; i++) {
      const same = gpuScreens[i] === hdScreens[i];
      const c = hdScreens[i];
      const grey = (((c & 31) + ((c >> 5) & 31) + ((c >> 10) & 31)) * 255 / 93) * 0.3;
      diff[i * 4] = same ? grey : 255; diff[i * 4 + 1] = same ? grey : 0; diff[i * 4 + 2] = same ? grey : 255; diff[i * 4 + 3] = 255;
    }
    const b64 = (u8) => { let s = ""; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000)); return btoa(s); };
    out.pics = { sw: b64(rgba(hdScreens)), gpu: b64(rgba(gpuScreens)), diff: b64(diff), upsmooth: b64(rgba(upSmooth)) };
    out.w = 256 * k; out.h = 384 * k;
    return out;
  }, { pre, k: meta.hd });
  for (const [name, b] of Object.entries(r.pics)) {
    writeFileSync(join(outDir, `${pre}${name}.png`), png(r.w, r.h, new Uint8Array(Buffer.from(b, "base64"))));
  }
  delete r.pics;
  const pct = (a, b) => (100 * a / b).toFixed(3) + "%";
  console.log(`  renderer ${r.renderer}; ${r.polys} polys, ${r.verts} verts, ${r.bins} bin entries`);
  console.log(`  3D frame: ${pct(r.eq3d, r.dots3d)} dots equal (${pct(r.eqVis3d, r.vis3d)} of visible)` +
              (r.firstDiff.length ? `; first diffs [x, y, sw, gpu] ${JSON.stringify(r.firstDiff)}` : ""));
  console.log(`  screens: GPU path ${pct(r.eqScreens, r.dotsScreens)}, composite over software 3D ${pct(r.eqScreensSw3d, r.dotsScreens)}, ` +
              `upscale nearest ${pct(r.eqUpNearest, r.dotsScreens)}, smooth ${pct(r.eqUpSmooth, r.dotsScreens)}`);
  console.log(`  ms: setScene ${r.jsMs.toFixed(2)} (warm, with uploads ${r.msSetScene.toFixed(2)}), render ${r.msRender.toFixed(2)}, ` +
              `upscale ${r.msUpscale.toFixed(2)}, composite ${r.msComposite.toFixed(2)} (pass alone ${r.msCompositePass.toFixed(2)}), ` +
              `round trip ${r.msEmpty.toFixed(2)}; render without plot / texels / depth math / both: ${r.ablate.join(" / ")}`);
}
await browser.close();
server.close();
