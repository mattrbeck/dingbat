@ dingbat's synthesized DS BIOS: the guest-visible half of the HLE BIOS
@ (hle_bios.nim is the other half). Assembled once per CPU:
@
@   ARM9 (--defsym ARM9=1, -march=armv5te): 4 KB image at 0xFFFF0000
@   ARM7 (--defsym ARM9=0, -march=armv4t):  16 KB image at 0x00000000
@
@ tools/nds_hle_bios.sh assembles both and regenerates hle_bios_image.nim;
@ the emulator only ever sees those embedded bytes.
@
@ Written from GBATEK ("BIOS Functions", "DS Interrupts", "BIOS RAM Usage"),
@ not from any BIOS dump. What lives here is what must run as guest code:
@ the exception vectors, the IRQ dispatcher, and the SWIs that block or
@ call back into the game (IntrWait, VBlankIntrWait, WaitByLoop and the
@ three ReadByCallback decompressors). Every other SWI is answered in Nim by
@ the CPU's swi_hook before the SWI vector is taken.

        .syntax unified
        .arm
        .text

        .if ARM9
        .equ DEBUG_VECTOR, 0x027FFD9C     @ debug handler; its stack below
        .else
        .equ DEBUG_VECTOR, 0x0380FFDC
        .equ IRQ_CHECK, 0x0380FFF8        @ IntrWait's IRQ check bits
        .endif

@ ---------------------------------------------------------------------------
@ Exception vectors

        .global _start
_start:
        b       exception           @ 0x00 reset (only by a stray jump)
        b       exception           @ 0x04 undefined instruction
        b       swi_entry           @ 0x08 SWI
        b       exception           @ 0x0C prefetch abort / BKPT
        b       exception           @ 0x10 data abort
        b       exception           @ 0x14 reserved
        b       irq_entry           @ 0x18 IRQ
        b       exception           @ 0x1C FIQ

@ ---------------------------------------------------------------------------
@ IRQ: save the caller-saved registers on the IRQ stack, call the user
@ handler with lr pointing back here, return to the interrupted code.
@ ARM9: handler pointer at DTCM+0x3FFC (ARM or Thumb, ldr pc interworks).
@ ARM7: handler pointer at 0x0380FFFC, read through the 0x03FFFFFC mirror.

