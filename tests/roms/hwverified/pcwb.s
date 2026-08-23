@ pcwb.s — WHAT: LDR/STR/STM/LDM base writeback with r15 as the base
@ register — does the writeback reach the program counter, and where
@ does execution land?
@
@ HOW: each candidate word executes with a breadcrumb sled of
@ `add r7, r7, #imm` (distinct powers of two) directly behind it, under
@ the TM3 watchdog.  The candidate sits at C, so the ARM pipeline base
@ value r15 = C+8.  r7's sum keys the landing site.  The first three
@ rows (offset +4) use a four-add sled (1/2/4/8): 15 = fell straight
@ through, 12 = resumed at base+4, 8 = base+8.  The five functional-form
@ rows use a five-add sled (1/2/4/8/16 at C+4..C+20): 1F = fell through
@ or landed base-4,
@ 1C = base+4, 18 = base+8, 10 = base+12.  r1 is zeroed first so the
@ load rows also show whether the loaded value arrived.
@
@ WHY the expected values: hardware's rule is "PC := the writeback
@ address (+4 extra for ldr, whose LOAD is suppressed)" for the
@ single-transfer forms, and NO writeback at all for the block forms:
@   ldmia r15!, {r1}   no wb (r7=0F), load happens: r1 = [base] =
@                      the sled's own `add r7, r7, #2` = 0xE2877002
@   str r1, [r15], #4  PC := base+4 (r7=0C)
@   ldr r1, [r15], #4  PC := base+8 (r7=08), r1 stays 0
@   str r1, [r15], #8  PC := base+8 (r7=18) — kills "fixed base+4"
@   ldr r1, [r15], #8  PC := base+12 (r7=10), r1 stays 0 — kills
@                      "fixed base+8"
@   str r1, [r15], #-4 PC := base-4 (r7=1F)
@   str r1, [r15, #4]! pre-indexed wb reaches PC too (r7=1C)
@   stmia r15!, {r1}   NO writeback — stores, then falls through to
@                      the next instruction (r7=1F), like ldm
@ No watchdog fires (+3 = 0).
@
@ PROVENANCE: verified on GBA SP AGS-001 (gbaedge page 25 THUMBPC2
@ writeback rows; page 29 PCWB2 — the functional-form discriminators and
@ the stm row); see docs/hwprobe-results-agb.md.
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
    .ascii "R15 WRITEBACK"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

probe:
    push {r4-r11, lr}
    ldr r8, =SLOT
    mov r11, #0                    @ watchdog-fired bitmask
    wdg_arm tw_rec1
    mov r7, #0
    mov r1, #0
    .word 0xE8BF0002               @ ldmia r15!, {r1}
    add r7, r7, #1                 @ C+4
    add r7, r7, #2                 @ C+8:  base
    add r7, r7, #4                 @ C+12: base+4
    add r7, r7, #8                 @ C+16: base+8
tw_rec1:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #1
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #0]
    str r1, [r8, #4]
    wdg_arm tw_rec2
    mov r7, #0
    mov r1, #0
    .word 0xE48F1004               @ str r1, [r15], #4
    add r7, r7, #1
    add r7, r7, #2
    add r7, r7, #4
    add r7, r7, #8
tw_rec2:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #2
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #1]
    wdg_arm tw_rec3
    mov r7, #0
    mov r1, #0
    .word 0xE49F1004               @ ldr r1, [r15], #4
    add r7, r7, #1
    add r7, r7, #2
    add r7, r7, #4
    add r7, r7, #8
tw_rec3:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #4
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #2]
    str r1, [r8, #8]
    @ ── the functional-form rows (five-add sleds) ──
    wdg_arm tw_rec4
    mov r7, #0
    mov r1, #0
    .word 0xE48F1008               @ str r1, [r15], #8
    add r7, r7, #1                 @ C+4
    add r7, r7, #2                 @ C+8:  base
    add r7, r7, #4                 @ C+12: base+4
    add r7, r7, #8                 @ C+16: base+8
    add r7, r7, #16                @ C+20: base+12
tw_rec4:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #8
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #12]
    wdg_arm tw_rec5
    mov r7, #0
    mov r1, #0
    .word 0xE49F1008               @ ldr r1, [r15], #8
    add r7, r7, #1
    add r7, r7, #2
    add r7, r7, #4
    add r7, r7, #8
    add r7, r7, #16
tw_rec5:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #16
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #13]
    str r1, [r8, #20]
    wdg_arm tw_rec6
    mov r7, #0
    mov r1, #0
    .word 0xE40F1004               @ str r1, [r15], #-4
    add r7, r7, #1
    add r7, r7, #2
    add r7, r7, #4
    add r7, r7, #8
    add r7, r7, #16
tw_rec6:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #32
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #14]
    wdg_arm tw_rec7
    mov r7, #0
    mov r1, #0
    .word 0xE5AF1004               @ str r1, [r15, #4]!
    add r7, r7, #1
    add r7, r7, #2
    add r7, r7, #4
    add r7, r7, #8
    add r7, r7, #16
tw_rec7:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #64
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #15]
    wdg_arm tw_rec8
    mov r7, #0
    mov r1, #0
    .word 0xE8AF0002               @ stmia r15!, {r1}
    add r7, r7, #1
    add r7, r7, #2
    add r7, r7, #4
    add r7, r7, #8
    add r7, r7, #16
tw_rec8:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #128
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #16]
    strb r11, [r8, #3]
    pop {r4-r11, pc}
    .ltorg


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x0F,0x0C,0x08,0x00,0x02,0x70,0x87,0xE2
    .byte 0x00,0x00,0x00,0x00,0x18,0x10,0x1F,0x1C
    .byte 0x1F,0x00,0x00,0x00,0x00,0x00,0x00,0x00
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
