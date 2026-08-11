@ defs.inc — shared constants + watchdog macros for the hwverified ROMs.
@ Included at the TOP of each ROM source (gas macros must be defined
@ before use); the code half of the runtime lives in runtime.inc,
@ included at the END of each source.  Memory map: results in the
@ 32-byte SLOT at 0x02000000, IRQ scratch + renderer state above it,
@ copied-code blocks in IWRAM.  The wdg_arm/wdg_disarm macros arm a
@ TM3-overflow IRQ watchdog for probe rows that provoke UNPREDICTABLE
@ behavior: if the core wedges with IRQs unmasked, the shared handler
@ in runtime.inc diverts the IRQ return to the given recovery label.

.equ IOBASE,   0x04000000
.equ SLOT,     0x02000000
.equ SLOTSZ,   32
.equ SCRATCH,  0x02001000          @ IRQ scratch (+0x48 stamp, +0x4C flag,
                                   @ +0x50 interrupted return address)
.equ MARKER,   0x02002000          @ watchdog bookkeeping
.equ EWDST,    0x02004000          @ DMA / store destination area
.equ IWBLOCK,  0x03000200          @ copied-code block (IWRAM)
.equ VRAM,     0x06000000
.equ COLORS,   0x02001100          @ +0 ink hword, +2 paper hword
.equ FLAGS,    0x02001140          @ per-cell mismatch flags (32 bytes)

@ watchdog arm/disarm for UNPREDICTABLE probe rows: TM3 overflow IRQ in
@ 65536 cycles, diverted by irq_handler (runtime.inc) to \rec.
.macro wdg_arm rec
    ldr r2, =MARKER
    ldr r0, =\rec
    str r0, [r2, #20]
    mov r0, #1
    str r0, [r2, #8]
    ldr r2, =0x0400010C            @ TM3
    mov r0, #0
    str r0, [r2]
    ldr r0, =0x00C00000            @ enable + IRQ, reload 0
    str r0, [r2]
    ldr r2, =0x04000200
    mov r0, #0x40
    strh r0, [r2]                  @ IE = timer 3
    ldr r2, =0x04000208
    mov r0, #1
    strh r0, [r2]                  @ IME on
.endm
.macro wdg_disarm
    ldr r2, =0x04000208
    mov r0, #0
    strh r0, [r2]
    ldr r2, =0x04000200
    strh r0, [r2]
    ldr r0, =0x3FFF
    strh r0, [r2, #2]
    ldr r2, =0x0400010C
    mov r0, #0
    str r0, [r2]
.endm
