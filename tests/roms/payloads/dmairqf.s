@ payload: a DMA's end-of-transfer interrupt when the burst's request lands
@ inside an opcode fetch with wait states.
@
@ gbaedge DMATIME row (d) (dbsuite dma/dmatime-completion-irq-after-resume)
@ runs this from the cartridge: the store arming DMA3 (16 words EWRAM ->
@ EWRAM, IRQ), then `ldrh r9, [TM0]` -- the CPU's resume stamp -- then an
@ EWRAM `ldr`, then a poll loop. The request lands two cycles after the
@ store, inside the ldrh's opcode fetch (N+S from the gamepak). The console
@ takes the interrupt one instruction later than dingbat (the handler's
@ stamp less the resume stamp: 0x6D against 0x5E). The same sequence, from
@ EWRAM (the fetch has wait states there too) and from IWRAM (none):
@
@   variant 0  body in EWRAM:  str TM1 on / strh DMA3 on / ldrh r9, [TM1] /
@              ldr r11, [EWRAM] / poll an IWRAM flag
@   variant 1  the same body in IWRAM
@   variant 2  EWRAM, with a `mov r0, r0` where the ldrh was (and r9 = 0)
@   variant 3  EWRAM, the ldrh but no EWRAM load after it (a nop)
@
@ AGB SP through tools/hwlink, 2026-09-25 (two passes a cell, agreeing;
@ recorded as the r0-agb.json family dmairqf with those two):
@   N=1/4/16, variant 0: 401A045 403E069 40CE0F9 -- entered after the EWRAM
@     `ldr` (address bits 0x04), the resume stamp as dingbat has it
@   variant 1 (IWRAM): 84002030 84002054 840020E4 -- as dingbat
@   variant 2 (no ldrh): 4000043 4000067 40000F7 -- as dingbat
@   variant 3 (ldrh, nop): 401A03E 403E062 40CE0F2 -- entered after the nop
@ dingbat (ae25841e) takes variants 0 and 3 one instruction early
@ (301A038 ...): it starts the burst inside the ldrh's 6-cycle fetch, so the
@ burst -- and its interrupt -- end three cycles before the console's. An
@ immediate DMA that waits for the whole fetch its request lands in
@ (IMM_FETCH_WAIT, measured on the console by its start: hadesdsd.s,
@ slotimm.s) gives all twelve cells; so does counting the synchroniser from
@ the fetch's end with the burst left where it was, which the DMA's own
@ timer reads rule out.
@
@ r0 bits 0..7 N (1..64 words), bits 8..9 variant
@ answer: bits 0..11 TM1 at the handler's first instruction, bits 12..23
@         the resume stamp (r9), bits 24..31 the interrupted address's
@         bits 2..9 (the body starts 256-byte aligned)
    .arm
    .text
    .global _start
.equ SRC, 0x02010000
.equ DST, 0x02010200
.equ EFLAG, 0x02010400
.equ EBODY, 0x02011000
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
    str r0, [r12, #12]             @ IWRAM flag
    ldr r1, =EFLAG
    str r0, [r1]
    add r1, r4, #0x100
    str r0, [r1, #4]               @ TM1 off
    strh r0, [r4, #0xDE]           @ DMA3 off
    ldr r2, =SRC
    str r2, [r4, #0xD4]
    ldr r2, =DST
    str r2, [r4, #0xD8]
    and r2, r9, #0xFF
    strh r2, [r4, #0xDC]
    @ copy the variant's body to EWRAM (variant 1 runs it where it is)
    and r0, r9, #0x300
    ldr r11, =bodies
    ldr r11, [r11, r0, lsr #6]
    and r0, r9, #0x300
    cmp r0, #0x100
    beq 2f
    ldr r1, =EBODY
    mov r2, #64
1:  ldr r3, [r11], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b
    ldr r11, =EBODY
2:  mov r0, #0x800
    strh r0, [r5]                  @ IE: DMA3
    mvn r0, #0
    strh r0, [r5, #2]
    mrs r0, cpsr
    bic r0, r0, #0x80
    msr cpsr_c, r0
    mov r0, #1
    strh r0, [r5, #8]              @ IME
    mov r8, #0x00800000            @ TM1 on
    ldr r10, =0xC400               @ DMA3: on, IRQ, 32-bit, immediate
    add r6, r12, #12               @ IWRAM flag
    ldr r7, =SRC                   @ an EWRAM word to load
    ldr r3, =0x00100000            @ watchdog
    mov r9, #0
    add r2, r4, #0x104             @ TM1 counter, for the stamp
    mov lr, pc
    bx r11
    mov r0, #0
    strh r0, [r5, #8]
    add r1, r4, #0x100
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
    ldr r1, =0xFFF
    and r0, r0, r1
    and r9, r9, r1
    orr r0, r0, r9, lsl #12
    ldr r1, [r12, #8]
    mov r1, r1, lsr #2
    and r1, r1, #0xFF
    orr r0, r0, r1, lsl #24
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
bodies:
    .word b_ld, b_ld, b_nold, b_nopld

    .align 8
b_ld:
    str r8, [r4, #0x104]           @ TM1 on
    strh r10, [r4, #0xDE]          @ DMA3 on
    ldrh r9, [r2]                  @ the resume stamp (TM1)
    ldr r11, [r7]                  @ an EWRAM load
1:  ldr r0, [r6]
    cmp r0, #0
    bne 2f
    subs r3, r3, #1
    bne 1b
2:  bx lr
    .align 8
b_nold:
    str r8, [r4, #0x104]
    strh r10, [r4, #0xDE]
    mov r0, r0
    ldr r11, [r7]
1:  ldr r0, [r6]
    cmp r0, #0
    bne 2f
    subs r3, r3, #1
    bne 1b
2:  bx lr
    .align 8
b_nopld:
    str r8, [r4, #0x104]
    strh r10, [r4, #0xDE]
    ldrh r9, [r2]
    mov r0, r0
1:  ldr r0, [r6]
    cmp r0, #0
    bne 2f
    subs r3, r3, #1
    bne 1b
2:  bx lr

@ Called by the BIOS's dispatcher (IRQ mode; lr_irq at [sp, #20]).
    .align 2
handler:
    mov r0, #0x04000000
    add r0, r0, #0x100
    ldrh r3, [r0, #4]              @ TM1, first thing
    ldr r2, =vars
    ldr r1, [r2, #4]
    cmp r1, #0
    streq r3, [r2]
    ldreq r3, [sp, #20]
    subeq r3, r3, #4
    streq r3, [r2, #8]
    add r1, r1, #1
    str r1, [r2, #4]
    mov r1, #1
    str r1, [r2, #12]              @ IWRAM flag
    ldr r3, =EFLAG
    str r1, [r3]
    mov r0, #0x04000000
    add r0, r0, #0x200
    mov r1, #0x800
    strh r1, [r0, #2]
    bx lr
    .ltorg
    .align 2
vars:
    .space 32
