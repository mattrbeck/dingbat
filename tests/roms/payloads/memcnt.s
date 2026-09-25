@ payload: MEMCNT (0x04000800) bit 5 (board WRAM enable) and bit 0 (swap)
@
@ The monitor lives in EWRAM below 0x02004000 and the payload in IWRAM at
@ 0x03000000, so board WRAM is only ever switched off by IWRAM code that
@ touches nothing of the monitor's and switches it back on before it
@ returns; the words it uses are A at 0x02016000 (whose 32K alias is IWRAM
@ 0x03006000, holding B) and D at 0x02016004 (alias 0x03006004). The swap
@ bit is set only by a routine copied into OBJ VRAM, which the swap cannot
@ move, and nothing touches the stack while it is set. MEMCNT's wait field
@ is kept as found.
@
@ On an AGB SP (2026-09-25): 0 B, 1 A, 2 C, 3 D, 4 3 cycles (5: 8, 6: 3),
@ 7 B -- board WRAM off, 02xxxxxx is the chip WRAM, mirrored every 32K, at
@ its timing, and the board WRAM keeps its contents -- and 13 0x0D000020
@ (cells 0-7 and 13 are laws). The swap: 8 reads what 9 does (0xE3A02004,
@ the BIOS's protected latch: 02000000 is the BIOS, still read-protected
@ from VRAM code), 10 A and 11 B (00/01 are board and chip WRAM), 12 the
@ open bus (the prefetched opcode; 0xE12FFF1E, `bx lr`, before the swap
@ variants called SWI 8 and the routine grew).
@
@ Again (2026-09-25, all cells laws): 8, 9 0xE3A02004, 10 A, 11 B, 12
@ 0x11A0E00F (the `movne lr, pc` two ahead of the load), and the BIOS
@ answers by the memory the newest fetch came from, not by its address:
@ 14, 15 and 16 read the latch (0xE3A02004) from code at 01xxxxxx,
@ 00xxxxxx and in VRAM, and 17 reads the BIOS's own word (0xEA000042) from
@ 01FFFFF8, whose r15 is 02000000. (A HALTCNT write goes by address:
@ haltswap.s.)
@
@ r0 = variant; answer:
@   0  0x02016000 read with board WRAM off           (B if it aliases IWRAM)
@   1  0x02016000 read after it is back on            (A)
@   2  0x03006004 after 0x02016004 was written (C) while off
@   3  0x02016004 after that, back on                 (D if the write missed it)
@   4  TM0 around an ldr from 0x02016000, off   5 on   6 an IWRAM ldr
@   7  0x02026000 read while off                      (B if IWRAM mirrors)
@   8  0x02000000 read with the swap on (from VRAM code)
@   9  0x00000000 read, no swap (from the same VRAM code)
@  10  0x00016000 with the swap on (A if board WRAM is there)
@  11  0x01006000 with the swap on (B if chip WRAM is there)
@  12  0x03006000 with the swap on
@  13  MEMCNT as found
@  14  0x02000018 with the swap on, read by code in the chip WRAM (01xxxxxx)
@  15  the same, by code in the board WRAM (00016100)
@  16  the same, by the VRAM code (the latch, as 8)
@  17  the same, by code in the chip WRAM at 01FFFFF8, whose newest fetch
@      (r15) is the BIOS's first word at 02000000
@
@ Every swap variant (8-12, 14-17) first calls SWI 8 so the BIOS latch is
@ what a SWI leaves (0xE3A02004) wherever the payload runs, and runs with
@ the CPU's IRQs masked: the exception vectors are RAM while the swap is on.
    .arm
    .text
    .global _start
