; probe_e_objgrid -- what does an object at a small X do to the fetch grid?
;
; An object at OAM X = 1 triggers at dot 90, inside the fine-scroll discard,
; before the first pixel is emitted. Pan Docs disagrees with itself there:
; Rendering.md says an object at X = 0 "always incurs an 11-dot penalty,
; regardless of SCX"; pixel_fifo.md says when SCX & 7 > 0 the penalty is
; "whatever the lower 3 bits of SCX are". GBMicrotest ppu_spritex_vs_scx only
; ever places the object at X = 0.
;
; HOW IT MEASURES. probe (d)'s bar, with objects added ahead of it. The bar's
; COLUMN is a readout as well as its shade: an object that stalls the fetcher
; N dots pushes every later fetch N dots later, so the bar moves N pixels
; right of where the same build puts it with objects off. Sweep the object's
; X and the bar's column traces the penalty function; X = OFF is the baseline
; and is probe (d) exactly.
;
; Eight 8x16 objects at Y = 32, 48, ... 144 put exactly one object on every
; measured line, all at the same X. Their tile is blank, so they cost their
; fetch and draw nothing. At every X offered (0..15) the object's own pixels
; are left of column 8, far from the bar.
;
; ONE ROM, PAGED (a flash cart's boot cycle is the slow part of a session):
;
;   LEFT / RIGHT   SCX 0..7          (the fine-scroll residue)
;   UP / DOWN      object X: OFF, then 0..15
;
; The current setting is printed at the top of the screen as two hex bytes --
; SCX, then the object X ($FF = objects off) -- so a photograph names its own
; setting.
;
; READING IT. Fourteen bands below the header, each eight identical scanlines
; plus a blank separator, as in probe (d): the shade says which bitplane the
; LCDC.4 write reached, the column says where the fetch grid was. One frame
; per setting; tools/gbprobe/read_probe_d_photo.py reads both out.

INCLUDE "hw.inc"

DEF HEADER_LINES EQU 16          ; two tile rows for the parameter readout

; Which line the halt anchor parks on. 16 ships (the bands start below the
; header). ANCHOR_LINE=0 anchors on line 0 as probe (d) does, which is the
; LY 153 -> 0 snapback wake, to separate the wake from the object path.
IF !DEF(ANCHOR_LINE)
DEF ANCHOR_LINE EQU HEADER_LINES
ENDC
DEF BANDS        EQU 14          ; 14 * 9 = 126 lines, ending at 141
DEF BANDLINES    EQU 8

; Same line arithmetic as probe (d): a line is 114 M-cycles, the body spends
; BASE+k + 2 + 2 + TAIL-k + 1 + 4, so BASE + TAIL = 105 whatever k is. PAD is
; the band's ninth line: leaving the loop costs 1 M less than going round it
; and the next counter costs 2, so 7*114 + 113 + 2 + PAD = 9*114.
IF !DEF(BASE)
DEF BASE EQU 26
ENDC
DEF TAIL EQU 105 - BASE
DEF PAD  EQU 113

DEF OBJ_OFF EQU $FF

; Build-time defaults, one build per setting, for the screenshot harness,
; which cannot press a button.
IF !DEF(SCX_DEFAULT)
DEF SCX_DEFAULT EQU 0
ENDC
IF !DEF(OBJX_DEFAULT)
DEF OBJX_DEFAULT EQU OBJ_OFF
ENDC

SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "hram", HRAM
hIsCgb: db

SECTION "wram", WRAM0
wScx:   db
wObjX:  db                       ; $FF = objects off
wHeld:  db                       ; joypad, previous frame (edge detection)
wLcdcA: db                       ; LCDC with BG at $8800  (the pulse's low)
wLcdcB: db                       ; LCDC with BG at $8000  (its resting value)

SECTION "main", ROM0[$150]

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a
    call InitVideo               ; LCD off, VRAM cleared, font loaded

    ; Tile $01 is index 0 in $8000 mode (VRAM is already clear) and index 3 in
    ; $8800 mode, where it is signed +1 at $9010. A fetch that takes one plane
    ; from each addressing mode lands on index 1 or 2, which is the reading.
    ld hl, $9010
    ld b, 16
    ld a, $FF
.glyph:
    ld [hl+], a
    dec b
    jr nz, .glyph

    ; Background: tile $01 everywhere. The header's own glyphs are written
    ; over the top two rows every frame, in VBlank.
    ld hl, _SCRN0
    ld de, 32 * 32
    ld a, $01
.map:
    ld [hl+], a
    dec de
    ld a, d
    or e
    ld a, $01
    jr nz, .map

    ; Eight 8x16 objects, one per sixteen scanlines, covering every measured
    ; line. X is filled in per frame. Tile 0 is blank, so they cost their
    ; fetch and draw nothing.
    ld hl, $FE00
    ld b, 8
IF DEF(PARK_OAM)
    ld c, 0                      ; every Y off-screen: nothing to select at all
ELSE
    ld c, 32                     ; first Y: screen line 16
ENDC
.oam:
    ld a, c
    ld [hl+], a                  ; Y
    xor a
    ld [hl+], a                  ; X (set per frame)
    ld [hl+], a                  ; tile 0
    ld [hl+], a                  ; attributes
    ld a, c
    add 16
    ld c, a
    dec b
    jr nz, .oam
    ; The other 32 entries are off-screen: OAM is not cleared by InitVideo, so
    ; say so rather than trust it.
    ld b, 32
.oamClear:
    xor a
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    dec b
    jr nz, .oamClear

    xor a
    ldh [rSCY], a
    ld [wHeld], a
    ld a, SCX_DEFAULT
    ld [wScx], a
    ld a, OBJX_DEFAULT
    ld [wObjX], a
    ld a, %11100100              ; identity palette: index IS shade
    ldh [rBGP], a
    ldh [rOBP0], a

    ; The window, for the acid-hell corner. WIN_LIVE has the window live
    ; part-way across the line while the LCDC pulses run (acid-hell's ly 68
    ; shape). WIN_PULSE puts window-enable into the pulse itself, so LCDC.4
    ; and LCDC.5 change on one dot, which acid-hell does and mealybug never
    ; does (m3_lcdc_tile_sel_change, m3_lcdc_tile_sel_win_change move them
    ; separately). The two builds differ only in whether bit 5 rides the
    ; pulse, so whatever the anchor contributes is common to both.
IF DEF(WIN_LIVE) || DEF(WIN_PULSE)
    ; x = 8, left of every band's bar, so each bar is measured inside the
    ; window rather than across its edge (acid-hell's pixel is at x = 80 with
    ; the window live from x = 26).
    ld a, 8 + 7                  ; window's leftmost pixel at x = 8
    ldh [rWX], a
    xor a
    ldh [rWY], a                 ; live from the top of the frame
ENDC

    ; Bring the LCD up once, here. ApplyParams runs in VBlank from now on and
    ; never touches LCDC.7: toggling the LCD per frame resets the PPU, and a
    ; frame grabbed during the off period is blank.
IF DEF(WIN_LIVE) || DEF(WIN_PULSE)
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJ16 | LCDCF_WINON
ELSE
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJ16
ENDC
    ld [wLcdcA], a
    or LCDCF_BG8000
    ld [wLcdcB], a
    ldh [rLCDC], a

; ---------------------------------------------------------------- frame -----
Frame:
    call ApplyParams             ; runs in VBlank; never touches LCDC.7

    ld hl, rLCDC
    ld a, [wLcdcA]
    ld d, a
    ld a, [wLcdcB]
    ld e, a
IF DEF(ANCHOR_POLL)
    ; The same line, reached without the halt: separates a time offset in the
    ; STAT-LYC halt's wake from one in the pixel pipeline. The poll's exit
    ; phase differs from the halt's, so the bar's absolute column moves, but
    ; it moves the same way for every machine running this build. Two stages
    ; so the wait always crosses a line boundary.
.pollPrev:
    ldh a, [rLY]
    cp ANCHOR_LINE - 1
    jr nz, .pollPrev
.pollHit:
    ldh a, [rLY]
    cp ANCHOR_LINE
    jr nz, .pollHit
ELSE
    ANCHOR ANCHOR_LINE           ; park on the first line below the header
ENDC

    ld b, BANDLINES
FOR K, BANDS
.band{d:K}:
    NOPS (BASE + K)
    ld [hl], d                   ; 2 M -- LCDC.4 LOW: the write under test
    ld [hl], e                   ; 2 M -- and high again, eight dots later
    NOPS (TAIL - K)
    dec b                        ; 1 M
    jp nz, .band{d:K}            ; 4 M taken / 3 M not
    ld b, BANDLINES              ; 2 M -- for the next band
    NOPS PAD                     ; the blank ninth line
ENDR

    call ReadPad
    jp Frame                     ; jp, not jr: the unrolled bands are 3 KB

; ---------------------------------------------------------------------------
; ApplyParams -- put the current settings into the hardware and draw the
; header, in VBlank, where OAM and VRAM are both writable and nothing the
; measurement depends on is running.
ApplyParams:
.waitVBlank:
    ldh a, [rLY]
    cp 145
    jr nz, .waitVBlank

    ld a, [wScx]
    and $07
    ldh [rSCX], a

    ; Objects: X into all eight entries, or park them off-screen.
    ld a, [wObjX]
    cp OBJ_OFF
    ld c, a                      ; c = X to write (garbage if OFF; unused)
    jr nz, .objOn
    xor a                        ; X = 0 with OBJ disabled: never fetched
    ld c, a
.objOn:
    ld hl, $FE01
    ld b, 8
.objLoop:
    ld a, c
    ld [hl], a
    ld a, l
    add 4
    ld l, a
    ld a, h
    adc 0
    ld h, a
    dec b
    jr nz, .objLoop

    ; The two LCDC values the pulse toggles between. OBJ enable and 8x16 ride
    ; along, so the pulse never disturbs them.
IF DEF(NO_OBJ16)
    ld a, LCDCF_ON | LCDCF_BGON
ELSE
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJ16
ENDC
IF DEF(WIN_LIVE)
    or LCDCF_WINON               ; window live in BOTH halves of the pulse
ENDC
    ld b, a
    ld a, [wObjX]
    cp OBJ_OFF
    jr z, .noObj
    ld a, b
    or LCDCF_OBJON
    ld b, a
.noObj:
    ld a, b
    ld [wLcdcA], a               ; BG at $8800 (window off too, under WIN_PULSE)
    or LCDCF_BG8000
IF DEF(WIN_PULSE)
    or LCDCF_WINON               ; bit 5 rides the pulse with bit 4
ENDC
    ld [wLcdcB], a               ; the resting value

    ; Header: the two parameters as hex, so the photo names its own setting.
    ; NOHEADER builds omit it, so a band can be anchored on line 0 without the
    ; glyphs on top of it (see ANCHOR_LINE).
IF !DEF(NOHEADER)
    ld d, 0
    ld e, 0
    ld a, [wScx]
    call PutByte
    ld e, 3
    ld a, [wObjX]
    call PutByte
ENDC

    ld a, [wLcdcB]               ; LCDC.7 is already set; this only moves the
    ldh [rLCDC], a               ; BG/OBJ bits to match the new setting
    ret

; ---------------------------------------------------------------------------
; ReadPad -- one step per press, not per frame held.
ReadPad:
    ld a, $20                    ; select the direction keys
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]                 ; the documented settling read
    cpl
    and $0F                      ; 1 = pressed: right, left, up, down
    ld b, a
    ld a, [wHeld]
    ld c, a
    ld a, b
    ld [wHeld], a
    xor c
    and b                        ; freshly pressed only
    ret z
    ld b, a

    bit 0, b                     ; RIGHT: SCX + 1
    jr z, .noRight
    ld a, [wScx]
    inc a
    and $07
    ld [wScx], a
.noRight:
    bit 1, b                     ; LEFT: SCX - 1
    jr z, .noLeft
    ld a, [wScx]
    dec a
    and $07
    ld [wScx], a
.noLeft:
    bit 2, b                     ; UP: object X forward, OFF -> 0 -> .. -> 15
    jr z, .noUp
    ld a, [wObjX]
    cp OBJ_OFF
    jr nz, .upInc
    xor a
    jr .upStore
.upInc:
    inc a
    cp 16
    jr c, .upStore
    ld a, OBJ_OFF
.upStore:
    ld [wObjX], a
.noUp:
    bit 3, b                     ; DOWN: object X backward
    jr z, .noDown
    ld a, [wObjX]
    cp OBJ_OFF
    jr nz, .downDec
    ld a, 15
    jr .downStore
.downDec:
    or a
    jr z, .downOff
    dec a
    jr .downStore
.downOff:
    ld a, OBJ_OFF
.downStore:
    ld [wObjX], a
.noDown:
    ret

INCLUDE "common.inc"
