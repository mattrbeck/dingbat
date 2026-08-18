; probe_cart -- is the flash cartridge returning the ROM's real bytes?
;
; WHY THIS EXISTS. Every other probe in this directory measures the CONSOLE,
; and each one assumes the cartridge hands the CPU the bytes the .gb file
; contains. A cheap flash cart can break that assumption -- marginal flash
; access times, weak buffers on the address lines -- and the failure is
; silent: the CPU never stalls waiting for a cartridge, because the Game Boy
; bus has no wait states at all. A late or wrong byte is simply executed. So
; a bad cart does not make a probe fail loudly; it makes it measure fiction.
;
; This ROM turns that into something photographable. It reads its own 32 KiB
; three different ways and shows the checksums, then hammers two addresses at
; opposite ends of the ROM and counts disagreements. Run it once at the start
; of a session; if the numbers match what the same .gb produces in an
; emulator, the cart is feeding the CPU correctly and every other probe's
; reading can be trusted.
;
; WHAT EACH ROW IS
;
;   00  hhll   sum16 of $0000-$7FFF read FORWARD
;   01  hhll   the same bytes read BACKWARD
;   02  hhll   the same bytes in a 251-byte STRIDE (251 is odd, so the walk
;              still visits all 32768 addresses exactly once)
;   03  ..cc   disagreements while alternating reads of $0104 and $7F04,
;              4096 times each, against the values first read there
;   04  ..aa   A at boot: $01 DMG-family, $11 CGB-family. Context, not a check
;
; All three sums cover the same bytes, so on a healthy cart rows 00, 01 and
; 02 are IDENTICAL. They differ in the ORDER of the reads, which is the point:
; sequential access is the easy case for slow flash, and it is the only case
; a plain "does it boot" check exercises. The stride makes every read a long
; address-line transition, and row 03 alternates between $0104 and $7F04 --
; fifteen address lines toggling on every access, the pattern most likely to
; expose a cart that settles late.
;
; A cart that fails only under a pattern this ROM does not use is still
; possible, and nothing here can rule it out. What a clean result does say is
; that the ROM's own bytes survive both the easy and the hard access order,
; which is the assumption the other probes actually rest on.
;
; The Game Boy's boot ROM already checks the logo and the header checksum, so
; a cart that mangles the first $34 bytes never gets this far -- that is the
; one piece of cartridge verification every GB does for free, and this ROM is
; the rest of it.

INCLUDE "hw.inc"

DEF FLAK_ITERS EQU 4096
DEF STRIDE EQU 251
DEF ADDR_LO EQU $0104
DEF ADDR_HI EQU $7F04

SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "hram", HRAM
hIsCgb: db

SECTION "wram", WRAM0
wFwd:  dw
wRev:  dw
wStr:  dw
wFlak: db
wBoot: db

SECTION "main", ROM0[$150]

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a
    ld [wBoot], a
    call InitVideo              ; LCD off, VRAM cleared, font loaded

; ---------------------------------------------------------------- forward ---
    ld bc, 0                    ; sum
    ld de, 0                    ; address
    ld hl, $8000                ; count
.fwd:
    ld a, [de]
    add c
    ld c, a
    jr nc, .fwdNoCarry
    inc b
.fwdNoCarry:
    inc de
    dec hl
    ld a, h
    or l
    jr nz, .fwd
    ld a, c
    ld [wFwd], a
    ld a, b
    ld [wFwd + 1], a

; ---------------------------------------------------------------- reverse ---
    ld bc, 0
    ld de, $7FFF
    ld hl, $8000
.rev:
    ld a, [de]
    add c
    ld c, a
    jr nc, .revNoCarry
    inc b
.revNoCarry:
    dec de
    dec hl
    ld a, h
    or l
    jr nz, .rev
    ld a, c
    ld [wRev], a
    ld a, b
    ld [wRev + 1], a

; ----------------------------------------------------------------- stride ---
; DE walks the ROM in steps of STRIDE, wrapped into $0000-$7FFF. STRIDE is
; odd, so it is coprime with 32768 and the walk is a permutation: the same
; 32768 bytes, in an order that makes almost every read a long jump.
    ld bc, 0
    ld de, 0
    ld hl, $8000
.str:
    ld a, [de]
    add c
    ld c, a
    jr nc, .strNoCarry
    inc b
.strNoCarry:
    push hl
    ld hl, STRIDE
    add hl, de
    ld a, h
    and $7F
    ld d, a
    ld e, l
    pop hl
    dec hl
    ld a, h
    or l
    jr nz, .str
    ld a, c
    ld [wStr], a
    ld a, b
    ld [wStr + 1], a

; ------------------------------------------------------------------- flaky ---
; Alternate the two addresses so fifteen address lines toggle on every read,
; and count how often either one disagrees with what it first returned.
    ld a, [ADDR_LO]
    ld d, a
    ld a, [ADDR_HI]
    ld e, a
    ld bc, FLAK_ITERS
    ld hl, 0                    ; L = mismatches, saturating at $FF
.flak:
    ld a, [ADDR_LO]
    cp d
    jr z, .flakHi
    inc l
    jr z, .flakSat              ; wrapped past $FF
.flakHi:
    ld a, [ADDR_HI]
    cp e
    jr z, .flakNext
    inc l
    jr nz, .flakNext
.flakSat:
    ld l, $FF
.flakNext:
    dec bc
    ld a, b
    or c
    jr nz, .flak
    ld a, l
    ld [wFlak], a

; -------------------------------------------------------------------- draw ---
    call LcdOff

    ld d, 0                     ; row 0: forward
    ld e, 0
    xor a
    call PutByte
    ld e, 3
    ld a, [wFwd + 1]
    call PutByte
    ld e, 5
    ld a, [wFwd]
    call PutByte

    ld d, 1                     ; row 1: reverse
    ld e, 0
    ld a, $01
    call PutByte
    ld e, 3
    ld a, [wRev + 1]
    call PutByte
    ld e, 5
    ld a, [wRev]
    call PutByte

    ld d, 2                     ; row 2: stride
    ld e, 0
    ld a, $02
    call PutByte
    ld e, 3
    ld a, [wStr + 1]
    call PutByte
    ld e, 5
    ld a, [wStr]
    call PutByte

    ld d, 3                     ; row 3: flaky count
    ld e, 0
    ld a, $03
    call PutByte
    ld e, 5
    ld a, [wFlak]
    call PutByte

    ld d, 4                     ; row 4: boot A
    ld e, 0
    ld a, $04
    call PutByte
    ld e, 5
    ld a, [wBoot]
    call PutByte

    call LcdOnText
    IDLE_FOREVER

INCLUDE "common.inc"
