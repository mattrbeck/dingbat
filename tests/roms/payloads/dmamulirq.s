@ payload: a timer interrupt raised as an immediate DMA takes the bus, with
@ the CPU in multiply internal cycles (variant 0), in EWRAM loads (1), or
@ with no DMA at all (2, the multiplies alone).
@
@ TM0 (/1, IRQ) starts with reload R, TM1 (/1) a cycle later, and the next
@ store arms DMA0 (8 words EWRAM -> EWRAM, 32-bit). The handler reads TM1
@ first thing, then the interrupted address. On an AGB SP (tools/hwlink,
@ 2026-09-24), sweeping the raise one cycle at a time across the burst's
@ start: the synchroniser keeps counting through the internal cycles the
@ CPU runs under the burst (the multiply it was granted in, a load's last
@ cycle), so an interrupt due before those end is taken after that
@ instruction; one due later waits for the burst's end and is taken one
@ instruction later. dingbat took the first kind late for raises in the
@ two cycles before the grant (it held back every recognition due after the
@ grant) and, in loads, one cycle early at the edge.
@
@ r0 bits 0..15 R, bits 16..17 variant
@ answer: bits 0..15  TM1 at handler entry
@         bits 16..23 handler entries
@         bits 24..31 the interrupted address (lr_irq - 4), bits 2..9
    .arm
    .text
    .global _start
.equ SRC, 0x02010000
.equ DST, 0x02010100
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
    str r2, [r12, #24]             @ vector
    mrs r2, cpsr
    str r2, [r12, #28]
    mov r0, #0
    strh r0, [r5, #8]              @ IME off
    adr r2, handler
    str r2, [r1]
    str r0, [r12]
    str r0, [r12, #4]
    str r0, [r12, #8]
    add r1, r4, #0x100
    mov r2, #0x00800000
    str r2, [r1]                   @ TM0 from 0, stopped (count reset)
    str r0, [r1]
    str r0, [r1, #4]
    strh r0, [r4, #0xBA]           @ DMA0 off
    ldr r2, =SRC
    str r2, [r4, #0xB0]
    ldr r2, =DST
    str r2, [r4, #0xB4]
    mov r2, #8
    strh r2, [r4, #0xB8]
    mov r0, #0x08
    strh r0, [r5]                  @ IE: TM0
    mvn r0, #0
    strh r0, [r5, #2]
    mrs r0, cpsr
    bic r0, r0, #0x80
    msr cpsr_c, r0
    mov r0, #1
    strh r0, [r5, #8]              @ IME
    mov r7, r9, lsl #16
    mov r7, r7, lsr #16
    orr r7, r7, #0x00C00000        @ TM0: reload, /1, IRQ, on
    mov r8, #0x00800000            @ TM1: /1, on
    mov r10, #0x8400               @ DMA0: on, 32-bit, immediate
    ldr r2, =0x55555555
    ldr r6, =SRC
    add r1, r4, #0x100
    and r0, r9, #0x30000
    ldr r11, =bodies
    ldr r11, [r11, r0, lsr #14]
    mov lr, pc
    bx r11
    mov r0, #0x100
3:  subs r0, r0, #1
    bne 3b
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
    ldr r0, [r12]
    mov r0, r0, lsl #16
    mov r0, r0, lsr #16
    ldr r1, [r12, #4]
    and r1, r1, #0xFF
    orr r0, r0, r1, lsl #16
    ldr r1, [r12, #8]
    mov r1, r1, lsr #2
    and r1, r1, #0xFF
    orr r0, r0, r1, lsl #24
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
bodies:
    .word b_mul, b_ldr, b_nodma, b_mul

    .align 2
b_mul:
    stmia r1, {r7, r8}             @ TM0, then TM1
    strh r10, [r4, #0xBA]          @ DMA0
    .rept 12
    mul r3, r2, r2
    .endr
    .rept 32
    mov r0, r0
    .endr
    bx lr
b_ldr:
    stmia r1, {r7, r8}
    strh r10, [r4, #0xBA]
    .rept 24
    ldr r3, [r6]
    .endr
    .rept 32
    mov r0, r0
    .endr
    bx lr
b_nodma:
    stmia r1, {r7, r8}
    strh r10, [r12, #12]           @ no DMA: a store to IWRAM instead
    .rept 12
    mul r3, r2, r2
    .endr
    .rept 32
    mov r0, r0
    .endr
    bx lr

@ Called by the BIOS's dispatcher (IRQ mode, sp = IRQ stack holding r0-r3,
@ r12, lr_irq).
handler:
    mov r0, #0x04000000
    add r0, r0, #0x100
    ldrh r3, [r0, #4]              @ TM1, first thing
    mov r2, #0
    strh r2, [r0, #2]              @ TM0 off
    sub r0, r0, #0x100
    ldr r2, =vars
    ldr r1, [r2, #4]
    cmp r1, #0
    streq r3, [r2]
    ldreq r3, [sp, #20]
    subeq r3, r3, #4
    streq r3, [r2, #8]
    add r1, r1, #1
    str r1, [r2, #4]
    add r0, r0, #0x200
    mov r1, #0x08
    strh r1, [r0, #2]
    bx lr
    .ltorg
    .align 2
vars:
    .space 32
