## APU.silent is unobservable: a core that skips mixing (muted, volume 0, a
## run-ahead lookahead, link player 2) runs exactly as one that mixes.
## Run standalone: nimble test_silentaudio   (or ./dingbat_silent_audio_test [filter])
##
## Two cores per case, one mixing throughout and one turning silent on and off
## every few frames (GBA through set_audio_silent, which re-latches the sound
## HLEs; the MP2K HLE is on in both). Their state payloads must match after
## every frame. Cases: every ROM committed under tests/roms and the state
## soak's seeded random programs, which write random values to the APU
## registers at random points in the frame (state_soak_test.nim, built with
## -d:soak_lib so its cases do not run here).

include state_soak_test

const
  SilentFlip = [7, 13, 3, 29, 11]   ## frames between silent toggles, cycled
  SilentRandomFrames = 600          ## per random program (the soak runs 1200)

proc twin_run[T](label: string; make: proc(): T; frames: int; seed: uint64;
                 poke: proc(e: T; seed: uint64; frame: int) {.nimcall.};
                 set_silent: proc(e: T; on: bool) {.nimcall.}) =
  let loud = make()
  let quiet = make()
  var next_flip = SilentFlip[0]
  var flips = 0
  var silent = false
  var distinct_seen: seq[uint64]
  try:
    for f in 0 ..< frames:
      if f == next_flip:
        silent = not silent
        set_silent(quiet, silent)
        inc flips
        next_flip = f + SilentFlip[flips mod SilentFlip.len]
      if poke != nil:
        poke(loud, seed, f)
        poke(quiet, seed, f)
      loud.step_frame()
      quiet.step_frame()
      let a = loud.state_payload()
      let b = quiet.state_payload()
      if a != b:
        fail(&"{label}: the {(if silent: \"silent\" else: \"resumed\")} core " &
             &"diverged from the mixing one at frame {f}: " & diff_note(a, b))
        return
      if distinct_seen.len < 64 and fnv(a) notin distinct_seen:
        distinct_seen.add(fnv(a))
  except CatchableError, Defect:
    let e = getCurrentException()
    fail(&"{label}: {e.name}: {e.msg}")
    return
  if distinct_seen.len < 8:
    fail(&"{label}: only {distinct_seen.len} distinct states in {frames} frames")
    return
  echo &"  [PASS] {label}: {frames} frames, {flips} silent toggles"

proc gb_sweep_stop_program(seed: uint64): string =
  ## Channel 1 triggered over and over with an upward sweep that overflows at
  ## once: each trigger's stop lands a few cycles later (ch1_sweep_due),
  ## after the duty has stepped at a high frequency. The stop freezes the
  ## phase wherever the channel was last observed, so a silent core must
  ## observe it as a mixing one does (gb/apu.nim get_sample).
  var r = Rng(s: seed)
  var rom = newString(0x8000)
  var pc = 0
  proc emit(bs: varargs[int]) =
    for b in bs:
      rom[pc] = char(b and 0xFF)
      inc pc
  pc = 0x100
  emit(0x00, 0xC3, 0x50, 0x01)                       # nop; jp $0150
  pc = 0x150
  emit(0xF3, 0x31, 0xFE, 0xFF)                       # di; ld sp, $FFFE
  for (lo, v) in [(0x26, 0x80), (0x25, 0xFF), (0x24, 0x77)]:
    emit(0x3E, v, 0xE0, lo)                          # NR52 on, routed, loud
  let loop_start = pc
  while pc < 0x7F00:
    emit(0x3E, (1 + r.below(7)) shl 4 or (1 + r.below(3)), 0xE0, 0x10)  # NR10: up, shift 1-3
    emit(0x3E, r.below(4) shl 6, 0xE0, 0x11)         # NR11: duty
    emit(0x3E, 0xF0, 0xE0, 0x12)                     # NR12: DAC on
    emit(0x3E, 0xC0 + r.below(0x40), 0xE0, 0x13)     # NR13: period <= 64 ticks
    emit(0x3E, 0x87, 0xE0, 0x14)                     # NR14: trigger, frequency 0x7xx
    let n = 1 + r.below(60)
    emit(0x01, n, 0x00, 0x0B, 0x78, 0xB1, 0x20, 0xFB) # ld bc,n; delay loop
  emit(0xC3, loop_start and 0xFF, loop_start shr 8)
  var sum = 0
  for a in 0x134 .. 0x14C: sum = sum - int(uint8(rom[a])) - 1
  rom[0x14D] = char(sum and 0xFF)
  rom

