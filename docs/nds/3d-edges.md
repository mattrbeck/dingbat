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
  corner to every (x, y), 4 x 49601 display captures, replayed through
  our engine (a scratch tool; the captures are not in the repo): all
  198404 exact now (97.3 % at the start of this round, the rest single-dot
  gaps the hardware leaves in shallow lines). Where the captures and the
  reference cores disagree, the captures decide.
- **Probe ROMs** (`tests/nds/src/3d_probe_*`, built by
  `tests/nds/tools/build_3d.sh`, hashed in `tests/nds_3d_test.nim`) run
  through `tools/ndsref` (melonDS DS 1.4, melonDS 0.9.3) and compared at
  18-bit colour with our 3D buffer. New this round: `_aa3` / `_aa3_edge` /
  `_aa3_em` (what an AA edge mixes with), `_aa4` (long shallow x-major
  edges), `_degen` / `_degen_aa` / `_degen_edge` (zero-width polygons),
  `_edge2` (edge marking corner cases), `_dot` (1-dot polygons and
  DISP_1DOT_DEPTH), `_xlu_seam` / `_xlu_seam_nb` (translucent seams),
  `_ztie` (depth ties at an apex), `_zinterp` / `_x` / `_s` / `_y2`
  (depth interpolation read off flat strips), `_hwline` (captured lines
  with gaps, laid over the captures).
- **polyrastertest v1.0.2-b** (Jaklyy, MIT; docs/nds/test-roms.md, round
  6): 77 one-polygon scenes whose spans (and, for edge marking, colours)
  were recorded on a console and are built into the ROM; the test
  program's source gives each scene's vertices. The console was a New 3DS
  XL in DS mode: the DS 3D engine as the 3DS runs it; no difference from a
  DS is known, but none was checked. Its verdicts decide the rules below
  marked (polyrastertest N), N being the ROM's scene number; where they
  disagree with the reference cores, the recording wins.
- **Pokemon SoulSilver** (run only): the bedroom (frame 6600), the
  kitchen (8000), the title's 3D Lugia (bottom screen, frame ~860), with
  the p12 input script, against the reference core.

## Edge rules (which dots a polygon covers)

Rounds 4-5's rules, for the rows of a polygon that are not swapped (next
section); the round-5 additions marked **new**.

- Edge x on row y: `X(y) = x0 << 18 + dx * floor(2^18 / dy) * (y - y0)`,
  minus one unit when x decreases; exactly +-1.0 per row at 45 degrees.
- x-major edges (|dx| > dy) cover, per row, the dots whose centres lie in
  [X(y), X(y) + S] (rounded half up), where S is the slope with its low 9
  bits cleared: a run stops one dot short when X(y+1) passes a dot centre
  by less than (slope mod 512) / 2^18, leaving a gap between rows
  (**new**: the hardware captures, all exact with it; the reference cores
  end the run at X(y+1) and draw that dot: 3d_probe_hwline, 6 dots).
  Other edges cover the dot holding X(y); a vertical right edge covers the
  dot left of it (its own column is out).
- Polygon size (GBATEK "Polygon Size"): opaque polygons without edge
  marking or anti-aliasing (and translucent ones with blending off) drop
  their bottom x-major runs and right y-major dots, except on the row
  above a flat bottom; everything else is full size. Rows run from the top
  vertex row to the row above the bottom vertex row.
- Wire-frames (alpha 0) draw the two runs per row, plus the whole top row
  and the row above a flat bottom; their dots are alpha 31 whatever the
  texel alpha (**new**: a transparent direct-colour texel shows its
  colour; 3d_lines, 46 -> 0 dots).
