# DS wireless: hardware model, local multiplayer, plan

Status: **prototype**. Two or more DS in one process share a radio (`Air`):
beacons, data frames with ACKs and retries, and the multiplay CMD -> REPLY
-> ACK round go from one console's wifi hardware to the other's at their air
times. Our test ROM runs host and client end to end; SoulSilver's main-menu
scan receives another console's beacons. Nothing crosses a network yet.

Sources: GBATEK "DS Wifi" chapters (I/O map, control, interrupts, power,
RX/TX buffers and control, timers, Multiplay Master/Slave, hardware
headers, Nintendo beacons, DS Download Play), the BlocksDS dswifi library
(MIT; `source/arm7/ntr/*`, read as a library), black-box runs of
SoulSilver and of the reference core (docs/oracles.md, "NDS core").

## The hardware in numbers

| What | Value | Source |
|---|---|---|
| Air time | preamble 192 us (long) or 96 us (short: 2 Mbit/s with W_PREAMBLE bit 2), then 8 us/byte at 1 Mbit/s or 4 us/byte at 2 Mbit/s, FCS included | GBATEK W_PREAMBLE, TX header [08h] |
| IRQ07 / IRQ01 | after the preamble / after the last bit, for every attempt | GBATEK W_IF, IRQ07 notes |
| TX order | beacon in its timeslot, then LOC3, LOC2, CMD, LOC1 | GBATEK W_TXREQ_READ |
| ACK | frames to a station (not group, not control) wait for the receiver hardware's ACK; missing: W_TX_ERR_COUNT+1, IRQ03, retry while W_TX_RETRYLIMIT lasts (07h = 8 tries); TX header 0001h okay, 0003h failed | GBATEK "Transmit Errors" |
| Beacon | at IRQ14 (W_BEACON_COUNT reload from W_BEACONINT, 1024-us "ms"); the hardware writes the sender's W_US_COUNT into the sent timestamp; W_TXSTAT 0301h + IRQ01 with W_TXSTATCNT bit 15 | GBATEK IRQ14 notes, IEEE Header |
| Multiplay host | CMD (W_TXBUF_CMD, needs W_CMD_COUNT > 0), replies awaited 16 + (10 + W_CMD_REPLYTIME) x slaves us, then the hardware's ACK to 03:09:BF:00:00:03 with missing-slave flags; TX header 0001h or 0005h with [02h] = slaves that missed; IRQ12 | GBATEK "Multiplay Master" |
| Multiplay slave | W_AID_LOW = slave number; at a CMD, REPLY1 -> REPLY2 (TX header [04h]+1), reply in its slot; no REPLY2: an empty reply, FC 0158h | GBATEK "Multiplay Slave" |
| Typical round | 1 slave, 4-byte payloads: CMD 240 us + window 364 us + ACK 224 us = 828 us | dswifi's sizes, GBATEK formulas; 830 us measured here, 832 on the reference |
| RX | address filter (own MAC, group addresses), BSSID filter (W_RXFILTER), DS direction filter (W_RXFILTER2), ring from W_RXBUF_BEGIN to END, 12-byte RX header, WRCSR 4-byte aligned | GBATEK Receive Control/Buffer, Hardware Headers |
| Channels | 1-14; Nintendo uses 1, 7, 13. A type-2 RF gets two writes per channel from firmware[0F2h + (ch-1)*6] | GBATEK "Change Channels" |

## What software touches

