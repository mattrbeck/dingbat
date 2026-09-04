; probe_j_winrestart -- how many dots does a mid-line window start cost?
;
; gb.nim WIN_RESTART_COUNTER / CGB_WIN_RESTART_COUNTER: "Which fetcher step a
; window start's restarted fetch resumes at, per model: 0 = fetch_counter 0, a
; six-dot startup fetch (Pan Docs); 1 = five dots. Both ship 0. DMG 0 is
; pinned by mealybug's DMG set. A five-dot CGB restart is suggested by probe
; (f) but no ROM pins it; assumed equal to the DMG." This page pins it.
;
; THE IDEA. A window start does not move any pixel by itself: the window's
; first pixel goes at x = WX - 7 whatever the restart costs, and the cost is
; spent as a stall, so it only makes mode 3 longer. What it DOES move is
; everything downstream of the start MEASURED AGAINST THE CPU: a store at a
; fixed line dot lands `restart` dots later in the pixel stream when a window
; started ahead of it. So the page draws the same store twice --
;
;   band lines 0..3   window off (WX = WXFAR, never matches)   -> q*_off
;   band lines 4..7   window on  (WX = WXON, starts at x = 32) -> q*_on
;
; and  restart = (q*_on - q*_off) mod 8  dots (6 with the counter at 0, 5 with
; it at 1); see SUB-M-CYCLE RESOLUTION for q. The two halves are FOUR PIXEL
; ROWS APART in the same band, so the restart cost is literally the width of
; the notch in the edge. Both halves run the same code at the same dot on the same
; machine, so the number is free of the halt-wake anchor, of the machines'
; phase difference and of any CGB write latency: it is a DIFFERENCE of two
; columns in one photograph. The DMG photo is the control -- mealybug already
; says 6 there, so a DMG that reads anything else condemns the page, not the
; constant.
;
; TIMING. Identical in shape to probe_h_latency: one frame of straight-line
; code from the LYC = 0 halt wake (the LY 153 -> 0 snapback), LEAD M-cycles,
; then 144 slots of exactly 114 M (= 456 dots = one line), slot k on line k.
; In slot k:
;
;     NOPS BASE            ; BASE M
;     ld a, LCDC & ~$10    ; 2 M
;     ldh [c], a           ; 2 M   <- the store, in its 2nd M-cycle
;     NOPS GAP             ; GAP M
;     ld a, LCDC           ; 2 M
;     ldh [c], a           ; 2 M   <- restore, in mode 0
;     ld a, wx(k+1)        ; 2 M
;     ldh [rWX], a         ; 3 M   <- next line's WX, in mode 0
;     NOPS 114 - (BASE + GAP + 13)
;
; so the store's M-cycle begins at line dot phi + 4*(BASE + 3), with
; phi = (wake dot in line 153) + 4*LEAD - 456. dingbat wakes at line-153 dot 9
; (DMG) / 13 (CGB), so at LEAD = 112 phi = 1 / 5 and the store at BASE = 38
; begins at dot 165 / 169 -- inside mode 3 either way. The restore is at dot
; 325 / 329 and the WX store at dot 341 / 345, both in mode 0 (mode 3 ends by
; dot 269 even with the window start and the widest object penalty).
;
; SUB-M-CYCLE RESOLUTION. The CPU moves in 4-dot steps and a boundary that a
; bitplane fetch decides moves in 8-pixel steps, so as in probe_h the FETCH
; GRID is moved instead: one blank 8x8 object per band at X = OBJX0 + p,
; p = band & 7, stalls the fetcher 11 - min(5, p) dots, so a rising p walks
; the grid one dot earlier (p = 6, 7 clamp to 5 and must read as p = 5). Bands
; 8..15 repeat p = 0..7 with the store ONE M-CYCLE LATER, which is four more
; dots, so the sixteen bands cover ten consecutive grid phases
;
;     q = 4 * (band >> 3) + min(5, band & 7)       q = 0 .. 9
;
; and the four bands that give a q twice must agree. READ the edge as THE
; FIRST COLUMN THAT IS NOT WHITE. In each half that column is flat over q and
; moves up by one tile at exactly one q: that q is q*. At the crossing q a
; CGB can show a tile of mid grey, or a single non-white pixel one column
; early, instead of a clean 8-pixel step -- the store landing between a
; fetch's two bitplane reads, which on a CGB LCDC.4 reaches a dot late
; (CGB_TDSEL_LATENCY). That sliver IS the crossing: count it as moved.
; (Ten phases and not six because a CGB's halt wake is 4 dots later than a
; DMG's, so a six-phase window cannot hold both machines' step.)
;
; VERIFIED to discriminate: rebuilding dingbat with
; `-d:CGB_WIN_RESTART_COUNTER=1` moves the CGB q*_on from 7 to 6 and nothing
; else, i.e. the page reads 5 instead of 6 -- so a hardware photo that reads 5
; is not a reading artefact.
;
; THE PICTURE. White page, corner marks, ruler in row 0, label in row 17
; (50 01 BB LL AA HH: page code, version, BASE, LEAD, boot A, CGB flag).
; Rows 1..16 are the sixteen bands of eight lines, band b at lines 8+8b; the
; TOP HALF of each band is a window-off line and the BOTTOM HALF a window-on
; line.
;
;   BG map  $9800 rows 1..16: tile $00.  $8000 mode -> $8000, blank (WHITE);
;                             $8800 mode -> $9000, all $FF (BLACK).
;   win map $9C00 column 0:   tile $02, a one-pixel index-1 hairline at the
;                             window's own first column, about x = WXON - 7,
;                             in $8000 mode ($9020 black);
;           $9C00 elsewhere:  tile $01, blank in $8000 mode ($9010 black).
;
; So EVERY line reads white ... black with exactly one edge, and the only
; difference between a window line and a background line is where that edge
; sits. The hairline near x = 32 is the window's own first pixel column: it
; says the window really started (dingbat draws it at x = 31, one slot left --
; WIN_START_PRE_PIXEL), and it is 30+ pixels clear of the edge. A tile of
; mid grey at the edge is the store landing between a fetch's two bitplane
; reads (probe (h)'s grey half-bar); count it as the first dark column.
;
;   restart = 6  -> Pan Docs' six-dot startup fetch (WIN_RESTART_COUNTER = 0,
;                   what ships on both machines)
;   restart = 5  -> five dots on this machine (counter = 1); if only the CGB
;                   photo says 5, CGB_WIN_RESTART_COUNTER = 1 and the DMG keeps
;                   0, which is exactly what probe (f) suggested
;   anything else -> the restart is not a fixed fetch-step cost at all
;
; dingbat's prediction: tools/gbprobe/expected/probe_j_winrestart.<model>.png.

INCLUDE "hw.inc"

DEF VERSION EQU $01
DEF PAGECODE EQU $50

IF !DEF(LEAD)
DEF LEAD EQU 112             ; M-cycles from the wake to slot 0 (line 0)
ENDC
IF !DEF(BASE)
DEF BASE EQU 38              ; M-cycles into the slot before the test store
ENDC
DEF GAP  EQU 36              ; M-cycles between the test store and the restore
IF !DEF(WXON)
DEF WXON EQU 39              ; window-on bands: the window starts at x = 32
ENDC
IF !DEF(OBJX0)
DEF OBJX0 EQU 16             ; band 0's object, at x = 8; p = OBJX0 & 7 = 0
ENDC

DEF BAND0     EQU 8
DEF BANDS     EQU 16
DEF BANDLINES EQU 8
DEF WXFAR     EQU 200        ; a WX that never matches

DEF T_WHITE  EQU $00         ; $8000 blank    / $9000 black
DEF T_WIN    EQU $01         ; $8010 blank    / $9010 black
DEF T_WMARK  EQU $02         ; $8020 hairline / $9020 black
DEF T_CORNER EQU $06

DEF LCDC_REST EQU LCDCF_ON | LCDCF_WIN9C | LCDCF_WINON | LCDCF_BG8000 | \
                  LCDCF_BGON | LCDCF_OBJON
DEF LCDC_TEST EQU LCDC_REST ^ LCDCF_BG8000      ; bit 4 off: 8800 mode

    PROBE_HEADER

    PROBE_HRAM

    PROBE_MAIN

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a          ; boot A: $01 DMG, $FF MGB, $11 CGB/AGB
    call InitVideo

    ; ---- tiles. $8000 faces: $00 and $01 stay blank (white), $02 gets a
    ; single index-1 column at pixel 0 -- the window's first tile, so a faint
    ; grey hairline at x = WXON - 7 says the window really started.
    ld hl, $8000 + T_WMARK * 16
    ld b, 8
.wmark:
    ld a, $80                ; plane 0 bit 7, plane 1 clear: colour index 1
    ld [hl+], a
    xor a
    ld [hl+], a
    dec b
    jr nz, .wmark
    ld hl, $8000 + T_CORNER * 16
    ld de, CornerTile
    ld b, 16
.corner:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .corner
    ; $9000/$9010/$9020: the 8800-mode faces of tiles $00, $01 and $02, all
    ; solid black, so the store's boundary is the ONLY edge in the picture.
    ld hl, $9000
    ld a, $FF
    ld b, 48
.black8800:
    ld [hl+], a
    dec b
    jr nz, .black8800

    ; ---- maps. $9800 rows 1..16 (all 32 columns) = tile $00. (InitVideo has
    ; already cleared VRAM; written out so the page does not depend on it.)
    ld hl, _SCRN0 + 32
    ld bc, 16 * 32
.bg:
    xor a
    ld [hl+], a
    dec bc
    ld a, b
    or c
    jr nz, .bg
    ; $9C00 = the window: tile $02 in column 0 (the hairline), $01 elsewhere.
    ld hl, _SCRN1
    ld b, 32
.winrow:
    ld a, T_WMARK
    ld [hl+], a
    ld c, 31
    ld a, T_WIN
.wincol:
    ld [hl+], a
    dec c
    jr nz, .wincol
    dec b
    jr nz, .winrow

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
    ld a, PAGECODE
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

    ; ---- OAM: cleared, then one blank 8x8 object per band, entry b at
    ; Y = 16 + BAND0 + 8b (its band's first line) and X = OBJX0 + (b & 7).
    ; Tile 0 is blank so it costs its fetch and draws nothing; objects always
    ; address from $8000, so the LCDC.4 store cannot make them visible.
    ld hl, $FE00
    ld b, 160
    xor a
.oamclr:
    ld [hl+], a
    dec b
    jr nz, .oamclr
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

    ; ---- registers at rest. WY = 0 so the window is armed from line 0 with
    ; LCDC.5 on all frame; WX alone decides whether it starts.
    xor a
    ldh [rSCX], a
    ldh [rSCY], a
    ldh [rWY], a
    ld a, WXFAR
    ldh [rWX], a
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
    PROBE_ROMX

; SLOT_PARAMS k -- everything line k needs, as assembler variables:
;   soff   extra lead M-cycles (0 in bands 0..7, 1 in bands 8..15)
;   tv     the LCDC value stored mid-mode-3 on this line
;   wxv    the WX stored in this line's mode 0, i.e. LINE k+1's window
MACRO SLOT_PARAMS
    DEF soff = 0
    DEF tv   = LCDC_REST
    IF (\1) >= BAND0 && (\1) < BAND0 + BANDS * BANDLINES
        DEF soff = ((\1) - BAND0) / (BANDS / 2 * BANDLINES)
        DEF tv   = LCDC_TEST
    ENDC
    ; line k+1's WX. Lines 4..7 of a band are window lines, 0..3 are not;
    ; slot 143 arms line 0 of the next frame, never a window line.
    DEF nxt = (\1) + 1
    IF nxt >= BAND0 && nxt < BAND0 + BANDS * BANDLINES && \
       ((nxt - BAND0) % BANDLINES) >= BANDLINES / 2
        DEF wxv = WXON
    ELSE
        DEF wxv = WXFAR
    ENDC
ENDM

Frame:
    PROBE_POLL               ; cart only: START returns to the menu
    ld c, LOW(rLCDC)
    ANCHOR 0
    ; wake: line 153, LY already reading 0. Slot 0 begins LEAD M later.
    NOPS LEAD
FOR k, 0, 144
    SLOT_PARAMS k
    ; ---- line {d:k}: a slot of exactly 114 M
    NOPS BASE + soff
    ld a, tv                 ; 2 M
    ldh [c], a               ; 2 M -- the store under test, M-cycle BASE+soff+3
    NOPS GAP
    ld a, LCDC_REST          ; 2 M
    ldh [c], a               ; 2 M -- restore, in mode 0
    ld a, wxv                ; 2 M
    ldh [rWX], a             ; 3 M -- next line's WX, in mode 0
    NOPS 114 - (BASE + soff + GAP + 13)
ENDR
    jp Frame
