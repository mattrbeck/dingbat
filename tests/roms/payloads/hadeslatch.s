@ payload: Hades-Tests dma-latch check 4, as compiled, with its NOP count
@
@ DMA1 is armed for sound FIFO A (repeat, 32-bit, source and destination
@ fixed) with 0xFEEDC0DE as its source word; TM0 is reloaded with 0xFFFF and
@ started at /1, so it overflows every cycle and FIFO A asks for DMA1 at
@ once. k NOPs later (the ROM has five) the CPU loads from unused I/O at
@ 0x04000FF0 and keeps what the open bus gave it. The ROM expects
@ 0xFEEDC0DE, the word DMA1 last moved; its source notes hardware and
@ emulators differ with and without the fifth NOP.
@
@ On an AGB SP (2026-09-25), with or without the FIFO reset: 0xFEEDC0DE at
@ k = 5 only -- the ROM's own count, so its expected value is the console's
@ -- and the prefetched opcode (0xE58D3008, `str r3, [sp, #8]`) at every
@ other k from 0 to 11. dingbat has the word at k = 8 only: its FIFO refill
@ burst comes 3 cycles late here (FIFO_DMA_REQUEST_DELAY 4 is a fit to
@ alyosha fifo_2; see the header there). Not a cycle law: dingbat fails it.
@
@ r0 bits 0..3 k (0..11)   bit 4: leave FIFO A as found (else reset it first)
@ answer: the loaded word
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    mov r4, #0x04000000
    ldrh r5, [r4, #0x84]           @ SOUNDCNT_X
    ldrh r6, [r4, #0x82]           @ SOUNDCNT_H
    tst r11, #0x10
    orreq r0, r6, #0x0800          @ FIFO A reset
    streqh r0, [r4, #0x82]
    and r0, r11, #0xF
    ldr r10, =bodies
    ldr r10, [r10, r0, lsl #2]
    mov lr, pc
    bx r10
    mov r4, #0x04000000
    strh r5, [r4, #0x84]
    orr r6, r6, #0x0800
    strh r6, [r4, #0x82]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
bodies:
    .word b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b11, b11, b11, b11

    .macro body n
    .align 2
b\n:
    push {lr}
    sub sp, sp, #20
    mov r3, #0
    str r3, [sp, #8]
    ldr r3, =0xFEEDC0DE
    str r3, [sp, #4]
    ldr r3, =0x04000084
    ldrh r3, [r3]
    lsl r3, r3, #16
    lsr r3, r3, #16
    ldr r2, =0x04000084
    orr r3, r3, #128
    lsl r3, r3, #16
    lsr r3, r3, #16
    strh r3, [r2]                  @ SOUNDCNT_X |= master enable
    ldr r3, =0x040000A0
    mov r2, #0
    str r2, [r3]                   @ FIFO_A = 0
    ldr r2, =0x040000BC
    add r3, sp, #4
    str r3, [r2]                   @ DMA1SAD
    ldr r3, =0x040000C0
    ldr r2, =0x040000A0
    str r2, [r3]                   @ DMA1DAD
    ldr r3, =0x040000C4
    ldr r2, =0xB7400001
    str r2, [r3]                   @ DMA1CNT: FIFO, repeat, 32-bit, fixed
    ldr r3, =0xFFFF
    ldr r1, =0x04000100
    ldr r2, =0x04000FF0
    mov r0, r3
    strh r0, [r1]                  @ TM0 reload 0xFFFF
    mov r0, #128
    strh r0, [r1, #2]              @ TM0 on
    .rept \n
    nop
    .endr
    ldr r0, [r2]
    mov r3, r0
    str r3, [sp, #8]
    ldr r3, =0x04000100
    mov r2, #0
    strh r2, [r3]
    ldr r3, =0x04000102
    mov r2, #0
    strh r2, [r3]
    ldr r3, =0x040000BC
    mov r2, #0
    str r2, [r3]
    ldr r3, =0x040000C0
    str r2, [r3]
    ldr r3, =0x040000C4
    str r2, [r3]
    ldr r0, [sp, #8]
    add sp, sp, #20
    pop {lr}
    bx lr
    .ltorg
    .endm
    body 0
    body 1
    body 2
    body 3
    body 4
    body 5
    body 6
    body 7
    body 8
    body 9
    body 10
    body 11
