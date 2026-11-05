@ payload: an H-blank or V-blank interrupt taken in dbsuite irqdecomp's poll
@ loop (id_delta), the loop run from EWRAM or IWRAM.
@
@ dbsuite's irqdecomp page run from EWRAM on an AGB SP (a multiboot build
@ with its cases unflagged, 2026-11-04): irqlat-hblank matches dingbat, but
@ irqlat-hblank-haltcnt (console 0x3EF, dingbat 0x3DD), irqlat-vblank
@ (0x9A0 / 0x981) and irqlat-vblank-haltcnt (0x97C / 0x995) do not. Their
@ HALTCNT write does nothing (HALTCNT answers only to the BIOS); it moves
@ where in the poll loop the interrupt lands. So: park on a V-count match
@ (a fixed cycle), d one-cycle NOPs, arm, and run the page's own loop --
@ `ldr r0, [r7, #0x4C]; cmp; bne; subs; bne` -- where the handler's TM0
@ stamp, the page's first act, ends it.
@
@ r0: bits 0-3 d, bit 4 V-blank (else H-blank), bit 5 sp_irq in EWRAM (as
@     the page: SCRATCH + 0xF0), bit 6 the page's HALTCNT store first, bit 7
@     the loop in IWRAM (else EWRAM), bits 8-15 the park line (0 = 100 for
@     H-blank, 158 for V-blank), bits 16-19 c: 4c more cycles of delay (the
@     EWRAM loop's period is ~46 cycles; d + 4c covers it).
@ answer: bits 0-15 handler stamp - the stamp before the IME store (the
@     page's latency), bits 16-23 where the BIOS returns to, as an offset
@     into the loop stub, bits 24-31 0xA5 (the handler ran).
    .arm
    .text
    .global _start
    .include "probe.inc"
.equ SCR, 0x02001000              @ dbsuite's SCRATCH: flag +0x4C, stamp +0x48
.equ EWSTUB, 0x02010000
.equ IWSTUB, 0x03006000

_start:
    probe_enter
    probe_set_handler handler
    ldr r7, =SCR
    mov r0, #0
    str r0, [r7, #0x4C]
    str r0, [r7, #0x48]
    str r0, [r7, #0x44]
    @ the IRQ stack: the page's in EWRAM, or the BIOS's
    mrs r0, cpsr
    msr cpsr_c, #0xD2
    str sp, [r12, #36]
    tst r9, #0x20
    ldrne sp, =SCR + 0xF0
    msr cpsr_c, r0
    @ the loop stub, with or without the HALTCNT store in front
    tst r9, #0x80
    ldreq r6, =EWSTUB
    ldrne r6, =IWSTUB
    str r6, [r12, #40]
    adr r0, stub_halt
    tst r9, #0x40
    adreq r0, stub_loop
    adr r2, stub_end
    mov r1, r6
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    cmp r0, r2
    blt 1b
    @ the park line and the source
    mov r1, r9, lsr #8
    ands r1, r1, #0xFF
    bne 2f
    tst r9, #0x10
    moveq r1, #100
    movne r1, #158
2:  tst r9, #0x10
    moveq r2, #0x10                @ DISPSTAT: H-blank IRQ
    moveq r3, #0x02                @ IE: H-blank
    movne r2, #0x08                @ V-blank IRQ
    movne r3, #0x01                @ IE: V-blank
    mov r0, r1, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x04
    strh r0, [r5]
    mvn r0, #0
    strh r0, [r5, #2]
    ldr r1, =0x00080000            @ the loop's count
    swi 0x020000                   @ park: wake on the V-count match
    strh r2, [r4, #4]              @ the blank's IRQ only
    strh r3, [r5]
    mvn r0, #0
    strh r0, [r5, #2]
    probe_timers_start
    @ bits 16-19 c: 4(c+1) - 1 more cycles, so d + 4c walks 64 phases
    mov r0, r9, lsr #16
    and r0, r0, #15
    add r0, r0, #1
4:  subs r0, r0, #1
    bne 4b
    probe_sled
    mov r0, #1
    ldrh r11, [r10]                @ the stamp before the arming store
    strh r0, [r5, #8]              @ IME: armed
    mov lr, pc
    bx  r6
    @ back: the answer
    mov r0, #0
    strh r0, [r5, #8]
    ldrh r0, [r7, #0x48]
    sub r0, r0, r11
    mov r0, r0, lsl #16
    mov r0, r0, lsr #16
    ldr r1, [r7, #0x44]
    orr r0, r0, r1, lsl #16
    mrs r1, cpsr
    msr cpsr_c, #0xD2
    ldr sp, [r12, #36]
    msr cpsr_c, r1
    probe_leave

handler:                           @ IRQ mode, from the BIOS dispatcher
    ldr r0, =0x04000100
    ldrh r1, [r0]                  @ entry stamp: the first thing, as the page's
    ldr r0, =0x04000200
    mov r2, #0
    strh r2, [r0, #8]
    ldrh r2, [r0, #2]
    strh r2, [r0, #2]
    ldr r0, =SCR
    ldr r2, [r0, #0x4C]
    cmp r2, #0
    bne 3f
    strh r1, [r0, #0x48]
    ldr r2, [sp, #20]              @ where the BIOS returns (lr_irq)
    ldr r3, =probe_vars + 40
    ldr r3, [r3]
    sub r2, r2, r3
    and r2, r2, #0xFF
    orr r2, r2, #0xA500
    str r2, [r0, #0x44]
    mov r2, #1
    str r2, [r0, #0x4C]
3:  bx  lr
    .ltorg

stub_halt:                         @ the page's id_halt, then id_delta's loop
    ldr r0, [pc, #8]
    mov r2, #0                     @ the page's `mov r1, #0`; r1 is the count here
    strb r2, [r0]
    b   stub_loop
    .word 0x04000301
stub_loop:
    ldr r0, [r7, #0x4C]
    cmp r0, #0
    bne 7f
    subs r1, r1, #1
    bne stub_loop
7:  bx  lr
stub_end:
    probe_data
