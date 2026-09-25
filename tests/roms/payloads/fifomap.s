@ fifomap.s -- fifodma.s (tests/roms/dbsuite/payloads) with more ways in
@
@ WHAT: the first sound-FIFO DMA bursts after TM0 starts, as fifodma.s
@ measures them (FIFO A on TM0, DMA1 4 words -> FIFO A, TM0 reload
@ 0x10000 - k, TM1 /1 a cycle later, n NOPs, a TM1 read), with the FIFO
@ first given w words by CPU stores, the timers started d NOPs later, a
@ different access before the read, or the burst's source moved.
@ WHY: fifo_dma/fifo_5 (alyosha) stores eight words and still sees a burst
@ on the first overflow; this separates that from the burst's timing.
@ PROVENANCE: AGB SP via tools/hwlink (rig.ask, 3 passes), 2026-09-25.
@ w = 8 words bursts at the first overflow exactly as w = 0 does, where
@ w = 4, 6 and 7 do not: the eighth word leaves the FIFO reading empty.
@ The source bits were measured once (a burst from the empty cartridge
@ slot at WAITCNT 0, incrementing or fixed: 32 cycles, as from EWRAM + 2)
@ and are not in r0table's TABLE: the console stopped answering right after
@ that session.
@
@ r0 bits 0..7 n (a NOP sled of 64), 8..15 k, 16..19 the tail (0 TM1 read,
@ 1 EWRAM load then TM1, 2 VCOUNT, 3 TM0, 4 IWRAM, 5 TM1 twice, 6 EWRAM
@ halfword, 7 DMA1CNT_H, each then TM1), 20..25 d, 26..29 w, bit 30 source
@ in the cartridge slot, bit 31 source fixed
@ answer: TM1 as read
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    mov r4, #0x04000000
    mov r0, #0
    str r0, [r4, #0x100]           @ TM0 off
    str r0, [r4, #0x104]           @ TM1 off
    strh r0, [r4, #0xC6]           @ DMA1 off
    mov r1, #0x80
    strh r1, [r4, #0x84]           @ SOUNDCNT_X: master on
    ldr r1, =0x0B04
    strh r1, [r4, #0x82]           @ SOUNDCNT_H: FIFO A L+R, TM0, reset
    mov r2, r11, lsr #26
    ands r2, r2, #0xF
    beq 2f
    mov r3, #0
1:  str r3, [r4, #0xA0]
    subs r2, r2, #1
    bne 1b
2:
    add r2, r4, #0x200
    mov r1, #0
    strh r1, [r2, #4]              @ WAITCNT 0 (the only safe one for the slot)
    ldr r1, =0x02004000
    tst r11, #0x40000000
    ldrne r1, =0x08004000
    str r1, [r4, #0xBC]            @ DMA1SAD
    ldr r1, =0x040000A0
    str r1, [r4, #0xC0]            @ DMA1DAD
    mov r1, #4
    strh r1, [r4, #0xC4]
    ldr r1, =0xB640
    tst r11, #0x80000000
    orrne r1, r1, #0x100           @ source fixed
    strh r1, [r4, #0xC6]           @ DMA1: on, special, 32-bit, repeat, dst fixed
    @ an empty FIFO requests on the first overflow, which is the point
    and r0, r11, #0xFF             @ n
    rsb r0, r0, #64
    ldr r9, =sled
    add r9, r9, r0, lsl #2         @ enter the sled 64-n NOPs from its end
    and r0, r11, #0xFF00
    mov r0, r0, lsr #8
    rsb r7, r0, #0x10000
    orr r7, r7, #0x00800000        @ TM0: reload, /1, on (no IRQ)
    mov r8, #0x00800000            @ TM1: /1, on
    add r1, r4, #0x100
    ldr r6, =0x02004100
    and r0, r11, #0xF0000
    ldr r10, =tails
    ldr r10, [r10, r0, lsr #14]
    and r0, r11, #0x3F00000
    mov r0, r0, lsr #20
    rsb r0, r0, #64
    ldr r2, =dsled
    add r2, r2, r0, lsl #2
    bx r2
dret:
    mov lr, pc
    b go
    mov r5, r0                     @ TM1
    mov r0, #0
    str r0, [r4, #0x100]
    str r0, [r4, #0x104]
    strh r0, [r4, #0xC6]
    strh r0, [r4, #0x82]
    strh r0, [r4, #0x84]
    mov r0, r5
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
go:
    stmia r1, {r7, r8}             @ TM0, then TM1
    bx r9                          @ into the sled (a branch: fixed cost)
    .align 2
sled:
    .rept 64
    mov r0, r0
    .endr
    bx r10
after_nops:
    ldrh r0, [r1, #4]
    mov pc, lr
after_nops_ld:
    ldr r3, [r6]
    ldrh r0, [r1, #4]
    mov pc, lr
t_keyin:                         @ v2: an IO read that is not a timer, then TM1
    ldrh r3, [r4, #6]
    ldrh r0, [r1, #4]
    mov pc, lr
t_tm0:                           @ v3: TM0 read, then TM1
    ldrh r3, [r1, #0]
    ldrh r0, [r1, #4]
    mov pc, lr
t_iwram:                         @ v4: IWRAM load, then TM1
    ldr r3, [sp]
    ldrh r0, [r1, #4]
    mov pc, lr
t_tm1x2:                         @ v5: TM1 twice, answer first<<16 | second
    ldrh r0, [r1, #4]
    ldrh r3, [r1, #4]
    orr r0, r3, r0, lsl #16
    mov pc, lr
t_ewram16:                       @ v6: EWRAM halfword load, then TM1
    ldrh r3, [r6]
    ldrh r0, [r1, #4]
    mov pc, lr
t_dmacnt:                        @ v7: read DMA1CNT_H (IO, the channel's own), then TM1
    ldrh r3, [r4, #0xC6]
    ldrh r0, [r1, #4]
    mov pc, lr
    .align 2
dsled:
    .rept 64
    mov r0, r0
    .endr
    b dret
    .align 2
tails:
    .word after_nops, after_nops_ld, t_keyin, t_tm0, t_iwram, t_tm1x2, t_ewram16, t_dmacnt
    .ltorg
