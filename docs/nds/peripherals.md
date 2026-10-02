# DS system peripherals: RTC interrupts, SPI, power manager, touchscreen, mic, sleep and lid

The ARM7's small devices: the RTC and its interrupt wire (RCNT), the SPI
bus with its three devices (power manager, firmware flash, touchscreen
controller with the microphone on its AUX input), HALTCNT sleep and the
hinge. Code: `src/dingbat/nds/io/{rtc,spi,mic,input}.nim`, sleep in
`nds.nim`, RCNT/HALTCNT in `bus7.nim`. Tests: `tests/nds_periph_test.nim`
(`nimble test_ndsperiph`) and our ROM `tests/nds/src/periph_suite`
(`tests/nds/tools/build_periph.sh`). Black-box reference runs:
docs/oracles.md, "NDS core", peripheral rows.

Sources: GBATEK ("DS Real-Time Clock", "DS Serial Peripheral Interface
Bus", "DS Touch Screen Controller (TSC)", "DS Power Management Device",
"DS Power Control", "DS Firmware Serial Flash Memory", "DS Keypad", "DS
Interrupts", "BIOS Halt Functions", "SIO General-Purpose Mode"); the Seiko
S-35190A datasheet Rev.4.2 (ABLIC), the RTC's family member, whose bit
numbers run the other way round (its B7 is GBATEK's bit 0); the TI TSC2046
datasheet (SBAS265G).

## Before

RTC registers and the clock, no interrupts (`TODO(rtc)`); RCNT read 8000h
and ignored writes. SPI replies and IF.23 at the start of a transfer, busy
flag for 8 bits. Power manager: 4 registers, mirrored by `and 3`, no DS-Lite
register 4. TSC: X/Y only, AUX = 800h, everything else 0. Firmware flash:
no busy time, erase on the third address byte. HALTCNT sleep = halt.
EXTKEYIN's lid bit had no setter, no lid IRQ. No microphone.

## RTC interrupts and RCNT

The S-35180 has one open-drain /INT pin, wired to SIO SI. Status 2 bits 0-3
(INT1FE, INT1ME, INT1AE, 32kE) pick INT1's mode, bit 6 enables alarm 2;
both drive the pin (datasheet Table 11):

| stat2 | INT1 | /INT low |
|---|---|---|
| x001, x101 | selected frequency (INT1 register bits 0-4 = 1, 2, 4, 8, 16 Hz) | while any selected wave is in the first half of its period; periods aligned to the seconds counter (Figures 19/20) |
| x010, x110 | per-minute edge | from the first minute carry after selection until the mode is left |
| 0011 | minute-periodical 1 | seconds 0-29 of each minute, from the first carry |
| 0111 | minute-periodical 2 | 7.81 ms (256 ticks) after each carry |
| 0100 | alarm 1 | from a minute carry whose time matches (bit 7 of each alarm byte enables that field's compare: weekday, hour with its AM/PM bit as the hour register reads, minute) until INT1AE clears; sets status 1 bit 4 |
| 1xxx | 32 kHz output | half of each crystal tick |
| bit 6 | alarm 2 | as alarm 1, status 1 bit 5 |

The flags read-clear; the pin is released only by leaving the mode. Alarms
compare at minute carries, not when the time is written (Figure 27/28). The
INT1 register is 3 bytes while stat2 bit 2 is set, else the 1-byte
frequency register, which is alarm 1's minute byte (GBATEK).

RCNT 4000134h: in general-purpose mode (bits 15-14 = 10) bits 0-3 read the
SC/SD/SI/SO lines: an output reads what it drives, SI as input the /INT
wire, the others their pull-ups (1). SI falling raises IF.7 when RCNT.8 is
set; turning RCNT.8 on with SI already low does not (GBATEK). With SI as a
driven-high output (8144h) the pin still pulls it low.

Time is kept in 32768 Hz ticks: host time, or with `set_fixed_clock`
(ndsrun `--rtc`) a start plus emulated time. An `evRtc` event is booked for
the next moment the pin can change (a minute carry, a 1/32 s boundary in
frequency mode, the end of a pulse); none when nothing is selected, so games
that only read the clock (SoulSilver reads date/time, status 1 and 2) cost
nothing. The clock-adjust register is a rate: bits 0-6 = N, N = 1..63 is
N x 3.052 ppm faster, 64..127 is (128 - N) steps slower, bit 7 makes the
step 1.017 ppm (Tables 13-15); the chip corrects in jumps every 20/60 s, we
spread it. Reset (status 1 bit 0) gives the datasheet's initial registers
and 2000-01-01.

Assumed: a time write restarts the sub-second divider (an alarm at 00:00
fires exactly 2 s after writing 23:59:58; the reference run takes 1.87 s,
docs/oracles.md); the DS's
SC/SD/SO pull-ups. Not modelled: the 7.81 ms re-trigger windows of the
per-minute modes, DSi extended commands, the power-on 1 Hz output (direct
boot leaves stat2 = 0).

## SPI bus

SPICNT 40001C0h, SPIDATA 40001C2h. A write to SPIDATA while bus-enabled
starts a transfer of 8 bits (16 in the "bugged" mode, bit 10) at the baud
rate in bits 0-1 (4 MHz, 2 MHz, 1 MHz, 512 KHz): busy (bit 7) for that
long, then `evSpi` puts the reply in SPIDATA, drops chip select unless bit
11 (as it was at the start) holds it, and raises IF.23 if bit 14 is set.
The device answers when the transfer starts; SPIDATA shows the previous
reply until the end. A write while busy is ignored (Assumed). In 16-bit
mode the device sees the byte then 00h (Assumed) and SPIDATA shows the
second reply (GBATEK).

| baud | master cycles per byte | periph_suite RES1-4 (bus cycles incl. ~27 of polling) | reference run (docs/oracles.md) |
|---|---|---|---|
| 4 MHz | 135 | 94 | 100 |
| 2 MHz | 269 | 166 | 166 |
| 1 MHz | 537 | 298 | 298 |
| 512 KHz | 1023 | 538 | 544 |

## Power manager (SPI device 0)

Index byte (bit 7 = read) then data. Old DS (Mitsumi 3152A): registers 0-3,
mirrored through 7Fh. DS-Lite (3205B, picked when the firmware header's
console type 1Dh is 20h, 63h or 57h): 0-4, 5-7 mirror 4, 8-7Fh mirror 0-7.

| reg | bits | dingbat |
|---|---|---|
| 0 | amp, mute (old DS only), lower/upper backlight, LED blink/speed, power off | R/W bits 0-6; writing bit 6 sets `power_off`: both CPUs and the clock stop, both screens go black, no sound, nothing wakes it (`powered_off()`, wasm `nds_powered_off`; the reference runs go black too, docs/oracles.md). After direct boot 0Dh (amp, both backlights: what the firmware leaves, Assumed) |
| 1 | battery low | read-only, `set_battery_low` |
| 2 | mic amp enable | bit 0 |
| 3 | mic gain 20/40/80/160 | bits 0-1 |
| 4 (Lite) | backlight level, force max, external power, 4 in bits 4-7 | level from firmware user settings 64h bits 4-5 (Assumed the boot applies it); force-max with external power reads level 3; `set_external_power` |

`backlight(n, top)` exposes bits 2/3 to frontends (screens dark when off).

## Touchscreen controller (SPI device 2, TSC2046)

Control byte: start bit 7, channel bits 4-6, 8-bit mode bit 3, single-ended
bit 2, power-down bits 0-1; the reply is a zero bit then 12 (8) bits MSB
first over the next two bytes.

| ch | reads |
|---|---|
| 0 / 7 | TEMP0 738 / TEMP1 881 (single-ended): TSC2046 600 mV at 25 C, TEMP1 - TEMP0 = T/2.573 mV, at the DS's 3.33 V reference; GBATEK's (TP1-TP0) x 8568/4096 gives 299 K |
| 2 | battery input, grounded: 0 |
| 1 / 5 | Y / X from the firmware calibration (released FFFh / 0); the ADC aims at the pixel's centre with the calibration screen values taken as pixel numbers, which libnds/calico converts back to the same pixel (GBATEK's formula with its scr1-1 term lands one lower) |
| 3 / 4 | Z1 / Z2 from a resistive model: Y+ at VREF, X- at ground, Z1 = X plate at the contact, Z2 = Y plate; released 0 / FFFh. Plates 400 ohm, contact 1000 ohm (Assumed); GBATEK's pressure formula gives back 1000 |
| 6 | AUX = microphone (below) |

In differential mode only X, Y, Z1, Z2 exist (GBATEK); 0, 2, 6, 7 read 0
there (Assumed). /PENIRQ (EXTKEYIN bit 6 low while touching) is enabled
by power-down modes 0 and 2 and disabled by 1 and 3, as the last control
byte left it. SoulSilver reads TEMP0 every frame and X/Y with mode 1 then
TEMP0 with mode 0; its frames do not change.

## Microphone

`push_mic(n, samples, rate)` queues mono int16 samples (`io/mic.nim`). A
conversion of channel 6 at master cycle t reads the queue where t has got to
since the first push (linear between samples); a dry queue is silence, and
a frontend push beyond 250 ms queued drops the oldest (a single long push,
like ndsrun's whole WAV, is kept). AUX = 800h + sample x 2^gain / 128,
clamped: full-scale input reaches full scale at gain 160 (Assumed), with
the amp (register 2) off it reads 800h (Assumed). `ndsrun --mic FILE.wav[@F]`.
periph_suite samples 256 8-bit values at 16 kHz: a 1 kHz sine at
20000/32768 gives 32h..CDh with 16 rising mid-crossings.

## Firmware flash (SPI device 1, ST M45PE20)

Commands as before (READ, FAST, RDID, RDSR, WREN/WRDI, PW, PP, PE, SE)
plus DP/RDP. Page write/program and page/sector erase run when chip select
drops: WIP (status bit 0) for GBATEK's typical 11 ms / 1.2 ms / 10 ms / 1 s,
WEL reads set until it ends; while busy every command but RDSR is ignored;
deep power-down ignores everything but release. The image is changed at
once and `firmware_dirty` set for the frontend to save it (ndsrun
`--firmware-out`, wasm `nds_firmware_dirty`). periph_suite programs FFh into 3FD00h (a no-op on any flash) and
measures 1.2 ms.

## Sleep and the lid

HALTCNT (4000301h) mode 3, written by the BIOS Sleep / CustomHalt(C0h),
sets `sleeping`: the ARM7 is halted and `run_until` / `run_frame` no
longer run the CPUs or dispatch events, so the master clock, video,
timers, sound and DMA stand still (GBATEK: "most of the hardware ...
paused"; the ARM9 stopping too is Assumed). The RTC's crystal runs on:
`run_frame` spends a frame of sleep in `rtc.sleep_advance`, which counts
`slept` cycles into the fixed clock and dispatches its due checks. Sleep
ends when IE & IF has one of IF.7 (SIO/RTC), IF.12 (keypad, KEYCNT), IF.13
(GBA slot) or IF.22 (lid): the GBA Stop wake list plus the hinge; a
pending V-blank flag does not wake it. The halt then ends as usual.
Mode 1 (GBA mode) is ignored.

`set_lid(n, closed)` sets EXTKEYIN bit 7; opening raises IF.22 ("Screens
unfolding"; no enable of its own). ndsrun: `--press LID@F-L`. SoulSilver
goes to sleep four frames after the lid closes (backlights off, LCDs white)
and wakes with a fade when it opens.

The reference run agrees that the timers and the ARM9's V-blank counting stop
during ARM7 sleep (periph_suite RES37-39; docs/oracles.md).

## Frontend API (nds.nim)

`set_lid`, `push_mic`, `set_battery_low`, `set_external_power`,
`backlight(top)`, `sleeping`, `asleep()` (sleeping or powered off), `powered_off()`. The web
page and desktop frontends do not call them yet.

## Left

- A hardware run of periph_suite would settle the Assumed rows: mid-transfer
  SPIDATA, the 16-bit mode's second byte, RCNT pull-ups, the divider on a
  time write, the AUX scale and amp-off value, the differential readings,
  whether the ARM9 stops in sleep.
- The firmware's write protection (/W covers the first 256 pages) is not
  modelled; writes always land.
- Mic: no anti-alias filter; the 250 ms queue bound is a guess for live
  input.
- DSi modes (TSC in DSi mode, extra power-manager registers, RTC extended
  commands) are out of scope.
