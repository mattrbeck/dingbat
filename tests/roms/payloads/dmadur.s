@ payload: how long a one-unit immediate DMA holds the bus, and when a timer
@ a DMA starts begins counting.
@
@ A store arms DMA0 (or, variant 0, nothing), n NOPs follow, then the CPU
@ reads TM1 (/1). On an AGB SP (tools/hwlink, 2026-09-24) every cell of
@ variants 3-7 matched dingbat as it was; variants 1 and 2 read two counts
@ lower than it did, because a TMCNT write a DMA makes lands where the
@ burst has got to, not at its start. (Variants 1 and 2 at n = 0 read TM1
@ before the DMA has started it: whatever the last run left.)
@
@ r0 bits 0..2 variant, bits 4..6 index into n = [0, 1, 2, 3, 4, 6, 8, 12]
@   0  the CPU starts TM1 (the baseline)
@   1  a 32-bit DMA0 IWRAM->TM1CNT starts TM1
@   2  a 16-bit DMA0 IWRAM->TM1CNT_H starts TM1
@   3  TM1 by the CPU; 32-bit DMA0 IWRAM->IWRAM
@   4  TM1 by the CPU; 32-bit DMA0 IWRAM->EWRAM
@   5  TM1 by the CPU; 32-bit DMA0 EWRAM->IWRAM
@   6  TM1 by the CPU; 16-bit DMA0 IWRAM->IWRAM
@   7  TM1 by the CPU; 32-bit DMA0 I/O (IE)->IWRAM
@ answer: TM1 as read after the NOPs
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    mov r3, #0x04000000
    mov r0, #0
    strh r0, [r3, #0xBA]
    str r0, [r3, #0x104]           @ TM1 off, reload 0
    and r1, r11, #7
    ldr r2, =srcs
    ldr r2, [r2, r1, lsl #2]
    str r2, [r3, #0xB0]
    ldr r2, =dsts
    ldr r2, [r2, r1, lsl #2]
    str r2, [r3, #0xB4]
    ldr r2, =ctls
    ldr r2, [r2, r1, lsl #2]
    str r0, [r3, #0xB8]
    ldr r4, =0x02004000
    ldr r5, =w32
    ldr r6, [r5]
    str r6, [r4]                   @ an EWRAM source word
    add r1, r3, #0x104             @ TM1
    add r3, r3, #0xB8              @ DMA0CNT
    mov r8, #0x00800000
    and r0, r11, #7                @ v
    and r7, r11, #0x70             @ n index * 16
    add r0, r0, r7, lsr #1         @ n index * 8 + v
    ldr r10, =bodies
    ldr r10, [r10, r0, lsl #2]
    mov lr, pc
    bx r10
    mov r3, #0x04000000
    mov r2, #0
    str r2, [r3, #0x104]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
    .align 2
w32: .word 0x00800000
w16: .word 0x00000080
iwdst: .space 16
srcs: .word 0, w32, w16, w32, w32, 0x02004000, w32, 0x04000200
dsts: .word 0, 0x04000104, 0x04000106, iwdst, 0x02004100, iwdst, iwdst, iwdst
ctls: .word 0, 0x84000001, 0x80000001, 0x84000001, 0x84000001, 0x84000001, 0x80000001, 0x84000001

bodies:
    .word b0_0
    .word b1_0
    .word b2_0
    .word b3_0
    .word b4_0
    .word b5_0
    .word b6_0
    .word b7_0
    .word b0_1
    .word b1_1
    .word b2_1
    .word b3_1
    .word b4_1
    .word b5_1
    .word b6_1
    .word b7_1
    .word b0_2
    .word b1_2
    .word b2_2
    .word b3_2
    .word b4_2
    .word b5_2
    .word b6_2
    .word b7_2
    .word b0_3
    .word b1_3
    .word b2_3
    .word b3_3
    .word b4_3
    .word b5_3
    .word b6_3
    .word b7_3
    .word b0_4
    .word b1_4
    .word b2_4
    .word b3_4
    .word b4_4
    .word b5_4
    .word b6_4
    .word b7_4
    .word b0_5
    .word b1_5
    .word b2_5
    .word b3_5
    .word b4_5
    .word b5_5
    .word b6_5
    .word b7_5
    .word b0_6
    .word b1_6
    .word b2_6
    .word b3_6
    .word b4_6
    .word b5_6
    .word b6_6
    .word b7_6
    .word b0_7
    .word b1_7
    .word b2_7
    .word b3_7
    .word b4_7
    .word b5_7
    .word b6_7
    .word b7_7
b0_0:
    str r8, [r1]
    ldrh r0, [r1]
    bx lr
b1_0:
    mov r0, r0
    str r2, [r3]
    ldrh r0, [r1]
    bx lr
b2_0:
    mov r0, r0
    str r2, [r3]
    ldrh r0, [r1]
    bx lr
b3_0:
    str r8, [r1]
    str r2, [r3]
    ldrh r0, [r1]
    bx lr
b4_0:
    str r8, [r1]
    str r2, [r3]
    ldrh r0, [r1]
    bx lr
b5_0:
    str r8, [r1]
    str r2, [r3]
    ldrh r0, [r1]
    bx lr
b6_0:
    str r8, [r1]
    str r2, [r3]
    ldrh r0, [r1]
    bx lr
b7_0:
    str r8, [r1]
    str r2, [r3]
    ldrh r0, [r1]
    bx lr
b0_1:
    str r8, [r1]
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b1_1:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b2_1:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b3_1:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b4_1:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b5_1:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b6_1:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b7_1:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b0_2:
    str r8, [r1]
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b1_2:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b2_2:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b3_2:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b4_2:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b5_2:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b6_2:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b7_2:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b0_3:
    str r8, [r1]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b1_3:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b2_3:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b3_3:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b4_3:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b5_3:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b6_3:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b7_3:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b0_4:
    str r8, [r1]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b1_4:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b2_4:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b3_4:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b4_4:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b5_4:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b6_4:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b7_4:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b0_5:
    str r8, [r1]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b1_5:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b2_5:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b3_5:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b4_5:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b5_5:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b6_5:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b7_5:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b0_6:
    str r8, [r1]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b1_6:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b2_6:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b3_6:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b4_6:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b5_6:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b6_6:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b7_6:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b0_7:
    str r8, [r1]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b1_7:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b2_7:
    mov r0, r0
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b3_7:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b4_7:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b5_7:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b6_7:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
b7_7:
    str r8, [r1]
    str r2, [r3]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1]
    bx lr
