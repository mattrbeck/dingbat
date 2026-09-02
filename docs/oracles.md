# Behaviours pinned only by another emulator

Policy: code comments cite hardware evidence — Pan Docs / GBATEK, a test ROM,
a hardware probe, or an issue with photographs — or say `Assumed`. Where a
modelled behaviour was instead settled by comparing dingbat against another
emulator (SameBoy, DocBoy, mGBA, NanoBoyAdvance, ares, gambatte) and no
independent evidence exists in the tree, it is listed here.

Two kinds of comparison, and only one is allowed going forward. **Running**
another emulator as a black box — a ROM in its runner, a frame / PCM / WRAM /
register dump, a trace diff (`tools/gbfuzz` SameBoy + mGBA runners,
`tools/gbdiff` DocBoy runner, `tools/nbadiff`, `tools/gbapu`) — is a legitimate
oracle and is recorded here. **Reading its implementation** — taking a value,
an ordering or a rule from the other emulator's source — is not; every row
marked `source` below is a debt: the behaviour stays, its warrant does not,
and it is to be re-derived from documentation, a test ROM or a hardware probe.

Columns: *How* is `run` (black-box comparison), `source` (the value or rule
came from the other emulator's code) or `unclear` (the history does not say).
The deciding commit is cited. *Independent evidence* is what pins or brackets
the row without any emulator; where nothing does, it names the probe that
would. Each `source`/`unclear` row is a candidate for docs/hwprobe-questions.md.
Rows marked *also ROM-pinned* have test-ROM evidence too; the comparison only
chose between readings the ROMs could not separate.

## GB core

| Where | Behaviour | Compared against | How | Independent evidence |
|---|---|---|---|---|
| `gb.nim` TIMER_IRQ_RUN_LEAD | running-CPU timer dispatch one M-cycle ahead of the halted wake (also ROM-pinned) | SameBoy | run — 3f4670d8 "four purpose-built probes against SameBoy" (gbfuzz runner) | four non-gambatte runner rows on the exact quantity |
| `gb.nim` CGB_LYC_WRITE_DEFER | CGB LYC write reaches the comparator one M-cycle later than DMG (also ROM-pinned) | SameBoy | run — 79612ed5/984ed33d `tools/gbfuzz/sameboy_wram` dumps | wilbertpol `ly_lyc*_write-C`, gambatte lycEnable/m0enable [cgb] |
| `gb.nim` LYC_SETTLE_HALT_SKIP | halted wake lands on the near side of the LY 153→0 blind window (daid ppu_scanline_bgp also pins it) | SameBoy | run — 65bcb716 `sameboy_microtest` LY-turn readback | daid ppu_scanline_bgp frames |
| `gb.nim` CGB_HALT_PPU_LEAD | halt-wake PPU lead on normal-line LYC wakes, absent on the LY 153→0 snapback (acid-hell and daid frames also pin it) | SameBoy | run — bc9afb1c "SameBoy reproduces ppu_scanline_bgp_1.dmg.png exactly" (frame diff) | cgb-acid-hell reference (hardware-proven), daid frames |
| `gb.nim` VDMA_OAM_BUS_CAPTURE | OAM DMA stores the VRAM DMA's byte at the HDMA source's low byte (gambatte hdma_transition_oamdma_1 pins the scored byte) | SameBoy | run — 9dda763f "walking a test ROM's readout across the whole of OAM and asking SameBoy" (patched ROMs in its runner) | gambatte hdma_transition_oamdma_1 (one byte) |
| `gb.nim` HDMA_HALT_M0_BLIND | only the HALT's position moves hdma_late_m0halt's answer | SameBoy | run — 2a4ed841 "pieces one at a time under SameBoy … trace now matches ROM for ROM" | gambatte dma/hdma_late_m0halt* |
| `gb.nim` HDMA_OVERHEAD_LEADS | six injected bytes / six lost OAM slots over the OAM walk | SameBoy | run — 9dda763f, same OAM-walk readout | gambatte dma 167→169 |
| `gb.nim` CGB_WIN_RESTART_COUNTER | CGB window restart would resume at fetch counter 1; ships 0 (= DMG) | SameBoy via probe (f) | run — ab785598 probe ROM on silicon, SameBoy runner 16/16 vs photographs | probe (f) photographs (docs/flashcart-runbook.md) |
| `gb.nim` GbQuirks.lyc_compare_hold | wilbertpol ly_lyc*-C values hold from CGB D onward, not 0–C | SameBoy per revision | run — 84ca126c `sameboy_wram` per revision, "the ROM against both, not an oracle copy" (its source was quoted only to name the split) | wilbertpol ly_lyc*/ly_new_frame expected bytes; needs a CGB-C vs D flashcart run |
| `gb.nim` GbQuirks.ly_read_edge_late | $FF44 snapback read one M-cycle later on CGB D/E/AGB, single speed (AGE ly-cgbBC/E also pin it) | SameBoy per revision | run — 351e82ac `sameboy_wram` on all seven revisions | AGE ly-cgbBC / ly-cgbE |
| `gb.nim` GbQuirks.m1_end_no_mode0 | CGB D+ go straight from $81 to $82 at the end of mode 1 (AGE stat-mode pins it; no emulator agrees) | — | run — 08d34522 `sameboy_wram` over AGE's ROM answers $81 on every revision; ROM overrides it | AGE stat-mode M1E byte, gambatte lycint152/m2stat rows |
| `gb.nim` GB_MIX_SCALE / GB_DC_CHARGE | 1/8 output level and the DC-blocker trajectory | SameBoy PCM dumps | run — c727b1fc "RMS gain against SameBoy … 1.002–1.049", 5706b012 "SameBoy was used only to check the answer" (DINGBAT_GB_AUDIO_DUMP both sides) | none; a line-out capture of one title vs the dump |
| `cpu.nim` CGB_HALT_LEAD_SKIP_LYC0 | the CGB halt-wake lead is present for LYC = 1, 8, 40, 100 and absent only on the snapback | SameBoy (CGB compat), LYC-swept daid ROM | run — bc9afb1c LYC-swept daid ROM in the SameBoy runner | daid ppu_scanline_bgp; probe (e) contradicts it (g1 photograph specced) |
| `fifo_ppu.nim` M3_PIPE_AHEAD | the DMG mode-3 pipeline advance is device-independent; daid's DMG refusal is confined to its snapback anchor | SameBoy | run — 65bcb716 / a554e7fc `gam_dispatch` "byte-identical to SameBoy on both devices" | mealybug + gambatte dispatch rows, shootout 261 |
| `ppu.nim` ppu_store_lcdc | WY re-check when LCDC.5 turns on | SameBoy | **source** — 7185bd0a removed the comment "SameBoy schedules a fresh wy_check after every LCDC write"; no dump | none. Pan Docs Window: WY condition is checked at each line, not on the write. hwprobe row 19 (window arming axes); a gbvis page toggling LCDC.5 on the WY line |
| `ppu.nim` LCD_ON_FRAME_DOTS | 10·456 dots as the artificial-vblank threshold after LCD-on (frontend pacing) | SameBoy | **source** — d5ff0da5 "SameBoy uses the identical rule and the identical 10*456"; 9e09d87b frame-count parity checked by run | not hardware (pacing rule, no frame exists); any threshold ≤ one frame period is equivalent |
| `memory.nim` skip_boot | OBP0/OBP1 hand off $00 on CGB/AGB, $FF on DMG/MGB/SGB; AGB P1 = $FF | SameBoy boot-ROM I/O dump | run — 8774472a `tools/gbfuzz/sameboy_bootio` dumps $FF00–$FF7F at handoff | mooneye boot_hwio-*; gbedge p00 IDENT (AGS: P1/SC captured) |
| `memory.nim` CGB write latency | the six per-register latencies exist as independent numbers | gambatte, SameBoy | **source** — 78fd545c "gambatte's video.cpp gives CGB a longer write latency … per register"; values swept, "every value gambatte's table gives is refused" | Pan Docs is silent. gambatte window/bgtilemap/lcd_offset rows bracket each value; mealybug `_cgb_c`; hwprobe row 4 (WY) |
| `memory.nim` SPEED_SWITCH_STALL_T | 2^16 + 4 dots as the raw stall (blargg cpu_instrs frames pin the region) | SameBoy | **source** — de6d28c5 "cross-checked against SameBoy's 0x20008", 74a0bbc5 "towards SameBoy's 65540" (its constant) | Pan Docs says 8200 (wrong). gambatte speedchange TIMA +128 / LY-at-431-lines bracket to one M-cycle; daid speed_switch_timing_ly/_stat; gbedge p13 DSTAT (photographed, undecoded) |
| `memory.nim` SPEED_SWITCH_FREEZES_OAM_DMA | OAM DMA frozen across the stall | SameBoy | **source** — 39378ca9 "what SameBoy's `GB_dma_run` means by returning early on `halted \|\| stopped`" | gambatte oamdma/oamdmasrcC0_speedchange_readC000 (exact), dma/hdma_transition_speedchange_oamdma (one M-cycle off) |
| `memory.nim` mem_vdma_bus_capture | `dma_position <= 0xA0` as "OAM DMA active" | SameBoy | run — 9dda763f OAM-walk readout in the SameBoy runner | gambatte dma/oamdma rows |
| `interrupts.nim` IF_READ_SAMPLE_T | a $FF0F read in the handler returns 0 then 1 (read latches early; VBlank source not late) | SameBoy | run — 36e0bcc1 "SameBoy reads 0,1" (register readback) | gambatte m1/lycint_vblankirq, int_vblank1_nops, int_lyc_nops |
| `timer.nim` timer_check_edge | a glitch overflow reloads through the same one-M-cycle window as a natural one (mooneye rapid_toggle also pins it) | SameBoy, DocBoy | **source** — 45a2d0f5 Pan Docs audit A6 "cross-checked against SameBoy and DocBoy first" (source reads; tried-and-reverted) | mooneye rapid_toggle (DMG only); gbedge p02 TIMAGLITCH bytes 10–13 captured on MGB + AGS, undecoded (hwprobe row A5/A6) |
| `timer.nim` SPEED_SWITCH_DIV_RESET_T | the DIV reset lands one M-cycle after the STOP fetch | SameBoy | **source** — 8bc6ea94 "SameBoy makes the same choice (`enter_stop_mode` ahead of `cycle_read(gb->pc++)`)"; value swept on gambatte | gambatte speedchange_tima0N (two-sided, one M-cycle wide); AGE spsw-tima |
| `serial.nim` serial_master_edge | half-rate master toggle off DIV bit 7 (bit 2 CGB fast), reseeded low by an SC write (gambatte serial/* also pin it) | SameBoy | **source** — b275380d "SameBoy's GB_serial_master_edge (Core/timing.c) does not shift on the tap: it flips a master clock" | Pan Docs Serial: 8192 Hz from DIV, no phase statement. gambatte serial 50→53; gbedge p06 SERIAL (MGB bytes captured, decode pending; hwprobe row 8) |
| `serial.nim` SERIAL_DIV_WRITE_LEAD_T | 4 T before the end of the store's M-cycle (only the T-cycle within the M-cycle is by comparison) | SameBoy | run — e20afbbf "measured two-sidedly against SameBoy by sliding both islands" | gambatte serial 71→75 pins the M-cycle |
| `apu/channel1.nim`, `channel2.nim` | CGB D/E half-tick backstep moves only the duty position, not the latched sample | SameBoy | run — f0e64749 "sweeping 20 rungs at both speeds against SameBoy on all six CGB revisions" (`sameboy_ssdump`) | SameSuite channel_1/2 verdict bytes; gbedge p12 PCMPSG (AGS captured) |
| `apu/channel2.nim` ch2_pcm_edge_zero | channel 2's PCM12 nibble reads 0 on a rising duty step on CGB 0–C (mirror of channel 1's ROM-pinned rule) | SameBoy | run — f0e64749, same 70 × 6 grid | SameSuite channel_1 arm is ROM-pinned; ch2 needs a CGB-C run of p12 |
| `printer.nim` | status sequence, ~7.5 frames per row, done-bit latch, full-band-only DATA, pre-exec ACK | SameBoy (Pocket Camera / Camera Gold behaviour corroborate) | run — 1bf10723 "diffing our printer dialogue against SameBoy packet-for-packet", ef3fc3f0 "inside SameBoy reproduced our failure verbatim" | Pan Docs Printer framing; Camera Gold / Hello Kitty end-to-end |
| `mbc/mbc7.nim` | whole MBC7 model; EEPROM words little-endian in `ram` for .sav interchange | SameBoy | **source** — 38f0188f "Followed SameBoy throughout, including its 0x81D0 idle accelerometer reading"; ab9108aa re-cited Pan Docs + 93LC56, one copied bug removed | Pan Docs MBC7 + 93LC56 datasheet cover the register file and command set; idle accelerometer value and .sav byte order have no doc — Kirby/Command Master on a flashcart (MBC7 cart needed) |

## GBA core

| Where | Behaviour | Compared against | How | Independent evidence |
|---|---|---|---|---|
| `gba/ppu.nim` new_ppu | BG2PA/BG2PD reset to 0x100 | mGBA | **source** — 201c1b01 "mGBA's GBAIOInit" | GBATEK gives no reset value (write-only). Real BIOS dump in tree (LLE): boot a mode-2 ROM that never writes PA/PD under LLE; RegisterRamReset's 0x100 is confirmed there (7fcc72f4) |
| `gba/ppu.nim` obj_geometry | signed OBJ X/Y (x > 239 → x−512, y > 159 → y−256) rather than mod-256 | mGBA, NanoBoyAdvance | run — 542b8f44 differential fuzz (tools/romfuzz mGBA + NBA runners) | GBATEK OBJ attr 0/1: 9-bit X, 8-bit Y wrap; jsmolka ppu frames |
| `gba/ppu.nim` render_sprites | OBJ budget: the sprite that exhausts it still draws fully (hardware likely truncates — docs/hwprobe-questions.md, GBA table, open) | mGBA | run — 49d6d706 Famicom Mini dumps "bit-identical to mGBA at the same frame" (own mGBA/NBA runner) | GBATEK "OBJ cycles per line" gives the budget, not the cut-off rule; hwprobe row 26 |
| `gba/ppu.nim` render_sprites | OBJ fetches wrap within OBJ VRAM; 8bpp name low bit cleared only under 2D mapping | mGBA, NanoBoyAdvance | **source** — e9019133 "mGBA (software-obj.c `align` mask) and NanoBoyAdvance" | GBATEK OBJ VRAM mapping note ("in 256-colour 2D mode … bit 0 ignored"); THPS2 portrait in-game; a jsmolka-style ROM writing odd 8bpp names in 1D |
| `gba/bus.nim`, `gba.nim` | DMA open-bus word visible to the DMA's own reads and the first CPU instruction after the burst (GBATEK pins only "recently transferred data") | mGBA | **source** — 81046b61 "Model (mirrors mGBA's gba->bus + dmaPC-distance …)"; found by register-trace diff (run) | GBATEK Unpredictable Things "DMA … recently transferred data"; mGBA suite DMA R+0x10 rows (open); Hello Kitty boot |
| `gba/bus.nim` tilt_read | tilt X ADC-ready bit always set | mGBA | **source** — a7dbb853 "the always-ready bit like mGBA" | GBATEK Yoshi tilt: 0E008400 bit 7 = ADC status; a poll-count ROM on the cart |
| `gba/bus.nim` UND vector stub | stub keeps only `subs pc, lr, #4` | mGBA | unclear — c92de8cb lists the stub with no comparison phrase | real BIOS dump in tree: disassemble the UND vector at $04 and run the same ROM under LLE |
| `gba/gpio.nim` gyro_update | gyro ADC shifts on the falling serial-clock edge | mGBA | unclear — 69f002b8 "FALLING clock edge, mGBA-verified ordering" (run or read not stated) | GBATEK Gyro (WarioWare Twisted) serial protocol; a bit-order ROM on the cart |
| `gba/cartridge.nim` | 1 MiB ROMs mirror 4× in a 4 MiB window (Classic NES Metroid's check is the in-game pin) | mGBA | **source** — faebadcb quotes "mGBA GBALoadROM: '1 MiB ROMs all appear as 4x mirrored, but not more'" | Classic NES Metroid anti-emulation check; GBATEK says only that reads past ROM end are open bus — read $08100000 on the cart |
| `gba/storage/eeprom.nim` | 115000-cycle settle (GBATEK ~6.5 ms); reads in 0x0E/0x0F return 0xFF; every data bit restarts the window | mGBA | **source** — 38927b5b "mGBA's constant and semantics; NBA …" | GBATEK EEPROM "~6.5 ms" (= 109,000 cycles) brackets the constant; SMA first-boot save pins "not shorter"; a busy-poll counting ROM on an EEPROM cart |
| `gba/apu.nim` | SOUNDCNT_H PSG volume 3 silences the PSG; SOUNDBIAS resolution masks with two guard bits | NanoBoyAdvance, SkyEmu; ares | **source** — c9689b76 "NanoBoyAdvance and SkyEmu both mute the PSG for it (mGBA … 200%)", 59cfe314 "as ares does" | GBATEK marks volume 3 "prohibited" and gives the bias resolutions; a line-out capture of volume 3 vs 2 |
| `gba/hle_bios.nim` | Div by zero returns ±1 / numerator / 1; RegisterRamReset clears IE/IF/WAITCNT/IME and leaves PA/PD at identity; Sqrt phase constants | mGBA HLE (games rely on the first two) | **source** — ccb964c5 Sqrt "structure cross-checked against mGBA's HLE, pinned here by the hardware anchors"; PA/PD from the real BIOS (7fcc72f4); Div-by-zero origin unclear | Real BIOS dump in tree: LLE is the ground truth for all three (Div(x,0) under LLE; mGBA suite BIOS math 615/615 anchors Sqrt) |

## Test-harness decisions

| Where | Decision | Compared against | How | Independent evidence |
|---|---|---|---|---|
| runner: wilbertpol ly_lyc*-C | not scored; behaviour placed at CGB D+ | SameBoy | run — a781e277 `sameboy_wram` per revision; upstream withdrew the -C rows | a CGB-C vs CGB-D flashcart run of the same ROMs |
| runner: GBMicrotest halt_op_dupe_delay, stat_write_glitch_l154_d | skipped as ROM defects (derived from source; cross-checked) | SameBoy | run — bbf916af "SameBoy reproduces dingbat's answer" on the ROM | the ROMs' own .s sources (docs/gb-test-suite-sources.md 8.6) |
| runner: jsmolka frame hashes | pinned hashes for ppu/hello, shades, stripes, nes | mGBA, NanoBoyAdvance | run — 4fe14a87 "each hash was confirmed byte-identical against BOTH mGBA and NanoBoyAdvance" | jsmolka's published reference PNGs |
| runner: SameSuite APU default revision | CPU CGB E | SameBoy verdict grid | run — f0e64749 70 ROM × 6 revision `sameboy_ssdump` grid | SameSuite's stated capture machine; gbedge p12 on CGB-E |
| `--screen-check` | asserts settled + multi-shade, not glyphs (blargg loses cells to mode-3 refusal at double speed) | SameBoy | run — de6d28c5 two builds over real ROMs, "SameBoy drops the same writes" (frame diff) | blargg's console bounded-polls VBlank (ROM source); serial output is the scored channel |
