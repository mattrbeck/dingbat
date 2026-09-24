@ dmatime.s -- dbsuite copy of tmp/pl/dmatime.s, unchanged, run on the AGB
@ SP on 2026-09-24 (00:33 UTC).
@
@ WHAT: how long an immediate EWRAM->EWRAM DMA3 of N units holds the CPU,
@ read by the first instruction after four NOPs behind the enable store.
@ PROVENANCE: AGB SP via tools/hwlink, 2026-09-24:
@   N=0 6, 1 20, 2 32, 4 56, 64 776, 1024 12296, 4096 49160 (32-bit);
@   16-bit: 1 14, 2 20, 64 392

@ r0 bits 0..15 N words EWRAM->EWRAM DMA3 (0: none); bit 16: 16-bit units
@ answer: TM1 read by the first instruction after the DMA3CNT store
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r4, #0x04000000
    add r1, r4, #0x100
    mov r2, #0
    str r2, [r1, #4]
    add r6, r4, #0xD4
    ldr r2, =0x02010000
    str r2, [r6]
    ldr r2, =0x02020000
    str r2, [r6, #4]
    mov r10, r0, lsl #16
    movs r10, r10, lsr #16
    orrne r10, r10, #0x80000000
    tst r0, #0x10000
    orreq r10, r10, #0x04000000
    cmp r10, #0
    mov r8, #0x00800000
    add r1, r4, #0x100
    str r8, [r1, #4]               @ TM1 starts
    strne r10, [r6, #8]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r0, [r1, #4]
    mov r2, #0
    str r2, [r1, #4]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
