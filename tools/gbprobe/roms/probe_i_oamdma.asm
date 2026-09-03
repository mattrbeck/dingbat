; probe_i_oamdma -- does the OAM scan see an object whose entry an OAM DMA is
; covering, and is entry 39 special?
;
; docs/hwprobe-questions.md row 17: strikethrough's LY-68 frame draws OAM
; entry 39 although an OAM DMA covers that line's mode 2, and dingbat's
; OAM_SCAN_DMA_LOCK / CGB_HALT_PPU_LEAD (fifo_ppu.nim) each break it.
;
; Two solid black 8x16 objects, lines 64..79: entry 0 at x = 40, entry 39
; at x = 80. Every other entry is zero. The DMA copies $C000, which holds
; the same 160 bytes, so OAM's contents never change: the only question is
; what the scan reads WHILE the DMA runs.
;
; TIMING. ANCHOR 66 (dingbat: wake at line dot 1 DMG / 5 CGB), then
;
;     NOPS N            ; N M
;     ld a, $C0         ; 2 M
;     call hDma         ; 6 M         (the loop runs from HRAM: during the
;     ldh [rDMA], a     ; 3 M, store in its 3rd M-cycle    DMA the CPU may
;                                                          not read ROM)
; store at wake + 4*(N + 10) dots = line 66 dot 289 (DMG) / 293 (CGB) at
; N = 62, in mode 0. The transfer takes 160 M = 640 dots from the following
; M-cycle: dots 293..933 of line 66 = line 67 dots 0..456 entire, and line
; 68 dots 0..21 (DMG; +4 CGB). So line 67's whole OAM scan is under the DMA;
; on line 68 entry 0 (scanned at dot 0) is under it and entry 39 (dot 78)
; is after it. Lines 64..66 and 69..79 are the controls.
;
; THE PICTURE. White page, corner marks, digits in row 0, label in row 17
; (40 01 NN 42 AA HH: page, version, N, the anchor line, boot A, CGB flag).
; A two-pixel black marker at x = 8..31 on lines 67 and 68 names the two
; lines under the DMA. The objects are two black 8x16 columns.
;
;   entry 0 (left) missing lines 67 AND 68, entry 39 missing 67 only
;       -> the scan reads what the DMA leaves ($FF: off-screen) for every
;          entry not yet copied / for the whole transfer, per entry
;   both columns missing 67 and 68     -> the scan is blind for the whole
;                                         DMA regardless of entry
;   both complete                      -> the scan reads OAM through the DMA
;   entry 39 complete, entry 0 gapped  -> entry 39 is special, as
;                                         strikethrough's reference says
;
; dingbat (OAM_SCAN_DMA_LOCK): see tools/gbprobe/expected/probe_i_oamdma.*.

INCLUDE "hw.inc"

IF !DEF(N)
DEF N EQU 62
ENDC
DEF VERSION EQU $01
DEF ALINE   EQU 66
DEF rOCPS   EQU $FF6A
DEF rOCPD   EQU $FF6B

DEF LCDC_OBJ EQU LCDCF_ON | LCDCF_BG8000 | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ16

DEF T_CORNER EQU $06
DEF T_MARK   EQU $07         ; rows 3 and 4 black: lines 67, 68 in map row 8
DEF T_OBJ    EQU $02         ; $8020/$8030 black: the 8x16 object

SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "hram", HRAM
hIsCgb: db
hDma:   ds 8                 ; ldh [rDMA],a / ld b,40 / dec b / jr nz / ret

SECTION "oamcopy", WRAM0[$C000]
wOam:   ds 160

SECTION "main", ROM0[$150]

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a
    call InitVideo

    ld hl, $8000 + T_OBJ * 16
    ld a, $FF
    ld b, 32
.obj:
    ld [hl+], a
    dec b
    jr nz, .obj
    ld hl, $8000 + T_CORNER * 16
    ld de, CornerTile
    ld b, 32
.copy:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .copy
    ld hl, hDma
    ld de, DmaCode
    ld b, DmaCodeEnd - DmaCode
.hram:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .hram

    ; ---- OAM image in WRAM, then OAM itself (LCD off: writable directly).
    ld hl, wOam
    ld bc, 160
    xor a
.clr:
    ld [hl+], a
    dec bc
    ld a, b
    or c
    ld a, 0
    jr nz, .clr
    ld a, 16 + 64
    ld [wOam + 0], a          ; entry 0:  Y 80, X 48 (x = 40), tile 2
    ld [wOam + 39 * 4], a     ; entry 39: Y 80, X 88 (x = 80), tile 2
    ld a, 48
    ld [wOam + 1], a
    ld a, 88
    ld [wOam + 39 * 4 + 1], a
    ld a, T_OBJ
    ld [wOam + 2], a
    ld [wOam + 39 * 4 + 2], a
    ld hl, wOam
    ld de, $FE00
    ld b, 160
.oam:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .oam

    ; ---- map: marker at row 8 columns 1..3, corners, ruler, label
    ld a, T_MARK
    ld [_SCRN0 + 8 * 32 + 1], a
    ld [_SCRN0 + 8 * 32 + 2], a
    ld [_SCRN0 + 8 * 32 + 3], a
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
    ld a, $40
    call PutByte
    ld e, 4
    ld a, VERSION
    call PutByte
    ld e, 7
    ld a, N
    call PutByte
    ld e, 10
    ld a, ALINE
    call PutByte
    ld e, 13
    ldh a, [hIsCgb]
    call PutByte
    ld e, 16
    ld a, [$0143]
    and $C0
    call PutByte

    ; CGB object palette 0: the same four greys common.inc gives BG palette
    ; 0 (InitVideo sets BCPD only; OBJ CRAM is whatever the boot left).
    ldh a, [hIsCgb]
    cp $11
    jr nz, .noObjPal
    ld a, $80
    ldh [rOCPS], a
    ld hl, CgbPal0
    ld b, 8
.opal:
    ld a, [hl+]
    ldh [rOCPD], a
    dec b
    jr nz, .opal
.noObjPal:

    xor a
    ldh [rSCX], a
    ldh [rSCY], a
    ld a, LCDC_OBJ
    ldh [rLCDC], a

Frame:
    ANCHOR ALINE
    NOPS N
    ld a, HIGH(wOam)
    call hDma                  ; the store is 9 M after the NOPs end
    jp Frame

DmaCode:
    ldh [rDMA], a
    ld b, 40
.wait:
    dec b
    jr nz, .wait
    ret
DmaCodeEnd:

CornerTile:
    dw `00000000
    dw `00000000
    dw `00333330
    dw `00333330
    dw `00333330
    dw `00333330
    dw `00333330
    dw `00000000
MarkTile:
    dw `00000000
    dw `00000000
    dw `00000000
    dw `33333333
    dw `33333333
    dw `00000000
    dw `00000000
    dw `00000000

INCLUDE "common.inc"
