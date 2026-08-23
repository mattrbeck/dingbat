// Pure-JS UV tripwire (no browser) for the present vertex shader in
// web/glpresent.js: evaluates the shipped `v_uv = ...;` expression (via
// glshaders.mjs), interpolates it at the four visible clip corners as the
// rasterizer would, and asserts the screen maps to the full [0,1] texture
// with row 0 at the top. Pins the halved-UV bug (`v_uv = p*0.5`, bb7561b).
//
//     clip corner   screen        expected v_uv
//     (-1,-1)       bottom-left   (0, 1)
//     ( 1,-1)       bottom-right  (1, 1)
//     (-1, 1)       top-left      (0, 0)
//     ( 1, 1)       top-right     (1, 0)
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
  {
    const [u, v] = uvAtClip(expr, [0, 0]);
    assertClose(u, 0.5, "center clip (0,0): u = 0.5");
    assertClose(v, 0.5, "center clip (0,0): v = 0.5");
  }

  // The same assertion against the known-buggy expressions must fail.
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
