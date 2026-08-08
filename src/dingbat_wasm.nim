import std/[os, strutils, math]
import sdl2 except init, quit
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
# Input-rollback online sessions (see the phase-3c block further down for how
# they're driven). Declared here so earlier procs (e.g. wasm_set_turbo, which
# must reach the live cores) can reference them. Mutually exclusive.
var stateRollback: RollbackSession = nil
var stateGbRollback: gbrb.GbRollbackSession = nil
# 2P local link sessions (see the link-mode block further down). Declared here
# for the same earlier-proc-reference reason: runahead_tick refuses to run
# while a link session exists.
var stateLink: Link = nil
var stateGbLink: gblink.GbLink = nil  # GB/GBC 2P link (mutually exclusive)
# Game Boy Printer (see the printer block further down); hoisted because the
# clip/runahead procs reference it. Always attached on a solo GB core.
var statePrinter: GbPrinter = nil
# Rewind history (see the rewind block further down for what it is and why it
# starts nil); hoisted because wasm_load_state, defined above that block, has
# to drop the ring when a loaded state starts a new timeline.
var rewindHistory: Rewind = nil
# Speculative rollback is opt-in for now (proven bit-identical to the blocking
# path in the native tests, but the interactive Emerald trade is unverified):
# JS enables it from a ?speculative=1 URL param before netlink_init/attach.
var specEnabled = false

proc netlink_set_speculative(on: cint) {.exportc.} =
  specEnabled = on != 0
var netOut: string = ""       # drained frames awaiting pickup by JS
var netErrorMsg: string = ""  # sticky protocol/handshake failure for the UI
var curRomPath: string = ""   # FS path of the running GBA ROM (for netlink_attach)
# CRC32 of the running GBA ROM, computed once at load straight from the
# cartridge buffer. Both netlink entry points used to re-read the whole ROM back
# out of the Emscripten FS purely to hash it — a full 16 MB read and a 16 MB
# transient allocation for a 4-byte result, incurred at exactly the moment
# (starting online play) when a memory-pressured phone can least afford a spike.
#
# The FS copy itself has to stay: reset, save-delete reboot and save-import
# reboot all call loadRom again without re-staging the ROM, so the file is the
# only copy of those bytes the JS side can reach. Freeing it (a 16 MB game is
# otherwise resident twice for the whole session) needs a wasm-side reset that
# rebuilds the core from the existing cartridge — see docs/performance.md.
var curRomCrc: uint32 = 0
var curRomCrcValid = false

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
# Super Game Boy frontend opt-ins (see wasm_sgb_enable / wasm_sgb_border_show).
# sgbRequested is OFF by default: index.js pushes the stored setting in at
# startup, but the embed never calls applySystemSettings, so this is what an
# embedded game gets -- and an embed should play the cart as the cart is.
var sgbRequested  = false
var sgbBorderWanted = true
var optGbaBiosMode: cint = 0  # 0 = HLE, 1 = real BIOS, 2 = real BIOS boot + HLE SWIs
var optGbaRunBios = true
var optMp2kHle = false        # MP2K sound-engine HLE (opt-in, engages on detection)

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
  result = new_gba(bios, rom_path,
                   run_bios = have_bios and optGbaRunBios,
                   use_hle = mode == 0,
                   hle_after_bios = mode == 2)
  result.mp2k_hle = optMp2kHle

# LCD response (common/lcd_response.nim): a per-pixel model of how the real
# panel settles, replacing the old "average the last two frames" blend. Some
# games flicker a sprite every other frame and let the screen's slow response
# turn it into a translucent one; a panel model renders that the way the
# hardware did instead of strobing. Presentation-only — emulation is untouched,
# so it is safe to change mid-frame. `lcdResp` follows the module-scope rule:
# its seqs stay empty here and are allocated from JS-invoked procs only.
var lcdMode = lmOff
var lcdResp: LcdResponse

proc sync_lcd_panel() =
  ## Resolve lmAuto against whatever core is running. Cheap when nothing
  ## changed (set_panel early-outs); rebuilds the table on a core switch.
  let gb = stateKind == ekGB and stateGb != nil
  lcdResp.set_panel(lcdMode.resolve(
    gba = stateKind == ekGBA,
    cgb = gb and stateGb.cgb_enabled,
    sgb = gb and stateGb.sgb_active()))

proc wasm_set_lcd_response(mode: cint) {.exportc.} =
  ## 0 = off, 1 = auto, 2 = dmg, 3 = cgb, 4 = agb, 5 = ags (LcdMode ordinals).
  lcdMode = if mode >= ord(low(LcdMode)) and mode <= ord(high(LcdMode)):
              LcdMode(mode) else: lmOff
  sync_lcd_panel()
  lcdResp.reset()   # drop stale cell state (also on core/resolution switch)

proc wasm_set_mp2k_hle(on: cint) {.exportc.} =
  ## Toggle MP2K/M4A sound-engine HLE ("Improve audio quality"): remembered for
  ## cores created later (make_gba) AND applied to the live GBA core, so the
  ## settings switch works mid-game. Arming it costs nothing on its own — the
  ## HLE only engages when the runtime detection actually finds the engine.
  optMp2kHle = on != 0
  if stateKind == ekGBA and stateGba != nil:
    stateGba.mp2k_hle = optMp2kHle

proc wasm_mp2k_available(): cint {.exportc.} =
  ## 1 when the loaded ROM's MP2K engine was detected (HLE can do something).
  if stateKind == ekGBA and stateGba != nil and stateGba.mp2k != nil and
     stateGba.mp2k.engaged: 1 else: 0

proc wasm_hle_audio_active(): cint {.exportc.} =
  ## 1 when a sound-engine HLE is enabled AND actually substituting audio right
  ## now — i.e. its driver was detected and its mixer is live. Covers both the
  ## MP2K/M4A HLE (engaged + mixer_live: engaged alone can idle while the game
  ## streams its own audio, see mixer_live) and the Camelot "Bon" driver HLE
  ## (Golden Sun). Drives the top-bar "HLE audio" indicator note.
  if stateKind != ekGBA or stateGba == nil or not stateGba.mp2k_hle: return 0
  if stateGba.mp2k != nil and stateGba.mp2k.engaged and
     stateGba.mp2k.mixer_live(): return 1
  if stateGba.gs_bon != nil and stateGba.gs_bon.engaged: return 1
  return 0

# --- WebGL2 present path ---
# The web front end no longer presents the game through SDL's renderer. Each
# frame it uploads the RAW BGR555 framebuffer (this pointer) to a WebGL2
# texture and a GLSL ES 300 shader does the LCD color correction + scanlines on
# the GPU (see web/index.js). This removes the per-frame CPU color-correction
# LUT that used to run here — a measurable win on the JIT-throttled iPhone. The
# LUTs above survive only for the low-rate consumers of wasm_fb_ptr (ambient
# glow, paused-game thumbnail).
#
# The LCD response stays on the CPU and works on the raw 5-bit channels
# (cheap, and only when enabled); the responded raw frame is what gets
# uploaded. It runs once per EMULATED frame here rather than per present, so
# the panel advances in emulated time — a 120 Hz display or a dropped present
# cannot change how the screen settles.
var gamePtr: pointer = nil       # pointer JS uploads this frame

proc prepare_game_frame(fb: ptr UncheckedArray[uint16]; pixels: int) =
  ## Point gamePtr at the pixels JS should upload this frame: the core's raw
  ## framebuffer directly (zero-copy) or, with the LCD response on, the panel's
  ## own output. No color conversion happens here — that is the shader's job.
  if lcdMode != lmOff: sync_lcd_panel()
  gamePtr = cast[pointer](lcdResp.apply(fb, pixels))

proc wasm_game_fb_ptr(): pointer {.exportc.} =
  ## Pointer to this frame's raw BGR555 framebuffer for the WebGL2 uploader
  ## (16-bit little-endian; the shader masks 0x7FFF). Valid after the last
  ## loop_tick/netlink_tick/rewind of the RAF turn.
  gamePtr

# --- Super Game Boy ---------------------------------------------------------
# The border is a second layer, not a bigger framebuffer: the core keeps
# emitting 160x144 and the presenter composites 256x224 around it. That is what
# keeps thumbnails, rewind, save states and the link/rollback blit paths on the
# dimensions they have always had.

proc wasm_sgb_enable(on: cint) {.exportc.} =
  ## Frontend opt-in, consulted the next time a ROM is loaded. The cart header
  ## still decides: a cart without the SGB flag, or one that is CGB-capable,
  ## never gets an adapter.
  sgbRequested = on != 0

proc wasm_sgb_active(): cint {.exportc.} =
  ## 1 when the running core actually has an SGB adapter. Drives the UI (the
  ## DMG shade palette has nothing to substitute once SGB colour is on).
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
  ## Bumped whenever the border image is re-rendered. The presenter re-uploads
  ## only when it moves: the image changes a handful of times in a session and
  ## it is 112 KiB.
  if stateKind == ekGB and stateGb != nil and stateGb.sgb_active():
    cint(stateGb.sgb_border_gen()) else: 0

proc wasm_sgb_backdrop(): cint {.exportc.} =
  ## SGB colour 0, shared by all four screen palettes. Shows wherever the
  ## border is transparent and the Game Boy window is not.
  if stateKind == ekGB and stateGb != nil and stateGb.sgb_active():
    cint(stateGb.sgb_backdrop()) else: 0

