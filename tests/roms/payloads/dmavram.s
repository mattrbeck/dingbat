@ payload: dmavram -- a DMA burst from VRAM to VRAM while the mode-3 bitmap
@ is being fetched, against the phase of the line it starts on.
@
@ dbsuite's dmatime-burst-vram-mode3 (gbaedge DMATIME +12) reads 0xB1 on the
@ console at a position of its page that nothing fixed. This is its burst
@ -- DMA3, sixteen words 06010000 -> 06010100, immediate, mode 3 with BG2
@ on -- started k cycles after a V-count-9 wake. Answer: TM0 after the
@ burst, less k.
@
@ AGB SP (link rig, 2026-09-25, 9 runs a cell): 0x1E5 at k = 0-2 of every
@ four and 0x1E6 at the fourth (spin 6, k = 3, 7, 11), 0x1D0 under forced
@ blank, halfwords as words -- the burst pays the bitmap's dots at the same
@ phases as the core's contention model. About one run in 80 answers 0x1D0
@ at a random cell (the wake missed the bitmap); r0table.py leaves out the
@ two cells that did it during the recording.
@
@   r0 bits 0..3  k: the sled's (k & 15) + 1 NOPs
@      bits 4..7  spin count / 16 (coarse: 64 cycles a step)
@      bit  8     forced blank (the no-contention control)
@      bit  9     halfwords: 32 units of 16 bits
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    ldrh r1, [r4]
    str r1, [r12, #32]             @ DISPCNT
    ldr r1, =0x0403                @ mode 3, BG2
    tst r9, #0x100
    orrne r1, r1, #0x80
    strh r1, [r4]
    add r7, r4, #0xD4              @ DMA3
    ldr r0, =0x06010000
    str r0, [r7]
    ldr r0, =0x06010100
    str r0, [r7, #4]
    ldr r6, =0x84000010
    tst r9, #0x200
    ldrne r6, =0x80000020
    and r2, r9, #0xF0
    add r2, r2, #1
    probe_park 9
    probe_timers_start
1:  subs r2, r2, #1                @ 4 cycles a count, as probe_spin
    bne 1b
    probe_sled
    str r6, [r7, #8]
    mov r0, r0                     @ the instruction the burst waits for
    mov r0, r0
    probe_read_tm0 r1
    and r0, r9, #0x0F
    sub r0, r1, r0
    mov r1, #0
    str r1, [r7, #8]
    ldr r1, [r12, #32]
    strh r1, [r4]
    probe_leave
    probe_data
