@ payload: an immediate DMA armed by a store EXECUTED FROM THE GAMEPAK
@ REGION, with no cartridge (slotexec.s's float trick)
@
@ The opcode at A = 0x0800C0C6 is A >> 1 = 0x6063, `str r3, [r4, #4]`. With
@ r4 = DMA0CNT - 4 and r3 = an immediate enable, the store arms DMA0 (one
@ unit, TM0CNT_L -> IWRAM) from a gamepak-fetched opcode, and the fetch in
@ flight when its request comes due (two cycles after the store) is the
@ floating BL suffix's own gamepak fetch. TM0 starts just before the branch
@ in; the DMA's copy of TM0 says where the burst began, the pad's read where
@ the CPU came home. Row 1 is the control: the same store into IWRAM.
@
@ r0 on entry = WAITCNT (0 or 0x4000 only: see slotdma.s).
@ 16 bytes per trial at 0x02008000: +0 (h) TM0 at the pad, +2 (h) sled
@ count, +4 (w) lr at the pad, +8 (h) the DMA's TM0 sample (0xDEAD: none)
    .arm
    .text
    .global _start
.equ RESULTS, 0x02008000
.equ SCRATCH, 0x03006000
.equ NTRIALS, 3
.equ SAMPLE, 0x03006010

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str sp, [r12]                  @ the watchdog unwinds to here
    str r0, [r12, #8]
    ldr r4, =0x04000200
    ldrh r1, [r4, #8]
    str r1, [r12, #12]             @ IME
    ldrh r1, [r4]
    str r1, [r12, #16]             @ IE
    ldrh r1, [r4, #4]
    str r1, [r12, #20]             @ WAITCNT
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #24]             @ the IRQ vector
    mov r2, #0
    strh r2, [r4, #8]
    adr r2, watchdog
    str r2, [r1]
    mov r2, #0x40                  @ IE: timer 3 only
    strh r2, [r4]
    strh r0, [r4, #4]              @ WAITCNT under test
    mov r0, #0
    str r0, [r12, #4]              @ trial index

next:
    ldr r12, =vars
    ldr r6, [r12, #4]
    cmp r6, #(NTRIALS * 2)
    bge done
    ldr r4, =0x04000200
    mvn r1, #0
    strh r1, [r4, #2]              @ IF clear
    ldr r7, =0x04000100
    mov r1, #0
    str r1, [r7]                   @ TM0 off, reload 0
    str r1, [r7, #12]              @ TM3 off
    ldr r1, =0x00C3FF00            @ TM3: 256 x 1024 cycles, IRQ, enable
    str r1, [r7, #12]
    ldr r1, =0x040000B0
    mov r0, #0
    str r0, [r1, #8]               @ DMA0 off
    str r7, [r1]                   @ DMA0SAD = TM0CNT_L
    ldr r0, =SAMPLE
    str r0, [r1, #4]               @ DMA0DAD
    ldr r1, =0xDEAD
    strh r1, [r0]
    mov r1, #1
    strh r1, [r4, #8]              @ IME on: the watchdog is armed

    cmp r6, #NTRIALS
    subge r6, r6, #NTRIALS
    adr r8, table
    add r8, r8, r6, lsl #4
    ldr r12, [r8]                  @ A
    orr r12, r12, #1
    ldr r2, [r8, #4]
    ldr r3, [r8, #8]
    ldr r4, [r8, #12]
    ldr r0, =0xFFC0FFC0
    ldr r1, =0x40004000
    ldr r5, =(land - 0xFFE)
    mov r6, #0x80
    adr r9, go
    orr r9, r9, #1
    bx r9

    .thumb
go: mov lr, r5
    mov r5, #0
    cmp r7, r7                     @ Z = 1, C = 1
    strh r6, [r7, #2]              @ TM0 starts
    bx r12
    @ If the float is not quite 0xFFFF the suffix lands SHORT of the pad.
    @ A counted sled turns that into a number instead of a hang: r5 = how
    @ many halfwords short, so the executed suffix was 0xFFFF - r5.
    .rept 64
    add r5, #1
    .endr
    .align 2
land:
    ldrh r6, [r7]
    mov r8, lr                     @ the suffix's own address + 3
    bx pc                          @ MUST sit on a word boundary: silicon does
    nop                            @ not forgive a misaligned one (it hung)
    .arm
    ldr r12, =vars
    mov r9, r5
    ldr r5, [r12, #4]
store:
    ldr r1, =RESULTS
    add r1, r1, r5, lsl #4
    strh r6, [r1]
    strh r9, [r1, #2]
    str r8, [r1, #4]
    ldr r0, =SAMPLE
    ldrh r0, [r0]
    strh r0, [r1, #8]
    ldr r0, =0x040000B8
    mov r2, #0
    str r2, [r0]                   @ DMA0 off
    add r5, r5, #1
    str r5, [r12, #4]
    b next

watchdog:                          @ IRQ mode, called by the BIOS
    ldr r4, =0x04000200
    mov r1, #0
    strh r1, [r4, #8]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr sp, =0x03007FA0            @ drop the BIOS's frame
    msr cpsr_c, #0x1F              @ system mode, ARM
    ldr r12, =vars
    ldr sp, [r12]
    ldr r5, [r12, #4]
    ldr r6, =0xFFFF
    mov r9, r6
    mov r8, #0
    b store

done:
    ldr r4, =0x04000200
    mov r1, #0
    strh r1, [r4, #8]
    ldr r7, =0x04000100
    str r1, [r7]
    str r1, [r7, #12]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r1, [r12, #24]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #20]
    strh r1, [r4, #4]
    ldr r1, [r12, #16]
    strh r1, [r4]
    ldr r1, [r12, #12]
    strh r1, [r4, #8]
    ldr sp, [r12]
    ldr r0, =0x534C4558            @ 'SLEX'
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg

vars:
    .space 32

@ A, r2, r3, r4. The opcode is A >> 1, so the comment IS the address.
table:
    .word 0x0800C0C6, 0, 0x80000001, 0x040000B4      @  0 6063 str -> DMA0CNT, 16-bit x1
    .word 0x0800C0C6, 0, 0x80000001, SCRATCH         @  1 6063 str -> IWRAM (control)
    .word 0x0800C0C6, 0, 0x84000001, 0x040000B4      @  2 6063 str -> DMA0CNT, 32-bit x1