proc wasm_out_w(): cint {.exportc.} =
  ## The presented picture's native width. This is what the canvas backing
  ## store and the CSS aspect ratio are sized from -- it replaces guessing the
  ## console from the ROM's file extension, and it is the only source that can
  ## know a border appeared mid-session.
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
  ## 1 when the running single core is GB/GBC (selects the CGB color model in
  ## the shader), 0 for GBA. Drives the panel_gbc uniform.
  if stateKind == ekGB: 1 else: 0

# --- Ambient-glow sampler ---------------------------------------------------
#
# The glow is a 24x16 halo blurred behind the screen, so what it must sample is
# WHAT THE USER SEES, not what the core emitted. Those stopped being the same
# thing when the Super Game Boy border landed: sampling the game framebuffer
# under a border means the halo is a blur of a picture whose edges are hidden
# behind 48 columns and 40 rows of SNES art, so Pokemon Blue's overworld greens
# bleed out from behind a Poke Ball border that is mostly blue.
#
# So this composites the way the presenter does -- border over Game Boy window
# over backdrop -- and it does it HERE rather than in JS because this is where
# the colour LUT lives. A second copy of the panel model in JS would drift the
# moment a new correction curve is added on one side only.
#
# What it deliberately does NOT sample, and why:
#
#   * upscale filters (hq4x / xBR). At one sample per ~100 output pixels the
#     filter cannot change the answer, and running it would cost real work for
#     a difference nobody can see.
#   * scanlines. They darken every other row by 28%; a point sample lands on
#     the dark row about half the time, so the halo would flicker in brightness
#     as an artefact of WHERE the grid fell rather than of the picture.
#   * integer-scale letterboxing. The bars are black and are not part of the
#     picture; sampling them would wash the glow toward black in exactly the
#     configuration where the screen is smallest and the glow matters most.
#
# In short: the composited picture, before presentation effects. That is the
# stage that answers "what colour is the screen", which is the only question
# the glow asks.
#
# The DMG shade palette is passed IN rather than stored. It is a presentation
# choice that deliberately never reaches the core (that is what keeps save
# states, rewind and netplay byte-identical), and an argument to a read-only
# sampler keeps it that way while still letting the halo match the screen.

var glowBuffer: seq[uint32]

proc wasm_glow_sample(gw, gh: cint; remap: cint;
                      p0, p1, p2, p3: uint32): pointer {.exportc.} =
  ## Point-sample the COMPOSITED picture into a gw x gh RGBA8888 buffer.
  ## One sample per cell, deliberately: an area average over the same grid was
  ## measured at 20x the cost for a difference invisible behind the blur.
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
    # Straight 5->8 bit, no panel model: border art and the backdrop are native
    # SNES output and the shader does not correct them either.
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
          # The shade palette is an exact 4-way substitution on the DMG words,
          # and a chosen palette is already in display space, so it bypasses
          # the panel model here exactly as it does in the shader.
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
  ## Corrected RGBA8888 of the CURRENT single-core framebuffer, converted on
  ## demand. No longer on the per-frame present path: only the ambient-glow
  ## sampler (~10 Hz) and the paused-game thumbnail (one-shot) call this, so the
  ## color-correction LUT runs at their low cadence instead of every frame.
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

# Global audio sample buffer for JS to consume via Web Audio API.
# The APU appends float32 stereo samples here; JS reads and clears after each frame.
var audioBuffer: seq[float32] = @[]

# True while a muted core's etAPUSample event is being dispatched (2P link
# mode plays player 1's APU only — see link_init). The sample is computed
# and the event rescheduled exactly as usual; only the append is dropped, so
# emulation stays bit-identical between the two linked cores.
var audioSuppressed = false

# Slow motion (0.5x): JS doubles the per-frame wall-clock step, so the core
# produces half the samples per second the AudioContext consumes. Emitting
# each sample twice restores the realtime rate, pitched down an octave — the
# classic slow-mo sound (the inverse of wasm_set_turbo's drop-every-other).
# (A WSOLA pitch-preserving variant was tried and rejected: it sounded worse
# than the honest octave drop.)
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
  ## frames per wall-clock second (the JS tick loop halves its frame step).
  ## In online rollback the live cores are the session's, not stateGba/stateGb —
  ## set turbo on those so 2x audio is decimated there too (both peers run 2x in
  ## lockstep, so this is safe; turbo only affects sample output, not timing).
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
  ## Slow motion is single-core only (the linked modes gate it off in JS), so
  ## unlike turbo there is no rollback-core mirroring to do here.
  slowmoStretch = on != 0

proc wasm_set_pitch_correct_ff(on: cint) {.exportc.} =
  ## Local audio preference: when on, 2x speed uses a WSOLA time-stretch so the
  ## sound keeps its pitch instead of jumping an octave. Independent of the
  ## rollback-synced turbo state — it only changes how the local APU turns the
  ## full-rate stream into the half-count output the pacing expects, so it never
  ## affects timing or desyncs a link. Mirror onto the live rollback cores too.
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
  ## Why the last wasm_load_state returned 0, verbatim from the core. Empty
  ## before any failure. JS shows this instead of guessing: a version refusal
  ## and a wrong-ROM refusal used to render as the same sentence.
  cstring(last_state_error)

proc wasm_state_error_kind(): cint {.exportc.} =
  ## WHY the last wasm_load_state returned 0, as a StateRejectKind ordinal, so
  ## the UI writes its own sentence per cause instead of reformatting the
  ## core's wording. `wasm_state_error` stays available as the detail line.
  cint(ord(last_state_reject_kind))

proc wasm_load_state(data: pointer; len: cint; keepRewind: cint): cint {.exportc.} =
  ## Validate and apply a state image (same bytes as desktop .state files).
  ## Returns 1 on success; 0 on rejection (version/core/ROM mismatch or
  ## corruption — the reason is echoed to the log) with the core untouched.
  ##
  ## Success normally drops the rewind ring (see below). keepRewind != 0 is for
  ## the one caller that is putting the SAME timeline back — undoing a scrubber
  ## commit — where the retained snapshots really are this state's own past and
  ## throwing away minutes of history would make Undo cost more than the thing
  ## it undoes.
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
    # A loaded state starts a new timeline; the ring holds the old one. Keeping
    # both was already wrong for hold-to-rewind (holding it after a load walks
    # backward into a moment that never preceded the frame on screen), and the
    # scrubber makes it visible: the strip would show thumbnails from a
    # different part of the game sitting next to current ones, and offer to
    # "rewind" to one. Dropping the history is what mGBA and RetroArch do, and
    # the honest answer — there is no path from here back to there.
    rewindHistory.clear()
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
  ## 1 while the running single-core cart's rumble motor is on: GB MBC5
  ## rumble carts (types 0x1C-0x1E) or GBA GPIO rumble carts (Drill Dozer,
  ## WarioWare: Twisted!). Link modes and no-core return 0 — stateKind is
  ## only set in single-core sessions, so no mode check is needed. JS polls
  ## this each RAF tick to drive haptics + screen shake.
  if stateKind == ekGB and stateGb != nil and stateGb.cartridge.mbc_rumble(): 1
  elif stateKind == ekGBA and stateGba != nil and stateGba.bus.gpio.gpio_rumble(): 1
  else: 0

proc wasm_set_tilt(x, y: cdouble) {.exportc.} =
  ## Tilt-cart accelerometer input, -1.0 .. 1.0 per axis (transients may
  ## exceed 1 for flick gestures), 0 = level. Routed to the GB cartridge
  ## (MBC7 — Kirby Tilt 'n' Tumble) or the GBA tilt window (Yoshi's
  ## Universal Gravitation); a no-op everywhere else, so JS can feed it
  ## unconditionally while a tilt cart is detected.
  if stateKind == ekGB and stateGb != nil:
    stateGb.cartridge.set_accelerometer(float(x), float(y))
  elif stateKind == ekGBA and stateGba != nil:
    if stateGba.bus.tilt_present:
      stateGba.bus.tilt_in_x = float(x)
      stateGba.bus.tilt_in_y = float(y)
    elif stateGba.bus.gpio.gyro_present:
      # Gyro carts are rate sensors: x carries the rotation rate (CW
      # positive, -1..1 = the hard-rotation extremes); y is unused.
      stateGba.bus.gpio.gyro_z = float(x)

proc wasm_cart_has_tilt(): cint {.exportc.} =
  ## Motion-cart kind: 0 = none, 1 = tilt/accelerometer (GB MBC7, GBA Yoshi),
  ## 2 = gyro rate sensor (WarioWare Twisted). Lets JS pick the input model
  ## and decide whether to request motion permission at ROM load.
  if stateKind == ekGB and stateGb != nil and stateGb.cartridge of Mbc7: 1
  elif stateKind == ekGBA and stateGba != nil and stateGba.bus.tilt_present: 1
  elif stateKind == ekGBA and stateGba != nil and stateGba.bus.gpio.gyro_present: 2
  else: 0

