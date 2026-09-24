/-
# Battery-save and save-state persistence (web/index.js)

What a game's battery save goes through on its way from the wasm core to the
IndexedDB key `save:<game>` (and from there to Drive's upload queue), and back.

`step` models the code as fixed on the branch worktree-lean-web-state, up to
and including the commit "web: flush the solo core wherever its file is read;
Reset, Delete and Import retire a waiting quota retry" (line numbers are at
that commit). The machine at dd7ba741f, and its seven counterexamples, are in
this file's history; each trace is replayed against `step` as a `regress_*`
theorem.

* The core keeps the cart's battery RAM in memory and marks it dirty when the
  game writes it (`ram_dirty`, gb.nim; `storage.dirty`, gba storage.nim). Once
  per emulated frame the dirty RAM is written to the emscripten MEMFS file
  next to the ROM (`handle_saves`: gb.nim 3494 `mbc_save`, gba.nim 1449
  `write_save`); a paused core runs no frames, so a state loaded while paused
  leaves its RAM in the core only. `wasm_flush_save` (dingbat_wasm.nim) writes
  it on demand: `flushSoloSave` (5313) calls it for the loaded solo game, and
  every reader of that game's file calls `flushSoloSave` first. Every solo ROM
  is the FS file `rom.<ext>` (written at the boot, loadRom 8047), so there is
  ONE battery file, `rom.sav`, shared by every game.
* `persistSave(romName, originalName)` (5320) flushes the solo core when
  `romName` is the loaded game's (5323), reads that file synchronously, skips
  if its signature equals `lastSaveSig` for the same name, else takes the next
  number in `persistSeq` (5306, 5328-5329) and
  `await dbPutRoomy("save:" + originalName, ...)` (4305; the put is issued in
  the same segment; a QuotaExceededError evicts a ROM and re-issues the put
  after an await, unless something has taken a later number for the same save
  meanwhile, 4309), then remembers the signature and calls
  `markUpload("save:" + originalName)` (2690). A later persist, and a delete
  (`retireSavePuts` 5307: deleteKeys 1564, resetCurrentSaveFile 1587) or an
  import (5414) of the same save, each take a number.
  Callers: the 5 s `setInterval` (11399), `beforeunload` (11413) and `pagehide`
  (11435) with the *current* names; `loadRom` (8031) for the outgoing game;
  `unloadGame` (9844) for the game it closes, before its names are nulled.
* `loadRom` (8012): outgoing game: `await persistAutoState()`,
  `await storeLastFrame()`, `await persistSave(...)`; then `loadingName = g`
  and `await dbGet("save:" + g)` (8037-8038); then ONE segment (8047-8085)
  writes the ROM, `installSave` (5356: writes the FS `.sav`, or unlinks it
  when there is no stored save, and sets `lastSaveSig` to what it wrote),
  `initFromEmscripten` (builds the new core, which reads `rom.sav` if it
  exists, gba.nim 1303 `new_storage`, gb `mbc_load`; no flush of the outgoing
  core), clears `loadingName`, and names the game, `paused = false`. Then
  `offerAutoResume` (5778).
* Resume snapshot: `persistAutoState` (5742) stores `stateauto:<game>` with
  the FS `.sav` signature (`liveSaveSig` 5756, which flushes first: the
  signature is the battery the state carries); `offerAutoResume` and the
  toast's tap re-check it against `save:<game>` (`autoStateMatchesSave`), and
  the tap also against the live battery (5793-5794) before `applyStateBytes`,
  which marks the cart RAM dirty (gb savestate.nim 755, gba savestate.nim 646).
* Slots: `saveToSlot` (5664), `loadFromSlot` (5704). Import:
  `applyImportedSave` (5394) detaches the game (as Reset), retires waiting
  puts, puts the imported bytes, `markUpload`s them and reboots. Delete:
  `deleteGameAction` (1957) -> `unloadGame({flushSave:false})` (9828) ->
  `deleteGameEverywhere` (3192). Close: `unloadGame` (9828): after its awaits,
  if no later load or close has taken the token, flush, detach and unlink in
  one segment (9844-9847). Reset: `resetGameAction` (1883) detaches a loaded
  game first (`detachLoadedGame` 1603: the token, unlink the FS .sav, null the
  names), then `resetGameSaves` (3184), then reboots it with `loadRom`; the
  Saves panel's `resetCurrentSaveFile` (1582) does the same. Drive pull: the
  `isRomLoaded || loadingName` guard before `await driveDownload` (3044) and
  again after it (3050), then `writeSyncBytes` (2484).

## Model

Games are `Nat`s. A save image is `Bytes`: the game whose cart produced it and
a logical version stamp (a global clock, starting at 1). Byte equality stands
for signature equality (`saveSignature` collisions ignored).

Every `await` is a pending continuation in `pend`; `resume i ok` runs the
`i`-th one whenever the scheduler likes. IndexedDB requests take effect at the
moment they are issued, and a `dbGet` captures its value then: the blobs store
is one object store and IndexedDB runs transactions with overlapping scope in
creation order, so this is exact for ordering. A persist whose put resolves
and the `await persistSave(...)` that waits on it are one event (the chain of
promise resolutions runs in one microtask checkpoint).

## Abstractions (and why they do not affect the properties)

* One slot (slot 0) stands for all nine; `-p2` link saves, 2P link mode,
  rollback/netplay (all refuse or bypass `persistSave`), rename (which
  detaches the name before any await) and the thumbnail batch (scratch FS
  names) are not modelled.
* The load token (`loadGen`) is not modelled here (GameLifecycle has it): any
  number of loads may be in flight and each may boot. That is a superset of
  the JS, where only the latest does; `unloadGame`'s token check is modelled
  as "the game it set out to close is still the one named".
* `storeLastFrame`, cheats, art, `recent`, Drive's own queue processing: no
  effect on the modelled keys; their awaits are merged with adjacent awaits
  (merging two awaits between which only effect-free code runs loses no
  behaviour of the modelled state).
* `markUpload` is recorded with the bytes the persist wrote (`uploads`); what
  Drive does with its queue is the Drive machine's business. `markDelete` is
  recorded as `deletes`.
* Every cart is modelled as having a battery. A save-less cart only narrows
  the core-side paths; `persistSave` reads `rom.sav` whatever the cart is.
* The frame loop is allowed whenever `!paused` and a core exists (rAF is
  throttled when hidden; allowing more frames only adds behaviours).
* The core's state-header check (`stateRejectMessage`) is modelled as
  "a state applies only to a core of the same game".
* A Resume toast never expires in the model (it lives 8 s in the page).
* `pullStart g` is the Drive pull reaching `save:<g>` (the other device's
  newer save, a fresh version); only its interaction with `save:<g>` is modelled.
-/
namespace WebState.SavePersistence

/-- `f` with `k ↦ v`. -/
def upd {α : Type} (f : Nat → α) (k : Nat) (v : α) : Nat → α :=
  fun x => if x = k then v else f x

@[simp] theorem upd_same {α : Type} (f : Nat → α) (k : Nat) (v : α) : upd f k v k = v := by
  simp [upd]

theorem upd_apply {α : Type} (f : Nat → α) (k : Nat) (v : α) (x : Nat) :
    upd f k v x = if x = k then v else f x := rfl

/-- A battery-save image: the game whose cart produced it, and when. -/
structure Bytes where
  game : Nat
  ver  : Nat
deriving DecidableEq, Repr

/-- The wasm core (`stateGb`/`stateGba`). -/
structure Core where
  game  : Nat
  gb    : Bool          -- a GB/GBC core
  ram   : Option Bytes  -- cart battery RAM; none = never written
  dirty : Bool          -- gb `cart.ram_dirty` / gba `storage.dirty`
deriving DecidableEq, Repr

/-- A `stateauto:<game>` record (persistAutoState 5742): the captured core and
    `saveSig`. -/
structure Snap where
  core    : Core
  saveSig : Option Bytes   -- sigOfSave(FS .sav at capture); none = no .sav
deriving DecidableEq, Repr

/-- What the awaiting caller of a `persistSave` does when it returns. -/
inductive After where
  | none                      -- the setInterval / pagehide / beforeunload / unloadGame call
  | load (g : Nat) (gb : Bool) -- loadRom 8031: the rest of loadRom
deriving DecidableEq, Repr

inductive Pending where
  /-- persistSave 5330: `dbPutRoomy` put issued and accepted; awaiting it. -/
  | persist (g : Nat) (b : Bytes) (k : After)
  /-- dbPutRoomy 4318: the put failed with QuotaExceededError; awaiting
      `evictOldestRom`, after which the same bytes are put again, unless
      something has taken a number for this save past `t` (4309). -/
  | evict (g : Nat) (b : Bytes) (k : After) (t : Nat)
  /-- loadRom 8027-8031: awaiting persistAutoState + storeLastFrame. -/
  | loadPre (g : Nat) (gb : Bool)
  /-- loadRom 8038: awaiting `dbGet("save:"+g)` (= v). -/
  | loadRestore (g : Nat) (gb : Bool) (v : Option Bytes)
  /-- offerAutoResume 5783: awaiting `dbGet(stateauto)` (= a). -/
  | offerGet (g : Nat) (a : Option Snap)
  /-- offerAutoResume 5786 / autoStateMatchesSave: awaiting `dbGet(save)`. -/
  | offerCheck (g : Nat) (a : Snap) (v : Option Bytes)
  /-- the Resume toast's handler 5793: awaiting `dbGet(save)`. -/
  | tapCheck (g : Nat) (a : Snap) (v : Option Bytes)
  /-- unloadGame 9834-9837: awaiting persistAutoState + storeLastFrame. -/
  | unloadPre (g : Nat) (flush : Bool) (thenDelete : Bool)
  /-- deleteGameEverywhere 3193 -> deleteKeys: awaiting the rom/art/frame deletes. -/
  | delSaves (g : Nat)
  /-- ... save:g deleted; awaiting the slot + session deletes. -/
  | delRest (g : Nat)
  /-- resetGameAction 1887: save:g deleted; awaiting the other deletes. `loaded`:
      the game was loaded and has been detached; `gb`: its core's kind. -/
  | resetRest (g : Nat) (loaded : Bool) (gb : Bool)
  /-- loadFromSlot: awaiting `dbGet(state:g)` (= v). -/
  | slotGet (g : Nat) (v : Option Core)
  /-- applyImportedSave 5415: awaiting `dbPut(save:g)` of the imported bytes. -/
  | importPut (g : Nat) (gb : Bool)
  /-- Drive pull 3044-3046: passed the guard, awaiting `driveDownload`. -/
  | pull (g : Nat) (b : Bytes)
deriving DecidableEq, Repr

structure St where
  clock   : Nat
  idb     : Nat → Option Bytes   -- IndexedDB "save:<g>"
  auto    : Nat → Option Snap    -- IndexedDB "stateauto:<g>"
  slot    : Nat → Option Core    -- IndexedDB "state:<g>"
  fs      : Option Bytes         -- MEMFS "rom.sav" (every solo ROM is rom.<ext>)
  core    : Option Core          -- stateGb / stateGba
  paused  : Bool                 -- paused
  cur     : Option Nat           -- currentRomName && currentOriginalName
  lastSig : Option (Nat × Bytes) -- lastSaveSigKey / lastSaveSig
  seq     : Nat → Nat            -- persistSeq (5306): the last number taken for save:g
  loading : Option Nat           -- loadingName
  pend    : List Pending         -- in-flight continuations
  toast   : Option (Nat × Snap)  -- the Resume action toast
  -- ghost state (not in the JS; for stating properties)
  writes  : List (Nat × Bytes)   -- every persist put of save:g accepted by IDB
  uploads : List (Nat × Bytes)   -- markUpload("save:"+g), with the bytes persist wrote
  resumes : List (Nat × Snap × Option Bytes) -- applied Resumes: game, snapshot, save seen by the check
  deletes : List Nat             -- markDelete("save:"+g)
  wiped   : Nat → Option Nat     -- clock when save:g was last deleted by the user
  floor   : Nat → Nat            -- newest version of g's save ever written to rom.sav or save:g

def init : St :=
  { clock := 1, idb := fun _ => none, auto := fun _ => none, slot := fun _ => none,
    fs := none, core := none, paused := false, cur := none, lastSig := none, seq := fun _ => 0,
    loading := none, pend := [], toast := none, writes := [], uploads := [], resumes := [],
    deletes := [], wiped := fun _ => none, floor := fun _ => 0 }

inductive Ev where
  | play                    -- the running game writes its cart battery RAM
  | frame                   -- handle_saves: dirty RAM -> rom.sav (once per frame)
  | pause                   -- showMainMenu (home) / pause button
  | unpause                 -- resumeGame (9562): needs a loaded game
  | tick (ok : Bool)        -- setInterval 11399 / pagehide 11435 / beforeunload 11413: persistSave(current names); ok = the put is accepted
  | hide                    -- visibilitychange 11420 / pagehide: persistAutoState()
  | launch (g : Nat) (gb : Bool) -- loadRom("rom.<ext>", g): tile tap (launchRom 4535), file drop, restart
  | resume (i : Nat) (ok : Bool) -- the i-th pending continuation runs
  | close                   -- "Close" on the paused card: unloadGame() (9871)
  | delete (g : Nat)        -- deleteGameAction(g) (1957)
  | reset (g : Nat)         -- resetGameAction(g) (1883) / resetCurrentSaveFile (1582)
  | tapResume               -- tap "Resume" on the toast
  | slotSave                -- saveToSlot(0)
  | slotLoad                -- loadFromSlot(0)
  | importSave              -- applyImportedSave, after the confirms (5406)
  | pullStart (g : Nat)     -- Drive pull reaches save:g (3044)
deriving DecidableEq, Repr

def push (s : St) (p : Pending) : St := { s with pend := s.pend ++ [p] }

/-- ghost: g's save at version b.ver has been written somewhere durable-ish. -/
def raise (s : St) (b : Bytes) : St :=
  { s with floor := upd s.floor b.game (max (s.floor b.game) b.ver) }

/-- `flushSoloSave` (5313) -> `wasm_flush_save`: with a game loaded, the core's
    dirty battery RAM into `rom.sav`, now. -/
def flushCore (s : St) : St :=
  match s.cur, s.core with
  | some _, some c =>
    if c.dirty then
      match c.ram with
      | some r => raise { s with fs := some r, core := some { c with dirty := false } } r
      | none => s
    else s
  | _, _ => s

/-- loadRom 8036-8038 after the outgoing persist: `loadingName = g`, the dbGet
    of the incoming save. Nothing is switched yet: the outgoing game stays
    named, on its own `rom.sav`, until the boot (`l4`). -/
def l3 (s : St) (g : Nat) (gb : Bool) : St :=
  push { s with loading := some g } (.loadRestore g gb (s.idb g))

def finish (s : St) : After → St
  | .none => s
  | .load g gb => l3 s g gb

/-- persistSave 5320-5331, its synchronous first segment: the flush (for the
    loaded game's file), then the read. -/
def persistCall (s : St) (g : Nat) (ok : Bool) (k : After) : St :=
  let s := if s.cur = some g then flushCore s else s        -- 5323
  match s.fs with
  | none => finish s k                                     -- 5324 no FS file
  | some b =>
    if s.lastSig = some (g, b) then finish s k              -- 5327 unchanged
    else
      let t := s.seq g + 1                                  -- 5328-5329 persistSeq
      let s := { s with seq := upd s.seq g t }
      if ok then                                            -- 5330-5331 put issued, accepted
        push (raise { s with idb := upd s.idb g (some b), writes := s.writes ++ [(g, b)] } b)
          (.persist g b k)
      else push s (.evict g b k t)                          -- 4318 quota: evict, retry

/-- persistAutoState 5742-5749 (the dbPut's effect; nobody awaits its tail):
    the state captured, then `liveSaveSig` flushes and reads the file. -/
def autoSnap (s : St) : St :=
  match s.cur, s.core with
  | some g, some c =>
    let s1 := flushCore s
    { s1 with auto := upd s1.auto g (some ⟨c, s1.fs⟩) }
  | _, _ => s

/-- loadRom 8012-8027, first segment: the load token (which clears
    `loadingName`), then the outgoing game's snapshot and await. -/
def launchCall (s : St) (g : Nat) (gb : Bool) : St :=
  let s := { s with loading := none }
  match s.cur with
  | some _ => push (autoSnap s) (.loadPre g gb)
  | none => l3 s g gb          -- nothing loaded: straight to the dbGet

/-- offerAutoResume 5778-5783: first segment. -/
def offerStart (s : St) : St :=
  match s.cur with
  | some n => push s (.offerGet n (s.auto n))
  | none => s

/-- loadRom 8047-8085, one segment: installSave replaces `rom.sav` by exactly
    the incoming save (unlinks it when there is none) and remembers its
    signature; initFromEmscripten builds the new core on it (and flushes no
    outgoing core); `loadingName` is cleared and the game named. Then
    offerAutoResume's start (8100). -/
def l4 (s : St) (g : Nat) (gb : Bool) (v : Option Bytes) : St :=
  offerStart { s with fs := v, cur := some g, paused := false, core := some ⟨g, gb, v, false⟩,
                      loading := none, lastSig := v.map (fun b => (g, b)) }

/-- applyStateBytes with the core's header check. -/
def applyState (s : St) (sc : Core) : St :=
  match s.core with
  | some c => if sc.game = c.game then { s with core := some { sc with dirty := true } } else s
  | none => s

/-- An explicit state load is the user's choice of save: a fresh version. -/
def restamp (t : Nat) (sc : Core) : Core :=
  { sc with ram := sc.ram.map (fun r => ⟨r.game, t⟩) }

def gbOf (s : St) : Bool := match s.core with | some c => c.gb | none => false

/-- A delete or an import of save:g takes a `persistSeq` number
    (`retireSavePuts` 5307): a put waiting on an eviction gives way. -/
def retire (s : St) (g : Nat) : St := { s with seq := upd s.seq g (s.seq g + 1) }

def resumeP (s : St) (p : Pending) (ok : Bool) : St :=
  match p with
  | .persist g b k =>                                       -- 5340-5343
      finish { s with lastSig := some (g, b), uploads := s.uploads ++ [(g, b)] } k
  | .evict g b k t =>
      if ok then                                            -- 4318: evicted one
        if s.seq g ≠ t then finish s k                      -- 4309, 5332: taken over
        else                                                -- 4314: put again
          push (raise { s with idb := upd s.idb g (some b), writes := s.writes ++ [(g, b)] } b)
            (.persist g b k)
      else finish { s with lastSig := none } k               -- 5333-5338: nothing left to give
  | .loadPre g gb =>                                        -- 8031 (names re-read here)
      match s.cur with
      | some a => persistCall s a ok (.load g gb)
      | none => s
  | .loadRestore g gb v => l4 s g gb v
  | .offerGet g a =>                                        -- 5785-5786
      match a with
      | some a' => if s.cur = some g then push s (.offerCheck g a' (s.idb g)) else s
      | none => s
  | .offerCheck g a v =>                                    -- 5786-5788
      if a.saveSig = v ∧ s.cur = some g then { s with toast := some (g, a) } else s
  | .tapCheck g a v =>                                      -- 5793-5798: stored and live save
      if a.saveSig = v ∧ s.cur = some g then
        let s := flushCore s                                -- liveSaveSig flushes first
        if a.saveSig = s.fs then applyState { s with resumes := s.resumes ++ [(g, a, v)] } a.core
        else s
      else s
  | .unloadPre g flush thenDelete =>
      -- 9835-9837: a later load or close has taken the token: the game it set
      -- out to close is no longer the one named.
      if s.cur != some g then s
      else if flush then
        -- 9844-9847: the flush (the core's RAM, then the file), while the name
        -- still says the core is g's; then detach and unlink, one segment
        let s2 := persistCall s g ok .none
        { s2 with cur := none, fs := none, paused := true }
      else
        let s2 := { s with cur := none, fs := none, paused := true }  -- 9845-9847, 9851
        if thenDelete then push s2 (.delSaves g) else s2   -- 1967 deleteGameEverywhere
  | .delSaves g =>                                          -- deleteKeys 1564-1565
      push (retire { s with idb := upd s.idb g none, wiped := upd s.wiped g (some s.clock),
                            floor := upd s.floor g 0 } g) (.delRest g)
  | .delRest g =>
      { s with slot := upd s.slot g none, auto := upd s.auto g none, deletes := s.deletes ++ [g] }
  | .resetRest g loaded gb =>
      let s1 := { s with slot := upd s.slot g none, auto := upd s.auto g none,
                         deletes := s.deletes ++ [g] }
      if loaded then launchCall s1 g gb else s1             -- 1889 the reboot: loadRom
  | .slotGet _ v =>                                         -- loadFromSlot (no name re-check)
      match v with
      | some sc => applyState { s with clock := s.clock + 1 } (restamp s.clock sc)
      | none => s
  | .importPut g gb =>                                      -- 5416-5420: markUpload, reboot
      launchCall s g gb
  | .pull g b =>                                            -- 3050-3053: re-checked, written
      if s.cur = some g ∨ s.loading = some g then s
      else raise { s with idb := upd s.idb g (some b) } b

def step (s : St) : Ev → St
  | .play =>
      if s.paused then s else
      match s.core with
      | some c => { s with core := some { c with ram := some ⟨c.game, s.clock⟩, dirty := true },
                           clock := s.clock + 1 }
      | none => s
  | .frame =>
      if s.paused then s else
      match s.core with
      | some c =>
        if c.dirty then
          match c.ram with
          | some r => raise { s with fs := some r, core := some { c with dirty := false } } r
          | none => s
        else s
      | none => s
  | .pause => { s with paused := true }
  | .unpause => if s.cur.isSome then { s with paused := false } else s
  | .tick ok =>
      match s.cur with
      | some g => persistCall s g ok .none
      | none => s
  | .hide => autoSnap s
  | .launch g gb => launchCall s g gb
  | .resume i ok =>
      match s.pend[i]? with
      | some p => resumeP { s with pend := s.pend.eraseIdx i } p ok
      | none => s
  | .close =>                                               -- 9828-9834: the token, then
      match s.cur with
      | some g => push (autoSnap { s with loading := none }) (.unloadPre g true false)
      | none => s
  | .delete g =>                                            -- 1958-1967
      if s.cur = some g then push { s with loading := none } (.unloadPre g false true)
      else push s (.delSaves g)
  | .reset g =>
      -- 1884-1887: a loaded game is detached first (detachLoadedGame 1603-1611:
      -- the token, unlink the FS .sav, null the names), in the same segment as
      -- the first delete (resetGameSaves 3184 -> deleteSaveData -> deleteKeys
      -- 1564-1565: the persistSeq number, then save:g).
      let loaded := decide (s.cur = some g)
      let s0 := if loaded then { s with fs := none, cur := none, loading := none } else s
      push (retire { s0 with idb := upd s0.idb g none, wiped := upd s0.wiped g (some s0.clock),
                             floor := upd s0.floor g 0 } g) (.resetRest g loaded (gbOf s))
  | .tapResume =>
      match s.toast with
      | some (g, a) =>
        let s1 := { s with toast := none }
        if s.cur = some g then push s1 (.tapCheck g a (s.idb g)) else s1   -- 5789-5793
      | none => s
  | .slotSave =>
      match s.cur, s.core with
      | some g, some c => { s with slot := upd s.slot g (some c) }
      | _, _ => s
  | .slotLoad =>
      match s.cur with
      | some g => push s (.slotGet g (s.slot g))
      | none => s
  | .importSave =>
      -- 5412-5415: detached (as Reset), the persistSeq number, the put issued
      match s.cur, s.core with
      | some g, some c =>
        let b : Bytes := ⟨g, s.clock⟩
        push (raise (retire { s with fs := none, cur := none, loading := none,
                                     idb := upd s.idb g (some b), clock := s.clock + 1 } g) b)
          (.importPut g c.gb)
      | _, _ => s
  | .pullStart g =>
      if s.cur = some g ∨ s.loading = some g then s         -- 3044
      else push { s with clock := s.clock + 1 } (.pull g ⟨g, s.clock⟩)

inductive Reachable : St → Prop
  | init : Reachable init
  | step {s : St} (e : Ev) : Reachable s → Reachable (step s e)

def run (s : St) : List Ev → St
  | [] => s
  | e :: es => run (step s e) es

theorem run_reachable (s : St) (es : List Ev) (h : Reachable s) :
    Reachable (run s es) := by
  induction es generalizing s with
  | nil => exact h
  | cons e es ih => exact ih _ (Reachable.step e h)
/-! ## Properties -/

/-- `save:<g>` only ever holds bytes produced by game `g`'s cart. -/
def Prov (s : St) : Prop := ∀ g b, s.idb g = some b → b.game = g

/-- After the user deletes `save:<g>`, only saves produced after the delete
    may appear under it. -/
def NoResurrect (s : St) : Prop :=
  ∀ g b t, s.idb g = some b → s.wiped g = some t → t ≤ b.ver

/-- The version of `g`'s save in a slot (0 = none, or another game's bytes). -/
def verOf (g : Nat) : Option Bytes → Nat
  | some b => if b.game = g then b.ver else 0
  | none => 0

/-- The newest save `g` has written (to `rom.sav` or `save:<g>`) is still
    held: in `save:<g>`, or in `rom.sav` while `g` is loaded (the next
    persist carries it over). -/
def Durable (s : St) (g : Nat) : Prop :=
  s.floor g ≤ verOf g (s.idb g) ∨ (s.cur = some g ∧ s.floor g ≤ verOf g s.fs)

/-! ## Provenance, under every interleaving

What it rests on: (1) loadRom fetches the incoming save before it switches
anything, and then, in the one synchronous segment that switches the names and
runs initFromEmscripten, replaces `rom.sav` by exactly that save (unlinking it
when there is none); (2) initFromEmscripten no longer `mbc_save`s the outgoing
GB core into the file; (3) unloadGame re-checks after its awaits that the game
it is closing is still the loaded one, and detaches, flushes and unlinks in one
segment; (4) Reset detaches before its deletes. -/

def WF (c : Core) : Prop := ∀ r, c.ram = some r → r.game = c.game

def POK : Pending → Prop
  | .persist g b _ => b.game = g
  | .evict g b _ _ => b.game = g
  | .loadRestore g _ v => ∀ b, v = some b → b.game = g
  | .offerGet _ a => ∀ a', a = some a' → WF a'.core
  | .offerCheck _ a _ => WF a.core
  | .tapCheck _ a _ => WF a.core
  | .slotGet _ v => ∀ c, v = some c → WF c
  | .pull g b => b.game = g
  | _ => True

structure FInv (s : St) : Prop where
  idb   : ∀ g b, s.idb g = some b → b.game = g
  fs    : ∀ b, s.fs = some b → ∃ c, s.core = some c ∧ c.game = b.game
  cur   : ∀ g, s.cur = some g → ∃ c, s.core = some c ∧ c.game = g
  core  : ∀ c, s.core = some c → WF c
  auto  : ∀ g a, s.auto g = some a → WF a.core
  slot  : ∀ g c, s.slot g = some c → WF c
  toast : ∀ g a, s.toast = some (g, a) → WF a.core
  pend  : ∀ p ∈ s.pend, POK p

theorem finv_congr {s s' : St} (h : FInv s) (h1 : s'.idb = s.idb) (h2 : s'.fs = s.fs)
    (h3 : s'.cur = s.cur) (h4 : s'.core = s.core) (h5 : s'.auto = s.auto)
    (h6 : s'.slot = s.slot) (h7 : s'.toast = s.toast) (h8 : s'.pend = s.pend) : FInv s' := by
  constructor
  · rw [h1]; exact h.idb
  · rw [h2, h4]; exact h.fs
  · rw [h3, h4]; exact h.cur
  · rw [h4]; exact h.core
  · rw [h5]; exact h.auto
  · rw [h6]; exact h.slot
  · rw [h7]; exact h.toast
  · rw [h8]; exact h.pend

theorem finv_init : FInv init := by
  constructor <;> simp [init]

theorem push_inv {s : St} {p : Pending} (h : FInv s) (hp : POK p) : FInv (push s p) := by
  constructor
  · exact h.idb
  · exact h.fs
  · exact h.cur
  · exact h.core
  · exact h.auto
  · exact h.slot
  · exact h.toast
  · intro q hq
    simp only [push, List.mem_append, List.mem_singleton] at hq
    rcases hq with hq | rfl
    · exact h.pend q hq
    · exact hp

theorem raise_inv {s : St} (b : Bytes) (h : FInv s) : FInv (raise s b) :=
  finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl

theorem fs_of_cur {s : St} (h : FInv s) {g : Nat} (hc : s.cur = some g) :
    ∀ b, s.fs = some b → b.game = g := by
  intro b hb
  obtain ⟨c, hc1, hc2⟩ := h.fs b hb
  obtain ⟨c', hc1', hc2'⟩ := h.cur g hc
  rw [hc1] at hc1'
  cases hc1'
  omega

/-- Detached: no name, the FS .sav unlinked, paused (unloadGame). -/
theorem finv_detach {s : St} (h : FInv s) :
    FInv { s with cur := none, fs := none, paused := true } := by
  constructor
  · exact h.idb
  · intro b hb; simp at hb
  · intro g' hg'; simp at hg'
  · exact h.core
  · exact h.auto
  · exact h.slot
  · exact h.toast
  · exact h.pend

/-- The FS .sav unlinked and the game paused (unloadGame, detachLoadedGame). -/
theorem finv_unlink {s : St} (h : FInv s) : FInv { s with fs := none, paused := true } := by
  constructor
  · exact h.idb
  · intro b hb; simp at hb
  · exact h.cur
  · exact h.core
  · exact h.auto
  · exact h.slot
  · exact h.toast
  · exact h.pend

theorem l3_inv {s : St} (g : Nat) (gb : Bool) (h : FInv s) : FInv (l3 s g gb) := by
  simp only [l3]
  exact push_inv (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl) (fun b hb => h.idb g b hb)

theorem finish_inv {s : St} (k : After) (h : FInv s) : FInv (finish s k) := by
  cases k with
  | none => exact h
  | load g gb => exact l3_inv g gb h

/-- The flush touches `rom.sav`, the core's dirty flag and the ghost floor only. -/
theorem flushCore_eq (s : St) :
    ∃ f c fl, flushCore s = { s with fs := f, core := c, floor := fl } := by
  unfold flushCore
  split
  · split
    · split
      · exact ⟨_, _, _, rfl⟩
      · exact ⟨s.fs, s.core, s.floor, rfl⟩
    · exact ⟨s.fs, s.core, s.floor, rfl⟩
  · exact ⟨s.fs, s.core, s.floor, rfl⟩

theorem flushCore_cur (s : St) : (flushCore s).cur = s.cur := by
  obtain ⟨f, c, fl, e⟩ := flushCore_eq s; rw [e]

theorem flushCore_inv {s : St} (h : FInv s) : FInv (flushCore s) := by
  unfold flushCore
  split
  · rename_i g c _ hc
    split
    · split
      · rename_i r hr
        apply raise_inv
        have hw : r.game = c.game := h.core c hc r hr
        constructor
        · exact h.idb
        · intro b hb; simp only [Option.some.injEq] at hb; subst hb
          exact ⟨_, rfl, hw.symm⟩
        · intro g' hg'
          obtain ⟨c', hc', hg⟩ := h.cur g' hg'
          rw [hc] at hc'; cases hc'
          exact ⟨_, rfl, hg⟩
        · intro c' hc'; simp only [Option.some.injEq] at hc'; subst hc'
          exact h.core c hc
        · exact h.auto
        · exact h.slot
        · exact h.toast
        · exact h.pend
      · exact h
    · exact h
  · exact h

theorem persistCall_inv {s : St} (g : Nat) (ok : Bool) (k : After) (h : FInv s)
    (hfs : ∀ b, s.fs = some b → b.game = g) : FInv (persistCall s g ok k) := by
  unfold persistCall
  have key : FInv (if s.cur = some g then flushCore s else s) ∧
      ∀ b, (if s.cur = some g then flushCore s else s).fs = some b → b.game = g := by
    split
    · rename_i hc
      have h1 := flushCore_inv h
      exact ⟨h1, fs_of_cur h1 (by rw [flushCore_cur]; exact hc)⟩
    · exact ⟨h, hfs⟩
  generalize (if s.cur = some g then flushCore s else s) = s at key ⊢
  obtain ⟨h, hfs⟩ := key
  dsimp only
  split
  · exact finish_inv k h
  · rename_i b hb
    have hbg := hfs b hb
    split
    · exact finish_inv k h
    · split
      · refine push_inv ?_ (show POK (.persist g b k) from hbg)
        apply raise_inv
        constructor
        · intro g' b' hb'
          simp only [upd_apply] at hb'
          split at hb'
          · rename_i hgg; cases hb'; rw [hgg]; exact hbg
          · exact h.idb g' b' hb'
        · exact h.fs
        · exact h.cur
        · exact h.core
        · exact h.auto
        · exact h.slot
        · exact h.toast
        · exact h.pend
      · exact push_inv (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl) hbg

theorem autoSnap_inv {s : St} (h : FInv s) : FInv (autoSnap s) := by
  unfold autoSnap
  split
  · rename_i g c _ hc
    have h1 := flushCore_inv h
    obtain ⟨f, co, fl, e⟩ := flushCore_eq s
    rw [e] at h1 ⊢
    constructor
    · exact h1.idb
    · exact h1.fs
    · exact h1.cur
    · exact h1.core
    · intro g' a ha
      simp only [upd_apply] at ha
      split at ha
      · cases ha; exact h.core c hc
      · exact h1.auto g' a ha
    · exact h1.slot
    · exact h1.toast
    · exact h1.pend
  · exact h

theorem launchCall_inv {s : St} (g : Nat) (gb : Bool) (h : FInv s) :
    FInv (launchCall s g gb) := by
  have h' : FInv { s with loading := none } := finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl
  unfold launchCall
  dsimp only
  split
  · exact push_inv (autoSnap_inv h') trivial
  · exact l3_inv g gb h'

theorem offerStart_inv {s : St} (h : FInv s) : FInv (offerStart s) := by
  unfold offerStart
  split
  · rename_i n _
    exact push_inv h (fun a' ha => h.auto n a' ha)
  · exact h

theorem l4_inv {s : St} (g : Nat) (gb : Bool) (v : Option Bytes) (h : FInv s)
    (hv : ∀ b, v = some b → b.game = g) : FInv (l4 s g gb v) := by
  simp only [l4]
  apply offerStart_inv
  constructor
  · exact h.idb
  · intro b hb
    exact ⟨_, rfl, (hv b hb).symm⟩
  · intro g' hg
    simp only [Option.some.injEq] at hg
    exact ⟨_, rfl, hg⟩
  · intro c hc
    simp only [Option.some.injEq] at hc
    subst hc
    intro r hr
    exact hv r hr
  · exact h.auto
  · exact h.slot
  · exact h.toast
  · exact h.pend

theorem applyState_inv {s : St} (sc : Core) (h : FInv s) (hsc : WF sc) :
    FInv (applyState s sc) := by
  unfold applyState
  split
  · rename_i c hc
    split
    · rename_i hg
      constructor
      · exact h.idb
      · intro b hb
        obtain ⟨c', hc', hg'⟩ := h.fs b hb
        rw [hc] at hc'; cases hc'
        exact ⟨_, rfl, by simp; omega⟩
      · intro g' hg2
        obtain ⟨c', hc', hg'⟩ := h.cur g' hg2
        rw [hc] at hc'; cases hc'
        exact ⟨_, rfl, by simp; omega⟩
      · intro c' hc'
        simp only [Option.some.injEq] at hc'
        subst hc'
        intro r hr
        exact hsc r hr
      · exact h.auto
      · exact h.slot
      · exact h.toast
      · exact h.pend
    · exact h
  · exact h

theorem restamp_wf (t : Nat) (sc : Core) (h : WF sc) : WF (restamp t sc) := by
  intro r hr
  simp only [restamp, Option.map_eq_some_iff] at hr
  obtain ⟨r0, h0, rfl⟩ := hr
  exact h r0 h0

theorem mem_eraseIdx_or {α : Type} {l : List α} {i : Nat} {p q : α}
    (hi : l[i]? = some p) (hq : q ∈ l) : q ∈ l.eraseIdx i ∨ q = p := by
  obtain ⟨j, hj⟩ := List.mem_iff_getElem?.mp hq
  by_cases hji : j = i
  · subst hji; rw [hi] at hj; cases hj; exact Or.inr rfl
  · exact Or.inl (List.mem_eraseIdx_iff_getElem?.mpr ⟨j, hji, hj⟩)

theorem resumeP_inv {s : St} (p : Pending) (ok : Bool) (h : FInv s) (hp : POK p) :
    FInv (resumeP s p ok) := by
  cases p with
  | persist g b k => exact finish_inv k (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl)
  | evict g b k t =>
    simp only [resumeP]
    split
    · split
      · exact finish_inv k h
      refine push_inv ?_ (show POK (.persist g b k) from hp)
      apply raise_inv
      constructor
      · intro g' b' hb'
        simp only [upd_apply] at hb'
        split at hb'
        · rename_i hgg; cases hb'; rw [hgg]; exact hp
        · exact h.idb g' b' hb'
      · exact h.fs
      · exact h.cur
      · exact h.core
      · exact h.auto
      · exact h.slot
      · exact h.toast
      · exact h.pend
    · exact finish_inv k (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl)
  | loadPre g gb =>
    simp only [resumeP]
    split
    · rename_i a ha
      exact persistCall_inv a ok _ h (fs_of_cur h ha)
    · exact h
  | loadRestore g gb v => exact l4_inv g gb v h hp
  | offerGet g a =>
    simp only [resumeP]
    split
    · rename_i a'
      split
      · exact push_inv h (hp a' rfl)
      · exact h
    · exact h
  | offerCheck g a v =>
    simp only [resumeP]
    split
    · constructor
      · exact h.idb
      · exact h.fs
      · exact h.cur
      · exact h.core
      · exact h.auto
      · exact h.slot
      · intro g' a' ht
        simp only [Option.some.injEq, Prod.mk.injEq] at ht
        obtain ⟨_, rfl⟩ := ht
        exact hp
      · exact h.pend
    · exact h
  | tapCheck g a v =>
    simp only [resumeP]
    split
    · have h1 := flushCore_inv h
      split
      · exact applyState_inv _ (finv_congr h1 rfl rfl rfl rfl rfl rfl rfl rfl) hp
      · exact h1
    · exact h
  | unloadPre g flush thenDelete =>
    simp only [resumeP]
    split
    · exact h
    · rename_i hne
      have hc : s.cur = some g := by
        simpa using hne
      have hfs := fs_of_cur h hc
      split
      · exact finv_detach (persistCall_inv g ok _ h hfs)
      · have h2 := finv_detach h
        split
        · exact push_inv (p := .delSaves g) h2 trivial
        · exact h2
  | delSaves g =>
    simp only [resumeP, retire]
    refine push_inv (p := .delRest g) ?_ trivial
    constructor
    · intro g' b' hb'
      simp only [upd_apply] at hb'
      split at hb'
      · cases hb'
      · exact h.idb g' b' hb'
    · exact h.fs
    · exact h.cur
    · exact h.core
    · exact h.auto
    · exact h.slot
    · exact h.toast
    · exact h.pend
  | delRest g =>
    simp only [resumeP]
    constructor
    · exact h.idb
    · exact h.fs
    · exact h.cur
    · exact h.core
    · intro g' a ha
      simp only [upd_apply] at ha
      split at ha
      · cases ha
      · exact h.auto g' a ha
    · intro g' c hc
      simp only [upd_apply] at hc
      split at hc
      · cases hc
      · exact h.slot g' c hc
    · exact h.toast
    · exact h.pend
  | resetRest g loaded gb =>
    simp only [resumeP]
    have h1 : FInv { s with slot := upd s.slot g none, auto := upd s.auto g none,
                            deletes := s.deletes ++ [g] } := by
      constructor
      · exact h.idb
      · exact h.fs
      · exact h.cur
      · exact h.core
      · intro g' a ha
        simp only [upd_apply] at ha
        split at ha
        · cases ha
        · exact h.auto g' a ha
      · intro g' c hc
        simp only [upd_apply] at hc
        split at hc
        · cases hc
        · exact h.slot g' c hc
      · exact h.toast
      · exact h.pend
    split
    · exact launchCall_inv g gb h1
    · exact h1
  | slotGet g v =>
    simp only [resumeP]
    split
    · rename_i sc
      exact applyState_inv _ (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl)
        (restamp_wf _ _ (hp sc rfl))
    · exact h
  | importPut g gb =>
    exact launchCall_inv _ _ h
  | pull g b =>
    simp only [resumeP]
    split
    · exact h
    apply raise_inv
    constructor
    · intro g' b' hb'
      simp only [upd_apply] at hb'
      split at hb'
      · rename_i hgg; cases hb'; rw [hgg]; exact hp
      · exact h.idb g' b' hb'
    · exact h.fs
    · exact h.cur
    · exact h.core
    · exact h.auto
    · exact h.slot
    · exact h.toast
    · exact h.pend

theorem step_inv {s : St} (e : Ev) (h : FInv s) : FInv (step s e) := by
  cases e with
  | play =>
    simp only [step]
    split
    · exact h
    · split
      · rename_i c hc
        constructor
        · exact h.idb
        · intro b hb
          obtain ⟨c', hc', hg'⟩ := h.fs b hb
          rw [hc] at hc'; cases hc'
          exact ⟨_, rfl, hg'⟩
        · intro g hg
          obtain ⟨c', hc', hg'⟩ := h.cur g hg
          rw [hc] at hc'; cases hc'
          exact ⟨_, rfl, hg'⟩
        · intro c' hc'
          simp only [Option.some.injEq] at hc'
          subst hc'
          intro r hr
          simp only [Option.some.injEq] at hr
          subst hr
          rfl
        · exact h.auto
        · exact h.slot
        · exact h.toast
        · exact h.pend
      · exact h
  | frame =>
    simp only [step]
    split
    · exact h
    · split
      · rename_i c hc
        split
        · split
          · rename_i r hr
            apply raise_inv
            have hw := h.core c hc r hr
            constructor
            · exact h.idb
            · intro b hb
              simp only [Option.some.injEq] at hb
              subst hb
              exact ⟨_, rfl, hw.symm⟩
            · intro g hg
              obtain ⟨c', hc', hg'⟩ := h.cur g hg
              rw [hc] at hc'; cases hc'
              exact ⟨_, rfl, hg'⟩
            · intro c' hc'
              simp only [Option.some.injEq] at hc'
              subst hc'
              exact h.core c hc
            · exact h.auto
            · exact h.slot
            · exact h.toast
            · exact h.pend
          · exact h
        · exact h
      · exact h
  | pause => exact finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl
  | unpause =>
    simp only [step]
    split
    · exact finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl
    · exact h
  | tick ok =>
    simp only [step]
    split
    · rename_i g hg
      exact persistCall_inv g ok _ h (fs_of_cur h hg)
    · exact h
  | hide => exact autoSnap_inv h
  | launch g gb => exact launchCall_inv g gb h
  | resume i ok =>
    simp only [step]
    split
    · rename_i p hp
      apply resumeP_inv p ok _ (h.pend p (List.mem_of_getElem? hp))
      constructor
      · exact h.idb
      · exact h.fs
      · exact h.cur
      · exact h.core
      · exact h.auto
      · exact h.slot
      · exact h.toast
      · intro q hq
        exact h.pend q (List.mem_of_mem_eraseIdx hq)
    · exact h
  | close =>
    simp only [step]
    split
    · exact push_inv (autoSnap_inv (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl)) trivial
    · exact h
  | delete g =>
    simp only [step]
    split
    · exact push_inv (p := .unloadPre g false true) (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl) trivial
    · exact push_inv (p := .delSaves g) h trivial
  | reset g =>
    simp only [step]
    have h0 : FInv (if decide (s.cur = some g) = true then { s with fs := none, cur := none, loading := none }
                    else s) := by
      split
      · constructor
        · exact h.idb
        · intro b hb; simp at hb
        · intro g' hg'; simp at hg'
        · exact h.core
        · exact h.auto
        · exact h.slot
        · exact h.toast
        · exact h.pend
      · exact h
    generalize (if decide (s.cur = some g) = true then { s with fs := none, cur := none, loading := none }
                else s) = s0 at h0 ⊢
    refine push_inv ?_ trivial
    simp only [retire]
    constructor
    · intro g' b' hb'
      simp only [upd_apply] at hb'
      split at hb'
      · cases hb'
      · exact h0.idb g' b' hb'
    · exact h0.fs
    · exact h0.cur
    · exact h0.core
    · exact h0.auto
    · exact h0.slot
    · exact h0.toast
    · exact h0.pend
  | tapResume =>
    simp only [step]
    split
    · rename_i g a ht
      have ha := h.toast g a ht
      have h1 : FInv { s with toast := none } := by
        constructor
        · exact h.idb
        · exact h.fs
        · exact h.cur
        · exact h.core
        · exact h.auto
        · exact h.slot
        · intro g' a' ht'; simp at ht'
        · exact h.pend
      split
      · exact push_inv h1 ha
      · exact h1
    · exact h
  | slotSave =>
    simp only [step]
    split
    · rename_i g c _ hc
      constructor
      · exact h.idb
      · exact h.fs
      · exact h.cur
      · exact h.core
      · exact h.auto
      · intro g' c' hc'
        simp only [upd_apply] at hc'
        split at hc'
        · cases hc'; exact h.core c hc
        · exact h.slot g' c' hc'
      · exact h.toast
      · exact h.pend
    · exact h
  | slotLoad =>
    simp only [step]
    split
    · rename_i g _
      exact push_inv h (fun c hc => h.slot g c hc)
    · exact h
  | importSave =>
    simp only [step]
    split
    · rename_i g c hg hc
      refine push_inv (p := .importPut g c.gb) ?_ trivial
      apply raise_inv
      simp only [retire]
      constructor
      · intro g' b' hb'
        simp only [upd_apply] at hb'
        split at hb'
        · rename_i hgg; cases hb'; exact hgg.symm
        · exact h.idb g' b' hb'
      · intro b hb; simp at hb
      · intro g' hg'; simp at hg'
      · exact h.core
      · exact h.auto
      · exact h.slot
      · exact h.toast
      · exact h.pend
    · exact h
  | pullStart g =>
    simp only [step]
    split
    · exact h
    · exact push_inv (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl) (show (⟨g, s.clock⟩ : Bytes).game = g from rfl)

theorem reachable_inv {s : St} (h : Reachable s) : FInv s := by
  induction h with
  | init => exact finv_init
  | step e _ ih => exact step_inv e ih

/-- `save:<g>` never receives another game's bytes, under every interleaving
    of timers, page events, taps and awaits. -/
theorem provenance {s : St} (h : Reachable s) : Prov s :=
  (reachable_inv h).idb

/-! ## The Resume guard and the upload queue

Both held at dd7ba741f too, and hold under every interleaving. -/

/-- The Resume guard (74a92a845): every applied Resume passed the check that
    its `saveSig` equals the `save:<g>` read after the tap, with `g` still
    loaded at the moment it applied. -/
def ResumeGuard (s : St) : Prop := ∀ x ∈ s.resumes, x.2.1.saveSig = x.2.2

/-- Every save persistSave got into IndexedDB has had `markUpload` for the
    same game with the same bytes, or that call is still in flight (the
    continuation after the put). -/
def UploadInv (s : St) : Prop :=
  ∀ x ∈ s.writes, x ∈ s.uploads ∨ ∃ k, Pending.persist x.1 x.2 k ∈ s.pend

structure GInv (s : St) : Prop where
  guard  : ResumeGuard s
  upload : UploadInv s

theorem ginv_congr {s s' : St} (h : GInv s) (h1 : s'.resumes = s.resumes)
    (h2 : s'.writes = s.writes) (h3 : s'.uploads = s.uploads) (h4 : ∀ p ∈ s.pend, p ∈ s'.pend) :
    GInv s' := by
  constructor
  · unfold ResumeGuard; rw [h1]; exact h.guard
  · intro x hx
    rw [h2] at hx
    rcases h.upload x hx with hu | ⟨k, hk⟩
    · exact Or.inl (h3 ▸ hu)
    · exact Or.inr ⟨k, h4 _ hk⟩

theorem ginv_push {s : St} (p : Pending) (h : GInv s) : GInv (push s p) :=
  ginv_congr h rfl rfl rfl (fun q hq => by simp [push, hq])

theorem ginv_write {s : St} (g : Nat) (b : Bytes) (k : After) (h : GInv s) (s' : St)
    (h1 : s'.resumes = s.resumes) (h2 : s'.writes = s.writes ++ [(g, b)])
    (h3 : s'.uploads = s.uploads) (h4 : s'.pend = s.pend ++ [.persist g b k]) : GInv s' := by
  constructor
  · unfold ResumeGuard; rw [h1]; exact h.guard
  · intro x hx
    rw [h2, List.mem_append, List.mem_singleton] at hx
    rcases hx with hx | rfl
    · rcases h.upload x hx with hu | ⟨k', hk⟩
      · exact Or.inl (h3 ▸ hu)
      · exact Or.inr ⟨k', by rw [h4]; exact List.mem_append_left _ hk⟩
    · exact Or.inr ⟨k, by rw [h4]; simp⟩

theorem ginv_l3 {s : St} (g : Nat) (gb : Bool) (h : GInv s) : GInv (l3 s g gb) := by
  unfold l3
  exact ginv_push _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))

theorem ginv_finish {s : St} (k : After) (h : GInv s) : GInv (finish s k) := by
  cases k with
  | none => exact h
  | load g gb => exact ginv_l3 g gb h

theorem ginv_flushCore {s : St} (h : GInv s) : GInv (flushCore s) := by
  obtain ⟨f, c, fl, e⟩ := flushCore_eq s
  rw [e]; exact ginv_congr h rfl rfl rfl (fun _ hq => hq)

theorem ginv_persistCall {s : St} (g : Nat) (ok : Bool) (k : After) (h : GInv s) :
    GInv (persistCall s g ok k) := by
  unfold persistCall
  have h' : GInv (if s.cur = some g then flushCore s else s) := by
    split
    · exact ginv_flushCore h
    · exact h
  generalize (if s.cur = some g then flushCore s else s) = s at h' ⊢
  dsimp only
  split
  · exact ginv_finish k h'
  · rename_i b _
    split
    · exact ginv_finish k h'
    · split
      · exact ginv_write g b k h' _ rfl rfl rfl rfl
      · exact ginv_push _ (ginv_congr h' rfl rfl rfl (fun _ hq => hq))

theorem ginv_autoSnap {s : St} (h : GInv s) : GInv (autoSnap s) := by
  unfold autoSnap
  split
  · have h1 := ginv_flushCore h
    exact ginv_congr h1 rfl rfl rfl (fun _ hq => hq)
  · exact h

theorem ginv_launchCall {s : St} (g : Nat) (gb : Bool) (h : GInv s) :
    GInv (launchCall s g gb) := by
  have h' : GInv { s with loading := none } := ginv_congr h rfl rfl rfl (fun _ hq => hq)
  unfold launchCall
  dsimp only
  split
  · exact ginv_push _ (ginv_autoSnap h')
  · exact ginv_l3 g gb h'

theorem ginv_offerStart {s : St} (h : GInv s) : GInv (offerStart s) := by
  unfold offerStart
  split
  · exact ginv_push _ h
  · exact h

theorem ginv_l4 {s : St} (g : Nat) (gb : Bool) (v : Option Bytes) (h : GInv s) :
    GInv (l4 s g gb v) := by
  unfold l4
  exact ginv_offerStart (ginv_congr h rfl rfl rfl (fun _ hq => hq))

theorem ginv_applyState {s : St} (sc : Core) (h : GInv s) : GInv (applyState s sc) := by
  unfold applyState
  split
  · split
    · exact ginv_congr h rfl rfl rfl (fun _ hq => hq)
    · exact h
  · exact h

theorem ginv_resumeP {s : St} (p : Pending) (ok : Bool) (s0 : St) (i : Nat)
    (hs : s = { s0 with pend := s0.pend.eraseIdx i }) (hi : s0.pend[i]? = some p)
    (h0 : GInv s0) : GInv (resumeP s p ok) := by
  -- first: s itself, minus the resumed persist
  have hpend : ∀ q ∈ s0.pend, q ∈ s.pend ∨ q = p := by
    intro q hq; rw [hs]; exact mem_eraseIdx_or hi hq
  have hbase : ∀ x ∈ s.writes, x ∈ s.uploads ∨ (∃ k, Pending.persist x.1 x.2 k ∈ s.pend) ∨
      (∃ k, p = .persist x.1 x.2 k) := by
    intro x hx
    rw [hs] at hx
    rcases h0.upload x hx with hu | ⟨k, hk⟩
    · exact Or.inl (by rw [hs]; exact hu)
    · rcases hpend _ hk with hk' | hk'
      · exact Or.inr (Or.inl ⟨k, hk'⟩)
      · exact Or.inr (Or.inr ⟨k, hk'.symm⟩)
  have hguard : ResumeGuard s := by rw [hs]; exact h0.guard
  cases p with
  | persist g b k =>
    apply ginv_finish
    constructor
    · exact hguard
    · intro x hx
      rcases hbase x hx with hu | hk | ⟨k', hk'⟩
      · exact Or.inl (List.mem_append_left _ hu)
      · exact Or.inr hk
      · cases hk'
        exact Or.inl (by simp)
  | tapCheck g a v =>
    have h : GInv s := by
      constructor
      · exact hguard
      · intro x hx
        rcases hbase x hx with hu | hk | ⟨k', hk'⟩
        · exact Or.inl hu
        · exact Or.inr hk
        · cases hk'
    simp only [resumeP]
    split
    · rename_i hc
      have h1 := ginv_flushCore h
      split
      · apply ginv_applyState
        constructor
        · intro x hx
          rw [List.mem_append, List.mem_singleton] at hx
          rcases hx with hx | rfl
          · exact h1.guard x hx
          · exact hc.1
        · exact h1.upload
      · exact h1
    · exact h
  | unloadPre g flush thenDelete =>
    have h : GInv s := by
      constructor
      · exact hguard
      · intro x hx
        rcases hbase x hx with hu | hk | ⟨k', hk'⟩
        · exact Or.inl hu
        · exact Or.inr hk
        · cases hk'
    simp only [resumeP]
    split
    · exact h
    · split
      · exact ginv_congr (s := persistCall s g ok .none) (ginv_persistCall g ok .none h)
          rfl rfl rfl (fun _ hq => hq)
      · split
        · exact ginv_push _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
        · exact ginv_congr h rfl rfl rfl (fun _ hq => hq)
  | _ =>
    have h : GInv s := by
      constructor
      · exact hguard
      · intro x hx
        rcases hbase x hx with hu | hk | ⟨k', hk'⟩
        · exact Or.inl hu
        · exact Or.inr hk
        · cases hk'
    first
    | (simp only [resumeP]; done)
    | skip
    simp only [resumeP]
    repeat' first
      | exact ginv_finish _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_persistCall _ ok _ h
      | exact ginv_persistCall _ ok _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_l4 _ _ _ h
      | exact ginv_push _ h
      | exact h
      | exact ginv_launchCall _ _ h
      | exact ginv_applyState _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_write _ _ _ h _ rfl rfl rfl rfl
      | exact ginv_push _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_congr h rfl rfl rfl (fun _ hq => hq)
      | exact ginv_l3 _ _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_launchCall _ _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_congr (ginv_persistCall _ ok _ (ginv_congr h rfl rfl rfl (fun _ hq => hq)))
          rfl rfl rfl (fun _ hq => hq)
      | split

theorem ginv_init : GInv init := by
  constructor
  · intro x hx; simp [init] at hx
  · intro x hx; simp [init] at hx

theorem ginv_step {s : St} (e : Ev) (h : GInv s) : GInv (step s e) := by
  cases e with
  | resume i ok =>
    simp only [step]
    split
    · rename_i p hp
      exact ginv_resumeP p ok s i rfl hp h
    · exact h
  | tick ok =>
    simp only [step]
    split
    · exact ginv_persistCall _ ok _ h
    · exact h
  | launch g gb => exact ginv_launchCall g gb h
  | hide => exact ginv_autoSnap h
  | importSave =>
    simp only [step]
    split
    · exact ginv_push _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
    · exact h
  | _ =>
    simp only [step]
    repeat' first
      | exact h
      | exact ginv_push _ h
      | exact ginv_push _ (ginv_autoSnap h)
      | exact ginv_push _ (ginv_autoSnap (ginv_congr h rfl rfl rfl (fun _ hq => hq)))
      | exact ginv_push _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_congr h rfl rfl rfl (fun _ hq => hq)
      | split

theorem reachable_ginv {s : St} (h : Reachable s) : GInv s := by
  induction h with
  | init => exact ginv_init
  | step e _ ih => exact ginv_step e ih

/-- A Resume is applied only when its `saveSig` matched the
    stored `save:<g>` read by a check issued after the tap. -/
theorem resume_only_on_sig_match {s : St} (h : Reachable s) : ResumeGuard s :=
  (reachable_ginv h).guard

/-- Every save `persistSave` wrote to `save:<g>` reaches
    `markUpload("save:"+g)` with the same bytes (or is about to: the
    continuation after the put is still pending). -/
theorem persist_marks_upload {s : St} (h : Reachable s) : UploadInv s :=
  (reachable_ginv h).upload

/-! ## The dd7ba741f counterexamples, replayed against the code

Game 0 and game 1 are two library games; `false`/`true` after `launch` is
GBA/GB. Pending indices are positions in `pend` (new continuations are
appended), so an index a trace names may now point elsewhere or nowhere: each
theorem states what the same events do now. `provenance` covers every one of
them; these pin the particular outcome. -/

open Ev in
/-- Play A (0) and save in game; go home; tap B (1), which has no save on
    this device. At dd7ba741f `rom.sav` still held A's save, B's core booted
    on it, and the next 5 s flush wrote it to `save:B` (and queued it for
    Drive). Now the boot unlinks `rom.sav`: B starts with no battery and
    `save:B` stays empty. -/
def trSwitch : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,     -- A boots (no save yet)
   play, frame, tick true, resume 0 true,             -- A saves; flushed to save:A
   pause,                                             -- home screen
   launch 1 false, resume 0 true,                     -- tap B: outgoing persist; dbGet save:B
   resume 0 true,                                     -- the boot: no save, no rom.sav
   tick true, resume 1 true]                          -- the 5 s flush

theorem regress_switch_writes_other_games_save :
    let s := run init trSwitch
    Reachable s ∧ s.idb 1 = none ∧ s.uploads = [(0, ⟨0, 1⟩)] ∧
      s.core = some ⟨1, false, none, false⟩ ∧ s.fs = none ∧ Prov s :=
  ⟨run_reachable _ _ .init, by decide, by decide, by decide, by decide,
   provenance (run_reachable _ _ .init)⟩

open Ev in
/-- B (1) has its own save (from an earlier Drive pull). At dd7ba741f the
    names switched to B before restoreSave's dbGet resolved, and the page
    hidden in that window (pagehide: persistSave with the CURRENT names)
    wrote A's `rom.sav` to `save:B`. A now stays named until the boot, and
    the flush in the window is A's, to `save:A`. -/
def trSwitchWindow : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,     -- A boots
   pullStart 1, resume 0 true,                        -- B's save arrives from Drive
   play, frame, tick true, resume 0 true,             -- A saves; flushed
   pause,
   launch 1 false, resume 0 true,                     -- tap B: dbGet save:B in flight
   tick true]                                         -- pagehide / the 5 s tick lands here

theorem regress_switch_window_overwrites_save :
    (run init (trSwitchWindow.take 12)).idb 1 = some ⟨1, 1⟩ ∧
    let s := run init trSwitchWindow
    Reachable s ∧ s.cur = some 0 ∧ s.idb 1 = some ⟨1, 1⟩ ∧ s.idb 0 = some ⟨0, 2⟩ ∧ Prov s :=
  ⟨by decide, run_reachable _ _ .init, by decide, by decide, by decide,
   provenance (run_reachable _ _ .init)⟩

open Ev in
/-- A (0) is a GB game whose cart RAM is dirty when it is left (written after
    the frame's `handle_saves`, or a state loaded while paused). B (1) has a
    save. At dd7ba741f restoreSave wrote B's save to `rom.sav`,
    initFromEmscripten then `mbc_save`d the outgoing GB core over it, B booted
    on A's RAM, and the next flush replaced `save:B` for good. The outgoing
    core is no longer flushed at init; the switch's own persist of A flushes
    it instead (`flushSoloSave`), into A's file, while A is still named: A's
    RAM is A's save, and B boots on its own. -/
def trGbInitFlush : List Ev :=
  [launch 0 true, resume 0 true, resume 0 true,      -- A (GB) boots
   pullStart 1, resume 0 true,                        -- B's save arrives from Drive
   play, frame, tick true, resume 0 true,             -- A saves; flushed
   play, pause,                                       -- A writes cart RAM; home before the next flush
   launch 1 false,                                    -- tap B: A's snapshot (flushes)
   resume 0 true, resume 0 true,                      -- A's persist: its RAM to save:A; dbGet save:B
   resume 0 true,                                     -- the boot
   tick true]

theorem regress_gb_init_flush_replaces_save :
    let s := run init trGbInitFlush
    Reachable s ∧ s.idb 1 = some ⟨1, 1⟩ ∧ s.idb 0 = some ⟨0, 3⟩ ∧ s.fs = some ⟨1, 1⟩ ∧
      s.core = some ⟨1, false, some ⟨1, 1⟩, false⟩ ∧ Prov s ∧ Durable s 0 ∧ Durable s 1 := by
  refine ⟨run_reachable _ _ .init, by decide, by decide, by decide, by decide,
    provenance (run_reachable _ _ .init), ?_, ?_⟩ <;> simp only [Durable] <;> decide

open Ev in
/-- Reset save data for the loaded game, with an in-game save from the last
    few seconds not yet flushed. At dd7ba741f resetGameAction deleted
    `save:<g>` first and detached the game only after all its deletes; the 5 s
    tick in between wrote the FS bytes back, and the reboot restored them.
    The game is now detached before the first delete: the tick finds no game
    named, the reboot finds neither a save nor an FS file, and the game starts
    fresh. -/
def trResetUndone : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,
   play, frame, tick true, resume 0 true,             -- save v1 flushed
   play, frame,                                       -- in-game save v2, in rom.sav only
   reset 0,                                           -- detached; save:0 deleted (clock 3)
   tick true, resume 1 true,                          -- the 5 s tick mid-deletes: no name
   resume 0 true,                                     -- rest of the deletes; the reboot
   resume 0 true]                                     -- the boot finds nothing

theorem regress_reset_undone_by_flush :
    let s := run init trResetUndone
    Reachable s ∧ s.idb 0 = none ∧ s.wiped 0 = some 3 ∧ s.cur = some 0 ∧
      s.core = some ⟨0, false, none, false⟩ ∧ 0 ∈ s.deletes ∧ NoResurrect s := by
  have hw : (run init trResetUndone).wiped = upd (fun _ => none) 0 (some 3) := rfl
  have hi : (run init trResetUndone).idb 0 = none := by decide
  refine ⟨run_reachable _ _ .init, hi, by rw [hw]; rfl, by decide, by decide, by decide, ?_⟩
  intro g b t hb ht
  rw [hw, upd_apply] at ht
  split at ht
  · subst_vars; rw [hi] at hb; cases hb
  · cases ht

open Ev in
/-- Close A, relaunch it: Resume is offered (the snapshot matches save:A).
    Within the toast's 8 s the player saves in game (rom.sav only; the 5 s
    flush has not run) and then taps Resume. At dd7ba741f the check compared
    with `save:A` alone, which still matched, so the older RAM was applied,
    marked dirty, and flushed over the newer save. The tap now also checks the
    live battery, `rom.sav`, and refuses: the newer save stays. -/
def trResumeOverUnflushed : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,
   play, frame, tick true, resume 0 true,             -- save v1 persisted
   close, resume 0 true,                              -- Close: snapshot (saveSig v1), persist, unlink
   launch 0 false, resume 0 true, resume 0 true, resume 0 true, -- relaunch; offer checks; toast
   play, frame,                                       -- in-game save v2 (rom.sav only)
   tapResume, resume 0 true,                          -- the tap's check: rom.sav is v2: refused
   frame]

theorem regress_resume_over_unflushed_save :
    let s := run init trResumeOverUnflushed
    Reachable s ∧ s.floor 0 = 2 ∧ s.idb 0 = some ⟨0, 1⟩ ∧ s.fs = some ⟨0, 2⟩ ∧
      s.resumes = [] ∧ Durable s 0 := by
  refine ⟨run_reachable _ _ .init, by decide, by decide, by decide, by decide, ?_⟩
  simp only [Durable]; decide

open Ev in
/-- Two persists of the same game race a full disk: the first put fails with
    QuotaExceededError and dbPutRoomy awaits evictOldestRom; a newer save is
    persisted meanwhile; the eviction completes. At dd7ba741f the OLD bytes
    were then put again, over the newer ones (and uploaded); the retry now
    sees the later persist's number and gives way. -/
def trQuotaPre : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,
   play, frame, tick false,                           -- v1: put rejected (quota) -> evict
   play, frame, tick true, resume 1 true]             -- v2 persisted
open Ev in
def trQuotaPost : List Ev := [resume 0 true, resume 0 true] -- eviction done: gives way

theorem regress_quota_retry_writes_older_save :
    (run init trQuotaPre).idb 0 = some ⟨0, 2⟩ ∧
    let s := run init (trQuotaPre ++ trQuotaPost)
    Reachable s ∧ s.idb 0 = some ⟨0, 2⟩ ∧ s.uploads = [(0, ⟨0, 2⟩)] ∧ s.pend = [] :=
  ⟨by decide, run_reachable _ _ .init, by decide, by decide, by decide⟩

open Ev in
/-- App start on a second device: a Drive pull is downloading game 0's newer
    save (it checked the guard before `await driveDownload`) when the player
    taps game 0. At dd7ba741f the game booted on the stale local save, the
    download landed in `save:0`, and the first 5 s flush (lastSaveSig was null
    at page start) wrote the stale bytes over it and queued them for Drive.
    Now the pull re-checks after the download and leaves the loaded game's
    save alone (Drive keeps the newer copy for the next pull), and the boot
    remembers the signature it installed, so the first flush writes nothing. -/
def trPullUnderLoaded : List Ev :=
  [pullStart 0, resume 0 true,                        -- an earlier sync left v1 here
   pullStart 0,                                       -- boot pull: v2 downloading
   launch 0 false, resume 1 true, resume 1 true,      -- tap game 0: boots on v1
   resume 0 true,                                     -- download lands: game 0 is loaded
   tick true, resume 0 true]                          -- first flush: nothing to write

theorem regress_pull_overwritten_by_stale_flush :
    let s := run init trPullUnderLoaded
    Reachable s ∧ s.idb 0 = some ⟨0, 1⟩ ∧ s.uploads = [] ∧ s.lastSig = some (0, ⟨0, 1⟩) ∧
      Durable s 0 := by
  refine ⟨run_reachable _ _ .init, by decide, by decide, by decide, ?_⟩
  simp only [Durable]; decide

/-! ## Unflushed RAM across a switch or a close

A paused core runs no frames, so RAM a state load gave it is dirty in the core
and not in `rom.sav`. The outgoing persist of a switch and the flush of a
close run while the game is still named, and flush the core first: that RAM
is what they store, under its own game. -/

/-- A switch's outgoing persist (loadRom 8031) stores the core's unflushed RAM
    under the outgoing game. -/
theorem switch_persists_dirty_ram {s : St} {i g a : Nat} {gb : Bool} {c : Core} {r : Bytes}
    (hi : s.pend[i]? = some (.loadPre g gb)) (hc : s.cur = some a) (hcore : s.core = some c)
    (hd : c.dirty = true) (hr : c.ram = some r) (hls : s.lastSig ≠ some (a, r)) :
    (step s (.resume i true)).idb a = some r ∧ (a, r) ∈ (step s (.resume i true)).writes := by
  simp [step, hi, resumeP, hc, persistCall, flushCore, hcore, hd, hr, hls, raise, push, upd]

/-- A close (unloadGame 9844) stores the core's unflushed RAM under its game. -/
theorem close_persists_dirty_ram {s : St} {i a : Nat} {td : Bool} {c : Core} {r : Bytes}
    (hi : s.pend[i]? = some (.unloadPre a true td)) (hc : s.cur = some a)
    (hcore : s.core = some c) (hd : c.dirty = true) (hr : c.ram = some r)
    (hls : s.lastSig ≠ some (a, r)) :
    (step s (.resume i true)).idb a = some r ∧ (a, r) ∈ (step s (.resume i true)).writes ∧
      (step s (.resume i true)).cur = none := by
  simp [step, hi, resumeP, hc, persistCall, flushCore, hcore, hd, hr, hls, raise, push, upd]

open Ev in
/-- Play A, save (persisted), save again, pause before the frame flushes it,
    close. The close's snapshot and flush write that RAM to `rom.sav` while A
    is still named, and the close stores it: `save:0` is the newest save. -/
def trCloseDirty : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,
   play, frame, tick true, resume 0 true,             -- v1 persisted
   play, pause,                                       -- v2 in the core only
   close, resume 0 true]                              -- the close

theorem regress_close_drops_dirty_ram :
    let s := run init trCloseDirty
    Reachable s ∧ s.idb 0 = some ⟨0, 2⟩ ∧ s.cur = none ∧ Prov s ∧ Durable s 0 := by
  refine ⟨run_reachable _ _ .init, by decide, by decide,
    provenance (run_reachable _ _ .init), ?_⟩
  simp only [Durable]; decide

/-! ## Import

`applyImportedSave` detaches the game (as Reset) before its put, and the reboot
installs the import. Before (and at dd7ba741f), the reboot first persisted
"the outgoing game": with the flush, the core's own RAM went over the
imported file and into `save:<g>`; and without it, the outgoing snapshot was
taken under the imported save's signature with the replaced battery in its
state, so Resume offered, and applied, the save just replaced. -/

open Ev in
def trImport : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,
   play, frame, tick true, resume 0 true,             -- v1 persisted
   hide,                                              -- a snapshot (v1)
   play, pause,                                       -- v2 in the core only
   importSave,                                        -- the import (v3): detached, put
   resume 0 true, resume 0 true,                      -- the reboot: dbGet, boot on v3
   resume 0 true, resume 0 true]                      -- the offer: v1's snapshot is not v3

theorem regress_import_survives_reboot :
    let s := run init trImport
    Reachable s ∧ s.idb 0 = some ⟨0, 3⟩ ∧ s.fs = some ⟨0, 3⟩ ∧ s.cur = some 0 ∧
      s.toast = none ∧ s.pend = [] ∧ Prov s :=
  ⟨run_reachable _ _ .init, by decide, by decide, by decide, by decide, by decide,
   provenance (run_reachable _ _ .init)⟩

/-! ## Reset, Delete and Import against a waiting quota retry

A persist waiting on a quota eviction re-puts its bytes unless a later number
has been taken for the save (`persistSeq`). A delete of the save (Reset,
Delete) and an import take one. -/

open Ev in
/-- A persist of game 0's save is waiting on a quota eviction when the player
    resets game 0. The Reset took no number before, so the retry found itself
    the latest and put the wiped save back (`NoResurrect` failed); now it gives
    way. -/
def trQuotaReset : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true, play, frame, tick false,  -- v1: quota -> evict
   reset 0,                                           -- save:0 deleted, a number taken
   resume 0 true]                                     -- eviction done: gives way

theorem regress_quota_retry_resurrects_reset_save :
    let s := run init trQuotaReset
    Reachable s ∧ s.idb 0 = none ∧ s.wiped 0 = some 2 ∧ NoResurrect s := by
  have hw : (run init trQuotaReset).wiped = upd (fun _ => none) 0 (some 2) := rfl
  have hi : (run init trQuotaReset).idb 0 = none := by decide
  refine ⟨run_reachable _ _ .init, hi, by rw [hw]; rfl, ?_⟩
  intro g b t hb ht
  rw [hw, upd_apply] at ht
  split at ht
  · subst_vars; rw [hi] at hb; cases hb
  · cases ht

open Ev in
/-- The same with Delete (the game loaded: unloadGame, then the deletes). -/
theorem regress_quota_retry_resurrects_deleted_save :
    let s := run init [launch 0 false, resume 0 true, resume 0 true, play, frame, tick false,
                       delete 0, resume 1 true, resume 1 true, resume 0 true]
    Reachable s ∧ s.idb 0 = none ∧ s.wiped 0 = some 2 :=
  ⟨run_reachable _ _ .init, by decide, by decide⟩

open Ev in
/-- ...and with an import: the import stands. -/
theorem regress_quota_retry_over_import :
    let s := run init [launch 0 false, resume 0 true, resume 0 true, play, frame, tick false,
                       importSave, resume 0 true]
    Reachable s ∧ s.idb 0 = some ⟨0, 2⟩ :=
  ⟨run_reachable _ _ .init, by decide⟩

/-! ## What the code still does not keep: `NoResurrect` against a Drive pull

The pull's per-save write issues its put after an await and is not told that
the user has since reset (or deleted) that save. It is the Drive code's, and
reported, not fixed here. -/

open Ev in
/-- A Drive pull is downloading game 1's save when the player resets game 1
    (not loaded, so nothing to detach); the download lands and writes the
    old save back. In the JS this is the pull's per-save write (3050-3053),
    which re-checks only that the game is not loaded or loading; the Drive
    deletes that Reset queued then remove Drive's copy, and the next sync's
    reconcile uploads the resurrected local one. -/
theorem open_pull_resurrects_reset_save :
    let s := run init [pullStart 1, reset 1, resume 0 true, resume 0 true]
    Reachable s ∧ s.idb 1 = some ⟨1, 1⟩ ∧ s.wiped 1 = some 2 ∧ ¬ NoResurrect s := by
  refine ⟨run_reachable _ _ .init, by decide, by decide, fun h => ?_⟩
  have := h 1 ⟨1, 1⟩ 2 (by decide) (by decide)
  exact absurd this (by decide)

end WebState.SavePersistence
