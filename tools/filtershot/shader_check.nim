## Compile-checks the desktop GL 3.3 present shader (src/dingbat.nim FRAG_SRC)
## in a real GL context from a hidden SDL window (web/render.test.mjs does the
## same for the web twin).
##
## Build: nim c -d:release --path:src -o:tools/filtershot/shader_check \
##          tools/filtershot/shader_check.nim
## Exit 0 = compiled + linked; nonzero prints the GL info log.

import std/[os, strutils]
import sdl2 except init, quit
import imguin/glad/gl

proc extract(src, marker: string): string =
  let start = src.find(marker)
  if start < 0: stderr.writeLine "marker not found: " & marker; system.quit(2)
  let a = src.find("\"\"\"", start) + 3
  let b = src.find("\"\"\"", a)
  src[a ..< b]

proc compile(kind: GLenum; src: string): GLuint =
  result = glCreateShader(kind)
  var cstr = allocCStringArray([src])
  glShaderSource(result, 1, cstr, nil)
  deallocCStringArray(cstr)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, addr ok)
  if ok == 0:
    var log = newString(4096)
    var n: GLsizei
    glGetShaderInfoLog(result, 4096, addr n, cstring(log))
    log.setLen(n)
    stderr.writeLine "shader compile failed:\n" & log
    system.quit(1)

proc main() =
  let dingbat_src = readFile(getAppDir() / ".." / ".." / "src" / "dingbat.nim")
  let frag = extract(dingbat_src, "const FRAG_SRC")
  let vert = extract(dingbat_src, "const VERT_SRC")
  if sdl2.init(INIT_VIDEO) != SdlSuccess:
    stderr.writeLine "SDL init failed: " & $getError(); system.quit(2)
  discard glSetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
  discard glSetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
  discard glSetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE)
  let win = createWindow("shader_check", 0, 0, 64, 64,
                         SDL_WINDOW_OPENGL or SDL_WINDOW_HIDDEN)
  if win == nil:
    stderr.writeLine "window failed: " & $getError(); system.quit(2)
  let ctx = glCreateContext(win)
  if ctx == nil:
    stderr.writeLine "GL context failed: " & $getError(); system.quit(2)
  discard gladLoadGL(glGetProcAddress)
  let fs = compile(GL_FRAGMENT_SHADER, frag)
  let vs = compile(GL_VERTEX_SHADER, vert)
  let prog = glCreateProgram()
  glAttachShader(prog, vs)
  glAttachShader(prog, fs)
  glLinkProgram(prog)
  var ok: GLint
  glGetProgramiv(prog, GL_LINK_STATUS, addr ok)
  if ok == 0:
    var log = newString(4096)
    var n: GLsizei
    glGetProgramInfoLog(prog, 4096, addr n, cstring(log))
    log.setLen(n)
    stderr.writeLine "link failed:\n" & log
    system.quit(1)
  echo "FRAG_SRC + VERT_SRC compile and link OK"
  glDeleteContext(ctx)
  destroy(win)
  sdl2.quit()

main()
