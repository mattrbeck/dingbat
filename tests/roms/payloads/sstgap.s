@ payload: the SingleStepTests ARM7TDMI forms the first probe did not run.
@
@ tests/singlestep_arm7.nim excuses a known divergence by its encoding: one
@ or two cells of sst.s / sstrisk.s settled each rule, and the rule then
@ covers every vector case of that shape. These cells ask the console about
@ the forms those cells left out (docs/hwprobe-sst.md, section 7): TSTP in
@ User mode, the other ALU ops writing r15 with S set, the byte, T,
@ register-offset and Rd = r15 forms of an r15 base with writeback, the
@ other LDM/STM addressing modes with `^` and with r15 in the list, the
@ signed and accumulating long multiplies, SWPB, and Thumb `cmp pc` in the
@ other modes. Every cell comes back by itself or through the watchdog;
@ the ones that may trap or jump into the BIOS are in sstrisk.s.
@
@ r0 = the cell (tools/hwlink/sst.py, GAP_CELLS); answers, A = the address
@ of the instruction tested:
@   ut.*  (User TSTP): CPSR low byte | flags byte | markers << 8 (1, 2: A+4,
@         A+8 ran; 0x10: execution went to the ALU result)
@   sa.*  (System, S-bit ALU op to r15): CPSR low byte | flags byte | 0x200
@         if execution went on as ARM, as sst.s's r.sysmovs
@   wb.*  (r15 base, writeback): markers (A+4..A+16 = 1, 2, 4, 8; 0x10 a
@         pad an r15 load names; 0x40 a stored word ran) | r1's low byte
@         << 8 (0x5E or 0x40 unchanged) | which of A+4..A+16 changed << 16
@         | (the word at A+8 as found - A) << 24
@   um.*  multiplies writing r15: markers (1, 2: A+4, A+8 ran; 0x10, 0x20:
@         went to the pad, or 4 past it) | RdHi's low byte << 8
@   ur.*  multiplies reading r15: r0 - A
@   u.swpb_rn15: as sst.s's u.swp_rn15
@   tc.*  Thumb `cmp pc, rX`: the CPSR at the escape

    .include "sst.inc"
    sst_entry cells, NCELLS

@ ---------------------------------------------------------------- User TSTP
@ sst.s's u_tp in User mode, I clear, out through the watchdog. Operands
@ make the ALU result ut_pad's address. Z and C set before.
ut_tp:                                        @ r7 = op (0-3)
    adr r0, ut_out
    bl  wd_arm
    adr r4, ut_pad
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
    adr r3, ut_blocks
    add r3, r3, r7, lsl #4
    mov r7, #0
    msr cpsr_c, #0x10                         @ User, I clear
    msr cpsr_f, #0x60000000
    mov pc, r3
    .balign 16
ut_blocks:
    .word 0xE110F001                          @ tst r0, r1 with Rd = r15
    MK  1
    MK  2
    b   ut_rec
    .word 0xE130F001                          @ teq
    MK  1
    MK  2
    b   ut_rec
    .word 0xE150F001                          @ cmp
    MK  1
    MK  2
    b   ut_rec
    .word 0xE170F001                          @ cmn
    MK  1
    MK  2
    b   ut_rec
ut_pad:
    MK  0x10
ut_rec:
    mrs r7, cpsr
    b   .                                     @ until the watchdog
ut_out:
    and r0, r7, #0xFF
    and r1, r7, #0xF0000000
    orr r0, r0, r1
    orr r0, r0, r6, lsl #8
    b   finish

    .macro UT name, op
\name:
    mov r7, #\op
    b   ut_tp
    .endm
    UT  ut_tst, 0
    UT  ut_teq, 1
    UT  ut_cmp, 2
    UT  ut_cmn, 3

@ ---------------------------------------------------------------- S-bit ALU ops
@ System mode, I set, Z and C set; each op's result is sa_pad's address
@ (lr), as sst.s's r.sysmovs does for MOVS and SUBS.
sa_run:                                       @ r2 = the instruction
    adr r5, sa_rec
    adr lr, sa_pad
    mvn r3, lr                                @ mvns pc, r3
    rsb r8, lr, #0                            @ rsbs pc, r8, #0
    msr cpsr_c, #0x9F
    msr cpsr_f, #0x60000000
    mov pc, r2
    .balign 4
sa_pad:
    .hword 0x4728                             @ Thumb: bx r5
    .hword 0xE1A0                             @ ARM: mov r4, r8, lsr #14
    b   sa_arm
sa_arm:
    orr r6, r6, #0x200
sa_rec:
    mrs r7, cpsr
    msr cpsr_c, #0xDF
    and r0, r7, #0xFF
    and r1, r7, #0xFF000000
    orr r0, r0, r1
    orr r0, r0, r6
    b   finish

    .macro SA name, word
\name:
    adr r2, 1f
    b   sa_run
1:  .word \word
    MK  1                                     @ fell through (no write to r15)
    b   sa_rec
    .endm
    SA  sa_adds, 0xE29EF000                   @ adds pc, lr, #0
    SA  sa_ands, 0xE01EF00E                   @ ands pc, lr, lr
    SA  sa_orrs, 0xE39EF000                   @ orrs pc, lr, #0
    SA  sa_eors, 0xE23EF000                   @ eors pc, lr, #0
    SA  sa_bics, 0xE3DEF000                   @ bics pc, lr, #0
    SA  sa_mvns, 0xE1F0F003                   @ mvns pc, r3
    SA  sa_rsbs, 0xE278F000                   @ rsbs pc, r8, #0

@ ---------------------------------------------------------------- r15 base, writeback
@ The instruction at A, the words at A+4..A+16 (markers unless the cell
@ names a pad), `b wb_post` at A+20 and the same four words again at
@ A+24..A+36, which wb_post compares with and puts back. Flags clear, so a
@ word holding an address (cond 0000, EQ) never runs.
wb_r1_load:
    ldr r1, =0x5EE5EE5E
    mov r2, #4
    bx  lr
wb_r1_store:                                  @ a store writes `orr r6, r6, #0x40`
    ldr r1, =0xE3866040
    mov r2, #4
    bx  lr
wb_pad:
    MK  0x10
