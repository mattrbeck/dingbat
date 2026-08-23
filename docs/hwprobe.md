# hwprobe: gbedge.gb + gbaedge.gba — hardware edge-case probe ROMs

`tests/roms/gbedge.gb` (27 pages, DMG+CGB) and `tests/roms/gbaedge.gba` (37
pages), built from committed sources. Questions: docs/hwprobe-questions.md;
results: docs/hwprobe-results-agb.md, docs/flashcart-runbook.md.

A bundled suite bakes its expectation into the ROM; these ROMs store the **raw
observed values** of a deterministic power-on sequence into 32-byte slots and
show them as hex (LEFT/RIGHT or A/B; wraps). Photograph every page on a
console, screenshot the same pages in an emulator, diff.

Every page shows `CRC` (this slot) and `ALL` (over every slot) — one photo of
any page fingerprints the whole run. `MODEL` identifies the machine (GB: boot
A/B — DMG=01, MGB/SGB2=FF, CGB=11+B.0=0, AGB-in-CGB-mode=11+B.0=1; GBA: BIOS
checksum low half).

## Hardware protocol

1. Flash the **manual** build to a cart.
2. Per console: photograph page 0 (IDENT + ALL). If ALL matches a console
   already captured, the run is identical.
3. On one console per distinct ALL: photograph all pages.
4. GB page 06 SERIAL: run with no link cable attached.
5. GBA pages 08 MSRTBIT and 18 BXDECODE run only on **START** and provoke
   UNPREDICTABLE behaviour; run them last. BXDECODE runs one candidate per
   START press (photograph between presses); after a freeze, power cycle,
   page back to 18, press **SELECT** once to skip the wedging candidate
   (candidate k wedged if the freeze came on press k+1).
6. Emulator side: the `-auto` builds flip pages every 64 frames;
   `tests/roms/hwprobe_ocr.py <shot.ppm>` reads a dingbat screenshot back as
   text. Compare photos against the **same build** you flashed — a few GBA
   open-bus/pipeline bytes differ between manual and auto binaries.

Caveats: GBA WAITSTATE/prefetch rows and open-bus-from-ROM bytes are
flashcart-influenced (note the cart); everything else is on-die. Boot-handoff
port bytes are suspect behind a flashcart menu (docs/flashcart-runbook.md).
gbedge on a GBA/SP runs only via a GB-slot flashcart (CGB-compat mode, MODEL
`11 01`); a GBA-slot GB emulator measures the emulator.

Debug: gbedge mirrors `$FF80` = index of the probe running and `$FF82` = 01
once the viewer is alive (`--mode=microtest --list=...`).

## GB pages (gbedge.gb)

