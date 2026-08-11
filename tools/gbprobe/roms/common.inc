; Shared runtime for the gbprobe probes: video bring-up, and the hex readout.
;
; Include AFTER hw.inc and font.inc, once, into ROM0.

IF !DEF(COMMON_INC)
DEF COMMON_INC EQU 1

; The font is data, so it has to live inside a SECTION; common.inc is included
; at the bottom of each probe, where one is open.
INCLUDE "font.inc"

; ---------------------------------------------------------------------------
; LcdOff -- stop the LCD safely.
; Turning the LCD off outside VBlank is documented as damaging on real
; hardware, and these ROMs are built to be run on real hardware, so the wait
; is not optional.
LcdOff:
    ldh a, [rLCDC]
    and LCDCF_ON
    ret z
.wait:
    ldh a, [rLY]
    cp 145
    jr nz, .wait
    xor a
    ldh [rLCDC], a
    ret

; ---------------------------------------------------------------------------
; InitVideo -- LCD off, VRAM cleared, font loaded, map blanked, palettes set.
; Clobbers everything. Leaves the LCD OFF.
InitVideo:
    call LcdOff

    ; Clear both VRAM banks. Bank 1 only exists on CGB; the write to rVBK is
    ; harmless on a DMG (the register reads back $FF and the single bank is
    ; cleared twice).
    ld a, 1
    ldh [rVBK], a
    call ClearVram
    xor a
    ldh [rVBK], a
    call ClearVram

    ; Font at tile FONT_BASE.
    ld hl, _VRAM8000 + FONT_BASE * 16
    ld de, FontTiles
    ld bc, FONT_TILE_BYTES
.font:
    ld a, [de]
    inc de
    ld [hl+], a
    dec bc
    ld a, b
    or c
    jr nz, .font

    ; DMG palette: identity, so a tile's colour index IS its shade.
    ld a, %11100100
    ldh [rBGP], a
    ldh [rOBP0], a
    ldh [rOBP1], a

    ; CGB palette 0, same four shades, so the readout looks the same on both
    ; machines. On a DMG these two registers do not exist and the writes are
    ; dropped.
    ldh a, [hIsCgb]
    cp $11
    jr nz, .noCgbPal
    ld a, $80              ; BCPS: index 0, auto-increment
    ldh [rBCPS], a
    ld hl, CgbPal0
    ld b, 8
.pal:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .pal
.noCgbPal:

    xor a
    ldh [rSCY], a
    ldh [rSCX], a
    ld a, 144              ; window parked below the screen
    ldh [rWY], a
    ld a, 7
    ldh [rWX], a
    ret

CgbPal0:
    dw $7FFF               ; 0 white
    dw $56B5              ; 1 light grey
    dw $2529              ; 2 dark grey
    dw $0000               ; 3 black

ClearVram:
    ld hl, $8000
    ld bc, $2000
    xor a
.loop:
    ld [hl+], a
    dec bc
    ld a, b
    or c
    ld a, 0
    jr nz, .loop
    ret

; ---------------------------------------------------------------------------
; LcdOnText -- LCD on, BG only, map $9800, tiles $8000. For the readout, not
; for a measurement; a measurement sets LCDC itself.
LcdOnText:
    ld a, LCDCF_ON | LCDCF_BG8000 | LCDCF_BGON
    ldh [rLCDC], a
    ret

; ---------------------------------------------------------------------------
; MapAddr -- HL = $9800 + Y*32 + X, with Y in D and X in E.
MapAddr:
    ld hl, _SCRN0
    ld a, d
    or a
    jr z, .noRows
    ld b, a
.rows:
    ld a, l
    add 32
    ld l, a
    ld a, h
    adc 0
    ld h, a
    dec b
    jr nz, .rows
.noRows:
    ld a, l
    add e
    ld l, a
    ld a, h
    adc 0
    ld h, a
    ret

; ---------------------------------------------------------------------------
; PutNibble -- write the glyph for the low nibble of A at (E,D). LCD must be
; off. Clobbers A, HL, B.
PutNibble:
    and $0F
    add FONT_BASE
    ld b, a
    push bc
    call MapAddr
    pop bc
    ld [hl], b
    ret

; PutByte -- two glyphs for A at (E,D) and (E+1,D).
PutByte:
    ld c, a
    swap a
    call PutNibble
    inc e
    ld a, c
    call PutNibble
    dec e
    ret

ENDC
