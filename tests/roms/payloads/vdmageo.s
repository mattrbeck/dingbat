@ payload: the V-blank DMA's grant, against a halted CPU's wake
@
@ halthb.s did this for the H-blank DMA and found the grant's floor already
@ exact. The V-blank side has had no such test, and it badly needs one:
@ VBLANK_DMA_REQUEST_DELAY was set to 1 on the strength of hdmamul.s and
@ hdmasweep.s, which report the V-blank DMA's write MINUS the H-blank DMA's --
@ a difference, blind to any shift common to both -- together with an absolute
@ stamp from a page whose anchor later turned out to be worth seven cycles of
@ nothing (docs/playtest-bugs.md sections 15 and 17). A constant fitted to
@ those two is exactly the shape of thing that needs re-checking without an
@ anchor.
@
@ Same construction as halthb.s. A V-count match interrupt on line 159 fixes
@ the line, IME stays clear so no handler runs, and HALT still exits on
@ IE & IF. TM0 and TM1 start two instructions apart just after that wake; DMA0
@ is armed with V-blank timing onto TM1CNT_H, so the V-blank DMA's own write
@ freezes TM1. Then we halt again on the V-blank interrupt.
@
@   W  TM0 the instant the CPU resumes from HALT on the V-blank IRQ
@   D  TM1, frozen by the V-blank DMA's own write to TM1CNT_H
@
@ Both are hardware events with no software sampling between them, and the CPU
@ is halted when the V-blank arrives, so the bus is idle and the grant has
@ nothing to wait on: this is the V-blank grant's floor. W - D is anchor-free.
@ W must not vary with k -- that is the proof the entry is controlled.
@
@ +0 + k*4 (w) (W << 16) | D for k = 0..13
@ +56     (b)  marker 81
@ D = 0xFFFF means the DMA never fired; W = 0xFFFF means the wake never came.
    .arm
    .text
    .global _start

.equ IOBASE,   0x04000000
.equ TM0BASE,  0x04000100
.equ TM1BASE,  0x04000104
.equ TM1CNTH,  0x04000106
.equ RESULTS,  0x02008000
.equ HPZERO,   0x03002800          @ the halfword the DMA moves
.equ VGSTUB,   0x03002000          @ IWRAM copy of vg_stub, clear of us

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r0, =RESULTS               @ EWRAM boots as noise; clear the slots
    mov r1, #0
    mov r2, #0
    mov r3, #0
    mov r12, #0
    mov r7, #4                     @ 4 x 16 = 64, covers +0..+63
