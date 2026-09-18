@ payload: does a write to HALTCNT halt the CPU, and for how long?
@
@ Built to settle one disagreement and it settled two. halthb.s first halted
@ by writing HALTCNT (0x04000301) directly, and on hardware that did not halt
@ at all -- the CPU ran straight on, on the same scanline. This isolates that
@ from everything else.
@
@ Park on line 100, set a V-count match for line 104, start a free-running
@ TM0, halt, then read TM0 and VCOUNT back. Halting works => about four
@ scanlines, ~4900 cycles, and VCOUNT = 104. Not halting => a couple of dozen
@ cycles and VCOUNT still 100. IME stays clear throughout: HALT exits on
@ IE & IF whether or not a handler would run, and a resident monitor owns the
@ IRQ vector so no handler may run.
@
@ Measured on an AGB SP (docs/playtest-bugs.md section 18):
@
@   method 0, strb to 0x04000301   hardware 11, line 100   -- it does NOT halt
@   method 1, SWI 2 (BIOS Halt)    hardware 4931, line 104
@
@ 0x04000300..0x04000301 answer only to BIOS code, which is why SWI 2 works:
@ the BIOS does the write itself. dingbat honoured it from anywhere and halted
@ where hardware does not, fixed in gba/mmio.nim.
@
@ arg r0 selects the method: 0 = strb HALTCNT, 1 = SWI 2.
@ +0 (w) TM0 after the halt, +4 (w) VCOUNT after the halt, +8 (b) marker 80
    .arm
    .text
    .global _start

.equ IOBASE,  0x04000000
.equ TM0BASE, 0x04000100
.equ RESULTS, 0x02008000

_start:
    stmfd sp!, {r4-r11, lr}
    mov r7, r0                     @ method
    ldr r0, =RESULTS
    mov r1, #0
    str r1, [r0]
    str r1, [r0, #4]
    str r1, [r0, #8]

    mov r4, #IOBASE
    ldr r10, =TM0BASE
    ldr r2, =0x04000200
    ldrh r6, [r2, #8]
    push {r6}
    ldrh r6, [r2]
    push {r6}
    ldrh r6, [r4, #4]
    push {r6}
    ldrh r6, [r10, #2]
    push {r6}

    mov r1, #0
    strh r1, [r2, #8]              @ IME off
1:  ldrh r0, [r4, #6]              @ park on line 100
    cmp r0, #100
    bne 1b
    mov r0, #104                   @ V-count match on 104, its IRQ enabled
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x04                  @ IE = V-count match only
    strh r0, [r2]
    mvn r0, #0
    strh r0, [r2, #2]              @ IF: clear all
    ldr r5, =0x00800000
    str r5, [r10]                  @ TM0 free-running
    cmp r7, #0
    bne 2f
    ldr r3, =0x04000300
    mov r0, #0
    strb r0, [r3, #1]              @ method 0: raw HALTCNT write
    b   3f
2:  swi 0x020000                   @ method 1: BIOS Halt
3:  ldrh r0, [r10]                 @ how long were we out?
    ldr r1, =RESULTS
    str r0, [r1]
    ldrh r0, [r4, #6]              @ and what line are we on now?
    str r0, [r1, #4]
    mov r0, #80
    strb r0, [r1, #8]

    mov r0, #0
    str r0, [r10]
    ldr r2, =0x04000200
    mvn r1, #0
    strh r1, [r2, #2]
    pop {r6}
    strh r6, [r10, #2]
    pop {r6}
    strh r6, [r4, #4]
    pop {r6}
    strh r6, [r2]
    pop {r6}
    strh r6, [r2, #8]
    mov r0, #0
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg
