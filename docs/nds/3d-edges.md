# DS 3D engine: polygon edges, anti-aliasing and edge marking

How the DS 3D engine draws a polygon's edges, what it mixes them with, and
the artifacts that come with it; what dingbat did before, what it does now,
the evidence, and what is still open. Hardware facts are GBATEK ("DS 3D
Rendering", "Toon, Edge, Fog, Alpha-Blending, Anti-Aliasing", "Polygon
Attributes", "DISP_1DOT_DEPTH") unless marked; values settled by black-box
reference runs are rows in docs/oracles.md ("### NDS 3D engine"); the rest
is marked Assumed. Code: `src/dingbat/nds/gpu3d/render.nim` (rasteriser,
post passes), `gpu3d/geometry.nim` (1-dot culling, clipping).

## Evidence used

- **GBATEK** (decides where it is explicit: polygon size, edge-marking
  neighbour test, 1-dot depth, alpha 31 for wire-frame lines, AA on
  lines/wire-frames and not on translucent polygons).
- **Hardware captures**: StrikerX3/nds-interp's line captures (images and
  the capture program only): a white wire-frame "line" from each screen
  corner to every (x, y), 4 x 49601 display captures. `capstool`-style
  replay of all four sets through our engine (scratch tool, not in the
  repo): 48281 of 49601 exact in each set (97.3 %), mirror-symmetric.
- **Probe ROMs** (`tests/nds/src/3d_probe_*`, built by
  `tests/nds/tools/build_3d.sh`, hashed in `tests/nds_3d_test.nim`) run
  through `tools/ndsref` (melonDS DS 1.4, melonDS 0.9.3) and compared at
  18-bit colour with our 3D buffer. New this round: `_aa3` / `_aa3_edge` /
  `_aa3_em` (what an AA edge mixes with), `_aa4` (long shallow x-major
  edges), `_degen` / `_degen_aa` / `_degen_edge` (zero-width polygons),
  `_edge2` (edge marking corner cases), `_dot` (1-dot polygons and
  DISP_1DOT_DEPTH), `_xlu_seam` / `_xlu_seam_nb` (translucent seams),
  `_ztie` (depth ties at an apex).
- **Pokemon SoulSilver** (run only): the bedroom (frame 6600), the
  kitchen (8000), the title's 3D Lugia (bottom screen, frame ~860), with
  the p12 input script, against the reference core.

## Edge rules (which dots a polygon covers)

Unchanged from the previous round except for zero-area polygons; recorded
here as the full rule set.

- Edge x on row y: `X(y) = x0 << 18 + dx * floor(2^18 / dy) * (y - y0)`,
  minus one unit when x decreases; exactly +-1.0 per row at 45 degrees.
- x-major edges (|dx| > dy) cover, per row, the dots whose centres lie in
  [X(y), X(y+1)] (rounded half up); other edges the dot holding X(y); a
  vertical right edge covers the dot left of it (its own column is out).
- Polygon size (GBATEK "Polygon Size"): opaque polygons without edge
  marking or anti-aliasing (and translucent ones with blending off) drop
  their bottom x-major runs and right y-major dots, except on the row
  above a flat bottom; everything else is full size. Rows run from the top
  vertex row to the row above the bottom vertex row.
- Wire-frames (alpha 0) draw the two runs per row, plus the whole top row
  and the row above a flat bottom; their dots are alpha 31 whatever the
  texel alpha (a transparent direct-colour texel shows its colour).
- Line segments (vertices on at most two dots) are drawn full size.
- **Zero-area polygons (new).** Games close the gaps where walls meet with
  polygons whose vertices all lie on one line (SoulSilver's bedroom has
  folded zero-width quads at x = 40 and 200). They follow the opaque size
  rules, but where the left run is dropped the right x-major run is drawn
  whole (it is not clipped to start after the left run); where the two
  edges coincide, the edge that runs forward in vertex order from the top
  vertex is the left one, so its colour, texcoords and depth are the ones
  shown (3d_probe_degen: 213 -> 0 dots).
- 1-dot polygons (all vertices on one dot) are dropped unless a vertex has
  w <= DISP_1DOT_DEPTH or POLYGON_ATTR.13 is set; 1x0 / 0x1 polygons are
  not checked; the dot takes the first vertex's attributes (3d_probe_dot,
  exact; unchanged).

Seams: adjacent opaque polygons sharing an edge neither overlap nor leave
gaps under the small-polygon rule (the bottom/right runs of one are the
top/left runs of the next); with edge marking or AA on, both draw the
shared edge and the later one loses the depth tie. Translucent polygons
with blending on are full size, so a shared edge is drawn twice and
blends twice unless the dot already holds the polygon's ID (one ID per
mesh hides the seam) or a depth-updating polygon made the second fail the
depth test (3d_probe_xlu_seam: bright seams between IDs, none within one;
exact).

## Anti-aliasing (DISP3DCNT.4)

GBATEK: opaque polygon edges get partial coverage; translucent polygons
are not anti-aliased; lines, wire-frames and 1-dot polygons are
("accidentally"); edge-marked edges go on translucent at about alpha 16.

| | Before | Now (reference runs) |
|---|---|---|
| What an edge dot mixes with | the colour it was drawn over, only where a 4-neighbour had another ID and lay further | a second layer per dot: the nearest opaque colour behind the top one, whatever the drawing order; hidden dots still land there when nearer, translucent polygons blend into both layers; no ID condition (3d_probe_aa3 exact) |
| Lines, wire-frames | no AA | AA'd like any edge: dotted, faded lines (3d_aa) |
| Under translucent polygons | AA skipped | AA still applies (both layers tinted) |
| x-major coverage | exact area at the dot centre | a 10-bit height h at the dot centre from the run's exact left end, stepping floor((2^28 - 1) dy / (\|dx\| 2^18)) per dot; left edges h, right edges 1023 - h (measured from the end of the left run where they overlap); c = h >> 5 (3d_probe_aa4 643 -> 6 dots) |
| y-major coverage | where the edge crosses the row's middle within the dot: right floor(32 c), left 31 - floor(32 (1 - c)) | unchanged |
| Edge marking + AA | edge colour at 17/32 over the colour drawn over | over the layer behind (3d_probe_aa3_edge exact) |

