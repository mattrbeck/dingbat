@ payload: romdataseq -- is a lone load from the gamepak that continues the
@ previous gamepak access's address sequential, when the code is not in the
@ gamepak?
@
@ The ARM7TDMI data sheet gives a single load's data cycle SEQ low (an N
@ cycle), and GBATEK ("GamePak Prefetch") says code in RAM or the BIOS
@ reading data from the gamepak is not affected by the prefetch bit. dingbat
@ used to price such a load S whenever it read the halfword after the last
@ gamepak access and the prefetcher was on, however long the CPU had been
@ elsewhere: Nintendo's HuffUnComp, walking a tree in the cartridge, ran a
@ frame fast in Klonoa 2 (docs/playtest-bugs.md, "Klonoa 2"; bus.nim
@ ROM_DATA_NONSEQ).
@
@ From IWRAM: (k & 15) + 1 one-cycle NOPs, ldrh A (0x08004000), two NOPs,
@ then ldrh of A + 2 (the halfword after it) or, for the control, of
@ A + 0x100 (not after it); TM0 from before the sled to just after the
@ second load. No branch between the loads (a branch out of the gamepak made
@ dingbat forget a halfword load's address, though not a byte load's at an
@ odd address, which HuffUnComp's tree walk makes: bit 7). The two paths are
@ the same length, so row DIFFERENCES between the A + 2 and A + 0x100 cells
@ are the second load's S-or-N.
@
@   r0 bits 0..3  k + 1 NOPs before the first load (its phase)
@      bit  4     WAITCNT 0x4000 (WS0 4/2, prefetcher on) instead of 0
@      bit  5     control: the second load reads A + 0x100
@      bit  6     answer the halfword the second load read instead of TM0:
@                 with the slot EMPTY it witnesses the access itself --
@                 addr >> 1 (0x2001 for A + 2) when nonsequential, 0xFFFF
@                 when sequential (slotfloat.s; WAITCNT 0 and 0x4000 are the
@                 two settings where the float is reliable). The emulators
@                 read their own image there: console-only cells.
@      bit  7     ldrb of A + 1, then of A + 3 (or A + 0x101)
@ answer: TM0 at the end (or, bit 6, the halfword read).
@
@ dingbat (ROM_DATA_NONSEQ) and both references: every A + 2 cell equals
@ its A + 0x100 control (0x19 at k = 0, 0x1A at k = 1), and bit 6 reads
@ 0x2001. The rule before: the same with the prefetcher off, but 2 less
@ with it on (0x10, 0x11, 0x90, 0x91 read 0x17, 0x18: S 3 for N 5), and
@ 0xFFFF for 0x50. Not yet run on the console (r0table.py --record
@ romdataseq, slot empty).
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    ldrh r7, [r5, #4]
    str r7, [r12, #32]             @ WAITCNT, restored below
    tst r9, #0x10
    moveq r0, #0
    movne r0, #0x4000
    strh r0, [r5, #4]
    mov r2, #0x08000000
    add r2, r2, #0x4000            @ A
    tst r9, #0x20
    addeq r3, r2, #2
    addne r3, r2, #0x100
    tst r9, #0x80
    adreq r7, halves
    adrne r7, bytes
    addne r2, r2, #1
    addne r3, r3, #1
    probe_park 50
    str r11, [r10]                 @ TM0 runs
    probe_sled
    bx r7
halves:
    ldrh r1, [r2]
    mov r0, r0
    mov r0, r0
    ldrh r6, [r3]
    probe_read_tm0 r1
    b collect
bytes:
    ldrb r1, [r2]
    mov r0, r0
    mov r0, r0
    ldrb r6, [r3]
    probe_read_tm0 r1
    b collect
collect:
    ldr r7, [r12, #32]
    strh r7, [r5, #4]
    tst r9, #0x40
    moveq r0, r1
    movne r0, r6
    probe_leave
    probe_data
