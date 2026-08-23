## Headless dingbat runner for cross-emulator screenshot comparison.
## Same CLI contract as mgba_runner.c / nba_runner.cpp, plus save states.
##
## Usage: dingbat_nav <rom.gba> <bios.bin|hle> <outprefix> <script> <shots> [--state]
##   script: comma-separated FRAME:KEY[:HOLD] ("" for none)
##   shots:  comma-separated frames; writes <outprefix>.f<frame>.ppm
##   --state: also save_state to <outprefix>.f<frame>.state at each shot
##
## Build: nim c -d:test_harness -d:release --path:src -o:tools/romfuzz/dingbat_nav tools/romfuzz/dingbat_nav.nim

import std/[os, strutils, strformat]
import dingbat/gba/gba
import dingbat/common/input
import dingbat/common/test_output

type InputEvent = tuple[frame: int, key: Input, pressed: bool]

proc parse_script(script: string): seq[InputEvent] =
  for entry in script.split(','):
    if entry.len == 0: continue
    let parts = entry.split(':')
    let frame = parseInt(parts[0])
    let key = parseEnum[Input](parts[1].toUpperAscii())
    let hold = if parts.len > 2: parseInt(parts[2]) else: 10
    result.add((frame, key, true))
    result.add((frame + hold, key, false))

proc write_ppm(path: string; buf: seq[uint16]) =
  var f = open(path, fmWrite)
  f.write("P6\n240 160\n255\n")
  for pixel in buf:
    let r5 = pixel and 0x1F
    let g5 = (pixel shr 5) and 0x1F
    let b5 = (pixel shr 10) and 0x1F
    f.write(char(uint8((r5 shl 3) or (r5 shr 2))))
    f.write(char(uint8((g5 shl 3) or (g5 shr 2))))
    f.write(char(uint8((b5 shl 3) or (b5 shr 2))))
  f.close()


proc main() =
  let args = commandLineParams()
  if args.len < 5:
    echo "Usage: dingbat_nav <rom> <bios|hle> <outprefix> <script> <shots> [--state]"
    quit(2)
  let rom_path = args[0]
  let bios = args[1]
  let prefix = args[2]
  let script = parse_script(args[3])
  var shots: seq[int]
  for tok in args[4].split(','):
    if tok.len > 0: shots.add(parseInt(tok))
  let want_state = args.len > 5 and args[5] == "--state"

  let use_hle = bios == "hle"
  # Skip the boot logo so frame 0 is the first game frame, as the other two
  # runners do. ROMFUZZ_RUN_BIOS plays the full boot (needs a real BIOS).
  let run_bios = getEnv("ROMFUZZ_RUN_BIOS") != "" and not use_hle
  let emu = new_gba(if use_hle: "" else: bios, rom_path,
                    run_bios = run_bios, use_hle = use_hle)
  emu.test_output = new_test_output()
  emu.post_init()
  # Holds the idle-loop fast-forward out of an A/B (see tests/dingbat_bench.nim).
  if getEnv("DINGBAT_NO_WAITLOOP") == "1":
    emu.cpu.attempt_waitloop_detection = false
  # RTC carts read the host wall clock, so two runs of the same binary give
  # different save states; freeze it when state files must be reproducible.
  let rtc_epoch = getEnv("ROMFUZZ_RTC_EPOCH")
  if rtc_epoch.len > 0:
    emu.enable_deterministic_rtc(parseBiggestInt(rtc_epoch))

  var max_frame = 0
  for s in shots: max_frame = max(max_frame, s)

  for f in 0 .. max_frame:
    for ev in script:
      if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
    when defined(psgdim):
      # Force CH3 into 64-step (two-bank) wave mode at a short period so the
      # bank-flip-on-wrap path in ch3_catchup is exercised under -d:psgverify;
      # no commercial title in the sweep set uses dimension=1.
      emu.bus[0x04000084'u32] = 0x80'u8            # master sound enable
      emu.bus[0x04000080'u32] = 0x77'u8            # PSG L/R enable + volumes
      emu.bus[0x04000081'u32] = 0x77'u8
      emu.bus[0x04000082'u32] = 0x02'u8            # PSG volume 100%
      for i in 0'u32 .. 15'u32:                    # fill both wave banks
        emu.bus[0x04000090'u32 + i] = uint8(0x10 * (i and 7) + ((i + f.uint32) and 7))
      emu.bus[0x04000070'u32] = 0xE0'u8            # DAC on, bank 1, dimension on
      for i in 0'u32 .. 15'u32:
        emu.bus[0x04000090'u32 + i] = uint8(0xF0 - 0x10 * (i and 7))
      emu.bus[0x04000070'u32] = 0xA0'u8            # DAC on, bank 0, dimension on
      emu.bus[0x04000072'u32] = 0x00'u8            # length
      emu.bus[0x04000073'u32] = 0x20'u8            # volume 100%
      # Short period (freq 0x7F0 -> 128 cycles/step) so the 32-entry pointer
      # wraps several times between observations; only re-trigger occasionally,
      # since a trigger resets the pointer to 0.
      emu.bus[0x04000074'u32] = 0xF0'u8
      emu.bus[0x04000075'u32] = (if (f mod 97) == 0: 0x87'u8 else: 0x07'u8)
    emu.step_frame()
    if f in shots:
      write_ppm(&"{prefix}.f{f:04}.ppm", emu.ppu.framebuffer)
      if want_state:
        if not emu.save_state(&"{prefix}.f{f:04}.state"):
          stderr.writeLine "save_state failed at frame " & $f

main()
