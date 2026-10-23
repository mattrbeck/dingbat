# DS HD 3D on the host GPU

A prototype on branch `worktree-nds-gpu3d`, not merged. HD 3D
(docs/nds/hd3d.md) drawn by the browser's GPU (WebGL2) in place of the
software renderer, behind a dev flag in the web app. The output matches
the software HD renderer **dot for dot**: both screens, display capture
included, at 2x, 3x and 4x.

## The question, answered

- **Was any DS 3D drawn on the host GPU?** No. The 1x renderer
  (`gpu3d/render.nim`) and HD (the same code as `RendererOf[S]`) are both
  software. The only GPU work on DS frames was the presenter's output
  filters.
- **Moving the 1x renderer to the GPU is not worth it.**
  - It saves at most the rasteriser's share of a frame: 36 % of
    SoulSilver's 3D-heavy title (Lugia, docs/nds/perf.md), much less
    where frames are reused.
  - It costs exactness, or read-backs. Capture, the 2D composite, rewind
    and save states all need the 1x picture on the CPU, and WebGL2
    read-backs stall.
- **Doing only HD on the GPU** ("just the upscaling") is where the cost
  is.
  - HD's extra is 78-92 % rasteriser. In the browser:

    | | GS field | GS title |
    |---|---|---|
    | 1x | 11.4 ms a frame | |
    | software 4x | 26.5 ms a frame | 48-50 ms a frame |

  - With the 1x machine exactly as it is and the GPU drawing HD, the CPU
    pays only for exporting the scene. That costs 0-6 % (below).
  - Golden Sun at 4x goes from 20-37 fps to full speed on an M2.
- **Tradeoffs**:
  - It needs WebGL2 and a GPU with headroom: about 2-11 ms of GPU time a
    frame at 4x on an M2.
  - It is one more renderer to keep in step with `render.nim`.
  - It is not used with run-ahead (below).
  - Mid-frame render-register changes are not split (below).
  - Nothing is lost in the picture: it is the software HD's, dot for dot.

## How it works

The core stays the machine. Each frame it exports what a renderer
outside it needs (display only, never in a save state; with the export
off it does nothing):

- **The scene**, from `gpu3d/gpuexport.nim` and `Gpu3d.export_gpu`, at
  each real render:
  - the polygons in the rasteriser's drawing order;
  - each vertex with its sub-dot screen position (`hpos`, as HD keeps
    it), depth, w, colour and texcoords;
  - the render registers, DISP3DCNT and the swap parameter;
  - the texture and palette slots as flat images (512 KB + 96 KB),
    rebuilt only when `vram.tex_gen` moves.
- **Engine A's composite planes**, from `engine2d.gpu_paint_line` and
  `gpu.gpu_line`, for each line whose composite holds 3D:
  - per dot, what `hd_dot` reads: the top and second layer under an
    opaque 3D pixel, their layer numbers, the window mask and the OBJ
    flags;
  - the dot as it is with a transparent 3D pixel, and the 1x dot;
  - per line, the blend settings, master brightness and BG0HOFS.

  None of it depends on the 3D line's values, so a line whose 2D inputs
  (the line cache's key and VRAM count) are unchanged keeps its planes
  (`gp_valid`).
- **Display capture's inputs**, from `gpu.gpu_valid`, before capture
  writes the line:
  - VRAM display's and source B's halfwords;
  - whether a capture's HD copy still stands for each (the `cap_1x` rule
    HD uses);
  - DISPCAPCNT and the display bank.

`web/nds/gpu3d.js` (`NdsGpu3d`) draws from that in the presenter's
WebGL2 context:

1. **Rows pass.** One fragment per (polygon, row): `draw_polygon`'s row
   setup.
   - This covers the two edge chains from the top vertex, swapped rows,
     x-major runs, the fill and wire-frame rules, the span ends'
     attributes (`edge_end`) and the AA data per edge.
   - It is written as 5 RGBA32I texels: which dots of the row are left
     edge dots, which are between and which are right edge dots, and
     how each is plotted.
