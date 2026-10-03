@ payload: what an S-bit write to r15 does in System mode, which has no SPSR
@
@ WHY: Colin McRae Rally 2.0, TOCA World Touring Cars and Starsky & Hutch
@ link an ARM run-time library whose routines return with `movs pc, lr`,
@ called from System mode (docs/playtest-bugs.md, "movs pc, lr in System
@ mode"). The ARM ARM calls the form UNPREDICTABLE outside an exception
@ mode. dingbat restored a stale copy of another mode's SPSR there (a Thumb
@ one: the games then ran their ARM library as Thumb); it now restores the
@ CPSR -- the S bit changes nothing -- as MRS reads the CPSR in place of the
@ SPSR in User and System mode (alyosha psr). Both references play the
@ three games. This asks the console.
@
@ r0 bits 0..1  the instruction: 0 `movs pc, lr`; 1 `subs pc, lr, #0`;
@               2 `ldmfd sp!, {pc}^`
@    bit 4      first leave a Thumb SPSR in IRQ mode (0x8000003F: N, T,
@               System) and come back to System mode, so a core that keeps
@               one SPSR copy across modes carries a Thumb value into it
@ The flags are set to Z and C (0x6) before the write, I is set throughout.
@ The target is a pad that escapes as Thumb (`bx r5`, bit 9 clear) and as
@ ARM (bit 9 set): Thumb `bx r5` / `.hword 0xE1A0` is ARM `mov r4, r8, lsr
@ #14`, then `b rec_arm`.
@
@ answer: bits 0..7 the CPSR's low byte after the write, bits 24..31 its
@ flags byte, bit 9 set if execution went on as ARM.
@
@ PROVENANCE: dingbat (both BIOSes) and mgba agree on every cell: movs and
@ subs 0x2000029F (System, I set, ARM, and the flags the ALU result sets --
@ Z clear, C kept -- with nothing restored over them), ldm^ 0x6000029F (the
@ flags as they were). dingbat before the fix: 0x0000021F on every cell (a
@ stale SPSR with I clear restored). Console: not yet run.
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r8, r0
    mrs r9, cpsr                   @ the caller's mode, restored after
    mov r10, sp                    @ the caller's stack (banked away below)
    tst r8, #0x10
    beq 1f
    msr cpsr_c, #0x92              @ IRQ mode, I set
    ldr r1, =0x8000003F
    msr spsr_cxsf, r1
1:  msr cpsr_c, #0x9F              @ System mode, I set
    ldr sp, =0x03007E00            @ System stack, out of the monitor's way
    adr r5, rec                    @ the Thumb pad's escape (ARM, bit 0 clear)
    adr lr, pad
    mov r6, #0
    adr r1, pad
    stmfd sp!, {r1}                @ for the ldm form
    and r0, r8, #3
    adr r2, f_movs
    cmp r0, #1
    adreq r2, f_subs
    adrhi r2, f_ldm
    msr cpsr_f, #0x60000000        @ Z, C (after the compare)
    mov pc, r2
f_movs:
    movs pc, lr
f_subs:
    subs pc, lr, #0
f_ldm:
    ldmfd sp!, {pc}^
    .align 2
pad:
    .hword 0x4728                  @ Thumb: bx r5
    .hword 0xE1A0                  @ ARM: mov r4, r8, lsr #14
    b   rec_arm
rec_arm:
    orr r6, r6, #0x200
rec:
    mrs r7, cpsr
    msr cpsr_cxsf, r9
    mov sp, r10
    and r0, r7, #0xFF
    and r1, r7, #0xFF000000
    orr r0, r0, r1
    orr r0, r0, r6
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg
