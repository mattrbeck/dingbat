; probe_k_lcdon -- the 2-dot CPU<->PPU grid residual after an LCD enable:
; do line 0, line 1 and the steady state put the mode 3 -> 0 edge at the same
; place?  docs/hwprobe-questions.md row 10.
;
; gb.nim: "Dots the first and second line after an LCD enable are short of
; 456. Both ship 0 ... Three families want the mode 3 -> 0 edge two dots
; earlier and each carrier is refused by a fourth: GBMicrotest `int_hblank_*`
; (line 0) say 0, `hblank_int_scx*` (line 1) say -2, the boot-hand-off rows
; say -2, gambatte `enable_display` (later lines/frames) says 0.
; `LINE0_TRIM=2, LINE1_TRIM=-2` is the closest fit and is not shipped because
; nothing derives it." Row 10 asks for exactly this page.
;
; WHY NOT THE PIXEL VERSION. A mid-line store's boundary column would be the
; natural instrument, but line 0 and line 1 exist ONCE per LCD enable and an
; enable restarts the frame, so a pixel band on line 0 can only ever be one
; pixel tall -- not photographable. The measurement is therefore numeric:
; count from the enable to the M-cycle at which STAT first reads mode 0 on the
; line under test, which is the same edge GBMicrotest's `hblank_int_scx0..7`
; and `int_hblank_*` measure, and paint the answer as a 4x8 block of squares.
; Nothing is left to a one-pixel reading.
;
; ONE CASE = (L, n, s):
;
;   L in {0, 1, 40}   the line under test: the enable's own line, the one
;                     after it, and the steady state
;   n in 0..3         extra M-cycles before the STAT read: the 4-dot axis
;   s in 0..7         SCX & 7, which lengthens mode 3 by s dots: the 1-dot
;                     axis. This is what turns an M-cycle instrument into a
;                     dot instrument, and it is why the answer is a STAIRCASE
;                     and not a number.
;
;     ldh a, [rLY] / cp 145 / jr nz      ; the LCD is turned off IN VBLANK only
;     xor a / ldh [rLCDC], a
;     ld a, s / ldh [rSCX], a
;     ld hl, SledEnd - n                 ; n at no run-time cost
;     ld a, $91 / ldh [rLCDC], a         ; <- THE ENABLE. Everything is counted
;     WAITM (DBASE + 114 * L)            ;    from the end of this store.
;     jp hl / <n nops>
;     ldh a, [rSTAT] / and 3             ; 1 iff mode 0
;
; WAITM emits an exact M-cycle delay (a 7-M-per-iteration 16-bit loop plus a
; remainder of nops), so the read lands DBASE + 114*L + n + 3 M-cycles after
; the enable whatever L is: 114 M is one line, so the three L values are the
; SAME dot of three different lines. With DBASE = 59 the read is at line dot
; 248 + 4n and the mode 3 -> 0 edge is at 252 + s, so the block's black/white
; boundary crosses n = 1..3 as s walks 0..7.
;
; THE PICTURE. Three blocks of 4 rows (n = 0..3, top to bottom) by 8 columns
; (s = 0..7, left to right), at screen rows 1..4, 6..9 and 11..14, columns
; 6..13. A cell is BLACK when STAT already read mode 0, WHITE when mode 3 was
; still running. Each block's top-left corner carries L in hex (00, 01, 28).
; Row 0 is the column ruler and row 17 the label:
;
;     55 01 DD NN AA HH   page code, version, DBASE, NMAX, the boot value of
;                         A ($01 DMG, $FF MGB, $11 CGB/AGB), the CGB flag.
;
; READING. In each block the boundary is a staircase falling one row per four
; columns. Read, for the same n, the FIRST s at which the cell turns black:
; call it s*(L, n). Then
;
;     s*(0, n) - s*(40, n)   is line 0's edge in DOTS relative to the steady
;                            state, and likewise for line 1.
;
; dingbat ships LCD_ON_LINE0_TRIM = LCD_ON_LINE1_TRIM = 0 and still does NOT
; predict three identical blocks: on every model it puts
;
;     block 00  n=1 row  ##......      block 01 and block 28  n=1 row  ####....
;               n=2 row  ######..                             n=2 row  ########
;
; i.e. LINE 0's mode 3 ends TWO DOTS LATER than lines 1 and 40, out of the
; first_line handling alone, while line 1 and the steady state agree exactly.
; The two open readings are therefore:
;
;   block 00 == block 28  -> dingbat's line-0 handling is two dots long
;   block 01 != block 28  -> line 1 has a residual of its own, which is what
;                            GBMicrotest `hblank_int_scx*` and the boot
;                            hand-off want and gambatte `enable_display`
;                            refuses; the column difference IS the trim
;
; Verified to discriminate: rebuilding dingbat with
; `-d:LCD_ON_LINE0_TRIM=2 -d:LCD_ON_LINE1_TRIM=-2` moves block 01 by two
; columns and leaves blocks 00 and 28 where they are.
;
; The measurement turns the LCD off 96 times, always at LY = 145 (Pan Docs:
; never outside VBlank), and takes about 96 frames; the page then draws itself
; once and idles. No MBC, no cartridge line, no save chip: every number is
; silicon, not the flashcart's FPGA.
;
; dingbat's prediction: tools/gbprobe/expected/probe_k_lcdon.<model>.png.

