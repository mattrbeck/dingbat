# Link cable: how it works and how to use it (2026-07)

Companion to `multiplayer.md` (roadmap + investigation) — this is the
practical guide. The full wire-format spec lives in `multiplayer.md` §3a;
this file summarizes the model and documents every user-facing entry point
that exists today.

## The model in one page

A GBA link session is **lockstep over emulated time**, not real time:

- Every core runs on its own deterministic scheduler. Cores are allowed to
  free-run only within a bounded window of each other (in-process: 512-cycle
  slices; network: LEAD = 16384 cycles past the peer's newest CLOCK beacon).
- When a game starts an SIO transfer, the exchange is resolved at an exact
  emulated cycle on every participant. If a peer hasn't reached that cycle
  yet, the initiator **stalls its emulated clock** and waits. Latency
  therefore slows emulation during link activity but can never desync it —
  the same discipline BGB uses for GB link over the internet.
- The transfer data/roles are hardware-faithful (multi-mode parent/child SI/
  SD/ID bits per GBATEK, normal-mode full-duplex exchange), so games behave
  as if a real AGB-005 cable were attached.

Layers (all shipped):

| Layer | File | What it does |
|---|---|---|
| SIO driver interface | `src/dingbat/gba/serial.nim` | `SioDriver` methods (`sio_start/complete/pin_state/siocnt_status`); null driver = no cable, loopback driver = plug wired to itself |
| In-process lockstep | `src/dingbat/gba/link.nim` | `new_link(@[gba1, gba2])`, `link.step_frame()`; drives 2 cores in one process |
| Wire protocol | `src/dingbat/common/linkproto.nim` | Length-prefixed LE frames: HELLO/CLOCK/TRANSFER/REPLY/BYE; compiles under emscripten |
| Protocol core | `src/dingbat/gba/netcore.nim` | `RemoteSioDriver` + bounded-lead sync + non-blocking `feed`/`take_outgoing`/`try_advance` state machine; transport-agnostic (emscripten-clean) |
| TCP transport | `src/dingbat/gba/netlink.nim` | Native socket pump over `netcore` (blocking waits + timeout, latency sim, half-close teardown); gated out of wasm |
| Browser transport | `web/netplay.js` + `web/signaling/server.js` | WebRTC DataChannel over `netcore`'s wasm exports; room-code signaling |

## Using it today

### Web UI: local 2-player (one machine)

The GBA tiles in the home library have a **"2P"** button. It launches two
linked cores side by side (stacked in portrait):

- **Player 1** = keyboard + touch controls; **Player 2** = connected gamepad.
- Both cores run the same ROM with **independent save slots**: P2's save is
  stored under `save:<rom>-p2` in IndexedDB, seeded from P1's save the first
  time. Both flush on the usual 5-second interval and on exit.
- Audio comes from P1 only. Rewind, 2x, fast-forward, save states, and
  sav import/export are hidden in link mode (they would desync the pair);
  pause and reset act on both cores.

### Web UI: online play with a room code (two browsers, anywhere)

GBA tiles also carry **HOST** and **JOIN** buttons:

- **Host** picks the game and gets a short room code (e.g. `KJ4-Q7N`) to
  share out of band. **Join** picks the same game and enters the code.
  Once the WebRTC DataChannel is up, both play in their own browser with
  their own save; trades/link features work.
- Each side runs only its own core (single canvas). A subtle
  **⏳ waiting for peer** badge appears whenever the emulated clock is
  stalled on the remote side (routine during transfer-heavy link screens;
  more visible on a slow connection). Rewind, speed toggles, save states,
  load-save, and reset are hidden (they would desync or can't reach the
  remote core); pause acts locally.
- If your friend leaves (or the connection drops), you get a
  "your game keeps running" toast and keep playing solo — the game sees a
  yanked cable.
- **Cross-version trades** (e.g. Ruby↔Sapphire): different ROMs have
  different checksums but link fine, so a mismatch is a warn-and-confirm,
  not a hard block. Truly incompatible games fail their own in-game link
  handshake.

Running it locally (development/CI, no cloud account):

```
# 1. signaling rendezvous (zero dependencies):
node web/signaling/server.js        # ws://localhost:8790 by default

# 2. serve web/ with COOP/COEP (SharedArrayBuffer):
python3 web/serve.py                 # http://localhost:8765
```

Open two tabs, Host in one, Join in the other with the code. Dev knobs:
`?linkdelay=50` adds 50 ms of send latency per side (internet simulation,
mirrors `--netlink-delay-ms`); `?signal=ws://host:port` points at a
different signaling server. v1 is **STUN-only** — most home NATs connect;
a strict-NAT/CGNAT pair gets a clear "could not connect peer-to-peer"
error (a TURN relay is a future add). The production signaling URL defaults
to `wss://<page-host>/signal`; set it up or override with `?signal=`.

### Native CLI: two processes over TCP (LAN/internet)

The test harness exposes the network link headlessly:

```
# machine/terminal A (unit 0, listener):
./dingbat_test <rom> --mode=netlink --listen 7788 --timeout 1200

# machine/terminal B (unit 1):
./dingbat_test <rom> --mode=netlink --connect <hostA>:7788 --timeout 1200
```

- The HELLO handshake verifies both sides run the same ROM (CRC-32) and
  refuses politely on mismatch.
- `--netlink-delay-ms N` adds artificial per-message latency (internet
  simulation; the linktest passes with 50 ms — slow, but correct).
- Over the internet: the listener's port must be reachable (port forward);
  this is the raw VBA-M/BGB-style workflow. The room-code experience is
  phase 3b (`phase3b-plan.md`).
- Note this harness is **headless** (no window or input) — its PASS/FAIL
  assertions are tied to `tests/roms/linktest.gba`'s EWRAM contract. Playing
  a real game over TCP needs a windowed frontend wired to `netlink.nim`
  (native GUI wiring is a small follow-up; the web path goes through 3b).

### Acceptance tests (run in CI — see `.github/workflows/test.yml`)

Four acceptance ROMs; the three transfer ROMs run both in-process
(lockstep, `link.nim`) and over TCP (`netlink.nim` + the
transport-independent `netcore.nim` the browser bridge also uses):

| ROM | Covers | Contract |
|---|---|---|
| `linktest.gba` (`linktest.s`) | Multi-player mode: parent/child SI-SD-ID roles, 4-slot SIOMULTI latches, serial IRQs | 16 rounds, parent `0xA000\|r`, child `0xB000\|r` |
| `normlinktest.gba` (`normlinktest.s`) | Normal 8-bit mode: internal/external clock master/slave, full-duplex register swap, serial IRQs | 16 rounds, master `0xC0\|r`, slave `0xD0\|r` |
| `norm32linktest.gba` (`norm32linktest.s`) | Normal 32-bit mode: the SIODATA32 full-duplex swap (distinct path from 8-bit) | 16 rounds, master `0xA5A50000\|r`, slave `0x5A5A0000\|r` |
| `attachtest.gba` (`attachtest.s`) | Mid-game attach: role re-negotiation when the cable is plugged in AFTER boot (the browser's `netlink_attach` flow, which boot-latched linktest can't exercise) | in-process only; boots cable-less, attaches mid-run, then linktest's multi contract |

```
# in-process lockstep (deterministic, no sockets):
./dingbat_test tests/roms/linktest.gba       --mode=linktest       --timeout=600
./dingbat_test tests/roms/normlinktest.gba   --mode=normlinktest   --timeout=600
./dingbat_test tests/roms/norm32linktest.gba --mode=norm32linktest --timeout=600
./dingbat_test tests/roms/attachtest.gba     --mode=attachtest     --timeout=1200

# networked, two processes on localhost (--link-contract picks the EWRAM
# contract: multi | normal | normal32; default multi):
./dingbat_test tests/roms/norm32linktest.gba --mode=netlink --link-contract=normal32 --listen 7790 --timeout 1200 &
./dingbat_test tests/roms/norm32linktest.gba --mode=netlink --link-contract=normal32 --connect 127.0.0.1:7790 --timeout 1200
```

Each prints `... PASS (16 ... rounds ...)` on success. `--mode=attachtest`
takes `--attach-after N` (default 10) to vary how many cable-less frames run
before the link is plugged in. Build the ROMs from their `.s` sources with
devkitARM (`arm-none-eabi-as -mcpu=arm7tdmi` + `arm-none-eabi-objcopy -O
binary`); the committed `.gba` binaries are what CI runs, so the toolchain is
only needed to regenerate them.

Both ROMs are headless (no window/input) — their PASS/FAIL is tied to the
EWRAM contract above. Playing a real game over TCP needs a windowed
frontend wired to `netlink.nim` (native GUI wiring is a small follow-up;
the web path goes through 3b's browser bridge).

## Behavior to expect during real link play

- **Stalls are normal.** During link screens the two emulators ping-pong
  transfers; each round-trip stalls the initiator until the peer catches up.
  On localhost this is invisible; at 50 ms RTT, transfer-heavy screens run
  visibly slow (a full linktest took ~26 s instead of ~0.6 s). Menus and
  trades are tolerant; real-time link battles will feel it.
- `NetLink.stalled` is exposed for frontends to show "waiting for peer".
- Pausing one side stalls the other within the lead window (by design).
- Disconnects: BYE on clean shutdown; the survivor's game sees the transfer
  time out exactly as a yanked cable would.
