@ payload: a timer interrupt raised inside a DMA3 burst, with a sound DMA
@ armed and idle or not.
@
@ TM0 (/1, IRQ) starts with reload R, TM1 (/1) a cycle later, and the next
@ store arms DMA3 (16 words EWRAM -> EWRAM, 32-bit, immediate: about 200
@ cycles). With variant bit 0, DMA1 is first armed for sound FIFO A (start
@ timing 3, repeat) with the sound master enable off, so it never requests
@ a transfer. With bit 1, the instruction after the DMA3 store acknowledges
@ TM0's IF bit. The handler reads TM1 first thing, then IF.
@
@ An idle channel armed on a hardware trigger changes nothing on the
@ console; in dingbat it makes DMA3's burst preemptible, so the burst's
@ transfer loop dispatches TM0's overflow while the burst still runs. That
@ raise used to be pushed back by the whole burst, not counted from its
@ end, and the stale IE & IF sample it held came out later as an interrupt
@ with no source (dma.nim; Boktai 2 - Solar Boy Django).
@
@ r0 bits 0..15 R, bits 16..17 variant
@ answer: bits 0..15  TM1 at handler entry
@         bits 16..23 handler entries
@         bit 24      IF bit 3 (TM0) at handler entry
    .arm
    .text
    .global _start
.equ SRC, 0x02010000
.equ DST, 0x02010100
.equ FSRC, 0x02010200
_start:
    stmfd sp!, {r4-r11, lr}
    mov r9, r0
    mov r4, #0x04000000
    add r5, r4, #0x200
    ldr r12, =vars
    ldrh r1, [r5, #8]
    str r1, [r12, #16]             @ IME
    ldrh r1, [r5]
    str r1, [r12, #20]             @ IE
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #24]             @ vector
    mrs r2, cpsr
    str r2, [r12, #28]
    mov r0, #0
    strh r0, [r5, #8]              @ IME off
    adr r2, handler
    str r2, [r1]
    str r0, [r12]
    str r0, [r12, #4]
    str r0, [r12, #8]
    add r1, r4, #0x100
    mov r2, #0x00800000
    str r2, [r1]                   @ TM0 from 0, stopped (count reset)
    str r0, [r1]
    str r0, [r1, #4]
    strh r0, [r4, #0xC6]           @ DMA1 off
    strh r0, [r4, #0xDE]           @ DMA3 off
    strh r0, [r4, #0x84]           @ sound master off: the FIFOs request nothing
    ldr r2, =SRC
    str r2, [r4, #0xD4]
    ldr r2, =DST
    str r2, [r4, #0xD8]
    tst r9, #0x10000
    beq 1f
    ldr r2, =FSRC
    str r2, [r4, #0xBC]            @ DMA1SAD
    add r2, r4, #0xA0
    str r2, [r4, #0xC0]            @ DMA1DAD = FIFO A
    ldr r2, =0xB600
    strh r2, [r4, #0xC6]           @ DMA1: on, sound FIFO, 32-bit, repeat
1:  mov r0, #0x08
    strh r0, [r5]                  @ IE: TM0
    mvn r0, #0
    strh r0, [r5, #2]
    mrs r0, cpsr
    bic r0, r0, #0x80
    msr cpsr_c, r0
    mov r0, #1
    strh r0, [r5, #8]              @ IME
    mov r7, r9, lsl #16
    mov r7, r7, lsr #16
    orr r7, r7, #0x00C00000        @ TM0: reload, /1, IRQ, on
    mov r8, #0x00800000            @ TM1: /1, on
    ldr r10, =0x84000010           @ DMA3: on, 32-bit, immediate, 16 words
    mov r3, #0x08
    add r1, r4, #0x100
    and r0, r9, #0x20000
    ldr r11, =bodies
    ldr r11, [r11, r0, lsr #15]
    mov lr, pc
    bx r11
    mov r0, #0x100
3:  subs r0, r0, #1
    bne 3b
    mov r0, #0
    strh r0, [r5, #8]
    add r1, r4, #0x100
    str r0, [r1]
    str r0, [r1, #4]
    strh r0, [r4, #0xC6]           @ DMA1 off
    ldr r1, [r12, #20]
    strh r1, [r5]
    mvn r1, #0
    strh r1, [r5, #2]
    ldr r1, [r12, #24]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #28]
    msr cpsr_c, r1
    ldr r1, [r12, #16]
    strh r1, [r5, #8]
    ldr r0, [r12]
    mov r0, r0, lsl #16
    mov r0, r0, lsr #16
    ldr r1, [r12, #4]
    and r1, r1, #0xFF
    orr r0, r0, r1, lsl #16
    ldr r1, [r12, #8]
    tst r1, #0x08
    orrne r0, r0, #0x01000000
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
bodies:
    .word b_plain, b_ack

    .align 2
b_plain:
    stmia r1, {r7, r8}             @ TM0, then TM1
    str r10, [r4, #0xDC]           @ DMA3
    mov r0, r0
    .rept 48
    mov r0, r0
    .endr
    bx lr
b_ack:
    stmia r1, {r7, r8}
    str r10, [r4, #0xDC]
    strh r3, [r5, #2]              @ IF: acknowledge TM0
    .rept 48
    mov r0, r0
    .endr
    bx lr

@ Called by the BIOS's dispatcher (IRQ mode, sp = IRQ stack holding r0-r3,
@ r12, lr_irq).
handler:
    mov r0, #0x04000000
    add r0, r0, #0x100
    ldrh r3, [r0, #4]              @ TM1, first thing
    mov r2, #0
    strh r2, [r0, #2]              @ TM0 off
    add r0, r0, #0x100
    ldrh r1, [r0, #2]              @ IF
    ldr r2, =vars
    ldr r0, [r2, #4]
    cmp r0, #0
    streq r3, [r2]
    streq r1, [r2, #8]
    add r0, r0, #1
    str r0, [r2, #4]
    mov r0, #0x04000000
    add r0, r0, #0x200
    mov r1, #0x08
    strh r1, [r0, #2]
    bx lr
    .ltorg
    .align 2
vars:
    .space 32
