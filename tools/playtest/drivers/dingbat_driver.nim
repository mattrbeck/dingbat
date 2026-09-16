## Persistent headless dingbat driver for tools/playtest. Speaks the line
## protocol documented in tools/playtest/README.md on stdin/stdout.
##
## Usage: dingbat_driver <rom.gba> <bios.bin|hle> [--run-bios] [--rtc EPOCH]
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
      of "peek":
        let a = uint32(parseHexInt(parts[1]))
        var s = ""
        for k in 0'u32 ..< uint32(parseInt(parts[2])):
          s.add(emu.bus[a + k].toHex(2))
        reply "ok " & s
      of "quit":
        emu.storage.write_save()
        reply "ok"
        quit(0)
      else:
        reply "err unknown command " & parts[0]
    except CatchableError as e:
      reply "err " & e.msg.replace("\n", " ")

main()
