@ payload: where ARM execution resumes after a Thumb `cmp pc, r0` at a
@ halfword boundary restores a T-clear SPSR (gbaedge THUMBPC3 row (c), built
@ and never run; dbsuite cpu/thumb-cmp-pc-halfword-*).
@
@ Row (a) on an AGB SP (session 4): CPSR = the SPSR (0x80000012), the
@ breadcrumb store at W never ran and the `add` at W+8 never ran, and the
@ block escaped cleanly through `bx r5`. That leaves: ARM resumed at A+10 or
@ A+14 (both `bx r5` in (a)), or the halfword already decoded behind the
@ compare, W+4 = Thumb `bx r5`, ran as Thumb. The ladder below splits them:
@
@   W+0   .hword 0x4000  } ARM word 0x45874000 = strmi r4, [r7]
@   W+2   .hword 0x4587  } Thumb cmp pc, r0 -- the entry, A
@   W+4   .hword 0x4728  } Thumb bx r5; ARM word 0xE3874728 =
@   W+6   .hword 0xE387  }   orr r4, r7, #0xA00000
@   W+8   add r6, r6, #1    (A+6)
@   W+12  add r6, r6, #2    (A+10)
@   W+16  add r6, r6, #4    (A+14)
@   W+20  bx r2             (A+18)
@   W+24  bx r2
@
@ Thumb `bx r5` escapes to rec; every ARM path ends in `bx r2`, to rec_arm,
@ which sets bit 10 -- so an ARM resume at A+18 and the Thumb halfword
@ running are told apart too.
@
@ answer: bits 0..7 r6 (7: resumed at W+4 or W+8 -- r4 says which; 6: W+12;
@ 4: W+16; 0: W+20 or the Thumb bx r5), bit 8 r4 changed (the orr at W+4
@ ran), bit 9 the breadcrumb at W was stored, bit 10 left through an ARM
@ `bx r2`, bits 16..23 CPSR's low byte and bits 24..31 its flags byte as
@ the escape found it.
@
@ r0 = 1 runs a second block whose W+4 halfword does not branch: Thumb
@ `movs r6, #0x20` (0x2620) with Thumb `bx r5` (0x4728) at W+6, so the ARM
@ word at W+4 is 0x47282620 = strmi r2, [r8, -r0, lsl #12]! -- a second
@ breadcrumb (bit 11) into SCRATCHW + 4. Kept: Thumb on at A+4 (r6 = 0x20,
@ out through bx r5); ARM after the Thumb halfword at W+8 / W+12 / W+16 /
@ W+20 (r6 = 0x27 / 0x26 / 0x24 / 0x20 and bit 10; the movs clears N, so
@ the W+4 strmi cannot run after it); ARM with no Thumb halfword at W+4
@ (breadcrumb 2 and r6 = 7).
@ IME is off throughout; the block runs in IRQ mode with I clear, as (a) did.
    .arm
    .text
    .global _start
.equ SCRATCHW, 0x02008100
_start:
    stmfd sp!, {r4-r11, lr}
    mov r3, #0x04000000
    add r3, r3, #0x200
    ldrh r11, [r3, #8]             @ IME, restored after
    mov r8, r0
    mov r0, #0
    strh r0, [r3, #8]
    ldr r7, =SCRATCHW
    str r0, [r7]
    str r0, [r7, #4]
    adr r12, blk + 3               @ W+2, Thumb
    cmp r8, #0
    adrne r12, blk2 + 3
    add r8, r7, #4                 @ breadcrumb 2
    mrs r9, cpsr
    msr cpsr_c, #0x12              @ IRQ mode, I clear
    ldr r1, =0x80000012            @ SPSR: N, T clear, IRQ mode, I clear
    msr spsr_cxsf, r1
    ldr r4, =0xC0DEC0DE
    mov r6, #0
    mov r0, #0
    adr r5, rec
    adr r2, rec_arm
    bx  r12
rec_arm:
    orr r6, r6, #0x400
rec:
    mrs r10, cpsr
    msr cpsr_cxsf, r9
    mov r3, #0x04000000
    add r3, r3, #0x200
    strh r11, [r3, #8]
    ldr r1, =0x4FF
    and r0, r6, r1
    ldr r1, =0xC0DEC0DE
    cmp r4, r1
    orrne r0, r0, #0x100
    ldr r1, [r7]
    cmp r1, #0
    orrne r0, r0, #0x200
    ldr r1, [r7, #4]
    cmp r1, #0
    orrne r0, r0, #0x800
    and r1, r10, #0xFF
    orr r0, r0, r1, lsl #16
    mov r1, r10, lsr #24
    orr r0, r0, r1, lsl #24
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg
    .align 3
blk:
    .hword 0x4000
    .hword 0x4587
    .hword 0x4728
    .hword 0xE387
    .word 0xE2866001
    .word 0xE2866002
    .word 0xE2866004
    .word 0xE12FFF12
    .word 0xE12FFF12
    .align 3
blk2:
    .hword 0x4000
    .hword 0x4587
    .hword 0x2620
    .hword 0x4728
    .word 0xE2866001
    .word 0xE2866002
    .word 0xE2866004
    .word 0xE12FFF12
    .word 0xE12FFF12
