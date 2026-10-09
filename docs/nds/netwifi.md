# DS wireless across machines: local play, Download Play, online

Status: **prototype + plan**. Two DS in two processes share one radio over
a TCP socket (`tools/ndsnet.nim`) and give exactly the one-process result.
The prototype also shows that this radio-level link cannot run at full
speed across a real network. Network play should exchange inputs, with both
consoles running on each peer. docs/nds/wifi.md covers the radio model this
builds on.

## The prototype: one Air across two processes

`io/wifi.nim`'s `Air` gets two hooks, `on_post` (a console here started a
frame) and `on_ack` (a console here ACKed a frame from a console elsewhere),
and two entry points, `post_remote` and `ack_remote`. Stations are numbered
from `Air.base`, so process 0 holds station 0 and process 1 holds station 1,
with the same numbering and MACs that `ndsair` gives in one process.
In-process behaviour is unchanged.

`tools/ndsnet.nim` runs one DS per process. The listener is station 0 and
the connecting side is station 1. Messages are `[len][kind][sent ns][body]`
over TCP with Nagle off:

| Message | Body | When |
|---|---|---|
| HELLO | station, master clock at start | once; both take the larger start as air time 0 |
| FRAME | sender, serial, kind, channel, rate, aid, start/data/stop air times, IEEE bytes | when a local frame's carrier starts |
| ACK | sender, serial | when the local hardware ACKs a remote station's frame |
| CLOCK | air time reached | after every step |
| DONE | - | end of run |

**Sync rule (exact).** Both sides step in `AIR_QUANTUM` (4096 cycles, 61 us)
on one air clock. A side may run a step only if the step ends no more than
one lead (default one quantum) past the other side's last CLOCK. Frames and
ACKs are sent before the CLOCK that covers them. A frame first acts on a
receiver at the end of its preamble, which is at least 96 us after it is
posted, so it always arrives in the receiver's future. An ACK is awaited a
SIFS, a long preamble and the ACK time after the frame (more than 250 us).
No rollback is needed, and the result does not depend on how the processes
are scheduled.

```
nim c -d:danger -d:test_harness --path:src --path:tools -o:ndsnet tools/ndsnet.nim
./ndsnet --listen 7070 --rom wifi_link.nds --press A@0-10 --frames 120 &
./ndsnet --connect 127.0.0.1:7070 --rom wifi_link.nds --frames 120
#   [--lead-us N] [--rtt-ms N] [--free-quiet] [--save S] [--rtc D] [--bios DIR] [--shots ..]
```

`--rtt-ms` holds each received message until RTT/2 after it was sent; both
processes are on one host and share its monotonic clock. `--lead-us` loosens
the rule. `--free-quiet` lets a side whose radio is quiet
(`wifi.radio_quiet`: not listening, not sending, no reply due) run without
waiting. Frames that the other side sent while this side was quiet are
dropped, and a radio that turns on inside a step may hear frames up to one
quantum late (counted as late).

### Results

All checks are byte comparisons of main RAM (md5) and of both screens
against `ndsair`, the one-process lockstep, printed by both tools.

| Run | Result |
|---|---|
| wifi_link host + client, 120 frames, two processes | RAM and screens of both identical to ndsair; every result word equal (4 PINGs and 4 PONGs ACKed, 8 multiplay rounds with no missed slave); 0 late |
| same with `--free-quiet` | identical; 1847 quiet steps during boot |
| SoulSilver (New Bark save, main menu) beside a wifi_link host, 1500 frames | the scan received 20 beacons, as in one process; RAM and screens identical; 0 late (strict), 1 late with `--free-quiet` |
| `tests/nds_wifi_test.nim` new check | two Airs bridged between quanta through the hooks give the one-Air RAM |

**A model fix it found.** A receiver used to decide whether it was on a
frame's channel when the sender *posted* the frame. Inside a quantum the two
machines can be up to 61 us apart, and SoulSilver's scan changes channel
every ~11 ms. So the channel at post time depended on stepping, and the
same scan heard 19 or 20 beacons. The receiver now checks the channel at
the frame's preamble end and again at its end, which is the frame's own air
time. Before the fix, one process heard 19 and two processes heard 20.
After it, both hear 20. The wifi and save-state suites still pass. The p12
regression path never touches the wifi registers.

### What looseness the games tolerate

These are wifi_link pairs run with a longer lead. Frames then arrive late,
and the receiver takes them at its current time.

| Lead | Late frames | Outcome |
|---|---|---|
| 61, 90, 120 us | 0 | exact |
| 250 us | 38 (beacons) | result words and RAM still identical |
| 500 us | 86 | **broken**: client PINGs not ACKed (TX header 0003h, 8 retries each), 0 of 8 multiplay rounds answered |
| 1, 4, 16.7 ms | 79-103 | broken the same way |

The hardware protocol allows about 250 us of slack. The ACK window and the
multiplay reply slot are both hardware timed: a reply must be on the air
10 us after the CMD ends, and the host's hardware closes the round about
364 us later. A game's wireless manager cannot loosen either one. Any
scheme that runs the two machines further apart than the ACK window loses
every unicast frame and every multiplay round.

### Speed versus round trip

The exact rule lets a side get one lead ahead of the other side's clock as
it was half a round trip ago. Throughput is therefore bounded by
lead / (RTT/2) of real time, whatever the CPU speed.

| RTT | Bound, lead 61 us (exact) | Measured | Bound, lead 250 us (loose limit) | Measured |
|---|---|---|---|---|
| 0 (same host) | CPU-bound | 149-154 % (quiet host); 4-61 % (loaded) | CPU-bound | 40 % (loaded) |
| 0.2 ms (wired LAN) | 61 % | 5 % (loaded) | 100 % | - |
| 1 ms | 12 % | 2.1 % | 50 % | 28 % |
| 5 ms (Wi-Fi LAN) | 2.4 % | 1.2 % | 10 % | 4.9 % |
| 20 ms (same city) | 0.6 % | 0.43 % | 2.5 % | 1.7 % |
| 60 ms (internet) | 0.2 % | 0.17 % | 0.8 % | 0.68 % |

How it was measured: wifi_link pairs, wall clock of N frames, both processes
on this Mac. During the sweeps other agents' jobs held the load average at
400-550 on 8 cores, so every wake-up waited for a CPU, and the
low-latency points sit far below the bound. The same SoulSilver pair ran at
154 % in a quiet moment and at 16 % under load. The high-RTT points match
the bound closely, because there the injected latency dominates.
Chart: speed_vs_rtt.png in the investigation's scratch directory.

Raising the lead does not change the conclusion. The physics cap is the
96-us preamble, and the protocol's tolerance is about 250 us. Even with
250 us of lead, Wi-Fi LAN gives 10 % and the internet under 1 %.
`--free-quiet` helps only while a radio is off. That is most of a game, but
none of the time spent inside a wireless session.

## 1. Local wireless across machines: the sync model that works

