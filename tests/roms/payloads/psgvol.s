@ psgvol.s -- the PSG's master volume (SOUNDCNT_L bits 0-2 / 4-6) and the
@ PSG : DirectSound ratio, by ear (tools/hwlink/psgvol_listen.py).
@
@ dingbat's GBA mixer scales the PSG by V / 8 (V = 0 silent); its GB core,
@ after Pan Docs, by (V + 1) / 8. Every tone here is 1024 Hz, so the
@ microphone's response is the same for all of them:
@   P<V>   channel 2, 50% duty, f = 1920, NR22 volume 15, master V (both
@          sides), PSG at 100%
@   D100   DirectSound A at 100% (timer 0 at 32768 Hz, DMA1 from a square
@          wave of 16 samples 0x7F, 16 samples 0x80), the PSG silent
@   D50    the same at 50%
@ Order (0.35 s a tone, 0.25 s silence, after a 0.5 s volume-12 sync tone),
@ played twice:
@   P7 P3 P0 P1 P5 P7 D100 D50 P7 D100
@ V / 8 predicts P3 / P7 = 0.43, P1 / P7 = 0.14, P5 / P7 = 0.71 and P0
@ silent; (V + 1) / 8 predicts 0.50, 0.25, 0.75 and P0 at 0.125.
@ D50 / D100 is 0.5 unless the DAC clips D100: a full-swing square at 100%
@ is +-512 in the 10-bit sum, which fits 0..3FFh only around a bias of
@ 200h (SOUNDBIAS's default register value; dingbat took the field, 100h,
@ and read 0.67 here). In the emulators (2026-10-02), D100 / P7 and the
@ rule: dingbat before 3.64 and V / 8 (clipped), after 4.23 and (V + 1) / 8;
@ the second reference 4.25, (V + 1) / 8; mGBA about 4.1, (V + 1) / 8.
@ answer: 0x600D when it has played everything.
    .include "probe.inc"
    .arm
    .text
    .global _start

    .equ BUF, 0x02010000
    .equ BUFLEN, 0x4000            @ 16 KB: 0.5 s at 32768 Hz
    .equ TONE, 22938               @ 0.35 s in TM2 ticks (256 cycles)
    .equ GAP, 16384                @ 0.25 s

    @ a PSG tone at master volume \v
    .macro ptone v
    ldr r0, =(0x2200 | \v | (\v << 4))
    bl psg
    .endm

_start:
    probe_enter
    @ the DirectSound wave: 16 x 0x7F, 16 x 0x80, over and over
    ldr r0, =BUF
    ldr r1, =0x7F7F7F7F
    ldr r2, =0x80808080
    add r3, r0, #BUFLEN
1:  stmia r0!, {r1}
    stmia r0!, {r1}
    stmia r0!, {r1}
    stmia r0!, {r1}
    stmia r0!, {r2}
    stmia r0!, {r2}
    stmia r0!, {r2}
    stmia r0!, {r2}
    cmp r0, r3
    blo 1b

    mov r0, #0
    strh r0, [r4, #0x84]           @ master off (clears the PSG) and on
    mov r0, #0x80
    strh r0, [r4, #0x84]
    mov r0, #2                     @ PSG 100%, DirectSound off
    strh r0, [r4, #0x82]
    mov r0, #0x80                  @ NR21 duty 50%
    strb r0, [r4, #0x68]
    ldr r0, =0x00820000            @ TM2: 256 cycles a tick
    str r0, [r10, #8]
    ldrh r7, [r10, #8]
    ldr r0, =GAP
    bl wait_for
    bl wait_for                    @ 0.5 s of silence
    ldr r0, =0x2277                @ sync: master 7, volume 12, 0.5 s
    strh r0, [r4, #0x80]
    mov r0, #0xC0
    strb r0, [r4, #0x69]
    ldr r0, =0x8780
    strh r0, [r4, #0x6C]
    ldr r0, =GAP
    bl wait_for
    bl wait_for
    mov r0, #0
    strb r0, [r4, #0x69]           @ DAC off
    ldr r0, =GAP
    bl wait_for

    mov r9, #2
round:
    ptone 7
    ptone 3
    ptone 0
    ptone 1
    ptone 5
    ptone 7
    ldr r0, =0x0306                @ D100: PSG 100%, A 100%, A both sides
    bl dsound
    ldr r0, =0x0302                @ D50
    bl dsound
    ptone 7
    ldr r0, =0x0306
    bl dsound
    subs r9, r9, #1
    bne round

    mov r0, #0
    strh r0, [r4, #0x84]           @ master off on the way out
    str r0, [r10, #8]              @ TM2 off
    ldr r0, =0x600D
    ldr r8, =0x040000B0            @ probe_leave uses r8 (DMA0), r10, r11
    ldr r10, =0x04000100
    probe_leave

@ channel 2 at volume 15 with SOUNDCNT_L = r0, TONE on, GAP off
psg:
    push {lr}
    strh r0, [r4, #0x80]
    mov r0, #0xF0
    strb r0, [r4, #0x69]
    ldr r0, =0x8780
    strh r0, [r4, #0x6C]
    ldr r0, =TONE
    bl wait_for
    mov r0, #0
    strb r0, [r4, #0x69]           @ DAC off
    ldr r0, =GAP
    bl wait_for
    pop {lr}
    bx lr

@ DirectSound A with SOUNDCNT_H = r0 (plus the FIFO reset), TONE on, GAP off
dsound:
    push {lr}
    orr r0, r0, #0x0800            @ reset FIFO A
    strh r0, [r4, #0x82]
    ldr r1, =0x040000C4            @ DMA1: the wave -> FIFO A, sound timing
    ldr r2, =BUF
    str r2, [r1, #-8]
    ldr r2, =0x040000A0
    str r2, [r1, #-4]
    ldr r2, =0xB6400000
    str r2, [r1]
    ldr r2, =0x0080FE00            @ TM0: 512 cycles a sample, on
    str r2, [r10]
    ldr r0, =TONE
    bl wait_for
    mov r2, #0
    str r2, [r10]                  @ TM0 off
    str r2, [r1]                   @ DMA1 off
    mov r2, #2
    strh r2, [r4, #0x82]           @ DirectSound off
    ldr r0, =GAP
    bl wait_for
    pop {lr}
    bx lr

@ r7 += r0, then wait until TM2 reaches r7 (mod 65536; r0 < 32768).
@ r0 survives; r8 does not.
wait_for:
    add r7, r7, r0
3:  ldrh r8, [r10, #8]
    sub r8, r8, r7
    movs r8, r8, lsl #16
    bmi 3b
    bx lr

    probe_data
