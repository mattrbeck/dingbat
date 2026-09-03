; probe_h_latency -- per-register CGB write latency, one register per page.
;
; A CPU store to a PPU register lands on the DMG at the top of the store's
; M-cycle; dingbat gives each register its own CGB delay on top of that
; (gb.nim CGB_SCX_LATENCY, CGB_SCY_LATENCY, CGB_WX_LATENCY, CGB_TDSEL_LATENCY,
; CGB_MAP_LATENCY; memory.nim mem_tick_ppu_latched; the mixer's
; CGB_MIXER_LATENCY for BGP). That the six are independent numbers is
; Assumed (docs/oracles.md). Every page here has the same code shape and the
; same anchor, so the DIFFERENCES between pages on one machine are free of
; the anchor, and the same page on a DMG and a CGB differ by the register's
; latency plus whatever the two machines' halt-wake phase differs by.
;
; PAGE selects the register (mk.sh probe_h_latency -DPAGE=n):
;   0 SCX    1 SCY    2 WX    3 BGP    4 LCDC.4 (tile data)    5 LCDC.3 (BG map)
;
; TIMING. One frame of straight-line code from the LYC=0 halt wake (the LY
; 153 -> 0 snapback, as probe (d)): LEAD M-cycles, then 144 slots of exactly
; 114 M-cycles (= 456 dots = one scanline), slot k drawn on line k. In slot
; k the store under test is
;
;     NOPS BASE+OFF        ; BASE+OFF M
;     ld a, T              ; 2 M
;     ldh [c], a           ; 2 M: fetch, then the store in its 2nd M-cycle
;
; so the store's M-cycle begins at
;
;     wake + 4 * (LEAD + 114*k + BASE + OFF + 3) dots
;
; and, since 114 M is one line, at line dot  phi + 4*(BASE + OFF + 3)  on line
; k, where phi = (wake dot within line 153) + 4*LEAD - 456. dingbat puts the
; wake at line-153 dot 9 on a DMG and dot 13 on every CGB revision (measured
; with -d:gb_win_trace), so with LEAD = 112, phi = 1 (DMG) / 5 (CGB) and the
; store at BASE = 38, OFF = 0 begins at line dot 165 (DMG) / 169 (CGB) --
; inside mode 3 (dots 80..252+SCX&7) at every fine scroll, and the CGB
; register latency is added to that. The restore store follows GAP M later,
; at line dot phi + 4*(BASE + OFF + GAP + 7) = 325+ (mode 0 at any SCX&7; a
; window start adds at most 6 dots to mode 3, an object at most 11). Nothing
; else touches the PPU during the frame.
;
; THE PICTURE. 20x18 tiles, white page. Row 0: corner marks, column digits
; 1..9 A..F 0 1 2 (the digit is the column's index). Rows 1..16: sixteen
; bands of eight lines, band b at lines 8+8b .. 15+8b. Row 17: corner marks
; and the label  PP 01 BB LL AA HH : page code ($30 + PAGE), version, BASE,
; LEAD, the boot value of A ($01 DMG, $11 CGB/AGB), and the cartridge's
; $0143 CGB flag ($80 native, $00 = compatibility-mode build).
;
; FETCHER PAGES (SCX, SCY, LCDC.4, LCDC.3). The CPU can only move the store
; in 4-dot steps and the fetch grid is locked to the line (a fine scroll
; moves the pixels against the grid, not the grid against the CPU), so the
; grid is moved instead: one blank 8x8 object per band, at X = OBJX0 + p,
; stalls the fetcher 11 - min(5, p) dots (Pan Docs "OBJ penalty"; the shape
; probe (e) saw on hardware), pushing every later fetch that much later.
; Band b has p = b & 7 (p = 6, 7 repeat 5), and bands 8..15 repeat 0..7 with
; the store one M-cycle later (OFF = 1). The background is a checker of
; 8-pixel bars; the store makes every fetch from some tile n on read the
; inverse (SCX+8 shifts the map one column; LCDC.3 picks the inverted map;
; LCDC.4 swaps to inverted tile data; SCY+4 swaps the tiles' two halves), so
; the band shows one DOUBLED bar, and its right half is column n. Reading:
; going down bands 0..5 the grid comes one dot earlier per band, so the
; doubled bar sits at column n and then steps to n+1 at the band p* where
; fetch n's read has moved ahead of the store; one dot of register latency
; moves p* one band UP (the store lands later, so the step comes earlier);
; bands 8..15 must show the same step four bands earlier (a 4-dot check of
; the sync). A grey (index 1 or 2) half-bar is the store landing between a
; fetch's two bitplane reads (the shade names the plane, as probe (d)).
;
; WX PAGE. LCDC.5 on, WY = 8, WX = 200 (never matches) at every line start;
; at the store WX := WX0 + b. The window (black with a white column at each
; tile's right edge) starts on that line at x = WX-7 iff the shifter has not
; passed it: a staircase from band b* down, b* the first band with a window.
; One dot of latency moves b* by one; one pixel of comparator lead the same.
;
; BGP PAGE (compatibility-mode cart: BGP is dead on a CGB running a
; CGB-flagged cart). Band b stores an inverted BGP at BASE + b: the white page
; turns black from x = (store dot + mixer delay) - 92, a 4-pixel staircase
; whose column against the ruler is the emission phase itself.

INCLUDE "hw.inc"

IF !DEF(PAGE)
    FAIL "build with -DPAGE=0..5 (SCX SCY WX BGP LCDC4 LCDC3)"
ENDC
DEF PAGE_SCX   EQU 0
DEF PAGE_SCY   EQU 1
DEF PAGE_WX    EQU 2
DEF PAGE_BGP   EQU 3
DEF PAGE_LCDC4 EQU 4
DEF PAGE_LCDC3 EQU 5
DEF VERSION    EQU $01

IF !DEF(LEAD)
DEF LEAD EQU 112             ; M-cycles from the wake to slot 0 (line 0)
ENDC
IF !DEF(BASE)
DEF BASE EQU 38              ; M-cycles into the slot before the test store
ENDC
DEF GAP  EQU 36              ; M-cycles between the test store and the restore
IF !DEF(WX0)
DEF WX0  EQU 76              ; WX page: band 0's WX; x = 69
ENDC
IF !DEF(OBJX0)
DEF OBJX0 EQU 32             ; fetcher pages: band 0's object, at x = 24
ENDC

DEF BAND0    EQU 8           ; first band line
DEF BANDS    EQU 16
DEF BANDLINES EQU 8
DEF WXFAR    EQU 200         ; a WX that never matches

; Tiles ($8000 mode). $00 blank is index 0 everywhere; the font is at $10.
DEF T_WHITE  EQU $00
DEF T_BLACK  EQU $02         ; $8020: index 3.  8800 mode: $9020, left blank
DEF T_HALFW  EQU $03         ; rows 0-3 index 0, rows 4-7 index 3
DEF T_HALFB  EQU $04         ; rows 0-3 index 3, rows 4-7 index 0
DEF T_STRIPE EQU $05         ; black, column 7 white (the window)
DEF T_CORNER EQU $06         ; 5x5 black square inset 2 px

IF PAGE == PAGE_WX
DEF LCDC_REST EQU LCDCF_ON | LCDCF_WIN9C | LCDCF_WINON | LCDCF_BG8000 | LCDCF_BGON
ELIF PAGE == PAGE_BGP
DEF LCDC_REST EQU LCDC_MEASURE            ; $91
ELSE
DEF LCDC_REST EQU LCDC_MEASURE | LCDCF_OBJON   ; $93: the grid-shifting objects
DEF FETCHER_PAGE EQU 1
ENDC

IF PAGE == PAGE_SCX
DEF REG EQU rSCX
ELIF PAGE == PAGE_SCY
DEF REG EQU rSCY
ELIF PAGE == PAGE_WX
DEF REG EQU rWX
ELIF PAGE == PAGE_BGP
DEF REG EQU rBGP
ELSE
DEF REG EQU rLCDC
ENDC

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
    ldh [hIsCgb], a          ; boot A: $01 DMG, $11 CGB/AGB
    call InitVideo

    ; ---- tiles
    ld hl, $8000 + T_BLACK * 16
    ld a, $FF
    ld b, 16
.black:
    ld [hl+], a
    dec b
    jr nz, .black
    ld hl, $8000 + T_HALFW * 16     ; rows 0-3 clear, rows 4-7 set
    xor a
    ld b, 8
.halfw0:
    ld [hl+], a
    dec b
    jr nz, .halfw0
    ld a, $FF
    ld b, 8
.halfw1:
    ld [hl+], a
    dec b
    jr nz, .halfw1
    ld hl, $8000 + T_HALFB * 16     ; rows 0-3 set, rows 4-7 clear
    ld b, 8
.halfb0:
    ld [hl+], a
    dec b
    jr nz, .halfb0
    xor a
    ld b, 8
.halfb1:
    ld [hl+], a
    dec b
    jr nz, .halfb1
    ld hl, $8000 + T_STRIPE * 16
    ld a, $FE
    ld b, 16
.stripe:
    ld [hl+], a
    dec b
    jr nz, .stripe
    ld hl, $8000 + T_CORNER * 16
    ld de, CornerTile
    ld b, 16
.corner:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .corner
IF PAGE == PAGE_LCDC4
    ; 8800-mode tile $00 lives at $9000: make it black, so the checker's
    ; white tile reads black and its black tile ($9020, blank) reads white.
    ld hl, $9000
    ld a, $FF
    ld b, 16
.t9000:
    ld [hl+], a
    dec b
    jr nz, .t9000
ENDC

    ; ---- maps. $9800 rows 1..16 (all 32 columns): the page's pattern.
    ld hl, _SCRN0 + 32
    ld b, 16
.rows:
    ld c, 16
.cols:
IF PAGE == PAGE_SCY
    ld a, T_HALFW
    ld [hl+], a
    ld a, T_HALFB
    ld [hl+], a
ELIF PAGE == PAGE_WX || PAGE == PAGE_BGP
    xor a
    ld [hl+], a
    ld [hl+], a
ELSE
    ld a, T_WHITE
    ld [hl+], a
    ld a, T_BLACK
    ld [hl+], a
ENDC
    dec c
    jr nz, .cols
    dec b
    jr nz, .rows

IF PAGE == PAGE_LCDC3
    ; $9C00: the inverted checker, every row.
    ld hl, _SCRN1
    ld b, 32
.rows1:
    ld c, 16
.cols1:
    ld a, T_BLACK
    ld [hl+], a
    ld a, T_WHITE
    ld [hl+], a
    dec c
    jr nz, .cols1
    dec b
    jr nz, .rows1
ENDC
IF PAGE == PAGE_WX
    ; $9C00: the window, stripes everywhere.
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
ENDC

    ; ---- row 0: corners and the column ruler; row 17: corners and the label.
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
    ld a, $30 + PAGE
    call PutByte
    ld e, 4
    ld a, VERSION
    call PutByte
    ld e, 7
    ld a, BASE
    call PutByte
    ld e, 10
    ld a, LEAD
    call PutByte
    ld e, 13
    ldh a, [hIsCgb]
    call PutByte
    ld e, 16
    ld a, [$0143]
    and $C0
    call PutByte

    ; ---- OAM: cleared, then one blank 8x8 object per band on the fetcher
    ; pages, entry b at Y = 16 + 8 + 8b (its band's first line) and
    ; X = OBJX0 + (b & 7). Tile 0 is blank, so it costs its fetch and draws
    ; nothing. The LCD is off, so OAM is writable directly.
    ld hl, $FE00
    ld b, 160
    xor a
.oamclr:
    ld [hl+], a
    dec b
    jr nz, .oamclr
IF DEF(FETCHER_PAGE)
    ld hl, $FE00
FOR bi, 0, BANDS
    ld a, 16 + BAND0 + BANDLINES * bi
    ld [hl+], a
    ld a, OBJX0 + (bi & 7)
    ld [hl+], a
    xor a
    ld [hl+], a
    ld [hl+], a
ENDR
ENDC

    ; ---- registers at rest
    xor a
    ldh [rSCX], a
    ldh [rSCY], a
    ld a, %11100100
    ldh [rBGP], a
    ld a, WXFAR
    ldh [rWX], a
    ld a, BAND0                ; WY: the WX page's window is armed from band 0
    ldh [rWY], a
    ld a, LCDC_REST
    ldh [rLCDC], a
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

INCLUDE "common.inc"

; ---------------------------------------------------------------- frame ----
; 144 unrolled slots are ~16 KB, so the frame gets the ROM's second half
; (a plain 32 KB ROM-only cart maps it at $4000 with no banking).
SECTION "frame", ROMX[$4000], BANK[1]

; Per-line parameters, as assembler variables set by BAND_PARAMS:
;   off    extra lead M-cycles   tval   the test store   rval  the restore
MACRO BAND_PARAMS               ; \1 = this line's band or -1
    DEF off   = 0
IF PAGE == PAGE_SCX
    DEF tval  = 0
    DEF rval  = 0
    IF (\1) >= 0
        DEF off   = (\1) >> 3
        DEF tval  = 8
    ENDC
ELIF PAGE == PAGE_SCY
    DEF tval  = 0
    DEF rval  = 0
    IF (\1) >= 0
        DEF off   = (\1) >> 3
        DEF tval  = 4
    ENDC
ELIF PAGE == PAGE_WX
    DEF tval  = WXFAR
    DEF rval  = WXFAR
    IF (\1) >= 0
        DEF tval  = WX0 + (\1)
    ENDC
ELIF PAGE == PAGE_BGP
    DEF tval  = %11100100
    DEF rval  = %11100100
    IF (\1) >= 0
        DEF off   = (\1)
        DEF tval  = %00011011
    ENDC
ELIF PAGE == PAGE_LCDC4
    DEF tval  = LCDC_REST
    DEF rval  = LCDC_REST
    IF (\1) >= 0
        DEF off   = (\1) >> 3
        DEF tval  = LCDC_REST ^ LCDCF_BG8000      ; bit 4 off: 8800 mode
    ENDC
ELSE ; PAGE_LCDC3
    DEF tval  = LCDC_REST
    DEF rval  = LCDC_REST
    IF (\1) >= 0
        DEF off   = (\1) >> 3
        DEF tval  = LCDC_REST | LCDCF_BG9C
    ENDC
ENDC
ENDM

Frame:
    ld c, LOW(REG)
    ANCHOR 0
    ; wake: line 153, LY already reading 0. Slot 0 begins LEAD M later.
    NOPS LEAD
FOR k, 0, 144
    IF k >= BAND0 && k < BAND0 + BANDS * BANDLINES
        DEF band = (k - BAND0) / BANDLINES
    ELSE
        DEF band = -1
    ENDC
    BAND_PARAMS band
    ; ---- line {d:k}: slot of 114 M
    NOPS BASE + off
    ld a, tval               ; 2 M
    ldh [c], a               ; 2 M -- the store under test, M-cycle BASE+off+3
    NOPS GAP
    ld a, rval               ; 2 M
    ldh [c], a               ; 2 M -- restore, in mode 0
    NOPS 114 - (BASE + off + 4 + GAP + 4)
ENDR
    jp Frame

