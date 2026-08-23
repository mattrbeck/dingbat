// Test helper: extracts the shipped VERT/FRAG from web/glpresent.js so
// uv.test.mjs and render.test.mjs exercise the real GLSL, not a copy. Pins
// the halved-UV regression (`v_uv = p*0.5` rendered only the bottom-left
// quadrant at 2x; fixed bb7561b) and its class: quadrant, Y-flip, scale,
// wrong upload dims.

import { readFileSync } from "node:fs";

const PRESENT_JS = new URL("./glpresent.js", import.meta.url);

// The shader literals contain no nested backticks, so a non-greedy match
// to the next backtick is exact.
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

// Pure-JS mirror of the vertex shader's UV math. The `v_uv = <expr>;`
// expression is evaluated from the extracted source, not a hardcoded copy.

// p per vertex id: vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)),
// the standard fullscreen-triangle position.
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

// Split a top-level comma-separated arg list (paren-aware).
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

// [u, v] for a vertex. Handles both shapes: vec2(A, B) (component form) and
// a whole-vector expression in p (the p*0.5 bug), applied per component.
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

// v_uv at a clip-space point by barycentric interpolation over the
// fullscreen triangle. w=1 at every vertex, so affine interpolation is exact
// (what the rasterizer does for that fragment).
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
