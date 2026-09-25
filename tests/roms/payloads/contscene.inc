@ contscene.inc: the scenes contmap.s, c2seq.s and c2code.s measure in.
@ scene_setup: r4 = 0x04000000, r12 = vars ([r12] = the argument,
@ [r12, #20] scratch, [r12, #40] <- the scene's first line). Scene = arg
@ bits 12..15 | bits 20..23 << 4. Writes BG0-3CNT, every BG's HOFS, BLDCNT,
@ identity affine BG2/BG3, OAM (every entry disabled, then the scene's
@ groups from entry 0; affine group 0 identity) and last the scene's
@ DISPCNT; clobbers r0-r3, r6, r7. Call it with the display blanked.
scene_setup:
    ldr r1, [r12, #0]
    mov r0, r1, lsr #12
    and r0, r0, #15
    mov r1, r1, lsr #16
    and r1, r1, #0xF0
    orr r1, r1, r0                 @ scene: bits 12..15, high nibble 20..23
    ldr r2, =scenes
    add r2, r2, r1, lsl #4         @ 16 bytes a scene
    str r2, [r12, #20]
    ldrh r0, [r2, #2]
    strh r0, [r4, #0x08]
    ldrh r0, [r2, #4]
    strh r0, [r4, #0x0A]
    ldrh r0, [r2, #6]
    strh r0, [r4, #0x0C]
    ldrh r0, [r2, #8]
    strh r0, [r4, #0x0E]
    ldrh r0, [r2, #12]             @ HOFS, every BG
    strh r0, [r4, #0x10]
    strh r0, [r4, #0x14]
    strh r0, [r4, #0x18]
    strh r0, [r4, #0x1C]
    mov r0, #0
    strh r0, [r4, #0x12]
    strh r0, [r4, #0x16]
    strh r0, [r4, #0x1A]
    strh r0, [r4, #0x1E]
    ldrh r0, [r2, #14]             @ BLDCNT; non-zero also paints BG VRAM
    strh r0, [r4, #0x50]
    ldr r1, =0x0808
    strh r1, [r4, #0x52]
    cmp r0, #0
    beq 2f
    ldr r0, =0x06000000
    ldr r1, =0x11111111
    mov r3, #0x1000
1:  str r1, [r0], #4
    subs r3, r3, #1
    bne 1b
2:
    mov r0, #0x100                 @ identity affine BG2 and BG3, origin 0
    strh r0, [r4, #0x20]
    strh r0, [r4, #0x26]
    strh r0, [r4, #0x30]
    strh r0, [r4, #0x36]
    mov r0, #0
    strh r0, [r4, #0x22]
    strh r0, [r4, #0x24]
    strh r0, [r4, #0x32]
    strh r0, [r4, #0x34]
    str r0, [r4, #0x28]
    str r0, [r4, #0x2C]
    str r0, [r4, #0x38]
    str r0, [r4, #0x3C]
    @ OAM: every entry disabled, then the scene's groups from entry 0
    ldr r0, =0x07000000
    ldr r1, =0x00000200
    mov r3, #0
    mov r6, #128
1:  str r1, [r0], #4
    str r3, [r0], #4
    subs r6, r6, #1
    bne 1b
    ldr r2, [r12, #20]
    ldrh r3, [r2, #10]             @ OBJ scene; high byte: first line (0 = 40)
    movs r0, r3, lsr #8
    moveq r0, #40
    str r0, [r12, #40]
    and r3, r3, #0xFF
    ldr r1, =objdesc
    ldr r1, [r1, r3, lsl #2]
    ldr r2, =objdesc
    add r1, r1, r2                 @ its groups
    ldr r0, =0x07000000
3:  ldrh r6, [r1]                  @ count
    cmp r6, #0
    beq 5f
    ldrh r2, [r1, #2]              @ attr0
    ldrh r3, [r1, #4]              @ attr1
4:  strh r2, [r0]
    strh r3, [r0, #2]
    ldrh r7, [r1, #6]
    strh r7, [r0, #4]              @ attr2
    ldrh r7, [r1, #8]
    add r2, r2, r7
    ldrh r7, [r1, #10]
    add r3, r3, r7
    add r0, r0, #8
    subs r6, r6, #1
    bne 4b
    add r1, r1, #12
    b   3b
5:  ldr r0, =0x07000000            @ affine group 0: identity
    mov r1, #0x100
    strh r1, [r0, #6]
    strh r1, [r0, #30]
    mov r1, #0
    strh r1, [r0, #14]
    strh r1, [r0, #22]
    ldr r2, [r12, #20]
    ldrh r0, [r2]
    strh r0, [r4]                  @ the scene's DISPCNT

    bx  lr
    .ltorg

    .align 2
@ DISPCNT, BG0CNT..BG3CNT, OBJ scene, HOFS, BLDCNT (16 bytes)
scenes:
    .hword 0x1F40, 0, 0, 0, 0, 1, 0, 0     @ 00 mode 0, BG0-3 + OBJ, 128 OBJs
    .hword 0x1C42, 0, 0, 0, 0, 1, 0, 0     @ 01 mode 2, BG2+3 + OBJ
    .hword 0x0F40, 0, 0, 0, 0, 0, 0, 0     @ 02 mode 0, BG0-3, no OBJ
    .hword 0x1F60, 0, 0, 0, 0, 1, 0, 0     @ 03 mode 0 + OBJ, H-blank free
    .hword 0x1F80, 0, 0, 0, 0, 1, 0, 0     @ 04 forced blank
    .hword 0x1403, 0, 0, 0, 0, 1, 0, 0     @ 05 mode 3 + OBJ
    .hword 0x0140, 0, 0, 0, 0, 0, 0, 0     @ 06 mode 0, BG0 4bpp
    .hword 0x0140, 0x80, 0, 0, 0, 0, 0, 0  @ 07 mode 0, BG0 8bpp
    .hword 0x0340, 0, 0, 0, 0, 0, 0, 0     @ 08 mode 0, BG0+BG1
    .hword 0x0440, 0, 0, 0, 0, 0, 0, 0     @ 09 mode 0, BG2 alone
    .hword 0x1040, 0, 0, 0, 0, 1, 0, 0     @ 0A OBJ alone, 128 OBJs
    .hword 0x0403, 0, 0, 0, 0, 0, 0, 0     @ 0B mode 3, no OBJ
    .hword 0x0040, 0, 0, 0, 0, 0, 0, 0     @ 0C nothing enabled
    .hword 0x0741, 0, 0, 0, 0, 0, 0, 0     @ 0D mode 1, BG0-2
    .hword 0x0404, 0, 0, 0, 0, 0, 0, 0     @ 0E mode 4
    .hword 0x0840, 0, 0, 0, 0, 0, 0, 0     @ 0F mode 0, BG3 alone
    .hword 0x0442, 0, 0, 0, 0, 0, 0, 0     @ 10 mode 2, BG2 alone
    .hword 0x0842, 0, 0, 0, 0, 0, 0, 0     @ 11 mode 2, BG3 alone
    .hword 0x0C42, 0, 0, 0, 0, 0, 0, 0     @ 12 mode 2, BG2+3, no OBJ
    .hword 0x0441, 0, 0, 0, 0, 0, 0, 0     @ 13 mode 1, BG2 alone
    .hword 0x0405, 0, 0, 0, 0, 0, 0, 0     @ 14 mode 5
    .hword 0x0140, 0, 0, 0, 0, 0, 3, 0     @ 15 BG0, HOFS 3
    .hword 0x0140, 0, 0, 0, 0, 0, 7, 0     @ 16 BG0, HOFS 7
    .hword 0x0140, 0, 0, 0, 0, 0, 8, 0     @ 17 BG0, HOFS 8
    .hword 0x0F40, 0x80, 0x80, 0x80, 0x80, 0, 0, 0  @ 18 BG0-3 8bpp
    .hword 0x0140, 0, 0, 0, 0, 0, 0, 0x2041 @ 19 BG0 alpha over backdrop, painted
    .hword 0x0140, 0, 0, 0, 0, 0, 0, 0x2000 @ 1A BG0 painted, no blend
    .hword 0x1040, 0, 0, 0, 0, 0, 0, 0     @ 1B OBJ on, every entry disabled
    .hword 0x1040, 0, 0, 0, 0, 2, 0, 0     @ 1C one 64x64 at entry 0
    .hword 0x1040, 0, 0, 0, 0, 3, 0, 0     @ 1D one 64x64 at entry 127
    .hword 0x1040, 0, 0, 0, 0, 4, 0, 0     @ 1E one 64x64 affine
    .hword 0x1040, 0, 0, 0, 0, 5, 0, 0     @ 1F one 64x64 8bpp
    .hword 0x1040, 0, 0, 0, 0, 6, 0, 0     @ 20 one 32x64
    .hword 0x1040, 0, 0, 0, 0, 7, 0, 0     @ 21 one 64x64 affine double-size
    .hword 0x1040, 0, 0, 0, 0, 8, 0, 0     @ 22 two 64x64
    .hword 0x1040, 0, 0, 0, 0, 9, 0, 0     @ 23 128 enabled, none on the line
    .hword 0x1040, 0, 0, 0, 0, 10, 0, 0    @ 24 entry 0 on the line, 1-127 not
    .hword 0x1040, 0, 0, 0, 0, 11, 0, 0    @ 25 19+1 8bpp 64x64 (Sprite_Last_VRAM_Access)
    .hword 0x1060, 0, 0, 0, 0, 12, 0, 0    @ 26 14+1, H-blank free (..._Free)
    .hword 0x1040, 0, 0, 0, 0, 13, 0, 0    @ 27 one 64x64 at entry 64
    .hword 0x1040, 0, 0, 0, 0, 14, 0, 0    @ 28 four 64x64
    .hword 0x1F40, 0, 0, 0, 0, 0, 0, 0     @ 29 BG0-3 + OBJ on, entries disabled
    .hword 0x1060, 0, 0, 0, 0, 2, 0, 0     @ 2A one 64x64, H-blank free
    .hword 0x1040, 0, 0, 0, 0, 15, 0, 0    @ 2B one 32x64 at X=100
    .hword 0x0140, 0, 0, 0, 0, 0, 5, 0     @ 2C BG0, HOFS 5
    .hword 0x0140, 0, 0, 0, 0, 0, 6, 0     @ 2D BG0, HOFS 6
    .hword 0x0240, 0, 0, 0, 0, 0, 7, 0     @ 2E BG1, HOFS 7
    .hword 0x0140, 0, 0, 0, 0, 0, 1, 0     @ 2F BG0, HOFS 1
    .hword 0x0140, 0x80, 0, 0, 0, 0, 7, 0  @ 30 BG0 8bpp, HOFS 7
    .hword 0x1C42, 0, 0, 0, 0, 2, 0, 0     @ 31 mode 2, BG2+3 + one 64x64 OBJ
    .hword 0x1C42, 0, 0, 0, 0, 0, 0, 0     @ 32 mode 2, BG2+3, OBJ on, none
    .hword 0x1C42, 0, 0, 0, 0, 5, 0, 0     @ 33 mode 2, BG2+3 + one 8bpp OBJ
    .hword 0x1440, 0, 0, 0, 0, 1, 0, 0     @ 34 mode 0 BG2 + 128 OBJs
    .hword 0x1441, 0, 0, 0, 0, 1, 0, 0     @ 35 mode 1 BG2 + 128 OBJs
    .hword 0x1442, 0, 0, 0, 0, 1, 0, 0     @ 36 mode 2 BG2 + 128 OBJs
    .hword 0x1842, 0, 0, 0, 0, 1, 0, 0     @ 37 mode 2 BG3 + 128 OBJs
    .hword 0x0140, 0, 0, 0, 0, 0, 4, 0     @ 38 BG0, HOFS 4
    .hword 0x0140, 0, 0, 0, 0, 0, 2, 0     @ 39 BG0, HOFS 2
    .hword 0x0340, 0, 0, 0, 0, 0, 5, 0     @ 3A BG0+BG1, HOFS 5
    .hword 0x0140, 0x80, 0, 0, 0, 0, 5, 0  @ 3B BG0 8bpp, HOFS 5
    .hword 0x1040, 0, 0, 0, 0, 16 | (161 << 8), 0, 0  @ 3C 128 OBJs at Y=160, lines 161-218
    .hword 0x1040, 0, 0, 0, 0, 1 | (161 << 8), 0, 0   @ 3D 128 OBJs at Y=40, lines 161-218
    .hword 0x1040, 0, 0, 0, 0, 16 | (100 << 8), 0, 0  @ 3E 128 OBJs at Y=160, lines 100-157
    .hword 0x1040, 0, 0, 0, 0, 17 | (158 << 8), 0, 0  @ 3F OBJs at Y=150: line 158 only
    .hword 0x1040, 0, 0, 0, 0, 17 | (159 << 8), 0, 0  @ 40 line 159 only
    .hword 0x1040, 0, 0, 0, 0, 17 | (160 << 8), 0, 0  @ 41 line 160 only
    .hword 0x1040, 0, 0, 0, 0, 18 | (226 << 8), 0, 0  @ 42 OBJs at Y=0: line 226 only
    .hword 0x1040, 0, 0, 0, 0, 18 | (227 << 8), 0, 0  @ 43 line 227 only

    .align 2
objdesc:
    .word od0 - objdesc, od1 - objdesc, od2 - objdesc, od3 - objdesc
    .word od4 - objdesc, od5 - objdesc, od6 - objdesc, od7 - objdesc
    .word od8 - objdesc, od9 - objdesc, od10 - objdesc, od11 - objdesc
    .word od12 - objdesc, od13 - objdesc, od14 - objdesc, od15 - objdesc
    .word od16 - objdesc, od17 - objdesc, od18 - objdesc
@ count, attr0, attr1, attr2, attr0 step, attr1 step
od0:  .hword 0
od1:  .hword 128, 40, 0xC000, 0, 0, 1, 0
od2:  .hword 1, 40, 0xC000, 0, 0, 0, 0
od3:  .hword 127, 0x200, 0, 0, 0, 0
      .hword 1, 40, 0xC000, 0, 0, 0, 0
od4:  .hword 1, 40 | 0x100, 0xC000, 0, 0, 0, 0
od5:  .hword 1, 40 | 0x2000, 0xC000, 0, 0, 0, 0
od6:  .hword 1, 40 | 0x8000, 0xC000, 0, 0, 0, 0
od7:  .hword 1, 40 | 0x300, 0x8000, 0, 0, 0, 0
od8:  .hword 2, 40, 0xC000, 0, 0, 0, 0
od9:  .hword 128, 160, 0xC000, 0, 0, 0, 0
od10: .hword 1, 40, 0xC000, 0, 0, 0
      .hword 127, 160, 0xC000, 0, 0, 0, 0
od11: .hword 19, 0x2028, 0xC000, 0x200, 0, 0
      .hword 1, 0x2028, 0xC040, 0x200, 0, 0
      .hword 108, 0x20A0, 0xC00A, 0x200, 0, 0, 0
od12: .hword 14, 0x2028, 0xC000, 0x200, 0, 0
      .hword 1, 0x2028, 0xC040, 0x200, 0, 0
      .hword 113, 0x20A0, 0xC03A, 0x200, 0, 0, 0
od13: .hword 64, 0x200, 0, 0, 0, 0
      .hword 1, 40, 0xC000, 0, 0, 0, 0
od14: .hword 4, 40, 0xC000, 0, 0, 0, 0
od15: .hword 1, 40 | 0x8000, 0xC064, 0, 0, 0, 0
od16: .hword 128, 160, 0xC000, 0, 0, 1, 0
od17: .hword 128, 150, 0xC000, 0, 0, 1, 0
od18: .hword 128, 0, 0xC000, 0, 0, 1, 0
