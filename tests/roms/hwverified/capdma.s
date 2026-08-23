@ capdma.s — WHAT: video-capture DMA3 (Special timing).  Does it run
@ only every other frame (screen polarity inversion?), and does hardware
@ clear the enable bit itself?
@
@ HOW: DMA3 is armed at a vblank in Special timing with repeat, a fixed
@ nonzero ROM source and an incrementing EWRAM destination ring that
@ was zeroed first.  After each of three frames the ring's nonzero-word
@ count is snapshotted (capdma_count) — per-frame deltas of 160*4 mean
@ it triggered on every line; alternating deltas would mean every other
@ frame.
@ Then the enable readback answers the self-clear question, and the
@ second half re-arms at each of three successive vblanks — the pattern
@ games actually use — counting again.
@
@ WHY the expected values: every armed frame transfers 160 triggers x 4
@ words = 0x280, then the enable bit self-clears at frame end (readback
@ 0x3700 = the armed value minus the enable bit).  Re-arming at the
@ next vblank captures a full frame again — no alternation — and the
@ count stays 0x280 because a re-enable reloads the internal
@ destination from DAD, overwriting the ring in place.
@
@ PROVENANCE: verified on GBA SP AGS-001 (gbaedge page 22 CAPDMA, slot
@ CRC F9B7); see docs/hwprobe-results-agb.md.
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
    .ascii "CAPTURE DMA"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

.equ CAPDST, 0x02008000            @ capture destination ring

probe:
    push {r4-r7, lr}
    ldr r8, =SLOT
    ldr r0, =CAPDST                @ zero the ring
    mov r1, #0x1000
    mov r2, #0
1:  str r2, [r0], #4
    subs r1, r1, #1
    bne 1b
    bl  wait_vblank                @ arm at a frame boundary
    ldr r4, =0x040000D4
    ldr r0, =rom_pattern           @ nonzero source, held fixed
    str r0, [r4]
    ldr r0, =CAPDST
    str r0, [r4, #4]
    mov r0, #4
    strh r0, [r4, #8]              @ 4 words per trigger
    ldr r0, =0xB700                @ enable+repeat+special+word+src-fixed
    strh r0, [r4, #10]
    mov r7, #0
2:  bl  wait_vblank
    bl  capdma_count
    str r0, [r8, r7]
    add r7, r7, #4
    cmp r7, #12
    blt 2b
    ldrh r0, [r4, #10]             @ still armed?
    strh r0, [r8, #12]
    mov r0, #0
    strh r0, [r4, #10]
    @ the game pattern — re-arm at each vblank, count per frame
    mov r7, #16
2:  bl  wait_vblank                @ frame boundary: arm for this frame
    ldr r0, =0xB700
    strh r0, [r4, #10]
    bl  wait_vblank                @ the armed frame has now run
    bl  capdma_count
    str r0, [r8, r7]
    add r7, r7, #4
    cmp r7, #28
    blt 2b
    ldrh r0, [r4, #10]
    strh r0, [r8, #28]             @ did the re-armed enable self-clear too
    mov r0, #0
    strh r0, [r4, #10]
    pop {r4-r7, pc}
capdma_count:                      @ -> r0 = nonzero words in the ring
    ldr r1, =CAPDST
    mov r2, #0x1000
    mov r0, #0
1:  ldr r3, [r1], #4
    cmp r3, #0
    addne r0, r0, #1
    subs r2, r2, #1
    bne 1b
    bx  lr
    .ltorg
rom_pattern:
    .word 0x11223344
    .ltorg


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x80,0x02,0x00,0x00,0x80,0x02,0x00,0x00
    .byte 0x80,0x02,0x00,0x00,0x00,0x37,0x00,0x00
    .byte 0x80,0x02,0x00,0x00,0x80,0x02,0x00,0x00
    .byte 0x80,0x02,0x00,0x00,0x00,0x37,0x00,0x00
classes:
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .align 2
ranges:
    .word 0xFFFFFFFF
    .include "runtime.inc"
