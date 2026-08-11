@ runtime.inc — shared runtime for the hwverified proof ROMs.
@ Derived from gbaedge.s (the probe ROM the AGS-001 hardware sessions
@ ran — see docs/hwprobe-results-agb.md); machinery kept byte-compatible
@ where it matters: mode 3 framebuffer, the same 8x8 1bpp font (so
@ tests/roms/hwprobe_ocr.py can read these screenshots too), raw-hex
@ result slot at 0x02000000.
@
@ Each ROM defines:
@   rom_name/rom_name_len  ASCII title
@   probe:                 runs once at boot, results -> SLOT (32 bytes)
@   expected:              32 bytes, the hardware-verified values
@   classes:               32 bytes: 0 = exact-check, 1 = informational
@                          (displayed in blue, never checked), 2 = member
@                          of a range-checked word (see ranges)
@   ranges:                word triplets {offset, lo, hi} over class-2
@                          words, terminated by an offset >= 32
@
@ The runtime draws the slot as hex: matching cells black-on-white,
@ MISMATCHED cells inverted (white-on-black), informational cells blue.
@ After everything is drawn it paints a 4x4 verdict block in the
@ bottom-right corner of the screen — GREEN if every checked cell
@ matches, RED otherwise.  Automated tests should sample pixel
@ (239,159); it stays white until the verdict is painted, so a hang
@ never reads as a pass.

main:
    mov r0, #IOBASE                @ IME off before anything else
    add r0, r0, #0x208
    mov r1, #0
    strh r1, [r0]

    @ zero the result slot and the IRQ scratch block
    ldr r0, =SLOT
    mov r1, #(SLOTSZ / 4)
    mov r2, #0
1:  str r2, [r0], #4
    subs r1, r1, #1
    bne 1b
    ldr r0, =SCRATCH + 0x40
    mov r1, #8
1:  str r2, [r0], #4
    subs r1, r1, #1
    bne 1b

    @ text colors: black ink on white paper
    ldr r0, =COLORS
    ldr r1, =0x7FFF0000
    str r1, [r0]

    @ install the IRQ handler (timer stamp + watchdog diversion)
    ldr r0, =0x03007FFC
    ldr r1, =irq_handler
    str r1, [r0]

    @ mode 3 + BG2, white screen
    ldr r0, =0x0403
    mov r1, #IOBASE
    strh r0, [r1]
    bl  clear_screen

    bl  probe
    bl  draw_result
forever:
    b   forever
    .ltorg

@ ──────────────────────────── IRQ handler ────────────────────────────────
@ Entered from the BIOS dispatcher in IRQ mode; sp_irq points at the
@ BIOS-saved {r0-r3,r12,lr} block, so [sp,#20] is the return address the
@ BIOS will `subs pc, lr, #4` through.  First entry since the flag was
@ cleared records the TM0 entry stamp and the interrupted return address;
@ a TM3 overflow acts as watchdog and diverts the return to the recovery
@ address the probe deposited at MARKER+20.
irq_handler:
    ldr r0, =0x04000100
    ldrh r1, [r0]                  @ TM0 entry stamp
    ldr r0, =SCRATCH
    ldr r2, [r0, #0x4C]
    cmp r2, #0
    streqh r1, [r0, #0x48]
    ldreq r3, [sp, #20]
    streq r3, [r0, #0x50]
    moveq r2, #1
    streq r2, [r0, #0x4C]
    ldr r0, =0x04000200
    ldrh r1, [r0, #2]              @ IF
    tst r1, #0x40                  @ timer 3: watchdog
    beq 1f
    ldr r2, =MARKER
    ldr r3, [r2, #8]
    cmp r3, #1                     @ probe in flight?
    bne 1f
    mov r3, #2                     @ mark "watchdog fired"
    str r3, [r2, #8]
    ldr r3, [r2, #20]              @ recovery address
    str r3, [sp, #20]              @ divert the IRQ return there
    mov r3, #0x9F                  @ system mode, ARM, IRQs masked
    msr SPSR_cxsf, r3
1:  strh r1, [r0, #2]              @ ack everything we saw
    bx  lr
    .ltorg

wait_vblank:
    ldr r0, =0x04000006
1:  ldrh r1, [r0]
    cmp r1, #159
    bne 1b
2:  ldrh r1, [r0]
    cmp r1, #160
    bne 2b
    bx  lr
    .ltorg

@ ═══════════════════════════ RENDERING ═══════════════════════════════════

clear_screen:
    ldr r0, =VRAM
    ldr r1, =0x7FFF7FFF
    ldr r2, =240*160/2
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    bx  lr
    .ltorg

@ r0 = ink, r1 = paper
set_colors:
    ldr r2, =COLORS
    strh r0, [r2, #0]
    strh r1, [r2, #2]
    bx  lr

@ r0 = cell x (0-29), r1 = cell y (0-19), r2 = font tile
@ Uses the ink/paper pair at COLORS.
draw_glyph:
    push {r4-r8, lr}
    ldr r3, =VRAM
    mov r4, #480
    mul r5, r1, r4
    add r3, r3, r5, lsl #3         @ + y*8*480
    add r3, r3, r0, lsl #4         @ + x*8*2
    ldr r5, =font_data
    add r5, r5, r2, lsl #3
    ldr r8, =COLORS
    ldrh r1, [r8, #0]              @ ink
    ldrh r8, [r8, #2]              @ paper
    mov r6, #8
dg_row:
    ldrb r7, [r5], #1
    mov r2, #0x80
    mov r12, r3
dg_col:
    tst r7, r2
    movne r4, r1
    moveq r4, r8
    strh r4, [r12], #2
    movs r2, r2, lsr #1
    bne dg_col
    add r3, r3, #480
    subs r6, r6, #1
    bne dg_row
    pop {r4-r8, pc}
    .ltorg

@ r0 = x, r1 = y, r2 = ASCII string, r3 = length
@ (font tiles: " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-/.")
draw_text:
    push {r4-r8, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, r3
1:  ldrb r8, [r6], #1
    mov r2, #0                     @ default: space
    cmp r8, #0x2D                  @ '-'
    moveq r2, #37
    cmp r8, #0x2F                  @ '/'
    moveq r2, #38
    cmp r8, #0x2E                  @ '.'
    moveq r2, #39
    sub r8, r8, #0x30
    cmp r8, #9
    addls r2, r8, #1               @ '0'-'9'
    sub r8, r8, #0x11
    cmp r8, #25
    addls r2, r8, #11              @ 'A'-'Z'
    mov r0, r4
    mov r1, r5
    bl  draw_glyph
    add r4, r4, #1
    subs r7, r7, #1
    bne 1b
    pop {r4-r8, pc}

@ r0 = x, r1 = y, r2 = byte
print_hex8:
    push {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r2, r6, lsr #4
    and r2, r2, #0xF
    add r2, r2, #1                 @ font tile = nibble + 1
    bl  draw_glyph
    and r2, r6, #0xF
    add r2, r2, #1
    add r0, r4, #1
    mov r1, r5
    bl  draw_glyph
    pop {r4-r6, pc}

@ r0 = ptr, r1 = len -> r0 = CRC-16/CCITT (poly 1021, init FFFF)
crc16:
    ldr r2, =0xFFFF
1:  ldrb r3, [r0], #1
    eor r2, r2, r3, lsl #8
    mov r12, #8
2:  tst r2, #0x8000
    mov r2, r2, lsl #1
    eorne r2, r2, #0x1000
    eorne r2, r2, #0x0021
    subs r12, r12, #1
    bne 2b
    bic r2, r2, #0xFF000000
    bic r2, r2, #0x00FF0000
    subs r1, r1, #1
    bne 1b
    mov r0, r2
    bx  lr
    .ltorg

@ Compare the slot against the baked-in expectations, draw every cell
@ (mismatches inverted, informational cells blue), then paint the
@ verdict block.
draw_result:
    push {r4-r11, lr}
    ldr r4, =SLOT
    ldr r6, =classes
    ldr r7, =FLAGS
    @ pass 1: exact-check flags
    mov r9, #0
1:  ldrb r0, [r4, r9]
    ldr r1, =expected
    ldrb r1, [r1, r9]
    ldrb r2, [r6, r9]
    mov r3, #0
    cmp r2, #0                     @ exact-check cell?
    bne 2f
    cmp r0, r1
    movne r3, #1
2:  strb r3, [r7, r9]
    add r9, r9, #1
    cmp r9, #32
    blt 1b
    @ pass 2: range-checked words
    ldr r5, =ranges
3:  ldr r0, [r5], #4               @ offset (>= 32 terminates)
    cmp r0, #32
    bhs 5f
    ldr r1, [r5], #4               @ lo
    ldr r2, [r5], #4               @ hi
    ldr r3, [r4, r0]
    cmp r3, r1
    blo 4f
    cmp r3, r2
    bls 3b                         @ within the band
4:  mov r3, #1                     @ out of band: flag the whole word
    strb r3, [r7, r0]
    add r0, r0, #1
    strb r3, [r7, r0]
    add r0, r0, #1
    strb r3, [r7, r0]
    add r0, r0, #1
    strb r3, [r7, r0]
    b   3b
5:  @ verdict: any flagged cell fails the ROM
    mov r9, #0
    mov r10, #0
6:  ldrb r0, [r7, r9]
    orr r10, r10, r0
    add r9, r9, #1
    cmp r9, #32
    blt 6b
    @ title
    mov r0, #0
    ldr r1, =0x7FFF
    bl  set_colors
    mov r0, #0
    mov r1, #0
    ldr r2, =rom_name
    mov r3, #rom_name_len
    bl  draw_text
    @ hex cells
    mov r9, #0
dr_loop:
    ands r0, r9, #3
    bne 7f
    mov r0, #0                     @ row label, normal colors
    ldr r1, =0x7FFF
    bl  set_colors
    mov r0, #0
    add r1, r9, #16                @ y = 4 + off/4
    mov r1, r1, lsr #2
    mov r2, r9
    bl  print_hex8
7:  ldrb r0, [r6, r9]              @ class
    cmp r0, #1
    beq 8f
    ldrb r0, [r7, r9]              @ mismatch flag
    cmp r0, #0
    bne 9f
    mov r0, #0                     @ match: black on white
    ldr r1, =0x7FFF
    b   10f
8:  ldr r0, =0x7C00                @ informational: blue on white
    ldr r1, =0x7FFF
    b   10f
9:  ldr r0, =0x7FFF                @ mismatch: white on black
    mov r1, #0
10: bl  set_colors
    and r0, r9, #3
    add r0, r0, r0, lsl #1         @ x = 3 + (off%4)*3
    add r0, r0, #3
    add r1, r9, #16
    mov r1, r1, lsr #2
    ldrb r2, [r4, r9]
    bl  print_hex8
    add r9, r9, #1
    cmp r9, #32
    blt dr_loop
    @ CRC of the slot, normal colors
    mov r0, #0
    ldr r1, =0x7FFF
    bl  set_colors
    mov r0, #0
    mov r1, #13
    ldr r2, =str_crc
    mov r3, #4
    bl  draw_text
    ldr r0, =SLOT
    mov r1, #SLOTSZ
    bl  crc16
    mov r8, r0
    mov r0, #4
    mov r1, #13
    mov r2, r8, lsr #8
    bl  print_hex8
    mov r0, #6
    mov r1, #13
    and r2, r8, #0xFF
    bl  print_hex8
    @ verdict block: 4x4 pixels at (236..239, 156..159) — green if every
    @ checked cell matched, red otherwise.  Painted last, so a hang never
    @ shows a verdict.
    ldr r0, =VRAM + (156*240 + 236)*2
    ldr r1, =0x03E0                @ green
    cmp r10, #0
    ldrne r1, =0x001F              @ red
    mov r2, #4
11: strh r1, [r0, #0]
    strh r1, [r0, #2]
    strh r1, [r0, #4]
    strh r1, [r0, #6]
    add r0, r0, #480
    subs r2, r2, #1
    bne 11b
    pop {r4-r11, pc}
str_crc:
    .ascii "CRC "
    .align 2
    .ltorg

    .include "font_gen.inc"
