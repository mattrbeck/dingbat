@ payload: the H-blank DMA grant's deferral, stamped absolutely
@
@ hdmasweep.s asked whether the grant waits for the CPU's bus cycle in flight
@ and answered yes, but it answers with `TM1 - TM0` -- the V-blank DMA's write
@ minus the H-blank DMA's. A difference pins neither term, and that cost us: a
@ constant offset in the V-blank DMA read as though it were the H-blank one
@ (docs/playtest-bugs.md section 14). So stamp the two DMAs separately and
@ report both raw.
@
@ TM0 is started at a fixed point just after the line-159 boundary and frozen
@ by the H-blank DMA's own write, so its value is the H-blank write measured
@ from a fixed anchor -- an absolute stamp, not a difference. The pre-delay k
@ shifts the CPU's loop phase under it, so the TM0 column IS the deferral as a
@ function of where in the CPU's access the request lands. TM1, frozen by the
@ V-blank DMA, should barely move: it is the control.
@
@ The other thing hdmasweep cannot do is see a whole period. Its loop is a
@ 32-bit gamepak load at 8 waits (about 18 cycles) plus about 10 cycles of
@ polling, call it 28, and it sweeps k over 14 -- half a period, which is why
@ its hardware rows look like one isolated dip at k = 6 rather than a shape.
@ This sweeps k = 0..31, so a full period is covered whatever it is, and the
@ deferral's real profile can be read off instead of inferred.
@
@ Reading it: subtract each row's TM0 from the largest TM0 in the column. That
@ is the deferral in cycles at that phase. Flat zero = no deferral anywhere.
@ A run of rows falling one cycle per k and snapping back = the grant waiting
@ for the end of an access, and the snap-backs mark where accesses end.
@
@ +0..+127 (32 w) (TM1 << 16) | TM0 for k = 0..31, the CPU looping on a
@   32-bit gamepak load at WS0 = 8 waits, prefetch off
@ +128 (w) the same with the loop loading from IWRAM, k = 0 (1-cycle accesses:
@   the control, nothing to defer for)
@ +132 (w) IWRAM again at k = 7
@ +140 (w) CONTROL, no DMA involved: TM0 stamped when the CPU first SEES the
@   DISPSTAT H-blank flag on the same line, from the same timer start. The
@   whole page is anchored on that timer start, so "both DMA writes are late"
@   and "both timers start early" fit the DMA rows equally well. This row
@   separates them: if it agrees between hardware and here while the DMA rows
@   differ, the difference is the DMA's. If it differs by the same amount, the
@   anchor moved and the DMA rows say nothing about the DMA.
@ +136 (b) marker 55
@ 0xFFFFFFFF in any slot means a DMA never fired there.
@
@ NOTE 2026-09-18: the control at +140 did its job and then misled us. It
@ reads 1006 on hardware against 999 here, and those seven cycles are this
@ page's own VCOUNT poll taking one extra iteration at two phases in seven,
@ not a property of the console. linegeo.s measures the line with no anchor
@ at all and finds the geometry exact. Treat every absolute number here as
@ anchored; the deferral SHAPE is what survives.
    .arm
    .text
    .global _start

.equ IOBASE,   0x04000000
.equ TM0BASE,  0x04000100
.equ TM0CNTH,  0x04000102
.equ RESULTS,  0x02008000
.equ HPZERO,   0x03002800          @ the halfword both DMAs move
.equ V10STUB,  0x03002000          @ IWRAM copy of hs_stub, clear of us
.equ FLSTUB,   0x03002400          @ IWRAM copy of fl_stub, clear of both

.macro hs_trial k, addr
    ldr r1, =0xA1400001            @ DMA0: enable, hblank, 16-bit, fixed, 1
    ldr r8, =0x91400001            @ DMA1: enable, vblank, 16-bit, fixed, 1
    ldr r3, =\addr
    ldr r5, =0x00800000
    mov r6, #\k
    ldr r2, =0x04000104            @ TM1BASE
    ldr r12, =V10STUB
    mov lr, pc
    bx  r12
.endm

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r0, =RESULTS               @ EWRAM boots as noise; clear the slots
    mov r1, #0
    mov r2, #0
    mov r3, #0
    mov r12, #0
    mov r7, #10                    @ 10 x 16 bytes = 160, covers +0..+139