**Nintendo's wireless manager (WM), as SoulSilver runs it** (`-d:wifilog`
trace, New Bark save, main menu, ~600 frames). Boot: a register self-test
(FFFFh, 5A5Ah, A5A5h, then counting patterns through 018h-142h), a write
and read-back of every BB register, RF init from the firmware table, then
the MAC init in GBATEK's order. At the main menu it scans for beacons for
as long as the menu is up: per channel 1, 7, 13 it forces power down
(W_POWERFORCE 8001h), writes the channel's RF[05h]/RF[06h], resets the MAC,
sets the RX ring 4BFCh-5F60h, W_IE E0FFh (IRQ00-07, 13-15),
W_RXSTAT_INC_IE 0468h, W_RXFILTER 0581h, W_RXFILTER2 000Bh, BSSID
FF:FF:FF:FF:FF:FF, W_POWER_TX 5, W_TXREQ_SET 2, queues power-up
(W_POWERSTATE 2) and polls W_RF_PINS for RX.ON (bit 7). It then dwells
about 11 ms and moves on (before this work RX.ON never rose and each channel
timed out instead). A received beacon is handled in its IRQ handler:
IRQ06 ack, IRQ02/IRQ00, W_RXBUF_WRCSR/BEGIN/END read, W_US_COUNT read,
READCSR moved to WRCSR. It never transmits there. The p12 new-game script
(the regression path) never touches the wifi registers at all.

**dswifi** (BlocksDS, `source/arm7/ntr`): the GBATEK init, a 40 ms wait,
then waits for W_RF_PINS bit 7 after W_POWERSTATE |= 2. Multiplay host:
CMD frames with `host_time = bytes*4 + 60h`, `client_time = bytes*4 + D2h`,
`all = F0h + (client_time + 0Ah) * n`, W_CMD_COUNT = 180h + (388h +
n*client_time + host_time + 32h) / 8, and its own retry when the CMD's TX
header reads 0005h. Client: alternating REPLY1 buffers. Its `registers.h`
names the W_RXFILTER bits (0: other BSS beacons, 1-6 data subtypes, 7 MP
ACKs, 8 empty replies, 9/10 other BSS management, 11 other BSS
control/data) and W_RXFILTER2's (ignore STA->STA, STA->DS, DS->STA, DS->DS
data). devkitPro's calico (`wlmgr`, which libnds 2 uses) has infrastructure
mode only: `WlMgrMode_LocalComms` is "not yet supported".

## The model

`io/wifi.nim` keeps the register model it had (widths, resets, IRQ edge,
power, timers, BB/RF) and adds:

- **Transmitter**: one frame at a time; stages preamble -> data -> (ACK
  wait | replies window) -> done. LOC frames get W_TX_SEQNO (unless LOCn
  bit 13, TX header [04h] or W_TX_HDR_CNT bit 2), the ACK wait and retries;
  beacons their timestamp; the CMD its reply window and the hardware ACK;
  W_CMD_COUNT counts down in 10-us steps; W_TXBUF_CMD bit 15 only sticks
  while it runs.
- **Receiver**: per received frame IRQ06 after the preamble, then at its
  end the filters, the ring (dropped when it would reach READCSR: W_RXSTAT
  RXBUF-full, no ACK, so the sender retries), the RX header (type nibble
  1/0/5/8/C/D/E/F, bit 4, bit 15 BSSID match), W_RXSTAT "received okay"
  (IRQ02 when enabled), W_RX_COUNT, the 5F6Eh log, IRQ00, and the ACK.
  Statistics and W_CMD_STAT clear when read. W_RXBUF_RD_DATA wraps END ->
  BEGIN.
- **Air**: `AirFrame`s carry the IEEE frame (no FCS), rate, channel and
  air times. A frame is posted when its carrier starts; each other station
  on the channel books IRQ06 at the frame's data start and delivery at its
  end. The channel is matched from the RF writes against the firmware's
  table (0 = unknown, hears everything: the synthesized firmware has no
  table). W_RF_PINS: 0044h preamble, 0046h data, 0084h listening.
- **Lockstep** (`nds/air.nim`): `AirLink` runs every machine to the same
  master-cycle target in 4096-cycle (61 us) quanta. Every cross-console
  effect lands at least a preamble (96 us) after it is posted, so it is
  always in the receiver's future; ACKs and replies are later still. No
  rollback, and the order machines run within a quantum does not matter.
  `firmware_with_mac` gives each console its own MAC (CRC fixed).
- `tools/ndsair.nim`: ndsrun for N machines (per-machine ROM, --press,
  --save), frame counts per console.