.equ VR, 0x06017F00
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    ldr r4, =0x04000800
    ldr r5, [r4]                   @ MEMCNT as found
    bic r6, r5, #0x21              @ board WRAM off, no swap
    orr r7, r5, #0x20              @ on
    bic r7, r7, #0x01
    ldr r8, =0x02016000
    ldr r9, =0x03006000
    ldr r0, =0x01234567
    str r0, [r8]                   @ A
    ldr r0, =0x11223344
    str r0, [r8, #4]               @ D
    ldr r0, =0x89ABCDEF
    str r0, [r9]                   @ B
    ldr r0, =0x76543210
    str r0, [r9, #4]
    ldr r10, =0x04000100
    mov r0, #0
    str r0, [r10]
    cmp r11, #13
    moveq r0, r5
    beq done
    cmp r11, #8
    bhs swap
    ldr r12, =table
    ldr pc, [r12, r11, lsl #2]
table:
    .word v0, v1, v2, v3, v4, v5, v6, v7
v0: str r6, [r4]
    ldr r0, [r8]
    str r7, [r4]
    b done
v1: str r6, [r4]
    ldr r0, [r8]
    str r7, [r4]
    ldr r0, [r8]
    b done
v2: ldr r1, =0x55AA55AA
    str r6, [r4]
    str r1, [r8, #4]
    str r7, [r4]
    ldr r0, [r9, #4]
    b done
v3: ldr r1, =0x55AA55AA
    str r6, [r4]
    str r1, [r8, #4]
    str r7, [r4]
    ldr r0, [r8, #4]
    b done
v4: mov r2, r8
    str r6, [r4]
    b time
v5: mov r2, r8
    str r7, [r4]
    b time
v6: mov r2, r9
time:
    ldr r3, =0x00800000
    str r3, [r10]
    ldr r1, [r2]
    ldrh r0, [r10]
    str r7, [r4]
    b done
v7: ldr r2, =0x02026000
    str r6, [r4]
    ldr r0, [r2]
    str r7, [r4]
    b done
swap:
    @ the BIOS latch as every SWI leaves it, whatever ran before: 8, 9
    @ and 16 read it, and a cartridge wrapper has not been through a SWI
    mov r0, #4
    swi 0x080000                   @ Sqrt
    @ copy the routine into VRAM
    adr r0, vr
    ldr r1, =VR
    mov r2, #9
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b
    @ and the read into board WRAM (15), clear of A and D
    adr r0, cw
    ldr r1, =0x02016100
    ldr r3, [r0]
    str r3, [r1]
    ldr r3, [r0, #4]
    str r3, [r1, #4]
    @ and into the chip WRAM's last two words (17), where the BIOS keeps
    @ its IRQ flags and vector: those wait in board WRAM meanwhile
    ldr r0, =0x03007FF8
    ldmia r0, {r1, r2}
    ldr r12, =0x02016200
    stmia r12, {r1, r2}
    adr r12, cw
    ldmia r12, {r1, r2}
    stmia r0, {r1, r2}
    orr r1, r7, #1                 @ swap on (board WRAM on)
    mov r2, r7
    cmp r11, #9
    moveq r1, r7                   @ 9: no swap
    ldr r12, =addrs
    sub r3, r11, #8
    ldr r3, [r12, r3, lsl #2]
    @ where the read runs: in VRAM, or (14) the chip WRAM at 01xxxxxx, or
    @ (15) the board WRAM at 00xxxxxx
    mov r9, #0
    cmp r11, #14
    ldreq r9, =cw - 0x02000000
    cmp r11, #15
    ldreq r9, =0x00016100
    cmp r11, #17
    ldreq r9, =0x01FFFFF8
    mov r0, r4
    mrs r8, cpsr                   @ no interrupt while the vectors are RAM
    orr r12, r8, #0x80
    msr cpsr_c, r12
    ldr r12, =VR
    mov lr, pc
    bx r12
    msr cpsr_c, r8
    ldr r12, =0x02016200
    ldmia r12, {r1, r2}
    ldr r12, =0x03007FF8
    stmia r12, {r1, r2}
    mov r0, r3
    str r7, [r4]
done:
    str r5, [r4]                   @ MEMCNT as found
    mov r1, #0
    str r1, [r10]
    ldmfd sp!, {r4-r11, lr}
    bx lr
addrs:
    .word 0x02000000, 0x00000000, 0x00016000, 0x01006000, 0x03006000
    .word 0, 0x02000018, 0x02000018, 0x02000018, 0x02000018
    .align 2
vr: str r1, [r0]
    cmp r9, #0
    ldreq r3, [r3]
    movne r12, lr
    movne lr, pc
    bxne r9
    movne lr, r12
    str r2, [r0]
    bx lr
cw: ldr r3, [r3]
    bx lr
    .ltorg
