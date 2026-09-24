@ switime.s -- how long each BIOS call takes, called from IWRAM.
@
@ WHAT: TM0 at prescaler 1 is started by the instruction before an ARM
@ `swi` and read by the instruction after it, so the count is the whole
@ call -- the SWI exception, the BIOS's dispatch, the function and the
@ return -- plus the fixed cost of the start and the read (subject 0, no
@ call at all).  Inputs are small and fixed so every count fits 16 bits;
@ buffers are in IWRAM so no count depends on a wait state.
@ WHY: an HLE BIOS gets the answers right and the time wrong.  Games time
@ against these calls (a CpuFastSet in V-blank, a decompression before a
@ fade), so the cost is behaviour, not trivia.  Nintendo's BIOS is the
@ reference; the timings are its behaviour, not its code.
@ PROVENANCE: dbsuite (2026-09-24); the answers are the AGB SP's, recorded
@ through tests/roms/dbsuite/record.py (3 runs a cell) into sp-agb.json.
@
@ r0 in = subject (table below); r0 out = TM0 ticks.  IME is held clear
@ while the call runs and put back afterwards.
    .arm
    .text
    .global _start

.equ BUF_A, 0x03004000             @ 1 KB source
.equ BUF_B, 0x03004400             @ 1 KB destination

