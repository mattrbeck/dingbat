@ nrx2table.s -- the NRx2 rewrite ("zombie") table on the AGB, by ear.
@
@ zombie.s's fourth take found one cell that is not the CGB's: 0x88 over a
@ playing volume-8, period-0, decreasing note leaves it at 6 (the CGB: 7).
@ This plays one cell per note so a recording of the speaker
@ (tools/hwlink/nrx2table_listen.py) can read the rest. Each note is
@ channel 2, 50% duty, f = 1917 (1000.5 Hz): NR22 = old, trigger, 0.15 s,
@ `count` writes of NR22 = new, 0.20 s more, channel off, 0.25 s silent.
@ Every new value has period 0, so after the write the volume holds still
@ to be measured; the before / after ratio within one note is what is read
@ (a capture that drops audio or drifts in gain cancels).
@
@ The table below is played three times. Predictions, before -> after:
@   R8  R12 R6 R10   references (no write)          8, 12, 6, 10
@   C1  80 -> 88     old p0 dec, new inc            CGB 8 -> 7   (zombie.s: 6)
@   C2  60 -> 68     old p0 dec, new inc            CGB 6 -> 9
@   C3  68 -> 68     old p0 inc, new inc            CGB 6 -> 7
@   C4  68 -> 60     old p0 inc, new dec p0         CGB 6 -> 10
@   C5  80 -> 80 x4  old p0 dec, new dec p0         CGB 8 -> 8
@   C6  87 -> 88     old p7 dec, new inc            CGB v -> 16 - (v + 2)
@   C7  6F -> 68     old p7 inc, new inc            CGB v -> v
@ (v = the volume an old period-7 envelope has reached at the write.)
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
    mov r0, #20                    @ 1.0 s of silence first
    bl wait
    ldr r0, =0xC080                @ sync: volume 12, 0.5 s
    bl tone
    mov r0, #10
    bl wait
    bl tone_off
    mov r0, #10
    bl wait
    mov r9, #3                     @ three rounds
round:
    adr r8, table
next:
    ldrb r0, [r8], #1              @ old NR22 (0 ends the table)
    cmp r0, #0
    beq done_round
    ldrb r2, [r8], #1              @ new NR22
    ldrb r3, [r8], #1              @ writes
    mov r0, r0, lsl #8
    orr r0, r0, #0x80              @ NR21 duty 2
    bl tone
    mov r0, #3                     @ 0.15 s
    bl wait
1:  subs r3, r3, #1
    strgeb r2, [r4, #0x69]
    bgt 1b
    mov r0, #4                     @ 0.20 s
    bl wait
    bl tone_off
    mov r0, #5                     @ 0.25 s silent
    bl wait
    b next
done_round:
    subs r9, r9, #1
    bne round
    mov r0, #0
    strh r0, [r4, #0x84]           @ master off on the way out
    ldr r0, =0x600D
    ldr r8, =0x040000B0            @ probe_leave uses r8 (DMA0), r10, r11
    ldr r10, =0x04000100
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

@ r0 units of 0.05 s (r1 only)
wait:
    mul r1, r0, r7
2:  subs r1, r1, #1
    bne 2b
    bx lr

    .align 2
table:  @ old NR22, new NR22, writes
    .byte 0x80, 0x00, 0            @ R8
    .byte 0x80, 0x88, 1            @ C1
    .byte 0xC0, 0x00, 0            @ R12
    .byte 0x60, 0x68, 1            @ C2
    .byte 0x60, 0x00, 0            @ R6
    .byte 0x68, 0x68, 1            @ C3
    .byte 0xA0, 0x00, 0            @ R10
    .byte 0x68, 0x60, 1            @ C4
    .byte 0x80, 0x80, 4            @ C5
    .byte 0x87, 0x88, 1            @ C6
    .byte 0x6F, 0x68, 1            @ C7
    .byte 0
    .align 2
    probe_data
