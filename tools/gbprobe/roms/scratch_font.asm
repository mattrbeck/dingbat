; Not a probe: a one-screen smoke test for the shared video/readout path, so a
; blank screen from a real probe can be told apart from a broken font, map or
; palette. Expected: "AB" at the top-left corner, "37" at row 2, column 5.
INCLUDE "hw.inc"

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
    ld d, 0
    ld e, 0
    ld a, $AB
    call PutByte
    ld d, 2
    ld e, 5
    ld a, $37
    call PutByte
    call LcdOnText
    IDLE_FOREVER

INCLUDE "common.inc"
