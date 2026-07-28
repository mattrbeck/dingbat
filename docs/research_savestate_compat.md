# Save states and emulator updates

Investigated 2026-07-27, from a confirmed report: two save states made around
2026-07-24 were refused with `state load REJECTED (ROM/version mismatch)` while
a state from another date loaded fine.

**Short answer: yes, updating dingbat threw away save states, and it had done so
five times in fifteen days.** The specific cause of the 07-24 rejections is
commit `b398a7b` (2026-07-24 17:05), which bumped `STATE_VERSION` 5 → 6 to add
*one Game Boy PPU field*. The version check was global, so it also refused every
GBA state in existence — even though the GBA payload is byte-for-byte identical
across that bump.

> **Status.** §1–§3 describe the format as it was, and are kept because they are
> the evidence. §5 is the guard that landed first (ordinal pinning + a corpus of
> reference states in CI). **§6 is the fix**: container v7 splits the version
> number per core and makes both readers migrate older layouts instead of
> refusing them. Every state dingbat has ever written now loads again, with two
> narrow, named exceptions. Recommendations §4.1–§4.3 are done; §4.4 (user-facing
> messages) and §4.5 (`gba_rom_checksum`) are still open.

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
- **Was live, now fixed.** `gba_rom_checksum` hashed
  `min(gba.cartridge.rom.len, 0x100000)` bytes — the length of the *allocated
  buffer*, not the file. For any GBA ROM **smaller than 1 MiB** the same commit
  changed both the number of bytes hashed and their content (the old buffer was
  pre-filled with the open-bus pattern and zero-padded to the next power of two;
  the new one is zero-filled to `next_pow2`, floor 32 KB). Those carts' states
  silently became "belongs to a different ROM" at `2dfd27e`. Rare on GBA — most
  commercial carts are ≥ 4 MiB, and the exactly-1-MiB Classic NES carts are
  unaffected because their first 1 MiB is unchanged — but it is a real class,
  and it is exactly the kind of change nobody thinks of as a format change.

  Reproduced, and fixed. `tests/roms/inputrec.gba` (56 bytes) hits it exactly:
  built at `origin/main` its identity is `0x0E29A8EB`, built from the file
  bytes it is `0xE72DC58B`. Pokémon Emerald (16 MiB) is `0x09BB5F7B` either
  way, as is every cart ≥ 1 MiB, because the 1 MiB cap means the hashed window
  is all file. The fix hashes `min(rom_size, 1 MiB)` — the file, so the
  identity no longer depends on how the buffer is allocated — and
  `gba_legacy_rom_checksums` recomputes the **two** superseded identities (the
  post-`2dfd27e` `next_pow2` buffer, and the pre-`2dfd27e` 32 MB open-bus one)
  and passes them to `parse_state_payload` as an accept-list. Old states load,
  new states are written with the corrected identity, so nothing is lost.
  The one-way cost is a **downgrade**: a state written after the fix for a
  sub-1 MiB cart is refused by a build from before it. Section 3b of
  `tests/savestate_compat_test.nim` pins all of this.

  Note that this is *not* the netplay ROM check. That is a CRC-32 of the ROM
  file (`linkproto.crc32`, in the HELLO message), computed from `readFile` on
  native and over `rom[0 ..< rom_size]` in the wasm build; it never used
  `gba_rom_checksum` and did not move. See §2.6.
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
nothing there. Snapshots stay in-process (`netcore.nim` captures
`gba.state_payload()`, the raw payload with no header, so it never computes a
ROM identity at all).

The peer ROM check is a **separate** value that happens to be called a
checksum: `LinkMsg.rom_crc`, a CRC-32 (`linkproto.crc32`) of the ROM **file**,
sent in HELLO and compared in `netcore.handle_hello`. Native takes it over
`readFile(current_rom_path())`; the wasm build takes it over
`rom[0 ..< rom_size]`, which is the same bytes (`dingbat_wasm.nim`, and the
comment there says so). The web rollback path has its own third hash,
`rbHash(romBytes)` in `web/netplay.js`, also over the file. None of the three
is `gba_rom_checksum`, and the 2026-07-28 ROM-identity fix changed none of
them — no wire value moved, and no peer pairing changed.

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

The corpus started at v6, so on its own it guards changes going forward; it
could not retroactively protect the v4/v5 states already in the wild. §6 does
that.

