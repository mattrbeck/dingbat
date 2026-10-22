# DS 3D on the host GPU (PAUSED 2026-10-21: in-flight notes)

Status: investigation + first prototype step, paused at Matt's request.
Branch `worktree-nds-gpu3d` (off main 2504fe21). Nothing here is merged.

## The question

Is any DS 3D drawn on the host GPU? What would it take, what would it
save, what are the tradeoffs, and what if the GPU only did the
upscaling (HD) part?

## Answers so far

- **No DS 3D runs on the host GPU today.** The 1x renderer
  (`gpu3d/render.nim`) and the HD 2-4x renderer (the same code as
  `RendererOf[S]`, docs/nds/hd3d.md) are both software. The only GPU work
  on DS frames is the presenter's output filters (web/glpresent.js).
- **Where the CPU goes** (from docs/nds/perf.md and hd3d.md):
  - At 1x the rasteriser was 36 % of host instructions in SoulSilver's
    3D-heavy title (Lugia). It is much less in the overworld, where most
    frames are reused. Moving 1x to the GPU saves at most that, and it
    costs exactness. Capture, the 2D composite and save states need the
    1x picture on the CPU, so it would need read-backs, which WebGL2
    makes synchronous. Not recommended.
  - At HD, the extra cost is 78-92 % rasteriser. Golden Sun field:
    120.7 M host instructions a frame at 1x vs 281 M at 4x. SoulSilver
    walk: 40.3 M vs 111.9 M. Browser: GS field 11.4 / 16.3 / 20.9 /
    26.5 ms at 1-4x. **Doing only HD on the GPU** removes nearly all of
    that increment. The CPU keeps the exact 1x machine and pays only for
    the export: the scene (~50-260 KB), plus the texture/palette images
    (608 KB) when `tex_gen` changes, plus one or two extra 2D composites
    per 3D line. That export cost is not measured yet (next step 1).
- **Recommended design ("hybrid HD")**: the 1x software renderer stays
  the source of truth. Each frame the core exports the scene, and the GPU
  renders it at N x and composites it with engine A's 2D layers by the
  `hd_dot` rules. This is display only, like HD today.
- **GPU rasteriser approach chosen: a per-pixel ordered loop.** A
  fragment shader walks the polygons binned to its row, in the DS's
  drawing order, and runs `draw_polygon`'s row logic and `plot_k` for its
  own dot.
  - Because a dot's state (colour, depth, IDs, flags, AA coverage, the
    layer behind) lives in registers, the hard parts of a classic
    triangle renderer stay exact. That covers the translucent-ID rule,
    blending over a transparent rear plane, shadow stencils, the depth-equal
    tolerance, the AA layer behind, x-major runs, swapped rows and the
    curse rule. Polygons are not split into triangles, so there is no
    diagonal crease.
  - The 64-bit math in render.nim fits in GLSL ES 3.00's 32-bit ints:
    - The q/r split gives exact `floor(a + (b-a)n/d)`.
    - The edge slope product stays below 2^29.
    - `pfac` uses a float estimate plus an exact 64-bit (two-word)
      correction.
    - The z reciprocal and w use a 32x32->64 multiply on 16-bit limbs.
    - The x-major AA increment simplifies to `(dy*1024 - 1) div |dx|`.

    So the GPU HD output can in principle be **bit-identical to the
    software HD renderer**, and checked against it by dumps.
  - Textures are decoded in the shader from raw slot images (R8UI
    1024x512 texture VRAM, 1024x96 palette). There is no CPU decode, and
    the upload happens only when `tex_gen` changes.
  - Post passes run in a second shader (AA, then edge marking with its
    4 neighbours, then fog), then a composite pass. The composite is a
    port of `hd_dot` / `effect_dot` / `bright_dot`, fed from per-dot planes.
- Alternatives, not built:
  - **(B1) classic triangle rasteriser**: fastest on GPU and what most
    emulators do. It loses the DS edge rules, n-gon interpolation (creases),
    exact translucency over a transparent clear (WebGL2 has no framebuffer
    fetch) and the depth-equal tolerance. AA would become MSAA.
  - **(C) "just upscale" the 1x 3D layer** on the GPU (filter) and
    composite at HD. Costs nothing on the CPU and keeps 2D sharp, but adds
    no detail (no sub-dot edges, no texel detail).