- Line segments (vertices on at most two dots) are drawn full size.
- **Zero-area polygons (new in round 5, changed in round 6).** Games close
  the gaps where walls meet with polygons whose vertices all lie on one
  line (SoulSilver's bedroom has folded zero-width quads at x = 40 and
  200). They follow the opaque size rules like any other; where the two
  edges coincide, the designated left edge (next section: the forward
  chain, collinear vertices counting as front-facing) is the left one, so
  its colour, texcoords and depth are the ones shown (3d_probe_degen: 213
  -> 0 dots). Round 5 also drew a slanted one's right x-major run whole
  where the left run is dropped, as the reference cores do; the console
  draws nothing there (polyrastertest 26, recorded empty; the reference
  fails it), so that exception is gone (3d_probe_degen column 5: 96 dots
  now differ from the reference, as the recording says).
- 1-dot polygons (all vertices on one dot) are dropped unless a vertex has
  w <= DISP_1DOT_DEPTH or POLYGON_ATTR.13 is set; 1x0 / 0x1 polygons are
  not checked; the dot takes the first vertex's attributes (3d_probe_dot,
  exact; unchanged).

Seams: adjacent opaque polygons sharing an edge neither overlap nor leave
gaps under the small-polygon rule (the bottom/right runs of one are the
top/left runs of the next); with edge marking or AA on, both draw the
shared edge and the depth test (strictly less) decides. Which one wins a
tie depends on the depth's rounding (**new**, 3d_probe_zinterp*): Z depth
is exact along edges, but across a span it steps by an 18-bit reciprocal
of the span's length, `a + (dz * n * floor(2^18 / d)) >> 18`, landing just
short of exact at whole steps, so a polygon drawn later wins the tie
where its depth rises from left to right (152 -> 0 dots in
3d_probe_zinterp_x). Translucent polygons
with blending on are full size, so a shared edge is drawn twice and
blends twice unless the dot already holds the polygon's ID (one ID per
mesh hides the seam) or a depth-updating polygon made the second fail the
depth test (3d_probe_xlu_seam: bright seams between IDs, none within one;
exact).

## Chains, facing and swapped rows (round 6, polyrastertest)

