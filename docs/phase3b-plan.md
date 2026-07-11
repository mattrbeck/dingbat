# Phase 3b: internet play in the browser with room codes — implementation plan

Handoff document for the implementing agent. Prerequisites are all on main:
the wire protocol (`src/dingbat/common/linkproto.nim`, spec in
`multiplayer.md` §3a), the native TCP reference implementation
(`src/dingbat/gba/netlink.nim`), the in-process link + web 2P mode
(`src/dingbat/gba/link.nim`, `src/dingbat_wasm.nim`, `web/`), and the usage
guide (`link-usage.md`). Read all of those first.

## Target experience

- Player A: **Host** → picks a ROM → gets a short room code (e.g. `KJ4-Q7N`)
  → shares it out of band.
- Player B: **Join** → picks the same ROM → enters the code → connected.
- Both play in their own browser with their own save; trades/link features
  work; a "waiting for peer" indicator shows whenever the emulated clock is
  stalled on the remote side.

## Architecture

```
browser A                    signaling service                    browser B
wasm core ⇄ JS bridge ⇄ WebRTC DataChannel (reliable/ordered) ⇄ JS bridge ⇄ wasm core
                 ↖ room code: offer/answer + ICE via WS ↗
```

The DataChannel carries **exactly the linkproto frames** (length-prefixed LE
binary; already emscripten-clean). The signaling service never sees game
traffic and holds no state beyond live rooms.

## Work items, in order

1. **Event-driven NetLink for wasm.** `netlink.nim` blocks inside
   `stall_wait` (fine on a socket, impossible in a browser). Refactor the
   sync/stall/transfer state machine so it can be driven externally:
   - Extract the transport-independent core (bounded-lead bookkeeping,
     TRANSFER/REPLY resolution, stall predicate) from the socket pump. The
     cleanest shape: `proc feed(bytes)` for inbound frames, `proc drain():
     bytes` for outbound, and `proc try_advance(frames): AdvanceResult`
     where the result says either "advanced a frame" or "stalled waiting for
     peer (render the indicator, come back after feed())".
   - The native TCP path should be re-expressed on top of the same core so
     there is ONE protocol implementation (its acceptance tests already
     exist and must stay green — see gates).
   - New wasm exports along the lines of `netlink_init(rom, is_host)`,
     `netlink_feed(ptr, len)`, `netlink_drain(ptr, cap) -> len`,
     `netlink_tick() -> status`, `netlink_stalled() -> bool`.
2. **JS transport bridge** (`web/`): WebRTC `RTCPeerConnection` +
   DataChannel (`ordered: true`, default reliable), buffering frames to/from
   the wasm exports each RAF. Include a latency-injection dev knob
   (`?linkdelay=50`) mirroring `--netlink-delay-ms` for testing.
3. **Signaling service**: a small WebSocket service —
   `create_room -> code`, `join(code)`, then it relays the SDP
   offer/answer + ICE candidates between exactly two sockets and closes.
   Codes: 6 chars from an unambiguous alphabet, single-use, ~10-minute TTL.
   Keep the server implementation in-repo (`web/signaling/` or `tools/`)
   with a "run locally" mode (`node server.js` or a Python equivalent) so
   development and CI need no cloud account.
4. **UI**: on GBA tiles next to "2P": "Host online" / "Join online".
   Host screen shows the code + "waiting for peer"; join screen has the code
   field. In-session: reuse the 2P chrome minus the second canvas (each side
   renders only its own core); show the stalled indicator (from
   `netlink_stalled`) as a subtle "⏳ waiting for peer" badge; hide the same
   desync-hazard controls the 2P mode hides; on disconnect, surface "peer
   disconnected" and keep the local game running (the game itself sees a
   yanked cable).
5. **Acceptance**:
   - Two browser contexts on one machine + local signaling server: run the
     linktest ROM to PASS via a debug hook, then a scripted sanity of a real
     game reaching the Cable Club handshake.
   - Same with the 50 ms latency knob: must complete, slower.
   - Native gates unchanged: both mGBA suite configs at their exact
     baselines, `--mode=linktest` and the two-process `--mode=netlink`
     localhost runs PASS, state roundtrip MATCH, `nimble wasm` builds.

## Decisions for the owner (make these before/while implementing)

1. **Where does the signaling service live in production?** Options:
   Cloudflare Worker + Durable Objects (free tier is plenty; websockets
   supported), a tiny VM/container you already run, or Deno Deploy/Fly.
   The in-repo local server (work item 3) is required regardless; this
   decision only affects the deployed URL the web UI defaults to.
2. **TURN relay: yes/no for v1?** STUN alone (free, e.g. Google's public
   STUN) connects most home NATs. Without TURN, a minority of pairs
   (symmetric NAT / strict CGNAT) simply fail to connect. TURN relays all
   game traffic through your server (bandwidth cost, but link traffic is
   tiny — order of KB/s). Recommendation: ship v1 STUN-only with a clear
   "could not connect peer-to-peer" error; add TURN later if users hit it.
3. **WebRTC-first vs relay-first.** Alternative v1: skip WebRTC entirely and
   relay linkproto frames through the WebSocket signaling server itself
   (simpler: no ICE, works behind every NAT; cost: game traffic through the
   server + ~2x latency). The plan above is WebRTC-first because trades are
   latency-tolerant and P2P keeps the service free-tier-sized — but if
   implementation risk matters more than server cost, relay-first is a
   legitimate simplification. Decide before work item 2.
4. **Native clients joining rooms?** The native TCP path could join the same
   room system later via a headless WebSocket/WebRTC bridge, or stay
   IP:port-only. Suggest: out of scope for 3b, revisit on demand.
5. **GB/GBC scope.** The GB core has no SIO driver abstraction yet. Options:
   GBA-only for 3b (suggested), or implement the BGB protocol for GB as a
   separate track (interop with BGB/Emulicious — see `multiplayer.md`).
6. **Same-ROM enforcement.** HELLO already rejects CRC mismatches. Decide
   whether to allow an override for compatible-but-different ROMs (e.g.
   Ruby↔Sapphire trades — different CRCs, fully link-compatible!). This
   NEEDS product thought: strict same-CRC would block cross-version trading,
   which is half the point of Pokémon links. Suggested: relax the check to
   a warning + confirm for GBA (games negotiate compatibility themselves),
   keep strict for the linktest harness.

## Known constraints to respect

- Never free-run past a pending exchange; stalls must stall *emulated* time
  only (the RAF loop keeps running, rendering the indicator).
- The DataChannel must be reliable+ordered; the protocol has no
  retransmission of its own.
- Frame parsing must tolerate partial/coalesced delivery (length-prefix
  framing already assumes a byte stream; DataChannel delivers messages, but
  the bridge should still reassemble defensively).
- Don't regress single-core or 2P behavior; the desync-hazard control
  hiding from 2P mode applies identically.
- iOS Safari PWA: verify DataChannel availability in standalone mode early
  (it works in current WebKit, but check before building UI on top).
