@ payload: a HALTCNT write from RAM code with MEMCNT's swap (bit 0) on
@
@ png183 memory t110/t111: with the swap on, 00xxxxxx is the board WRAM,
@ 01xxxxxx the chip WRAM and 02xxxxxx the BIOS (memcnt.s cells 8-12). Does
@ a `strb` to HALTCNT (0x04000301) halt the CPU when it runs from the chip
@ WRAM at 01xxxxxx? The test says yes from 01FFFFF0 (r15 01FFFFF8) and no
@ from 01FFFFF8 (r15 02000000, the BIOS's first word).
@
@ The store runs as `strb r2, [r10]; bx lr`, copied into the chip WRAM and
@ called at its 01xxxxxx address from a routine in OBJ VRAM, which the swap
@ cannot move; nothing touches the stack while the swap is on, and the CPU's
@ IRQs are masked with IME clear, so a halt ends on the V-blank that IE
@ (V-blank only) and DISPSTAT then allow, and nothing is dispatched. The
@ call is made on line 0, so the answer is VCOUNT after it: 160 if the
@ store halted the CPU, 0 if it did not.
@
@ Every IO register it writes, and the BIOS's words at 03007FF0-03007FFF
@ that variants 1 and 2 land on, go back as found.
@
@ On an AGB SP (2026-09-25, laws): 0 160, 1 0, 2 160, 3 0 -- the write
@ answers to where the newest fetch was made, below 02000000, whatever
@ memory is there, as the test has it; the BIOS's read protection does not
@ (memcnt.s cells 14-17).
@
@ r0 = variant; answer VCOUNT after the store:
@   0  from 01007000 under the swap             (r15 01007008)
@   1  from 01FFFFF8 under the swap             (r15 02000000)
@   2  from 01FFFFF0 under the swap             (r15 01FFFFF8)
@   3  from 03007000, no swap (control: IWRAM code does not halt)
    .arm
    .text
    .global _start
.equ VR, 0x06017F00
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    mov r4, #0x04000000
    add r5, r4, #0x200
    ldrh r0, [r5, #8]              @ IME
    ldrh r1, [r5]                  @ IE
    ldrh r2, [r4, #4]              @ DISPSTAT
    stmfd sp!, {r0-r2}
    ldr r12, =0x03007FF0           @ the BIOS's words, kept in board WRAM
    ldmia r12, {r0-r3}
    ldr r12, =0x02016300
    stmia r12, {r0-r3}
    mov r0, #0
    strh r0, [r5, #8]              @ IME off
    mov r0, #1
    strh r0, [r5]                  @ IE: V-blank
    ldrh r0, [r4, #4]
    orr r0, r0, #0x08
    strh r0, [r4, #4]              @ DISPSTAT: V-blank IRQ
    @ the store, into the chip WRAM
    ldr r12, =places
    ldr r3, [r12, r11, lsl #3]     @ where it goes, as IWRAM
    add r12, r12, r11, lsl #3
    ldr r9, [r12, #4]              @ where it is called
    adr r0, hc
    ldr r1, [r0]
    str r1, [r3]
    ldr r1, [r0, #4]
    str r1, [r3, #4]
    @ the routine, into VRAM
    adr r0, vr
    ldr r1, =VR
    mov r2, #6
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b
    ldr r6, =0x04000800
    ldr r7, [r6]                   @ MEMCNT as found
    bic r7, r7, #0x01
    orr r7, r7, #0x20              @ board WRAM on, no swap
    orr r8, r7, #0x01              @ the swap
    cmp r11, #3
    moveq r8, r7                   @ 3: no swap
    ldr r10, =0x04000301
    mov r2, #0
    mrs r1, cpsr
    stmfd sp!, {r1}
    orr r1, r1, #0x80              @ no interrupt while the vectors are RAM
    msr cpsr_c, r1
    mov r1, #1
2:  ldrh r0, [r4, #6]              @ line 0
    cmp r0, #0
    bne 2b
    strh r1, [r5, #2]              @ acknowledge V-blank
    ldr r12, =VR
    mov lr, pc
    bx r12
    ldrh r0, [r4, #6]              @ the answer
    ldmfd sp!, {r1}
    mov r3, #1
    strh r3, [r5, #2]              @ acknowledge the V-blank again
    msr cpsr_c, r1
    mov r7, r0
    ldr r12, =0x02016300
    ldmia r12, {r0-r3}
    ldr r12, =0x03007FF0
    stmia r12, {r0-r3}
    mov r0, r7
    ldmfd sp!, {r1-r3}             @ IME, IE, DISPSTAT
    strh r2, [r5]
    strh r3, [r4, #4]
    strh r1, [r5, #8]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .align 2
places:
    .word 0x03007000, 0x01007000
    .word 0x03007FF8, 0x01FFFFF8
    .word 0x03007FF0, 0x01FFFFF0
    .word 0x03007000, 0x03007000
hc: strb r2, [r10]
    bx lr
vr: str r8, [r6]                   @ the swap on (3: unchanged)
    mov r12, lr
    mov lr, pc
    bx r9
    str r7, [r6]                   @ off again
    bx r12
    .ltorg
