import std/[os, hashes, math, parseopt, strformat, strutils, tables, times, algorithm]
import std/[net, nativesockets]
import sdl2 except init, quit, glBindTexture, glUnbindTexture
import sdl2/joystick
import sdl2/gamecontroller
import zippy/ziparchives
import imguin/[cimgui, impl_opengl, impl_sdl2]
import imguin/glad/gl
import stb_image/read as stbi
import stb_image/write as stbiw
import dingbat/common/config
import dingbat/common/lcd_response
import dingbat/common/input
import dingbat/common/rewind
import dingbat/gba/gba
import dingbat/gba/netlink
import dingbat/gb/gb
import dingbat/frontend/file_explorer
import dingbat/frontend/config_editor
import dingbat/frontend/keybindings_widget
import dingbat/frontend/controller_widget
import dingbat/frontend/gba_debug
import dingbat/frontend/gb_debug
import dingbat/frontend/cheats_widget
import dingbat/frontend/save_states_widget
import dingbat/common/cheats
import dingbat/common/serialize

const VERSION = "0.1.0"
const GBA_W   = 240
const GBA_H   = 160
const GB_W    = 160
const GB_H    = 144

const KMOD_SHIFT_MASK = int16(0x0003)  # LSHIFT | RSHIFT

# Mod key mask for keyboard shortcuts (raw int16 from modstate)
when defined(macosx):
  const MOD_KEY_MASK = int16(0x0C00)  # LGUI | RGUI
  const MOD_KEY_STR  = "Cmd"
else:
  const MOD_KEY_MASK = int16(0x00C0)  # LCTRL | RCTRL
  const MOD_KEY_STR  = "Ctrl"

const LOGO_PNG_DATA = staticRead("../README/dingbat.png")

# The sdl2 wrapper doesn't expose SDL_free (needed for drop-event filenames)
proc sdl_free(mem: pointer) {.importc: "SDL_free", cdecl.}
# ...nor SDL_GameControllerRumble (SDL >= 2.0.9; the linked SDL2 is newer).
# Magnitudes are 0..0xFFFF; the effect auto-stops after duration_ms.
proc game_controller_rumble(pad: GameControllerPtr;
                            low_freq, high_freq: uint16;
                            duration_ms: uint32): cint
  {.importc: "SDL_GameControllerRumble", cdecl.}

# ──────────────────────────── Shaders ────────────────────────────

const VERT_SRC = """
#version 330 core
out vec2 tex_coord;
const vec2 vertices[4] = vec2[](vec2(-1.0,-1.0),vec2(1.0,-1.0),vec2(-1.0,1.0),vec2(1.0,1.0));
void main() {
  gl_Position = vec4(vertices[gl_VertexID], 0.0, 1.0);
  tex_coord = (vertices[gl_VertexID] + 1.0) / vec2(2.0, -2.0);
}
"""

# Color correction has one model per panel (selected by panel_gbc):
#  - GBA: mGBA-style AGB model (linearize with lcdGamma 4.0, mix, re-gamma)
#  - GB/GBC: Pokefan531's hardware-measured "GBC-Color" model — the CGB
#    panel is far less washed out than the AGB's, so the GBA curve would
#    crush its colors. Both match the wasm build's LUTs and the screenshot
#    path (bgr555_to_rgb) exactly.
#
# The upscale filters (hq4x / xBR) below are CLEAN-ROOM implementations written
# from published ALGORITHM DESCRIPTIONS — Hyllian's xBR tutorial (the weighted
# YUV 48:7:6 distance and the wd_red<wd_blue edge rule), the ubitux "Butchering
# HQX" write-up, and Wikipedia's hqx/pixel-art-scaling pages. No GPL/LGPL shader
# source was copied; the math is reimplemented in fragment form. The same code
# is mirrored in web/index.js's GLSL ES 300 shader.
const FRAG_SRC = """
#version 330 core
in vec2 tex_coord;
out vec4 frag_color;
uniform sampler2D input_texture;
uniform sampler2D border_texture;
uniform bool color_correct;
uniform bool panel_gbc;
uniform bool scanlines;
uniform float tex_width;
uniform float tex_height;
// The pixel-row pitch the scanline effect uses. Equal to tex_height without a
// border; with one it is the OUTPUT height (224), because the SGB border and
// the Game Boy window are both native rows of the same 224-row picture. Feed
// tex_height here instead and the border gets 144-row scanlines over 224 rows.
uniform float scan_height;
// SGB border: a 256x224 RGB5_A1 layer drawn over the whole quad, with the
// Game Boy window composited into the 160x144 rect at (48, 40). Alpha 0 is
// SNES colour 0 -- transparent, so the window (or the backdrop) shows through.
uniform bool sgb_border;
uniform vec3 sgb_backdrop;
uniform int filter_mode;   // 0 = none, 1 = hq4x, 2 = xBR

vec3 srctex(vec2 uv) { return texture(input_texture, uv).rgb; }

// BT.601 YUV; the perceptual space both filters classify edges in.
vec3 yuv(vec3 c) {
  return vec3(dot(c, vec3( 0.299,  0.587,  0.114)),
              dot(c, vec3(-0.169, -0.331,  0.500)),
              dot(c, vec3( 0.500, -0.419, -0.081)));
}
// xBR weighted color distance: 48*|dY| + 7*|dU| + 6*|dV|.
float df(vec3 a, vec3 b) {
  vec3 d = abs(yuv(a) - yuv(b));
  return d.x * 48.0 + d.y * 7.0 + d.z * 6.0;
}
// hqx similar/different test: per-channel YUV thresholds 48,7,6 (8-bit units).
bool similar(vec3 a, vec3 b) {
  vec3 d = abs(yuv(a) - yuv(b));
  return d.x <= 48.0/255.0 && d.y <= 7.0/255.0 && d.z <= 6.0/255.0;
}

// Sample the source texel-neighborhood around uv and smooth the pixel-art edge
// the fragment sits on. filter_mode picks the algorithm.
vec3 upscale(vec2 uv, vec2 tsz) {
  vec3 E = srctex(uv);
  if (filter_mode == 0) return E;
  vec2 t  = 1.0 / tsz;
  vec2 fp = fract(uv * tsz);                 // sub-texel position, 0.5 = center
  float sx = fp.x < 0.5 ? -1.0 : 1.0;        // which diagonal corner we're in
  float sy = fp.y < 0.5 ? -1.0 : 1.0;
  float lx = sx > 0.0 ? fp.x : 1.0 - fp.x;   // corner-local: 0.5 at center..1 far
  float ly = sy > 0.0 ? fp.y : 1.0 - fp.y;
  // ramp across the anti-diagonal through the active corner (lv2-style AA)
  float w = smoothstep(0.15, 0.85, lx + ly - 1.0);
  vec3 Ph = srctex(uv + t * vec2(sx, 0.0));  // horizontal edge neighbor
  vec3 Pv = srctex(uv + t * vec2(0.0, sy));  // vertical edge neighbor
  vec3 X  = srctex(uv + t * vec2(sx, sy));   // diagonal neighbor

  if (filter_mode == 1) {                    // hq4x-style (threshold + 3px blend)
    if (!similar(E, Ph) && !similar(E, Pv) && similar(Ph, Pv))
      return mix(E, 0.5 * (Ph + Pv), w);
    return E;
  }
  // filter_mode == 2: xBR-lv2 edge-directed interpolation
  vec3 C  = srctex(uv + t * vec2( sx, -sy));
  vec3 G  = srctex(uv + t * vec2(-sx,  sy));
  vec3 F4 = srctex(uv + t * vec2( 2.0 * sx, 0.0));
  vec3 H5 = srctex(uv + t * vec2( 0.0, 2.0 * sy));
  vec3 D  = srctex(uv + t * vec2(-sx, 0.0));
  vec3 I5 = srctex(uv + t * vec2( sx, 2.0 * sy));
  vec3 I4 = srctex(uv + t * vec2( 2.0 * sx, sy));
  vec3 B  = srctex(uv + t * vec2( 0.0, -sy));
  float wd_red  = df(E, C) + df(E, G) + df(X, F4) + df(X, H5) + 4.0 * df(Pv, Ph);
  float wd_blue = df(Pv, D) + df(Pv, I5) + df(Ph, I4) + df(Ph, B) + 4.0 * df(E, X);
  if (wd_red < wd_blue) {
    vec3 px = df(E, Ph) <= df(E, Pv) ? Ph : Pv;
    return mix(E, px, w);
  }
  return E;
}

vec3 correct(vec3 c) {
  float outGamma = 2.2;
  if (panel_gbc) {
    vec3 lin = pow(c, vec3(2.2)) * 0.94;
    return pow(clamp(vec3(
      0.82 * lin.r + 0.125 * lin.g + 0.195 * lin.b,
      0.24 * lin.r + 0.665 * lin.g + 0.075 * lin.b,
     -0.06 * lin.r + 0.210 * lin.g + 0.730 * lin.b), 0.0, 1.0),
      vec3(1.0 / outGamma));
  }
  float lcdGamma = 4.0;
  vec3 lin = pow(c, vec3(lcdGamma));
  return pow(vec3(
      0.0 * lin.b +  50.0 * lin.g + 255.0 * lin.r,
     30.0 * lin.b + 230.0 * lin.g +  10.0 * lin.r,
    220.0 * lin.b +  10.0 * lin.g +  50.0 * lin.r) / 255.0,
    vec3(1.0 / outGamma));
}

// The Game Boy layer, with every filter the no-border path applies.
vec3 gb_layer(vec2 uv) {
  vec3 raw = upscale(uv, vec2(tex_width, tex_height));
  return color_correct ? correct(raw) : raw;
}

void main() {
  vec3 rgb;
  if (sgb_border) {
    vec4 b = texture(border_texture, tex_coord);
    if (b.a > 0.5) {
      // Border art is native SNES output, not an LCD panel: no colour
      // correction, and the upscale filters stay off it (they are tuned for
      // 2bpp pixel art and smear 4bpp tiles).
      rgb = b.rgb;
    } else {
      // tex_coord.y runs 0 -> -1 (the vertex shader flips there), so the
      // window rectangle has to be worked out in un-flipped space and the
      // result flipped back for the sampler.
      vec2 up = vec2(tex_coord.x, -tex_coord.y) * vec2(256.0, 224.0);
      vec2 guv = (up - vec2(48.0, 40.0)) / vec2(160.0, 144.0);
      rgb = (guv.x >= 0.0 && guv.x < 1.0 && guv.y >= 0.0 && guv.y < 1.0)
            ? gb_layer(vec2(guv.x, -guv.y)) : sgb_backdrop;
    }
  } else {
    rgb = gb_layer(tex_coord);
  }
  if (scanlines && fract(tex_coord.y * scan_height) < 0.3) {
    rgb *= 0.72;
  }
  frag_color = vec4(rgb, 1.0);
}
"""

const LOGO_VERT_SRC = """
#version 330 core
out vec2 tex_coord;
uniform float aspect;
uniform float scale;
const vec2 vertices[4] = vec2[](vec2(-1.0,-1.0),vec2(1.0,-1.0),vec2(-1.0,1.0),vec2(1.0,1.0));
void main() {
  vec2 scaled_xy = vec2(vertices[gl_VertexID]) * scale;
  gl_Position = vec4(scaled_xy.x, scaled_xy.y * aspect, 0.0, 1.0);
  tex_coord = (vertices[gl_VertexID] + 1.0) / vec2(2.0, -2.0);
}
"""

const LOGO_FRAG_SRC = """
#version 330 core
in vec2 tex_coord;
out vec4 frag_color;
uniform sampler2D input_texture;
void main() { frag_color = texture(input_texture, tex_coord); }
"""

# ──────────────────────────── Helpers ────────────────────────────

proc print_help() =
  echo "dingbat - A GBA emulator"
  echo ""
  echo "Usage: dingbat [options] [BIOS] [ROM]"
  echo ""
  echo "Options:"
  echo "  -h, --help       Show this help message"
  echo "  --hle            Use HLE BIOS (no external BIOS file needed)"
  echo "  --hle-after-bios Run real BIOS for init, then use HLE for SWI calls"
  echo "  --run-bios       Run the BIOS on startup"
  echo "  --skip-bios      Skip the BIOS on startup (default)"
  echo "  --version        Print version"
  echo ""
  echo "Network link (2-player, GBA only — run the same ROM on both sides):"
  echo "  --listen PORT       Host the link on PORT (this side is unit 0)"
  echo "  --connect HOST:PORT Join a host's link (this side is unit 1)"
  echo "  --netlink-delay-ms N  Add N ms of send latency (network simulation)"
  echo "  --link-auto         Zero-config auto-pair on localhost (same as opening"
  echo "                      the Link Cable window; for testing two local copies)"
  echo ""
  echo "Verification:"
  echo "  --capture N:PATH    After N presented frames, write the GL back buffer"
  echo "                      (the real composited picture, letterbox excluded)"
  echo "                      to PATH as a PNG and exit"

proc compile_shader(src: string; shader_type: GLenum): GLuint =
  result = glCreateShader(shader_type)
  var src_ptr = cstring(src)
  glShaderSource(result, 1, cast[cstringArray](addr src_ptr), nil)
  glCompileShader(result)
  var status: GLint = 0
  glGetShaderiv(result, GL_COMPILE_STATUS, addr status)
  if status == 0:
    var log_len: GLint = 0
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, addr log_len)
    var log_buf = newString(log_len + 1)
    glGetShaderInfoLog(result, log_len, nil, cstring(log_buf))
    echo "Shader compile error: ", log_buf
    sdl2.quit(); system.quit(1)

proc create_shader_program(): GLuint =
  let vert = compile_shader(VERT_SRC, GL_VERTEX_SHADER)
  let frag = compile_shader(FRAG_SRC, GL_FRAGMENT_SHADER)
  result = glCreateProgram()
  glAttachShader(result, vert)
  glAttachShader(result, frag)
  glLinkProgram(result)
  var status: GLint = 0
  glGetProgramiv(result, GL_LINK_STATUS, addr status)
  if status == 0:
    var log_len: GLint = 0
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, addr log_len)
    var log_buf = newString(log_len + 1)
    glGetProgramInfoLog(result, log_len, nil, cstring(log_buf))
    echo "Shader link error: ", log_buf
    sdl2.quit(); system.quit(1)
  glDeleteShader(vert)
  glDeleteShader(frag)

