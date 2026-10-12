@ sst.inc: the frame the SingleStepTests probes (sst.s, sstrisk.s) share.
@
@ A cell is one numbered routine; r0 on entry is its number, and its answer
@ comes back in r0 (tools/hwlink/sst.py names them). Linked and loaded at
@ 0x03000000 like every monitor payload, so labels are absolute addresses.
@
@ Cells change mode freely, so the frame saves every banked register and
@ every SPSR on entry and puts them back on the way out, with IME, IE, the
@ timers and the IRQ vector at 0x03007FFC. A cell ends with `b finish`,
@ r0 = its answer, from any privileged mode.
@
@ The watchdog. A cell that may not come back by itself (User mode has no
@ way out but an exception; an undefined instruction whose handler returns
@ to it again) arms TM3 to raise an interrupt 16384 cycles later, with
@ IME set and IE = TM3, and runs with CPSR.I clear. The BIOS dispatches the
@ interrupt to wd_handler, which records the interrupted CPSR and return
@ address and continues at the cell's continuation in System mode. Every
@ register but r0-r3 and r12 survives (the BIOS stacks those; the handler
@ uses them). The banked registers it disturbs are put back by `finish`.
@
@ Scratch: IWRAM 0x03006000-0x03006FFF, EWRAM 0x02030000-0x02030FFF, and a
@ System-mode stack at 0x03007C00. The payload itself stays below 0x03006000.

.equ SCR_IW,  0x03006400
.equ SCR_EW,  0x02030400
.equ STK,     0x03007C00
.equ IRQVEC,  0x03007FFC
.equ WD_CYC,  0x4000

