# flashcart-runbook: the GB hardware session kit

`tools/make-flashcart-kit.sh` (needs the game-boy-test-roms cache) builds
`flashcart-kit/`; copy it to the SD card. Consoles on hand: **GBC (board
-04), GBP (MGB), GBA, GBA SP**. The GB flashcart works in the GBA/SP's GB slot
(CGB-compat mode on AGB silicon; gbedge MODEL reads `11 01`). The GB Micro has
no GB slot. No DMG and no SGB: the MGB covers the mono side (its boot seeds
differ from DMG's — that is data); SGB-only rows stay open.

## Rules

- **Menu pollution.** A flashcart menu runs before the ROM and restores the
  handoff registers (A/F/B/C/D/E/H/L, per model) but not the I/O ports it
  used. A menu polling "any key held" leaves P1 = $CF. On the MGB that is also
  the correct answer, so the contamination is invisible there; on the AGS it
  is wrong (the AGB boot ROM writes $FF to P1 before handoff; mooneye
  `misc/boot_hwio-C` asserts $FF for cgb+agb+ags). A byte that (a) is an I/O
  port, (b) is "untouched since boot" and (c) the menu plausibly used is not
  evidence on its own — cross-check against the boot ROM disassembly. Timing
  pages are unaffected. Use a hard-reset-to-game mode for gbedge p00/p01 if
  the cart has one; otherwise mark them menu-tainted.
- **No mapper tests.** The flashcart's FPGA answers MBC questions (MBC5 `$1A`
  enable, MBC3 latch, MBC30 banking, `$FEA0`). Those need real carts.
- **Cold boot, not reset**, for anything measuring power-up state (wramscan).

## Folders

**1. gbedge.gb** — protocol in docs/hwprobe.md. Order GBC, then GBA or SP, then
GBP; on GBA and SP photograph page 00 on both and skip the second if `ALL`
matches. Priority pages if cut short: 00 IDENT (post-boot port readback, boot
fingerprint, which CGB revision the -04 board carries), 02 TIMAGLITCH (the CGB
TAC-disable tick — GBC vs GBP photo is the answer), 03 TIMARELOAD, 15 M1STAT,
16 HALTPHASE, 17 WYLATCH, 18 CGBWRAM, 12 PCMPSG (CGB C vs E discrimination —
read before trusting any per-revision conclusion from the -04 board), 1A
SWEEP (GBC page vs GBA page).

**2. windesync** — nitro2k01's window-glitch ROM (SameBoy issue #278; D-pad
menu, hold A + direction). Run on GBP and GBC (hwprobe row 18): (1) arming —
window never enabled, WX=$07/WY=$00 over the pattern: any glitch column? then
enable-once-and-disable via the LYC toggles; (2) insert vs replace — with the
glitch over `%01000111`, does everything right of it shift one pixel?
close-up; (3) same on the GBC. Cross-check with folder 3's
`m3_lcdc_win_en_change_multiple_wx.gb` on the GBP (the two white pixels at
t=8/t=32, alignment either side) and `m2_win_en_toggle.gb` on the GBC (Pan
Docs' CGB note: clearing LCDC.5 resets the frame's Y condition — if true the
lower toggled bands differ from the DMG reference).

**3. strikethrough.gb** — GBC and GBP. Whole frame, then close-up of **LY 68,
x 71..78** (OAM entry 39; hwprobe row 17).

**4. rapid_toggle.gb** — mooneye, prints its verdict. GBP and GBC; with gbedge
p02 this pins the CGB TAC-disable tick. A CGB "fail" screen is data —
photograph the register dump.

**5. CRAM lock edges (GBC)** — gambatte `cgbpal_*` ROMs display a raw value;
`_outXX` in the name is what the cgb04c reference unit showed. Photograph the
11 rows dingbat fails (`cgbpal_m3end_{1,3}*`, `*_ds_*`, `*_lcdoffset*`,
`cgbpal_m3start_ds_1`, `cgbpal_read/write_m3start_ds_1`, `..._lcdoffset1_1`)
and anything whose value differs from its suffix (a revision split if the -04
board is CGB-D). The 8 `ly0_late_cgbp*` rows re-check the line-0 exemption.

**6. oamdma phase family (GBC)** — which `_ds_1`/`_ds_2` phase shows the
sprite value; if hardware matches the filenames the cgb04c references stand.

**7. APU** — `channel_3_restart_stop_delay.gb` on GBC (does NR30 DAC-off clear
the CH3 sample buffer — dingbat clears it citing this ROM);
`channel_1_sweep_restart{,_2}.gb` on GBC and GBA. The HPF charge question is
analog (line-out decay recording on GBP/GBC/GBA).

**9. rtcrate / wramscan** — `tools/gbprobe/roms/{rtcrate,wramscan}.asm`, build
with `mkcart.sh` (rtcrate needs header `$10`, MBC3+TIMER+RAM+BATTERY).
`rtcrate.gb` prints four rows of frame counts; dingbat `01DE` (478 frames per
8 RTC seconds), `003C` (a SECONDS write resets the sub-second divider), `001E`,
`001E` (MINUTES writes and halt/resume keep the remainder). `001E` in row 1 on
silicon would contradict rtc3test's `tests.md`. v3 seeds rows with `EEEE`
(`FFFF` = timed out); `rtcrate_mbc5.gb` is the no-RTC control (header `$1B`,
prints `FFF8/FFFF/FFFF/FFFF`) — if it draws and the MBC3 build stays white,
the cart refuses the header. `wramscan.gb` photographs power-up WRAM: line 0 =
ZEROS/FFS/OTHER over 8192 bytes, lines 2–17 a 16×16 map (one glyph per 32
bytes: `0`, `F`, `A` mixed); it writes nothing to WRAM before measuring — do
not "tidy" a `ld [$C000],a` into it. The map is the deliverable.

**9. g1** — `g1_scx0.gb`, `g1_scx4.gb` on the SP; header reads `00 FF` /
`04 FF`; no input. Read with `tools/gbprobe/read_g1.sh`.

## Results

### gbedge, GBP (MGB) + GBA SP — `tests/roms/expected/gb-mgb-1.txt`, `gb-agbsp-1.txt`

All 27 pages on both consoles, each verified against its on-screen
CRC-16/CCITT (init $FFFF), zero read errors. gbedge is CGB-flagged, so the SP
ran CGB-native (MODEL 11 01, ALL 052C); the MGB ran DMG-family (MODEL FF 00,
ALL 3FE7).

MGB vs dingbat `--model mgb`: 22 of 26 content pages byte-identical. Mismatches:

| page | hardware | dingbat |
|---|---|---|
| P06 SERIAL bytes 00/02/03 | 64/63/46 | 5D/64/40 (`start_wait_*` cluster) |
| P0F UNUSED bytes 1C/1D | 50 | 51 |
| P15 M1STAT byte 08 / 1B | E0 / E2 (identical on the SP, CRC F5C8) | E3 / E3 |
| P19 DIVTAPS bytes 08/09 | 88 00 (identical on the SP) | 00 20 |

P03 TIMARELOAD and P05 IEPUSH match byte-for-byte on both consoles.

AGS-native values (no dingbat reference: the gbedge viewer white-screens under
`--model cgb/agb`, a dingbat bug): P00 SC = $7C, SVBK = $F8, RP = $3E (no IR
window on an SP; dingbat leaves RP unmapped → $FF), VBK $FE, KEY1 $7E, FF75
$8F, OPRI $FE, DIV $1F, LY $91, STAT $81; **P1 = $CF is menu-contaminated**.
P18 CGBWRAM byte 0A = **5C — `$D000` banks** (banks 2–7 distinct, SVBK 0→1
alias only). P1A SWEEP byte-identical to the MGB page — **no second overflow
check in the GB-slot APU**. Model splits captured for decode: P02 bytes 10–13,
P06 bytes 02/05/06, P0B, P0D, P0F (`$FEA0` echo `AA..FF`), P10, P13/P14,
P16, P17.

### GBA SP photos IMG_3803–3808 (`hwphotos/`)

**cgb-acid-hell (IMG_3803): the reference is hardware-correct on AGS.** The
pass state is the near-blank screen with the yellow smiley; the two disputed
pixels are its mouth — the reference draws a "∨" (dark at (79,68), (81,68),
(80,69)), dingbat a flat bar (dark at (79–81,68)). A grid fit of the photo
(both eyes dark, cheek yellow, as controls) reads (80,68) yellow and (80,69)
dark — the reference's values. The runner must pass `--color`; without it the
capture is the compat-grey view.

probe_c ×3 (IMG_3804–3806), daid (3807), probe_b (3808): archived, not
machine-read — probe (c) draws on black and `photowarp.py` cannot find the
panel; the fix is four white corner tiles in the ROM and a re-shoot.
`find_panel.py` locates the SP's lit panel for ROMs that have a border.

### g1, GBA SP (`flashcart-kit/9-halt-lead/IMG_g1_scx0.jpg`, `IMG_g1_scx4.jpg`)

Read with `tools/gbprobe/read_g1.sh`. SCX 0: `24 32 32 40 40 48 48 56 56 64
64 71 71 79`; SCX 4: `20 28 28 36 36 45 45 53 53 61 61 69 69 77` (trailing
+1s are perspective drift). dingbat predicts `32 40 40 48 …` / `28 36 …` at
lead 0 and `40 40 48 …` / `36 36 …` at lead 1: 8 px (2 M) out with
`CGB_HALT_PPU_LEAD=0` and 16 px (4 M) with it on, so the long-standing 2–3 M
offset of probe (e) is a dingbat defect. It does not unship the lead:
`cgb-acid-hell`'s reference is hardware-correct on the same console
(IMG_3803) and daid's is a silicon capture; both are exact only with the
lead, and an instrument 2 M wrong cannot arbitrate a 1 M answer.

What is known about the 2 M (`tools/gbprobe/probe_f_base.sh --plain`, target
BASE 26, dingbat 24 at lead 0):

- Not the halt: `-DANCHOR_POLL` (reach the anchor by polling `rLY`, no `halt`)
  is still 3 M out.
- Not `CGB_TDSEL_LATENCY` (1→24, 5→23, 9→22, 13→22) nor `CGB_PIPE_MCYCLES`
  (1→24, 2→23; 0 gives no common BASE across SCX). Both move BASE down as they
  grow; the fix must retard the PPU against the CPU.
- Machine axis: DMG BASE 27 (1 M early), CGB compat 24, CGB native 24 (2 M
  late) — a DMG/CGB split, not native/compat.
- Not the VBlank header drawing (`-DNOHEADER` unchanged).
- Hypothesis: daid's ruler is BGP (emission) and is exact on the same machine;
  probe (e)'s is LCDC.4 (the fetch grid). A 2 M separation between emission and
  the fetch grid is the axis `docs/gb-failure-triage.md` names. Probe (c) puts
  both rulers on one frame; its SP photos (IMG_3804–3806) cannot be registered
  because the ROM draws on black — add four white corner tiles (no timing
  change) and re-shoot.

### wramscan, GBA SP

    through the cart menu   050D 00DF 1A14   zeros 1293, $FF 223, other 6676
    direct boot (SD out)    0171 00DD 1DB2   zeros  369, $FF 221, other 7602

The direct boot removed 924 zero bytes (the loader's cleared work area) while
$FF barely moved; **93 % of WRAM is neither $00 nor $FF**, with ~369 zeros and
~221 $FF — far more than uniform random (~32 each), so there is structure on
top of the noise. A loader still runs before the ROM on a direct boot, so 369
is an upper bound on the true zero count.

## Getting results back

One folder of photos per console. gbedge pages: `tests/roms/hwprobe_ocr.py`
reads dingbat screenshots of the same build for the diff side; photos are
compared by eye. File each delta as a row in docs/hwprobe-questions.md or
docs/pandocs-upstream.md §2 — each names the knob or model it moves.