| Model | Exact? | Speed | Verdict |
|---|---|---|---|
| Radio-level lockstep (this prototype) | yes | lead/(RTT/2): 61 % on wired LAN at best, under 3 % on Wi-Fi LAN or internet | same host only (two windows or tabs); one process is simpler there |
| Radio-level, loose (lead > 250 us) | no | better, still RTT-bound | breaks ACKs and multiplay: unusable |
| Radio-level, speculative (time warp) | yes | every round's CMD -> REPLY -> ACK is a causal round trip inside ~600 us: rolls back every round | no |
| **Both consoles on each peer**, inputs exchanged (delay, then rollback) | yes | 100 % at any RTT, with ceil(RTT/2 / 16.7 ms) frames of input delay (1 frame up to 33 ms, 2 up to 66 ms) or rollback | **recommended** |
| WM-level bridge (fake the peer's replies locally) | no | full | only for loose protocols (lobbies, chat); frame-locked games break |

The recommended model is the one the GBA netplay already uses: send inputs,
not bus or radio traffic. It is exact because the in-process Air is
deterministic. The existing test shows that machine order inside a
quantum does not matter, and this change removes the one stepping
dependency found so far. What it needs:

1. **Determinism.** Inputs (keys, touch, lid, mic) are the only outside
   source. The RTC comes from emulated time (`--rtc`), there is no host
   clock, and the mic is silent or sent with the inputs. Add a two-peer
   replay check: same inputs, same frames. 1-2 days.
2. **Session start.** Save states already cover the wifi state (rx queue,
   transmitter stage; docs/nds/savestate.md), so a session starts from one
   state of both machines, sent at connect, the way GB/GBA netplay sends
   SRAM. Both peers need both ROMs. The GBA link already sends a ROM the
   friend lacks and skips one the friend has; reuse that. 1-2 days.
3. **Input exchange** over the existing DataChannel / `linkproto` framing,
   with a fixed delay first. Web UI: pick a ROM per console, choose whose
   screen you see (yours by default). 2-3 days.
4. **Rollback** with the rewind machinery: 3-5 days, then tuning.
5. **CPU.** Two DS per peer, plus re-simulation for rollback. Native: the
   pair ran ~65 fps on a loaded desktop (wifi.md). Web on an M-series Mac:
   SoulSilver's intro takes 5 ms a frame, so two DS fit easily, with room
   for 1-2 frames of rollback. iPhone has no JIT, and one DS is already the
   heavy case. Two DS on a phone is the main risk: measure before
   promising rollback there. Delay-only play needs exactly 2x.

Total: ~1.5-2 weeks to delay-based play on web and desktop, plus ~1 week
for rollback. iOS depends on the 2x CPU measurement.

The prototype's wire protocol stays useful in three places: a same-host
test rig (two processes, or two tabs over BroadcastChannel), a LAN
debugging aid, and the transport for (3) below, where the virtual access
point is just another remote station.

## 2. DS Download Play

The host's cart runs WMB. It sends beacons with icon and name snippets,
then over multiplay a name request, the RSA-signed header and the ARM9 and
ARM7 binaries in 1F8h-byte packets (GBATEK "DS Download Play"). The client
has no card. What is needed beyond (1):

- **A cardless client that can boot from the air.** Two options:
  - *Firmware*: firmware boot already works with the user's dumps
    (docs/nds/boot.md). Booting with an empty slot and choosing DS Download
    Play runs Nintendo's real client, and the Nintendo-signed binaries pass
    its RSA check on their own. Needs the user's firmware dump. 2-4 days,
    mostly finding what the firmware waits on.
  - *HLE client*: a Nim station on the Air with no CPU. It speaks the WMB
    client side (auth/assoc, the name reply, replies asking for the next
    packet), collects the image, then direct-boots a second machine with it
    and the 27FFC40h boot-info block. No dumps needed. 3-5 days.
- **Across the network**, with both consoles on each peer: each peer must
  run the host's console, so each needs the host's ROM. Download Play over
  the internet therefore means "send the friend the cart", which the GBA
  link already does. That is the honest description. The client console is
  then the cardless one above, on both peers.
- **Library UI**: a "Download Play" entry that boots an empty-slot machine
  next to the host's game. 1 day.

## 3. Online play (Nintendo Wi-Fi Connection)

The service shut down in 2014. Community services carry DS games: the user
points the DS's DNS at them, and they implement Nintendo's login,
connection test and GameSpy matchmaking. DS online play is infrastructure
mode. The game's DWC/SOC stack runs on the ARM9 and WM on the ARM7, and the
access point comes from the firmware's three WFC slots (3FA00h-3FCFFh;
open or WEP only for DS-mode games). Infrastructure mode is tolerant of
timing: TCP/IP timeouts are in seconds, so no lockstep is needed. The AP
can be emulated in-process, and network latency is just latency.

