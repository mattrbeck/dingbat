; Hardware registers and shared helpers for the gbprobe probe ROMs.
;
; Written from Pan Docs' register map. Nothing here is copied from a test
; suite; the probes are our own ROMs and this is their own header.

IF !DEF(HW_INC)
DEF HW_INC EQU 1

DEF rP1     EQU $FF00
DEF rDIV    EQU $FF04
DEF rIF     EQU $FF0F
DEF rLCDC   EQU $FF40
DEF rSTAT   EQU $FF41
DEF rSCY    EQU $FF42
DEF rSCX    EQU $FF43
DEF rLY     EQU $FF44
DEF rLYC    EQU $FF45
DEF rDMA    EQU $FF46
DEF rBGP    EQU $FF47
DEF rOBP0   EQU $FF48
DEF rOBP1   EQU $FF49
DEF rWY     EQU $FF4A
DEF rWX     EQU $FF4B
DEF rKEY1   EQU $FF4D
DEF rVBK    EQU $FF4F
DEF rBANK   EQU $FF50
DEF rBCPS   EQU $FF68
DEF rBCPD   EQU $FF69
DEF rSVBK   EQU $FF70
DEF rIE     EQU $FFFF

; LCDC bits
DEF LCDCF_ON     EQU %10000000
DEF LCDCF_WIN9C  EQU %01000000
DEF LCDCF_WINON  EQU %00100000
DEF LCDCF_BG8000 EQU %00010000
DEF LCDCF_BG9C   EQU %00001000
DEF LCDCF_OBJ16  EQU %00000100
DEF LCDCF_OBJON  EQU %00000010
DEF LCDCF_BGON   EQU %00000001

; STAT bits
DEF STATF_LYC    EQU %01000000
DEF STATF_MODE2  EQU %00100000
DEF STATF_MODE1  EQU %00010000
DEF STATF_MODE0  EQU %00001000

DEF IEF_VBLANK   EQU %00000001
DEF IEF_STAT     EQU %00000010

DEF _VRAM8000 EQU $8000
DEF _VRAM8800 EQU $8800
DEF _VRAM9000 EQU $9000
DEF _SCRN0    EQU $9800
DEF _SCRN1    EQU $9C00

; The whole measurement config, in one place, for the two numeric probes.
; BG only: OBJ off (the STAT field tail is absorbed by an object fetch, so the
; measured line must be object-free), window parked off screen, BG tile data
; at $8000, BG map at $9800.
DEF LCDC_MEASURE EQU LCDCF_ON | LCDCF_BG8000 | LCDCF_BGON

; ---------------------------------------------------------------------------
; The combined cart (probes_all.gb).
;
; GBPROBE_COMBINED lifts a probe out of the fixed $100/$150 cartridge layout so
; eighteen pages fit on one MBC5 cart behind a menu. A standalone build defines
; nothing and every one of these macros expands to exactly what the source used
; to spell out, so the standalone .gb files stay byte-for-byte the same.
;
; In the cart a probe keeps its code in ROM0 (the launcher's bank) and gets one
; switchable bank of its own for the big unrolled frame; GBPROBE_TAG names its
; sections and GBPROBE_BANK numbers that bank. The launcher owns hIsCgb and the
; common.inc routines, and every probe's RAM is unioned onto the same bytes
; because only one page ever runs.

; PROBE_HEADER -- the cart header and the jump to Start. The cart has its own.
MACRO PROBE_HEADER
IF !DEF(GBPROBE_COMBINED)
SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00
ENDC
ENDM

; PROBE_HRAM -- opens the probe's HRAM at $FF80, hIsCgb first. In the cart that
; byte is the launcher's (it survives the page, and holds the boot A the
; launcher hands back), so the probe only reserves it.
MACRO PROBE_HRAM
IF DEF(GBPROBE_COMBINED)
SECTION UNION "probe_hram", HRAM[$FF80]
    ds 1
ELSE
SECTION "hram", HRAM[$FF80]
hIsCgb: db
ENDC
ENDM

; PROBE_WRAM $Cxxx -- opens a fixed WRAM0 block, unioned across pages.
MACRO PROBE_WRAM
IF DEF(GBPROBE_COMBINED)
SECTION UNION "probe_wram_\1", WRAM0[\1]
ELSE
SECTION "probe_wram_\1", WRAM0[\1]
ENDC
ENDM

; PROBE_MAIN -- the probe's code. $150 standalone, a floating ROM0 block in the
; cart; nothing here is timing-critical (every measurement re-anchors on LYC).
MACRO PROBE_MAIN
IF DEF(GBPROBE_COMBINED)
SECTION "main_{GBPROBE_TAG}", ROM0
ProbeStart_{GBPROBE_TAG}::     ; the menu's entry point for this page
ELSE
SECTION "main", ROM0[$150]
ENDC
ENDM

; PROBE_ROMX -- the probe's own $4000 bank for the unrolled frame.
MACRO PROBE_ROMX
IF DEF(GBPROBE_COMBINED)
SECTION "romx_{GBPROBE_TAG}", ROMX[$4000], BANK[GBPROBE_BANK]
ELSE
SECTION "frame", ROMX[$4000], BANK[1]
ENDC
ENDM

; PROBE_POLL -- one START poll, at the top of a page's redraw loop. Costs a
; handful of M-cycles before the loop's own ANCHOR, which re-syncs anyway.
MACRO PROBE_POLL
IF DEF(GBPROBE_COMBINED)
    call ProbePoll
ENDC
ENDM

; ---------------------------------------------------------------------------
; NOPS n -- n nop instructions, the slide every probe is built out of.
; n = 0 emits nothing, which REPT already does; the macro exists so the call
; sites read as a dot count rather than as an assembler directive.
MACRO NOPS
    REPT (\1)
        nop
    ENDR
ENDM

; ---------------------------------------------------------------------------
; ANCHOR line -- park the CPU on a known dot of a known line.
;
; STAT's LYC=LY source with IME off: the CPU sits in `halt` and is woken by IF
; alone, so it resumes without a vector fetch and without touching the stack.
; Waking on LYC rather than on mode 2 pins the LINE as well as the dot, which
; matters because the probes sweep the code length before the halt: a mode-2
; wake would land on whichever line the sweep happened to reach, and every
; step of the sweep would be measuring a different line.
;
; IF is cleared immediately before the halt so a stale STAT request cannot
; make this a halt-bug (no-halt) case; IE holds STAT alone so nothing else can
; wake it.
MACRO ANCHOR
    ld a, STATF_LYC
    ldh [rSTAT], a
    ld a, \1
    ldh [rLYC], a
    ld a, IEF_STAT
    ldh [rIE], a
    xor a
    ldh [rIF], a
    halt
ENDM

; ---------------------------------------------------------------------------
; IDLE_FOREVER -- park the CPU with the picture up, and do it safely.
;
; The obvious `halt / jr @-1` is a trap here, and it cost a debugging session:
; the probes leave the anchor's STAT request SET in IF, so a bare `halt` with
; IME off hits the halt bug, the operand byte of the following `jr` is read as
; an opcode, and execution runs off into whatever follows -- which on both
; dingbat and SameBoy ends with something writing LCDC and a white screen. IE
; is cleared first so IE & IF is zero and the halt is a real halt.
MACRO IDLE_FOREVER
    xor a
    ldh [rIE], a
    ldh [rIF], a
.idle\@:
IF DEF(GBPROBE_COMBINED)
    call ProbePoll         ; START goes back to the cart's menu
ELSE
    halt
ENDC
    jr .idle\@
ENDM

ENDC
