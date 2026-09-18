@ payload: time 64 Thumb multiplies running from IWRAM.
@
@ This is prefetchbench's subject I on real hardware. It costs no cartridge
@ fetch at all, so it is the floor that any cartridge measurement of the same
@ block has to sit above: a prefetcher can hide the cost of fetching an
@ instruction, nothing can make one execute faster than its own internal
@ cycles. Both emulators say 333.
    .arm
    .text
    .global _start

.equ TM0CNT_L, 0x04000100
.equ TM0CNT_H, 0x04000102

_start:
    stmfd sp!, {r4-r7, lr}
    ldr r4, =TM0CNT_L
    ldr r5, =TM0CNT_H
    mov r0, #0
    strh r0, [r5]                  @ stop
    strh r0, [r4]                  @ count from zero
    adr r6, tblock
    add r6, r6, #1                 @ entered as Thumb
    mov r0, #0x80                  @ enable, no prescaler: one tick per cycle
    strh r0, [r5]
    mov lr, pc
    bx  r6
    ldrh r0, [r4]
    mov r1, #0
    strh r1, [r5]                  @ stop
    ldmfd sp!, {r4-r7, lr}
    bx  lr

    .align 2
    .thumb
tblock:
    mov r1, #7
    mov r2, #13
    .rept 64
    mul r1, r2
    .endr
    bx  lr
