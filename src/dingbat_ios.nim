# iOS C API for the core (static library, ios/build-core.sh; header
# ios/include/dingbat.h), the sibling of src/dingbat_wasm.nim: the same
# features the web build exports, under dingbat_* names.
#
# Audio is pull-based: the build omits -d:test_harness/-d:emscripten so the
# APUs take their desktop SDL2-queue path, and src/dingbat_ios_audio.c provides
# those SDL2 symbols as a ring buffer drained from an AVAudioSourceNode render
# block. Pacing is the desktop model: the shell runs frames only while
# dingbat_audio_ahead() is 0, so the 32768 Hz audio clock paces emulation; the
# C file breaks get_sample()'s blocking backstop after ~250 ms of stalled
# playback so the shell cannot deadlock.
#
# Every function here must be called from one thread (the shell's main thread
# via CADisplayLink); only the plain-C dingbat_audio_* functions are safe from
# the CoreAudio render thread.

import std/[os, strutils, math]
import zippy  # clip anchors and their thumbnails are stored deflated
import dingbat/common/input
import dingbat/common/rewind
import dingbat/common/serialize
import dingbat/common/cheats
import dingbat/common/lcd_response
import dingbat/common/rom_exts
import dingbat/common/scheduler
import dingbat/gba/gba
import dingbat/gba/link as gbalink
import dingbat/gba/rollback as gbarb
import dingbat/gb/gb
import dingbat/gb/link as gblink
import dingbat/gb/rollback as gbrb
import dingbat/gb/printer

{.compile: "dingbat_ios_audio.c".}

const GBA_W = 240
const GBA_H = 160
const GB_W  = 160
const GB_H  = 144

type EmuKind = enum ekNone, ekGBA, ekGB

var stateKind: EmuKind = ekNone
var stateGba:  GBA     = nil
var stateGb:   GB      = nil
var romPath:   string  = ""
var biosPath:  string  = ""
var statePrinter: GbPrinter = nil      # always attached on a GB core
var rewindHistory: Rewind = nil

# Clip capture state (the procs are at the end, "Retroactive clip capture").
const CLIP_SNAP_INTERVAL = 60          # anchor + thumbnail cadence (frames)
const CLIP_MAX_FRAMES = 60 * 60        # rolling history window (~60 s)
const CLIP_CAP_BYTES = 24 * 1024 * 1024

type ClipAnchor = object
  frame: int          # canonical frame index this state is the start of
  packed: string      # zlib'd state payload
  thumb: seq[byte]    # zlib'd BGR555 thumbnail (may be empty)
  tw, th: int

var clipCapBytes = CLIP_CAP_BYTES
var clipAnchors: seq[ClipAnchor] = @[]
var clipAnchorBytes = 0
var clipInputs: seq[uint16] = @[]      # button mask per canonical frame
var clipInputsStart = 0                # absolute frame of clipInputs[0]
var clipFrameIndex = 0                 # canonical frames since core init
var clipCurButtons: uint16 = 0         # live mask, mirrored from set_input
var clipLiveStash = ""                 # live state while a replay runs
var clipCursor = 0
var clipEnd = 0
var clipReplaying = false

# Online link (input rollback, web rollback_*): both players' cores run here
# and only inputs cross the network. While a session runs, its local core is
# also stateGba/stateGb, so the picture, audio and save exports serve it;
# everything that would move that core outside the session (frames, input,
# states, rewind, cheats, reset) refuses.
var rbGba: gbarb.RollbackSession = nil
var rbGb: gbrb.GbRollbackSession = nil
var rbLocal = 0                         # the core this player drives
var rbEpoch: int64 = 0                  # the shared RTC clock
proc rb_active(): bool {.inline.} = rbGba != nil or rbGb != nil
proc dingbat_rollback_exit() {.exportc, cdecl.}
# Local 2P (web link_*): two cores of one ROM on the in-process cable. Player
# 1's core is the live one as above (its save is the game's, its sound the
# one heard); player 2's runs silent on its own battery file.
var lkGba: gbalink.Link = nil
var lkGb: gblink.GbLink = nil
proc lk_active(): bool {.inline.} = lkGba != nil or lkGb != nil
proc dingbat_link_exit() {.exportc, cdecl.}
## A session owns the live core: nothing outside it may move it.
proc core_shared(): bool {.inline.} = rb_active() or lk_active()

proc dingbat_audio_set_mode(mode: cint) {.importc, cdecl.}
proc dingbat_audio_get_mode(): cint {.importc, cdecl.}
proc clip_reset()


proc NimMain() {.importc.}
proc dingbat_audio_set_stretch(on: cint) {.importc, cdecl.}

# LCD color correction as BGR555 -> RGBA8888 tables, one per panel (the same
# models as dingbat_wasm.nim's build_color_luts and the Metal shader):
#  - GBA: linearize with gamma 4.0, mix channels, re-gamma with 2.2.
#  - GB/GBC: Pokefan531's "GBC-Color": gamma 2.2, luminance 0.94, matrix.
# Only the low-rate consumers (thumbnails, ambient glow) read these; the
# present path corrects in the shader.
var colorLutGba: array[0x8000, uint32]
var colorLutGbc: array[0x8000, uint32]
var rgbaBuffer: seq[uint32] = @[]
var colorCorrect = true

proc build_color_luts(correct: bool) =
  for i in 0 ..< 0x8000:
    let r5 = float64(i and 0x1F) / 31.0
    let g5 = float64((i shr 5) and 0x1F) / 31.0
    let b5 = float64((i shr 10) and 0x1F) / 31.0
    var gba, gbc: array[3, uint32]
    if correct:
      block:
        let r = pow(r5, 4.0)
        let g = pow(g5, 4.0)
        let b = pow(b5, 4.0)
        let mixed = [
          (  0.0 * b +  50.0 * g + 240.0 * r) / 255.0,
          ( 30.0 * b + 230.0 * g +  10.0 * r) / 255.0,
          (220.0 * b +  10.0 * g +  50.0 * r) / 255.0,
        ]
        for c in 0 .. 2:
          gba[c] = uint32(min(255.0, round(pow(mixed[c], 1.0 / 2.2) * 255.0)))
      block:
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

proc dingbat_init() {.exportc, cdecl.} =
  ## Must be called once before any other API; runs Nim module init. Safe to
  ## call again (later calls do nothing).
  var once {.global.} = false
  if once: return
  once = true
  NimMain()
  build_color_luts(colorCorrect)

# --- Options read at the next core construction (load or reset) ---
var optGbaBiosMode: cint = 0  # 0 = HLE, 1 = real BIOS, 2 = real BIOS boot + HLE SWIs
var optGbaRunBios = true
var optMp2kHle = false
var optFifoInterp = true
var optSgb = false
var optSgbBorder = true
var optGbModel: cint = 0      # 0 = from the cart header, 1 = DMG, 2 = CGB
var optSilent = false
var optVolume: cint = 100
var optMute = false
var chanMutes: cint = 0
var optTurbo = false
var optPitchCorrect = true
var optFastForward = false
var rewindEnabled = true
var rewindCapBytes = REWIND_CAP_BYTES

# LCD response (common/lcd_response.nim): presentation only.
var lcdOn = false
var lcdResp: LcdResponse
var gamePtr: pointer = nil

proc sync_lcd_panel() =
  let gb = stateKind == ekGB and stateGb != nil
  lcdResp.set_panel(lcdOn.resolve(
    gba = stateKind == ekGBA,
    cgb = gb and stateGb.cgb_enabled,
    sgb = gb and stateGb.sgb_active()),
    display_gamma = if stateKind == ekGBA and colorCorrect: 4.0 else: 0.0)

proc prepare_game_frame(fb: ptr UncheckedArray[uint16]; pixels: int) =
  if lcdOn: sync_lcd_panel()
  gamePtr = cast[pointer](lcdResp.apply(fb, pixels))

