# iOS C API for the dingbat emulator core, the sibling of src/dingbat_wasm.nim.
#
# Built as a static library (see ios/build-core.sh) and consumed by the Swift
# shell in ios/Dingbat via the handwritten header ios/include/dingbat.h. The
# exported surface mirrors the wasm build where possible; differences:
#
#   - Audio is *pull*-based instead of wasm's push-per-frame model. The build
#     deliberately omits -d:test_harness/-d:emscripten so the APUs take their
#     desktop SDL2-queue path — and the SDL2 audio symbols they import are
#     provided by src/dingbat_ios_audio.c (compiled in below), which implements
#     them as a ring buffer drained by dingbat_audio_read() from an
#     AVAudioSourceNode render block.
#
#   - Pacing model: identical to the desktop frontend. The APU queues samples
#     as emulation runs; dingbat_audio_ahead() exposes the core's audio_ahead()
#     check and the shell runs frames only while audio is NOT comfortably
#     ahead of playback, so the audio clock (32768 Hz, real time) paces
#     emulation. The blocking backstop inside get_sample() stays a rarely-hit
#     safety net, and dingbat_ios_audio.c breaks that backstop after ~250 ms
#     if playback stalls, so the shell can never deadlock.
#
#   - Presentation: dingbat_framebuffer_rgba() applies the same BGR555→RGBA
#     LCD color-correction LUT the wasm build uses, so the shell can upload
#     straight to a texture/CGImage without porting the LUT to Swift.
#
# All threading happens Swift-side; every function here must be called from a
# single thread (the shell uses the main thread via CADisplayLink), except the
# plain-C dingbat_audio_* functions in dingbat_ios_audio.c which are safe from
# the CoreAudio render thread.

import std/[os, strutils, math]
import dingbat/common/input
import dingbat/gba/gba
import dingbat/gb/gb

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

proc NimMain() {.importc.}

# LCD color correction, identical to dingbat_wasm.nim's build_color_lut:
# linearize with lcdGamma 4.0, mix channels, re-gamma with outGamma 2.2.
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

proc dingbat_init() {.exportc, cdecl.} =
  ## Must be called once before any other API; runs Nim module init.
  NimMain()

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
  flush_current_save()
  let ext = path.splitFile().ext.toLowerAscii()
  try:
    if ext in [".gb", ".gbc"]:
      stateKind = ekGB
      let bootrom = if bios.len > 0 and fileExists(bios): bios else: ""
      stateGb = new_gb(bootrom, path, true, false, bootrom.len > 0)
      stateGb.post_init()
      rgbaBuffer.setLen(GB_W * GB_H)
    else:
      stateKind = ekGBA
      let gba_bios = if bios.len > 0 and fileExists(bios): bios else: ""
      stateGba = new_gba(gba_bios, path, run_bios = gba_bios.len > 0, use_hle = true)
      stateGba.post_init()
      rgbaBuffer.setLen(GBA_W * GBA_H)
    romPath = path
    biosPath = bios
    return 0
  except CatchableError:
    stateKind = ekNone
    return -2

proc dingbat_load_rom(rom_path: cstring; bios_path: cstring): cint {.exportc, cdecl.} =
  ## Load a .gba/.gb/.gbc ROM from a filesystem path. Battery saves are read
  ## from and written to `<rom minus extension>.sav` next to the ROM, so the
  ## path should live somewhere writable (the app's Documents dir).
  ## Returns 0 on success, -1 if missing, -2 on core init failure.
  let bios = if bios_path != nil: $bios_path else: ""
  load_rom_impl($rom_path, bios)

proc dingbat_load_rom_bytes(data: pointer; len: cint; persist_path: cstring;
                            bios_path: cstring): cint {.exportc, cdecl.} =
  ## Persist a ROM image to persist_path (must be writable; battery saves are
  ## created alongside it) and load it. Returns dingbat_load_rom's codes, or
  ## -3 if the bytes could not be written.
  if data == nil or len <= 0 or persist_path == nil: return -3
  var image = newString(int(len))
  copyMem(addr image[0], data, int(len))
  try:
    writeFile($persist_path, image)
  except CatchableError:
    return -3
  dingbat_load_rom(persist_path, bios_path)

proc dingbat_reset(): cint {.exportc, cdecl.} =
  ## Hard reset: flushes the battery save and reloads the current ROM.
  if stateKind == ekNone or romPath.len == 0: return -1
  load_rom_impl(romPath, biosPath)

proc dingbat_run_frame() {.exportc, cdecl.} =
  case stateKind
  of ekGBA: stateGba.step_frame()
  of ekGB:  stateGb.step_frame()
  of ekNone: discard

proc dingbat_framebuffer(): ptr uint16 {.exportc, cdecl.} =
  ## Raw BGR555 framebuffer; dimensions via dingbat_fb_width/height.
  case stateKind
  of ekGBA: addr stateGba.ppu.framebuffer[0]
  of ekGB:  addr stateGb.ppu.framebuffer[0]
  of ekNone: nil