# --- Retroactive clip capture (prototype) ---
# "Save the last N seconds" without recording video: a rolling ring of state
# snapshots (one per second) plus a per-frame input log (2 bytes/frame).
# Deterministic replay from the nearest anchor reconstructs the exact frames
# the player saw — the same state+inputs determinism rollback netplay relies
# on. JS drives clip_tick once per RAF at realtime while a MediaRecorder
# captures the canvas + audio; the live game state is stashed and restored
# around the replay. Single-core only. Presentation-only, never serialized.
# (Known divergence: the GBA RTC reads wall clock, so an RTC game's replayed
# clock can differ by up to the clip length — cosmetic.)
const CLIP_SNAP_INTERVAL = 60          # anchor snapshot cadence (frames)
const CLIP_MAX_FRAMES = 12 * 60        # rolling history window (~12 s)
var clipSnaps: seq[tuple[frame: int, payload: string]] = @[]
var clipInputs: seq[uint16] = @[]      # button mask per canonical frame
var clipInputsStart = 0                # absolute frame of clipInputs[0]
var clipFrameIndex = 0                 # canonical frames since core init
var clipCurButtons: uint16 = 0         # live mask, mirrored from setInput
var clipLiveStash = ""                 # live state while a replay runs
var clipCursor = 0
var clipEnd = 0
var clipReplaying = false

proc clip_reset() =
  clipSnaps.setLen(0)
  clipInputs.setLen(0)
  clipInputsStart = 0
  clipFrameIndex = 0
  clipCurButtons = 0
  clipLiveStash = ""
  clipReplaying = false

proc clip_note_frame() =
  ## Called once per canonical frame BEFORE it steps: log the held buttons
  ## and drop history that has aged out of the window.
  if clipReplaying: return
  if clipFrameIndex mod CLIP_SNAP_INTERVAL == 0:
    let payload = case stateKind
      of ekGBA: stateGba.state_payload()
      of ekGB:  stateGb.state_payload()
      of ekNone: ""
    if payload.len > 0:
      clipSnaps.add((clipFrameIndex, payload))
  clipInputs.add(clipCurButtons)
  inc clipFrameIndex
  let oldest = clipFrameIndex - CLIP_MAX_FRAMES
  while clipSnaps.len > 1 and clipSnaps[1].frame <= oldest:
    clipSnaps.delete(0)
  if clipSnaps.len > 0 and clipInputsStart < clipSnaps[0].frame:
    let drop = clipSnaps[0].frame - clipInputsStart
    if drop > 0 and drop <= clipInputs.len:
      clipInputs = clipInputs[drop .. ^1]  # ≤720 u16s, copying is trivial
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

proc clip_begin(seconds: cint): cint {.exportc.} =
  ## Arm a replay of roughly the last `seconds`. Stashes the live state and
  ## rewinds the core to the best anchor. Returns the number of frames the
  ## replay will run (JS steps them via clip_tick), or 0 if there is no
  ## usable history / a linked mode is active.
  if stateNet != nil or stateLink != nil or stateGbLink != nil: return 0
  if stateRollback != nil or stateGbRollback != nil: return 0
  if clipReplaying or clipSnaps.len == 0: return 0
  let want = clipFrameIndex - int(seconds) * 60
  var pick = 0
  for i in 0 ..< clipSnaps.len:
    if clipSnaps[i].frame <= want: pick = i
    else: break
  # Prefer covering the full window: if even the oldest anchor is newer than
  # `want`, use it anyway (short clip beats no clip).
  let anchor = clipSnaps[pick]
  clipLiveStash = case stateKind
    of ekGBA: stateGba.state_payload()
    of ekGB:  stateGb.state_payload()
    of ekNone: ""
  if clipLiveStash.len == 0: return 0
  if not clip_apply_payload(anchor.payload):
    clipLiveStash = ""
    return 0
  clipCursor = anchor.frame
  clipEnd = clipFrameIndex
  clipReplaying = true
  # A replay re-sends serial bytes the printer already processed live —
  # mute it (reply 0, mutate nothing) for the duration.
  if statePrinter != nil: statePrinter.muted = true
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
# Every solo GB core has a printer plugged in from the start (see the note
# in gb/printer.nim: asking first cannot work, the opening INIT resolves
# inside one frame). Finished prints queue in the printer's outbox; JS pops
# them as 8-bit grayscale for the photo gallery.
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
# The Pocket Camera cart is fully emulated (sensor model, exposure, dither —
# gb/mbc/camera.nim) but fed a synthetic scene by default. When the user
# opts in, JS fills this 128x120 luminance buffer from getUserMedia frames
# and the sensor proc reads it. Allocated from JS-invoked procs only (the
# module-teardown rule — see rewindHistory above).
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
  ## Point the emulated sensor at the JS-fed buffer (getUserMedia granted).
  ## Returns the buffer length so JS can bound its writes.
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
  # During a retroactive-capture replay the input LOG owns the core; live
  # presses only update the mask above, which clip_tick re-applies when the
  # replay ends — so what the player holds through the capture carries over.
  if clipReplaying: return
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
# (Declared up top beside statePrinter so wasm_load_state can clear it.)

# Memory cap for rewind rings created from here on (default REWIND_CAP_BYTES,
# 64 MB). JS lowers this on memory-constrained platforms (iOS Safari, where
# process-level pressure gets the wasm JIT demoted) by calling the setter at
# runtime-init time — before the first ROM load, so every new_rewind() call
# site (initFromEmscripten, netlink_exit) picks it up.
var rewindCapBytes: int = REWIND_CAP_BYTES

