// --- Shared WebGL2 game presenter ---
// The single place that turns the wasm core's raw BGR555 framebuffer into
// pixels on a canvas. Both index.js and embed.js call this so the embed
// cannot lag the main renderer.
//
// Deps are injected so this file has no DOM/globals of its own beyond the
// wasm Module: canvasEl is the VISIBLE canvas we own a WebGL2 context on
// (SDL must render to a different, hidden canvas); nativeRes() -> [w,h] gives
// the core's native pixel size; log(msg) reports GL errors.
function createGlRenderer(canvasEl, nativeRes, log) {
  let gl = null, prog = null, tex = null, btex = null, lost = false;
  let uColorCorrect, uPanelGbc, uGrid, uScanHeight, uTexSize, uFilter;
  let uScanWidth, uSubpixel;
  let uDmgRemap, uDmgPal, uBorderTex, uSgbBorder, uSgbBackdrop;
  let lastW = 0, lastH = 0;
  // Last SGB border generation uploaded. The image changes a handful of times
  // in a session and is 112 KiB, so it is re-uploaded only when it moves.
  let lastBorderGen = -1;
  // Scratch for the vec3[4] palette upload — 12 floats, reused every draw.
  const dmgPalBuf = new Float32Array(12);

  const VERT = `#version 300 es
out vec2 v_uv;
void main() {
  // Full-screen triangle; v_uv flips Y so framebuffer row 0 is at the top.
  // p is (0,0),(2,0),(0,2) -> clip (-1,-1),(3,-1),(-1,3): the triangle spans 4
  // clip units, so v_uv must span 0..2 across it for the visible [-1,1] window
  // to interpolate 0..1. Passing p directly (NOT p*0.5) is what makes the whole
  // frame show instead of just the bottom-left quadrant zoomed 2x.
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  v_uv = vec2(p.x, 1.0 - p.y);
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

  // Upscale filters: the hq4x- and xBR-style branches follow the public
  // algorithm descriptions. Mirrors src/dingbat.nim FRAG_SRC.
  const FRAG = `#version 300 es
precision highp float;
precision highp int;
precision highp usampler2D;
in vec2 v_uv;
out vec4 frag_color;
uniform usampler2D u_tex;       // R16UI: raw BGR555 pixels
uniform bool u_color_correct;
uniform bool u_panel_gbc;       // CGB color model vs AGB
uniform bool u_grid;
// The pixel pitches the LCD-grid and RGB-subpixel looks use. These are the
// OUTPUT dimensions, not the game texture's: with an SGB border the picture
// is 256x224 native pixels and both layers live in it, so feeding the game's
// 160x144 here would draw a Game Boy grid over SNES border art.
uniform float u_scan_height;
uniform float u_scan_width;
uniform bool u_subpixel;
uniform vec2 u_tex_size;        // game texel dimensions (w, h)
uniform int u_filter;           // 0 = none, 1 = hq4x, 2 = xBR
// --- Super Game Boy border ---------------------------------------------
// A 256x224 second layer in the same BGR555 packing as the game framebuffer,
// with bit 15 = opaque (SNES colour 0 is transparent). The Game Boy window is
// composited into the 160x144 rect at (48, 40). Off unless the running cart is
// an SGB game that actually transferred a border.
uniform usampler2D u_border;
uniform bool u_sgb_border;
uniform vec3 u_sgb_backdrop;    // SGB colour 0, shown where nothing else is
// --- Game Boy shade palette (monochrome DMG titles only) ---
// A DMG game's framebuffer holds ONLY the four BGR555 values the core writes
// for shades 0..3 (src/dingbat/gb/gb.nim DMG_COLORS), so recolouring the
// screen is an exact 4-way substitution here in the presenter — the core never
// sees it, which is what keeps save states, rewind and netplay byte-identical.
// Off (u_dmg_remap false) unless the caller passes a palette AND the running
// game is monochrome; a pixel that is not on the shade ramp falls through
// untouched, so a mis-gated colour title would still render correctly.
//
// The LCD response model (src/dingbat/common/lcd_response.nim) is what makes
// this more than a four-way substitution: a settling pixel sits BETWEEN two
// shades for a few frames, and an exact-match table would drop those back to
// the built-in green while everything around them wore the chosen palette.
// So the lookup finds which pair of shades a pixel lies between and mixes the
// corresponding pair of palette entries. Exactly-a-shade still lands exactly
// on its palette entry (t is 0 or 1), and a pixel that is not near the ramp
// is left alone, which is what keeps a colour game safe.
uniform bool u_dmg_remap;
uniform vec3 u_dmg_pal[4];      // sRGB 0..1, shade 0 (lightest) -> 3

// The four values a monochrome core writes (gb.nim DMG_COLORS), as 5-bit
// channels. Green is strictly decreasing across them, so it is the key that
// says where between two shades a settling pixel currently is.
const vec3 DMG_SHADE[4] = vec3[4](vec3(31.0, 30.0, 26.0),   // 0x6BDF
                                  vec3(31.0, 21.0, 14.0),   // 0x3ABF
                                  vec3(29.0, 13.0, 13.0),   // 0x35BD
                                  vec3(15.0,  7.0, 11.0));  // 0x2CEF

ivec2 g_max;
vec3 fetchRGB(ivec2 p) {
  uint packed = texelFetch(u_tex, clamp(p, ivec2(0), g_max), 0).r & 0x7FFFu;
  vec3 c = vec3(float(packed & 31u),
                float((packed >> 5) & 31u),
                float((packed >> 10) & 31u));
  if (u_dmg_remap) {
    for (int i = 0; i < 3; i++) {
      vec3 a = DMG_SHADE[i], b = DMG_SHADE[i + 1];
      float t = (a.y - c.y) / (a.y - b.y);
      if (t >= 0.0 && t <= 1.0) {
        // Green brackets it; confirm the other two channels agree before
        // trusting the substitution.
        if (all(lessThan(abs(mix(a, b, t) - c), vec3(1.5))))
          return mix(u_dmg_pal[i], u_dmg_pal[i + 1], t);
        break;
      }
    }
  }
  return c / 31.0;
}
vec3 yuv(vec3 c) {
  return vec3(dot(c, vec3( 0.299,  0.587,  0.114)),
              dot(c, vec3(-0.169, -0.331,  0.500)),
              dot(c, vec3( 0.500, -0.419, -0.081)));
}
float df(vec3 a, vec3 b) {           // xBR weighted distance 48*Y+7*U+6*V
  vec3 d = abs(yuv(a) - yuv(b));
  return d.x * 48.0 + d.y * 7.0 + d.z * 6.0;
}
bool similar(vec3 a, vec3 b) {       // hqx per-channel YUV threshold (48,7,6)
  vec3 d = abs(yuv(a) - yuv(b));
  return d.x <= 48.0/255.0 && d.y <= 7.0/255.0 && d.z <= 6.0/255.0;
}
vec3 unpack555(uint packed) {
  return vec3(float(packed & 31u),
              float((packed >> 5) & 31u),
              float((packed >> 10) & 31u)) / 31.0;
}

vec3 upscale(vec2 uv) {
  g_max = ivec2(u_tex_size) - ivec2(1);
  vec2 pos  = uv * u_tex_size;
  ivec2 base = ivec2(floor(pos));
  vec3 E = fetchRGB(base);
  if (u_filter == 0) return E;
  vec2 fp = fract(pos);
  int sx = fp.x < 0.5 ? -1 : 1;
  int sy = fp.y < 0.5 ? -1 : 1;
  float lx = sx > 0 ? fp.x : 1.0 - fp.x;
  float ly = sy > 0 ? fp.y : 1.0 - fp.y;
  float w = smoothstep(0.15, 0.85, lx + ly - 1.0);
  vec3 Ph = fetchRGB(base + ivec2(sx, 0));
  vec3 Pv = fetchRGB(base + ivec2(0, sy));
  vec3 X  = fetchRGB(base + ivec2(sx, sy));

  if (u_filter == 1) {               // hq4x-style
    if (!similar(E, Ph) && !similar(E, Pv) && similar(Ph, Pv))
      return mix(E, 0.5 * (Ph + Pv), w);
    return E;
  }
  // u_filter == 2: xBR-lv2
  vec3 C  = fetchRGB(base + ivec2( sx, -sy));
  vec3 G  = fetchRGB(base + ivec2(-sx,  sy));
  vec3 F4 = fetchRGB(base + ivec2( 2 * sx, 0));
  vec3 H5 = fetchRGB(base + ivec2( 0, 2 * sy));
  vec3 D  = fetchRGB(base + ivec2(-sx, 0));
  vec3 I5 = fetchRGB(base + ivec2( sx, 2 * sy));
  vec3 I4 = fetchRGB(base + ivec2( 2 * sx, sy));
  vec3 B  = fetchRGB(base + ivec2( 0, -sy));
  float wd_red  = df(E, C) + df(E, G) + df(X, F4) + df(X, H5) + 4.0 * df(Pv, Ph);
  float wd_blue = df(Pv, D) + df(Pv, I5) + df(Ph, I4) + df(Ph, B) + 4.0 * df(E, X);
  if (wd_red < wd_blue) {
    vec3 px = df(E, Ph) <= df(E, Pv) ? Ph : Pv;
    return mix(E, px, w);
  }
  return E;
}

// The panel colour model, applied to the Game Boy layer only.
vec3 shade(vec3 c) {
  float outGamma = 2.2;
  vec3 rgb;
  // A chosen palette is already in display space: the LCD colour model would
  // shift the exact hex the user (or the theme) asked for, so it is bypassed.
  // Default shades keep the panel model, so nothing changes when the palette
  // feature is off.
  if (u_color_correct && !u_dmg_remap) {
    if (u_panel_gbc) {
      vec3 lin = pow(c, vec3(2.2)) * 0.94;
      rgb = pow(clamp(vec3(
        0.82 * lin.r + 0.125 * lin.g + 0.195 * lin.b,
        0.24 * lin.r + 0.665 * lin.g + 0.075 * lin.b,
       -0.06 * lin.r + 0.210 * lin.g + 0.730 * lin.b), 0.0, 1.0),
        vec3(1.0 / outGamma));
    } else {
      float lcdGamma = 4.0;
      vec3 lin = pow(c, vec3(lcdGamma));
      rgb = pow(vec3(
        0.0 * lin.b +  50.0 * lin.g + 240.0 * lin.r,
       30.0 * lin.b + 230.0 * lin.g +  10.0 * lin.r,
      220.0 * lin.b +  10.0 * lin.g +  50.0 * lin.r) / 255.0,
        vec3(1.0 / outGamma));
    }
  } else {
    rgb = c;
  }
  return rgb;
}

void main() {
  vec3 rgb;
  if (u_sgb_border) {
    ivec2 bp = clamp(ivec2(v_uv * vec2(256.0, 224.0)), ivec2(0), ivec2(255, 223));
    uint bw = texelFetch(u_border, bp, 0).r;
    if ((bw & 0x8000u) != 0u) {
      // Border art is native SNES output, not an LCD panel: it skips the
      // colour model, the shade palette and the 2bpp-tuned upscale filters.
      rgb = unpack555(bw & 0x7FFFu);
    } else {
      vec2 guv = (v_uv * vec2(256.0, 224.0) - vec2(48.0, 40.0)) / vec2(160.0, 144.0);
      rgb = (guv.x >= 0.0 && guv.x < 1.0 && guv.y >= 0.0 && guv.y < 1.0)
            ? shade(upscale(guv)) : u_sgb_backdrop;
    }
  } else {
    rgb = shade(upscale(v_uv));
  }
  // "LCD grid": a thin dark seam between every pixel, on BOTH axes — the
  // pixel matrix a reflective Game Boy LCD really shows (scanlines were a CRT
  // idiom; no handheld panel has them). The seam is the trailing quarter of
  // each cell, one whole backing pixel at the web's 4x store, and it darkens
  // gently so the grid reads as texture rather than as bars.
  if (u_grid &&
      (fract(v_uv.x * u_scan_width) > 0.75 ||
       fract(v_uv.y * u_scan_height) > 0.75)) {
    rgb *= 0.85;
  }
  // "RGB subpixels": draw the display's own structure — each emulated pixel
  // splits into three vertical R/G/B stripes over a darkened row gap, the way
  // a GBC/GBA TFT's subpixel triad looks up close (a DMG panel has no
  // subpixels, so there this is a stylised look, not a simulation). The
  // off-stripes keep half and a 1.35 gain rebalances overall brightness;
  // min() stops the gain pushing whites into hue shifts.
  if (u_subpixel) {
    int stripe = int(fract(v_uv.x * u_scan_width) * 3.0);
    vec3 m = stripe == 0 ? vec3(1.0, 0.5, 0.5)
           : stripe == 1 ? vec3(0.5, 1.0, 0.5)
           :               vec3(0.5, 0.5, 1.0);
    rgb = min(rgb * m * 1.35, vec3(1.0));
    if (fract(v_uv.y * u_scan_height) > 0.85) rgb *= 0.7;
  }
  frag_color = vec4(rgb, 1.0);
}`;

  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
      log("gl shader compile error: " + gl.getShaderInfoLog(s));
      gl.deleteShader(s);
      return null;
    }
    return s;
  };

  const build = () => {
    const vs = compile(gl.VERTEX_SHADER, VERT);
    const fs = compile(gl.FRAGMENT_SHADER, FRAG);
    if (!vs || !fs) { prog = null; return false; }
    prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
      log("gl link error: " + gl.getProgramInfoLog(prog));
      prog = null; return false;
    }
    uColorCorrect = gl.getUniformLocation(prog, "u_color_correct");
    uPanelGbc = gl.getUniformLocation(prog, "u_panel_gbc");
    uGrid = gl.getUniformLocation(prog, "u_grid");
    uScanHeight = gl.getUniformLocation(prog, "u_scan_height");
    uScanWidth = gl.getUniformLocation(prog, "u_scan_width");
    uSubpixel = gl.getUniformLocation(prog, "u_subpixel");
    uTexSize = gl.getUniformLocation(prog, "u_tex_size");
    uFilter = gl.getUniformLocation(prog, "u_filter");
    uDmgRemap = gl.getUniformLocation(prog, "u_dmg_remap");
    // Array uniforms are addressed by their first element.
    uDmgPal = gl.getUniformLocation(prog, "u_dmg_pal[0]");
    uBorderTex = gl.getUniformLocation(prog, "u_border");
    uSgbBorder = gl.getUniformLocation(prog, "u_sgb_border");
    uSgbBackdrop = gl.getUniformLocation(prog, "u_sgb_backdrop");
    tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    // Integer textures must use NEAREST filtering.
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    // The SGB border layer, on texture unit 1. Allocated lazily on the first
    // frame that has one.
    btex = gl.createTexture();
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, btex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16UI, 256, 224, 0,
      gl.RED_INTEGER, gl.UNSIGNED_SHORT, null);
    gl.activeTexture(gl.TEXTURE0);
    lastW = 0; lastH = 0; lastBorderGen = -1;
    return true;
  };

  const ensure = () => {
    if (!gl) {
      gl = canvasEl.getContext("webgl2", {
        alpha: false, antialias: false, depth: false, stencil: false,
        preserveDrawingBuffer: false, premultipliedAlpha: false,
        powerPreference: "low-power",
      });
      if (!gl) { log("WebGL2 unavailable — game view cannot render"); return false; }
      // Mobile Safari can drop the context under memory pressure; recover.
      canvasEl.addEventListener("webglcontextlost", (e) => {
        e.preventDefault();
        lost = true; prog = null; tex = null;
        log("gl context lost");
      });
      canvasEl.addEventListener("webglcontextrestored", () => {
        lost = false;
        log("gl context restored");
        build();
      });
    }
    if (lost) return false;
    if (!prog && !build()) return false;
    return true;
  };

  return {
    // Draw the current wasm game frame. opts drives the color/scanline uniforms.
    // opts.frame, when given, is the picture instead of the em.js core's: a
    // w x h frame assembled from BGR555 parts ({ view: Uint16Array, x, y, w,
    // h }), texels no part covers left black. The DS's two screens come in
    // this way (index.js "Nintendo DS"); there is no SGB border then.
    draw(opts) {
      if (!ensure()) return;
      const frame = opts.frame || null;
      const ptr = frame ? 0 : Module._wasm_game_fb_ptr && Module._wasm_game_fb_ptr();
      if (!frame && !ptr) return;
      // nativeRes() is the OUTPUT size, which an SGB border makes 256x224.
      // The game texture is always the console's own framebuffer.
      const border = !frame && !!(Module._wasm_sgb_border && Module._wasm_sgb_border());
      const [ow, oh] = frame ? [frame.w, frame.h] : nativeRes();
      const w = border ? 160 : ow, h = border ? 144 : oh;
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 2);
      if (frame) {
        if (w !== lastW || h !== lastH) {
          // Zero-filled: the gap between parts reads as black.
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16UI, w, h, 0,
            gl.RED_INTEGER, gl.UNSIGNED_SHORT, new Uint16Array(w * h));
          lastW = w; lastH = h;
        }
        for (const p of frame.parts) {
          gl.texSubImage2D(gl.TEXTURE_2D, 0, p.x, p.y, p.w, p.h,
            gl.RED_INTEGER, gl.UNSIGNED_SHORT, p.view);
        }
      } else {
        // Fresh view each frame: ALLOW_MEMORY_GROWTH can detach the old buffer.
        const view = new Uint16Array(Module.memory.buffer, ptr, w * h);
        if (w !== lastW || h !== lastH) {
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16UI, w, h, 0,
            gl.RED_INTEGER, gl.UNSIGNED_SHORT, view);
          lastW = w; lastH = h;
        } else {
          gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, w, h,
            gl.RED_INTEGER, gl.UNSIGNED_SHORT, view);
        }
      }
      // --- SGB border layer ---
      if (border) {
        const bptr = Module._wasm_sgb_border_ptr && Module._wasm_sgb_border_ptr();
        const gen = Module._wasm_sgb_border_gen ? Module._wasm_sgb_border_gen() : 0;
        if (bptr && gen !== lastBorderGen) {
          lastBorderGen = gen;
          const bview = new Uint16Array(Module.memory.buffer, bptr, 256 * 224);
          gl.activeTexture(gl.TEXTURE1);
          gl.bindTexture(gl.TEXTURE_2D, btex);
          gl.pixelStorei(gl.UNPACK_ALIGNMENT, 2);
          gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 256, 224,
            gl.RED_INTEGER, gl.UNSIGNED_SHORT, bview);
          gl.activeTexture(gl.TEXTURE0);
        } else {
          gl.activeTexture(gl.TEXTURE1);
          gl.bindTexture(gl.TEXTURE_2D, btex);
          gl.activeTexture(gl.TEXTURE0);
        }
      }
      gl.viewport(0, 0, canvasEl.width, canvasEl.height);
      gl.useProgram(prog);
      gl.uniform1i(uColorCorrect, opts.colorCorrect ? 1 : 0);
      gl.uniform1i(uPanelGbc, opts.panelGbc ? 1 : 0);
      gl.uniform1i(uGrid, opts.grid ? 1 : 0);
      gl.uniform1i(uSubpixel, opts.subpixel ? 1 : 0);
      // Grid/subpixel pitch follows the OUTPUT size, the game texture
      // does not.
      gl.uniform1f(uScanHeight, oh);
      gl.uniform1f(uScanWidth, ow);
      gl.uniform2f(uTexSize, w, h);
      gl.uniform1i(uBorderTex, 1);
      gl.uniform1i(uSgbBorder, border ? 1 : 0);
      if (border) {
        const bd = Module._wasm_sgb_backdrop ? Module._wasm_sgb_backdrop() : 0;
        gl.uniform3f(uSgbBackdrop, (bd & 31) / 31,
          ((bd >> 5) & 31) / 31, ((bd >> 10) & 31) / 31);
      }
      gl.uniform1i(uFilter, opts.filter === "hq4x" ? 1 : opts.filter === "xbr" ? 2 : 0);
      // opts.dmgPalette: four "#rrggbb" strings (shade 0 -> 3) or null/absent.
      const pal = opts.dmgPalette;
      const remap = !!(pal && pal.length === 4);
      gl.uniform1i(uDmgRemap, remap ? 1 : 0);
      if (remap) {
        for (let i = 0; i < 4; i++) {
          const n = parseInt(String(pal[i]).replace("#", ""), 16) || 0;
          dmgPalBuf[i * 3] = ((n >> 16) & 255) / 255;
          dmgPalBuf[i * 3 + 1] = ((n >> 8) & 255) / 255;
          dmgPalBuf[i * 3 + 2] = (n & 255) / 255;
        }
        gl.uniform3fv(uDmgPal, dmgPalBuf);
      }
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    },
  };
}

// --- Ambient glow composer ---
// The glow behind the game is a coarse sample of the picture, blurred and
// faded to a soft ellipse. It was CSS (filter: blur(32px) plus a radial
// mask-image), and the game canvas repaints over it every frame, so the
// compositor re-ran that blur and mask on every frame: +0.25-0.65 ms of
// GPU-process work per frame on an M2 (docs/settings-cost.md). Here it is
// composed once per sample (10 Hz), and not at all while the picture holds
// still, on a grid of a few dozen texels; the compositor only stretches a
// bitmap. The model is the CSS it replaced, in the element's own CSS pixels:
// the sw x sh sample stretched bilinearly over the box, a Gaussian of sigma
// 32 px with nothing outside the box, then radial-gradient(ellipse at
// center, black 40%, transparent 78%) as alpha.
function createGlowComposer(sw, sh) {
  const SIGMA_CSS = 32;
  const TEXELS_PER_SIGMA = 1.6;      // the grid only has to hold a blurred image
  const SETTLED = 0.25;              // largest change, in 8-bit levels, not redrawn
  const MIN_SIGMA = 0.8;             // a sampled Gaussian narrower than this is not one
  const ema = new Float32Array(sw * sh * 3);
  let gw = 0, gh = 0, lw = 0, lh = 0, img = null, dirty = true;
  let work = null, lo = null, lotmp = null;
  let ksx = null, ksy = null, kSigX = 0, kSigY = 0, losum = null, alpha = null;
  let ux0 = null, ux1 = null, ufx = null, uy0 = null, uy1 = null, ufy = null;
  let sx0 = null, sx1 = null, fx = null, sy0 = null, sy1 = null, fy = null;

  const gauss = (sigma) => {
    const rad = Math.ceil(3 * sigma);
    const k = new Float32Array(2 * rad + 1);
    let sum = 0;
    for (let i = -rad; i <= rad; i++) sum += (k[i + rad] = Math.exp(-(i * i) / (2 * sigma * sigma)));
    for (let i = 0; i < k.length; i++) k[i] /= sum;
    return k;
  };
  // Weight of the kernel that lands inside [0, n) from texel i: the blur of
  // the box's own (opaque) alpha.
  const coverage = (k, n) => {
    const rad = (k.length - 1) >> 1, out = new Float32Array(n);
    for (let i = 0; i < n; i++)
      for (let j = -rad; j <= rad; j++) if (i + j >= 0 && i + j < n) out[i] += k[j + rad];
    return out;
  };
  // Bilinear source taps for a stretch of `src` texels over `dst`, edges
  // clamped, centres aligned (what the browser does to a stretched canvas).
  const taps = (src, dst) => {
    const i0 = new Int32Array(dst), i1 = new Int32Array(dst), f = new Float32Array(dst);
    for (let i = 0; i < dst; i++) {
      const s = Math.min(src - 1, Math.max(0, (i + 0.5) * src / dst - 0.5));
      i0[i] = Math.floor(s); i1[i] = Math.min(src - 1, i0[i] + 1); f[i] = s - i0[i];
    }
    return [i0, i1, f];
  };
  // Bilinear stretch of a 3-channel (w x h) plane into (dw x dh), given taps.
  const stretch = (from, w, to, dw, dh, x0, x1, xf, y0, y1, yf) => {
    for (let y = 0; y < dh; y++) {
      const a0 = y0[y] * w, a1 = y1[y] * w, wy = yf[y];
      for (let x = 0; x < dw; x++) {
        const wx = xf[x], q = (y * dw + x) * 3;
        const p00 = (a0 + x0[x]) * 3, p01 = (a0 + x1[x]) * 3;
        const p10 = (a1 + x0[x]) * 3, p11 = (a1 + x1[x]) * 3;
        const w00 = (1 - wx) * (1 - wy), w01 = wx * (1 - wy);
        const w10 = (1 - wx) * wy, w11 = wx * wy;
        to[q] = from[p00] * w00 + from[p01] * w01 + from[p10] * w10 + from[p11] * w11;
        to[q + 1] = from[p00 + 1] * w00 + from[p01 + 1] * w01 + from[p10 + 1] * w10 + from[p11 + 1] * w11;
        to[q + 2] = from[p00 + 2] * w00 + from[p01 + 2] * w01 + from[p10 + 2] * w10 + from[p11 + 2] * w11;
      }
    }
  };

  return {
    // Grid for a box of cssW x cssH CSS pixels; returns [w, h] for the
    // canvas. An unchanged box costs nothing.
    layout(cssW, cssH, ctx) {
      if (!(cssW > 0 && cssH > 0)) return [gw, gh];
      const w = Math.max(32, Math.min(64, Math.round(TEXELS_PER_SIGMA * cssW / SIGMA_CSS)));
      const h = Math.max(16, Math.min(64, Math.round(w * cssH / cssW)));
      // Blur and stretch are both linear, so the blur runs on the sample
      // (sigma in its cells; a big box first stretches it 2x or more so the
      // kernel stays a Gaussian) and the stretch to the grid follows. The
      // colour is renormalised by the kernel weight inside the box; the
      // alpha, the blurred box edge times the ellipse, is exact on the grid.
      const mx = Math.ceil(MIN_SIGMA * cssW / (SIGMA_CSS * sw));
      const my = Math.ceil(MIN_SIGMA * cssH / (SIGMA_CSS * sh));
      const sigX = SIGMA_CSS * sw * mx / cssW, sigY = SIGMA_CSS * sh * my / cssH;
      if (w === gw && h === gh && lw === sw * mx && lh === sh * my &&
          Math.abs(kSigX - sigX) < 0.02 && Math.abs(kSigY - sigY) < 0.02) return [gw, gh];
      gw = w; gh = h; lw = sw * mx; lh = sh * my; dirty = true;
      ksx = gauss(sigX); kSigX = sigX;
      ksy = gauss(sigY); kSigY = sigY;
      const lcx = coverage(ksx, lw), lcy = coverage(ksy, lh);
      losum = new Float32Array(lw * lh);
      for (let y = 0; y < lh; y++) for (let x = 0; x < lw; x++) losum[y * lw + x] = lcx[x] * lcy[y];
      work = new Float32Array(lw * lh * 3);
      lo = new Float32Array(lw * lh * 3); lotmp = new Float32Array(lw * lh * 3);
      [ux0, ux1, ufx] = taps(sw, lw);
      [uy0, uy1, ufy] = taps(sh, lh);
      const cx = coverage(gauss(SIGMA_CSS * gw / cssW), gw);
      const cy = coverage(gauss(SIGMA_CSS * gh / cssH), gh);
      alpha = new Float32Array(gw * gh);
      for (let y = 0; y < gh; y++) {
        const v = (y + 0.5) / gh - 0.5;
        for (let x = 0; x < gw; x++) {
          const u = (x + 0.5) / gw - 0.5;
          // farthest-corner ellipse: radii sqrt(2) x the half box
          const t = Math.SQRT2 * Math.sqrt(u * u + v * v);
          alpha[y * gw + x] = 255 * Math.min(1, Math.max(0, (0.78 - t) / 0.38)) * cx[x] * cy[y];
        }
      }
      [sx0, sx1, fx] = taps(lw, gw);
      [sy0, sy1, fy] = taps(lh, gh);
      img = ctx.createImageData(gw, gh);
      return [gw, gh];
    },
    // One sample: `rgba` is sw x sh RGBA8888. Saturation x1.5 (luma kept),
    // then blended over the running picture at 0.3, or taken whole when
    // `fresh`. Draws the composed glow into ctx, unless nothing moved.
    compose(rgba, ctx, fresh) {
      if (!img) return;
      let moved = 0;
      for (let i = 0, o = 0; i < sw * sh * 4; i += 4, o += 3) {
        const R = rgba[i], G = rgba[i + 1], B = rgba[i + 2];
        const luma = 0.299 * R + 0.587 * G + 0.114 * B;
        const s0 = Math.min(255, Math.max(0, luma + (R - luma) * 1.5));
        const s1 = Math.min(255, Math.max(0, luma + (G - luma) * 1.5));
        const s2 = Math.min(255, Math.max(0, luma + (B - luma) * 1.5));
        if (fresh) { ema[o] = s0; ema[o + 1] = s1; ema[o + 2] = s2; continue; }
        const d0 = (s0 - ema[o]) * 0.3, d1 = (s1 - ema[o + 1]) * 0.3, d2 = (s2 - ema[o + 2]) * 0.3;
        ema[o] += d0; ema[o + 1] += d1; ema[o + 2] += d2;
        moved = Math.max(moved, Math.abs(d0), Math.abs(d1), Math.abs(d2));
      }
      if (!fresh && !dirty && moved < SETTLED) return;
      dirty = false;
      // The sample at blur resolution (itself, when the box is small enough).
      let src = ema;
      if (lw !== sw || lh !== sh) {
        stretch(ema, sw, work, lw, lh, ux0, ux1, ufx, uy0, uy1, ufy);
        src = work;
      }
      // Blur: rows, then columns, zero outside the box, renormalised.
      const rx = (ksx.length - 1) >> 1, ry = (ksy.length - 1) >> 1;
      for (let y = 0; y < lh; y++) {
        for (let x = 0; x < lw; x++) {
          let s0 = 0, s1 = 0, s2 = 0;
          const j0 = Math.max(-rx, -x), j1 = Math.min(rx, lw - 1 - x);
          for (let j = j0; j <= j1; j++) {
            const k = ksx[j + rx], p = (y * lw + x + j) * 3;
            s0 += src[p] * k; s1 += src[p + 1] * k; s2 += src[p + 2] * k;
          }
          const q = (y * lw + x) * 3;
          lotmp[q] = s0; lotmp[q + 1] = s1; lotmp[q + 2] = s2;
        }
      }
      for (let y = 0; y < lh; y++) {
        const j0 = Math.max(-ry, -y), j1 = Math.min(ry, lh - 1 - y);
        for (let x = 0; x < lw; x++) {
          let s0 = 0, s1 = 0, s2 = 0;
          for (let j = j0; j <= j1; j++) {
            const k = ksy[j + ry], p = ((y + j) * lw + x) * 3;
            s0 += lotmp[p] * k; s1 += lotmp[p + 1] * k; s2 += lotmp[p + 2] * k;
          }
          const n = 1 / losum[y * lw + x], q = (y * lw + x) * 3;
          lo[q] = s0 * n; lo[q + 1] = s1 * n; lo[q + 2] = s2 * n;
        }
      }
      // Stretch to the grid; the alpha is precomputed.
      const d = img.data;
      for (let y = 0; y < gh; y++) {
        const a0 = sy0[y] * lw, a1 = sy1[y] * lw, wy = fy[y];
        for (let x = 0; x < gw; x++) {
          const wx = fx[x];
          const p00 = (a0 + sx0[x]) * 3, p01 = (a0 + sx1[x]) * 3;
          const p10 = (a1 + sx0[x]) * 3, p11 = (a1 + sx1[x]) * 3;
          const w00 = (1 - wx) * (1 - wy), w01 = wx * (1 - wy);
          const w10 = (1 - wx) * wy, w11 = wx * wy;
          const k = y * gw + x, i = k * 4;
          d[i] = lo[p00] * w00 + lo[p01] * w01 + lo[p10] * w10 + lo[p11] * w11;
          d[i + 1] = lo[p00 + 1] * w00 + lo[p01 + 1] * w01 + lo[p10 + 1] * w10 + lo[p11 + 1] * w11;
          d[i + 2] = lo[p00 + 2] * w00 + lo[p01 + 2] * w01 + lo[p10 + 2] * w10 + lo[p11 + 2] * w11;
          d[i + 3] = alpha[k];
        }
      }
      ctx.putImageData(img, 0, 0);
    },
  };
}
