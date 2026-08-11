@ sweep.s — WHAT: PSG channel 1 sweep-unit corners no test suite pins:
@ divider-zero behavior and the trigger-time frequency checks.
@
@ HOW: with the PSG master on and channel 1 routed, each row programs
@ NR10-style sweep parameters, triggers the channel with a chosen
@ frequency, and polls SOUNDCNT_X bit0 counting iterations until the
@ channel's active flag drops (capped at 0x80000).  The competing sweep
@ models predict different death times: at-trigger (count 0), at a
@ sweep tick (a mid-range count), or never (the cap).
@
@ WHY the expected values, shift 1, increment, threshold 2048:
@   freq 1024 period 0: the sweep timer NEVER ticks with divider 0
@     (no period-0-acts-as-8 like the DMG lore) -> survives to the cap.
@   freq 1400: the immediate trigger calculation 1400+700 = 2100
@     overflows -> dies AT TRIGGER (0).
@   freq 1300: first trigger check passes (1950), but the check runs a
@     SECOND time on the recalculated frequency with the same offset:
@     1950+650 = 2600 -> dies AT TRIGGER (0).
@   freq 1000: second check value 2000 passes (and 1024's would be
@     exactly 2048, which also survives — the second check only fails
@     ABOVE 2048), so the note lives until the first sweep tick, whose
@     written-back 1500 re-check (1500+750 = 2250) kills it.  The poll
@     count is timing-jittery (hardware saw 0xF75 and 0xF9A on the two
@     sessions), so it is RANGE-checked 0x800..0x1800: below the band
@     means wrongly dead at trigger, above means dead too late.
@
@ PROVENANCE: verified on GBA SP AGS-001 (sessions 2+3, gbaedge page 23
@ SWEEPQ); see docs/hwprobe-results-agb.md.
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
    .ascii "SWEEP TRIGGER"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

probe:
    push {r4-r7, lr}
    ldr r8, =SLOT
    ldr r4, =0x04000060            @ SOUND1CNT_L base
    ldr r5, =0x04000080            @ SOUNDCNT_L/H/X
    mov r0, #0x80
    strh r0, [r5, #4]              @ master enable
    ldr r0, =0x1177
    strh r0, [r5]                  @ route ch1
.macro sq_run sweep, freq, slot_off
    ldr r0, =\sweep
    strh r0, [r4]                  @ SOUND1CNT_L
    ldr r0, =0xF000
    strh r0, [r4, #2]              @ max envelope, no length
    ldr r0, =0x8000 + \freq
    strh r0, [r4, #4]              @ trigger, length disabled
    mov r6, #0
    ldr r7, =0x80000
9:  ldrh r0, [r5, #4]
    tst r0, #1
    beq 8f
    add r6, r6, #1
    cmp r6, r7
    blt 9b
8:  str r6, [r8, #\slot_off]
.endm
    sq_run 0x01, 1024, 0           @ shift 1, period 0, up
    sq_run 0x21, 1400, 4           @ shift 1, period 2, up
    sq_run 0x21, 1300, 8
    sq_run 0x21, 1000, 12
    mov r0, #0
    strh r0, [r5, #4]              @ master off — silence again
    pop {r4-r7, pc}
    .ltorg


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x00,0x00,0x08,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x9A,0x0F,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
classes:
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x02,0x02,0x02,0x02
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .align 2
ranges:
    .word 12, 0x800, 0x1800
    .word 0xFFFFFFFF
    .include "runtime.inc"
