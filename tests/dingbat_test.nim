import std/[os, strutils, parseopt]
import dingbat/gb/gb
import dingbat/gba/gba
import dingbat/common/test_output
import dingbat/common/rewind

type
  TestMode = enum
    tmSerial, tmSram, tmMooneye, tmMgba, tmMgbaSuite, tmScreenshot,
    tmStateRoundtrip, tmRewindTest

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

proc fb_hash(fb: seq[uint16]): uint32 =
  ## FNV-1a over the framebuffer bytes
  result = 0x811C9DC5'u32
  for v in fb:
    result = (result xor uint32(v and 0xFF)) * 0x01000193'u32
    result = (result xor uint32(v shr 8)) * 0x01000193'u32

# Save/load-state roundtrip: run `warmup` frames, save a state, run 60 more
# frames and record a framebuffer hash; then reconstruct a fresh emulator,
# load the state, run 60 frames and compare. Also re-saves both emulators'
# states and compares the files byte-for-byte, which covers all serialized
# internal state, not just the visible pixels. Exits 0 iff everything matches.
proc state_roundtrip(rom_path, bios_path: string; warmup: int): int =
  const POST_FRAMES = 60
  let state_path  = rom_path & ".roundtrip.state"
  let state_path1 = rom_path & ".roundtrip1.state"
  let state_path2 = rom_path & ".roundtrip2.state"
  defer:
    for p in [state_path, state_path1, state_path2]: removeFile(p)
  let ext = rom_path.splitFile().ext.toLowerAscii()
  var fb1, fb2: seq[uint16]
  if ext in [".gba", ".bin"]:
    let is_hle = bios_path == "hle" or bios_path == ""
    let actual_bios = if is_hle: "" else: bios_path
    proc make_gba(): GBA =
      result = new_gba(actual_bios, rom_path, run_bios = false, use_hle = is_hle)
      result.test_output = new_test_output()
      result.post_init()
    let emu1 = make_gba()
    for _ in 0 ..< warmup: emu1.step_frame()
    if not emu1.save_state(state_path):
      echo "ROUNDTRIP: save failed"; return 1
    let emu2 = make_gba()
    if not emu2.load_state(state_path):
      echo "ROUNDTRIP: load failed"; return 1
    for _ in 0 ..< POST_FRAMES: emu1.step_frame()
    for _ in 0 ..< POST_FRAMES: emu2.step_frame()
    fb1 = emu1.ppu.framebuffer
    fb2 = emu2.ppu.framebuffer
    if not emu1.save_state(state_path1) or not emu2.save_state(state_path2):
      echo "ROUNDTRIP: re-save failed"; return 1
  else:
    proc make_gb(): GB =
      result = new_gb("", rom_path, fifo = true, headless = true, run_bios = false)
      result.test_output = new_test_output()
      result.post_init()
    let emu1 = make_gb()
    for _ in 0 ..< warmup: emu1.step_frame()
    if not emu1.save_state(state_path):
      echo "ROUNDTRIP: save failed"; return 1
    let emu2 = make_gb()
    if not emu2.load_state(state_path):
      echo "ROUNDTRIP: load failed"; return 1
    for _ in 0 ..< POST_FRAMES: emu1.step_frame()
    for _ in 0 ..< POST_FRAMES: emu2.step_frame()
    fb1 = emu1.ppu.framebuffer
    fb2 = emu2.ppu.framebuffer
    if not emu1.save_state(state_path1) or not emu2.save_state(state_path2):
      echo "ROUNDTRIP: re-save failed"; return 1
  let h1 = fb_hash(fb1)
  let h2 = fb_hash(fb2)
  let fb_ok = fb1 == fb2
  let state_ok = readFile(state_path1) == readFile(state_path2)
  echo "ROUNDTRIP framebuffer: ", toHex(h1, 8), " vs ", toHex(h2, 8),
       (if fb_ok: " MATCH" else: " MISMATCH")
  echo "ROUNDTRIP full state:  ", (if state_ok: "MATCH" else: "MISMATCH")
  if fb_ok and state_ok: 0 else: 1