proc create_logo_shader_program(): GLuint =
  let vert = compile_shader(LOGO_VERT_SRC, GL_VERTEX_SHADER)
  let frag = compile_shader(LOGO_FRAG_SRC, GL_FRAGMENT_SHADER)
  result = glCreateProgram()
  glAttachShader(result, vert)
  glAttachShader(result, frag)
  glLinkProgram(result)
  var status: GLint = 0
  glGetProgramiv(result, GL_LINK_STATUS, addr status)
  if status == 0:
    var log_len: GLint = 0
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, addr log_len)
    var log_buf = newString(log_len + 1)
    glGetProgramInfoLog(result, log_len, nil, cstring(log_buf))
    echo "Logo shader link error: ", log_buf
    sdl2.quit(); system.quit(1)
  glDeleteShader(vert)
  glDeleteShader(frag)

proc setup_game_texture(): GLuint =
  glGenTextures(1, addr result)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_NEAREST))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_NEAREST))

proc load_logo_texture(): (GLuint, float32) =
  var buf = newSeq[byte](LOGO_PNG_DATA.len)
  for i, c in LOGO_PNG_DATA: buf[i] = byte(c)
  var w, h, comp: int
  let pixels = stbi.loadFromMemory(buf, w, h, comp, stbi.RGBA)
  var tex: GLuint
  glGenTextures(1, addr tex)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, tex)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_NEAREST))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_NEAREST))
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), GLsizei(w), GLsizei(h), 0,
               GL_RGBA, GL_UNSIGNED_BYTE,
               unsafeAddr pixels[0])
  let canvas_aspect = float32(h) / float32(w)
  result = (tex, canvas_aspect)

# --capture N:PATH. Reads the actual GL back buffer, so it proves the shader
# path rather than the core's buffers. -1 disables.
var capture_after = -1
var capture_path  = ""
var present_count = 0

proc setup_border_texture(): GLuint =
  glGenTextures(1, addr result)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_NEAREST))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_NEAREST))
  # Wrap mode is deliberately left at the default REPEAT, matching the game
  # texture. VERT_SRC emits tex_coord.y in [0, -1] (it flips the image by
  # dividing by -2), so every fetch is at a negative V and only REPEAT brings
  # it back into range. CLAMP_TO_EDGE here pins the whole border to row 0 --
  # which looks like "the border is a set of vertical stripes".
  # RGB5_A1 with 1_5_5_5_REV is exactly the core's border format: BGR555 in
  # bits 0-14 and the opaque flag in bit 15 land straight in RGB and A.
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGB5_A1), GLsizei(256), GLsizei(224),
               0, GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV, nil)
  glActiveTexture(GL_TEXTURE0)

proc setup_vao() =
  var vao: GLuint
  glGenVertexArrays(1, addr vao)
  glBindVertexArray(vao)

# ──────────────────────────── App State ────────────────────────────

type EmuKind = enum ekNone, ekGBA, ekGB

type LinkSetup = enum
  lsNone        # no link setup in progress
  lsListening   # hosting: non-blocking accept polled each frame
  lsConnecting  # joining: non-blocking connect polled each frame

type AppState = ref object
  cfg:             Config
  gba_emu:         GBA
  gb_emu:          GB
  emu_kind:        EmuKind
  window:          WindowPtr
  gl_ctx:          GlContextPtr
  io:              ptr ImGuiIO
  game_texture:    GLuint
  # SGB border layer, 256x224 RGB5_A1. Allocated once; only uploaded (and only
  # sampled) while the loaded cart is running as a Super Game Boy and has
  # actually transferred a border.
  border_texture:  GLuint
  border_shown:    bool     # what the last present decided; drives window sizing
  border_gen:      uint32   # last border generation uploaded to the texture
  logo_texture:    GLuint
  canvas_aspect:   float32
  logo_shader:     GLuint
  game_shader:     GLuint
  fe:              FileExplorer
  ce:              ConfigEditor
  dbg:             GbaDebug
  gb_dbg:          GbDebug
  cheats:          CheatsWidget
  save_states:     SaveStatesWidget
  state_slot_texs: array[NUM_SLOTS, GLuint]  # thumbnails for the grid (0 = none)
  scale:           int
  running:         bool
  paused:          bool
  # Save states execute only at frame boundaries: the menu/hotkey sets a
  # pending flag and the main loop services it right after run_until_frame
  pending_save:    bool
  pending_load:    bool
  pending_step:    bool  # frame advance: run exactly one frame while paused
  # A refused save state used to be an echo to stdout and a screen that did not
  # change — the user pressed Load and nothing happened. This is what the app
  # says instead; render_state_notice draws it and it clears on dismissal.
  state_notice:      string
  state_notice_hint: string
  rewind:          Rewind
  rewinding:       bool    # true while the rewind key is held
  last_rewind_pop: uint32
  # Active 2-player network link (nil = single-player). While non-nil the
  # local GBA core is driven by netlink.step_frame instead of run_until_frame
  # so the socket stays pumped and the two sides stay in sync; rewind, frame
  # advance, turbo and save-state load are suppressed (they would desync).
  netlink:         NetLink
  # UI-driven link setup (ImGui "Link Cable" window). No CLI port needed:
  # the user picks Host or Join at runtime; establishment is non-blocking so
  # the UI keeps rendering while waiting for a peer.
  link_window:     bool
  link_window_prev: bool   # previous frame's link_window, to detect open/close
  link_setup:      LinkSetup
  # Zero-config auto-pairing: opening the Link Cable window immediately probes
  # 127.0.0.1 and, failing that, hosts — alternating until a peer appears. The
  # underlying socket phase is still tracked by link_setup; this flag just marks
  # that the connect/listen alternation is being driven automatically.
  link_auto:       bool
  link_server:     Socket
  link_client:     Socket
  link_port:       cint    # ImGui port input (defaults to LINK_DEFAULT_PORT)
  link_host_buf:   array[64, char]  # ImGui host-address input for joining
  link_status:     string  # last error / status line shown in the window
  link_attempts:   int     # join: connect retries spread across frames
  fullscreen:      bool
  enable_overlay:  bool
  last_mouse_tick: uint32

var app: AppState

# Emulated-frames FPS, updated once a second by update_fps_title and shown in
# the debug overlay alongside the ImGui (UI) framerate
var emu_fps = 0.0

# LCD response (common/lcd_response.nim): the per-pixel panel model that
# replaced interframe blending. Presentation-only — emulation state is
# untouched, so the setting is safe to change live. The cell state is dropped
# on ROM load, so a stale ghost can't smear across cores.
var lcd_resp: LcdResponse

# MBC5 rumble (GB cart types 0x1C-0x1E): update_rumble polls the cart's motor
# once per main-loop iteration into rumble_on, which render_game reads for
# the viewport shake; rumble_flip alternates the jitter direction per present.
var rumble_on         = false
var rumble_flip       = false
var rumble_last_pulse = 0'u32

# ──────────────────────────── ROM Loading ────────────────────────────

proc flush_gb_save() =
  # Battery saves are also flushed once per frame while running; this covers
  # switching ROMs and quitting mid-frame
  if app.gb_emu != nil:
    app.gb_emu.cartridge.mbc_save()

const ROM_EXTS = [".gba", ".gb", ".gbc"]

proc extract_zip_rom(zip_path: string): string =
  ## Extract the first GBA/GB/GBC ROM in a zip and return its path ("" if
  ## none / unreadable). The destination is a stable per-zip cache dir keyed
  ## by the zip's full path, so re-opening the same zip reuses the same
  ## extracted ROM — which keeps the emulator's .sav (written next to the
  ## ROM) persistent across sessions.
  try:
    let reader = openZipArchive(zip_path)
    defer: reader.close()
    var entry = ""
    for name in reader.walkFiles:
      if name.splitFile().ext.toLowerAscii() in ROM_EXTS:
        entry = name
        break
    if entry == "":
      echo "No ROM found in zip: ", zip_path
      return ""
    let dest_dir = config_dir() / "zip-cache" /
                   &"{zip_path.splitFile().name}-{cast[uint32](hash(zip_path)):08x}"
    createDir(dest_dir)
    let dest = dest_dir / entry.extractFilename()
    writeFile(dest, reader.extractFile(entry))
    dest
  except ZippyError, IOError, OSError:
    echo "Failed to read zip: ", getCurrentExceptionMsg()
    ""

proc apply_color_correction() =
  ## Push the config's color-correction flag into the game shader uniform
  glUseProgram(app.game_shader)
  let loc = glGetUniformLocation(app.game_shader, "color_correct")
  glUniform1i(loc, GLint(if app.cfg.color_correction: 1 else: 0))

proc sgb_border_active(): bool =
  ## Should this present composite a Super Game Boy border? Four conditions,
  ## and the last one is the one that keeps the window from resizing for a
  ## cart that colours its screen but ships no border art.
  app.emu_kind == ekGB and app.gb_emu != nil and
    app.cfg.sgb_enable and app.cfg.sgb_border and app.gb_emu.sgb_has_border()

proc output_size(): (int, int) =
  ## The picture's native size, which is what the window is sized from and
  ## what the aspect is preserved against. 256x224 only while a border is
  ## actually on screen.
  case app.emu_kind
  of ekGBA: (GBA_W, GBA_H)
  of ekGB:  (if sgb_border_active(): (SGB_BORDER_W, SGB_BORDER_H) else: (GB_W, GB_H))
  of ekNone: (GBA_W, GBA_H)

proc resize_to_output() =
  ## Size the window to an integer multiple of the native picture. Skipped in
  ## fullscreen, where the letterbox does the work instead.
  if app.fullscreen: return
  let (w, h) = output_size()
  setSize(app.window, cint(w * app.scale), cint(h * app.scale))

proc game_viewport(): (GLint, GLint, GLint, GLint) =
  ## The letterboxed rect the game quad is drawn into.
  ##
  ## dingbat used to stretch the quad across the whole window, which is
  ## invisible as long as the window keeps the size load_rom gave it and
  ## obviously wrong the moment it does not -- fullscreen on a 16:9 panel
  ## stretched a 10:9 Game Boy picture by 1.6x horizontally. It matters more
  ## now: an SGB border switches the picture from 10:9 to 8:7 part way into a
  ## session, so a window sized for one aspect has to letterbox the other.
  var ww, wh: cint
  getSize(app.window, ww, wh)
  let (ow, oh) = output_size()
  if not app.cfg.preserve_aspect or ow <= 0 or oh <= 0:
    return (0.GLint, 0.GLint, GLint(ww), GLint(wh))
  let scale = min(float(ww) / float(ow), float(wh) / float(oh))
  let vw = GLint(float(ow) * scale)
  let vh = GLint(float(oh) * scale)
  ((GLint(ww) - vw) div 2, (GLint(wh) - vh) div 2, vw, vh)

proc apply_panel_uniforms() =
  ## Select the panel's color-correction model and pixel-row height for the
  ## scanline effect. Depends only on the core kind, so this runs when a core
  ## is (re)loaded rather than per frame.
  glUseProgram(app.game_shader)
  let gbc = app.emu_kind == ekGB
  glUniform1i(glGetUniformLocation(app.game_shader, "panel_gbc"),
              GLint(if gbc: 1 else: 0))
  glUniform1f(glGetUniformLocation(app.game_shader, "tex_height"),
              if gbc: GLfloat(GB_H) else: GLfloat(GBA_H))
  glUniform1f(glGetUniformLocation(app.game_shader, "tex_width"),
              if gbc: GLfloat(GB_W) else: GLfloat(GBA_W))
  # Bind the two samplers to their texture units once. Without this the border
  # sampler defaults to unit 0 and samples the Game Boy texture as its own
  # border, which reads as "the border is a smeared copy of the game".
  glUniform1i(glGetUniformLocation(app.game_shader, "input_texture"), 0)
  glUniform1i(glGetUniformLocation(app.game_shader, "border_texture"), 1)

proc apply_master_volume() =
  if app.gba_emu != nil:
    app.gba_emu.apu.set_master_volume(app.cfg.volume, app.cfg.mute)
  if app.gb_emu != nil:
    app.gb_emu.apu.set_master_volume(app.cfg.volume, app.cfg.mute)

proc apply_pitch_correct_ff() =
  if app.gba_emu != nil:
    app.gba_emu.apu.set_pitch_correct_ff(app.cfg.pitch_correct_ff)
  if app.gb_emu != nil:
    app.gb_emu.apu.set_pitch_correct_ff(app.cfg.pitch_correct_ff)

proc apply_audio_lowpass() =
  # Analog-output low-pass models the GBA's cap/speaker smoothing; only the
  # GBA DirectSound path has the FIFO imaging it targets.
  if app.gba_emu != nil:
    app.gba_emu.apu.set_audio_lowpass(app.cfg.audio_lowpass)

proc apply_mp2k_hle() =
  # Experimental MP2K sound-engine HLE. Arming the flag costs nothing on its
  # own — the HLE only engages when the runtime detection recognizes the
  # engine in the loaded game (mp2k.nim), so this is safe to leave on.
  if app.gba_emu != nil:
    # Suspended (not overwritten) while speed mode is on
    app.gba_emu.mp2k_hle = app.cfg.mp2k_hle and not app.cfg.speed_mode

proc apply_fifo_interp() =
  # DirectSound FIFO interpolation (true-phase cubic reconstruction). Off is
  # the hardware-accurate mode — bit-true DAC output including its grit.
  if app.gba_emu != nil:
    # Suspended (not overwritten) while speed mode is on
    app.gba_emu.apu.set_fifo_interp(app.cfg.fifo_interp and
                                    not app.cfg.speed_mode)

proc apply_speed_mode() =
  # Speed mode (low-end devices): GBA renders every other frame and the
  # emulated CPU is charged double cycles. Live on the running GBA core; the
  # GB renderer choice (scanline while on) applies at the next ROM load.
  if app.gba_emu != nil:
    app.gba_emu.ppu.frameskip = if app.cfg.speed_mode: 1 else: 0
    app.gba_emu.set_underclock(if app.cfg.speed_mode: 1 else: 0)
  # The audio niceties read speed_mode through their own apply procs
  apply_mp2k_hle()
  apply_fifo_interp()

proc current_cheat_engine(): CheatEngine
proc load_cheats()
proc on_cheats_changed()

