@ ldmglitch3.s -- dbsuite copy of tmp/pl/ldmglitch3.s, unchanged, run on
@ the AGB SP on 2026-09-24 (00:40 UTC).
@
@ WHAT: which reads the LDM^ glitch reaches, and what does not trigger it.
@ PROVENANCE: AGB SP via tools/hwlink, 2026-09-24:
@   arg 0  ldm {r2}^ (low reg only), add r2,r8,r9  -> 0000FD02 (still OR'd)
@   arg 1  stm {r8}^, add                          -> 00009669 (STM^: none)
@   arg 2  plain ldm {r8,r9} (no ^), add           -> 00001100 (none)
@   arg 3  ldm^, str r8 -> the stored word         -> 00001248 (store data
@          is not OR'd)
@   arg 4  ldm {r8,r9}^, add (reference)           -> 0000FD02

@ FIQ mode, IWRAM. User r8/r9 first set to 0x2481/0x4218 by an ldm^ that
@ is allowed to expire (two nops); banked r8/r9 = 0x1248/0x8421. Then:
@ r0=0: ldm {r2}^ (low register only), add r2,r8,r9
@    1: stm {r8}^ to scratch, add r2,r8,r9
@    2: ldm {r8,r9} without ^ (loads banked 0x2481/0x4218... from data+8), add
@    3: ldm {r8,r9}^, str r8,[r1,#16] -> answer the stored word
@    4: ldm {r8,r9}^, add r2,r8,r9 (reference)
@ answer r2
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r7, r0
    mrs r6, cpsr
    adr r1, data
    mov r0, #0xD1
    msr cpsr_c, r0
    ldmia r1, {r8, r9}^
    mov r0, r0
    mov r0, r0
    ldr r8, =0x1248
    ldr r9, =0x8421
    cmp r7, #0
    beq v0
    cmp r7, #1
    beq v1
    cmp r7, #2
    beq v2
    cmp r7, #3
    beq v3
v4: ldmia r1, {r8, r9}^
    add r2, r8, r9
    b done
v0: ldmia r1, {r2}^
    add r2, r8, r9
    b done
v1: add r3, r1, #32
    stmia r3, {r8}^
    add r2, r8, r9
    b done
v2: add r3, r1, #8
    ldmia r3, {r8, r9}
    add r2, r8, r9
    b done
v3: ldmia r1, {r8, r9}^
    str r8, [r1, #16]
    mov r0, r0
    ldr r2, [r1, #16]
done:
    msr cpsr_c, r6
    mov r0, r2
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
    .align 2
data:
    .word 0x2481, 0x4218, 0x1000, 0x0100, 0, 0, 0, 0
    .word 0, 0, 0, 0
