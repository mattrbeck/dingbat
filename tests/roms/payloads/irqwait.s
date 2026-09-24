@ payload: do the CPU's wait states hold off an interrupt?
@
@ A TM0 overflow k cycles after its start interrupts a NOP sled; the handler
@ reads TM1 (started one cycle after TM0) first thing and records where the
@ sled was interrupted. The sled runs from IWRAM (one-cycle fetches) or
@ from EWRAM (ARM fetch 6 cycles, Thumb 3). On an AGB SP (tools/hwlink,
@ 2026-09-24) the IWRAM cells matched dingbat as it was; from EWRAM the
@ interrupt came one NOP later at every phase -- recognised during a
@ fetch's wait states, it waits for the next instruction (IRQ_LAST_WAITS)
@ -- and the entry itself cost 5 (ARM) or 2 (Thumb) more: the in-flight
@ fetch, as from the cartridge (cpu.irq_enter).
@
@ r0 bits 0..7 k (>= 8), bit 8: sled in EWRAM, bit 9: Thumb sled
@ answer: bits 0..15 TM1 at entry, bits 16..23 NOPs completed before it,
@         bits 24..31 entries
    .arm
    .text
    .global _start
.equ EWSLED, 0x02010000
_start:
    stmfd sp!, {r4-r11, lr}
    mov r9, r0
    mov r4, #0x04000000
    add r5, r4, #0x200
    ldr r12, =vars
    ldrh r1, [r5, #8]
    str r1, [r12, #16]             @ IME
    ldrh r1, [r5]
    str r1, [r12, #20]             @ IE
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #24]
    mrs r2, cpsr
    str r2, [r12, #28]
    mov r0, #0
    strh r0, [r5, #8]              @ IME off
    ldr r2, =handler
    str r2, [r1]
    str r0, [r12]
    str r0, [r12, #4]
    str r0, [r12, #8]
    add r1, r4, #0x100
    str r0, [r1]                   @ TM0 off
    str r0, [r1, #4]               @ TM1 off
    @ pick the sled, copying it to EWRAM if asked
    tst r9, #0x200
    ldreq r6, =sled_arm
    ldrne r6, =sled_thumb
    ldreq r7, =sled_arm_end
    ldrne r7, =sled_thumb_end
    tst r9, #0x100
    beq 2f
    ldr r2, =EWSLED
1:  ldr r3, [r6], #4
    str r3, [r2], #4
    cmp r6, r7
    blt 1b
    ldr r6, =EWSLED
2:  str r6, [r12, #12]             @ sled start
    mov r0, #0x08
    strh r0, [r5]                  @ IE: TM0
    mvn r0, #0
    strh r0, [r5, #2]
    mrs r0, cpsr
    bic r0, r0, #0x80
    msr cpsr_c, r0
    mov r0, #1
    strh r0, [r5, #8]              @ IME
    and r0, r9, #0xFF
    rsb r7, r0, #0x10000
    orr r7, r7, #0x00C00000        @ TM0: reload, /1, IRQ, on
    mov r8, #0x00800000            @ TM1: /1, on
    add r1, r4, #0x100
    tst r9, #0x200
    orrne r6, r6, #1               @ Thumb entry
    mov lr, pc
    b go
    @ back from the sled
    mov r0, #0
    strh r0, [r5, #8]
    add r1, r4, #0x100
    str r0, [r1]
    str r0, [r1, #4]
    ldr r1, [r12, #20]
    strh r1, [r5]
    mvn r1, #0
    strh r1, [r5, #2]
    ldr r1, [r12, #24]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #28]
    msr cpsr_c, r1
    ldr r1, [r12, #16]
    strh r1, [r5, #8]
    ldr r0, [r12]                  @ TM1
    mov r0, r0, lsl #16
    mov r0, r0, lsr #16
    ldr r1, [r12, #8]              @ interrupted address
    ldr r2, [r12, #12]
    sub r1, r1, r2
    tst r9, #0x200
    movne r1, r1, lsr #1
    moveq r1, r1, lsr #2
    and r1, r1, #0xFF
    orr r0, r0, r1, lsl #16
    ldr r1, [r12, #4]
    and r1, r1, #0xFF
    orr r0, r0, r1, lsl #24
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
go:
    stmia r1, {r7, r8}             @ TM0, then TM1
    bx r6
    .align 2
sled_arm:
    .rept 48
    mov r0, r0
    .endr
    bx lr
sled_arm_end:
    .thumb
    .align 2
sled_thumb:
    .rept 64
    mov r8, r8
    .endr
    bx lr
    .align 2
sled_thumb_end:
    .arm
@ Called by the BIOS dispatcher (IRQ mode; lr_irq at [sp, #20]).
handler:
    mov r0, #0x04000000
    add r0, r0, #0x100
    ldrh r3, [r0, #4]              @ TM1, first thing
    mov r1, #0
    strh r1, [r0, #2]              @ TM0 off
    ldr r2, =vars
    ldr r1, [r2, #4]
    cmp r1, #0
    streq r3, [r2]
    ldreq r3, [sp, #20]
    subeq r3, r3, #4
    streq r3, [r2, #8]
    add r1, r1, #1
    str r1, [r2, #4]
    mov r0, #0x04000000
    add r0, r0, #0x200
    mov r1, #0x08
    strh r1, [r0, #2]
    bx lr
    .ltorg
    .align 2
vars:
    .space 32
