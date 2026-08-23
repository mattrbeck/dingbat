import std/[os, strutils, math]
import sdl2 except init, quit
import zippy  # clip anchors + their strip thumbnails are stored deflated
import dingbat/common/input
import dingbat/common/rewind
import dingbat/common/serialize
import dingbat/common/scheduler
import dingbat/gba/gba
import dingbat/gba/link
import dingbat/gba/rollback
import dingbat/gba/netcore
import dingbat/gb/gb
import dingbat/gb/link as gblink
import dingbat/gb/rollback as gbrb
import dingbat/gb/printer
import dingbat/common/cheats
import dingbat/common/lcd_response

const GBA_W = 240
const GBA_H = 160
const GB_W  = 160
const GB_H  = 144

# SDL keycodes for non-printable keys are scancode | SDLK_SCANCODE_MASK.
const SDLK_SCANCODE_MASK = cint(1 shl 30)
const SC_RIGHT = cint(79); const SC_LEFT = cint(80)
const SC_DOWN  = cint(81); const SC_UP   = cint(82)

# Default keybindings; mutable so JS can rebind via setKeybindingForInput().
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

var stateKind:     EmuKind     = ekNone
var stateGba:      GBA         = nil
var stateGb:       GB          = nil
var stateWindow:   WindowPtr   = nil
var stateRenderer: RendererPtr = nil
var stateTexture:  TexturePtr  = nil
var frameCount {.exportc.}: cint = 0

# Session handles, hoisted above their blocks because earlier procs guard on
# them. Module-scope heap globals in this build must stay nil/empty here and
# be allocated only from JS-invoked procs: main() returns after init (JS
# drives frames via rAF) and Nim's exit teardown destroys anything allocated
# at module init.
var stateNet: NetCore = nil                        # online link (netlink_*)
var stateRollback: RollbackSession = nil           # input-rollback online play,
var stateGbRollback: gbrb.GbRollbackSession = nil  # mutually exclusive
var stateLink: Link = nil                          # 2P local link, mutually
var stateGbLink: gblink.GbLink = nil               # exclusive
var statePrinter: GbPrinter = nil                  # always attached on a solo GB core
var rewindHistory: Rewind = nil
# Speculative rollback is opt-in (?speculative=1), set before netlink_init/attach.
var specEnabled = false

proc netlink_set_speculative(on: cint) {.exportc.} =
  specEnabled = on != 0
var netOut: string = ""       # drained frames awaiting pickup by JS
var netErrorMsg: string = ""  # sticky protocol/handshake failure for the UI
var curRomPath: string = ""   # FS path of the running GBA ROM (for netlink_attach)
# CRC32 of the running GBA ROM, hashed from the cartridge buffer at load so
# netlink never re-reads the FS copy (a 16 MB transient allocation on a
# memory-pressured phone). The FS copy must stay: reset and save-import
# reboots call loadRom again without re-staging the ROM.
var curRomCrc: uint32 = 0
var curRomCrcValid = false

# LCD color correction as BGR555 -> RGBA8888 tables, one per panel:
#  - GBA: the desktop game shader's model (linearize with gamma 4.0, mix
#    channels, re-gamma with 2.2).
#  - GB/GBC: Pokefan531's "GBC-Color" model (libretro): gamma 2.2, luminance
#    0.94, channel-mix matrix, re-gamma. The GBC panel is far less washed out
#    than the AGB's, so the GBA curve crushes its colors.
var colorLutGba: array[0x8000, uint32]
var colorLutGbc: array[0x8000, uint32]
var rgbaBuffer: seq[uint32] = @[]
var colorCorrect = true  # matches the desktop default (cfg.color_correction)

proc build_color_luts(correct: bool) =
  ## With `correct` unset both tables are a plain 5 -> 8 bit expansion. Every
  ## present path reads them, so rebuilding is enough to toggle correction.
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

proc sync_lcd_panel()   # defined with the LCD-response state below

proc wasm_set_color_correction(on: cint) {.exportc.} =
  ## The LCD response table is built for the code->photon curve of the chain
  ## after it, so it re-syncs too.
  colorCorrect = on != 0
  build_color_luts(colorCorrect)
  sync_lcd_panel()

# --- Core-construction settings ---
# Take effect at the next core construction (ROM load / reset), not on the
# running core.
var optGbFifo = true
# sgbRequested defaults OFF: the embed never calls applySystemSettings, and an
# embedded game should play the cart as the cart is.
var sgbRequested  = false
var sgbBorderWanted = true
var optGbaBiosMode: cint = 0  # 0 = HLE, 1 = real BIOS, 2 = real BIOS boot + HLE SWIs
var optGbaRunBios = true
var optMp2kHle = false        # MP2K sound-engine HLE (opt-in, engages on detection)
var optFifoInterp = true      # GBA FIFO interpolation (off = bit-true DAC output)
# Speed mode: GBA renders every other frame and the CPU is charged double
# cycles (less faithful; CPU-heavy games drop internal frames). index.js also
# suspends rewind, HLE audio and FIFO interpolation while it is on.
var optSpeedMode = false

proc apply_speed_mode_gba(g: GBA) =
  g.ppu.frameskip = if optSpeedMode: 1 else: 0
  g.set_underclock(if optSpeedMode: 1 else: 0)

proc apply_speed_mode_gb(g: GB) =
  # Honored only by the scanline renderer (which speed mode forces at load);
  # the FIFO renderer ignores GbPpu.frameskip.
  g.ppu.frameskip = if optSpeedMode: 1 else: 0

proc wasm_set_gb_renderer(fifo: cint) {.exportc.} =
  optGbFifo = fifo != 0

proc wasm_set_gba_bios_mode(mode: cint) {.exportc.} =
  optGbaBiosMode = clamp(mode, 0, 2)

proc wasm_set_gba_run_bios(on: cint) {.exportc.} =
  optGbaRunBios = on != 0

proc make_gba(rom_path: string): GBA =
  ## The real-BIOS modes and the boot intro fall back to HLE when no bios.bin
  ## exists.
  let have_bios = fileExists("bios.bin")
  let bios = if have_bios: "bios.bin" else: ""
  let mode = if have_bios: optGbaBiosMode else: 0
  result = new_gba(bios, rom_path,
                   run_bios = have_bios and optGbaRunBios,
                   use_hle = mode == 0,
                   hle_after_bios = mode == 2)
  result.mp2k_hle = optMp2kHle
  result.apu.set_fifo_interp(optFifoInterp)
  # Speed mode is applied by the solo load site only (initFromEmscripten):
  # link/rollback/netlink cores keep faithful timing, or two peers with
  # different settings would desync.

# LCD response (common/lcd_response.nim): a per-pixel model of how the panel
# settles, so a sprite flickered every other frame reads as translucent
# instead of strobing. Presentation-only, safe to change mid-frame. lcdResp's
# seqs are allocated from JS-invoked procs only (module-teardown rule above).
var lcdOn = false
var lcdResp: LcdResponse

proc sync_lcd_panel() =
  ## Resolve the panel against the running core (set_panel early-outs when
  ## nothing changed). The GBA correction shader linearizes with gamma 4.0, so
  ## the AGB table is built for that chain; GB's branch keeps the 2.2 input
  ## curve, so only the GBA case passes a gamma.
  let gb = stateKind == ekGB and stateGb != nil
  lcdResp.set_panel(lcdOn.resolve(
    gba = stateKind == ekGBA,
    cgb = gb and stateGb.cgb_enabled,
    sgb = gb and stateGb.sgb_active()),
    display_gamma = if stateKind == ekGBA and colorCorrect: 4.0 else: 0.0)

proc wasm_set_lcd_response(on: cint) {.exportc.} =
  ## 0 = off; the panel itself is resolved from the running machine.
  lcdOn = on != 0
  sync_lcd_panel()
  lcdResp.reset()   # drop stale cell state

proc wasm_set_mp2k_hle(on: cint) {.exportc.} =
  ## MP2K/M4A sound-engine HLE: remembered for later cores and applied to the
  ## live GBA core. Only engages when runtime detection finds the engine.
  optMp2kHle = on != 0
  if stateKind == ekGBA and stateGba != nil:
    stateGba.mp2k_hle = optMp2kHle

proc wasm_set_fifo_interp(on: cint) {.exportc.} =
  ## GBA FIFO interpolation: remembered for later cores and applied live.
  ## Off = bit-true DAC output.
  optFifoInterp = on != 0
  if stateKind == ekGBA and stateGba != nil:
    stateGba.apu.set_fifo_interp(optFifoInterp)

proc wasm_set_speed_mode(on: cint) {.exportc.} =
  ## Remembered for later cores and applied to the live solo core. On GB the
  ## frameskip only bites under the scanline renderer (forced at the next
  ## load); the renderer choice is construction-time.
  optSpeedMode = on != 0
  if stateKind == ekGBA and stateGba != nil:
    apply_speed_mode_gba(stateGba)
  elif stateKind == ekGB and stateGb != nil:
    apply_speed_mode_gb(stateGb)

proc wasm_mp2k_available(): cint {.exportc.} =
  ## 1 when the loaded ROM's MP2K engine was detected (HLE can do something).
  if stateKind == ekGBA and stateGba != nil and stateGba.mp2k != nil and
     stateGba.mp2k.engaged: 1 else: 0

