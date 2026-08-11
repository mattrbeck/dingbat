# hwprobe: gbedge.gb + gbaedge.gba — hardware edge-case probe ROMs

**Date:** 2026-08-11 (v6 + GB SWEEP)  **ROMs:** `tests/roms/gbedge.gb`
(27 pages, DMG+CGB), `tests/roms/gbaedge.gba` (37 pages).  v2 added six pages aimed at
the highest-leverage open questions in docs/gb-failure-triage.md and the
GBA bus/HLE calibrations; v4/v5 added the guessed-at-behavior pages; v6
(gbaedge 28-36) adds nine DISCRIMINATION pages that isolate the model
splits the three AGS-001 sessions could not separate, plus the IRQLAT
irq_arm r5-clobber fix.  The full research catalog behind them is
docs/hwprobe-questions.md.  Both built from committed sources
(`gbedge.py` hand-assembles; `gbaedge.py` drives arm-none-eabi-as/ld).

## Why these exist

Every bundled suite (mooneye, gambatte, blargg, AGE, GBMicrotest, SameSuite,
mealybug, mGBA-suite, jsmolka, FuzzARM) bakes an *expected* value into the
ROM and prints pass/fail — so a suite can only test what its author already
knew, and a wrong expectation poisons every emulator that calibrates to it.
These two ROMs invert that: each probe runs a choreographed, deterministic
sequence from power-on and stores the **raw observed values** into a 32-byte
result slot.  A viewer pages through the slots as hex (LEFT/RIGHT or A/B;
wraps).  Nothing on screen says pass or fail.

**Real hardware is the oracle.** Photograph every page on a console;
screenshot the same pages in an emulator; diff.  Model-to-model differences
(DMG revisions vs CGB revisions vs AGB) are data too — several pages are
deliberate model fingerprints.

Every page shows two CRCs: `CRC` (this slot) and `ALL` (global, over every
slot).  **One photo of any page therefore fingerprints the whole run** — if
`ALL` matches between hardware and emulator, every probe agrees; if not,
page through to find which `CRC` differs.  `MODEL` identifies the machine
(GB: boot A/B — DMG=01, MGB/SGB2=FF, CGB=11+B.0=0, AGB-in-CGB-mode=11+B.0=1;
GBA: BIOS checksum low half).

## Hardware protocol

1. Flash `gbedge.gb` / `gbaedge.gba` (the **manual** builds) to a cart.
2. On each console model you own: photograph page 0 (IDENT + ALL). If ALL
   matches a console already captured, the whole run is identical — done.
3. On at least one console per distinct ALL value: photograph all pages.
4. GB serial page (06 SERIAL): run with **no link cable attached**.
5. GBA pages 08 (MSRTBIT) and 18 (BXDECODE) run only when you press
   **START on that page** — they provoke architecturally UNPREDICTABLE
   behavior (MSR setting the T bit from ARM state; executing near-BX
   encodings). A timer-IRQ watchdog attempts recovery, but a power cycle
   may be needed, so run them LAST, after every other page is
   photographed. Photograph each page after it redraws.  BXDECODE runs
   ONE candidate per START press (photograph between presses!); if a
   press freezes the console, power cycle, page back to 18, press
   **SELECT once** to skip the wedging candidate, and keep going —
   candidate k wedged if the freeze came on press k+1.
