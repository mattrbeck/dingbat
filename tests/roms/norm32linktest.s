@ Normal-mode (32-bit) link acceptance ROM (dingbat_test --mode=norm32linktest,
@ and over TCP via --mode=netlink --link-contract=normal32).
@
@ Same shape as normlinktest.s but exercises the 32-bit normal transfer path
@ (SIODATA32 swap), a distinct code path from 8-bit in both link.nim
@ (complete_normal, is32 branch) and netcore.nim (WIRE_NORMAL32). Both linked
@ units run this image; role from a brief multi-mode SI probe. Unit 0 is the
@ MASTER (internal clock, sends 0xA5A50000|round); unit 1 the SLAVE (external
@ clock, answers 0x5A5A0000|round). After each full-duplex round the master's
@ SIODATA32 holds the slave's word and vice-versa. Each unit records the
@ 32-bit word it RECEIVED -> 0x02000000+4*round, snapshots SIOCNT (internal-
@ clock bit) at 0x02000804, counts serial-IRQ flags at 0x02000808, and writes
@ 0x0000CAFE to 0x02000800 when done.
@
@ Build:
@   arm-none-eabi-as -mcpu=arm7tdmi -o norm32linktest.o norm32linktest.s
@   arm-none-eabi-objcopy -O binary norm32linktest.o norm32linktest.gba

    .arm
    .text
    .global _start
_start:
    b   init

init:
    ldr r4, =0x04000100        @ SIO regs base (SIODATA32 = +0x20, SIOCNT = +0x28)
    ldr r11, =0x04000200       @ IE/IF base (IF = +2)
    ldr r6, =0x02000000        @ received-word log (32-bit slots)
    ldr r10, =0x02000800       @ +0 done, +4 SIOCNT snapshot, +8 IRQ count
    mov r0, #0
    str r0, [r10, #0]
    str r0, [r10, #4]
    str r0, [r10, #8]
    strh r0, [r4, #0x34]      @ RCNT = 0
    ldr r0, =0x2000            @ SIOCNT: multi-player mode, no start (role probe)
    strh r0, [r4, #0x28]
    ldrh r0, [r4, #0x28]
    mov r7, #0                 @ round counter
    tst r0, #4                 @ SI: 0 = unit 0 (master), 1 = unit 1 (slave)
    bne slave

@ ---------------- master (unit 0, internal clock, 32-bit) ----------------
master:
    ldr r0, =40000
1:  subs r0, r0, #1
    bne 1b
    ldr r0, =0x5001            @ normal 32-bit, internal clock, IRQ enable
    strh r0, [r4, #0x28]
    ldrh r0, [r4, #0x28]
    str r0, [r10, #4]          @ role snapshot (internal-clock bit set)
    ldr r8, =0xA5A50000        @ our outgoing word base
m_loop:
    orr r0, r8, r7
    str r0, [r4, #0x20]        @ SIODATA32 = 0xA5A50000 | round
    mov r0, #0x80
    strh r0, [r11, #2]         @ ack any stale serial IF
    ldr r0, =0x5081            @ IRQ | start | internal clock | normal32
    strh r0, [r4, #0x28]
m_wait:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    bne m_wait                 @ until busy clears
    bl  log_round
    ldr r0, =20000             @ inter-round gap: slave rearms its answer
2:  subs r0, r0, #1
    bne 2b
    add r7, r7, #1
    cmp r7, #16
    blt m_loop
    b   done

@ ---------------- slave (unit 1, external clock, 32-bit) ----------------
slave:
    ldr r0, =0x5000            @ normal 32-bit, external clock, IRQ enable
    strh r0, [r4, #0x28]
    ldrh r0, [r4, #0x28]
    str r0, [r10, #4]          @ role snapshot (internal-clock bit clear)
    ldr r8, =0x5A5A0000        @ our outgoing word base
s_loop:
    orr r0, r8, r7
    str r0, [r4, #0x20]        @ SIODATA32 = 0x5A5A0000 | round
    mov r0, #0x80
    strh r0, [r11, #2]         @ ack any stale serial IF
    ldr r0, =0x5080            @ external clock | IRQ | start: arm & show busy
    strh r0, [r4, #0x28]
s_wait_clr:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    bne s_wait_clr             @ until the master's clock completes the swap
    bl  log_round
    add r7, r7, #1
    cmp r7, #16
    blt s_loop

done:
    ldr r0, =0xCAFE
    str r0, [r10, #0]
3:  b 3b

@ Record IF bit 7 (ack it) and the 32-bit word we received this round.
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
    ldr r0, [r4, #0x20]        @ SIODATA32: the received word
    str r0, [r6], #4           @ log it
    bx  lr

    .pool