### The intended workflow when it goes red

The header of the test file spells this out. In short: prefer making the reader
tolerate the old layout (§6) and keep the corpus entry green; if a field
genuinely cannot be reconstructed, refuse *that case* explicitly and name it.
Never delete a corpus entry to make the test pass.

---

## 6. The fix: container v7, per-core revisions, migrating readers

Implements §4.2(a) and §4.3.

### 6.1 The header

Byte 13 was `slot`, "reserved for future multi-slot support"; every writer since
v1 put a literal 0 there (multi-slot ended up in the file *name*). It now holds
the **payload revision of the core that wrote the file**, and 0 means "pre-v7,
derive it". Verified free by reading every historical `write_state_header`.

`STATE_VERSION` is now 7 and describes the *header*, not the payloads. Payload
changes bump `GBA_PAYLOAD_VERSION` or `GB_PAYLOAD_VERSION` instead — one core at
a time, which is the whole point. Acceptance changed from `!=` (refuse anything
not exactly equal) to: refuse only containers *newer* than this build, then
refuse only revisions newer than this core reads.

Pre-v7 files get their revision from a derivation table, reconstructed by walking
every commit that touched either `savestate.nim` — not just the version bumps,
which is what makes it trustworthy:

| container | GBA rev | GB rev | what moved |
|---|---|---|---|
| 1 | 1 | 1 | format introduced |
| 2 | 2 | 1 | GBA CPU halt-wake fields |
| 3 | 3 | 1 | GBA bus ROM trackers + RTC epoch |
| 4 | 3 | 2 | GB serial section |
| 5 | 4 | 2 | GBA CPU `halt_resume_pop` |
| 6 | 4 | 3 | GB PPU `dots_since_frame` |

Every other commit in those windows was checked and changed no bytes. The single
wrinkle: inside container 4 the GB serial section's 5th byte changed *meaning*
(`previous_bit` → `clock_history`, `f678d02`) at the same width, so the layout is
still single-valued. That byte is the shift-clock edge history, 0 in any state
not taken mid-transfer, and 0 means "clock low" under both readings.

The table is pinned in a compile-time `static:` block in the test — editing
`legacy_payload_version` fails the build.

### 6.2 The migrations

| migration | what it does | why it is right |
|---|---|---|
| GBA 1→2 | `halt_wake=false`, `halt_resume_charge=0`, `halt_resume_addr=0` | rev 1 charged the BIOS return path up front, so nothing is ever deferred in a rev-1 state. 0 is the value, not a guess. |
| GBA 2→3 | ROM burst trackers start cold (`rom_next_addr=1`, the existing sentinel), `rom_hot=false`; `rtc.deterministic=false`, `epoch=0` | rev ≤ 2 didn't restore the trackers at all, so a load left junk; cold costs a few cycles on one access, exactly what `66a3c42` called "invisible in a one-shot load". Deterministic RTC didn't exist, so off *is* the state. |
| GBA 3→4 | `halt_resume_pop=false`, **plus** an IntrWait stack-frame retrofit | see below |
| GB 1→2 | serial section absent → idle | the port was a stub; no transfer could exist. |
| GB 2→3 | `dots_since_frame=0` | the counter is reset at every frame push, and states are only written at frame boundaries. The test asserts this premise directly (it measures < 456 dots, i.e. under one scanline of a 70224-dot frame). |

**The IntrWait retrofit** is the interesting one, because the v5 bump declared it
impossible: *"a v4 state saved mid-IntrWait/Halt would resume with a mis-restored
sp, so old states are refused."* `32dd8bb` made the HLE IntrWait push
`{r2, lr}` + `{r4, lr}` onto the System stack, hold sp 16 bytes lower for the
whole wait, and pop all four words on resume — unconditionally, with no flag.

It is possible, because the old build never overwrote `r2`/`r4`/`lr_sys` while
waiting, so a rev-3 state still holds the *caller's* values in those registers —
which is precisely what the frame is meant to contain. Writing them where the pop
expects them, lowering sp, and putting the live registers into the halt-loop
convention makes the new resume restore the caller's `r2`/`r4`/`lr` and the
original sp: the same caller-visible outcome the old build produced (its resume
restored nothing and left them live). The 16 bytes land below the System sp,
which is dead stack the new build clobbers on every IntrWait anyway.

