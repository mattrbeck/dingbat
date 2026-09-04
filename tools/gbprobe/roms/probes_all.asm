; probes_all -- the eighteen photograph pages on one MBC5 cartridge.
;
; One flash-cart burn instead of eighteen. The launcher owns bank 0: the cart
; header, the menu, and the single copy of common.inc that every page imports
; (each page is assembled with GBPROBE_COMBINED, which strips its own copy and
; moves it off the fixed $150 entry). A page's code sits in bank 0 beside the
; launcher; its unrolled frame, where it has one, gets a switchable bank of its
; own, and the menu selects that bank before it jumps.
;
; The hand-off gives a page exactly what the boot ROM gives it: A = the model
; byte ($01 DMG, $FF MGB, $11 CGB/AGB), the LCD on, interrupts off and nothing
; pending, every register the pages touch back at its power-on value. A holds
; in HRAM at $FF80 -- the byte every page writes as hIsCgb with the same value
; -- so START can hand it straight back on the way out.
;
; The pages are byte-identical in what they render: tools/gbprobe/README.md's
; "One ROM for the flashcart" section, and probes_all_check.sh, hold the diff
; against the standalone renders.
;
; Controls: UP/DOWN move, A runs the page, START (in a page) returns here.
; The one deviation is the BGP page: see the README. A cart has one CGB flag
; and seventeen of the eighteen pages want $80, so this cart carries $80 and
; page 33 runs CGB-native here where its own .gb runs compatibility mode.

INCLUDE "hw.inc"

; ---------------------------------------------------------------------------
; A page's own HRAM is unioned at $FF80 (hIsCgb, then up to eight bytes of DMA
; trampoline), so the menu's state starts clear of it.
DEF HRAM_MENU EQU $FF90

; Tile numbers. InitVideo loads the hex font at FONT_BASE ($10): 0-9 then A-F,
; so the menu's own twenty glyphs (G..Z) carry on from $20, and the cursor
; takes tile $01.
DEF CURSOR_TILE EQU $01
DEF LETTER_BASE EQU $20

DEF TEXTLEN  EQU 18            ; screen columns 2..19
DEF ENTRYLEN EQU 3 + TEXTLEN
DEF ENTRIES  EQU 18

SECTION UNION "probe_hram", HRAM[$FF80]
hIsCgb:: db                    ; the boot A, shared with every page

SECTION "menu_hram", HRAM[HRAM_MENU]
hSel:   db                     ; menu cursor, 0 .. ENTRIES-1
hPad:   db                     ; last frame's buttons, for edge detection

; The RST and interrupt vectors. Nothing here ever runs -- IME is off in the
; menu and in every page -- but the pages' code is floating in ROM0 and this
; keeps it out of the bytes a real cart is expected to have blank.
SECTION "vectors", ROM0[$0000]
    ds $100, $00

SECTION "boot", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "launcher", ROM0[$150]

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a
    xor a
    ldh [hSel], a
    ldh [hPad], a
    jr Menu

; ---------------------------------------------------------------------------
; Relaunch -- where a page's START lands, with A already the boot byte and the
; cursor still where it was. Everything a page can have left behind is put back
; here, not in the page, so the next hand-off is the same as the first.
Relaunch::
    di
    ld sp, $DFFF
    ldh [hIsCgb], a
    ; fall through

Menu:
    call ResetHardware
    call InitVideo             ; LCD off, VRAM cleared, hex font, palettes
    call LoadMenuTiles         ; the letters and the cursor
    call DrawMenu
    call LcdOnText

.loop:
    call WaitFrame
    call ReadPad               ; B = newly pressed
    bit 6, b                   ; UP
    jr nz, .up
    bit 7, b                   ; DOWN
    jr nz, .down
    bit 0, b                   ; A
    jr nz, .run
    jr .loop

.up:
    ldh a, [hSel]
    or a
    jr z, .loop
    dec a
    jr .move
.down:
    ldh a, [hSel]
    inc a
    cp ENTRIES
    jr nc, .loop
.move:
    ldh [hSel], a
    call WaitVBlank            ; the map write must not land in mode 3
    call DrawCursor
    jr .loop

