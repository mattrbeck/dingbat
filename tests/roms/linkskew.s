@ Cross-version link-timing reproduction ROM (tests/dingbat_test.nim --mode=linktest).
@
@ Identical to linktest.s EXCEPT the child stages its outgoing SIOMLT_SEND word
@ LATE: only AFTER the round has started (busy bit set), as a partner game
@ whose serial IRQ retires late does (two different Gen-3 games at different
@ cycle offsets). The word is still staged inside the transfer window, so a
@ completion-time latch (link.nim complete_multi) samples the FRESH word
@ (0xB000|round) and the standard linktest contract passes; a start-time
@ latch samples the STALE previous word and FAILS. Regression guard for the
@ cross-version "communication error".
@
@ Build (devkitARM):
@   arm-none-eabi-as -mcpu=arm7tdmi -o linkskew.o linkskew.s
@   arm-none-eabi-objcopy -O binary linkskew.o linkskew.gba

    .arm
    .text
    .global _start
_start:
    b   init

init:
    ldr r4, =0x04000100        @ SIO regs base (LDRH/STRH imm offset is 8-bit)
    ldr r11, =0x04000200       @ IE/IF base (IF = +2)
    ldr r6, =0x02000000        @ SIOMULTI0 log
    ldr r9, =0x02000400        @ SIOMULTI1 log
    ldr r10, =0x02000800       @ +0 done, +4 SIOCNT snapshot, +8 IRQ count
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

@ ---------------- parent (unit 0) ----------------
parent:
    ldr r0, =40000             @ let the child reach its receive loop
1:  subs r0, r0, #1
    bne 1b
    ldrh r0, [r4, #0x28]      @ snapshot with both units attached & ready
    str r0, [r10, #4]
p_loop:
    ldr r0, =0xA000
    orr r0, r0, r7
    strh r0, [r4, #0x2A]      @ SIOMLT_SEND = 0xA000 | round (staged before start)
    mov r0, #0x80
    strh r0, [r11, #2]         @ ack any stale serial IF
    ldr r0, =0x6083
    strh r0, [r4, #0x28]      @ start the round
p_wait:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    bne p_wait                 @ until busy clears
    bl  log_round
    ldr r0, =20000             @ inter-round gap
2:  subs r0, r0, #1
    bne 2b
    add r7, r7, #1
    cmp r7, #16
    blt p_loop
    b   done

@ ---------------- child (unit 1) ----------------
@ Stages round N's answer AFTER the round has started (busy set), i.e. LATE.
child:
c_loop:
c_wait_set:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    beq c_wait_set             @ until busy sets (round N running)
    str r0, [r10, #4]          @ snapshot mid-round (busy bit masked by test)
    ldr r0, =0xB000
    orr r0, r0, r7
    strh r0, [r4, #0x2A]      @ LATE-stage round N's answer, AFTER the round began
c_wait_clr:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    bne c_wait_clr             @ until busy clears (round done)
    bl  log_round
    add r7, r7, #1
    cmp r7, #16
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

    .pool
