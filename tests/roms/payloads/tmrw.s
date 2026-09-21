@ payload: a timer read against a timer stop, in straight-line code
@
@ wakeirq.s found a timer READ as an interrupt handler's first access one
@ lower on the console than here, while a timer STOP written from the same
@ place froze at the same value. Either reads and stops disagree everywhere
@ or something about that moment is special. This is the everywhere case:
@ IWRAM, no interrupts, TM0 started, r0 NOPs, read, three NOPs, stop, read
@ the frozen value.
@
@   r0 bits 0..3  NOPs before the first read
@      bit  4     the first read is a word read of TM0CNT (L and H together)
@      bit  5     a `bx` to the next instruction comes before the first read
@                 (a pipeline refill, as an exception entry or return leaves)
@
@ answer: first read << 16 | frozen value.
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r7, lr}
    mov r7, r0
    ldr r4, =0x04000100
    ldr r5, =0x04000208
    ldrh r6, [r5]
    mov r0, #0
    strh r0, [r5]                  @ IME off
    str r0, [r4]
    ldr r1, =0x00800000
    mov r2, #0
    adr r3, 2f
    and r0, r7, #0x0F
    rsb r0, r0, #15
    str r1, [r4]                   @ TM0 runs
    add pc, pc, r0, lsl #2
    mov r0, r0
    .rept 16
    mov r0, r0
    .endr
    tst r7, #0x20
    bxne r3
2:  tst r7, #0x10
    ldreqh r0, [r4]
    ldrne r0, [r4]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    strh r2, [r4, #2]              @ stop
    mov r0, r0, lsl #16
    ldrh r1, [r4]
    orr r0, r0, r1
    strh r6, [r5]
    ldmfd sp!, {r4-r7, lr}
    bx lr
