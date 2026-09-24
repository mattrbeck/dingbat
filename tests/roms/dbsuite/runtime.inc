@ runtime.inc -- the menu, the runner, the watchdog, the output channels
@ and the renderer.
@
@ Robustness, in the order things can go wrong:
@  * a case that hangs with interrupts open: TM3 (/1024, IRQ) is armed
@    around every run routine; its overflow (4 s) diverts the IRQ return to
@    case_timeout_recover and the case reads TIMEOUT.
@  * a case that hangs with interrupts masked, or that ends in the BIOS's
@    undefined-instruction or abort handler: nothing inside the machine can
@    take control back.  The results block says RUNNING and names the case
@    in flight, so a harness reports it; the screen keeps its white verdict
@    block and a RUNNING banner, which never reads as a pass.
@  * a case that ends in a reset (a jump to 0, or a BIOS handler that
@    reboots): main finds the results block still RUNNING, marks the case in
@    flight CRASH and carries on with the next one.
@  * a case that comes back in another CPU mode or with the stack moved:
@    the runner restores System mode and its own stack from memory.

@ ═══════════════════════════════ entry ═══════════════════════════════════
main:
    mov r0, #IOBASE
    add r0, r0, #0x208
    mov r1, #0
    strh r1, [r0]                  @ IME off before anything else
    msr cpsr_c, #0xD2              @ IRQ mode stack
    ldr sp, =0x03007FA0
    msr cpsr_c, #0xD3              @ SVC mode stack
    ldr sp, =0x03007FE0
    msr cpsr_c, #0x1F              @ System, IRQs open (IME gates them)
    ldr sp, =0x03007F00

    ldr r4, =RT
    mov r0, #0
    mvn r1, #0
    str r0, [r4, #RT_INFLIGHT]
    str r1, [r4, #RT_LAST_RUN]
    str r0, [r4, #RT_VERDICT]
    str r0, [r4, #RT_LINKON]
    str r0, [r4, #RT_SCROLL]
    str r0, [r4, #RT_CURSOR]
    ldr r0, =0x7FFF
    strh r0, [r4, #RT_PAPER]
    mov r0, #0
    strh r0, [r4, #RT_INK]

    bl  machine_reset
    ldr r0, =0xDBFF0001            @ beacon: booted
    bl  beacon
.if MB
    @ the multiboot build keeps the boot beacon armed for 2 s, so a host
    @ that samples late still sees that the image started
    mov r4, #120
1:  bl  wait_vblank
    bl  beacon_poll
    subs r4, r4, #1
    bne 1b
    ldr r4, =RT
.endif
    bl  detect_debug_ports
    bl  resume_check               @ r0 = 1: a run was cut short by a reset
    cmp r0, #0
    bne main_resume
    bl  results_init
    ldr r0, =rom_config
    ldr r0, [r0]
    tst r0, #1
    bne main_runall
    b   menu

main_runall:
    ldr r0, =rom_config            @ bits 16-31: the case to start from
    ldr r0, [r0]
    mov r0, r0, lsr #16
    ldr r1, =N_CASES
    cmp r0, r1
    movhs r0, #0
    bl  run_range
    b   summary_view

main_resume:
    @ the case in flight when the machine reset is a CRASH; go on from the
    @ next one to the end of the run that was in progress
    ldr r4, =RESULTS
    ldr r0, [r4, #RB_RESUMES]
    add r0, r0, #1
    str r0, [r4, #RB_RESUMES]
    ldr r5, [r4, #RB_CURRENT]
    mov r0, r5
    mov r1, #ST_CRASH
    mov r2, #0
    bl  record_status
    mov r0, r5
    bl  emit_case_line
    add r0, r5, #1
    ldr r1, [r4, #RB_RUNEND]
    bl  run_range_continue
    b   summary_view
    .ltorg

@ r0 = a word for a host on the link cable to find: armed as a 32-bit slave
@ transfer, no interrupt.  0xDBFF0001 booted, 0xDBFF0002 in the menu,
@ 0xDB000000 | n case n in flight; the results stream follows a run.
beacon:
    ldr r1, =RT
    str r0, [r1, #RT_BEACON]
    ldr r1, =0x04000120
    str r0, [r1]
    ldr r0, =0x1080
    strh r0, [r1, #8]
    bx  lr

@ re-arm the beacon once the host has clocked it (not while the results
@ stream owns the port).  Clobbers r0-r2.
beacon_poll:
    ldr r2, =RT
    ldr r0, [r2, #RT_LINKON]
    cmp r0, #0
    bxne lr
    ldr r1, =0x04000120
    ldrh r0, [r1, #8]
    tst r0, #0x80
    bxne lr
    ldr r0, [r2, #RT_BEACON]
    str r0, [r1]
    ldr r0, =0x1080
    strh r0, [r1, #8]
    bx  lr

@ -> r0 = 1 if the results block is a run of this ROM that a reset cut short
resume_check:
    ldr r2, =RESULTS
    ldr r0, [r2, #RB_MAGIC]
    ldr r1, =MAGIC_WORD
    cmp r0, r1
    bne 9f
    ldr r0, [r2, #RB_VERSION]
    cmp r0, #RB_VER
    bne 9f
    ldr r0, [r2, #RB_STATE]
    cmp r0, #1
    bne 9f
    ldr r0, [r2, #RB_NCASES]
    ldr r1, =N_CASES
    cmp r0, r1
    bne 9f
    ldr r0, [r2, #RB_CURRENT]
    cmp r0, r1
    bhs 9f
    ldr r0, [r2, #RB_RUNEND]
    cmp r0, r1
    bhi 9f
    ldr r0, [r2, #RB_RESUMES]
    cmp r0, #32                    @ a reset loop: stop resuming
    bhs 9f
    mov r0, #1
    bx  lr
9:  mov r0, #0
    bx  lr
    .ltorg

@ ═══════════════════════════ results block ═══════════════════════════════
results_init:
    stmfd sp!, {r4-r8, lr}
    ldr r4, =RESULTS
    ldr r1, =N_CASES
    mov r2, #RB_CASES
    add r2, r2, r1, lsl #4         @ bytes
    mov r0, r4
    mov r3, #0
1:  str r3, [r0], #4
    subs r2, r2, #4
    bgt 1b
    mov r0, #RB_VER
    str r0, [r4, #RB_VERSION]
    ldr r0, =N_CASES
    str r0, [r4, #RB_NCASES]
    ldr r0, =N_SUITES
    str r0, [r4, #RB_NSUITES]
    mvn r0, #0
    str r0, [r4, #RB_CURRENT]
    mov r0, #MB
    str r0, [r4, #RB_FLAGS]
    @ suite records: first case and count; case records: suite and kind
    ldr r5, =suite_table
    mov r6, #0                     @ suite index
2:  ldr r0, [r5]                   @ name, 0 = end
    cmp r0, #0
    beq 5f
    ldr r7, [r5, #4]               @ first
    ldr r8, [r5, #12]              @ next suite's first (or N_CASES)
    add r0, r4, #RB_SUITES
    add r0, r0, r6, lsl #4
    strh r7, [r0, #12]
    sub r1, r8, r7
    strh r1, [r0, #14]
3:  cmp r7, r8
    bhs 4f
    add r0, r4, #RB_CASES
    add r0, r0, r7, lsl #4
    strb r6, [r0, #1]
    ldr r1, =case_table
    add r1, r1, r7, lsl #5
    ldr r1, [r1, #CD_INFO]
    and r1, r1, #0x0F
    strb r1, [r0, #2]
    add r7, r7, #1
    b   3b
4:  add r5, r5, #8
    add r6, r6, #1
    b   2b
5:  ldr r0, =MAGIC_WORD            @ the magic last: a half-built block never
    str r0, [r4, #RB_MAGIC]        @ reads as one
    bl  recount
    ldmfd sp!, {r4-r8, pc}
    .ltorg

@ Recompute every suite's counters and the totals from the case records.
recount:
    stmfd sp!, {r4-r9, lr}
    ldr r4, =RESULTS
    add r0, r4, #RB_TOTALS
    mov r1, #0
    mov r2, #6
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    add r0, r4, #RB_SUITES
    mov r2, #(MAX_SUITES * 16)
2:  strh r1, [r0], #2              @ zero the counters (+0..+10), keep +12/+14
    strh r1, [r0], #2
    strh r1, [r0], #2
    strh r1, [r0], #2
    strh r1, [r0], #2
    strh r1, [r0], #2
    add r0, r0, #4
    subs r2, r2, #16
    bne 2b
    ldr r5, =N_CASES
    mov r6, #0
3:  cmp r6, r5
    bhs 9f
    add r0, r4, #RB_CASES
    add r0, r0, r6, lsl #4
    ldrb r1, [r0]                  @ status
    ldrb r2, [r0, #1]              @ suite
    mov r0, r1
    mov r1, r2
    bl  count_status
    add r6, r6, #1
    b   3b
9:  ldmfd sp!, {r4-r9, pc}

@ r0 = status, r1 = suite: bump the suite's counter and the totals
count_status:
    ldr r2, =RESULTS
    add r3, r2, #RB_SUITES
    add r3, r3, r1, lsl #4
    ldrh r12, [r3, #10]            @ total
    add r12, r12, #1
    strh r12, [r3, #10]
    cmp r0, #ST_NOTRUN
    beq 1f
    sub r12, r0, #1                @ PASS..SKIP -> counters 0..4
    add r1, r3, r12, lsl #1
    ldrh r12, [r1]
    add r12, r12, #1
    strh r12, [r1]
    sub r12, r0, #1
    add r1, r2, #RB_TOTALS
    ldr r3, [r1, r12, lsl #2]
    add r3, r3, #1
    str r3, [r1, r12, lsl #2]
    bx  lr
1:  add r1, r2, #(RB_TOTALS + 20)
    ldr r3, [r1]
    add r3, r3, #1
    str r3, [r1]
    bx  lr
    .ltorg

@ r0 = case, r1 = status, r2 = got (the expectation comes from the table)
record_status:
    stmfd sp!, {r4-r6, lr}
    ldr r4, =RESULTS
    add r4, r4, #RB_CASES
    add r4, r4, r0, lsl #4
    strb r1, [r4]
    str r2, [r4, #4]
    ldr r3, =case_table
    add r3, r3, r0, lsl #5
    ldr r5, [r3, #CD_LO]
    ldr r6, [r3, #CD_HI]
    ldr r0, [r3, #CD_INFO]
    and r0, r0, #0x0F
    cmp r0, #K_SLOT                @ a slot-relative expectation has no
    moveq r5, #0                   @ value until the case has run
    moveq r6, #0
    str r5, [r4, #8]
    str r6, [r4, #12]
    mov r0, r1
    ldrb r1, [r4, #1]
    bl  count_status
    ldmfd sp!, {r4-r6, pc}
    .ltorg

@ ═════════════════════════════ the runner ════════════════════════════════
@ r0 = first case, r1 = one past the last.  Resets those cases, runs them,
@ recounts, and writes RB_DONE last.
run_range:
    stmfd sp!, {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    ldr r6, =RESULTS
    mov r0, #0
    str r0, [r6, #RB_DONE]
    str r0, [r6, #RB_RESUMES]
    str r5, [r6, #RB_RUNEND]
    ldr r1, =RT
    str r0, [r1, #RT_VERDICT]
    str r0, [r1, #RT_LINKON]
    mov r0, r4                     @ forget these cases' old answers
1:  cmp r0, r5
    bhs 2f
    add r1, r6, #RB_CASES
    add r1, r1, r0, lsl #4
    mov r2, #0
    strb r2, [r1]
    str r2, [r1, #4]
    add r0, r0, #1
    b   1b
2:  bl  recount
    mov r0, r4
    mov r1, r5
    bl  emit_begin_line
    mov r0, r4
    mov r1, r5
    ldmfd sp!, {r4-r6, lr}
    @ fall through
run_range_continue:
    stmfd sp!, {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    ldr r6, =RESULTS
    mov r0, #1
    str r0, [r6, #RB_STATE]
    ldr r0, =RT
    mvn r1, #0
    str r1, [r0, #RT_LAST_RUN]     @ no group results carried in
    mov r1, #0
    str r1, [r0, #RT_FAILROW]
    str r4, [r0, #RT_RUNSTART]
    bl  draw_run_screen
1:  cmp r4, r5
    bhs 2f
    str r4, [r6, #RB_CURRENT]
    mov r0, r4
    bl  run_case
    add r4, r4, #1
    b   1b
2:  mvn r0, #0
    str r0, [r6, #RB_CURRENT]
    bl  recount
    mov r0, #2
    str r0, [r6, #RB_STATE]
    bl  emit_summary_lines
    @ verdict: green only if nothing failed, timed out or crashed
    ldr r0, [r6, #(RB_TOTALS + 4)]
    ldr r1, [r6, #(RB_TOTALS + 8)]
    orr r0, r0, r1
    ldr r1, [r6, #(RB_TOTALS + 12)]
    orr r0, r0, r1
    ldr r1, [r6, #RB_TOTALS]       @ and at least one pass
    cmp r1, #0
    moveq r0, #1
    ldr r1, =RT
    cmp r0, #0
    moveq r0, #1
    movne r0, #2
    str r0, [r1, #RT_VERDICT]
    ldr r0, =DONE_WORD
    str r0, [r6, #RB_DONE]         @ the last word written
    @ stream the block down the link cable from here on
    ldr r0, =RESULTS
    ldr r1, =N_CASES
    mov r1, r1, lsl #2
    add r1, r1, #(RB_CASES / 4)
    bl  link_report_init
    ldmfd sp!, {r4-r6, pc}
    .ltorg

@ r0 = case index: run it (or reuse its group's run) and record the verdict
run_case:
    stmfd sp!, {r4-r9, lr}
    mov r4, r0
    ldr r5, =case_table
    add r5, r5, r4, lsl #5         @ r5 = descriptor
    bl  beacon_poll
    bl  draw_run_progress
    ldr r0, [r5, #CD_INFO]
    tst r0, #F_RISKY
    beq 0f
    ldr r1, =rom_config
    ldr r1, [r1]
    tst r1, #4                     @ rom_config bit 2: leave these out
    beq 0f
    mov r0, r4
    mov r1, #ST_SKIP
    mov r2, #0
    bl  record_status
    b   8f
0:  ldr r0, [r5, #CD_INFO]
    tst r0, #F_CART
    beq 1f
.if MB
    mov r0, r4                     @ the multiboot build runs from EWRAM
    mov r1, #ST_SKIP               @ with no cartridge: nothing to measure
    mov r2, #0
    bl  record_status
    b   8f
.endif
1:  @ the group head: this case, or the nearest one above with a run
    mov r6, r4
    mov r7, r5
2:  ldr r0, [r7, #CD_RUN]
    cmp r0, #0
    bne 3f
    cmp r6, #0
    beq 3f
    sub r6, r6, #1
    sub r7, r7, #CD_SIZE
    b   2b
3:  ldr r8, =RT
    ldr r0, [r8, #RT_LAST_RUN]
    cmp r0, r6
    beq 4f
    str r6, [r8, #RT_LAST_RUN]
    mov r0, r7
    bl  call_guarded               @ -> RT_GROUP_ST
4:  ldr r0, [r8, #RT_GROUP_ST]
    cmp r0, #0
    beq 5f
    mov r1, r0                     @ TIMEOUT or CRASH
    mov r0, r4
    mov r2, #0
    bl  record_status
    b   8f
5:  mov r0, r5
    bl  eval_case                  @ r0 status, r1 got, r2 lo, r3 hi
    mov r6, r2
    mov r7, r3
    mov r2, r1
    mov r1, r0
    mov r0, r4
    bl  record_status
    ldr r0, =RESULTS               @ a slot-relative expectation: record
    add r0, r0, #RB_CASES          @ the value it resolved to
    add r0, r0, r4, lsl #4
    str r6, [r0, #8]
    str r7, [r0, #12]
8:  mov r0, r4
    bl  emit_case_line
    mov r0, r4
    bl  draw_case_result
    ldmfd sp!, {r4-r9, pc}
    .ltorg

@ r0 = descriptor -> r0 status (PASS/FAIL), r1 got, r2 exp lo, r3 exp hi
eval_case:
    stmfd sp!, {r4-r7, lr}
    mov r4, r0
    ldr r5, [r4, #CD_INFO]
    mov r0, r5, lsr #16
    ldr r1, =0xFFF
    and r0, r0, r1
    bl  slot_word
    ldr r6, [r4, #CD_MASK]
    and r1, r0, r6                 @ got
    ldr r2, [r4, #CD_LO]
    ldr r3, [r4, #CD_HI]
    and r5, r5, #0x0F
    cmp r5, #K_SLOT
    bne 1f
    mov r7, r1
    mov r0, r2
    bl  slot_word
    and r2, r0, r6
    mov r3, r2
    mov r1, r7
1:  mov r0, #ST_FAIL
    cmp r5, #K_TWO
    bne 2f
    cmp r1, r2
    cmpne r1, r3
    moveq r0, #ST_PASS
    b   3f
2:  cmp r1, r2
    blo 3f
    cmp r1, r3
    movls r0, #ST_PASS
3:  ldmfd sp!, {r4-r7, pc}

@ r0 = byte offset into SLOT -> r0 = the little-endian word there
slot_word:
    ldr r1, =SLOT
    add r1, r1, r0
    ldrb r0, [r1]
    ldrb r2, [r1, #1]
    orr r0, r0, r2, lsl #8
    ldrb r2, [r1, #2]
    orr r0, r0, r2, lsl #16
    ldrb r2, [r1, #3]
    orr r0, r0, r2, lsl #24
    bx  lr
    .ltorg

@ r0 = descriptor.  Runs its routine under the watchdog from a clean
@ machine and leaves RT_GROUP_ST = 0 (it returned), TIMEOUT or CRASH.
call_guarded:
    stmfd sp!, {r4-r11, lr}
    mov r4, r0
    bl  machine_reset
    ldr r0, =SLOT                  @ a clean slot and IRQ scratch
    mov r1, #(SLOTSZ / 4)
    mov r2, #0
1:  str r2, [r0], #4
    subs r1, r1, #1
    bne 1b
    ldr r0, =SCRATCH + 0x40
    mov r1, #8
1:  str r2, [r0], #4
    subs r1, r1, #1
    bne 1b
    ldr r0, =MARKER
    mov r1, #8
1:  str r2, [r0], #4
    subs r1, r1, #1
    bne 1b
    @ a beacon for a host on the link cable: 0xDB000000 | the case in
    @ flight, as a 32-bit slave transfer (no interrupt, so a case cannot
    @ tell), so a run that stops can be placed without a screen
    ldr r0, =RESULTS
    ldr r0, [r0, #RB_CURRENT]
    orr r0, r0, #0xDB000000
    bl  beacon
    ldr r5, =RT
    str sp, [r5, #RT_SAVED_SP]
    mrs r0, cpsr
    str r0, [r5, #RT_SAVED_CPSR]
    mov r0, #1
    str r0, [r5, #RT_INFLIGHT]
    @ the case-level watchdog: TM3 /1024 from 0 overflows in 4 s
    ldr r1, =0x0400010C
    ldr r0, =0x00C30000
    str r0, [r1]
    ldr r1, =0x04000200
    mov r0, #0x40
    strh r0, [r1]                  @ IE = timer 3
    ldr r0, =0x3FFF
    strh r0, [r1, #2]              @ IF acknowledged
    mov r0, #1
    strh r0, [r1, #8]              @ IME
    mov r0, r4
    ldr r1, [r4, #CD_RUN]
    mov lr, pc
    bx  r1
    mov r4, #0                     @ it came back
    b   cg_after
case_timeout_recover:              @ the watchdog's diverted return, System
    mov r4, #ST_TIMEOUT            @ mode with IRQs masked
cg_after:
    mrs r0, cpsr                   @ whatever mode the case left us in
    and r0, r0, #0x1F
    cmp r0, #0x10                  @ User mode cannot leave by itself
    beq cg_user
    msr cpsr_c, #0x9F              @ System, IRQs masked
    ldr r5, =RT
    ldr sp, [r5, #RT_SAVED_SP]
    mov r0, #0
    str r0, [r5, #RT_INFLIGHT]
    bl  machine_reset
    msr cpsr_c, #0x1F
    str r4, [r5, #RT_GROUP_ST]
    ldmfd sp!, {r4-r11, pc}
cg_user:
    @ a case left us in User mode: raise the watchdog now and let its
    @ handler return us in System mode
    ldr r5, =RT
    mov r0, #1
    str r0, [r5, #RT_INFLIGHT]
    mov r4, #ST_CRASH
    ldr r1, =0x0400010C
    ldr r0, =0x00C0FFF0
    str r0, [r1]
    ldr r1, =0x04000200
    mov r0, #0x40
    strh r0, [r1]
    mov r0, #1
    strh r0, [r1, #8]
1:  b   1b                         @ the IRQ lands in case_timeout_recover,
    .ltorg                         @ which reads TIMEOUT: good enough

@ Everything a case may have changed goes back to the state the cases
@ were written against.  Clobbers r0-r3.
machine_reset:
    mov r0, #IOBASE
    add r1, r0, #0x200
    mov r2, #0
    strh r2, [r1, #8]              @ IME
    strh r2, [r1]                  @ IE
    ldr r3, =0x3FFF
    strh r3, [r1, #2]              @ IF
    strh r2, [r1, #4]              @ WAITCNT: the cartridge BIOS's 0
    ldr r3, =0x0D000020            @ internal memory control, boot value
    ldr r1, =0x04000800
    str r3, [r1]
    add r1, r0, #0x100             @ timers: stopped, reload 0
    str r2, [r1]
    str r2, [r1, #4]
    str r2, [r1, #8]
    str r2, [r1, #12]
    add r1, r0, #0xB0              @ DMA: disabled, addresses cleared
    mov r3, #4
1:  str r2, [r1, #8]
    str r2, [r1]
    str r2, [r1, #4]
    add r1, r1, #12
    subs r3, r3, #1
    bne 1b
    strh r2, [r0, #4]              @ DISPSTAT: no match, no IRQ enables
    add r1, r0, #0x80              @ sound: master off clears the PSG
    strh r2, [r1, #4]
    strh r2, [r1]
    ldr r3, =0x0B0F                @ FIFO resets, the rest 0
    strh r3, [r1, #2]
    strh r2, [r1, #2]
    add r1, r0, #0x120             @ SIO: stopped, external clock
    strh r2, [r1, #8]              @ SIOCNT (0x128)
    strh r2, [r1, #0x14]           @ RCNT (0x134): serial mode
    strh r2, [r1, #0x12]           @ KEYCNT (0x132)
    ldr r3, =0x0403                @ mode 3, BG2
    strh r3, [r0]
    strh r2, [r0, #0x50]           @ BLDCNT
    strh r2, [r0, #0x4C]           @ MOSAIC
    ldr r3, =0x0100                @ BG2 affine: identity at the origin
    add r1, r0, #0x20
    strh r3, [r1]
    strh r2, [r1, #2]
    strh r2, [r1, #4]
    strh r3, [r1, #6]
    str r2, [r1, #8]
    str r2, [r1, #12]
    strh r2, [r0, #0x0C]           @ BG2CNT
    ldr r1, =0x03007FFC            @ our IRQ handler
    ldr r3, =irq_handler
    str r3, [r1]
    mrs r3, cpsr                   @ the BIOS's IRQ stack, wherever a case
    msr cpsr_c, #0xD2              @ left it
    ldr sp, =0x03007FA0
    msr cpsr_c, r3
    bx  lr
    .ltorg

@ Put the IRQ stack in EWRAM at SCRATCH+0xF0 for the rest of the case, as
@ gbaedge's pages ran with it (its THUMBPC and LDMUSER pages moved sp_irq
@ there and never put it back): the BIOS dispatcher's push and pop then
@ cost what they cost on the photographed run.  machine_reset undoes it.
sp_irq_ewram:
    mrs r0, cpsr
    msr cpsr_c, #0xD2
    ldr sp, =SCRATCH + 0xF0
    msr cpsr_c, r0
    bx  lr
    .ltorg

@ ─────────────────────────────── IRQ handler ─────────────────────────────
@ Entered from the BIOS dispatcher in IRQ mode; [sp,#20] is the address
@ the BIOS returns through (`subs pc, lr, #4`).  First entry since the flag
@ at SCRATCH+0x4C was cleared records the TM0 stamp and that address (the
@ IRQ-window cases read it).  A TM3 overflow is the watchdog: a probe row
@ armed with wdg_arm is diverted to its recovery label, otherwise a case
@ run under call_guarded is diverted to case_timeout_recover.
irq_handler:
    ldr r0, =0x04000100
    ldrh r1, [r0]
    ldr r0, =SCRATCH
    ldr r2, [r0, #0x4C]
    cmp r2, #0
    streqh r1, [r0, #0x48]
    ldreq r3, [sp, #20]
    streq r3, [r0, #0x50]
    moveq r2, #1
    streq r2, [r0, #0x4C]
    ldr r0, =0x04000200
    ldrh r1, [r0, #2]              @ IF
    tst r1, #0x40
    beq 9f
    ldr r2, =MARKER
    ldr r3, [r2, #8]
    cmp r3, #1                     @ a probe row in flight?
    bne 2f
    mov r3, #2
    str r3, [r2, #8]
    ldr r3, [r2, #20]
    b   3f
2:  ldr r2, =RT
    ldr r3, [r2, #RT_INFLIGHT]
    cmp r3, #1
    bne 9f
    mov r3, #2
    str r3, [r2, #RT_INFLIGHT]
    ldr r3, =case_timeout_recover
3:  add r3, r3, #4                 @ the BIOS returns to [sp,#20] - 4
    str r3, [sp, #20]
    mov r3, #0x9F                  @ System mode, ARM, IRQs masked
    msr SPSR_cxsf, r3
    ldr r2, =0x0400010C            @ and the watchdog stopped
    mov r3, #0
    str r3, [r2]
9:  strh r1, [r0, #2]              @ acknowledge what we saw
    bx  lr
    .ltorg

@ ────────────────────────────── the run routines ─────────────────────────
@ run_payload: p0 = a payload_blob record, p1 = its argument.  The blob is
@ copied to IWRAM 0x03000000 and called there with r0 = the argument, as
@ the link rig's monitor calls it; SLOT+0 = the r0 it returns, and
@ SLOT+0x100.. = the first 256 bytes of its result area (0x02008000).
run_payload:
    stmfd sp!, {r4, lr}
    ldr r1, [r0, #CD_P0]
    ldr r4, [r0, #CD_P1]
    ldmia r1, {r2, r3}
    ldr r1, =PAYLOAD
1:  ldr r12, [r2], #4
    str r12, [r1], #4
    cmp r2, r3
    blo 1b
    @ Enter at the top of line 120, clear of every line a payload parks on
    @ (30, 50, 100-102, 159, 160): a payload that waits for an interrupt
    @ must not be called in the few cycles before that interrupt, or the
    @ wait can end at once and the page reads another entry phase.
    ldr r1, =0x04000006
1:  ldrh r2, [r1]
    cmp r2, #120
    beq 1b
2:  ldrh r2, [r1]
    cmp r2, #120
    bne 2b
    mov r0, r4
    ldr r12, =PAYLOAD
    mov lr, pc
    bx  r12
    ldr r1, =SLOT
    str r0, [r1]
    ldr r2, =PRESULTS
    add r1, r1, #0x100
    mov r3, #64
1:  ldr r0, [r2], #4
    str r0, [r1], #4
    subs r3, r3, #1
    bne 1b
    ldmfd sp!, {r4, pc}
    .ltorg

wait_vblank:
    ldr r0, =0x04000006
1:  ldrh r1, [r0]
    cmp r1, #159
    bne 1b
2:  ldrh r1, [r0]
    cmp r1, #160
    bne 2b
    bx  lr
    .ltorg

@ wait_vblank for the viewer loops, serving the link all the while: the host
@ clocks the results stream far faster than once a frame, and a word the ROM
@ has not re-armed reads as nothing (link_report_poll re-arms one word per
@ call).  Not for the cases: their poll loops keep their own timing.
wait_vblank_link:
    stmfd sp!, {r4, lr}
1:  bl  link_report_poll
    ldr r0, =0x04000006
    ldrh r1, [r0]
    cmp r1, #159
    bne 1b
2:  bl  link_report_poll
    ldr r0, =0x04000006
    ldrh r1, [r0]
    cmp r1, #160
    bne 2b
    ldmfd sp!, {r4, pc}
    .ltorg

@ ═══════════════════════════ output channels ═════════════════════════════
@ mGBA's debug registers (0x04FFF780 enable -> reads 0x1DEA, 0x04FFF600
@ string, 0x04FFF700 flags) and no$gba's debug port (0x04FFFA00 reads
@ "no$gba", a string pointer written to 0x04FFFA10).  Both are probed at
@ boot and used only if they answer; on hardware the writes land nowhere.
detect_debug_ports:
    ldr r2, =RT
    mov r0, #0
    str r0, [r2, #RT_MGBA]
    str r0, [r2, #RT_NOCASH]
    ldr r1, =0x04FFF780
    ldr r0, =0xC0DE
    strh r0, [r1]
    ldrh r0, [r1]
    ldr r3, =0x1DEA
    cmp r0, r3
    moveq r0, #1
    streq r0, [r2, #RT_MGBA]
    ldr r1, =0x04FFFA00
    ldr r0, [r1]
    ldr r3, =0x67246F6E            @ "no$g"
    cmp r0, r3
    moveq r0, #1
    streq r0, [r2, #RT_NOCASH]
    bx  lr
    .ltorg

sb_reset:
    ldr r1, =RT
    mov r0, #0
    str r0, [r1, #RT_SBPOS]
    bx  lr

@ r0 = character
sb_char:
    ldr r1, =RT
    ldr r2, [r1, #RT_SBPOS]
    cmp r2, #250
    bxhs lr
    add r3, r1, #RT_SB
    strb r0, [r3, r2]
    add r2, r2, #1
    str r2, [r1, #RT_SBPOS]
    bx  lr

@ r0 = NUL-terminated string
sb_str:
    stmfd sp!, {r4, lr}
    mov r4, r0
1:  ldrb r0, [r4], #1
    cmp r0, #0
    beq 2f
    bl  sb_char
    b   1b
2:  ldmfd sp!, {r4, pc}

@ r0 = value: eight hex digits
sb_hex:
    stmfd sp!, {r4, r5, lr}
    mov r4, r0
    mov r5, #28
1:  mov r0, r4, lsr r5
    and r0, r0, #0xF
    cmp r0, #10
    addlo r0, r0, #0x30
    addhs r0, r0, #0x37
    bl  sb_char
    subs r5, r5, #4
    bpl 1b
    ldmfd sp!, {r4, r5, pc}

@ r0 = value: decimal
sb_dec:
    stmfd sp!, {r4-r6, lr}
    mov r4, r0
    ldr r5, =dec_powers
    mov r6, #0                     @ a digit has been printed
1:  ldr r1, [r5], #4
    cmp r1, #1
    beq 3f
    mov r0, #0
2:  cmp r4, r1
    subhs r4, r4, r1
    addhs r0, r0, #1
    bhs 2b
    cmp r0, #0
    cmpeq r6, #0
    beq 1b
    mov r6, #1
    add r0, r0, #0x30
    bl  sb_char
    b   1b
3:  add r0, r4, #0x30
    bl  sb_char
    ldmfd sp!, {r4-r6, pc}
dec_powers:
    .word 1000000000, 100000000, 10000000, 1000000, 100000, 10000, 1000
    .word 100, 10, 1
    .ltorg

@ Send the line to every debug channel that answered.
sb_emit:
    stmfd sp!, {r4-r6, lr}
    mov r0, #0
    bl  sb_char                    @ NUL-terminate
    ldr r4, =RT
    add r5, r4, #RT_SB
    ldr r0, [r4, #RT_MGBA]
    cmp r0, #0
    beq 2f
    ldr r1, =0x04FFF600
    mov r2, r5
1:  ldrb r0, [r2], #1
    strb r0, [r1], #1
    cmp r0, #0
    bne 1b
    ldr r1, =0x04FFF700
    ldr r0, =0x0103                @ send, level INFO
    strh r0, [r1]
2:  ldr r0, [r4, #RT_NOCASH]
    cmp r0, #0
    beq 3f
    ldr r1, =0x04FFFA10
    str r5, [r1]
3:  ldmfd sp!, {r4-r6, pc}
    .ltorg

@ r0 = case index -> r0 = its suite's name
suite_name_of:
    ldr r1, =RESULTS + RB_CASES
    add r1, r1, r0, lsl #4
    ldrb r1, [r1, #1]
    ldr r0, =suite_table
    ldr r0, [r0, r1, lsl #3]
    bx  lr
    .ltorg

status_names:
    .word str_notrun, str_pass, str_fail, str_timeout, str_crash, str_skip
str_notrun:  .asciz "NOTRUN"
str_pass:    .asciz "PASS"
str_fail:    .asciz "FAIL"
str_timeout: .asciz "TIMEOUT"
str_crash:   .asciz "CRASH"
str_skip:    .asciz "SKIP"
str_dbsuite: .asciz "DBSUITE "
str_case:    .asciz "case "
str_got:     .asciz " got="
str_exp:     .asciz " exp="
str_dots:    .asciz ".."
str_bar:     .asciz "|"
str_dash:    .asciz "-"
str_begin:   .asciz "begin version=1 cases="
str_first:   .asciz " first="
str_end:     .asciz " end="
str_mode:    .asciz " mode="
str_cart:    .asciz "cartridge"
str_mboot:   .asciz "multiboot"
str_suite:   .asciz "suite "
str_done:    .asciz "done"
str_spass:   .asciz " pass="
str_sfail:   .asciz " fail="
str_stimeout:.asciz " timeout="
str_scrash:  .asciz " crash="
str_sskip:   .asciz " skip="
str_stotal:  .asciz " total="
str_alldone: .asciz "DBSUITE ALL DONE"
    .align 2

@ r0 = first, r1 = end
emit_begin_line:
    stmfd sp!, {r4, r5, lr}
    mov r4, r0
    mov r5, r1
    bl  sb_reset
    ldr r0, =str_dbsuite
    bl  sb_str
    ldr r0, =str_begin
    bl  sb_str
    ldr r0, =N_CASES
    bl  sb_dec
    ldr r0, =str_first
    bl  sb_str
    mov r0, r4
    bl  sb_dec
    ldr r0, =str_end
    bl  sb_str
    mov r0, r5
    bl  sb_dec
    ldr r0, =str_mode
    bl  sb_str
.if MB
    ldr r0, =str_mboot
.else
    ldr r0, =str_cart
.endif
    bl  sb_str
    bl  sb_emit
    ldmfd sp!, {r4, r5, pc}
    .ltorg

@ r0 = case index:
@ "DBSUITE case <suite>/<name> <STATUS> got=<hex> exp=<hex>[..<hex>|<hex>]"
emit_case_line:
    stmfd sp!, {r4-r7, lr}
    mov r4, r0
    ldr r5, =RESULTS + RB_CASES
    add r5, r5, r4, lsl #4
    ldr r6, =case_table
    add r6, r6, r4, lsl #5
    bl  sb_reset
    ldr r0, =str_dbsuite
    bl  sb_str
    ldr r0, =str_case
    bl  sb_str
    mov r0, r4
    bl  suite_name_of
    bl  sb_str
    mov r0, #'/'
    bl  sb_char
    ldr r0, [r6, #CD_NAME]
    bl  sb_str
    mov r0, #' '
    bl  sb_char
    ldrb r7, [r5]
    ldr r0, =status_names
    ldr r0, [r0, r7, lsl #2]
    bl  sb_str
    ldr r0, =str_got
    bl  sb_str
    cmp r7, #ST_PASS
    cmpne r7, #ST_FAIL
    beq 1f
    ldr r0, =str_dash
    bl  sb_str
    b   2f
1:  ldr r0, [r5, #4]
    bl  sb_hex
2:  ldr r0, =str_exp
    bl  sb_str
    ldr r0, [r6, #CD_INFO]
    and r7, r0, #0x0F
    cmp r7, #K_SLOT
    ldrne r0, [r6, #CD_LO]
    ldreq r0, [r5, #8]
    bl  sb_hex
    cmp r7, #K_SLOT
    beq 3f
    ldr r1, [r6, #CD_LO]
    ldr r2, [r6, #CD_HI]
    cmp r1, r2
    beq 3f
    cmp r7, #K_TWO
    ldreq r0, =str_bar
    ldrne r0, =str_dots
    bl  sb_str
    ldr r0, [r6, #CD_HI]
    bl  sb_hex
3:  bl  sb_emit
    ldmfd sp!, {r4-r7, pc}
    .ltorg

@ one line per suite, then "DBSUITE done ..." and "DBSUITE ALL DONE"
emit_summary_lines:
    stmfd sp!, {r4-r6, lr}
    ldr r4, =suite_table
    ldr r5, =RESULTS + RB_SUITES
1:  ldr r0, [r4]
    cmp r0, #0
    beq 2f
    bl  sb_reset
    ldr r0, =str_dbsuite
    bl  sb_str
    ldr r0, =str_suite
    bl  sb_str
    ldr r0, [r4]
    bl  sb_str
    mov r0, r5
    mov r1, #1                     @ halfword counters
    bl  sb_counts
    bl  sb_emit
    add r4, r4, #8
    add r5, r5, #16
    b   1b
2:  bl  sb_reset
    ldr r0, =str_dbsuite
    bl  sb_str
    ldr r0, =str_done
    bl  sb_str
    ldr r0, =RESULTS + RB_TOTALS
    mov r1, #0                     @ word counters
    bl  sb_counts
    bl  sb_emit
    bl  sb_reset
    ldr r0, =str_alldone
    bl  sb_str
    bl  sb_emit
    ldmfd sp!, {r4-r6, pc}

@ r0 = counters (pass fail timeout crash skip), r1 = 1 halfwords (then a
@ total follows) / 0 words (the total is their sum plus notrun)
sb_counts:
    stmfd sp!, {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    ldr r6, =count_labels
    mov r7, #0
1:  ldr r0, [r6, r7, lsl #2]
    bl  sb_str
    cmp r5, #0
    ldreq r0, [r4, r7, lsl #2]
    addne r0, r4, r7, lsl #1
    ldrneh r0, [r0]
    bl  sb_dec
    add r7, r7, #1
    cmp r7, #5
    blo 1b
    ldr r0, =str_stotal
    bl  sb_str
    cmp r5, #0
    ldrneh r0, [r4, #10]
    bne 2f
    ldr r0, =N_CASES
2:  bl  sb_dec
    ldmfd sp!, {r4-r7, pc}
count_labels:
    .word str_spass, str_sfail, str_stimeout, str_scrash, str_sskip
    .ltorg

@ ════════════════════════════ link report ════════════════════════════════
@ The protocol of tests/roms/linkreport.inc ('LRPT' | count | words...,
@ looped; read with `python3 tools/hwlink/gblink.py report`), with its
@ state kept in RAM so it works from a cartridge.  Nothing blocks: with no
@ cable no transfer completes and link_report_poll does nothing.
.equ LR_MAGIC, 0x4C525054          @ 'LRPT'

@ r0 = block, r1 = words
link_report_init:
    stmfd sp!, {r4, lr}
    ldr r4, =RT + RT_LR_STATE
    str r0, [r4, #0]
    str r1, [r4, #4]
    mov r0, #0
    str r0, [r4, #8]
    ldr r1, =0x04000134            @ RCNT: serial mode
    strh r0, [r1]
    bl  lr_stage
    ldr r0, =RT
    mov r1, #1
    str r1, [r0, #RT_LINKON]
    ldmfd sp!, {r4, pc}

link_report_poll:
    stmfd sp!, {r4, lr}
    bl  beacon_poll
    ldr r0, =RT
    ldr r0, [r0, #RT_LINKON]
    cmp r0, #0
    beq 1f
    ldr r1, =0x04000128
    ldrh r0, [r1]
    tst r0, #0x80                  @ still waiting for the host's clock?
    bne 1f
    ldr r0, [r1, #-8]              @ the host's word: 'BOOT' asks for the
    ldr r2, =0x424F4F54            @ BIOS's HardReset, which with no
    cmp r0, r2                     @ cartridge waits for the next upload
    swieq 0x260000                 @ (tools/hwlink's monitor answers BOOT
    ldr r4, =RT + RT_LR_STATE      @ the same way)
    ldr r0, [r4, #8]
    add r0, r0, #1
    ldr r1, [r4, #4]
    add r1, r1, #2
    cmp r0, r1
    movcs r0, #0
    str r0, [r4, #8]
    bl  lr_stage
1:  ldmfd sp!, {r4, pc}

lr_stage:
    ldr r2, =RT + RT_LR_STATE
    ldr r0, [r2, #8]
    cmp r0, #0
    ldreq r1, =LR_MAGIC
    beq 2f
    cmp r0, #1
    ldreq r1, [r2, #4]
    beq 2f
    sub r0, r0, #2
    ldr r1, [r2, #0]
    ldr r1, [r1, r0, lsl #2]
2:  ldr r0, =0x04000120
    str r1, [r0]
    ldr r1, =0x1080                @ 32-bit, external clock, ready
    strh r1, [r0, #8]
    bx  lr
    .ltorg

@ ═════════════════════════════ the screens ═══════════════════════════════
@ Mode 3, a 6x8 font: 40 columns x 20 rows.  The 4x4 verdict block at
@ (236..239, 156..159) is white until a run finishes, then green (nothing
@ failed) or red; every screen redraws it last.

.equ C_BLACK,  0x0000
.equ C_WHITE,  0x7FFF
.equ C_RED,    0x001F
.equ C_GREEN,  0x0200
.equ C_BLUE,   0x5000
.equ C_GREY,   0x4210
.equ C_PINK,   0x4C7D
.equ C_DKRED,  0x0010

@ r0 = ink, r1 = paper
set_colors:
    ldr r2, =RT
    strh r0, [r2, #RT_INK]
    strh r1, [r2, #RT_PAPER]
    bx  lr

@ r0 = x, r1 = y, r2 = w, r3 = h (pixels), colour on the stack word
@ (fill_rect_c: colour in r12)
fill_rect_c:
    stmfd sp!, {r4-r6, lr}
    ldr r4, =VRAM
    mov r5, #480
    mla r4, r1, r5, r4
    add r4, r4, r0, lsl #1
1:  mov r5, r4
    mov r6, r2
2:  strh r12, [r5], #2
    subs r6, r6, #1
    bne 2b
    add r4, r4, #480
    subs r3, r3, #1
    bne 1b
    ldmfd sp!, {r4-r6, pc}

clear_screen:
    ldr r0, =VRAM
    ldr r1, =0x7FFF7FFF
    ldr r2, =240*160/2
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    bx  lr

@ r0 = row: blank the text row (paper white)
clear_row:
    stmfd sp!, {lr}
    mov r1, r0, lsl #3
    mov r0, #0
    mov r2, #240
    mov r3, #8
    ldr r12, =C_WHITE
    bl  fill_rect_c
    ldmfd sp!, {pc}

@ r0 = x pixel, r1 = y pixel, r2 = character (lower case drawn upper)
draw_char:
    stmfd sp!, {r4-r9, lr}
    cmp r2, #'a'
    blo 1f
    cmp r2, #'z'
    subls r2, r2, #0x20
1:  sub r2, r2, #0x20
    cmp r2, #96
    movhs r2, #('?' - 0x20)
    ldr r3, =VRAM
    mov r4, #480
    mla r3, r1, r4, r3
    add r3, r3, r0, lsl #1
    ldr r5, =font_data
    add r5, r5, r2, lsl #3
    ldr r8, =RT
    ldrh r9, [r8, #RT_INK]
    ldrh r8, [r8, #RT_PAPER]
    mov r6, #8
2:  ldrb r7, [r5], #1
    mov r2, #0x80
    mov r12, r3
3:  tst r7, r2
    movne r4, r9
    moveq r4, r8
    strh r4, [r12], #2
    mov r2, r2, lsr #1
    cmp r2, #2                     @ six columns: bits 7..2
    bne 3b
    add r3, r3, #480
    subs r6, r6, #1
    bne 2b
    ldmfd sp!, {r4-r9, pc}
    .ltorg

@ r0 = column, r1 = row, r2 = NUL-terminated string -> r0 = next column
draw_str:
    stmfd sp!, {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
1:  ldrb r2, [r6], #1
    cmp r2, #0
    beq 2f
    cmp r4, #40
    bhs 2f
    add r0, r4, r4, lsl #1
    mov r0, r0, lsl #1             @ x = col * 6
    mov r1, r5, lsl #3
    bl  draw_char
    add r4, r4, #1
    b   1b
2:  mov r0, r4
    ldmfd sp!, {r4-r6, pc}

@ r0 = column, r1 = row, r2 = value, r3 = digits (hex) -> r0 = next column
draw_hex:
    stmfd sp!, {r4-r8, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    sub r7, r3, #1
    mov r7, r7, lsl #2
1:  mov r2, r6, lsr r7
    and r2, r2, #0xF
    cmp r2, #10
    addlo r2, r2, #0x30
    addhs r2, r2, #0x37
    add r0, r4, r4, lsl #1
    mov r0, r0, lsl #1
    mov r1, r5, lsl #3
    bl  draw_char
    add r4, r4, #1
    subs r7, r7, #4
    bpl 1b
    mov r0, r4
    ldmfd sp!, {r4-r8, pc}

@ r0 = column, r1 = row, r2 = value -> r0 = next column (decimal)
draw_dec:
    stmfd sp!, {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    bl  sb_reset
    mov r0, r6
    bl  sb_dec
    mov r0, #0
    bl  sb_char
    mov r0, r4
    mov r1, r5
    ldr r2, =RT + RT_SB
    bl  draw_str
    ldmfd sp!, {r4-r6, pc}
    .ltorg

@ the verdict block, bottom right: white, green or red
draw_verdict:
    stmfd sp!, {lr}
    ldr r0, =RT
    ldr r0, [r0, #RT_VERDICT]
    ldr r12, =C_WHITE
    cmp r0, #1
    ldreq r12, =0x03E0
    cmp r0, #2
    ldreq r12, =0x001F
    mov r0, #236
    mov r1, #156
    mov r2, #4
    mov r3, #4
    bl  fill_rect_c
    ldmfd sp!, {pc}
    .ltorg

@ r0 = x, r1 = y: the logo at 2x (96 x 58); 0x8000 marks transparent
draw_logo:
    stmfd sp!, {r4-r10, lr}
    ldr r4, =VRAM
    mov r5, #480
    mla r4, r1, r5, r4
    add r4, r4, r0, lsl #1
    ldr r5, =logo_data
    mov r6, #LOGO_H
1:  mov r7, #LOGO_W
    mov r8, r4
2:  ldrh r9, [r5], #2
    tst r9, #0x8000
    bne 3f
    strh r9, [r8]
    strh r9, [r8, #2]
    add r10, r8, #480
    strh r9, [r10]
    strh r9, [r10, #2]
3:  add r8, r8, #4
    subs r7, r7, #1
    bne 2b
    add r4, r4, #960
    subs r6, r6, #1
    bne 1b
    ldmfd sp!, {r4-r10, pc}
    .ltorg

@ r0 = ink: set the ink, white paper
ink:
    ldr r1, =RT
    strh r0, [r1, #RT_INK]
    ldr r0, =C_WHITE
    strh r0, [r1, #RT_PAPER]
    bx  lr
    .ltorg

str_title:    .asciz "DBSUITE"
str_sub1:     .asciz "GBA behaviour as"
str_sub2:     .asciz "a real GBA SP shows it"
str_cartb:    .asciz "cartridge build"
str_mbb:      .asciz "multiboot build"
str_all:      .asciz "run every suite"
str_cases:    .asciz " cases"
str_help1:    .asciz "A run  START all"
str_auto:     .asciz "auto-run in "
str_autooff:  .asciz "auto-run off            "
str_running:  .asciz "RUNNING - do not trust this screen"
str_results:  .asciz "RESULTS"
str_total:    .asciz "total"
str_help2:    .asciz "A detail  B menu  UP/DOWN"
str_help3:    .asciz "B back  UP/DOWN scroll"
str_gotl:     .asciz "  got "
str_expl:     .asciz " exp "
str_slash:    .asciz "/"
str_ok:       .asciz "all pass"
str_bad:      .asciz "FAILURES"
str_sk:       .asciz " skip "
str_fl:       .asciz " fail "
str_to:       .asciz " t/o "
str_cr:       .asciz " crash "
str_pa:       .asciz " pass "
    .align 2

@ ───────────────────────────────── menu ──────────────────────────────────
menu:
    ldr r4, =RT
    mov r0, #0
    str r0, [r4, #RT_CURSOR]
    mov r0, #150                   @ frames of countdown (2.5 s)
    ldr r1, =rom_config
    ldr r1, [r1]
    tst r1, #2
    movne r0, #0
    mov r9, r0                     @ r9 = countdown, 0 = off
    ldr r0, =0x3FF
    str r0, [r4, #RT_KEYS]
    ldr r0, =RT
    ldr r0, [r0, #RT_LINKON]
    cmp r0, #0                     @ results already streaming: keep them
    ldreq r0, =0xDBFF0002          @ beacon: in the menu
    bleq beacon
menu_redraw:
    bl  clear_screen
    mov r0, #4
    mov r1, #4
    bl  draw_logo
    mov r0, #C_BLACK
    bl  ink
    mov r0, #18
    mov r1, #1
    ldr r2, =str_title
    bl  draw_str
    ldr r0, =C_GREY
    bl  ink
    ldr r0, =rom_version
    add r0, r0, #8                 @ "1"
    mov r2, r0
    mov r0, #26
    mov r1, #1
    bl  draw_str
    mov r0, #18
    mov r1, #3
    ldr r2, =str_sub1
    bl  draw_str
    mov r0, #18
    mov r1, #4
    ldr r2, =str_sub2
    bl  draw_str
    mov r0, #18
    mov r1, #6
.if MB
    ldr r2, =str_mbb
.else
    ldr r2, =str_cartb
.endif
    bl  draw_str
menu_list:
    @ rows 8..: "run every suite", then the suites
    mov r5, #0                     @ entry
    ldr r6, =suite_table
1:  cmp r5, #0
    beq 2f
    sub r0, r5, #1
    ldr r1, [r6, r0, lsl #3]
    cmp r1, #0
    beq 5f
2:  add r0, r5, #8
    bl  clear_row
    ldr r0, [r4, #RT_CURSOR]
    cmp r0, r5
    ldreq r0, =C_BLUE
    ldrne r0, =C_BLACK
    bl  ink
    ldr r0, [r4, #RT_CURSOR]
    cmp r0, r5
    mov r2, #'>'
    moveq r0, #0
    addeq r1, r5, #8
    moveq r1, r1, lsl #3
    bleq draw_char
    cmp r5, #0
    bne 3f
    mov r0, #2
    add r1, r5, #8
    ldr r2, =str_all
    bl  draw_str
    ldr r2, =N_CASES
    b   4f
3:  sub r0, r5, #1
    add r7, r6, r0, lsl #3
    mov r0, #2
    add r1, r5, #8
    ldr r2, [r7]
    bl  draw_str
    ldr r2, [r7, #12]
    ldr r3, [r7, #4]
    sub r2, r2, r3
4:  mov r0, #24
    add r1, r5, #8
    bl  draw_dec
    add r1, r5, #8
    ldr r2, =str_cases
    bl  draw_str
    add r5, r5, #1
    cmp r5, #11
    blo 1b
5:  mov r10, r5                    @ entries
    ldr r0, =C_GREY
    bl  ink
    mov r0, #0
    mov r1, #19
    ldr r2, =str_help1
    bl  draw_str
    bl  draw_verdict
menu_loop:
    bl  wait_vblank_link
    cmp r9, #0
    beq 2f
    subs r9, r9, #1
    beq menu_go_all
    ldr r0, =C_GREY
    bl  ink
    mov r0, #26
    mov r1, #19
    ldr r2, =str_auto
    bl  draw_str
    add r2, r9, #59
    ldr r3, =0x8889                @ /60 for small numbers
    mul r2, r3, r2
    mov r2, r2, lsr #21
    mov r0, #38
    mov r1, #19
    bl  draw_dec
2:  bl  read_keys                  @ r0 = newly pressed
    cmp r0, #0
    beq menu_loop
    mov r5, r0
    cmp r9, #0                     @ any key stops the countdown
    beq 3f
    mov r9, #0
    ldr r0, =C_GREY
    bl  ink
    mov r0, #26
    mov r1, #19
    ldr r2, =str_autooff
    bl  draw_str
3:  mov r0, r5
    tst r0, #0x08                  @ START
    bne menu_go_all
    tst r0, #0x01                  @ A
    bne menu_go_sel
    ldr r1, [r4, #RT_CURSOR]
    tst r0, #0x40                  @ UP
    subne r1, r1, #1
    tst r0, #0x80                  @ DOWN
    addne r1, r1, #1
    cmp r1, #0
    movlt r1, #0
    cmp r1, r10
    subge r1, r10, #1
    str r1, [r4, #RT_CURSOR]
    b   menu_list
menu_go_all:
    mov r0, #0
    ldr r1, =N_CASES
    bl  run_range
    b   summary_view
menu_go_sel:
    ldr r1, [r4, #RT_CURSOR]
    cmp r1, #0
    beq menu_go_all
    sub r1, r1, #1
    ldr r2, =suite_table
    add r2, r2, r1, lsl #3
    str r1, [r4, #RT_VIEW]
    ldr r0, [r2, #4]
    ldr r1, [r2, #12]
    bl  run_range
    b   detail_view_entry
    .ltorg

@ -> r0 = keys newly pressed this frame (active high)
read_keys:
    ldr r2, =0x04000130
    ldrh r0, [r2]
    ldr r1, =0x3FF
    eor r0, r0, r1                 @ pressed = 1
    ldr r2, =RT
    ldr r1, [r2, #RT_KEYS]
    str r0, [r2, #RT_KEYS]
    bic r0, r0, r1
    bx  lr
    .ltorg

@ ───────────────────────────── the run screen ────────────────────────────
draw_run_screen:
    stmfd sp!, {lr}
    bl  clear_screen
    ldr r0, =C_RED
    bl  ink
    mov r0, #0
    mov r1, #0
    ldr r2, =str_running
    bl  draw_str
    bl  draw_verdict
    ldmfd sp!, {pc}
    .ltorg

@ r0 = case index: rows 2-3 say which case is in flight
draw_run_progress:
    stmfd sp!, {r4, r5, lr}
    mov r4, r0
    mov r0, #2
    bl  clear_row
    mov r0, #3
    bl  clear_row
    mov r0, #C_BLACK
    bl  ink
    mov r0, #0
    mov r1, #2
    add r2, r4, #1
    bl  draw_dec
    ldr r2, =str_slash
    mov r1, #2
    bl  draw_str
    ldr r2, =RESULTS
    ldr r2, [r2, #RB_RUNEND]
    mov r1, #2
    bl  draw_dec
    add r0, r0, #1
    mov r5, r0
    mov r0, r4
    bl  suite_name_of
    mov r2, r0
    mov r0, r5
    mov r1, #2
    bl  draw_str
    ldr r2, =case_table
    add r2, r2, r4, lsl #5
    ldr r2, [r2, #CD_NAME]
    mov r0, #2
    mov r1, #3
    bl  draw_str
    ldmfd sp!, {r4, r5, pc}
    .ltorg

@ r0 = case index: the tally on row 5, and a failure goes on the list
draw_case_result:
    stmfd sp!, {r4-r6, lr}
    mov r4, r0
    mov r0, #5
    bl  clear_row
    ldr r5, =RESULTS
    mov r0, #0
    mov r1, #5
    bl  draw_tally
    add r5, r5, #RB_CASES
    add r5, r5, r4, lsl #4
    ldrb r0, [r5]
    cmp r0, #ST_FAIL
    cmpne r0, #ST_TIMEOUT
    cmpne r0, #ST_CRASH
    bne 9f
    ldr r6, =RT
    ldr r0, [r6, #RT_FAILROW]
    cmp r0, #12                    @ rows 7..18: six failures, then wrap
    movhs r0, #0
    add r1, r0, #2
    str r1, [r6, #RT_FAILROW]
    add r0, r0, #7
    mov r1, r4
    bl  draw_case_lines
9:  ldmfd sp!, {r4-r6, pc}
    .ltorg

@ r0 = column, r1 = row: "pass N fail N t/o N crash N skip N" (totals)
draw_tally:
    stmfd sp!, {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    ldr r6, =RESULTS + RB_TOTALS
    ldr r0, =C_GREEN
    bl  ink
    mov r0, r4
    mov r1, r5
    ldr r2, =str_pa
    bl  draw_str
    ldr r2, [r6]
    mov r1, r5
    bl  draw_dec
    mov r7, r0
    ldr r0, =C_RED
    bl  ink
    mov r0, r7
    mov r1, r5
    ldr r2, =str_fl
    bl  draw_str
    ldr r2, [r6, #4]
    mov r1, r5
    bl  draw_dec
    mov r1, r5
    ldr r2, =str_to
    bl  draw_str
    ldr r2, [r6, #8]
    mov r1, r5
    bl  draw_dec
    mov r1, r5
    ldr r2, =str_cr
    bl  draw_str
    ldr r2, [r6, #12]
    mov r1, r5
    bl  draw_dec
    mov r7, r0
    ldr r0, =C_GREY
    bl  ink
    mov r0, r7
    mov r1, r5
    ldr r2, =str_sk
    bl  draw_str
    ldr r2, [r6, #16]
    mov r1, r5
    bl  draw_dec
    ldmfd sp!, {r4-r7, pc}
    .ltorg

@ r0 = row, r1 = case: two rows -- "STATUS suite/name", "  got X exp Y"
draw_case_lines:
    stmfd sp!, {r4-r8, lr}
    mov r4, r0
    mov r5, r1
    ldr r6, =RESULTS + RB_CASES
    add r6, r6, r5, lsl #4
    ldr r7, =case_table
    add r7, r7, r5, lsl #5
    mov r0, r4
    bl  clear_row
    add r0, r4, #1
    bl  clear_row
    ldrb r8, [r6]
    cmp r8, #ST_PASS
    ldreq r0, =C_GREEN
    beq 1f
    cmp r8, #ST_SKIP
    cmpne r8, #ST_NOTRUN
    ldreq r0, =C_GREY
    ldrne r0, =C_RED
1:  bl  ink
    ldr r2, =status_names
    ldr r2, [r2, r8, lsl #2]
    mov r0, #0
    mov r1, r4
    bl  draw_str
    mov r0, #C_BLACK
    bl  ink
    mov r0, r5
    bl  suite_name_of
    mov r2, r0
    mov r0, #8
    mov r1, r4
    bl  draw_str
    ldr r2, =str_slash
    mov r1, r4
    bl  draw_str
    ldr r2, [r7, #CD_NAME]
    mov r1, r4
    bl  draw_str
    cmp r8, #ST_PASS               @ passes and skips need no second row
    cmpne r8, #ST_SKIP
    cmpne r8, #ST_NOTRUN
    beq 9f
    ldr r0, =C_GREY
    bl  ink
    add r1, r4, #1
    mov r0, #0
    ldr r2, =str_gotl
    bl  draw_str
    ldr r0, =C_RED
    bl  ink
    cmp r8, #ST_FAIL
    movne r0, #6
    addne r1, r4, #1
    ldrne r2, =str_dash
    blne draw_str
    bne 2f
    mov r0, #6
    add r1, r4, #1
    ldr r2, [r6, #4]
    mov r3, #8
    bl  draw_hex
2:  ldr r0, =C_GREY
    bl  ink
    mov r0, #14
    add r1, r4, #1
    ldr r2, =str_expl
    bl  draw_str
    mov r0, #C_BLACK
    bl  ink
    ldr r0, [r7, #CD_INFO]
    and r0, r0, #0x0F
    cmp r0, #K_SLOT
    ldreq r2, [r6, #8]
    ldrne r2, [r7, #CD_LO]
    mov r0, #19
    add r1, r4, #1
    mov r3, #8
    bl  draw_hex
    ldr r0, [r7, #CD_INFO]
    and r0, r0, #0x0F
    cmp r0, #K_SLOT
    beq 9f
    ldr r1, [r7, #CD_LO]
    ldr r2, [r7, #CD_HI]
    cmp r1, r2
    beq 9f
    cmp r0, #K_TWO
    ldreq r2, =str_bar
    ldrne r2, =str_dots
    mov r0, #27
    add r1, r4, #1
    bl  draw_str
    ldr r2, [r7, #CD_HI]
    add r1, r4, #1
    mov r3, #8
    mov r8, r0
    mov r0, r8
    bl  draw_hex
9:  ldmfd sp!, {r4-r8, pc}
    .ltorg

@ ──────────────────────────── the summary view ───────────────────────────
summary_view:
    ldr r4, =RT
    mov r0, #0
    str r0, [r4, #RT_CURSOR]
    ldr r0, =0x3FF
    str r0, [r4, #RT_KEYS]
sv_redraw:
    bl  clear_screen
    mov r0, #C_BLACK
    bl  ink
    mov r0, #0
    mov r1, #0
    ldr r2, =str_title
    bl  draw_str
    mov r1, #0
    add r0, r0, #1
    ldr r2, =str_results
    bl  draw_str
    ldr r6, =RESULTS
    ldr r0, [r6, #(RB_TOTALS + 4)]
    ldr r1, [r6, #(RB_TOTALS + 8)]
    orr r0, r0, r1
    ldr r1, [r6, #(RB_TOTALS + 12)]
    orrs r0, r0, r1
    ldreq r0, =C_GREEN
    ldrne r0, =C_RED
    bl  ink
    ldreq r2, =str_ok
    ldrne r2, =str_bad
    mov r0, #18
    mov r1, #0
    bl  draw_str
    mov r0, #0
    mov r1, #1
    bl  draw_tally
    @ one row per suite: "  name   pass/total  fail t/o crash skip"
    ldr r5, =suite_table
    ldr r6, =RESULTS + RB_SUITES
    mov r7, #0
1:  ldr r0, [r5]
    cmp r0, #0
    beq 4f
    ldr r1, [r4, #RT_CURSOR]
    cmp r1, r7
    ldreq r0, =C_BLUE
    ldrne r0, =C_BLACK
    bl  ink
    add r1, r7, #3
    mov r0, #0
    ldr r2, [r4, #RT_CURSOR]
    cmp r2, r7
    mov r2, #'>'
    moveq r1, r1, lsl #3
    bleq draw_char
    mov r0, #2
    add r1, r7, #3
    ldr r2, [r5]
    bl  draw_str
    ldrh r0, [r6, #2]
    ldrh r1, [r6, #4]
    orr r0, r0, r1
    ldrh r1, [r6, #6]
    orrs r0, r0, r1
    ldreq r0, =C_GREEN
    ldrne r0, =C_RED
    bl  ink
    mov r0, #14
    add r1, r7, #3
    ldrh r2, [r6]
    bl  draw_dec
    add r1, r7, #3
    ldr r2, =str_slash
    bl  draw_str
    ldrh r2, [r6, #10]
    ldrh r3, [r6, #8]
    sub r2, r2, r3                 @ run, not skipped
    add r1, r7, #3
    bl  draw_dec
    ldrh r2, [r6, #8]
    cmp r2, #0
    beq 3f
    mov r8, r0
    ldr r0, =C_GREY
    bl  ink
    mov r0, r8
    add r1, r7, #3
    ldr r2, =str_sk
    bl  draw_str
    ldrh r2, [r6, #8]
    add r1, r7, #3
    bl  draw_dec
3:  add r5, r5, #8
    add r6, r6, #16
    add r7, r7, #1
    cmp r7, #15
    blo 1b
4:  mov r10, r7
    @ the first failures, two rows each, under the suite table
    add r9, r7, #4                 @ row
    mov r7, #0                     @ case
    ldr r8, =N_CASES
5:  cmp r7, r8
    bhs 7f
    ldr r0, =RESULTS + RB_CASES
    add r0, r0, r7, lsl #4
    ldrb r0, [r0]
    cmp r0, #ST_FAIL
    cmpne r0, #ST_TIMEOUT
    cmpne r0, #ST_CRASH
    bne 6f
    cmp r9, #18
    bhs 7f
    mov r0, r9
    mov r1, r7
    bl  draw_case_lines
    add r9, r9, #2
6:  add r7, r7, #1
    b   5b
7:  ldr r0, =C_GREY
    bl  ink
    mov r0, #0
    mov r1, #19
    ldr r2, =str_help2
    bl  draw_str
    bl  draw_verdict
sv_loop:
    bl  wait_vblank_link
    bl  read_keys
    cmp r0, #0
    beq sv_loop
    tst r0, #0x02                  @ B
    bne menu
    tst r0, #0x01                  @ A
    bne sv_detail
    ldr r1, [r4, #RT_CURSOR]
    tst r0, #0x40
    subne r1, r1, #1
    tst r0, #0x80
    addne r1, r1, #1
    cmp r1, #0
    movlt r1, #0
    cmp r1, r10
    subge r1, r10, #1
    str r1, [r4, #RT_CURSOR]
    b   sv_redraw
sv_detail:
    ldr r1, [r4, #RT_CURSOR]
    str r1, [r4, #RT_VIEW]
    b   detail_view_entry
    .ltorg

@ ─────────────────────────── the detail view ─────────────────────────────
@ every case of suite RT_VIEW: failures first... no: in table order, two
@ rows each for a failure, one for anything else
detail_view_entry:
    ldr r4, =RT
    mov r0, #0
    str r0, [r4, #RT_SCROLL]
    ldr r0, =0x3FF
    str r0, [r4, #RT_KEYS]
dv_redraw:
    bl  clear_screen
    ldr r0, [r4, #RT_VIEW]
    ldr r5, =suite_table
    add r5, r5, r0, lsl #3
    mov r0, #C_BLACK
    bl  ink
    mov r0, #0
    mov r1, #0
    ldr r2, [r5]
    bl  draw_str
    ldr r0, [r4, #RT_VIEW]
    ldr r6, =RESULTS + RB_SUITES
    add r6, r6, r0, lsl #4
    ldrh r2, [r6]
    mov r0, #14
    mov r1, #0
    bl  draw_dec
    ldr r2, =str_slash
    mov r1, #0
    bl  draw_str
    ldrh r2, [r6, #10]
    mov r1, #0
    bl  draw_dec
    ldr r7, [r5, #4]               @ first case
    ldr r8, [r5, #12]              @ end
    ldr r0, [r4, #RT_SCROLL]
    add r7, r7, r0
    mov r9, #1                     @ row
1:  cmp r7, r8
    bhs 3f
    cmp r9, #18
    bhs 3f
    mov r0, r9
    mov r1, r7
    bl  draw_case_lines
    ldr r0, =RESULTS + RB_CASES
    add r0, r0, r7, lsl #4
    ldrb r0, [r0]
    cmp r0, #ST_FAIL
    cmpne r0, #ST_TIMEOUT
    cmpne r0, #ST_CRASH
    addeq r9, r9, #2
    addne r9, r9, #1
    add r7, r7, #1
    b   1b
3:  ldr r0, =C_GREY
    bl  ink
    mov r0, #0
    mov r1, #19
    ldr r2, =str_help3
    bl  draw_str
    bl  draw_verdict
dv_loop:
    bl  wait_vblank_link
    bl  read_keys
    cmp r0, #0
    beq dv_loop
    tst r0, #0x02                  @ B
    bne summary_view
    ldr r1, [r4, #RT_SCROLL]
    tst r0, #0x40
    subne r1, r1, #1
    tst r0, #0x80
    addne r1, r1, #1
    tst r0, #0x20                  @ LEFT/RIGHT: a page
    subne r1, r1, #8
    tst r0, #0x10
    addne r1, r1, #8
    cmp r1, #0
    movlt r1, #0
    ldr r2, [r4, #RT_VIEW]
    ldr r3, =suite_table
    add r3, r3, r2, lsl #3
    ldr r2, [r3, #12]
    ldr r3, [r3, #4]
    sub r2, r2, r3                 @ cases in the suite
    cmp r1, r2
    subge r1, r2, #1
    str r1, [r4, #RT_SCROLL]
    b   dv_redraw
    .ltorg
