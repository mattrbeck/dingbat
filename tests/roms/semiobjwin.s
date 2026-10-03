@ semiobjwin.s -- WHAT: does a semi-transparent OBJ pixel alpha-blend with
@ a 2nd-target layer below it inside a window whose colour-special-effect
@ bit is clear?
@
@ HOW: mode 0, one BG and six 64x32 sprites, all drawn with one colour
@ each, in three horizontal bands that differ only in BLDCNT's mode
@ (rewritten by polling VCOUNT in the gaps between bands, so no sprite
@ row sees a write):
@
@   band  rows     sprites at y   BLDCNT
@   1     0-52     8-39           0x0150  alpha:   OBJ 1st, BG0 2nd
@   2     53-106   61-92          0x01D0  darken:  OBJ 1st, BG0 2nd
@   3     107-159  114-145        0x0110  none:    OBJ 1st, BG0 2nd
@
@ BLDALPHA = 0x080C (EVA 12, EVB 8), BLDY = 8.  WIN0 covers columns 60-179
@ on every line with WININ = 0x1F (all layers, effect bit CLEAR); outside
@ it WINOUT = 0x3F (all layers, effect bit SET).  BG0 (priority 3) is solid
@ on even tile rows and transparent on odd ones, so each sprite crosses
@ BG0 (a 2nd target) and the backdrop (not one) in 8-pixel stripes.  In
@ each band the left sprite (x 28-91) is semi-transparent (OBJ mode 1) and
@ straddles WIN0's left edge; the right sprite (x 148-211) is a normal OBJ
@ straddling its right edge.  So every band shows, for each sprite kind,
@ effects-on and effects-off pixels over a 2nd target and over a non-target.
@
@ Colours (BGR555): backdrop 0x4210 (16,16,16), BG0 0x6000 (0,0,24),
@ OBJ 0x0118 (24,8,0); alpha OBJ over BG0 = (18,6,12), OBJ darkened = (12,4,0).
@
@ WHY: the semi-transparent OBJ under an effects-off window is the cell
@ under test (overworld fog in FireRed-engine games); the normal OBJ with
@ OBJ as a 1st target is the control that an effects-off window does stop
@ 1st-target colour math.  docs/playtest-bugs.md, "Semi-transparent OBJ
@ under an effects-off window", records what the two reference emulators
@ draw for every cell; they agree with each other on every pixel, and
@ semiobjwin_expected.png is that frame (the test runner's
@ "dingbat/semiobjwin" row).  tests/roms/semiobjwin.py builds it.
    .arm
    .text
    .global _start
_start:
    b   main
    .space 0x9C                    @ logo, written by gbafix (romfix.py)
    .space 0x20                    @ header, written by semiobjwin.py

main:
    mov r0, #0x04000000
    mov r1, #0x80                  @ forced blank while VRAM is set up
    strh r1, [r0]

    @ palettes: BG 0 = backdrop, BG 1 = BG0 colour, OBJ 1 = sprite colour
    ldr r2, =0x05000000
    ldr r1, =0x4210
    strh r1, [r2]
    ldr r1, =0x6000
    strh r1, [r2, #2]
    ldr r1, =0x0118
    add r3, r2, #0x200
    strh r1, [r3, #2]

    @ BG tiles: tile 0 transparent, tile 1 solid index 1
    ldr r2, =0x06000000
    mov r1, #0
    mov r4, #8
1:  str r1, [r2], #4
    subs r4, r4, #1
    bne 1b
    ldr r1, =0x11111111
    mov r4, #8
1:  str r1, [r2], #4
    subs r4, r4, #1
    bne 1b

    @ BG0 map at screen block 31: tile 1 on even rows, tile 0 on odd rows
    ldr r2, =0x0600F800
    mov r5, #0                     @ row
2:  ands r1, r5, #1
    moveq r1, #1
    movne r1, #0
    orr r1, r1, r1, lsl #16
    mov r4, #16                    @ 32 entries, two per word
1:  str r1, [r2], #4
    subs r4, r4, #1
    bne 1b
    add r5, r5, #1
    cmp r5, #32
    bne 2b

    @ OBJ tiles 0-31 (one 64x32 sprite, 1D mapping): solid index 1
    ldr r2, =0x06010000
    ldr r1, =0x11111111
    mov r4, #256
1:  str r1, [r2], #4
    subs r4, r4, #1
    bne 1b

    @ OAM: hide all 128, then write the six sprites
    ldr r2, =0x07000000
    mov r1, #0x200                 @ attr0 bit 9: disabled
    mov r4, #128
1:  strh r1, [r2], #8
    subs r4, r4, #1
    bne 1b
    ldr r2, =0x07000000
    adr r3, sprites
    mov r4, #6
1:  ldrh r1, [r3], #2
    strh r1, [r2]
    ldrh r1, [r3], #2
    strh r1, [r2, #2]
    mov r1, #0                     @ tile 0, priority 0, palette 0
    strh r1, [r2, #4]
    add r2, r2, #8
    subs r4, r4, #1
    bne 1b

    @ PPU registers
    ldr r1, =0x1F03                @ BG0CNT: priority 3, screen block 31
    strh r1, [r0, #0x08]
    ldr r1, =(60 << 8) | 180       @ WIN0H: columns 60-179
    strh r1, [r0, #0x40]
    mov r1, #160                   @ WIN0V: rows 0-159
    strh r1, [r0, #0x44]
    mov r1, #0x1F                  @ WININ: win0 all layers, no effect
    strh r1, [r0, #0x48]
    mov r1, #0x3F                  @ WINOUT: all layers, effect
    strh r1, [r0, #0x4A]
    ldr r1, =0x080C                @ BLDALPHA: EVA 12, EVB 8
    strh r1, [r0, #0x52]
    mov r1, #8                     @ BLDY
    strh r1, [r0, #0x54]
    ldr r6, =0x0150                @ band 1
    ldr r7, =0x01D0                @ band 2
    ldr r8, =0x0110                @ band 3
    strh r6, [r0, #0x50]
    ldr r1, =0x3140                @ DISPCNT: mode 0, OBJ 1D, BG0, OBJ, WIN0
    strh r1, [r0]

loop:
    mov r1, #53
    bl wait_vcount
    strh r7, [r0, #0x50]
    mov r1, #107
    bl wait_vcount
    strh r8, [r0, #0x50]
    mov r1, #160
    bl wait_vcount
    strh r6, [r0, #0x50]
    b loop

wait_vcount:                       @ spin until VCOUNT == r1
    ldrh r2, [r0, #6]
    cmp r2, r1
    bne wait_vcount
    bx lr

    .align 2
sprites:                           @ attr0, attr1 per sprite
    .hword   8 | (1 << 10) | (1 << 14),  28 | (3 << 14)   @ band 1 semi
    .hword   8 |             (1 << 14), 148 | (3 << 14)   @ band 1 normal
    .hword  61 | (1 << 10) | (1 << 14),  28 | (3 << 14)   @ band 2 semi
    .hword  61 |             (1 << 14), 148 | (3 << 14)   @ band 2 normal
    .hword 114 | (1 << 10) | (1 << 14),  28 | (3 << 14)   @ band 3 semi
    .hword 114 |             (1 << 14), 148 | (3 << 14)   @ band 3 normal
    .ltorg
