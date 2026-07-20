// Shared test helper: pulls the REAL WebGL2 present shaders out of
// web/glpresent.js so both the pure-JS UV unit test (uv.test.mjs) and the
// headless-Chromium GL readback test (render.test.mjs) exercise the exact GLSL
// that ships — not a reimplementation. A future edit to createGlRenderer's
// VERT/FRAG in glpresent.js is therefore what is under test: change the shader
// and these tests move with it. (The shaders lived in index.js until they were
// factored into glpresent.js, shared by the main page and the embed.)
//
// Motivation: a vertex-shader UV bug (`v_uv = p*0.5`, the fullscreen-triangle
// UVs halved) made every ROM render as only the bottom-left quadrant zoomed 2x
// and SHIPPED, because nothing asserted the rendered pixels matched the source
// frame. Fixed in bb7561b (`v_uv = vec2(p.x, 1.0 - p.y)`). These helpers make
// that whole class (quadrant / Y-flip / scale / wrong upload dims) catchable.
//
// Zero runtime dependencies; reads glpresent.js as text at import time.

import { readFileSync } from "node:fs";

const PRESENT_JS = new URL("./glpresent.js", import.meta.url);

// Extract the first backtick-delimited template literal assigned to `name`.
// The shader literals contain no nested backticks, so a non-greedy match to the
// next backtick is exact.
function extractLiteral(src, name) {
  const re = new RegExp("const\\s+" + name + "\\s*=\\s*`([\\s\\S]*?)`");
  const m = src.match(re);
  if (!m) throw new Error(`could not find shader literal '${name}' in glpresent.js`);
  return m[1];
}

export function readShaders() {
  const src = readFileSync(PRESENT_JS, "utf8");
  return { VERT: extractLiteral(src, "VERT"), FRAG: extractLiteral(src, "FRAG"), src };
}

// --- Pure-JS mirror of the vertex-shader UV math (Layer 2 tripwire) ----------
//
// The GLSL builds a fullscreen triangle from gl_VertexID and assigns v_uv from
// `p`. We evaluate the ACTUAL `v_uv = <expr>;` expression pulled from index.js
// (not a hardcoded copy) so the buggy `p*0.5` form and the correct
// `vec2(p.x, 1.0 - p.y)` form give genuinely different results here.

// p per vertex id: vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)).
// This is the standard fullscreen-triangle position; it was never the bug and
// is not what these tests guard, so it is reproduced directly.
export function pForVertex(id) {
  return [(id << 1) & 2, id & 2];
}

// clip position = p * 2.0 - 1.0  (the gl_Position.xy in the VERT).
export function clipForVertex(id) {
  const [px, py] = pForVertex(id);
  return [px * 2 - 1, py * 2 - 1];
}

// Grab the `v_uv = <expr>;` right-hand side from a VERT source string.
export function uvExpr(vert) {
  const m = vert.match(/v_uv\s*=\s*([^;]+);/);
  if (!m) throw new Error("no `v_uv = ...;` assignment found in VERT");
  return m[1].trim();
}

// Split a top-level comma-separated arg list (no nested parens in our exprs,
// but handle them anyway for robustness).
function splitTopComma(s) {
  const out = [];
  let depth = 0, start = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "(") depth++;
    else if (c === ")") depth--;
    else if (c === "," && depth === 0) { out.push(s.slice(start, i)); start = i + 1; }
  }
  out.push(s.slice(start));
  return out.map((x) => x.trim());
}

// Evaluate a scalar GLSL arithmetic expression in p.x / p.y with numeric px,py.
function evalScalar(expr, px, py) {
  const js = expr
    .replace(/p\.x/g, `(${px})`)
    .replace(/p\.y/g, `(${py})`);
  if (!/^[-+*/(). 0-9eE]+$/.test(js))
    throw new Error(`refusing to evaluate unexpected UV expression: '${expr}'`);
  return Function(`"use strict";return (${js});`)();
}

// Evaluate the v_uv expression for a given vertex, returning [u, v].
// Handles the two shapes the shader has taken:
//   vec2(A, B)   — component form (the fixed shader)
//   p * S  / p   — whole-vector form applied per component (the p*0.5 bug)
export function uvForVertexFromExpr(expr, id) {
  const [px, py] = pForVertex(id);
  const vec = expr.match(/^vec2\(([\s\S]*)\)$/);
  if (vec) {
    const [a, b] = splitTopComma(vec[1]);
    return [evalScalar(a, px, py), evalScalar(b, px, py)];
  }
  // Whole-vector expression: substitute the vector p with each component.
  const comp = (n) => {
    const js = expr.replace(/\bp\b/g, `(${n})`);
    if (!/^[-+*/(). 0-9eE]+$/.test(js))
      throw new Error(`refusing to evaluate unexpected UV expression: '${expr}'`);
    return Function(`"use strict";return (${js});`)();
  };
  return [comp(px), comp(py)];
}

// Interpolate v_uv at an arbitrary clip-space point using barycentric weights of
// the fullscreen triangle. w=1 for every vertex, so linear (affine) interpolation
// is exact — no perspective divide. This reproduces what the GPU rasterizer does
// for the fragment at that clip position, giving us the texture UV the visible
// screen corner samples.
export function uvAtClip(expr, clipPt) {
  const A = clipForVertex(0), B = clipForVertex(1), C = clipForVertex(2);
  const uvA = uvForVertexFromExpr(expr, 0);
  const uvB = uvForVertexFromExpr(expr, 1);
  const uvC = uvForVertexFromExpr(expr, 2);
  const [px, py] = clipPt;
  const v0 = [B[0] - A[0], B[1] - A[1]];
  const v1 = [C[0] - A[0], C[1] - A[1]];
  const v2 = [px - A[0], py - A[1]];
  const d00 = v0[0] * v0[0] + v0[1] * v0[1];
  const d01 = v0[0] * v1[0] + v0[1] * v1[1];
  const d11 = v1[0] * v1[0] + v1[1] * v1[1];
  const d20 = v2[0] * v0[0] + v2[1] * v0[1];
  const d21 = v2[0] * v1[0] + v2[1] * v1[1];
  const denom = d00 * d11 - d01 * d01;
  const b = (d11 * d20 - d01 * d21) / denom; // weight of B
  const c = (d00 * d21 - d01 * d20) / denom; // weight of C
  const a = 1 - b - c;                        // weight of A
  return [
    a * uvA[0] + b * uvB[0] + c * uvC[0],
    a * uvA[1] + b * uvB[1] + c * uvC[1],
  ];
}
