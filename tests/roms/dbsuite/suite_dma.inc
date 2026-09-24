@ suite_dma.inc -- DMA: the CNT_H byte-write anomaly, video-capture DMA,
@ the H-blank DMA's grant against every phase of an instruction, the
@ immediate DMA's start and burst length, and what a DMA reading unmapped
@ memory gets off the data bus.

    suite "dma"

@ ───────────────────────── CNT_H byte writes ──────────────────────────────
@ WHAT: byte writes to DMA3CNT_H.  Each poke primes DMA3 with a valid
@ source, a cleared marker word as destination and 4 units, then reads the
@ marker (did it run?) and CNT_H back.
@ WHY: `strb 0x80` to the UPPER byte mirrors bit 7 into the lower byte too
@ (runs, reads back 0080 once the enable self-clears); `strb 0x80` to the
@ LOWER byte stores nothing.  Only bit 7 mirrors or drops: hi 0xC0 reads
@ 4080 (not 40C0), lo 0xC0 reads 0040 (not 0000).  An emulator with plain
@ byte writes gets every row but the controls wrong.
@ PROVENANCE: AGB SP, gbaedge pages 21 DMAEDGE, 27 IOBYTE, 30 DMABYTE2
@ (sessions 2-4, photographed; the anomaly holds on all four channels);
@ hwverified/dmabyte.s.
run_dmabyte:
    push {r4-r8, lr}
    ldr r8, =SLOT
    ldr r4, =0x040000D4
