## The shared PSG's AGB-only behaviour, as the GBA SP answered it, and the
## GB core keeping the CGB's. Run standalone:
##   nimble test_psgagb
##
## Every expected value here was read off the console (docs/gbatek-upstream.md
## §1.14), so a change to `common/psg_channels.nim` that moves one is a
## regression on hardware, not a refit:
##
## * Wave RAM (tests/roms/payloads/wavebank.s, wavedly.s; AGB SP over the link
##   rig 2026-09-30, two sessions identical). The CPU reads back what it
##   wrote under the same SOUND3CNT_L bit 6, playing or not; a read while
##   channel 3 plays never returns the byte being played (the CGB's rule); in
##   64-sample mode bit 6 reads back as written. Which physical bank playback
##   uses (GBATEK: the selected one, the CPU the other) is not visible from
##   the CPU, so nothing here pins it. These rows would sit in dbsuite, but
##   its multiboot image is full.
## * NR22 rewrites of a period-0 note (nrx2table.s, the SP's speaker, three
##   rounds): 0x88 over 0x80 leaves 6, 0x68 over 0x60 leaves 8, 0x68 over
##   0x68 leaves 6. The CGB (SameSuite, CGB E) leaves 7, 9, 7; the GB core
##   must keep those.
## * Noise shift 14 freezes the LFSR (zombie.s v2); shift 13 is the control.
##
## No ROM on disk: each core runs a spin loop assembled here, and the test
## drives the PSG registers through the bus between frames.

import std/os
import dingbat/gba/gba
import dingbat/gb/gb

var failures = 0
proc check(cond: bool; name: string) =
  if cond: echo "  [PASS] ", name
  else:
    echo "  [FAIL] ", name
    inc failures

# ── GBA ──────────────────────────────────────────────────────────────────────

