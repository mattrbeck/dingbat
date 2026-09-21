@ payload: the mGBA suite's `DMA Prefetch Break`, end to end, where the link
@ rig can run it.
@
@ slotexec.s, slotdma.s and vbwait.s measured that row's terms one at a time
@ and every one agrees with the console, yet the sum does not reproduce the
@ suite's constant. This runs the whole sentence instead: DMA3 armed for
@ H-blank with the suite's own control word, VBlankIntrWait through
@ Nintendo's BIOS and a table-walking dispatcher, the suite's entry sequence,
@ and its seven-instruction loop reading unmapped memory until the DMA's word
@ shows up on the bus. Only the loop's home differs, because an empty slot
@ cannot hold one: IWRAM (period 12, the capture window is one cycle and the
@ grant walks +4 a line, so one entry phase in four is ever caught) or EWRAM
@ (period 30, window 3, walk -2: always caught, on a line that says where
@ the entry was to within two cycles). Swept over the entry sled, the answers
@ are a staircase whose every edge is a one-cycle statement about the path
@ from the V-blank interrupt to a line's H-blank DMA.
@
@ r0 bits 0..6   k, NOPs between SWI 5's return and the entry sequence
@    bit  7      leave the DMA unarmed (for the flag reads: an H-blank DMA
@                stalls the CPU just as an H-blank interrupt arrives)
@    bit  8      run the Thumb block from EWRAM rather than IWRAM
@    bit  9      stamp: the DMA's destination is TM0CNT and its word stops
@                TM0, which the entry sequence started -- so the DMA's own
@                write says when it ran, apart from whether the loop saw it
@    bit  10     wait on a V-count match (line = bits 16..23) rather than
@                on V-blank -- the other source, and any line
@    bit  11     DMA0 rather than DMA3
@    bit  12     a stale entry ahead of the end of the dispatcher's table
@    bit  13     with bit 14: the interrupt that stops the ring is the
@                H-blank of the line itself, not a V-count match. Without:
@                wait halted on an H-blank interrupt (whichever line is next)
@    bit  14     take the interrupt on a RUNNING CPU (needs bit 10, IWRAM
@                only): wait halted for line - 1, then run a ring of
@                one-cycle NOPs until the match on the line itself interrupts
@                it, and have the dispatcher return into the entry sequence.
@                Every other mode enters through a halted CPU's wake
@    bits 24..31 N != 0: no loop. Spin N x 4 cycles after the entry sequence
@                and read DISPSTAT and VCOUNT once each -- swept over k, the
@                cycle a flag turns over, measured from the same entry as the
@                stamps and with no polling loop to quantise it
@    bit  15     arm the DMA for V-blank rather than H-blank (enter on a
@                V-count match at 159 and the stamp is the V-blank DMA's)
@ answer: reads << 8 | VCOUNT at the exit; reads = 0x4000 if never caught,
@ 0xFFFFFFFF if the watchdog fired. With bit 9: T << 16 | reads, T = TM0 as
@ the first DMA after the entry left it (mod 65536).
    .arm
    .text
    .global _start
.equ EWRAM_HOME, 0x02010000
.equ LIMIT, 0x10010000             @ 0x4000 reads

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str sp, [r12]
    str r0, [r12, #8]
    ldr r4, =0x04000200
    ldrh r1, [r4, #8]
    str r1, [r12, #12]             @ IME
    ldrh r1, [r4]
    str r1, [r12, #16]             @ IE
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #24]             @ the IRQ vector
    mov r3, #0x04000000
    ldrh r2, [r3, #4]
    str r2, [r12, #28]             @ DISPSTAT
    mov r2, #0
    strh r2, [r4, #8]
    adr r2, dispatcher
    str r2, [r1]

    @ the dispatcher's table: n entries that never match, then the end
    ldr r1, =table
    mov r2, r0, lsr #12
    and r2, r2, #1
    mov r3, #0x10                  @ TIMER1's bit, as SIO timing leaves behind
1:  cmp r2, #0
    strne r3, [r1, #4]
    strne r3, [r1], #8
    subne r2, r2, #1
    bne 1b
    str r2, [r1]
    str r2, [r1, #4]

    @ stamp mode: aim the DMA at TM0CNT with a word that stops it
    tst r0, #0x200
    ldrne r1, =0x0000BEEF
    ldrne r2, =src
    strne r1, [r2]
    ldrne r2, =lit_word
    strne r1, [r2]
    ldrne r1, =0x04000100
    ldrne r2, =lit_dst
    strne r1, [r2]

    ldr r2, =lit_coarse
    mov r1, r0, lsr #24
    str r1, [r2]

    @ the Thumb block, in place or in EWRAM
    ldr r8, =blk
    tst r0, #0x100
    beq 3f
    ldr r9, =EWRAM_HOME
    ldr r10, =blk_end
    mov r8, r9
    ldr r1, =blk
2:  ldr r2, [r1], #4
    str r2, [r9], #4
    cmp r1, r10
    blo 2b
3:  and r1, r0, #0x7F
    add r7, r8, #(sled_end - blk)
    sub r7, r7, r1, lsl #1
    orr r7, r7, #1                 @ where SWI 5's return lands in the sled
    tst r0, #0x4000
    beq 4f
    ldr r2, =lit_r7                @ running: the SWI returns into runprep,
    str r7, [r2]                   @ which arms the real line and spins
    mov r1, r0, lsr #16
    and r1, r1, #0xFF
    mov r1, r1, lsl #8
    orr r1, r1, #0x20
    tst r0, #0x2000
    movne r1, #0x10                @ H-blank interrupt instead
    ldr r2, =lit_dispval
    str r1, [r2]
    ldr r2, =redirect
    add r1, r8, #6                 @ `bx r7`, + 4 for the BIOS's subs pc, lr, #4
    str r1, [r2, #4]
    add r7, r8, #(runprep - blk)
    orr r7, r7, #1
4:

    ldr r10, =0x04000100
    mov r1, #0
    str r1, [r10, #12]
    ldr r1, =0x00C3F000            @ TM3: 4096 x 1024 cycles, IRQ -- the watchdog
    str r1, [r10, #12]

    mov r3, #0x04000000
    ldr r12, =vars
    ldr r6, [r12, #8]
    tst r6, #0x800
    addeq r2, r3, #0xD4
    addne r2, r3, #0xB0
    ldr r1, =src
    str r1, [r2]
    ldr r1, =lit_dst
    ldr r1, [r1]
    str r1, [r2, #4]
    ldr r1, =0xA7400001            @ the suite's word: H-blank, repeat, 32-bit,
    tst r6, #0x8000                @ both addresses fixed, one word
    ldrne r1, =0x97400001          @ or the same on V-blank
    tst r6, #0x80
    movne r1, #0
    str r1, [r2, #8]

    tst r6, #0x400
    moveq r0, #0x08                @ DISPSTAT: V-blank interrupt
    beq 5f
    mov r0, r6, lsr #16
    and r0, r0, #0xFF
    and r1, r6, #0x6000
    cmp r1, #0x4000
    subeq r0, r0, #1               @ running: halt for the line before
    mov r0, r0, lsl #8
    orr r0, r0, #0x20              @ or a V-count match
    cmp r1, #0x2000
    moveq r0, #0x10                @ or, halted, the next H-blank
5:  strh r0, [r3, #4]
    tst r6, #0x400
    moveq r0, #0x41
    movne r0, #0x46
    strh r0, [r4]                  @ IE = that (and H-blank, which DISPSTAT
                                   @ gates), and the watchdog
    ldr r1, =0xDF05                @ svc 5, VBlankIntrWait
    ldrne r1, =0xDF04              @ svc 4, IntrWait(r0, r1)
    sub r2, r8, #0
    strh r1, [r2]
    mvn r0, #0
    strh r0, [r4, #2]
    mov r0, #1
    strh r0, [r4, #8]
    ldr r4, =out
    mov r5, #0
    and r1, r6, #0x6000
    cmp r1, #0x2000
    movne r1, #4
    moveq r1, #2
    orr r8, r8, #1
    bx r8

back:
    mov r3, #0x04000000
    mov r1, #0
    str r1, [r3, #0xDC]
    cmn r2, #1
    beq finish
    sub r2, r2, #0x10000000
    ldr r12, =vars
    ldr r1, [r12, #8]
    tst r1, #0x200
    moveq r2, r2, lsl #6           @ reads << 8 | VCOUNT
    andeq r0, r0, #0xFF
    orreq r0, r0, r2
    beq finish
    ldr r1, =0x04000100
    ldrh r0, [r1]                  @ T, where the DMA's write left it
    mov r0, r0, lsl #16
    orr r0, r0, r2, lsr #2
finish:
    ldr r12, =vars
    ldr r4, =0x04000200
    mov r1, #0
    strh r1, [r4, #8]
    mov r3, #0x04000000
    str r1, [r3, #0xDC]
    str r1, [r3, #0xB8]
    ldr r7, =0x04000100
    str r1, [r7, #12]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r1, [r12, #24]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #28]
    strh r1, [r3, #4]
    ldr r1, [r12, #16]
    strh r1, [r4]
    ldr r1, [r12, #12]
    strh r1, [r4, #8]
    ldr sp, [r12]
    ldmfd sp!, {r4-r11, lr}
    bx lr

@ The shape of libgba's dispatcher when nothing is registered for the
@ interrupt that fired: mask IME, save SPSR, fold the flags into the BIOS's
@ copy, walk the table to its end, acknowledge, restore, return.
dispatcher:
    ldr r0, =redirect
    ldr r1, [r0]
    cmp r1, #0
    beq 1f
    mov r1, #0
    str r1, [r0]
    ldr r1, [r0, #4]
    str r1, [sp, #20]              @ the BIOS's saved lr: return to `bx r7`
1:  mov r3, #0x04000000
    ldr r2, [r3, #0x200]           @ IE | IF << 16
    ldr r1, [r3, #0x208]           @ IME
    str r3, [r3, #0x208]           @ IME off
    mrs r0, spsr
    stmfd sp!, {r0, r1, r3, lr}
    and r1, r2, r2, lsr #16
    tst r1, #0x40
    bne watchdog
    ldrh r2, [r3, #-8]             @ the BIOS's copy, 0x03FFFFF8
    orr r2, r2, r1
    strh r2, [r3, #-8]
    ldr r2, =table
    add r3, r3, #0x200
3:  ldr r0, [r2, #4]
    cmp r0, #0
    beq 2f
    ands r0, r0, r1
    bne 2f
    add r2, r2, #8
    b 3b
2:  strh r1, [r3, #2]              @ IF
    ldmfd sp!, {r0, r1, r3, lr}
    str r1, [r3, #0x208]           @ IME back
    mov pc, lr

watchdog:
    add r0, r3, #0x200
    mov r1, #0
    strh r1, [r0, #8]
    mvn r1, #0
    strh r1, [r0, #2]
    ldr sp, =0x03007FA0
    msr cpsr_c, #0x1F
    mvn r0, #0
    b finish
    .ltorg

@ Everything from the SWI to the exit, position-independent. r4 = out,
@ r5 = 0, r7 = the sled entry. The entry sequence and the loop are the
@ suite's, instruction for instruction, but for the exit test: that one
@ passes on the loop's own opcode, which has no fixed value here, so this
@ one leaves on the DMA's word.
    .thumb
    .align 2
blk:
    svc 5
    bx r7
    .rept 64
    mov r0, r0
    .endr
sled_end:
    ldr r3, lit_tm0
    ldr r0, lit_go
    str r0, [r3]                   @ TM0 starts (only stamp mode reads it)
    mov r2, #128
    ldr r3, lit_ime
    ldr r0, lit_mask
    strh r5, [r3]                  @ IME off
    ldr r1, lit_word
    ldr r5, lit_limit
    lsl r2, #21
    ldr r3, lit_coarse
    cmp r3, #0
    beq 2f
4:  sub r3, #1
    bne 4b
    ldr r3, lit_dispstat
    ldrh r0, [r3]                  @ DISPSTAT, once
    ldrh r1, [r3, #2]              @ VCOUNT, three cycles later
    lsl r1, #8
    lsl r0, #29
    lsr r0, #29
    orr r0, r1
    mov r2, #0
    sub r2, #1                     @ reads = -1 marks the mode for `back`
    ldr r3, lit_back
    bx r3
1:  cmp r2, r5
    beq 3f
2:  ldmia r2!, {r3}
    str r3, [r4, #4]
    and r3, r0
    cmp r3, r1
    bne 1b
3:  ldr r3, lit_vcount
    ldrh r0, [r3]                  @ VCOUNT at the exit
    ldr r3, lit_back
    bx r3
runprep:
    ldr r3, lit_dispstat
    ldr r0, lit_dispval
    strh r0, [r3]                  @ the match moves to the line itself
    ldr r7, lit_r7
    ldr r3, lit_redirect
    mov r0, #1
    str r0, [r3]
    b ring
    .align 2
lit_tm0:    .word 0x04000100
lit_go:     .word 0x00800000
lit_ime:    .word 0x04000208
lit_mask:   .word 0xFFFFFFFF
lit_word:   .word 0xDEAD0000
lit_limit:  .word LIMIT
lit_vcount: .word 0x04000006
lit_back:   .word back
lit_coarse: .word 0
lit_dispstat: .word 0x04000004
lit_dispval: .word 0
lit_r7:     .word 0
lit_redirect: .word redirect
ring:
    .rept 1000
    mov r0, r0
    .endr
    b ring
    .align 2
blk_end:

    .arm
vars:
    .space 32
redirect:
    .word 0, 0
out:
    .space 8
src:
    .word 0xDEAD0000, 0xDEAD0001, 0xDEAD0002, 0xDEAD0003
dst:
    .word 0
lit_dst:
    .word dst
table:
    .space 72
