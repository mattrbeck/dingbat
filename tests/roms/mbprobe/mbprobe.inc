@ mbprobe.inc — equates and macros shared by sender.s and payload_*.s.
@ Include at the TOP of a source; mbcommon.inc (the shared code) goes at the
@ BOTTOM so the image header stays at offset 0.
@
@ Every source defines IS_CHILD (1 = multiboot payload, 0 = sender) before
@ including this file; build.py passes --defsym CARTBOOT=1 for the
@ payload twins linked at 0x08000000.

    .arm
    .text
    .global _start

.equ IOBASE,        0x04000000
.equ VRAM,          0x06000000
.equ RESULT,        0x03000400      @ 256-byte result slot, 4 pages of 64
.equ STATUS,        0x03000500      @ word: 0 = running, 1 = done
.equ CMDBUF,        0x03000600      @ EEPROM command bit stream (halfwords)
.equ RDBUF,         0x03000700      @ EEPROM read bit stream (68 halfwords)
.equ MBPARAM,       0x03000200      @ sender: MultiBootParam (0x4C bytes)

@ send-back protocol over the multiplay link (parent = sender, child = payload)
@   parent sends 0xA0ii  -> child answers (ii << 8) | RESULT[ii]
@   parent sends 0xAF00  -> child answers 0xAF00 | STATUS
@ The child's reply is latched at the START of a transfer, so the parent
@ repeats a request until the reply's top byte echoes the index it asked for.
.equ SIO_REQ_DATA,   0xA000
.equ SIO_REQ_STATUS, 0xAF00

.equ KEY_A,      0x001
.equ KEY_B,      0x002
.equ KEY_SELECT, 0x004
.equ KEY_START,  0x008
.equ KEY_RIGHT,  0x010
.equ KEY_LEFT,   0x020
.equ KEY_UP,     0x040
.equ KEY_DOWN,   0x080
.equ KEY_R,      0x100
.equ KEY_L,      0x200

.equ FG_COLOR,   0x0000             @ black glyphs
.equ BG_COLOR,   0x7FFF             @ on white

@ WAITCNT values (GBATEK): 0x4317 = SRAM 8, WS0 3/1, WS1 4/4, WS2 8/8,
@ prefetch on — the common retail value, and the 8-clock WS2 the EEPROM
@ needs.  Tilt adds PHI 4 MHz (bits 11-12 = 1).  Wario's own is 0x45B7.
.equ WAITCNT_EEPROM, 0x4317
.equ WAITCNT_TILT,   0x4B17
.equ WAITCNT_GYRO,   0x45B7
.equ WAITCNT_ROM,    0x4317

@ 192-byte cart header + the multiboot entries (GBATEK "GBA Cartridge
@ Header", "Additional Multiboot Header Entries").  build.py patches the
@ logo, title, game code and complement; the slave BIOS verifies them and
@ then overwrites 0xC4/0xC5 before jumping to 0xC0.
.macro IMAGE_HEADER entry
_start:
    b   \entry                     @ 0x00 ROM entry (cart boot only)
    .space 0x9C                    @ 0x04 Nintendo logo
    .space 0x20                    @ 0xA0 title / code / 0x96 / complement
    b   \entry                     @ 0xC0 multiboot RAM entry point
mb_boot_mode:
    .byte 0                        @ 0xC4 BIOS: 1 joybus, 2 normal, 3 multiplay
mb_slave_id:
    .byte 0                        @ 0xC5 BIOS: slave number
    .space 0x1A                    @ 0xC6-0xDF unused
    b   \entry                     @ 0xE0 JOYBUS entry point
.endm

@ String literal with a _len equate.
.macro DEFSTR name, text
\name:
    .ascii "\text"
    .equ \name\()_len, . - \name
.endm

@ Draw a DEFSTR at (col,row).
.macro DRAW col, row, name
    mov r0, #\col
    mov r1, #\row
    ldr r2, =\name
    mov r3, #\name\()_len
    bl  draw_str
.endm

@ Status line (row 9, cleared to the right edge).
.macro STATUS_MSG name
    ldr r0, =\name
    mov r1, #\name\()_len
    bl  draw_status
.endm

@ Store a big-endian value into RESULT (values read naturally on screen).
.macro STORE_BE32 base, off, reg
    mov r12, \reg, lsr #24
    strb r12, [\base, #\off]
    mov r12, \reg, lsr #16
    strb r12, [\base, #\off+1]
    mov r12, \reg, lsr #8
    strb r12, [\base, #\off+2]
    strb \reg, [\base, #\off+3]
.endm

.macro STORE_BE16 base, off, reg
    mov r12, \reg, lsr #8
    strb r12, [\base, #\off]
    strb \reg, [\base, #\off+1]
.endm
