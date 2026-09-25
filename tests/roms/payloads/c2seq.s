@ payload: c2seq -- gbaedge CONTEND2's sixteen reads as a sweepable sentence.
@
@ contmap.s's scenes (same table, same OAM groups), but instead of one
@ access: sixteen `ldrh` from one address with seven NOPs after each (the
@ ten-cycle period the cartridge loop has), started k cycles after a
@ V-count-40 wake. Answer: TM0 at the end, less k.
@
@   r0 bits 0..11   k
@      bits 12..15, 20..23  scene (contmap.s)
@      bits 16..19  0 PRAM  1 VRAM 06000000  2 VRAM 06014000  3 OAM  4 IWRAM
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str r0, [r12, #0]
    mov r4, #0x04000000
    add r5, r4, #0x200
    ldrh r1, [r5, #8]
    str r1, [r12, #4]
    ldrh r1, [r5]
    str r1, [r12, #8]
    ldrh r1, [r4, #4]
    str r1, [r12, #12]
    ldrh r1, [r4]
    str r1, [r12, #16]
    mov r0, #0
    strh r0, [r5, #8]
    ldr r10, =0x04000100
    str r0, [r10]
    mov r0, #0x80
    strh r0, [r4]
    bl  scene_setup

    ldr r0, [r12, #0]
    mov r0, r0, lsr #16
    and r0, r0, #15
    ldr r1, =targets
    ldr r8, [r1, r0, lsl #2]
    mov r0, #40
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x04
    strh r0, [r5]
    mvn r0, #0
    strh r0, [r5, #2]
    mov r0, #0
    str r0, [r10]
    ldr r1, [r12, #0]
    ldr r0, =0xFFF
    and r1, r1, r0
    mov r6, r1, lsr #2
    add r6, r6, #1
    and r7, r1, #3
    rsb r7, r7, #3
    ldr r11, =0x00800000
    swi 0x020000
    str r11, [r10]
1:  subs r6, r6, #1
    bne 1b
    add pc, pc, r7, lsl #2
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    .rept 16
    ldrh r3, [r8]
    .rept 7
    mov r0, r0
    .endr
    .endr
    ldrh r0, [r10]
    ldr r12, =vars
    ldr r1, [r12, #0]
    ldr r2, =0xFFF
    and r1, r1, r2
    sub r9, r0, r1

    mov r0, #0
    strh r0, [r5, #8]
    str r0, [r10]
    ldr r1, [r12, #12]
    strh r1, [r4, #4]
    mvn r1, #0
    strh r1, [r5, #2]
    ldr r1, [r12, #8]
    strh r1, [r5]
    ldr r1, [r12, #16]
    strh r1, [r4]
    mov r1, #0
    strh r1, [r4, #0x50]
    ldr r0, =0x07000000
    ldr r1, =0x00000200
    mov r2, #0
    mov r3, #128
1:  str r1, [r0], #4
    str r2, [r0], #4
    subs r3, r3, #1
    bne 1b
    ldr r1, [r12, #4]
    strh r1, [r5, #8]
    mov r0, r9
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

    .align 2
targets:
    .word 0x05000000, 0x06000000, 0x06014000, 0x07000000, 0x03007000

    .include "contscene.inc"

    .align 2
vars:
    .space 64
