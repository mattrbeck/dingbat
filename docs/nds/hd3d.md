# DS HD rendering: the 3D scene at a multiple of 256x192

What it takes to show DS games' 3D sharper than the console did, the
options and what each loses, and the prototype on branch `nds-hd3d`: the
software rasteriser run a second time at N x the resolution (N = 2..4),
composited with the 2D layers per sub-dot, display capture included.
Display only: with HD on, the 1x screens, the machine and its save state
are byte for byte what they are with it off.

On main (2026-10-09) behind Settings > Nintendo DS > 3D resolution
(Native, 2x, 3x, 4x; Native by default), which shows only with DS Beta on
(docs/nds/beta.md).

## HD's history across loads, rewind and run-ahead

HD keeps what no state carries: the vertices' sub-dot positions
(`geometry.hpos`, `Gpu3d.hpos`), the HD 3D frame and the HD render its next
lines come from, display capture's HD copies (`cap_hd`/`cap_1x`) and the
rows already holding a line (`hd_rep`). So:

- **A state applied over a running HD machine** (a load, a rewind pop, a
  scrubber commit) restarts HD from it (`Gpu.hd_restart`, from
  `apply_new`): the frames after it are exactly what turning HD on at that
  state draws, and the screens meanwhile show the loaded 1x ones scaled up.
- **Run-ahead** looks ahead and comes back to the same timeline, so it
  takes HD's history first (`Gpu.hd_side`) and puts it back after
  (`load_own_payload(as_new = false)` leaves HD alone); the page is shown
  the look ahead's HD screens (`nds_hd_fb555_*`). Its own HD frames and the
  ones it shows are a plain run's.
- **3D frame reuse** at HD also compares the HD positions (`last_hpos`): a
  vertex moving within its dot keeps the 1x lists equal while the HD frame
  changes (SoulSilver walking left every reused frame stale).

Checked at 2x and 4x on Golden Sun's field and SoulSilver (80-118 frames,
0 differences) and in `tests/nds_savestate_test.nim` "HD 3D history".

## Cost in the browser

Chromium on this Mac (M-series), ms a frame unpaced (`ndsBench`, 16.7 is
full speed):

| | Native | 2x | 3x | 4x |
|---|---|---|---|---|
| Golden Sun field | 11.4 | 16.3 | 20.9 | 26.5 |
| SoulSilver walking | 3.4 | 5.2 | 5.6 | 6.0 |

2x holds full speed in SoulSilver-class games; Golden Sun-class 3D is at
the edge at 2x on a fast desktop and below it on phones.

## How a DS frame is made today

- **Geometry** (`gpu3d/geometry.nim`): commands to clip-space vertices,
  clipped, placed on the screen in whole dots (`to_screen`, sx/sy), into
  Polygon/Vertex RAM; swapped to the renderer at V-blank.
- **Rasteriser** (`gpu3d/render.nim`): the whole frame at once into a
  256x192 colour buffer (6-bit RGB + 5-bit alpha) and a per-dot record
  (depth, opaque/translucent polygon IDs, fog/edge flags, AA coverage and
  the layer behind). Opaque polygons Y-sorted, then translucent ones
  (sorted or in order); the hardware's edge/fill rules, 9/8-bit
  perspective factors, Z/W-buffer, shadow volumes, toon/highlight; post
  passes AA, edge marking, fog. Per-line costs model the 48-line cache
  (RDLINES_COUNT). A frame whose inputs are unchanged is reused.
- **Hand-off** (`gpu3d/gpu3d.nim`): lines are copied into `frame` as the
  display would take them, so a render-register write mid-frame splits the
  frame (`draw_lines`).
- **2D engine A** (`gpu/engine2d.nim`): BG0 is the 3D line (BG0HOFS
  scrolls it), composited with the BGs/OBJs by priority and windows
  (painted, `composite`), 3D-over-2D blended by the 3D alpha
  (`blend_3d`), colour effects and master brightness on 6-bit channels.
- **Display capture** (`gpu/gpu.nim capture_line`): the composite, or the
  3D layer alone, optionally blended with a VRAM bank or the main-memory
  FIFO, written as 15-bit + alpha into an LCDC bank. Games read it back
  as VRAM display (display mode 2), as a 2D bitmap BG or bitmap OBJs, or
  as a texture. **Dual-screen 3D** (both screens 3D) alternates POWCNT1.15
  every frame and shows the other screen from last frame's capture: Golden
  Sun: Dark Dawn does exactly that (title and field: engine A renders 3D
  into the composite, captures it to bank D and shows bank D by VRAM
  display, 30 Hz per screen).

