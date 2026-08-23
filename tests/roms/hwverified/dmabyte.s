@ dmabyte.s — WHAT: the DMA CNT_H byte-write anomaly.  Can a byte write
@ of 0x80 to the WRONG byte of DMA3CNT_H still enable the DMA (bus
@ byte-mirroring)?  Hardware: the anomaly is BIT7-GRANULAR, not a
@ byte-lane mirror, and holds on ALL FOUR channels (DMA0/1/2/3 alike).
@
@ HOW: before each poke DMA3 is primed with a valid ROM source, an
@ EWRAM destination whose first word is cleared as a marker, and a
@ 4-unit length (de_prime).  After the byte write and a few nops, the
@ marker says whether a transfer ran and DMA3CNT_H is read back
@ (de_verdict).  Seven pokes: 0x80 to the upper byte (0x040000DF,
@ where the enable bit lives), 0x80 to the lower byte (0x040000DE),
@ 0x44 to each byte as bit7-clear controls, then the granularity
@ discriminators: 0xC0 to the upper byte, 0xC0 to the lower byte, and
@ 0x40 to the upper byte as a bit7-clear control.
@
@ WHY the expected values: `strb 0x80` to the UPPER byte lands in BOTH
@ bytes — the DMA runs (marker = 1) and after the immediate transfer
@ self-disables, the readback is 0x0080: the enable bit is gone but
@ bit7 of the LOW byte (a src-control bit) stuck.  `strb 0x80` to the
@ LOWER byte stores NOTHING (readback 0x0000 — not even the bit7 it
@ named).  The 0x44 controls store normally under the register's bit
@ mask: 0x0040 low (dst-control bits) and 0x4400 high.  The 0xC0 rows
@ pin the granularity: upper-byte 0xC0 runs the DMA and reads back
@ 0x4080 — ONLY bit7 mirrored into the low byte (a whole-value mirror
@ would read 0x40C0); lower-byte 0xC0 reads back 0x0040 — bit7 is
@ dropped but bit6 stores (a whole-write drop would read 0x0000).
@ Upper-byte 0x40 stores normally (0x4000, no run).  So bit7 of a
@ CNT_H byte write mirrors into the other byte's bit7 when written
@ high-side and is dropped when written low-side; every other bit
@ behaves like a normal masked byte write.
@
@ PROVENANCE: verified on GBA SP AGS-001 (gbaedge pages 21 DMAEDGE, 27
@ IOBYTE and 30 DMABYTE2 — the 0x80 row on DMA0/1/2 and the 0xC0/0x40
@ rows on DMA3); see docs/hwprobe-results-agb.md.
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
    de_prime
    mov r0, #0xC0
    ldr r1, =0x040000DF
    strb r0, [r1]                  @ high byte, bit7+bit6: enable + IRQ-off
    nop                            @ granularity probe — 0x4080 = bit7-only
    nop                            @ mirror, 0x40C0 = whole-value mirror
    nop
    nop
    de_verdict 16
    de_prime
    mov r0, #0xC0
    ldr r1, =0x040000DE
    strb r0, [r1]                  @ low byte, bit7+bit6 — 0x0040 = bit6
    nop                            @ stores + bit7 dropped, 0x0000 = whole
    nop                            @ write dropped
    nop
    nop
    de_verdict 20
    de_prime
    mov r0, #0x40
    ldr r1, =0x040000DF
    strb r0, [r1]                  @ high byte, bit6 only (control: 0x4000,
    nop                            @ no run)
    nop
    nop
    nop
    de_verdict 24
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
    .byte 0x01,0x00,0x80,0x40,0x00,0x00,0x40,0x00
    .byte 0x00,0x00,0x00,0x40,0x00,0x00,0x00,0x00
classes:
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .align 2
ranges:
    .word 0xFFFFFFFF
    .include "runtime.inc"
