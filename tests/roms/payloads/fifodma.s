@ fifodma.s -- dbsuite copy of the link-rig probe fifodma.s the parent
@ session ran on the AGB SP on 2026-09-24 (the code is unchanged; the
@ source counter lines that were never used are dropped).
@
@ WHAT: when a sound FIFO DMA runs after the timer overflow that requests
@ it.  FIFO A on TM0, DMA1 (sound FIFO, 32-bit, repeat, 4 words EWRAM ->
@ FIFO A).  TM0 starts with reload 0x10000 - k, TM1 (/1) on the next
@ cycle; then n one-cycle NOPs and the CPU reads TM1 (variant 0), or n
@ NOPs, an EWRAM load, then the read (variant 1).
@ WHY: the FIFO request lands a fixed time after the overflow, the 4-word
@ burst takes its share of the NOPs, and a load in flight holds the burst
@ off to its end -- the read tells which side of the burst it fell.
@ PROVENANCE: AGB SP via tools/hwlink (payloadcmp), 2026-09-24, k = 20
@ and 33, n = 10..43; re-recorded by record.py into sp-agb.json.
@
@ r0 bits 0..7 n (index into a NOP sled of 64), bits 8..15 k, bit 16 variant
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
    ldr r1, =0x02004000
    str r1, [r4, #0xBC]            @ DMA1SAD
    ldr r1, =0x040000A0
    str r1, [r4, #0xC0]            @ DMA1DAD
    mov r1, #4
    strh r1, [r4, #0xC4]
    ldr r1, =0xB640
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
    tst r11, #0x10000
    ldr r10, =after_nops
    ldrne r10, =after_nops_ld
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
    .ltorg
