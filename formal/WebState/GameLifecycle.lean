/-
# The game lifecycle: loading, switching, closing and resuming a game

Models `web/index.js` at commit dd7ba741f (branch worktree-lean-web-state):

| JS                                             | lines        |
|------------------------------------------------|--------------|
| `launchRom`                                    | 4484-4497    |
| library tile click (resume-if-loaded shortcut) | 5127-5138    |
| `handleRomFile` / `handleZipFile` (open, drop) | 8083-8142    |
| `loadRom`: L0 7881-7888, L1 7889, L2 7890,     | 7881-7936    |
|   L3 7892-7920, L4 7920-7922, L5 7922-7935     |              |
| `restoreSave` / `persistSave`                  | 5245-5274    |
| `persistAutoState` / `autoStateMatchesSave`    | 5643-5657    |
| `offerAutoResume` + the Resume toast action    | 5669-5688    |
| `pushToast` (an offer's tap handler)           | 5368-5416    |
| `showMainMenu` (go home) / `resumeGame`        | 9352-9380    |
| `setPausedCardShown` / `updatePausedCard`      | 9588-9613    |
| `unloadGame`: U0 9636-9641, U1 9642,           | 9636-9673    |
|   U2 9644-9646, U3 9648-9665; the card's X     |              |
| 5 s autosave, `beforeunload`, `pagehide`,      | 11195-11238  |
|   `visibilitychange` (hidden)                  |              |
| `pullSyncInner`'s per-save download            | 2990-3016    |
| `flushSyncInner`'s upload (blind: no remote    | 2786-2800    |
|   modifiedTime check)                          |              |
| RAF `tick` (runs the core whenever !paused)    | 11321-11470  |
| core: `initFromEmscripten` reads `rom.<ext>` and `rom.sav`; the cores flush dirty cart
|   RAM to `rom.sav` once per frame (`handle_saves`, `storage.nim`)                  |

## State

Exactly the variables these functions read or write (see the field comments).

## Abstractions, and why they do not affect the stated properties

* **Games**: three names `A B C`, all with the same extension. `launchRom` writes
  every game to the one FS file `"rom" + ext`, and `stripExt` maps `rom.gba`,
  `rom.gb` and `rom.gbc` all to the one battery file **`rom.sav`**, so `fsSav` is
  one slot for every game (true for mixed systems too); `fsRom` is one slot per
  extension, modelled as one slot (the ROM-collision trace needs same-extension
  games; the `rom.sav` traces do not).
* **Save bytes** are a `Sav` = (the game whose code produced them, a version
  number that is fresh at each production). Two saves are equal iff their bytes
  are, so `saveSignature` is the identity (no FNV collisions).
* **Cart RAM = `rom.sav`.** The cores flush dirty RAM to `rom.sav` once per
  frame; the model flushes at the write (`gameSave`) and at a snapshot apply
  (restoring marks RAM dirty). Only a sub-frame lag is lost.
* **IndexedDB**: every `dbGet`/`dbPut` is a one-request transaction on one store,
  so IDB runs them in issue order: a request's effect is taken at the segment
  that issues it, and the `await` on it is a separate event. `dbPutRoomy`'s
  quota path is not modelled (a failed write only removes behaviour).
* **Toasts** never expire and are never de-duplicated: that only adds
  behaviour (safety proofs stay sound; each bug trace says why it fits in 8 s).
* **Scheduling is free**: any pending continuation may fire next. That is a
  superset of what a browser does (IDB completes requests in issue order,
  `storeLastFrame` calls resolve in call order through `frameStoreChain`, a
  microtask-only await resumes before any task), so the fixed model's proofs
  cover every real order; each bug trace was checked by hand against those
  orderings (its comment gives the argument).
* **Frames / pictures / cheats / audio / clips / brand flight**: no state these
  properties read. `storeLastFrame`'s await is kept as an interleaving point.
* **Link, rollback, netplay**, the reset button, save import, the per-game
  menu's Delete/Remove, "library pictures" and renames are not modelled: every
  persist path returns early in the link modes, and the others are separate
  entry points that need a menu interaction inside a millisecond window.
* **Drive**: one remote copy of `save:g` and the per-file `syncState.sigs`
  (`synced`); another device writing a newer save is `remoteSave`. A page load
  (`reload`) keeps IndexedDB and Drive and drops everything else.
* `fresh`, `gFlow`, `gIsLoad` are proof-only (ghost) fields; `loadGen` and
  `loading` exist only in the fixed model (`stepF`) and are inert in `step`.

## Contents

* `step`: the code as it is. Kept: `tap_loaded_resumes`,
  `unload_flush_keyed_by_outgoing`, `resume_applies_only_matched`. Broken, by
  concrete traces from `init`: `bug_stale_sav_inherited`,
  `bug_unload_race_writes_incoming_save`, `bug_double_tap_boots_wrong_rom`,
  `bug_double_tap_resume_point_of_other_rom`,
  `bug_double_tap_overwrites_resume_point`, `bug_pagehide_in_load_gap`,
  `bug_pull_mid_load_loses_remote_save`, `bug_resume_restores_older_battery`.
* `stepF`: the same machine with the six fixes listed at its section. Proved
  for every reachable state: `fixed_save_owner`, `fixed_auto_owner`,
  `fixed_cur_coherent`, `fixed_ui_agree`, `fixed_resume_keeps_battery`,
  `fixed_pull_blocked_during_load`, `fixed_stale_noop`, `fixed_every_trace`.
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
  | u3 (g : G) (t : Nat)
  deriving DecidableEq, Repr

/-- A call in flight, with the locals it captured. `t` is the load token
(fixed model only). -/
inductive Pend
  | launchW (g : G) (t : Nat)                 -- launchRom/handleRomFile before writeToFS
  | launchL (g : G) (t : Nat)                 -- after touchRecent/addRecentRom: calls loadRom
  | l1 (g : G) (t : Nat)                      -- loadRom after `await persistAutoState()`
  | l2 (g : G) (t : Nat)                      -- after `await storeLastFrame`
  | l3 (g : G) (t : Nat)                      -- after `await persistSave(outgoing)`
  | l4 (g : G) (t : Nat) (v : Option Sav)     -- after restoreSave's dbGet (value v)
  | l5 (g : G) (t : Nat)                      -- after `await restoreCheats()`
  | offer1 (n : G) (a : Option Snap)          -- offerAutoResume after dbGet(stateauto:)
  | offer2 (n : G) (a : Snap) (v : Option Sav) -- after autoStateMatchesSave's dbGet
  | res1 (n : G) (a : Snap) (v : Option Sav)  -- the Resume tap, after its dbGet
  | u1 (g : G) (t : Nat)                      -- unloadGame after `await persistAutoState()`
  | u2 (g : G) (t : Nat)                      -- after `await storeLastFrame`
  | u3 (g : G) (t : Nat)                      -- after `await persistSave(romName, g)`
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
  loadGen : Nat            -- FIX: load generation token
  loading : Option G       -- FIX: the game whose restoreSave is in flight
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
  | .u3 g t => push s (.u3 g t)

/-- `persistSave(romName, g)` up to its first await (5245-5256): read FS
rom.sav synchronously; nothing, or the signature last written for `g`, returns;
otherwise the dbPutRoomy is issued, and lastSig/markUpload follow its await. -/
def persistSave (s : St) (g : G) (k : After) : St :=
  match s.fsSav with
  | none => pushAfter s k
  | some d =>
    if s.lastSig = some (g, d) then pushAfter s k
    else push { s with idb := upd s.idb g (some d) } (.psDone g d k)

/-- `persistAutoState()` (5643-5651): no name or no core returns; the dbPut
is issued with the snapshot and the signature of FS rom.sav. -/
def persistAuto (s : St) : St :=
  match s.cur, s.core with
  | some g, some r =>
    let a : Snap := { rom := r, ram := s.coreRam, sig := s.fsSav, fresh := s.fresh }
    { s with auto := upd s.auto g (some a) }
  | _, _ => s

/-- `resumeGame` (9373-9380). -/
def resumeGame (s : St) : St :=
  if s.cur.isSome then { s with paused := false, running := true } else s

/-- `offerAutoResume` up to its first await (5669-5675). -/
def offerStart (s : St) : St :=
  match s.cur with
  | none => s
  | some n => push s (.offer1 n (s.auto n))

/-- `x`, or `y` when `x` is nothing. -/
def orKeep (x y : Option Sav) : Option Sav :=
  match x with
  | some d => some d
  | none => y

/-- `applyStateBytes` (5504-5513); the core rejects a state for another ROM
(WRONG_ROM). Restored cart RAM is dirty, so it reaches rom.sav. -/
def applyState (s : St) (a : Snap) : St :=
  if s.core = some a.rom then
    { s with coreRam := a.ram, fsSav := orKeep a.ram s.fsSav, fresh := a.fresh }
  else s

/-- `showMainMenu` (9352-9366) with `updatePausedCard` (9593-9613). -/
def goHome (s : St) : St :=
  match s.cur with
  | none => s
  | some c => { s with paused := true, running := false,
                       card := if s.core.isSome then some c else none }

/-- The RAF tick runs the core whenever `!paused` (11326). -/
def frame (s : St) : St :=
  if !s.paused && s.core.isSome then { s with fresh := false } else s

def gameSave (s : St) : St :=
  match s.paused, s.core with
  | false, some r =>
    let d : Sav := ⟨r, s.clock⟩
    { s with coreRam := some d, fsSav := some d, clock := s.clock + 1, fresh := false }
  | _, _ => s

/-- The 5 s interval (11195-11201). -/
def tick (s : St) : St :=
  match s.cur with
  | some g => persistSave s g .none
  | none => s

/-- `pagehide` / `beforeunload` (11203-11238): persistSave, then persistAutoState. -/
def pagehide (s : St) : St :=
  match s.cur with
  | some g => persistAuto (persistSave s g .none)
  | none => s

def remoteSave (s : St) (g : G) : St :=
  { s with drive := upd s.drive g (some ⟨g, s.clock⟩), clock := s.clock + 1 }

/-- `flushSyncInner`'s upload of save:g (2786-2800): re-uploads whenever the
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

/-- The pull's per-save write (3007-3012): written when its signature differs
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
    -- autoStateMatchesSave (5679-5682)
    let s := { s with toasts := s.toasts.eraseIdx i }
    if s.cur = some n then push s (.res1 n a (s.idb n)) else s

/-! ## The code as it is (`step`) -/

/-- loadRom's segment that ends in `await restoreSave` (7892-7916). -/
def l3Seg (s : St) (g : G) (t : Nat) : St :=
  push { s with cur := some g, paused := false, hasGame := true, running := true }
    (.l4 g t (s.idb g))

/-- loadRom's first segment (7881-7889). No link session is modelled. -/
def loadStart (s : St) (g : G) (t : Nat) : St :=
  if s.cur.isSome then push (persistAuto s) (.l1 g t) else l3Seg s g t

def fire (s : St) : Pend → St
  | .launchW g t => push { s with fsRom := some g } (.launchL g t)   -- writeToFS (4492-4494)
  | .launchL g t => loadStart s g t                                   -- loadRom(romFile, name)
  | .l1 g t => push s (.l2 g t)                                       -- storeLastFrame (7889)
  | .l2 g t =>                                                        -- 7890: args read NOW
    match s.cur with
    | none => s              -- persistSave(null, null): TypeError, loadRom rejects
    | some c => persistSave s c (.l3 g t)
  | .l3 g t => l3Seg s g t
  | .l4 g t v =>                                                      -- restoreSave 5270-5273,
    let fs := orKeep v s.fsSav                                        -- then initFromEmscripten
    push { s with fsSav := fs, core := s.fsRom, coreRam := fs, fresh := true } (.l5 g t)
  | .l5 _ _ => offerStart s                                           -- 7932
  | .offer1 n a =>                                                    -- 5676-5677
    match a with
    | none => s
    | some a => if s.cur = some n then push s (.offer2 n a (s.idb n)) else s
  | .offer2 n a v =>                                                  -- 5677-5679
    if a.sig = v ∧ s.cur = some n then { s with toasts := s.toasts ++ [(n, a)] } else s
  | .res1 n a v =>                                                    -- 5682-5687
    if a.sig = v ∧ s.cur = some n then applyState s a else s
  | .u1 g t => push s (.u2 g t)                                       -- 9642
  | .u2 g t => persistSave { s with cur := none } g (.u3 g t)         -- 9644-9646
  | .u3 _ _ =>                                                        -- 9648-9665
    { s with fsSav := none, paused := true, hasGame := false, running := false, card := none }
  | .psDone g d k =>                                                  -- 5260-5263
    pushAfter { s with lastSig := some (g, d), dirty := upd s.dirty g true } k
  | .pullW g d => pullWrite s g d

def step (s : St) : Ev → St
  | .tap g =>
    if s.running then s                                   -- #home hidden: no tile
    else if s.cur = some g then resumeGame s              -- 5132
    else push s (.launchW g s.loadGen)                    -- launchRom (4484)
  | .openFile g => push s (.launchW g s.loadGen)
  | .goHome => goHome s
  | .resume => if s.running then s else resumeGame s
  | .closeCard =>
    if s.running || s.card.isNone then s
    else match s.cur with                                 -- unloadGame (9636-9641)
      | none => s
      | some g => push (persistAuto s) (.u1 g s.loadGen)
  | .frame => frame s
  | .gameSave => gameSave s
  | .tick => tick s
  | .hide => persistAuto s                                -- 11217-11221
  | .pagehide => pagehide s
  | .toastTap i => toastTap s i
  | .remoteSave g => remoteSave s g
  | .pullCheck g =>                                       -- 3005-3007
    match s.drive g with
    | some d => if s.cur ≠ some g ∧ some d ≠ s.synced g then push s (.pullW g d) else s
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

/-! ## What the code as it is does keep -/

/-- Tapping the tile of the game in memory resumes it: no load starts, the
core is untouched, and it runs (5132). -/
theorem tap_loaded_resumes (s : St) (g : G) (hr : s.running = false) (hc : s.cur = some g) :
    step s (.tap g) = { s with paused := false, running := true } := by
  simp [step, hr, hc, resumeGame]

/-- unloadGame's final flush is addressed to the outgoing game's key: every
other `save:` key is untouched (9644-9646). (What it writes there is another
matter: `bug_unload_race_writes_incoming_save`.) -/
theorem unload_flush_keyed_by_outgoing (s : St) (g h : G) (t : Nat) (hne : h ≠ g) :
    (fire s (.u2 g t)).idb h = s.idb h := by
  simp only [fire, persistSave]
  split
  · simp [pushAfter, push]
  · split
    · simp [pushAfter, push]
    · simp [push, upd, hne]

/-- The Resume action applies a snapshot only to the game still current, and
only when the save it read matched the snapshot's signature (5680-5687). -/
theorem resume_applies_only_matched (s : St) (n : G) (a : Snap) (v : Option Sav)
    (h : fire s (.res1 n a v) ≠ s) : a.sig = v ∧ s.cur = some n := by
  simp only [fire] at h
  split at h
  · assumption
  · exact absurd rfl h

/-! ## Counterexamples: the code does not keep what it means to

Each trace runs from a fresh install (`init`). `boot g` is "open g's file and
let the load finish"; `abHome` plays B (saves in game), closes it, plays A
(saves in game) and goes home, leaving A paused behind the card. The traces
use only orders a browser can produce; the ordering argument is in each
comment (IDB runs requests in issue order; `storeLastFrame` calls resolve in
call order, being one promise chain; a Drive download is network time).
-/

def boot (g : G) : List Ev := [.openFile g, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0]
def playA : List Ev := boot .A ++ [.gameSave, .tick, .fire 0]
def abHome : List Ev :=
  boot .B ++ [.gameSave, .tick, .fire 0, .goHome, .closeCard, .fire 0, .fire 0, .fire 0] ++
  boot .A ++ [.gameSave, .tick, .fire 0, .goHome]

theorem not_saveOwner {s : St} (g : G) (d : Sav) (h : s.idb g = some d) (hne : d.owner ≠ g) :
    ¬ SaveOwner s := fun hs => hne (hs g d h)

theorem not_autoOwner {s : St} (g : G) (a : Snap) (h : s.auto g = some a) (hne : a.rom ≠ g) :
    ¬ AutoOwner s := fun hs => hne (hs g a h).1

/-- **No race needed.** Play A (it saves), go home, tap B, which has never
saved. `restoreSave` returns without touching FS `rom.sav` when there is no
stored save (5270-5271), so B's core boots with A's battery file
(`new_storage`/`mbc_load` read `rom.sav`), and the next 5 s autosave writes A's
bytes to `save:B` (and queues them for Drive). -/
def trStaleSav : List Ev :=
  playA ++ [.goHome, .tap .B, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0,
            .fire 0, .tick]

theorem bug_stale_sav_inherited :
    (run init trStaleSav).idb .B = some ⟨.A, 0⟩ ∧ ¬ SaveOwner (run init trStaleSav) :=
  ⟨by decide, not_saveOwner .B ⟨.A, 0⟩ (by decide) (by decide)⟩

/-- **Close the paused game while another tile's load is in flight.** A is
paused behind the card; tap B, then the card's X. Order: B's loadRom issues
its persistAutoState put (L0) before unloadGame issues its own (U0), so its
`storeLastFrame` joins the frame chain first (l1 before u1), so its
continuation resolves first; B's persistSave(A) skips (A was flushed), so L3
sets current = B and issues dbGet(save:B) in the same microtask run, before
the unload's frame encode has even issued its put: IDB order then forces L4
(rom.sav := B's save) before u2. u2 then does `persistSave(romName, "A")`,
which reads FS rom.sav — B's save — into `save:A`. A's battery save is
replaced by B's, locally and on Drive. -/
def trUnloadRace : List Ev :=
  abHome ++ [.tap .B, .fire 0, .fire 0, .closeCard, .fire 0, .fire 0, .fire 0, .fire 1, .fire 1,
             .fire 0]

theorem bug_unload_race_writes_incoming_save :
    (run init trUnloadRace).idb .A = some ⟨.B, 0⟩ ∧ ¬ SaveOwner (run init trUnloadRace) :=
  ⟨by decide, not_saveOwner .A ⟨.B, 0⟩ (by decide) (by decide)⟩

/-- **Double-tap two tiles** (B then C, the second tap before B's load hides
the home screen at its L3). launchRom writes both to the one FS file
`rom.gba`; C's `getRomBytes` get is issued at the second tap, before B's L3
issues dbGet(save:B), so IDB order forces C's writeToFS before B's L4, and
B's `initFromEmscripten("rom.gba")` boots **C's ROM under B's name with B's
save**. C's load then persists "the outgoing game" — which is B by name — so
`stateauto:B` becomes a state of C's core (B's real resume point is gone;
offered next time, the core rejects it as WRONG_ROM). -/
def trDoubleTapTwo : List Ev :=
  abHome ++ [.tap .B, .tap .C, .fire 0, .fire 0, .fire 0, .fire 1, .fire 1, .fire 1, .fire 1]

theorem bug_double_tap_boots_wrong_rom :
    (run init trDoubleTapTwo).cur = some .B ∧ (run init trDoubleTapTwo).core = some .C ∧
    ¬ CurCoherent (run init trDoubleTapTwo) := by
  refine ⟨by decide, by decide, fun h => ?_⟩
  have := (h .B (by decide)).1
  exact absurd this (by decide)

theorem bug_double_tap_resume_point_of_other_rom :
    ¬ AutoOwner (run init (trDoubleTapTwo ++ [.fire 0])) := by
  refine not_autoOwner .B ⟨.C, some ⟨.B, 0⟩, some ⟨.B, 0⟩, true⟩ ?_ (by decide)
  decide

/-- **Double-tap the same tile** from a fresh page (the likeliest race here).
Session 1 played A and was hidden (a real resume point). New page: tap A
twice, the second before the first load's L3 hides the home screen. Both
taps miss the "already loaded" shortcut (current is set only at L3). The
first load reaches L4 one dbGet after L3; the second loadRom starts after its
own getRomBytes + touchRecent chain (tens of ms later), sees current = A, and
snapshots "the outgoing game": A's core seconds after boot. The real resume
point is overwritten by a fresh boot (`fresh = true`). -/
def sessionA : List Ev := playA ++ [.hide, .reload]
def trDoubleTapSame : List Ev :=
  sessionA ++ [.tap .A, .tap .A, .fire 0, .fire 0, .fire 0, .fire 1, .fire 0]

theorem bug_double_tap_overwrites_resume_point :
    (run init sessionA).auto .A = some ⟨.A, some ⟨.A, 0⟩, some ⟨.A, 0⟩, false⟩ ∧
    (run init trDoubleTapSame).auto .A = some ⟨.A, some ⟨.A, 0⟩, some ⟨.A, 0⟩, true⟩ := by
  decide

/-- **pagehide in the L3–L4 gap.** L3 names B current while FS rom.sav still
holds A's battery until restoreSave's dbGet returns (7892 vs 7916). Any
synchronous flusher in that gap — pagehide, beforeunload, the 5 s tick, a
second loadRom's L2 — writes A's battery to `save:B` (and A's core state to
`stateauto:B`). The 5 s tick case heals at the next tick if B stays current;
pagehide ends the page, so nothing heals it. -/
def trPagehideGap : List Ev :=
  abHome ++ [.tap .B, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .pagehide]

theorem bug_pagehide_in_load_gap :
    (run init trPagehideGap).idb .B = some ⟨.A, 1⟩ ∧ ¬ SaveOwner (run init trPagehideGap) ∧
    ¬ AutoOwner (run init trPagehideGap) :=
  ⟨by decide, not_saveOwner .B ⟨.A, 1⟩ (by decide) (by decide),
   not_autoOwner .B ⟨.A, some ⟨.A, 1⟩, some ⟨.A, 1⟩, false⟩ (by decide) (by decide)⟩

/-- **A Drive pull lands mid-load.** A was played and synced; another device
then saves A (version 1). New page: the pull checks `isRomLoaded(A)` (false),
starts the download; the player taps A; its L3 reads `save:A` (version 0) and
L4 boots it; the download lands and writes version 1 to `save:A`; the 5 s
autosave writes FS rom.sav (version 0) back over it and marks it for upload;
the upload sees bytes differing from the last synced signature and replaces
Drive's version 1. The other device's save now survives nowhere (its next pull
brings version 0 down over it too). -/
def trPullRace : List Ev :=
  playA ++ [.upload .A, .reload, .remoteSave .A, .pullCheck .A, .tap .A, .fire 1, .fire 1, .fire 1,
            .fire 0, .tick, .fire 1, .upload .A]

theorem bug_pull_mid_load_loses_remote_save :
    (run init (playA ++ [.upload .A, .reload, .remoteSave .A])).drive .A = some ⟨.A, 1⟩ ∧
    (run init trPullRace).idb .A = some ⟨.A, 0⟩ ∧
    (run init trPullRace).drive .A = some ⟨.A, 0⟩ ∧
    (run init trPullRace).fsSav = some ⟨.A, 0⟩ := by
  decide

/-- **Resume after an unflushed in-game save.** The offer's check (and its
re-check at the tap, 5682) compares the snapshot's signature with IndexedDB
`save:A`, which lags the live battery (FS rom.sav) by up to the 5 s autosave.
The game saves in game (version 1), the player taps Resume before the next
tick: IDB still holds version 0, the check passes, the snapshot's version-0
RAM is restored over version 1, and the next flush makes the loss durable. -/
def trResumeUnflushed : List Ev :=
  sessionA ++ [.tap .A, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .gameSave,
               .toastTap 0]

theorem bug_resume_restores_older_battery :
    (run init trResumeUnflushed).fsSav = some ⟨.A, 1⟩ ∧
    (step (run init trResumeUnflushed) (.fire 0)).fsSav = some ⟨.A, 0⟩ ∧
    ¬ ResumeKeepsBattery step (run init trResumeUnflushed) := by
  refine ⟨by decide, by decide, fun h => ?_⟩
  have := h 0 .A ⟨.A, some ⟨.A, 0⟩, some ⟨.A, 0⟩, false⟩ (some ⟨.A, 0⟩) (by decide)
  exact absurd this (by decide)

