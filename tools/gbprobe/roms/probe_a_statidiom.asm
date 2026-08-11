; probe_a_statidiom -- does the STAT mode FIELD report differently to two read
; idioms at the mode-0 boundary?
;
; docs/gb-failure-triage.md, hardware experiment (a). Idiom and suite are
; perfectly confounded in every test ROM that exists: every LD A,(C) witness
; is gambatte's and every LDH A,($41) witness is GBMicrotest's, so no amount
; of re-reading those suites can separate "the idiom sees a different value"
; from "that suite measured something else". This ROM runs BOTH idioms, from
; ONE anchor, on ONE machine, with their IO cycles on the same dot.
;
; Equalising the IO cycle is the whole trick, and it is not the same as
; equalising the instruction start:
;
;   LD A,(C)      $F2      2 M-cycles, the IO read is M2
;   LDH A,($41)   $F0 $41  3 M-cycles, the IO read is M3
;
; so with both instructions starting on the same M-cycle, LDH reads one
; M-cycle LATER. The LD A,(C) arm therefore gets one MORE preceding NOP, and
; the two reads then sample the same PPU dot. (The triage doc's prose says
; exactly this; the code sketch beside it has the two slides the other way
; round, which would compare dots four apart. The prose is what is implemented
; here, and it is the arm that is self-consistent with the cycle counts it
; quotes in the same sentence.)
;
; Setup, per the doc: LCD on, BG on, OBJ OFF (the field tail is absorbed by an
; object fetch, so the measured line has to be object-free), window parked,
; SCY = 0. Two SCX blocks: SCX = 3 is the measurement and SCX = 0 is the
; control -- with no fine scroll the mode-0 boundary moves earlier by exactly
; s dots, so the whole flip should move by s and nothing else should change.
;
; Readout. Raw STAT bytes land at $C000; the screen shows, for each sweep step
; N, the low nibble of the four bytes measured at that N. Nothing is compared
; against an expectation anywhere in this ROM -- it reports, it does not judge,
; because the point is to find out what hardware does, not to confirm a guess.
;
; Screen layout (20x18 tiles)
;   row 0   : BASE (2 hex digits) at col 0, ANCHOR line at col 3
;   row 1+N : N at col 0-1, then
;             col 3 = LD A,(C)   at SCX=3
;             col 4 = LDH A,($41) at SCX=3
;             col 6 = LD A,(C)   at SCX=0
;             col 7 = LDH A,($41) at SCX=0
; Each result digit is the LOW NIBBLE of STAT, so bits 3..0: the mode is the
; bottom two bits and bit 2 is the LYC coincidence flag, which is 1 on the
; anchor line. A digit of 7 is mode 3, 4 is mode 0.

INCLUDE "hw.inc"

; The line the sweep runs on. Mid-screen, so nothing about the first or last
; line of the frame can be part of the answer.
DEF ANCHOR_LINE EQU $47

; Base slide, in M-cycles from the halt wake. Mode 3 on a BG-only line ends at
; dot 252 + (SCX and 7), so the boundary is dot 255 at SCX=3. The read's IO
; cycle lands at (wake + 4*(N+2)) dots, so a base of 52 puts the sweep window
; at roughly dots 216..276 for N = 0..15 -- wide enough that the flip is inside
; it whatever the wake latency turns out to be, on any of the three engines.
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
; One anchor per measurement, so every step starts from the same dot of the
; same line and nothing accumulates.

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
