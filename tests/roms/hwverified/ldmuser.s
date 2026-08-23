@ ldmuser.s — WHAT: user-bank block transfers (`stm {..}^`) with a
@ BANKED base register — which bank supplies the base address, which
@ bank's value is stored, and which bank receives the writeback?  Plus:
@ does an SPSR read in the shadow of an `ldm^` come back OR'd with CPSR?
@
@ HOW: from IRQ mode with IRQs masked, user r13 is parked on the marker
@ 0xCAFE0001 (System mode shares the user bank, so it is set before the
@ mode switch and read back after).  Three stores probe the bank
@ plumbing: `stmia r4, {r13}^` (which value?), `stmia r4!, {r13}^`
@ (writeback with a non-banked base), and the headline
@ `stmia r13!, {r13}^` (banked base + user list + writeback).  Then
@ SPSR_irq is set to the distinct pattern 0x600000D2 and read back in
@ the very next instruction after `ldmia r4, {r1}^`.
@
@ WHY the expected values: the store uses the BANKED r13 as the base
@ address but stores the USER r13 value (CAFE0001 lands at EWDST+0x40),
@ and the writeback goes to the USER bank: user r13 becomes base+4,
@ i.e. EWDST+0x44, so its delta from the marker is
@ 0x02004044 - 0xCAFE0001 = 0x37024043, while the banked r13 is
@ unchanged (delta 0).  The post-ldm^ SPSR read returns 0x600000D2
@ unchanged.  (Caveat recorded in the hwprobe notes: CPSR's set bits at
@ that point happen to be a subset of the pattern, so this row cannot
@ by itself falsify the OR theory — it does pin the observable value.)
@
@ PROVENANCE: verified on GBA SP AGS-001 (gbaedge page 19 LDMUSER, slot
@ CRC 856D); see docs/hwprobe-results-agb.md.
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
    .ascii "LDM USER BANK"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

probe:
    push {r4-r11, lr}
    ldr r8, =SLOT
    ldr r4, =EWDST
    ldr r0, =0x12345678            @ ldm^ source value
    str r0, [r4, #0x20]
    mrs r7, CPSR
    mov r9, sp                     @ park the user/system sp on a marker
    ldr r0, =0xCAFE0001
    mov sp, r0
    bic r0, r7, #0x1F              @ -> IRQ mode, I set
    orr r0, r0, #0x92
    msr CPSR_c, r0
    ldr sp, =SCRATCH + 0xF0        @ sp_irq: valid but unused scratch
    @ 1: plain user-bank store
    .word 0xE8C42000               @ stmia r4, {r13}^
    ldr r0, [r4]
    str r0, [r8, #0]
    @ 2: writeback + user list, non-banked base
    .word 0xE8E42000               @ stmia r4!, {r13}^   (UNPREDICTABLE)
    ldr r1, =EWDST
    sub r0, r4, r1
    str r0, [r8, #4]
    ldr r4, =EWDST                 @ restore r4 whatever happened
    @ 3: banked base + user list + writeback
    ldr r0, =EWDST + 0x40
    mov sp, r0                     @ r13_irq = base
    .word 0xE8ED2000               @ stmia r13!, {r13}^
    ldr r1, =EWDST + 0x40
    ldr r0, [r1]                   @ what got stored
    str r0, [r8, #8]
    sub r0, sp, r1                 @ banked writeback delta
    str r0, [r8, #12]
    @ 4: SPSR in the shadow of an ldm^
    ldr r0, =0x600000D2            @ distinct-but-legal pattern (IRQ mode)
    msr SPSR_cxsf, r0
    add r4, r4, #0x20
    .word 0xE8D40002               @ ldmia r4, {r1}^ (user-bank load)
    mrs r2, SPSR                   @ the read theorized to come back OR'd
    str r2, [r8, #20]
    str r1, [r8, #24]
    sub r4, r4, #0x20
    msr CPSR_c, r7                 @ back to system mode
    ldr r0, =0xCAFE0001            @ user r13 delta from the marker
    sub r0, sp, r0
    str r0, [r8, #16]
    mov sp, r9                     @ real stack back
    pop {r4-r11, pc}
    .ltorg


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x01,0x00,0xFE,0xCA,0x04,0x00,0x00,0x00
    .byte 0x01,0x00,0xFE,0xCA,0x00,0x00,0x00,0x00
    .byte 0x43,0x40,0x02,0x37,0xD2,0x00,0x00,0x60
    .byte 0x78,0x56,0x34,0x12,0x00,0x00,0x00,0x00
classes:
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .align 2
ranges:
    .word 0xFFFFFFFF
    .include "runtime.inc"