proc setRewindCapBytes(n: cint) {.exportc.} =
  if n > 0: rewindCapBytes = int(n)

# Master on/off for rewind, mirroring the native `rewind` config toggle. ON is
# the default on both frontends; JS calls the setter from its settings load and
# whenever the user flips the switch. Off means the ring is never allocated, so
# loop_tick's `rewindHistory != nil` guard skips the per-interval
# state_payload() + thumbnail push outright — the whole point is to give the
# CPU back, not just to hide the button.
#
# Live both ways, so the web UI needs no reload: turning it off drops the ring
# (and its memory) immediately, turning it back on allocates a fresh, empty one
# for the session already running. History does not survive a trip through
# "off" — there is nothing to keep it in.
var rewindEnabled: bool = true

proc setRewindEnabled(on: cint) {.exportc.} =
  rewindEnabled = on != 0
  if not rewindEnabled:
    rewindHistory = nil
  elif rewindHistory == nil and stateKind != ekNone and stateNet == nil:
    # Only for a live single core. The linked modes (2P, online, rollback)
    # deliberately keep the ring nil — rewinding one side desyncs the pair —
    # and they tear the single-core session down (stateKind = ekNone) or hold
    # stateNet, so both are excluded here rather than by a mode flag.
    rewindHistory = new_rewind(rewindCapBytes)

# Scrubber thumbnails are captured at push time, while the framebuffer that
# belongs to the snapshot is still the one on screen. Same 120-wide geometry
# (and BGR555 layout) as the save-state thumbnail trailer — see gba_thumbnail
# / gb_thumbnail in the two savestate.nim files.
const SCRUB_THUMB_W = 120
const GBA_SCRUB_THUMB_H = SCRUB_THUMB_W * GBA_H div GBA_W  # 3:2  -> 120x80
const GB_SCRUB_THUMB_H  = SCRUB_THUMB_W * GB_H  div GB_W   # 10:9 -> 120x108

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
  # Drain SDL events BEFORE stepping so anything they carry (keyboard input
  # on the SDL path) lands in the frame about to run rather than the next
  # one. The JS gameKeyHandler path is unaffected — it applies at event time.
  checkInput()
  clip_note_frame()  # retroactive-capture history (inputs + 1/s anchors)
  case stateKind
  of ekGBA:
    if stateTexture == nil: return
    stateGba.step_frame()
    if rewindHistory != nil:
      discard rewindHistory.maybe_push(
        proc(): string = stateGba.state_payload(),
        proc(): RewindThumb = gba_rewind_thumb(stateGba))
    # gamePtr is refreshed every frame (even static ones) so the WebGL2
    # uploader always has a valid pointer; the blend path decays a lingering
    # ghost into a static picture rather than freezing it in.
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
  # No SDL present here anymore: JS uploads gamePtr to WebGL2 and draws once
  # per RAF turn (see drawGame in web/index.js).

# Run-ahead (latency reduction, RetroArch's single-instance method): most
# GB/GBA games poll input 1-3 frames before the result reaches the screen.
# Each tick runs one canonical frame (audio kept), snapshots, silently runs N
# more frames with the same input, PRESENTS that future frame, then restores
# the snapshot — so the pixels on screen are the ones the game will show N
# frames from now, and a button press appears to take effect N frames sooner.
# The future framebuffer must be retained in its own buffer: ppu.framebuffer
# is serialized, so apply_state_payload would revert the pixels gamePtr
# points at before JS uploads them. Full notes: docs/run-ahead.md.
var runaheadFrame: seq[uint16] = @[]

proc runahead_tick(n: cint) {.exportc.} =
  ## loop_tick with N frames of run-ahead. n <= 0 behaves exactly like
  ## loop_tick. Single-core modes only: the linked modes are frame-synced
  ## with a peer (running ahead would desync them), 2P link already runs two
  ## cores per frame (run-ahead would multiply that), and in every linked
  ## mode stateGba/stateGb may point at a stale single-core session — the
  ## guards below make a mistimed JS call a no-op instead of stepping it.
  if stateRenderer == nil: return
  if stateNet != nil: return
  if stateLink != nil or stateGbLink != nil: return
  if stateRollback != nil or stateGbRollback != nil: return
  if clipReplaying: return
  inc frameCount
  checkInput()
  clip_note_frame()  # canonical frames only — lookahead steps are not history
  case stateKind
  of ekGBA:
    if stateTexture == nil: return
    stateGba.step_frame()  # canonical frame: this one's audio is played
    if rewindHistory != nil:
      discard rewindHistory.maybe_push(
        proc(): string = stateGba.state_payload(),
        proc(): RewindThumb = gba_rewind_thumb(stateGba))
    if n <= 0:
      prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                         GBA_W * GBA_H)
      return
    let snap = stateGba.state_payload()
    audioSuppressed = true  # lookahead frames' audio is thrown away
    for _ in 0 ..< int(n): stateGba.step_frame()
    audioSuppressed = false
    if runaheadFrame.len != GBA_W * GBA_H: runaheadFrame.setLen(GBA_W * GBA_H)
    copyMem(addr runaheadFrame[0], addr stateGba.ppu.framebuffer[0], GBA_W * GBA_H * 2)
    try:
      stateGba.apply_state_payload(snap)
    except CatchableError:
      discard  # snapshot came from this same build one call ago; unreachable
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
    # Lookahead frames feed the printer bytes the canonical timeline hasn't
    # sent yet — snapshot around them so no phantom packet/print survives.
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
  # JS draws the restored frame (drawGame) after this returns.
  1

