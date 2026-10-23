// Host-GPU 3D against the software HD over many ROMs (docs/nds/gpu3d.md):
// each ROM boots in the web build of the core (web/nds/nds.js, HLE BIOS)
// with the core's software HD and the GPU export both on from power-on,
// so display capture's history is the same for both; every frame goes
// through web/nds/gpu3d.js and every Nth frame's screens are compared dot
// for dot with the core's (at k = 1, with the 1x screens). A short press
// script reaches past title screens.
//
//   node tools/gpu3d/sweep.mjs OUTDIR ROM... [--k 1,2,4] [--frames 360] [--every 4]
//
// One line per ROM and scale; for the first mismatching frame of each it
// writes OUTDIR/<rom>_k<k>_f<frame>_{sw,gpu,diff}.png. Needs web/nds/nds.js
// (the web build) and Playwright.

import { createServer } from "node:http";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, resolve, dirname, extname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync } from "node:zlib";
import { createRequire } from "node:module";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const args = process.argv.slice(2);
const opt = (name, dflt) => { const i = args.indexOf(name); return i >= 0 ? args.splice(i, 2)[1] : dflt; };
const KS = opt("--k", "1,2,4").split(",").map(Number);
const FRAMES = Number(opt("--frames", "360"));
const EVERY = Number(opt("--every", "4"));
// --hold KEY@F-L (button ids as nds_set_button: 0 A .. 3 START .. 2 SELECT)
// and --repeat KEY@F/N (pressed for 3 frames every N frames from F) in
// place of the default presses
const HOLD = opt("--hold", "");
const REPEAT = opt("--repeat", "");
const [outArg, ...roms] = args;
const outDir = resolve(outArg);
mkdirSync(outDir, { recursive: true });
let pw;
try { pw = createRequire(join(root, "web", "package.json"))("playwright"); } catch {
  pw = createRequire(join(root, "..", "..", "..", "web", "package.json"))("playwright");
}