1:  stmia r0!, {r1-r3, r12}
    subs r7, r7, #1
    bne 1b

    ldr r0, =vg_stub               @ the stub runs from IWRAM
    ldr r1, =VGSTUB
    mov r2, #((vg_stub_end - vg_stub) / 4)
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b

    mov r4, #IOBASE
    ldr r10, =TM0BASE
    ldr r11, =TM1BASE
    ldr r9, =0x040000B0            @ DMA0
    ldr r0, =0x04000200            @ IE / IF / IME
    ldrh r6, [r0, #8]              @ everything we are about to disturb, saved:
    push {r6}                      @ a resident monitor has to survive us
    ldrh r6, [r0]
    push {r6}
    mov r1, #0
    strh r1, [r0, #8]              @ IME off before touching IE
    ldrh r6, [r4, #4]              @ DISPSTAT
    push {r6}
    ldrh r6, [r10, #2]             @ both timer controls
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
    ldr r8, =0x91400001            @ DMA0: enable, vblank, 16-bit, fixed, 1
    .irp k, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13
    mov r6, #\k
    ldr r12, =VGSTUB
    mov lr, pc
    bx  r12
    ldr r1, =RESULTS
    str r7, [r1, #(\k * 4)]
    .endr

    ldr r1, =RESULTS
    mov r0, #81
    strb r0, [r1, #56]

    mov r0, #0                     @ everything back as we found it
    str r0, [r9, #8]
    pop {r6}
    strh r6, [r11, #2]
    pop {r6}
    strh r6, [r10, #2]
    pop {r6}
    strh r6, [r4, #4]
    ldr r0, =0x04000200
    mvn r1, #0
    strh r1, [r0, #2]              @ IF: clear anything we provoked
    pop {r6}
    strh r6, [r0]                  @ IE
    pop {r6}
    strh r6, [r0, #8]              @ IME last
    ldr r0, =0x56445F54            @ 'VD_T': the payload ran to the end
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

@ r4 = IOBASE, r10 = TM0BASE, r11 = TM1BASE, r9 = DMA0, r6 = k (0..13),
@ r5 = 0x00800000, r8 = DMA0 control word.
@ -> r7 = (W << 16) | D.
@ No literal pools and no constants wider than an immediate: the routine is
@ copied to IWRAM, and every address is built from r4.
vg_stub:
    add r2, r4, #0x200             @ IE at [r2], IF at [r2,#2], IME at [r2,#8]
    mov r12, #0
    str r12, [r9, #8]              @ DMA0 off
    str r12, [r10]                 @ TM0 off, reload 0
    str r12, [r11]                 @ TM1 off, reload 0
    strh r12, [r2, #8]             @ IME off: no handler, but HALT still wakes
                                   @ on IE & IF, which is what we want
    mov r0, #159                   @ DISPSTAT: V-count match on line 159 ...
    mov r0, r0, lsl #8
    orr r0, r0, #0x20              @ ... and enable its interrupt
    strh r0, [r4, #4]
    mov r0, #0x04                  @ IE = V-count match only
    strh r0, [r2]
    mvn r0, #0
    strh r0, [r2, #2]              @ IF: clear everything pending
    swi 0x020000                   @ HALT. We resume on the line we chose, at
                                   @ a cycle the PPU picked, not one a poll
                                   @ happened to sample. Through the BIOS: a
                                   @ byte write to HALTCNT is ignored outside
                                   @ BIOS code on hardware (section 18).
    add r2, r4, #0x200             @ the SWI clobbers r0-r3

    str r5, [r10]                  @ TM0: the clock, never stopped
    str r5, [r11]                  @ TM1: the same clock, a fixed skew behind
    str r8, [r9, #8]               @ arm the V-blank DMA
    mov r0, #0x08                  @ DISPSTAT: V-blank interrupt, match off
    strh r0, [r4, #4]
    mov r0, #0x01                  @ IE = V-blank only
    strh r0, [r2]
    mvn r0, #0
    strh r0, [r2, #2]              @ IF clear again: the match bit is still up

    rsb r6, r6, #31
    add pc, pc, r6, lsl #2         @ skip 31-k sled entries: k+1 NOPs run
    mov r0, r0                     @ (pc reads +8: this word is jumped over)
    .rept 32
    mov r0, r0
    .endr

    swi 0x020000                   @ HALT again, with the bus idle. Nothing is
                                   @ in flight for the grant to wait on.
    ldrh r7, [r10]                 @ W: the cycle the CPU resumed

    mov r12, #0
1:  ldrh r0, [r11, #2]             @ TM1CNT_H: has the DMA frozen it yet?
    tst r0, #0x80
    beq 2f
    add r12, r12, #1
    cmp r12, #0x4000
    bcc 1b
    mvn r1, #0                     @ the DMA never fired
    b   3f
2:  ldrh r1, [r11]                 @ D: the cycle the DMA wrote TM1CNT_H
3:  add r2, r4, #0x200             @ the SWI clobbers r0-r3
    mov r0, #0
    str r0, [r9, #8]               @ DMA0 off before the next V-blank
    str r0, [r10]                  @ both timers off, as we found them
    str r0, [r11]
    mov r0, #0
    strh r0, [r4, #4]              @ DISPSTAT interrupts off
    strh r0, [r2]                  @ IE off
    mov r1, r1, lsl #16            @ D, masked to its low halfword
    mov r1, r1, lsr #16
    orr r7, r1, r7, lsl #16        @ (W << 16) | D
    bx  lr
vg_stub_end:
