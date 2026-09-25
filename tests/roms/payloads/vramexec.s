@ payload: vramexec -- what code fetched from PRAM, VRAM and OAM costs, with
@ the renderer off (forced blank), against the same block in IWRAM and EWRAM.
@
@ The block (16 copies of one instruction, then `bx lr`) is copied to the
@ region and called from IWRAM between a TM0 start and a TM0 read.
@
@   r0 bits 0..3  block: 0 ARM nop   1 ARM ldrh [IWRAM]   2 ARM ldr [IWRAM]
@                 3 ARM ldrh [VRAM 06000000]   4 ARM mul (one internal cycle)
@                 5 ARM str [IWRAM]  6 Thumb nop  7 Thumb ldrh [IWRAM]
@                 8 ARM ldrh [PRAM]  9 ARM ldr [VRAM 06000000]
@                 A ARM ldm {r3} [IWRAM]  B Thumb ldr [IWRAM]
@      bit 8      the timed call made from EWRAM (0x02020000), not IWRAM
@      bits 4..6  where: 0 IWRAM  1 EWRAM  2 VRAM 06014000  3 VRAM 06000000
@                 4 PRAM  5 OAM
@ answer: TM0 at the read.
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r9, r0
    mov r4, #0x04000000
    ldrh r11, [r4]
    mov r0, #0x80                  @ forced blank
    strh r0, [r4]
    ldr r10, =0x04000100
    mov r0, #0
    str r0, [r10]
    @ source block
    and r0, r9, #15
    adr r1, blocks
    add r1, r1, r0, lsl #3
    ldr r2, [r1]                   @ the instruction
    ldr r3, [r1, #4]               @ 1 = Thumb
    and r0, r9, #0x70
    adr r1, wheres
    ldr r5, [r1, r0, lsr #2]       @ destination
    mov r6, r5
    cmp r3, #0
    bne thumb_copy
    mov r0, #16
1:  str r2, [r6], #4
    subs r0, r0, #1
    bne 1b
    ldr r2, =0xE12FFF1E            @ bx lr
    str r2, [r6], #4
    b   copied
thumb_copy:
    mov r0, #8
    orr r2, r2, r2, lsl #16
1:  str r2, [r6], #4
    subs r0, r0, #1
    bne 1b
    ldr r2, =0x46C04770            @ bx lr; nop
    str r2, [r6], #4
    orr r5, r5, #1
copied:
    ldr r2, =0x03007000            @ data address for IWRAM loads
    and r0, r9, #15
    cmp r0, #3
    cmpne r0, #9
    ldreq r2, =0x06000000
    cmp r0, #8
    ldreq r2, =0x05000000
    mov r3, #3
    ldr r8, =0x00800000
    tst r9, #0x100
    bne from_ewram
    str r8, [r10]
    mov lr, pc
    bx  r5
    ldrh r0, [r10]
    b   measured
from_ewram:                        @ bit 8: the call made from EWRAM
    adr r0, tramp
    ldr r1, =0x02020000
    mov r6, #5
1:  ldr r7, [r0], #4
    str r7, [r1], #4
    subs r6, r6, #1
    bne 1b
    adr r9, measured_e
    ldr r0, =0x02020000
    bx  r0
measured_e:
measured:
    mov r1, #0
    str r1, [r10]
    strh r11, [r4]
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

    .align 2
tramp:
    str r8, [r10]
    mov lr, pc
    bx  r5
    ldrh r0, [r10]
    bx  r9

    .align 2
blocks:
    .word 0xE1A00000, 0            @ mov r0, r0
    .word 0xE1D230B0, 0            @ ldrh r3, [r2]
    .word 0xE5923000, 0            @ ldr r3, [r2]
    .word 0xE1D230B0, 0            @ ldrh r3, [r2] (VRAM)
    .word 0xE0010393, 0            @ mul r1, r3, r3
    .word 0xE5823000, 0            @ str r3, [r2]
    .word 0x46C0, 1                @ Thumb mov r8, r8
    .word 0x8813, 1                @ Thumb ldrh r3, [r2]
    .word 0xE1D230B0, 0            @ ldrh r3, [r2] (PRAM)
    .word 0xE5923000, 0            @ ldr r3, [r2] (VRAM)
    .word 0xE8920008, 0            @ ldmia r2, {r3}
    .word 0x6813, 1                @ Thumb ldr r3, [r2]
wheres:
    .word 0x03004000, 0x02010000, 0x06014000, 0x06000000
    .word 0x05000000, 0x07000000, 0x03004000, 0x03004000
