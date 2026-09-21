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
| **2** | **`DEAD6019`** | `DEADBEE3` |
| 3 | opcode | same |

At two NOPs hardware returns **half the DMA word beside a freshly fetched
opcode halfword**. The latch is per-halfword: a DMA fills both halves, and
later halfword fetches overwrite them one at a time, each into the half its
own address bit 1 selects -- the same placement rule closed as THUMBBUS this
morning (section 12). dingbat keeps the DMA word whole and loses the
opcode half -- it holds too much, not too little. (`60A86019` was
written here first; that is mGBA's value for this row, a column slip.
dingbat's own ARM two-NOP row is `DEADBEE3` too, which is the
self-consistent reading: its window is wide at both ends.)

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


### The latch, built: `-d:obuslatch`, 2026-09-18 evening

The attempt above, carried out. `-d:obuslatch` replaces the predicate with a
real 32-bit register: `Bus.obus_latch` plus `obus_half_at`, the cycle each
half was last driven by an opcode fetch. Fetches drive it; the DMA does not
write it but is resolved against those stamps at read time, per half. The
default build is untouched -- every line is inside `when defined`.

Three things it settles.

**It is suite-neutral.** mGBA suite 6997/1 and the 1219-row runner
1171/48, both identical to HEAD, and `DMA Prefetch Break` returns the same
`0x100025C8`. The shape can be replaced without paying for it, which is what
section 13 could not assume.

**The latch reaches the shape the predicate could not.** It emits genuine
half-and-half words -- `DEAD4770` on obuswint's three-NOP row -- where the
old answer was all-or-nothing by construction. That was the whole point.

**What is left is one number.** All three post-DMA rows
(`obusprobe +48`, `obuswin +8`, `obuswint +8`) are wrong by exactly **one
opcode fetch**: hardware puts the half-and-half word two NOPs after the
burst, dingbat puts it three. Not a shape, not a window, not a constant to
sweep -- one fetch of lag, the same distance on every row.

Where the lag comes from is known and is not the latch's fault. The value
driven is right: `obus_drive_pipeline` writes what r15 points at, two
instructions ahead of the one executing, exactly as the BIOS latch beside it
already does for the same reason (gbaedge IDENT). What is wrong is the
ORDER. dingbat charges one fetch per instruction, lazily, when that
instruction executes; and it defers an immediate DMA to the next data
access. Both land in the right CYCLE -- which is why stamp arithmetic still
passes 6997 rows -- but the fetches the real pipeline had already issued
before the burst got the bus have not happened yet in ours. The latch is
order-sensitive where the predicate was not, so it is the first thing in the
emulator to show that ordering error as a wrong value rather than hiding it.

That also says what closing `Break` would cost, and it is not this file: the
fetch stream has to run ahead of execution, not beside it. Section 14's
ladder argument is unchanged by any of this -- the exit stays on ladder A.

### A harness trap found while gating the above

`dingbat_test_runner` does not build the harness. It shells out to
`./dingbat_test` as it finds it on disk (`harness_name`, near the argument
parsing) and never checks that it matches the tree. A stale binary there
silently produces a stale `tests/results_mgba_suite.md` -- during this
session one from earlier the same day reported `DMA Prefetch Break` as
`0x10002540`, one full 34-iteration rung off the `0x100025C8` the same
commit's source actually gives, which is exactly the kind of difference this
row is being mined for. Rebuild `dingbat_test` before believing a runner
number, and before regenerating the results markdown.

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


## 15. The H-blank DMA deferral, stamped: a shape, not a constant, 2026-09-18

`hdmastamp.s` is `hdmasweep.s` with the two DMA writes reported raw instead of
subtracted, `k` swept over 32 so a whole loop period is covered instead of
half, and a no-DMA control. Run over the link rig on an AGB SP, five times.

### The deferral is a ramp that snaps, and its size is the access

The loop period is exactly **24 cycles** (`k` and `k+24` agree on every stable
row). 21 of 32 rows are identical across all five runs; the rest tip run to
run and are ignored here, per the rule that a re-hosted page is repeated
before it is believed. Taking each row's TM0 above the column minimum as the
deferral:

| k | 19 | 20 | 21 | 22 | 23 | 0 / 24 | 1 / 25 |
|---|---|---|---|---|---|---|---|
| deferral | 6 | 7 | 8 | 9 | 10 | **11** | **0** |

**One cycle of deferral per cycle of pre-delay, then a snap to zero.** Each
extra NOP puts the request one cycle earlier inside the access in flight, so
the grant waits one cycle longer, until the request falls before the access
starts and waits nothing. Several ramps are interleaved because the loop holds
more than one bus access (the long gamepak load and the short MMIO poll), and
the largest deferral seen is **15**, the length of the longest access.

So the answer to "should we just add a constant" is no. The deferral is 0 at
most phases and up to 15 at others, and any constant is wrong nearly
everywhere -- it would also undo the exact agreement hdmamul and hdmasweep now
have on their undeferred rows. What has to be modelled is the rule:
**grant at the end of the bus access in flight**, which is what the prototype
in section 14 does.

dingbat's own spread on the same column is **6**, against hardware's 15, and
it is incidental jitter from dispatching at instruction boundaries rather than
a deferral. That number is the size of what is missing.

### The trap: absolute stamps on this page are anchored, not absolute

The page's stamps count from its own timer start, so "both DMA writes are late"
and "both timers start early" fit the DMA rows equally well -- the same class
of mistake as reading a difference as though it pinned one of its terms
(section 14). The control row exists to separate them, and it earns its keep:

| | hardware | dingbat | delta |
|---|---|---|---|
| **control: TM0 when the CPU first sees the H-blank flag, no DMA at all** | 1006 | 999 | **7** |
| IWRAM loop, H-blank DMA write | 998 | 994 | 4 |
| IWRAM loop, V-blank DMA write | 1225 | 1221 | 4 |

A measurement with no DMA in it differs by seven cycles. Before that row
existed, the four DMA stamps looked like a clean common-mode offset of about
six cycles in both grants -- and a common-mode correction of +6 was built and
does make all four DMA stamps match hardware exactly while leaving hdmamul at
227, which is precisely what a common-mode error would look like. It was not
shipped, because the control says the anchor moved too. **Normalised against
the control, dingbat's DMA write is about three cycles LATE relative to the
flag, not early** -- the opposite direction from what the suite's row wants.

Two things follow. The ramp above is trustworthy because it is a shape within
one column and immune to any constant anchor offset. Nothing absolute from
this page is trustworthy without the control, including in earlier sections.

### The seven cycles are a new lead, and not a DMA one

**Withdrawn 2026-09-18, see section 17.** The seven cycles were this
page's own polling loop taking one extra iteration at two of seven
phases, not anything in the console. `linegeo.s` measures the same
quantities without an anchor and finds the line, the flag and the
V-blank edge all correct. What is below is left as written because the
reasoning still holds; only its premise was wrong.

Something with no DMA in it -- the interval from the timer start just after
the VCOUNT 158-to-159 edge to the cycle the CPU's poll loop first sees the
H-blank flag -- is seven cycles shorter here than on hardware. That is the
line's own geometry, the timer's enable latency, or the poll's timing, and all
three are worth separating. p50 HDMAPHASE timed its flag stamps as agreeing to
the cycle on a different poll loop, so the two measurements are in tension and
whichever is right, something is unmodelled.

### Does this close the suite's last row? Probably not on its own

With the V-blank DMA correct, `DMA Prefetch Break` passes for an H-blank grant
9 to 12 cycles after the flag, against the 2 shipped -- a correction of 7 to
10 in that loop. But that loop runs at `WAITCNT` 0, where gamepak accesses are
3 to 5 cycles, so a deferral that waits for the access in flight can supply at
most about 5 there. **The deferral is necessary and looks insufficient.** The
rest has to come from somewhere else, and the seven-cycle anchor discrepancy
above is the first place to look. Claiming the deferral will close the row
would be the same over-reach this file has now recorded twice.


