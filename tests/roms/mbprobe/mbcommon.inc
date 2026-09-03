@ mbcommon.inc — shared code: mode-3 text (5x7 glyphs at 2x = 12x16 px,
@ 20 columns x 10 rows, black on white, 6x6 corner marks for photo
@ alignment), hex result pages, keys, timers, and the child side of the
@ send-back link protocol.  Included at the END of every source (after
@ mbprobe.inc at the top).  All routines clobber r0-r3, r12; r4-r11 kept.

    .balign 4                      @ sources end with DEFSTR text

@ ───────────────────────────── video ────────────────────────────────────
vid_init:                          @ mode 3, white, corner marks
    push {r4, lr}
    mov r0, #IOBASE
    ldr r1, =0x0403
    strh r1, [r0]
    ldr r0, =VRAM
    ldr r1, =0x7FFF7FFF
    ldr r2, =19200                 @ 240*160*2/4 words
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    ldr r0, =VRAM
    bl  corner
    ldr r0, =VRAM + 234*2
    bl  corner
    ldr r0, =VRAM + 154*480
    bl  corner
    ldr r0, =VRAM + 154*480 + 234*2
    bl  corner
    pop {r4, pc}

corner:                            @ r0 = top-left pixel address
    mov r1, #6
    mov r3, #FG_COLOR
1:  mov r2, #6
    mov r4, r0
2:  strh r3, [r4], #2
    subs r2, r2, #1
    bne 2b
    add r0, r0, #480
    subs r1, r1, #1
    bne 1b
    bx  lr

draw_char:                         @ r0 col, r1 row, r2 ascii
    push {r4-r9, lr}
    ldr r3, =VRAM
    mov r4, #7680                  @ 16 lines * 480 bytes
    mla r3, r1, r4, r3
    add r3, r3, r0, lsl #3
    add r3, r3, r0, lsl #4         @ + col * 24 bytes (12 px)
    ldr r5, =font_data
    sub r2, r2, #0x20
    cmp r2, #0x40
    movcs r2, #0                   @ out of table -> blank
    add r5, r5, r2, lsl #3
    mov r6, #7
    ldr r9, =FG_COLOR | (FG_COLOR << 16)   @ two pixels per word store
    ldr r12, =BG_COLOR | (BG_COLOR << 16)
1:  ldrb r7, [r5], #1
    mov r4, r3
    mov r8, #5
