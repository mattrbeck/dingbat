@ irqstorm.s — WHAT: a timer interrupt raised thousands of times while a
@ DMA burst holds the CPU off the bus is one interrupt, taken once, at a
@ fixed cycle after the burst ends.
@
@ WHY this is a test: an emulator that models the timer interrupt's
@ synchroniser (alyosha-tas/gba-tests irq/IF, irq/IE, Interactions/
@ Internal_Cycle_DMA_IRQ*) can easily book one piece of work per raise.
@ Outside a burst each raise is recognised a few cycles later and the work
@ drains; under a burst every raise waits for the burst's end, so the
@ bookings pile up. dingbat did exactly that for a while: every test ROM
@ it was written for passed, and Golden Nugget Casino, Caesar's Palace
@ Advance, Corvette and a SpongeBob beta crashed on a full scheduler
@ queue: each had TM0 running at /1 with its interrupt enabled through a
@ long 32-bit DMA (DMA3; DMA2 in Corvette) when the queue overflowed.
@ Rows 3-7 below crash such an emulator (row 2 is the size that still fits
@ a 64-entry queue); rows 0-1 check the no-DMA recognition, which the
@ "join the raise in flight" fix must not push back.
@
@ HOW: the experiment is tests/roms/payloads/irqstorm.s (see its header),
@ copied to IWRAM 0x03000000 and run once per row, exactly as the link
@ rig runs it on the console. TM0 overflows every P cycles with its
@ interrupt enabled; TM1 counts every cycle from TM0's start; DMA3 copies
@ N words EWRAM -> EWRAM. The handler stops TM0 first thing and reads TM1.
@ Each 4-byte cell: TM1 at handler entry (halfword), handler entries
@ (byte, must be 1), TM0's low byte where the stop froze it.
@
@   row  P    N        row  P    N
@   0    16   0        4    16   1024
@   1    1    0        5    1    1024
@   2    16   64       6    64   1024
@   3    16   128      7    256  4096
@
@ PROVENANCE: GBA SP AGS-001 through tools/hwlink (payloadcmp.py
@ on_hardware, the same payload bytes at the same address), 2026-09-23,
@ asked twice with identical answers. TM1 at entry: 47, 30, 801, 1569,
@ 12321, 12319, 12321, 49185; one entry each; TM0 low byte FF, FF, F1,
@ F1, F1, FF, E1, 21. The same bursts with no timer (TM1 read four NOPs
@ after the arming store) read 776, 12296 and 49160 for 64, 1024 and 4096
@ words on the console and in dingbat alike; dingbat (7ca348ebf) takes the
@ interrupt 2 cycles later than the console after every burst here (1 when
@ P = 1) and matches it with no DMA.
@
@ Verdict: white = never finished (the crash, or a hang), red = finished
@ with other values, green = the console's.
    .arm
    .text
    .global _start
_start:
    b   header_end
    .space 0x9C
    .space 0x20
header_end:
    b   main
rom_name:
    .ascii "IRQ STORM"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

.equ PAYLOAD_HOME, 0x03000000

probe:
    push {r4-r7, lr}
    adr r0, payload
    ldr r1, =PAYLOAD_HOME
    ldr r2, =payload_end
    adr r3, payload
    sub r2, r2, r3
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #4
    bgt 1b
    adr r4, rows
    ldr r5, =SLOT
    mov r6, #8
2:  ldr r0, [r4], #4
    ldr r7, =PAYLOAD_HOME
    mov lr, pc
    bx  r7
    str r0, [r5], #4
    subs r6, r6, #1
    bne 2b
    pop {r4-r7, pc}
    .ltorg
rows:
    .word 0xFFF00000, 0xFFFF0000, 0xFFF00040, 0xFFF00080
    .word 0xFFF00400, 0xFFFF0400, 0xFFC00400, 0xFF001000
    .align 2
payload:
    .incbin "irqstorm_payload.bin"
    .align 2
payload_end:

@ hardware-verified expectations (little-endian words: TM1 lo, TM1 hi,
@ entries, TM0 low byte)
    .align 2
expected:
    .byte 0x2F,0x00,0x01,0xFF, 0x1E,0x00,0x01,0xFF
    .byte 0x21,0x03,0x01,0xF1, 0x21,0x06,0x01,0xF1
    .byte 0x21,0x30,0x01,0xF1, 0x1F,0x30,0x01,0xFF
    .byte 0x21,0x30,0x01,0xE1, 0x21,0xC0,0x01,0x21
classes:
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .align 2
ranges:
    .word 0xFFFFFFFF
    .include "runtime.inc"
