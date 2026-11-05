@ payload: stphase3.s with s0trig.s's readout on the last trigger:
@ SOUNDCNT_X bit 0 at eight reads 3 cycles apart from the trigger's next
@ instruction, then polls until off -- when the shift-0 kill lands, to the
@ read, not only before or after the first poll.
@
@ stphase3.s on an AGB SP (2026-11-05, 512 cells, every one single-valued):
@ the last trigger's fate is one 16-phase pattern in its phase u from the
@ master-on's divider restart -- escapes at u = 12, 13 -- moved by 10 when
@ the 1400 row's trigger fell at u = 2..5.
@
@ r0 as stphase3.s (bits 0..7 variant and last row, 8..15 the delay loop,
@ 16..19 i, 24..27 k, 28..31 j).
@ answer: bits 0..7 the eight reads, bits 16..31 polls it stayed on after
@ them (cap 0xFFFF).
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
    and r0, r0, #0xFF
3:  subs r0, r0, #1
    bpl 3b
    mov r7, r9, lsr #16
    probe_sled r7
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
    strh r1, [r4]
    ldr r0, =0xF000
    strh r0, [r4, #2]
    orr r0, r2, #0x8000
    strh r0, [r4, #4]              @ the last trigger
    ldrh r0, [r5, #4]
    ldrh r1, [r5, #4]
    ldrh r2, [r5, #4]
    ldrh r3, [r5, #4]
    ldrh r6, [r5, #4]
    ldrh r7, [r5, #4]
    ldrh r11, [r5, #4]
    ldrh lr, [r5, #4]
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
    and r11, r11, #1
    orr r0, r0, r11, lsl #6
    and lr, lr, #1
    orr r0, r0, lr, lsl #7
    mov r3, #0
    ldr r2, =0xFFFF
4:  ldrh r1, [r5, #4]
    tst r1, #1
    beq 5f
    add r3, r3, #1
    cmp r3, r2
    blt 4b
5:  orr r0, r0, r3, lsl #16
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
