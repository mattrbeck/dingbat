@ Normal-mode (8-bit) link acceptance ROM (dingbat_test --mode=normlinktest,
@ and over TCP via --mode=netlink --link-contract=normal).
@
@ Complements linktest.s (which only covers multi-player mode). Both linked
@ units run this same image and derive their role from a brief multi-mode SI
@ probe (SIOCNT bit 2: 0 = unit 0, 1 = unit 1). Unit 0 becomes the normal-mode
@ MASTER (internal clock); unit 1 the SLAVE (external clock). They then run 16
@ normal 8-bit full-duplex exchanges: the master sends 0xC0|round, the slave
@ answers 0xD0|round. Because the swap is full-duplex, after each round the
@ master's SIODATA8 holds the slave's byte and vice-versa. Each unit records,
@ per round, the byte it RECEIVED -> 0x02000000+2*round, snapshots SIOCNT
@ (internal/external-clock bit) at 0x02000804, counts serial-IRQ flags (IF bit
@ 7, acked each round) at 0x02000808, and finally writes 0x0000CAFE to
@ 0x02000800.
@
@ Build (devkitARM or llvm+binutils):
@   arm-none-eabi-as -mcpu=arm7tdmi -o normlinktest.o normlinktest.s
@   arm-none-eabi-objcopy -O binary normlinktest.o normlinktest.gba
@ Runs headerless under dingbat's HLE BIOS (skip_bios jumps to 0x08000000).

    .arm
    .text
    .global _start
_start:
    b   init

init:
    ldr r4, =0x04000100        @ SIO regs base (LDRH/STRH imm offset is 8-bit)
    ldr r11, =0x04000200       @ IE/IF base (IF = +2)
    ldr r6, =0x02000000        @ received-byte log
    ldr r10, =0x02000800       @ +0 done, +4 SIOCNT snapshot, +8 IRQ count
    mov r0, #0
    str r0, [r10, #0]
    str r0, [r10, #4]
    str r0, [r10, #8]
    strh r0, [r4, #0x34]      @ RCNT = 0: SIO mode from SIOCNT
    @ Probe our cable position in multi mode: SI (bit 2) = 0 on unit 0, 1 on
    @ unit 1. Valid immediately at boot (the driver derives it from our id,
    @ not from the peer), so it is a stable role source before we switch to
    @ normal mode where SI just mirrors the peer's SO.
    ldr r0, =0x2000            @ SIOCNT: multi-player mode, no start
    strh r0, [r4, #0x28]
    ldrh r0, [r4, #0x28]
    mov r7, #0                 @ round counter
    tst r0, #4
    bne slave

@ ---------------- master (unit 0, internal clock) ----------------
master:
    ldr r0, =40000             @ let the slave reach its armed receive loop
1:  subs r0, r0, #1
    bne 1b
    ldr r0, =0x4001            @ normal 8-bit, internal clock, IRQ enable
    strh r0, [r4, #0x28]
    ldrh r0, [r4, #0x28]
    str r0, [r10, #4]          @ role snapshot (internal-clock bit set)
m_loop:
    ldr r0, =0xC0
    orr r0, r0, r7
    strh r0, [r4, #0x2A]      @ SIODATA8 = 0xC0 | round
    mov r0, #0x80
    strh r0, [r11, #2]         @ ack any stale serial IF
    ldr r0, =0x4081            @ IRQ | start | internal clock | normal8
    strh r0, [r4, #0x28]      @ drive the exchange
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

@ ---------------- slave (unit 1, external clock) ----------------
slave:
    ldr r0, =0x4000            @ normal 8-bit, external clock, IRQ enable
    strh r0, [r4, #0x28]
    ldrh r0, [r4, #0x28]
    str r0, [r10, #4]          @ role snapshot (internal-clock bit clear)
s_loop:
    ldr r0, =0xD0
    orr r0, r0, r7
    strh r0, [r4, #0x2A]      @ SIODATA8 = 0xD0 | round (our outgoing byte)
    mov r0, #0x80
    strh r0, [r11, #2]         @ ack any stale serial IF
    ldr r0, =0x4080            @ external clock | IRQ | start: arm & show busy
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

@ Record IF bit 7 (ack it) and the byte we received this round (the peer's
@ word, swapped into our SIODATA8 by the exchange).
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
    ldrh r0, [r4, #0x2A]      @ SIODATA8: low byte holds the received word
    and r0, r0, #0xFF
    strh r0, [r6], #2          @ log received byte
    bx  lr

    .pool
