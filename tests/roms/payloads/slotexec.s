@ payload: execute ONE opcode out of an empty cartridge slot, and time it
@
@ The link rig has no cartridge, so gamepak opcode timing looked unreachable
@ (docs/playtest-bugs.md section 12). It is not. slotfloat.s shows an empty
@ slot answers every NONSEQUENTIAL halfword read with addr >> 1 and every
@ SEQUENTIAL one with 0xFFFF, deterministically. So:
@
@   - branch to A and the CPU executes the opcode (A >> 1) & 0xFFFF, fetched
@     with a real nonsequential gamepak access at the WAITCNT in force;
@   - the next opcode is a sequential fetch, reads 0xFFFF, and 0xFFFF is the
@     Thumb BL suffix: pc = lr + 0xFFE. With lr aimed at a landing pad in
@     IWRAM, the float itself is the way home.
@
@ Wait states belong to the memory controller, not the cartridge (waitcnt.s:
@ hardware == both emulators with the slot empty), so this times a gamepak
@ fetch of any opcode we like, plus -- the part that matters -- whether the
@ fetch FOLLOWING it is charged as sequential or nonsequential. TM0 runs at
@ one count a cycle from just before the branch in to the landing pad; every
@ overhead is IWRAM code identical in all three machines, so rows compare
@ directly and row DIFFERENCES are gamepak cycles.
@
@ r0 on entry = the WAITCNT value to run under.
@ +0 + 8*i (h) TM0 at the landing pad for trial i, 0xFFFF = watchdog fired
@    +2     (h) sled count: the exit suffix executed was 0xFFFF - this
@    +4     (w) lr at the pad = address after the suffix, | 1
@ then the whole table again (every trial is run twice; they must agree)
@ The emulators need a ROM image with FFFF everywhere and A >> 1 at each A:
@ tools/hwlink/slotexec.py builds it.
    .arm
    .text
    .global _start
.equ RESULTS, 0x02008000
.equ SCRATCH, 0x03006000
.equ NTRIALS, 20

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
    add r1, r1, r5, lsl #3
    strh r6, [r1]
    strh r9, [r1, #2]
    str r8, [r1, #4]
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
    .word 0x08008006, 0, 0, SCRATCH                  @  0 4003 ands r3, r0
    .word 0x08008516, 0, 0, SCRATCH                  @  1 428B cmp r3, r1
    .word 0x0801A200, 0, 0, SCRATCH                  @  2 D100 bne, not taken
    .word 0x0801A0FE, 0, 0, SCRATCH                  @  3 D07F beq -> 2's D100
    .word 0x08019410, 0x10000000, 0, SCRATCH         @  4 CA08 ldmia, unmapped
    .word 0x08019410, SCRATCH, 0, SCRATCH            @  5 CA08 ldmia, IWRAM
    .word 0x08019410, 0x02010000, 0, SCRATCH         @  6 CA08 ldmia, EWRAM
    .word 0x0800D026, 0x10000000, 0, SCRATCH         @  7 6813 ldr r3,[r2] unmapped
    .word 0x0800D026, SCRATCH, 0, SCRATCH            @  8 6813 ldr, IWRAM
    .word 0x0800D026, 0x02010000, 0, SCRATCH         @  9 6813 ldr, EWRAM
    .word 0x0800D026, 0x08000100, 0, SCRATCH         @ 10 6813 ldr, gamepak
    .word 0x0800C0C6, 0, 0, SCRATCH                  @ 11 6063 str r3,[r4,#4] IWRAM
    .word 0x0800C0C6, 0, 0, 0x02010000               @ 12 6063 str, EWRAM
    .word 0x08008686, 0, 0, SCRATCH                  @ 13 4343 mul, 1 internal
    .word 0x08008686, 0, 0x00000100, SCRATCH         @ 14 4343 mul, 2 internal
    .word 0x08008686, 0, 0x00010000, SCRATCH         @ 15 4343 mul, 3 internal
    .word 0x08008686, 0, 0x01000000, SCRATCH         @ 16 4343 mul, 4 internal
    .word 0x0800D026, 0x04000000, 0, SCRATCH         @ 17 6813 ldr, I/O
    .word 0x0800D026, 0x05000000, 0, SCRATCH         @ 18 6813 ldr, palette
    .word 0x0800C0C6, 0, 0, 0x10000000               @ 19 6063 str, unmapped