2. **Dot pass.** One fragment per HD dot.
   - The dot walks the polygons binned to its 32x8 tile, in the
     hardware's drawing order.
   - For each polygon it reads that row's record and applies `plot_k`'s
     rules to the dot's state. The state is colour, depth, opaque and
     translucent IDs, flags, AA coverage and the layer behind, and it
     lives in registers.
   - So the parts a triangle rasteriser cannot keep are the
     hardware's:
     - the translucent-ID rule;
     - blending over a transparent rear plane;
     - shadow volume stencils;
     - the depth-equal tolerance;
     - the edge-marking overlap rule;
     - the AA layer behind.

     Polygons are interpolated along edges and spans as on the DS, not
     split into triangles. Texels are decoded in the shader from the slot
     images, all seven formats.
3. **Post pass.** Anti-aliasing, then edge marking (4 neighbours'
   IDs and depths), then fog. The result is the core's pixel format.
4. **Composite.** Both screens at k:
   - engine A's 3D lines take `hd_dot` / `effect_dot` / `bright_dot`
     per HD dot;
   - VRAM display reads the banks' HD copies where valid;
   - everything else is the 1x screens' dot.
5. **Capture.** The captured halfwords' HD sub-dots go into the
   destination bank's HD copy (two textures, swapped), from the HD
   composite or 3D and source B as `hd_line` does.

`render.nim`'s 64-bit arithmetic fits GLSL ES 3.00's 32-bit integers
exactly:

- `floor(a + (b - a) n / d)` is split as q / r.
- The edge slope's product stays under 2^29.
- `pfac` is a float estimate corrected exactly on two words.
- Depth, w and AA heights use a 32x32 -> 64 multiply on 16-bit limbs.
- The x-major AA step is `(dy * 1024 - 1) div |dx|`.

## Checked

- **Dumps.** `ndsrun --gpu-dump DIR@F,.. --hd K` writes the export with
  the software HD output beside it. `node tools/gpu3d/run.mjs DIR` draws
  each frame with gpu3d.js and compares.
  - The material: SoulSilver New Bark Town, Golden Sun's first field, and
    GS's title (dual-screen 3D: each screen alternately rendered,
    captured to bank D and shown by VRAM display), in runs of
    consecutive frames from a state.
  - Results:
    - 54 frames at 2x, 3x and 4x: every 3D frame and every screen
      identical.
    - Chromium (ANGLE Metal) and WebKit (Apple GPU) alike.
- **Live, in the app.** `node tools/gpu3d/live.mjs ROM STATE` loads a
  game and a state in headless Chromium, turns the core's software HD
  and the GPU path on at the same frame, and compares every frame's HD
  screens. Results: 120 frames each of the GS field, the GS title and
  SoulSilver, 100 % of dots equal.
- **The sweep.** `node tools/gpu3d/sweep.mjs OUT ROM...` boots each ROM
  in the web core with the software HD and the GPU path both on from
  power-on. Display capture's history is then the same for both. Every
  frame goes through the GPU, and every 4th frame's screens are compared
  with the core's. At k = 1 they are compared with the native screens,
  so this also checks that the GPU draws the native picture exactly.
  - What ran: 263 ROMs at 1x, 2x and 4x (`roms/3d`, polyrastertest,
    homebrew, the libnds examples, the BlocksDS 3D, capture and gl2d
    examples), 360 frames each with A/START/touch presses.
  - Results:
    - 789 of 789 runs identical over 38,181 compared frames.
    - polyrastertest driven through all 77 scenes in manual mode
      (`--hold 2@1-20 --repeat 0@40/14`): 599 frames a scale,
      identical.
  - What the sweep found and what was fixed:
    - Render-register writes mid-frame (`gpu_late`).
    - Frame reuse after such a split (`gpu_last`).
    - A switched-off DS showing the GPU's last picture.
    - A crash on a full Vertex RAM of strips, which lists more than
      6144 vertices.

    None was an edge or a dot rule: each showed whole frames from the
    wrong render.
- **The machine.** With the export on, the whole-state and screen
  hashes every 50 frames are identical to the export off (SoulSilver
  800 frames, GS field and title 600 each). All 16 DS suites
  (`tests/nds_*_test.nim`, `desktop_nds_test`) pass.

