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
@ sweep-trigger-second-check: the trigger's second check depends on where
@ the trigger lands in the PSG's 16-cycle (1 MHz) clock.  Over the link rig
@ (tools/hwlink, 2026-09-24, the same rows from IWRAM with a delay loop in
@ 4-cycle steps) the 1300 row dies at the trigger for half the phases -- the
@ delay alternates kill/live every 8 cycles -- and otherwise lives to the
@ first tick (21000-24500 IWRAM polls; 0x10A0, 0x114C and 0x12DF from this
@ ROM's multiboot build on the SP).  A cartridge boot always lands on the
@ same phase, which is why gbaedge and hwverified/sweep photographed 0; a
@ multiboot upload lands anywhere.  So: 0, or death by the first tick.
    crange "sweep-trigger-second-check", RUN_SAME, 8, 0xFFFFFFFF, 0, 0x1800
    crange "sweep-first-tick-rechecks", RUN_SAME, 12, 0xFFFFFFFF, 0x800, 0x1800, F_CART
    crange "sweep-512-dies-tick-3", RUN_SAME, 16, 0xFFFFFFFF, 0x2A00, 0x4000, F_CART
    crange "sweep-2018-survives-2048", RUN_SAME, 20, 0xFFFFFFFF, 0x400, 0x1A00, F_CART
    crange "sweep-940-same-offset", RUN_SAME, 24, 0xFFFFFFFF, 0x400, 0x1A00, F_CART
    crange "sweep-2033-dies-at-trigger", RUN_SAME, 28, 0xFFFFFFFF, 0, 0x200, F_CART

@ ──────────────────────── first trigger after master-on ───────────────────
@ WHAT: gbaedge page 51 PSGFIRST, its rows and macros unchanged: each
@ channel's first trigger after a SOUNDCNT_X off/on, counter 16, polling
@ until the active bit falls (a 16-bit count; FFFF = never fell).
@ WHY: channel 1 alone dies at once (0 polls) -- on its first AND second
@ trigger, with NR10 = 0 -- while ch2/3/4 live; NR10 = 0x11 saves it; a
@ trigger with the length counter off never expires (FFFF); SOUNDCNT_X
@ reads 0x80 straight after the dying trigger.  (Later work pinned the
@ cause on the sweep's f + f overflow check at f = 0x400.)
@ PROVENANCE: AGB SP, gbaedge page 51 PSGFIRST (session 6, 2026-09-16, CRC
@ 4549; agb-sp-6.txt), which ran this code from the cartridge at WAITCNT 0:
@ cartridge only (from RAM the poll loop runs several times faster and the
@ link-rig re-run of the page, psgwhy, saw some rows move).  Lifetimes are
@ checked +-1500 polls around the console's (one 256 Hz length tick is
@ ~1100 polls here); the dying rows, the SOUNDCNT_X reads and the
@ never-expiring rows exactly.
.macro pf_wait ctl, trig, bit
    strh r0, [r4, #\ctl]
    strh r1, [r4, #\trig]
    ldrh r6, [r4, #0x84]
    ldr r2, =0x00060000
    mov r3, #0
1:  ldrh r0, [r4, #0x84]
    tst r0, #\bit
    beq 2f
    add r3, r3, #1
    subs r2, r2, #1
    bne 1b
    add r9, r9, #1
    mvn r3, #0
2:
.endm
.macro pf_reset
    mov r0, #0
    strh r0, [r4, #0x84]
    mov r0, #0x80
    strh r0, [r4, #0x84]
    ldr r0, =0xFF77
    strh r0, [r4, #0x80]
    mov r0, #2
    strh r0, [r4, #0x82]
.endm
run_psgfirst:
    push {r4-r11, lr}
    ldr r8, =SLOT
    mov r4, #IOBASE
    mov r9, #0
    pf_reset
    ldr r0, =0xF0B0                @ envelope 15, duty 2, counter 16
    ldr r1, =0xC400                @ trigger + length enable
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #0]
    strb r6, [r8, #21]
    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x68, 0x6C, 2
    strh r3, [r8, #2]
    strb r6, [r8, #22]
    pf_reset
    mov r0, #0x80                  @ ch3: DAC on, a non-zero wave
    strh r0, [r4, #0x70]
    ldr r0, =0x04000090
    mvn r1, #0
    str r1, [r0, #0]
    str r1, [r0, #4]
    str r1, [r0, #8]
    str r1, [r0, #12]
    ldr r0, =0x20F0
    ldr r1, =0xC000
    pf_wait 0x72, 0x74, 4
    strh r3, [r8, #4]
    pf_reset
    ldr r0, =0xF030
    ldr r1, =0xC000
    pf_wait 0x78, 0x7C, 8
    strh r3, [r8, #6]
    strb r6, [r8, #23]
    pf_reset
    mov r0, #0
    strh r0, [r4, #0x60]           @ NR10 = 0
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #8]
    pf_reset
    mov r0, #0x11                  @ NR10: period 1, shift 1
    strh r0, [r4, #0x60]
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #10]
    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x68, 0x6C, 2          @ ch2 takes the first slot
    strh r3, [r8, #14]
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1          @ ch1 second
    strh r3, [r8, #12]
    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1          @ discarded
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #16]
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #18]
    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0x8000                @ length enable clear
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #24]
    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0x8000
    pf_wait 0x68, 0x6C, 2
    strh r3, [r8, #26]
    mov r0, #0
    strh r0, [r4, #0x84]
    pop {r4-r11, pc}
    .ltorg
    chalf "psg-ch1-first-trigger-dies", run_psgfirst, 0, 0x0000, F_CART
    crange "psg-ch2-first-trigger-lives", RUN_SAME, 2, 0xFFFF, 17758 - 1500, 17758 + 1500, F_CART
    crange "psg-ch3-first-trigger-lives", RUN_SAME, 4, 0xFFFF, 18807 - 1500, 18807 + 1500, F_CART
    crange "psg-ch4-first-trigger-lives", RUN_SAME, 6, 0xFFFF, 18808 - 1500, 18808 + 1500, F_CART
    chalf "psg-ch1-nr10-0-dies",    RUN_SAME, 8, 0x0000, F_CART
    crange "psg-ch1-sweep-running-lives", RUN_SAME, 10, 0xFFFF, 1813 - 900, 1813 + 900, F_CART
    crange "psg-ch1-after-ch2-lives", RUN_SAME, 12, 0xFFFF, 18203 - 1500, 18203 + 1500, F_CART
    crange "psg-ch2-before-ch1-lives", RUN_SAME, 14, 0xFFFF, 18807 - 1500, 18807 + 1500, F_CART
    chalf "psg-ch1-second-trigger-dies", RUN_SAME, 16, 0x0000, F_CART
    crange "psg-ch1-third-trigger-lives", RUN_SAME, 18, 0xFFFF, 18804 - 1500, 18804 + 1500, F_CART
    cbyte "psg-soundcnt-x-after-ch1", RUN_SAME, 21, 0x80, F_CART
    cbyte "psg-soundcnt-x-after-ch2", RUN_SAME, 22, 0x82, F_CART
    cbyte "psg-soundcnt-x-after-ch4", RUN_SAME, 23, 0x88, F_CART
    chalf "psg-ch1-length-off-never-expires", RUN_SAME, 24, 0xFFFF, F_CART
    chalf "psg-ch2-length-off-never-expires", RUN_SAME, 26, 0xFFFF, F_CART
    .include "gen_sp_apu.inc"
