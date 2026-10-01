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
| `gb.nim` GbQuirks.lyc_compare_hold | wilbertpol ly_lyc*-C values hold from CGB D onward, not 0–C | SameBoy per revision | run — 84ca126c `sameboy_wram` per revision, "the ROM against both, not an oracle copy" (its source was quoted only to name the split) | gambatte cgb04c `lycint152_*` rows for the LY/STAT edges; the LYC hold itself needs a CGB-C flashcart run |
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
| `common/psg_channels.nim` sq_write_freq_hi | CGB D/E half-tick backstep moves only the duty position, not the latched sample | SameBoy | run — f0e64749 "sweeping 20 rungs at both speeds against SameBoy on all six CGB revisions" (`sameboy_ssdump`) | SameSuite channel_1/2 verdict bytes; gbedge p12 PCMPSG (AGS captured) |
| `gb/apu/psg_host.nim` sq_pcm_edge_zero | channel 2's PCM12 nibble reads 0 on a rising duty step on CGB 0–C (mirror of channel 1's ROM-pinned rule) | SameBoy | run — f0e64749, same 70 × 6 grid | SameSuite channel_1 arm is ROM-pinned; ch2 needs a CGB-C run of p12 |
| `printer.nim` | status sequence, ~7.5 frames per row, done-bit latch, full-band-only DATA, pre-exec ACK | SameBoy (Pocket Camera / Camera Gold behaviour corroborate) | run — 1bf10723 "diffing our printer dialogue against SameBoy packet-for-packet", ef3fc3f0 "inside SameBoy reproduced our failure verbatim" | Pan Docs Printer framing; Camera Gold / Hello Kitty end-to-end |
| `mbc/mbc7.nim` | MBC7 accelerometer idle value and .sav word order | — | re-derived 2026-09-01 from Pan Docs MBC7 + the 93LC56 datasheet (the earlier file, 38f0188f, followed SameBoy); a flat cart reading exactly the centre and the little-endian .sav words are Assumed | Pan Docs + 93LC56 pin the register file, command set and busy status (tests/mbc7_test.nim); Kirby Tilt 'n' Tumble boots, plays and round-trips its save identically; needs an MBC7 cart for the idle value |

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
| runner: wilbertpol `-C` rows | scored on CGB E (`WilbertpolCgbRep`): the fork's Color group names no revision, all 15 `-C`/`-cgb` ROMs pass on D/E and six fail on C where gambatte's cgb04c rows and AGE's cgbBC/cgbE pairs pin the C behaviour | SameBoy per revision (`sameboy_wram`), gambatte, AGE | run — 2026-09-21: dingbat and SameBoy split `ly_new_frame-C` at C/D identically; SameBoy-C fails gambatte `lycint152_ly0stat_2` | a CGB-C flashcart run of `ly_lyc-C` (the one edge no other suite covers) |
| runner: GBMicrotest halt_op_dupe_delay, stat_write_glitch_l154_d | skipped as ROM defects (derived from source; cross-checked) | SameBoy | run — bbf916af "SameBoy reproduces dingbat's answer" on the ROM | the ROMs' own .s sources (docs/gb-test-suite-sources.md 8.6) |
| runner: jsmolka frame hashes | pinned hashes for ppu/hello, shades, stripes, nes | mGBA, NanoBoyAdvance | run — 4fe14a87 "each hash was confirmed byte-identical against BOTH mGBA and NanoBoyAdvance" | jsmolka's published reference PNGs |
| runner: SameSuite APU default revision | CPU CGB E | SameBoy verdict grid | run — f0e64749 70 ROM × 6 revision `sameboy_ssdump` grid | SameSuite's stated capture machine; gbedge p12 on CGB-E |
| `--screen-check` | asserts settled + multi-shade, not glyphs (blargg loses cells to mode-3 refusal at double speed) | SameBoy | run — de6d28c5 two builds over real ROMs, "SameBoy drops the same writes" (frame diff) | blargg's console bounded-polls VBlank (ROM source); serial output is the scored channel |

## DS reference cores (tools/ndsref)

