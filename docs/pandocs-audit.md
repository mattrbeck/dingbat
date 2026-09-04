# pandocs-audit: where dingbat disagrees with Pan Docs

The disagreement list between `src/dingbat/gb/` and Pan Docs (gbdev/pandocs
master). Every row carries its evidence or `Assumed`. Items where the evidence
is settled against Pan Docs' text are drafted as upstream corrections in
docs/pandocs-upstream.md §1; items that need hardware are its §2. Rows that
were fixed to agree with Pan Docs are not listed — git history has them.

Excluded: the Star Trek window insertion glitch (docs/hwprobe-questions.md
row 18), Pan Docs sections marked TODO, SM83 instruction pages (blargg green),
analog-only matters.

## A — Pan Docs may be right; dingbat differs and nothing pins it

| # | Pan Docs | dingbat | evidence |
|---|---|---|---|
| A5 | Timer_Obscure_Behaviour: the TAC-disable glitch tick "does not happen on Color models" | ticks on every model (`timer_check_edge`, FF07 write) | mooneye `rapid_toggle` is DMG-side only. **Hardware pending**: gbedge p02 TIMAGLITCH bytes 10–13 are captured on MGB and AGS, undecoded |
| A6 | Timer pages: a glitch-caused overflow also passes through the 1-M-cycle reload window (TIMA reads 0, TIMA write ignored / TMA write propagates in cycle B) | glitch overflows reload TMA on the write's own M-cycle (`timer_check_edge(on_write=true)`) | mooneye `rapid_toggle` **fails** when the countdown is armed instead — the write-commit phase already supplies the delay. What that phase cannot express is the window interior for a DIV-write overflow; no ROM pins it |
| A8 | OAM_Corruption_Bug: "Any memory access instruction, if it accesses OAM" in mode 2 corrupts | only the 16-bit IDU family (inc/dec rr, ld [hl±], push/pop, dispatch) reaches `oam_bug_if`; plain loads go through `cpu_oam_open` | blargg `oam_bug` is green either way (its causes ROMs never test plain accesses). Probe run on an AGS in GB mode 2026-09-04 (tools/gbprobe probe_k_oamclass): **no class corrupts OAM there**, plain accesses included; DMG still to photograph. Deferred: wiring it must not double-fire the IDU sites |
| A9 | Audio_details: envelope timer gets +1 when a trigger lands just before an envelope step | `init_volume_envelope` sets `timer = period` unconditionally (the length analogue is modelled) | no SameSuite row pins it; Assumed Probe built: gbedge page 1E ENVPHASE, unrun. |
| A10 | Audio_Registers NR10: pace 0→nonzero write reloads the sweep timer | NR10 write stores fields only; the "instantly disabled" half is modelled | no SameSuite row pins it; Assumed Probe built: gbedge page 1F NR10PACE, unrun. |
| A12 | Window.md CGB note: clearing LCDC.5 resets the frame's window Y condition | `window_trigger` clears only at mode 1 | mealybug `m2_win_en_toggle` is DMG-referenced only. Hardware: flashcart-runbook folder 2 |
| A13 | pixel_fifo.md: CGB performs the object fetch (and pays the penalty) with LCDC.1 off, gating only display | trigger and mode-3 length both require `sprite_enabled` on every device | modelling it swaps every sibling pair of gambatte `oamdma/late_sp*` phases (`fifo_ppu.nim`); `CGB_OBJ_ABORT=0` points Pan Docs' way. A one-fast-M-cycle phase term is needed before it can ship; gambatte `sprites/enable/*_cgb` and hardware (flashcart folder 6) arbitrate |
| A14 | Power_Up_Sequence: post-boot P1 = $C7/$CF on SGB/CGB/AGB; SC(CGB) = $7F | P1 = $FF (no select line low); SC = $7C | **hardware AGS: SC = $7C** (gbedge p00) — dingbat right. P1: the AGB boot ROM (the CGB boot ROM with `AGB=1`) writes $FF before handoff and mooneye `misc/boot_hwio-C` asserts $FF; the AGS photo's $CF is flashcart-menu contamination (docs/flashcart-runbook.md) |
| A19 | SGB_Command_Multiplayer: MLT_REQ pads are distinct controllers | the ID counter is modelled; every ID reads the one physical pad (`joypad_lines`) | frontend plumbing (the 2P link-mode input path is the donor) |
| A24 | Audio_details: HPF charge 0.999958 (DMG) vs 0.998943 (MGB/CGB) | one `GB_DC_CHARGE` on every model | analog only; no capture exists. Assumed |

## B — documented, knowingly unmodelled (test-ROM visible at most)

- RP `$FF56` unmapped: reads $FF (hardware AGS: $3E). Bit 1 = 1 is the correct
  "no IR signal", so handshakes time out gracefully (`gb.nim`).
- OPRI `$FF6C` / KEY0 `$FF4C` not decoded as registers — derived from the
  header / `cgb_native`; diverges only for readback or a custom boot ROM.
- `$FEA0-$FEFF` while OAM is blocked should read $FF (and corrupt on DMG);
  dingbat answers the per-revision idle model in every mode (`memory.nim`).
  Hardware AGS: echo pattern `AA..FF` captured (gbedge p0F).
- PC executing inside OAM never triggers the corruption bug (`ppu.nim`).
- SCY sampled per bitplane on every CGB revision — correct for ≤ CGB C; CGB D+
  read it once (docs/gb-mealybug-sources.md, SCY; `m3_scy_change` `_cgb_d`
  differs by 6217 px).