**Where it is refused instead.** If `intr_wait_active` is set but the CPU is *not*
halted, the user IRQ handler is mid-flight on that same System stack; lowering sp
under it would move the base its own pushes already used, and there is nothing to
reconstruct from. That case raises a `StateError` naming it, and `load_state`'s
existing backup/restore leaves the running game untouched. Refusing 100% of these
was the old behaviour; refusing only this sliver is strictly better, and it is
the one place a silent wrong answer was available and declined.

### 6.3 What is loadable now

| | GBA | GB |
|---|---|---|
| container v1 | ✅ (rev 1) | ✅ (rev 1) |
| container v2 | ✅ (rev 2) | ✅ (rev 1) |
| container v3 | ✅ (rev 3) | ✅ (rev 1) |
| container v4 | ✅ (rev 3) | ✅ (rev 2) |
| container v5 | ✅ (rev 4) | ✅ (rev 2) |
| container v6 | ✅ (rev 4) | ✅ (rev 3) |

Two deliberate exceptions:

1. **GBA rev ≤ 3 taken mid-IntrWait with the handler running** — refused, §6.2.
2. **GBA states for carts smaller than 1 MiB, written before `2dfd27e`** —
   refused as "belongs to a different ROM". This is §2.4, not a payload problem:
   the identity hash covers `min(rom_buffer_len, 1 MiB)` and the buffer resize
   changed both the length and the padding for sub-1-MiB carts. Fixing it
   invalidates those states one more time, so it stays out of this change.
   Demonstrated: a genuine container-v3 state for the 56-byte `inputrec.gba` is
   refused, while genuine container-v1/v2/v3 states for a 16 MiB commercial cart
   load fine — exactly the predicted boundary.

### 6.4 How it was verified

Not "it didn't crash".

**Real user states.** All three of the files that prompted this now load and
*resume correctly*, confirmed by running 600 frames and looking at the output:

| file | container | path exercised | result |
|---|---|---|---|
| `Minish Cap (USA).state` | v4 | GBA rev 3→4 **incl. the IntrWait retrofit** (`intr_wait_active=1`, `halted=1` in the file) | intro cutscene resumes and advances — "A long, long time ago…" → "when the world was on the verge of being swallowed by shadow…" |
| `Golden Sun - The Lost Age.state` | v5 | GBA rev 4, no migration | resumes to its in-game temple scene |
| `PokemonFireRed.state` | v5 | GBA rev 4, no migration | resumes to Pallet Town, animating |

**Genuine old-build fixtures, not doctored headers.** For each old format,
`git archive <commit> | tar -x` into a scratch tree, compile a 20-line generator
against *that* tree, and run it on a committed test ROM. That produced real
container v1/v3/v4/v5 files, now in `tests/states/` and loaded by CI. The same
method against a commercial cart produced container v1/v2/v3 GBA states — those
load too (they can't be committed, so the corpus documents GBA rev 3/4 only, and
the test asserts that coverage rather than passing vacuously on an empty set).

**An exact-inverse proof for the IntrWait retrofit.** The corpus can't cover it
(no committed test ROM calls IntrWait), so the test builds both shapes by hand
from `hle_intr_wait`'s own definition — never from the migration's code — then
converts the new shape *down* to the old one and asserts the migration converts
it back to a **byte-identical payload**, plus the four frame words and sp
individually. The unreconstructible case is asserted to raise, and the pre-load
payload asserted to restore.

**Mutation-tested.** Each guard was confirmed to fail when the thing it describes
is broken:

| mutation | result |
|---|---|
| frame retrofit lowers sp by 12 instead of 16 | byte-identity + sp checks FAIL |
| `legacy_payload_version` off by one for GB | **compile error** |
| extra `write_u32` in `save_bus_state` | GBA corpus entries FAIL on the section marker |
| swap `etIME` / `etRtcSecond` | **compile error** |

**Regression.** `--mode=rollback`, `--mode=rollbacknet` and `--mode=speclink` all
pass — they drive `state_payload`/`apply_state_payload` thousands of times per
run and assert bit-identical replay, which is the strongest available check that
the reader/writer still agree. The GB HDMA screenshot guard passes. Corpus,
round-trip and rejection checks: 60 assertions, all green.