## Options

| | quality | cost | what it loses | display capture |
|---|---|---|---|---|
| **(a) software rasteriser at N x** (prototyped) | sharp polygon edges and models; textures as sharp as their texels (nearest); every DS rule kept | 3D work x N^2 (dots), plus N^2 composite passes per 3D line | outlines (edge marking) and AA ramps 1 HD dot wide (thinner); line/wire-frame polygons 1 HD dot wide; vertex positions get the sub-dot precision the hardware drops, so HD content sits up to a dot from the 1x picture | HD copy of every capture, used while VRAM still holds what was captured (VRAM display, capture source B; not yet 2D BGs/OBJs/textures) |
| **(b) GPU renderer** (WebGL2 / Metal) | as (a), any N for little CPU; MSAA in place of the DS's AA | CPU: the texture decode/upload and draw submission; GPU: trivial | see below | needs a GPU-side capture: render to texture, keep the HD capture texture next to the 1x one, same validity rule; the CPU must never wait on a read-back |
| **(c) texture filtering / packs** | smooths texels (bilinear) or replaces them (packs) | small (GPU) / a texture hash per upload | bilinear is wrong for pixel-art textures with colour-0 holes and palettes (fringes); packs need per-game assets, a hash of every texture + palette | n/a |
| **(d) 2D upscale filters on the output** | the web app's hq4x / xBR already apply to DS screens (glpresent.js, any game) | GPU shader | not more detail: smooths 1x pixels, 3D and 2D alike, can't recover edges | works on whatever is shown |

**What a GPU renderer loses** (or must work hard to keep): the DS's own
edge and fill rules (x-major runs, swapped rows, the overlapping-edge rule,
1-dot and line polygons: GPUs rasterise triangles with top-left rules);
polygons of 4-10 vertices interpolated across spans (a GPU splits them
into triangles: Gouraud and texture coordinates crease along the
diagonal); the 9/8-bit perspective factors and 9-bit colour (floats); W-
buffer depth and the depth-equal test's +-0x200 tolerance (fragment-shader
depth, and the tolerance needs the old depth: framebuffer fetch, which
Metal has on Apple GPUs and WebGL2 does not); the translucent polygon-ID
rule (one blend per ID per dot: a stencil per dot holds it), shadow
volumes (stencil, but "not on its own ID" needs the opaque ID: a second
target or framebuffer fetch); edge marking and fog are post passes over an
ID/depth/flag target (fine); the DS's AA (coverage + the layer behind)
would be replaced by MSAA; toon/highlight are a table lookup (fine);
texture formats decoded on the CPU (the decoded-texel cache already
exists) and uploaded per tex_gen; the bitmap rear plane a texture;
mid-frame register writes become a re-render with a scissor. Drawn in
submission order, blending stays in the DS's order (GPUs blend primitives
in order).

## The prototype (a)

`ndsrun ROM --hd N` (2..4) writes PNGs at 256N x 384N; the core setter is
`NDS.set_hd_scale(n)`, the web build's `nds_set_hd(k)` (Settings >
Nintendo DS > 3D resolution); in the desktop app (DS Beta) Settings >
Video > Nintendo DS > 3D resolution, `NdsGame.set_hd`, the presenter's
texture the HD screens (docs/nds/desktop.md).

- **Geometry** keeps each vertex's screen position in 1/192 dots
  (`hd_screen`, alongside Polygon/Vertex RAM, only while HD is on; exact
  at 2x, 3x, 4x). Its floor is the hardware's whole-dot position.
- **Renderer** is generic over the scale (`RendererOf[S]`, `Renderer =
  RendererOf[1]`): the S = 1 instance compiles to the same code as before
  (host instructions on SoulSilver p12 +0.01 %); S = 2/3/4 are extra
  instances drawing 256S x 192S. The line budget stays the 1x renderer's.
  The HD renderer gets the same polygon lists with the HD positions,
  the 1x Y-sort keys (same drawing order) and the 1x render registers;
  it renders whenever the 1x one does (frame reuse included) and its lines
  are handed off with the 1x ones (mid-frame register changes split both).
- **Composite** (`Gpu.hd_line`): engine A's composite per HD dot, by the
  hardware's rules (priorities, windows, 3D alpha blending, colour effects,
  master brightness), computed per 1x dot rather than per sub-dot column
  (see "Why the fast composite is exact" below). Everything else (engine
  B, 2D lines) repeats each dot N x N, and a repeated line the screen's
  rows already hold is not written again. A line showing 3D is not reused
  by the 2D line cache while HD is on (its scratch is needed).
