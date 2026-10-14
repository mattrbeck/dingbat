@ payload: psgrace -- psgfirst.s's page with its entry phase made an argument
@
@ psgfirst.s's f = 0x400 ch1 rows (+0, +8, +12, +16) die or live run to run
@ on the AGB SP (tests/roms/dbsuite/sp-agb.json 'psgfirst', nine runs from
@ IWRAM): +0 lives 3/9, +8 5/9, +12 2/9, +16 6/9; the cartridge photograph
@ (agb-sp-6.txt page 33, one run) has +12 alive and the rest dead. The rig
@ enters a payload at no fixed cycle. If the spread is that entry phase --
@ against the PSG's 4 MHz / 2 MHz / 1 MHz dividers and the 512 Hz
@ sequencer -- then a page entered on a fixed cycle (a V-count halt) and
@ walked by a delay reproduces the console's set of answers, cell by cell.
@
@ The page from "the first trigger after a master-on" to the last row is
@ psgfirst.s's, instruction for instruction (pf_wait / pf_reset as there).
@
@   r0 bits 0..3   d: (d & 15) + 1 one-cycle NOPs after the wake
@      bits 8..15  c: c * 64 four-cycle spins before them (256 cycles a
@                  step; c = 0..127 walks the 512 Hz sequencer's 32768)
@ answer: bits 0..15  +12's poll count (ch1 after ch2's whole tone)
@         bit 16 +0 alive, 17 +8, 18 +12, 19 +16, 20 +18, 21 +10 (more
@         than 0x100 polls); bits 24..27 the low nibble of +0's count
@         (0 or 1 when it dies: how soon)
    .include "probe.inc"
    .arm
    .text
    .global _start

.equ IOBASE,  0x04000000
.equ RESULTS, 0x02008000

.macro pf_wait ctl, trig, bit
    strh r0, [r4, #\ctl]
    strh r1, [r4, #\trig]
    ldrh r6, [r4, #0x84]
    ldr r2, =0x00060000
    mov r3, #0
1:  ldrh r0, [r4, #0x84]
    tst r0, #\bit
    beq 2f
    add r3, r3, #1
    subs r2, r2, #1
    bne 1b
    add r9, r9, #1
    mvn r3, #0                     @ never expired: 0xFFFF, not a truncated
                                   @ 0x60000 that would read as "died at once"
2:
.endm

@ master off (which clears every PSG register) then on, and the mixer set up
@ for all four channels
.macro pf_reset
    mov r0, #0
    strh r0, [r4, #0x84]
    mov r0, #0x80
    strh r0, [r4, #0x84]
    ldr r0, =0xFF77                @ all four channels, both sides, full
    strh r0, [r4, #0x80]
    mov r0, #2
    strh r0, [r4, #0x82]           @ PSG ratio 100 %
.endm

@ ch3 needs its DAC on and a non-zero wave before it will play at all
.macro pf_wave
    mov r0, #0x80
    strh r0, [r4, #0x70]           @ NR30: DAC on, bank 0
    ldr r0, =0x04000090
    mvn r1, #0
    str r1, [r0, #0]
    str r1, [r0, #4]
    str r1, [r0, #8]
    str r1, [r0, #12]
.endm

_start:
    probe_enter
    ldr r8, =RESULTS
    mov r0, #0
    mov r1, #0
    mov r2, #0
    mov r3, #0
    stmia r8, {r0-r3}
    add r6, r8, #16
    stmia r6, {r0-r3}
    probe_park 100
    mov r0, r9, lsr #8
    and r0, r0, #0xFF
    movs r0, r0, lsl #6
    beq 9f
8:  subs r0, r0, #1
    bne 8b
9:  probe_sled r9
    mov r4, #IOBASE
    ldr r8, =RESULTS
    mov r9, #0

    @ -- the first trigger after a master-on, one channel at a time --
    pf_reset
    ldr r0, =0xF0B0                @ envelope 15, duty 2, counter 16
    ldr r1, =0xC400                @ trigger + length enable
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #0]
    strb r6, [r8, #21]

    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x68, 0x6C, 2
    strh r3, [r8, #2]
    strb r6, [r8, #22]

    pf_reset
    pf_wave
    ldr r0, =0x20F0                @ NR32 volume 100 %, NR31 counter 16
    ldr r1, =0xC000                @ trigger + length enable
    pf_wait 0x72, 0x74, 4
    strh r3, [r8, #4]

    pf_reset
    ldr r0, =0xF030                @ NR42 envelope 15, NR41 counter 16
    ldr r1, =0xC000                @ NR44 trigger + length enable, NR43 = 0
    pf_wait 0x78, 0x7C, 8
    strh r3, [r8, #6]
    strb r6, [r8, #23]

    @ -- ch1's sweep unit idle vs running --
    pf_reset
    mov r0, #0
    strh r0, [r4, #0x60]           @ NR10: no sweep (also the reset state)
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #8]

    pf_reset
    mov r0, #0x11                  @ NR10: period 1, shift 1 -- unit running
    strh r0, [r4, #0x60]
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #10]

    @ -- is it ch1, or is it whoever goes first? --
    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x68, 0x6C, 2          @ ch2 takes the first slot ...
    strh r3, [r8, #14]
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1          @ ... so ch1 is only the second trigger
    strh r3, [r8, #12]

    @ -- ch1's own second trigger, and ch1 with no master toggle --
    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1          @ discarded
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #16]

    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #18]

    @ -- the same two first triggers with the length counter disabled --
    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0x8000                @ trigger, length enable CLEAR
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #24]

    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0x8000
    pf_wait 0x68, 0x6C, 2
    strh r3, [r8, #26]

    mov r0, #0
    strh r0, [r4, #0x84]           @ leave the PSG off behind us
    mov r3, #0
    ldrh r1, [r8, #0]
    cmp r1, #0x100
    orrhi r3, r3, #0x1
    ldrh r1, [r8, #8]
    cmp r1, #0x100
    orrhi r3, r3, #0x2
    ldrh r1, [r8, #12]
    cmp r1, #0x100
    orrhi r3, r3, #0x4
    ldrh r1, [r8, #16]
    cmp r1, #0x100
    orrhi r3, r3, #0x8
    ldrh r1, [r8, #18]
    cmp r1, #0x100
    orrhi r3, r3, #0x10
    ldrh r1, [r8, #10]
    cmp r1, #0x100
    orrhi r3, r3, #0x20
    ldrh r1, [r8, #0]
    and r1, r1, #0xF
    orr r3, r3, r1, lsl #8
    ldrh r0, [r8, #12]
    orr r0, r0, r3, lsl #16
    mov r5, #0x04000000
    add r5, r5, #0x200
    ldr r8, =0x040000B0
    ldr r10, =0x04000100
    ldr r12, =probe_vars
    probe_leave
    .ltorg
    probe_data
