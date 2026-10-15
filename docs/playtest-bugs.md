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

> **Superseded in part by section 25**, the same night. "Where the row is
> now" below is wrong: the suite's constant is the console's number. Every
> term had been compared with the console and the sum had not; run end to
> end, the console disagreed with both cores by one cycle, and the cycle was
> the H-blank flag's.

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


## 25. The pieces matched and the sum did not: the H-blank flag rises at 1007, 2026-09-20 late

Section 24 ended with both cores agreeing on `0x10002B1C`, the suite and mGBA
on `0x10002A94`, and every term of the row individually compared with an AGB
SP. Matt's question was the right one: what is confounded? The answer was
the one thing never done -- **the whole sentence had never been run on the
console**, only its words.

### The row is an exact tie

`-d:obuslatchdbg` on the rebuilt ROM: on line 11 the DMA's request landed on
the very cycle the `ldmia`'s own fetch would have begun, the DMA went first,
the fetch refreshed the bus and the capture was lost; line 12 caught it. A
sweep of the loop's entry (a throwaway `BREAK_DELAY` knob) showed the
structure: the answer encodes the entry delay mod 36 in its low bits *and*
the catching line, `0x10002A94` is in our family one line up, stale
dispatcher entries cannot produce it (three give `...2A90`), and **entering
one cycle earlier passes, under both cores.** So: one cycle between
VBlankIntrWait's return and an H-blank DMA's request, or the tie-break.

### `breakram.s`: the same sentence, where the rig can run it

An empty slot cannot hold a loop, so `tests/roms/payloads/breakram.s` runs the
suite's sequence from RAM: DMA3 with the suite's control word, SWI 5 through
Nintendo's BIOS, a table-walking dispatcher, the suite's entry instructions
and its seven-instruction loop on unmapped memory, from IWRAM (period 12,
one-cycle window, walk +4) or EWRAM (period 30, window 3, walk -2), swept over
a sled of one-cycle NOPs after the return. Each k is one end-to-end number
and every edge in the staircase is a one-cycle statement.

**The console caught at dingbat's k + 1 with identical read counts, every
run.** A stamp mode (the same DMA's word also stops a timer started by the
entry sequence) split it: the console's T was ours + 1 at every k, *and the
capture fell at the same T in both*. So the tie-break was right and the DMA's
write was a cycle late on the console relative to the return -- V-blank wait
or V-count wait, same line or 68 lines on, DMA0 or DMA3, and the V-blank DMA
too. `slotdma.s`'s own control had said so all along (D = 980 against our
979); section 22 filed the D column under "deferral, unmodelled" and compared
only the cost column. That was the confounder.

### Which end moved: single reads of DISPSTAT

Both DMAs late by one cycle is either the DMAs or the anchor. A third mode
spins a coarse delay after the entry and reads DISPSTAT and VCOUNT *once* --
no polling loop, which is what quantised `linegeo.s` and `hdmageo.s` to
seven cycles. From the same V-count entry, to the cycle:

| event | console vs dingbat |
|---|---|
| next VCOUNT edge | same |
| H-blank flag falls | same |
| V-blank flag rises (line 160) | same |
| **H-blank flag rises** | **+1** |
| H-blank DMA's write, V-blank DMA's write | +1 |
| V-count match flag changes | +1: it reads its old value for one cycle after VCOUNT moves |

The entry was right. **The H-blank flag rises at 1007, not GBATEK's 1006**
(low for 1007 cycles, high for 225), and the H-blank DMA follows it at +2 as
before; the V-blank DMA's request is +2 as well, not +1. `hdmamul.s`'s 227
had been bought in section 14 with a V-blank +1 that was correct only while
the H-blank DMA was also a cycle early -- the common-mode blind spot that
`docs/gbatek-upstream.md` section 3 warns about in its own words.

Entering on a **running** CPU (the interrupt lands in a ring of one-cycle
Thumb NOPs and the dispatcher rewrites the BIOS's saved lr) gives the same +1,
so it is not a halt-wake effect.

### Four more things the same payloads measured

1. **One interrupt delay, not three.** With the flag at 1007 and no DMA
   armed, a running CPU takes the H-blank interrupt 4 cycles after the flag,
   and `halthb.s` without its DMA wakes at 1003 on the console and, at 4,
   here. The V-count match is raised one cycle after the line boundary (the
   lagging flag above) and V-blank at it, so 4 serves both -- which is
   section 22's "V-blank is a cycle ahead of V-count", explained. The old
   4 / 5 / 6 becomes `PPU_IRQ_SYNC_DELAY = 4` plus `VCOUNT_MATCH_DELAY = 1`.
   H-blank's 6 had been 4, plus the flag's missing cycle, plus one cycle of:
2. **A DMA stalls an interrupt still in the synchroniser by its whole
   length.** A running CPU takes the H-blank interrupt exactly 4 cycles later
   with a one-word H-blank DMA armed than without. A wall-clock delay loses
   one cycle to it. `dma.nim` now pushes pending interrupt checks back by as
   long as a (non-nested) burst held the bus. H-blank interrupt plus H-blank
   DMA is what every raster effect does.
3. **A halted CPU resumes on a DMA's last cycle.** `halthb.s`: 1003 with no
   DMA, 1004 / 1006 / 1010 under one, two and four words; waiting the burst
   out reads a cycle more each time. The same cycle section 22 saw a running
   CPU get back when an internal cycle met a DMA.
4. The V-count match flag is a live compare: rewrite the setting mid-line and
   the flag is already clear, where we (and mGBA) held it to the next line.
   DISPSTAT reads now compute it. Whether a mid-line match *raises* the
   interrupt is not measured.

### Where that leaves everything

`tools/hwlink/breakram.py --record` stores the console's table (15 sweeps,
152 cells, three runs each; 151 cells gave one answer) and `--check` scores
the emulators against it:

| | cells matching the console |
|---|---|
| dingbat, HLE | **151 / 152** |
| dingbat, real BIOS | **151 / 152** |
| mGBA 0.10.5 | 70 / 152 |

(The odd cell is the one the console answered two ways.) `halthb.s` and
`hdmamul.s` are byte-identical again -- `halthb.s` had quietly stopped being
so when section 24 moved the HLE's Halt return, and nothing re-ran it --
`slotdma.s`'s D floor is 980 in both, its cheap rows and the `ldmia` capture
window sit on the console's k (they had been one k early, which section 24
called a match), `vbwait.s` is unchanged.

**The mGBA suite's rebuilt ROM scores 6998 / 6998 under the HLE and under
the real BIOS.** The released fork still fails `DMA Prefetch Break` with
`0x10002540`, as a console would: that is the stale TIMER1 handler of section
23, and `breakram.py --stale=1` confirms eleven cycles an entry on silicon
(one 12-cycle read fewer, one NOP more).
Runner 1219 / 1171 / 48, row-identical; save-state, clip-replay and rewind
tests pass.

So the constant was the console's, mGBA reaches it with compensating errors
(it matches fewer than half of these cells), and section 24's table of
predictions is withdrawn: an official build from a fresh boot should read
`0x10002A94`, and `0x10002540` after SIO timing.

Method, for next time: **compare the sum, not just the terms** -- and when a
runner prints two columns, a mismatch in the one you were not looking at is
still a mismatch.

Still open: the handler-entry split (+2 / -2, section 22), the grant's
deferral, the internal-cycle overlap for a running CPU (it needs a stamp on
every bus access, the hottest path in the core, for one cycle at one phase),
and the prefetch-on refill order.

> All four are settled in section 26.

**An LYC write that newly matches does raise the interrupt.**
`tests/roms/payloads/lycwrite.s`, parked on line 100 with IME clear and IF
clean: moving the setting 50 -> 100 sets IF's V-count bit at once; turning
the enable on while already matching does not; acknowledging IF while still
matching does not bring it back. So the match is an edge of the live compare
and a register write can make one. Neither emulator did; dingbat now does.

The torn unmapped word (section 22, item 5) is fixed: an unmapped read now
takes one verdict for the whole access (`read_open_bus_word`) instead of one
per byte with a catch-up -- and possibly a DMA -- between them. `slotdma.s`
hop 2 reads `FFFFFFFF` at that phase, as the console does.


## 26. The open items, chased: five more laws and one link-rig defect, 2026-09-21

Section 25 closed the suite and left four things open plus one odd cell in
`breakram.py`'s table. All five are settled here, each against the console.

### The odd cell was the link, not the console

`--stamp --vcount=160`, k = 2, had answered `T=19099` once and `T=19100`
twice. Ten more runs: `19100` every time, which is dingbat's answer -- and
`19099` is k = 3's. `monitor.py` verified the payload's bytes by reading them
back but sent the ARGUMENT bare in the call command, so one flipped bit ran
k = 3 and filed it under k = 2. `run_payload` now uploads a nine-word
trampoline behind the payload: the argument rides in memory (read back with
the code), the result is stored beside it and read until two reads agree.
The whole table re-recorded through it: **152 cells, 152 single-valued, the
only change that one cell. dingbat 152 / 152 under both BIOSes.**

### 1. A halted CPU runs one more instruction before it takes the interrupt

`tests/roms/payloads/wakeirq.s`: halt through SWI 2 with IME on, and have the
handler report the return address the BIOS's dispatcher pushed. We said
`0x1B4` (the `bx lr` after Halt's HALTCNT write, not yet run); **the console
says `0x170`: the `bx lr` has already executed**, and the handler is entered
2 cycles later (`0x9A1` against `0x99F`). A plain wake with IME clear is on
the same cycle in all four columns. The interrupt input is synchronised on a
clock that was stopped, so the wake comes first and the exception one
instruction later. That is the whole of section 22's "entered 2 later, left
2 sooner, return on time": the three cycles of `bx lr` (`bl` in IntrWait)
move from after the handler to before it, less one cycle that turned out to
be a different bug:

### 2. The IRQ entry/return split was a cycle out, hidden by a timer stop that was a cycle early

The control for the above runs the CPU into a sled of 2700 one-cycle NOPs
instead of halting. V-count match or timer overflow, the console interrupts
**the same NOP**, **returns on the same cycle**, costs **the same in all**
(return into the sled instead and its end does not move) -- and reads a
clock in the handler **one cycle sooner**. So entry was a cycle long and the
return a cycle short. Moving that cycle alone failed about 250 of the mGBA suite's timer
rows, which stop a timer inside a handler. One more control: stop a timer as
the handler's first act. Identical on the console and here. Reads a cycle
apart and stops not -- so `tests/roms/payloads/tmrw.s` does it in
straight-line IWRAM code: start, NOPs, read, three NOPs, stop, read the
frozen count. The first read agrees; **the console freezes one higher. A
write that stops a timer takes effect a cycle after we had it.** The suite's
rows pass either way because they only ever see entry + stop.

With the stop where it belongs every DMA-written stop stamp on every page
moved a cycle, which located the last piece: a burst's two hand-off cycles
are one before its first transfer and one after its last, not two in front.
All four together: `IRQ_ENTRY_EXTRA = 1`, `TIMER_STOP_DELAY = 1`,
`DMA_LEAD_CYCLES = 1`, and the HLE's fitted `SIO_TRANSFER_OVERHEAD` follows
the stop (its four rows stop a timer to read it). Suite and runner
row-identical; `vbwait.s` H, R and T are the console's under both cores for
the first time, all three modes.

The HLE gets the same shape by number: three cycles before the entry on a
wake, three fewer on the way out. The one cell it cannot match is the
address itself -- the HLE has no BIOS instruction to be inside.

### 3. The grant waits for the access in flight, and the CPU works through the burst when it can

`tests/roms/payloads/dmaphase.s`: the halted, interrupt-anchored entry,
a one-cycle NOP sled, then a long run of ONE kind of instruction under a
one-halfword H-blank DMA that freezes TM1 with its own write. D is when the
DMA wrote; T less the no-DMA control is what the CPU paid.

| run | D over a period | the CPU pays |
|---|---|---|
| multiplies (1 fetch + 4 internal) | flat | **4, 3, 2, 1, 0** as the request moves from the last internal cycle back to the fetch |
| EWRAM loads (1 + 6 + 1) | ramps 0..5 across the data access, snaps | 3 with the grant just before the internal cycle or in it, else 4 |
| IWRAM loads (1 + 1 + 1) | flat | 3 on the data cycle, else 4 |
| NOPs | flat | 4 |

Two rules, and both are about the bus. **A request inside a bus access is
granted at that access's end** (a 32-bit EWRAM load is ONE six-cycle access,
not two). **The CPU is stopped only when it needs the bus:** internal cycles
run underneath a burst, all of them, so a four-cycle DMA inside a multiply
can cost nothing at all. Section 22's "-1" was the one-internal-cycle case.

Knowing where accesses end costs a scheduler sync per access, which is what
section 16 priced itself out with. `DMA_ACCESS_WINDOW` pays it only from the
H-blank's start to the request (49 cycles a line) and only with an H-blank or
V-blank DMA armed, with no new test on the fetch path at all: the window
invalidates the fetch cache and rides its miss path, data accesses reuse the
flag test the immediate-DMA window already made, internal cycles take one
predictable branch. A gamepak branch's refill becomes two accesses inside
the window, and a burst between them breaks the second. Cost, retired
instructions, 1500 frames: Metroid Zero Mission +0.70%, Golden Sun 2 +0.63%.
`dmaphase.s` 36 / 36 under both cores (mGBA 13); `slotdma.s`'s D column,
section 22's unmodelled ramp, now the console's at every k.

### 4. With the prefetcher on, the refill is in the same order and a DMA off the gamepak is nearly free

`slotdma.py --waitcnt=0x4000` -- the empty slot survives the prefetcher at
4/2 waits. No-DMA baseline 1043 with it on or off (the chain is all branches).
With it on the console pays **0** cycles for a DMA at nine of fourteen
phases, 3 at three, 4 at the two that are in IWRAM; with it off, 4 plus the
forced nonsequential fetch. The prefetcher keeps fetching while a burst that
never touches the gamepak has the bus. `ROM_REFILL_ORDERED_PF` (the refill
in hardware order with the prefetcher on too) and `DMA_KEEPS_PREFETCH` (such
a burst neither breaks the stream nor wastes its cycles) give D 14 / 14 and
T 11 / 14 against 5 and 3 before. The three left are one cycle each, at the
phases where the grant follows the opcode's own fetch and a branch is next:
it looks like the prefetcher's committed-halfword penalty applying to a
branch's first fetch, and the suite's prefetch columns are too many passing
rows to try that on one page's evidence.

### Where everything is

| table | dingbat, HLE | dingbat, real BIOS | mGBA 0.10.5 |
|---|---|---|---|
| `breakram.py --check` | 152 / 152 | 152 / 152 | 70 |
| `r0table.py --check` (`dmaphase`, `wakeirq`, `tmrw`, `lycwrite`) | 54 / 55 | 55 / 55 | 16 |

mGBA suite: rebuilt fork ROM 6998 / 6998 under both BIOSes, released ROM
still its one row (section 23). Runner 1219 / 1171 / 48, row-identical;
save-state, clip-replay and rewind tests pass. `halthb.s`, `hdmamul.s` and
`vbwait.s` word-identical to the console under both cores.

Still open, smaller than before: the three prefetch-on phases above; a
handler on the HLE finds a different return address on the stack than
Nintendo's BIOS leaves; the library-wide waitloop on==off sweep has not been
re-run on this tree.

Method, again: a row that passes is evidence about a SUM. The timer rows
had always passed on entry + stop, and each term was a cycle out.

## 27. Boktai 2: the REGION SETTING screen ignores every key, at some clock times, 2026-10-01

**FIXED** (dma.nim, interrupts.nim). Boktai 2 - Solar Boy Django (U) drew the
region list after the time setting and then took no key, under the HLE and
Nintendo's BIOS alike, with the cart clock frozen at 00:00, 00:01, 01:00 or
06:00 but not at 00:30 or 12:00; the references went on to the KONAMI logo.

**It was not the solar sensor.** The game had crashed. Its IRQ handler
(IWRAM 0x03002D00) dispatches on IE & IF in a fixed order -- V-count,
serial, timer 3, H-blank, V-blank, timers 0-2, DMA, keypad -- through a
table at 0x03002CB0, with a game-pak entry that stops the sound and loops.
Entered with IE & IF zero it falls through all of them to the fourteenth
slot, which is null, and jumps to address 0. The timer interrupts kept
running afterwards: timer 3 is the solar sensor's clock (each overflow
writes one clock edge to the GPIO port at 0x08247F36 and reads the
comparator), so the port kept being clocked with the main loop gone, which
is why the sensor readback looked different from mgba's.

**The interrupt with no source.** Timer 3 overflowed inside a 196-cycle
DMA3 copy. The game has sound DMA armed, so DMA3's burst is preemptible and
its transfer loop dispatches due events at transfer boundaries: the raise
ran before the burst's stall span was known, got a plain 3-cycle
synchroniser delay, and the burst's end then pushed it back by the whole
burst (`pipe_due += held`). Meanwhile the CPU took a pending H-blank
interrupt the moment it had the bus back; the handler served timer 3 first
and acknowledged it, a nested entry acknowledged H-blank, and 180 cycles
later the synchroniser delivered its stale IE & IF sample as a fresh
interrupt. Which DMA3 copy a timer 3 overflow lands
in depends on what the game does that frame, and the clock changes that,
hence the clock times.

**The law already in the core, applied to this path.** A timer interrupt
raised while a burst holds the CPU off the bus counts from the burst's end
(raise_synced: `stall_to + IRQ_SYNC_DELAY - UNDER_BURST_CREDIT`, measured
with `irqstorm.s` on the AGB SP). A raise the burst's own loop dispatched now
gets the same at the burst's end, and a check dispatched inside the burst no
longer recognises what the stopped synchroniser holds. Arming an idle
channel the console never sees fire can no longer move a timer interrupt.

**Evidence.** `tests/roms/payloads/dmairqarm.s`: TM0's interrupt raised k
cycles into a DMA3 burst, with an idle sound DMA armed (sound master off, so
it never requests) or not. Before: armed, every raise inside the burst was
taken 2 cycles early, and at k = 4 twice (`010200DC`); after: armed answers
equal unarmed at all 30 pairs (then held by `cyclelaws_test` as
console-free invariants). The rig was not connected on 2026-10-01, so the
absolute entry cycle waited for the console (below); mgba takes it 5 cycles
earlier than dingbat throughout, armed or not.

**Console, 2026-10-02.** `r0table.py --record dmairqarm` on the AGB SP: the
console answers every (not armed, armed) pair alike, and every cell's entry
cycle is dingbat's -- dingbat and dingbat-bios 60/60, mgba 16/60. The 60
cells are console laws now (`tests/roms/cyclelaws/dmairqarm.gba`, both
BIOSes), which hold the pairs equal and the absolute cycle besides;
`tests/roms/invariants/` is gone.

| clock (2006-01-01, UTC) | 00:00 | 00:01 | 00:30 | 01:00 | 06:00 | 12:00 | 23:59 | host |
|---|---|---|---|---|---|---|---|---|
| dingbat-bios before | stall | stall | ok | stall | stall | ok | ok | ok |
| dingbat (HLE) before | ok | ok | ok | ok | ok | ok | stall | stall |
| both, after | ok | ok | ok | ok | ok | ok | ok | ok |

Every 37 minutes through the day (39 clock times, dingbat-bios): 17 stalled
before, none after.

The script (`cd10d8ed....play`) now replays on dingbat and dingbat-bios with
the references' screens at all eleven checkpoints. Runner, both mGBA suite
BIOS modes (6998 / 6998), cycle laws, RTC, save-state and soak tests:
unchanged.

## 28. Phantasy Star Collection: every Master System window drawn with shifted scanlines, 2026-10-02

**FIXED** (dma.nim, `DMA_BUS_BACK_TO_BACK` in gba.nim). In Phantasy Star
(the first game of Phantasy Star Collection (U)), from about frame 3800 --
B opens the command menu in Camineet -- every window the game draws (the
command menu, the status box, messages, the save slot and continue screens)
showed repeated or shifted scanlines and struck-through text, in all four
dingbat configurations. mgba and the second reference draw them clean and
agree pixel for pixel. The game itself went on; its save was byte-identical
on all six.

**How the collection draws a Master System screen.** Its player puts the
picture on BG1 and a high-priority copy of the window rows on BG0, and
scrolls both per line from one table: DMA1 (H-blank, repeat, 16-bit, CNT_H
0xA240) moves a halfword a line from a ROM table at 0x08770E5B/0x08770E5F
to BG1VOFS; DMA2 (H-blank, repeat, source FIXED at 0x04000016) moves
BG1VOFS to BG0VOFS. BG1VOFS is write-only, so DMA2's read is open bus: it
gets whatever is on the data bus, and the design works only if that is the
word DMA1 drove there a moment earlier. Then BG0 scrolls with BG1 and the
window rows sit over the picture rows they belong to.

**What dingbat gave it.** `DMA_READS_CPU_BUS` (gba.nim; dmaobus.s on the
AGB SP, 2026-09-24) says a burst's first unmapped read gets
the CPU's last bus transaction -- its data load if it came after its last
fetch, else the fetched opcode -- and every non-nested burst marked itself
`dma_bus_fresh` to take that path. DMA2 is not nested (both channels are
requested on the same H-blank and `run_pending` grants them one after the
other), so each line's BG0VOFS was a halfword of whatever the SMS
emulator's code had last fetched or loaded (`0C03`, `19A1`, ... where DMA1
had written `0000`, `0001`, ...). BG0's rows landed at arbitrary heights:
the shifted lines and the strike-throughs.

**Why the CPU's word is wrong there.** The CPU never had the bus between
the two bursts. `tests/roms/payloads/hdmalag.s` measured that on the AGB SP
on 2026-09-24: of two channels granted on the same H-blank, the second
makes its first read the cycle after the first's last write. The bus goes
from DMA1 to DMA2 with DMA1's last word still on it, as it does inside a
burst and for a nested one, which the core already modelled. Both
references draw the game accordingly. (dingbat then still started the
second burst two cycles later than the console, hdmalag's known offset; the
word on the bus does not depend on it. Fixed the same day, below.)

**The change.** `run_pending` notes when the grant it is making follows a
burst it ran itself, with no CPU access between, and `run_channel` then
leaves `dma_bus_fresh` clear: the burst's first unmapped read returns the
last word the bus carried (`dma_open_bus`). That covers two channels on one
H-blank (or V-blank) and a chained immediate pair (`DMA_CHAIN`). A burst
granted after the CPU had the bus still reads the CPU's word, so every
dmaobus/alyosha Bus cell stands.

**Probe: `tests/roms/payloads/hdmaobus.s`** (as predicted before the console
answered; its answers follow the table).
DMA1 writes X_k = `A500 | 11k` to BG1VOFS on line 40 + k; a second channel
reads BG1VOFS (fixed) into EWRAM on the same H-blank, eight lines. Writer
first (reader DMA2) or reader first (reader DMA0); the CPU in a Thumb NOP
sled (`46C0`) or halted through SWI 2. Answer: the halfword read on line
40 + k, with the number of reader bursts (8) in bits 16-23.

| cells | dingbat before | dingbat after | mGBA | predicted for the SP |
|---|---|---|---|---|
| writer first, sled, k = 0, 1 | `46C0` (the CPU's NOP) | X_k | X_k | X_k |
| writer first, sled, k = 2..7 | `1AFF` / `E1C6` (the VCOUNT poll) | X_k | X_k | X_k |
| writer first, halted, k = 0..5 | `0000` HLE / `0300` BIOS | X_k | X_k | X_k |
| reader first, sled, k = 0, 1 | `46C0` | `46C0` | `46C0` | `46C0` |
| reader first, halted, k = 1..5 | `0000` / `0300` | `0000` / `0300` | `7F00` | open |

The last row is the open question the probe adds: a halted CPU drives
nothing, so the reader granted first may find the writer's word from the
line before (X_(k-1)) still on the bus. dingbat answers what the CPU last
fetched in the BIOS's Halt; no test holds that row. The other 18 cells are
held by `cyclelaws_test` from `tests/roms/invariants/hdmaobus.gba`, marked
predicted, until the console answered.

**Console, 2026-10-02.** `r0table.py --record hdmaobus` on the AGB SP.
Writer first: X_k in every cell, sled or halt -- `DMA_BUS_BACK_TO_BACK` is
the console's, and so is the game's design. Reader first in the sled: `46C0`
at k = 0, 1, and from k = 2 several answers a cell (the poll loop's opcodes
or the line number it loaded): where the arming leaves the sled is not
fixed, so the H-blank lands anywhere in a 7-cycle loop; ten runs of 0x102
gave six different words. Those six cells are no law (`lawrom.py` leaves a
cell with two answers out). Reader first under the halt, the open row:
**X_(k-1)**, the writer's word from the line before, k = 1..5; the BIOS's
last fetch (`0300`) at k = 0; after the wake on line 46, `002E`, the line
number the CPU's VCOUNT `ldrh` had just loaded; on line 47, `E150`, the
poll loop's `cmp`. dingbat answered the CPU's last fetch for all of these
(`0300` / `0000`, `1AFF`, `E1C6`).

`tests/roms/payloads/hdmaphase.s` took the halted half apart (80 cells,
every one unanimous): the poll loop's phase on line 46 walked one cycle at a
time by NOPs after the wake and read on lines 46-48, the reader alone and
with the writer, and VCOUNT loaded as a byte, halfword and word read back
through either half of the I/O word. Four rules came out of it, each a knob
in gba.nim:

| knob | what the console showed |
|---|---|
| `DMA_BUS_WHILE_HALTED` | a halted CPU drives nothing: a burst granted with the CPU halted since the last one ended reads that burst's last word (hdmaobus X_(k-1); the reader alone keeps its own `0300` every line) |
| `DMA_READS_IO_LOAD` | the CPU's last data load counts when it was an I/O register too, and the I/O bus is 32 bits wide: an `ldrh` or `ldrb` of VCOUNT leaves DISPSTAT (`2E26`) on the lower half as well. The load's value stays through its internal cycle |
| `DMA_SEES_REFILL_FETCH` | a request between a branch's two refill fetches finds the first (the loop's own first opcode); the core charges the refill as one block, so r15 alone answered the second |
| `DMA_PENDING_CHAIN` | a request latched together with a burst's (two channels on one H-blank) follows it with no hand-back and no lead: the one-halfword reader holds the CPU 6 cycles, reader plus writer 10, not 12 -- hdmalag's "the second channel starts two cycles late here", from the CPU's side. Requests arriving during a burst are not chained: unmeasured, and a first version that chained them too moved Pokemon Mystery Dungeon - Red Rescue Team's timing-seeded personality quiz under the official BIOS (other questions, the script desynced; all four configs pass with the narrower rule) |

The last one also brings hdmalag's configurations 23-28 and 30 (DMA3 behind
DMA1 across the drop edge) onto the console: recorded the same day and
frozen; 29 still differs (18 bursts here, 20 on the console). The HLE's stub
BIOS gained the two stack literals after Halt's `bx lr` (the default user
and IRQ stack tops), so the halted fetch reads the same word under either
BIOS.

| table | dingbat before | after | Nintendo's BIOS before | after | mGBA |
|---|---|---|---|---|---|
| hdmaobus (32; 6 racing) | 18 | 26 | 19 | 26 | 18 |
| hdmaphase (80) | 38 | 80 | 41 | 80 | 9 |
| hdmalag 23-28, 30 (28) | 21 | 28 | 21 | 28 | 6 |

Every other recorded cell holds (`r0table.py --check`: 1893/1898 dingbat and
Nintendo's BIOS, the five misses racing cells; cycle laws 2072/2072 under
both BIOSes).

**ps1_title's rows 7k+2/7k+3 are not a second DMA effect.** The evaluator
also saw BG1 row pairs one table step early at checkpoint ps1_title
(f1982). The game alternates DMA1's table start between 0x08770E5B and
0x08770E5F (two entries apart) every frame: a two-field line-drop pattern
for squeezing the Master System picture. dingbat's frame 1983 is pixel-
identical to the second reference's frame 1982 (mgba differs from both only
by the blinking cursor), so dingbat is one field out of phase at that frame
-- the same thing as the starfield twinkle the script notes -- and the
harness already rates that checkpoint as the references' own spread.

**Evidence.** The script (`9f2dc591....play`): FAIL (field_menu, save_slot,
saved MAJOR) before on all four dingbat configs, PASS after on all four,
every checkpoint on the references' screens. A build that logs every burst
whose first read takes the new path ran all 135 scripted games (dingbat,
HLE): Phantasy Star Collection is the only one that ever reaches it, so
every other script's emulation is unchanged; the six-emulator scripts of
Golden Sun, F-Zero - Maximum Velocity, Mario Kart Super Circuit, Castlevania
- Aria of Sorrow, Pokemon Emerald and Iridion II still PASS. Runner 1433/1443, mGBA suite
6998/6998 (HLE and Nintendo's BIOS), dbsuite unchanged (dma 261/262, bus
76/79, both BIOSes), cycle laws 1860/1860 and invariants 30/30 under both
BIOSes.

## 29. Final Fight One: a frame late after a load, and why that is the references, 2026-10-02

The playtest evaluator flagged dingbat (every config) a frame behind mGBA,
with the second reference agreeing with mGBA, in Final Fight One (fade-in
after the black loading screen at f315), The Sims - Bustin' Out (first ~40
frames), Harvest Moon - Friends of Mineral Town, Yu-Gi-Oh! The Eternal
Duelist Soul, Lunar Legend and Yoshi's Island. **No emulator change: in the
three traced, every cycle dingbat spends that the references do not is a
cost silicon has already measured or a hardware-verified test requires.**

### How it was found

`tools/playtest/drivers`: dingbat's `peek` was a *timed* bus read (it
charged wait states), so peeking RAM every frame moved the game; it is now
untimed. New debug commands (README, "Driver protocol"): `trace N PATH` in
dingbat and mGBA (PC and master-clock cycles per instruction, black-box
from mGBA's public step and timing calls), `runto PC`, `pft PC N PATH`.
With them: replay the frozen script, diff RAM per frame, then trace both
emulators across the frames where RAM first diverges and compare the cost of
the same loop.

### Final Fight One

* RAM diverges at **f280**, not f315: from there dingbat's EWRAM at frame
  f+1 equals mGBA's at f (2 bytes differ) all the way to the fade-in.
* f272-f280 is a loading thread: an LZ decompressor in Thumb ROM code
  (0x08045CD0, WAITCNT 0x4314, prefetch on) unpacking straight into VRAM
  with read-modify-write halfwords, then a pass at 0x0803DECC and an EWRAM
  memset (0x0806B838). Both emulators give the thread the same ~279k cycles
  a frame (the main thread and interrupts differ by ~80 cycles a frame).
* mGBA reaches the idle loop **17.6k cycles before** the f280 V-blank;
  dingbat **26.2k cycles after** it, so the game's next step slips a frame.
  The 44k gap:

| | cycles | evidence |
|---|---|---|
| renderer contention on the decompressor's VRAM reads/writes (mode 0, BG1-3 on, palette black) | 16.4k | console-measured (`contmap.s`, CONTEND2: +1 per CPU VRAM read in mode 0); neither reference models it |
| a branch waits out a committed prefetch halfword (`clear_pipeline`) -- the decompressor's `ldrb` from VRAM then `b` pays it on every other byte | 9.7k | needed by alyosha prefetcher_full_arm, _branch_thumb, _thumb_3, _boundary_1/_3 (hardware-verified; WS0 4/2 like this game) |
| everything else: mGBA prices data accesses under the prefetcher below the bus floor | ~18k | the memset loop (4 `stmia` of one word to EWRAM, `subs`, `cmp`, `bhi`) is 38 cycles in dingbat and **26 in mGBA**, though four EWRAM word stores alone are 24 bus cycles and the taken branch's nonsequential refill another 6; `slotexec.s` on the AGB SP: EWRAM load/store from gamepak code with the prefetcher on = dingbat, mGBA 4-5 short |

  `-d:CONTENTION=false` lands 9.8k late, `-d:BRANCH_COMMIT_WAIT=false`
  16.6k late, both off **still 2.5k late** -- f315 either way. Turning off
  measured behaviour does not reach the references' frame.
* The alyosha prefetcher ROMs, 120 frames each in the playtest drivers:
  dingbat passes all nine tried; mGBA fails 8 (passes _branch_thumb_6);
  the second reference fails 5 (_branch_thumb_2/_3/_4/_6, _full_arm). Both
  references' prefetchers are fast in ways hardware is not.

### The others traced

* **The Sims - Bustin' Out**: boot clears 40 KB of EWRAM with
  `stmia r0!,{r1}; adds; cmp; bcc` from ROM at WAITCNT 0x4314: **18 cycles
  an iteration in dingbat, 14 in mGBA** (one EWRAM word store is 6 bus
  cycles and the taken branch's refill 4 + 2). The references do not agree
  either: the second reference shows the 30 Hz animation a frame *ahead* of
  mGBA, dingbat a frame behind, three phases from f33.
* **Harvest Moon - Friends of Mineral Town**: the boot Huffman decoder
  (0x080D1186, WAITCNT 0x4017) loads its bit stream from the cartridge
  with `ldmia r0!,{r2}`; dingbat charges the fetch after a gamepak data load
  nonsequential and the load's I cycle no prefetch (alyosha
  prefetcher_branch_thumb_2, failed by both references): 4 cycles a word
  more than mGBA. mGBA's frame-10 work ends with 46k idle; dingbat's spills
  just past the V-blank and loses frame 11 -- the farm layout seed follows.
* Not traced (and `-d:CONTENTION=false` / `-d:BRANCH_COMMIT_WAIT=false`
  change none of their first divergent frames, nor The Sims' or Harvest
  Moon's): Yu-Gi-Oh! EDS (first difference f32, where the second reference
  also leaves mGBA), Yoshi's Island (dingbat briefly *ahead* at f93, f191),
  Lunar Legend (both dingbat configs match mGBA f2-f560; the second
  reference already differs from mGBA every fourth frame from f33), MMBN2/4.

### Hardware check

`tests/roms/payloads/slotbranch.s` + `tools/hwlink/slotbranch.py` (empty
slot, WAITCNT 0x4000 only): one load fetched from the slot, then the BL
suffix branching either home (control) or to `bx r6` at 0x08008E60 in the
slot. The rom-home difference per load is the gamepak branch target's cost:

| load (d = data + I cycles) | dingbat home/rom/diff | mGBA home/rom/diff |
|---|---|---|
| `ands` (no data) | 18 / 29 / 11 | 18 / 29 / 11 |
| `ldr` IWRAM, d=2 | 18 / 29 / 11 | 18 / 29 / 11 |
| `ldmia` IWRAM 2 regs, d=3 | 19 / 30 / 11 | 18 / 29 / 11 |
| `ldmia` IWRAM 3 regs, d=4 | 20 / 32 / **12** | 18 / 29 / 11 |
| `ldrh` EWRAM, d=4 | 20 / 32 / **12** | 18 / 29 / 11 |
| `ldmia` VRAM 2 regs, d=5 | 21 / 32 / 11 | 18 / 29 / 11 |
| `ldmia` VRAM 3 regs, d=7 | 23 / 35 / **12** | 18 / 29 / 11 |
| `ldr` EWRAM, d=7 | 23 / 35 / **12** | 18 / 29 / 11 |
| `ldr` VRAM, d=3 | 19 / 30 / 11 | 18 / 29 / 11 |

The commit wait shows as diff 12 at d = 4 and 7 (d mod 3 = 1 at S = 3);
the home column re-asks section 22's question for more loads (mGBA charges
none of them). A console that reads 11 everywhere refutes the commit wait at
a branch and makes Final Fight 9.7k cycles faster -- still a frame behind
the references.

**Console, 2026-10-02.** `slotbranch.py` on the AGB SP (empty slot): every
single-load row is dingbat's, home, rom and diff, including the d = 4 and
d = 7 cells' diff 12 -- the commit wait at a gamepak branch target
(`BRANCH_COMMIT_WAIT`) is the console's, and the references' 11 is an
under-charge (mGBA is wrong on rows 2-8). Rows 3 and 6, the 3-register
`ldmia` from IWRAM and from VRAM, vary between runs; over six runs the
console's home path read 22 and 25 where dingbat says 20 and 23 (rom 32 and
35, as dingbat). So multi-register loads in slot code may cost more still on
hardware than dingbat charges, which only widens the gap to the references;
no rule yet fits those two rows and the slotexec/alyosha prefetcher data, so
nothing changed. Final Fight One's frame stays the references' error.

## 30. Kingdom Hearts - Chain of Memories: DirectSound near-mono after the movie, 2026-10-02

**Symptom.** After the opening movie both references play FIFO B (left) 29
output samples (14 FIFO samples at 15768 Hz) behind FIFO A (right) for the
rest of the run; dingbat keeps them sample-aligned, so its wide passages are
near-mono (L/R correlation from the first music on: dingbat 0.90, mgba 0.42,
the second reference 0.44) and the audio check fails in all four configs
(12.3 % of the run). The m4a mixer writes the same position into both
buffers, so any constant offset is the FIFOs', not the music's.

**The register sequence** (dingbat trace, cycle frames; the script's frames
are the same within a frame). The game runs m4a stereo (SOUNDCNT_H 0xA90E:
A right, B left, both TM0) from f3, then for the movie (f1566) switches to
FIFO A alone to both sides (0x0B04: A reset, B unrouted, DMA1 only, TM0
period 532). At f8009 it stops TM0 and DMA1 with FIFO A three bytes short
of a word boundary (15 bytes queued), then m4a's SoundInit: DMA1/DMA2 CNT_H
0x0400, SOUNDCNT_X 0x8F, SOUNDCNT_H 0xA90E (both FIFOs reset), DMA1/DMA2
0xB600, TM0 1254 on V-count 159, SoundMode's TM0 stop / VSyncOff / TM0 1064.
From then on the only writes are m4a's resync every sixth frame (DMA1CNT
0x84400004, DMA2CNT likewise, both CNT_H 0x0400, both 0xB600), which
reloads both sources together and so keeps whatever offset the FIFOs hold.
The boot-time init (f3) is the same sequence from empty FIFOs, and there
all three emulators stay aligned.

**Mechanism.** Both references keep playing the rest of the word a FIFO is
on through a reset; only the queued words go. FIFO A therefore comes out of
the f8009 reset with three stale samples ahead of the new stream and FIFO B
with none, and that difference survives every resync. Black-box evidence:
`tests/roms/payloads/fiforeset.s` (four words, k samples played, reset,
four more words, then the overflow at which each refill DMA first asks)
reads 2 5 4 3 2 5 4 3 for k = 0..7 on both references and 2 everywhere on
dingbat; a FIFO played audibly (pattern words, reset after k samples) shows
the 4 - k mod 4 leftover samples before the new pattern on the second
reference. Built with `-d:FIFO_RESET_KEEPS_WORD=true`, dingbat reads the
references' 2 5 4 3 and its Kingdom Hearts left channel lands 29 samples
behind the right, as on both (L/R correlation 0.44); the playtest goes from
FAIL (12.3 %) to PASS (0.1 %, dingbat and dingbat-bios).

**The master enable is already answered, by the console.** A first version
of the knob kept the word through every reset, including SOUNDCNT_X going
off (the second reference does; fiforeset.s v = 1; mgba clears nothing
there at all). The recorded laws refuse it: two console cells of fifomap
(`r0-agb.json`, 0x1428 and 0x20001428, run straight after a cell that
stops TM0 part-way through a word and exits with the master off) read one
refill burst more than that model gives (0x6A, model 0x4C), and dbsuite's
three fifodma "spike" cells fail. With the word kept through the reset bit
only, every cycle law holds (1860/1860) and the runner is unchanged, so
the knob now covers SOUNDCNT_H's bits alone: whatever the bits do, powering
the sound off empties the FIFO, word and all, as `FIFO_MASTER_RESET`
already has it. Also seen: mgba does not drain a FIFO routed to neither
side (the second reference does, as dingbat does).

**Console, 2026-10-02: the references are wrong.** `r0table.py --record
fiforeset` on the AGB SP reads `00020202` in all 18 cells, by SOUNDCNT_H's
reset bit and by the master enable alike: a FIFO reset drops the word being
played with the rest, as dingbat does. dingbat 18/18, mgba 3/18. Kingdom
Hearts - Chain of Memories' near-mono after the movie is the console's
sound; the wide stereo both references play there comes from their FIFO
reset. `FIFO_RESET_KEEPS_WORD` stays off, documented as the references'
behaviour (kept to reproduce them), and the cells are console laws
(`tests/roms/cyclelaws/fiforeset.gba`). The audio check's FAIL on this
script is the references' spread, not a dingbat bug.

**Status before the console (kept for the record).** No measurement said
what the AGB does there, so the knob shipped off (`dma_channels.nim`
FIFO_RESET_KEEPS_WORD). Run `python3 tools/hwlink/r0table.py --record
fiforeset` with the SP on the link. dingbat predicts 2 for every cell as
shipped and, with the knob, 2 5 4 3 2 5 4 3 2 for v = 0 and 2 throughout
for v = 1; the references read 2 5 4 3 2 5 4 3 2 for v = 0. 2 5 4 3 in A
and B for v = 0 means flip the knob to true (Kingdom Hearts then passes);
2 throughout means the references are wrong and this game is right as it
is. v = 1 should read 2 throughout on the console (fifomap says so); if it
does not, the fifomap reading above needs another look.

## 31. Castlevania HoD: thunder at different frames is the lightning's randomness, not the APU, 2026-10-02

**Symptom.** All four dingbat configs play IDENTICAL to both references at
every checkpoint but fail audio: "differs from both references in 2.4 % of
the run, longest 2.26 s from f6960 (silence/presence ...)". The references
agree with each other. **No emulator change: the difference is which frames
the game chooses for its lightning, and the thunder that comes with it.**

**What the sound is.** On the bridge the game plays everything through FIFO
A (SOUNDCNT_H 0x030E: A to both sides at 100 %, B unrouted; DMA1 on TM0)
plus the noise channel, from its own software mixer; the MP2K HLE is off in
the playtest driver (`gba.mp2k_hle` is set only by the frontends). Per-frame
I/O snapshots (SOUNDCNT_L/H/X, NRxx, DMA1/2 CNT_H, TM0/1) from f6900 to
f7300 show the same register traffic in all three emulators, and the last
NR41/NR44 writes at f6906. What differs is the mix the game writes: the
dialogue's ambience ends around f6978, and a thunder clap of ~160 frames
plays at

| | thunder from | lightning flashes (screen mean > 170) |
|---|---|---|
| dingbat (all four) | f6960, f7240, f7470, f7720, ... | f6968, f7248, f7307, f7482, f7738, f7994, ... |
| mGBA | f7140, f7460, f7720, ... | f7149, f7206, f7465, f7721, f7977, f8072, ... |
| second reference | f7150, f7480, f7740, ... | f7152, f7235, f7493, f7749, f8005, f8034, ... |

Each flash repeats 256 game frames later (a new flash starts a new cycle),
and new ones arrive at random. The references' first flash after the
dialogue lands three frames apart by coincidence: every later flash differs
between them (f7206 / f7235, f8072 / f8034, ...), as the script's notes
already recorded for the screen (f7220/f7480 white in mGBA only). The
audio check compares those first claps and flags dingbat, whose clap is
180 frames earlier.

**Why the randomness differs.** EWRAM 0x02000000 counts the game's frames
(the main loop's passes) and 0x02000008 is its random seed, stepped every
pass. Read every frame of the replay in all three (the second reference's
driver now has `peek` for work RAM and I/O, below):

| lag frames (V-blanks without a pass) | f1-f6264 | f6264-f6913 (dialogue) |
|---|---|---|
| mGBA | 74 | 18 |
| second reference | 76 | 24 |
| dingbat, all four configs | 78 | 25 |
| dingbat `-d:CONTENTION=false` | 77 | 24 |
| dingbat `-d:BRANCH_COMMIT_WAIT=false` | 77 | 25 |
| dingbat, both off | 77 | 23 |

Every second A press in the dialogue opens a new text box, and that pass
overruns a frame in all three; in dingbat and the second reference it
overruns by one more. So the seed (and the frame count the lightning cycle
is keyed to) falls out of step in all three emulators, and the seeds at
f6900 are three different values. dingbat is with the second reference
here, not the outlier.

**Where the cycles go** (dingbat-bios-nowl vs mGBA traces, the two frames
of the text box at f6429-f6430): mGBA ends the second frame with 15.4k
cycles idle, dingbat spills ~16k into the next. The largest items:

| | dingbat | mGBA | evidence |
|---|---|---|---|
| a 0x800-halfword DMA3 to VRAM 0x0600D000 in active display (V-count 84-93) | 11752 | 8202 | 8204 with `-d:CONTENTION=false`: the renderer's VRAM contention, console-mapped (`contmap.s`, section 29); neither reference models it |
| 0x080015BC -> 0x08001528 (a tile lookup, 1033 calls), per call | 198 | 190 | the difference is all in the returns: `pop {r4-r7}; pop {r1}; bx r1` with the stack in IWRAM (sp 0x03007DD4) is 18 cycles in dingbat, 12 in mGBA, though five IWRAM loads, two internal cycles and the 4 + 2 refill of the branch to ROM are 13 on the bus alone (WAITCNT 0x4017) |
| other Thumb ROM code with data accesses (0x08013Bxx, 0x0802B6xx, 0x08000Axx) | ~+12k together | | the same class: section 29's "mGBA prices data accesses under the prefetcher below the bus floor" |

**Who is right.** The audio itself is not in question: the register writes
match and the difference follows the flash. On the lag, the console has
answered the mechanisms dingbat charges more for: `slotexec.s` (section 22)
with the prefetcher on, hardware = dingbat on all twenty single gamepak
opcodes (loads and stores to IWRAM/EWRAM among them), mGBA misses nine; the
VRAM contention is `contmap.s`'s map. The multi-register load case (the
`pop` above) is the pending `slotbranch.s` question of section 29 (rows
`ldmia IWRAM 2 regs` / `3 regs`: dingbat 19 / 20, mGBA 18 / 18); running
`python3 tools/hwlink/slotbranch.py` with the SP on the link settles it, and
no new probe is needed for this game. Even if it came out mGBA's way, the
lightning would still not be reproducible: the second reference, which
lags like dingbat, flashes at frames of its own.

**How it was found.** Replay the frozen script with a per-frame `peek`
(play the steps, hook every frame), diff RAM to find the frame counter and
seed, compare lag per span, then `trace` both emulators across one text
box and sum cycles per routine. The second reference's `peek` reads work
RAM and IWRAM from the core's save-state copy and I/O through its peek
calls; with a peek every frame its audio stays byte-identical to a run
without. The knob variants (`CONTENTION`, `BRANCH_COMMIT_WAIT`, both) also
show how chaotic the schedule is: their thunder lands at f7000, f7000 and
f7140 (the last one matching the references by chance), from lag changes
of one or two frames.

## 32. Lunar Legend: the load screen reads differently, and it is not the save, 2026-10-02

**Symptom.** All four dingbat configs fail the cross-load check: "mgba save
in dingbat: checkpoint load_file differs from the references reading the
same save (mgba=MAJOR, nba=MAJOR)", the same for the second reference's
save. Play is IDENTICAL; dingbat's and mGBA's battery files are
byte-identical (EEPROM 8 KB), the second reference's differs in 23 bytes.

**Not the save.** Every reader shows every save the same way: at
load_file the four dingbat configs hash 3FD1E88F for all three files,
mGBA ABA41A9B for all, the second reference F4EADD89 for all. The
difference is the [load] run, not the file. The checkpoint is
`compare=text` over the rotating globe of the file menu, and OCR reads
dingbat as "LOAD | Burg | 10:000 | DATA | 2:HO" and both references as
"LOAD | 01:LV | Burg | 000:01 | 2:HO DATA" (similarity 0.66 = MAJOR). The
pixels are the same menu with the same text (LV 1 Burg, 000:01, NO DATA);
the globe and Nall's cursor are one animation step apart.

**Why one step.** With a battery file present the game reads the whole
EEPROM at boot (f6-f21: ~1030 calls of the read routine at 0x080567F0,
each a 17-halfword address DMA and a 68-halfword read DMA, from Thumb ROM
code at WAITCNT 0x4314, prefetch on). A call costs 4167 cycles in dingbat
and 4096 in mGBA; the last one ends 170.5k cycles into f21 in dingbat and
88.1k in mGBA, and from there the game is a frame behind: its post-load
burst runs at f27 (mGBA f26), the title's 4-frame animation steps at f35,
f39, ... (mGBA f34, f38, ...), the globe's 8-frame steps likewise. In
[new] (no battery file, no EEPROM read) dingbat matches mGBA frame for
frame to f560 and after that differs only by one 5-bit step on the fading
globe (colour-effect rounding; the second reference rounds differently
again: its background is 1,2,5 where both others have 0,2,5).

**Where the 71 cycles go** (per call, dingbat minus mGBA, from `trace`;
the interrupt path in between costs a few cycles less in dingbat):

| | per call | rule |
|---|---|---|
| six PC-relative literal loads (`ldr rX,[pc,#n]`, e.g. 0x08056776, 0x08056780, 0x08056788, 0x08001292) in the DMA helper, run twice | ~+44 | the opcode fetch after a gamepak data load is nonsequential (N 4 vs S 2) and the load's I cycle fills nothing: alyosha prefetcher_branch_thumb_2, hardware-verified, failed by both references (the Harvest Moon rule of section 29) |
| the address-bit loop 0x08056826-0x08056838, 14 iterations, an `ldrb` from a cartridge table each | ~+28 | the same rule, +2 an iteration |
| the two EEPROM DMAs | +4 | 176 and 686 cycles in dingbat, 174 and 684 in mGBA |

The 64-bit assembly loop (0x0805686C-0x08056880, IWRAM `ldrh`) costs the
same in both. `-d:BRANCH_COMMIT_WAIT=false -d:CONTENTION=false` leaves the
first divergence at f34.

**Status: no change.** The references' prefetcher, as in section 29; a
user importing an mGBA or second-reference save into dingbat gets the
same file menu as from dingbat's own. The script's note says so.

## 33. Yu-Gi-Oh! - The Eternal Duelist Soul: the title a frame late after the boot load, 2026-10-02

**Symptom.** `title` ([new]) and `continue_title` ([load]) are DIFFERENT in
all four configs; the references are pixel-identical there. The script's
note had dingbat's green grid "offset by about one pixel and differing on
every row". Section 29 left it untraced ("first difference f32").

**f32 is not where play parts.** The fades from f32 (f32-43, f166-177,
f215-229, f352-366, f400-414, f537-551) differ from mGBA by at most one
5-bit step (452 px; blend rounding), and the second reference leaves mGBA
there by 2-3 steps (1323 px) and a frame early. f552-f643 are identical
again. Play parts at **f582**: from there dingbat's IWRAM at frame f+1 equals
mGBA's at f (the RNG word at 0x03000040 and the frame counters at
0x03004890, one step behind) with nothing different before. HLE and
official BIOS are identical for 1000 frames.

**The loop.** f575-582 is a boot load whose hot loop (0x0807517A-0x080751DA,
Thumb ROM, WAITCNT 0x4014, prefetch on, 8192 iterations) stores a halfword
to OBJ VRAM (DISPCNT 0: no contention) and then tests four bytes loaded
from EWRAM, each `ldrb`, `cmp`, mostly-taken `beq`. **72.6 cycles an
iteration in dingbat, 64.8 in mGBA**, 65.6k cycles over the loop: an EWRAM
`ldrb` plus its `cmp` is 6-7 cycles against mGBA's 4, though the EWRAM
byte read alone is 3 plus the load's I cycle -- the `slotexec.s` rule of
section 29 (EWRAM data access from gamepak code with the prefetcher on,
console = dingbat). mGBA reaches the idle loop (0x08075D8E) 55k cycles
before the f582 V-blank; dingbat 21k cycles after it.

**On the title** dingbat[f] = mGBA[f-1] except 304 px: the grid scrolls a
pixel a frame (a one-frame lag is ~13k px), and the emblem's flame, which
wobbles during the logo, comes to rest on another frame of its animation
(2 px right; x centre 120.1 against 118.1 on both references), so no
offset matches exactly. [load] boots the same way with any save (mGBA's
included: f728-f918 differ, f919 on identical), so `continue_title` is the
same lag, not the save. **Status: no change**; the references' cost of the
loop is below the console's.

## 34. Mario & Luigi - Superstar Saga: Bowser on another idle pose, five main-loop counts behind, 2026-10-02

**Symptom.** `07_mark` (f20257, a battle with Bowser) is DIFFERENT in all
four configs: the same battle on every emulator, with Bowser and Mario on
other idle-animation poses (diff box 54..209 x 48..155, 1298 px against
mGBA). The references themselves disagree at 06, 11 and 15-19; at 07 their
difference happened to fall under MINOR.

**The counter.** Counting only pixels more than one 5-bit step apart,
dingbat matches mGBA to f17826; the poses part from the battle flash at
f17828 (the second reference is a frame behind mGBA there and on its own
pose phase). The battle animations run off the game's main-loop counter
(IWRAM 0x03000368), not its V-blank count (0x0300036C). At f17600, screens
still identical, the V-blank counts agree and the main-loop counter and
the task timers tagged TIME/FLDM/BEVS/EVTS (0x03002150, 0x03002210,
0x03002548, 0x0300257C) are all exactly **5** lower in dingbat. Loading
mGBA's f17700 state and poking only 0x03000368 to dingbat's value makes mGBA
draw the battle exactly as dingbat for the next 239 frames (0 of 239 frames
more than a step apart; 163 of 239 without the poke).

**Where the five went.** dingbat's main loop misses a V-blank that mGBA's
makes at f3829, f3964, f5025, f5054 and f10335, all scene loads. At f3828
(traced from both emulators' states; no input in the stretch) dingbat runs
86,733 instructions, mGBA 88,451, and in f3829 mGBA finishes the iteration
before the V-blank and dingbat does not: over f3827-3828 dingbat spends
28.5k cycles more in gamepak code (net 14.6k behind once its 12.6k fewer
halted cycles are counted). The gap is spread over many ROM functions, not
one loop; e.g. the first 24 instructions of 0x0801E68C cost 78 cycles in
dingbat and 60 in mGBA, which charges its register pushes to the IWRAM
stack and `ldr`s below the bus floor -- section 29's pricing again.

**Status: no change.** A checkpoint on a battle's idle animation judges the
main-loop phase, which here follows the references' cheaper gamepak code;
the script's note says so (a still screen would be a steadier checkpoint).

## 35. Advance Wars: first-boot flash writes finish instantly, and the menu scroll is a frame out of phase, 2026-10-02

**Symptom.** At `02_mark` (f3932, the Field Training menu) dingbat's
scrolling emblem background is one scroll step ahead of both references
(~4.4k px more than a step apart, all on the background; dingbat[f] =
mGBA[f+1..f+2] there). The references differ from each other only at the
cursor arrows (~250 px) plus blend rounding. All four configs alike;
`-d:CONTENTION=false` / `-d:BRANCH_COMMIT_WAIT=false` change nothing. **Not
section 29: dingbat is early, and the cause is the flash chip.**

**Mechanism.** On first boot (no save) the game fills a 4 KB flash sector
(0xF000) one byte at a time from f28, polling the chip after each byte
through its status routine in IWRAM (0x03007A4C). dingbat's flash
(`storage/flash.nim`, Panasonic 0x1B32) has no busy state: a program lands
at once, so the first status read already returns the written byte --
~885 cycles a byte, done at f41. mGBA keeps the chip busy for three more
calls of the status routine: ~1119 cycles a byte, done at f45; the second
reference finishes between the two. The game's frame counter (0x03004358,
+1 a frame) therefore starts at f53 on dingbat and f56 on mGBA (3748 on
dingbat, 3745 on mGBA at f3800), and the menu background (scroll at 0x03001E44/0x03001E50)
steps every second frame on that counter's parity: a frame after mGBA's
until the screen change at f3727 zeroes the scroll, a frame before after it,
which the diagonal wipe shows from f3736. The save and the play are
otherwise the same.

**Check.** A scratch build where status reads after each byte program
report busy for T cycles (DQ7 inverted, DQ6 toggling, **DQ5 = 0**: the game
reads DQ5 as "time limit exceeded", and a DQ7-only model hangs it on a white
screen; first poll ~418 cycles after the write, then every 127): T = 500
gives counter start f55, 560-650 f57 (still the opposite parity), **700
gives f58 = mGBA's parity**, the scroll matches mGBA frame for frame
(f3725-3734) and `02_mark` differs only at the cursor arrows, as the
references do from each other. So mGBA behaves as if a byte program takes
roughly 670-800 cycles (40-48 us).

**Status: needs a measurement.** Byte-program and sector-erase times are
unmeasured in dingbat; both references model a busy time and disagree on
how long. A busy model (program, and probably erase and chip erase, with
the DQ7/DQ6/DQ5 status above) belongs in `flash.nim` with the value from a
real flash cart (time a byte program by polling DQ7 from IWRAM with a
timer, per chip ID), not from a reference. Until then Advance Wars stays a
frame out of phase; any game that writes flash on first boot or while
saving and paces itself by the poll count can shift the same way.

**Datasheet search (2026-10-02): no usable timing, core unchanged.** dingbat
identifies as Panasonic MN63F805MNP (ID 1B32h, 64K; Advance Wars is a 64K
cart) and Sanyo LE26FV10N1TS (ID 1362h, 128K). Neither part has a public
datasheet: no hit on alldatasheet, datasheetarchive, onsemi (Sanyo's
successor) or a general search; the only sources name the parts and IDs
(<https://reinerziegler.de.mirrors.gg8.se/GBA/gba.htm>, gbhwdb cart
entries). GBATEK's "GBA Cart Backup Flash ROM" table
(<https://problemkaputt.de/gbatek.htm>, same in the mgba-emu/gbatek
markdown) leaves the average timings "?,?,?" for both and gives only
timeouts, 1B32h: write 10 ms, sector erase 500 ms, chip erase 500 ms; 1362h:
all "?". Timeouts bound a busy model from above but do not set it. Public
datasheets exist only for chips dingbat does not report: SST's SST39VF0x0
family (DS20005023B,
<https://ww1.microchip.com/downloads/en/DeviceDoc/20005023B.pdf>) gives
byte program 14 us typical / 20 us max (~235 / 336 cycles), sector erase
18 ms / 25 ms, chip erase 70 ms / 100 ms, with Data# polling (DQ7) and
Toggle Bit (DQ6) only, no DQ5 -- while Advance Wars' poll reads DQ5 as a
timeout, so the Panasonic part polls like an AMD-style chip, not an SST one.
Borrowing another maker's timing would be a guess dressed as a spec, so the
value still has to come from a real Panasonic (and Sanyo) cart, as above.

## 36. Super Mario Advance 3: the cart's EEPROM decides 1-1, 2026-10-02

**Symptom.** On the frozen script every dingbat config reaches 1-1 with pink
tulip buds on the first bush where both references show white puffs
(stage_start, f4304), then a Shy Guy at the bush that hits Yoshi (shy_guys,
column_top, below_white_block). The HLE configs fail at stage_start, the
BIOS ones from shy_guys; the references agree with each other. Section 29's
"a frame late" is not the mechanism here.

**Where it starts.** Per-frame hashes plus EWRAM/IWRAM dumps every 50
frames (`peek`) on dingbat-bios and mgba: EWRAM is identical up to the file
menu, and from 1-1's load (f3950-4000) a block of map data at 0x020006C8
holds different decoration tiles, as does a 32-bit word at 0x03006B5C
written during the load. The cause is far earlier: from f89 the boot shows
each screen **5 frames before mgba** (the second reference 5 before
dingbat), and two IWRAM frame counters (0x030000DD, 0x03006B01) carry that
offset for the rest of the run.

**Mechanism.** On a blank cart the game formats its 64 Kbit EEPROM at first
boot: **196 block writes**, each followed by the library's ready poll
(`ldrh 0x0D000000; bit 0`, loop at 0x0812FA68, with a timer-IRQ timeout
flag that never fires here). Instruction traces of the first 90 frames
(`trace`) time every poll from its start to the ready read:

| | cycles a block | x 196 |
|---|---|---|
| dingbat (`EEPROM_SETTLE_CYCLES` 108368 from the last data bit) | 108116 | 21.19M |
| mgba | 114753 (as if 115000) | 22.49M |
| the second reference | ~101000 (boot 5 frames ahead of dingbat) | ~19.8M |

1.30M cycles is 4.6 frames: the frame on which the format ends, and with it
the phase of the counters the game later seeds 1-1's decorations and enemy
from, is the EEPROM's programming time. Built with
`-d:EEPROM_SETTLE_CYCLES=115005` (mgba's figure seen from the poll),
**all four dingbat configs PASS**, pixel-identical to mgba through
below_white_block; nothing else in the run differs that matters.

**Who is right: nobody, for a blank cart.** Sweeping the settle time from
100000 to 118000 in steps of 1000 (stage_start's bush, dingbat-bios):

    100k P  101k P  102k P  103k B  104k B  105k B  106k P  107k P  108k B
    109k B  110k B  111k B  112k P  113k B  114k B  115k P  116k B  117k B  118k B

(P white puffs as the references, B tulip buds as dingbat). The outcome
flips every 1000-3000 cycles a block -- 1-3 % of the programming time, well
inside what an EEPROM's erase/program time varies by between chips and with
temperature and supply. On real carts 1-1's first bush on a fresh save is
not a fixed fact, and the references agree only because 101k and 115k both
happen to land on P. dingbat keeps GBATEK's "ca. 108368 clock cycles (ca.
6.5ms)" (re-derived 2026-09-01, docs/oracles.md); a cart with a save skips
the format and none of this applies.

**Status: no change; a probe for the cart.** `EEPROM_SETTLE_CYCLES` is now
an `{.intdefine.}`, so a measured value can be tried without an edit.
`tests/roms/payloads/eesettle.s` (r0table row `eesettle`, recorded only
when named) times one block write-back on the cart in the SP's slot: boot
the SP holding SELECT+START with Super Mario Advance 3 inserted (multiboot
with a cartridge), install the monitor, `python3 tools/hwlink/r0table.py
--record eesettle`. dingbat predicts n = 0 and 1 108362, n = 2 (the DMA)
848, n = 3 FFFFFFFF on a blank last block. A stable console value near one
of the sweep's P or B bands says what this cart does; a spread across runs
confirms the checkpoint can never be diagnostic. Either way the script
needs a route that does not depend on it (a soft reset after the first
boot's format, or a seeded formatted save), not an emulator change.

## 37. Yoshi Topsy-Turvy: the calibration ball is frame parity, not the sensor, 2026-10-02

**Symptom.** All four dingbat configs fail `confirm` (f1360, "Is the ball
moving the way you want?"): the ball sits still in the middle on dingbat
and has rolled to the right on both references. The tracker blamed the tilt
sensor's resting value; the saves differ in the calibration words (dingbat
0x3A0/0x392/0x392, the references 0xFFF three times).

**The sensor values are not it.** dingbat answers GBATEK's level reading
(X 0x392, Y 0x3A0, bus.nim). mgba with no rotation source reads 0xFFF on
both axes (a sensor pinned at full tilt); the second reference has no tilt
sensor at all and reads the 0xFF of an empty SRAM window, also 0xFFF. The
mgba driver now attaches a level rotation source (mgba's public
`mPERIPH_ROTATION`, zero tilt), so mgba calibrates at its level reading
(0x3A0 on both axes); the second reference cannot be fed one. Neither that,
nor dingbat with X centred at 0x3A0, nor a 0xFFF power-on latch changes the
checkpoint. (Koro Koro Puzzle, the other tilt script, still passes with the
level mgba.)

**Mechanism.** The game's tilt-direction state (0x03001DE0, updated by
0x08001E9C once a logic frame) compares the live X with the right and left
calibrations +-10. Until they are written (zero) it flips 1 <-> 2 every
frame; the drivers cannot tilt, so the calibration stores right = left =
the resting X, the live X sits on both thresholds, and the state freezes at
whatever it was: the references at 1 (the ball rolls), dingbat at 2. RAM
dumps every 5 frames put the flip out of phase between f725 and f730. There
the game unpacks the next screen with an LZ77 decompressor in IWRAM
(0x030000D0-0x030001A6) writing VRAM halfwords and reading its back
references from VRAM, mode 0 with the display on, over four frames:
dingbat spends **12.9k cycles more** than mgba in that code (0.1-0.2 cycles
on each VRAM `ldrb`/`strh`), finishes just after the V-blank where mgba
finishes just before, and starts the next screen one frame later.

**Who is right: dingbat.** The extra cycles are renderer contention, the
console-measured map in contention.nim (contmap.s cells in r0-agb.json;
gbaedge p41 CONTEND2: "+1 per CPU halfword read" in mode 0), which neither
reference models. With `-d:CONTENTION=false` dingbat matches mgba at
confirm and PASSES -- the same shape as section 29's Final Fight One.

**Status: no emulator change; harness input fixed for mgba.** The confirm
checkpoint stays a reference artifact (their missing contention); the tilt
sensor's resting value is not involved. Open on hardware, not needed here:
the ready bit's conversion time and the latch before the first conversion
(dingbat 0, mgba 0xFFF) -- tests/roms/mbprobe payload_tilt.

## 38. Mario Party Advance: the HLE BIOS's copies ignored an EWRAM stack, 2026-10-02

**FIXED** (hle_bios.nim, cpu.nim). Mario Party Advance (U) failed under the
HLE BIOS (`dingbat`, `dingbat-nowl`: `checkpoint comment: MAJOR`) and passed
under Nintendo's (`dingbat-bios`, `dingbat-bios-nowl`). All six emulators
show the same menus at every checkpoint; what differs is the sparkles under
the host's star, which drift across the text field the OCR compares.

**A timer-seeded random number.** Replayed per frame, HLE and official BIOS
hash identically until f938, when the star's sparkle particles come out in
different places, and then for 7359 of the run's 8522 frames. The game's
LCG (0x08072AD0: `x * 0x41C64E6D + 0x3039`, state at 0x0203A4B8) is seeded
at f884 by 0x0800B7F8 from TM0's counter: 0xFEB9 under the official BIOS,
0xFEAF under the HLE. TM0 is m4a's sample clock (prescaler 1, period 1254,
which divides the frame), restarted at f871 by the music player's V-sync-on
routine (0x0806FC4C), which polls VCOUNT until it reads 159 and then starts
the timer. The poll loop samples VCOUNT once an iteration, so where it sees
the edge depends on the loop's phase, and that phase was set by everything
the main loop did earlier in the frame: under the HLE it reached the poll
350 cycles early, a V-count interrupt later caught it 2 cycles out of
phase, the edge fell one iteration later, and TM0 started 10 cycles late.

**Where the 350 cycles went.** Instruction traces of f871 under both BIOSes
(game code zipped, the time offset printed wherever it changes) move only
across SWIs: one CpuFastSet to OAM costs the same, then each CpuSet comes
back 50 cycles early and each CpuFastSet 100. The game runs its tasks on
stacks in EWRAM (0x02036Exx), and the BIOS dispatcher switches to System
mode and pushes {r2, lr} on that stack before every routine, the routines
push their own frames there, and a few spill inside their loops. The HLE's
routine models were fitted with the stack in IWRAM, one cycle a word; in
EWRAM a word costs six. CpuSet's frame is push {r4, r5, lr} (with the
dispatcher's pair, 10 words: 50 cycles), CpuFastSet's push {r4-r10, lr}
(20 words: 100). The OAM copy runs on the IWRAM stack, which is why it
matched.

**The fix: price the stack's region.** `tools/biosdrv/swisp.c` and
`swisp2.c` call every timed SWI from a cartridge Thumb caller with the
System stack in IWRAM and then in EWRAM, at several sizes and stream shapes
and through the validation-skip paths, on the HLE and on the official BIOS
in this core. Counting the official BIOS's stack accesses in each call
(`BD_MEMTRACE`/`BD_MEMREAD`, `tests/biosdrv_probe.nim`) and charging the
EWRAM premium for each reproduces every EWRAM-minus-IWRAM difference to the
cycle. The HLE now charges each stack word's region (`swi_frame`,
`swi_stack_entry`/`swi_stack_exit`; nothing changes for an IWRAM stack):

* the dispatcher's push and pop, 2 words each, for every SWI from Halt to
  SoundBias and MidiKey2Freq (Halt's push in `hle_halt`, its pop at the
  0x170 trap; IntrWait's and Stop's pops after the wake);
* the routine frames, pushed / popped: Sqrt 1/1, ArcTan2, RLUnCompWram,
  RLUnCompVram, Diff8bitUnFilterVram and MidiKey2Freq 5/4+1, CpuSet 3/2+1,
  CpuFastSet, BgAffineSet and LZ77UnCompVram 8/8, ObjAffineSet and
  LZ77UnCompWram 4/4, BitUnPack and HuffUnComp 9/9, Diff8bitUnFilterWram
  and Diff16bitUnFilter 2/1+1, IntrWait 2/2; Div, DivArm, ArcTan,
  GetBiosChecksum and SoundBias none;
* the loop spills: BitUnPack and HuffUnComp spill one word after the check,
  then reload it for every unit the offset is added to (BitUnPack) or every
  leaf (HuffUnComp); RLUnCompVram stores one word and loads two per flag
  byte, stores one per run and loads one per run byte.

After it the HLE equals the official BIOS on all 80 EWRAM-stack calls of
the two probes, as it already did on the IWRAM ones; it does not model the
sound-driver SWIs' own frames (not measured). Mario Party Advance now
hashes identically under both BIOSes on every frame but the first (the
frame the boot skip hands over; Pokemon Mystery Dungeon's differs the same
way), and all four configurations pass, the audio note gone too. Runner
(1433/1443, no row changed) and cycle laws (HLE and official BIOS,
1860/1860) unchanged; `dingbat` replays the Legacy of Goku I and II, Top
Gun - Combat Zones, Pokemon Mystery Dungeon, Fire Emblem: The Sacred
Stones, Circle of the Moon and Banjo-Kazooie scripts frame for frame as it
did before (every frame hash equal; their stacks are in IWRAM), so their
remaining HLE-vs-official differences (Circle of the Moon f5318, Banjo
f1194) are something else.

Also seen, not changed: the validation-skip paths (zero length, or a source
below 0x02000000) run 4-17 cycles short of the official BIOS on every stack,
by routine (CpuSet 6, CpuFastSet 8, BitUnPack 15, LZ77UnCompWram 4,
LZ77UnCompVram 14, HuffUnComp 13, RLUnCompWram 14, RLUnCompVram 17,
Diff8bitUnFilterWram 7, Diff8bitUnFilterVram 14, Diff16bitUnFilter 7): one
`BIOS_CHECK_SKIP_COST` stands for all of them (swisp2.c cases 42-52). And
SoundBias(0) with the level already at 0 is 2 cycles short (swisp.c).

## 39. Rockman EXE 4.5: Mega Man's mosaic is the install bar's dice, and the dice are the boot's EWRAM cycles, 2026-10-02

**Symptom.** At `pet_greeting` (f3624) all four dingbat configs show Mega
Man fully drawn while mGBA and the second reference still show his mosaic
fade-in (the second reference runs on the host clock, so from the PET menu
on its screens are not diagnostic anyway, per the script). Asked: is
dingbat ahead in time, or is MOSAIC latched or applied wrongly?

**Not the mosaic.** dingbat *is* ahead -- mGBA shows at f what dingbat
showed ten frames earlier (f3551-3604) -- but not because anything runs
faster. Copying dingbat's two RNG words into mGBA at f3200 (`poke8` of
0x02003F6C, 8 bytes, and 0x02003C84, 4 bytes) makes mGBA follow dingbat
frame for frame through the install screen and show Mega Man fully drawn
at f3624; VRAM, palette RAM and OAM are then byte-identical at f3502 and
f3600. What is left (an 8-line step of the opening wipe at f3502, one
5-bit step on ~1.2k pixels of the blended PET at f3600-3624) is the game's
frame counter (0x02004B80), one behind mGBA's since f9 -- below.

**Mechanism.** After NAVI SELECT the "NOW INSTALLING..." bar (f3274 on)
advances with random pauses: mGBA's bar holds at 0x20 for nine frames
(countdown at 0x0200F55E), dingbat's does not, and dingbat leaves the
install ten frames early; the PET's mosaic fade-in follows. The pauses come
from a per-frame LCG at 0x02003F6C. It is zeroed when the title loads and
starts stepping at **f476 on mGBA, f477 on the second reference, f478 on
dingbat** (all four configs alike). The script's keys arrive on fixed
frames, so at NAVI SELECT dingbat's LCG holds mGBA's value of two frames
before and throws other dice.

**Where the two frames go** (instruction traces, `trace`, dingbat-bios-nowl
against mGBA):

1. *Boot RAM clear* (0x08000188: `subs; str r2,[r0,r1]; bne`, ARM from ROM
   under WAITCNT 0x45B4 = WS0 3/1, prefetch on). Over IWRAM both take 22
   cycles an iteration; over the 256 KB of EWRAM dingbat takes **26**,
   mGBA still **22** -- the 6-cycle EWRAM word store costs mGBA nothing.
   65536 x 4 = 262k cycles, 0.93 frame: the game's frame counter starts
   f9 on dingbat, f8 on mGBA and the second reference.
2. *Title load*. An XOR pass over EWRAM 0x02000000-0x0200A3F6 (0x08005C80:
   `ldrb; eors; strb; subs; bge`) is **20** cycles an iteration in dingbat,
   **16** in mGBA; a checksum over 0xC7A8 bytes (0x0804AB5C: `ldrb; adds;
   subs; bge`) **16** against **14**. ~270k cycles, the second frame. (The
   sound driver's V-blank code in ROM is ~1.1k cycles a frame dearer too.)

**Who is right: dingbat, as far as the console has been asked.** Section
22's `slotexec.s` on the AGB SP (section 29 leans on it the same way):
EWRAM loads and stores from gamepak code with the prefetcher on cost what
dingbat charges, and mGBA is 4-5 cycles short -- the same gap as both
loops here. And mGBA's 16 for the XOR loop
is under the 18 the ARM7TDMI's own counts give with every fetch served
from a full prefetch buffer (two 3-cycle EWRAM byte accesses, the load's
internal cycle, the taken branch's 4 + 2 refill, one cycle for each other
instruction). The exact cells (3/1 waits) are not in the recorded tables:
an empty-slot probe is only safe at WAITCNT 0 (section 22's rules), so
this game's timing cannot be re-run on the rig as is. **No emulator
change.** `pet_greeting` and everything after it in this script follow
the install's dice; the script notes say so.

## 40. Klonoa: the clouds are the darken rounding, the Vision 1-1 card is the cart's EEPROM, 2026-10-02

**Symptom (curated, from an earlier evaluation).** The New Game screen's
clouds and the Vision 1-1 title card differ on dingbat. The current suite
no longer shows dingbat alone anywhere in this script (every checkpoint
has all six emulators in one group, but the second reference alone at
`vision_map` and `back_to_map`; `new_game` is compare=none, `level_start`
a slip of +3 to mGBA and -2 to the second reference). Both reproduce
frame by frame, as two mechanisms.

**The clouds (f861-1070): rounding, not scroll.** The screen is under a
brightness decrease (mGBA's registers: BLDCNT 0x00D6, BLDY 5). dingbat and
mGBA have the clouds in the same place: all 30k pixels that differ are
dingbat **one 5-bit step darker**, and every differing pair is exactly
`t*11 >> 4` (dingbat) against `t - (t*5 >> 4)` (mGBA) for some t -- the
darken rounding dingbat takes from the SP photographs of `blendprobe.gba`
(`ppu.nim` `blend_colors`, docs/hwprobe-questions.md; an exact capture is
still wanted there). The second reference differs from both by -3..+3 on
~14k pixels (its clouds sit elsewhere). The Vision 1-1 card's fades show
the same one-step darkening (f3230).

**The Vision 1-1 card (f3213 on): the EEPROM's programming time.** From
f3213 dingbat runs two frames ahead of both references (they agree with
each other) through the title card and into the level. Entering Vision
1-1 the game writes 15 blocks of its 4 Kbit EEPROM (f3204-3209), polling
each to ready (0x08051798, `ldrh 0x0D000000; bit 0`, 32 cycles a poll in
both): **108141 cycles a block in dingbat** (`EEPROM_SETTLE_CYCLES`,
GBATEK's 108368 from the last data bit), **114776 in mGBA**. Built with
`-d:EEPROM_SETTLE_CYCLES=115005` (section 36's mGBA figure), dingbat-bios
equals mGBA frame for frame from f3167 and is pixel-identical to *both*
references at f3320 and f3500; the frames that still differ are fade
frames, i.e. the darken rounding above.

**Who is right: the cart.** As in section 36: a block's programming time
is the chip's, varies between parts, and is unmeasured; GBATEK's "ca.
108368" stays. A 4 Kbit cart is a different chip from Super Mario Advance
3's 64 Kbit one, so it gets its own row: `tests/roms/payloads/eesettle4k.s`
(eesettle.s with 6-bit addresses; r0table row `eesettle4k`, cart rows are
recorded only when named). With Klonoa in the SP's slot, booted holding
SELECT+START: `python3 tools/hwlink/r0table.py --record eesettle4k`.
dingbat predicts 0x103 FFFFFFFF (blank last block) or the block, 0x102
00000300, 0x100 / 0x101 0001A74A (108362); mGBA 00000301 and 0001C130
(114992). Never with a 64 Kbit cart inserted. **No emulator change.**

## 41. The PSG envelope restart and master volume: probes built, the SP not heard, 2026-10-02

**Not settled on the console: the Mac's microphone could not be opened.**
Every capture hung without a frame; `AVCaptureDevice.authorizationStatus`
for audio reads *not determined* for this session's process, i.e. macOS is
waiting for someone to answer the microphone prompt. Both probes and their
listeners are ready for the next session that has the microphone (the user
grants it once):

    python3 tools/hwlink/envrestart_listen.py record   # ~30 s
    python3 tools/hwlink/psgvol_listen.py record       # ~20 s

and both dry-run in the emulators (`... emu dingbat mgba nba`).

**1. Does an NRx2 write's extra envelope clock survive a trigger?**
`common/psg_channels.nim` arms `env_extra_tick` when NRx2 takes a running
channel's period from 0 to non-zero (SameSuite `nrx2_speed_change`, CGB) and
`psg_trigger_envelope` does not clear it. The music engine most games use
ends a note with NRx2 = 0x08 and a trigger, then starts the next by writing
an increasing envelope and triggering at once, so in dingbat the new note's
first step comes about 2 ms after the trigger instead of a period later.
`tests/roms/payloads/envrestart.s` plays, on channels 2, 1 and 4, at four
phases of the 64 Hz envelope clock (slots timed on TM2 so every slot starts
at the same frame-sequencer phase): A, NRx2 = 0x09 written to a stopped
channel and triggered; B0, the engine's sequence (0x08 + trigger, 62 ms
later 0x09 and a trigger back to back); B20, the write 20 ms before the
trigger. 6.5 envelope clocks after the trigger a period-0 write of the same
direction freezes the level (nrx2table.s C7 showed that holds on the AGB),
and each note ends in a 203 ms steady tone read against period-0 references
(volumes 4 / 6 / 8 / 10) in the same take. Emulators: dingbat B0 = A + 1 at
every period-1 cell of all three channels, mGBA and the second reference
B0 = A; B20 = A everywhere. **Nothing changed**: the proposed
`ch.env_extra_tick = false` in `psg_trigger_envelope` stays unapplied until
the console answers (if the SP says B0 = A and the CGB is unknown, the AGB
switch is `when PSG_AGB` in that template).

**2. SOUNDCNT_L master volume, V / 8 or (V + 1) / 8, and the PSG : DMA
ratio.** `tests/roms/payloads/psgvol.s` plays 1024 Hz tones only (one
microphone response for all): channel 2 at volume 15 under master 7, 3, 0,
1, 5, 7, then DirectSound A at 100% and 50% fed a full-swing square (16 x
0x7F, 16 x 0x80) at 32768 Hz, twice over. Its dry run found a dingbat bug the
console is not needed for:

* **SOUNDBIAS was taken at half its level.** The bias field is bits 1-9
  (GBATEK: "Bias Level (Default=100h)", the register's 200h), so in the
  10-bit sum it counts twice; dingbat added the field (100h). The DAC's
  0..3FFh was then centred 256 below the sum's zero: a DirectSound channel
  at 100% (an 8-bit sample x4, +-512) clipped below -256, the negative half
  of every peak past -64. The 50% / 100% ratio of the square read 0.67
  instead of 0.50. Games hit it: 30 s of Kirby & The Amazing Mirror's intro
  put 506 output samples on the floor (-256) and none above +364;
  LeafGreen's 722. **FIXED** (`gba/apu.nim`): the bias is the field x2.
* **(V + 1) / 8, unmeasured, applied.** The master volume is the PSG
  block's own NR50, and the GB core scales by (V + 1) / 8 (Pan Docs: 0 is
  an eighth, not silence); the GBA mixer used V / 8. The project's rule is
  that the GBA follows the GB where the SP has not measured otherwise, and
  both references agree with Pan Docs. **CHANGED** (`gba/apu.nim`), marked
  unmeasured in the code; psgvol.s will settle it.

After both, dingbat's DirectSound-100% : PSG ratio (one channel, volume 15,
master 7, PSG 100%) is 4.23 against the second reference's 4.25 (mGBA about
4.1, with a blip resampler's 50% / 100% of 0.60); before, 3.64 with V / 8
and the clip. Predictions for the console: V / 8 gives P3 / P7 0.43, P1 / P7
0.14, P0 silent; (V + 1) / 8 gives 0.50, 0.25, 0.125.

**Found on the way: a prescaled timer read 0 once every 16 frames.**
envrestart.s's first emulator run had its waits on TM2 (prescaler 256)
return early. `end_frame` rebases the scheduler keeping the clock's low 10
bits; a timer whose anchor predated the base had its ticks folded into the
counter, but its anchor kept its offset within the prescaler period, which
could land after the rebased clock. A read in the frame's first few cycles
below that offset took the "not started yet" path and answered the reload.
The frame's length walks the clock's low bits through a 16-frame cycle, so
it came back once every 16 frames, at prescalers 64, 256 and 1024 (games
reading a slow timer right at the start of V-blank). **FIXED** (`gba.nim`
`end_frame`: the anchor goes to cycle 0, the same prescaler period).
`tests/roms/payloads/tmjump.s` polls TM2 across the start of V-blank for 16
frames: the SP reads no jump at any prescaler; the old core 6 at 256 and 30
at 1024. Recorded and frozen (`tests/roms/cyclelaws/tmjump.gba`).

Gates. Timer fix: runner 1433/1443 row-identical; cycle laws 2075/2075 HLE
and Nintendo's BIOS; 22 playtest scripts (Harry Potter CoS to Kirby NiDL,
dingbat and dingbat-bios against mGBA and the second reference) give the
same verdict per game and config as before. Mixer (bias and master volume):
`nimble test_psgagb`, `test_mp2kpass`, `test_silentaudio` pass; runner
1433/1443 row-identical; eight audio scripts (Mother 3, LeafGreen, Golden
Sun, Metroid Zero Mission, Aria of Sorrow, Breath of Fire, Minish Cap,
Metroid Fusion) pass on all four emulators as before, every audio verdict
the same (the two MINOR windows that were there stay one each: LeafGreen
f6390 spectrum 0.38 -> 0.42, Metroid Fusion f23385 level 7 -> 6 dB).

## 42. hdmalag configuration 29: the request that lands in a refill, 2026-10-02

**FIXED** (`REFILL_WINDOW_SPLIT`, cpu.nim `window_refill`, ppu.nim
`start_hblank`). Configuration 29 of `tests/roms/payloads/hdmalag.s` arms
DMA1 (3 words, EWRAM scratch) and DMA3 (302 halfwords of TM0 stamps) on
every H-blank: DMA3's burst ends 3 cycles before the next H-blank's grant,
so the CPU, polling VCOUNT in a `ldrh / cmp / blo` loop from IWRAM, runs 3
cycles a line. The console starts every burst on its H-blank's cycle (first
read at 981 + 1232k, 20 bursts); dingbat started line 143's 2 cycles late,
and the next H-blank found DMA3 still running and dropped it (18).

A trace (`-d:itrace`) showed line 143's request landing at the second cycle
of the `blo`'s refill -- a `blo` whose own fetch the line-142 burst had been
granted at, so its refill ran after both bursts. dingbat charged that refill
as one 2-cycle block with no access end, so the request waited for the next
opcode fetch to end (grant at +3, not +1). Two changes:

* with the DMA access window open, a refill outside the gamepak is two
  fetches, each synced to its end (`window_refill`). r15 moves on after
  each sync, so a burst granted between them still finds the first fetch on
  the bus -- the hdmaphase/hdmaobus cells that pinned
  `DMA_SEES_REFILL_FETCH` all hold (moving r15 first broke 23 of them);
* the window it needed was line 143's, opened by `start_hblank` while the
  bursts ran -- and the line-142 request's `window_closing`, still set
  because no fetch had come between that request and the new window, shut
  it at the `blo`'s fetch. Opening a window now clears it.

Configuration 29's four cells recorded and frozen. hdmalag's other
configurations, slotexec/slotbranch/slotdma (prefetch on and off) and the
alyosha prefetcher ROMs unchanged. Runner 1433/1443 row-identical; cycle
laws 2079/2079 HLE and Nintendo's BIOS; the 22 playtest scripts give the
same verdict per game and config.

## 43. Slot-code ldm and slotdma k = 4-8: the console runs something else, 2026-10-02

No change. Two leftovers from §29 and §26, chased on the SP.

**slotbranch rows 3 and 6** (a 3-register `ldmia` fetched from the empty
slot, home path 22 / 25 on the console where dingbat says 20 / 23): not a
per-run phase. `tests/roms/payloads/slotldm.s` (`python3
tools/hwlink/slotbranch.py --tally --source=tests/roms/payloads/slotldm.s`)
runs the home trial for 2- to 6-register `ldmia` from IWRAM, EWRAM and VRAM
at four one-cycle sled offsets, 24 trials a row:

| registers | IWRAM (dingbat / console) | EWRAM | VRAM |
|---|---|---|---|
| 2 | 19 / 19 x24 | 29 / 29 x24 | 21 / 21 x24 |
| 3 | 20 / 20 x23, 22 x1 | 35 / 35 x7, 37 x17 | 23 / 23 x18, 25 x6 |
| 4 | 21 / 21 x8, 23 x16 | 41 / 41 x9, 43 x15 | 25 / 25 x18, 27 x6 |
| 5 | 22 / 22 x14, 24 x10 | 47 / 47 x4, 49 x20 | 27 / 27 x5, 29 x19 |
| 6 | 23 / 23 x1, 25 x23 | 53 / 53 x11, 55 x13 | 29 / 29 x24 |

Two registers never vary; three and more read dingbat's time or 2 more,
trial by trial (both passes of one run disagree), in proportions that
change between sessions (3-register IWRAM was high in about half its
trials in a session with sled offsets 0-15) and do not follow the sled. A halt to line 100
before each trial (a fixed PPU phase) spreads them wider (5-register EWRAM
47-56). The same loads from IWRAM code (`tests/roms/payloads/ldmvar.s`) cost
the same every time in every region (32 / 7 / 12, as both emulators say),
so it is the empty slot's code fetches, not the loads, and no phase a
payload can set (sled, PPU line) decides it. In
a later session the 6-register EWRAM row read times of 0 and 1 with the
right return address, unexplained. Without a cartridge this is not an
instrument for multi-register loads; no rule, nothing to fit.

**slotdma k = 4-8** (prefetcher off: console 1052, dingbat 1049): at those
phases the H-blank DMA lands in the hop's 5-cycle nonsequential fetch, and
the console's return address reads 08008009 where dingbat's and the
console's own other phases read 08008007 (raw `r0`/`lr` columns of the
payload's block): the forced-nonsequential fetch after the burst floated
`addr >> 1` instead of the `0xFFFF` suffix and the console executed one more
hop -- §22's "chain's raw +5 rows". The emulator image cannot float two
values at one address, so the column compares different programs; the cost
itself (DMA + 2) is §22's and dingbat's. With the prefetcher on the three
one-cycle cells of §26 (k = 0, 12, 13: 1046 vs 1045) are unchanged.

## 44. The HLE BIOS against Nintendo's, frame by frame: RegisterRamReset, frame ends, copies, 2026-10-03

**PARTLY FIXED** (hle_bios.nim, hle_copy.nim, cpu.nim, bus.nim, gba.nim).
Section 38 left Castlevania - Circle of the Moon (`dingbat` and
`dingbat-bios` part at f5318) and Banjo-Kazooie - Grunty's Revenge (f1194)
as HLE-vs-official differences of another kind, and three small gaps.

**A frame-by-frame comparison.** `tools/playtest/hlecmp.py` replays every
ready script's `[new]` timeline in two dingbat configurations (default
`dingbat` against `dingbat-bios`) and compares every frame's hash: per game
the first differing frame, with frame 0 told apart (it is the frame the
boot skip hands over on). Before this section 66 of the 135 scripts hashed
identically under both BIOSes on every frame (88 apart from frame 0).
To find where a game first sees a BIOS call take another time, the
playtest driver gained `rundigest` (per frame: how many instructions ran
outside the BIOS, which PCs in order, and which PCs at which cycle of the
frame; built with `-d:biosdrvtrace`), its `trace` prints each step's
absolute cycle (`gba.rebased`, what end_frame has subtracted since power-on;
tests/biosdrv_probe.nim now uses it too, where its rebuild from frame
lengths went wrong by 1024s after an HLE routine longer than a frame) and
marks the steps that only paid a parked HLE remainder (`R`), and the probe
takes `BD_IOALL=1` to log every I/O store.

**Banjo-Kazooie: RegisterRamReset was 826 cycles long.** Banjo's digests
part at f2: its boot calls RegisterRamReset(0xFD), and the HLE returned 826
cycles after the official BIOS. tools/biosdrv/rrr.c, rrr2.c (every flag
alone, combinations, none, the IWRAM flag; WAITCNT 0 and 0x4317): the
routine always forces blank first, then runs the groups in the order other
I/O, SIO, sound, EWRAM, VRAM, OAM, palette, IWRAM, each a fixed time, and
the times add -- a fixed 135 cycles plus 410, 154, 203, 434240, 64576, 480,
736 and 13168 per group. The old model charged each group the whole call's
overhead (two groups paid it twice, no group not at all: 135 short). It is
now a timeline: each store at the cycle the console makes it (BD_IOALL),
the RAM clears ascending between their first and last store, groups later
by those before them. The stores go through the bus as the routine's do,
which also fixes what it leaves: DISPCNT forced blank even with no flags;
IE, IF, WAITCNT and IME cleared first; KEYCNT untouched; RCNT 0x8000 and
JOYCNT acknowledged; SOUNDBIAS 0x200, SOUNDCNT_H 0x880E, both wave RAM
banks cleared; without the SIO flag the routine's two SIO stores 0x20 low
(0x8000 to 0x04000114, 7 to 0x04000120); r0, r1 and r3 as the routine
leaves them (rrrregs.c). Exact on all of rrr*.c's calls but one: with the
prefetch buffer on at the call, the other-I/O group's call returns a cycle
late. Banjo then hashes identically under both BIOSes on all 16369 frames.

**Frame ends inside a routine.** An HLE routine is one instruction, so a
routine running past the end of a frame carried `step_frame` on with it:
the frame's hash was taken after it, with the next frame's first lines
drawn into it when it ran that far (a boot RegisterRamReset is 1.8 frames:
the frame-0 differences of most games), and the keys for the next frame
came in late. The routine bodies now stop at a frame's end
(`hle_frame_ended`), parked as for an interrupt: the decompressors and
math routines on the halt-resume charge (`hle_park_frame_extra` nets out
the handler-return refill the resume takes back, since no handler ran),
RegisterRamReset on its r0 continuation (bit 30; the resume takes the
second dispatch back, measured from the PPU's line-160 start where the stop
came), the copies in BIOS code (below). rrr4.c, rrr5.c: frame-end resumes
from ARM and Thumb callers in IWRAM, EWRAM and the cartridge, exact.

**The small gaps.** The validation-skip paths now cost each routine's own
time (`bios_check_skip_cost`: CpuSet 32, CpuFastSet 34, BitUnPack 41,
LZ77UnCompWram 30, LZ77UnCompVram 40, HuffUnComp 39, RLUnCompWram 40,
RLUnCompVram 43, the Diff filters 33/40/33; swisp2.c cases 42-52 exact).
SoundBias(0) pays the falling path's 2 cycles with the level already 0
(swisp.c exact). The 4-bit HuffUnComp per-leaf stack reload was right:
tools/biosdrv/huff4.c (4- and 8-bit symbols, two- and four-leaf trees,
IWRAM and EWRAM stacks) is exact on all 16 calls. And the registers the
routines leave, which a game can read after the SWI, now match swisp.c,
swisp2.c and the new swiregs.c: r0/r1 past the source and destination for
the decompressors, filters, BitUnPack and affine sets (the Vram forms count
whole halfwords), r3 = 0x170 where the routine's exit pops it, the last
halfword read for Diff16bitUnFilter, the last output word for HuffUnComp,
the last entry's pa for BgAffineSet, the multiplier for MidiKey2Freq,
0x04000088 and the level for SoundBias, 1 and 0x4000 for
GetBiosChecksum, CpuFastSet's r3 the last burst's second word; r0 past the
header on the skip paths. Diff8bitUnFilterVram with an odd length was 2
cycles long (swiregs.c lengths 1-9).

**Copies taken by an interrupt between instructions.** Contra Advance's
H-blank interrupts fall inside its copies (the merged SWI / interrupt
entry logs of the two runs: entries 23 to 124 cycles apart): an interrupt
inside a CpuSet or CpuFastSet was taken at the end of the whole unit (a
transfer, or an 8-word burst -- up to ~120 cycles late in a CpuFastSet to
VRAM), and
from the caller's code after rewinding onto the SWI, with a fitted
constant for the rest (cpusi.c: a Thumb caller in the cartridge 2 cycles a
preemption short at WAITCNT 0x4317, 2 long at 0x0000; every interrupt's
entry -4 to +7 cycles from the console's). `hle_copy.nim` now runs each
unit as the routine's own instructions with their times (the driver's
`trace` of the official BIOS, a step per instruction: CpuSet's halfword
copy is test, branch, ldrh, strh, add, branch back; CpuFastSet's subs,
ldmia, stmia, branch back), the loads and stores in their instruction, the
boundaries after the loop up to the dispatcher's `msr`, and the loop placed
where the console's starts against the swi (the comment read in the
caller's region moves it: `routine_phase`). A preempted copy parks in BIOS
code with the SWI's frames on the SVC and System stacks, its state in
registers and the PC on a stub-BIOS trap (`COPY_TRAP`) the interrupt
returns to, so the entry and return are the console's by construction and
a save state taken meanwhile resumes it. On cpusi.c (and its WAITCNT 0x0317
and 0x0000 rebuilds), the new cpusi4.c (four caller kinds) and fastsi.c
(CpuFastSet copies and fills to EWRAM and VRAM) every call's time is the
console's and every interrupt is entered on the console's cycle, but for
4 of 3300 entries a cycle or three out. A store to I/O lands a cycle early,
so the DMA it arms starts on the console's cycle (alyosha
timing/dma_from_bios).

**What is left.** `hlecmp.py` over all 135 scripts: the HLE and the
official BIOS now hash identically on every frame, frame 0 included, in
104 games (before: 66, and 88 leaving frame 0 aside; no game that matched
before stopped matching). The 31 left, by first differing frame (frames
differing / compared): Super Mario Advance 3 f171 (2775/5455), Sword of Mana
f222 (36), Rayman Advance f256 (9), Kirby - Nightmare in Dream Land f368
(1), Fire Emblem f389 (1), Super Mario Advance 2 f546 (3), Doom f589
(34), Phantasy Star Collection f635 (1), Medabots AX f996 (2), Final
Fantasy V Advance f1000 (2), Final Fantasy IV Advance f1005 (445), Contra
Advance f1192 (1), Super Puzzle Fighter II Turbo f1276 (6), Fire Emblem:
The Sacred Stones f1313 (8), Top Gun - Combat Zones f1328 (1), F-Zero -
Maximum Velocity f1508 (28), Onimusha Tactics f1863 (2), Kingdom Hearts -
Chain of Memories f1973 (91), Sabre Wulf f2679 (2), Dragon Ball Z -
Supersonic Warriors f2813 (1), Advance Guardian Heroes f3098 (212), Mortal
Kombat - Deadly Alliance f3685 (8), Dragon Ball Z - The Legacy of Goku f3827
(1), Sonic Advance 3 f5189 (2), Castlevania - Circle of the Moon f5318
(700), Street Fighter Alpha 3 f5712 (1), Advance Wars f7865 (2), Advance
Wars 2 f8786 (4), Final Fantasy Tactics Advance f10983 (1), Tactics Ogre
f11428 (1), Castlevania - Harmony of Dissonance f13346 (1). Most surface
in a frame or a few: cycle-level differences that resync.

The ones traced are the decompressors' and the other routine bodies'
(Contra Advance's first difference is still to be traced): they still write their output up front and charge a cost model
that stops on the cycle an interrupt line rises (the console takes it at
the end of the BIOS instruction in progress, 0-5 cycles later), and a DMA
burst inside one stalls the whole model where the console grants it at the
routine's access boundaries and runs part of it under internal cycles.
Castlevania - Circle of the Moon is the second: its f324 LZ77UnCompWram
(5120 bytes from the cartridge, sound FIFO DMA running) returns a cycle
after the HLE's, which moves the phase of its busy-wait loop from there on
(the same stream in a probe: exact without DMA, 1 and 2 cycles long with a
FIFO DMA every 1254 / 777 cycles); the frames part at f5318. Mortal Kombat
- Deadly Alliance's RLUnCompWrams run under DMA too (a few hundred cycles
apart per call). Top Gun - Combat Zones is the first: its fade at f1328
draws tiles a long LZ77UnCompVram has not written yet on the console. The
fix is the copies' treatment for each routine (their instructions' times
from the trace, progressive stores, a BIOS-resident park), with the DMA
grant and internal-cycle overlap inside each instruction on top; an
interrupt arriving in the dispatcher's window before a routine, or in the
return path of the routines other than the copies, is also still taken
after the SWI.

Gates: runner 1433/1443, no row changed (alyosha timing/dma_from_bios
holds through the I/O store's early cycle); cycle laws all hold under the
HLE and the official BIOS (2072/2072 each); every biosdrv probe as before
or better (cpusi.c from 12 off-cycle calls to none); playtest PASS in all
four dingbat configurations for Circle of the Moon, Banjo-Kazooie, the
Legacy of Goku I and II, Top Gun - Combat Zones, Pokemon Mystery Dungeon,
Fire Emblem: The Sacred Stones, Mario Party Advance, Golden Sun and The Lost
Age, Pokemon Emerald and FireRed.

## 45. Gradius Galaxies: black at the first stage, an interrupt return two bytes early, 2026-10-02

**FIXED** (cpu.nim `refill_from_head`). Found by `tools/playtest/inputsweep.py`
(START/A on a fixed beat, ~1600 library titles, dingbat against mGBA): in
Gradius Galaxies (U) the stage fades in, START pauses it, and in both dingbat
configurations (HLE and official BIOS) the screen goes black at f1021 and
never changes again; mGBA and the second reference play on. Regressed with
671d1162 (2026-09-24, the prefetcher running on while the CPU is off the
gamepak).

**Where the CPU went.** From f810 the game's main thread executes the open
bus above the BIOS (Thumb, 0x0000B1F6 upwards to 0xC000, where an undefined
instruction traps to 0x04 and returns there forever); interrupts still run,
so the music driver and the V-blank handler keep going over a black screen.
The way in: a Thumb `bx r0` at 0x080596D8 returns to 0x080003DB (`pop {r0};
bx r0` in a veneer at 0x080003D4), a V-blank interrupt is taken on the very
next boundary, and the handler's `subs pc, lr, #4` lands at 0x080003D8 --
the second half of the `bl` before the veneer's pop -- which jumps to LR +
0x2F6 in the BIOS's unused space.

**Why two bytes early.** An exception return refills from the prefetcher's
buffer when it lands exactly on the head the prefetcher went on at when the
CPU left the gamepak (`refill_from_head`). The return runs in ARM state and
its CPSR is restored afterwards, so the target was aligned as an ARM address
(`and not 3`) unless it matched the head as a halfword. Here the head was
0x080003D8 and the target 0x080003DA: word-aligned it matched, and the
refill took ARM width at 0x080003D8. A return from an exception mode whose
SPSR is Thumb, to an address with bit 1 set that is not the head, can only
be a Thumb return; it now takes the ordinary refill. Every case the change
touches was a wrong address before it, so no timing moves elsewhere: runner
1433/1443 (no row changed), cycle laws hold (HLE and official BIOS,
2072/2072), Gradius Galaxies plays through to the stage with both BIOSes.

Also seen, not changed: the interrupt was taken with r15 still odd
(0x080003DF: `bx` leaves bit 0 in r15 until the next fetch masks it), so
LR_irq was odd; the console's LR is always the halfword address plus 4. Only
a handler that inspects LR could tell.

## 46. Colin McRae Rally 2.0, TOCA, Starsky & Hutch: `movs pc, lr` in System mode restored a stale SPSR, 2026-10-02

**FIXED** (arm.nim `exception_return_restore`). Found by the same input sweep.
Colin McRae Rally 2.0 (U): after the difficulty menu the HLE configuration
soft-resets to the Spellbound logo and the official-BIOS one crashes into a
pale garbage screen, where both references show the Rally Finland stage
screen. TOCA World Touring Cars (E) and Starsky & Hutch (E) hang the same
way. Broken at least since 2026-08-01 (not a recent regression).

**The way in.** The three link an ARM run-time library whose routines
return with `movs pc, lr` -- 26-bit-era style, restoring the flags -- and
the games call them from System mode. Colin McRae's unsigned divide
(0x08000534) returns that way from 0x080007F4 into its signed wrapper at
0x0800081C, and dingbat came back in **Thumb** state: it ran the wrapper's
ARM words as Thumb, reached a Thumb veneer region with the stack one frame
off, and a function returned to a pointer in a data table (0x082B3BB0).
The official-BIOS run then executed that table, whose stores overwrote the
IRQ handler in IWRAM, and jumped to 0x01A4903C; the HLE run reached a soft
reset.

**Why Thumb.** User and System mode have no SPSR. An S-bit write to r15
(`movs pc, lr`, `subs pc, lr, #n`, `ldm {..., pc}^`) restores CPSR from
`cpu.spsr`, and in those modes that field held whatever `switch_mode` last
copied there: a snapshot of some earlier CPSR, here a Thumb one. MRS already
reads the CPSR in place of the SPSR in User and System mode (alyosha psr);
the restore now does the same, so the S bit changes nothing there and the
write is a plain branch. The payload `tests/roms/payloads/sysmovs.s`
(r0table `sysmovs`, six cells: `movs pc, lr`, `subs pc, lr, #0` and
`ldmfd sp!, {pc}^` in System mode with Z and C set, with and without a
Thumb SPSR left in IRQ mode) asked the AGB SP, which answers 0x6000029F in
every cell: ARM state, System mode, and the flags as they were before the
instruction -- a movs or subs result's own flags do not stick either. So a
data-processing S-bit write to r15 in User or System mode now puts back the
pre-instruction CPSR before the restore (`arm_data_processing`). dingbat
(both BIOSes) matches all six cells; mGBA keeps the ALU's flags on the
movs/subs cells (0x2000029F); dingbat answered 0x0000021F in every cell
before the fix. The row is frozen as a cycle law (tests/roms/cyclelaws/
sysmovs.gba).

All three games now play on with both BIOSes, matching mGBA at every
screenshot of the sweep's 3000 frames.

## 47. Semi-transparent OBJ under an effects-off window

**FIXED** (ppu.nim `composite_span`). Reported on Pokémon MurfGreen, a
minimal hack of the FireRed decomp: the overworld fog was fully opaque,
where on hardware it is see-through and the ground shows. At that point
DISPCNT = 7F60 (mode 0, BG0-3 and OBJ, WIN0 and WIN1 on), WININ = 1F1F (all
layers, colour-effect bit clear in both windows), WINOUT = 0101, BLDCNT =
1E40 (alpha, no 1st targets, 2nd targets BG1-3 and OBJ), BLDALPHA = 080C.
The fog is OAM sprites in OBJ mode 1 (semi-transparent), priority 2.

**What was wrong.** A semi-transparent OBJ pixel alpha-blends with a
2nd-target layer below it even where the window's colour-special-effect bit
is clear. Everything else still needs the bit: BLDCNT 1st-target alpha,
brighten and darken, and the semi-transparent OBJ's own fallback to
brighten/darken when the layer below is not a 2nd target. The span
compositor sent every span whose window had the bit clear to the opaque
loop (`can_blend = effects and ...`), so a semi-transparent OBJ there never
blended. Now an effects-off span clears its 1st-target selections and, when
the line has a semi-transparent OBJ pixel and BLDCNT names any 2nd target,
runs the blend loop, which then searches for a bottom layer only under a
semi-transparent top. Spans with no semi-transparent OBJ pixel (nearly all)
still take the opaque loop.

`tests/roms/semiobjwin.gba` (source `semiobjwin.s`) asks the question
directly: one BG as the 2nd target, striped with the backdrop (not a
target); WIN0 over the middle third with the effect bit clear, effects on
outside; in each of three bands (BLDCNT alpha, darken, none) a
semi-transparent OBJ straddles WIN0's left edge and a normal OBJ, with OBJ
as a 1st target, its right edge. Both reference emulators draw the same
frame, pixel for pixel in 5-bit colour:

| cell | alpha band | darken band | none band |
|---|---|---|---|
| semi OBJ, effect bit clear, over the 2nd target | **alpha** | **alpha** | **alpha** |
| semi OBJ, effect bit clear, over the backdrop | plain | plain | plain |
| semi OBJ, effect bit set, over the 2nd target | alpha | alpha | alpha |
| semi OBJ, effect bit set, over the backdrop | plain | darkened | plain |
| normal OBJ (1st target), effect bit clear | plain | plain | plain |
| normal OBJ (1st target), effect bit set, over the 2nd target | alpha | darkened | plain |
| normal OBJ (1st target), effect bit set, over the backdrop | plain | darkened | plain |

dingbat drew plain in the three bold cells (1536 pixels) and matched
everywhere else; it now matches the references on every pixel.

In the 135-game suite one checkpoint moved, in all four dingbat
configurations: Castlevania - Aria of Sorrow's `castle_corridor`, where nine
pixels of a semi-transparent sprite went from (11,9,17) to within one step
of both references' (28,22,27) (the one-step differences left are alpha
rounding, where dingbat follows the SP-measured blendprobe values). Every other dingbat checkpoint hash
is unchanged; pass counts are unchanged.

**Lineage.** The rule was known and fixed once: Crab, dingbat's
predecessor, gained it on 2021-02-03 (805e860, "sprite blending overrides
effects being disabled, fixes emerald cave/fog/underwater"). Crab's
2022-08-11 blending rewrite (a353dce) dropped it; that rewrite was matched
against tonc's `bld_demo`, which uses no windows, so nothing it was checked
against could notice. The Nim port (bf71c126, 2026-02-24) inherited the
rewrite's rule, and the span compositor (cfa15a42, 2026-07-27) kept it,
faithfully specialising the wrong behaviour.

**Why nothing caught it.** No test ROM or suite case dingbat runs combines
a window with its effect bit clear and a semi-transparent OBJ (no runner
row changed with the fix). `tests/ppucomposite_test.nim` compared
the compositor with itself under configurations that must agree (fast path
against general path, one loop against another), so a rule wrong in every
path passed all of it. And the 135-game playtest has no fog, cave or
underwater scene among its checkpoints; the references only cross-check
dingbat where the scripts go.

**Prevention.**
- `dingbat/semiobjwin` in the test runner ("GBA - Other test ROMs") scores
  the probe's frame against `tests/roms/semiobjwin_expected.png`, the frame
  both references draw.
- `tests/ppucomposite_test.nim` test 10 checks every pixel of 96 fuzzed
  frames (BG modes 0-5, random windows, effect bits, BLDCNT, coefficients,
  OBJ modes, debug masks; half of them with every effect bit clear and
  semi-transparent sprites over 2nd targets) against a plain per-pixel model
  of the colour-effect rules with none of the span machinery, and requires
  the semi-transparent-under-a-clear-bit path to be hit. Against the old
  compositor it fails (65613 pixels differ); against the fixed one it
  passes.

## 48. The HLE BIOS's routines as stub-BIOS code, step by step: decompressors, copies, IntrWait, the math, RegisterRamReset, 2026-10-03

**FIXED** for the routines below (hle_unc.nim, new; hle_bios.nim, hle_copy.nim,
bus.nim, gba.nim). Section 44 left the decompressors writing their output up
front and charging a cost model: a DMA burst inside one stalled the whole
model where the console grants it between the routine's own accesses and
runs part of it under the internal cycles (Castlevania - Circle of the
Moon's sound FIFO inside its cartridge LZ77UnCompWrams, a cycle or two a
call), an interrupt was taken on the cycle the line rose rather than at the
end of the BIOS instruction in progress, and a frame drawn mid-call showed
output the console had not written yet (Top Gun - Combat Zones' fade). The
copies ran instruction by instruction but charged constants (no DMA
overlap), and every SWI took an interrupt arriving between the dispatcher's
`msr` and the routine after the SWI.

**The routines run as BIOS code.** The stub BIOS now holds one `swi 0` per
step of each routine (0x0C00-0x152F ARM, 0x3A00-0x3FFF Thumb), and the HLE
executes a step by its address: the CPU fetches it (one BIOS cycle) and its
body makes the console instruction's accesses and internal cycles through
the bus calls the core's ARM and Thumb handlers make, in their order -- a
load its access then an internal cycle, a store its access, a register
shift or a multiply its internal cycles, a taken branch the refill -- then
steps or branches to the next. So the CPU's own loop runs the routine:
interrupts are taken at its instruction boundaries and return into it, DMA
requests are granted between its accesses and run under its internal
cycles, renderer contention meets each access when it is made, the frame
loop stops between two steps, and a save state holds a routine in progress
in its registers, its stack frames and r15. The SWI's exception entry, the
dispatcher (its pushes on the SVC and System stacks, its read of the swi's
comment byte in the caller's region, the `msr` into System mode with the
caller's I bit) and its return (the pops, `movs pc, lr`) are steps too, so
an interrupt in the dispatcher's window is taken there. Each routine's step
sequence is the console's: tools/biosdrv/steptrace.nim logs every
instruction the official BIOS executes in this core inside a probe's calls
(its cycles, its accesses and their cycle in the step, the DMA in it), and
the HLE's steps follow those kinds and that order; the comparison is
tools/biosdrv/stepcmp.py, which lines the two traces up step by step,
ignoring only the BIOS addresses. Nothing of the console's code is in the
stub; the labels are hle_unc.nim's own.

Covered: IntrWait and VBlankIntrWait, Div, DivArm, Sqrt, ArcTan, ArcTan2,
CpuSet, CpuFastSet, GetBiosChecksum, BgAffineSet, ObjAffineSet, BitUnPack,
LZ77UnCompWram/Vram, HuffUnComp, RLUnCompWram/Vram, the Diff filters,
SoundBias, MidiKey2Freq and RegisterRamReset (which clears each group
through a tail call into CpuFastSet, as the console's does). Halt and Stop
keep their models (Halt already parked in stub code and took the window's
interrupt), the sound driver too. With a BIOS image mapped (hle_after_bios)
these SWIs now run the image's own routines.

**What the console does that the HLE did not.** The probes for the step
order also compare output and registers, and found:

- LZ77 and RL runs are copied whole: a header length that ends inside a
  back-reference or a run still writes all of it (up to 17 or 129 bytes
  past the end; r1 ends past them) -- tools/biosdrv/uncedge.c.
- LZ77UnCompVram reads a back-reference's byte from the destination with a
  halfword load at an even distance from the destination pointer, so a
  distance-1 reference at an odd position reads VRAM the routine has not
  stored yet, and from an odd destination the loads rotate (uncedge.c,
  uncalign.c). The HLE decompressed into a buffer and gave the "right"
  bytes.
- The Thumb routines (RLUnComp, the Diff filters, CpuSet's word path) take
  their header with a load that does not rotate: a stream at an odd
  halfword reads its header from the word below. Mortal Kombat - Deadly
  Alliance keeps its RLUnCompWram streams there; the HLE's rotated header
  gave it a length of 0 (a skip) or 0x1F00 where the console reads 0x3000
  (its frames had parted at f463 with the first build of this section).
  The ARM routines' header loads do rotate (uncalign.c).
- HuffUnComp: the bitstream is read where the tree size puts it, off a word
  boundary if so, with rotating loads (the HLE aligned it); each symbol is
  shifted in at the top of the output word (a 4-bit leaf keeps its low
  four bits), the word starts at 0, and it is stored and kept shifting
  every (size & 7) + 4 leaves -- the count the routine spills and reloads
  at every leaf; the HLE assumed 32 / size (tools/biosdrv/huffsz.c, every
  size nibble).
- BitUnPack does not mask a unit plus the offset to the destination width:
  an overflow carries into the next unit (uncedge.c).
- HuffUnComp and BitUnPack keep their spilled word above sp (sp moved down
  two words), RLUnCompVram its two words above sp too (three words): a
  handler pushing on the System stack cannot clobber them. The first build
  of this section spilled below sp, and Dragon Ball Z - The Legacy of
  Goku's first HuffUnComp ran ~10 times too long once its handler's push
  overwrote the count (found by tools/biosdrv/uncregs.c, which logs the
  registers each interrupt finds: steptrace.nim BD_IRQREGS=1).
- RegisterRamReset's sound group keeps SOUNDBIAS's level bits and clears
  the amplitude resolution (it reads the register first; the HLE wrote
  0x200) -- tools/biosdrv/rrrsb.c; its wave RAM clears are eight words from
  0x04000090, FIFO A and B included; the other-I/O group also stores 0xFF to
  0x04000410.
- IntrWait halts at least once even with the flag already set; without the
  discard its first HALTCNT store goes through the dispatcher's r12 into
  the BIOS (no halt); r12 = 0x04000000, r4 = 1, r2 the mirror and lr the
  console's 0x344/0x34C are there while it waits; a nested IntrWait nests
  through the stack -- all by construction now (tools/biosdrv/iwait.c).
- The registers each routine leaves are the console's (uncfin.c, swiregs.c,
  swisp2.c): LZ77UnCompVram leaves its pending halfword in r3, which Mortal
  Kombat's next SWI found there; LZ77UnCompWram and LZ77UnCompVram keep the
  console's own register for every value (uncregs.c: the registers an
  interrupt finds match), the other routines their own within the ones the
  console uses.
- The affine sets' multiplies take the scales (x, x, y, y) and, in
  BgAffineSet, -cx, cy, -cx, -cy as the multiplier, the last four
  multiply-accumulates (tools/biosdrv/affset.c); MidiKey2Freq's two long
  multiplies take the fine pitch in the top byte and the interpolated
  multiplier (m2ftime.c).

**Probes.** Every step of every call equal, HLE against the official BIOS
(stepcmp.py; the IRQ frame's register values and the System stack's
pushed return addresses aside): unct.c, uncfin.c (registers), uncdma.c
(LZ77/RL/Huffman/Diff with the sound FIFO's DMA at 1254 and 777 cycles a
sample, and a Timer 1 interrupt every 3000 cycles on top), uncedge.c,
uncalign.c, uncregs.c, huffsz.c, iwait.c, affset.c, sbias.c, mathset.c
(Div, DivArm, Sqrt and ArcTan over 50 inputs), atan2.c (every ArcTan2 path),
rrrsb.c, and the existing cpusi4.c, fastsi.c, lz77t.c, lz77i.c, huff4.c,
m2ftime.c, midikey.c, rrr.c, rrr2.c, rrr4.c, rrr5.c, rrrregs.c, swisp.c,
swisp2.c, swiregs.c. compare.py over all 88 probes: every one as before or
better -- lz77t.c from 11 marks and 484 cycles off to none, rrr.c from 3
calls a cycle off to none, swiregs.c from 1 to none.

**Games.** `hlecmp.py` over all 135 scripts, HLE against the official BIOS
on every frame: 135 of 135 equal on every
frame after f0, from 104 before this section (118 with the decompressors
alone; Mortal Kombat - Deadly Alliance and Final Fantasy IV Advance, a
frame each, came equal with the later rounds -- LZ77 in the console's registers
(Mortal Kombat's next SWI read LZ77UnCompVram's r3), then the affine sets,
the math routines and RegisterRamReset on the engine; Contra Advance's one difference was RegisterRamReset, two
cycles short at frame 2, now exact).

Tools: tools/biosdrv/steptrace.nim (step traces; BD_SWIWIN=1 brackets a
game's SWIs, BD_IRQREGS=1 the registers each interrupt finds, BD_WATCHREG
one register's writers), stepcmp.py, the playtest driver's `swilog` (each
SWI's start, length and arguments) with tools/playtest/swicmp.py (the first
call that differs between the two configurations) and
tools/playtest/digcmp.py (`rundigest` compared: the first frame the game's
code ran on other cycles).

Gates: the runner 1433 of 1443 as before; the cycle laws 2085 of 2085
under the HLE and under the official BIOS; the save-state compatibility
guards; the playtest suite 122 of 135 with the same 13 failures as before
(Pokemon Mystery Dungeon - Red Rescue Team, Pokemon Pinball: Ruby &
Sapphire and Breath of Fire II failed once with the machine's load near
250 -- empty screen reads, the official-BIOS configurations as well -- and
passed on a rerun).

## 49. Harry Potter CoS, Starsky & Hutch: an 8 KB save for a 4 Kbit EEPROM came back 512 bytes, 2026-10-03

**FIXED** (gba.nim `new_storage`, storage.nim `battery_file_bytes`). The
cross-load step of Harry Potter and the Chamber of Secrets (a known FAIL
since the suite began) and of the new Starsky & Hutch (E) script booted the
second reference's save -- an 8192-byte file, the size it writes for every
EEPROM -- in each dingbat configuration, and the game's own write during
`[load]` made dingbat rewrite the file at 512 bytes: the chip bytes intact,
the file shortened. mGBA left the same file 8192 bytes long; the harness
counts a shortened battery file as a dingbat problem (an extended one is
fine).

dingbat sizes an EEPROM from the game's first command (the DMA length), not
from the file, because emulators write 8 KB files for 4 Kbit chips; the
buffer starts at 8 KB and shrinks to 512 bytes on a 4 Kbit command. The
file's bytes past 0x200 are now kept as loaded (`eeprom_file_tail`) and
written back after the chip's, so a 4 Kbit game never shortens a file it was
given; a 512-byte file stays 512 bytes and a 64 Kbit game is unchanged. With
an RTC trailer the trailer still follows the chip data (8192 + 16). Guards:
`nimble test_gbartc` (the "4Kbit part" cases now expect the file's own
length). Starsky & Hutch and Harry Potter pass their cross-load matrices on
all four configurations.

## 50. Sleep mode: six games never woke from Stop, 2026-10-03

**FIXED, hardware row pending** (interrupts.nim `check_interrupts`,
keypad.nim `stop_key_condition`). Found by the deep input sweep
(`inputsweep.py --pattern deep`: its save attempts open the pause menu and
pick entries, and many pause menus end in Sleep). dingbat went black and
silent for good where both references played on:

| game | sleep routine | dingbat before |
|---|---|---|
| Ghost Rider (U), Catwoman (U), Action Man - Robot Atack (E) | KEYCNT 0xC304 (IRQ, AND, L+R+SELECT), Stop; on waking KEYCNT 0xC000 (IRQ, AND, no key) and Stop again | woke on L+R+SELECT, then stayed in the second Stop |
| Cabbage Patch Kids - The Patch Puppy Rescue (U), Puyo Pop Fever (E), The Santa Clause 3 (U) | IE = keypad + gamepak, KEYCNT 0x8304 (AND, L+R+SELECT, **IRQ enable clear**), Stop, then wait for every key released | never woke |
| Powerpuff Girls - Him and Seek (U) | KEYCNT 0xC304, one Stop | woke on L+R+SELECT (correct) |

The references are no guide: both treat SWI 3 as a halt that the next
interrupt ends, so they never sleep at all (the sweep's flags were the
references playing on under a sleeping console). GBATEK: Stop "can be
terminated by ... Joypad, Game Pak, or General-Purpose-SIO" interrupts, as
far as enabled in IE -- it does not say whether the wake needs KEYCNT's IRQ
enable or a fresh edge.

The games say what the console does. The 0x8304 sleepers (three publishers)
can only wake if the key condition ends Stop without bit 14; Ghost Rider's
second Stop can only return if the condition ends Stop as a level: its
IRQ handler acknowledged the first wake's IF before the 0xC000 store
(traced: IF 0x0018 at the store), and nothing about the condition changes.
dingbat now ends Stop while IE's keypad bit is set and KEYCNT's key
condition holds (AND over the selected keys, vacuously true with none; OR:
any), ignoring bit 14 and raising nothing; the keypad IRQ itself stays as
it was (an edge of the condition with bit 14 set). Key changes during Stop
re-check. All seven games now sleep, wake on L+R+SELECT and return to their
menus; none wakes before the keys (checked by replaying each to its
sleep, 60 frames idle, then L+R+SELECT).

Probe: `tests/roms/payloads/keyirq.s`, r0table row `keyirq` (KEYCNT stores
with nothing held: the vacuous AND, a rewrite of a matching value, the
enable bit, a level after the acknowledge; emulators answer dingbat
03FF0309, mgba 03FF0101/0100, the second reference 03FF030D). Its ad hoc
Stop cells (arguments 0x80000000, 0x80000001: Stop under KEYCNT 0xC000 /
0x8000 with IE = keypad) settle the model directly -- dingbat returns
0x57000000 from both; a console that disagrees hangs and needs a power
cycle. Runner 1433/1443, cycle laws hold with both BIOSes.

## §51. Sonic Advance: a reference that never boots is no witness for the save, 2026-10-03

**Symptom.** All four dingbat configs failed the save cross-load: "nba save
in dingbat: battery file changed by booting, nba left it unchanged" (the
first 4 KB of 64 KB).

**Cause: the harness.** The second reference never gets past the grey bars
of section 1 in this game, so its [new] run writes nothing and its save is
blank (64 KB of 0xFF). A blank FLASH sends the game to the language screen,
and picking a language writes the "PIRO" header block -- in dingbat and in
mGBA alike, byte for byte (both write the same 4086 non-0xFF bytes). The
second reference "left it unchanged" only because it was still on grey
bars. `cross_load_verdict` now counts a reference as keeping a save only
when that reference shows its own save the way another emulator does (the
`healthy` test it already used for the reverse direction); otherwise the
rewrite is the game's own and is a note. Sonic Advance passes in all four
configs; no other game in the corpus had this problem.

## §52. The stale-driver check refused the train's second run of base, 2026-10-12

**Symptom.** The train's verdict on the SingleStepTests CPU fixes
(716b7589) listed ten games as noise: on the second run of base every
dingbat configuration was "play FAILED", status PASS->FAIL. Mario Party
Advance appeared only there, so its change was never reported.

**Cause: the harness (1239267b).** The stale-driver check compared the
driver's modification time with the newest source file. The second run of
base copies base's cached driver (`copy2`, old mtime) into a fresh
checkout of base, whose files all carry the checkout's time, so every
driver was refused. The references still replayed, the rows had results,
and `denoise` took the failures for base's own nondeterminism; all 849
cells of the noise ledger came from that run.

**Fix.** build.sh stamps each dingbat driver with a sum of the sources it
is built from (`<binary>.srcsum`: src/dingbat/gba, src/dingbat/common, the
driver, nim.cfg, build.sh -- the GBA core imports nothing else, so a DS
commit no longer makes bin/ stale); emu.py refuses a driver whose stamp is
not the checkout's, and the train copies the stamp with a cached driver
(a cached driver without one is rebuilt). `denoise` no longer learns
anything from a configuration the rerun could not play where the baseline
did. The ledger's poisoned cells were removed. Diffing the two baselines
directly (7dc82b46 -> b98294aa) shows what was hidden: ten games changed,
all neutral (nine audio; Doom and Starsky & Hutch checkpoints too; Mario
Party Advance's self-load cells), no pass/fail flip. The corpus stands at
129/140 in every dingbat configuration.

## §53. Shin Bokura no Taiyou: the sensor notice a phase behind, the second reference on the host clock, 2026-10-12

**Symptom.** Boktai 3's new script (`2651c5e6....play`): at `solar_notice`
(f400, compared at f430) every dingbat configuration is SLIP against both
references (mGBA -16, the second reference -15) while the references are
IDENTICAL to each other. The sun and gauge animation on the boot's sensor
notice runs out of phase; everything meets again at `sensor_setting`.
The sign: dingbat is late. The animation holds each picture for up to ten
frames and the classifier reports the first matching frame of the
reference's window, so -16 is a hold that starts 8 frames earlier in mGBA.

**Two causes, neither in dingbat's core.**

1. **The second reference ran on the host clock (harness, fixed).** The boot
   does a clock-dependent computation behind a black screen before the notice
   fades in. In dingbat-bios that black hold lasts 60 frames at the harness
   epoch (2006-01-01 00:00), 59 at 2006-06-11 and 53 at the host time of the
   run (2026-10-12 22:00), and the second reference, which ignored `--rtc`,
   showed 53. With `--rtc` set to the host time, dingbat-bios and the second
   reference draw the same picture on 448 of the first 450 frames (frames 0
   and 4, below, differ); at the epoch dingbat is 7 frames behind it. Its
   driver now honours `--rtc`: the core has no clock setting and its static
   library imports only `time` and `localtime` for a clock, so the driver
   defines `time()`, which the linker binds ahead of the C library's, and
   answers the frozen epoch (the host clock without `--rtc`, as before).
   At the epoch the second reference's black hold is 60 frames and it
   matches dingbat-bios on 448/450 frames again. It was also
   the train's main source of noise (a reference playing a `[load]` cell
   live read the wall clock); scripts that wrote "the second reference runs
   on the host clock, its screens there are not diagnostic" (Boktai 2,
   Rockman EXE 4.5) no longer need to.
2. **mGBA under-charges the boot (no change).** At the same epoch mGBA
   reaches the sun animation 8 frames before dingbat (f169 against f177):
   the black hold is 58 frames against 60, the grey hold that follows 84
   against 86, the fade-in 22 against 26 -- the second reference, on the
   same clock, is 60 / 86 / 26 like dingbat. All three holds are CPU-bound
   loading code in Thumb ROM with the prefetcher on (WAITCNT 0x4014, then
   0x4314: WS0 3/1, so N = 4 and S = 2 cycles a halfword); per frame both
   emulators spend the same ~280.9k cycles and the same ~148 cycles per
   interrupt, but dingbat runs 3.7% fewer main-thread instructions. Traced
   in both (`trace`, main thread only, cycles per loop iteration):

| loop | dingbat | mGBA | floor |
|---|---|---|---|
| `__muldi3` (0x0824AC74, libgcc soft-float, 4 calls per double multiply from 0x08249B3C; stack in IWRAM), call + return | 155-159 | 145 | 155 |
| soft-float `unpack_d` (0x082496A0), call + return | 156-161 | 150 | -- |
| EWRAM table scan (0x08218CEE: `ldr` from 0x0203xxxx, two taken branches) | 34 | 30 | 33 |
| EWRAM scan (0x08218D72) | 26 | 22 | 26 |
| byte copy IWRAM -> EWRAM, 8 x `ldrb`/`strb` unrolled (0x08219EC4) | 73 | 48 | 67 |

   The floors use nothing but GBATEK's wait states (EWRAM at 0x0D000020:
   3 cycles a byte or halfword, 6 a word) and the ARM7TDMI's own cycle
   counts (LDR 1S+1N+1I, STR 2N, STM n+1, LDM-with-PC n+1 plus the refill
   N+S), with every opcode fetch the prefetcher could have buffered taken
   at one cycle:
   * `__muldi3`, from entry to the taken `bcs`: `push {r4-r7,lr}`, four
     `str` and an `ldr` from the stack are 19 cycles of the CPU's own before
     the literal `ldr r0,[pc,#92]` can be fetched (the ROM alone would have
     it at 16); the literal is a 32-bit ROM read (6) and an internal cycle,
     the opcode after it nonsequential (4), then 20 halfwords at S and the
     branch refill (6): at least 77, dingbat's figure; mGBA's is 73. From
     the branch target to the return: the gamepak delivers no halfword
     faster than S = 2 cycles, the 22
     halfwords up to the `pop {r4-r7,pc}` take 44, the pop's five loads and
     internal cycle 6, the refill 6: at least 56 (dingbat 58, mGBA **50**,
     under the bus's own bandwidth). The caller's 8 instructions: 22 in
     both.
   * The byte copy: eight `ldrb` from IWRAM (3 each) and eight `strb` to
     EWRAM (1 + 3 each), four ALU instructions and the taken `bgt` (1 + 4 +
     2): 67 with every fetch from a full buffer. mGBA charges 48. dingbat's
     73 adds the prefetcher stopping at eight halfwords and the fetch after
     the drained buffer being nonsequential (alyosha prefetcher_full_*,
     which dingbat passes and mGBA fails, section 29) and the S-rate fetches
     right after each refill.
   * The scans: an EWRAM word load is 1 + 6 + 1 whatever the prefetcher
     does, and the fetches right after a refill come at S; mGBA's 30 and 22
     are the ROM fetches alone, as if the load were free. dingbat's extra
     cycle in the first is the taken branch waiting out the halfword in its
     final cycle (`BRANCH_COMMIT_WAIT`, console-measured with
     `slotbranch.s`, section 29).

   This is section 29's "mGBA prices data accesses under the prefetcher
   below the bus floor", in the class the console has answered for dingbat
   (`slotexec.s`: EWRAM loads and stores from gamepak code with the
   prefetcher on, console = dingbat, mGBA 4-5 short; multi-register loads
   from the slot cost dingbat's time or 2 more, section 43). Weighted by how
   often each runs over frames 6-30, the soft-float routines account for
   the whole 224k-cycle gap of the black hold (`__muldi3` 75k, the
   0x08249500-0x082497FF fp-bit code 100k, the rest of 0x08249xxx 48k).
   fp-bit calls `__muldi3` with both high words zero (0x08249B20-0x08249B6C),
   so each of its two multiplies with a 32-bit operand has a zero on the
   other side: which Thumb register sets the early termination (dingbat:
   Rd, the data sheet's `MULS Rd, Rs, Rd`) only moves internal cycles from
   one multiply to the other.

**Not the sensor, not the RTC protocol.** The notice's animation is the same
sequence of pictures with the same hold lengths in all three emulators; only
its start moves. The sensor calibration screen is IDENTICAL in all three, as
in the Boktai 1 and 2 scripts. Before the black hold, frame 4 carries a tear
(white above, black below) at line 95 in mGBA, 99 in dingbat and 102 in the
second reference: the boot's first writes, where the references disagree
with each other too; frame 0 is the frame the BIOS skip starts in (at line
126), drawn differently above that line by each driver.

**After the fix** (dingbat-bios, mgba, second reference; the RTC scripts
before -> after):

* Shin Bokura no Taiyou: `solar_notice` against the second reference
  SLIP(-15) -> IDENTICAL; against mGBA SLIP(-16) as before (mGBA against
  the second reference is now SLIP(+2), so mGBA stands alone); play SLIP ->
  IDENTICAL; the second reference's save differs from dingbat's in 12
  bytes, was 34; its cross-loads of every save now show `title` and
  `data_select` as dingbat does. Its `first_gameplay` stays 29 frames off
  both dingbat and mGBA, as before (not chased).
* Boktai: `solar_setting` SLIP(+6) -> IDENTICAL, `time_setting` MAJOR (the
  host date on screen) -> IDENTICAL; save 23 -> 8 bytes apart.
* Boktai 2: `solar_notice` MINOR -> IDENTICAL, `region` SLIP(-12) and
  `title` SLIP(+7) -> IDENTICAL; `gameplay` IDENTICAL -> SLIP(-23), the
  second reference alone (mGBA agrees with dingbat). With the old driver on
  the same build: `region` SLIP(-26), `title` SLIP(-8), `valley_path`
  MAJOR, `gameplay` IDENTICAL -- three host-clock differences for one.
* Rockman EXE 4.5: from the PET menu on the second reference now sides
  with mGBA (`save_screen` identical to mGBA's, was MAJOR against both);
  `pet_greeting` is still the `@known` of section 39.
* Pokemon Ruby, Sapphire, Emerald: every checkpoint verdict as before.

All PASS; harness unit tests 36/36. The train keys the reference binaries
on the drivers' sources, so its next baseline plays the references live once.
Scripts' comments updated (Boktai 2, Boktai 3, Rockman EXE 4.5), and
the README's driver notes.
## §54. Zelda II: the HLE Halt came back 9 cycles early, and once slept through an interrupt, 2026-10-12

**Symptom.** Classic NES Series: Zelda II was the last corpus game whose
HLE (`dingbat`) and official-BIOS (`dingbat-bios`) runs differed: video,
saves and checkpoints equal, audio off by up to 172/32768 around f2346 and
f2900-2908. `swicmp.py` put the first differing BIOS call at #101 (f53): a
Halt from IWRAM (ARM, IRQs on), woken by timer 1, 81913 cycles on HLE
against 81922; the HLE then gained an extra Halt call about every 45
frames.

**Cause 1: the return path.** Per-instruction traces of both runs agree up
to the dispatcher's return at 0x170. There a DMA0 burst (5 cycles) and the
sound FIFO's DMA2 burst (4) were granted, and the official BIOS's `pop
{r2, lr}` waited for both (0x170 -> 0x174 took 13 cycles, not 4). The HLE's
return was a trap at 0x170 that charged the 16-cycle path as internal
cycles and read the frames untimed; a burst runs under internal cycles, so
both were free. It happens whenever the game's FIFO request lands in those
16 cycles.

**Cause 2: one interrupt sample.** With the return fixed, call #4517
(f1582) parted: the HLE's Halt lasted 4622 cycles, the BIOS's 79077. Timer
1's interrupt was recognised at the boundary after the routine's `bx ip`
(0x16C), after the dispatcher's `msr` and before the HALTCNT write. The
console takes it there and its write then sleeps; the HLE sampled the line
once, 18 cycles after the comment read (`HALT_MSR_AT`), missed it, and at
the write took it as "recognised by the write" (no sleep), coming straight
back.

**Fix.** The Halt runs the console's code from the dispatcher's `msr` on.
`hle_halt` charges the dispatch to the `msr` (`HALT_MSR_START` = 10 cycles
after the comment read; the official BIOS's trace: read ends 114, `msr`
fetched 124), opens the interrupt gate as `msr` does, and parks at 0x164 on
the stub's copy of the routine (push, `bx ip`, the HALTCNT `strb` that
halts in mmio.nim); the stub's 0x170-0x188 now hold the dispatcher's
return as instructions, with a trap at 0x184 (`cpu.hle_halt_return`) for
the one pop that differs because the HLE's SVC frame is three words where
the console's is four (it makes the console's three reads). The modelled
`HALT_MSR_AT`, `HALT_WRITE_AT` and `HALT_BIOS_RETURN` are gone: the write
still lands 25 cycles after the read and the return still costs 16, now
because the instructions do. Zelda II: all 8015 Halt calls of its script
start and last the same on both, and the audio streams are identical. A
scratch probe (a Halt from IWRAM with a timer interrupt landing k = 1..89,
120, 200, 400 cycles after the timer starts, a handler stamping TM0, TM0
read after the return) differed in 7 of 92 cells before (k = 23-24: a
pending interrupt's handler entered 3-4 cycles late; k = 28-32: Zelda II's
case, no sleep) and in none after. No console measurement here: the
official BIOS running in this core is the reference, and the cycle laws
(2085/2085 under both BIOSes) still hold.

## §55. Metroid Fusion hung at boot over Nintendo's BIOS: the HLE Halt parked in the image, 2026-10-13

**Symptom.** With Nintendo's BIOS image mapped and the HLE taking SWIs --
`hle_after_bios` (the apps' "HLE after BIOS", mode 2), or the HLE mode
with a BIOS file given, which every frontend passes when one exists --
Metroid Fusion hung in its 13th frame (f12) and stayed on a dead screen
(PC looping at 0x64 in Undefined mode at f600). Found reading the code
after §54; not in the corpus, which runs the HLE over the stub BIOS or
Nintendo's BIOS without the HLE.

**Cause.** `hle_takes(2)` was true over a real image. Since 45ec2b82
(2026-09-23) the HLE Halt parks in BIOS code -- since §54 at 0x164, after
pushing its own three-word SVC frame {caller CPSR, r12, return}, which
only the stub's return pops (a trap at 0x184 makes the console's reads).
Over Nintendo's image those addresses are the image's own routine and
return, which pops four words: the SPSR from the frame's CPSR word, then
r11 from r12's, r12 from the return address, and lr from the word above
the frame. Metroid Fusion's Halt is a Thumb `swi 2` at 0x0800075A: at the
image's `movs pc, lr` lr_svc = 0, r11 = 0x000001FF, r12 = 0x0800075C (the
return address), sp_svc 0x03007FE4 (its top is 0x03007FE0), and the CPU
went to the reset vector. The routines that hle_unc.nim runs as stub code,
and the sound driver's, already went to the image (`hle_takes` false);
Halt was the one parked routine left out.

**Fix.** `hle_takes` is false for Halt over a real image, so the image's
own dispatcher and Halt run, as they already did for a Halt from IWRAM in
mode 2. Stop keeps the HLE: it parks on the caller's own instruction with
the halt-resume fields and runs no BIOS code (lr_sys = 0x170 is only the
register the console leaves), and its returns came back intact over the
image as over the stub. Over the stub `hle_takes` answers true before it
gets to the change, and mode 1 never asks, so the corpus is unaffected (no
train run). No state
migration: a state parked in the HLE Halt over an image was already on the
path to the bad return.

**Test.** `tests/swihalt_test.nim` (`nimble test_swihalt`, CI) runs
`tests/roms/swihalt.s`: three Halts from ARM ROM and three from Thumb, each
woken by V-blank, then a Stop from each woken by A, checking that each
returns to the next instruction with sp, r10, r11 and the SVC sp intact.
It runs over the stub (HLE), over a 16 KB stand-in image the test writes
(our own SWI and IRQ vectors with a four-word frame, no Nintendo code) in
every mode, and over Nintendo's image in modes 0, 1 and 2 when the file is
there (not in CI). Before: every image mode with the HLE failed all 8 calls
(Nintendo's image: the first Halt went to 0 and the image's boot, SVC sp
0x03007FFC at the end; the stand-in: 0x02CBD5D4). After: all 7 configs
8/8. Ten games over Nintendo's image, 600 frames: Metroid Fusion was the
only one to Halt from ROM; its f600 picture is now the same in modes 0, 1
and 2, and the other nine are unchanged.

## §56. The deep input sweep on the whole pool: no title fails in dingbat alone, 2026-10-13

`inputsweep.py sweep --pattern deep --frames 12000` over the 1625-title pool
(one dump per title not covered by a script: 774 USA, 24 multi-region, 157
Europe, 670 Japan), dingbat against mGBA, then every flagged title rechecked
with the second reference as well. 25 flags:

- **13 sleep**: the game's own sleep option (Stop) reached by the deep
  pattern's menu blocks; the references do not model Stop.
- **12 others, none dingbat's alone.** Rechecked, every one is dingbat
  against mGBA only, the second reference agreeing with dingbat, except
  Pitfall - The Lost Expedition (`garbage` against both: dense jungle
  foliage, the screenshots show normal play). Most are timing forks: the
  same press lands on another frame and the run goes elsewhere (Tiger Woods
  2004, Super Robot Taisen OG, Total Soccer Manager, Extreme Ghostbusters,
  three Yu-Gi-Oh!s, Naruto Ninjutsu Zenkai 2, Pro Mahjong Tsuwamono, which
  dingbat and the second reference play frame for frame). Code Breaker is a
  cheat device with no game behind it. CROSS CHANGE (J): dingbat and the
  second reference reach the story; mGBA alone asks for the "verification
  button" three times after the save-format wait and stays black.

The earlier deep sweep (2026-10-02, USA and part of Europe) had covered
1142 titles; this one ran the whole pool on main 346c741d (the last ~240 on
b7c1e32e). Detectors that cried wolf: `garbage` on busy screens (city
traffic, foliage, football crowds).

## §57. Summon Night - Swordcraft Story 2: the first battle's random numbers part all three emulators, 2026-10-13

**Symptom.** All four dingbat configurations fail on audio alone: "audio
differs from both references in 4.0% of the run, longest 2.76 s from
f24450". Every checkpoint is IDENTICAL, SLIP or MINOR, and the four dingbat
configurations write byte-identical saves.

**Cause: nobody's.** The first battle (the Rampage Rabbit, won by mashing A
towards it) draws on timing-seeded random numbers: the frames are identical
in all three emulators at f13848, and by f13980 the rabbit stands somewhere
else in each. No two emulators share a frame from f14401 to f26400; they
meet again in Master's house about f27000. Ten of the twelve flagged audio
runs fall in that stretch and the other two in the house just after (f29055,
f29310), behind a fight that ended at a different moment in each. Edgar's HP
after it differs (117/120/123), so the saves differ in 6 bytes; every save
loads in every emulator. The audio windows count against dingbat only where
the two references agree, and the music they share keeps agreeing while each
emulator's fight sounds differ. The script carries `@known` for the audio.

## §58. Klonoa 2: Nintendo's HuffUnComp ran fast, a lone gamepak byte load priced sequential, 2026-10-13

**Symptom.** The new Klonoa 2 - Dream Champ Tournament script
(`35c05676....play`) failed `level_start` and `gameplay` MAJOR in all four
dingbat configurations while mGBA and the second reference agreed frame for
frame: from f4454, the white mosaic fade-in to Vision 1-1, dingbat's fade
was a step on, the HUD hearts at another phase and Klonoa ~3 px left of the
references at f5178. Earlier, the title's spinning star ran a frame ahead
and the world map two; the checkpoint windows had absorbed those.

**dingbat was early, by whole frames of the game's own counter.** RAM read
every frame in dingbat-bios and mGBA (the second reference's `peek` lands a
frame off theirs, so it served as a cross-check only): the first
difference that is not the stack is a loader's EWRAM buffers at f738-f789,
filled further in dingbat at every frame end. The game keeps a frame counter
at 0x03004CA4 that stops during loads; it restarts at f789 in dingbat and
f790 in mGBA (the title load), and dingbat is two counts ahead from f1842 on
-- and so is everything phased on it (a 15-step cycle at 0x03005D1A, the
star, the hearts). Entering Vision 1-1 both stop it on the same frame
(f4404, the button press) and restart it on the same frame (f4454), so the
two-count lead shows only from the fade on; Klonoa's position follows,
since the input timeline meets the level's start two game frames later in
the references.

**The loop.** `trace` of f737-f860 in both (dingbat r15 leads by 8 in ARM,
mGBA by 4): the load frames are almost all Nintendo's BIOS, 0x1064-0x10E8,
HuffUnComp's tree walk (ARM, from the BIOS), with the tree and bit stream
in the cartridge; WAITCNT 0x4314 (WS0 N 4, S 2, prefetcher on). Frames
739-746: the same 2,185,8xx cycles each, 1,192,035 instructions in dingbat
against 1,183,313 in mGBA (+0.74%). Every instruction costs the same in
both except the two node reads, `ldrb r6, [r2]` (0x1084) and
`ldrb r10, [r2]` (0x10B4): mGBA 6 cycles every time; dingbat 4 cycles on
34,581 of 305,806 (11%) and 14,058 of 86,296 (16%).

**The floor.** A lone `ldrb` from the gamepak executed from the BIOS:
the BIOS fetch (1), the data cycle, and the internal cycle (1). The ARM7TDMI
data sheet gives a single load's data cycle SEQ low -- a nonsequential
cycle -- and GBATEK's "GamePak Prefetch" says the prefetcher works only with
opcodes fetched from the gamepak: code in RAM or the BIOS that reads data
from it is not affected. So N = 4 at WS0 3 waits, 6 in all, every time:
both references' figure. dingbat's 4 is an S (2).

**Why dingbat took S.** `rom_access_cycles` called a CPU access sequential
when it read `rom_next_addr` (the previous gamepak access + 2, or + 4) and
the prefetch bit was set, however long the CPU had been off the gamepak
bus. A branch out of the gamepak forgets an even `rom_next_addr` -- but an
odd one is how `leave_rom` keeps the prefetcher's head, so it survives:
a byte load at an odd address leaves exactly that. The tree walk's next
node is often the halfword after the last one, two branches later, and
then it went S. Section 20 had already called this rule modelling rather
than measurement.

**Fix.** `bus.nim` `ROM_DATA_NONSEQ` (on): a CPU data access is sequential
only back to back with the previous gamepak access (an LDM/STM's later
transfers), whatever the prefetch bit; opcode fetches keep their rules, and
the HLE BIOS's routines make the same bus calls so they follow.
`-d:ROM_DATA_NONSEQ=false` restores the old rule.

**Evidence and gates.**

* The script, all four dingbat configurations: PASS; `level_start` and
  `gameplay` IDENTICAL to both references (were MAJOR), `title` IDENTICAL.
  dingbat-bios's frames f700-f5300 never differ from mGBA where mGBA and the
  second reference agree (before: from f788 on, and every frame from f4453);
  the HuffUnComp frames now run 1,183,194 instructions against mGBA's
  1,183,313, every instruction of the loop at mGBA's cost, and the game's
  frame counter at 0x03004CA4 equals mGBA's on every frame f1-f4459.
* `tools/knobsweep.py --suite`, the new rule against the old as a knob:
  console cells 4170/4182 and the mGBA suite 0/13996 FAIL under both
  BIOSes for both, nothing moved -- no recorded console cell and no suite row rests on the
  old rule. `test_cyclelaws` (HLE, and real BIOS 2085/2085), `ci_local.py`
  34/34.
* `tests/roms/payloads/romdataseq.s` (r0table row `romdataseq`): from
  IWRAM, `ldrh A`, two NOPs, `ldrh A+2` against `ldrh A+0x100`, and the same
  as `ldrb` at odd addresses, prefetcher off and on. dingbat, mGBA and the
  second reference: every A+2 cell equals its control (0x19, 0x1A at k = 0,
  1); the old rule: 2 less with the prefetcher on (S 3 for N 5). Bit 6 reads
  the halfword back: with the slot empty the float witnesses the access
  itself (`addr >> 1` = 0x2001 for N, 0xFFFF for S; WAITCNT 0 and 0x4000 are
  the safe settings, section 22). **The AGB SP agrees (recorded
  2026-10-13, slot empty):** all 32 timing cells equal their controls,
  0x19..0x1C at k = 0..3 with the prefetcher off and on, and the four float
  cells read 0x2001 / 0x2080 (`addr >> 1`: an N access, never 0xFFFF).
  dingbat and dingbat-bios match 36/36, mGBA 32/36. The row is in
  r0-agb.json and the cycle-law gate (`tests/roms/cyclelaws/romdataseq.gba`;
  2121/2121 cells under the HLE and the real BIOS).

**The train** (`klonoa2`, 161 games): Klonoa 2 fixed (FAIL -> PASS in all
four); 99 games neutral, nearly all on the audio dump's hash alone (any
game whose code in RAM or the BIOS reads the cartridge moves by cycles);
one regression, Castlevania - Circle of the Moon. Two of the neutral ones
looked at:

* **Donkey Kong Country**: `kongo_jungle_map` IDENTICAL -> SLIP(+1) against
  both references (they agree). The old build never differed from them
  where they agree through f4000; the new one from f2753. Split by where
  the code runs, the whole move is the BIOS half of the rule (the other
  half -- DKC's own sample mixer in IWRAM, `ldrsb r1,[r0]; ldrsb
  r2,[r0,#1]` at 0x030039A0, which mGBA charges 6 every time, as dingbat
  now does -- changes no frame). The f2400-f2421 load is two
  LZ77UnCompWram and three HuffUnComp calls; the old rule took S on 8,355
  node reads there, 16.7k cycles under the floor, and finished ~2.5k cycles
  before mGBA. Now every instruction of both loops costs what mGBA charges,
  and the last call returns 7,133 cycles after mGBA's (f2420, line 84
  against 78), a frame late. By region, f2398 to that return: BIOS code
  +4.8k, of which +2.7k is renderer contention on HuffUnComp's word stores
  into VRAM (`streq r3,[r1],#4`: mGBA 3 cycles every time, dingbat 4-8 on
  1,140 of them; console-measured, `contmap.s`), the game's Thumb ROM code
  +1.9k (dingbat's prefetcher rules; the alyosha prefetcher ROMs both
  references fail, section 29), IWRAM code +0.4k; 2.1k of the total had
  accrued before the first call (the same in the old build). So the old
  build matched the references by an under-charge cancelling charges they
  do not make -- section 29's case again; nothing changed for it.
* **Klonoa - Empire of Dreams** (same engine): `level_start` SLIP(+3) ->
  IDENTICAL to mGBA; `vision_map` IDENTICAL -> SLIP(+2), where the
  references disagree with each other (section 40's EEPROM programming time
  still stands between them).

**Castlevania - Circle of the Moon** (`shaft_bottom` MINOR -> MAJOR, all
four): not settled. Its script already records the skeletons' bone
throws parting the emulators (RAM differs from mGBA's from f8 in both
builds; the RNG looks timing-fed). Both builds first differ from both
references where they agree at the same frame, f7306 (a bone at Nathan's
feet); from there the runs fork, and where the old build's fork happened
to rejoin the references at f7990 (MINOR), the new one has Nathan
elsewhere in the shaft. The f7306 divergence predates this change and is
not explained here; no `@known` added. (Settled in the next section: the
skeletons' throws are random draws no two emulators share.)

## §59. Castlevania - Circle of the Moon: the skeletons' bones are an idle-loop RNG, and no two emulators share it, 2026-10-13

**Symptom.** With `ROM_DATA_NONSEQ` (the section above) `shaft_bottom`
went MINOR -> MAJOR in all four dingbat configurations: Nathan knocked
elsewhere in the shaft by a bone, where both references (MINOR to each
other) have him on the bottom ledge. Old and new builds alike first differ
from both references, where those agree, at f7306: a bone at Nathan's feet
in dingbat, none in view in mGBA or the second reference.

**Cause: nobody's; the checkpoint compares random draws.** The f7306
"agreement" is a single frame. Every frame hash f7000-f7989: mGBA and the
second reference agree on 86 of 990 frames (they part off and on from the
first frames, and on nearly every frame from f6879); the old build met
mGBA on 391, the new one on 292. At f7306 the two references happen to
show no bone at all.

**The RNG.** RAM read every frame in dingbat-bios and mGBA, from f0: past
the stack, the one word that differs from f7 on is 0x0200A260. `watchw`
finds its writer:

* 0x080057D4 (Thumb, ROM): unless the pause byte 0x02025FFA is set,
  `[0x0200A260] += 1` (0 skipped). The main loop at 0x080003C8-0x080003D2
  calls it in a loop until the V-blank handler clears the halfword at
  0x02021EA2: once per idle iteration, so the word counts idle loop passes
  since boot.
* 0x080057F8, rand(): `t = s ^ (s >> 16); s += ((s * 0x499602D2) ^ (t <<
  8)) - t`. 0x08005820, rand(n): `(rand() * n) >> 32` through the 64-bit
  multiply at 0x080C37B4.

A Python model of rand() reproduces every jump in the word between two
frames as `R^k(s + a) + b` (a + b = the idle passes on either side of the
work), so each rand call can be read off the per-frame peeks of all three
emulators. On the script's path: 130 calls at f5317-f5329 (the Dracula
scene), five rand(0x1F) at f7043 and the skeletons' rand(0x3D) from f7094:

| | state fed at the skeletons' draws | draws (`rand*61>>32`) | frames |
|---|---|---|---|
| dingbat-bios | 0x5B227822, 0x3F0338D0, 0x53F33F1F | 15, 20, 23 | f7094, f7135, f7177 |
| old build (`-d:ROM_DATA_NONSEQ=false`) | 0x7375BFE2, 0xF751104D, 0x555B3317 | 58, 20, 23 | f7094, f7146, f7188 |
| mGBA | 0x9215FD7D, 0x3B2F502B, 0x08CA3414 | 14, 2, 48 | f7094, f7135, f7173 |
| second reference (its peek, a frame late) | 0x2822870C, 0x9CC90147, 0xE4E2DC0A | 37, 54, 41 | f7095, f7141, f7192 |

Every draw differs between the two references (and between each of them
and both dingbat builds); a draw is one of 61, so any difference in the
state gives another throw. The old build's MINOR was a draw that happened
not to hit Nathan. The change moves the idle count from f401 on (by f5316
the old build counts 765 passes more: its gamepak loads from RAM and BIOS
code were cheaper), so the Dracula scene's draws already differ (old and new
frames first differ at f5318), and every later one.

**Why the states differ: every cycle since boot counts.** Idle passes per
frame (the word's increments) on the boot screen, f9-f40: dingbat 3065, the
second reference 3065, mGBA 3398; in the shaft (f6990): 2543, 2550, 2875.
Until the first draw the word is a pure count. At f5316, the frame before
it: dingbat 11,584,412 passes; the second reference 11,478 more (0.1%: it
starts counting a frame earlier, 879 passes in its first counting frame
where dingbat and mGBA count 1289 and 1292 at f7, and around loads its
frames fall a frame off dingbat's either way; two passes a frame more on
average); mGBA 1,413,981 more (12%). One pass of difference already gives the Dracula scene's 130
draws, and everything after, other values. 0x0202534C records when each
frame's work ends (VCOUNT, read just before the idle wait): 0xB0 in all three
early on, in the shaft 0xD0 in dingbat and the second reference and 0xCC
in mGBA.

**The idle loop's cost**, WAITCNT 0x45B7 (WS0 N 4, S 2, prefetcher on),
`trace` / `pft` of one pass: dingbat 84 cycles, mGBA 76. The bus floor,
instruction by instruction (fetch + data + I; a fetch is 1 cycle only
when the prefetcher had free gamepak cycles to read it ahead):

| instruction | floor | dingbat | why |
|---|---|---|---|
| `bl` (first half) 0x080003C8 | 2 | 2 | the refill before it kept the bus busy: S |
| `bl` (second half) | 8 | 8 | S, then N+S at 0x080057D4 |
| `ldr r0,[pc]` | 9 | 9 | S fetch (right after the refill), gamepak word N+S 6, I |
| `ldrb r0,[r0,#10]` (EWRAM) | 8 | 8 | fetch N 4: after a gamepak load the prefetcher stays stopped through the I cycle (alyosha prefetcher_branch_thumb_2, hardware-verified; section 29), EWRAM 3, I |
| `cmp`, `bne` (not taken) | 2 | 2 | prefetched |
| `ldr r1,[pc]` | 8 | 9 | +1: the prefetcher's halfword in its final cycle has committed and the load waits it out (mGBA suite Timing, ROM prefetch columns) |
| `ldr r0,[r1]` (EWRAM word) | 11 | 11 | fetch N 4 (as above), 6, I |
| `adds`, `str r0,[r1]`, `cmp` | 9 | 9 | EWRAM word store 6 |
| `bne` (taken, +6) | 3 | 3 | the target is the prefetcher's next halfword: the buffer is kept (alyosha prefetcher_branch_thumb) |
| `bx lr` | 7 | 7 | N+S at 0x080003CC |
| `ldrh r0,[r5,#18]` (EWRAM) | 6 | 6 | S fetch after the refill, 3, I |
| `lsls`, `cmp` | 2 | 2 | |
| `blt` (taken) | 7 | 8 | +1: a branch waits out a committed prefetch halfword (`BRANCH_COMMIT_WAIT`, console-measured, section 29 `slotbranch`) |
| **pass** | **82** | **84** | |

mGBA's 76 is 6 under that floor, exactly what the two fetches after the
gamepak loads cost at 1 instead of 4, the prefetcher_branch_thumb_2 law
(a test both references fail, section 29); so mGBA runs 11-13% more idle
passes a frame. The second reference's equal
count on the boot screen (3065 a frame, ending its work on the same line)
says it charges this loop what dingbat does; its RNG still differs from its
first counting frame, and its later frames by a few passes on average
(other code, not traced: its driver has no `trace`).

**Settled, no core change.** A checkpoint after the skeletons' first draw
compares where one-in-61 throws land, seeded by the exact cycle count of
every frame since boot. No emulator is known to match the console's count;
the two references do not match each other's at any frame. The script
carries `@known * checkpoint shaft_bottom:` citing this section; all four
dingbat configurations PASS with it (the other checkpoints unchanged:
`plank_shaft` IDENTICAL to mGBA, `map` MINOR where the references are MINOR
to each other).

Also seen, not chased: f7035-f7041 and f7048-f7054, the white flash
(BLDCNT 0xFF00, BLDY ramping 2..16..2 in mGBA), differ between dingbat and
mGBA in the red channel only, one 5-bit step, with RAM and palette RAM
identical: a brighten-rounding question (section 40 measured darken), not
a game-state difference.

## §60. The corpus plays the HLE over Nintendo's image too (dingbat-hleimg), 2026-10-13

§55's Metroid Fusion hang lived in a configuration the harness never ran:
the HLE BIOS with a real image mapped, which is what every frontend runs
for a player who installed a BIOS file and kept the HLE on. The four
dingbat configurations were the HLE over the stub (no file) and Nintendo's
BIOS alone, so routing between the two (`hle_takes`) was never exercised by
a game.

`dingbat-hleimg` is the fifth: the driver's `--hle` keeps the BIOS file
mapped under the HLE (`new_gba(bios, rom, use_hle = true)`, as
game_load.nim, the wasm and iOS cores do), waitloop skipping on. Its
variant pair is (`dingbat`, `dingbat-hleimg`): a difference there is the
image's own code running where the stub's would. The train compares it
from the first baseline that has it (a configuration the baseline did not
play is skipped, not reported as a change).

Checked on Metroid Fusion: on main both `dingbat` and `dingbat-hleimg` PASS
(IDENTICAL); with §55's fix reverted `dingbat` still passes and
`dingbat-hleimg` fails every checkpoint MAJOR.

## §61. The keypad interrupt reaches IF late on the console: keyirq recorded, 2026-10-13

**MODELLED, one phase question open** (keypad.nim `KEYPAD_IRQ_HOLD`;
rows `keyirq` 3/3 in the cycle-law gate, `keyirq2` 16/18 cells with both
BIOSes, `keyirq3` built). §50's row `keyirq`, recorded on the SP with nothing held
(three runs a cell, all alike):

| argument (bit 1's delay) | console | dingbat, dingbat-bios | mgba |
|---|---|---|---|
| 0 | 03FF0000 | 03FF0309 | 03FF0101 |
| 0x10 | 03FF0002 | 03FF0309 | 03FF0100 |
| 0x1000 | 03FF0002 | 03FF0309 | 03FF0100 |

No emulator has a cell (dingbat 0/3, mgba 0/3; the second reference was
predicted 03FF030D). Every sample `keyirq` takes a few cycles after its
KEYCNT store reads IF bit 12 clear on the console: the vacuous AND (bit 0),
the false -> true write (bit 3), the byte path (bit 8), the enable turned on
over a holding condition (bit 9). dingbat sets IF on the store itself, so
it answers 1 in all four. The bit is set only in bit 1, the re-read after
an acknowledge and 16 or 4096 delay turns, not after 0. So the keypad
condition reaches IF somewhere between about 30 and 100 cycles after the
store (bit 0's store, then its sample, the acknowledge, then the delay).

What the row cannot say:

- **Edge or level.** Bit 1's IF could be bit 0's edge landing after the
  acknowledge or a level setting it again.
- **IF without KEYCNT's IRQ enable.** Bit 4 (0x8000) samples too soon to
  answer. That is the Cabbage Patch Kids question in §50.

`keyirq2` times all of this. TM0 cascaded into TM1 runs from the store
until IF bit 12 is seen (8 cycles a poll, a 2M-cycle timeout). It covers:

- the vacuous AND, three times;
- the enable clear;
- a second wait after an acknowledge, which is a level if it comes again;
- the OR with nothing selected;
- the byte path;
- true pulses of 0 to 64 delay turns, to see whether a short condition is
  caught.

dingbat answers 0x10 (the probe's own overhead: IF on the store), never
again after an acknowledge, and catches every pulse.

The §50 Stop rule stands until this is answered. A late IF may also
change what Ghost Rider's second Stop needs: if the vacuous condition
sets IF late, or as a level, that Stop ends on an ordinary keypad
interrupt.

### keyirq2 answered, and the model

The console, three runs a cell (case 0 nine times):

| case | console | dingbat before | dingbat now |
|---|---|---|---|
| 0, the vacuous AND (x3) | 0x4F (0x46 once in nine) | 0x10 | 0x4F |
| 1, 0x8000: the enable clear | never | never | never |
| 2, again after an acknowledge | never | never | never |
| 3, OR with nothing selected | never | never | never |
| 4, the byte path | 0x46 | 0x10 | 0x4F |
| 5, true pulses of 0, 1, 2, 4, 8 turns (up to ~40 cycles) | never | caught (0x15..0x35) | never |
| 5, pulses of 16, 32, 64 turns (~67 cycles and longer) | 0x55, 0x95, 0x115 | the same | the same |

What this shows:

- **A late edge.** The keypad interrupt is a rising edge, so cell 2 never
  sees it again after the acknowledge. It reaches IF only once the
  condition has held for about 60 cycles. A true condition shorter than
  ~40 cycles is never caught, while 67 or more always is.
- **The cells keyirq could not answer.** keyirq's bit 1 was bit 0's own
  edge, landing after the acknowledge. Bit 4's question is settled: KEYCNT
  with bit 14 clear never sets IF. So the 0x8304 sleepers (§50) can only
  wake through Stop's own key condition, as dingbat already models it.
- **A transient never fires.** A byte-wise KEYCNT rewrite that passes
  through a matching value raises nothing on the console, which is what
  `write_keycnt16` was built to avoid by hand.

dingbat now arms `etKeypadIrq` KEYPAD_IRQ_HOLD = 64 cycles after the
condition turns true. It raises IF then if the condition never turned false
in between. A turn to false cancels the hold and ends the edge. Every hold
from 62 to 68 gives the same cells. With either BIOS, every keyirq cell and
16 of keyirq2's 18 match. Both misses are phase cells:

- **Case 0** answered both 0x46 and 0x4F, so no single value can match it.
- **The byte path** answered 0x46 three times in three, against dingbat's
  0x4F. The code from the store to the poll is the same as case 0's, so no
  fixed hold gives both. The two cases differ only in the cycles before the
  store. That points to a condition sampled on a divided clock, with a phase
  some earlier event sets.

`keyirq3` (r0table row, 32 cells) moves the store one cycle at a time, from
0 to 15:

- **Set A** moves it against the quiet KEYCNT 0 store.
- **Set B** moves everything together.

A latency that cycles with n in set A only would show that the phase comes
from the last KEYCNT write. A latency that cycles in both would show a
free-running clock.

The rest of the console tables are unchanged: 1985/1993 cells for both
dingbat and dingbat-bios. The 8 misses are hdmaobus's six race cells and
keyirq2's two phase cells.

### keyirq3 answered: the phase is not the last KEYCNT write's

The console, three runs a cell, every cell answered one way. The store is
moved n cycles:

| n | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| set A (vs the quiet KEYCNT 0) | 46 | 46 | 4F | 46 | 4F | 46 | 4F | 4F | 4F | 46 | 4F | 4F | 46 | 46 | 4F | 46 |
| set B (everything moved) | 46 | 46 | 4F | 46 | 4F | 46 | 4F | 4F | 4F | 46 | 4F | 4F | 46 | 46 | 4F | 46 |

Set A and set B agree cell for cell, so the quiet KEYCNT 0 store does not
set the phase. It is the store's cycle position counted from the payload's
entry, and it repeats run after run. So something the monitor's call
lands on at a fixed offset clocks the keypad condition.

The early cells (0x46) do not form one run of residues under any period up
to 16. That rules out a single divided clock with a fixed hold. Two
candidates would explain an irregular pattern:

- a slower clock (for example the PPU's dot or line clock), anchored to
  something the payload does not control;
- a sampler whose rate is not a whole number of CPU cycles.

dingbat (a fixed 64-cycle hold) has 16 of 32 cells, the most a fixed hold
can have, since it answers all early or all late. mgba has 0 of 32.

The phase spans one 9-cycle poll. No game can see it, because a keypad
interrupt raised 9 cycles earlier or later changes nothing a frame-based
input routine reads. The model stays as it is. `keyirq2` and `keyirq3`
stay out of the cycle-law gate (`OPEN_ROWS`). If the clock is ever wanted,
the next probe would anchor the store to the H-blank flag edge (as
`halthb.s` does) instead of to the payload's entry.

## §62. Phantasy Star Collection: SLIP(-29) is one field of a two-field screen, and the field is set by a VRAM fill under contention, 2026-10-14

**Symptom.** In the train run 20261013-173431-1c, all five dingbat configs
SLIP at `camineet`, `field_menu`, `save_slot` and `save_name` (mGBA -29 /
-21, the second reference -29). The references are IDENTICAL to each other
there. dingbat-bios shows the gap too, so the BIOS and the HLE are not
involved.

**The 29 frames are a classifier artefact.** From the Master System
emulator's start, the game draws every screen as two fields that alternate
every frame (the line-drop table at 0x08770E5B / 0x08770E5F of section
28). On a still screen the hash sequence is A B A B. A centre frame on the
other field first appears at k = 1 of the reference's 61-frame window, and
`classify` reports the first match, k - 30 = -29. The real offset is odd:
dingbat's frames match mGBA's at offsets ±1, ±3, ... from f2014 to f5170.
At f3550 IWRAM and EWRAM are byte-identical to mGBA's except the stack and
a field flag (0x02020FF0, with 0x02020FFC and 0x0202101E). That flag
alternates 01/00 every frame from **f1692 in mGBA and f1693 in dingbat**
(all configs), and it never holds a frame in either emulator through
f5170. The whole difference is this one field of phase, set at f1693.

**The references only agree on parity.** Matched by frame hash over the
Phantasy Star intro (f1757-f1788), dingbat runs at odd offsets from mGBA
(-3..-7). The second reference runs at even offsets from mGBA (-2..-8) and
odd ones from dingbat (±1). The second reference is several frames from
mGBA here too, but by an even number, so on these screens it looks
IDENTICAL. The checkpoints test the field parity and nothing else.

**What moves f1692 to f1693** (`trace` from f1684, dingbat-bios-nowl
against mGBA, the same instructions in both). Starting Phantasy Star runs
its init in Thumb ROM code with WAITCNT 0x4014 (WS0 3/1, prefetcher on).
The init has two parts dingbat charges more for.

1. *The EEPROM read, f1686-f1690.* The init reads the whole 64 Kbit EEPROM
   (a blank cart): 256 calls of the read routine at 0x0876CC14, each with
   two DMA3 transfers through 0x0876CB94. A call costs **3860 cycles in
   dingbat and 3722 in mGBA**: +138 a call, 35.3k cycles in all. Of that,
   +84 is the 14-iteration address-bit loop at 0x0876CC4A-0x0876CC5C, at
   39 cycles an iteration against 33. The loop body is `strh` to the IWRAM
   stack, five ALU ops, `ldr r0,[r6]` (EWRAM 0x02021418), `ldrb
   r0,[r0,#8]` (gamepak 0x087F2700), `cmp` and `bcc`. mGBA charges the
   `ldr` and the `ldrb` 11 cycles together, fetches included. Their data
   and internal cycles alone are 12 (an EWRAM word is 6, a gamepak N read
   is 4, plus two I cycles). This is section 29's class: dingbat's price
   follows `slotexec.s` (rows 9 and 10, EWRAM and gamepak `ldr` from slot
   code with the prefetcher on, AGB SP = dingbat) and alyosha
   prefetcher_branch_thumb_2 (hardware-verified, mGBA fails it).
2. *A 96 KB VRAM clear in active display.* At 0x0873871C, DMA3 with CNT
   0x85006000 (24576 words, fixed source on the IWRAM stack, into
   0x06000000). DISPCNT is 0x1741 (mode 1, BG0-2 and OBJ, palette RAM all
   black, so the screen shows black). The burst costs **110,465 cycles in
   dingbat and 74,168 in mGBA**. With `-d:CONTENTION=false` it costs
   74,160 in dingbat. The extra 36.3k is the renderer's BG VRAM
   contention. The burst starts at V-count 81 in dingbat (50 in mGBA,
   which reached it earlier) and runs across 79 drawn lines, where affine
   BG2 holds dots 33+4n and 34+4n. The map is console-measured: `contmap.s`
   cells for this scene (0x0D, mode 1 BG0-2) are in r0-agb.json, and
   `dmavram.s` on the SP shows that a DMA burst pays the renderer's dots
   at the model's phases. Neither reference models contention.

mGBA reaches the Master System loop (the first 0x0873C7xx instruction) at
V-count 128, 39.7k cycles before the V-blank. dingbat without contention
reaches it at V-count 159, 1.1k cycles before. dingbat as built reaches it
at V-count 188 of the next frame, so the field flag starts one V-blank
later. Built with `-d:CONTENTION=false`, dingbat-bios-nowl starts the flag
at f1692, and `camineet`, `field_menu` and `save_slot` hash-match both
references. Taking out a measured mechanism matches the references; that
is section 29's pattern.

**Status: no emulator change** (class: the references under-charge per
console-measured rules). Both costs that move the frame are ones the
console has answered: contention for the VRAM clear, and the
slotexec/alyosha prefetcher pricing for the EEPROM loop. Each alone uses up
most of mGBA's 39.7k-cycle margin, and together they cross the V-blank.
The second reference's own even offset from mGBA shows its boot timing is
not mGBA's either, so the two agreeing at these checkpoints is a parity
coincidence, not a timing witness. Two things would make these checkpoints
diagnostic: a script that reaches Camineet from a seeded save, or a
checkpoint that takes both fields (`window` covering an even and an odd
frame and judged as a pair). Both are harness/script work, not core work.
No probe is proposed; no new SP cell is needed for the mechanism.

**Classifier fixed, 2026-10-14.** `classify` now reports the SLIP match
nearest the window's centre, not the first in the window
(tools/playtest/tests/test_classify.py). These checkpoints now read SLIP
±1. They still test only the field parity.

**How it was found.** First, every frame's hash in dingbat-bios-nowl, mGBA
and the second reference over the frozen `[new]` timeline, matched at
offsets in a ±8 window, which showed the parity pattern. Then full IWRAM
and EWRAM dumps (`peek`) at f1616-f3550, which found the field flag and
its first frame with a `peek` every frame. Last, `trace` of f1684 on in
dingbat and mGBA, cycles summed per routine, with the `CONTENTION` knob
toggled on the driver (`-d:CONTENTION=false`, built outside bin/).

## §63. Metal Slug Advance: the landing a frame late, a load that pays EWRAM's wait states, 2026-10-14

**Symptom.** `landing` (f1322, window 30) is SLIP -2 against both references
in all five dingbat configurations. The references agree there (IDENTICAL).

**Where play parts.** The landing scene runs at 30 Hz. From f1212 dingbat's
odd frames show mGBA's picture of the frame before, and the even frames
match. The game's main loop is one V-blank behind; the SLIP -2 is that
phase seen through the 30 Hz picture. Up to f1209 dingbat's EWRAM is
byte-identical to mGBA's every frame, and IWRAM differs only in two stack
bytes. The main loop (wait at 0x08000290, polling a V-blank flag at
0x03000204 that the handler sets, with a missed-V-blank count at
0x03000200) leaves its wait 190 cycles into f1210 and runs a load in Thumb
ROM code (WAITCNT 0x4314: WS0 3/1, prefetch on; EWRAM 3/6, MEMCNT
0x0D000020). Traced from both emulators' f1206 states:

| | dingbat | mGBA |
|---|---|---|
| load ends | f1212, 15,159 cycles after the V-blank | f1211, 8,165 cycles before it |
| cycles / instructions | 576,728 / 178,561 | 553,441 / 175,408 |
| main threads identical for | 174,532 instructions | |
| behind mGBA where they part | 14,610 cycles | |

They part where the late core is already past the V-blank. The main loop's
check at 0x080002E8 sees the V-blank flag in dingbat only, and runs the
sound mixer one more time (8.7k cycles). To be on time, dingbat would have
to charge at most 8.1k more than mGBA over the identical stretch. It
charges 14.6k more.

**What the 14.6k is.** Variant builds, from the same state:

- `-d:CONTENTION=false`: no change.
- `-d:ROM_DATA_NONSEQ=false`: no change.
- `-d:BRANCH_COMMIT_WAIT=false`: 1.3k sooner, still 13.9k late.
- EWRAM at 2 cycles a halfword (scratch): still late, 9.7k.
- EWRAM at 1 cycle a halfword (scratch): on time, 2.5k before the V-blank.
  Nothing else gets there.

dingbat's EWRAM time over the identical stretch is 9.0k cycles. Of that,
2.8k is IWRAM code (block 0x03002700), which mGBA prices the same as
dingbat. The rest, ~6.1k, is EWRAM accessed from the ROM code under the
prefetcher. A typical case is 0x08002ECC's loop: a ROM table, then an
EWRAM pointer load (`ldr r0, [r1]` with r1 = 0x0200E1D0), then `cmp`.
mGBA charges 4.1 cycles for the EWRAM word load and the `cmp` together,
though the word alone is 6 bus cycles. The remaining drift is spread over
ROM functions (pushes and pops to the IWRAM stack, loads under the
prefetcher), as in §29 and §34.

**Who is right: dingbat.** `slotexec.s` (§22; console = dingbat on all
twenty rows at 4/2 with the prefetcher on) in all three emulators:

| row | console = dingbat | second reference | mGBA |
|---|---|---|---|
| 6 `ldmia` EWRAM | 22 | 22 | **17** |
| 9 `ldr` EWRAM | 22 | 22 | **17** |
| 12 `str` EWRAM | 21 | 21 | **17** |

The console pays 5, 5 and 4 cycles over the IWRAM rows. mGBA pays nothing.

An emulator-only timing ROM (Thumb blocks from ROM at 0x4314, TM0 per
block; scratch, not committed) agrees:

- 16 EWRAM word loads: dingbat 131, second reference 128, mGBA **90**.
  The 16-bit EWRAM bus alone needs 16 x 6 = 96 cycles for them.
- 16 `push {r4-r6}` / `pop {r4-r6}` pairs: 150 / 144 / **74**, below their
  96 data cycles.

mGBA's frame rests on prices below the bus floor.

**The second reference is no witness.** Its EWRAM is not mGBA's before the
load. 0x02004640 reads 4A against 4B on every frame from f1040 (the first
peeked) to the load, and 0x0200CEC9 reads 09 against 07 from f1191. Its
pictures part from mGBA's at f604-911 and f1157-1193. So it reaches the
landing's phase by another path, not by a cheaper run of the same load.
On the same timing ROM it prices 15 of 30 shapes exactly as dingbat does.
Fourteen are 3 to 12 cycles a block cheaper, where its full prefetch buffer
keeps refilling. One (0x2ECC's loop rebuilt) is 26 cycles dearer than
dingbat. A scratch dingbat whose buffer keeps refilling matches it on 29 of
the 30.

alyosha prefetcher_full_* and _branch_thumb_4 (hardware-verified; the
second reference fails _full_arm and _branch_thumb_4, §29) say the buffer
stops until the CPU drains it, as dingbat does. In this load the rule is
worth 55 cycles. dingbat-bios slips identically; the HLE is not involved.

**Status: (b), no core change.** The references' frame needs EWRAM data
accesses from gamepak code to be cheaper than the console makes them.

## §64. Mario vs. Donkey Kong: the level-clear tally two frames early, the flash chip's program time, 2026-10-14

**Symptom.** `level_clear` (f7087) is SLIP +2 against mGBA and +1 against
the second reference in all five configurations, with the references
IDENTICAL.

**The references do not agree.** They only show the same picture at the
checkpoint's centre. The tally holds each picture for four frames. Frame
by frame from f6286 every emulator is one frame from the next: dingbat
leads the second reference by one, and the second reference leads mGBA by
one. The game parts the emulators wherever it writes flash:

| when | what is written |
|---|---|
| f0-90 | boot: 6,796 bytes of three sectors |
| f1100-1300 and f1300-1800 | the file |
| f6243 | the level-clear save |

The first frame difference is f99. dingbat and mGBA draw the level itself
frame-identically (f5600-6202). The second reference plays it differently
(its level timer a second lower, per the script).

**The loop.** From f6243 the game programs one 4 KB sector a byte at a
time, under WAITCNT 0x0000 (the countdown at 0x03001F40 runs from 0x1000
to 0). After each byte it calls a status routine it copied to the stack
(0x03007E40: `ldrb r0, [r0]; bx lr`) until the byte reads back. Traced
from both emulators' f6235 states:

| | dingbat | mGBA |
|---|---|---|
| first byte | f6243, cycle 276,114 | f6243, cycle 275,228 |
| last byte | f6264, cycle 239,456 | f6266, cycle 179,640 |
| status calls | 4,096 (one a byte) | 7,972 (1.95 a byte) |
| cycles a byte | 1,427 | 1,552 |
| sector total | 5,862,156 | 6,365,019 |

mGBA's sector takes 503k cycles (1.8 frames) longer. The tally (0x03000C14)
starts at f6265 in dingbat and at f6267 in mGBA. The second reference
identifies its flash as SST (ID D4BF), so the game runs its routines for
that chip there. It writes at dingbat's rate (~197 bytes a frame, against
dingbat's 197 and mGBA's 184) but starts ~0.4 frame later, from its own
level. All five dingbat configurations, Nintendo's BIOS included, write
and slip alike.

**Why: §35's open question again.** dingbat's flash (`storage/flash.nim`)
has no busy state, so a program lands at once. mGBA holds a byte program
~640 cycles once a sector erase has run (below), which costs this game one
more status call a byte. The console's time belongs to the cart's chip, and
nobody has measured it. dingbat's sector ends 41k cycles before its frame
does, so ~10 cycles a byte decide a frame. Each further status call a byte
(~125 cycles) costs about 1.8 frames.

**Probe (designed, not run): `tests/roms/payloads/flashprog.s`**, row
`flashprog` in `r0table.py` (`NEEDS_CART`; kept out of the cyclelaws
gate). Run from IWRAM over the link, with a FLASH cart in the slot, booted
holding SELECT+START as for `eesettle`. It answers:

- the chip ID;
- the bare poll;
- a byte program of the last byte with the value it already holds, so no
  bit can change, at SRAM 8 waits, at WAITCNT 0 (the game's), and with the
  first poll late;
- and, only if sector 15 is blank, a real 0xFF -> 0xFE program followed
  by an erase that restores the sector, plus an erase of the blank sector.

Each answer is in cycles from the store that starts the chip to the read
that returns the data. The emulators' cells:

| cell | dingbat | mGBA | second reference |
|---|---|---|---|
| 0 ID | 1B32 | 1B32 | D4BF |
| 4 / 0x104 poll floor | 34 / 30 | 34 / 30 | 34 / 30 |
| 1 same-value program, 8 waits | 51 | 51 (678 after an erase) | 51 |
| 0x101 same, WAITCNT 0 | 43 | 43 (673 after an erase) | 43 |
| 0x201 / 0x301 first poll late | 147 / 139 | 147 / 139 (679 after an erase) | 147 / 139 |
| 2 / 0x102 real program | 51 / 43 | 51 / 673 (after cell 2's erase) | 51 / 43 |
| 3 / 0x103 erase blank sector 15 | 45 / 37 | 30,046 / 30,037 | 45 / 37 |

On the console, a cell less the floor is the chip's busy time. mGBA's 640
costs the game exactly one more status call a byte, so its first status
read comes 510-640 cycles after the data store, and the checkpoint
follows from the busy time:

| console busy | level_clear frame |
|---|---|
| under ~510 cycles | dingbat's |
| ~640 | mGBA's |
| each further ~125 | about 2 frames later |

SST's datasheet program time, 14 us (235 cycles), would be dingbat's frame.
The Panasonic and Sanyo parts dingbat reports have no public timing (§35).
A measured time per chip ID belongs in `storage/flash.nim`, with Advance
Wars (§35) as its second check.

**Status: (c), no core change.**

## §65. The second reference's pictures are a frame stale: its frames end before the V-blank, 2026-10-14

**Found chasing** Donkey Kong Country's `kongo_jungle_map` and Super Mario
Advance's `quit_to_title` (the next two sections). Both are SLIP +1 against
both references, and the references are IDENTICAL. In both games the
second reference's game state agrees with dingbat's, not mGBA's. Only its
picture agrees with mGBA's.

**Where its frames end.** `peek 4000006` after each `run 1`:

| | frame 0 | frames 1.. |
|---|---|---|
| dingbat, mGBA | VCOUNT 126 | 160, the V-blank start, every frame |
| the second reference, Donkey Kong Country | 225 | 155 at f1-f105, 156 to f1800, 157 to f4100, then 158, 159 by f4700 |
| the second reference, Super Mario Advance | 225 | 142 at f100, drifting to 146 by f2500 |

Its driver runs `kCyclesPerFrame` cycles a call, and the call stops a few
lines before line 160 at a phase that drifts. The core presents its picture
at the V-blank, so after harness frame f the second reference holds the
picture that dingbat and mGBA presented at the end of f-1. Its RAM peeks
are taken 1-18 lines earlier than theirs. For most game code, which has
finished its frame by then, the two read the same.

**Measured.** In Donkey Kong Country, over f1852-2421, f2424-2999 and
f3192-3355 dingbat's and the second reference's IWRAM match byte for byte
at offset 0. In those stretches every frame whose hash places it uniquely
(387 frames) has dingbat[f] = second reference[f+1]; none has offset 0.
The rest are blend-rounding frames that match nowhere.

Across the corpus (train 20261013-173431-1c, 1263 `[new]` checkpoints):

| pair | SLIP +1 | SLIP -1 |
|---|---|---|
| dingbat-bios ~ second reference | 107 (62 games) | 10 |
| mGBA ~ second reference | 97 | 14 |
| dingbat-bios ~ mGBA | 9 | 9 |

**What it changes.** The harness treats a SLIP as a pass, so none of these
fails a game. But IDENTICAL references on an animated screen can mean
"mGBA a frame behind in game state, the second reference at dingbat's frame
with a stale picture". That is the case in both sections below. A
reference pair's agreement is evidence only on still screens, or after a
RAM comparison.

**Status: FIXED in the driver, 2026-10-14.** Measured with a temporary
driver command:

- **Small runs work.** `Run(n)` advances n cycles: 500 moves a line in
  three steps, 1232 one line, and 100,000 from line 181 lands on line 34.
  The earlier `Run(500)` reading was not reproduced.
- **The picture comes late.** The core presents a frame at the end of the
  V-blank, between lines 227 and 0, not at its start.
- **It double-buffers.** The core alternates two buffers. At line 160 the
  buffer being drawn already holds the frame it presents 68 lines later:
  400 of 400 Donkey Kong Country frames are equal.

So `run_frame` (the driver's `run` and `runhash`) now runs whole lines to
159, then 4-cycle steps to VCOUNT 160. It copies the buffer being drawn as
the frame's picture and sizes the frame's audio by the cycles it ran.

After the fix, over Donkey Kong Country's `[new]` timeline to f3400, every
frame ends at VCOUNT 160. In the stretches this section measured (f1852 on),
every uniquely placed frame of the second reference equals dingbat's at
offset 0, where it was dingbat[f] = second reference[f+1].

**The boot lead.** Before f1300 the second reference's pictures equal both
dingbat's and mGBA's one frame later. dingbat-bios and mGBA give the same
counts, 1148 frames at -1, so the second reference runs a V-blank ahead of
both through Donkey Kong Country's boot. The stale picture used to cancel
this, which is why its boot screens looked IDENTICAL to mGBA's.

Its start state does not explain the lead. Its cartridge start is at VCOUNT
225, where dingbat's and mGBA's are at 126, the line Nintendo's BIOS hands
over on (§4). But a driver that ran its own boot of Nintendo's BIOS
instead, starting frame 0 at the hand-over (r15 into the cartridge after
75,983,824 cycles, at VCOUNT 139), made the lead two frames, not none. The
lead is therefore the second reference's own timing in that boot. It is not
corrected, and the experiment was not kept.

**The corpus with the fix** (baseline 20261014, 164 games, against the train
run 20261013-173431-1c). dingbat's runs are unchanged, so everything below
comes from the second reference's new results and the classifier:

| | before | after |
|---|---|---|
| dingbat-bios ~ second reference SLIP +1 / -1 | 107 / 10 | 7 / 37 |
| mGBA ~ second reference SLIP +1 / -1 | 97 / 14 | 16 / 35 |
| checkpoints where all three agree | 814 | 957 |
| the second reference alone | 256 | 113 |

The verdicts that moved:

- **Six `@known` entries no longer match.** In Harvest Moon `farm_intro`
  and Yoshi Topsy-Turvy `confirm`, the second reference is now IDENTICAL to
  dingbat, against mGBA. Its stale picture had hidden that it agrees with
  dingbat there (§29, §37). In The Sims `language`, the references no longer
  agree with each other. The audio entries for Harmony of Dissonance, KH
  Chain of Memories and Swordcraft Story 2 no longer differ from both
  references. Those `@known` lines are removed.
- **Advance Wars passes.** Its menu-scroll checkpoint is no longer one where
  the references agree against dingbat.
- **Four checkpoints that were not diagnostic now are.** The references now
  agree against dingbat at Rockman EXE 4.5 `pet_menu`, Castlevania: Aria of
  Sorrow `select_data`, Koro Koro Puzzle `title` and Mario & Luigi
  `06_f19428`. Each is chased in its own section.

## §66. Donkey Kong Country: the Kongo Jungle map a frame ahead is mGBA's cheap load, 2026-10-14

**Symptom.** `kongo_jungle_map` (f4626): every dingbat configuration,
dingbat-bios included, shows the map one frame ahead of both references,
which are IDENTICAL.

**The second reference is with dingbat.** EWRAM matches byte for byte in
dingbat-bios-nowl and the second reference at every frame from f2601 to
f2800. The V-blank count at 0x03000058 matches from f1802 to f4700. Its
matching picture is the stale capture of the section above. mGBA is the
one that parts.

**Where mGBA parts: the end of a 37-frame load.** From f2386 (after a
98,348-cycle DMA) the game builds the next scene without halting:

- a BIOS routine at 0x10xx;
- a 650-iteration tile loop at 0x08001FE0-0x08002092 (Thumb, ROM, WAITCNT
  0x4314 = WS0 3/1 with the prefetcher on). Each iteration calls SWI 7
  twice through `push {lr}; bl; svc 7; bx lr; pop {r1}; bx r1` wrappers,
  loads tile data from EWRAM (`ldrh`, `ldrb`), stores to EWRAM and BG
  VRAM (`strh`), and counts in IWRAM 0x030012CC.

Traced from f2380 in both, the load's instructions are the same and its
cost is not:

| | busy cycles, f2386 to the first halt | load ends |
|---|---|---|
| dingbat-bios-nowl | 10,575,212 | 10,350 cycles **after** the f2423 V-blank |
| mGBA | 10,556,746 | 8,469 cycles **before** it |

The 18,466-cycle gap, by region:

| region | dingbat minus mGBA |
|---|---|
| the tile loop at 0x080020xx | +4.3k |
| Nintendo's BIOS routine at 0x10xx | +3.0k |
| the SWI wrappers at 0x08000Axx | +2.8k |
| 0x080329xx | +1.6k |
| 0x080065xx | +1.3k |
| the rest | scattered |

One tile-loop iteration of the same instructions costs exactly 10 cycles
more in dingbat (482 against 472, 430 against 420). The extra cycles fall
on:

- the EWRAM loads and stores;
- the `pop {r1}` from the IWRAM stack straight after a `bx lr` refill into
  ROM: 4 cycles in dingbat against 2 in mGBA, where the fetch, the data
  cycle and the internal cycle alone are 4.

The second reference does even fewer iterations a frame than dingbat (353
against 360, and 376 in mGBA) and ends the load on dingbat's frame.

**Why that is the checkpoint.** mGBA's V-blank count 0x03000058 resumes one
V-blank sooner (f2424: 556 against 555) and stays one ahead. The cutscene's
animations and fades follow it:

- f2736-f2752: mGBA's Diddy animation byte (0x0200B9B5) is a frame early.
- From f2755: its BG palette buffer (0x02000410, copied to palette RAM by
  DMA3 at line 161) is a frame late.
- At f4407: the map transition starts a frame late (0x03000058 is reset at
  f4408 in dingbat, f4409 in mGBA).

**The decisive test.** Load mGBA to f2500, `poke8` 0x03000058 from 632 to
dingbat's 631, and change nothing else. mGBA then draws the checkpoint as
dingbat does: the centre frame and 60 of the window's 61 frames match.

Builds with `-d:CONTENTION=false -d:BRANCH_COMMIT_WAIT=false` still end
the load 3,632 cycles after the V-blank, and the window does not move.

**Who is right: dingbat, as far as the console has been asked.** This is
the class in §29, §33, §34 and §39. On the AGB SP, `slotexec.s` gives EWRAM
loads and stores from gamepak code with the prefetcher on dingbat's cost,
and mGBA's 4-5 cycles less. The second reference independently lands on
dingbat's frame. As in §39, the exact cells are at 3/1 waits, which an
empty-slot probe cannot run (§22: only WAITCNT 0 is safe).

**Status: no change.** The script passes (a SLIP is a pass). `kongo_jungle_map`
judges the cutscene's V-blank-count phase, which a 0.18 % cheaper load
moves by a frame.

## §67. Super Mario Advance: the title a frame ahead is the first boot's EEPROM format, 2026-10-14

**Symptom.** `quit_to_title` (f2400, the animated title after SAVE AND
QUIT): every dingbat configuration, dingbat-bios included, is one frame
ahead of both references, which are IDENTICAL.

**The second reference is with dingbat again.** On the title (f2365-2415)
there are 3,303 IWRAM bytes that change. Every one of them in dingbat at f
equals the second reference at f and mGBA at f+1. The references' matching
picture is the stale capture of the first section above (here its frames
end at VCOUNT 142-146).

**Where mGBA parts: the boot.** On a blank cart the game formats its
4 Kbit EEPROM. It writes 36 blocks, each polled to ready (0x080B69AC:
`ldrh 0x0D000000`, bit 0, with a timer-flag timeout that never fires).
Each block's poll lasts:

| | cycles a block | x 36 |
|---|---|---|
| dingbat (`EEPROM_SETTLE_CYCLES` 108368) | 108,432 | 3.90M |
| mGBA | 115,091 | 4.14M |

After the format, a wait for VCOUNT 159 (0x080B5710) turns the 240k-cycle
difference into a whole frame. To the boot's first main-loop poll mGBA runs
280,330 cycles and 64,101 instructions more. From there every step of the
boot comes one frame later in mGBA: the V-blank handler's busy flag and
counter at 0x03001990-0x03001993 first count at f21 in dingbat, f22 in mGBA
and f18 in the second reference.

SAVE AND QUIT (A at f2270) shifts all of IWRAM by a frame in mGBA against
dingbat between f2271 and f2272: mGBA takes the press a frame later, still a
frame behind. dingbat and the second reference reach the title on the same
frame and run it in step.

**The decisive test.** Built with `-d:EEPROM_SETTLE_CYCLES=115005` (§36's
mGBA figure), dingbat, dingbat-bios and dingbat-bios-nowl match both
references on all 61 frames of the checkpoint's window.

**Who is right: the cart, unmeasured.** This is §36 and §40 again. A
block's programming time belongs to the chip, varies between parts, and
GBATEK's "ca. 108368" stays.

**The probe.** It exists: `tests/roms/payloads/eesettle4k.s`, r0table row
`eesettle4k`, run with this game's 4 Kbit cart (AMZE) in the SP's slot,
booted holding SELECT+START: `python3 tools/hwlink/r0table.py --record
eesettle4k`. Predicted cells (`--emulators-only`):

| cell | dingbat, dingbat-bios | mGBA |
|---|---|---|
| 0x100, 0x101 (programming time) | 0001A74A (108,362) | 0001C130 (114,992) |
| 0x102 (DMA length) | 00000300 | 00000301 |
| 0x103 | FFFFFFFF on a blank last block | FFFFFFFF on a blank last block |

A console value within a few hundred cycles of 108k says the cart sides
with dingbat. One near 115k says it sides with mGBA. A spread across runs
says the checkpoint's frame can never be diagnostic.

**Status: no change.** The script passes (a SLIP is a pass). Its later
`[new]` checkpoints (`saved`, the file select) are still screens.

## §68. Car Battler Joe: the shadows' flicker phase, moved by mGBA's cheap map loads, 2026-10-14

**Symptom.** At `field_menu` (f20454) every dingbat configuration shows
the same picture as both references: SLIP -7 against mGBA, -5 against
the second reference. At `takah` (f22100) it is SLIP -1 against mGBA
and DIFFERENT against the second reference, with the references MINOR
to each other. The five dingbat configurations are identical at both,
so neither BIOS nor idle-loop skipping is involved.

**What differs on screen.** The game draws the sprites' shadows on
alternate frames (the script's note says so). At `field_menu` mGBA and
the second reference are pixel-identical. dingbat differs from both only
in the shadows under Joe and Pal (0.6% of pixels, box 112,62 28x26), so
the SLIP offsets are just the first frame in the window with the other
flicker phase. At `takah` dingbat again lacks the shadows that both
references draw (box 90,45 102x43 against mGBA). The second reference
also has Takah on another frame of his idle animation, which is its
MINOR against mGBA (box 94,16 40x26). Its DIFFERENT against dingbat is
that pose plus the shadows.

**Two clocks part, at loads.** The game keeps a frame counter at
0x030019D4 that stops during loads; it was peeked every frame in all
three emulators.

* *First boot.* On a blank cart the game writes 148 blocks of its
  64 Kbit EEPROM. Each block is polled to ready (`ldrh 0x0D000000`,
  bit 0; the library loop at 0x0806004C, §36's shape). A block takes
  108,068-108,075 cycles in dingbat (15,995,014 in all) and
  114,735-114,741 in mGBA (16,981,662 in all), 3.5 frames more.
  So mGBA's counter starts at f72 where dingbat's starts at f69, and
  mGBA's intro transitions come 3 frames late. The second reference's
  counter starts at f64, yet its intro pictures fall on dingbat's frames
  (f134-f2317, outside the fades). **None of this reaches the
  checkpoints.** Built with `-d:EEPROM_SETTLE_CYCLES=115005`,
  dingbat-bios moves its frames f78-f658 onto mGBA's, and every frame
  from f659 on hashes as in the shipped build: the START press at f660
  waits the difference out.
* *Scene loads.* After the boot, mGBA gains one count on dingbat at each
  of eight loads by `takah`: f415, f4477, f4877, f8056, f14903, f17485,
  f19973 and f21844. That leaves dingbat -4 at `field_menu` and -5 at
  `takah`. The second reference's counter stays exactly 5 ahead of
  dingbat's from f77 to f23086, so it takes every one of these loads in
  dingbat's number of frames. (f23086 is the practice load, which the
  script notes it runs late.)

**The loop.** Traced with `trace` over f4460-f4480 and f19958-f19975,
dingbat-bios-nowl against mGBA. Every scene load builds a 128x64 map in
a Thumb ROM loop at 0x08013190-0x08013250: 8192 iterations under WAITCNT
0x4314 (WS0 N 4, S 2, prefetcher on), with word and byte loads and
stores to EWRAM tables at 0x0202xxxx. Both emulators run the same
402,884 instructions: **1,277,643 cycles in dingbat, 1,101,525 in mGBA**
(156.0 against 134.5 an iteration). The 176k cycles (0.63 frame) carry
the load's end past a V-blank on the loads listed. Per instruction it
is section 29's pattern:

* `ldr r0, [r6, #16]` (an EWRAM word) costs 9 cycles in dingbat and 2
  in mGBA;
* each EWRAM store costs 4 against 2;
* the ALU op after a load costs 1 (prefetched) against 2.

The load and the op after it come to 10 against 4, though the EWRAM
word alone is 6 bus cycles and the load's I cycle one more. `slotexec.s`
on the AGB SP (section 22, used in §29, §33 and §39) says what EWRAM data
from gamepak code costs with the prefetcher on: dingbat's figure, with
mGBA 4-5 short. The second reference agrees with dingbat on every load
here.

**The flicker byte.** 0x03002A6C toggles every frame in play.

* dingbat and mGBA hold it in phase until f4477, the first scene load
  mGBA finishes a frame early. Over the next loads the two change phase
  against each other, and from f17485 on they stay opposite, through
  `field_menu` and `takah`.
* The second reference is in the opposite phase from the first scene
  that draws shadows (f2346, after the f2318-f2345 fade) and never
  changes against dingbat afterwards. Where that phase comes from is
  not chased: its driver has no `trace`, and its peeks fall off
  dingbat's frame phase (§58).

So the two references show the same shadows at both checkpoints by
different routes, and dingbat shows the other phase.

**Status: no core change.**

* Against mGBA, the slip is mGBA's under-charge of EWRAM data from
  gamepak code. The console's figure is dingbat's.
* Against the second reference, it is a frame-parity phase set before
  f2346, plus that emulator's own idle pose for Takah.
* The first-boot EEPROM writes are unmeasured cart time (below), and
  they do not reach either checkpoint.

Both verdicts are SLIP or not diagnostic, so no `@known` is added.

**Probe, for the record.** The cart's real block time is measured by
`tests/roms/payloads/eesettle.s` (r0table row `eesettle`, 64 Kbit
addressing), with Car Battler Joe in the slot and the console booted
holding SELECT+START. `python3 tools/hwlink/r0table.py eesettle 3 2 0 1
--emulators-only` predicts:

| cell | dingbat / dingbat-bios | mgba |
|---|---|---|
| 0x3 | FFFFFFFF (blank last block) | FFFFFFFF |
| 0x2 | 00000350 | 00000351 |
| 0x0 | 0001A74A (108362) | 00000026 |
| 0x1 | 0001A74A | 00000026 |

## §69. Starsky & Hutch: the menus are the EEPROM's programming time, the chase is the race loop's pricing, 2026-10-14

**Symptom.** At `chase` (f5140, the car at full throttle) every dingbat
configuration is SLIP -1 against mGBA and DIFFERENT against the second
reference (5.8% of pixels, box 35,0 197x160). The references are MINOR
to each other. All five configurations are identical. Section 46's
`movs pc, lr` fix was a different symptom of this game.

**Where play parts.** RAM was dumped every 50 frames, then every frame,
in dingbat-bios and mGBA. EWRAM and IWRAM agree, past the stack, up to
f2494, the frame after the title's START. From f2525 one frame in four
differs: the menus update at 15 Hz, and dingbat's updates land a frame
before mGBA's. The game's V-blank counter (0x030057B0) stops while it
writes the EEPROM:

| write | dingbat | mGBA | second reference |
|---|---|---|---|
| f2494, title to main menu (55 blocks) | 21 frames | 23 | 21 |
| f3602, the save slot | 21 | 22 | 21 |
| f3657, into the episode | 21 | 22 | 21 |

The cart has a 4 Kbit EEPROM, polled to ready at 0x080B7700 (`ldrh
0x0D000000`, bit 0, with a timer-flag timeout; 32 cycles a poll in both).
The first write's 55 blocks take **108,095 cycles a block in dingbat
and 114,733 in mGBA**. That is 6.6k a block, or 1.3 frames a write.
After the three writes, dingbat's main-loop counter (0x030057B4) is 3
counts ahead of mGBA's. Built with `-d:EEPROM_SETTLE_CYCLES=115005`,
dingbat-bios hashes as mGBA on every frame f1-f4599, and the menu slips
go.

**The chase does not follow from that.** The race load (A at f4504)
ends at f4534 in all three emulators. From there the race state agrees
apart from the counters and the sound buffer's phase. The build with
115005 shows the shipped build's chase frames exactly.

The race runs a 12 fps loop. Its wait (0x08007094) halts until a V-blank
count is reached, and an iteration's work is 4.0-4.6 frames. So an
iteration takes 5 frames unless its work ends before the fourth V-blank.
Over f4535-f5170 every dingbat iteration takes 5 frames. Two of mGBA's
take 4 (f4604-f4607 and f4623-f4626). From then on mGBA flips each
picture 2 frames before dingbat, and the hash window finds the centre
picture there (SLIP -1).

Iteration f4604, measured from the wait's exit to its next entry:

| | dingbat | mGBA |
|---|---|---|
| instructions | 391,161 | 390,168 |
| cycles | **1,138,886** | **1,120,677** |
| wait entered | 17,742 cycles after line 160 | 1,919 cycles before line 160 |

The 18.2k-cycle difference:

| | cycles | evidence |
|---|---|---|
| renderer contention on the frame copy in IWRAM (`ldm` from an EWRAM buffer, `stmia r2!, {r8-r11}` into BG VRAM; mode 1, BG2 affine on) | ~9.7k | the store costs 9 in both during V-blank; on lines 0-159 it costs 10-33 in dingbat against 9 in mGBA. Console-measured (`contmap.s`: affine BG2 holds dots 33+4n and 34+4n); neither reference models it |
| other IWRAM code | ~2.1k | more H-blank interrupts fall in the longer iteration |
| gamepak code | ~5.9k | §29's prefetcher pricing, spread thin |
| BIOS | ~0.5k | |

With `-d:CONTENTION=false`, 54 frames of the run change, and dingbat
still gets neither of mGBA's 4-frame iterations.

Separately, every iteration's V-blank wait ends 1,465 cycles later in
dingbat. The line-159 H-blank handler returns from Halt just as line
160 begins. dingbat runs the wait loop's `ldrh` of the interrupt flag
before it takes the V-blank interrupt, so the loop halts once more,
until line 161's H-blank. mGBA takes the interrupt one instruction
sooner. No frame here depends on it: no iteration in f4535-f4634 enters
its wait less than 17.7k cycles after the V-blank it misses. It is not
chased further. The halted-wake half of that timing is console law
(`wakeirq`, section 26), and mGBA misses those cells.

**Against the second reference the race is not diagnostic.** From
f4800 no frame of the second reference equals any frame of mGBA's or
dingbat's within ±12 frames. The references' MINOR at the centre is two
different race frames that happen to share 98.8% of their pixels.

**Status: no core change.**

* The menus follow the cart's block programming time, which is
  unmeasured. dingbat keeps GBATEK's ca. 108368 (§36, §40).
* The chase follows the race loop's cost, and dingbat's extra cycles
  there are console-measured contention and prefetcher rules.

Both are SLIP against mGBA, so no `@known` is added.

**Probe, for the record.** `tests/roms/payloads/eesettle4k.s` (r0table
row `eesettle4k`, 6-bit addressing) times one block on a 4 Kbit cart.
Starsky & Hutch is one, as is §40's Klonoa. Put it in the slot and boot
holding SELECT+START. `python3 tools/hwlink/r0table.py eesettle4k 0x103
0x102 0x100 0x101 --emulators-only` predicts:

| cell | dingbat / dingbat-bios | mgba |
|---|---|---|
| 0x103 | FFFFFFFF (blank) or the block | FFFFFFFF |
| 0x102 | 00000300 | 00000301 |
| 0x100 | 0001A74A (108362) | 0001C130 (114992) |
| 0x101 | 0001A74A | 0001C130 |

What the console answers decides it:

* near 114.7k: mGBA is right on this game's menus, and dingbat moves;
* near 108k: dingbat stays as it is;
* a spread between runs: these checkpoints can never be diagnostic.

## §70. Rockman EXE 4.5: the PET menu is the install bar's dice again, and the second reference threw its own, 2026-10-14

**Symptom.** Since §65's driver fix, `pet_menu` (f4734) is DIFFERENT against
both references in all five dingbat configurations, and the references are
MINOR to each other. The screen is the same menu in all three. dingbat's
background scroll, the menu's arrows and Mega Man's pose are on other
frames (2,632 px against mGBA, box 0,12-239,148). The references differ only
in the glow around Mega Man (856 px, every one a single 5-bit step).

**The same cause as §39, carried forward.** Load mGBA's f3200 state and
`poke8` only dingbat's two RNG words (0x02003F6C, 8 bytes, and 0x02003C84,
4 bytes). mGBA then shows dingbat's install bar frame for frame, f3503-f3594
at offset 0 where it was +10. At `pet_menu` it differs from dingbat in 1,186
px, the glow only (box 0,30-67,159, mean error 0.013, MINOR). That glow is
the game's frame counter 0x02004B80, one behind mGBA's since the boot (§39).

**Whose state the second reference shares: neither, exactly.** Peeked every
frame from f470, and every two frames over the install:

| | dingbat | mGBA | second reference |
|---|---|---|---|
| the LCG at 0x02003F6C starts stepping | f478 | f476 | f477 |
| frame counter 0x02004B80 at f3200 / f4734 | 0x08D8 / 0x0ED4 | 0x08D9 / 0x0ED5 | 0x08D8 / 0x0ED4 |
| the install's last frame (hash-matched) | 10 frames before mGBA | | mGBA's |
| IWRAM bytes differing from mGBA at f4734 (below the stacks) | 3,871 | | 33 |

Its LCG runs one step from each emulator, so it throws its own dice. Its
install pictures part from mGBA's over f3274-f3289, f3298-f3337, f3345-f3361
and f3386-f3409, and then its last pause ends on mGBA's frame. The PET
scene's state (sprite tables at 0x0200DAxx-0x0200E6xx, the IWRAM buffers at
0x03001873-0x030047D7) follows the install's end, so from there it has
mGBA's. Its frame counter is dingbat's, which is why the glow differs from
mGBA's. The references agree at `pet_menu` because two different dice
sequences happened to end the install on the same frame. That is not a
timing witness.

**Status: (b), no core change.** As §39: the dice follow the boot's EWRAM
clear and the title's EWRAM passes, where dingbat's price is the console's
(`slotexec.s`, AGB SP) and mGBA's is 4-5 cycles short. The script gets
`@known * checkpoint pet_menu:` for this section. `save_prompt` (MINOR
against both, the references MINOR to each other) and `save_screen` (SLIP)
need nothing.

**How it was found.** `peek` of the RNG words, the frame counter, the
install countdown, and full EWRAM/IWRAM at f3200, f3624, f4000 and f4734 in
dingbat-bios-nowl, mGBA and the second reference over the frozen `[new]`
timeline. Then `runhash` f3201-f4760 in all three, matched by hash within
±20 frames. Then the mGBA run from its f3200 state with the poke.

## §71. Mario & Luigi: the battle at 06 is §34's main-loop count, and the second reference keeps dingbat's count, 2026-10-14

**Symptom.** Since §65's driver fix, `06_f19428` (f19758, the Bowser battle's
Solo Attack prompt) is MAJOR against both references in all five dingbat
configurations, and the references are MINOR to each other. It is the same
battle on every emulator. dingbat has Bowser and Peach's fountain on other
frames of their idle animations (box 50,50-160,106, about 1.9k px). The
references differ in 100 px, three of them more than a 5-bit step. `07_mark`,
499 frames later, is the same picture (§34, already `@known`).

**The main-loop counter decides it, as in §34.** Load mGBA's f17700 state
(before the battle flash) and `poke8` only the main-loop counter at
0x03000368:

| mGBA's counter set to | at 06 (f19758), against | px |
|---|---|---|
| dingbat's (0x44D6) | dingbat | 96, box 50,66-188,155 |
| dingbat's + 1 (0x44D7) | mGBA unpoked | **0** |
| dingbat's + 4 (0x44DA) | dingbat / mGBA | 1,616 / 2,040 |
| dingbat's + 5 (0x44DB, its own) | mGBA unpoked | 0 |

`07_mark` (f20257) behaves the same way: 93 px from dingbat with dingbat's
count, and 0 from mGBA with dingbat's + 1. A poke at f19000, inside the
battle, changes nothing at either checkpoint. So the poses are set from the
counter early in the battle, and +1 and +5 land on the same phase.

**Whose state the second reference shares: dingbat's.** Counters peeked
every frame to f400, then every 10 to f3800, and around each load:

| | dingbat | mGBA | second reference |
|---|---|---|---|
| main-loop counter 0x03000368 starts | f24 | f24 | f23 |
| V-blank count 0x0300036C against dingbat | | +0 | +1 from f23 |
| main-loop counter against dingbat after f3829, f3964, f5025, f5054, f10335 | | +1, +2, +3, +4, +5 | +1 throughout (0 for a frame or two inside two boot loads) |
| task timers 0x03002150, 0x03002210, 0x03002548, 0x0300257C at f17550-f19758 | | +5 each | **equal to dingbat's** |

The second reference takes every one of §34's five scene loads in dingbat's
number of frames. Its only difference is a V-blank of boot lead, the one §65
measured in Donkey Kong Country. That lead puts its counter at dingbat's + 1,
which draws the same battle frame as mGBA's + 5. The references' agreement
at 06 and 07 is therefore a phase coincidence. On the loads that moved the
counter, the second reference is with dingbat, and mGBA alone is cheap.

**Status: (b), no core change.** This is §34's cause: mGBA under-charges
gamepak code at the scene loads (§29's prefetcher pricing, where the console
sides with dingbat). The script gets `@known * checkpoint 06_f19428:` for
this section. The `07_mark` entry now cites §71 as well, because the second
reference does not under-charge those loads.

**How it was found.** `peek` of the two counters and the four task timers in
dingbat-bios-nowl, mGBA and the second reference over the frozen `[new]`
timeline, `runhash` f19650-f19800 (no frame matches between any two at any
offset within ±20), and the mGBA runs from its f17700 and f19000 states
with the poke.

## §72. Castlevania: Aria of Sorrow: Select Data is the alpha blend's rounding, 2026-10-14

**Symptom.** `select_data` (f965, the file select over the castle
picture): every dingbat configuration is DIFFERENT against both
references, and the references are MINOR to each other. The five
configurations are identical. This checkpoint became diagnostic with §65's
driver fix.

**Whose state.** IWRAM and EWRAM were peeked every frame from f0 to f999 in
dingbat-bios, mGBA and the second reference. At f965, leaving out the stack
and the sound buffer at 0x03005840-0x03005E6F, dingbat and mGBA differ in
seven bytes. The ones that matter:

| | dingbat | mGBA | second reference |
|---|---|---|---|
| 0x0300519B, the screen's frame count | 0x9E | 0xA0 | 0xA1 |
| 0x03000072, the cursor's bob | 2 frames behind mGBA | | 1 frame ahead of mGBA |
| 0x030023F1, the title's scroll cycle, frozen since the title | 15 | 14 | 13 |
| 0x030054F4, a 9-step cycle | in phase with mGBA | | 2 steps off |

The second reference shares neither emulator's state. Its counts run a
frame ahead of mGBA's and three ahead of dingbat's.

**Where the counts part.**

* *Boot.* From f11 the second reference counts early. By f16 it is three
  frames ahead of both, drawing each picture three frames before they do.
  This is §65's boot lead.
* *Two loads.* The count at 0x0300519B holds while the game loads.

  | load | dingbat | mGBA | second reference |
  |---|---|---|---|
  | f155 | 3 frames | 2 | 3 |
  | f432 | 9 frames | 8 | 9 |

  mGBA gains a frame at each load. The second reference takes both in
  dingbat's number of frames.

The f432 load, traced from f426 in dingbat-bios-nowl and mGBA:

| | busy cycles | instructions | ends on line |
|---|---|---|---|
| dingbat | **2,330,257** | 719,363 | 227, after the V-blank |
| mGBA | **2,231,156** | 697,580 | 147, 13 lines before it |

Where the 99.1k-cycle difference falls:

* About 60k is gamepak code. Under WAITCNT 0x4017 (WS0 3/1, prefetcher on)
  the same instructions cost more in dingbat. The largest share is the
  tile-lookup routine at 0x08001800-0x080019FF, called 2048 times: the same
  instructions take 580,526 cycles against 557,018. It loads from the
  cartridge (`ldrb r3, [r0]`, `ldr r0, [r0, #0xC]`, `ldrh r2, [r1]` with r0
  and r1 at 0x080E8xxx) and from its literal pool, and stores into IWRAM.
  Next come its caller at 0x0803F7xx (+8.2k), 0x08000Dxx (+5.9k) and
  0x08000Axx (+5.0k). Nintendo's BIOS at 0x0Bxx adds +3.1k on the same
  4,122 instructions.
* About 35k is the V-blank sound mixer in IWRAM (0x030028xx-0x03002Bxx),
  with 17.5k more instructions. It runs 9 times in dingbat's load against 8
  in mGBA's, and mixes 19 voice passes against 12. This follows from the
  longer load, not from the mixer's pricing: per instruction its cycles are
  the same.

**The picture is the blend.** At f965 dingbat and mGBA hold the same
palette RAM, VRAM and video registers. dingbat's registers were read
through a scratch driver's register dump, mGBA's through `peek`. OAM
differs in one byte, the cursor's x. BLDCNT 0x0844 blends BG2 (the panels)
over BG3 (the castle), and BLDALPHA 0x0A06 gives EVA 6, EVB 10.

Rendering dingbat's frame one layer at a time (`layers`) finds 22,290
blended pixels:

* **mGBA:** all 22,290 equal min(31, ((w(t)·6 + w(b)·10) >> 4) >> 3),
  where w(c) = c<<3 | c>>2 widens the 5-bit colour to 8 bits.
* **The second reference:** 21,753 equal the rounded (t·6 + b·10 + 8) >> 4.
  The other 537 are one green step below that.
* **dingbat:** (t·6 + b·10) >> 4, truncated.

For example, the panel's (3,3,3) over the castle's (1,1,22) is exactly
(1.75, 1.75, 14.875). dingbat draws (1,1,14), mGBA (1,1,15) and the second
reference (2,2,15).

mGBA is a step higher than dingbat on 17,680 pixels and the second
reference on 21,794. Of the 16,110 unblended pixels, the second reference
matches dingbat on every one. mGBA matches on all but 52, the cursor's bob.

**The decisive test.** A scratch dingbat build with mGBA's blend formula
(not kept) puts 41 of the window's 61 frames on an mGBA frame. For 38 of
them it is mGBA's frame from two frames earlier, the cursor's lag. The
other frames combine the cursor's phase with the 9-step cycle, which runs
in phase with mGBA, so no single offset matches them all. With the
rounding form, no frame equals the second reference's, because of its
green.

**Who is right: dingbat, on the blend.** The SP's `blendprobe.gba`
photographs (`tests/roms/expected/blendprobe-agb-sp-1.txt`) fit truncation
on all 16 alpha cells:

* rounding misses five, for example T02B28 at EVA 7, EVB 9: 17, where the
  console shows 16;
* mGBA's widened form also misses five, for example T00B28 at EVA 7, EVB 9:
  16, where the console shows 15.

A photograph only picks a 5-bit candidate. A capture of the digital video
signal is still wanted (docs/hwprobe-questions.md).

The loads are §29's and §66's class: mGBA's cheaper data accesses from
gamepak code under the prefetcher. `slotexec.s` measured that class on the
console at 4/2 and found dingbat's figure. This game runs at 3/1 (§39's
caveat). The second reference takes the loads in dingbat's frames.

**Status: no core change.** `@known * checkpoint select_data:` is added to
the script: no reference can draw the console's panels here.
**Later the same day:** after the driver fixes of §82 and §83, the second
reference's checkpoint frame reads one 5-bit step from dingbat's, which is
MINOR. dingbat is no longer alone there, so the `@known` is removed.

## §73. Koro Koro Puzzle: the title is the alpha blend's rounding, read by the text comparison, 2026-10-14

**Symptom.** `title` (f940, `compare=text`): every dingbat configuration
is MAJOR against both references, at text similarity 0.77 and 0.74. The
references are MINOR to each other (0.95). The faded second PUSH START row
reads "PUBH $TART" in dingbat and "PUGH BTRRT" in both references, and the
logo's Japanese reads as noise everywhere. §37 noted that this script
"still passes"; the second reference's stale picture (§65) had hidden this
checkpoint.

**The picture is the blend.** At f940 dingbat and mGBA differ on 2,924
pixels, and the second reference and dingbat on 2,932. Every one is a
single 5-bit step, with dingbat the lower, in the logo and the faded row.
The two emulators' registers match: BLDCNT 0x3A45 (BG0 and BG2 over BG1,
BG3, OBJ and the backdrop) and BLDALPHA 0x0C04 (EVA 4, EVB 12).

The scratch builds of the section above settle it:

* **mGBA's blend:** dingbat's f940 equals mGBA's on every pixel. Its
  frames hash as mGBA's on every frame from f831 to f959, the window
  included, and on f790-f805.
* **Rounding:** dingbat differs from the second reference only in green,
  by one step on 1,928 pixels. That is the green rule of the section
  above.

**Whose state.** The title's picture is the same game state in all three.
RAM differs in:

| | dingbat | mGBA | second reference |
|---|---|---|---|
| tilt samples (0x030009DC on, 8 of them) | X 0x392, Y 0x3A0 | 0x3A0, 0x3A0 | 0xFFF, 0xFFF |
| 0x03000A18, the frame count | 0x383 | 0x384 | 0x386 |
| 0x03000A20, a random word, frozen from f792 | 0x338B1A91 | 0x452BD7B1 | 0x452BD7B1 |

* *The tilt sensor.* Each driver feeds it differently. dingbat answers its
  level reading (bus.nim `TILT_X/Y_CENTER`). The mGBA driver attaches a
  level rotation source (§37). The second reference has no sensor and reads
  the 0xFF of the empty SRAM window. The title samples the sensor, but
  nothing on it follows the sensor: the frames above match with X 0x392
  against 0x3A0, and the second reference's title, read at 0xFFF, differs
  from the rounding build only in green.
* *The counts are the boot.* On the blank cart, the boot runs from frame 0
  to its first halt:

  | | busy cycles | instructions | count starts |
  |---|---|---|---|
  | dingbat-bios-nowl | **9,265,791** | 2,962,174 | f34 |
  | mGBA | **9,011,814** | 2,929,754 | f33 |
  | second reference | | | f31, §65's lead |

  Of the 254k-cycle difference:

  * +58k is IWRAM code at 0x030016xx, with more instructions.
  * +33.5k is gamepak code at 0x08018Bxx.
  * +30.4k is a list walk at 0x0805BD6E-0x0805BD78: 4,830 passes of
    `adds; cmp; beq; ldr r0, [r2, #0x38]; cmp; bne`, with r2 in EWRAM at
    0x020356xx. A pass costs 23.6 cycles in dingbat and 17.8 in mGBA. mGBA
    charges the EWRAM word load and the `cmp` after it 4 cycles together,
    though the word alone is 6 bus cycles. This is `slotexec.s` row 9
    (EWRAM `ldr` from gamepak code, prefetcher on): the console and dingbat
    take 22, mGBA 17 (§63).
* *The random word.* It advances with the frame count and stops on the
  same frames in all three (f790-f792, 30 frames after the A at f760). The
  references' counts are ahead, so they stop one step further on. The
  second reference shares mGBA's word but not its counts. Whether a later
  checkpoint follows the word was not chased.

**Who is right: dingbat, on both.** The blend follows the SP's blendprobe
photographs, as in the section above. The boot is the console-measured
EWRAM pricing of §63 and §68, and the second reference takes the boot even
sooner, by its own timing (§65).

**Status: no core change.** `@known * checkpoint title:` is added to the
script.
**Later the same night:** classify now applies the pixel path's one-step
rounding rule to text-judged screens before OCR runs. `title` reads MINOR
against both references, so the `@known` is removed. Gunstar's panels and
Klonoa 2's pause (§89) were the same case.

## §74. The checkpoints where all three emulators differ, 2026-10-14

**The set.** In the baseline `e9739f858dc3-src-baecd9352478` (164 games),
72 `[new]` checkpoints in 53 games have all three pairs outside
IDENTICAL/MINOR: dingbat-bios against mGBA, dingbat-bios against the second
reference, and mGBA against the second reference. Nobody judges them: the
references do not agree, so no verdict counts against dingbat.

**Method.** For each checkpoint:

* the three centre frames compared in 15-bit colour: pixels, pixels more
  than one 5-bit step apart, the box;
* the three 61-frame windows matched by hash at every offset;
* the script's notes and the ledger;
* BLDCNT, BLDALPHA, BLDY, the window registers and DISPCNT peeked at the
  checkpoint frame in all three (mGBA's `peek` also returns the write-only
  registers).

A scratch replay of the frozen `[new]` timeline did the peeks. It reproduced
the baseline's hash at all 69 checkpoint frames checked.

| bucket | checkpoints |
|---|---|
| render (same state, the picture differs) | 22 |
| other deterministic (same state, a CPU-timing race in the visible frame) | 2 |
| downstream (an earlier, classified divergence) | 15 |
| RNG/phase (timing-seeded randomness or an animation phase) | 25 |
| harness (window 0 on an animated screen, mid-fade, a reference that never boots) | 8 |

**The render rows.** Every render row but one is colour-effect rounding,
with the effect's registers equal in all three emulators. These rows split
three ways:

* 14 alpha blends: every differing pixel is within one 5-bit step, dingbat
  the lower. This is §72's truncation, which the SP photographs confirm.
* 5 darkens: §40's rule, also photographed.
* 2 brightens: the brighten section below.

The other render row is Klonoa 2's world map, where mGBA alone draws seven
pixels in a window column, and the second reference matches dingbat bit for
bit (the Klonoa 2 section below).

Most of the rounding rows read SLIP 0, not MINOR. `classify` tests "the
windows share a frame" before its one-step rule. An unblended frame at the
window's edge is shared, so a rounding difference at the centre is reported
as a slip. None of them hides a dingbat bug.

| game | checkpoint | bucket | reason | § |
|---|---|---|---|---|
| Advance Guardian Heroes | stage1 | RNG/phase | the first fight runs differently in all three (script note) | |
| Advance Wars | 02_mark | downstream | first-boot flash writes, menu scroll phase | §35 |
| Asterix & Obelix XXL | main_menu | harness | the second reference hangs at boot (blank); dingbat~mGBA SLIP +2 | |
| Asterix & Obelix XXL | level1 | harness | the same; dingbat~mGBA SLIP -14 (the stage fade, script note) | |
| Rockman EXE 4.5 | saved | downstream | the install bar's dice | §39, §70 |
| Boktai | solar_setting | harness | the first screen's fade-in at -2/-1/+1, every pixel within a step | |
| Breath of Fire | title | render | darken EVY 1 (text compare) | §40 |
| Breath of Fire | downstairs | render | darken EVY 1 (text compare) | §40 |
| Breath of Fire II | title | render | darken EVY 1 (text compare) | §40 |
| Castlevania: Aria of Sorrow | title | downstream | a frame or two apart after the boot loads; within a step | §72 |
| Castlevania: Aria of Sorrow | intro | render | darken EVY 3 | §40 |
| Castlevania: HoD | story | render | alpha 9/7 on the clouds (text compare) | §72 |
| Contra Advance | level_intro | render | darken EVY 15 | §40 |
| Crash Nitro Kart | name_entry | RNG/phase | animated keyboard, text compare; windows match at -1/-3/-2 | |
| Deadly Skies | save_slots | render | alpha, dingbat~second reference within a step; mGBA a fade step behind (EVA 12 against 13) | §72 |
| Derby Stallion Advance | title | RNG/phase | animated title at -6/-2/+4; the second reference rolls other numbers (script) | |
| Doom | e1m1_east_room | RNG/phase | the player drifts with the game's tic rate (script) | |
| DQ Monsters Caravan Heart | kiefer_room | RNG/phase | RAM parts from the title; the second reference 29 frames ahead (script) | |
| Final Fantasy V | title | render | alpha on the semi-transparent PRESS ANY BUTTON | §72 |
| Final Fight One | intro_story | downstream | the load a frame late | §29 |
| Fire Emblem: Sacred Stones | slots_empty | render | alpha 6/16 over an animated background; dingbat~second reference within a step but 84 px; mGBA's background on another frame | §72 |
| Fire Emblem: Sacred Stones | intro | harness | the text fading in at -2/+1/+3 | |
| Fire Emblem: Sacred Stones | prologue | render | alpha 3/16 (text compare) | §72 |
| Gradius Galaxies | stage1 | render | alpha 15/16 | §72 |
| Gunstar Super Heroes | hall | render | dingbat~mGBA alpha only; the second reference's own lines and pillar (script note) | §72 |
| Gunstar Super Heroes | bridge | render | the same | §72 |
| Klonoa - Empire of Dreams | vision_map | downstream | the EEPROM's programming time | §40 |
| Klonoa - Empire of Dreams | holding_moo | downstream | the same | §40 |
| Klonoa 2 | world_map | render | mGBA alone on 7 px of a window column; the second reference = dingbat | Klonoa 2 below |
| Klonoa 2 | vision_map | other deterministic | 1 px of cloud edge, a race in the visible frame, mGBA a line early | Klonoa 2 below, §58 |
| Klonoa 2 | back_to_map | RNG/phase | dingbat~mGBA one frame (59 of 60 at -1); the second reference elsewhere | §58 |
| Koro Koro Puzzle | warning | RNG/phase | the scrolling background at three positions, the boot's counts | §73 |
| Lufia: Ruins of Lore | title | render | alpha 9/6, 3 px | §72 |
| Mario & Luigi | 16_f48916 | downstream | the main-loop count | §34, §71 |
| Mario Golf: Advance Tour | title | render | alpha 9/7 on PRESS START | §72 |
| Mario Party Advance | hobby, dream, secret | RNG/phase | ~100 px of the star's sparkles (text compare) | |
| Mario Pinball Land | title | render | alpha 9/7 | §72 |
| Mario vs. Donkey Kong | select_data | render | dingbat~mGBA alpha; the second reference at EVB 7 against 9 (its own phase) | §72, §64 |
| Mega Man & Bass | title | RNG/phase | the menu slide at +5/-8/-13 (script) | |
| Mega Man Zero 4 | title | render | brighten EVY 5 | brighten below |
| Medabots AX | intro | other deterministic | a palette write in the visible frame lands on three lines | Medabots below |
| Pokemon Mystery Dungeon | tiny_woods, dungeon_menu, quicksave_prompt, saved | RNG | the quiz and the dungeon are timing-seeded (script) | |
| Phantasy Star Collection | saved | downstream | the field parity | §62 |
| Rayman 10th Anniversary | game_select | render | brighten EVY 5 on OBJ | brighten below |
| Rhythm Tengoku | title | RNG/phase | the logo's bounce phase | |
| Rhythm Tengoku | game_select | RNG/phase | the colour cycle's phase (script) | |
| Shining Force | recorded | RNG/phase | the wandering NPCs (script) | |
| Sonic Advance 2 | presented | RNG/phase | the ripple's phase; the second reference on another screen | §65 |
| Sonic Advance 3 | hub | RNG/phase | Sonic and Tails elsewhere (script) | |
| Sonic Battle | title | RNG/phase | the animated background's phase (script) | |
| Sonic Pinball Party | language | harness | window 0 on a scrolling checkerboard | |
| Sonic Pinball Party | deutsch | harness | the same | |
| Street Fighter Alpha 3 | title | RNG | the attract-mode fight (script) | |
| Super Mario Advance 3 | column_top | downstream | the cart's EEPROM decides 1-1 | §36 |
| Super Mario Advance 3 | below_white_block | downstream | the same | §36 |
| Spyro 2 | intro | harness | mid-fade; the fade starts on window frames 19, 23 and 14 | |
| Starsky & Hutch | chase | downstream | the race loop's pricing | §69 |
| Super Ghouls 'N Ghosts | graveyard | RNG/phase | the zombies and Arthur's hit (script) | |
| Super Puzzle Fighter II | menu_after_save | RNG/phase | the animated menu ±1-2 frames after the save | |
| Super Puzzle Fighter II | stage1_vs | RNG | the random opponent: Chun-Li, Ryu, Felicia (script) | |
| Super Puzzle Fighter II | puzzle_play | downstream | the opponent and gems of stage1_vs | |
| Swordcraft Story 2 | workshop | downstream | the first battle's random numbers | §57 |
| Zelda: The Minish Cap | saved | harness | window 0; Link's idle and the background animate | |
| The Sims - Bustin' Out | language | downstream | the boot's three phases | §29, §65 |
| Tony Hawk's Pro Skater 4 | back_to_menu | render | alpha 15/1 (text compare) | §72 |
| Yu-Gi-Oh! Eternal Duelist Soul | title | downstream | `@known` | §33 |
| Yu-Gi-Oh! Sacred Cards | title | render | dingbat~mGBA alpha; the second reference a fade step on (EVA 2 against 1) | §72 |

**Status: no core change.** No row hides a dingbat bug. The four rows that
looked most likely to are chased in the next three sections.

## §75. Mega Man Zero 4 and Rayman 10th Anniversary: the brighten is truncated in every channel, as the SP photographs say, 2026-10-14

**Symptom.** Mega Man Zero 4 `title` (f690) and Rayman 10th Anniversary
`game_select` (f704) are SLIP 0 or -1 between every pair. Every differing
pixel is one 5-bit step. All three emulators have the same registers:

* Mega Man Zero 4: brighten (BLDCNT 0x3F82, BG1), BLDY 5, on PRESS START.
* Rayman: brighten (BLDCNT 0x0090, OBJ), BLDY 5.

These are the only brighten rows of the set.

**The top colours.** mGBA ran from its f689 (f703) state for 30,000 trace
steps, past its V-blank handler. Then `poke8 0x04000050` cleared the effect
bits, and `run 1` drew the checkpoint frame with the effect off. BLDCNT read
back unchanged. With the true top value t of every pixel the effect changes,
each emulator's channel value was compared with dingbat's
`t + ((31 - t) * 5 >> 4)`:

| | pixels | dingbat | mGBA +1 (R / G / B) | second reference +1 (R / G / B) |
|---|---|---|---|---|
| MMZ4, exact fraction < 0.8125 | 1,255 | truncation on every value | 305 / 386 / 813 | 285 / 20 / 793 |
| MMZ4, fraction >= 0.8125 | | truncation | R 25, G 25 (all) | R 25, G 25 (all) |
| Rayman, fraction < 0.8125 | 2,818 | truncation on every value | 403 / 1,295 / 378 | 375 / 572 / 1,809 |
| Rayman, fraction >= 0.8125 | | truncation | R 405, G 386, B 184 (all) | the same |

A reference is never more than one step from truncation. It is truncation or
one step higher, depending on the pixel.

**Who is right: dingbat, except for green at high fractions, which is open.**
The SP's `blendprobe` photographs (`tests/roms/expected/blendprobe-agb-sp-1.txt`)
show truncation in R, G and B together at fractions 0.5625 to 0.75. Examples:

* EVY 3 T11: exact 14.75, the console shows 14.
* EVY 7 T02: 14.6875, the console shows 14.
* EVY 11 T01: 21.625, the console shows 21.

Every value here where a reference adds a step below 0.8125 has a fraction
of 0.25 to 0.75. Those rows cover that range, and below 0.5 rounding would
not add a step either. So the references' +1 there is wrong in all three
channels.

At 0.8125 and above, R and B truncate on the SP, so the references are wrong
there too. Green is not settled: on those photo rows it nulls a step higher
or at no 5-bit value ("Brighten green anomaly", docs/hwprobe-questions.md).
That leaves 25 and 386 green values here, in a direction the references
happen to take. If the console's green is the step higher, both checkpoints
still differ from both references in R, B and low-fraction green.

**Status: (b), no core change.** For the green rows the classification is
(c): a capture of the video signal, or the single-channel photo probe that
docs/hwprobe-questions.md already asks for. The CPU cannot read a blend
result back, so an r0table probe cannot answer it.

## §76. Medabots AX: a palette write during the visible frame lands on three lines, 2026-10-14

**Symptom.** `intro` (f958, the island map) is SLIP 0 between every pair.
The only pixels that differ are a green strip, rows 39-45, x 0-15 and
224-239. dingbat has (7,26,7) and (4,27,7) there; mGBA has (7,25,7) and
(4,26,7) on every row. The second reference differs from dingbat only on row
45, x 224-239.

**Same state.** At f957 all three pictures are equal. Palette RAM and OAM
are byte-identical in dingbat and mGBA at f957 and f958. The two colours are
palette entries 0x050001F8 and 0x050001FA. The game rewrites them while the
screen is drawn (`watchw` in dingbat catches the store at line 45), so each
line of the strip shows whichever value it read.
The emulators differ only in the line each one writes them on:

| | where the new colour starts |
|---|---|
| mGBA | before line 39 |
| dingbat built with `-d:CONTENTION=false` | line 42 |
| the second reference | line 45, about dot 224 |
| dingbat as built (`watchw`) | line 46: the store lands at line 45, ~cycle 1,200, in the H-blank |

**Where the cycles go.** Traces from the f957 frame end (VCOUNT 160) to the
palette loop's first instruction (0x08025F70), dingbat-bios-nowl against
mGBA:

| | cycles | steps | line |
|---|---|---|---|
| dingbat | 138,007 | 43,739 | 44 |
| mGBA | 129,417 | 43,483 | 37 |

Of the +8,590:

* **+4.3k is Nintendo's CpuSet** (the halfword loop at 0x0B8x). It copies
  into BG VRAM through lines 0-39 in mode 0 with four BGs. Its store costs 5
  cycles on 4,223 of its passes in dingbat and 2 in mGBA. Outside the drawn
  lines a pass costs the same in both.
* **+1.6k is ROM code at 0x080564xx.** Four of its instructions
  (0x0805645C-0x08056468) cost 5 cycles against 2, the same pattern.
* The rest is spread over gamepak code, §29's prefetch pricing.

The renderer's contention on CPU VRAM accesses is console-measured
(`contmap.s` cells in r0-agb.json; `dmavram.s`, §62, §69). Neither reference
models it.

**Status: (b), no core change.** The contention-off build puts the write
three lines after mGBA's. The remaining three lines are §29's class, where
`slotexec.s` on the SP sides with dingbat. The second reference lands within
about 300 cycles of dingbat's write, so on this frame its timing is
dingbat's.

## §77. Klonoa 2: the world map's window column is mGBA's alone, the Vision map's cloud is a one-line race, 2026-10-14

**`world_map` (f2240): render, mGBA alone.** dingbat and mGBA hash equal on
59 of the window's 61 frames. The two that differ are f2239 (2 px) and f2240
(7 px). Every differing pixel is at x 106-107, lines 103-107. The second
reference runs this stretch three frames ahead. Its f2236 and f2237 hash
exactly as dingbat's f2239 and f2240 (87F2F715172CA1D1, 2959FA049447AD5B).
At the same game state it draws dingbat's picture bit for bit.

* *Same state, no race.* IWRAM and EWRAM are identical at f2238-f2240,
  except the stack and two bytes (0x03004244 and 0x03005210, 00 against
  40). Palette RAM and OAM are identical. IE is 0x0001, so only the V-blank
  interrupt is on. The trace runs no instruction between VCOUNT 0 and 159:
  the game writes everything during the V-blank.
* *The registers (mGBA's peek).* Mode 0 with BG0-3, OBJ, WIN0 and WIN1
  (DISPCNT 0x7F40).
  * WIN1H opens one column at a time: X1 108, 107, 106, 104 at f2238-f2241,
    X2 108. WIN1V covers lines 80-160.
  * WIN0 covers x 0-108, lines 108-160.
  * WININ 0x3F3F, WINOUT 0x003D: BG1 shows only inside the windows.
* *The pixels.* Rendered one layer at a time (`layers`), dingbat's
  differing pixels are BG0:
  * BG1 and OBJ draw nothing there.
  * BG2 covers the column above line 103.
  * WIN0 starts at line 108.

  Inside WIN1's one- or two-pixel column, mGBA draws BG0 colours that
  dingbat's BG0 has 2-4 px further right. For example, (16,31,17) is at
  (106,104) in mGBA and from x=108 in dingbat. Outside the column the three
  agree.

Two independent renderers agree bit for bit at equal state. This is not a
dingbat question, and no console rule is needed (a photograph would settle
it if it were ever wanted).

**`vision_map` (f3590): other deterministic, a race in the visible frame.**
dingbat and mGBA differ on three of the 61 frames, at a cloud's top edge, x
74-88:

* f3565: 20 px, lines 38-39.
* f3577: 14 px, line 40.
* f3590: 1 px at (87,37).

At the f3564 and f3565 frame ends, RAM, palette RAM and OAM equal mGBA's,
apart from the same two bytes and the stack. Here the CPU runs through the visible frame: IE is
0x0003, with H-blank interrupts. A costly stretch at 0x0802F4xx runs while
lines 37-45 are drawn in dingbat and lines 36-44 in mGBA.

From the f3564 frame end to its first instruction, dingbat takes 130,770
cycles (line 38) and mGBA 129,079 (line 36). Of the +1,691:

* +802 is gamepak code at 0x080011xx;
* +240 is code running from EWRAM at 0x020000xx.

That is §29's and §63's class, where the SP sides with dingbat
(`slotexec.s`). `-d:CONTENTION=false` leaves all three frames' hashes
unchanged. The second reference is no witness: at this checkpoint it shares
no frame with either within ±30 (its own timing, §58).

**Status: no core change** (`world_map`: mGBA alone; `vision_map`: (b),
§29's class). Both checkpoints are SLIP 0 between dingbat and mGBA, so no
`@known` is needed.

## §78. Dragon Ball Z - Buu's Fury: Grand Kai's planet ten frames off is one lost frame and a blink seeded from the RNG, 2026-10-14

**Symptom.** `grand_kai_planet` (f19934) is SLIP +10 against mGBA and +11
against the second reference in all five dingbat configurations. The
references are IDENTICAL to each other. Ten frames is too many for one
frame-boundary race.

**Nothing accumulates.** Over the `[new]` timeline, dingbat-bios-nowl and
mGBA hash frame for frame at offset 0 through f19908 and again from f19943.
They differ only in f19909-f19942, inside the checkpoint's window, and
there only on Goku's face (box 118,67 5x3). Goku blinks for 15 frames out
of every 256. dingbat blinks at f19653 and f19909, mGBA at f19672 and
f19928, the second reference at f19673 and f19929. The checkpoint's centre
frame is eyes open in dingbat and eyes shut in both references, and the
classifier's nearest match is ten frames away. The HLE (`dingbat`) hashes
as dingbat-bios-nowl on all 20,000 frames.

**The blink counter is a random number.** The counter is the halfword at
0x02031366 (Goku's object at 0x02031354, +18). A routine at 0x0800DFD4
adds one to it every frame, and the eyes are shut while its low byte is
above 0xF0. The scene's load seeds it at f17852 with the game's
`random(255)` (`bl 0x0803FACC`, state word at 0x03004A5C). The draw is
**0x92 in dingbat and 0x7E in both references**: 20 counts. The second
reference's load ends four frames earlier and its later pauses differ by a
frame, so it lands one frame from mGBA.

**The random state is one step behind.** The RNG word steps once per
main-loop iteration. It is equal in all three at every frame up to f15800.
At f15801 dingbat repeats a frame (its picture holds) and does not step. The
references step. dingbat's sequence then runs one step behind theirs to the
f17852 draw.

**f15800: a sprite frame that does not fit.** An NPC's blink starts there
(object 0x02032E64, counter low byte 0xF1). The new sprite frames (the
0x0800F38C path, three of them this frame) are unpacked by IWRAM code at
0x03000100-0x030002FF. With the mixer and the frame's game code, that
fills the whole frame: 0 cycles halted
(WAITCNT 0x4314, DISPCNT 0x1F40). The main thread reaches its V-blank wait
(Halt at 0x0803F422) in the next frame:

| from the f15800 V-blank to the wait | cycles | against the V-blank at 280,896 |
|---|---|---|
| dingbat-bios-nowl, dingbat (HLE, identical) | 287,222 | 6,326 late |
| mGBA, given dingbat's counters (below) | 281,681 | **785 late** |
| mGBA as run | blinks this NPC at f15798, 251k busy | 28.7k early |

mGBA does not reach f15800 in dingbat's state. Its object counters run
**two ahead** from f14442 (below), so its NPC blinks at f15798 and its
f15800 is an ordinary frame.

**The decisive test.** Load mGBA's f15500 state and `poke8` only dingbat's
values into the low bytes of the four object counters (0x0202FE52,
0x02032E76, 0x02033626, 0x02033A0A, each 2 lower). mGBA then unpacks the
sprite at f15800 too, misses the same V-blank by 785 cycles, holds its RNG
word over f15801, and draws the checkpoint as dingbat does. The centre
frame matches, and 56 of the window's 61 frames. The other 5 are the
background tile's 20-frame toggle, which mGBA shows one frame early through
the whole scene.

**Where mGBA's two counts come from.** These are two more frames of the
same kind. Each time, mGBA reaches the wait before the V-blank and dingbat
after it (the same game state in both):

| frame | what | dingbat to the wait | mGBA to the wait | ROM main thread, dingbat - mGBA |
|---|---|---|---|---|
| f14266 | a new sprite frame (the 0x0800F38C path) | 1,652 late | 3,055 early | +4,342 (+4,233 over 12,235 executions of PCs run equally often) |
| f14441 | the work after the A press at f14441 | 12,072 late | 777 early | +7,289 (+4,520 over equal-count PCs); IWRAM +4.9k is the mixer, which mixes more the later it runs |
| f15800 | the NPC blink, same state | 6,326 late | 785 late | +3,808 (+4,341 over equal-count PCs) |

The IWRAM unpacker costs the same in both, cycle for cycle (0x03000200
region: 108,567 against 108,689 at the same instruction count). The gap is
gamepak code. It is §68's pattern again, instruction for instruction: an
EWRAM word load from ROM code (`ldr r1, [r5, #16]` at 0x08007DCE,
0x08007DFA, 0x08007E20, 0x08007E4C; `ldr r0, [r1, #80]` at 0x0800DFD6)
costs 8-9 cycles in dingbat and 2 in mGBA. `slotexec.s` on the AGB SP
(row 9, §63) gives the console's price as dingbat's, with mGBA 5 short.

**The second reference** keeps dingbat's counters. At f14500, f15000 and
f15500, every object counter checked (eight objects) equals dingbat's. Its dialogue pauses fall
on other frames, but they net to dingbat's count. So it reaches f15800 in
dingbat's state and still makes the frame: its RNG steps at f15801, and its
f15799-f15800 pictures equal dingbat's. To do that it must run this frame
at least 785 cycles cheaper than mGBA, whose price for it is already below
the console's. It has no `trace`, so where it saves was not measured. §63
measured the likeliest place: on gamepak code its prefetch buffer keeps
refilling, which alyosha prefetcher_full_arm and _branch_thumb_4
(hardware-verified) refute.

**Status: (b), no core change.**

* The ten frames are one lost main-loop iteration at f15800, carried by the
  RNG into a 256-frame blink phase. They are not ten frames of load time.
* mGBA's frame rests on EWRAM data accesses from gamepak code priced below
  the console's (§29, §63, §68), at f14266 and f14441. It loses f15800
  itself when it is put in dingbat's state.
* The second reference's frame needs that frame cheaper still than mGBA's.
* The exact cells are at WAITCNT 0x4314, which an empty-slot probe cannot
  run (§39, §66). The rule that decides it (`slotexec.s` row 9) is already
  measured, so no new probe is proposed.
* The HLE and Nintendo's BIOS run the f15800 iteration in identical cycles,
  so the HLE is not involved.
* A SLIP passes, so no `@known` is added. The checkpoint judges Goku's
  blink phase. A frame outside the blink, or a still NPC-free view, would
  make it diagnostic.

**How it was found.** The script was replayed to f20000 in
dingbat-bios-nowl, the HLE, mGBA and the second reference: per-frame
hashes, a state every 500 frames, and a RAM dump of each state.

1. Matching per-frame hashes put the difference only on the blink.
2. Dumps at f19600-f19602 found the per-frame counter that is 19 / 20
   apart. `watchw` on it found the `random(255)` store at f17852.
3. The RNG word, peeked every frame, parts at f15801.
4. `trace` from f15797, split into the main thread and interrupts, found
   the f15800 overrun.
5. The object counters across the states found mGBA's lead. `trace` of
   f14263 and f14441 found the two frames where it comes from.
6. The `poke8` run closed it.

## §79. The console cells nobody reproduces, worked from the recorded data alone, 2026-10-14

Seven items had been filed as "the console answers, no emulator does":
- hdmaobus's six racing cells
- the post-DMA open-bus window
- the halted H-blank wake +19
- the ÷64 timer phase
- the HLE's call costs
- the sound FIFO at timer periods 1-3
- dbsuite's six reds (878/884)

No console run was made. Each item was put against every recorded cell of
its kind, not only the missed ones. The outcome:
- one is a checker fix;
- four were already matched and their entries are stale;
- the FIFO and PSG ones have no law.

Their probes are designed. Each probe's predictions are written down below
and in its payload header, before any console run.

### 1. hdmaobus's racing cells are the arming poll's phase

**Why `0x104` scored a miss with dingbat's `0008E150` in the console's
set.** `rig.ask` stores a cell with several answers as one joined string:
`0008002C | 00081AFF | 0008E150 | ...`. `tables.check` compared strings, so
such a cell could never match, by design (rig.py: "it can never match an
emulator, which is the point"). That is right for a rig fault. It is wrong
for a race the payload builds in.

Scoring "dingbat's word is in the set" would be wrong in both directions:
- five of dingbat's six words are in their sets, but `0x103`'s `E1C6` is
  not (the console's runs showed `002B 1AFF E150`);
- a different entry cycle would pass or fail other cells by luck.

**The phase.** The reader-first sled rows arm on line 40 after a VCOUNT
poll. The poll is ARM code in IWRAM: `ldrh` 3 + `cmp` 1 + `bne` 3 = 7
cycles, and the 1232-cycle line is 176 of them. So the poll phase at which
line 40 starts carries through every line change, and the link rig's entry
makes that phase random.

`tests/roms/payloads/hdmarace.s` is hdmaobus with a `probe_park` on line 37,
then d one-cycle NOPs ahead of the poll. In the emulators, d is the phase:
- d and d + 7 answer alike;
- every non-racing cell (k = 0, 1, writer first, halted) answers as in
  hdmaobus at every d.

dingbat (both BIOSes), the reader's halfword at k = 2..7:

| d | k=2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|
| 0 | E150 | E3A0 | 1AFF | E1C6 | 002E | E150 |
| 1 | E1D4 | 002B | E150 | E3A0 | 1AFF | E1C6 |
| 2 | E1C6 | 002B | E150 | E3A0 | 1AFF | E1C6 |
| 3 | E3A0 | 1AFF | E1C6 | 002D | E150 | E3A0 |
| 4 | 002A | E150 | E3A0 | 1AFF | E1C6 | 002F |
| 5 | 002A | E150 | E3A0 | 1AFF | E1C6 | 002F |
| 6 | 1AFF | E1C6 | 002C | E150 | E3A0 | 1AFF |

The words are the poll's bus words:

| word | what it is |
|---|---|
| `00LL` | the line number the `ldrh` loaded (DMA_READS_IO_LOAD) |
| `E150` | `cmp` |
| `1AFF` | `bne` |
| `E3A0`, `E1C6` | the two opcodes the taken branch's refill fetched past it |
| `E1D4` | the `ldrh` itself; reached only at k = 2 |

| cell | console (3-9 runs) | dingbat over d = 0..6 | mGBA over d |
|---|---|---|---|
| 0x102 | 002A 1AFF E150 E1C6 E1D4 E3A0 | the same six | 0000 0001 FFFC |
| 0x103 | 002B 1AFF E150 | + E1C6 E3A0 | same three |
| 0x104 | 002C 1AFF E150 E1C6 E3A0 | the same five | same three |
| 0x105 | 002D 1AFF E150 E3A0 | + E1C6 | same three |
| 0x106 | 1AFF E150 E1C6 E3A0 | + 002E | same three |
| 0x107 | 002F 1AFF E1C6 E3A0 | + E150 | same three |

In all six cells, every word the console gave is one of dingbat's:
- two cells match exactly;
- four have one or two words more. A cell asked 3 to 9 times will miss
  those, since each phase comes up at weight 1/7 or 2/7.

The test that could have failed is `E1D4`. dingbat gives it at one phase in
seven at k = 2 and never after, because the DMA's 10 cycles a line move the
phase off it. The console showed it at `0x102` and in none of the five
later cells. mGBA's words share nothing with the console's in any cell.

No model was touched. The race is four existing laws seen at random phases:
DMA_READS_CPU_BUS, DMA_READS_IO_LOAD, DMA_SEES_REFILL_FETCH and
DMA_PENDING_CHAIN. So these cells are now evidence for those laws, and
nothing was fitted to them.

**The change (tools only):**
- `r0table.RACES` maps a payload to its phase variant
  (`'hdmaobus': ('hdmarace', 12, 7)`).
- `tables.check` scores a racing cell of such a payload as a match when
  every console word is among the emulator's answers over the phases. A
  racing cell without a variant still cannot match (keyirq2 0x0).
- `lawrom.py` freezes those cells into `tests/roms/cyclelaws/hdmarace.gba`:
  42 words, each marked with its cell and the console's set.
- `cyclelaws_test` holds each set as one cell.
- The hdmaobus ROM and every other frozen ROM are byte-identical.
- Control: writing `0008DEAD` into 0x103's console set makes the test fail,
  as it should.

| | before | after |
|---|---|---|
| `r0table.py --check`, dingbat / dingbat-bios | 2001 / 2001 of 2025 | **2007 / 2007** (6 racing, by phase sweep) |
| `nimble test_cyclelaws`, HLE / Nintendo's BIOS | 2124 / 2124 | 2130 / 2130 |

The 18 misses left are keyirq2's 2 and keyirq3's 16 (§61, OPEN_ROWS).

**Predicted for a console run of hdmarace.s (none made).** The console
wakes from the park on the same cycle as the core (hdmaphase, halthb). If
so, each cell should be unanimous and equal to the table above. If the
wake differs by c cycles, the console's table should be this one with its
rows rotated by c. Either way, the prediction includes:
- the duplicate rows (d = 1 and 2 at k = 3..7; d = 4 and 5 everywhere);
- `E1D4` at only one (d, k).

The table is also in the payload's header.

### 2. The halted H-blank wake +19 was a row that never halted

The +19 is gbaedge p40 IRQDECOMP's hblank-haltcnt row (`agb-sp-5.txt`;
console `03DD`, dingbat `03CA` at the time).
- Its HALTCNT write is cartridge code, which the console ignores
  (haltprobe.s, §18). So the row is a running-CPU row anchored by a ROM
  poll of the H-blank flag, and dbsuite checks it ±32 for that reason.
- dingbat now reads it exactly (`03DD`, irqlat-hblank-haltcnt).
- The halted H-blank wake itself is pinned and matched under both BIOSes
  by halthb (sp-agb.json W `03EC`, D `03D4` at every k), breakram
  `--hblank` and wakeirq.
- irqlat-hblank and irqlat-vblank-haltcnt read +15, against photographs of
  a different ROM's layout, inside one poll quantum. That is not cycle
  evidence.

What has never been measured is a running CPU's H-blank interrupt timed
from a controlled cycle. `tests/roms/payloads/wakehb.s` is wakeirq.s plus
bit 7, which makes the source line 100's own H-blank (DISPSTAT bit 4, IE
bit 1). It is still entered from the V-count halt. Predicted, also in the
header:

| arg | dingbat, both BIOSes | mGBA | console, if the running rows were 15 early |
|---|---|---|---|
| 0x80 | 017003EF | 01B403F3 | |
| 0x90 | 000003EB | 000003F3 | |
| 0xA0 | 041903EC | 042003F3 | 040A03DD |
| 0xA8 | 03A803EC | 03B003F3 | 039903DD |
| 0xE0 | 0B3603EC | 0B3403F3 | |
| 0xA2 | 03EC0000 | 03F40000 | |

- Every bit-7 cell is its V-count twin less 0x5B2 (line 102 + 5, against
  1007 + 4).
- The exception is 0xE0, whose sled also takes line 101's H-blank.
- With bit 7 clear the cells are wakeirq's, with the sled shifted by the 4
  added cycles: 0x28 reads `095B` and 0x60 `0AFE` (recorded `095F` /
  `0AFA`).

### 3. The ÷64 phase is matched

The recorded cells are §19's timergeo (the console reads 19 19 19 18 19 19
19 18 on lines 100-107, where dingbat once read 19 everywhere) and
sp-agb.json's 24 timergeo cells.
- dingbat matches all 24 under both BIOSes; mGBA matches 7.
- The fix was 80a88cd2: the skip-BIOS entry at prescaler phase 776. That
  phase was pinned by alyosha timer/timer, where only phase 8 mod 64
  passes, not by timergeo.
- The LLE boot gives the same 24 cells.
- The law: one divider runs free from power-on, at a fixed phase against
  the video grid.
- ÷256 and ÷1024 still move with the frame (§19).

The console only brackets the line-103 edge, between e = 4 and e = 8.
These timergeo cells would pin it to the cycle. Predicted:

| arg | 0x46701 | 0x56701 | 0x66701 | 0x76701 | 0x86701 | 0x366401 | 0x376401 |
|---|---|---|---|---|---|---|---|
| dingbat | 001204BD | 001204BE | 001204BF | 001304C0 | 001304C1 | 001304EF | 001404F0 |
| mGBA | 001304BD | 001304BE | 001304BF | 001304C0 | 001304C1 | 001304EF | 001304F0 |

dingbat's edge is at e = 7 on line 103, and 16 cycles later for each line
earlier. Line 100's edge is at e = 55, which the last two cells test.

### 4. The HLE's call costs are matched

- SWITIME and SWIREGION (gbaedge 03, 0D) are byte-identical to the console
  under both the HLE and Nintendo's BIOS (`hwprobe_capture.py`: crc EF34,
  65E6).
- dbsuite bios is 47/47.
- No `--check` cell misses under the HLE alone.
- The old Sqrt and CpuFastSet gaps went with ccb964c5, e6a453d1 and
  df656c3e.

IWCYCLE +10 (`0A64` against `0A55`) is not a cost:
- every SWI 4/5 row of that page waits from a ROM VCOUNT poll;
- +14 and +28 use the same anchor and match;
- the console's +10 minus +28 is -8 cycles and dingbat's is +7, both
  inside one poll iteration;
- so the difference is the anchor's phase, and it is the same under both
  BIOSes.

### 5. The post-DMA open bus is matched

These recorded cells have all matched the console since 6f0ac75f and
83aa0391:
- obusprobe (8), obuswin (10) and obuswint (4, including `DEAD6019`);
- gbaedge 05 DMALATCH and 39 DMAOPENBUS;
- the dbsuite bus cases built from them.

The law: the DMA's word stays until the CPU's next bus access, per halfword
lane. §11's "still open" and the comment above the latch in bus.nim are
out of date.

One thing has never been measured: what a 16-bit DMA leaves in the lanes.
dma.nim puts the halfword in both. `tests/roms/payloads/obusdma16.s`
(`payloadcmp.py --block=0x02008000:13`) does a 16-bit DMA, one NOP, then a
read of 0x10000000, for IWRAM and EWRAM sources and both destination
lanes. The hypotheses, with predictions in its header:

| hypothesis | prediction |
|---|---|
| H1 | the halfword on both lanes (dingbat and mGBA, every row) |
| H2 | the source address's lane |
| H3 | the destination's lane |
| H4 | the bus width decides: IWRAM rows as H2, EWRAM rows as H1 |

The 32-bit control (+44) reads `DEADBEE3` under all four.

### 6. The FIFO at timer periods 1-3: no law

fifoffff's 264 cells (open-agb.json) measure the extra cycles the refills
cost a read, against n NOPs. On the console the refills come in groups:

| k | extras |
|---|---|
| 1 | 26 / 44 / 62 |
| 2 | 20, then 30 from n = 21 |
| 3 | 11 / 19 / 29 |
| 4 | 0 / 10 / 10 / 20 |

dingbat makes single 10-cycle bursts and scores 76/264 (fifospk 107/107).

A four-rule cycle model fits every k = 1, 2 and 4 cell, plus the tm /
tm_w0 / tm_ff / ob / ob_ff sets: 224/264 in all.
- A request lands 4 cycles after its overflow.
- The level is counted as each of the burst's words lands.
- A request in the burst's last cycle chains the next burst at 8 cycles.
- A request earlier in the burst is dropped.

It misses all 40 k = 3 cells. Their extras are odd, and every burst in
this family is 10 or 8 cycles, so no sum of bursts reaches them. A wider
rule grid reached k = 3 only by breaking k = 1 (best 144/184). It was not
prototyped in the core: a rule that fits three periods out of four is the
table tuning this round guards against.

`tests/roms/payloads/fifolog.s` is fifoffff with its one TM1 read replaced
by ten reads 3 cycles apart.
- A gap of 3 + L between samples is an L-cycle burst, so one run logs the
  whole refill stream.
- Sample 0 is fifoffff's own read and must reproduce the recorded cells.
  dingbat's sample 0 already equals its fifoffff answers.
- Keep to k <= 4 and the IWRAM source (the header says why).
- `tests/roms/payloads/fifolog-predicted.txt` has, for k 1-4 × w 0/3 × n 0,
  1, 11, 12, 20, 28, 29: the toy's answers, the k = 3 timeline's, dingbat's
  and mGBA's.

The deciding cells:

| cell | toy | k = 3 timeline | dingbat | mGBA |
|---|---|---|---|---|
| k = 3, w = 0, n = 0 | 24, flat gaps | 17, with a gap of 10 (an 8-cycle burst between samples 0 and 1) | 26, flat | 20 |
| k = 1, w = 3, n = 0 | 32 | – | 16 | 29 |

The w = 3 rows test the toy's chain rule against dingbat's rule of
counting the level after the whole burst.

### 7. dbsuite's six reds: four are the page's phase, two are the PSG

`tests/roms/dbsuite/run.py` on this tree scores 878/884: the same six reds
as results_dbsuite.md.

**dma/dmatime-burst-vram-mode3, bus/contend-pram-mode0,
contend-vram-mode0, contend-vram-mode2-locked-out.** These have the same
shape as §1, on a larger scale.
- The expected values are gbaedge photographs, and nothing in dbsuite
  fixes the dot each page starts on.
- Sweeping run_contend2's entry, the core reads all sixteen photographed
  CONTEND2 values at exactly one of 36 phases (72008a06). That fits sixteen
  values with one free parameter, not one parameter per value.
- The branch `worktree-agent-aa8ff0fb965ceea0e` parks those pages at that
  phase (865 at the time, bus 79/79). It is held for Matt's decision and a
  cartridge run.

**apu/psg-ch1-after-ch2-lives and sweeptrig-shift0-400-after-rows-d33.**
`tests/roms/payloads/psgrace.s` is the psgfirst page entered from a
V-count halt, then d NOPs (0..15) and c × 256 spin cycles (0..127, across
the 512 Hz sequencer). It sweeps 256 phases, against sp-agb.json's nine
psgfirst runs:

| row | console, 9 runs | dingbat over 256 phases |
|---|---|---|
| +0: first trigger missed | 3/9 | 64/256: fits |
| +16: the discarded first trigger missed | 3/9 | 66/256: fits |
| +8 (NR10 = 0 first): lives | 5/9 | 27/256 (P(>= 5 of 9) ~ 0.001) |
| +12 (after ch2's note): lives, the dbsuite case | 2/9, plus the photograph | **0/256** |

- +0 and +16 are a phase lottery, and dingbat's sets cover them.
- +12 is not a lottery. The trigger's distance from the master-on is fixed
  mod 16 there, so its position against the 2 MHz edge is 1, 2 or 4, never
  the 0 that escapes. dingbat lacks a rule here.
- d33 reads 0 on every console run, and both of dingbat's rules stop too
  late: C2 gives 1, and C3 stops two reads later still. Moving C2 would
  break the s0trig bit-14 laws it is fitted to.
- s0mode and s0path (138/216 missed, C2 everywhere) fall into about ten
  classes. These move with the master-on's phase, the distance from the
  wake, the cell before, and an NR10 write. No single rule anchored on the
  master-on fits them.

`tests/roms/payloads/s0age.s` asks what ends the slow timing. It is
s0long's no-halt path, with:
- k: a 16-phase sled;
- m: spins of 262144..1572864 cycles;
- bit 8: a ch2 length-16 note;
- bit 9: an NR10 = 0 write.

Predicted, the low byte at k = 0..15 (L = lives):

| hypothesis | prediction |
|---|---|
| H0, dingbat today (all 512 cells, both BIOSes) | every row `1 0 L F 7 7 7 3 3 3 L 3 3 3 1 1` |
| H1, the slow timing runs out by itself | rows with m >= 1 turn to C2 (`1 3 1 1` repeating, no L) or C3 (one L in four) |
| H2, a note ending by length ends it | only bit-8 rows with m >= 4 leave H0 |
| H3, an NR10 write ends it | bit-9 rows leave H0 at every m |
| mGBA | L everywhere |

Suggested console cells: 16 k × m ∈ {0, 2, 5, 7} × bits 8/9 = 256.

**Status: no core change.** What this round changed:
- tools/hwlink: RACES and the phase-swept check;
- lawrom.py and cyclelaws_test.nim;
- the cyclelaws freeze of hdmarace.

It also added the probes hdmarace, wakehb, obusdma16, fifolog and s0age,
plus the psgrace sweep, each run in the emulators only. With no src/
change, the train and the mGBA suite were not run.

## §80. Gradius Galaxies: stage 1 a frame behind is the load queue's service order, a phase race at one V-blank; the +1 was the classifier's sign, 2026-10-14

**Symptom.** In the baseline (main, 164 games) every dingbat configuration
is SLIP +1 at `stage1_enemies` (f4400) and SLIP -1 at `stage1_late` (f5472)
against both references, which are IDENTICAL to each other.

**One lag, not two.** Frame hashes over the frozen `[new]` timeline in
dingbat, dingbat-bios-nowl, mGBA and the second reference. dingbat and
dingbat-bios-nowl hash alike on every frame, so neither BIOS nor idle-loop
skipping is involved. dingbat is at offset 0 to both references from f3631
to f3768. From f3773 to f5600 every frame that places uniquely has
dingbat[f] = reference[f-1]: one frame behind, at both checkpoints. (About
half the stage's frames match no other emulator at any offset, and mGBA and
the second reference share only half theirs; the stage has some per-frame
rendering difference between all three.)

The opposite sign was `classify`'s. At `stage1_enemies` neither centre frame
is in the other's window, so it took the shared-frame path, which computed
`(k - a.centre) - (k' - b.centre)`: the negative of the centre match's
convention. A lag read -1 on one path and +1 on the other. In the baseline
this path decided 42 `[new]` checkpoints in 31 games (280 dingbat pairs, 29
reference pairs), so every shared-frame offset recorded before this section
has its sign inverted. **Fixed** (tools/playtest/classify.py, a case in
tests/test_classify.py). No verdict changes; only the sign of those offsets.

**What the game does.** The main thread is a background loader
(0x080136F4): it scans a 16-slot request queue at 0x03000028 (12 bytes a
slot: source, destination, a done-flag pointer), slot 0 to 15, calls the
LZ decompressor at 0x0800DE74 for each pending slot, sets its flag and
scans again. The game itself runs in the V-blank interrupt, with an
H-blank interrupt every line. Idle, a scan costs about 1,210 cycles of wall
time in dingbat and 1,195 in mGBA, interrupts included.

At the V-blank that ends f3755 the game queues seven requests, in slots 0
to 6. `peek` of the queue a frame later:

| | slot 0 (source 0x0826F8B0) | slots 1-6 |
|---|---|---|
| mGBA, second reference | already done | pending |
| dingbat | pending, done last (f3767) | slot 1 being decompressed |

**Where the scan stood** (`trace` of f3680-f3775 with the script's keys,
dingbat-bios-nowl against mGBA). When the V-blank interrupt came, mGBA's
scan had just loaded slot 14's word, so after the handler returned it
wrapped and found slot 0 first. dingbat's scan had loaded slot 0's word 16
cycles before line 160 (the scan began 46 cycles before it), found it empty,
and the interrupt was taken 11 cycles into the V-blank. After the handler it
went on at slot 1, so slot 0 waited for the other six.

**How the order becomes a frame.** The completions gate what the V-blank
handler starts next:

| | 65,629-cycle DMA from the V-blank handler | the 0x0801B job (~159k cycles) |
|---|---|---|
| mGBA | in f3769's V-blank | f3768, line 177 to line 106, 36k cycles to spare |
| dingbat | in f3768's V-blank | f3768 from line 2, still running at line 160 |

dingbat loses the f3768 game frame. Its V-blank count at 0x030007A8 holds
for one frame (0xEB4 at f3769, where the references read 0xEB5). From there
the stage runs a frame behind.

**The decisive test.** A scratch driver command stalls dingbat's CPU K
internal cycles at f3740 and changes nothing else (dingbat-bios-nowl, run on
to f5500). The results:

| K | first slot serviced | `stage1_enemies` / `stage1_late` against mGBA |
|---|---|---|
| 0, 40 | 1 | -1 (as shipped) |
| 80 to 400 | 0 (the references' order) | **0**: 30 of 60 frames and 58 of 60 match at offset 0, the rest nowhere |
| 440 | 3 | -3 |
| 480 | 2 | -2 |
| 520, 560 | 1 | -1 |
| 600 | 0 | 0 |

The outcome repeats every ~530 cycles of CPU time, one idle scan. The
order, and with it the lag (0 to -3 frames), is set by where the scan
stands, to within ~28 cycles (one slot's check), when one interrupt lands.
About seven phases in ten give the references' order, which is why two
emulators with different timing agree.

**Who is right: nobody can say.** The scan's own code costs the same in both
emulators slot for slot: 27.8 cycles (`ldr` from IWRAM, `cmp`, `beq`, four
ALU ops, `bge`). The loop around it costs 85.5 in dingbat and 79.2 in mGBA.
The difference is the pushes and pops to the IWRAM stack from ROM code:
`pop {r4-r7}` is 6 cycles in dingbat and 2 in mGBA, under the 5 cycles its
four data cycles and one internal cycle need (as §66). But the phase at
f3755 integrates every cycle the CPU spent since the main thread went idle,
76 frames earlier (about 170 scans a frame), plus every interrupt. A
one-cycle change to any of that moves the phase by ~170 cycles a frame. No
single console-measured rule decides it, and the console's own phase, with
its own history, would pick one of these orders as arbitrarily.

**Status: (d), no core change.** The race is the game's (an idle scan read
against an interrupt-time enqueue). Both checkpoints are SLIP, which passes.
The script's note on the unscored second pause now cites this section.

**How it was found.** `runhash` over the timeline in all four, matched within
±6 frames. Then `peek` of all IWRAM and EWRAM every frame f3750-f3790, which
found the V-blank count and the queue. Then `trace` from f3680 in dingbat
and mGBA, one frame per call so the script's keys stay on their frames: the
drivers' `trace` now takes N <= 0 as "append until -N frames have ended".
Last, the stall sweep, with a `stall N` command (`cpu.idle(N)`) in a scratch
copy of the driver.

## §81. Rockman EXE 4.5: save_screen's SLIP(+3) is the install's ten-frame lead, read through the cursor's blink, 2026-10-14

**Symptom.** `save_screen` (f5092, window 10) is SLIP +3 against both
references in all five dingbat configurations, and the references are
IDENTICAL. §70 left it alone ("SLIP need nothing"). Asked: is this
downstream of §39's install dice, or something separate?

**What the +3 is.** While the game waits on the save screen, the only
motion is the menu cursor's blink: three pictures held 5, 6 and 6 frames, a
17-frame cycle. The cycle runs in step in dingbat and mGBA, hash for hash,
from f5037 to f5088. At f5089 dingbat starts the screen's next animation,
and every frame after that differs from mGBA's within ±12. mGBA starts the
same animation at f5099. dingbat's centre frame is in neither reference's
run. mGBA's centre is a blink picture that dingbat showed at f5088-f5089,
three frames before its centre, so `classify` reports +3. The real gap is
ten frames, and dingbat is ahead.

**The ten frames are §70's.** EWRAM was peeked every frame from f4900 to
f5110 in all three. Every byte that varies follows one of two clocks:

- the bytes that follow the script's presses are at offset 0 in all three;
- the PET scene's sprite tables (0x0200DAC0-0x0200DB1F, §70's "sprite
  tables at 0x0200DAxx") have dingbat[f] = mGBA[f+10], at no other offset.

Peeked from f3400, that +10 holds unbroken from f3420 to f5090. It is the
install's end, ten frames early (§39), and no press since has resynchronised
it. The second reference's tables are at mGBA's offset, because its install
ends on mGBA's frame (§70). So the references agree here for §70's reason.

**The decisive test (§70's).** Run mGBA to f3200 and `poke8` dingbat's two
RNG words (0x02003F6C = 6F EA 25 47 91 8C 30 AC, 0x02003C84 = C1 B0 5D DF),
changing nothing else. mGBA then hashes as dingbat on every frame from
f4948 to f5272, the whole `save_screen` window included.

**Status: (b), no core change.** It is the same cause as `pet_greeting` and
`pet_menu`. The dice follow the boot's EWRAM clear and the title's EWRAM
passes, where dingbat's price is the console's (`slotexec.s`, AGB SP) and
mGBA's is 4-5 cycles short (§39). The checkpoint is SLIP, which passes, so
it gets no `@known`. The script's notes say what the +3 is. `saved` (f6258)
reads SLIP -3 against mGBA through the classifier's inverted shared-frame
path (the section above), so it is dingbat ahead there too, +3 with the
fix. It was not chased.

## §82. Super Mario Advance 3: 1-1 after a soft reset, 2026-10-14

**Why.** §36 left the script's 1-1 checkpoints (`shy_guys`, `column_top`,
`below_white_block`, the corpus's last FAIL) undiagnostic. On a blank cart
the first boot formats the 64 Kbit EEPROM (196 polled block writes), the
frame the boot ends on is the chip's programming time, and a settle sweep
flips 1-1 every 1-3 % of it. §36 asked for a route that does not depend on
it.

**The route: a soft reset after the format.** The script now holds
A+B+SELECT+START for frames 151-160. Every emulator's format is over by
then: the boot's first screens are at dingbat f89, mGBA f94 and the second
reference f84. The game's reset path is
`swi 1` (RegisterRamReset, r0 = 0xFF: all of EWRAM, IWRAM, palette, VRAM,
OAM and the I/O), `swi 0` (SoftReset), and in the crt0 a DMA3 fill of all
of EWRAM (0x85010000, 65,536 words, 458,761 cycles). The reboot finds a
formatted chip and does not format again. Held, the combination resets the
game again about 8.5 frames later, still inside the hold; the last reset
decides.

Evidence that the format no longer matters, dingbat-bios built at three
programming times:

| `EEPROM_SETTLE_CYCLES` | counters 0x030000DD / 0x03006B01 at f151 | frames f152-f560 equal to the 108368 build |
|---|---|---|
| 101000 | 0F 44 | all |
| 108368 (GBATEK) | 0A 3F | - |
| 115005 | 05 3A | all |

The same three builds reset at `yi_title` (f1460) instead: 910 of 910
frames equal. After the reset mGBA's counters equal dingbat's on all 409
frames, and 371 of its pictures are identical (the rest are fades); before
the reset its counters were 5 frames behind.

The rest of the script is the old timeline, 72 frames later: the reboot's
first screen is f166, the first boot's was mGBA's f94. The two START taps
that fell in the format are gone.

**The second reference came out two frames ahead: its driver.** After the
reset its RAM at f152 was dingbat's at f154, 4 bytes apart, and it stayed
two frames ahead. Its costs are not the cause. A payload run in all four
emulators (`payloadcmp` wrapper, emulators only) times each piece the same
to the cycle:

| | dingbat, dingbat-bios, mGBA, the second reference |
|---|---|
| the crt0's DMA3 fill (0x8500/0x8501, count 0, IWRAM -> EWRAM) | 458,761 |
| the same after RegisterRamReset(0x80) | 458,758 |
| DMA3 count 0, fixed source and destination in IWRAM | 131,081 |
| RegisterRamReset, EWRAM only / VRAM only / palette only | 434,431 / 64,767 / 927 |

With the reset at `yi_title`, the reset's EWRAM clear had reached the
same address in all three emulators at the end of f1461
(0x02024CDF-0x02024DBF).

The driver is the cause. Its `run_frame` runs whole lines to 159, then
4-cycle steps until VCOUNT reads 160. The core runs a DMA burst whole, so
a `Run` that starts one returns at the burst's end, however far past the
requested cycles. Logged at f152: the bulk `Run` started on line 160 and
returned on line 47. The 458,761-cycle fill had begun on line 131 and
crossed two V-blank starts. The steps then went on to the next line 160,
so one harness frame held three V-blank starts. The first boot loses one
the same way: its frame 1 starts on line 225 with the crt0's fill.

**Fixed in the driver** (its `run_frame`, `tools/playtest/drivers/`). The
video device counts presentations, one per V-blank end. A frame that
starts on lines 160-227 holds one, a frame from below 160 none. Any extra
is a V-blank start the frame swallowed. That many following harness frames
are owed: they end at once, each with one frame's audio, so harness frame
n is the n-th V-blank start again. A `state_load` clears the debt.

After the fix the second reference's counters equal dingbat's and
mGBA's on every frame checked, from the reset to the story pages
(f152-f351, f2400-f3026). Its first boot shows its
first screen on f84, the 101000 build's frame (§36's "~101000" is its
programming time alone).

Frames 1-1500 with no input, old driver against new:

| | frames that differ | from |
|---|---|---|
| Metal Slug Advance | 0 | - |
| Super Mario Advance | 940 | f18 |
| Donkey Kong Country | 1,332 | f109 |
| Megaman Zero | 813 | f4 |
| Final Fight One | 1,232 | f4 |
| Super Mario Advance 3 | 701 | f81 |

The same 1,300 frames placed against dingbat-bios's (the offset of the
one dingbat frame within 3 that has the same hash; negative is the second
reference ahead):

| | old driver | new driver |
|---|---|---|
| Megaman Zero | 444 frames at -2 | 444 at 0 |
| Final Fight One | 365 at -2, 59 at -1 | 88 at -1, 59 at 0 |
| Donkey Kong Country | 718 at -3 | 560 at -1 |

So much of the boot lead that §65 measured for the second reference in
Donkey Kong Country is this accounting, not its timing. One frame of it
stays, and that frame is its own. §73's Koro Koro Puzzle boot lead was not
re-measured. The fix moves the second reference's frames in most of the
corpus, so the train's reference results need a fresh baseline.

**Verdicts** (all seven configurations, with audio):

| checkpoint | dingbat configs ~ mGBA | ~ the second reference | mGBA ~ the second reference |
|---|---|---|---|
| title_menu | IDENTICAL | IDENTICAL | IDENTICAL |
| choose_game | MINOR | MINOR | MINOR |
| yi_title | MINOR | IDENTICAL | MINOR |
| file_menu | IDENTICAL | IDENTICAL | IDENTICAL |
| story | IDENTICAL | IDENTICAL | IDENTICAL |
| stage_start | MINOR | MINOR | MINOR |
| shy_guys | MINOR | MINOR | MINOR |
| column_top | MAJOR | MAJOR | MAJOR |
| below_white_block | MAJOR | MAJOR | MAJOR |

All five dingbat configurations PASS. `choose_game` and the last four
checkpoints are noted "not diagnostic", because the references disagree
with each other there. At
`stage_start` all four show §36's white puffs on the first bush, and only
Yoshi's pose differs. At `shy_guys` the dingbat configurations are
pixel-identical to each other, and the 232-234 pixels that differ are a
Shy Guy that mGBA and the second reference have in view and dingbat does not.
By `column_top` both references have been hit (the 8-second timer), and
dingbat has not.

**What 1-1 now depends on: an RNG that adds VCOUNT.** At f4325, the frame
before the first Shy Guy (object at 0x03003430) moves, dingbat-bios's and
the second reference's IWRAM differ only in:

* bytes that also differ between dingbat's two BIOS configurations;
* 24 bytes of old stack below 0x03007CA8.

The Shy Guy then walks right in dingbat (target speed +0x59 at
0x03003448) and left in both references (-0x59, from f4326 in mGBA and
f4327 in the second reference).

Its walk is set by 0x08090070 (Thumb). That routine reads the halfword at
`[0x03007240] + 0x29CC` = 0x03004BD8. If its low two bits are 0, it turns
the Shy Guy to the facing stored at +0x9F. Then it takes the target speed
and a distance of `(rng & 31) + 32` from that.

0x08035648 writes the word:

    rng += ((VCOUNT + b) ^ b) ^ h

where b is a byte and h a halfword of game state at 0x03002200 + n, and
VCOUNT is read live from 0x04000006. It is called ten times a frame: once
on line 219, then once a line on lines 6-13 while the main loop waits.
Which line comes twice depends on the cycle the wait starts on.

**The decisive test.** Load mGBA to f4324, `poke8` the RNG's low byte with
its low two bits set to K, and change nothing else. For K = 1 the Shy Guy
walks left, as in mGBA's own run. For K = 0, 2 and 3 it walks right, as in
dingbat. The direction is a one-in-four draw.

The word is 0 until the game proper starts. It first counts at f1884, and
there all three emulators already differ: 0x1073 in dingbat, 0x1074 in the
second reference, 0x104D in mGBA. dingbat's own two BIOS configurations
part at f1943 (0x6ECE against 0x6ECF). Every later draw is a function of
every frame's sub-line timing since f1884. Like Castlevania's idle count
(§59), no two emulators share it, so a checkpoint showing a Shy Guy
compares random draws.

**Two smaller findings on the way:**

* *dingbat's HLE SoftReset is 812 cycles short* (class (a), not fixed
  here). `rundigest` (TIMEHASH) first parts dingbat from dingbat-bios at
  f152, the reset. RegisterRamReset(0xFF) returns on the same cycle in
  both. From the `swi 0` (0x0812F6F0) to the crt0's first instruction,
  Nintendo's BIOS takes 875 cycles and the HLE 63. `hle_bios.nim`'s plain
  SoftReset branch zeroes 0x03007E00-0x03007FFF and resets the banks, and
  charges no time for the clear. Fixing it would leave the RNG split above in
  place: the RNG would still differ from the references from f1884.
  **Fixed the same day:** the branch now charges `SOFTRESET_BODY` = 810.
  That is 812 less 2, because the HLE's first ROM instruction takes 22
  cycles where the BIOS's takes 20 (the refill is charged on the other
  side of the jump). The swi and the end of the crt0's first instruction
  now land on the same cycles in both, 42420537 and 42421432. The
  `rundigest` frames that differ from dingbat-bios in the 310 frames from
  f150 fall from 299 to 2. Both are reset frames (the keys are held, so
  the game resets twice), where only the entry instruction's start cycle
  differs.
* *mGBA's logic-frame counter.* 0x03006B01 counts one ahead in mGBA at
  f3027, f3067 and f3107 (11 frames after each story A) and at f4036. The
  second reference keeps dingbat's count. In the page turn traced at f3022,
  mGBA runs 88k instructions a frame where dingbat runs 68k. This is the
  cheap-load pattern of §66 and §68. It was not traced to a law, and it
  does not change the classification above.

**Classification.** The EEPROM's programming time is out of the script
(the route). The second reference's two-frame lead was the harness's (d),
now fixed. The remaining 1-1 difference is the game's VCOUNT-fed RNG:
(d), as §59. dingbat's HLE SoftReset is (a), fixed (`SOFTRESET_BODY`).

**Status: script and driver changed, no core change.** The script
(`7352d2bd...play`) carries the reset, the shifted timeline, and a header
saying why its last three checkpoints compare draws. The game's verdict is
PASS. No `@known` is needed while the references disagree there. If they
ever agree by chance, this section is the reason to add one.

## §83. Mega Man Battle Network 2: the title a frame behind is mGBA's boot clear and the second reference's double frame, 2026-10-14

**Symptom.** `title` (f690) and `main_menu` (f820) are SLIP -1 against both
references in all five dingbat configurations, with the references
IDENTICAL. They became visible with §65's driver fix. dingbat-bios is no
different: the cause is game code, not the BIOS.

**Where play parts: the boot, f7.** IWRAM and EWRAM were dumped every frame
from f0 to f260 in dingbat-bios-nowl, mGBA and the second reference. All
three are equal to f6. From f7 mGBA's RAM is dingbat's of one frame later.
The second reference's equals dingbat's exactly at f8 and f9. Its f10 is
mGBA's f10 (30 EWRAM bytes apart) and dingbat's f11. The picture shows it
from f202, at offset -1 to f759.

**mGBA: the EWRAM clear (§39's loop).** The boot clears IWRAM (0x7E00 bytes,
22 cycles an iteration in both), then 256 KB of EWRAM with the same Capcom
library loop as Rockman EXE 4.5. Here it is at 0x080001C8: `subs r1, r1, #4;
str r2, [r0, r1]; bne`, ARM from ROM under WAITCNT 0x45B4 (WS0 3/1,
prefetcher on).

| | an iteration | 65,536 iterations | the clear ends |
|---|---|---|---|
| dingbat | 26 | 1,703,885 | 155,195 cycles after the f7 V-blank |
| mGBA | 22 | 1,441,782 | 173,988 cycles after the f6 V-blank |

The 262,103 cycles are mGBA's EWRAM store, the 4 cycles `slotexec.s` row 12
says it under-charges (console = dingbat, §63).

**Why a 0.93-frame difference costs a whole frame.** After the clear the
boot copies 0x15B8 bytes of code to IWRAM (35 cycles a word in both) and
starts the sound driver. That waits for VCOUNT 159 three times
(0x080E76A0: `ldrb r0, [VCOUNT]; cmp r0, #159; bne`). Each wait parks the
boot until line 159, so a boot that reaches the first wait in a given frame
leaves it at that frame's line 159:

| | clear end to the first wait | first wait entered | left |
|---|---|---|---|
| dingbat | 67,253 cycles | f7 + 222,448 (line 112) | f7's line 159 |
| mGBA | 65,907 | f6 + 239,895 (line 126) | f6's line 159 |

Everything after runs instruction for instruction alike, a frame apart. To
reach mGBA's wait, dingbat's boot would need 223,684 cycles less, 3.4 cycles
an iteration of the clear. **The decisive test:** a scratch driver with a
`poke8` lowered MEMCNT's EWRAM wait from 2 to 1 for the clear alone. The
clear then takes 24 cycles an iteration and ends 131k cycles sooner (line
179, after the f7 V-blank), and the first wait is entered within 8 cycles
of where it was. All 760 frames hash as before.

**The second reference: a harness frame that ran two.** Its EWRAM clear
costs what dingbat's does. At its f7 the code copy has done 99 of its 1,390
words, so its clear ended about 3.5k cycles before that V-blank. With
dingbat's 26 cycles an iteration and its own start (VCOUNT 225, 129 lines
more in frame 0 than dingbat's 126), the clear ends within 1.1k cycles of
that. The waits absorb the head start, which is why its f8 and f9 are
dingbat's.

The frame it gains is f10. The third VCOUNT-159 wait returns 894 cycles
before the f10 V-blank, and the next instruction starts a 16,409-cycle DMA
(the store at 0x080009D6) that ends on line 172. The driver (§65) ran whole
lines to 159, then 4-cycle `Run` steps until VCOUNT read 160. The core runs
the DMA in one step, so VCOUNT went from 159 to 172 and never read 160, and
the steps ran on to the next frame's line 160. A logging build counted
368,940 cycles asked for in that frame against about 280,200 in every
other. dingbat's and mGBA's frames end at the DMA's end.

**Fixed in the driver.** The 4-cycle steps now stop at the first VCOUNT of
160 or more (`tools/playtest/drivers/nba_driver.cpp`). With it the second
reference equals dingbat at offset 0 on every uniquely placed frame from
f202 to f859: `title` and `main_menu` are IDENTICAL to dingbat and SLIP -1
against mGBA alone. Hamtaro - Rainbow Rescue (the next section) and Donkey
Kong Country's first 1,400 frames hash exactly as before. Donkey Kong
Country's boot lead (§65) is not this.

A logging build of the fixed driver, run over the baseline's `[new]`
timelines, found frames that end past line 160 in 78 of the 164 games, 161
frames in all. In 28 games one is frame 0, which starts on line 225. Each
was a double frame in the baseline's second-reference runs, so from there
on that game's second reference was a frame further ahead. Castlevania:
Aria of Sorrow has them at f0 and f11, where §72 saw its three-frame
lead begin. Some of what §65 called the second reference's own boot lead
is therefore this. The baseline's second-reference results need recording
again with the fixed driver. dingbat is untouched.

**Who is right: dingbat.** mGBA's lead is its under-charged EWRAM store,
which `slotexec.s` measured on the AGB SP (§39 has the same caveat: the
console's cells are at 4/2, the game runs at 3/1). The second reference's
lead was the harness's.

**Status: (b) for mGBA, (d) for the second reference, no core change.** A
SLIP is a pass, so no `@known` line is added.

## §84. Hamtaro - Rainbow Rescue: the "Bye-Q" a frame early, the prefetcher read ROM through an SRAM store, 2026-10-14

**Symptom.** `bye` (f6212, after Quit > Yep-P) is SLIP +1 against both
references in all five dingbat configurations, with the references
IDENTICAL. It became visible with §65's driver fix. Every other checkpoint
is IDENTICAL in all three.

**Where play parts: the quit save, f6018-f6025.** Up to f6019 dingbat's RAM
is mGBA's every frame, apart from a fixed 19-byte set. From f6026 dingbat's
frame f is mGBA's f+1. In between the game writes its save: the routine at
0x081B79A0 sets WAITCNT's SRAM field to 8 waits (WAITCNT 0x4017: WS0 3/1,
prefetcher on) and copies 19,021 bytes from EWRAM 0x02001E78 to SRAM
0x0E002FE4 in a Thumb loop at 0x081B79BA-0x081B79C6:

    ldrb r0, [r5]; strb r0, [r4]; adds r5, #1; adds r4, #1;
    subs r3, #1; cmp r3, r1; bne

Traced from both emulators' f6016 states to the first halt:

| | instructions | cycles | halts |
|---|---|---|---|
| dingbat | 673,592 | 2,227,270 | 19,908 cycles before the f6026 V-blank |
| mGBA | 682,493 | 2,290,881 | 43,718 cycles after it |

Of the 63.6k-cycle difference, the loop is 60.8k (153,479 instructions in
both). The rest is +28.7k for dingbat at 0x080EC7xx and -19.7k in the IWRAM
interrupt handler, which mGBA runs more often in its longer save (35,189
against 30,489 instructions).

The loop's cost per instruction, averaged over 19,021 bytes:

| | ldrb (EWRAM) | strb (SRAM) | adds, adds, subs, cmp | bne | a byte |
|---|---|---|---|---|---|
| dingbat | 5.78 | 10.02 | 1, 1, 1, 1 | 7.98 | **27.78** |
| mGBA | 2.02 | 13.00 | 2, 2, 2, 2 | 7.98 | **31.00** |

**Why: dingbat's prefetcher keeps fetching through the store.** The SRAM
sits on the cartridge's own pins, so a CPU access to it must hold the
gamepak bus for its 9 cycles. dingbat prices it from the wait-state table and
leaves the prefetcher's clock (`rom_free_since`) alone. So the prefetcher
fetches ROM through the store as if the bus were free, and the four ALU ops
after it come out of a full buffer at 1 cycle each. dingbat only has to be
1.05 cycles a byte dearer (19.9k over 19,021 bytes) to miss the V-blank as
both references do.

**The rule that fixes it, tried and held back.** Branch
`sram-holds-gamepak-bus` (4889b3aa, `bus.nim` SRAM_HOLDS_GAMEPAK_BUS) adds
one rule. A CPU data access to 0E-0Fxxxxxx moves the prefetcher's free time
on by the access. It applies while the code runs from the gamepak with the
prefetcher on and not yet full. What the buffer held stays in it, and the
burst rules are untouched.

* **Hamtaro.** The loop costs 29.0 cycles a byte (ALU ops 1, 1.12, 1.12,
  2). The save takes 2,282,658 cycles and halts 35,490 cycles after the
  f6026 V-blank, so `bye` is IDENTICAL to both references. Every other
  checkpoint hashes as before. One other stretch moves, f2152-f2360 after
  the title's A: dingbat was a frame ahead of mGBA and two ahead of the
  second reference. Now all 87 uniquely placed frames are the second
  reference's, one behind mGBA.
* **A second scratch rule.** If the access also empties the buffer and
  pauses the prefetcher, as a gamepak data load does, the loop costs 31.8 a
  byte. The checkpoints are the same; the console can tell the two apart.
* **Gates.** `r0table.py --check` stays at dingbat 2001/2025.
  `nimble test_cyclelaws` gives 2124/2124 under the HLE and Nintendo's
  BIOS. `tools/ci_local.py`: 34 passed, 0 failed. With
  `knobsweep.py SRAM_HOLDS_GAMEPAK_BUS=false --suite`, 0 of 13,996 mGBA
  suite rows move (no row times an SRAM access from gamepak code).
* **The train** (20261014-151408-2c): CHANGED, 1 regressed, 51 neutral.
  Most of the neutral changes are audio in games that touch SRAM. Counting
  dingbat-bios's checkpoint verdicts against each reference, 7 get better
  and 15 worse.

**The regression: Dragon Ball Z - The Legacy of Goku II, a race the rule
only nudges.** `select_game` goes from IDENTICAL to DIFFERENT, so the game
FAILs. It is an EEPROM cart, but at boot it reads 0x0E000000 and
0x0E000001 (0x0800015E). Those two reads are the only instructions the rule
reprices before f785, 12 cycles in all. Under both builds, RAM is identical
at every frame checked from f5 to f780. At f784's V-blank one build takes a
second interrupt within its first handler's tail. The other leaves an
IWRAM poll at 0x03000224 first. Its main-loop counter (0x03000E20, +1 in a
V-blank routine at 0x0801F230) then misses f785, and the background's
animation phase moves for the rest of the run. That is a few-cycle race
carried from the boot, of the §4 and §59 kind. It does not argue either way
on SRAM pricing. Sonic Advance 3 `hub`, The Urbz and Castlevania - Circle
of the Moon `plank_shaft` (§59's idle-loop RNG) move by the same kind of
nudge.

So the corpus cannot decide the rule. Hamtaro's 20k-cycle margin moves onto
the references' frame, and races elsewhere move both ways. The rule stays
off main until the console answers.

**The probe: `tests/roms/payloads/sramloop.s`**, r0table row `sramloop`
(NEEDS_CART). **It needs the cartridge:** Hamtaro - Rainbow Rescue (A84P)
in the slot, the console booted holding SELECT+START. The payload checks
the cart's loop byte for byte, then runs it at the game's WAITCNT. It is
timed from IWRAM to the loop's own `pop {r4, r5}; pop {r0}; bx r0` home.
The bytes written are SRAM 0x7F00-0x7F3F's own, read into EWRAM first, so
the save is left as it was (bit 10 checks). The emulators run the payload's
copy of the loop from the wrapper's gamepak image, at the same word phase.
`python3 tools/hwlink/r0table.py sramloop 1 2 0x10 0x40 0x110 0x140 0x210
0x240 0x310 0x340 0x440 --emulators-only`:

| cell | what | dingbat, dingbat-bios | the held rule | mGBA | emptying rule |
|---|---|---|---|---|---|
| 0x1 / 0x2 | 1 / 2 bytes | 0x26 / 0x42 | 0x29 / 0x46 | 0x28 / 0x47 | 0x2E / 0x50 |
| 0x10 | 16 bytes | 0x1CA (458) | 0x1DC (476) | 0x1F9 (505) | 0x22C (556) |
| 0x40 | 64 bytes | 0x70A (1802) | 0x74C (1868) | 0x7C9 (1993) | 0x88C (2188) |
| | **a byte, (0x40 - 0x10) / 48** | **28.0** | **29.0** | **31.0** | **34.0** |
| 0x110 / 0x140 | prefetcher off | 0x262 / 0x952 (37.0) | the same | the same | |
| 0x210 / 0x240 | to EWRAM, prefetcher on | 0x16A / 0x58A (22.0) | the same | 0x149 / 0x509 (20.0) | |
| 0x310 / 0x340 | to EWRAM, prefetcher off | 0x202 / 0x7D2 (31.0) | the same | the same | |
| 0x440 | SRAM bytes changed | 0 | 0 | 0 | |

What the console's byte says:

* 28: the prefetcher reads through SRAM, and the old rule was right;
* 29: it waits the access out and keeps its buffer (the held rule);
* 31 or more: the access also costs the buffer or the burst (mGBA, the
  emptying rule), and the rule to land is the emptying variant.

The EWRAM rows are the control. On the console they should be dingbat's,
as `slotexec.s` found for EWRAM stores from gamepak code. Every
`bye`-moving answer (29 and up) keeps the checkpoint on the references'
frame.

**Status: (c), no core change on this branch.** The rule removes a bus the
prefetcher cannot have. But what the console charges is unmeasured, and
the train shows the corpus cannot settle it. `sramloop` with the Hamtaro
cart decides it. If the byte comes back 29 or more, the rule on
`sram-holds-gamepak-bus` (or its emptying variant, at about 31) is what to
land. A SLIP is a pass, so no `@known` line is added.

## §85. Rhythm Tengoku: the title's logo balls are drawn from an idle-loop RNG, and the references meet only on the settled logo, 2026-10-14

**Symptom.** In the baseline `f2a983d050ef-src-028dc3a8c6ea` (after §65,
§82 and §83's driver fixes) `title` (f996) is MAJOR against both
references in all four dingbat configurations. The references are SLIP 0
to each other ("the windows share a frame; neither centre does"), so the
game FAILs. §74 had filed it as "RNG/phase: the logo's bounce phase".

**Stable in every emulator.** dingbat-bios, mGBA and the second reference
each played the frozen `[new]` timeline twice for 1,100 frames. Each pair of
runs is identical on every frame, and every run reproduces the baseline's
`health` and `title` windows hash for hash. dingbat (the HLE) equals
dingbat-bios on all 1,100 frames.

**Where play parts: f692, five random draws.** EWRAM is identical in all
three emulators to the end of f691. At f692, 39 bytes in 20 runs differ, and
all three values differ at each one. They are the five logo balls' records
(28 bytes apart from 0x02005CDC) and three bytes each at 0x02003BC0 + 0x3C·k.
`watchw` finds the writer, 0x0801CBAE-0x0801CBCC. It fills each record with
`rand(20) + 150`, `rand(5) + 238`, `rand(32) - 16`, `rand(12)` and so on.
`rand(n)` at 0x08001980 is a 16-bit LCG at 0x030000B4, `s = s * 109 + 1021`,
returning `(n * s) >> 16`. The draws pick each ball's flight in and its
later bounces. The state going into the draws (end of f691) is 0x2A2F in
dingbat, 0x45B6 in mGBA and 0x44BA in the second reference.

The pictures are identical in all three from f3 to f854. The balls appear
at f855 (the second reference) and f856 (dingbat, mGBA). At f870 they are
in flight in three different places (pixels exact against mGBA: dingbat
73 %, the second reference 51 %). Over the title's 189 frames
(f855-f1043) the two references show the same picture on 22, dingbat and
mGBA on 19 (f940-f957, out of the window), dingbat and the second
reference on none. In the checkpoint's window the references meet on 22
frames from f1002 to f1026, once their logos have settled with the same
ball raised. That
is the SLIP 0. It is not the same draws.

**The RNG counts every idle cycle since f7.** The game's V-blank wait
(0x080013BC-0x080013D4, Thumb in ROM) loops on the bare LCG step at
0x08001964. Each pass also loads a ROM word from
`0x08000000 + (s << 2 & 0x3FFFC)` into `[sp]`. It stops when the V-blank
handler sets the halfword at 0x03000098. So the state is stepped once per
idle pass, and the LCG has full period 65,536. Each frame's steps can be
read back exactly from the per-frame peeks of 0x030000B4 in all three:

| | f7 (first counting frame) | f8 | a frame, steady screens | f9-f691 | total to the draws |
|---|---|---|---|---|---|
| dingbat (all configurations) | 227 | 2,311 | 2,200 | 1,489,941 | 1,492,479 |
| the second reference | 1,816 | 2,231 | 2,200 or 2,201 | 1,490,223 | 1,494,270 |
| mGBA | 359 | 2,370 | 2,261 | 1,531,481 | 1,534,210 |

One pass of difference already makes every draw another number. The
second reference differs from dingbat on 342 of the 683 frames f9-f691,
by one pass each time (+282 in all). Its first counting frame is 1,589
passes (≈159k cycles) longer. That is not its timing. It enters the ROM on
line 225 (VCOUNT 0xE1 before the first frame), where dingbat and mGBA
enter on line 126. Line 126 is the console's: bootio.gba's VCOUNT word
photographs it, and dingbat's skip-BIOS entry moved there in 9a3c7b7cd
(§4). So the
second reference's first frame runs 129 lines more of the boot before its
first V-blank. mGBA counts 61 passes a frame more than the other two.

**The pass's price**, WAITCNT 0x45B7 (WS0 N 4, S 2, prefetcher on), traced
on f25: dingbat 100 cycles, mGBA 98. The ALU ops cost 1-2 cycles in both.
dingbat's extra is the four fetches after the pass's four gamepak loads
(the two literal loads, the random ROM word, the flag's literal). It prices
each at N, 4 cycles: after a gamepak data load the prefetcher stays stopped
through the I cycle (alyosha prefetcher_branch_thumb_2, hardware-verified,
failed by both references; §29, §59). Idle time a frame: dingbat
2,200 × 100 ≈ 220.2k cycles, mGBA 2,261 × 98 ≈ 221.8k. So mGBA's frame
work is also ~1.6k cycles cheaper, the §29 and §59 kind of under-charge.

**Status: (d), no core change.** The checkpoint compares where five
balls land, drawn from a state that counts every idle cycle since f7. No
emulator is known to reproduce the console's count. The two references do
not share a state on any frame from f7, and the second reference starts
the count from another line of the frame. A probe could price the pass
again, but it could not decide 1.49 million passes. The script carries
`@known * checkpoint title:` citing this section, as §59 did for
Castlevania's bones. Every later checkpoint is unaffected in the baseline.

## §86. Final Fight One: intro_story a frame behind is §29's load, now that the second reference keeps mGBA's frame, 2026-10-14

**Symptom.** In the same baseline `intro_story` (f630) is SLIP -1 against
both references in all four dingbat configurations, and the references
are IDENTICAL. It passes the tolerance. §74 had it under "all three
differ" ("downstream: the load a frame late", §29). Since §82's driver fix
the second reference no longer sits elsewhere, so the slip is now
dingbat's alone.

**Stable.** Each of dingbat-bios, mGBA and the second reference was
replayed twice for 700 frames, and each pair is identical on every frame.
Each run reproduces the baseline's `intro_story` window hash for hash.
dingbat (the HLE) equals dingbat-bios on all 700 frames.

**Where play parts: f280, the same load as §29.** The second reference's
pictures differ from mGBA's only on f1-f4 (its boot), and its EWRAM equals
mGBA's at every frame f250-f319. dingbat's EWRAM equals both references'
to f279. From f281 its EWRAM at frame f is theirs at f-1, two bytes apart.
The first picture to differ is f315, the fade-in after the black loading
screen. From there to f700 dingbat's frame f is the references' f-1 on 369
of 386 frames, and the rest are static frames equal anyway.

**The margin**, traced f271-f282 in dingbat-bios and mGBA. The idle loop is
at 0x0800B422-0x0800B43A plus 0x0800BC32-0x0800BC3A. mGBA enters it at
cycle 263,333 of f280, **17,564 cycles before** the V-blank. dingbat enters
at cycle 26,684 of f281, **26,684 after** it. That is a 44,248-cycle gap.
§29 measured 17.6k and 26.2k on 2026-10-02, so dingbat's load is 0.5k
dearer since then. Summed over f272-f281, dingbat minus mGBA:

| code | dingbat − mGBA | per pass | why dingbat is dearer |
|---|---|---|---|
| the LZ decompressor into VRAM, 0x08045C90-0x08045D3E | +28,132 | | renderer contention on its VRAM reads and writes (console-measured, `contmap.s`) and the commit wait at its `ldrb`-then-`b` (console-measured, §29 `slotbranch`) |
| the EWRAM memset, 0x0806B85E-0x0806B86A | +6,308 | 38 / 26 | four EWRAM word stores are 24 bus cycles alone; `slotexec.s` on the SP = dingbat |
| a 32-byte copy, ROM to VRAM (`ldmia`/`stmia` ×2), 0x08000272 | +4,391 | 74 / 55 | the fetch after each gamepak `ldmia` at N (prefetcher_branch_thumb_2) |
| a halfword fill of VRAM 0x06008020-0x0600BFFF (`strh; adds; cmp; bne`), 0x0803DED4 | +2,097 | 14.28 / 14.03 | a quarter of its stores pay 5-6 cycles: the renderer's contention (mode 0, BG1-3 and OBJ on; `contmap.s`'s console map) |
| everything else | +3,320 | | |

Built with `-d:CONTENTION=false -d:BRANCH_COMMIT_WAIT=false`,
dingbat-bios still enters the idle loop **2,956 cycles after** the f280
V-blank (§29: 2.5k). That is still f315. Turning off two console-measured
rules does not reach the references' frame. The rest is the references'
data accesses under the prefetcher, below the bus floor.

The second reference has no `trace`, so its own margin is unmeasured. It
reaches the idle loop before the f280 V-blank as mGBA does. Its prefetcher
fails 5 of the alyosha prefetcher rows dingbat passes (§29).

**Status: (b), no core change.** Every cycle dingbat spends that the
references do not is a cost the SP has measured or a hardware-verified row
requires. It is §29 unchanged, now seen against two references instead of
one. A SLIP is a pass, so no `@known` line is added. The script's session
note ("dingbat-bios draws the caption box under the map black, mgba and
nba draw it solid blue") is this frame: dingbat's f+1 is the references'
f.

## §87. The Sims - Bustin' Out: the language screen a frame behind is the first boot's EEPROM format against mGBA's cheap memset, 2026-10-14

**Symptom.** `language` (f632, `compare=text`) is MAJOR against both
references in all four dingbat configurations, in the baseline with the
fixed second-reference driver. The references are IDENTICAL to each other.
Earlier the same day they were not (§65 removed the `@known` for that
reason), and §74 listed the checkpoint as "downstream: the boot's three
phases".

**Stable.** dingbat-bios, mGBA and the second reference each played the
`[new]` timeline twice for 700 frames. Each pair of runs is hash-identical
on every frame, and each reproduces the baseline's checkpoint hash. The
agreement is not host-clock noise. It is new because the second reference's
driver used to run frame 0 and its boot DMAs as double frames (§82, §83).

**What the checkpoint sees.** The flags scroll at 30 Hz, one picture held
for two frames. dingbat's window is mGBA's shifted by one frame:
dingbat[f] = mGBA[f-1] on every frame from f48 to f662. The text comparison
skips the hash-window test, and the flags cover different letters a frame
apart ("DeutEch" against "Deutsch"), so a one-frame lag reads MAJOR. Under
the pixel comparison the same windows would be SLIP -1.

**Where the frame goes: the boot reaches the main loop late.** The main
loop's V-blank wait (0x0801F970: clear bit 0 of a flag the V-blank handler
sets, then spin on it) is entered for the first time at f31 + 193,167
cycles in mGBA, 87.7k cycles before the V-blank. dingbat enters it at f32 +
82,829, after that V-blank. The 30 Hz cadence starts on the next frame,
f32 in mGBA and f33 in dingbat, so the phase is set there. Everything from
f3 to that wait is busy code with no V-blank wait, so every cycle on the
way counts. Two stretches matter, traced from f0 in dingbat-bios-nowl and
mGBA:

1. *The EEPROM format, f3-f12.* On a blank cart the game writes 22 blocks of
   its 64 Kbit EEPROM. Each write (0x0804CA80) polls the chip to ready, with
   a VCOUNT-counted timeout. Call to call, a block takes 115,686 cycles in
   dingbat (`EEPROM_SETTLE_CYCLES` = 108,368, GBATEK's "ca.") and 122,140
   in mGBA, which behaves as if its chip took ~114,800. At the last write
   dingbat is 115.5k cycles ahead of mGBA.
2. *The scene load, f23-f31.* From the first 0x08027xxx instruction to the
   first 0x08049xxx, both run the same 492,054 instructions. They cost
   1,963,949 cycles in dingbat and 1,737,699 in mGBA, +226.3k. Of that,
   192.5k is a memset at 0x08027A8A, `stmia r0!, {r1}; adds r3, #1; cmp r3,
   r4; blo`, from ROM at WAITCNT 0x4314 into EWRAM: 48,133 iterations at 18
   cycles in dingbat and 14 in mGBA (§29 found the same loop). mGBA's
   `stmia` costs 2 cycles, the fetch alone. An EWRAM word store is 6 bus
   cycles.

**The second reference prices the memset as dingbat does.** The loop was
rebuilt in a scratch payload (run from the `payloadrun` wrapper's gamepak
image at the game's word phase and WAITCNT, TM0 per run; not committed).
Cycles an iteration, (T(64) - T(16)) / 48:

| destination | dingbat, dingbat-bios | the second reference | mGBA |
|---|---|---|---|
| EWRAM, prefetcher on | 18.0 | 18.0 | **14.0** |
| IWRAM, prefetcher on | 14.0 | 14.0 | 14.0 |
| EWRAM, prefetcher off | 22.0 | 22.0 | 22.0 |
| `str r1, [r0]; adds r0, #4` body, EWRAM | 18.0 | 18.0 | 16.0 |

Its chip is faster instead. `eesettle` (§36) in the emulators: dingbat
108,362, the second reference **101,392**, mGBA 38 (it keeps a chip busy
only for a command of the width it settled on, so in the game it waits
~114.8k). Its RAM runs a frame ahead of mGBA's at f26-f30, and from f32 it
is on mGBA's frame. So the references reach the same frame by different
errors, or by different truths: mGBA with a slow chip and a store below
the bus floor, the second reference with a fast chip and the console's
store.

**The decisive test.** dingbat-bios built with other
`EEPROM_SETTLE_CYCLES`, the rest unchanged, over the first 700 frames:

| `EEPROM_SETTLE_CYCLES` | `language` | frames hash-identical to mGBA |
|---|---|---|
| 101,000 / 104,400 / 104,800 | IDENTICAL to both references | 658 (the second reference: 659) |
| 105,100 / 105,350 / 105,600 / 106,800 / 107,600 / 108,368 | a frame behind | 346 |

The other 42 frames are the boot's fades (f33-f46, f663-f687), where the
references also differ from each other. A chip that programs a block in
104.8k cycles or less, 3.3 % under GBATEK's figure, puts dingbat on the
references' frame. The HLE configurations are identical to dingbat-bios
here (the baseline's variants), and the BIOS plays no part.

**Who is right: not decidable yet.** The memset is the §29/§63 class. On the
AGB SP, `slotexec.s` row 12 makes an EWRAM `str` from gamepak code cost 4
cycles more than an IWRAM one. That is dingbat's and the second reference's
difference here, and mGBA's is 0. (The console's cells are at 4/2 in an
empty slot. The game runs at 3/1, the §39 caveat.) The chip's programming
time has never been measured (§36, §64, §67, §82). GBATEK's 108,368 is an
"approximately". The second reference's 101,392 and mGBA's ~114.8k are as
unsourced.

**The probe: `eesettle`, as it stands** (`tests/roms/payloads/eesettle.s`,
r0table row `eesettle`, NEEDS_CART). **It needs this cartridge**: The Sims -
Bustin' Out (ASIE, 64 Kbit EEPROM) in the slot, the console booted holding
SELECT+START, then `python3 tools/hwlink/r0table.py --record eesettle`.
Another 64 Kbit cart answers for its own chip only. Cells (n = 3, 2, 0, 1)
in the emulators:

| cell | dingbat, dingbat-bios | the second reference | mGBA |
|---|---|---|---|
| 3: the last block | FFFFFFFF (blank) | FFFFFFFF | FFFFFFFF |
| 2: the write DMA | 848 | 848 | 849 |
| 0: rewrite unchanged, to ready | 108,362 | 101,392 | 38 |
| 1: write the complement, to ready | 108,362 | 101,392 | 38 |

The cell is the settle time less 6. A console cell 0 of about 104,790 or
less puts `language` on the references' frame. Then dingbat's constant is
the error for this chip (class (a), a change to `storage/eeprom.nim`, with
Super Mario Advance 3, Klonoa and Starsky & Hutch as its other checks).
About 105,090 or more keeps dingbat's frame. Then the references are wrong,
mGBA by its store and the second reference by its chip, and an `@known`
belongs in the script. A spread between runs, or between cells 0 and 1, is
part of the answer (a chip that skips erasing an unchanged block).

**Status: (c), no core change.** The script's header now says why
`language` follows the chip. It stays a FAIL until the cell is recorded.
Separately, `compare=text` turns a pure one-frame lag into MAJOR, because
it never asks whether the hash windows share a frame. Testing the windows
first, as the pixel path does, would make this checkpoint a SLIP. That is a
harness decision, not made here.
**Made the same night (53668273):** a text-judged checkpoint whose picture
appears in the other side's window is now a SLIP. `language` reads SLIP -1
against both references and passes. The chip question above still stands.

## §88. Yu-Gi-Oh! - The Eternal Duelist Soul: start_duel forty frames off is a rock-paper-scissors draw, the RNG one step behind since the boot load, 2026-10-14

**Symptom.** In all four dingbat configurations, `start_duel` (f2956) is
SLIP +40 and `duel_field` (f3136) MAJOR against both references. The audio
differs from both in 10.4 % of the run, longest 1.51 s from f2970. The
references are IDENTICAL to each other at both checkpoints. `title` and
`continue_title` are §33's `@known`.

**Stable.** dingbat-bios, mGBA and the second reference each played the
`[new]` timeline twice for 3,200 frames. Each pair of runs is hash-identical
on every frame, and each reproduces the baseline's hashes at both
checkpoints.

**Where the 40 frames come from: one rock-paper-scissors round.** Before the
first duel the game decides who goes first with rock-paper-scissors. The
player's throw is the script's tap at f2446, and the opponent's comes from
the RNG. Up to f2475 dingbat's pictures are mGBA's at offset 0 or within
one 5-bit step (f2410: 9,306 px, f2460: 99 px, all one step). At f2478
dingbat's opponent has thrown scissors: "WIN !!". Both references'
opponents throw rock: "DRAW", and the round is played again on the next
taps, two taps at 20 frames each. Every later dingbat frame that places
uniquely is mGBA's frame 40 later (f2476-f2973), so the slip is that one
round. The duel's deck shuffle draws from the same RNG later,
so the dealt hand differs (`duel_field`). Every flagged audio window is from
f2565 on, after the throw.

**The RNG is one step behind from f582.** The word at 0x03000040 is a
per-frame LCG, stepped by the main loop, with bursts of extra draws. In
dingbat-bios, dingbat[f] = mGBA[f-1] on every frame from f583 to f2445 apart
from the draw bursts. That is §33's boot load (f575-f582): dingbat's load
ends 21k cycles after the f582 V-blank and mGBA's 55k before it, so the
loop's step is lost once and never made up. The pictures resync by f919,
but the RNG keeps the lost step. **The decisive test.** Run mGBA to f2441,
`poke8` the RNG word from its own 0xBDC894F1 to dingbat's 0x65803B82, and
change nothing else. mGBA's opponent then throws scissors, and `start_duel`
and `duel_field` are hash-identical to dingbat-bios. Of frames
f2441-f3165, 481 are identical (5 without the poke). The rest are within
one 5-bit step where checked (f2460, f2470, f2500, f2600, f2990, f3070),
except the opponent's deal (below).

**The second reference is on mGBA's frame by its boot lead, not by
mGBA's prices.** Its RNG equals mGBA's of the next frame from f3 to f572.
It enters the boot load a frame early (its last step before the load is at
f573, mGBA's and dingbat's at f574) and leaves it on mGBA's frame (the
frame counters at 0x03004890 change at f581 in both references, at f582 in
dingbat). So its load takes dingbat's eight frames, not mGBA's seven. That
fits §63's tables, where it prices EWRAM loads and stores from gamepak code
as dingbat and the console do. The lead from f3 is its own boot timing
(frame 0 starts on line 225, not the console's hand-over line 126, §4,
§65).

**A residue the checkpoints do not show.** After the poke, the RNG words
part for four frames, f2620-f2623, and agree again from f2624. In those
frames the opponent's cards are dealt, and the deal's names differ: "Mirror
Force" in dingbat, "Bell of Destruction" in the poked mGBA. The player's
hand is the same. The interleaving of the shuffle's draws with the
per-frame step depends on where in the shuffle the frame falls, the §59
kind of race. It was not traced further.

**Who is right: dingbat, as far as the console has been asked.** The frame
is §33's. Its loop's EWRAM `ldrb` under the prefetcher follows `slotexec.s`
on the AGB SP (§29, §63), and mGBA's price is below the bus floor. The
second reference's agreement is its boot lead, not a witness for the load.

**Status: (b), no core change.** The script now carries two `@known` lines,
for `duel_field` and the audio (`start_duel` is a SLIP, a pass). Its notes
say why the duel is not played.

## §89. Gunstar Super Heroes, Klonoa 2, Mario Party Advance: three text comparisons that read rounding and sparkles, 2026-10-14

**Symptom.** In the baseline `f2a983d050ef-src-028dc3a8c6ea` (the second
reference's driver fixed by §65, §82 and §83), three checkpoints fail in
every dingbat configuration with the references MINOR to each other:
Gunstar Super Heroes `new_data` (f1584), Klonoa 2 `pause` (f5449) and
Mario Party Advance `secret` (f7442). Before the fix the references
disagreed there too. All three are `compare=text`: the verdict is the OCR
text's similarity (dingbat 0.56, 0.71 and 0.54/0.58; the references 0.82,
1.0 and 0.80, exactly on the 0.8 threshold).

**Stable, and only in the OCR.** dingbat-bios, mGBA and the second
reference were each played twice more on the frozen scripts. In all three
games the checkpoint hashes, the 61-frame windows and the verdicts were the
same as the baseline's in every emulator (the OCR is cached by the
picture's bytes, so equal pictures read alike). But no two emulators show
the same picture at any of the three checkpoints. The references "agree"
only in what OCR reads. In pixels they are as far apart from each other as
from dingbat:

| checkpoint | dingbat ~ mGBA | dingbat ~ second reference | mGBA ~ second reference |
|---|---|---|---|
| Gunstar `new_data` | 4,395 px, all one step | 9,473 px, all one step | 7,539 px, all one step |
| Klonoa 2 `pause` | 8,462 px, all one step | 9,611 px, all one step | 3,342 px, all one step |
| Mario Party `secret` | 87 px | 50 px | 97 px |

**Gunstar `new_data`: the alpha blend's rounding.** EWRAM, palette RAM, OAM
and VRAM are identical in all three at f1584. IWRAM differs between dingbat
and the second reference only on the stack; mGBA alone is 2-3 behind on
four counters (0x030006AC, 0x030034D2, 0x030034F2, 0x030062D8). DISPCNT is
0x3741, BLDCNT 0x0264 (BG2 and the backdrop over BG1) and BLDALPHA 0x0510
(EVA 16, EVB 5) in all three. In every differing channel value dingbat is
one step lower, against both references: §72's truncation, which the SP's
blendprobe photographs show. So the second reference draws the same game
state 9,473 pixels a step brighter, and OCR reads dingbat's "NORMAL" in
Cyrillic. The windows share two frames at offset 0 in every pair, so the
menus no longer run out of phase, which was the script's reason for
`compare=text`.

**Klonoa 2 `pause`: the darken's rounding, over a frame the pause menu's
load lost.** The pause screen is still (one hash in each window). EWRAM is
identical in all three at f5449, and palette RAM, OAM and VRAM in dingbat
and mGBA. BLDCNT is 0x00DE (darken BG1-3 and OBJ), BLDY 9 (mGBA's
readback), inside WIN0 over lines 0-143. Every differing channel value is
one step, with dingbat lower: §40's darken rule, also photographed. Lines
144-159 (the HUD) are identical in all three, yet OCR reads its "1/30" as
"143o" in dingbat and "1:30" in both references.

IWRAM shows something the picture does not. A frame counter (0x03004CA0,
with 0x03004C8C and 0x03004CA4) and an RNG word stepped once a frame
(0x03000DA0) are one step behind in dingbat. They were equal in all three
at `gameplay` (f5178) and every frame to f5374, where START is pressed. The
counters then stop while the menu loads: for two frames in both
references, which resume at f5377, and for three in dingbat, which resumes
at f5378. Traced from the f5373 V-blank, in dingbat-bios and mGBA:

* f5375 is a BIOS decompression routine (0x1074-0x1130). The two price it
  to the cycle over 270k instructions.
* mGBA enters IntrWait (BIOS 0x340) at line 159 of f5376, **47 cycles
  before the V-blank**. dingbat enters it 7,575 cycles later, after its
  V-blank handler, and so waits a whole frame.

On the 395k instructions both run, dingbat is **302 cycles dearer**:

| | dingbat - mGBA |
|---|---|
| the two DMA3 copies into BG VRAM at lines 137 and 141 (1,024 halfwords IWRAM -> 0x0600E000, 2,572 against 2,052 cycles; 1,536 halfwords EWRAM -> 0x060008C0, 7,713 against 6,157; mode 0, four BGs) | +2,076 |
| a map loop at 0x080320E0 (`ldrb`, two `ldr`s and an `ldrh` of data, `strh` to VRAM), 540 passes at 48 cycles against 46 | +1,080 |
| f5374's V-blank handler and game code | +328 |
| a software divide at 0x08051748, 540 calls: its ALU ops take 1 cycle from a full prefetch buffer where mGBA takes 2; its `push`/`pop` cost more | -3,414 |
| the rest, spread | +232 |

* The DMAs are the renderer's contention on VRAM in drawn lines. It is
  console-measured (`contmap.s` cells in r0-agb.json, `dmavram.s`, §62),
  and neither reference models it.
* The map loop is §29's class: data accesses from gamepak code under the
  prefetcher, where `slotexec.s` sides with dingbat.
* The divide's 1-cycle ALU ops are the prefetcher_full behaviour of the
  hardware-verified alyosha ROMs, which mGBA fails (§29).

**The decisive test:** dingbat-bios built with `-d:CONTENTION=false` resumes
the counter at f5377, the references' frame. Its `back_to_map` window
(f5817-f5877) equals mGBA's on 61 of 61 frames, against 52 as built. That
SLIP(-1) against mGBA is this frame. The second reference shares no frame
there with either (its own phase, §77). The HLE configuration equals
dingbat-bios on all 61.

**Mario Party Advance `secret`: a star's sparkles, phased by the first
boot's EEPROM format.** Every keyboard checkpoint of the profile interview
(`name`, `hobby`, `comment`, `dream`, `secret`) has the same signature. 50
to 307 pixels differ, all in one box of about 25 by 45 pixels that follows
the star at the prompt, and the references differ from each other as much
as from dingbat. At `secret` the sparkles cross "Secret?", and OCR reads
them as letters. No frame matches between any pair from f1674 to f7472.

* *State, not rendering.* mGBA was loaded at f7300 and every IWRAM and
  EWRAM byte where it differs from dingbat was set to dingbat's (989
  bytes, `poke8`). It then draws dingbat's frames exactly, 142 of 142, to
  f7442. Its counter alone, or the 0x030029C8 table of particle timers
  alone, matches none or 2.
* *The sparkles' RNG.* The word at 0x0203A4B8 is stepped every 8 frames in
  the interview. dingbat and the second reference draw the same sequence
  (0xB9FE0000, 0xFE021F4A, 0x5FDA91D0, ...), dingbat 20 frames later (f884
  against f864) and later 16. mGBA's sequence is out of step from its
  second draw.
* *The 20 frames are the format.* A blank cart formats its 64 Kbit EEPROM
  at boot ("Saving...", from f484). dingbat built with
  `-d:EEPROM_SETTLE_CYCLES=101000` equals dingbat as built to f818, the
  format's end. From there it equals the second reference on every frame of
  f1152-f3272 and f3362-f7472. All five keyboard checkpoints are then the
  second reference's pictures bit for bit. A 115005 build matches mGBA on
  only 755 frames: mGBA also has lag frames of its own (its frame counter,
  0x03004400, is a frame ahead from f201, a load that dingbat and the
  second reference both lose).
* The six emulators' battery files are byte-identical (SHA-1 5082396c...),
  so the typed profile is the same everywhere.

**Who is right.** Gunstar and Klonoa 2's pictures are dingbat's: truncation,
photographed on the SP (§40, §72). Klonoa 2's lost frame is the
console-measured VRAM contention. mGBA makes the V-blank by 47 cycles; it
would miss by about 2,000 if it paid the contention, where dingbat misses by
about 255. The second reference was not traced; it resumes on mGBA's
frame. Mario
Party's sparkles follow the cart's EEPROM programming time. That is the
chip's, unmeasured, as in §36, §40 and §82. dingbat keeps GBATEK's 108,368,
and the second reference's boots place it near 101,000 (§82). The
existing probe decides it for this cart: `tests/roms/payloads/eesettle.s`
(r0table row `eesettle`, NEEDS_CART), with Mario Party Advance (B8ME) in
the slot and the console booted holding SELECT+START. `python3
tools/hwlink/r0table.py eesettle 3 2 0 1 --emulators-only` predicts:

| cell | dingbat, dingbat-bios | mGBA |
|---|---|---|
| 0x3 | FFFFFFFF | FFFFFFFF |
| 0x2 | 00000350 | 00000351 |
| 0x0 / 0x1 | 0001A74A (108,362) | 00000026 |

Whatever it says, a checkpoint on the sparkles compares the format's
time, not the profile.

**What changed: the scripts.** A text comparison is judged before the
window and one-step rules, so a picture that pixels would call MINOR
(colour-effect rounding, which the classifier exempts by design) or SLIP
can fail on what OCR makes of the rounding. §73 was the same. The three
scripts now judge these screens by pixels:

* Gunstar's `title`, `main_menu`, `difficulty` and `new_data` give SLIP 0
  (shared frames) or MINOR.
* Klonoa 2's `pause` gives MINOR (one step).
* Mario Party's five keyboards give MINOR (at least 98% of pixels equal);
  the typed text is covered by the save comparison.

Played in all four default configurations with audio and cross-loads, all
three games PASS. Re-judging the three games' stored baseline runs with the
harness's own `compare_checkpoints` and the new modes gives the same
verdicts, and every untouched checkpoint's verdict as stored.

A classifier rule would avoid the class instead: in `compare=text`, accept
a shared window frame or an every-pixel-within-a-step picture before
reading text. It is not made here, because `tools/playtest` is part of the
train's results key, so the change needs a fresh baseline.

**Status: no core change.** Gunstar and Klonoa 2's pictures are (b) (§40,
§72). Klonoa 2's lost frame is (b) (contention, §62). Mario Party's
sparkles are (d), and (c) for which programming time the cart has. Its
probe exists. No `@known` is needed: the checkpoints pass.
