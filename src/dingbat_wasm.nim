import std/[os, strutils]
import sdl2 except init, quit
import dingbat/common/input
import dingbat/gba/gba
import dingbat/gb/gb

const GBA_W = 240
const GBA_H = 160
const GB_W  = 160
const GB_H  = 144

# Scancode constants and mask for non-printable keys (arrows, F-keys, etc.)
const SDLK_SCANCODE_MASK = cint(1 shl 30)
const SC_RIGHT = cint(79); const SC_LEFT = cint(80)
const SC_DOWN  = cint(81); const SC_UP   = cint(82)

# Default keybindings: mgba-style (arrow keys, Z/X, A/S, Backspace, Return).
# Mutable so JS can update bindings at runtime via setKeybindingForInput().
var KEYBINDINGS: array[10, (cint, Input)] = [
  (SC_UP    or SDLK_SCANCODE_MASK, Input.UP),
  (SC_DOWN  or SDLK_SCANCODE_MASK, Input.DOWN),
  (SC_LEFT  or SDLK_SCANCODE_MASK, Input.LEFT),
  (SC_RIGHT or SDLK_SCANCODE_MASK, Input.RIGHT),
  (cint(122), Input.A),      # z
  (cint(120), Input.B),      # x
  (cint(8),   Input.SELECT), # backspace
  (cint(13),  Input.START),  # return
  (cint(97),  Input.L),      # a
  (cint(115), Input.R),      # s
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

proc isStopped(): cint {.exportc.} =
  ## 1 while the GBA is in Stop mode (sleeping), used by the JS frontends
  if stateKind == ekGBA and stateGba != nil and stateGba.cpu.stopped: 1 else: 0

proc setInput(inputId: cint; pressed: cint) {.exportc.} =
  if inputId < 0 or inputId > ord(Input.high): return
  let inp = Input(inputId)
  let down = pressed != 0
  case stateKind
  of ekGBA: stateGba.handle_input(inp, down)
  of ekGB:  stateGb.handle_input(inp, down)
  of ekNone: discard

proc setKeybindingForInput(inputId: cint; keycode: cint) {.exportc.} =
  if inputId < 0 or inputId > ord(Input.high): return
  let inp = Input(inputId)
  for i in 0..<KEYBINDINGS.len:
    if KEYBINDINGS[i][1] == inp:
      KEYBINDINGS[i] = (keycode, inp)
      return

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
    let bootrom = if fileExists("bootrom.bin"): "bootrom.bin" else: ""
    stateGb = new_gb(bootrom, path, true, false, bootrom.len > 0)
    stateGb.post_init()
    stateTexture = stateRenderer.createTexture(
      SDL_PIXELFORMAT_BGR555, SDL_TEXTUREACCESS_STREAMING, GB_W, GB_H)
    discard stateRenderer.setLogicalSize(GB_W, GB_H)
  else:
    stateKind = ekGBA
    let bios = if fileExists("bios.bin"): "bios.bin" else: ""
    stateGba = new_gba(bios, path, run_bios = fileExists("bios.bin"), use_hle = true)
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
stateWindow = createWindow("dingbat", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                            GBA_W * 4, GBA_H * 4, SDL_WINDOW_SHOWN)
stateRenderer = stateWindow.createRenderer(-1, Renderer_Accelerated)

when defined(emscripten):
  emscripten_cancel_main_loop()  # cancel dummy; JS drives loop via RAF
