@ cpu_more.inc -- the rest of the cpu suite (included by suite_cpu.inc):
@ block-transfer corners, the multiply carry flag, undefined CPSR modes,
@ Thumb multiply timing.

@ ──────────────────────────── block transfers ─────────────────────────────
@ WHAT: STM/LDM corners: base first vs not first in an STM list with
@ writeback, a loaded base beating writeback, the empty register list (STM
@ stores PC+12 and adds 0x40; LDM loads PC from [base] and adds 0x40), and
@ a misaligned LDR's rotation.
@ WHY: the ARM7TDMI stores the OLD base when it is first in the list and
@ the written-back one otherwise; the empty-list forms move r15 and 16
@ words' worth of base.  Emulators that treat an empty list as a no-op
@ fall through with the base unchanged.
@ PROVENANCE: AGB SP, gbaedge page 6 LDMSTM (session 1, 2026-08-10, CRC
@ 6899; tests/roms/expected/agb-sp-1.txt).  The empty-list STM stored
@ 0x08000930 there = that STM's own address + 12: dbsuite checks the same
@ rule against its own STM's address.
run_ldmstm:
    push {r4-r8, lr}
    ldr r8, =SLOT
    ldr r4, =EWDST
    ldr r1, =0x11111111
    mov r0, r4
    stmia r0!, {r0, r1}
    ldr r2, [r4]
    str r2, [r8, #0]
    mov r0, #0x22
    mov r1, r4
    stmia r1!, {r0, r1}
    ldr r2, [r4, #4]
    str r2, [r8, #4]
    ldr r0, =0xCAFEBABE
    str r0, [r4]
    mov r0, r4
    ldmia r0!, {r0}
    str r0, [r8, #8]
    mov r0, r4
ls_empty_stm:
    .word 0xE8A00000               @ stmia r0!, {} -- empty rlist
    ldr r1, [r4]
    str r1, [r8, #12]
    sub r1, r0, r4
    str r1, [r8, #16]
    ldr r1, =ls_empty_stm + 12     @ the rule: this STM's address + 12
    str r1, [r8, #32]
    ldr r0, =EWDST + 0x80
    ldr r1, =ls_empty_cont
    str r1, [r0]
    mov r7, #0
    .word 0xE8B00000               @ ldmia r0!, {} -- empty rlist
    mov r7, #2                     @ fell through
    b   ls_empty_join
ls_empty_cont:
    mov r7, #1                     @ PC was loaded from [base]
ls_empty_join:
    str r7, [r8, #20]
    ldr r1, =EWDST + 0x80
    sub r1, r0, r1
    str r1, [r8, #24]
    ldr r4, =ls_pattern
    add r3, r4, #1
    ldr r0, [r3]
    str r0, [r8, #28]
    pop {r4-r8, pc}
    .ltorg
ls_pattern:
    .word 0x11223344
    cword "stm-base-first-stores-old", run_ldmstm, 0, EWDST
    cword "stm-base-second-stores-new", RUN_SAME, 4, EWDST + 8
    cword "ldm-wb-loaded-base-wins", RUN_SAME, 8, 0xCAFEBABE
    case  "stm-empty-list-stores-pc12", RUN_SAME, 0, 0, 12, 0xFFFFFFFF, 32, 0, K_SLOT
    cword "stm-empty-list-base-plus-40", RUN_SAME, 16, 0x40
    cword "ldm-empty-list-loads-pc", RUN_SAME, 20, 1
    cword "ldm-empty-list-base-plus-40", RUN_SAME, 24, 0x40
    cword "ldr-misaligned-rotates", RUN_SAME, 28, 0x44112233

@ ────────────────────────── multiply carry flag ───────────────────────────
@ WHAT: the C flag after flag-setting multiplies (MULS, MLAS, UMULLS,
@ SMULLS, UMLALS, SMLALS) over sixteen operand pairs, with C preset to 1
@ and to 0: one bit per pair (pair 0 = bit 0).  Pairs 0-7 are the MULFLAGS
@ page's table; 8-15 hold Rm = 12345678 and sweep Rs through every early-
@ termination class.  Then the whole NZCV nibble of MULS for MULFLAGS'
@ eight pairs, and sixteen back-to-back MULS timed per Rs class.
@ WHY: the carry is neither preserved nor random: it comes out of the
@ multiplier's last step, the same for either preset (set for pairs 3, 4,
@ 11 and 13 on MULS/MLAS/SMULLS/SMLALS; pairs 1, 4, 11 and 13 on UMULLS/
@ UMLALS).
@ Emulators that leave C alone read 0000 for the C=0 rows and FFFF for
@ C=1.  The timing rows say early termination looks at leading zeros AND
@ leading ones (one m-cycle a byte class, 16 cycles over 16 MULS).
@ PROVENANCE: AGB SP, gbaedge page 7 MULFLAGS (session 1, CRC 64F4) and
@ page 42 MULTIME (session 5, 2026-09-04, CRC 149C; agb-sp-5.txt).  The
@ timed rows run from the cartridge: cartridge only.
.macro mt_vec preset, off, op:vararg
    mov r6, #0
    mov r9, #0
    ldr r7, =mul16_ops
1:  add r0, r7, r6, lsl #3
    ldr r1, [r0]
    ldr r2, [r0, #4]
    mov r3, #0
    mov r4, #0
    mov r0, #0
.if \preset
    subs r10, r6, #0               @ C := 1
.else
    adds r10, r6, #0               @ C := 0
.endif
    \op
    mrs r10, CPSR
    mov r11, #0
    tst r10, #0x20000000
    movne r11, #1
    orr r9, r9, r11, lsl r6
    add r6, r6, #1
    cmp r6, #16
    blt 1b
    strh r9, [r8, #\off]
.endm
run_multime:
    push {r4-r11, lr}
    ldr r8, =SLOT
    mt_vec 1, 0,  muls r0, r1, r2
    mt_vec 0, 2,  muls r0, r1, r2
    mt_vec 1, 4,  mlas r0, r1, r2, r3
    mt_vec 0, 6,  mlas r0, r1, r2, r3
    mt_vec 1, 8,  umulls r0, r4, r1, r2
    mt_vec 1, 10, smulls r0, r4, r1, r2
    mt_vec 1, 12, umlals r0, r4, r1, r2
    mt_vec 1, 14, smlals r0, r4, r1, r2
    mov r6, #0
    ldr r7, =mt_sweep
2:  ldr r5, =0x12345678
    ldr r4, [r7, r6, lsl #2]
    bl  tm_start
    mov r1, r5
    mov r2, r4
    .rept 16
    muls r0, r1, r2
    .endr
    bl  tm_stop
    add r3, r8, #16
    add r3, r3, r6, lsl #1
    strh r0, [r3]
    add r6, r6, #1
    cmp r6, #8
    blt 2b
    @ MULFLAGS: the NZCV nibble per pair, C preset 1 (+32..+39).  (The
    @ page's C-preset-0 half indexed past its 8-pair table into the ROM's
    @ own code, so it is not reproduced; MULTIME's +2/+6 cover C = 0.)
    mov r6, #0
    ldr r7, =mul16_ops
3:  add r0, r7, r6, lsl #3
    ldr r1, [r0]
    ldr r2, [r0, #4]
    subs r0, r6, #0                @ C := 1
    muls r0, r1, r2
    mrs r3, CPSR
    mov r3, r3, lsr #28
    add r0, r8, #32
    strb r3, [r0, r6]
    add r6, r6, #1
    cmp r6, #8
    blt 3b
    pop {r4-r11, pc}
    .ltorg
mul16_ops:
    .word 0x00000000, 0x00000000
    .word 0xFFFFFFFF, 0xFFFFFFFF
    .word 0x000000FF, 0xFF00FF00
    .word 0x12345678, 0x9ABCDEF0
    .word 0x0000FFFF, 0x0000FFFF
    .word 0x80000000, 0x00000002
    .word 0xFFFFFF00, 0x00000100
    .word 0x00000001, 0xFFFFFFFF
    .word 0x12345678, 0x00000001
    .word 0x12345678, 0x000000FF
    .word 0x12345678, 0x00000100
    .word 0x12345678, 0x0000FFFF
    .word 0x12345678, 0x00010000
    .word 0x12345678, 0x00FFFFFF
    .word 0x12345678, 0x01000000
    .word 0x12345678, 0xFFFFFFFF
mt_sweep:
    .word 0x00000012, 0x00001234, 0x00123456, 0x12345678
    .word 0xFFFFFFEE, 0xFFFFEDCC, 0xFFEDCBAA, 0xEDCBA988

@ tm_start/tm_stop: gbaedge's stopwatch (TM0 /1 with TM1 cascading), kept
@ instruction for instruction so the timed rows read what the console did.
tm_start:
    ldr r3, =0x04000100
    mov r2, #0
    str r2, [r3]
    str r2, [r3, #4]
    ldr r1, =0x00840000
    str r1, [r3, #4]
    ldr r2, =0x00800000
    str r2, [r3]
    bx  lr
tm_stop:
    ldr r3, =0x04000100
    ldrh r0, [r3]
    ldrh r1, [r3, #4]
    mov r2, #0
    str r2, [r3]
    str r2, [r3, #4]
    orr r0, r0, r1, lsl #16
    bx  lr
    .ltorg
    chalf "muls-carry-c1",          run_multime, 0, 0x2818
    chalf "muls-carry-c0",          RUN_SAME, 2, 0x2818
    chalf "mlas-carry-c1",          RUN_SAME, 4, 0x2818
    chalf "mlas-carry-c0",          RUN_SAME, 6, 0x2818
    chalf "umulls-carry",           RUN_SAME, 8, 0x2812
    chalf "smulls-carry",           RUN_SAME, 10, 0x2818
    chalf "umlals-carry",           RUN_SAME, 12, 0x2812
    chalf "smlals-carry",           RUN_SAME, 14, 0x2818
    cword "muls-nzcv-c1-pairs-0-3", RUN_SAME, 32, 0x02000004
    cword "muls-nzcv-c1-pairs-4-7", RUN_SAME, 36, 0x0808040A
    chalf "muls-16x-rs-1-byte",     RUN_SAME, 16, 0x00DC, F_CART
    chalf "muls-16x-rs-2-bytes",    RUN_SAME, 18, 0x00EC, F_CART
    chalf "muls-16x-rs-3-bytes",    RUN_SAME, 20, 0x00FC, F_CART
    chalf "muls-16x-rs-4-bytes",    RUN_SAME, 22, 0x010C, F_CART
    chalf "muls-16x-rs-neg-1-byte", RUN_SAME, 24, 0x00DC, F_CART
    chalf "muls-16x-rs-neg-2-bytes", RUN_SAME, 26, 0x00EC, F_CART
    chalf "muls-16x-rs-neg-3-bytes", RUN_SAME, 28, 0x00FC, F_CART
    chalf "muls-16x-rs-neg-4-bytes", RUN_SAME, 30, 0x010C, F_CART

@ ────────────────── long-multiply flags, misaligned halves ───────────────
@ WHAT: the NZCV nibble after UMULLS/SMULLS (FFFFFFFF x FFFFFFFF, then
@ 0000FFFF x 00010001, C preset 1), and LDRH / LDRSH from an odd address.
@ WHY: a misaligned LDRH rotates the aligned halfword (0x3344 -> 0x0033 in
@ the low half); a misaligned LDRSH loads the signed BYTE.
@ PROVENANCE: AGB SP, gbaedge page 7 MULFLAGS (session 1, CRC 64F4:
@ +16..+23 = 0A 00 00 00 33 00 33 00).
run_mulflags2:
    push {r4-r8, lr}
    ldr r8, =SLOT
    ldr r1, =0xFFFFFFFF
    ldr r2, =0xFFFFFFFF
    subs r0, r0, r0
    umulls r0, r4, r1, r2
    mrs r3, CPSR
    mov r3, r3, lsr #28
    strb r3, [r8, #0]
    smulls r0, r4, r1, r2
    mrs r3, CPSR
    mov r3, r3, lsr #28
    strb r3, [r8, #1]
    ldr r1, =0x0000FFFF
    ldr r2, =0x00010001
    umulls r0, r4, r1, r2
    mrs r3, CPSR
    mov r3, r3, lsr #28
    strb r3, [r8, #2]
    smulls r0, r4, r1, r2
    mrs r3, CPSR
    mov r3, r3, lsr #28
    strb r3, [r8, #3]
    ldr r4, =ls_pattern
    add r3, r4, #1
    ldrh r0, [r3]
    strh r0, [r8, #4]
    ldrsh r0, [r3]
    strh r0, [r8, #6]
    pop {r4-r8, pc}
    .ltorg
    cword "long-mul-nzcv",          run_mulflags2, 0, 0x0000000A
    chalf "ldrh-misaligned-rotates", RUN_SAME, 4, 0x0033
    chalf "ldrsh-misaligned-is-ldrsb", RUN_SAME, 6, 0x0033

@ ──────────────────────── undefined CPSR modes ────────────────────────────
@ WHAT: CPSR_c written with the undefined mode numbers 0x15, 0x1A, 0x1E
@ (interrupts open, a TM3 watchdog armed); r13/r14 read straight back,
@ with every real bank first loaded with a constant naming it.
@ WHY: silicon reads 0 for r13 and r14 there -- not the user bank, not any
@ real bank -- and keeps the mode number as written.  Prince of Tennis
@ 2004 returns into mode 0x1E; an emulator that maps undefined modes onto
@ the user bank leaks the user r13/r14 (51515151).
@ PROVENANCE: AGB SP, gbaedge page 49 UNDMODE (session 5, 2026-09-04, CRC
@ EFA2; agb-sp-5.txt); the console survived it.
.macro un_probe mode, off, step
    mov r0, #\step
    strb r0, [r8, #28]
    msr CPSR_c, #\mode
    mov r6, sp
    mov r7, lr
    mrs r3, CPSR
    msr CPSR_c, #0xDF
    str r6, [r8, #\off]
    strb r3, [r8, #(\off + 4)]
    strb r7, [r8, #(\off + 5)]
.endm
run_undmode:
    push {r4-r11, lr}
    ldr r8, =SLOT
    mrs r4, CPSR
    mov r5, sp
    ldr r9, =MARKER
    str r5, [r9, #12]
    wdg_arm und_recover
    ldr r0, =0x52525252            @ name every bank before reading any
    msr CPSR_c, #0xD1
    mov sp, r0
    msr CPSR_c, #0xDF
    ldr r0, =0x53535353
    msr CPSR_c, #0xD7
    mov sp, r0
    msr CPSR_c, #0xDF
    ldr r0, =0x54545454
    msr CPSR_c, #0xDB
    mov sp, r0
    msr CPSR_c, #0xDF
    ldr r0, =0x51515151
    mov sp, r0
    un_probe 0x15, 0, 1
    un_probe 0x1A, 8, 2
    un_probe 0x1E, 16, 3
    mov r0, #4
    strb r0, [r8, #28]
    mov r6, sp
    str r6, [r8, #24]
und_recover:
    msr CPSR_c, #0xDF
    ldr r9, =MARKER
    ldr sp, [r9, #12]
    ldr r0, [r9, #8]
    strb r0, [r8, #29]
    wdg_disarm
    msr CPSR_c, r4
    mov r0, #0xAA
    strb r0, [r8, #30]
    pop {r4-r11, pc}
    .ltorg
    cword "mode-15-r13-reads-0",    run_undmode, 0, 0, F_RISKY
    cbyte "mode-15-latches",        RUN_SAME, 4, 0x15, F_RISKY
    cbyte "mode-15-r14-reads-0",    RUN_SAME, 5, 0x00, F_RISKY
    cword "mode-1a-r13-reads-0",    RUN_SAME, 8, 0, F_RISKY
    cbyte "mode-1a-latches",        RUN_SAME, 12, 0x1A, F_RISKY
    cbyte "mode-1a-r14-reads-0",    RUN_SAME, 13, 0x00, F_RISKY
    cword "mode-1e-r13-reads-0",    RUN_SAME, 16, 0, F_RISKY
    cbyte "mode-1e-latches",        RUN_SAME, 20, 0x1E, F_RISKY
    cbyte "mode-1e-r14-reads-0",    RUN_SAME, 21, 0x00, F_RISKY
    cword "system-r13-survives",    RUN_SAME, 24, 0x51515151, F_RISKY
    cbyte "undefined-modes-finish", RUN_SAME, 28, 0x04, F_RISKY
    cbyte "undefined-modes-clean",  RUN_SAME, 29, 0x01, F_RISKY

@ ─────────── writes in an undefined mode, and the loose MRS slot ──────────
@ WHAT: (a) CPSR_c = 0xCC (mode 0x0C, IRQ and FIQ masked): `mov r13, #0xFF`,
@ `mov r14, #0x77` and `mov r12, #0x55`, each read straight back, then the
@ caller's r13 once its mode is back.  (b) The immediate form of the MRS
@ slot -- TST/CMP immediate with S and bit 21 clear -- as 0xE30F0000,
@ 0xE3010000, 0xE3001000, 0xE3001002 and 0xE34031F2 over known registers.
@ WHY: an undefined mode has no r13/r14 at all: a write is lost and a read
@ gives 0, while r8-r12 stay the user bank's and the caller's bank is left
@ alone.  The loose MRS slot is a register move, Rd = Rn, the immediate and
@ the PSR bit ignored (png183 psr/psr2 tests 13-20).  An emulator that
@ banks undefined modes like User keeps 0xFF; one that decodes the slot as
@ MRS returns the CPSR.
@ PROVENANCE: AGB SP through tools/hwlink, 2026-09-24: this sequence from
@ IWRAM read 0, 0, 0x55 and the caller's sp; then r0 = the move's pc,
@ 42, 42, 0xFE and r0-r3 = FE, 1, 2A, FE.
run_undwrite:
    push {r4-r11, lr}
    ldr r8, =SLOT
    mrs r4, CPSR
    mov r10, sp
    msr CPSR_c, #0xCC
    mov r13, #0xFF
    mov r5, r13
    mov r14, #0x77
    mov r6, r14
    mov r12, #0x55
    mov r7, r12
    msr CPSR_c, r4
    mov r9, sp                     @ the caller's r13, not yet reloaded
    mov sp, r10
    str r5, [r8, #0]
    str r6, [r8, #4]
    str r7, [r8, #8]
    sub r9, r9, r10
    str r9, [r8, #12]
    mov r0, #0
    mov r1, pc
    .word 0xE30F0000               @ r0 = r15 (this address + 8 = r1 + 4)
    sub r0, r0, r1
    str r0, [r8, #16]
    mov r0, #0
    mov r1, #42
    .word 0xE3010000               @ r0 = r1
    str r0, [r8, #20]
    mov r0, #42
    mov r1, #0
    .word 0xE3001000               @ r1 = r0
    str r1, [r8, #24]
    mov r0, #0xFE
    mov r1, #0
    mov r2, #42
    .word 0xE3001002               @ r1 = r0 (bits 0-3 unused)
    str r1, [r8, #28]
    mov r0, #0xFE
    mov r1, #1
    mov r2, #42
    mov r3, #0
    .word 0xE34031F2               @ CMP slot, PSR bit set: r3 = r0
    orr r3, r3, r2, lsl #8
    orr r3, r3, r1, lsl #16
    orr r3, r3, r0, lsl #24
    str r3, [r8, #32]
    pop {r4-r11, pc}
    .ltorg
    cword "mode-0c-r13-write-lost",  run_undwrite, 0, 0, F_RISKY
    cword "mode-0c-r14-write-lost",  RUN_SAME, 4, 0, F_RISKY
    cword "mode-0c-r12-writable",    RUN_SAME, 8, 0x55, F_RISKY
    cword "mode-0c-caller-r13-kept", RUN_SAME, 12, 0, F_RISKY
    cword "mrs-slot-imm-pc",         RUN_SAME, 16, 4, F_RISKY
    cword "mrs-slot-imm-rn",         RUN_SAME, 20, 42, F_RISKY
    cword "mrs-slot-imm-rd",         RUN_SAME, 24, 42, F_RISKY
    cword "mrs-slot-imm-rm-unused",  RUN_SAME, 28, 0xFE, F_RISKY
    cword "mrs-slot-imm-cmp-form",   RUN_SAME, 32, 0xFE012AFE, F_RISKY

@ ─────────────── Thumb cmp pc at a halfword, and with no SPSR ─────────────
@ WHAT: (a) Thumb `cmp pc, r0` at A with A % 4 == 2, in IRQ mode, with an
@ SPSR whose T bit is clear (N set, IRQ mode, I clear).  The block overlays
@ Thumb and ARM decode: W+0/W+2 read as ARM `strmi r4, [r7]` (a breadcrumb
@ in a cleared scratch word), W+4/W+6 as a benign `orr`, then ARM `add r6,
@ r6, #2` at W+8 and `bx r5` escapes at W+12 and W+16.  (b) the same
@ instruction in System mode, which has no SPSR, with N|Z preset -- flags
@ no compare of pc against 0 can produce.
@ WHY: the Thumb `cmp pc` form restores CPSR from SPSR (the thumb-cmp-pc
@ cases above); where ARM execution then resumes is UNPREDICTABLE.  The
@ console restored the SPSR (0x80000012) and resumed past BOTH overlay words
@ and the add -- at A+10 or A+14 -- where resuming at (A+2) & ~3 runs the
@ add (r6 = 2) and resuming at A & ~3 stores the breadcrumb.  In System
@ mode the restore is a no-op: CPSR reads C000001F, not a compare's flags.
@ PROVENANCE: AGB SP, gbaedge page 35 THUMBPC3 (session 4, 2026-08-11, CRC
@ 104A; tests/roms/expected/agb-sp-4.txt): 80000012, scratch 0, r6 0,
@ clean; C000001F, clean.  Ported with the page's own block and watchdog.
run_thumbpc3:
    push {r4-r11, lr}
    ldr r8, =SLOT
    mrs r9, CPSR
    msr CPSR_c, #0xD2              @ IRQ mode: keep its stack pointer
    mov r11, sp
    msr CPSR_c, r9
    @ (a)
    ldr r7, =SCRATCH + 0x80
    mov r0, #0
    str r0, [r7]
    msr CPSR_c, #0x12              @ IRQ mode, I clear (the watchdog reaches it)
    ldr sp, =SCRATCH + 0xF0
    ldr r1, =0x80000012            @ SPSR: N, T clear, IRQ mode, I clear
    msr SPSR_cxsf, r1
    wdg_arm tp3_rec
    ldr r4, =0xC0DEC0DE
    mov r6, #0
    mov r0, #0
    ldr r5, =tp3_rec
    ldr r1, =tp3_blk + 3           @ W+2, Thumb
    bx  r1
tp3_rec:
    mrs r10, CPSR                  @ as it resumed, before anything else
    msr CPSR_c, #0xD2
    mov sp, r11
    msr CPSR_cxsf, r9
    wdg_disarm
    str r10, [r8, #0]
    ldr r0, [r7]
    str r0, [r8, #4]
    strb r6, [r8, #8]
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    strb r0, [r8, #9]
    mov r0, #0
    str r0, [r2, #8]
    @ (b)
    msr CPSR_c, #0x1F              @ System mode, I clear
    wdg_arm tp3b_rec
    ldr r0, =0xC0000000
    msr CPSR_f, r0                 @ N|Z: no compare of pc with 0 gives both
    mov r0, #0
    adr r3, tp3b_ret
    adr r1, tp3b_pad
    orr r1, r1, #1
    bx  r1
    .thumb
tp3b_pad:
    .hword 0x4587                  @ cmp pc, r0
    .hword 0x4718                  @ bx r3
    .hword 0x4718                  @ bx r3 (a skipped slot still escapes)
    .hword 0x4718
    .align 2
    .arm
tp3b_ret:
    mrs r1, CPSR
    str r1, [r8, #12]
tp3b_rec:
    msr CPSR_c, #0xD2
    mov sp, r11
    msr CPSR_cxsf, r9
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    strb r0, [r8, #16]
    mov r0, #0
    str r0, [r2, #8]
    pop {r4-r11, pc}
    .ltorg
    .align 2
tp3_blk:                           @ W
    .hword 0x4000                  @ W+0: ARM word W = strmi r4, [r7]
    .hword 0x4587                  @ W+2: Thumb cmp pc, r0 (the entry, A)
    .hword 0x4728                  @ W+4: Thumb bx r5 / ARM low half
    .hword 0xE387                  @ W+6: ARM word W+4 = orr r4, r7, #...
    .word 0xE2866002               @ W+8:  add r6, r6, #2
    .word 0xE12FFF15               @ W+12: bx r5
    .word 0xE12FFF15               @ W+16: bx r5 (safety)
    cword "thumb-cmp-pc-halfword-restores-spsr", run_thumbpc3, 0, 0x80000012, F_RISKY
    cword "thumb-cmp-pc-halfword-not-at-a-and-3", RUN_SAME, 4, 0, F_RISKY
    cbyte "thumb-cmp-pc-halfword-skips-the-add", RUN_SAME, 8, 0, F_RISKY
    cbyte "thumb-cmp-pc-halfword-clean", RUN_SAME, 9, 1, F_RISKY
    cword "thumb-cmp-pc-system-mode-no-op", RUN_SAME, 12, 0xC000001F, F_RISKY
    cbyte "thumb-cmp-pc-system-mode-clean", RUN_SAME, 16, 1, F_RISKY

@ ──────────────────────────── Thumb multiply ──────────────────────────────
@ WHAT/PROVENANCE: tests/roms/payloads/thumbmul.s -- 64 Thumb multiplies
@ timed from IWRAM.  AGB SP through the link rig, 2026-09-17: 317 cycles
@ (memory note gba-hardware-link-2026-09-17: "317 on all three").
    payload_blob pl_thumbmul, "thumbmul.bin"
    cpay "thumb-mul-64-iwram-cycles", pl_thumbmul, 0, 317
