@ mbstub.s -- the multiboot wrapper around dbsuite's body.
@
@ A multiboot image lands at 0x02000000, where dbsuite's cases keep their
@ scratch (and where the link-rig payloads it carries expect it).  So the
@ body is linked at MB_HOME (0x02024000, the top 112 KB of EWRAM) and this
@ stub, entered by the BIOS at 0x020000C0, copies it there -- backwards,
@ since the destination overlaps the source's tail -- and jumps to it.
    .arm
    .text
    .global _start
.equ MB_HOME, 0x02024000

_start:
    b   stub                       @ 0x00
    .space 0x9C                    @ 0x04-0x9F: logo (gbafix)
    .space 0x20                    @ 0xA0-0xBF: title and codes (build.py)
    b   stub                       @ 0xC0: the multiboot entry
    .byte 0, 0                     @ 0xC4/0xC5: boot mode, slave id (BIOS)
    .space 0x1A                    @ 0xC6-0xDF
    b   stub                       @ 0xE0: JOY bus entry
stub:
    mov r0, #0x04000000
    add r0, r0, #0x208
    mov r1, #0
    strh r1, [r0]                  @ IME off
    mov r0, #0x04000000            @ a blue screen: the stub ran (the
    ldr r1, =0x0403                @ body's first screen replaces it)
    strh r1, [r0]
    mov r0, #0x06000000
    ldr r1, =0x7C007C00
    ldr r2, =240 * 160 / 2
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    adr r0, body                   @ PC-relative: the same image also boots
    ldr r3, =BODY_SIZE             @ from a cartridge (0x08000000), which is
    add r1, r0, r3                 @ how an emulator without multiboot runs it
    ldr r2, =MB_HOME
    add r2, r2, r3                 @ copy from the end down
1:  ldr r3, [r1, #-4]!
    str r3, [r2, #-4]!
    cmp r1, r0
    bhi 1b
    ldr pc, =MB_HOME
    .ltorg
    .align 4
body:
    .incbin "body.bin"
    .align 2
body_end:
.equ BODY_SIZE, body_end - body