Until round 6 the two edges of a row were sorted by their x at the row's
centre, so any polygon was drawn as if its left edge were on the left.
The console does not sort: it walks two chains of edges and decides once,
from the polygon's facing, which chain is the left one. Where a
self-crossing or concave polygon puts that chain on the right, the row is
"swapped" (polyrastertest's word) and drawn by rules of its own, glitches
included. Code: `draw_polygon`, `Chain`, `facing` in render.nim.

- **Chains** (polyrastertest 27-29, 70). From the top vertex (the first
  vertex on the top row) one chain runs forward in vertex order, one
  backward. A chain moves on to its next vertex when its edge ends at or
  above the row, whichever way the next edge runs, so a chain whose next
  vertex lies above skips ahead to the first edge reaching below the row
  (the "cursed line polygons": quads with vertex 2 = vertex 4, whose
  chains end up on one segment).
- **Facing** (polyrastertest 72-75). The forward chain is the left one
  when the first three vertices turn anticlockwise (Y up) or lie on one
  line, else the backward chain. A concave second vertex therefore swaps
  the whole polygon (74). It is taken in clip space: 72 and 73 put the
  second vertex on the same screen line, one dot apart in clip space, and
  are drawn differently. Assumed: the determinant of the three vertices'
  (x, y, w) (every scene has w = 1.0, so only the sign of the 2D cross is
  pinned) and the vertices after clipping (the same first three in every
  clipped scene). Culling (geometry.nim) still uses the whole polygon's
  screen area: no scene culls.
- **Line rows** (24, 27-29). A row whose two chains are on one segment
  (same two endpoints) is drawn whole, as line segments are; three
  distinct collinear vertices give two different segments and follow the
  size rules (25, 26: 26 draws nothing).
- **Swapped rows** (13, 14, 16, 30-32, 49, 50, 53, 70, 73, 74). A row is
  swapped when the designated left edge's X(y) (18-bit, at the row's top)
  lies right of the designated right edge's, or equals it with a larger
  slope. Its span runs from the designated right edge (now on the left)
  to the designated left edge:
  - a filled x-major run gives only its inner dot (the one at X(y)); an
    unfilled one is left out whole;
  - the left end follows the left fill rule (filled unless an x-major
    edge going right, or full size);
  - the right end follows the right fill rule for x-major edges (filled
    when going right, or full size); any other right edge is filled when
    the edge on the *left* is vertical. That is the "swapped vertical left
    glitch" (30-32: the hardware checks the wrong side for the vertical
    right edge rule, so a slope facing a vertical left edge is filled and
    one facing a slope is not; x-major right edges never);
  - a vertical edge moves left a dot by being the designated right edge,
    wherever it lies (49, 50, 53), but not past x = 0 (56); a designated
    left vertical stays put when it lies on the right (13, 14);
  - with nothing between the two ends only the filled edge dots are drawn
    (31's top row); a swapped row whose ends cross over (start more than
    a dot past the end) is drawn as an ordinary row (13 row 98, 53 row
    141, 70 row 108);
  - wire-frames draw only the two end dots;
  - anti-aliasing: a vertical edge in a swapped row gets coverage 0, so it
    vanishes into the layer behind (54-56: "they invert the AA alpha for
    swapped polygons ... even though vertical edges shouldn't be"); sloped
    edges keep the coverage of the side they lie on (only visible/invisible
    is recorded, so their exact coverage is Assumed).
- **Flat polygons** (59-67): all vertices on one row draw from the
  leftmost to the rightmost of vertex 1 and its two neighbours, right end
  out: a quad's vertex 3 is never used ("1-4, 1-2 or 2-4"), also after
  clipping (the clipped vertex list, first vertex first).
- **Trapezoid rule** (33-37): the row above a flat bottom draws both
  x-major runs only when the bottom vertices are apart in x (36: two
  vertices on one dot are no flat bottom).

## Anti-aliasing (DISP3DCNT.4)

GBATEK: opaque polygon edges get partial coverage; translucent polygons
are not anti-aliased; lines, wire-frames and 1-dot polygons are
("accidentally"); edge-marked edges go on translucent at about alpha 16.

| | Before | Now (reference runs) |
|---|---|---|
| What an edge dot mixes with | the colour it was drawn over, only where a 4-neighbour had another ID and lay further | a second layer per dot: the nearest opaque colour behind the top one, whatever the drawing order; hidden dots still land there when nearer, translucent polygons blend into both layers; no ID condition (3d_probe_aa3 exact) |
| Lines, wire-frames | no AA | AA'd like any edge: dotted, faded lines (3d_aa); a 1-dot polygon stays visible (the reference runs; GBATEK says it vanishes, not settled) |
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
- **Gaps in shallow lines and x-major edges**: a dot is left out of an
  x-major run when x(y+1) passes its centre by less than the slope's low
  9 bits (the line captures; 1320 of 49601 lines per corner have one).
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
| 3d_probe_zinterp / _s / _y2 / _x (new) | 0 / 0 / 0 / 152 | 0 / 0 / 0 / 0 |
| 3d_probe_hwline (new; against the hardware captures) | 6 | 0 (the reference cores: 6) |
| every other 3d_* ROM | unchanged (hashes kept) | |

Pokemon SoulSilver against the reference core (whole top screen, p12;
ndscompare, so both runners on the host clock):

| Frame | before | now | what is left |
|---|---|---|---|
| 6600 (bedroom) | 1061 (2.16 %) | 44 (0.09 %) | the character's shadow (30, texture), 3 apex dots (depth ties), 11 single dots |
| 8000 (kitchen + text box) | 1131 (2.30 %) | 328 (0.67 %) | text box (141, 2D timing), wallpaper texel seams (131, texcoords on a quad clipped at x = 256), shadow, single dots |
| title, bottom screen (our 860 vs reference 858) | 2493 (5.07 %) | 672 (1.37 %) | bubbles (2D sprites), one-step shading inside Lugia (lighting), a few spine edge dots |
| 3000, 5000 | 993, 11580 | the same (no anti-aliased 3D on screen; the 5000 differences are the name-entry screen a few frames behind, 2D only) | |

With the regression script (`--rtc 2004-01-01`), frames 3000 and 5000
are byte-identical to before; 8000 changes (808 dots), as intended.

Round 6 (the chains and swapped rows; `nds-polyraster`):

| What | before | now |
|---|---|---|
| polyrastertest (scenes passing, the ROM's own verdict) | 49 stepped (50 in the hunt's run) | 73 of 77 (the reference: 70) |
| 3d_probe_degen against melonDS DS 1.4 | 0 | 96 (column 5, a slanted zero-area triangle: the console draws none of it, polyrastertest 26) |
| 3d_light against melonDS DS 1.4 | 4648 | 4619 (30 dots changed, 29 of them now as the reference: swapped rows at the bottom of its spheres) |
| every other 3d_* ROM | | unchanged (hashes kept) |
| nds-interp line captures | 198404 / 198404 | 198404 / 198404 |
| SoulSilver against the reference, top screen, frames 6600 / 8000 | 16 / 283 | 15 / 283 |

SoulSilver's regression frames 3000/5000/8000 are byte-identical
(e4b66d68 / 6cf51b7e / ae4536a1).

## Open

- **The curse of edge marking** (polyrastertest 38, 39, 43; the reference
  fails them too). With edge marking on, a second polygon behind the
  first (z -16/4096: depth 7680 against 0) whose x-major edge run lies on the first one's
  edge dots shows that run over them on the console: over the first
  polygon's extra left run (38, drawn only because edge marking makes it
  full size) or extra right run (39), over its bottom row (43); a
  diagonal edge (42) or an x-major run that is not filled (40, 44) does
  not. The depth test alone cannot give that (the second polygon is
  further); something lets a filled x-major run of a later polygon replace
  edge dots. Not fitted: 155 dots in the three scenes.
