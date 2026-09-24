@ ldmglitch2.s -- dbsuite copy of the link-rig payload tmp/pl/ldmglitch2.s
@ the parent session ran on the AGB SP on 2026-09-24 (00:39 UTC).  Changed
@ from that file: the EWRAM copy lives at 0x0200C000 instead of 0x02030000
@ (which is dbsuite's multiboot code); the 64-byte-aligned block is the
@ same bytes.
@
@ WHAT: the LDM^ glitch does not depend on the memory the code runs from.
@ PROVENANCE: AGB SP via tools/hwlink, 2026-09-24:
@   arg 0 (block run from IWRAM) -> 0000FD02,  arg 1 (from EWRAM) -> 0000FD02
@ (args 2/3, the IRQ-mode block, were never run on the console.)

@ The LDM^ sequence run from IWRAM (r0 bit 0 = 0) or copied to EWRAM
@ 0x0200C000 (bit 0 = 1). Bit 1: IRQ mode, ldm {r13,r14}^ then add r2,r13,r14
@ (banked 0x1248/0x8421, user 0x2481/0x4218 loaded). answer r2.
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r7, r0
    adr r1, user_data
    adr r4, blk_fiq
    adr r5, blk_fiq_end
    tst r7, #2
    adrne r4, blk_irq
    adrne r5, blk_irq_end
    mov r10, r4
    tst r7, #1
    beq 2f
    ldr r10, =0x0200C000
    mov r3, r10
1:  ldr r2, [r4], #4
    str r2, [r3], #4
    cmp r4, r5
    blo 1b
2:  mov lr, pc
    bx r10
    mov r0, r2
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
    .align 2
user_data:
    .word 0x2481, 0x4218
@ r1 = data. Returns in r2; preserves r4-r11 of the caller's mode
blk_fiq:
    mrs r3, cpsr
    mov r0, #0xD1
    msr cpsr_c, r0
    mov r8, #0x1200
    orr r8, r8, #0x48
    mov r9, #0x8400
    orr r9, r9, #0x21
    ldmia r1, {r8, r9}^
    add r2, r8, r9
    msr cpsr_c, r3
    bx lr
blk_fiq_end:
blk_irq:
    mrs r3, cpsr
    mov r12, lr
    mov r0, #0xD2
    msr cpsr_c, r0
    mov r0, sp
    mov r7, lr
    mov sp, #0x1200
    orr sp, sp, #0x48
    mov lr, #0x8400
    orr lr, lr, #0x21
    ldmia r1, {r13, r14}^
    add r2, r13, r14
    mov sp, r0
    mov lr, r7
    msr cpsr_c, r3
    bx r12
blk_irq_end:
