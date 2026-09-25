@ fsgap.s -- how long after a SOUNDCNT_X master-on does a length enable
@ still get the extra length clock at every 512 Hz phase?
@
@ fsfirst.s triggers ch2 (counter 1, trigger + length enable) 4 cycles
@ after the master-on write, and the AGB SP gave the extra clock -- the
@ note reloads to 63 and outlives the poll cap -- in all 31 cells;
@ psgfirst.s triggers 16 cycles after and gets it only when the 512 Hz
@ tap rule does. This page puts g one-cycle NOPs between the two writes.
@ While g is inside the window every run reaches the cap; past it the cell
@ goes two-valued with the 512 Hz phase (the cap, or a death within one
@ step). dingbat: gba/apu/abstract_channels.nim PSG_POWER_ON_WINDOW.
@
@   r0 bits 0..4  g: g + 1 NOPs between the master-on and the NR21/22 store
@ answer: TM0 at the first poll that saw ch2 off | polls << 16 (bit 16 of
@ the poll count is lost: the cap reads TM0 alone)
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    mov r3, #0
    strh r3, [r4, #0x84]           @ master off (clears the PSG)
    ldr r6, =0xF03F                @ vol 15, counter 64 - 63 = 1
    ldr r7, =0xC000                @ trigger + length enable
    mov r2, #0x80
    and r1, r9, #0x1F
    rsb r1, r1, #31                @ NOPs to skip
    probe_park 50
    str r11, [r10]                 @ TM0 runs
    strh r2, [r4, #0x84]           @ master on
    add pc, pc, r1, lsl #2         @ g + 1 NOPs
    mov r0, r0
    .rept 32
    mov r0, r0
    .endr
    strh r6, [r4, #0x68]
    strh r7, [r4, #0x6C]
    mov r3, #0
    ldr r2, =0x20000
1:  ldrh r0, [r4, #0x84]
    tst r0, #2
    beq 2f
    add r3, r3, #1
    cmp r3, r2
    blt 1b
2:  ldrh r1, [r10]
    mov r0, #0
    strh r0, [r4, #0x84]           @ master off on the way out
    orr r0, r1, r3, lsl #16
    probe_leave
    probe_data
