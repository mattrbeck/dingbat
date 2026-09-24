@ suite_timer.inc -- timers: start latency, back-to-back reads, cascade,
@ reload writes to a running timer, and a read against a stop.

    suite "timer"

@ ─────────────────────────────── TIMERS ──────────────────────────────────
@ WHAT: (a) TM0 at prescaler 1 started, then read twice back to back;
@ (b) TM0 reload FFFC with TM1 cascading, read after a short loop; (c) a
@ reload written to a RUNNING timer, read at once; (d) the same reload
@ written to a stopped timer then started.
@ WHY: the first read sees 7 cycles, the second 0x11 (start latency and
@ read cost from the cartridge); the cascade counts one tick per TM0
@ overflow (TM1 = 0x33, TM0 = FFFC); a reload written mid-run does not
@ latch (0x21) and a restart takes it (0x123B).
@ PROVENANCE: AGB SP, gbaedge page 4 TIMERS (session 1, 2026-08-10, CRC
@ DD91; tests/roms/expected/agb-sp-1.txt bytes +6..+15; the first six
@ bytes, the power-on prescaler phase, depend on everything that ran
@ before and are not reproduced here).  Cycle-exact code from the
@ cartridge at WAITCNT 0: cartridge only.
run_timers:
    push {r4-r8, lr}
    ldr r8, =SLOT
    ldr r4, =0x04000100
    mov r0, #0
    str r0, [r4]
    ldr r0, =0x00800000
    str r0, [r4]
    ldrh r1, [r4]
    ldrh r2, [r4]
    strb r1, [r8, #6]
    strb r2, [r8, #7]
    mov r0, #0
    str r0, [r4]
    ldr r0, =0x0080FFFC            @ TM0: reload FFFC, enable
    ldr r1, =0x00840000            @ TM1: cascade
    str r1, [r4, #4]
    str r0, [r4]
    mov r5, #8
1:  subs r5, r5, #1
    bne 1b
    ldrh r0, [r4, #4]
    strh r0, [r8, #8]
    ldrh r0, [r4]
    strh r0, [r8, #10]
    mov r0, #0
    str r0, [r4]
    str r0, [r4, #4]
    ldr r0, =0x00800000
    str r0, [r4]
    ldr r0, =0x00801234
    str r0, [r4]
    ldrh r1, [r4]
    strh r1, [r8, #12]
    mov r0, #0
    str r0, [r4]
    ldr r0, =0x00801234
    str r0, [r4]
    ldrh r1, [r4]
    strh r1, [r8, #14]
    mov r0, #0
    str r0, [r4]
    pop {r4-r8, pc}
    .ltorg
    cbyte "start-then-read",        run_timers, 6, 0x07, F_CART
    cbyte "second-read",            RUN_SAME, 7, 0x11, F_CART
    chalf "cascade-counts-overflows", RUN_SAME, 8, 0x0033, F_CART
    chalf "cascade-source-reloaded", RUN_SAME, 10, 0xFFFC, F_CART
    chalf "reload-write-running-no-latch", RUN_SAME, 12, 0x0021, F_CART
    chalf "reload-taken-on-start",  RUN_SAME, 14, 0x123B, F_CART

    payload_blob pl_tmrw, "tmrw.bin"
    .include "gen_timer.inc"
    .include "gen_sp_timer.inc"