proc wasm_hle_audio_active(): cint {.exportc.} =
  ## 1 when a sound-engine HLE is enabled and substituting audio right now:
  ## MP2K engaged with its mixer live (engaged alone can idle while the game
  ## streams its own audio), or the Camelot "Bon" driver engaged. Drives the
  ## "HLE audio" indicator.
  if stateKind != ekGBA or stateGba == nil or not stateGba.mp2k_hle: return 0
  if stateGba.mp2k != nil and stateGba.mp2k.engaged and
     stateGba.mp2k.mixer_live(): return 1
  if stateGba.gs_bon != nil and stateGba.gs_bon.engaged: return 1
  return 0

# --- WebGL2 present path ---
# JS uploads the raw BGR555 framebuffer (gamePtr) to a WebGL2 texture each
# frame; color correction and scanlines run in the shader (web/index.js). The
# LUTs above serve only the low-rate consumers of wasm_fb_ptr (ambient glow,
# paused thumbnail). The LCD response runs on the CPU once per EMULATED frame,
# so a 120 Hz display or a dropped present cannot change how the panel settles.
var gamePtr: pointer = nil       # pointer JS uploads this frame

proc prepare_game_frame(fb: ptr UncheckedArray[uint16]; pixels: int) =
  ## Point gamePtr at the pixels JS uploads: the raw framebuffer (zero-copy)
  ## or, with the LCD response on, the panel's output.
  if lcdOn: sync_lcd_panel()
  gamePtr = cast[pointer](lcdResp.apply(fb, pixels))

proc wasm_game_fb_ptr(): pointer {.exportc.} =
  ## Raw BGR555 for the WebGL2 uploader (the shader masks 0x7FFF). Valid
  ## after the last tick of the RAF turn.
  gamePtr

# --- Super Game Boy ---
# The border is a second layer, not a bigger framebuffer: the core keeps
# emitting 160x144 and the presenter composites 256x224 around it, so
# thumbnails, rewind, save states and the link blits keep their dimensions.

proc wasm_sgb_enable(on: cint) {.exportc.} =
  ## Consulted at the next ROM load; the cart header still decides (no SGB
  ## flag, or CGB-capable: no adapter).
  sgbRequested = on != 0

proc wasm_sgb_active(): cint {.exportc.} =
  ## 1 when the running core has an SGB adapter.
  if stateKind == ekGB and stateGb != nil and stateGb.sgb_active(): 1 else: 0

proc wasm_sgb_border(): cint {.exportc.} =
  ## 1 when a border has been transferred AND the frontend wants it shown.
  if stateKind == ekGB and stateGb != nil and sgbBorderWanted and
     stateGb.sgb_has_border(): 1 else: 0

proc wasm_sgb_border_show(on: cint) {.exportc.} =
  sgbBorderWanted = on != 0

proc wasm_sgb_border_ptr(): pointer {.exportc.} =
  ## 256x224 BGR555, bit 15 = opaque. Same 16-bit layout as the game
  ## framebuffer, so the presenter uploads it as another R16UI texture.
  if stateKind == ekGB and stateGb != nil and stateGb.sgb_active():
    stateGb.sgb_border_ptr() else: nil

proc wasm_sgb_border_gen(): cint {.exportc.} =
  ## Bumped when the border image is re-rendered; the presenter re-uploads
  ## the 112 KiB only when it moves.
  if stateKind == ekGB and stateGb != nil and stateGb.sgb_active():
    cint(stateGb.sgb_border_gen()) else: 0

proc wasm_sgb_backdrop(): cint {.exportc.} =
  ## SGB colour 0, shared by all four screen palettes. Shows wherever the
  ## border is transparent and the Game Boy window is not.
  if stateKind == ekGB and stateGb != nil and stateGb.sgb_active():
    cint(stateGb.sgb_backdrop()) else: 0

proc wasm_out_w(): cint {.exportc.} =
  ## The presented picture's native width, which the canvas backing store is
  ## sized from; the only source that knows a border appeared mid-session.
  if wasm_sgb_border() != 0: cint(SGB_BORDER_W)
  elif stateKind == ekGB: cint(GB_W)
  elif stateKind == ekGBA: cint(GBA_W)
  else: 0

proc wasm_out_h(): cint {.exportc.} =
  if wasm_sgb_border() != 0: cint(SGB_BORDER_H)
  elif stateKind == ekGB: cint(GB_H)
  elif stateKind == ekGBA: cint(GBA_H)
  else: 0

proc wasm_panel_gbc(): cint {.exportc.} =
  ## 1 when the running core is GB/GBC (CGB color model in the shader).
  if stateKind == ekGB: 1 else: 0

# --- Ambient-glow sampler ---
# The glow samples what the user SEES, so this composites the way the
# presenter does (border over Game Boy window over backdrop); it lives here
# rather than in JS because the colour LUT lives here. It deliberately skips
# upscale filters (invisible behind the blur), scanlines (a point sample on a
# dark row would flicker the halo) and letterbox bars (not the picture). The
# DMG shade palette is passed in, not stored: a presentation choice that never
# reaches the core, which keeps states, rewind and netplay byte-identical.

var glowBuffer: seq[uint32]

