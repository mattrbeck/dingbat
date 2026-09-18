@ obuswint.s — the post-DMA window measured from THUMB code.
@
@ obuswin.s measured the window from ARM code in IWRAM and found it one
@ cycle narrower than dingbat models: the read one 1-cycle NOP after the
@ burst sees the DMA's word, the read two NOPs after does not. Applying that
@ correction costs the mGBA suite two rows -- `DMA Prefetch Read` stops
@ seeing a word it should see, and `DMA Prefetch Break` stops seeing one
@ altogether -- and that suite's loop is THUMB code in ROM, not ARM code in
@ IWRAM.
@
@ So before concluding that the two cannot be reconciled, check the axis that
@ can actually be reached here. The rig cannot run code from the gamepak, but
@ it can run Thumb from IWRAM, which separates the instruction set from the
@ memory. If Thumb puts the boundary one cycle earlier than ARM does, the
@ correction is conditional and both the measurement and the suite can be
@ right. If Thumb lands on the same boundary, the difference is the memory
@ the code runs from, and only a cartridge can settle it.
@
@ Same DMA as obuswin.s, same trials, in Thumb. Registers are set up in ARM
@ so the trial itself is stores and NOPs only, and the DMA's three register
@ writes are the last thing before the NOPs in every row.
@
@   +0  Thumb, no NOP between the burst and the read
@   +4  Thumb, one 1-cycle NOP        (ARM: sees the DMA word)
@   +8  Thumb, two NOPs               (ARM: sees an opcode)
@   +12 Thumb, three NOPs
@   +16 the DMA's last word, for comparison
@   +20 marker 'OBWT'
    .arm
    .text
    .global _start

.equ UNMAP,    0x10000000
.equ RESULTS,  0x02008000
.equ SCRATCH,  0x02009000
.equ DMA3SAD,  0x040000D4
.equ LASTWORD, 0xDEADBEE3
.equ MARKER,   0x4F425754          @ 'OBWT'

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r7, =UNMAP
    ldr r5, =RESULTS
    ldr r1, =dma_source
    ldr r2, =SCRATCH
    ldr r3, =DMA3SAD
    ldr r4, =0x84000004            @ enable, 32-bit, immediate, 4 words

    ldr r0, =thumb_part + 1
    mov lr, pc
    bx  r0

    ldr r0, =LASTWORD
    str r0, [r5, #16]
    ldr r0, =MARKER
    str r0, [r5, #20]
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

    .align 2
dma_source:
    .word 0x11111111
    .word 0x22222222
    .word 0x33333333
    .word LASTWORD

@ r1 = source, r2 = destination, r3 = DMA3SAD, r4 = the enable word,
@ r5 = results, r7 = the unmapped address. Only r0 is clobbered.
.macro tw_trial nops, slot
    str r1, [r3, #0]
    str r2, [r3, #4]
    str r4, [r3, #8]               @ the burst is requested here
    .rept \nops
    mov r0, r0
    .endr
    ldr r0, [r7, #0]
    str r0, [r5, #\slot]
.endm

    .align 2
    .thumb
thumb_part:
    tw_trial 0, 0
    tw_trial 1, 4
    tw_trial 2, 8
    tw_trial 3, 12
    bx  lr