; ---------------------------------------------------------------------------
; .run -- select the page's bank, put the machine back the way the boot ROM
; leaves it, and jump in with A = the model byte.
.run:
    call ResetHardware
    ldh a, [hSel]
    call EntryAddr             ; HL = the entry's row in MenuTable
    ld a, [hl+]
    ld [$2000], a              ; MBC5 ROM bank, low eight bits
    ld a, 0
    ld [$3000], a              ; ... and bit 8
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ldh a, [hIsCgb]
    jp hl

; ---------------------------------------------------------------------------
; ProbePoll -- called from inside a page's redraw loop (PROBE_POLL) and from
; its idle loop (IDLE_FOREVER). Returns at once unless START is down, so it
; costs the loop a dozen M-cycles ahead of an ANCHOR that re-syncs anyway.
ProbePoll::
    ld a, $10                  ; P15 low: the button group
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    and $08                    ; START reads 0 while held
    ret nz
.held:                         ; wait it out, or the menu takes the same press
    ld a, $10
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    and $08
    jr z, .held
    ldh a, [hIsCgb]
    jp Relaunch                ; SP is reset there, so the page's stack is moot

; ---------------------------------------------------------------------------
; ResetHardware -- every register a page can leave changed, back to the value
; the boot ROM leaves. OAM and WRAM are deliberately untouched: a page that
; uses either clears it itself, and a page that does not must see them exactly
; as its own .gb sees them.
ResetHardware:
    xor a
    ldh [rIE], a
    ldh [rIF], a
    ldh [rSTAT], a
    ldh [rLYC], a
    ldh [$FF02], a             ; SC: probe (k) serialdiv starts a transfer
    ldh [$FF05], a             ; TIMA
    ldh [$FF06], a             ; TMA
    ldh [$FF07], a             ; TAC
    ldh [rVBK], a
    ld a, 1
    ldh [rSVBK], a             ; CGB WRAM bank 1, as the boot ROM leaves it
    ret

; ---------------------------------------------------------------------------
; WaitFrame / WaitVBlank -- LY polling; the menu runs with interrupts off.
WaitFrame:
    call WaitVBlank
.active:
    ldh a, [rLY]
    cp 144
    jr nc, .active
    ret

WaitVBlank:
    ldh a, [rLY]
    cp 144
    jr nz, WaitVBlank
    ret

; ---------------------------------------------------------------------------
; ReadPad -- B = buttons pressed this frame and not last, in the usual order
; (bit 0 A, 1 B, 2 SELECT, 3 START, 4 RIGHT, 5 LEFT, 6 UP, 7 DOWN).
ReadPad:
    ld a, $10                  ; P15 low: A, B, SELECT, START
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    cpl
    and $0F
    ld c, a
    ld a, $20                  ; P14 low: RIGHT, LEFT, UP, DOWN
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    cpl
    and $0F
    swap a
    or c
    ld c, a                    ; C = held now
    ld a, $30
    ldh [rP1], a
    ldh a, [hPad]
    cpl
    and c
    ld b, a                    ; B = newly pressed
    ld a, c
    ldh [hPad], a
    ret

; ---------------------------------------------------------------------------
; LoadMenuTiles -- the cursor at tile CURSOR_TILE and G..Z at LETTER_BASE.
; InitVideo has already put the hex font at FONT_BASE, which covers 0-9 and
; A-F, so the menu's charmap needs only the twenty letters after F.
LoadMenuTiles:
    ld hl, _VRAM8000 + CURSOR_TILE * 16
    ld de, CursorTile
    ld bc, LetterTilesEnd - CursorTile
.cursor:                       ; sixteen bytes, then jump the gap to LETTER_BASE
    ld a, [de]
    inc de
    ld [hl+], a
    dec bc
    ld a, l
    cp LOW(_VRAM8000 + (CURSOR_TILE + 1) * 16)
    jr nz, .cursor
    ld hl, _VRAM8000 + LETTER_BASE * 16
.letters:
    ld a, [de]
    inc de
    ld [hl+], a
    dec bc
    ld a, b
    or c
    jr nz, .letters
    ret