So meshes of one ID show no seams because the neighbouring polygon *is*
the layer behind, not because of an ID rule: the old rule happened to
avoid seams but left mesh silhouettes against same-ID polygons hard
(SoulSilver's roof eaves and furniture outlines showed saw-tooth edges:
the dot at the end of each run had no coverage and showed the rear plane).

The second layer is kept only where the frame has AA on, and is only
written for dots whose top is a partly covered edge dot or an edge-flagged
dot (nothing else reads it). `below`/`below_depth` are per-frame scratch
(not in save states).

## Edge marking (DISP3DCNT.5)

Unchanged; the new probe confirms GBATEK and the existing implementation:
opaque edge dots (wire-frames included; the polygon's runs plus its top
and bottom rows) take EDGE_COLOR[ID / 8] when a 4-neighbour has another ID
and is strictly further; screen borders compare against the rear plane's
ID and depth (a polygon with the rear plane's ID shows no border edge);
the pass runs after translucent polygons, so the edge colour overwrites a
translucent colour, and a translucent polygon that updates depth hides
the edges under it ("malfunction", GBATEK); equal depth never marks
(3d_edge, 3d_probe_edge2, exact).

## Known artifacts the hardware itself produces

These are what the DS draws, and so what dingbat now draws:

- **Dotted / faded lines and wire-frames with AA on** (GBATEK; the
  reference runs agree; BlocksDS's tutorial warns lines "can become too
  faint to see"). Lines drawn translucent avoid it.
- **Seams between translucent polygons of different IDs**: shared edges
  blend twice (bright or dark lines across a mesh).
- **Gaps in shallow lines**: the hardware leaves a dot out of an x-major
  run when x(y+1) lands just above a half dot (the line captures; we draw
  that dot, see Open).
- **Small polygons**: opaque polygons without AA/edge marking lose their
  bottom/right edges; lone polygons look a dot short.
- **Edge marking at the screen border** when the polygon ID differs from
  the rear plane's; **edges vanishing under depth-writing translucent
  polygons**; **edge colour drawn over translucent polygons**.
- **AA'd edge-marked edges at half strength**, so outlines look softer
  with AA on (SoulSilver's objects).
- **Zero-width filler polygons** show at a wall's corner column where the
  forward edge's depth wins.

## Measurements

Dots of our 3D buffer differing from melonDS DS 1.4 at 18-bit colour
(frame 30); "before" is the start of this round (0f2beeea).

| ROM | before | now |
|---|---|---|
| 3d_aa | 777 | 31 |
| 3d_lines | 46 | 0 |
| 3d_probe_aa | 110 | 22 |
| 3d_probe_aa2 | 643 | 4 |
| 3d_probe_aa3 / _edge / _em (new) | 421 / 2357 / 0 | 0 / 0 / 0 |
| 3d_probe_aa4 (new) | 643 | 6 |
| 3d_probe_degen / _aa / _edge (new) | 213 / 117 / 0 | 0 / 0 / 0 |
| 3d_probe_edge2, _dot, _xlu_seam, _xlu_seam_nb (new) | 0 | 0 |
| 3d_probe_ztie (new) | 6 | 6 |
| every other 3d_* ROM | unchanged (hashes kept) | |

Pokemon SoulSilver against the reference core (whole top screen, p12):

| Frame | before | now | what is left |
|---|---|---|---|
| 6600 (bedroom) | 1061 (2.16 %) | 44 (0.09 %) | the character's shadow (30, texture), 3 apex dots (depth ties), 11 single dots |
| 8000 (kitchen + text box) | 1131 (2.30 %) | 328 (0.67 %) | text box (141, 2D timing), wallpaper texel seams (131, texcoords on a quad clipped at x = 256), shadow, single dots |
| title, bottom screen (our 860 vs reference 858) | 2493 (5.07 %) | 672 (1.37 %) | bubbles (2D sprites), one-step shading inside Lugia (lighting), a few spine edge dots |

## Open

- **Shallow-line gaps** (hardware captures, 1320 of 49601 per corner): the
  hardware leaves out the last dot of an x-major run when x(y+1) is at most
  502 / 2^18 above a half dot, but includes it when x(y+1) is exactly a
  half (dy a power of two); no bias or truncation of x(y+1) fits every
  capture. We draw the dot. The reference cores draw it too.
- **Depth at an apex** (3d_probe_ztie, 6 dots; SoulSilver 3 dots): where a
  polygon's apex dot ties a flat neighbour's depth, the reference shows
  the later polygon when it gets nearer from the apex; sampling edge depth
  at the row centre fixes those dots but breaks 3d_depth (58 dots), so the
  depth interpolation along edges is not pinned.
- **Coverage residue**: 3d_probe_aa 22, _aa2 4, _aa4 6, 3d_aa 31 dots, all
  one coverage step (y-major rounding, rows where both edges' runs share
  dots near a vertex).
- Not edges, found on the way: SoulSilver's wallpaper (a quad clipped at
  x = 256, texel boundaries one dot apart every 10 dots), the character's
  shadow (an alpha-8 textured quad, its ellipse a row longer here), and
  3d_clip's 86 dots are texcoord/clipping arithmetic.
