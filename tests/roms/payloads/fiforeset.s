@ fiforeset.s -- does a sound-FIFO reset drop the word being played?
@
@ WHAT: FIFO A (right) and FIFO B (left) both on TM0, period 2048. Each FIFO
@ is first drained (one word stored, eight overflows: the word is played out
@ and the FIFO is empty), then given four words; TM0 plays k samples and
@ stops; the FIFOs are reset (v = 0: SOUNDCNT_H's reset bits, as the m4a
@ SoundInit writes them; v = 1: SOUNDCNT_X master off and on); four more
@ words go in, DMA1 -> FIFO A and DMA2 -> FIFO B are armed (sound FIFO,
@ 32-bit, repeat, with their IRQ bits), TM0 runs again and the payload counts
@ its overflows until each channel's first refill burst flags IF.
@ WHY: Kingdom Hearts - Chain of Memories resets both FIFOs as it restarts
@ its sound after the opening movie, with FIFO A part-way through a word
@ and FIFO B empty. Both reference emulators keep playing the rest of the
@ word FIFO A was on after the reset (their output: a 15-sample resync
@ offset between B and A for the rest of the game); dingbat drops it.
@ READING: four fresh words alone ask at the second overflow (index 2).
@ Each sample left over from a word that survives the reset delays that by
@ one: a reset after k samples leaves (4 - k mod 4) mod 4 of them, so k = 0..7
@ reads 2 5 4 3 2 5 4 3 if the word survives, 2 everywhere if it does not.
@ Both channels behave alike (A and B carry the same history).
@ PROVENANCE: dingbat (word dropped) 2 everywhere; both reference emulators
@ 2 5 4 3 2 5 4 3 2 for v = 0. For v = 1 one reference keeps the word the
@ same way and mgba does not empty the FIFO at all (18 - k); the console's
@ fifomap cells (r0-agb.json) already say the master enable empties it, word
@ and all (predict 2 throughout). Console: not yet run.
@
@ r0 bits 0..7 k, bit 8 v
@ answer: A | B << 8 | overflows counted << 16; bit 23 a timeout (no burst
@ in 40 overflows), bit 31 the V-blank guard fired
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    mov r4, #0x04000000
    add r10, r4, #0x200            @ IE / IF
    ldrh r0, [r4, #0x84]
    ldrh r1, [r4, #0x82]
    orr r0, r0, r1, lsl #16
    str r0, saved                  @ SOUNDCNT_H << 16 | SOUNDCNT_X
    ldrh r0, [r10]
    str r0, savedie
    ldr r1, =0x0608
    bic r0, r0, r1
    strh r0, [r10]                 @ IE without TM0 / DMA1 / DMA2 (IME untouched)
    mov r0, #0
    str r0, [r4, #0x100]           @ TM0 off
    strh r0, [r4, #0xC6]           @ DMA1 off
    strh r0, [r4, #0xD2]           @ DMA2 off
    strh r0, [r4, #0xBA]           @ DMA0 off
    @ start just after a V-blank begins: the whole run (< 60 lines) ends
    @ before the next one
1:  ldrh r0, [r4, #6]
    cmp r0, #161
    bne 1b
    @ guard: DMA0 on V-blank zeroes DMA1CNT..DMA2CNT (four words from C4)
    adr r1, zeros
    str r1, [r4, #0xB0]
    add r1, r4, #0xC4
    str r1, [r4, #0xB4]
    mov r1, #4
    strh r1, [r4, #0xB8]
    ldr r1, =0x9500                @ on, V-blank, 32-bit, src fixed, dst inc
    strh r1, [r4, #0xBA]
    mov r1, #0x80
    strh r1, [r4, #0x84]           @ master on
    ldr r1, =0xA90E
    strh r1, [r4, #0x82]           @ A right, B left, both on TM0, both reset
    ldr r1, =0x02004000
    str r1, [r4, #0xBC]            @ DMA1SAD (EWRAM, the experiments' area)
    ldr r1, =0x040000A0
    str r1, [r4, #0xC0]            @ DMA1DAD = FIFO A
    mov r1, #4
    strh r1, [r4, #0xC4]
    ldr r1, =0x02004400
    str r1, [r4, #0xC8]            @ DMA2SAD
    ldr r1, =0x040000A4
    str r1, [r4, #0xCC]            @ DMA2DAD = FIFO B
    mov r1, #4
    strh r1, [r4, #0xD0]
    @ drain: one word each, eight samples
    mov r0, #1
    bl store
    mov r0, #8
    bl play
    @ four words, k samples
    mov r0, #4
    bl store
    and r0, r11, #0xFF
    bl play
    @ the reset
    tst r11, #0x100
    ldreq r1, =0xA90E
    streqh r1, [r4, #0x82]
    movne r1, #0
    strneh r1, [r4, #0x84]         @ master off ...
    movne r1, #0x80
    strneh r1, [r4, #0x84]         @ ... and on
    ldr r1, =0x210E
    strh r1, [r4, #0x82]           @ routing as before, no reset bits
    mov r0, #4
    bl store
    @ measure
    ldr r1, =0xF640                @ on, IRQ, sound FIFO, repeat, 32-bit, dst fixed
    strh r1, [r4, #0xC6]
    strh r1, [r4, #0xD2]
    ldr r1, =0x0608
    strh r1, [r10, #2]             @ clear IF TM0 / DMA1 / DMA2
    ldr r1, =0x00C0F800            @ TM0: reload 0x10000 - 2048, IRQ bit, /1, on
    mov r5, #0                     @ A's index
    mov r6, #0                     @ B's index
    mov r7, #0                     @ overflows
    str r1, [r4, #0x100]
mloop:
    ldr r2, =4000
2:  ldrh r1, [r10, #2]
    tst r1, #8
    bne 3f
    subs r2, r2, #1
    bne 2b
    orr r7, r7, #0x80              @ no overflow: give up
    b mdone
3:  add r7, r7, #1
    mov r1, #8
    strh r1, [r10, #2]
    mov r2, #20                    @ ~80 cycles: a burst it asked for lands first
4:  subs r2, r2, #1
    bne 4b
    ldrh r1, [r10, #2]
    tst r1, #0x200
    beq 5f
    cmp r5, #0
    moveq r5, r7
5:  tst r1, #0x400
    beq 6f
    cmp r6, #0
    moveq r6, r7
6:  cmp r5, #0
    cmpne r6, #0
    bne mdone
    cmp r7, #40
    blt mloop
    orr r7, r7, #0x80
mdone:
    mov r0, #0
    str r0, [r4, #0x100]           @ TM0 off first: no more requests
    mov r2, #40                    @ ~160 cycles: any burst still owed ends
7:  subs r2, r2, #1
    bne 7b
    strh r0, [r4, #0xC6]           @ DMA1 off
    strh r0, [r4, #0xD2]           @ DMA2 off
    ldrh r2, [r4, #0xBA]
    tst r2, #0x8000
    orreq r7, r7, #0x8000          @ the guard ran
    strh r0, [r4, #0xBA]           @ DMA0 off
    ldr r1, =0x0608
    strh r1, [r10, #2]
    ldr r0, savedie
    strh r0, [r10]
    ldr r0, saved
    orr r1, r0, #0x88000000        @ FIFO A and B reset, as found otherwise
    mov r1, r1, lsr #16
    strh r1, [r4, #0x82]
    strh r0, [r4, #0x84]
    orr r0, r5, r6, lsl #8
    orr r0, r0, r7, lsl #16
    ldmfd sp!, {r4-r11, lr}
    bx lr

store:                             @ r0 words into each FIFO
    ldr r1, =0x11223344
1:  str r1, [r4, #0xA0]
    str r1, [r4, #0xA4]
    subs r0, r0, #1
    bne 1b
    mov pc, lr

play:                              @ r0 TM0 overflows (period 2048), then stop
    cmp r0, #0
    moveq pc, lr
    mov r1, #8
    strh r1, [r10, #2]
    ldr r1, =0x00C0F800
    str r1, [r4, #0x100]
1:  ldr r2, =4000
2:  ldrh r1, [r10, #2]
    tst r1, #8
    bne 3f
    subs r2, r2, #1
    bne 2b
3:  mov r1, #8
    strh r1, [r10, #2]
    subs r0, r0, #1
    bne 1b
    ldr r1, =0xF800
    str r1, [r4, #0x100]           @ TM0 off
    mov pc, lr

    .align 2
saved:   .word 0
savedie: .word 0
zeros:   .word 0
    .ltorg
