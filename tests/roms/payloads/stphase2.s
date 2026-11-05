@ payload: stphase.s with a second sled, between the f = 1024 row and the
@ 1400 row, so the last trigger's phase against the master-on and against
@ the 1400 row's trigger can be told apart.
@
@ stphase.s on an AGB SP (2026-11-05, 256 cells, every one single-valued):
@ after the shift-1 rows, the shift-0 f = 0x400 trigger's fate is a
@ function of its 16-cycle phase u from the master-on's divider restart in
@ those cells -- lives at u = 12, 13; one poll at 14, 15, 0, 1 and 9; none
@ otherwise -- but there the 1400 row's phase moved with it.
@
@ r0 as stphase.s (bits 0..23 sweeptrig.s's, bits 24..27 k: a (k & 15) + 1
@ cycle sled after the wake), bits 28..31 j: a (j & 15) + 1 cycle sled
@ before the 1400 row.
@ answer: polls of SOUNDCNT_X bit 0 until ch1 stopped (cap 0x40000).
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    mov r7, r9, lsr #24
    probe_park 100
    probe_sled r7
    stmfd sp!, {r4, r5}
    ldr r4, =0x04000060
    ldr r5, =0x04000080
    mov r0, #0
    strh r0, [r5, #4]
    mov r0, #0x80
    strh r0, [r5, #4]
    ldr r0, =0x1177
    strh r0, [r5]
    and r1, r9, #3
    cmp r1, #0
    bne 1f
    ldr r1, =0x01
    ldr r2, =1024
    bl row
1:  and r1, r9, #3
    cmp r1, #1
    beq 2f
    mov r7, r9, lsr #28
    probe_sled r7
    ldr r1, =0x21
    ldr r2, =1400
    bl row
2:  mov r0, r9, lsr #8
    ldr r1, =0xFFFF
    and r0, r0, r1
3:  subs r0, r0, #1
    bpl 3b
    tst r9, #4
    ldreq r1, =0x21
    movne r1, #0                   @ bit 2: NR10 = 0 (shift 0)
    tst r9, #8
    ldreq r2, =1300
    ldrne r2, =0x400               @ bit 3: f = 0x400
    tst r9, #0x10
    subne r2, r2, #1               @ bit 4: one less (0x3FF / 1299)
    tst r9, #0x20
    orrne r2, r2, #0x4000          @ bit 5: length enable (counter 64 - 0)
    bl row
    mov r1, #0
    strh r1, [r5, #4]
    ldmfd sp!, {r4, r5}
    probe_leave
@ r1 = NR10, r2 = frequency; returns the poll count in r0
row:
    strh r1, [r4]
    ldr r0, =0xF000
    strh r0, [r4, #2]
    orr r0, r2, #0x8000
    strh r0, [r4, #4]              @ trigger (+ length enable if bit 14)
    mov r0, #0
    ldr r3, =0x40000
9:  ldrh r6, [r5, #4]
    tst r6, #1
    beq 8f
    add r0, r0, #1
    cmp r0, r3
    blt 9b
8:  bx lr
    probe_data
