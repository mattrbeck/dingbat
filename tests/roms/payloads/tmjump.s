@ tmjump.s -- a prescaled timer read back-to-back across the start of
@ V-blank: does a read ever step by anything but 0 or 1?
@
@ TM2 at prescaler r0 (1 = 64, 2 = 256, 3 = 1024 cycles a tick), started
@ once; then 16 frames of: halt to line 159, read TM2 in a tight loop until
@ VCOUNT reads 161. Any pair of consecutive reads whose difference (mod
@ 65536) is not 0 or 1 is counted, and the first eight are kept at
@ 0x02008000 as (previous, read) words. answer: the count.
@
@ The console reads none at any prescaler (AGB SP, 2026-10-02). dingbat
@ read one 0 every 16 frames: its per-frame rebase left a timer's anchor
@ in the future of the rebased clock, so a read in the frame's first few
@ cycles took the "not started yet" path (gba.nim end_frame). Found by
@ envrestart.s, whose waits on TM2 came back early.
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    and r0, r9, #3
    orr r0, r0, #0x80
    mov r0, r0, lsl #16
    str r0, [r10, #8]              @ TM2: reload 0, the prescaler, on
    ldr r6, =0x02008000            @ the first jumps: previous, read
    mov r7, #0                     @ count
    mov r3, #16                    @ frames
0:  probe_park 159
    ldrh r1, [r10, #8]
1:  ldrh r2, [r10, #8]
    sub r0, r2, r1
    mov r0, r0, lsl #16
    cmp r0, #0x10000
    bls 2f                         @ 0 or 1
    cmp r7, #8
    addlo r0, r6, r7, lsl #3
    strlo r1, [r0]
    strlo r2, [r0, #4]
    add r7, r7, #1
2:  mov r1, r2
    ldrh r0, [r4, #6]
    cmp r0, #161
    bne 1b
    subs r3, r3, #1
    bne 0b
    mov r0, #0
    str r0, [r10, #8]
    mov r0, r7
    probe_leave
    probe_data
