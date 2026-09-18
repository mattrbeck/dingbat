@ obuswin.s — what actually ends the post-DMA open-bus window?
@
@ obusprobe.s measured the window as "exactly one instruction": the read
@ immediately after the DMA's enable store sees an opcode (the burst has not
@ run), the next one sees the DMA's word, the one after that is back to an
@ opcode. dingbat holds it one instruction too long. But "one instruction" is
@ a description of three samples, not a mechanism, and the mGBA suite's last
@ red row turns on the mechanism: docs/mgba-suite-verdicts.md reasons that on
@ hardware "the DMA's word survives on the data bus only until the next
@ gamepak fetch", so in a ROM-resident loop the window is a few cycles in the
@ middle of an instruction rather than a whole instruction, and concludes
@ that closing the row needs the core to dispatch a DMA part-way through an
@ instruction.
@
@ That conclusion rests on the quoted premise, which nothing has measured.
@ If what ends the window is the next ACCESS rather than the next instruction
@ boundary, the rule is implementable where dingbat already counts accesses,
@ and no sub-instruction dispatch is needed. If it is specifically the next
@ GAMEPAK access, that is better still: it explains why the window looks a
@ whole instruction wide from IWRAM (nothing here touches the gamepak) and
@ only a few cycles wide from ROM (every opcode fetch does).
@
@ So: same DMA every time, and vary only what happens between it and the
@ unmapped read. The intervening work is chosen to separate three things that
@ "one instruction" cannot -- instruction count, cycle count, and whether the
@ bus was touched at all:
@
@   +0   nothing                     the burst has not run yet
@   +4   one 1-cycle NOP             the known-good window
@   +8   two 1-cycle NOPs            the known-closed window
@   +12  one MUL                     1 instruction, ~4 cycles, NO bus access
@   +16  one LDR from IWRAM          1 instruction, an internal bus access
@   +20  one LDR from EWRAM          1 instruction, a slower internal access
@   +24  one LDR from the GAMEPAK    1 instruction, an EXTERNAL access
@   +28  NOP then a gamepak LDR      the gamepak access arrives later
@   +32  a gamepak LDR then a NOP    the gamepak access arrives earlier
@   +36  one LDMIA of 4 registers    1 instruction, many internal accesses
@   +40  the DMA's last word, for comparison
@   +44  marker 'OBWN'
@
@ Reading it: if +12/+16/+20/+36 all hold the DMA word while +24 does not,
@ the window ends at the next gamepak access and the suite's premise is
@ right. If +8 is closed but +12 and +36 are open, the window is not a cycle
@ count either. If everything past +4 is closed, "one instruction" is the
@ whole rule and the premise is wrong.
@
@ Pure reads and a DMA into scratch EWRAM: nothing here can leave the console
@ anywhere but where it started.
    .arm
    .text
    .global _start

.equ UNMAP,    0x10000000          @ past the gamepak: nothing answers here
.equ RESULTS,  0x02008000
.equ SCRATCH,  0x02009000
.equ GAMEPAK,  0x08000000
.equ DMA3SAD,  0x040000D4
.equ LASTWORD, 0xDEADBEE3
.equ MARKER,   0x4F42574E          @ 'OBWN'

@ r7 = unmapped, r10 = results, r11 = EWRAM scratch, r12 = gamepak,
@ r8 = an IWRAM buffer, r4/r5 = large MUL operands.
.macro dma_start
    ldr r0, =dma_source
    ldr r1, =SCRATCH
    ldr r2, =DMA3SAD
    str r0, [r2, #0]
    str r1, [r2, #4]
    ldr r0, =0x84000004            @ enable, 32-bit, immediate, 4 words
    str r0, [r2, #8]
.endm

.macro dw_read slot
    ldr r0, [r7]                   @ the unmapped read under test
    str r0, [r10, #\slot]
.endm

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r7,  =UNMAP
    ldr r10, =RESULTS
    ldr r11, =SCRATCH
    ldr r12, =GAMEPAK
    ldr r8,  =iwbuf
    ldr r4,  =0x12345678           @ large, so the MUL takes its 4 internal
    ldr r5,  =0x9ABCDEF0           @ cycles rather than an early-terminated 1

    dma_start
    dw_read 0

    dma_start
    mov r0, r0
    dw_read 4

    dma_start
    mov r0, r0
    mov r0, r0
    dw_read 8

    dma_start
    mul r3, r4, r5                 @ internal cycles only, the bus stays idle
    dw_read 12

    dma_start
    ldr r3, [r8]                   @ IWRAM
    dw_read 16

    dma_start
    ldr r3, [r11]                  @ EWRAM
    dw_read 20

    dma_start
    ldr r3, [r12]                  @ gamepak: an external access
    dw_read 24

    dma_start
    mov r0, r0
    ldr r3, [r12]
    dw_read 28

    dma_start
    ldr r3, [r12]
    mov r0, r0
    dw_read 32

    dma_start
    ldmia r8, {r0, r1, r2, r3}     @ four internal accesses, one instruction
    dw_read 36

    ldr r0, =LASTWORD
    str r0, [r10, #40]
    ldr r0, =MARKER
    str r0, [r10, #44]
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

    .align 2
dma_source:
    .word 0x11111111
    .word 0x22222222
    .word 0x33333333
    .word LASTWORD
iwbuf:
    .word 0x55555555
    .word 0x66666666
    .word 0x77777777
    .word 0x88888888