INCLUDE "hw.inc"

DEF VERSION  EQU $01
DEF PAGECODE EQU $55

IF !DEF(DBASE)
DEF DBASE EQU 58             ; M-cycles from the enable to the sled
ENDC
DEF NMAX   EQU 4             ; n = 0 .. NMAX-1
DEF SMAX   EQU 8             ; s = 0 .. SMAX-1
DEF LINES  EQU 3
DEF BLKCOL EQU 6             ; the blocks' first screen column

DEF T_CELL   EQU $01         ; solid black
DEF T_CORNER EQU $06

; WAITM t -- burn exactly t M-cycles. Clobbers A and DE.
;   ld de, k        3 M
;   dec de/ld a,d/or e/jr nz    7 M per iteration, 6 on the last
;   => 7k + 2, plus the remainder as nops
MACRO WAITM
    IF (\1) < 10
        NOPS (\1)
    ELSE
        DEF wk = ((\1) - 2) / 7
        ld de, wk
.wl\@:
        dec de
        ld a, d
        or e
        jr nz, .wl\@
        NOPS (\1) - (7 * wk + 2)
    ENDC
ENDM

    PROBE_HEADER

    PROBE_HRAM

    PROBE_WRAM $C000
wRes: ds LINES * NMAX * SMAX  ; 1 = STAT read mode 0, 0 = mode 3 still running
wL:   db
wN:   db
wS:   db
wTmp: db

    PROBE_MAIN

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a
    call InitVideo
    call LcdOnText           ; the sweep's first case needs an LCD to turn off

    ; ---- the sweep: 3 * 4 * 8 = 96 cases, one VBlank apart
    xor a
    ld [wL], a
.lloop:
    xor a
    ld [wN], a
.nloop:
    xor a
    ld [wS], a
.sloop:
    ld a, [wN]
    ld b, a
    ld a, [wS]
    ld c, a
    ld a, [wL]
    or a
    jr nz, .try1
    call MeasureL0
    jr .got
.try1:
    dec a
    jr nz, .try40
    call MeasureL1
    jr .got
.try40:
    call MeasureL40
.got:
    ; A = STAT & 3; the cell is 1 when the line has already reached mode 0
    or a
    ld a, 0
    jr nz, .store
    inc a
.store:
    ld [wTmp], a
    ld a, [wL]
    add a, a
    add a, a
    add a, a
    add a, a
    add a, a                 ; 32 * L
    ld b, a
    ld a, [wN]
    add a, a
    add a, a
    add a, a                 ; 8 * n
    add b
    ld b, a
    ld a, [wS]
    add b                    ; the index, always below 96
    ld l, a
    ld h, 0
    ld bc, wRes
    add hl, bc
    ld a, [wTmp]
    ld [hl], a

    ld hl, wS
    inc [hl]
    ld a, [hl]
    cp SMAX
    jr nz, .sloop
    ld hl, wN
    inc [hl]
    ld a, [hl]
    cp NMAX
    jr nz, .nloop
    ld hl, wL
    inc [hl]
    ld a, [hl]
    cp LINES
    jr nz, .lloop

    ; ---- draw
    call LcdOff
    xor a                    ; the last case left SCX at 7: unscroll the page
    ldh [rSCX], a
    ldh [rSCY], a
    ld hl, $8000 + T_CELL * 16
    ld b, 16
