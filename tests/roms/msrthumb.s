@ =============================================================================
@ msrthumb.gba - what does an ARM7TDMI do when MSR writes the CPSR T bit?
@
@ Build: python3 tests/roms/msrthumb_build.py     (see tests/roms/MSRTHUMB.md)
@
@ ARM says "MSR changing T is UNPREDICTABLE", but real GBA software depends on
@ it: Pokemon Pinball: Ruby & Sapphire's decompressor exits ARM state with
@ `msr cpsr_fc, r2` (T set) and relies on an already-prefetched `bx r0` to run
@ afterwards. Emulators model the mid-pipeline switch differently and one
@ (NanoBoyAdvance) does not model it at all. This ROM measures what the silicon
@ actually does, so the model can stop being a guess.
@
@ ---------------------------------------------------------------------------
@ Method
@ ---------------------------------------------------------------------------
@ The probe is an `msr` at address A whose next two words (A+4, A+8) were
@ already inside the pipeline (A+4 decoded as ARM, A+8 fetched as ARM) when T
@ flipped. Those two words are chosen so that EVERY plausible reinterpretation
@ leaves a different, harmless fingerprint:
@
@   W1 (at A+4) = 0x35813404
@       as ARM        : strcc r3, [r1, #0x404]   -> writes 0xA5A5A5A5 @ 0x02000404
@       as THUMB @A+4 : add   r4, #4             -> r4 = 0x04
@       as THUMB @A+6 : add   r5, #0x81          -> r5 = 0x81
@
@   W2 (at A+8) = 0x37813609
@       as ARM        : strcc r3, [r1, r9, lsl #12]  (r9 = 0)
@                                                -> writes 0xA5A5A5A5 @ 0x02000000
@       as THUMB @A+8 : add   r6, #9             -> r6 = 0x09
@       as THUMB @A+10: add   r7, #0x81          -> r7 = 0x81
@
@ The carry flag is cleared before the msr, so the `cc` conditions above are
@ TRUE: an ARM-decoded slot really does store. r4..r7 start at 0. Whatever the
@ hardware does, execution converges two halfwords later on a Thumb `b` at
@ A+12 (whose containing ARM word is `cond=cs`, i.e. a no-op with carry clear,
@ so an emulator that ignores the T write entirely also survives and is
@ reported rather than crashing the test).
@
@ Reading the result (R4 R5 R6 R7 F, F bit0 = ARM store @0x02000404,
@ bit1 = ARM store @0x02000000, bit2 = T write ignored entirely):
@
@   00 00 09 00 0  A+4 slot killed, A+8 low half runs as Thumb, resume at A+12
@                  == the model mGBA and dingbat implement today
@   00 00 09 81 0  A+4 slot killed, A+8 AND A+10 run as Thumb (no A+10 skip)
@   00 00 09 81 1  A+4 completes as ARM (pipeline not flushed), then A+8, A+10
@   00 00 09 00 1  A+4 completes as ARM, A+8 as Thumb, A+10 skipped
@   04 81 09 81 0  all four halfwords re-decoded as Thumb
@   00 00 00 00 0  pipeline fully flushed, refetched at A+12
@   ** ** ** ** 4  the T write did not take effect at all
@
@ Probe 6/7 is the literal Pokemon Pinball shape (`msr` + 0x00000000 +
@ 0xE0A04700, whose low half is `bx r0`); it prints OK when the guest's own
@ branch is honoured.
@
@ Each probe is run from ROM, IWRAM and EWRAM: the fetch that landed in the
@ pipeline is 16-bit on the cart bus and 32-bit in IWRAM, which is exactly the
@ kind of thing that could change the answer.
@ =============================================================================

    .arm
    .section .text
    .global _start

_start:
    b       entry
    .space  0xBC            @ cartridge header, filled in by msrthumb_build.py

@ --- fixed addresses -------------------------------------------------------
    .equ WITNESS_W2,  0x02000000    @ ARM-decode witness for W2
    .equ WITNESS_W1,  0x02000404    @ ARM-decode witness for W1
    .equ VAR_IDX,     0x02000800
    .equ RESULTS,     0x02001000    @ 8 records x 32 bytes
    .equ EWRAM_BLOB,  0x02008000
    .equ IWRAM_BLOB,  0x03000000
    .equ NUM_PROBES,  8
    .equ MAGIC,       0xA5A5A5A5

entry:
    mov     r0, #0x04000000
    mov     r1, #0
    str     r1, [r0, #0x208]        @ IME = 0: no interrupts during the probes
    ldr     sp, =0x03007F00

    ldr     r1, =0x0403
    strh    r1, [r0, #0]            @ DISPCNT = mode 3, BG2 on

    bl      clear_screen
    bl      run_all
    bl      draw_report
    ldr     r0, =str_done
    mov     r1, #0
    mov     r2, #ROW_Y+NUM_PROBES*ROW_DY+28
    ldr     r3, =0x03E0
    bl      puts

hang:
    b       hang

@ =============================================================================
@ Probe runner
@ =============================================================================
run_all:
    stmfd   sp!, {r4-r11, lr}

    @ Mark every record "not run" (flags bit 8). A probe that wedges the CPU on
    @ some behaviour this test did not anticipate then leaves the rows before it
    @ on screen and its own row as "--", which says exactly where it died.
    ldr     r1, =RESULTS
    mov     r0, #NUM_PROBES
    mov     r2, #0x100
mark_unrun:
    str     r2, [r1, #24]
    add     r1, r1, #32
    subs    r0, r0, #1
    bne     mark_unrun

    mov     r0, #0
    ldr     r1, =VAR_IDX
    str     r0, [r1]

probe_loop:
    ldr     r1, =VAR_IDX
    ldr     r0, [r1]
    cmp     r0, #NUM_PROBES
    bge     probes_done

    bl      draw_report             @ repaint before each probe, so a hang shows
    ldr     r1, =VAR_IDX            @ which probe was in flight
    ldr     r0, [r1]

    ldr     r1, =probe_table
    add     r1, r1, r0, lsl #2      @ entry stride is 20 bytes
    add     r1, r1, r0, lsl #4
    ldr     r6, [r1, #0]            @ where to run it from
    ldr     r12, [r1, #4]           @ CPSR and-mask
    ldr     r8, [r1, #8]            @ CPSR or-mask
    ldr     r2, [r1, #12]           @ blob start
    ldr     r3, [r1, #16]           @ blob end

    cmp     r6, r2                  @ copy the blob unless it runs in place
    beq     blob_ready
    mov     r4, r2
    mov     r5, r6
copy_blob:
    ldr     r7, [r4], #4
    str     r7, [r5], #4
    cmp     r4, r3
    blo     copy_blob
blob_ready:

    mov     r7, #0                  @ clear the ARM-decode witnesses
    ldr     r1, =WITNESS_W1
    str     r7, [r1]
    ldr     r1, =WITNESS_W2
    str     r7, [r1]

    ldr     r11, =RESULTS           @ zero this probe's record
    add     r11, r11, r0, lsl #5
    str     r7, [r11, #0]
    str     r7, [r11, #4]
    str     r7, [r11, #8]
    str     r7, [r11, #12]
    str     r7, [r11, #16]
    str     r7, [r11, #20]
    str     r7, [r11, #24]
    str     r7, [r11, #28]

    ldr     r1, =0x04000100         @ free-running cycle counter, prescaler 1
    strh    r7, [r1, #2]
    strh    r7, [r1, #0]
    mov     r2, #0x80
    strh    r2, [r1, #2]

    ldr     r1, =WITNESS_W2         @ r1 = probe store base
    ldr     r3, =MAGIC              @ r3 = value an ARM-decoded slot stores
    ldr     r10, =probe_ret
    mov     pc, r6

probe_ret:
    msr     cpsr_c, #0xDF           @ back to SYS regardless of what the probe left

    ldr     r1, =0x04000100
    ldrh    r2, [r1, #0]            @ cycles
    mov     r3, #0
    strh    r3, [r1, #2]

    ldr     r1, =VAR_IDX
    ldr     r0, [r1]
    ldr     r11, =RESULTS
    add     r11, r11, r0, lsl #5
    str     r2, [r11, #28]

    ldr     r3, =MAGIC
    mov     r4, #0
    ldr     r1, =WITNESS_W1
    ldr     r5, [r1]
    str     r5, [r11, #16]
    cmp     r5, r3
    orreq   r4, r4, #1              @ W1 completed as an ARM instruction
    ldr     r1, =WITNESS_W2
    ldr     r5, [r1]
    str     r5, [r11, #20]
    cmp     r5, r3
    orreq   r4, r4, #2              @ W2 completed as an ARM instruction

    ldr     r5, [r11, #24]          @ tag left by the blob
    cmp     r5, #0xFA
    orreq   r4, r4, #4              @ T write never took effect
    cmp     r5, #0x0B
    orreq   r4, r4, #8              @ pinball probe: guest's bx r0 was honoured
    cmp     r5, #0xFB
    orreq   r4, r4, #0x10           @ pinball probe: fell through without the bx
    str     r4, [r11, #24]

    ldr     r1, =VAR_IDX            @ next probe
    ldr     r0, [r1]
    add     r0, r0, #1
    str     r0, [r1]
    b       probe_loop

probes_done:
    ldmfd   sp!, {r4-r11, pc}

    .ltorg

@ =============================================================================
@ The probe blob.
@
@ Entry (ARM): r1 = store base, r3 = 0xA5A5A5A5, r8 = CPSR or-mask,
@              r10 = return address, r11 = result record, r12 = CPSR and-mask.
@ Position independent: it is copied verbatim into IWRAM and EWRAM.
@ =============================================================================
    .align  2
probe_blob:
    mov     r4, #0
    mov     r5, #0
    mov     r6, #0
    mov     r7, #0
    mov     r9, #0                  @ index register for W2-as-ARM: offset 0
    mrs     r2, cpsr
    and     r2, r2, r12
    orr     r2, r2, r8
    mov     r0, #0
    subs    r0, r0, #1              @ borrow => carry clear => `cc` slots fire

probe_msr:
    msr     cpsr_c, r2              @ <- A
    .word   0x35813404              @ <- A+4  (W1, already decoded as ARM)
    .word   0x37813609              @ <- A+8  (W2, already fetched as ARM)
    .thumb
    b       probe_conv              @ <- A+12 (Thumb) / low half of a `cs` no-op
    .hword  0x2000                  @ <- A+14 (Thumb `mov r0,#0`), never reached
    .arm

    @ Only reached if the CPU is still in ARM state, i.e. the T write was
    @ dropped: A+12 decoded as ARM is 0x2000E0xx, cond = cs, and carry is clear.
    mov     r0, #0xFA
    str     r0, [r11, #24]
    str     r4, [r11, #0]
    str     r5, [r11, #4]
    str     r6, [r11, #8]
    str     r7, [r11, #12]
    bx      r10

    .thumb
    .thumb_func
probe_conv:
    mov     r0, r11
    str     r4, [r0, #0]
    str     r5, [r0, #4]
    str     r6, [r0, #8]
    str     r7, [r0, #12]
    bx      r10                     @ r10 is even: back to ARM state
    .arm
    .align  2
probe_blob_end:

@ =============================================================================
@ Pokemon Pinball: Ruby & Sapphire's actual exit shape, byte for byte.
@ =============================================================================
    .align  2
pin_blob:
    ldr     r0, pin_lit             @ where the game would have jumped
    mov     r4, #0
    mov     r5, #0
    mov     r6, #0
    mov     r7, #0
    mrs     r2, cpsr
    and     r2, r2, r12
    orr     r2, r2, r8
    mov     r9, #0
    mov     r0, r0                  @ (keep r0 live across the switch)

pin_msr:
    msr     cpsr_c, r2              @ <- A
    .word   0x00000000              @ <- A+4  harmless in every decoding
    .word   0xE0A04700              @ <- A+8  low half = Thumb `bx r0`
    .thumb
    b       pin_notaken             @ <- A+12
    .hword  0x2000
    .arm

    mov     r0, #0xFA               @ T write dropped: still in ARM state
    str     r0, [r11, #24]
    bx      r10

    .thumb
    .thumb_func
pin_notaken:
    mov     r0, r11                 @ Thumb, but the guest's bx never happened
    mov     r1, #0xFB
    str     r1, [r0, #24]
    bx      r10
    .arm
    .align  2
pin_lit:
    .word   pin_land
pin_land:
    mov     r0, #0x0B               @ reached through the guest's own bx r0
    str     r0, [r11, #24]
    bx      r10
pin_blob_end:

@ =============================================================================
@ Probe table: dest, cpsr and-mask, cpsr or-mask, blob start, blob end
@ =============================================================================
    .align  2
probe_table:
    .word   probe_blob,  0xFFFFFFFF, 0x00000020, probe_blob, probe_blob_end
    .word   IWRAM_BLOB,  0xFFFFFFFF, 0x00000020, probe_blob, probe_blob_end
    .word   EWRAM_BLOB,  0xFFFFFFFF, 0x00000020, probe_blob, probe_blob_end
    .word   probe_blob,  0xFFFFFFE0, 0x00000032, probe_blob, probe_blob_end
    .word   IWRAM_BLOB,  0xFFFFFFE0, 0x00000032, probe_blob, probe_blob_end
    .word   EWRAM_BLOB,  0xFFFFFFE0, 0x00000032, probe_blob, probe_blob_end
    .word   pin_blob,    0xFFFFFFE0, 0x0000003F, pin_blob,   pin_blob_end
    .word   IWRAM_BLOB,  0xFFFFFFE0, 0x0000003F, pin_blob,   pin_blob_end

@ =============================================================================
@ Report
@ =============================================================================
    .equ COL_MEM,   3
    .equ COL_MSK,   7
    .equ COL_R4,   10
    .equ COL_R5,   13
    .equ COL_R6,   16
    .equ COL_R7,   19
    .equ COL_F,    22
    .equ COL_CYC,  24
    .equ ROW_Y,    40
    .equ ROW_DY,   10

draw_report:
    stmfd   sp!, {r4-r11, lr}

    ldr     r0, =str_title
    mov     r1, #8
    mov     r2, #4
    ldr     r3, =0x7FFF
    bl      puts

    ldr     r0, =str_head
    mov     r1, #0
    mov     r2, #ROW_Y-14
    ldr     r3, =0x03FF
    bl      puts

    mov     r9, #0                  @ probe index
report_row:
    mov     r2, #ROW_Y
    mov     r0, #ROW_DY
    mla     r2, r9, r0, r2          @ y = ROW_Y + idx*ROW_DY
    mov     r10, r2

    ldr     r11, =RESULTS           @ record
    add     r11, r11, r9, lsl #5

    ldr     r3, =0x7FFF
    mov     r0, #'P'
    mov     r1, #0
    mov     r2, r10
    bl      putc
    add     r0, r9, #'0'
    mov     r1, #8
    mov     r2, r10
    bl      putc

    ldr     r0, =mem_names          @ 4-byte zero-terminated names
    add     r0, r0, r9, lsl #2
    mov     r1, #COL_MEM*8
    mov     r2, r10
    ldr     r3, =0x7FE0
    bl      puts

    ldr     r0, =probe_table        @ or-mask, low byte
    add     r0, r0, r9, lsl #2
    add     r0, r0, r9, lsl #4
    ldr     r0, [r0, #8]
    mov     r1, #COL_MSK*8
    mov     r2, r10
    ldr     r3, =0x7FE0
    bl      put_hex8

    ldr     r4, [r11, #24]          @ flags
    tst     r4, #0x100              @ never ran (or wedged the CPU)
    bne     row_unrun
    tst     r4, #8                  @ pinball success
    bne     row_pin_ok
    tst     r4, #0x10               @ pinball fell through
    bne     row_pin_no

    ldr     r3, =0x7FFF
    ldr     r0, [r11, #0]
    mov     r1, #COL_R4*8
    mov     r2, r10
    bl      put_hex8
    ldr     r0, [r11, #4]
    mov     r1, #COL_R5*8
    mov     r2, r10
    bl      put_hex8
    ldr     r0, [r11, #8]
    mov     r1, #COL_R6*8
    mov     r2, r10
    bl      put_hex8
    ldr     r0, [r11, #12]
    mov     r1, #COL_R7*8
    mov     r2, r10
    bl      put_hex8
    b       row_flags

row_unrun:
    ldr     r0, =str_unrun
    mov     r1, #COL_R4*8
    mov     r2, r10
    ldr     r3, =0x4210
    bl      puts
    b       row_next

row_pin_ok:
    ldr     r0, =str_ok
    mov     r1, #COL_R4*8
    mov     r2, r10
    ldr     r3, =0x03E0
    bl      puts
    b       row_flags
row_pin_no:
    ldr     r0, =str_no
    mov     r1, #COL_R4*8
    mov     r2, r10
    ldr     r3, =0x001F
    bl      puts

row_flags:
    ldr     r0, [r11, #24]
    and     r0, r0, #7
    add     r0, r0, #'0'
    mov     r1, #COL_F*8
    mov     r2, r10
    ldr     r3, =0x7FFF
    bl      putc

    ldr     r0, [r11, #28]
    mov     r1, #COL_CYC*8
    mov     r2, r10
    ldr     r3, =0x7BDE
    bl      put_hex16

row_next:
    add     r9, r9, #1
    cmp     r9, #NUM_PROBES
    blo     report_row

    ldr     r0, =str_w1
    mov     r1, #0
    mov     r2, #ROW_Y+NUM_PROBES*ROW_DY+8
    ldr     r3, =0x4210
    bl      puts
    ldr     r0, =str_w2
    mov     r1, #0
    mov     r2, #ROW_Y+NUM_PROBES*ROW_DY+18
    ldr     r3, =0x4210
    bl      puts

    ldmfd   sp!, {r4-r11, pc}

    .ltorg

@ =============================================================================
@ Text primitives (mode 3)
@ =============================================================================
@ r0 = char, r1 = x, r2 = y, r3 = colour
putc:
    stmfd   sp!, {r0-r10, lr}
    sub     r0, r0, #0x20
    cmp     r0, #(0x5A - 0x20)
    movhi   r0, #0
    ldr     r4, =font_data
    add     r4, r4, r0, lsl #3
    ldr     r5, =0x06000000
    mov     r6, #240
    mul     r7, r2, r6
    add     r7, r7, r1
    add     r5, r5, r7, lsl #1
    mov     r8, #0
putc_row:
    ldrb    r9, [r4, r8]
    mov     r10, r5
    mov     r0, #0
putc_col:
    mov     r1, #0                  @ opaque: cells are cleared as well as drawn,
    tst     r9, #0x80               @ so repainting a row erases what was there
    movne   r1, r3
    strh    r1, [r10]
    add     r10, r10, #2
    mov     r9, r9, lsl #1
    add     r0, r0, #1
    cmp     r0, #8
    blo     putc_col
    add     r5, r5, #480
    add     r8, r8, #1
    cmp     r8, #8
    blo     putc_row
    ldmfd   sp!, {r0-r10, pc}

@ r0 = string, r1 = x, r2 = y, r3 = colour
puts:
    stmfd   sp!, {r4-r7, lr}
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    mov     r7, r3
puts_next:
    ldrb    r0, [r4], #1
    cmp     r0, #0
    beq     puts_done
    mov     r1, r5
    mov     r2, r6
    mov     r3, r7
    bl      putc
    add     r5, r5, #8
    cmp     r5, #240
    blo     puts_next
puts_done:
    ldmfd   sp!, {r4-r7, pc}

@ r0 = value (low byte), r1 = x, r2 = y, r3 = colour
put_hex8:
    stmfd   sp!, {r4-r7, lr}
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    mov     r7, r3
    mov     r0, r4, lsr #4
    and     r0, r0, #0xF
    bl      hex_digit
    mov     r1, r5
    mov     r2, r6
    mov     r3, r7
    bl      putc
    and     r0, r4, #0xF
    bl      hex_digit
    add     r1, r5, #8
    mov     r2, r6
    mov     r3, r7
    bl      putc
    ldmfd   sp!, {r4-r7, pc}

@ r0 = value (low halfword), r1 = x, r2 = y, r3 = colour
put_hex16:
    stmfd   sp!, {r4-r7, lr}
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    mov     r7, r3
    mov     r0, r4, lsr #8
    mov     r1, r5
    mov     r2, r6
    mov     r3, r7
    bl      put_hex8
    mov     r0, r4
    add     r1, r5, #16
    mov     r2, r6
    mov     r3, r7
    bl      put_hex8
    ldmfd   sp!, {r4-r7, pc}

@ r0 = nibble -> ascii
hex_digit:
    and     r0, r0, #0xF
    cmp     r0, #10
    addlo   r0, r0, #'0'
    addhs   r0, r0, #('A' - 10)
    bx      lr

clear_screen:
    ldr     r0, =0x06000000
    ldr     r1, =0x0000
    ldr     r2, =(240*160/2)
clear_loop:
    str     r1, [r0], #4
    subs    r2, r2, #1
    bne     clear_loop
    bx      lr

    .ltorg

@ =============================================================================
@ Data
@ =============================================================================
    .align  2
str_title:
    .asciz  "MSR T-BIT PIPELINE PROBE"
str_head:
    .asciz  "P- MEM MSK R4 R5 R6 R7 F CYCL"
str_unrun:
    .asciz  "-- -- -- -- - ----"   @ padded: blanks the whole row
str_done:
    .asciz  "ALL PROBES COMPLETED"
str_ok:
    .asciz  "BX OK       "         @ padded: blanks the stale R6/R7 cells
str_no:
    .asciz  "BX NO       "
str_w1:
    .asciz  "W1 35813404 A+4 A+6"
str_w2:
    .asciz  "W2 37813609 A+8 A+10"

    .align  2
mem_names:
    .asciz  "ROM"
    .asciz  "IWR"
    .asciz  "EWR"
    .asciz  "ROM"
    .asciz  "IWR"
    .asciz  "EWR"
    .asciz  "PIN"
    .asciz  "PIW"

    .align  2
    .include "msrthumb_font.inc"

    .end