proc live_fb(): ptr UncheckedArray[uint16] =
  case stateKind
  of ekGBA: cast[ptr UncheckedArray[uint16]](addr stateGba.ppu.framebuffer[0])
  of ekGB:  cast[ptr UncheckedArray[uint16]](addr stateGb.ppu.framebuffer[0])
  of ekNone: nil

proc game_pixels(): int =
  if stateKind == ekGB: GB_W * GB_H else: GBA_W * GBA_H

proc present_live() =
  let fb = live_fb()
  if fb != nil: prepare_game_frame(fb, game_pixels())

proc apply_channel_mutes() =
  template mask(apu: untyped; n: int) =
    for i in 0 ..< n: apu.channel_mask[i] = (chanMutes and (1.cint shl i)) == 0
  case stateKind
  of ekGBA: mask(stateGba.apu, 6)
  of ekGB:  mask(stateGb.apu, 4)
  of ekNone: discard

proc apply_audio() =
  ## Every output-side option onto the live core; called after each build.
  optSilent = optMute or optVolume <= 0
  case stateKind
  of ekGBA:
    stateGba.apu.set_master_volume(int(optVolume), optMute)
    stateGba.set_audio_silent(optSilent)
    stateGba.apu.turbo = optTurbo
    stateGba.apu.set_pitch_correct_ff(optPitchCorrect)
    stateGba.apu.sync = not optFastForward
  of ekGB:
    stateGb.apu.set_master_volume(int(optVolume), optMute)
    stateGb.apu.silent = optSilent
    stateGb.apu.turbo = optTurbo
    stateGb.apu.set_pitch_correct_ff(optPitchCorrect)
    stateGb.apu.sync = not optFastForward
  of ekNone: discard
  # The friend's core: silent, and nothing of it reaches the audio ring.
  if rbGba != nil:
    let rc = rbGba.link.cores[1 - rbLocal]
    rc.set_audio_silent(true)
    rc.apu.audio_dev = 0
  if rbGb != nil:
    let rc = rbGb.link.cores[1 - rbLocal]
    rc.apu.silent = true
    rc.apu.audio_dev = 0
  if lkGba != nil:
    lkGba.cores[1].set_audio_silent(true)
    lkGba.cores[1].apu.audio_dev = 0
  if lkGb != nil:
    lkGb.cores[1].apu.silent = true
    lkGb.cores[1].apu.audio_dev = 0
  apply_channel_mutes()

proc flush_current_save() =
  case stateKind
  of ekGBA:
    if stateGba != nil:
      stateGba.storage.write_save()
  of ekGB:
    if stateGb != nil:
      stateGb.cartridge.mbc_save()
  of ekNone: discard

proc load_rom_impl(path, bios: string): cint =
  if not fileExists(path): return -1
  dingbat_rollback_exit()
  dingbat_link_exit()
  flush_current_save()
  let ext = path.splitFile().ext.toLowerAscii()
  statePrinter = nil
  try:
    if ext in GB_ROM_EXTS:
      stateKind = ekGB
      let bootrom = if bios.len > 0 and fileExists(bios): bios else: ""
      stateGb = new_gb(bootrom, path, false, bootrom.len > 0,
                       force_cgb = optGbModel == 2, force_dmg = optGbModel == 1)
      stateGb.sgb_requested = optSgb
      stateGb.post_init()
      statePrinter = new_gb_printer()
      stateGb.set_serial_driver(GbPrinterDriver(printer: statePrinter))
    else:
      stateKind = ekGBA
      let haveBios = bios.len > 0 and fileExists(bios)
      let mode = if haveBios: optGbaBiosMode else: 0
      stateGba = new_gba(if haveBios: bios else: "", path,
                         run_bios = haveBios and optGbaRunBios,
                         use_hle = mode == 0,
                         hle_after_bios = mode == 2)
      stateGba.post_init()
      stateGba.mp2k_hle = optMp2kHle
      stateGba.apu.set_fifo_interp(optFifoInterp)
    romPath = path
    biosPath = bios
    clip_reset()
    lcdResp.reset()
    rewindHistory = if rewindEnabled: new_rewind(rewindCapBytes) else: nil
    apply_audio()
    present_live()
    return 0
  except CatchableError:
    stateKind = ekNone
    stateGba = nil
    stateGb = nil
    gamePtr = nil
    return -2

proc dingbat_load_rom(rom_path: cstring; bios_path: cstring): cint {.exportc, cdecl.} =
  ## Battery saves live at `<rom minus extension>.sav` next to the ROM, so the
  ## path must be writable. Returns 0 on success, -1 if missing, -2 on core
  ## init failure.
  let bios = if bios_path != nil: $bios_path else: ""
  load_rom_impl($rom_path, bios)

proc dingbat_load_rom_bytes(data: pointer; len: cint; persist_path: cstring;
                            bios_path: cstring): cint {.exportc, cdecl.} =
  ## Write the image to persist_path (battery saves go alongside it) and load
  ## it. Returns dingbat_load_rom's codes, or -3 if the bytes could not be
  ## written.
  if data == nil or len <= 0 or persist_path == nil: return -3
  var image = newString(int(len))
  copyMem(addr image[0], data, int(len))
  try:
    writeFile($persist_path, image)
  except CatchableError:
    return -3
  dingbat_load_rom(persist_path, bios_path)

proc dingbat_unload(flush: cint) {.exportc, cdecl.} =
  ## Drop the core (closing a game), flushing its battery save first unless
  ## `flush` is 0: a copy let go for another device's newer one (Drive
  ## hand-off) must not write its RAM over the save landing in its place.
  if flush != 0: flush_current_save()
  if rb_active():
    if flush != 0: dingbat_rollback_exit()
    else:
      rbGba = nil
      rbGb = nil
      gbRtcNowOverride = -1
  if lk_active():
    if flush != 0: dingbat_link_exit()
    else:
      lkGba = nil
      lkGb = nil
  stateKind = ekNone
  stateGba = nil
  stateGb = nil
  statePrinter = nil
  rewindHistory = nil
  gamePtr = nil
  romPath = ""

proc dingbat_reset(): cint {.exportc, cdecl.} =
  ## Hard reset: flushes the battery save and reloads the current ROM.
  if stateKind == ekNone or romPath.len == 0 or core_shared(): return -1
  load_rom_impl(romPath, biosPath)

proc dingbat_loaded(): cint {.exportc, cdecl.} =
  if stateKind == ekNone: 0 else: 1

proc dingbat_is_gb(): cint {.exportc, cdecl.} =
  if stateKind == ekGB: 1 else: 0

proc dingbat_is_cgb(): cint {.exportc, cdecl.} =
  ## 1 for a Game Boy core running in colour mode (a DMG title on a forced
  ## CGB still reads 1; the shade palette needs the monochrome case).
  if stateKind == ekGB and stateGb != nil and stateGb.cgb_enabled: 1 else: 0

# --- Frames ---

proc push_rewind() =
  if rewindHistory == nil: return
  case stateKind
  of ekGBA:
    discard rewindHistory.maybe_push(
      proc(): string = stateGba.state_payload(),
      proc(): RewindThumb = RewindThumb(w: 120, h: 80,
        pixels: downscale_bgr555(stateGba.ppu.framebuffer, GBA_W, GBA_H, 120, 80)))
  of ekGB:
    discard rewindHistory.maybe_push(
      proc(): string = stateGb.state_payload(),
      proc(): RewindThumb = RewindThumb(w: 120, h: 108,
        pixels: downscale_bgr555(stateGb.ppu.framebuffer, GB_W, GB_H, 120, 108)))
  of ekNone: discard

proc clip_note_frame()

proc step_canonical() =
  clip_note_frame()
  case stateKind
  of ekGBA: stateGba.step_frame()
  of ekGB:
    stateGb.step_frame()
    if statePrinter != nil: statePrinter.tick_frame()
  of ekNone: discard
  push_rewind()

proc dingbat_run_frame() {.exportc, cdecl.} =
  ## One emulated frame; its picture is then at dingbat_game_fb().
  if stateKind == ekNone or core_shared(): return
  step_canonical()
  present_live()

var runaheadFrame: seq[uint16] = @[]

proc dingbat_run_frame_ahead(n: cint) {.exportc, cdecl.} =
  ## dingbat_run_frame with N frames of run-ahead: one canonical frame (its
  ## audio played), then N silent lookahead frames whose picture is shown,
  ## then the canonical state restored (docs/run-ahead.md).
  if stateKind == ekNone or core_shared(): return
  step_canonical()
  if n <= 0:
    present_live()
    return
  let pixels = game_pixels()
  case stateKind
  of ekGBA:
    let snap = stateGba.state_payload()
    stateGba.apu.silent = true
    for _ in 0 ..< int(n): stateGba.step_frame()
    stateGba.apu.silent = optSilent
    if runaheadFrame.len != pixels: runaheadFrame.setLen(pixels)
    copyMem(addr runaheadFrame[0], addr stateGba.ppu.framebuffer[0], pixels * 2)
    try: stateGba.apply_state_payload(snap)
    except CatchableError: discard
  of ekGB:
    let snap = stateGb.state_payload()
    let prnSnap = if statePrinter != nil: statePrinter.clone() else: nil
    stateGb.apu.silent = true
    for _ in 0 ..< int(n): stateGb.step_frame()
    stateGb.apu.silent = optSilent
    if prnSnap != nil: copy_into(prnSnap, statePrinter)
    if runaheadFrame.len != pixels: runaheadFrame.setLen(pixels)
    copyMem(addr runaheadFrame[0], addr stateGb.ppu.framebuffer[0], pixels * 2)
    try: stateGb.apply_state_payload(snap)
    except CatchableError: discard
  of ekNone: return
  prepare_game_frame(cast[ptr UncheckedArray[uint16]](addr runaheadFrame[0]), pixels)

proc dingbat_game_fb(): ptr uint16 {.exportc, cdecl.} =
  ## The picture to present: raw BGR555 (the shader masks 0x7FFF), the LCD
  ## response's output when that is on. dingbat_fb_width x dingbat_fb_height.
  if stateKind == ekNone: nil else: cast[ptr uint16](gamePtr)

proc dingbat_framebuffer(): ptr uint16 {.exportc, cdecl.} =
  ## The core's own BGR555 framebuffer (no LCD response).
  let fb = live_fb()
  if fb == nil: nil else: cast[ptr uint16](fb)

proc dingbat_framebuffer_rgba(): ptr uint32 {.exportc, cdecl.} =
  ## Colour-corrected RGBA8888 (R first in memory) of the core's framebuffer,
  ## converted on call: thumbnails, the library picture and the ambient glow.
  let fb = live_fb()
  if fb == nil: return nil
  let n = game_pixels()
  let lut = if stateKind == ekGB: addr colorLutGbc else: addr colorLutGba
  if rgbaBuffer.len != n: rgbaBuffer.setLen(n)
  for i in 0 ..< n:
    rgbaBuffer[i] = lut[fb[i] and 0x7FFF]
  addr rgbaBuffer[0]

proc dingbat_fb_width(): cint {.exportc, cdecl.} =
  if stateKind == ekGB: GB_W else: GBA_W

proc dingbat_fb_height(): cint {.exportc, cdecl.} =
  if stateKind == ekGB: GB_H else: GBA_H

proc dingbat_frame_static(): cint {.exportc, cdecl.} =
  ## 1 if the last GBA frame was unchanged (render skip) and no LCD response
  ## is settling, so the shell may skip the upload.
  if stateKind == ekGBA and stateGba.ppu.frame_static and not lcdOn: 1 else: 0

proc dingbat_panel_gbc(): cint {.exportc, cdecl.} =
  if stateKind == ekGB: 1 else: 0

# --- Video options ---

proc dingbat_set_color_correction(on: cint) {.exportc, cdecl.} =
  ## Rebuilds the thumbnail tables; the shader reads its own flag. The LCD
  ## response table follows the chain after it, so it re-syncs too.
  colorCorrect = on != 0
  build_color_luts(colorCorrect)
  sync_lcd_panel()

proc dingbat_set_lcd_response(on: cint) {.exportc, cdecl.} =
  lcdOn = on != 0
  sync_lcd_panel()
  lcdResp.reset()

# --- Super Game Boy ---

proc dingbat_set_sgb(on: cint) {.exportc, cdecl.} =
  ## Consulted at the next load; the cart header still decides.
  optSgb = on != 0

proc dingbat_set_sgb_border(on: cint) {.exportc, cdecl.} =
  optSgbBorder = on != 0

proc dingbat_sgb_active(): cint {.exportc, cdecl.} =
  if stateKind == ekGB and stateGb != nil and stateGb.sgb_active(): 1 else: 0

proc dingbat_sgb_border(): cint {.exportc, cdecl.} =
  ## 1 when a border has been transferred AND the shell wants it shown.
  if stateKind == ekGB and stateGb != nil and optSgbBorder and
     stateGb.sgb_has_border(): 1 else: 0

proc dingbat_sgb_border_ptr(): ptr uint16 {.exportc, cdecl.} =
  ## 256x224 BGR555, bit 15 = opaque.
  if stateKind == ekGB and stateGb != nil and stateGb.sgb_active():
    stateGb.sgb_border_ptr() else: nil

proc dingbat_sgb_border_gen(): cint {.exportc, cdecl.} =
  if stateKind == ekGB and stateGb != nil and stateGb.sgb_active():
    cint(stateGb.sgb_border_gen()) else: 0

proc dingbat_sgb_backdrop(): cint {.exportc, cdecl.} =
  if stateKind == ekGB and stateGb != nil and stateGb.sgb_active():
    cint(stateGb.sgb_backdrop()) else: 0

# --- Ambient-glow sampler (dingbat_wasm.nim's wasm_glow_sample) ---
# Composites the way the presenter does (border over the Game Boy window
# over the backdrop), without upscale filters or scanlines. The DMG shade
# palette is passed in, not stored.

var glowBuffer: seq[uint32]

proc dingbat_glow_sample(gw, gh: cint; remap: cint;
                         p0, p1, p2, p3: uint32): ptr uint32 {.exportc, cdecl.} =
  ## Point-sample the composited picture into a gw x gh RGBA8888 buffer (R
  ## first in memory). One sample per cell: an area average would cost 20x
  ## for a difference invisible behind the blur.
  if gw <= 0 or gh <= 0: return nil
  let fbp = live_fb()
  if fbp == nil: return nil
  let fb = fbp
  let lut = if stateKind == ekGB: addr colorLutGbc else: addr colorLutGba
  let gameW = if stateKind == ekGB: GB_W else: GBA_W
  let gameH = if stateKind == ekGB: GB_H else: GBA_H
  let border = dingbat_sgb_border() != 0
  let outW = if border: SGB_BORDER_W else: gameW
  let outH = if border: SGB_BORDER_H else: gameH
  let offX = if border: (SGB_BORDER_W - GB_W) div 2 else: 0
  let offY = if border: (SGB_BORDER_H - GB_H) div 2 else: 0
  let bp = if border: cast[ptr UncheckedArray[uint16]](stateGb.sgb_border_ptr()) else: nil
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

proc dingbat_out_width(): cint {.exportc, cdecl.} =
  ## The presented picture's width: 256 with an SGB border, else the game's.
  if dingbat_sgb_border() != 0: cint(SGB_BORDER_W) else: dingbat_fb_width()

proc dingbat_out_height(): cint {.exportc, cdecl.} =
  if dingbat_sgb_border() != 0: cint(SGB_BORDER_H) else: dingbat_fb_height()

# --- System options (next core construction) ---

proc dingbat_set_gba_bios_mode(mode: cint) {.exportc, cdecl.} =
  optGbaBiosMode = clamp(mode, 0, 2)

