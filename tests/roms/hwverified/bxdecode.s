@ bxdecode.s — WHAT: which near-BX encodings actually execute as BX on
@ the ARM7TDMI?
@
@ HOW: each candidate word is copied to IWRAM at C with r1 pointing at a
@ Thumb pad (bit0 set) and breadcrumbs behind it: C+4 `add r7, #2`
@ (fallthrough), C+8 `add r7, #4` (also the $+8 landing site for
@ BX r15), C+12 `bx r5` (recover), pad: Thumb `adds r7, #1; bx r5`.
@ r7 = 1 means the candidate took the BX to r1, 6 = fell through as
@ two ordinary ARM instructions, 4 = branched to $+8.  Every candidate
@ runs under the TM3 watchdog with a known-good CPSR stashed, since a
@ candidate that decodes as a mode switch must not poison the next one.
@
@ WHY the expected values: the genuine `bx r1` (0xE12FFF11) takes the
@ branch (1).  The ARMv5 BLX-register word 0xE12FFF31 ALSO executes as
@ BX on ARM7TDMI — the "loose decode" is real silicon behavior (1).
@ `bx r15` (0xE12FFF1F) branches to $+8 in ARM state (4).  All three
@ run clean (phases 1/1/1).  The fourth near-BX word measured on
@ hardware, the SBO-violated 0xE120FF11, is deliberately NOT in this
@ ROM: on the real console it wedges the machine beyond any watchdog
@ (exception entry masks IRQs) and needs a power cycle.
@
@ PROVENANCE: verified on GBA SP AGS-001 (gbaedge page 24 BXDECODE,
@ one-candidate-per-press flow); see docs/hwprobe-results-agb.md.
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
    .ascii "BX DECODE"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

probe:
    push {r4-r11, lr}
    ldr r8, =SLOT
    mov r10, #0                    @ candidate index
bx_next:
    cmp r10, #3
    bge bx_done
    ldr r0, =bx_candidates
    ldr r9, [r0, r10, lsl #2]      @ candidate word
    @ build the block in IWRAM
    ldr r1, =IWBLOCK
    str r9, [r1, #0]
    ldr r0, =0xE2877002            @ add r7, r7, #2
    str r0, [r1, #4]
    ldr r0, =0xE2877004            @ add r7, r7, #4
    str r0, [r1, #8]
    ldr r0, =0xE12FFF15            @ bx r5
    str r0, [r1, #12]
    ldr r0, =0x47281C7F            @ thumb: adds r7, r7, #1 ; bx r5
    str r0, [r1, #16]
    ldr r2, =MARKER
    str sp, [r2, #12]
    mrs r0, CPSR
    str r0, [r2, #24]              @ known-good CPSR — a candidate that
                                   @ decodes as a mode switch must not
                                   @ poison the following candidates
    wdg_arm bx_recover
    ldr r5, =bx_recover
    ldr r1, =IWBLOCK
    add r0, r1, #16
    orr r1, r0, #1                 @ r1 -> thumb pad (BX target)
    mov r7, #0
    ldr r0, =IWBLOCK
    bx  r0
bx_recover:
    ldr r2, =MARKER                @ r0-r7 are unbanked in every mode, so
    ldr r3, [r2, #24]              @ this sequence works even if the
    msr CPSR_cxsf, r3              @ candidate switched mode (r8/r10 come
    ldr sp, [r2, #12]              @ back with the mode restore)
    wdg_disarm
    ldr r2, =MARKER                @ (wdg_disarm clobbered r2)
    strb r7, [r8, r10]             @ breadcrumb
    ldr r3, [r2, #8]               @ 1 = clean, 2 = watchdog fired
    add r0, r10, #4
    strb r3, [r8, r0]
    mov r0, #0
    str r0, [r2, #8]
    add r10, r10, #1
    b   bx_next
bx_done:
    pop {r4-r11, pc}
bx_candidates:
    .word 0xE12FFF11               @ control: genuine BX r1
    .word 0xE12FFF31               @ the BLX-r1 encoding (ARMv5, not v4T)
    .word 0xE12FFF1F               @ BX r15
    .ltorg


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x01,0x01,0x04,0x00,0x01,0x01,0x01,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
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
