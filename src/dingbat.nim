import std/[os, hashes, math, options, parseopt, strformat, strutils, tables, times, algorithm]
import sdl2 except init, quit, glBindTexture, glUnbindTexture
import sdl2/joystick
import sdl2/gamecontroller
import imguin/[cimgui, impl_opengl, impl_sdl2]
import imguin/glad/gl
import stb_image/read as stbi
import stb_image/write as stbiw
import dingbat/common/config
import dingbat/common/atomicfile
import dingbat/common/lcd_response
import dingbat/common/input
import dingbat/common/rewind
import dingbat/gba/gba
import dingbat/gba/netlink
import dingbat/gb/gb
import dingbat/frontend/file_explorer
import dingbat/frontend/notice
import dingbat/frontend/config_editor
import dingbat/frontend/keybindings_widget
import dingbat/frontend/controller_widget
import dingbat/frontend/held_input
import dingbat/frontend/gba_debug
import dingbat/frontend/gb_debug
import dingbat/frontend/cheats_widget
import dingbat/frontend/save_states_widget
import dingbat/frontend/link_cable
import dingbat/frontend/persist
import dingbat/frontend/game_load
import dingbat/frontend/game_lock
import dingbat/frontend/window_restore
when defined(gui_driver):
  import dingbat/frontend/gui_driver
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
#  - GBA: the ares colour model (ISC, see THIRD_PARTY_NOTICES.md): linearize
#    γ4.0, mix, re-gamma. Matches bgr555_to_rgb and the wasm LUT.
#  - GB/GBC: Pokefan531's "GBC-Color" model. The CGB panel is far less washed
#    out than the AGB's, so the GBA curve would crush its colors.
#
# Upscale filters: the hq4x- and xBR-style branches follow the public
# algorithm descriptions. Mirrored in web/glpresent.js's GLSL ES shader.
const FRAG_SRC = """
#version 330 core
in vec2 tex_coord;
out vec4 frag_color;
uniform sampler2D input_texture;
uniform sampler2D border_texture;
uniform bool color_correct;
uniform bool panel_gbc;
uniform bool lcd_grid;
uniform float tex_width;
uniform float tex_height;
// The pixel pitches the LCD-grid and RGB-subpixel looks use. Equal to the
// game texture's dims without a border; with one they are the OUTPUT dims
// (256x224), because the SGB border and the Game Boy window are both native
// pixels of the same picture. Feed tex_width/tex_height here instead and the
// border gets a 160x144 grid stretched over 256x224.
uniform float scan_height;
uniform float scan_width;
uniform bool subpixel;
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
      0.0 * lin.b +  50.0 * lin.g + 240.0 * lin.r,
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
  // "LCD grid": a thin dark seam between every pixel, on BOTH axes — the
  // pixel matrix a reflective Game Boy LCD really shows (scanlines were a CRT
  // idiom; no handheld panel has them). The seam is the trailing quarter of
  // each cell and darkens gently, so the grid reads as texture rather than as
  // bars. fract() of the negative tex_coord.y still lands in [0,1).
  if (lcd_grid &&
      (fract(tex_coord.x * scan_width) > 0.75 ||
       fract(tex_coord.y * scan_height) > 0.75)) {
    rgb *= 0.85;
  }
  // "RGB subpixels": draw the display's own structure — each emulated pixel
  // splits into three vertical R/G/B stripes over a darkened row gap, the way
  // a GBC/GBA TFT's subpixel triad looks up close (a DMG panel has no
  // subpixels, so there this is a stylised look, not a simulation). The
  // off-stripes keep half and a 1.35 gain rebalances overall brightness;
  // min() stops the gain pushing whites into hue shifts.
  if (subpixel) {
    int stripe = int(fract(tex_coord.x * scan_width) * 3.0);
    vec3 m = stripe == 0 ? vec3(1.0, 0.5, 0.5)
           : stripe == 1 ? vec3(0.5, 1.0, 0.5)
           :               vec3(0.5, 0.5, 1.0);
    rgb = min(rgb * m * 1.35, vec3(1.0));
    if (fract(tex_coord.y * scan_height) > 0.85) rgb *= 0.7;
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
  echo "  --run-bios       Run the BIOS intro"
  echo "  --skip-bios      Skip the BIOS intro"
  echo "  (BIOS options and a BIOS argument hold for this run; Settings keep theirs)"
  echo "  --version        Print version"
  echo ""
  echo "Network link (2-player, GBA only; the same game, or two that trade):"
  echo "  --listen PORT       Host the link on PORT (this side is unit 0)"
  echo "  --connect HOST:PORT Join a host's link (this side is unit 1)"
  echo "  --netlink-delay-ms N  Add N ms of send latency (network simulation)"
  echo "  --link-auto         Zero-config auto-pair on localhost (same as opening"
  echo "                      the Link Cable window)"
  echo "  Two windows on one computer can't open the same ROM file (they would"
  echo "  share its save): open a different game in each (Ruby and Sapphire),"
  echo "  or a copy of the ROM file under another name."
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

type AppState = ref object
  cfg:             Config
  cur_path:        string  # what load_rom last loaded (a zip: the zip); Reset reloads it
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
  # Set when a save state is refused; render_state_notice draws it.
  state_notice:      string
  state_notice_hint: string
  # Set when a ROM could not be loaded; render_load_notice draws it.
  load_notice:       string
  load_notice_hint:  string
  # This window's hold on its game's files: a second window is refused
  game_lock:       GameLock
  # Command-line BIOS choices: for this run only, never written to cfg
  boot_overrides:  BootOverrides
  # A battery save that can't be written; shown in the same modal once
  # state_notice is clear (poll_battery_notice).
  battery:           BatteryNotice
  rewind:          Rewind
  rewinding:       bool    # true while the rewind key is held
  last_rewind_pop: uint32
  # Active 2-player network link (nil = single-player). While non-nil the
  # local GBA core is driven by netlink.step_frame instead of run_until_frame
  # so the socket stays pumped and the two sides stay in sync; rewind, frame
  # advance, turbo and save-state load are suppressed (they would desync).
  netlink:         NetLink
  # ImGui "Link Cable" window; establishment is non-blocking so the UI keeps
  # rendering while waiting for a peer.
  link_window:     bool
  link:            LinkCable  # pairing state (frontend/link_cable.nim)
  fullscreen:      bool
  fs_track:        FullscreenTrack  # the window's real state (window_restore.nim)
  enable_overlay:  bool
  last_mouse_tick: uint32

var app: AppState

# Emulated-frames FPS (not the UI framerate), updated once a second
var emu_fps = 0.0

# LCD response (common/lcd_response.nim): per-pixel panel model,
# presentation-only, so safe to change live. Cell state is dropped on ROM load.
var lcd_resp: LcdResponse

# MBC5 rumble (GB cart types 0x1C-0x1E): update_rumble polls the cart's motor
# once per main-loop iteration into rumble_on, which render_game reads for
# the viewport shake; rumble_flip alternates the jitter direction per present.
var rumble_on         = false
var rumble_flip       = false
var rumble_last_pulse = 0'u32

# ──────────────────────────── ROM Loading ────────────────────────────

proc flush_saves() =
  ## Before a core is dropped (a switch, a Reset) and at quit: the last
  ## frame's battery write, or a state loaded while paused, is on disk. A
  ## failure is the core's to log (once) and poll_battery_notice's to show.
  discard flush_batteries(app.gba_emu, app.gb_emu)

proc apply_color_correction() =
  glUseProgram(app.game_shader)
  let loc = glGetUniformLocation(app.game_shader, "color_correct")
  glUniform1i(loc, GLint(if app.cfg.color_correction: 1 else: 0))

proc sgb_border_active(): bool =
  ## The last condition keeps the window from resizing for a cart that
  ## colours its screen but ships no border art.
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
  ## Size the window to an integer multiple of the native picture. In
  ## fullscreen the letterbox does the work, and the window is sized once
  ## it is a window again (track_fullscreen).
  if app.fullscreen:
    app.fs_track.refit = true
    return
  let (w, h) = output_size()
  setSize(app.window, cint(w * app.scale), cint(h * app.scale))

proc remember_fullscreen(on: bool) =
  ## The menu's checkmark, and saved, so the next start can come back this
  ## way (window_restore.nim).
  app.fullscreen = on
  if app.cfg.fullscreen != on:
    app.cfg.fullscreen = on
    save_config(app.cfg)

proc set_fullscreen(on: bool) =
  ## Menu and Cmd/Ctrl+F.
  remember_fullscreen(on)
  discard setFullscreen(app.window, if on: SDL_WINDOW_FULLSCREEN_DESKTOP else: 0'u32)

proc window_is_fullscreen(): bool =
  ## What the window really is. On macOS AppKit is asked: a fullscreen Space
  ## entered from the green button or Ctrl+Cmd+F sets no SDL 2 flag.
  when defined(macosx):
    var info: WMinfo
    getVersion(info.version)
    if getWMInfo(app.window, info) and info.subsystem == SysWM_Cocoa:
      # SDL_SysWMinfo.info.cocoa.window, the union's first member
      return ns_window_fullscreen(cast[ptr pointer](addr info.padding[0])[])
  (getFlags(app.window) and SDL_WINDOW_FULLSCREEN) != 0

proc track_fullscreen() =
  ## On a window resize: take up a fullscreen the OS entered or left for the
  ## window, and size a window back from fullscreen to the picture if a
  ## sizing was deferred meanwhile (else a Game Boy game loaded while
  ## fullscreen came back in a GBA-shaped window, letterboxed).
  let real = window_is_fullscreen()
  case app.fs_track.observe(real, app.fullscreen)
  of fcNone: discard
  of fcEntered, fcLeft:
    remember_fullscreen(real)
    # SDL 2 on macOS adopts a Space it did not make ("already there"), so
    # the menu's toggle can leave it; where SDL already agrees, a no-op.
    discard setFullscreen(app.window,
                          if real: SDL_WINDOW_FULLSCREEN_DESKTOP else: 0'u32)
  if app.fs_track.take_refit(real): resize_to_output()

proc game_viewport(): (GLint, GLint, GLint, GLint) =
  ## The letterboxed rect the game quad is drawn into. An SGB border switches
  ## the picture from 10:9 to 8:7 mid-session, so one window must fit both.
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
  let eff = app.cfg.pitch_correct_ff and not app.cfg.speed_mode
  if app.gba_emu != nil:
    app.gba_emu.apu.set_pitch_correct_ff(eff)
  if app.gb_emu != nil:
    app.gb_emu.apu.set_pitch_correct_ff(eff)

proc apply_audio_lowpass() =
  # Analog-output low-pass models the GBA's cap/speaker smoothing; only the
  # GBA DirectSound path has the FIFO imaging it targets.
  if app.gba_emu != nil:
    app.gba_emu.apu.set_audio_lowpass(app.cfg.audio_lowpass and
                                      not app.cfg.speed_mode)

proc apply_mp2k_hle() =
  # Arming costs nothing: the HLE engages only when mp2k.nim's runtime
  # detection recognizes the engine in the loaded game.
  if app.gba_emu != nil:
    app.gba_emu.mp2k_hle = app.cfg.mp2k_hle and not app.cfg.speed_mode

proc apply_fifo_interp() =
  # DirectSound FIFO interpolation (cubic). Off is bit-true DAC output.
  if app.gba_emu != nil:
    app.gba_emu.apu.set_fifo_interp(app.cfg.fifo_interp and
                                    not app.cfg.speed_mode)

proc apply_speed_mode() =
  # Speed mode (low-end devices): GBA renders every other frame and the
  # emulated CPU is charged double cycles. Live on the running GBA core; the
  # GB renderer choice (scanline while on) applies at the next ROM load.
  if app.gba_emu != nil:
    app.gba_emu.ppu.frameskip = if app.cfg.speed_mode: 1 else: 0
    app.gba_emu.set_underclock(if app.cfg.speed_mode: 1 else: 0)
  if app.gb_emu != nil:
    # Honored only by the scanline renderer (forced at the next ROM load
    # while the mode is on); the FIFO renderer ignores the field.
    app.gb_emu.ppu.frameskip = if app.cfg.speed_mode: 1 else: 0
  # The audio niceties are suspended (not overwritten) while speed mode is
  # on; each apply proc reads speed_mode itself
  apply_mp2k_hle()
  apply_fifo_interp()
  apply_pitch_correct_ff()
  apply_audio_lowpass()

proc current_cheat_engine(): CheatEngine
proc load_cheats()
proc on_cheats_changed()
proc save_state_slot(slot: int): bool
# Network link procs, defined below with the rest of the link code
proc teardown_netlink(why = "")
proc link_cancel_setup()
proc link_auto_stop()

# ──────────────────────────── Input log ────────────────────────────
# DINGBAT_INPUT_LOG=<path> records a GBA session's keypad as "<frame> <mask>"
# lines (mask in KEYINPUT bit order, set before that frame runs) for
# tools/playtest, which replays it headless and turns it into a script. Loading
# a state or rewinding breaks the frame timeline; the log says so. Every 60
# frames a "hash" line carries the framebuffer hash the playtest drivers
# compute, so a replay can prove it is still in step; F9 writes a "mark" (the
# player saying "check this screen"). The RTC is frozen at the playtest
# harness's epoch while recording, so a clock-reading game replays the same.

const INPUT_LOG_RTC_EPOCH = 1136073600'i64   # tools/playtest DEFAULT_RTC

var input_log: system.File
var input_log_open = false
var input_log_frame = 0
var input_log_mask = 0

proc input_log_start(rom_path: string) =
  let path = getEnv("DINGBAT_INPUT_LOG")
  if path.len == 0: return
  if input_log_open: input_log.close()
  # append: every ROM load (including a reset) starts a new session in the file
  input_log_open = open(input_log, path, fmAppend)
  if not input_log_open:
    echo "input log: cannot write ", path
    return
  input_log.writeLine "session " & $getTime().toUnix
  input_log.writeLine "rom " & rom_path
  let g = app.gba_emu
  input_log.writeLine &"bios run_bios={g.run_bios} use_hle={g.use_hle} hle_after_bios={g.hle_after_bios}"
  app.gba_emu.enable_deterministic_rtc(INPUT_LOG_RTC_EPOCH)
  input_log.writeLine &"rtc {INPUT_LOG_RTC_EPOCH}"
  input_log.flushFile()
  input_log_frame = 0
  input_log_mask = 0
  echo "input log: recording to ", path

proc input_log_fb_hash(): uint64 =
  ## FNV-1a over the 15-bit pixels, as tools/playtest/drivers hash them
  result = 0xcbf29ce484222325'u64
  for p in app.gba_emu.ppu.framebuffer:
    result = (result xor uint64(p and 0x7FFF)) * 0x100000001b3'u64

proc input_log_frame_start() =
  if not input_log_open: return
  if input_log_frame mod 60 == 0 and input_log_frame > 0:
    input_log.writeLine &"hash {input_log_frame} {input_log_fb_hash().toHex}"
  let mask = int(not toU16(app.gba_emu.keypad.keyinput) and 0x03FF'u16)
  if mask != input_log_mask:
    input_log.writeLine &"{input_log_frame} {mask}"
    input_log.flushFile()
    input_log_mask = mask
  inc input_log_frame

proc input_log_event(what: string) =
  if not input_log_open: return
  input_log.writeLine &"desync {input_log_frame} {what}"
  input_log.flushFile()

proc input_log_mark() =
  if not input_log_open: return
  input_log.writeLine &"mark {input_log_frame}"
  input_log.flushFile()
  echo "input log: mark at frame ", input_log_frame

proc input_log_close() =
  if not input_log_open: return
  input_log.writeLine &"end {input_log_frame}"
  input_log.close()
  input_log_open = false

proc new_core_takes_held_input()  # defined below, with the controllers

proc load_notice(text, hint: string) =
  echo text, (if hint.len > 0: " (" & hint & ")" else: "")
  app.load_notice = text
  app.load_notice_hint = hint

proc load_rom(path: string) =
  ## Every failure leaves the running game (or the home screen) as it was and
  ## says why.
  if not fileExists(path):
    load_notice(&"{path.extractFilename()} isn't there any more.", path)
    return
  # Zips: load the first ROM inside; recents keep the zip path itself
  var rom_path = path
  if path.splitFile().ext.toLowerAscii() == ".zip":
    rom_path = extract_zip_rom(config_dir() / "zip-cache", path)
    if rom_path == "":
      load_notice(&"No Game Boy or GBA ROM could be read from {path.extractFilename()}.", "")
      return
  # Before the new core reads the .sav: a Reset reloads the same file
  flush_saves()
  # A game another dingbat window has open is refused before its .sav is
  # read; a Reset keeps this window's own lock
  let lock_dir = config_dir() / "locks"
  var claim: GameLock
  if not app.game_lock.claim_files(lock_dir, rom_path, claim):
    let (text, hint) = refusal_notice(rfFiles, path.extractFilename(),
                                      rom_path.extractFilename())
    load_notice(text, hint)
    return
  # The new core is built and checked before anything of the old one goes
  let boot = boot_settings(app.cfg, app.boot_overrides)
  if boot.note.len > 0 and not is_gb_rom(rom_path): echo boot.note
  let built = build_core(rom_path, CoreOptions(
    gb_bootrom: app.cfg.gb_bootrom_path,
    # Speed mode forces the cheaper scanline renderer; the FIFO preference
    # is remembered and returns when it is switched off.
    gb_fifo: app.cfg.gb_fifo and not app.cfg.speed_mode,
    headless: app.cfg.headless, gb_run_bios: boot.gb_run_bios,
    sgb: app.cfg.sgb_enable, bios_path: boot.bios_path,
    run_bios: boot.run_bios, use_hle: boot.use_hle,
    hle_after_bios: boot.hle_after_bios))
  if built.error.len > 0:
    claim.abandon()
    load_notice(built.error, built.detail)
    return
  # A copy of this game under the same file name shares its save-state slots
  let identity = if built.gb != nil: built.gb.state_rom_identity()
                 else: built.gba.state_rom_identity()
  if not app.game_lock.claim_states(lock_dir, rom_path, identity, claim):
    claim.abandon()
    let (text, hint) = refusal_notice(rfStates, path.extractFilename(),
                                      rom_path.extractFilename())
    load_notice(text, hint)
    return
  # The link, or a setup still waiting for a peer, belongs to the outgoing
  # core: left up, the netlink keeps driving that core unseen, and a peer
  # arriving later is bound to whatever is loaded then, a GB game included
  if app.netlink == nil and app.link.setup != lsNone:
    app.link.status = "Link ended: another game was loaded."
  link_auto_stop()
  link_cancel_setup()
  teardown_netlink("another game was loaded")
  # A Quick Save asked for in this same batch of input is the outgoing
  # game's: saved now, not dropped. With the link gone the core is at a frame
  # boundary (teardown finishes a frame the link left torn).
  if app.pending_save:
    app.pending_save = false
    if not save_state_slot(0):
      app.state_notice = QUICK_SAVE_FAILED
      app.state_notice_hint = last_state_error
  # What that finished frame wrote goes too
  flush_saves()
  # The old game's files are written out; its locks go to the new game
  app.game_lock.commit(claim)
  if built.gb != nil:
    app.gb_emu = built.gb
    app.gba_emu = nil
    app.emu_kind = ekGB
    app.border_shown = false
    app.border_gen = 0
    setSize(app.window, cint(GB_W * app.scale), cint(GB_H * app.scale))
    app.dbg = nil
    app.gb_dbg = new_gb_debug(app.gb_emu)
  else:
    app.gba_emu = built.gba
    input_log_start(rom_path)
    app.gb_emu = nil
    app.emu_kind = ekGBA
    app.border_shown = false
    setSize(app.window, cint(GBA_W * app.scale), cint(GBA_H * app.scale))
    app.dbg = new_gba_debug(app.gba_emu)
    app.gb_dbg = nil
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
  app.cur_path = path
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
  # An open Save States window re-reads the new game's slots before its Save,
  # Load or Delete act on them (mark_stale also drops the old game's notice)
  app.save_states.mark_stale()
  new_core_takes_held_input()

proc reset_game() =
  ## Restart the running game: the file it was loaded from, whatever became
  ## of the Recent list since.
  if app.cur_path.len > 0: load_rom(app.cur_path)

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
  rp.changeFileExt(".cht")

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
      write_file_atomic(path, eng.serialize())
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

proc states_dir(): string = config_dir() / "states"

proc state_identity(): uint32 =
  case app.emu_kind
  of ekGBA: app.gba_emu.state_rom_identity()
  of ekGB:  app.gb_emu.state_rom_identity()
  of ekNone: 0'u32

proc state_is_ours(data: string): bool =
  ## An older build's slot file (named by the ROM file name alone) belongs
  ## to this game only if its header says so.
  case app.emu_kind
  of ekGBA: app.gba_emu.state_is_for(data)
  of ekGB:  app.gb_emu.state_is_for(data)
  of ekNone: false

proc state_file_path(slot = 0): string =
  ## Where a slot is written: named by the ROM's file name and identity
  ## (persist.nim), so same-named games keep their own slots. Slot 0 is the
  ## Quick slot.
  let rom = current_rom_path()
  if rom.len == 0: return ""
  states_dir() / state_file_name(rom, state_identity(), slot)

proc state_slot_read_path(slot = 0): string =
  ## Where a slot is read from: its own file, else an older build's for this
  ## game (read only; the next Save writes the new name).
  let rom = current_rom_path()
  if rom.len == 0: return ""
  state_read_path(states_dir(), rom, state_identity(), slot, state_is_ours)

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
  # A linked core's state is half of a two-player session: loading one would
  # put the two games out of step. Refused here, whoever asks (menu, hotkey,
  # the Save States window), so no caller can miss it.
  if app.netlink != nil:
    last_state_error = ""
    return false
  let path = state_slot_read_path(slot)
  if path.len == 0: return false
  result = case app.emu_kind
    of ekGBA: app.gba_emu.load_state(path)
    of ekGB:  app.gb_emu.load_state(path)
    of ekNone: false
  if result:
    echo "State loaded: ", path
    input_log_event("state_load")
    # The ring holds the timeline the load just replaced; rewinding into it
    # would step back through frames that never led here (the web drops it
    # the same way).
    app.rewind.clear()

proc state_reject_sentence(): string =
  ## One sentence per StateRejectKind, saying what to do about it; never raw
  ## exception text, never two causes on one message.
  if app.netlink != nil:
    return "Save states can't be loaded while the link cable is connected. " &
           "Disconnect first."
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
    # The common one: Quick Load before any Quick Save. Not "damaged".
    "There's no save state in that slot yet."
  of srkNone:
    "That save state couldn't be loaded."

proc delete_state_slot(slot: int) =
  let rom = current_rom_path()
  if rom.len == 0: return
  for path in state_delete_paths(states_dir(), rom, state_identity(), slot,
                                 state_is_ours):
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
    let path = state_slot_read_path(i)
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
    if not save_state_slot(0):
      # The write goes to a temp file first, so the slot is as it was.
      app.state_notice = QUICK_SAVE_FAILED
      app.state_notice_hint = last_state_error
    # An open Save States window is showing slot 1 stale now — refresh it
    app.save_states.mark_stale()
  if app.pending_load:
    app.pending_load = false
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
    let mixed = [(  0.0 * b +  50.0 * g + 240.0 * r) / 255.0,
                 ( 30.0 * b + 230.0 * g +  10.0 * r) / 255.0,
                 (220.0 * b +  10.0 * g +  50.0 * r) / 255.0]
    for i in 0 .. 2:
      result[i] = byte(min(255.0, round(pow(mixed[i], 1.0 / 2.2) * 255.0)))
  else:
    result[0] = byte(round(r5 * 255.0))
    result[1] = byte(round(g5 * 255.0))
    result[2] = byte(round(b5 * 255.0))

proc save_screenshot() =
  ## Write the current frame to config_dir/screenshots/<rom>-<timestamp>.png,
  ## colour-corrected when the setting is on so it matches the screen.
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
    # does NOT get the LCD colour-correction curve.
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
  # Speed mode suspends the panel model — per-pixel CPU work every frame
  # The GBA color-correction shader linearizes with lcdGamma 4.0, so while it
  # is on, the AGB table must be built for that chain (see set_panel).
  lcd_resp.set_panel((app.cfg.lcd_response and not app.cfg.speed_mode).resolve(
    gba = app.emu_kind == ekGBA,
    cgb = gb and app.gb_emu.cgb_enabled,
    sgb = gb and app.gb_emu.sgb_active()),
    display_gamma = if app.emu_kind == ekGBA and app.cfg.color_correction: 4.0
                    else: 0.0)
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
        of 1: app.cfg.video_filter = vfNone
        of 2: app.cfg.video_filter = vfHq4x
        of 3: app.cfg.video_filter = vfXbr
        of 4: app.cfg.video_filter = vfGrid
        of 5: app.cfg.video_filter = vfSubpixel
        of 6: app.cfg.video_filter = vfNone;   app.cfg.color_correction = false
        of 7: app.cfg.color_correction = true; app.cfg.lcd_response = true
        of 8: app.cfg.lcd_response = false
        else: echo "GPUTIME sweep done"; app.running = false

proc render_game() =
  if app.emu_kind != ekNone:
    glUseProgram(app.game_shader)
    glBindTexture(GL_TEXTURE_2D, app.game_texture)
    # Pushed every present: the Settings window's Apply has no callback into
    # this module, so a cached value could go stale. The grid and subpixel
    # looks are separate shader stages; filter_mode only carries the
    # smoothing algorithms. Speed mode suspends the whole selector.
    let vf = if app.cfg.speed_mode: vfNone else: app.cfg.video_filter
    glUniform1i(glGetUniformLocation(app.game_shader, "lcd_grid"),
                GLint(if vf == vfGrid: 1 else: 0))
    glUniform1i(glGetUniformLocation(app.game_shader, "subpixel"),
                GLint(if vf == vfSubpixel: 1 else: 0))
    glUniform1i(glGetUniformLocation(app.game_shader, "filter_mode"),
                GLint(if vf in {vfHq4x, vfXbr}: ord(vf) else: 0))
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
    glUniform1f(glGetUniformLocation(app.game_shader, "scan_width"),
                GLfloat(GBA_W))
    # The panel model must be fed static frames too, or a cell still on its
    # way to its target would freeze part-settled instead of finishing
    if (app.cfg.lcd_response and not app.cfg.speed_mode) or
       not app.gba_emu.ppu.frame_static:
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
    glUniform1f(glGetUniformLocation(app.game_shader, "scan_width"),
                if border: GLfloat(SGB_BORDER_W) else: GLfloat(GB_W))
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
      # ±1 px viewport jitter, alternating per present; restored right after
      # the draw so ImGui renders unshaken.
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
  var focused    = getMouseFocus() == app.window
  when defined(gui_driver):
    focused = focused or gui_driver.mouse_in
  let mouse_idle = getTicks() - app.last_mouse_tick > 3000'u32
  result = focused and not mouse_idle
  discard showCursor(result)

proc render_link_window()  # defined below, near the network-link procs

proc poll_battery_notice() =
  ## Once per loop iteration: the running core's battery-write failures into
  ## `app.battery` (the first of a run opens the notice; a write that lands
  ## takes it down).
  var none = false
  case app.emu_kind
  of ekGBA:
    if app.gba_emu != nil:
      let st = app.gba_emu.storage
      app.battery.poll(st.save_path, st.save_error, st.save_error_new)
  of ekGB:
    if app.gb_emu != nil:
      let cart = app.gb_emu.cartridge
      app.battery.poll(cart.sav_path, cart.save_error, cart.save_error_new)
  of ekNone: app.battery.poll("", "", none)

proc render_state_notice() =
  ## What the app says when a save state is refused (a silent refusal reads
  ## as "nothing happened"). Modal on purpose: it is always the direct result
  ## of something the user just did, so it never appears unbidden.
  render_notice("State##notice", app.state_notice, app.state_notice_hint)

proc render_load_notice() =
  ## A ROM that could not be loaded. After the other notices, never over one:
  ## two modals opened at the same level replace each other every frame.
  if app.state_notice.len > 0 or app.cfg.notice.len > 0: return
  render_notice("Open ROM##notice", app.load_notice, app.load_notice_hint)

proc render_config_notice() =
  ## The settings file was moved aside or could not be written (config.nim
  ## reports each cause once). Shown after the state notice, never over it.
  if app.state_notice.len > 0: return
  var no_hint = ""
  render_notice("Settings##notice", app.cfg.notice, no_hint)

proc render_battery_notice() =
  ## The running game's battery save can't be written (persist.nim
  ## BatteryNotice: once per run of failures, down when a write lands).
  ## Unbidden, so it waits for the other notices.
  if app.state_notice.len > 0 or app.cfg.notice.len > 0 or
     app.load_notice.len > 0: return
  render_notice("Save file##battery", app.battery.text, app.battery.hint)

var imgui_skipped = false  # the last render_imgui returned before igNewFrame

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
     # The menu bar hides after three idle seconds, exactly the state a Quick
     # Load keypress lands in; the notice must still be drawn then.
     app.state_notice.len == 0 and app.cfg.notice.len == 0 and
     app.load_notice.len == 0 and app.battery.text.len == 0:
    # Only igNewFrame drains ImGui's input queue, a few events a frame, so
    # every key event of a long keyboard-only session would wait there and
    # the menu would take that long to see a click. Drop the backlog, and
    # start the UI from nothing held (a release may be among what is dropped).
    if app.io != nil:
      if not imgui_skipped:
        ImGuiIO_ClearInputKeys(app.io)
        ImGuiIO_ClearInputMouse(app.io)
      ImGuiIO_ClearEventsQueue(app.io)
    imgui_skipped = true
    return
  imgui_skipped = false

  ImGui_Impl_OpenGL3_NewFrame()
  ImGui_ImplSDL2_NewFrame()
  igNewFrame()

  var overlay_h: cfloat = 10.0
  var open_rom = false

  if menu_visible:
    if igBeginMainMenuBar():
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
                           nil, false, game_loaded and app.netlink == nil):
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

      if igBeginMenu("Emulation", true):
        var should_reset = false
        discard igMenuItem_BoolPtr(cstring("Reset  " & MOD_KEY_STR & "+R"),
                                   nil, addr should_reset, true)
        discard igMenuItem_BoolPtr(cstring("Pause  " & MOD_KEY_STR & "+P"),
                                   nil, addr app.paused, true)
        # Frame advance, 2x and fast forward can't run ahead of a linked
        # peer (it paces both), so they are off while linked, like Tab.
        let unlinked = app.netlink == nil
        if igMenuItem_Bool(cstring("Frame Advance  " & MOD_KEY_STR & "+N"),
                           nil, false, app.paused and app.emu_kind != ekNone and
                           unlinked):
          app.pending_step = true
        if igMenuItem_BoolPtr("Rewind (hold `)", nil, addr app.cfg.rewind,
                              not app.cfg.speed_mode):
          if not app.cfg.rewind:
            app.rewind.clear()  # free the history when disabled
          save_config(app.cfg)
        # Speed mode: GBA frameskip + 2x emulated-CPU underclock, GB scanline
        # renderer at next load, rewind suspended.
        if igMenuItem_BoolPtr("Speed mode (less accurate)", nil,
                              addr app.cfg.speed_mode, true):
          if app.cfg.speed_mode:
            app.rewind.clear()  # suspended while on; history would go stale
          apply_speed_mode()
          save_config(app.cfg)
        # The GB renderer swap waits for a load; say so where it is chosen
        if app.emu_kind == ekGB:
          igSetItemTooltip("On a Game Boy game this takes effect at the next " &
                           "load or Reset.")
        # 2x Speed stays audio-paced (at double rate); Fast Forward is
        # inverted audio sync — unsynced emulation runs uncapped, so
        # checked == not sync. Radio-style: fast forward would silently
        # dominate 2x, so enabling either clears the other.
        if app.emu_kind == ekGBA and app.gba_emu != nil:
          if igMenuItem_BoolPtr("2x Speed", "Shift+Tab",
                                addr app.gba_emu.apu.turbo, unlinked):
            if app.gba_emu.apu.turbo: app.gba_emu.apu.sync = true
          var fast_forward = not app.gba_emu.apu.sync
          if igMenuItem_BoolPtr("Fast Forward", "Tab",
                                addr fast_forward, unlinked):
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
        if should_reset: reset_game()
        igSeparator()
        # Cheats live here, not under Debug: a first-class feature, next to
        # the other things that change a running game.
        discard igMenuItem_BoolPtr("Cheats", nil, addr app.cheats.window,
                                   app.emu_kind != ekNone)
        if igMenuItem_Bool("Link Cable...", nil, app.link_window,
                           app.emu_kind == ekGBA):
          app.link_window = not app.link_window
        igEndMenu()

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
        # WSOLA time-stretch keeps 2x audio at normal pitch. The audio
        # niceties below (and Rewind above) gray out while speed mode is on:
        # a live-looking control that does nothing is worse than a disabled one.
        if igMenuItem_BoolPtr("Pitch-correct fast-forward", nil,
                              addr app.cfg.pitch_correct_ff,
                              not app.cfg.speed_mode):
          apply_pitch_correct_ff()
          save_config(app.cfg)
        # ON: reconstructs the waveform between FIFO samples. OFF: bit-true
        # GBA DAC output, grit included.
        if igMenuItem_BoolPtr("Audio interpolation", nil,
                              addr app.cfg.fifo_interp,
                              app.emu_kind == ekGBA and not app.cfg.speed_mode):
          apply_fifo_interp()
          save_config(app.cfg)
        # Pair with interpolation off for the closest real-hardware sound.
        if igMenuItem_BoolPtr("Analog filter", nil,
                              addr app.cfg.audio_lowpass,
                              app.emu_kind == ekGBA and not app.cfg.speed_mode):
          apply_audio_lowpass()
          save_config(app.cfg)
        # Sound-engine HLE: changes the mix character and supersedes
        # interpolation for the music stream when engaged (per-game detection).
        if igMenuItem_BoolPtr("Enhanced music synthesis (HLE)", nil,
                              addr app.cfg.mp2k_hle, not app.cfg.speed_mode):
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
              app.cfg.frame_size = s
              if app.emu_kind != ekNone: resize_to_output()
              save_config(app.cfg)
          igSeparator()
          if igMenuItem_Bool(cstring("Fullscreen  " & MOD_KEY_STR & "+F"),
                             nil, app.fullscreen, true):
            set_fullscreen(not app.fullscreen)
          igEndMenu()
        igEndMenu()

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

  app.fe.render("ROM", open_rom, ROM_DIALOG_EXTS, proc(path: string) =
    load_rom(path))

  render_state_notice()
  render_config_notice()
  render_load_notice()
  render_battery_notice()

  app.ce.render()

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
  # load_state_slot refuses while linked; the window says so up front.
  app.save_states.load_blocked =
    if app.netlink != nil: "Loading is paused while linked." else: ""
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

# Left-stick-as-dpad and right-trigger fast-forward thresholds (hardcoded,
# not part of the rebindable button table)
const STICK_DEADZONE     = 8000'i16
const TRIGGER_THRESHOLD  = 8000'i16

# What the keyboard, each pad and each pad's stick hold, merged for the core
# (frontend/held_input.nim)
var held: HeldInput

proc emu_pad_input(inp: Input; pressed: bool) =
  case app.emu_kind
  of ekGBA:
    if app.gba_emu != nil: app.gba_emu.handle_input(inp, pressed)
  of ekGB:
    if app.gb_emu != nil: app.gb_emu.handle_input(inp, pressed)
  of ekNone: discard

proc push_held_input() =
  ## Tell the core what changed in the merged held state
  let (pressed, released) = held.take_changes()
  for inp in released: emu_pad_input(inp, false)
  for inp in pressed: emu_pad_input(inp, true)

proc apply_trigger() =
  ## The right trigger's fast forward, onto the running core's speed toggles
  template onto(apu: untyped) =
    var speed = Speed(sync: apu.sync, turbo: apu.turbo)
    held.apply_trigger(speed, linked = app.netlink != nil)
    apu.sync = speed.sync
    apu.turbo = speed.turbo
  case app.emu_kind
  of ekGBA:
    if app.gba_emu != nil: onto(app.gba_emu.apu)
  of ekGB:
    if app.gb_emu != nil: onto(app.gb_emu.apu)
  of ekNone: discard

proc new_core_takes_held_input() =
  ## A fresh core holds nothing: press what the player still holds, and
  ## fast-forward again under a trigger still pulled
  held.core_replaced()
  push_held_input()
  apply_trigger()

proc update_rumble() =
  ## 80 ms effects re-triggered every 50 ms chain into a continuous buzz
  ## while the motor stays on; stopping explicitly on the off edge keeps
  ## short pulses crisp.
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

proc open_dropped(path: string) =
  ## A file dropped on the window: a ROM or a zip loads, anything else is ignored
  if is_rom_file(path):
    load_rom(path)

proc handle_input() =
  when defined(gui_driver):
    # A pushed drop event cannot carry its path through SDL's own event
    # memory, so the driver hands it over here, where SDL's would arrive.
    if gui_driver.dropped.len > 0:
      let path = gui_driver.dropped
      gui_driver.dropped = ""
      open_dropped(path)
  var evt = defaultEvent
  while pollEvent(evt):
    discard ImGui_ImplSDL2_ProcessEvent(cast[ptr SDL_Event](addr evt))

    case evt.kind
    of KeyDown, KeyUp:
      let pressed = evt.kind == KeyDown
      let kev     = key(evt)
      let sym     = kev.keysym.sym
      let mods    = kev.keysym.modstate

      # Releases are applied before any of these filters (held_input.nim)
      let route = held.route_key(app.cfg.keybindings, sym, pressed, kev.repeat,
                                 shortcut_mod = (mods and MOD_KEY_MASK) != 0,
                                 imgui_keyboard = app.io != nil and
                                                  app.io[].WantCaptureKeyboard,
                                 capturing = app.ce.capturing_keys())
      push_held_input()
      case route
      of krNone: discard
      of krCapture:
        app.ce.keybindings.key_released(sym)
      of krShortcut:
        case sym
        of K_r:
          reset_game()
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
          set_fullscreen(not app.fullscreen)
        of K_q:
          app.running = false
        else: discard
      of krMark:
        # playtest recording: mark this screen as a checkpoint
        input_log_mark()
      of krScreenshot:
        # Screenshot to config_dir/screenshots
        save_screenshot()
      of krRewind:
        # Hold-to-rewind, core-agnostic (disabled while linked — it desyncs)
        app.rewinding = pressed and app.cfg.rewind and
                        app.emu_kind != ekNone and app.netlink == nil
      of krFastForward:
        # Shift+Tab = 2x, Tab = unbounded; mutually exclusive, since fast
        # forward would silently dominate 2x
        template toggle(apu: untyped) =
          if (mods and KMOD_SHIFT_MASK) != 0:
            apu.turbo = not apu.turbo
            if apu.turbo: apu.sync = true
          else:
            apu.sync = not apu.sync
            if not apu.sync: apu.turbo = false
        # Suppressed while linked (would run ahead of the peer)
        if app.emu_kind == ekGBA and app.gba_emu != nil and app.netlink == nil:
          toggle(app.gba_emu.apu)
        elif app.emu_kind == ekGB and app.gb_emu != nil:
          toggle(app.gb_emu.apu)
      of krChannel:
        # Feedback is visible in the Audio/Video > Channels submenu
        let ch = int(sym) - int(K_1)
        if app.emu_kind == ekGBA and app.gba_emu != nil:
          app.gba_emu.apu.channel_mask[ch] = not app.gba_emu.apu.channel_mask[ch]
        elif app.emu_kind == ekGB and app.gb_emu != nil and ch < 4:
          app.gb_emu.apu.channel_mask[ch] = not app.gb_emu.apu.channel_mask[ch]

    of ControllerDeviceAdded:
      # `which` is a device index for the Added event
      let idx = cdevice(evt).which
      if isGameController(cint(idx)):
        let pad = gameControllerOpen(cint(idx))
        if pad != nil:
          let id = pad.getJoystick().instanceID()
          controllers[id] = pad
          held.pad_added(id)

    of ControllerDeviceRemoved:
      # `which` is a joystick instance id for the Removed event
      let id = cdevice(evt).which
      if controllers.hasKey(id):
        controllers[id].close()
        controllers.del(id)
      # Unplugged mid-press: let go of what this pad held, and only that
      held.pad_removed(id)
      push_held_input()
      apply_trigger()

    of ControllerButtonDown, ControllerButtonUp:
      let pressed = evt.kind == ControllerButtonDown
      let button  = cint(cbutton(evt).button)
      let bound   = app.cfg.controller_bindings.hasKey(button)
      held.pad_button(cbutton(evt).which, button, bound,
                      if bound: app.cfg.controller_bindings[button] else: Input.low,
                      pressed)
      push_held_input()
      if not pressed and app.ce.capturing_buttons():
        app.ce.controller.button_released(button)

    of ControllerAxisMotion:
      let ax = caxis(evt)
      if ax.axis == uint8(SDL_CONTROLLER_AXIS_LEFTX):
        held.pad_stick(ax.which, Input.LEFT,  ax.value < -STICK_DEADZONE)
        held.pad_stick(ax.which, Input.RIGHT, ax.value > STICK_DEADZONE)
      elif ax.axis == uint8(SDL_CONTROLLER_AXIS_LEFTY):
        held.pad_stick(ax.which, Input.UP,   ax.value < -STICK_DEADZONE)
        held.pad_stick(ax.which, Input.DOWN, ax.value > STICK_DEADZONE)
      elif ax.axis == uint8(SDL_CONTROLLER_AXIS_TRIGGERRIGHT):
        held.pad_trigger(ax.which, ax.value > TRIGGER_THRESHOLD)
      push_held_input()
      apply_trigger()

    of WindowEvent:
      let wev = window(evt)
      if wev.event == WindowEvent_SizeChanged:
        var w, h: cint
        getSize(app.window, w, h)
        glViewport(0, 0, w, h)
        # Every fullscreen change resizes; SDL 2 on macOS sends it once the
        # transition is over, when the window is where it will stay
        track_fullscreen()

    of MouseMotion:
      app.last_mouse_tick = motion(evt).timestamp

    of DropFile:
      let dropped = drop(evt)
      let path = $dropped.file
      sdl_free(dropped.file)
      open_dropped(path)

    of QuitEvent:
      app.running = false

    else: discard

# ──────────────────────────── FPS Title ────────────────────────────

var fps_frames    = 0
var fps_us        = 0'i64
var fps_last_time = getTime()
var fps_second    = getTime().toUnix() mod 60

proc update_fps_title(emulated: bool) =
  # Count emulated frames only: the main loop iterates at the display's
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

proc gl_loader(name: cstring): pointer = glGetProcAddress(name)

# ──────────────────────────── Network link ────────────────────────────

const LINK_FRAME_BUDGET_MS = 8
  ## How long one iteration's linked frame may wait on the peer before the
  ## loop takes input and draws again (half a 60 Hz frame).

proc link_ready(): bool =
  app.emu_kind == ekGBA and app.gba_emu != nil

proc teardown_netlink(why = "") =
  ## Drop the network link and return the local GBA to single-player: send the
  ## peer a BYE, drain/close the socket, and swap the RemoteSioDriver back for
  ## the default no-cable driver so the game sees the cable unplug cleanly.
  ## `why` (empty for the user's own Disconnect) is shown as "Link ended: ...".
  ## A core the link left inside a frame (parked on the peer, or step_frame
  ## raised part way) finishes that frame single-player: link_mid_frame no
  ## longer holds a Quick Save/Load back once the link is gone, and the state
  ## format assumes a frame boundary.
  let torn = app.netlink != nil and app.netlink.mid_frame
  app.link.teardown(app.netlink, why)
  if torn and app.gba_emu != nil:
    app.gba_emu.run_until_frame()

proc linked_now(nl: NetLink): bool =
  ## Bind a new link to the app; drops rewind history, which would desync.
  if nl == nil: return false
  app.netlink = nl
  app.rewind.clear()
  app.rewinding = false
  true

proc establish_netlink(listen_port: int; connect_to: string; delay_ms: int) =
  ## `--listen PORT` hosts (unit 0) and `--connect HOST:PORT` joins (unit 1)
  ## the way the Link Cable window's Advanced Host and Join do, with the
  ## window open on the status: the loop services the wait
  ## (service_link_setup), so the game runs single-player and the window
  ## answers until a peer pairs, and Cancel or closing the window ends it.
  app.link.delay_ms = delay_ms
  if app.link.start_cli(listen_port, connect_to, link_ready()):
    app.link_window = true

proc link_cancel_setup() = app.link.cancel_setup()

proc link_auto_stop() = app.link.auto_stop()

proc service_link_setup() =
  ## Per iteration: poll the pending accept/connect so the UI never blocks
  ## while waiting for a peer; a paired socket becomes app.netlink.
  if app.netlink != nil: return
  let gba = if link_ready(): app.gba_emu else: nil
  discard linked_now(app.link.service_setup(gba, current_rom_path(),
                                            link_now_ms()))

proc service_netlink() =
  ## Phase 1 while linked and not emulating a frame (paused): keep the socket
  ## read so the peer's BYE or loss is seen, and our pause reaches it (CLOCK's
  ## paused bit: its stall clock stops, the link stays up).
  if app.netlink == nil: return
  try:
    app.netlink.set_paused(app.paused)
    if app.paused: app.netlink.idle()
  except NetLinkError as e:
    echo "NETLINK: link lost: ", e.msg, " — continuing single-player"
    teardown_netlink(e.msg)
    return
  if app.netlink.peer_done:
    echo "NETLINK: peer disconnected — continuing single-player"
    teardown_netlink("the other player disconnected")

proc link_mid_frame(): bool =
  ## The linked core stopped inside a frame, parked on the peer: states wait.
  app.netlink != nil and app.netlink.mid_frame

proc render_link_advanced() =
  ## Manual Host/Join behind a collapsed "Advanced" header; either button
  ## first cancels auto-pairing.
  if igCollapsingHeader_TreeNodeFlags("Advanced", 0):
    igSetNextItemWidth(120)
    discard igInputInt("Port", addr app.link.port, 1, 100, 0)
    igSeparator()
    igText("Host — share your address + port with a friend:")
    if igButton("Host game", ImVec2(x: 0, y: 0)):
      link_auto_stop(); link_cancel_setup(); app.link.start_host(link_ready())
    igSeparator()
    igText("Join — enter the host's address:")
    igSetNextItemWidth(200)
    discard igInputTextWithHint("##link_host", "127.0.0.1",
      cast[cstring](addr app.link.host_buf[0]), csize_t(app.link.host_buf.len),
      0, nil, nil)
    igSameLine(0, -1)
    if igButton("Join game", ImVec2(x: 0, y: 0)):
      link_auto_stop(); link_cancel_setup(); app.link.start_join(link_ready())

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
      igText("%s", cstring(app.link.status))
      if app.netlink.peer_paused:
        igText("The other player has paused.")
      elif app.netlink.stalled:
        igText("Waiting for the other player...")
      igText("Rewind, turbo and save-state load are paused while linked.")
      if igButton("Disconnect", ImVec2(x: 0, y: 0)):
        teardown_netlink()
    elif not link_ready():
      igText("Load a GBA ROM, then reopen this window to link.")
    else:
      if app.link.auto:
        # An animated ellipsis so it's visibly working; auto stops on close.
        let dots = 1 + (int(getTicks() div 400) mod 3)
        igText("Waiting to pair%s", cstring(repeat('.', dots)))
        # load_rom refuses a ROM file another window has open (game_lock.nim)
        igTextWrapped("%s", cstring(LINK_SAME_MACHINE_HINT))
      elif app.link.setup == lsListening:
        igText("Hosting on port %d", cint(app.link.port))
        igText("Waiting for a friend to join...")
        igText("They pick Join and enter  your-ip : %d", cint(app.link.port))
        if igButton("Cancel", ImVec2(x: 0, y: 0)): link_cancel_setup()
      elif app.link.setup == lsConnecting:
        igText("Connecting to %s:%d ...",
               cstring(app.link.join_host()), cint(app.link.port))
        if igButton("Cancel", ImVec2(x: 0, y: 0)): link_cancel_setup()
      elif app.link.setup == lsHandshake:
        igText("Connected. Waiting for the other game to answer")
        igText("(up to %d s)...", cint(app.link.hello_timeout_ms div 1000))
        if igButton("Cancel", ImVec2(x: 0, y: 0)): link_cancel_setup()
      else:
        igText("Two players, one emulated link cable, over the network.")
      igSeparator()
      render_link_advanced()
    if app.link.status.len > 0 and app.netlink == nil:
      igSeparator()
      igText("%s", cstring(app.link.status))
  igEnd()

proc update_link_auto() =
  ## Opening the Link Cable window starts auto-pairing; closing it stops any
  ## pairing, auto or manual.
  app.link.update_auto(app.link_window, link_ready(), app.netlink != nil)

# ──────────────────────────── Main ────────────────────────────

proc main() =
  var rom_path     = ""
  var boot_ov: BootOverrides
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
      of "hle":            boot_ov.use_hle = true
      of "hle-after-bios": boot_ov.hle_after_bios = true
      of "run-bios":       boot_ov.run_bios = some(true)
      of "skip-bios":      boot_ov.run_bios = some(false)
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
        link_auto = true
      else: echo "Unknown option: --" & p.key; system.quit(1)
    of cmdArgument:
      pos_args.add(p.key)

  case pos_args.len
  of 0: discard
  of 1: rom_path  = pos_args[0]
  of 2: boot_ov.bios_path = pos_args[0]; rom_path = pos_args[1]
  else: echo "Too many arguments."; system.quit(1)

  # The command-line BIOS choices stay in app.boot_overrides (load_rom's
  # boot_settings applies them); written into cfg, the next save_config
  # would have made them permanent.
  let cfg = load_config()
  # Fullscreen at start only as the platform restores windows. When it does
  # not, the saved flag is cleared, as macOS discards a window's state at
  # quit, so turning the system setting on later brings back nothing stale.
  let start_fs = start_fullscreen(cfg.fullscreen, system_restores_windows())
  if cfg.fullscreen != start_fs:
    cfg.fullscreen = start_fs
    save_config(cfg)

  when defined(windows):
    # Per-monitor DPI awareness (SDL >= 2.24): render at native pixels
    # instead of letting DWM bitmap-stretch the window on scaled displays
    discard setHint("SDL_WINDOWS_DPI_AWARENESS", "permonitorv2")
  if sdl2.init(INIT_VIDEO or INIT_AUDIO or INIT_JOYSTICK or INIT_GAMECONTROLLER) != SdlSuccess:
    echo "SDL2 init failed: ", $sdl2.getError(); system.quit(1)
  defer: sdl2.quit()

  when defined(macosx):
    discard glSetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG)
  discard glSetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE)
  discard glSetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
  discard glSetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
  discard glSetAttribute(SDL_GL_DOUBLEBUFFER, 1)
  discard glSetAttribute(SDL_GL_DEPTH_SIZE, 24)
  discard glSetAttribute(SDL_GL_STENCIL_SIZE, 8)

  var window_flags = SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE
  when defined(gui_driver):
    driver_init()
    if driver_enabled(): window_flags = window_flags or SDL_WINDOW_HIDDEN
  let window = createWindow(
    "dingbat",
    SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
    cint(GBA_W * cfg.frame_size), cint(GBA_H * cfg.frame_size),
    window_flags or (if start_fs: SDL_WINDOW_FULLSCREEN_DESKTOP else: 0'u32)
  )
  if window == nil:
    echo "Failed to create window: ", $sdl2.getError(); system.quit(1)
  defer: destroyWindow(window)

  let gl_ctx = glCreateContext(window)
  if gl_ctx == nil:
    echo "Failed to create OpenGL context: ", $sdl2.getError(); system.quit(1)
  defer: glDeleteContext(gl_ctx)
  discard glSetSwapInterval(0)  # disable vsync

  if not gladLoadGL(gl_loader):
    echo "Failed to load OpenGL extensions"; system.quit(1)

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

  discard igCreateContext(nil)
  igStyleColorsDark(nil)
  let io_ptr = igGetIO_Nil()
  discard ImGui_ImplSDL2_InitForOpenGL(cast[ptr SDL_Window](window),
                                        cast[pointer](gl_ctx))
  discard ImGui_Impl_opengl3_Init("#version 330")

  let fe = new_file_explorer(cfg)
  let ce = new_config_editor(cfg, fe)
  # "Reset to Defaults" changes settings no widget owns (color correction,
  # volume, speed mode and the audio niceties, frame size) — push them into
  # the live GL uniform, core and window here.
  ce.live_sync = proc() =
    apply_color_correction()
    apply_master_volume()
    apply_speed_mode()  # also re-applies pitch, low-pass, interpolation, MP2K
    if app.scale != app.cfg.frame_size:
      app.scale = app.cfg.frame_size
      if app.emu_kind != ekNone: resize_to_output()

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
    scale:           (when defined(gputime): parseInt(getEnv("DINGBAT_SCALE", "3"))
                      else: cfg.frame_size),
    running:         true,
    paused:          false,
    fullscreen:      start_fs,
    enable_overlay:  false,
    last_mouse_tick: getTicks(),
    rewind:          new_rewind(),
    link:            init_link_cable(),
    boot_overrides:  boot_ov,
  )
  ce.bios.overrides = describe(boot_ov)
  # Save States widget: the app owns the files, textures and core, so the
  # widget just calls back. Save/Load run synchronously here — render_imgui is
  # always reached at a frame boundary (right after process_pending_state).
  app.save_states.on_open = proc() = refresh_state_slots()
  app.save_states.on_save = proc(slot: int) =
    if not save_state_slot(slot):
      app.save_states.notice = SLOT_SAVE_FAILED
  app.save_states.on_load = proc(slot: int) =
    if not load_state_slot(slot):
      # Same sentence-per-cause table as Quick Load; raw wording goes to the log.
      app.save_states.notice = state_reject_sentence()
      if last_state_error.len > 0:
        echo "Slot load refused: ", last_state_error
  app.save_states.on_delete = proc(slot: int) = delete_state_slot(slot)

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
      establish_netlink(listen_port, connect_to, netlink_delay)
    elif link_auto:
      # Opening the window is what update_link_auto's open-edge detection
      # keys on.
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
  # Normal play: fixed 16.743 ms wall-clock slot (280896 cycles / 16.777216
  # MHz; the GB frame is the same period); the audio queue is a bounds check
  # only. Turbo and fast-forward keep pure audio pacing.
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
    # Hysteresis: below `low`, burst until `target`. Stopping at `low` would
    # park the steady state on the threshold and the cadence would follow the
    # audio drain granularity instead of the wall clock.
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

  # DINGBAT_PACING_LOG=1: one line per second with emulated-frame counts and
  # audio queue depth bounds (qmin=0 would mean an underrun)
  let pacing_log = getEnv("DINGBAT_PACING_LOG").len > 0
  var pace_frames = 0
  var pace_total  = 0
  var pace_min_q  = uint32.high
  var pace_max_q  = 0'u32
  var pace_start  = 0'u32
  var pace_last   = 0'u32
  # DINGBAT_LATENCY_TEST=<trials>: inject a synthetic UP press where polled
  # SDL keys are applied and measure wall-clock time until (a) the framebuffer
  # first differs and (b) that frame reaches glSwapWindow. Needs a GBA ROM
  # that is static until a keypress and responds next frame (tonc m7_demo.gba:
  # UP moves the camera).
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
    when defined(gui_driver): driver_poll(window)
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
          input_log_event("rewind")
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
            # the two sides stay in lockstep. Parked on the peer, it hands
            # back after LINK_FRAME_BUDGET_MS so input and drawing go on (the
            # frame resumes next iteration). On the peer leaving or a link
            # error, tear the link down and keep running single-player.
            try:
              emulated = app.netlink.step_frame_for(LINK_FRAME_BUDGET_MS)
            except NetLinkError as e:
              echo "NETLINK: link lost: ", e.msg, " — continuing single-player"
              teardown_netlink(e.msg)
          else:
            input_log_frame_start()
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
    # Linked: the socket is read even while paused, and BYE ends the link.
    service_netlink()
    # Pending save/load states run here, at a guaranteed frame boundary (a
    # linked core parked on the peer mid-frame keeps them pending)
    if (app.pending_save or app.pending_load) and app.emu_kind != ekNone and
       not link_mid_frame():
      process_pending_state()
    poll_battery_notice()
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
    update_link_auto()
    service_link_setup()
    let now = getTicks()
    var presented = false
    # A paced frame is presented immediately: holding it for the next interval
    # slot would add up to a display period of input latency. The interval
    # throttle bounds present rate under turbo and keeps the UI refreshing
    # when nothing was emulated.
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
      when defined(gui_driver): driver_frame(window)
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
  # The peer hears BYE (a pulled cable) instead of waiting out its timeout
  link_auto_stop()
  link_cancel_setup()
  teardown_netlink()
  flush_saves()
  input_log_close()

main()
