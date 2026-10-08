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

Frame reuse (docs/nds/perf.md) compares a full render's inputs, the render
registers included, each time one is needed, so a mid-frame change forces a
redraw and a frame whose registers return to the last drawn values reuses
it; nds_perf_test runs 3d_render_timing with reuse and loop skipping on and
off (state, screens and sound identical).

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

## Sweep, before -> after

Homebrew, 600 frames, default script, against the compat table: ColecoDS,
NINTV-DS, SpeccySE, StellaDS (broken-ref-too/ref-broken) and Kekatsu
(differs 100 %) -> **ok**; DLDI benchmark 12.45 -> 0.05 %, Emulator
Examination 87.4 -> 0.85 %, DSMA stress test 100 -> 57 % (after-exit shots
now match). Counter-Strike 99.7 -> 16.6 % and nds-examples dual_screen
28.9 % -> ok come from the newer base (same with and without this branch).
Everything else pixel-identical to the base build, rttexample included.
nds-examples: 37 ok / ok-phase, the rest unchanged.

## 6. Firmware settings writes

The DS menu's settings and a game's Nintendo WFC setup program the firmware
flash; the image changed in memory only. Now `spi.firmware_dirty` marks it,
ndsrun `--firmware-out FILE` writes it, and wasm exports
`nds_firmware_len/_ptr/_dirty/_clean` let the web app keep it (docs/nds/web.md
"Firmware settings"; `nds_reboot` keeps the written flash). Test:
nds_periph_test firmware flash.

Not done: the GBA-slot cart's RTC (S-3511 on GPIO) for dual-slot games --
the GBA core's RTC is written against the GBA object, a port is ~400 lines,
and no DS game is known to read it (HGSS does not).

## 7. Load timing: Golden Sun: Dark Dawn and Pokemon Mystery Dungeon

Branch `nds-compat10`. Golden Sun: Dark Dawn's loads took longer than on
the reference (the title fade 9 frames late, menus ~10, the intro pages
35-53 frames behind) and Pokemon Mystery Dungeon's per-frame RNG started
2 frames early (docs/nds/commercial.md). Two probes measured both CPUs'
access costs against the reference, profiles of the games' loads in a
`-d:ndsdebug` ndsrun (`--prof`, `--trace9/7`, `--iolog`) showed which
costs mattered, and three changes followed. Evidence levels as in
docs/oracles.md: **GBATEK** (the spec), **run** (black-box reference
comparison), **Assumed**.

**Probes.**

- `tests/nds/src/disp_cpu9time` (new; build_3d.sh): ARM9 loops of 8
  accesses timed by a cascaded timer, 256 passes per cell (one bus cycle =
  100h), with the protection unit as the SDK sets it (main RAM cached and
  write-buffered, DTCM 0B000000h, ITCM at 0): LDR / LDRH / STR per region,
  cache misses, LDM, a load whose result the next opcode uses, code from the
  cache / uncached main RAM / ITCM / WRAM, a DMA started under a running
  loop, loads from uncached code. The cells are also left in RAM
  (02300100h) for nds_compat_test.
- `tests/nds/src/arm7_timing` rows 16-28 (new): ARM7 code in main RAM
  with main-RAM / WRAM data, and the wifi regions under WIFIWAITCNT 0030h
  and 0007h.
- `tests/nds/src/disp_cardtime` page 2 (new): a 200h-byte card read that
  the CPU starts polling only 0-8000h bus cycles after the ROMCTRL write.

**Found and changed.**

1. *ARM7 wifi accesses* (GBATEK; run agrees). WIFIWAITCNT (4000206h) was
   not implemented: every ARM7 access to 4800000h-4FFFFFFh cost one bus
   cycle. GBATEK: WS0 (4800000h-4807FFFh, the RAM) N = 10/8/6/18,
   S = 6/4; WS1 (4808000h-480FFFFh, the registers) N = 10/8/6/18, S =
   10/4, per halfword; the register is reachable only with POWCNT2 bit 1;
   the firmware sets 0030h. Now `timing.nim` wifi7, the register in
   bus7.nim, direct boot leaving 0030h. The reference measures exactly
   these (rows 22-28: 99 / 147 / 139 / 67 / 0030h / 163 / 99, ours the
   same). Pokemon Mystery Dungeon's ARM7 boot writes 5A5Ah / A5A5h over
   wifi RAM 04804000h-04805FFFh and reads them back, several passes from
   code in main RAM: one of its 2 frames.
2. *ARM9 single loads and stores* (GBATEK; run agrees). Ours charged the
   opcode's cycle and a load interlock on top of the access: an LDR from
   I/O cost 5 bus cycles, GBATEK's NDS9/DATA table says 4, the reference
   4. GBATEK's tables are whole-instruction times (its NDS9/CODE row and
   WaitByLoop table are, and it prints half cycles where it measured them),
   and "STR 1S+1N (not 2N, and both in parallel)". Now a single load/store
   overlaps the opcode's own cycle (`arm/cpu.nim` single_access,
   `bus9.nim` overlap9): I/O, WRAM and OAM 4, VRAM and palette 5 (LDRH 4),
   DTCM and cache hits 0.5, uncached main RAM 10 (the reference 9: GBATEK
   kept). GBATEK's load interlock ("1L", only when the next opcode uses the
   result) is not modelled (Assumed; the reference charges none either:
   rows UIO/UDT/UMC). With the code itself fetched over the bus from
   another region the access overlaps 2 bus cycles (GBATEK: "typically
   codetime+datatime-2"; the reference: 3). Golden Sun: Dark Dawn loads by
   polling the card with the CPU (ldr ROMCTRL, tst, ldr data, strcc): the
   CPU-polled rows of disp_cardtime went from 7-8 % slower than the
   reference to within 1 % (B200 1C43h -> 19BEh, reference 19F1h; B1K
   DE83h -> CA7Eh, reference CBC6h). HLE SWI cost fit refitted
   (`hle_bios.nim`: the BIOS's own loads got cheaper).
3. *ARM7 opcode fetch after a data access* (GBATEK for stores; run for
   loads). The ARM7 has one bus; ours kept a fetch sequential across a
   data access between two fetches, so code in main RAM paid S32 (2)
   where its next fetch must open a new burst (N32 9). GBATEK's cycle
   table makes the code half of STR nonsequential (2N); for LDR (1S+1N+1I)
   it leaves the fetch after the I cycle sequential. Now the fetch after
   any data access is nonsequential (`bus7.nim` break_fetch7). Rows
   16 / 17 / 19 / 21 (main-RAM code: 8 LDR, 8 STR, a word copy, 8 LDR from
   WRAM): before 117 / 109 / 38 / 45, now 173 / 165 / 52 / 101, reference
   157 / 157 / 49 / 85. GBATEK's STR-only rule gives 117 / 165 / 45 / 45
   and leaves Mystery Dungeon's RNG a frame early; the both-ways rule puts it
   on the reference's frames (below). The reference is still ~2 cycles
   cheaper per access (its main-RAM data is 3 cheaper than GBATEK's, rows
   6-7, kept).

**Found, not changed.**

- *Card transfer*: polling late changes nothing on either core: the card
  holds each word until it is read (page 2: identical to within 50 bus
  cycles on 8000h of delay). DMA reads stay 20 bus cycles a word (GBATEK's
  6.7 MB/s) against the reference's 23 (docs/oracles.md).
- *DMA and the CPU*: GBATEK says the ARM9 "can be kept running during DMA,
  provided that it is accessing only TCM (or cached memory)". Neither core
  does: a 4000h-word DMA under a SUBS/BGT loop from ITCM or the cache
  takes the sum of the two (rows DIT/DIC: C045h + C013h -> 1C019h here,
  CA78h + C014h -> 18A7Ah on the reference). Left: running the CPU on would
  put the games further from the reference, and no hardware run pins it.
- *ARM9 data-cache misses* (the rest of Golden Sun's gap). Ours fills a
  line in GBATEK's 23 bus cycles; the reference charges every cached access
  ~1.5 bus cycles and never misses (row MM, eight loads to one set: 0F01h
  there, BA80h here; docs/oracles.md: it keeps no cache contents either).
  Golden Sun decompresses with LDRB/STRB through the cache from ITCM code
  (01FF86C0h-01FF8900h, about a quarter of its load time). With line fills
  at 3 master cycles the title comes 9 frames *early* and the menus 4-6
  early; with GBATEK's 23 bus cycles 5 and 7-8 late. Kept GBATEK.
- *Code timing*: the reference runs cached code at 1.5 cycles an opcode
  and a taken branch at 4.5 (ours 1 and 3; GBATEK's WaitByLoop table, 4
  cycles a SUB/BGT pass with the BIOS cached, is ours), ITCM code at 1 with
  a taken branch at 2 (ours 3: the ARM946E-S refills two stages), uncached
  main-RAM code at 9 bus cycles an opcode plus a whole refetch per branch
  (ours 9.5 and 1). An ARM9 load from an empty GBA slot costs 4 bus cycles
  there, 20 here (EXMEMCNT's 10 + 6 + the 3-cycle penalty).

**Results** (`--rtc 2004-01-01`, real BIOS, the scripts in
docs/nds/commercial.md):

| | before | after | reference |
|---|---|---|---|
| Mystery Dungeon: RNG 020A604Ch first changes | frame 23 | 25 | 25 |
| Mystery Dungeon: RNG word frame for frame | 2 early to the end | equal for 10 600 frames (intro, quiz, naming) | |
| Golden Sun: logos dark | frame 181 | 181 | 182 |
| Golden Sun: title fade-in | 418 | 414 | 409 |
| Golden Sun: menu / naming scenes | +9 to +10 | +7 to +8 | |
| Golden Sun: logic counter 02079244h behind, intro pages (frames 4000-26000) | 35-53 frames | 22-29 | |
| SoulSilver p12 3000 / 5000 / 6000 / 6600 | e4b66d68 / 6cf51b7e / 5f7fa5c3 / dfb2fd6c | unchanged | 0 / 0 / 0 / 12 dots |
| SoulSilver p12 8000 | ae4536a1, 283 dots | 8971b401, 142 dots | |
| SoulSilver firmware boot: the logo | frame 86 line 16 | frame 86 line 7 | frame 84 line 0 |

SoulSilver 8000: walking downstairs now loads as fast as on the reference,
so the A presses hit Mom's text on the same page ("Professor Elm,"); the
142 dots left are the 3D room's edges. The HLE BIOS gives the same p12
shots. Mystery Dungeon's random choices still differ (the intro demo's
cast, then the personality): the game draws them from more than the RNG
word (thread bookkeeping and counters in its RAM differ by a frame's
fraction from frame ~30), so only cycle-level agreement would settle them.

Host instructions: SoulSilver p12 frames 100-6000 (identical frames on
both builds), -d:danger: 74.97 / 74.79 G before, 75.02 / 75.00 G after
(+0.1 to +0.3 %, within the run-to-run spread); frames 7300-8100 1.1 %
fewer.

## Left

- Hardware runs of `3d_render_timing` (when render registers are read) and
  `arm7_timing` (ARM7 branch and main-RAM costs) would settle the two
  GBATEK-vs-reference disagreements above; `arm7_timing` rows 16-21 and
  `disp_cpu9time` on hardware would settle the fetch-after-load rule, the
  ARM9 interlock, cached-code speed and DMA overlap (section 7).
- VRAM remapped during the render window, and the render budget delaying
  when a line samples its registers.
- The card's "dead" state after an invalid KEY2 command.
- The GBA-slot RTC. (The web app now stores the firmware image and shows a
  powered-off console: docs/nds/web.md.)
