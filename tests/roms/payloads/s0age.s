@ s0age.s -- does channel 1's slow shift-0 timing run out by itself, or does
@ a channel's note ending, or an NR10 write, end it?
@
@ psgfirst.s's page (tests/roms/dbsuite/sp-agb.json 'psgfirst', nine runs
@ from IWRAM, and the cartridge photograph agb-sp-6.txt page 33): ch1
@ f = 0x400 triggered after ch2's whole note (+12, about 1.05M cycles after
@ the master-on, CPU running) lives in 3 runs of 10; on dingbat's slow
@ timing it cannot live at any entry phase (a phase sweep of the same page,
@ payloads/psgrace.s, never has +12 alive: the trigger's distance from the
@ master-on is fixed mod 16 there). And +8 -- NR10 = 0 written before the
@ trigger -- lives in 5 runs of 9, where dingbat's slow timing spares about
@ one phase in 10. s0long.s held the slow timing to 262144 cycles with no
@ note playing and no NR10 write. This page is s0long.s's no-halt path
@ (park on line 50, master on, spin, trigger) with
@
@   r0 bits 0..3  k: (k & 15) + 1 cycle sled right before the trigger
@      bits 4..6  m: SPIN[m] x 4 cycles between the master-on and the
@                 trigger: 262144 (s0long's longest, the control) .. 1572864
@      bit  8     ch2 note (NR21/22 0xF0B0, NR24 0xC400: length 16, dies at
@                 the 16th length clock, about 1.05M cycles on) triggered
@                 right after the master-on; clear: the same stores to IWRAM
@      bit  9     NR10 = 0 written right before ch1's NR11/NR12; clear: the
@                 same store to IWRAM
@ Every skipped write goes to IWRAM instead (same cost), so the trigger's
@ distance from the master-on and from the wake does not move with bits 8, 9,
@ and SPIN[m] x 4 is a multiple of 65536, so not mod 16 either.
@ answer: as s0trig.s -- bits 0..7 SOUNDCNT_X bit 0 at eight reads 3 cycles
@ apart after the trigger, bits 16..31 polls it stayed on (cap FFFF)
@
@ Predicted (written 2026-10-14, before any console run):
@   (k = 0..15, the low byte of each answer, L = lives (FFFF00FF))
@   H0, dingbat today (HLE and Nintendo's BIOS): every (m, bit 8, bit 9)
@     row is the slow row, s0long's no-halt shape at this page's distance:
@     1 0 L F 7 7 7 3 3 3 L 3 3 3 1 1 (one phase in 8 lives)
@   H1, the slow timing runs out by itself between 262144 and ~1.05M
@     cycles: m = 0 is that row, longer m turn to a non-slow class --
@     C2 (s0trig bit 14; dingbat forced off the slow timing gives
@     1 3 1 1 1 3 1 1 1 3 1 1 1 3 1 1, no L) or C3 (s0path's base: one
@     L in 4 phases, 3 at the other three)
@   mGBA: L in every cell (no shift-0 check at all)
@   H2, a channel's note ending by length ends it: bit 8 rows with
@     m >= 4 (past ch2's death) leave the slow row; bit 8 clear stays slow
@   H3, an NR10 write ends it (psgfirst +8): bit 9 rows leave the slow row
@     at every m
@ dingbat's actual answers: docs/playtest-bugs.md (the section that adds
@ this file).
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    mov r0, #0
    strh r0, [r4, #0x84]           @ master off (clears the PSG)
    mov r0, r9, lsr #4
    and r0, r0, #0x07
    adr r1, spins
    ldr r7, [r1, r0, lsl #2]       @ spin count
    @ where bit 8's and bit 9's stores go: the PSG, or a word of probe_vars
    add r6, r12, #40               @ dummy (IWRAM), 0x60-relative
    sub r6, r6, #0x60
    tst r9, #0x100
    moveq r10, r6                  @ ch2 stores' base
    movne r10, r4
    tst r9, #0x200
    moveq r11, r6                  @ NR10 store's base
    movne r11, r4
    mov r2, #0x80
    ldr r3, =0xF0B0
    ldr r6, =0xC400
    probe_park 50
    strh r2, [r4, #0x84]           @ master on
    ldr r0, =0xFF77
    strh r0, [r4, #0x80]
    strh r3, [r10, #0x68]          @ ch2 NR21/NR22 (or IWRAM)
    strh r6, [r10, #0x6C]          @ ch2 trigger, length on (or IWRAM)
3:  subs r7, r7, #1                @ 4 cycles an iteration
    bne 3b
    mov r0, #0
    strh r0, [r11, #0x60]          @ NR10 = 0 (or IWRAM)
    ldr r0, =0xF0B0                @ ch1 NR11/NR12
    strh r0, [r4, #0x62]
    ldr r1, =0x8400                @ trigger, f = 0x400, length off
    probe_sled
    strh r1, [r4, #0x64]           @ trigger
    ldrh r0, [r4, #0x84]
    ldrh r1, [r4, #0x84]
    ldrh r2, [r4, #0x84]
    ldrh r3, [r4, #0x84]
    ldrh r6, [r4, #0x84]
    ldrh r7, [r4, #0x84]
    ldrh r10, [r4, #0x84]
    ldrh r11, [r4, #0x84]
    and r0, r0, #1
    and r1, r1, #1
    orr r0, r0, r1, lsl #1
    and r2, r2, #1
    orr r0, r0, r2, lsl #2
    and r3, r3, #1
    orr r0, r0, r3, lsl #3
    and r6, r6, #1
    orr r0, r0, r6, lsl #4
    and r7, r7, #1
    orr r0, r0, r7, lsl #5
    and r10, r10, #1
    orr r0, r0, r10, lsl #6
    and r11, r11, #1
    orr r0, r0, r11, lsl #7
    mov r3, #0
    ldr r2, =0xFFFF
4:  ldrh r1, [r4, #0x84]
    tst r1, #1
    beq 5f
    add r3, r3, #1
    cmp r3, r2
    blt 4b
5:  orr r0, r0, r3, lsl #16
    ldr r10, =0x04000100           @ probe_leave uses r10 and r11
    mov r1, #0
    strh r1, [r4, #0x84]           @ master off on the way out
    probe_leave
    .ltorg
    .align 2
spins:                             @ x4 cycles: 262k, 393k, 524k, 655k, 786k, 1.05M, 1.31M, 1.57M
    .word 65536, 98304, 131072, 163840, 196608, 262144, 327680, 393216
    probe_data
