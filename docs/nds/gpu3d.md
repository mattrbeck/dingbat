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
- **Moving the 1x renderer to the GPU by reading its frame back is not
  worth it.** Capture needs the dots on the CPU the moment the frame
  starts, and WebGL2 read-backs stall.
- **Leaving it out is (the skip, below).** Display capture is the only
  thing on the machine that reads the 3D dots, and the DS decides at
  line 0 whether a frame captures. A frame that does not is drawn by the
  GPU alone; the CPU walks its polygons' spans for the line budget only.
  The machine is unchanged, and the GPU path then runs 9-13 % *under*
  the CPU-only 1x where nothing captures.
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

## The skip: the CPU's 3D left out

The export above leaves the CPU drawing every frame's 3D at 1x, as
without the GPU, so at 1x the GPU path can only cost more. But the 3D
dots have four readers, and only one is the machine's:

| Reader | Needs |
|---|---|
| the screen | display only: the GPU draws it |
| display capture to VRAM | every dot, exactly (machine state) |
| RDLINES_COUNT, DISP3DCNT.12 | each line's cost: polygon spans, no dots |
| save states | nothing at a frame boundary (`dead_3d_frame`: zeros) |

Capture runs for a whole frame or not at all: `Gpu.start_line` latches
DISPCAPCNT's enable at line 0 (`capturing`). So the skip
(`Gpu3d.gpu_skip`, `nds.set_gpu_skip`, `--gpu-skip`, on in the web app
with the GPU path) decides per frame, exactly:

- At line 0, `px_need` = the frame captures (or the frontend wants the
  1x screens whole: `want_dots`, for a rewind thumbnail). Until then it
  is true, so a render in V-blank (a render-register write while lines
  are due) draws as before.
- A render that needs no dots runs `render.render_costs` instead of
  `render_frame`: `draw_polygon[1, false]` walks each polygon's rows and
  spans and charges them (`charge`) without plotting or decoding
  texels. The line costs, RDLINES and the underflow flag come out as a
  full render's (`tests/nds_3d_test.nim` checks every scene).
- The display's 3D line is not pulled (`touch_line`: the render
  happens on time, for the costs and the export, no dots copied).
  Engine A composites with an all-transparent 3D line (`gpu.none3d`).
- Frame reuse needs the dots when this render does (`px_ok`); a state
  taken mid-frame (debugger only) draws a skipped render's dots first
  (`settle_dots`).

What this leaves:

- **The machine is the same.** Every state field matches the skip off,
  in SoulSilver, the GS field and the GS title (sampled at 9 frames),
  except two display copies the state holds: the last picture of each
  screen (`Gpu.top` / `bottom`) and the 3D line buffer, which lack the
  3D in skipped frames. A state loaded elsewhere shows that picture
  until its next frame is drawn.
- **The core's own 1x screens lack the 3D** in skipped frames. The web
  app takes its pictures (library, paused hero, state-slot thumbnail,
  screenshot, Report a Bug) from the GPU's screens instead
  (`ndsGpuRgba`). Rewind thumbnails are taken by the core, so a frame
  that will have one is drawn whole (`want_dots`, one frame a second).
- **Games that capture every frame gain nothing**: GS's title.

**Step 2, the planes in one pass.** `gpu_paint_line` drew engine A's
line twice more for the planes: with a transparent 3D layer
(`render_hd_sub`) and with an opaque one (`hd_prepare`). In a skipped
frame the line itself was drawn with a transparent 3D layer, so its
`gfx` and `line` are the first of those (`clear3d`). The line cache
also reuses such lines now that the 3D's values are not in them; it
does so only when the line's planes are kept too, since a reused line
leaves no layer scratch to make planes from (`gp_on`).

**Step 3, the handoff trimmed.**

- *The cost pass on a bound.* RDLINES and the underflow flag (sticky:
  every frame's counts) only fall as line costs rise (`budget`: a line
  finishes no sooner). `render.cost_bound` charges every polygon on
  every row between its top and bottom vertices with its vertices' x
  range plus a dot each side, one pass over the vertices and no edge
  walked; it is at least each line's cost (`tests/nds_3d_test.nim`,
  every scene). When it already leaves the cache full and no underflow
  (`costs_fit`), so do the exact costs, and `render_costs` does not run;
  otherwise it does. That settles 85 % of SoulSilver's skipped renders
  and 96 % of the GS field's. `-d:nds_cost_check` runs both and asserts
  RDLINES and the flag agree.
- *The capture inputs only where they are read.* `gpu_valid` (and
  `hd_pre` before it) made `gpu_plane2` on every line; the GPU reads it
  only on lines captured or shown from VRAM, so it runs on those alone.