proc wasm_glow_sample(gw, gh: cint; remap: cint;
                      p0, p1, p2, p3: uint32): pointer {.exportc.} =
  ## Point-sample the composited picture into a gw x gh RGBA8888 buffer. One
  ## sample per cell: an area average costs 20x for a difference invisible
  ## behind the blur.
  if gw <= 0 or gh <= 0: return nil
  let fbp = case stateKind
    of ekGBA: (if stateGba != nil: cast[pointer](addr stateGba.ppu.framebuffer[0]) else: nil)
    of ekGB:  (if stateGb  != nil: cast[pointer](addr stateGb.ppu.framebuffer[0]) else: nil)
    of ekNone: nil
  if fbp == nil: return nil
  let fb = cast[ptr UncheckedArray[uint16]](fbp)
  let lut = if stateKind == ekGB: addr colorLutGbc else: addr colorLutGba
  let gameW = if stateKind == ekGB: GB_W else: GBA_W
  let gameH = if stateKind == ekGB: GB_H else: GBA_H

  let border = wasm_sgb_border() != 0
  let outW = if border: SGB_BORDER_W else: gameW
  let outH = if border: SGB_BORDER_H else: gameH
  let offX = if border: (SGB_BORDER_W - GB_W) div 2 else: 0
  let offY = if border: (SGB_BORDER_H - GB_H) div 2 else: 0
  let bp = if border: cast[ptr UncheckedArray[uint16]](stateGb.sgb_border_ptr())
           else: nil
  let backdrop = if border: stateGb.sgb_backdrop() else: 0'u16

  template unpack(v: uint16): uint32 =
    # Straight 5->8 bit: border art and the backdrop are SNES output and the
    # shader does not correct them either.
    let r = uint32(v and 0x1F); let g = uint32((v shr 5) and 0x1F)
    let b = uint32((v shr 10) and 0x1F)
    0xFF000000'u32 or ((b * 255 div 31) shl 16) or
                      ((g * 255 div 31) shl 8) or (r * 255 div 31)

  if glowBuffer.len != gw * gh: glowBuffer.setLen(gw * gh)
  for y in 0 ..< gh:
    let oy = ((2 * y + 1) * outH) div (2 * gh)
    for x in 0 ..< gw:
      let ox = ((2 * x + 1) * outW) div (2 * gw)
      var px: uint32
      if border and (bp[oy * SGB_BORDER_W + ox] and 0x8000'u16) != 0:
        px = unpack(bp[oy * SGB_BORDER_W + ox] and 0x7FFF'u16)
      else:
        let gx = ox - offX
        let gy = oy - offY
        if gx >= 0 and gx < gameW and gy >= 0 and gy < gameH:
          let raw = fb[gy * gameW + gx] and 0x7FFF'u16
          # A chosen shade palette is already display space, so it bypasses
          # the panel model here as in the shader.
          if remap != 0:
            case raw
            of 0x6BDF: px = p0
            of 0x3ABF: px = p1
            of 0x35BD: px = p2
            of 0x2CEF: px = p3
            else:      px = lut[raw]
          else:
            px = lut[raw]
        else:
          px = unpack(backdrop)
      glowBuffer[y * gw + x] = px
  addr glowBuffer[0]

proc wasm_fb_ptr(): pointer {.exportc.} =
  ## Corrected RGBA8888 of the current framebuffer, converted on demand. Not
  ## on the present path: only the ambient-glow sampler (~10 Hz) and the
  ## paused-game thumbnail call this.
  let fbp = case stateKind
    of ekGBA: (if stateGba != nil: cast[pointer](addr stateGba.ppu.framebuffer[0]) else: nil)
    of ekGB:  (if stateGb  != nil: cast[pointer](addr stateGb.ppu.framebuffer[0]) else: nil)
    of ekNone: nil
  if fbp == nil: return nil
  let fb = cast[ptr UncheckedArray[uint16]](fbp)
  let pixels = if stateKind == ekGB: GB_W * GB_H else: GBA_W * GBA_H
  let lut = if stateKind == ekGB: addr colorLutGbc else: addr colorLutGba
  if rgbaBuffer.len != pixels: rgbaBuffer.setLen(pixels)
  for i in 0 ..< pixels: rgbaBuffer[i] = lut[fb[i] and 0x7FFF]
  addr rgbaBuffer[0]

# float32 stereo samples for Web Audio; JS reads and clears after each frame.
var audioBuffer: seq[float32] = @[]

# True while a muted core's etAPUSample is being dispatched (2P link plays
# player 1 only). The sample is computed and rescheduled as usual; only the
# append is dropped, so the linked cores stay bit-identical.
var audioSuppressed = false

# Slow motion: JS doubles the wall-clock step, so the core makes half the
# samples the AudioContext consumes; emitting each twice restores the rate an
# octave down (a WSOLA pitch-preserving variant sounded worse).
var slowmoStretch = false

proc appendAudioSample(left, right: float32) {.exportc.} =
  if audioSuppressed: return
  audioBuffer.add(left)
  audioBuffer.add(right)
  if slowmoStretch:
    audioBuffer.add(left)
    audioBuffer.add(right)

proc getAudioBufferPtr(): pointer {.exportc.} =
  if audioBuffer.len > 0: addr audioBuffer[0] else: nil

proc getAudioBufferLen(): cint {.exportc.} =
  cint(audioBuffer.len)

proc clearAudioBuffer() {.exportc.} =
  audioBuffer.setLen(0)

# --- Save states ---
# These exports run from JS event handlers, which the browser never
# interleaves with the RAF callback, so they always run at a frame boundary:
# the only place state_bytes / load_state_bytes are valid.

# Retained so the pointer from wasm_state_data stays valid until the next
# wasm_state_size call.
var stateImage: string = ""

proc wasm_state_size(): cint {.exportc.} =
  ## Serialize the full state (same bytes as desktop .state files) into a
  ## retained buffer; returns its length, 0 when no core runs.
  case stateKind
  of ekGBA: stateImage = stateGba.state_bytes()
  of ekGB:  stateImage = stateGb.state_bytes()
  of ekNone: stateImage = ""
  cint(stateImage.len)

proc wasm_state_data(): pointer {.exportc.} =
  ## Buffer from the last wasm_state_size() call; JS copies it out before
  ## calling wasm_state_size() again.
  if stateImage.len > 0: addr stateImage[0] else: nil

proc wasm_set_turbo(on: cint) {.exportc.} =
  ## 2x speed: the APU drops every other sample, so JS gets realtime-rate
  ## (pitched-up) audio at double the frames per second. In online rollback
  ## the live cores are the session's, so set it there (both peers run 2x in
  ## lockstep; turbo only affects sample output, not timing).
  let t = on != 0
  if stateRollback != nil:
    for core in stateRollback.link.cores: core.apu.turbo = t
  elif stateGbRollback != nil:
    for core in stateGbRollback.link.cores: core.apu.turbo = t
  else:
    case stateKind
    of ekGBA: stateGba.apu.turbo = t
    of ekGB:  stateGb.apu.turbo = t
    of ekNone: discard

proc wasm_set_slowmo(on: cint) {.exportc.} =
  ## Single-core only (the linked modes gate it off in JS).
  slowmoStretch = on != 0

proc wasm_set_pitch_correct_ff(on: cint) {.exportc.} =
  ## When on, 2x speed uses a WSOLA time-stretch to keep pitch. Local-only:
  ## it changes how the APU reduces the stream, never timing, so it cannot
  ## desync a link. Mirrored onto live rollback cores.
  let t = on != 0
  if stateRollback != nil:
    for core in stateRollback.link.cores: core.apu.set_pitch_correct_ff(t)
  elif stateGbRollback != nil:
    for core in stateGbRollback.link.cores: core.apu.set_pitch_correct_ff(t)
  else:
    case stateKind
    of ekGBA: stateGba.apu.set_pitch_correct_ff(t)
    of ekGB:  stateGb.apu.set_pitch_correct_ff(t)
    of ekNone: discard

proc wasm_state_error(): cstring {.exportc.} =
  ## Why the last wasm_load_state returned 0, verbatim from the core; empty
  ## before any failure.
  cstring(last_state_error)

proc wasm_state_error_kind(): cint {.exportc.} =
  ## The reason as a StateRejectKind ordinal, so the UI can word each cause
  ## itself; wasm_state_error is the detail line.
  cint(ord(last_state_reject_kind))

proc wasm_load_state(data: pointer; len: cint; keepRewind: cint): cint {.exportc.} =
  ## Apply a state image (same bytes as desktop .state files). Returns 1 on
  ## success; 0 on rejection with the core untouched. Success drops the rewind
  ## ring unless keepRewind != 0, which is for undoing a scrubber commit,
  ## where the ring really is this state's own past.
  last_state_error = ""
  if data == nil or len <= 0: return 0
  if stateNet != nil: return 0  # loading a state mid-link would desync the pair
  var image = newString(int(len))
  copyMem(addr image[0], data, int(len))
  let ok = case stateKind
    of ekGBA: stateGba.load_state_bytes(image)
    of ekGB:  stateGb.load_state_bytes(image)
    of ekNone: false
  if ok and keepRewind == 0 and rewindHistory != nil:
    # A loaded state starts a new timeline; the ring holds the old one, and
    # hold-to-rewind would walk into moments that never preceded the screen.
    rewindHistory.clear()
  if ok: 1 else: 0

proc benchFrames(n: cint) {.exportc.} =
  ## Run frames without presenting, so JS can time emulation apart from the
  ## upload path.
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
  ## 1 while the running cart's rumble motor is on (GB MBC5 rumble types
  ## 0x1C-0x1E, GBA GPIO rumble). stateKind is only set in single-core
  ## sessions, so link modes return 0. JS polls this per RAF tick.
  if stateKind == ekGB and stateGb != nil and stateGb.cartridge.mbc_rumble(): 1
  elif stateKind == ekGBA and stateGba != nil and stateGba.bus.gpio.gpio_rumble(): 1
  else: 0

proc wasm_set_tilt(x, y: cdouble) {.exportc.} =
  ## Accelerometer input, -1..1 per axis (flick transients may exceed 1),
  ## 0 = level. MBC7 on GB, the tilt window or gyro on GBA; a no-op
  ## elsewhere, so JS can feed it unconditionally.
  if stateKind == ekGB and stateGb != nil:
    stateGb.cartridge.set_accelerometer(float(x), float(y))
  elif stateKind == ekGBA and stateGba != nil:
    if stateGba.bus.tilt_present:
      stateGba.bus.tilt_in_x = float(x)
      stateGba.bus.tilt_in_y = float(y)
    elif stateGba.bus.gpio.gyro_present:
      # Gyro carts are rate sensors: x is the rotation rate (CW positive);
      # y is unused.
      stateGba.bus.gpio.gyro_z = float(x)

proc wasm_cart_has_tilt(): cint {.exportc.} =
  ## 0 = none, 1 = tilt/accelerometer (MBC7, GBA tilt), 2 = gyro rate sensor.
  ## JS picks the input model and motion-permission prompt from this.
  if stateKind == ekGB and stateGb != nil and stateGb.cartridge of Mbc7: 1
  elif stateKind == ekGBA and stateGba != nil and stateGba.bus.tilt_present: 1
  elif stateKind == ekGBA and stateGba != nil and stateGba.bus.gpio.gyro_present: 2
  else: 0

# Strip thumbnails: 120-wide BGR555, the same geometry as the save-state
# thumbnail trailer, so one JS decoder serves rewind strips, clip strips and
# state thumbnails.
const SCRUB_THUMB_W = 120
const GBA_SCRUB_THUMB_H = SCRUB_THUMB_W * GBA_H div GBA_W  # 3:2  -> 120x80
const GB_SCRUB_THUMB_H  = SCRUB_THUMB_W * GB_H  div GB_W   # 10:9 -> 120x108

# --- Retroactive clip capture ---
# A rolling ring of state anchors (one per second) plus a per-frame input log;
# deterministic replay from the anchor at or before the chosen start rebuilds
# the frames the player saw while JS records the canvas. Single-core only,
# never serialized. Its own store rather than a reader of the rewind ring:
# rewind may be off, it steps backward from the newest state, and it keeps no
# inputs. Anchors are zlib'd whole payloads; the byte cap below bounds a game
# that compresses badly by shortening the window. Known divergence: the GBA
# RTC reads wall clock, so a replayed clock can differ by the clip length.

# Anchors double as the scrubber strip, so one cadence serves both.
const CLIP_SNAP_INTERVAL = 60          # anchor + thumbnail cadence (frames)
const CLIP_MAX_FRAMES = 60 * 60        # rolling history window (~60 s)
const CLIP_CAP_BYTES = 12 * 1024 * 1024
  ## Byte budget for the anchor ring, smaller than rewind's because the window
  ## is time-bounded too. JS lowers it on iOS, where memory pressure gets the
  ## wasm JIT demoted.

type ClipAnchor = object
  frame: int          # canonical frame index this state is the start of
  packed: string      # zlib'd state payload
  thumb: seq[byte]    # zlib'd BGR555 thumbnail (may be empty)
  tw, th: int

var clipCapBytes = CLIP_CAP_BYTES
var clipAnchors: seq[ClipAnchor] = @[]
var clipAnchorBytes = 0                # packed + thumb across clipAnchors
var clipInputs: seq[uint16] = @[]      # button mask per canonical frame
var clipInputsStart = 0                # absolute frame of clipInputs[0]
var clipFrameIndex = 0                 # canonical frames since core init
var clipCurButtons: uint16 = 0         # live mask, mirrored from setInput
var clipLiveStash = ""                 # live state while a replay runs
var clipCursor = 0
var clipEnd = 0
var clipReplaying = false

proc setClipCapBytes(n: cint) {.exportc.} =
  ## Takes effect at the next anchor, when the ring trims to the new cap.
  if n > 0: clipCapBytes = int(n)

proc clip_reset() =
  clipAnchors.setLen(0)
  clipAnchorBytes = 0
  clipInputs.setLen(0)
  clipInputsStart = 0
  clipFrameIndex = 0
  clipCurButtons = 0
  clipLiveStash = ""
  clipReplaying = false

proc clip_anchor_size(a: ClipAnchor): int = a.packed.len + a.thumb.len

proc clip_capture_thumb(): tuple[pixels: seq[byte], w, h: int] =
  ## The anchor's own frame, downscaled to the shared 120-wide geometry.
  case stateKind
  of ekGBA:
    (downscale_bgr555(stateGba.ppu.framebuffer, GBA_W, GBA_H,
                      SCRUB_THUMB_W, GBA_SCRUB_THUMB_H),
     SCRUB_THUMB_W, GBA_SCRUB_THUMB_H)
  of ekGB:
    (downscale_bgr555(stateGb.ppu.framebuffer, GB_W, GB_H,
                      SCRUB_THUMB_W, GB_SCRUB_THUMB_H),
     SCRUB_THUMB_W, GB_SCRUB_THUMB_H)
  of ekNone: (newSeq[byte](), 0, 0)

proc clip_note_frame() =
  ## Once per canonical frame before it steps: log the held buttons and
  ## evict history outside the window or the budget.
  if clipReplaying: return
  if clipFrameIndex mod CLIP_SNAP_INTERVAL == 0:
    let payload = case stateKind
      of ekGBA: stateGba.state_payload()
      of ekGB:  stateGb.state_payload()
      of ekNone: ""
    if payload.len > 0:
      let t = clip_capture_thumb()
      var a = ClipAnchor(frame: clipFrameIndex,
                         packed: compress(payload, BestSpeed, dfZlib),
                         tw: t.w, th: t.h)
      if t.pixels.len > 0:
        a.thumb = compress(t.pixels, BestSpeed, dfZlib)
      clipAnchors.add(a)
      clipAnchorBytes += clip_anchor_size(a)
  clipInputs.add(clipCurButtons)
  inc clipFrameIndex
  # Time bound and byte bound both evict from the front; on a game that
  # compresses badly the byte bound is what holds.
  let oldest = clipFrameIndex - CLIP_MAX_FRAMES
  while clipAnchors.len > 1 and clipAnchors[1].frame <= oldest:
    clipAnchorBytes -= clip_anchor_size(clipAnchors[0])
    clipAnchors.delete(0)
  while clipAnchors.len > 1 and clipAnchorBytes > clipCapBytes:
    clipAnchorBytes -= clip_anchor_size(clipAnchors[0])
    clipAnchors.delete(0)
  if clipAnchors.len > 0 and clipInputsStart < clipAnchors[0].frame:
    let drop = clipAnchors[0].frame - clipInputsStart
    if drop > 0 and drop <= clipInputs.len:
      clipInputs = clipInputs[drop .. ^1]  # ≤3600 u16s, copying is trivial
      clipInputsStart += drop

proc clip_apply_payload(payload: string): bool =
  try:
    case stateKind
    of ekGBA: stateGba.apply_state_payload(payload)
    of ekGB:  stateGb.apply_state_payload(payload)
    of ekNone: return false
    true
  except CatchableError:
    false

proc clip_set_buttons(mask: uint16) =
  ## Drive the core's absolute input state (idempotent per bit).
  for i in 0 .. ord(Input.high):
    let down = (mask and (1'u16 shl i)) != 0
    case stateKind
    of ekGBA: stateGba.handle_input(Input(i), down)
    of ekGB:  stateGb.handle_input(Input(i), down)
    of ekNone: discard

proc clip_available(): bool =
  ## Replay needs a live single core: every linked mode is frame-synced with
  ## a peer.
  stateKind != ekNone and stateNet == nil and stateLink == nil and
    stateGbLink == nil and stateRollback == nil and stateGbRollback == nil

proc clip_history_frames(): cint {.exportc.} =
  ## How far back the range picker may reach, in frames, measured from the
  ## oldest anchor: a start before it has nothing to replay from.
  if not clip_available() or clipAnchors.len == 0: return 0
  cint(clipFrameIndex - clipAnchors[0].frame)

# --- Clip scrubber strip ---
# Same shape as wasm_rewind_scrub_*, deliberately separate: different
# moments, different cadences, and rewind may not be running at all.

var clipStripThumbs: seq[byte] = @[]  # packed BGR555, newest sample first
var clipStripAgo: seq[int] = @[]      # frames-ago of each sample
var clipStripW = 0
var clipStripH = 0

proc clip_scrub_generate(maxSamples: cint): cint {.exportc.} =
  ## Inflate up to maxSamples anchor thumbnails spread evenly across the
  ## window, newest first. Returns the count.
  clipStripThumbs = @[]
  clipStripAgo = @[]
  if not clip_available(): return 0
  # Newest-first ordering, and only anchors that carry a picture.
  var usable: seq[int] = @[]
  for i in countdown(clipAnchors.high, 0):
    if clipAnchors[i].thumb.len > 0: usable.add(i)
  if usable.len == 0: return 0
  let n = min(max(1, int(maxSamples)), usable.len)
  for s in 0 ..< n:
    # Evenly spaced picks spanning the whole strip; a fixed stride never
    # reaches the oldest frame when the count doesn't divide.
    let i = usable[if n == 1: 0 else: s * (usable.len - 1) div (n - 1)]
    var pixels: seq[byte]
    try:
      pixels = uncompress(clipAnchors[i].thumb, dfZlib)
    except CatchableError:
      continue  # in-process bytes; unreachable
    clipStripW = clipAnchors[i].tw
    clipStripH = clipAnchors[i].th
    clipStripThumbs.add pixels
    clipStripAgo.add(clipFrameIndex - clipAnchors[i].frame)
  cint(clipStripAgo.len)

proc clip_scrub_count(): cint {.exportc.} = cint(clipStripAgo.len)
proc clip_scrub_thumb_w(): cint {.exportc.} = cint(clipStripW)
proc clip_scrub_thumb_h(): cint {.exportc.} = cint(clipStripH)
proc clip_scrub_thumbs_ptr(): pointer {.exportc.} =
  if clipStripThumbs.len > 0: addr clipStripThumbs[0] else: nil

proc clip_scrub_frames_ago(sample: cint): cint {.exportc.} =
  ## How far back sample `i` sits, in frames (0 = the live moment).
  if sample < 0 or sample >= clipStripAgo.len: return 0
  cint(clipStripAgo[int(sample)])

proc clip_begin(startAgo, endAgo: cint): cint {.exportc.} =
  ## Arm a replay of [startAgo, endAgo) frames before now. Stashes the live
  ## state, restores the anchor at or before the start, silently re-emulates
  ## up to the start frame and presents it. Returns the number of frames the
  ## replay will run (JS steps them via clip_tick), or 0 with no usable
  ## history / a linked mode active.
  if not clip_available(): return 0
  if clipReplaying or clipAnchors.len == 0: return 0
  var startFrame = clipFrameIndex - max(0, int(startAgo))
  let endFrame = clipFrameIndex - max(0, int(endAgo))
  # Clamp to what history covers: a short clip beats no clip.
  if startFrame < clipAnchors[0].frame: startFrame = clipAnchors[0].frame
  if startFrame < clipInputsStart: startFrame = clipInputsStart
  if endFrame <= startFrame: return 0
  var pick = 0
  for i in 0 ..< clipAnchors.len:
    if clipAnchors[i].frame <= startFrame: pick = i
    else: break
  var anchorPayload: string
  try:
    anchorPayload = uncompress(clipAnchors[pick].packed, dfZlib)
  except CatchableError:
    return 0
  clipLiveStash = case stateKind
    of ekGBA: stateGba.state_payload()
    of ekGB:  stateGb.state_payload()
    of ekNone: ""
  if clipLiveStash.len == 0: return 0
  if not clip_apply_payload(anchorPayload):
    clipLiveStash = ""
    return 0
  clipCursor = clipAnchors[pick].frame
  clipEnd = endFrame
  clipReplaying = true
  # A replay re-sends serial bytes the printer already processed; mute it.
  if statePrinter != nil: statePrinter.muted = true
  # Silent pre-roll (at most CLIP_SNAP_INTERVAL-1 frames, audio dropped,
  # nothing presented) so the range starts on exactly the chosen frame.
  audioSuppressed = true
  while clipCursor < startFrame:
    let idx = clipCursor - clipInputsStart
    if idx >= 0 and idx < clipInputs.len: clip_set_buttons(clipInputs[idx])
    case stateKind
    of ekGBA: stateGba.step_frame()
    of ekGB:  stateGb.step_frame()
    of ekNone: break
    inc clipCursor
  audioSuppressed = false
  # Present the start frame now: the recorder attaches to the canvas after
  # this returns.
  case stateKind
  of ekGBA:
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                       GBA_W * GBA_H)
  of ekGB:
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGb.ppu.framebuffer[0]),
                       GB_W * GB_H)
  of ekNone: discard
  cint(clipEnd - clipCursor)

proc clip_tick(): cint {.exportc.} =
  ## Step one replay frame with its logged input; present it. Returns frames
  ## remaining, or -1 once the replay is done (state already restored).
  if not clipReplaying: return -1
  if clipCursor >= clipEnd:
    discard clip_apply_payload(clipLiveStash)
    clipLiveStash = ""
    clipReplaying = false
    if statePrinter != nil: statePrinter.muted = false
    clip_set_buttons(clipCurButtons)   # re-apply what the player holds NOW
    return -1
  let idx = clipCursor - clipInputsStart
  if idx >= 0 and idx < clipInputs.len:
    clip_set_buttons(clipInputs[idx])
  case stateKind
  of ekGBA:
    stateGba.step_frame()
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                       GBA_W * GBA_H)
  of ekGB:
    stateGb.step_frame()
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGb.ppu.framebuffer[0]),
                       GB_W * GB_H)
  of ekNone: return -1
  inc clipCursor
  cint(clipEnd - clipCursor)

