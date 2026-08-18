; probe_d_tdsel -- when does an LCDC.4 write reach the BACKGROUND FETCHER?
;
; THE QUESTION. `cgb-acid-hell` and mealybug's `m3_lcdc_tile_sel_change2` are
; the same experiment -- pulse LCDC.4 across a background bitplane fetch and
; photograph which byte came back -- and dingbat cannot satisfy both. Traced
; 2026-08-17 on the shipping tree:
;
;   change2   line 43: map read 142, plane 0 at 144, LCDC write 145, plane 1 146
;   acid-hell line 68: map read 170, plane 0 at 172, plane 1 at 174, write 177
;
; Both ROMs write on the same phase (dot = 1 mod 8); their fetch grids sit four
; dots apart. So ONE latency from the write to the fetcher cannot serve both:
; at the shipping `CGB_TDSEL_LATENCY = 1` change2's write lands exactly on its
; plane-1 read (glitch, reference matched) while acid-hell's lands on a MAP
; read (no glitch at all, and acid-hell's two pixels come out wrong); at 5 the
; two swap, acid-hell goes pixel-exact and change2's four rows break. That is
; the whole of the GBEmulatorShootout's last failing row, and neither ROM can
; arbitrate it, because each is consistent with itself.
;
; WHAT THIS PROBE MEASURES. The latency directly, as a function the photograph
; can read: for a write at a KNOWN offset, which read of the fetch cycle comes
; back glitched. The offset is swept, and -- unlike probe (c), whose staircase
; moves by four dots a line and has to be measured geometrically -- it is held
; constant for a whole BAND of nine identical scanlines. The answer is a block
; of colour nine pixels tall, not a one-pixel step, so it survives a hand-held
; photograph of a lit screen and needs no registration to read.
;
; HOW TO READ IT. Sixteen bands, top to bottom, band k writing k M-cycles later
; than band 0 (one M-cycle = four dots). Every band shows one vertical bar
; whose SHADE is the reading, because the background is built so that the two
; addressing modes disagree on every bit (probe (c)'s trick):
;
;   bar WHITE (index 0)  -- the write missed the fetch's data reads entirely
;                           (it landed on the map read or on a sleep dot)
;   bar BLACK (index 3)  -- BOTH bitplanes came from the wrong mode
;   bar LIGHT (index 1)  -- only the LOW plane was redirected
;   bar DARK  (index 2)  -- only the HIGH plane was redirected
;
; So the band index of the first non-white bar is the latency in M-cycles, and
; its shade says which plane the write reached first. The pattern repeats with
; the fetch cycle (8 dots = 2 M-cycles), so a correct reading shows the same
; shade every second band -- which is the built-in consistency check: sixteen
; bands measure the same two phases eight times each.
;
; SCX is a build-time define, exactly as in probe (c): the fetch grid's phase
; against the CPU's carries a borrow off the fine scroll (SCX_FINE_BORROW), so
; SCXVAL 0/3/7 are three different relative phases and all three are worth a
; photograph. Between them they cover the 4-dot ambiguity the M-cycle grid
; leaves, which is precisely the gap acid-hell and change2 disagree across.
;
; DEVICE. Built WITHOUT a CGB flag, like probe (c): the disputed constant is
; `CGB_TDSEL_LATENCY`, i.e. CGB silicon, and a CGB running a cartridge with no
; CGB flag is CGB silicon in DMG-compatibility mode -- which is also what
; `cgb-acid-hell` measures through its own $FEA0 gate, and what daid's frames
; are. The same cart runs on a DMG for free, and that column is a control: the
; DMG has no such latency, so its first non-white band IS the zero point the
; CGB's is measured against.

INCLUDE "hw.inc"

IF !DEF(SCXVAL)
DEF SCXVAL EQU 0
ENDC

DEF LCDC_ON8000 EQU LCDCF_ON | LCDCF_BG8000 | LCDCF_BGON   ; $91
DEF LCDC_ON8800 EQU LCDCF_ON | LCDCF_BGON                  ; $81

; Bands, and PULSED lines per band. Each band is eight pulsed lines plus one
; blank one (the pad below), so a band occupies nine scanlines and sixteen of
; them are exactly the 144-line frame. The blank line is not filler: it is a
; visible separator between bands, which is what lets the bands be counted off
; a photograph without measuring anything.
DEF BANDS EQU 16
DEF BANDLINES EQU 8

; The pulse's position inside the line, in M-cycles from the top of the body.
; BASE is overridable for the same reason probe (c)'s S1 is: the halt-wake
; latency is the one quantity this ROM cannot know in advance, and moving BASE
; walks the bar across the screen until a camera can see it. At BASE = 26 the
; pulse lands near dot 185 -- comfortably inside mode 3 at every SCX, and far
; from both edges.
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
; (`jp nz` not taken), and the next band's counter costs 2, so the pad is not
; a round number: 7*114 + 113 + 2 + PAD = 9*114 puts the next band's first
; pulse on exactly the same dot of its line as this band's was. Get this wrong
; and every band is measuring a different offset than it says.
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
; is a constant the assembler folds -- a runtime-variable NOPS would need a
; jump table whose own cost would land back inside the measurement. The line
; counter for the NEXT band is loaded inside this band's pad, so no band's
; first line is a different length from its other seven.
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
