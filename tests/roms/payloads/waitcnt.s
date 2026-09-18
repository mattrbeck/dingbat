@ payload: how long do sequential 32-bit reads from the cartridge window take?
@ r0 = the WAITCNT value to set; returns the cycles 64 reads took.
@
@ Runs from IWRAM (32-bit, no waits) so the measurement is the reads and the
@ loop around them, not the cost of fetching itself. The address is past any
@ cartridge, so it reads open bus either way: on the console because nothing
@ is in the slot, in an emulator because it is past the end of the image.
@ Open bus or not, the wait states are the memory controller's, so the cycle
@ count is the thing being compared.
    .arm
    .text
    .global _start

.equ WAITCNT,  0x04000204
.equ TM0CNT_L, 0x04000100
.equ TM0CNT_H, 0x04000102
.equ PROBE,    0x09000000

_start:
    stmfd sp!, {r4-r7, lr}
    ldr r1, =WAITCNT
    strh r0, [r1]

    ldr r1, =TM0CNT_L
    ldr r3, =TM0CNT_H
    mov r2, #0
    strh r2, [r3]                  @ stop
    strh r2, [r1]                  @ count from 0
    ldr r4, =PROBE
    mov r5, #64
    mov r2, #0x80                  @ enable, no prescaler: one tick per cycle
    strh r2, [r3]
1:  ldr r6, [r4], #4
    subs r5, r5, #1
    bne 1b
    ldrh r0, [r1]
    mov r2, #0
    strh r2, [r3]                  @ stop
    ldmfd sp!, {r4-r7, lr}
    bx  lr