proc clip_abort() {.exportc.} =
  ## Bail out of a replay (recorder error, ROM switch): restore the live state.
  if not clipReplaying: return
  discard clip_apply_payload(clipLiveStash)
  clipLiveStash = ""
  clipReplaying = false
  if statePrinter != nil: statePrinter.muted = false
  clip_set_buttons(clipCurButtons)

# --- Game Boy Printer ---
# Every solo GB core has a printer from the start (gb/printer.nim: the
# opening INIT resolves inside one frame, so attaching on demand cannot
# work). JS pops finished prints as 8-bit grayscale.
var printerTakeBuf: seq[uint8] = @[]

proc printer_attach() =
  ## Plug a fresh printer into the running solo GB core.
  if stateKind != ekGB or stateGb == nil: return
  statePrinter = new_gb_printer()
  stateGb.set_serial_driver(GbPrinterDriver(printer: statePrinter))

var printerLogBuf: seq[uint16] = @[]

proc printer_log_len(): cint {.exportc.} =
  ## Copy the RX/TX dialogue ring for JS inspection; returns entry count.
  if statePrinter == nil: return 0
  printerLogBuf = statePrinter.log
  cint(printerLogBuf.len)

proc printer_log_ptr(): pointer {.exportc.} =
  if printerLogBuf.len > 0: addr printerLogBuf[0] else: nil

