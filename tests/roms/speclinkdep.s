@ Speculation SAFETY probe (tests/dingbat_test.nim --mode=speclinkbench).
@
@ Models the one property a real Pokémon trade has that the symmetric benchmark
@ does NOT: the master's OUTGOING word depends on what it just RECEIVED. Here the
@ parent sends acc, and after each round sets acc = (child's word) XOR 1 — so
@ round N's transfer is a function of round N-1's reply. The child streams an
@ independent counter (0x2000|round), so predictions miss and rollbacks fire.
@
@ Under speculation the master predicts the child's reply, keeps running, and
@ SENDS the next transfer built from that prediction; a wrong guess rolls back
@ locally but the wrong transfer is already on the wire. rollback's
@ `round_out == out_word` check must fire here (native) / silently desync
@ (wasm -d:danger). Reproduction of the in-game "link error".
@
@ Same EWRAM contract as linktest (200 rounds): SIOMULTI0 -> 0x02000000+2k,
@ SIOMULTI1 -> 0x02000400+2k, IRQ at 0x02000808, done 0xCAFE at 0x02000800.
@
@ Build: arm-none-eabi-as -mcpu=arm7tdmi -o speclinkdep.o speclinkdep.s
@        arm-none-eabi-objcopy -O binary speclinkdep.o speclinkdep.gba

    .arm
    .text
    .global _start
_start:
    b   init

init:
    ldr r4, =0x04000100
    ldr r11, =0x04000200
    ldr r6, =0x02000000
    ldr r9, =0x02000400
    ldr r10, =0x02000800
    mov r0, #0
    str r0, [r10, #0]
    str r0, [r10, #4]
    str r0, [r10, #8]
    strh r0, [r4, #0x34]      @ RCNT = 0
    ldr r0, =0x6003
    strh r0, [r4, #0x28]      @ SIOCNT: multi, IRQ enable
    mov r7, #0
    ldrh r0, [r4, #0x28]
    tst r0, #4
    bne child

@ ---------------- parent (unit 0, master): out depends on last received ----------
parent:
    ldr r0, =40000
1:  subs r0, r0, #1
    bne 1b
    ldrh r0, [r4, #0x28]
    str r0, [r10, #4]
    ldr r8, =0x1000           @ acc: initial outgoing word (round 0)
p_loop:
    strh r8, [r4, #0x2A]      @ SIOMLT_SEND = acc
    mov r0, #0x80
    strh r0, [r11, #2]
    ldr r0, =0x6083
    strh r0, [r4, #0x28]      @ start round
p_wait:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    bne p_wait
    bl  log_round
    ldrh r0, [r4, #0x22]      @ SIOMULTI1 = child's reply this round
    eor r8, r0, #1            @ acc = received XOR 1  <-- OUTGOING DEPENDS ON RECEIVED
    ldr r0, =8000
2:  subs r0, r0, #1
    bne 2b
    add r7, r7, #1
    cmp r7, #200
    blt p_loop
    b   done

@ ---------------- child (unit 1, responder): independent counter ----------------
child:
    ldr r0, =0x2000           @ arm round 0
    strh r0, [r4, #0x2A]
c_loop:
c_wait_set:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    beq c_wait_set
    str r0, [r10, #4]
c_wait_clr:
    ldrh r0, [r4, #0x28]
    tst r0, #0x80
    bne c_wait_clr
    bl  log_round
    add r7, r7, #1
    ldr r0, =0x2000
    orr r0, r0, r7            @ 0x2000 | round
    strh r0, [r4, #0x2A]
    cmp r7, #200
    blt c_loop

done:
    ldr r0, =0xCAFE
    str r0, [r10, #0]
3:  b 3b

log_round:
    ldrh r0, [r11, #2]
    tst r0, #0x80
    beq 4f
    ldr r1, [r10, #8]
    add r1, r1, #1
    str r1, [r10, #8]
    mov r0, #0x80
    strh r0, [r11, #2]
4:
    ldrh r0, [r4, #0x20]
    strh r0, [r6], #2
    ldrh r0, [r4, #0x22]
    strh r0, [r9], #2
    bx  lr

    .pool
