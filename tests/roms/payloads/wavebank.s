@ wavebank.s -- which wave RAM bank does the CPU see on the AGB, and does a
@ read while channel 3 plays return the byte being played?
@
@ GBATEK (SOUND3CNT_L): "The currently selected Bank Number (Bit 6) will be
@ played back, while reading/writing to/from wave RAM will address the other
@ (not selected) bank." The CGB instead resolves a CPU access against the
@ byte under the pointer while CH3 plays. The two agree on every access made
@ with CH3 stopped (each is self-consistent), so this page reads while it
@ plays.
@
@ Wave RAM is filled with A = 10 11 .. 1F while bank 0 is selected and with
@ B = 20 21 .. 2F while bank 1 is, then read back. Answer: word n (r0 bits
@ 0..4) of the 80-byte block below.
@   words  0..3   idle, bank 0 selected
@   words  4..7   idle, bank 1 selected
@   words  8..11  just after a trigger, playing bank 0 (freq 0: 16384 cycles
@                 a sample, so the pointer is still at 0)
@   words 12..15  about five samples later
@   words 16..19  after NR30 selects bank 1 while playing
@ Other-bank (GBATEK): A A | A A B, each the whole 16-byte pattern.
@ Byte-being-played:   A B | 10*16, 12*16, 22*16 (one byte repeated).
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    mov r0, #0
    strh r0, [r4, #0x84]           @ master off (clears the PSG) and on
    mov r0, #0x80
    strh r0, [r4, #0x84]
    ldr r0, =0xFF77
    strh r0, [r4, #0x80]
    mov r0, #2
    strh r0, [r4, #0x82]
    ldr r7, =blk
    mov r0, #0x00                  @ DAC off, bank 0 selected
    strh r0, [r4, #0x70]
    ldr r1, =0x1110                @ A
    bl fill
    mov r0, #0x40                  @ DAC off, bank 1 selected
    strh r0, [r4, #0x70]
    ldr r1, =0x2120                @ B
    bl fill
    mov r0, #0x00
    strh r0, [r4, #0x70]
    add r6, r7, #0
    bl dump
    mov r0, #0x40
    strh r0, [r4, #0x70]
    add r6, r7, #16
    bl dump
    mov r0, #0x80                  @ DAC on, bank 0, 32 samples
    strh r0, [r4, #0x70]
    ldr r0, =0x2000                @ volume 100%
    strh r0, [r4, #0x72]
    ldr r0, =0x8000                @ trigger, freq 0
    strh r0, [r4, #0x74]
    add r6, r7, #32
    bl dump
    ldr r0, =20480                 @ ~81920 cycles: five samples
1:  subs r0, r0, #1
    bne 1b
    add r6, r7, #48
    bl dump
    mov r0, #0xC0                  @ DAC on, bank 1 selected, still playing
    strh r0, [r4, #0x70]
    add r6, r7, #64
    bl dump
    mov r0, #0
    strh r0, [r4, #0x70]
    strh r0, [r4, #0x84]           @ master off on the way out
    and r0, r9, #0x1F
    ldr r0, [r7, r0, lsl #2]
    ldr r10, =0x04000100           @ probe_leave uses r10 and r11
    probe_leave

@ eight halfwords r1, r1 + 0x0202, ... into 0x04000090
fill:
    mov r2, #0
    ldr r3, =0x0202
2:  add r0, r4, #0x90
    strh r1, [r0, r2]
    add r1, r1, r3
    add r2, r2, #2
    cmp r2, #16
    blt 2b
    bx lr

@ the 16 bytes at 0x04000090 (as halfwords) into [r6]
dump:
    mov r2, #0
3:  add r0, r4, #0x90
    ldrh r1, [r0, r2]
    strh r1, [r6, r2]
    add r2, r2, #2
    cmp r2, #16
    blt 3b
    bx lr

    .ltorg
    .align 2
blk:
    .space 80
    probe_data