proc dingbat_set_gba_run_bios(on: cint) {.exportc, cdecl.} =
  optGbaRunBios = on != 0

proc dingbat_set_gb_model(model: cint) {.exportc, cdecl.} =
  optGbModel = clamp(model, 0, 2)

proc dingbat_set_mp2k_hle(on: cint) {.exportc, cdecl.} =
  ## Remembered for later cores and applied to the live one.
  optMp2kHle = on != 0
  # Not onto a linked core: the HLE runs in place of the game's own mixer
  # code, so switching it mid-session would desync the friend.
  if stateKind == ekGBA and stateGba != nil and not core_shared():
    stateGba.mp2k_hle = optMp2kHle

proc dingbat_set_fifo_interp(on: cint) {.exportc, cdecl.} =
  optFifoInterp = on != 0
  if stateKind == ekGBA and stateGba != nil:
    stateGba.apu.set_fifo_interp(optFifoInterp)

proc dingbat_mp2k_available(): cint {.exportc, cdecl.} =
  if stateKind == ekGBA and stateGba != nil and stateGba.mp2k != nil and
     stateGba.mp2k.engaged: 1 else: 0

proc dingbat_hle_audio_active(): cint {.exportc, cdecl.} =
  if stateKind != ekGBA or stateGba == nil or not stateGba.mp2k_hle: return 0
  if stateGba.mp2k != nil and stateGba.mp2k.engaged and
     stateGba.mp2k.mixer_live(): return 1
  if stateGba.gs_bon != nil and stateGba.gs_bon.engaged: return 1
  0

# --- Input ---