_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    mov r4, #0x04000000
    add r7, r4, #0x200
    ldrh r5, [r7, #8]              @ IME, kept
    mov r0, #0
    strh r0, [r7, #8]
    str r0, [r4, #0x100]           @ TM0 off, reload 0
    ldr r0, =BUF_A                 @ a known source: words i * 0x01010101
    ldr r1, =0x01010101
    mov r2, #0
    mov r3, #256
1:  str r2, [r0], #4
    add r2, r2, r1
    subs r3, r3, #1
    bne 1b
    ldr r0, =subjects
    cmp r11, #(subjects_end - subjects) / 4
    movhs r11, #0
    ldr r0, [r0, r11, lsl #2]
    mov r10, #0x04000000
    add r10, r10, #0x100           @ TM0
    mov r8, #0x80                  @ TM0CNT_H: on, /1
    mov lr, pc
    bx r0
    mov r6, r0                     @ TM0 ticks
    mov r0, #0
    str r0, [r4, #0x100]           @ TM0 off
    add r7, r4, #0x200
    strh r5, [r7, #8]
    mov r0, r6
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg

@ Each subject sets the call's registers, then runs the timed three:
@   strh r8, [r10, #2]  /  swi  /  ldrh r0, [r10]
@ and returns with r0 = the count.  BIOS calls keep r4-r11 and lr_svc is
@ theirs, so the subject's own return address is parked in r9.
.macro timed n
    mov r9, lr
    strh r8, [r10, #2]
    swi \n << 16
    ldrh r0, [r10]
    bx r9
.endm

subjects:
    .word s_none, s_div, s_div_big, s_divarm, s_sqrt0, s_sqrt_mid, s_sqrt_max
    .word s_arctan, s_arctan2, s_arctan2_neg, s_cpuset16, s_cpuset_fill
    .word s_fastset, s_fastset_fill, s_checksum, s_bgaffine, s_objaffine
    .word s_bitunpack, s_lz77, s_rl, s_diff8, s_midikey, s_intrwait
subjects_end:

s_none:                            @ 0: the start and the read alone
    mov r9, lr
    strh r8, [r10, #2]
    ldrh r0, [r10]
    bx r9
s_div:                             @ 1: Div 10 / 3
    mov r0, #10
    mov r1, #3
    timed 0x06
s_div_big:                         @ 2: Div 0x7FFFFFFF / 3 (many quotient bits)
    mvn r0, #0x80000000
    mov r1, #3
    timed 0x06
s_divarm:                          @ 3: DivArm 10 / 3
    mov r0, #3
    mov r1, #10
    timed 0x07
s_sqrt0:                           @ 4: Sqrt 0
    mov r0, #0
    timed 0x08
s_sqrt_mid:                        @ 5: Sqrt 0x3FFFFFFF
    mvn r0, #0xC0000000
    timed 0x08
s_sqrt_max:                        @ 6: Sqrt 0xFFFFFFFF
    mvn r0, #0
    timed 0x08
s_arctan:                          @ 7: ArcTan 0x2000
    mov r0, #0x2000
    timed 0x09
s_arctan2:                         @ 8: ArcTan2 (0x100, 0x100)
    mov r0, #0x100
    mov r1, #0x100
    timed 0x0A
s_arctan2_neg:                     @ 9: ArcTan2 (-0x100, -0x80)
    mvn r0, #0xFF
    mvn r1, #0x7F
    timed 0x0A
s_cpuset16:                        @ 10: CpuSet, 32 halfwords copied
    ldr r0, =BUF_A
    ldr r1, =BUF_B
    mov r2, #32
    timed 0x0B
s_cpuset_fill:                     @ 11: CpuSet, 32 words filled
    ldr r0, =BUF_A
    ldr r1, =BUF_B
    ldr r2, =0x05000020
    timed 0x0B
s_fastset:                         @ 12: CpuFastSet, 256 words copied
    ldr r0, =BUF_A
    ldr r1, =BUF_B
    mov r2, #256
    timed 0x0C
s_fastset_fill:                    @ 13: CpuFastSet, 256 words filled
    ldr r0, =BUF_A
    ldr r1, =BUF_B
    ldr r2, =0x01000100
    timed 0x0C
s_checksum:                        @ 14: GetBiosChecksum
    timed 0x0D
s_bgaffine:                        @ 15: BgAffineSet, one entry
    ldr r0, =bg_src
    ldr r1, =BUF_B
    mov r2, #1
    timed 0x0E
s_objaffine:                       @ 16: ObjAffineSet, one entry, stride 2
    ldr r0, =obj_src
    ldr r1, =BUF_B
    mov r2, #1
    mov r3, #2
    timed 0x0F
s_bitunpack:                       @ 17: BitUnPack, 4 bytes of 1 bit to 4 bits
    ldr r0, =BUF_A
    ldr r1, =BUF_B
    ldr r2, =bup_info
    timed 0x10
s_lz77:                            @ 18: LZ77UnCompWram, 16 bytes
    ldr r0, =lz_src
    ldr r1, =BUF_B
    timed 0x11
s_rl:                              @ 19: RLUnCompWram, 16 bytes
    ldr r0, =rl_src
    ldr r1, =BUF_B
    timed 0x14
s_diff8:                           @ 20: Diff8bitUnFilterWram, 16 bytes
    ldr r0, =diff_src
    ldr r1, =BUF_B
    timed 0x16
s_midikey:                         @ 21: MidiKey2Freq, key 60, no fine pitch
    ldr r0, =wave
    mov r1, #60
    mov r2, #0
    timed 0x1F
s_intrwait:                        @ 22: IntrWait (0, 1) with its flag already set:
    ldr r2, =0x03007FF8            @ the immediate return, IE left clear
    ldrh r0, [r2]
    orr r0, r0, #1
    strh r0, [r2]
    mov r0, #0
    mov r1, #1
    timed 0x04
    .ltorg

    .align 2
bg_src:                            @ ox, oy (s32 19.8), cx, cy (s16), sx, sy (s16 8.8), angle
    .word 0x00008000, 0x00004000
    .hword 120, 80, 0x0100, 0x0100, 0x2000, 0
obj_src:                           @ sx, sy (8.8), angle, pad
    .hword 0x0100, 0x0200, 0x4000, 0
bup_info:                          @ source length, source width, dest width, offset
    .hword 4
    .byte 1, 4
    .word 0
lz_src:                            @ 16 bytes: 8 literals, then one 8-byte copy 8 back
    .word 0x00001010
    .byte 0x00, 1, 2, 3, 4, 5, 6, 7, 8
    .byte 0x80, 0x50, 0x07
    .align 2
rl_src:                            @ 16 bytes: one run of 0xAA
    .word 0x00001030
    .byte 0x8D, 0xAA
    .align 2
diff_src:                          @ 16 bytes of deltas
    .word 0x00001081
    .byte 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 121, 98, 219
wave:                              @ a WaveData header: type, key, freq (Hz << 10)
    .word 0
    .word 0x00AC4400
