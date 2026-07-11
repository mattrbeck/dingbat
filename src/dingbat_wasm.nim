import std/[os, strutils, math]
import sdl2 except init, quit
import dingbat/common/input
import dingbat/common/rewind
import dingbat/common/scheduler
import dingbat/gba/gba
import dingbat/gba/link
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

# LCD color correction matching the desktop game shader exactly: linearize
# with lcdGamma 4.0, mix channels, re-gamma with outGamma 2.2. SDL's renderer
# API has no shader hook, but the 15-bit BGR555 domain is small enough to
# precompute exhaustively as a BGR555 -> RGBA8888 table.
var colorLut: array[0x8000, uint32]
var rgbaBuffer: seq[uint32] = @[]

proc build_color_lut() =
  for i in 0 ..< 0x8000:
    let r = pow(float64(i and 0x1F) / 31.0, 4.0)
    let g = pow(float64((i shr 5) and 0x1F) / 31.0, 4.0)
    let b = pow(float64((i shr 10) and 0x1F) / 31.0, 4.0)
    let mixed = [
      (  0.0 * b +  50.0 * g + 255.0 * r) / 255.0,
      ( 30.0 * b + 230.0 * g +  10.0 * r) / 255.0,
      (220.0 * b +  10.0 * g +  50.0 * r) / 255.0,
    ]
    var rgb: array[3, uint32]
    for c in 0 .. 2:
      rgb[c] = uint32(min(255.0, round(pow(mixed[c], 1.0 / 2.2) * 255.0)))
    colorLut[i] = 0xFF000000'u32 or (rgb[2] shl 16) or (rgb[1] shl 8) or rgb[0]

proc present_corrected(fb: ptr UncheckedArray[uint16]; pixels: int; pitch: cint) =
  for i in 0 ..< pixels:
    rgbaBuffer[i] = colorLut[fb[i] and 0x7FFF]
  discard stateTexture.updateTexture(nil, addr rgbaBuffer[0], pitch)

# Global audio sample buffer for JS to consume via Web Audio API.
# The APU appends float32 stereo samples here; JS reads and clears after each frame.
var audioBuffer: seq[float32] = @[]

# True while a muted core's etAPUSample event is being dispatched (2P link
# mode plays player 1's APU only — see link_init). The sample is computed
# and the event rescheduled exactly as usual; only the append is dropped, so
# emulation stays bit-identical between the two linked cores.
var audioSuppressed = false

proc appendAudioSample(left, right: float32) {.exportc.} =
  if audioSuppressed: return
  audioBuffer.add(left)
  audioBuffer.add(right)

proc getAudioBufferPtr(): pointer {.exportc.} =
  if audioBuffer.len > 0: addr audioBuffer[0] else: nil

proc getAudioBufferLen(): cint {.exportc.} =
  cint(audioBuffer.len)

proc clearAudioBuffer() {.exportc.} =
  audioBuffer.setLen(0)

# --- Save states ---
# The build is single-threaded (--threads:off, no pthread link flags) and JS
# drives emulation: requestAnimationFrame calls loop_tick(), one frame per
# call. These exports are only invoked from JS event handlers, which the
# browser never interleaves with the RAF callback, so they always run between
# ticks — i.e. at a frame boundary, the only place state_bytes /
# load_state_bytes are valid.

# Retained so the pointer returned by wasm_state_data stays valid after
# wasm_state_size returns (freed/replaced on the next wasm_state_size call).
var stateImage: string = ""

proc wasm_state_size(): cint {.exportc.} =
  ## Serialize the running core's full state (header + payload, identical to
  ## desktop .state files) into a retained buffer and return its length.
  ## Returns 0 when no core is running. Read the bytes via wasm_state_data().
  case stateKind
  of ekGBA: stateImage = stateGba.state_bytes()
  of ekGB:  stateImage = stateGb.state_bytes()
  of ekNone: stateImage = ""
  cint(stateImage.len)

proc wasm_state_data(): pointer {.exportc.} =
  ## Pointer to the buffer produced by the last wasm_state_size() call.
  ## JS must copy it out before calling wasm_state_size() again.
  if stateImage.len > 0: addr stateImage[0] else: nil

proc wasm_set_turbo(on: cint) {.exportc.} =
  ## 2x speed: the APU drops every other sample at the queue point, so JS
  ## receives realtime-rate (pitched-up) audio while running double the
  ## frames per wall-clock second (the JS tick loop halves its frame step)
  case stateKind
  of ekGBA: stateGba.apu.turbo = on != 0
  of ekGB:  stateGb.apu.turbo = on != 0
  of ekNone: discard

