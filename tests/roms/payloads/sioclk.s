@ payload: an SIO transfer started on the external clock, then switched to
@ the internal clock with Start still set (docs/playtest-bugs.md §101)
@
@ Nintendo's link start-up in Coloris and Dial Hex starts a normal 32-bit
@ transfer on the external clock (SIOCNT 0x5080: nothing clocks it), and on
@ the next pass sets SC (0x5081) with Start still set, then stores Start
@ again with a byte write. Both references then complete the transfer;
@ dingbat starts one only on Start's rising edge, so it stays busy.
@ GBATEK does not say what switching SC does to an active transfer.
@
@   r0 bits 0..1  0  control: start on the internal clock from idle
@                 1  start on the external clock, then set SC (halfword)
@                 2  as 1, then the games' byte store of Start (0x85)
@                 3  control: start on the external clock, no switch
@ answer: TM0 cycles from the start store until Start reads clear
@         (0xFFFF: still busy after 12288 cycles, ~0.7 ms)
@         | IF bit 7 (serial) << 16 | SIOCNT's low byte at the end << 24,
@         less bit 2 (SI: low on the rig, where the link adapter drives it;
@         high with no cable)
@ Cell 3 is not in the recorded row: the host's next poll clocks it, at a
@ time of the host's choosing (9.8k-11.8k cycles in nine runs on the SP).
@
@ The monitor's host clocks the link about every 2 ms while a payload runs;
@ the measured window is a fraction of that, so a stray host clock shows as
@ a lone outlier among a cell's repeats, not as the cell's answer. SIOCNT
@ goes back to 0x1000 (stopped) before returning; the monitor re-arms the
@ port and RCNT itself.
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    ldr r6, =0x04000120            @ SIODATA32; SIOCNT at +8
    ldr r1, =0x12345678
    str r1, [r6]
    add r3, r4, #0x100
    mov r1, #0
    strh r1, [r3, #0x34]           @ RCNT: SIOCNT chooses the mode
    and r7, r9, #3
    mov r1, #0x5000                @ IRQ enable, 32-bit, external clock, 256 kHz
    cmp r7, #0
    orreq r1, r1, #1               @ the control starts on the internal clock
    strh r1, [r6, #8]
    orr r2, r1, #0x80              @ the start store
    orr r3, r2, #1                 @ SC set with Start still set
    mov r0, #0x85                  @ the byte store of Start
    ldr r9, =0x3000                @ the window, in TM0 cycles (r8 is probe_leave's)
    probe_timers_start
    strh r2, [r6, #8]
    cmp r7, #1
    cmpne r7, #2
    streqh r3, [r6, #8]
    cmp r7, #2
    streqb r0, [r6, #8]
1:  ldrh r1, [r6, #8]
    ldrh r2, [r10]                 @ TM0, read with every poll
    tst r1, #0x80
    beq 2f
    cmp r2, r9
    bls 1b
    ldr r2, =0xFFFF
2:  ldrh r1, [r6, #8]              @ SIOCNT at the end
    ldrh r3, [r5, #2]              @ IF
    mov r0, #0x1000
    strh r0, [r6, #8]              @ stop: external clock, Start clear
    and r1, r1, #0xFB              @ less bit 2, SI: the link adapter holds it low
    and r3, r3, #0x80
    mov r0, r2
    orr r0, r0, r3, lsl #9         @ IF bit 7 -> bit 16
    orr r0, r0, r1, lsl #24
    probe_leave
    probe_data