# Rewind verification: run forward taking snapshots exactly like the
# frontend does, then pop backward and require byte-exact payload
# reconstruction through the XOR-delta chain — both a few steps back and all
# the way to the oldest snapshot — and that the emulator resumes from the
# rewound state. Exits 0 iff everything matches.
proc rewind_test(rom_path, bios_path: string): int =
  const TOTAL_FRAMES = 300
  let ext = rom_path.splitFile().ext.toLowerAscii()
  let rw = new_rewind()
  var ref_first = ""   # payload of the very first snapshot
  var ref_mid = ""     # payload of snapshot 20
  var snapshots = 0

  template drive(emu: untyped) =
    for f in 1 .. TOTAL_FRAMES:
      emu.step_frame()
      if rw.maybe_push(proc(): string = emu.state_payload()):
        inc snapshots
        if snapshots == 1:  ref_first = emu.state_payload()
        if snapshots == 20: ref_mid = emu.state_payload()
    echo "REWIND history:    ", rw.len, " snapshots in ", rw.mem_used(),
         " bytes (", ref_mid.len, " bytes/full snapshot)"
    # Pop back to snapshot 20 (pops return newest first)
    var popped = ""
    for _ in 1 .. (snapshots - 19):
      popped = rw.pop()
    let mid_ok = popped == ref_mid
    echo "REWIND mid-chain:  ", (if mid_ok: "MATCH" else: "MISMATCH")
    # Apply and make sure the emulator resumes from there
    emu.apply_state_payload(popped)
    let apply_ok = emu.state_payload() == ref_mid
    for _ in 1 .. 10: emu.step_frame()
    echo "REWIND apply:      ", (if apply_ok: "MATCH" else: "MISMATCH")
    # Walk the rest of the chain to the oldest snapshot
    var last = ""
    while true:
      let s = rw.pop()
      if s.len == 0: break
      last = s
    let full_ok = last == ref_first
    echo "REWIND full chain: ", (if full_ok: "MATCH" else: "MISMATCH")
    if mid_ok and apply_ok and full_ok: return 0 else: return 1

  if ext in [".gba", ".bin"]:
    let is_hle = bios_path == "hle" or bios_path == ""
    let actual_bios = if is_hle: "" else: bios_path
    let emu = new_gba(actual_bios, rom_path, run_bios = false, use_hle = is_hle)
    emu.test_output = new_test_output()
    emu.post_init()
    drive(emu)
  else:
    let emu = new_gb("", rom_path, fifo = true, headless = true, run_bios = false)
    emu.test_output = new_test_output()
    emu.post_init()
    drive(emu)

proc main() =
  var rom_path = ""
  var bios_path = ""
  var mode = tmSerial
  var timeout_frames = 1800
  var warmup_frames = 600
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
        of "stateroundtrip": mode = tmStateRoundtrip
        of "rewindtest": mode = tmRewindTest
        else:
          echo "Unknown mode: ", v
          quit(1)
      of "timeout":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        timeout_frames = parseInt(v)
      of "frames":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        warmup_frames = parseInt(v)
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
    echo "Usage: dingbat_test <rom_path> --mode <serial|sram|mooneye|mgba|mgba-suite|screenshot|stateroundtrip> [--timeout <frames>] [--frames <warmup>] [--screenshot <path.ppm>]"
    quit(1)

  if mode == tmStateRoundtrip:
    quit(state_roundtrip(rom_path, bios_path, warmup_frames))
  if mode == tmRewindTest:
    quit(rewind_test(rom_path, bios_path))

  let ext = rom_path.splitFile().ext.toLowerAscii()
  let is_gba = ext in [".gba", ".bin"]
  let test_out = new_test_output()

  if is_gba:
    let is_hle = bios_path == "hle" or bios_path == ""
    let actual_bios = if is_hle: "" else: bios_path
    let emu = new_gba(actual_bios, rom_path, run_bios = false, use_hle = is_hle)
    emu.test_output = test_out
    emu.post_init()
    for frame in 0 ..< timeout_frames:
      if test_out.finished: break
      try:
        emu.step_frame()
      except:
        stderr.writeLine("Emulator exception at frame " & $frame & ": " & getCurrentExceptionMsg())
        break
      if mode == tmMgba and test_out.mgba_debug_output.len > 0:
        let output = test_out.mgba_debug_output
        if output.contains("FAIL") or output.contains("PASS") or
           output.contains("fail") or output.contains("pass"):
          test_out.finished = true
      if mode == tmMgbaSuite and test_out.mgba_debug_output.contains("ALL DONE"):
        test_out.finished = true
    # Screenshot mode: write the 240x160 GBA framebuffer as PPM after running
    if mode == tmScreenshot and screenshot_path.len > 0:
      write_ppm(screenshot_path, emu.ppu.framebuffer, 240, 160, color_mode)
      echo screenshot_path
      quit(0)
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
  of tmStateRoundtrip, tmRewindTest:
    discard  # handled (and exited) above

  if output.len > 0:
    echo output
  if not test_out.finished:
    echo "TIMEOUT after ", timeout_frames, " frames"
  if passed:
    quit(0)
  else:
    quit(1)

main()
