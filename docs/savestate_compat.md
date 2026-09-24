# Save-state format and compatibility

`src/dingbat/common/serialize.nim` (container), `src/dingbat/gba/savestate.nim`
and `src/dingbat/gb/savestate.nim` (payloads), `tests/savestate_compat_test.nim`
(`nimble test_savestate_compat`, in CI, needs no downloaded ROMs).

## The container

```
magic(8)="DGBSTATE"  version(4)  core(1)  payload_rev(1)  flags(2)
rom_checksum(4)  rom_size(4)  payload_len(4)  payload_hash(4)   = 32 bytes
[payload_len bytes of payload]
[flags bit 0: thumbnail trailer: thumb_w(2) thumb_h(2) len(4) BGR555 pixels]
[flags bit 1: whole-ROM trailer: len(4)=8 fnv1a(whole ROM file)(4) file length(4)]
```

Trailers come in flag-bit order after the payload; a reader finds one by
skipping those before it. Every v7 reader discards `flags` and accepts bytes
past the payload, so a new trailer needs no container bump (verified
against origin/main's reader for the whole-ROM one: it loads the new files
and reads the same payload and thumbnail).

`STATE_VERSION` (7) describes the **header**. Each core has its own payload
revision — `GBA_PAYLOAD_VERSION`, `GB_PAYLOAD_VERSION` — stored in byte 13
(`slot` before v7; every pre-v7 writer put 0 there, and 0 means "derive it"
from the table below). A payload change bumps one core's revision and leaves
the other core's states loadable; that split is the reason v7 exists.

The payload is flat and positional: fields written per subsystem with a
one-byte section tag between subsystems (`GBA_SEC_*` / `GB_SEC_*`), checked by
`expect_tag`. There is no field-level framing — the reader must replay the
writer's sequence with the file's revision in hand.

`parse_state_payload` refuses a state on:

| check | error |
|---|---|
| magic absent | `not a dingbat save state` |
| container newer than this build | `save state format version N not supported` |
| payload revision newer than this core reads | same |
| `core` byte differs | `created by a different core (GBA/GB mismatch)` |
| `rom_checksum` or `rom_size` differ | `belongs to a different ROM` |
| fewer bytes than `payload_len` | `truncated or corrupt` |
| whole-ROM trailer flagged but cut off | `truncated (its ROM identity is cut off)` |
| whole-ROM trailer present and not this cart's (GBA) | `belongs to a different ROM (its whole-ROM identity differs)` |
| FNV-1a of the payload differs | `payload hash mismatch` |

The size check is `<`, not `!=`: the thumbnail trailer lives outside the
hashed payload, so old readers slice by `payload_len` and ignore it.
`load_state` / `load_state_bytes` snapshot the live machine first and restore
it if applying fails midway (verified by mutation in the test).

## Revisions and migrations

Pre-v7 containers map to payload revisions by `legacy_payload_version`
(pinned in a compile-time block in the test):

| container | GBA rev | GB rev | what moved |
|---|---|---|---|
| 1 | 1 | 1 | format introduced |
| 2 | 2 | 1 | GBA CPU halt-wake fields |
| 3 | 3 | 1 | GBA bus ROM trackers + RTC epoch |
| 4 | 3 | 2 | GB serial section |
| 5 | 4 | 2 | GBA CPU `halt_resume_pop` |
| 6 | 4 | 3 | GB PPU `dots_since_frame` |

The reader migrates older revisions instead of refusing:

| migration | default applied | why it is exact |
|---|---|---|
| GBA 1→2 | `halt_wake=false`, `halt_resume_charge=0`, `halt_resume_addr=0` | rev 1 charged the BIOS return up front; nothing is ever deferred |
| GBA 2→3 | ROM trackers cold (`rom_next_addr=1`, `rom_hot=false`); `rtc.deterministic=false`, `epoch=0` | rev ≤ 2 never restored the trackers; cold costs a few cycles on one access |
| GBA 3→4 | `halt_resume_pop=false` + IntrWait stack-frame retrofit | below |
| GB 1→2 | serial idle | the port was a stub |
| GB 2→3 | `dots_since_frame=0` | states are written at frame boundaries (asserted) |
| GBA 6→7 | RTC `status` = `02h \| irq<<3 \| m24<<6`; `bias_set=false`, `bias=0`, `wday_bias=0`, `bias_host=false` | rev ≤ 6 read status back with bit 1 forced and ignored clock writes, so the clock was always the source clock |
| GB 4→5 | no `GB_SEC_SGB` section → fresh `SgbState` | see `docs/sgb.md` |
| GBA 7→8 | bus `pf_paused=false`, `pf_running=false`, `pf_count=0` | rev ≤ 7 had no pause state; a full buffer re-pauses on the next fetch, and a running prefetcher with credit is running again at once, so at most one branch's refill differs |

