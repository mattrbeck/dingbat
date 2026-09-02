# GB test suites: sources, scoring, and what their authors state

The test ROMs' own sources state the hardware behaviour they measure, usually
in cycles. This doc records, per suite: where it comes from, how the runner
scores it, which silicon it was verified on, which rows are deliberately not
scored and why, and the hardware claims the sources make that dingbat's PPU,
APU and cart models are built on. Pass counts live in `tests/results*.md`.

## Pinned sources

| Suite | Upstream | Revision in the bundle | Where the claims are | License |
|---|---|---|---|---|
| gbdev shootout | `gbdev/GBEmulatorShootout` | `38b926b` | `testroms/*.py` `description=`, `test.py`, `util.py` | see upstream |
| Mealybug Tearoom | `mattcurrie/mealybug-tearoom-tests` | `70e88fb` | `the-comprehensive-game-boy-ppu-documentation.md`, `src/ppu/*.asm` headers, `expected/`, `photos/` | MIT |
| daid | in-shootout, `testroms/daid/` | `38b926b` | `*.asm` + `expect:` byte tables | see upstream |
| Mooneye | `Gekkio/mooneye-test-suite` | `8d742b9d55` | per-test `.s` headers, `README.markdown` "Test naming" | MIT |
| Mooneye (wilbertpol fork) | `wilbertpol/mooneye-gb` | bundle `v7.0` | per-test `.s` headers | MIT |
| blargg | `retrio/gb-test-roms` | HEAD | `oam_bug/readme.txt`, `oam_bug/source/*.s` | none stated |
| SameSuite | `LIJI32/SameSuite` | `f71b4b3c37` | per-test `.asm` headers, `apu/README.md` | MIT |
| GBMicrotest | `aappleby/GBMicrotest` | `f3b55497c1` | per-test `.asm` headers, `README.md` | see upstream |
| gambatte testrunner | `sinamas/gambatte` `test/hwtests` | bundle `v7.0` | file names encode the expectation | GPL-2.0 |
| AGE | `c-sp/age-test-roms` | bundle `v7.0` | per-test source | see upstream |
| rtc3test | `aaaaaa123456789/rtc3test` | `80ae792bf1` | `tests.md` (the spec; `README.md` is a stub) | see upstream |
| BullyGB | `Ashiepaws/BullyGB` | `e24fe6fd7f` | `src/tests/*.asm`, `TestRoutines::` in `src/tests.asm` | see upstream |
| strikethrough | `Ashiepaws/strikethrough.gb` | `7cd01bf916` | `src/main.asm` (README is one sentence) | see upstream |
| acid | `mattcurrie/{dmg,cgb}-acid2`, `cgb-acid-hell` | `8a98ce731f` / `04c6ca40cf` / `107b7c5a87` | `README.md` feature maps | MIT |
| CasualPokePlayer | `CasualPokePlayer/test-roms` | per-test branches | branch `README.md` (`# Conclusion` where present) | see upstream |

The c-sp bundle (`/tmp/dingbat-test-roms/game-boy-test-roms/`, version
`GbBundleVersion` in `tests/dingbat_test_runner.nim`) ships a
`game-boy-test-roms-howto.md` per suite naming the exit condition, frame
budget and the hardware the suite was verified on. No bundle howto records a
license; the column above is from the upstream repositories where one exists.

## How the runner scores each suite

The verdict mechanism per suite (`TestMode` in `tests/dingbat_test_runner.nim`),
the device each suite is scored on and the screenshot conventions are in
[`tests/README.md`](../tests/README.md), "Which suites run, and how each is
scored". One fact about the shootout's own list belongs here: it scores 264
rows of which three ship no reference PNG and are classed `INFO`
(`acid/which.gb` on DMG and CGB, `daid/rom_and_ram.gb`), so its denominator is
261, and its mealybug list is `all = dmgs` — only the 24 DMG rows carry
shootout weight.

## Which silicon each suite was verified on

From each suite's `game-boy-test-roms-howto.md` and README:

| suite | verified on |
|---|---|
| blargg | DMG-CPU-08 (DMG-CPU C blob), CPU-CGB-02 (CGB B), CPU-CGB-06 (CGB E); `cgb_sound` fails on CGB B ("test case 3 fails with code 04") and passes C/E |
| GBMicrotest | "believed to be a DMG-CPU-08 … a DMG-CPU B or a DMG-CPU C" |
| gambatte | `dmg08` and `cgb04c` (DMG-CPU-08, CPU CGB C) |
| AGE | DMG-CPU-08, CGB B, CGB C, CGB E |
| scribbltests | MGB 9638 D and CPU CGB D |
| mealybug | per-device reference sets `DMG-blob`, `DMG-CPU B` (two tests only), `CPU CGB C`, `CPU CGB D` |
| strikethrough | no statement; the bundler's DMG-C and CGB B/C/E all pass |
| BullyGB | "most test cases are compatible to all Game Boy devices"; fails on the bundler's DMG-C with `Bad Echo RAM Reads`, CGB passes |
| rtc3test, cpp, mbc3-tester | cartridge tests, device-independent |
| dmg-acid2 / cgb-acid2 | "does not require any T-cycle accurate timing and thus *probably* works on any" |
| cgb-acid-hell | no compatibility statement; hardware photo in `img/photo.jpg` |
| mooneye | encoded in the file name (below) |

Mealybug revision splits, decoded from its own reference sets: `DMG-CPU B` vs
`DMG-blob` differs on `m3_lcdc_bg_en_change` (228 px) and
`m3_lcdc_win_en_change_multiple_wx` (3 px) only. `CPU CGB C` vs `CPU CGB D`
differs on `m3_scy_change` (6217), `m3_bgp_change` (864),
`m3_bgp_change_sprites` (716), `m3_window_timing_wx_0` (144),
`m3_lcdc_obj_en_change_variant` (144), `m3_window_timing` (138),
`m3_obp0_change` (42), and is identical for the other seventeen.

Mealybug's `expected/` images are the output of the author's emulator ("which I
believe to be correct"); `photos/` are the hardware. A disagreement of a few
pixels against `expected/` is settled by the photo only when it is structural
(a band present or absent), not positional.

Mooneye file-name convention (`README.markdown`, "Test naming"): `dmg`, `mgb`,
`sgb`, `sgb2`, `cgb`, `agb`, `ags`; revision letters `DMG: 0, A, B, C / CGB: 0,
A, B, C, D, E / AGB: 0, A, A E, B, B E`; group suffixes `G = dmg+mgb`,
`S = sgb+sgb2`, `C = cgb+agb+ags`, `A = agb+ags`. Revision 0 is its own machine
(`boot_div-cgb0` beside `boot_div-cgbABCDE`). "For now, the focus is on
DMG/MGB/SGB/SGB2, so not all tests pass on CGB/AGB/AGS."

## Rows deliberately not scored

The runner's `NotScored` ledger is the record, printed as "Deliberately not
scored" at the end of [`tests/results.md`](../tests/results.md); each entry
names its reason and its builder. Two things it does not say:

* The SGB rows. `samesuite/sgb/*` are scored (on `--sgb`; the adapter is
  `docs/sgb.md`). `cpp/sgb-ext-test` is not built as a row: its `NotScored`
  entry predates the adapter, and `docs/sgb.md` records the adapter passing
  it byte-exact outside the runner. Wiring it in is a runner change.
* Not a skip, but easy to misread: GBMicrotest's `hblank_int_scx*` and
  `int_hblank_halt_scx*` families encode a different overhead row from their
  `_incs`/`_nops` siblings (see "GBMicrotest" below).

## Mealybug: what the sources assert

Per claim (window enable cleared in mode 3, the 6-dot window startup, WX = 0
with SCX > 0, the WX 4/5/6 reactivation pixel, SCY sampling per revision, the
SCX high/low split, the CGB TILE_SEL glitches) and per test, with the dingbat
mechanism named against each:
[`docs/gb-mealybug-sources.md`](gb-mealybug-sources.md) ("The suite's PPU
documentation" and "Per-test: what the source asserts").

## Mooneye: header claims that are not in the file name

Every `.s` carries a `; Verified results:` block. These state a number or quirk
the name does not:

| Claim, quoted | Source |
|---|---|
| `(SCX mod 8) = 0 => LY increments 51 cycles after STAT interrupt` / `= 1-4 => 50` / `= 5-7 => 49` | `acceptance/ppu/hblank_ly_scx_timing-GS.s` — a three-band table |
| `line 0 starts with mode 0 and goes straight to mode 3` / `the PPU is late by 2 T-cycles` / `CGB before D: failure` / `CGB D, E, AGB, AGS: different failure than pre-D CGBs` | `acceptance/ppu/lcdon_timing-GS.s` — `LCD_ON_LINE0_TRIM` in `gb.nim` |
| `M = 0: write to $FF46 happens` / `M = 1: nothing (OAM still accessible)` / `M = 2: new DMA starts, OAM reads will return $FF`; restarted DMA: `M = 1: previous DMA is running (OAM not accessible)` | `acceptance/oam_dma_start.s` — two tables, fresh vs restarted |
| `TIMA register contains 00 for 4 cycles before being reloaded with the value from TMA. The TIMA increments do still happen every 64 cycles, there is no additional 4 cycle delay.` | `acceptance/timer/tima_reload.s` |
| `the timer circuit design causes some unexpected timer increases` / `BC < $FFF8 — Your emulator does not emulate the unexpected timer increases` | `acceptance/timer/rapid_toggle.s` |
| `These instructions take 12 cycles and also trigger the mentioned behaviour.` (`ldh (<DIV),a`) | `acceptance/timer/tim01_div_trigger.s` |
| `serial clock is divided from the main clock with a big counter, so clock edges align based on the reset time, not the time when SC is written to` | `acceptance/serial/boot_sclk_align-dmgABCmgb.s`; fails DMG 0 |
| `On CGB/GBA DI has a delay and this test fails in round 2!!` | `acceptance/di_timing-GS.s` |
| `If bit 5 (mode 2 OAM interrupt) is set, an interrupt is also triggered at line 144 when vblank starts` / `vblank and stat_m2_144 are triggered at the same time` | `acceptance/ppu/vblank_stat_intr-GS.s` |
| `The written value is $02, which clears the INTR_TIMER bit and cancels the interrupt dispatch. PC is set to $0000` | `acceptance/interrupts/ie_push.s` |
| `On DMG the sprite flags have unused bits, but they are still writable and readable normally` | `acceptance/bits/mem_oam.s` |
| `Bootrom duration on real SGB/SGB2 depends on the header bytes, including the global checksum` | `acceptance/boot_div-S.s`, `boot_div2-S.s` |
| `pass: DMG ABC, MGB, CGB, AGB, AGS` / `fail: DMG 0` | `acceptance/ppu/stat_irq_blocking.s` — DMG 0 split without a suffix |
| `Serving an interrupt is supposed to take 5 M-cycles.` | `acceptance/intr_timing.s` |

`acceptance/ppu/intr_2_mode0_timing_sprites.s` (pass on every model): its 90
testcases, quantised to M-cycles from a mode-2 STAT interrupt, pin the object
penalty table — N objects at X = 0 cost `11 + 6·(N−1)` dots; at other X the
first costs `6 + max(0, 5 − ((X+SCX) mod 8))` and each further object on the
same tile 6; X ≥ 168 costs nothing; the dedup key is per BG tile; objects are
evaluated sorted ascending by X. dingbat's `fifo_ppu.nim` object-trigger code
states the same table. The row additionally pins one dot of mode-3 end phase
with no slack (`testcase 2,0` wants the top of its 4-dot window, `testcase 2,3`
the bottom), which is the same quantity GBMicrotest and
`hblank_ly_scx_timing-GS` disagree about (see `tick_bg_fetcher`).

## SameSuite

Verdict: a `CorrectResults:` table byte-compared against a RAM buffer, then the
mooneye Fibonacci registers and `ld b,b` (`include/base.inc`). Only `apu/` has
a README; `dma/`, `ppu/`, `sgb/` and `interrupt/` are documented solely by
per-file headers.

The `apu/` sub-suite — its per-revision README, every ROM's stated claim
and the model built on it — is [`docs/samesuite-apu.md`](samesuite-apu.md).
The non-APU claims dingbat is built on:

| test | claim, quoted | dingbat |
|---|---|---|
| `dma/gdma_addr_mask` | "Addresses written to HDMA1-4 are masked. The lowest 4 bits of addresses are always ignored" | `hdma_dst and 0x1FF0` (Pan Docs, "HDMA") |
| `dma/hdma_lcd_off` (header copied verbatim into `hdma_mode0`, which enables the LCD) | "A single tile should get copied, and the count should decrement once"; HDMA5 reads `$02` then `$80` after `$00` | |
| `dma/gbc_dma_cont` | "partially initializing a new GDMA after the previous one ends normally" | |
| `ppu/blocking_bgpi_increase` | BCPD written in modes 0–3 reads back `$C5` every time: the index auto-increments even in mode 3 where the write is blocked; BCPS reads with bit 6 set ("TODO: what about bit 7?") | `0x40 or …` read, increment ungated by mode |

## SGB

The SGB adapter (`src/dingbat/gb/sgb.nim`, `docs/sgb.md`) implements the
packet transport and `MLT_REQ`; the three ROMs below pin what Pan Docs leaves
open, and `docs/sgb.md` "Transport" and "`MLT_REQ` joypad IDs" carry the
rules read off them:

- `samesuite/sgb/command_mlt_req.asm`: "Initial value always reads out as
  controller 1"; `MLT_REQ_1` "increments the player 5 times before it gets
  ANDed", `MLT_REQ_3` six times; unsupported mode 2 "has a glitched player 3".
- `samesuite/sgb/command_mlt_req_1_incrementing.asm`: P1 write sequences that
  advance the player index — `$10→$30` yes; `$20→$30` no; `$10,$20,$30` yes;
  `$10,$20,$10,$30` no; `$10,$10,$30` yes; `$00,$10,$30`, `$10,$00,$30`,
  `$00,$30` yes. Expected `$FE,$FE,$FF,$FF,$FE,$FF,$FE,$FF`.
- `cpp/sgb-ext-test` (`src/intro.asm`): 25 malformed `MLT_REQ` sends
  (corrupt STOP bit, skipped `$30`, first bit driven through intermediate P1
  values), each followed by a pad-count read-back; the verdict is only the
  reference PNG (256 bytes rendered as bits). The README publishes no
  conclusion.

## GBMicrotest

`README.md`: "All tests in this repo have been checked on real hardware
(version DMG-CPU-08 I believe)." `build.sh` assembles `-DDMG`; eight files
branch on `.ifdef DMG` and only that arm is in the binary. Tags: 128 files
`; pass - dmg`, 12 `; pass - ags`, 25 `; pass - ags, dmg`.

**The SCX mode-3 penalty is stated twice and the scored families split on
it.** `500-scx-timing.s` / `minimal.s` header:

```
; ags overhead 70?
; 0 0 0 1 1 1 1 2
; dmg overhead 65
; 0 1 1 1 1 2 2 2
```

(extra M-cycles of mode 3 for SCX = 0..7). `int_hblank_incs_scx*` and
`int_hblank_nops_scx*` encode the DMG row; `int_hblank_halt_scx*` and
`hblank_int_scx*` (with their `_if_d`/`_nops_*` siblings) encode the AGS row,
in ROMs all assembled `-DDMG`. dingbat implements the DMG row; the AGS-row
families pass on it because a halt-woken reader meets the mode-0 edge at a
different point of its M-cycle from a running one (`M0_HALT_BLIND_DOTS`,
`docs/gb-failure-triage.md` A5), not because half the suite runs as an AGS.

**Line 153** (`line_153_ly_{a..d}.s`): LY reads 152 at `nops 4`, 153 at
`nops 5`, and at `nops 6` `.ifdef DMG / RESULT 0 / .else / RESULT 153` — on
DMG, LY reads 153 for exactly one M-cycle. `line_153_lyc153_stat_timing_*.s`
(LYC = 153) and `line_153_lyc0_stat_timing_*.s` (LYC = 0) carry per-M-cycle
STAT tables: the LYC=153 coincidence holds for one M-cycle (`101 - C5`, `102 -
C1`), and the LYC=0 match appears during line 153 (`108 - c5` … `218 - c5`,
`219 - c4`). dingbat runs the STAT edge detector at the snapback and models
the read path's one-M-cycle blind window (`LYC_SETTLE_DOTS` in `gb/ppu.nim`).
`line_153_ly_c`, `line_153_lyc0_int_inc_sled` and
`line_153_lyc0_stat_timing_c` move together with `LCD_ON_LINE0_TRIM` — they
read the LCD-on dot phase, not the snapback.

**Timer interrupts** (`int_timer_incs.s`, `int_timer_nops.s`): TAC enabled with
TIMA = `$FE` and DIV freshly zeroed; the interrupt must land at `// 9 - int
fires on A`.

**Line 144** (`line_144_oam_int_{a..d}.s`): the four variants state the
expected IF byte at successive M-cycles (`$E0`, `$E0`, `$E2`, `$00`); at the
`_c` point IF has the STAT bit without the VBlank bit.

**Tables in verdict-less ROMs** (no row depends on them; they are the suite's
best dot tables):

`lcdon_write_timing.s`, explicitly AGS:

```
;   0 - dots
;  17 - dots  (last cycle of oam line 0)
;  18 - white (first cycle of vram on line 0)
;  60 - white (last cycle of vram on line 0)
;  61 - dots  (first cycle of hblank on line 0)
; 111 - white (last cycle of line)
; 112 - white (first cycle of oam on line 1)
; 131 - white (last cycle of oam on line 1, no hole between oam and vram)
; 132 - white (first cycle of vram on line 1)
; 174 - white (last cycle of vram on line 1)
; 175 - dots  (first cycle of hblank on line 1)
; 225 - white (last cycle of hblank on line 1)
```

`002-vram_locked.s`, DMG STAT per M-cycle after LCD-on, including a glitch the
suite documents nowhere else:

```
;   6 - stat 10000101
;   7 - stat 10000100 - glitch stat reads as hblank?
;   8 - stat 10000110 - oam line 0 starts here
;  27 - stat 10000110 - oam line 0 ends here
;  28 - stat 10000111 - vram line 0 starts here
;  70 - stat 10000111 - vram line 0 ends here
;  71 - stat 10000100 - hblank line 0 starts here
; 121 - stat 10000000 - lyc goes 0 on last cycle of hblank
; 122 - stat 10000010 - oam line 1 starts here
```

`000-oam_lock.s`: `;   0 - 01100010 ? oam not clean on boot?`, `;  69 - black /
;  70 - garbage`. `mode2_stat_int_to_oam_unlock.s`: `; correct - / ; 54 - black
/ ; 55 - white`.

## blargg

Only `oam_bug/readme.txt` states a mechanism; the other suites document how to
run and what the verdict codes mean. `oam_bug`, in full:

> Occurs when 16-bit increment/decrement is made of value in range $FE00 to
> $FEFF, during around the first 20 cycles of a visible scanline while LCD is
> on, where 114 cycles = 1 scanline. Causes several bytes of OAM to be copied
> from one place to another. Occurs with INC rp (including SP) / DEC rp / POP
> rp (counts as two increments) / PUSH rp (counts as two increments) / LD
> A,(HL+) / LD A,(HL-). Doesn't occur with LD HL,SP+n / ADD HL,rp / ADD SP,n.
> Doesn't occur anytime during the 10 vblank scanlines. Doesn't occur when LCD
> is off. Corruption depends on when it occurs.

"cycles" are M-cycles (`delay.s` forwards `n/4`). The sources pin the window
tighter than the readme: `4-scanline_timing.s` measures from the LCD-on write
and places the first corruption at `delay 70224-2` and the last at `+18` (19
M-cycles); `5-timing_bug.s` asserts it recurs on every visible line and stops
after line 143. `3-non_causes`/`2-causes`: `LD DE,$FDFF : INC DE` does not
corrupt but `LD SP,$FDFF : POP BC` does (the pre-increment operand decides, and
POP's second increment fires); `LD DE,$FE00 : INC DE` (row 0) must corrupt.
The readme gives no corruption *pattern*; the row/read/write patterns are Pan
Docs, "OAM Corruption Bug". `8-instr_effect` is bit-for-bit against four CRCs
over a fill that is recoverable from `oam_bug.inc` in
`crzysdrs/blarggs-test-roms` (absent from `retrio/gb-test-roms`): `fill_oam`
writes `$0C,$0D,…` over `$FE00..$FE9F`, `print_oam` prints `"-- "` for
unchanged bytes; the ROMs store the complement of the target CRC and the CRC'd
stream excludes `print_char_nocrc` spaces/newlines. Pan Docs: "Game Boy Color
and Advance are not affected by this bug, even when running monochrome
software" — `oam_bug_access` gates on `boot_model`, which is why these ROMs
must run `--dmg` despite `$0143 = $80`.

## daid

`speed_switch_timing_{div,ly,stat}.asm` carry a literal `expect:` table of the
register's byte sequence after a speed switch (32 bytes DIV, 128 LY, 64 STAT),
which localises any regression to an M-cycle.

`ppu_scanline_bgp` (`daid.py`): "Changing the BGP register has three possible
effects for one pixel: the previous BGP is used, the next BGP is used, or the
OR result of the previous and next BGP is used, the last case causing a black
line. Which case occurs seems to be hardware and instance dependent". Three
references ship; the runner accepts any (`alt_pngs`). The ROM's STAT handler is
exactly 456 dots long and free-runs from one LYC=0 interrupt, so the frame is
`V[j]` written on dot `φ + 456·⌊j/10⌋ + 16·(j mod 10)`: `φ = −362` reproduces
`_0` exactly, `φ = −363` reproduces `_2`, and `_1` is those two with the OR
pixel between (`MIXER_PALETTE_OR`, the shipped model). φ < 0 means the handler
starts inside line 153 — the LYC=0 interrupt belongs to the LY 153→0 snapback.

`stop_instr_gbc_mode3` (`daid.py`): "doing a STOP during mode 3 on Color
Gameboy will keep the screen displaying the same data, as the PPU keeps
running"; the reference is the text still on screen, so a blank-panel STOP
fails it (whereas `stop_instr (GBC)`'s black reference cannot).

## MBC3 / RTC (CasualPokePlayer, rtc3test)

`rtc-invalid-banks-test` README: "The RAMB register for MBC3+RTC is a 4 bit
register. The upper 4 bits do not affect the bank selected." Of 16 values only
9 map to anything; "banks" `$04-$07` and `$0D-$0F` "appear to produce open bus
behavior" (the test reads from HRAM so the open-bus value is `$FF`). dingbat:
`ram_bank_num = val and 0x0F` in `mbc3.nim`.

`ramg-mbc3-test` README: "rRAMG is a 4 bit register, where 0xA enables RAM, and
other values disable RAM." dingbat: `(val and 0x0F) == 0x0A`.

`latch-rtc-test` (`cpp.py`): "latches the RTC using a single write to the
0x6000-0x7FFF region", 52 iterations of a random byte. The README publishes no
conclusion; the latch register is modelled as 1 bit (0→1 edge of bit 0).
Assumed beyond the reference image.

`rtc3test/tests.md` is the spec (all sub-tests pass on hardware; "these tests
will fail if carried out in a platform with a significantly inaccurate clock,
such as the Super Game Boy"). Basic: tick 1000 ms ±1; RTC off does not tick;
register writes read back as the new state or new state + 1 s; 255d 23:59:59
rolls to 256d; 511d overflow sets the flag and it is sticky. Range: valid-bit
masks `$3F/$3F/$1F/$FF/$C1`; rolling seconds/minutes past 63 or hours past 31
zeroes the register "without causing the next register to increment".
Sub-second (tolerance 1.5 ms): writing seconds resets the sub-second divider;
minutes, hours, day-low and control (halt bit unchanged) do not; the sub-second
remainder is frozen across a halt. There is no "512-cycle latch" claim anywhere
in rtc3test.

## bully, strikethrough, acid

`bully.gb` (`$0143 = $80`) writes only BG palette 0 colour 3 (`rBCPS` `$86`,
two `rBCPD` zeros); colours 0–2 are inherited from the boot ROM, so a CGB-native
boot must seed palette RAM as the boot ROM leaves it. `src/tests/initram.asm`
("Uninitialized RAM not randomized") requires power-up WRAM to be neither all
`$00` nor all `$FF` (`GB_POWERUP_WRAM_PATTERN`). The reference is pure
black/white and device-agnostic; the shootout scores it on both devices.

`strikethrough.gb`: 40 sprites at `Y = $54`, `X = 23 + 8n`; a `STATF_LYC`
interrupt at `LYC = $54-$11` waits for mode 0 plus 28 NOPs and starts OAM DMA
so the transfer straddles the next line's modes 2 and 3. Source is 160 bytes
of `$01` with one `$00` at byte 46 ("seems to affect the tile number of the
sprite thats shown"). Expected text `Everyth+ng is OK!`: exactly one bar
survives. Assertion: during OAM DMA the PPU's OAM fetch sees what the DMA is
putting on the bus, not shadow OAM.

`dmg-acid2` ("NOT a PPU timing torture test"; register writes happen in mode 2
via LY=LYC interrupts) and `cgb-acid2` ("Double speed mode and WRAM banking
emulation are not required") READMEs map each face part to the feature it
asserts; use them to diagnose a partial failure:

| part | asserts |
|---|---|
| `!` in "Hello World!" | 10-object-per-line limit drops a solid-white 11th |
| mohawk | LCDC bit 0 off draws BGP colour 0 |
| eye whites | OAM bit 7 over BG colour 0; LCDC bit 4 with signed indexes `$a1`/`$a2` |
| right eye | window, WX moved off-screen at its bottom |
| mole beside left eye | visible only if tile data is read from `$8000` instead of `$8800` |
| moles by the nose | lower-X object wins even if later in OAM; at equal X the earlier OAM entry wins |
| nose | OAM bits 5/6 flips; missing nose = OBJ palette bit 4 |
| mouth | 8×16 objects ignore bit 0 of the tile index; LCDC bit 2 |
| right chin | LCDC bit 6 and the window internal line counter (16 window rows already drawn) |
| footer / tongue | LCDC bits 3, 5 / bit 1 |
| cgb: eyes, eye corners | BG attribute bits 5/6 (flip), OAM bit 7 vs BG attribute bit 7 |
| cgb: nose | OAM bit 3 (VRAM bank 1) with LCDC bit 0 master priority cleared |
| cgb: mole | `$FF6C` OPRI bit 0 (OAM order beats X) |
| cgb: footer | BG attribute bit 3 (tile VRAM bank) |

`cgb-acid-hell` documents nothing by design (README: "Emulator Requirements —
Not telling"); its source is an uncommented 15,340-line disassembly. The only
artefacts are `img/reference.png` and `img/photo.jpg`. The reference was
photographed against an AGS-101 and is hardware-correct
(docs/flashcart-runbook.md, IMG_3803).

`little-things-gb/firstwhite` README: "This program should display a white
screen … If you get text, your emulator needs to be fixed and probably shows
1-frame glitches in Pokémon Pinball." The reference is 23040 white pixels.

## Source quirks worth knowing

- `channel_4_align.asm` and `channel_4_volume_div.asm` headers name the wrong
  channel/register (see the SameSuite table).
- `hdma_mode0.asm` carries `hdma_lcd_off.asm`'s header verbatim.
- `channel_3_restart_during_delay.asm` has no header.
- `BullyGB/README.md` points at a wiki and ships no test list; the list is
  `TestRoutines::` in `src/tests.asm`.
- CasualPokePlayer's `latch-rtc-test` and `sgb-ext-test` branches publish no
  conclusion; `ramg-mbc3-test` and `rtc-invalid-banks-test` do.
- mealybug ships a `DMG-CPU B` reference set for exactly two tests.