| pg | name | probes |
|---|---|---|
| 00 | IDENT | boot A F B C D E H L SP, DIV/LY/STAT/IF/LCDC/IE at a fixed entry offset, then P1 KEY1 VBK SVBK FF72-77 OPRI RP SB SC TAC FF03 |
| 01 | DIVPHASE | DIV reset→first-increment distance at 1 M-cycle resolution; TIMA-vs-mux phase at TAC=05 |
| 02 | TIMAGLITCH | falling-edge detector: DIV-write glitch, TAC-disable glitch, TAC 05→06 switch glitch, 4-freq rate row (expect 01 40 10 04) |
| 03 | TIMARELOAD | TIMA across overflow (position+width of the 00 window), TIMA/TMA write in window, IF timing |
| 04 | HALTBUG | halt-bug duplication, EI delay (ei/nop, ei/di), ei/halt wake, IME=0 halt wake latency |
| 05 | IEPUSH | dispatch with SP=0000 so the PC-high push lands on IE; run 1 keeps the bit, run 2 clears it; IF disposition |
| 06 | SERIAL | no-cable internal-clock duration, SC=83 on DMG, DIV reset mid-transfer, SB mid-shift, external-clock stall |
| 07 | IFVBLANK | IF.0 rise vs the LY 143→144 boundary, LY+STAT anchors |
| 08 | STATSEQ | STAT mode string across line 40 (20-dot cadence), SCX=5 mode-3 stretch |
| 09 | LY153 | four 1-M-cycle-phase sweeps over 152→153→0 at 4-dot resolution + LYC=153 flag timing |
| 0A | LCDON | STAT string right after LCDC.7 set, first-line length via LY |
| 0B | STATWBUG | STAT=00 written in vblank/mode0/mode3/mode2/LYC-match, IF.1 polled after each |
| 0C | STATIRQ | STAT IRQs per frame for 6 source combos (blocking fingerprint) |
| 0D | OAMDMA | reads of WRAM/VRAM/ROM/OAM/ECHO during OAM DMA for 4 source buses + OAM after |
| 0E | OAMCORRUPT | inc hl/dec hl/inc de at $FE30 in mode 2 at 3 offsets + vblank control; count, first index, row bytes |
| 0F | UNUSED | FEA0-FEFF, unmapped IO, P1 both/neither select, IF/IE upper bits, STAT/TAC/SC write-FF readback, DIV double-read |
| 10 | VRAMLOCK | VRAM/OAM/BCPD read values per mode; are locked writes dropped |
| 11 | HDMA (CGB) | GDMA cycles via TIMA, HBLANK-DMA countdown, mid-run cancel readback, armed-across-LCD-off |
| 12 | PCMPSG (CGB/AGB) | 24 PCM12 samples at 5 M-cycles after ch1 trigger, ch2 join, NR52 flags |
| 13 | DSTAT (CGB) | STAT string + LY153 in double speed (10-dot sampling) |
| 14 | SPEED (CGB) | KEY1 switch: DIV reset, TIMA across the stall, LY across both switches, double-rate DIV |
| 15 | M1STAT | IF bits 0+1 across 143→144 at 4-dot resolution, mode-1 source only; mode-2-source-at-144; control |
| 16 | HALTPHASE | halt-woken handler vs timed sled racing one mode-0 edge, TIMA- and LY-stamped, SCX 0 and 3 |
| 17 | WYLATCH | mode-0-IRQ timestamp of the window-start line while the WY write walks across line 39 |
| 18 | CGBWRAM | $D000 banking under every SVBK value with alias sentinels (byte 0A: 77 alias, 5C banking) |
| 19 | DIVTAPS | serial-completion and APU length-expiry poll counts at 8 DIV-reset phases (staircase periods are the tap bits) |
| 1A | SWEEP | ch1 trigger overflow at freq 1300/940/1024/1000 shift 1 + divider-0 cap (the AGB second-check question) |

CGB-only pages show `EE` at offset 1F on DMG-class hardware.

## GBA pages (gbaedge.gba)

| pg | name | probes |
|---|---|---|
| 00 | IDENT | BIOS checksum, boot DISPCNT/greenswap/WAITCNT/KEYINPUT/POSTFLG/0x04000800/CPSR/SP, open bus |
| 01 | OPENBUS | 0x0, 0x4000, 0x01000000, 0x10000000 words; 16/8-bit; the same read from EWRAM and IWRAM; 16-bit dup from ROM |
| 02 | BIOSPROT | BIOS-region reads post-startup / post-SWI / inside an IRQ / post-IRQ |
| 03 | SWITIME | timer-cascade cycle counts for Div, Sqrt, ArcTan2, CpuSet ×3, CpuFastSet, BgAffineSet |
| 04 | TIMERS | prescaler phase sweep, enable latency, cascade with reload FFFC, reload-latch mid-run vs restart |
| 05 | DMALATCH | open bus after DMA, cycles stolen by a 16-word DMA, DMA from BIOS, DMA0 from ROM, misaligned source |
| 06 | LDMSTM | stm base-in-list, ldm base+wb, empty-rlist STM/LDM, rotated unaligned LDR |
| 07 | MULFLAGS | C after 8 MUL operand pairs × C preset 1/0 + UMULLS/SMULLS |
| 08 | MSRTBIT | **START**: `msr cpsr_c` with T set from ARM; breadcrumbs at A+4/6/8/10 |
| 09 | PPUSTAT | [DISPSTAT,VCOUNT] pairs across line 40, after hblank-flag rise, vblank entry |
| 0A | PSGSTAT | ch1 active flag after trigger, polls to length expiry, SOUNDBIAS boot, ch3 wave bank readback |
| 0B | WAITSTATE | 16 sequential ROM reads under 4 WAITCNT settings; 32-nop ROM call prefetch off/on |
| 0C | PFPHASE | one timer-bracketed ROM read after k=0..7 sequential fetches, two waitstate settings |
| 0D | SWIREGION | Sqrt at 4 inputs between calibration points; Div and CpuSet from IWRAM/EWRAM/ROM callers |
| 0E | CONTEND | timed PRAM/VRAM/OAM/EWRAM reads mid-line visible vs forced blank vs hblank vs vblank, plus VRAM writes |
| 0F | IRQLAT | trigger-vs-handler TM0 stamps for TM2-overflow / DMA3 / hblank / vblank IRQs |
| 10 | IORW | 16 halfword reads of write-only and unused IO before any IO write |
| 11 | CPSRBITS | all-ones writes to each CPSR field; SPSR_irq written FFFFFFFF / 0 / 0F; mrs SPSR in system mode |
| 12 | THUMBPC | stored-value deltas for `str pc` / `stm {pc}` / `stm {lr,pc}`; `ldm pc`; Thumb `cmp pc, r0` with a loaded SPSR; `mov r0, pc` |
| 13 | LDMUSER | `stm {r13}^`, `stm r4!, {r13}^`, `stm r13!, {r13}^`, mrs SPSR after `ldm ^` |
| 14 | IRQWIN | a parked TM2 IF bit released through IME / CPSR.I / IE with a sled behind the store; 16 IF-acks vs a 16-cycle overflow loop |
| 15 | DMAEDGE | byte writes 0x80 to 0xDF/0xDE/0xDD with did-it-run + CNT_H readback; vblank DMA disabled before any vblank |
| 16 | CAPDMA | DMA3 Special timing with repeat; destination ring after frames 1/2/3 + CNT_H |
| 17 | SWEEPQ | ch1 sweep death times: period 0, immediate-trigger recalc, unwritten second recalc, mid-note rewrite, length control |
| 18 | BXDECODE | **START, one per press**: BX r1, `E12FFF31`, `E120FF11` (SBO violated), BX r15; r7: 1 = took BX, 6 = fell through, 4 = $+8 |
| 19 | THUMBPC2 | Thumb `cmp/add/mov pc, r0` with SPSR in a different mode; `ldm/str/ldr r15` writeback rows |
| 1A | IRQWIN2 | IRQWIN gates TM0-timestamped + EWRAM-load sled + one-shot overflow swept in 2-cycle steps across an IF-ack |
| 1B | IOBYTE | byte writes 0x44 to low then high byte of eight readable registers, halfword readback |
| 1C | LDMUSER2 | `ldmia r0,{r1-r7}^` in IRQ mode with SPSR flags disjoint from CPSR; mrs SPSR in the shadow |
| 1D | PCWB2 | five r15-writeback forms from EWRAM (str ±8/−4 post, str pre, ldr +8, stm) |
| 1E | DMABYTE2 | hi-byte strb 0x80 on DMA0/1/2; DMA3 hi 0xC0 / lo 0xC0 / hi 0x40 |
| 1F | SWEEP2 | ch1 sweep rows freq 512 s1, 2018 s7, 940 s1, 2033 s7 (second check / first calc exactly at 2048) |
| 20 | IRQWIN3 | IME-gate sled with 4-I-cycle muls, waitstated ROM loads, mixed sled; ack-race at 4-cycle steps |
| 21 | IRQLAT2 | TM2 latency with irq_arm r5 reload fixed: reload 0 one-word, FF00 one-word, FF00 two-write, FFF0 |
| 22 | IOBYTE2 | DISPSTAT lo strb 0x38, hi strb 0x38, 16-bit control, 16-bit-then-byte-clear |
| 23 | THUMBPC3 | Thumb `cmp pc` at A%4==2 with a T-clearing SPSR (overlay block); System-mode cmp; v7 row (c) resume ladder W+8/12/16, r4 captured |
| 24 | MSRTBIT2 | MSRTBIT block run twice under the watchdog: immediate-form `msr CPSR_c,#0x3F`, register form setting T and IRQ→System in one write |

## Expected results

`tests/roms/expected/` holds one directory per transcribed hardware run: PNGs
of every page rendered from the hardware values with the ROM's own font
(`tests/roms/hwprobe_expected.py`), pixel-identical to the viewer; see its
`README.md`. Growing the ROM changes the address/phase-sensitive bytes of
IDENT/TIMERS/LDMSTM/PPUSTAT/IRQLAT, so compare against the build that was run.

## Regenerating / extending

```
python3 tests/roms/gbedge.py            # -> gbedge.gb, gbedge-auto.gb
python3 tests/roms/gbaedge.py           # -> gbaedge(-auto).gba (arm-none-eabi-as/ld/objcopy)
python3 tests/roms/gbedge.py --only=5:6 # build a probe subset
```

New GB probes: a `@test("NAME")` function in gbedge.py (32-byte slot; enter and
leave with LCD on and IME off — the runner re-parks timers, serial, STAT, LYC
and palettes between probes). New GBA probes: a `probe_*` routine in gbaedge.s
plus a name in gbaedge.py's `PAGES`.
