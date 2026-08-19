; wramscan — photograph the power-up contents of work RAM.
;
; WHY. BullyGB's first test, InitRAMTest, walks $C000-$DFFF and reports
; "Uninitialized RAM not randomized" if every byte is $00 — which is exactly
; dingbat's power-up state, so bully stops there and its other eight tests
; (bootreg, divtest, dmabusconflict, echoram, initvram_dmg, undoc_regs,
; unused_io) have never run in this emulator. Filling WRAM with a fixed
; xorshift makes bully print "All tests OK!", but it costs gambatte's
; oamdma_srcFE00_*/srcFF00_* rows, which read WRAM back through the echo
; region and therefore encode SOME power-up convention. Zeroes are wrong and
; that xorshift is wrong; nobody in the tree knows what is right.
;
; This asks the console. Run it on a COLD boot (battery out / power off for a
; few seconds, not a reset) and photograph the screen.
;
; WHAT IT SHOWS
;
;   line 0    three 4-digit counts over all 8192 bytes of $C000-$DFFF:
;               ZEROS   how many bytes are $00
;               FFS     how many bytes are $FF
;               OTHER   how many are neither
;   lines 2-17  a 16x16 map. Each cell covers 32 consecutive bytes:
;               0  all 32 bytes are $00
;               F  all 32 bytes are $FF
;               A  anything else (a mixed or patterned chunk)
;             Cell (col, row) covers $C000 + (row*16 + col) * 32, reading
;             left to right then top to bottom.
;
; The map is what makes this worth photographing rather than just counting:
; real WRAM is not uniform noise, it is STRUCTURED — typically banded, with
; runs of one value and boundaries at regular addresses — and the shape of the
; banding is what an emulator would have to reproduce for the gambatte rows to
; keep passing.
;
; CRITICAL: this ROM writes NOTHING to WRAM before it has finished measuring
; it. The stack lives in HRAM ($FFFE), the three counters live in HRAM, and
; everything drawn goes straight to VRAM. Adding a single `ld [$C000], a`
; anywhere above the scan would destroy the thing being measured.

INCLUDE "hw.inc"

SECTION "hram", HRAM
hIsCgb:   db
hZeros:   dw
hFFs:     dw
hOther:   dw

SECTION "entry", ROM0[$100]
    nop
    jp Start
    DS $150 - @

SECTION "main", ROM0

Start:
    di
    ld sp, $FFFE               ; HRAM stack: a WRAM stack would overwrite the
    ldh [hIsCgb], a            ; very bytes this ROM exists to read
    call LcdOff
    call ClearVram
    call InitVideo

    xor a
    ldh [hZeros], a
    ldh [hZeros + 1], a
    ldh [hFFs], a
    ldh [hFFs + 1], a
    ldh [hOther], a
    ldh [hOther + 1], a

    ; ---- scan 256 cells of 32 bytes, writing each cell's glyph straight to
    ; ---- the tilemap as it goes, so no buffer is needed anywhere.
    ld hl, $C000               ; source
    ld de, _SCRN0 + 32 * 2 + 2 ; tilemap cursor: line 2, column 2
    ld c, 0                    ; cell index 0..255
.cell
    push de
    ; classify 32 bytes: b = saw a non-$00, c' = saw a non-$FF
    ld d, 0                    ; d bit0 = saw non-zero
    ld e, 0                    ; e bit0 = saw non-FF
    ld b, 32
.byte
    ld a, [hli]
    or a
    jr z, .isZero
    ld d, 1
    jr .checkFF
.isZero
    push hl
    ld hl, hZeros + 1
    inc [hl]
    jr nz, .noCarryZ
    dec hl
    inc [hl]
.noCarryZ
    pop hl
.checkFF
    cp $FF
    jr z, .isFF
    ld e, 1
    jr .counted
.isFF
    push hl
    ld hl, hFFs + 1
    inc [hl]
    jr nz, .noCarryF
    dec hl
    inc [hl]
.noCarryF
    pop hl
.counted
    dec b
    jr nz, .byte

    ; glyph: all-zero -> '0', all-FF -> 'F', else 'A'
    ld a, d
    or a
    jr z, .allZero             ; never saw a non-zero byte
    ld a, e
    or a
    jr z, .allFF               ; never saw a non-FF byte
    ld a, FONT_BASE + $0A      ; 'A' = mixed
    jr .put
.allZero
    ld a, FONT_BASE + $00
    jr .put
.allFF
    ld a, FONT_BASE + $0F
.put
    pop de
    ld [de], a
    inc de

    ; every 16 cells, drop to the next tilemap line and back to column 2
    ld a, c
    inc a
    ld c, a
    and $0F
    jr nz, .noWrap
    ld a, e
    add 32 - 16
    ld e, a
    ld a, d
    adc 0
    ld d, a
.noWrap
    ld a, c
    or a
    jr nz, .cell

    ; ---- "other" = 8192 - zeros - ffs ---------------------------------
    ld hl, 8192
    ldh a, [hZeros]
    ld b, a
    ldh a, [hZeros + 1]
    ld c, a
    ld a, l
    sub c
    ld l, a
    ld a, h
    sbc b
    ld h, a
    ldh a, [hFFs]
    ld b, a
    ldh a, [hFFs + 1]
    ld c, a
    ld a, l
    sub c
    ld l, a
    ld a, h
    sbc b
    ld h, a
    ld a, h
    ldh [hOther], a
    ld a, l
    ldh [hOther + 1], a

    call DrawCounts
    call LcdOnText
.done
    halt
    jr .done

; Three 4-digit counts on line 0: zeros at x=0, FFs at x=5, other at x=10.
DrawCounts:
    call LcdOff
    ld d, 0
    ld e, 0
    ldh a, [hZeros]
    call PutByte
    ld e, 2
    ldh a, [hZeros + 1]
    call PutByte
    ld e, 5
    ldh a, [hFFs]
    call PutByte
    ld e, 7
    ldh a, [hFFs + 1]
    call PutByte
    ld e, 10
    ldh a, [hOther]
    call PutByte
    ld e, 12
    ldh a, [hOther + 1]
    call PutByte
    ret

INCLUDE "common.inc"
