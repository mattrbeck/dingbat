## The OpenGL 3.3 core presenter (Windows, Linux, and macOS with
## DINGBAT_RENDERER=gl): presenter.nim's backend calls, one GL context on the
## SDL window. Textures take the core's BGR555 words as they are
## (GL_UNSIGNED_SHORT_1_5_5_5_REV).

import sdl3
import imguin/[cimgui, impl_opengl]
import imguin/glad/gl
import present_shader
import imgui_sdl3

var
  ctx: GLContext
  game_prog, logo_prog: GLuint
  game_tex, border_tex, logo_tex: GLuint
  loc: tuple[sgb_backdrop, dmg_pal, tex_width, tex_height, scan_width,
             scan_height, color_correct, panel_gbc, lcd_grid, subpixel,
             sgb_border, filter_mode, dmg_remap, aspect, scale: GLint]

proc gl_window_flags*(): uint64 =
  ## Before the window exists: the context it will get.
  when defined(macosx):
    discard glSetAttribute(GL_CONTEXT_FLAGS, GL_CONTEXT_FORWARD_COMPATIBLE_FLAG)
  discard glSetAttribute(GL_CONTEXT_PROFILE_MASK, GL_CONTEXT_PROFILE_CORE)
  discard glSetAttribute(GL_CONTEXT_MAJOR_VERSION, 3)
  discard glSetAttribute(GL_CONTEXT_MINOR_VERSION, 3)
  discard glSetAttribute(GL_DOUBLEBUFFER, 1)
  discard glSetAttribute(GL_DEPTH_SIZE, 24)
  discard glSetAttribute(GL_STENCIL_SIZE, 8)
  WINDOW_OPENGL

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
    sdl3.quit(); system.quit(1)

proc link_program(vert_src, frag_src: string): GLuint =
  let vert = compile_shader(vert_src, GL_VERTEX_SHADER)
  let frag = compile_shader(frag_src, GL_FRAGMENT_SHADER)
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
    sdl3.quit(); system.quit(1)
  glDeleteShader(vert)
  glDeleteShader(frag)

proc new_texture(unit: GLenum; filter: GLenum): GLuint =
  # Wrap stays at the default REPEAT: the quad's tex_coord.y is in [0, -1],
  # so every fetch is at a negative V. CLAMP_TO_EDGE pins the whole picture
  # to row 0 (vertical stripes).
  glGenTextures(1, addr result)
  glActiveTexture(unit)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(filter))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(filter))

proc gl_loader(name: cstring): pointer = cast[pointer](glGetProcAddress(name))

proc gl_init*(window: Window): bool =
  ctx = glCreateContext(window)
  if ctx == nil:
    echo "Failed to create OpenGL context: ", $getError(); return false
  discard glSetSwapInterval(0)  # disable vsync: main()'s scheduler paces
  if not gladLoadGL(gl_loader):
    echo "Failed to load OpenGL extensions"; return false
  game_tex = new_texture(GL_TEXTURE0, GL_NEAREST)
  # RGB5_A1 with 1_5_5_5_REV is the core's border format: BGR555 in bits 0-14,
  # opaque flag in bit 15.
  border_tex = new_texture(GL_TEXTURE1, GL_NEAREST)
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGB5_A1), GLsizei(256), GLsizei(224),
               0, GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV, nil)
  glActiveTexture(GL_TEXTURE0)
  var vao: GLuint
  glGenVertexArrays(1, addr vao)
  glBindVertexArray(vao)
  game_prog = link_program(GAME_VERT_GLSL, GAME_FRAG_GLSL)
  logo_prog = link_program(LOGO_VERT_GLSL, LOGO_FRAG_GLSL)
  template at(p: GLuint; name: string): GLint = glGetUniformLocation(p, name)
  loc = (at(game_prog, "u.sgb_backdrop"), at(game_prog, "u.dmg_pal"),
         at(game_prog, "u.tex_width"), at(game_prog, "u.tex_height"),
         at(game_prog, "u.scan_width"), at(game_prog, "u.scan_height"),
         at(game_prog, "u.color_correct"), at(game_prog, "u.panel_gbc"),
         at(game_prog, "u.lcd_grid"), at(game_prog, "u.subpixel"),
         at(game_prog, "u.sgb_border"), at(game_prog, "u.filter_mode"),
         at(game_prog, "u.dmg_remap"), at(logo_prog, "aspect"),
         at(logo_prog, "scale"))
  glUseProgram(game_prog)
  glUniform1i(at(game_prog, "input_texture"), 0)
  glUniform1i(at(game_prog, "border_texture"), 1)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  true

proc gl_shutdown*() =
  if ctx != nil: discard glDestroyContext(ctx)

proc gl_logo_upload*(px: pointer; w, h: int) =
  logo_tex = new_texture(GL_TEXTURE0, GL_NEAREST)
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), GLsizei(w), GLsizei(h), 0,
               GL_RGBA, GL_UNSIGNED_BYTE, px)

proc gl_game_alloc*(w, h: int) =
  ## Storage once per size; per-frame uploads use glTexSubImage2D
  ## (glTexImage2D each frame costs ~0.4 ms on macOS's GL-on-Metal).
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, game_tex)
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGB5), GLsizei(w), GLsizei(h), 0,
               GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV, nil)

proc gl_game_upload*(y0, w, h: int; px: pointer) =
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, game_tex)
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, GLint(y0), GLsizei(w), GLsizei(h),
                  GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV, px)

proc gl_border_upload*(px: pointer) =
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, border_tex)
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, GLsizei(256), GLsizei(224),
                  GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV, px)
  glActiveTexture(GL_TEXTURE0)

proc gl_begin*(pw, ph: int; r, g, b: float32) =
  glViewport(0, 0, GLsizei(pw), GLsizei(ph))
  glClearColor(r, g, b, 1.0'f32)
  glClear(GL_COLOR_BUFFER_BIT)

proc gl_draw_game*(x, y, w, h, pw, ph: int; look: Look) =
  ## Into (x, y, w, h), back-buffer pixels from the bottom left; the
  ## viewport goes back to the whole pw x ph window after.
  glDisable(GL_BLEND)
  glUseProgram(game_prog)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, border_tex)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, game_tex)
  glUniform3f(loc.sgb_backdrop, look.sgb_backdrop[0], look.sgb_backdrop[1],
              look.sgb_backdrop[2])
  var pal = look.dmg_pal
  glUniform3fv(loc.dmg_pal, 4, addr pal[0])
  glUniform1f(loc.tex_width, look.tex_width)
  glUniform1f(loc.tex_height, look.tex_height)
  glUniform1f(loc.scan_width, look.scan_width)
  glUniform1f(loc.scan_height, look.scan_height)
  glUniform1i(loc.color_correct, GLint(look.color_correct))
  glUniform1i(loc.panel_gbc, GLint(look.panel_gbc))
  glUniform1i(loc.lcd_grid, GLint(look.lcd_grid))
  glUniform1i(loc.subpixel, GLint(look.subpixel))
  glUniform1i(loc.sgb_border, GLint(look.sgb_border))
  glUniform1i(loc.filter_mode, GLint(look.filter_mode))
  glUniform1i(loc.dmg_remap, GLint(look.dmg_remap))
  glViewport(GLint(x), GLint(y), GLsizei(w), GLsizei(h))
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
  glViewport(0, 0, GLsizei(pw), GLsizei(ph))

proc gl_draw_logo*(aspect, scale: float32) =
  glEnable(GL_BLEND)
  glUseProgram(logo_prog)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, logo_tex)
  glUniform1f(loc.aspect, aspect)
  glUniform1f(loc.scale, scale)
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)

proc gl_read*(x, y, w, h: int): seq[byte] =
  ## The back buffer's (x, y, w, h) (from the bottom left) as RGB rows, top
  ## row first.
  var pix = newSeq[byte](w * h * 3)
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glReadPixels(GLint(x), GLint(y), GLsizei(w), GLsizei(h), GL_RGB,
               GL_UNSIGNED_BYTE, addr pix[0])
  result = newSeq[byte](pix.len)
  let stride = w * 3
  for row in 0 ..< h:
    copyMem(addr result[row * stride], addr pix[(h - 1 - row) * stride], stride)

proc gl_present*(window: Window) = discard glSwapWindow(window)

proc gl_imgui_init*(window: Window) =
  discard ImGui_ImplSDL3_InitForOpenGL(window, ctx)
  discard ImGui_Impl_opengl3_Init("#version 330")

proc gl_imgui_new_frame*() = ImGui_Impl_OpenGL3_NewFrame()

proc gl_imgui_render*(dd: ptr ImDrawData) = ImGui_Impl_OpenGL3_RenderDrawData(dd)

proc gl_ui_texture*(tex: var uint64; px: pointer; w, h: int; bgr555, linear: bool) =
  ## Create or refill an ImGui image. The binding on unit 0 is kept: the
  ## draws bind their own, but ImGui's backend restores what it found.
  var prev: GLint
  glActiveTexture(GL_TEXTURE0)
  glGetIntegerv(GL_TEXTURE_BINDING_2D, addr prev)
  var t = GLuint(tex)
  if t == 0:
    glGenTextures(1, addr t)
    tex = uint64(t)
  glBindTexture(GL_TEXTURE_2D, t)
  let f = GLint(if linear: GL_LINEAR else: GL_NEAREST)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, f)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, f)
  # Linear filtering at an image's edge would blend in the opposite edge's
  # texels under the default REPEAT (a thumbnail's bottom row on its top)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))
  if bgr555:
    glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGB5), GLsizei(w), GLsizei(h), 0,
                 GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV, px)
  else:
    glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), GLsizei(w), GLsizei(h), 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, px)
  glBindTexture(GL_TEXTURE_2D, GLuint(prev))

proc gl_info*(): seq[string] =
  @["OpenGL",
    "  Version: " & $cast[cstring](glGetString(GL_VERSION)),
    "  Shading: " & $cast[cstring](glGetString(GL_SHADING_LANGUAGE_VERSION))]
