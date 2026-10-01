@ zombie.s -- an NRx2 write to a playing channel, and the noise LFSR at
@ shift 14: which does the AGB do? Heard, not read: the CPU cannot see a
@ channel's volume or the LFSR, so this plays segments through the speaker
@ for a recording to compare (tools/hwlink/zombie_listen.py).
@
@ Every tone is channel 2, 50% duty, f = 1917 (131072 / 131 = 1000.5 Hz).
@ A recording path that suppresses a steady tone after a second or so (the
@ first take, 2026-09-30) is why every segment is short and separated by
@ silence, and the noise tests come first. Times from the sync tone's onset:
@   0.00  sync, volume 15, 0.20 s
@   0.50  N1 channel 4, volume 15, shift 13: 64 LFSR steps a second (both models)
@   2.00  N2 shift 14: the GB's counter has no bit 14, so the LFSR never
@         steps (silence); the GBA used to step it 32 times a second
@   3.50  N3 shift 13 again: the control, also for drift
@   5.00  Z1 reference volume 8
@   5.50  Z2 reference volume 12
@   6.00  Z3 volume 8, then at 6.25 four writes of NR22 = 0x80 to the playing
@         note: the GB's table (SameSuite channel_1_volume / _nrx2_glitch)
@         adds 0, so it stays 8; the rule the GBA used to apply, +1 a write: 12
@   6.75  Z4 reference volume 8
@   7.25  Z5 volume 8, then at 7.50 one write of 0x88: both rules give 7
@   8.00  Z6 reference volume 7
@ Noise segments 1.2 s (a triggered LFSR holds its output for its first 15
@ steps: 0.23 s at shift 13, 0.47 s at shift 14 on the old rule), tones
@ 0.25 s (Z3, Z5: 0.25 + 0.25), gaps silent.
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
    ldr r6, =0x877D                @ channel 2 trigger, f = 1917
    ldr r7, =209715                @ 0.05 s of 4-cycle spins
    mov r0, #10                    @ 0.5 s of silence first
    bl wait
    ldr r0, =0xF080                @ sync: volume 15
    bl tone
    mov r0, #4
    bl wait
    bl tone_off
    mov r0, #6
    bl wait
    ldr r1, =0x80D0                @ N1: shift 13
    bl noise
    ldr r1, =0x80E0                @ N2: shift 14
    bl noise
    ldr r1, =0x80D0                @ N3: shift 13
    bl noise
    ldr r0, =0x8080                @ Z1: volume 8
    bl tone
    bl short
    ldr r0, =0xC080                @ Z2: volume 12
    bl tone
    bl short
    ldr r0, =0x8080                @ Z3: volume 8 ...
    bl tone
    mov r0, #5
    bl wait
    mov r1, #0x80                  @ ... four writes of NR22 = 0x80
    strb r1, [r4, #0x69]
    strb r1, [r4, #0x69]
    strb r1, [r4, #0x69]
    strb r1, [r4, #0x69]
    bl short
    ldr r0, =0x8080                @ Z4: volume 8
    bl tone
    bl short
    ldr r0, =0x8080                @ Z5: volume 8 ...
    bl tone
    mov r0, #5
    bl wait
    mov r1, #0x88                  @ ... one write of 0x88
    strb r1, [r4, #0x69]
    bl short
    ldr r0, =0x7080                @ Z6: volume 7
    bl tone
    bl short
    mov r0, #0
    strh r0, [r4, #0x84]           @ master off on the way out
    ldr r0, =0x600D
    ldr r10, =0x04000100           @ probe_leave uses r10 and r11
    probe_leave

@ channel 2: NR21/NR22 = r0, then trigger
tone:
    strh r0, [r4, #0x68]
    strh r6, [r4, #0x6C]
    bx lr

@ channel 2 DAC off (silent)
tone_off:
    mov r0, #0x80
    strh r0, [r4, #0x68]
    bx lr

@ 0.25 s of the tone already playing, then channel 2 off, then 0.25 s silent
short:
    push {lr}
    mov r0, #5
    bl wait
    bl tone_off
    mov r0, #5
    bl wait
    pop {lr}
    bx lr

@ channel 4 at volume 15, NR43/NR44 = r1 (with the trigger): 1.2 s on, 0.3 s off
noise:
    push {lr}
    ldr r0, =0xF000
    strh r0, [r4, #0x78]
    strh r1, [r4, #0x7C]
    mov r0, #24
    bl wait
    mov r0, #0
    strh r0, [r4, #0x78]           @ DAC off
    mov r0, #6
    bl wait
    pop {lr}
    bx lr

@ r0 units of 0.05 s
wait:
    mul r1, r0, r7
1:  subs r1, r1, #1
    bne 1b
    bx lr

    probe_data
