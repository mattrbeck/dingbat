@ payload: where the H-blank DMA's write lands, with no anchor to be wrong about
@
@ linegeo.s established that the line's geometry agrees with hardware exactly
@ -- scanline length, H-blank flag position, V-blank flag against the VCOUNT
@ edge -- and that hdmastamp.s's seven-cycle "anchor discrepancy" was its
@ control landing on one of the two poll phases in seven where the console
@ needs an extra iteration of the polling loop. Quantisation, not physics.
@
@ That leaves the DMA itself, and hdmastamp measured it from a timer start
@ inside the payload, which is the anchor that just proved untrustworthy. So
@ measure it the way linegeo measures the flag: differences only.
@
@ TM0 is the clock. It is started on line 158 and never stopped, and every
@ stamp the CPU takes is a read of it. TM1 is started immediately after TM0,
@ so it runs on the same clock a fixed number of cycles behind, and it is
@ frozen by the H-blank DMA's own write to TM1CNT_H. The skew between the two
@ starts is two instructions of the same code in both places, so it is a
@ constant that cancels the moment hardware and here are compared row by row.
@
@   A  the cycle the CPU first sees VCOUNT = 159       (TM0)
@   B  the cycle it first sees the H-blank flag        (TM0)
@   C  the cycle it first sees VCOUNT = 160            (TM0)
@   D  the cycle the H-blank DMA wrote TM1CNT_H        (TM1, frozen)
@
@ D - B is the whole question: how far the grant sits behind the flag, with
@ no timer start, no line boundary and no absolute claim anywhere in it. If
@ that agrees, the grant is right and the mGBA suite's "DMA Prefetch Break"
@ is asking for something a correct model does not owe it. If it disagrees,
@ the disagreement is the grant's, and this is the number to fit.
@
@ C - A is carried through from linegeo as the certainty check: it must come
@ back bracketing 1232, or the run is not measuring a scanline and nothing
@ else in it counts.
@
@ k runs 0..13, two whole periods of the seven-cycle poll grid. Not further:
@ the resident monitor gives a payload ten seconds, every trial waits out a
@ frame to park on line 158, and a 32-trial sweep does not come back.
@
@ +0  + k*8 (w) ((C - A) << 16) | (B - A) for k = 0..13
@ +4  + k*8 (w) ((D - A) << 16) | (B - A again, for alignment of the pair)
@ +256     (b)  marker 78
@ D - A = 0xFFFF means the DMA never fired.
    .arm
    .text
    .global _start

.equ IOBASE,   0x04000000
.equ TM0BASE,  0x04000100
.equ TM1BASE,  0x04000104
.equ TM1CNTH,  0x04000106
.equ RESULTS,  0x02008000
.equ HPZERO,   0x03002800          @ the halfword the DMA moves
.equ HGSTUB,   0x03002000          @ IWRAM copy of hg_stub, clear of us

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r0, =RESULTS               @ EWRAM boots as noise; clear the slots
    mov r1, #0
    mov r2, #0
    mov r3, #0
    mov r12, #0
    mov r7, #17                    @ 17 x 16 = 272, covers +0..+271
