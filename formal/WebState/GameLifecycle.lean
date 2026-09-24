/-
# The game lifecycle: loading, switching, closing and resuming a game

Models `web/index.js` as fixed on the branch worktree-lean-web-state, up to
the commit "web: flush the solo core wherever its file is read; Reset, Delete
and Import retire a waiting quota retry" (line numbers at that commit). The
model at dd7ba741f, and the eight counterexamples it proved there,
are in the history of this file; each of those traces is replayed here against
the fixed code as a `regress_*` theorem.

| JS                                             | lines        |
|------------------------------------------------|--------------|
| `launchRom` (takes the load token)             | 4535-4550    |
| library tile click (resume-if-loaded           | 5181-5195    |
|   shortcut; a Drive-only tile takes the token  |              |
|   at the tap, 5192, and launches after its     |              |
|   download only if no later tap took it, 5194) |              |
| `handleRomFile` / `handleZipFile` (open, drop) | 8245-8311    |
| `loadGen` / `loadingName` / `nextLoadGen`      | 7879-7893    |
| `loadRom`: L0 8012-8027, L1 8028-8029,         | 8012-8102    |
|   L2 8030-8031, L3 8036-8038 (loadingName,     |              |
|   dbGet save:), L4 8039-8085 (ROM +            |              |
|   installSave + init + names, one segment),    |              |
|   L5 8086-8102                                 |              |
| `flushSoloSave` / `persistSave` /              | 5313-5366    |
|   `installSave`                                |              |
| `persistAutoState` / `liveSaveSig` /           | 5742-5766    |
|   `autoStateMatchesSave`                       |              |
| `offerAutoResume` + the Resume toast action    | 5778-5800    |
| `pushToast` (an offer's tap handler)           | 5468-5516    |
| `showMainMenu` (go home) / `resumeGame`        | 9547-9570    |
| `setPausedCardShown` / `updatePausedCard`      | 9777-9802    |
| `unloadGame`: U0 9828-9834, U1 9835-9836,      | 9828-9869    |
|   U2 9837-9869 (flush, detach, unlink: one     |              |
|   segment); the card's X 9871                  |              |
| 5 s autosave, `beforeunload`, `pagehide`,      | 11395-11444  |
|   `visibilitychange` (hidden)                  |              |
| `pullSyncInner`'s per-save download (checks    | 3042-3057    |
|   before and after the download)               |              |
| `flushSyncInner`'s upload (blind: no remote    | 2821-2836    |
|   modifiedTime check)                          |              |
| RAF `tick` (runs the core whenever !paused)    | 11525-11679  |
| core: `initFromEmscripten` reads `rom.<ext>` and `rom.sav` (no flush of the
|   outgoing core, dingbat_wasm.nim); the cores flush dirty cart RAM to `rom.sav`
|   once per frame (`handle_saves`, `storage.nim`)                               |

## State

Exactly the variables these functions read or write (see the field comments).

## Abstractions, and why they do not affect the stated properties

* **Games**: three names `A B C`, all with the same extension. Every game is
  the one FS file `"rom" + ext`, and `stripExt` maps `rom.gba`, `rom.gb` and
  `rom.gbc` all to the one battery file **`rom.sav`**, so `fsSav` is one slot
  for every game (true for mixed systems too); `fsRom` is one slot per
  extension, modelled as one slot. The ROM is written at the boot (loadRom's
  `opts.rom`), with the save, in the segment that builds the core.
* **Save bytes** are a `Sav` = (the game whose code produced them, a version
  number that is fresh at each production). Two saves are equal iff their bytes
  are, so `saveSignature` is the identity (no FNV collisions).
* **Cart RAM = `rom.sav`.** The cores flush dirty RAM to `rom.sav` once per
  frame, but a paused core runs no frames (a state loaded while paused leaves
  its RAM in the core only). Every reader of the loaded game's `rom.sav`
  flushes the core first (`flushSoloSave` 5313 -> `wasm_flush_save`:
  persistSave 5323, and `liveSaveSig` 5757 for persistAutoState's signature
  and the Resume check), and unloadGame's flush runs while the game is still
  named, so what every one of them reads is the core's RAM. The model
  therefore writes the file at the RAM write (`gameSave`) and at a snapshot
  apply (restoring marks RAM dirty); SavePersistence models the dirty flag
  and the flush themselves (`switch_persists_dirty_ram`,
  `close_persists_dirty_ram`).
* **IndexedDB**: every `dbGet`/`dbPut` is a one-request transaction on one store,
  so IDB runs them in issue order: a request's effect is taken at the segment
  that issues it, and the `await` on it is a separate event. `dbPutRoomy`'s
  quota path is not modelled (SavePersistence has it).
* **Toasts** never expire and are never de-duplicated: that only adds
  behaviour (safety proofs stay sound).
* **Scheduling is free**: any pending continuation may fire next. That is a
  superset of what a browser does, so the proofs cover every real order.
* **Frames / pictures / cheats / audio / clips / brand flight**: no state these
  properties read. `storeLastFrame`'s await is kept as an interleaving point;
  `restoreCheats`' await is the L5 split.
* **Link, rollback, netplay**, the reset button, save import, the per-game
  menu's Delete/Remove/Reset, "library pictures" and renames are not modelled:
  every persist path returns early in the link modes (and loadRom abandons a
  load a link session overtook, Netplay.lean), and the others are separate
  entry points (Reset and import detach the game and take the load token
  too; SavePersistence models them). The SIO link path's boot (`launchNetRom`,
  netplay.js) mirrors loadRom's L3/L4: it takes the token, reads the save, and
  names its game only in the segment that installs the save and inits the core.
* **Drive**: one remote copy of `save:g` and the per-file `syncState.sigs`
  (`synced`); another device writing a newer save is `remoteSave`. A page load
  (`reload`) keeps IndexedDB and Drive and drops everything else.
* `fresh`, `gFlow`, `gIsLoad` are proof-only (ghost) fields.

## Contents

* `step`: the code. Kept, for every reachable state (`Reachable`, arbitrary
  interleavings): `save_owner`, `auto_owner`, `cur_coherent`, `ui_agree`,
  `resume_keeps_battery`, `pull_blocked_during_load`, `stale_noop`,
  `every_trace`; and the one-step facts `tap_loaded_resumes`,
  `unload_flush_keyed_by_outgoing`, `resume_applies_only_matched`.
* The dd7ba741f counterexamples, now safe: `regress_stale_sav_inherited`,
  `regress_unload_race_writes_incoming_save`, `regress_double_tap_boots_wrong_rom`,
  `regress_double_tap_resume_point_of_other_rom`,
  `regress_double_tap_overwrites_resume_point`, `regress_pagehide_in_load_gap`,
  `regress_pull_mid_load_loses_remote_save`, `regress_resume_restores_older_battery`.
-/

namespace WebState.GameLifecycle

inductive G | A | B | C
  deriving DecidableEq, Repr

/-- Battery-save bytes: who wrote them, and which production. -/
structure Sav where
  owner : G
  ver : Nat
  deriving DecidableEq, Repr

