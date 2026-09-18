# Playtest bug investigations

Bugs the cross-emulator playtest harness (tools/playtest) found in dingbat,
with the investigation state of each. Newest notes at the bottom of each
section; a section marked FIXED names its commit.

## 1. Sonic Advance 1 + 2 hang on grey bars at boot

**Cause (proven 2026-09-16):** RCNT is 0 after the skip-BIOS boot. The real
BIOS leaves it in general-purpose mode (bit 15 set); mGBA initialises it to
0x8000. With RCNT = 0x8000 forced at skip-boot, dingbat's Sonic Advance
frames are hash-identical to mGBA's from frame 60 on. dingbat's real-BIOS
boot (`--run-bios`) already worked: the BIOS writes RCNT itself.

Ruled out: the RCNT pin readout (bits 0-3 in multiplay mode read 0xF in
dingbat, 0x0 in mGBA; forcing 0 changed nothing).

Hardware question: which post-boot I/O values does the skip-BIOS path still
get wrong? tests/roms/bootio.gba dumps every I/O word at ROM entry plus
RCNT/SIOCNT write-readback experiments (see that file's header).

**FIXED:** the skip-BIOS boot now leaves RCNT = 0x800F, the value dingbat's
real-BIOS path produces. Sonic Advance and Sonic Advance 2 playtests PASS
(play identical to mGBA, saves cross-load). Sonic Advance 2's save still
differs from mGBA's in 28 bytes (3 ranges): not yet examined.

### What else the skip-BIOS boot got wrong (2026-09-17)

dingbat runs the real BIOS itself (`--run-bios`), so it is its own oracle for
this: boot both ways, stop the moment PC reaches 0x08000000, and diff every
CPU register, every I/O word and all of IWRAM/EWRAM/palette/VRAM/OAM. Then
log every I/O write the BIOS makes to see which values are deliberate. The
whole difference was five things, the same for every ROM tested:

- **RCNT** — the BIOS's last write is 0x8000, not the 0x800F assumed above
  (0x800F was an intermediate value of its multiboot probe). dingbat reads
  back 0x800F either way, because bits 0-3 read the pins, so this is a
  faithfulness fix, not a behaviour change.
- **SOUNDCNT_H = 0x000E** — PSG and both DMA channels at full volume. Was 0.
  (The FIFO reset bits the BIOS writes alongside are write-only.)
- **Wave RAM** — the BIOS clears it; dingbat left Channel 3's GB power-on
  pattern (0xFF00 per word).
- **LR = 0x08000000** — the BIOS branches to the entry point. Was 0.
- **The entry video phase was 14 cycles late.** Both boots enter on line 126
  at 838 cycles, but the BIOS arrives with the first two ROM words already
  fetched and paid for, while this path still has to fetch them. Starting
  14 cycles earlier (a non-sequential plus a sequential 32-bit ROM read at
  the boot WAITCNT of 0) makes the two boots run in exact lockstep: the PPU
  phase now matches at every one of the first 83,891 instructions, where
  before it diverged at instruction 1 and stayed 14 cycles apart forever.

What still differs is unobservable: elapsed cycles, the stale banked copy of
LR (overwritten by the first mode switch), TM0's frozen counter while the
timer is disabled (reloaded on enable), and SPSR in SYS mode (no such
register on hardware). Test runner unchanged at 1219/1171/48.

First emulator runs of bootio.gba (dingbat skip-BIOS vs dingbat real BIOS vs
mGBA), open-bus words aside:
- the skip-BIOS boot also differs from dingbat's real-BIOS boot in SOUNDCNT_H
  (0 vs 0x000E) and wave RAM (FF00 vs 0000 per word) and TM0's counter;
- RCNT data nibble: dingbat keeps what is written (80F5 reads 80F5), mGBA
  never stores it (reads 80F0);
- RCNT pins in normal/multi/UART/JOY modes: dingbat 5/F/F/C, mGBA 0;
- SIODATA32_L / SIOMULTI2 written in normal 8-bit mode: dingbat reads 0,
  mGBA reads the value back.
The hardware pages settle each of these.

## 2. Save state with a game-set clock fails to load (RangeDefect)

Rockman EXE 4.5 sets its clock to 2006, earlier than the harness's source
clock, so the RTC bias is negative. The writer wrapped it into a u64
silently; the reader's checked `int64(u64)` conversion raised. **FIXED** with
casts on both sides; tests/gba_rtc_test.nim covers a negative bias. The bias
code is only on this branch, so no shipped state is affected.

## 3. Rockman EXE 4.5 never saves (SRAM picked over FLASH512)

Library census (7906 ROMs, save-library strings): ROMs naming more than one
library are Medabots AX / Medarot G (EEPROM+FLASH), Kim Possible (J) / Kim
Possible 2 / Ueki no Housoku (EEPROM+FLASH512), Breath of Fire (J) / Super
Monkey Ball Jr (EEPROM+FLASH+SRAM), One Piece - Mezase! King of Paris
(SRAM+FLASH), Rockman EXE 4.5 (SRAM+FLASH512), Top Gun (all but EEPROM).
Save-memory writes logged over a minute of boot/menus in dingbat:
- Rockman 4.5: flash ID command only, then waits on flash (mGBA pins BR4J to
  FLASH512 + RTC).
- One Piece: flash ID command, then SRAM writes when no flash answers (with
  flash it erases/programs flash; mGBA autodetects flash from that command).
- Medabots, Kim Possible 2, Monkey Ball Jr: EEPROM first (dingbat's EEPROM
  pick matches). Ueki: flash ID then EEPROM (mGBA pins EEPROM; unchanged).
- Breath of Fire (J): no save access in that minute; unchanged (EEPROM).
**FIXED:** SRAM + a flash library without EEPROM -> that flash type
(storage.nim); tests/savestate_compat_test.nim covers the pairs.
(the harness's saves.py rom_info mirrors it). Rockman EXE 4.5 playtest now PASS: dingbat saves, all 9 cross-loads work, 9 bytes differ from mGBA's save.

## 4. Random outcomes differ on identical input frames (Yu-Gi-Oh! 2004 deck)

Not an RNG bug: a boot-timing phase. Method (tools in the session scratch,
recipe here): replay identical input in dingbat and mGBA, peek the game's
RNG seed (IWRAM 0x03000040) every frame. The sequences are identical; the
seed advances once per game frame, but dingbat reaches frame-13's value one
frame later than mGBA and stays one frame behind. The lag comes from a
per-frame count of TM0 IRQ bursts (TM0 reload 0xFCE2 = 798 cycles, 16
overflows per burst; 22 bursts per 280896-cycle frame exactly) taken in
the vblank path: dingbat counts 21, mGBA 22 -- the timer phase straddles
the snapshot.

Two causes found:
1. **Skip-BIOS video phase** (FIXED 9a3c7b7cd, test runner unchanged): dingbat started
   the PPU on line 0 at ROM entry; its own LLE BIOS boot hands over on line
   126, 838 cycles in (mGBA's skip-boot also uses line 126). TM0 phase vs
   mGBA at each frame boundary went from 367 to ~23 cycles. bootio.gba's
   VCOUNT word (0x006) photographs the hardware value.
2. **~50 cycles of ROM-access cost** between instruction 82,600 and the TM0
   enable at instruction 83,772 (dingbat vs mGBA cycle counts per
   instruction agree to +-2 before that). Too fine to call without
   hardware; the deck still differs. Left as is.

Side note: dingbat's harness frame 1 can end mid-frame when the boot halts
across two vblanks inside one CPU step (step_frame exits with frame=2); the
count realigns by frame 3.

### 2026-09-17: it is not a boot-phase offset, and Harvest Moon is the same bug

Two results from this round.

**The boot phase is exonerated.** With a temporary knob on the skip-boot
video phase, shifting it by -800, -600, -400, -200, -120 ... +130 cycles
never moves the frame at which Yu-Gi-Oh's seed reaches its next value
(dingbat 13, mGBA 12, at every offset). So the one-frame lag is not a
timer/vblank straddle that a few dozen cycles could tip, and the 14-cycle
entry fix above, though right, does not decide it either.

**dingbat's ROM timing diverges when the prefetcher is switched on.**
Stepping dingbat and mGBA instruction by instruction from ROM entry and
diffing their cycle counts: they agree to within the 0..2 cycles of
intra-instruction accounting for the first 82,688 instructions. At
instruction 82,689 the game writes WAITCNT 0x0003 -> 0x4014 — bit 14, the
gamepak prefetcher — and from that instruction on dingbat accumulates about
one extra cycle per 17 instructions, reaching +66 by instruction 83,821,
where the timer the RNG reads is enabled. mGBA and the second reference
produce byte-identical saves here; dingbat is the odd one out.

dingbat's prefetch model is pinned against the mGBA suite's ROM timing rows
and passes every one of them. The single failing row in the whole 6998-test
suite is "DMA Prefetch Break" (0x100026D4 vs an expected 0x10002A94, 960
cycles fast) — the one hardware-anchored prefetch discrepancy we have, and
the obvious next thread to pull.

Recipe: `cycdump` (a Nim tool stepping the CPU and printing cycles per
instruction) against the mGBA driver's `stepn 1`, comparing the running
delta's envelope rather than per-instruction costs, which differ harmlessly
because the two emulators charge bus cycles at different boundaries.

**Harvest Moon FoMT is the same bug, not a separate one.** Its farm_intro
checkpoint differs because the farm's random debris (branches, stones,
stumps) is laid out differently; mGBA and the second reference agree with
each other and dingbat does not, and that layout is what makes its save
differ in 4051 bytes. Same shape as the Yu-Gi-Oh deck: identical input,
a different draw from a timing-seeded RNG.

After the phase fix the Yu-Gi-Oh! 2004 and Mario Golf AT playtests PASS on
their checkpoints, but their saves still differ from BOTH references (107
and 4 bytes): the deck/values are still one frame off. Harvest Moon FoMT
still FAILs at farm_intro (not traced; note early-frame RAM peeks in dingbat
are unreliable because of the frame-1 quirk above).
Probe commands added to the playtest drivers for this: mGBA `busread16 A`,
`stepn N`, `stepuntil A MASK` (single-steps, reports the master clock);
dingbat `layers MASK`. Instruction-level cycle comparison recipe: step both
N instructions from boot and diff dingbat `scheduler.cycles` vs mGBA
`mTimingGlobalTime` (a Nim tool that ticks the CPU; do not poll I/O between
ticks, bus reads cost cycles).

## 5. Boktai: "Solar Sensor is broken."

**FIXED:** GPIO solar sensor for game codes U3I* / U32* / U33* (gpio.nim,
GBATEK "GBA Cart Solar Sensor"): bit 1 resets a counter, bit 0 rising edges
count, bit 3 reads 1 once the counter reaches `solar_level` (default 0xE8 =
no sunlight). Verified: with the sensor removed the message appears at frame
~4476 of the scripted run; with it the intro continues. tests/gba_rtc_test.nim
covers dark/bright measurements. **Open:** no frontend control yet for
`gpio.solar_level` (desktop/web), so the in-game sun gauge stays at zero.

## 6. Fire Emblem: The Sacred Stones, one-step colour on two menus

Not resolved. At select_mode BLDCNT=0x3C42 (BG1 over BG2/BG3/OBJ/BD),
BLDALPHA=0x030D (13+3). dingbat's pixels differ from both references on
~12k pixels, mostly 1-3 steps darker, some white pixels 29 vs 31 -- more
than blend truncation explains, so a layer input (BG1/BG2 content or frame
phase of the animated fog) differs. The references agree with each other
though their checkpoint frames differ by 5. The verdict itself came from OCR
noise on the text. mGBA's enableVideoLayer segfaults in the headless build,
so a per-layer comparison needs another route (dump BG1/BG2 tile+palette
state in both at the same frame).

**2026-09-17: the heading is wrong, but it is not a frame offset either.**
Both failing checkpoints sit on menus over an animated background, and *no
two* emulators agree on them: dingbat~mgba 69% of pixels exact, dingbat~nba
70%, mgba~nba 85%, all with channel deltas of 15-20. So the references
disagree with each other here in the same way, only half as much.

The obvious explanation, that each emulator samples the animation at a
different point, was tested and does not hold. The classifier now also
cross-compares the two recorded hash windows (not just each centre frame
against the other's window), and the windows were widened to 200 frames as
an experiment: dingbat still never renders a frame mGBA also rendered, and
neither does the second reference. On these screens no two emulators ever
produce an identical frame at any offset, so exact-frame comparison cannot
adjudicate them at all, and the pixel metrics are all we have. They put
dingbat about twice as far from either reference as they are from each
other - suggestive, not conclusive.

Note for anyone re-running this: widening a checkpoint's window shifts every
later checkpoint, because collecting the window advances the emulator. The
experiment above turned the next checkpoint from IDENTICAL into SLIP(-3)
purely that way. The windows in the script are back to 30.

Still the most likely reading is the original one: a layer input (the
animated fog's content or phase) differs, not the blend, which is
hardware-verified. Needs a per-layer dump in both at the same frame.
