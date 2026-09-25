@ payload: Hades-Tests dma-start-delay, its two checks as compiled
@
@ The ROM's test_01/test_02 bodies (ARM, as the published binary has them),
@ run from IWRAM or copied to EWRAM and run there. TM0 at /1 is started by a
@ store, DMA0 (16-bit, immediate, 1 unit) copies TM0CNT_L into a sample on
@ the stack, and the CPU reads TM0 again after the burst (test 1), or
@ disables DMA0 with the very next store and reads TM0 after that and after
@ polling the enable bit (test 2). WAITCNT's prefetch bit is cleared first,
@ as the ROM does for these kinds.
@
@ r0 bit 0: test 2 (else test 1)   bit 1: run from EWRAM (else IWRAM)
@ answer: sample0 | sample1 << 8 | sample2 << 16 (each < 0x100 here)
    .arm
    .text
    .global _start
.equ EW_COPY, 0x02010000
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    ldr r3, =0x04000204
    ldr r2, [r3]
    bic r2, r2, #0x4000
    str r2, [r3]
    tst r11, #1
    adreq r4, t1
    adreq r5, t1_end
    adrne r4, t2
    adrne r5, t2_end
    mov r10, r4
    tst r11, #2
    beq 2f
    ldr r6, =EW_COPY
    mov r10, r6
1:  ldr r0, [r4], #4
    str r0, [r6], #4
    cmp r4, r5
    blo 1b
2:  mov lr, pc
    bx r10
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg

    .align 2
t1:
    push {lr}
    sub sp, sp, #20
    ldr r2, =0xDEAD
    strh r2, [sp, #4]
    strh r2, [sp, #6]
    ldr r3, =0x04000102
    mov r2, #0
    strh r2, [r3]
    ldr r3, =0x04000100
    mov r2, #0
    strh r2, [r3]
    ldr r3, =0x04000102
    mov r2, #0x80
    strh r2, [r3]                  @ TM0 on
    ldr r3, =0x040000B0
    ldr r2, =0x04000100
    str r2, [r3]
    ldr r2, =0x040000B4
    add r3, sp, #4
    str r3, [r2]
    ldr r3, =0x040000B8
    mov r2, #0x80000001
    str r2, [r3]                   @ DMA0 on
1:  ldr r3, =0x040000B8
    ldr r3, [r3]
    cmp r3, #0
    blt 1b
    ldr r3, =0x04000100
    ldrh r3, [r3]
    lsl r3, r3, #16
    lsr r3, r3, #16
    strh r3, [sp, #6]
    ldr r3, =0x04000102
    mov r2, #0
    strh r2, [r3]
    ldr r3, =0x040000B8
    mov r2, #0
    str r2, [r3]
    ldrh r0, [sp, #4]
    ldrh r1, [sp, #6]
    and r0, r0, #0xFF
    and r1, r1, #0xFF
    orr r0, r0, r1, lsl #8
    add sp, sp, #20
    pop {lr}
    bx lr
    .ltorg
t1_end:

    .align 2
t2:
    push {lr}
    sub sp, sp, #20
    ldr r2, =0xDEAD
    strh r2, [sp]
    strh r2, [sp, #2]
    strh r2, [sp, #4]
    ldr r3, =0x04000102
    mov r2, #0
    strh r2, [r3]
    ldr r3, =0x04000100
    mov r2, #0
    strh r2, [r3]
    ldr r3, =0x04000102
    mov r2, #0x80
    strh r2, [r3]                  @ TM0 on
    ldr r3, =0x040000B0
    ldr r2, =0x04000100
    str r2, [r3]
    ldr r2, =0x040000B4
    mov r3, sp
    str r3, [r2]
    ldr r3, =0x040000B8
    mov r2, #0x80000001
    str r2, [r3]                   @ DMA0 on
    ldr r3, =0x040000B8
    mov r2, #0
    str r2, [r3]                   @ and off
    ldr r3, =0x04000100
    ldrh r3, [r3]
    lsl r3, r3, #16
    lsr r3, r3, #16
    strh r3, [sp, #2]
1:  ldr r3, =0x040000B8
    ldr r3, [r3]
    cmp r3, #0
    blt 1b
    ldr r3, =0x04000100
    ldrh r3, [r3]
    lsl r3, r3, #16
    lsr r3, r3, #16
    strh r3, [sp, #4]
    ldr r3, =0x04000102
    mov r2, #0
    strh r2, [r3]
    ldr r3, =0x040000B8
    mov r2, #0
    str r2, [r3]
    ldrh r0, [sp]
    ldrh r1, [sp, #2]
    ldrh r2, [sp, #4]
    and r0, r0, #0xFF
    and r1, r1, #0xFF
    and r2, r2, #0xFF
    orr r0, r0, r1, lsl #8
    orr r0, r0, r2, lsl #16
    add sp, sp, #20
    pop {lr}
    bx lr
    .ltorg
t2_end:
