@ sweeptrig.s -- dbsuite copy of the link-rig probe sweepq2.s the parent
@ session ran on the AGB SP on 2026-09-24 (the code is unchanged).
@
@ WHAT: channel 1 triggered with the sweep at shift 0 (NR10 = 0) at
@ frequency 0x400 and 0x3FF, with and without the length counter, and with
@ sweep 0x21 at 1300 on its own, after a master off/on and 0x1177 routing.
@ WHY: Pan Docs has the trigger's overflow check run only for a non-zero
@ shift.  On the console it runs at shift 0 too: 0x400 + (0x400 >> 0) =
@ 0x800 overflows and the channel never plays, at every trigger, with or
@ without length; 0x3FF + 0x3FF = 0x7FE does not, and the channel lives.
@ Sweep 0x21 at 1300 alone passes the trigger's checks (1950) and lives
@ to a tick; it dies at the trigger only straight after a row that died,
@ at half the phases of the 16-cycle clock (the apu suite's
@ sweep-trigger-second-check case brackets that one).
@ PROVENANCE: AGB SP via tools/hwlink (payloadcmp), 2026-09-24, delays
@ 30..45 (every phase of the 16-cycle clock): shift-0 0x400 dead at every
@ delay, length on or off; 0x3FF and 1300-alone alive at every delay.
@ The cells dbsuite checks were re-recorded by record.py into sp-agb.json.
@
@ r0 bits 0..1 variant, bits 8..23 delay loop count before the last trigger
@   0  master off/on, 0x1177, rows 0x01/1024, 0x21/1400, then the last row
@   1  master off/on, 0x1177, then the last row alone
@   2  master off/on, 0x1177, 0x21/1400, then the last row
@ the last row: 0x21 at 1300, or with bit 2 NR10 = 0, bit 3 f = 0x400,
@ bit 4 one less (0x3FF / 1299), bit 5 the length enable (counter 64)
@ answer: polls of SOUNDCNT_X bit 0 until ch1 stopped (cap 0x40000)
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r9, lr}
    mov r9, r0
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
    ldmfd sp!, {r4-r9, lr}
    bx lr
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
    .ltorg
