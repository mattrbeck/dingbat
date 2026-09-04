# gbaedge hardware results — AGB sessions 1–5

Hardware: **GBA SP (AGS-001)**, EverDrive GBA flashcart. `MODEL 18 7F` on every
page (GetBiosChecksum `BAAE187F` low half). Raw transcriptions and rendered
PNGs: `tests/roms/expected/agb-sp-{1,2,3,4}.txt` and directories. Builds:
session 1 = 16-page at 5b0db6b (`ALL F54C`, `1512` after MSRTBIT); session 2 =
25-page at c1c5d8f (`ALL 4B70`); session 3 = 28-page at 9b0ffc2 (`ALL FDE5`);
session 4 = 37-page at aaaa0eb (`ALL B473`); session 5 = 50-page at ad6af27a
(`ALL 05C6`, pages 37–49, transcription `agb-sp-5.txt`). Open follow-ups are in
docs/hwprobe-questions.md, "GBA".

## Pages hardware confirmed byte-perfect

| page | what this settles |
|---|---|
| 01 OPENBUS | every open-bus/pipeline source, incl. RAM-executed stubs |
| 02 BIOSPROT | BIOS-region protection readback in all CPU contexts (latch states `e129f000/e3a02004/e25ef004/e55ec002`) |
| 03 SWITIME, 0D SWIREGION | **real-BIOS path**: all 12 SWI cycle counts; HLE diverges (below) |
| 04 TIMERS (all but boot phase) | start latency, double-read, cascade (TM1=33/TM0=FFFC with TM0 started at FFFC) |
| 05 DMALATCH | post-DMA bus latch incl. protected-source delivery |
| 06 LDMSTM | empty-rlist / writeback-in-list |
| 08 MSRTBIT | silicon resumes Thumb at **A+8 and skips A+10** (r7=04, clean, control valid) |
| 09 PPUSTAT | DISPSTAT/VCOUNT edge sampling |
| 0B WAITSTATE | all 12 waitstate/prefetch counts (EverDrive behaved as a standard cart) |
| 0C PFPHASE | all 16 prefetch dead-cycle phase values — `elapsed mod s == s-1` holds |
| 0E CONTEND | unloaded contention pattern (mode 3, OBJ on, no sprites) |
| 10 IORW | unused/write-only IO read map on all 16 registers (CRC 626A) |
| 1C LDMUSER2 | SPSR read in the ldm^ shadow = **SPSR unchanged** (`90000092`, CPSR flags disjoint) — the OR-with-CPSR and returns-CPSR theories are dead (CRC B520) |
| 1D PCWB2 (after fix) | PC := the writeback address (+4 for ldr, load suppressed); `stmia r15!` performs **no** writeback (CRC A9AA) |
| 1E DMABYTE2 | CNT_H byte-write anomaly is **bit7-granular on all four channels**: hi strb 0x80 mirrors into the low byte (0080); hi 0xC0 → 4080; lo 0xC0 → 0040; hi 0x40 → 4000 (CRC 1A71) |
| 1F SWEEP2 | model-bucket match: trigger checks do not write back; the tick path runs a recalculated second check; 2018/s7 survives the trigger (boundary is strictly > 2048) and dies at tick 1 (tick check ≥ 2048); 940/s1 survives (trigger second check reuses the old offset); 2033/s7 dies at trigger. hw polls 35CD/0A75/1138/0002 |
| 20 IRQWIN3 | dispatch window is cycle-based with dingbat's constant (2 muls / 2 ROM-ldrs / 3 mixed); ack-race `03 03` (CRC C443) |
| 21 IRQLAT2 (after fix) | reload-0 one-word arming delivers; one-word vs two-write byte-equal (Δ 0x143); FFF0 row enters the handler before the trigger stamp. The +6-cycle entry latency is a gamepak-execution-context cost at vector entry/return (CRC 0EE1, mGBA suite unmoved) |
| 22 IOBYTE2 | DISPSTAT low byte **stores** byte writes (0x38 → 0039; byte-clear → 0001; LYC hi strb → 3801). Session 3's "ignores byte writes" was the 0x44 payload having only bit 6 to store |
| 24 MSRTBIT2 | the A+8/skip-A+10 quirk is form-independent and composes with an IRQ→System switch in the same write (recovery mode 1F) (CRC E35E) |
| 11 CPSRBITS (partly) | sys-mode `mrs SPSR` returns CPSR |
| 12 THUMBPC (partly) | stored-PC deltas +12/+12/+12, `ldm pc` +8, Thumb `mov r0, pc` +4 |
| 16 CAPDMA (conclusion) | capture DMA runs in every armed frame (640 words = 160 triggers × 4) and hardware clears the enable at frame end; re-arming reloads dst from DAD. No every-other-frame pattern |

## Divergences (hardware ≠ dingbat)

| page | hardware | dingbat |
|---|---|---|
| 0F IRQLAT | DMA3 entry 029A; hblank pair (046A, 08DF); vblank (0AD4, 4375). (The TM2 row was a probe bug — `irq_arm` clobbered r5 and wrote IME; fixed in v6, re-measured on 21 IRQLAT2) | 0288; (0463, 08C0); (0AC8, 4363) — `IRQ_SYNC_DELAY` / `HBLANK_IRQ_SYNC_DELAY` one-row fits |
| 07 MULFLAGS | with C preset 1, MUL **clears** carry for operand pairs 0/1/2/5/6/7: nibbles `04 00 00 02 0A 04 08 08`; C-preset-0 and UMULLS/SMULLS rows match | `06 02 02 02 0A 06 0A 0A` |
| 00 IDENT | boot DISPCNT=0080, POSTFLG=01, `0x04000800`=0D000020 (documented cold-boot defaults; EverDrive-chainload caveat) | open bus at 0x04000800 |
| 04 TIMERS | prescaler-64 boot phase staircase `07 07 07 06 06 06` | `06 07 07 06 06 07` (k=0, k=5) |
| 0A PSGSTAT | ch1 length-63 expiry 2E1E polls | 283A (~14 % early) |
| 03/0D HLE path | Sqrt `00CC/0118/0164/01C3`; CpuFastSet 256 words 0DFB | HLE Sqrt `0106/020B/0368/051C`; 0FBD; Sqrt/ArcTan2/BgAffineSet 1–4 cycles off |
| 11 CPSRBITS | only NZCV latch in CPSR; SPSR holds exactly F00000FF; **SPSR bit 4 forced high** (write 0 → 10, 0F → 1F) | latches bits 8–27; reads back what was written |
| 12/19 THUMBPC, THUMBPC2 | Thumb `cmp pc, r0` loads SPSR into CPSR — a **full restore including mode** (SPSR 9000009F in IRQ mode → CPSR 9000009F); `add pc`/`mov pc` do not touch CPSR | plain compare (20000092) |
| 19 THUMBPC2 r15 writeback | `ldm r15!` no writeback (r7=15); `str r1,[r15],#4` PC=base+4 (r7=12); `ldr r1,[r15],#4` PC=base+8 with the **load suppressed** | base+8 / base+8 / load performed |
| 13 LDMUSER | `stm r13!, {r13}^` stores **user r13** and writes back base+4 into the **user** bank | stores 0; adds 4 to the old user value |
| 14/1A IRQWIN, IRQWIN2 | dispatch after 3 sled instructions for IME and IE stores, 2 for msr I-clear; cycle deltas 81/81/84; EWRAM-load sled lands after 2 loads | 1 everywhere; 67/67/6C |
| 15 DMAEDGE | `strb 0x80 → 0x040000DF` mirrors into both bytes (0080, transfer ran); byte writes to 0xDE/0xDD do nothing | no mirroring |
| 17 SWEEPQ | freq-1000 dies at first tick (F75 polls); period rewrite and same-value rewrite both die at ~1CBD (the NR10 write is irrelevant); length-63 control dies at 0 polls fresh and after idle frames (length clocked at/near trigger — the extra-length-clock quirk); period 0 never ticks | 12F4; 1CBF; 12AA9 / 1E9 (phase-dependent); cap matches |
| 18 BXDECODE | `[01, 01, DD, 04]`: `0xE12FFF31` (ARMv5 BLX word) **executes as BX**; `0xE120FF11` (SBO violated) wedges the console with IRQs masked (press 3 froze; SELECT skipped it); BX r15 → $+8 | `[01, 06, 01, 04]` — falls through the BLX word, takes the SBO-violated one as BX |
| 23 THUMBPC3 (a) | halfword-aligned T-clearing `cmp pc`: resumes ARM **past both overlay words** (scratch 0, r6 0 — A+10 or A+14); (b) System-mode cmp = C000001F on both (no SPSR → no-op restore) | resumes at `(A+2)&~3` and executes the A+6 word (r6=2) |

Session-1 raw page dump is `tests/roms/expected/agb-sp-1.txt`; the per-page
CRCs there are `IDENT 985C, OPENBUS 60B9, BIOSPROT A024, SWITIME EF34, TIMERS
DD91, DMALATCH 7A27, LDMSTM 6899, MULFLAGS 64F4, MSRTBIT DCB3/6DA2, PPUSTAT
2E32, PSGSTAT F59F, WAITSTATE C0D2, PFPHASE 34E0, SWIREGION 65E6, CONTEND
2D2C, IRQLAT C288`.

