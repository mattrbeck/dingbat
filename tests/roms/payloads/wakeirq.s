@ payload: a halted CPU is woken by an interrupt it will take. What runs first?
@
@ vbwait.s found the console entering a wake handler 2 cycles later than we
@ do and leaving it 2 cycles sooner, the sum unchanged. One reading: the wake
@ and the interrupt are not the same instant, and whatever the CPU executes
@ between them it does not have to execute again afterwards. The handler can
@ see that directly -- the BIOS's dispatcher leaves the interrupted address
@ on the stack.
@
@ Parked on line 100 by a halt with IME clear (a fixed cycle of a fixed
@ line), TM1 started, then halted again through SWI 2 (HALTCNT answers only
@ to BIOS code) with a V-count match due on line 102.
@
@   r0 bit 4      IME clear: nothing is taken, and the first instruction
@                 after the SWI reads TM1 (W, the plain wake and return)
@
@      bit 5      the control: no halt. The interrupt lands in a sled of
@                 one-cycle NOPs and the handler sends the return to a
@                 second TM1 read, R -- the entry/return split of a RUNNING
@                 CPU, from the same clock.
@
@      bit 2      (with bit 5) the interrupt is a timer's overflow, not the
@                 V-count match: is the split the source's or the CPU's?
@
@      bit 1      (with bit 5) the handler's first act stops TM0, started one
@                 instruction after TM1; bits 16..31 are where it froze.
@
@ answer: bits 0..15 TM1 on entry to the handler (or W); bits 16..31 the low
@ half of the address the interrupt came back to -- a BIOS address: which of
@ Nintendo's instructions after the HALTCNT write had already run. With bit
@ 5, bits 16..31 are R; with bit 3 as well, the index of the NOP the
@ interrupt came back to; with bit 6 the handler returns into the sled, so R
@ is the sled's end and moves only with what the interrupt cost in all.
    .arm
    .text
    .global _start
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
    ldrh r1, [r4, #4]
    str r1, [r12, #24]             @ DISPSTAT
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #28]             @ the IRQ vector
    mov r0, #0
    strh r0, [r5, #8]
    adr r2, handler
    tst r9, #0x02
    adrne r2, handler_stop
    str r2, [r1]
    str r0, [r12]
    str r0, [r12, #4]
    str r0, [r12, #8]
    str r0, [r12, #12]

    ldr r11, =0x04000104
    str r0, [r11]
    mov r0, #100                   @ park on line 100
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x04
    strh r0, [r5]
    mvn r0, #0
    strh r0, [r5, #2]
    swi 0x020000
    ldr r0, =0x00800000
    str r0, [r11]                  @ TM1 runs from here
    str r0, [r11, #-4]             @ and TM0, for bit 1
    tst r9, #0x04
    beq 3f
    ldr r0, =0x00C0F6A0            @ bit 2: TM2 overflows 2400 cycles on, and
    str r0, [r11, #4]              @ interrupts instead of the V-count match
    mov r0, #0x20
    strh r0, [r5]
3:

    mov r0, #102
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mvn r0, #0
    strh r0, [r5, #2]
    mov r6, #0
    mov r7, #0
    mvn r8, #0                     @ a multiplier of four significant bytes
    ldr r10, =0x02008000
    tst r9, #0x10
    moveq r0, #1
    movne r0, #0
    strh r0, [r5, #8]              @ IME
    tst r9, #0x10
    bne plain
    tst r9, #0x20
    bne running
    swi 0x020000                   @ halt; the interrupt is taken on the wake
    b finish

running:
    adr r0, after
    tst r9, #0x40
    movne r0, #0                   @ bit 6: return into the sled instead
    str r0, [r12, #8]
    ldr pc, =sled
after:
    ldrh r1, [r11]                 @ R
    tst r9, #0x02
    ldrneh r1, [r11, #-4]          @ bit 1: TM0 as the handler froze it
    tst r9, #0x08
    beq 2f
    ldr r1, [r12, #4]              @ bit 3: which NOP was next, instead of R
    ldr r0, =sled
    sub r1, r1, r0
    sub r1, r1, #4
    mov r1, r1, lsr #2
2:
    mov r0, #0
    strh r0, [r5, #8]
    ldr r0, [r12]
    orr r0, r0, r1, lsl #16
    b leave

plain:
    swi 0x020000
    ldrh r0, [r11]                 @ W
    b leave

finish:
    mov r0, #0
    strh r0, [r5, #8]
    ldr r0, [r12]                  @ H
    ldr r1, [r12, #4]              @ the interrupted address + 4
    sub r1, r1, #4
    orr r0, r0, r1, lsl #16

leave:
    mov r1, #0
    str r1, [r11, #-4]
    strh r1, [r5, #8]
    str r1, [r11]
    str r1, [r11, #4]
    ldr r1, [r12, #24]
    strh r1, [r4, #4]
    mvn r1, #0
    strh r1, [r5, #2]
    ldr r1, [r12, #20]
    strh r1, [r5]
    ldr r1, [r12, #28]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #16]
    strh r1, [r5, #8]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg

@ Called by the BIOS's dispatcher, which has pushed r0-r3, r12 and lr.
handler:
    mov r0, #0x04000000
    add r1, r0, #0x100
    ldrh r1, [r1, #4]              @ H, first thing
    ldr r2, =vars
    ldr r3, [r2, #4]
    cmp r3, #0
    bne 1f                         @ only the first interrupt is the question
    str r1, [r2]
    ldr r1, [sp, #20]
    str r1, [r2, #4]
    ldr r1, [r2, #8]
    cmp r1, #0
    addne r1, r1, #4
    strne r1, [sp, #20]            @ the control returns to `after`
1:  add r0, r0, #0x200
    ldrh r1, [r0, #2]
    strh r1, [r0, #2]
    bx lr
    .ltorg

@ bit 1: the handler's first act is to stop TM0 -- what the mGBA suite's
@ timer rows do, and they pin the value it freezes at.
handler_stop:
    mov r0, #0x04000000
    add r1, r0, #0x100
    mov r2, #0
    strh r2, [r1, #2]
    ldr r2, =vars
    ldr r1, [sp, #20]
    str r1, [r2, #4]
    ldr r1, [r2, #8]
    cmp r1, #0
    addne r1, r1, #4
    strne r1, [sp, #20]
    add r0, r0, #0x200
    ldrh r1, [r0, #2]
    strh r1, [r0, #2]
    bx lr
    .ltorg
vars:
    .space 32

sled:
    .rept 2700
    mov r0, r0
    .endr
    b after
