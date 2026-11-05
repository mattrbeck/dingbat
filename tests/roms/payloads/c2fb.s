@ payload: when the renderer comes back after forced blank -- c2ew.s's row
@ (from EWRAM, sixteen ldrh from PRAM or VRAM under CONTEND2's scene, 128
@ 64x64 OBJs) with forced blank on until a V-count wake on line L, the
@ scene's DISPCNT stored straight after it, then line N polled and read.
@
@ The parked CONTEND2 page from EWRAM on an AGB SP: its first row, which
@ leaves forced blank two lines before it reads, saw no contention at all;
@ dingbat drew line 40 and charged PRAM a cycle at one phase in four, VRAM
@ up to 48. Leaving it on line 37 or earlier, line 40 reads as drawn.
@
@ r0: bits 0-3 d, bits 16-19 c (d + 4c cycles after the wake), bit 4 VRAM
@     06000000 (else PRAM 05000000), bits 24-31 L (forced blank off on that
@     line's wake), bits 8-15 N (the line read; 0 = 40), bit 6 the OBJ layer
@     off (C2_M0NO), bits 20-23 k: 256k more cycles before the store (to
@     move it across line L).
@ answer: TM0 at tm_stop | TM1 << 16.
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
    mov r1, r9, lsr #24            @ L
    ldr r6, =EWSTUB
    tst r9, #0x40
    ldreq r7, =0x1F40              @ C2_M0
    ldrne r7, =0x0F40              @ C2_M0NO
    mov r0, #0x80                  @ forced blank until the wake
    strh r0, [r4]
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
    mov r0, r9, lsr #20            @ k x 256 cycles
    and r0, r0, #15
    mov r0, r0, lsl #6
    add r0, r0, #1
5:  subs r0, r0, #1
    bne 5b
    probe_sled
    mov r9, r9, lsr #8             @ N for the stub's poll
    ands r9, r9, #0xFF
    moveq r9, #40
    mov lr, pc
    bx  r6
    mov r9, r0
    mov r0, #0x80
    strh r0, [r4]
    mov r0, r9
    probe_leave

stub:                              @ the scene's DISPCNT store, then line N polled
    strh r7, [r4]
    sub r1, r9, #1
1:  ldrh r0, [r4, #6]
    cmp r0, r1
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, r9
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