- *Only changed rows uploaded.* The core stamps each row of the planes
  with the export epoch it was written at (`gpu_row_at`, `gpu_row2_at`;
  `gpu_epoch` counts frames exported by any core and never goes back),
  and the page uploads only the rows stamped since its last upload
  (`NdsGpu3d.planeRows`). Lines whose planes the line cache kept, and
  `gpu_plane2` outside captures, are not sent again.
- *An unchanged scene not drawn again.* A frame that reused the last
  render exports the same scene and gen (`scene_serial`, unique across
  cores), so the page skips binning, uploads and the 3D passes and
  composites over the `out3d` it has (not after late parts, which leave
  it mixed).

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
- **The skip.** `sweep.mjs --skip` runs a second core with the skip
  (no HD, the GPU drawing every scale) in step with a reference core
  (software HD, or native at k = 1) and compares the GPU's screens with
  the reference's. 787 of 789 runs identical at 1x, 2x and 4x. The
  other two (`dsma_stress_test` 2x, `scene_ups` 4x) differ in one frame
  each and are identical on two re-runs. The web core's RTC reads the
  host clock, so two cores can run apart: the stress test's differing
  dots are its own timing printout. With a fixed clock (`ndsrun`) both
  ROMs' states match the skip off. Also: the dump harness on skip-mode
  planes (32 frames of the GS field, title and SoulSilver at 2x and 4x,
  all identical); `live.mjs`'s 1x check (60 frames each, the GPU's
  screens equal to the native ones, the pictures taken from them too);
  `tests/nds_3d_test.nim` (line costs); state field diffs (above).
- **Step 3.** The sweep with `--skip`, drawing as the app does (the
  scene only when its gen is new, only the plane rows written since
  the last upload): 789 of 789 runs identical. `live.mjs` in all three
  scenes: 100 %. `-d:nds_cost_check` agreed in every frame of the
  three scenes; their state hashes match the skip before step 3.
  `tests/nds_3d_test.nim` also checks the bound against every scene's
  line costs, and that turning the export on again over a still scene
  draws the planes afresh: before, a line whose planes were kept went
  on being taken as kept in the new, zeroed planes (`set_gp_on`), so
  every painted line came out blank until it changed. The page turns
  the export on again whenever it applies the display settings.
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

Where the export's own cost goes (measurement builds that each leave
one part out): the composite planes are about 88 % of it (3.4-5.3 % of
the frame), the scene 0.3-0.6 %, the slot images about nothing.

**With the skip** (host instructions against the GPU off, same frames;
"skip" includes step 2):

| | export | skip, step 1 only | skip | skip + step 3 | no 1x rasteriser |
|---|---|---|---|---|---|
| SoulSilver walk | +3.9 % | -12.5 % | -12.6 % | **-16.0 %** | -16.8 % |
| GS field | +3.9 % | -7.2 % | -8.9 % | **-10.1 %** | -11.6 % |
| GS title (captures every frame) | +5.9 % | +5.8 % | +5.5 % | +5.5 % | |

"No 1x rasteriser" (`-d:nds_noraster`, GPU off) is the floor: the CPU
doing nothing for the 3D. Step 3 leaves 0.8-1.5 points above it.
Parts of step 3, same frames:

- The cost bound: 0.5 points in each. (The cost pass itself was 0.5 %
  of SoulSilver, not the 2.6 % first noted, a run that left out the
  state hashing of the others; the bound leaves 0.03 % of it.)
- `gpu_valid` and `hd_pre` on capture and VRAM-display lines only: 3
  points in SoulSilver, 1 in the GS field.
- `hd_prepare` (the planes' second compositing) now costs 0.1-0.2 %
  (a measurement build without it), as the plane cache keeps most
  lines: merging it into the line's own compositing is not worth it.

(Host instruction counts move by up to 0.7 % between runs of the same
binary on a busy Mac; each row above is from one run.)

In the app (`live.mjs`, uncapped frames a second, load 16-33; the
states stand still, so many frames reuse the last render and leave
less to skip than the walks above):

| | native | GPU 1x, no skip | GPU 1x | GPU 4x, no skip | GPU 4x |
|---|---|---|---|---|---|
| GS field | 61.0 | 58.8 | **64.7** | 57.3 | 59.5 |
| GS title | 67.3 | 62.8 | 62.0 | 50.4 | 46.2 |
| SoulSilver | 198.7 | 190.7 | 195.1 | 187.7 | 184.9 |

The GS title captures every frame: the skip does nothing there, and its
two columns differ by noise.

With step 3, on a quiet Mac (load 4-7), each mode run twice in
alternation (`live.mjs --uncapped`), frames a second:

| | native | GPU 1x, no skip | GPU 1x | GPU 4x |
|---|---|---|---|---|
| GS field | 87.3 / 85.9 | 81.5 / 80.6 | **94.5 / 95.0** | **94.5 / 94.5** |
| SoulSilver, standing | 293.1 / 293.4 | 291.1 / 291.1 | **302.9 / 299.9** | 299.0 / 297.6 |

The GS field at 4x on the GPU now runs faster than at 1x without it.
The page's own work per frame (`drawGame` with the GPU branch: the
scene's JS, the uploads, the GL calls; the GPU's time overlaps), with
step 3's uploads and scene check against the planes uploaded whole
and the scene drawn every frame (`GPU ... full`):

