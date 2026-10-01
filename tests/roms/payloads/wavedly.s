@ wavedly.s -- does channel 3's trigger start-up scale with the GBA's clock?
@
@ The CGB's wave channel starts 6 T-cycles late after a trigger (SameSuite
@ channel_3_restart_delay / _shift_delay pass at 5..6 only). On the GBA the
@ same 6 is either 6 system cycles or 6 of the PSG's 4 MHz ones (24). CH3's
@ pointer is not readable, but in 64-step mode (SOUND3CNT_L bit 5) the
@ played bank flips each time it wraps, and bit 6 reads that bank back. At
@ freq 0x7FF a sample is 8 cycles, so the first flip lands 32 samples =
@ 256 cycles plus the start-up after the trigger.
@
@ Parked on a V-count match, trigger, then 4c + k cycles (c = r0 bits 4..11,
@ k = bits 0..3 through a sled), then one read of SOUND3CNT_L.
@ answer: SOUND3CNT_L's low byte (bit 6: the bank playing); SOUNDCNT_X's
@ low byte << 8 (bit 2: CH3 on), the control that it is playing at all.
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
    mov r0, #0xA0                  @ DAC on, 64 samples, bank 0
    strh r0, [r4, #0x70]
    ldr r0, =0x2000                @ volume 100%
    strh r0, [r4, #0x72]
    ldr r1, =0x87FF                @ trigger, freq 0x7FF
    mov r2, r9, lsr #4
    and r2, r2, #0xFF
    add r2, r2, #1
    probe_park 50
    strh r1, [r4, #0x74]           @ trigger
1:  subs r2, r2, #1                @ 4c cycles
    bne 1b
    probe_sled
    ldrh r0, [r4, #0x70]
    and r0, r0, #0xFF
    ldrh r1, [r4, #0x84]           @ control: CH3 still on (bit 2)?
    and r1, r1, #0xFF
    orr r0, r0, r1, lsl #8
    mov r1, #0
    strh r1, [r4, #0x70]
    strh r1, [r4, #0x84]           @ master off on the way out
    ldr r10, =0x04000100           @ probe_leave uses r10 and r11
    probe_leave
    probe_data