- **Capture**: each captured halfword gets N x N HD sub-dots
  (`cap_hd`, from the HD composite or HD 3D layer, blended with source B's
  HD copy) and a note of the 1x value written (`cap_1x`). VRAM display and
  capture source B use the HD copy where the bank still holds that value,
  the 1x pixel elsewhere (a CPU write, a DMA, another capture). That is
  what makes Golden Sun's dual-screen 3D come out in HD.
- Not machine state: every new field is in the save state's skip lists
  (the layout is unchanged), and a state loads into an HD machine (the
  first frame after places vertices by their whole dots).

### Why the fast composite is exact

The first prototype (08b4eb78) composited every sub-dot column of a line
whole: engine A's composite and master brightness N x N times per line
with that column of the HD 3D frame as BG0. That is the definition; the
fast path computes the same thing per dot:

- Within a line, a dot's result depends on the 3D pixel it shows and on
  nothing else that differs between its sub-dots (BGs, OBJs, windows,
  effect registers, BG0HOFS are the line's). So a sub-dot whose HD 3D
  pixel equals the 1x pixel at that dot gets the 1x dot's result, and one
  equal to the dot's previous sub-dot gets that one's (`hd_lp/lg/ld`).
- A transparent 3D pixel never shows: every transparent value gives the
  dot of the line composited with no 3D (one more composite, only on
  lines where a sub-dot needs it).
- An opaque one: the line is painted once with the 3D layer opaque
  wherever BG0HOFS lets it show (`hd_prepare`, the same paint as the line
  composite). Where the 3D layer is then the top or second layer, the dot
  is the effect rules on p's colour (`hd_dot`); `effect_dot` and
  `bright_dot` are the very templates the line composite and master
  brightness expand, not copies. Where it is under two other layers, the
  top two are the same as with no 3D, so the dot is the 1x one.
- VRAM display and capture copy the captured HD sub-dots with one
  validity test per 1x dot instead of per sub-dot.

Checked against 08b4eb78 as the oracle: `ndsrun --hd-hash 5` (a CRC-32 of
each HD screen every 5 frames) over SoulSilver New Bark Town (p12 frames
9001-10000: walking, the house exit, a fade), Golden Sun's first field
(28001-28300) and title (1001-1300, dual-screen 3D through capture), at
2x, 3x and 4x: all 960 hashes identical. SoulSilver p12's HD shots at 2x
(3000-8000) are identical too.

### Checked

- SoulSilver p12 (the regression anchor): shots 3000/5000/6000/6600/8000 e4b66d68 /
  6cf51b7e / 61fad7f8 / dfb2fd6c / 8971b401 and the state + screen
  hashes every 500 frames identical to the branch head, with HD off and
  with `--hd 2` (the 1x screens and the whole state). Golden Sun title
  (capture every frame): state and screen hashes every 10 frames for 120
  frames identical at 1x and `--hd 4`.
- `--state-layout` identical; all 14 DS suites pass.
- Web: `e2e/nds.e2e.mjs` (new test: HD screens at 2x, 1x screen unchanged,
  presenter draws, setting kept) passes with the rest; the microphone and
  audio-graph tests time out in this headless setup as before HD
  (getUserMedia). `tests/*.test.mjs` 865/865, tsc clean.

### Cost

Host instructions per emulated frame (`ndsrun --perf-from`, macOS
retired-instruction counter: exact, unlike wall time on this shared Mac),
from save states with the scripts' presses. "Before" is 08b4eb78 (every
sub-dot column composited whole), "after" the per-dot composite. The
split comes from builds with `-d:hd_nocomposite` (no HD composite) and
`-d:hd_nocapture` (no HD capture).

| scene | 1x | 2x | 3x | 4x |
|---|---|---|---|---|
| SoulSilver, New Bark Town walk (p12 9001-10400), before | 40.4 M | 80.3 M | 121.1 M | 177.2 M |
| ... after | 40.3 M | 67.6 M | 86.8 M | 111.9 M |
| ... after: HD composite (before) | | 7.6 M (17.2) | 11.6 M (39.4) | 15.9 M (70.3) |
| ... after: HD rasteriser and hand-off | | 19.7 M | 34.9 M | 55.7 M |
| Golden Sun DD, first field (28001-28600), before | 121.0 M | 183.9 M | 251.7 M | 344.1 M |
| ... after | 120.7 M | 172.0 M | 219.3 M | 281.2 M |
| ... after: HD composite (before) | | 9.3 M (18.0) | 15.7 M (41.6) | 22.7 M (75.0) |
| ... after: HD rasteriser and hand-off | | 42.0 M | 82.9 M | 137.8 M |
| Golden Sun DD, title (1330 polygons, 1001-1600), before | 133.6 M | 264.0 M | 412.8 M | 615.3 M |
| ... after | 132.8 M | 243.5 M | 360.9 M | 518.1 M |
| ... after: HD composite | | 12.0 M | 20.7 M | 29.9 M |