proc load_rom(path: string) =
  if not fileExists(path):
    echo "ROM not found: ", path; return
  # Zips: load the first ROM inside; recents keep the zip path itself
  var rom_path = path
  if path.splitFile().ext.toLowerAscii() == ".zip":
    rom_path = extract_zip_rom(path)
    if rom_path == "": return
  flush_gb_save()
  let ext = rom_path.splitFile().ext.toLowerAscii()
  if ext in [".gb", ".gbc"]:
    # Speed mode forces the cheaper scanline renderer; the FIFO preference
    # is remembered and returns when it is switched off.
    app.gb_emu = new_gb(app.cfg.gb_bootrom_path, rom_path,
                        app.cfg.gb_fifo and not app.cfg.speed_mode,
                        app.cfg.headless, app.cfg.run_bios)
    # Super Game Boy is opt-in from config but header-gated in the core: a
    # cart without the SGB flag, or one that is CGB-capable, gets nothing.
    app.gb_emu.sgb_requested = app.cfg.sgb_enable
    app.gb_emu.post_init()
    app.gba_emu = nil
    app.emu_kind = ekGB
    app.border_shown = false
    app.border_gen = 0
    setSize(app.window, cint(GB_W * app.scale), cint(GB_H * app.scale))
    app.dbg = nil
    app.gb_dbg = new_gb_debug(app.gb_emu)
  else:
    let bios = app.cfg.bios_path
    app.gba_emu = new_gba(bios, rom_path, app.cfg.run_bios, app.cfg.use_hle, app.cfg.hle_after_bios)
    app.gba_emu.post_init()
    app.gb_emu = nil
    app.emu_kind = ekGBA
    app.border_shown = false
    setSize(app.window, cint(GBA_W * app.scale), cint(GBA_H * app.scale))
    app.dbg = new_gba_debug(app.gba_emu)
    app.gb_dbg = nil
  # Cheats: attach the widget to this core's engine and load the sidecar.
  app.cheats.attach(current_cheat_engine(),
                    if app.emu_kind == ekGBA: cpGBA else: cpGB)
  app.cheats.on_change = on_cheats_changed
  load_cheats()
  apply_master_volume()
  apply_pitch_correct_ff()
  apply_audio_lowpass()
  apply_fifo_interp()
  apply_mp2k_hle()
  apply_speed_mode()
  apply_panel_uniforms()
  lcd_resp.reset()  # fresh core: don't ghost the previous game's frame
  app.rewind.clear()
  app.rewinding = false
  glDisable(GL_BLEND)
  glUseProgram(app.game_shader)
  glBindTexture(GL_TEXTURE_2D, app.game_texture)
  # Allocate the texture storage once here; per-frame uploads use
  # glTexSubImage2D, which avoids a driver-side reallocation every frame
  # (glTexImage2D each frame cost ~0.4 ms on macOS's GL-on-Metal stack)
  let (tw, th) = if app.emu_kind == ekGBA: (GBA_W, GBA_H) else: (GB_W, GB_H)
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGB5), GLsizei(tw), GLsizei(th), 0,
               GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV, nil)
  # Update recents
  var recs = app.cfg.recents
  let idx = recs.find(path)
  if idx >= 0: recs.delete(idx)
  recs.insert(path, 0)
  while recs.len > 8: recs.setLen(8)
  app.cfg.recents = recs
  save_config(app.cfg)
  setPosition(app.window, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED)
  app.paused = false
  app.pending_save = false
  app.pending_load = false

# ──────────────────────────── Save States ────────────────────────────

proc current_rom_path(): string =
  case app.emu_kind
  of ekGBA: (if app.gba_emu != nil: app.gba_emu.rom_path else: "")
  of ekGB:  (if app.gb_emu != nil: app.gb_emu.rom_path else: "")
  of ekNone: ""

# ──────────────────────────── Cheats ────────────────────────────

proc cheat_file_path(): string =
  ## Sidecar cheat list, next to the ROM (mirrors the .sav convention).
  let rp = current_rom_path()
  if rp.len == 0: return ""
  rp[0 ..< rp.rfind('.')] & ".cht"

proc current_cheat_engine(): CheatEngine =
  case app.emu_kind
  of ekGBA: (if app.gba_emu != nil: app.gba_emu.cheats else: nil)
  of ekGB:  (if app.gb_emu != nil: app.gb_emu.cheats else: nil)
  of ekNone: nil

proc refresh_cheat_rom_patches() =
  case app.emu_kind
  of ekGBA: (if app.gba_emu != nil: app.gba_emu.refresh_cheat_rom_patches())
  of ekGB:  (if app.gb_emu != nil: app.gb_emu.refresh_cheat_rom_patches())
  of ekNone: discard

proc save_cheats() =
  let eng = current_cheat_engine()
  let path = cheat_file_path()
  if eng == nil or path.len == 0: return
  try:
    if eng.cheats.len == 0:
      if fileExists(path): removeFile(path)
    else:
      writeFile(path, eng.serialize())
  except CatchableError as e:
    echo "cheats: could not save ", path, ": ", e.msg

proc load_cheats() =
  ## Read the sidecar (if any) into the live engine and apply ROM patches.
  let eng = current_cheat_engine()
  let path = cheat_file_path()
  if eng == nil or path.len == 0 or not fileExists(path): return
  try:
    eng.deserialize(readFile(path))
    refresh_cheat_rom_patches()
  except CatchableError as e:
    echo "cheats: could not load ", path, ": ", e.msg

proc on_cheats_changed() =
  ## Called by the widget after any edit: re-apply ROM patches, then persist.
  refresh_cheat_rom_patches()
  save_cheats()

proc state_file_path(slot = 0): string =
  ## Per-ROM state files. Slot 0 is the "Quick" slot and keeps the historical
  ## `<rom>.state` name so existing saves stay loadable; slots 1..8 add a
  ## `.slotN` suffix.
  let rom = current_rom_path()
  if rom.len == 0: return ""
  let base = config_dir() / "states" / rom.extractFilename()
  if slot == 0: base & ".state"
  else: base & ".slot" & $slot & ".state"

proc save_state_slot(slot: int): bool =
  ## Synchronous save of a numbered slot (with a thumbnail). Callers must be at
  ## a frame boundary — true during process_pending_state and render_imgui.
  let path = state_file_path(slot)
  if path.len == 0: return false
  result = case app.emu_kind
    of ekGBA: app.gba_emu.save_state(path, thumbnail = true)
    of ekGB:  app.gb_emu.save_state(path, thumbnail = true)
    of ekNone: false
  if result: echo "State saved: ", path

proc load_state_slot(slot: int): bool =
  let path = state_file_path(slot)
  if path.len == 0: return false
  result = case app.emu_kind
    of ekGBA: app.gba_emu.load_state(path)
    of ekGB:  app.gb_emu.load_state(path)
    of ekNone: false
  if result: echo "State loaded: ", path

proc state_reject_sentence(): string =
  ## One sentence per refusal cause, saying what to do about it. The core
  ## classifies the refusal (StateRejectKind); this never echoes raw exception
  ## text at the user, and never collapses two causes onto one message.
  case last_state_reject_kind
  of srkNotAState:
    "That file isn't a dingbat save state."
  of srkWrongCore:
    "That save state is for the other system - a Game Boy state can't load " &
    "into a GBA game, or the reverse."
  of srkWrongRom:
    "That save state belongs to a different game. Load the game it was made " &
    "in, then try again."
  of srkTooNew:
    "That save state was made by a newer version of dingbat than this one. " &
    "Update dingbat and try again."
  of srkTruncated:
    "That save state file is incomplete - the copy or download was cut short."
  of srkCorrupt:
    "That save state is damaged and can't be loaded. The game is still " &
    "running and nothing was changed."
  of srkNoFile:
    # The common one, now that Quick Load reports at all: pressing the key
    # before ever saving used to do nothing, and telling that person their
    # file is damaged would be worse than saying nothing.
    "There's no save state in that slot yet."
  of srkNone:
    "That save state couldn't be loaded."

proc delete_state_slot(slot: int) =
  let path = state_file_path(slot)
  if path.len > 0 and fileExists(path):
    try:
      removeFile(path)
      echo "State deleted: ", path
    except CatchableError:
      echo "Delete state failed: ", getCurrentExceptionMsg()

proc refresh_state_slots() =
  ## Scan the nine slot files, decode each embedded thumbnail into a GL texture,
  ## and hand the metadata to the Save States widget. Called when the window
  ## opens and right after a save — never on the hot path.
  let w = app.save_states
  w.have_rom = app.emu_kind != ekNone
  for i in 0 ..< NUM_SLOTS:
    let path = state_file_path(i)
    if path.len == 0 or not fileExists(path):
      w.set_slot(i, used = false, label = "", tex = 0, tw = 0, th = 0)
      continue
    var label = ""
    try:
      label = getFileInfo(path).lastWriteTime.local.format("MM-dd  HH:mm")
    except CatchableError: discard
    var data = ""
    try: data = readFile(path)
    except CatchableError: discard
    let (tw, th, pixels) = parse_state_thumbnail(data)
    if pixels.len > 0:
      if app.state_slot_texs[i] == 0:
        glGenTextures(1, addr app.state_slot_texs[i])
      glBindTexture(GL_TEXTURE_2D, app.state_slot_texs[i])
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
      glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGB5), GLsizei(tw), GLsizei(th), 0,
                   GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV, addr pixels[0])
      w.set_slot(i, used = true, label = label,
                 tex = uint64(app.state_slot_texs[i]),
                 tw = float32(tw), th = float32(th))
    else:
      # File exists but carries no thumbnail (older save / quick-save on a
      # pre-thumbnail build): still selectable, just no preview.
      w.set_slot(i, used = true, label = label, tex = 0, tw = 0, th = 0)

proc process_pending_state() =
  ## Runs between frames only (right after run_until_frame returns, or while
  ## paused), so the core is always at a frame boundary here. Quick Save/Load
  ## act on slot 0.
  if app.pending_save:
    app.pending_save = false
    discard save_state_slot(0)
    # An open Save States window is showing slot 1 stale now — refresh it
    app.save_states.mark_stale()
  if app.pending_load:
    app.pending_load = false
    # Quick Load is a keypress with no widget behind it, so a discarded bool
    # here meant the user pressed the key and NOTHING happened — not even a
    # line they would see. It is the one outcome a refusal must never produce.
    if not load_state_slot(0):
      app.state_notice = state_reject_sentence()
      app.state_notice_hint = last_state_error

# ──────────────────────────── Screenshots ────────────────────────────

proc bgr555_to_rgb(px: uint16; correct, gbc: bool): array[3, byte] =
  ## Expand one BGR555 framebuffer pixel to 8-bit RGB. When `correct` is set
  ## this mirrors the display shader's LCD color correction — the AGB model
  ## (linearize with gamma 4.0, mix channels, re-gamma with 2.2) or, with
  ## `gbc`, the CGB model — so the PNG matches on-screen.
  let r5 = float64(px and 0x1F) / 31.0
  let g5 = float64((px shr 5) and 0x1F) / 31.0
  let b5 = float64((px shr 10) and 0x1F) / 31.0
  if correct and gbc:
    const lum = 0.94
    let r = pow(r5, 2.2) * lum
    let g = pow(g5, 2.2) * lum
    let b = pow(b5, 2.2) * lum
    let mixed = [0.82 * r + 0.125 * g + 0.195 * b,
                 0.24 * r + 0.665 * g + 0.075 * b,
                -0.06 * r + 0.210 * g + 0.730 * b]
    for i in 0 .. 2:
      result[i] = byte(min(255.0, round(pow(max(0.0, min(1.0, mixed[i])), 1.0 / 2.2) * 255.0)))
  elif correct:
    let r = pow(r5, 4.0)
    let g = pow(g5, 4.0)
    let b = pow(b5, 4.0)
    let mixed = [(  0.0 * b +  50.0 * g + 255.0 * r) / 255.0,
                 ( 30.0 * b + 230.0 * g +  10.0 * r) / 255.0,
                 (220.0 * b +  10.0 * g +  50.0 * r) / 255.0]
    for i in 0 .. 2:
      result[i] = byte(min(255.0, round(pow(mixed[i], 1.0 / 2.2) * 255.0)))
  else:
    result[0] = byte(round(r5 * 255.0))
    result[1] = byte(round(g5 * 255.0))
    result[2] = byte(round(b5 * 255.0))

proc save_screenshot() =
  ## Write the current frame to config_dir/screenshots/<rom>-<timestamp>.png.
  ## Applies LCD color correction to match the on-screen image when the
  ## setting is enabled — parity with the web front-end's screenshot button.
  if app.emu_kind == ekNone: return
  let border = sgb_border_active()
  let (w, h) = output_size()
  let correct = app.cfg.color_correction
  let gbc = app.emu_kind == ekGB
  var rgb = newSeq[byte](w * h * 3)
  template put(i: int; v: uint16; corr: bool) =
    let c = bgr555_to_rgb(v, corr, gbc)
    rgb[i * 3 + 0] = c[0]
    rgb[i * 3 + 1] = c[1]
    rgb[i * 3 + 2] = c[2]
  template convert(fb: untyped) =
    for i in 0 ..< w * h: put(i, fb[i], correct)
  if border:
    # Same composite the shader does: backdrop, Game Boy window at (48, 40),
    # then opaque border pixels on top. The border is native SNES art, so it
    # does NOT get the LCD colour-correction curve — matching what is on
    # screen is the whole point of this path.
    let s = app.gb_emu
    let bp = cast[ptr UncheckedArray[uint16]](s.sgb_border_ptr())
    let backdrop = s.sgb_backdrop()
    for i in 0 ..< w * h: put(i, backdrop, false)
    for y in 0 ..< GB_H:
      for x in 0 ..< GB_W:
        put((y + 40) * w + (x + 48), s.ppu.framebuffer[y * GB_W + x], correct)
    for i in 0 ..< w * h:
      if (bp[i] and 0x8000'u16) != 0: put(i, bp[i] and 0x7FFF'u16, false)
  else:
    case app.emu_kind
    of ekGBA: convert(app.gba_emu.ppu.framebuffer)
    of ekGB:  convert(app.gb_emu.ppu.framebuffer)
    of ekNone: return
  let dir = config_dir() / "screenshots"
  try:
    createDir(dir)
  except OSError as e:
    echo "Screenshot failed (mkdir): ", e.msg; return
  let rom  = current_rom_path().extractFilename()
  let base = if rom.len > 0: rom.changeFileExt("") else: "screenshot"
  let path = dir / (base & "-" & now().format("yyyyMMdd-HHmmss") & ".png")
  if stbiw.writePNG(path, w, h, 3, rgb):
    echo "Screenshot saved: ", path
  else:
    echo "Screenshot failed: ", path

# ──────────────────────────── Rendering ────────────────────────────

