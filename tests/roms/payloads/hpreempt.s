@ payload: where an H-blank DMA preempts a running immediate burst
@
@ DMA1 (immediate, 64 halfwords, source TM0CNT_L fixed, into IWRAM) runs
@ across the H-blank of a parked line; DMA0 (H-blank, one halfword, also
@ TM0CNT_L into IWRAM) takes the bus somewhere inside it. Every unit of
@ DMA1 is one I/O read and one IWRAM write, so its samples step by 2; the
@ unit DMA0 lands in shows where the higher-priority channel got in:
@
@   between DMA1's read and its write:  d0 - s[j] = 1, s[j+1] - d0 = 3
@   between two of DMA1's transfers:    d0 - s[j] = 2, s[j+1] - d0 = 2
@
@ On an AGB SP (2026-09-25, tools/hwlink/r0-agb.json): 2/2 in every cell --
@ between transfers, never between a read and its write; the unit j it
@ lands in matches cell for cell once DMA_PREEMPT_AFTER_READ is off (with it
@ on, 1/3).
@
@ r0 bits 0..3 k (sled), bits 4..11 extra spin counts (4 cycles each)
@ answer: (d0 - s[j]) | (s[j+1] - d0) << 8 | j << 16 | (s[1] - s[0]) << 24;
@         0xFFFFFFFF: DMA0 did not land inside DMA1's samples
    .include "probe.inc"
    .arm
    .text
    .global _start
.equ BUF, 0x03006800
_start:
    probe_enter
    ldr r1, =BUF
    mov r0, #0
    mov r2, #64
1:  strh r0, [r1], #2
    subs r2, r2, #1
    bne 1b
    str r0, [r12, #32]
    add r0, r12, #32
    str r10, [r8]                  @ DMA0SAD = TM0CNT_L
    str r0, [r8, #4]               @ DMA0DAD
    ldr r6, =0xA0000001            @ H-blank, 16-bit, one unit
    str r10, [r8, #12]             @ DMA1SAD = TM0CNT_L
    ldr r0, =BUF
    str r0, [r8, #16]              @ DMA1DAD
    add r2, r8, #20                @ DMA1CNT
    ldr r3, =0x81000040            @ immediate, 16-bit, source fixed, 64
    mov r7, r9, lsr #4
    and r7, r7, #0xFF
    probe_park 50
    probe_timers_start
    probe_dma_arm
    probe_spin 200
    movs r0, r7
    beq 3f
2:  subs r0, r0, #1
    bne 2b
3:  probe_sled
    str r3, [r2]                   @ DMA1 on
    mov r0, r0
    mov r0, r0
    @ find j: s[j] < d0 < s[j+1]
    ldrh r6, [r12, #32]            @ d0
    ldr r1, =BUF
    mov r2, #0
4:  ldrh r3, [r1, #2]
    cmp r3, r6
    bhi 5f
    add r1, r1, #2
    add r2, r2, #1
    cmp r2, #63
    blo 4b
    mvn r0, #0
    b 6f
5:  ldrh r7, [r1]                  @ s[j]
    cmp r7, r6
    mvnhs r0, #0
    bhs 6f
    sub r0, r6, r7
    sub r3, r3, r6
    orr r0, r0, r3, lsl #8
    orr r0, r0, r2, lsl #16
    ldr r1, =BUF
    ldrh r3, [r1]
    ldrh r7, [r1, #2]
    sub r7, r7, r3
    and r7, r7, #0xFF
    orr r0, r0, r7, lsl #24
6:  probe_leave
    probe_data
