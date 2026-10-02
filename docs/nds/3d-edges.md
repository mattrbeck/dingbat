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
  with gaps, laid over the captures). Round 7: `_swap_aa` (AA coverage of
  x-major edges in swapped rows, polyrastertest 56's polygon among them).
- **polyrastertest v1.0.2-b** (Jaklyy, MIT; docs/nds/test-roms.md, round
  6): 77 one- and two-polygon scenes whose spans (and, for edge marking, colours)
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
    edges keep the coverage of the side they lie on. The x-major edge on
    the left (the designated right one) shows its inner dot with the
    coverage its run's *first* dot would have (left-edge rule, h measured
    at that dot's centre from the run's exact left end), as if the
    coverage were set at the start of the run and never stepped to the
    inner dot (round 7: polyrastertest 56's top row, where the run starts
    0.07 dots before a dot centre and the console shows nothing, while the
    rows below show their inner dots; 3d_probe_swap_aa, 11 such edges going
    left and right, on the reference: every inner dot exact, 136 of
    the 166 dots that differed). The swapped x-major edge on the right keeps the right-edge
    coverage of its inner dot (not probed).
- **Flat polygons** (59-67): all vertices on one row draw from the
  leftmost to the rightmost of vertex 1 and its two neighbours, right end
  out: a quad's vertex 3 is never used ("1-4, 1-2 or 2-4"), also after
  clipping (the clipped vertex list, first vertex first).
- **Trapezoid rule** (33-37): the row above a flat bottom draws both
  x-major runs only when the bottom vertices are apart in x (36: two
  vertices on one dot are no flat bottom).

## Overlapping edges with edge marking (round 7, polyrastertest 38-44)

"The curse of edge marking". The test's author describes it in the
program's newer source (`source/tests.h` at HEAD, a test-program comment;
that source's 22 scenes of it have no recorded data, the data file is the
release's), from runs on a console:

> Edgemarking (only) + overlapping edges + same id = no fill????
> right ymajor/vert (overriden by left ymajor/vert)
> bottom xmajor/flat (overriden by top xmajor/flat)

with per-scene notes: "Does not apply when poly ids are different", "Also
doesn't apply with aa, ofc" (that scene commented out), "What about
translucency? - no", "Wireframe? - yes, for some reason?", "How about when
over the Rear Plane? - no", "also applies to verticals", "bottom xmajor",
"bottom flat", "note that it's specifically the center of the polygon, and
not the slopes that this applies to", "the rules dont seem to combine",
"does not apply if the edge becomes properly edge marked".

The rule (`plot`, ROLE_*): **with edge marking on and anti-aliasing off,
where edges of two opaque polygons (wire-frames included) with the same ID
overlap, a left edge wins over a right one when neither is x-major
(y-major, diagonal, vertical), and a top x-major run or the top row's span
over a bottom x-major run or the bottom row's span, whichever polygon is
nearer and whichever is drawn first.** A later polygon's winning edge
replaces the dot whatever its depth; a later polygon's losing edge leaves
it alone whatever its depth. x-major runs are top or bottom as the fill
rules name them (a left run going right is a bottom edge, a right run
going right a top one); swapped rows and flat (one-row) polygons take no
part (no evidence).

The recorded evidence is the release's seven scenes 38-44 (a white polygon
and a red one 16/4096 behind it, depth 7680 against 0, colours recorded).
The release's test sets POLYGON_ATTR once, so both polygons of every pair
share one ID (1 in 38, 0 in the rest) and edge marking never marks between
them:

| # | Overlap | Console | The rule |
|---|---|---|---|
| 38, 39 | red's top x-major run over white's bottom x-major run (white's left / right edge) | red over white's whole run | top over bottom |
| 40, 41 | white's top x-major run over red's bottom run | white | top over bottom (white is nearer too) |
| 42 | red's right diagonal over white's bottom x-major run | white | different kinds: no rule |
| 43 | red's top x-major run over white's bottom row; over white's interior a row higher | red over the bottom row only | top over bottom; interiors take no part |
| 44 | white's top row over red's bottom x-major run | white | top over bottom |

Round 7 first fitted these with "a later polygon's x-major run replaces a
same-ID polygon's edge dots"; it also passes 77/77 (with the Y-sort only:
in submission order it fails 40 and 44), but the author's description is
order-free, covers non-x-major edges, and excludes AA. Drawn through
dingbat (a scratch replay of tests.h's scenes, no recorded data to compare)
the author's rule gives the effect in every scene the notes call "yes"
(the first, diagonal, scene, wire-frame, verticals, bottom x-major, bottom
flat: 63-64 dots each; in "the center ... not the slopes" the bottom row's
centre changes and its two slope dots do not) and none in every "no"
(different IDs, AA, translucency, rear plane, properly edge marked), and
the release's 77 pass whether opaque polygons are Y-sorted or not.
Assumed: what "properly edge marked" means beyond that scene (it passes
without a special case), the role of swapped rows and one-row polygons,
and any depth limit (one difference recorded).

What it does to a game: nothing in SoulSilver. Its overworld runs with
DISP3DCNT = 0039h (textures, blending, AA and edge marking; edge colour 0
black for IDs 0-7, 1084h for the rest, p12 frames 3000-8000), and with AA
on the rule does not apply: frames 3000/5000/8000 are unchanged and the
reference comparison is as before (15 / 283 dots at 6600 / 8000). The
first fit, which ignored AA, changed 114 / 65 dots there.

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
(3d_edge, 3d_probe_edge2, exact). While drawing, edge marking without AA
also lets left/top edges win over a same-ID polygon's right/bottom edges
whatever their depth (round 7, "Overlapping edges with edge marking"
above).

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
- **Edges of hidden same-ID polygons showing through** with edge marking
  (AA off): a left or top edge wins over a same-ID polygon's right or
  bottom edge even from behind (polyrastertest 38, 39, 43).

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

Round 7 (overlapping edges with edge marking, the swapped x-major
coverage; `nds-polyraster2`):

| What | before | now |
|---|---|---|
| polyrastertest (scenes passing, the ROM's own verdict) | 73 of 77 | 77 of 77 (the reference: 70) |
| 3d_probe_swap_aa (new) against melonDS DS 1.4 | 166 | 30 (every swapped inner dot exact; left: 11 dots on the rows where the x-major edge passes the vertical one, and 19 of right-edge coverage residue in ordinary rows) |
| every other 3d_* ROM (3d_edge, 3d_probe_edge2, _aa3_em, _degen_edge ...) | | unchanged (hashes kept) |
| nds-interp line captures | 198404 / 198404 | 198404 / 198404 |
| SoulSilver against the reference, top screen, frames 6600 / 8000 | 15 / 283 | 15 / 283 (AA is on there, so the overlapping-edge rule does not apply) |

SoulSilver's regression frames 3000/5000/8000 are byte-identical
(e4b66d68 / 6cf51b7e / ae4536a1).

## Open

- **The overlapping-edge rule's edges** (round 7): only 38-44 are
  recorded (top/bottom x-major runs and rows, one depth difference); the
  left/right part, wire-frames, the AA/translucent/different-ID
  exclusions and "properly edge marked" rest on the author's notes, whose
  scenes (polyrastertest HEAD, tests.h) have no recorded data. A console
  run of HEAD's curse scenes with their data re-recorded would settle
  them dot for dot; swapped rows and one-row polygons are untested.
- **The row where a swapped edge passes the other one** (3d_probe_swap_aa,
  11 dots): 6 are rows whose ends cross by one dot, which the reference
  draws as ordinary rows and we as the filled edge dots alone; drawing
  them as ordinary rows fails polyrastertest 13 (without AA), so the
  recording sides with us there, but no recording has such a row with
  AA. The other 5 are single dots at the vertical edge on that row.
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
