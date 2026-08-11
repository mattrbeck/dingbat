@ psrmask.s — WHAT: which CPSR/SPSR bits are physically writable on the
@ ARM7TDMI (no test suite measures this; emulators typically latch all).
@
@ HOW: all-ones MSR writes per field, raw MRS readback after each:
@ msr CPSR_f/CPSR_s/CPSR_x with 0xFF in the respective byte, then (from
@ IRQ mode) msr SPSR_cxsf with all-ones, all-zeros and 0x0F, and finally
@ an MRS SPSR back in System mode, where no SPSR exists.
@
@ WHY the expected values: only the NZCV flags (bits 28-31) and the
@ control byte (bits 0-7) physically exist — writes to bits 8-27 never
@ latch, so the s and x field writes leave CPSR unchanged (F000001F
@ three times: NZCV latched from the f write, mode 1F System).  The SPSR
@ holds exactly the mask F00000FF; bit4 reads as one (write 0 reads
@ 0x10, write 0x0F reads 0x1F).  A System-mode SPSR read returns CPSR
@ (2000001F here — the flags are pinned to C-only just before the read
@ so the row is deterministic and matches the gbaedge transcription).
@
@ PROVENANCE: verified on GBA SP AGS-001 (session 2, gbaedge page 17
@ CPSRBITS, slot CRC F153); see docs/hwprobe-results-agb.md.
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
    .ascii "PSR WRITE MASK"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

probe:
    push {r4-r8, lr}
    ldr r8, =SLOT
    mrs r7, CPSR                   @ saved state to restore
    ldr r0, =0xFF000000
    msr CPSR_f, r0
    mrs r1, CPSR
    str r1, [r8, #0]
    ldr r0, =0x00FF0000
    msr CPSR_s, r0
    mrs r1, CPSR
    str r1, [r8, #4]
    ldr r0, =0x0000FF00
    msr CPSR_x, r0
    mrs r1, CPSR
    str r1, [r8, #8]
    msr CPSR_cxsf, r7              @ full restore, whatever latched above
    bic r0, r7, #0x1F              @ -> IRQ mode, IRQs masked
    orr r0, r0, #0x92
    msr CPSR_c, r0
    ldr r0, =0xFFFFFFFF
    msr SPSR_cxsf, r0
    mrs r1, SPSR
    str r1, [r8, #12]
    mov r0, #0
    msr SPSR_cxsf, r0
    mrs r1, SPSR
    str r1, [r8, #16]
    mov r0, #0x0F
    msr SPSR_cxsf, r0
    mrs r1, SPSR
    str r1, [r8, #20]
    msr CPSR_c, r7                 @ back to system mode
    msr CPSR_f, #0x20000000        @ pin flags: the sys-mode read below
                                   @ returns CPSR, keep it deterministic
    mrs r1, SPSR                   @ ARM7TDMI has no SPSR here
    str r1, [r8, #24]
    pop {r4-r8, pc}
    .ltorg


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x1F,0x00,0x00,0xF0,0x1F,0x00,0x00,0xF0
    .byte 0x1F,0x00,0x00,0xF0,0xFF,0x00,0x00,0xF0
    .byte 0x10,0x00,0x00,0x00,0x1F,0x00,0x00,0x00
    .byte 0x1F,0x00,0x00,0x20,0x00,0x00,0x00,0x00
classes:
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .align 2
ranges:
    .word 0xFFFFFFFF
    .include "runtime.inc"
