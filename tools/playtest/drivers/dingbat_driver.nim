## Persistent headless dingbat driver for tools/playtest. Speaks the line
## protocol documented in tools/playtest/README.md on stdin/stdout.
##
## Usage: dingbat_driver <rom.gba> <bios.bin|hle> [--run-bios] [--rtc EPOCH]
##                       [--no-waitloop] [--audio PATH] [--mp2k-hle]
##                       [--no-fifo-interp]
##   Without --rtc the cartridge RTC runs from the host clock.
##   --no-waitloop turns off idle-loop fast-forwarding (the shipped default
##   is on). --audio writes every mixed sample, s16le stereo at 32768 Hz.
##   --mp2k-hle arms the MP2K sound-engine HLE (the apps' "Enhanced audio"
##   setting, gba.mp2k_hle; off by default there and here). --no-fifo-interp
##   emits the raw FIFO latches instead of the apps' default cubic
##   reconstruction (apu.set_fifo_interp).
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
  var waitloop = true
  var mp2k_hle = false
  var fifo_interp = true
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    case args[i]
    of "--run-bios": run_bios = true
    of "--rtc":
      inc i
      rtc_epoch = parseBiggestInt(args[i])
    of "--no-waitloop": waitloop = false
    of "--mp2k-hle": mp2k_hle = true
    of "--no-fifo-interp": fifo_interp = false
    of "--audio":
      # the APU's own dump (apu.nim), claimed when the core is created
      inc i
      putEnv("DINGBAT_GBA_AUDIO_DUMP", args[i])
    else: positional.add(args[i])
    inc i
  if positional.len != 2:
    stderr.writeLine "Usage: dingbat_driver <rom> <bios|hle> [--run-bios] [--rtc EPOCH] [--no-waitloop] [--audio PATH] [--mp2k-hle] [--no-fifo-interp]"
    quit(2)
  let rom_path = positional[0]
  let use_hle = positional[1] == "hle"
  let emu = new_gba(if use_hle: "" else: positional[1], rom_path,
                    run_bios = run_bios and not use_hle, use_hle = use_hle)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.cpu.attempt_waitloop_detection = waitloop
  emu.mp2k_hle = mp2k_hle
  emu.apu.set_fifo_interp(fifo_interp)
  if rtc_epoch >= 0:
    emu.enable_deterministic_rtc(rtc_epoch)

  var frame = 0
  var held = 0
  when defined(biosdrvtrace):
    # apulog: every byte the CPU or DMA writes to the sound registers
    # 0x04000060-0x0400008F (FIFO data excluded), one line each:
    # FRAME CYCLE_IN_FRAME ADDR VALUE (mgba_driver's apulog writes the same)
    var apulog: File = nil
    proc log_io(address: uint32; value: uint8) {.closure.} =
      let a = address and 0xFFFFFF'u32
      if apulog != nil and a >= 0x60'u32 and a <= 0x8F'u32:
        let now = int64(emu.scheduler.cycles) + int64(emu.bus.cycles)
        apulog.writeLine(&"{frame} {now - int64(emu.frame_start_cycles)} " &
                         &"{(0x04000000'u32 or a).toHex(8)} {value.toHex(2)}")
    bdIoHook = log_io
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
      of "rundigest":
        # rundigest N (driver built with -d:biosdrvtrace): run N frames,
        # replying per frame FBHASH:COUNT:PCHASH:TIMEHASH over the
        # instructions executed outside the BIOS region -- how many, which
        # PCs in order, and which PCs at which cycle of the frame. Two
        # configurations whose game code runs the same instructions on the
        # same cycles agree on all four; HLE against official BIOS, the
        # first frame where TIMEHASH differs is where the game first saw a
        # BIOS call take a different time. (debug)
        when defined(biosdrvtrace):
          var cnt = 0
          var ph, th: uint64
          bdPcHook = proc(pc: uint32) {.closure.} =
            if pc >= 0x4000'u32:
              inc cnt
              ph = (ph xor uint64(pc)) * 0x100000001b3'u64
              let t = int64(emu.scheduler.cycles) + int64(emu.bus.cycles) -
                      int64(emu.frame_start_cycles)
              th = (th xor (uint64(pc) shl 24) xor uint64(t)) * 0x100000001b3'u64
          var outs: seq[string]
          for _ in 1 .. parseInt(parts[1]):
            cnt = 0
            ph = 0xcbf29ce484222325'u64
            th = ph
            emu.step_frame()
            inc frame
            outs.add(fb_hash(emu.ppu.framebuffer).toHex & ":" & $cnt & ":" &
                     ph.toHex & ":" & th.toHex)
          bdPcHook = nil
          reply "ok " & outs.join(" ")
        else:
          reply "err build with -d:biosdrvtrace"
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
      of "chmask":
        # chmask N: output mutes, APU.channel_mask (the apps' channel mutes;
        # emulation is unaffected). Bits 0-3 PSG 1-4, 4 FIFO A, 5 FIFO B;
        # a set bit plays.
        let m = parseInt(parts[1])
        for ch in 0 .. 5: emu.apu.channel_mask[ch] = (m shr ch and 1) == 1
        reply "ok"
      of "apulog":
        # apulog PATH | apulog off (driver built with -d:biosdrvtrace)
        when defined(biosdrvtrace):
          if apulog != nil: apulog.close()
          apulog = nil
          if parts[1] != "off": apulog = open(parts[1], fmWrite)
          reply "ok"
        else:
          reply "err build with -d:biosdrvtrace"
      of "layers":
        # debug visibility: bits 0-3 BG0-3, bit 4 OBJ
        emu.ppu.debug_layer_mask = uint8(parseHexInt(parts[1]))
        reply "ok"
      of "peek":
        # untimed: a timed bus read (`emu.bus[a]`) charges wait states to
        # the CPU, so peeking every frame shifted the game's own timing
        let a = uint32(parseHexInt(parts[1]))
        var s = ""
        for k in 0'u32 ..< uint32(parseInt(parts[2])):
          s.add(emu.bus.read_byte_internal(a + k).toHex(2))
        reply "ok " & s
      of "trace":
        # trace N PATH: N instruction steps, "PC CYCLES VCOUNT T/A ABS [R]"
        # per step to PATH (PC as r15 before the step, cycles the step took,
        # the absolute master-clock cycle it started on, R on a step that
        # paid a parked HLE routine remainder instead of executing) (debug)
        var f = open(parts[2], fmWrite)
        var prev = int64(emu.scheduler.cycles) + int64(emu.bus.cycles)
        for _ in 1 .. parseInt(parts[1]):
          let pc = emu.cpu.r[15]
          let th = emu.cpu.cpsr.thumb
          let start = emu.rebased + prev
          # a step that only pays an HLE routine's parked remainder at the
          # instruction after its SWI (cpu.tick) executes no instruction: R
          let parked = emu.cpu.halt_resume_charge != 0 and
                       pc - (if th: 4'u32 else: 8'u32) == emu.cpu.halt_resume_addr
          emu.cpu.tick()
          let now = int64(emu.scheduler.cycles) + int64(emu.bus.cycles)
          f.writeLine(pc.toHex(8) & " " & $(now - prev) & " " & $emu.ppu.vcount &
                      (if th: " T " else: " A ") & $start & (if parked: " R" else: ""))
          prev = now
          if emu.ppu.frame != 0:
            emu.end_frame()
            inc frame
            prev = int64(emu.scheduler.cycles) + int64(emu.bus.cycles)
            emu.frame_start_cycles = emu.scheduler.cycles
            f.writeLine("FRAME")
        f.close()
        reply "ok"
      of "pft":
        # pft PC N PATH: run to r15 == PC, then N steps with -d:pftrace on
        when defined(pftrace):
          let target = uint32(parseHexInt(parts[1]))
          while emu.cpu.r[15] != target:
            emu.cpu.tick()
            if emu.ppu.frame != 0:
              emu.end_frame()
              inc frame
              emu.frame_start_cycles = emu.scheduler.cycles
          pft_on = true
          pft_lines.setLen(0)
          for _ in 1 .. parseInt(parts[2]):
            emu.cpu.tick()
            if emu.ppu.frame != 0:
              emu.end_frame()
              inc frame
              emu.frame_start_cycles = emu.scheduler.cycles
          pft_on = false
          writeFile(parts[3], pft_lines.join("\n"))
          reply "ok"
        else:
          reply "err build with -d:pftrace"
      of "runto":
        # runto PC: step until r15 == PC (debug), then print r0-r15
        let target = uint32(parseHexInt(parts[1]))
        while emu.cpu.r[15] != target:
          emu.cpu.tick()
          if emu.ppu.frame != 0:
            emu.end_frame()
            inc frame
            emu.frame_start_cycles = emu.scheduler.cycles
        var s: seq[string]
        for k in 0 .. 15: s.add(emu.cpu.r[k].toHex(8))
        reply "ok " & s.join(" ")
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
        when defined(biosdrvtrace):
          if apulog != nil: apulog.close()
        emu.storage.write_save()
        reply "ok"
        quit(0)
      else:
        reply "err unknown command " & parts[0]
    except CatchableError as e:
      reply "err " & e.msg.replace("\n", " ")

main()