proc dingbat_framebuffer_rgba(): ptr uint32 {.exportc, cdecl.} =
  ## Color-corrected RGBA8888 (R first in memory) view of the framebuffer,
  ## converted on call. Valid until the next ROM load. nil when no core runs.
  let fb = dingbat_framebuffer()
  if fb == nil: return nil
  let n = rgbaBuffer.len
  let src = cast[ptr UncheckedArray[uint16]](fb)
  for i in 0 ..< n:
    rgbaBuffer[i] = colorLut[src[i] and 0x7FFF]
  addr rgbaBuffer[0]

proc dingbat_fb_width(): cint {.exportc, cdecl.} =
  if stateKind == ekGB: GB_W else: GBA_W

proc dingbat_fb_height(): cint {.exportc, cdecl.} =
  if stateKind == ekGB: GB_H else: GBA_H

proc dingbat_frame_static(): cint {.exportc, cdecl.} =
  ## 1 if the last GBA frame was unchanged (render skip); shell may skip upload.
  if stateKind == ekGBA and stateGba.ppu.frame_static: 1 else: 0

proc dingbat_set_input(input_id: cint; pressed: cint) {.exportc, cdecl.} =
  ## input_id: 0 UP, 1 DOWN, 2 LEFT, 3 RIGHT, 4 A, 5 B, 6 SELECT, 7 START,
  ## 8 L, 9 R (same ids as the web build's data-inputs).
  if input_id < 0 or input_id > ord(Input.high): return
  let inp = Input(input_id)
  let down = pressed != 0
  case stateKind
  of ekGBA: stateGba.handle_input(inp, down)
  of ekGB:  stateGb.handle_input(inp, down)
  of ekNone: discard

proc dingbat_is_stopped(): cint {.exportc, cdecl.} =
  ## 1 while the GBA is in Stop mode (sleeping), for a UI badge.
  if stateKind == ekGBA and stateGba != nil and stateGba.cpu.stopped: 1 else: 0

proc dingbat_flush_save() {.exportc, cdecl.} =
  ## Persist battery-backed save RAM now (call on scenePhase background/exit).
  ## GBA saves also auto-flush once per frame via the core's etSaves event;
  ## GB saves only flush here or on ROM switch.
  flush_current_save()

proc dingbat_set_volume(volume: cint; mute: cint) {.exportc, cdecl.} =
  ## volume 0..100; at 100 unmuted samples pass through bit-identical.
  case stateKind
  of ekGBA: stateGba.apu.set_master_volume(int(volume), mute != 0)
  of ekGB:  stateGb.apu.set_master_volume(int(volume), mute != 0)
  of ekNone: discard

proc dingbat_set_fast_forward(enabled: cint) {.exportc, cdecl.} =
  ## Disables audio-sync pacing (the APU then clears the queue each buffer, so
  ## playback keeps only the freshest samples). The shell decides how many
  ## frames per display tick fast-forward actually runs.
  case stateKind
  of ekGBA: stateGba.apu.sync = enabled == 0
  of ekGB:  stateGb.apu.sync = enabled == 0
  of ekNone: discard

proc dingbat_audio_ahead(): cint {.exportc, cdecl.} =
  ## 1 when synced audio is buffered comfortably ahead of playback; the shell
  ## should stop running frames this display tick (the core's pacing signal).
  let ahead = case stateKind
    of ekGBA: stateGba.apu.audio_ahead()
    of ekGB:  stateGb.apu.audio_ahead()
    of ekNone: false
  if ahead: 1 else: 0

# --- Save states ---
# Single-threaded like the wasm build: the shell only calls these from the
# same (main) thread that runs dingbat_run_frame, i.e. at frame boundaries.

# Retained so the pointer returned by dingbat_state_data stays valid after
# dingbat_state_size returns (replaced on the next dingbat_state_size call).
var stateImage: string = ""

proc dingbat_state_size(): cint {.exportc, cdecl.} =
  ## Serialize the running core's full state (same bytes as desktop .state
  ## files) into a retained buffer; returns its length, 0 when no core runs.
  case stateKind
  of ekGBA: stateImage = stateGba.state_bytes()
  of ekGB:  stateImage = stateGb.state_bytes()
  of ekNone: stateImage = ""
  cint(stateImage.len)

proc dingbat_state_data(): pointer {.exportc, cdecl.} =
  ## Pointer to the buffer produced by the last dingbat_state_size() call.
  if stateImage.len > 0: addr stateImage[0] else: nil

proc dingbat_load_state(data: pointer; len: cint): cint {.exportc, cdecl.} =
  ## Validate and apply a state image. Returns 1 on success; 0 on rejection
  ## (version/core/ROM mismatch or corruption) with the core untouched.
  if data == nil or len <= 0: return 0
  var image = newString(int(len))
  copyMem(addr image[0], data, int(len))
  let ok = case stateKind
    of ekGBA: stateGba.load_state_bytes(image)
    of ekGB:  stateGb.load_state_bytes(image)
    of ekNone: false
  if ok: 1 else: 0

build_color_lut()
