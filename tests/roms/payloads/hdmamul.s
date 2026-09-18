@ payload: does a DMA grant wait for INTERNAL cycles, or only for the bus?
@
@ The companion to hdmasweep.s, and the other half of the rule behind the
@ H-blank DMA grant. hdmasweep asks whether the grant waits for the CPU's bus
@ access in flight to finish; this asks whether it waits for anything at all
@ when the CPU is busy with no bus access -- an ARM7TDMI multiply spends its
@ internal cycles with the bus idle, so if the two pages disagree the grant
@ tracks the bus, and if they agree it tracks the instruction.
@
@ Everything else is hdmasweep's: same stub, same two timer-freezing DMAs,
@ same pre-delay sweep, same byte layout. The only change is in the poll loop,
@ where `ldr r0, [r3]` from the gamepak becomes `mul r0, r3, r6` on two large
@ operands, which on an ARM7TDMI is four internal cycles and no bus access.
@ WAITCNT is never touched, since nothing here reads the cartridge.
@
@ Read it against hdmasweep's rows:
@   both sawtooth   -> the grant waits for the instruction, bus or not
@   load sawtooth, multiply flat -> it waits for the bus cycle specifically
@   both flat       -> the grant is PPU-timed and neither wait exists
@
@ +0..+26 (14 h) TM1 - TM0 with pre-delay k = 0..13, the H-blank DMA landing
@   while the CPU loops on a multiply
@ +28, +30  unused here: hdmasweep.s carries the 1-cycle IWRAM control, and
@   this page's loop is the comparison rather than a second control
@ +31 (b) marker 54
    .arm
    .text
    .global _start

.equ IOBASE,   0x04000000
.equ TM0BASE,  0x04000100
.equ TM0CNTH,  0x04000102
.equ RESULTS,  0x02008000
.equ HPZERO,   0x03002800          @ the halfword both DMAs move
.equ V10STUB,  0x03002000          @ IWRAM copy of hs_stub, clear of us

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
    ldr r0, =RESULTS               @ EWRAM boots as noise; clear the slot
    mov r1, #0
    mov r2, #0
    mov r3, #0
    mov r12, #0
    stmia r0, {r1-r3, r12}
    add r0, r0, #16
    stmia r0, {r1-r3, r12}

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
    ldrh r6, [r0, #8]              @ IME as we found it: the probe page runs
    push {r6}                      @ under a viewer ROM, we run under a
    mov r1, #0                     @ resident monitor that has to survive us
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
    .irp k, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13
    hs_trial \k, 0x7FFFFFFF        @ a multiplier big enough to cost 4 cycles
    ldr r1, =RESULTS
    strh r7, [r1, #(\k * 2)]
    .endr
    ldr r1, =RESULTS
    mov r0, #54
    strb r0, [r1, #31]

    pop {r6}                       @ timer controls and IME back as found
    ldr r0, =0x04000106
    strh r6, [r0]
    pop {r6}
    strh r6, [r10, #2]
    pop {r6}
    ldr r0, =0x04000200
    strh r6, [r0, #8]
    ldr r0, =0x484D554C            @ 'HMUL': the payload ran to the end
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

@ r1 = DMA0 (H-blank) control, r8 = DMA1 (V-blank) control, r3 = address the
@ loop loads from, r5 = 0x00800000, r6 = k (0..15), r2 = TM1BASE,
@ r4 = IOBASE, r9 = DMA0, r10 = TM0BASE, r11 = DMA1
@ -> r7 = TM1 - TM0 (0xFFFF if either DMA never fired).  No literal pools:
@ the routine is copied to IWRAM.
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
    rsb r6, r6, #15
    add pc, pc, r6, lsl #2         @ skip 15-k sled entries: k+1 NOPs run
    mov r0, r0                     @ (pc reads +8: this word is jumped over)
    .rept 16
    mov r0, r0
    .endr
    mov r6, r3                     @ r3 is the multiplier, not an address
    mov r12, #0
3:  mul r0, r3, r6                 @ four internal cycles, bus idle
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
    sub r7, r7, r0
7:  mov r0, #0
    str r0, [r9, #8]
    str r0, [r11, #8]
    str r0, [r10]
    str r0, [r2]
    bx  lr
hs_stub_end:

