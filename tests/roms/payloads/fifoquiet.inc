@ quiet: leave no sound-DMA state from a previous run (r3 = 0x04000000,
@ IME off). TM0 stops, any request it left drains, the sound DMAs go off,
@ both FIFOs are reset with the master on, then the master goes off.
    .macro quiet
    mov r0, #0
    add r2, r3, #0x100
    strh r0, [r2, #2]
    mov r1, #200
91: subs r1, r1, #1
    bne 91b
    strh r0, [r3, #0xC6]
    strh r0, [r3, #0xD2]
    mov r1, #50
92: subs r1, r1, #1
    bne 92b
    mov r1, #0x80
    str r1, [r3, #0x84]
    mov r1, #0x8800
    strh r1, [r3, #0x82]
    mov r1, #50
93: subs r1, r1, #1
    bne 93b
    str r0, [r3, #0x80]
    str r0, [r3, #0x84]
    @ every timer's counter to 0 (one left at 0xFFFF overflows the moment it
    @ starts: TIMER_START_OVERFLOW): reload 0, start, stop
    add r2, r3, #0x100
    mov r1, #0x00800000
    str r1, [r2]
    str r1, [r2, #4]
    str r1, [r2, #8]
    str r1, [r2, #12]
    str r0, [r2]
    str r0, [r2, #4]
    str r0, [r2, #8]
    str r0, [r2, #12]
    .endm
