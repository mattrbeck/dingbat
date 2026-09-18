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


## 7. Prefetch: Thumb code with internal cycles (the Yu-Gi-Oh residue)

`tests/roms/prefetchbench.{s,py}` times nine instruction patterns across four
wait settings. Eight are cycle-identical in dingbat and mGBA, ARM and Thumb
alike. One is not, and the ninth subject says which emulator is wrong:

| subject | waits | dingbat | mGBA |
|---|---|---|---|
| thumb multiplies (from ROM) | 3/1 prefetch ON | 340 | 212 |
| thumb multiplies (from ROM) | 3/1 prefetch off | 535 | 535 |
| thumb multiplies (from ROM) | 4/2 prefetch ON | 357 | 239 |
| thumb multiplies (from ROM) | 4/2 prefetch off | 614 | 614 |
| **the same block, from IWRAM** | any | **333** | **333** |

Subject I copies that exact multiply block into IWRAM and times it there, so
it costs no cartridge fetch at all. Both emulators agree it takes 333 cycles.
That is a floor: the prefetcher can hide the cost of fetching an instruction,
but nothing can make an instruction execute faster than its own internal
cycles.

dingbat's cartridge run with the prefetcher on is 340, seven cycles above the
floor -- the buffer hiding almost all of the fetch, which is what the
hardware is supposed to do. mGBA's is 212, which is 121 cycles *below* its
own floor: with its prefetcher on, code in the cartridge runs faster than the
same code in zero-wait RAM. That cannot happen on hardware.

**So dingbat is most likely right here and mGBA is wrong**, and the reading
in section 4 was backwards: dingbat is not drifting slow through Yu-Gi-Oh's
Thumb code, mGBA is running it fast. The second reference agrees with mGBA on
the resulting deck, so either it shares the model or it is fast for its own
reasons; it exposes no cycle counter, so this bench cannot ask it directly.

**Hardware has since anchored the floor.** `tests/roms/payloads/thumbmul.s`
runs that same multiply block on the console through the resident monitor,
and `tools/hwlink/payloadcmp.py` runs the identical bytes in both emulators
through the same IWRAM wrapper:

| | hardware | dingbat | mGBA |
|---|---|---|---|
| 64 Thumb multiplies, from IWRAM | **317** | 317 | 317 |

All three agree exactly, so the instruction timing underneath is right
everywhere and 317 cycles is what those instructions provably cost to
execute. mGBA's 212 for the same block fetched from the cartridge is about a
hundred cycles below that, which is no longer just inconsistent with its own
model -- it is below a measured hardware floor.

dingbat still was not changed on the strength of this. What hardware has
settled is that mGBA is wrong here, not that dingbat's number is right: 340
is plausible but unmeasured, and measuring it needs the block fetched from a
cartridge, which needs a flashcart. The wait-state path is measured and
matches: `tests/roms/payloads/waitcnt.s` agrees with both emulators on all
six settings on hardware.


## Suite snapshot, 2026-09-17

All 52 ready scripts, on the tree with this session's boot fixes: **46 pass,
6 fail**. The 19 `@status wip` scripts still need a human to play to a first
save.

| game | checkpoint | state |
|---|---|---|
| Fire Emblem: The Sacred Stones | select_mode, slots_empty | section 6 |
| Harvest Moon: FoMT | farm_intro | section 4 (same bug as Yu-Gi-Oh) |
| Advance Wars | 02_mark | not traced |
| Mario & Luigi: Superstar Saga | 07_mark | not traced |
| Wario Land 4 | difficulty | palette-cycle animation, known |
| Dragon Ball Z: The Legacy of Goku | -- | plays identically; a reference's save read back in dingbat differs |

Advance Wars and Mario & Luigi were re-run against a driver built from the
commit before this session's changes and fail identically there, so neither
is a regression -- both are pre-existing and previously went unnoticed. At
both failing checkpoints the two references disagree with each other as
well, which is the same shape as Fire Emblem's animated menus.


## 8. A second net: every game, no script

The suite above needs a recorded script per game, which is why it covers 52
titles out of a 7,899-ROM library. `tools/playtest/bootsweep.py` covers the
rest of the library at the cost of depth: it boots a game in all three
emulators, presses nothing, and watches for 40 seconds. That is enough for
the logos, the title screen and -- on most GBA titles -- the attract-mode
demo, which is real gameplay with real input, just not ours.

What it compares is deliberately not frame-by-frame. Two emulators a few
frames apart on an animating screen disagree on nearly every frame while
both being right, which is what the suite's SLIP verdict exists for. Here
each emulator's whole run is reduced to the *set* of frames it drew, and
what is counted is set difference: a frame hash one emulator produced that
another never produced at any point in the run. A timing slip cancels out of
that completely; drawing something nobody else ever draws does not.

A count on its own still means little, because a game that seeds its RNG
from uninitialised memory diverges in all three. So every emulator is scored
the same way against the other two and only the shape is read:

    dingbat 0     mgba 0     nba 0        nothing to see
    dingbat 850   mgba 12    nba 9        dingbat is the odd one out
    dingbat 900   mgba 880   nba 890      the game is nondeterministic

### Yu-Gi-Oh! The Eternal Duelist Soul — the sweep finds it too

The strongest signal so far, and it lands on a game section 7 already
traced by a completely different route: **1,813 odd dingbat frames in
2,400, and at 1,659 of them the two references drew byte-identical frames
to each other.** mGBA 163, the second reference 157.

At frame 1570 the references agree exactly and dingbat differs on 46 % of
the screen. The picture is the title screen; the logo and every line of
text are identical in all three, and what differs is the scrolling green
grid behind them, which dingbat draws at a phase neither reference ever
draws in 2,400 frames. Not merely offset in time -- an offset would put
dingbat's frames somewhere in a reference's run, and none of them appear.

**This is in tension with section 7, and both results should be kept.**
Section 7 measured on hardware that a block of Thumb multiplies costs 317
cycles from IWRAM, which puts mGBA's 212 for the same block fetched from
the cartridge about a hundred cycles below a measured floor -- mGBA's
prefetch model is wrong there. This sweep says that in the behaviour a
player can see, dingbat is the one that differs from both references at
once. Those are different claims and can both hold: being wrong about a
cycle count is not the same as being wrong about what reaches the screen,
and the two references can share a model that is wrong in a way that
happens to agree. What neither result gives us is dingbat's own number
measured, which still needs the block fetched from a cartridge, which
still needs the flashcart.

### Donkey Kong Country 2 (E)

The first real find, and it survives on the current tree (measured again
after rebasing onto `55c79b9fb`, so it is not a regression from the H-blank
DMA work and not fixed by it either):

| | odd frames in 2,400 |
|---|---|
| dingbat | 208 |
| mGBA | 1 |
| second reference | 4 |

The odd frames are not one event. There is a single one at frame 156 and
then a steady beat from frame 549 to frame 1279, one or two frames every
five or six -- something that repeats on the intro's animation cycle.

At frame 620 the two references are **byte-identical to each other** and
dingbat differs from both, which is the cleanest shape a finding can have
here. It is 3,006 pixels of 38,400, scattered along layer edges (the mast,
the rigging, the banner), mean absolute error 0.36, largest channel delta
25. Tested and rejected: a horizontal shift of any row by 1-4 pixels in
either direction improves not one of the 160 differing rows, so it is not a
scroll offset. The differing pixels are blend results -- dingbat draws
5-bit (6,6,6) where the references have (10,8,6), and so on through 257
distinct colour pairs -- which points at a colour special effect being
applied with a different coefficient, or on a different line, rather than at
geometry.

Nor is it a register left in the wrong state. Every readable PPU
register agrees at that frame -- DISPCNT, DISPSTAT, all four BGxCNT, WININ,
WINOUT, BLDCNT and BLDALPHA -- and `BLDCNT` reads 0, so whatever blend
produced those pixels was set up and taken down *within* the frame. (The
write-only registers cannot be compared this way: dingbat returns open bus
for the BG offsets, the window bounds, MOSAIC and BLDY, where mGBA returns
the last value written. Reading open bus is the correct behaviour, so that
is not a finding.)

A per-scanline effect landing differently, then -- and the DMA channels
say which one. At that frame DKC2 has **DMA0 armed on H-blank, repeating,
writing two halfwords from a table in EWRAM to 0x04000014**, which is
BG1HOFS and BG1VOFS: a per-line parallax scroll, driven by exactly the
mechanism docs/hwprobe-questions.md is still asking about. (The source
address and count are only legible in mGBA's dump, since dingbat returns
open bus for the write-only DMA registers.)

**The grant count is not the problem.** A per-frame H-blank grant census
(the DMA-phases work's `-d:dmacount`, run here on this branch) gives DMA0
**exactly 160 grants on every one of 536 frames**, with the source pointer
reading 0x0200679C at every V-blank against SAD 0x0200651C -- a difference
of 0x280, which is exactly 160 grants of two halfwords. The table is
consumed once per frame, completely, with no drift to accumulate. So the
difference is in *where in each line* the write lands, not how many land,
which puts it behind the same hardware column as everything else.

**Not the grant instant either, and this one is already measured.**
DKC2 scores an identical 208 odd frames on the tree before the H-blank DMA
work and on the tree after it -- that is, with the DMA requested at cycle
960 and at 1008. That moves all 160 per-line writes by 48 cycles and the
game's output does not change by a pixel, because dingbat renders a
scanline in one go and both grant points fall after line N's render and
before line N+1's. Whatever hardware says about a grant waiting on a bus
cycle is a few cycles on top of the 48 that demonstrably did nothing here.
So this is not behind `hdmasweep.s`, and saying so earlier was an
under-reading of our own data.

**Nor is it blending.** At a differing frame `BLDCNT` and `BLDALPHA` both
read 0000 in dingbat and mGBA alike, the two frames use exactly the same
197 colours, and of the differing pixels **not one** is a colour the other
emulator fails to draw somewhere else in the same frame. Blend arithmetic
invents values that need not exist in any palette; nothing here is
invented. It is selection, not arithmetic.

**What the composite tests can and cannot show.** No row of dingbat's
frame equals any row of the reference's within +/-60 pixels horizontally or
+/-24 lines vertically. That sounds like it rules out a scroll difference,
and an earlier version of this section said so. It does not. Three
background layers are enabled here, and if one layer's per-line scroll
differs while the others stay put, the composited row is neither layer
translated -- it is a different mixture of the same two palettes, which is
exactly what is observed: the same colours, rearranged within each row,
with no whole-row displacement in either axis.

**The per-layer dump names the layer: it is all BG1.** With one
screenshot per layer at the driver's frame 549, every one of the 301
differing pixels takes its visible colour from BG1:

| layer | lit pixels | supplies the visible colour at a differing pixel |
|---|---|---|
| BG0 | 10264 | 0 |
| BG1 | 38400 | **301** |
| BG2 | 0 | 0 |
| BG3 | 5024 | 0 |
| OBJ | 3268 | 0 |

and row by row: 119 -> 100 of 100 BG1, 127 -> 114 of 114, 135 -> 87 of 87.
Nothing else contributes a single pixel. BG1 is exactly the layer DMA0's
per-line writes to 0x04000014 steer, so the per-line scroll hypothesis
survives the one test that could have killed it, and the sprite layer --
which an earlier, contaminated run had supplying a third of the differing
pixels -- contributes none.

**And the per-line scroll trace says it is a vertical-offset boundary.**
With `-d:bgtrace` dumping what each text BG rendered every line with, BG1's
scroll on driver frame 549 changes at thirteen lines, and **every one of the
three differing lines is one of them -- 3 of 3**:

| line | BG1 (hofs, vofs) across the boundary | what moved | pixels differ |
|---|---|---|---|
| 23, 55, 69 | (65250,0) -> (65393,0) -> ... | hofs | no |
| 79 | (65500,0) -> (0,1) | hofs+vofs | no |
| 86, 94, 102, 110 | (0,1) <-> (0,0) | vofs | no |
| **119, 127, 135** | **(0,1) <-> (0,0)** | **vofs** | **YES** |
| 143, 151 | (0,1) <-> (0,0) | vofs | no |

So the differences sit exactly where BG1's *vertical* offset changes, on the
last line before it changes, and never where only the horizontal offset
moves. The ten vertical boundaries that do not differ are the ones where
BG1 has no horizontal edge for a one-line shift to reveal -- vofs 0 against
vofs 1 is invisible on uniform content, which is also why the three that do
differ are consecutive and in the busiest part of the picture.

That makes this a question about *when a per-line vertical scroll write
takes effect*, one line either side, rather than about the scroll values
themselves, which are what they should be. It is the renderer's latch, not
the DMA's arithmetic -- consistent with the rows being tile-bottom lines,
and consistent with the grant instant having been measured as irrelevant.

**Where this stops, deliberately.** The values are correct, the timing of
their effect is unknown, a one-line latch is suspected, and nothing in
dingbat changes until that is settled. mGBA's own per-line trace would only
say the two emulators disagree, not which is right, and the documentation
does not pin the cycle at which a text BG's vertical offset stops affecting
the line being fetched -- which is why this has survived this long. What
settles it is a photograph: a BG with a sharp horizontal edge, its vertical
offset driven from a per-line table toggling every eight lines exactly as
DKC2 drives it. The edge's zigzag shows directly which line each shift lands
on, with no emulator in the loop. That is a visual probe page, and the link
rig cannot answer it because composited pixel output is not CPU-readable.

**Does any other game show the same signature?** Screened all 26 flagged
games at their sparsest witnessed frame: **no**. Every game's differing rows
are tile-bottom in about one case in eight, which is what chance gives, and
the sparse cases are other shapes entirely -- X-Bladez differs on rows 53,
77, 117, 119, 122, 124 (one tile-bottom), a Yoshi's Island trainer on rows
32-39 (exactly one whole tile row), Billy Hatcher on row 84 alone. Only
Super Donkey Kong 2 (J) matches DKC2's shape, and that is the same game.

So the latch does not gain priority from the sweep. **The screen is weak
evidence, though, and should not be read as a clean negative:** it samples
24 frames per game, and it did not find DKC2's own frame 549 either -- it
picked frame 711, where DKC2 differs on one row that is not tile-bottom. A
sensitive version would have to examine every witnessed frame of every
flagged game.

Two cautions earned the hard way while taking this, both now fixed upstream
and both recorded in section 9: `dingbat_test` wrote GBA screenshots in
greyscale, and its `--nosave` never detached a GBA battery. Any per-layer
figure taken before those fixes is void -- including the earlier reading of
this very frame, which is why the OBJ share above is 0 and not a third.
Settling it properly needs a per-layer dump at one frame in both emulators,
which is also what Fire Emblem (section 6) has been waiting on.

Not traced further. The screenshots and the per-row analysis are
reproducible with `bootsweep.py show "Donkey Kong Country 2"`.

Two Pokemon Ruby ROM hacks flag as well (`Pokemon Ambar`, `Obsidian Demo
1`), both with the same shape at the same frame, 766. They share a base, so
they are one finding, and being hacks they are weak evidence about hardware;
the sweep's dump filters do not catch a hack that is not marked as one.


### The sweep's flags so far

659 of 2,297 library titles swept (the run continues; results land in
`tools/playtest/out/bootsweep/results.json` as they come). `bootsweep.py
triage` re-runs everything flagged and ranks it by the share of dingbat's
lone frames where the two references drew byte-identical frames to each
other:

| share | witnessed | game |
|---|---|---|
| 92 % | 1659/1813 | Yu-Gi-Oh! The Eternal Duelist Soul (U) |
| 100 % | 207/208 | Donkey Kong Country 2 (E) |
| 38 % | 367/963 | X-Bladez: Inline Skater (E) |
| 24 % | 51/216 | four "2 Games in 1" Sonic compilations |
| 0 % | 0/966 | R-Type III (E) |

R-Type III is what the metric is for: 966 lone frames, and the references
never once agree with each other on any of them, so there is nothing to
arbitrate and it is not a finding. The four Sonic compilations are one
finding, not four -- they share a title screen whose shine all three
emulators draw at a different point of its sweep. X-Bladez is real but
sub-perceptual: at the frame triage picked, dingbat and the references are
the same picture to the eye and to three decimal places of matching pixels.

Which leaves Yu-Gi-Oh and Donkey Kong Country 2 as the two worth a person's
time, and they are the two written up above.


### The shape the strong flags share

Three of the four strongest flags are the same picture at different
addresses: an element that animates continuously, drawn by dingbat at a
phase that neither reference ever draws in 2,400 frames, while the two
references agree with each other exactly.

| game | the animating thing | witnessed |
|---|---|---|
| Yu-Gi-Oh! The Eternal Duelist Soul | the scrolling grid behind the title | 1659/1813 |
| Kaeru B Back (J) | the gears turning behind the logo | 1360/1877 |
| Donkey Kong Country 2 (E) | the per-line parallax scroll | 207/208 |

(DKC2's entry here is about which part of the picture moves, not a claim
about the cause; see its own section for what has been ruled out.)

In each the static parts -- logo, text, sprites -- are identical in all
three emulators, and only the moving thing differs. That is worth saying
plainly because of what it rules out: a renderer that drew a tile or a
colour wrong would not restrict itself to the animating element, and a
pure timing offset would put dingbat's frames somewhere in a reference's
run, where none of them appear. What fits all three is the *rate* at which
something advances -- a counter driven off a timer, an IRQ or the cycle
cost of the code that updates it -- being slightly different in dingbat,
so its phases fall between the ones the references produce rather than
among them.

That is a hypothesis, not a finding, and it is the same family as section
7's disagreement about what a block of code costs. It predicts something
checkable: the games that flag this way should be the ones whose animation
is driven from code whose timing section 7 disputes. Nobody has checked
that yet.


## 9. Two harnesses on the same core disagree

Found while trying to take a per-layer screenshot of the Donkey Kong Country
2 frame above. `tests/dingbat_test.nim --mode=screenshot` and
`tools/playtest/drivers/dingbat_driver.nim` are the same emulator built from
the same tree, both HLE, both `run_bios = false`, both calling `post_init`,
both taking no input. On Donkey Kong Country 2 (E) they produce **byte-
identical frames at 10 and 30, and completely different ones from 60**:

| driver frame | dingbat_test | pixels differing |
|---|---|---|
| 10 | `--timeout=10` | 0 |
| 30 | `--timeout=30` | 0 |
| 60 | `--timeout=60` | 38400 (all) |
| 120 | `--timeout=120` | 38400 |
| 300 | `--timeout=300` | 38218 |
| 549 | `--timeout=546..553` | ~38263 at every offset |

**Half of it was a battery file, and that half is fixed.** `--nosave`
never detached the GBA battery -- it only blanked the GB cartridge -- so
`dingbat_test` pointed at the library silently loaded the `.sav` sitting
beside the ROM while the playtest harness, which symlinks into its own
directory, booted blank. On a battery game the two then agree until the
frame the save is first read. With that fixed (a `--nosave` run and a
scratch-symlink run now agree to the pixel), the table above becomes:

| driver frame | differing, battery detached |
|---|---|
| 60 | 0 |
| 120 | 0 |
| 300 | 37982 |
| 549 | 37971 |

**The other half was greyscale, and the bisect was measuring a
sunrise.** `dingbat_test` wrote GBA screenshots as luma -- a Game Boy
default the GBA path inherited, since the DMG screenshot suites compare
against grey references -- so against a colour reference every *lit* pixel
differed. The "first divergence at frame 166, growing to the whole screen by
210" was a scene fading in, one newly-lit pixel at a time: 0 while the
screen was dark, 43 as a logo began to appear, ~37,900 once it was lit.
Nothing was amplifying.

That also explains why every elimination came back negative. Both harnesses
really were deterministic, the keys really were identical, the offsets
really were all equally wrong, and the idle-loop fast-forward really did
change nothing -- because the difference was not in the emulation at all.

Fixed upstream, and with it the two harnesses agree to the pixel. The
mapping is **`--timeout` = driver frame + 1**, verified exact at driver
frames 300 and 549; the 336-pixel residual that survived the colour fix was
that off-by-one.

The lesson worth keeping is not about screenshots. Three real defects hid
behind what looked like a core divergence -- a battery that would not
detach, a harness pointed at a read-only library, and a colour space -- and
each was found by taking the comparison seriously rather than explaining the
number away. A harness that disagrees with another harness is a bug
somewhere, and it is usually not where the interesting code is.

This matters beyond one game: a screenshot from one harness cannot be used
to explain a finding from the other until it is resolved, which is what
blocked the per-layer dump. Whichever is wrong, one of the two is not
running what we think it runs.

**A trap found alongside it:** `dingbat_test` writes its battery file beside
the ROM. Pointed at the library it will create a `.sav` inside
`~/Documents/emu/gba/archive/roms`, which is read-only by convention. The
playtest harness symlinks each ROM into its own environment directory for
exactly this reason; anything else driving `dingbat_test` over the library
should do the same, or pass `--nosave`.


## 10. The hardware run, 2026-09-18

All six queued payloads, on the SP over the link cable. These belong in
docs/hwprobe-results-agb.md with the other sessions; they are here because
that file is another branch's and this is where the payloads were written.

**waitprobe -- an empty cartridge slot honours WAITCNT.** 256 loads from
0x08000000, hardware with no cartridge against the emulators with one:

| WAITCNT | 0x0000 | 0x0004 | 0x0008 | 0x000C | 0x10000 | 0x1000C |
|---|---|---|---|---|---|---|
| hardware | 3588 | 3332 | 3076 | 4612 | 2819 | 3843 |
| both emulators | 3588 | 3332 | 3076 | 4612 | 2819 | 3843 |

Identical to the digit, and 4612 - 3588 = 1024 exactly as predicted from
N + S per load. Wait states are the memory controller's, not the
cartridge's, and the rig can measure them with an empty slot -- which is
what licenses hdmasweep's ROM rows below.

**hdmasweep and hdmamul -- the DMA grant waits for the bus cycle.** Fourteen
rows each, sweeping where in the CPU's access the H-blank request lands:

| | rows |
|---|---|
| hdmasweep (32-bit ROM load, 8 waits), hardware | 219 219 218 216 227 227 216 227 227 227 227 227 227 227 |
| hdmasweep, dingbat | 226 on all fourteen |
| hdmamul (four internal cycles, bus idle), hardware | **227 on all fourteen** |
| hdmamul, dingbat | 226 on all fourteen |

The load page varies and the multiply page is flat, so the grant defers to
the CPU's **bus cycle** in flight and not to the instruction: a request
landing inside a multiply waits for nothing. dingbat models no deferral at
all, and is also one cycle off the no-deferral baseline (226 against 227).

**swiedge -- the HLE BIOS arithmetic is exactly right.** All 24 answers
byte-identical across hardware, dingbat and mGBA: GetBiosChecksum
0xBAAE187F, Div by zero, 0x80000000 / -1, Sqrt at both ends of its range,
ArcTan2 on all four axes and at the origin. dingbat replaces these calls
with its own code and gets every edge case the real BIOS gives.

**psgfirst and psgwhy** are the sound-channel pages; their rows are in the
message trail to the session that owns that model, and psgwhy disagrees with
both emulators at five rows. Two worth naming: at f = 0x7FF with NR10 = 0x01
hardware's channel rises and then dies at once where both emulators never
start it, and with ch2 triggered first hardware never starts ch1 where both
emulators run it normally.

### The link would not come up, and that is not an absent console

Twenty-five cold opens handshook **three times**; the other twenty-two read
`FFFFFFFF` on every transfer, which is indistinguishable from a console that
is switched off. The console was power-cycled twice and the adapter replugged
before the fault turned out to be in `open_link`.

The failure is entirely in initialisation -- an open that comes up is then
solid, every transfer clean -- so `open_link` now probes with a benign word
(0x6202, answered in the multiboot loop and echoed by a running monitor, so
it works whatever state the console is in) and re-issues the whole sequence
until the link answers, up to 40 attempts. A dead link and an absent console
are no longer the same symptom.


## 11. Two more from the rig, 2026-09-18

Both ran with the slot empty and the monitor resident, so neither needed
anyone at the console.

### The prefetch question cannot be answered with an empty slot

Reading the gamepak region with no cartridge in it does not return the
address pattern all the way. The first access of a word reads the latched
address, and the sequential second access reads a floating bus:

| address | 0x08000000 | 0x08000004 | 0x08008680 | 0x0A000000 | 0x0E000000 |
|---|---|---|---|---|---|
| word read | `FFFF0000` | `FFFE0002` | `FFFF4340` | `FFFF0000` | `FFFFFFFF` |

The low halfword is `addr >> 1` exactly, every time; the high halfword is
`FFFF` or `FFFE`, never the address. That settles a tempting idea: since the
low halfwords spell out a long run of harmless Thumb encodings (`0x0000` at
0x08000000 rising to `0x3FFF` at 0x08008000, all data-processing on low
registers, with 64 consecutive `MUL`s at 0x08008680), it looked as though
code could be *executed* from an empty slot and the prefetcher measured
without a cartridge. It cannot: sequential fetches -- which is what
straight-line execution is made of -- read `FFFF`, and `0xF800`-`0xFFFF` is
the `BL` suffix, so the CPU would branch somewhere unpredictable within two
instructions. **prefetchbench.gba genuinely needs the flashcart.**

### pfram.s -- the floor for prefetchbench, measured on silicon

What the rig *can* do is the other half of the subtraction. `pfram.s` runs
prefetchbench's eight subjects out of IWRAM, where no opcode comes from the
gamepak and the prefetcher never engages, so the cartridge run's prefetch
effect is (cartridge - this) per subject rather than (cartridge - an
emulator's idea of the floor).

All 32 rows -- eight subjects by four wait settings -- are identical on
hardware, dingbat and mGBA:

| subject | 3/1 | 4/2 | | subject | 3/1 | 4/2 |
|---|---|---|---|---|---|---|
| arm nops | 263 | 263 | | thumb nops | 263 | 263 |
| arm loop | 518 | 518 | | thumb loop | 518 | 518 |
| arm nops+load | 520 | **584** | | thumb nops+load | 522 | **586** |
| arm multiplies | 137 | 137 | | thumb multiplies | 317 | 317 |

Two results fall out of it. The prefetch-on and prefetch-off columns are
equal on every row including the two that load from the gamepak, so **the
prefetch buffer does not serve data loads** -- GBATEK says opcode fetches
only, and this is that claim measured rather than assumed. And the two
gamepak rows move by exactly 64 cycles between the wait settings, 2 cycles
across 32 loads, which is waitprobe's empty-slot result again from a
different direction.

It also gives **linkreport.inc its first run on hardware**. The block came
back over the stream byte-identical to the same block read through the
monitor's own `read_mem`. That path is how the cartridge run reports, so it
is now proven before the run that needs the cartridge rather than during it.

### obusprobe.s -- what an unmapped read returns

Reads of 0x10000000, which nothing answers. Seven rows; hardware disagrees
with dingbat on three and with mGBA on one, and no two of the three agree
everywhere:

| | hardware | dingbat (was) | mGBA |
|---|---|---|---|
| ARM ldr | `E58A0000` | same | same |
| Thumb ldr, load at 0x030000F0 | `3E0260A8` | `60A860A8` | same as hw |
| Thumb ldr, load at 0x030000FA | `61283E02` | `61286128` | same as hw |
| Thumb ldrh, load at 0x03000104 | `000061A8` | same | same |
| Thumb ldrh, load at 0x0300010E | `00003E02` | `00006228` | same as hw |
| unmapped read 0 instr after a DMA | `E59F0068` | same as hw | `E58A0034` |
| unmapped read 1 instr after a DMA | `DEADBEE3` | same | same |
| unmapped read 2 instr after a DMA | `E59F0024` | `DEADBEE3` | same as hw |

**The Thumb composition, closed.** This was THUMBBUS in
docs/hwprobe-questions.md, carried as "deferred". A Thumb fetch is a
halfword, so the 32-bit bus value has to be made of two of them, and the
rule is not fetch order: each of the two most recent fetches, `$+2` and
`$+4`, lands in the half of the latch **its own address bit 1 selects**. The
two loads above are the same instruction at the two alignments and that is
the only thing separating them -- at 0x030000F0, `[$+2]` = 3E02 is the high
half and `[$+4]` = 60A8 the low; at 0x030000FA the same two swap places.
dingbat duplicated `[$+4]` into both halves, which is right only when they
happen to be equal.

The fix is **conditional on the bus width the code is fetched over**, and
finding that out was the whole of the work. Composing everywhere costs 40
I/O rows and 6 Timing rows of the mGBA suite, because that suite reads its
write-only registers from ROM-resident Thumb code, and a 16-bit bus cannot
fill both halves of a 32-bit latch from one fetch -- there the duplicate is
what hardware gives. So the pair applies in the 32-bit-wide regions only:
BIOS, IWRAM and OAM. IWRAM is the one measured; the other two are the same
bus width and no row in any suite executes from either. With that condition
the 1219-row runner and every mGBA suite section are **row-identical** to
before, and the four Thumb rows above match hardware.

**The post-DMA window, still open.** Hardware puts the DMA's last word on
the bus for exactly one instruction: the read immediately after the enable
store sees an opcode (the burst has not run yet), the next one sees
`DEADBEE3`, and the one after that is back to an opcode. dingbat holds the
word one instruction too long and mGBA releases it one too early, so each is
wrong at one end and they are wrong at opposite ends. dingbat's condition in
`read_open_bus_value` is `dma_request_at > fetch_start and <= read_start`,
and the distance-2 read should fail the first test but does not, which points
at `fetch_start` after a burst rather than at the window itself. Left alone
deliberately: three games named in that comment depend on the word surviving,
and this page probes one shape only -- an immediate DMA3 to EWRAM, from ARM
code. `obusprobe.s` reproduces it in seconds when someone picks it up.


## 12. Checking what section 11 assumed, 2026-09-18

Section 11 gated the Thumb open-bus pair on the width of the bus the code is
fetched over, and the only evidence for the gate was that the mGBA suite
agreed with it -- which is the same as assuming the suite is right. Two
payloads test it instead. Both ran with the slot empty and the monitor
resident.

### obusbus.s -- the gate is right, and its OAM arm is wrong

The identical Thumb block, copied rather than reassembled, run from four
memories of known width, each reading 0x10000000. The two rows per memory are
the same load at the two word alignments:

| memory | width | bit 1 clear | bit 1 set | composition |
|---|---|---|---|---|
| IWRAM | 32 | `3E026028` | `60A83E02` | the two fetches, placed by bit 1 |
| EWRAM | 16 | `60286028` | `60A860A8` | `[$+4]` duplicated into both halves |
| VRAM  | 16 | `60286028` | `60A860A8` | the same |
| OAM   | 32 | `606E6028` | `60A83E02` | the aligned **word** holding `$+4` |

Identical with the display on and forced blank, so the OAM row is not the PPU
competing for the bus.

**The gate holds.** Two independently measured 16-bit memories duplicate
`[$+4]`, which is exactly what dingbat does outside the wide regions, and the
cartridge bus is 16 bits wide too. So the 40 I/O rows and 6 Timing rows that
composing everywhere cost were not masking a second bug -- the suite was
right and the gate is hardware-correct, now by measurement rather than by
agreement.

**But bus width is the wrong rule.** OAM is 32 bits wide and does not compose
a pair: it hands back the aligned word holding `$+4`, which is what ARM code
gets. What decides the answer is how much of the latch one fetch fills --
a 16-bit bus mirrors its halfword into both halves, IWRAM drives only the
half its address selects and leaves the other half holding the previous
fetch, and OAM fills the whole latch at once. Three cases, not two. dingbat
had OAM in IWRAM's case on the reasoning that both are 32 bits wide; fixed,
with both gates row-identical. No game executes from OAM, so the value here
is the mechanism, not the row.

BIOS is the one region left unmeasured -- a payload cannot execute there --
and stays with IWRAM, the memory it shares a bus with.

### hdmasweep.s -- the H-blank grant does defer, at some phases

gbaedge slot 53, the page the mGBA suite's last red row has been waiting on,
run for the first time. It asks whether the H-blank DMA grant waits for the
CPU's bus cycle to end, by shifting the request inside a loop of 8-wait ROM
loads with a pre-delay of k one-cycle NOPs and measuring anchor-free as
(V-blank write - H-blank write). A larger number means the H-blank DMA landed
earlier. Six runs:

| k | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8-13 |
|---|---|---|---|---|---|---|---|---|---|
| hardware | 216-219 | 217-219 | 216-218 | 227 or 216 | 227 | 227 | **216** | 227 | 227 |
| dingbat | 226 | 226 | 226 | 226 | 226 | 226 | 226 | 226 | 226 |

The method's own control passes on hardware every run: the IWRAM row reads
227 and (IWRAM k=7) - (IWRAM k=0) is 0, so one-cycle accesses give no spread
and the ROM rows mean what they claim. **mGBA's control fails** -- its
`+30` reads -1, a spread where there can be none -- so its rows on this page
are noise and are not a third opinion.

Neither of the page's two predictions is what came out. It is not a sawtooth
falling one cycle per k, and it is not flat: most phases show no deferral at
all, k = 6 shows a stable **11-cycle** deferral in all six runs, and k = 0-3
sit in an unstable band that tips between the two. So a deferral is real on
silicon and depends on where in the CPU's bus cycle the request falls, but
not in the shape the page was drawn to catch.

**dingbat models none of it** -- 226 flat across every k, including the
phases where hardware loses 11 cycles. That is the mechanism the suite's
`DMA Prefetch Break` row plausibly needs, because the suite's own request
lands inside a long ROM access; grant-at-1012 was only ever a fit to that one
row, and hardware already refuted it (p50: the grant is at flag + 2).

Two things left alone deliberately. The deferral itself is a scheduler
change, and the DMA grant deferral is another session's piece of work; this
is the measurement it needs, not a patch. And dingbat sits **1 cycle** below
hardware on every undeferred row including the IWRAM control (226 vs 227) --
p50 calibrated the H-blank request against absolute stamps and found flag + 2
exact, so the residual cycle is more likely on the V-blank DMA's side than
the H-blank one. Neither constant should move on one page.

### psgwhy.s -- ch1's dying trigger enables first, and it is the sweep

gbaedge slot 52, also run for the first time. p44 and p51 could only watch
SOUNDCNT_X bit 0 *fall*, so neither could tell a trigger that never enables
from one that enables and is then killed; this page polls for the rise too.

**Four runs, and six of the fifteen rows vary between them**, so the page
cannot be read as a whole. The payload runs from IWRAM and the probe's poll
loop was written cartridge-resident, so it polls faster here than the rows
were calibrated for and races the frame sequencer -- the same caveat already
noted for p52's fall counts, now visible as instability. Only the rows that
repeated in all four runs are reported:

| row | hardware | dingbat / mGBA |
|---|---|---|
| f = 0x400, length on (**the dying row**) | enabled, then died at once | healthy, stays on |
| f = 0x3FF | healthy | healthy |
| f = 0, length on | healthy | healthy |
| f = 0x7FF, shift 1 (a real sweep overflow) | enabled, then died at once | **never enabled** |
| retrigger straight away | never enabled | healthy |
| nothing routed (SOUNDCNT_L = 0) | enabled, then died at once | healthy |

Two things close on those rows alone.

**The open question was a false dichotomy.** docs/hwprobe-questions.md
carried "never-enables vs active bit rises late" for this row. It is neither:
the bit is already set on the first poll after the store and has fallen by
the next. The channel turns on and is then killed.

**The f + f sweep candidate holds.** f = 0x400 dies, f = 0x3FF lives, f = 0
lives -- exactly the boundary where the overflow check `f + f` reaches the
limit 0x800, and it is the frequency that decides it. The page was written to
test that and the stable rows fit it.

**Both emulators have the mechanism backwards** on the one row where a sweep
overflow is unambiguous (f = 0x7FF, shift 1): they refuse the trigger, so the
channel never enables, where hardware accepts it and kills it immediately
after. Nothing changed here -- this is the PSG thread's to land, the unstable
rows should be settled first from a cartridge or with a rate-matched poll
delay, and a trigger that enables for one poll is audible where a refused one
is not.

### hdmamul.s -- and the grant rule, settled

hdmasweep's companion, and the page that turns its odd shape into a rule. It
is hdmasweep with one line changed: the poll loop's `ldr r0, [r3]` from the
gamepak becomes `mul r0, r3, r6` on two large operands, which on an ARM7TDMI
is four internal cycles with the bus idle. Its own decision table:

* both pages sawtooth -> the grant waits for the instruction, bus or not
* the load defers, the multiply is flat -> it waits for the **bus cycle**
* both flat -> the grant is PPU-timed and neither wait exists

Hardware is **227 on every k, in all six runs, with no variation at all** --
the flattest row this rig has produced. Against hdmasweep's loads, which lose
a stable 11 cycles at k = 6 and tip run to run at k = 0-3, that is the middle
line:

**the H-blank DMA grant waits for the CPU's bus access in flight, and waits
for nothing when the CPU is busy with no bus access.** An internal cycle
never delays it. That is the rule the two pages were written to decide, and
it is now decided.

It also rules out the reading that hdmasweep's non-sawtooth shape means no
deferral exists: if the grant ignored the bus, the load page would be flat
too, and it is not.

The same 1-cycle gap shows here for the third time -- hardware 227, dingbat
226, on a loop that touches no cartridge at all. Three independent loops (ROM
load, IWRAM load, multiply) all put dingbat exactly one cycle below hardware
on this measurement, which makes a constant offset in one of the two DMAs far
more likely than anything phase-dependent. p50 pinned the H-blank request
against absolute stamps, so the V-blank side is the place to look. Not
changed here: one page should not move a constant that three games and the
suite's last red row sit on.

mGBA's rows on this page wander between 0xE0 and 0xE3 with no pattern, as
they did on hdmasweep.

### swiedge.s -- the HLE BIOS, checked against Nintendo's

dingbat ships an HLE BIOS, so every arithmetic SWI is our code standing in
for Nintendo's, and until now it had only ever been checked against itself.
The console in the rig runs the real thing. Same payload, same inputs, one
side executing the actual BIOS.

**0 of 96 bytes disagree.** All 24 answers match on hardware, dingbat and
mGBA, and they are deliberately the cases where an implementation has to have
made a decision rather than the ones any implementation gets right:

* `GetBiosChecksum` = `BAAE187F`, the AGB BIOS
* Div 1/0 and -1/0 -- the sign of the numerator is kept
* Div `0x80000000 / -1`, the one quotient that overflows
* Div -7/2 -- the rounding direction and the sign of the remainder
* Sqrt at 0, 1, `0x3FFFFFFF` and `0xFFFFFFFF`, both ends of the range
* ArcTan2 at the origin, on all four axes and on the diagonal

So the HLE arithmetic is right, not merely self-consistent. The open HLE
question is unaffected and remains what it was: the *cycle costs* of these
bodies, where Sqrt is up to 3x off (docs/hwprobe-questions.md, SWITIME).


## 13. The post-DMA open-bus latch, measured, 2026-09-18

Aimed at the mGBA suite's last red row, `DMA Prefetch Break`. It did not
close it. What it did was replace the reasoning the row has been parked on
with measurements, and rule out the fix that reasoning implies.

docs/mgba-suite-verdicts.md parks the row like this: on hardware "the DMA's
word survives on the data bus only until the next gamepak fetch", so in a
ROM-resident loop the window is a slot a few cycles wide in the middle of an
instruction, where dingbat arms it for a whole instruction; therefore
"closing the row means dispatching a DMA part-way through an instruction,
not tuning a constant". Nothing had measured the premise.

### obuswin.s -- the window is cycles, not instructions, and not the gamepak

Same immediate DMA3 every row; only what sits between the burst and an
unmapped read changes.

| between the burst and the read | hardware | dingbat | mGBA |
|---|---|---|---|
| nothing | opcode | same | **wrong** |
| one 1-cycle NOP | **the DMA word** | same | same |
| two NOPs | opcode | **the DMA word** | same as hw |
| one MUL (1 instruction, ~4 cycles, no bus access) | opcode | same | **the DMA word** |
| one LDR from IWRAM | opcode | same | **the DMA word** |
| one LDR from EWRAM | opcode | same | **the DMA word** |
| one LDR from the **gamepak** | opcode | same | **the DMA word** |
| NOP, then a gamepak LDR | opcode | same | same |
| a gamepak LDR, then a NOP | opcode | same | same |
| one LDMIA of 4 registers | opcode | same | **the DMA word** |

Two claims die here. It is **not one instruction**: a single MUL, one
instruction that touches no bus at all, already closes it. And it is **not
"until the next gamepak access"**: that MUL never goes near the gamepak. The
surviving reading is the one dingbat's own field comment already states --
the word stays until the CPU's next bus access replaces it, opcode fetches
included, which is why a MUL's extra internal cycles are enough (they buy
another fetch) and why every load closes it (its own data cycle). The
suite's "next gamepak fetch" is that rule's ROM-resident special case.

### obuswint.s -- and the latch is per-halfword, which changes the shape

The same trials in Thumb, and this is the result that matters:

| NOPs between the burst and the read | hardware | dingbat |
|---|---|---|
| 0 | opcode | same |
| 1 | `DEADBEE3`, the DMA word | same |
| **2** | **`DEAD6019`** | `60A86019` |
| 3 | opcode | same |

At two NOPs hardware returns **half the DMA word beside a freshly fetched
opcode halfword**. The latch is per-halfword: a DMA fills both halves, and
later halfword fetches overwrite them one at a time, each into the half its
own address bit 1 selects -- the same placement rule closed as THUMBBUS this
morning (section 12). dingbat loses the DMA half entirely.

### What that rules out

`read_open_bus_value` answers this with a predicate -- the whole DMA word, or
no DMA word -- gated on `dma_request_at` falling between two cycle stamps. A
predicate of that shape **cannot produce `DEAD6019` at all**, whatever its
bounds. So the width is not the bug; the shape is.

That is also why the obvious fix fails. obuswin.s says the lower bound is one
fetch too early for ARM code in IWRAM (the two-NOP row should be an opcode
and dingbat returns the word). Moving it:

| lower bound | ARM/IWRAM rows | `DMA Prefetch Read` | `DMA Prefetch Break` |
|---|---|---|---|
| `> fetch_start` (shipped) | two-NOP row wrong | **PASS** | `0x10002540` vs `0x10002A94` |
| `> fetch_start + 1` | all correct | **FAIL** | `0x00000000` |
| `> fetch_start + fetch cost` | all correct | **FAIL** | `0x00000000` |

Both corrections make every measured ARM row right and cost a passing suite
row, and neither moves `Break` toward its target -- it goes to zero, i.e. the
loop stops seeing a word at all. Reverted; the suite and the 1219-row runner
are back to baseline exactly.

### What the next attempt should be

Model the latch instead of the window: a real 32-bit register, halves written
independently, updated by opcode fetches and by the last word a DMA moved,
and read back whole. That is the mechanism all three payloads agree on, it
subsumes the Thumb composition already in `read_open_bus_value` (which
recomputes the same value from `pc` on demand), and it is the only shape that
can return a half-and-half word. It is not a constant to tune, but neither is
it "dispatch a DMA part-way through an instruction" -- the verdicts doc's
conclusion followed from a premise that is now measured false.

It is a hot-path change touching three named games and several suite rows, so
it wants a session that can watch the gates, not a drive-by. `obuswin.s`,
`obuswint.s` and `obusprobe.s` reproduce every number above in seconds, and
`-d:obusdbg` prints the cycle stamps the current predicate turns on.


## 14. `DMA Prefetch Break`: what the window cannot do, and what can, 2026-09-18

Section 13 took the row's premise apart and left "model the latch as a
register" as the next attempt. That attempt was made and it is the wrong
target. The row does not turn on what the open-bus latch holds; it turns on
**when the H-blank DMA's word reaches the bus**. Below is the proof that the
window is not the lever, the measurement that says what is, and a prototype
that reproduces the measured behaviour for the first time.

### The test, read from its own source

`mgba-suite-auto/src/misc-edge.c`:

```c
u32* ptr = (u32*) 0x10000000;
DMA3COPY(&a, &b, DMA_HBLANK | DMA_SRC_FIXED | DMA_DST_FIXED | DMA_REPEAT | DMA32 | 1);
for (i = 0; i < 0x00008000; ++i) {
        u32 value = *ptr;
        ++ptr;
        if ((value & 0xFFC0FFC0) != 0x40004000) { out[0] = (u32) ptr; break; }
}
```

One word per H-blank, and a ROM-resident Thumb loop reading unmapped space
until a read is not the prefetched opcode. `out[0] = 0x10000000 + 4 x reads`,
so the constant `0x10002A94` is 2725 reads. The loop is exactly **36 cycles**
an iteration here, and dingbat's window is the 3-cycle slot
`(fetch_start, fetch_start + 3]`, so the exit is a phase coincidence between a
once-a-line event and a 36-cycle loop. Note the mask: a HALF-and-half latch
would also break the loop, which is why section 13's finding looked relevant.

### No bounds can close it

Two sweeps, both against the whole suite (one run is about a second):

* Every `(lo, hi)` in a 13x13 grid around the shipped bounds. `Break` takes
  **three values in the entire space** -- `0x00000000`, `0x100024B8` and
  `0x10002540`. The target is not among them.
* Better: disable the window entirely so the loop never exits, log the
  DMA-to-read phase offset for all 16384 reads, and evaluate **every**
  possible sub-instruction slot offline in one pass. The shipped slot
  reproduces 2384 exactly. Only two degenerate one-cycle slots at an offset
  of -11 (the burst landing eleven cycles before the load's own fetch, which
  is no mechanism at all) give 2725, and the achievable exit counts are
  otherwise **dense** -- nearly every integer is reachable by some slot.

Dense reachability is the important half. It means matching this constant by
choosing a window is fitting, not modelling, and a fit here would be worth
nothing: the suite's own `Flip` rows move by a skip quantum when the poll
loop's phase shifts.

### Nobody else passes it either

Both reference emulators were run on the same ROM to `ALL DONE`:

| | `Break` | reads | Misc |
|---|---|---|---|
| hardware (the ROM's constant) | `0x10002A94` | 2725 | -- |
| dingbat | `0x10002540` | 2384 | 11/12 |
| the second reference (`nba`) | `0x10002540` | 2384 | 11/12 |
| mGBA 0.10.5 | `0x100024B8` | 2350 | 6/12 |

dingbat and the second reference agree **bit for bit**, and mGBA's own value
is one of the three the bounds sweep reaches. Three independent cores landing
inside a three-element set is what a shared structural gap looks like.

### What the lever is, measured

Move the H-blank DMA request later and the row closes. At
`-d:HBLANK_DMA_REQUEST_DELAY=9` (and 10, 11, 12) the **entire suite is green,
6998/6998**, and across all 6998 rows the only line that changes versus the
shipped delay of 2 is this one flipping FAIL to PASS. A four-wide plateau with
zero collateral is not a knife-edge fit.

That constant is refuted -- but **not by hdmamul, and the first version of
this section said otherwise**. See "what hdmamul can and cannot see" below.
The payload rows:

| | hardware | dingbat @ delay 2 | dingbat @ delay 9 |
|---|---|---|---|
| hdmamul (multiply loop, bus idle) | **227 on all fourteen** | 226 flat | **219 flat** |
| hdmasweep (32-bit ROM load, 8 waits) | 219 219 218 216 227 227 216 227 227 227 227 227 227 227 | 226 flat | 219 flat |

### What hdmamul can and cannot see

hdmamul's stub arms DMA0 on H-blank to zero `TM0CNT_H` and DMA1 on V-blank to
zero `TM1CNT_H`, and reports `TM1 - TM0`. **It is a difference between the two
DMAs' writes, and pins neither absolutely.** So it is blind to a common-mode
offset: move both grants by the same amount and it cannot tell. Measured,
moving both together (H-blank at 2+k, V-blank at k):

| H / V request | suite | `Break` | hdmamul, all 14 rows |
|---|---|---|---|
| 2 / 0 (shipped before this) | 6997/1 | `0x10002540` | 226 |
| 4 / 2 | 6997/1 | `0x100024B8` | 226 |
| 6 / 4 | 6997/1 | `0x100024B8` | 226 |
| 8 / 6 | 6997/1 | `0x10002B1C` | 226 |
| **9 / 7** | **6998/0** | **PASS** | 226 |
| 10 / 8 | 6998/0 | PASS | 226 |

hdmamul sits at 226 across the whole range. Reading "hardware 227, dingbat
226" as "the H-blank request belongs at flag+1" attributed a differential
measurement to one of its two terms, which it does not license.

What does refute the common-mode shift is **p50 HDMAPHASE**, whose stamps are
absolute against a shared anchor: the V-blank DMA's write is hardware 1222
against dingbat 1221, and both flag stamps agree to the cycle. A common-mode
+7 would put that write seven cycles late, not one.

### The missing cycle was the V-blank DMA's, and it is now fixed

p50 says dingbat's V-blank DMA write is one cycle early. hdmamul and hdmasweep
say the V-minus-H difference is one low, on every row of both sweeps. That is
the same cycle seen absolutely and differentially. Raising the V-blank DMA's
request to flag+1 (`VBLANK_DMA_REQUEST_DELAY`, mirroring the H-blank's flag+2)
makes both payloads match hardware exactly:

| | hardware | dingbat before | dingbat now |
|---|---|---|---|
| hdmamul, all 14 rows | 227 | 226 | **227** |
| hdmasweep, undeferred rows and the IWRAM control | 227 | 226 | **227** |

The suite is row-identical and the 1219-row runner has zero changed rows. What
is left on hdmasweep is only the deferral: hardware drops to 216-219 at the k
where the request lands inside a gamepak access, and dingbat is still flat.

So one constant cannot serve both pages, and that is the whole point -- the
difference is the deferral hdmasweep measures and dingbat does not model:
**the grant waits for the CPU's bus access in flight, and for nothing else.**
An idle bus defers nothing; the Break loop's gamepak accesses defer several
cycles. p50 measured that directly too: the H-blank DMA's write moves from 999
to 1004 with the CPU loading from ROM, against zero spread on IWRAM.

The arithmetic closes. Instrumenting the grant in that loop: the request lands
with the in-flight access ending 1 or 3 cycles later, the CPU-to-DMA hand-off
costs 2, and the transfer itself 2. So the word reaches the bus at request+5
to request+7 -- the 9-ish effective delay the suite wants, without moving the
constant hardware pins at flag+1.

### A prototype that reproduces the shape

Three edits, and they are small enough to redo from this description:

1. `Bus.access_end`, a stamp of when the CPU's most recent bus access
   finishes. Set it right after every `bus.cycles += bus.access_cycles(...)`
   in the six data-access wrappers and at the end of the two fast fetch paths
   in `fetch_half`/`fetch_word`; internal cycles must never move it, which is
   what separates the load page from the multiply page.
2. `etHDMARequest` re-arms itself at `access_end` when that is in the future
   (bounded, the longest gamepak access is 18 cycles), instead of granting.
3. Stamp the open-bus window from the cycle the transfer **ends** rather than
   the cycle the burst was requested -- that is when the word is actually on
   the bus, and it is worth four cycles here.

Result on the payload rig: **hdmasweep stops being flat.** It was 226 on all
fourteen rows; it now varies (217, 219, 217, 217, 216, ...) while hdmamul
stays flat at 226. That is the measured rule -- load varies, multiply flat --
reproduced for the first time.

It is not shippable yet and was not shipped. The shape is right and the
magnitudes are not: dingbat defers on rows where hardware defers nothing, so
the sawtooth sits near 216-219 where hardware runs up to 227. Calibrating it
means moving the base delay to flag+1 as hdmamul demands and then getting the
deferral to fire only for an access genuinely spanning the request cycle --
and dingbat dispatches events at instruction boundaries, so by the time
`etHDMARequest` runs, the access that spanned the request cycle has usually
already been charged. That is the same sub-instruction resolution problem the
verdicts doc named, now with a number on it (about seven cycles) and two
hardware payloads bracketing the answer.

It also touches DMA timing globally -- 32 Timing rows, the Metroid title fix,
DKC2 -- so it wants a supervised session. The gates are cheap: one suite run
is about a second, and `payloadcmp.py --emulators-only --block=0x02008000:8`
on hdmasweep.s and hdmamul.s is the hardware column.

### One real bug found on the way

`end_frame` rebases every absolute-cycle anchor it knows about -- the
scheduler, the APU, timers, `rom_free_since`, `gate_open_at`, EEPROM's
`busy_until` -- but not `Bus.dma_request_at`, which `read_open_bus_value`
compares against cycles taken from the scheduler. Left behind, it sat a whole
frame in the future, and the open-bus window could not open again until the
next burst re-stamped it. Fixed. Every gate is byte-identical either way,
which is why it survived: the window it silently held shut is one almost
nothing reads.
