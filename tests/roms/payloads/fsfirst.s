@ fsfirst.s -- when does the first 512 Hz length clock land after a
@ SOUNDCNT_X master-on?
@
@ Parked on a V-count match (a fixed cycle), then a j-cycle sled, TM0 start,
@ master on, ch2 NR21/22 = counter 1 (or 2), trigger + length enable, a
@ k-cycle sled, then poll SOUNDCNT_X bit 1 until it falls; answer TM0 then.
@   r0 bits 0..3  k (sled after the trigger: shifts the poll grid)
@      bits 4..7  j (sled before TM0/master-on: shifts the whole sequence)
@      bit  8     counter 2 instead of 1
@      bit  9     skip the master off/on (sound stays on from before)
@ answer: TM0 at the first poll that saw ch2 off (0xFFFF..: cap), | polls << 16
    .include "probe.inc"
    .arm
    .text
    .global _start
_start:
    probe_enter
    mov r3, #0
    strh r3, [r4, #0x84]           @ master off (clears the PSG)
    tst r9, #0x200
    movne r0, #0x80
    strneh r0, [r4, #0x84]         @ bit 9: on already, before the park
    ldr r6, =0xF03F                @ vol 15, counter 64-63 = 1
    tst r9, #0x100
    ldrne r6, =0xF03E              @ counter 2
    ldr r7, =0xC000                @ trigger + length enable
    mov r2, #0x80
    mov r1, r9, lsr #4
    probe_park 50
    and r0, r1, #0x0F              @ j-sled
    rsb r0, r0, #15
    add pc, pc, r0, lsl #2
    mov r0, r0
    .rept 16
    mov r0, r0
    .endr
    str r11, [r10]                 @ TM0 runs
    strh r2, [r4, #0x84]           @ master on (a no-op with bit 9)
    strh r6, [r4, #0x68]
    strh r7, [r4, #0x6C]
    probe_sled
    mov r3, #0
    ldr r2, =0x20000
1:  ldrh r0, [r4, #0x84]
    tst r0, #2
    beq 2f
    add r3, r3, #1
    cmp r3, r2
    blt 1b
2:  ldrh r1, [r10]
    mov r0, #0
    strh r0, [r4, #0x84]           @ master off on the way out
    orr r0, r1, r3, lsl #16
    probe_leave
    probe_data