proc printer_disconnect() {.exportc.} =
  ## Used when another peer takes the port (2P link binds its own driver).
  statePrinter = nil

proc printer_poll(): cint {.exportc.} =
  ## Finished strips waiting in the outbox.
  if statePrinter != nil: cint(statePrinter.outbox.len) else: 0

proc printer_take(): cint {.exportc.} =
  ## Pop the oldest finished strip into the retained grayscale buffer
  ## (160 x h, 255 = white). Returns h, or 0 when the outbox is empty.
  if statePrinter == nil or statePrinter.outbox.len == 0: return 0
  let shades = statePrinter.outbox[0]
  statePrinter.outbox.delete(0)
  const GRAY = [255'u8, 170, 85, 0]
  printerTakeBuf.setLen(shades.len)
  for i in 0 ..< shades.len:
    printerTakeBuf[i] = GRAY[shades[i] and 3]
  cint(shades.len div 160)

proc printer_take_ptr(): pointer {.exportc.} =
  if printerTakeBuf.len > 0: addr printerTakeBuf[0] else: nil

# --- GB Camera webcam source ---
# The Pocket Camera cart (gb/mbc/camera.nim) is fed a synthetic scene by
# default; on opt-in JS fills this 128x120 luminance buffer from getUserMedia.
# Allocated from JS-invoked procs only (module-teardown rule above).
const CAM_SRC_W = 128
const CAM_SRC_H = 120
var cameraFrame: seq[uint8] = @[]

proc camera_source_from_buffer(x, y: int): uint8 =
  if cameraFrame.len == CAM_SRC_W * CAM_SRC_H:
    cameraFrame[y * CAM_SRC_W + x]
  else:
    0x80'u8

proc wasm_cart_has_camera(): cint {.exportc.} =
  ## 1 when the running GB cart is the Pocket Camera (type 0xFC).
  if stateKind == ekGB and stateGb != nil and stateGb.cartridge of PocketCamera: 1
  else: 0

proc wasm_camera_attach(): cint {.exportc.} =
  ## Point the emulated sensor at the JS-fed buffer. Returns its length so JS
  ## can bound its writes.
  if stateKind != ekGB or stateGb == nil: return 0
  if cameraFrame.len != CAM_SRC_W * CAM_SRC_H:
    cameraFrame = newSeq[uint8](CAM_SRC_W * CAM_SRC_H)
    for i in 0 ..< cameraFrame.len: cameraFrame[i] = 0x80
  stateGb.cartridge.set_camera_source(camera_source_from_buffer)
  cint(cameraFrame.len)

proc wasm_camera_frame_ptr(): pointer {.exportc.} =
  ## Destination for JS's 128x120 8-bit luminance frames (row-major, 255 =
  ## bright). Valid after wasm_camera_attach.
  if cameraFrame.len > 0: addr cameraFrame[0] else: nil

proc setInput(inputId: cint; pressed: cint) {.exportc.} =
  if inputId < 0 or inputId > ord(Input.high): return
  let inp = Input(inputId)
  let down = pressed != 0
  if down: clipCurButtons = clipCurButtons or (1'u16 shl inputId)
  else: clipCurButtons = clipCurButtons and not (1'u16 shl inputId)
  # During a clip replay the input log owns the core; live presses only
  # update the mask, which clip_tick re-applies when the replay ends.
  if clipReplaying: return
  # While an online link is live, input goes through the netcore so a
  # speculative rollback replays the exact press timing.
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

# Rewind history (common/rewind.nim, declared up top): pushed every
# REWIND_INTERVAL frames from loop_tick, popped by JS while the rewind button
# is held, cleared when a new core is created.

# Memory cap for rewind rings created from here on. JS lowers it on iOS
# before the first ROM load (memory pressure gets the wasm JIT demoted).
var rewindCapBytes: int = REWIND_CAP_BYTES

proc setRewindCapBytes(n: cint) {.exportc.} =
  if n > 0: rewindCapBytes = int(n)

# Master rewind on/off. Off means the ring is never allocated, so loop_tick
# skips the per-interval state_payload() + thumbnail push entirely. Live both
# ways; history does not survive a trip through off.
var rewindEnabled: bool = true

proc setRewindEnabled(on: cint) {.exportc.} =
  rewindEnabled = on != 0
  if not rewindEnabled:
    rewindHistory = nil
  elif rewindHistory == nil and stateKind != ekNone and stateNet == nil:
    # Live single core only: linked modes keep the ring nil (rewinding one
    # side desyncs the pair), and they tear the solo session down or hold
    # stateNet, so both are excluded here.
    rewindHistory = new_rewind(rewindCapBytes)

proc gba_rewind_thumb(g: GBA): RewindThumb =
  RewindThumb(w: SCRUB_THUMB_W, h: GBA_SCRUB_THUMB_H,
              pixels: downscale_bgr555(g.ppu.framebuffer, GBA_W, GBA_H,
                                       SCRUB_THUMB_W, GBA_SCRUB_THUMB_H))

proc gb_rewind_thumb(g: GB): RewindThumb =
  RewindThumb(w: SCRUB_THUMB_W, h: GB_SCRUB_THUMB_H,
              pixels: downscale_bgr555(g.ppu.framebuffer, GB_W, GB_H,
                                       SCRUB_THUMB_W, GB_SCRUB_THUMB_H))

proc loop_tick() {.exportc.} =
  if stateRenderer == nil: return
  if stateNet != nil: return  # online link mode: netlink_tick drives frames
  if clipReplaying: return    # clip_tick owns the core during a replay
  inc frameCount
  # Drain SDL events before stepping so keyboard input lands in this frame.
  checkInput()
  clip_note_frame()
  case stateKind
  of ekGBA:
    if stateTexture == nil: return
    stateGba.step_frame()
    if rewindHistory != nil:
      discard rewindHistory.maybe_push(
        proc(): string = stateGba.state_payload(),
        proc(): RewindThumb = gba_rewind_thumb(stateGba))
    # gamePtr is refreshed every frame (even static ones) so the uploader
    # always has a valid pointer and the LCD response keeps decaying.
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                       GBA_W * GBA_H)
  of ekGB:
    if stateTexture == nil: return
    stateGb.step_frame()
    if statePrinter != nil: statePrinter.tick_frame()
    if rewindHistory != nil:
      discard rewindHistory.maybe_push(
        proc(): string = stateGb.state_payload(),
        proc(): RewindThumb = gb_rewind_thumb(stateGb))
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGb.ppu.framebuffer[0]),
                       GB_W * GB_H)
  of ekNone:
    return
  # JS uploads gamePtr to WebGL2 once per RAF turn (drawGame in web/index.js).

# Run-ahead: each tick runs one canonical frame (audio kept), snapshots,
# silently runs N more with the same input, presents that future frame and
# restores the snapshot, so a press appears N frames sooner. The future frame
# needs its own buffer: ppu.framebuffer is serialized, so apply_state_payload
# would revert the pixels gamePtr points at. Notes: docs/run-ahead.md.
var runaheadFrame: seq[uint16] = @[]

