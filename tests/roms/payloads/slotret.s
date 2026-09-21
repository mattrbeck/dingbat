@ payload: what an EXCEPTION RETURN into gamepak Thumb code costs
@
@ The mGBA suite's BIOS timing rows measure a SWI called from the cartridge
@ as one number, entry plus return, so they cannot say how the two halves
@ split. `DMA Prefetch Break` can: its loop starts when VBlankIntrWait
@ returns, the SWI's entry was paid before the halt, and one cycle of the
@ return is a whole scanline of loop iterations (docs/playtest-bugs.md
@ section 24). vbwait.s checked that return into IWRAM. This checks it into
@ the gamepak region, with no cartridge, by the slotexec.s trick: the target
@ executes one opcode (A >> 1) and the floating 0xFFFF after it is a BL
@ suffix that branches to lr + 0xFFE -- the pad.
@
@ Four ways into the same two-instruction Thumb sequence, TM0 running from
@ just before the transfer to the pad:
@   0  bx r12            into the slot
@   1  movs pc, lr       into the slot   (SVC mode, SPSR = System | Thumb)
@   2  bx r12            into the same opcode in IWRAM
@   3  movs pc, lr       into the same opcode in IWRAM
@ (1 - 0) against (3 - 2) is the question: does an exception return pay
@ anything a branch does not, when the refill comes from the gamepak?
@
@ WAITCNT 0 only. +0 + 4*i (w) TM0 at the pad, i = 0..3, then the same again.
    .arm
    .text
    .global _start
.equ RESULTS, 0x02008000
.equ SLOT,    0x08004400           @ opcode 2200: mov r2, #0

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str sp, [r12]
    ldr r4, =0x04000200
    ldrh r1, [r4, #8]
    str r1, [r12, #12]
    ldrh r1, [r4]
    str r1, [r12, #16]
    ldrh r1, [r4, #4]
    str r1, [r12, #20]
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #24]
    mrs r2, cpsr
    str r2, [r12, #28]             @ the mode we were called in
    mov r2, #0
    strh r2, [r4, #8]
    adr r2, watchdog
    str r2, [r1]
    mov r2, #0x40
    strh r2, [r4]
    mov r2, #0
    strh r2, [r4, #4]              @ WAITCNT 0
    str r2, [r12, #4]

next:
    ldr r12, =vars
    ldr r6, [r12, #4]
    cmp r6, #8
    bge done
    ldr r4, =0x04000200
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r7, =0x04000100
    mov r1, #0
    str r1, [r7]
    str r1, [r7, #12]
    ldr r1, =0x00C3FF00            @ the watchdog
    str r1, [r7, #12]
    mov r1, #1
    strh r1, [r4, #8]

    and r6, r6, #3
    tst r6, #2
    ldreq r12, =(SLOT + 1)
    ldrne r12, =(stub + 1)
    msr cpsr_c, #0x1F              @ System: the mode the return lands in,
    ldr lr, =(land - 0xFFE)        @ whose lr is where the float goes
    mov r5, #0x80
    tst r6, #1
    beq 1f
    ldr r0, =vars                  @ an exception return needs a privileged
    ldr r0, [r0, #28]              @ mode to make it from; in User mode the
    and r0, r0, #0x1F              @ msr below would be ignored and the
    cmp r0, #0x10                  @ movs unpredictable, so say so instead
    ldreq r1, =0xEEEE
    ldreq r12, =vars
    ldreq r5, [r12, #4]
    beq store
    b by_return
1:
    strh r5, [r7, #2]              @ TM0 starts
    bx r12

by_return:
    msr cpsr_c, #0x13              @ Supervisor
    mov r0, #0x3F                  @ System, Thumb, interrupts on
    msr spsr_fsxc, r0
    bic lr, r12, #1                @ lr_svc = the target
    strh r5, [r7, #2]              @ TM0 starts
    movs pc, lr

    .thumb
    .align 2
stub:                              @ the slot's two halfwords, in IWRAM
    mov r2, #0
    ldr r3, =(land + 1)
    bx r3
    .align 2
    .ltorg
    .align 2
land:
    bx pc                          @ word-aligned, or silicon hangs
    nop
    .arm
    ldrh r1, [r7]
    ldr r12, =vars
    ldr r5, [r12, #4]
store:
    ldr r4, =RESULTS
    str r1, [r4, r5, lsl #2]
    add r5, r5, #1
    str r5, [r12, #4]
    b next

watchdog:
    ldr r4, =0x04000200
    mov r1, #0
    strh r1, [r4, #8]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr sp, =0x03007FA0
    msr cpsr_c, #0x1F
    ldr r12, =vars
    ldr sp, [r12]
    ldr r5, [r12, #4]
    ldr r1, =0xFFFF
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
    ldr r1, [r12, #28]
    msr cpsr_fsxc, r1              @ the mode we were called in, then its sp
    ldr sp, [r12]
    ldr r0, =0x534C5254            @ 'SLRT'
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg

vars:
    .space 32

table:
    .word 0x08004400, 0   @ 2200 mov r2, #0
