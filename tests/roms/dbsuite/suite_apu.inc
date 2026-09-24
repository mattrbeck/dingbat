@ suite_apu.inc -- the PSG: channel 1's sweep unit at trigger and at its
@ ticks, and whose first trigger after a master-on dies.

    suite "apu"

@ ──────────────────────────────── sweep ──────────────────────────────────
@ WHAT: with the PSG on and channel 1 routed, each row programs the sweep,
@ triggers at a chosen frequency, and polls SOUNDCNT_X bit 0 counting
@ iterations until the channel stops (capped at 0x80000).
@ WHY, shift 1 up, limit 2048: period 0 never ticks (survives to the
@ cap, no period-0-acts-as-8); 1400 overflows at the trigger's first check
@ (0); 1300 passes the first check but a SECOND check on the recalculated
@ frequency with the same offset kills it (0); 1000 lives to the first
@ tick, whose written-back 1500 re-check kills it.  Period 2 rows, each
@ after a full APU reset: 512/s1 dies at the THIRD tick (no write-back at
@ trigger, a recalculated second check on the tick path); 2018/s7 survives
@ a second check landing exactly on 2048 (strictly greater kills) and dies
@ at tick 1 (the tick path's check is >= 2048); 940/s1 survives (the
@ trigger's second check reuses the old offset); 2033/s7 dies at trigger.
@ Poll counts jitter, so the tick rows are range-checked at the midpoints
@ between adjacent tick buckets (hardware 0xF75/0xF9A, 0x35CD, 0x0A75,
@ 0x1138, 0x0002).  The poll loop runs from the cartridge, so the ranged
@ rows are cartridge only.
@ PROVENANCE: AGB SP, gbaedge pages 23 SWEEPQ and 31 SWEEP2 (sessions 2-4,
@ photographed); hwverified/sweep.s.
run_sweep:
    push {r4-r8, lr}
    ldr r8, =SLOT
    ldr r4, =0x04000060
    ldr r5, =0x04000080
    mov r0, #0x80
    strh r0, [r5, #4]
    ldr r0, =0x1177
    strh r0, [r5]
.macro sq_run sweep, freq, slot_off
    ldr r0, =\sweep
    strh r0, [r4]
    ldr r0, =0xF000
    strh r0, [r4, #2]
    ldr r0, =0x8000 + \freq
    strh r0, [r4, #4]
    mov r6, #0
    ldr r7, =0x80000
9:  ldrh r0, [r5, #4]
    tst r0, #1
    beq 8f
    add r6, r6, #1
    cmp r6, r7
    blt 9b
8:  str r6, [r8, #\slot_off]
.endm
.macro sq_reset
    mov r0, #0
    strh r0, [r5, #4]
    mov r0, #0x80
    strh r0, [r5, #4]
    ldr r0, =0x1177
    strh r0, [r5]
.endm
    sq_run 0x01, 1024, 0
    sq_run 0x21, 1400, 4
    sq_run 0x21, 1300, 8
    sq_run 0x21, 1000, 12
    sq_reset
    sq_run 0x21, 512, 16
    sq_reset
    sq_run 0x27, 2018, 20
    sq_reset
    sq_run 0x21, 940, 24
    sq_reset
    sq_run 0x27, 2033, 28
    mov r0, #0
    strh r0, [r5, #4]
    pop {r4-r8, pc}
    .ltorg
    cword "sweep-period-0-never-ticks", run_sweep, 0, 0x80000
    cword "sweep-trigger-overflow", RUN_SAME, 4, 0
    cword "sweep-trigger-second-check", RUN_SAME, 8, 0
    crange "sweep-first-tick-rechecks", RUN_SAME, 12, 0xFFFFFFFF, 0x800, 0x1800, F_CART
    crange "sweep-512-dies-tick-3", RUN_SAME, 16, 0xFFFFFFFF, 0x2A00, 0x4000, F_CART
    crange "sweep-2018-survives-2048", RUN_SAME, 20, 0xFFFFFFFF, 0x400, 0x1A00, F_CART
    crange "sweep-940-same-offset", RUN_SAME, 24, 0xFFFFFFFF, 0x400, 0x1A00, F_CART
    crange "sweep-2033-dies-at-trigger", RUN_SAME, 28, 0xFFFFFFFF, 0, 0x200, F_CART

@ ──────────────────────── first trigger after master-on ───────────────────
@ WHAT: tests/roms/payloads/psgfirst.s (gbaedge page 51 PSGFIRST re-hosted,
@ rows unchanged): each channel's first trigger after a SOUNDCNT_X
@ off/on, counter 16, polling until the active bit falls.
@ WHY: channel 1 alone dies at once (0 polls) -- on its first AND second
@ trigger, with NR10 = 0 -- while ch2/3/4 live; NR10 = 0x11 saves it; a
@ trigger with the length counter off never expires (FFFF); SOUNDCNT_X
@ reads 0x80 straight after the dying trigger.  (Later work pinned the
@ cause on the sweep's f + f overflow check at f = 0x400.)  Lifetimes are
@ poll counts that depend on the loop's speed: only "lives" is checked.
@ PROVENANCE: AGB SP, gbaedge page 51 PSGFIRST (session 6, 2026-09-16, CRC
@ 4549; agb-sp-6.txt, run from the cartridge).  The rows checked here are
@ the ones that do not depend on the poll loop's speed.
    payload_blob pl_psgfirst, "psgfirst.bin"
    chalf "psg-ch1-first-trigger-dies", run_payload, 0x100, 0x0000, 0, pl_psgfirst
    crange "psg-ch2-first-trigger-lives", RUN_SAME, 0x102, 0xFFFF, 0x1000, 0xFFFE
    crange "psg-ch3-first-trigger-lives", RUN_SAME, 0x104, 0xFFFF, 0x1000, 0xFFFE
    crange "psg-ch4-first-trigger-lives", RUN_SAME, 0x106, 0xFFFF, 0x1000, 0xFFFE
    chalf "psg-ch1-nr10-0-dies",    RUN_SAME, 0x108, 0x0000
    crange "psg-ch1-sweep-on-lives", RUN_SAME, 0x10A, 0xFFFF, 0x0100, 0xFFFE
    chalf "psg-ch1-second-trigger-dies", RUN_SAME, 0x110, 0x0000
    cbyte "psg-soundcnt-x-after-dying", RUN_SAME, 0x115, 0x80
    chalf "psg-ch1-length-off-lives", RUN_SAME, 0x118, 0xFFFF
