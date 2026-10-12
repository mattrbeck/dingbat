@ payload: the SingleStepTests cells that may take an undefined-instruction
@ exception or jump into the BIOS (sst.s has the rest; docs/hwprobe-sst.md).
@ Uploaded on its own and run after everything else: if one of these
@ wedges the console, the other answers are already in.
@
@ What makes them safe to try. The BIOS's undefined-instruction vector,
@ with no debugging cartridge in the slot (GBATEK: the handler forwards to
@ a cartridge only when the header's debug bits are set), returns with
@ SUBS PC, LR, #4: to the undefined instruction itself from ARM, and to the
@ halfword before it from Thumb. So
@   - an ARM trap would loop on the instruction. Each cell runs with the
@     watchdog armed (sst.inc) and I clear, so the loop ends in wd_handler,
@     which reads the trap off R14_und.
@   - the Thumb cell puts `bx r5` in the halfword before the instruction:
@     a trap returns there and escapes. A branch lands on `bx r3`, a fall
@     through on `bx r2`.
@   - MRS into r15 reads SPSR_svc = 0x00000010, so a write of it to r15
@     sends execution to 0x10, the BIOS's vector that branches into the
@     same handler (a word-aligned value: no question of how r15's low
@     bits are taken). R14_svc is set so its SUBS PC, LR, #4 comes back to
@     mr_bios, in User mode with I clear (SPSR_svc), where it waits for
@     the watchdog.
@
@ r0 = the cell (tools/hwlink/sst.py, RISK_CELLS); answers:
@   x.mrc14_*: r0 after `mrc p14, 0, r0, cN, c0, 0` (r0 = 0x5EE5EE5E
@       before; GBATEK: the prefetched opcode, the word at A+8, here
@       0xC0DE14xx), or 0x7A70xxxx if it trapped, xxxx = R14_und - A
@   x.mcr14_c1: 0x14 if it fell through, 0x7A70xxxx if it trapped
@   x.mrc14_r15: `mrc p14, 0, r15, c0, c0, 0` with the word at A+8
@       0xA0DE14F0 and the flags clear: the CPSR's flags byte << 24 | its
@       low byte, or 0x7A70xxxx
@   x.thumb_dexx: bits 0-7 how it left (1 branched, 2 fell through, 4
@       trapped and returned before it, 8 the watchdog); bits 8-15
@       R14_und - A (0 before: unchanged if no trap); bits 16-23 SPSR_und's
@       low byte, 24-31 its flags byte (0 before)
@   x.mrs_r15: `mrs pc, spsr` in SVC mode. Bits 0-7 markers (1, 2, 4:
@       A+4, A+8, A+12 ran; 0x10 came back through the BIOS's handler;
@       0x20 the watchdog took it out); bits 8-15 the CPSR's low byte
@       where it came out (0 if nowhere), 16-23 the interrupted CPSR's
@       low byte as the watchdog found it, 24-31 the CPSR's flags byte

    .include "sst.inc"
    sst_entry cells, NCELLS

@ ---------------------------------------------------------------- CP14
@ r4 = A. R14_und and SPSR_und cleared, watchdog armed, System mode with
@ I clear; then the instruction at A.
cp_setup:
    mov r7, lr
    msr cpsr_c, #0xDB
    mov lr, #0
    msr spsr_cxsf, #0
    msr cpsr_c, #0xDF
    adr r0, cp_trapped
    bl  wd_arm
    ldr r0, =0x5EE5EE5E
    msr cpsr_c, #0x1F
    msr cpsr_f, #0
    bx  r7

cp_done:                                      @ came through: r0 is the answer
    msr cpsr_c, #0xDF
    mov r5, r0
    bl  wd_disarm
    mov r0, r5
    b   finish

cp_trapped:                                   @ the watchdog: read R14_und
    msr cpsr_c, #0xDB
    mov r1, lr
    msr cpsr_c, #0xDF
    sub r1, r1, r4
    mov r1, r1, lsl #16
    ldr r0, =0x7A700000
    orr r0, r0, r1, lsr #16
    b   finish

    .macro CPMRC name, word, tag
\name:
    adr r4, 1f
    bl  cp_setup
1:  .word \word
    b   cp_done
    .word \tag                                @ A+8: the prefetched opcode
    .endm
    CPMRC x_mrc14_c0, 0xEE100E10, 0xC0DE1400  @ mrc p14, 0, r0, c0, c0, 0
    CPMRC x_mrc14_c1, 0xEE110E10, 0xC0DE1401  @ mrc p14, 0, r0, c1, c0, 0
    CPMRC x_mrc14_c2, 0xEE120E10, 0xC0DE1402  @ mrc p14, 0, r0, c2, c0, 0

x_mcr14_c1:
    adr r4, 1f
    bl  cp_setup
1:  .word 0xEE010E10                          @ mcr p14, 0, r0, c1, c0, 0
    mov r0, #0x14
    b   cp_done

x_mrc14_r15:
    adr r4, 1f
    bl  cp_setup
1:  .word 0xEE10FE10                          @ mrc p14, 0, r15, c0, c0, 0
    b   2f
    .word 0xA0DE14F0
2:  mrs r1, cpsr
    and r0, r1, #0xFF
    and r1, r1, #0xFF000000
    orr r0, r0, r1
    b   cp_done

@ ---------------------------------------------------------------- Thumb DExx
x_thumb_dexx:
    msr cpsr_c, #0xDB
    mov lr, #0
    msr spsr_cxsf, #0
    msr cpsr_c, #0xDF
    adr r0, dx_wd
    bl  wd_arm
    adr r5, dx_trap
    adr r2, dx_fall
    adr r3, dx_branch
    adr r12, dx_blk + 3                       @ A = dx_blk + 2, Thumb
    msr cpsr_c, #0x1F                         @ System, I clear
    msr cpsr_f, #0x60000000
    bx  r12
    .thumb
    .balign 4
dx_blk:
    .hword 0x4728                             @ A-2: bx r5 (where a trap returns)
    .hword 0xDE02                             @ A: cond 1110, offset 2 -> A+8
    .hword 0x4710                             @ A+2: bx r2
    .hword 0x4710
    .hword 0x4710
    .hword 0x4718                             @ A+8: bx r3
    .hword 0x4718
    .hword 0x4718
    .arm
    .balign 4
dx_branch:
    MK  1
    b   dx_done
dx_fall:
    MK  2
    b   dx_done
dx_trap:
    MK  4
dx_done:
    msr cpsr_c, #0xDF
    bl  wd_disarm
    b   dx_out
dx_wd:
    MK  8
dx_out:
    msr cpsr_c, #0xDB
    mov r1, lr
    mrs r2, spsr
    msr cpsr_c, #0xDF
    adr r3, dx_blk + 2
    cmp r1, #0
    subne r1, r1, r3
    and r1, r1, #0xFF
    orr r0, r6, r1, lsl #8
    and r1, r2, #0xFF
    orr r0, r0, r1, lsl #16
    and r1, r2, #0xFF000000
    orr r0, r0, r1
    b   finish

@ ---------------------------------------------------------------- MRS r15
x_mrs_r15:
    mov r7, #0
    adr r0, mr_wd
    bl  wd_arm
    msr cpsr_c, #0xD3                         @ SVC, I and F set
    adr lr, mr_bios + 4                       @ the handler's SUBS PC, LR, #4
    mov r1, #0x10                             @ SPSR_svc: User, I clear, no flags
    msr spsr_cxsf, r1
1:  .word 0xE14FF000                          @ A: mrs pc, spsr
    MK  1
    MK  2
    MK  4
    mrs r7, cpsr                              @ fell through: still SVC
    msr cpsr_c, #0xDF
    bl  wd_disarm
    b   mr_out
mr_bios:                                      @ the BIOS handler came back: User mode
    MK  0x10
    mrs r7, cpsr
    b   .                                     @ until the watchdog
mr_wd:
    MK  0x20
mr_out:
    and r0, r7, #0xFF
    orr r0, r6, r0, lsl #8
    ldr r1, =vars
    ldr r1, [r1, #V_WDSPSR]
    and r1, r1, #0xFF
    orr r0, r0, r1, lsl #16
    and r1, r7, #0xFF000000
    orr r0, r0, r1
    b   finish

    .ltorg
    sst_frame

@ the order is tools/hwlink/sst.py's RISK_CELLS
    .align 2
cells:
    .word x_mrc14_c0, x_mrc14_c1, x_mrc14_c2, x_mcr14_c1, x_mrc14_r15
    .word x_thumb_dexx
    .word x_mrs_r15
cells_end:
.equ NCELLS, (cells_end - cells) / 4

    sst_vars
