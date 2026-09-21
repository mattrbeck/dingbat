@ probe.inc: the pieces every cycle probe re-grew, as macros.
@
@ A probe is ARM code entered with r0 = its argument and answering in r0
@ (tools/hwlink/monitor.py). The kit fixes a register convention so the
@ macros compose; everything else (r0-r3, r6, r7) is the probe's own.
@
@   r4  0x04000000      r5  0x04000200 (IE, IF, WAITCNT, IME at +8)
@   r8  0x040000B0 DMA0 r10 0x04000100 TM0 (TM1 at +4, ...)
@   r9  the argument    r11 0x00800000, a timer's start word
@   r12 probe_vars: 32 bytes of saved state, then 32 of the probe's
@
@ The shape that gave reproducible single-cycle numbers on the console:
@
@     probe_enter                  @ save, IME off, timers and DMA0 clear
@     probe_park 50                @ wake on a cycle the PPU chose
@     probe_timers_start           @ TM0 and TM1 run from here
@     probe_dma_arm                @ (set up before the park) or probe_vcount_irq
@     probe_spin 205               @ coarse: 4 cycles a count from IWRAM
@     probe_sled                   @ fine: (r9 & 15) + 1 one-cycle NOPs
@     ...the thing measured...
@     probe_read_tm0 r1            @ T
@     probe_leave                  @ r0 is the answer
@     probe_data
@
@ Sweep the sled's count from the host, one cell per k. Each edge in the
@ staircase is a one-cycle statement; see docs/cycle-hunt-method.md.
@
@ On the console: `bx pc` only on a word boundary; HALTCNT answers only to
@ BIOS code, so halts go through SWI 2; keep literal pools in range of long
@ sleds with .ltorg (probe_data ends with one).

    .macro probe_enter
    stmfd sp!, {r4-r11, lr}
    mov r9, r0
    mov r4, #0x04000000
    add r5, r4, #0x200
    ldr r12, =probe_vars
    ldrh r1, [r5, #8]
    str r1, [r12]                  @ IME
    ldrh r1, [r5]
    str r1, [r12, #4]              @ IE
    ldrh r1, [r4, #4]
    str r1, [r12, #8]              @ DISPSTAT
    ldr r1, =0x03007FFC
    ldr r1, [r1]
    str r1, [r12, #12]             @ the IRQ vector
    mov r0, #0
    strh r0, [r5, #8]
    ldr r10, =0x04000100
    str r0, [r10]
    str r0, [r10, #4]
    ldr r8, =0x040000B0
    str r0, [r8, #8]
    ldr r11, =0x00800000           @ a timer's start word
    .endm

    @ r0 survives; everything probe_enter saved goes back
    .macro probe_leave
    mov r1, #0
    strh r1, [r5, #8]
    str r1, [r8, #8]
    str r1, [r10]
    str r1, [r10, #4]
    ldr r1, [r12, #8]
    strh r1, [r4, #4]
    mvn r1, #0
    strh r1, [r5, #2]
    ldr r1, =0x03007FFC
    ldr r2, [r12, #12]
    str r2, [r1]
    ldr r1, [r12, #4]
    strh r1, [r5]
    ldr r1, [r12]
    strh r1, [r5, #8]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .endm

    @ V-count match on \line, enabled in DISPSTAT and IE, IF cleared
    .macro probe_vcount_irq line
    mov r0, #\line
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x04
    strh r0, [r5]
    mvn r0, #0
    strh r0, [r5, #2]
    .endm

    @ Halt with IME clear until \line's V-count match: the CPU resumes on a
    @ fixed cycle of a fixed line, which a polled entry never gave. Put every
    @ register load the measured path needs BEFORE this.
    .macro probe_park line
    probe_vcount_irq \line
    swi 0x020000
    .endm

    @ An interrupt handler for the BIOS dispatcher to call
    .macro probe_set_handler label
    adr r0, \label
    ldr r1, =0x03007FFC
    str r0, [r1]
    .endm

    @ TM0 and TM1, prescaler 1, one store apart. Nothing but stores between
    @ the wake and the measurement: r11 was loaded by probe_enter.
    .macro probe_timers_start
    str r11, [r10]
    str r11, [r10, #4]
    .endm

    .macro probe_read_tm0 reg
    ldrh \reg, [r10]
    .endm

    .macro probe_read_tm1 reg
    ldrh \reg, [r10, #4]
    .endm

    @ A timer stop lands one cycle after this write (tmrw.s)
    .macro probe_stop_tm0
    mov r0, #0
    strh r0, [r10, #2]
    .endm

    @ DMA0 moves one zero halfword onto TM1CNT_H: the DMA's own write freezes
    @ TM1, so TM1 afterwards is WHEN the DMA wrote. \timing 1 = V-blank,
    @ 2 = H-blank. Set up BEFORE the park; \reg keeps the control word, and a
    @ probe's no-DMA control clears it so both paths are the same length.
    .macro probe_dma_stamp_setup timing, reg=r6
    mov r0, #0
    str r0, [r12, #32]
    add r0, r12, #32
    str r0, [r8]
    ldr r0, =0x04000106
    str r0, [r8, #4]
    ldr \reg, =(0x81400001 | (\timing << 28))
    .endm

    @ one store: armed for the next such blank
    .macro probe_dma_arm reg=r6
    str \reg, [r8, #8]
    .endm

    @ 4 cycles a count from IWRAM, less one on the way out
    .macro probe_spin count
    mov r0, #\count
1:  subs r0, r0, #1
    bne 1b
    .endm

    @ (\reg & 15) + 1 one-cycle NOPs; the computed branch costs the same for
    @ every count, so consecutive counts differ by exactly one cycle
    .macro probe_sled reg=r9
    and r0, \reg, #0x0F
    rsb r0, r0, #15
    add pc, pc, r0, lsl #2
    mov r0, r0
    .rept 16
    mov r0, r0
    .endr
    .endm

    .macro probe_data
    .ltorg
    .align 2
probe_vars:
    .space 64
    .endm