irq_entry:
        stmfd   sp!, {r0-r3, r12, lr}
        .if ARM9
        mrc     p15, 0, r0, c9, c1, 0   @ DTCM region register
        mov     r0, r0, lsr #12
        mov     r0, r0, lsl #12
        add     r0, r0, #0x4000         @ DTCM end
        .else
        mov     r0, #0x04000000
        .endif
        add     lr, pc, #0              @ return to the ldmfd
        ldr     pc, [r0, #-4]
        ldmfd   sp!, {r0-r3, r12, lr}
        subs    pc, lr, #4

@ ---------------------------------------------------------------------------
@ Undefined instruction, aborts, FIQ, reset: GBATEK's debug handler
@ contract. The vector word doubles as the top of a debug stack; the
@ handler finds spsr, r12 and lr (the faulting return address) below it.
@ With no handler installed the CPU parks here.

exception:
        .if ARM9
        mrc     p15, 0, sp, c1, c0, 0   @ protection unit off, so the debug
        bic     sp, sp, #1              @ stack is reachable whatever the
        mcr     p15, 0, sp, c1, c0, 0   @ game's regions say
        .endif
        ldr     sp, =DEBUG_VECTOR
        stmfd   sp!, {r12, lr}
        mrs     r12, spsr
        stmfd   sp!, {r12}
        ldr     r12, =DEBUG_VECTOR
        ldr     r12, [r12]
        cmp     r12, #0
        movne   lr, pc
        bxne    r12
park:
        b       park

@ ---------------------------------------------------------------------------
@ SWI dispatcher, reached only for the SWIs the Nim hook routes here.
@ GBATEK "How BIOS Processes SWIs": spsr, r11, r12 and lr go on the SVC
@ stack, the routine runs in System mode with the caller's IRQ-disable
@ bit (so IRQs are taken inside IntrWait and the callbacks), r2 and
@ r4-r14 come back unchanged.

swi_entry:
        stmfd   sp!, {r11, r12, lr}
        mrs     r11, spsr
        stmfd   sp!, {r11}
        ldrb    r12, [lr, #-2]          @ comment byte, ARM and Thumb alike
        and     r12, r12, #0x1F
        adr     r11, swi_table
        ldr     r12, [r11, r12, lsl #2]
        mrs     r11, spsr
        and     r11, r11, #0x80
        orr     r11, r11, #0x1F         @ System mode, ARM, caller's I bit
        msr     cpsr_c, r11
        stmfd   sp!, {r2, lr}
        mov     lr, pc
        bx      r12
        ldmfd   sp!, {r2, lr}
        mov     r12, #0xD3              @ back to SVC, IRQs off
        msr     cpsr_c, r12
        ldmfd   sp!, {r11}
        msr     spsr_fsxc, r11
        ldmfd   sp!, {r11, r12, lr}
        movs    pc, lr

swi_table:
        .word   swi_none                @ 00 SoftReset (Nim)
        .word   swi_none                @ 01
        .word   swi_none                @ 02
        .word   wait_by_loop            @ 03 WaitByLoop
        .word   intr_wait               @ 04 IntrWait
        .word   vblank_intr_wait        @ 05 VBlankIntrWait
        .word   swi_none, swi_none      @ 06-07
        .word   swi_none, swi_none      @ 08-09
        .word   swi_none, swi_none      @ 0A-0B
        .word   swi_none, swi_none      @ 0C-0D
        .word   swi_none, swi_none      @ 0E-0F
        .word   swi_none, swi_none      @ 10-11
        .word   lz77_callback           @ 12 LZ77UnCompReadByCallbackWrite16bit
        .word   huff_callback           @ 13 HuffUnCompReadByCallback
        .word   swi_none                @ 14
        .word   rl_callback             @ 15 RLUnCompReadByCallbackWrite16bit
        .word   swi_none, swi_none      @ 16-17
        .word   swi_none, swi_none      @ 18-19
        .word   swi_none, swi_none      @ 1A-1B
        .word   swi_none, swi_none      @ 1C-1D
        .word   swi_none, swi_none      @ 1E-1F

swi_none:
        bx      lr

@ ---------------------------------------------------------------------------
@ WaitByLoop(r0): GBATEK's "SUB R0,1 / BGT" loop, run from the BIOS.

wait_by_loop:
        subs    r0, r0, #1
        bgt     wait_by_loop
        bx      lr

@ ---------------------------------------------------------------------------
@ IntrWait(r0 = discard old flags, r1 = flags to wait for), forcing IME=1.
@ The user IRQ handler ORs the IRQs it served into the check word; a check
@ takes the wanted bits out of it (IME off around the read-modify-write)
@ and the wait ends once a check found any. Between checks the CPU halts
@ and the IRQ is taken.
@
@ ARM7: discard (r0 != 0) clears the wanted bits, then check, halt, check,
@ ... so with r0 = 0 a flag already set returns at once.
@ ARM9 (GBATEK: "No Discard (r0=0) doesn't work"), as measured against the
@ console's BIOS: with r0 != 0 it is discard, halt, check, halt, check...;
@ with r0 = 0 it checks first, halts, and returns after that one IRQ if
@ the first check found a flag (leaving whatever the IRQ set), otherwise
@ checks once without stopping, then halt, check... as above.

vblank_intr_wait:
        mov     r0, #1
        mov     r1, #1
intr_wait:
        stmfd   sp!, {r4, lr}
        mov     r12, #0x04000000
        .if ARM9
        mrc     p15, 0, r4, c9, c1, 0
        mov     r4, r4, lsr #12
        mov     r4, r4, lsl #12
        add     r4, r4, #0x3F00
        add     r4, r4, #0xF8           @ DTCM+0x3FF8
        .else
        ldr     r4, =IRQ_CHECK
        .endif
        mov     r3, #1
        str     r3, [r12, #0x208]       @ IME = 1
        cmp     r0, #0
        .if ARM9
        bne     intr_wait_discard
        bl      intr_check
        bl      intr_halt
        cmp     r0, #0
        bne     intr_wait_done
        bl      intr_check
        b       intr_wait_halt
intr_wait_discard:
        .else
        beq     intr_wait_check
        .endif
        mov     r3, #0
        str     r3, [r12, #0x208]
        ldr     r3, [r4]
        bic     r3, r3, r1              @ discard the old flags
        str     r3, [r4]
        mov     r3, #1
        str     r3, [r12, #0x208]
        .if ARM9
intr_wait_halt:
        bl      intr_halt
intr_wait_check:
        bl      intr_check
        beq     intr_wait_halt
        .else
intr_wait_check:
        bl      intr_check
        bne     intr_wait_done
        bl      intr_halt
        b       intr_wait_check
        .endif
intr_wait_done:
        ldmfd   sp!, {r4, lr}
        bx      lr

@ r0 = the wanted flags (r1) found in the check word at r4, now taken out
@ of it; Z set when none. r12 = 0x04000000.
intr_check:
        mov     r3, #0
        str     r3, [r12, #0x208]       @ IME = 0
        ldr     r3, [r4]
        ands    r0, r3, r1
        bicne   r3, r3, r0
        strne   r3, [r4]
        mov     r3, #1
        str     r3, [r12, #0x208]       @ IME = 1
        cmp     r0, #0
        bx      lr

intr_halt:
        .if ARM9
        mov     r3, #0
        mcr     p15, 0, r3, c7, c0, 4   @ wait for interrupt
        .else
        mov     r3, #0x80
        strb    r3, [r12, #0x301]       @ HALTCNT: halt
        .endif
        bx      lr

@ ---------------------------------------------------------------------------
@ ReadByCallback decompressors (GBATEK "NDS/DSi Decompression Callbacks").
@ r0 = source, r1 = destination, r2 = parameter for open (Huffman: a 0x200-
@ byte temp buffer), r3 = {open, close, get8, get16, get32}. The callbacks
@ may be ARM or Thumb. Returns the decompressed length, or the negative
@ code from open/close.
@
@ Shared register use: r4 source, r5 destination, r6 bytes still to
@ produce, r7 callback table, r9 output halfword being built; [sp] holds
@ the header word.

        .macro  callback offset
        ldr     r12, [r7, #\offset]
        mov     lr, pc
        bx      r12
        .endm

@ Open the stream: header in r0 and [sp], r6 = length. Called with the
@ routine's frame pushed; returns to the caller's caller on an error.
cb_open:
        mov     r4, r0
        mov     r5, r1
        mov     r7, r3
        mov     r8, lr
        callback 0
        mov     lr, r8
        cmp     r0, #0
        ldrlt   r1, [r7, #4]
        blt     cb_out                  @ rejected: return the code
        add     r4, r4, #4
        str     r0, [sp, #-8]!
        mov     r6, r0, lsr #8
        mov     r9, #0
        bx      lr

@ r0 = next source byte through get8
cb_get8:
        stmfd   sp!, {r1, lr}
        mov     r0, r4
        callback 8
        add     r4, r4, #1
        and     r0, r0, #0xFF
        ldmfd   sp!, {r1, lr}
        bx      lr

@ Output byte r0 through 16-bit writes: even bytes wait in r9, odd ones
@ complete the halfword. Uses r12 only.
cb_put8:
        tst     r5, #1
        moveq   r9, r0
        orrne   r9, r9, r0, lsl #8
        bicne   r12, r5, #1
        strhne  r9, [r12]
        add     r5, r5, #1
        sub     r6, r6, #1
        bx      lr

@ Done: close (if any), return the length or close's error. Like the
@ console's, r1 comes back holding the close pointer.
cb_finish:
        ldr     r1, [r7, #4]
        cmp     r1, #0
        beq     1f
        mov     r0, r4
        mov     lr, pc
        bx      r1
        ldr     r1, [r7, #4]
        cmp     r0, #0
        blt     2f
1:
        ldr     r0, [sp]
        mov     r0, r0, lsr #8
2:
        add     sp, sp, #8
cb_out:
        ldmfd   sp!, {r3-r11, lr}
        bx      lr

@ As in the ReadNormal forms, a token is always finished: the length is
@ only checked between tokens, so a back-reference or run may overrun it.

@ LZ77UnCompReadByCallbackWrite16bit. r8 = flag bits (current in bit 31),
@ r10 = blocks left under this flag byte, r11 = token byte 1.
lz77_callback:
        stmfd   sp!, {r3-r11, lr}
        bl      cb_open
lz77_flags:
        cmp     r6, #0
        ble     cb_finish
        bl      cb_get8
        mov     r8, r0, lsl #24
        mov     r10, #8
lz77_block:
        movs    r8, r8, lsl #1
        bcs     lz77_ref
        bl      cb_get8                 @ literal
        bl      cb_put8
        b       lz77_next
lz77_ref:
        bl      cb_get8
        mov     r11, r0
        bl      cb_get8
        orr     r2, r0, r11, lsl #8
        mov     r2, r2, lsl #20
        mov     r2, r2, lsr #20
        add     r2, r2, #1              @ distance back
        mov     r3, r11, lsr #4
        add     r3, r3, #3              @ length
lz77_copy:
        sub     r0, r5, r2              @ earlier output byte, read back
        bic     r1, r0, #1              @ as a halfword (VRAM-safe)
        ldrh    r1, [r1]
        tst     r0, #1
        movne   r1, r1, lsr #8
        and     r0, r1, #0xFF
        bl      cb_put8
        subs    r3, r3, #1
        bgt     lz77_copy
lz77_next:
        cmp     r6, #0
        ble     cb_finish
        subs    r10, r10, #1
        bgt     lz77_block
        b       lz77_flags

@ RLUnCompReadByCallbackWrite16bit. r8 = bytes left in this run,
@ r10 = the repeated byte.
rl_callback:
        stmfd   sp!, {r3-r11, lr}
        bl      cb_open
rl_flag:
        cmp     r6, #0
        ble     cb_finish
        bl      cb_get8
        and     r8, r0, #0x7F
        tst     r0, #0x80
        bne     rl_run
        add     r8, r8, #1              @ literal bytes
rl_literal:
        bl      cb_get8
        bl      cb_put8
        subs    r8, r8, #1
        bgt     rl_literal
        b       rl_flag
rl_run:
        add     r8, r8, #3              @ repeated bytes
        bl      cb_get8
        mov     r10, r0
rl_repeat:
        mov     r0, r10
        bl      cb_put8
        subs    r8, r8, #1
        bgt     rl_repeat
        b       rl_flag

@ HuffUnCompReadByCallback. The tree (size byte + table) is copied to the
@ temp buffer so it can be walked; the bitstream comes in words through
@ get32, bit 31 first. r8 = current node, r9 = output word being built,
@ r10 = bits in it, r11 = temp buffer, r2 = bits left in r3's word.
huff_callback:
        stmfd   sp!, {r3-r11, lr}
        mov     r11, r2
        bl      cb_open
        bl      cb_get8                 @ tree size / 2 - 1
        strb    r0, [r11]
        add     r8, r0, #1
        mov     r8, r8, lsl #1
        sub     r8, r8, #1              @ table bytes after the size byte
        add     r10, r11, #1
huff_tree:
        bl      cb_get8
        strb    r0, [r10], #1
        subs    r8, r8, #1
        bgt     huff_tree
        add     r8, r11, #1             @ root node
        mov     r10, #0
huff_word:
        cmp     r6, #0
        ble     cb_finish
        mov     r0, r4
        callback 16
        add     r4, r4, #4
        mov     r3, r0
        mov     r2, #32
huff_bit:
        ldrb    r0, [r8]
        and     r1, r0, #0x3F
        bic     r12, r8, #1
        add     r12, r12, r1, lsl #1
        add     r12, r12, #2            @ node 0; node 1 follows it
        movs    r3, r3, lsl #1
        addcs   r12, r12, #1
        movcc   r1, #0x80               @ node 0 end flag
        movcs   r1, #0x40               @ node 1 end flag
        tst     r0, r1
        moveq   r8, r12
        beq     huff_next
        ldrb    r0, [r12]               @ data node
        ldr     r1, [sp]
        and     r1, r1, #0xF            @ data size in bits
        orr     r9, r9, r0, lsl r10
        add     r10, r10, r1
        add     r8, r11, #1
        cmp     r10, #32
        blo     huff_next
        str     r9, [r5], #4
        mov     r9, #0
        mov     r10, #0
        subs    r6, r6, #4
        ble     cb_finish
huff_next:
        subs    r2, r2, #1
        bgt     huff_bit
        b       huff_word

        .ltorg