; ---------------------------------------------------------------------------
; DrawMenu -- one entry per screen row, LCD off. Row r is
;   col 0  cursor      col 2..19  the entry's eighteen text tiles
DrawMenu:
    ld hl, _SCRN0
    ld de, MenuTable + 3       ; the first entry's text
    ld c, ENTRIES
.row:
    xor a
    ld [hl+], a                ; col 0: cursor, painted by DrawCursor
    ld [hl+], a                ; col 1: gap
    ld b, TEXTLEN
.text:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .text
    inc de
    inc de
    inc de                     ; step over the next entry's bank and address
    ld a, l
    add 32 - 2 - TEXTLEN
    ld l, a
    ld a, h
    adc 0
    ld h, a
    dec c
    jr nz, .row
    ; fall through: paint the cursor on the selected row

DrawCursor:
    ld hl, _SCRN0
    ld c, ENTRIES
    ldh a, [hSel]
    ld e, a
    ld d, 0
.row:
    ld a, d
    cp e
    ld a, CURSOR_TILE
    jr z, .put
    xor a
.put:
    ld [hl], a
    ld a, l
    add 32
    ld l, a
    ld a, h
    adc 0
    ld h, a
    inc d
    dec c
    jr nz, .row
    ret

; ---------------------------------------------------------------------------
; EntryAddr -- HL = MenuTable + A * ENTRYLEN.
EntryAddr:
    ld hl, MenuTable
    or a
    ret z
    ld b, a
.add:
    ld a, l
    add ENTRYLEN
    ld l, a
    ld a, h
    adc 0
    ld h, a
    dec b
    jr nz, .add
    ret

; ---------------------------------------------------------------------------
; The menu table. One row per page, in page-code order:
;   db bank   dw entry   ds TEXTLEN text tiles
NEWCHARMAP menu
    CHARMAP " ", $00
    CHARMAP "0", $10
    CHARMAP "1", $11
    CHARMAP "2", $12
    CHARMAP "3", $13
    CHARMAP "4", $14
    CHARMAP "5", $15
    CHARMAP "6", $16
    CHARMAP "7", $17
    CHARMAP "8", $18
    CHARMAP "9", $19
    CHARMAP "A", $1A
    CHARMAP "B", $1B
    CHARMAP "C", $1C
    CHARMAP "D", $1D
    CHARMAP "E", $1E
    CHARMAP "F", $1F
    CHARMAP "G", LETTER_BASE + 0
    CHARMAP "H", LETTER_BASE + 1
    CHARMAP "I", LETTER_BASE + 2
    CHARMAP "J", LETTER_BASE + 3
    CHARMAP "K", LETTER_BASE + 4
    CHARMAP "L", LETTER_BASE + 5
    CHARMAP "M", LETTER_BASE + 6
    CHARMAP "N", LETTER_BASE + 7
    CHARMAP "O", LETTER_BASE + 8
    CHARMAP "P", LETTER_BASE + 9
    CHARMAP "Q", LETTER_BASE + 10
    CHARMAP "R", LETTER_BASE + 11
    CHARMAP "S", LETTER_BASE + 12
    CHARMAP "T", LETTER_BASE + 13
    CHARMAP "U", LETTER_BASE + 14
    CHARMAP "V", LETTER_BASE + 15
    CHARMAP "W", LETTER_BASE + 16
    CHARMAP "X", LETTER_BASE + 17
    CHARMAP "Y", LETTER_BASE + 18
    CHARMAP "Z", LETTER_BASE + 19
SETCHARMAP main

MACRO ENTRY                    ; \1 bank, \2 entry symbol, \3 menu text
    db (\1)
    dw \2
    SETCHARMAP menu
    db \3
    SETCHARMAP main
    ds TEXTLEN - STRLEN(\3), 0
ENDM

