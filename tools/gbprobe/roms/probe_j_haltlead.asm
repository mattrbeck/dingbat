; probe_j_haltlead -- does a CGB's halt wake land at the same phase on an
; ordinary line as it does on the LY 153 -> 0 snapback?
;
; cpu.nim, cpu_halt_tick: "The LY 153 -> 0 snapback wake does not carry the
; lead: daid ppu_scanline_bgp, whose wake is LYC = 0, is exact only without
; it; THAT THE LEAD HOLDS ON EVERY OTHER LINE IS ASSUMED; no ROM pins it."
; The same seam again in fifo_ppu.nim (M3_PIPE_AHEAD's derivation): "the four
; dots belong to the snapback halt wake (LYC_SETTLE_HALT_SKIP, gb.nim).
; Assumed; no ROM pins the re-anchored reading."  Three constants sit on that
; assumption: CGB_HALT_PPU_LEAD (1), LYC_SETTLE_HALT_SKIP (on) and
; CGB_HALT_LEAD_SKIP_LYC0 (0, derived from it).
;
; THE IDEA. One frame, one page, two halves that differ ONLY in which halt
; wake positioned them:
;
;   lines 8..71    half A: ONE halt, on LYC = 0 -- the LY 153 -> 0 snapback --
;                  then LEAD M-cycles and 64 lines of straight-line code, the
;                  way probe (d) and probe (h) are anchored.
;   lines 72..135  half B: a halt PER LINE, on LYC = that line, so every
;                  measured line carries its own ORDINARY-LINE wake.
;
; Both halves then do exactly the same thing: store LCDC with bit 4 clear at a
; known M-cycle inside mode 3, restore it in mode 0. The lead M-cycles are
; chosen (BASE_B = BASE_A - 2) so that in dingbat's own model the two stores
; would land on the same line dot if the two wakes had the same phase, and
;
;     P(half A) - P(half B)  =  (snapback wake dot) - (ordinary wake dot)
;
; falls straight out of the picture (see READING). dingbat says 8 dots on
; every model: its snapback wake is line dot 9 (DMG) / 13 (CGB) and its
; ordinary wake dot 1 / 5, so the two machines' 4-dot CGB lead cancels INSIDE
; each machine and both are predicted to read 8.
;
; That is what makes the page worth burning: it is a within-machine
; difference, so it needs no cross-machine anchor, no register latency and no
; agreement about where dot 0 is. A DMG that reads 8 and a CGB that reads 8
; leaves all three constants standing. A CGB that reads 4 or 12 while the DMG
; reads 8 says the CGB lead is NOT the same on an ordinary line as on the
; snapback -- exactly the assumption -- and the sign says which way:
;
;   CGB 12, DMG 8 -> the ordinary-line wake is 4 dots EARLIER than modelled:
;                    the lead does not apply there (CGB_HALT_LEAD_SKIP_LYC0
;                    has it backwards -- the snapback is the case that keeps it)
;   CGB  4, DMG 8 -> the ordinary-line wake is 4 dots LATER than modelled:
;                    the lead is doubled there, or the snapback pays it twice
;   CGB  8, DMG 4 -> the seam is on the DMG side (LYC_SETTLE_DOTS), not the
;                    CGB lead at all
;
; WHAT THIS PAGE CANNOT SEE, said plainly: a lead that applies EQUALLY to both
; wakes. dingbat's does -- LYC_SETTLE_HALT_SKIP moves the snapback wake one
; M-cycle early and CGB_HALT_PPU_LEAD puts it back, so both anchors carry the
; same four dots -- and rebuilding with `-d:CGB_HALT_PPU_LEAD=0` leaves this
; page's answer at 8 on every model. What the page IS sensitive to is the lead
; being ANCHOR-DEPENDENT, which is exactly the sentence in cpu.nim:
; `-d:CGB_HALT_LEAD_SKIP_LYC0=1` (the control build the comment names) moves
; half A's q* from 1 to 5 and nothing else, i.e. the page reads 4 instead of 8.
; The size of a uniform lead is probe (h)'s business (a CGB-minus-DMG column
; difference), not this page's.
;
; TIMING. Half A slot k begins at line k dot  w_snap + 4*LEAD - 456, which at
; LEAD = 112 is w_snap - 8; the store's M-cycle is BASE_A + 3 + soff M-cycles
; further on, i.e. at line dot  w_snap - 8 + 4*(BASE_A + 3 + soff).
; Half B line k wakes at dot w_ord and its store is at
; w_ord + 4*(BASE_B + 3 + soff), so with BASE_B = BASE_A - 2 the two differ by
; exactly w_snap - w_ord. Half B's slot then arms the next line and halts:
;
;     ... restore ...            ; ends about line dot 350
;     ld a, k+1 / ldh [rLYC], a  ; 5 M   (LY is still k: no match, no edge)
;     xor a     / ldh [rIF], a   ; 4 M   (so the halt is a real halt)
;     halt                       ; woken by LYC = k+1 at line k+1 dot 0
;
; With BASE_A = 38, GAP = 36 that puts the store at line dot 165 (DMG) / 169
; (CGB) in half A, the restore at 325 / 329 (mode 0 at every SCX) and the halt
; from about dot 390. STAT holds the LYC source alone and IE holds STAT alone
; for the whole frame, so nothing else can wake it.
;
; SUB-M-CYCLE RESOLUTION. The CPU moves in 4-dot steps and a boundary a
; bitplane fetch decides moves in 8-pixel steps, so as in probe (h) the FETCH
; GRID is moved instead: one blank 8x8 object per band at X = OBJX0 + p,
; p = band & 7, stalls the fetcher 11 - min(5, p) dots, so a rising p walks
; the grid one dot earlier (p = 6, 7 clamp to 5 and must read as p = 5). The
; four TOP lines of a band store at BASE, the four BOTTOM lines one M-cycle
; later, which is four more dots, so a band pair covers ten grid phases
;
;     q = 4 * (line is in the band's bottom half) + min(5, band & 7)
;
; and the phases that occur twice must agree. (SCX would be the cheaper
; shifter and does NOT work: a fine scroll moves the pixels against the grid,
; not the grid against the CPU -- e(s) + s comes out flat, verified.)
;
; THE PICTURE. White page, corner marks, ruler in row 0, label in row 17
; (51 01 BB LL AA HH: page code, version, BASE_A, LEAD, boot A, CGB flag).
; Rows 1..16 are 16 bands of eight lines, band b at lines 8 + 8b:
;
;     bands 0..7  half A (snapback)        bands 8..15  half B (per line)
;     p = b & 7   the band's object, and with it the grid phase
;
; Every line is white until the store's boundary and black after it: BG map
; all tile $00, whose $8000 face is blank and whose $8800 face ($9000) is
; solid black, so clearing LCDC.4 mid-line turns the rest of the line black.
; The objects are blank tile 0 and address from $8000 whatever LCDC.4 says,
; so they cost their fetch and draw nothing. Rows 0 and 17 are drawn with
; LCDC.4 set, so the ruler and the label are never inverted.
;
; READING. Read the edge column e(q), the first non-white column, for
; q = 0..9 in each half (bands 0..7 give it, and each band gives q and q+4 in
; its two halves). e is flat and steps up by one tile at exactly one q: q*.
; The two halves' q* must be EQUAL if the answer is a multiple of 8, so the
; answer comes off the columns:
;
;     answer = e_A(q) - e_B(q)  +  (q*_B - q*_A)     at any q where both flat
;
; and dingbat predicts 8 on dmg, cgbc, cgbd and agb alike (e_A one whole tile
; right of e_B, same q*). An answer of 4 or 12 shows up as the two halves'
; q* being four apart. A grey (index 1 or 2) tile or a one-pixel sliver at
; the edge is the store landing between a fetch's two bitplane reads; count
; it as the first non-white column.
;
; dingbat's prediction: tools/gbprobe/expected/probe_j_haltlead.<model>.png.

INCLUDE "hw.inc"

DEF VERSION  EQU $01
DEF PAGECODE EQU $51

IF !DEF(LEAD)
DEF LEAD EQU 112             ; M-cycles from the snapback wake to slot 0
ENDC
IF !DEF(BASE)
DEF BASE EQU 38              ; half A: M-cycles into the slot before the store
ENDC
DEF BASE_B EQU BASE - 2      ; half B: cancels LEAD = 112's -8 dots
DEF GAP    EQU 36            ; M-cycles from the test store to the restore

DEF BAND0     EQU 8
DEF BANDS     EQU 16
DEF BANDLINES EQU 8
DEF HALFLINE  EQU BAND0 + BANDS / 2 * BANDLINES   ; 72: first half-B line
IF !DEF(OBJX0)
DEF OBJX0 EQU 16             ; band 0's object, at x = 8; p = OBJX0 & 7 = 0
ENDC

DEF T_WHITE  EQU $00         ; $8000 blank / $9000 black
DEF T_CORNER EQU $06

DEF LCDC_REST EQU LCDC_MEASURE | LCDCF_OBJON    ; $93: the grid-shifting objects
DEF LCDC_TEST EQU LCDC_REST ^ LCDCF_BG8000      ; bit 4 off: 8800 mode

    PROBE_HEADER

    PROBE_HRAM

    PROBE_MAIN

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a          ; boot A: $01 DMG, $FF MGB, $11 CGB/AGB
    call InitVideo

    ; ---- tiles. $8000 tile $00 stays blank; its $8800-mode face at $9000 is
    ; solid black, so the LCDC.4 store is the only edge in the picture.
    ld hl, $9000
    ld a, $FF
    ld b, 16
.black8800:
    ld [hl+], a
    dec b
    jr nz, .black8800
    ld hl, $8000 + T_CORNER * 16
    ld de, CornerTile
    ld b, 16
.corner:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .corner

    ; ---- map: rows 1..16 (all 32 columns) are tile $00 already (InitVideo
    ; cleared VRAM); only the ruler and the label are drawn.
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

    xor a
    ldh [rSCX], a
    ldh [rSCY], a
    ld a, 144
    ldh [rWY], a
    ld a, 7
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

; SLOT_PARAMS k -- line k's parameters as assembler variables:
;   soff    extra lead M-cycles for the store: 0 in a band's top four lines,
;           1 in its bottom four
;   tv      the LCDC value stored mid-mode-3
MACRO SLOT_PARAMS
    DEF soff = 0
    DEF tv   = LCDC_REST
    IF (\1) >= BAND0 && (\1) < BAND0 + BANDS * BANDLINES
        DEF soff = (((\1) - BAND0) % BANDLINES) / (BANDLINES / 2)
        DEF tv   = LCDC_TEST
    ENDC
ENDM

; ARM_NEXT line -- point the LYC source at `line` and halt. LY is still
; line-1 when LYC is written, so the write cannot make an edge of its own.
MACRO ARM_NEXT
    ld a, \1                 ; 2 M
    ldh [rLYC], a            ; 3 M
    xor a                    ; 1 M
    ldh [rIF], a             ; 3 M
    halt                     ; 1 M, then the wait
ENDM

Frame:
    PROBE_POLL               ; cart only: START returns to the menu
    ld c, LOW(rLCDC)
    ANCHOR 0
    ; ---- half A: one wake, on the LY 153 -> 0 snapback, then straight line.
    NOPS LEAD
FOR k, 0, HALFLINE
    SLOT_PARAMS k
    ; ---- line {d:k}
    NOPS BASE + soff
    ld a, tv                 ; 2 M
    ldh [c], a               ; 2 M -- the store under test
    NOPS GAP
    ld a, LCDC_REST          ; 2 M
    ldh [c], a               ; 2 M -- restore, in mode 0
    IF k == HALFLINE - 1
        ; The last half-A slot hands over: arm line HALFLINE and halt there.
        ARM_NEXT HALFLINE
    ELSE
        NOPS 114 - (BASE + soff + GAP + 8)
    ENDC
ENDR
    ; ---- half B: woken on line HALFLINE, and on every line after it.
FOR k, HALFLINE, 144
    SLOT_PARAMS k
    ; ---- line {d:k}, entered from its own LYC wake
    NOPS BASE_B + soff
    ld a, tv                 ; 2 M
    ldh [c], a               ; 2 M -- the store under test
    NOPS GAP
    ld a, LCDC_REST          ; 2 M
    ldh [c], a               ; 2 M -- restore, in mode 0
    IF k == BAND0 + BANDS * BANDLINES - 1
        ; Last measured line: hand back to the snapback anchor. Lines
        ; 136..143 (the label row) are drawn with the CPU halted.
        jp Frame
    ELSE
        ARM_NEXT (k + 1)
    ENDC
ENDR
    jp Frame
