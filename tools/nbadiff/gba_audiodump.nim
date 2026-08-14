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
  # Mode arg (the DINGBAT_FIFO_INTERP=0 escape hatch is compiled out under
  # test_harness, so poke the fields directly):
  #   (none)  shipping default: true-phase cubic FIFO reconstruction
  #   zoh     interpolation off — bit-true hardware DAC output
  #   mp2k    enable the MP2K/Bon HLE (Emerald -> mp2k, Golden Sun -> gs_bon)
  if args.len > 3:
    case args[3]
    of "zoh":  emu.apu.dma_channels.fifo_interp = false
    of "mp2k": emu.mp2k_hle = true
    else:
      echo "unknown mode: ", args[3]
      quit(1)
    echo "mode: ", args[3]
  for f in 0 ..< parseInt(args[2]):
    emu.step_frame()
  echo "ran ", args[2], " frames"

main()
