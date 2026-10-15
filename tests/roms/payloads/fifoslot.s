@ fifoslot.s -- alyosha fifo_dma/fifo's FIFO refills, with the burst read
@ out of the empty cartridge slot
@
@ WHAT: fifospk's geometry (FIFO A on TM0 reload 0x10000 - k, DMA1 sound
@ FIFO 32-bit repeat, TM1 /1 started a cycle after TM0, n one-cycle NOPs,
@ a TM1 read) with fifo_dma/fifo's setup: SOUNDCNT_H = 0 (FIFO A on TM0,
@ no speaker), WAITCNT 0, and DMA1's source either EWRAM or the gamepak slot
@ at 0x08000150, fixed or incrementing (fifo.gba bursts from 0x08000150,
@ fixed, under WAITCNT 0). Optionally six words are stored to FIFO A while
@ SOUNDCNT_X's master enable is off, as fifo.gba's test 2 does.
@ WHY: fifo.gba (alyosha, 2023-09-01 upload) reads TM1 = 0x68 where dingbat
@ reads 0x62 in its tests 2, 3 and 4. The ROM's first upload said test 2
@ "also tests that fixed source address in ROM uses all non-sequential
@ accesses" -- six cycles more per burst, which is exactly 0x68 -- and the
@ next day's source retracts that ("gives unexpected results on hardware")
@ without a new binary. A burst read out of the slot costs the same wait
@ states as one read out of a cartridge (the memory controller owns them),
@ so this asks the console which: 2 + 4 x (5+3) + 4 = 38 cycles (every word
@ nonsequential) or 2 + (5+3) + 3 x (3+3) + 4 = 32 (sequential after the
@ first), for a fixed and for an incrementing source; and whether the six
@ words stored with the master off reach the FIFO (if they do, the first
@ overflow asks for nothing).
@ PROVENANCE: AGB SP via tools/hwlink (rig.ask, 3 interleaved passes,
@ every cell one answer), 2026-10-14; 644 cells in r0-agb.json (fifoslot),
@ frozen in tests/roms/cyclelaws/fifoslot.gba.
@  - a fixed source in the slot bursts exactly as an incrementing one, 32
@    cycles (sequential after the first word): the "all nonsequential" rule
@    fifo.gba's 2023-09-01 upload states, and its author retracted the next
@    day, is not the console's. EWRAM: 30.
@  - the six stores with the master off reach nothing: w = 1 reads as w = 0.
@  - NOT as dingbat had it: the second refill comes right behind the first
@    when the second overflow falls in the first burst's last words. Rules,
@    gba/apu/dma_channels.nim: FIFO_LEVEL_AT_OVERFLOW (an overflow inside a
@    burst counts only the words written by its cycle), FIFO_DROP_BUSY (a
@    request inside the channel's own burst is lost), FIFO_HANDBACK_CHAIN (one
@    on its last cycle takes the next burst's first read there, the rest at
@    the next request). Fitted on sets a, b, w, ksweep, late (k = 26..36,
@    EWRAM and slot); then predicted before the run and matched cell for
@    cell: conf, 266 cells (IWRAM bursts at k = 8..14 -- dropped, chained,
@    back to back, one and two cycles apart, none -- and the chained bursts'
@    second halves at k = 29 / 31).
@
@ SAFETY: fifospk.s's way out (TM0 stopped, ~160 cycles of nothing, then
@ DMA1 off: alyosha's unsafe/fifo_dma_disable_jam crashes a console by
@ disabling a FIFO DMA in the cycle its request arrives). No V-blank guard
@ (a guard that disables DMA1 can land on a request in the same way, and
@ with DMA1 writing FIFO A the refills cannot chain: each burst adds 16
@ bytes, an overflow takes one). Only WAITCNT 0 is safe in the empty slot.
@ TM0 is scrubbed before anything is armed so that a previous cell that
@ stopped it at 0xFFFF does not overflow this cell's start (fifospk.s).
@
@ r0 bits 0..7   n  one-cycle NOPs after the timers start (0..127)
@    bits 8..15  k  TM0 period
@    bits 16..17 s  DMA1 source: 0 EWRAM 0x02004000 incrementing,
@                   1 slot 0x08000150 fixed (fifo.gba), 2 the slot
@                   incrementing, 3 EWRAM fixed; with bit 19,
@                   4 IWRAM 0x03004000 incrementing
@    bit  18     w  six words stored to FIFO A with the master off
@ answer: TM1 as read
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    mov r4, #0x04000000
    ldrh r0, [r4, #0x84]
    ldrh r1, [r4, #0x82]
    orr r0, r0, r1, lsl #16
    str r0, saved                  @ SOUNDCNT_H << 16 | SOUNDCNT_X
    add r2, r4, #0x200
    ldrh r0, [r2, #4]
    str r0, savedw                 @ WAITCNT
    mov r0, #0
    strh r0, [r2, #4]              @ WAITCNT 0 (the only safe one for the slot)
    str r0, [r4, #0x100]           @ TM0 off
    str r0, [r4, #0x104]           @ TM1 off
    strh r0, [r4, #0xC6]           @ DMA1 off
    @ scrub TM0: an enable loads the reload (0), so a count left at 0xFFFF
    @ by the last cell cannot overflow this cell's start; DMA1 is off
    add r3, r4, #0x100
    mov r1, #0x80
    strh r1, [r3, #2]
    strh r0, [r3, #2]
    @ fifo.gba: master off, SOUNDCNT_H = 0, the stores, master on
    strh r0, [r4, #0x84]           @ SOUNDCNT_X: master off (empties FIFO A)
    strh r0, [r4, #0x82]           @ SOUNDCNT_H: FIFO A on TM0, no speaker
    tst r11, #0x40000
    beq 1f
    str r0, [r4, #0xA0]
    str r0, [r4, #0xA0]
    str r0, [r4, #0xA0]
    str r0, [r4, #0xA0]
    str r0, [r4, #0xA0]
    str r0, [r4, #0xA0]
1:  mov r1, #0x80
    strh r1, [r4, #0x84]           @ SOUNDCNT_X: master on
    and r0, r11, #0x30000
    tst r11, #0x80000
    orrne r0, r0, #0x40000         @ s bit 2
    adr r1, sources
    ldr r1, [r1, r0, lsr #14]
    str r1, [r4, #0xBC]            @ DMA1SAD
    ldr r1, =0x040000A0
    str r1, [r4, #0xC0]            @ DMA1DAD = FIFO A
    mov r1, #4
    strh r1, [r4, #0xC4]
    adr r1, controls
    ldr r1, [r1, r0, lsr #14]
    strh r1, [r4, #0xC6]           @ DMA1: on, special, 32-bit, repeat
    and r0, r11, #0xFF             @ n
    rsb r0, r0, #128
    ldr r9, =sled
    add r9, r9, r0, lsl #2
    and r0, r11, #0xFF00
    mov r0, r0, lsr #8
    rsb r7, r0, #0x10000
    orr r7, r7, #0x00800000        @ TM0: reload, /1, on (no IRQ)
    mov r8, #0x00800000            @ TM1: /1, on
    add r1, r4, #0x100
    mov lr, pc
    b go
    mov r5, r0                     @ the answer
    mov r0, #0
    str r0, [r4, #0x100]           @ TM0 off: no more requests
    mov r2, #40                    @ ~160 cycles: any burst still owed ends
2:  subs r2, r2, #1
    bne 2b
    str r0, [r4, #0x104]           @ TM1 off
    strh r0, [r4, #0xC6]           @ DMA1 off
    ldr r0, saved
    orr r1, r0, #0x88000000        @ FIFO A and B reset, as found otherwise
    mov r1, r1, lsr #16
    strh r1, [r4, #0x82]
    strh r0, [r4, #0x84]
    ldr r0, savedw
    add r2, r4, #0x200
    strh r0, [r2, #4]
    mov r0, r5
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .align 2
saved:
    .word 0
savedw:
    .word 0
sources:
    .word 0x02004000, 0x08000150, 0x08000150, 0x02004000, 0x03004000
controls:
    .word 0xB640, 0xB740, 0xB640, 0xB740, 0xB640   @ src incrementing / fixed, dst fixed
    .ltorg
go:
    stmia r1, {r7, r8}             @ TM0, then TM1
    bx r9                          @ into the sled (a branch: fixed cost)
    .align 2
sled:
    .rept 128
    mov r0, r0
    .endr
    ldrh r0, [r1, #4]
    mov pc, lr
    .ltorg