| | GPU 1x full | GPU 1x | GPU 4x full | GPU 4x |
|---|---|---|---|---|
| GS field | 0.31 ms | 0.15 ms | 0.43 ms | 0.21 ms |
| GS title | 0.22 ms | 0.22 ms | 0.35 ms | 0.34 ms |
| SoulSilver | 0.18 ms | 0.04 ms | 0.19 ms | 0.03 ms |

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
- The GPU path now draws at 1x too, with the skip.
  `ndsGpuSkip(false)` (or `?gpu3d-skip=0`) keeps the CPU's 3D, as
  before.
- With run-ahead on, the software HD is used.

## Tradeoffs and what is left

- **Frames that capture** still draw their 3D on the CPU: the bank's
  bytes are machine state. *Lazy capture* would let the GPU capture
  too and owe the bytes to the machine, read back from the GPU only
  when something besides the display reads the bank (the CPUs, DMA, a
  state). The survey (`-d:nds_cap_survey`, `gpu/capsurvey.nim`: per
  capture, what reads the bank before the next capture into it) says
  where that would pay:
  - **GS** captures 2D+3D every frame on its title and intro (600 of
    600 frames from the title state, 1276 of the first 3000 from
    power-on), and each capture is copied to main RAM (DMA or a BIOS
    copy, a whole screen a frame) besides being shown. Lazy capture
    would read back every frame: a stall each frame in WebGL2, for the
    ~2.8 ms the CPU's rasteriser takes there. Not worth it on the web.
    SoulSilver and PMD (first 3000 frames, and SoulSilver's walk)
    never capture.
  - **The 263 sweep ROMs**: 18 capture. 12 read the bank only through
    the display, capture source B, the 2D engines or 3D textures
    (dual-screen 3D, motion blur, render to texture, volumetric
    shadows); 6 read it with the CPU or DMA (bloom, two-pass 3D, two
    test ROMs, a demo).
  - The display-only cases need more than the capture on the GPU:
    engine B's BG/OBJ and the 3D's textures read the bank too, so the
    GPU would draw those from its copy as well.
  - Native builds with unified memory (iOS Metal, Apple silicon) could
    read back without the copy's cost, waiting on a fence only when the
    machine first reads the bank: the later GS's copy comes after its
    capture, the more of the GPU's work it overlaps (not measured).

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
- The skip: `render.nim render_costs` (`draw_polygon[S, P]`),
  `gpu3d.nim` (`gpu_skip`, `px_need`, `px_ok`, `touch_line`,
  `settle_dots`), `gpu.nim` (`none3d`, `gpu_skipping`, `want_dots`),
  `engine2d.nim` (`gpu_paint_line`'s `clear3d`, `gp_on`),
  `rewinding.nim nds_rewind_frame`, `rewind.nim thumb_next`,
  `nds_set_gpu_skip`, `index.js ndsGpuSkip` / `ndsGpuRgba`.
- `tools/ndsrun.nim`: `--gpu`, `--gpu-skip`, `--gpu-dump`.
- `tools/gpu3d/run.mjs`: the dump harness.
- `tools/gpu3d/live.mjs`: the live check and timings (`--uncapped`
  picks and orders the uncapped modes; `GPU ... full` uploads the
  planes whole and draws every scene).
- Step 3: `render.nim cost_bound` / `costs_fit`, `gpu3d.nim`
  (`cost_fits`, `scene_serial`, `-d:nds_cost_check`), `gpu.nim`
  (`gpu_epoch`, `gpu_row_at` / `gpu_row2_at`, `gpu_valid` on capture
  and VRAM-display lines only), `nds_gpu_epoch` / `nds_gpu_rows`,
  `gpu3d.js planeRows`, `index.js ndsGpuTexture`.
- `src/dingbat/nds/gpu/capsurvey.nim`: the capture survey
  (`-d:nds_cap_survey`, hooks in gpu.nim, bus9.nim, bus7.nim, ndsrun).
