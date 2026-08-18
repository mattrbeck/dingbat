; probe_e_objgrid -- what does an object at a small X do to the FETCH GRID?
;
; THE QUESTION. probe (d) settled, on silicon, that dingbat's LCDC.4 latency
; and fetch-grid phase are right on a line with nothing on it: every
; fine-scroll residue 0-7, CGB and DMG-compat, all read #2#2#2#2#2#2#2#2.
; `cgb-acid-hell`'s two disputed pixels therefore do not come from either.
; What its line 68 has and probe (d)'s lines do not is an OBJECT AT OAM X = 1,
; triggering at dot 90 -- inside the fine-scroll discard, before the first
; pixel is emitted.
;
; That is exactly where Pan Docs contradicts itself. `Rendering.md`: an object
; at X = 0 "always incurs an 11-dot penalty, regardless of SCX".
; `pixel_fifo.md`: when SCX & 7 > 0 the penalty is "whatever the lower 3 bits
; of SCX are". dingbat implements the flat 11 and applies it at X = 0 exactly,
; because its evidence -- GBMicrotest `ppu_spritex_vs_scx`, 153/153 cells --
; only ever places the object at 0. acid-hell's object is at 1, and every
; X in 1..7 also triggers left of the first on-screen pixel.
;
; HOW IT MEASURES. probe (d)'s bar, with objects added ahead of it. The bar's
; COLUMN is the readout, not just its shade: an object that stalls the fetcher
; for N dots pushes every later fetch N dots later, so the bar moves N pixels
; right of where the same build puts it with objects off. Sweep the object's X
; and the bar's column traces the penalty function directly -- and the X = OFF
; setting is the baseline, which is probe (d) exactly.
;
; Eight 8x16 objects at Y = 32, 48, ... 144 put one object -- and only one --
; on every measured line, all at the same X. Their tile is blank, so they
; cost their fetch without drawing anything: the penalty is the whole effect.
; At every X this probe offers (0..15) the object's own pixels are left of
; column 8, far from the bar.
;
; ONE ROM, PAGED. Everything that was a separate build of probe (d) is a
; runtime parameter here, because a flash cart's boot cycle is the slowest
; part of a hardware session:
;
;   LEFT / RIGHT   SCX 0..7          (the fine-scroll residue)
;   UP / DOWN      object X: OFF, then 0..15
;
; The current setting is printed at the top of the screen as two hex bytes --
; SCX, then the object X ($FF = objects off) -- so a photograph is
; self-describing and cannot be filed under the wrong setting.
;
; READING IT. Fourteen bands below the header, each eight identical scanlines
; plus a blank separator, exactly as probe (d): the shade says which bitplane
; the LCDC.4 write reached, and the column says where the fetch grid was.
; Photograph one frame per setting; `tools/gbprobe/read_probe_d_photo.py`
; reads both out.

INCLUDE "hw.inc"

DEF HEADER_LINES EQU 16          ; two tile rows for the parameter readout

; Which line the halt anchor parks on. 16 is the shipping value (the bands
; start below the header). ANCHOR_LINE=0 exists to separate two things probe
; (d) and probe (e) confounded: probe (d) anchors on LINE 0, which dingbat
; special-cases (LY0_PIPE_MCYCLES, the 153->0 snapback, first_line), and its
; columns matched hardware exactly; probe (e) anchors on a normal line and its
; baseline sits 8 dots off. If dingbat's own column moves between the two
; anchors, the difference lives in the wake, not in the object path.
IF !DEF(ANCHOR_LINE)
DEF ANCHOR_LINE EQU HEADER_LINES
ENDC
DEF BANDS        EQU 14          ; 14 * 9 = 126 lines, ending at 141
DEF BANDLINES    EQU 8

; Same line arithmetic as probe (d), and it has to hold exactly or the bands
; stop meaning one offset each: a line is 114 M-cycles, the body spends
; BASE+k + 2 + 2 + TAIL-k + 1 + 4, so BASE + TAIL = 105 whatever k is. PAD is
; the band's ninth line: leaving the loop costs 1 M less than going round it
; and the next counter costs 2, so 7*114 + 113 + 2 + PAD = 9*114.
IF !DEF(BASE)
DEF BASE EQU 26
ENDC
DEF TAIL EQU 105 - BASE
DEF PAD  EQU 113

DEF OBJ_OFF EQU $FF

; Runtime paging is for the hardware session; these are for generating
; dingbat's predictions, one build per setting, since the screenshot harness
; has no way to press a button.
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

    ; Bring the LCD up once, here. ApplyParams runs in VBlank from now on and
    ; never touches LCDC.7: toggling the LCD off and on per frame would reset
    ; the PPU every frame, and a frame grabbed during the off period is blank
    ; -- which is exactly what the first cut of this ROM produced.
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJ16
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
    ANCHOR ANCHOR_LINE           ; park on the first line below the header

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
    ld b, a
    ld a, [wObjX]
    cp OBJ_OFF
    jr z, .noObj
    ld a, b
    or LCDCF_OBJON
    ld b, a
.noObj:
    ld a, b
    ld [wLcdcA], a               ; BG at $8800
    or LCDCF_BG8000
    ld [wLcdcB], a               ; BG at $8000 -- the resting value

    ; Header: the two parameters as hex, so the photo names its own setting.
    ; NOHEADER builds omit it, so a band can be anchored on line 0 without the
    ; glyphs sitting on top of it (used to separate the wake from the object
    ; path -- see ANCHOR_LINE).
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
