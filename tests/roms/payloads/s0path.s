@ s0path.s -- s0trig.s's bit-14 path taken apart: what puts channel 1's
@ shift-0 check on its fast timing?
@
@ s0trig.s's bit-14 cells are the only fast ones. Each runs straight after
@ another cell that ended with a master-off; it switches the PSG on at entry,
@ writes SOUNDCNT_L = 0xFF77 and SOUNDCNT_H = 2, parks (a CPU halt) with
@ sound on and routed, writes SOUNDCNT_X = 0x80 and SOUNDCNT_L again, then
@ NR11/NR12 and the trigger. Everything else measured is slow (s0time,
@ s0long -- including a halt after the master-on with SOUNDCNT_L still
@ cleared -- and s0write, which refuted the SOUNDCNT_X rewrite). dingbat's
@ stand-in (gba/apu/abstract_channels.nim psg_halt_entry): a halt that
@ begins with the PSG on and routed.
@
@ With no bits set this page is that bit-14 path, instruction for
@ instruction up to the trigger. Each bit changes one step; a skipped write
@ goes to IWRAM instead (same cost), so the trigger's cycle does not move.
@
@   r0 bits 0..3  k: (k & 15) + 1 cycle sled right before the trigger
@      bit  8     the master-off happens here, at entry, and a 65536-cycle
@                 spin (CPU running) separates it from the master-on --
@                 instead of the previous cell's exit and the monitor
@      bit  9     no SOUNDCNT_L write before the park
@      bit  10    no SOUNDCNT_H write before the park
@      bit  11    no SOUNDCNT_X rewrite after the park
@      bit  12    no SOUNDCNT_L write after the park
@      bit  13    no park: a spin of the same length in lines instead
@                 (waits for line 50 by polling VCOUNT, CPU running)
@ dingbat predicts: fast with no bits, 0x100, 0x400, 0x800, 0x1000 (the
@ halt still begins routed); slow with 0x200 and 0x2000.
@ answer: as s0trig.s -- bits 0..7 SOUNDCNT_X bit 0 at eight reads 3 cycles
@ apart after the trigger, bits 16..31 polls it stayed on (cap FFFF)
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    tst r9, #0x100                 @ bit 8: the off here, a gap, then on
    beq 1f
    mov r0, #0
    strh r0, [r4, #0x84]
    ldr r0, =16384
0:  subs r0, r0, #1
    bne 0b
1:  add r6, r12, #40               @ r6 = the IWRAM stand-in address
    mov r0, #0x80
    strh r0, [r4, #0x84]           @ master on (off since the previous exit)
    ldr r0, =0xFF77
    tst r9, #0x200
    addeq r1, r4, #0x80
    movne r1, r6
    strh r0, [r1]                  @ SOUNDCNT_L (bit 9: IWRAM)
    mov r0, #2
    tst r9, #0x400
    addeq r1, r4, #0x82
    movne r1, r6
    strh r0, [r1]                  @ SOUNDCNT_H (bit 10: IWRAM)
    tst r9, #0x2000
    bne 2f
    probe_park 50
    b 3f
2:  ldrh r0, [r4, #6]              @ bit 13: poll VCOUNT for line 50
    cmp r0, #50
    beq 2b                         @ (leave line 50 if already on it)
4:  ldrh r0, [r4, #6]
    cmp r0, #50
    bne 4b
3:  mov r0, #0x80
    tst r9, #0x800
    addeq r1, r4, #0x84
    movne r1, r6
    strh r0, [r1]                  @ SOUNDCNT_X = 0x80 again (bit 11: IWRAM)
    ldr r0, =0xFF77
    tst r9, #0x1000
    addeq r1, r4, #0x80
    movne r1, r6
    strh r0, [r1]                  @ SOUNDCNT_L again (bit 12: IWRAM)
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
5:  ldrh r1, [r4, #0x84]
    tst r1, #1
    beq 6f
    add r3, r3, #1
    cmp r3, r2
    blt 5b
6:  orr r0, r0, r3, lsl #16
    ldr r10, =0x04000100           @ probe_leave uses r10 and r11
    mov r1, #0
    strh r1, [r4, #0x84]           @ master off on the way out
    probe_leave
    probe_data
