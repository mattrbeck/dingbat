## Headless GBA audio-dump harness, for A/B'ing dingbat's mixed audio against
## NanoBoyAdvance (or any other reference emulator's core-mixer dump).
##
## Boots the REAL BIOS (run_bios=true — NBA's default is to run the BIOS, so
## a comparison capture must too; dingbat_bench hardcodes run_bios=false) and
## steps N frames unthrottled. DINGBAT_GBA_AUDIO_DUMP captures the mixed
## 32768 Hz stream from inside get_sample.
##
## IMPORTANT dump format: DINGBAT_GBA_AUDIO_DUMP writes the DAC-scale value
## (+/-512, i.e. total_left BEFORE the *32 output scaling) as s16le stereo.
## Normalize with /512.0, not /32768.0. NBA's dump (NBA_AUDIO_DUMP patch in
## ~/code/NanoBoyAdvance, uncommitted) writes f32le stereo already normalized
## to +/-1.0 full DAC (sample / 0x200) — so the two match after /512.
##
## Build: nim c -d:test_harness -d:release --path:src -o:gba_audiodump tools/nbadiff/gba_audiodump.nim
## Usage: DINGBAT_GBA_AUDIO_DUMP=out.s16 gba_audiodump <bios> <rom> <frames> [zoh]

import std/[os, strutils]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let args = commandLineParams()
  if args.len < 3:
    echo "Usage: gba_audiodump <bios> <rom> <frames> [zoh]"
    quit(1)
  let emu = new_gba(args[0], args[1], run_bios = true, use_hle = false)
  emu.test_output = new_test_output()
  emu.post_init()
  # "zoh" forces the legacy zero-order-hold FIFO read for a before/after A/B
  # of the cubic reconstruction (the DINGBAT_FIFO_INTERP=0 escape hatch is
  # compiled out under test_harness, so poke the field directly).
  if args.len > 3 and args[3] == "zoh":
    emu.apu.dma_channels.fifo_interp = false
    echo "fifo_interp OFF (zero-order hold)"
  for f in 0 ..< parseInt(args[2]):
    emu.step_frame()
  echo "ran ", args[2], " frames"

main()
