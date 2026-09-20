@ payload: what an EMPTY cartridge slot returns to a run of halfword reads
@
@ The first read of a burst returns addr >> 1 and the sequential ones float
@ (section 12). This page reads the shapes an opcode fetch would make -- one
@ nonsequential halfword and three sequential ones after it, from even and
@ odd halfword addresses -- so that slotexec.s can rely on what it finds.
@
@ r0 = the WAITCNT to read under. For each of 8 addresses: +0 four halfwords by DMA3 (N,S,S,S), +8 a lone
@ ldrh of A+2 (N), +10 a lone ldrh of A+4 (N). 12 bytes a row at 0x02008000.
    .arm
    .text
    .global _start
.equ RESULTS, 0x02008000
_start:
    stmfd sp!, {r4-r11, lr}
    ldr r4, =0x04000204
    ldrh r5, [r4]
    strh r0, [r4]                  @ r0 = the WAITCNT to read under
    ldr r6, =RESULTS
    adr r7, table
    mov r8, #8
    ldr r9, =0x040000D4            @ DMA3
1:  ldr r0, [r7], #4
    str r0, [r9]
    str r6, [r9, #4]
    ldr r1, =0x80000004            @ enable, immediate, 16-bit, 4 units
    str r1, [r9, #8]
    nop
    nop
    ldrh r1, [r0, #2]
    strh r1, [r6, #8]
    ldrh r1, [r0, #4]
    strh r1, [r6, #10]
    add r6, r6, #12
    subs r8, r8, #1
    bne 1b
    strh r5, [r4]
    ldr r0, =0x534C4F54
    ldmfd sp!, {r4-r11, lr}
    bx lr
table:
    .word 0x08004000, 0x08004002, 0x0800D000, 0x0800D002
    .word 0x0801C000, 0x08008516, 0x08008006, 0x08008686
    .ltorg
