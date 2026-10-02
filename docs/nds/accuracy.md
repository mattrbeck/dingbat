# DS accuracy round: power-off, 3D render timing, capture, card, boot lag

The open items left by the homebrew sweep (docs/nds/compat.md) and the
boot/3D/peripheral write-ups, taken one by one. Hardware facts are GBATEK
unless marked; black-box reference runs are rows in docs/oracles.md ("NDS
core", "NDS 3D engine"). Branch `nds-accuracy`.

## 1. Power-off

**Hardware.** Power manager register 0 bit 6, "DS System Power (0=Normal,
1=Shut Down)" (GBATEK "DS Power Management Device"). libnds's
`systemShutDown` (every program returning from `main`, START in most
examples, every emulator port without an SD card) gets the ARM7 to write it.

**Before.** The periph round had made the bit stop both CPUs and the clock
(`spi.power_off`), but the screens kept the last picture, frontends could
not tell, and the sweep's own frame loop spun forever on a stopped clock.

**Now.** `run_frame` / `run_until` blank both framebuffers once the bit is
set (and on every later call, so a state loaded in that condition is black
too); no sound comes out (the SPU stops with the clock). `powered_off()` on
the machine, `nds_powered_off()` in wasm (and "powered off" in
`nds_status`), "powered off in frame N" from ndsrun. Black is the unpowered
LCD (Assumed colour); the reference goes black the frame after the write,
ours from the write.

Test: `tests/nds_compat_test.nim` power-off (the ARM7's SPI writes: index,
then 4Ch; clock, CPUs, frame counter and SPU stand still; both screens
black; input does nothing).

Sweep (`--only` the ROMs that exit): ColecoDS, NINTV-DS, SpeccySE, StellaDS
broken-ref-too/ref-broken -> **ok**; Kekatsu differs -> **ok**; DLDI
benchmark (12.45 -> 0.05 %), DSMA stress test, Emulator Examination now
match after their exit (what differs is before it). 0.4-2.9 ms of CPU per
frame instead of ~18 for the spinning ports. The sweep scores
black-equals-black after a power-off as a match.

## 2. 3D render timing

**Hardware (GBATEK).** "Rendering starts 48 lines in advance (while still
in the Vblank period)", in scanline 214, into a 48-line cache; the display
takes a line from it at each line start from line 263 (= 0) on. The render
registers (DISP3DCNT, 0x4000330-0x40003BF) "are not swapped (so that values
must be kept intact during rendering, too)". So line y < 48 is drawn at line
214 with the registers then, line y >= 48 when the display takes line
y - 48.

**Before.** The whole frame was drawn at the first `render_line` after
V-blank (line 0's H-blank) with the registers of that moment.

**Now** (`gpu3d.nim` due_lines, draw_lines, render_reg_changing). Each
frame's 192 lines go into `frame` line by line in time: `due_lines(t)` is
0 before line 214, 48 from then on (Assumed: the cache fills at once),
then 49 + the display lines taken. A write that changes a render register
(DISP3DCNT bits 0-11 and 14, clear colour/depth/offset, edge, fog, toon,
alpha-test) first draws every line already due with the old value. The
rasteriser stays whole-frame: lines come from a full render (`ren.color`)
redone only when a register changed since, so a frame with no mid-render
change renders once, as before. The render budget's delay (RDLINES) does
not move when a line samples its registers (Assumed). VRAM remapped during
the render window is still read as it is when the full render runs.

**Test ROM** `tests/nds/src/3d_render_timing` (phases of 20 frames; top
screen = 3D only), checked in `tests/nds_3d_test.nim`:

| Phase | Writes per frame | dingbat (GBATEK) | reference |
|---|---|---|---|
| CLR | CLEAR_COLOR blue at 60, red at 200, green at 230 | red 0-47, green 48-108, blue 109-191 | blue everywhere |
| TOON | the same on toon entry 31 under a toon quad | the same bands | blue |
| FOG | fog off at 60, on at 200, off at 230 | fog 0-47 only | no fog |
| L nnn | blue at 100, red at line nnn | 150..213: red to 148, blue below; 214..262: blue 0-47, red to 148; 0/1/2: blue to 48/49/50 | red for 150 and 191, blue from 192 on |
| SWPD / SWPV | quad + SWAP_BUFFERS at 100 / 200, the bottom backdrop at 200 | swap at the next 192 either way | the same |

So the reference renders the whole frame with the registers as they are at
the start of V-blank (line 192), before any V-blank write; GBATEK puts the
start at 214 with live registers. Kept GBATEK; a hardware run of
3d_render_timing would settle it.

**rttexample is not fixed by this**, and could not be: it writes its
CLEAR_COLOR at line 192 right after `swiWaitForVBlank`, before line 214, so
under GBATEK's timing the previous pass (swapped at that V-blank) renders
with the new colour, exactly as before. The reference shows the author's
intended colours because it reads the register before the write (above);
the program's screenshot is an emulator's. If hardware latches the render
registers at V-blank start, GBATEK's description is wrong and both the
model and the ROM's expectations change: that is the user's call.

Every 3d_* ROM hash and SoulSilver 3000/5000/8000 are unchanged.
SoulSilver writes DISP3DCNT at lines 214-220 each frame, but only to
acknowledge flags (the value stays 0039h), so nothing re-renders.

## 3. Display capture (Counter-Strike DS)

Counter-Strike DS runs libnds's dual-screen 3D (POWCNT1.15 swapped each
frame, capture into C / D shown by engine B) and switches to one 3D screen
at frame ~27. On this base it no longer shows the wrong screen: after the
switch both cores show the game on top and the gamepad below. Left:

- the switch lands one frame later in ours (ref frame 27 shows the gamepad
  list on top for one frame, ours frame 28): CPU timing, not a capture rule;
- 16.6 % of the top screen differs by one 5-bit colour step in textured
  walls (texel rounding, the rasteriser's topic).

nds-examples `dual_screen` (same technique) is now **ok** (was 28.9 %);
`3D_Both_Screens` 0.63 % (rasteriser edges). The capture rules
(DISPCAPCNT sources, VRAM display mode, 3D source A) already agree with
the reference (docs/nds/3d-timing.md).

## 4. Card: nds-examples `eeprom`

The example re-reads the header with libnds's raw `cardReadHeader` (a 9F
dummy and a 00 command, ROMCTRL without KEY2 bits 13/22) after the boot left
the card in main mode, twice, and compares the copies.

GBATEK "DS Cartridge Protocol": in KEY2 command mode "any other command
(anything else than above B7h and B8h) ... returns an endless KEY2
encrypted stream of 00h bytes". The card decrypts the plain command with
its own stream (garbage, not B7/B8), and the console does not decrypt the
reply: the CPU sees the KEY2 stream, which keeps advancing, so the two
copies differ and the example prints "Please eject & reinsert DS card" --
which is what ours shows. The reference answers both reads with zeros
(identical copies: "Game ID:" empty, then EEPROM type -1). Kept GBATEK.
GBATEK's further detail -- after an invalid command the card stops
advancing KEY2 for commands and answers HIGH-Z then encrypted zeros, "a
state similar to the KEY1-phase" -- is not modelled: a homebrew program on
a flashcart sees whatever the flashcart does, and a dead card would fail
every later read of a program that sent one raw command (no program needing
the dead state is known). The save-chip
probe is no longer reached; ours presents a chip of the detected type to
any program (games need that), the reference none.

## 5. Firmware-boot lag (2 frames behind the reference)

The BIOS phase (power-on to the logo, 1.4 s) is ARM7-bound: the ARM9 waits
in the BIOS while the ARM7 sets up KEY1, runs the card handshake with its
secure-area delays (6 x 26 ms on timer 3), decrypts the firmware and runs
two ~100 ms CRC16 passes (BIOS 0x2600) with SPI flash reads between. Ours
reaches the logo at frame 86 line 16, the reference by frame 84 line 0.

`tests/nds/src/arm7_timing` (new; ARM7 loops timed with timers, 256 x a
pass's cycles per row; checked in nds_compat_test) against the reference:

| Row | dingbat | reference | GBATEK |
|---|---|---|---|
| Thumb / ARM SUB+BGT pass | 3 | 3 | 4 (WaitByLoop: 20BAh passes per ms) |
| 8 MOV + SUBS/BGT | 11 | 11 | |
| 8 LDRH from ARM7 WRAM + loop | 27 | 27 | |
| 8 LDRH from main RAM + loop | 91 | 67 | 1S + N16 (9) + 1I = 11 each |
| 8 LDR / 8 STR main RAM + loop | 99 / 91 | 75 / 75 | 12 / 11 each |
| LDMIA 8 main RAM + loop | 29 | 26 | N32 + 7 S32 + 1S + 1I |
| 8 MUL, BL+BX, untaken branch, main-RAM loop | 19, 8, 5, 10 | the same | |
| BIOS WaitByLoop pass, GetCRC16 WRAM / main RAM (512 B) | 3, 6Bh, 73h | 3, 6Bh, 70h | 4 |

Found: the reference makes ARM7 nonsequential main-RAM data 3 cycles
cheaper than GBATEK's NDS7/DATA row ("Main Memory is ALWAYS having the
nonsequential 3 wait PENALTY (even on ARM7)"). With its costs our logo
comes at frame 85 line 92, 0.7 frames earlier; kept GBATEK. The other
~1.3 frames are not found: every other ARM7 access kind measured matches.

Also found, not changed: both cores charge an ARM7 SUB/BGT pass 3 cycles,
GBATEK's WaitByLoop table and the ARM7TDMI's B = 2S + 1N say 4 (the GBA
core in this repo, measured on hardware, charges the discarded prefetch).
Charging it (bus7.nim fetch_cost7: one more sequential fetch in the
branch's region) gives 4 everywhere, leaves SoulSilver 3000/5000/8000
unchanged, but moves the firmware-boot logo to frame 90, the periph_suite
SPI busy rows off the reference (304 vs 298 at 1 MHz) and the HLE SWI cost
fit (hle_bios.nim) off the BIOS. A decision for the user.

## 6. Firmware settings writes

The DS menu's settings and a game's Nintendo WFC setup program the firmware
flash; the image changed in memory only. Now `spi.firmware_dirty` marks it,
ndsrun `--firmware-out FILE` writes it, and wasm exports
`nds_firmware_len/_ptr/_dirty/_clean` let the web app keep it (not wired
in the app yet). Test: nds_periph_test firmware flash.

Not done: the GBA-slot cart's RTC (S-3511 on GPIO) for dual-slot games --
the GBA core's RTC is written against the GBA object, a port is ~400 lines,
and no DS game is known to read it (HGSS does not).

## Left

- Hardware runs of `3d_render_timing` (when render registers are read) and
  `arm7_timing` (ARM7 branch and main-RAM costs) would settle the two
  GBATEK-vs-reference disagreements above.
- VRAM remapped during the render window, and the render budget delaying
  when a line samples its registers.
- The card's "dead" state after an invalid KEY2 command.
- The GBA-slot RTC; the web app storing the firmware image and showing a
  powered-off console.
