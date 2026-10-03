@ envrestart.s -- does an NRx2 write to a playing channel make the NEXT
@ trigger's envelope start one clock early? Heard, not read
@ (tools/hwlink/envrestart_listen.py).
@
@ The music engine most GBA games use ends a note with NRx2 = 0x08 and a
@ trigger (the channel keeps running at volume 0), and starts the next one
@ by writing its envelope -- increasing from 0, a non-zero period -- and
@ triggering at once. The write takes the period from 0 to non-zero on a
@ running channel, which on the CGB costs one extra envelope clock at the
@ next odd frame-sequencer step (SameSuite channel_1_nrx2_speed_change). The
@ question is whether that clock survives the trigger that follows.
@
@ Each note is one 0.5625 s slot (36 envelope clocks of 262144 cycles,
@ timed on TM2 at 256 cycles a tick, so every slot starts at the same
@ frame-sequencer phase), t = 0 at the slot's start:
@   0       A / ref: NRx2 = 0 (DAC off).  B: NRx2 = 0x08 and trigger --
@           running at volume 0, the engine's note-off
@   T0 = 4E + phase * E/4 (E = one envelope clock, 15.625 ms):
@           NRx2 = 0x09 (0x0A for the period-2 rows; a ref's own value) and
@           trigger, back to back.  B20: the write 20 ms before T0
@   T0 + 6.5E  NRx2 = value & 0xF8: the envelope freezes where it is
@           (period 0, same direction: no volume change, nrx2table.s C7)
@   T0 + 19.5E DAC off; silent to the slot's end
@ So each case note ends in a 203 ms steady level, read against the ref
@ notes (period 0, volumes 4 / 6 / 8 / 10). A freezes at the number of
@ envelope clocks in its 6.5E; B0 at one more if the extra clock survives
@ the trigger, the same if not; B20 lets the extra clock fire before the
@ trigger (the control). Channel 2 and 1 at f = 1917 (1000.5 Hz, duty 50%),
@ channel 4 periodic (7-bit) noise, NR43 = 0x1A.
@ In the emulators (2026-10-02): dingbat B0 = A + 1 at every period-1 cell
@ of all three channels (the clock survives); mGBA and the second
@ reference B0 = A everywhere. B20 = A in all three.
@ answer: 0x600D when it has played everything.
    .include "probe.inc"
    .arm
    .text
    .global _start

    .equ E, 1024                   @ an envelope clock in TM2 ticks
    .equ K_REF, 0
    .equ K_A, 1
    .equ K_B0, 2
    .equ K_B20, 3

    @ chan 1 / 2 / 4, kind, NRx2 value, phase 0..3
    .macro note chan, kind, val, phase=0
    .if \chan == 1
    mov r1, #0x63
    mov r2, #0x64
    mov r3, #0x8700
    orr r3, r3, #0x7D
    .elseif \chan == 2
    mov r1, #0x69
    mov r2, #0x6C
    mov r3, #0x8700
    orr r3, r3, #0x7D
    .else
    mov r1, #0x79
    mov r2, #0x7C
    mov r3, #0x8000
    orr r3, r3, #0x1A
    .endif
    mov r6, #\val
    mov r9, #\kind
    orr r9, r9, #(\phase << 8)
    bl play
    .endm

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
    mov r0, #0x08                  @ NR10: no sweep; negate keeps the AGB's
    strh r0, [r4, #0x60]           @ shift-0 trigger check from stopping ch1
    mov r0, #0x80                  @ NR11 / NR21 duty 50%, NR41 length 0
    strb r0, [r4, #0x62]
    strb r0, [r4, #0x68]
    mov r0, #0
    strb r0, [r4, #0x78]
    ldr r0, =0x00820000            @ TM2: 256 cycles a tick
    str r0, [r10, #8]
    ldrh r7, [r10, #8]             @ r7: the schedule, in ticks
    ldr r0, =16384
    bl wait_for
    bl wait_for                    @ 0.5 s silence
    ldr r0, =0xC080                @ sync: ch2 volume 12, 0.5 s
    strh r0, [r4, #0x68]
    ldr r0, =0x877D
    strh r0, [r4, #0x6C]
    ldr r0, =16384
    bl wait_for
    bl wait_for
    mov r0, #0x80
    strh r0, [r4, #0x68]           @ DAC off
    ldr r0, =16384
    bl wait_for
    bl wait_for

    note 2, K_REF, 0x80
    note 2, K_A,   0x09, 0
    note 2, K_B0,  0x09, 0
    note 2, K_B20, 0x09, 0
    note 2, K_REF, 0x40
    note 2, K_A,   0x09, 1
    note 2, K_B0,  0x09, 1
    note 2, K_B20, 0x09, 1
    note 2, K_REF, 0x60
    note 2, K_A,   0x09, 2
    note 2, K_B0,  0x09, 2
    note 2, K_B20, 0x09, 2
    note 2, K_REF, 0xA0
    note 2, K_A,   0x09, 3
    note 2, K_B0,  0x09, 3
    note 2, K_B20, 0x09, 3
    note 2, K_REF, 0x80
    note 2, K_A,   0x0A, 1
    note 2, K_B0,  0x0A, 1
    note 2, K_A,   0x0A, 3
    note 2, K_B0,  0x0A, 3
    note 2, K_REF, 0x60
    note 1, K_REF, 0x80
    note 1, K_A,   0x09, 0
    note 1, K_B0,  0x09, 0
    note 1, K_A,   0x09, 1
    note 1, K_B0,  0x09, 1
    note 1, K_REF, 0x40
    note 1, K_A,   0x09, 2
    note 1, K_B0,  0x09, 2
    note 1, K_A,   0x09, 3
    note 1, K_B0,  0x09, 3
    note 1, K_REF, 0xA0
    note 4, K_REF, 0x80
    note 4, K_A,   0x09, 0
    note 4, K_B0,  0x09, 0
    note 4, K_A,   0x09, 1
    note 4, K_B0,  0x09, 1
    note 4, K_REF, 0x40
    note 4, K_A,   0x09, 2
    note 4, K_B0,  0x09, 2
    note 4, K_A,   0x09, 3
    note 4, K_B0,  0x09, 3
    note 4, K_REF, 0xA0

    mov r0, #0
    strh r0, [r4, #0x84]           @ master off on the way out
    str r0, [r10, #8]              @ TM2 off
    ldr r0, =0x600D
    ldr r8, =0x040000B0            @ probe_leave uses r8 (DMA0), r10, r11
    ldr r10, =0x04000100
    probe_leave

@ One slot. r1 = NRx2's offset, r2 = the trigger halfword's, r3 = its value,
@ r6 = NRx2, r9 = kind | phase << 8. r7 = the slot's start on entry, its
@ end on return.
play:
    push {lr}
    and r0, r9, #0xFF
    cmp r0, #K_B0
    movge r0, #0x08                @ B: the note-off, running at volume 0
    movlt r0, #0
    strb r0, [r4, r1]
    strgeh r3, [r4, r2]
    mov r0, r9, lsr #8             @ phase
    mov r0, r0, lsl #8             @ * E / 4
    add r0, r0, #(4 * E)
    and lr, r9, #0xFF
    cmp lr, #K_B20
    bne 1f
    ldr lr, =1311                  @ B20: the write 20 ms early
    sub r0, r0, lr
    bl wait_for
    strb r6, [r4, r1]
    ldr r0, =1311
    bl wait_for
    strh r3, [r4, r2]
    b 2f
1:  bl wait_for
    strb r6, [r4, r1]              @ write and trigger back to back
    strh r3, [r4, r2]
2:  ldr r0, =(6 * E + E / 2)
    bl wait_for
    and r0, r6, #0xF8
    strb r0, [r4, r1]              @ freeze
    ldr r0, =(13 * E)
    bl wait_for
    mov r0, #0
    strb r0, [r4, r1]              @ DAC off
    mov r0, r9, lsr #8
    mov r0, r0, lsl #8
    rsb r0, r0, #(12 * E + E / 2)  @ to 36E from the slot's start
    bl wait_for
    pop {lr}
    bx lr

@ r7 += r0, then wait until TM2 reaches r7 (mod 65536; r0 < 32768).
@ r0 survives; r8 does not.
wait_for:
    add r7, r7, r0
3:  ldrh r8, [r10, #8]
    sub r8, r8, r7
    movs r8, r8, lsl #16
    bmi 3b
    bx lr

    probe_data
