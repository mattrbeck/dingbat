@ payload: the first sound-FIFO refills at short timer periods (reload
@ 0xFFFF and up), from IWRAM
@
@ !! THE CONSOLE STOPPED ANSWERING during this payload's k = 6, 8, 12, 20
@ !! set (2026-09-25 08:29, ~90 runs in; which cell is unknown) after 632
@ !! runs of the sets below went through. Do not send it again until that
@ !! is understood; dingbat runs every cell of it.
@
@ WHAT: FIFO A on TM0 at reload 0x10000 - k, DMA1 sound FIFO 32-bit repeat
@ with its source fixed (IWRAM word 0xFEEDC0DE, or EWRAM), w words stored in
@ FIFO A first; TM0 and TM1 (/1) start together (TM1 a cycle later), n
@ one-cycle NOPs, then a TM1 read or a load from unused IO 0x04000FF0
@ (which word the open bus holds: the prefetched opcode, or the refill's
@ word when a burst came between the load's fetch and its data cycle --
@ Hades-Tests dma-latch test 4 at k = 1; tests/roms/payloads/hadeslatch.s).
@
@ AGB SP, 2026-09-25 (rig.ask, 2-3 interleaved passes, every cell one
@ answer). "extra" = TM1 - n - 6, the cycles DMA took before the read:
@  k = 1, w = 1 or 0, TM0 from ~0:  26 for n <= 11, 44 for 12..25, 62 for
@     26..39 -- 18 more every 14 NOPs (8 words, 32 bytes, per 32 cycles),
@     the first group 26; the load reads the refill's word at n = 12 only.
@  k = 1 over a stopped 0xFFFF: the same, a NOP earlier (n = 11).
@  k = 2: 20 for n <= 20, then 30.   k = 3: 11 at n = 0, 19 to n = 28, then 29.
@  k = 4: 0 at n = 0, 10 at n = 1..2, 20 from n = 3 on (to 39).
@ dingbat (single 10-cycle bursts a request apart) has k = 1: 20, then +10
@ every 6 NOPs; k = 2: 30 from n = 19; k = 3: 20 to n = 36; k = 4: 20 from
@ n = 1. Unmodelled: at k <= 3 the console runs refills in groups (18 =
@ one burst and one chained without its two lead cycles?) and holds them
@ off longer. A request delay of 3 at k = 1 against 4 at k = 20 (fifodma)
@ would put Hades-Tests dma-latch's word at its five NOPs.
@
@ SAFETY: as fifospk.s -- DMA0 armed on V-blank to write 0 to DMA1CNT_H,
@ TM0 stopped ~160 cycles before DMA1 is disabled, every register it
@ touches left off or as found, WAITCNT untouched.
@
@ r0 bits 0..7   n  NOPs (0..63)
@    bits 8..9   w  words stored in FIFO A before the start (0..3)
@    bit  10     TM0's count left at 0xFFFF before the enable (else ~0): an
@                enable over a stopped 0xFFFF overflows on its start cycle
@    bit  11     DMA1 source EWRAM 0x02004000 (else IWRAM, the page's own)
@    bit  12     load from 0x04000FF0 instead of reading TM1
@    bits 16..23 k: TM0 reload 0x10000 - k (0 = 1, the 0xFFFF of the title)
@ answer: TM1, or the loaded word; bit 31 of a TM1 answer = the guard ran
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
    mov r0, #0
    str r0, [r4, #0x104]           @ TM1 off
    strh r0, [r4, #0xC6]           @ DMA1 off
    strh r0, [r4, #0xBA]           @ DMA0 off
    @ TM0's count: run it from the reload and stop it again
    tst r11, #0x400
    ldreq r1, =0x00800000          @ from 0: stops at ~2
    ldrne r1, =0x0080FFFF          @ from 0xFFFF: every tick reloads 0xFFFF
    str r1, [r4, #0x100]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, #0
    add r1, r4, #0x100
    strh r0, [r1, #2]              @ stop (reload kept: 0xFFFF stays 0xFFFF)
    @ the guard: DMA0 on V-blank writes 0 to DMA1CNT_H, once
    adr r1, zero
    str r1, [r4, #0xB0]
    add r1, r4, #0xC6
    str r1, [r4, #0xB4]
    mov r1, #1
    strh r1, [r4, #0xB8]
    ldr r1, =0x9140                @ on, V-blank, 16-bit, src fixed, dst fixed
    strh r1, [r4, #0xBA]
    mov r1, #0x80
    strh r1, [r4, #0x84]           @ SOUNDCNT_X: master on
    ldr r1, =0x0B04
    strh r1, [r4, #0x82]           @ SOUNDCNT_H: FIFO A L+R, TM0, reset
    and r2, r11, #0x300
    movs r2, r2, lsr #8
    beq 2f
    ldr r3, =0x5A5A5A5A
1:  str r3, [r4, #0xA0]            @ w words into FIFO A
    subs r2, r2, #1
    bne 1b
2:
    adr r1, word
    tst r11, #0x800
    ldrne r1, =0x02004000
    str r1, [r4, #0xBC]            @ DMA1SAD
    ldr r1, =0x040000A0
    str r1, [r4, #0xC0]            @ DMA1DAD
    mov r1, #4
    strh r1, [r4, #0xC4]
    ldr r1, =0xB740
    strh r1, [r4, #0xC6]           @ DMA1: on, special, 32-bit, repeat, src+dst fixed
    and r0, r11, #0xFF             @ n
    rsb r0, r0, #64
    ldr r9, =sled
    add r9, r9, r0, lsl #2
    mov r7, r11, lsr #16
    ands r7, r7, #0xFF             @ k (0 = 1)
    moveq r7, #1
    rsb r7, r7, #0x10000
    orr r7, r7, #0x00800000        @ TM0: reload 0x10000 - k, /1, on
    mov r8, #0x00800000            @ TM1: /1, on
    add r1, r4, #0x100
    ldr r2, =0x04000FF0
    tst r11, #0x1000
    adreq r10, t_tm1
    adrne r10, t_obus
    mov lr, pc
    b go
    mov r5, r0                     @ the answer
    mov r0, #0
    str r0, [r4, #0x100]           @ TM0 off: no more requests
    mov r2, #40                    @ ~160 cycles: any burst still owed ends
1:  subs r2, r2, #1
    bne 1b
    str r0, [r4, #0x104]           @ TM1 off
    strh r0, [r4, #0xC6]           @ DMA1 off
    ldrh r2, [r4, #0xBA]
    tst r2, #0x8000
    tsteq r11, #0x1000
    orreq r5, r5, #0x80000000      @ the guard ran (TM1 answers only)
    strh r0, [r4, #0xBA]           @ DMA0 off
    ldr r0, saved
    orr r1, r0, #0x88000000        @ FIFO A and B reset, as found otherwise
    mov r1, r1, lsr #16
    strh r1, [r4, #0x82]
    strh r0, [r4, #0x84]
    mov r0, r5
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .align 2
saved:
    .word 0
zero:
    .word 0
word:
    .word 0xFEEDC0DE
    .ltorg
go:
    stmia r1, {r7, r8}             @ TM0, then TM1
    bx r9
    .align 2
sled:
    .rept 64
    mov r0, r0
    .endr
    bx r10
t_tm1:
    ldrh r0, [r1, #4]
    mov pc, lr
t_obus:
    ldr r0, [r2]
    mov pc, lr
    .ltorg
