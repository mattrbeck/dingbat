@ payload: the sound-FIFO DMA "spikes" (tests/roms/dbsuite fifodma), with a
@ safe way out
@
@ WHAT: fifodma's geometry (FIFO A on TM0 reload 0x10000 - k, DMA1 sound
@ FIFO 32-bit repeat from EWRAM, TM1 /1 started on the next cycle, n
@ one-cycle NOPs, then an access). fifodma's console table has three cells
@ that cost the CPU one or two refill bursts more than their neighbours
@ (k = 20: n = 14 reads 80, n = 24 reads 90; the EWRAM-load n = 17 reads 91).
@
@ FOUND (AGB SP, 2026-09-25, rig.ask 3 interleaved passes, every cell one
@ answer): the spike belongs to the cell BEFORE. Each cell stops TM0 on its
@ way out; the cells whose TM1 read lands on TM0's overflow cycle (k = 20:
@ n = 13 and 23, the load at n = 16) stop it at 0xFFFF, and the next cell's
@ enable over 0xFFFF overflows on its start cycle (the tick tmrffirq.s
@ measured for the interrupt) -- a whole overflow: FIFO A takes it, asks
@ for a refill, and every NOP count of that next cell reads two bursts (60
@ cycles) more than it does after any other cell. [P, X] pairs, no guard:
@   P = n13 or n23 -> X n10 76, n12 78, n14 80, n16 82, n17 83, n20 86,
@                     n24 90, n26 92, n28 94
@   P = n15        -> X n10 16, n12 18, n14 20, n16 22, n17 53, n20 56,
@                     n24 60, n26 62, n28 94
@ fifodma ran its cells in NOP order, so its n14 and n24 followed n13 and
@ n23. (dingbat: timer.nim TIMER_START_OVERFLOW.) A read at TOVF+1 is not
@ special: k = 33 n = 27 and every access variant at k = 20 n = 14 read what
@ their predecessor predicts.
@ Also: DMA0 armed on V-blank (idle, the guard below) changes nothing on the
@ console -- k = 20 n = 10..30 read the same with and without it -- where
@ dingbat ran its events inside the FIFO burst then and chained a second
@ burst (dma_channels.nim FIFO_OWN_BURST_NO_REQUEST).
@
@ SAFETY (tmp fifomap.s, the earlier probe, wedged the console on its first
@ cell three times; cause unknown):
@  - the way out stops TM0 first and then waits ~160 cycles with nothing
@    else to do before it disables DMA1, so the disable can never land on a
@    burst's start (fifomap stopped TM0 and disabled DMA1 two instructions
@    apart: a stop on an overflow requests a refill that starts about when
@    the disable lands);
@  - DMA0 is armed on V-blank to write 0 to DMA1CNT_H: if refills ever came
@    back to back for good (a DMA that never lets go of the bus), the next
@    V-blank breaks the chain and the payload comes back with bit 31 set;
@  - every IO register it touches is left as found or off (SOUNDCNT_X/H
@    restored, TM0/TM1/DMA0/DMA1 off); WAITCNT is not touched.
@ 161 cells of it ran on the console without trouble.
@
@ r0 bits 0..7   n  one-cycle NOPs after the timers start (0..63)
@    bits 8..15  k  TM0 period
@    bits 16..18 v  what comes after the NOPs:
@                   0 TM1 read (the answer)
@                   1 KEYINPUT read, then TM1        2 TM0 read, then TM1
@                   3 EWRAM load, then TM1           4 DMA1CNT_H read, then TM1
@                   5 TM1 twice (first << 16 | second)
@                   6 SOUNDCNT_H read, then TM1
@                   7 TM1, p NOPs, TM1 (first << 16 | second)
@    bit  19        no V-blank guard (the old probe's setup, for comparison)
@    bits 20..25 d  NOPs before the timer start (phase)
@    bits 26..31 p  NOPs between the reads of v = 7
@ answer: as above, bit 31 set if the V-blank guard fired
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    mov r4, #0x04000000
    ldrh r0, [r4, #0x84]
    ldrh r1, [r4, #0x82]
    orr r0, r0, r1, lsl #16
    str r0, saved                  @ SOUNDCNT_H << 16 | SOUNDCNT_X
    mov r0, #0
    str r0, [r4, #0x100]           @ TM0 off
    str r0, [r4, #0x104]           @ TM1 off
    strh r0, [r4, #0xC6]           @ DMA1 off
    strh r0, [r4, #0xBA]           @ DMA0 off
    @ the guard: DMA0 on V-blank writes 0 to DMA1CNT_H, once
    adr r1, zero
    str r1, [r4, #0xB0]            @ DMA0SAD
    add r1, r4, #0xC6
    str r1, [r4, #0xB4]            @ DMA0DAD = DMA1CNT_H
    mov r1, #1
    strh r1, [r4, #0xB8]
    ldr r1, =0x9140                @ on, V-blank, 16-bit, src fixed, dst fixed
    tst r11, #0x80000
    streqh r1, [r4, #0xBA]
    mov r1, #0x80
    strh r1, [r4, #0x84]           @ SOUNDCNT_X: master on
    ldr r1, =0x0B04
    strh r1, [r4, #0x82]           @ SOUNDCNT_H: FIFO A L+R, TM0, reset
    ldr r1, =0x02004000
    str r1, [r4, #0xBC]            @ DMA1SAD (EWRAM, the experiments' area)
    ldr r1, =0x040000A0
    str r1, [r4, #0xC0]            @ DMA1DAD
    mov r1, #4
    strh r1, [r4, #0xC4]
    ldr r1, =0xB640
    strh r1, [r4, #0xC6]           @ DMA1: on, special, 32-bit, repeat, dst fixed
    @ the empty FIFO requests on TM0's first overflow
    and r0, r11, #0xFF             @ n
    rsb r0, r0, #64
    ldr r9, =sled
    add r9, r9, r0, lsl #2
    and r0, r11, #0xFF00
    mov r0, r0, lsr #8
    rsb r7, r0, #0x10000
    orr r7, r7, #0x00800000        @ TM0: reload, /1, on (no IRQ)
    mov r8, #0x00800000            @ TM1: /1, on
    add r1, r4, #0x100
    ldr r6, =0x02004100
    and r0, r11, #0x70000
    ldr r10, =tails
    ldr r10, [r10, r0, lsr #14]
    mov r0, r11, lsr #26           @ p
    rsb r0, r0, #64
    ldr r12, =psled
    add r12, r12, r0, lsl #2
    and r0, r11, #0x3F00000
    mov r0, r0, lsr #20
    rsb r0, r0, #64
    ldr r2, =dsled
    add r2, r2, r0, lsl #2
    bx r2
dret:
    mov lr, pc
    b go
    mov r5, r0                     @ the answer
    mov r0, #0
    str r0, [r4, #0x100]           @ TM0 off: no more requests
    mov r2, #40                    @ ~160 cycles: any burst still owed ends
1:  subs r2, r2, #1
    bne 1b
    str r0, [r4, #0x104]           @ TM1 off
    strh r0, [r4, #0xC6]           @ DMA1 off
    ldrh r2, [r4, #0xBA]
    tst r2, #0x8000
    orreq r5, r5, #0x80000000      @ the guard ran
    strh r0, [r4, #0xBA]           @ DMA0 off
    ldr r0, saved
    orr r1, r0, #0x88000000        @ FIFO A and B reset, as found otherwise
    mov r1, r1, lsr #16
    strh r1, [r4, #0x82]
    strh r0, [r4, #0x84]
    mov r0, r5
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .align 2
saved:
    .word 0
zero:
    .word 0
    .ltorg
go:
    stmia r1, {r7, r8}             @ TM0, then TM1
    bx r9                          @ into the sled (a branch: fixed cost)
    .align 2
sled:
    .rept 64
    mov r0, r0
    .endr
    bx r10
t_tm1:                           @ v0
    ldrh r0, [r1, #4]
    mov pc, lr
t_keyin:                         @ v1
    ldrh r3, [r1, #0x30]           @ KEYINPUT (r1 = 0x04000100)
    ldrh r0, [r1, #4]
    mov pc, lr
t_tm0:                           @ v2
    ldrh r3, [r1, #0]
    ldrh r0, [r1, #4]
    mov pc, lr
t_iwram:                         @ v3
    ldr r3, [r6]                   @ EWRAM (fifodma variant 1)
    ldrh r0, [r1, #4]
    mov pc, lr
t_dmacnt:                        @ v4
    ldrh r3, [r4, #0xC6]
    ldrh r0, [r1, #4]
    mov pc, lr
t_tm1x2:                         @ v5
    ldrh r0, [r1, #4]
    ldrh r3, [r1, #4]
    orr r0, r3, r0, lsl #16
    mov pc, lr
t_sndcnt:                        @ v6
    ldrh r3, [r4, #0x82]
    ldrh r0, [r1, #4]
    mov pc, lr
t_gap:                           @ v7
    ldrh r0, [r1, #4]
    bx r12
t_iowr:                          @ (unused)
    strh r3, [r4, #0x86]
    ldrh r0, [r1, #4]
    mov pc, lr
t_spin:                          @ (dingbat copies only): two frames
    ldr r3, =140000
2:  subs r3, r3, #1
    bne 2b
    ldrh r0, [r1, #4]
    mov pc, lr
    .ltorg
    .align 2
psled:
    .rept 64
    mov r0, r0
    .endr
    ldrh r3, [r1, #4]
    orr r0, r3, r0, lsl #16
    mov pc, lr
    .align 2
dsled:
    .rept 64
    mov r0, r0
    .endr
    b dret
    .align 2
tails:
    .word t_tm1, t_keyin, t_tm0, t_iwram, t_dmacnt, t_tm1x2, t_sndcnt, t_gap
    @ never reached from an argument; dingbat test copies only
    .word t_iowr, t_spin
    .ltorg