- Serial: no per-bit SB blend on a live link, no irregular external clocks
  (byte-duplex driver contract, `serial.nim`); disconnect pull-up ramp
  unmodelled.
- CH4 all-DACs-off: hardware outputs hard 0 and holds the HPF charge; dingbat
  drains a decay tail. Sub-audible.
- SGB/SGB1 clock (+2.41 %) and SGB1 APU pitch: runs at handheld speed.
- SGB PCT_TRN 29th tilemap row (`$700-$73F`) not rendered.
- Camera: an interrupted capture leaves a complete new image (matches Pan
  Docs' own sample code).
- Web frontend attaches the printer in SGB1 sessions (SGB1 has no link port).

## C — dingbat deliberately disagrees, evidence on dingbat's side

Each of these is a candidate Pan Docs correction (docs/pandocs-upstream.md).

| Pan Docs | dingbat | evidence |
|---|---|---|
| CGB_Registers KEY1: speed-switch stall 2050 M-cycles; "DIV does not tick" | 131072 destination-clock cycles; timer/serial/OAM-DMA run through the stall | gambatte `speedchange_tima00_*` (+128 TIMA ticks), LY across the stall, daid `speed_switch_timing_*` `expect:` tables |
| Interrupts: IF bit cleared at dispatch step 1 | IF clears at the end of dispatch (T ∈ (15,19]) | gambatte `*_late_retrigger` families. Dispatch M-cycle order (pushes first vs waits first) is suite-undecidable — Pan Docs' SonoSooS order is plausible; hardware-able |
| MBC3: latch on `$00` then `$01` | any write to `$6000-$7FFF` latches | CasualPokePlayer `latch-rtc-test` capture: 51/51 reports under "any write", 28/51 under the bit-0 edge |
| CGB_Registers HDMA5: early-termination readback = remaining blocks − 1 | the terminating write's own low 7 bits land in the register | SameSuite `dma/hdma_lcd_off` |
| OAM_DMA_Transfer: the PPU reads $FF during OAM DMA | the PPU reads the DMA unit's bus byte | `strikethrough.gb` pixel-exact (the mode-2 scan lock is hwprobe row 17) |
| STAT: the DMG STAT-write glitch fires in "OAM scan" | mode 2 excluded (only the hblank→mode-2 edge) | GBMicrotest `stat_write_glitch_l0_c/l1_d/l154_c`; −11 gambatte rows to put it back |
| OAM: writes blocked throughout mode 2 | admitted in mode 2's last M-cycle | mooneye `lcdon_write_timing-GS`, GBMicrotest `oam_write_l1_c` |
| pixel_fifo.md: X=0 object penalty depends on SCX (Rendering.md says flat 11) | flat 11 dots | GBMicrotest `ppu_spritex_vs_scx` (153/153 cells) |
| Timer_and_Divider_Registers: TMA written during the reload cycle → old value | new value | mooneye `tma_write_reloading`; Pan Docs' own Obscure page says new |
| Audio_details envelope "zombie mode" rule | a larger truth table | SameSuite `channel_1_volume`, `nrx2_glitch` |
| Audio_Registers NR10: sweep trigger actions immediate | 3/9/7 M-cycle delays, NR10 re-read at check time | SameSuite `channel_1_sweep_restart*` |
| Audio: CH3 sample buffer clears only on APU power-on | also clears on NR30 DAC-off | SameSuite `channel_3_restart_stop_delay`; hardware re-check queued (flashcart folder 7) |
| Power_Up_Sequence footnote: CGB registers read $FF in Non-CGB mode | VBK reads `$FE|bank`; FF72/73/75/PCM12/34 answer in compat mode; KEY1/SVBK/HDMA/RP/FF74 do read $FF | mooneye `misc/bits/unused_hwio-C` |
| Gameboy_Printer: status bit 2 = "image data full" | bit 3 is data-present, bit 2 is print-done | real carts: Hello Kitty and Camera Gold re-print forever under clear-on-read variants |
| MMM01 heading: RAM-bank-high is bits 1–2 | bits 2–3 | Pan Docs' own diagrams |
| STOP with LCD on (DMG): "horizontal black line" | leaves the frame white | daid `stop_instr.gb` reference; panel decay is analog |
| Compat colorization per title | one fallback palette | boot-ROM data deliberately not lifted |
| OAM_DMA_Transfer: "CPU can access only HRAM during OAM DMA" | per-bus conflict model | 314 gambatte `oamdma/busy*` rows, 0 mismatches |
| CGB_Registers SVBK: R/W | write 0 reads back $F8 raw | hardware AGS: SVBK = $F8 (gbedge p00) |
| MBC5: RAM enable = exactly $0A | any low nibble $A | MBCs.md current text; hardware unconfirmed (needs a real MBC5 cart) |

## D — subsystems absent

- 4-Player Adapter (DMG-07): degrades as "not plugged in".
- SNES-side SGB commands (SOUND/SOU_TRN, OBJ_TRN, DATA_SND/TRN/JUMP,
  ATRC_EN/TEST_EN/PAL_PRI): accepted and dropped (`sgb.nim`). SOUND is audible
  on hardware, OBJ_TRN visible. SGB auto-freeze on LCD off and ICON_EN bit 2
  are modelled.
- Mappers: M161, EMS multicart, Wisdom Tree (> 32 KiB), Bung detection
  ("proposal" pages). HuC3 tone generator and MCU busy window are
  instant/silent (`huc3.nim`).
- Header logo/checksum lockup: not enforced without a user boot ROM.