/-- A save state (`captureStateBytes`) as `persistAutoState` stores it. -/
structure Snap where
  rom : G              -- the ROM whose core it is (the core's header check)
  ram : Option Sav     -- the cart RAM inside it
  sig : Option Sav     -- `saveSig`: signature of FS rom.sav at capture
  fresh : Bool         -- ghost: the core had not run a frame since boot
  deriving DecidableEq, Repr

/-- What an awaited `persistSave` resumes into. -/
inductive After
  | none
  | l3 (g : G) (t : Nat)
  deriving DecidableEq, Repr

/-- A call in flight, with the locals it captured; `t` is its load token. -/
inductive Pend
  | launchW (g : G) (t : Nat)                 -- launchRom after ensureRuntimeReady/getRomBytes
  | launchL (g : G) (t : Nat)                 -- after touchRecent/addRecentRom: calls loadRom
  | l1 (g : G) (t : Nat)                      -- loadRom after `await persistAutoState()`
  | l2 (g : G) (t : Nat)                      -- after `await storeLastFrame`
  | l3 (g : G) (t : Nat)                      -- after `await persistSave(outgoing)`
  | l4 (g : G) (t : Nat) (v : Option Sav)     -- after the dbGet of save:g (value v)
  | l5 (g : G) (t : Nat)                      -- after `await restoreCheats()`
  | offer1 (n : G) (a : Option Snap)          -- offerAutoResume after dbGet(stateauto:)
  | offer2 (n : G) (a : Snap) (v : Option Sav) -- after autoStateMatchesSave's dbGet
  | res1 (n : G) (a : Snap) (v : Option Sav)  -- the Resume tap, after its dbGet
  | u1 (g : G) (t : Nat)                      -- unloadGame after `await persistAutoState()`
  | u2 (g : G) (t : Nat)                      -- after `await storeLastFrame`
  | psDone (g : G) (d : Sav) (k : After)      -- persistSave after its dbPutRoomy
  | pullW (g : G) (d : Sav)                   -- pull: driveDownload came back with d
  deriving DecidableEq, Repr

structure St where
  cur : Option G           -- currentOriginalName (currentRomName is non-null iff this is)
  paused : Bool            -- paused
  hasGame : Bool           -- body.has-game
  running : Bool           -- body.running (hides #home: tiles, card, hero)
  card : Option G          -- #home-paused shown (body.home-card), with homePausedName
  fsRom : Option G         -- FS "rom.<ext>"
  fsSav : Option Sav       -- FS "rom.sav" (= the core's cart RAM, see header)
  core : Option G          -- the ROM the core was last initFromEmscripten'd with
  coreRam : Option Sav     -- the core's cart RAM
  fresh : Bool             -- ghost: no frame run since the last init
  idb : G → Option Sav     -- IndexedDB "save:<g>"
  auto : G → Option Snap   -- IndexedDB "stateauto:<g>"
  lastSig : Option (G × Sav) -- lastSaveSigKey / lastSaveSig
  drive : G → Option Sav   -- Drive's "save:<g>"
  synced : G → Option Sav  -- syncState.sigs["save:<g>"]
  dirty : G → Bool         -- markUpload("save:<g>") queued
  toasts : List (G × Snap) -- live "Last session saved — Resume" offers
  pend : List Pend         -- continuations in flight
  clock : Nat              -- source of fresh save versions
  loadGen : Nat            -- loadGen
  loading : Option G       -- loadingName
  gFlow : G                -- ghost: the game of the flow holding the current token
  gIsLoad : Bool           -- ghost: ...and whether that flow is a load

def init : St where
  cur := none
  paused := false
  hasGame := false
  running := false
  card := none
  fsRom := none
  fsSav := none
  core := none
  coreRam := none
  fresh := false
  idb := fun _ => none
  auto := fun _ => none
  lastSig := none
  drive := fun _ => none
  synced := fun _ => none
  dirty := fun _ => false
  toasts := []
  pend := []
  clock := 0
  loadGen := 0
  loading := none
  gFlow := .A
  gIsLoad := false

inductive Ev
  | tap (g : G)        -- library tile tap (#home visible)
  | openFile (g : G)   -- file picker, drag-drop, add tile, zip (handleRomFile)
  | goHome             -- showMainMenu
  | resume             -- #home-resume / the paused card's picture or Resume
  | closeCard          -- the paused card's X: unloadGame()
  | frame              -- RAF tick runs a frame
  | gameSave           -- the running cart writes its battery RAM
  | tick               -- the 5 s autosave interval
  | hide               -- visibilitychange to hidden
  | pagehide           -- pagehide / beforeunload
  | toastTap (i : Nat) -- tap the i-th Resume offer
  | remoteSave (g : G) -- another device uploads a newer save:g
  | pullCheck (g : G)  -- pullSyncInner reaches Drive's save:g
  | upload (g : G)     -- flushSyncInner uploads save:g
  | reload             -- a new page load: IDB and Drive survive
  | fire (i : Nat)     -- the scheduler resumes the i-th continuation
  deriving DecidableEq, Repr

/-! ## Shared segments -/

def upd {β : Type} (f : G → β) (g : G) (v : β) : G → β :=
  fun h => if h = g then v else f h

def push (s : St) (p : Pend) : St := { s with pend := s.pend ++ [p] }

def pushAfter (s : St) : After → St
  | .none => s
  | .l3 g t => push s (.l3 g t)

/-- `persistSave(romName, g)` up to its first await (5320-5331): read FS
rom.sav synchronously; nothing, or the signature last written for `g`, returns;
otherwise the dbPutRoomy is issued, and lastSig/markUpload follow its await. -/
def persistSave (s : St) (g : G) (k : After) : St :=
  match s.fsSav with
  | none => pushAfter s k
  | some d =>
    if s.lastSig = some (g, d) then pushAfter s k
    else push { s with idb := upd s.idb g (some d) } (.psDone g d k)

/-- `persistAutoState()` (5742-5749): no name or no core returns; the dbPut
is issued with the snapshot and the signature of FS rom.sav. -/
def persistAuto (s : St) : St :=
  match s.cur, s.core with
  | some g, some r =>
    let a : Snap := { rom := r, ram := s.coreRam, sig := s.fsSav, fresh := s.fresh }
    { s with auto := upd s.auto g (some a) }
  | _, _ => s

/-- `resumeGame` (9562-9570). -/
def resumeGame (s : St) : St :=
  if s.cur.isSome then { s with paused := false, running := true } else s

/-- `offerAutoResume` up to its first await (5778-5784). -/
def offerStart (s : St) : St :=
  match s.cur with
  | none => s
  | some n => push s (.offer1 n (s.auto n))

/-- `x`, or `y` when `x` is nothing. -/
def orKeep (x y : Option Sav) : Option Sav :=
  match x with
  | some d => some d
  | none => y

/-- `applyStateBytes`; the core rejects a state for another ROM (WRONG_ROM).
Restored cart RAM is dirty, so it reaches rom.sav. -/
def applyState (s : St) (a : Snap) : St :=
  if s.core = some a.rom then
    { s with coreRam := a.ram, fsSav := orKeep a.ram s.fsSav, fresh := a.fresh }
  else s

/-- `showMainMenu` (9547-9560) with `updatePausedCard` (9782-9802). -/
def goHome (s : St) : St :=
  match s.cur with
  | none => s
  | some c => { s with paused := true, running := false,
                       card := if s.core.isSome then some c else none }

/-- The RAF tick runs the core whenever `!paused`. -/
def frame (s : St) : St :=
  if !s.paused && s.core.isSome then { s with fresh := false } else s

def gameSave (s : St) : St :=
  match s.paused, s.core with
  | false, some r =>
    let d : Sav := ⟨r, s.clock⟩
    { s with coreRam := some d, fsSav := some d, clock := s.clock + 1, fresh := false }
  | _, _ => s

/-- The 5 s interval (11395-11401). -/
def tick (s : St) : St :=
  match s.cur with
  | some g => persistSave s g .none
  | none => s

/-- `pagehide` / `beforeunload` (11403-11444): persistSave, then persistAutoState. -/
def pagehide (s : St) : St :=
  match s.cur with
  | some g => persistAuto (persistSave s g .none)
  | none => s

def remoteSave (s : St) (g : G) : St :=
  { s with drive := upd s.drive g (some ⟨g, s.clock⟩), clock := s.clock + 1 }

/-- `flushSyncInner`'s upload of save:g (2821-2836): re-uploads whenever the
bytes differ from the last synced signature. No remote-version check. -/
def upload (s : St) (g : G) : St :=
  if s.dirty g then
    match s.idb g with
    | some d =>
      if some d ≠ s.synced g then
        { s with drive := upd s.drive g (some d), synced := upd s.synced g (some d),
                 dirty := upd s.dirty g false }
      else { s with dirty := upd s.dirty g false }
    | none => { s with dirty := upd s.dirty g false }
  else s

/-- A new page load: the JS heap, the MEMFS and every continuation are gone. -/
def reload (s : St) : St :=
  { init with idb := s.idb, auto := s.auto, drive := s.drive, synced := s.synced,
              dirty := s.dirty, clock := s.clock, loadGen := s.loadGen }

/-- The pull's per-save write (3051-3055): written when its signature differs
from the last synced one. -/
def pullWrite (s : St) (g : G) (d : Sav) : St :=
  if some d ≠ s.synced g then
    { s with idb := upd s.idb g (some d), synced := upd s.synced g (some d) }
  else s

def toastTap (s : St) (i : Nat) : St :=
  match s.toasts[i]? with
  | none => s
  | some (n, a) =>
    -- pushToast's onclick: dismiss, then fn(); fn checks the name and awaits
    -- autoStateMatchesSave (5788-5793)
    let s := { s with toasts := s.toasts.eraseIdx i }
    if s.cur = some n then push s (.res1 n a (s.idb n)) else s

/-! ## The code (`step`)

1. **Load token.** A tile tap, a file open and a close take `nextLoadGen()`
   synchronously (which also clears `loadingName`); every continuation of
   launchRom/handleRomFile/loadRom/unloadGame returns when `gen !== loadGen`.
2. **The game is named only when the core holds it.** loadRom sets
   `loadingName` and reads `save:<g>`, then in one synchronous segment writes
   the ROM, installs the save (writes `rom.sav`, or unlinks it when there is
   none; `lastSaveSig` := what was read), runs `initFromEmscripten` (which no
   longer flushes the outgoing GB core), clears `loadingName` and names the
   game, `paused = false`, `has-game running`.
3. **unloadGame** calls persistSave (its flush and FS read are synchronous,
   and run while the game is still named), then detaches and unlinks, in the
   same segment.
4. **Resume** re-checks the snapshot's signature against FS rom.sav, the live
   battery, synchronously just before `applyStateBytes`.
5. **The pull** treats `loadingName` as loaded, and re-checks after the
   download, just before writeSyncBytes.
-/

def bump (s : St) (g : G) (isLoad : Bool) : St :=
  { s with loadGen := s.loadGen + 1, loading := none, gFlow := g, gIsLoad := isLoad }

/-- loadRom L3 (8036-8038): `loadingName = name`, dbGet(save:name) issued. -/
def l3Seg (s : St) (g : G) (t : Nat) : St :=
  push { s with loading := some g } (.l4 g t (s.idb g))

/-- loadRom L0 (8012-8025): with a game in, persistAutoState; else straight to L3. -/
def loadStart (s : St) (g : G) (t : Nat) : St :=
  if s.cur.isSome then push (persistAuto s) (.l1 g t) else l3Seg s g t

/-- loadRom L4 (8039-8085): ROM, save, core, names: one segment. -/
def l4Seg (s : St) (g : G) (t : Nat) (v : Option Sav) : St :=
  push { s with fsRom := some g, fsSav := v, core := some g, coreRam := v, fresh := true,
                lastSig := v.map (fun d => (g, d)), loading := none, cur := some g,
                paused := false, hasGame := true, running := true } (.l5 g t)

/-- unloadGame U2 (9837-9869): flush, detach, unlink, pause, one segment. -/
def u2Seg (s : St) (g : G) : St :=
  let s1 := persistSave s g .none
  { s1 with cur := none, fsSav := none, paused := true, hasGame := false, running := false,
            card := none }

def fire (s : St) : Pend → St
  | .launchW g t => if t = s.loadGen then push s (.launchL g t) else s
  | .launchL g t => if t = s.loadGen then loadStart s g t else s
  | .l1 g t => if t = s.loadGen then push s (.l2 g t) else s
  | .l2 g t =>                                                      -- 8030: args read now
    if t = s.loadGen then
      match s.cur with
      | none => s
      | some c => persistSave s c (.l3 g t)
    else s
  | .l3 g t => if t = s.loadGen then l3Seg s g t else s
  | .l4 g t v => if t = s.loadGen then l4Seg s g t v else s
  | .l5 _ t => if t = s.loadGen then offerStart s else s            -- 8086-8087, 8100
  | .offer1 n a =>                                                  -- 5785-5786
    match a with
    | none => s
    | some a => if s.cur = some n then push s (.offer2 n a (s.idb n)) else s
  | .offer2 n a v =>                                                -- 5786-5788
    if a.sig = v ∧ s.cur = some n then { s with toasts := s.toasts ++ [(n, a)] } else s
  | .res1 n a v =>                                                  -- 5793-5799
    if a.sig = v ∧ s.cur = some n ∧ a.sig = s.fsSav then applyState s a else s
  | .u1 g t => if t = s.loadGen then push s (.u2 g t) else s        -- 9835
  | .u2 g t => if t = s.loadGen then u2Seg s g else s               -- 9837
  | .psDone g d k => pushAfter { s with lastSig := some (g, d), dirty := upd s.dirty g true } k
  | .pullW g d => if s.cur = some g ∨ s.loading = some g then s else pullWrite s g d -- 3050

def step (s : St) : Ev → St
  | .tap g =>
    if s.running then s                                   -- #home hidden: no tile
    else if s.cur = some g then resumeGame s              -- 5185
    else push (bump s g true) (.launchW g (s.loadGen + 1)) -- launchRom 4536
  | .openFile g => push (bump s g true) (.launchW g (s.loadGen + 1))
  | .goHome => goHome s
  | .resume => if s.running then s else resumeGame s
  | .closeCard =>
    if s.running || s.card.isNone then s
    else match s.cur with                                 -- unloadGame 9828-9834
      | none => s
      | some g => push (persistAuto (bump s g false)) (.u1 g (s.loadGen + 1))
  | .frame => frame s
  | .gameSave => gameSave s
  | .tick => tick s
  | .hide => persistAuto s                                -- 11420-11424
  | .pagehide => pagehide s
  | .toastTap i => toastTap s i
  | .remoteSave g => remoteSave s g
  | .pullCheck g =>                                       -- 3044-3046
    match s.drive g with
    | some d =>
      if s.cur ≠ some g ∧ s.loading ≠ some g ∧ some d ≠ s.synced g then push s (.pullW g d) else s
    | none => s
  | .upload g => upload s g
  | .reload => reload s
  | .fire i =>
    match s.pend[i]? with
    | none => s
    | some p => fire { s with pend := s.pend.eraseIdx i } p

def run (s : St) (es : List Ev) : St := es.foldl step s

inductive Reachable : St → Prop
  | init : Reachable init
  | step {s} (e : Ev) : Reachable s → Reachable (step s e)

theorem reachable_run (es : List Ev) : ∀ s, Reachable s → Reachable (run s es) := by
  induction es with
  | nil => intro s h; exact h
  | cons e es ih => intro s h; exact ih _ (Reachable.step e h)

/-! ## Properties the code means to keep -/

/-- Every stored `save:<g>` is bytes that game `g` wrote. -/
def SaveOwner (s : St) : Prop := ∀ g d, s.idb g = some d → d.owner = g

/-- Every `stateauto:<g>` is a state of game `g`, taken with `g`'s battery. -/
def AutoOwner (s : St) : Prop :=
  ∀ g a, s.auto g = some a → a.rom = g ∧ a.ram = a.sig ∧ ∀ d, a.sig = some d → d.owner = g

/-- The current game is the game in the core, with its own battery. -/
def CurCoherent (s : St) : Prop :=
  ∀ g, s.cur = some g → s.core = some g ∧ s.coreRam = s.fsSav ∧ ∀ d, s.fsSav = some d → d.owner = g

/-- body.has-game, body.running and the paused card agree with the current game. -/
def UIAgree (s : St) : Prop :=
  (s.hasGame = true ↔ s.cur.isSome) ∧ (s.running = true → s.cur.isSome) ∧
  ∀ c, s.card = some c → s.running = false → s.cur = some c

/-- Snapshots and pending payloads that belong to game `n`. -/
def SnapOK (n : G) (a : Snap) : Prop :=
  a.rom = n ∧ a.ram = a.sig ∧ ∀ d, a.sig = some d → d.owner = n

/-- A `Resume` never changes the battery: the snapshot carries the live save. -/
def ResumeKeepsBattery (stp : St → Ev → St) (s : St) : Prop :=
  ∀ i n a v, s.pend[i]? = some (.res1 n a v) → (stp s (.fire i)).fsSav = s.fsSav

/-! ## One-step facts -/

/-- Tapping the tile of the game in memory resumes it: no load starts, the
core is untouched, and it runs (5185). -/
theorem tap_loaded_resumes (s : St) (g : G) (hr : s.running = false) (hc : s.cur = some g) :
    step s (.tap g) = { s with paused := false, running := true } := by
  simp [step, hr, hc, resumeGame]

/-- unloadGame's final flush is addressed to the outgoing game's key: every
other `save:` key is untouched (9844-9847). -/
theorem unload_flush_keyed_by_outgoing (s : St) (g h : G) (hne : h ≠ g) :
    (u2Seg s g).idb h = s.idb h := by
  simp only [u2Seg, persistSave]
  split
  · simp [pushAfter]
  · split
    · simp [pushAfter]
    · simp [push, upd, hne]

/-- The Resume action applies a snapshot only to the game still current, and
only when both the stored save and the live battery match its signature
(5793-5799). -/
theorem resume_applies_only_matched (s : St) (n : G) (a : Snap) (v : Option Sav)
    (h : fire s (.res1 n a v) ≠ s) : a.sig = v ∧ s.cur = some n ∧ a.sig = s.fsSav := by
  simp only [fire] at h
  split at h
  · assumption
  · exact absurd rfl h

/-! ## The invariant -/

/-- The part of the state the pending continuations' claims read. -/
structure K where
  loadGen : Nat
  gFlow : G
  gIsLoad : Bool
  cur : Option G
  fsSav : Option Sav
  paused : Bool
  loading : Option G

def St.kv (s : St) : K :=
  ⟨s.loadGen, s.gFlow, s.gIsLoad, s.cur, s.fsSav, s.paused, s.loading⟩

def SavOK (g : G) (v : Option Sav) : Prop := ∀ d, v = some d → d.owner = g

/-- A load holding the current token is the current flow. -/
def LoadClaim (k : K) (g : G) (t : Nat) : Prop :=
  t ≤ k.loadGen ∧ (t = k.loadGen → k.gIsLoad = true ∧ k.gFlow = g)

/-- An unload holding the current token: its game is still current, or it
has already detached it. -/
def UnloadClaim (k : K) (g : G) (t : Nat) : Prop :=
  t ≤ k.loadGen ∧ (t = k.loadGen → k.gIsLoad = false ∧ k.gFlow = g ∧
    (k.cur = some g ∨ (k.cur = none ∧ k.fsSav = none ∧ k.paused = true)))

def AfterOK (k : K) : After → Prop
  | .none => True
  | .l3 g t => LoadClaim k g t

def PendOK (k : K) : Pend → Prop
  | .launchW g t => LoadClaim k g t
  | .launchL g t => LoadClaim k g t
  | .l1 g t => LoadClaim k g t
  | .l2 g t => LoadClaim k g t
  | .l3 g t => LoadClaim k g t
  | .l4 g t v => SavOK g v ∧ LoadClaim k g t ∧ (t = k.loadGen → k.loading = some g ∨ k.cur = some g)
  | .l5 _ _ => True
  | .offer1 n a => ∀ a', a = some a' → SnapOK n a'
  | .offer2 n a _ => SnapOK n a
  | .res1 n a _ => SnapOK n a
  | .u1 g t => UnloadClaim k g t
  | .u2 g t => UnloadClaim k g t
  | .psDone _ _ a => AfterOK k a
  | .pullW g d => d.owner = g

structure Inv (s : St) : Prop where
  save : SaveOwner s
  auto : AutoOwner s
  drive : ∀ g d, s.drive g = some d → d.owner = g
  coh : CurCoherent s
  ui : UIAgree s
  toasts : ∀ x ∈ s.toasts, SnapOK x.1 x.2
  pend : ∀ p ∈ s.pend, PendOK s.kv p

/-! ### Shapes of the shared segments -/

def afterList : After → List Pend
  | .none => []
  | .l3 g t => [.l3 g t]

theorem pushAfter_eq (s : St) (a : After) :
    pushAfter s a = { s with pend := s.pend ++ afterList a } := by
  cases a <;> simp [pushAfter, push, afterList]

theorem persistSave_shape (s : St) (g : G) (a : After) :
    ∃ I P, persistSave s g a = { s with idb := I, pend := s.pend ++ P } ∧
      (∀ h d, I h = some d → s.idb h = some d ∨ (h = g ∧ s.fsSav = some d)) ∧
      (∀ q ∈ P, (∃ d, q = .psDone g d a) ∨ q ∈ afterList a) := by
  unfold persistSave
  split
  · exact ⟨s.idb, afterList a, by rw [pushAfter_eq], fun h d hd => .inl hd,
      fun q hq => .inr hq⟩
  · rename_i d hd
    split
    · exact ⟨s.idb, afterList a, by rw [pushAfter_eq], fun h d hd => .inl hd,
        fun q hq => .inr hq⟩
    · refine ⟨upd s.idb g (some d), [.psDone g d a], rfl, ?_, ?_⟩
      · intro h d' h'
        simp only [upd] at h'
        split at h'
        · subst_vars; exact .inr ⟨rfl, hd ▸ h'.symm ▸ rfl⟩
        · exact .inl h'
      · intro q hq
        simp at hq
        exact .inl ⟨d, hq⟩

theorem persistAuto_shape (s : St) :
    ∃ A, persistAuto s = { s with auto := A } ∧
      ∀ h a, A h = some a → s.auto h = some a ∨
        (s.cur = some h ∧ s.core = some a.rom ∧ a.ram = s.coreRam ∧ a.sig = s.fsSav) := by
  unfold persistAuto
  split
  · rename_i g r hg hr
    refine ⟨upd s.auto g (some { rom := r, ram := s.coreRam, sig := s.fsSav, fresh := s.fresh }),
      rfl, ?_⟩
    intro h a ha
    simp only [upd] at ha
    split at ha
    · subst_vars
      simp only [Option.some.injEq] at ha
      subst ha
      exact .inr ⟨hg, hr, rfl, rfl⟩
    · exact .inl ha
  · exact ⟨s.auto, rfl, fun h a ha => .inl ha⟩

/-! ### Invariant lemmas for the shared segments -/

theorem snap_of_capture {s : St} (hI : Inv s) {h : G} {a : Snap} (hc : s.cur = some h)
    (hr : s.core = some a.rom) (hram : a.ram = s.coreRam) (hsig : a.sig = s.fsSav) :
    SnapOK h a := by
  obtain ⟨hcore, hram', hown⟩ := hI.coh h hc
  refine ⟨?_, ?_, ?_⟩
  · rw [hcore] at hr; exact (Option.some.inj hr).symm
  · rw [hram, hsig, hram']
  · intro d hd; rw [hsig] at hd; exact hown d hd

theorem inv_persistAuto {s : St} (hI : Inv s) : Inv (persistAuto s) := by
  obtain ⟨A, heq, hA⟩ := persistAuto_shape s
  rw [heq]
  refine ⟨hI.save, ?_, hI.drive, hI.coh, hI.ui, hI.toasts, hI.pend⟩
  intro h a ha
  rcases hA h a ha with h1 | ⟨hc, hr, hram, hsig⟩
  · exact hI.auto h a h1
  · exact snap_of_capture hI hc hr hram hsig

theorem inv_persistSave {s : St} {g : G} {a : After} (hI : Inv s) (hg : SavOK g s.fsSav)
    (ha : AfterOK s.kv a) : Inv (persistSave s g a) := by
  obtain ⟨I, P, heq, hIdb, hP⟩ := persistSave_shape s g a
  rw [heq]
  refine ⟨?_, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts, ?_⟩
  · intro h d hd
    rcases hIdb h d hd with h1 | ⟨rfl, h2⟩
    · exact hI.save h d h1
    · exact hg d h2
  · intro q hq
    simp only [List.mem_append] at hq
    rcases hq with hq | hq
    · exact hI.pend q hq
    · rcases hP q hq with ⟨d, rfl⟩ | hq'
      · exact ha
      · cases a <;> simp [afterList] at hq' <;> subst hq' <;> exact ha

theorem inv_push {s : St} {p : Pend} (hI : Inv s) (hp : PendOK s.kv p) : Inv (push s p) := by
  refine ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts, ?_⟩
  intro q hq
  simp only [push, List.mem_append, List.mem_singleton] at hq
  rcases hq with hq | rfl
  · exact hI.pend q hq
  · exact hp

theorem inv_erase {s : St} (i : Nat) (hI : Inv s) : Inv { s with pend := s.pend.eraseIdx i } :=
  ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts,
   fun q hq => hI.pend q (List.mem_of_mem_eraseIdx hq)⟩

/-! ### Transfer of the pending claims across a change of `kv` -/

theorem loadClaim_bump {k k' : K} {g : G} {t : Nat} (h : LoadClaim k g t)
    (hlt : k.loadGen < k'.loadGen) : LoadClaim k' g t :=
  ⟨by have := h.1; omega, fun h' => absurd h' (by have := h.1; omega)⟩

theorem unloadClaim_bump {k k' : K} {g : G} {t : Nat} (h : UnloadClaim k g t)
    (hlt : k.loadGen < k'.loadGen) : UnloadClaim k' g t :=
  ⟨by have := h.1; omega, fun h' => absurd h' (by have := h.1; omega)⟩

/-- A token bump retires every claim. -/
theorem pendOK_bump {k k' : K} {q : Pend} (hq : PendOK k q) (hlt : k.loadGen < k'.loadGen) :
    PendOK k' q := by
  cases q with
  | launchW g t => exact loadClaim_bump hq hlt
  | launchL g t => exact loadClaim_bump hq hlt
  | l1 g t => exact loadClaim_bump hq hlt
  | l2 g t => exact loadClaim_bump hq hlt
  | l3 g t => exact loadClaim_bump hq hlt
  | l4 g t v =>
    exact ⟨hq.1, loadClaim_bump hq.2.1 hlt, fun h => absurd h (by have := hq.2.1.1; omega)⟩
  | l5 => trivial
  | offer1 => exact hq
  | offer2 => exact hq
  | res1 => exact hq
  | u1 g t => exact unloadClaim_bump hq hlt
  | u2 g t => exact unloadClaim_bump hq hlt
  | psDone g d a =>
    cases a with
    | none => trivial
    | l3 g t => exact loadClaim_bump hq hlt
  | pullW => exact hq

/-- The current load names its game in `loading`. -/
theorem pendOK_loading {k : K} {g : G} {q : Pend} (hq : PendOK k q)
    (hf : k.gIsLoad = true ∧ k.gFlow = g) : PendOK { k with loading := some g } q := by
  cases q with
  | l4 g' t v =>
    refine ⟨hq.1, hq.2.1, fun ht => .inl ?_⟩
    obtain ⟨_, h2⟩ := hq.2.1.2 ht
    simp only; rw [← h2, hf.2]
  | _ => exact hq

/-- The current load's boot: a current unload cannot exist beside it, and
every current load claim is about the game it names. -/
theorem pendOK_l4 {k : K} {g : G} {v : Option Sav} {q : Pend} (hq : PendOK k q)
    (hl : k.gIsLoad = true) (hf : k.gFlow = g) :
    PendOK { k with cur := some g, fsSav := v, paused := false, loading := none } q := by
  have uc : ∀ g' t, UnloadClaim k g' t →
      UnloadClaim { k with cur := some g, fsSav := v, paused := false, loading := none } g' t :=
    fun g' t h => ⟨h.1, fun ht => by
      have := (h.2 ht).1
      rw [hl] at this
      exact absurd this (by decide)⟩
  cases q with
  | l4 g' t v' =>
    refine ⟨hq.1, hq.2.1, fun ht => .inr ?_⟩
    obtain ⟨_, h2⟩ := hq.2.1.2 ht
    simp only; rw [← h2, hf]
  | u1 g' t => exact uc g' t hq
  | u2 g' t => exact uc g' t hq
  | _ => exact hq

/-- The current unload's detach: a current load cannot exist beside it. -/
theorem pendOK_u2 {k : K} {q : Pend} (hq : PendOK k q) (hl : k.gIsLoad = false) :
    PendOK { k with cur := none, fsSav := none, paused := true } q := by
  have uc : ∀ g' t, UnloadClaim k g' t →
      UnloadClaim { k with cur := none, fsSav := none, paused := true } g' t :=
    fun g' t h => ⟨h.1, fun ht => by
      obtain ⟨h1, h2, _⟩ := h.2 ht
      exact ⟨h1, h2, .inr ⟨rfl, rfl, rfl⟩⟩⟩
  cases q with
  | u1 g' t => exact uc g' t hq
  | u2 g' t => exact uc g' t hq
  | l4 g' t v =>
    refine ⟨hq.1, hq.2.1, fun ht => ?_⟩
    have := (hq.2.1.2 ht).1
    rw [hl] at this
    exact absurd this (by decide)
  | _ => exact hq

/-- The running cart writes rom.sav: nothing is paused, so no unload has
detached its game yet. -/
theorem pendOK_fsSav_running {k : K} {x : Option Sav} {q : Pend} (hq : PendOK k q)
    (hp : k.paused = false) : PendOK { k with fsSav := x } q := by
  have uc : ∀ g' t, UnloadClaim k g' t → UnloadClaim { k with fsSav := x } g' t :=
    fun g' t h => ⟨h.1, fun ht => by
      obtain ⟨h1, h2, h3⟩ := h.2 ht
      refine ⟨h1, h2, ?_⟩
      rcases h3 with h3 | ⟨_, _, h3⟩
      · exact .inl h3
      · rw [hp] at h3; exact absurd h3 (by decide)⟩
  cases q with
  | u1 g' t => exact uc g' t hq
  | u2 g' t => exact uc g' t hq
  | _ => exact hq

theorem pendOK_pause {k : K} {q : Pend} (hq : PendOK k q) : PendOK { k with paused := true } q := by
  have uc : ∀ g' t, UnloadClaim k g' t → UnloadClaim { k with paused := true } g' t :=
    fun g' t h => ⟨h.1, fun ht => by
      obtain ⟨h1, h2, h3⟩ := h.2 ht
      refine ⟨h1, h2, ?_⟩
      rcases h3 with h3 | ⟨h3, h4, _⟩
      · exact .inl h3
      · exact .inr ⟨h3, h4, rfl⟩⟩
  cases q with
  | u1 g' t => exact uc g' t hq
  | u2 g' t => exact uc g' t hq
  | _ => exact hq

theorem pendOK_unpause {k : K} {q : Pend} (hq : PendOK k q) (hc : k.cur.isSome = true) :
    PendOK { k with paused := false } q := by
  have uc : ∀ g' t, UnloadClaim k g' t → UnloadClaim { k with paused := false } g' t :=
    fun g' t h => ⟨h.1, fun ht => by
      obtain ⟨h1, h2, h3⟩ := h.2 ht
      refine ⟨h1, h2, ?_⟩
      rcases h3 with h3 | ⟨h3, _, _⟩
      · exact .inl h3
      · rw [h3] at hc; exact absurd hc (by decide)⟩
  cases q with
  | u1 g' t => exact uc g' t hq
  | u2 g' t => exact uc g' t hq
  | _ => exact hq

/-! ### Preservation -/

theorem persistAuto_kv (s : St) : (persistAuto s).kv = s.kv := by
  obtain ⟨A, heq, _⟩ := persistAuto_shape s
  rw [heq]; rfl

theorem savOK_cur {s : St} (hI : Inv s) {g : G} (hc : s.cur = some g) : SavOK g s.fsSav :=
  (hI.coh g hc).2.2

theorem inv_bump {s : St} (hI : Inv s) (g : G) (b : Bool) : Inv (bump s g b) :=
  ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts,
   fun q hq => pendOK_bump (hI.pend q hq) (by simp [bump, St.kv])⟩

theorem inv_resumeGame {s : St} (hI : Inv s) : Inv (resumeGame s) := by
  unfold resumeGame
  split
  · rename_i hc
    exact ⟨hI.save, hI.auto, hI.drive, hI.coh, ⟨hI.ui.1, fun _ => hc, fun _ _ h => by simp at h⟩,
      hI.toasts, fun q hq => pendOK_unpause (hI.pend q hq) hc⟩
  · exact hI

theorem inv_l3Seg {s : St} {g : G} {t : Nat} (hI : Inv s) (hp : LoadClaim s.kv g t)
    (ht : t = s.loadGen) : Inv (l3Seg s g t) := by
  obtain ⟨hl, hf⟩ := hp.2 ht
  have h1 : Inv { s with loading := some g } :=
    ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts,
     fun q hq => pendOK_loading (hI.pend q hq) ⟨hl, hf⟩⟩
  exact inv_push h1 ⟨fun d hd => hI.save g d hd, hp, fun _ => .inl rfl⟩

theorem inv_fire {s : St} {p : Pend} (hI : Inv s) (hp : PendOK s.kv p) : Inv (fire s p) := by
  cases p with
  | launchW g t =>
    simp only [fire]
    split
    · exact inv_push hI hp
    · exact hI
  | launchL g t =>
    simp only [fire]
    split
    · rename_i ht
      unfold loadStart
      split
      · have h1 := inv_persistAuto hI
        refine inv_push h1 ?_
        rw [persistAuto_kv]; exact hp
      · exact inv_l3Seg hI hp ht
    · exact hI
  | l1 g t =>
    simp only [fire]
    split
    · exact inv_push hI hp
    · exact hI
  | l2 g t =>
    simp only [fire]
    split
    · split
      · exact hI
      · rename_i c hc
        exact inv_persistSave hI (savOK_cur hI hc) hp
    · exact hI
  | l3 g t =>
    simp only [fire]
    split
    · rename_i ht; exact inv_l3Seg hI hp ht
    · exact hI
  | l4 g t v =>
    simp only [fire]
    split
    · rename_i ht
      obtain ⟨hv, hlc, _⟩ := hp
      obtain ⟨hl, hf⟩ := hlc.2 ht
      unfold l4Seg
      refine inv_push ⟨hI.save, hI.auto, hI.drive, ?_, ?_, hI.toasts, ?_⟩ trivial
      · intro g' hg'
        simp only [Option.some.injEq] at hg'
        subst hg'
        exact ⟨rfl, rfl, hv⟩
      · exact ⟨by simp, fun _ => rfl, fun _ _ h => by simp at h⟩
      · exact fun q hq => pendOK_l4 (hI.pend q hq) hl hf
    · exact hI
  | l5 g t =>
    simp only [fire]
    split
    · simp only [offerStart]
      split
      · exact hI
      · exact inv_push hI (fun a' ha' => hI.auto _ a' ha')
    · exact hI
  | offer1 n a =>
    simp only [fire]
    split
    · exact hI
    · split
      · exact inv_push hI (hp _ rfl)
      · exact hI
  | offer2 n a v =>
    simp only [fire]
    split
    · refine ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, ?_, hI.pend⟩
      intro x hx
      simp only [List.mem_append, List.mem_singleton] at hx
      rcases hx with hx | rfl
      · exact hI.toasts x hx
      · exact hp
    · exact hI
  | res1 n a v =>
    simp only [fire]
    split
    · rename_i h
      obtain ⟨_, hc, hsig⟩ := h
      obtain ⟨_, hram, _⟩ := hp
      obtain ⟨_, hcr, _⟩ := hI.coh n hc
      have e1 : a.ram = s.coreRam := by rw [hram, hsig, hcr]
      have e2 : orKeep a.ram s.fsSav = s.fsSav := by
        rw [hram, hsig]; cases s.fsSav <;> rfl
      unfold applyState
      split
      · rw [e2, e1]
        exact ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts, hI.pend⟩
      · exact hI
    · exact hI
  | u1 g t =>
    simp only [fire]
    split
    · exact inv_push hI hp
    · exact hI
  | u2 g t =>
    simp only [fire]
    split
    · rename_i ht
      obtain ⟨hl, _, hcur⟩ := hp.2 ht
      have hg : SavOK g s.fsSav := by
        rcases hcur with hc | ⟨_, hn, _⟩
        · exact savOK_cur hI hc
        · intro d hd; change s.fsSav = none at hn; rw [hn] at hd; exact absurd hd (by simp)
      unfold u2Seg
      obtain ⟨I, P, heq, hIdb, hP⟩ := persistSave_shape s g .none
      rw [heq]
      refine ⟨?_, hI.auto, hI.drive, fun _ h => absurd h (by simp), ?_, hI.toasts, ?_⟩
      · intro h d hd
        rcases hIdb h d hd with h1 | ⟨rfl, h2⟩
        · exact hI.save h d h1
        · exact hg d h2
      · exact ⟨by simp, fun h => by simp at h, fun _ h => by simp at h⟩
      · intro q hq
        simp only [List.mem_append] at hq
        rcases hq with hq | hq
        · exact pendOK_u2 (hI.pend q hq) hl
        · rcases hP q hq with ⟨d, rfl⟩ | hq'
          · trivial
          · simp [afterList] at hq'
    · exact hI
  | psDone g d a =>
    simp only [fire]
    rw [pushAfter_eq]
    refine ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts, ?_⟩
    intro q hq
    simp only [List.mem_append] at hq
    rcases hq with hq | hq
    · exact hI.pend q hq
    · cases a with
      | none => simp [afterList] at hq
      | l3 g t => simp [afterList] at hq; subst hq; exact hp
  | pullW g d =>
    simp only [fire]
    split
    · exact hI
    · unfold pullWrite
      split
      · refine ⟨?_, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts, hI.pend⟩
        intro h d' hd'
        simp only [upd] at hd'
        split at hd'
        · rename_i hh; subst hh; simp only [Option.some.injEq] at hd'; subst hd'; exact hp
        · exact hI.save h d' hd'
      · exact hI

theorem inv_step {s : St} (e : Ev) (hI : Inv s) : Inv (step s e) := by
  cases e with
  | tap g =>
    simp only [step]
    split
    · exact hI
    · split
      · exact inv_resumeGame hI
      · exact inv_push (inv_bump hI g true) ⟨by simp [bump, St.kv], fun _ => ⟨rfl, rfl⟩⟩
  | openFile g =>
    exact inv_push (inv_bump hI g true) ⟨by simp [bump, St.kv], fun _ => ⟨rfl, rfl⟩⟩
  | goHome =>
    simp only [step, goHome]
    split
    · exact hI
    · rename_i c hc
      refine ⟨hI.save, hI.auto, hI.drive, hI.coh, ⟨hI.ui.1, fun h => by simp at h, ?_⟩,
        hI.toasts, fun q hq => pendOK_pause (hI.pend q hq)⟩
      intro c' hc' _
      simp only at hc'
      split at hc'
      · simp only [Option.some.injEq] at hc'; subst hc'; exact hc
      · exact absurd hc' (by simp)
  | resume =>
    simp only [step]
    split
    · exact hI
    · exact inv_resumeGame hI
  | closeCard =>
    simp only [step]
    split
    · exact hI
    · split
      · exact hI
      · rename_i g hg
        refine inv_push (inv_persistAuto (inv_bump hI g false)) ?_
        rw [persistAuto_kv]
        exact ⟨by simp [bump, St.kv], fun _ => ⟨rfl, rfl, .inl hg⟩⟩
  | frame =>
    simp only [step, frame]
    split
    · exact ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts, hI.pend⟩
    · exact hI
  | gameSave =>
    simp only [step, gameSave]
    split
    · rename_i r hp hr
      refine ⟨hI.save, hI.auto, hI.drive, ?_, hI.ui, hI.toasts,
        fun q hq => pendOK_fsSav_running (hI.pend q hq) hp⟩
      intro g hg
      obtain ⟨hcore, _, _⟩ := hI.coh g hg
      rw [hr] at hcore
      simp only [Option.some.injEq] at hcore
      subst hcore
      exact ⟨hr, rfl, fun d hd => by simp only [Option.some.injEq] at hd; subst hd; rfl⟩
    · exact hI
  | tick =>
    simp only [step, tick]
    split
    · rename_i g hg; exact inv_persistSave hI (savOK_cur hI hg) trivial
    · exact hI
  | hide => exact inv_persistAuto hI
  | pagehide =>
    simp only [step, pagehide]
    split
    · rename_i g hg
      exact inv_persistAuto (inv_persistSave hI (savOK_cur hI hg) trivial)
    · exact hI
  | toastTap i =>
    simp only [step, toastTap]
    split
    · exact hI
    · rename_i n a hx
      have hsnap : SnapOK n a := hI.toasts (n, a) (List.mem_of_getElem? hx)
      have h1 : Inv { s with toasts := s.toasts.eraseIdx i } :=
        ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui,
         fun x hx' => hI.toasts x (List.mem_of_mem_eraseIdx hx'), hI.pend⟩
      split
      · exact inv_push h1 hsnap
      · exact h1
  | remoteSave g =>
    refine ⟨hI.save, hI.auto, ?_, hI.coh, hI.ui, hI.toasts, hI.pend⟩
    intro h d hd
    simp only [step, remoteSave, upd] at hd
    split at hd
    · subst_vars; simp only [Option.some.injEq] at hd; subst hd; rfl
    · exact hI.drive h d hd
  | pullCheck g =>
    simp only [step]
    split
    · rename_i d hd
      split
      · exact inv_push hI (hI.drive g d hd)
      · exact hI
    · exact hI
  | upload g =>
    simp only [step, upload]
    split
    · split
      · rename_i d hd
        split
        · refine ⟨hI.save, hI.auto, ?_, hI.coh, hI.ui, hI.toasts, hI.pend⟩
          intro h d' hd'
          simp only [upd] at hd'
          split at hd'
          · subst_vars; simp only [Option.some.injEq] at hd'; subst hd'; exact hI.save _ _ hd
          · exact hI.drive h d' hd'
        · exact ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts, hI.pend⟩
      · exact ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts, hI.pend⟩
    · exact hI
  | reload =>
    refine ⟨hI.save, hI.auto, hI.drive, fun _ h => absurd h (by simp [step, reload, init]),
      ?_, fun _ h => absurd h (by simp [step, reload, init]),
      fun _ h => absurd h (by simp [step, reload, init])⟩
    simp [UIAgree, step, reload, init]
  | fire i =>
    simp only [step]
    split
    · exact hI
    · rename_i p hp
      exact inv_fire (inv_erase i hI) (hI.pend p (List.mem_of_getElem? hp))

theorem inv_init : Inv init :=
  ⟨fun _ _ h => absurd h (by simp [init]), fun _ _ h => absurd h (by simp [init]),
   fun _ _ h => absurd h (by simp [init]), fun _ h => absurd h (by simp [init]),
   by simp [UIAgree, init], fun _ h => absurd h (by simp [init]),
   fun _ h => absurd h (by simp [init])⟩

theorem reachable_inv {s : St} (h : Reachable s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step e _ ih => exact inv_step e ih

/-! ## What the code keeps, under every interleaving -/

/-- No `save:<g>` ever holds another game's battery. -/
theorem save_owner {s : St} (h : Reachable s) : SaveOwner s := (reachable_inv h).save

/-- No `stateauto:<g>` is ever a state of another game, or carries RAM other
than the battery its signature names. -/
theorem auto_owner {s : St} (h : Reachable s) : AutoOwner s := (reachable_inv h).auto

/-- The named game is the game in the core, running on its own battery. -/
theorem cur_coherent {s : St} (h : Reachable s) : CurCoherent s := (reachable_inv h).coh

/-- body.has-game, body.running and the visible paused card agree with it. -/
theorem ui_agree {s : St} (h : Reachable s) : UIAgree s := (reachable_inv h).ui

/-- A Resume never changes the battery: it can only restore a snapshot whose
RAM is the live save. -/
theorem resume_keeps_battery {s : St} (h : Reachable s) : ResumeKeepsBattery step s := by
  intro i n a v hi
  have hI := reachable_inv h
  have hp : SnapOK n a := hI.pend _ (List.mem_of_getElem? hi)
  obtain ⟨_, hram, _⟩ := hp
  simp only [step, hi, fire]
  split
  · rename_i hc
    obtain ⟨_, _, hsig⟩ := hc
    unfold applyState
    split
    · show orKeep a.ram s.fsSav = s.fsSav
      rw [hram, hsig]; cases s.fsSav <;> rfl
    · rfl
  · rfl

/-- While the current load of `g` is between reading `save:g` and booting
it, a Drive pull cannot write `save:g`. -/
theorem pull_blocked_during_load {s : St} (h : Reachable s) {g : G} {t : Nat}
    {v : Option Sav} (hl : Pend.l4 g t v ∈ s.pend) (ht : t = s.loadGen) {i : Nat} {d : Sav}
    (hi : s.pend[i]? = some (.pullW g d)) : (step s (.fire i)).idb g = s.idb g := by
  have hload : s.loading = some g ∨ s.cur = some g := ((reachable_inv h).pend _ hl).2.2 ht
  rcases hload with hload | hload <;> simp [step, hi, fire, hload]

def tokOf : Pend → Option Nat
  | .launchW _ t | .launchL _ t | .l1 _ t | .l2 _ t | .l3 _ t | .l4 _ t _ | .l5 _ t
  | .u1 _ t | .u2 _ t => some t
  | _ => none

/-- A superseded load or close does nothing when it resumes. -/
theorem stale_noop (s : St) (i : Nat) (p : Pend) (t : Nat) (hp : s.pend[i]? = some p)
    (ht : tokOf p = some t) (hne : t ≠ s.loadGen) :
    step s (.fire i) = { s with pend := s.pend.eraseIdx i } := by
  simp only [step, hp]
  cases p <;> simp only [tokOf, Option.some.injEq, reduceCtorEq] at ht <;> subst ht <;>
    simp [fire, hne]

/-- Whatever the user, the timers, the page and Drive do, in whatever order. -/
theorem every_trace (es : List Ev) :
    SaveOwner (run init es) ∧ AutoOwner (run init es) ∧ CurCoherent (run init es) ∧
    UIAgree (run init es) := by
  have h := reachable_run es init .init
  exact ⟨save_owner h, auto_owner h, cur_coherent h, ui_agree h⟩

/-! ## The code still loads, switches and closes games -/

def boot (g : G) : List Ev := [.openFile g, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0]

/-- Opening a file loads it. -/
example : (run init (boot .A)).cur = some .A ∧ (run init (boot .A)).core = some .A := by
  decide

/-- Double-tapping two tiles: the later tap wins, the earlier load is dropped,
and B is never named or booted. -/
example :
    let s := run init (boot .A ++ [.gameSave, .goHome, .tap .B, .tap .C, .fire 0, .fire 0,
                                    .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0])
    s.cur = some .C ∧ s.core = some .C ∧ s.fsSav = none ∧ s.pend = [.l5 .C 3] := by
  decide

/-- Closing the paused game while a tile's load is in flight: the close
supersedes the load, and A's save is A's. -/
example :
    let s := run init (boot .A ++ [.gameSave, .goHome, .tap .B, .fire 0, .fire 0, .closeCard,
                                    .fire 0, .fire 0, .fire 0, .fire 0, .fire 0])
    s.cur = none ∧ s.idb .A = some ⟨.A, 0⟩ ∧ s.hasGame = false := by
  decide

/-! ## The dd7ba741f counterexamples, replayed against the code

Each trace below reached a bad state at dd7ba741f (its comment says how). Run
through `step`, the same events end in a good state: `every_trace` covers the
properties, and each theorem pins what now happens instead. -/

def playA : List Ev := boot .A ++ [.gameSave, .tick, .fire 0]
def abHome : List Ev :=
  boot .B ++ [.gameSave, .tick, .fire 0, .goHome, .closeCard, .fire 0, .fire 0, .fire 0] ++
  boot .A ++ [.gameSave, .tick, .fire 0, .goHome]
def sessionA : List Ev := playA ++ [.hide, .reload]

/-- Play A (it saves), go home, tap B, which has never saved. At dd7ba741f
`restoreSave` returned without touching FS `rom.sav`, B booted on A's battery,
and the next 5 s autosave wrote A's bytes to `save:B`. Now B boots with no
battery file, and `save:B` stays empty. -/
def trStaleSav : List Ev :=
  playA ++ [.goHome, .tap .B, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0,
            .fire 0, .tick]

theorem regress_stale_sav_inherited :
    let s := run init trStaleSav
    s.cur = some .B ∧ s.core = some .B ∧ s.fsSav = none ∧ s.idb .B = none ∧
      s.idb .A = some ⟨.A, 0⟩ ∧ SaveOwner s :=
  ⟨by decide, by decide, by decide, by decide, by decide, (every_trace _).1⟩

/-- Close the paused game while another tile's load is in flight. At
dd7ba741f the load's L3 named B and put B's save in `rom.sav` before the
close's flush read it into `save:A`. The close now supersedes the load: A is
closed with its own save, and B never boots. -/
def trUnloadRace : List Ev :=
  abHome ++ [.tap .B, .fire 0, .fire 0, .closeCard, .fire 0, .fire 0, .fire 0, .fire 1, .fire 1,
             .fire 0]

theorem regress_unload_race_writes_incoming_save :
    let s := run init trUnloadRace
    s.cur = none ∧ s.idb .A = some ⟨.A, 1⟩ ∧ s.idb .B = some ⟨.B, 0⟩ ∧ SaveOwner s :=
  ⟨by decide, by decide, by decide, (every_trace _).1⟩

/-- Double-tap two tiles. At dd7ba741f both launches wrote the one FS file
`rom.gba`, B booted C's ROM under B's name, and C's load then snapshotted it
as B's resume point. Now C's tap supersedes B's load: C boots under its own
name, and `stateauto:B` is untouched. -/
def trDoubleTapTwo : List Ev :=
  abHome ++ [.tap .B, .tap .C, .fire 0, .fire 0, .fire 0, .fire 1, .fire 1, .fire 1, .fire 1]

theorem regress_double_tap_boots_wrong_rom :
    let s := run init (trDoubleTapTwo ++ [.fire 0, .fire 0, .fire 0, .fire 0, .fire 0])
    s.cur = some .C ∧ s.core = some .C ∧ CurCoherent s :=
  ⟨by decide, by decide, (every_trace _).2.2.1⟩

theorem regress_double_tap_resume_point_of_other_rom :
    (run init (trDoubleTapTwo ++ [.fire 0])).auto .B =
      some ⟨.B, some ⟨.B, 0⟩, some ⟨.B, 0⟩, false⟩ ∧
    AutoOwner (run init (trDoubleTapTwo ++ [.fire 0])) :=
  ⟨by decide, (every_trace _).2.1⟩

/-- Double-tap the same tile from a fresh page, over a real resume point. At
dd7ba741f the second load found A named (by the first's L3) and snapshotted
the fresh boot over the real resume point. Now the second tap supersedes the
first before it names anything, and the resume point survives. -/
def trDoubleTapSame : List Ev :=
  sessionA ++ [.tap .A, .tap .A, .fire 0, .fire 0, .fire 0, .fire 1, .fire 0]

theorem regress_double_tap_overwrites_resume_point :
    (run init sessionA).auto .A = some ⟨.A, some ⟨.A, 0⟩, some ⟨.A, 0⟩, false⟩ ∧
    (run init (trDoubleTapSame ++ [.fire 0, .fire 0, .fire 0])).auto .A =
      some ⟨.A, some ⟨.A, 0⟩, some ⟨.A, 0⟩, false⟩ ∧
    (run init (trDoubleTapSame ++ [.fire 0, .fire 0, .fire 0])).cur = some .A := by
  decide

/-- The page going away between a load's L3 and its boot. At dd7ba741f L3
had already named B while `rom.sav` still held A's battery: pagehide wrote
A's battery to `save:B` and A's core state to `stateauto:B`. Now A is still
named until the boot, so pagehide persists A under A. -/
def trPagehideGap : List Ev :=
  abHome ++ [.tap .B, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .pagehide]

theorem regress_pagehide_in_load_gap :
    let s := run init trPagehideGap
    s.cur = some .A ∧ s.idb .B = some ⟨.B, 0⟩ ∧ s.auto .B = some ⟨.B, some ⟨.B, 0⟩, some ⟨.B, 0⟩, false⟩ ∧
      s.auto .A = some ⟨.A, some ⟨.A, 1⟩, some ⟨.A, 1⟩, false⟩ ∧ SaveOwner s ∧ AutoOwner s :=
  ⟨by decide, by decide, by decide, by decide, (every_trace _).1, (every_trace _).2.1⟩

/-- A Drive pull lands mid-load. At dd7ba741f the pull checked
`isRomLoaded(A)` only before its download; the load booted version 0, the
download wrote version 1, the first autosave wrote version 0 back and the
upload replaced Drive's version 1. Now the pull re-checks after the download
and skips the loaded game, and the boot remembers the signature it
installed, so the first autosave writes nothing: Drive keeps version 1. -/
def trPullRace : List Ev :=
  playA ++ [.upload .A, .reload, .remoteSave .A, .pullCheck .A, .tap .A, .fire 1, .fire 1, .fire 1,
            .fire 0, .tick, .fire 1, .upload .A]

theorem regress_pull_mid_load_loses_remote_save :
    (run init (playA ++ [.upload .A, .reload, .remoteSave .A])).drive .A = some ⟨.A, 1⟩ ∧
    (run init trPullRace).drive .A = some ⟨.A, 1⟩ ∧
    (run init trPullRace).idb .A = some ⟨.A, 0⟩ ∧
    (run init trPullRace).dirty .A = false := by
  decide

/-- Resume after an unflushed in-game save. At dd7ba741f the tap's check
compared the snapshot with IndexedDB `save:A`, which lags the live battery by
up to one autosave, and restored version 0 over version 1. The check now also
reads FS rom.sav, and refuses. -/
def trResumeUnflushed : List Ev :=
  sessionA ++ [.tap .A, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .gameSave,
               .toastTap 0]

theorem regress_resume_restores_older_battery :
    (run init trResumeUnflushed).fsSav = some ⟨.A, 1⟩ ∧
    (step (run init trResumeUnflushed) (.fire 0)).fsSav = some ⟨.A, 1⟩ ∧
    ResumeKeepsBattery step (run init trResumeUnflushed) :=
  ⟨by decide, by decide, resume_keeps_battery (reachable_run _ _ .init)⟩

end WebState.GameLifecycle
