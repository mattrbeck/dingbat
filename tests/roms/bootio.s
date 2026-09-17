@ bootio.s — the I/O register file a GBA ROM finds at entry (built by
@ bootio.py).  The first thing the ROM does is read every I/O word from
@ 0x04000000 to 0x0400020A, so the dump is what the BIOS boot left behind.
@ Then it runs write/read-back experiments on the serial registers.  Real
@ hardware is the oracle: nothing here encodes an expected value.
@
@ Data (0x02000000, 360 words, little-endian):
@   word i (0-261)  = the I/O word at 0x04000000 + 2*i, read at entry
@   word 262        = 0x04000300 (POSTFLG/HALTCNT)
@   words 263-264   = 0x04000800 low/high (internal memory control)
@   words 270-291   = the experiments below, in table order
@
@ Viewer: 4 pages (LEFT/RIGHT or A/B), 18 rows of 5 words each.
@   pages 0-2: rows labelled by the address of their first word; the last
@              row of page 2 holds 208 20A 300 800 802
@   page 3:    rows labelled by experiment number (row*5)
@ Each page shows CRC-16/CCITT of its 180 bytes and of all 720 ("ALL").
@ Run with NO link cable attached.

    .arm
    .text
    .global _start

.equ DATA,   0x02000000
.equ VPAGE,  0x02002100            @ +0 page +4 previous keys
.equ VRAM,   0x06000000
.equ NPAGES, 4

_start:
    b   header_end                 @ 0x00: BIOS jumps here after the logo
    .space 0x9C                    @ 0x04-0x9F: logo (patched by bootio.py)
    .space 0x20                    @ 0xA0-0xBF: title/codes (patched)
header_end:
    @ capture before touching anything (no stack, no writes to I/O)
    ldr r0, =0x04000000
    ldr r1, =DATA
    ldr r2, =262
1:  ldrh r3, [r0], #2
    strh r3, [r1], #2
    subs r2, r2, #1
    bne 1b
    ldr r0, =0x04000300
    ldrh r3, [r0]
    strh r3, [r1], #2
    ldr r0, =0x04000800
    ldrh r3, [r0]
    strh r3, [r1], #2
    ldrh r3, [r0, #2]
    strh r3, [r1], #2
    @ zero the rest of the data block (EWRAM boots as noise)
    mov r2, #0
    ldr r3, =(360 - 265)
1:  strh r2, [r1], #2
    subs r3, r3, #1
    bne 1b

    ldr sp, =0x03007F00

    @ experiments: {write address (0 = none), value, read address}
    ldr r4, =exp_table
    ldr r5, =DATA + 270*2
    mov r6, #NEXP
2:  ldr r0, [r4], #4
    ldr r1, [r4], #4
    ldr r2, [r4], #4
    cmp r0, #0
    strneh r1, [r0]
    ldrh r3, [r2]
    strh r3, [r5], #2
    subs r6, r6, #1
    bne 2b
    ldr r0, =0x04000128            @ leave the port as the BIOS did
    mov r1, #0
    strh r1, [r0]
    ldr r0, =0x04000134
    ldr r1, =0x8000
    strh r1, [r0]

    ldr r0, =0x0403                @ mode 3 + BG2
    mov r1, #0x04000000
    strh r0, [r1]
    b   viewer
    .ltorg

.equ SIOCNT, 0x04000128
.equ RCNT,   0x04000134
exp_table:
    .word RCNT, 0x80F5, RCNT       @ 0  GP, all outputs, data 0101
    .word RCNT, 0x80FA, RCNT       @ 1  GP, all outputs, data 1010
    .word RCNT, 0x8000, RCNT       @ 2  GP, all inputs, data 0
    .word RCNT, 0x800F, RCNT       @ 3  GP, all inputs, data 1111
    .word RCNT, 0x80F0, RCNT       @ 4  GP, all outputs, data 0 (kept?)
    .word RCNT, 0x0000, RCNT       @ 5  leave GP: SIOCNT picks the mode
    .word 0,    0,      SIOCNT     @ 6
    .word SIOCNT, 0x2003, SIOCNT   @ 7  multiplay, 115200
    .word 0,    0,      RCNT       @ 8
    .word SIOCNT, 0x3000, SIOCNT   @ 9  UART
    .word 0,    0,      RCNT       @ 10
    .word SIOCNT, 0x1000, SIOCNT   @ 11 normal 32-bit, external clock
    .word 0,    0,      RCNT       @ 12
    .word SIOCNT, 0x0001, SIOCNT   @ 13 normal 8-bit, internal clock
    .word 0,    0,      RCNT       @ 14
    .word RCNT, 0xC000, RCNT       @ 15 JOY bus
    .word 0,    0,      SIOCNT     @ 16
    .word 0,    0,      0x04000140 @ 17 JOYCNT
    .word 0,    0,      0x04000158 @ 18 JOYSTAT
    .word RCNT, 0x0000, 0x0400012A @ 19 SIODATA8 (normal 8-bit again)
    .word 0x0400012A, 0x1234, 0x0400012A  @ 20 SIODATA8 write/read
    .word 0x04000120, 0x5678, 0x04000120  @ 21 SIODATA32_L write/read
    .word 0x04000124, 0x9ABC, 0x04000124  @ 22 SIOMULTI2 write/read
.equ NEXP, (. - exp_table) / 12

@ ─────────────────────────────── viewer ──────────────────────────────────
viewer:
    ldr r4, =VPAGE
    mov r0, #0
    str r0, [r4, #0]
    ldr r0, =0x03FF
    str r0, [r4, #4]
    mov r0, #0
    bl  draw_page
view_loop:
    bl  wait_vblank
    ldr r4, =VPAGE
    ldr r0, =0x04000130
    ldrh r0, [r0]                  @ 0 = pressed
    ldr r1, [r4, #4]
    str r0, [r4, #4]
    mvn r2, r0
    and r2, r2, r1                 @ newly pressed
    ldr r5, [r4, #0]
    tst r2, #0x11                  @ RIGHT or A
    bne 1f
    tst r2, #0x22                  @ LEFT or B
    beq view_loop
    subs r5, r5, #1
    movlt r5, #NPAGES-1
    b   2f
1:  add r5, r5, #1
    cmp r5, #NPAGES
    movge r5, #0
2:  str r5, [r4, #0]
    mov r0, r5
    bl  draw_page
    b   view_loop
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

@ r0 = cell x (0-29), r1 = cell y (0-19), r2 = font tile
draw_glyph:
    push {r4-r7, lr}
    ldr r3, =VRAM
    mov r4, #480
    mul r5, r1, r4
    add r3, r3, r5, lsl #3
    add r3, r3, r0, lsl #4
    ldr r5, =font_data
    add r5, r5, r2, lsl #3
    ldr r1, =0x7FFF
    mov r6, #8
dg_row:
    ldrb r7, [r5], #1
    mov r2, #0x80
    mov r12, r3
dg_col:
    tst r7, r2
    movne r4, #0
    moveq r4, r1
    strh r4, [r12], #2
    movs r2, r2, lsr #1
    bne dg_col
    add r3, r3, #480
    subs r6, r6, #1
    bne dg_row
    pop {r4-r7, pc}
    .ltorg

@ r0 = x, r1 = y, r2 = string (font tile bytes), r3 = length
draw_str:
    push {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, r3
1:  ldrb r2, [r6], #1
    mov r0, r4
    mov r1, r5
    bl  draw_glyph
    add r4, r4, #1
    subs r7, r7, #1
    bne 1b
    pop {r4-r7, pc}

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

@ r0 = x, r1 = y, r2 = 16-bit value
print_hex16:
    push {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r2, r6, lsr #8
    and r2, r2, #0xFF
    bl  print_hex8
    add r0, r4, #2
    mov r1, r5
    and r2, r6, #0xFF
    bl  print_hex8
    pop {r4-r6, pc}

@ r0 = page
draw_page:
    push {r4-r11, lr}
    mov r9, r0
    bl  clear_screen
    mov r0, #0
    mov r1, #0
    ldr r2, =str_title
    mov r3, #str_title_len
    bl  draw_str
    mov r0, #12
    mov r1, #0
    mov r2, r9
    bl  print_hex8
    mov r0, #0
    mov r1, #1
    ldr r2, =str_crc
    mov r3, #str_crc_len
    bl  draw_str
    ldr r0, =DATA
    mov r1, #180
    mul r2, r9, r1
    add r0, r0, r2
    bl  crc16
    mov r2, r0
    mov r0, #4
    mov r1, #1
    bl  print_hex16
    mov r0, #11
    mov r1, #1
    ldr r2, =str_all
    mov r3, #str_all_len
    bl  draw_str
    ldr r0, =DATA
    ldr r1, =720
    bl  crc16
    mov r2, r0
    mov r0, #15
    mov r1, #1
    bl  print_hex16
    mov r10, #0                    @ row
dp_row:
    mov r0, #90
    mul r7, r9, r0
    add r7, r7, r10, lsl #2
    add r7, r7, r10                @ r7 = first word index of the row
    cmp r9, #3
    movlt r6, r7, lsl #1           @ label: address
    subge r6, r7, #0x100           @ label: experiment number
    subge r6, r6, #0x0E
    mov r0, #0
    add r1, r10, #2
    mov r2, r6, lsr #8
    and r2, r2, #0xF
    add r2, r2, #1
    bl  draw_glyph
    mov r0, #1
    add r1, r10, #2
    and r2, r6, #0xFF
    bl  print_hex8
    mov r8, #0                     @ column
dp_col:
    add r0, r7, r8
    ldr r1, =DATA
    add r1, r1, r0, lsl #1
    ldrh r2, [r1]
    add r0, r8, r8, lsl #2
    add r0, r0, #4                 @ x = 4 + col*5
    add r1, r10, #2
    bl  print_hex16
    add r8, r8, #1
    cmp r8, #5
    blt dp_col
    add r10, r10, #1
    cmp r10, #18
    blt dp_row
    pop {r4-r11, pc}
    .ltorg

    .include "bootio_gen.inc"