Assumed (no source pins them): 802.11b's 10-us SIFS before an ACK and each
reply slot; the ACK at the frame's rate with a long preamble; slave k's slot
at CMD end + 10 + k*(time + 10) us; the CMD ACK body [00h] = 0; power-up
(and IRQ15 auto-wakeup) at once with RX.ON; RSSI bytes C1h/30h; a reply slot
that finds the transmitter busy is skipped; a full ring keeps one halfword
free.

Not modelled: collisions, carrier sense and backoff (frames never
collide; a station hears frames even while another is on the air, but not
while it transmits itself); the CMD's own hardware retries inside
W_CMD_COUNT and IRQ12 on expiry; WEP; the DS Lite's type-3 RF channel
table; NAV/duration, TIM updates, W_CONTENTFREE; W_POWERFORCE's delayed
path; save states of the new state (rx queue, transmitter stage, Air).

## Evidence

- `tests/nds/src/wifi_link` (ours, C, no library; `build_wifi.sh`): both
  roles in one ROM, A held at boot = host. On two machines (nds_wifi_test,
  26 frames): client sees beacons (RX header 0011h, 2 Mbit/s, 84 bytes,
  timestamps 65536 us apart, game ID from the tag), 4 PINGs and 4 PONGs all
  ACKed (RX header 8018h), 8 multiplay rounds with no missed slave (W_TXSTAT
  0B01h), 8 REPLYs at the host (801Eh, the client's 8th payload), 8 CMDs
  (801Ch) and 8 ACKs (801Dh) at the client, 0 late frames.
- `tests/nds_wifi_test.nim`: the wifi blocks alone too (beacon delivery,
  RXFILTER bit 0, channels, ACK and 8 tries = 8 x 578 us, ring full and
  RD_DATA wrap). Passes with dumps and with HLE BIOS + synthesized firmware.
- Reference runs (one console; docs/oracles.md, "NDS core"): host
  alone identical on beacon W_TXSTAT/TX header, IRQ07 spacing and beacon
  data time, the 8 failed CMD rounds and their flags; CMD round 830 vs 832
  us. Client alone differs: the core reports a frame to an absent station
  sent in 248 us, no error; we keep GBATEK's 8 tries and 0003h.
- SoulSilver: p12 frames 3000/5000/8000 unchanged (e4b66d68, 6cf51b7e,
  d2ad8167); the main menu still shows CONTINUE; with `ndsair` beside a
  wifi_link host its scan received 20 beacons in 1500 frames (it listens on
  channel 7 a third of the time) and its IRQ handler consumed them.

Two SoulSilvers in one process (one at the menu, one at the title) took 19.7
s of CPU for 1300 frames against 12.4 s for one alone (native, a loaded
machine): about 65 frames/s for the pair.

## Plan

### (a) Two consoles over dingbat's WebRTC transport

The GBA link (`gba/netcore.nim`) lets each side run ahead of the newest peer
clock by a bounded lead and stalls the emulated clock otherwise; a SIO
transfer anchors to explicit cycles, so latency slows emulation but never
desyncs it. The same conservative scheme for the DS needs a lead no larger
than the shortest cross-console latency, one preamble: 96 us of emulated
time. With 20-100 ms network round trips that is under 0.5% of real time.
The MP protocol has no slack to borrow: a slave's reply must be on the air
microseconds after the CMD, and the host's hardware decides at the end of
the window whether it came.

| Approach | How | Cost | Verdict |
|---|---|---|---|
| Remote air, conservative | ship AirFrames + clocks, lead <= 96 us | speed ~RTT-bound | unusable |
| Remote air, speculative | predict the peer's frames (timing is predictable, payloads are game state every round), roll back on mismatch | rollback per round, every frame | mispredicts constantly; no |
| **Both consoles on each peer** | each peer runs both machines on one in-process Air; only inputs (keys, touch, lid, mic) cross the network, delay-based then rollback (GGPO) | 2x CPU per peer; determinism; both peers need the same ROMs, firmware, BIOS, saves | **recommended** |
| WM-level bridge | fake each slave's reply locally from the last one heard, deliver CMDs late | cheap, no 2x CPU | breaks frame-locked games (most MP games); fine for loose protocols (Pictochat-like, lobbies) |

Phases for the recommended path:
1. Determinism audit (inputs are the only outside source: RTC from emulated
   time as `--rtc` does, no host clock, mic silence or networked) and a
   two-machine replay check: same inputs -> same frames, both peers. 1-2 days.
2. Save states covering wifi (rx queue, transmitter stage, Air) on top of the
   save-state work in progress; the session starts from both peers' saves
   (sent at connect, as the GB/GBA net modes send SRAM). 1-2 days.
3. Input exchange over `linkproto`-style frames on the DataChannel: per
   frame, each peer's inputs for its console; fixed input delay of
   ceil(RTT/2 / 16.7 ms) frames first (2-4 frames at 50 ms). 2-3 days incl.
   web UI (pick ROM per console, show the peer's screen or not).
4. Rollback (predict the peer's held keys, restore and re-run both machines
   on a mismatch) using the rewind machinery: 3-5 days, then tuning.
5. Performance: two DS per peer in wasm. The native pair runs ~65 fps on a
   loaded desktop; the web build must reach 60 fps for two machines (plus
   re-simulation headroom for rollback) -- measure early, it decides
   phase 4.

Total ~2-3 weeks to a playable two-player session; Download Play titles
need (b).

### (b) DS Download Play

The host is a game (cart) running WMB: beacons (tag DDh type 0Bh with 10
snippets of icon/name), then over MP: NameRequest, RSA frame, data packets
(1F8h bytes each: header, ARM9, ARM7), Done; the client acknowledges
through its replies (GBATEK "DS Download Play"). Two ways to be the client:

1. **Real**: a second machine booting the firmware's Download Play client.
   Needs the firmware boot path (another work item) and this wifi model; the
   RSA check passes on its own since the binaries are Nintendo-signed. Most
   faithful; also gives Pictochat. ~2-4 days after firmware boot works,
   mostly finding what the firmware waits on.
2. **HLE client**: a Nim station on the Air (no CPU) that speaks the WMB
   client protocol (auth/assoc, username reply, data replies with the next
   wanted packet), collects the image, then direct-boots a second machine
   with it and the 27FFC40h block (boot indicator 2, beacon/BSSID info).
   Works without firmware dumps. ~3-5 days.

Either way the session then runs as (a); single-card play over the network is
(a) + (b).

### (c) Nintendo WFC replacement servers

DS online uses infrastructure mode: the game's own DWC/SOC stack on the ARM9,
WM on the ARM7, AP settings from the firmware's WFC slots (3FA00h-3FCFFh,
open or WEP only on DS-mode games). An emulated access point would need:
beacons and probe/auth/assoc answers for the configured SSID (WEP: RC4
on the frames with the W_WEPKEY slots, not modelled yet); LLC/SNAP <-> IP
bridging to a
user-space NAT (DHCP, DNS); in the browser, a WebSocket relay for TCP/UDP
since pages have no raw sockets; DNS overrides sending
nintendowifi.net names to a replacement service (e.g. Wiimmfi), which
handles the DS's SSL and GameSpy protocols; game-to-game UDP for matches through the relay. Mostly outside
the core: AP + NAT 1 week, relay service and DNS 1 week, per-game fixes
after. Lower priority than (a)/(b).

## Effort summary

| Item | Estimate | Depends on |
|---|---|---|
| Model gaps (CMD hardware retry, IRQ12 on W_CMD_COUNT expiry, collisions/CCA, DS Lite RF table, WEP) | 2-4 days | nothing |
| (a) phases 1-3, delay-based play over WebRTC | 1-1.5 weeks | save states |
| (a) phase 4 rollback | 1 week | rewind, performance |
| (b) HLE Download Play client | 3-5 days | (a) for the network |
| (b) firmware client | 2-4 days | firmware boot |
| (c) WFC | 2-3 weeks | AP + relay service |