**IntrWait retrofit.** Rev 4 made the HLE IntrWait push `{r2, lr}` + `{r4, lr}`
on the System stack for the whole wait and pop all four on resume. A rev-3
state still holds the caller's values in those registers (the old build never
touched them while waiting), so the loader writes them where the pop expects
them and lowers sp by 16 — dead stack the new build clobbers anyway. The one
unreconstructible case, `intr_wait_active` set but the CPU not halted (the
user IRQ handler is mid-flight on that stack), raises a named `StateError`.
The test builds both shapes from `hle_intr_wait`'s definition, converts new →
old → new and asserts a byte-identical payload.

Two states stay refused: GBA rev ≤ 3 taken mid-IntrWait with the handler
running, and sub-1 MiB GBA carts' states from before the ROM-buffer resize
(below).

## ROM identity

`gba_rom_checksum` (the header's identity) hashes `min(rom_size, 1 MiB)` of
the **file**, and `rom_size` holds a fixed tag, so the header alone cannot tell
apart two carts that share their first 1 MiB (a hack that changes only later
banks). Every GBA state therefore also carries the whole-ROM trailer
(`gba_whole_rom`: FNV-1a over the whole file and its length, hashed once at
load in the same pass as the 1 MiB one, from the file rather than the
cheat-patched buffer). A reader refuses a state whose trailer is not this
cart's; a state without one (any build before the trailer) is judged by the
header alone, so it still loads, in the hack too. The header is unchanged, so
older builds still load new states (and still cannot tell the hack apart).
GB never had the limit: its header hashes the whole file and carries its real
length, and it writes no trailer. The desktop names slot files by the
whole-ROM identity and reads the 1 MiB-named ones as a fallback
(`frontend/persist.nim`).

The 1 MiB hash is of the **file** — never the
allocated buffer, whose length and padding changed when the buffer became
`next_pow2(file)` and silently re-identified every sub-1 MiB cart.
`gba_legacy_rom_checksums` recomputes the two superseded identities (the
`next_pow2` buffer and the earlier 32 MB open-bus one) as an accept-list, so
old states load and new ones carry the corrected identity. Downgrade is
one-way for sub-1 MiB carts. `GBA_STATE_ROM_TAG` is pinned to the old
`0x02000000` so `rom_size` keeps matching. An implemented-since mapper
changes `mbc_kind_tag` and refuses states of the broken emulation, which is
fine. `load_storage_state` / `load_mbc_state` refuse a backup of a different
length from the one the cart autodetects.

Netplay never puts a payload on the wire: `linkproto` exchanges inputs and
SIO words under `LINKPROTO_VERSION`, and its peer ROM check is a CRC-32 of
the file (`LinkMsg.rom_crc`; web rollback has its own `rbHash`). None of
those is `gba_rom_checksum`.

## What is deliberately not in the payload

The MP2K sound-engine HLE (`src/dingbat/gba/mp2k.nim`) keeps no state in the
payload. Everything it holds is a shadow of the game's own driver state in
emulated RAM — the pass detector and the bus window it watches (reopened
by the next frame poll), each voice's read cursor and 64-sample
tap window, the quality tier's per-frame gain ramps, the echo ring, and the
frame FIFO that lands each pass at the hardware's latency — and a load rebuilds
it from that RAM (`mp2k_state_loaded`: every voice re-latches at the engine's
own cursor, the next lock write arms pass detection again, and
the first frame after the load starts the FIFO at its target level with
silence). Consequences a reader may notice: the first V-blank after a load
plays the hardware path or silence rather than the HLE's render, a note that
was mid-decay resumes at its next per-frame value (no ramp across the load),
and a state saved with the HLE off loads identically with it on. None of that
is a bug to chase, and none of it justifies a payload revision.

## Rules for changing the format

* **`EventType` is append-only.** `scheduler.save_to` writes `ord(ev.kind)`;
  inserting a kind mid-enum reinterprets every pending event in every state
  with no error. The test pins every ordinal at compile time; a reorder fails
  the build.
* Bump the owning core's payload revision, add a migration that defaults the
  new field to what the old build implicitly did, and keep every corpus entry
  (`tests/states/<rom>.v<N>.state`, real images from the committed test ROMs,
  generated by building the old tree with `git archive`) green. If a field
  genuinely cannot be reconstructed, refuse *that case* by name. Never delete
  a corpus entry to make the test pass.
* The header constants, trailer flags and `CoreKind` ordinals are pinned too.
  A trailer is only ever appended (a new flag bit, after the others) or
  lengthened (its `len` grows; readers use the prefix they know).
* `--mode=rollback`, `--mode=rollbacknet` and `--mode=speclink` drive
  `state_payload` / `apply_state_payload` thousands of times and assert
  bit-identical replay; run them after any reader/writer change.

## User-facing messages (open)

Web (`loadFromSlot`) collapses every rejection to "State didn't match this
game"; native `load_state_slot` discards the result and shows nothing.
`parse_state_payload` already raises distinct messages — plumb the reason
out. Files are never deleted on a failed load; keep that.
