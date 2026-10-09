# DS HD rendering: the 3D scene at a multiple of 256x192

What it takes to show DS games' 3D sharper than the console did, the
options and what each loses, and the prototype on branch `nds-hd3d`: the
software rasteriser run a second time at N x the resolution (N = 2..4),
composited with the 2D layers per sub-dot, display capture included.
Display only: with HD on, the 1x screens, the machine and its save state
are byte for byte what they are with it off.

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
Nintendo DS > 3D resolution).

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
- **Composite** (`Gpu.hd_line`): after the 1x line, engine A's composite is
  run again N x N times with a sub-dot column of the HD 3D frame as BG0
  (`render_hd_sub`): BGs, OBJs, windows and effects are the line's own,
  so priorities, 3D alpha blending, colour effects and master brightness
  are the hardware's rules per HD dot. Everything else (engine B, 2D
  lines) repeats each dot N x N. A line showing 3D is not reused by the
  2D line cache while HD is on (its scratch is needed).
- **Capture**: each captured halfword gets N x N HD sub-dots
  (`cap_hd`, from the HD composite or HD 3D layer, blended with source B's
  HD copy) and a note of the 1x value written (`cap_1x`). VRAM display and
  capture source B use the HD copy where the bank still holds that value,
  the 1x pixel elsewhere (a CPU write, a DMA, another capture). That is
  what makes Golden Sun's dual-screen 3D come out in HD.
- Not machine state: every new field is in the save state's skip lists
  (the layout is unchanged), and a state loads into an HD machine (the
  first frame after places vertices by their whole dots).

### Checked

- SoulSilver p12 (HLE BA 393-pt-wide iPhone shows each screen ~374 pt = ~1122 px at 3x, so 4x
internal (1024 px) is about native and 2x is half of it, scaled up.

- **Hook-up** (0.5-1 agent-day): the core already has it
  (`set_hd_scale`, `gpu.hd_top/hd_bottom`); the C API needs
  `dingbat_nds_set_hd` and the HD screen pointers, the Swift presenter a
  256N x 384N texture, Settings a picker. No JIT question: the app runs
  the core as native code, and a GPU path would be Metal.
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
  what it gives up is listed under option (b).): shots 3000/5000/6000/6600/8000 e4b66d68 /
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
from save states with the scripts' presses; "composite" is the difference
to a `-d:hd_nocomposite` build (no per-sub-dot composite, no HD capture):

| scene | 1x | 2x | 3x | 4x |
|---|---|---|---|---|
| SoulSilver, New Bark Town walk (p12 9001-10400) | 40.4 M | 80.3 M (x2.0) | 121.1 M (x3.0) | 177.2 M (x4.4) |
| ... of which HD rasteriser | | 22.7 M | 41.3 M | 66.4 M |
| ... of which HD composite | | 17.2 M | 39.4 M | 70.3 M |
| Golden Sun DD, first field (28001-28600) | 121.0 M | 183.9 M (x1.5) | 251.7 M (x2.1) | 344.1 M (x2.8) |
| ... of which HD rasteriser + capture | | 44.9 M | 89.1 M | 148.0 M |
| ... of which HD composite | | 18.0 M | 41.6 M | 75.0 M |
| Golden Sun DD, title (1330 polygons, 1001-1600) | 133.6 M | 264.0 M (x2.0) | 412.8 M (x3.1) | 615.3 M (x4.6) |

Wall time, best of two back-to-back runs (SoulSilver walking out of the
house, 300 frames, one M-series core): 1x 4.7 ms/frame, 2x 8.4 ms, 4x
20.2 ms. So on this Mac 2x and 3x keep 60 fps in SoulSilver, 4x does not
single-threaded; Golden Sun, already ~2.5x SoulSilver's work at 1x, has
no room for any HD step on one core.

The rasteriser grows less than N^2 (polygon setup, sorting and the
geometry are paid once). The composite grows as N^2: each sub-dot column
re-runs engine A's whole composite (every BG/OBJ pass, effects, master
brightness) for one changed layer. Fixed with HD off: +0.1 % host
instructions on SoulSilver p12 (two scale tests per line).

## iOS

A 393-pt-wide iPhone shows each screen ~374 pt = ~1122 px at 3x, so 4x
internal (1024 px) is about native and 2x is half of it, scaled up.

- **Hook-up** (0.5-1 agent-day): the core already has it
  (`set_hd_scale`, `gpu.hd_top/hd_bottom`); the C API needs
  `dingbat_nds_set_hd` and the HD screen pointers, the Swift presenter a
  256N x 384N texture, Settings a picker. No JIT question: the app runs
  the core as native code, and a GPU path would be Metal.
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

- Faster composite (about a day): paint the non-3D layers once per line
  and run only the 3D layer's insertion and the effect pass per sub-dot;
  the HD composite is half the HD cost at 3x-4x.
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