proc render_logo() =
  # Bind explicitly: other code (uniform updates, debug texture uploads) may
  # have switched the active program/texture between frames
  glUseProgram(app.logo_shader)
  glBindTexture(GL_TEXTURE_2D, app.logo_texture)
  var w, h: cint
  getSize(app.window, w, h)
  let window_aspect = float32(w) / float32(h)
  let aspect_loc = glGetUniformLocation(app.logo_shader, "aspect")
  let scale_loc  = glGetUniformLocation(app.logo_shader, "scale")
  glUniform1f(aspect_loc, window_aspect * app.canvas_aspect)
  glUniform1f(scale_loc, 0.5'f32)
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)

proc upload_frame(fb: ptr uint16; w, h: int) =
  ## Upload the frame texture, running it through the panel model first when
  ## the LCD response is on. The model advances once per uploaded frame — i.e.
  ## in emulated time, not in display refreshes — so the screen settles the
  ## same way whatever the window's refresh rate is.
  let src = cast[ptr UncheckedArray[uint16]](fb)
  let gb = app.emu_kind == ekGB and app.gb_emu != nil
  lcd_resp.set_panel(app.cfg.lcd_response.resolve(
    gba = app.emu_kind == ekGBA,
    cgb = gb and app.gb_emu.cgb_enabled,
    sgb = gb and app.gb_emu.sgb_active()))
  let upload = cast[pointer](lcd_resp.apply(src, w * h))
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, GLsizei(w), GLsizei(h),
                  GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV, upload)

when defined(gputime):
  # Throwaway instrument (-d:gputime): GL_TIME_ELAPSED around the game quad,
  # so the cost of an upscale filter can be measured at a real window size
  # instead of extrapolated from the web build's fixed 960x640 backing store.
  # Prints a line a second: viewport, median/p90 GPU ms for the game draw.
  var gpuq: array[8, GLuint]
  var gpuq_init = false
  var gpuq_slot = 0
  var gpu_samples: seq[float]
  var gpu_last_report = getTime()
  var gpu_sweep_step = 0

  proc gpu_begin() =
    if not gpuq_init:
      glGenQueries(GLsizei(gpuq.len), addr gpuq[0])
      gpuq_init = true
    else:
      # harvest the slot we are about to reuse (8 frames of latency)
      var avail: GLint
      glGetQueryObjectiv(gpuq[gpuq_slot], GL_QUERY_RESULT_AVAILABLE, addr avail)
      if avail != 0:
        var ns: GLuint64
        glGetQueryObjectui64v(gpuq[gpuq_slot], GL_QUERY_RESULT, addr ns)
        gpu_samples.add(float(ns) / 1e6)
    glBeginQuery(GL_TIME_ELAPSED, gpuq[gpuq_slot])

  proc gpu_end() =
    glEndQuery(GL_TIME_ELAPSED)
    gpuq_slot = (gpuq_slot + 1) mod gpuq.len
    let now = getTime()
    if (now - gpu_last_report).inMilliseconds >= 2000 and gpu_samples.len > 8:
      gpu_last_report = now
      var v = gpu_samples
      v.sort()
      var w, h: cint
      getSize(app.window, w, h)
      echo "GPUTIME viewport=", w, "x", h,
           " filter=", $app.cfg.video_filter,
           " scanlines=", app.cfg.scanlines,
           " colorcorrect=", app.cfg.color_correction,
           " lcdresponse=", $app.cfg.lcd_response,
           " n=", v.len,
           " median_ms=", formatFloat(v[v.len div 2], ffDecimal, 4),
           " p90_ms=", formatFloat(v[(v.len * 9) div 10], ffDecimal, 4),
           " emu_fps=", formatFloat(emu_fps, ffDecimal, 1)
      gpu_samples.setLen(0)
      # DINGBAT_GPUTIME_SWEEP=1 walks the present-path settings itself, one
      # per report, so a whole matrix comes out of a single launch instead of
      # a dozen windows.
      if getEnv("DINGBAT_GPUTIME_SWEEP") == "1":
        gpu_sweep_step.inc
        case gpu_sweep_step
        of 1: app.cfg.video_filter = vfNone;  app.cfg.scanlines = false
        of 2: app.cfg.video_filter = vfHq4x
        of 3: app.cfg.video_filter = vfXbr
        of 4: app.cfg.video_filter = vfNone;  app.cfg.scanlines = true
        of 5: app.cfg.scanlines = false;      app.cfg.color_correction = false
        of 6: app.cfg.color_correction = true; app.cfg.lcd_response = true
        of 7: app.cfg.lcd_response = false
        else: echo "GPUTIME sweep done"; app.running = false

proc render_game() =
  if app.emu_kind != ekNone:
    glUseProgram(app.game_shader)
    glBindTexture(GL_TEXTURE_2D, app.game_texture)
    # Pushed every present (like the logo uniforms): the Settings window's
    # Apply has no callback into this module, so a cached value could go stale.
    # An active upscale filter suspends scanlines (smoothing + row-darkening
    # fight each other) — same behavior as the web frontend.
    let scan = app.cfg.scanlines and app.cfg.video_filter == vfNone
    glUniform1i(glGetUniformLocation(app.game_shader, "scanlines"),
                GLint(if scan: 1 else: 0))
    glUniform1i(glGetUniformLocation(app.game_shader, "filter_mode"),
                GLint(ord(app.cfg.video_filter)))
  # The letterboxed rect this present draws into. Computed before the case so
  # both cores share it, and restored to the full window afterwards so ImGui
  # is not clipped by it.
  var win_w, win_h: cint
  getSize(app.window, win_w, win_h)
  let (vx, vy, vw, vh) = game_viewport()
  if app.emu_kind != ekNone:
    glViewport(vx, vy, GLsizei(vw), GLsizei(vh))
  case app.emu_kind
  of ekGBA:
    if app.gba_emu == nil:
      glViewport(0, 0, GLsizei(win_w), GLsizei(win_h)); return
    glUniform1i(glGetUniformLocation(app.game_shader, "sgb_border"), 0)
    glUniform1f(glGetUniformLocation(app.game_shader, "scan_height"),
                GLfloat(GBA_H))
    # The panel model must be fed static frames too, or a cell still on its
    # way to its target would freeze part-settled instead of finishing
    if app.cfg.lcd_response or not app.gba_emu.ppu.frame_static:
      upload_frame(addr app.gba_emu.ppu.framebuffer[0], GBA_W, GBA_H)
    when defined(gputime): gpu_begin()
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
    when defined(gputime): gpu_end()
  of ekGB:
    if app.gb_emu == nil:
      glViewport(0, 0, GLsizei(win_w), GLsizei(win_h)); return
    let border = sgb_border_active()
    glUniform1i(glGetUniformLocation(app.game_shader, "sgb_border"),
                GLint(if border: 1 else: 0))
    # The scanline pitch follows the OUTPUT, not the Game Boy texture: with a
    # border the picture is 224 native rows and both layers live in it.
    glUniform1f(glGetUniformLocation(app.game_shader, "scan_height"),
                if border: GLfloat(SGB_BORDER_H) else: GLfloat(GB_H))
    if border:
      let bd = app.gb_emu.sgb_backdrop()
      glUniform3f(glGetUniformLocation(app.game_shader, "sgb_backdrop"),
                  GLfloat(float(bd and 0x1F) / 31.0),
                  GLfloat(float((bd shr 5) and 0x1F) / 31.0),
                  GLfloat(float((bd shr 10) and 0x1F) / 31.0))
      let gen = app.gb_emu.sgb_border_gen()
      if gen != app.border_gen:
        app.border_gen = gen
        glActiveTexture(GL_TEXTURE1)
        glBindTexture(GL_TEXTURE_2D, app.border_texture)
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0,
                        GLsizei(SGB_BORDER_W), GLsizei(SGB_BORDER_H),
                        GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV,
                        app.gb_emu.sgb_border_ptr())
        glActiveTexture(GL_TEXTURE0)
        glBindTexture(GL_TEXTURE_2D, app.game_texture)
      else:
        glActiveTexture(GL_TEXTURE1)
        glBindTexture(GL_TEXTURE_2D, app.border_texture)
        glActiveTexture(GL_TEXTURE0)
    # A border appearing (or a state load taking one away) changes the
    # picture's size and aspect, so the window follows it -- once, on the
    # edge, the same way a console changes video mode.
    if border != app.border_shown:
      app.border_shown = border
      resize_to_output()
      getSize(app.window, win_w, win_h)
      let (nx, ny, nw, nh) = game_viewport()
      glViewport(nx, ny, GLsizei(nw), GLsizei(nh))
    upload_frame(addr app.gb_emu.ppu.framebuffer[0], GB_W, GB_H)
    if rumble_on:
      # ±1 px viewport jitter, alternating per present, while the cart's
      # rumble motor runs. Only the viewport origin moves (the quad and
      # texture are untouched), and it's restored right after the draw so
      # ImGui renders unshaken.
      rumble_flip = not rumble_flip
      let off: GLint = if rumble_flip: 1 else: -1
      let (jx, jy, jw, jh) = game_viewport()
      glViewport(jx + off, jy - off, GLsizei(jw), GLsizei(jh))
      glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
    else:
      glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
  of ekNone:
    render_logo()
  glViewport(0, 0, GLsizei(win_w), GLsizei(win_h))

proc show_menu_bar(): bool =
  if app.emu_kind == ekNone: return true
  let focused    = getMouseFocus() == app.window
  let mouse_idle = getTicks() - app.last_mouse_tick > 3000'u32
  result = focused and not mouse_idle
  discard showCursor(result)

proc render_link_window()  # defined below, near the network-link procs

proc render_state_notice() =
  ## What the app says when a save state is refused. Before this, a refused
  ## Quick Load was an echo to stdout and a screen that did not change: the
  ## user pressed the key and nothing happened, which is the worst outcome
  ## available. Modal on purpose — it is always the direct result of something
  ## the user just did, so it never appears unbidden.
  if app.state_notice.len == 0: return
  const POPUP = "State##notice"
  if not igIsPopupOpen_Str(POPUP, 0):
    igOpenPopup_Str(POPUP, 0)
  var center = ImVec2(x: 0, y: 0)
  let vp = igGetMainViewport()
  if vp != nil:
    when compiles(ImGuiViewport_GetCenter(addr center, vp)):
      ImGuiViewport_GetCenter(addr center, vp)
    else:
      let c = ImGuiViewport_GetCenter(vp)
      center = ImVec2(x: c.x, y: c.y)
  igSetNextWindowPos(center, cint(ImGui_Cond_Appearing), ImVec2(x: 0.5, y: 0.5))
  igSetNextWindowSizeConstraints(ImVec2(x: 380, y: 0), ImVec2(x: 560, y: 400),
                                 nil, nil)
  var stay_open = true
  if igBeginPopupModal(POPUP, addr stay_open,
                       cint(ImGui_WindowFlags_AlwaysAutoResize)):
    igPushTextWrapPos(0)
    igTextUnformatted(cstring(app.state_notice), nil)
    if app.state_notice_hint.len > 0:
      igSpacing()
      # The detail line is for someone reporting a bug, not for reading first:
      # dimmed, below, and never the whole message. Through "%s" and not as the
      # format string itself: this is the one igTextDisabled call in the tree
      # whose text is not a literal — it carries core wording built from the
      # FILE's own bytes, and a '%' in there would read arguments that were
      # never pushed.
      igTextDisabled("%s", cstring(app.state_notice_hint))
    igPopTextWrapPos()
    igSpacing()
    if igButton("OK", ImVec2(x: 120, y: 0)):
      app.state_notice = ""
      app.state_notice_hint = ""
      igCloseCurrentPopup()
    igEndPopup()
  if not stay_open:
    app.state_notice = ""
    app.state_notice_hint = ""

