@ swplead.s -- does a channel 1 trigger just before a sweep clock miss it?
@
@ On the CGB a trigger within 8 T-cycles (4 on DMG) before a sweep clock
@ does not get that clock: its sweep timer starts one clock later (gambatte
@ sound/ch1_init_reset_sweep_counter_timing_*). On the GBA that lead would
@ be 32 cycles, if it is there at all.
@
@ NR10 = period 1, shift 1, and f = 0x400: the trigger check passes
@ (0x400 + 0x200), the first sweep clock writes back 0x600 and its second
@ check (0x600 + 0x300) stops the channel, so SOUNDCNT_X bit 0 falls on the
@ first sweep clock the trigger takes. A calibration note finds one sweep
@ clock by polling for that; a note at f = 0x080 then clears the shadow (the
@ trigger check also tests the previous shadow); and the measured note is
@ triggered about 131072 cycles (the next sweep clock) minus an offset after
@ the calibration death: 4c + k cycles earlier for larger c (c = r0 bits
@ 4..11, k = bits 0..3 through a sled).
@ answer: bits 0..15 polls (about 10 cycles each) from the measured trigger
@ until ch1 stopped (cap 0xFFFF): small = it took the clock right after it,
@ ~13000 = it missed that one and died at the next. Bits 16..31: polls the
@ calibration note lived.
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
    ldr r0, =0xFF77
    strh r0, [r4, #0x80]
    mov r0, #2
    strh r0, [r4, #0x82]
    mov r0, #0x11                  @ NR10: period 1, shift 1, add
    strh r0, [r4, #0x60]
    ldr r0, =0xF080                @ NR12 vol 15, NR11 duty 2, no length
    strh r0, [r4, #0x62]
    ldr r1, =0x8400                @ trigger, f = 0x400
    ldr r6, =0x8080                @ trigger, f = 0x080
    mov r2, r9, lsr #4
    and r2, r2, #0xFF
    rsb r2, r2, #256               @ 256 - c: less wait for larger c
    probe_park 50
    strh r1, [r4, #0x64]           @ calibration note
    mov r3, #0
    ldr r7, =0xFFFF
1:  ldrh r0, [r4, #0x84]
    tst r0, #1
    beq 2f
    add r3, r3, #1
    cmp r3, r7
    blt 1b
2:  strh r6, [r4, #0x64]           @ shadow to 0x080
    ldr r0, =32512                 @ 130048 cycles, then 4 (256 - c)
3:  subs r0, r0, #1
    bne 3b
4:  subs r2, r2, #1
    bne 4b
    probe_sled
    strh r1, [r4, #0x64]           @ the measured note
    mov r2, #0
5:  ldrh r0, [r4, #0x84]
    tst r0, #1
    beq 6f
    add r2, r2, #1
    cmp r2, r7
    blt 5b
6:  orr r0, r2, r3, lsl #16
    mov r1, #0
    strh r1, [r4, #0x84]           @ master off on the way out
    ldr r10, =0x04000100           @ probe_leave uses r10 and r11
    probe_leave
    probe_data
