; probe_c_arbitrate -- acid-hell against daid, on ONE frame.
;
; docs/gb-failure-triage.md, hardware experiment (c), and the oldest
; pixel-level contradiction in the tree. `cgb-acid-hell` needs the CPU's writes
; aligned to the BG FETCH grid where they are; `daid/ppu_scanline_bgp` needs
; them four dots later relative to pixel EMISSION. Run on separate frames the
; two are two measurements of two things. Run on ONE frame they arbitrate,
; because the fetch grid and the emission grid are then the same grid.
;
; What the frame contains. From one halt anchor at LY = LYC = 0, a loop whose
; body is exactly 115 M-cycles -- one dot MORE than a scanline's 114 -- so each
; iteration starts four dots later in its line than the last, and both features
; below walk right by four pixels per line. Each iteration does two things on
; its own line:
;
;   * ONE BGP write, against a flat background, so the resulting band EDGE's
;     column reads out emission's phase. This is daid's ruler.
;   * ONE LCDC.4 pulse eight dots wide ($91 -> $81 -> $91), over a map whose
;     tile index reads back DIFFERENT DATA in the two addressing modes, so the
;     glitched bitplane fetch shows up as a column that is unambiguously the
;     other mode's data. This is acid-hell's residue.
;
; Reading it. Two staircases descend across the frame. The measurement is not
; either staircase's absolute position -- that depends on the halt-wake latency
; and is not comparable between machines -- it is the HORIZONTAL DISTANCE
; between them on the same line, which is internal to one photograph. If
; emission and the fetch grid are the same grid, that distance is fixed by the
; code and equals (glitch slide - band slide) in dots. If hardware separates
; emission from the fetch grid by four dots, the distance is four pixels off,
; in the same photograph, with nothing else changed.
;
; WHY THIS IS A DMG CART, and it is the one design decision worth arguing with.
; The doc says "Setup. CGB." The emission ruler it names is BGP -- and on a CGB
; running a CGB-flagged cartridge BGP is dead, colour comes from CRAM, and CRAM
; is not writable during mode 3, so there is NO mid-line emission ruler in true
; CGB mode at all. The only way to put daid's ruler and acid-hell's residue on
; one frame is the machine daid itself runs on: a CGB executing a cartridge
; with no CGB flag, i.e. DMG-compatibility mode, where the PPU is CGB silicon
; and BGP is live. So this cart carries no CGB flag, which also means it runs
; natively on a DMG for free, and the DMG column is a control rather than an
; extra build.
;
; SCX is a build-time define (mk.sh probe_c_arbitrate -DSCXVAL=3), because the
; campaign's one solid new structural result (SCX_FINE_BORROW) says the fetch
; grid's column carries a borrow off the fine scroll, and no reference frame in
; existence exercises that. SCXVAL 0, 3 and 7 are the three worth having.

INCLUDE "hw.inc"

IF !DEF(SCXVAL)
DEF SCXVAL EQU 0
ENDC

; The two BGP values. Identity, and its exact reverse, so EVERY colour index is
; distinguishable in both states -- which matters because a half-glitched fetch
; (one bitplane redirected, not both) lands on index 1 or 2, and that is itself
; a reading, not noise.
DEF BGP_A EQU %11100100
DEF BGP_B EQU %00011011

; LCDC with BG tile data at $8000, and the same with bit 4 cleared. Both keep
; the LCD on and the BG enabled; objects and the window are off throughout, so
; nothing but the BG fetcher is on the line.
DEF LCDC_ON8000 EQU LCDCF_ON | LCDCF_BG8000 | LCDCF_BGON   ; $91
DEF LCDC_ON8800 EQU LCDCF_ON | LCDCF_BGON                  ; $81

; Slide lengths, in M-cycles, inside the 115-M-cycle body. Derived in the
; header comment's terms: the wake lands within a few dots of the line start,
; the loop's lead-in is 4 M-cycles, and mode 3 begins at dot 80.
;   S1  puts the BGP write at about dot 79 on the first line, so its band edge
;       enters at column 0 and walks right by 4 per line.
;   S2  puts the LCDC.4 pulse 40 dots later, so the glitched column enters at
;       about column 39 -- far enough from the band edge that the two never
;       overlap while both are on screen.
;   S3  puts the BGP restore past the end of the visible line, so the band
;       reaches the right-hand edge of the screen instead of stopping short.
;   S4  is the remainder; the four must sum to 99 for the body to be 115.
; All three are overridable (mk.sh probe_c_arbitrate -DS2=9), because on real
; hardware the halt-wake latency is the one number this ROM cannot know in
; advance, and moving S1 walks both staircases across the screen until they
; are where a camera can see them.
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

    ; The background: map entry $01 everywhere, whose DATA differs by
    ; addressing mode. In $8000 mode tile $01 is at $8010 and is all colour
    ; index 0 (already zero from the VRAM clear). In $8800 mode tile $01 is
    ; signed +1, at $9010, and is all index 3. A fetch that reads the wrong
    ; one is therefore unmistakable, and a fetch that reads one bitplane from
    ; each lands on index 1 or 2, which says WHICH plane was redirected.
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
    ANCHOR 0
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
