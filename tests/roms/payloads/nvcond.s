@ nvtest: does an ARM opcode with condition 1111 (NV) run as a no-op on the
@ console?  r0 = 0: 16 real NOPs; r0 = 1: 16 words 0xFFFFxxxx / 0xFFFFFFFF.
@ Returns TM0 ticks across the block, or 0xFFFF if the TM3 watchdog fired
@ (an undefined-instruction trap re-executes forever under this BIOS).
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str sp, [r12]
    ldr r4, =0x04000200
    ldrh r1, [r4, #8]
    str r1, [r12, #12]
    ldrh r1, [r4]
    str r1, [r12, #16]
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #24]
    mov r2, #0
    strh r2, [r4, #8]
    adr r2, watchdog
    str r2, [r1]
    mov r2, #0x40
    strh r2, [r4]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r7, =0x04000100
    mov r1, #0
    str r1, [r7]
    str r1, [r7, #12]
    ldr r1, =0x00C3FF00
    str r1, [r7, #12]
    mov r1, #1
    strh r1, [r4, #8]
    mov r6, #0x80
    cmp r0, #0
    bne nv
    strh r6, [r7, #2]
    .rept 16
    nop
    .endr
    ldrh r0, [r7]
    b done
nv:
    strh r6, [r7, #2]
    .word 0xFFFF8000, 0xFFFFFFFF, 0xFFFF8002, 0xFFFFFFFF
    .word 0xFFFF8004, 0xFFFFFFFF, 0xFFFF8006, 0xFFFFFFFF
    .word 0xFFFF8008, 0xFFFFFFFF, 0xFFFF800A, 0xFFFFFFFF
    .word 0xFFFF800C, 0xFFFFFFFF, 0xFFFF800E, 0xFFFFFFFF
    ldrh r0, [r7]
    b done
watchdog:
    ldr r4, =0x04000200
    mov r1, #0
    strh r1, [r4, #8]
    ldr sp, =0x03007FA0
    msr cpsr_c, #0x1F
    ldr r0, =0xFFFF
done:
    ldr r12, =vars
    ldr r4, =0x04000200
    mov r1, #0
    strh r1, [r4, #8]
    ldr r7, =0x04000100
    str r1, [r7]
    str r1, [r7, #12]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r1, [r12, #24]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #16]
    strh r1, [r4]
    ldr r1, [r12, #12]
    strh r1, [r4, #8]
    ldr sp, [r12]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
vars:
    .space 32
