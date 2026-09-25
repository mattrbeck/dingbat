@ payload: how soon the interrupt an enable-at-0xFFFF raises is taken
@
@ tmrffff.s: a timer stopped at 0xFFFF and enabled again raises its IRQ
@ flag. alyosha irq/BL_IRQ_2 case d takes that interrupt and reads the
@ timer first thing in its handler, and reads one count lower on the
@ console than here. This times the same thing from IWRAM: TM0 stopped at
@ 0xFFFF (tmrffff's k = 10), IME on, then TM0CNT = 0x00C0FFE0 by a word
@ store, a NOP sled; the handler's first act reads TM0.
@
@   r0 bit 0  control: TM0 stopped at 0xFFFE instead (no interrupt at the
@             enable; the handler runs on the overflow 32 counts later)
@      bits 4..7  extra NOPs between the enable and... nothing: the sled
@             before the enable (the interrupt's phase against the sled)
@
@ answer: TM1 (started just before the sled) << 16 | TM0, both read by the
@ handler first thing (0xFFFFFFFF if it never ran).
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
    ldrh r8, [r5]                  @ IE, restored on the way out
    ldr r0, =0x03007FFC
    ldr r9, [r0]                   @ the IRQ vector, restored too
    adr r1, handler
    str r1, [r0]
    ldr r0, =result
    mvn r1, #0
    str r1, [r0]
    mov r0, #0
    str r0, [r4]
    ldr r0, =0x00800000            @ a known count first (tmrffff.s)
    str r0, [r4]
    mov r0, #0
    str r0, [r4]
    ldr r1, =0x0080FFF0            @ run from 0xFFF0 without an IRQ
    mov r2, #0
    tst r7, #1
    moveq r0, #53                  @ 63 - k NOPs skipped: k = 10 stops at FFFF
    movne r0, #54                  @ k = 9: FFFE
    str r1, [r4]
    add pc, pc, r0, lsl #2
    mov r0, r0
    .rept 64
    mov r0, r0
    .endr
    strh r2, [r4, #2]              @ stop
    mov r0, #8
    strh r0, [r5]                  @ IE = timer 0
    strh r0, [r5, #2]              @ IF.3 clear
    mov r0, #1
    strh r0, [r5, #8]              @ IME on
    ldr r2, =0x00C0FFE0
    ldr r0, =0x00800000
    str r0, [r4, #4]               @ TM1 from 0: the handler's clock
    and r0, r7, #0xF0
    mov r0, r0, lsr #4
    rsb r0, r0, #15
    add pc, pc, r0, lsl #2
    mov r0, r0
    .rept 16
    mov r0, r0
    .endr
    str r2, [r4]                   @ enable, IRQ, reload 0xFFE0
    .rept 96
    mov r0, r0
    .endr
    mov r0, #0
    strh r0, [r5, #8]              @ IME off
    str r0, [r4]
    str r0, [r4, #4]
    mov r0, #8
    strh r0, [r5, #2]
    strh r8, [r5]
    ldr r1, =0x03007FFC
    str r9, [r1]
    ldr r0, =result
    ldr r0, [r0]
    strh r6, [r5, #8]
    ldmfd sp!, {r4-r9, lr}
    bx lr

handler:
    ldrh r3, [r4]                  @ first act: the count
    ldrh r2, [r4, #4]              @ then when, by TM1
    orr r3, r3, r2, lsl #16
    ldr r0, =result
    str r3, [r0]
    mov r0, #0
    str r0, [r4]                   @ stop, so no second interrupt
    mov r0, #8
    strh r0, [r5, #2]
    bx lr
    .ltorg
    .align 2
result:
    .word 0
