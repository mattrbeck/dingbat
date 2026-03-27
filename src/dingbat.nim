import std/[os, parseopt, strformat, strutils, tables, times]
import sdl2 except init, quit, glBindTexture, glUnbindTexture
import imguin/[cimgui, impl_opengl, impl_sdl2]
import imguin/glad/gl
import stb_image/read as stbi
import dingbat/common/config
import dingbat/gba/gba
import dingbat/gb/gb
import dingbat/frontend/file_explorer
import dingbat/frontend/config_editor
import dingbat/frontend/keybindings_widget
import dingbat/frontend/gba_debug

const VERSION = "0.1.0"
const GBA_W   = 240
const GBA_H   = 160
const GB_W    = 160
const GB_H    = 144

# Mod key mask for keyboard shortcuts (raw int16 from modstate)
when defined(macosx):
  const MOD_KEY_MASK = int16(0x0C00)  # LGUI | RGUI
  const MOD_KEY_STR  = "Cmd"
else:
  const MOD_KEY_MASK = int16(0x00C0)  # LCTRL | RCTRL
  const MOD_KEY_STR  = "Ctrl"

const LOGO_PNG_DATA = staticRead("../README/dingbat.png")

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
void main() {
  vec4 color = texture(input_texture, tex_coord);
  float lcdGamma = 4.0, outGamma = 2.2;
  color.rgb = pow(color.rgb, vec3(lcdGamma));
  frag_color.rgb = pow(vec3(
    0.0 * color.b +  50.0 * color.g + 255.0 * color.r,
   30.0 * color.b + 230.0 * color.g +  10.0 * color.r,
  220.0 * color.b +  10.0 * color.g +  50.0 * color.r) / 255.0,
    vec3(1.0 / outGamma));
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
  scale:           int
  running:         bool
  paused:          bool
  fullscreen:      bool
  enable_overlay:  bool
  last_mouse_tick: uint32

var app: AppState

# ──────────────────────────── ROM Loading ────────────────────────────

proc load_rom(path: string) =
  if not fileExists(path):
    echo "ROM not found: ", path; return
  let ext = path.splitFile().ext.toLowerAscii()
  if ext in [".gb", ".gbc"]:
    app.gb_emu = new_gb(app.cfg.gb_bootrom_path, path, app.cfg.gb_fifo,
                        app.cfg.headless, app.cfg.run_bios)
    app.gb_emu.post_init()
    app.gba_emu = nil
    app.emu_kind = ekGB
    setSize(app.window, cint(GB_W * app.scale), cint(GB_H * app.scale))
  else:
    let bios = app.cfg.bios_path
    app.gba_emu = new_gba(bios, path, app.cfg.run_bios, app.cfg.use_hle, app.cfg.hle_after_bios)
    app.gba_emu.post_init()
    app.gb_emu = nil
    app.emu_kind = ekGBA
    setSize(app.window, cint(GBA_W * app.scale), cint(GBA_H * app.scale))
    app.dbg = new_gba_debug(app.gba_emu)
  glDisable(GL_BLEND)
  glUseProgram(app.game_shader)
  glBindTexture(GL_TEXTURE_2D, app.game_texture)
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

# ──────────────────────────── Rendering ────────────────────────────

proc render_logo() =
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
  case app.emu_kind
  of ekGBA:
    if app.gba_emu == nil: return
    glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGB5), GBA_W, GBA_H, 0,
                 GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV,
                 addr app.gba_emu.ppu.framebuffer[0])
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
  of ekGB:
    if app.gb_emu == nil: return
    glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGB5), GB_W, GB_H, 0,
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
  ImGui_Impl_OpenGL3_NewFrame()
  ImGui_ImplSDL2_NewFrame()
  igNewFrame()

  var overlay_h: cfloat = 10.0
  var open_rom = false

  if show_menu_bar():
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
        if app.emu_kind == ekGBA and app.gba_emu != nil:
          discard igMenuItem_BoolPtr("Audio Sync", "Tab",
                                     addr app.gba_emu.apu.sync, true)
        if should_reset and app.cfg.recents.len > 0:
          load_rom(app.cfg.recents[0])
        igEndMenu()

      # Audio/Video menu
      if igBeginMenu("Audio/Video", true):
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
        igEndMenu()

      var win_size = ImVec2(x: 0, y: 0)
      igGetWindowSize(addr win_size)
      overlay_h += win_size.y
      igEndMainMenuBar()

  # File explorer
  app.fe.render("ROM", open_rom, ["gba", "gb", "gbc"], proc(path: string) =
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
      igText("FPS:        %.1f", fps)
      igText("Frame time: %.3f ms", 1000.0'f32 / fps)
      igSeparator()
      igText("OpenGL")
      let ver  = cast[cstring](glGetString(GL_VERSION))
      let shad = cast[cstring](glGetString(GL_SHADING_LANGUAGE_VERSION))
      igText("  Version: %s", ver)
      igText("  Shading: %s", shad)
    igEnd()

  if app.dbg != nil:
    app.dbg.render_windows()

  igRender()
  ImGui_Impl_OpenGL3_RenderDrawData(igGetDrawData())

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
          of K_f:
            app.fullscreen = not app.fullscreen
            let flags = if app.fullscreen: SDL_WINDOW_FULLSCREEN_DESKTOP else: 0'u32
            discard setFullscreen(app.window, flags)
          of K_q:
            app.running = false
          else: discard
      elif app.emu_kind == ekGBA and app.gba_emu != nil:
        if app.cfg.keybindings.hasKey(sym):
          app.gba_emu.handle_input(app.cfg.keybindings[sym], pressed)
        elif sym == K_TAB and pressed:
          app.gba_emu.apu.sync = not app.gba_emu.apu.sync
      elif app.emu_kind == ekGB and app.gb_emu != nil:
        if app.cfg.keybindings.hasKey(sym):
          app.gb_emu.handle_input(app.cfg.keybindings[sym], pressed)
        elif sym == K_TAB and pressed:
          app.gb_emu.apu.toggle_sync()

    of WindowEvent:
      let wev = window(evt)
      if wev.event == WindowEvent_SizeChanged:
        var w, h: cint
        getSize(app.window, w, h)
        glViewport(0, 0, w, h)

    of MouseMotion:
      app.last_mouse_tick = motion(evt).timestamp

    of QuitEvent:
      app.running = false

    else: discard

# ──────────────────────────── FPS Title ────────────────────────────

var fps_frames    = 0
var fps_us        = 0'i64
var fps_last_time = getTime()
var fps_second    = getTime().toUnix() mod 60

proc update_fps_title() =
  inc fps_frames
  let now = getTime()
  fps_us += (now - fps_last_time).inMicroseconds()
  fps_last_time = now
  let cur_sec = now.toUnix() mod 60
  if cur_sec != fps_second:
    let fps = if fps_us > 0: fps_frames.float * 1_000_000.0 / fps_us.float else: 0.0
    let title = if app.emu_kind == ekNone: "dingbat"
                elif app.paused: "dingbat - PAUSED"
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
  if has_bios_arg: cfg.bios_path = bios_path
  if cli_run_bios: cfg.run_bios = true

  # SDL2 init
  if sdl2.init(INIT_VIDEO or INIT_AUDIO or INIT_JOYSTICK) != SdlSuccess:
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
  )

  if rom_path != "":
    if not fileExists(rom_path):
      echo "ROM file not found: ", rom_path; system.quit(1)
    load_rom(rom_path)

  while app.running:
    if not app.paused:
      case app.emu_kind
      of ekGBA:
        if app.gba_emu != nil: app.gba_emu.run_until_frame()
      of ekGB:
        if app.gb_emu != nil: app.gb_emu.run_until_frame()
      of ekNone: discard
    handle_input()
    glClear(GL_COLOR_BUFFER_BIT)
    render_game()
    render_imgui()
    glSwapWindow(window)
    update_fps_title()

main()
