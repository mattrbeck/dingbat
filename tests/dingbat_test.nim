import std/[os, strutils, parseopt]
import dingbat/gb/gb
import dingbat/gba/gba
import dingbat/common/test_output

type
  TestMode = enum
    tmSerial, tmSram, tmMooneye, tmMgba, tmMgbaSuite, tmScreenshot

# BGR555 -> 8-bit greyscale, mapping DMG_COLORS to the mealybug expected values.
# DMG_COLORS = [0x6BDF, 0x3ABF, 0x35BD, 0x2CEF] -> greyscale [0xFF, 0xAA, 0x55, 0x00]
proc bgr555_to_grey(c: uint16): uint8 =
  case c
  of 0x6BDF: 0xFF'u8
  of 0x3ABF: 0xAA'u8
  of 0x35BD: 0x55'u8
  of 0x2CEF: 0x00'u8
  else:
    # Fallback for non-DMG colors: generic BGR555 to greyscale
    let r = int(c and 0x1F) * 255 div 31
    let g = int((c shr 5) and 0x1F) * 255 div 31
    let b = int((c shr 10) and 0x1F) * 255 div 31
    uint8((r + g + b) div 3)

# BGR555 -> RGB using CGB-acid2 convention: (c << 3) | (c >> 2)
proc bgr555_to_rgb(c: uint16): array[3, uint8] =
  let r5 = int(c and 0x1F)
  let g5 = int((c shr 5) and 0x1F)
  let b5 = int((c shr 10) and 0x1F)
  [uint8((r5 shl 3) or (r5 shr 2)),
   uint8((g5 shl 3) or (g5 shr 2)),
   uint8((b5 shl 3) or (b5 shr 2))]

proc write_ppm(path: string; buf: seq[uint16]; w, h: int; color: bool) =
  var f = open(path, fmWrite)
  f.write("P6\n" & $w & " " & $h & "\n255\n")
  for pixel in buf:
    if color:
      let rgb = bgr555_to_rgb(pixel)
      f.write(char(rgb[0]))
      f.write(char(rgb[1]))
      f.write(char(rgb[2]))
    else:
      let grey = bgr555_to_grey(pixel)
      f.write(char(grey))
      f.write(char(grey))
      f.write(char(grey))
  f.close()

proc main() =
  var rom_path = ""
  var bios_path = ""
  var mode = tmSerial
  var timeout_frames = 1800
  var screenshot_path = ""
  var color_mode = false

  var p = initOptParser(commandLineParams())
  var positional = 0
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdArgument:
      if positional == 0:
        rom_path = p.key
        inc positional
    of cmdLongOption, cmdShortOption:
      case p.key
      of "mode":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        case v.toLowerAscii()
        of "serial": mode = tmSerial
        of "sram": mode = tmSram
        of "mooneye": mode = tmMooneye
        of "mgba": mode = tmMgba
        of "mgba-suite": mode = tmMgbaSuite
        of "screenshot": mode = tmScreenshot
        else:
          echo "Unknown mode: ", v
          quit(1)
      of "timeout":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        timeout_frames = parseInt(v)
      of "screenshot":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        screenshot_path = v
      of "color":
        color_mode = true
      of "bios":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        bios_path = v

  if rom_path.len == 0:
    echo "Usage: dingbat_test <rom_path> --mode <serial|sram|mooneye|mgba|mgba-suite|screenshot> [--timeout <frames>] [--screenshot <path.ppm>]"
    quit(1)

  let ext = rom_path.splitFile().ext.toLowerAscii()
  let is_gba = ext in [".gba", ".bin"]
  let test_out = new_test_output()

  if is_gba:
    let emu = new_gba(bios_path, rom_path, run_bios = false)
    emu.test_output = test_out
    emu.post_init()
    if bios_path == "hle":
      emu.bios_path = ""  # Force HLE SWI dispatch
    for frame in 0 ..< timeout_frames:
      if test_out.finished: break
      emu.step_frame()
      if mode == tmMgba and test_out.mgba_debug_output.len > 0:
        let output = test_out.mgba_debug_output
        if output.contains("FAIL") or output.contains("PASS") or
           output.contains("fail") or output.contains("pass"):
          test_out.finished = true
      if mode == tmMgbaSuite and test_out.mgba_debug_output.contains("ALL DONE"):
        test_out.finished = true
  else:
    let emu = new_gb("", rom_path, fifo = true, headless = true, run_bios = false)
    emu.test_output = test_out
    emu.post_init()
    for frame in 0 ..< timeout_frames:
      if test_out.finished: break
      emu.step_frame()
      if mode == tmSerial and test_out.serial_buffer.len > 0:
        if test_out.serial_buffer.contains("Passed") or
           test_out.serial_buffer.contains("Failed"):
          test_out.finished = true
      if mode == tmSram and emu.cartridge.ram.len >= 4:
        if emu.cartridge.ram[1] == 0xDE'u8 and
           emu.cartridge.ram[2] == 0xB0'u8 and
           emu.cartridge.ram[3] == 0x61'u8:
          test_out.sram_status = emu.cartridge.ram[0]
          var text = ""
          for i in 4 ..< emu.cartridge.ram.len:
            let b = emu.cartridge.ram[i]
            if b == 0: break
            text.add(char(b))
          test_out.sram_text = text
          test_out.finished = true
    # Screenshot mode: write framebuffer as PPM after running
    if mode == tmScreenshot and screenshot_path.len > 0:
      write_ppm(screenshot_path, emu.ppu.framebuffer, GB_WIDTH, GB_HEIGHT, color_mode)
      echo screenshot_path
      quit(0)

  # Determine result
  var passed = false
  var output = ""

  case mode
  of tmSerial:
    output = test_out.serial_buffer
    passed = output.contains("Passed")
  of tmSram:
    output = test_out.sram_text
    passed = test_out.sram_status == 0
  of tmMooneye:
    passed = test_out.mooneye_result == 0
    output = if passed: "Mooneye: PASS" else: "Mooneye: FAIL"
  of tmMgba:
    output = test_out.mgba_debug_output
    passed = output.contains("PASS") or output.contains("pass")
  of tmMgbaSuite:
    output = test_out.mgba_debug_output
    passed = output.contains("ALL DONE")
  of tmScreenshot:
    echo "Screenshot mode requires --screenshot path"
    quit(1)

  if output.len > 0:
    echo output
  if not test_out.finished:
    echo "TIMEOUT after ", timeout_frames, " frames"
  if passed:
    quit(0)
  else:
    quit(1)

main()