Prebuilt libretro cores (macOS arm64 binaries, no sources) run as black boxes
by `tools/ndsref` (2026-10-01). Their names and option files live in
`~/.cache/dingbat-nds/cores` (`NAME_libretro.dylib` + `NAME_libretro.opts`),
not in the repo; the settings that matter are recorded here so the setup can
be rebuilt. No DS behaviour is pinned by these runs yet.

| Core (as it reports itself) | Output | Settings for comparable runs | Findings |
|---|---|---|---|
| melonDS DS 1.4.0 | XRGB8888 (6-bit widened), 59.826098 fps, 32728.498 Hz | `melonds_boot_mode=direct`, `melonds_console_mode=ds`, `melonds_sysfile_mode=native` (BIOS/firmware from `--bios`, else built-in), `melonds_jit_enable=disabled`, `melonds_render_mode=software`, `melonds_threaded_renderer=disabled`, `melonds_start_time_mode=absolute` (RTC fixed at 2004-01-01, otherwise host clock), `melonds_number_of_screen_layouts=1` + `melonds_screen_layout1=top-bottom`, `melonds_screen_gap=0`, `melonds_show_cursor=disabled`, `melonds_touch_mode=touch`, `melonds_audio_interpolation=disabled` (also linear/cosine/cubic/gaussian), `melonds_homebrew_sdcard=disabled`, `melonds_dsi_sdcard=disabled`, `melonds_network_mode=disabled` | rejects ROMs with plain ARM9 code in the secure area (all white; `--relocate` fixes it); runs current libnds builds; libnds `hello_world` counter matches ndsrun frame for frame; armwrestler menu equal from frame 5, fb_both from 10 (ours draws faster: CPU timing) |
| melonDS 0.9.3 | XRGB8888, 59.898308 fps, 32768 Hz | `melonds_boot_directly=enabled`, `melonds_console_mode=DS`, `melonds_threaded_renderer=disabled`, `melonds_screen_layout=Top/Bottom`, `melonds_screen_gap=0`, `melonds_touch_mode=Touch`, `melonds_audio_interpolation=None` (also Linear/Cosine/Cubic); BIOS = system dir files, else its free BIOS + generated firmware | one frame behind the 1.4.0 core under direct boot; tone output at half the amplitude of the other cores; secure-area and current-libnds failures (white frames) as the next row; no RTC option (host clock) |
| DeSmuME 0.9.12 (git 95b4d79) | RGB565, 59.8261 fps, 44100 Hz | `desmume_use_external_bios` (disabled = HLE; enabled with `--bios`), `desmume_boot_into_bios=disabled`, `desmume_num_cores=1`, `desmume_advanced_timing=enabled`, `desmume_internal_resolution=256x192`, `desmume_screens_layout=top/bottom`, `desmume_screens_gap=0`, `desmume_pointer_mouse=enabled` + `desmume_pointer_type=touch` (touch is never polled otherwise); no audio interpolation option | runs secure-area ROMs as they are; current libnds builds (hello_world, Simple_Tri) stay white; fb_both and armwrestler equal to ndsrun from frame 2 / 1; RTC is the host clock (no option) |

All three: two runs of the same ROM gave byte-identical PNGs (frames 30, 60,
120) and WAVs for fb_both, gx_tri, snd_tone, Simple_Tri, hello_world and
armwrestler. A firmware boot (`melonds_boot_mode=native` /
`desmume_boot_into_bios=enabled` with real dumps) stops at the health-and-
safety screen until touched, then shows a menu that lists no homebrew card,
so only direct boot is comparable. Open differences seen on first use: the
3D triangle's colour interpolation and one edge line (gx_tri, Simple_Tri:
3.9-5.7 k pixels at tolerance 0, 1.1-1.9 k at tolerance 8, against every core); raw
touch ADC values (firmware calibration) while the reported pixel matches;
ndsrun writes 0.2% fewer samples per frame than 32728 Hz x frame time
(snd_tone, 120 frames: 65499 vs 65646).

## NDS core

