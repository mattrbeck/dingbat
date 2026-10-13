## Halt and Stop called from the cartridge, in every BIOS mode
## (tests/roms/swihalt.s): each call comes back to the instruction after it
## with the System and SVC stacks where they were and the registers the
## dispatcher saves intact.
##
##   nimble test_swihalt
##
## With Nintendo's image mapped and the HLE taking SWIs (hle_after_bios, or
## use_hle with a BIOS file given) a Halt from ROM went into the HLE, which
## parked in the image's code over its own three-word SVC frame: the
## image's return pops four (docs/playtest-bugs.md, "Metroid Fusion hung at
## boot over Nintendo's BIOS"). Runs under the HLE BIOS always; over a
## stand-in image made here (no Nintendo code in it) in all three modes,
## which is enough to see where a cartridge Halt goes: to the image's own
## SWI vector; and over Nintendo's image in all three when DINGBAT_GBA_BIOS
## (or tests/roms/gba_bios.bin) is there -- it never is in CI.

import std/[os, strformat, strutils]
import dingbat/gba/gba
import dingbat/common/input

const Rom = "tests/roms/swihalt.gba"
const Results = 0x02000000'u32
const Done = 0x02000100'u32
const Calls = 8
const UserSp = 0x03007F00'u32
const SvcSp = 0x03007FE0'u32

var failures = 0

proc word(emu: GBA; a: uint32): uint32 =
  for k in 0'u32 .. 3: result = result or (uint32(emu.bus[a + k]) shl (8 * k))

proc fail(msg: string) =
  echo "  FAIL ", msg
  inc failures

proc standin_image(path: string) =
  ## A 16 KB image of our own: an IRQ vector that calls the user handler as
  ## the console's does, and an SWI vector whose Halt (2) and Stop (3) write
  ## HALTCNT from BIOS code with a four-word SVC frame {spsr, r11, r12, lr},
  ## the console's shape (written here from GBATEK's description of the
  ## calls, not taken from any BIOS).
  var img = newSeq[byte](0x4000)
  proc put(a: int; w: uint32) =
    for k in 0 .. 3: img[a + k] = byte(w shr (8 * k))
  put(0x08, 0xEA000000'u32 or uint32((0x100 - 0x08 - 8) div 4))  # b 0x100
  put(0x18, 0xEA000000'u32 or uint32((0x200 - 0x18 - 8) div 4))  # b 0x200
  # SWI: 0x100
  let swi = [
    0xE92D5800'u32,  # push {r11, r12, lr}
    0xE14FB000'u32,  # mrs  r11, spsr
    0xE92D0800'u32,  # push {r11}
    0xE55EC002'u32,  # ldrb r12, [lr, #-2] (the comment, ARM or Thumb)
    0xE3A0B301'u32,  # mov  r11, #0x04000000
    0xE35C0003'u32,  # cmp  r12, #3
    0x03A0C080'u32,  # moveq r12, #0x80 (Stop)
    0x13A0C000'u32,  # movne r12, #0    (Halt)
    0xE5CBC301'u32,  # strb r12, [r11, #0x301]
    0xE8BD0800'u32,  # pop  {r11}
    0xE169F00B'u32,  # msr  spsr_fc, r11
    0xE8BD5800'u32,  # pop  {r11, r12, lr}
    0xE1B0F00E'u32]  # movs pc, lr
  for i, w in swi: put(0x100 + 4 * i, w)
  # IRQ: 0x200
  let irq = [
    0xE92D500F'u32,  # push {r0-r3, r12, lr}
    0xE3A00301'u32,  # mov  r0, #0x04000000
    0xE28FE000'u32,  # add  lr, pc, #0
    0xE510F004'u32,  # ldr  pc, [r0, #-4]
    0xE8BD500F'u32,  # pop  {r0-r3, r12, lr}
    0xE25EF004'u32]  # subs pc, lr, #4
  for i, w in irq: put(0x200 + 4 * i, w)
  writeFile(path, cast[string](img))

proc run(label, bios: string; use_hle, hle_after_bios: bool) =
  let emu = new_gba(bios, Rom, run_bios = false, use_hle = use_hle,
                    hle_after_bios = hle_after_bios)
  emu.post_init()
  var held = 0
  for _ in 1 .. 300:
    emu.step_frame()
    # The Stops wait for the keypad interrupt: A while stopped, for a frame
    if held > 0:
      dec held
      if held == 0: emu.handle_input(A, false)
    elif emu.cpu.stopped:
      emu.handle_input(A, true)
      held = 1
    if emu.word(Done) == 0x600DD0E5'u32 and held == 0: break
  var bad = 0
  for k in 0'u32 ..< Calls:
    let r = Results + 16 * k
    let what = (if k < 6: "Halt" else: "Stop") & (if k in [0'u32, 1, 2, 6]: " (ARM)" else: " (Thumb)")
    let got = [emu.word(r), emu.word(r + 4), emu.word(r + 8), emu.word(r + 12)]
    let want = [0x600D0000'u32 or k, UserSp, 0x11110000'u32 or k, 0x10100000'u32 or k]
    if got != want:
      inc bad
      fail &"{label} call {k} {what}: marker {got[0].toHex(8)} sp {got[1].toHex(8)} " &
           &"r11 {got[2].toHex(8)} r10 {got[3].toHex(8)} (want {want[0].toHex(8)} " &
           &"{want[1].toHex(8)} {want[2].toHex(8)} {want[3].toHex(8)})"
  if emu.word(Done) != 0x600DD0E5'u32:
    inc bad
    fail &"{label}: never finished (pc {emu.cpu.r[15].toHex(8)}, cpsr " &
         &"{cast[uint32](emu.cpu.cpsr).toHex(8)})"
  let svc = emu.cpu.reg_banks[mode_bank(modeSVC)][5]
  if svc != SvcSp:
    inc bad
    fail &"{label}: SVC sp {svc.toHex(8)} after the calls, want {SvcSp.toHex(8)}"
  echo &"{label}: {Calls - min(bad, Calls)}/{Calls} calls came back intact" &
       (if bad == 0: "" else: &" ({bad} problems)")

run("HLE BIOS", "", use_hle = true, hle_after_bios = false)
let standin = getTempDir() / "dingbat_swihalt_image.bin"
standin_image(standin)
run("stand-in image, HLE after it", standin, use_hle = false, hle_after_bios = true)
run("stand-in image, HLE", standin, use_hle = true, hle_after_bios = false)
run("stand-in image", standin, use_hle = false, hle_after_bios = false)
removeFile(standin)
let bios = getEnv("DINGBAT_GBA_BIOS", "tests/roms/gba_bios.bin")
if fileExists(bios):
  run("Nintendo's BIOS", bios, use_hle = false, hle_after_bios = false)
  run("Nintendo's BIOS, HLE after it", bios, use_hle = false, hle_after_bios = true)
  run("Nintendo's BIOS, HLE", bios, use_hle = true, hle_after_bios = false)
else: echo "Nintendo's BIOS: not here, skipped"

if failures == 0: echo "ALL SWI HALT/STOP RETURNS INTACT"
else:
  echo failures, " FAILURES"
  quit(1)
