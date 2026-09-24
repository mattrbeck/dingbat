@ mbdiag.s -- a multiboot smoke test for the link rig, built by
@ `build.py --diag SIZE OUT [--nostub]`.
@
@ It turns the screen GREEN and then keeps a 32-bit slave transfer armed
@ with 0xDBFF0001 forever: a host clocking the link reads that word on
@ every transfer.  With the stub (the default) it is carried as the body
@ of an image built exactly like dbsuite.mb.gba -- mbstub.s paints the
@ screen blue, copies the body to 0x02024000 and jumps there -- and padded
@ to SIZE bytes, so a failure that depends on the upload's size, or on the
@ stub, shows up on its own.  With --nostub it starts at 0x020000C0 like
@ tests/roms/gbamon.s, padded to SIZE the same way.
    .arm
    .text
    .global _start
_start:
.if NOSTUB
    b   diag                       @ 0x00
    .space 0x9C
    .space 0x20
.endif
diag:
    mov r0, #0x04000000
    add r1, r0, #0x200
    mov r2, #0
    strh r2, [r1, #8]              @ IME off
    ldr r1, =0x0403
    strh r1, [r0]                  @ mode 3, BG2
    mov r0, #0x06000000
    ldr r1, =0x03E003E0            @ green
    ldr r2, =240 * 160 / 2
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    ldr r0, =0x04000134
    mov r1, #0
    strh r1, [r0]                  @ RCNT: serial
    ldr r0, =0x04000120
2:  ldrh r1, [r0, #8]
    tst r1, #0x80                  @ still armed: wait
    bne 2b
    ldr r1, =0xDBFF0001
    str r1, [r0]
    ldr r1, =0x1080                @ 32-bit, external clock, start
    strh r1, [r0, #8]
    b   2b
    .ltorg
    .align 4
    .space PAD
