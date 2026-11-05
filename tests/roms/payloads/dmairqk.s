@ dmairqk: dmairqv's immediate kinds (3..7) without the branch after the
@ trigger store: TM1 starts, the store arms the channel, k NOPs, then the
@ sled. Splits what dmairqv's d >= 2 cells share (the end interrupt a cycle
@ sooner than dmairq's NOP-sled cells): the trigger a word store (dmairqv)
@ or a CNT_H halfword store (dmairq), the burst landing in a branch's
@ refill (dmairqv) or in NOPs (dmairq).
@
@ r0: bits 0-15 WAITCNT, bit 16 = CNT_H halfword trigger (else the word
@     store), bits 24-27 k (0..11), bit 28 = sled in IWRAM (else the empty
@     slot), bits 29-31 kind (3..7, as dmairqv). The handler is dmairqv's.
@ Returns TM1 at the read | IF << 16 (0xFFFF = watchdog).
    .arm
    .text
    .global _start
    .include "fifoquiet.inc"
.equ SLED, 0x08010000

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str sp, [r12]
    str r0, [r12, #4]
    ldr r4, =0x04000200
    ldrh r1, [r4, #8]
    str r1, [r12, #8]
    ldrh r1, [r4]
    str r1, [r12, #12]
    ldrh r1, [r4, #4]
    str r1, [r12, #16]
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #20]
    mov r2, #0
    strh r2, [r4, #8]
    ldr r2, =handler
    str r2, [r1]
    mov r3, #0x04000000
    quiet
    mov r0, #0
    str r0, [r3, #0x80]
    str r0, [r3, #0x84]
    add r1, r3, #0xB0
    mov r2, #12
1:  str r0, [r1], #4               @ every DMA channel off
    subs r2, r2, #1
    bne 1b
    str r0, [r3, #0x100]
    str r0, [r3, #0x104]
    str r0, [r3, #0x10C]
    ldr r0, [r12, #4]
    mov r11, r0, lsr #29           @ kind
    ldr r10, =kinds
    add r10, r10, r11, lsl #4
    ldmia r10, {r5-r8}             @ channel base offset, SAD, DAD, CNT
    add r5, r5, r3                 @ r5 = DMAxSAD
    str r6, [r5]
    str r7, [r5, #4]
    cmp r11, #3
    blt fifo
    cmp r11, #6
    beq fifo                       @ kind 6 is immediate but on DMA1: armed below
    b armed
fifo:
    cmp r11, #3
    strlt r8, [r5, #8]             @ FIFO kinds: armed now, requested by TM0
armed:
    strh r0, [r4, #4]              @ WAITCNT under test
    mov r1, #0x40                  @ IE: watchdog + this channel
    ldr r2, =0x0100
    sub r6, r5, r3
    sub r6, r6, #0xB0
    mov r7, #0
2:  cmp r6, #0
    beq 3f
    sub r6, r6, #12
    add r7, r7, #1
    b 2b
3:  orr r1, r1, r2, lsl r7
    strh r1, [r4]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r1, =0x00C3FF00
    str r1, [r3, #0x10C]
    mov r1, #1
    strh r1, [r4, #8]
    mov r1, #0x80
    str r1, [r3, #0x84]
    tst r0, #0x10000000
    ldreq r10, =SLED
    ldrne r10, =iwsled
    mov r9, r0, lsr #24
    and r9, r9, #15
    rsb r9, r9, #15
    adr r6, dsled
    add r9, r6, r9, lsl #2
    ldr r1, =0x00800000
    cmp r11, #3
    blt tmfifo
    cmp r11, #6
    blt imm
    beq imm
imm:
    mov r7, r8, lsr #16            @ CNT_H for the halfword trigger
    strh r8, [r5, #8]              @ CNT_L (the count) now
    mov r9, r0, lsr #24
    and r9, r9, #15
    tst r0, #0x10000
    addne r9, r9, #12
    ldr r6, =ktab
    ldr pc, [r6, r9, lsl #2]
tmfifo:
    mov r2, r0, lsr #16
    and r2, r2, #0xFF
    rsb r2, r2, #0x10000
    orr r0, r2, #0x00C00000
    str r1, [r3, #0x104]           @ TM1 starts
    str r0, [r3, #0x100]           @ TM0 starts
    mov pc, r9
dsled:
    .rept 15
    nop
    .endr
    mov pc, r10

    .macro kbody k, half
kb_\half\()_\k:
    str r1, [r3, #0x104]           @ TM1 starts
    .if \half
    strh r7, [r5, #10]             @ the transfer starts (CNT_H)
    .else
    str r8, [r5, #8]               @ the transfer starts (CNT word)
    .endif
    .rept \k
    nop
    .endr
    mov pc, r10
    .endm
    .irp k, 0,1,2,3,4,5,6,7,8,9,10,11
    kbody \k, 0
    .endr
    .irp k, 0,1,2,3,4,5,6,7,8,9,10,11
    kbody \k, 1
    .endr
ktab:
    .irp k, 0,1,2,3,4,5,6,7,8,9,10,11
    .word kb_0_\k
    .endr
    .irp k, 0,1,2,3,4,5,6,7,8,9,10,11
    .word kb_1_\k
    .endr
    .ltorg
kinds:  @ channel register offset, SAD, DAD, CNT word
    .word 0xBC, 0x02000000, 0x040000A0, 0xF7400004
    .word 0xBC, 0x03006800, 0x040000A0, 0xF7400004
    .word 0xC8, 0x02000000, 0x040000A4, 0xF7400004
    .word 0xD4, 0x02000000, 0x040000A0, 0xC4000004
    .word 0xD4, 0x02000000, 0x02000400, 0xC4000004
    .word 0xB0, 0x02000000, 0x040000A0, 0xC4000004
    .word 0xBC, 0x02000000, 0x040000A0, 0xC4000004
    .word 0xD4, 0x03006800, 0x03006C00, 0xC4000004
iwsled:
    .rept 512
    nop
    .endr
    b iwsled

handler:                           @ IRQ mode, from the BIOS; r3 = 0x04000000
    mov r0, #0
    str r0, [r3, #0x208]
    ldr r7, [r3, #0x104]
    ldrh r6, [r4, #2]
    ldr sp, =0x03007FA0
    msr cpsr_c, #0x1F
    mov r7, r7, lsl #16
    mov r7, r7, lsr #16
    tst r6, #0x40
    ldrne r7, =0xFFFF
    orr r7, r7, r6, lsl #16
    mov r0, #0
    add r2, r3, #0x100
    strh r0, [r2, #2]
    mov r1, #200
1:  subs r1, r1, #1
    bne 1b
    add r1, r3, #0xB0
    mov r2, #12
2:  str r0, [r1], #4
    subs r2, r2, #1
    bne 2b
    mov r1, #50
1:  subs r1, r1, #1
    bne 1b
    str r0, [r3, #0x84]
    str r0, [r3, #0x104]
    str r0, [r3, #0x10C]
    ldr r12, =vars
    ldr r4, =0x04000200
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r1, [r12, #20]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #16]
    strh r1, [r4, #4]
    ldr r1, [r12, #12]
    strh r1, [r4]
    ldr r1, [r12, #8]
    strh r1, [r4, #8]
    ldr sp, [r12]
    mov r0, r7
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
vars:
    .space 32