wb_post:                                      @ r4 = A
    and r0, r1, #0xFF
    orr r0, r6, r0, lsl #8
    ldr r5, [r4, #8]
    sub r5, r5, r4
    orr r0, r0, r5, lsl #24
    mov r2, #4
    mov r3, #0x10000
1:  ldr r5, [r4, r2]
    add r7, r2, #20
    ldr r7, [r4, r7]
    cmp r5, r7
    orrne r0, r0, r3
    str r7, [r4, r2]
    mov r3, r3, lsl #1
    add r2, r2, #4
    cmp r2, #16
    bls 1b
    b   finish

    .macro WB name, setup, word, w4=0xE3866001, w8=0xE3866002, w12=0xE3866004, w16=0xE3866008
\name:
    bl  \setup
    adr r4, 1f
    msr cpsr_f, #0
1:  .word \word
    .word \w4, \w8, \w12, \w16
    b   wb_post
    .word \w4, \w8, \w12, \w16
    .endm
    WB  wb_ldrb_post, wb_r1_load, 0xE4DF1004      @ ldrb r1, [pc], #4
    WB  wb_strb_post, wb_r1_store, 0xE4CF1004     @ strb r1, [pc], #4
    WB  wb_ldrt_post, wb_r1_load, 0xE4BF1004      @ ldrt r1, [pc], #4
    WB  wb_strt_post, wb_r1_store, 0xE4AF1004     @ strt r1, [pc], #4
    WB  wb_ldrbt_post, wb_r1_load, 0xE4FF1004     @ ldrbt r1, [pc], #4
    WB  wb_strbt_post, wb_r1_store, 0xE4EF1004    @ strbt r1, [pc], #4
    WB  wb_ldr_post_reg, wb_r1_load, 0xE69F1002   @ ldr r1, [pc], r2 (r2 = 4)
    WB  wb_ldr_pre_reg, wb_r1_load, 0xE7BF1002    @ ldr r1, [pc, r2]!
    WB  wb_ldrb_pre, wb_r1_load, 0xE5FF1004       @ ldrb r1, [pc, #4]!
    WB  wb_strb_pre, wb_r1_store, 0xE5EF1004      @ strb r1, [pc, #4]!
    WB  wb_ldrpc_post, wb_r1_load, 0xE49FF004, w8=wb_pad   @ ldr pc, [pc], #4
    WB  wb_ldrpc_pre, wb_r1_load, 0xE5BFF004, w12=wb_pad   @ ldr pc, [pc, #4]!
    WB  wb_strpc_post, wb_r1_store, 0xE48FF004    @ str pc, [pc], #4
    WB  wb_ldmib, wb_r1_load, 0xE9BF0002          @ ldmib pc!, {r1}
    WB  wb_ldmda, wb_r1_load, 0xE83F0002          @ ldmda pc!, {r1}
    WB  wb_ldmdb, wb_r1_load, 0xE93F0002          @ ldmdb pc!, {r1}
    WB  wb_stmdb, wb_r1_store, 0xE92F0002         @ stmdb pc!, {r1}
    WB  wb_ldmia_user, wb_r1_load, 0xE8FF0002     @ ldmia pc!, {r1}^
    WB  wb_stmia_user, wb_r1_store, 0xE8EF0002    @ stmia pc!, {r1}^
    WB  wb_ldmia_r1pc, wb_r1_load, 0xE8BF8002, w12=wb_pad  @ ldmia pc!, {r1, pc}
    WB  wb_stmia_r1pc, wb_r1_store, 0xE8AF8002    @ stmia pc!, {r1, pc}

@ ---------------------------------------------------------------- long multiplies
um_pad:
    MK  0x10
    MK  0x20
um_rec:
    and r0, r3, #0xFF
    orr r0, r6, r0, lsl #8
    b   finish

um_smull_lo15:                                @ smull pc, r3, r0, r1: lo = um_pad
    adr r0, um_pad
    mov r1, #1
    mov r3, #0
    .word 0xE0C3F190
    MK  1
    MK  2
    b   um_rec

@ umlal pc, r3, r0, r1 with r0 = um_pad - (A+8), r1 = 1, r3 = 0: lo is
@ um_pad if r15 reads as A+8 and the write lands, um_pad+4 if A+12
um_umlal_lo15:
    adr r2, 1f
    adr r0, um_pad
    sub r0, r0, r2
    sub r0, r0, #8
    mov r1, #1
    mov r3, #0
1:  .word 0xE0A3F190
    MK  1
    MK  2
    b   um_rec

    .macro UR name, word
\name:
    mov r0, #0
    mov r1, #1
    mov r3, #0
1:  .word \word
    adr r1, 1b
    sub r0, r0, r1
    b   finish
    .endm
    UR  ur_umull_rs15, 0xE0830F91             @ umull r0, r3, r1, pc
    UR  ur_smull_rm15, 0xE0C3019F             @ smull r0, r3, pc, r1
    UR  ur_smlal_rm15, 0xE0E3019F             @ smlal r0, r3, pc, r1
    UR  ur_umlal_rs15, 0xE0A30F91             @ umlal r0, r3, r1, pc

@ ---------------------------------------------------------------- SWPB
u_swpb_rn15:                                  @ swpb r0, r1, [pc]; as sst.s's u_swp_rn15
    ldr r1, =0xE3866040
    ldr r0, =0x5EE5EE5E
    adr r4, 1f
1:  .word 0xE14F0091
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

@ ---------------------------------------------------------------- Thumb cmp pc
@ sst.s's r_tcmp: Z and C set, r0 = 0, at a word boundary; the halfword
@ after escapes (`bx r5`). In an exception mode the SPSR is 0x900000BF (N,
@ V, I, T, System). Answer: the CPSR at the escape.
tc_run:                                       @ r8 = the Thumb block
    msr cpsr_f, #0x60000000
    mov r0, #0
    adr r5, tc_rec
    add r12, r8, #1
    bx  r12
    .thumb
    .balign 4
tc_cmp_r0:
    .hword 0x4587                             @ cmp pc, r0
    .hword 0x4728                             @ bx r5
    .hword 0x4728
    .hword 0x4728
tc_cmp_pc:
    .hword 0x45FF                             @ cmp pc, pc
    .hword 0x4728
    .hword 0x4728
    .hword 0x4728
    .arm
    .balign 4
tc_rec:
    mrs r0, cpsr
    msr cpsr_c, #0xDF
    b   finish

    .macro TC name, mode, block
\name:
    msr cpsr_c, #\mode
    ldr r1, =0x900000BF
    msr spsr_cxsf, r1
    adr r8, \block
    b   tc_run
    .endm
    TC  tc_svc, 0x93, tc_cmp_r0
    TC  tc_fiq, 0x91, tc_cmp_r0
    TC  tc_abt, 0x97, tc_cmp_r0
    TC  tc_und, 0x9B, tc_cmp_r0
    TC  tc_irq_pcpc, 0x92, tc_cmp_pc

tc_usr:                                       @ User mode: out through the watchdog
    adr r0, tc_usr_out
    bl  wd_arm
    adr r5, tc_usr_rec
    adr r12, tc_cmp_r0 + 1
    mov r0, #0
    mov r7, #0
    msr cpsr_c, #0x10
    msr cpsr_f, #0x60000000
    bx  r12
tc_usr_rec:
    mrs r7, cpsr
    b   .
tc_usr_out:
    mov r0, r7
    b   finish

    .ltorg
    sst_frame

@ the order is tools/hwlink/sst.py's GAP_CELLS
    .align 2
cells:
    .word ut_tst, ut_teq, ut_cmp, ut_cmn
    .word sa_adds, sa_ands, sa_orrs, sa_eors, sa_bics, sa_mvns, sa_rsbs
    .word wb_ldrb_post, wb_strb_post, wb_ldrt_post, wb_strt_post, wb_ldrbt_post, wb_strbt_post
    .word wb_ldr_post_reg, wb_ldr_pre_reg, wb_ldrb_pre, wb_strb_pre
    .word wb_ldrpc_post, wb_ldrpc_pre, wb_strpc_post
    .word wb_ldmib, wb_ldmda, wb_ldmdb, wb_stmdb, wb_ldmia_user, wb_stmia_user
    .word wb_ldmia_r1pc, wb_stmia_r1pc
    .word um_smull_lo15, um_umlal_lo15
    .word ur_umull_rs15, ur_smull_rm15, ur_smlal_rm15, ur_umlal_rs15
    .word u_swpb_rn15
    .word tc_svc, tc_fiq, tc_abt, tc_und, tc_irq_pcpc, tc_usr
cells_end:
.equ NCELLS, (cells_end - cells) / 4

    sst_vars
