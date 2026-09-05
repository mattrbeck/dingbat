; probe_k_winglitch -- the window insertion glitch (Pan Docs "Window", the
; Star Trek 25th Anniversary glitch): docs/hwprobe-questions.md row 18.
;
; When the WX comparator matches on a line with LCDC.5 LOW, dingbat puts one
; colour-0 pixel on the front of the BG FIFO (gb.nim WIN_EN_HOLD_ZERO = 1),
; overwriting the pixel that was there. Row 18's four open axes:
;
;   (a) the ARMING condition -- full activation, a WY match seen while LCDC.5
;       was set, or Pan Docs' enable-free Y condition (LY >= WY alone, which
;       silicon already refutes: Pokemon Blue rests at WX = 7 / WY = 0 with
;       the window off and draws no white column)
;   (b) INSERT (the rest of the line delayed a dot -- nitro2k01) vs REPLACE
;       (mealybug reads back unshifted either side; dingbat replaces)
;   (c) does a CGB glitch at all
;   (d) WX = 7 on the line's first push with the latch armed, and the phase
;       rule (WX & 7) == 7 - (SCX & 7); no ROM pins that phase
;
; ARM (mk.sh probe_k_winglitch -DARM=n) picks the arming regime, one ROM each,
; because `window_trigger` is a PER-FRAME latch cleared in VBlank: the three
; regimes cannot share a frame, so they share a source instead.
;
;   ARM = 0  WY = 0 and LCDC.5 is NEVER set in the frame. LY >= WY holds on
;            every measured line, so Pan Docs' enable-free Y condition is TRUE
;            and dingbat's is FALSE. A glitch here refutes dingbat's gate --
;            and would then have to be reconciled with Pokemon Blue.
;   ARM = 1  WY = 4; LCDC.5 is set for lines 3..5 with WX = 200, so the WY
;            match at line 4's mode 2 is seen with the window enabled but the
;            window NEVER STARTS. Then LCDC.5 goes low for the rest of the
;            frame. This is dingbat's own gate and nothing more.
;   ARM = 2  as ARM = 1 but WX = 87 on line 4, so the window really draws once
;            (full activation) before LCDC.5 goes low.
;
;   glitch on 1 and 2, none on 0  -> dingbat's gate is right
;   glitch on 2 only              -> the latch needs FULL ACTIVATION
;   glitch on 0 as well           -> Pan Docs' Y-only condition
;   no glitch anywhere            -> WIN_EN_HOLD_ZERO is not a hardware effect
;
; AXIS picks what the sixteen bands sweep:
;
;   AXIS = 0  SCX = 0 throughout; band b sets WX = WXG0 + b, so the bands walk
;             the match through two full mod-8 phases. Axis (d)'s WX half.
;   AXIS = 1  bands 0..7 set SCX = b and WX = WXG0 + b (the difference
;             WX - SCX held constant); bands 8..15 set SCX = b & 7 and
;             WX = WXG0 (WX held). If the glitch follows the first group the
;             phase rule is on (WX - SCX); if it follows the second it is on
;             WX alone. Axis (d)'s SCX half.
;
; NO DOT PRECISION IS NEEDED and none is used. Every line is entered from its
; own LYC = LY halt and sets SCX and WX inside mode 2, ten M-cycles from the
; wake, forty dots before mode 3 starts; the match then happens wherever the
; comparator says it does. So the page is free of the halt-wake anchor, of
; every register latency, and of the assembler timing that probe (h) and
; probe (j) live on. What it costs is that the page cannot see WHEN the match
; is refused, only THAT it was.
;
; THE PICTURE. Rows 1..16 are sixteen bands of eight lines, band b at lines
; 8 + 8b. The background is a 4-black / 4-white vertical stripe, every tile
; the same, so a one-pixel shift shows as a jag at every stripe edge across
; 160 pixels. In each band:
;
;     TOP four lines     WX = the band's test value  (the glitch line)
;     BOTTOM four lines  WX = 200, which never matches (the control line)
;
; so the answer to axis (b) is the shape of the stripe edges at the band's
; midline:
;
;     edges flush, one white pixel added on the top half   -> REPLACE
;     edges step one pixel right on the top half           -> INSERT
;     top and bottom identical                             -> no glitch
;
; Row 0 is the column ruler (the digit is the tile column) and row 17 the
; label:  53/54 01 AA GG BB HH -- page code ($53 for AXIS 0, $54 for AXIS 1),
; version, ARM, WXG0, the boot value of A ($01 DMG, $FF MGB, $11 CGB/AGB) and
; the cartridge's CGB flag. Lines 0..7 and 136..143 are drawn with SCX = 0 and
; WX = 200 so the ruler and the label are never scrolled or glitched.
;
; dingbat's prediction: no glitch on ANY CGB revision (CGB_WIN_EN_HOLD = 0, so
; a refused match is dropped outright and never reaches WIN_EN_HOLD_ZERO), and
; on a DMG a replace -- see tools/gbprobe/expected/probe_k_winglitch*.
;
; NOTE ON THE FLASHCART: nothing here touches an MBC, a cartridge line or a
; save chip, so every pixel is silicon, not the cart's FPGA.

INCLUDE "hw.inc"

DEF VERSION EQU $01

IF !DEF(ARM)
DEF ARM EQU 1
ENDC
IF !DEF(AXIS)
DEF AXIS EQU 0
ENDC
IF !DEF(WXG0)
DEF WXG0 EQU 39              ; band 0's WX: the match is at x = 32
ENDC
DEF PAGECODE EQU $53 + AXIS

DEF BAND0     EQU 8
DEF BANDS     EQU 16
DEF BANDLINES EQU 8
DEF WXFAR     EQU 200        ; a WX that never matches
DEF ARMLINE   EQU 4          ; the line the WY match is taken on (ARM 1, 2)
DEF ARMWX     EQU 87         ; ARM = 2: the window really draws, from x = 80

DEF T_STRIPE EQU $01         ; 4 black then 4 white, every row
DEF T_CORNER EQU $06

DEF LCDC_BASE EQU LCDC_MEASURE                  ; $91: BG only, $8000, $9800
DEF LCDC_WIN  EQU LCDC_BASE | LCDCF_WINON | LCDCF_WIN9C

    PROBE_HEADER

    PROBE_HRAM

    PROBE_MAIN

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a
    call InitVideo

    ; ---- tiles
    ld hl, $8000 + T_STRIPE * 16
    ld b, 8
.stripe:
    ld a, $F0                ; both planes set for pixels 0..3: colour 3
    ld [hl+], a
    ld a, $F0
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

    ; ---- map: rows 1..16, all 32 columns, are the stripe.
    ld hl, _SCRN0 + 32
    ld bc, 16 * 32
.bg:
    ld a, T_STRIPE
    ld [hl+], a
    dec bc
    ld a, b
    or c
    jr nz, .bg
    ; The window map ($9C00) is only ever seen on ARM = 2's single window
    ; line; leave it as InitVideo's blank so that line reads white.

    ; ---- row 0: corners and the ruler; row 17: corners and the label.
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
    ld a, ARM
    call PutByte
    ld e, 10
    ld a, WXG0
    call PutByte
    ld e, 13
    ldh a, [hIsCgb]
    call PutByte
    ld e, 16
    ld a, [$0143]
    and $C0
    call PutByte

    xor a
    ldh [rSCX], a
    ldh [rSCY], a
IF ARM == 0
    xor a                    ; WY = 0: LY >= WY on every measured line
ELSE
    ld a, ARMLINE
ENDC
    ldh [rWY], a
    ld a, WXFAR
    ldh [rWX], a
    ld a, LCDC_BASE
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

; LINE_PARAMS k -- line k's registers, as assembler variables. All of them are
; stored inside mode 2, so only their VALUES matter, never their dot.
;   wxv     WX for this line     scxv   SCX for this line
;   lcdcv   LCDC, or -1 for "leave it alone"
MACRO LINE_PARAMS
    DEF wxv   = WXFAR
    DEF scxv  = 0
    DEF lcdcv = -1
    ; The arming window: LCDC.5 up for lines ARMLINE-1 .. ARMLINE, down after.
IF ARM != 0
    IF (\1) == ARMLINE - 1
        DEF lcdcv = LCDC_WIN
    ENDC
    IF (\1) == ARMLINE
        IF ARM == 2
            DEF wxv = ARMWX      ; the window really draws this one line
        ENDC
    ENDC
    IF (\1) == ARMLINE + 1
        DEF lcdcv = LCDC_BASE    ; and LCDC.5 is low for every measured line
    ENDC
ENDC
    IF (\1) >= BAND0 && (\1) < BAND0 + BANDS * BANDLINES
        DEF bnd = ((\1) - BAND0) / BANDLINES
        ; the top half of a band is the glitch line, the bottom half the control
        IF (((\1) - BAND0) % BANDLINES) < BANDLINES / 2
IF AXIS == 0
            DEF wxv  = WXG0 + bnd
ELSE
            IF bnd < 8
                DEF wxv  = WXG0 + bnd
            ELSE
                DEF wxv  = WXG0
            ENDC
ENDC
        ENDC
IF AXIS == 1
        DEF scxv = bnd & 7
ENDC
    ENDC
ENDM

; ARM_NEXT line -- point the LYC source at `line` and halt. LY is still
; line-1, so writing LYC cannot make an edge of its own.
MACRO ARM_NEXT
    ld a, \1                 ; 2 M
    ldh [rLYC], a            ; 3 M
    xor a                    ; 1 M
    ldh [rIF], a             ; 3 M
    halt                     ; 1 M, then the wait
ENDM

Frame:
    PROBE_POLL               ; cart only: START returns to the menu
    ANCHOR 1
FOR k, 1, 144
    LINE_PARAMS k
    ; ---- line {d:k}: woken at its own LY, still forty-odd dots inside mode 2
    IF lcdcv >= 0
    ld a, lcdcv              ; 2 M
    ldh [rLCDC], a           ; 3 M
    ENDC
    ld a, scxv               ; 2 M
    ldh [rSCX], a            ; 3 M
    ld a, wxv                ; 2 M
    ldh [rWX], a             ; 3 M
    IF k == 143
    jp Frame                 ; ANCHOR 1 rearms for the next frame
    ELSE
    ARM_NEXT (k + 1)
    ENDC
ENDR
    jp Frame
