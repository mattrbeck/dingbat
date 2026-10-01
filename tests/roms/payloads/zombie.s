@ zombie.s -- an NRx2 write to a playing channel: which volume change does
@ the AGB make? Heard, not read: the CPU cannot see a channel's volume, so
@ this plays segments through the speaker for a recording to compare
@ (tools/hwlink/zombie_listen.py).
@
@ Channel 2, 50% duty, f = 1917 (1024 Hz), PSG at full scale. 0.4 s each:
@   0  silence (0.5 s, the recording's marker)
@   1  reference, volume 8         (NR22 = 0x80, period 0)
@   2  reference, volume 12        (0xC0)
@   3a volume 8 ...
@   3b ... after four more writes of NR22 = 0x80 to the playing note.
@      The GB's table (SameSuite channel_1_volume / _nrx2_glitch): old
@      period 0 decreasing -> new period 0 decreasing adds 0, so 3b = 8.
@      Pan Docs' rule as the GBA used to apply it: +1 a write, 3b = 12.
@   4a volume 8 ...
@   4b ... after one write of 0x88 (increase): both rules +1 then 16 - v,
@      so 4b = 7 -- the control.
@   5  reference, volume 7         (0x70)
@   6  channel 4, shift 14, 0.8 s: the GB's counter has no bit 14, so the
@      LFSR never steps (silence); the GBA used to step it 32 times a second
@      (clicks)
@   7  shift 13, 0.8 s: 64 steps a second in both models (the control)
@ answer: 0x600D when it has played everything.
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    mov r0, #0
    strh r0, [r4, #0x84]           @ master off (clears the PSG) and on
    mov r0, #0x80
    strh r0, [r4, #0x84]
    ldr r0, =0xFF77                @ all PSG channels, both sides, volume 7
    strh r0, [r4, #0x80]
    mov r0, #2                     @ PSG at 100%
    strh r0, [r4, #0x82]
    ldr r6, =0x877D                @ trigger, f = 1917
    ldr r7, =1677722               @ 0.4 s of 4-cycle spins
    ldr r0, =2097152               @ 0.5 s of silence
1:  subs r0, r0, #1
    bne 1b
    ldr r0, =0x8080                @ 1: NR22 = 0x80, NR21 = 0x80
    strh r0, [r4, #0x68]
    strh r6, [r4, #0x6C]
    bl wait
    ldr r0, =0xC080                @ 2: volume 12
    strh r0, [r4, #0x68]
    strh r6, [r4, #0x6C]
    bl wait
    ldr r0, =0x8080                @ 3a: volume 8
    strh r0, [r4, #0x68]
    strh r6, [r4, #0x6C]
    bl wait
    mov r1, #0x80                  @ 3b: four writes of NR22 = 0x80
    strb r1, [r4, #0x69]
    strb r1, [r4, #0x69]
    strb r1, [r4, #0x69]
    strb r1, [r4, #0x69]
    bl wait
    ldr r0, =0x8080                @ 4a: volume 8
    strh r0, [r4, #0x68]
    strh r6, [r4, #0x6C]
    bl wait
    mov r1, #0x88                  @ 4b: one write of 0x88
    strb r1, [r4, #0x69]
    bl wait
    ldr r0, =0x7080                @ 5: volume 7
    strh r0, [r4, #0x68]
    strh r6, [r4, #0x6C]
    bl wait
    mov r0, #0                     @ channel 2 off (DAC)
    strh r0, [r4, #0x68]
    ldr r0, =0xF000                @ 6: noise, volume 15, shift 14
    strh r0, [r4, #0x78]
    ldr r0, =0x80E0
    strh r0, [r4, #0x7C]
    bl wait
    bl wait
    ldr r0, =0x80D0                @ 7: shift 13, the control
    strh r0, [r4, #0x7C]
    bl wait
    bl wait
    mov r0, #0
    strh r0, [r4, #0x84]           @ master off on the way out
    ldr r0, =0x600D
    ldr r10, =0x04000100           @ probe_leave uses r10 and r11
    probe_leave

wait:
    mov r0, r7
2:  subs r0, r0, #1
    bne 2b
    bx lr

    probe_data