# --- Rewind scrubber (bug-report timeline) ---
# Hands JS a strip of thumbnails sampled across rewind history so it can
# present a timeline and let the user pick the moment a bug happened.
#
# The strip is COPIED out of the ring, which stored each picture when its
# snapshot was pushed. It used to be rendered here on demand: apply every
# sampled snapshot to the live core and downscale the framebuffer it carries.
# That was O(entire history), not O(samples) — reaching sample 47 meant
# inflating every delta in front of it. Measured in this browser build on a
# full 64 MB ring (Advance Wars, 4.6 min of history): opening the report modal
# went 1379 ms -> 17 ms, and picking the oldest sample 1341 ms -> 38 ms (the
# keyframes do that half). Nothing is applied to the live core now, so opening
# the modal no longer disturbs the running game at all.

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
  ## Collect up to maxSamples thumbnails sampled evenly across the stored
  ## strip (newest first). Returns the sample count; 0 when there is no
  ## history. O(samples): one small inflate each, nothing walked.
  scrubThumbs = @[]
  scrubIds = @[]
  if rewindHistory == nil or stateKind == ekNone: return 0
  let count = rewindHistory.thumb_count
  if count == 0: return 0
  # Spread the samples over the WHOLE strip: n evenly spaced picks, first the
  # newest and last the oldest. A fixed stride leaves a ragged tail (and never
  # reaches the oldest thumbnail at all when the count doesn't divide).
  let n = min(max(1, int(maxSamples)), count)
  for s in 0 ..< n:
    let i = if n == 1: 0 else: s * (count - 1) div (n - 1)
    let t = rewindHistory.thumb_at(i)
    if t.pixels.len == 0: continue  # (unreachable) never a hole in the strip
    # Geometry is fixed per core for the life of the ring, so the last one
    # read is the one that describes every entry in the strip.
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
  ## Approx wall-clock age of a sample, in tenths of a second (snapshots are
  ## rewindHistory.snapshot_interval frames apart at ~60 fps). Measured in
  ## snapshots back from the newest, so a rewind that shortened history moves
  ## the answer with it.
  if sample < 0 or sample >= scrubIds.len or rewindHistory == nil: return 0
  let index = rewindHistory.index_of_id(scrubIds[sample])
  if index < 0: return 0
  let frames = index * rewindHistory.snapshot_interval
  cint(frames * 10 div 60)

proc wasm_rewind_scrub_state_size(sample: cint): cint {.exportc.} =
  ## Reconstruct the chosen sample's snapshot, build its full .state image
  ## (header + payload + thumbnail) into the shared stateImage buffer, restore
  ## the live core, and return the size. Read the bytes via wasm_state_data().
  if sample < 0 or sample >= scrubIds.len or rewindHistory == nil:
    return 0
  # By absolute ID: the strip was captured before the modal opened, and a
  # positional index would quietly slide onto a different moment if anything
  # evicted in between.
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

# --- Committing to a scrubbed moment --------------------------------------
# The scrubber's other two questions: "would this cost me my in-game save?"
# and "make it so".

proc cart_save_bytes(): seq[byte] =
  ## The cartridge's battery-backed save data and NOTHING else — the bytes
  ## that reach the .sav file.
  ##
  ## Deliberately not the whole storage section of the payload: that section
  ## also carries controller state (flash bank + command phase, the EEPROM
  ## shift register and address latch), which differs between two moments
  ## whenever a save happened to be mid-command, with no user-visible save
  ## data difference at all. Comparing the section wholesale would raise the
  ## "this discards your save" prompt on games that merely poll their flash
  ## chip — the fastest way to teach players to click through it.
  case stateKind
  of ekGBA:
    if stateGba != nil and stateGba.storage != nil: stateGba.storage.memory
    else: @[]
  of ekGB:
    # No battery means no .sav: the RAM is scratch that dies with the console,
    # so rolling it back costs the player nothing to warn about.
    if stateGb != nil and stateGb.cartridge != nil and stateGb.cartridge.has_battery:
      stateGb.cartridge.ram
    else: @[]
  of ekNone: @[]

