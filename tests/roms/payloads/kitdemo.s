@ payload: probe.inc, proved against a recorded table
@
@ dmaphase.s's multiply and NOP runs rebuilt from the kit: an H-blank DMA
@ that stamps itself against every phase of a run of one instruction. The
@ park, the timers, the spin and the sled are where dmaphase.s has them, so
@ T less the no-DMA control and D's shape over k are dmaphase's, and those
@ are on record from the console. This page has its own cells in
@ tools/hwlink/r0-agb.json; it is also the template for a new probe.
@
@   r0 bits 0..3  k + 1 NOPs
@      bits 4..5  0 multiplies (1 fetch + 4 internal), 3 NOPs
@      bit  7     no DMA
@ answer: T << 16 | D, as dmaphase.s.
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    ldr r2, =0x12345678            @ a multiplier of four significant bytes
    mov r3, #3
    and r0, r9, #0x30
    adr r7, run_mul
    cmp r0, #0x30
    ldreq r7, =run_nop
    probe_dma_stamp_setup 2
    tst r9, #0x80
    movne r6, #0
    probe_park 50
    probe_timers_start
    probe_dma_arm
    probe_spin 205
    probe_sled
    bx r7

run_mul:
    .rept 64
    mul r1, r3, r2
    .endr
    probe_read_tm0 r1
    b collect
    .ltorg

run_nop:
    .rept 256
    mov r0, r0
    .endr
    probe_read_tm0 r1

collect:
    probe_read_tm1 r2
    mov r0, r1, lsl #16
    orr r0, r0, r2
    probe_leave
    probe_data