proc gba_rom(): string =
  result = newString(0x200)
  for i, b in [0xFE'u8, 0xFF, 0xFF, 0xEA]: result[i] = char(b)   # b .

let gba_path = getTempDir() / "dingbat_psgagb.gba"
writeFile(gba_path, gba_rom())
let agb = new_gba("", gba_path, run_bios = false)
agb.post_init()

proc w(a: uint32; v: uint8) = agb.bus[0x04000000'u32 + a] = v
proc r(a: uint32): uint8 = agb.bus[0x04000000'u32 + a]
proc wave_word(i: int): uint32 =
  for k in 0 .. 3: result = result or (uint32(r(0x90'u32 + uint32(4*i + k))) shl (8*k))
proc master_reset() =
  w(0x84, 0x00); w(0x84, 0x80)
  w(0x80, 0x77); w(0x81, 0xFF); w(0x82, 0x02)

echo "wave RAM banks (wavebank.s)"
master_reset()
w(0x70, 0x00)                                   # bank 0 selected, DAC off
for i in 0 .. 15: w(0x90'u32 + uint32(i), uint8(0x10 + i))
w(0x70, 0x40)                                   # bank 1 selected
for i in 0 .. 15: w(0x90'u32 + uint32(i), uint8(0x20 + i))
check(wave_word(0) == 0x23222120'u32 and wave_word(3) == 0x2F2E2D2C'u32,
      "idle, bank 1 selected: B (SP words 4..7)")
w(0x70, 0x00)
check(wave_word(0) == 0x13121110'u32 and wave_word(3) == 0x1F1E1D1C'u32,
      "idle, bank 0 selected: A (SP words 0..3)")
w(0x70, 0x80)                                   # DAC on, bank 0
w(0x72, 0x00); w(0x73, 0x20)                    # volume 100%
w(0x74, 0x00); w(0x75, 0x80)                    # f = 0, trigger, no length
check((r(0x84) and 0x04) != 0, "channel 3 on")
check(wave_word(0) == 0x13121110'u32 and wave_word(3) == 0x1F1E1D1C'u32,
      "at the trigger: what was written, not the byte playing (SP words 8..11)")
agb.step_frame()
check((r(0x84) and 0x04) != 0 and wave_word(0) == 0x13121110'u32,
      "a frame into the note: still what was written (SP words 12..15)")
w(0x70, 0xC0)
check(wave_word(0) == 0x23222120'u32 and wave_word(3) == 0x2F2E2D2C'u32,
      "bank 1 selected while playing: B (SP words 16..19)")

echo "64-sample mode (wavedly.s)"
master_reset()
w(0x70, 0xA0)                                   # 64 samples, DAC on, bank 0
w(0x72, 0x00); w(0x73, 0x20)
w(0x74, 0xFF); w(0x75, 0x87)                    # f = 0x7FF, trigger
for f in 1 .. 3:
  agb.step_frame()
  check(r(0x70) == 0xA0 and r(0x84) == 0x84,
        "frame " & $f & ": NR30 reads 0xA0 as written, SOUNDCNT_X 0x84 (SP 0x84A0)")

proc agb_nr22(old, new: uint8): uint8 =
  master_reset()
  w(0x68, 0x80); w(0x69, old)                   # duty 2, NR22 = old
  w(0x6C, 0x7D); w(0x6D, 0x87)                  # f = 1917, trigger
  agb.step_frame()
  w(0x69, new)
  agb.apu.channel2.current_volume

echo "NR22 rewrite of a period-0 note (nrx2table.s)"
check(agb_nr22(0x80, 0x88) == 6, "AGB 0x88 over 0x80: 6 (CGB 7)")
check(agb_nr22(0x60, 0x68) == 8, "AGB 0x68 over 0x60: 8 (CGB 9)")
check(agb_nr22(0x68, 0x68) == 6, "AGB 0x68 over 0x68: 6 (CGB 7)")
check(agb_nr22(0x68, 0x60) == 10, "AGB 0x60 over 0x68: 10, as the CGB")

proc agb_lfsr_moves(nr43: uint8): bool =
  master_reset()
  w(0x79, 0xF0); w(0x7C, nr43); w(0x7D, 0x80)
  agb.step_frame()
  let before = agb.apu.channel4.lfsr
  for f in 1 .. 4: agb.step_frame()
  agb.apu.channel4.lfsr != before

echo "noise shift 14 (zombie.s)"
check(not agb_lfsr_moves(0xE0), "AGB shift 14: the LFSR holds")
check(agb_lfsr_moves(0xD0), "AGB shift 13: the LFSR steps (control)")

# ── GB, CGB mode: the same writes keep the CGB's table ─────────────────────

proc gb_rom(): string =
  result = newString(0x8000)
  for i, b in [0x00, 0xC3, 0x50, 0x01]: result[0x100 + i] = char(b)  # jp $0150
  for i, b in [0xF3, 0x18, 0xFE]: result[0x150 + i] = char(b)        # di; jr @
  result[0x143] = char(0x80)                                         # CGB
  var sum = 0
  for a in 0x134 .. 0x14C: sum = sum - int(uint8(result[a])) - 1
  result[0x14D] = char(sum and 0xFF)

let gb_path = getTempDir() / "dingbat_psgagb.gbc"
writeFile(gb_path, gb_rom())
let cgb = new_gb("", gb_path, headless = true, run_bios = false, force_cgb = true)
cgb.post_init()

proc gw(a: int; v: uint8) = cgb.memory.write_byte(cgb, a, v)
proc gb_reset() =
  gw(0xFF26, 0x00); gw(0xFF26, 0x80); gw(0xFF24, 0x77); gw(0xFF25, 0xFF)

proc gb_nr22(old, new: uint8): uint8 =
  gb_reset()
  gw(0xFF16, 0x80); gw(0xFF17, old)
  gw(0xFF18, 0x7D); gw(0xFF19, 0x87)
  cgb.step_frame()
  gw(0xFF17, new)
  cgb.apu.channel2.current_volume

echo "GB core, CGB mode"
check(gb_nr22(0x80, 0x88) == 7, "CGB 0x88 over 0x80: 7")
check(gb_nr22(0x60, 0x68) == 9, "CGB 0x68 over 0x60: 9")
check(gb_nr22(0x68, 0x68) == 7, "CGB 0x68 over 0x68: 7")
check(gb_nr22(0x68, 0x60) == 10, "CGB 0x60 over 0x68: 10")

echo ""
if failures == 0: echo "ALL PSG AGB TESTS PASSED"
else:
  echo failures, " FAILURES"
  quit(1)