proc gba_shift0_stop_program(seed: uint64): string =
  ## Channel 1 triggered over and over at frequencies >= 0x400 with a shift-0
  ## sweep: the AGB's f + f check stops it a few cycles after the trigger
  ## (ch1_settle), and the silent core must observe that as a mixing one does
  ## (gba/apu.nim get_sample).
  var r = Rng(s: seed)
  var code: seq[uint32]
  proc load(rd: int; v: uint32) =
    code.add(0xE3A00000'u32 or (uint32(rd) shl 12) or (v and 0xFF))
    for (sh, rot) in [(8'u32, 12'u32), (16'u32, 8'u32), (24'u32, 4'u32)]:
      if ((v shr sh) and 0xFF) != 0:
        code.add(0xE3800000'u32 or (uint32(rd) shl 16) or (uint32(rd) shl 12) or
                 (rot shl 8) or ((v shr sh) and 0xFF))
  proc strh(off: uint32; v: uint32) =                # strh r5, [r4, #off]
    load(5, v)
    code.add(0xE1C450B0'u32 or ((off shr 4) shl 8) or (off and 0xF))
  load(4, 0x04000000'u32)
  strh(0x84, 0x80)                                   # SOUNDCNT_X: master on
  strh(0x80, 0xFF77)                                 # SOUNDCNT_L: all routed, loud
  strh(0x82, 0x0002)                                 # SOUNDCNT_H: PSG 100%
  let loop_start = code.len
  while code.len * 4 < 0x20000:
    if r.chance(3):                                  # a master off/on now and then
      strh(0x84, 0x00)
      strh(0x84, 0x80)
    strh(0x60, uint32(1 + r.below(7)) shl 4)         # SOUND1CNT_L: shift 0
    strh(0x62, 0xF000'u32 or (uint32(r.below(4)) shl 6))   # envelope 15, duty
    strh(0x64, 0x8000'u32 or uint32(0x400 + r.below(0x400)))  # trigger, f >= 0x400
    load(8, uint32(1 + r.below(200)))
    code.add(0xE2588001'u32)                         # subs r8, r8, #1
    code.add(0x1AFFFFFD'u32)                         # bne (back one)
  let back = int32(loop_start) - int32(code.len) - 2
  code.add(0xEA000000'u32 or (cast[uint32](back) and 0xFFFFFF))
  result = newString(code.len * 4)
  for i, w in code:
    for b in 0 .. 3: result[i * 4 + b] = char((w shr (8 * b)) and 0xFF)

proc gba_silent(e: GBA; on: bool) = e.set_audio_silent(on)
proc gb_silent(e: GB; on: bool) = e.apu.silent = on

proc gba_hle_maker(path: string): proc(): GBA =
  result = proc(): GBA =
    result = new_gba("", path, run_bios = false, use_hle = true)
    result.mp2k_hle = true
    result.post_init()

if paramCount() >= 1: only = paramStr(1)
let tmp = getTempDir() / &"dingbat_silent_audio_{getCurrentProcessId()}"
createDir(tmp)
let t_start = epochTime()

let roms_dir = currentSourcePath().parentDir / "roms"
var roms: seq[string]
for path in walkDirRec(roms_dir):
  let ext = path.splitFile().ext.toLowerAscii()
  if ext in [".gb", ".gbc", ".gba"]: roms.add(path)
doAssert roms.len > 0, "no ROMs under " & roms_dir
for i, path in roms:
  let rel = path.relativePath(roms_dir).replace('\\', '/')
  let label = "rom " & rel
  if not wanted(label): continue
  let copy = tmp / &"{i}_{path.extractFilename()}"   # .sav lands in tmp
  copyFile(path, copy)
  if path.splitFile().ext.toLowerAscii() == ".gba":
    twin_run(label, gba_hle_maker(copy), RomFrames, 0, nil, gba_silent)
  else:
    twin_run(label, gb_maker(copy), RomFrames, 0, nil, gb_silent)

for seed in [0x5701'u64, 0x5702]:
  for cgb in [false, true]:
    let label = &"gb sweep stops {(if cgb: \"cgb\" else: \"dmg\")} {seed:#x}"
    if not wanted(label): continue
    let path = tmp / &"sweep_{seed:x}_{ord(cgb)}.gb"
    var rom = gb_sweep_stop_program(seed)
    rom[0x143] = char(if cgb: 0x80 else: 0x00)
    writeFile(path, rom)
    twin_run(label, gb_maker(path), RomFrames, seed, nil, gb_silent)

for seed in [0x5A01'u64, 0x5A02]:
  let label = &"gba shift-0 stops {seed:#x}"
  if not wanted(label): continue
  let path = tmp / &"shift0_{seed:x}.gba"
  writeFile(path, gba_shift0_stop_program(seed))
  twin_run(label, gba_hle_maker(path), RomFrames, seed, nil, gba_silent)

for seed in [0x6B01'u64, 0x6B02, 0x6B03]:
  for cgb in [false, true]:
    let label = &"random gb {(if cgb: \"cgb\" else: \"dmg\")} {seed:#x}"
    if not wanted(label): continue
    let path = tmp / &"random_{seed:x}_{ord(cgb)}.gb"
    writeFile(path, gb_program(seed, cgb))
    twin_run(label, gb_maker(path), SilentRandomFrames, seed, gb_harness_poke, gb_silent)

for seed in [0xA901'u64, 0xA902, 0xA903]:
  let label = &"random gba {seed:#x}"
  if not wanted(label): continue
  let path = tmp / &"random_{seed:x}.gba"
  writeFile(path, gba_program(seed))
  twin_run(label, gba_hle_maker(path), SilentRandomFrames, seed, gba_harness_poke, gba_silent)

try: removeDir(tmp)
except OSError: discard

echo &"silent audio: {epochTime() - t_start:.1f}s"
if failures == 0: echo "ALL SILENT AUDIO CHECKS PASS"
else:
  echo failures, " FAILURE(S)"
  quit(1)
