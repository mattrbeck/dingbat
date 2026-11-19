@ viewer.inc -- the cartridge build's screens for someone working the suite
@ by hand.  Three of them:
@
@   home   the suites, each with its case count and its result once it has
@          run.  A opens a suite that has results and runs one that has
@          none, SELECT runs it (again), START runs everything.
@   list   one suite's cases (or every suite's), a mark and a name each,
@          got and expected under a failure.  SELECT keeps the failures
@          only, L and R jump to the previous and next failure.
@   case   one case: its answer, what was expected and how it is checked.
@
@ A screen is drawn as text into RT_VNEXT, 40x20 cells, and vshow paints
@ the cells that differ from the ones on the LCD (RT_VSHOWN), so a cursor
@ move repaints two rows and no cell is blanked before it is drawn.  The
@ painter runs from the cartridge: no code is copied anywhere, so an
@ emulator needs nothing beyond plain ROM execution to show these screens.
@
@ The run screen and the cases do not come through here: from the moment a
@ run starts they execute the instructions they did before this file
@ existed.  The home screen is up from boot, counting down to the auto-run.

.equ C_SEL,    0x6739              @ the cursor row's paper
.equ C_BAR,    0x2108              @ the title bar
.equ C_TRACK,  0x6B5A              @ the scroll track

.equ G_ARROW,  0x7F                @ vfont_gen.inc's marks
.equ G_DOTS,   0x80
.equ G_PASS,   0x81
.equ G_FAIL,   0x82
.equ G_NONE,   0x83
.equ G_TRACK,  0x85

@ ══════════════════════════════ text cells ═══════════════════════════════

@ r0 = ink.  Keeps the flags.
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
    mov r3, #41