1:  stmia r0!, {r1-r3, r12}
    subs r7, r7, #1
    bne 1b

    ldr r0, =hg_stub               @ the stub runs from IWRAM, where the poll
    ldr r1, =HGSTUB                @ loop costs the same every iteration
    mov r2, #((hg_stub_end - hg_stub) / 4)
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b

    mov r4, #IOBASE
    ldr r10, =TM0BASE
    ldr r11, =TM1BASE
    ldr r9, =0x040000B0            @ DMA0
    ldr r0, =0x04000200            @ IEADDR
    ldrh r6, [r0, #8]              @ IME as we found it: we run under a
    push {r6}                      @ resident monitor that has to survive us
    mov r1, #0
    strh r1, [r0, #8]              @ IME off
    ldrh r6, [r10, #2]             @ and both timer controls
    push {r6}
    ldrh r6, [r11, #2]
    push {r6}

    ldr r0, =HPZERO                @ the zero the DMA moves into TM1CNT_H
    mov r1, #0
    strh r1, [r0]
    str r0, [r9]                   @ DMA0 source
    ldr r1, =TM1CNTH
    str r1, [r9, #4]               @ DMA0 destination

    ldr r5, =0x00800000            @ reload 0, enable, prescaler 1
    ldr r8, =0xA1400001            @ DMA0: enable, hblank, 16-bit, fixed, 1
    .irp k, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13
    mov r6, #\k
    ldr r12, =HGSTUB
    mov lr, pc
    bx  r12
    ldr r1, =RESULTS
    str r7, [r1, #(\k * 8)]
    str r2, [r1, #(\k * 8 + 4)]
    .endr

    ldr r1, =RESULTS
    mov r0, #78
    strb r0, [r1, #256]

    mov r0, #0                     @ DMA0, timer controls and IME back
    str r0, [r9, #8]
    pop {r6}
    strh r6, [r11, #2]
    pop {r6}
    strh r6, [r10, #2]
    pop {r6}
    ldr r0, =0x04000200
    strh r6, [r0, #8]
    ldr r0, =0x48474554            @ 'HGET': the payload ran to the end
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

@ r4 = IOBASE, r10 = TM0BASE, r11 = TM1BASE, r9 = DMA0, r6 = k (0..13),
@ r5 = 0x00800000, r8 = DMA0 control word.
@ -> r7 = ((C - A) << 16) | (B - A), r2 = ((D - A) << 16) | (B - A).
@ No literal pools: the routine is copied to IWRAM.
hg_stub:
    mov r12, #0
    str r12, [r9, #8]              @ DMA0 off
    str r12, [r10]                 @ TM0 off, reload 0
    str r12, [r11]                 @ TM1 off, reload 0
1:  ldrh r0, [r4, #6]              @ park on line 158, so that starting the
    cmp r0, #158                   @ timers cannot cost us a 16-bit overflow
    bne 1b
    str r5, [r10]                  @ TM0: the clock, never stopped
    str r5, [r11]                  @ TM1: the same clock, a fixed skew behind,
                                   @ to be frozen by the DMA's own write
    rsb r6, r6, #31
    add pc, pc, r6, lsl #2         @ skip 31-k sled entries: k+1 NOPs run
    mov r0, r0                     @ (pc reads +8: this word is jumped over)
    .rept 32
    mov r0, r0
    .endr
2:  ldrh r0, [r4, #6]
    cmp r0, #159
    bne 2b
    ldrh r1, [r10]                 @ A: VCOUNT = 159 seen
    str r8, [r9, #8]               @ arm the H-blank DMA for this line
3:  ldrh r0, [r4, #4]              @ DISPSTAT
    tst r0, #2                     @ H-blank flag of line 159
    beq 3b
    ldrh r2, [r10]                 @ B: the flag seen
    mov r12, #0
4:  ldrh r0, [r11, #2]             @ TM1CNT_H: has the DMA frozen it yet?
    tst r0, #0x80
    beq 5f
    add r12, r12, #1
    cmp r12, #0x4000
    bcc 4b
    mvn r3, #0                     @ the DMA never fired
    b   6f
5:  ldrh r3, [r11]                 @ D: the cycle the DMA wrote TM1CNT_H
    sub r3, r3, r1                 @ D - A, on a timebase a fixed skew behind
6:  mov r12, #0
    str r12, [r9, #8]              @ DMA0 off before the next line's H-blank
7:  ldrh r0, [r4, #6]
    cmp r0, #160                   @ the same loop as 2b, so A and C sit on
    bne 7b                         @ one grid and C - A brackets the line
    ldrh r0, [r10]                 @ C: VCOUNT = 160 seen
    sub r0, r0, r1                 @ C - A
    sub r2, r2, r1                 @ B - A
    mov r7, r2
    orr r7, r7, r0, lsl #16        @ ((C - A) << 16) | (B - A)
    mov r3, r3, lsl #16
    orr r2, r2, r3                 @ ((D - A) << 16) | (B - A)
    mov r0, #0
    str r0, [r10]                  @ both timers off, as we found them
    str r0, [r11]
    bx  lr
hg_stub_end:
