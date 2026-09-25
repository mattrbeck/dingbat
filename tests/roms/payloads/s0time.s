@ s0time.s -- how long after a master-on, or after a 512 Hz step, does
@ channel 1's shift-0 trigger check keep its slow timing?
@
@ s0trig.s measured the check two ways: 40 cycles after a master-on the
@ trigger is taken on a 2 MHz edge (one phase in 8 escapes, the stop comes
@ 2..12 cycles later) and a frame after one it stops the channel on the
@ first 4 MHz edge 3 cycles on. psgfirst.s's "ch1 after ch2" row, some 25
@ cycles after a length step, behaves like the first. dingbat takes the
@ first within PSG_SETTLE (256) cycles of either event
@ (gba/apu/abstract_channels.nim psg_settling); this page measures where it
@ ends. Every cell is the FIRST ch1 trigger after a master-on (so the check
@ is armed): NR10 = 0, f = 0x400, length off, reads as s0trig.s.
@
@   r0 bits 0..3  k: (k & 15) + 1 cycle sled right before the trigger
@      bits 4..7  m: spin SPIN[m] x 4 cycles between the sync point and it
@      bit  8     sync point = the 512 Hz step a ch2 counter-2 note dies on
@                 (polled, 10-cycle granularity) instead of the master-on
@ answer: bits 0..7 SOUNDCNT_X bit 0 at eight reads 3 cycles apart from
@ the trigger's next instruction; bits 16..31 polls it stayed on (cap FFFF)
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    mov r0, #0
    strh r0, [r4, #0x84]           @ master off (clears the PSG)
    mov r0, r9, lsr #4
    and r0, r0, #0x0F
    adr r1, spins
    ldr r7, [r1, r0, lsl #2]       @ spin count
    ldr r6, =0xF03E                @ ch2: vol 15, counter 2
    mov r2, #0x80
    probe_park 50
    strh r2, [r4, #0x84]           @ master on
    ldr r0, =0xFF77
    strh r0, [r4, #0x80]
    tst r9, #0x100
    beq 3f
    mov r0, #0                     @ ch2 counter 2, trigger + enable 20+
    mov r0, r0                     @ cycles on: it dies on a step
    strh r6, [r4, #0x68]
    ldr r0, =0xC000
    strh r0, [r4, #0x6C]
    ldr r2, =0x80000
1:  ldrh r0, [r4, #0x84]
    tst r0, #2
    beq 3f
    subs r2, r2, #1
    bne 1b
3:  subs r7, r7, #1                @ 4 cycles an iteration
    bne 3b
    ldr r0, =0xF0B0                @ ch1 NR11/NR12
    strh r0, [r4, #0x62]
    ldr r1, =0x8400                @ trigger, f = 0x400, length off
    probe_sled
    strh r1, [r4, #0x64]           @ trigger
    ldrh r0, [r4, #0x84]
    ldrh r1, [r4, #0x84]
    ldrh r2, [r4, #0x84]
    ldrh r3, [r4, #0x84]
    ldrh r6, [r4, #0x84]
    ldrh r7, [r4, #0x84]
    ldrh r10, [r4, #0x84]
    ldrh r11, [r4, #0x84]
    and r0, r0, #1
    and r1, r1, #1
    orr r0, r0, r1, lsl #1
    and r2, r2, #1
    orr r0, r0, r2, lsl #2
    and r3, r3, #1
    orr r0, r0, r3, lsl #3
    and r6, r6, #1
    orr r0, r0, r6, lsl #4
    and r7, r7, #1
    orr r0, r0, r7, lsl #5
    and r10, r10, #1
    orr r0, r0, r10, lsl #6
    and r11, r11, #1
    orr r0, r0, r11, lsl #7
    mov r3, #0
    ldr r2, =0xFFFF
4:  ldrh r1, [r4, #0x84]
    tst r1, #1
    beq 5f
    add r3, r3, #1
    cmp r3, r2
    blt 4b
5:  orr r0, r0, r3, lsl #16
    ldr r10, =0x04000100           @ probe_leave uses r10 and r11
    mov r1, #0
    strh r1, [r4, #0x84]           @ master off on the way out
    probe_leave
    .ltorg
    .align 2
spins:
    .word 1, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 128, 192, 256, 1024, 8192
    probe_data
