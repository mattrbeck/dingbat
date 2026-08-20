; rtcrate — measure the MBC3 RTC against the frame clock, on real hardware.
;
; WHY. dingbat walks ax6/rtc3test's battery ~25% slower than whatever emulator
; the GBEmulatorShootout captured its reference images with: rtc3test-1 needs
; 720 frames where the shootout allots 570 (testroms/ax6.py, runtime=9.5), and
; -3 needs >1500 where it allots 1200. Every sub-test PASSES and dingbat's
; final frame is a 100.0% pixel match to the reference, so the BEHAVIOUR is
; right and only the PACING is disputed. Nothing in the tree can settle that,
; because both candidates are emulators. This asks silicon.
;
; Four measurements, all in FRAMES (LY 143->144 edges), printed as four hex
; digits each:
;
;   row 0   frames for EIGHT RTC seconds   (divide by 8 for the rate)
;   row 1   frames from a SECONDS-register write to the next tick
;   row 2   frames from a MINUTES-register write to the next tick
;   row 3   frames from halt -> resume to the next tick
;
; Row 0 is the rate: one GB second is 4194304 T and a frame is 70224 T, so a
; correct clock gives 8 seconds ~= 478 frames = $01DE, and anything near $0258
; (8 * 75) would be a clock running a quarter slow.
;
; Rows 1-3 are the sub-second divider rule, which is what actually decides the
; dispute. rtc3test's own tests.md says writing SECONDS resets the divider to a
; FULL second (RTCS/500 and RTCS/900 both expect 1000ms) while writing MINUTES
; leaves the remaining time alone (RTCM/50 expects 50ms). Each write here lands
; 30 frames (~half a second) after a tick, so:
;
;   row 1 ~= 60 frames ($3C)   if a seconds write resets the divider
;   row 2 ~= 30 frames ($1E)   if a minutes write does not
;
; If row 1 comes back ~30 instead, the divider is NOT reset and dingbat is
; spending a whole extra second on every seconds write that rtc3test makes —
; which would be the entire 25%.
;
; No CGB flag on purpose: the RTC is on the CARTRIDGE, so this measures its
; crystal against the console's frame clock and wants the plainest machine.
; Runs on DMG/MGB/SGB/CGB/AGB alike. NEEDS AN MBC3+TIMER CART — see build.sh,
; which fixes the header to $10 (MBC3+TIMER+RAM+BATTERY) rather than mk.sh's
; ROM-only default.

INCLUDE "hw.inc"

DEF ROWS EQU 6
DEF TICK_CAP EQU 180   ; frames a single tick wait may take before giving up

SECTION "hram", HRAM
hIsCgb: db

SECTION "vars", WRAM0
wResults: DS ROWS * 2
wRow:     DS 1

SECTION "entry", ROM0[$100]
    nop
    jp Start
    DS $150 - @

SECTION "main", ROM0

; Wait one frame (one LY 143->144 edge). Clobbers A.
WaitFrame:
.notVBlank
    ldh a, [rLY]
    cp 144
    jr z, .notVBlank
.toVBlank
    ldh a, [rLY]
    cp 144
    jr nz, .toVBlank
    ret

; Latch the RTC and return SECONDS in A.
; The latch needs a 0->1 transition on $6000; without the 0 first the latched
; registers never re-sample and every read returns the same stale second.
ReadSeconds:
    ld hl, $6000
    ld [hl], 0
    ld [hl], 1
    ld a, $08
    ld [$4000], a
    ld a, [$A000]
    and $3F
    ret

; Wait for SECONDS to change; BC = frames waited, or $FFFF if the clock never
; ticked within TICK_CAP frames.
;
; The cap is not defensive padding, it is the whole difference between a probe
; and a brick: v1 of this ROM waited forever, so on a cart whose MBC3 has no RTC
; it sat on a blank screen and reported nothing at all. A cart that cannot tick
; is a RESULT -- it should print $FFFF and move on, and rows 4-5 below then say
; whether the $A000 window responds at all.
WaitTick:
    call ReadSeconds
    ld d, a
    ld bc, 0
.loop
    call WaitFrame
    inc bc
    ld a, b
    or a
    jr nz, .giveUp                 ; bc >= 256
    ld a, c
    cp TICK_CAP
    jr nc, .giveUp
    push de
    call ReadSeconds
    pop de
    cp d
    jr z, .loop
    ret
.giveUp
    ld bc, $FFFF
    ret

; Wait 30 frames (~half a second), so a "reset the divider" answer and a
; "keep the remainder" answer land far apart.
WaitHalf:
    ld b, 30
.loop
    push bc
    call WaitFrame
    pop bc
    dec b
    jr nz, .loop
    ret

StoreResult:
    ld a, [wRow]
    ld l, a
    ld h, 0
    add hl, hl
    ld de, wResults
    add hl, de
    ld a, b
    ld [hli], a
    ld a, c
    ld [hl], a
    ld a, [wRow]
    inc a
    ld [wRow], a
    ret

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a        ; $11 on CGB/AGB, $01 on DMG, $FF on MGB
    call LcdOff
    call ClearVram
    call InitVideo
    xor a
    ld [wRow], a

    ; Cart RAM + RTC on.
    ld a, $0A
    ld [$0000], a

    ; Clear the halt bit (6) of DH ($0C) so the clock is definitely running.
    ld hl, $6000
    ld [hl], 0
    ld [hl], 1
    ld a, $0C
    ld [$4000], a
    ld a, [$A000]
    and %10111111
    ld [$A000], a

    call LcdOnText

    ; --- row 0: eight whole RTC seconds ---------------------------------
    call WaitTick                  ; align to an edge first
    ld hl, 0
    ld e, 8
.rate
    push de
    push hl
    call WaitTick
    pop hl
    add hl, bc
    pop de
    dec e
    jr nz, .rate
    ld b, h
    ld c, l
    call StoreResult

    ; --- row 1: SECONDS write -> next tick -------------------------------
    call WaitTick
    call WaitHalf
    ld a, $08
    ld [$4000], a
    ld a, [$A000]
    ld [$A000], a                  ; write back what was there: only the WRITE
    call WaitTick                  ; itself is under test, not a new value
    call StoreResult

    ; --- row 2: MINUTES write -> next tick -------------------------------
    call WaitTick
    call WaitHalf
    ld a, $09
    ld [$4000], a
    ld a, [$A000]
    ld [$A000], a
    call WaitTick
    call StoreResult

    ; --- row 3: halt -> resume -> next tick -------------------------------
    call WaitTick
    call WaitHalf
    ld a, $0C
    ld [$4000], a
    ld a, [$A000]
    or %01000000
    ld [$A000], a
    call WaitHalf
    ld a, $0C
    ld [$4000], a
    ld a, [$A000]
    and %10111111
    ld [$A000], a
    call WaitTick
    call StoreResult

    ; --- row 4: raw DH ($0C) in the high half, raw SECONDS in the low ----
    ld hl, $6000
    ld [hl], 0
    ld [hl], 1
    ld a, $0C
    ld [$4000], a
    ld a, [$A000]
    ld b, a
    call ReadSeconds
    ld c, a
    call StoreResult

    ; --- row 5: raw byte at $A000 with the bank set to 0 (plain cart RAM),
    ; --- so "the window answers but the RTC does not" is distinguishable
    ; --- from "the window is dead".
    xor a
    ld [$4000], a
    ld a, [$A000]
    ld b, a
    ld a, [$A001]
    ld c, a
    call StoreResult

    call DrawResults
.done
    halt
    jr .done

DrawResults:
    ; PutByte clobbers B and C (it does `ld c, a` internally) and preserves
    ; only D and E, so neither the loop counter nor the second half of a
    ; result can live in a register across a call. The counter lives in wRow
    ; and each result is re-read from WRAM between the two halves.
    call LcdOff
    xor a
    ld [wRow], a
.rows
    ld a, [wRow]
    add a                          ; row * 2 = screen line
    ld d, a
    ld e, 1
    ld a, [wRow]
    call PutNibble                 ; leading digit = row number

    ld a, [wRow]                   ; high byte
    ld l, a
    ld h, 0
    add hl, hl
    ld bc, wResults
    add hl, bc
    ld a, [hl]
    ld e, 3
    call PutByte

    ld a, [wRow]                   ; low byte, re-read
    ld l, a
    ld h, 0
    add hl, hl
    ld bc, wResults + 1
    add hl, bc
    ld a, [hl]
    ld e, 5
    call PutByte

    ld a, [wRow]
    inc a
    ld [wRow], a
    cp ROWS
    jr nz, .rows
    call LcdOnText
    ret

INCLUDE "common.inc"