proc wasm_load_state(data: pointer; len: cint): cint {.exportc.} =
  ## Validate and apply a state image (same bytes as desktop .state files).
  ## Returns 1 on success; 0 on rejection (version/core/ROM mismatch or
  ## corruption — the reason is echoed to the log) with the core untouched.
  if data == nil or len <= 0: return 0
  var image = newString(int(len))
  copyMem(addr image[0], data, int(len))
  let ok = case stateKind
    of ekGBA: stateGba.load_state_bytes(image)
    of ekGB:  stateGb.load_state_bytes(image)
    of ekNone: false
  if ok: 1 else: 0

proc benchFrames(n: cint) {.exportc.} =
  ## Run emulation frames without presenting; lets the JS side measure how
  ## much of a frame is emulation vs the LUT convert + texture upload path.
  case stateKind
  of ekGBA:
    for _ in 0 ..< n: stateGba.step_frame()
  of ekGB:
    for _ in 0 ..< n: stateGb.step_frame()
  of ekNone: discard

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

# Rewind history (see common/rewind.nim): pushed every REWIND_INTERVAL
# frames from loop_tick, popped by JS at its own cadence while the rewind
# button is held. Cleared when a new core is created.
# Deliberately nil at module scope: this build's main() returns after init
# (JS drives frames via rAF), and Nim's exit teardown destroys module-init
# heap globals — a ring created here would dangle by the time JS calls in.
# initFromEmscripten (invoked from JS, post-main) creates it instead.
var rewindHistory: Rewind = nil

proc loop_tick() {.exportc.} =
  if stateRenderer == nil: return
  inc frameCount
  case stateKind
  of ekGBA:
    if stateTexture == nil: return
    stateGba.step_frame()
    if rewindHistory != nil:
      discard rewindHistory.maybe_push(proc(): string = stateGba.state_payload())
    if not stateGba.ppu.frame_static:
      present_corrected(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                        GBA_W * GBA_H, GBA_W * 4)
  of ekGB:
    if stateTexture == nil: return
    stateGb.step_frame()
    if rewindHistory != nil:
      discard rewindHistory.maybe_push(proc(): string = stateGb.state_payload())
    present_corrected(cast[ptr UncheckedArray[uint16]](addr stateGb.ppu.framebuffer[0]),
                      GB_W * GB_H, GB_W * 4)
  of ekNone:
    return
  checkInput()
  stateRenderer.clear()
  discard stateRenderer.copy(stateTexture, nil, nil)
  stateRenderer.present()

proc wasm_rewind_pop(): cint {.exportc.} =
  ## Step rewind history back one snapshot (REWIND_INTERVAL frames) and
  ## present the restored framebuffer. Called between loop_tick invocations
  ## only (frame boundary). Returns 1 when applied, 0 when exhausted.
  if stateRenderer == nil or stateTexture == nil or rewindHistory == nil:
    return 0
  let snap = rewindHistory.pop()
  if snap.len == 0: return 0
  try:
    case stateKind
    of ekGBA:
      stateGba.apply_state_payload(snap)
      present_corrected(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                        GBA_W * GBA_H, GBA_W * 4)
    of ekGB:
      stateGb.apply_state_payload(snap)
      present_corrected(cast[ptr UncheckedArray[uint16]](addr stateGb.ppu.framebuffer[0]),
                        GB_W * GB_H, GB_W * 4)
    of ekNone:
      return 0
  except CatchableError:
    return 0
  stateRenderer.clear()
  discard stateRenderer.copy(stateTexture, nil, nil)
  stateRenderer.present()
  1

# --- 2P local link mode (multiplayer phase 3, web side) ---
# Two GBA cores running the same ROM, wired by the in-process lockstep link
# (gba/link.nim). The SDL renderer/canvas only serves the single-core path,
# so in link mode JS drives frames via link_tick and blits each core's
# framebuffer itself from the per-core RGBA buffers below (converted through
# the same color LUT as the single-core present path). Globals are nil/empty
# at module scope and only ever allocated from JS-invoked procs — this
# build's main() returns after init and Nim's exit teardown would leave
# module-init heap globals dangling (see rewindHistory above).
var stateLink: Link = nil
var linkRgba: array[2, seq[uint32]]

proc link_exit() {.exportc.} =
  ## Leave link mode: force a final battery-save flush for both cores into
  ## their FS .sav files (JS persists those to IndexedDB right after) and
  ## drop the link.
  if stateLink != nil:
    for core in stateLink.cores:
      core.storage.write_save()
    stateLink = nil
  audioSuppressed = false