@ ... r3 = the column it must end before: a string that would pass it ends
@ in an ellipsis
vstrn:
    stmfd sp!, {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    sub r7, r3, #1
1:  ldrb r2, [r6], #1
    cmp r2, #0
    beq 2f
    cmp r4, r7
    blo 3f
    ldrb r0, [r6]                  @ the last column: more to come?
    cmp r0, #0
    movne r2, #G_DOTS
    movne r6, #0
3:  mov r0, r4
    mov r1, r5
    bl  vput
    add r4, r4, #1
    cmp r6, #0
    bne 1b
2:  mov r0, r4
    ldmfd sp!, {r4-r7, pc}

@ r0 = column, r1 = row, r2 = value: eight hex digits -> r0 = next column
vhex:
    stmfd sp!, {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, #28
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

@ r0 = the column to end before, r1 = row: the output line, right-aligned
vsbr:
    stmfd sp!, {r4, r5, lr}
    mov r4, r0
    mov r5, r1
    mov r0, #0
    bl  sb_char
    ldr r1, =RT
    ldr r2, [r1, #RT_SBPOS]
    sub r2, r2, #1
    sub r0, r4, r2
    mov r1, r5
    ldr r2, =RT + RT_SB
    bl  vstr
    ldmfd sp!, {r4, r5, pc}

@ r0 = the column to end before, r1 = row, r2 = value (decimal)
vdecr:
    stmfd sp!, {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    bl  sb_reset
    mov r0, r6
    bl  sb_dec
    mov r0, r4
    mov r1, r5
    bl  vsbr
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

@ every cell blank on white, and white paper
vclear:
    ldr r3, =RT
    ldr r12, =C_WHITE
    strh r12, [r3, #RT_PAPER]
    add r3, r3, #RT_VNEXT
    mov r1, #800
    mov r2, #' '
    mov r12, r12, lsl #16
1:  stmia r3!, {r2, r12}
    subs r1, r1, #1
    bne 1b
    bx  lr

@ row 0 as the title bar; white ink on it until the caller changes paper
vbar:
    stmfd sp!, {lr}
    ldr r0, =C_BAR
    bl  vpaper
    mov r0, #0
    bl  vrow
    ldr r0, =C_WHITE
    bl  vink
    ldmfd sp!, {pc}

@ r1 = row, r2 = label: grey at column 1 -> black ink, r0 = 11, r1 = row
vlabel:
    stmfd sp!, {r5, r6, lr}
    mov r5, r1
    mov r6, r2
    ldr r0, =C_GREY
    bl  vink
    mov r0, #1
    mov r1, r5
    mov r2, r6
    bl  vstr
    mov r0, #C_BLACK
    bl  vink
    mov r0, #11
    mov r1, r5
    ldmfd sp!, {r5, r6, pc}

@ r2 = the key line for row 19: \001 before a key's name, \002 before
@ what it does
vhint:
    stmfd sp!, {r5, r6, lr}
    mov r5, #0
    mov r6, r2
1:  ldrb r2, [r6], #1
    cmp r2, #0
    beq 3f
    cmp r2, #2
    bhi 2f
    ldreq r0, =C_GREY
    movne r0, #C_BLACK
    bl  vink
    b   1b
2:  mov r0, r5
    mov r1, #19
    bl  vput
    add r5, r5, #1
    b   1b
3:  ldmfd sp!, {r5, r6, pc}

@ r0 / r1 -> r0, for small quotients
vdiv:
    mov r2, #0
1:  cmp r0, r1
    subhs r0, r0, r1
    addhs r2, r2, #1
    bhs 1b
    mov r0, r2
    bx  lr

@ Put the next screen on the LCD: from the top of V-blank, paint each cell
@ that differs from the one showing -- every cell when RT_VSTALE says the
@ pixels are someone else's (the run screen's, the boot stub's).  A cell
@ whose character is 0 is not text and is never painted.
vshow:
    stmfd sp!, {r4-r8, r11, lr}
    bl  wait_vblank_link
    ldr r4, =RT
    ldr r11, [r4, #RT_VSTALE]
    mov r0, #0
    str r0, [r4, #RT_VSTALE]
    add r5, r4, #RT_VNEXT
    add r4, r4, #RT_VSHOWN
    ldr r6, =VRAM
    bl  vpaint
    bl  draw_verdict               @ it sits in the last cell
    ldmfd sp!, {r4-r8, r11, pc}

@ r4 = RT: the LCD holds someone else's pixels (boot's, the run screen's).
@ Every way in from boot or a run comes through here.
vinstall:
    mov r0, #1
    str r0, [r4, #RT_VSTALE]
    bx  lr
    .ltorg

@ The painter.  r4 = cells showing, r5 = the next screen, r6 = VRAM, r11 =
@ paint everything.
    .align 2
vpaint:
    stmfd sp!, {lr}
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
    blne vpaint_cell
3:  add r4, r4, #8
    add r6, r6, #12
    subs r8, r8, #1
    bne 2b
    add r6, r6, #(480 * 7)
    subs r7, r7, #1
    bne 1b
    ldmfd sp!, {pc}
@ r0 = character, r1 = ink | paper << 16, r2 = the cell's first pixel.
@ Two pixels a store, through a table of the four pairs; a blank is three
@ words a line.
vpaint_cell:
    stmfd sp!, {r4-r6}
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
    ldmfd sp!, {r4-r6}
    bx  lr
2:  eor r1, r1, r3, lsl #16        @ ink
    sub r0, r0, #0x20
    cmp r0, #VFONT_N
    movhs r0, #('?' - 0x20)
    ldr r4, 5f
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
    ldmfd sp!, {r4-r6}
    bx  lr
5:  .word vfont_data

    tally_fn vtally, vstr, vdec

@ -> r0 = keys newly pressed; a d-pad direction held for 20 calls (a third
@ of a second) comes again every third call, and r1 = 1 when it is one of
@ those
vkeys:
    stmfd sp!, {lr}
    bl  read_keys
    ldr r2, =RT
    ldr r1, [r2, #RT_KEYS]
    and r12, r1, #0xF0             @ the d-pad, held
    ldr r3, [r2, #RT_VREPEAT]
    add r3, r3, #1
    tst r0, #0xF0                  @ a new direction starts the wait again
    movne r3, #0
    cmp r12, #0
    moveq r3, #0
    mov r1, #0
    cmp r3, #20
    orrhs r0, r0, r12
    movhs r3, #17
    movhs r1, #1
    str r3, [r2, #RT_VREPEAT]
    ldmfd sp!, {pc}
    .ltorg

@ ═══════════════════════════════ results ═════════════════════════════════

@ r0 = case -> r0 = 1 if it failed, timed out or crashed (keeps r1-r3)
vbad:
    ldr r12, =RESULTS + RB_CASES
    ldrb r0, [r12, r0, lsl #4]
    cmp r0, #ST_FAIL
    cmpne r0, #ST_TIMEOUT
    cmpne r0, #ST_CRASH
    moveq r0, #1
    movne r0, #0
    bx  lr

@ r0 = home entry (0 every suite, n the n-th) -> r0 = passes, r1 = failures
@ of any kind, r2 = skips, r3 = cases
ventry_stats:
    cmp r0, #0
    bne 1f
    ldr r12, =RESULTS + RB_TOTALS
    ldr r0, [r12]
    ldr r1, [r12, #4]
    ldr r2, [r12, #8]
    add r1, r1, r2
    ldr r2, [r12, #12]
    add r1, r1, r2
    ldr r2, [r12, #16]
    ldr r3, =N_CASES
    bx  lr
1:  sub r0, r0, #1
    ldr r12, =suite_table
    add r12, r12, r0, lsl #3
    ldr r3, [r12, #12]
    ldr r2, [r12, #4]
    sub r3, r3, r2
    ldr r12, =RESULTS + RB_SUITES
    add r12, r12, r0, lsl #4
    ldrh r0, [r12]
    ldrh r1, [r12, #2]
    ldrh r2, [r12, #4]
    add r1, r1, r2
    ldrh r2, [r12, #6]
    add r1, r1, r2
    ldrh r2, [r12, #8]
    bx  lr
    .ltorg

@ per status: the list's mark | its colour << 16, and the case page's word
vstatus_marks:
    .word G_NONE | C_GREY << 16, G_PASS | C_GREEN << 16, G_FAIL | C_RED << 16
    .word G_FAIL | C_RED << 16, G_FAIL | C_RED << 16, '-' | C_GREY << 16
vstatus_words:
    .word str_v_notrun, str_pass, str_fail, str_timeout, str_crash, str_v_skipped

str_v_notrun:   .asciz "NOT RUN"
str_v_skipped:  .asciz "SKIPPED"
str_v_title:    .asciz "dbsuite"
str_v_auto:     .asciz "auto-run in "
str_v_none:     .asciz "not run"
str_v_all:      .asciz "all suites"
str_v_suite:    .asciz "suite"
str_v_cases:    .asciz "cases"
str_v_passed:   .asciz "passed"
str_v_failures: .asciz " failures"
str_v_nofail:   .asciz "no failures"
str_v_of:       .asciz " of "
str_v_got:      .asciz "got"
str_v_exp:      .asciz "exp"
str_v_expected: .asciz "expected"
str_v_mask:     .asciz "mask"
str_v_check:    .asciz "check"
str_v_slot:     .asciz "slot"
str_v_needs:    .asciz "needs"
str_v_risky:    .asciz "risky"
str_v_cart:     .asciz "the cartridge bus"
str_v_undef:    .asciz "provokes undefined CPU state"
str_v_timeout:  .asciz "timed out"
str_v_crash:    .asciz "the console reset"
str_v_dots:     .asciz " .. "
str_v_or:       .asciz " or "
str_v_zero:     .asciz "0 or "
str_v_exact:    .asciz "exactly this value"
str_v_range:    .asciz "anywhere in the range"
str_v_two:      .asciz "either value"
str_v_kslot:    .asciz "equals another slot word"
str_v_zrange:   .asciz "zero, or in the range"
str_v_plus:     .asciz "+"
str_h_run:      .asciz "\001A\002 run  \001START\002 run all"
str_h_open:     .asciz "\001A\002 cases  \001SELECT\002 run  \001START\002 run all"
str_h_list:     .asciz "\001A\002 open  \001B\002 back  \001SEL\002 failures  \001L R\002 jump"
str_h_fails:    .asciz "\001A\002 open  \001B\002 back  \001SEL\002 all cases  \001L R\002 jump"
str_h_case:     .asciz "\001B\002 back  \001\204\002 case  \001L R\002 failure"
    .align 2

@ ════════════════════════════════ home ═══════════════════════════════════
@ Boot reaches vboot from runtime.inc's menu, with the auto-run countdown;
@ a whole run ends at summary_view, and the list's B at home_enter.

@ r4 = RT: the home screen into the next screen -> r10 = entries
home_fill:
    stmfd sp!, {r5-r9, lr}
    bl  vclear
    ldr r0, [r4, #RT_VLOGOCH]      @ the logo's cells: blank until it is
    ldr r3, =RT + RT_VNEXT         @ drawn over them, then not text
    bl  vlogo_cells
    mov r0, #C_BLACK
    bl  vink
    mov r0, #18
    mov r1, #1
    ldr r2, =str_v_title
    bl  vstr
    ldr r0, =C_GREY
    bl  vink
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
    mov r0, #2
    mov r1, #8
    ldr r2, =str_v_suite
    bl  vstr
    mov r0, #19
    mov r1, #8
    ldr r2, =str_v_cases
    bl  vstr
    mov r0, #30
    mov r1, #8
    ldr r2, =str_v_passed
    bl  vstr
    @ rows 9-17: every suite, then the suites (nine entries at most)
    mov r5, #0                     @ entry
1:  cmp r5, #0
    beq 2f
    ldr r6, =suite_table
    sub r0, r5, #1
    ldr r1, [r6, r0, lsl #3]
    cmp r1, #0
    beq 5f
2:  ldr r0, [r4, #RT_CURSOR]
    cmp r0, r5
    ldreq r0, =C_SEL
    ldrne r0, =C_WHITE
    bl  vpaper
    add r0, r5, #9
    bl  vrow
    mov r0, #C_BLACK
    bl  vink
    ldr r0, [r4, #RT_CURSOR]
    cmp r0, r5
    moveq r0, #0
    addeq r1, r5, #9
    moveq r2, #G_ARROW
    bleq vput
    cmp r5, #0
    ldreq r2, =str_v_all
    ldrne r6, =suite_table
    subne r0, r5, #1
    ldrne r2, [r6, r0, lsl #3]
    mov r0, #2
    add r1, r5, #9
    bl  vstr
    mov r0, r5
    bl  ventry_stats
    mov r6, r0                     @ passes
    mov r7, r1                     @ failures
    sub r8, r3, r2                 @ cases not skipped
    mov r2, r3
    mov r0, #24
    add r1, r5, #9
    bl  vdecr
    adds r0, r6, r7
    bne 3f
    ldr r0, =C_GREY
    bl  vink
    mov r0, #29
    add r1, r5, #9
    ldr r2, =str_v_none
    bl  vstr
    b   4f
3:  cmp r7, #0                     @ red for a failure, green once every
    ldrne r0, =C_RED               @ case has passed, black part way
    bne 8f
    cmp r6, r8
    ldreq r0, =C_GREEN
    movne r0, #C_BLACK
8:  bl  vink
    bl  sb_reset
    mov r0, r6
    bl  sb_dec
    mov r0, #'/'
    bl  sb_char
    mov r0, r8
    bl  sb_dec
    mov r0, #36
    add r1, r5, #9
    bl  vsbr
4:  add r5, r5, #1
    cmp r5, #9
    blo 1b
5:  mov r10, r5
    ldr r0, =C_WHITE
    bl  vpaper
    mov r0, #0                     @ the totals, once anything has run
    bl  ventry_stats
    adds r0, r0, r1
    beq 6f
    mov r0, #1
    mov r1, #18
    bl  vtally
6:  ldr r0, [r4, #RT_CURSOR]
    bl  ventry_stats
    adds r0, r0, r1
    ldreq r2, =str_h_run
    ldrne r2, =str_h_open
    bl  vhint
    ldr r0, [r4, #RT_VAUTO]        @ "auto-run in N", while it counts
    cmp r0, #0
    beq 7f
    bl  vauto_secs
    mov r5, r0
    ldr r0, =C_GREY
    bl  vink
    mov r0, #26
    mov r1, #19
    ldr r2, =str_v_auto
    bl  vstr
    mov r1, #19
    mov r2, r5
    bl  vdec
7:  ldmfd sp!, {r5-r9, pc}

@ r4 = RT -> r0 = the countdown in whole seconds, rounded up
vauto_secs:
    ldr r0, [r4, #RT_VAUTO]
    add r0, r0, #59
    ldr r1, =0x8889                @ /60 for small numbers
    mul r0, r1, r0
    mov r0, r0, lsr #21
    bx  lr
    .ltorg

@ r0 = character, r3 = a screen of cells: the logo's cells, columns 0-16
@ of rows 0-7
vlogo_cells:
    mov r1, #8
1:  mov r2, #17
2:  str r0, [r3], #8
    subs r2, r2, #1
    bne 2b
    add r3, r3, #(23 * 8)
    subs r1, r1, #1
    bne 1b
    bx  lr

@ r4 = RT, r9 = frames of countdown (0: none): the screen at boot
vboot:
    str r9, [r4, #RT_VAUTO]
    bl  vinstall
    b   home_show
summary_view:                      @ a whole run has finished
    ldr r4, =RT
    bl  vinstall
home_enter:                        @ from the list too
    ldr r4, =RT
    mov r0, #0
    str r0, [r4, #RT_VAUTO]
home_show:
    mov r0, #' '
    str r0, [r4, #RT_VLOGOCH]
    mov r0, #0
    str r0, [r4, #RT_VREPEAT]
    ldr r0, =0x3FF
    str r0, [r4, #RT_KEYS]
    bl  home_fill
    bl  vshow
    mov r0, #4
    mov r1, #4
    bl  draw_logo
    mov r0, #0                     @ those cells no longer show blanks: the
    str r0, [r4, #RT_VLOGOCH]      @ next screen must paint over them
    ldr r3, =RT + RT_VSHOWN
    bl  vlogo_cells
    b   home_loop
home_paint:
    bl  home_fill
    bl  vshow
home_loop:
    bl  wait_vblank_link
    ldr r0, [r4, #RT_VAUTO]        @ the countdown: run everything at 0,
    cmp r0, #0                     @ repaint when its seconds change
    beq 1f
    bl  vauto_secs
    mov r5, r0
    ldr r0, [r4, #RT_VAUTO]
    subs r0, r0, #1
    str r0, [r4, #RT_VAUTO]
    beq home_run_all
    bl  vauto_secs
    cmp r0, r5
    beq 1f
    bl  home_fill
    bl  vshow
1:  bl  vkeys
    cmp r0, #0
    beq home_loop
    mov r9, #0
    ldr r2, [r4, #RT_VAUTO]        @ any key stops the countdown
    cmp r2, #0
    movne r9, #1
    movne r2, #0
    strne r2, [r4, #RT_VAUTO]
home_key:                          @ r0 = keys, r1 = a repeat, r9 = paint anyway
    mov r5, r0
    mov r6, r1
    tst r5, #0x08                  @ START
    bne home_run_all
    tst r5, #0x04                  @ SELECT
    bne home_run_sel
    tst r5, #0x01                  @ A: its cases, or its first run
    beq 1f
    ldr r0, [r4, #RT_CURSOR]
    bl  ventry_stats
    adds r0, r0, r1
    beq home_run_sel
    ldr r0, [r4, #RT_CURSOR]
    sub r0, r0, #1
    str r0, [r4, #RT_VIEW]
    b   list_enter
1:  ldr r1, [r4, #RT_CURSOR]
    mov r2, r1
    tst r5, #0x40                  @ UP
    subne r1, r1, #1
    tst r5, #0x80                  @ DOWN
    addne r1, r1, #1
    cmp r1, #0                     @ a press wraps, a held key stops
    bge 2f
    cmp r6, #0
    subeq r1, r10, #1
    movne r1, #0
2:  cmp r1, r10
    blt 3f
    cmp r6, #0
    moveq r1, #0
    subne r1, r10, #1
3:  str r1, [r4, #RT_CURSOR]
    cmp r1, r2
    cmpeq r9, #0
    beq home_loop
    b   home_paint
home_run_all:
    b   menu_go_all
home_run_sel:
    b   menu_go_sel
    .ltorg

@ ════════════════════════════════ list ═══════════════════════════════════
@ RT_VLIST holds the cases on show, RT_VN of them; RT_VCUR and RT_VTOP are
@ positions in it.  A failure takes two rows, anything else one; rows 1-18.

@ r0 = position -> r0 = its case (keeps r1-r3)
vitem:
    ldr r12, =RT + RT_VLIST
    add r12, r12, r0, lsl #1
    ldrh r0, [r12]
    bx  lr

@ r0 = position -> r0 = the rows it takes (keeps r1-r3)
vrows:
    stmfd sp!, {lr}
    bl  vitem
    bl  vbad
    add r0, r0, #1
    ldmfd sp!, {pc}

@ r0 = position -> r0 = the first position from which a page reaches it
vfit:
    stmfd sp!, {r5-r7, lr}
    mov r5, r0
    bl  vrows
    mov r6, r0                     @ rows from r5 to it
1:  cmp r5, #0
    beq 2f
    sub r0, r5, #1
    bl  vrows
    add r7, r6, r0
    cmp r7, #18
    bhi 2f
    mov r6, r7
    sub r5, r5, #1
    b   1b
2:  mov r0, r5
    ldmfd sp!, {r5-r7, pc}

@ r0 = position, r1 = 1 or -1 -> r0 = the next failure that way, or r0
vseek:
    stmfd sp!, {r5-r7, lr}
    mov r5, r0
    mov r6, r0
    mov r7, r1
1:  add r6, r6, r7
    cmp r6, #0
    blt 2f
    ldr r0, [r4, #RT_VN]
    cmp r6, r0
    bge 2f
    mov r0, r6
    bl  vitem
    bl  vbad
    cmp r0, #0
    beq 1b
    mov r5, r6
2:  mov r0, r5
    ldmfd sp!, {r5-r7, pc}

@ r4 = RT: RT_VLIST from RT_VIEW (-1: every suite) and RT_VFILTER
vlist_build:
    stmfd sp!, {r5-r8, lr}
    ldr r0, [r4, #RT_VIEW]
    cmn r0, #1
    moveq r5, #0
    ldreq r6, =N_CASES
    ldrne r1, =suite_table
    addne r1, r1, r0, lsl #3
    ldrne r5, [r1, #4]
    ldrne r6, [r1, #12]
    ldr r7, =RT + RT_VLIST
    mov r8, #0
1:  cmp r5, r6
    bhs 3f
    ldr r0, [r4, #RT_VFILTER]
    cmp r0, #0
    beq 2f
    mov r0, r5
    bl  vbad
    cmp r0, #0
    beq 4f
2:  strh r5, [r7], #2
    add r8, r8, #1
4:  add r5, r5, #1
    b   1b
3:  str r8, [r4, #RT_VN]
    ldmfd sp!, {r5-r8, pc}

@ r4 = RT: the cursor inside the list, the page around the cursor and no
@ further down than the list's end needs
list_clamp:
    stmfd sp!, {r5-r6, lr}
    mov r5, #0
    mov r6, #0
    ldr r0, [r4, #RT_VN]
    subs r0, r0, #1
    blt 9f
    ldr r5, [r4, #RT_VCUR]
    ldr r6, [r4, #RT_VTOP]
    cmp r5, #0
    movlt r5, #0
    cmp r5, r0
    movgt r5, r0
    bl  vfit
    cmp r6, r0
    movgt r6, r0
    cmp r6, r5
    movgt r6, r5
    mov r0, r5
    bl  vfit
    cmp r6, r0
    movlt r6, r0
9:  str r5, [r4, #RT_VCUR]
    str r6, [r4, #RT_VTOP]
    ldmfd sp!, {r5-r6, pc}

@ "position of positions", white on the title bar's right
vtitle_pos:
    stmfd sp!, {lr}
    ldr r0, [r4, #RT_VN]
    cmp r0, #0
    beq 1f
    bl  sb_reset
    ldr r0, [r4, #RT_VCUR]
    add r0, r0, #1
    bl  sb_dec
    ldr r0, =str_v_of
    bl  sb_str
    ldr r0, [r4, #RT_VN]
    bl  sb_dec
    mov r0, #39
    mov r1, #0
    bl  vsbr
1:  ldmfd sp!, {pc}

@ r0 = row, r1 = position: the case's one or two rows
vitem_draw:
    stmfd sp!, {r5-r11, lr}
    mov r5, r0
    mov r6, r1
    mov r0, r6
    bl  vitem
    mov r7, r0                     @ case
    ldr r8, =RESULTS + RB_CASES
    add r8, r8, r7, lsl #4         @ its record
    ldr r9, =case_table
    add r9, r9, r7, lsl #5         @ its descriptor
    ldrb r10, [r8]                 @ status
    ldr r0, [r4, #RT_VCUR]
    cmp r0, r6
    ldreq r0, =C_SEL
    ldrne r0, =C_WHITE
    bl  vpaper
    mov r0, r5
    bl  vrow
    mov r0, r7
    bl  vbad
    movs r11, r0                   @ 1: a second row
    addne r0, r5, #1
    blne vrow
    mov r0, #C_BLACK
    bl  vink
    ldr r0, [r4, #RT_VCUR]
    cmp r0, r6
    moveq r0, #0
    moveq r1, r5
    moveq r2, #G_ARROW
    bleq vput
    ldr r2, =vstatus_marks
    ldr r2, [r2, r10, lsl #2]
    mov r0, r2, lsr #16
    bl  vink
    and r2, r2, #0xFF
    mov r0, #1
    mov r1, r5
    bl  vput
    mov r0, #C_BLACK
    bl  vink
    mov r6, #3                     @ column
    ldr r0, [r4, #RT_VIEW]         @ every suite's: say which
    cmn r0, #1
    bne 1f
    mov r0, r7
    bl  suite_name_of
    mov r2, r0
    mov r0, #3
    mov r1, r5
    bl  vstr
    mov r6, r0
    mov r1, r5
    mov r2, #'/'
    bl  vput
    add r6, r6, #1
1:  mov r0, r6
    mov r1, r5
    ldr r2, [r9, #CD_NAME]
    mov r3, #39
    bl  vstrn
    cmp r11, #0
    beq 9f
    add r5, r5, #1
    ldr r0, =C_GREY
    bl  vink
    cmp r10, #ST_FAIL
    beq 2f
    cmp r10, #ST_TIMEOUT
    ldreq r2, =str_v_timeout
    ldrne r2, =str_v_crash
    mov r0, #3
    mov r1, r5
    bl  vstr
    b   9f
2:  mov r0, #3
    mov r1, r5
    ldr r2, =str_v_got
    bl  vstr
    mov r0, #17
    mov r1, r5
    ldr r2, =str_v_exp
    bl  vstr
    ldr r0, =C_RED
    bl  vink
    mov r0, #7
    mov r1, r5
    ldr r2, [r8, #4]
    bl  vhex
    mov r0, #C_BLACK
    bl  vink
    ldr r6, [r9, #CD_INFO]
    and r6, r6, #0x0F              @ kind
    cmp r6, #K_SLOT
    ldreq r2, [r8, #8]
    ldrne r2, [r9, #CD_LO]
    mov r0, #21
    mov r1, r5
    bl  vhex
    cmp r6, #K_SLOT
    beq 9f
    ldr r1, [r9, #CD_LO]
    ldr r2, [r9, #CD_HI]
    cmp r1, r2
    beq 9f
    ldr r0, =C_GREY
    bl  vink
    cmp r6, #K_TWO
    ldreq r2, =str_bar
    ldrne r2, =str_dots
    mov r0, #29
    mov r1, r5
    bl  vstr
    mov r0, #C_BLACK
    bl  vink
    mov r0, #31
    mov r1, r5
    ldr r2, [r9, #CD_HI]
    bl  vhex
9:  ldr r0, =C_WHITE
    bl  vpaper
    ldmfd sp!, {r5-r11, pc}
    .ltorg

detail_view_entry:                 @ one suite's run has finished
    ldr r4, =RT
    bl  vinstall
list_enter:                        @ from home: RT_VIEW is set
    ldr r4, =RT
    mov r0, #0
    str r0, [r4, #RT_VFILTER]
    str r0, [r4, #RT_VTOP]
    str r0, [r4, #RT_VCUR]
    bl  vlist_build
list_back:                         @ from the case page
    mov r0, #0
    str r0, [r4, #RT_VREPEAT]
    ldr r0, =0x3FF
    str r0, [r4, #RT_KEYS]
list_draw:
    bl  list_clamp
    bl  vclear
    bl  vbar
    ldr r0, [r4, #RT_VIEW]
    cmn r0, #1
    ldreq r2, =str_v_all
    ldrne r1, =suite_table
    ldrne r2, [r1, r0, lsl #3]
    mov r0, #1
    mov r1, #0
    bl  vstr
    ldr r1, [r4, #RT_VFILTER]
    cmp r1, #0
    movne r1, #0
    ldrne r2, =str_v_failures
    blne vstr
    bl  vtitle_pos
    ldr r0, =C_WHITE
    bl  vpaper
    ldr r7, [r4, #RT_VTOP]         @ position
    mov r9, #1                     @ row
1:  ldr r0, [r4, #RT_VN]
    cmp r7, r0
    bhs 3f
    mov r0, r7
    bl  vrows
    mov r8, r0
    add r1, r9, r0
    cmp r1, #19
    bhi 3f
    mov r0, r9
    mov r1, r7
    bl  vitem_draw
    add r9, r9, r8
    add r7, r7, #1
    b   1b
3:  ldr r0, [r4, #RT_VTOP]
    sub r7, r7, r0                 @ cases on the page
    str r7, [r4, #RT_VPAGE]
    ldr r8, [r4, #RT_VN]
    cmp r8, #0
    bne 4f
    ldr r0, =C_GREY
    bl  vink
    mov r0, #14
    mov r1, #9
    ldr r2, =str_v_nofail
    bl  vstr
    b   7f
4:  cmp r8, r7                     @ more than a page: the scroll track,
    bls 7f                         @ 18 cells in column 39
    ldr r0, [r4, #RT_VTOP]
    add r0, r0, r0, lsl #3
    mov r0, r0, lsl #1
    mov r1, r8
    bl  vdiv
    mov r5, r0                     @ the thumb's first cell
    add r0, r7, r7, lsl #3
    mov r0, r0, lsl #1
    mov r1, r8
    bl  vdiv
    cmp r0, #0
    moveq r0, #1
    add r6, r5, r0                 @ ... and the one past its last
    cmp r6, #18
    subhi r5, r5, #1
    movhi r6, #18
    mov r9, #0
5:  cmp r9, r5
    cmphs r6, r9
    ldrhi r0, =C_GREY
    ldrls r0, =C_TRACK
    bl  vink
    mov r0, #39
    add r1, r9, #1
    mov r2, #G_TRACK
    bl  vput
    add r9, r9, #1
    cmp r9, #18
    blo 5b
7:  ldr r0, [r4, #RT_VFILTER]
    cmp r0, #0
    ldreq r2, =str_h_list
    ldrne r2, =str_h_fails
    bl  vhint
    bl  vshow
list_loop:
    bl  wait_vblank_link
    bl  vkeys
    cmp r0, #0
    beq list_loop
    mov r5, r0
    tst r5, #0x02                  @ B: home, the cursor on this suite
    ldrne r0, [r4, #RT_VIEW]
    addne r0, r0, #1
    strne r0, [r4, #RT_CURSOR]
    bne home_enter
    tst r5, #0x04                  @ SELECT
    bne list_filter
    ldr r8, [r4, #RT_VN]
    cmp r8, #0
    beq list_loop
    tst r5, #0x01                  @ A
    bne case_enter
    ldr r6, [r4, #RT_VCUR]
    ldr r7, [r4, #RT_VTOP]
    mov r1, r6
    mov r2, r7
    ldr r3, [r4, #RT_VPAGE]        @ a page keeps one case in view
    subs r3, r3, #1
    movle r3, #1
    tst r5, #0x40                  @ UP
    subne r1, r1, #1
    tst r5, #0x80                  @ DOWN
    addne r1, r1, #1
    tst r5, #0x20                  @ LEFT
    subne r1, r1, r3
    subne r2, r2, r3
    tst r5, #0x10                  @ RIGHT
    addne r1, r1, r3
    addne r2, r2, r3
    str r1, [r4, #RT_VCUR]
    str r2, [r4, #RT_VTOP]
    tst r5, #0x300                 @ R and L: the next and previous failure
    beq 1f
    tst r5, #0x100
    movne r1, #1
    mvneq r1, #0
    mov r0, r6
    bl  vseek
    str r0, [r4, #RT_VCUR]
1:  bl  list_clamp
    ldr r1, [r4, #RT_VCUR]
    ldr r2, [r4, #RT_VTOP]
    cmp r1, r6
    cmpeq r2, r7
    beq list_loop
    b   list_draw
list_filter:                       @ the other list, on the same case or
    mov r6, #0                     @ the next one it holds
    ldr r0, [r4, #RT_VN]
    cmp r0, #0
    beq 1f
    ldr r0, [r4, #RT_VCUR]
    bl  vitem
    mov r6, r0
1:  ldr r0, [r4, #RT_VFILTER]
    eor r0, r0, #1
    str r0, [r4, #RT_VFILTER]
    bl  vlist_build
    mov r5, #0
2:  ldr r0, [r4, #RT_VN]
    cmp r5, r0
    bhs 3f
    mov r0, r5
    bl  vitem
    cmp r0, r6
    addlo r5, r5, #1
    blo 2b
3:  str r5, [r4, #RT_VCUR]
    sub r5, r5, #4
    str r5, [r4, #RT_VTOP]
    b   list_draw
    .ltorg

@ ════════════════════════════════ case ═══════════════════════════════════
case_enter:
    mov r0, #0
    str r0, [r4, #RT_VREPEAT]
case_draw:
    bl  vclear
    bl  vbar
    ldr r0, [r4, #RT_VCUR]
    bl  vitem
    mov r7, r0                     @ case
    ldr r8, =RESULTS + RB_CASES
    add r8, r8, r7, lsl #4         @ its record
    ldr r9, =case_table
    add r9, r9, r7, lsl #5         @ its descriptor
    ldrb r10, [r8]                 @ status
    ldr r11, [r9, #CD_INFO]
    mov r0, r7
    bl  suite_name_of
    mov r2, r0
    mov r0, #1
    mov r1, #0
    bl  vstr
    bl  vtitle_pos
    ldr r0, =C_WHITE
    bl  vpaper
    mov r0, #C_BLACK
    bl  vink
    mov r0, #1
    mov r1, #2
    ldr r2, [r9, #CD_NAME]
    bl  vstr
    ldr r2, =vstatus_marks
    ldr r2, [r2, r10, lsl #2]
    mov r0, r2, lsr #16
    bl  vink
    ldr r2, =vstatus_words
    ldr r2, [r2, r10, lsl #2]
    mov r0, #1
    mov r1, #4
    bl  vstr
    cmp r10, #ST_TIMEOUT           @ ... and why, for the two with no answer
    ldreq r2, =str_v_timeout
    cmp r10, #ST_CRASH
    ldreq r2, =str_v_crash
    cmpne r10, #ST_TIMEOUT
    bne 1f
    mov r5, r2
    ldr r0, =C_GREY
    bl  vink
    mov r0, #11
    mov r1, #4
    mov r2, r5
    bl  vstr
1:  mov r1, #6                     @ got: a case that ran to its check
    ldr r2, =str_v_got
    bl  vlabel
    cmp r10, #ST_PASS
    cmpne r10, #ST_FAIL
    ldrne r2, =str_dash
    blne vstr
    bne 2f
    cmp r10, #ST_FAIL
    ldreq r0, =C_RED
    bleq vink
    mov r0, #11
    mov r1, #6
    ldr r2, [r8, #4]
    bl  vhex
2:  mov r1, #7
    ldr r2, =str_v_expected
    bl  vlabel
    and r6, r11, #0x0F             @ kind
    cmp r6, #K_SLOT
    bne 3f
    cmp r10, #ST_PASS              @ a slot word: known once the case ran
    cmpne r10, #ST_FAIL
    ldrne r2, =str_dash
    blne vstr
    bne 5f
    mov r0, #11
    mov r1, #7
    ldr r2, [r8, #8]
    bl  vhex
    b   5f
3:  cmp r6, #K_ZRANGE
    ldreq r2, =str_v_zero
    bleq vstr
    mov r1, #7
    ldr r2, [r9, #CD_LO]
    bl  vhex
    ldr r1, [r9, #CD_LO]
    ldr r2, [r9, #CD_HI]
    cmp r1, r2
    beq 5f
    cmp r6, #K_TWO
    ldreq r2, =str_v_or
    ldrne r2, =str_v_dots
    mov r1, #7
    bl  vstr
    mov r1, #7
    ldr r2, [r9, #CD_HI]
    bl  vhex
5:  mov r1, #8
    ldr r2, =str_v_mask
    bl  vlabel
    ldr r2, [r9, #CD_MASK]
    bl  vhex
    mov r1, #9
    ldr r2, =str_v_check
    bl  vlabel
    ldr r2, [r9, #CD_LO]
    ldr r3, [r9, #CD_HI]
    cmp r2, r3
    ldreq r2, =str_v_exact
    ldrne r2, =str_v_range
    cmp r6, #K_TWO
    ldreq r2, =str_v_two
    cmp r6, #K_SLOT
    ldreq r2, =str_v_kslot
    cmp r6, #K_ZRANGE
    ldreq r2, =str_v_zrange
    bl  vstr
    mov r1, #10                    @ where in the slot the answer is read
    ldr r2, =str_v_slot
    bl  vlabel
    ldr r2, =str_v_plus
    bl  vstr
    mov r5, r0
    bl  sb_reset
    mov r0, r11, lsl #4
    mov r0, r0, lsr #20
    bl  sb_dec
    mov r0, #0
    bl  sb_char
    mov r0, r5
    mov r1, #10
    ldr r2, =RT + RT_SB
    bl  vstr
    mov r5, #12
    tst r11, #F_CART
    beq 6f
    mov r1, r5
    ldr r2, =str_v_needs
    bl  vlabel
    ldr r2, =str_v_cart
    bl  vstr
    add r5, r5, #1
6:  tst r11, #F_RISKY
    beq 7f
    mov r1, r5
    ldr r2, =str_v_risky
    bl  vlabel
    ldr r2, =str_v_undef
    bl  vstr
7:  ldr r2, =str_h_case
    bl  vhint
    bl  vshow
case_loop:
    bl  wait_vblank_link
    bl  vkeys
    cmp r0, #0
    beq case_loop
    mov r5, r0
    tst r5, #0x02                  @ B
    bne list_back
    ldr r6, [r4, #RT_VCUR]
    mov r0, r6
    tst r5, #0x60                  @ UP, LEFT
    subne r0, r0, #1
    tst r5, #0x90                  @ DOWN, RIGHT
    addne r0, r0, #1
    cmp r0, #0
    movlt r0, #0
    ldr r1, [r4, #RT_VN]
    cmp r0, r1
    subge r0, r1, #1
    tst r5, #0x300                 @ R and L: the next and previous failure
    beq 1f
    tst r5, #0x100
    movne r1, #1
    mvneq r1, #0
    mov r0, r6
    bl  vseek
1:  cmp r0, r6
    beq case_loop
    str r0, [r4, #RT_VCUR]
    b   case_draw
    .ltorg

    .include "vfont_gen.inc"
    .align 2
