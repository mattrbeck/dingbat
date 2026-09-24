@ suite_cpu.inc -- ARM7TDMI behaviour as the GBA SP's CPU shows it: PSR
@ write masks, Thumb hi-register ops on pc, MSR setting the T bit, loose BX
@ decodes, r15 base writeback, user-bank LDM/STM and the LDM^ glitch.
@
@ Every experiment here comes from tests/roms/hwverified (whose .s files
@ carry the full discriminator reasoning) or from a link-rig payload; the
@ code is theirs, only the result plumbing is dbsuite's.

    suite "cpu"

@ ─────────────────────────────── PSR masks ────────────────────────────────
@ WHAT: which CPSR/SPSR bits are physically writable.  All-ones MSR per
@ field with raw MRS readback, SPSR all-ones/zeros/0x0F from IRQ mode, and
@ an MRS SPSR in System mode (which has no SPSR).
@ WHY: an emulator that latches bits 8-27 or reads back exactly what was
@ written fails; so does one that faults or returns 0 for a System-mode
@ SPSR read.
@ PROVENANCE: AGB SP AGS-001, gbaedge page 17 CPSRBITS (session 2,
@ 2026-08-11, photographed, slot CRC F153; tests/roms/expected/
@ agb-sp-2.txt); hwverified/psrmask.s.
run_psrmask:
    push {r4-r8, lr}
    ldr r8, =SLOT
    mrs r7, CPSR
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
    msr CPSR_cxsf, r7
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
    msr CPSR_c, r7                 @ back to System mode
    msr CPSR_f, #0x20000000        @ pin the flags for the next read
    mrs r1, SPSR                   @ System mode has no SPSR
    str r1, [r8, #24]
    msr CPSR_cxsf, r7
    pop {r4-r8, pc}
    .ltorg
    cword "psr-f-field-sets-nzcv",  run_psrmask, 0, 0xF000001F
    cword "psr-s-field-writes-nothing", RUN_SAME, 4, 0xF000001F
    cword "psr-x-field-writes-nothing", RUN_SAME, 8, 0xF000001F
    cword "spsr-holds-f00000ff",   RUN_SAME, 12, 0xF00000FF
    cword "spsr-bit4-reads-one",   RUN_SAME, 16, 0x00000010
    cword "spsr-0f-reads-1f",      RUN_SAME, 20, 0x0000001F
    cword "system-mode-spsr-is-cpsr", RUN_SAME, 24, 0x2000001F

@ ───────────────────────────── Thumb op pc ────────────────────────────────
@ WHAT: Thumb hi-register CMP/ADD/MOV with rd = pc, run in IRQ mode with
@ SPSR = 0x9000009F (a different mode) so a full restore shows.
@ WHY: hardware restores ALL of CPSR from SPSR on `cmp pc, r0` (mode
@ included); ADD/MOV to pc branch to the operand and leave CPSR alone.
@ Emulators that treat the CMP as a plain compare read 20000092.
@ PROVENANCE: AGB SP, gbaedge pages 18 THUMBPC and 25 THUMBPC2 (sessions
@ 2-3, photographed); hwverified/thumbcmp.s.
run_thumbcmp:
    push {r4-r11, lr}
    ldr r8, =SLOT
    mrs r9, CPSR
    bic r0, r9, #0x1F
    orr r0, r0, #0x92
    msr CPSR_c, r0
    mov r10, sp
    ldr r0, =SCRATCH + 0xF0
    mov sp, r0
    ldr r1, =0x9000009F
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
    msr CPSR_c, #0x92              @ back to IRQ mode to restore its sp
    mov sp, r10
    msr CPSR_c, r9
    msr CPSR_f, r9
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
    .hword 0x3701
    .hword 0x3702
    .hword 0x3704
    .hword 0x4718                  @ bx r3 (branch target)
    .align 2
    .arm
23: mrs r1, CPSR
    str r1, [r8, #8]
    strb r7, [r8, #16]
    msr CPSR_c, r9
    bic r0, r9, #0x1F
    orr r0, r0, #0x92
    msr CPSR_c, r0
    ldr r1, =0x9000009F
    msr SPSR_cxsf, r1
    msr CPSR_f, #0
    adr r3, 25f
    adr r1, 24f
    add r0, r1, #7
    bic r0, r0, #1
    orr r1, r1, #1
    mov r7, #0
    bx  r1
    .thumb
24: .hword 0x4687                  @ mov pc, r0
    .hword 0x3701
    .hword 0x3702
    .hword 0x3704
    .hword 0x4718
    .align 2
    .arm
25: mrs r1, CPSR
    str r1, [r8, #12]
    strb r7, [r8, #17]
    msr CPSR_c, r9
    msr CPSR_f, r9
    pop {r4-r11, pc}
    .ltorg
    cword "thumb-cmp-pc-restores-cpsr", run_thumbcmp, 0, 0x9000009F
    cword "thumb-cmp-pc-lands-in-system", RUN_SAME, 4, 0x9000009F
    cword "thumb-add-pc-keeps-cpsr", RUN_SAME, 8, 0x00000092
    cword "thumb-mov-pc-keeps-cpsr", RUN_SAME, 12, 0x00000092
    cbyte "thumb-add-pc-branches",  RUN_SAME, 16, 0x00
    cbyte "thumb-mov-pc-branches",  RUN_SAME, 17, 0x04

@ ────────────────────────── MSR sets the T bit ────────────────────────────
@ WHAT: where execution resumes after an ARM `msr CPSR_c` sets the Thumb
@ bit (UNPREDICTABLE per the ARM ARM).  Thumb breadcrumbs at A+4..A+10
@ (adds of 1/2/4/8) say which halfwords ran.
@ WHY: silicon executes the LOW halfword of the word at A+8 next, skips
@ A+10 and continues from A+12: r7 = 4.  This crashes emulators that
@ refetch from A+4 or keep decoding ARM.
@ PROVENANCE: AGB SP, gbaedge page 8 MSRTBIT (session 1, 2026-08-10) and
@ page 24 MSRTBIT2 (session 4); hwverified/msrtbit.s.
run_msrtbit:
    push {r4-r11, lr}
    ldr r2, =MARKER
    str sp, [r2, #12]
    ldr r0, =msr_block
    ldr r1, =IWBLOCK
    ldmia r0!, {r3-r8}
    stmia r1!, {r3-r8}
    ldr r8, =SLOT
    mov r0, #0
    str r0, [r2, #0]
    str r0, [r2, #16]
    wdg_arm msr_recover
    ldr r6, =MARKER
    ldr r5, =msr_recover
    mov r7, #0
    mrs r4, CPSR
    orr r0, r4, #0x20
    cmp r7, #0                     @ pin flags: Z=1 C=1
    ldr r1, =IWBLOCK
    bx  r1
msr_recover:
    ldr r2, =MARKER
    ldr sp, [r2, #12]
    wdg_disarm
    ldr r2, =MARKER
    ldr r8, =SLOT
    ldr r3, [r2, #16]
    cmp r3, #1
    beq msr_after_control
    strb r7, [r8, #0]
    ldr r3, [r2, #8]
    strb r3, [r8, #1]
    mrs r3, CPSR
    strb r3, [r8, #3]
    ldr r3, [r2, #0]
    str r3, [r8, #4]
    mov r0, #1
    str r0, [r2, #16]
    wdg_arm msr_recover
    mov r7, #0
    ldr r6, =MARKER
    ldr r5, =msr_recover
    ldr r1, =IWBLOCK + 4 + 1
    bx  r1
msr_after_control:
    wdg_disarm
    strb r7, [r8, #2]
    ldr r2, =MARKER
    mov r0, #0
    str r0, [r2, #8]
    pop {r4-r11, pc}
    .ltorg
msr_block:
    .word 0xE121F000               @ A+0: msr CPSR_c, r0
    .hword 0x3701                  @ A+4:  adds r7, #1   (thumb)
    .hword 0x3702                  @ A+6:  adds r7, #2
    .hword 0x3704                  @ A+8:  adds r7, #4
    .hword 0x3708                  @ A+10: adds r7, #8
    .hword 0x6037                  @ A+12: str r7, [r6]
    .hword 0x4728                  @ A+14: bx r5
    .word 0xE12FFF15               @ A+16: bx r5 (ARM safety net)
    .word 0xE12FFF15
    .ltorg
    cbyte "msr-t-runs-a8-low-half", run_msrtbit, 0, 0x04
    cbyte "msr-t-no-watchdog",      RUN_SAME, 1, 0x01
    cbyte "msr-t-control-block",    RUN_SAME, 2, 0x0F
    cbyte "msr-t-resumes-arm-system", RUN_SAME, 3, 0x1F
    cword "msr-t-marker-stored",    RUN_SAME, 4, 0x00000004

@ ────────────────────────────── BX decode ─────────────────────────────────
@ WHAT: which near-BX encodings execute as BX on the ARM7TDMI.  r7 = 1:
@ took the BX to a Thumb pad; 6: fell through; 4: branched to $+8.
@ WHY: the ARMv5 BLX-register word 0xE12FFF31 executes as BX on silicon
@ (loose decode); BX r15 branches to $+8.  The SBO-violated 0xE120FF11 is
@ deliberately NOT run: it wedges a real console with IRQs masked.
@ PROVENANCE: AGB SP, gbaedge page 24 BXDECODE (session 3, one candidate
@ per press); hwverified/bxdecode.s.
run_bxdecode:
    push {r4-r11, lr}
    ldr r8, =SLOT
    mov r10, #0
bx_next:
    cmp r10, #3
    bge bx_done
    ldr r0, =bx_candidates
    ldr r9, [r0, r10, lsl #2]
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
    str r0, [r2, #24]
    wdg_arm bx_recover
    ldr r5, =bx_recover
    ldr r1, =IWBLOCK
    add r0, r1, #16
    orr r1, r0, #1
    mov r7, #0
    ldr r0, =IWBLOCK
    bx  r0
bx_recover:
    ldr r2, =MARKER
    ldr r3, [r2, #24]
    msr CPSR_cxsf, r3
    ldr sp, [r2, #12]
    wdg_disarm
    ldr r2, =MARKER
    strb r7, [r8, r10]
    ldr r3, [r2, #8]
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
    cbyte "bx-r1-control",          run_bxdecode, 0, 0x01
    cbyte "blx-reg-word-runs-as-bx", RUN_SAME, 1, 0x01
    cbyte "bx-r15-branches-plus-8", RUN_SAME, 2, 0x04
    cbyte "bx-r1-control-clean",    RUN_SAME, 4, 0x01
    cbyte "blx-reg-word-clean",     RUN_SAME, 5, 0x01
    cbyte "bx-r15-clean",           RUN_SAME, 6, 0x01

@ ─────────────────────────── r15 base writeback ───────────────────────────
@ WHAT: LDR/STR/STM/LDM with r15 as the base and writeback: does the
@ writeback reach the PC, and where does execution land?  A sled of adds
@ (distinct powers of two) keys the landing site.
@ WHY: hardware: PC := the writeback address (+4 more for ldr, whose load
@ is suppressed) for the single-transfer forms; NO writeback at all for
@ the block forms.  Emulators commonly land on base+8 and perform the
@ load.
@ PROVENANCE: AGB SP, gbaedge page 25 THUMBPC2 and page 29 PCWB2 (sessions
@ 3-4); hwverified/pcwb.s.  dbsuite change: the store rows store the word
@ already at the store address (r1 = that opcode) instead of 0, so the
@ multiboot build, whose code is in RAM, does not rewrite its own sled;
@ nothing measured depends on the stored value.
.macro pw_row wordv, sled5, recl, slotb, r1val=0
    wdg_arm \recl
    mov r7, #0
    ldr r1, =\r1val
    .word \wordv
    add r7, r7, #1
    add r7, r7, #2
    add r7, r7, #4
    add r7, r7, #8
.if \sled5
    add r7, r7, #16
.endif
\recl:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #(1 << (\slotb & 7))
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #\slotb]
.endm
run_pcwb:
    push {r4-r11, lr}
    ldr r8, =SLOT
    mov r11, #0
    pw_row 0xE8BF0002, 0, pw_rec1, 0         @ ldmia r15!, {r1}
    str r1, [r8, #4]
    pw_row 0xE48F1004, 0, pw_rec2, 1, 0xE2877002  @ str r1, [r15], #4
    pw_row 0xE49F1004, 0, pw_rec3, 2         @ ldr r1, [r15], #4
    str r1, [r8, #8]
    pw_row 0xE48F1008, 1, pw_rec4, 12, 0xE2877002 @ str r1, [r15], #8
    pw_row 0xE49F1008, 1, pw_rec5, 13        @ ldr r1, [r15], #8
    str r1, [r8, #20]
    pw_row 0xE40F1004, 1, pw_rec6, 14, 0xE2877002 @ str r1, [r15], #-4
    pw_row 0xE5AF1004, 1, pw_rec7, 15, 0xE2877004 @ str r1, [r15, #4]!
    pw_row 0xE8AF0002, 1, pw_rec8, 16, 0xE2877002 @ stmia r15!, {r1}
    strb r11, [r8, #3]
    pop {r4-r11, pc}
    .ltorg
    cbyte "ldm-r15-wb-no-writeback", run_pcwb, 0, 0x0F
    cword "ldm-r15-wb-loads",       RUN_SAME, 4, 0xE2877002
    cbyte "str-r15-post4-pc-base4", RUN_SAME, 1, 0x0C
    cbyte "ldr-r15-post4-pc-base8", RUN_SAME, 2, 0x08
    cword "ldr-r15-post4-no-load",  RUN_SAME, 8, 0x00000000
    cbyte "str-r15-post8-pc-base8", RUN_SAME, 12, 0x18
    cbyte "ldr-r15-post8-pc-base12", RUN_SAME, 13, 0x10
    cword "ldr-r15-post8-no-load",  RUN_SAME, 20, 0x00000000
    cbyte "str-r15-post-4-pc-base-4", RUN_SAME, 14, 0x1F
    cbyte "str-r15-pre4-wb-pc",     RUN_SAME, 15, 0x1C
    cbyte "stm-r15-wb-no-writeback", RUN_SAME, 16, 0x1F
    cbyte "r15-wb-no-watchdog",     RUN_SAME, 3, 0x00

@ ───────────────────────── user-bank STM^/LDM^ ────────────────────────────
@ WHAT: `stm {r13}^` from IRQ mode: which bank supplies the base, which
@ value is stored, where the writeback goes; and an SPSR read right after
@ an `ldm^`.
@ WHY: the store uses the BANKED r13 as the address and stores the USER
@ r13; the writeback goes to the USER bank (user r13 = base+4, banked
@ unchanged).  Emulators store 0 or add 4 to the old user value.
@ PROVENANCE: AGB SP, gbaedge pages 19 LDMUSER and 28 LDMUSER2 (sessions
@ 2 and 4, CRCs 856D / B520); hwverified/ldmuser.s.
run_ldmuser:
    push {r4-r11, lr}
    ldr r8, =SLOT
    ldr r4, =EWDST
    ldr r0, =0x12345678
    str r0, [r4, #0x20]
    mrs r7, CPSR
    mov r9, sp
    ldr r0, =0xCAFE0001
    mov sp, r0
    bic r0, r7, #0x1F
    orr r0, r0, #0x92
    msr CPSR_c, r0
    mov r10, sp                    @ keep the IRQ stack for the way out
    ldr sp, =SCRATCH + 0xF0
    .word 0xE8C42000               @ stmia r4, {r13}^
    ldr r0, [r4]
    str r0, [r8, #0]
    .word 0xE8E42000               @ stmia r4!, {r13}^   (UNPREDICTABLE)
    ldr r1, =EWDST
    sub r0, r4, r1
    str r0, [r8, #4]
    ldr r4, =EWDST
    ldr r0, =EWDST + 0x40
    mov sp, r0
    .word 0xE8ED2000               @ stmia r13!, {r13}^
    ldr r1, =EWDST + 0x40
    ldr r0, [r1]
    str r0, [r8, #8]
    sub r0, sp, r1
    str r0, [r8, #12]
    ldr r0, =0x600000D2
    msr SPSR_cxsf, r0
    add r4, r4, #0x20
    .word 0xE8D40002               @ ldmia r4, {r1}^
    mrs r2, SPSR
    str r2, [r8, #20]
    str r1, [r8, #24]
    sub r4, r4, #0x20
    mov sp, r10
    msr CPSR_c, r7
    ldr r0, =0xCAFE0001
    sub r0, sp, r0
    str r0, [r8, #16]
    mov sp, r9
    pop {r4-r11, pc}
    .ltorg
    cword "stm-user-stores-user-r13", run_ldmuser, 0, 0xCAFE0001
    cword "stm-user-wb-nonbanked-base", RUN_SAME, 4, 0x00000004
    cword "stm-user-banked-base-stores-user", RUN_SAME, 8, 0xCAFE0001
    cword "stm-user-banked-base-unchanged", RUN_SAME, 12, 0x00000000
    cword "stm-user-wb-to-user-bank", RUN_SAME, 16, 0x37024043
    cword "spsr-after-ldm-user-unchanged", RUN_SAME, 20, 0x600000D2
    cword "ldm-user-loads",         RUN_SAME, 24, 0x12345678

@ ────────────────────────────── LDM^ glitch ───────────────────────────────
@ WHAT/WHY/PROVENANCE: see payloads/ldmglitch*.s -- the instruction after
@ a user-bank LDM (from a mode with banked registers) reads banked OR user
@ in its first cycle.  AGB SP via the link rig, 2026-09-24.
    payload_blob pl_ldmg1, "ldmglitch1.bin"
    payload_blob pl_ldmg2, "ldmglitch2.bin"
    payload_blob pl_ldmg3, "ldmglitch3.bin"
    payload_blob pl_ldmg4, "ldmglitch4.bin"
    cpay "ldm-user-glitch-add-ors",      pl_ldmg1, 0, 0x0000FD02
    cpay "ldm-user-glitch-gone-after-nop", pl_ldmg1, 1, 0x00009669
    cpay "ldm-user-glitch-mul-ors",      pl_ldmg1, 2, 0x2A6BA8C1
    cpay "ldm-user-glitch-gone-2-nops",  pl_ldmg1, 4, 0x00009669
    cpay "ldm-user-glitch-from-iwram",   pl_ldmg2, 0, 0x0000FD02
    cpay "ldm-user-glitch-from-ewram",   pl_ldmg2, 1, 0x0000FD02
    cpay "ldm-user-glitch-unloaded-regs", pl_ldmg3, 0, 0x0000FD02
    cpay "stm-user-no-glitch",           pl_ldmg3, 1, 0x00009669
    cpay "plain-ldm-no-glitch",          pl_ldmg3, 2, 0x00001100
    cpay "ldm-user-glitch-store-data-clean", pl_ldmg3, 3, 0x00001248
    cpay "ldm-user-glitch-reference",    pl_ldmg3, 4, 0x0000FD02
    cpay "ldm-user-glitch-shift-rs-only", pl_ldmg4, 0, 0x00000081
    cpay "ldm-user-glitch-umull-rm-rs",  pl_ldmg4, 1, 0x0000005B
    cpay "ldm-user-glitch-msr-rm",       pl_ldmg4, 2, 0xC0000000
    cpay "ldm-user-glitch-mla-rs-clean", pl_ldmg4, 3, 0x0000000F
    cpay "ldm-user-glitch-shift-control", pl_ldmg4, 5, 0x00000021
    cpay "ldm-user-glitch-irq-r13-r14",  pl_ldmg4, 4, 0x0000FD02

    .include "cpu_more.inc"
