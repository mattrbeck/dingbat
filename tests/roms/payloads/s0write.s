@ s0write.s -- which sound-control write switches channel 1's shift-0 check
@ from its slow timing to its fast one?
@
@ s0time.s / s0long.s: the first shift-0 f = 0x400 trigger after a
@ master-on stays on the slow, master-on-anchored timing (one phase in 8
@ lives) out to 262144 cycles and across a halt. s0trig.s's bit-14 cells
@ are fast; they differ from s0long's halt cells only in a SOUNDCNT_H = 2
@ write and a second SOUNDCNT_X = 0x80 write while sound is already on.
@ dingbat (gba/apu/channel1.nim ch1_s0_kill_at, apu.nim) takes the rewrite:
@ it predicts fast for w = 1 at either place and slow for w = 0, 2, 3.
@
@ One write of the same shape in every cell (the control writes IWRAM), so
@ each variant's trigger lands on the same cycle.
@
@   r0 bits 0..3  k: (k & 15) + 1 cycle sled right before the trigger
@      bits 4..5  m: spin SPIN[m] x 4 cycles between the master-on and the
@                 trigger (16 -> 64 cycles, 16384 -> 65536, 1, 256 -> 1024)
@      bits 8..9  w: the write -- 0 none (IWRAM), 1 SOUNDCNT_X = 0x80 again,
@                 2 SOUNDCNT_H = 2, 3 SOUNDCNT_L = 0xFF77 again
@      bit  10    the write BEFORE the spin (else after it, ~10 cycles
@                 before the trigger)
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
    and r0, r0, #0x03
    adr r1, spins
    ldr r7, [r1, r0, lsl #2]       @ spin count
    mov r0, r9, lsr #8             @ the write: r6 = address, r3 = value
    and r0, r0, #0x03
    adr r1, targets
    ldr r6, [r1, r0, lsl #3]
    add r1, r1, #4
    ldr r3, [r1, r0, lsl #3]
    mov r2, #0x80
    probe_park 50
    strh r2, [r4, #0x84]           @ master on
    ldr r0, =0xFF77
    strh r0, [r4, #0x80]
    tst r9, #0x400
    strneh r3, [r6]                @ bit 10: the write before the spin
    streqh r3, [r12, #40]          @ (else an IWRAM store of the same cost)
3:  subs r7, r7, #1                @ 4 cycles an iteration
    bne 3b
    tst r9, #0x400
    streqh r3, [r6]                @ the write after the spin
    strneh r3, [r12, #40]
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
    .word 16, 16384, 1, 256
targets:                           @ (address, value) per w
    .word probe_vars + 40, 0
    .word 0x04000084, 0x80
    .word 0x04000082, 0x02
    .word 0x04000080, 0xFF77
    probe_data