const romFiles = new Map(roms.map((r, i) => [`/rom/${i}`, resolve(r)]));
const types = { ".js": "text/javascript", ".wasm": "application/wasm", ".html": "text/html" };
const server = createServer((rq, rs) => {
  const url = decodeURIComponent(new URL(rq.url, "http://x").pathname);
  if (url === "/") {
    rs.writeHead(200, { "content-type": "text/html" });
    rs.end('<!doctype html><canvas id=c></canvas><script src="/web/nds/nds.js"></script>');
    return;
  }
  const file = romFiles.get(url) || join(root, url);
  if (!existsSync(file)) { rs.writeHead(404); rs.end(); return; }
  rs.writeHead(200, { "content-type": types[extname(file)] || "application/octet-stream" });
  rs.end(readFileSync(file));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await pw.chromium.launch({ headless: true,
  args: ["--enable-gpu", "--ignore-gpu-blocklist", "--use-angle=metal", "--mute-audio"] });
const page = await browser.newPage();
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

let totals = { runs: 0, exact: 0, polysMax: 0 };
for (const [url, file] of romFiles) {
  for (const k of KS) {
    const r = await page.evaluate(async ({ url, k, frames, every, hold, repeat }) => {
      const { NdsGpu3d } = await import("/web/nds/gpu3d.js");
      if (!window.__core) window.__core = await createNdsCore({ locateFile: (p) => "/web/nds/" + p });
      const c = window.__core;
      const rom = new Uint8Array(await (await fetch(url)).arrayBuffer());
      c._nds_set_hd(k);
      c._nds_set_gpu(1);
      const p = c._nds_rom_alloc(rom.length);
      c.HEAPU8.set(rom, p);
      if (!c._nds_boot(0, 0, 0, 0, 0, 0, 0, 0)) return { error: "boot failed" };
      const cv = document.getElementById("c");
      const gl = window.__gl || (window.__gl = cv.getContext("webgl2", { antialias: false }));
      // a fresh renderer per run: no capture history from another ROM
      const g = new NdsGpu3d(gl);
      g.setScale(k);
      const W = 256 * k, H = 384 * k, half = W * H / 2;
      const out = new Uint32Array(W * H * 4);
      const fb = gl.createFramebuffer();
      // presses: A and START now and then (past title screens, libnds
      // examples' prompts), a tap in the middle of the touch screen
      const press = hold || repeat ? {} : { 100: 0, 160: 3, 220: 0, 280: 0 };
      const held = hold ? hold.split("@").map((v, i) => i ? v.split("-").map(Number) : Number(v)) : null;
      const rep = repeat ? repeat.split("@").map((v, i) => i ? v.split("/").map(Number) : Number(v)) : null;
      let compared = 0, bad = 0, badDots = 0, firstBad = -1, maxPolys = 0, frames3d = 0, pics = null, offAt = 0, lateFrames = 0;
      let lastGen = -1;
      for (let f = 1; f <= frames; f++) {
        if (press[f] !== undefined) c._nds_set_button(press[f], 1);
        if (press[f - 3] !== undefined) c._nds_set_button(press[f - 3], 0);
        if (held && f === held[1][0]) c._nds_set_button(held[0], 1);
        if (held && f === held[1][1]) c._nds_set_button(held[0], 0);
        if (rep && f >= rep[1][0] && (f - rep[1][0]) % rep[1][1] === 0) c._nds_set_button(rep[0], 1);
        if (rep && f >= rep[1][0] + 3 && (f - rep[1][0] - 3) % rep[1][1] === 0) c._nds_set_button(rep[0], 0);
        if (!hold && !repeat && f === 200) c._nds_set_touch(128, 96, 1);
        if (!hold && !repeat && f === 203) c._nds_set_touch(128, 96, 0);
        c._nds_run_frame();
        c._nds_audio_clear();
        // switched off (libnds examples do on START): nothing more is drawn,
        // and the app shows the core's own black screens
        if (c._nds_powered_off()) { offAt = f; break; }
        const buf = c.HEAPU8.buffer;
        const sp = c._nds_gpu_scene();
        if (!sp) continue;
        const scene = new Uint32Array(buf, sp, c._nds_gpu_scene_len());
        maxPolys = Math.max(maxPolys, scene[1]);
        if (scene[6] !== lastGen) { lastGen = scene[6]; if (scene[1] > 0) frames3d++; }
        const late = [];
        for (let i = 0, nl = c._nds_gpu_late_count(); i < nl; i++) {
          late.push({ scene: new Uint32Array(buf, c._nds_gpu_late(i), c._nds_gpu_late_len(i)), line: c._nds_gpu_late_line(i) });
        }
        if (late.length) lateFrames++;
        g.drawFrame(scene, new Uint8Array(buf, c._nds_gpu_tex(), 0x80000), new Uint8Array(buf, c._nds_gpu_pal(), 0x18000), late);
        g.composite([new Uint16Array(buf, c._nds_fb555_top(), 256 * 192), new Uint16Array(buf, c._nds_fb555_bottom(), 256 * 192)],
          new Uint32Array(buf, c._nds_gpu_plane(), 256 * 192 * 4), new Uint32Array(buf, c._nds_gpu_plane2(), 256 * 192 * 4),
          new Uint32Array(buf, c._nds_gpu_lines(), 192 * 8));
        if (f % every !== 0) continue;
        gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, g.screens.t, 0);
        gl.readPixels(0, 0, W, H, gl.RGBA_INTEGER, gl.UNSIGNED_INT, out);
        const top = new Uint16Array(c.HEAPU8.buffer, k > 1 ? c._nds_hd_fb555_top() : c._nds_fb555_top(), half);
        const bot = new Uint16Array(c.HEAPU8.buffer, k > 1 ? c._nds_hd_fb555_bottom() : c._nds_fb555_bottom(), half);
        let d = 0;
        for (let i = 0; i < half; i++) {
          if (out[i * 4] !== top[i]) d++;
          if (out[(i + half) * 4] !== bot[i]) d++;
        }
        compared++;
        if (d) {
          bad++; badDots += d;
          if (firstBad < 0) {
            firstBad = f;
            const sw = new Uint16Array(W * H), gp = new Uint16Array(W * H);
            sw.set(top); sw.set(bot, half);
            for (let i = 0; i < W * H; i++) gp[i] = out[i * 4];
            pics = { sw: Array.from(sw), gpu: Array.from(gp) };
          }
        }
      }
      gl.deleteFramebuffer(fb);
      c._nds_unload();
      return { compared, bad, badDots, firstBad, maxPolys, frames3d, pics, W, H, offAt, lateFrames };
    }, { url, k, frames: FRAMES, every: EVERY, hold: HOLD, repeat: REPEAT });
    const name = basename(file, ".nds");
    if (r.error) { console.log(`${name} ${k}x: ${r.error}`); continue; }
    totals.runs++;
    if (!r.bad) totals.exact++;
    totals.polysMax = Math.max(totals.polysMax, r.maxPolys);
    console.log(`${name} ${k}x: ${r.bad ? "DIFFERS" : "exact"}, ${r.compared} frames compared` +
      (r.bad ? ` (${r.bad} differ, ${r.badDots} dots, first frame ${r.firstBad})` : "") +
      `; 3D scenes ${r.frames3d}, up to ${r.maxPolys} polygons` + (r.offAt ? `; switched off at frame ${r.offAt}` : "") +
      (r.lateFrames ? `; ${r.lateFrames} frames split mid-frame` : ""));
    if (r.pics) {
      const rgba = (s, diffWith) => {
        const o = new Uint8Array(s.length * 4);
        for (let i = 0; i < s.length; i++) {
          const c = s[i];
          if (diffWith && diffWith[i] !== c) { o.set([255, 0, 255, 255], i * 4); continue; }
          const sc = diffWith ? 0.35 : 1;
          o.set([(c & 31) * 255 / 31 * sc, ((c >> 5) & 31) * 255 / 31 * sc, ((c >> 10) & 31) * 255 / 31 * sc, 255], i * 4);
        }
        return o;
      };
      const pre = join(outDir, `${name}_k${k}_f${r.firstBad}`);
      writeFileSync(pre + "_sw.png", png(r.W, r.H, rgba(r.pics.sw)));
      writeFileSync(pre + "_gpu.png", png(r.W, r.H, rgba(r.pics.gpu)));
      writeFileSync(pre + "_diff.png", png(r.W, r.H, rgba(r.pics.sw, r.pics.gpu)));
    }
  }
}
console.log(`total: ${totals.exact} of ${totals.runs} runs exact; up to ${totals.polysMax} polygons a scene`);
await browser.close();
server.close();
