@ payload: when an immediate DMA takes the bus from the instruction after
@ its enable.
@
@ DMA0 copies TM1CNT (TM1 at /1, started three instructions earlier) into
@ EWRAM, armed by a store and followed by one variant instruction; then the
@ CPU reads TM1. On an AGB SP (tools/hwlink, 2026-09-24), counting from the
@ enabling store's last cycle W: the DMA requests the bus at W+2. A CPU
@ access that began before then (a load or store issued by the next
@ instruction, from W+1) finishes first -- a load reads memory as it was --
@ and the burst starts at its end: an EWRAM word load or store delays it by
@ five cycles, a halfword by two, a one-cycle IWRAM or I/O access not at all.
@ An access starting on W+2 (after a NOP, or an ldm's second word) loses the
@ bus to the burst. Internal cycles (a multiply's, a load's last) run under
@ the burst. ARM and Thumb agree cell for cell.
@
@ r0 bits 0..3 variant, bit 4 Thumb
@   0  -                         5  mul; ldr EWRAM dest
@   1  ldr EWRAM (DMA's dest)    6  str EWRAM
@   2  ldr IWRAM                 7  ldm IWRAM, 2 words
@   3  nop; ldr EWRAM dest       8  ldrh I/O (IE)
@   4  nop; nop; ldr EWRAM dest  9  ldrh EWRAM dest
@ answer: bits 0..7   TM1 as the DMA read it
@         bits 8..9   the variant's load: 0 the old value, 1 the DMA's, 2 other
@         bits 16..23 TM1 as the CPU read it after
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    mov r3, #0x04000000
    mov r0, #0
    strh r0, [r3, #0xBA]           @ DMA0 off
    str r0, [r3, #0x104]           @ TM1 off
    ldr r4, =0x02004000
    ldr r2, =0xDEADBEEF
    str r2, [r4]
    str r4, [r3, #0xB4]            @ DMA0DAD
    add r1, r3, #0x104
    str r1, [r3, #0xB0]            @ DMA0SAD = TM1CNT
    str r0, [r3, #0xB8]
    add r3, r3, #0xB8              @ DMA0CNT
    ldr r2, =0x84000001
    ldr r5, =iw
    ldr r6, =0x02004100
    ldr r7, =0x04000200            @ IE: a register nothing here changes
    mov r8, #0x00800000
    mov r9, #0
    and r0, r11, #0x1F
    ldr r10, =bodies
    ldr r10, [r10, r0, lsl #2]
    mov lr, pc
    bx r10
    @ r0 = CPU TM1 read, r9 = the variant's load
    ldr r2, [r4]                   @ the DMA's word
    and r1, r2, #0xFF
    ldr r3, =0xDEADBEEF
    and r10, r11, #0xF
    cmp r10, #9
    moveq r3, r3, lsl #16          @ ldrh: the low half
    moveq r3, r3, lsr #16
    moveq r2, r2, lsl #16
    moveq r2, r2, lsr #16
    cmp r9, r3
    beq 1f
    cmp r9, r2
    orreq r1, r1, #0x100
    orrne r1, r1, #0x200
1:  and r0, r0, #0xFF
    orr r0, r1, r0, lsl #16
    mov r3, #0x04000000
    mov r2, #0
    str r2, [r3, #0x104]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
    .align 2
iw: .word 0x11111111, 0x22222222, 0x33333333, 0x44444444
bodies:
    .word a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, 0, 0, 0, 0, 0, 0
    .word t0+1, t1+1, t2+1, t3+1, t4+1, t5+1, t6+1, t7+1, t8+1, t9+1

    .macro arm_body n, v
    .align 2
a\n:
    str r8, [r1]                   @ TM1 on
    mov r0, r0
    mov r0, r0
    str r2, [r3]                   @ DMA0 on
    \v
    ldrh r0, [r1]
    bx lr
    .endm
    arm_body 0, ""
    arm_body 1, "ldr r9, [r4]"
    arm_body 2, "ldr r9, [r5]"
    arm_body 3, "mov r0, r0; ldr r9, [r4]"
    arm_body 4, "mov r0, r0; mov r0, r0; ldr r9, [r4]"
    arm_body 5, "mul r0, r7, r7; ldr r9, [r4]"
    arm_body 6, "str r9, [r6]"
    arm_body 7, "ldmia r5, {r9, r12}"
    arm_body 8, "ldrh r9, [r7]"
    arm_body 9, "ldrh r9, [r4]"
    .ltorg

    .thumb
    .macro thumb_body n, v
    .align 2
t\n:
    mov r0, r8
    mov r6, r0
    str r6, [r1]                   @ TM1 on
    mov r0, r0
    mov r0, r0
    str r2, [r3]                   @ DMA0 on
    \v
    ldrh r0, [r1]
    mov r9, r6
    bx lr
    .endm
    thumb_body 0, ""
    thumb_body 1, "ldr r6, [r4]"
    thumb_body 2, "ldr r6, [r5]"
    thumb_body 3, "mov r0, r0; ldr r6, [r4]"
    thumb_body 4, "mov r0, r0; mov r0, r0; ldr r6, [r4]"
    thumb_body 5, "mul r0, r7; ldr r6, [r4]"
    thumb_body 6, "str r6, [r4, #64]"
    thumb_body 7, "ldmia r5!, {r0, r6}"
    thumb_body 8, "ldrh r6, [r7]"
    thumb_body 9, "ldrh r6, [r4]"
