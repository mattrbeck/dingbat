# gbaedge hardware results — AGB session 1

Real hardware: **GBA SP (AGS-001)**, EverDrive GBA flashcart, 2026-08-10.
Manual build of `tests/roms/gbaedge.gba` at 5b0db6b. `MODEL 18 7F` on every
page (GetBiosChecksum `BAAE187F` low half — AGB-family BIOS). Whole-run
fingerprint `ALL F54C` (pre-MSRTBIT); after MSRTBIT ran, `ALL 1512`.

## Verdict vs dingbat (same manual build, page-patched at 0x1C4/0x1D8)

Byte-perfect matches — hardware confirms dingbat's model outright:

| page | what this settles |
|---|---|
| P01 OPENBUS | every open-bus/pipeline source probed, incl. RAM-executed stubs |
| P02 BIOSPROT | BIOS-region protection readback in all CPU contexts |
| P05 DMALATCH | post-DMA bus latch incl. protected-source delivery |
| P06 LDMSTM | empty-rlist / writeback-in-list corner behavior |
| P08 MSRTBIT | **silicon resumes Thumb at A+8 and SKIPS A+10** (r7=04, clean run, control valid) — dingbat's arm.nim model is now genuinely hardware-verified; NBA's differs |
| P09 PPUSTAT | DISPSTAT/VCOUNT edge sampling |
| P0B WAITSTATE | all 12 waitstate/prefetch cycle counts (EverDrive behaved as a standard cart) |
| P0C PFPHASE | all 16 prefetch dead-cycle phase values — the `elapsed mod s == s-1` rule holds on silicon |
| P0E CONTEND | CPU/PPU contention pattern identical to dingbat's model |
| P03 SWITIME / P0D SWIREGION | **real-BIOS path only**: all 12 SWI cycle counts exact |

Divergences (dingbat != hardware), ranked:

1. **P0F IRQLAT**: dingbat never delivers the TM2-overflow IRQ armed as
   reload-0 + enable+IRQ in one word (entry stamp 0000; hw FF8B). The other
   sources fire but enter late-shifted: DMA3 entry hw 029A vs 0288 (+18),
   hblank pair hw (046A,08DF) vs (0463,08C0), vblank hw (0AD4,4375) vs
   (0AC8,4363). The one-row-fitted IRQ_SYNC_DELAY/HBLANK_IRQ_SYNC_DELAY
   constants now have four real anchors.
2. **P07 MULFLAGS**: with C preset to 1, hardware CLEARS carry for operand
   pairs 0/1/2/5/6/7 where dingbat leaves it set (hw nibbles 04 00 00 02
   0A 04 08 08 vs dingbat 06 02 02 02 0A 06 0A 0A). C-preset-0 rows and
   UMULLS/SMULLS rows already match — the early-termination carry is
   deterministic and now has 8 anchor points.
3. **P00 IDENT boot handoff**: hw DISPCNT=0080 (forced blank), POSTFLG=01,
   0x04000800=0D000020 (documented reset default; dingbat reads open bus
   there — register unimplemented). EverDrive-chainload caveat applies to
   this page, but all three values equal the documented cold-boot handoff.
4. **P04 TIMERS**: free-running prescaler-64 boot phase: hw staircase
   07 07 07 06 06 06 vs dingbat 06 07 07 06 06 07 (k=0 and k=5 differ).
   Start latency, double-read, cascade (TM1=33/TM0=FFFC) all match —
   the earlier "cascade mis-modeled" suspicion is refuted.
5. **P0A PSGSTAT**: ch1 length-63 expiry poll count hw 2E1E vs dingbat 283A
   (~14% early) — same length-timer-phase family as the GB DIVTAPS finding.
6. **HLE-only** (real BIOS exact): Sqrt cost curve up to ~3x off across the
   bit-length sweep (hw 00CC/0118/0164/01C3 vs HLE 0106/020B/0368/051C);
   CpuFastSet 256-word copy 450 cycles slow (0DFB vs 0FBD); Sqrt/ArcTan2/
   BgAffineSet off by 1-4 cycles in SWITIME.

## Raw hardware transcription

