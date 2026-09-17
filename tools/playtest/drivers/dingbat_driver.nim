## Persistent headless dingbat driver for tools/playtest. Speaks the line
## protocol documented in tools/playtest/README.md on stdin/stdout.
##
## Usage: dingbat_driver <rom.gba> <bios.bin|hle> [--run-bios] [--rtc EPOCH]
##   Without --rtc the cartridge RTC runs from the host clock.
##   The battery save is <rom minus extension>.sav, exactly as the desktop
##   app places it; run the driver on a ROM symlink inside a private
##   directory so saves never touch the library.
##
## Build: tools/playtest/build.sh

import std/[os, strutils, strformat]
import dingbat/gba/gba
import dingbat/common/input
import dingbat/common/test_output

# Protocol key bits, GBA KEYINPUT order
const KEY_ORDER = [A, B, SELECT, START, RIGHT, LEFT, UP, DOWN, R, L]

proc fb_hash(buf: seq[uint16]): uint64 =
  ## FNV-1a over BGR555 pixels; every driver hashes the same 15-bit values
  result = 0xcbf29ce484222325'u64
  for p in buf:
    result = (result xor uint64(p and 0x7FFF)) * 0x100000001b3'u64

proc write_ppm(path: string; buf: seq[uint16]) =
  var data = newString(240 * 160 * 3)
  for i, pixel in buf:
    let r5 = pixel and 0x1F
    let g5 = (pixel shr 5) and 0x1F
    let b5 = (pixel shr 10) and 0x1F
    data[i*3]   = char(uint8((r5 shl 3) or (r5 shr 2)))
    data[i*3+1] = char(uint8((g5 shl 3) or (g5 shr 2)))
    data[i*3+2] = char(uint8((b5 shl 3) or (b5 shr 2)))
  writeFile(path, "P6\n240 160\n255\n" & data)

# Cartridge RTC over the GPIO port, bit-banged the way a game's RTC driver
# does it (GBATEK "GBA Cart I/O Port (GPIO)" / "Real-Time Clock"): commands
# MSB first, parameters LSB first, one SCK low->high per bit. The same
# sequence in every driver, so `rtc_get` compares what each game would read.
proc rtc_xfer(emu: GBA; cmd: uint8; data: openArray[byte]; nread: int): seq[byte] =
  let g = emu.bus.gpio
  template w(reg: uint32; v: uint8) = g[0x08000000'u32 + reg] = v
  w(0xC8, 1)
  w(0xC6, 7)
  w(0xC4, 1)
  w(0xC4, 5)
  for i in 0 .. 7:
    let b = (cmd shr (7 - i)) and 1
    w(0xC4, 4'u8 or (b shl 1))
    w(0xC4, 5'u8 or (b shl 1))
  for v in data:
    for i in 0 .. 7:
      let b = (v shr i) and 1
      w(0xC4, 4'u8 or (b shl 1))
      w(0xC4, 5'u8 or (b shl 1))
  if nread > 0:
    w(0xC6, 5)
    for _ in 0 ..< nread:
      var v = 0'u8
      for i in 0 .. 7:
        w(0xC4, 4)
        w(0xC4, 5)
        v = v or (((g[0x080000C4'u32] shr 1) and 1) shl i)
      result.add(v)
  w(0xC6, 7)
  w(0xC4, 1)

proc reply(s: string) =
  stdout.write(s & "\n")
  stdout.flushFile()

proc main() =
  var positional: seq[string]
  var run_bios = false
  var rtc_epoch = -1'i64
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    case args[i]
    of "--run-bios": run_bios = true
    of "--rtc":
      inc i
      rtc_epoch = parseBiggestInt(args[i])
    else: positional.add(args[i])
    inc i
  if positional.len != 2:
    stderr.writeLine "Usage: dingbat_driver <rom> <bios|hle> [--run-bios] [--rtc EPOCH]"
    quit(2)
  let rom_path = positional[0]
  let use_hle = positional[1] == "hle"
  let emu = new_gba(if use_hle: "" else: positional[1], rom_path,
                    run_bios = run_bios and not use_hle, use_hle = use_hle)
  emu.test_output = new_test_output()
  emu.post_init()
  if rtc_epoch >= 0:
    emu.enable_deterministic_rtc(rtc_epoch)

  var frame = 0
  var held = 0
  reply &"ready dingbat save={emu.storage.save_path} size={emu.storage.memory.len}"
  var line: string
  while stdin.readLine(line):
    let parts = line.strip().splitWhitespace()
    if parts.len == 0: continue
    try:
      case parts[0]
      of "keys":
        let mask = parseInt(parts[1])
        for bit, key in KEY_ORDER:
          let now = (mask shr bit and 1) == 1
          if now != ((held shr bit and 1) == 1):
            emu.handle_input(key, now)
        held = mask
        reply "ok"
      of "run":
        for _ in 1 .. parseInt(parts[1]):
          emu.step_frame()
          inc frame
        reply &"ok {frame}"
      of "runhash":
        # run N frames, reporting the framebuffer hash after each
        var hashes: seq[string]
        for _ in 1 .. parseInt(parts[1]):
          emu.step_frame()
          inc frame
          hashes.add(fb_hash(emu.ppu.framebuffer).toHex)
        reply "ok " & hashes.join(" ")
      of "hash":
        reply "ok " & fb_hash(emu.ppu.framebuffer).toHex
      of "frame":
        reply &"ok {frame}"
      of "shot":
        write_ppm(parts[1], emu.ppu.framebuffer)
        reply "ok"
      of "savedata":
        writeFile(parts[1], cast[string](emu.storage.memory))
        reply &"ok {emu.storage.memory.len}"
      of "flush":
        emu.storage.write_save()
        reply "ok"
      of "state_save":
        reply(if emu.save_state(parts[1]): "ok" else: "err state_save failed")
      of "state_load":
        reply(if emu.load_state(parts[1]): "ok" else: "err state_load failed")
      of "layers":
        # debug visibility: bits 0-3 BG0-3, bit 4 OBJ
        emu.ppu.debug_layer_mask = uint8(parseHexInt(parts[1]))
        reply "ok"
      of "peek":
        let a = uint32(parseHexInt(parts[1]))
        var s = ""
        for k in 0'u32 ..< uint32(parseInt(parts[2])):
          s.add(emu.bus[a + k].toHex(2))
        reply "ok " & s
      of "rtc_get":
        # DATE_TIME register bytes (year month day weekday hour minute second)
        # and the status register, hex
        let dt = emu.rtc_xfer(0x65, [], 7)
        let st = emu.rtc_xfer(0x63, [], 1)
        var h = ""
        for b in dt: h.add(b.toHex(2))
        reply "ok " & h & " " & st[0].toHex(2)
      of "rtc_set":
        # rtc_set YYMMDDWWHHMMSS: a DATE_TIME write of those register bytes
        var b: seq[byte]
        for k in 0 .. 6: b.add(uint8(parseHexInt(parts[1][2 * k .. 2 * k + 1])))
        discard emu.rtc_xfer(0x64, b, 0)
        reply "ok"
      of "quit":
        emu.storage.write_save()
        reply "ok"
        quit(0)
      else:
        reply "err unknown command " & parts[0]
    except CatchableError as e:
      reply "err " & e.msg.replace("\n", " ")

main()
