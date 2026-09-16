@ blendprobe.s — GBA colour special effects probe (built by blendprobe.py,
@ which also generates every page's tiles, maps and blend registers into
@ blendprobe_gen.inc and documents the method).  This file is only the
@ viewer: upload the palette and tiles once, then on each page change copy
@ the page's four BG maps and write its BLDCNT/BLDALPHA/BLDY under forced
@ blank.
@
@ Layers: BG3 labels (priority 0), BG2 candidate stripes (1, never a blend
@ target), BG0 effect 1st target (2), BG1 2nd target (3). All 8bpp text
@ BGs over one 256-colour palette, char base 0, screen bases 16/20/24/28.

.equ IOBASE,   0x04000000
.equ PALBG,    0x05000000
.equ VRAM,     0x06000000
.equ PAGEVAR,  0x03000000          @ +0 page, +4 previous keys, +8 auto ctr
    .include "blendprobe_equ.inc"  @ NPAGES, NTILES

    .arm
    .section .text
    .global _start
_start:
    b   header_end                 @ 0x00: BIOS jumps here after the logo
    .space 0x9C                    @ 0x04-0x9F: logo (patched by blendprobe.py)
    .space 0x20                    @ 0xA0-0xBF: title/codes (patched)
header_end:
    b   main

main:
    mov r0, #IOBASE                @ IME off; no interrupts are used
    add r2, r0, #0x200
    mov r1, #0
    strh r1, [r2, #0x08]
    mov r1, #0x80                  @ forced blank while uploading
    strh r1, [r0]

    ldr r0, =palette_data          @ palette: 256 hwords
    ldr r1, =PALBG
    mov r2, #256
1:  ldrh r3, [r0], #2
    strh r3, [r1], #2
    subs r2, r2, #1
    bne 1b

    ldr r0, =tile_data             @ tiles: NTILES * 64 bytes (8bpp)
    ldr r1, =VRAM
    ldr r2, =NTILES * 64
1:  ldrb r3, [r0], #1
    strb r3, [r1], #1
    subs r2, r2, #1
    bne 1b

    mov r0, #IOBASE                @ BG0-3 control
    ldr r1, =0x1082                @ BG0: prio 2, 8bpp, screen base 16
    strh r1, [r0, #0x08]
    ldr r1, =0x1483                @ BG1: prio 3, 8bpp, screen base 20
    strh r1, [r0, #0x0A]
    ldr r1, =0x1881                @ BG2: prio 1, 8bpp, screen base 24
    strh r1, [r0, #0x0C]
    ldr r1, =0x1C80                @ BG3: prio 0, 8bpp, screen base 28
    strh r1, [r0, #0x0E]
    mov r1, #0                     @ all scroll offsets zero
    strh r1, [r0, #0x10]
    strh r1, [r0, #0x12]
    strh r1, [r0, #0x14]
    strh r1, [r0, #0x16]
    strh r1, [r0, #0x18]
    strh r1, [r0, #0x1A]
    strh r1, [r0, #0x1C]
    strh r1, [r0, #0x1E]

    ldr r4, =PAGEVAR
    mov r1, #0
    str r1, [r4, #0]
    ldr r1, =0x3FF
    str r1, [r4, #4]
    mov r1, #0
    str r1, [r4, #8]
    mov r0, #0
    bl  show_page

loop:
    bl  wait_vblank
    ldr r4, =PAGEVAR
    ldr r5, [r4, #0]               @ r5 = page
.ifdef AUTOPAGE
    ldr r1, [r4, #8]
    add r1, r1, #1
    cmp r1, #64
    movge r1, #0
    str r1, [r4, #8]
    bne loop
    add r5, r5, #1
    cmp r5, #NPAGES
    movge r5, #0
    b   2f
.else
    mov r0, #IOBASE
    add r0, r0, #0x130
    ldrh r1, [r0]                  @ KEYINPUT, 0 = pressed
    ldr r2, [r4, #4]               @ last frame's KEYINPUT
    str r1, [r4, #4]
    bic r3, r2, r1                 @ newly pressed: released before, pressed now
    tst r3, #0x11                  @ A or RIGHT: next
    bne 3f
    tst r3, #0x22                  @ B or LEFT: previous
    beq loop
    subs r5, r5, #1
    movlt r5, #NPAGES - 1
    b   2f
3:  add r5, r5, #1
    cmp r5, #NPAGES
    movge r5, #0
.endif
2:  str r5, [r4, #0]
    mov r0, r5
    bl  show_page
    b   loop
    .ltorg

@ r0 = page
show_page:
    push {r4-r7, lr}
    mov r7, #IOBASE
    mov r1, #0x80
    strh r1, [r7]                  @ forced blank
    ldr r4, =page_table
    mov r1, #24
    mul r1, r0, r1
    add r4, r4, r1                 @ r4 -> {map0..map3, bldcnt, bldalpha, bldy, 0}
    ldr r5, =VRAM + 0x8000         @ screen base 16
    mov r6, #0
1:  ldr r0, [r4, r6, lsl #2]       @ map pointer for BG r6
    mov r1, r5
    ldr r2, =1024
2:  ldrh r3, [r0], #2
    strh r3, [r1], #2
    subs r2, r2, #1
    bne 2b
    add r5, r5, #0x2000            @ next screen base (+4 blocks)
    add r6, r6, #1
    cmp r6, #4
    bne 1b
    ldrh r1, [r4, #16]
    strh r1, [r7, #0x50]           @ BLDCNT
    ldrh r1, [r4, #18]
    strh r1, [r7, #0x52]           @ BLDALPHA
    ldrh r1, [r4, #20]
    strh r1, [r7, #0x54]           @ BLDY
    ldr r1, =0x0F00                @ mode 0, BG0-3 on
    strh r1, [r7]
    pop {r4-r7, pc}
    .ltorg

@ busy-wait for the start of the next vertical blank
wait_vblank:
    mov r0, #IOBASE
1:  ldrh r1, [r0, #6]
    cmp r1, #160
    beq 1b
2:  ldrh r1, [r0, #6]
    cmp r1, #160
    bne 2b
    bx  lr
    .ltorg

    .include "blendprobe_gen.inc"
