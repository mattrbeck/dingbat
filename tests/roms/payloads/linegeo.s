@ payload: the scanline's own geometry, with no anchor to be wrong about
@
@ Every absolute number this line of work has leaned on was measured from a
@ timer started inside the same payload, so "the event is late" and "the timer
@ started early" fit it equally well. hdmastamp.s's control found that out the
@ expensive way: it reads 1006 on hardware and 999 here, and there is no way
@ to tell from that page whether the H-blank flag, the VCOUNT edge, the
@ timer's enable latency or the poll's own granularity is responsible
@ (docs/playtest-bugs.md sections 15 and 16).
@
@ So: start one timer, once, and never stop it. Read it four times. Report
@ only DIFFERENCES between those reads. The enable latency is then common to
@ every stamp and cancels exactly, and what is left is the line's geometry.
@
@   A  the cycle the CPU first sees VCOUNT = 159
@   B  the cycle it first sees the H-blank flag of line 159
@   C  the cycle it first sees VCOUNT = 160
@   E  the cycle it first sees the V-blank flag
@
@ C - A IS THE SCANLINE LENGTH, and it is the certainty check: both polls are
@ the same three-instruction loop on the same grid, so C - A must come back a
@ multiple of that loop's period bracketing 1232. A run that does not bracket
@ 1232 is not measuring what this file claims and nothing else in it counts.
@
@ B - A is the H-blank flag's position in the line, which is the number that
@ GBATEK gives as 1006 and that nobody here has ever measured. E - C is the
@ V-blank flag against the VCOUNT edge that should be simultaneous with it --
@ the other term of every difference hdmamul.s and hdmasweep.s report, and so
@ far never pinned on its own.
@
@ The sled k shifts the poll grid one cycle at a time under a fixed line, so
@ the quantisation shows up as a sawtooth in k instead of hiding as a constant
@ in one reading. Sweeping a whole period means the profile can be compared
@ between hardware and here row by row, which a single number never allowed.
@
@ +0   + k*8 (w) ((C - A) << 16) | (B - A) for k = 0..31
@ +4   + k*8 (w) ((E - C) << 16) | A
@ +256      (b)  marker 77
    .arm
    .text
    .global _start

.equ IOBASE,   0x04000000
.equ TM0BASE,  0x04000100
.equ RESULTS,  0x02008000
.equ LGSTUB,   0x03002000          @ IWRAM copy of lg_stub, clear of us

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

    ldr r0, =lg_stub               @ the stub runs from IWRAM, where the poll
    ldr r1, =LGSTUB                @ loop costs the same every iteration
    mov r2, #((lg_stub_end - lg_stub) / 4)
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b

    mov r4, #IOBASE
    ldr r10, =TM0BASE
    ldr r0, =0x04000200            @ IEADDR
    ldrh r6, [r0, #8]              @ IME as we found it: we run under a
    push {r6}                      @ resident monitor that has to survive us
    mov r1, #0
    strh r1, [r0, #8]              @ IME off
    ldrh r6, [r10, #2]             @ and TM0's control
    push {r6}

    ldr r5, =0x00800000            @ TM0: reload 0, enable, prescaler 1
    .irp k, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    mov r6, #\k
    ldr r12, =LGSTUB
    mov lr, pc
    bx  r12
    ldr r1, =RESULTS
    str r7, [r1, #(\k * 8)]
    str r9, [r1, #(\k * 8 + 4)]
    .endr

    ldr r1, =RESULTS
    mov r0, #77
    strb r0, [r1, #256]

    pop {r6}                       @ TM0 control and IME back as found
    strh r6, [r10, #2]
    pop {r6}
    ldr r0, =0x04000200
    strh r6, [r0, #8]
    ldr r0, =0x4C474554            @ 'LGET': the payload ran to the end
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

@ r4 = IOBASE, r10 = TM0BASE, r6 = k (0..31), r5 = 0x00800000.
@ -> r7 = ((C - A) << 16) | (B - A), r9 = ((E - C) << 16) | A.
@ No literal pools: the routine is copied to IWRAM.
lg_stub:
    mov r12, #0
    str r12, [r10]                 @ TM0 off, reload 0
1:  ldrh r0, [r4, #6]              @ park on line 158, so that starting the
    cmp r0, #158                   @ timer cannot cost us a 16-bit overflow
    bne 1b
    str r5, [r10]                  @ TM0 free-running from here, never stopped
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
3:  ldrh r0, [r4, #4]              @ DISPSTAT
    tst r0, #2                     @ H-blank flag of line 159
    beq 3b
    ldrh r2, [r10]                 @ B: the flag seen
4:  ldrh r0, [r4, #6]              @ the same loop as 2b, so A and C sit on
    cmp r0, #160                   @ one grid and C - A is a whole number of
    bne 4b                         @ its periods bracketing the line
    ldrh r3, [r10]                 @ C: VCOUNT = 160 seen
5:  ldrh r0, [r4, #4]
    tst r0, #1                     @ V-blank flag
    beq 5b
    ldrh r12, [r10]                @ E: the V-blank flag seen
    mov r0, #0
    str r0, [r10]                  @ TM0 off, as we found it
    sub r7, r2, r1                 @ B - A
    sub r0, r3, r1                 @ C - A
    orr r7, r7, r0, lsl #16
    sub r9, r12, r3                @ E - C
    mov r9, r9, lsl #16
    orr r9, r9, r1                 @ | A, for scale only: it is anchored
    bx  lr
lg_stub_end:
