; probe_b_scxm3 -- how much does a mid-line SCX store lengthen mode 3, and
; does the amount depend on where in mode 3 the store lands?
;
; docs/gb-failure-triage.md, hardware experiment (b). This is the campaign's
; largest single unexplained quantity: gambatte's two rows bracket hardware at
; 11-14 dots on DMG and 7-10 on CGB for a store that LOWERS `SCX and 7`, and
; the extension grows with how late the store lands. dingbat extends mode 3 by
; zero. Nothing derived in four rounds produces that number, so this ROM stops
; deriving and measures the law directly.
;
; Method. SCX = 7 is written during mode 2, so the line latches a fine scroll
; of 7 and mode 3 is 172 + 7 dots long. Then, from one anchor:
;
;     <BASE_M + M nops>  ld a,$05 / ldh [c],a   ; C = LOW(rSCX): the store
;     <(7-M) + BASE_N + N nops>  ldh a,[rSTAT]  ; the read
;
; and the STAT byte is kept. M walks the STORE across the head of mode 3; N
; walks the READ across the mode-3 -> mode-0 boundary.
;
; The (7-M) term is the one deliberate refinement over the doc's sketch. Left
; out, the read's dot would be BASE + M + N, so the read would walk right along
; with the store and the M = 7 row would be four M-cycles past the boundary
; before its N sweep even started -- the top rows of the grid would carry no
; information at all. With it, the read lands on the SAME dot for every row, so
; a column of the grid is one dot of the line and the grid reads directly as
; "for each store position, at which read dot has mode 0 arrived".
;
; Rows 8 and 9 are the two controls the doc asks for:
;   row 8  M = 2, but the store writes $07 -- the value SCX ALREADY holds.
;          A store that does not change the fine scroll must not extend
;          anything. If it does, the mechanism is the store and not the value.
;   row 9  M = 2, and no store at all: four NOPs in its place, so the read dot
;          is identical. This is the zero of the whole measurement.
;
; Reading it. Each cell is the low nibble of STAT, so 7 is mode 3 and 4 is
; mode 0 (bit 2 is the LYC coincidence flag, set on the anchor line). Along a
; row, the first column showing 4 is the dot mode 0 arrived. Row 9 is the
; unextended boundary; every row above it that flips LATER is extended, and by
; how many columns is how many M-cycles.
;
; Screen layout (20x18 tiles)
;   row 0        BASE_M, BASE_N, ANCHOR line, all in hex
;   rows 2..11   row index at col 0, then N = 0..9 at cols 2..11

INCLUDE "hw.inc"

DEF ANCHOR_LINE EQU $47

; Store position. The store's write cycle lands at roughly
; (wake + 4*(BASE_M + M + 3)) dots, and mode 3 begins at dot 80, so BASE_M = 16
; starts the sweep just before mode 3 and walks it to about dot 107 at M = 7 --
; across the seven-dot fine-scroll discard and out the far side of it.
; Overridable from the command line (mk.sh probe_b_scxm3 -DBASE_M=8) so the
; store can be walked over a wider stretch of the line than one build covers,
; without the grid getting too big to photograph.
IF !DEF(BASE_M)
DEF BASE_M EQU 16
ENDC

; Read position. Calibrated against probe (a), which put the halt wake within a
; few dots of the line start: this places N = 0 about sixteen dots before the
; SCX=7 boundary at dot 259, and N = 9 about twenty-eight dots after it, so an
; extension anywhere in the measured 7..14 range is inside the window with
; room on both sides.
; The read's dot is (BASE_M + BASE_N + 14 + N) M-cycles from the wake, so the
; two bases are one quantity: BASE_N defaults to whatever keeps the READ where
; it is when BASE_M moves the STORE. Override BASE_M alone and the store walks
; while the boundary stays put, which is the sweep this experiment wants.
IF !DEF(BASE_N)
DEF BASE_N EQU 47 - BASE_M
ENDC

DEF ROWS EQU 10
DEF COLS EQU 10

SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "hram", HRAM
hIsCgb: db

SECTION "results", WRAM0[$C000]
wResults: ds ROWS * COLS

SECTION "main", ROM0[$150]

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a

    call InitVideo
    ld a, LCDC_MEASURE
    ldh [rLCDC], a

; --------------------------------------------------------------- sweep -----

; MEAS_STORE  M, N, slot, value
MACRO MEAS_STORE
    ld a, 7
    ldh [rSCX], a          ; the line latches a fine scroll of 7
    ld c, LOW(rSCX)
    ANCHOR ANCHOR_LINE
    NOPS BASE_M + (\1)
    ld a, \4
    ldh [c], a
    NOPS (7 - (\1)) + BASE_N + (\2)
    ldh a, [rSTAT]
    ld [wResults + (\3)], a
ENDM

; MEAS_NOSTORE  M, N, slot -- identical timing, no store.
MACRO MEAS_NOSTORE
    ld a, 7
    ldh [rSCX], a
    ANCHOR ANCHOR_LINE
    NOPS BASE_M + (\1)
    NOPS 4                 ; stands in for ld a,imm / ldh [c],a
    NOPS (7 - (\1)) + BASE_N + (\2)
    ldh a, [rSTAT]
    ld [wResults + (\3)], a
ENDM

    ; Rows 0..7: the measurement. A store of $05 lowers `SCX and 7` from 7.
    FOR m, 0, 8
        FOR n, 0, COLS
            MEAS_STORE m, n, m * COLS + n, $05
        ENDR
    ENDR

    ; Row 8: store the value SCX already holds.
    FOR n, 0, COLS
        MEAS_STORE 2, n, 8 * COLS + n, $07
    ENDR

    ; Row 9: no store.
    FOR n, 0, COLS
        MEAS_NOSTORE 2, n, 9 * COLS + n
    ENDR

; ---------------------------------------------------------------- draw -----
    call LcdOff

    ld d, 0
    ld e, 0
    ld a, BASE_M
    call PutByte
    ld e, 3
    ld a, BASE_N
    call PutByte
    ld e, 6
    ld a, ANCHOR_LINE
    call PutByte

    ld hl, wResults
    ld c, 0
.row:
    ld a, c
    add 2
    ld d, a
    ld e, 0
    ld a, c
    push hl
    push bc
    call PutNibble
    pop bc
    pop hl
    ld e, 2
    ld b, COLS
.col:
    ld a, [hl+]
    push hl
    push bc
    call PutNibble
    pop bc
    pop hl
    inc e
    dec b
    jr nz, .col
    inc c
    ld a, c
    cp ROWS
    jr nz, .row

    xor a
    ldh [rSCX], a
    ldh [rSCY], a
    call LcdOnText
    IDLE_FOREVER

INCLUDE "common.inc"
