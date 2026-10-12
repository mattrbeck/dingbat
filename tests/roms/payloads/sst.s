@ payload: where the SingleStepTests ARM7TDMI vectors and dingbat disagree,
@ asked of the console (docs/hwprobe-sst.md has the questions and answers).
@
@ The vectors were made by running a reference emulator, not hardware, so a
@ disagreement between them and dingbat is settled here. r0 = the cell's
@ number (tools/hwlink/sst.py, CELLS, names them in this order); the answer
@ comes back in r0. sst.inc is the frame: it saves and restores every bank,
@ SPSR, IME, IE, the timers and the IRQ vector around the cell.
@
@ Every cell here comes back by itself or through the watchdog (sst.inc).
@ The ones that touch the undefined-instruction vector, or may jump into the
@ BIOS, are in sstrisk.s, uploaded separately and run last.
@
@ Answer formats, by group (A = the address of the instruction tested):
@   t.*  timer cycles (TM1, prescaler 1) from its start to its read around
@        four copies of the instruction; t.ctrl / t.thumb_ctrl hold none
@   v.*  a stored r15 as (value - A): a word, a byte lane, a halfword lane
@        with the rest of the pre-filled 0xAAAAAAAA word kept
@   v.push_order.*  TM0's count << 16 | TM1's, both started by one store
@        of two words (TM0's control word at the lower address)
@   markers: bit n set when the word at A+4(n+1)... ran; see each cell
@   psr: the CPSR or SPSR as read back

    .include "sst.inc"
    sst_entry cells, NCELLS

@ ---------------------------------------------------------------- timing
@ r9 = the destination, r10 = TM0CNT, r11 = a timer start word, TM1 timed

t_iw:
    ldr r9, =SCR_IW
    bx  r8
t_ew:
    ldr r9, =SCR_EW
    bx  r8

t_setup:
    ldr r10, =0x04000100
    ldr r11, =0x00800000
    mov r0, #0
    str r0, [r10, #4]
    mov r1, #1
    mov r2, #2
    mov r3, #3
    mov r4, #4
    mov r12, #12
    bx  lr

    .macro TCELL name, insn:vararg
\name\()_iw:
    adr r8, \name
    b   t_iw
\name\()_ew:
    adr r8, \name
    b   t_ew
\name:
    bl  t_setup
    str r11, [r10, #4]
    .rept 4
    \insn
    .endr
    ldrh r0, [r10, #4]
    b   finish
    .endm

t_ctrl:
    bl  t_setup
    str r11, [r10, #4]
    ldrh r0, [r10, #4]
    b   finish

    TCELL t_str_r0, str r0, [r9]
    TCELL t_str_pc, .word 0xE589F000          @ str pc, [r9]
    TCELL t_strb_r0, strb r0, [r9]
    TCELL t_strb_pc, .word 0xE5C9F000         @ strb pc, [r9]
    TCELL t_strh_r0, strh r0, [r9]
    TCELL t_strh_pc, .word 0xE1C9F0B0         @ strh pc, [r9]
    TCELL t_stm4, stmia r9, {r0-r3}
    TCELL t_stm3pc, .word 0xE8898007          @ stmia r9, {r0-r2, pc}
    TCELL t_apcs_r0, stmdb r9!, {r0, r4, r11, r12, lr}
    TCELL t_apcs_pc, .word 0xE929D810        @ stmdb r9!, {r4, r11, r12, lr, pc}

@ Thumb: the timer starts in ARM, `bx` into the block, four pushes, `bx`
@ back; sp is the destination (r9 + 0x200)
t_thumb:
    bl  t_setup
    add sp, r9, #0x200
    adr r7, 2f
    str r11, [r10, #4]
    bx  r8
    .balign 4
2:  ldrh r0, [r10, #4]
    ldr sp, =STK
    b   finish

    .macro THCELL name, hw
\name\()_iw:
    adr r8, \name + 1
    ldr r9, =SCR_IW
    b   t_thumb
\name\()_ew:
    adr r8, \name + 1
    ldr r9, =SCR_EW
    b   t_thumb
    .thumb
    .balign 4
\name:
    .rept 4
    .hword \hw
    .endr
    bx  r7
    .arm
    .balign 4
    .endm

t_thumb_ctrl:
    adr r8, 1f + 1
    ldr r9, =SCR_IW
    b   t_thumb
    .thumb
    .balign 4
1:  bx  r7
    .arm
    .balign 4

    THCELL t_push_r0, 0xB401                  @ push {r0}
    THCELL t_push_lr, 0xB500                  @ push {lr}
    THCELL t_push_r3r7, 0xB4F8                @ push {r3-r7}
    THCELL t_push_r4r7lr, 0xB5F0              @ push {r4-r7, lr}

@ ---------------------------------------------------------------- values
v_prefill:
    ldr r9, =SCR_IW
    ldr r1, =0xAAAAAAAA
    mov r2, r1
    mov r3, r1
    mov r4, r1
    stmdb r9, {r1-r4}
    stmia r9, {r1-r4}
    mov r0, #0
    mov r1, #1
    mov r2, #2
    bx  lr

v_str_pc:
    bl  v_prefill
1:  .word 0xE589F000                          @ str pc, [r9]
    ldr r0, [r9]
    adr r1, 1b
    sub r0, r0, r1
    b   finish

v_strb_pc:
    bl  v_prefill
1:  .word 0xE5C9F000                          @ strb pc, [r9]
    ldr r0, [r9]
    adr r1, 1b
    sub r2, r0, r1
    and r2, r2, #0xFF
    bic r0, r0, #0xFF
    orr r0, r0, r2
    b   finish

v_strh_pc:
    bl  v_prefill
1:  .word 0xE1C9F0B0                          @ strh pc, [r9]
    ldr r0, [r9]
    adr r1, 1b
    sub r2, r0, r1
    mov r2, r2, lsl #16
    mov r2, r2, lsr #16
    mov r0, r0, lsr #16
    orr r0, r2, r0, lsl #16
    b   finish

v_stm_pc:
    bl  v_prefill
1:  .word 0xE8898007                          @ stmia r9, {r0-r2, pc}
    ldr r0, [r9, #12]
    adr r1, 1b
    sub r0, r0, r1
    b   finish

v_apcs_pc:
    bl  v_prefill
1:  .word 0xE909D810                         @ stmdb r9, {r4, r11, r12, lr, pc}
    ldr r0, [r9, #-4]
    adr r1, 1b
    sub r0, r0, r1
    b   finish

@ PUSH's store order, read off the timers: the two words start TM0 and TM1;
@ whichever is stored first has the higher count when both are read.
v_po_setup:
    ldr r10, =0x04000100
    mov r0, #0
    str r0, [r10]
    str r0, [r10, #4]
    ldr r0, =0x00800000
    mov r1, r0
    bx  lr

v_po_read:
    ldmia r10, {r2, r3}
    ldr sp, =STK
    mov r0, #0
    str r0, [r10]
    str r0, [r10, #4]
    mov r2, r2, lsl #16
    mov r3, r3, lsl #16
    orr r0, r2, r3, lsr #16
    b   finish

v_po_thumb:
    bl  v_po_setup
    ldr sp, =0x04000108
    adr r5, v_po_read
    adr r12, 1f + 1
    bx  r12
    .thumb
    .balign 4
1:  .hword 0xB403                             @ push {r0, r1}
    bx  r5
    .arm
    .balign 4

v_po_stmia:
    bl  v_po_setup
    stmia r10, {r0, r1}
    b   v_po_read

v_po_desc:
    bl  v_po_setup
    str r1, [r10, #4]
    str r0, [r10]
    b   v_po_read

@ ---------------------------------------------------------------- cheap cells
@ Thumb shift by register with Rs = 0x101: the bottom byte (1) or the whole
@ register (a shift of 32 or more)
    .macro TSHIFT name, r0val, hw
\name:
    ldr r0, =\r0val
    ldr r1, =0x101
    msr cpsr_f, #0
    ldr r5, =finish
    adr r12, 1f + 1
    bx  r12
    .thumb
    .balign 4
1:  .hword \hw
    bx  r5
    .arm
    .balign 4
    .endm

    TSHIFT c_lsl, 0x00000001, 0x4088          @ lsl r0, r1
    TSHIFT c_lsr, 0x80000000, 0x40C8          @ lsr r0, r1
    TSHIFT c_asr, 0x80000000, 0x4108          @ asr r0, r1

@ mov pc, r0, lsl r1 lands on T: markers T-8 1, T-4 2, T 4, T+4 8
c_movpc:
    adr r0, 5f
    mov r0, r0, lsr #1
    mov r1, #1
    mov pc, r0, lsl r1
    MK  0x80                                  @ not taken
    b   6f
    MK  1
    MK  2
5:  MK  4
    MK  8
6:  mov r0, r6
    b   finish

@ r8-r12: System writes tag 1, IRQ tag 2 (the same registers), FIQ tag 3
@ (its own); then SVC, FIQ and System read them. Answer: one nibble a
@ register, r8 lowest -- 0x22222 is the shared bank, 0x33333 FIQ's.
c_fiq_pack:
    mov r0, r8, lsr #4
    mov r1, r9, lsr #4
    orr r0, r0, r1, lsl #4
    mov r1, r10, lsr #4
    orr r0, r0, r1, lsl #8
    mov r1, r11, lsr #4
    orr r0, r0, r1, lsl #12
    mov r1, r12, lsr #4
    orr r0, r0, r1, lsl #16
    bx  lr

c_fiq:
    mov r7, r0                                @ which view
    msr cpsr_c, #0xDF
    mov r8, #0x10
    mov r9, #0x11
    mov r10, #0x12
    mov r11, #0x13
    mov r12, #0x14
    msr cpsr_c, #0xD2
    mov r8, #0x20
    mov r9, #0x21
    mov r10, #0x22
    mov r11, #0x23
    mov r12, #0x24
    msr cpsr_c, #0xD1
    mov r8, #0x30
    mov r9, #0x31
    mov r10, #0x32
    mov r11, #0x33
    mov r12, #0x34
    msr cpsr_c, #0xD3
    bl  c_fiq_pack
    mov r4, r0
    msr cpsr_c, #0xD1
    bl  c_fiq_pack
    mov r5, r0
    msr cpsr_c, #0xDF
    bl  c_fiq_pack
    mov r6, r0
    mov r0, r4
    cmp r7, #1
    moveq r0, r5
    cmp r7, #2
    moveq r0, r6
    b   finish
c_fiq_svc:
    mov r0, #0
    b   c_fiq
c_fiq_fiq:
    mov r0, #1
    b   c_fiq
c_fiq_sys:
    mov r0, #2
    b   c_fiq

@ MSR in User mode; the CPSR as User mode reads it after. The watchdog takes
@ the CPU back out. Flags clear before.
    .macro UMSR name, insn:vararg
\name:
    adr r0, 9f
    bl  wd_arm
    mov r7, #0
    ldr r2, =0xF000001F
    msr cpsr_f, #0
    msr cpsr_c, #0x10                         @ User, I clear
    \insn
    mrs r7, cpsr
    b   .
9:  mov r0, r7
    b   finish
    .endm

    UMSR c_umsr_sys, msr cpsr_c, #0x1F
    UMSR c_umsr_fc, msr cpsr_fc, r2
    UMSR c_umsr_svc, msr cpsr_c, #0x13

c_smsr_svc:                                   @ control: from System it works
    msr cpsr_f, #0
    msr cpsr_c, #0xD3
    mrs r0, cpsr
    b   finish

@ ---------------------------------------------------------------- re-confirm
@ The S-bit write to r15 in System mode (sysmovs.s, the same cells): r1 =
@ 0 movs pc, lr; 1 subs pc, lr, #0; 2 ldmfd sp!, {pc}^; bit 4 leaves a
@ Thumb SPSR in IRQ mode first. Answer as sysmovs.s: CPSR low byte, its
@ flags byte, bit 9 if execution went on as ARM.
r_movs:
    tst r1, #0x10
    beq 1f
    msr cpsr_c, #0x92
    ldr r2, =0x8000003F
    msr spsr_cxsf, r2
1:  msr cpsr_c, #0x9F
    adr r5, r_rec
    adr lr, r_pad
    adr r2, r_pad
    stmfd sp!, {r2}
    and r0, r1, #3
    adr r2, r_f_movs
    cmp r0, #1
    adreq r2, r_f_subs
    adrhi r2, r_f_ldm
    msr cpsr_f, #0x60000000
    mov pc, r2
r_f_movs:
    movs pc, lr
r_f_subs:
    subs pc, lr, #0
r_f_ldm:
    ldmfd sp!, {pc}^
    .balign 4
r_pad:
    .hword 0x4728                             @ Thumb: bx r5
    .hword 0xE1A0                             @ ARM: mov r4, r8, lsr #14
    b   r_rec_arm
r_rec_arm:
    orr r6, r6, #0x200
r_rec:
    mrs r7, cpsr
    ldr r1, =vars
    ldr r1, [r1, #V_WDCONT]
    cmp r1, #0
    bne .                                     @ User mode: wait for the watchdog
r_out:
    ldr sp, =STK
    and r0, r7, #0xFF
    and r1, r7, #0xFF000000
    orr r0, r0, r1
    orr r0, r0, r6
    b   finish

    .macro RMOVS name, v
\name:
    ldr r1, =vars
    mov r0, #0
    str r0, [r1, #V_WDCONT]
    mov r1, #\v
    b   r_movs
    .endm
    RMOVS r_movs0, 0
    RMOVS r_movs1, 1
    RMOVS r_movs2, 2
    RMOVS r_movs10, 0x10
    RMOVS r_movs11, 0x11
    RMOVS r_movs12, 0x12

@ the same three from User mode, I clear; out through the watchdog
r_umovs:
    mov r8, r1
    adr r0, r_out
    bl  wd_arm
    adr r5, r_rec
    adr lr, r_pad
    adr r2, r_pad
    stmfd sp!, {r2}
    and r0, r8, #3
    adr r2, r_f_movs
    cmp r0, #1
    adreq r2, r_f_subs
    adrhi r2, r_f_ldm
    msr cpsr_c, #0x10                         @ User, I clear
    msr cpsr_f, #0x60000000
    mov pc, r2

    .macro RUMOVS name, v
\name:
    mov r1, #\v
    b   r_umovs
    .endm
    RUMOVS r_umovs0, 0
    RUMOVS r_umovs1, 1
    RUMOVS r_umovs2, 2

@ r15 as a base with writeback. The word at A is the instruction; A+4..
@ A+16 are markers 1, 2, 4, 8, so the bits say where execution went on.
@ Answer: markers | (r1's low byte << 8) (r1 starts 0x5E; a load of a
@ marker word gives its n) | (which of A+8, A+12 a store changed << 16:
@ bit 0 A+8, bit 1 A+12).
r_wb_pre:
    ldr r1, =0x5EE5EE5E
    bx  lr
r_wb_store:                                   @ a store writes `orr r6, r6, #0x40`
    ldr r1, =0xE3866040
    bx  lr
r_wb_post:                                    @ r4 = A
    and r0, r1, #0xFF
    orr r0, r6, r0, lsl #8
    ldr r2, [r4, #8]
    ldr r3, =0xE3866002
    cmp r2, r3
    orrne r0, r0, #0x10000
    str r3, [r4, #8]
    ldr r2, [r4, #12]
    ldr r3, =0xE3866004
    cmp r2, r3
    orrne r0, r0, #0x20000
    str r3, [r4, #12]
    b   finish

    .macro RWB name, setup, word
\name:
    bl  \setup
    adr r4, 1f
1:  .word \word
    MK  1
    MK  2
    MK  4
    MK  8
    b   r_wb_post
    .endm
    RWB r_ldm_wb, r_wb_pre, 0xE8BF0002        @ ldmia pc!, {r1}
    RWB r_str_post, r_wb_store, 0xE48F1004    @ str r1, [pc], #4
    RWB r_ldr_post, r_wb_pre, 0xE49F1004      @ ldr r1, [pc], #4
    RWB r_ldr_prewb, r_wb_pre, 0xE5BF1004     @ ldr r1, [pc, #4]!
    RWB r_str_prewb, r_wb_store, 0xE5AF1004   @ str r1, [pc, #4]!
    RWB r_stm_wb, r_wb_store, 0xE8AF0002      @ stmia pc!, {r1}

@ PSR bits: CPSR written 0x0FFFFFDF in System mode; IRQ's SPSR written
@ three ways. Answer: the PSR read back.
r_cpsrbits:
    ldr r1, =0x0FFFFFDF
    msr cpsr_cxsf, r1
    mrs r0, cpsr
    msr cpsr_cxsf, #0xDF
    b   finish

    .macro RSPSR name, val
\name:
    msr cpsr_c, #0xD2
    ldr r1, =\val
    msr spsr_cxsf, r1
    mrs r0, spsr
    b   finish
    .endm
    RSPSR r_spsr_mid, 0x0FFFFF00
    RSPSR r_spsr_all, 0xFFFFFFEF
    RSPSR r_spsr_zero, 0x00000000

@ Thumb `cmp pc, r0` at a word boundary, r0 = 0 (a plain compare sets C
@ only), Z and C set before. IRQ mode with SPSR 0x900000BF (N, V, I, T,
@ System), or System mode. The halfword after it escapes (`bx r5`).
@ Answer: the CPSR at the escape.
r_tcmp:
    msr cpsr_f, #0x60000000
    mov r0, #0
    adr r5, 2f
    adr r12, 1f + 1
    bx  r12
    .thumb
    .balign 4
1:  .hword 0x4587                             @ cmp pc, r0
    .hword 0x4728                             @ bx r5
    .hword 0x4728
    .hword 0x4728
    .arm
    .balign 4
2:  mrs r0, cpsr
    b   finish

r_tcmp_irq:
    msr cpsr_c, #0x92
    ldr r1, =0x900000BF
    msr spsr_cxsf, r1
    b   r_tcmp
r_tcmp_sys:
    msr cpsr_c, #0x9F
    b   r_tcmp

@ ---------------------------------------------------------------- UNPREDICTABLE
@ TST/TEQ/CMP/CMN with S set and Rd = r15 (ARMv2's TSTP etc.). Operands
@ make the ALU result the address of u_tp_pad. SVC: CPSR 0x600000D3, SPSR
@ 0x900000DF; IRQ: 0x600000D2, SPSR 0x300000D7; System: 0x600000DF.
@ Answer: CPSR low byte | flags byte | markers << 8 (1, 2: A+4, A+8 ran;
@ 0x10: execution went to the result).
u_tp:                                         @ r7 = op (0-3), r8 = mode (0-2)
    adr r4, u_tp_pad
    ldr r1, =0xFFFFFFFF
    mov r0, r4
    cmp r7, #1
    eoreq r0, r4, #0x80000000
    moveq r1, #0x80000000
    cmp r7, #2
    addeq r0, r4, #1
    moveq r1, #1
    cmp r7, #3
    subeq r0, r4, #1
    moveq r1, #1
    adr r3, u_tp_blocks
    add r3, r3, r7, lsl #4
    cmp r8, #0
    beq 1f
    cmp r8, #1
    beq 2f
    msr cpsr_c, #0xDF
    b   3f
1:  msr cpsr_c, #0xD3
    ldr r2, =0x900000DF
    msr spsr_cxsf, r2
    b   3f
2:  msr cpsr_c, #0xD2
    ldr r2, =0x300000D7
    msr spsr_cxsf, r2
3:  msr cpsr_f, #0x60000000
    mov pc, r3
    .balign 16
u_tp_blocks:
    .word 0xE110F001                          @ tst r0, r1 with Rd = r15
    MK  1
    MK  2
    b   u_tp_rec
    .word 0xE130F001                          @ teq
    MK  1
    MK  2
    b   u_tp_rec
    .word 0xE150F001                          @ cmp
    MK  1
    MK  2
    b   u_tp_rec
    .word 0xE170F001                          @ cmn
    MK  1
    MK  2
    b   u_tp_rec
u_tp_pad:
    MK  0x10
    b   u_tp_rec
u_tp_rec:
    mrs r7, cpsr
    msr cpsr_c, #0xDF
    and r0, r7, #0xFF
    and r1, r7, #0xF0000000
    orr r0, r0, r1
    orr r0, r0, r6, lsl #8
    b   finish

    .macro UTP name, op, mode
\name:
    mov r7, #\op
    mov r8, #\mode
    b   u_tp
    .endm
    UTP u_tst_svc, 0, 0
    UTP u_teq_svc, 1, 0
    UTP u_cmp_svc, 2, 0
    UTP u_cmn_svc, 3, 0
    UTP u_tst_irq, 0, 1
    UTP u_teq_irq, 1, 1
    UTP u_cmp_irq, 2, 1
    UTP u_cmn_irq, 3, 1
    UTP u_tst_sys, 0, 2
    UTP u_teq_sys, 1, 2
    UTP u_cmp_sys, 2, 2
    UTP u_cmn_sys, 3, 2

@ r15 read by register-shifted data processing. Answers:
@ u_rs15: mov r0, r1, lsr r15 with r1 = 0xFFFFFFFF at A = xx00, so r0 =
@   0xFFFFFFFF >> (the low byte r15 read as): 0x00FFFFFF is 8, 0x000FFFFF 12
@ u_rn15 / u_rm15: r0 - A (GBATEK: 12)
u_rs15:
    mvn r1, #0
    b   u_rs15_a
u_rn15:
    mov r1, #0
    mov r2, #0
1:  .word 0xE08F0211                          @ add r0, pc, r1, lsl r2
    adr r1, 1b
    sub r0, r0, r1
    b   finish
u_rm15:
    mov r2, #0
1:  .word 0xE1A0021F                          @ mov r0, pc, lsl r2
    adr r1, 1b
    sub r0, r0, r1
    b   finish

@ multiplies writing r15: the product is u_mp_pad's address. Answer:
@ markers (1, 2: A+4, A+8 ran; 0x10: went to the product)
    .macro UMP name, word, a, b
\name:
    ldr r0, =\a
    ldr r1, =\b
    mov r2, #0
    mov r3, #0
    .word \word
    MK  1
    MK  2
    b   u_mp_rec
    .endm
u_mp_pad:
    MK  0x10
u_mp_rec:
    mov r0, r6
    b   finish
    UMP u_mul_rd15, 0xE00F0190, u_mp_pad, 1             @ mul pc, r0, r1
    UMP u_mla_rd15, 0xE02F2190, u_mp_pad, 1             @ mla pc, r0, r1, r2
    UMP u_umull_lo15, 0xE083F190, u_mp_pad, 1           @ umull pc, r3, r0, r1
u_umull_hi15:                                 @ umull r3, pc, r0, r1: hi = pad
    ldr r0, =0x80000000
    adr r1, u_mp_pad
    add r1, r1, r1
    mov r2, #0
    mov r3, #0
    .word 0xE08F3190
    MK  1
    MK  2
    b   u_mp_rec

@ multiplies reading r15. Answer: r0 - A
    .macro UMR name, word, b, c
\name:
    ldr r1, =\b
    ldr r2, =\c
    mov r3, #0
1:  .word \word
    adr r1, 1b
    sub r0, r0, r1
    b   finish
    .endm
    UMR u_mul_rm15, 0xE000019F, 1, 0          @ mul r0, pc, r1
    UMR u_mul_rs15, 0xE0000F91, 1, 0          @ mul r0, r1, pc
    UMR u_mla_rn15, 0xE020F291, 0, 0          @ mla r0, r1, r2, pc
    UMR u_umull_rm15, 0xE083019F, 1, 0        @ umull r0, r3, pc, r1

@ SWP with r15. u_swp_rm15: swp r0, pc, [r1]; answer: the stored word - A.
@ u_swp_rd15: swp pc, r0, [r1] with [r1] = u_sw_pad; answer: markers
@ (0x10 went to the loaded word) | 0x100 if r0 was stored.
@ u_swp_rn15: swp r0, r1, [pc] with r1 = `orr r6, r6, #0x40`; A+4..A+12
@ are markers 1, 2, 4. Answer: r0's low byte (the marker word it read) |
@ markers << 8 | which of A+4, A+8, A+12 changed << 16.
u_swp_rm15:
    ldr r1, =SCR_IW
    ldr r0, =0xAAAAAAAA
    str r0, [r1]
1:  .word 0xE101009F                          @ swp r0, pc, [r1]
    ldr r0, [r1]
    adr r2, 1b
    sub r0, r0, r2
    b   finish

u_swp_rd15:
    ldr r1, =SCR_IW
    adr r0, u_sw_pad
    str r0, [r1]
    ldr r0, =0x12345678
    .word 0xE101F090                          @ swp pc, r0, [r1]
    MK  1
    MK  2
    b   u_sw_rec
u_sw_pad:
    MK  0x10
u_sw_rec:
    ldr r1, =SCR_IW
    ldr r1, [r1]
    ldr r2, =0x12345678
    mov r0, r6
    cmp r1, r2
    orreq r0, r0, #0x100
    b   finish

u_swp_rn15:
    ldr r1, =0xE3866040
    ldr r0, =0x5EE5EE5E
    adr r4, 1f
1:  .word 0xE10F0091                          @ swp r0, r1, [pc]
    MK  1
    MK  2
    MK  4
    and r0, r0, #0xFF
    orr r0, r0, r6, lsl #8
    ldr r3, =0xE3866001
    ldr r2, [r4, #4]
    cmp r2, r3
    orrne r0, r0, #0x10000
    str r3, [r4, #4]
    add r3, r3, #1
    ldr r2, [r4, #8]
    cmp r2, r3
    orrne r0, r0, #0x20000
    str r3, [r4, #8]
    add r3, r3, #2
    ldr r2, [r4, #12]
    cmp r2, r3
    orrne r0, r0, #0x40000
    str r3, [r4, #12]
    b   finish

    .ltorg
    sst_frame

    .balign 256
u_rs15_a:
    .word 0xE1A00F31                          @ mov r0, r1, lsr pc
    b   finish

@ the order is tools/hwlink/sst.py's CELLS
    .align 2
cells:
    .word t_ctrl
    .word t_str_r0_iw, t_str_pc_iw, t_strb_r0_iw, t_strb_pc_iw
    .word t_strh_r0_iw, t_strh_pc_iw, t_stm4_iw, t_stm3pc_iw
    .word t_apcs_r0_iw, t_apcs_pc_iw
    .word t_str_r0_ew, t_str_pc_ew, t_strb_r0_ew, t_strb_pc_ew
    .word t_strh_r0_ew, t_strh_pc_ew, t_stm4_ew, t_stm3pc_ew
    .word t_apcs_r0_ew, t_apcs_pc_ew
    .word t_thumb_ctrl
    .word t_push_r0_iw, t_push_lr_iw, t_push_r3r7_iw, t_push_r4r7lr_iw
    .word t_push_r0_ew, t_push_lr_ew, t_push_r3r7_ew, t_push_r4r7lr_ew
    .word v_str_pc, v_strb_pc, v_strh_pc, v_stm_pc, v_apcs_pc
    .word v_po_thumb, v_po_stmia, v_po_desc
    .word c_lsl, c_lsr, c_asr, c_movpc
    .word c_fiq_svc, c_fiq_fiq, c_fiq_sys
    .word c_umsr_sys, c_umsr_fc, c_umsr_svc, c_smsr_svc
    .word r_movs0, r_movs1, r_movs2, r_movs10, r_movs11, r_movs12
    .word r_umovs0, r_umovs1, r_umovs2
    .word r_ldm_wb, r_str_post, r_ldr_post, r_ldr_prewb, r_str_prewb, r_stm_wb
    .word r_cpsrbits, r_spsr_mid, r_spsr_all, r_spsr_zero
    .word r_tcmp_irq, r_tcmp_sys
    .word u_tst_svc, u_teq_svc, u_cmp_svc, u_cmn_svc
    .word u_tst_irq, u_teq_irq, u_cmp_irq, u_cmn_irq
    .word u_tst_sys, u_teq_sys, u_cmp_sys, u_cmn_sys
    .word u_rs15, u_rn15, u_rm15
    .word u_mul_rd15, u_mla_rd15, u_umull_lo15, u_umull_hi15
    .word u_mul_rm15, u_mul_rs15, u_mla_rn15, u_umull_rm15
    .word u_swp_rm15, u_swp_rd15, u_swp_rn15
cells_end:
.equ NCELLS, (cells_end - cells) / 4

    sst_vars