## Session 5 (2026-09-04): pages 37–49

Photographed on the same AGS-001; every hex page re-checked against its
on-screen CRC. Three pages matched dingbat's prediction outright, ten did
not. The verdict per page, in the order a fix would be worth landing:

| page | hardware said | dingbat | fix that follows |
|---|---|---|---|
| 25 OBJBUDGET, 26 OBJGEOM | same picture and CRC as `predicted-2026-09/p37,p38.png` | match | none |
| 2A MULTIME | carry matrix and early-termination sweep byte-exact | match | none: the MULFLAGS row from session 1 is closed |
| 2D MEMCTL | the EWRAM wait field of `0x04000800` is live: 16 word reads cost 321/289/609 at WS 13/14/4, i.e. `waits = 15 − WS`, `2·(1+waits)` per word; 8/16-bit access and the 64 K mirrors all work | 321 for every setting (readback only) | **landed**: `update_waitcnt` applies the field to page 2; the page now matches byte-for-byte, suites unchanged |
| 2F IWCYCLE | immediate-return IntrWait = 192, matching the real BIOS; mirror clear, r12, sp, IME residues all as modelled | HLE 160 | charge a 32-cycle entry cost in the HLE IntrWait; the halting rows are absolutely timed and already exact |
| 31 UNDMODE | in an undefined CPSR mode (15/1A/1E) banked r13 and r14 read **0**; the mode field latches the pattern; system-mode r13 survives | routes the pattern to the user bank (reads 51515151, leaks r14) | a seventh, empty bank: reads 0, writes discarded |
| 28 IRQDECOMP | halted H-blank wake 989 vs 970: recognition ~19 cycles later. V-blank/DMA/timer halted rows exact; IF-ack race byte-exact | `HBLANK_IRQ_SYNC_DELAY = 6` | 6 → ~25; the six failing H-blank Flip suite rows need the same direction and size. Running-CPU rows differ by sub-instruction attribution (+4…+30, one loop period), no knob |
| 2E DMATIME | start delays and IWRAM/OAM/PRAM/EWRAM/ROM bursts exact to the cycle; VRAM burst +21 (renderer contention); completion IRQ reaches a **running** CPU 15 cycles later (halted case exact, same +15 on IRQDECOMP) | no contention; IRQ gate | defer recognition, not IF, after a burst when the CPU is running; VRAM term below |
| 30 DMAFIFO | grant is level-conditioned (one 4-word burst per 16 overflows, single-shot leaves nothing behind), confirming the Assumed rule; each hardware-triggered burst costs ~1 cycle more; FIFO B on DMA2 exactly equals A | bursts 30 cycles; B one burst cheaper | +1 on the timer-triggered grant; trace the B/A phase before calling it a rule |
| 27 DMAOPENBUS | grant at store+3 confirmed; DMA3 from unmapped space repeats its own latch (both `A5A5A5A5`); the one wrong word says an opcode fetch also refreshes open bus | window lasts to the end of the instruction | clear the arm flag at the next opcode fetch; re-check the passing "DMA Prefetch Read" row and Hello Kitty Collection's boot |
| 29 CONTEND2 | OAM: zero contention in every configuration. PRAM: +1 over 16 reads. VRAM, mode 0: **+1 per CPU halfword read**, OBJ layer and H-blank-free irrelevant. VRAM, mode 2 with two affine BGs: the CPU is locked out until H-blank (1066 vs 230). Code executed from VRAM under forced blank costs 220, not 183 | no contention term; VRAM opcode fetch undercharged by ~2/instruction | first the VRAM fetch cost (a bus bug, renderer off); then an affine-mode VRAM block; a per-access probability term would break the exact mode-3 CONTEND page, contention is phase-locked |
| 2B TIMPHASE | one free-running divider shared by all timers, a reload write does not realign it, a fresh timer inherits a running one's phase (row `06 19` exact); staircase shape reproduced by the same window length | same model; base phase 1–7 cycles apart | none: shape-only page, residual is accumulated boot drift |
| 2C PSGPHASE | every ch1 trigger that is the **first trigger after a SOUNDCNT_X 0→1** dies at once, for lengths 1, 2 and 4 ticks alike (no poll timed out; SOUNDCNT_X reads 80 right after the trigger); ch2 triggered two stores later lives 486 polls; where both live, the 256 Hz length clock matches to one poll | length counters live | none yet: not a length-unit effect. One follow-up page decides ch1-specific (sweep unit) vs first-trigger-of-any-channel; also read the BIOS's boot value of bit 7 |
