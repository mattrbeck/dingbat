@ payload: a timer interrupt storm under a long DMA burst.
@
@ A timer overflowing every few cycles raises its IF bit thousands of times
@ while a DMA burst holds the CPU off the bus. On the console that is one
@ interrupt, taken once the burst is over; an emulator that books one piece
@ of work per overflow (a scheduler event per raise, say) can run out of
@ room partway through the burst. That is how a synchroniser for the timer
@ interrupt crashed four commercial games in this emulator while every test
@ ROM it was written for passed. This payload is that case with nothing else
@ in it.
@
@ TM0 overflows every P cycles with its interrupt enabled, TM1 counts every
@ cycle from one cycle after TM0's start, and (with N != 0) DMA3 copies N
@ words EWRAM -> EWRAM, started by the next instruction. The handler stops
@ TM0 as its first act and reads TM1, so the answer says when the interrupt
@ was taken and how many times.
@
@ r0 bits 0..15   N, DMA3 words (32-bit, immediate); 0: no DMA
@    bits 16..31  TM0's reload; P = 0x10000 - reload (0xFFFF: every cycle)
@ answer: bits 0..15  TM1 as the handler found it
@         bits 16..23 handler entries (0: never taken inside the watchdog)
@         bits 24..31 TM0 as the handler's stop left it, low byte
    .arm
    .text
    .global _start
.equ SRC, 0x02010000
.equ DST, 0x02020000

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
    str r2, [r12, #24]             @ the IRQ vector
    mrs r2, cpsr
    str r2, [r12, #28]             @ CPSR
    mov r0, #0
    strh r0, [r5, #8]              @ IME off while we set up
    adr r2, handler
    str r2, [r1]
    str r0, [r12]                  @ TM1 at entry
    str r0, [r12, #4]              @ entries
    str r0, [r12, #8]              @ TM0 after the stop
    add r1, r4, #0x100
    mov r2, #0x00800000
    str r2, [r1]                   @ TM0 started from 0 and stopped: a /1
    str r0, [r1]                   @ timer enabled over 0xFFFF (where the
                                   @ last run's stop may have left it)
                                   @ overflows at once
    str r0, [r1, #4]               @ TM1 stopped

    @ DMA3: SRC -> DST, N words, 32-bit, immediate, armed by the store below
    add r6, r4, #0xD4
    ldr r1, =SRC
    str r1, [r6]
    ldr r1, =DST
    str r1, [r6, #4]
    mov r10, r9, lsl #16
    movs r10, r10, lsr #16         @ N
    orrne r10, r10, #0x84000000    @ enable | 32-bit

    mov r0, #0x08
    strh r0, [r5]                  @ IE: TM0
    mvn r0, #0
    strh r0, [r5, #2]              @ IF: acknowledge everything
    mrs r0, cpsr
    bic r0, r0, #0x80
    msr cpsr_c, r0                 @ I clear
    mov r0, #1
    strh r0, [r5, #8]              @ IME

    mov r7, r9, lsr #16            @ TM0: reload, /1, interrupt, enable
    orr r7, r7, #0x00C00000
    mov r8, #0x00800000            @ TM1: 0, /1, enable
    add r1, r4, #0x100
    ldr r11, =0x00100000           @ watchdog: ~1M cycles
    stmia r1, {r7, r8}             @ TM0, then TM1 a cycle later
    strne r10, [r6, #8]            @ DMA3CNT (flags still from the movs)
1:  ldr r0, [r12, #4]
    cmp r0, #0
    bne 2f
    subs r11, r11, #1
    bne 1b
2:  mov r0, #0x100                 @ a while longer: a second entry would show
3:  subs r0, r0, #1
    bne 3b

    mov r0, #0
    strh r0, [r5, #8]              @ IME off
    add r1, r4, #0x100
    str r0, [r1]
    str r0, [r1, #4]
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
    and r1, r1, #0xFF
    orr r0, r0, r1, lsl #24
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg

@ Called by the BIOS's dispatcher, which has pushed r0-r3, r12 and lr.
handler:
    mov r0, #0x04000000
    add r1, r0, #0x100
    mov r2, #0
    strh r2, [r1, #2]              @ TM0 stopped, first thing
    ldrh r3, [r1, #4]              @ TM1
    ldr r2, =vars
    ldr r12, [r2, #4]
    cmp r12, #0
    streq r3, [r2]                 @ the first entry is the question
    ldreqh r3, [r1]
    streq r3, [r2, #8]
    add r12, r12, #1
    str r12, [r2, #4]
    add r0, r0, #0x200
    mov r1, #0x08
    strh r1, [r0, #2]              @ acknowledge TM0
    bx lr
    .ltorg
    .align 2
vars:
    .space 32
