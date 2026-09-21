@ payload: an H-blank DMA against every phase of an instruction -- when does
@ it run, and what does the CPU pay?
@
@ Two things were known from pages that could not pin them: the grant waits
@ for the bus access in flight (hdmastamp.s, anchored on a poll), and a DMA
@ requested in a load's data cycle costs the CPU a cycle less (slotdma.s, one
@ phase of one instruction). This page has the entry breakram.s found
@ reliable: parked on a line by a halt with IME clear, so the CPU resumes on
@ a cycle the PPU chose; both timers started; a counted spin to just short of
@ the H-blank; a sled of k one-cycle NOPs; then a long run of ONE kind of
@ instruction, with a one-halfword H-blank DMA whose own write freezes TM1.
@
@   r0 bits 0..3  k + 1 NOPs
@      bits 4..5  the run: 0 multiplies (1 fetch + 4 internal)
@                          1 loads from EWRAM (1 fetch + 6 data + 1 internal)
@                          2 loads from IWRAM (1 + 1 + 1)
@                          3 NOPs
@      bit  7     no DMA (the control: T is then the program's own length)
@
@ answer: T << 16 | D. T = TM0 read after the run; T less the control's T is
@ what the DMA cost the CPU at that phase. D = TM1 as the DMA froze it: flat
@ in k if the grant waits for nothing, a sawtooth if it waits for the access.
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
    mov r0, #0
    strh r0, [r5, #8]
    str r0, [r12]                  @ the halfword the DMA moves
    ldr r10, =0x04000100
    str r0, [r10]
    str r0, [r10, #4]
    ldr r8, =0x040000B0
    str r0, [r8, #8]
    str r12, [r8]                  @ DMA0: vars -> TM1CNT_H
    ldr r0, =0x04000106
    str r0, [r8, #4]

    mov r0, #50                    @ park on line 50
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x04
    strh r0, [r5]
    mvn r0, #0
    strh r0, [r5, #2]

    ldr r2, =0x12345678            @ a multiplier of four significant bytes
    mov r3, #3
    ldr r11, =0x02008000
    ldr r6, =0x00800000
    ldr r1, =0xA1400001            @ enable, H-blank, 16-bit, both fixed, 1
    tst r9, #0x80
    movne r1, #0
    and r0, r9, #0x30
    adr r7, run_mul
    cmp r0, #0x10
    adreq r7, run_ewram
    cmp r0, #0x20
    adreq r7, run_iwram
    cmp r0, #0x30
    ldreq r7, =run_nop

    swi 0x020000
    str r6, [r10]                  @ TM0
    str r6, [r10, #4]              @ TM1
    str r1, [r8, #8]               @ DMA0 armed for this line's H-blank
    mov r0, #205
1:  subs r0, r0, #1
    bne 1b
    and r0, r9, #0x0F
    rsb r0, r0, #15
    add pc, pc, r0, lsl #2
    mov r0, r0
    .rept 16
    mov r0, r0
    .endr
    bx r7

run_mul:
    .rept 64
    mul r1, r3, r2
    .endr
    ldrh r1, [r10]
    b collect

run_ewram:
    .rept 40
    ldr r1, [r11]
    .endr
    ldrh r1, [r10]
    b collect

run_iwram:
    .rept 80
    ldr r1, [r12, #4]
    .endr
    ldrh r1, [r10]
    b collect
    .ltorg

run_nop:
    .rept 256
    mov r0, r0
    .endr
    ldrh r1, [r10]

collect:
    ldrh r2, [r10, #4]             @ D
    mov r0, r1, lsl #16
    orr r0, r0, r2
    mov r1, #0
    str r1, [r8, #8]
    str r1, [r10]
    str r1, [r10, #4]
    ldr r1, [r12, #24]
    strh r1, [r4, #4]
    mvn r1, #0
    strh r1, [r5, #2]
    ldr r1, [r12, #20]
    strh r1, [r5]
    ldr r1, [r12, #16]
    strh r1, [r5, #8]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
vars:
    .space 32
