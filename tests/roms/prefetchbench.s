@ prefetchbench.s — times four instruction patterns executed FROM the
@ cartridge, across wait-state settings with the prefetcher on and off.
@
@ This is the case the link cable cannot reach: GBATEK is explicit that the
@ prefetcher only affects opcodes fetched from the gamepak, and a multiboot
@ payload runs from RAM. Here the timed routines are part of the cartridge
@ image, so they are fetched through the prefetcher like a real game's code.
@
@ Subjects:
@   A  straight-line NOPs            - pure sequential fetch
@   B  a two-instruction loop        - a branch, so the burst breaks
@   C  NOPs with a ROM loadevery 8      - the CPU taking the bus off the prefetcher
@   D  multiplies                    - internal cycles, prefetcher runs ahead
@
@ Results: 8 subjects x 4 wait settings, 32 words at 0x02000000, then the
@ marker 0x600D0000 at 0x02000FFC. prefetchbench.py reads them out of an
@ emulator; on a flashcart the same block can be streamed over the link.
@
@ Why it exists: dingbat and mGBA disagree on Thumb code with internal
@ cycles while the prefetcher is on (subject H), by two cycles an
@ instruction, and agree on everything else here. That is the shape of the
@ drift that decides Yu-Gi-Oh's starter deck. Neither emulator is an oracle,
@ so the number that settles it has to come from hardware.
    .arm
    .text
    .global _start

.equ WAITCNT,  0x04000204
.equ TM0CNT_L, 0x04000100
.equ TM0CNT_H, 0x04000102

_start:
    b   main
    .space 0x9C
    .space 0x20
main:
    ldr sp, =0x03007F00
    @ Copy the Thumb multiply block into IWRAM. It uses only immediates, so
    @ it runs anywhere. Timed from there it costs no cartridge fetches at
    @ all, which is the floor any cartridge measurement has to sit above:
    @ internal cycles cannot be overlapped away.
    ldr r0, =subject_h
    ldr r1, =0x03001000
    ldr r2, =subject_h_end
    ldr r3, =subject_h
    sub r2, r2, r3
1:  ldr r4, [r0], #4
    str r4, [r1], #4
    subs r2, r2, #4
    bgt 1b
    ldr r10, =0x02000000           @ where results go
    adr r11, subjects
    mov r9, #0                     @ subject index
subject_loop:
    ldr r8, [r11]                  @ routine
    cmp r8, #0
    beq done
    adr r7, waits
    mov r6, #4                     @ four wait settings each
wait_loop:
    ldr r0, [r7], #4
    ldr r1, =WAITCNT
    strh r0, [r1]

    ldr r4, =TM0CNT_L
    ldr r5, =TM0CNT_H
    mov r0, #0
    strh r0, [r5]                  @ stop
    strh r0, [r4]                  @ count from zero
    mov r0, #0x80                  @ enable, no prescaler: one tick per cycle
    strh r0, [r5]
    mov lr, pc
    bx  r8
    ldrh r0, [r4]
    mov r1, #0
    strh r1, [r5]                  @ stop
    str r0, [r10], #4

    subs r6, r6, #1
    bgt wait_loop
    add r11, r11, #4
    add r9, r9, #1
    b   subject_loop
done:
    ldr r0, =0x02000FFC
    ldr r1, =0x600D0000
    str r1, [r0]
    @ Offer the results to a host on the link cable, so a flashcart run needs
    @ no photograph. With no cable nothing ever completes and this is just a
    @ spin (see linkreport.inc).
    ldr r0, =0x02000000
    mov r1, #(9 * 4)
    bl  link_report_init
1:  bl  link_report_poll
    b   1b
    .ltorg                         @ main's literals, before the timed blocks

    .include "linkreport.inc"

    .align 2
waits:
    .word 0x4014                   @ WS0 3/1, prefetch on
    .word 0x0014                   @ WS0 3/1, prefetch off
    .word 0x4000                   @ WS0 4/2, prefetch on
    .word 0x0000                   @ WS0 4/2, prefetch off
subjects:
    .word subject_a
    .word subject_b
    .word subject_c
    .word subject_d
    .word subject_e + 1            @ +1: entered as Thumb
    .word subject_f + 1
    .word subject_g + 1
    .word subject_h + 1
    .word 0x03001001               @ subject I: subject_h copied into IWRAM
    .word 0

    .align 2
subject_a:                         @ 256 sequential instructions
    .rept 256
    mov r0, r0
    .endr
    bx  lr

    .align 2
subject_b:                         @ 128 iterations of a two-instruction loop
    mov r2, #128
1:  subs r2, r2, #1
    bne 1b
    bx  lr

    .align 2
subject_c:                         @ 32 x (8 instructions + a load from ROM)
    adr r3, subject_c
    .rept 32
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldr r1, [r3]
    .endr
    bx  lr

    .align 2
subject_d:                         @ 64 multiplies: internal cycles throughout
    mov r1, #7
    mov r2, #13
    .rept 64
    mul r0, r1, r2
    .endr
    bx  lr

@ The same four patterns in Thumb. A game's hot code is usually Thumb, and
@ its opcodes are halfwords, which is a different load on the prefetcher.
    .align 2
    .thumb
subject_e:                         @ 256 sequential Thumb instructions
    .rept 256
    mov r0, r0
    .endr
    bx  lr

    .align 2
subject_f:                         @ 128 iterations of a two-instruction loop
    mov r2, #128
1:  sub r2, #1
    bne 1b
    bx  lr

    .align 2
subject_g:                         @ 32 x (8 instructions + a load from ROM)
    ldr r3, =subject_g
    .rept 32
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldr r1, [r3, #0]
    .endr
    bx  lr

    .align 2
subject_h:                         @ 64 multiplies: internal cycles throughout
    mov r1, #7
    mov r2, #13
    .rept 64
    mul r1, r2
    .endr
    bx  lr
subject_h_end:
