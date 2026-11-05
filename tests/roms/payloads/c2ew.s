@ payload: dbsuite CONTEND2's row (c2_row) as the multiboot build runs it --
@ from EWRAM -- behind a V-count park and a phase sweep.
@
@ The parked CONTEND2 page run from EWRAM on an AGB SP (scratch multiboot
@ build, 2026-11-04) reads contend-pram-mode0 0xBC and contend-vram-mode0
@ 0xE3 where dingbat reads 0xBD and 0xE2, every other row the same; c2seq.s
@ (the same sixteen reads from IWRAM, ten cycles apart) matches at all of
@ k = 60..259. So: the row itself -- `wait_line40` (VCOUNT polled to 39 then
@ 40), the page's tm_start, sixteen back-to-back `ldrh` from PRAM or VRAM,
@ tm_stop -- copied to EWRAM with the page's helpers, under the page's
@ scene (mode 0, four text BGs, 128 64x64 OBJs on line 40 and on).
@
@ r0: bits 0-3 d, bits 16-19 c (d + 4c cycles after the wake), bit 4 VRAM
@     06000000 (else PRAM 05000000), bit 5 the page's poll (park on line 38,
@     then wait_line40) -- else park on line 40 and read straight away,
@     bit 6 the OBJ layer off (C2_M0NO).
@ answer: TM0 at tm_stop (the row's value) | TM1 << 16.
    .arm
    .text
    .global _start
    .include "probe.inc"
.equ EWSTUB, 0x02010000

_start:
    probe_enter
    @ the page's scene, written under forced blank
    mov r0, #0x80
    strh r0, [r4]
    mov r0, #0
    strh r0, [r4, #0x08]
    strh r0, [r4, #0x0A]
    strh r0, [r4, #0x0C]
    strh r0, [r4, #0x0E]
    ldr r0, =0x07000000            @ 128 OBJs, 64x64, Y = 40, X = 0..127
    mov r1, #0
1:  mov r2, #40
    orr r3, r1, #0xC000
    orr r2, r2, r3, lsl #16
    str r2, [r0], #4
    mov r2, #0
    str r2, [r0], #4
    add r1, r1, #1
    cmp r1, #128
    blt 1b
    mov r0, #0x100
    strh r0, [r4, #0x20]
    strh r0, [r4, #0x26]
    strh r0, [r4, #0x30]
    strh r0, [r4, #0x36]
    @ the row to EWRAM
    adr r0, stub
    adr r2, stub_end
    ldr r1, =EWSTUB
2:  ldr r3, [r0], #4
    str r3, [r1], #4
    cmp r0, r2
    blt 2b
    @ the target (patched into the stub's literal), the poll, the scene
    tst r9, #0x10
    ldreq r2, =0x05000000
    ldrne r2, =0x06000000
    adr r0, base_lit
    adr r3, stub
    sub r0, r0, r3
    ldr r3, =EWSTUB
    str r2, [r0, r3]
    tst r9, #0x20
    moveq r1, #40
    movne r1, #38
    ldr r6, =EWSTUB
    tst r9, #0x20
    addeq r6, r6, #24              @ no poll: straight into stub_reads (6 words in)
    tst r9, #0x40
    ldreq r7, =0x1F40              @ C2_M0
    ldrne r7, =0x0F40              @ C2_M0NO
    strh r7, [r4]                  @ the scene on, as c2_row's first store
    mov r0, r1, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x04
    strh r0, [r5]
    mvn r0, #0
    strh r0, [r5, #2]
    swi 0x020000                   @ park
    mov r0, r9, lsr #16
    and r0, r0, #15
    add r0, r0, #1
4:  subs r0, r0, #1
    bne 4b
    probe_sled
    mov lr, pc
    bx  r6
    mov r9, r0
    mov r0, #0x80
    strh r0, [r4]
    mov r0, r9
    probe_leave

stub:                              @ wait_line40, then c2_row's body
1:  ldrh r0, [r4, #6]
    cmp r0, #39
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, #40
    bne 2b
stub_reads:
    push {lr}
    bl  tm_start_ew
    ldr r2, base_lit               @ c2_row: `ldr r2, =base` after tm_start
    .rept 16
    ldrh r3, [r2]
    .endr
    bl  tm_stop_ew
    pop {pc}
tm_start_ew:                       @ the page's tm_start, word for word
    ldr r3, =0x04000100
    mov r2, #0
    str r2, [r3]
    str r2, [r3, #4]
    ldr r1, =0x00840000
    str r1, [r3, #4]
    ldr r2, =0x00800000
    str r2, [r3]
    bx  lr
tm_stop_ew:                        @ the page's tm_stop
    ldr r3, =0x04000100
    ldrh r0, [r3]
    ldrh r1, [r3, #4]
    mov r2, #0
    str r2, [r3]
    str r2, [r3, #4]
    orr r0, r0, r1, lsl #16
    bx  lr
    .ltorg
base_lit:
    .word 0
stub_end:
    probe_data