1:  stmia r0!, {r1-r3, r12}
    subs r7, r7, #1
    bne 1b

    ldr r0, =hs_stub               @ the stub runs from IWRAM
    ldr r1, =V10STUB
    mov r2, #((hs_stub_end - hs_stub) / 4)
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b

    mov r4, #IOBASE
    ldr r9, =0x040000B0            @ DMA0
    ldr r10, =TM0BASE
    ldr r11, =0x040000BC           @ DMA1
    ldr r0, =0x04000200            @ IEADDR
    ldrh r6, [r0, #8]              @ IME as we found it: we run under a
    push {r6}                      @ resident monitor that has to survive us
    mov r1, #0
    strh r1, [r0, #8]              @ IME off
    ldrh r6, [r10, #2]             @ and both timer controls
    push {r6}
    ldr r6, =0x04000106
    ldrh r6, [r6]
    push {r6}
    ldr r0, =HPZERO                @ the zero both DMAs move
    strh r1, [r0]
    str r0, [r9]
    str r0, [r11]
    ldr r1, =TM0CNTH
    str r1, [r9, #4]               @ DMA0 -> TM0CNT_H
    ldr r1, =0x04000106
    str r1, [r11, #4]              @ DMA1 -> TM1CNT_H
    ldr r0, =0x04000204
    ldrh r0, [r0]
    push {r0}                      @ WAITCNT, put back at the end

    hs_trial 0, HPZERO             @ IWRAM control, k = 0 and k = 7
    ldr r1, =RESULTS
    str r7, [r1, #128]
    hs_trial 7, HPZERO
    ldr r1, =RESULTS
    str r7, [r1, #132]

    ldr r0, =0x04000204
    mov r1, #0x0C                  @ WS0 first access 8 waits, prefetch off
    strh r1, [r0]
    .irp k, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    hs_trial \k, 0x08000000
    ldr r1, =RESULTS
    str r7, [r1, #(\k * 4)]
    .endr
    pop {r0}
    ldr r1, =0x04000204
    strh r0, [r1]                  @ WAITCNT back as we found it

    ldr r12, =FLSTUB               @ the flag-stamp control
    ldr r0, =fl_stub
    mov r2, #((fl_stub_end - fl_stub) / 4)
1:  ldr r3, [r0], #4
    str r3, [r12], #4
    subs r2, r2, #1
    bne 1b
    ldr r5, =0x00800000
    ldr r2, =0x04000104
    ldr r12, =FLSTUB
    mov lr, pc
    bx  r12
    ldr r1, =RESULTS
    str r7, [r1, #140]

    ldr r1, =RESULTS
    mov r0, #55
    strb r0, [r1, #136]

    pop {r6}                       @ timer controls and IME back as found
    ldr r0, =0x04000106
    strh r6, [r0]
    pop {r6}
    strh r6, [r10, #2]
    pop {r6}
    ldr r0, =0x04000200
    strh r6, [r0, #8]
    ldr r0, =0x48445354            @ 'HDST': the payload ran to the end
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

@ r1 = DMA0 (H-blank) control, r8 = DMA1 (V-blank) control, r3 = the address
@ the loop loads from, r5 = 0x00800000, r6 = k (0..31), r2 = TM1BASE,
@ r4 = IOBASE, r9 = DMA0, r10 = TM0BASE, r11 = DMA1
@ -> r7 = (TM1 << 16) | TM0, or 0xFFFFFFFF if either DMA never fired.
@ No literal pools: the routine is copied to IWRAM.
hs_stub:
    mov r12, #0
    str r12, [r9, #8]
    str r12, [r11, #8]
    str r12, [r10]
    str r12, [r2]
1:  ldrh r0, [r4, #6]              @ park on line 158 ...
    cmp r0, #158
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, #159
    bne 2b                         @ ... and start on the line-159 boundary
    str r1, [r9, #8]               @ arm the H-blank DMA0
    str r8, [r11, #8]              @ arm the V-blank DMA1
    str r5, [r2]                   @ TM1 first ...
    str r5, [r10]                  @ ... then TM0, a fixed skew behind
    rsb r6, r6, #31
    add pc, pc, r6, lsl #2         @ skip 31-k sled entries: k+1 NOPs run
    mov r0, r0                     @ (pc reads +8: this word is jumped over)
    .rept 32
    mov r0, r0
    .endr
    mov r12, #0
3:  ldr r0, [r3]                   @ the access the H-blank grant may wait on
    ldrh r0, [r10, #2]             @ TM0CNT_H: still enabled?
    tst r0, #0x80
    beq 4f
    add r12, r12, #1
    cmp r12, #0x8000
    bcc 3b
    b   8f
4:  mov r12, #0
5:  ldrh r0, [r2, #2]              @ TM1CNT_H, polled on 1-cycle accesses
    tst r0, #0x80
    beq 6f
    add r12, r12, #1
    cmp r12, #0x8000
    bcc 5b
8:  mvn r7, #0                     @ a DMA never fired
    b   7f
6:  ldrh r7, [r2]                  @ V-blank write stamp
    ldrh r0, [r10]                 @ H-blank write stamp
    orr r7, r0, r7, lsl #16        @ (TM1 << 16) | TM0, both raw
7:  mov r0, #0
    str r0, [r9, #8]
    str r0, [r11, #8]
    str r0, [r10]
    str r0, [r2]
    bx  lr
hs_stub_end:

@ The anchor control. Same preamble as hs_stub -- park on 158, start on the
@ line-159 boundary, TM1 then TM0 -- but no DMA at all: it polls DISPSTAT for
@ the H-blank flag and stamps TM0 the moment it sees it. r7 = TM0.
@ r4 = IOBASE, r10 = TM0BASE, r2 = TM1BASE, r5 = 0x00800000.
fl_stub:
    mov r12, #0
    str r12, [r10]
    str r12, [r2]
1:  ldrh r0, [r4, #6]
    cmp r0, #158
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, #159
    bne 2b
    str r5, [r2]                   @ TM1 first ...
    str r5, [r10]                  @ ... then TM0, the same fixed skew
3:  ldrh r0, [r4, #4]              @ DISPSTAT
    tst r0, #2                     @ H-blank flag
    beq 3b
    ldrh r7, [r10]                 @ TM0 the moment the flag is seen
    mov r0, #0
    str r0, [r10]
    str r0, [r2]
    bx  lr
fl_stub_end:
