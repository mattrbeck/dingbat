import std/[os, strutils]
import sdl2 except init, quit
import crab/common/input
import crab/gba/gba
import crab/gb/gb

const GBA_W = 240
const GBA_H = 160
const GB_W  = 160
const GB_H  = 144

# SDL keycodes matching the default keybindings and reference HTML virtual controls.
# Emscripten maps JS keycodes (uppercase ASCII for printable keys) to SDL keycodes
# (lowercase ASCII), so these match the keycode= attributes in index.html.
const KEYBINDINGS: array[10, (cint, Input)] = [
  (cint(101), Input.UP),     # e
  (cint(100), Input.DOWN),   # d
  (cint(115), Input.LEFT),   # s
  (cint(102), Input.RIGHT),  # f
  (cint(107), Input.A),      # k
  (cint(106), Input.B),      # j
  (cint(108), Input.SELECT), # l
  (cint(59),  Input.START),  # semicolon
  (cint(119), Input.L),      # w
  (cint(114), Input.R),      # r
]

type EmuKind = enum ekNone, ekGBA, ekGB

# Use a plain value-type global (not a ref) to avoid ARC header offset issues
# and ensure stable memory layout in WASM.
var stateKind:     EmuKind     = ekNone
var stateGba:      GBA         = nil
var stateGb:       GB          = nil
var stateWindow:   WindowPtr   = nil
var stateRenderer: RendererPtr = nil
var stateTexture:  TexturePtr  = nil
var frameCount {.exportc.}: cint = 0

# Global audio sample buffer for JS to consume via Web Audio API.
# The APU appends float32 stereo samples here; JS reads and clears after each frame.
var audioBuffer: seq[float32] = @[]

proc appendAudioSample(left, right: float32) {.exportc.} =
  audioBuffer.add(left)
  audioBuffer.add(right)

proc getAudioBufferPtr(): pointer {.exportc.} =
  if audioBuffer.len > 0: addr audioBuffer[0] else: nil

proc getAudioBufferLen(): cint {.exportc.} =
  cint(audioBuffer.len)

proc clearAudioBuffer() {.exportc.} =
  audioBuffer.setLen(0)

proc setInput(inputId: cint; pressed: cint) {.exportc.} =
  if inputId < 0 or inputId > ord(Input.high): return
  let inp = Input(inputId)
  let down = pressed != 0
  case stateKind
  of ekGBA: stateGba.handle_input(inp, down)
  of ekGB:  stateGb.handle_input(inp, down)
  of ekNone: discard

proc checkInput() =
  var evt = defaultEvent
  while pollEvent(evt):
    case evt.kind
    of KeyDown, KeyUp:
      let pressed = evt.kind == KeyDown
      let sym = key(evt).keysym.sym
      for (code, inp) in KEYBINDINGS:
        if sym == code:
          setInput(cint(ord(inp)), cint(pressed))
          break
    else: discard

proc loop_tick() {.exportc.} =
  if stateRenderer == nil: return
  inc frameCount
  case stateKind
  of ekGBA:
    if stateTexture == nil: return
    stateGba.step_frame()
    discard stateTexture.updateTexture(nil, unsafeAddr stateGba.ppu.framebuffer[0], GBA_W * 2)
  of ekGB:
    if stateTexture == nil: return
    stateGb.step_frame()
    discard stateTexture.updateTexture(nil, unsafeAddr stateGb.ppu.framebuffer[0], GB_W * 2)
  of ekNone:
    return
  checkInput()
  stateRenderer.clear()
  discard stateRenderer.copy(stateTexture, nil, nil)
  stateRenderer.present()

proc initFromEmscripten(rom_path: cstring) {.exportc.} =
  let path = $rom_path
  let ext = path.splitFile().ext.toLowerAscii()
  if stateTexture != nil:
    destroyTexture(stateTexture)
    stateTexture = nil
  if ext in [".gb", ".gbc"]:
    stateKind = ekGB
    stateGb = new_gb("", path, true, false, false)
    stateGb.post_init()
    stateTexture = stateRenderer.createTexture(
      SDL_PIXELFORMAT_BGR555, SDL_TEXTUREACCESS_STREAMING, GB_W, GB_H)
    discard stateRenderer.setLogicalSize(GB_W, GB_H)
  else:
    stateKind = ekGBA
    let bios = if fileExists("bios.bin"): "bios.bin" else: ""
    stateGba = new_gba(bios, path, false)
    stateGba.post_init()
    stateTexture = stateRenderer.createTexture(
      SDL_PIXELFORMAT_BGR555, SDL_TEXTUREACCESS_STREAMING, GBA_W, GBA_H)
    discard stateRenderer.setLogicalSize(GBA_W, GBA_H)
    frameCount = 0

when defined(emscripten):
  # Register a dummy main loop so SDL2's emscripten backend can call
  # emscripten_set_main_loop_timing during SDL_Init without warning.
  type em_callback_func = proc() {.cdecl.}
  proc emscripten_set_main_loop(fun: em_callback_func, fps, sim: cint) {.header: "<emscripten.h>".}
  proc emscripten_cancel_main_loop() {.header: "<emscripten.h>".}
  proc dummyLoop() {.cdecl.} = discard
  emscripten_set_main_loop(dummyLoop, 0, 0)

discard sdl2.init(INIT_VIDEO or INIT_AUDIO)
stateWindow = createWindow("crab", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                            GBA_W * 4, GBA_H * 4, SDL_WINDOW_SHOWN)
stateRenderer = stateWindow.createRenderer(-1, Renderer_Accelerated)

when defined(emscripten):
  emscripten_cancel_main_loop()  # cancel dummy; JS drives loop via RAF