The HD composite is 2.3-4.4x cheaper than before; HD capture and VRAM
display are within measurement noise of none (Golden Sun field, nocapture
build). What is left of the HD cost is the rasteriser drawing N^2 as
many dots (the span loops, `fill_k`, are the top of the profile; then
`clear` and `edge_mark` over the whole HD frame), 78 % of it in
SoulSilver at 4x and 86-92 % in Golden Sun. HD off: SoulSilver p12 host
instructions -0.4 % against the branch head (the templates the composite
now shares inline a little better).

## iOS

A 393-pt-wide iPhone shows each screen ~374 pt = ~1122 px at 3x, so 4x
internal (1024 px) is about native and 2x is half of it, scaled up.

- **Hook-up** (done): `dingbat_nds_set_hd(k)` (kept across DS boots,
  applied live), `dingbat_nds_hd_scale`, and `dingbat_nds_hd_fb` with its
  width/height: the HD screens stacked 256k x 384k, copied beside the 1x
  composite after every frame, load, reset and rewind. `GameRenderer`
  uploads it in place of the 1x one and draws each view from it (texels,
  filters, grid and subpixel pitch all k x, as the web's `ndsFrame`
  views); thumbnails, the glow and states keep the 1x picture. Settings >
  Nintendo DS > 3D resolution (`NdsState.hd`, the `nds-display` record's
  `hd`). No JIT question: the app runs the core as native code, and a GPU
  path would be Metal. Checked: `tests/ios_api_test.nim` (no 3D: every
  k x k block is the 1x pixel; a 3D ROM differs from the 1x scaled up; a
  state load, reset and rewind keep the scale) and simulator shots of
  Simple_Tri at Native, 2x and 4x. Not yet measured on a device.
- **Budget**: a recent iPhone's performance core is in this Mac's class
  for single-thread work, but it throttles under a sustained load, and
  the 1x core must fit first. From the numbers above, 2x is plausible for
  SoulSilver-class games on an A15-A17; 4x and anything in Golden Sun
  need the HD work off the emulation thread.
- **Threads** (3-5 agent-days, native): HD is display-only, so it can run
  beside the emulation with no determinism risk: the HD rasteriser on a
  worker (it needs the frame's lists, render registers and the texture /
  palette slots: < 1 MB a frame, or the decoded-texel cache by tex_gen),
  or split into row bands over 2-4 cores (bands overlap one row for edge
  marking); the per-sub-dot composite on the GPU (a fragment shader over
  the 1x 2D layers and the HD 3D texture) or on another core. On the web
  the same split needs a second wasm instance in a worker fed by
  postMessage, since SharedArrayBuffer threads need cross-origin
  isolation, which the Drive sign-in popup rules out.
- **Metal renderer** (2-4 weeks for HD only): GPU cost is trivial at 4x;
  what it gives up is listed under option (b).

## What is left

- The rasteriser is now nearly all of the HD cost. Its per-dot work is
  the 1x rasteriser's (already tuned); what HD alone could still trim is
  the whole-frame passes (`clear`, edge marking, fog, AA) at N^2 dots, a
  few percent. Beyond that it is threads (row bands) or a GPU renderer.
- Captures read back as 2D bitmap BGs, bitmap OBJs or textures stay 1x
  (the HD copy is only used by VRAM display and capture source B). Games
  that show the second 3D screen through engine B's bitmap BG need the
  shadow there too (2-3 days, with a scale/rotation check: only 1:1 BGs
  can use it).
- Edge marking and AA come out 1 HD dot wide: thinner outlines than the
  console. An option could widen them to N dots.
- Textures stay nearest (as the console). Bilinear filtering in the HD
  renderer is a small change but softens pixel-art textures and fringes
  colour-0 holes; texture packs need a hash per texture + palette and
  per-game assets.
- A state loaded with HD on draws its first frame with whole-dot vertex
  positions (the sub-dot positions are not in the state).
