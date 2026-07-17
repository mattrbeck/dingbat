import std/[os, strutils, math]
import sdl2 except init, quit
import dingbat/common/input
import dingbat/common/rewind
import dingbat/common/scheduler
import dingbat/gba/gba
import dingbat/gba/link
import dingbat/gba/rollback
import dingbat/gba/netcore
import dingbat/gb/gb
import dingbat/gb/link as gblink
import dingbat/gb/rollback as gbrb

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

# --- Online link mode (multiplayer phase 3b) state ---
# A single local GBA core linked to a remote peer: JS shuttles linkproto
# wire bytes between netlink_feed/netlink_drain and a WebRTC DataChannel.
# Globals follow the module-scope rule below (rewindHistory): nil/empty
# here, only ever allocated from JS-invoked procs. Full implementation
# after initFromEmscripten.
var stateNet: NetCore = nil
# Speculative rollback is opt-in for now (proven bit-identical to the blocking
# path in the native tests, but the interactive Emerald trade is unverified):
# JS enables it from a ?speculative=1 URL param before netlink_init/attach.
var specEnabled = false

proc netlink_set_speculative(on: cint) {.exportc.} =
  specEnabled = on != 0
var netOut: string = ""       # drained frames awaiting pickup by JS
var netErrorMsg: string = ""  # sticky protocol/handshake failure for the UI
var curRomPath: string = ""   # FS path of the running GBA ROM (for netlink_attach)

# LCD color correction. SDL's renderer API has no shader hook, but the 15-bit
# BGR555 domain is small enough to precompute exhaustively as BGR555 ->
# RGBA8888 tables — one per panel:
#  - GBA: the desktop game shader's model (mGBA-style: linearize with
#    lcdGamma 4.0, mix channels, re-gamma with outGamma 2.2)
#  - GB/GBC: Pokefan531's hardware-measured "GBC-Color" model (libretro):
#    linearize with gamma 2.2, luminance 0.94, channel-mix matrix, re-gamma.
#    The GBC panel is far less washed out than the AGB's, so reusing the GBA
#    curve there crushed its colors.
var colorLutGba: array[0x8000, uint32]
var colorLutGbc: array[0x8000, uint32]
var rgbaBuffer: seq[uint32] = @[]
var colorCorrect = true  # matches the desktop default (cfg.color_correction)

proc build_color_luts(correct: bool) =
  ## Fill both BGR555 -> RGBA8888 lookup tables. When `correct` is unset both
  ## do a plain 5-bit -> 8-bit expansion (raw hardware colors). Every present
  ## path (single-core, link, rollback) reads these, so rebuilding them here
  ## is enough to toggle correction everywhere.
  for i in 0 ..< 0x8000:
    let r5 = float64(i and 0x1F) / 31.0
    let g5 = float64((i shr 5) and 0x1F) / 31.0
    let b5 = float64((i shr 10) and 0x1F) / 31.0
    var gba, gbc: array[3, uint32]
    if correct:
      block:  # GBA (AGB panel)
        let r = pow(r5, 4.0)
        let g = pow(g5, 4.0)
        let b = pow(b5, 4.0)
        let mixed = [
          (  0.0 * b +  50.0 * g + 255.0 * r) / 255.0,
          ( 30.0 * b + 230.0 * g +  10.0 * r) / 255.0,
          (220.0 * b +  10.0 * g +  50.0 * r) / 255.0,
        ]
        for c in 0 .. 2:
          gba[c] = uint32(min(255.0, round(pow(mixed[c], 1.0 / 2.2) * 255.0)))
      block:  # GB/GBC (CGB panel)
        const lum = 0.94
        let r = pow(r5, 2.2) * lum
        let g = pow(g5, 2.2) * lum
        let b = pow(b5, 2.2) * lum
        let mixed = [
          0.82 * r + 0.125 * g + 0.195 * b,
          0.24 * r + 0.665 * g + 0.075 * b,
         -0.06 * r + 0.210 * g + 0.730 * b,
        ]
        for c in 0 .. 2:
          gbc[c] = uint32(min(255.0, round(pow(max(0.0, min(1.0, mixed[c])), 1.0 / 2.2) * 255.0)))
    else:
      for (dst, v) in [(0, r5), (1, g5), (2, b5)]:
        gba[dst] = uint32(round(v * 255.0))
        gbc[dst] = gba[dst]
    colorLutGba[i] = 0xFF000000'u32 or (gba[2] shl 16) or (gba[1] shl 8) or gba[0]
    colorLutGbc[i] = 0xFF000000'u32 or (gbc[2] shl 16) or (gbc[1] shl 8) or gbc[0]

proc wasm_set_color_correction(on: cint) {.exportc.} =
  ## Toggle LCD color correction from JS (parity with the desktop menu item).
  ## Rebuilds the shared color LUTs; the next presented frame uses them.
  colorCorrect = on != 0
  build_color_luts(colorCorrect)