- **polyrastertest 56, one dot**: on the top row of the combined
  AA/swapped/clipped scene the inner dot of the swapped x-major edge is
  invisible on the console (coverage 0) and not in ours; the AA coverage
  of sloped edges in swapped rows is only pinned as visible/invisible.
- **Facing**: the determinant of (x, y, w) and taking it after clipping
  are Assumed (every scene has w = 1.0 and keeps its first three vertices
  through clipping); culling still uses the whole polygon's screen area,
  and whether it follows the first three vertices too is untested (no
  scene culls).
- polyrastertest's data comes from a New 3DS XL in DS mode; a DS or DS
  Lite run of the ROM would confirm the rules are the DS's own.

- The run-end rule is pinned only for lines (the captures); for polygon
  edges it is the same rasteriser path, but no capture shows a filled
  polygon, and the reference cores do not have it (none of our 3d_probe_*
  triangles happens to hit it).
- **Depth at an apex** (3d_probe_ztie, 6 dots; SoulSilver 3 dots): where a
  polygon's apex dot ties a flat neighbour's depth, the reference shows
  the later polygon when it gets nearer from the apex; sampling edge depth
  at the row centre fixes those dots but breaks 3d_depth (58 dots), and
  3d_probe_zinterp shows edge depth exact on whole rows, so the apex dot
  must take its depth some other way (not found).
- **Coverage residue**: 3d_probe_aa 22, _aa2 4, _aa4 6, 3d_aa 31 dots, all
  one coverage step (y-major rounding, rows where both edges' runs share
  dots near a vertex).
- Not edges, found on the way: SoulSilver's wallpaper (a quad clipped at
  x = 256, texel boundaries one dot apart every 10 dots), the character's
  shadow (an alpha-8 textured quad, its ellipse a row longer here), and
  3d_clip's 86 dots are texcoord/clipping arithmetic.
