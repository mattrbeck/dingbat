@ Speculation benchmark ROM (tests/dingbat_test.nim --mode=speclinkbench).
@
@ A LONG, SYMMETRIC multi-mode exchange standing in for a Pokémon Cable Club
@ "all players ready" sync: both units send the SAME cyclic handshake word
@ each round (table[round & 15]: runs of repeats and a few transitions per
@ cycle, like the real 0x961e/0xcafe/0x11/0x00 cadence). Because the
@ responder mirrors the master, an echo-aware predictor gets every round
@ while a "same as last" guess misses every transition. 200 rounds so
@ rollback re-emulation cost compounds.
@
@ Same EWRAM contract as linktest so the harness can hash final state and prove
@ speculation stays bit-identical: SIOMULTI0 -> 0x02000000+2k, SIOMULTI1 ->
@ 0x02000400+2k (200 rounds = 0x190 bytes each, clear of 0x800), IRQ count at
@ 0x02000808, SIOCNT snapshot at 0x02000804, 0x0000CAFE done flag at 0x02000800.
@
@ Build (devkitARM / binutils):
@   arm-none-eabi-as -mcpu=arm7tdmi -o speclinkbench.o speclinkbench.s
@   arm-none-eabi-objcopy -O binary speclinkbench.o speclinkbench.gba

    .arm
    .text
    .global _start
_start:
    b   init

init:
    ldr r4, =0x04000100        @ SIO regs base
    ldr r11, =0x04000200       @ IE/IF base (IF = +2)
    ldr r6, =0x02000000        @ SIOMULTI0 log
    ldr r9, =0x02000400        @ SIOMULTI1 log
    ldr r10, =0x02000800       @ +0 done, +4 SIOCNT snapshot, +8 IRQ count
    ldr r5, =table             @ shared cyclic handshake pattern (link-time offset)
    add r5, r5, #0x08000000    @ ROM runs mapped at 0x08000000; =table is section-relative
    mov r0, #0
    str r0, [r10, #0]
    str r0, [r10, #4]
    str r0, [r10, #8]
    strh r0, [r4, #0x34]      @ RCNT = 0: SIO mode from SIOCNT
    ldr r0, =0x6003
    strh r0, [r4, #0x28]      @ SIOCNT: multi-player, 115200 baud, IRQ enable
    mov r7, #0                 @ round counter
    ldrh r0, [r4, #0x28]
    tst r0, #4                 @ SI: 0 = parent, 1 = child
    bne child

@ ---------------- parent (unit 0, the speculating master) ----------------
parent:
    ldr r0, =40000             @ let the child reach its receive loop
1:  subs r0, r0, #1
    bne 1b
    ldrh r0, [r4, #0x28]      @ snapshot with both units attached & ready
    str r0, [r10, #4]
p_loop:
    and r3, r7, #15
    add r3, r5, r3, lsl #1
    ldrh r8, [r3]
    strh r8, [r4, #0x2A]      @ SIOMLT_SEND = table[round & 15]
    mov r0, #0x80
    strh r0, [r11, #2]         @ ack any stale serial IF
    ldr r0, =0x6083
    strh r0, [r4, #0x28]      @ start the round
p_wait:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    bne p_wait                 @ until busy clears
    bl  log_round
    ldr r0, =8000              @ inter-round gap: child rearms SIOMLT_SEND
2:  subs r0, r0, #1
    bne 2b
    add r7, r7, #1
    cmp r7, #200
    blt p_loop
    b   done

@ ---------------- child (unit 1, the responder) ----------------
child:
    and r3, r7, #15            @ arm round 0 (r7 = 0)
    add r3, r5, r3, lsl #1
    ldrh r8, [r3]
    strh r8, [r4, #0x2A]
c_loop:
c_wait_set:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    beq c_wait_set             @ until busy sets (round running)
    str r0, [r10, #4]          @ snapshot mid-round
c_wait_clr:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    bne c_wait_clr             @ until busy clears (round done)
    bl  log_round
    add r7, r7, #1
    and r3, r7, #15            @ mirror the master: same table word for next round
    add r3, r5, r3, lsl #1
    ldrh r8, [r3]
    strh r8, [r4, #0x2A]
    cmp r7, #200
    blt c_loop

done:
    ldr r0, =0xCAFE
    str r0, [r10, #0]
3:  b 3b

@ Record IF bit 7 (ack it) and the two receive latches for this round.
log_round:
    ldrh r0, [r11, #2]         @ IF
    tst r0, #0x80
    beq 4f
    ldr r1, [r10, #8]
    add r1, r1, #1
    str r1, [r10, #8]          @ serial IRQ flag seen this round
    mov r0, #0x80
    strh r0, [r11, #2]         @ ack
4:
    ldrh r0, [r4, #0x20]      @ SIOMULTI0
    strh r0, [r6], #2
    ldrh r0, [r4, #0x22]      @ SIOMULTI1
    strh r0, [r9], #2
    bx  lr

    .align 2
table:
    .hword 0x961e, 0x961e, 0x961e, 0x961e
    .hword 0xcafe, 0xcafe, 0xcafe
    .hword 0x0011, 0x0011
    .hword 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000

    .pool
