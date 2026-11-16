# Experimental iOS C API wrapper for the dingbat emulator core.
# Modeled on the exported surface of src/dingbat_wasm.nim, minus SDL.
# Built as: nim c --app:staticlib --noMain --os:ios --cpu:arm64 -d:test_harness ...
# A Swift/ObjC shell calls dingbat_init() once (runs NimMain), then
# dingbat_load_rom / dingbat_run_frame / dingbat_framebuffer / dingbat_set_input.

import std/[os, strutils]
import dingbat/common/input
import dingbat/gba/gba
import dingbat/gb/gb

const GBA_W = 240
const GBA_H = 160
const GB_W  = 160
const GB_H  = 144

type EmuKind = enum ekNone, ekGBA, ekGB

var stateKind: EmuKind = ekNone
var stateGba:  GBA     = nil
var stateGb:   GB      = nil

proc NimMain() {.importc.}

proc dingbat_init() {.exportc, cdecl, dynlib.} =
  ## Must be called once before any other API; runs Nim module init.
  NimMain()

proc dingbat_load_rom(rom_path: cstring; bios_path: cstring): cint {.exportc, cdecl, dynlib.} =
  ## Load a .gba/.gb/.gbc ROM from a filesystem path. Returns 0 on success.
  let path = $rom_path
  if not fileExists(path): return -1
  let ext = path.splitFile().ext.toLowerAscii()
  if stateGb != nil:
    stateGb.cartridge.mbc_save()
  try:
    if ext in [".gb", ".gbc"]:
      stateKind = ekGB
      let bootrom = if bios_path != nil and fileExists($bios_path): $bios_path else: ""
      stateGb = new_gb(bootrom, path, true, false, bootrom.len > 0)
      stateGb.post_init()
    else:
      stateKind = ekGBA
      let bios = if bios_path != nil and fileExists($bios_path): $bios_path else: ""
      stateGba = new_gba(bios, path, run_bios = bios.len > 0, use_hle = true)
      stateGba.post_init()
    return 0
  except CatchableError:
    stateKind = ekNone
    return -2

proc dingbat_run_frame() {.exportc, cdecl, dynlib.} =
  case stateKind
  of ekGBA: stateGba.step_frame()
  of ekGB:  stateGb.step_frame()
  of ekNone: discard

proc dingbat_framebuffer(): ptr uint16 {.exportc, cdecl, dynlib.} =
  ## BGR555 framebuffer pointer; dimensions via dingbat_fb_width/height.
  case stateKind
  of ekGBA: addr stateGba.ppu.framebuffer[0]
  of ekGB:  addr stateGb.ppu.framebuffer[0]
  of ekNone: nil

proc dingbat_fb_width(): cint {.exportc, cdecl, dynlib.} =
  if stateKind == ekGB: GB_W else: GBA_W

proc dingbat_fb_height(): cint {.exportc, cdecl, dynlib.} =
  if stateKind == ekGB: GB_H else: GBA_H

proc dingbat_frame_static(): cint {.exportc, cdecl, dynlib.} =
  ## 1 if the last GBA frame was unchanged (render skip); shell may skip upload.
  if stateKind == ekGBA and stateGba.ppu.frame_static: 1 else: 0

proc dingbat_set_input(input_id: cint; pressed: cint) {.exportc, cdecl, dynlib.} =
  if input_id < 0 or input_id > ord(Input.high): return
  let inp = Input(input_id)
  let down = pressed != 0
  case stateKind
  of ekGBA: stateGba.handle_input(inp, down)
  of ekGB:  stateGb.handle_input(inp, down)
  of ekNone: discard

proc dingbat_is_stopped(): cint {.exportc, cdecl, dynlib.} =
  if stateKind == ekGBA and stateGba != nil and stateGba.cpu.stopped: 1 else: 0

proc dingbat_flush_save() {.exportc, cdecl, dynlib.} =
  ## Persist battery-backed save RAM (call on app background/exit).
  if stateKind == ekGB and stateGb != nil:
    stateGb.cartridge.mbc_save()
  # GBA backup writes go through its own save path on write.

# NOTE: audio is compiled out under -d:test_harness. A real iOS build would
# widen the APU gate `when defined(emscripten)` to also cover an ios_shell
# define, then export the same appendAudioSample/getAudioBufferPtr/
# getAudioBufferLen/clearAudioBuffer ring the wasm build uses.