## 16. `DMA Prefetch Break`: a knob map, and two beliefs retired, 2026-09-18

Sections 14 and 15 each ended on a claim about what would close this row.
Both were wrong, and the way they were wrong is worth more than the row.

### What the row is actually sensitive to: one number, not two

`HBLANK_FLAG_DELAY` is now an `intdefine` so this is reproducible. Sweeping
it with the grant delay held at 2, against the whole suite:

| flag delay | 46 | 48 | 50 | 51 | 52 | 53-56 | 58 | 61 |
|---|---|---|---|---|---|---|---|---|
| Break reads | 2540 | 24B8 | 24B8 | 24B8 | 2B1C | **passes** | 2A0C | 2984 |
| suite fails | 1 | 1 | 5 | 8 | 7 | 6 | 7 | 7 |

Moving the *flag* by +7 to +10 closes the row, exactly as moving the *grant*
by +7 to +10 does (section 14's sweep). The row cannot tell them apart: it
sees only the sum, because it never reads `DISPSTAT` at all -- it reads open
bus in a 36-cycle loop and exits when a DMA lands in the right phase.

But the flag is not free to move. From 50 upward the six `H-blank bit start
Flip` rows fail, and those rows read the flag directly. **The suite pins the
flag where it is and demands the grant move relative to it.** That is a
coherent position -- it is exactly the deferral of section 15 -- so the
deferral was built.

### The deferral is real on hardware and inert on this row

`Bus.access_end` stamped at the end of every CPU bus access, `etHDMARequest`
re-armed there when the request lands inside one, capped so a stale stamp
cannot strand it. Swept over caps 4, 6, 8, 10, 12, 16, 18, 24 and 64:

**Every cap gives the same suite result, and the same Break value as the
baseline (`0x10002540`).** Not "close"; identical, and flat in the cap. In
that loop the H-blank request never lands inside a bus access, so there is
nothing to wait for and the model has no effect. It also costs `DMA Prefetch
Read`, which the baseline passes.

So section 15's "necessary but insufficient" was the wrong shape of wrong.
The deferral is not a partial answer to this row; it is **not an answer to
this row at all**. It remains well-measured on hardware (section 15's ramp)
and worth modelling for its own sake, but it must be justified by the payload
that measures it, never by this row.

The prototype also exposed a real defect worth recording: `access_end` was
not rebased in `end_frame`, so after a frame boundary it stranded around
150,000 cycles in the future -- the same bug the shipped `dma_request_at`
rebase fixed, reintroduced by the same omission. Any new `CycleCount` field
on `Bus` needs a rebase line, and the absence of one is silent.

### Why the row is not merely an open-bus question

An earlier 13x13 sweep of the post-DMA window's bounds reached only three
values and never the target, while moving the flag reaches it easily. The
difference tells us something: moving the window moves only *what the CPU
reads*, whereas moving the flag also moves *when the DMA steals the bus*, and
the burst's theft shifts the loop's own phase. **The row constrains when the
transfer happens, not just how it is observed.** That is why no open-bus
model can close it, and why it is a real -- if brittle -- timing constraint.

### The sign problem, stated plainly

The row wants the H-blank DMA 7 to 10 cycles later relative to the flag.
Section 15's hardware page, normalised against its no-DMA control, says our
DMA write is already about 3 cycles **late**. Those point opposite ways. One
of them is wrong, and the candidates are: the control's own seven-cycle
discrepancy (unexplained, see section 15), or the row being a phase
coincidence that a correct model is not obliged to reproduce.

**Nothing should be shipped for this row until that sign is resolved**, and
it cannot be resolved by any local sweep -- every constant that moves the row
also moves rows that are already correct.

### The experiment that would resolve it: `linegeo.s`

The control in `hdmastamp.s` measures from a timer start to a flag poll, so
timer-enable latency and poll granularity are folded into its 1006-vs-999.
An anchor-free version is straightforward and has not been built:

* one timer, started once, **never stopped**, read three times;
* stamp A at the VCOUNT 158->159 edge, B when the H-blank flag of that line
  is first seen, C at the VCOUNT 159->160 edge;
* report B-A and C-A, both differences within a single timer run, so the
  enable latency cancels exactly;
* sweep a pre-delay sled as section 15 does, to get below poll granularity.

**C-A must be 1232.** That is the certainty check: a payload that does not
return the scanline length is not measuring what it claims, and no number
from it should be believed. With the method validated by C-A, B-A pins the
flag against the line for the first time, and the seven cycles either survive
or dissolve. The same run can stamp the V-blank flag against VCOUNT 160 and
so pin the other term of every difference this file has relied on.


## 17. The anchor was the artifact: `linegeo.s` and `hdmageo.s`, 2026-09-18

Sections 15 and 16 both ended pointing at the same unexplained seven cycles,
and section 16 said no local sweep could settle the sign. Two anchor-free
payloads settle it. Both start one timer, once, never stop it, and report
only differences between reads of it, so the timer's enable latency is common
to every stamp and cancels exactly.

### `linegeo.s`: the line is right, and the seven cycles were quantisation

Four stamps on one free-running timer: A at the VCOUNT 158->159 edge, B when
the H-blank flag of line 159 is first seen, C at the VCOUNT 159->160 edge, E
when the V-blank flag is first seen. Two runs on an AGB SP, `k` swept 0..31.

| | hardware | dingbat | mGBA |
|---|---|---|---|
| C - A (the scanline) | 1227, 1234 | 1227, 1234 | 1227, 1234 |
| B - A (the H-blank flag) | 1002, 1009 | 1002, 1009 | 1002, 1009 |
| E - C (V-blank flag vs VCOUNT) | 8 | 8 | 8 |

**Identical, and 1232 sits inside the C - A bracket.** The scanline length,
the H-blank flag's position in it, and the V-blank flag against the VCOUNT
edge are all correct here, and correct in mGBA too.

The only column that disagrees is `A` itself -- the one value on the page
that is anchored, and labelled as such in the source. It differs by exactly
7, one iteration of the polling loop, and only at two of the seven poll
phases. **That is the whole of section 15's "1006 versus 999": its control
sat on one of those two phases.** Quantisation, not physics. The seven-cycle
lead is closed, and closed as an artifact of the instrument.

A caveat the payload teaches: C - A is *not* pinned at 1232 even though
1232 = 7 x 176 and both VCOUNT polls are the same seven-cycle loop. The
H-blank flag poll runs between them and restarts the grid at a new phase, so
C - A brackets the line rather than equalling it. It is still a certainty
check -- a run that does not bracket 1232 is not measuring a scanline -- but
a weaker one than it looks.

### `hdmageo.s`: the grant, with no anchor in it

Same construction, plus TM1 started immediately after TM0 and frozen by the
H-blank DMA's own write to TM1CNT_H. The skew between the two timer starts is
two instructions of the same code everywhere, so it is a constant that
cancels on comparison. **D - B is then the DMA's write relative to the flag
being seen, with no timer start, no line boundary and nothing absolute in
it.** Nine runs on an AGB SP, `k` swept 0..13.

| | D - B, pooled over all runs | bounds |
|---|---|---|
| hardware | -11, -10, -9, -8, -6, -5 | **-11 .. -5** |
| dingbat | -11, -8, -6, -5 | **-11 .. -5** |
| mGBA | -12, -9, -6 | -12 .. -6 |

**The bounds are identical.** Our grant is not late and not early: it lands
in the same window hardware's does, and on two runs the whole 112-byte page
came back byte-identical to the console. What it does not do is produce the
two intermediate values -10 and -9, which hardware reaches at phases the
sled cannot address -- our response to phase is coarser, which is the same
thing section 15 saw as a spread of 6 against hardware's 15, restated without
an anchor. mGBA's window is shifted and one cycle wider on the low side.

Two methodological notes, both learned the hard way here. The console's entry
phase relative to the video line is **not** controlled -- the monitor invokes
the payload wherever it likes -- so per-`k` rows move between runs and only
phase-independent statistics (the value set, the bounds) mean anything. And
a 32-trial sweep never returns: the monitor allows ten seconds and every
trial waits out a frame parking on line 158, so `hdmageo.s` runs 14, which is
two whole periods of the seven-cycle grid.

### What this settles about `DMA Prefetch Break`

Everything the row depends on is now measured against hardware and correct:
the scanline length, the H-blank flag's position, the V-blank flag, and the
H-blank DMA grant's window relative to that flag. The row wants the DMA 7 to
10 cycles later than we put it (section 16). **Hardware says it is not.**

So the row is not a bug we have failed to find. It is the phase coincidence
the reachability analysis in section 14 described: a 36-cycle loop against a
once-a-line DMA, whose reported value is the read count at which the two
first coincide, and which moves by whole scanlines under sub-cycle changes
anywhere. `docs/gbatek-upstream.md` section 3 carries the suggestion to its
author. Three of the constants that would close it -- `HBLANK_FLAG_DELAY`,
`HBLANK_DMA_REQUEST_DELAY`, and a grant deferral -- are now each refuted
individually by a hardware payload or by the rest of the suite.

**This row should stay red.** Closing it now would mean moving something that
hardware says is right, and the next section of this file would be about
taking it back out.

### What is left, and it is small

Our phase response is coarser than the console's: 4 values where hardware
shows 6, inside the same bounds. That is worth modelling for its own sake --
it is the grant resolving against a phase finer than instruction boundaries
-- but it is not worth fitting to this row, and `hdmageo.s` is the page that
should judge any attempt at it.


## 18. Controlling the line: `halthb.s`, and two bugs it found, 2026-09-18

Matt's question: if the entry phase is what limits sections 15 to 17, can we
not control it with an interrupt rather than a poll? Yes, and it is a better
instrument in three separate ways.

A V-count match interrupt fixes the line exactly. With `IME` clear no handler
runs -- which matters, because a resident monitor owns the IRQ vector -- but
HALT still exits on `IE & IF`, so the CPU resumes at a cycle the PPU chose
instead of one a polling loop happened to sample. `halthb.s` does that, then
arms the H-blank DMA to freeze a second timer and halts again, so both stamps
are hardware events with no software sampling between them:

* **W** -- TM0 the instant the CPU resumes from HALT on the H-blank IRQ
* **D** -- TM1, frozen by the H-blank DMA's own write to `TM1CNT_H`

It also arranges something no earlier page could: **at the H-blank the CPU is
halted, so there is no bus access in flight for the grant to wait on.**
Section 15 measured the grant deferring up to 15 cycles behind a long access;
this measures the floor, with the bus provably idle.

### The proof that entry is controlled

`W` must not vary with `k`: the sled moves where the CPU halts, and the wake
is tied to the flag, not to the halt. It does not vary, on any platform, and
the whole page is identical across four hardware runs -- where `hdmageo.s`
needed nine runs pooled because its rows moved run to run. **That is the
phase control, and it is worth more than the measurement it carries.**

### Bug 1: `HALTCNT` is BIOS-only, and we honoured it from anywhere

The first attempt wrote `HALTCNT` (`0x04000301`) directly and did not halt on
hardware at all -- `W` simply tracked the sled. mGBA did the same. dingbat
halted for ~1000 cycles. A minimal probe settles it: park on line 100, set a
V-count match for 104, start a free-running timer, halt, read it back.

| | raw `strb` to `0x04000301` | `SWI 2` |
|---|---|---|
| hardware | **11 cycles, still line 100** | 4931, line 104 |
| mGBA | 11 cycles, still line 100 | 4934 |
| dingbat (before) | **4914, line 104** | 4931 |

`0x04000300`-`0x04000301` answer only to BIOS code; the write is ignored from
ROM or RAM, which is why `SWI 2` works -- the BIOS performs the write itself.
Gated on the PC being in the BIOS region in `mmio.nim`; `SWI 2` is unaffected
because `hle_bios` sets `cpu.halted` directly. After the fix all three agree
on both rows. No gate moved.

### Bug 2: the line-boundary IRQ was two cycles early

With the entry controlled, the page reads, on every `k` and every run:

| | W | D | **W − D** |
|---|---|---|---|
| hardware | 1004 | 980 | **24** |
| dingbat (before) | 1006 | 982 | **24** |
| mGBA | 1011 | 980 | 31 |

`W − D` is the anchor-free quantity -- the halt wake against the grant, both
hardware events -- and **it was already exactly right**, which is a real
result in its own right: with the bus idle the grant's floor is correct, and
mGBA's is seven cycles out. But `W` and `D` were *both* two high, and since
they share a timer that starts just after the first wake, the only thing that
can move them together is **when that first wake happened**. The V-count
match wake was two cycles early.

The line-boundary interrupts were sharing the global `IRQ_SYNC_DELAY` of 3
with timers, serial, keypad and DMA. Split into `LINE_IRQ_SYNC_DELAY` and set
to **5**, which is what hardware measures. The suite does not constrain it at
all -- 3, 4, 5 and 6 give an identical 6997/1 -- so this is a row only
hardware could have decided, and the constant would have been indefensible
without it. `linegeo.s` and `hdmageo.s` re-run unchanged afterwards.

### What this changes about method

Three of the four pages in sections 15 to 18 were limited by an entry the
payload did not control, and two of them produced a number that was later
withdrawn. The order to reach for is now: **control the line with a V-count
match halt, take every stamp from one free-running timer, and prefer two
hardware events over any event and any poll.** A poll in the measurement is a
quantiser; a poll in the *entry* is a quantiser you cannot see.


## 19. Four more probes on the halted-entry rig, 2026-09-18

Section 18's shape -- fix the line with a V-count match halt, take every stamp
from one free-running timer, prefer two hardware events to any event and any
poll -- applied to everything else within reach. Three of the four came back
clean, which is worth as much as the one that did not.

### `vdmageo.s`: the V-blank grant, and a constant that deserved re-checking

`VBLANK_DMA_REQUEST_DELAY` was set to 1 earlier the same day on the strength
of a difference (`hdmamul`, blind to a common-mode shift) and an absolute
stamp from a page whose anchor was later withdrawn. Exactly the shape of
thing to distrust. Re-measured with no anchor -- V-count match on 159, halt,
DMA1 freezing TM1, halt again on the V-blank IRQ:

| | W | D | W − D |
|---|---|---|---|
| hardware | 1229 | 1205 | **24** |
| dingbat | 1229 | 1205 | **24** |
| mGBA | 1229 | 1204 | 25 |

Byte-identical, and the same `W − D = 24` the H-blank side gives. The
constant was right; it is now right *for a reason we can point at*.

### `dmasteal.s`: how much the burst actually costs the CPU

The other half of what moves `DMA Prefetch Break` is the theft itself, and
nothing had ever measured it. Enter on line 100, free-run TM0, execute a loop
of **fixed** iteration count spanning that line's H-blank -- no poll, so no
quantiser -- once with and once without a DMA armed.

An IWRAM 16-bit DMA of N transfers costs exactly **3 + 2N** cycles, and every
row of a sweep over transfer count (1..32), source and destination region
(IWRAM, EWRAM, VRAM, palette, OAM) and width (16 and 32 bit) is identical on
hardware, dingbat and mGBA. Twelve region/width rows, twelve agreements. The
steal is not where the last row's error lives.

### `timergeo.s`: the prescaler is global, and we are one tick out at one phase

The prescaler divider free-runs and is not restarted when a timer is enabled
-- which dingbat already models -- but *where that grid sits relative to the
video grid* had never been checked, because before section 18 the payload's
own phase was whatever the monitor handed us.

Counting prescaler-64 ticks over a fixed span, entering at the top of each of
eight consecutive lines:

| entry line | 100 | 101 | 102 | 103 | 104 | 105 | 106 | 107 |
|---|---|---|---|---|---|---|---|---|
| hardware | 19 | 19 | 19 | **18** | 19 | 19 | 19 | **18** |
| dingbat | 19 | 19 | 19 | **19** | 19 | 19 | 19 | **19** |
| mGBA | **18** | 19 | 19 | 19 | **18** | 19 | 19 | 19 |

Period 4, because the line step is 1232 mod 64 = 16 and four lines are the
four distinct phases. **At one phase in four our count is one tick high**, and
mGBA is one tick low at a different phase; neither of us is right, and we are
wrong in opposite places.

No phase constant fixes it. A `TIMER_PHASE` added to both ends of
`ticks_between` was swept over 0, 16, 32, 48 and 1023 -- the last being −1 for
every period, since all of them divide 1024, which tests the other half-open
convention -- and the disagreeing row does not move. So this is not the grid
being offset; it is the boundary case itself, one phase where hardware
resolves a tick the other way. The mGBA suite does not constrain it at all
(every value gives 6997/1), so nothing but hardware can decide it. **Not
fixed, and deliberately not guessed at.**

### The limit of the current control, and what would lift it

The ÷256 and ÷1024 rows of that page looked like clean disagreements and then
**changed between runs on hardware**, so they are discarded. They had to: a
frame is 280896 cycles, and 280896 mod 64 = 0 but mod 256 = 64 and mod 1024 =
320. The ÷64 phase therefore repeats every frame and is reproducible, while
the ÷256 and ÷1024 phases walk with the frame index and need frame parity
controlled as well as the line.

**We control the line; we do not control the frame.** That is the next thing
to fix about the rig, and until it is, no prescaler-256 or -1024 claim from
this page means anything. It is the same lesson as section 17 one level up:
the thing that moved was the part of the entry we had not pinned.

### None of this reaches the last row

`DMA Prefetch Break` counts a loop **in ROM**, and the rig is a multiboot link
with no cartridge in the slot, so gamepak and prefetch timing cannot be
measured here at all. Everything reachable that the row depends on -- line
geometry, flag position, grant window, grant floor, DMA steal -- is now
measured and correct. What is left is on the other side of a bus this rig
cannot see, which is what `prefetchbench.gba` on the flashcart is for.


## 20. `DMA Prefetch Break`: what the test actually is, 2026-09-18

Sections 14 to 19 worked on this row from the outside, measuring everything
it depends on that the link rig can reach and finding all of it correct.
This round read the test's own source instead, and re-swept the knobs against
the current HEAD. Both changed the picture.

### The baseline had moved and nobody noticed

We report **`0x100025C8`, not `0x10002540`**. Commit `6964209c6`, which fixed
the line-boundary IRQ, shifted this row by 34 iterations as a side effect.
The deficit against the expected `0x10002A94` is **307 iterations, not 341**,
and *section 16's table is stale*: the flag-delay pass window is now 55..58
where it records 53..56, and the grant window 11..14 where it records 9..12.
The `H-blank bit start Flip` rows want `HBLANK_FLAG_DELAY` in 43..48.

A lesson worth keeping: a row we have decided to leave red still needs its
number re-read after every commit that touches timing, or the next session
reasons from a value that no longer exists. Three sessions' arithmetic in
this file was done against 2384.

### What the test does

It arms DMA3 for **one** 32-bit word, source and destination both **fixed**
(so the datum is always the same word), H-blank timing, repeating. Then it
spins a seven-instruction Thumb loop **in ROM** reading unmapped
`0x10000000 + 4i`. Open bus there is the Thumb halfword at the load's own
address + 4 -- the loop's own `ands`, doubled -- and the loop's masked
compare passes on exactly that, so it spins on its own opcode until an
H-blank DMA's word displaces it. The reported number is the pointer when
that happened.

Two things follow that we had wrong. **The test never writes `WAITCNT`**: it
runs at the reset default, four-cycle ROM accesses with the gamepak prefetch
buffer *off*. So the prefetch buffer is not involved at all, and the name of
the row refers to the CPU pipeline's prefetch showing up on open bus. And
`DMA Prefetch Read`, which we pass, is not a separate test but the second
output of the same function -- passing it means our open-bus-during-DMA
*value* is right and only the *phase* is wrong.

### The deficit is quantised, and the target is on the other ladder

A line is 1232 cycles and the loop is 36, so 34.2 passes fit in a line.
**Every constant in the emulator moves the exit in whole steps of 34
iterations** -- one line's worth of passes -- and the reachable values fall
on two ladders one pass apart: 2350 + 34k and 2351 + 34k. The expected 2725
is on the second ladder. A 103-build sweep of all five intdefines:

| constant | shipped | gain on this row | green range |
|---|---|---|---|
| `HBLANK_FLAG_DELAY` | 46 | −34 iterations per ~2.6 cycles, wraps at 53→54 | 43..48 |
| `HBLANK_IRQ_SYNC_DELAY` | 6 | **exactly zero**, 17 builds, never moved a byte | 4..8 |
| `LINE_IRQ_SYNC_DELAY` | 5 | +34 per ~2.3 cycles, monotone, saturates at `0x2A90` | **0..32, all of it** |
| `HBLANK_DMA_REQUEST_DELAY` | 2 | identical to the flag delay at (44+k): they are one axis | 0..8, 10..16 |
| `VBLANK_DMA_REQUEST_DELAY` | 1 | **exactly zero**, 16 builds | 0..16, all of it |

`LINE_IRQ_SYNC_DELAY` is the sharpest miss and the best evidence in the
table. The suite does not constrain it *at all* -- 6997/1 for every value
from 0 to 32 -- it has the highest usable gain, it walks straight up to
**`0x2A90`, one single iteration short of the target**, and then saturates.
It can never land on `0x2A94` because it is on the wrong ladder. The only
transition in the entire sweep that changes residue class is crossing
flag + grant >= 56, which is the grant delay that section 14's hardware
measurement refutes.

So the row is closeable -- `HBLANK_DMA_REQUEST_DELAY` in 11..14 gives a full
green 6998/0 with zero collateral -- by exactly the one knob hardware says is
wrong, and by nothing else. That is the same conclusion as section 15, but it
is now a statement about the model's reachable set rather than about a search
that happened to fail.

### The expected value has a provenance problem

`0x10002A94` is a hardcoded constant in the suite's expectation table. It was
introduced in 2026-05-31, in the **same commit that rewrote the code it
measures** ("make the test resistant to gcc updates"), with no hardware claim
in the message. Its predecessor `0x10002A64` stood for three years; the one
time it was checked against silicon, a GBA SP reported **`0x10002AF8`** and a
second emulator agreed with the console, while the table matched the suite's
own emulator and not the hardware. A companion commit the same day replaced
an earlier contributor's explicitly hardware-derived numbers for the sibling
`H-blank bit start` rows with values described as "modern gcc values", and an
upstream issue is still open reporting those as wrong on hardware.

No hardware reading of the current build has been published anywhere. The
constant is also **per-build**: it depends on the compiler's exact code
addresses and alignment, which is why it moved when the loop went from six
instructions to seven.

None of that makes the constant wrong. It does mean we have been treating a
number of unknown provenance as an oracle, which is the thing this project
does not do anywhere else.

### `tests/roms/prefetchdma.gba`

A cartridge ROM, because everything left is on the gamepak side of a bus the
link rig cannot see. Four parts: the loop's period across wait settings, what
an H-blank DMA costs a ROM-fetched loop (the link rig's answer, with the loop
in EWRAM, is exactly 3 + 2N), the post-DMA open-bus window scanned a cycle at
a time from ROM code, and a replica of the suite's own loop and DMA reporting
its break address at sixteen entry phases. Results stream down the link cable
and are copied to SRAM, so a run gives exact numbers rather than a photograph.

It has already separated the two emulators twice before reaching hardware.

**A loop with an unmapped load gets no prefetch benefit in the other emulator
and full benefit here.** A four-instruction Thumb loop `ldr r0,[r2]` /
`add r2,#4` / `sub r1,#1` / `bne`, fetched from ROM at 3/1 with prefetch on,
costs 14.12 cycles an iteration here and 18.12 there -- and 18.13 in both
with prefetch off, and 14.12 in both when the load target is mapped IWRAM.
Same split at 4/2 waits. So one of us keeps the prefetcher running across a
load of unmapped space and the other does not. Part A settles it.

**The replica's open bus diverges too.** dingbat spins it and reports a break
address; the other emulator breaks on the *first* pass, having read back an
opcode from twenty instructions earlier. The loop layout was checked by
disassembly -- `ands` (`0x4003`) sits exactly four bytes after the `ldmia`,
in the priming read and in the loop alike -- so the suite's own rule says
both should read `0x40034003`. Part D settles that too.

**And the break address scatters.** Across sixteen entry phases spanning
about forty-five cycles, dingbat's replica gives sixteen *distinct* break
addresses, from `0x1000248C` to `0x10002AFC` -- a spread that brackets the
expected `0x10002A94` and is wider than our whole deficit. The row is a
knife-edge coincidence whose answer depends on the cycle the loop is entered
on. That does not excuse a wrong number, but it does say what kind of number
it is, and it is a strong reason to want silicon's reading of the actual
suite rather than a closer approach to a constant of unknown origin.

### What actually selects the ladder, traced cycle by cycle

Instrumenting every unmapped read, every DMA grant and every bus access in
the loop answers it, and the answer is not a number.

The loop is 36.006 cycles measured over 2417 iterations (2414 of 2417 gaps
are exactly 36; the other three are the DMA's theft). It starts at vcount
160, dot 227 -- **inside V-blank** -- and 2321 of the first 2418 reads happen
there, where no H-blank DMA exists and no exit is possible. Everything is
decided in the first few visible lines of the next frame: we exit on **line
2**, on the third H-blank DMA the loop ever sees, and the expected 2725 lands
on **line 11**, nine scanlines later.

The grant is at dot 1008 on every line with zero spread and the word reaches
the bus at dot 1012. Taking F as the dot at which the load's own opcode fetch
starts, the walk is −2 on eight lines and −4 on five, summing to exactly −36
over **13 lines** -- one full wrap of the pass. So F takes only **13 values,
all odd**. Our window admits F in [1005, 1007]; the grid contains exactly one
such point, 1007, and that is the entire selection rule. Which line it first
occurs on depends only on where in V-blank the loop started -- shift that by
two cycles and the first hit moves a line, which is 34 iterations. That is
the 34-quantum, and it is why `LINE_IRQ_SYNC_DELAY`, which moves the V-blank
entry, walks the value in steps of 0x88.

**Ladder A is "the grant lands inside the load instruction". Ladder B is "the
word survives to the next pass's load".** Our exit is always the last read
whose own opcode fetch began before the grant. The target is the first read
whose fetch begins after it -- literally one pass later.

And our model **cannot reach ladder B by construction**: `read_open_bus_value`
keys the window on *this reading instruction's own* `fetch_start`, so a read
whose fetch began after `dma_request_at` fails `dma_request_at > fetch_start`
for every choice of bounds. That is why section 14's 13x13 bounds sweep
reached only three values, all on ladder A, and why the only knob that crosses
ladders is one that moves the grant -- moving the grant changes which pass the
grant is *inside*, which is the one thing bounds cannot change.

### The inconsistency that would close it, and it is ours

Three mechanisms could put the capture on the next pass. Two are already
refuted: the latch surviving 12 cycles and two opcode fetches longer is
refuted by `obuswin.s` (section 13), and moving the grant 13--16 cycles later
is refuted by `hdmageo.s` (section 17). The third is not refuted, and it is a
disagreement inside dingbat rather than with hardware.

**Our timing model and our value model disagree about when a fetch happened.**
`read_open_bus_value` returns the opcode at `r15` -- `0x4003` from
`0x08005FB8` -- and that value is right, because on hardware the pipeline runs
ahead and that halfword has already been fetched when the load's data cycle
occurs. The test's own steady-state result proves it. But our *access trace*
shows we fetch `0x08005FB8` **after** the load's data cycle: we fetch lazily,
one fetch per instruction, charged when that instruction executes. So the bus
access immediately before the data cycle is the load's own fetch, where on the
console it is a fetch two instructions further on.

That is about two fetches, eight to ten cycles -- the same order as the twelve
to thirteen the target needs -- and it moves the capture from the pass
containing the grant to the pass after it **without moving the grant and
without extending the latch**. Stated as a mechanism: the open-bus window
should sit where the real pipeline's last pre-data-cycle fetch sits, which is
two instruction fetches later in the pass than where we put it.

Not built. It is not a constant: it means reordering when fetch cycles are
charged relative to data cycles, which touches the 32 DMA/ROM Timing rows,
the prefetch columns, the BIOS timing rows, and the `rom_hot` bookkeeping that
hangs off fetch order, and would need `HBLANK_DMA_REQUEST_DELAY` and the DMA
hand-off constants re-derived against the same payloads. It is recorded here
because it is the first candidate that is not refuted by one of our own
hardware pages, and because the evidence for it needs no hardware at all.

### Two things found on the way, both worth knowing

`clear_pipeline`'s flat `2 x wait_s` refill lump is the **largest single term
in this loop** -- 6 of its 36 cycles -- and it is charged on top of the two
refill fetches the following instructions then charge individually. That reads
like a double charge, and removing it was tested: the suite goes to 6294/704
and the row overshoots to `0x1000308C`. So it is load-bearing and calibrated,
not a bug. But the row's dominant time constant is a lump whose justification
is a comment, and the loop period is a lever that reaches *past* the target.

`seq = address == rom_next_addr and (prefetch_on or contiguous)` -- the rule
that a burst breaks whenever the CPU spent cycles off the ROM bus -- costs
this loop 4 cycles a pass. Removing it leaves the suite at 6997/1 with the row
unchanged, so it is not a lever here; but it is stated as modelling rather
than measurement, and it is **duplicated by hand in `rom_access_cycles` and
`rom_fetch_cycles`**, so editing one of them is silently a no-op.

### What hardware is being asked

In priority order, and all of it needs a cart in the slot:

1. **Run `mgba-suite.gba` itself and read the Misc page.** Nobody has ever
   done this for the build we test against. If silicon does not say
   `0x10002A94`, every session spent chasing that constant was chasing a
   model, and the row becomes a documentation task rather than a bug.
2. `prefetchdma.gba` part A: the loop's period, and which of the two
   prefetch behaviours across an unmapped load is real.
3. Part D: the replica's break address, three-way.
4. Parts B and C: the DMA's cost to a ROM-fetched loop, and the open-bus
   window's closing edge against a gamepak fetch.


## 21. `DMA Prefetch Break`: the target is out of range, and the loop period is why, 2026-09-18 evening

Sections 14 and 20 argued the row sits on a ladder we cannot climb. With the
latch built (section 13) and `-d:obuslatchdbg` printing a stamp per unmapped
read, the loop can now be read off directly instead of reasoned about, and
the conclusion is stronger and simpler than a ladder.

### What the loop actually does, measured

2418 word reads, and every number below comes from the log, not a model:

| quantity | value |
|---|---|
| loop period | **36 cycles** (2413 of 2418 iterations; 4 stragglers at 38/40/42) |
| fetch -> read, the whole window | **3 cycles** |
| DMA grants during the entire loop | **four**: 72, 85080, 86312, 87544 |
| grant spacing | 1232, i.e. one scanline |

The loop starts in V-blank and spends **2321 of its 2418 reads there, with no
H-blank DMA in existence**. Only three grants are live, one per visible line,
and we break on the third: its grant at 87544 falls between that read's fetch
at 87543 and its data cycle at 87546. Everything about this row is decided in
three scanlines at the very end.

Also settled by the same log: the loop runs from ROM, a 16-bit bus, so every
fetch mirrors into **both** halves of the latch and `h0 == h1` on every
iteration. The per-halfword machinery section 13 wanted is real and correct
and is **inert for this test**. It cannot be what closes this row.

### Why nothing reaches the target

> **Corrected in section 22.** The argument below forgets the cycles the DMA
> itself steals from the loop, which turn the +8 walk into +4 or +2 a line.
> The target is reachable; what decides the row is the entry phase.

The grant moves `1232 mod 36 = 8` cycles per line against the loop's phase,
and `gcd(8, 36) = 4`. So the grant only ever visits **9 of the 36 offsets**,
all congruent mod 4. Either one of those nine lands inside the 3-cycle window
within nine lines, or none ever will. That caps how long the loop can
survive, and the cap is the whole story:

**Over every entry phase in a full 1232-cycle period, the exit index can only
land in 2316..2623.** The suite wants **2725**. It is not on another rung of
a ladder -- it is outside the achievable range entirely, and no window width
from 1 to 12 changes that (the range only shrinks).

That retires the remaining knobs at once. It is not the window's width, not
its lower bound, not the entry phase, not the grant dot, and not the latch's
shape. `-d:OBUS_LEAD` confirms it from the other side: the reachable set is
`{2418, 25688, 0}` -- lead 1 overshoots by 684 lines, lead >= 3 never breaks
at all (reproducing section 13's `0x00000000`).

### What is left, and it is measurable tonight

The cap comes from `gcd(1232 mod P, P)` for loop period `P`. Sweeping `P`
with everything else held at the measured values:

| P | 1232 mod P | gcd | offsets visited | reachable exits | 2725? |
|---|---|---|---|---|---|
| 34 | 8 | 2 | 17 | 2452..3067 | **yes** |
| 35 | 7 | 7 | 5 | 2382..2557 | no |
| **36 (ours)** | 8 | 4 | 9 | **2316..2623** | **no** |
| 37 | 11 | 1 | 37 | 2253..2818 | **yes** |
| 38 | 16 | 2 | 19 | 2194..2809 | **yes** |
| 31 | 23 | 1 | 31 | 2689..3602 | **yes** |

So the expected constant is only explicable if the real loop takes **31, 34,
37 or 38 cycles** -- not 36. A period one or two cycles longer than ours
would do it, and the two nearest candidates, 37 and 38, are exactly the size
of error a single mis-charged pipeline refill would produce. `clear_pipeline`
charges a flat `2 * wait_s` for the branch at the bottom of this loop, which
is 6 of the 36 cycles and the largest single term in it (section 20).

This is a falsifiable prediction, and `tests/roms/prefetchdma.gba` Part A
already measures precisely it: the period of a seven-instruction Thumb loop
in ROM at 4/2 waits with the prefetcher off. **If hardware reports 36, the
expected constant cannot be a property of this loop at all and the row should
be treated as build-specific magic** (section 20 on its provenance). If it
reports 37 or 38, the row is a real timing bug in our ROM fetch accounting
and the open-bus model was never implicated.

Either way the next move is one number off a cartridge, not more modelling.


## 22. `DMA Prefetch Break`: gamepak timing without a cartridge, and what silicon says, 2026-09-20

Sections 12 and 19 both closed with "this needs the flashcart". It does not.
The link rig can execute code from the cartridge region of a console with an
**empty slot**, and that turned every remaining unknown about this row into a
measurement. The flashcart was unavailable; nothing below used it.

### The trick

`slotfloat.s`: an empty slot answers a **nonsequential** halfword read with
`addr >> 1` and a **sequential** one with `0xFFFF`. Byte-identical over
sixteen runs, even and odd halfwords, at WAITCNT 0 (4/2).

`0xFFFF` is the Thumb `BL` suffix: `pc = lr + 0xFFE`. So branch to `A` and
the CPU executes the opcode `(A >> 1) & 0xFFFF`, fetched by a real
nonsequential gamepak access with the real wait states (they belong to the
memory controller, not the cartridge), and the *next* fetch -- sequential,
floating -- branches to wherever `lr` was aimed. Section 12 looked at the same
float and called it the end of the idea; it is the way home.

The suffix also leaves `lr` = its own address + 2, so with `lr` aimed back
into the slot the excursion **chains**: the hop after next lands `0x1002`
further on, where the opcode is `0x801` greater. Two interleaved families
(`mov r0` / `cmp` / `add` / `sub` / `and`, and one ending in `bx r6`) give
about 130 cycles of continuous gamepak-region fetching in the shape N S S S.

Rules this cost a power cycle each to learn:

- **`bx pc` must sit on a word boundary.** Both emulators forgive a
  misaligned one; the console never came back.
- **Only WAITCNT 0 is safe.** At 3-wait and 2-wait first accesses the float is
  sampled before it settles and the exit suffix is sometimes not there; at 8
  waits the *address* has decayed by the time it is sampled. A timer watchdog
  in the payload recovers a hang, but not garbage that rewrites the vector.
- The emulators need an image that reads the same way: `tools/hwlink/
  slotexec.py` pads payloadcmp's wrapper to 128 KiB of `0xFFFF` and plants
  `A >> 1` at each address a payload's table names. Two table addresses one
  halfword apart collide there and not on the console (it cost a false
  3-cycle "disagreement"); keep them apart.

### `slotexec.s`: the loop period is 36, on silicon

Twenty single opcodes, each timed from IWRAM through the slot and back.
**At 4/2 with the prefetcher off -- the setting the row runs under -- hardware,
dingbat and mGBA agree on all twenty.** A taken branch in ROM costs 11. A load
costs its fetch + 1 + 1 and the fetch after it is nonsequential; the same
after a store; an unmapped data access costs 1; multiplies cost their
internal cycles and the fetch after them is nonsequential too. Those are the
terms of the Break loop, `3+3+(3+1+1)+(5+1)+5+3+11 = 36`. Section 21 asked
hardware for one number and this is it: **36**.

At 4/2 with the prefetcher **on**: hardware equals dingbat on all twenty and
mGBA misses nine, including the "unmapped load" split section 20 recorded
between the two emulators. That is the first silicon check the prefetch
model has had.

### `slotdma.s`: what an H-blank DMA does to code fetched from the gamepak

Halted entry on a V-count match (section 18), a delay, a k-NOP sled, the
chain, and DMA0 armed for H-blank with `TM1CNT_H` as its destination so the
DMA's own write stamps itself. Three runs, every cell identical. With k
sliding the DMA across N S S S (period 14):

| DMA request lands in | DMA's write | cost to the CPU |
|---|---|---|
| the 5-cycle nonsequential fetch | floor +4 down to +0 | DMA + 2 |
| either sequential fetch that another follows | floor +2 .. +0 | DMA + 2 |
| the last sequential fetch before a branch | floor +2 .. +0 | DMA + 0 |
| IWRAM NOPs (control) | floor, flat | DMA |

So, measured in the gamepak region for the first time:

1. **The grant waits for the access in flight and nothing else** -- a ramp the
   length of that access, 0..4 then 0..2, 0..2, 0..2. dingbat is flat; mGBA
   ramps 0..10 across whole instructions. (Section 15 found the same rule
   against an 8-wait data load; this is the opcode-fetch case.)
2. **After a DMA the next gamepak access is nonsequential**, and the slot
   *shows* it: the fetch that should have floated to `0xFFFF` comes back as
   `addr >> 1`. That is +2 exactly when the broken fetch would have been
   sequential, and +0 when the next access was a branch target anyway. (The
   chain's raw "+5" rows are this: the forced-N fetch replaced the exit suffix
   with one more harmless opcode.) dingbat already cools its burst trackers
   after a DMA; it just applies the penalty to the next *instruction* rather
   than the next *access*.

Then the row's own instruction, `ldmia r2!, {r3}` from unmapped memory, as a
single hop, reporting what it loaded:

| request lands in | loaded | note |
|---|---|---|
| the hop's first two fetches | `CA0ACA0A` / `CA0BCA0B` | not the DMA word: a forced-N fetch came between |
| **the `ldmia`'s own fetch, all 3 cycles** | **`00000000`, the DMA's word** | the capture window |
| its data cycle | `FFFFFFFF` | and **T drops by 1**: the DMA runs over the internal cycle that follows |
| its internal cycle, or later | `FFFFFFFF` | |

3. **The capture window is exactly the three cycles of the load's own fetch.**
   With the stamp conventions aligned, that *is* `read_open_bus_value`'s
   `(fetch_start, read_start]`. The window was never the bug.
4. A DMA requested during a data cycle **overlaps the internal cycle after
   it**. Neither emulator models that. Not fixed here.
5. One real dingbat bug seen on the way: at the phase where the request falls
   inside the unmapped read itself we return **`000000FF`** -- the read is
   assembled a byte at a time and the catch-up inside it lets the DMA land
   between bytes. Hardware reads a whole word. Not fixed here.

### Section 21 was wrong, and why

Section 21 argued the expected exit is out of range because the grant walks
`1232 mod 36 = 8` cycles a line. It forgot the DMA's own stolen cycles: each
grant delays the loop by 4 or 6, so the walk is **+4 or +2 a line**, not +8,
and a walk of thirteen lines is reachable. With the measured rules:

| request phase in the loop | lines until captured |
|---|---|
| `cmp` / `beq` fetches before the `ldmia` | 1 .. 3 |
| the `ldmia`'s fetch | 0 |
| its data and internal cycles, the `str` fetch | 12 .. 13 |
| the `str`'s write, the `ands` fetch | 10 .. 12 |
| `cmp`, `beq`, the branch target, the refill | 9 down to 4 |

The expected `0x10002A94` is line 11, reachable from three phases: the
`str`'s write and two cycles of the `ands` fetch. dingbat enters at the `beq`'s fetch and walks 2, 4, 6 -- line 2,
`0x100025C8` -- and under the hardware rules above that walk is *identical*.
**So the row is one number: the loop's entry phase, about fifteen cycles
from where we have it.**

### `vbwait.s`: the entry phase, against Nintendo's BIOS

The loop is entered when `VBlankIntrWait` returns. The console runs the real
BIOS, so this is the one leg never compared with anything. `vbwait.s` calls
IntrWait from a fixed cycle (halted entry), starts TM0 on the return, and
reads it at a second V-count halt wake two lines later; a second clock stamps
handler entry (H) and the return (R).

| | hardware | dingbat, real BIOS | dingbat, HLE | mGBA |
|---|---|---|---|---|
| T, waiting on **V-blank** | **2379** | 2379 (was 2378) | 2378 (was 2377) | 2379 |
| T, waiting on **V-count 160** | **2378** | 2378 | 2377 | 2379 |
| H, handler entered (V-blank / V-count) | 8381 / 8382 | 8379 / 8380 | 8380 / 8381 | 8378 / 8378 |
| R - H, the way out | 82 | 84 | 84 | 85 |

("was": before the fix below. Larger T = an earlier return.)

- **The V-blank interrupt reaches the CPU one cycle sooner than a V-count
  match raised at the same line boundary.** We shared one delay. Fixed:
  `VBLANK_IRQ_SYNC_DELAY = LINE_IRQ_SYNC_DELAY - 1`. Both gates row-identical
  (the suite cannot see it); with it the real-BIOS core reads hardware's T
  on both rows.
- *(Resolved in section 24: it was the HLE's Halt return, not IntrWait.)*
  The HLE returns one cycle late. It is **not** `INTRWAIT_TUNE`: at 43 the
  return matches and 16 Timer count-up rows fail, while the real BIOS passes
  them all -- the HLE's extra cycle is on the way *in*. Open.
- On hardware the handler is entered **2 cycles later and left 2 cycles
  sooner** than in our real-BIOS core, same instructions. The halt-wake IRQ
  entry and its return are split in the wrong place (the split in `cpu.irq`
  is calibrated on a running CPU). Invisible to everything but code that
  reads a clock inside a wake handler. Open.

### Where that leaves the row

> **Superseded by section 23**, the same day. The entry phase this section
> ends on was found: it is our fork of the suite, not the emulator.

With the measured V-blank delay and the real BIOS, dingbat reports
**`0x10002540`**; with the HLE, `0x100025C8` (its one late cycle is worth
exactly one line). A second reference emulator has reported `0x10002540` all
along. No WAITCNT a flashcart loader might leave behind produces the expected
value either (`-d:breakwait -d:BREAKWAIT=N` forces one for this test alone:
4/2 prefetch on gives `0x10002D94`, the fast settings `0x100044F8`).

Every mechanism this row depends on has now been measured on an AGB SP --
loop period, grant, deferral, forced-N, capture window, line geometry, the
IntrWait return -- and dingbat agrees with all of it that bears on the
answer. **The prediction for silicon is `0x10002540`, not `0x10002A94`.** If
the flashcart photograph says `0x10002A94` there are about fifteen cycles
somewhere none of these probes looked, and the place to look is the suite's
own interrupt dispatcher; if it says `0x10002540` the row is a wrong
expectation and the only thing left to do is make the HLE's IntrWait as good
as the real BIOS's.

New debug flags: `-d:hdmalog` (every H-blank grant with its line and pc),
`-d:breakwait`. New payloads: `slotfloat.s`, `slotexec.s`, `slotdma.s`,
`vbwait.s`; runners `tools/hwlink/slotexec.py`, `slotdma.py`.


## 23. `DMA Prefetch Break`: it was the fork, 2026-09-20 evening

Matt's question was whether we build the suite with the compiler upstream
used, since the Misc rows time compiler output (section 20, and the pin in
the fork's `docker-build.sh`). Answering it found the row.

### The compiler is not the difference

Upstream pins nothing: its `docker-build.sh` pulls `devkitpro/devkitarm`
with no tag, so "their version" is whatever `latest` was on the day. Our
`20260221` pin is an inference from the date of the commits that re-measured
the constants. It can be checked, though, because upstream's buildbot
publishes its own binary (`s3.amazonaws.com/mgba/suite-latest.zip`, built
2026-07-08). Against the ROM we test:

- `dmaPrefetch` is **byte-identical**, all 132 bytes, but for one literal (a
  data address). Same instructions, same registers, same literal-pool
  offsets, same word alignment of the loop (`0x08006520` there, `0x08005FB4`
  here).
- libgba's interrupt dispatcher is byte-identical but for the address of its
  handler table.

So the pinned toolchain reproduces upstream's code for this test exactly.

### What the fork changed

Only `main()`: upstream runs **one suite at a time from a menu**; the fork
runs **all thirteen back to back** so a harness can score them. That is not
neutral. libgba's dispatcher walks its handler table linearly looking for the
raised flag, and nothing registers a V-blank *handler* -- `main()` only
enables the interrupt -- so every V-blank walks the entire table to its
terminator. Each entry it steps over is `ldr / cmp / beq / ands / bne / add /
b` = **11 cycles** from IWRAM.

On a console, Misc opened from a fresh boot runs with the table empty. In our
auto-run, the suite before Misc is SIO timing, which does `irqInit();
irqSet(IRQ_TIMER1, ...)` and leaves that entry behind. `VBlankIntrWait`
therefore returns 11 cycles later than on the console, the loop starts 11
cycles later, and the H-blank grant falls 11 cycles earlier in it: phase 2-3
instead of 15-16. Section 22's table says what that costs -- two lines
instead of eleven, **exactly the 307 iterations this row has been short all
along.**

Shown twice:

- `-d:breakirq` empties the table as the test arms its DMA: **Misc 12/12,
  suite 6998/6998.** The grant walk is 15, 19, 21, 23, 25, 27, 31, 35, 1, 3,
  5, 7 -- eleven lines, then the capture -- and the exit is `0x10002A94`.
- The fork rebuilt (pinned image, scratch copy) with `irqInit();
  irqEnable(IRQ_VBLANK);` before each suite, which is the state the menu
  leaves: **stock dingbat scores it 6998/6998.** No other row moves.

The expected constant is right, the emulator was right, and sections 14 to
22 were measuring a console-vs-harness difference in test *setup*. None of
that work is wasted -- the period, the grant deferral, the forced
nonsequential access, the capture window and the V-blank interrupt's extra
cycle are all real and all measured -- but none of it was ever going to turn
this row green.

### Two things still open

> **Both chased in section 24.** The HLE's pass here was two errors
> cancelling; with them fixed both cores agree, one line *past* the constant.

**The real BIOS lands one line short.** On the rebuilt ROM the HLE reports
`0x10002A94` and the real-BIOS core `0x10002A0C`: entry phase 16 against 15,
the one cycle by which `vbwait.s` shows the HLE returning late. `vbwait.s`
says the real-BIOS core's return is the one that matches silicon (with a
minimal handler), so either the console is a cycle off that on libgba's
path, or our per-line steal differs from hardware's in a way that cancels it
for the HLE. It does differ: section 22 measured the post-DMA nonsequential
penalty per *access*, we charge it per *instruction*, and on this walk that
changes the steal at the branch-target phases (we take 4 where the console
takes 6). Hand-walking the measured rule from either entry phase gives line
12, not 11. So the HLE's pass is genuine against the suite's constant but is
not yet proof of cycle-exactness, and the honest next step is to model the
penalty per access and see whether the real-BIOS core then lands on 11.

**The suite's own test is order-dependent**, on hardware too: run Timer IRQ
or SIO timing from the menu and then Misc, and the console should report a
different Break value than from a fresh boot. `hblankBit` next to it calls
`irqInit()` itself; `dmaPrefetch` does not. Worth sending upstream with the
rest of docs/gbatek-upstream.md section 3, when Matt chooses to.

### For the flashcart

Three ROMs now sit in `~/Documents/emu/gba/flashcart-tests/`:
`mgba-suite-upstream-official.gba` (open Misc from a fresh boot: expect
`0x10002A94`; then run SIO timing and Misc again: expect it to change),
`mgba-suite-irqreset.gba` (the rebuilt fork: expect `0x10002A94`), and the
current fork build `mgba-suite.gba` (expect `0x10002540`, section 22). The
fork patch is beside them.


## 24. The real BIOS, chased: three bugs, and the row is mGBA's number, 2026-09-20 night

Section 23 left the real-BIOS core one scanline short of the HLE on the
rebuilt ROM. One line of that loop is one cycle of entry phase, so this was a
hunt for single cycles, done the way the others were: a probe on the AGB SP
for each suspect, and no change without one.

### What was wrong

**1. A branch into the gamepak was refilled in the wrong order.**
`clear_pipeline` charged a flat `2S` and left the nonsequential access to the
target's own fetch. The sum was right and the order was not, and section 22
had already measured why order matters: the first gamepak access after a DMA
is nonsequential. With N charged last, a DMA landing in the refill cost
nothing where the console pays two cycles, and one landing in the branch's
own fetch cost two where the console pays none. Now N then S at the target,
the burst continuing into the target's own fetch, events due before the
refill run first (`ROM_REFILL_ORDERED`; prefetch-off only -- with the
prefetcher on the totals would move and section 22's twenty rows pin those).
An exception return into Thumb, and the HLE's post-return charges, keep the
burst alive the same way.

Checked where it was found: **`slotdma.s`'s cost column now matches the
console at every phase** of the chain and of all three single hops, where it
was wrong at five phases in fourteen. The `ldmia` capture window also came
out exact (the same three k as hardware; it had looked six wide only because
of where the refill was charged). Suite and runner row-identical.

**2. The HLE's Halt returned a cycle early.** Section 22 blamed IntrWait and
was wrong. `-d:irqlog` shows both cores take the wake IRQ on the same cycle;
what differed was the *first* Halt in `vbwait.s`, which starts the page's
clocks. `HALT_RETURN_COST` 20 -> 21 and the HLE matches the real BIOS -- and
the console -- on T, R and H alike. `halthb.s` never saw it because a Halt
return cancels out of that page's difference.

That exposed **3: `SIO_TRANSFER_OVERHEAD` was 8 and should be 7.** The four
SIO timing rows end on a Halt wake, so they measure the serial start-up
*plus* the Halt return. At 8 they passed under the HLE and read exactly one
cycle long under the real BIOS, which is why the real-BIOS core has always
scored 0/4 there: the short Halt was hiding the long serial start. **The
real-BIOS core now passes all four, for the first time.**

**4. An IRQ that wakes an HLE Halt returns into the BIOS, not the caller.**
`exception_return_restore` gives a cycle back unless the return refills from
the gamepak. Under the HLE a halted SWI's wake IRQ returns, notionally, to
the caller, so a cartridge-resident caller lost the cycle; on the console
that return is into the halted BIOS routine whatever the caller's region.

Probes that came back *clean*, and so rule their suspects out:
`slotret.s` (an exception return into gamepak Thumb costs exactly what a
branch does -- console, both cores and mGBA all 20/20/13/13), `vbwait.s` with
a table-walking dispatcher (`mrs`, four-register push and pop, word-wide I/O
reads, an IME write: the real-BIOS core returns on the console's cycle,
2352 / 2351), and a DMA swept across a store (no phase costs anything extra,
on silicon or here -- so the one-cycle saving in section 22 really is the
internal cycle, not data cycles in general).

### Where the row is now

**The HLE and the real BIOS agree on every row of both ROMs**, 6997/6998
each, down to the knife-edge value: `0x10002540` on the released fork,
`0x10002B1C` on the rebuilt one. Section 23's HLE pass was error 1 and error
2 cancelling; hand-walking section 22's rules had predicted line 12, and that
is what both cores now compute.

**mGBA reports exactly `0x10002A94` on the rebuilt ROM.** So the suite's
constant is reproduced by the suite author's emulator and by nothing else we
have -- and mGBA is measurably wrong, against this console, on the mechanisms
that decide it: it defers the grant across whole instructions (section 22),
charges nothing for the broken burst, raises the V-count interrupt a cycle
early and enters a wake handler three cycles early (`vbwait.s`). Section 20
had already found this constant's predecessor agreeing with that emulator
and not with a console. It may still be right: eleven lines against twelve
is one cycle, and there are mechanisms here measured only in one context
(the internal-cycle overlap is unmodelled and is not on this walk; the wake
handler is entered two cycles late on the console with the return on time).
But it is no longer the better-supported number.

Three photographs settle it, and they discriminate cleanly:

| ROM, how run | dingbat (both cores) | mGBA / suite constant |
|---|---|---|
| `mgba-suite-upstream-official.gba`, fresh boot, Misc | `0x10002B1C` | `0x10002A94` |
| the same, after running SIO timing first | `0x10002540` | -- |
| `mgba-suite-irqreset.gba` (rebuilt fork) | `0x10002B1C` | `0x10002A94` |

### Still open, all measured

- The wake handler is entered 2 cycles later on the console than in either
  core, and left 2 cycles sooner; the return is on time. `cpu.irq`'s
  entry/return split is calibrated on a running CPU and is wrong for a
  halted one. Visible only to code that reads a clock inside a wake handler.
- A DMA requested during a data cycle runs over the internal cycle after it
  (-1). Unmodelled.
- The H-blank grant's deferral to the end of the access in flight moves the
  DMA's own writes by up to 4 cycles at 4/2. Unmodelled; it does not change
  what the CPU pays.
- A DMA landing between the bytes of one unmapped read tears the word
  (`000000FF`). The console reads it whole.
- With the prefetcher on, a branch into the gamepak is still refilled in the
  old order.

New: `tests/roms/payloads/slotret.s`, `vbwait.s | 0x200`, `slotdma.s` hop 3
(a store), `-d:irqlog`.
