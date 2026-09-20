@ payload: when does VBlankIntrWait hand control back, to the cycle?
@
@ The mGBA suite's `DMA Prefetch Break` spins a 36-cycle loop from the moment
@ SWI 5 returns until an H-blank DMA catches it some eighty lines later, and
@ its answer moves a whole scanline's worth of iterations for every two
@ cycles that return is early or late. slotexec.s and slotdma.s pinned
@ everything else about that loop on silicon, which leaves this: the path
@ from the V-blank interrupt, through the BIOS's dispatcher and the handler
@ and the BIOS's IntrWait loop, back to the caller. The console runs
@ Nintendo's BIOS and the emulators run their own stand-ins, so it is also the
@ one piece of that row never compared against the real thing.
@
@ Both ends are hardware events. Entry: halt on a V-count match with IME
@ clear (halthb.s), so SWI 5 is always called from the same cycle of the same
@ line. Exit: TM0 is started by the first instruction after SWI 5 returns,
@ and read by the first instruction after a second V-count halt wakes on
@ line 162. T = two lines, less however far into line 160 the return came.
@
@ r0 = how many extra NOPs to run before calling SWI 5 (it must not matter).
@ | 0x100: wait on a V-count match at line 160 instead of on V-blank.
@ +0 + 12*i (w) T, (w) R, (w) H for trials i = 0..5. R and H are a second
@ clock started on the parked line, read just after the return and on entry
@ to the handler: R - H is the way out, H the way in. Handler in IWRAM.
    .arm
    .text
    .global _start
.equ RESULTS, 0x02008000

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str sp, [r12]
    str r0, [r12, #8]
    ldr r4, =0x04000200
    ldrh r1, [r4, #8]
    str r1, [r12, #12]             @ IME
    ldrh r1, [r4]
    str r1, [r12, #16]             @ IE
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #24]             @ the IRQ vector
    mov r3, #0x04000000
    ldrh r2, [r3, #4]
    str r2, [r12, #28]             @ DISPSTAT
    mov r2, #0
    strh r2, [r4, #8]
    adr r2, handler
    str r2, [r1]
    str r2, [r12, #4]
    mov r2, #0
    str r2, [r12, #4]              @ trial index

next:
    ldr r12, =vars
    ldr r6, [r12, #4]
    cmp r6, #6
    bge done
    mov r4, #0x04000000
    add r2, r4, #0x200
    ldr r10, =0x04000100
    mov r1, #0
    strh r1, [r2, #8]              @ IME off
    str r1, [r10]
    str r1, [r10, #12]
    ldr r1, =0x00C3F000            @ TM3: 4096 x 1024 cycles, IRQ -- the watchdog
    str r1, [r10, #12]
    ldr r5, =0x00800000

    mov r0, #100                   @ park on line 100 first
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x44
    strh r0, [r2]
    mvn r0, #0
    strh r0, [r2, #2]
    swi 0x020000
    add r2, r4, #0x200
    ldr r11, =0x04000104
    str r5, [r11]                  @ TM1: a second clock, from the parked line

    ldr r12, =vars
    ldr r0, [r12, #8]
    and r0, r0, #0xFF
    rsb r0, r0, #15
    add pc, pc, r0, lsl #2         @ r0 NOPs of the 16 (it must not matter)
    mov r0, r0
    .rept 16
    mov r0, r0
    .endr

    ldr r0, [r12, #8]
    tst r0, #0x100                 @ | 0x100: wait on a V-count match at line
    moveq r0, #0x08                @ 160 instead -- the same cycle of the same
    ldrne r0, =0xA020              @ line, raised by the other source
    strh r0, [r4, #4]              @ DISPSTAT: V-blank interrupt
    moveq r0, #0x41                @ IE = V-blank, and the watchdog
    movne r0, #0x44
    strh r0, [r2]
    mvn r0, #0
    strh r0, [r2, #2]
    mov r0, #1
    strh r0, [r2, #8]              @ IME on: this one is a real interrupt
    moveq r1, #1
    movne r1, #4
    mov r0, #1
    swi 0x040000                   @ IntrWait(discard, flag)
    str r5, [r10]                  @ TM0 starts on the return
    ldrh r7, [r11]                 @ R: TM1 just after it (mod 65536)

    add r2, r4, #0x200
    mov r0, #0
    strh r0, [r2, #8]              @ IME off again
    mov r0, #162
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x44
    strh r0, [r2]
    mvn r0, #0
    strh r0, [r2, #2]
    swi 0x020000
    ldrh r1, [r10]                 @ T

    ldr r12, =vars
    ldr r5, [r12, #4]
store:
    ldr r4, =RESULTS
    add r4, r4, r5, lsl #3
    add r4, r4, r5, lsl #2         @ 12 bytes a trial
    str r1, [r4]
    str r7, [r4, #4]
    ldr r0, [r12, #20]
    str r0, [r4, #8]               @ H: TM1 as the handler was entered
    ldr r11, =0x04000104
    mov r0, #0
    str r0, [r11]
    add r5, r5, #1
    str r5, [r12, #4]
    b next

@ Called by the BIOS's dispatcher in IRQ mode. Acknowledge, tell IntrWait,
@ return -- the least a handler can do, so what is measured is the BIOS.
handler:
    mov r0, #0x04000000
    add r1, r0, #0x100
    ldrh r1, [r1, #4]              @ H, first thing
    ldr r2, =vars
    str r1, [r2, #20]
    add r0, r0, #0x200
    ldrh r1, [r0, #2]
    tst r1, #0x40
    bne watchdog
    strh r1, [r0, #2]              @ IF
    ldr r2, =0x03007FF8
    ldrh r3, [r2]
    orr r3, r3, r1
    strh r3, [r2]                  @ the BIOS's copy, which IntrWait polls
    bx lr

watchdog:
    mov r1, #0
    strh r1, [r0, #8]
    mvn r1, #0
    strh r1, [r0, #2]
    ldr sp, =0x03007FA0
    msr cpsr_c, #0x1F
    ldr r12, =vars
    ldr sp, [r12]
    ldr r5, [r12, #4]
    ldr r1, =0xFFFF
    b store

done:
    ldr r4, =0x04000200
    mov r1, #0
    strh r1, [r4, #8]
    ldr r7, =0x04000100
    str r1, [r7]
    str r1, [r7, #12]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r1, [r12, #24]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #28]
    mov r3, #0x04000000
    strh r1, [r3, #4]
    ldr r1, [r12, #16]
    strh r1, [r4]
    ldr r1, [r12, #12]
    strh r1, [r4, #8]
    ldr sp, [r12]
    ldr r0, =0x56425754            @ 'VBWT'
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg

vars:
    .space 32
