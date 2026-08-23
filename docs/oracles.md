# Behaviours pinned only by another emulator

Policy: code comments cite hardware evidence — Pan Docs / GBATEK, a test ROM,
a hardware probe, or an issue with photographs — or say `Assumed`. Where a
modelled behaviour was instead settled by comparing dingbat against another
emulator (SameBoy, DocBoy, mGBA, NanoBoyAdvance, ares, gambatte) and no
independent evidence exists in the tree, it is listed here. Each row is a
candidate for a probe ROM (docs/hwprobe-questions.md). Rows marked *also
ROM-pinned* have test-ROM evidence too; the comparison only chose between
readings the ROMs could not separate.

## GB core

| Where | Behaviour | Compared against |
|---|---|---|
| `gb.nim` TIMER_IRQ_RUN_LEAD | running-CPU timer dispatch one M-cycle ahead of the halted wake (also ROM-pinned) | SameBoy |
| `gb.nim` CGB_LYC_WRITE_DEFER | CGB LYC write reaches the comparator one M-cycle later than DMG (also ROM-pinned) | SameBoy |
| `gb.nim` LYC_SETTLE_HALT_SKIP | halted wake lands on the near side of the LY 153→0 blind window (daid ppu_scanline_bgp also pins it) | SameBoy |
| `gb.nim` CGB_HALT_PPU_LEAD | halt-wake PPU lead on normal-line LYC wakes, absent on the LY 153→0 snapback (acid-hell and daid frames also pin it) | SameBoy |
| `gb.nim` VDMA_OAM_BUS_CAPTURE | OAM DMA stores the VRAM DMA's byte at the HDMA source's low byte (gambatte hdma_transition_oamdma_1 pins the scored byte) | SameBoy |
| `gb.nim` HDMA_HALT_M0_BLIND | only the HALT's position moves hdma_late_m0halt's answer | SameBoy |
| `gb.nim` HDMA_OVERHEAD_LEADS | six injected bytes / six lost OAM slots over the OAM walk | SameBoy |
| `gb.nim` CGB_WIN_RESTART_COUNTER | CGB window restart would resume at fetch counter 1; ships 0 (= DMG) | SameBoy via probe (f) |
| `gb.nim` GbQuirks.lyc_compare_hold | wilbertpol ly_lyc*-C values hold from CGB D onward, not 0–C | SameBoy per revision |
| `gb.nim` GbQuirks.ly_read_edge_late | $FF44 snapback read one M-cycle later on CGB D/E/AGB, single speed (AGE ly-cgbBC/E also pin it) | SameBoy per revision |
| `gb.nim` GbQuirks.m1_end_no_mode0 | CGB D+ go straight from $81 to $82 at the end of mode 1 (AGE stat-mode pins it; no emulator agrees) | — |
| `gb.nim` GB_MIX_SCALE / GB_DC_CHARGE | 1/8 output level and the DC-blocker trajectory | SameBoy PCM dumps |
| `cpu.nim` CGB_HALT_LEAD_SKIP_LYC0 | the CGB halt-wake lead is present for LYC = 1, 8, 40, 100 and absent only on the snapback | SameBoy (CGB compat), LYC-swept daid ROM |
| `fifo_ppu.nim` M3_PIPE_AHEAD | the DMG mode-3 pipeline advance is device-independent; daid's DMG refusal is confined to its snapback anchor | SameBoy |
| `ppu.nim` ppu_store_lcdc | WY re-check when LCDC.5 turns on | SameBoy |
| `ppu.nim` LCD_ON_FRAME_DOTS | 10·456 dots as the artificial-vblank threshold after LCD-on (frontend pacing) | SameBoy |
| `memory.nim` skip_boot | OBP0/OBP1 hand off $00 on CGB/AGB, $FF on DMG/MGB/SGB; AGB P1 = $FF | SameBoy boot-ROM I/O dump |
| `memory.nim` CGB write latency | the six per-register latencies exist as independent numbers | gambatte, SameBoy |
| `memory.nim` SPEED_SWITCH_STALL_T | 2^16 + 4 dots as the raw stall (blargg cpu_instrs frames pin the region) | SameBoy |
| `memory.nim` SPEED_SWITCH_FREEZES_OAM_DMA | OAM DMA frozen across the stall | SameBoy |
| `memory.nim` mem_vdma_bus_capture | `dma_position <= 0xA0` as "OAM DMA active" | SameBoy |
| `interrupts.nim` IF_READ_SAMPLE_T | a $FF0F read in the handler returns 0 then 1 (read latches early; VBlank source not late) | SameBoy |
| `timer.nim` timer_check_edge | a glitch overflow reloads through the same one-M-cycle window as a natural one (mooneye rapid_toggle also pins it) | SameBoy, DocBoy |
| `timer.nim` SPEED_SWITCH_DIV_RESET_T | the DIV reset lands one M-cycle after the STOP fetch | SameBoy |
| `serial.nim` serial_master_edge | half-rate master toggle off DIV bit 7 (bit 2 CGB fast), reseeded low by an SC write (gambatte serial/* also pin it) | SameBoy |
| `serial.nim` SERIAL_DIV_WRITE_LEAD_T | 4 T before the end of the store's M-cycle (only the T-cycle within the M-cycle is by comparison) | SameBoy |
| `apu/channel1.nim`, `channel2.nim` | CGB D/E half-tick backstep moves only the duty position, not the latched sample | SameBoy |
| `apu/channel2.nim` ch2_pcm_edge_zero | channel 2's PCM12 nibble reads 0 on a rising duty step on CGB 0–C (mirror of channel 1's ROM-pinned rule) | SameBoy |
| `printer.nim` | status sequence, ~7.5 frames per row, done-bit latch, full-band-only DATA, pre-exec ACK | SameBoy (Pocket Camera / Camera Gold behaviour corroborate) |
| `mbc/mbc7.nim` | whole MBC7 model; EEPROM words little-endian in `ram` for .sav interchange | SameBoy |

## GBA core

| Where | Behaviour | Compared against |
|---|---|---|
| `gba/ppu.nim` new_ppu | BG2PA/BG2PD reset to 0x100 | mGBA |
| `gba/ppu.nim` obj_geometry | signed OBJ X/Y (x > 239 → x−512, y > 159 → y−256) rather than mod-256 | mGBA, NanoBoyAdvance |
| `gba/ppu.nim` render_sprites | OBJ budget: the sprite that exhausts it still draws fully (hardware likely truncates — hwprobe row 26, open) | mGBA |
| `gba/ppu.nim` render_sprites | OBJ fetches wrap within OBJ VRAM; 8bpp name low bit cleared only under 2D mapping | mGBA, NanoBoyAdvance |
| `gba/bus.nim`, `gba.nim` | DMA open-bus word visible to the DMA's own reads and the first CPU instruction after the burst (GBATEK pins only "recently transferred data") | mGBA |
| `gba/bus.nim` tilt_read | tilt X ADC-ready bit always set | mGBA |
| `gba/bus.nim` UND vector stub | stub keeps only `subs pc, lr, #4` | mGBA |
| `gba/gpio.nim` gyro_update | gyro ADC shifts on the falling serial-clock edge | mGBA |
| `gba/cartridge.nim` | 1 MiB ROMs mirror 4× in a 4 MiB window (Classic NES Metroid's check is the in-game pin) | mGBA |
| `gba/storage/eeprom.nim` | 115000-cycle settle (GBATEK ~6.5 ms); reads in 0x0E/0x0F return 0xFF; every data bit restarts the window | mGBA |
| `gba/apu.nim` | SOUNDCNT_H PSG volume 3 silences the PSG; SOUNDBIAS resolution masks with two guard bits | NanoBoyAdvance, SkyEmu; ares |
| `gba/hle_bios.nim` | Div by zero returns ±1 / numerator / 1; RegisterRamReset clears IE/IF/WAITCNT/IME and leaves PA/PD at identity; Sqrt phase constants | mGBA HLE (games rely on the first two) |

## Test-harness decisions

| Where | Decision | Compared against |
|---|---|---|
| runner: wilbertpol ly_lyc*-C | not scored; behaviour placed at CGB D+ | SameBoy |
| runner: GBMicrotest halt_op_dupe_delay, stat_write_glitch_l154_d | skipped as ROM defects (derived from source; cross-checked) | SameBoy |
| runner: jsmolka frame hashes | pinned hashes for ppu/hello, shades, stripes, nes | mGBA, NanoBoyAdvance |
| runner: SameSuite APU default revision | CPU CGB E | SameBoy verdict grid |
| `--screen-check` | asserts settled + multi-shade, not glyphs (blargg loses cells to mode-3 refusal at double speed) | SameBoy |
