@ obusbus.s — does the width of the bus the CODE is fetched over decide how
@ an unmapped read is composed?
@
@ obusprobe.s settled what a Thumb open-bus read returns when the code runs
@ from IWRAM: the two most recent fetches, $+2 and $+4, each land in the half
@ of the 32-bit latch its own address bit 1 selects. Applying that everywhere
@ costs 40 I/O rows and 6 Timing rows of the mGBA suite, whose write-only
@ register reads run from ROM-resident Thumb code; keeping the old duplicate
@ there brings them back. The explanation offered for that was bus width -- a
@ 16-bit bus cannot fill both halves of the latch from one fetch, so the one
@ fetch fills both -- but nothing measured it. It was inferred from the suite
@ agreeing, which is the same as assuming the suite is right.
@
@ So run the IDENTICAL Thumb block from four memories of known width and read
@ 0x10000000 from each:
@
@   IWRAM 0x03000000  32-bit   (the control: obusprobe's answer)
@   EWRAM 0x02000000  16-bit
@   VRAM  0x06000000  16-bit
@   OAM   0x07000000  32-bit
@
@ The block is copied, not reassembled, so the four differ in the memory they
@ execute from and in nothing else. EWRAM and VRAM stand in for the cartridge
@ bus, which is 16 bits wide too and which this rig cannot reach; OAM is the
@ other half of the gate dingbat now ships, and had never been measured.
@
@ If the two 16-bit rows duplicate one halfword and the two 32-bit rows mix
@ two, the gate is hardware-correct. If all four mix, the gate is wrong and
@ those 46 suite rows are failing for some other reason.
@
@ r0 out: 'BUSW'.  Results at 0x02008000, 49 words:
@   +0   IWRAM: (value, load address) x 4
@   +64  EWRAM: the same four
@   +128 VRAM:  the same four
@   +192 OAM:   the same four
@   +256 marker 'BUSW'
    .arm
    .text
    .global _start

.equ UNMAP,    0x10000000          @ past the gamepak: nothing answers here
.equ RESULTS,  0x02008000
.equ EWCODE,   0x0200A000          @ clear of the monitor and of RESULTS
.equ VRCODE,   0x06010000
.equ OAMCODE,  0x07000100
.equ MARKER,   0x42555357          @ 'BUSW'
.equ DISPCNT,  0x04000000

@ Copy the Thumb block to \dest and run it there, answering at RESULTS + \at.
.macro run_from dest, at
    ldr r1, =thumb_part
    ldr r2, =thumb_end
    ldr r3, =\dest
1:  ldr r0, [r1], #4
    str r0, [r3], #4
    cmp r1, r2
    blo 1b
    ldr r10, =RESULTS + \at
    ldr r0, =\dest + 1
    mov lr, pc
    bx  r0
.endm

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r7, =UNMAP

    @ r0 != 0: force blank first. The PPU reads VRAM and OAM itself, so a row
    @ that executes from either is running against the renderer unless the
    @ display is off -- and an anomaly in exactly those two rows would be
    @ indistinguishable from a bus-width effect. Run it both ways.
    ldr r11, =DISPCNT
    ldrh r4, [r11]                 @ keep it, and put it back at the end
    cmp r0, #0
    movne r1, #0x80
    strneh r1, [r11]               @ the condition goes before the size here

    @ IWRAM, in place: the control, and the same code bytes as the copies.
    ldr r10, =RESULTS
    ldr r0, =thumb_part + 1
    mov lr, pc
    bx  r0

    run_from EWCODE,  64
    run_from VRCODE,  128
    run_from OAMCODE, 192

    strh r4, [r11]                 @ the display as it was

    ldr r0, =MARKER
    ldr r1, =RESULTS
    str r0, [r1, #256]
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

@ Four blocks of five halfwords. Five is odd, so consecutive blocks put their
@ load on opposite word alignments with no padding: within each memory the
@ pairs differ in bit 1 of the load's address and in nothing else. Register
@ traffic only, so the block is position independent and can be copied rather
@ than reassembled. r5 shadows r10, because Thumb cannot index off a high
@ register.
.macro tb_trial op, slot
    mov r6, pc                     @ r6 = this instruction + 4
    \op r0, [r7, #0]
    sub r6, #2                     @ ... so the load's own address
    str r0, [r5, #\slot]
    str r6, [r5, #(\slot + 4)]
.endm

    .align 2
    .thumb
thumb_part:
    mov r5, r10
    tb_trial ldr,  0
    tb_trial ldr,  8
    tb_trial ldrh, 16
    tb_trial ldrh, 24
    bx  lr
    .align 2
thumb_end:
