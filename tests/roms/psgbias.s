@ psgbias.s — GBA PSG-volume / SOUNDBIAS audio probe (built by psgbias.py;
@ procedure in tests/roms/README-probes-gba.md, "PSGBIAS").
@
@ One tone per STEP, the step's settings in 4x glyphs on screen so a photo
@ and a line-out recording match up.  Nothing here encodes an expected
@ level: the recording is the result.  Step table at the bottom; the
@ sequence is fixed so a single take, A pressed every few seconds, walks
@ the whole probe.  A = next, B = previous, START = replay; every step
@ opens with 15 frames of silence (the segment delimiter).
@
@ Sound plumbing (deterministic from power-on, no reliance on RAM):
@   PSG steps  ch1 square, 440 Hz (2048-298), duty 50%, envelope 15 held,
@              SOUNDCNT_L 1177 (ch1 L+R, 7/7), SOUNDCNT_H bits 0-1 = V
@   DS steps   FIFO A <- DMA1 <- EWRAM, timer 0 at 924 cycles/sample
@              (18157.6 Hz = 304 samples per frame exactly); ALL 256K of
@              EWRAM holds the waveform and DMA1 walks the EWRAM mirrors
@              (0x02000000-0x02FFFFFF) — no re-arming, no seams, 15 min
@              per step.  SQ = +127/-128, period 16.  TRI = +/-16 LSB
@              triangle, period 128.  SOUNDCNT_H 0B06: DS A 100% L+R,
@              timer 0, FIFO reset on start; PSG routed off.
@   SOUNDBIAS  0x0200 | R<<14 on every step.  SOUNDCNT_X stays 80h (a
@              master off/on would clear the PSG registers).
@ Variables live in IWRAM (EWRAM is the sample buffer).

    .arm
    .text
    .global _start

.equ IOBASE,   0x04000000
.equ VRAM,     0x06000000
.equ VARS,     0x03000000          @ +0 step +4 prev keys +8 auto counter
                                   @ +12 gap frames left +16 wave in EWRAM
.equ EWBUF,    0x02000000
.equ NSTEPS,   12
.equ GAP_FRAMES, 15
.equ AUTO_FRAMES, 180

_start:
    b   header_end
    .space 0x9C
    .space 0x20
header_end:
    b   main

