# The desktop presenter: OpenGL and Metal

How the desktop app (`src/dingbat.nim`) draws the game picture and the UI.
Windows and Linux draw with OpenGL 3.3 core; macOS draws with Metal only,
chosen when building (every Mac that runs macOS 11, the app's minimum, has
Metal; a Mac without a device says so and quits). The comparisons below
were measured while macOS could still draw with OpenGL too.

## One design, two backends

- `frontend/presenter.nim`: the calls `dingbat.nim` makes, in the same order
  each present: `begin` (clear) → `game_upload` → `draw_game` / `draw_logo`
  → `read` (a capture) → `imgui_new_frame` … `imgui_render` → `read` (a GUI
  driver shot) → `present`. Rects are back-buffer pixels from the bottom
  left, as `glViewport`'s. ImGui images go through `ui_texture`.
- `frontend/present_shader.nim`: the game shader written once. A prelude
  per language maps the shared body (`float3`, the uniform block `u`, the
  texel fetch) onto GLSL 3.30 or Metal Shading Language, so every filter
  and look (none / hq4x / xBR / LCD grid / RGB subpixels, both colour
  models, the shade palette, the SGB border) is the same code on both.
  `Look` is the block's contents.
- `frontend/presenter_gl.nim`: the OpenGL backend. Its picture is byte for
  byte what the app drew before the split (every look, captured).
- `frontend/presenter_metal.mm`: the Metal backend. A `CAMetalLayer` from
  `SDL_Metal_CreateView`; one command buffer a present, committed with the
  drawable at `present`. `displaySyncEnabled = NO`, as OpenGL's swap
  interval 0: `main()`'s frame scheduler and swap hold pace both backends
  unchanged. ImGui draws through Dear ImGui's Metal backend
  (`frontend/vendor/`, unmodified; imguin ships only its header).

Metal details that matter:

- The game and border textures are `R16Uint` holding the core's BGR555
  words; the shader reads them with OpenGL's NEAREST + REPEAT texel rule
  (the quad's `tex_coord.y` runs 0 to -1, as on OpenGL). Works on any
  Metal Mac (no packed 16-bit formats needed).
- A filter's neighbour past the picture's edge reads the edge texel
  (`srctex` clamps before the fetch), on both backends, as the web's and
  iOS's presenters do; the wrap above only maps the flipped quad.
- The game texture is a ring of 3 written with `replaceRegion`; at most 2
  presents are on the GPU, so a texture still being read is never written.
- `read` (captures, `shot`) ends the pass, blits the drawable into a
  buffer and waits; the present goes on in a new command buffer. The
  layer is `framebufferOnly = NO` only when a read can happen
  (`--capture`, `-d:gui_driver` builds).
- The shader compiles with fast math off (`MTLMathModeSafe`).
- ImGui's Metal pipeline always filters linearly; the GB debug windows'
  tile and map views (NEAREST on OpenGL) are drawn between
  `ui_nearest_begin` / `ui_nearest_end`, a draw callback that switches to
  a nearest-sampling copy of that pipeline.
- The DS's HD 3D is the core's software renderer on the desktop: a
  256k x 384k texture, uploaded like any other picture. The iOS app's
  Metal 3D renderer (`ios/Dingbat/Sources/NdsGpu3d*.swift`) is not on the
  desktop.

## How they compare (2026-11-16, Apple silicon, macOS 26.6)

Captures (`--capture`, hidden window, scratch HOME) of every look, Metal
against this Mac's OpenGL (max channel difference / channels that differ):

| | Metal vs OpenGL |
|---|---|
| GBA blendprobe: none, colour off, LCD response, stretch, xBR, hq4x, grid | 2 / ~5 % |
| GBA blendprobe: RGB subpixels | 3 / 11 % |
| DMG (shade palette): none, grid, RGB | 0 |
| DMG: hq4x, xBR | 1 / 4 channels |
| GBC: colour on, off, LCD response | 0 |
| SGB with border: none, grid, hq4x, RGB / xBR | 1 / 2 |
| DS gx_tri: none, grid, HD 2x, HD 4x | 2 / ~2 % |
| DS: hq4x | 10 at 24 pixels |
| DS: HD 2x + xBR | 5 at a few pixels |
| Home screen logo | 0 |
| ImGui menu bar, open menu | 2 (the game behind) |
| Save States grid | 109 at the thumbnail's top edge |

The spread is OpenGL's, not Metal's: macOS's OpenGL samples its RGB5
texture a level or two off v/31 (a 5-bit 3 reads 24, not 25; 16 reads 134,
not 132), and Metal reads exactly v/31. Against
`tests/golden/desktop-blendprobe.png` (llvmpipe), Metal is 2 levels off on
6 % of channels, this Mac's OpenGL 2 levels on 9 %. Where hq4x and xBR
decide on a threshold, a level's difference flips a few edge pixels. ImGui
images (the Save States thumbnails) clamp at their edges on both backends.

Pacing, `DINGBAT_FRAME_TRACE`, 10 s, hidden window, muted (ms, median /
p99; the window is hidden, so these are CPU times, not glass times):

| | swap call | start to swapped | frame interval sd |
|---|---|---|---|
| GBA, OpenGL (3 runs) | 0.28-0.66 / 5.7-6.0 | 0.8-1.4 / 6.3-6.7 | 1.3-1.4 |
| GBA, Metal (2 runs) | 0.01-0.02 / 0.04 | 0.54-0.64 / 0.61-0.67 | 0.07-0.19 |
| DS HD 2x, OpenGL | 0.49-0.65 / 5.4-6.3 | 3.3-4.6 / 9.1-10.2 | 1.2-1.3 |
| DS HD 2x, Metal | 0.02 / 0.05 | 2.96 / 3.20 | 0.27 |

`DINGBAT_LATENCY_TEST=40` (m7_demo, press to swapped), avg / max: OpenGL
10.9 / 18.2 and 10.8 / 22.3, Metal 9.9 / 17.5.

With Metal the trace's `shown` column is each present's real time on the
glass (the drawable's `presentedTime`); 0 on OpenGL and in a hidden window.
Glass-to-glass pacing has to be measured with the window shown.

## Not done

- A `CAMetalDisplayLink` or `presentsWithTransaction` loop: the scheduler
  and swap hold are kept as they are, so both backends pace alike.
  `DINGBAT_METAL_VSYNC=1` turns the layer's display sync on, for trying
  (in a hidden window it measures the same as off).
- `-d:gputime` (GPU time of the game quad) is OpenGL only: Windows and
  Linux. On macOS it is a build error.

## CPU cost, Metal vs OpenGL on macOS

Pokemon Emerald's overworld (Littleroot, from a quick save), one
gui_driver binary, hidden and muted window, Apple M2, macOS 26.6; each
figure is the difference between a 26 s and a 6 s run (20 s of steady
state, boot excluded), two runs each; instructions and cycles from
`/usr/bin/time -l`, CPU-side only:

| | Metal | OpenGL |
|---|---|---|
| normal speed: share of one core | 8.1 % | 10.3-11.7 % |
| normal speed: cycles per second | ~242 M | ~305 M |
| normal speed: instructions per frame | 14.4 M | 15.7 M |
| paused (62 presents/s, UI only): cycles per present | 1.6 M | 2.8 M |
| fast-forward, uncapped | ~1220 fps | ~1230 fps |

Fast-forward is emulation-bound: about 1220 frames are emulated a second
but only about 60 presented, so presenting is ~4 % of the work there and
Metal's saving (~2 %) is inside the runs' ±5 % spread. xBR changes neither
backend's CPU figures (it runs on the GPU).