.cell:
    ld a, $FF
    ld [hl+], a
    dec b
    jr nz, .cell
    ld hl, $8000 + T_CORNER * 16
    ld de, CornerTile
    ld b, 16
.corner:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .corner

    ; clear the map, then the ruler, the label and the three blocks
    ld hl, _SCRN0
    ld bc, 32 * 32
    xor a
.clrmap:
    ld [hl+], a
    dec bc
    ld a, b
    or c
    xor a
    jr nz, .clrmap

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
    ld a, DBASE
    call PutByte
    ld e, 10
    ld a, NMAX
    call PutByte
    ld e, 13
    ldh a, [hIsCgb]
    call PutByte
    ld e, 16
    ld a, [$0143]
    and $C0
    call PutByte

    ; the three blocks
    xor a
    ld [wL], a
.blk:
    xor a
    ld [wN], a
.blkn:
    xor a
    ld [wS], a
.blks:
    ; index = 32*L + 8*n + s
    ld a, [wL]
    add a, a
    add a, a
    add a, a
    add a, a
    add a, a
    ld b, a
    ld a, [wN]
    add a, a
    add a, a
    add a, a
    add b
    ld b, a
    ld a, [wS]
    add b
    ld l, a
    ld h, 0
    ld bc, wRes
    add hl, bc
    ld a, [hl]
    or a
    ld a, 0
    jr z, .white
    ld a, T_CELL
.white:
    ld c, a                  ; C = the tile
    ; row = 1 + 5*L + n, column = BLKCOL + s
    ld a, [wL]
    ld b, a
    add a, a
    add a, a
    add b                    ; 5*L
    inc a
    ld b, a
    ld a, [wN]
    add b
    ld d, a
    ld a, [wS]
    add BLKCOL
    ld e, a
    ld a, c
    call PutTile
    ld hl, wS
    inc [hl]
    ld a, [hl]
    cp SMAX
    jr nz, .blks
    ld hl, wN
    inc [hl]
    ld a, [hl]
    cp NMAX
    jr nz, .blkn
    ld hl, wL
    inc [hl]
    ld a, [hl]
    cp LINES
    jr nz, .blk

    ; each block's L in hex at its top-left
    ld d, 1
    ld e, 1
    xor a
    call PutByte
    ld d, 6
    ld e, 1
    ld a, 1
    call PutByte
    ld d, 11
    ld e, 1
    ld a, 40
    call PutByte

    call LcdOnText
    IDLE_FOREVER

; ---------------------------------------------------------------------------
; PutTile -- write tile A at (E, D). LCD must be off.
PutTile:
    ld b, a
    push bc
    call MapAddr
    pop bc
    ld [hl], b
    ret

; ---------------------------------------------------------------------------
; VblankLcdOff -- wait for LY = 145 and stop the LCD there. Clobbers A only,
; so a caller can hold its parameters in BC.
VblankLcdOff:
.wait:
    ldh a, [rLY]
    cp 145
    jr nz, .wait
    xor a
    ldh [rLCDC], a
    ret

; ---------------------------------------------------------------------------
; MeasureL0 / MeasureL1 / MeasureL40 -- B = n, C = s. Return A = STAT & 3,
; sampled DBASE + 114*L + n + 3 M-cycles after the LCD enable.
MeasureL0:
    call VblankLcdOff
    ld a, c
    ldh [rSCX], a
    ld hl, SledEnd
    ld a, l
    sub b
    ld l, a
    ld a, h
    sbc 0
    ld h, a
    ld a, LCDC_MEASURE
    ldh [rLCDC], a           ; <- the enable
    WAITM DBASE
    jp hl

MeasureL1:
    call VblankLcdOff
    ld a, c
    ldh [rSCX], a
    ld hl, SledEnd
    ld a, l
    sub b
    ld l, a
    ld a, h
    sbc 0
    ld h, a
    ld a, LCDC_MEASURE
    ldh [rLCDC], a
    WAITM DBASE + 114
    jp hl

MeasureL40:
    call VblankLcdOff
    ld a, c
    ldh [rSCX], a
    ld hl, SledEnd
    ld a, l
    sub b
    ld l, a
    ld a, h
    sbc 0
    ld h, a
    ld a, LCDC_MEASURE
    ldh [rLCDC], a
    WAITM DBASE + 114 * 40
    jp hl

Sled:
    NOPS NMAX - 1
SledEnd:
    ldh a, [rSTAT]
    and 3
    ret

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
