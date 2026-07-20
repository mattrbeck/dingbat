// --- Shared WebGL2 game presenter ---
// The single place that turns the wasm core's raw BGR555 framebuffer into
// pixels on a canvas. Both the main page (index.js) and the embed (embed.js)
// call this so the embed can never silently fall behind the main renderer
// again (it did: commit 4c4a3e9 moved presentation off SDL into JS but only
// wired up index.js, leaving the embed a black frame).
//
// Deps are injected so this file has no DOM/globals of its own beyond the
// wasm Module: canvasEl is the VISIBLE canvas we own a WebGL2 context on
// (SDL must render to a different, hidden canvas); nativeRes() -> [w,h] gives
// the core's native pixel size; log(msg) reports GL errors.
function createGlRenderer(canvasEl, nativeRes, log) {
  let gl = null, prog = null, tex = null, lost = false;
  let uColorCorrect, uPanelGbc, uScanlines, uTexHeight, uTexSize, uFilter;
  let lastW = 0, lastH = 0;

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

  // The hq4x / xBR branches are CLEAN-ROOM implementations from published
  // algorithm descriptions (Hyllian's xBR tutorial: YUV 48:7:6 distance and the
  // wd_red<wd_blue edge rule; ubitux's "Butchering HQX" write-up + Wikipedia for
  // the hqx per-channel YUV threshold). No GPL/LGPL shader source was copied.
  // Same math as the desktop GL 3.3 shader (src/dingbat.nim FRAG_SRC).
  const FRAG = `#version 300 es
precision highp float;
precision highp int;
precision highp usampler2D;
in vec2 v_uv;
out vec4 frag_color;
uniform usampler2D u_tex;       // R16UI: raw BGR555 pixels
uniform bool u_color_correct;
uniform bool u_panel_gbc;       // CGB color model vs AGB
uniform bool u_scanlines;
uniform float u_tex_height;     // native rows (for scanline pitch)
uniform vec2 u_tex_size;        // native texel dimensions (w, h)
uniform int u_filter;           // 0 = none, 1 = hq4x, 2 = xBR

ivec2 g_max;
vec3 fetchRGB(ivec2 p) {
  uint packed = texelFetch(u_tex, clamp(p, ivec2(0), g_max), 0).r;
  return vec3(float(packed & 31u),
              float((packed >> 5) & 31u),
              float((packed >> 10) & 31u)) / 31.0;
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

vec3 upscale() {
  g_max = ivec2(u_tex_size) - ivec2(1);
  vec2 pos  = v_uv * u_tex_size;
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

void main() {
  vec3 c = upscale();
  float outGamma = 2.2;
  vec3 rgb;
  if (u_color_correct) {
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
        0.0 * lin.b +  50.0 * lin.g + 255.0 * lin.r,
       30.0 * lin.b + 230.0 * lin.g +  10.0 * lin.r,
      220.0 * lin.b +  10.0 * lin.g +  50.0 * lin.r) / 255.0,
        vec3(1.0 / outGamma));
    }
  } else {
    rgb = c;
  }
  if (u_scanlines && fract(v_uv.y * u_tex_height) < 0.3) {
    rgb *= 0.72;
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
    uScanlines = gl.getUniformLocation(prog, "u_scanlines");
    uTexHeight = gl.getUniformLocation(prog, "u_tex_height");
    uTexSize = gl.getUniformLocation(prog, "u_tex_size");
    uFilter = gl.getUniformLocation(prog, "u_filter");
    tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    // Integer textures must use NEAREST filtering.
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    lastW = 0; lastH = 0;
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
    draw(opts) {
      if (!ensure()) return;
      const ptr = Module._wasm_game_fb_ptr && Module._wasm_game_fb_ptr();
      if (!ptr) return;
      const [w, h] = nativeRes();
      // Fresh view each frame: ALLOW_MEMORY_GROWTH can detach the old buffer.
      const view = new Uint16Array(Module.memory.buffer, ptr, w * h);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 2);
      if (w !== lastW || h !== lastH) {
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16UI, w, h, 0,
          gl.RED_INTEGER, gl.UNSIGNED_SHORT, view);
        lastW = w; lastH = h;
      } else {
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, w, h,
          gl.RED_INTEGER, gl.UNSIGNED_SHORT, view);
      }
      gl.viewport(0, 0, canvasEl.width, canvasEl.height);
      gl.useProgram(prog);
      gl.uniform1i(uColorCorrect, opts.colorCorrect ? 1 : 0);
      gl.uniform1i(uPanelGbc, opts.panelGbc ? 1 : 0);
      gl.uniform1i(uScanlines, opts.scanlines ? 1 : 0);
      gl.uniform1f(uTexHeight, h);
      gl.uniform2f(uTexSize, w, h);
      gl.uniform1i(uFilter, opts.filter === "hq4x" ? 1 : opts.filter === "xbr" ? 2 : 0);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    },
  };
}
