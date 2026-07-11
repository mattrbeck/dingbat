import std/[os, hashes, parseopt, strformat, strutils, tables, times]
import sdl2 except init, quit, glBindTexture, glUnbindTexture
import sdl2/joystick
import sdl2/gamecontroller
import zippy/ziparchives
import imguin/[cimgui, impl_opengl, impl_sdl2]
import imguin/glad/gl
import stb_image/read as stbi
import dingbat/common/config
import dingbat/common/input
import dingbat/common/rewind
import dingbat/gba/gba
import dingbat/gb/gb
import dingbat/frontend/file_explorer
import dingbat/frontend/config_editor
import dingbat/frontend/keybindings_widget
import dingbat/frontend/controller_widget
import dingbat/frontend/gba_debug
import dingbat/frontend/gb_debug

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

const FRAG_SRC = """
#version 330 core
in vec2 tex_coord;
out vec4 frag_color;
uniform sampler2D input_texture;
uniform bool color_correct;
void main() {
  vec4 color = texture(input_texture, tex_coord);
  if (color_correct) {
    float lcdGamma = 4.0, outGamma = 2.2;
    color.rgb = pow(color.rgb, vec3(lcdGamma));
    frag_color.rgb = pow(vec3(
      0.0 * color.b +  50.0 * color.g + 255.0 * color.r,
     30.0 * color.b + 230.0 * color.g +  10.0 * color.r,
    220.0 * color.b +  10.0 * color.g +  50.0 * color.r) / 255.0,
      vec3(1.0 / outGamma));
  } else {
    frag_color.rgb = color.rgb;
  }
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

proc setup_vao() =
  var vao: GLuint
  glGenVertexArrays(1, addr vao)
  glBindVertexArray(vao)

# ──────────────────────────── App State ────────────────────────────

type EmuKind = enum ekNone, ekGBA, ekGB

type AppState = ref object
  cfg:             Config
  gba_emu:         GBA
  gb_emu:          GB
  emu_kind:        EmuKind
  window:          WindowPtr
  gl_ctx:          GlContextPtr
  io:              ptr ImGuiIO
  game_texture:    GLuint
  logo_texture:    GLuint
  canvas_aspect:   float32
  logo_shader:     GLuint
  game_shader:     GLuint
  fe:              FileExplorer
  ce:              ConfigEditor
  dbg:             GbaDebug
  gb_dbg:          GbDebug
  scale:           int
  running:         bool
  paused:          bool
  # Save states execute only at frame boundaries: the menu/hotkey sets a
  # pending flag and the main loop services it right after run_until_frame
  pending_save:    bool
  pending_load:    bool
  pending_step:    bool  # frame advance: run exactly one frame while paused
  rewind:          Rewind
  rewinding:       bool    # true while the rewind key is held
  last_rewind_pop: uint32
  fullscreen:      bool
  enable_overlay:  bool
  last_mouse_tick: uint32

var app: AppState

# Emulated-frames FPS, updated once a second by update_fps_title and shown in
# the debug overlay alongside the ImGui (UI) framerate
var emu_fps = 0.0

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

proc apply_master_volume() =
  if app.gba_emu != nil:
    app.gba_emu.apu.set_master_volume(app.cfg.volume, app.cfg.mute)
  if app.gb_emu != nil:
    app.gb_emu.apu.set_master_volume(app.cfg.volume, app.cfg.mute)

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
    app.gb_emu = new_gb(app.cfg.gb_bootrom_path, rom_path, app.cfg.gb_fifo,
                        app.cfg.headless, app.cfg.run_bios)
    app.gb_emu.post_init()
    app.gba_emu = nil
    app.emu_kind = ekGB
    setSize(app.window, cint(GB_W * app.scale), cint(GB_H * app.scale))
    app.dbg = nil
    app.gb_dbg = new_gb_debug(app.gb_emu)
  else:
    let bios = app.cfg.bios_path
    app.gba_emu = new_gba(bios, rom_path, app.cfg.run_bios, app.cfg.use_hle, app.cfg.hle_after_bios)
    app.gba_emu.post_init()
    app.gb_emu = nil
    app.emu_kind = ekGBA
    setSize(app.window, cint(GBA_W * app.scale), cint(GBA_H * app.scale))
    app.dbg = new_gba_debug(app.gba_emu)
    app.gb_dbg = nil
  apply_master_volume()
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

proc state_file_path(): string =
  ## One slot per ROM for now; the state header reserves a slot byte so more
  ## slots can be added later
  let rom = current_rom_path()
  if rom.len == 0: return ""
  config_dir() / "states" / rom.extractFilename() & ".state"

proc process_pending_state() =
  ## Runs between frames only (right after run_until_frame returns, or while
  ## paused), so the core is always at a frame boundary here. Success/failure
  ## is echoed for now; the bool results are ready for a future toast/OSD.
  let path = state_file_path()
  if app.pending_save:
    app.pending_save = false
    if path.len > 0:
      let ok = case app.emu_kind
        of ekGBA: app.gba_emu.save_state(path)
        of ekGB:  app.gb_emu.save_state(path)
        of ekNone: false
      if ok: echo "State saved: ", path
  if app.pending_load:
    app.pending_load = false
    if path.len > 0:
      let ok = case app.emu_kind
        of ekGBA: app.gba_emu.load_state(path)
        of ekGB:  app.gb_emu.load_state(path)
        of ekNone: false
      if ok: echo "State loaded: ", path

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

proc render_game() =
  if app.emu_kind != ekNone:
    glUseProgram(app.game_shader)
    glBindTexture(GL_TEXTURE_2D, app.game_texture)
  case app.emu_kind
  of ekGBA:
    if app.gba_emu == nil: return
    if not app.gba_emu.ppu.frame_static:
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, GBA_W, GBA_H,
                      GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV,
                      addr app.gba_emu.ppu.framebuffer[0])
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
  of ekGB:
    if app.gb_emu == nil: return
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, GB_W, GB_H,
                    GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV,
                    addr app.gb_emu.ppu.framebuffer[0])
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
  of ekNone:
    render_logo()

proc show_menu_bar(): bool =
  if app.emu_kind == ekNone: return true
  let focused    = getMouseFocus() == app.window
  let mouse_idle = getTicks() - app.last_mouse_tick > 3000'u32
  result = focused and not mouse_idle
  discard showCursor(result)

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
     (app.gb_dbg == nil or not app.gb_dbg.any_window_open):
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
        if igMenuItem_Bool(cstring("Save State  " & MOD_KEY_STR & "+S"),
                           nil, false, game_loaded):
          app.pending_save = true
        if igMenuItem_Bool(cstring("Load State  " & MOD_KEY_STR & "+L"),
                           nil, false, game_loaded):
          app.pending_load = true
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
        igSeparator()
        if igMenuItem_BoolPtr("LCD Color Correction", nil,
                              addr app.cfg.color_correction, true):
          apply_color_correction()
          save_config(app.cfg)
        if igBeginMenu("Channels", app.emu_kind == ekGBA and app.gba_emu != nil):
          const ch_names = ["PSG1", "PSG2", "PSG3", "PSG4", "DMA-A", "DMA-B"]
          for ch in 0 .. 5:
            discard igMenuItem_BoolPtr(cstring(ch_names[ch]), cstring($(ch + 1)),
                                       addr app.gba_emu.apu.channel_mask[ch], true)
          igEndMenu()
        igSeparator()
        if igBeginMenu("Frame size", true):
          for s in 1 .. 8:
            if igMenuItem_Bool(cstring($s & "x"), nil, s == app.scale, true):
              app.scale = s
              case app.emu_kind
              of ekGBA: setSize(app.window, cint(GBA_W * s), cint(GBA_H * s))
              of ekGB:  setSize(app.window, cint(GB_W * s),  cint(GB_H * s))
              of ekNone: discard
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
        igText(if app.rewinding: "<< Rewinding" else: "Paused")
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
            if app.paused and app.emu_kind != ekNone: app.pending_step = true
          of K_s:
            if app.emu_kind != ekNone: app.pending_save = true
          of K_l:
            if app.emu_kind != ekNone: app.pending_load = true
          of K_f:
            app.fullscreen = not app.fullscreen
            let flags = if app.fullscreen: SDL_WINDOW_FULLSCREEN_DESKTOP else: 0'u32
            discard setFullscreen(app.window, flags)
          of K_q:
            app.running = false
          else: discard
      elif sym == K_BACKQUOTE:
        # Hold-to-rewind, core-agnostic
        app.rewinding = pressed and app.cfg.rewind and app.emu_kind != ekNone
      elif app.emu_kind == ekGBA and app.gba_emu != nil:
        if app.cfg.keybindings.hasKey(sym):
          app.gba_emu.handle_input(app.cfg.keybindings[sym], pressed)
        elif sym == K_TAB and pressed:
          # Shift+Tab = 2x speed, Tab = unbounded fast forward; the two are
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

# ──────────────────────────── Main ────────────────────────────

proc main() =
  var bios_path    = ""
  var rom_path     = ""
  var cli_run_bios = false
  var has_bios_arg = false
  var use_hle        = false
  var hle_after_bios = false
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

  app = AppState(
    cfg:             cfg,
    gba_emu:         nil,
    window:          window,
    gl_ctx:          gl_ctx,
    io:              io_ptr,
    game_texture:    game_tex,
    logo_texture:    logo_tex,
    canvas_aspect:   canvas_aspect,
    logo_shader:     logo_shader,
    game_shader:     game_shader,
    fe:              fe,
    ce:              ce,
    dbg:             nil,
    scale:           3,
    running:         true,
    paused:          false,
    fullscreen:      false,
    enable_overlay:  false,
    last_mouse_tick: getTicks(),
    rewind:          new_rewind(),
  )
  # GLSL uniforms default to 0/false, so push the configured value now
  apply_color_correction()

  if rom_path != "":
    if not fileExists(rom_path):
      echo "ROM file not found: ", rom_path; system.quit(1)
    load_rom(rom_path)

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
  let pacing_log = getEnv("DINGBAT_PACING_LOG").len > 0
  var pace_frames = 0
  var pace_total  = 0
  var pace_min_q  = uint32.high
  var pace_max_q  = 0'u32
  var pace_start  = 0'u32
  var pace_last   = 0'u32
  while app.running:
    var emulated = false
    # Frame advance bypasses the audio pacing gate: it must run exactly one
    # frame regardless of queue depth
    let stepping = app.paused and app.pending_step
    app.pending_step = false
    if app.rewinding and app.emu_kind != ekNone:
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
        if app.gba_emu != nil and (stepping or not app.gba_emu.apu.audio_ahead()):
          app.gba_emu.run_until_frame()
          emulated = true
      of ekGB:
        if app.gb_emu != nil and (stepping or not app.gb_emu.apu.audio_ahead()):
          app.gb_emu.run_until_frame()
          emulated = true
      of ekNone: discard
      if emulated and app.cfg.rewind:
        case app.emu_kind
        of ekGBA:
          discard app.rewind.maybe_push(proc(): string = app.gba_emu.state_payload())
        of ekGB:
          discard app.rewind.maybe_push(proc(): string = app.gb_emu.state_payload())
        of ekNone: discard
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
    let now = getTicks()
    var presented = false
    if now - last_present >= present_interval:
      last_present = now
      glClear(GL_COLOR_BUFFER_BIT)
      render_game()
      render_imgui()
      glSwapWindow(window)
      presented = true
    update_fps_title(emulated)
    if not emulated and not presented:
      # Idle until audio drains or the next present slot; don't busy-spin
      delay(1)
  flush_gb_save()

main()
