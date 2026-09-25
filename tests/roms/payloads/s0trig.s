@ s0trig.s -- which channel-1 triggers at sweep shift 0 and f = 0x400 die?
@
@ The AGB SP kills some (sweeptrig.s, psgfirst.s: 0 or 1 polls) and spares
@ others (psgfirst.s's third trigger, its length-off row), and games trigger
@ shift 0 at f >= 0x400 hundreds of times a minute with the channel off, so
@ the rule is narrower than "f + f overflows". This page sweeps the suspects
@ one bit at a time, parked on a V-count match so every cell starts on the
@ same cycle of every free-running clock.
@
@   r0 bits 0..3   k: a (k & 15) + 1 cycle sled right before the trigger
@      bits 4..7   c: 4c more cycles of spin between master-on and the sled
@      bit  8      write NR10 = 0 explicitly (else only master-off cleared it)
@      bit  9      length enable in the trigger (counter 16)
@      bit  10     NR11 = 0x00 (duty 0, counter 64) instead of 0xB0
@      bit  11     a prior f = 0x100 note, still playing, before the sled
@      bit  12     that prior note stopped by its DAC (NR12 = 0) first
@      bit  13     NR10 = 0x08 (negate) instead of 0
@      bit  14     no master off/on (sound left on from the previous cell)
@      bit  15     f = 0x3FF (control: lives)
@ answer: bits 0..7 SOUNDCNT_X bit 0 at eight reads 3 cycles apart from the
@ trigger's next instruction; bits 16..31 polls it stayed on (10 cycles a
@ poll, cap 0xFFFF).
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    tst r9, #0x4000
    moveq r0, #0
    streqh r0, [r4, #0x84]         @ master off (clears the PSG) ...
    mov r0, #0x80
    strh r0, [r4, #0x84]           @ ... and on, or on already
    ldr r0, =0xFF77
    strh r0, [r4, #0x80]
    mov r0, #2
    strh r0, [r4, #0x82]
    probe_park 50
    tst r9, #0x4000                @ re-toggle after the park so the time
    moveq r0, #0                   @ from master-on is the cell's own
    streqh r0, [r4, #0x84]
    mov r0, #0x80
    strh r0, [r4, #0x84]
    ldr r0, =0xFF77
    strh r0, [r4, #0x80]
    tst r9, #0x800                 @ bit 11: a prior note at f = 0x100
    beq 1f
    ldr r0, =0xF0B0
    strh r0, [r4, #0x62]
    ldr r0, =0x8100
    strh r0, [r4, #0x64]
    tst r9, #0x1000                @ bit 12: stopped by its DAC
    movne r0, #0
    strneh r0, [r4, #0x62]
1:  mov r0, r9, lsr #4             @ spin 4c cycles
    and r0, r0, #0x0F
    add r0, r0, #1
2:  subs r0, r0, #1
    bne 2b
    tst r9, #0x100                 @ bit 8 / 13: NR10
    tsteq r9, #0x2000
    beq 3f
    tst r9, #0x2000
    moveq r0, #0
    movne r0, #0x08
    strh r0, [r4, #0x60]
3:  tst r9, #0x400
    ldreq r0, =0xF0B0
    ldrne r0, =0xF000
    strh r0, [r4, #0x62]
    ldr r1, =0x8400
    tst r9, #0x8000
    subne r1, r1, #1               @ 0x83FF
    tst r9, #0x200
    orrne r1, r1, #0x4000
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
    probe_data
