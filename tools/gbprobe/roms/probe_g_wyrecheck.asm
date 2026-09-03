; probe_g_wyrecheck -- does the window re-check WY when LCDC.5 turns on?
;
; docs/hwprobe-questions.md row 19 / docs/oracles.md ppu_store_lcdc. Pan
; Docs states the window's Y condition per line ("WY == LY at some point in
; the frame"); dingbat latches it at the top of every line without looking
; at LCDC.5 (window_trigger), and ALSO re-checks it inside the LCDC store
; (window_trigger_en, Assumed -- removing it changes no verdict in the tree).
;
; The frame: WY = 64, WX = 87 (window x = 80), LCDC.5 CLEAR from VBlank on.
; On line WLINE, at a cycle-counted dot inside mode 3 while the shifter is
; still left of x = 80, LCDC.5 is set and left set until line 136.
;
;   VARIANT 0   WLINE = 64, the WY line itself
;   VARIANT 1   WLINE = 65, the line after (LY != WY at the store)
;
; TIMING. ANCHOR WLINE parks the CPU on the LYC=WLINE halt wake; dingbat puts
; that wake at line dot 1 (DMG) / 5 (CGB, its CGB_HALT_PPU_LEAD on a normal
; line). Then
;
;     NOPS N          ; N M
;     ld a, LCDC_WIN  ; 2 M
;     ldh [c], a      ; 2 M: the store is its 2nd M-cycle
;
; so the store begins  wake + 4*(N + 3)  dots = line dot 141 (DMG) / 145
; (CGB) at N = 32: mode 3 began at dot 80 and the first pixel left at ~92,
; so the shifter is at x ~= 49..53, thirty pixels short of the window's 80.
; Nothing else touches the PPU until line 136, where LCDC.5 is cleared again
; so the label row (lines 136..143) stays readable.
;
; THE PICTURE. White page, corner marks, column digits in row 0, the label
; in row 17 (2V 01 NN LL AA HH: page $20+VARIANT, version, N, WLINE, boot A,
; cart CGB flag). Two black rules cross the whole screen at lines WLINE-1
; and WLINE+1, so line WLINE is a one-pixel white line between them. The
; window is black with a white column at each tile's right edge, from x = 80.
;
;   the white line between the rules STOPS at x = 80, and the block below
;     it is black to the bottom            -> the window started ON line WLINE
;   the white line runs the full width, and the block starts level with the
;     lower rule                            -> it started on the NEXT line
;   the white line runs the full width and there is no block at all
;                                          -> not this frame
;
; dingbat (both variants, all models): ON line WLINE -- its per-line latch is
; taken with LCDC.5 clear, and the mid-line enable then starts the window at
; x = 80 on the same line. A hardware "next line" on variant 0 would mean the
; latch needs LCDC.5 at the top of the line and the store does not re-check;
; "not this frame" on variant 1 would mean the latch itself needs LCDC.5.

INCLUDE "hw.inc"

IF !DEF(VARIANT)
DEF VARIANT EQU 0
ENDC
IF !DEF(N)
DEF N EQU 32
ENDC
DEF VERSION EQU $01
DEF WYLINE  EQU 64
DEF WLINE   EQU WYLINE + VARIANT
DEF WXVAL   EQU 87

DEF LCDC_NOWIN EQU LCDCF_ON | LCDCF_WIN9C | LCDCF_BG8000 | LCDCF_BGON     ; $D1
DEF LCDC_WIN   EQU LCDC_NOWIN | LCDCF_WINON                              ; $F1

DEF T_STRIPE EQU $05         ; black, column 7 white (the window)
DEF T_CORNER EQU $06
DEF T_RULE_A EQU $07         ; map row 7, lines 56..63
DEF T_RULE_B EQU $08         ; map row 8, lines 64..71

SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "hram", HRAM
hIsCgb: db

SECTION "main", ROM0[$150]

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a
    call InitVideo

    ; ---- tiles
    ld hl, $8000 + T_STRIPE * 16
    ld a, $FE
    ld b, 16
.stripe:
    ld [hl+], a
    dec b
    jr nz, .stripe
    ld hl, $8000 + T_CORNER * 16
    ld de, CornerTile
    ld b, 16 + 32              ; corner, rule A, rule B are consecutive
.copy:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .copy

    ; ---- maps: $9800 rows 7 and 8 carry the rules; $9C00 is all stripes.
    ld hl, _SCRN0 + 7 * 32
    ld a, T_RULE_A
    ld b, 32
.rowa:
    ld [hl+], a
    dec b
    jr nz, .rowa
    ld a, T_RULE_B
    ld b, 32
.rowb:
    ld [hl+], a
    dec b
    jr nz, .rowb
    ld hl, _SCRN1
    ld bc, 32 * 32
    ld a, T_STRIPE
.win:
    ld [hl+], a
    dec bc
    ld a, b
    or c
    ld a, T_STRIPE
    jr nz, .win

    ; ---- row 0 ruler, row 17 label, corners
    ld a, T_CORNER
    ld [_SCRN0 + 0], a
    ld [_SCRN0 + 19], a
    ld [_SCRN0 + 17 * 32 + 0], a
    ld [_SCRN0 + 17 * 32 + 19], a
    ld hl, _SCRN0 + 1
    ld c, 1
.ruler:
    ld a, c
    and $0F
    add FONT_BASE
    ld [hl+], a
    inc c
    ld a, c
    cp 19
    jr nz, .ruler
    ld d, 17
    ld e, 1
    ld a, $20 + VARIANT
    call PutByte
    ld e, 4
    ld a, VERSION
    call PutByte
    ld e, 7
    ld a, N
    call PutByte
    ld e, 10
    ld a, WLINE
    call PutByte
    ld e, 13
    ldh a, [hIsCgb]
    call PutByte
    ld e, 16
    ld a, [$0143]
    and $C0
    call PutByte

    ; ---- registers
    xor a
    ldh [rSCX], a
    ldh [rSCY], a
    ld a, WYLINE
    ldh [rWY], a
    ld a, WXVAL
    ldh [rWX], a
    ld a, LCDC_NOWIN
    ldh [rLCDC], a

Frame:
    ld c, LOW(rLCDC)
    ANCHOR WLINE
    NOPS N
    ld a, LCDC_WIN
    ldh [c], a                 ; the store: wake + 4*(N+3) dots
    ANCHOR 136
    ld a, LCDC_NOWIN
    ldh [c], a                 ; window off for the label row and the next frame
    jp Frame

CornerTile:
    dw `00000000
    dw `00000000
    dw `00333330
    dw `00333330
    dw `00333330
    dw `00333330
    dw `00333330
    dw `00000000
; Rule tiles: a black row wherever the tile row's screen line is WLINE-1 or
; WLINE+1. Tile A is map row 7 (line 56 + r), tile B map row 8 (64 + r).
RuleA:
FOR r, 0, 8
    IF (56 + r) == WLINE - 1 || (56 + r) == WLINE + 1
        dw `33333333
    ELSE
        dw `00000000
    ENDC
ENDR
RuleB:
FOR r, 0, 8
    IF (64 + r) == WLINE - 1 || (64 + r) == WLINE + 1
        dw `33333333
    ELSE
        dw `00000000
    ENDC
ENDR

INCLUDE "common.inc"
