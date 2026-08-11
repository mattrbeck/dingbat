@ iomap.s — WHAT: what unused and write-only IO registers return on
@ reads — zero or open bus?  Emulators guess differently per register.
@
@ HOW: 16 halfword reads in table order, stored raw, before ANYTHING
@ writes IO (so write-only registers still hold boot values and the
@ answer is purely what a read returns).  Open-bus reads from ROM
@ return the prefetch latch, i.e. this ROM's own code bytes near the
@ read loop — deterministic for this exact binary, which is why those
@ cells can be exact-checked (they reproduced byte-for-byte on
@ hardware): 0x6001 and 0xE256 are halves of the loop's own opcodes.
@
@ WHY the expected values: 0x66/0x6A/0x78 (sound gaps), 0x136/0x142
@ (SIO/JOY gaps — the "reads 0" lore is real for these) and
@ 0x206/0x20A read ZERO; everything else sampled — the write-only PPU
@ registers 0x10/0x28/0x40/0x4C/0x54 and the unused 0x4E/0x56, plus
@ 0x110 (timer gap) and 0x12C — returns open bus.
@
@ PROVENANCE: verified on GBA SP AGS-001 (session 2, gbaedge page 16
@ IORW, slot CRC 626A — dingbat matched it byte-for-byte on the day);
@ see docs/hwprobe-results-agb.md.
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
    .ascii "IO READ MAP"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

probe:
    push {r4-r6, lr}
    ldr r4, =SLOT
    ldr r5, =iorw_offsets
    mov r6, #16
    ldr r3, =IOBASE
1:  ldrh r0, [r5], #2
    ldrh r0, [r3, r0]
    strh r0, [r4], #2
    subs r6, r6, #1
    bne 1b
    pop {r4-r6, pc}
iorw_offsets:
    .hword 0x010                   @ BG0HOFS   (write-only)
    .hword 0x028                   @ BG2X_L    (write-only)
    .hword 0x040                   @ WIN0H     (write-only)
    .hword 0x04C                   @ MOSAIC    (write-only)
    .hword 0x04E                   @ unused
    .hword 0x054                   @ BLDY      (write-only)
    .hword 0x056                   @ unused
    .hword 0x066                   @ unused (reads zero on hardware)
    .hword 0x06A                   @ unused (reads zero)
    .hword 0x078                   @ unused (reads zero)
    .hword 0x110                   @ unused, timer gap (open bus)
    .hword 0x12C                   @ unused (open bus)
    .hword 0x136                   @ unused (reads zero)
    .hword 0x142                   @ unused (reads zero)
    .hword 0x206                   @ unused (reads zero)
    .hword 0x20A                   @ unused (reads zero)
    .ltorg


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x01,0x60,0x01,0x60,0x01,0x60,0x01,0x60
    .byte 0x56,0xE2,0x01,0x60,0x56,0xE2,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x01,0x60,0x01,0x60
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
classes:
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .align 2
ranges:
    .word 0xFFFFFFFF
    .include "runtime.inc"