6. Emulator side: the `-auto` builds flip pages every 64 frames for
   input-less harnesses; `tests/roms/hwprobe_ocr.py <shot.ppm>` reads a
   dingbat screenshot back as exact text (it matches the ROMs' own font).
   **Compare hardware photos against the SAME build you flashed** — a few
   GBA open-bus/pipeline bytes legitimately differ between the manual and
   auto binaries (the code around the capture points differs).

### AGB-only sessions (GBA console + EverDrive)

All 37 gbaedge pages run natively — CONTEND, IRQLAT, and the nine
guessed-at-behavior pages (16-24) are entirely on-die, so the flashcart cannot
influence them; WAITSTATE/PFPHASE and ROM open-bus bytes carry the
flashcart caveat below.  NOTE: growing the ROM to 25 pages changed the
whole-run fingerprint and the address/phase-sensitive bytes of a few v1
pages (IDENT/TIMERS/LDMSTM/PPUSTAT/IRQLAT) — session-1 photos and
`tests/roms/expected/agb-sp-1/` correspond to the 16-page build at
5b0db6b; a fresh session on the 25-page build re-covers everything.  gbedge.gb runs on
the same console **only via a GB-slot flashcart** (the GBA's CGB
compatibility mode; MODEL line reads 11 01 = AGB) — a GBA-slot cart
running a GB emulator (Goomba etc.) is worthless here, it would measure
the emulator.  An AGB session answers every CGB-mode page for the AGB
model (CGBWRAM/M1STAT/HALTPHASE/WYLATCH/PCMPSG/SPEED/DSTAT/DIVTAPS
included); DMG and CGB-revision data still needs the real handhelds.

Caveats: GBA WAITSTATE/prefetch rows and any open-bus-from-ROM bytes are
flashcart-influenced — note which cart was used (EverDrive vs EZ-Flash vs
repro board can differ); everything else is cart-independent.  gbedge only
ever disables the LCD during vblank (DMG panel safety).  All GB WRAM the
probes read through DMA is written first (power-on WRAM is silicon noise).

## Debug channels

gbedge mirrors state into HRAM: `$FF80` = index of the probe currently
running (before the viewer starts; a hang leaves the culprit's index
behind), `$FF82` = 0x01 once the viewer is alive.  dingbat can read these
via `--mode=microtest --list=...` (scored "PASS" == ROM healthy).

## GB/GBC pages (gbedge.gb)

| pg | name | probes | why it's interesting |
|---|---|---|---|
| 00 | IDENT | boot A F B C D E H L SP, DIV/LY/STAT/IF/LCDC/IE at a fixed entry offset, then P1 KEY1 VBK SVBK FF72-77 OPRI RP SB SC TAC FF03 | boot-handoff DIV phase is a per-model constant no suite pins; FF72-75 masks changed across CGB revisions; PCM12/34 idle values; P1 upper bits |
| 01 | DIVPHASE | DIV reset→first-increment distance at 1 M-cycle resolution; TIMA-vs-mux phase at TAC=05 | write/read sub-instruction offsets differ between emulators |
| 02 | TIMAGLITCH | falling-edge detector: DIV-write glitch, TAC-disable glitch, TAC 05→06 switch glitch, plus a 4-freq rate-calibration row (expect 01 40 10 04) | disable/switch glitches differ DMG vs CGB revisions |
| 03 | TIMARELOAD | TIMA sampled cycle-by-cycle across overflow (position+width of the 00 window), TIMA-write-in-window, TMA-write-in-window, IF timing | the most hand-tuned corner of every GB timer |
| 04 | HALTBUG | halt bug byte-duplication, EI delay (ei/nop, ei/di), ei/halt wake, IME=0 halt wake latency in DIV ticks | ei/di dispatch window rarely covered |
| 05 | IEPUSH | dispatch with SP=0000 so the PC-high push lands on IE; run 1 keeps the bit (0x04xx), run 2 clears it (0x01xx) | mooneye documents DMG cancelling to PC=0 — CGB/AGB behavior is thin ice; also records what happens to IF |
| 06 | SERIAL | no-cable internal-clock duration (poll count), SC=83 on DMG (ignored bit?), **DIV reset mid-transfer** (serial clocks off the DIV chain), SB mid-shift, external-clock stall | no bundled suite touches serial-vs-DIV at all |
| 07 | IFVBLANK | IF.0 rise vs the LY 143→144 boundary, 10-dot effective resolution, LY+STAT anchors | dingbat has an open "vblank raised early" finding; SameBoy/gambatte disagree here |
| 08 | STATSEQ | STAT mode string across line 40 (20-dot cadence), SCX=5 mode-3 stretch | encodes the whole mode-timing model incl. what a mid-mode STAT read returns (the cc-2 sampling work) |
| 09 | LY153 | four 1-M-cycle-phase sweeps tiling the 152→153→0 boundary at 4-dot resolution + LYC=153 coincidence-flag timing | the phantom line splits models and emulators |
| 0A | LCDON | STAT string immediately after LCDC.7 set (mode-0 start, skipped OAM scan), first-line length via LY | the least-agreed sequence in GB emulation |
| 0B | STATWBUG | STAT=00 written in vblank/mode0/mode3/mode2/LYC-match (+ a value-independence case), IF.1 polled after each | DMG-only spurious-IRQ bug (Road Rash); CGB immunity per revision |
| 0C | STATIRQ | STAT IRQs per frame for 6 source combos (incl. blocking-heavy LYC+m0+m2 and m1+m2) | "STAT blocking" counts are a compact fingerprint of the whole line model |
| 0D | OAMDMA | reads of WRAM/VRAM/ROM/OAM/ECHO **during** OAM DMA for 4 source buses (ROM/WRAM/VRAM/ECHO-source) + OAM content after | which buses conflict differs DMG vs CGB (separate WRAM bus); DMA-from-E000 is barely documented anywhere |
| 0E | OAMCORRUPT | inc hl/dec hl/inc de at $FE30 inside mode 2 at 3 offsets + vblank control; corrupt-count, first index, row bytes | DMG OAM bug: WHICH rows and what values is revision silicon data |
| 0F | UNUSED | FEA0-FEFF sweep, unmapped IO, P1 both/neither select lines, IF/IE upper bits, STAT/TAC/SC write-FF readback, DIV double-read | the classic model-fingerprint corners |
| 10 | VRAMLOCK | what VRAM/OAM/BCPD reads RETURN per mode + are locked writes dropped (incl. the CGB-E neighbouring-palette-write lore) | DMG FF-vs-CGB values; palette lock differs by CGB revision |
| 11 | HDMA (CGB) | GDMA cycles via TIMA, HBLANK-DMA remaining-count countdown, mid-run cancel readback + did-block-1-copy, armed-across-LCD-off behavior | pause/resume across LCD off is disputed |
| 12 | PCMPSG (CGB/AGB) | 24 PCM12 samples at 5 M-cycles right after ch1 trigger (latency + duty steps), ch2 join, NR52 flags | the digital scope the SameSuite APU work needs — sub-period sampling answers the channel_1/2 offset question on silicon |
| 13 | DSTAT (CGB) | STAT string + LY153 quirk **in double speed** (10-dot sampling) | double resolution on the same edges; directly validates the cc-2 STAT readback change |
| 14 | SPEED (CGB) | KEY1 switch: DIV reset?, TIMA across the stall (stall length!), LY across both switches, double-rate DIV check | Pan Docs' ~2050-cycle stall figure vs silicon |
| 15 | M1STAT | IF bits 0+1 sampled together across the 143->144 boundary at 4-dot resolution, mode-1 source only; the mode-2-source-at-144 quirk; a control | bucket 18: 42 gambatte `m1` rows are VALUE failures on whether the mode-1 STAT source asserts at vblank entry and how it overlaps the vblank IF bit |
| 16 | HALTPHASE | halt-woken handler vs a timed sled racing the same mode-0 edge, both TIMA- and LY-timestamped, 1 M-cycle resolution via grid phase sweeps, SCX 0 and 3 | bucket 24: GBMicrotest and mooneye contradict each other about exactly this on the same silicon; resolving it gates ~21 runner rows (STAT_M2_LEAD) |
| 17 | WYLATCH | mode-0-IRQ timestamp of the window-start line while the WY write time is swept across line 39, four 4-dot-spaced timestamp grids + early-armed and never-hits controls | the late_wy anomaly: CGB samples WY SOONER than DMG (the only backwards CGB latency); ~26 late_wy rows + the 51-row WY-LATCH pipeline sub-bucket |
| 18 | CGBWRAM | $D000-window banking under every SVBK value with alias sentinels, incl. the exact SVBK=2 configuration | bucket 16's 64 rows, "Declined pending hardware": byte 0A reads 77 on a console where $D000 aliases $C000, 5C where banking is real |
| 19 | DIVTAPS | phase staircases: serial-completion poll counts at 8 DIV-reset phases, APU length-expiry poll counts at 8 phases | the mechanism page — DIV/timer/serial/frame-sequencer are supposed to be taps off ONE counter; the staircase periods ARE the tap bits.  (dingbat's length-expiry flag only clears at 1 of 8 phases — already suspicious) |
| 1A | SWEEP | ch1 trigger overflow checks at the AGB anchor frequencies: NR52-bit0 poll counts for freq 1300/940/1024/1000 shift 1 (sweep period 2) + a divider-0 cap row | AGB silicon (AGS-001 SWEEPQ/SWEEP2) runs a SECOND linear trigger check (shadow + 2*(shadow>>s), kills strictly above $800); blargg dmg/cgb_sound CRCs say GB silicon does not (8 rows regressed when ported, 2026-08-11) — this re-anchors the divergence on CGB with raw values.  0 polls at +0 = CGB runs the AGB check; ~1 tick (~$440) = single check; +8 must cap at $2000 |

CGB-only pages show `EE` at offset 1F on DMG-class hardware.  (CGBWRAM
runs everywhere; a DMG shows the flat B7 no-banking pattern as control.)

### dingbat baseline (main @ today) — flagged while bringing the ROM up

- **P1 upper bits**: IDENT byte 10 reads `3F` (bits 7:6 clear) — hardware
  reads them set (`CF`-style).
- **IEPUSH run 2**: dingbat takes the timer vector (`tcnt=1`) — mooneye's
  DMG cancels to 0x0000.  Also check IF disposition on hardware.
- **TIMARELOAD**: dingbat's TIMA=00 window spans 2 consecutive k values;
  the hardware lore says 1 M-cycle.
- **IFVBLANK**: IF.0 rises ~2-3 samples before where LY flips — quantifies
  the open early-vblank finding against silicon.
- **SPEED**: dingbat's switch stall consumes only ~3 TIMA ticks (TAC=06);
  hardware documentation implies ~130.  Also LY delta across the stall.
- **SERIAL**: DIV-reset-mid-transfer *shortens* the transfer in dingbat
  (0x40 poll iterations vs 0x5D); on hardware a DIV reset should stretch it.

## GBA pages (gbaedge.gba)

| pg | name | probes | why it's interesting |
|---|---|---|---|
| 00 | IDENT | GetBiosChecksum, boot DISPCNT/greenswap/WAITCNT/KEYINPUT/POSTFLG/0x04000800/CPSR/SP, current open bus | AGB vs AGS vs DS-compat silicon split via checksum; boot POSTFLG lore |
| 01 | OPENBUS | 0x0 (BIOS latch), 0x4000, 0x01000000, 0x10000000 words; 16/8-bit variants; the same read executed from EWRAM and IWRAM; 16-bit dup from ROM | open bus reflects the *executing bus's* prefetch — a classic NBA/mGBA divergence family |
| 02 | BIOSPROT | BIOS-region reads post-startup / post-SWI / **inside an IRQ** / post-IRQ + halfword splits + address independence | the four latch states (e129f000/e3a02004/e25ef004/e55ec002) and their edges |
| 03 | SWITIME | TM0/TM1-cascade cycle counts for Div, Sqrt, ArcTan2, CpuSet (3 shapes), CpuFastSet, BgAffineSet | dingbat ships HLE BIOS timing calibrations — this row IS the calibration oracle, comparable HLE vs `--bios` vs silicon |
| 04 | TIMERS | free-running-prescaler phase sweep, enable latency (double read), cascade with reload FFFC, reload-latch semantics mid-run vs restart | the free-running prescaler was a recent dingbat fix; phase evidence from silicon |
| 05 | DMALATCH | open bus right after DMA (latch vs pipeline?), cycles stolen by a 16-word DMA, DMA from BIOS (protected src), DMA0 from ROM (illegal bus), misaligned halfword source | emulators split three ways on what post-DMA open bus returns |
| 06 | LDMSTM | stm base-in-list (first/not-first), ldm base+wb, **empty-rlist STM/LDM** (stored PC? loaded PC? base±0x40), rotated unaligned LDR | ARM7TDMI quirks every core hand-implements |
| 07 | MULFLAGS | C flag after 8 MUL operand pairs × C preset 1/0 + UMULLS/SMULLS | ARM7's "meaningless" carry is deterministic silicon behavior emulators guess at |
| 08 | MSRTBIT | **interactive (START)**: `msr cpsr_c` with T set from ARM state; thumb breadcrumbs at A+4/6/8/10 accumulate a distinct r7 per resume point; ARM-continuation netted by condition-skipped pairs; control run validates mechanics | the open question behind arm.nim's MSR handling: dingbat resumes at A+8 and skips A+10 (r7=04) — silicon answer wanted; may need a power cycle |
| 09 | PPUSTAT | [DISPSTAT,VCOUNT] pairs across line 40, fine window after hblank-flag rise, vblank-entry pairs | hblank-set-at-1006 vs mGBA's model; boundary sampling mirrors the GB cc-2 work |
| 0A | PSGSTAT | ch1 active-flag after trigger, poll-count until length expiry, SOUNDBIAS boot value, ch3 wave-RAM bank readback while playing | GB channels on AGB silicon (SameSuite-on-AGB context) |
| 0B | WAITSTATE | 16 sequential ROM reads under 4 WAITCNT settings; a 32-nop ROM call with prefetch off/on; WAITCNT restored to boot value | prefetch-buffer modelling; flashcart-dependent — record the cart |
| 0C | PFPHASE | one timer-bracketed ROM data read after k=0..7 sequential ROM fetches, two waitstate settings | dingbat's prefetch dead-cycle rule (`elapsed mod s == s-1`) is fitted per-row to the mGBA suite and provably wrong-shaped for the DMA rows; the cost-vs-k wobble IS the real rule |
| 0D | SWIREGION | Sqrt cycle counts at 4 inputs between the fit's calibration points; Div and CpuSet issued from IWRAM/EWRAM/ROM callers | SWI_HLE_BASE and the "S16-1" refill residual were calibrated against the suite's IWRAM column only; Sqrt is a 3-point piecewise guess |
| 0E | CONTEND | timed PRAM/VRAM/OAM/EWRAM reads mid-line visible vs forced blank vs hblank vs vblank, plus VRAM writes | dingbat models ZERO PPU/CPU contention (constant access costs while rendering); every byte here is on-die, so the flashcart cannot touch it |
| 0F | IRQLAT | trigger-vs-handler TM0 stamps for TM2-overflow / DMA3 / hblank / vblank IRQs | dingbat's two fitted synchronizer latencies (3 and 6, one suite row each); source-to-source deltas cancel the fixed dispatch cost.  (dingbat never delivers the TM2 IRQ at all — fresh divergence) |
| 10 | IORW | 16 halfword reads of write-only (BG0HOFS, BG2X, WIN0H, MOSAIC, BLDY) and unused (0x4E, 0x56, 0x66, 0x6A, 0x78, 0x110, 0x12C, 0x136, 0x142, 0x206, 0x20A) IO, taken before anything writes IO | the zero-vs-open-bus IO read map — every emulator hand-picks it |
| 11 | CPSRBITS | all-ones writes to each CPSR MSR field with mrs readback; SPSR_irq written 0xFFFFFFFF / 0 / 0x0F; mrs SPSR in system mode | which status bits physically exist; is SPSR bit4 forced high; what a nonexistent SPSR returns |
| 12 | THUMBPC | stored-value deltas for `str pc` / `stm {pc}` / `stm {lr,pc}`; `ldm pc, {r1}`; Thumb `cmp pc, r0` with a loaded SPSR (flag word says normal-compare vs SPSR-load); Thumb `mov r0, pc` | settles the theory that Thumb CMP r15 loads SPSR into CPSR.  (Building this found a dingbat hang: Thumb hi-reg CMP rd=pc never advanced PC) |
| 13 | LDMUSER | `stm {r13}^` value, `stm r4!, {r13}^` writeback, `stm r13!, {r13}^` with banked base (which bank gets the writeback), mrs SPSR immediately after an `ldm ^` | banked-base user-list transfers and the OR-with-CPSR theory for the post-ldm^ SPSR read — both unmeasured corners |
| 14 | IRQWIN | a parked TM2 IF bit released through one gate at a time (IME write / CPSR.I clear / IE write) with an instruction sled behind the store — the handler records how far the sled ran; plus 16 IF-acks against a 16-cycle overflow loop | when IME / I / IE are actually sampled, in instructions — emulators use guessed constants here |
| 15 | DMAEDGE | DMA3 primed, then byte writes 0x80 to 0xDF / 0xDE / 0xDD each followed by did-it-run + CNT_H readback; vblank DMA enabled then disabled before any vblank | the byte-mirroring DMA-enable rumor (and does it affect all bits?), plus disable-while-starting |
| 16 | CAPDMA | DMA3 armed in Special timing with repeat; nonzero-word counts in the destination ring after frames 1/2/3 + CNT_H readback | the "capture DMA only runs every other frame" rumor; dingbat currently fires exactly ONE trigger ever (count stays 4) |
| 17 | SWEEPQ | ch1 sweep death times (poll counts to the SOUNDCNT_X active-flag drop): period 0, immediate-trigger-recalc overflow, the unwritten second recalc, a mid-note period rewrite, plus a pure length-death control | three sweep-unit unknowns (divider 0 / immediate recalc / unwritten second recalc), CPU-visible on AGB without audio capture |
| 18 | BXDECODE | **interactive**: four encodings run from IWRAM with breadcrumbs — genuine BX r1, the ARMv5 BLX-r1 word 0xE12FFF31, BX with an SBO field violated (0xE120FF11), BX r15.  **v2: each START press runs ONE candidate** (byte +9 = next index, page redraws between presses); **SELECT skips** the next candidate (result byte DD) — session 2 proved a candidate can wedge the console beyond the watchdog, so after a freeze: power cycle, page RIGHT back to 18, skip the wedger, harvest the rest.  r7 verdict: 1 = took the BX, 6 = fell through, 4 = branched to $+8; phase 2 = watchdog recovered | do near-BX encodings execute as BX, fall through, or trap?  dingbat answers [1, 6, 1, 4] — its 12-bit decode LUT cannot see the SBO fields |
| 19 | THUMBPC2 | Thumb `cmp/add/mov pc, r0` with SPSR = 0x9000009F (a DIFFERENT mode than current) — CPSR-after words say whether the r15 SPSR-load is full-CPSR or flags-only, breadcrumbs say whether add/mov still branch; plus `ldm/str/ldr r15` base-writeback rows under the timer watchdog with distinct-breadcrumb sleds | scopes session 2's SPSR-load discovery, and the last untested r15 corners |
| 1A | IRQWIN2 | the IRQWIN gates again but TM0-timestamped (pre-store stamp vs handler entry stamp) + an EWRAM-load sled for the IME gate + a one-shot TM2 overflow swept in 2-cycle steps across an IF-ack write (bit0 = IF right after, bit1 = 8 nops later) | converts the gate windows from instructions to cycles, and extracts the same-cycle ack-vs-assert priority |
| 1B | IOBYTE | byte-writes 0x44 to the low then high byte of eight readable registers (DISPCNT, DISPSTAT, BG0CNT, WININ, BLDCNT, SOUND1CNT_L w/ master forced on, IE, DMA3CNT_H sans enable), halfword readback after each, original restored | is DMAEDGE's byte-mirroring asymmetry bus-wide or DMA-specific — one byte, both bytes, or ignored, per register |
| 1C | LDMUSER2 | `ldmia r0,{r1-r7}^` in IRQ mode with SPSR flags N\|V and CPSR flags Z\|C (DISJOINT), mrs SPSR in the shadow (next instruction / one nop later / no-ldm control / CPSR sanity) | session 2's OR-with-CPSR row was unfalsifiable (CPSR bits ⊆ SPSR); readback 0x90000092 = unchanged, 0xF0000092 = OR'd, 0x60000092 = returns CPSR |
| 1D | PCWB2 | five r15-writeback candidates run from EWRAM in a breadcrumb block with pads before AND after (str ±8/-4 post-indexed, str pre-indexed, ldr +8, stm), identity store payloads, watchdogged | pins the FUNCTIONAL FORM: "PC := writeback address (+4 for ldr)" vs "PC := base+4/base+8 fixed" — session 3 measured only offset +4, where the two models coincide |
| 1E | DMABYTE2 | upper-byte strb 0x80 on DMA0/1/2 (immediate EWRAM copy primed via 16-bit writes; ran + CNT_H readback), DMA3 upper 0xC0 / lower 0xC0 / upper 0x40 | generalizes the DMA3CNT_H bit7 anomaly: which channels mirror, whole-value vs bit7-only (40C0 vs 4080), and whether a lo-byte 0xC0 is fully dropped or bit6 still stores |
| 1F | SWEEP2 | four ch1 sweep rows (freq 512 s1, 2018 s7, 940 s1, 2033 s7 — the s7 rows put the second trigger check / first calc EXACTLY at 2048), poll counts | pins trigger-recalc writeback (death tick 2/3/4 on the 512 row), the >2048-vs->=2048 boundary (single-anchor today), and same-offset vs recalculated second check (940 row) |
| 20 | IRQWIN3 | the IME-gate sled re-run with 4-I-cycle muls, waitstated ROM loads, and a mixed nop/ldr sled; plus the ack-race sweep re-run at 4-cycle steps (reload 0xFFF8-4k) straddling the ack | is the post-store dispatch window cycle-counted (instructions x cost triangulates the constant); the previous 2-cycle ack sweep landed entirely before the ack on both machines |
| 21 | IRQLAT2 | the TM2 IRQ-latency row with the irq_arm r5-clobber FIXED (session 1's row armed IME by mistake): reload 0 one-word, reload 0xFF00 one-word, 0xFF00 two-halfword arming, reload 0xFFF0 (overflow inside the arming code) | the retracted IRQLAT divergence re-measured for real, plus arming-shape and overflow-proximity variants |
| 22 | IOBYTE2 | DISPSTAT lo-byte strb 0x38 (bits 3-5 are REAL IRQ enables), hi-byte strb 0x38 (LYC), 16-bit control, 16-bit-then-byte-clear | session 3's 0x44 probe was unfalsifiable (only bit6); 0x39 readback = byte writes store, 0x01 = lo byte ignores byte writes |
| 23 | THUMBPC3 | Thumb `cmp pc, r0` at A%4==2 with a T-CLEARING SPSR (overlaid Thumb/ARM block: scratch-store breadcrumb at W, escape at W+4); plus the same cmp in System mode (no SPSR) with flags preset N\|Z.  **v7 row (c)**: the same halfword-aligned cmp with the resume ladder extended — distinct breadcrumb adds at W+8/W+12/W+16 (A+6/A+10/A+14), r4 captured to show whether the W+4 ARM word ran, escape at W+20, safety at W+24 | where ARM execution resumes after the restore at a halfword boundary.  Session 4 answered (a) with an unlisted outcome — resumed past BOTH overlay words (A+10 or A+14, the old block's escape and safety were identical) — and (c) is the discriminator |
| 24 | MSRTBIT2 | the MSRTBIT breadcrumb block boot-run twice under the watchdog: immediate-form `msr CPSR_c,#0x3F` from System, and register-form setting T AND switching IRQ->System in one write | does the A+8-skip-A+10 quirk hold for the immediate form and across a simultaneous mode switch (recovery CPSR byte says whether the switch landed) |

### dingbat baseline (main @ today) — flagged while bringing the ROM up

- **OPENBUS +20/+24**: reads executed from EWRAM/IWRAM stubs return
  `00000000` in dingbat; hardware should return the stub's own pipeline.
- **BIOSPROT**: all four latch states match the documented values —
  hardware run will confirm the whole family.
- **DMALATCH +0**: post-DMA open bus returns CPU pipeline (`e3a00401`),
  not the DMA latch; the protected-source DMA *does* deliver the latch
  (`31323334` = last word of the preceding DMA).
- **TIMERS +8/+10**: with TM1 cascading a TM0 that started at 0xFFFC,
  dingbat reads TM1=0x33 and TM0=0xFFFC — TM1 looks like it's counting
  system clocks and TM0 looks frozen. ~~Suspicious; hardware will
  arbitrate.~~ **Hardware matches exactly** (AGB session 1) — the model
  is right.
- **MSRTBIT**: r7=04 (resume at A+8, skip A+10), watchdog not needed.
  **Confirmed on AGB silicon** (session 1): identical breadcrumb, clean
  run, valid control.

### dingbat baseline — the v6 pages (37-page build, HLE == real BIOS on all nine)

- **LDMUSER2**: post-ldm^ SPSR reads back 0x90000092 (unchanged) at both
  distances; control and CPSR sanity rows exact.
- **PCWB2**: r7 = 18/10/1F/1C/18 — dingbat generalizes as PC := writeback
  (+4 for ldr, load suppressed: r1 stays 0), EXCEPT `stmia r15!` lands
  base+8 (neither wb=base+4 nor the ldm-style no-wb).  No watchdog fires.
  (Post-session-4 fix: the stm row now reads 1F — no writeback — and the
  page is byte-perfect vs hardware, CRC A9AA.)
- **DMABYTE2**: dingbat mirrors CNT_H bit7 on ALL FOUR channels (readback
  0080 after hi-strb 0x80, transfer runs); DMA3 hi 0xC0 -> 4080
  (bit7-only mirror), lo 0xC0 -> 0040 (bit6 stores, bit7 dropped),
  hi 0x40 -> 4000 control exact.
- **SWEEP2**: polls 3532 / 09D8 / 109D / 0000 — the 512 row dies ~tick 3,
  2018 and 940 die ~tick 1, 2033 dies at trigger.
- **IRQWIN3**: dispatch after 2 muls / 2 ROM-ldrs / 3 mixed-sled
  instructions (8/8/C bytes); ack-race k=0..5 -> 00, k=6..7 -> 03 — the
  coarser sweep straddles the ack point in dingbat.
- **IRQLAT2**: TM2 delivers on every arming shape now that r5 is
  reloaded: deltas 0x33 (reload 0), 0x13D (0xFF00, one-word AND
  two-write identical), and the 0xFFF0 row enters the handler BEFORE the
  trigger-side stamp (entry 0B4F < trigger 0C4F) — the overflow lands
  inside the arming code, as designed.  IRQLAT p0F's own TM2 pair reads
  (00D4, 0103) after the fix.  (Post-session-4 retune: the gamepak-context
  entry/return cost lands the page byte-perfect vs hardware, CRC 0EE1 —
  deltas 0x39/0x143/0x143, p0F TM2 pair (00D4, 0109).)
- **IOBYTE2**: dingbat STORES the DISPSTAT lo-byte 0x38 (readback 0039)
  and the byte-clear (0001 after) — the "lo byte ignores byte writes"
  hardware model predicts 0001/0039 instead; hi-byte LYC and 16-bit
  control exact (3801/0039).
- **THUMBPC3**: (a) CPSR 80000012, scratch 0, r6=02 — dingbat performs
  the full restore and resumes ARM at (A+2)&~3, clean; (b) CPSR
  C000001F — the System-mode "restore" writes CPSR-as-SPSR back (no-op),
  flags preset survives, clean.  **v7 row (c)** (post-session-4 build,
  HLE == real BIOS, page CRC 2333): +17 phase 01, +18 r6 = 07, +20 r4 =
  0x02A01080, +24 scratch = 0, +28 CPSR = 0x80000012 — dingbat resumes
  at (A+2)&~3 and executes the W+4 orr plus all three ladder adds.
  Hardware (session 4, old block) resumed past both overlay words, so
  the silicon prediction is r4 = 0xC0DEC0DE with r6 = 06 (A+10) or
  04 (A+14).
- **MSRTBIT2**: r7=04 / phase 01 / recovery mode 1F on BOTH rows — the
  A+8-skip-A+10 quirk holds for the immediate form and across the
  IRQ->System mode switch (which lands) in dingbat's model.

**Hardware session 1 (AGB SP + EverDrive, 2026-08-10) is transcribed and
diffed in `docs/hwprobe-results-agb.md`** — 9/16 pages byte-perfect
(11/16 on the real-BIOS path); confirmed divergences: IRQLAT (reload-0
one-shot timer IRQ undelivered + per-source latencies), MULFLAGS carry
after MUL, IDENT boot handoff (DISPCNT/POSTFLG/0x04000800), TIMERS boot
prescaler phase, PSGSTAT length expiry, and the HLE-only SWI costs.

## Expected results

`tests/roms/expected/` holds one directory per transcribed hardware run:
PNGs of every page rendered from the hardware values with the ROM's own
font (`tests/roms/hwprobe_expected.py`), pixel-identical to the viewer's
display.  An emulator screenshot that equals the PNG matches hardware on
every byte of that page; see `tests/roms/expected/README.md` for the
comparison rules (the `ALL` line encodes whole-run agreement).

## Regenerating / extending

```
python3 tests/roms/gbedge.py            # -> gbedge.gb, gbedge-auto.gb
python3 tests/roms/gbaedge.py           # -> gbaedge(.-auto).gba (needs
                                        #    arm-none-eabi-as/ld/objcopy)
python3 tests/roms/gbedge.py --only=5:6 # debug: build a probe subset
```

New GB probes: add a `@test("NAME")` function in gbedge.py (32-byte slot,
enter/leave with LCD on and IME off — the runner re-parks timers, serial,
STAT, LYC, palettes and trampolines between probes).  New GBA probes: a
`probe_*` routine in gbaedge.s plus a name in gbaedge.py's `PAGES`.

Emulator-side reading: run the `-auto` build, screenshot at intervals
(`--mode=screenshot --timeout=N`), decode with `tests/roms/hwprobe_ocr.py`.