## What is done (uncommitted work committed with this note)

- `src/dingbat/nds/gpu3d/gpuexport.nim`: the scene format (header, regs,
  polygons in drawing order, vertices with sub-dot positions),
  `export_scene`, and `slot_images` (texture/palette slot images built as
  render.nim's page tables do).
- `gpu3d.nim`: `gpu_on`, `set_gpu`, and `export_gpu` after each real
  render. Reuse also compares `hpos` while exporting.
- `gpu.nim` + `engine2d.nim`: `set_gpu`, `gpu_line` and
  `gpu_paint_line`. For lines showing 3D, these write per dot
  top/sec/layers/window/OBJ flags/no-3D dot/1x dot, and per line
  bld/eva/evb/evy/brightness/BG0HOFS. Display mode 1 only.
- `nds.nim set_gpu_export`; savestate skip lists extended.
- `render.nim`: `facing` exported.
- `tools/ndsrun.nim`: `--gpu` (export on, for `--perf-from` costs) and
  `--gpu-dump DIR@F,..`. The dump writes scene/tex/pal/plane/lines, the
  1x screens and 3D frame, and with `--hd N` the software HD 3D frame
  and screens: the oracle for the GPU path.
- Builds (`-d:danger -d:test_harness`). **Not yet checked**: the 14 DS
  suites, the state layout, and SoulSilver/GS hashes with `--gpu` off and
  on. The export must not change the machine; it should not, since it
  is display-only fields in skip lists, but this is unverified.

## Next steps

1. Cost of the export: `ndsrun --perf-from` with and without `--gpu`
   on the GS field / SS walk / GS title. This is the CPU side of the
   hybrid; compare it with `--hd 2/4`.
2. `web/nds/gpu3d.js` (WebGL2): the raster shader (per-pixel ordered
   loop, design above), the post shader and the composite shader. JS
   per frame: HD vertex positions, per-polygon bbox/flags (`line`, flat
   bottom, top vertex), and row-band bins.
3. Harness page `tools/gpu3d/` that loads dumps and diffs the GPU 3D
   frame against `hd3d.bin` and the GPU screens against
   `hdtop/hdbottom.bin`. Report the exact-match %, GPU time (disjoint
   timer query) and JS time.
4. Display capture at HD (Golden Sun's dual-screen 3D: title and field
   capture to bank D and show it by VRAM display). This needs per-bank
   HD capture textures plus a validity mask (the `cap_1x` rule), and
   display mode 2 in the composite. Until then GS's captured screen stays 1x.
5. Live web integration behind a flag (wasm exports for the scene and
   planes; the presenter takes a GL texture), then `ndsBench` numbers. iOS
   would port the same shaders to Metal; desktop to SDL_GPU or GL.
6. Mid-frame render-register splits (`draw_lines`) are ignored by the
   export (last render wins). This is rare; note it in the tradeoffs.

## Scratch (job dir, may be gone: regenerate)

`/Users/matt/.claude/jobs/6a30b37a/tmp/`:
- `ndsrun_gpu` (this branch).
- `nr.sh` (runs ndsrun with a press-script file).
- `scripts/` (ss_p12, gs_dd_field, ... copied from
  `~/.claude/jobs/d24d5ead/tmp/perf4/scripts/`, newlines stripped).
- `states/`: ss9600, gs28000, gst1000 (HLE BIOS, `--rtc 2004-01-01`).
- `dumps/{ss,gs,gst}/fN_*` (`--hd 4`):
  - SS 9700/10200/10400 hold 335-370 polygons; 10000 is a black
    transition with 0.
  - GS field 28100/28200/28300 hold 1364-1539 polygons.
  - GS title 1100/1101/1300 alternate 9 and 1334 polygons (dual-screen
    capture).
- Regenerate with:

  ```
  ndsrun ROM --rtc 2004-01-01 --press "$(cat script)" --state-save F@N
  ndsrun ROM --state-load F --frames N --hd 4 --gpu-dump DIR@frames
  ```
