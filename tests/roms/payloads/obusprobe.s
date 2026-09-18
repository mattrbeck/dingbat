@ obusprobe.s — what does a read of unmapped memory actually return?
@
@ Two rows of docs/hwprobe-questions.md that need no cartridge and no camera,
@ and are pure reads, so nothing here can leave the console anywhere but
@ where it started.
@
@ (a) THUMBBUS, "deferred". Unmapped reads hand back whatever the CPU last
@     drove on the bus, which in ARM state is unambiguous -- the opcode at
@     $+8 -- but in Thumb state has to be composed from halfwords, and GBATEK
@     makes it depend on the load instruction's own alignment. dingbat's
@     bus.nim picks one composition. This runs the identical load twice, on
@     opposite word alignments, so the two rows differ in nothing else; the
@     host reads the payload image back out of IWRAM and works out which
@     halfwords each answer was built from.
@
@ (b) The post-DMA window. dingbat's read_open_bus_value keeps the last DMA
@     word on the bus for a span marked Assumed. A DMA moves a distinctive
@     word, then the unmapped read happens one, two or three instructions
@     later: if the DMA's word survives to the first read and not the second,
@     the window is one instruction wide, and so on.
@
@ r0 out: 'OBUS'.  Results at 0x02008000, 15 words:
@   +0  ARM ldr from unmapped,  +4  the address of that ldr
@   +8  Thumb ldr,  one alignment,  +12 its address
@   +16 Thumb ldr,  the other,      +20 its address
@   +24 Thumb ldrh, one alignment,  +28 its address
@   +32 Thumb ldrh, the other,      +36 its address
@   +40/+44/+48 unmapped read 0, 1 and 2 instructions after a DMA
@   +52 the last word that DMA moved, +56 marker 'OBUS'
    .arm
    .text
    .global _start

.equ UNMAP,    0x10000000          @ past the gamepak: nothing answers here
.equ RESULTS,  0x02008000
.equ SCRATCH,  0x02009000
.equ DMA3SAD,  0x040000D4
.equ LASTWORD, 0xDEADBEE3

@ One post-DMA trial: start an immediate 4-word DMA, let \n instructions go
@ by, then read unmapped memory. Written out per distance rather than jumped
@ into, so "n instructions after the DMA" means exactly that.
.macro dma_trial n, slot
    ldr r0, =dma_source
    ldr r1, =SCRATCH
    ldr r2, =DMA3SAD
    str r0, [r2, #0]
    str r1, [r2, #4]
    ldr r0, =0x84000004            @ enable, 32-bit, immediate, 4 words
    str r0, [r2, #8]
    .rept \n
    mov r0, r0
    .endr
    ldr r0, [r7]                   @ the unmapped read under test
    str r0, [r10, #\slot]
.endm

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r10, =RESULTS
    ldr r7, =UNMAP

    @ (a) ARM state. pc reads $+8, so the answer should be the opcode two
    @ instructions along from the load -- which is why the address is kept.
    mov r6, pc                     @ r6 = this instruction + 8
    ldr r0, [r7]
    sub r6, r6, #4                 @ ... so the address of the ldr itself
    str r0, [r10, #0]
    str r6, [r10, #4]

    ldr r0, =thumb_part + 1
    mov lr, pc
    bx  r0

    @ (b) the post-DMA window.
    ldr r0, =LASTWORD
    str r0, [r10, #52]
    dma_trial 0, 40
    dma_trial 1, 44
    dma_trial 2, 48

    ldr r0, =0x4F425553            @ 'OBUS'
    str r0, [r10, #56]
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

    .align 2
dma_source:
    .word 0x11111111
    .word 0x22222222
    .word 0x33333333
    .word LASTWORD

@ The Thumb half. Four identical blocks, each five halfwords long -- an odd
@ number, so consecutive blocks put their load on opposite word alignments
@ without any padding, which is the whole point: the pairs differ in bit 1 of
@ the load's address and in nothing else. Each block records the address it
@ loaded from as well as what it got, and the host reads the payload image
@ back out of IWRAM to see which halfwords the answer was built from.
@ r5 shadows r10, because Thumb cannot index off a high register.
.macro tb_trial op, slot
    mov r6, pc                     @ r6 = this instruction + 4
    \op r0, [r7, #0]
    sub r6, #2                     @ ... so the load's own address
    str r0, [r5, #\slot]
    str r6, [r5, #(\slot + 4)]
.endm

    .align 2
    .thumb
thumb_part:
    mov r5, r10
    tb_trial ldr,  8
    tb_trial ldr,  16
    tb_trial ldrh, 24
    tb_trial ldrh, 32
    bx  lr