Sound rows come from `tests/nds/src/snd_suite` (our ROM: timed SPU sections
plus register/capture readbacks drawn as bit rows), dumped by `ndsrun --wav`
and by `tools/ndsref` on each core, and measured with
`tests/nds/tools/snd_analyze.py` (levels, frequencies, LFSR correlation,
envelopes, edge timing; resampling-robust). Cores and settings as in the
section above; libnds builds need `--bios` on melonDS DS to make sound.
Where every core agrees with GBATEK (and with dingbat) nothing is listed:
start delays 3/1/11 samples, PSG duties, the noise LFSR, PCM8/16 and ADPCM
decode, volume/divider/pan/master steps, the SOUNDCNT output selectors and
ch1/ch3 mixer bits, mixer capture and its clip, register masks.

| Where | Behaviour | Compared against | How | Independent evidence |
|---|---|---|---|---|
| `nds/io/spu.nim` channel FIFO | channels read sample words ahead of playback (FIFO_WORDS = 8), so a channel replaying a buffer that capture is filling hears it one loop late: echo period = buffer + 2 samples (4194 output samples for a 4096-sample loop at 31979 Hz) | melonDS DS 1.4.0 (sample-identical period), DeSmuME (same at 4 ms resolution) | run — snd_suite `echo`; reading at play time gave a 3-sample feedback loop instead | GBATEK's block diagram shows the FIFOs; maxmod's reverb depends on the loop-late reading; the depth is Assumed |
| `spu.nim` repeat mode 0 | "Manual" plays on past PNT+LEN through the following memory, busy until stopped | melonDS DS plays through; melonDS 0.9.3 loops; DeSmuME stops | run — snd_suite `repeat` | GBATEK names the mode only; Assumed from the bit layout (neither the loop nor the one-shot bit set); a hardware run of snd_suite |
| `spu.nim` repeat mode 3 | "Prohibited" loops like mode 1 | both melonDS cores loop; DeSmuME stops | run — snd_suite `repeat` | Assumed; a hardware run |
| `spu.nim` one-shot busy bit | cleared at the start of the last sample (GBATEK kept); melonDS DS and DeSmuME clear it a sample later, at its end (readbacks: 67/43/11 sample periods for 64-sample PCM8, 32-sample ADPCM, 8-sample PCM16 vs GBATEK's 66/42/10) | melonDS DS, DeSmuME, melonDS 0.9.3 (mixed) | run — snd_suite `start_timing` (a 1 MHz reference channel stopped by the CPU when busy drops) and RES[3/4/19] | GBATEK "Sound Stop (timing note)"; unclear until a hardware run |
| `spu.nim` Hold flag | the last sample of a one-shot stays out while Hold is set | no core holds it (DeSmuME and melonDS 0.9.3 drop to 0) | run — snd_suite `hold` | GBATEK "Hold Flag" (kept) |
| `spu.nim` capture from ch(a) | both-negative bug (-8000h), overflow bug (AND FFFFh), source before panning | melonDS (both) capture ch(a)'s panned left + ch(b); DeSmuME plain ch(a), clipped sum | run — snd_suite RES[15-17] | GBATEK "Capture Bugs" (kept) |
| `spu.nim` PCM8 capture rounding | 8.16 fraction MSB set rounds towards zero (-4080h -> C0h) | all three floor (BFh) | run — snd_suite RES[14] | GBATEK "Capture Clipping/Rounding" (kept) |
| `spu.nim` SNDCAPxCNT bit 0 | reads back as written | DeSmuME agrees; melonDS (both) read 0 | run — snd_suite RES[9] | GBATEK lists it R/W (kept) |
| `spu.nim` output sampling | the PWM word is the mixer's value at each 1024-cycle tick: a channel above the output rate aliases at full level (a 47.6 kHz tone comes out at 14.9 kHz, full scale) | melonDS 0.9.3 the same; melonDS DS -14 dB (it also low-passes ~7 kHz and high-passes its output); DeSmuME resamples to 44.1 kHz | run — snd_suite `timer` | GBATEK gives the 1.04876 MHz mixer and 32.768 kHz PWM, not how the PWM word is taken; Assumed |
| `spu.nim` SOUNDBIAS | output is bias - 200h as DC, also with master enable off | melonDS 0.9.3 identical ramp; melonDS DS high-passes it away; DeSmuME ignores bias | run — snd_suite `bias` | GBATEK SOUNDBIAS ("always enabled") |
| `nds/io/timers.nim` write_reg | writing TMxCNT_H of a running timer without changing start/prescaler/cascade (an IRQ-enable toggle) keeps the count and prescaler phase | melonDS DS | run — maxmod `basic_sound` music drifted 4 ms/s (0.4%) late against melonDS DS until fixed (maxmod toggles TM1's IRQ enable every tick); after it the envelopes line up over 10 s | GBATEK timers (control writes do not reload); the prescaler phase surviving is Assumed |

## NDS core

Comparisons against the melonDS DS 1.4.0 core run through `tools/ndsref`
(settings in the table above, `--rtc 2004-01-01` on ndsrun to match its
`melonds_start_time_mode=absolute`), on Pokemon SoulSilver unless named.

| Where | Behaviour | Compared against | How | Independent evidence |
|---|---|---|---|---|
| `nds/timing.nim` | the whole memory-timing model: per-region N/S access costs, ARM9 N32 fetches, cache tags, internal cycles | melonDS DS 1.4.0 | run — SoulSilver boot reached the first black frame at 130 (placeholder 2/4 cycles per instruction), 150 (this model), 190 (+ SPI busy) vs the core's ~195; frames 205-1600 then match pixel for pixel apart from fades and 3D | GBATEK "DS Memory Timings" gives every table value; Assumed: code-cache line fill = data fill, write-buffered store = 1 bus cycle, ARM9 branch refill 2 cycles, ARM7 refill = one extra S fetch; a hardware cycle-count ROM would pin them |
| `io/cart.nim`, `io/spi.nim` | AUXSPICNT.7 / SPICNT.7 busy for 8 bits at the baud rate | melonDS DS 1.4.0 | run — removing it puts SoulSilver's boot ~40 frames ahead of the core (its 512 KB save is read at 4 MHz) | GBATEK AUXSPICNT/SPICNT (baud rates, busy flag) |
| `io/backup.nim` | IR-cart SPI front-end (00h pass-through, 01h receive length 0, 08h version AAh) | melonDS DS 1.4.0 | run — both show the Continue menu with CONNECT TO POKéWALKER from the same save | GBATEK "DS Cart Infrared Cartridge SPI Commands"; the reply byte during the IR command byte (FFh) is Assumed |
| `io/wifi.nim` | enough of the MAC/BB/RF for the SDK's wireless manager to start: without it SoulSilver's Continue showed "A communication error has occurred" | melonDS DS 1.4.0 | run — both reach CONTINUE / NEW GAME / CONNECT TO POKéWALKER and continue into New Bark Town | GBATEK DS Wifi chapters (register widths, reset values, IRQ edge, power states, timers, BB/RF tables); Assumed: power-up applies at once (with RX.ON), wifi RAM above 0x6000 reads FFFFh |
| `io/wifi.nim` beacon transmit | W_TXSTAT 0301h and TX header 0001h after a beacon (W_TXSTATCNT bit 15); IRQ07s 64 x 1024 us apart for W_BEACONINT 40h; IRQ07 -> IRQ01 352 us for 88 bytes at 2 Mbit/s | melonDS DS 1.4.0 identical | run — `wifi_link` host alone (A held), RES[4-6] at frame 600, `--relocate --bios` | GBATEK W_TXSTATCNT, IRQ14 notes, preamble/rate timing |
| `io/wifi.nim` multiplay CMD, no slave | 8 rounds each end with TX header 0005h, [02h] = 0002h (slave 1 missing), W_TXSTAT 0B01h; request -> IRQ12 830 us (core 832 us) | melonDS DS 1.4.0 (same but the 2 us) | run — `wifi_link` host alone, RES[9], RES[12-14] | GBATEK "Multiplay Master" (16 + (10 + REPLYTIME) x n wait, CMD ACK); Assumed: the 10-us SIFS gaps |
| `io/wifi.nim` frame to an absent station | 8 tries (1 + W_TX_RETRYLIMIT 7), each frame + ACK wait; TX header 0003h, W_TXSTAT failed, W_TX_ERR_COUNT 8: 3987 us for a 36-byte frame with short preamble | melonDS DS reports it sent after one try (TX header 0001h, 248 us, no error count) | run — `wifi_link` client alone, RES[8], RES[14-15] | GBATEK "DS Wifi Transmit Errors" (ACK, retries, 0003h) kept; the ACK wait (SIFS + ACK at the frame's rate, long preamble) is Assumed |
| `io/rtc.nim` | `--rtc` clocks the RTC from emulated time | melonDS DS 1.4.0 | run — with both at 2004-01-01 00:00 the same input script gives identical frames 3000 and 5000 (the game seeds from the RTC) | none needed: a test-harness choice, the hardware clock is the host's |
| `nds.nim` slot2_read, `io/slot2.nim` open bus | empty GBA slot: ROM halfwords address/2, OR FE08h at the 10-cycle first access, FFFFh at 18; SRAM FFh; the CPU not owning the slot (EXMEMCNT.7) reads zeros; each CPU's EXMEMSTAT bits 0-6 its own | melonDS DS 1.4.0 (`melonds_slot2_device=auto`, nothing inserted) | run — `slot2_probe` (tests/nds/src/slot2_probe, `--relocate`): words 0-38, 53-64, 68-81 identical | GBATEK "DS Memory Control - Cartridges and Main RAM" (GBA Slot) |
| `bus9.nim` EXMEMCNT bit 14 | a write of 0 is ignored, the bit reads set | melonDS DS 1.4.0 | run — slot2_probe word 37 (0080h written, 6080h read) | GBATEK: "writes to this bit appear to be ignored?" |
| `timing.nim` GBA-slot rows | access times follow each CPU's own EXMEMCNT bits 0-4 (10/8/6/18 first, 6/4 second, SRAM 10/8/6/18) | melonDS DS 1.4.0 | run — slot2_probe words 39-52: 16 loads move by the same 32 bus cycles per setting step on both CPUs; the absolute counts differ by a constant per CPU (ARM9 68 more here, ARM7 16 fewer), which the main-RAM control loop (80-81) shows is loop overhead, not the slot | GBATEK EXMEMCNT field values and "DS Memory Timings" (the table is the default setting) |
| `io/slot2.nim` Rumble Pak | ROM halfwords read open bus with AD1 low (address/2 AND FFFDh at 6/8 cycles, FFFDh at 18); SRAM FFh | melonDS DS 1.4.0 (`rumble-pak`) reads FFFDh at every address and timing and SRAM 00h | run — slot2_probe; GBATEK's own detection loop (word 53) finds 1000h matches here and 0 on the core; libnds' check (FFFDh at 0x08000000 with its 18-cycle setting) passes on both | GBATEK "DS Cart Rumble Pak" (kept: its detection loop needs the address pattern); SRAM: Assumed High-Z as an empty slot |
| `io/slot2.nim` rumble strength | one latch change a frame = 64/255, each further change adds 64 | melonDS DS 1.4.0 reports 16384/65535 for one change a frame, 32768 for two, then fades over ~6 frames | run — slot2_probe's 30-frame toggle tail, `ndsrun --rumble-log` vs `ndsref --rumble-log` | GBATEK: the actuator moves on each change; the strength scale is a frontend choice |
| `io/slot2.nim` Memory Expansion Pak | header ID at 0x080000B0-BF (FFFF 0000 2400 2424 FFFF FFFF FFFF 7FFF), the rest of the ROM region FFFFh, RAM at 0x09000000 starts unlocked, locked reads FFFFh and drops writes, byte stores do nothing | melonDS DS 1.4.0 (`expansion-pak`) | run — slot2_probe words 54-62, 72-76: identical except 75 (0x08240000 reads 0 there, FFFFh here) and the SRAM region (00h there, FFh here) | GBATEK "DS Cart Expansion RAM" gives only base, size and the lock register; everything else here is the reference's, hardware unverified |
| `io/slot2.nim` GBA cart | ROM, header, FLASH ID (Sanyo 1362h for FLASH1M), GPIO port read-back | melonDS DS 1.4.0 (`--slot2` Emerald + its .sav) | run — slot2_probe identical except: past the 16 MB image (0x09xxxxxx) the core reads 0, we read open bus as the GBA core does; boot info at 0x027FFC30 the core leaves 0000FFFF/0/0, we fill it from the header (GBATEK boot info) | GBATEK "DS Cartridge GBA Slot", "GBA Cart Backup Flash ROM"; the GBA core's measured open bus past the ROM |
| `io/slot2.nim` + SoulSilver | the main menu lists MIGRATE FROM <game> only with a Generation 3 cart in slot 2, and only for a save with two Pokedex flags set (general block 15EEh/15EFh: the bytes of the Pokedex tail the menu code reads) | melonDS DS 1.4.0 | run — the New Bark save with those flags, Emerald + its .sav: both show MIGRATE FROM EMERALD at frame 1520; with the save unmodified or no cart, neither does (FireRed, no .sav: MIGRATE FROM FIRERED here, not run on the core) | the game's own behaviour |
| `boot.nim` firmware_boot, `io/cart.nim` KEY1/KEY2 handshake | `ndsrun --boot firmware` with the user's three dumps: real BIOS -> card handshake -> firmware logo, health and safety, menu -> SoulSilver | melonDS DS 1.4.0 with `melonds_boot_mode=native`, `melonds_firmware_username=existing_username`, `melonds_firmware_favorite_color=default`, `melonds_firmware_language=default`, `--depth5` | run — same dumps, `--press TOUCH:128:100@350+5,TOUCH:128:45@700+5`, shots every 2-4 frames to 1700, decoded pixels compared: blank to frame 84 (core) / 86 (ours); logo and warning frames identical with ours 2 frames later; after the touch identical from 402 through the menu to 704; launch fade 708-764 differs (740 equal); white 768-968 and the intro 976-1092, 1196-1412 identical; later within 0-4 frames apart from the 3D scenes | GBATEK protocol, KEY1 and KEY2 chapters; the re-encrypted secure area's CRC16 equals header 06Ch (86A5) and the BIOS accepts it; the 2-frame lag in the BIOS phase is unexplained |


### NDS 3D engine

From our test ROMs (`tests/nds/src/3d_*`, built by `tests/nds/tools/build_3d.sh`)
run through `tools/ndsref` on melonDS DS 1.4.0, melonDS 0.9.3 (`--relocate`)
and DeSmuME, compared with ndsrun at frame 30. The 3D buffer is compared at
18-bit colour (the melonDS cores' undepthed output) where the top screen is
BG0 = 3D unmodified, else at 15-bit. The `3d_probe_*` ROMs draw
pseudo-random shapes from an LCG so a model can regenerate the exact vertex
lists and be fitted rule by rule; nothing was taken from any emulator's
source. "Exact" means 0 dots differ. Hardware evidence: the line captures
in StrikerX3/nds-interp (`data/images/TL.7z`, a DS test program's display
capture of a line from (0,0) to every (x, y)) — our edge rules reproduce
4376 of 4510 sampled captures dot for dot; the rest are 1-2 dots on runs
whose x(y+1) lands a few 2^-18 above a half dot (unresolved).

| Where | Behaviour | Compared against | How | Independent evidence |
|---|---|---|---|---|
| `gpu3d/render.nim` Edge, edge_run, draw_polygon | edge x = x0 << 18 + dx * floor(2^18/dy) * (y - y0), -1 when x decreases, exactly +-1.0 at 45 degrees; x-major runs cover dots whose centres lie in [x(y), x(y+1)] (half up), y-major edges the dot holding x(y), a vertical right edge its left neighbour; opaque polygons drop bottom x-major runs and right y-major dots except on the row above a flat bottom; wire-frames draw the runs plus the top row and the row above a flat bottom; lines (two distinct dots) are full size | melonDS DS 1.4 exact; 0.9.3 agrees on full-size, lines and wire-frames, differs 18-46 dots on opaque | run — 3d_probe_tri, _tri_edge, _tri_xlu, _tri_s2(_edge), _tri_flat(_edge), _line, _wire: exact | the nds-interp line captures above (97 % exact); GBATEK "Polygon Size" for which edges drop |
| `gpu3d/render.nim` edge_end, plot | 9-bit colours (6-bit * 8 + 7); span ends are the runs' outer ends with the edge attributes of the row that end belongs to; equal w: exact linear floor; else factor floor(n w0 2^P / (n w0 + (d - n) w1)), P = 9 on edges, 8 across spans | melonDS DS 1.4 exact; 0.9.3 differs (228-1044 dots) | run — 3d_probe_lerp, _tri_rgb, _persp, _persp_tex, _persp_w16/_w256: exact | none; GBATEK says only "perspective-correct" |
| `gpu3d/render.nim` plot (shadow) | the mask (ID 0) flags dots where its back face is hidden; the shadow draws only on flagged dots, clearing them, never on its own ID; no mask, no shadow | all three cores | run — 3d_shadow exact on all three | GBATEK "Shadow Polygons" words it the other way round ("drawn only if the stencil bits are zero") |
| `gpu3d/geometry.nim` TEXGEN_NORMAL_SHIFT / _VERTEX_SHIFT | 21 and 24 | all three cores | run — 3d_texcoord: 17/20 (GBATEK's parts table) off by 8.6k dots, 21/24 exact | GBATEK "Texture Coordinates" table gives the operand widths, not the shift |
| `gpu3d/render.nim` blend_texel | decal: (Rt*At + Rv*(31-At)) >> 5 with 5-bit At; highlight: texel modulated by (Rv, Rv, Rv), plus the toon colour | melonDS DS 1.4 exact; 0.9.3 differs (267 / 447 dots) | run — 3d_blendmodes, 3d_highlight exact | GBATEK "Texture Blending" (decal with 63-At, highlight modulating by the table colour) |
| `gpu3d/geometry.nim` to_screen | screen y = floor((w - y) * height / 2w) + 191 - y2 (top-down) | melonDS DS 1.4 | run — 3d_probe_clip: clipped vertices land a row low otherwise | GBATEK gives the bottom-up formula; it agrees on whole-dot vertices |
| `gpu3d/geometry.nim` clip_polygon, intersect | planes near, far, y, x; the new vertex sits exactly on the plane; coordinates and texcoords round down, 5-bit colours round up | melonDS DS 1.4 exact | run — 3d_probe_clip, _clip_persp (17 dots), _clipq exact; 3d_vcolor 3 dots, 3d_clip 86 | GBATEK "Clipping" (which vertices are made, not their arithmetic) |
| `gpu3d/geometry.nim` apply_normal | specular level 2 (N.H)^2 - 1 with H the unit half vector, through a 7-bit table index; the sum of all terms kept with 17 fraction bits, truncated once; diffuse level to 8 fraction bits | cores disagree: specular shape all three (1.4 closest, 31/192 quads off), sum precision melonDS DS only (0.9.3 and DeSmuME truncate per term), diffuse precision both melonDS (DeSmuME follows 12 bits) | run — 3d_probe_light, _light_spec, _light_tab, _light_sum | GBATEK "Polygon Light Parameters" gives (-H.N)^2 on the unnormalised H and real arithmetic; unclear |
| `gpu3d/render.nim` aa_cov, anti_alias, edge_mark | coverage: y-major edges at the row's middle within the dot, x-major edges the edge height at the column centre; right edges floor(32 c), left 31 - floor(32 (1 - c)); mixed over the colour drawn on, where a 4-neighbour has another ID and lies further; no coverage leaves the colour beneath; with edge marking the edge colour goes on at 17/32 over it | melonDS DS 1.4 and 0.9.3 agree | run — 3d_probe_aa (110 dots), _aa_edge exact; the neighbour rule from SoulSilver's title Lugia and overworld (no seams inside one-ID meshes); 3d_probe_aa2 shows same-ID edges blending where we do not (634 dots) | GBATEK "Anti-Aliasing" (opaque edges only, edge-marked edges translucent) |
| `gpu3d/gpu3d.nim` fifo_level | the first 4 entries queued behind a stalled command sit in the PIPE, uncounted | melonDS DS 1.4 | run — 3d_status: 40 queued behind SWAP_BUFFERS read as 36 | GBATEK "FIFO / PIPE Number of Entries" |
| `gpu3d/render.nim` plot (blending off) | a translucent dot over an opaque one with DISP3DCNT.3 off takes the polygon's alpha | DeSmuME agrees; both melonDS cores keep alpha 31 | run — 3d_alpha_noblend | GBATEK "Alpha-Blending" (bypassed: overwritten by Poly[R,G,B,A]) decides |