proc runahead_tick(n: cint) {.exportc.} =
  ## loop_tick with N frames of run-ahead (n <= 0 is plain loop_tick).
  ## Single-core only: linked modes are frame-synced with a peer, 2P already
  ## runs two cores per frame, and stateGba/stateGb may be stale there; the
  ## guards make a mistimed JS call a no-op.
  if stateRenderer == nil: return
  if stateNet != nil: return
  if stateLink != nil or stateGbLink != nil: return
  if stateRollback != nil or stateGbRollback != nil: return
  if clipReplaying: return
  inc frameCount
  checkInput()
  clip_note_frame()  # canonical frames only; lookahead steps are not history
  case stateKind
  of ekGBA:
    if stateTexture == nil: return
    stateGba.step_frame()  # canonical frame; its audio is played
    if rewindHistory != nil:
      discard rewindHistory.maybe_push(
        proc(): string = stateGba.state_payload(),
        proc(): RewindThumb = gba_rewind_thumb(stateGba))
    if n <= 0:
      prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                         GBA_W * GBA_H)
      return
    let snap = stateGba.state_payload()
    audioSuppressed = true  # lookahead audio is thrown away
    for _ in 0 ..< int(n): stateGba.step_frame()
    audioSuppressed = false
    if runaheadFrame.len != GBA_W * GBA_H: runaheadFrame.setLen(GBA_W * GBA_H)
    copyMem(addr runaheadFrame[0], addr stateGba.ppu.framebuffer[0], GBA_W * GBA_H * 2)
    try:
      stateGba.apply_state_payload(snap)
    except CatchableError:
      discard  # snapshot came from this build one call ago; unreachable
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr runaheadFrame[0]),
                       GBA_W * GBA_H)
  of ekGB:
    if stateTexture == nil: return
    stateGb.step_frame()
    if statePrinter != nil: statePrinter.tick_frame()
    if rewindHistory != nil:
      discard rewindHistory.maybe_push(
        proc(): string = stateGb.state_payload(),
        proc(): RewindThumb = gb_rewind_thumb(stateGb))
    if n <= 0:
      prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGb.ppu.framebuffer[0]),
                         GB_W * GB_H)
      return
    let snap = stateGb.state_payload()
    # Lookahead frames feed the printer bytes the canonical timeline has not
    # sent yet; snapshot around them so no phantom print survives.
    let prnSnap = if statePrinter != nil: statePrinter.clone() else: nil
    audioSuppressed = true
    for _ in 0 ..< int(n): stateGb.step_frame()
    audioSuppressed = false
    if prnSnap != nil: copy_into(prnSnap, statePrinter)
    if runaheadFrame.len != GB_W * GB_H: runaheadFrame.setLen(GB_W * GB_H)
    copyMem(addr runaheadFrame[0], addr stateGb.ppu.framebuffer[0], GB_W * GB_H * 2)
    try:
      stateGb.apply_state_payload(snap)
    except CatchableError:
      discard
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr runaheadFrame[0]),
                       GB_W * GB_H)
  of ekNone:
    return

proc wasm_rewind_pop(): cint {.exportc.} =
  ## Step back one snapshot (REWIND_INTERVAL frames) and present it. Frame
  ## boundary only. Returns 1 when applied, 0 when exhausted.
  if stateRenderer == nil or stateTexture == nil or rewindHistory == nil:
    return 0
  let snap = rewindHistory.pop()
  if snap.len == 0: return 0
  try:
    case stateKind
    of ekGBA:
      stateGba.apply_state_payload(snap)
      prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                         GBA_W * GBA_H)
    of ekGB:
      stateGb.apply_state_payload(snap)
      prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGb.ppu.framebuffer[0]),
                         GB_W * GB_H)
    of ekNone:
      return 0
  except CatchableError:
    return 0
  # JS draws the restored frame after this returns.
  1

# --- Rewind scrubber (bug-report timeline) ---
# Hands JS a strip of thumbnails sampled across rewind history. The strip is
# copied out of the ring, which stored each picture at push time: nothing is
# applied to the live core and the cost is O(samples), not O(history).

var scrubThumbs: seq[byte] = @[]   # packed BGR555 thumbnails, one after another
var scrubIds: seq[int] = @[]       # absolute rewind ID of each sample
var scrubThumbW = 0
var scrubThumbH = 0

proc current_payload(): string =
  case stateKind
  of ekGBA: (if stateGba != nil: stateGba.state_payload() else: "")
  of ekGB:  (if stateGb  != nil: stateGb.state_payload()  else: "")
  of ekNone: ""

proc apply_payload(payload: string) =
  case stateKind
  of ekGBA: stateGba.apply_state_payload(payload)
  of ekGB:  stateGb.apply_state_payload(payload)
  of ekNone: discard

proc wasm_rewind_scrub_generate(maxSamples: cint): cint {.exportc.} =
  ## Up to maxSamples thumbnails spread evenly across the strip, newest
  ## first. Returns the count; 0 with no history.
  scrubThumbs = @[]
  scrubIds = @[]
  if rewindHistory == nil or stateKind == ekNone: return 0
  let count = rewindHistory.thumb_count
  if count == 0: return 0
  # Evenly spaced picks spanning the whole strip; a fixed stride never
  # reaches the oldest thumbnail when the count doesn't divide.
  let n = min(max(1, int(maxSamples)), count)
  for s in 0 ..< n:
    let i = if n == 1: 0 else: s * (count - 1) div (n - 1)
    let t = rewindHistory.thumb_at(i)
    if t.pixels.len == 0: continue  # unreachable: never a hole in the strip
    # Geometry is fixed per core for the life of the ring.
    scrubThumbW = t.w
    scrubThumbH = t.h
    scrubThumbs.add t.pixels
    scrubIds.add rewindHistory.thumb_id(i)
  cint(scrubIds.len)

proc wasm_rewind_scrub_count(): cint {.exportc.} = cint(scrubIds.len)
proc wasm_rewind_scrub_thumb_w(): cint {.exportc.} = cint(scrubThumbW)
proc wasm_rewind_scrub_thumb_h(): cint {.exportc.} = cint(scrubThumbH)
proc wasm_rewind_scrub_thumbs_ptr(): pointer {.exportc.} =
  if scrubThumbs.len > 0: addr scrubThumbs[0] else: nil

proc wasm_rewind_scrub_seconds_ago(sample: cint): cint {.exportc.} =
  ## Age in tenths of a second, counted in snapshots back from the newest
  ## (so a rewind that shortened history moves the answer with it).
  if sample < 0 or sample >= scrubIds.len or rewindHistory == nil: return 0
  let index = rewindHistory.index_of_id(scrubIds[sample])
  if index < 0: return 0
  let frames = index * rewindHistory.snapshot_interval
  cint(frames * 10 div 60)

proc wasm_rewind_scrub_state_size(sample: cint): cint {.exportc.} =
  ## Build the chosen sample's full .state image (header + payload +
  ## thumbnail) into stateImage, restore the live core, return the size.
  if sample < 0 or sample >= scrubIds.len or rewindHistory == nil:
    return 0
  # By absolute ID: a positional index would slide onto a different moment
  # if anything evicted since the strip was captured.
  let snap = rewindHistory.snapshot_by_id(scrubIds[sample])
  if snap.len == 0: return 0
  let stash = current_payload()
  stateImage = ""
  try:
    apply_payload(snap)
    stateImage = case stateKind
      of ekGBA: stateGba.state_bytes(thumbnail = true)
      of ekGB:  stateGb.state_bytes(thumbnail = true)
      of ekNone: ""
  except CatchableError:
    stateImage = ""
  if stash.len > 0:
    try: apply_payload(stash)
    except CatchableError: discard
  cint(stateImage.len)

# --- Committing to a scrubbed moment ---

proc cart_save_bytes(): seq[byte] =
  ## The bytes that reach the .sav file, not the whole storage section: that
  ## also carries controller state (flash bank/command phase, EEPROM shift
  ## register), which differs whenever a save was mid-command with no save
  ## data change, and would raise the "discards your save" prompt on games
  ## that merely poll their flash chip.
  case stateKind
  of ekGBA:
    if stateGba != nil and stateGba.storage != nil: stateGba.storage.memory
    else: @[]
  of ekGB:
    # No battery means no .sav, so rolling the RAM back costs nothing to
    # warn about.
    if stateGb != nil and stateGb.cartridge != nil and stateGb.cartridge.has_battery:
      stateGb.cartridge.ram
    else: @[]
  of ekNone: @[]

proc wasm_rewind_scrub_save_differs(sample: cint): cint {.exportc.} =
  ## 1 when committing to `sample` would change the cartridge save data. An
  ## exact byte comparison, so it cannot miss or invent a change; it cannot
  ## know intent (a game scribbling in SRAM unprompted still reports one, the
  ## safe direction). Stash and restore per call: holding a stash across the
  ## sheet's lifetime turns every early return or ROM switch into a corrupted
  ## live session, and a round trip is ~4 ms.
  if sample < 0 or sample >= scrubIds.len or rewindHistory == nil: return 0
  let now = cart_save_bytes()
  if now.len == 0: return 0
  let snap = rewindHistory.snapshot_by_id(scrubIds[sample])
  if snap.len == 0: return 0
  let stash = current_payload()
  if stash.len == 0: return 0
  var differs = false
  try:
    apply_payload(snap)
    differs = cart_save_bytes() != now
  except CatchableError:
    differs = false
  try: apply_payload(stash)
  except CatchableError: discard
  if differs: 1 else: 0

