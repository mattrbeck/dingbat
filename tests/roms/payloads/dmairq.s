@ payload: when a running CPU takes a DMA's end-of-transfer interrupt.
@
@ TM1 (/1) starts, the next store arms DMA3 (N words EWRAM -> EWRAM,
@ 32-bit, immediate, IRQ at the end), then the CPU polls a flag in IWRAM
@ (variant 0) or EWRAM (1), or runs a NOP sled (2). The handler reads TM1
@ first thing and the interrupted address. On an AGB SP (tools/hwlink,
@ 2026-09-24), N = 1 to 64: the sled matched dingbat as it was; in the poll
@ loops -- where the burst takes the bus as a load ends and the load's
@ internal cycle runs under it -- the interrupt came one cycle and one
@ instruction later: its synchroniser counts from where the burst let go
@ of the bus, not from the CPU's clock with that cycle taken out
@ (dma.nim DMA_IRQ_FROM_BUS_END).
@
@ r0 bits 0..7 N (1..64), bits 8..9 variant
@ answer: bits 0..15 TM1 at entry, bits 16..23 entries, bits 24..31
@         interrupted address bits 2..9
    .arm
    .text
    .global _start
.equ SRC, 0x02010000
.equ DST, 0x02010200
.equ EFLAG, 0x02010400
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
    str r2, [r12, #24]
    mrs r2, cpsr
    str r2, [r12, #28]
    mov r0, #0
    strh r0, [r5, #8]              @ IME off
    ldr r2, =handler
    str r2, [r1]
    str r0, [r12]
    str r0, [r12, #4]
    str r0, [r12, #8]
    str r0, [r12, #12]             @ IWRAM flag
    ldr r1, =EFLAG
    str r0, [r1]                   @ EWRAM flag
    add r1, r4, #0x100
    str r0, [r1, #4]               @ TM1 off
    strh r0, [r4, #0xDE]           @ DMA3 off
    ldr r2, =SRC
    str r2, [r4, #0xD4]
    ldr r2, =DST
    str r2, [r4, #0xD8]
    and r2, r9, #0xFF
    strh r2, [r4, #0xDC]
    mov r0, #0x800
    strh r0, [r5]                  @ IE: DMA3
    mvn r0, #0
    strh r0, [r5, #2]
    mrs r0, cpsr
    bic r0, r0, #0x80
    msr cpsr_c, r0
    mov r0, #1
    strh r0, [r5, #8]              @ IME
    mov r8, #0x00800000            @ TM1 on
    ldr r10, =0xC400               @ DMA3: on, IRQ, 32-bit, immediate
    add r6, r12, #12               @ IWRAM flag
    ldr r7, =EFLAG
    and r0, r9, #0x300
    ldr r11, =bodies
    ldr r11, [r11, r0, lsr #6]
    ldr r3, =0x00100000            @ watchdog
    mov lr, pc
    bx r11
    mov r0, #0
    strh r0, [r5, #8]
    add r1, r4, #0x100
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
    mov r1, r1, lsr #2
    and r1, r1, #0xFF
    orr r0, r0, r1, lsl #24
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
bodies:
    .word b_iw, b_ew, b_nop, b_iw

    .align 2
b_iw:
    str r8, [r4, #0x104]           @ TM1 on
    strh r10, [r4, #0xDE]          @ DMA3 on
1:  ldr r0, [r6]
    cmp r0, #0
    bne 2f
    subs r3, r3, #1
    bne 1b
2:  bx lr
b_ew:
    str r8, [r4, #0x104]
    strh r10, [r4, #0xDE]
1:  ldr r0, [r7]
    cmp r0, #0
    bne 2f
    subs r3, r3, #1
    bne 1b
2:  bx lr
b_nop:
    str r8, [r4, #0x104]
    strh r10, [r4, #0xDE]
    .rept 300
    mov r0, r0
    .endr
    bx lr

@ Called by the BIOS's dispatcher (IRQ mode; lr_irq at [sp, #20]).
handler:
    mov r0, #0x04000000
    add r0, r0, #0x100
    ldrh r3, [r0, #4]              @ TM1, first thing
    ldr r2, =vars
    ldr r1, [r2, #4]
    cmp r1, #0
    streq r3, [r2]
    ldreq r3, [sp, #20]
    subeq r3, r3, #4
    streq r3, [r2, #8]
    add r1, r1, #1
    str r1, [r2, #4]
    mov r1, #1
    str r1, [r2, #12]              @ IWRAM flag
    ldr r3, =EFLAG
    str r1, [r3]
    mov r0, #0x04000000
    add r0, r0, #0x200
    mov r1, #0x800
    strh r1, [r0, #2]
    bx lr
    .ltorg
    .align 2
vars:
    .space 32