2:  tst r7, #0x80
    movne r0, r9
    moveq r0, r12
    str r0, [r4]
    str r0, [r4, #480]
    add r4, r4, #4
    mov r7, r7, lsl #1
    subs r8, r8, #1
    bne 2b
    add r3, r3, #960
    subs r6, r6, #1
    bne 1b
    pop {r4-r9, pc}

draw_str:                          @ r0 col, r1 row, r2 ptr, r3 len
    push {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, r3
1:  cmp r7, #0
    beq 2f
    mov r0, r4
    mov r1, r5
    ldrb r2, [r6], #1
    bl  draw_char
    add r4, r4, #1
    sub r7, r7, #1
    b   1b
2:  pop {r4-r7, pc}

draw_hex:                          @ r0 col, r1 row, r2 value, r3 digits
    push {r4-r8, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    sub r8, r3, #1
1:  mov r0, r4
    mov r1, r5
    mov r2, r8, lsl #2
    mov r2, r6, lsr r2
    and r2, r2, #0xF
    cmp r2, #10
    addlt r2, r2, #0x30
    addge r2, r2, #0x37
    bl  draw_char
    add r4, r4, #1
    subs r8, r8, #1
    bpl 1b
    pop {r4-r8, pc}

draw_status:                       @ r0 ptr, r1 len: row 9 from col 1, padded
    push {r4, lr}
    mov r4, r1
    mov r2, r0
    mov r3, r1
    mov r0, #1
    mov r1, #9
    bl  draw_str
    add r4, r4, #1
1:  cmp r4, #19
    bge 2f
    mov r0, r4
    mov r1, #9
    mov r2, #0x20
    bl  draw_char
    add r4, r4, #1
    b   1b
2:  pop {r4, pc}

@ Rows 1-8: "NN" row label (page*8+i) then 8 bytes as 16 hex digits.
draw_page:                         @ r0 page 0..3 (RESULT[page*64..+64])
    push {r4-r7, lr}
    ldr r4, =RESULT
    add r4, r4, r0, lsl #6
    mov r5, r0, lsl #3
    mov r6, #0
1:  mov r0, #0
    add r1, r6, #1
    add r2, r5, r6
    mov r3, #2
    bl  draw_hex
    mov r7, #0
2:  add r0, r7, r7
    add r0, r0, #3
    add r1, r6, #1
    ldrb r2, [r4, r7]
    mov r3, #2
    bl  draw_hex
    add r7, r7, #1
    cmp r7, #8
    bne 2b
    add r4, r4, #8
    add r6, r6, #1
    cmp r6, #8
    bne 1b
    @ "P<n>" at the right of the title row
    mov r0, #17
    mov r1, #0
    mov r2, #0x50
    bl  draw_char
    mov r0, #18
    mov r1, #0
    mov r2, r5, lsr #3
    mov r3, #1
    bl  draw_hex
    pop {r4-r7, pc}

@ ───────────────────────────── input / time ─────────────────────────────
wait_vblank:
    mov r0, #IOBASE
1:  ldrh r1, [r0, #4]
    tst r1, #1
    bne 1b
2:  ldrh r1, [r0, #4]
    tst r1, #1
    beq 2b
    bx  lr

read_keys:                         @ r0 = keys held (active high, 10 bits)
    mov r0, #IOBASE
    add r0, r0, #0x130
    ldrh r0, [r0]
    mvn r0, r0
    mov r0, r0, lsl #22
    mov r0, r0, lsr #22
    bx  lr

wait_press:                        @ r0 mask -> r0 keys newly pressed in mask
    push {r4, r5, lr}
    mov r4, r0
1:  bl  sio_serve
    bl  wait_vblank
    bl  read_keys
    tst r0, r4
    bne 1b                         @ wait for release
2:  bl  sio_serve
    bl  wait_vblank
    bl  read_keys
    ands r5, r0, r4
    beq 2b
    mov r0, r5
    pop {r4, r5, pc}

timer3_init:                       @ TM3 free-running, prescaler 64 = 262144 Hz
    mov r0, #IOBASE
    add r0, r0, #0x100
    mov r1, #0
    str r1, [r0, #0x0C]
    ldr r1, =0x00810000
    str r1, [r0, #0x0C]
    bx  lr

delay:                             @ r0 ticks of 1/262144 s (< 0x8000)
    mov r1, #IOBASE
    add r1, r1, #0x100
    ldrh r2, [r1, #0x0C]
1:  ldrh r3, [r1, #0x0C]
    sub r3, r3, r2
    mov r3, r3, lsl #16
    mov r3, r3, lsr #16
    cmp r3, r0
    blo 1b
    bx  lr

@ ───────────────────────────── cart presence ────────────────────────────
@ 1 if the logo at 0x08000004..0x0800009F equals the copy in this image's
@ own header (which the slave BIOS has already verified against its own).
cart_seated:
    ldr r1, =0x08000004
    ldr r2, =_start + 4
    mov r3, #39
1:  ldr r0, [r1], #4
    ldr r12, [r2], #4
    cmp r0, r12
    movne r0, #0
    bxne lr
    subs r3, r3, #1
    bne 1b
    mov r0, #1
    bx  lr

@ Multiboot: wait for A (default) / B / L before the first cart access,
@ then insist the cart is seated.  Cart-boot twins skip the wait (dingbat
@ presses nothing) and return the keys held at boot.
cart_gate:                         @ -> r0 keys pressed at the gate
.ifdef CARTBOOT
    push {lr}
    bl  read_keys
    pop {pc}
.else
    push {r4, lr}
1:  STATUS_MSG str_insert
    ldr r0, =(KEY_A | KEY_B | KEY_L)
    bl  wait_press
    mov r4, r0
    bl  cart_seated
    cmp r0, #0
    bne 2f
    STATUS_MSG str_nocart
    ldr r0, =0x4000
    bl  delay
    b   1b
2:  STATUS_MSG str_cartok
    mov r0, r4
    pop {r4, pc}
.endif

@ ───────────────────────────── result slot ──────────────────────────────
result_init:                       @ zero RESULT, STATUS=0, record 0xC4/0xC5
    ldr r0, =RESULT
    mov r1, #0
    mov r2, #64
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    ldr r0, =STATUS
    str r1, [r0]
    ldr r0, =RESULT
    ldr r1, =mb_boot_mode
    ldrb r2, [r1]
    strb r2, [r0]
    ldr r1, =mb_slave_id
    ldrb r2, [r1]
    strb r2, [r0, #1]
    bx  lr

@ ───────────────────────────── link (child side) ────────────────────────
@ (r0 = 0x04000120: +0 SIOMULTI0, +8 SIOCNT, +0xA SIOMLT_SEND, +0x14 RCNT)
sio_child_init:                    @ multiplay mode, 115200 (matches the sender)
    mov r0, #IOBASE
    add r0, r0, #0x120
    mov r1, #0
    strh r1, [r0, #0x14]           @ RCNT: SIO mode per SIOCNT
    ldr r1, =0x2003
    strh r1, [r0, #0x08]           @ SIOCNT: multiplay, 115200 baud
    mvn r1, #0
    strh r1, [r0, #0x0A]           @ SIOMLT_SEND
    bx  lr

sio_serve:                         @ answer the parent's last request word
.if IS_CHILD
    mov r0, #IOBASE
    add r0, r0, #0x120
    ldrh r1, [r0]                  @ SIOMULTI0 = parent's data
    mov r2, r1, lsr #8
    cmp r2, #0xAF
    beq 2f
    cmp r2, #0xA0
    bne 3f
    and r1, r1, #0xFF
    ldr r2, =RESULT
    ldrb r2, [r2, r1]
    orr r2, r2, r1, lsl #8
    strh r2, [r0, #0x0A]
    bx  lr
2:  ldr r2, =STATUS
    ldr r2, [r2]
    orr r2, r2, #0xAF00
    strh r2, [r0, #0x0A]
3:
.endif
    bx  lr

@ Final viewer: STATUS=1, page through RESULT with L/R, keep serving the
@ link.  Never returns.  Cart-boot twins cycle a page every 64 frames
@ instead, so dingbat --timeout picks the page.
viewer:
    ldr r0, =STATUS
    mov r1, #1
    str r1, [r0]
    mov r4, #0
1:  mov r0, r4
    bl  draw_page
.ifdef CARTBOOT
    mov r5, #64
2:  bl  wait_vblank
    subs r5, r5, #1
    bne 2b
    add r4, r4, #1
.else
2:  mov r0, #(KEY_L | KEY_R)
    bl  wait_press
    tst r0, #KEY_R
    addne r4, r4, #1
    tst r0, #KEY_L
    subne r4, r4, #1
.endif
    and r4, r4, #3
    b   1b

DEFSTR str_insert, "INSERT CART - A"
DEFSTR str_nocart, "NO CART - RETRY"
DEFSTR str_cartok, "CART OK"
DEFSTR str_done,   "DONE - L/R PAGES"

    .balign 4
    .include "mbfont.inc"
    .ltorg