What the emulator needs:

1. **A virtual access point on the Air** (a Nim station, no CPU): beacons
   for one SSID, probe, authentication and association responses, the ACK
   behaviour the DS expects, and power-save buffering if games use it. Make
   it an open network so the WEP engine is not needed: the DS accepts open
   APs. 2-3 days.
2. **A user-space IP stack behind it**: 802.11 data <-> LLC/SNAP <-> IPv4,
   ARP, a DHCP server (address, gateway, DNS = the AP), a DNS proxy that
   answers Nintendo's WFC host names (`*.nintendowifi.net` and the GameSpy
   names) with the chosen service and forwards the rest, UDP NAT, and TCP
   termination mapped to host sockets. Writing it costs about 1-1.5 weeks
   in Nim; linking a small permissively licensed user-mode TCP/IP stack in
   C costs about 4-5 days of glue.
3. **Host transport**:
   - *Native (desktop, iOS)*: BSD sockets, no relay needed. iOS allows
     outgoing sockets.
   - *Web*: pages cannot open raw TCP/UDP. A WebSocket relay carries the
     sockets (connect, data, close, plus UDP datagrams). It is a new Nim
     server next to the signaling server, and it must allow only the chosen
     service's hosts and ports: an open relay is an abuse magnet. 3-4 days,
     plus hosting and its bandwidth.
4. **TLS and certificates**: none in the emulator. The relay passes bytes
   through, so the game's own SSL client talks end to end with the service.
   The services already accept the DS's old SSL, which is why a DNS change
   is all a real DS needs. No certificate patching and no Nintendo keys.
5. **Setup**: preset WFC slot 1 in the synthesized firmware (our SSID, DNS
   from DHCP), so games connect with no setup screen. A user with a real
   firmware dump gets the slot written the same way (1 day). **Give each
   install its own console MAC** (and the firmware user ID derived from
   it). Today every synthesized firmware has the same MAC, and the
   services key friend codes and bans on it. 1 day.
6. **Per-game testing** (Mario Kart DS, Pokemon Gen 4/5 GTS and Wi-Fi Club,
   Tetris DS, ...): 1 week, with fixes after that.

Total ~4-5 weeks: core 2-3 weeks, relay and ops 1 week, games 1 week.

Risks:

- We depend on third-party services: their uptime, terms, and which games
  they support. Some of them ban emulators or shared MACs.
- Running a relay costs money and needs an allowlist, rate limits and
  abuse handling.
- Nintendo trademark: user-facing text should name the service, not
  "Nintendo WFC".
- Game-to-game UDP in matches (Mario Kart DS) through the relay adds the
  relay's RTT, which is acceptable for those games.
- DSi-enhanced games use WPA only in DSi mode, which is out of scope.

## Effort summary

| Item | Estimate | Depends on |
|---|---|---|
| Inputs-only two-console netplay, delay-based (web + desktop) | 1.5-2 weeks | save states (done), GBA link transport and ROM transfer |
| Rollback on top | 1 week | rewind; 2x CPU headroom (measure on iPhone) |
| Download Play: HLE client (or firmware client with dumps) | 3-5 days (2-4) | the above for network play |
| WFC online: AP + IP stack + native sockets | 2-3 weeks | nothing |
| WFC on the web: WebSocket relay + hosting | 1 week | the above |
| Radio-level link (this prototype) to a product | not recommended beyond same-host tests | - |

## Open decisions

- Should network DS play be inputs-only with both consoles on each peer?
  That is recommended, and it means each peer runs 2 DS and both have both
  ROMs, sent at connect as the GBA link does.
- Is shipping the host's ROM to the friend acceptable for Download Play
  over the internet? There is no other way to run it there.
- Online: which community service to target, whether dingbat runs a
  WebSocket relay for the web build, and per-install MAC generation, which
  is needed before any online play.
