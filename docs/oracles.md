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
| `ppu.nim` ppu_store_lcdc | WY re-check when LCDC.5 turns on | — | Assumed — 7185bd0a removed a source-derived comment; disabling the re-check changes no verdict (2026-09-01) | none. Pan Docs states the WY condition per line only. hwprobe row 19; a gbvis page toggling LCDC.5 on the WY line |
| `memory.nim` skip_boot | OBP0/OBP1 hand off $00 on CGB/AGB, $FF on DMG/MGB/SGB; AGB P1 = $FF | SameBoy boot-ROM I/O dump | run — 8774472a `tools/gbfuzz/sameboy_bootio` dumps $FF00–$FF7F at handoff | mooneye boot_hwio-*; gbedge p00 IDENT (AGS: P1/SC captured) |
| `memory.nim` CGB write latency | the six per-register latencies exist as independent numbers | — | Assumed — 78fd545c took the per-register structure from gambatte's source; every value was then swept | each value is bracketed by gambatte late_wy_*/window/* and mealybug `_cgb_c` rows (named at the CGB_*_LATENCY knobs); the six-independent-numbers structure is Assumed; hwprobe row 4 |
| `memory.nim` mem_vdma_bus_capture | `dma_position <= 0xA0` as "OAM DMA active" | SameBoy | run — 9dda763f OAM-walk readout in the SameBoy runner | gambatte dma/oamdma rows |
| `interrupts.nim` IF_READ_SAMPLE_T | a $FF0F read in the handler returns 0 then 1 (read latches early; VBlank source not late) | SameBoy | run — 36e0bcc1 "SameBoy reads 0,1" (register readback) | gambatte m1/lycint_vblankirq, int_vblank1_nops, int_lyc_nops |
| `timer.nim` timer_check_edge | a glitch overflow reloads through the same one-M-cycle window as a natural one | — | ROM/probe — mooneye rapid_toggle (DMG); gbedge p02 TIMAGLITCH bytes 00–0F identical on MGB and AGS (decoded 2026-09-01) | CGB reload window Assumed; AGS bytes 11–12 (TAC $05→$06 switch glitch) DISAGREE with the model — open, docs/hwprobe-questions.md |
| `serial.nim` SERIAL_DIV_WRITE_LEAD_T | 4 T before the end of the store's M-cycle (only the T-cycle within the M-cycle is by comparison) | SameBoy | run — e20afbbf "measured two-sidedly against SameBoy by sliding both islands" | gambatte serial 71→75 pins the M-cycle |
| `apu/channel1.nim`, `channel2.nim` | CGB D/E half-tick backstep moves only the duty position, not the latched sample | SameBoy | run — f0e64749 "sweeping 20 rungs at both speeds against SameBoy on all six CGB revisions" (`sameboy_ssdump`) | SameSuite channel_1/2 verdict bytes; gbedge p12 PCMPSG (AGS captured) |
| `apu/channel2.nim` ch2_pcm_edge_zero | channel 2's PCM12 nibble reads 0 on a rising duty step on CGB 0–C (mirror of channel 1's ROM-pinned rule) | SameBoy | run — f0e64749, same 70 × 6 grid | SameSuite channel_1 arm is ROM-pinned; ch2 needs a CGB-C run of p12 |
| `printer.nim` | status sequence, ~7.5 frames per row, done-bit latch, full-band-only DATA, pre-exec ACK | SameBoy (Pocket Camera / Camera Gold behaviour corroborate) | run — 1bf10723 "diffing our printer dialogue against SameBoy packet-for-packet", ef3fc3f0 "inside SameBoy reproduced our failure verbatim" | Pan Docs Printer framing; Camera Gold / Hello Kitty end-to-end |
| `mbc/mbc7.nim` | MBC7 accelerometer idle value and .sav word order | — | Assumed — 38f0188f followed SameBoy; ab9108aa re-derived the protocol from Pan Docs + the 93LC56 datasheet | Pan Docs MBC7 + 93LC56 pin the register file and command set; 0x81D0/0x70 are Pan Docs values, "a flat cart reads exactly the centre" and little-endian .sav words are Assumed; needs an MBC7 cart |

## GBA core

