@ dmaobus.s -- dbsuite copy of the link-rig payload tmp/pl/dmaobus.s the
@ parent session ran on the AGB SP on 2026-09-24 (01:53 UTC).  Changed from
@ that file: its EWRAM data and destination moved from 0x02031000/0x02030000
@ to 0x0200D000/0x0200C000 (dbsuite's multiboot code lives up there); the
@ addresses keep their low 12 bits, the code in IWRAM is laid out the same.
@
@ WHAT: an immediate DMA reading unmapped IO (0x04001000) gets whatever is
@ on the data bus -- the CPU's last load if it came after the last opcode
@ fetch.  A 16-bit memory puts a halfword on both halves and a byte on all
@ four lanes.
@ WHY: an emulator that returns 0 (or the last DMA word) for a DMA from
@ unmapped memory fails alyosha-tas Bus/* and these.
@ PROVENANCE: AGB SP via tools/hwlink, 2026-09-24 (commit 4acee4b9d):
@   arg 0 ldrsh [odd] -> FF24FF24   1 ldrh -> FF24FF24   2 ldrb -> FFFFFFFF
@   3 no load (nops)  -> 46C046C0   4 ldr  -> 11223344

@ DMA1 immediate, 1 word 32-bit, src 0x04001000 (unmapped IO, fixed),
@ dst EWRAM 0x0200C000, armed by a Thumb str from IWRAM, then a load:
@ r0 = 0 ldrsh from 0x0200D005 (halfword there 0xFF24)
@      1 ldrh from 0x0200D004   2 ldrb from 0x0200D005
@      3 no load (nops)         4 ldr from 0x0200D008 (0x11223344)
@ answer: the word the DMA wrote
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r7, r0
    ldr r4, =0x0200D000
    ldr r0, =0xFF24
    strh r0, [r4, #4]
    ldr r0, =0x11223344
    str r0, [r4, #8]
    ldr r4, =0x0200C000
    ldr r0, =0xDEADBEEF
    str r0, [r4]
    mov r3, #0x04000000
    add r3, r3, #0xC4              @ DMA1CNT
    mov r0, #0
    str r0, [r3]
    ldr r0, =0x04001000
    str r0, [r3, #-8]              @ SAD
    str r4, [r3, #-4]              @ DAD
    ldr r2, =0x85000001
    ldr r5, =0x0200D005
    adr r0, thumbs
    add r0, r0, r7, lsl #5
    add r0, r0, #1
    mov lr, pc
    bx r0
    ldr r0, [r4]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
    .thumb
    .align 5
thumbs:
t0: mov r0, #0
    str r2, [r3]
    ldrsh r0, [r5, r0]
    nop
    nop
    nop
    bx lr
    .align 5
t1: mov r0, #1
    neg r0, r0
    str r2, [r3]
    ldrh r0, [r5, r0]
    nop
    nop
    nop
    bx lr
    .align 5
t2: mov r0, #0
    str r2, [r3]
    ldrb r0, [r5, r0]
    nop
    nop
    nop
    bx lr
    .align 5
t3: mov r0, #0
    str r2, [r3]
    nop
    nop
    nop
    nop
    bx lr
    .align 5
t4: mov r0, #3
    str r2, [r3]
    ldr r0, [r5, r0]
    nop
    nop
    nop
    bx lr