P00 IDENT      CRC 985C
00: 7F 18 AE BA   04: 80 00 00 00   08: 00 00 FF 03   0C: 01 00 00 00
10: 20 00 00 0D   14: 1F 00 00 00   18: 00 7F 00 03   1C: 10 80 BD E8

P01 OPENBUS    CRC 60B9
00: 00 F0 29 E1   04: 01 04 A0 E3   08: 01 02 A0 E3   0C: 01 09 A0 E3
10: 01 10 40 00   14: 00 00 00 00   18: 00 00 00 00   1C: 30 80 00 00

P02 BIOSPROT   CRC A024
00: 00 F0 29 E1   04: 04 20 A0 E3   08: 04 F0 5E E2   0C: 02 C0 5E E5
10: 02 C0 5E E5   14: 02 C0 5E E5   18: 01 00 00 00   1C: 00 00 00 00

P03 SWITIME    CRC EF34
00: F7 01 00 00   04: 19 05 00 00   08: C1 01 00 00   0C: DE 11 00 00
10: EF 0C 00 00   14: FB 0D 00 00   18: C8 0B 00 00   1C: 46 01 00 00

P04 TIMERS     CRC DD91
00: 07 07 07 06   04: 06 06 07 11   08: 33 00 FC FF   0C: 21 00 3B 12
10-1C: 00

P05 DMALATCH   CRC 7A27
00: 01 04 A0 E3   04: D3 FE FF EB   08: 45 01 00 00   0C: 34 33 32 31
10: 00 00 00 00   14: 44 33 22 11   18: 30 80 BD E8   1C: 00 00 00 00

P06 LDMSTM     CRC 6899
00: 00 40 00 02   04: 08 40 00 02   08: BE BA FE CA   0C: 30 09 00 08
10: 40 00 00 00   14: 01 00 00 00   18: 40 00 00 00   1C: 33 22 11 44

P07 MULFLAGS   CRC 64F4
00: 04 00 00 02   04: 0A 04 08 08   08: 00 00 08 08   0C: 00 00 00 08
10: 0A 00 00 00   14: 33 00 33 00   18: 00 00 00 00   1C: 00 00 00 00

P08 MSRTBIT (pre-START)  CRC DCB3
00: 99 00 00 00   ... 00 ...   1C: 00 00 00 EE

P08 MSRTBIT (post-START) CRC 6DA2, ALL 1512
00: 04 01 0F 1F   04: 04 00 00 00   08: AA 00 00 00   0C-18: 00
1C: 00 00 00 EE
# +0=04 breadcrumb (resume A+8, SKIP A+10), +1=01 clean (no watchdog),
# +2=0F control valid, +3=1F recovery CPSR (sys mode, ARM), +4 marker=04

P09 PPUSTAT    CRC 2E32
00: 00 28 00 28   04: 00 29 00 29   08: 00 2A 02 2A   0C: 00 2B 02 2C
10: 02 02 02 02   14: 00 00 00 00   18: 00 9F 01 A1   1C: 01 A3 01 A5

P0A PSGSTAT    CRC F59F
00: 81 00 1E 2E   04: 80 00 00 02   08: 00 00 84 00   0C-1C: 00

P0B WAITSTATE  CRC C0D2
00: 31 01 EB 00   04: E8 00 2E 01   08: 28 01 25 01   0C-1C: 00

P0C PFPHASE    CRC 34E0
00: 4B 00 51 00   04: 57 00 5D 00   08: 63 00 69 00   0C: 6F 00 75 00
10: 36 00 3A 00   14: 3E 00 42 00   18: 46 00 4A 00   1C: 4E 00 52 00

P0D SWIREGION  CRC 65E6
00: CC 00 18 01   04: 64 01 C3 01   08: FF 01 1F 02   0C: 26 05 46 05
10: F7 01 00 00   14-1C: 00

P0E CONTEND    CRC 2D2C
00: E0 00 E0 00   04: E0 00 E0 00   08: E0 00 E0 00   0C: E0 00 E0 00
10: 90 00 90 00   14: 90 00 E0 00   18: 88 00 88 00   1C: 00 00 00 00

P0F IRQLAT     CRC C288
00: C3 00 8B FF   04: ED 01 9A 02   08: 6A 04 DF 08   0C: D4 0A 75 43
10-1C: 00