# --- Core-construction settings (web Settings panel) ---
# Mirrors the desktop config: these take effect at the NEXT core construction
# (ROM load / reset), not on the running core. Defaults match the previous
# hardcoded behavior: GB FIFO renderer; GBA full HLE with the real-BIOS intro
# played whenever a bios.bin has been provided.
var optGbFifo = true
var optGbaBiosMode: cint = 0  # 0 = HLE, 1 = real BIOS, 2 = real BIOS boot + HLE SWIs
var optGbaRunBios = true

proc wasm_set_gb_renderer(fifo: cint) {.exportc.} =
  optGbFifo = fifo != 0

proc wasm_set_gba_bios_mode(mode: cint) {.exportc.} =
  optGbaBiosMode = clamp(mode, 0, 2)

proc wasm_set_gba_run_bios(on: cint) {.exportc.} =
  optGbaRunBios = on != 0

proc make_gba(rom_path: string): GBA =
  ## Construct a GBA core honoring the settings above. The real-BIOS modes
  ## (and the boot intro) silently fall back to HLE when no bios.bin exists —
  ## there is nothing to execute without one.
  let have_bios = fileExists("bios.bin")
  let bios = if have_bios: "bios.bin" else: ""
  let mode = if have_bios: optGbaBiosMode else: 0
  new_gba(bios, rom_path,
          run_bios = have_bios and optGbaRunBios,
          use_hle = mode == 0,
          hle_after_bios = mode == 2)

# Interframe blending (LCD ghosting): presents the average of the last two
# frames, like mGBA's "interframe blending" — the real panels' slow pixel
# response ghosted the previous frame into the current one, and some games
# exploit it (fast flicker for transparency). Presentation-only: emulation is
# untouched, so it can be toggled live. prevFrame follows the module-scope
# rule (empty here, allocated from JS-invoked procs only).
var frameBlend = false
var prevFrame: seq[uint32] = @[]

proc wasm_set_frame_blend(on: cint) {.exportc.} =
  frameBlend = on != 0
  prevFrame.setLen(0)  # drop stale history (also on core/resolution switch)

