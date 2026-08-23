; probe_d_tdsel -- when does an LCDC.4 write reach the background fetcher?
;
; For a write at a known offset, which read of the fetch cycle comes back
; glitched. The offset is held constant for a BAND of nine identical
; scanlines, so the answer is a block of colour nine pixels tall that survives
; a hand-held photograph without registration.
;
; HOW TO READ IT. Sixteen bands, top to bottom, band k writing k M-cycles
; later than band 0 (one M-cycle = four dots). Each band shows one vertical
; bar whose SHADE is the reading, because the background is built so that the
; two addressing modes disagree on every bit:
;
;   bar WHITE (index 0)  -- the write missed the fetch's data reads entirely
;                           (it landed on the map read or on a sleep dot)
;   bar BLACK (index 3)  -- BOTH bitplanes came from the wrong mode
;   bar LIGHT (index 1)  -- only the LOW plane was redirected
;   bar DARK  (index 2)  -- only the HIGH plane was redirected
;
; The band index of the first non-white bar is the latency in M-cycles, and
; its shade says which plane the write reached first. The pattern repeats
; with the fetch cycle (8 dots = 2 M-cycles), so a correct reading shows the
; same shade every second band: sixteen bands measure two phases eight times.
;
; SCX is a build-time define; SCXVAL 0/3/7 are three fetch-grid phases against
; the CPU and all three are worth a photograph.
;
; The main builds carry the CGB flag (native mode, as cgb-acid-hell and
; mealybug's tile_sel CGB captures are); common.inc gives CGB palette 0 the
; same four greys as the DMG palette, so the readout is identical either way.
; probe_d_tdsel_compat.gb is the same source with the flag off, to test
; whether the latency depends on the mode. A DMG runs every build (the flag
; is ignored) and is the control: it has no such latency.

INCLUDE "hw.inc"

IF !DEF(SCXVAL)
DEF SCXVAL EQU 0
ENDC

DEF LCDC_ON8000 EQU LCDCF_ON | LCDCF_BG8000 | LCDCF_BGON   ; $91
DEF LCDC_ON8800 EQU LCDCF_ON | LCDCF_BGON                  ; $81

; Eight pulsed lines plus one blank separator line (the pad below) per band;
; sixteen nine-line bands are exactly the 144-line frame.
DEF BANDS EQU 16
DEF BANDLINES EQU 8

; The pulse's position inside the line, in M-cycles from the top of the body.
; 26 puts it near dot 185, inside mode 3 at every SCX. Overridable: the
; halt-wake latency is the one quantity the ROM cannot know in advance.
IF !DEF(BASE)
DEF BASE EQU 26
ENDC

; A line is 114 M-cycles, and every line of the frame has to be exactly that
; or the pulse walks and the band stops meaning one offset. Per pulsed line:
;   BASE + k     lead-in nops
;   2            ld [hl], d      LCDC.4 low   <- the write under test
;   2            ld [hl], e      LCDC.4 high, eight dots later
;   TAIL - k     trailing nops
;   1            dec b
;   4            jp nz (taken)
; so BASE + TAIL + 9 = 114, i.e. BASE + TAIL = 105, independent of k -- which
; is what makes the k in the lead-in a pure offset and not a length change.
DEF TAIL EQU 105 - BASE

; The band's ninth line. Leaving the loop costs 1 M less than going round it
; (`jp nz` not taken) and the next band's counter costs 2, so
; 7*114 + 113 + 2 + PAD = 9*114 keeps every band's first pulse on the same dot.
DEF PAD EQU 113

SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "hram", HRAM
hIsCgb: db          ; common.inc's InitVideo reads it to pick the palette path

SECTION "main", ROM0[$150]

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a  ; boot leaves A = $11 on CGB, $01 on DMG
    call InitVideo

    ; Tile $01 in $8000 mode is at $8010 and is all index 0 (VRAM is already
    ; clear). Tile $01 in $8800 mode is signed +1, at $9010; filling it with
    ; $FF makes it all index 3. A fetch that takes one plane from each lands
    ; on index 1 or 2 -- which is the reading, not noise.
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
    ld a, %11100100        ; identity palette: a tile's index IS its shade
    ldh [rBGP], a
    ld a, LCDC_ON8000
    ldh [rLCDC], a

Frame:
    ld hl, rLCDC
    ld d, LCDC_ON8800
    ld e, LCDC_ON8000
    ANCHOR 0
    ; ---- anchor: the lead-in below is 2 M-cycles, then band 0's first line
    ; starts. Every line from here to the bottom of the frame is 114 M-cycles.

; Each band is straight-line code with its own inner loop, so the write offset
; is an assembler constant (a runtime NOPS would cost cycles inside the
; measurement). The next band's counter is loaded inside this band's pad, so
; no band's first line differs in length from its other seven.
    ld b, BANDLINES        ; band 0's counter; the pad reloads it thereafter
FOR K, BANDS
.band{d:K}:
    NOPS (BASE + K)
    ld [hl], d             ; 2 M -- LCDC.4 LOW: the write under test
    ld [hl], e             ; 2 M -- LCDC.4 high again, 8 dots later
    NOPS (TAIL - K)
    dec b                  ; 1 M
    jp nz, .band{d:K}      ; 4 M taken / 3 M not taken
    ld b, BANDLINES        ; 2 M -- for the next band
    NOPS PAD               ; the blank ninth line
ENDR

    jp Frame

INCLUDE "common.inc"
