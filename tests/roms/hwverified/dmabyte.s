@ dmabyte.s — WHAT: the DMA3CNT_H byte-write anomaly.  Rumor said a
@ byte write of 0x80 to the WRONG byte of DMA3CNT_H can still enable
@ the DMA (bus byte-mirroring); hardware says the truth is stranger.
@
@ HOW: before each poke DMA3 is primed with a valid ROM source, an
@ EWRAM destination whose first word is cleared as a marker, and a
@ 4-unit length (de_prime).  After the byte write and a few nops, the
@ marker says whether a transfer ran and DMA3CNT_H is read back
@ (de_verdict).  Four pokes: 0x80 to the upper byte (0x040000DF, where
@ the enable bit lives), 0x80 to the lower byte (0x040000DE), then
@ 0x44 to each byte as bit7-clear controls.
@
@ WHY the expected values: `strb 0x80` to the UPPER byte lands in BOTH
@ bytes — the DMA runs (marker = 1) and after the immediate transfer
@ self-disables, the readback is 0x0080: the enable bit is gone but
@ bit7 of the LOW byte (a src-control bit) stuck.  `strb 0x80` to the
@ LOWER byte stores NOTHING (readback 0x0000 — not even the bit7 it
@ named).  The 0x44 controls store normally under the register's bit
@ mask: 0x0040 low (dst-control bits) and 0x4400 high.  So the anomaly
@ is bit7-specific, not a general byte-lane mirror.
@
@ PROVENANCE: verified on GBA SP AGS-001 (sessions 2+3, gbaedge pages
@ 21 DMAEDGE and 27 IOBYTE); see docs/hwprobe-results-agb.md.
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
    .ascii "DMA BYTE WRITE"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

probe:
    push {r4-r7, lr}
    ldr r8, =SLOT
    ldr r4, =0x040000D4            @ DMA3SAD
.macro de_prime
    ldr r0, =rom_pattern
    str r0, [r4]                   @ SAD
    ldr r5, =EWDST + 0x100
    mov r0, #0
    str r0, [r5]                   @ clear the marker
    str r5, [r4, #4]               @ DAD
    mov r0, #4
    strh r0, [r4, #8]              @ CNT_L: 4 units
    mov r0, #0
    strh r0, [r4, #10]             @ CNT_H: fully disabled, plain config
.endm
.macro de_verdict slot_off
    ldr r5, =EWDST + 0x100
    ldr r0, [r5]
    cmp r0, #0
    movne r0, #1
    strb r0, [r8, #\slot_off]
    ldrh r0, [r4, #10]
    strh r0, [r8, #\slot_off + 2]
    mov r0, #0
    strh r0, [r4, #10]             @ off again
.endm
    de_prime
    mov r0, #0x80
    ldr r1, =0x040000DF
    strb r0, [r1]                  @ enable via its own byte
    nop
    nop
    nop
    nop
    de_verdict 0
    de_prime
    mov r0, #0x80
    ldr r1, =0x040000DE
    strb r0, [r1]                  @ the OTHER byte — should not enable
    nop
    nop
    nop
    nop
    de_verdict 4
    de_prime
    mov r0, #0x44
    ldr r1, =0x040000DE
    strb r0, [r1]                  @ low byte, bit7 clear
    nop
    nop
    nop
    nop
    de_verdict 8
    de_prime
    mov r0, #0x44
    ldr r1, =0x040000DF
    strb r0, [r1]                  @ high byte, bit7 clear (no enable bit)
    nop
    nop
    nop
    nop
    de_verdict 12
    pop {r4-r7, pc}
    .ltorg
rom_pattern:
    .word 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00
    .ltorg


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x01,0x00,0x80,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x40,0x00,0x00,0x00,0x00,0x44
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
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
