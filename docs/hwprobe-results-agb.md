# gbaedge hardware results — AGB sessions 1 & 2

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

1. **P0F IRQLAT**: ~~dingbat never delivers the TM2-overflow IRQ armed as
   reload-0 + enable+IRQ in one word (entry stamp 0000; hw FF8B).~~
   **RETRACTED 2026-08-10: the TM2 row is a probe bug, not a divergence.**
   The `irq_arm` macro clobbers r5 (it ends as 0x04000208), so the probe's
   `str 0x00C00000, [r5]` arming word lands on IME - disabling it - and
   TM2CNT is never written (byte-level bus trace on the committed ROM
   confirms no TM2 arming with reload 0 ever reaches the timer). Both
   machines then time out the spin and read a STALE `SCRATCH+0x48` stamp:
   dingbat's EWRAM is zeroed (0000), the hardware value FF8B is EverDrive-
   chainloader leftovers. A corrected micro-ROM (reload 0 + enable + IRQ in
   one 32-bit write, full BIOS handler dispatch) delivers the one-shot IRQ
   correctly on dingbat. A future gbaedge rev should reload r5 after
   irq_arm and re-measure. The other sources fire but enter late-shifted:
   DMA3 entry hw 029A vs 0288 (+18), hblank pair hw (046A,08DF) vs
   (0463,08C0), vblank hw (0AD4,4375) vs (0AC8,4363). The one-row-fitted
   IRQ_SYNC_DELAY/HBLANK_IRQ_SYNC_DELAY constants now have real anchors.
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

## Session 2 — the nine guessed-at-behavior pages (25-page build @ c1c5d8f)

Same console and cart, 2026-08-10.  `ALL 4B70`, MODEL 18 7F.  Raw
transcription: `tests/roms/expected/agb-sp-2.txt` (rendered PNGs beside
it).  One page matches dingbat outright; seven diverge; BXDECODE could
not be run — **pressing START on it hangs the console with no recovery**
(the watchdog is IRQ-driven, so a candidate that masks IRQs or wedges
the core in an exception mode is unrescuable; that alone proves at least
one near-BX encoding does something violent rather than execute as BX or
fall through).

| page | verdict |
|---|---|
| IORW | **MATCH** (CRC 626A) — dingbat's unused/write-only IO read map is exactly right on all 16 registers |
| CPSRBITS | diverges: only NZCV latch in CPSR (dingbat latches bits 8-27 too); SPSR holds exactly F00000FF; **SPSR bit4 is forced high** (write 0 -> read 10, write 0F -> read 1F; dingbat reads back what was written); sys-mode mrs SPSR returns CPSR (that part matches) |
| THUMBPC | diverges on the headline: hardware CPSR after Thumb `cmp pc, r0` = **A0000092 — the pre-loaded SPSR flags, not the compare result.  The SPSR-load theory is TRUE on silicon** (dingbat does a normal compare, 20000092).  Scope caveat: the experiment pinned SPSR's mode/I bits to the current mode for safety, so only the FLAG transfer is proven — whether mode/I transfer too needs a follow-up with a different-mode SPSR.  Stored-PC deltas (+12/+12/+12), `ldm pc` fetch (+8), Thumb `mov r0, pc` (+4) all match |
| LDMUSER | diverges: `stm r13!, {r13}^` stores **user r13** (CAFE0001; dingbat stores 0) and the writeback lands in the **user bank as base+4** (user r13 becomes EWDST+0x44; dingbat adds 4 to the old user value instead).  No banked writeback either way; post-ldm^ SPSR read came back 600000D2, dingbat agrees.  **Caveat 2026-08-10: this row does NOT falsify the OR-with-CPSR theory** — CPSR's set bits at read time were a subset of the SPSR value, so "unchanged" and "OR'd with CPSR" produce the same readback; discriminating them needs a rerun with CPSR flags disjoint from SPSR flags |
| IRQWIN | diverges: hardware dispatches after **3 sled instructions** for the IME and IE stores and **2** for the msr I-clear (dingbat: 1 everywhere); ack-race survivors 8/16 vs 9/16 |
| DMAEDGE | diverges: after `strb 0x80 -> 0x040000DF`, CNT_H reads back **0080** — the byte write mirrored into BOTH bytes (enable ran + src-ctl bit left behind), so the rumor is real for the upper byte; the 0xDE and 0xDD byte writes did nothing at all (no mirroring down, not even a low-byte write — asymmetric).  dingbat: no mirroring anywhere |
| CAPDMA | diverges: hardware transfers **640 words in frame 1 (160 triggers x 4) then the enable bit self-clears** (readback 3700) — capture DMA runs a full frame of lines then hardware disables it; no every-other-frame pattern with this arming.  dingbat fires one trigger (4 words) and also self-clears |
| SWEEPQ | diverges: freq-1300 dies AT TRIGGER on hardware (poll 0) — the immediate trigger recalc apparently runs the overflow check **twice** (1950 passes, its own recalc 2925 fails); dingbat lets it live to the first tick.  **Corrected 2026-08-10: the recalc-2925 model is falsified by the freq-1000 and freq-1024 rows** (recalc would kill both at trigger; hardware let both survive it) — the second trigger check re-uses the SAME offset (1300: 1950+650=2600 fails) and fails only strictly above 2048 (1024: 1536+512=2048 survives; the strictness rests on that single anchor).  freq-1000 dies at first tick, faster than dingbat (F75 vs 12F4 polls); the mid-note period rewrite kills the channel instantly (0 polls; dingbat 1CBF); the length-63 control dies in 4B polls — near-instant, suggesting a trigger-adjacent length clock (dingbat 12AA9).  Period-0 never ticks (cap) — matches dingbat |
| BXDECODE | **not run — hangs the console** (see above).  Needs a v2 that runs one candidate per START press with results persisted and redrawn between candidates, so the wedging candidate is identified and the survivors still report |

