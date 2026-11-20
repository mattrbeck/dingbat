# Security: what dingbat takes from outside, and what guards it

What an attacker can hand dingbat, where it lands, what stops it doing harm, and what is
still open. Written 2026-11-20 after a review of online link play, ROM and file handling;
keep it current when one of these paths changes.

## The bytes that come from outside

| From | What | Lands in |
|---|---|---|
| The player | a ROM, a zip, a save, a save state, a cheat | every core; the web library (IndexedDB), iOS's Documents, the desktop's files |
| Google Drive | the same, plus the library file (names, recents, renames) and a save-webhook address | the same, on every device signed in |
| A link friend (online) | HELLO, inputs, presses, sync and re-sync messages, a save state, a whole ROM | the rollback session (`web/netplay.js`, `ios/.../NetLink.swift`, `src/dingbat/frontend/online_link.nim`) and both cores |
| The signaling server | pairing messages, SDP | the same sessions, before WebRTC is up |

A link friend is the one that matters most: anyone who types the same room code is one,
and nothing they send waits for the player to choose a file.

## Where a bug would hurt

- **Web**: the core is wasm built with `-d:danger` (no bounds or range checks). An
  out-of-bounds access stays inside wasm's linear memory: it can corrupt the emulator, not
  escape the tab. What reaches the page's JavaScript (names, pictures, text) is the real
  risk there.
- **iOS and desktop**: native, built `-d:release` with Nim's checks on, except the hot
  loops that turn them off (`{.push boundChecks: off, ...}`, in five files) and `UncheckedArray`/`ptr` casts. A
  bug in one of those is memory corruption in a native process. A Swift read past a
  `Data`'s end ends the app.

No route from a ROM alone to code execution on the host was found (by reading the GB/GBC
and GBA cores, 2026-11-19, not by fuzzing ROMs).

## Defences

### Save states (a file, Drive, or a link friend)

- **Decompression is capped.** States are deflated; `serialize.nim` inflates through
  zlib's own inflate (vendored, `src/dingbat/vendor/zlib`) into at most
  `STATE_PLAIN_MAX` (128 MiB), so a small stream cannot ask for gigabytes
  (`common/inflate_bound.nim`).
- **Fields are range-checked on load**, not trusted: bank numbers, register indices, PPU
  position (`gb/savestate.nim` and the GBA/DS loaders), and every scheduler deadline must
  sit within `MAX_EVENT_HORIZON` of the clock (`common/scheduler.nim`). A refused state
  leaves the running machine as it was.
- **A loaded state cannot hang a frame.** `step_frame` gives up after
  `FRAME_STEP_LIMIT` steps (16 frames' worth) on GB and GBA, alone and linked; the DS
  frame has its own time limit. A machine a state left halted with its clock stopped
  plays very slowly instead of freezing the app.
- **Fuzzed**: `tools/fuzz.sh gbstate|gbastate|ndsstate` (libFuzzer, every byte but the
  length and hash the fuzzer's; a state that loads is run two frames). CI runs GB and GBA
  for a minute each; `ndsstate` runs on a desk only (the DS ROMs are not in the repo).
  Kept crash inputs: `tests/fuzz/regress/`.

### A link friend

- **Nothing of a different game crosses or boots until both players agree.** A friend
  whose ROM differs is asked about first ("Your friend is playing “TITLE”, a different
  game than you…"); until both say yes no ROM is sent or started on either side. The
  title is the cartridge header's, cleaned to printable ASCII, at most 16 characters.
- **Sizes are capped before anything is allocated**: a ROM at `RB_ROM_MAX` (48 MiB), a
  state or re-sync state at `RB_STATE_MAX` (8 MiB), the same on iOS (`romMax`,
  `stateMax`). Chunks past an announced size are dropped.
- **Messages too short for their kind are dropped whole** (`RB_MIN_LEN` on the web; iOS
  guards each read). Input frames far ahead of the session are ignored
  (`FEED_AHEAD_SLACK` in the rollback cores), so a friend cannot make one allocate.
- **Tested hostile**: `web/tests/link-fuzz.test.mjs` (80,000 seeded messages before and
  during a link), `tests/link_hostile_test.nim` (input frames, state fields, state size).
- **The signaling server cannot be swapped by a link.** `?signal=` is honoured only
  when the page itself runs on a local address (`NET_LOCAL_HOST`). The server limits
  rendezvous rate, sockets and rooms per address (`web/signaling/`).

### Files and Drive

- **Zips**: an entry over `ZIP_ENTRY_MAX` (512 MiB) is refused before decompression,
  and decompression stops at the size the zip declares (web, desktop with its CRC
  checked; iOS decodes into a fixed buffer).
- **Names from Drive are not paths.** iOS refuses a game name that is empty, `.`, `..`,
  over 255 bytes, or holds a slash or a control character (`RomLibrary.validName`). On
  the web names are IndexedDB keys.
- **What reaches the page is built as text.** Save-state labels and pictures from Drive
  go through `cleanStateMeta` (a picture must match `STATE_THUMB_URL`, a base64
  `data:image/` URL); announcements are
  set with `textContent`; no `innerHTML` takes outside data.
- **A different game under a name already in the library** is asked about (Replace or
  Keep both), or numbered when a sync finds it, so it never runs against another
  game's save.
- **Drive tokens on iOS** are in the Keychain (`TokenVault`, this device only), not in
  the app's files.

### The web page

- **Content-Security-Policy** in a `<meta>` on `index.html`, `embed.html` and
  `oauth-callback.html`, written and checked by `tools/csp.mjs`: scripts only from the
  site, the inline ones by hash, and Google's sign-in library; no inline handlers; no
  other origin's images or frames. Checked by a unit test, by the deploy after its last
  rewrite of the page, and by every browser suite (a refusal is a page error).
- `'unsafe-eval'` sits beside `'wasm-unsafe-eval'` because iOS 15's Safari knows only
  the former and refuses to compile the core without it. Injected scripts and handlers
  are still refused; the app itself uses no `eval`.

## Open

- **Room codes are typed by the players** (at least three letters or digits), so a
  stranger can sit on a likely one. The different-game question covers a squatter with
  another game, not one with the same game. Random codes plus a short confirmation phrase
  both screens show would close it.
- **`connect-src` allows any `https:` address**, because the save webhook posts to any
  address the player (or Drive) sets. Removing the webhook lets that shrink to Google's
  hosts and the signaling server.
- **The desktop's online link** has no different-game question and does not bind to
  loopback only. Desktop builds are not published now.
- **The desktop link's message parser** (`online_link.nim`) is not fuzzed.
- **ROMs are not fuzzed.** The audit above read the cores; it did not run hostile ROMs at
  scale.
- **A first-visit Update in Chrome may stall for about 30 s**: the Updating card's
  picture request can restart the old service worker mid-swap. Seen only under
  Playwright's DevTools (`web/e2e/sw-updates.e2e.mjs` stops the worker there); not
  checked in a plain Chrome.
- **Linux WebKitGTK** sends a service worker's `only-if-cached` requests to the network,
  so it would download every asset on install. No browser the app targets uses it.