proc dingbat_set_input(input_id: cint; pressed: cint) {.exportc, cdecl.} =
  ## input_id: 0 UP, 1 DOWN, 2 LEFT, 3 RIGHT, 4 A, 5 B, 6 SELECT, 7 START,
  ## 8 L, 9 R (same ids as the web build's data-inputs).
  if input_id < 0 or input_id > ord(Input.high) or core_shared(): return
  let inp = Input(input_id)
  let down = pressed != 0
  if down: clipCurButtons = clipCurButtons or (1'u16 shl input_id)
  else: clipCurButtons = clipCurButtons and not (1'u16 shl input_id)
  # During a clip replay the input log owns the core; the live mask is
  # re-applied when it ends.
  if clipReplaying: return
  case stateKind
  of ekGBA: stateGba.handle_input(inp, down)
  of ekGB:  stateGb.handle_input(inp, down)
  of ekNone: discard

proc dingbat_is_stopped(): cint {.exportc, cdecl.} =
  ## 1 while the GBA is in Stop mode (sleeping), for a UI badge.
  if stateKind == ekGBA and stateGba != nil and stateGba.cpu.stopped: 1 else: 0

proc dingbat_rumble(): cint {.exportc, cdecl.} =
  ## 1 while the cart's rumble motor is on (GB MBC5 rumble, GBA GPIO rumble).
  if stateKind == ekGB and stateGb != nil and stateGb.cartridge.mbc_rumble(): 1
  elif stateKind == ekGBA and stateGba != nil and stateGba.bus.gpio.gpio_rumble(): 1
  else: 0

proc dingbat_set_tilt(x, y: cdouble) {.exportc, cdecl.} =
  ## Accelerometer input, -1..1 per axis, 0 = level; for a gyro cart x is the
  ## rotation rate. A no-op on carts without a sensor.
  if stateKind == ekGB and stateGb != nil:
    stateGb.cartridge.set_accelerometer(float(x), float(y))
  elif stateKind == ekGBA and stateGba != nil:
    if stateGba.bus.tilt_present:
      stateGba.bus.tilt_in_x = float(x)
      stateGba.bus.tilt_in_y = float(y)
    elif stateGba.bus.gpio.gyro_present:
      stateGba.bus.gpio.gyro_z = float(x)

proc dingbat_cart_has_tilt(): cint {.exportc, cdecl.} =
  ## 0 = none, 1 = tilt/accelerometer (MBC7, GBA tilt), 2 = gyro rate sensor.
  if stateKind == ekGB and stateGb != nil and stateGb.cartridge of Mbc7: 1
  elif stateKind == ekGBA and stateGba != nil and stateGba.bus.tilt_present: 1
  elif stateKind == ekGBA and stateGba != nil and stateGba.bus.gpio.gyro_present: 2
  else: 0

# --- Game Boy Camera ---
const CAM_SRC_W = 128
const CAM_SRC_H = 120
var cameraFrame: seq[uint8] = @[]

proc camera_source_from_buffer(x, y: int): uint8 =
  if cameraFrame.len == CAM_SRC_W * CAM_SRC_H:
    cameraFrame[y * CAM_SRC_W + x]
  else:
    0x80'u8

proc dingbat_cart_has_camera(): cint {.exportc, cdecl.} =
  if stateKind == ekGB and stateGb != nil and stateGb.cartridge of PocketCamera: 1
  else: 0

proc dingbat_camera_attach(): cint {.exportc, cdecl.} =
  ## Point the emulated sensor at dingbat_camera_frame (128x120 luminance,
  ## 255 = bright). Returns the buffer's length.
  if stateKind != ekGB or stateGb == nil: return 0
  if cameraFrame.len != CAM_SRC_W * CAM_SRC_H:
    cameraFrame = newSeq[uint8](CAM_SRC_W * CAM_SRC_H)
    for i in 0 ..< cameraFrame.len: cameraFrame[i] = 0x80
  stateGb.cartridge.set_camera_source(camera_source_from_buffer)
  cint(cameraFrame.len)

proc dingbat_camera_frame(): ptr uint8 {.exportc, cdecl.} =
  if cameraFrame.len > 0: addr cameraFrame[0] else: nil

# --- Game Boy Printer ---
var printerTakeBuf: seq[uint8] = @[]

proc dingbat_printer_poll(): cint {.exportc, cdecl.} =
  ## Finished prints waiting to be taken.
  if statePrinter != nil: cint(statePrinter.outbox.len) else: 0

proc dingbat_printer_take(): cint {.exportc, cdecl.} =
  ## Pop the oldest print into a grayscale buffer (160 x h, 255 = white) at
  ## dingbat_printer_take_ptr. Returns h, 0 when nothing is waiting.
  if statePrinter == nil or statePrinter.outbox.len == 0: return 0
  let shades = statePrinter.outbox[0]
  statePrinter.outbox.delete(0)
  const GRAY = [255'u8, 170, 85, 0]
  printerTakeBuf.setLen(shades.len)
  for i in 0 ..< shades.len:
    printerTakeBuf[i] = GRAY[shades[i] and 3]
  cint(shades.len div 160)

proc dingbat_printer_take_ptr(): ptr uint8 {.exportc, cdecl.} =
  if printerTakeBuf.len > 0: addr printerTakeBuf[0] else: nil

# --- Saves ---

proc dingbat_flush_save() {.exportc, cdecl.} =
  ## Call on scenePhase background/exit and before reading the .sav file.
  flush_current_save()

# --- Audio ---

proc dingbat_set_volume(volume: cint; mute: cint) {.exportc, cdecl.} =
  ## volume 0..100; at 100 unmuted samples pass through bit-identical. A
  ## silent core (muted or 0) skips mixing.
  optVolume = clamp(volume, 0, 100)
  optMute = mute != 0
  apply_audio()

proc dingbat_set_channel_mutes(bits: cint) {.exportc, cdecl.} =
  ## Bit i mutes channel i: Square 1, Square 2, Wave, Noise, Sample A,
  ## Sample B (the GB has the first four). Output only; kept across loads.
  chanMutes = bits
  apply_channel_mutes()

proc dingbat_set_fast_forward(enabled: cint) {.exportc, cdecl.} =
  ## Disables audio-sync pacing (the APU then keeps only the freshest
  ## samples); the shell decides how many frames per display tick to run.
  optFastForward = enabled != 0
  apply_audio()

proc dingbat_set_turbo(on: cint) {.exportc, cdecl.} =
  ## 2x: the APU drops every other sample (or time-stretches with pitch
  ## correction), so audio pacing runs the game at double speed.
  optTurbo = on != 0
  apply_audio()

proc dingbat_set_slowmo(on: cint) {.exportc, cdecl.} =
  ## Half speed: each sample is queued twice, so audio pacing halves the
  ## frame rate and the sound plays an octave down.
  dingbat_audio_set_stretch(if on != 0: 1 else: 0)

proc dingbat_set_pitch_correct_ff(on: cint) {.exportc, cdecl.} =
  optPitchCorrect = on != 0
  apply_audio()

proc dingbat_audio_ahead(): cint {.exportc, cdecl.} =
  ## 1 when synced audio is buffered comfortably ahead of playback: the
  ## shell's pacing signal to stop running frames this display tick.
  let ahead = case stateKind
    of ekGBA: stateGba.apu.audio_ahead()
    of ekGB:  stateGb.apu.audio_ahead()
    of ekNone: false
  if ahead: 1 else: 0

# --- Save states ---
# Only valid at frame boundaries: the shell calls these from the thread that
# runs dingbat_run_frame.

var stateImage: string = ""

proc dingbat_state_size(): cint {.exportc, cdecl.} =
  ## Serialize the full state (same bytes as desktop .state files) into a
  ## retained buffer; returns its length, 0 when no core runs.
  case stateKind
  of ekGBA: stateImage = pack_state(stateGba.state_bytes(thumbnail = true))
  of ekGB:  stateImage = pack_state(stateGb.state_bytes(thumbnail = true))
  of ekNone: stateImage = ""
  cint(stateImage.len)

proc dingbat_state_data(): pointer {.exportc, cdecl.} =
  ## Pointer to the buffer produced by the last *_size() call.
  if stateImage.len > 0: addr stateImage[0] else: nil

proc dingbat_load_state(data: pointer; len: cint; keep_rewind: cint): cint {.exportc, cdecl.} =
  ## Returns 1 on success; 0 on rejection with the core untouched (the cause
  ## at dingbat_state_error_kind). Success drops the rewind ring unless
  ## keep_rewind (undoing a scrubber commit, whose ring is this state's past).
  last_state_error = ""
  last_state_reject_kind = srkNone
  if data == nil or len <= 0 or core_shared(): return 0
  var image = newString(int(len))
  copyMem(addr image[0], data, int(len))
  let ok = case stateKind
    of ekGBA: stateGba.load_state_bytes(image)
    of ekGB:  stateGb.load_state_bytes(image)
    of ekNone: false
  if ok:
    if keep_rewind == 0 and rewindHistory != nil: rewindHistory.clear()
    if statePrinter != nil: statePrinter.resync()
    lcdResp.reset()
    present_live()
  if ok: 1 else: 0

proc dingbat_state_error_kind(): cint {.exportc, cdecl.} =
  ## StateRejectKind ordinal: 0 none, 1 not a state, 2 wrong core, 3 wrong
  ## ROM, 4 too new, 5 truncated, 6 corrupt, 7 no file.
  cint(ord(last_state_reject_kind))

proc dingbat_state_error(): cstring {.exportc, cdecl.} =
  cstring(last_state_error)

# --- Rewind ---

proc dingbat_set_rewind(on: cint; cap_bytes: cint) {.exportc, cdecl.} =
  ## Master switch; off frees the ring. cap_bytes > 0 sets the memory cap for
  ## rings made from here on.
  if cap_bytes > 0: rewindCapBytes = int(cap_bytes)
  rewindEnabled = on != 0
  if not rewindEnabled:
    rewindHistory = nil
  elif rewindHistory == nil and stateKind != ekNone:
    rewindHistory = new_rewind(rewindCapBytes)

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

proc dingbat_rewind_pop(): cint {.exportc, cdecl.} =
  ## Step back one snapshot (REWIND_INTERVAL frames) and present it. Returns
  ## 1 when applied, 0 when history is exhausted.
  if stateKind == ekNone or rewindHistory == nil: return 0
  let snap = rewindHistory.pop()
  if snap.len == 0: return 0
  try:
    apply_payload(snap)
  except CatchableError:
    return 0
  present_live()
  1

var scrubThumbs: seq[byte] = @[]
var scrubIds: seq[int] = @[]
var scrubThumbW = 0
var scrubThumbH = 0

proc dingbat_rewind_scrub_generate(max_samples: cint): cint {.exportc, cdecl.} =
  ## Up to max_samples thumbnails spread evenly across history, newest first.
  scrubThumbs = @[]
  scrubIds = @[]
  if rewindHistory == nil or stateKind == ekNone: return 0
  let count = rewindHistory.thumb_count
  if count == 0: return 0
  let n = min(max(1, int(max_samples)), count)
  for s in 0 ..< n:
    let i = if n == 1: 0 else: s * (count - 1) div (n - 1)
    let t = rewindHistory.thumb_at(i)
    if t.pixels.len == 0: continue
    scrubThumbW = t.w
    scrubThumbH = t.h
    scrubThumbs.add t.pixels
    scrubIds.add rewindHistory.thumb_id(i)
  cint(scrubIds.len)

proc dingbat_rewind_scrub_thumb_w(): cint {.exportc, cdecl.} = cint(scrubThumbW)
proc dingbat_rewind_scrub_thumb_h(): cint {.exportc, cdecl.} = cint(scrubThumbH)
proc dingbat_rewind_scrub_thumbs(): pointer {.exportc, cdecl.} =
  ## Packed BGR555 thumbnails, w*h*2 bytes each, in sample order.
  if scrubThumbs.len > 0: addr scrubThumbs[0] else: nil

proc dingbat_rewind_scrub_seconds_ago(sample: cint): cint {.exportc, cdecl.} =
  ## Age in tenths of a second.
  if sample < 0 or sample >= scrubIds.len or rewindHistory == nil: return 0
  let index = rewindHistory.index_of_id(scrubIds[sample])
  if index < 0: return 0
  cint(index * rewindHistory.snapshot_interval * 10 div 60)

proc cart_save_bytes(): seq[byte] =
  case stateKind
  of ekGBA:
    if stateGba != nil and stateGba.storage != nil: stateGba.storage.memory
    else: @[]
  of ekGB:
    if stateGb != nil and stateGb.cartridge != nil and stateGb.cartridge.has_battery:
      stateGb.cartridge.ram
    else: @[]
  of ekNone: @[]

proc dingbat_rewind_scrub_save_differs(sample: cint): cint {.exportc, cdecl.} =
  ## 1 when committing to `sample` would change the cartridge save data.
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

proc dingbat_rewind_scrub_state_size(sample: cint): cint {.exportc, cdecl.} =
  ## Build the chosen sample's full .state image (header + payload +
  ## thumbnail) into the dingbat_state_data() buffer, put the live core
  ## back, and return the size (0 when the sample is gone). Report a Bug
  ## attaches it.
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
      of ekGBA: pack_state(stateGba.state_bytes(thumbnail = true))
      of ekGB:  pack_state(stateGb.state_bytes(thumbnail = true))
      of ekNone: ""
  except CatchableError:
    stateImage = ""
  if stash.len > 0:
    try: apply_payload(stash)
    except CatchableError: discard
  cint(stateImage.len)

proc dingbat_rewind_commit(sample: cint): cint {.exportc, cdecl.} =
  ## Rewind the live core to `sample` and drop every newer snapshot. The shell
  ## keeps its own pre-commit state for Undo.
  if stateKind == ekNone or rewindHistory == nil: return 0
  if sample < 0 or sample >= scrubIds.len: return 0
  let snap = rewindHistory.rewind_to_id(scrubIds[sample])
  if snap.len == 0: return 0
  try:
    apply_payload(snap)
  except CatchableError:
    return 0
  if statePrinter != nil: statePrinter.resync()
  present_live()
  1

# --- Cheats ---

var cheatErrBuf: string

proc dingbat_load_cheats(text: cstring): cstring {.exportc, cdecl.} =
  ## Replace the game's cheat list with `.cht` text. Returns newline-separated
  ## parse errors ("name: message"), or "". Valid until the next call.
  let eng = case stateKind
    of ekGBA: (if stateGba != nil: stateGba.cheats else: nil)
    of ekGB:  (if stateGb  != nil: stateGb.cheats  else: nil)
    of ekNone: nil
  cheatErrBuf = ""
  if eng == nil or core_shared(): return cstring(cheatErrBuf)
  eng.deserialize($text)
  case stateKind
  of ekGBA: stateGba.refresh_cheat_rom_patches()
  of ekGB:  stateGb.refresh_cheat_rom_patches()
  of ekNone: discard
  for c in eng.cheats:
    if c.error.len > 0:
      if cheatErrBuf.len > 0: cheatErrBuf.add "\n"
      cheatErrBuf.add (if c.name.len > 0: c.name else: "?") & ": " & c.error
  cstring(cheatErrBuf)

# --- Retroactive clip capture ("Clip that!", dingbat_wasm.nim's clip_*) ---
# A rolling ring of state anchors (one per second) plus a per-frame input
# log; deterministic replay from the anchor at or before the chosen start
# rebuilds the frames the player saw, which the shell encodes. Separate from
# the rewind ring: rewind may be off and keeps no inputs. The GBA RTC reads
# wall clock, so a replayed clock can differ by the clip's length.

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

proc clip_note_frame() =
  ## Once per canonical frame before it steps: an anchor every second, the
  ## held buttons every frame, and eviction past the window or the budget.
  if clipReplaying or stateKind == ekNone: return
  if clipFrameIndex mod CLIP_SNAP_INTERVAL == 0:
    let payload = current_payload()
    if payload.len > 0:
      var a = ClipAnchor(frame: clipFrameIndex, packed: compress(payload, BestSpeed, dfZlib))
      let fb = live_fb()
      let (w, h) = if stateKind == ekGB: (GB_W, GB_H) else: (GBA_W, GBA_H)
      let th = 120 * h div w
      let pixels = downscale_bgr555(toOpenArray(fb, 0, w * h - 1), w, h, 120, th)
      a.thumb = compress(pixels, BestSpeed, dfZlib)
      a.tw = 120
      a.th = th
      clipAnchors.add(a)
      clipAnchorBytes += clip_anchor_size(a)
  clipInputs.add(clipCurButtons)
  inc clipFrameIndex
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
      clipInputs = clipInputs[drop .. ^1]
      clipInputsStart += drop

proc clip_apply_payload(payload: string): bool =
  try:
    apply_payload(payload)
    stateKind != ekNone
  except CatchableError:
    false

proc clip_set_buttons(mask: uint16) =
  for i in 0 .. ord(Input.high):
    let down = (mask and (1'u16 shl i)) != 0
    case stateKind
    of ekGBA: stateGba.handle_input(Input(i), down)
    of ekGB:  stateGb.handle_input(Input(i), down)
    of ekNone: discard

proc dingbat_set_clip_cap(bytes: cint) {.exportc, cdecl.} =
  if bytes > 0: clipCapBytes = int(bytes)

proc dingbat_clip_history_frames(): cint {.exportc, cdecl.} =
  ## How far back a clip may start, in frames.
  if stateKind == ekNone or clipAnchors.len == 0: return 0
  cint(clipFrameIndex - clipAnchors[0].frame)

var clipStripThumbs: seq[byte] = @[]
var clipStripAgo: seq[int] = @[]
var clipStripW = 0
var clipStripH = 0

proc dingbat_clip_scrub_generate(max_samples: cint): cint {.exportc, cdecl.} =
  ## Up to max_samples anchor thumbnails spread across the window, newest
  ## first. Returns the count.
  clipStripThumbs = @[]
  clipStripAgo = @[]
  if stateKind == ekNone: return 0
  var usable: seq[int] = @[]
  for i in countdown(clipAnchors.high, 0):
    if clipAnchors[i].thumb.len > 0: usable.add(i)
  if usable.len == 0: return 0
  let n = min(max(1, int(max_samples)), usable.len)
  for s in 0 ..< n:
    let i = usable[if n == 1: 0 else: s * (usable.len - 1) div (n - 1)]
    var pixels: seq[byte]
    try: pixels = uncompress(clipAnchors[i].thumb, dfZlib)
    except CatchableError: continue
    clipStripW = clipAnchors[i].tw
    clipStripH = clipAnchors[i].th
    clipStripThumbs.add pixels
    clipStripAgo.add(clipFrameIndex - clipAnchors[i].frame)
  cint(clipStripAgo.len)

proc dingbat_clip_scrub_thumb_w(): cint {.exportc, cdecl.} = cint(clipStripW)
proc dingbat_clip_scrub_thumb_h(): cint {.exportc, cdecl.} = cint(clipStripH)
proc dingbat_clip_scrub_thumbs(): pointer {.exportc, cdecl.} =
  if clipStripThumbs.len > 0: addr clipStripThumbs[0] else: nil

proc dingbat_clip_scrub_frames_ago(sample: cint): cint {.exportc, cdecl.} =
  if sample < 0 or sample >= clipStripAgo.len: return 0
  cint(clipStripAgo[int(sample)])

proc dingbat_clip_begin(start_ago, end_ago: cint): cint {.exportc, cdecl.} =
  ## Arm a replay of [start_ago, end_ago) frames before now: stash the live
  ## state, restore the anchor at or before the start, silently re-emulate
  ## to the start frame. Returns the frames the replay runs (step them with
  ## dingbat_clip_tick), 0 with no usable history.
  if stateKind == ekNone or clipReplaying or clipAnchors.len == 0: return 0
  var startFrame = clipFrameIndex - max(0, int(start_ago))
  let endFrame = clipFrameIndex - max(0, int(end_ago))
  if startFrame < clipAnchors[0].frame: startFrame = clipAnchors[0].frame
  if startFrame < clipInputsStart: startFrame = clipInputsStart
  if endFrame <= startFrame: return 0
  var pick = 0
  for i in 0 ..< clipAnchors.len:
    if clipAnchors[i].frame <= startFrame: pick = i
    else: break
  var anchorPayload: string
  try: anchorPayload = uncompress(clipAnchors[pick].packed, dfZlib)
  except CatchableError: return 0
  clipLiveStash = current_payload()
  if clipLiveStash.len == 0: return 0
  if not clip_apply_payload(anchorPayload):
    clipLiveStash = ""
    return 0
  clipCursor = clipAnchors[pick].frame
  clipEnd = endFrame
  clipReplaying = true
  if statePrinter != nil: statePrinter.muted = true
  # Silent pre-roll to exactly the chosen frame: its sound is dropped.
  let mode = dingbat_audio_get_mode()
  dingbat_audio_set_mode(2)
  while clipCursor < startFrame:
    let idx = clipCursor - clipInputsStart
    if idx >= 0 and idx < clipInputs.len: clip_set_buttons(clipInputs[idx])
    case stateKind
    of ekGBA: stateGba.step_frame()
    of ekGB:  stateGb.step_frame()
    of ekNone: break
    inc clipCursor
  dingbat_audio_set_mode(mode)
  cint(clipEnd - clipCursor)

proc dingbat_clip_tick(): cint {.exportc, cdecl.} =
  ## One replay frame with its logged input; its picture is then at
  ## dingbat_framebuffer. Frames remaining, or -1 once done (the live state
  ## is already back).
  if not clipReplaying: return -1
  if clipCursor >= clipEnd:
    discard clip_apply_payload(clipLiveStash)
    clipLiveStash = ""
    clipReplaying = false
    if statePrinter != nil: statePrinter.muted = false
    clip_set_buttons(clipCurButtons)
    present_live()
    return -1
  let idx = clipCursor - clipInputsStart
  if idx >= 0 and idx < clipInputs.len: clip_set_buttons(clipInputs[idx])
  case stateKind
  of ekGBA: stateGba.step_frame()
  of ekGB:  stateGb.step_frame()
  of ekNone: return -1
  inc clipCursor
  cint(clipEnd - clipCursor)

proc dingbat_clip_abort() {.exportc, cdecl.} =
  ## Bail out of a replay: the live state comes back.
  if not clipReplaying: return
  discard clip_apply_payload(clipLiveStash)
  clipLiveStash = ""
  clipReplaying = false
  if statePrinter != nil: statePrinter.muted = false
  clip_set_buttons(clipCurButtons)
  present_live()

# --- Online link: input rollback (dingbat_wasm.nim's rollback_*) ---
# The shell runs dingbat_rollback_tick once per frame with this player's
# buttons, ships the returned frame and those buttons to the friend, and
# feeds the friend's with dingbat_rollback_feed; the session predicts and
# rolls back itself (gba/rollback.nim, gb/rollback.nim). Determinism needs
# the same ROMs, states and core build on both sides and the shared RTC
# epoch. Core 0 is the host's game, core 1 the guest's.

var rbRomPaths: array[2, string]

proc rb_mute_replays(core: GBA) =
  ## A rolled-back frame was already heard: its re-simulation queues nothing
  ## (the device is closed for the sample; the mix itself still runs, so the
  ## core stays bit-identical).
  let orig = core.scheduler.dispatch
  core.scheduler.dispatch = proc(kind: scheduler.EventType) =
    if kind == etAPUSample and rbGba != nil and rbGba.replaying:
      let apu = rbGba.link.cores[rbLocal].apu
      let dev = apu.audio_dev
      apu.audio_dev = 0
      orig(kind)
      apu.audio_dev = dev
    else:
      orig(kind)

proc rb_mute_replays(core: GB) =
  let orig = core.scheduler.dispatch
  core.scheduler.dispatch = proc(kind: scheduler.EventType) =
    if kind == etAPUSample and rbGb != nil and rbGb.replaying:
      let apu = rbGb.link.cores[rbLocal].apu
      let dev = apu.audio_dev
      apu.audio_dev = 0
      orig(kind)
      apu.audio_dev = dev
    else:
      orig(kind)

proc rb_become_live() =
  ## The session's local core is the one the picture and audio exports serve.
  if rbGba != nil:
    stateKind = ekGBA
    stateGba = rbGba.link.cores[rbLocal]
    stateGb = nil
  elif rbGb != nil:
    stateKind = ekGB
    stateGb = rbGb.link.cores[rbLocal]
    stateGba = nil
  statePrinter = nil  # the cable is the link's
  rewindHistory = nil
  romPath = rbRomPaths[rbLocal]
  clip_reset()
  lcdResp.reset()
  apply_audio()
  present_live()

proc dingbat_rollback_init(rom0, rom1: cstring; local_player: cint;
                           epoch: cdouble): cint {.exportc, cdecl.} =
  ## rom0/rom1: the host's and the guest's ROM files (this player's own game
  ## at its real path, so its battery save is the game's); `local_player`
  ## (0/1) the core this player drives; `epoch` the shared unix-seconds RTC
  ## seed both sides pass. The solo core is flushed and dropped. Returns 1,
  ## or 0 with no game loaded.
  dingbat_rollback_exit()
  dingbat_link_exit()
  flush_current_save()
  stateKind = ekNone
  stateGba = nil
  stateGb = nil
  statePrinter = nil
  rewindHistory = nil
  gamePtr = nil
  if local_player < 0 or local_player > 1 or rom0 == nil or rom1 == nil: return 0
  rbLocal = int(local_player)
  rbEpoch = int64(epoch)
  rbRomPaths = [$rom0, $rom1]
  try:
    if rbRomPaths[0].splitFile().ext.toLowerAscii() in GB_ROM_EXTS:
      # As the web build: the cart header picks the model, and the boot ROM
      # only when one is installed.
      let bootrom = if biosPath.len > 0 and fileExists(biosPath): biosPath else: ""
      enable_deterministic_gb_rtc(rbEpoch)  # applies to the cart and state loads
      var cores: seq[GB] = @[]
      for path in rbRomPaths:
        if not fileExists(path): return 0
        let core = new_gb(bootrom, path, false, bootrom.len > 0)
        core.post_init()
        cores.add(core)
      rb_mute_replays(cores[rbLocal])
      rbGb = gbrb.new_gb_rollback_session(new_gb_link(cores), rbLocal, 12)
    else:
      let haveBios = biosPath.len > 0 and fileExists(biosPath)
      let mode = if haveBios: optGbaBiosMode else: 0
      var cores: seq[GBA] = @[]
      for path in rbRomPaths:
        if not fileExists(path): return 0
        let core = new_gba(if haveBios: biosPath else: "", path,
                           run_bios = haveBios and optGbaRunBios,
                           use_hle = mode == 0,
                           hle_after_bios = mode == 2)
        core.post_init()  # builds the APU state set_fifo_interp touches
        core.mp2k_hle = optMp2kHle
        core.apu.set_fifo_interp(optFifoInterp)
        core.enable_deterministic_rtc(rbEpoch)
        cores.add(core)
      rb_mute_replays(cores[rbLocal])
      rbGba = gbarb.new_rollback_session(new_link(cores), rbLocal, 12)
  except CatchableError:
    rbGba = nil
    rbGb = nil
    gbRtcNowOverride = -1
    return 0
  rb_become_live()
  1

proc dingbat_rollback_load_state(player: cint; data: pointer; len: cint): cint {.exportc, cdecl.} =
  ## Seed core `player` from a full save state (a .state file's bytes) before
  ## the first tick. The shared RTC is re-applied after: the state carries
  ## the solo wall clock. Returns 1 on success.
  if player < 0 or player > 1 or data == nil or len <= 0: return 0
  var image = newString(int(len))
  copyMem(addr image[0], data, int(len))
  var ok = false
  if rbGb != nil:
    enable_deterministic_gb_rtc(rbEpoch)
    ok = rbGb.link.cores[int(player)].load_state_bytes(image)
  elif rbGba != nil:
    let core = rbGba.link.cores[int(player)]
    ok = core.load_state_bytes(image)
    if ok: core.enable_deterministic_rtc(rbEpoch)
  if ok and int(player) == rbLocal:
    lcdResp.reset()
    present_live()
  if ok: 1 else: 0

proc dingbat_rollback_tick(local_bits: cint): cint {.exportc, cdecl.} =
  ## One frame with this player's buttons and the friend's predicted ones.
  ## Returns the frame just simulated (send it with `local_bits`), or -1 when
  ## stalled at the prediction window waiting for the friend.
  if rbGb != nil:
    if gbrb.tick(rbGb, uint16(local_bits)) == grbStalled: return -1
    present_live()
    return cint(rbGb.head - 1)
  if rbGba == nil: return -1
  if gbarb.tick(rbGba, uint16(local_bits)) == rbStalled: return -1
  present_live()
  cint(rbGba.head - 1)

proc dingbat_rollback_feed(frame, bits: cint) {.exportc, cdecl.} =
  ## The friend's buttons for `frame` (may roll back and re-simulate).
  if frame < 0: return
  if rbGb != nil: gbrb.feed_remote(rbGb, int(frame), uint16(bits))
  elif rbGba != nil: gbarb.feed_remote(rbGba, int(frame), uint16(bits))

proc dingbat_rollback_active(): cint {.exportc, cdecl.} =
  if rb_active(): 1 else: 0

proc dingbat_rollback_transfers(): cint {.exportc, cdecl.} =
  ## Monotonic count of transfers on the emulated cable: a linked game keeps
  ## it moving and stops when it closes the link (the idle auto-disconnect).
  if rbGb != nil: return cint(rbGb.link.transfers and 0x7fffffff)
  if rbGba != nil: return cint(rbGba.link.transfers and 0x7fffffff)
  0

proc dingbat_rollback_exit() {.exportc, cdecl.} =
  ## End the session with nothing kept running (both battery saves written).
  if rbGba != nil:
    for core in rbGba.link.cores: core.storage.write_save()
    rbGba = nil
  elif rbGb != nil:
    for core in rbGb.link.cores: core.cartridge.mbc_save()
    rbGb = nil
    gbRtcNowOverride = -1
  else:
    return
  stateKind = ekNone
  stateGba = nil
  stateGb = nil
  gamePtr = nil

proc dingbat_rollback_exit_to_single(): cint {.exportc, cdecl.} =
  ## Leave the session but keep playing: this player's core, with its
  ## progress, becomes the solo core with the cable unplugged (a GB core gets
  ## its printer back); the friend's core goes. Returns 1, 0 with no session.
  if rbGb != nil:
    let core = rbGb.link.cores[rbLocal]
    core.cartridge.mbc_save()
    rbGb = nil
    gbRtcNowOverride = -1
    stateKind = ekGB
    stateGb = core
    stateGba = nil
    statePrinter = new_gb_printer()
    core.set_serial_driver(GbPrinterDriver(printer: statePrinter))
  elif rbGba != nil:
    let core = rbGba.link.cores[rbLocal]
    core.storage.write_save()
    core.set_sio_driver(NullSioDriver())
    rbGba = nil
    stateKind = ekGBA
    stateGba = core
    stateGb = nil
  else:
    return 0
  romPath = rbRomPaths[rbLocal]
  rewindHistory = if rewindEnabled: new_rewind(rewindCapBytes) else: nil
  clip_reset()
  lcdResp.reset()
  apply_audio()
  present_live()
  1

proc dingbat_rollback_head(): cint {.exportc, cdecl.} =
  ## Next frame to simulate; -1 with no session.
  if rbGb != nil: cint(rbGb.head) elif rbGba != nil: cint(rbGba.head) else: -1

proc dingbat_rollback_confirmed(): cint {.exportc, cdecl.} =
  ## Last frame with the friend's real input; -1 for none.
  if rbGb != nil: cint(rbGb.confirmed) elif rbGba != nil: cint(rbGba.confirmed) else: -1

var rbDumpImage = ""

proc dingbat_rollback_dump_size(player: cint): cint {.exportc, cdecl.} =
  ## Debug (web rollback_dump_size): core `player`'s full state into a buffer,
  ## its length; dingbat_rollback_dump_data points at it. The same bytes on
  ## both sides at the same confirmed frame, or the link has desynced.
  rbDumpImage = ""
  if player < 0 or player > 1: return 0
  if rbGb != nil: rbDumpImage = rbGb.link.cores[player].state_bytes()
  elif rbGba != nil: rbDumpImage = rbGba.link.cores[player].state_bytes()
  cint(rbDumpImage.len)

proc dingbat_rollback_dump_data(): pointer {.exportc, cdecl.} =
  if rbDumpImage.len > 0: addr rbDumpImage[0] else: nil

# --- 2P local link (dingbat_wasm.nim's link_*) ---
# Two cores of one ROM over the lockstep cable, on screen side by side. The
# paths are the same ROM under two names so each core has its own .sav:
# player 1's the game's own, player 2's beside it.

proc dingbat_link_init(rom0, rom1: cstring): cint {.exportc, cdecl.} =
  ## Player 1 on `rom0` (the game's own file), player 2 on `rom1`. The solo
  ## core is flushed and dropped. Returns 1, or 0 with no game loaded.
  dingbat_link_exit()
  dingbat_rollback_exit()
  flush_current_save()
  stateKind = ekNone
  stateGba = nil
  stateGb = nil
  statePrinter = nil
  rewindHistory = nil  # rewinding one core would desync the pair
  gamePtr = nil
  if rom0 == nil or rom1 == nil: return 0
  let paths = [$rom0, $rom1]
  try:
    if paths[0].splitFile().ext.toLowerAscii() in GB_ROM_EXTS:
      let bootrom = if biosPath.len > 0 and fileExists(biosPath): biosPath else: ""
      var cores: seq[GB] = @[]
      for path in paths:
        if not fileExists(path): return 0
        let core = new_gb(bootrom, path, false, bootrom.len > 0)
        core.post_init()
        cores.add(core)
      lkGb = new_gb_link(cores)
      stateKind = ekGB
      stateGb = cores[0]
    else:
      let haveBios = biosPath.len > 0 and fileExists(biosPath)
      let mode = if haveBios: optGbaBiosMode else: 0
      var cores: seq[GBA] = @[]
      for path in paths:
        if not fileExists(path): return 0
        let core = new_gba(if haveBios: biosPath else: "", path,
                           run_bios = haveBios and optGbaRunBios,
                           use_hle = mode == 0,
                           hle_after_bios = mode == 2)
        core.post_init()
        core.mp2k_hle = optMp2kHle
        core.apu.set_fifo_interp(optFifoInterp)
        cores.add(core)
      lkGba = new_link(cores)
      stateKind = ekGBA
      stateGba = cores[0]
  except CatchableError:
    lkGba = nil
    lkGb = nil
    stateKind = ekNone
    return 0
  romPath = paths[0]
  clip_reset()
  lcdResp.reset()
  apply_audio()
  present_live()
  1

proc dingbat_link_tick() {.exportc, cdecl.} =
  ## Both cores one lockstep frame; player 1's picture is then at
  ## dingbat_game_fb(), each player's raw at dingbat_link_fb.
  if lkGb != nil: lkGb.step_frame()
  elif lkGba != nil: lkGba.step_frame()
  else: return
  present_live()

proc dingbat_link_fb(player: cint): ptr uint16 {.exportc, cdecl.} =
  ## `player`'s (0/1) BGR555 framebuffer, the game's size.
  if player < 0 or player > 1: return nil
  if lkGb != nil: return cast[ptr uint16](addr lkGb.cores[player].ppu.framebuffer[0])
  if lkGba != nil: return cast[ptr uint16](addr lkGba.cores[player].ppu.framebuffer[0])
  nil

var lkRgba: seq[uint32] = @[]

proc dingbat_link_rgba(player: cint): ptr uint32 {.exportc, cdecl.} =
  ## `player`'s picture as colour-corrected RGBA8888 (the web's link
  ## canvases), converted on call.
  let fb = cast[ptr UncheckedArray[uint16]](dingbat_link_fb(player))
  if fb == nil: return nil
  let n = game_pixels()
  let lut = if lkGb != nil: addr colorLutGbc else: addr colorLutGba
  if lkRgba.len != n: lkRgba.setLen(n)
  for i in 0 ..< n: lkRgba[i] = lut[fb[i] and 0x7FFF]
  addr lkRgba[0]

proc dingbat_link_input(player, input_id, pressed: cint) {.exportc, cdecl.} =
  if input_id < 0 or input_id > ord(Input.high) or player < 0 or player > 1: return
  if lkGb != nil: lkGb.cores[player].handle_input(Input(input_id), pressed != 0)
  elif lkGba != nil: lkGba.cores[player].handle_input(Input(input_id), pressed != 0)

proc dingbat_link_active(): cint {.exportc, cdecl.} =
  if lk_active(): 1 else: 0

proc dingbat_link_flush_saves() {.exportc, cdecl.} =
  ## Both players' battery saves to their files.
  if lkGba != nil:
    for core in lkGba.cores: core.storage.write_save()
  if lkGb != nil:
    for core in lkGb.cores: core.cartridge.mbc_save()

proc dingbat_link_exit() {.exportc, cdecl.} =
  ## Both saves written, the pair dropped; no game left loaded.
  if not lk_active(): return
  dingbat_link_flush_saves()
  lkGba = nil
  lkGb = nil
  stateKind = ekNone
  stateGba = nil
  stateGb = nil
  gamePtr = nil