proc wasm_rewind_commit(sample: cint): cint {.exportc.} =
  ## Rewind the live core to `sample` and drop every newer snapshot, so the
  ## strip, hold-to-rewind and the next push agree on the newest moment.
  ## Returns 1, or 0 when the sample is gone or a linked mode owns the core.
  ## JS keeps its own pre-commit image for the Undo toast; nothing here
  ## preserves the discarded snapshots.
  if stateRenderer == nil or rewindHistory == nil: return 0
  if stateNet != nil or stateLink != nil or stateGbLink != nil: return 0
  if stateRollback != nil or stateGbRollback != nil: return 0
  if clipReplaying: return 0
  if sample < 0 or sample >= scrubIds.len: return 0
  let snap = rewindHistory.rewind_to_id(scrubIds[sample])
  if snap.len == 0: return 0
  try:
    apply_payload(snap)
  except CatchableError:
    return 0
  # The printer's protocol state is not in the payload, so it is now ahead
  # of the core it is wired to (see resync).
  if statePrinter != nil: statePrinter.resync()
  case stateKind
  of ekGBA:
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                       GBA_W * GBA_H)
  of ekGB:
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGb.ppu.framebuffer[0]),
                       GB_W * GB_H)
  of ekNone: return 0
  1

# --- 2P local link mode ---
# Two cores running the same ROM over the in-process lockstep link
# (gba/link.nim, gb/link.nim). JS drives frames via link_tick and blits each
# core from the per-core RGBA buffers below (same color LUT as the solo
# path). Allocated from JS-invoked procs only (module-teardown rule above).
var linkRgba: array[2, seq[uint32]]

proc link_exit() {.exportc.} =
  ## Flush both cores' battery saves to their FS .sav files (JS persists
  ## those to IndexedDB right after) and drop the link.
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
  ## GB/GBC variant of link_init; player 2's APU is muted as in the GBA path.
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
  ## The two paths hold identical ROM bytes under distinct names, so each
  ## core gets its own .sav (trading needs both). Returns 1 on success.
  link_exit()
  stateNet = nil  # entering 2P mode tears down any online link session
  netOut.setLen(0)
  netErrorMsg.setLen(0)
  # Tear down any running single-core session (mirrors initFromEmscripten).
  if stateGb != nil:
    stateGb.cartridge.mbc_save()
  stateKind = ekNone
  stateGba = nil
  stateGb = nil
  rewindHistory = nil  # rewinding one core would desync the pair
  if stateTexture != nil:
    destroyTexture(stateTexture)
    stateTexture = nil
  if ($rom1_path).splitFile().ext.toLowerAscii() in [".gb", ".gbc"]:
    return gb_link_init($rom1_path, $rom2_path)
  var cores: seq[GBA] = @[]
  for path in [$rom1_path, $rom2_path]:
    if not fileExists(path): return 0
    let core = make_gba(path)
    core.post_init()
    cores.add(core)
  # Player 1's APU is the only audible one: core 2's sample events still run
  # (emulation identical) while appendAudioSample drops the samples.
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
  ## Advance both cores one lockstep frame and convert each changed
  ## framebuffer to RGBA for JS to blit.
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
  # Drain the SDL queue: JS handles link input via link_input, but
  # emscripten's SDL layer still queues keys the JS handler doesn't intercept.
  var evt = defaultEvent
  while pollEvent(evt): discard

proc link_fb_ptr(player: cint): pointer {.exportc.} =
  ## `player`'s (0 or 1) RGBA8888 framebuffer; JS picks the copy length from
  ## link_is_gb.
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

# --- Input-rollback online play ---
# Both cores run locally; only per-frame input bitmasks cross the network. JS
# drives rollback_tick per RAF, ships the returned frame's input to the peer
# and feeds peer inputs via rollback_feed; the session predicts and rolls
# back internally (gba/rollback.nim, gb/rollback.nim). Determinism needs an
# identical build/ROM/save and a deterministic RTC. rbLocal is this peer's
# core index.
var rbLocal = 0
var rbEpoch: int64 = 0

proc wrap_rollback_audio(core: GBA; alwaysMute: bool) =
  ## Mute a core's samples: always for the remote core (`alwaysMute`), and
  ## for the local core only while re-simulating rolled-back frames (already
  ## heard). A proc, not an inline loop: a for-loop closure would alias the
  ## last iteration's `orig`.
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
  ## Convert the local player's framebuffer to RGBA; only the settled frame
  ## is shown.
  if stateRollback == nil: return
  let core = stateRollback.link.cores[rbLocal]
  let fb = cast[ptr UncheckedArray[uint16]](addr core.ppu.framebuffer[0])
  for i in 0 ..< GBA_W * GBA_H:
    linkRgba[rbLocal][i] = colorLutGba[fb[i] and 0x7FFF]

proc wrap_gb_rollback_audio(core: GB; alwaysMute: bool) =
  ## GB analog of wrap_rollback_audio.
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
  ## GB variant of rollback_init; the RTC is frozen to the shared epoch.
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
  ## Leave the session but keep playing: promote this peer's core (with its
  ## progress) to the solo core, unplug its cable, drop the peer's core and
  ## the link. Returns 1; JS then clears rollback mode.
  if stateGbRollback != nil:
    let gcore = stateGbRollback.link.cores[rbLocal]
    gcore.cartridge.mbc_save()
    stateGbRollback = nil
    audioSuppressed = false
    stateGb = gcore
    stateKind = ekGB
    # Back to solo play: plug the printer in (every solo GB core has one).
    printer_attach()
    if stateTexture != nil: destroyTexture(stateTexture)
    stateTexture = stateRenderer.createTexture(
      SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, GB_W, GB_H)
    rgbaBuffer.setLen(GB_W * GB_H)
    stateWindow.setSize(cint(GB_W * 4), cint(GB_H * 4))
    discard stateRenderer.setLogicalSize(GB_W, GB_H)
    lcdResp.reset()
    return 1
  if stateRollback == nil: return 0
  let core = stateRollback.link.cores[rbLocal]
  core.storage.write_save()
  core.set_sio_driver(NullSioDriver())  # cable unplugged
  stateRollback = nil
  audioSuppressed = false
  stateGba = core
  stateKind = ekGBA
  # Recreate the texture rollback_init destroyed: loop_tick bails without it.
  if stateTexture != nil: destroyTexture(stateTexture)
  stateTexture = stateRenderer.createTexture(
    SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, GBA_W, GBA_H)
  rgbaBuffer.setLen(GBA_W * GBA_H)
  stateWindow.setSize(cint(GBA_W * 4), cint(GBA_H * 4))
  discard stateRenderer.setLogicalSize(GBA_W, GBA_H)
  lcdResp.reset()
  1

proc rollback_init(rom1_path, rom2_path: cstring; localPlayer: cint;
                   epoch: cdouble): cint {.exportc.} =
  ## rom1/rom2 hold each player's ROM bytes under distinct names (own .sav
  ## each); `localPlayer` (0/1) is the core this peer drives; `epoch` is the
  ## shared unix-seconds RTC seed both peers must pass identically. Returns 1.
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
  if ($rom1_path).splitFile().ext.toLowerAscii() in [".gb", ".gbc"]:
    return gb_rollback_init($rom1_path, $rom2_path, int64(epoch))
  var cores: seq[GBA] = @[]
  for path in [$rom1_path, $rom2_path]:
    if not fileExists(path): return 0
    let core = make_gba(path)
    core.post_init()
    core.enable_deterministic_rtc(int64(epoch))
    cores.add(core)
  wrap_rollback_audio(cores[rbLocal], alwaysMute = false)
  wrap_rollback_audio(cores[1 - rbLocal], alwaysMute = true)
  stateRollback = new_rollback_session(new_link(cores), rbLocal, 12)
  for p in 0 .. 1: linkRgba[p] = newSeq[uint32](GBA_W * GBA_H)
  frameCount = 0
  1

proc rollback_tick(localBits: cint): cint {.exportc.} =
  ## Advance one frame with the local input + prediction. Returns the frame
  ## index just simulated (ship it to the peer with `localBits`), or -1 if
  ## stalled at the prediction window.
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
  ## Ingest a peer input (may trigger a rollback + re-simulation).
  if frame < 0: return
  if stateGbRollback != nil:
    gbrb.feed_remote(stateGbRollback, int(frame), uint16(bits))
    return
  if stateRollback == nil: return
  stateRollback.feed_remote(int(frame), uint16(bits))

proc rollback_fb_ptr(): pointer {.exportc.} =
  ## The local player's RGBA framebuffer, valid after a tick.
  if stateRollback == nil and stateGbRollback == nil: return nil
  addr linkRgba[rbLocal][0]

proc rollback_head(): cint {.exportc.} =
  if stateGbRollback != nil: cint(stateGbRollback.head)
  elif stateRollback == nil: -1 else: cint(stateRollback.head)

proc rollback_confirmed(): cint {.exportc.} =
  if stateGbRollback != nil: cint(stateGbRollback.confirmed)
  elif stateRollback == nil: -1 else: cint(stateRollback.confirmed)

proc rollback_load_state(player: cint; data: pointer; len: cint): cint {.exportc.} =
  ## Seed core `player` from a full save-state so the session continues from
  ## where each player was. Call before the first tick. The deterministic RTC
  ## is re-applied after: the state carries the solo wall-clock RTC, which
  ## would desync. Returns 1 on success.
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
  ## Debug: serialize rollback core `player`'s full save-state into a buffer
  ## and return its length (0 if no session). Pair with rollback_dump_data;
  ## captures a live desync for offline reproduction.
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
  ## Monotonic count of SIO transfers on the emulated cable. A linked game
  ## fires these continuously and stops when it closes the link, so JS
  ## watches this for "no activity => done"; the SIO mode register stays
  ## latched in multi mode after a game finishes, so it cannot serve.
  if stateGbRollback != nil: return cint(stateGbRollback.link.transfers and 0x7fffffff)
  if stateRollback == nil: return 0
  cint(stateRollback.link.transfers and 0x7fffffff)

