@ f6slot: alyosha fifo_6's measured path with its NOP sled in the EMPTY slot.
@ An empty slot reads A>>1 on a nonsequential halfword and 0xFFFF on a
@ sequential one, so every ARM word there is 0xFFFFxxxx: condition NV, a
@ one-cycle no-op on the console (nvtest.s). So the CPU can sit fetching
@ gamepak code -- prefetcher and all -- while fifo_6's DMA1 FIFO refill and
@ its completion interrupt happen around it.
@
@ fifo_6: DMA1 EWRAM (fixed) -> FIFO A, special, repeat, 32-bit, 4 words, IRQ;
@ master on; TM1 = 0 enabled, TM0 period P enabled; NOP sled in the gamepak;
@ the DMA1-end IRQ goes through the BIOS to a handler that does
@ `mov r0,#0; str r0,[r3,#0x208]; ldr r7,[r3,#0x104]`. Here the handler is in
@ IWRAM (the BIOS enters it in ARM; the slot cannot hold it).
@
@ r0: bits 0-15 WAITCNT, 16-23 P, 24-27 d = IWRAM NOPs between the TM0 start
@ and the jump into the sled, bit 28 = sled in IWRAM instead (control).
@ Returns TM1 at the handler's read (low 16) | IF at that point << 16;
@ 0xFFFF in the low half = the watchdog fired.
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
    str r1, [r12, #8]              @ IME
    ldrh r1, [r4]
    str r1, [r12, #12]             @ IE
    ldrh r1, [r4, #4]
    str r1, [r12, #16]             @ WAITCNT
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #20]             @ vector
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
    strh r0, [r4, #4]              @ WAITCNT under test
    ldr r1, =0x0240                @ IE: DMA1 + TM3 (watchdog)
    strh r1, [r4]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r1, =0x00C3FF00            @ TM3: 256 x 1024 cycles, IRQ
    str r1, [r3, #0x10C]
    mov r1, #1
    strh r1, [r4, #8]              @ IME
    mov r1, #0x80
    str r1, [r3, #0x84]            @ master on
    @ sled address and the delay
    tst r0, #0x10000000
    ldreq r10, =SLED
    adrne r10, iwsled
    mov r5, r0, lsr #24
    and r5, r5, #15
    rsb r5, r5, #15
    adr r9, dsled
    add r9, r9, r5, lsl #2         @ enter the 15-NOP delay sled d from its end
    mov r2, r0, lsr #16
    and r2, r2, #0xFF
    rsb r2, r2, #0x10000
    orr r0, r2, #0x00C00000        @ TM0: reload 0x10000 - P, enable, IRQ bit
    ldr r1, =0x00800000
    str r1, [r3, #0x104]           @ TM1 starts
    str r0, [r3, #0x100]           @ TM0 starts
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

handler:                           @ IRQ mode, from the BIOS; r3 = 0x04000000
    mov r0, #0
    str r0, [r3, #0x208]
    ldr r7, [r3, #0x104]
    ldrh r6, [r4, #2]              @ IF (r4 = 0x04000200, kept)
    ldr sp, =0x03007FA0            @ drop the BIOS frame
    msr cpsr_c, #0x1F              @ system mode, ARM
    mov r7, r7, lsl #16
    mov r7, r7, lsr #16
    tst r6, #0x40
    ldrne r7, =0xFFFF
    orr r7, r7, r6, lsl #16
    @ stop TM0, let any request it left drain before DMA1 goes off
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
