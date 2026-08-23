# Link cable: how to use it

`multiplayer.md` carries the design notes and wire format; this is the practical guide.

## The model

A link session is lockstep over **emulated** time, not real time:

- Each core runs its own deterministic scheduler; cores free-run only within a bounded
  window of each other (in-process: 512-cycle slices; network: 16384 cycles past the
  peer's newest CLOCK beacon).
- An SIO transfer resolves at one exact emulated cycle on every participant. If a peer
  has not reached that cycle, the initiator stalls its emulated clock. Latency slows
  emulation during link activity and can never desync it.
- Transfer data and roles follow GBATEK ("SIO Multi-Player Mode", "SIO Normal Mode"):
  parent/child SI/SD/ID bits, full-duplex normal-mode exchange.

| Layer | File |
|---|---|
| SIO driver interface (`SioDriver`; null = no cable, loopback = plug wired to itself) | `src/dingbat/gba/serial.nim` |
| In-process lockstep, N cores | `src/dingbat/gba/link.nim`, `src/dingbat/gb/link.nim` |
| Wire protocol (length-prefixed LE frames: HELLO/CLOCK/TRANSFER/REPLY/BYE) | `src/dingbat/common/linkproto.nim` |
| Transport-independent protocol core (bounded-lead sync, non-blocking state machine) | `src/dingbat/gba/netcore.nim` |
| TCP transport (native only) | `src/dingbat/gba/netlink.nim` |
| Browser transport: WebRTC DataChannel + room-code signaling | `web/netplay.js`, `web/signaling/` |

## Web: local 2-player (one machine)

GBA tiles have a **2P** button: two linked cores side by side. Player 1 = keyboard +
touch, Player 2 = gamepad; independent saves (P2 under `save:<rom>-p2`, seeded from P1's);
audio is P1's. Rewind, speed, save states and sav import/export are hidden in link mode;
pause and reset act on both cores.

## Web: online play with a room code

GBA tiles also carry **HOST** and **JOIN**. Host picks the game and gets a short code
(e.g. `KJ4-Q7N`); Join enters it. Each side runs only its own core with its own save. A
**waiting for peer** badge shows while the emulated clock is stalled on the remote side.
Rewind, speed, save states, load-save and reset are hidden; pause is local. If the peer
leaves, your game keeps running and sees a yanked cable. Different ROM checksums (e.g.
Ruby↔Sapphire) are a warn-and-confirm, not a block.

Running it locally:

```
node web/signaling/server.js   # ws://localhost:8790 (or web/signaling/server.nim)
python3 web/serve.py           # http://localhost:8765
```

Open two tabs, Host in one, Join in the other. `?linkdelay=50` adds 50 ms of send latency
per side; `?signal=ws://host:port` points at another signaling server (the default is
`wss://<page-host>/signal`). Connections are STUN-only: a strict-NAT/CGNAT pair gets a
"could not connect peer-to-peer" error.

## Native: two processes over TCP

The native GUI's Link Cable window hosts or joins a TCP session. The test harness does
the same headlessly:

```
./dingbat_test <rom> --mode=netlink --listen 7788 --timeout 1200           # unit 0
./dingbat_test <rom> --mode=netlink --connect <hostA>:7788 --timeout 1200  # unit 1
```

HELLO verifies both sides run the same ROM (CRC-32). `--netlink-delay-ms N` adds
artificial per-message latency. Over the internet the listener's port must be reachable.

## Acceptance tests (CI: `.github/workflows/test.yml`)

| ROM (`tests/roms/`) | Covers | Contract |
|---|---|---|
| `linktest.gba` | Multi mode: parent/child roles, SIOMULTI latches, serial IRQs | 16 rounds, parent `0xA000\|r`, child `0xB000\|r` |
| `normlinktest.gba` | Normal 8-bit: internal/external clock, full-duplex swap, IRQs | 16 rounds, master `0xC0\|r`, slave `0xD0\|r` |
| `norm32linktest.gba` | Normal 32-bit: SIODATA32 swap | 16 rounds, master `0xA5A50000\|r`, slave `0x5A5A0000\|r` |
| `attachtest.gba` | Cable plugged in after boot (`netlink_attach`) | in-process only; `--attach-after N` cable-less frames (default 10) |

```
./dingbat_test tests/roms/linktest.gba --mode=linktest --timeout=600   # likewise normlinktest, norm32linktest, attachtest
./dingbat_test tests/roms/norm32linktest.gba --mode=netlink --link-contract=normal32 --listen 7790 --timeout 1200 &
./dingbat_test tests/roms/norm32linktest.gba --mode=netlink --link-contract=normal32 --connect 127.0.0.1:7790 --timeout 1200
```

Each prints `... PASS (16 ... rounds ...)`. The ROMs build from their `.s` sources with
`arm-none-eabi-as -mcpu=arm7tdmi` + `objcopy -O binary`; the committed binaries are what CI runs.

## What to expect during play

Stalls are normal: each transfer round-trip stalls the initiator until the peer catches
up — invisible on localhost, visible on transfer-heavy screens at 50 ms RTT. Pausing one
side stalls the other. A clean shutdown sends BYE; the survivor's game sees a yanked cable.
