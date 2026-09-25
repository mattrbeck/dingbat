@ payload: contmap -- which cycles of a line the renderer holds PRAM, VRAM
@ and OAM, one CPU access at a time.
@
@ One call measures 128 consecutive delays k. For each: halt on a V-count
@ match (a fixed cycle of line L), start TM0, wait exactly k cycles, make one
@ access, read TM0. The halfword stored for k is TM0 - k: a constant plus the
@ cycles the access waited. Lines L = 40, 43, ... 97 in turn (twenty a
@ frame), so with the OBJ scenes every one of them, and the line each fetches
@ OBJs for, is covered by the same sprites; a scene can name another first
@ line, and from line 150 on every measurement is on that one line. The
@ scenes (DISPCNT, BGxCNT, fine scroll, BLDCNT and an OAM arrangement) are
@ contscene.inc's.
@
@   r0 bits 0..10   first k
@      bit 11       measure that k alone and answer it in r0 (a law's form)
@      bits 12..15, 20..23  scene (contscene.inc)
@      bits 16..19  access: 0 ldrh PRAM  1 ldrh VRAM 06000000
@                   2 ldrh VRAM 06014000  3 ldrh OAM  4 ldrh IWRAM
@                   5 ldr VRAM 06000000   6 strh VRAM 06000000
@                   7 ldr VRAM 06014000   8 ldr PRAM  9 ldr OAM
@      bits 24..31  (emulator runs) the 256-byte slot of 0x02008000 to answer in
@ answer: 128 halfwords at 0x02008000; r0 = 0x600D (bit 11: the halfword).
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str r0, [r12, #0]              @ arg
    mov r4, #0x04000000
    add r5, r4, #0x200
    ldrh r1, [r5, #8]
    str r1, [r12, #4]              @ IME
    ldrh r1, [r5]
    str r1, [r12, #8]              @ IE
    ldrh r1, [r4, #4]
    str r1, [r12, #12]             @ DISPSTAT
    ldrh r1, [r4]
    str r1, [r12, #16]             @ DISPCNT
    mov r0, #0
    strh r0, [r5, #8]              @ IME off
    ldr r10, =0x04000100
    str r0, [r10]

    @ the scene: forced blank while OAM is written
    mov r0, #0x80
    strh r0, [r4]
    bl  scene_setup

    @ the access block
    ldr r0, [r12, #0]
    mov r0, r0, lsr #16
    and r0, r0, #15
    ldr r1, =ops
    ldr r9, [r1, r0, lsl #3]       @ code
    add r9, r9, r1
    add r1, r1, #4
    ldr r8, [r1, r0, lsl #3]       @ target
    str r9, [r12, #24]
    str r8, [r12, #28]

    mov r0, #0
    str r0, [r12, #32]             @ i
    ldr r0, [r12, #40]             @ the scene's first line
    str r0, [r12, #36]             @ line
    ldr r11, =0x00800000

next:
    ldr r0, [r12, #36]             @ line
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
    ldr r0, =0x7FF
    and r1, r1, r0
    ldr r0, [r12, #32]
    add r1, r1, r0                 @ k
    mov r6, r1, lsr #2
    add r6, r6, #1
    and r7, r1, #3
    rsb r7, r7, #3
    ldr r9, [r12, #24]
    ldr r8, [r12, #28]
    swi 0x020000
    str r11, [r10]                 @ TM0 from 0
1:  subs r6, r6, #1
    bne 1b
    add pc, pc, r7, lsl #2
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    bx  r9

op_ldrh:
    ldrh r1, [r8]
    ldrh r0, [r10]
    b   done
op_ldr:
    ldr r1, [r8]
    ldrh r0, [r10]
    b   done
op_strh:
    strh r1, [r8]
    ldrh r0, [r10]
    b   done

done:
    ldr r12, =vars
    ldr r1, [r12, #0]
    ldr r2, =0x7FF
    and r1, r1, r2
    ldr r2, [r12, #32]
    add r1, r1, r2                 @ k
    sub r0, r0, r1
    ldr r3, =0x02008000
    add r3, r3, r2, lsl #1
    ldrb r1, [r12, #3]             @ arg bits 24..31: output slot (256 bytes)
    add r3, r3, r1, lsl #8
    strh r0, [r3]
    str r3, [r12, #44]
    add r2, r2, #1
    str r2, [r12, #32]
    ldr r0, [r12, #36]
    ldr r1, [r12, #40]
    cmp r1, #150                   @ a first line from 150 on: that line only
    addlo r0, r0, #3
    add r1, r1, #60
    cmp r0, r1
    ldrge r0, [r12, #40]
    str r0, [r12, #36]
    ldr r1, [r12, #0]
    tst r1, #0x800                 @ bit 11: this k alone, answered in r0
    movne r1, #1
    moveq r1, #128
    cmp r2, r1
    blt next

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
    strh r1, [r4, #0x50]           @ BLDCNT
    ldr r0, =0x07000000            @ OBJs off again
    ldr r1, =0x00000200
    mov r2, #0
    mov r3, #128
1:  str r1, [r0], #4
    str r2, [r0], #4
    subs r3, r3, #1
    bne 1b
    ldr r1, [r12, #4]
    strh r1, [r5, #8]
    ldr r0, [r12, #0]
    tst r0, #0x800
    ldrne r0, [r12, #44]
    ldrneh r0, [r0]
    ldreq r0, =0x600D
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

    .align 2
    .align 2
ops:
    .word op_ldrh - ops, 0x05000000
    .word op_ldrh - ops, 0x06000000
    .word op_ldrh - ops, 0x06014000
    .word op_ldrh - ops, 0x07000000
    .word op_ldrh - ops, 0x03007000
    .word op_ldr - ops,  0x06000000
    .word op_strh - ops, 0x06000000
    .word op_ldr - ops,  0x06014000
    .word op_ldr - ops,  0x05000000
    .word op_ldr - ops,  0x07000000

    .include "contscene.inc"

    .align 2
vars:
    .space 64
