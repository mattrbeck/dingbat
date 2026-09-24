@ ldmglitch4.s -- dbsuite copy of tmp/pl/ldmglitch4.s, unchanged, run on
@ the AGB SP on 2026-09-24 (01:51 UTC).
@
@ WHAT: the LDM^ glitch by operand class (see the variant list below).
@ PROVENANCE: AGB SP via tools/hwlink, 2026-09-24, args [0,1,2,3,5,4]:
@   0 add r2,r8,r9,lsl r10 -> 00000081 (Rs OR'd to 3, Rn/Rm not: 1 + (0x10 << 3))
@   1 umull                -> 0000005B (Rm and Rs OR'd: 7 * 13)
@   2 msr cpsr_f, r8       -> C0000000 (Rm OR'd: N and Z)
@   3 mla, Rs the only banked operand -> 0000000F (not OR'd)
@   5 control, a nop first -> 00000021
@   4 IRQ mode ldm {r13,r14}^ ; add r2,r13,r14 -> 0000FD02

@ LDM^ glitch, operand classes. FIQ mode unless noted; user r8-r10 set by an
@ ldm^ that expires (two nops) first. answer r2.
@ 0: add r2, r8, r9, lsl r10   banked 1/0x10/1, user 0x100/0x20/2
@ 1: umull r2, r3, r8, r9      banked 3/5, user 4/8 (answer lo)
@ 2: msr cpsr_f, r8 ; mrs      banked 0x40000000, user 0x80000000 (answer flags)
@ 3: mla r2, r0, r8, r1        r0=3 r1=0, banked r8=5 user r8=8
@ 4: IRQ mode: ldm {r13,r14}^ ; add r2, r13, r14 (banked 0x1248/0x8421,
@    user 0x2481/0x4218); the caller's user sp/lr are saved and restored
@ 5: control: variant 0 with a nop before the add
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r7, r0
    mrs r6, cpsr
    cmp r7, #4
    beq v4
    adr r1, data
    mov r0, #0xD1
    msr cpsr_c, r0
    cmp r7, #0
    adreq r4, set0
    cmp r7, #5
    adreq r4, set0
    cmp r7, #1
    adreq r4, set1
    cmp r7, #2
    adreq r4, set2
    cmp r7, #3
    adreq r4, set3
    add r3, r4, #12
    ldmia r3, {r8, r9, r10}^       @ user values
    mov r0, r0
    mov r0, r0
    ldmia r4, {r0, r2, r3}         @ the banked values, via low registers
    mov r8, r0
    mov r9, r2
    mov r10, r3
    mov r0, #3
    mov r1, #0
    cmp r7, #1
    beq v1
    cmp r7, #2
    beq v2
    cmp r7, #3
    beq v3
    cmp r7, #5
    beq v5
v0: ldmia r1, {r2}^
    add r2, r8, r9, lsl r10
    b done
v5: ldmia r1, {r2}^
    mov r0, r0
    add r2, r8, r9, lsl r10
    b done
v1: ldmia r1, {r2}^
    umull r2, r3, r8, r9
    b done
v2: mrs r5, cpsr
    ldmia r1, {r2}^
    msr cpsr_f, r8
    mrs r2, cpsr
    msr cpsr_f, r5
    and r2, r2, #0xF0000000
    b done
v3: ldmia r1, {r2}^
    mla r2, r0, r8, r1
    b done
done:
    msr cpsr_c, r6
    mov r0, r2
    ldmfd sp!, {r4-r11, lr}
    bx lr

v4: adr r1, irqdata
    adr r5, save
    mov r0, #0xD2
    msr cpsr_c, r0
    mov r3, sp
    mov r4, lr
    stmia r5, {r13, r14}^          @ the caller's user sp/lr
    mov r0, r0
    ldr sp, =0x1248
    ldr lr, =0x8421
    ldmia r1, {r13, r14}^
    add r2, r13, r14
    mov r0, r0
    mov r0, r0
    ldmia r5, {r13, r14}^          @ back
    mov r0, r0
    mov r0, r0
    mov sp, r3
    mov lr, r4
    msr cpsr_c, r6
    mov r0, r2
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
    .align 2
data:  .word 0, 0, 0, 0
@ each set: banked first (r8, r9, r10), then user
set0:  .word 1, 0x10, 1, 0x100, 0x20, 2
set1:  .word 3, 5, 0, 4, 8, 0
set2:  .word 0x40000000, 0, 0, 0x80000000, 0, 0
set3:  .word 5, 0, 0, 8, 0, 0
irqdata: .word 0x2481, 0x4218
save:  .word 0, 0