main:
    mov r0, #IOBASE
    add r0, r0, #0x208
    mov r1, #0
    strh r1, [r0]                  @ IME off
    ldr r4, =VARS
    mov r0, #0
    str r0, [r4, #0]               @ step 0
    str r0, [r4, #8]
    str r0, [r4, #16]              @ no wave in EWRAM yet
    ldr r0, =0x03FF
    str r0, [r4, #4]
    mov r0, #IOBASE
    mov r1, #0x80
    strh r1, [r0, #0x84]           @ SOUNDCNT_X master on, once
    ldr r1, =0x0403                @ mode 3 + BG2
    strh r1, [r0]
    bl  apply_step                 @ draws + starts the gap

loop:
    bl  wait_vblank
    ldr r4, =VARS
    ldr r0, [r4, #12]              @ silence gap running?
    cmp r0, #0
    beq 1f
    subs r0, r0, #1
    str r0, [r4, #12]
    bleq start_step                @ gap over: sound on
1:  ldr r0, =0x04000130
    ldrh r0, [r0]
    ldr r1, [r4, #4]
    str r0, [r4, #4]
    mvn r2, r0
    and r2, r2, r1                 @ newly pressed
    ldr r5, [r4, #0]
.ifdef AUTOSTEP
    ldr r3, [r4, #8]
    add r3, r3, #1
    cmp r3, #AUTO_FRAMES
    movge r3, #0
    str r3, [r4, #8]
    bge step_next
.endif
    tst r2, #0x01                  @ A
    bne step_next
    tst r2, #0x02                  @ B
    bne step_prev
    tst r2, #0x08                  @ START
    bne step_redo
    b   loop
step_next:
    add r5, r5, #1
    cmp r5, #NSTEPS
    movge r5, #0
    b   step_store
step_prev:
    subs r5, r5, #1
    movlt r5, #NSTEPS-1
step_store:
    str r5, [r4, #0]
step_redo:
    bl  apply_step
    b   loop
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

@ ─────────────────────────────── sound ──────────────────────────────────
@ step -> r0 = table entry pointer
step_entry:
    ldr r1, =VARS
    ldr r1, [r1, #0]
    ldr r0, =step_table
    add r0, r0, r1, lsl #2
    bx  lr

@ everything off (SOUNDCNT_X stays on), redraw, open the gap
apply_step:
    push {r4, lr}
    mov r4, #IOBASE
    mov r0, #0
    strh r0, [r4, #0x80]           @ SOUNDCNT_L: no PSG routing
    strh r0, [r4, #0x82]           @ SOUNDCNT_H: DS A off
    ldr r1, =0x040000C6
    strh r0, [r1]                  @ DMA1CNT_H off
    str r0, [r4, #0x100]           @ TM0 off
    ldr r1, =VARS
    mov r0, #GAP_FRAMES
    str r0, [r1, #12]
    bl  draw_screen
    pop {r4, pc}
    .ltorg

start_step:
    push {r4-r7, lr}
    mov r4, #IOBASE
    bl  step_entry
    ldrb r5, [r0, #0]              @ source
    ldrb r6, [r0, #1]              @ PSG volume
    ldrb r7, [r0, #2]              @ bias resolution
    mov r0, r7, lsl #14
    orr r0, r0, #0x200
    strh r0, [r4, #0x88]           @ SOUNDBIAS
    cmp r5, #0
    bne ds_start
    strh r6, [r4, #0x82]           @ SOUNDCNT_H: PSG volume only
    ldr r0, =0x1177
    strh r0, [r4, #0x80]           @ ch1 L+R, 7/7
    mov r0, #0
    strh r0, [r4, #0x60]           @ no sweep
    ldr r0, =0xF080                @ envelope 15, duty 50%
    strh r0, [r4, #0x62]
    ldr r0, =0x8000 + 1750         @ trigger, 440 Hz
    strh r0, [r4, #0x64]
    pop {r4-r7, pc}
ds_start:
    ldr r1, =VARS
    ldr r0, [r1, #16]
    cmp r0, r5                     @ EWRAM already holds this wave?
    beq 1f
    str r5, [r1, #16]
    ldr r2, =wave_square
    mov r3, #wave_square_len / 4
    cmp r5, #2
    ldreq r2, =wave_tri
    moveq r3, #wave_tri_len / 4
    bl  fill_ewram
1:  ldr r0, =0x0B06                @ DS A 100% L+R, timer 0, FIFO reset
    strh r0, [r4, #0x82]
    ldr r1, =0x040000BC            @ DMA1 SAD/DAD/CNT
    ldr r0, =EWBUF
    str r0, [r1]
    ldr r0, =0x040000A0            @ FIFO_A
    str r0, [r1, #4]
    ldr r0, =0xB6000000            @ enable, repeat, 32-bit, FIFO, dst fixed
    str r0, [r1, #8]
    ldr r0, =0x0080FC64            @ TM0: reload 65536-924, enable
    str r0, [r4, #0x100]
    pop {r4-r7, pc}
    .ltorg

@ r2 = period bytes (ROM), r3 = period length in words: tile it over EWRAM
fill_ewram:
    push {r4-r7, lr}
    ldr r4, =EWBUF
    mov r5, #0x10000               @ words
1:  mov r6, r2
    mov r7, r3
2:  ldr r0, [r6], #4
    str r0, [r4], #4
    subs r7, r7, #1
    bne 2b
    subs r5, r5, r3
    bne 1b
    pop {r4-r7, pc}
    .ltorg

@ ────────────────────────────── display ─────────────────────────────────
draw_screen:
    push {r4-r8, lr}
    ldr r0, =VRAM
    ldr r1, =0x7FFF7FFF
    ldr r2, =240*160/2
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    bl  step_entry
    mov r8, r0
    @ line 1: STEP nn
    mov r0, #8
    mov r1, #4
    ldr r2, =str_step
    mov r3, #str_step_len
    bl  big_str
    ldr r4, =VARS
    ldr r4, [r4, #0]
    mov r5, #0                     @ tens
2:  cmp r4, #10
    blt 3f
    sub r4, r4, #10
    add r5, r5, #1
    b   2b
3:  mov r0, #168
    mov r1, #4
    add r2, r5, #1
    bl  big_glyph
    mov r0, #200
    mov r1, #4
    add r2, r4, #1
    bl  big_glyph
    @ line 2: PSG Vn / DS SQ / DS TRI
    ldrb r5, [r8, #0]
    cmp r5, #0
    bne 4f
    mov r0, #8
    mov r1, #44
    ldr r2, =str_psg
    mov r3, #str_psg_len
    bl  big_str
    ldrb r2, [r8, #1]
    add r2, r2, #1
    mov r0, #168
    mov r1, #44
    bl  big_glyph
    b   5f
4:  ldr r2, =str_ds_sq
    mov r3, #str_ds_sq_len
    cmp r5, #2
    ldreq r2, =str_ds_tri
    moveq r3, #str_ds_tri_len
    mov r0, #8
    mov r1, #44
    bl  big_str
    @ line 3: BIAS Rn
5:  mov r0, #8
    mov r1, #84
    ldr r2, =str_bias
    mov r3, #str_bias_len
    bl  big_str
    ldrb r2, [r8, #2]
    add r2, r2, #1
    mov r0, #200
    mov r1, #84
    bl  big_glyph
    @ small: register values this step programs
    mov r0, #0
    mov r1, #15
    ldr r2, =str_cnth
    mov r3, #str_cnth_len
    bl  draw_str
    ldrb r5, [r8, #0]
    ldrb r6, [r8, #1]
    cmp r5, #0
    ldrne r6, =0x0B06
    mov r0, #11
    mov r1, #15
    mov r2, r6, lsr #8
    bl  print_hex8
    mov r0, #13
    mov r1, #15
    and r2, r6, #0xFF
    bl  print_hex8
    mov r0, #15
    mov r1, #15
    ldr r2, =str_biasr
    mov r3, #str_biasr_len
    bl  draw_str
    ldrb r7, [r8, #2]
    mov r7, r7, lsl #14
    orr r7, r7, #0x200
    mov r0, #21
    mov r1, #15
    mov r2, r7, lsr #8
    bl  print_hex8
    mov r0, #23
    mov r1, #15
    and r2, r7, #0xFF
    bl  print_hex8
    mov r0, #0
    mov r1, #17
    ldr r2, =str_keys
    mov r3, #str_keys_len
    bl  draw_str
    mov r0, #0
    mov r1, #19
    ldr r2, =str_title
    mov r3, #str_title_len
    bl  draw_str
    pop {r4-r8, pc}
    .ltorg

@ r0 = x px, r1 = y px, r2 = font tile: 8x8 glyph drawn 4x (32x32)
big_glyph:
    push {r4-r11, lr}
    ldr r3, =VRAM
    mov r4, #480
    mla r3, r1, r4, r3             @ + y*480
    add r3, r3, r0, lsl #1         @ + x*2
    ldr r5, =font_data
    add r5, r5, r2, lsl #3
    mov r6, #8                     @ glyph rows
bg_row:
    ldrb r7, [r5], #1
    mov r9, #4                     @ 4 screen rows per glyph row
bg_line:
    mov r2, #0x80
    mov r12, r3
bg_col:
    tst r7, r2
    movne r4, #0
    ldreq r4, =0x7FFF
    strh r4, [r12], #2
    strh r4, [r12], #2
    strh r4, [r12], #2
    strh r4, [r12], #2
    movs r2, r2, lsr #1
    bne bg_col
    add r3, r3, #480
    subs r9, r9, #1
    bne bg_line
    subs r6, r6, #1
    bne bg_row
    pop {r4-r11, pc}
    .ltorg

@ r0 = x px, r1 = y px, r2 = string, r3 = length (32 px per glyph)
big_str:
    push {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, r3
1:  ldrb r2, [r6], #1
    mov r0, r4
    mov r1, r5
    bl  big_glyph
    add r4, r4, #32
    subs r7, r7, #1
    bne 1b
    pop {r4-r7, pc}

@ r0 = cell x, r1 = cell y, r2 = font tile (8x8)
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

print_hex8:
    push {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r2, r6, lsr #4
    and r2, r2, #0xF
    add r2, r2, #1
    bl  draw_glyph
    and r2, r6, #0xF
    add r2, r2, #1
    add r0, r4, #1
    mov r1, r5
    bl  draw_glyph
    pop {r4-r6, pc}

@ ─────────────────────────────── data ────────────────────────────────────
    .align 2
@ source (0 PSG, 1 DS square, 2 DS triangle), PSG volume, bias res, pad
step_table:
    .byte 0, 2, 0, 0               @  0 PSG V2 R0  (100%) reference
    .byte 0, 3, 0, 0               @  1 PSG V3 R0  (prohibited value)
    .byte 0, 1, 0, 0               @  2 PSG V1 R0  (50%)
    .byte 0, 0, 0, 0               @  3 PSG V0 R0  (25%)
    .byte 1, 2, 0, 0               @  4 DS SQ R0
    .byte 1, 2, 1, 0               @  5 DS SQ R1
    .byte 1, 2, 2, 0               @  6 DS SQ R2
    .byte 1, 2, 3, 0               @  7 DS SQ R3
    .byte 2, 2, 0, 0               @  8 DS TRI R0
    .byte 2, 2, 1, 0               @  9 DS TRI R1
    .byte 2, 2, 2, 0               @ 10 DS TRI R2
    .byte 2, 2, 3, 0               @ 11 DS TRI R3

    .include "psgbias_gen.inc"
