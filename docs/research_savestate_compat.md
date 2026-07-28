# Save states and emulator updates

Investigated 2026-07-27, from a confirmed report: two save states made around
2026-07-24 were refused with `state load REJECTED (ROM/version mismatch)` while
a state from another date loaded fine.

**Short answer: yes, updating dingbat throws away save states, and it has done
so five times in fifteen days.** The specific cause of the 07-24 rejections is
commit `b398a7b` (2026-07-24 17:05), which bumped `STATE_VERSION` 5 → 6 to add
*one Game Boy PPU field*. The version check is global, so it also refused every
GBA state in existence — even though the GBA payload is byte-for-byte identical
across that bump.

---

## 1. What the format is

`src/dingbat/common/serialize.nim` defines a 32-byte header followed by a flat,
positional, unversioned payload:

```
magic(8)="DGBSTATE"  version(4)  core(1)  slot(1)  flags(2)
rom_checksum(4)  rom_size(4)  payload_len(4)  payload_hash(4)   = 32 bytes
[payload_len bytes of payload]
[optional thumbnail trailer: thumb_w(2) thumb_h(2) len(4) BGR555 pixels]
```

The payload is written field by field per subsystem by
`src/dingbat/gba/savestate.nim` and `src/dingbat/gb/savestate.nim`, with a
one-byte section tag between subsystems (`GBA_SEC_*` / `GB_SEC_*`), validated on
read by `expect_tag`. There is no field-level framing: the reader replays the
writer's exact sequence of `read_u32`/`read_bool`/… calls and any divergence
shows up as a tag mismatch, a truncation, or silent garbage.

`parse_state_payload` refuses a state on any of:

| check | error text |
|---|---|
| magic absent | `not a dingbat save state` |
| `version != STATE_VERSION` | `save state format version N not supported` |
| `core` byte differs | `created by a different core (GBA/GB mismatch)` |
| `rom_checksum` or `rom_size` differ | `belongs to a different ROM` |
| fewer bytes than `payload_len` | `truncated or corrupt` |
| FNV-1a of the payload differs | `payload hash mismatch` |

The size check is `<`, not `!=` — that is the "relaxed length-check" the
thumbnail trailer needed, and it is correct: the trailer lives outside the
hashed payload so old readers slice by `payload_len` and ignore it.

Both `load_state` and `load_state_bytes` snapshot the live machine first and
restore it if applying fails midway, so a rejection never leaves a half-loaded
emulator. **Verified** by mutation in `tests/savestate_compat_test.nim`.

---

## 2. The five ways an update invalidates a state

### 2.1 A `STATE_VERSION` bump — the one that actually fired

`parse_state_payload` accepts exactly one version. Every bump is a hard,
unconditional discard of every state every user has, for **both** cores. The
history:

| version | commit | date | what changed | which core's payload |
|---|---|---|---|---|
| v1 | `ea14217` | 07-10 | format introduced | — |
| v2 | `5ab4e7c` | 07-11 | GBA CPU halt-wake / deferred halt-return | GBA only |
| v3 | `66a3c42` | 07-14 | GBA bus ROM burst/prefetch trackers, RTC | GBA only |
| v4 | `0956322` | 07-16 | GB serial port (SB/SC) | GB only |
| v5 | `32dd8bb` | 07-23 | GBA HLE `halt_resume_pop` (1 byte) | GBA only |
| v6 | `b398a7b` | 07-24 17:05 | GB PPU `lcd_off_dots` (4 bytes) | GB only |

Every single bump touched exactly one core's `savestate.nim` (`git show --stat`
on each), and every single one invalidated the other core's states for free.

**This is the reported bug.** Confirmed directly against the files on disk:

| file | mtime | version byte | outcome today |
|---|---|---|---|
| `~/Downloads/Legend of Zelda … Minish Cap (USA).state` | 07-22 17:14 | 4 | refused |
| `~/Downloads/Golden Sun - The Lost Age ….state` | 07-23 10:49 | 5 | refused |
| `~/Downloads/PokemonFireRed.state` | 07-24 11:04 | 5 | refused |
| `~/Downloads/PokemonEmerald.state` | 07-26 19:20 | 6 | loads |

The 07-24 states are *v5* because they were saved at 11:04, before the 17:05
bump. The state "from a different date" that loaded is 07-26, i.e. v6.

**The rejection was gratuitous.** Two independent confirmations that the GBA
payload did not change between v5 and today:

1. `git diff 32dd8bb..HEAD -- src/dingbat/gba/savestate.nim` contains no
   writer/reader change at all. The one substantial edit (`2b323ff`, the lazy
   PSG catch-up) deliberately round-trips the four channel deadlines through the
   scheduler events they replaced *specifically* to keep the payload
   byte-identical, and says so in its comment.
2. Empirically: with the version comparison temporarily disabled, the v5
   `Golden Sun - The Lost Age` state loads into a HEAD build and runs 120 frames
   clean at 11.6x realtime.

So the GBA half of the v6 bump destroyed users' states in exchange for nothing.

### 2.2 `EventType` ordinal changes

`scheduler.save_to` writes `ord(ev.kind)` as a byte and `load_from` reads it
straight back. Inserting a kind anywhere except the end reinterprets every
pending event in every existing state as the wrong kind — a PPU deadline becomes
a timer deadline — with **no error anywhere**: `load_from` only rejects ordinals
past `high(EventType)`, and an inserted kind keeps every ordinal in range.

Status: **this has not fired since save states existed.** The two historical
insertions (`etPPUSetHBlankFlag` in `a1fe6ab`, `etRtcSecond` in `1410d5b`)
predate the format (`ea14217`, 07-10) by a day or two. Both additions since
(`etDMA`, `etCameraDone`) were appends. The constraint was comment-enforced
until now; §4.1 makes it mechanical.

### 2.3 A field added or removed without a version bump

Nothing in the format detects this — the reader just walks off. In practice the
section tag one subsystem later catches it (`state section marker mismatch`),
which is a refusal rather than corruption, but only because the tags exist; a
field added to the *last* section before `GBA_SEC_END`/`GB_SEC_END` would still
be caught, while a swap of two same-width fields inside one section would not be
caught at all.

Status: **has not fired.** Checked every commit touching either `savestate.nim`
since v5. The `worktree-simplify` refactor (`a60eaa0`, `eb01567`, "one
bidirectional visitor per subsystem") is **not on main** — that branch is
unmerged, so it is not implicated in anything users have seen. The four new GB
mappers (`38f0188`..`4832563`) only added new `elif cart of …` branches, which
are selected by the cart's runtime type and so cannot shift an existing cart's
layout. `9e09d87` renamed `lcd_off_dots` → `dots_since_frame` without changing
the bytes.

### 2.4 ROM identity drift

The header stores `rom_checksum` and `rom_size`, and both must match the loaded
ROM. Two hazards, one handled and one live:

- **Handled.** `2dfd27e` changed the GBA ROM buffer from a flat 32 MB to
  `next_pow2(file_size)`. `GBA_STATE_ROM_TAG` was pinned to the old
  `0x02000000` constant precisely so the `rom_size` field would keep matching.
  Correct, and commented.
- **Live, unnoticed.** `gba_rom_checksum` hashes
  `min(gba.cartridge.rom.len, 0x100000)` bytes — the length of the *allocated
  buffer*, not the file. For any GBA ROM **smaller than 1 MiB** the same commit
  changed both the number of bytes hashed and their content (the old buffer was
  pre-filled with the open-bus pattern and zero-padded to the next power of two;
  the new one is zero-filled to `next_pow2`, floor 32 KB). Those carts' states
  silently became "belongs to a different ROM" at `2dfd27e`. Rare on GBA — most
  commercial carts are ≥ 4 MiB, and the exactly-1-MiB Classic NES carts are
  unaffected because their first 1 MiB is unchanged — but it is a real class,
  and it is exactly the kind of change nobody thinks of as a format change.
  Inferred from reading both revisions of `cartridge.nim`; not reproduced
  against a real sub-1-MiB cart.
- Related: a cart whose mapper was **unimplemented** and is now implemented
  changes its `mbc_kind_tag`, so its old states are refused with `save state MBC
  type mismatch`. Applies to the seven mappers added in `38f0188`..`4832563`.
  Those states were snapshots of a broken emulation, so this one is fine.

### 2.5 Length/size guards

`load_storage_state` (GBA, non-EEPROM) and `load_mbc_state` (GB) refuse when the
backup memory in the state is a different length from the one the cart
autodetected. Save-type autodetection changed in `38927b5` and `faebadc`
(EEPROM sizing). Any cart whose detected backup size moved has states that no
longer load. Inferred from the code; not enumerated against real carts.

### 2.6 Not a factor: netplay

Rollback/netplay never puts a state payload on the wire — `linkproto.nim`
exchanges inputs and SIO words only, under its own `LINKPROTO_VERSION`. So
`STATE_VERSION` is not a peer-compatibility axis, and format changes cost
nothing there. Snapshots stay in-process.

---

## 3. What the user sees when it happens

- **Web** (`web/index.js`, `loadFromSlot`): toast `"State didn't match this
  game"`. Wrong and unhelpful — the state matches the game fine, it is the build
  that moved. The file itself is kept in IndexedDB, so nothing is lost
  permanently. Worst affected surface, because the service worker updates the
  app under the user without asking.
- **Native** (`src/dingbat.nim`, `load_state_slot`): the failure is `echo`'d to
  stdout and the return value is `discard`ed. A user clicking a slot in the save
  states window sees **nothing at all** — the game just keeps running.
- **Files** are never deleted on a failed load, on any surface. That part is
  already right.

---

## 4. Recommendations, in priority order

### 4.1 Land the guards (done — see §5)

A CI test that loads a committed corpus of reference states is the single
highest-value change, because it converts both silent failure modes into a red
build. Implemented.

### 4.2 Stop bumping the version for one core

Cheapest real fix, and it would have prevented the reported bug outright.
`STATE_VERSION` is one global number for two independent payloads. Either:

- **(a) Per-core versions.** Reuse the reserved `slot` byte at header offset 13,
  or the top 16 bits of `version`, as a per-core payload version, and validate
  only the one matching the file's `core` byte. Four of the five historical
  bumps become no-ops for the other core.
- **(b) Compare against a floor, not equality.** Keep a
  `MIN_SUPPORTED_VERSION` per core and accept anything in
  `[MIN_SUPPORTED, CURRENT]`, which then *requires* 4.3 to be meaningful.

(a) is a two-line change and strictly better than today even without migrations.

### 4.3 Make the reader version-tolerant where it is cheap

Every bump so far was an *append* to one subsystem's field list, except v6,
which inserted `lcd_off_dots` mid-section. Both shapes are migratable, because
the reader knows the file's version before it starts:

```nim
# pass the header version into gba_apply_state / gb_apply_state
if ver >= 5: cpu.halt_resume_pop = r.read_bool()
else:        cpu.halt_resume_pop = false
```

That is the whole migration for v4→v5. For v6 it is the same idea at a known
offset inside `load_ppu_state`. Concretely, all five historical bumps are
expressible as ≤ 5 lines each:

| bump | migration for older states |
|---|---|
| v1→v2 | default the halt-wake fields to `false`/`0` |
| v2→v3 | default the ROM burst trackers to "cold" (`rom_hot = false`) |
| v3→v4 | default GB serial to idle |
| v4→v5 | `halt_resume_pop = false` |
| v5→v6 | `dots_since_frame = 0` |

Each default is exactly what the field was implicitly doing in the build that
wrote the file. The cost is a `ver` parameter threaded into the two
`*_apply_state` procs and one `if` per migrated field, and the payoff is that a
version bump stops being a user-facing event. Deleting a migration later (when
nobody has v2 states anymore) is a one-line revert.

Worth noting what this does *not* need to be: it does not need a self-describing
format, field tags, or a schema. The positional layout is fine; it just needs to
be read with the version in hand.

### 4.4 Fix the user-facing messages

- Distinguish the causes. `parse_state_payload` already raises distinct
  messages; plumb the reason out instead of collapsing to a bool. Web should say
  "This state was made by an older version of dingbat and can't be loaded"
  rather than "State didn't match this game".
- Native should surface *something*. Right now `load_state_slot`'s return value
  is discarded at both call sites.
- Never delete a state on a failed load. Already true; keep it true, and
  consider showing the version/date in the slot UI so an unloadable slot is
  visibly stale rather than mysteriously inert.

### 4.5 Make ROM identity independent of buffer allocation

`gba_rom_checksum` should hash `min(cartridge.rom_size, 0x100000)` bytes (the
file size, which is already stored) instead of `min(rom.len, …)` (the
allocation). As written, any future change to the allocation policy silently
re-identifies every sub-1-MiB cart. Note that fixing this *also* invalidates the
affected states one final time, so it wants to land with 4.3 in place, or
alongside an accept-either-checksum grace period.

---

## 5. What was implemented

`tests/savestate_compat_test.nim`, wired into `nimble test_savestate_compat` and
into the CI job (a new "Save-state format compatibility" step, needs no
downloaded ROMs), plus `tests/states/*.state`.

1. **`EventType` ordinal pinning**, compile-time. Every enumerator's ordinal is
   asserted in a `static:` block, with the appended ones listed separately and a
   `high(EventType)` check so a new kind cannot be added without touching the
   file. A reorder now fails the **build**.
2. **Header constant pinning**, compile-time: magic, header size, thumbnail
   flag, `CoreKind` ordinals.
3. **The corpus.** `tests/states/<rom>.v<N>.state` are real state images taken
   from the already-committed test ROMs (`inputrec.gba`, `linktest.gba`,
   `gbhdmatest.gbc`, `gblinktest.gb`). The test boots the matching ROM and
   asserts each still loads. 1.3 MB raw, ~2.5 KB in the pack file — they are
   mostly zeros.
4. **Round-trip and rejection tests**: this build reads its own states
   (including the thumbnail trailer), and a wrong version / wrong ROM / wrong
   core / truncated / garbage image is refused *and* leaves the emulator's
   payload byte-identical.

Each guard was confirmed to actually fail, by mutation:

| mutation | result |
|---|---|
| `STATE_VERSION` 6 → 7 | all 4 corpus entries FAIL, `version 6 not supported` |
| extra `write_u32`/`read_u32` in `save_bus_state` | both GBA entries FAIL, `state section marker mismatch` |
| swap `etIME` / `etRtcSecond` | **compile error**: `etIME moved from 7 to 8` |

The corpus starts at v6, so it guards changes from here forward; it cannot
retroactively protect the v5 states already in the wild. Recovering those needs
4.2/4.3 — and for GBA specifically, accepting v5 is sufficient on its own, since
the payload is already identical.

### The intended workflow when it goes red

The header of the test file spells this out. In short: prefer making the reader
tolerate the old layout (4.3) and keep the corpus entry green; if the format
genuinely must break, bump the version, regenerate with `--write-corpus`, and
say in the commit message that users lose their states. Never delete a corpus
entry to make the test pass.