## Session 3 — the v5 pages (28-page build @ 9b0ffc2)

`ALL FDE5`.  Raw: `tests/roms/expected/agb-sp-3.txt`.  This session
closed every question session 2 left open:

| page | verdict |
|---|---|
| THUMBPC2 | **The Thumb `cmp pc` SPSR-load is a FULL CPSR restore**: with SPSR = 9000009F (System) while executing in IRQ mode, CPSR after = 9000009F — mode bits switched (dingbat: flags-only compare, 20000092).  `add pc`/`mov pc` do NOT touch CPSR and branch exactly to the operand (dingbat matches both; the earlier "dingbat lands target-2" note was a probe arithmetic misread — r0 was pad+6).  r15 writeback on hardware is THREE different behaviors: `ldm r15!` performs NO writeback (r7=15; dingbat lands base+8), `str r1,[r15],#4` sets PC=base+4 (r7=12; dingbat base+8), `ldr r1,[r15],#4` sets PC=base+8 (r7=8; matches dingbat) but **suppresses the load** (r1 stays 0; dingbat loads E2877002).  Watchdog never fired |
| IRQWIN2 | dispatch deltas hw 81/81/84 cycles vs dingbat 67/67/6C (~+25 each, consistent with IRQLAT); the EWRAM-load sled lands after 2 loads vs 3 uniform adds (real width-dependence for the cycle model; dingbat: 1 instruction on both sleds).  Ack-race rows all-zero on BOTH — the swept overflow lands before the ack at every offset in this code shape; inconclusive but same-code comparable |
| IOBYTE | byte-write behavior is PER-REGISTER: DISPCNT/BG0CNT/WININ/BLDCNT/NR10/IE/DMA3CNT_H all take byte writes normally (masked), but **DISPSTAT's low byte IGNORES byte writes entirely** (hw 0003 = just the flags; dingbat stores bit6 -> 0041).  **Caveat 2026-08-10: with a 0x44 payload the only storable bit is 6, so "byte writes ignored" is indistinguishable from "bits 6-7 don't exist"** — dingbat's fix models the latter (unused bits), which explains this row without the stronger claim; a 0x38 byte write (real IRQ-enable bits) would discriminate.  Everything except DISPSTAT matches dingbat.  Note the tension with DMAEDGE: CNT_H lo-byte 0x44 stores fine here (bit6), yet session 2's lo-byte 0x80 (bit7) stored nothing — bit7 itself is the anomaly, not the byte lane |
| CAPDMA (re-arm rows) | re-armed enable self-clears every armed frame (+28 = 3700 again); counts stay 640 because re-enabling reloads the internal dst from DAD (the ring is overwritten in place — design note for the record).  Conclusion: capture DMA runs in EVERY armed frame and hardware clears the enable at frame end; the every-other-frame rumor is dead on AGB SP |
| SWEEPQ (decomp rows) | session 2's "instant" mid-note death did NOT reproduce: period-rewrite and SAME-VALUE-rewrite both die at ~1CBD polls (identical — the NR10 write itself is irrelevant).  The length-63 control now dies at 0 polls both fresh AND after two idle frames: with length=63 one tick remains, and hardware clocks length at/near trigger — the classic extra-length-clock quirk, which dingbat lacks (its two length rows: 12AA9 and 1E9 — wildly phase-dependent) |
| BXDECODE | **completed via the one-per-press flow** (press 3 froze the console; power cycle + SELECT skipped it).  Hardware: [01, 01, DD, 04] vs dingbat [01, 06, 01, 04].  So: the ARMv5 BLX word 0xE12FFF31 **executes as BX on ARM7TDMI** (the loose-decode "false positive" is real silicon behavior; dingbat falls through — wrong).  The SBO-violated BX 0xE120FF11 does something violent enough to wedge the console with IRQs masked (dingbat takes it as plain BX — also wrong, in the other direction).  BX r15 branches to $+8 in ARM state — both agree |

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