proc link_init(rom1_path, rom2_path: cstring): cint {.exportc.} =
  ## Start 2P link mode. The two paths hold identical ROM bytes under
  ## distinct names, so each core derives its own .sav path — two
  ## independent battery saves for the same game (trading needs both).
  ## Returns 1 on success.
  link_exit()
  # Tear down any running single-core session (mirrors initFromEmscripten)
  if stateGb != nil:
    stateGb.cartridge.mbc_save()
  stateKind = ekNone
  stateGba = nil
  stateGb = nil
  rewindHistory = nil  # rewinding one core would desync the pair
  if stateTexture != nil:
    destroyTexture(stateTexture)
    stateTexture = nil
  let bios = if fileExists("bios.bin"): "bios.bin" else: ""
  var cores: seq[GBA] = @[]
  for path in [$rom1_path, $rom2_path]:
    if not fileExists(path): return 0
    let core = new_gba(bios, path, run_bios = fileExists("bios.bin"), use_hle = true)
    core.post_init()
    cores.add(core)
  # Player 1's APU is the only audible one: wrap core 2's event dispatch so
  # its sample events run normally (identical emulation, event stream and
  # rescheduling untouched) while appendAudioSample drops the samples
  # instead of interleaving them into the shared audio buffer.
  let orig_dispatch = cores[1].scheduler.dispatch
  cores[1].scheduler.dispatch = proc(kind: scheduler.EventType) =
    if kind == etAPUSample:
      audioSuppressed = true
      orig_dispatch(kind)
      audioSuppressed = false
    else:
      orig_dispatch(kind)
  stateLink = new_link(cores)
  for p in 0 .. 1:
    linkRgba[p] = newSeq[uint32](GBA_W * GBA_H)
  frameCount = 0
  1

proc link_tick() {.exportc.} =
  ## Advance both cores one lockstep-linked frame and convert each changed
  ## framebuffer to RGBA. JS blits the buffers into two 2D canvases.
  if stateLink == nil: return
  inc frameCount
  stateLink.step_frame()
  for p in 0 .. 1:
    let core = stateLink.cores[p]
    if core.ppu.frame_static: continue  # unchanged since the previous frame
    let fb = cast[ptr UncheckedArray[uint16]](addr core.ppu.framebuffer[0])
    for i in 0 ..< GBA_W * GBA_H:
      linkRgba[p][i] = colorLut[fb[i] and 0x7FFF]
  # Drain the SDL event queue: JS handles all link-mode input directly via
  # link_input, but emscripten's SDL layer still queues events for keys the
  # JS capture handler doesn't intercept.
  var evt = defaultEvent
  while pollEvent(evt): discard

proc link_fb_ptr(player: cint): pointer {.exportc.} =
  ## Pointer to `player`'s (0 or 1) 240x160 RGBA8888 framebuffer.
  if stateLink == nil or player < 0 or player > 1: return nil
  if linkRgba[player].len == 0: return nil
  addr linkRgba[player][0]

proc link_input(player, inputId, pressed: cint) {.exportc.} =
  if stateLink == nil or player < 0 or player >= cint(stateLink.cores.len): return
  if inputId < 0 or inputId > ord(Input.high): return
  stateLink.cores[player].handle_input(Input(inputId), pressed != 0)

proc initFromEmscripten(rom_path: cstring) {.exportc.} =
  # Leaving 2P link mode for a single-core session
  link_exit()
  # Flush the outgoing GB cart's battery save before replacing it
  if stateGb != nil:
    stateGb.cartridge.mbc_save()
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
      SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, GB_W, GB_H)
    rgbaBuffer.setLen(GB_W * GB_H)
    discard stateRenderer.setLogicalSize(GB_W, GB_H)
  else:
    stateKind = ekGBA
    let bios = if fileExists("bios.bin"): "bios.bin" else: ""
    stateGba = new_gba(bios, path, run_bios = fileExists("bios.bin"), use_hle = true)
    stateGba.post_init()
    stateTexture = stateRenderer.createTexture(
      SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, GBA_W, GBA_H)
    rgbaBuffer.setLen(GBA_W * GBA_H)
    discard stateRenderer.setLogicalSize(GBA_W, GBA_H)
    frameCount = 0
  rewindHistory = new_rewind()

when defined(emscripten):
  # Register a dummy main loop so SDL2's emscripten backend can call
  # emscripten_set_main_loop_timing during SDL_Init without warning.
  type em_callback_func = proc() {.cdecl.}
  proc emscripten_set_main_loop(fun: em_callback_func, fps, sim: cint) {.header: "<emscripten.h>".}
  proc emscripten_cancel_main_loop() {.header: "<emscripten.h>".}
  proc dummyLoop() {.cdecl.} = discard
  emscripten_set_main_loop(dummyLoop, 0, 0)

build_color_lut()
discard sdl2.init(INIT_VIDEO or INIT_AUDIO)
stateWindow = createWindow("dingbat", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                            GBA_W * 4, GBA_H * 4, SDL_WINDOW_SHOWN)
stateRenderer = stateWindow.createRenderer(-1, Renderer_Accelerated)

when defined(emscripten):
  emscripten_cancel_main_loop()  # cancel dummy; JS drives loop via RAF
