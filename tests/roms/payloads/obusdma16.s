@ obusdma16.s -- what a HALFWORD DMA leaves on the data bus
@
@ obusprobe.s, obuswin.s and obuswint.s measured the post-DMA window with a
@ 32-bit DMA only: one NOP after the burst an unmapped read returns the last
@ word it moved (DEADBEE3), and from Thumb in IWRAM two NOPs after it the
@ latch is half DMA word, half fresh opcode (DEAD6019): the latch is two
@ halves. Nothing has measured what a 16-bit burst puts in those halves.
@ dingbat duplicates the last halfword into both (dma.nim, `half or (half
@ shl 16)`); that is a model, not a measurement.
@
@ Every row: an immediate DMA3 (or DMA0), 16-bit, then ONE NOP (the open
@ window), then `ldr` of 0x10000000. Source halfwords at h0..h3 =
@ 1111 2222 3333 BEE3 (h1 and h3 in the upper lane of their word). The
@ source copy is in IWRAM (a 32-bit bus) or EWRAM (a 16-bit bus).
@
@   +0   IWRAM, from h2, 2 units -> SCRATCH     last read BEE3 (upper lane),
@                                                the one before 3333 (lower)
@   +4   IWRAM, from h1, 2 units -> SCRATCH     last 3333 (lower), before 2222
@   +8   IWRAM, from h3, 1 unit  -> SCRATCH     BEE3 alone (upper)
@   +12  IWRAM, from h2, 1 unit  -> SCRATCH     3333 alone (lower)
@   +16..+28  the same four from the EWRAM copy
@   +32  IWRAM, from h2, 2 units -> SCRATCH+2   the writes' lanes swapped
@                                                (BEE3 written to a lower lane)
@   +36  EWRAM, the same as +32
@   +40  DMA0 (cannot write the gamepak), IWRAM from h2, 2 units -> 0x08000000:
@        the reads happen, the writes do not
@   +44  control: the 32-bit DMA of obuswin.s's one-NOP row (DEADBEE3)
@   +48  marker 'OB16'
@
@ Hypotheses and what each predicts (x = the half of the opcode fetch the
@ burst displaced, unknown in advance):
@   H1 a halfword is on both lanes, by read or by write (dingbat's model;
@      ARM7TDMI stores replicate a halfword across the bus):
@      +0 BEE3BEE3  +4 33333333  +8 BEE3BEE3  +12 33333333, EWRAM the same,
@      +32 BEE3BEE3 +36 BEE3BEE3  +40 BEE3BEE3
@   H2 each read drives only its source address's lane (the Thumb-fetch
@      placement rule of section 12), the write changes nothing:
@      +0 BEE33333  +4 22223333  +8 BEE3xxxx  +12 xxxx3333, EWRAM the same,
@      +32 BEE33333 +36 BEE33333 +40 BEE33333
@   H3 each WRITE drives only its destination address's lane (the DMA's
@      write cycle is the bus's last word); a lane no write reached keeps
@      the fetch's half:
@      +0 BEE33333  +4 33332222  +8 xxxxBEE3  +12 xxxx3333, EWRAM the same,
@      +32 3333BEE3 +36 3333BEE3  +40 as H2 (no write happens)
@   H4 the bus width decides (the Thumb fetch rule, section 11): reads from
@      a 32-bit region drive their lane, from a 16-bit one both lanes:
@      IWRAM rows +0..+12, +32, +40 as H2; EWRAM rows +16..+28, +36 as H1
@   In every hypothesis +44 = DEADBEE3 (the measured 32-bit control).
@
@ Emulators, 2026-10-14 (payloadcmp.py --emulators-only --block=0x02008000:13):
@   dingbat and mGBA both H1 in every row; +44 DEADBEE3. No console run yet:
@   the hypotheses above are the pre-registration.
    .arm
    .text
    .global _start

.equ UNMAP,    0x10000000
.equ RESULTS,  0x02008000
.equ SCRATCH,  0x02009000
.equ EWSRC,    0x02009100
.equ DMA0SAD,  0x040000B0
.equ DMA3SAD,  0x040000D4
.equ MARKER,   0x3631424F          @ 'OB16'

@ one row: SAD, DAD, CNT stores, the NOP, the unmapped read into r0
.macro d16 chan, src, dst, cnt
    ldr r0, =\src
    ldr r1, =\dst
    ldr r2, =\chan
    ldr r3, =\cnt
    str r0, [r2, #0]
    str r1, [r2, #4]
    str r3, [r2, #8]
    mov r0, r0                     @ the one NOP: the window obuswin.s found open
    ldr r0, [r7]
.endm

.macro row slot, chan, src, dst, cnt
    d16 \chan, \src, \dst, \cnt
    str r0, [r10, #\slot]
.endm

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r7,  =UNMAP
    ldr r10, =RESULTS

    @ the EWRAM copy of the source halfwords
    ldr r0, =src16
    ldr r1, =EWSRC
    ldr r2, [r0]
    str r2, [r1]
    ldr r2, [r0, #4]
    str r2, [r1, #4]

    row 0,  DMA3SAD, src16 + 4, SCRATCH, 0x80000002
    row 4,  DMA3SAD, src16 + 2, SCRATCH, 0x80000002
    row 8,  DMA3SAD, src16 + 6, SCRATCH, 0x80000001
    row 12, DMA3SAD, src16 + 4, SCRATCH, 0x80000001
    row 16, DMA3SAD, EWSRC + 4, SCRATCH, 0x80000002
    row 20, DMA3SAD, EWSRC + 2, SCRATCH, 0x80000002
    row 24, DMA3SAD, EWSRC + 6, SCRATCH, 0x80000001
    row 28, DMA3SAD, EWSRC + 4, SCRATCH, 0x80000001
    row 32, DMA3SAD, src16 + 4, SCRATCH + 2, 0x80000002
    row 36, DMA3SAD, EWSRC + 4, SCRATCH + 2, 0x80000002
    row 40, DMA0SAD, src16 + 4, 0x08000000, 0x80000002
    row 44, DMA3SAD, src32, SCRATCH, 0x84000004

    ldr r0, =MARKER
    str r0, [r10, #48]
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

    .align 2
src16:
    .hword 0x1111, 0x2222, 0x3333, 0xBEE3
src32:
    .word 0x11111111, 0x22222222, 0x33333333, 0xDEADBEE3
