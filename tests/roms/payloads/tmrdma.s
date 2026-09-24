@ payload: two immediate DMAs racing on a timer (alyosha timer/timer_reset,
@ from IWRAM).
@
@ DMA1 writes TM0CNT (reload 0xFFE0, /1, enable) from IWRAM; k Thumb NOPs
@ after its enable a store arms DMA0, which reads TM0CNT into EWRAM; then
@ the CPU reads that EWRAM word and the timer. TM0 was left stopped near
@ 0xFF80 first. On an AGB SP (tools/hwlink, 2026-09-24):
@ - k = 0: DMA1 runs first although DMA0 has the higher priority (DMA0's
@   request comes two cycles after its own enable), and DMA0 follows it on
@   the next cycle: it reads the old count under the new control bits (a
@   timer read before counting starts still shows the old count), and the
@   pair costs the CPU one lead and one hand-back, not two of each;
@ - k >= 1: DMA0's request lands inside the CPU's 6-cycle EWRAM load: the
@   load reads the word as it was (0xDEADBEEF) and DMA0 waits for its end;
@ - DMA1 alone: a DMA-written TMCNT starts the timer where the DMA's write
@   lands, not where its burst began.
@ alyosha timer_reset expects 0xF3 for the CPU's read at k = 0 from ROM; this
@ replica reads 0xF3 on the console too.
@
@ r0 bits 0..2  k, Thumb NOPs between the two enables
@    bit 4      no DMA0 (DMA1 only)
@    bit 5      no DMA1 (DMA0 only, timer left stopped)
@ answer: bits 0..15  DMA0's word, low half (0xBEEF: DMA0 never ran)
@         bit 16      DMA0's word's high half is 0x0080 (the new control)
@         bits 17..18 the CPU's EWRAM read: 0 the old word, 1 DMA0's, 2 other
@         bits 24..31 the CPU's TM0 read, low byte
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    mov r3, #0x04000000
    mov r0, #0
    strh r0, [r3, #0xBA]           @ DMA0CNT_H off
    strh r0, [r3, #0xC6]           @ DMA1CNT_H off
    ldr r1, =0x0080FF80
    str r1, [r3, #0x100]           @ TM0: reload FF80, /1, on
    str r0, [r3, #0x100]           @ and off: count near FF80
    ldr r1, =0x02004000            @ DMA0 destination
    ldr r2, =0xDEADBEEF
    str r2, [r1]
    str r1, [r3, #0xB4]            @ DMA0DAD
    add r2, r3, #0x100
    str r2, [r3, #0xB0]            @ DMA0SAD = TM0CNT
    str r2, [r3, #0xC0]            @ DMA1DAD = TM0CNT
    ldr r2, =word
    str r2, [r3, #0xBC]            @ DMA1SAD = the word below
    str r0, [r3, #0xB8]            @ counts 0, controls off
    str r0, [r3, #0xC4]
    ldr r2, =0x84000001            @ enable, 32-bit, immediate, 1 unit
    add r4, r3, #0xC4              @ DMA1CNT (r4) and DMA0CNT (r3)
    add r3, r3, #0xB8
    tst r11, #0x20
    ldrne r4, =scratch             @ no DMA1: its store goes nowhere
    tst r11, #0x10
    ldrne r3, =scratch             @ no DMA0
    ldr r6, =0x04000100            @ TM0
    and r0, r11, #7
    ldr r9, =bodies
    ldr r9, [r9, r0, lsl #2]
    orr r9, r9, #1
    ldr r1, =0x02004000
    mov lr, pc
    bx r9
    @ r0 = CPU TM0 read, r5 = CPU EWRAM read
    ldr r2, =0x02004000
    ldr r2, [r2]                   @ DMA0's word
    mov r1, r2, lsl #16
    mov r1, r1, lsr #16
    mov r3, r2, lsr #16
    cmp r3, #0x80
    orreq r1, r1, #0x10000
    ldr r3, =0xDEADBEEF
    cmp r5, r3
    beq 1f
    cmp r5, r2
    orreq r1, r1, #0x20000
    orrne r1, r1, #0x40000
1:  and r0, r0, #0xFF
    orr r0, r1, r0, lsl #24
    mov r3, #0x04000000
    mov r1, #0
    str r1, [r3, #0x100]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
    .align 2
word:
    .word 0x0080FFE0
scratch:
    .word 0
bodies:
    .word b0, b1, b2, b3, b4, b5, b6, b7

    .thumb
    .macro body k
    .align 2
b\k:
    ldr r0, [r6]
    mov r8, r0
    cmp r0, r0
    bne 9f
    mov r0, #0
    ldr r5, [r1]
    ldr r5, [r1]
    str r2, [r4]                   @ DMA1 on
    .rept \k
    mov r8, r8
    .endr
    str r2, [r3]                   @ DMA0 on
    ldr r0, [r1]                   @ the EWRAM word
    mov r5, r0
    cmp r0, r0
    bne 9f
    ldr r0, [r6]                   @ the timer
9:  bx lr
    .endm
    body 0
    body 1
    body 2
    body 3
    body 4
    body 5
    body 6
    body 7