proc blend_avg(a, b: uint32): uint32 {.inline.} =
  # Per-channel (a+b)/2 without unpacking: halve both with the low bits
  # masked off, then add back the carry each pair of low bits would produce.
  ((a and 0xFEFEFEFE'u32) shr 1) + ((b and 0xFEFEFEFE'u32) shr 1) +
    (a and b and 0x01010101'u32)

proc present_corrected(fb: ptr UncheckedArray[uint16]; pixels: int; pitch: cint) =
  let lut = if stateKind == ekGB: addr colorLutGbc else: addr colorLutGba
  if frameBlend:
    if prevFrame.len != pixels:  # first blended frame: seed history, no ghost
      prevFrame.setLen(pixels)
      for i in 0 ..< pixels:
        prevFrame[i] = lut[fb[i] and 0x7FFF]
    for i in 0 ..< pixels:
      let cur = lut[fb[i] and 0x7FFF]
      rgbaBuffer[i] = blend_avg(cur, prevFrame[i])
      prevFrame[i] = cur
  else:
    for i in 0 ..< pixels:
      rgbaBuffer[i] = lut[fb[i] and 0x7FFF]
  discard stateTexture.updateTexture(nil, addr rgbaBuffer[0], pitch)

proc wasm_fb_ptr(): pointer {.exportc.} =
  ## Pointer to the last-presented single-core RGBA framebuffer (after color
  ## correction and blending). JS samples a coarse grid from it to drive the
  ## ambient-glow backdrop; stale-while-static is fine for that.
  if rgbaBuffer.len > 0: addr rgbaBuffer[0] else: nil

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
  if stateNet != nil: return 0  # loading a state mid-link would desync the pair
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
  if stateNet != nil: return  # free-running past the peer would desync
  case stateKind
  of ekGBA:
    for _ in 0 ..< n: stateGba.step_frame()
  of ekGB:
    for _ in 0 ..< n: stateGb.step_frame()
  of ekNone: discard

proc isStopped(): cint {.exportc.} =
  ## 1 while the GBA is in Stop mode (sleeping), used by the JS frontends
  if stateKind == ekGBA and stateGba != nil and stateGba.cpu.stopped: 1 else: 0

proc wasm_rumble(): cint {.exportc.} =
  ## 1 while the running single-core GB cart's rumble motor is on (MBC5
  ## rumble carts, types 0x1C-0x1E). GBA, link modes and no-core return 0 —
  ## stateKind is only ekGB in single-core GB sessions, so no mode check is
  ## needed. JS polls this each RAF tick to drive haptics + screen shake.
  if stateKind == ekGB and stateGb != nil and stateGb.cartridge.mbc_rumble(): 1
  else: 0

proc setInput(inputId: cint; pressed: cint) {.exportc.} =
  if inputId < 0 or inputId > ord(Input.high): return
  let inp = Input(inputId)
  let down = pressed != 0
  # While an online link is live, route input through the netcore so a
  # speculative rollback replays the exact press timing (note_input just
  # applies the press when speculation is off, so this is always safe).
  if stateNet != nil:
    stateNet.note_input(inp, down)
    return
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
  if stateNet != nil: return  # online link mode: netlink_tick drives frames
  inc frameCount
  case stateKind
  of ekGBA:
    if stateTexture == nil: return
    stateGba.step_frame()
    if rewindHistory != nil:
      discard rewindHistory.maybe_push(proc(): string = stateGba.state_payload())
    # Blending must present static frames too, so the lingering ghost of the
    # last change decays instead of freezing into the picture
    if frameBlend or not stateGba.ppu.frame_static:
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
var stateGbLink: gblink.GbLink = nil  # GB/GBC 2P link (mutually exclusive)
var linkRgba: array[2, seq[uint32]]

proc link_exit() {.exportc.} =
  ## Leave link mode: force a final battery-save flush for both cores into
  ## their FS .sav files (JS persists those to IndexedDB right after) and
  ## drop the link.
  if stateLink != nil:
    for core in stateLink.cores:
      core.storage.write_save()
    stateLink = nil
  if stateGbLink != nil:
    for core in stateGbLink.cores:
      core.cartridge.mbc_save()
    stateGbLink = nil
  audioSuppressed = false

proc gb_link_init(rom1_path, rom2_path: string): cint =
  ## GB/GBC variant of link_init: two GB cores over gb/link.nim's lockstep
  ## coordinator. Player 2's APU is muted exactly as in the GBA path.
  var cores: seq[GB] = @[]
  let bootrom = if fileExists("bootrom.bin"): "bootrom.bin" else: ""
  for path in [rom1_path, rom2_path]:
    if not fileExists(path): return 0
    let core = new_gb(bootrom, path, optGbFifo, false, bootrom.len > 0)
    core.post_init()
    cores.add(core)
  let orig_dispatch = cores[1].scheduler.dispatch
  cores[1].scheduler.dispatch = proc(kind: scheduler.EventType) =
    if kind == etAPUSample:
      audioSuppressed = true
      orig_dispatch(kind)
      audioSuppressed = false
    else:
      orig_dispatch(kind)
  stateGbLink = new_gb_link(cores)
  for p in 0 .. 1:
    linkRgba[p] = newSeq[uint32](GB_W * GB_H)
  frameCount = 0
  1

proc link_init(rom1_path, rom2_path: cstring): cint {.exportc.} =
  ## Start 2P link mode. The two paths hold identical ROM bytes under
  ## distinct names, so each core derives its own .sav path — two
  ## independent battery saves for the same game (trading needs both).
  ## Returns 1 on success.
  link_exit()
  stateNet = nil  # entering 2P mode tears down any online link session
  netOut.setLen(0)
  netErrorMsg.setLen(0)
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
  # GB/GBC ROMs take the GB lockstep path (gb/link.nim); everything else GBA.
  if ($rom1_path).splitFile().ext.toLowerAscii() in [".gb", ".gbc"]:
    return gb_link_init($rom1_path, $rom2_path)
  var cores: seq[GBA] = @[]
  for path in [$rom1_path, $rom2_path]:
    if not fileExists(path): return 0
    let core = make_gba(path)
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
  if stateGbLink != nil:
    inc frameCount
    stateGbLink.step_frame()
    for p in 0 .. 1:
      let fb = cast[ptr UncheckedArray[uint16]](
        addr stateGbLink.cores[p].ppu.framebuffer[0])
      for i in 0 ..< GB_W * GB_H:
        linkRgba[p][i] = colorLutGbc[fb[i] and 0x7FFF]
    var gevt = defaultEvent
    while pollEvent(gevt): discard
    return
  if stateLink == nil: return
  inc frameCount
  stateLink.step_frame()
  for p in 0 .. 1:
    let core = stateLink.cores[p]
    if core.ppu.frame_static: continue  # unchanged since the previous frame
    let fb = cast[ptr UncheckedArray[uint16]](addr core.ppu.framebuffer[0])
    for i in 0 ..< GBA_W * GBA_H:
      linkRgba[p][i] = colorLutGba[fb[i] and 0x7FFF]
  # Drain the SDL event queue: JS handles all link-mode input directly via
  # link_input, but emscripten's SDL layer still queues events for keys the
  # JS capture handler doesn't intercept.
  var evt = defaultEvent
  while pollEvent(evt): discard

proc link_fb_ptr(player: cint): pointer {.exportc.} =
  ## Pointer to `player`'s (0 or 1) RGBA8888 framebuffer (240x160 GBA or
  ## 160x144 GB — JS picks the copy length from link_is_gb).
  if player < 0 or player > 1 or linkRgba[player].len == 0: return nil
  if stateLink == nil and stateGbLink == nil: return nil
  addr linkRgba[player][0]

proc link_input(player, inputId, pressed: cint) {.exportc.} =
  if inputId < 0 or inputId > ord(Input.high): return
  if stateGbLink != nil:
    if player < 0 or player >= cint(stateGbLink.cores.len): return
    stateGbLink.cores[player].handle_input(Input(inputId), pressed != 0)
    return
  if stateLink == nil or player < 0 or player >= cint(stateLink.cores.len): return
  stateLink.cores[player].handle_input(Input(inputId), pressed != 0)

# --- Input-rollback online play (multiplayer phase 3c) ---
# Both cores run locally (like 2P link); only the two players' per-frame input
# bitmasks cross the network. JS drives one frame per RAF via rollback_tick,
# ships the returned frame's input to the peer, and feeds arriving peer inputs
# via rollback_feed. The RollbackSession predicts + rolls back internally
# (gba/rollback.nim). Determinism: identical build/ROM/save + deterministic RTC.
var stateRollback: RollbackSession = nil
var stateGbRollback: gbrb.GbRollbackSession = nil  # GB/GBC online (mutually exclusive)
var rbLocal = 0
var rbEpoch: int64 = 0

proc wrap_rollback_audio(core: GBA; alwaysMute: bool) =
  ## Mute a core's APU samples: `alwaysMute` (the remote player's core) is always
  ## silent; otherwise (the local core) it is silent only while re-simulating
  ## rolled-back frames, whose audio already played on the forward pass. A proc
  ## (not an inline loop) so each wrapper captures its OWN `orig` — an inline
  ## for-loop closure would alias the last iteration's binding.
  let orig = core.scheduler.dispatch
  core.scheduler.dispatch = proc(kind: scheduler.EventType) =
    if kind == etAPUSample and
       (alwaysMute or (stateRollback != nil and stateRollback.replaying)):
      audioSuppressed = true
      orig(kind)
      audioSuppressed = false
    else:
      orig(kind)

proc rollback_render() =
  ## Convert the LOCAL player's framebuffer to RGBA for blitting (the peer sees
  ## their own game). Skipped mid-replay — only the settled frame is shown.
  if stateRollback == nil: return
  let core = stateRollback.link.cores[rbLocal]
  let fb = cast[ptr UncheckedArray[uint16]](addr core.ppu.framebuffer[0])
  for i in 0 ..< GBA_W * GBA_H:
    linkRgba[rbLocal][i] = colorLutGba[fb[i] and 0x7FFF]

# ---- GB/GBC online rollback (parallel to the GBA path above) ----

proc wrap_gb_rollback_audio(core: GB; alwaysMute: bool) =
  ## GB analog of wrap_rollback_audio: play only the local core, and nothing
  ## while re-simulating rolled-back frames (already heard on the forward pass).
  let orig = core.scheduler.dispatch
  core.scheduler.dispatch = proc(kind: scheduler.EventType) =
    if kind == etAPUSample and
       (alwaysMute or (stateGbRollback != nil and stateGbRollback.replaying)):
      audioSuppressed = true
      orig(kind)
      audioSuppressed = false
    else:
      orig(kind)

proc gb_rollback_render() =
  if stateGbRollback == nil: return
  let core = stateGbRollback.link.cores[rbLocal]
  let fb = cast[ptr UncheckedArray[uint16]](addr core.ppu.framebuffer[0])
  for i in 0 ..< GB_W * GB_H:
    linkRgba[rbLocal][i] = colorLutGbc[fb[i] and 0x7FFF]

proc gb_rollback_init(rom1_path, rom2_path: string; epoch: int64): cint =
  ## GB variant of rollback_init: two GB cores over the lockstep GB link, both
  ## with the RTC frozen to the shared epoch (deterministic across peers).
  var cores: seq[GB] = @[]
  let bootrom = if fileExists("bootrom.bin"): "bootrom.bin" else: ""
  enable_deterministic_gb_rtc(epoch)  # applies to cartridge/state loads below
  for path in [rom1_path, rom2_path]:
    if not fileExists(path): return 0
    let core = new_gb(bootrom, path, optGbFifo, false, bootrom.len > 0)
    core.post_init()
    cores.add(core)
  wrap_gb_rollback_audio(cores[rbLocal], alwaysMute = false)
  wrap_gb_rollback_audio(cores[1 - rbLocal], alwaysMute = true)
  stateGbRollback = gbrb.new_gb_rollback_session(new_gb_link(cores), rbLocal, 12)
  for p in 0 .. 1: linkRgba[p] = newSeq[uint32](GB_W * GB_H)
  frameCount = 0
  1

proc rollback_exit() {.exportc.} =
  if stateRollback != nil:
    for core in stateRollback.link.cores:
      core.storage.write_save()
    stateRollback = nil
  if stateGbRollback != nil:
    for core in stateGbRollback.link.cores:
      core.cartridge.mbc_save()
    stateGbRollback = nil
  audioSuppressed = false

proc rollback_exit_to_single(): cint {.exportc.} =
  ## Leave the session but KEEP PLAYING: promote this peer's core (with all its
  ## post-trade progress) to the single-player core, so disconnecting continues
  ## seamlessly instead of dropping to a blank screen. Unplugs its cable (null
  ## driver), drops the peer's core + the link. Returns 1 on success; JS then
  ## clears rollback mode and the normal single-core RAF branch takes over.
  if stateGbRollback != nil:
    let gcore = stateGbRollback.link.cores[rbLocal]
    gcore.cartridge.mbc_save()
    gcore.set_serial_driver(GbSerialDriver())  # cable unplugged — solo play
    stateGbRollback = nil
    audioSuppressed = false
    stateGb = gcore
    stateKind = ekGB
    if stateTexture != nil: destroyTexture(stateTexture)
    stateTexture = stateRenderer.createTexture(
      SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, GB_W, GB_H)
    rgbaBuffer.setLen(GB_W * GB_H)
    stateWindow.setSize(cint(GB_W * 4), cint(GB_H * 4))
    discard stateRenderer.setLogicalSize(GB_W, GB_H)
    prevFrame.setLen(0)
    return 1
  if stateRollback == nil: return 0
  let core = stateRollback.link.cores[rbLocal]
  core.storage.write_save()
  core.set_sio_driver(NullSioDriver())  # cable unplugged — back to solo play
  stateRollback = nil
  audioSuppressed = false
  stateGba = core
  stateKind = ekGBA
  # Recreate the SDL texture rollback_init destroyed — loop_tick bails without it,
  # so the solo game would freeze on a stale frame after disconnect.
  if stateTexture != nil: destroyTexture(stateTexture)
  stateTexture = stateRenderer.createTexture(
    SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, GBA_W, GBA_H)
  rgbaBuffer.setLen(GBA_W * GBA_H)
  stateWindow.setSize(cint(GBA_W * 4), cint(GBA_H * 4))
  discard stateRenderer.setLogicalSize(GBA_W, GBA_H)
  prevFrame.setLen(0)
  1

proc rollback_init(rom1_path, rom2_path: cstring; localPlayer: cint;
                   epoch: cdouble): cint {.exportc.} =
  ## Start an online input-rollback session. rom1/rom2 hold each player's ROM
  ## bytes under distinct names (own .sav each); `localPlayer` (0/1) is which
  ## core this peer's buttons drive; `epoch` is the shared UTC unix-seconds RTC
  ## seed both peers must pass identically. Returns 1 on success.
  rollback_exit()
  link_exit()
  stateNet = nil
  netOut.setLen(0); netErrorMsg.setLen(0)
  if stateGb != nil: stateGb.cartridge.mbc_save()
  stateKind = ekNone
  stateGba = nil; stateGb = nil
  rewindHistory = nil
  if stateTexture != nil:
    destroyTexture(stateTexture); stateTexture = nil
  if localPlayer < 0 or localPlayer > 1: return 0
  rbLocal = int(localPlayer)
  rbEpoch = int64(epoch)
  # GB/GBC ROMs take the GB rollback path (gb/rollback.nim).
  if ($rom1_path).splitFile().ext.toLowerAscii() in [".gb", ".gbc"]:
    return gb_rollback_init($rom1_path, $rom2_path, int64(epoch))
  var cores: seq[GBA] = @[]
  for path in [$rom1_path, $rom2_path]:
    if not fileExists(path): return 0
    let core = make_gba(path)
    core.post_init()
    core.enable_deterministic_rtc(int64(epoch))
    cores.add(core)
  # Audio: play only the LOCAL core, and nothing while re-simulating rolled-back
  # frames (they were already heard on the forward pass).
  wrap_rollback_audio(cores[rbLocal], alwaysMute = false)
  wrap_rollback_audio(cores[1 - rbLocal], alwaysMute = true)
  stateRollback = new_rollback_session(new_link(cores), rbLocal, 12)
  for p in 0 .. 1: linkRgba[p] = newSeq[uint32](GBA_W * GBA_H)
  frameCount = 0
  1

proc rollback_tick(localBits: cint): cint {.exportc.} =
  ## Advance one presentation frame with the local input + prediction. Returns
  ## the frame index just simulated (ship it to the peer with `localBits`), or
  ## -1 if stalled at the prediction window. Renders the local core.
  if stateGbRollback != nil:
    if gbrb.tick(stateGbRollback, uint16(localBits)) == gbrb.grbStalled: return -1
    inc frameCount
    gb_rollback_render()
    var gevt = defaultEvent
    while pollEvent(gevt): discard
    return cint(stateGbRollback.head - 1)
  if stateRollback == nil: return -1
  let st = stateRollback.tick(uint16(localBits))
  if st == rbStalled: return -1
  inc frameCount
  rollback_render()
  var evt = defaultEvent
  while pollEvent(evt): discard
  cint(stateRollback.head - 1)

proc rollback_feed(frame, bits: cint) {.exportc.} =
  ## Ingest a peer input (may trigger a rollback + re-simulation internally).
  if frame < 0: return
  if stateGbRollback != nil:
    gbrb.feed_remote(stateGbRollback, int(frame), uint16(bits))
    return
  if stateRollback == nil: return
  stateRollback.feed_remote(int(frame), uint16(bits))

proc rollback_fb_ptr(): pointer {.exportc.} =
  ## The local player's RGBA framebuffer (call rollback_render first / after tick).
  if stateRollback == nil and stateGbRollback == nil: return nil
  addr linkRgba[rbLocal][0]

proc rollback_head(): cint {.exportc.} =
  if stateGbRollback != nil: cint(stateGbRollback.head)
  elif stateRollback == nil: -1 else: cint(stateRollback.head)

proc rollback_confirmed(): cint {.exportc.} =
  if stateGbRollback != nil: cint(stateGbRollback.confirmed)
  elif stateRollback == nil: -1 else: cint(stateRollback.confirmed)

proc rollback_load_state(player: cint; data: pointer; len: cint): cint {.exportc.} =
  ## Seed core `player` from a full save-state (same bytes as a .state file) so
  ## the session CONTINUES from where each player was, instead of rebooting. Must
  ## be called BEFORE the first tick (before any checkpoint is captured). The
  ## deterministic RTC is re-applied afterward — the loaded state carries the
  ## single-player wall-clock RTC, which would desync. Returns 1 on success.
  if player < 0 or player > 1 or data == nil or len <= 0: return 0
  var image = newString(int(len))
  copyMem(addr image[0], data, int(len))
  if stateGbRollback != nil:
    enable_deterministic_gb_rtc(rbEpoch)  # frozen shared clock before the load
    return (if stateGbRollback.link.cores[int(player)].load_state_bytes(image): 1 else: 0)
  if stateRollback == nil: return 0
  let core = stateRollback.link.cores[int(player)]
  if not core.load_state_bytes(image): return 0
  core.enable_deterministic_rtc(rbEpoch)  # both peers agree on this clock
  1

var rbDumpImage: string = ""
proc rollback_dump_size(player: cint): cint {.exportc.} =
  ## Debug: serialize online-link core `player`'s (0/1) full save-state into an
  ## internal buffer and return its length (0 if no session / bad index). Pair
  ## with rollback_dump_data to read the bytes — used to capture a live link
  ## desync (e.g. a stuck trade) for offline reproduction. Works for GB and GBA.
  if player < 0 or player > 1: return 0
  if stateGbRollback != nil:
    rbDumpImage = stateGbRollback.link.cores[player].state_bytes()
    return cint(rbDumpImage.len)
  if stateRollback != nil:
    rbDumpImage = stateRollback.link.cores[player].state_bytes()
    return cint(rbDumpImage.len)
  0

proc rollback_dump_data(): pointer {.exportc.} =
  ## Pointer to the buffer filled by the last rollback_dump_size call.
  if rbDumpImage.len > 0: addr rbDumpImage[0] else: nil

proc rollback_transfers(): cint {.exportc.} =
  ## Monotonic count of SIO transfers driven on the emulated cable. A linked game
  ## fires these continuously (timer-paced) to stay synced and STOPS when it
  ## closes the link, so JS watches this for "no activity for a while ⇒ done" —
  ## reliable across games, unlike the SIO mode register which stays latched in
  ## multi mode after a game is finished (why the mode-based check never fired).
  if stateGbRollback != nil: return cint(stateGbRollback.link.transfers and 0x7fffffff)
  if stateRollback == nil: return 0
  cint(stateRollback.link.transfers and 0x7fffffff)

proc initFromEmscripten(rom_path: cstring) {.exportc.} =
  # Leaving 2P link mode for a single-core session
  link_exit()
  # Leaving online link mode: drop the protocol core (JS closes the channel)
  stateNet = nil
  netOut.setLen(0)
  netErrorMsg.setLen(0)
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
    stateGb = new_gb(bootrom, path, optGbFifo, false, bootrom.len > 0)
    stateGb.post_init()
    stateTexture = stateRenderer.createTexture(
      SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, GB_W, GB_H)
    rgbaBuffer.setLen(GB_W * GB_H)
    # Match the canvas backing store to the panel's aspect ratio: leaving it
    # at the GBA's 3:2 letterboxes GB content at a fractional scale, which
    # defeats pixel-perfect (integer) display scaling.
    stateWindow.setSize(cint(GB_W * 4), cint(GB_H * 4))
    discard stateRenderer.setLogicalSize(GB_W, GB_H)
  else:
    stateKind = ekGBA
    curRomPath = path  # remembered so netlink_attach can re-derive the ROM CRC
    stateGba = make_gba(path)
    stateGba.post_init()
    stateTexture = stateRenderer.createTexture(
      SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, GBA_W, GBA_H)
    rgbaBuffer.setLen(GBA_W * GBA_H)
    stateWindow.setSize(cint(GBA_W * 4), cint(GBA_H * 4))
    discard stateRenderer.setLogicalSize(GBA_W, GBA_H)
    frameCount = 0
  prevFrame.setLen(0)  # blend history is per-core (and per-resolution)
  rewindHistory = new_rewind()

# --- Online link mode (multiplayer phase 3b, web side) ---
# One local GBA core linked to a remote peer over whatever byte transport
# JS provides (a WebRTC DataChannel in the web UI). The protocol state
# machine is gba/netcore.nim — the same implementation the native TCP
# transport wraps. JS shuttles wire bytes with netlink_feed/netlink_drain
# and drives frames with netlink_tick instead of loop_tick; rendering,
# audio, and input all reuse the single-core paths (each side renders only
# its own core).

proc net_collect() =
  # Move frames the protocol core queued into the JS-visible drain buffer.
  if stateNet == nil: return
  for f in stateNet.take_outgoing():
    netOut.add f

proc netlink_init(rom_path: cstring; is_host: cint;
                  allow_crc_mismatch: cint): cint {.exportc.} =
  ## Start online link mode on a GBA ROM already written to the FS. Sets up
  ## the usual single-core session, then binds the network protocol core to
  ## it (host = unit 0, the multi-mode parent). Our HELLO is queued
  ## immediately — drain and send it once the channel opens. With
  ## allow_crc_mismatch, differing ROM CRCs are accepted and reported via
  ## netlink_crc_mismatch (cross-version trades, e.g. Ruby<->Sapphire);
  ## the UI should warn + confirm before ticking. Returns 1 on success.
  initFromEmscripten(rom_path)  # also tears down any previous session
  if stateKind != ekGBA: return 0
  rewindHistory = nil  # rewinding one side would desync the pair
  let rom = readFile($rom_path)
  stateNet = new_net_core(stateGba, id = (if is_host != 0: 0 else: 1),
                          rom_crc = crc32(rom),
                          strict_crc = allow_crc_mismatch == 0,
                          lead = NETLINK_LEAD_RAF,
                          speculative = specEnabled)
  net_collect()
  frameCount = 0
  1

proc gba_awaiting_link(): cint {.exportc.} =
  ## 1 when a running, un-linked GBA game is sitting in multi-player serial
  ## mode — i.e. it walked up to a Cable Club / Union Room and is polling a
  ## link port with no cable attached. GBA games only enter this SIO mode to
  ## link, so it is a reliable "wants a partner" signal for the mid-game
  ## "link cable detected" badge. Returns 0 once online mode is active.
  if stateNet != nil or stateKind != ekGBA or stateGba == nil: return 0
  if stateGba.serial.sio_mode() == smMulti: 1 else: 0

proc netlink_attach(is_host: cint; allow_crc_mismatch: cint): cint {.exportc.} =
  ## Bind the network protocol core to the ALREADY-RUNNING GBA core, without
  ## the reboot netlink_init does — the game keeps its exact state, and its
  ## next link-cable poll finds a partner. The link clock is rebaselined to
  ## the core's current cycle so both sides start near zero; the bounded-lead
  ## sync absorbs whatever skew remains. Returns 1 on success.
  if stateKind != ekGBA or stateGba == nil or stateNet != nil: return 0
  if curRomPath.len == 0 or not fileExists(curRomPath): return 0
  rewindHistory = nil  # rewinding one side would desync the pair
  let rom = readFile(curRomPath)
  stateNet = new_net_core(stateGba, id = (if is_host != 0: 0 else: 1),
                          rom_crc = crc32(rom),
                          strict_crc = allow_crc_mismatch == 0,
                          lead = NETLINK_LEAD_RAF,
                          speculative = specEnabled)
  stateNet.rebaseline()
  # A multi-mode transfer left mid-flight by the no-cable driver is stuck
  # busy with no completion scheduled; clear it so the game's link retry
  # re-initiates cleanly through the remote driver (it is polling for
  # exactly that). No data is latched — the real exchange happens on retry.
  if (stateGba.serial.siocnt and 0x0080'u16) != 0:
    stateGba.serial.siocnt = stateGba.serial.siocnt and not 0x0080'u16
  net_collect()
  1

proc netlink_exit() {.exportc.} =
  ## Leave online mode: queue BYE for the peer, flush the battery save, and
  ## keep the local game running unlinked (it sees a yanked cable). JS must
  ## drain once more after this to actually deliver the BYE, then close the
  ## channel and switch the RAF driver back to loop_tick.
  if stateNet == nil: return
  stateNet.send_bye(LINK_BYE_SHUTDOWN)
  net_collect()
  stateNet = nil
  if stateGba != nil:
    stateGba.set_sio_driver(NullSioDriver())
    stateGba.storage.write_save()
  rewindHistory = new_rewind()

proc netlink_feed(data: pointer; len: cint): cint {.exportc.} =
  ## Ingest wire bytes from the transport (any chunking). A REPLY landing
  ## here can unpark a stalled transfer completion. Returns 0 on a corrupt
  ## stream (sticky error; see netlink_error_msg).
  if stateNet == nil or data == nil or len <= 0: return 0
  try:
    stateNet.feed(cast[ptr UncheckedArray[char]](data)
                  .toOpenArray(0, int(len) - 1))
    net_collect()
    1
  except LinkProtoError as e:
    netErrorMsg = e.msg
    0

proc netlink_drain(buf: pointer; cap: cint): cint {.exportc.} =
  ## Copy up to cap pending outbound wire bytes into buf; returns the count
  ## (0 = nothing pending). Call after every tick/feed and send on the
  ## DataChannel.
  net_collect()
  if netOut.len == 0 or buf == nil or cap <= 0: return 0
  let n = min(netOut.len, int(cap))
  copyMem(buf, addr netOut[0], n)
  if n == netOut.len:
    netOut.setLen(0)
  else:
    netOut = netOut[n .. ^1]
  cint(n)

proc netlink_tick(): cint {.exportc.} =
  ## Drive one RAF tick of online link mode. Returns:
  ##   0 = handshake pending (feed more, don't render)
  ##   1 = a frame completed and was presented
  ##   2 = stalled waiting for the peer (emulated clock parked mid-frame;
  ##       keep the RAF loop running, show the indicator, feed on arrival)
  ##   3 = failed (handshake rejection or corrupt stream; netlink_error_msg)
  ##   4 = not in online link mode
  if stateNet == nil: return 4
  if netErrorMsg.len > 0: return 3
  if stateNet.hello == hsFailed:
    netErrorMsg = stateNet.hello_error
    return 3
  var r = stateNet.try_advance()
  while r == naProgress:
    r = stateNet.try_advance()
  net_collect()
  case r
  of naHello:
    0
  of naStalled:
    2
  of naFrame:
    inc frameCount
    if frameBlend or not stateGba.ppu.frame_static:
      present_corrected(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                        GBA_W * GBA_H, GBA_W * 4)
    checkInput()
    stateRenderer.clear()
    discard stateRenderer.copy(stateTexture, nil, nil)
    stateRenderer.present()
    1
  of naProgress:
    1  # unreachable: the loop above only exits on the other results

proc netlink_stalled(): cint {.exportc.} =
  ## 1 while the emulated clock is parked waiting for the peer (frontends
  ## surface "waiting for peer").
  if stateNet != nil and stateNet.stalled: 1 else: 0

proc netlink_peer_done(): cint {.exportc.} =
  ## 1 once the peer sent BYE (it left the session; we keep running).
  if stateNet != nil and stateNet.peer_done: 1 else: 0

proc netlink_crc_mismatch(): cint {.exportc.} =
  ## 1 when the handshake accepted a differing ROM CRC (relaxed mode); the
  ## UI warns + confirms before play starts.
  if stateNet != nil and stateNet.crc_mismatch: 1 else: 0

proc netlink_error_msg(): cstring {.exportc.} =
  ## Sticky failure reason after netlink_tick/netlink_feed reported one.
  cstring(netErrorMsg)

var netDebugStr: string = ""

proc netlink_debug(): cstring {.exportc.} =
  ## Diagnostic snapshot of the protocol core (shown in the web log).
  netDebugStr = if stateNet != nil: stateNet.debug_state() else: "no session"
  cstring(netDebugStr)

proc wasm_ew16(offset: cint): cint {.exportc.} =
  ## Debug/test hook: read a halfword from board WRAM (EWRAM). The linktest
  ## ROM acceptance contract lives at fixed EWRAM offsets (0x800 = 0xCAFE
  ## when finished); browser acceptance tests poll this.
  if stateGba == nil or offset < 0 or int(offset) + 1 >= stateGba.bus.wram_board.len:
    return 0
  cint(uint16(stateGba.bus.wram_board[offset]) or
       (uint16(stateGba.bus.wram_board[offset + 1]) shl 8))

when defined(emscripten):
  # Register a dummy main loop so SDL2's emscripten backend can call
  # emscripten_set_main_loop_timing during SDL_Init without warning.
  type em_callback_func = proc() {.cdecl.}
  proc emscripten_set_main_loop(fun: em_callback_func, fps, sim: cint) {.header: "<emscripten.h>".}
  proc emscripten_cancel_main_loop() {.header: "<emscripten.h>".}
  proc dummyLoop() {.cdecl.} = discard
  emscripten_set_main_loop(dummyLoop, 0, 0)

build_color_luts(colorCorrect)
discard sdl2.init(INIT_VIDEO or INIT_AUDIO)
stateWindow = createWindow("dingbat", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                            GBA_W * 4, GBA_H * 4, SDL_WINDOW_SHOWN)
stateRenderer = stateWindow.createRenderer(-1, Renderer_Accelerated)

when defined(emscripten):
  emscripten_cancel_main_loop()  # cancel dummy; JS drives loop via RAF