## Cost

**CPU: the export.** Host instructions over the same frames, `ndsrun
--perf-from`, macOS retired instructions:

| | HD off | export (`--gpu`) | software 2x | software 4x |
|---|---|---|---|---|
| SoulSilver walk, 800 frames | 38.5 G | 39.9 G (+3.7 %) | 66.7 G | 123.4 G |
| GS field, 600 frames | 73.1 G | 75.8 G (+3.7 %) | 103.9 G | 169.4 G |
| GS title, 600 frames | 88.9 G | 94.0 G (+5.7 %) | 171.1 G | 377.1 G |

The title's extra is its capture lines. Capture always redraws a line,
so its planes are made every frame.

**Browser, M2, Chromium**, `live.mjs`, 4x, unpaced ms a frame. The
"picture" is the scene upload plus the GPU passes, waited for each
frame:

| | native | software 4x | GPU 4x core | GPU 4x picture |
|---|---|---|---|---|
| GS field | 11.2 | 26.3 | 12.2 | 11.3 |
| GS title | 11.7 | 48.5 | 12.5 | 9.0 |
| SoulSilver | 3.4 | 5.7 | 3.4 | 3.1 |

The GPU's own time depends on its clock. The GS field's 3D pass is
5.4 ms with the GPU busy back to back, but 10.3 ms when the GPU idles
through each emulated frame and is only asked for one picture at a time.
In play the GPU's work overlaps the next frame's emulation. Paced (the
app's own loop, emulated frames a second, 60 = full speed):

| | native | software 4x | GPU 4x |
|---|---|---|---|
| GS field | 59.8 | 36.8 | 59.9 |
| GS title | 59.8 | 20.2 | 59.8 |
| SoulSilver | 59.8 | 60.0 | 59.8 |

The 3D pass alone by scale, from the dump harness on an M2 (Chromium,
GPU busy):

| | 2x | 3x | 4x |
|---|---|---|---|
| SoulSilver | 2.4 ms | 2.3 ms | 2.7 ms |
| GS field (~1600 polygons) | 3.9 ms | 3.9 ms | 5.8 ms |
| GS title | 3.4 ms | 4.5 ms | 5.9 ms (8.1 max) |

The composite and capture together take about 1 ms. The JS side
(vertex placement, bins, record table, uploads) takes 0.3-0.8 ms a frame.

**Uncapped** (`live.mjs`): frames back to back, each drawn to the canvas,
only the last waited for, so the GPU overlaps the next frame as in
fast-forward. Frames a second, measured at load about 8 (other jobs on
the Mac): compare within a row.

| | native | GPU 1x* | software 2x | GPU 2x | software 4x | GPU 4x |
|---|---|---|---|---|---|---|
| GS field | 64.5 | 59.5 | 46.9 | 60.2 | 29.2 | 61.5 |
| GS title | 60.6 | 54.9 | 31.9 | 56.0 | 15.6 | 54.6 |
| SoulSilver | 219.1 | 202.3 | 141.8 | 204.9 | 99.0 | 202.5 |

\*The GPU drawing the same 1x scene beside the core's own picture. This
is the GPU path's fixed cost, about 8 %, and the reason it stays off
at 1x.

**The 1x rasteriser** (`-d:nds_noraster`, a measurement build that
leaves the 1x frame undrawn; same frames, same run) takes 17 % of
SoulSilver's host instructions, 12 % of the GS field's and 24 % of the
GS title's.

- That is the most moving native 3D to the GPU could save. After the
  export's 4-6 %, the net is 6-20 %.
- It would need the 3D frame back on the CPU within the frame, for
  capture, the 2D composite and save states. WebGL2 can only do that
  by stalling.
- The GPU does draw 1x exactly (the sweep's k = 1), so correctness is
  not what holds it back.

## Trying it

```
tools/serve_nds_dev.sh                      # builds both cores, serves the app
# then open the app with ?gpu3d=1, or in the console:
ndsGpu3d(true)                              # localStorage "nds-gpu3d" keeps it
```

Settings > Nintendo DS > 3D resolution picks k as before; 2x-4x then
draw on the GPU.

- `ndsGpuBench(120)` gives the core's and the picture's ms a frame.
- `ndsGpu3d(false)` goes back to the software HD.
- With run-ahead on, the software HD is used.

## Tradeoffs and what is left

- **Run-ahead.** Its look-ahead frames run the core, and their captures
  would advance `cap_1x` without the GPU seeing them. The GPU path stands
  down while run-ahead is on (`ndsGpuActive`). Fix: export the look-ahead
  frames to the GPU too, or keep `cap_1x` per timeline.
- **A lost WebGL context** builds a new renderer. The banks' HD copies
  are lost with it: captured screens show 1x until the game captures
  again.
- **Phones.** Not measured on a device.
  - An A15-A17 GPU has about half the M2's throughput: 4x in GS would be
    roughly 10-20 ms of GPU time, 2x about a third of that.
  - Thermal limits matter more than on a Mac. 2x is the safe default
    there.
  - The CPU side is unchanged from 1x, which is the point.
- **iOS app and desktop.**
  - The shaders are plain GLSL ES 3.00 with integer textures.
  - The iOS app (Metal) needs a port to MSL. The logic is the same, and
    Metal has 64-bit integers, which would drop the two-word helpers.
  - The desktop app draws with SDL 3. SDL_GPU or OpenGL 3.3 would take
    the GLSL nearly as is.
- **Settings UI.** The prototype hangs off the existing 3D-resolution
  setting with a dev flag. Shipping it would add a "Draw HD 3D on the
  GPU" switch with auto-detection (WebGL2, integer textures, 5 draw
  buffers).
- **Faster still.** The dot pass is about 70 % of the GPU time.
  - The per-dot divisions (`lin` on equal-w spans, `pfac` on the others)
    could take a float estimate plus one integer correction, as `pfac`
    already does for its 64-bit case.
  - The rows pass could also skip rows the bins never reach.
- **Beyond the DS's look.** Once the GPU draws HD, things the software
  path could not afford come almost free:
  - edge marking and AA at N dots wide;
  - bilinear textures with colour-0 holes kept;
  - higher scales (6x, 8x: `HD_SUB` is exact at both).

  Each would leave dot-for-dot agreement with the software HD.

The **"just upscale" variant** is in gpu3d.js as `upscale(frame3d,
smooth)`. It scales the 1x 3D layer (nearest, or smoothed between the
dots showing 3D) and composites it at HD. It costs nothing on the CPU
and about 0.5 ms on the GPU. Against the real HD screens it matches 71 %
of the GS field's dots and 90 % of SoulSilver's. It keeps 2D crisp and
re-blends 3D over 2D at HD, but it adds no detail: no sub-dot edges, no
texel detail, outlines still 4 dots thick at 4x. A classic triangle
rasteriser (what most emulators do) was not built. It would be faster on
the GPU, but it loses the DS's edge rules, n-gon interpolation, the
translucent-ID rule and exact blending over a transparent clear (WebGL2
has no framebuffer fetch).

## Files

- `src/dingbat/nds/gpu3d/gpuexport.nim`: the scene's words and the slot
  images.
- `gpu3d.nim` (`set_gpu`, `export_gpu`), `gpu.nim` (`set_gpu`,
  `gpu_valid`, `gpu_line`, `gpu_frames`), `engine2d.nim`
  (`gpu_paint_line`, `gp_*`), `nds.nim set_gpu_export`, and savestate
  skip lists for all of them.
- `src/dingbat_nds_wasm.nim`:
  - `nds_set_gpu`, `nds_gpu_frames`;
  - `nds_gpu_scene` / `_len`;
  - `nds_gpu_tex` / `pal` / `plane` / `plane2` / `lines`.
- `web/nds/gpu3d.js`: the renderer.
- `web/glpresent.js`: `frame.glTexture`.
- `web/index.js`: `ndsGpu3d`, `ndsGpuTexture`, `ndsGpuBench`.
- `tools/ndsrun.nim`: `--gpu`, `--gpu-dump`.
- `tools/gpu3d/run.mjs`: the dump harness.
- `tools/gpu3d/live.mjs`: the live check and timings.
