@ payload: an H-blank DMA into OAM with sprites on, running into the next line
@
@ alyosha Interactions/Halt_DMA_IRQ_Read_OAM ends on a sum whose big term is
@ one H-blank DMA of 140 halfwords from EWRAM to OAM (fixed destination)
@ granted at dot 1011 of line 130 and running to dot ~341 of line 131, with
@ sprites on: the burst crosses the PPU's own OAM traffic in the H-blank and
@ in line 131's drawing. dingbat charges it 2 + 140 * (3 + 1) cycles and
@ reads the row 2 cycles early. This asks the console for the burst's
@ length: parked on line 100, TM0 started, the DMA armed, a fixed IWRAM
@ spin (stalled by the burst), then TM0. The no-DMA control gives the spin.
@
@   r0 bits 0..9  N halfwords
@      bit  12    sprites on (DISPCNT 0x1404, else 0x0404)
@      bit  13    fill OAM first with the row's pattern (word k = 1 + 3k)
@      bit  14    destination IWRAM 0x03006000 instead of OAM + 0x40
@      bit  15    no DMA (control word 0: the same path, nothing armed)
@
@ answer: TM0 after the spin.
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    ldrh r1, [r4]
    str r1, [r12, #32]             @ DISPCNT
    tst r9, #0x2000
    beq 2f
    mov r1, #0x07000000
    mov r2, #1
    mov r3, #256
1:  str r2, [r1], #4
    add r2, r2, #3
    subs r3, r3, #1
    bne 1b
2:  ldr r1, =0x0404
    tst r9, #0x1000
    orrne r1, r1, #0x1000
    strh r1, [r4]
    ldr r1, =0x02010000
    str r1, [r8]                   @ DMA0SAD: EWRAM
    ldr r1, =0x07000040
    tst r9, #0x4000
    ldrne r1, =0x03006000
    str r1, [r8, #4]               @ DMA0DAD
    and r6, r9, #0x0300
    and r1, r9, #0xFF
    orr r6, r6, r1
    ldr r1, =0xA1400000            @ enable, H-blank, src fixed, dst fixed
    orr r6, r6, r1
    tst r9, #0x8000
    movne r6, #0
    probe_park 100
    probe_timers_start
    probe_dma_arm
    probe_spin 700
    probe_read_tm0 r0
    ldr r1, [r12, #32]
    strh r1, [r4]
    probe_leave
    probe_data