@ vars layout
.equ V_ARG,    0
.equ V_SP,     4          @ the caller's sp after the entry push
.equ V_CPSR,   8          @ the caller's CPSR
.equ V_SPUSR,  12         @ User/System sp and lr as found
.equ V_LRUSR,  16
.equ V_IME,    20
.equ V_IE,     24
.equ V_IRQV,   28
.equ V_RES,    32
.equ V_WDCONT, 36
.equ V_WDHIT,  40
.equ V_WDSPSR, 44
.equ V_WDLR,   48
.equ V_BANKS,  64         @ fiq r8-r14 + spsr (8), irq/svc/abt/und r13 r14 spsr (3 each)

    @ `orr r6, r6, #n`: a breadcrumb. Its encoding is 0xE3866000 | n, which
    @ the r15-as-base cells read back to tell which word they loaded.
    .macro MK n
    orr r6, r6, #\n
    .endm

    .macro sst_entry table, count
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str r0, [r12, #V_ARG]
    str sp, [r12, #V_SP]
    mrs r1, cpsr
    str r1, [r12, #V_CPSR]
    msr cpsr_c, #0xDF              @ System, I and F set
    str sp, [r12, #V_SPUSR]
    str lr, [r12, #V_LRUSR]
    ldr sp, =STK
    bl  save_banks
    ldr r12, =vars                 @ again: a core that mis-banks r8-r12 keeps going
    mov r4, #0x04000000
    add r5, r4, #0x200
    ldrh r1, [r5, #8]
    str r1, [r12, #V_IME]
    ldrh r1, [r5]
    str r1, [r12, #V_IE]
    ldr r2, =IRQVEC
    ldr r1, [r2]
    str r1, [r12, #V_IRQV]
    mov r0, #0
    strh r0, [r5, #8]              @ IME off
    str r0, [r12, #V_WDHIT]
    bl  timers_off
    mov r6, #0
    ldr r0, [r12, #V_ARG]
    cmp r0, #\count
    bhs cell_bad
    ldr r1, =\table
    ldr pc, [r1, r0, lsl #2]
    .endm

    .macro sst_frame
cell_bad:
    ldr r0, =0xBAD0BAD0
    @ fall into finish

finish:
    msr cpsr_c, #0xDF
    ldr r12, =vars
    str r0, [r12, #V_RES]
    bl  timers_off
    mov r4, #0x04000000
    add r5, r4, #0x200
    ldr r1, [r12, #V_IE]
    strh r1, [r5]
    ldr r1, =0xFFFF
    strh r1, [r5, #2]              @ acknowledge what the cell raised
    ldr r2, =IRQVEC
    ldr r1, [r12, #V_IRQV]
    str r1, [r2]
    ldr r1, [r12, #V_IME]
    strh r1, [r5, #8]
    bl  restore_banks
    ldr r12, =vars
    ldr sp, [r12, #V_SPUSR]
    ldr lr, [r12, #V_LRUSR]
    ldr r0, [r12, #V_RES]
    ldr r1, [r12, #V_CPSR]
    ldr r2, [r12, #V_SP]
    msr cpsr_cxsf, r1
    mov sp, r2
    ldmfd sp!, {r4-r11, lr}
    bx  lr

@ every timer stopped (TM0-TM3); clobbers r1, r2
timers_off:
    ldr r1, =0x04000100
    mov r2, #0
    str r2, [r1]
    str r2, [r1, #4]
    str r2, [r1, #8]
    str r2, [r1, #12]
    bx  lr

@ System mode in and out; r12 = vars; clobbers r0, r1
save_banks:
    add r0, r12, #V_BANKS
    msr cpsr_c, #0xD1
    stmia r0!, {r8-r14}
    mrs r1, spsr
    str r1, [r0], #4
    msr cpsr_c, #0xD2
    stmia r0!, {r13, r14}
    mrs r1, spsr
    str r1, [r0], #4
    msr cpsr_c, #0xD3
    stmia r0!, {r13, r14}
    mrs r1, spsr
    str r1, [r0], #4
    msr cpsr_c, #0xD7
    stmia r0!, {r13, r14}
    mrs r1, spsr
    str r1, [r0], #4
    msr cpsr_c, #0xDB
    stmia r0!, {r13, r14}
    mrs r1, spsr
    str r1, [r0], #4
    msr cpsr_c, #0xDF
    bx  lr

restore_banks:
    add r0, r12, #V_BANKS
    msr cpsr_c, #0xD1
    ldmia r0!, {r8-r14}
    ldr r1, [r0], #4
    msr spsr_cxsf, r1
    msr cpsr_c, #0xD2
    ldmia r0!, {r13, r14}
    ldr r1, [r0], #4
    msr spsr_cxsf, r1
    msr cpsr_c, #0xD3
    ldmia r0!, {r13, r14}
    ldr r1, [r0], #4
    msr spsr_cxsf, r1
    msr cpsr_c, #0xD7
    ldmia r0!, {r13, r14}
    ldr r1, [r0], #4
    msr spsr_cxsf, r1
    msr cpsr_c, #0xDB
    ldmia r0!, {r13, r14}
    ldr r1, [r0], #4
    msr spsr_cxsf, r1
    msr cpsr_c, #0xDF
    bx  lr

@ r0 = where to continue if it fires (System mode). Leaves CPSR alone: the
@ cell clears I in the mode it tests. Clobbers r1-r3.
wd_arm:
    ldr r1, =vars
    str r0, [r1, #V_WDCONT]
    mov r2, #0
    str r2, [r1, #V_WDHIT]
    str r2, [r1, #V_WDSPSR]
    str r2, [r1, #V_WDLR]
    ldr r2, =wd_handler
    ldr r3, =IRQVEC
    str r2, [r3]
    mov r3, #0x04000000
    add r3, r3, #0x200
    mov r2, #0x40
    strh r2, [r3]                  @ IE: TM3
    ldr r2, =0xFFFF
    strh r2, [r3, #2]
    ldr r1, =0x0400010C
    mov r2, #0
    str r2, [r1]
    ldr r2, =(0x00C00000 | (0x10000 - WD_CYC))
    str r2, [r1]                   @ TM3: prescaler 1, IRQ, running
    mov r2, #1
    strh r2, [r3, #8]              @ IME
    bx  lr

@ clobbers r1, r2
wd_disarm:
    mov r1, #0x04000000
    add r1, r1, #0x200
    mov r2, #0
    strh r2, [r1, #8]              @ IME off
    mov r2, #0x40
    strh r2, [r1, #2]              @ IF: TM3
    ldr r1, =0x0400010C
    mov r2, #0
    str r2, [r1]                   @ TM3 stopped
    bx  lr

@ IRQ mode, called by the BIOS's dispatcher (which stacked r0-r3, r12, lr)
wd_handler:
    mov r0, #0x04000000
    add r0, r0, #0x200
    mov r1, #0
    strh r1, [r0, #8]
    ldr r2, =0x0400010C
    str r1, [r2]
    mov r1, #0x40
    strh r1, [r0, #2]
    ldr r0, =vars
    mrs r1, spsr
    str r1, [r0, #V_WDSPSR]
    ldr r1, [sp, #20]
    str r1, [r0, #V_WDLR]
    mov r1, #1
    str r1, [r0, #V_WDHIT]
    ldr r1, [r0, #V_WDCONT]
    msr cpsr_c, #0xDF
    bx  r1
    .ltorg
    .endm

    .macro sst_vars
    .align 2
vars:
    .space 128
    .endm
