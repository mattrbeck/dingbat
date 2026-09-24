@ dmaobus2.s -- dbsuite copy of the link-rig payload tmp/pl/dmaobus2.s the
@ parent session ran on the AGB SP on 2026-09-24 (03:48 and 04:25 UTC).
@ Changed from that file: the EWRAM addresses 0x02030000/0x02032000/
@ 0x02034000 became 0x0200C000/0x0200E000/0x0200F000 (dbsuite's multiboot
@ code lives up there); alignment below 4 KB is kept, so every snippet
@ fetches with the same address bits.
@
@ WHAT: what the data bus holds when an immediate DMA from unmapped IO
@ starts, after one instruction of each kind -- when the DMA starts (+2
@ after the enable, ahead of the next fetch at an instruction boundary) and
@ which lanes each memory drives (IWRAM only its own; EWRAM a halfword on
@ both halves).
@ PROVENANCE: AGB SP via tools/hwlink, 2026-09-24 (commits 813d2424f,
@ 83aa03913):
@   IWRAM  0 31033104  1 46C03344  2 112246C0  3 46C04644  4 46C033C0
@          5 462246C0  6 11C046C0  7 46C046C0  8 11223344  9 E2811004
@          10 55665566  11 11223344  12 11220000
@   EWRAM  0x100 31033103, 0x101-0x108 46C046C0, 0x109 E2811003,
@          0x10A 46C046C0, 0x10B E1A00000, 0x10C E1A00000

@ DMA1 immediate, 1 word 32-bit from 0x04001000 (unmapped IO) to EWRAM
@ 0x0200C000, armed by `str r2,[r3]`; what follows varies.
@ r0 bits 0..7 variant, bit 8: run the snippet from an EWRAM copy
@  0 Thumb: str; add r1,#1..#5 (opcodes 3101..3105)
@  1 Thumb: str; ldrh [iw+0]   2 ldrh [iw+2]   (iw word = 0x11223344, IWRAM)
@  3..6 Thumb: str; ldrb [iw+0..3]
@  7 Thumb: str; str r6,[r7] (0xCAFEBABE to EWRAM)
@  8 Thumb: str; ldr [iw]
@  9 ARM:   str; add r1,r1,#1..#5 (E2811001..)
@ 10 Thumb: str; ldrh [ew+0], ew halfwords 0x5566 0x7788 (EWRAM) (control)
@ answer: the DMA's word
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r9, r0
    ldr r4, =0x0200C000
    ldr r0, =0xDEADBEEF
    str r0, [r4]
    ldr r7, =0x0200E000
    ldr r6, =0xCAFEBABE
    ldr r0, =0x77885566
    str r0, [r7, #0x10]
    mov r3, #0x04000000
    add r3, r3, #0xC4
    mov r0, #0
    str r0, [r3]
    ldr r0, =0x04001000
    str r0, [r3, #-8]
    str r4, [r3, #-4]
    ldr r2, =0x85000001
    adr r5, iwdata
    and r8, r9, #0xFF
    adr r0, snippets
    add r0, r0, r8, lsl #6
    tst r9, #0x100
    beq 2f
    ldr r1, =0x0200F000            @ copy the 64-byte snippet to EWRAM
    mov r10, r1
    mov r11, #16
1:  ldr r12, [r0], #4
    str r12, [r1], #4
    subs r11, r11, #1
    bne 1b
    mov r0, r10
2:  cmp r8, #9
    cmpne r8, #11
    cmpne r8, #12
    addne r0, r0, #1               @ Thumb unless ARM variants 9, 11, 12
    mov r1, #0
    mov lr, pc
    bx r0
    ldr r0, [r4]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
    .align 2
iwdata: .word 0x11223344
    .align 6
snippets:
    .thumb
s0: str r2, [r3]
    add r1, #1
    add r1, #2
    add r1, #3
    add r1, #4
    add r1, #5
    nop
    nop
    bx lr
    .align 6
s1: str r2, [r3]
    ldrh r0, [r5, #0]
    nop
    nop
    nop
    bx lr
    .align 6
s2: str r2, [r3]
    ldrh r0, [r5, #2]
    nop
    nop
    nop
    bx lr
    .align 6
s3: str r2, [r3]
    ldrb r0, [r5, #0]
    nop
    nop
    nop
    bx lr
    .align 6
s4: str r2, [r3]
    ldrb r0, [r5, #1]
    nop
    nop
    nop
    bx lr
    .align 6
s5: str r2, [r3]
    ldrb r0, [r5, #2]
    nop
    nop
    nop
    bx lr
    .align 6
s6: str r2, [r3]
    ldrb r0, [r5, #3]
    nop
    nop
    nop
    bx lr
    .align 6
s7: str r2, [r3]
    str r6, [r7]
    nop
    nop
    nop
    bx lr
    .align 6
s8: str r2, [r3]
    ldr r0, [r5]
    nop
    nop
    nop
    bx lr
    .align 6
    .arm
s9: str r2, [r3]
    add r1, r1, #1
    add r1, r1, #2
    add r1, r1, #3
    add r1, r1, #4
    add r1, r1, #5
    mov r0, r0
    bx lr
    .align 6
    .thumb
s10: str r2, [r3]
    ldrh r0, [r7, #0x10]
    nop
    nop
    nop
    bx lr
    .align 6
    .arm
s11: str r2, [r3]
    ldr r0, [r5]
    mov r0, r0
    mov r0, r0
    bx lr
    .align 6
s12: str r2, [r3]
    ldrh r0, [r5, #2]
    mov r0, r0
    mov r0, r0
    bx lr
    .align 6