/-- All of the above are reachable. -/
theorem bug_traces_reachable :
    Reachable (run init trStaleSav) ∧ Reachable (run init trUnloadRace) ∧
    Reachable (run init (trDoubleTapTwo ++ [.fire 0])) ∧ Reachable (run init trDoubleTapSame) ∧
    Reachable (run init trPagehideGap) ∧ Reachable (run init trPullRace) ∧
    Reachable (run init trResumeUnflushed) :=
  ⟨reachable_run _ _ .init, reachable_run _ _ .init, reachable_run _ _ .init,
   reachable_run _ _ .init, reachable_run _ _ .init, reachable_run _ _ .init,
   reachable_run _ _ .init⟩

/-! ## The fixed code (`stepF`)

The smallest JS change set the model shows sufficient:

1. **Load token.** `let loadGen = 0;` — a tile tap, a file open and a close
   take `const gen = ++loadGen;` synchronously, and every continuation of
   launchRom/handleRomFile/loadRom/unloadGame returns when `gen !== loadGen`.
2. **Name the game only when the core holds it.** In loadRom, move
   `currentRomName = romName; currentOriginalName = …`, `paused = false` and
   the `has-game running` classes from before `await restoreSave` to after
   `initFromEmscripten` (one synchronous segment: write/unlink rom.sav, init,
   name), and set `loadingName = originalName` before the dbGet instead.
3. **restoreSave unlinks** `rom.sav` when there is no stored save.
4. **unloadGame** detaches, calls persistSave (its FS read is synchronous)
   and unlinks/tears down in the same segment: no `await` before the unlink.
5. **Resume** re-checks the snapshot's signature against FS rom.sav — the live
   battery — synchronously, just before `applyStateBytes`.
6. **The pull** treats `loadingName` as loaded (`isRomLoaded`) and re-checks
   after the download, just before writeSyncBytes.
-/

def bump (s : St) (g : G) (isLoad : Bool) : St :=
  { s with loadGen := s.loadGen + 1, gFlow := g, gIsLoad := isLoad }

def l3SegF (s : St) (g : G) (t : Nat) : St :=
  push { s with loading := some g } (.l4 g t (s.idb g))

def loadStartF (s : St) (g : G) (t : Nat) : St :=
  if s.cur.isSome then push (persistAuto s) (.l1 g t) else l3SegF s g t

def l4SegF (s : St) (g : G) (t : Nat) (v : Option Sav) : St :=
  push { s with fsSav := v, core := s.fsRom, coreRam := v, fresh := true, cur := some g,
                paused := false, hasGame := true, running := true } (.l5 g t)

def u2SegF (s : St) (g : G) : St :=
  let s1 := persistSave { s with cur := none } g .none
  { s1 with fsSav := none, paused := true, hasGame := false, running := false, card := none,
            loading := none }

def fireF (s : St) : Pend → St
  | .launchW g t => if t = s.loadGen then push { s with fsRom := some g } (.launchL g t) else s
  | .launchL g t => if t = s.loadGen then loadStartF s g t else s
  | .l1 g t => if t = s.loadGen then push s (.l2 g t) else s
  | .l2 g t =>
    if t = s.loadGen then
      match s.cur with
      | none => s
      | some c => persistSave s c (.l3 g t)
    else s
  | .l3 g t => if t = s.loadGen then l3SegF s g t else s
  | .l4 g t v => if t = s.loadGen then l4SegF s g t v else s
  | .l5 _ _ => offerStart s
  | .offer1 n a =>
    match a with
    | none => s
    | some a => if s.cur = some n then push s (.offer2 n a (s.idb n)) else s
  | .offer2 n a v =>
    if a.sig = v ∧ s.cur = some n then { s with toasts := s.toasts ++ [(n, a)] } else s
  | .res1 n a v =>
    if a.sig = v ∧ s.cur = some n ∧ a.sig = s.fsSav then applyState s a else s
  | .u1 g t => if t = s.loadGen then push s (.u2 g t) else s
  | .u2 g t => if t = s.loadGen then u2SegF s g else s
  | .u3 _ _ => s
  | .psDone g d k => pushAfter { s with lastSig := some (g, d), dirty := upd s.dirty g true } k
  | .pullW g d => if s.cur = some g ∨ s.loading = some g then s else pullWrite s g d

def stepF (s : St) : Ev → St
  | .tap g =>
    if s.running then s
    else if s.cur = some g then resumeGame s
    else push (bump s g true) (.launchW g (s.loadGen + 1))
  | .openFile g => push (bump s g true) (.launchW g (s.loadGen + 1))
  | .goHome => goHome s
  | .resume => if s.running then s else resumeGame s
  | .closeCard =>
    if s.running || s.card.isNone then s
    else match s.cur with
      | none => s
      | some g => push (persistAuto (bump s g false)) (.u1 g (s.loadGen + 1))
  | .frame => frame s
  | .gameSave => gameSave s
  | .tick => tick s
  | .hide => persistAuto s
  | .pagehide => pagehide s
  | .toastTap i => toastTap s i
  | .remoteSave g => remoteSave s g
  | .pullCheck g =>
    match s.drive g with
    | some d =>
      if s.cur ≠ some g ∧ s.loading ≠ some g ∧ some d ≠ s.synced g then push s (.pullW g d) else s
    | none => s
  | .upload g => upload s g
  | .reload => reload s
  | .fire i =>
    match s.pend[i]? with
    | none => s
    | some p => fireF { s with pend := s.pend.eraseIdx i } p

inductive ReachableF : St → Prop
  | init : ReachableF init
  | step {s} (e : Ev) : ReachableF s → ReachableF (stepF s e)

/-! ### The invariant of the fixed code -/

/-- The part of the state the pending continuations' claims read. -/
structure K where
  loadGen : Nat
  gFlow : G
  gIsLoad : Bool
  fsRom : Option G
  cur : Option G
  fsSav : Option Sav
  paused : Bool
  loading : Option G

def St.kv (s : St) : K :=
  ⟨s.loadGen, s.gFlow, s.gIsLoad, s.fsRom, s.cur, s.fsSav, s.paused, s.loading⟩

def SavOK (g : G) (v : Option Sav) : Prop := ∀ d, v = some d → d.owner = g

/-- A load holding the current token owns FS rom.<ext>. -/
def LoadClaim (k : K) (g : G) (t : Nat) : Prop :=
  t ≤ k.loadGen ∧ (t = k.loadGen → k.gIsLoad = true ∧ k.gFlow = g ∧ k.fsRom = some g)

/-- An unload holding the current token: its game is still current, or it
has already detached it. -/
def UnloadClaim (k : K) (g : G) (t : Nat) : Prop :=
  t ≤ k.loadGen ∧ (t = k.loadGen → k.gIsLoad = false ∧ k.gFlow = g ∧
    (k.cur = some g ∨ (k.cur = none ∧ k.fsSav = none ∧ k.paused = true)))

def AfterOK (k : K) : After → Prop
  | .none => True
  | .l3 g t => LoadClaim k g t
  | .u3 _ _ => False

def PendOK (k : K) : Pend → Prop
  | .launchW g t => t ≤ k.loadGen ∧ (t = k.loadGen → k.gIsLoad = true ∧ k.gFlow = g)
  | .launchL g t => LoadClaim k g t
  | .l1 g t => LoadClaim k g t
  | .l2 g t => LoadClaim k g t
  | .l3 g t => LoadClaim k g t
  | .l4 g t v => SavOK g v ∧ LoadClaim k g t ∧ (t = k.loadGen → k.loading = some g)
  | .l5 _ _ => True
  | .offer1 n a => ∀ a', a = some a' → SnapOK n a'
  | .offer2 n a _ => SnapOK n a
  | .res1 n a _ => SnapOK n a
  | .u1 g t => UnloadClaim k g t
  | .u2 g t => UnloadClaim k g t
  | .u3 _ _ => False
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

/-! #### Shapes of the shared segments -/

def afterList : After → List Pend
  | .none => []
  | .l3 g t => [.l3 g t]
  | .u3 g t => [.u3 g t]

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

/-! #### Invariant lemmas for the shared segments -/

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

/-! #### Transfer of the pending claims across a change of `kv` -/

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
  | launchW g t => exact ⟨by have := hq.1; omega, fun h => absurd h (by have := hq.1; omega)⟩
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
  | u3 => exact hq.elim
  | psDone g d a =>
    cases a with
    | none => trivial
    | l3 g t => exact loadClaim_bump hq hlt
    | u3 => exact hq.elim
  | pullW => exact hq

/-- The current load writes FS rom.<ext>: its own game, which is what every
current load claims. -/
theorem pendOK_fsRom {k : K} {g : G} {q : Pend} (hq : PendOK k q)
    (hf : k.gIsLoad = true ∧ k.gFlow = g) : PendOK { k with fsRom := some g } q := by
  have lc : ∀ g' t, LoadClaim k g' t → LoadClaim { k with fsRom := some g } g' t :=
    fun g' t h => ⟨h.1, fun ht => by
      obtain ⟨h1, h2, _⟩ := h.2 ht
      exact ⟨h1, h2, by simp only; rw [← h2, hf.2]⟩⟩
  cases q with
  | launchL g' t => exact lc g' t hq
  | l1 g' t => exact lc g' t hq
  | l2 g' t => exact lc g' t hq
  | l3 g' t => exact lc g' t hq
  | l4 g' t v => exact ⟨hq.1, lc g' t hq.2.1, hq.2.2⟩
  | psDone g' d a =>
    cases a with
    | l3 g'' t => exact lc g'' t hq
    | _ => exact hq
  | _ => exact hq

/-- The current load names its game in `loading`. -/
theorem pendOK_loading {k : K} {g : G} {q : Pend} (hq : PendOK k q)
    (hf : k.gIsLoad = true ∧ k.gFlow = g) : PendOK { k with loading := some g } q := by
  cases q with
  | l4 g' t v =>
    refine ⟨hq.1, hq.2.1, fun ht => ?_⟩
    obtain ⟨_, h2, _⟩ := hq.2.1.2 ht
    simp only; rw [← h2, hf.2]
  | _ => exact hq

/-- The current load's L4: a current unload cannot exist beside it. -/
theorem pendOK_l4 {k : K} {g : G} {v : Option Sav} {q : Pend} (hq : PendOK k q)
    (hl : k.gIsLoad = true) :
    PendOK { k with cur := some g, fsSav := v, paused := false } q := by
  have uc : ∀ g' t, UnloadClaim k g' t →
      UnloadClaim { k with cur := some g, fsSav := v, paused := false } g' t :=
    fun g' t h => ⟨h.1, fun ht => by
      have := (h.2 ht).1
      rw [hl] at this
      exact absurd this (by decide)⟩
  cases q with
  | u1 g' t => exact uc g' t hq
  | u2 g' t => exact uc g' t hq
  | _ => exact hq

/-- The current unload's detach: a current load cannot exist beside it. -/
theorem pendOK_u2 {k : K} {q : Pend} (hq : PendOK k q) (hl : k.gIsLoad = false) :
    PendOK { k with cur := none, fsSav := none, paused := true, loading := none } q := by
  have uc : ∀ g' t, UnloadClaim k g' t →
      UnloadClaim { k with cur := none, fsSav := none, paused := true, loading := none } g' t :=
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

/-! #### Preservation -/

theorem persistAuto_kv (s : St) : (persistAuto s).kv = s.kv := by
  obtain ⟨A, heq, _⟩ := persistAuto_shape s
  rw [heq]; rfl

theorem persistAuto_cur (s : St) : (persistAuto s).cur = s.cur := by
  obtain ⟨A, heq, _⟩ := persistAuto_shape s
  rw [heq]

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

theorem inv_l3SegF {s : St} {g : G} {t : Nat} (hI : Inv s) (hp : LoadClaim s.kv g t)
    (ht : t = s.loadGen) : Inv (l3SegF s g t) := by
  obtain ⟨hl, hf, _⟩ := hp.2 ht
  have h1 : Inv { s with loading := some g } :=
    ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts,
     fun q hq => pendOK_loading (hI.pend q hq) ⟨hl, hf⟩⟩
  exact inv_push h1 ⟨fun d hd => hI.save g d hd, hp, fun _ => rfl⟩

theorem inv_fireF {s : St} {p : Pend} (hI : Inv s) (hp : PendOK s.kv p) : Inv (fireF s p) := by
  cases p with
  | launchW g t =>
    simp only [fireF]
    split
    · rename_i ht
      obtain ⟨hl, hf⟩ := hp.2 ht
      have h1 : Inv { s with fsRom := some g } :=
        ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts,
         fun q hq => pendOK_fsRom (hI.pend q hq) ⟨hl, hf⟩⟩
      exact inv_push h1 ⟨by simp [St.kv, ht], fun _ => ⟨hl, hf, rfl⟩⟩
    · exact hI
  | launchL g t =>
    simp only [fireF]
    split
    · rename_i ht
      unfold loadStartF
      split
      · have h1 := inv_persistAuto hI
        refine inv_push h1 ?_
        rw [persistAuto_kv]; exact hp
      · exact inv_l3SegF hI hp ht
    · exact hI
  | l1 g t =>
    simp only [fireF]
    split
    · exact inv_push hI hp
    · exact hI
  | l2 g t =>
    simp only [fireF]
    split
    · split
      · exact hI
      · rename_i c hc
        exact inv_persistSave hI (savOK_cur hI hc) hp
    · exact hI
  | l3 g t =>
    simp only [fireF]
    split
    · rename_i ht; exact inv_l3SegF hI hp ht
    · exact hI
  | l4 g t v =>
    simp only [fireF]
    split
    · rename_i ht
      obtain ⟨hv, hlc, _⟩ := hp
      obtain ⟨hl, _, hrom⟩ := hlc.2 ht
      unfold l4SegF
      refine inv_push ⟨hI.save, hI.auto, hI.drive, ?_, ?_, hI.toasts, ?_⟩ trivial
      · intro g' hg'
        simp only [Option.some.injEq] at hg'
        subst hg'
        exact ⟨hrom, rfl, hv⟩
      · exact ⟨by simp, fun _ => rfl, fun _ _ h => by simp at h⟩
      · exact fun q hq => pendOK_l4 (hI.pend q hq) hl
    · exact hI
  | l5 =>
    simp only [fireF, offerStart]
    split
    · exact hI
    · exact inv_push hI (fun a' ha' => hI.auto _ a' ha')
  | offer1 n a =>
    simp only [fireF]
    split
    · exact hI
    · split
      · exact inv_push hI (hp _ rfl)
      · exact hI
  | offer2 n a v =>
    simp only [fireF]
    split
    · refine ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, ?_, hI.pend⟩
      intro x hx
      simp only [List.mem_append, List.mem_singleton] at hx
      rcases hx with hx | rfl
      · exact hI.toasts x hx
      · exact hp
    · exact hI
  | res1 n a v =>
    simp only [fireF]
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
    simp only [fireF]
    split
    · exact inv_push hI hp
    · exact hI
  | u2 g t =>
    simp only [fireF]
    split
    · rename_i ht
      obtain ⟨hl, _, hcur⟩ := hp.2 ht
      have hg : SavOK g s.fsSav := by
        rcases hcur with hc | ⟨_, hn, _⟩
        · exact savOK_cur hI hc
        · intro d hd; change s.fsSav = none at hn; rw [hn] at hd; exact absurd hd (by simp)
      unfold u2SegF
      obtain ⟨I, P, heq, hIdb, hP⟩ := persistSave_shape { s with cur := none } g .none
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
  | u3 => exact hp.elim
  | psDone g d a =>
    simp only [fireF]
    rw [pushAfter_eq]
    refine ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts, ?_⟩
    intro q hq
    simp only [List.mem_append] at hq
    rcases hq with hq | hq
    · exact hI.pend q hq
    · cases a with
      | none => simp [afterList] at hq
      | l3 g t => simp [afterList] at hq; subst hq; exact hp
      | u3 => exact hp.elim
  | pullW g d =>
    simp only [fireF]
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

theorem inv_stepF {s : St} (e : Ev) (hI : Inv s) : Inv (stepF s e) := by
  cases e with
  | tap g =>
    simp only [stepF]
    split
    · exact hI
    · split
      · exact inv_resumeGame hI
      · exact inv_push (inv_bump hI g true) ⟨by simp [bump, St.kv], fun _ => ⟨rfl, rfl⟩⟩
  | openFile g =>
    exact inv_push (inv_bump hI g true) ⟨by simp [bump, St.kv], fun _ => ⟨rfl, rfl⟩⟩
  | goHome =>
    simp only [stepF, goHome]
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
    simp only [stepF]
    split
    · exact hI
    · exact inv_resumeGame hI
  | closeCard =>
    simp only [stepF]
    split
    · exact hI
    · split
      · exact hI
      · rename_i g hg
        refine inv_push (inv_persistAuto (inv_bump hI g false)) ?_
        rw [persistAuto_kv]
        exact ⟨by simp [bump, St.kv], fun _ => ⟨rfl, rfl, .inl hg⟩⟩
  | frame =>
    simp only [stepF, frame]
    split
    · exact ⟨hI.save, hI.auto, hI.drive, hI.coh, hI.ui, hI.toasts, hI.pend⟩
    · exact hI
  | gameSave =>
    simp only [stepF, gameSave]
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
    simp only [stepF, tick]
    split
    · rename_i g hg; exact inv_persistSave hI (savOK_cur hI hg) trivial
    · exact hI
  | hide => exact inv_persistAuto hI
  | pagehide =>
    simp only [stepF, pagehide]
    split
    · rename_i g hg
      exact inv_persistAuto (inv_persistSave hI (savOK_cur hI hg) trivial)
    · exact hI
  | toastTap i =>
    simp only [stepF, toastTap]
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
    simp only [stepF, remoteSave, upd] at hd
    split at hd
    · subst_vars; simp only [Option.some.injEq] at hd; subst hd; rfl
    · exact hI.drive h d hd
  | pullCheck g =>
    simp only [stepF]
    split
    · rename_i d hd
      split
      · exact inv_push hI (hI.drive g d hd)
      · exact hI
    · exact hI
  | upload g =>
    simp only [stepF, upload]
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
    refine ⟨hI.save, hI.auto, hI.drive, fun _ h => absurd h (by simp [stepF, reload, init]),
      ?_, fun _ h => absurd h (by simp [stepF, reload, init]),
      fun _ h => absurd h (by simp [stepF, reload, init])⟩
    simp [UIAgree, stepF, reload, init]
  | fire i =>
    simp only [stepF]
    split
    · exact hI
    · rename_i p hp
      exact inv_fireF (inv_erase i hI) (hI.pend p (List.mem_of_getElem? hp))

theorem inv_init : Inv init :=
  ⟨fun _ _ h => absurd h (by simp [init]), fun _ _ h => absurd h (by simp [init]),
   fun _ _ h => absurd h (by simp [init]), fun _ h => absurd h (by simp [init]),
   by simp [UIAgree, init], fun _ h => absurd h (by simp [init]),
   fun _ h => absurd h (by simp [init])⟩

theorem reachableF_inv {s : St} (h : ReachableF s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step e _ ih => exact inv_stepF e ih

/-! ### What the fixed code keeps, under every interleaving -/

/-- No `save:<g>` ever holds another game's battery. -/
theorem fixed_save_owner {s : St} (h : ReachableF s) : SaveOwner s := (reachableF_inv h).save

/-- No `stateauto:<g>` is ever a state of another game, or carries RAM other
than the battery its signature names. -/
theorem fixed_auto_owner {s : St} (h : ReachableF s) : AutoOwner s := (reachableF_inv h).auto

/-- The named game is the game in the core, running on its own battery. -/
theorem fixed_cur_coherent {s : St} (h : ReachableF s) : CurCoherent s := (reachableF_inv h).coh

/-- body.has-game, body.running and the visible paused card agree with it. -/
theorem fixed_ui_agree {s : St} (h : ReachableF s) : UIAgree s := (reachableF_inv h).ui

/-- A Resume never changes the battery: it can only restore a snapshot whose
RAM is the live save. -/
theorem fixed_resume_keeps_battery {s : St} (h : ReachableF s) : ResumeKeepsBattery stepF s := by
  intro i n a v hi
  have hI := reachableF_inv h
  have hp : SnapOK n a := hI.pend _ (List.mem_of_getElem? hi)
  obtain ⟨_, hram, _⟩ := hp
  simp only [stepF, hi, fireF]
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
theorem fixed_pull_blocked_during_load {s : St} (h : ReachableF s) {g : G} {t : Nat}
    {v : Option Sav} (hl : Pend.l4 g t v ∈ s.pend) (ht : t = s.loadGen) {i : Nat} {d : Sav}
    (hi : s.pend[i]? = some (.pullW g d)) : (stepF s (.fire i)).idb g = s.idb g := by
  have hload : s.loading = some g := ((reachableF_inv h).pend _ hl).2.2 ht
  simp [stepF, hi, fireF, hload]

def tokOf : Pend → Option Nat
  | .launchW _ t | .launchL _ t | .l1 _ t | .l2 _ t | .l3 _ t | .l4 _ t _ | .u1 _ t | .u2 _ t => some t
  | _ => none

/-- A superseded load or close does nothing when it resumes. -/
theorem fixed_stale_noop (s : St) (i : Nat) (p : Pend) (t : Nat) (hp : s.pend[i]? = some p)
    (ht : tokOf p = some t) (hne : t ≠ s.loadGen) :
    stepF s (.fire i) = { s with pend := s.pend.eraseIdx i } := by
  simp only [stepF, hp]
  cases p <;> simp only [tokOf, Option.some.injEq, reduceCtorEq] at ht <;> subst ht <;>
    simp [fireF, hne]

def runF (s : St) (es : List Ev) : St := es.foldl stepF s

theorem reachableF_runF (es : List Ev) : ∀ s, ReachableF s → ReachableF (runF s es) := by
  induction es with
  | nil => intro s h; exact h
  | cons e es ih => intro s h; exact ih _ (ReachableF.step e h)

/-- Whatever the user, the timers, the page and Drive do, in whatever order. -/
theorem fixed_every_trace (es : List Ev) :
    SaveOwner (runF init es) ∧ AutoOwner (runF init es) ∧ CurCoherent (runF init es) ∧
    UIAgree (runF init es) := by
  have h := reachableF_runF es init .init
  exact ⟨fixed_save_owner h, fixed_auto_owner h, fixed_cur_coherent h, fixed_ui_agree h⟩

/-! ### The fix is not vacuous: it still loads, switches and closes games -/

def bootF (g : G) : List Ev := [.openFile g, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0]

/-- Opening a file loads it. -/
example : (runF init (bootF .A)).cur = some .A ∧ (runF init (bootF .A)).core = some .A := by
  decide

/-- Double-tapping two tiles: the later tap wins, the earlier load is dropped,
and B is never named or booted. -/
example :
    let s := runF init (bootF .A ++ [.gameSave, .goHome, .tap .B, .tap .C, .fire 0, .fire 0,
                                      .fire 0, .fire 0, .fire 0, .fire 0, .fire 0, .fire 0])
    s.cur = some .C ∧ s.core = some .C ∧ s.fsSav = none ∧ s.pend = [.l5 .C 3] := by
  decide

/-- Closing the paused game while a tile's load is in flight: the close
supersedes the load, and A's save is A's. -/
example :
    let s := runF init (bootF .A ++ [.gameSave, .goHome, .tap .B, .fire 0, .fire 0, .closeCard,
                                      .fire 0, .fire 0, .fire 0, .fire 0, .fire 0])
    s.cur = none ∧ s.idb .A = some ⟨.A, 0⟩ ∧ s.hasGame = false := by
  decide

end WebState.GameLifecycle
