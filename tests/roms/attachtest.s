@ Mid-game attach acceptance ROM (dingbat_test --mode=attachtest).
@
@ Unlike linktest.s, which latches its parent/child role ONCE at boot, this
@ ROM re-reads the SI pin on every iteration, so it can be launched with NO
@ cable attached (both units read SI=1 from the no-cable driver and simply
@ wait) and have the link plugged in LATER — exactly the browser's mid-game
@ "link cable detected" attach flow. The harness boots two cores cable-less,
@ lets them spin in the negotiate loop, attaches the lockstep link, and then
@ requires the rounds to complete.
@
@ Once attached, unit 0 reads SI=0 -> becomes the multi-mode parent (sends
@ 0xA000|round); unit 1 reads SI=1 -> stays the child (answers 0xB000|round).
@ The EWRAM contract is identical to linktest.s (0x000+2k / 0x400+2k receive
@ latches, 0x804 SIOCNT role snapshot, 0x808 IRQ count, 0x800 = 0xCAFE done),
@ so the multi-mode checker validates it unchanged.
@
@ Build:
@   arm-none-eabi-as -mcpu=arm7tdmi -o attachtest.o attachtest.s
@   arm-none-eabi-objcopy -O binary attachtest.o attachtest.gba

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
    mov r0, #0
    str r0, [r10, #0]
    str r0, [r10, #4]
    str r0, [r10, #8]
    strh r0, [r4, #0x34]      @ RCNT = 0
    ldr r0, =0x6003            @ SIOCNT: multi-player, 115200 baud, IRQ enable
    strh r0, [r4, #0x28]
    mov r7, #0                 @ round counter (survives across re-negotiation)

@ Re-read our cable position every pass so a cable attached AFTER boot is
@ picked up: SI=0 -> drive as parent, SI=1 -> answer as child. parent_round
@ and child_round branch back here (never `bx lr`) so the only subroutine is
@ the leaf log_round — a nested bl would clobber lr.
negotiate:
    cmp r7, #16
    bge done
    ldrh r0, [r4, #0x28]
    tst r0, #4
    beq parent_round           @ SI=0: parent
    @ SI=1: fall through to child_round

@ ---------------- child (unit 1): answer for the current round ----------------
child_round:
    ldr r0, =0xB000
    orr r0, r0, r7
    strh r0, [r4, #0x2A]      @ SIOMLT_SEND = 0xB000 | round (armed answer)
c_wait_set:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    bne c_wait_clr             @ busy set: the parent started this round
    tst r0, #4
    bne c_wait_set             @ still SI=1 (child, no cable yet): keep waiting
    b   negotiate              @ SI flipped to 0 (cable attached): re-negotiate
c_wait_clr:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    bne c_wait_clr             @ until busy clears (round done)
    bl  log_round
    add r7, r7, #1
    b   negotiate

@ ---------------- parent (unit 0): drive the current round ----------------
parent_round:
    ldr r0, =0xA000
    orr r0, r0, r7
    strh r0, [r4, #0x2A]      @ SIOMLT_SEND = 0xA000 | round
    mov r0, #0x80
    strh r0, [r11, #2]         @ ack any stale serial IF
    ldr r0, =0x6083
    strh r0, [r4, #0x28]      @ start the round
p_wait:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    bne p_wait                 @ until busy clears
    bl  log_round
    ldr r0, =20000             @ inter-round gap: child rearms SIOMLT_SEND
1:  subs r0, r0, #1
    bne 1b
    add r7, r7, #1
    b   negotiate

done:
    ldr r0, =0xCAFE
    str r0, [r10, #0]
3:  b 3b

@ Snapshot SIOCNT role bits (busy clear here), record IF bit 7 (ack it), and
@ the two receive latches for this round.
log_round:
    ldrh r0, [r4, #0x28]
    str r0, [r10, #4]          @ SIOCNT role snapshot (SI/SD/ID)
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