proc wasm_rewind_scrub_save_differs(sample: cint): cint {.exportc.} =
  ## 1 when committing to `sample` would change the cartridge save data, 0 when
  ## it would leave it byte-identical (or there is nothing to compare).
  ##
  ## Exact, both ways: a full byte comparison of the save region, so it cannot
  ## miss a changed save, and it cannot invent one either. What it does NOT
  ## know is the player's intent — a game that scribbles in SRAM without the
  ## player ever choosing "Save" still reports a difference. That is the safe
  ## direction, and the claim the UI makes ("would change your in-game save
  ## data") is literally true in that case.
  ##
  ## Per-call stash and restore. Holding a stash across the sheet's lifetime
  ## would be cheaper, but every early return, ROM switch or exception in
  ## between becomes a silently corrupted live session; one round trip is
  ## ~4 ms, which nobody can see.
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
  ## Rewind the live core to `sample` and throw the future away: every
  ## snapshot newer than it leaves the ring, so the strip, hold-to-rewind and
  ## the next push all agree that this is now the newest moment. Returns 1 on
  ## success, 0 when the sample is gone or a linked mode owns the core.
  ##
  ## JS keeps its own pre-commit state image for the Undo toast. That is a
  ## safety net over the next few seconds, not a second branch of history —
  ## nothing here preserves the discarded snapshots.
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
  # The printer's protocol state is not in the payload, so it is now ahead of
  # the core it is wired to (see resync's note).
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

# --- 2P local link mode (multiplayer phase 3, web side) ---
# Two GBA cores running the same ROM, wired by the in-process lockstep link
# (gba/link.nim). The SDL renderer/canvas only serves the single-core path,
# so in link mode JS drives frames via link_tick and blits each core's
# framebuffer itself from the per-core RGBA buffers below (converted through
# the same color LUT as the single-core present path). Globals are nil/empty
# at module scope and only ever allocated from JS-invoked procs — this
# build's main() returns after init and Nim's exit teardown would leave
# module-init heap globals dangling (see rewindHistory above).
# (stateLink / stateGbLink are declared up top beside stateNet so earlier
# procs — runahead_tick's link guard — can reference them.)
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
# stateRollback / stateGbRollback are declared up top (near stateNet) so
# wasm_set_turbo can reach the live cores; rbLocal is this peer's core index.
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
    stateGbRollback = nil
    audioSuppressed = false
    stateGb = gcore
    stateKind = ekGB
    # Back to solo play: the peer's cable is gone, so plug the printer in
    # (every solo GB core keeps one — see the printer block above). This
    # replaces the old "unplugged, null driver" binding.
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
  lcdResp.reset()
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

# ──────────────────────────── Cheats ────────────────────────────

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

# Returned to JS across calls; must outlive the proc, so keep it in a global.
var cheatErrBuf: string

proc load_cheats(text: cstring): cstring {.exportc.} =
  ## Replace the current game's cheat list with the serialized blob from JS
  ## (the `.cht` text format). Returns a newline-separated list of parse errors
  ## ("name: message"), or "" when every cheat parsed cleanly.
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
  # Leaving 2P link mode for a single-core session
  link_exit()
  clip_reset()  # capture history belongs to the previous core
  statePrinter = nil  # the printer belongs to the previous core
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
    curRomCrcValid = false  # the cached CRC belongs to a GBA cart
    let bootrom = if fileExists("bootrom.bin"): "bootrom.bin" else: ""
    stateGb = new_gb(bootrom, path, optGbFifo, false, bootrom.len > 0)
    stateGb.sgb_requested = sgbRequested
    stateGb.post_init()
    printer_attach()  # a printer is always plugged in on solo GB
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
    # Hash the cartridge buffer over its true (unpadded) length — the same
    # bytes a peer gets from hashing the file, so the wire value is unchanged.
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
  lcdResp.reset()  # the panel state is per-core (and per-resolution)
  rewindHistory = if rewindEnabled: new_rewind(rewindCapBytes) else: nil

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
  stateNet = new_net_core(stateGba, id = (if is_host != 0: 0 else: 1),
                          rom_crc = curRomCrc,
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
  if not curRomCrcValid: return 0
  rewindHistory = nil  # rewinding one side would desync the pair
  stateNet = new_net_core(stateGba, id = (if is_host != 0: 0 else: 1),
                          rom_crc = curRomCrc,
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
  rewindHistory = if rewindEnabled: new_rewind(rewindCapBytes) else: nil

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
    prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0]),
                       GBA_W * GBA_H)
    checkInput()
    # JS uploads gamePtr to WebGL2 and draws after this tick (netStep path).
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
