@ dbsuite.s -- a GBA test-suite ROM of behaviour measured on a real GBA SP
@ (AGS-001).  One ROM, a menu of suites, many cases each; every case
@ prints PASS/FAIL with the value it got and the value hardware gave.
@ README.md describes the screens, the output channels and the results
@ block a harness reads; build.py builds the cartridge image (dbsuite.gba)
@ and the multiboot image (dbsuite.mb.gba).
@
@ Assembled twice: MB=0 links this whole file at 0x08000000 behind a
@ cartridge header; MB=1 links it at MB_HOME in EWRAM, and mbstub.s carries
@ it as the body of a multiboot image and copies it there.
    .arm
    .text
    .global _start

    .include "defs.inc"

    @ the tables the case/suite macros fill (subsections 1 and 3)
    .pushsection .text, 1
    .align 2
case_table:
    .popsection
    .pushsection .text, 3
    .align 2
suite_table:
    .popsection

_start:
.if MB == 0
    b   header_end                 @ 0x00: the BIOS enters here
    .space 0x9C                    @ 0x04-0x9F: logo (gbafix)
    .space 0x20                    @ 0xA0-0xBF: title and codes (build.py)
header_end:                        @ 0xC0
.endif
    b   main
@ rom_config, at 0x080000C4 in the cartridge image (the body's second word
@ in the multiboot one; cases.json gives both file offsets): a harness may
@ patch it.  bit 0: run at once, without the menu's countdown, from case
@ bits 16-31 to the end; bit 1: never auto-run; bit 2: SKIP the cases
@ flagged F_RISKY (undefined CPSR modes).
rom_config:
    .word 0
rom_version:
    .ascii "dbsuite 1"
    .byte 0
    .align 2

    .include "runtime.inc"
    .include "suite_cpu.inc"
    .include "suite_irq.inc"
    .include "suite_timer.inc"
    .include "suite_dma.inc"
    .include "suite_bus.inc"
    .include "suite_ppu.inc"
    .include "suite_apu.inc"
    .include "suite_bios.inc"

    .ltorg
    .align 2
    .include "font_gen.inc"
    .align 2
    .include "logo_gen.inc"

    @ table terminators
    .pushsection .text, 3
    .align 2
    .word 0, NCASES
    .popsection
    .pushsection .text, 1
    .align 2
case_table_end:
    .popsection

.equ N_CASES, NCASES
.equ N_SUITES, NSUITES