# --- Cheats ---

proc current_cheat_engine(): CheatEngine =
  case stateKind
  of ekGBA: (if stateGba != nil: stateGba.cheats else: nil)
  of ekGB:  (if stateGb  != nil: stateGb.cheats  else: nil)
  of ekNone: nil

proc refresh_cheat_rom_patches() =
  case stateKind
  of ekGBA: (if stateGba != nil: stateGba.refresh_cheat_rom_patches())
  of ekGB:  (if stateGb  != nil: stateGb.refresh_cheat_rom_patches())
  of ekNone: discard

# Returned to JS, so it must outlive the proc.
var cheatErrBuf: string

proc load_cheats(text: cstring): cstring {.exportc.} =
  ## Replace the game's cheat list with the `.cht` text from JS. Returns a
  ## newline-separated list of parse errors ("name: message"), or "".
  let eng = current_cheat_engine()
  if eng == nil: return cstring("")
  eng.deserialize($text)
  refresh_cheat_rom_patches()
  cheatErrBuf = ""
  for c in eng.cheats:
    if c.error.len > 0:
      if cheatErrBuf.len > 0: cheatErrBuf.add "\n"
      cheatErrBuf.add (if c.name.len > 0: c.name else: "?") & ": " & c.error
  return cstring(cheatErrBuf)

proc initFromEmscripten(rom_path: cstring) {.exportc.} =
  link_exit()
  clip_reset()  # capture history belongs to the previous core
  statePrinter = nil  # the printer belongs to the previous core
  stateNet = nil  # JS closes the channel
  netOut.setLen(0)
  netErrorMsg.setLen(0)
  if stateGb != nil:
    stateGb.cartridge.mbc_save()
  let path = $rom_path
  let ext = path.splitFile().ext.toLowerAscii()
  if stateTexture != nil:
    destroyTexture(stateTexture)
    stateTexture = nil
  if ext in [".gb", ".gbc"]:
    stateKind = ekGB
    curRomCrcValid = false  # the cached CRC belongs to a GBA cart
    let bootrom = if fileExists("bootrom.bin"): "bootrom.bin" else: ""
    # Speed mode forces the cheaper scanline renderer (construction-time);
    # the FIFO preference returns when it is off.
    stateGb = new_gb(bootrom, path, optGbFifo and not optSpeedMode, false,
                     bootrom.len > 0)
    stateGb.sgb_requested = sgbRequested
    stateGb.post_init()
    stateGb.apply_speed_mode_gb()  # solo cores only, see make_gba
    printer_attach()  # a printer is always plugged in on solo GB
    stateTexture = stateRenderer.createTexture(
      SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, GB_W, GB_H)
    rgbaBuffer.setLen(GB_W * GB_H)
    # Match the canvas backing store to the panel's aspect ratio: at the
    # GBA's 3:2, GB content letterboxes at a fractional scale, defeating
    # integer display scaling.
    stateWindow.setSize(cint(GB_W * 4), cint(GB_H * 4))
    discard stateRenderer.setLogicalSize(GB_W, GB_H)
  else:
    stateKind = ekGBA
    curRomPath = path  # remembered so netlink_attach can re-derive the ROM CRC
    stateGba = make_gba(path)
    stateGba.post_init()
    stateGba.apply_speed_mode_gba()  # solo cores only, see make_gba
    # Hash the cartridge buffer over its unpadded length: the same bytes a
    # peer gets from hashing the file.
    let cart = stateGba.cartridge
    curRomCrc = crc32(cast[ptr UncheckedArray[char]](addr cart.rom[0])
                        .toOpenArray(0, cart.rom_size - 1))
    curRomCrcValid = true
    stateTexture = stateRenderer.createTexture(
      SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, GBA_W, GBA_H)
    rgbaBuffer.setLen(GBA_W * GBA_H)
    stateWindow.setSize(cint(GBA_W * 4), cint(GBA_H * 4))
    discard stateRenderer.setLogicalSize(GBA_W, GBA_H)
    frameCount = 0
  lcdResp.reset()  # panel state is per-core (and per-resolution)
  rewindHistory = if rewindEnabled: new_rewind(rewindCapBytes) else: nil

# --- Online link mode ---
# One local GBA core linked to a remote peer over a byte transport JS
# provides (a WebRTC DataChannel). The protocol state machine is
# gba/netcore.nim, shared with the native TCP transport. JS shuttles wire
# bytes with netlink_feed/netlink_drain and drives frames with netlink_tick;
# rendering, audio and input reuse the solo paths.

proc net_collect() =
  if stateNet == nil: return
  for f in stateNet.take_outgoing():
    netOut.add f

proc netlink_init(rom_path: cstring; is_host: cint;
                  allow_crc_mismatch: cint): cint {.exportc.} =
  ## Set up the solo session on a ROM already in the FS, then bind the
  ## protocol core (host = unit 0, the multi-mode parent). Our HELLO is queued
  ## immediately; drain and send it once the channel opens. With
  ## allow_crc_mismatch, differing CRCs are accepted and reported via
  ## netlink_crc_mismatch (cross-version trades); the UI confirms before
  ## ticking. Returns 1 on success.
  initFromEmscripten(rom_path)  # also tears down any previous session
  if stateKind != ekGBA: return 0
  rewindHistory = nil  # rewinding one side would desync the pair
  stateNet = new_net_core(stateGba, id = (if is_host != 0: 0 else: 1),
                          rom_crc = curRomCrc,
                          strict_crc = allow_crc_mismatch == 0,
                          lead = NETLINK_LEAD_RAF,
                          speculative = specEnabled)
  net_collect()
  frameCount = 0
  1

proc gba_awaiting_link(): cint {.exportc.} =
  ## 1 when an un-linked GBA game is polling multi-player serial mode with
  ## no cable: games only enter that SIO mode to link, so it is the "wants a
  ## partner" badge signal. 0 once online mode is active.
  if stateNet != nil or stateKind != ekGBA or stateGba == nil: return 0
  if stateGba.serial.sio_mode() == smMulti: 1 else: 0

proc netlink_attach(is_host: cint; allow_crc_mismatch: cint): cint {.exportc.} =
  ## Bind the protocol core to the already-running GBA core without the
  ## reboot netlink_init does. The link clock is rebaselined to the core's
  ## current cycle so both sides start near zero; bounded-lead sync absorbs
  ## the remaining skew. Returns 1 on success.
  if stateKind != ekGBA or stateGba == nil or stateNet != nil: return 0
  if not curRomCrcValid: return 0
  rewindHistory = nil  # rewinding one side would desync the pair
  stateNet = new_net_core(stateGba, id = (if is_host != 0: 0 else: 1),
                          rom_crc = curRomCrc,
                          strict_crc = allow_crc_mismatch == 0,
                          lead = NETLINK_LEAD_RAF,
                          speculative = specEnabled)
  stateNet.rebaseline()
  # A multi-mode transfer left mid-flight by the no-cable driver is stuck
  # busy with no completion scheduled; clear it so the game's retry
  # re-initiates through the remote driver. No data is latched.
  if (stateGba.serial.siocnt and 0x0080'u16) != 0:
    stateGba.serial.siocnt = stateGba.serial.siocnt and not 0x0080'u16
  net_collect()
  1

proc netlink_exit() {.exportc.} =
  ## Queue BYE, flush the battery save, keep the game running unlinked (a
  ## yanked cable). JS must drain once more to deliver the BYE, then switch
  ## the RAF driver back to loop_tick.
  if stateNet == nil: return
  stateNet.send_bye(LINK_BYE_SHUTDOWN)
  net_collect()
  stateNet = nil
  if stateGba != nil:
    stateGba.set_sio_driver(NullSioDriver())
    stateGba.storage.write_save()
  rewindHistory = if rewindEnabled: new_rewind(rewindCapBytes) else: nil

proc netlink_feed(data: pointer; len: cint): cint {.exportc.} =
  ## Ingest wire bytes (any chunking); a REPLY can unpark a stalled transfer.
  ## Returns 0 on a corrupt stream (sticky error; see netlink_error_msg).
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
  ## Copy up to cap pending outbound bytes into buf; returns the count. Call
  ## after every tick/feed.
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
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                       GBA_W * GBA_H)
    checkInput()
    1
  of naProgress:
    1  # unreachable: the loop above only exits on the other results

proc netlink_stalled(): cint {.exportc.} =
  ## 1 while the emulated clock is parked waiting for the peer.
  if stateNet != nil and stateNet.stalled: 1 else: 0

proc netlink_peer_done(): cint {.exportc.} =
  ## 1 once the peer sent BYE; we keep running.
  if stateNet != nil and stateNet.peer_done: 1 else: 0

proc netlink_crc_mismatch(): cint {.exportc.} =
  ## 1 when the handshake accepted a differing ROM CRC (relaxed mode).
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
  ## Test hook: read a halfword from EWRAM. The linktest ROM's acceptance
  ## contract lives at fixed offsets (0x800 = 0xCAFE when finished).
  if stateGba == nil or offset < 0 or int(offset) + 1 >= stateGba.bus.wram_board.len:
    return 0
  cint(uint16(stateGba.bus.wram_board[offset]) or
       (uint16(stateGba.bus.wram_board[offset + 1]) shl 8))

when defined(emscripten):
  # A dummy main loop so SDL2's emscripten backend can call
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
