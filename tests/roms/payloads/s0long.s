@ s0long.s -- when does channel 1's shift-0 trigger check stop running on
@ the dividers a master-on restarted?
@
@ s0time.s: the first shift-0 f = 0x400 trigger after a master-on keeps the
@ slow, master-on-anchored timing (one phase in 8 lives) for all 32768
@ cycles it spins; s0trig.s's bit-14 cells, whose master-on came before a
@ halt up to a frame earlier, get a fast 4 MHz timing with no survivor.
@ dingbat ends the slow timing at the sweep unit's first clock (the 3rd
@ 512 Hz step, 81920..114687 cycles on; gba/apu/channel1.nim). This page
@ separates time from the halt:
@   bit 8 clear: master-on right after the park, then a spin of
@                SPIN[m] x 4 cycles, then the trigger;
@   bit 8 set:   master-on right after a park on line 40, a second park on
@                line 50 (12320 cycles later, the CPU halted), then the
@                spin and the trigger.
@
@   r0 bits 0..3  k: (k & 15) + 1 cycle sled right before the trigger
@      bits 4..6  m: SPIN[m]
@      bit  8     halt between the master-on and the trigger
@ answer: as s0trig.s -- bits 0..7 SOUNDCNT_X bit 0 at eight reads 3 cycles
@ apart after the trigger, bits 16..31 polls it stayed on (cap FFFF)
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    mov r0, #0
    strh r0, [r4, #0x84]           @ master off (clears the PSG)
    mov r0, r9, lsr #4
    and r0, r0, #0x07
    adr r1, spins
    ldr r7, [r1, r0, lsl #2]       @ spin count
    mov r2, #0x80
    tst r9, #0x100
    beq 1f
    probe_park 40
    strh r2, [r4, #0x84]           @ master on, then halt to line 50
    probe_park 50
    b 2f
1:  probe_park 50
    strh r2, [r4, #0x84]           @ master on
2:  ldr r0, =0xFF77
    strh r0, [r4, #0x80]
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
spins:                             @ x4 cycles: 16k, 64k, 98k, 131k, 197k, 262k, 1, 16
    .word 4096, 16384, 24576, 32768, 49152, 65536, 1, 16
    probe_data
