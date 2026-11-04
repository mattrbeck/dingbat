@ f6q3: f6q.s with bit 13 of the argument selecting WS0 3/1 (WAITCNT 0x0014
@ or 0x4014, alyosha fifo_6's own). The empty slot does not answer reliably
@ at those waits, so this one runs from a cartridge whose sled region is
@ 0xFFFFFFFF -- the same NV no-ops the empty slot gives (tests/roms/
@ fifokit.py). With bit 13 clear it is f6q.s exactly.
@
@ f6q: f6slot with the interrupt taken from TM3 at a chosen cycle instead of
@ (or as well as) the DMA1-end interrupt, to split fifo_6's path: the IRQ
@ entry from a (prefetched) gamepak sled, and what a FIFO burst does to the
@ sled's fetch stream, each on its own.
@
@ r0: bits 0-11 Q = TM3 period (/1, IRQ; started one store before TM1),
@     bit 14 = prefetcher on (WAITCNT 0x4000, else 0), bits 16-23 P (0 =
@     no TM0, no refills), 24-27 d, bit 28 = IWRAM sled, bit 29 = DMA1's
@     IRQ off (IE = TM3 only).
@ Returns TM1 at the handler's read | IF << 16.
    .arm
    .text
    .global _start
    .include "fifoquiet.inc"
.equ SLED, 0x08010000

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str sp, [r12]
    str r0, [r12, #4]
    ldr r4, =0x04000200
    ldrh r1, [r4, #8]
    str r1, [r12, #8]
    ldrh r1, [r4]
    str r1, [r12, #12]
    ldrh r1, [r4, #4]
    str r1, [r12, #16]
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #20]
    mov r2, #0
    strh r2, [r4, #8]
    ldr r2, =handler
    str r2, [r1]
    mov r3, #0x04000000
    quiet
    mov r0, #0
    str r0, [r3, #0x80]
    str r0, [r3, #0x84]
    str r0, [r3, #0xBC]
    str r0, [r3, #0xC0]
    str r0, [r3, #0xC4]
    str r0, [r3, #0x100]
    str r0, [r3, #0x104]
    str r0, [r3, #0x10C]
    mov r0, #0x02000000
    ldr r1, =0x040000A0
    ldr r2, =0xF7400004
    str r0, [r3, #0xBC]
    str r1, [r3, #0xC0]
    str r2, [r3, #0xC4]
    ldr r0, [r12, #4]
    and r1, r0, #0x4000
    tst r0, #0x2000
    orrne r1, r1, #0x14            @ bit 13: WS0 3/1, fifo_6's own waits
    strh r1, [r4, #4]              @ WAITCNT 0x4000 or 0
    tst r0, #0x20000000
    ldreq r1, =0x0240
    movne r1, #0x40
    strh r1, [r4]
    mvn r1, #0
    strh r1, [r4, #2]
    mov r1, #1
    strh r1, [r4, #8]
    mov r1, #0x80
    str r1, [r3, #0x84]
    tst r0, #0x10000000
    ldreq r10, =SLED
    adrne r10, iwsled
    mov r5, r0, lsr #24
    and r5, r5, #15
    rsb r5, r5, #15
    adr r9, dsled
    add r9, r9, r5, lsl #2
    @ TM3: Q (/1, IRQ) or the 256 x 1024 watchdog
    mov r6, r0, lsl #20
    movs r6, r6, lsr #20
    ldreq r6, =0x00C3FF00
    rsbne r6, r6, #0x10000
    orrne r6, r6, #0x00C00000
    @ TM0: P, or nothing
    mov r2, r0, lsr #16
    ands r2, r2, #0xFF
    rsbne r2, r2, #0x10000
    orrne r2, r2, #0x00C00000
    ldr r1, =0x00800000
    str r6, [r3, #0x10C]           @ TM3 starts
    str r1, [r3, #0x104]           @ TM1 starts
    str r2, [r3, #0x100]           @ TM0 starts (or stays off)
    mov pc, r9
dsled:
    .rept 15
    nop
    .endr
    mov pc, r10

    .ltorg
iwsled:
    .rept 512
    nop
    .endr
    b iwsled

handler:
    mov r0, #0
    str r0, [r3, #0x208]
    ldr r7, [r3, #0x104]
    ldrh r6, [r4, #2]
    ldr sp, =0x03007FA0
    msr cpsr_c, #0x1F
    mov r7, r7, lsl #16
    mov r7, r7, lsr #16
    orr r7, r7, r6, lsl #16
    mov r0, #0
    add r2, r3, #0x100
    strh r0, [r2, #2]
    mov r1, #200
1:  subs r1, r1, #1
    bne 1b
    strh r0, [r3, #0xC6]
    mov r1, #50
1:  subs r1, r1, #1
    bne 1b
    str r0, [r3, #0x84]
    str r0, [r3, #0x104]
    str r0, [r3, #0x10C]
    ldr r12, =vars
    ldr r4, =0x04000200
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r1, [r12, #20]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #16]
    strh r1, [r4, #4]
    ldr r1, [r12, #12]
    strh r1, [r4]
    ldr r1, [r12, #8]
    strh r1, [r4, #8]
    ldr sp, [r12]
    mov r0, r7
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
vars:
    .space 32
