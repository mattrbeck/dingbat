@ pcwb.s — WHAT: LDR/STR/LDM base writeback with r15 as the base
@ register — does the writeback reach the program counter, and where
@ does execution land?
@
@ HOW: each candidate word executes with a four-instruction breadcrumb
@ sled of `add r7, r7, #imm` (1/2/4/8) directly behind it, under the
@ TM3 watchdog.  The candidate sits at C, so the ARM pipeline base
@ value r15 = C+8.  r7's sum keys the landing site: 15 = fell straight
@ through (no PC writeback), 12 = resumed at C+12 = base+4, 8 = resumed
@ at C+16 = base+8.  r1 is zeroed first so the load rows also show
@ whether the loaded value arrived.
@
@ WHY the expected values: three DIFFERENT behaviors on silicon —
@ `ldmia r15!, {r1}` performs NO base writeback at all (r7 = 0F) but
@ the load happens: r1 = the word at base = C+8, which is the sled's
@ own `add r7, r7, #2` = 0xE2877002.  `str r1, [r15], #4` writes
@ PC := base+4 and execution continues there (r7 = 0C).
@ `ldr r1, [r15], #4` writes PC := base+8 (r7 = 08) and SUPPRESSES the
@ load — r1 stays 0.  No watchdog fires (+3 = 0).
@
@ PROVENANCE: verified on GBA SP AGS-001 (session 3, gbaedge page 25
@ THUMBPC2, writeback rows); see docs/hwprobe-results-agb.md.
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
    strb r11, [r8, #3]
    pop {r4-r11, pc}
    .ltorg


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x0F,0x0C,0x08,0x00,0x02,0x70,0x87,0xE2
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
