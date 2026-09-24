@ ldmglitch1.s -- dbsuite copy of the link-rig payload the parent session ran
@ on the AGB SP on 2026-09-24 (00:36 UTC) as tmp/pl/ldmglitch.s; the code
@ below is that file unchanged.
@
@ WHAT: the LDM^ glitch.  After an LDM that loads the user bank (S bit, no
@ r15 in the list) from a mode with banked registers, the NEXT instruction's
@ first-cycle reads of banked registers return banked OR user.
@ WHY: an emulator that models LDM^ as a clean user-bank load gets 9669
@ where the console gets FD02 (alyosha-tas/gba-tests LDM/* pin the same
@ glitch).
@ PROVENANCE: AGB SP (AGS-001) via tools/hwlink (payloadcmp.on_hardware),
@ 2026-09-24, run twice with identical answers:
@   arg 0  ldm {r8,r9}^ ; add r2,r8,r9       -> 0000FD02 (OR'd: 36C9+C639)
@   arg 1  one nop between                   -> 00009669 (no glitch)
@   arg 2  ldm {r8,r9}^ ; mul r2,r8,r9       -> 2A6BA8C1 (36C9 * C639)
@   arg 3  (reads the caller's user r9: not deterministic, not used)
@   arg 4  two nops between                  -> 00009669

@ LDM^ in FIQ mode: user r8/r9 loaded from memory while FIQ's banked r8/r9
@ hold other values; the instruction after reads r8/r9.
@ r0: 0 add r2,r8,r9 right after; 1 one nop between; 2 mul r2,r8,r9 right
@ after; 3 ldm {r8}^ only, then add; 4 add r2,r8,r9 two nops after
@ answer: r2. No-glitch: 0x1248+0x8421 = 0x9669 (mul 0x09B1A088... low
@ word); OR'd reads: 0x36C9+0xC639 = 0xFD02.
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r7, r0
    mrs r6, cpsr
    adr r1, user_data
    mov r0, #0xD1                  @ FIQ, IRQ+FIQ masked
    msr cpsr_c, r0
    ldr r8, =0x1248
    ldr r9, =0x8421
    cmp r7, #1
    beq v1
    cmp r7, #2
    beq v2
    cmp r7, #3
    beq v3
    cmp r7, #4
    beq v4
v0: ldmia r1, {r8, r9}^
    add r2, r8, r9
    b done
v1: ldmia r1, {r8, r9}^
    mov r0, r0
    add r2, r8, r9
    b done
v2: ldmia r1, {r8, r9}^
    mul r2, r8, r9
    b done
v3: ldmia r1, {r8}^
    add r2, r8, r9
    b done
v4: ldmia r1, {r8, r9}^
    mov r0, r0
    mov r0, r0
    add r2, r8, r9
done:
    msr cpsr_c, r6
    mov r0, r2
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
    .align 2
user_data:
    .word 0x2481, 0x4218
