@ payload: a timer stopped near its overflow, then enabled again
@
@ alyosha timer/timer_disable test 2 enables a timer whose count stopped at
@ 0xFFFF and finds its interrupt flag set; its readme guesses the counter
@ "ticks one cycle before resetting". alyosha irq/BL_IRQ_2 case c stops a
@ timer at about the same count from a handler and case d then enables it,
@ and reads as if no interrupt came from that enable. This page walks the
@ stop across the overflow one cycle at a time and reports what the stop
@ left and what the enable raised. IWRAM, IME off, TM0 at prescaler 1.
@
@   r0 bits 0..5  k NOPs between the start and the stop
@      bits 8..15 the reload's low byte (0xFFxx)
@      bit  16    re-enable with a word store (reload 0 too) as
@                 timer_disable does, instead of a halfword control store
@      bit  17    no re-enable (control)
@
@ answer: frozen count << 16 | count 8 cycles after the re-enable << 4 & 0xFF0
@         | IF.3 after the re-enable << 1 | IF.3 after the stop
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r9, lr}
    mov r7, r0
    ldr r4, =0x04000100
    ldr r5, =0x04000200
    ldrh r6, [r5, #8]
    mov r0, #0
    strh r0, [r5, #8]              @ IME off
    str r0, [r4]                   @ TM0 off
    ldr r0, =0x00800000
    str r0, [r4]                   @ run from 0 and stop again: a count the
    mov r0, #0                     @ last cell left at 0xFFFF would raise
    str r0, [r4]                   @ IF.3 at this cell's start
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, #8
    strh r0, [r5, #2]              @ IF.3 clear
    and r1, r7, #0xFF00
    orr r1, r1, #0xFF0000
    mov r1, r1, lsr #8
    orr r1, r1, #0xFF00            @ reload 0xFFxx
    orr r1, r1, #0x00C00000        @ enable, IRQ, prescaler 1
    mov r2, #0
    mov r8, #0xC0
    mov r9, #0x00C00000
    and r0, r7, #0x3F
    rsb r0, r0, #63
    str r1, [r4]                   @ TM0 runs
    add pc, pc, r0, lsl #2
    mov r0, r0
    .rept 64
    mov r0, r0
    .endr
    strh r2, [r4, #2]              @ stop
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r3, [r4]                  @ frozen count
    ldrh r1, [r5, #2]
    and r1, r1, #8
    mov r1, r1, lsr #3             @ IF.3 after the stop
    mov r0, #8
    strh r0, [r5, #2]              @ IF.3 clear
    mov r0, r0
    mov r0, r0
    tst r7, #0x20000
    bne 3f
    tst r7, #0x10000
    streqh r8, [r4, #2]            @ re-enable, control only
    strne r9, [r4]                 @ re-enable, reload 0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r4]
    and r0, r0, #0xFF
    orr r1, r1, r0, lsl #4
    mov r0, r0
    mov r0, r0
    ldrh r0, [r5, #2]
    and r0, r0, #8
    orr r1, r1, r0, lsr #2         @ IF.3 after the re-enable
3:  mov r0, #0
    str r0, [r4]
    mov r0, #8
    strh r0, [r5, #2]
    orr r0, r1, r3, lsl #16
    strh r6, [r5, #8]
    ldmfd sp!, {r4-r9, lr}
    bx lr
    .ltorg