MenuTable:
    ENTRY  1, ProbeStart_gwy0,        "20 G WY0"
    ENTRY  1, ProbeStart_gwy1,        "21 G WY1"
    ENTRY  1, ProbeStart_hscx,        "30 H SCX"
    ENTRY  2, ProbeStart_hscy,        "31 H SCY"
    ENTRY  3, ProbeStart_hwx,         "32 H WX"
    ENTRY  4, ProbeStart_hbgp,        "33 H BGP"
    ENTRY  5, ProbeStart_hlcdc4,      "34 H LCDC4"
    ENTRY  6, ProbeStart_hlcdc3,      "35 H LCDC3"
    ENTRY  1, ProbeStart_ioamdma,     "40 I OAMDMA"
    ENTRY  7, ProbeStart_jwinrestart, "50 J WINRESTART"
    ENTRY  8, ProbeStart_jhaltlead,   "51 J HALTLEAD"
    ENTRY  1, ProbeStart_kserialdiv,  "52 K SERIALDIV"
    ENTRY  9, ProbeStart_kwing0,      "53 K WINGLITCH A0"
    ENTRY 10, ProbeStart_kwing1,      "53 K WINGLITCH A1"
    ENTRY 11, ProbeStart_kwing2,      "53 K WINGLITCH A2"
    ENTRY 12, ProbeStart_kwingscx,    "54 K WINGLITCH SCX"
    ENTRY  1, ProbeStart_klcdon,      "55 K LCDON"
    ENTRY 13, ProbeStart_koamclass,   "56 K OAMCLASS"
MenuTableEnd:

ASSERT MenuTableEnd - MenuTable == ENTRIES * ENTRYLEN

; ---------------------------------------------------------------------------
; The cursor, then G..Z in the hex font's 5x7 style.
CursorTile:
    dw `03000000, `03300000, `03330000, `03333000, `03330000, `03300000, `03000000, `00000000

LetterTiles:
    ; G
    dw `00333000, `03000300, `03000000, `03033300, `03000300, `03000300, `00333000, `00000000
    ; H
    dw `03000300, `03000300, `03000300, `03333300, `03000300, `03000300, `03000300, `00000000
    ; I
    dw `00333000, `00030000, `00030000, `00030000, `00030000, `00030000, `00333000, `00000000
    ; J
    dw `00033300, `00003000, `00003000, `00003000, `00003000, `03003000, `00330000, `00000000
    ; K
    dw `03000300, `03003000, `03030000, `03300000, `03030000, `03003000, `03000300, `00000000
    ; L
    dw `03000000, `03000000, `03000000, `03000000, `03000000, `03000000, `03333300, `00000000
    ; M
    dw `03000300, `03303300, `03030300, `03000300, `03000300, `03000300, `03000300, `00000000
    ; N
    dw `03000300, `03300300, `03030300, `03003300, `03000300, `03000300, `03000300, `00000000
    ; O
    dw `00333000, `03000300, `03000300, `03000300, `03000300, `03000300, `00333000, `00000000
    ; P
    dw `03333000, `03000300, `03000300, `03333000, `03000000, `03000000, `03000000, `00000000
    ; Q
    dw `00333000, `03000300, `03000300, `03000300, `03030300, `03003000, `00330300, `00000000
    ; R
    dw `03333000, `03000300, `03000300, `03333000, `03030000, `03003000, `03000300, `00000000
    ; S
    dw `00333300, `03000000, `03000000, `00333000, `00000300, `00000300, `03333000, `00000000
    ; T
    dw `03333300, `00030000, `00030000, `00030000, `00030000, `00030000, `00030000, `00000000
    ; U
    dw `03000300, `03000300, `03000300, `03000300, `03000300, `03000300, `00333000, `00000000
    ; V
    dw `03000300, `03000300, `03000300, `03000300, `03000300, `00303000, `00030000, `00000000
    ; W
    dw `03000300, `03000300, `03000300, `03030300, `03030300, `03303300, `03000300, `00000000
    ; X
    dw `03000300, `03000300, `00303000, `00030000, `00303000, `03000300, `03000300, `00000000
    ; Y
    dw `03000300, `03000300, `00303000, `00030000, `00030000, `00030000, `00030000, `00000000
    ; Z
    dw `03333300, `00000300, `00003000, `00030000, `00300000, `03000000, `03333300, `00000000
LetterTilesEnd:

; ---------------------------------------------------------------------------
; The one copy of the shared video/readout runtime. Every page's own copy is
; stripped by GBPROBE_COMBINED and resolved to these.
INCLUDE "common.inc"

EXPORT LcdOff, InitVideo, ClearVram, LcdOnText, MapAddr, PutNibble, PutByte
EXPORT FontTiles, CgbPal0
