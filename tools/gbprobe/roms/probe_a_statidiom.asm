; probe_a_statidiom -- does the STAT mode field read differently to the two
; read idioms, LD A,(C) and LDH A,($41), at the mode-0 boundary?
;
; Both idioms run from one anchor on one machine with their IO cycles on the
; same dot: LD A,(C) reads in M2 of 2, LDH A,($41) reads in M3 of 3, so the
; LD A,(C) arm gets one extra NOP and the two reads sample the same PPU dot.
;
; Setup: LCD on, BG on, OBJ off (an object fetch would absorb the field tail),
; window parked, SCY = 0. SCX = 3 is the measurement, SCX = 0 the control:
; with no fine scroll the mode-0 boundary moves 3 dots earlier and nothing
; else should change. Raw STAT bytes land at $C000; the ROM reports, it does
; not judge.
;
; Screen layout (20x18 tiles)
;   row 0   : BASE (2 hex digits) at col 0, ANCHOR line at col 3
;   row 1+N : N at col 0-1, then
;             col 3 = LD A,(C)   at SCX=3
;             col 4 = LDH A,($41) at SCX=3
;             col 6 = LD A,(C)   at SCX=0
;             col 7 = LDH A,($41) at SCX=0
; Each digit is the low nibble of STAT: bits 1-0 the mode, bit 2 the LYC
; coincidence flag (1 on the anchor line). 7 is mode 3, 4 is mode 0.

INCLUDE "hw.inc"

; Sweep line; mid-screen so the frame's edge lines play no part.
DEF ANCHOR_LINE EQU $47

; Base slide, in M-cycles from the halt wake. Mode 3 on a BG-only line ends at
; dot 252 + (SCX and 7), i.e. dot 255 at SCX=3; the read's IO cycle lands at
; wake + 4*(N+2) dots, so 52 puts the N = 0..15 window at about dots 216..276.
IF !DEF(BASE_A)
DEF BASE_A EQU 52
ENDC
DEF STEPS  EQU 16

SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "hram", HRAM
hIsCgb: db

SECTION "results", WRAM0[$C000]
wResults: ds 64

SECTION "main", ROM0[$150]

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a        ; $11 on CGB/AGB, $01 on DMG, $FF on MGB

    call InitVideo
    ld a, LCDC_MEASURE
    ldh [rLCDC], a

; --------------------------------------------------------------- sweep -----
; One anchor per measurement, so nothing accumulates between steps.

MACRO MEAS_C           ; \1 = slide in M-cycles, \2 = result slot
    ld c, LOW(rSTAT)
    ANCHOR ANCHOR_LINE
    NOPS (\1) + 1
    ldh a, [c]
    ld [wResults + (\2)], a
ENDM

MACRO MEAS_H           ; \1 = slide in M-cycles, \2 = result slot
    ANCHOR ANCHOR_LINE
    NOPS (\1)
    ldh a, [rSTAT]
    ld [wResults + (\2)], a
ENDM

    ld a, 3
    ldh [rSCX], a
    FOR i, 0, STEPS
        MEAS_C BASE_A + i, i * 2
        MEAS_H BASE_A + i, i * 2 + 1
    ENDR

    xor a
    ldh [rSCX], a
    FOR i, 0, STEPS
        MEAS_C BASE_A + i, 32 + i * 2
        MEAS_H BASE_A + i, 32 + i * 2 + 1
    ENDR

; ---------------------------------------------------------------- draw -----
    call LcdOff

    ld d, 0
    ld e, 0
    ld a, BASE_A
    call PutByte
    ld e, 3
    ld a, ANCHOR_LINE
    call PutByte

    FOR i, 0, STEPS
        ld d, (i) + 1
        ld e, 0
        ld a, i
        call PutByte
        ld e, 3
        ld a, [wResults + i * 2]
        call PutNibble
        ld e, 4
        ld a, [wResults + i * 2 + 1]
        call PutNibble
        ld e, 6
        ld a, [wResults + 32 + i * 2]
        call PutNibble
        ld e, 7
        ld a, [wResults + 32 + i * 2 + 1]
        call PutNibble
    ENDR

    xor a
    ldh [rSCX], a
    ldh [rSCY], a
    call LcdOnText
    IDLE_FOREVER

INCLUDE "common.inc"