.macro de_prime
    ldr r0, =db_pattern
    str r0, [r4]
    ldr r5, =EWDST + 0x100
    mov r0, #0
    str r0, [r5]
    str r5, [r4, #4]
    mov r0, #4
    strh r0, [r4, #8]
    mov r0, #0
    strh r0, [r4, #10]
.endm
.macro de_verdict slot_off
    ldr r5, =EWDST + 0x100
    ldr r0, [r5]
    cmp r0, #0
    movne r0, #1
    strb r0, [r8, #\slot_off]
    ldrh r0, [r4, #10]
    strh r0, [r8, #\slot_off + 2]
    mov r0, #0
    strh r0, [r4, #10]
.endm
.macro de_poke val, addr, slot_off
    de_prime
    mov r0, #\val
    ldr r1, =\addr
    strb r0, [r1]
    nop
    nop
    nop
    nop
    de_verdict \slot_off
.endm
    de_poke 0x80, 0x040000DF, 0
    de_poke 0x80, 0x040000DE, 4
    de_poke 0x44, 0x040000DE, 8
    de_poke 0x44, 0x040000DF, 12
    de_poke 0xC0, 0x040000DF, 16
    de_poke 0xC0, 0x040000DE, 20
    de_poke 0x40, 0x040000DF, 24
    pop {r4-r8, pc}
    .ltorg
db_pattern:
    .word 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00
    cbyte "cnth-hi-80-runs",        run_dmabyte, 0, 1
    chalf "cnth-hi-80-reads-0080",  RUN_SAME, 2, 0x0080
    cbyte "cnth-lo-80-no-run",      RUN_SAME, 4, 0
    chalf "cnth-lo-80-stores-nothing", RUN_SAME, 6, 0x0000
    chalf "cnth-lo-44-control",     RUN_SAME, 10, 0x0040
    chalf "cnth-hi-44-control",     RUN_SAME, 14, 0x4400
    cbyte "cnth-hi-c0-runs",        RUN_SAME, 16, 1
    chalf "cnth-hi-c0-bit7-only-mirrors", RUN_SAME, 18, 0x4080
    chalf "cnth-lo-c0-bit7-dropped", RUN_SAME, 22, 0x0040
    cbyte "cnth-hi-40-no-run",      RUN_SAME, 24, 0
    chalf "cnth-hi-40-control",     RUN_SAME, 26, 0x4000

@ ─────────────────────────── capture DMA ──────────────────────────────────
@ WHAT: DMA3 in Special timing (video capture) with repeat, fixed source,
@ into a zeroed 16 KB ring; nonzero words counted after each of three
@ frames, the enable read back; then re-armed at each of three V-blanks.
@ WHY: it runs on every line of every armed frame (160 x 4 words = 0x280)
@ -- no every-other-frame pattern -- and the enable bit clears itself at
@ frame end (0xB700 reads back 0x3700); a re-enable reloads the internal
@ destination from DAD.
@ PROVENANCE: AGB SP, gbaedge page 22 CAPDMA (session 2, CRC F9B7);
@ hwverified/capdma.s.
run_capdma:
    push {r4-r8, lr}
    ldr r8, =SLOT
    ldr r0, =CAPDST
    mov r1, #0x1000
    mov r2, #0
1:  str r2, [r0], #4
    subs r1, r1, #1
    bne 1b
    bl  wait_vblank
    ldr r4, =0x040000D4
    ldr r0, =cap_pattern
    str r0, [r4]
    ldr r0, =CAPDST
    str r0, [r4, #4]
    mov r0, #4
    strh r0, [r4, #8]
    ldr r0, =0xB700
    strh r0, [r4, #10]
    mov r7, #0
2:  bl  wait_vblank
    bl  capdma_count
    str r0, [r8, r7]
    add r7, r7, #4
    cmp r7, #12
    blt 2b
    ldrh r0, [r4, #10]
    strh r0, [r8, #12]
    mov r0, #0
    strh r0, [r4, #10]
    mov r7, #16
2:  bl  wait_vblank
    ldr r0, =0xB700
    strh r0, [r4, #10]
    bl  wait_vblank
    bl  capdma_count
    str r0, [r8, r7]
    add r7, r7, #4
    cmp r7, #28
    blt 2b
    ldrh r0, [r4, #10]
    strh r0, [r8, #28]
    mov r0, #0
    strh r0, [r4, #10]
    pop {r4-r8, pc}
capdma_count:
    ldr r1, =CAPDST
    mov r2, #0x1000
    mov r0, #0
1:  ldr r3, [r1], #4
    cmp r3, #0
    addne r0, r0, #1
    subs r2, r2, #1
    bne 1b
    bx  lr
    .ltorg
cap_pattern:
    .word 0x11223344
    cword "capture-frame-1-every-line", run_capdma, 0, 0x280
    cword "capture-frame-2",        RUN_SAME, 4, 0x280
    cword "capture-frame-3",        RUN_SAME, 8, 0x280
    chalf "capture-enable-self-clears", RUN_SAME, 12, 0x3700
    cword "capture-rearm-1",        RUN_SAME, 16, 0x280
    cword "capture-rearm-2",        RUN_SAME, 20, 0x280
    cword "capture-rearm-3",        RUN_SAME, 24, 0x280
    chalf "capture-rearm-self-clears", RUN_SAME, 28, 0x3700

@ ───────────────────── immediate DMA start and length ─────────────────────
@ WHAT/WHY/PROVENANCE: payloads/dmatime.s -- TM1 read four NOPs after the
@ enable store of an EWRAM->EWRAM DMA3 of N units: 6 + the burst (a 32-bit
@ unit costs 12 EWRAM cycles after the first).  AGB SP, 2026-09-24.
    payload_blob pl_dmatime, "dmatime.bin"
    cpay "imm-dma-none",            pl_dmatime, 0x00000, 6
    cpay "imm-dma-1-word",          pl_dmatime, 0x00001, 20
    cpay "imm-dma-2-words",         pl_dmatime, 0x00002, 32
    cpay "imm-dma-4-words",         pl_dmatime, 0x00004, 56
    cpay "imm-dma-64-words",        pl_dmatime, 0x00040, 776
    cpay "imm-dma-1024-words",      pl_dmatime, 0x00400, 12296
    cpay "imm-dma-4096-words",      pl_dmatime, 0x01000, 49160
    cpay "imm-dma-1-halfword",      pl_dmatime, 0x10001, 14
    cpay "imm-dma-2-halfwords",     pl_dmatime, 0x10002, 20
    cpay "imm-dma-64-halfwords",    pl_dmatime, 0x10040, 392

@ ───────────────── DMA from unmapped memory reads the data bus ─────────────
@ WHAT/WHY/PROVENANCE: payloads/dmaobus.s and dmaobus2.s -- an immediate
@ DMA1 from 0x04001000 (unmapped IO) copies whatever the data bus holds
@ when it starts: the CPU's last load (a 16-bit memory repeats a halfword,
@ a byte fills all four lanes; IWRAM drives only its own lanes) or the
@ last opcode fetch.  AGB SP through the link rig, 2026-09-24.
    payload_blob pl_dmaobus, "dmaobus.bin"
    cpay "unmapped-src-after-ldrsh-odd", pl_dmaobus, 0, 0xFF24FF24
    cpay "unmapped-src-after-ldrh", pl_dmaobus, 1, 0xFF24FF24
    cpay "unmapped-src-after-ldrb", pl_dmaobus, 2, 0xFFFFFFFF
    cpay "unmapped-src-no-load-opcode", pl_dmaobus, 3, 0x46C046C0
    cpay "unmapped-src-after-ldr",  pl_dmaobus, 4, 0x11223344
    payload_blob pl_dmaobus2, "dmaobus2.bin"
    cpay "bus-iw-thumb-adds",       pl_dmaobus2, 0x000, 0x31033104
    cpay "bus-iw-ldrh-lo",          pl_dmaobus2, 0x001, 0x46C03344
    cpay "bus-iw-ldrh-hi",          pl_dmaobus2, 0x002, 0x112246C0
    cpay "bus-iw-ldrb-0",           pl_dmaobus2, 0x003, 0x46C04644
    cpay "bus-iw-ldrb-1",           pl_dmaobus2, 0x004, 0x46C033C0
    cpay "bus-iw-ldrb-2",           pl_dmaobus2, 0x005, 0x462246C0
    cpay "bus-iw-ldrb-3",           pl_dmaobus2, 0x006, 0x11C046C0
    cpay "bus-iw-store-then-fetch", pl_dmaobus2, 0x007, 0x46C046C0
    cpay "bus-iw-ldr",              pl_dmaobus2, 0x008, 0x11223344
    cpay "bus-iw-arm-adds",         pl_dmaobus2, 0x009, 0xE2811004
    cpay "bus-iw-ldrh-ewram",       pl_dmaobus2, 0x00A, 0x55665566
    cpay "bus-iw-arm-ldr",          pl_dmaobus2, 0x00B, 0x11223344
    cpay "bus-iw-arm-ldrh-hi",      pl_dmaobus2, 0x00C, 0x11220000
    cpay "bus-ew-thumb-adds",       pl_dmaobus2, 0x100, 0x31033103
    cpay "bus-ew-ldrh-lo",          pl_dmaobus2, 0x101, 0x46C046C0
    cpay "bus-ew-ldrh-hi",          pl_dmaobus2, 0x102, 0x46C046C0
    cpay "bus-ew-ldrb-0",           pl_dmaobus2, 0x103, 0x46C046C0
    cpay "bus-ew-ldrb-1",           pl_dmaobus2, 0x104, 0x46C046C0
    cpay "bus-ew-ldrb-2",           pl_dmaobus2, 0x105, 0x46C046C0
    cpay "bus-ew-ldrb-3",           pl_dmaobus2, 0x106, 0x46C046C0
    cpay "bus-ew-store-then-fetch", pl_dmaobus2, 0x107, 0x46C046C0
    cpay "bus-ew-ldr",              pl_dmaobus2, 0x108, 0x46C046C0
    cpay "bus-ew-arm-adds",         pl_dmaobus2, 0x109, 0xE2811003
    cpay "bus-ew-ldrh-ewram",       pl_dmaobus2, 0x10A, 0x46C046C0
    cpay "bus-ew-arm-ldr",          pl_dmaobus2, 0x10B, 0xE1A00000
    cpay "bus-ew-arm-ldrh-hi",      pl_dmaobus2, 0x10C, 0xE1A00000

    payload_blob pl_dmaphase, "dmaphase.bin"
    payload_blob pl_kitdemo, "kitdemo.bin"
    .include "gen_dma.inc"
