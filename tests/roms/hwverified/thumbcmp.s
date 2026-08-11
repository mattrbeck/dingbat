@ thumbcmp.s — WHAT: Thumb hi-register operations with rd = pc.  Does
@ CMP load SPSR into CPSR (like the ARM S-suffixed rd=15 forms)?  Do
@ hi-reg ADD/MOV to pc touch CPSR at all, and where do they branch?
@
@ HOW: each experiment runs in IRQ mode with SPSR preloaded to
@ 0x9000009F — SYSTEM mode, I set, N|V flags — deliberately a DIFFERENT
@ mode than the executing one, so a full restore is distinguishable from
@ a flags-only transfer by the mode bits that come back.  CPSR flags are
@ cleared going in.  A tiny Thumb pad executes the one instruction under
@ test and `bx r3` returns to ARM code that captures CPSR/SPSR.  The
@ ADD/MOV pads carry breadcrumb adds so r7 says where execution landed
@ (0 = branched to pad+8 / pad+6, 7 = fell through).
@
@ WHY the expected values: hardware performs a FULL CPSR restore on
@ CMP pc (readback 9000009F whole, mode bits switched to System); the
@ SPSR read right after returns 9000009F too because the restore left
@ us in System mode, where SPSR reads return CPSR.  ADD pc and MOV pc
@ never touch CPSR (00000092: still IRQ mode, flags still clear) and
@ branch to the exact operand value: the ADD lands on pad+8 (r7 = 0)
@ and the MOV operand computes to pad+6, so its r7 = 4.
@
@ PROVENANCE: verified on GBA SP AGS-001 (sessions 2+3, gbaedge pages
@ 18 THUMBPC and 25 THUMBPC2); see docs/hwprobe-results-agb.md.
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
    .ascii "THUMB CMP PC"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

probe:
    push {r4-r11, lr}
    ldr r8, =SLOT
    mrs r9, CPSR                   @ saved good state (system mode)
    @ ── Thumb cmp pc, r0 with a DIFFERENT-mode SPSR ──
    bic r0, r9, #0x1F
    orr r0, r0, #0x92              @ IRQ mode, I set
    msr CPSR_c, r0
    ldr r0, =SCRATCH + 0xF0
    mov sp, r0                     @ sp_irq hygiene (never used)
    ldr r1, =0x9000009F            @ SYSTEM mode, I set, N|V
    msr SPSR_cxsf, r1
    msr CPSR_f, #0
    mov r0, #0
    adr r3, 21f
    adr r1, 20f
    orr r1, r1, #1
    bx  r1
    .thumb
20: .hword 0x4587                  @ cmp pc, r0
    .hword 0x4718                  @ bx r3
    .align 2
    .arm
21: mrs r1, CPSR
    str r1, [r8, #0]
    mrs r1, SPSR
    str r1, [r8, #4]
    msr CPSR_c, r9                 @ back to known system state
    msr CPSR_f, r9
    @ ── Thumb add pc, r0 (branch?  and does it touch CPSR?) ──
    bic r0, r9, #0x1F
    orr r0, r0, #0x92
    msr CPSR_c, r0
    ldr r1, =0x9000009F
    msr SPSR_cxsf, r1
    msr CPSR_f, #0
    mov r0, #4                     @ target = pad+4+4 = pad+8
    mov r7, #0
    adr r3, 23f
    adr r1, 22f
    orr r1, r1, #1
    bx  r1
    .thumb
22: .hword 0x4487                  @ add pc, r0
    .hword 0x3701                  @ +2: adds r7, #1   (fallthrough path)
    .hword 0x3702                  @ +4: adds r7, #2
    .hword 0x3704                  @ +6: adds r7, #4
    .hword 0x4718                  @ +8: bx r3         (branch target)
    .align 2
    .arm
23: mrs r1, CPSR
    str r1, [r8, #8]
    strb r7, [r8, #16]
    msr CPSR_c, r9
    @ ── Thumb mov pc, r0 ──
    bic r0, r9, #0x1F
    orr r0, r0, #0x92
    msr CPSR_c, r0
    ldr r1, =0x9000009F
    msr SPSR_cxsf, r1
    msr CPSR_f, #0
    adr r3, 25f
    adr r1, 24f
    add r0, r1, #7                 @ = pad+6 with bit0 set; ARM7TDMI MOV
    bic r0, r0, #1                 @ pc ignores bit0 — pass it even
    orr r1, r1, #1
    mov r7, #0
    bx  r1
    .thumb
24: .hword 0x4687                  @ mov pc, r0
    .hword 0x3701                  @ +2: adds r7, #1
    .hword 0x3702                  @ +4: adds r7, #2
    .hword 0x3704                  @ +6: adds r7, #4
    .hword 0x4718                  @ +8: bx r3
    .align 2
    .arm
25: mrs r1, CPSR
    str r1, [r8, #12]
    strb r7, [r8, #17]
    msr CPSR_c, r9
    msr CPSR_f, r9
    pop {r4-r11, pc}
    .ltorg


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x9F,0x00,0x00,0x90,0x9F,0x00,0x00,0x90
    .byte 0x92,0x00,0x00,0x00,0x92,0x00,0x00,0x00
    .byte 0x00,0x04,0x00,0x00,0x00,0x00,0x00,0x00
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
