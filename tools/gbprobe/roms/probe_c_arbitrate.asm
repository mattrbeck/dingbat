; probe_c_arbitrate -- are pixel emission and the BG fetch grid the same grid?
;
; From one halt anchor at LY = LYC = ANCHORLINE, a loop whose body is 115
; M-cycles -- one more than a scanline -- so each iteration starts four dots
; later in its line and both features below walk right by four pixels per
; line. Each iteration, on its own line:
;
;   * ONE BGP write against a flat background: the band EDGE's column reads
;     out emission's phase.
;   * ONE LCDC.4 pulse eight dots wide ($91 -> $81 -> $91) over a map whose
;     tile index reads back different data in the two addressing modes: the
;     glitched bitplane fetch shows as a column of the other mode's data.
;
; Reading it. Two staircases descend across the frame. The measurement is the
; HORIZONTAL DISTANCE between them on one line; the absolute position depends
; on the halt-wake latency and is not comparable between machines. If
; emission and the fetch grid are one grid the distance is fixed by the code
; at (glitch slide - band slide) dots; a four-dot separation between them
; shows as four pixels.
;
; DMG cart on purpose: the emission ruler is BGP, which is dead on a CGB
; running a CGB-flagged cart (colour comes from CRAM, not writable in mode 3).
; DMG-compatibility mode on a CGB has CGB silicon with BGP live; a DMG runs
; the same cart natively and is the control.
;
; SCX is a build-time define (mk.sh probe_c_arbitrate -DSCXVAL=3). SCXVAL 0,
; 3 and 7 are three different fetch-grid phases against the CPU.

INCLUDE "hw.inc"

IF !DEF(SCXVAL)
DEF SCXVAL EQU 0
ENDC

IF !DEF(ANCHORLINE)
DEF ANCHORLINE EQU 0
ENDC

; Identity and its exact reverse, so every colour index is distinguishable in
; both states: a half-glitched fetch (one bitplane redirected) lands on index
; 1 or 2, which is a reading, not noise.
DEF BGP_A EQU %11100100
DEF BGP_B EQU %00011011

; LCD on, BG on, objects and window off; tile data at $8000 and at $8800.
DEF LCDC_ON8000 EQU LCDCF_ON | LCDCF_BG8000 | LCDCF_BGON   ; $91
DEF LCDC_ON8800 EQU LCDCF_ON | LCDCF_BGON                  ; $81

; Slide lengths, in M-cycles, inside the 115-M-cycle body (wake within a few
; dots of line start, 4 M-cycles of lead-in, mode 3 from dot 80):
;   S1  BGP write at about dot 79 on the first line: the band edge enters at
;       column 0 and walks right by 4 per line.
;   S2  LCDC.4 pulse 40 dots later: the glitched column enters at about
;       column 39 and never overlaps the band edge on screen.
;   S3  BGP restore past the visible line, so the band reaches the right edge.
;   S4  the remainder.
; Overridable (mk.sh probe_c_arbitrate -DS2=9): the halt-wake latency is the
; one number the ROM cannot know, and S1 walks both staircases into view.
IF !DEF(S1)
DEF S1 EQU 14
ENDC
IF !DEF(S2)
DEF S2 EQU 8
ENDC
IF !DEF(S3)
DEF S3 EQU 27
ENDC
; 98, not 99: the loop tail is `jp nz` (4 M-cycles taken), because the body is
; 140-odd bytes of NOP slide and a relative jump cannot reach back over it.
DEF S4 EQU 98 - S1 - S2 - S3

DEF LINES EQU 144

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
    ldh [hIsCgb], a

    call InitVideo

    ; Map entry $01 everywhere. In $8000 mode tile $01 is at $8010, all index
    ; 0 (VRAM is already clear); in $8800 mode it is signed +1 at $9010, all
    ; index 3. One bitplane from each lands on index 1 or 2, which says WHICH
    ; plane was redirected.
    ld hl, $9010
    ld b, 16
    ld a, $FF
.glyph:
    ld [hl+], a
    dec b
    jr nz, .glyph

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

    ld a, SCXVAL
    ldh [rSCX], a
    xor a
    ldh [rSCY], a
    ld a, BGP_A
    ldh [rBGP], a
    ld a, LCDC_ON8000
    ldh [rLCDC], a

Frame:
    ld hl, rLCDC
    ld c, LOW(rBGP)
    ld d, LCDC_ON8800
    ld e, LCDC_ON8000
    ; ANCHORLINE is a build-time define; 0 ships. Line 0 is the LY 153 -> 0
    ; snapback wake, so a non-zero value anchors on an ordinary line instead.
    ANCHOR ANCHORLINE
    ; ---- anchor: 4 M-cycles of lead-in, then the body, forever at 115 each
    ld b, LINES            ; 2 M
    ld a, BGP_B            ; 2 M
.line:
    NOPS S1
    ldh [c], a             ; 2 M -- BGP <- B. The band edge is this dot.
    NOPS S2
    ld [hl], d             ; 2 M -- LCDC.4 low
    ld [hl], e             ; 2 M -- LCDC.4 high, exactly 8 dots later
    NOPS S3
    ld a, BGP_A            ; 2 M
    ldh [c], a             ; 2 M -- BGP restored, past the visible line
    ld a, BGP_B            ; 2 M -- reloaded for the next iteration
    NOPS S4
    dec b                  ; 1 M
    jp nz, .line           ; 4 M
    jp Frame

INCLUDE "common.inc"
