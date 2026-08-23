# Upscale filters

dingbat's present shaders (`web/glpresent.js` `FRAG`, `src/dingbat.nim`
`FRAG_SRC`) carry three optional pixel-art scalers, selected by the Filter
setting: `hq4x`, `xbr` and `xbrz`. This page is the written specification the
`xbrz` ("xBRZ-style") branch was implemented from. It was written without
consulting any scaler source; the sections "What the family does" and
"Required behaviour" are the specification as handed to the implementer, and
"Implementation choices" records the rules the implementer had to invent where
the specification left a gap.

## What the family of "scale by rules" filters does (public knowledge)

Pixel-art scalers of the xBR family (Hyllian's xBR, 2011; Zenju's xBRZ variant,
2012) look at a small neighbourhood around each source pixel, decide whether a
diagonal edge passes through each of the pixel's four corners, and if so fill
the corner region of the magnified pixel with the colour of the neighbour on
the other side of the edge, so that staircase edges become smooth diagonals
while interior areas and fine detail are left alone. xBRZ differs from xBR in
three publicly described ways: a perceptual colour distance (Euclidean in
YCbCr rather than weighted YUV), a corner decision that compares edge
"strength" along the two diagonals of the 2x2 quad at the corner using a
wider support and a dominance ratio, and extra rules that refuse to blend when
doing so would erase one- or two-pixel features (eyes, dots, checkerboards) or
would round off the end of a line.

## Required behaviour

Inputs: source texture (RGB), the fragment's position inside its source
texel (sub-texel coordinates), and texel-fetch access to at least the 5x5
neighbourhood. Output: the fragment colour.

1. **Colour distance.** `dist(a, b)` = Euclidean distance between the YCbCr
   representations of a and b, scaled so that 8-bit channels give 0..~441.
   Two colours are "alike" when `dist < 30` (on that 8-bit scale).
2. **Active corner.** The fragment lies in one quadrant of its texel; that
   quadrant's corner is the active corner. Let the centre pixel be P, the
   horizontal neighbour across the active corner H, the vertical neighbour V,
   and the diagonal neighbour D. (P, H, V, D form the 2x2 quad at the corner.)
3. **Edge test at the corner.** Measure how "cut" the quad is along each of
   its two diagonals:
   - `across` = strength of an edge separating P and D from H and V, i.e. the
     colour difference along the P-D diagonal's *perpendicular* -- computed as
     a weighted sum: `dist(H, V)` counts 4x, plus the four distances that
     continue that same diagonal direction one pixel further out on each side
     of the quad (the two pixels beyond H and V in the 5x5 window, paired
     with the quad pixel they extend).
   - `along` = the same construction for the other diagonal (`dist(P, D)`
     counts 4x, plus its four outer continuations).
   An edge crosses the active corner when `across < along`. If not, output P
   unchanged.
4. **Fine-pattern guard.** If the quad is a checkerboard or a 2x2 of paired
   colours (`P~H and V~D`, or `P~V and H~D`), output P unchanged.
5. **Dominance.** The edge is *dominant* when `along > 3.6 x across`. A
   dominant edge always gets full blending. A non-dominant edge gets full
   blending only if none of these end-of-line guards fires:
   - the adjacent corner of P on the H side is also cut and P is not alike to
     the pixel diagonally across that corner;
   - likewise for the adjacent corner on the V side;
   - P is an isolated pixel: the five pixels around the quad on the far side
     (from the pixel beyond V, through V, D, H, to the pixel beyond H) are all
     alike and P is not alike to D.
   When a guard fires, only a small nib at the very corner is rounded (see 8).
6. **Blend colour.** The colour painted into the corner is whichever of H or V
   is closer to P (`dist(P,H) <= dist(P,V)` -> H, else V).
7. **Line slope.** For a fully blended corner, classify the edge:
   - *shallow* (closer to horizontal) when `2.2 x dist(H, far-V-side pixel)
     <= dist(V, far-H-side pixel)` and the two pixels on the V side that
     would lie on that line are not alike to P;
   - *steep* symmetrically;
   - otherwise a 45 degree diagonal.
   (The "far-V-side pixel" is the one diagonally adjacent to V away from the
   active corner; symmetric for H.)
8. **Fill shape (resolution-independent).** Instead of per-scale lookup
   tables, compute a signed distance from the fragment's sub-texel position
   to the cut line (45 degrees, shallow 1:2, or steep 2:1 through the corner)
   and mix P toward the blend colour with a narrow smoothstep across that
   line. For the nib-only case, mix a fraction (~0.45) within a small radius
   of the corner point.

## Implementation choices

Where the specification left a detail open, the shader does the following.
Offsets are written relative to P in units of the active corner's signs
(`sx`, `sy`), so `(1,0)` is H, `(0,1)` is V and `(1,1)` is D.

- **Outer continuations (rule 3).** `across` uses the four pairs parallel to
  the H-V direction one pixel out on either side of the quad:
  `P-(1,-1)`, `P-(-1,1)`, `D-(2,0)`, `D-(0,2)`. `along` uses the pairs
  parallel to the P-D direction: `H-(0,-1)`, `H-(2,1)`, `V-(-1,0)`,
  `V-(1,2)`. The whole rule therefore reads a 5x5 window; the same helper
  (`cornerDiffs`) evaluates the two adjacent corners for rule 5, so nothing
  beyond 5x5 is ever fetched.
- **"Far-V-side pixel" (rule 7)** is taken as `(-1,1)`: the pixel beside V on
  the side away from H. H and that pixel are the two ends of a 1:2-slope
  segment through the corner, so their agreement is what "shallow" means; V
  and `(1,-1)` are the ends of the 2:1 segment. The "two pixels on the V side
  that would lie on that line" are V and `(-1,1)`.
- **Adjacent corners (rule 5)** are P's corners `(sx,-sy)` and `(-sx,sy)`,
  tested with the same edge rule as the active corner; the pixel "diagonally
  across" each is `(1,-1)` and `(-1,1)` respectively. The isolated-pixel ring
  is `(-1,1), V, D, H, (1,-1)`, tested pairwise along the ring.
- **Cut lines (rule 8)** live in corner-local coordinates `lx, ly` that run
  0.5 at the texel centre to 1.0 at the active corner. All three lines pass
  through the quadrant centre `(0.75, 0.75)` so the wedges have equal area:
  45 degrees is `lx + ly = 1.5`, shallow is `0.5 lx + ly = 1.125`, steep is
  `lx + 0.5 ly = 1.125`. The mix is a `smoothstep` over +-`aa` texels of the
  signed distance, where `aa` is half an output pixel in texel units (from
  `fwidth` of the interpolated uv, taken once in `main()` in uniform control
  flow), clamped to [0.01, 0.25].
- **Nib (rule 8)** is a quarter-disc of radius 0.25 texels about the corner
  point, mixed at 0.45 with the same `aa` edge.
- The wedge is confined to the active quadrant (each quadrant evaluates only
  its own corner), so a shallow or steep line stops at the quadrant boundary.
