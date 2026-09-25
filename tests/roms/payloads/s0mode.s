@ s0mode.s -- what separates the two timings channel 1's shift-0 check has
@ off its slow one?
@
@ After a halt that spans a 512 Hz step (apu.nim tick_frame_sequencer), the
@ AGB SP answers two ways on what is, up to the trigger, one path:
@   s0trig.s bit 14 (C2): the stop on the first 4 MHz edge 3+ cycles after
@     the write -- reads on 1 1 2 1 per 4 phases, no survivor;
@   s0path.s base (C3): the trigger taken on a 4 MHz edge, a write one cycle
@     before the edge missed -- reads on 2 L 2 2, one survivor in 4.
@ The paths differ in the master-on's phase (entry code), the trigger's
@ distance from the wake, and the cell before. This page is s0path's base
@ path with one of those moved at a time; k over 4 phases classifies each
@ row (C3: one L; C2: no L, one 2).
@
@   r0 bits 0..1  k: (k & 3) + 1 cycle sled right before the trigger
@      bits 4..7  j: j NOPs before the master-on (its phase; the trigger's
@                 cycle after the wake does not move)
@      bits 8..10 u: U[u] NOPs between the wake and the rest (0, 4, 8, 12,
@                 16, 24, 32, 48: the trigger's distance from the wake)
@      bits 11..12 h: a note in this cell before the master-on, as the cell
@                 before leaves one: 0 none, 1 ch1 f = 0x400 (dies), 2 ch1
@                 f = 0x100 (lives), 3 ch2 -- each switched on, triggered, and
@                 switched off again by a master-off
@ answer: as s0trig.s -- bits 0..7 SOUNDCNT_X bit 0 at eight reads 3 cycles
@ apart after the trigger, bits 16..31 polls it stayed on (cap FFFF)
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    mov r0, r9, lsr #11            @ h: a note, then a master-off
    ands r0, r0, #3
    beq 1f
    mov r1, #0x80
    strh r1, [r4, #0x84]
    ldr r1, =0xF0B0
    cmp r0, #3
    addne r2, r4, #0x62            @ ch1 NR11/12 (h 1, 2) or ch2 NR21/22
    addeq r2, r4, #0x68
    strh r1, [r2]
    ldr r1, =0x8400                @ f = 0x400 for h 1 and 3
    cmp r0, #2
    ldreq r1, =0x8100              @ f = 0x100 for h 2
    add r2, r2, #2                 @ NRx3/NRx4 (0x64 / 0x6A... ch2 at 0x6C)
    cmp r0, #3
    addeq r2, r2, #2
    strh r1, [r2]                  @ trigger
    mov r1, #64
0:  subs r1, r1, #1
    bne 0b
    mov r1, #0
    strh r1, [r4, #0x84]           @ master off
1:  mov r0, r9, lsr #4             @ j NOPs
    and r0, r0, #0x0F
    rsb r0, r0, #15
    add pc, pc, r0, lsl #2
    mov r0, r0
    .rept 16
    mov r0, r0
    .endr
    mov r0, #0x80
    strh r0, [r4, #0x84]           @ master on
    ldr r0, =0xFF77
    strh r0, [r4, #0x80]           @ SOUNDCNT_L
    mov r0, #2
    strh r0, [r4, #0x82]           @ SOUNDCNT_H
    mov r0, r9, lsr #8             @ u: NOPs to skip after the wake
    and r0, r0, #7
    adr r1, uskip
    ldr r7, [r1, r0, lsl #2]
    probe_park 50
    add pc, pc, r7, lsl #2         @ 48 - U[u] skipped, U[u] run
    mov r0, r0
    .rept 48
    mov r0, r0
    .endr
    mov r0, #0x80
    strh r0, [r4, #0x84]           @ SOUNDCNT_X = 0x80 again
    ldr r0, =0xFF77
    strh r0, [r4, #0x80]           @ SOUNDCNT_L again
    ldr r0, =0xF0B0                @ ch1 NR11/NR12
    strh r0, [r4, #0x62]
    ldr r1, =0x8400                @ trigger, f = 0x400, length off
    and r0, r9, #3                 @ k: (k & 3) + 1 NOPs
    rsb r0, r0, #3
    add pc, pc, r0, lsl #2
    mov r0, r0
    .rept 4
    mov r0, r0
    .endr
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
    .ltorg
    .align 2
uskip:                             @ 48 - U[u]: NOPs skipped
    .word 48, 44, 40, 36, 32, 24, 16, 0
    probe_data
