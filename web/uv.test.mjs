// Layer 2 — fast pure-JS UV-math tripwire (no browser).
//
// Guards the WebGL2 present vertex shader in web/index.js against the class of
// bug that shipped: the fullscreen-triangle UVs were halved (`v_uv = p*0.5`),
// so the visible screen sampled only the bottom-left quadrant of the source
// frame zoomed 2x. Fixed in bb7561b to `v_uv = vec2(p.x, 1.0 - p.y)`.
//
// This test pulls the ACTUAL `v_uv = ...;` expression out of index.js (via
// glshaders.mjs) and evaluates it, then interpolates v_uv at the four VISIBLE
// clip-space corners the same way the GPU rasterizer would. It asserts the
// visible screen maps to the FULL [0,1] texture with row 0 at the TOP:
//
//     clip corner        screen position     expected v_uv
//     (-1,-1)  bottom-left                    (0, 1)
//     ( 1,-1)  bottom-right                   (1, 1)
//     (-1, 1)  top-left                       (0, 0)   <- row 0 at top (Y-flip)
//     ( 1, 1)  top-right                      (1, 0)
//
// Run against the buggy `p*0.5` shader this FAILS; against the fix it PASSES.
//
// Zero dependencies, mirroring web/sdputil.test.mjs / signaling/server.test.mjs:
// a plain assert() helper, a single run(), non-zero exit on any failure.
//
// Run:  node web/uv.test.mjs

import { readShaders, uvExpr, uvAtClip } from "./glshaders.mjs";

let failures = 0;
function assert(cond, msg) {
  if (cond) { console.log(`  ok: ${msg}`); return; }
  failures++;
  console.error(`  FAIL: ${msg}`);
}

const EPS = 1e-9;
function assertClose(a, b, msg) {
  assert(Math.abs(a - b) < EPS, `${msg} (got ${a}, want ${b})`);
}

// The four visible clip-space corners and the UV each must sample.
const CORNERS = [
  { name: "bottom-left  (-1,-1)", clip: [-1, -1], uv: [0, 1] },
  { name: "bottom-right ( 1,-1)", clip: [1, -1], uv: [1, 1] },
  { name: "top-left     (-1, 1)", clip: [-1, 1], uv: [0, 0] },
  { name: "top-right    ( 1, 1)", clip: [1, 1], uv: [1, 0] },
];

function checkExpr(expr, label) {
  console.log(`${label}: v_uv = ${expr}`);
  let allGood = true;
  for (const c of CORNERS) {
    const [u, v] = uvAtClip(expr, c.clip);
    const ok = Math.abs(u - c.uv[0]) < EPS && Math.abs(v - c.uv[1]) < EPS;
    if (!ok) allGood = false;
    console.log(
      `    ${c.name} -> uv (${u.toFixed(3)}, ${v.toFixed(3)})` +
      `  want (${c.uv[0]}, ${c.uv[1]})  ${ok ? "ok" : "MISMATCH"}`
    );
  }
  return allGood;
}

async function run() {
  const { VERT } = readShaders();
  const expr = uvExpr(VERT);

  console.log("the SHIPPING shader (extracted from index.js) maps the visible");
  console.log("screen to the full texture with row 0 at the top:");
  for (const c of CORNERS) {
    const [u, v] = uvAtClip(expr, c.clip);
    assertClose(u, c.uv[0], `${c.name}: u`);
    assertClose(v, c.uv[1], `${c.name}: v`);
  }
  // Center of the screen samples the center of the texture.
  {
    const [u, v] = uvAtClip(expr, [0, 0]);
    assertClose(u, 0.5, "center clip (0,0): u = 0.5");
    assertClose(v, 0.5, "center clip (0,0): v = 0.5");
  }

  // Red/green proof, in-test: the same assertion evaluated against the KNOWN
  // buggy expressions must FAIL. This documents that the test actually catches
  // the shipped bug, independent of the live index.js contents.
  console.log("\nregression witnesses (these buggy shaders MUST NOT pass):");
  {
    const shipped = checkExpr(expr, "shipping index.js");
    assert(shipped, "shipping shader passes all four corners");

    const buggyScalar = checkExpr("p*0.5", "the ORIGINAL bug  `p*0.5`");
    assert(!buggyScalar, "`p*0.5` is REJECTED (would render bottom-left quadrant)");

    const buggyVec = checkExpr(
      "vec2(p.x*0.5, 1.0 - p.y*0.5)",
      "the halved-vec2 bug"
    );
    assert(!buggyVec, "`vec2(p.x*0.5, 1.0 - p.y*0.5)` is REJECTED");

    const noFlip = checkExpr("vec2(p.x, p.y)", "no Y-flip  `vec2(p.x, p.y)`");
    assert(!noFlip, "missing Y-flip is REJECTED (top/bottom would swap)");
  }

  if (failures) { console.error(`\n${failures} assertion(s) failed`); process.exit(1); }
  console.log("\nall UV-math tests passed");
}

run().catch((e) => { console.error(e); process.exit(1); });
