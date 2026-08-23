@ msrtbit.s — WHAT: where execution resumes after `msr CPSR_c` sets the
@ Thumb bit from ARM state (UNPREDICTABLE per the ARM ARM).
@
@ HOW: a 24-byte block is copied to IWRAM: an ARM `msr` at A+0, then four
@ Thumb `adds r7, #imm` breadcrumbs at A+4/A+6/A+8/A+10 with distinct
@ immediates (1/2/4/8), a Thumb `str r7, [r6]` at A+12 and `bx r5` at
@ A+14.  r7's final value is a bitmask of exactly which halfwords
@ executed.  A TM3-overflow IRQ watchdog is armed first: if the core
@ wedges, the shared handler diverts the IRQ return to msr_recover.
@ A control run then enters the block in Thumb directly at A+4 (skipping
@ the msr) to prove the breadcrumb/str/bx mechanics themselves work.
@ The flags are pinned Z=1,C=1 before the msr so that if a core keeps
@ fetching ARM instead, the halfword pairs decode as condition-LO/MI
@ words that never execute and the trailing ARM `bx r5` nets it out.
@
@ WHY the expected values: silicon keeps the two words prefetched by the
@ ARM pipeline; on the switch it executes the LOW halfword of the word
@ at A+8 next, skips A+10, and continues normally from A+12.  Hence
@ r7 = 4 (only the A+8 add ran), the str stored marker word 4, the run
@ was clean (phase 1, no watchdog), and the control run's r7 = 0x0F.
@ Slot: +0 breadcrumb r7 = 04, +1 phase = 01, +2 control r7 = 0F,
@ +3 CPSR low byte at recovery = 1F (System, ARM), +4 marker word = 4.
@
@ PROVENANCE: verified on GBA SP AGS-001 (gbaedge page 8 MSRTBIT); see
@ docs/hwprobe-results-agb.md and tests/roms/gbaedge.s.
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
    .ascii "MSR THUMB BIT"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

probe:
    push {r4-r11, lr}
    ldr r2, =MARKER
    str sp, [r2, #12]
    @ copy the probe block into IWRAM
    ldr r0, =msr_block
    ldr r1, =IWBLOCK
    ldmia r0!, {r3-r8}
    stmia r1!, {r3-r8}
    ldr r8, =SLOT
    mov r0, #0
    str r0, [r2, #0]               @ marker word
    str r0, [r2, #16]              @ phase = 0 (main run)
    wdg_arm msr_recover
    @ go
    ldr r6, =MARKER                @ r6: thumb str target
    ldr r5, =msr_recover           @ r5: bx target from the block
    mov r7, #0
    mrs r4, CPSR
    orr r0, r4, #0x20              @ T bit
    cmp r7, #0                     @ pin flags: Z=1 C=1 (see block comment)
    ldr r1, =IWBLOCK
    bx  r1
msr_recover:
    ldr r2, =MARKER
    ldr sp, [r2, #12]              @ sp may be anything if we crashed wild
    wdg_disarm
    ldr r2, =MARKER                @ (wdg_disarm clobbered r2)
    ldr r8, =SLOT
    ldr r3, [r2, #16]              @ which phase was this?
    cmp r3, #1
    beq msr_after_control
    @ main run results
    strb r7, [r8, #0]
    ldr r3, [r2, #8]               @ 1 = clean, 2 = watchdog fired
    strb r3, [r8, #1]
    mrs r3, CPSR
    strb r3, [r8, #3]
    ldr r3, [r2, #0]
    str r3, [r8, #4]
    @ control run: enter the block in THUMB at A+4, skipping the MSR —
    @ validates that the breadcrumb/str/bx mechanics themselves work
    mov r0, #1
    str r0, [r2, #16]              @ phase = 1
    wdg_arm msr_recover
    mov r7, #0
    ldr r6, =MARKER
    ldr r5, =msr_recover
    ldr r1, =IWBLOCK + 4 + 1       @ thumb entry at A+4
    bx  r1
msr_after_control:
    wdg_disarm
    strb r7, [r8, #2]
    ldr r2, =MARKER
    mov r0, #0
    str r0, [r2, #8]
    pop {r4-r11, pc}
    .ltorg

@ The block run from IWRAM.  If MSR enters Thumb cleanly the adds
@ accumulate a distinct r7 per entry point, the str drops r7 at [r6], and
@ bx r5 recovers.  If the core instead keeps fetching ARM, the halfword
@ pairs decode as condition-LO / condition-MI words that the pinned Z=1,
@ C=1, N=0 flags skip, and the trailing ARM `bx r5` nets execution out.
msr_block:
    .word 0xE121F000               @ A+0: msr CPSR_c, r0
    .hword 0x3701                  @ A+4:  adds r7, #1   (thumb)
    .hword 0x3702                  @ A+6:  adds r7, #2
    .hword 0x3704                  @ A+8:  adds r7, #4
    .hword 0x3708                  @ A+10: adds r7, #8
    .hword 0x6037                  @ A+12: str r7, [r6]
    .hword 0x4728                  @ A+14: bx r5
    .word 0xE12FFF15               @ A+16: bx r5 (ARM safety net)
    .word 0xE12FFF15               @ A+20
    .ltorg


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x04,0x01,0x0F,0x1F,0x04,0x00,0x00,0x00
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
