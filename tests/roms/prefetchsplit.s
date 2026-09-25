@ prefetchsplit.s — three prefetcher rules, each split out of the alyosha
@ row that implied it, for a cartridge run.
@
@ alyosha prefetcher/prefetcher_branch_thumb_arm_3 and prefetcher/
@ bounday_test_1 are green in dingbat on three rules read off their sources.
@ Each row checks a SUM, and two of the rules were chosen by which term of
@ the sum they explain; these cases take the terms apart. Everything here
@ runs from the gamepak with the prefetcher on, which the link rig (a
@ multiboot payload, empty slot) cannot reach: this is a flashcart ROM.
@
@   A  A branch to the halfword the prefetcher reads next, with nothing
@      buffered but the prefetcher running since the CPU's own last access,
@      meets it at S (S+S refill) rather than N+S. dingbat had this for
@      Thumb-state branches only (prefetcher_branch_thumb_4); thumb_arm_3's
@      first check reads 2 high without it for the ARM `bx` into Thumb that
@      opens the test. A1 is that `bx` (target = head), A2 the same with the
@      target one word further (a plain flush), A3/A4 the ARM-to-ARM pair.
@      Rule (WS0 3/1, S16 = 2): A2 - A1 = 2 and A4 - A3 = 2. Without it,
@      both differences are 0.
@   B  A Thumb `bx pc` at a word + 6 leaves the ARM PC at a word + 10,
@      bit 1 set. Rule: the word fetched is the aligned one, the PC
@      keeps the bit (B*.2 = PC & 3), and an ARM fetch after cycles off the
@      gamepak is never served from the buffer (the prefetcher's halfwords
@      are the aligned ones): the second of two back-to-back I/O loads pays
@      N32 (6) where the aligned control pays 2. Rule: (B1.1 - B1.0) -
@      (B2.1 - B2.0) = 4, B1.2 = 2, B2.2 = 0.
@   C  The first halfword of a 128 KiB block. C1 is bounday_test_1's own
@      code at its own address (0x0801FFE8), C2 the same code where no
@      boundary is crossed. Rule: C1 - C2 = 8 (the boundary halfword is the
@      CPU's own nonsequential fetch, after the final-cycle wait the
@      prefetcher's running phase imposes). C3/C4 (prefetch on) and C5/C6
@      (off) are ARM nops across 0x08040000 and across nothing, with no
@      load to let the prefetcher ahead: GBATEK says the block start is
@      nonsequential there too, which dingbat does NOT model (the plain
@      burst path is the hot path). GBATEK: C3 - C4 = C5 - C6 = 2; dingbat
@      reads 0 for both.
@
@ Every count is TM0 at prescaler 1 from a store that starts it, read with
@ `ldr` as the alyosha tests do; only the differences are the facts, but
@ dingbat's absolute numbers are comparable too (same code, same anchor).
@
@ Results: WORDS words at 0x02000000, the last the marker 0x600D0003; also
@ copied byte by byte into SRAM for a cart that writes its save out (the
@ SRAM_V tag below is how a flashcart picks the save type).
@ prefetchsplit.py builds it, prints dingbat's reading, and decodes a .sav.
@ dingbat before these rules (ae25841e) reads every difference as 0.
    .syntax unified
    .arm
    .text
    .global _start

.equ IOBASE,    0x04000000
.equ WAITCNT,   0x04000204
.equ TM0CNT,    0x04000100
.equ EWRAM,     0x02000000
.equ RESULTS,   0x02000000
.equ WORDS,     17
.equ MARKER,    0x600D0003

_start:
    b   main
    .space 0x9C
    .space 0x20
    .ascii "SRAM_V113"
    .align 2

main:
    ldr sp, =0x03007F00
    ldr r10, =RESULTS
    mov r0, #IOBASE                @ sound off, as the alyosha tests do
    mov r1, #0
    str r1, [r0, #0x80]
    str r1, [r0, #0x84]
    ldr r0, =WAITCNT
    ldr r1, =0x4014                @ WS0 3/1, prefetch on
    strh r1, [r0]

    bl  case_a1
    bl  store16
    bl  case_a2
    bl  store16
    bl  case_a3
    bl  store16
    bl  case_a4
    bl  store16

    bl  case_b1
    bl  store_b
    bl  case_b2
    bl  store_b

    ldr r0, =c1_code + 1           @ C1: bounday_test_1 at its own address
    bl  call_c
    bl  store16
    ldr r0, =case_c2_thumb + 1
    bl  call_c
    bl  store16

    ldr r0, =case_c3               @ C3/C4: prefetch on
    bl  call_arm
    bl  store16
    ldr r0, =case_c4
    bl  call_arm
    bl  store16
    ldr r0, =WAITCNT
    ldr r1, =0x0014                @ C5/C6: prefetch off
    strh r1, [r0]
    ldr r0, =case_c3
    bl  call_arm
    bl  store16
    ldr r0, =case_c4
    bl  call_arm
    bl  store16
    ldr r0, =WAITCNT
    ldr r1, =0x4014
    strh r1, [r0]

    ldr r1, =MARKER
    str r1, [r10], #4

    ldr r0, =RESULTS               @ into SRAM, a byte at a time
    ldr r1, =0x0E000000
    ldr r2, =(WORDS * 4)
1:  ldrb r3, [r0], #1
    strb r3, [r1], #1
    subs r2, r2, #1
    bgt 1b
9:  b   9b
    .ltorg

store16:
    mov r0, r0, lsl #16
    mov r0, r0, lsr #16
    str r0, [r10], #4
    bx  lr

store_b:
    mov r0, r0, lsl #16
    mov r0, r0, lsr #16
    str r0, [r10], #4
    mov r1, r1, lsl #16
    mov r1, r1, lsr #16
    str r1, [r10], #4
    and r2, r2, #3
    str r2, [r10], #4
    bx  lr

@ r0 = Thumb entry (+1) of a C case, which has 0x00800000 in the word
@ before it (bounday_test_1's r4); it returns with `bx lr` in Thumb
call_c:
    stmfd sp!, {r4-r7, lr}
    ldr r3, =TM0CNT
    mov r1, #EWRAM
    sub r4, r0, #5
    mov lr, pc
    bx  r0
    ldmfd sp!, {r4-r7, pc}

@ r0 = ARM entry of a C3-C6 case
call_arm:
    stmfd sp!, {r4-r7, lr}
    ldr r3, =TM0CNT
    ldr r4, =0x00800000
    mov r5, #0
    mov lr, pc
    bx  r0
    ldmfd sp!, {r4-r7, pc}
    .ltorg

    .align 2
tm_on:
    .word 0x00800000

@ ---------------------------------------------------------------------------
@ A: thumb_arm_3's opening, instruction for instruction (its `adr r4,
@ test_2` / `add r4, 1` become two ALU ops on r5 so r4 stays the ROM
@ pointer), then the timer read at the branch target.
@ ---------------------------------------------------------------------------
    .align 2
case_a1:
    stmfd sp!, {r4-r7, lr}
    ldr r3, =TM0CNT
    mov r1, #EWRAM
    ldr r4, =tm_on
    mov r7, #0xFF
    mov r0, #0
    str r0, [r3]
    ldr r0, [r4]
    str r0, [r3]
    add r5, pc, #80
    add r5, r5, #1
    mov r2, #0
    add r2, pc, #9                 @ -> a1_t + 1: the bx's word + 12
    bx  r2
    nop
    nop
    .thumb
a1_t:
    ldr r0, [r3]
    nop
    bx  pc                         @ on a word boundary + 4: ARM at + 8
    nop
    .arm
    ldmfd sp!, {r4-r7, pc}
    .ltorg

    .align 2
case_a2:
    stmfd sp!, {r4-r7, lr}
    ldr r3, =TM0CNT
    mov r1, #EWRAM
    ldr r4, =tm_on
    mov r7, #0xFF
    mov r0, #0
    str r0, [r3]
    ldr r0, [r4]
    str r0, [r3]
    add r5, pc, #80
    add r5, r5, #1
    mov r2, #0
    add r2, pc, #13                @ -> a2_t + 1: the bx's word + 16
    bx  r2
    nop
    nop
    nop
    .thumb
a2_t:
    ldr r0, [r3]
    nop
    bx  pc
    nop
    .arm
    ldmfd sp!, {r4-r7, pc}
    .ltorg

    .align 2
case_a3:
    stmfd sp!, {r4-r7, lr}
    ldr r3, =TM0CNT
    mov r1, #EWRAM
    ldr r4, =tm_on
    mov r7, #0xFF
    mov r0, #0
    str r0, [r3]
    ldr r0, [r4]
    str r0, [r3]
    add r5, pc, #80
    add r5, r5, #1
    mov r2, #0
    add r2, pc, #8                 @ -> a3_t (ARM): the bx's word + 12
    bx  r2
    nop
    nop
a3_t:
    ldr r0, [r3]
    ldmfd sp!, {r4-r7, pc}
    .ltorg

    .align 2
case_a4:
    stmfd sp!, {r4-r7, lr}
    ldr r3, =TM0CNT
    mov r1, #EWRAM
    ldr r4, =tm_on
    mov r7, #0xFF
    mov r0, #0
    str r0, [r3]
    ldr r0, [r4]
    str r0, [r3]
    add r5, pc, #80
    add r5, r5, #1
    mov r2, #0
    add r2, pc, #12                @ -> a4_t (ARM): the bx's word + 16
    bx  r2
    nop
    nop
    nop
a4_t:
    ldr r0, [r3]
    ldmfd sp!, {r4-r7, pc}
    .ltorg

@ ---------------------------------------------------------------------------
@ B: thumb_arm_3's Thumb run into `bx pc`, then two I/O loads in ARM and
@ the PC read. B1's `bx pc` sits at a word + 6 (target word + 10: bit 1
@ set, the test's own layout); B2's at a word + 8 (target aligned).
@ ---------------------------------------------------------------------------
    .align 2
case_b1:
    stmfd sp!, {r4-r7, lr}
    ldr r3, =TM0CNT
    mov r1, #EWRAM
    ldr r4, =tm_on
    mov r0, #0
    str r0, [r3]
    ldr r0, [r4]
    str r0, [r3]
    add r2, pc, #1                 @ -> b1_t + 1 (the next word)
    bx  r2
    .thumb
b1_t:                              @ a word boundary
    adds r0, r0, #0
    ldr r0, [r1]
    ldr r0, [r1]
    bx  pc                         @ word + 6 -> ARM at word + 10
    .arm
    ldr r0, [r3]                   @ word + 8: executed first
    ldr r1, [r3]
    mov r2, pc
    ldmfd sp!, {r4-r7, pc}
    .ltorg

    .align 2
case_b2:
    stmfd sp!, {r4-r7, lr}
    ldr r3, =TM0CNT
    mov r1, #EWRAM
    ldr r4, =tm_on
    mov r0, #0
    str r0, [r3]
    ldr r0, [r4]
    str r0, [r3]
    add r2, pc, #1
    bx  r2
    .thumb
b2_t:                              @ a word boundary
    nop                            @ one more halfword: bx pc lands aligned
    adds r0, r0, #0
    ldr r0, [r1]
    ldr r0, [r1]
    bx  pc                         @ word + 8 -> ARM at word + 12
    nop
    .arm
    ldr r0, [r3]
    ldr r1, [r3]
    mov r2, pc
    ldmfd sp!, {r4-r7, pc}
    .ltorg

@ ---------------------------------------------------------------------------
@ C2: bounday_test_1's Thumb code, where no 128 KiB boundary is crossed.
@ Entered with r3 = TM0CNT, r4 -> 0x00800000 in ROM, r1 = EWRAM.
@ ---------------------------------------------------------------------------
    .org 0x11FE4
    .word 0x00800000
    .thumb
case_c2_thumb:
    movs r7, #255
    movs r0, #0
    str r0, [r3]
    ldr r0, [r4]
    str r0, [r3]
    ldr r0, [r4]
    ldr r0, [r1]
    ldr r0, [r1]
    adds r0, r0, #0
    adds r0, r0, #0
    adds r0, r0, #0
    adds r0, r0, #0
    adds r0, r0, #0
    adds r0, r0, #0
    ldr r0, [r3]
    bx  lr

@ C1: the same across 0x08020000, at bounday_test_1's own addresses, with
@ its 0x00800000 at 0x0801FFE4 as the test has it.
    .org 0x1FFE4
    .word 0x00800000
    .thumb
c1_code:
    movs r7, #255
    movs r0, #0
    str r0, [r3]
    ldr r0, [r4]
    str r0, [r3]
    ldr r0, [r4]
    ldr r0, [r1]
    ldr r0, [r1]
    adds r0, r0, #0                @ 0x0801FFF8
    adds r0, r0, #0
    adds r0, r0, #0
    adds r0, r0, #0                @ 0x08020000
    adds r0, r0, #0
    adds r0, r0, #0
    ldr r0, [r3]                   @ 0x08020004
    bx  lr

@ ---------------------------------------------------------------------------
@ C4/C6: ARM nops from a timer start, across nothing; C3/C5 the same
@ across 0x08040000. r3 = TM0CNT, r4 = 0x00800000, r5 = 0.
@ ---------------------------------------------------------------------------
    .org 0x2FFD0
    .arm
case_c4:
    str r5, [r3]
    str r4, [r3]
    .rept 16
    nop
    .endr
    ldr r0, [r3]
    bx  lr

    .org 0x3FFD0
    .arm
case_c3:
    str r5, [r3]
    str r4, [r3]
    .rept 16                       @ 0x0803FFD8 .. 0x08040014
    nop
    .endr
    ldr r0, [r3]
    bx  lr
    .space 0x100
