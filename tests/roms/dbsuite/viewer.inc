@ viewer.inc -- the cartridge build's screens for someone working the suite
@ by hand: the menu once a key is pressed, the summary and the detail view.
@
@ A screen is drawn as text into RT_VNEXT, 40x20 cells, and vshow paints
@ the cells that differ from the ones on the LCD (RT_VSHOWN).  A cursor
@ move repaints two rows, a scroll repaints the names that changed, and no
@ cell is blanked before it is drawn.
@
@ The run path does not come through here.  Boot, the menu's countdown, the
@ run screen and the cases execute the instructions they did before this
@ file existed, so a run enters every case at the cycle it used to.

.equ C_HILITE, 0x7F14              @ the cursor row's paper

@ r0 = ink; the paper stays (`ink` puts it back to white).  Keeps the flags.
vink:
    ldr r1, =RT
    strh r0, [r1, #RT_INK]
    bx  lr

@ r0 = paper.  Keeps the flags.
vpaper:
    ldr r1, =RT
    strh r0, [r1, #RT_PAPER]
    bx  lr

@ r0 = column, r1 = row, r2 = character, in the current colours (keeps r2)
vput:
    cmp r0, #40
    bxhs lr
    ldr r3, =RT
    ldr r12, [r3, #RT_INK]         @ ink | paper << 16
    cmp r2, #' '
    moveq r12, r12, lsr #16        @ a blank has no ink: blanks compare equal
    moveq r12, r12, lsl #16
    add r3, r3, #RT_VNEXT
    add r1, r1, r1, lsl #2
    add r0, r0, r1, lsl #3         @ row * 40 + column
    add r3, r3, r0, lsl #3
    stmia r3, {r2, r12}
    bx  lr

@ r0 = column, r1 = row, r2 = NUL-terminated string -> r0 = next column
vstr:
    stmfd sp!, {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
1:  ldrb r2, [r6], #1
    cmp r2, #0
    beq 2f
    mov r0, r4
    mov r1, r5
    bl  vput
    add r4, r4, #1
    b   1b
2:  mov r0, r4
    ldmfd sp!, {r4-r6, pc}

@ r0 = column, r1 = row, r2 = value, r3 = digits (hex) -> r0 = next column
vhex:
    stmfd sp!, {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    sub r7, r3, #1
    mov r7, r7, lsl #2
1:  mov r2, r6, lsr r7
    and r2, r2, #0xF
    cmp r2, #10
    addlo r2, r2, #0x30
    addhs r2, r2, #0x37
    mov r0, r4
    mov r1, r5
    bl  vput
    add r4, r4, #1
    subs r7, r7, #4
    bpl 1b
    mov r0, r4
    ldmfd sp!, {r4-r7, pc}

@ r0 = column, r1 = row, r2 = value -> r0 = next column (decimal)
vdec:
    stmfd sp!, {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    bl  sb_reset
    mov r0, r6
    bl  sb_dec
    mov r0, #0
    bl  sb_char
    mov r0, r4
    mov r1, r5
    ldr r2, =RT + RT_SB
    bl  vstr
    ldmfd sp!, {r4-r6, pc}

@ r0 = row: blank it in the current paper
vrow:
    ldr r3, =RT
    ldrh r12, [r3, #RT_PAPER]
    mov r12, r12, lsl #16
    add r3, r3, #RT_VNEXT
    add r0, r0, r0, lsl #2
    add r3, r3, r0, lsl #6         @ 40 cells of 8 bytes a row
    mov r1, #40
    mov r2, #' '
1:  stmia r3!, {r2, r12}
    subs r1, r1, #1
    bne 1b
    bx  lr

@ every cell blank on white
vclear:
    ldr r3, =RT + RT_VNEXT
    mov r1, #800
    mov r2, #' '
    ldr r12, =(C_WHITE << 16)
1:  stmia r3!, {r2, r12}
    subs r1, r1, #1
    bne 1b
    bx  lr
    .ltorg

@ Put the next screen on the LCD: from the top of V-blank, paint each cell
@ that differs from the one showing -- every cell when RT_VSTALE says the
@ pixels are someone else's (the run screen's, the boot menu's).  A cell
@ whose character is 0 is not text and is never painted (the menu's logo).
@ The scan stays ahead of the beam unless most of the screen changed.
vshow:
    stmfd sp!, {r4-r8, r11, lr}
    bl  wait_vblank_link
    ldr r4, =RT
    ldr r11, [r4, #RT_VSTALE]
    mov r0, #0
    str r0, [r4, #RT_VSTALE]
    add r5, r4, #RT_VNEXT
    add r4, r4, #RT_VSHOWN
    ldr r6, =VRAM                  @ the cell's pixels
    mov r7, #20
1:  mov r8, #40
2:  ldmia r5!, {r0, r1}
    ldmia r4, {r2, r3}
    cmp r11, #0
    cmpeq r0, r2
    cmpeq r1, r3
    beq 3f
    stmia r4, {r0, r1}
    cmp r0, #0
    movne r2, r6
    blne vcell
3:  add r4, r4, #8
    add r6, r6, #12
    subs r8, r8, #1
    bne 2b
    add r6, r6, #(480 * 7)
    subs r7, r7, #1
    bne 1b
    bl  draw_verdict               @ it sits in the last cell
    ldmfd sp!, {r4-r8, r11, pc}
    .ltorg

@ r0 = character (lower case drawn upper), r1 = ink | paper << 16, r2 = the
@ cell's first pixel.  Two pixels a store, through a table of the four
@ pairs; a blank is three words a line.
vcell:
    stmfd sp!, {r4-r6, lr}
    mov r3, r1, lsr #16            @ paper
    cmp r0, #' '
    bne 2f
    orr r3, r3, r3, lsl #16
    mov r12, #8
1:  str r3, [r2]
    str r3, [r2, #4]
    str r3, [r2, #8]
    add r2, r2, #480
    subs r12, r12, #1
    bne 1b
    ldmfd sp!, {r4-r6, pc}
2:  eor r1, r1, r3, lsl #16        @ ink
    cmp r0, #'a'
    blo 3f
    cmp r0, #'z'
    subls r0, r0, #0x20
3:  sub r0, r0, #0x20
    cmp r0, #96
    movhs r0, #('?' - 0x20)
    ldr r4, =font_data
    add r4, r4, r0, lsl #3
    sub sp, sp, #16                @ left | right << 16, by the two font bits
    orr r5, r3, r3, lsl #16
    orr r6, r3, r1, lsl #16
    str r5, [sp]
    str r6, [sp, #4]
    orr r5, r1, r3, lsl #16
    orr r6, r1, r1, lsl #16
    str r5, [sp, #8]
    str r6, [sp, #12]
    mov r12, #0xC
    mov r0, #8
4:  ldrb r5, [r4], #1              @ six columns: bits 7..2
    and r6, r12, r5, lsr #4
    ldr r6, [sp, r6]
    str r6, [r2], #4
    and r6, r12, r5, lsr #2
    ldr r6, [sp, r6]
    str r6, [r2], #4
    and r6, r12, r5
    ldr r6, [sp, r6]
    str r6, [r2], #472
    subs r0, r0, #1
    bne 4b
    add sp, sp, #16
    ldmfd sp!, {r4-r6, pc}
    .ltorg

    tally_fn vtally, vstr, vdec
    case_lines_fn vcase_lines, vrow, vstr, vhex

@ -> r0 = keys newly pressed; a d-pad direction held for 20 calls (a third
@ of a second) comes again every third call
vkeys:
    stmfd sp!, {lr}
    bl  read_keys
    ldr r2, =RT
    ldr r1, [r2, #RT_KEYS]
    and r1, r1, #0xF0              @ the d-pad, held
    ldr r3, [r2, #RT_VREPEAT]
    add r3, r3, #1
    tst r0, #0xF0                  @ a new direction starts the wait again
    movne r3, #0
    cmp r1, #0
    moveq r3, #0
    cmp r3, #20
    orrhs r0, r0, r1
    movhs r3, #17
    str r3, [r2, #RT_VREPEAT]
    ldmfd sp!, {pc}
    .ltorg

str_help3v:   .asciz "B back  UP/DOWN  LEFT/RIGHT page"
str_of:       .asciz " of "
    .align 2

@ ───────────────────────────────── menu ──────────────────────────────────
@ The boot menu (runtime.inc) draws itself and counts down as it always
@ has.  Its first key press lands at vmenu_first, and from then on the menu
@ is this one: the same layout, the cursor row on a tinted bar, no
@ countdown.  B in the summary comes back to vmenu.

@ r4 = RT: the menu into the next screen -> r10 = entries
vmenu_fill:
    stmfd sp!, {r5-r7, lr}
    bl  vclear
    ldr r3, =RT + RT_VNEXT         @ the logo's pixels: columns 0-16 of
    mov r0, #0                     @ rows 0-7 are not text
    mov r1, #8
1:  mov r2, #17
2:  str r0, [r3], #8
    subs r2, r2, #1
    bne 2b
    add r3, r3, #(23 * 8)
    subs r1, r1, #1
    bne 1b
    mov r0, #C_BLACK
    bl  ink
    mov r0, #18
    mov r1, #1
    ldr r2, =str_title
    bl  vstr
    ldr r0, =C_GREY
    bl  ink
    mov r0, #26
    mov r1, #1
    ldr r2, =rom_version + 8       @ "1"
    bl  vstr
    mov r0, #18
    mov r1, #3
    ldr r2, =str_sub1
    bl  vstr
    mov r0, #18
    mov r1, #4
    ldr r2, =str_sub2
    bl  vstr
    mov r0, #18
    mov r1, #6
    ldr r2, =str_cartb
    bl  vstr
    @ rows 8..: "run every suite", then the suites
    mov r5, #0                     @ entry
    ldr r6, =suite_table
1:  cmp r5, #0
    beq 2f
    sub r0, r5, #1
    ldr r1, [r6, r0, lsl #3]
    cmp r1, #0
    beq 5f
2:  ldr r0, [r4, #RT_CURSOR]
    cmp r0, r5
    ldreq r0, =C_HILITE
    ldrne r0, =C_WHITE
    bl  vpaper
    add r0, r5, #8
    bl  vrow
    ldr r0, [r4, #RT_CURSOR]
    cmp r0, r5
    ldreq r0, =C_BLUE
    ldrne r0, =C_BLACK
    bl  vink
    moveq r0, #0
    addeq r1, r5, #8
    moveq r2, #'>'
    bleq vput
    cmp r5, #0
    bne 3f
    mov r0, #2
    add r1, r5, #8
    ldr r2, =str_all
    bl  vstr
    ldr r2, =N_CASES
    b   4f
3:  sub r0, r5, #1
    add r7, r6, r0, lsl #3
    mov r0, #2
    add r1, r5, #8
    ldr r2, [r7]
    bl  vstr
    ldr r2, [r7, #12]
    ldr r3, [r7, #4]
    sub r2, r2, r3
4:  mov r0, #24
    add r1, r5, #8
    bl  vdec
    add r1, r5, #8
    ldr r2, =str_cases
    bl  vstr
    add r5, r5, #1
    cmp r5, #11
    blo 1b
5:  mov r10, r5
    ldr r0, =C_GREY
    bl  ink                        @ and white paper again
    mov r0, #0
    mov r1, #19
    ldr r2, =str_help1
    bl  vstr
    ldmfd sp!, {r5-r7, pc}
    .ltorg

vmenu:
    ldr r4, =RT
    mov r0, #0
    str r0, [r4, #RT_CURSOR]
    str r0, [r4, #RT_VREPEAT]
    ldr r0, =0x3FF
    str r0, [r4, #RT_KEYS]
    mov r0, #0                     @ the logo's block, then the text
    mov r1, #0
    mov r2, #102
    mov r3, #64
    ldr r12, =C_WHITE
    bl  fill_rect_c
    mov r0, #4
    mov r1, #4
    bl  draw_logo
    b   vmenu_paint
@ r0 = the boot menu's first keys, r4 = RT, r10 = entries
vmenu_first:
    mov r5, r0
    mov r0, #1                     @ its pixels were not drawn from cells
    str r0, [r4, #RT_VSTALE]
    mov r0, #0
    str r0, [r4, #RT_VREPEAT]
    mov r0, r5
vmenu_key:
    tst r0, #0x08                  @ START
    bne menu_go_all
    tst r0, #0x01                  @ A
    bne menu_go_sel
    ldr r1, [r4, #RT_CURSOR]
    tst r0, #0x40                  @ UP
    subne r1, r1, #1
    tst r0, #0x80                  @ DOWN
    addne r1, r1, #1
    cmp r1, #0
    movlt r1, #0
    cmp r1, r10
    subge r1, r10, #1
    str r1, [r4, #RT_CURSOR]
vmenu_paint:
    bl  vmenu_fill
    bl  vshow
vmenu_loop:
    bl  wait_vblank_link
    bl  vkeys
    cmp r0, #0
    beq vmenu_loop
    b   vmenu_key
    .ltorg

@ ──────────────────────────── the summary view ───────────────────────────
summary_view:                      @ from a run: the LCD holds its screen
    ldr r4, =RT
    mov r0, #1
    str r0, [r4, #RT_VSTALE]
    mov r0, #0
    str r0, [r4, #RT_CURSOR]
sv_enter:                          @ from the detail view, the cursor set
    ldr r4, =RT
    mov r0, #0
    str r0, [r4, #RT_VREPEAT]
    ldr r0, =0x3FF
    str r0, [r4, #RT_KEYS]
sv_redraw:
    bl  vclear
    mov r0, #C_BLACK
    bl  ink
    mov r0, #0
    mov r1, #0
    ldr r2, =str_title
    bl  vstr
    mov r1, #0
    add r0, r0, #1
    ldr r2, =str_results
    bl  vstr
    ldr r6, =RESULTS
    ldr r0, [r6, #(RB_TOTALS + 4)]
    ldr r1, [r6, #(RB_TOTALS + 8)]
    orr r0, r0, r1
    ldr r1, [r6, #(RB_TOTALS + 12)]
    orrs r0, r0, r1
    ldreq r0, =C_GREEN
    ldrne r0, =C_RED
    bl  ink
    ldreq r2, =str_ok
    ldrne r2, =str_bad
    mov r0, #18
    mov r1, #0
    bl  vstr
    mov r0, #0
    mov r1, #1
    bl  vtally
    @ one row per suite: "  name   pass/run  skip N"
    ldr r5, =suite_table
    ldr r6, =RESULTS + RB_SUITES
    mov r7, #0
1:  ldr r0, [r5]
    cmp r0, #0
    beq 4f
    ldr r1, [r4, #RT_CURSOR]
    cmp r1, r7
    ldreq r0, =C_HILITE
    ldrne r0, =C_WHITE
    bl  vpaper
    add r0, r7, #3
    bl  vrow
    ldr r1, [r4, #RT_CURSOR]
    cmp r1, r7
    ldreq r0, =C_BLUE
    ldrne r0, =C_BLACK
    bl  vink
    moveq r0, #0
    addeq r1, r7, #3
    moveq r2, #'>'
    bleq vput
    mov r0, #2
    add r1, r7, #3
    ldr r2, [r5]
    bl  vstr
    ldrh r0, [r6, #2]
    ldrh r1, [r6, #4]
    orr r0, r0, r1
    ldrh r1, [r6, #6]
    orrs r0, r0, r1
    ldrne r0, =C_RED
    bne 2f
    ldrh r0, [r6]                  @ no pass either: it has not run
    cmp r0, #0
    ldrne r0, =C_GREEN
    ldreq r0, =C_GREY
2:  bl  vink
    mov r0, #14
    add r1, r7, #3
    ldrh r2, [r6]
    bl  vdec
    add r1, r7, #3
    ldr r2, =str_slash
    bl  vstr
    ldrh r2, [r6, #10]
    ldrh r3, [r6, #8]
    sub r2, r2, r3                 @ run, not skipped
    add r1, r7, #3
    bl  vdec
    ldrh r2, [r6, #8]
    cmp r2, #0
    beq 3f
    mov r8, r0
    ldr r0, =C_GREY
    bl  vink
    mov r0, r8
    add r1, r7, #3
    ldr r2, =str_sk
    bl  vstr
    ldrh r2, [r6, #8]
    add r1, r7, #3
    bl  vdec
3:  add r5, r5, #8
    add r6, r6, #16
    add r7, r7, #1
    cmp r7, #15
    blo 1b
4:  mov r10, r7
    ldr r0, =C_WHITE
    bl  vpaper
    @ the first failures, two rows each, under the suite table
    add r9, r7, #4                 @ row
    mov r7, #0                     @ case
    ldr r8, =N_CASES
5:  cmp r7, r8
    bhs 7f
    ldr r0, =RESULTS + RB_CASES
    add r0, r0, r7, lsl #4
    ldrb r0, [r0]
    cmp r0, #ST_FAIL
    cmpne r0, #ST_TIMEOUT
    cmpne r0, #ST_CRASH
    bne 6f
    cmp r9, #18
    bhs 7f
    mov r0, r9
    mov r1, r7
    bl  vcase_lines
    add r9, r9, #2
6:  add r7, r7, #1
    b   5b
7:  ldr r0, =C_GREY
    bl  ink
    mov r0, #0
    mov r1, #19
    ldr r2, =str_help2
    bl  vstr
    bl  vshow
sv_loop:
    bl  wait_vblank_link
    bl  vkeys
    cmp r0, #0
    beq sv_loop
    tst r0, #0x02                  @ B
    bne vmenu
    tst r0, #0x01                  @ A
    bne sv_detail
    ldr r1, [r4, #RT_CURSOR]
    mov r2, r1
    tst r0, #0x40
    subne r1, r1, #1
    tst r0, #0x80
    addne r1, r1, #1
    cmp r1, #0
    movlt r1, #0
    cmp r1, r10
    subge r1, r10, #1
    cmp r1, r2
    beq sv_loop
    str r1, [r4, #RT_CURSOR]
    b   sv_redraw
sv_detail:
    ldr r1, [r4, #RT_CURSOR]
    str r1, [r4, #RT_VIEW]
    b   dv_enter
    .ltorg

@ ─────────────────────────── the detail view ─────────────────────────────
@ every case of suite RT_VIEW in table order, two rows for a failure and
@ one for anything else; UP/DOWN move a case, LEFT/RIGHT a page
detail_view_entry:                 @ from a run: the LCD holds its screen
    ldr r4, =RT
    mov r0, #1
    str r0, [r4, #RT_VSTALE]
dv_enter:                          @ from the summary
    ldr r4, =RT
    mov r0, #0
    str r0, [r4, #RT_SCROLL]
    str r0, [r4, #RT_VREPEAT]
    ldr r0, =0x3FF
    str r0, [r4, #RT_KEYS]
    @ the furthest scroll: the first case from which the page reaches the
    @ suite's last (the cases before the last may fill rows 1-16)
    ldr r0, [r4, #RT_VIEW]
    ldr r5, =suite_table
    add r5, r5, r0, lsl #3
    ldr r1, [r5, #4]               @ first
    ldr r2, [r5, #12]
    sub r2, r2, #1                 @ the last case
    mov r3, #0                     @ rows from r2 to the one before the last
    ldr r12, =RESULTS + RB_CASES
1:  cmp r2, r1
    bls 2f
    sub r0, r2, #1
    ldrb r6, [r12, r0, lsl #4]
    cmp r6, #ST_FAIL
    cmpne r6, #ST_TIMEOUT
    cmpne r6, #ST_CRASH
    addeq r3, r3, #2
    addne r3, r3, #1
    cmp r3, #16
    movls r2, r0
    bls 1b
2:  subs r2, r2, r1
    movmi r2, #0
    str r2, [r4, #RT_VMAX]
dv_redraw:
    bl  vclear
    ldr r0, [r4, #RT_VIEW]
    ldr r5, =suite_table
    add r5, r5, r0, lsl #3
    mov r0, #C_BLACK
    bl  ink
    mov r0, #0
    mov r1, #0
    ldr r2, [r5]
    bl  vstr
    ldr r0, [r4, #RT_VIEW]
    ldr r6, =RESULTS + RB_SUITES
    add r6, r6, r0, lsl #4
    ldrh r2, [r6]
    mov r0, #14
    mov r1, #0
    bl  vdec
    ldr r2, =str_slash
    mov r1, #0
    bl  vstr
    ldrh r2, [r6, #10]
    mov r1, #0
    bl  vdec
    ldr r7, [r5, #4]               @ first case
    ldr r8, [r5, #12]              @ end
    ldr r0, [r4, #RT_SCROLL]
    add r7, r7, r0
    mov r9, #1                     @ row
1:  cmp r7, r8
    bhs 3f
    cmp r9, #18
    bhs 3f
    mov r0, r9
    mov r1, r7
    bl  vcase_lines
    ldr r0, =RESULTS + RB_CASES
    add r0, r0, r7, lsl #4
    ldrb r0, [r0]
    cmp r0, #ST_FAIL
    cmpne r0, #ST_TIMEOUT
    cmpne r0, #ST_CRASH
    addeq r9, r9, #2
    addne r9, r9, #1
    add r7, r7, #1
    b   1b
3:  ldr r6, [r5, #4]               @ r7 = one past the last case shown
    sub r7, r7, r6
    ldr r0, [r4, #RT_SCROLL]
    sub r1, r7, r0
    str r1, [r4, #RT_VPAGE]
    ldr r0, =C_GREY
    bl  ink
    ldr r2, [r4, #RT_SCROLL]       @ "first-last of cases"
    add r2, r2, #1
    mov r0, #26
    mov r1, #0
    bl  vdec
    mov r1, #0
    ldr r2, =str_dash
    bl  vstr
    mov r1, #0
    mov r2, r7
    bl  vdec
    mov r1, #0
    ldr r2, =str_of
    bl  vstr
    mov r1, #0
    sub r2, r8, r6
    bl  vdec
    mov r0, #0
    mov r1, #19
    ldr r2, =str_help3v
    bl  vstr
    bl  vshow
dv_loop:
    bl  wait_vblank_link
    bl  vkeys
    cmp r0, #0
    beq dv_loop
    tst r0, #0x02                  @ B: back, the cursor on this suite
    ldrne r0, [r4, #RT_VIEW]
    strne r0, [r4, #RT_CURSOR]
    bne sv_enter
    ldr r1, [r4, #RT_SCROLL]
    ldr r2, [r4, #RT_VPAGE]        @ a page keeps one case in view
    subs r2, r2, #1
    movle r2, #1
    tst r0, #0x40
    subne r1, r1, #1
    tst r0, #0x80
    addne r1, r1, #1
    tst r0, #0x20
    subne r1, r1, r2
    tst r0, #0x10
    addne r1, r1, r2
    cmp r1, #0
    movlt r1, #0
    ldr r2, [r4, #RT_VMAX]
    cmp r1, r2
    movgt r1, r2
    ldr r2, [r4, #RT_SCROLL]
    cmp r1, r2
    beq dv_loop
    str r1, [r4, #RT_SCROLL]
    b   dv_redraw
    .ltorg