| Where | Behaviour | Compared against | How | Independent evidence |
|---|---|---|---|---|
| `gba/ppu.nim` obj_geometry | signed OBJ X/Y (x > 239 → x−512, y > 159 → y−256) rather than mod-256 | mGBA, NanoBoyAdvance | run — 542b8f44 differential fuzz (tools/romfuzz mGBA + NBA runners) | GBATEK OAM Attributes caution (a tall OBJ at Y>128 is treated as Y>−128) pins the sign; the exact thresholds are Assumed; jsmolka ROMs draw no OBJs |
| `gba/ppu.nim` render_sprites | OBJ budget: the sprite that exhausts it still draws fully (hardware likely truncates — docs/hwprobe-questions.md, GBA table, open) | mGBA | run — 49d6d706 Famicom Mini dumps "bit-identical to mGBA at the same frame" (own mGBA/NBA runner) | GBATEK gives the budget, not the cut-off rule; Assumed |
| `gba/ppu.nim` render_sprites | OBJ fetches wrap within OBJ VRAM | — | Assumed — e9019133 took it from mGBA/NBA source (the 8bpp low-bit rule from the same commit is GBATEK verbatim and no longer listed) | a ROM naming tile 1023 for a multi-tile OBJ |
| `gba/bus.nim` read_open_bus_value, `gba.nim` | last DMA word on open bus for the DMA's own reads and the first CPU instruction after the burst | — | run — mGBA suite Misc "DMA Prefetch Read" fails without it (2026-09-01); the model's shape (81046b61) came from mGBA's source | GBATEK Unpredictable Things ("might also change if a DMA transfer occurs"); Hello Kitty Collection boot; the one-instruction window is Assumed |
| `gba/bus.nim` tilt_read | tilt X ADC-ready bit always set | — | Assumed — a7dbb853 copied the choice | GBATEK Tilt Sensor (E008300h bit 7 = ADC status, poll with timeout); a poll-count ROM on a tilt cart |
| `gba/gpio.nim` gyro_update | gyro ADC shifts on the falling serial-clock edge | — | Assumed (WarioWare Twisted plays; rising-edge shifting halves every reading) | GBATEK Gyro Sensor protocol does not fix the edge; a bit-order ROM on the cart |
| `gba/cartridge.nim` | 1 MiB ROMs mirror 4× in a 4 MiB window | — | GBATEK Cart Protections (Classic NES Series: "ROM mirrors") and Classic NES Metroid's jump into them pin that mirrors exist; the 4 MiB window is Assumed | read $08100000 / $08400000 on the cart |
| `gba/storage/eeprom.nim` | 108368-cycle write settle; reads in states 0x0E/0x0F return 0xFF; every data bit restarts the window | — | GBATEK ("ca. 108368 clock cycles (ca. 6.5ms)") pins the settle — re-derived 2026-09-01, replacing an inherited 115000; the 0xFF and per-bit-restart semantics are Assumed | a busy-poll counting ROM on an EEPROM cart |
| `gba/apu.nim` | SOUNDCNT_H PSG volume 3 mutes the PSG; SOUNDBIAS resolution mask keeps one bit more than GBATEK's table | — | Assumed — GBATEK marks volume 3 "Prohibited" and lists the resolutions; c9689b76/59cfe314 took both choices from other emulators | a line-out capture of volume 3 vs 2 |

## Test-harness decisions

| Where | Decision | Compared against | How | Independent evidence |
|---|---|---|---|---|
| runner: wilbertpol ly_lyc*-C | not scored; behaviour placed at CGB D+ | SameBoy | run — a781e277 `sameboy_wram` per revision; upstream withdrew the -C rows | a CGB-C vs CGB-D flashcart run of the same ROMs |
| runner: GBMicrotest halt_op_dupe_delay, stat_write_glitch_l154_d | skipped as ROM defects (derived from source; cross-checked) | SameBoy | run — bbf916af "SameBoy reproduces dingbat's answer" on the ROM | the ROMs' own .s sources (docs/gb-test-suite-sources.md 8.6) |
| runner: jsmolka frame hashes | pinned hashes for ppu/hello, shades, stripes, nes | mGBA, NanoBoyAdvance | run — 4fe14a87 "each hash was confirmed byte-identical against BOTH mGBA and NanoBoyAdvance" | jsmolka's published reference PNGs |
| runner: SameSuite APU default revision | CPU CGB E | SameBoy verdict grid | run — f0e64749 70 ROM × 6 revision `sameboy_ssdump` grid | SameSuite's stated capture machine; gbedge p12 on CGB-E |
| `--screen-check` | asserts settled + multi-shade, not glyphs (blargg loses cells to mode-3 refusal at double speed) | SameBoy | run — de6d28c5 two builds over real ROMs, "SameBoy drops the same writes" (frame diff) | blargg's console bounded-polls VBlank (ROM source); serial output is the scored channel |