proc render_imgui() =
  # Skip the whole ImGui pass when no UI is visible (menu bar hidden, no
  # dialogs/overlay/debug windows): at uncapped emulation speeds the empty
  # NewFrame/Render pair costs real throughput. The home screen (no ROM
  # loaded) always renders ImGui — it shows the drag-and-drop hint and has
  # no emulation to slow down.
  let menu_visible = show_menu_bar()
  if app.emu_kind != ekNone and not app.paused and not app.rewinding and
     not menu_visible and not app.enable_overlay and
     not app.fe.open and not app.ce.open and
     (app.dbg == nil or
      not (app.dbg.video_window or app.dbg.sched_window or app.dbg.exp_window)) and
     (app.gb_dbg == nil or not app.gb_dbg.any_window_open) and
     not app.link_window and not app.cheats.window and
     not app.save_states.window and
     # A refused Quick Load is a keypress, and the menu bar hides itself after
     # three idle seconds — exactly the state the keyboard is used in. Without
     # this the notice would be skipped and the refusal would be silent again,
     # which is the whole bug it exists to fix.
     app.state_notice.len == 0:
    return

  ImGui_Impl_OpenGL3_NewFrame()
  ImGui_ImplSDL2_NewFrame()
  igNewFrame()

  var overlay_h: cfloat = 10.0
  var open_rom = false

  if menu_visible:
    if igBeginMainMenuBar():
      # File menu
      if igBeginMenu("File", true):
        if igMenuItem_Bool("Open ROM", nil, false, true):
          open_rom = true
        if igBeginMenu("Recent", app.cfg.recents.len > 0):
          for recent in app.cfg.recents:
            if igMenuItem_Bool(cstring(recent), nil, false, true):
              load_rom(recent)
          igSeparator()
          if igMenuItem_Bool("Clear", nil, false, true):
            app.cfg.recents.setLen(0)
            save_config(app.cfg)
          igEndMenu()
        igSeparator()
        let game_loaded = app.emu_kind != ekNone
        if igMenuItem_Bool(cstring("Quick Save  " & MOD_KEY_STR & "+S"),
                           nil, false, game_loaded):
          app.pending_save = true
        if igMenuItem_Bool(cstring("Quick Load  " & MOD_KEY_STR & "+L"),
                           nil, false, game_loaded):
          app.pending_load = true
        if igMenuItem_Bool("Save States...", nil, false, game_loaded):
          app.save_states.window = true
        if igMenuItem_Bool("Screenshot  F12", nil, false, game_loaded):
          save_screenshot()
        igSeparator()
        if igMenuItem_Bool("Settings", nil, false, true):
          app.ce.open = true
        igSeparator()
        if igMenuItem_Bool(cstring("Exit  " & MOD_KEY_STR & "+Q"), nil, false, true):
          app.running = false
        igEndMenu()

      # Emulation menu
      if igBeginMenu("Emulation", true):
        var should_reset = false
        discard igMenuItem_BoolPtr(cstring("Reset  " & MOD_KEY_STR & "+R"),
                                   nil, addr should_reset, true)
        discard igMenuItem_BoolPtr(cstring("Pause  " & MOD_KEY_STR & "+P"),
                                   nil, addr app.paused, true)
        if igMenuItem_Bool(cstring("Frame Advance  " & MOD_KEY_STR & "+N"),
                           nil, false, app.paused and app.emu_kind != ekNone):
          app.pending_step = true
        if igMenuItem_BoolPtr("Rewind (hold `)", nil, addr app.cfg.rewind, true):
          if not app.cfg.rewind:
            app.rewind.clear()  # free the history when disabled
          save_config(app.cfg)
        # Speed mode: the low-end preset — GBA frameskip + 2x emulated-CPU
        # underclock, GB scanline renderer at next load, rewind suspended.
        # Advertised as less accurate on purpose.
        if igMenuItem_BoolPtr("Speed mode (less accurate)", nil,
                              addr app.cfg.speed_mode, true):
          if app.cfg.speed_mode:
            app.rewind.clear()  # suspended while on; history would go stale
          apply_speed_mode()
          save_config(app.cfg)
        # 2x Speed stays audio-paced (at double rate); Fast Forward is
        # inverted audio sync — unsynced emulation runs uncapped, so
        # checked == not sync. Radio-style: fast forward would silently
        # dominate 2x, so enabling either clears the other.
        if app.emu_kind == ekGBA and app.gba_emu != nil:
          if igMenuItem_BoolPtr("2x Speed", "Shift+Tab",
                                addr app.gba_emu.apu.turbo, true):
            if app.gba_emu.apu.turbo: app.gba_emu.apu.sync = true
          var fast_forward = not app.gba_emu.apu.sync
          if igMenuItem_BoolPtr("Fast Forward", "Tab",
                                addr fast_forward, true):
            app.gba_emu.apu.sync = not fast_forward
            if fast_forward: app.gba_emu.apu.turbo = false
        elif app.emu_kind == ekGB and app.gb_emu != nil:
          if igMenuItem_BoolPtr("2x Speed", "Shift+Tab",
                                addr app.gb_emu.apu.turbo, true):
            if app.gb_emu.apu.turbo: app.gb_emu.apu.sync = true
          var fast_forward = not app.gb_emu.apu.sync
          if igMenuItem_BoolPtr("Fast Forward", "Tab",
                                addr fast_forward, true):
            app.gb_emu.apu.sync = not fast_forward
            if fast_forward: app.gb_emu.apu.turbo = false
        if should_reset and app.cfg.recents.len > 0:
          load_rom(app.cfg.recents[0])
        igSeparator()
        # Cheats live here, not under Debug: they're a first-class feature (the
        # web UI agrees) and users look for them next to the other things that
        # change a running game.
        discard igMenuItem_BoolPtr("Cheats", nil, addr app.cheats.window,
                                   app.emu_kind != ekNone)
        # Network link: opens the Host/Join window (GBA only). No CLI port
        # needed — the user picks a role and address at runtime.
        if igMenuItem_Bool("Link Cable...", nil, app.link_window,
                           app.emu_kind == ekGBA):
          app.link_window = not app.link_window
        igEndMenu()

      # Audio/Video menu
      if igBeginMenu("Audio/Video", true):
        var vol = cint(app.cfg.volume)
        igSetNextItemWidth(120.0)
        if igSliderInt("Volume", addr vol, 0, 100, "%d%%", 0):
          app.cfg.volume = int(vol)
          apply_master_volume()
        # Persist only when the slider edit completes, not every frame
        if igIsItemDeactivatedAfterEdit():
          save_config(app.cfg)
        if igMenuItem_BoolPtr("Mute", nil, addr app.cfg.mute, true):
          apply_master_volume()
          save_config(app.cfg)
        # WSOLA time-stretch keeps 2x audio at normal pitch (instead of the
        # classic octave-up). Off by default; slightly more CPU at 2x.
        if igMenuItem_BoolPtr("Pitch-correct fast-forward", nil,
                              addr app.cfg.pitch_correct_ff, true):
          apply_pitch_correct_ff()
          save_config(app.cfg)
        # DirectSound FIFO interpolation. ON (default): reconstructs the
        # waveform between hardware samples (cleaner treble). OFF: bit-true
        # GBA DAC output, including its characteristic grit. GBA only.
        if igMenuItem_BoolPtr("Audio interpolation", nil,
                              addr app.cfg.fifo_interp, app.emu_kind == ekGBA):
          apply_fifo_interp()
          save_config(app.cfg)
        # Gentle analog-output low-pass modeling the GBA's output filter.
        # Pair with interpolation off for the closest real-hardware sound.
        # Off by default → output bit-identical to unfiltered. GBA only.
        if igMenuItem_BoolPtr("Analog filter", nil,
                              addr app.cfg.audio_lowpass, app.emu_kind == ekGBA):
          apply_audio_lowpass()
          save_config(app.cfg)
        # Sound-engine HLE: re-renders supported games' music engines at
        # higher quality; changes the mix character, and supersedes
        # interpolation for the music stream when engaged. Auto-engages
        # per-game on detection, other games unaffected. Off by default.
        if igMenuItem_BoolPtr("Enhanced music synthesis (HLE)", nil,
                              addr app.cfg.mp2k_hle, true):
          apply_mp2k_hle()
          save_config(app.cfg)
        igSeparator()
        if igMenuItem_BoolPtr("LCD Color Correction", nil,
                              addr app.cfg.color_correction, true):
          apply_color_correction()
          save_config(app.cfg)
        let have_gba_ch = app.emu_kind == ekGBA and app.gba_emu != nil
        let have_gb_ch  = app.emu_kind == ekGB and app.gb_emu != nil
        if igBeginMenu("Channels", have_gba_ch or have_gb_ch):
          if have_gba_ch:
            const ch_names = ["PSG1", "PSG2", "PSG3", "PSG4", "DMA-A", "DMA-B"]
            for ch in 0 .. 5:
              discard igMenuItem_BoolPtr(cstring(ch_names[ch]), cstring($(ch + 1)),
                                         addr app.gba_emu.apu.channel_mask[ch], true)
          elif have_gb_ch:
            const ch_names = ["Pulse 1", "Pulse 2", "Wave", "Noise"]
            for ch in 0 .. 3:
              discard igMenuItem_BoolPtr(cstring(ch_names[ch]), cstring($(ch + 1)),
                                         addr app.gb_emu.apu.channel_mask[ch], true)
          igEndMenu()
        igSeparator()
        if igBeginMenu("Frame size", true):
          for s in 1 .. 8:
            if igMenuItem_Bool(cstring($s & "x"), nil, s == app.scale, true):
              app.scale = s
              if app.emu_kind != ekNone: resize_to_output()
          igSeparator()
          if igMenuItem_BoolPtr(cstring("Fullscreen  " & MOD_KEY_STR & "+F"),
                                nil, addr app.fullscreen, true):
            let flags = if app.fullscreen: SDL_WINDOW_FULLSCREEN_DESKTOP else: 0'u32
            discard setFullscreen(app.window, flags)
          igEndMenu()
        igEndMenu()

      # Debug menu
      if igBeginMenu("Debug", true):
        discard igMenuItem_BoolPtr("Overlay", nil, addr app.enable_overlay, true)
        igSeparator()
        if app.dbg != nil:
          app.dbg.render_menu_items()
        if app.gb_dbg != nil:
          app.gb_dbg.render_menu_items()
        igEndMenu()

      var win_size = ImVec2(x: 0, y: 0)
      # imguin <= 1.92.4 uses a pOut out-param; later versions return by value
      when compiles(igGetWindowSize(addr win_size)):
        igGetWindowSize(addr win_size)
      else:
        let ws = igGetWindowSize()
        win_size = ImVec2(x: ws.x, y: ws.y)
      overlay_h += win_size.y
      igEndMainMenuBar()

  # File explorer
  app.fe.render("ROM", open_rom, ["gba", "gb", "gbc", "zip"], proc(path: string) =
    load_rom(path))

  render_state_notice()

  # Config editor
  app.ce.render()

  # Overlay
  if app.enable_overlay:
    igSetNextWindowPos(ImVec2(x: 10, y: overlay_h), cint(ImGui_Cond_Always),
                       ImVec2(x: 0, y: 0))
    igSetNextWindowBgAlpha(0.5'f32)
    let ov_flags = cint(ImGui_WindowFlags_NoDecoration) or
                   cint(ImGui_WindowFlags_NoMove) or
                   cint(ImGui_WindowFlags_NoSavedSettings)
    if igBegin("##overlay", addr app.enable_overlay, ov_flags):
      let fps = app.io[].Framerate
      igText("UI FPS:     %.1f", fps)
      igText("Frame time: %.3f ms", 1000.0'f32 / fps)
      igText("Emulation:  %.1f fps", cfloat(emu_fps))
      if app.emu_kind == ekGBA and app.gba_emu != nil and
         app.gba_emu.apu != nil:
        # GB's APU has no queued-bytes getter, so this is GBA-only
        igText("Audio queue: %u bytes", cuint(app.gba_emu.apu.audio_queued_bytes()))
      if app.cfg.rewind and app.emu_kind != ekNone:
        igText("Rewind: %d snapshots, %.1f MB", cint(app.rewind.len),
               cdouble(app.rewind.mem_used()) / (1024.0 * 1024.0))
      igSeparator()
      igText("OpenGL")
      let ver  = cast[cstring](glGetString(GL_VERSION))
      let shad = cast[cstring](glGetString(GL_SHADING_LANGUAGE_VERSION))
      igText("  Version: %s", ver)
      igText("  Shading: %s", shad)
    igEnd()

  if app.dbg != nil:
    app.dbg.render_windows()
  if app.gb_dbg != nil:
    app.gb_dbg.render_windows()
  app.cheats.render()
  app.save_states.render()

  render_link_window()

  # Home screen: point out that ROMs can be dragged onto the window (SDL2
  # has no drag-hover event, so a live "release to load" prompt isn't
  # possible until SDL3)
  if app.emu_kind == ekNone:
    let vp = igGetMainViewport()
    if vp != nil:
      let (vpos, vsize) = (vp[].Pos, vp[].Size)
      igSetNextWindowPos(ImVec2(x: vpos.x + vsize.x * 0.5'f32,
                                y: vpos.y + vsize.y - 16),
                         cint(ImGui_Cond_Always), ImVec2(x: 0.5, y: 1.0))
      igSetNextWindowBgAlpha(0.0'f32)
      let hint_flags = cint(ImGui_WindowFlags_NoDecoration) or
                       cint(ImGui_WindowFlags_NoMove) or
                       cint(ImGui_WindowFlags_NoInputs) or
                       cint(ImGui_WindowFlags_NoSavedSettings)
      if igBegin("##drop_hint", nil, hint_flags):
        igTextDisabled("Drop a ROM here to play (.gba, .gb, .gbc, .zip)")
      igEnd()

  # Paused/rewinding badge: without it a paused game with the menu bar
  # hidden looks like a frozen emulator
  if (app.paused or app.rewinding) and app.emu_kind != ekNone:
    let vp = igGetMainViewport()
    if vp != nil:
      let (vpos, vsize) = (vp[].Pos, vp[].Size)
      igSetNextWindowPos(ImVec2(x: vpos.x + vsize.x - 10,
                                y: vpos.y + overlay_h + 4),
                         cint(ImGui_Cond_Always), ImVec2(x: 1.0, y: 0.0))
      igSetNextWindowBgAlpha(0.5'f32)
      let badge_flags = cint(ImGui_WindowFlags_NoDecoration) or
                        cint(ImGui_WindowFlags_NoMove) or
                        cint(ImGui_WindowFlags_NoInputs) or
                        cint(ImGui_WindowFlags_NoSavedSettings)
      if igBegin("##paused_badge", nil, badge_flags):
        igText(if app.rewinding: cstring"<< Rewinding" else: cstring"Paused")
      igEnd()

  igRender()
  ImGui_Impl_OpenGL3_RenderDrawData(igGetDrawData())

# ──────────────────────────── Controllers ────────────────────────────

# Open game controllers, keyed by joystick instance id. SDL2 emits
# ControllerDeviceAdded for controllers already attached at init, so hotplug
# handling below covers startup too. Every opened controller feeds player 1.
var controllers: Table[int32, GameControllerPtr]

# Left-stick-as-dpad and right-trigger fast-forward state (hardcoded, not
# part of the rebindable button table)
const STICK_DEADZONE     = 8000'i16
const TRIGGER_THRESHOLD  = 8000'i16
var stick_dirs: array[Input.UP..Input.RIGHT, bool]
var pad_ff_held = false

proc emu_pad_input(inp: Input; pressed: bool) =
  case app.emu_kind
  of ekGBA:
    if app.gba_emu != nil: app.gba_emu.handle_input(inp, pressed)
  of ekGB:
    if app.gb_emu != nil: app.gb_emu.handle_input(inp, pressed)
  of ekNone: discard

proc bound_button_held(inp: Input): bool =
  # Is any controller button that maps to `inp` currently held?
  for btn, v in app.cfg.controller_bindings.pairs:
    if v == inp:
      for pad in controllers.values:
        if pad.getButton(GameControllerButton(btn)) != 0: return true
  false

proc set_stick_dir(inp: Input; active: bool) =
  if stick_dirs[inp] == active: return
  stick_dirs[inp] = active
  # Don't release a direction the d-pad (or any button bound to it) still holds
  if not active and bound_button_held(inp): return
  emu_pad_input(inp, active)

proc set_fast_forward(held: bool) =
  # Audio sync is a toggle elsewhere in the UI, so track the trigger's held
  # state and assign sync directly instead of toggling per event
  if held == pad_ff_held: return
  pad_ff_held = held
  case app.emu_kind
  of ekGBA:
    if app.gba_emu != nil: app.gba_emu.apu.sync = not held
  of ekGB:
    if app.gb_emu != nil: app.gb_emu.apu.sync = not held
  of ekNone: discard

proc update_rumble() =
  ## Poll the cart's rumble motor — GB MBC5 rumble carts, or GBA GPIO rumble
  ## carts (Drill Dozer, WarioWare: Twisted!) — and drive controller
  ## vibration: 80 ms effects re-triggered every 50 ms chain into a
  ## continuous buzz while the motor stays on. render_game reads rumble_on
  ## for the viewport shake. Effects die out on their own, but stopping
  ## explicitly on the off edge keeps short pulses crisp.
  let was_on = rumble_on
  let motor_on =
    case app.emu_kind
    of ekGB:  app.gb_emu != nil and app.gb_emu.cartridge.mbc_rumble()
    of ekGBA: app.gba_emu != nil and app.gba_emu.bus.gpio.gpio_rumble()
    of ekNone: false
  rumble_on = app.cfg.gb_rumble and not app.paused and motor_on
  if rumble_on:
    let now = getTicks()
    if now - rumble_last_pulse >= 50:
      rumble_last_pulse = now
      for pad in controllers.values:
        # 0.6 strong (low-freq) / 0.4 weak (high-freq), matching the web UI
        discard pad.game_controller_rumble(0x9999'u16, 0x6666'u16, 80)
  elif was_on:
    for pad in controllers.values:
      discard pad.game_controller_rumble(0, 0, 0)

# ──────────────────────────── Input ────────────────────────────

proc handle_input() =
  var evt = defaultEvent
  while pollEvent(evt):
    discard ImGui_ImplSDL2_ProcessEvent(cast[ptr SDL_Event](addr evt))

    case evt.kind
    of KeyDown, KeyUp:
      let pressed = evt.kind == KeyDown
      let kev     = key(evt)
      let sym     = kev.keysym.sym
      let mods    = kev.keysym.modstate

      if app.io != nil and app.io[].WantCaptureKeyboard: continue

      if app.ce.keybindings.wants_input():
        if not pressed: app.ce.keybindings.key_released(sym)
      elif (mods and MOD_KEY_MASK) != 0:
        if not pressed:
          case sym
          of K_r:
            if app.cfg.recents.len > 0: load_rom(app.cfg.recents[0])
          of K_p:
            app.paused = not app.paused
          of K_n:
            # Frame advance would desync a live link; suppress it there.
            if app.paused and app.emu_kind != ekNone and app.netlink == nil:
              app.pending_step = true
          of K_s:
            if app.emu_kind != ekNone: app.pending_save = true
          of K_l:
            # Loading a save state mid-link would desync the pair.
            if app.emu_kind != ekNone and app.netlink == nil:
              app.pending_load = true
          of K_f:
            app.fullscreen = not app.fullscreen
            let flags = if app.fullscreen: SDL_WINDOW_FULLSCREEN_DESKTOP else: 0'u32
            discard setFullscreen(app.window, flags)
          of K_q:
            app.running = false
          else: discard
      elif sym == K_F12:
        # Screenshot to config_dir/screenshots (fires on press, not release)
        if pressed: save_screenshot()
      elif sym == K_BACKQUOTE:
        # Hold-to-rewind, core-agnostic (disabled while linked — it desyncs)
        app.rewinding = pressed and app.cfg.rewind and
                        app.emu_kind != ekNone and app.netlink == nil
      elif app.emu_kind == ekGBA and app.gba_emu != nil:
        if app.cfg.keybindings.hasKey(sym):
          app.gba_emu.handle_input(app.cfg.keybindings[sym], pressed)
        elif sym == K_TAB and pressed and app.netlink == nil:
          # Turbo/fast-forward are suppressed while linked (they would run
          # ahead of the peer). Shift+Tab = 2x speed, Tab = unbounded fast
          # forward; the two are
          # mutually exclusive (fast forward would silently dominate 2x)
          if (mods and KMOD_SHIFT_MASK) != 0:
            app.gba_emu.apu.turbo = not app.gba_emu.apu.turbo
            if app.gba_emu.apu.turbo: app.gba_emu.apu.sync = true
          else:
            app.gba_emu.apu.sync = not app.gba_emu.apu.sync
            if not app.gba_emu.apu.sync: app.gba_emu.apu.turbo = false
        elif pressed and sym >= K_1 and sym <= K_6:
          # Feedback is visible in the Audio/Video > Channels submenu
          let ch = int(sym) - int(K_1)
          app.gba_emu.apu.channel_mask[ch] = not app.gba_emu.apu.channel_mask[ch]
      elif app.emu_kind == ekGB and app.gb_emu != nil:
        if app.cfg.keybindings.hasKey(sym):
          app.gb_emu.handle_input(app.cfg.keybindings[sym], pressed)
        elif sym == K_TAB and pressed:
          if (mods and KMOD_SHIFT_MASK) != 0:
            app.gb_emu.apu.turbo = not app.gb_emu.apu.turbo
            if app.gb_emu.apu.turbo: app.gb_emu.apu.sync = true
          else:
            app.gb_emu.apu.toggle_sync()
            if not app.gb_emu.apu.sync: app.gb_emu.apu.turbo = false
        elif pressed and sym >= K_1 and sym <= K_4:
          # Feedback is visible in the Audio/Video > Channels submenu
          let ch = int(sym) - int(K_1)
          app.gb_emu.apu.channel_mask[ch] = not app.gb_emu.apu.channel_mask[ch]

    of ControllerDeviceAdded:
      # `which` is a device index for the Added event
      let idx = cdevice(evt).which
      if isGameController(cint(idx)):
        let pad = gameControllerOpen(cint(idx))
        if pad != nil:
          controllers[pad.getJoystick().instanceID()] = pad

    of ControllerDeviceRemoved:
      # `which` is a joystick instance id for the Removed event
      let id = cdevice(evt).which
      if controllers.hasKey(id):
        controllers[id].close()
        controllers.del(id)
      if controllers.len == 0:
        # Unplugged mid-press: release anything the pad was holding
        for inp in Input.UP .. Input.RIGHT: stick_dirs[inp] = false
        for inp in Input: emu_pad_input(inp, false)
        set_fast_forward(false)

    of ControllerButtonDown, ControllerButtonUp:
      let pressed = evt.kind == ControllerButtonDown
      let button  = cint(cbutton(evt).button)
      if app.ce.controller.wants_input():
        if not pressed: app.ce.controller.button_released(button)
      elif app.cfg.controller_bindings.hasKey(button):
        let inp = app.cfg.controller_bindings[button]
        # Don't release a direction the left stick still holds
        if pressed or not (inp in stick_dirs.low .. stick_dirs.high and stick_dirs[inp]):
          emu_pad_input(inp, pressed)

    of ControllerAxisMotion:
      let ax = caxis(evt)
      if ax.axis == uint8(SDL_CONTROLLER_AXIS_LEFTX):
        set_stick_dir(Input.LEFT,  ax.value < -STICK_DEADZONE)
        set_stick_dir(Input.RIGHT, ax.value > STICK_DEADZONE)
      elif ax.axis == uint8(SDL_CONTROLLER_AXIS_LEFTY):
        set_stick_dir(Input.UP,   ax.value < -STICK_DEADZONE)
        set_stick_dir(Input.DOWN, ax.value > STICK_DEADZONE)
      elif ax.axis == uint8(SDL_CONTROLLER_AXIS_TRIGGERRIGHT):
        set_fast_forward(ax.value > TRIGGER_THRESHOLD)

    of WindowEvent:
      let wev = window(evt)
      if wev.event == WindowEvent_SizeChanged:
        var w, h: cint
        getSize(app.window, w, h)
        glViewport(0, 0, w, h)

    of MouseMotion:
      app.last_mouse_tick = motion(evt).timestamp

    of DropFile:
      let dropped = drop(evt)
      let path = $dropped.file
      sdl_free(dropped.file)
      let ext = path.splitFile().ext.toLowerAscii()
      if ext in ROM_EXTS or ext == ".zip":
        load_rom(path)

    of QuitEvent:
      app.running = false

    else: discard

# ──────────────────────────── FPS Title ────────────────────────────

var fps_frames    = 0
var fps_us        = 0'i64
var fps_last_time = getTime()
var fps_second    = getTime().toUnix() mod 60

proc update_fps_title(emulated: bool) =
  # Count emulated frames only: the main loop now iterates at the display's
  # refresh rate even when emulation is paced slower by audio sync
  if emulated: inc fps_frames
  let now = getTime()
  fps_us += (now - fps_last_time).inMicroseconds()
  fps_last_time = now
  let cur_sec = now.toUnix() mod 60
  if cur_sec != fps_second:
    let fps = if fps_us > 0: fps_frames.float * 1_000_000.0 / fps_us.float else: 0.0
    emu_fps = fps
    let title = if app.emu_kind == ekNone: "dingbat"
                elif app.paused: "dingbat - PAUSED"
                elif app.emu_kind == ekGBA and app.gba_emu != nil and
                     app.gba_emu.cpu.stopped: "dingbat - SLEEPING"
                else: fmt"dingbat - {fps:.1f} fps"
    setTitle(app.window, cstring(title))
    fps_frames = 0
    fps_us     = 0
    fps_second = cur_sec

# ──────────────────────────── GL proc loader ────────────────────────────

proc gl_loader(name: cstring): pointer = glGetProcAddress(name)

# ──────────────────────────── Network link ────────────────────────────

proc teardown_netlink() =
  ## Drop the network link and return the local GBA to single-player: send the
  ## peer a BYE, drain/close the socket, and swap the RemoteSioDriver back for
  ## the default no-cable driver so the game sees the cable unplug cleanly.
  if app.netlink == nil: return
  try:
    app.netlink.send_bye()
    app.netlink.close()
  except CatchableError:
    discard  # peer already gone; nothing to flush
  app.netlink = nil
  if app.gba_emu != nil:
    app.gba_emu.set_sio_driver(NullSioDriver())

const LINK_DEFAULT_PORT = 47810

# Auto-pair: connect probes to make before falling back to hosting. Probes are
# throttled to ~6/sec in service_link_setup, so 3 tries is a snappy ~0.5 s.
const LINK_AUTO_CONNECT_TRIES = 3

proc finish_link(sock: Socket; id: int; delay_ms = 0): bool =
  ## Run the HELLO handshake over an already-connected socket; on success bind
  ## the link to the local core (and drop rewind history, which would desync).
  ## Shared by the CLI flags and the ImGui "Link Cable" window. Returns false
  ## (closing the socket) on a rejected handshake.
  try:
    app.netlink = new_net_link(app.gba_emu, sock, id,
                               crc32(readFile(current_rom_path())),
                               delay_ms, allow_crc_mismatch = true)
    echo "NETLINK: linked as unit ", id, (if id == 0: " (host)" else: " (guest)"),
         (if delay_ms > 0: ", +" & $delay_ms & " ms send delay" else: "")
    app.rewind.clear()
    app.rewinding = false
    app.link_status = "Linked as " & (if id == 0: "host (unit 0)" else: "guest (unit 1)")
    app.link_auto = false  # auto-pair, if it was running, is done
    # Leave app.link_window as-is: keep the window open so it shows the paired
    # status and Disconnect control (the user closes it when they're done).
    true
  except NetLinkError as e:
    echo "NETLINK: handshake failed: ", e.msg
    app.link_status = "Handshake failed: " & e.msg
    try: sock.close()
    except CatchableError: discard
    false

proc establish_netlink(rom_path: string; listen_port: int; connect_to: string;
                       delay_ms: int): NetLink =
  ## Open a TCP link for the desktop app and run the HELLO handshake, mirroring
  ## the test harness. `--listen` becomes unit 0 (host); `--connect HOST:PORT`
  ## unit 1 (guest). Returns nil (printing the reason) on any failure so the
  ## caller falls back to normal single-player. GBA-only; ROM already loaded.
  if app.emu_kind != ekGBA or app.gba_emu == nil:
    echo "NETLINK: link mode needs a GBA ROM; continuing single-player"
    return nil
  var sock: Socket
  var id = 0
  try:
    if listen_port > 0:
      let server = newSocket(buffered = false)
      server.setSockOpt(OptReuseAddr, true)
      server.bindAddr(Port(listen_port))
      server.listen()
      echo "NETLINK: listening on port ", listen_port, " — waiting for peer..."
      var fds = @[server.getFd()]
      if selectRead(fds, 120_000) <= 0:
        echo "NETLINK: no peer connected within 120 s; continuing single-player"
        server.close()
        return nil
      server.accept(sock)
      server.close()
      id = 0
    else:
      let colon = connect_to.rfind(':')
      if colon < 0:
        echo "NETLINK: --connect wants HOST:PORT, got ", connect_to
        return nil
      let host = connect_to[0 ..< colon]
      let port = Port(parseInt(connect_to[colon + 1 .. ^1]))
      echo "NETLINK: connecting to ", connect_to, " ..."
      var connected = false
      for attempt in 0 ..< 40:  # the host may still be starting up
        sock = newSocket(buffered = false)
        try:
          sock.connect(host, port)
          connected = true
          break
        except OSError:
          sock.close()
          sleep(250)
      if not connected:
        echo "NETLINK: could not connect to ", connect_to,
             "; continuing single-player"
        return nil
      id = 1
  except OSError as e:
    echo "NETLINK: socket setup failed: ", e.msg, "; continuing single-player"
    return nil
  # Relaxed CRC: same-ROM sessions still match exactly, and cross-version link
  # games (e.g. Ruby<->Sapphire trades) with differing CRCs link fine.
  if finish_link(sock, id, delay_ms):
    result = app.netlink
  else:
    echo "NETLINK: continuing single-player"
    result = nil

proc link_ready(): bool =
  ## The link menu/window is only usable with a running GBA core.
  app.emu_kind == ekGBA and app.gba_emu != nil

proc link_cancel_setup() =
  case app.link_setup
  of lsListening:
    try: app.link_server.close()
    except CatchableError: discard
  of lsConnecting:
    if app.link_client != nil:
      try: app.link_client.close()
      except CatchableError: discard
  of lsNone: discard
  app.link_setup = lsNone

proc link_auto_start() =
  ## Begin zero-config auto-pairing on localhost. Start by probing for an
  ## existing host on 127.0.0.1:LINK_DEFAULT_PORT (reusing the non-blocking
  ## connect machinery); service_link_setup flips to hosting if nobody answers.
  if not link_ready() or app.netlink != nil or app.link_auto or
     app.link_setup != lsNone:
    return
  app.link_auto = true
  app.link_port = LINK_DEFAULT_PORT
  app.link_attempts = 0
  app.link_setup = lsConnecting
  app.link_status = ""
  echo "NETLINK: auto-pair — probing 127.0.0.1:", LINK_DEFAULT_PORT

proc link_auto_stop() =
  ## Cancel auto-pairing and tear down any listening/connecting socket exactly
  ## as the manual Cancel path does. No-op once a link is established.
  if not app.link_auto: return
  link_cancel_setup()
  app.link_auto = false

proc link_start_host() =
  ## Bind + listen (non-blocking); service_link_setup accepts the peer later.
  if not link_ready():
    app.link_status = "Load a GBA ROM first"; return
  try:
    let server = newSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(app.link_port))
    server.listen()
    server.getFd().setBlocking(false)
    app.link_server = server
    app.link_setup = lsListening
    app.link_status = ""
    echo "NETLINK: hosting on port ", app.link_port, " — waiting for a peer"
  except OSError as e:
    app.link_status = "Couldn't host on port " & $app.link_port & ": " & e.msg

proc link_start_join() =
  ## Begin joining; service_link_setup runs the (non-freezing) connect retries.
  if not link_ready():
    app.link_status = "Load a GBA ROM first"; return
  app.link_attempts = 0
  app.link_setup = lsConnecting
  app.link_status = ""

proc link_auto_listen(): bool =
  ## Auto-pair host leg: bind + listen on the default port, deliberately WITHOUT
  ## SO_REUSEADDR. On macOS SO_REUSEADDR lets a second bind to the same port
  ## silently succeed, which would leave both racing instances listening and
  ## nobody connecting. Omitting it makes the second bind fail (EADDRINUSE) —
  ## that failure is exactly what breaks the two-instance symmetry: the loser
  ## falls back to connecting and reaches the winner. Listener = unit 0.
  try:
    let server = newSocket(buffered = false)
    server.bindAddr(Port(LINK_DEFAULT_PORT))
    server.listen()
    server.getFd().setBlocking(false)
    app.link_server = server
    app.link_setup = lsListening
    echo "NETLINK: auto-pair — hosting on port ", LINK_DEFAULT_PORT
    true
  except OSError:
    false  # port already taken (peer is hosting); caller keeps probing it

proc service_link_setup() =
  ## Per-frame: poll the pending accept/connect so the UI never blocks while
  ## waiting for a peer; hand a connected socket to finish_link.
  case app.link_setup
  of lsListening:
    var fds = @[app.link_server.getFd()]
    if selectRead(fds, 0) > 0:
      var sock: Socket
      try:
        app.link_server.accept(sock)
        app.link_server.close()
      except OSError as e:
        if app.link_auto:
          # Fall back to probing for a peer instead of surfacing an error.
          app.link_attempts = 0
          app.link_setup = lsConnecting
        else:
          app.link_status = "Accept failed: " & e.msg
          app.link_setup = lsNone
        return
      app.link_setup = lsNone
      discard finish_link(sock, 0)
  of lsConnecting:
    # One blocking connect attempt throttled to ~6/sec. On localhost/LAN a
    # connect is instant (success or refused), so this does not stall the UI.
    inc app.link_attempts
    if app.link_attempts mod 10 != 1: return
    let host = $cast[cstring](addr app.link_host_buf[0])
    var sock = newSocket(buffered = false)
    try:
      sock.connect(host, Port(app.link_port))
      app.link_setup = lsNone
      discard finish_link(sock, 1)
    except OSError:
      try: sock.close()
      except CatchableError: discard
      if app.link_auto:
        # After a few quick probes with no host answering, become the host.
        # If the bind is refused (a peer grabbed the port first, or a
        # simultaneous-start race), keep probing so we reach that peer.
        if app.link_attempts >= LINK_AUTO_CONNECT_TRIES * 10:
          if not link_auto_listen():
            app.link_attempts = 0
      elif app.link_attempts > 300:  # ~5 s of retries
        app.link_status = "Couldn't reach " & host & ":" & $app.link_port
        app.link_setup = lsNone
  of lsNone: discard

proc render_link_advanced() =
  ## The manual Host/Join controls, unchanged in behavior, tucked behind a
  ## collapsed "Advanced" header. Either button first cancels auto-pairing so a
  ## manual action behaves exactly as it did before zero-config existed.
  if igCollapsingHeader_TreeNodeFlags("Advanced", 0):
    igSetNextItemWidth(120)
    discard igInputInt("Port", addr app.link_port, 1, 100, 0)
    igSeparator()
    igText("Host — share your address + port with a friend:")
    if igButton("Host game", ImVec2(x: 0, y: 0)):
      link_auto_stop(); link_cancel_setup(); link_start_host()
    igSeparator()
    igText("Join — enter the host's address:")
    igSetNextItemWidth(200)
    discard igInputTextWithHint("##link_host", "127.0.0.1",
      cast[cstring](addr app.link_host_buf[0]), csize_t(app.link_host_buf.len),
      0, nil, nil)
    igSameLine(0, -1)
    if igButton("Join game", ImVec2(x: 0, y: 0)):
      link_auto_stop(); link_cancel_setup(); link_start_join()

proc render_link_window() =
  ## The "Link Cable" window. Zero-config by default: opening it auto-pairs on
  ## localhost and shows only a status line. Manual Host/Join live under
  ## "Advanced" for cross-machine / custom-port play.
  if not app.link_window: return
  igSetNextWindowSize(ImVec2(x: 340, y: 0), cint(ImGui_Cond_FirstUseEver))
  if igBegin("Link Cable", addr app.link_window,
             cint(ImGui_WindowFlags_NoCollapse)):
    if app.netlink != nil:
      igText("Paired successfully")
      igText("%s", cstring(app.link_status))
      igText("Rewind, turbo and save-state load are paused while linked.")
      if igButton("Disconnect", ImVec2(x: 0, y: 0)):
        teardown_netlink()
        app.link_status = ""
    elif not link_ready():
      igText("Load a GBA ROM, then reopen this window to link.")
    else:
      if app.link_auto:
        # An animated ellipsis so it's visibly working; auto stops on close.
        let dots = 1 + (int(getTicks() div 400) mod 3)
        igText("Waiting to pair%s", cstring(repeat('.', dots)))
      elif app.link_setup == lsListening:
        igText("Hosting on port %d", cint(app.link_port))
        igText("Waiting for a friend to join...")
        igText("They pick Join and enter  your-ip : %d", cint(app.link_port))
        if igButton("Cancel", ImVec2(x: 0, y: 0)): link_cancel_setup()
      elif app.link_setup == lsConnecting:
        igText("Connecting to %s:%d ...",
               cstring(cast[cstring](addr app.link_host_buf[0])), cint(app.link_port))
        if igButton("Cancel", ImVec2(x: 0, y: 0)): link_cancel_setup()
      else:
        igText("Two players, one emulated link cable, over the network.")
      igSeparator()
      render_link_advanced()
    if app.link_status.len > 0 and app.netlink == nil:
      igSeparator()
      igText("%s", cstring(app.link_status))
  igEnd()

proc update_link_auto() =
  ## Drive zero-config auto-pairing off the Link Cable window's open/close edge:
  ## start probing when it opens (nothing else in progress), tear the auto
  ## socket down when it closes without having paired.
  if app.link_window and not app.link_window_prev:
    if link_ready() and app.netlink == nil and app.link_setup == lsNone:
      link_auto_start()
  elif not app.link_window and app.link_window_prev:
    link_auto_stop()
  app.link_window_prev = app.link_window

# ──────────────────────────── Main ────────────────────────────

proc main() =
  var bios_path    = ""
  var rom_path     = ""
  var cli_run_bios = false
  var has_bios_arg = false
  var use_hle        = false
  var hle_after_bios = false
  var listen_port    = 0
  var connect_to     = ""
  var netlink_delay  = 0
  var link_auto      = false
  var pos_args: seq[string]

  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":  print_help(); system.quit(0)
      of "version":    echo VERSION; system.quit(0)
      of "hle":            use_hle = true
      of "hle-after-bios": hle_after_bios = true
      of "run-bios":       cli_run_bios = true
      of "skip-bios":  cli_run_bios = false
      of "listen":
        # Values may be attached (--listen:PORT) or space-separated (--listen
        # PORT); pull the next token in the latter case, like the harness.
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        listen_port = parseInt(v)
      of "connect":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        connect_to = v
      of "netlink-delay-ms":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        netlink_delay = parseInt(v)
      of "capture":
        let parts = p.val.split(':', 1)
        capture_after = parseInt(parts[0])
        capture_path  = if parts.len > 1: parts[1] else: "capture.png"
      of "link-auto":
        # Debug/verification: kick off the same zero-config auto-pair the Link
        # Cable window does, without touching the GUI. Mirrors opening it.
        link_auto = true
      else: echo "Unknown option: --" & p.key; system.quit(1)
    of cmdArgument:
      pos_args.add(p.key)

  case pos_args.len
  of 0: discard
  of 1: rom_path  = pos_args[0]
  of 2: bios_path = pos_args[0]; rom_path = pos_args[1]; has_bios_arg = true
  else: echo "Too many arguments."; system.quit(1)

  let cfg = load_config()
  if use_hle:
    cfg.use_hle = true
    cfg.run_bios = false
  if hle_after_bios:
    cfg.hle_after_bios = true
    cfg.run_bios = true
  if has_bios_arg:
    cfg.bios_path = bios_path
    # An explicit CLI BIOS implies real-BIOS mode unless --hle* was passed
    if not use_hle and not hle_after_bios:
      cfg.use_hle = false
  if cli_run_bios: cfg.run_bios = true

  # SDL2 init
  when defined(windows):
    # Per-monitor DPI awareness (SDL >= 2.24): render at native pixels
    # instead of letting DWM bitmap-stretch the window on scaled displays
    discard setHint("SDL_WINDOWS_DPI_AWARENESS", "permonitorv2")
  if sdl2.init(INIT_VIDEO or INIT_AUDIO or INIT_JOYSTICK or INIT_GAMECONTROLLER) != SdlSuccess:
    echo "SDL2 init failed: ", $sdl2.getError(); system.quit(1)
  defer: sdl2.quit()

  # Set GL attributes before window creation
  when defined(macosx):
    discard glSetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG)
  discard glSetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE)
  discard glSetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
  discard glSetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
  discard glSetAttribute(SDL_GL_DOUBLEBUFFER, 1)
  discard glSetAttribute(SDL_GL_DEPTH_SIZE, 24)
  discard glSetAttribute(SDL_GL_STENCIL_SIZE, 8)

  let window = createWindow(
    "dingbat",
    SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
    cint(GBA_W * 3), cint(GBA_H * 3),
    SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE
  )
  if window == nil:
    echo "Failed to create window: ", $sdl2.getError(); system.quit(1)
  defer: destroyWindow(window)

  let gl_ctx = glCreateContext(window)
  if gl_ctx == nil:
    echo "Failed to create OpenGL context: ", $sdl2.getError(); system.quit(1)
  defer: glDeleteContext(gl_ctx)
  discard glSetSwapInterval(0)  # disable vsync

  # Load OpenGL function pointers
  if not gladLoadGL(gl_loader):
    echo "Failed to load OpenGL extensions"; system.quit(1)

  # GL setup
  glClearColor(60.0'f32/255, 61.0'f32/255, 107.0'f32/255, 1.0'f32)
  let game_tex = setup_game_texture()
  let border_tex = setup_border_texture()
  setup_vao()
  let game_shader = create_shader_program()
  let logo_shader = create_logo_shader_program()
  let (logo_tex, canvas_aspect) = load_logo_texture()
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  glEnable(GL_BLEND)
  glUseProgram(logo_shader)

  # ImGui setup
  discard igCreateContext(nil)
  igStyleColorsDark(nil)
  let io_ptr = igGetIO_Nil()
  discard ImGui_ImplSDL2_InitForOpenGL(cast[ptr SDL_Window](window),
                                        cast[pointer](gl_ctx))
  discard ImGui_Impl_opengl3_Init("#version 330")

  # Frontend objects
  let fe = new_file_explorer(cfg)
  let ce = new_config_editor(cfg, fe)
  # "Reset to Defaults" changes color-correction and volume, which no widget
  # owns — push them into the live GL uniform and APU here.
  ce.live_sync = proc() =
    apply_color_correction()
    apply_master_volume()
    apply_pitch_correct_ff()
    apply_audio_lowpass()
    apply_fifo_interp()
    apply_mp2k_hle()

  app = AppState(
    cfg:             cfg,
    gba_emu:         nil,
    window:          window,
    gl_ctx:          gl_ctx,
    io:              io_ptr,
    game_texture:    game_tex,
    border_texture:  border_tex,
    logo_texture:    logo_tex,
    canvas_aspect:   canvas_aspect,
    logo_shader:     logo_shader,
    game_shader:     game_shader,
    fe:              fe,
    ce:              ce,
    cheats:          new_cheats_widget(),
    save_states:     new_save_states_widget(),
    dbg:             nil,
    scale:           (when defined(gputime): parseInt(getEnv("DINGBAT_SCALE", "3")) else: 3),
    running:         true,
    paused:          false,
    fullscreen:      false,
    enable_overlay:  false,
    last_mouse_tick: getTicks(),
    rewind:          new_rewind(),
    link_port:       LINK_DEFAULT_PORT,
  )
  # Save States widget: the app owns the files, textures and core, so the
  # widget just calls back. Save/Load run synchronously here — render_imgui is
  # always reached at a frame boundary (right after process_pending_state).
  app.save_states.on_open = proc() = refresh_state_slots()
  app.save_states.on_save = proc(slot: int) = discard save_state_slot(slot)
  app.save_states.on_load = proc(slot: int) =
    # Surface WHY a load was refused. The core distinguishes a wrong ROM
    # from a newer-build file from a corrupt section; discarding the bool
    # left the user with a silently unchanged screen.
    if not load_state_slot(slot):
      # Same sentence-per-cause table the Quick Load path uses, instead of the
      # core's raw wording. The detail stays available in the log.
      app.save_states.notice = state_reject_sentence()
      if last_state_error.len > 0:
        echo "Slot load refused: ", last_state_error
  app.save_states.on_delete = proc(slot: int) = delete_state_slot(slot)

  # Default the Join address to localhost (2 instances on one machine).
  let default_host = "127.0.0.1"
  for i, c in default_host: app.link_host_buf[i] = c
  # GLSL uniforms default to 0/false, so push the configured value now
  # (tex_height too: 0 would make the scanline fract() darken everything)
  apply_color_correction()
  apply_panel_uniforms()

  if listen_port > 0 and connect_to.len > 0:
    echo "Use either --listen or --connect, not both."; system.quit(1)

  if rom_path != "":
    if not fileExists(rom_path):
      echo "ROM file not found: ", rom_path; system.quit(1)
    load_rom(rom_path)
    # Bring up the 2-player network link once the core exists (GBA only).
    if listen_port > 0 or connect_to.len > 0:
      app.netlink = establish_netlink(rom_path, listen_port, connect_to,
                                      netlink_delay)
    elif link_auto:
      # Mirror opening the Link Cable window: open it so update_link_auto's
      # open-edge detection kicks off zero-config auto-pairing.
      if link_ready():
        app.link_window = true
      else:
        echo "NETLINK: --link-auto needs a GBA ROM; ignoring"
  elif listen_port > 0 or connect_to.len > 0:
    echo "NETLINK: --listen/--connect need a ROM path; ignoring"
  elif link_auto:
    echo "NETLINK: --link-auto needs a ROM path; ignoring"

  # The UI (ImGui + present) runs at the display's refresh rate, decoupled
  # from emulation speed in both directions:
  #  - Emulation faster than the display (audio sync off / fast forward):
  #    presents are skipped down to the display rate instead of wasting
  #    ~1 ms per emulated frame on texture upload + swap.
  #  - Emulation paced below the display rate (audio sync at ~60 fps on a
  #    120 Hz display): audio pacing happens here — skip emulation while the
  #    audio queue is ahead — so the loop keeps servicing the UI instead of
  #    blocking inside the APU's queue-drain wait.
  var display_mode: DisplayMode
  var present_interval = 8'u32
  if getDesktopDisplayMode(0, display_mode) == SdlSuccess and
     display_mode.refresh_rate > 0:
    present_interval = uint32(1000 div display_mode.refresh_rate)
  var last_present = getTicks()
  # Pacing diagnostics (env-gated): DINGBAT_PACING_LOG=1 prints one line per
  # second with emulated-frame counts and SDL audio queue depth bounds, for
  # verifying that audio-sync pacing holds the hardware frame rate (59.7275)
  # without draining the queue (qmin=0 would mean an underrun)
  # ── Wall-clock frame scheduler (normal-speed play) ──────────────────────
  # Releasing frames purely on audio-queue depth tied the emulation cadence to
  # the queue's push/drain granularity, which jittered frame spacing (and so
  # input latency) by most of a frame. Normal play instead runs each frame on
  # a fixed 16.743 ms wall-clock slot (280896 cycles / 16.777216 MHz; the GB
  # frame is the same period) and uses the audio queue only as a bounds check:
  # refill immediately when it nears underrun, hold the slot if it ran away.
  # Turbo (2x) and fast-forward keep pure audio pacing — their frame rate is
  # intentionally not the hardware rate.
  let sched_freq = getPerformanceFrequency()
  let frame_ticks = sched_freq * 280896'u64 div 16777216'u64
  var next_frame_due = getPerformanceCounter()

  var sched_refilling = true  # start with an empty queue: fill to target

  proc scheduler_frame_due(queued, low, target, high: uint32): bool =
    let now = getPerformanceCounter()
    if next_frame_due + frame_ticks < now:
      # Stalled (pause, hitch, held slots): resync instead of bursting a
      # backlog of missed slots
      next_frame_due = now
    if queued > high: return false  # queue ran away: hold until it drains
    # Underrun guard with hysteresis: once the queue dips below `low`, burst
    # frames until it reaches `target`. Stopping at `low` itself would park
    # the steady-state level right on the threshold, so every frame would
    # re-trigger an early refill and the cadence would follow the audio
    # drain granularity again instead of the wall clock.
    if queued < low: sched_refilling = true
    if sched_refilling:
      if queued < target: return true
      sched_refilling = false
    now >= next_frame_due

  proc scheduler_frame_ran() =
    # Clamp to one period from now: refill-burst frames must not bank future
    # slots (that would starve the queue right back below the refill line and
    # turn the cadence into a burst/hold sawtooth)
    next_frame_due = min(next_frame_due + frame_ticks,
                         getPerformanceCounter() + frame_ticks)

  proc is_paced(): bool =
    ## True while emulation is meant to run at exactly hardware speed
    case app.emu_kind
    of ekGBA: app.gba_emu != nil and app.gba_emu.apu.sync and
              not app.gba_emu.apu.turbo
    of ekGB:  app.gb_emu != nil and app.gb_emu.apu.sync and
              not app.gb_emu.apu.turbo
    of ekNone: false

  proc gba_frame_due(): bool =
    let apu = app.gba_emu.apu
    if not apu.sync or apu.turbo: return not apu.audio_ahead()
    # s16 stereo is 4 B/frame: 1024/3072/8192 B ≈ 7.8/23.4/62.5 ms of audio
    scheduler_frame_due(apu.audio_queued_bytes(), 1024, 3072, 8192)

  proc gb_frame_due(): bool =
    let apu = app.gb_emu.apu
    if not apu.sync or apu.turbo: return not apu.audio_ahead()
    # f32 stereo is 8 B/frame: the same time bounds are 2048/6144/16384 B
    scheduler_frame_due(apu.audio_queued_bytes(), 2048, 6144, 16384)

  let pacing_log = getEnv("DINGBAT_PACING_LOG").len > 0
  var pace_frames = 0
  var pace_total  = 0
  var pace_min_q  = uint32.high
  var pace_max_q  = 0'u32
  var pace_start  = 0'u32
  var pace_last   = 0'u32
  # Input-latency self-test (env-gated): DINGBAT_LATENCY_TEST=<trials> injects
  # a synthetic UP press at the same point in the loop where polled SDL key
  # events are applied, then measures wall-clock time until (a) the emulated
  # framebuffer first differs — the core rendered the response — and (b) that
  # framebuffer reaches glSwapWindow. Needs a GBA ROM whose screen is static
  # until a keypress and responds on the next frame (tonc m7_demo.gba works:
  # UP moves the camera). Prints per-trial lines and a summary, then quits.
  var lat_trials = 0
  try: lat_trials = parseInt(getEnv("DINGBAT_LATENCY_TEST", "0"))
  except ValueError: discard
  var lat_state = 0            # 0 settle, 1 awaiting fb change, 2 awaiting present
  var lat_settle = 0
  var lat_inject_at = 0'u64
  var lat_rng = 0x9E3779B97F4A7C15'u64
  var lat_t0, lat_t1: uint64
  var lat_base: uint32
  var lat_wait = 0
  var lat_change_ms: seq[float]
  var lat_present_ms: seq[float]
  let lat_freq = float(getPerformanceFrequency())
  proc lat_ms(a, b: uint64): float = float(b - a) * 1000.0 / lat_freq
  proc lat_fb_hash(): uint32 =
    result = 0x811C9DC5'u32
    for v in app.gba_emu.ppu.framebuffer:
      result = (result xor uint32(v and 0xFF)) * 0x01000193'u32
      result = (result xor uint32(v shr 8)) * 0x01000193'u32
  proc lat_stats(xs: seq[float]): (float, float, float) =
    var mn = xs[0]
    var mx = xs[0]
    var s  = 0.0
    for x in xs:
      mn = min(mn, x)
      mx = max(mx, x)
      s += x
    (mn, s / float(xs.len), mx)
  if lat_trials > 0:
    echo "LATENCY: present_interval=", present_interval, " ms, ",
         "display refresh=", display_mode.refresh_rate, " Hz"
  while app.running:
    var emulated = false
    # Frame advance bypasses the audio pacing gate: it must run exactly one
    # frame regardless of queue depth
    let stepping = app.paused and app.pending_step
    app.pending_step = false
    if app.rewinding and app.emu_kind != ekNone and app.netlink == nil:
      # Step history backward at a fixed cadence (~30 pops/s of 10-frame
      # snapshots ≈ 5x realtime). Applying a snapshot restores the serialized
      # framebuffer, so presenting it shows the rewound frame directly.
      let now_r = getTicks()
      if now_r - app.last_rewind_pop >= 33:
        app.last_rewind_pop = now_r
        let snap = app.rewind.pop()
        if snap.len > 0:
          try:
            case app.emu_kind
            of ekGBA: app.gba_emu.apply_state_payload(snap)
            of ekGB:  app.gb_emu.apply_state_payload(snap)
            of ekNone: discard
            emulated = true
          except CatchableError:
            echo "Rewind failed: ", getCurrentExceptionMsg()
            app.rewinding = false
    elif not app.paused or stepping:
      case app.emu_kind
      of ekGBA:
        if app.gba_emu != nil and (stepping or gba_frame_due()):
          if app.netlink != nil:
            # Linked: advance through the netlink so the socket is pumped and
            # the two sides stay in lockstep. On the peer leaving or a link
            # error, tear the link down and keep running single-player.
            try:
              app.netlink.step_frame()
              emulated = true
            except NetLinkError as e:
              echo "NETLINK: link lost: ", e.msg, " — continuing single-player"
              teardown_netlink()
            if app.netlink != nil and app.netlink.peer_done:
              echo "NETLINK: peer disconnected — continuing single-player"
              teardown_netlink()
          else:
            app.gba_emu.run_until_frame()
            emulated = true
      of ekGB:
        if app.gb_emu != nil and (stepping or gb_frame_due()):
          app.gb_emu.run_until_frame()
          emulated = true
      of ekNone: discard
      if emulated and is_paced():
        scheduler_frame_ran()
      if emulated and app.cfg.rewind and not app.cfg.speed_mode and
         app.netlink == nil:
        case app.emu_kind
        of ekGBA:
          discard app.rewind.maybe_push(proc(): string = app.gba_emu.state_payload())
        of ekGB:
          discard app.rewind.maybe_push(proc(): string = app.gb_emu.state_payload())
        of ekNone: discard
    if lat_trials > 0 and app.emu_kind == ekGBA and app.gba_emu != nil and
       not app.paused:
      case lat_state
      of 0:
        if emulated:
          inc lat_settle
        if lat_settle >= 40:  # let the screen go static between trials
          # Inject at a per-trial pseudo-random phase within the frame period
          # so the trials sample the whole arrival-time distribution, not just
          # the just-missed-a-frame worst case
          if lat_inject_at == 0:
            lat_rng = lat_rng * 6364136223846793005'u64 + 1442695040888963407'u64
            lat_inject_at = getPerformanceCounter() +
                            (lat_rng shr 33) mod frame_ticks
          elif getPerformanceCounter() >= lat_inject_at:
            lat_inject_at = 0
            lat_settle = 0
            lat_base = lat_fb_hash()
            app.gba_emu.handle_input(UP, true)
            lat_t0 = getPerformanceCounter()
            lat_wait = 0
            lat_state = 1
      of 1:
        if emulated:
          if lat_fb_hash() != lat_base:
            lat_t1 = getPerformanceCounter()
            lat_state = 2
          else:
            inc lat_wait
            if lat_wait > 10:
              echo "LATENCY: no fb change within 10 frames — wrong ROM or key?"
              app.gba_emu.handle_input(UP, false)
              lat_state = 0
      else: discard
    # Pending save/load states run here, at a guaranteed frame boundary
    if (app.pending_save or app.pending_load) and app.emu_kind != ekNone:
      process_pending_state()
    if pacing_log and app.emu_kind == ekGBA and app.gba_emu != nil and
       not app.paused:
      let q = app.gba_emu.apu.audio_queued_bytes()
      pace_min_q = min(pace_min_q, q)
      pace_max_q = max(pace_max_q, q)
      if emulated:
        if pace_start == 0:
          pace_start = getTicks()
          pace_last  = pace_start
        inc pace_frames
        inc pace_total
      if pace_start != 0:
        let t = getTicks()
        if t - pace_last >= 1000:
          let elapsed = float(t - pace_start) / 1000.0
          echo &"pacing t={elapsed:.2f}s frames_1s={pace_frames} " &
               &"total={pace_total} avg_fps={float(pace_total - 1)/elapsed:.4f} " &
               &"qmin={pace_min_q} qmax={pace_max_q}"
          pace_last = t
          pace_frames = 0
          pace_min_q = uint32.high
          pace_max_q = 0
    handle_input()
    update_rumble()
    update_link_auto()    # start/stop zero-config auto-pair on window open/close
    service_link_setup()  # non-blocking accept/connect for the Link window
    let now = getTicks()
    var presented = false
    # A freshly emulated frame is presented immediately while emulation runs
    # at realtime (audio sync on, no turbo): holding it for the next interval
    # slot added up to a display period of input latency and beat against the
    # emulation cadence. The interval throttle still bounds present rate when
    # emulation outruns the display (turbo / fast-forward), and keeps the UI
    # refreshing when nothing was emulated (paused, menus, audio ahead).
    if (emulated and is_paced()) or now - last_present >= present_interval:
      last_present = now
      # Black behind a game so the letterbox bars read as bezel; the brand
      # purple is the empty-app backdrop and stays that way.
      if app.emu_kind == ekNone:
        glClearColor(60.0'f32/255, 61.0'f32/255, 107.0'f32/255, 1.0'f32)
      else:
        glClearColor(0'f32, 0'f32, 0'f32, 1.0'f32)
      glClear(GL_COLOR_BUFFER_BIT)
      render_game()
      inc present_count
      if capture_after >= 0 and present_count >= capture_after:
        let (cx, cy, cw, ch) = game_viewport()
        var pix = newSeq[byte](int(cw) * int(ch) * 3)
        glPixelStorei(GL_PACK_ALIGNMENT, 1)
        glReadPixels(cx, cy, GLsizei(cw), GLsizei(ch), GL_RGB, GL_UNSIGNED_BYTE,
                     addr pix[0])
        # GL reads bottom-up; PNG wants top-down.
        var flipped = newSeq[byte](pix.len)
        let stride = int(cw) * 3
        for row in 0 ..< int(ch):
          copyMem(addr flipped[row * stride],
                  addr pix[(int(ch) - 1 - row) * stride], stride)
        if stbiw.writePNG(capture_path, int(cw), int(ch), 3, flipped):
          echo "capture written: ", capture_path, " ", cw, "x", ch
        else:
          echo "capture FAILED: ", capture_path
        app.running = false
      render_imgui()
      glSwapWindow(window)
      presented = true
      if lat_trials > 0 and lat_state == 2:
        let t2 = getPerformanceCounter()
        lat_change_ms.add(lat_ms(lat_t0, lat_t1))
        lat_present_ms.add(lat_ms(lat_t0, t2))
        echo &"LATENCY trial {lat_present_ms.len}: " &
             &"inject→fb-change {lat_ms(lat_t0, lat_t1):.2f} ms, " &
             &"inject→present {lat_ms(lat_t0, t2):.2f} ms"
        app.gba_emu.handle_input(UP, false)
        lat_state = 0
        if lat_present_ms.len >= lat_trials:
          let (c0, c1, c2) = lat_stats(lat_change_ms)
          let (p0, p1, p2) = lat_stats(lat_present_ms)
          echo &"LATENCY inject→fb-change ms: min {c0:.2f} avg {c1:.2f} max {c2:.2f}"
          echo &"LATENCY inject→present ms:  min {p0:.2f} avg {p1:.2f} max {p2:.2f}"
          app.running = false
    update_fps_title(emulated)
    if not emulated and not presented:
      # Idle until audio drains or the next present slot; don't busy-spin
      delay(1)
  flush_gb_save()

main()
