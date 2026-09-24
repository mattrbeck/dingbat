/-
# Battery-save and save-state persistence (web/index.js @ dd7ba741f)

What a game's battery save goes through on its way from the wasm core to the
IndexedDB key `save:<game>` (and from there to Drive's upload queue), and back.

* The core keeps the cart's battery RAM in memory and marks it dirty when the
  game writes it (`ram_dirty`, gb.nim; `storage.dirty`, gba storage.nim). Once
  per emulated frame the dirty RAM is written to the emscripten MEMFS file
  next to the ROM (`handle_saves`: gb.nim 3494 `mbc_save`, gba.nim 1388
  `write_save`). Every solo ROM is written to the FS as `rom.<ext>`
  (`launchRom` 4494, `handleRomFile` 8131, `handleZipFile` 8117), so there is
  ONE battery file, `rom.sav`, shared by every game.
* `persistSave(romName, originalName)` (5245) reads that file synchronously,
  skips if its signature equals `lastSaveSig` for the same name, else
  `await dbPutRoomy("save:" + originalName, ...)` (4260; the put is issued in
  the same segment, a QuotaExceededError evicts a ROM and re-issues the put
  after an await), then remembers the signature and calls
  `markUpload("save:" + originalName)` (2653). Each persist that reaches the
  put takes the next number in `persistSeq` (5261-5271), and a re-issue after
  an eviction gives way when a later persist of the same save has taken one
  (dbPutRoomy 4271; as of the commit "web: a quota retry gives way to a newer
  save"; at dd7ba741f it put its older bytes back over the newer ones).
  Callers: the 5 s `setInterval` (11195), `beforeunload` (11203) and `pagehide`
  (11220) with the *current* names; `loadRom` (7890) for the outgoing game;
  `unloadGame` (9646) with names captured before its awaits.
* `loadRom` (7881): outgoing game: `await persistAutoState()`,
  `await storeLastFrame()`, `await persistSave(...)`; then the names switch,
  `paused = false`, `await restoreSave(...)` (5269: `dbGet`, then writes the
  FS file only if the game has a stored save), then
  `initFromEmscripten` (dingbat_wasm.nim 1699), which first `mbc_save`s the
  OUTGOING GB core (1706) and then builds the new core, which reads `rom.sav`
  if it exists (gba.nim 1243 `new_storage`, gb `mbc_load`). Then
  `offerAutoResume` (5669).
* Resume snapshot: `persistAutoState` (5643) stores `stateauto:<game>` with
  the FS `.sav` signature at capture (`saveSig`); `offerAutoResume` and the
  toast's tap re-check it against `save:<game>` (`autoStateMatchesSave`
  5655) before `applyStateBytes`, which marks the cart RAM dirty (gb
  savestate.nim 755, gba savestate.nim 646).
* Slots: `saveToSlot` (5565), `loadFromSlot` (5605). Import:
  `applyImportedSave` (5302). Delete: `deleteGameAction` (1920) ->
  `unloadGame({flushSave:false})` (9636) -> `deleteGameEverywhere` (3149).
  Reset: `resetGameAction` (1857) detaches a loaded game first
  (`detachLoadedGame` 1578: unlink the FS .sav, null the names), then
  `resetGameSaves` (3146), then reboots it with `loadRom`; the Saves panel's
  `resetCurrentSaveFile` (1559) does the same (line numbers and this order as
  of the commit "web: Reset detaches the game before deleting its save"; at
  dd7ba741f the detach came after the deletes). Drive pull: the `isRomLoaded` guard (3005)
  before `await driveDownload` and `writeSyncBytes` (2447) after it.

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

`fx = true` selects the repaired machine used in `fixed_provenance`; every
`if fx` names the JS change it stands for.
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
  gb    : Bool          -- a GB/GBC core (`initFromEmscripten` flushes it on the way out)
  ram   : Option Bytes  -- cart battery RAM; none = never written
  dirty : Bool          -- gb `cart.ram_dirty` / gba `storage.dirty`
deriving DecidableEq, Repr

/-- A `stateauto:<game>` record (5646): the captured core and `saveSig`. -/
structure Snap where
  core    : Core
  saveSig : Option Bytes   -- sigOfSave(FS .sav at capture); none = no .sav
deriving DecidableEq, Repr

/-- What the awaiting caller of a `persistSave` does when it returns. -/
inductive After where
  | none                      -- the setInterval / pagehide / beforeunload call
  | load (g : Nat) (gb : Bool) -- loadRom 7890: the rest of loadRom
  | unload                    -- unloadGame 9646: unlink the .sav, pause
deriving DecidableEq, Repr

inductive Pending where
  /-- persistSave 5252: `dbPutRoomy` put issued and accepted; awaiting it. -/
  | persist (g : Nat) (b : Bytes) (k : After)
  /-- dbPutRoomy 4280: the put failed with QuotaExceededError; awaiting
      `evictOldestRom`, after which the same bytes are put again, unless a
      later persist has taken a number past `t` (4271). -/
  | evict (g : Nat) (b : Bytes) (k : After) (t : Nat)
  /-- loadRom 7889-7890: awaiting persistAutoState + storeLastFrame. -/
  | loadPre (g : Nat) (gb : Bool)
  /-- loadRom 7915 / restoreSave 5270: awaiting `dbGet("save:"+g)` (= v). -/
  | loadRestore (g : Nat) (gb : Bool) (v : Option Bytes)
  /-- offerAutoResume 5673: awaiting `dbGet(stateauto)` (= a). -/
  | offerGet (g : Nat) (a : Option Snap)
  /-- offerAutoResume 5677 / autoStateMatchesSave 5657: awaiting `dbGet(save)`. -/
  | offerCheck (g : Nat) (a : Snap) (v : Option Bytes)
  /-- the Resume toast's handler 5682: awaiting `dbGet(save)`. -/
  | tapCheck (g : Nat) (a : Snap) (v : Option Bytes)
  /-- unloadGame 9641-9642: awaiting persistAutoState + storeLastFrame. -/
  | unloadPre (g : Nat) (flush : Bool) (thenDelete : Bool)
  /-- deleteGameEverywhere 3150: awaiting the rom/art/frame deletes. -/
  | delSaves (g : Nat)
  /-- ... save:g deleted; awaiting the slot + session deletes. -/
  | delRest (g : Nat)
  /-- resetGameAction 1861: save:g deleted; awaiting the other deletes. `loaded`:
      the game was loaded and has been detached; `gb`: its core's kind. -/
  | resetRest (g : Nat) (loaded : Bool) (gb : Bool)
  /-- loadFromSlot 5609: awaiting `dbGet(state:g)` (= v). -/
  | slotGet (g : Nat) (v : Option Core)
  /-- applyImportedSave 5317: awaiting `dbPut(save:g)`. -/
  | importPut (g : Nat)
  /-- Drive pull 3005-3008: passed `isRomLoaded`, awaiting `driveDownload`. -/
  | pull (g : Nat) (b : Bytes)
deriving DecidableEq, Repr

structure St where
  clock   : Nat
  idb     : Nat → Option Bytes   -- IndexedDB "save:<g>"
  auto    : Nat → Option Snap    -- IndexedDB "stateauto:<g>"
  slot    : Nat → Option Core    -- IndexedDB "state:<g>"
  fs      : Option Bytes         -- MEMFS "rom.sav" (every solo ROM is rom.<ext>)
  core    : Option Core          -- stateGb / stateGba
  paused  : Bool                 -- paused (7767)
  cur     : Option Nat           -- currentRomName && currentOriginalName (7765)
  lastSig : Option (Nat × Bytes) -- lastSaveSigKey / lastSaveSig (5237)
  seq     : Nat → Nat            -- persistSeq (5261): the last number a persist of save:g took
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
    pend := [], toast := none, writes := [], uploads := [], resumes := [],
    deletes := [], wiped := fun _ => none, floor := fun _ => 0 }

inductive Ev where
  | play                    -- the running game writes its cart battery RAM
  | frame                   -- handle_saves: dirty RAM -> rom.sav (once per frame)
  | pause                   -- showMainMenu (home) / pause button
  | unpause                 -- resumeGame (9373): needs a loaded game
  | tick (ok : Bool)        -- setInterval 11195 / pagehide 11220 / beforeunload 11203: persistSave(current names); ok = the put is accepted
  | hide                    -- visibilitychange 11213 / pagehide: persistAutoState()
  | launch (g : Nat) (gb : Bool) -- loadRom("rom.<ext>", g): tile tap 5133 (launchRom 4484), file drop, restart 8271
  | resume (i : Nat) (ok : Bool) -- the i-th pending continuation runs
  | close                   -- "Close" on the paused card: unloadGame() (9672)
  | delete (g : Nat)        -- deleteGameAction(g) (1920)
  | reset (g : Nat)         -- resetGameAction(g) (1854) / resetCurrentSaveFile (1559)
  | tapResume               -- tap "Resume" on the toast
  | slotSave                -- saveToSlot(0)
  | slotLoad                -- loadFromSlot(0)
  | importSave              -- applyImportedSave, after the confirms (5314)
  | pullStart (g : Nat)     -- Drive pull reaches save:g (3005)
deriving DecidableEq, Repr

def push (s : St) (p : Pending) : St := { s with pend := s.pend ++ [p] }

/-- ghost: g's save at version b.ver has been written somewhere durable-ish. -/
def raise (s : St) (b : Bytes) : St :=
  { s with floor := upd s.floor b.game (max (s.floor b.game) b.ver) }

/-- loadRom 7892-7915 after the outgoing persist: names switch, `paused = false`,
    `restoreSave` issues its dbGet.
    fx: fetch the incoming save BEFORE switching anything (the switch moves to
    the synchronous segment that runs initFromEmscripten, `l4`). -/
def l3 (fx : Bool) (s : St) (g : Nat) (gb : Bool) : St :=
  if fx then push s (.loadRestore g gb (s.idb g))
  else push { s with cur := some g, paused := false } (.loadRestore g gb (s.idb g))

def finish (fx : Bool) (s : St) : After → St
  | .none => s
  | .load g gb => l3 fx s g gb
  | .unload => { s with fs := none, paused := true }   -- unloadGame 9648-9651

/-- persistSave 5245-5266, its synchronous first segment. -/
def persistCall (fx : Bool) (s : St) (g : Nat) (ok : Bool) (k : After) : St :=
  match s.fs with
  | none => finish fx s k                                  -- 5248 no FS file
  | some b =>
    if s.lastSig = some (g, b) then finish fx s k           -- 5269 unchanged
    else
      let t := s.seq g + 1                                  -- 5270-5271 persistSeq
      let s := { s with seq := upd s.seq g t }
      if ok then                                            -- 5272-5273 put issued, accepted
        push (raise { s with idb := upd s.idb g (some b), writes := s.writes ++ [(g, b)] } b)
          (.persist g b k)
      else push s (.evict g b k t)                          -- 4280 quota: evict, retry

/-- persistAutoState 5643-5652 (the dbPut's effect; nobody awaits its tail). -/
def autoSnap (s : St) : St :=
  match s.cur, s.core with
  | some g, some c => { s with auto := upd s.auto g (some ⟨c, s.fs⟩) }
  | _, _ => s

/-- loadRom 7881-7890, first segment: the outgoing game's snapshot, then await. -/
def launchCall (fx : Bool) (s : St) (g : Nat) (gb : Bool) : St :=
  match s.cur with
  | some _ => push (autoSnap s) (.loadPre g gb)
  | none => l3 fx s g gb       -- 7888: nothing loaded, straight to the switch

/-- initFromEmscripten 1706-1707: the outgoing GB core's `mbc_save` to its own
    sav_path, which is `rom.sav` too. -/
def gbFlush (core : Option Core) (fs : Option Bytes) : Option Bytes :=
  match core with
  | some c => if c.gb && c.dirty then (match c.ram with | some r => some r | none => fs) else fs
  | none => fs

/-- offerAutoResume 5669-5673: first segment. -/
def offerStart (s : St) : St :=
  match s.cur with
  | some n => push s (.offerGet n (s.auto n))
  | none => s

def raiseOpt (s : St) : Option Bytes → St
  | some b => raise s b
  | none => s

/-- restoreSave 5271-5273 + initFromEmscripten + offerAutoResume's start.
    fx: `rom.sav` is replaced by exactly the incoming save (unlinked when it has
    none), the names switch here, and initFromEmscripten no longer flushes the
    outgoing core into the incoming game's file. -/
def l4 (fx : Bool) (s : St) (g : Nat) (gb : Bool) (v : Option Bytes) : St :=
  if fx then
    offerStart { s with fs := v, cur := some g, paused := false, core := some ⟨g, gb, v, false⟩ }
  else
    let fs1 := match v with | some b => some b | none => s.fs    -- 5271: no save, no write
    let fs2 := gbFlush s.core fs1
    offerStart { raiseOpt s fs2 with fs := fs2, core := some ⟨g, gb, fs2, false⟩ }

/-- applyStateBytes (5451) with the core's header check. -/
def applyState (s : St) (sc : Core) : St :=
  match s.core with
  | some c => if sc.game = c.game then { s with core := some { sc with dirty := true } } else s
  | none => s

/-- An explicit state load is the user's choice of save: a fresh version. -/
def restamp (t : Nat) (sc : Core) : Core :=
  { sc with ram := sc.ram.map (fun r => ⟨r.game, t⟩) }

def gbOf (s : St) : Bool := match s.core with | some c => c.gb | none => false

def resumeP (fx : Bool) (s : St) (p : Pending) (ok : Bool) : St :=
  match p with
  | .persist g b k =>                                       -- 5260-5263
      finish fx { s with lastSig := some (g, b), uploads := s.uploads ++ [(g, b)] } k
  | .evict g b k t =>
      if ok then                                            -- 4280: evicted one
        if s.seq g ≠ t then finish fx s k                   -- 4271, 5274: a later persist went in
        else                                                -- 4276: put again
          push (raise { s with idb := upd s.idb g (some b), writes := s.writes ++ [(g, b)] } b)
            (.persist g b k)
      else finish fx { s with lastSig := none } k            -- 5275-5280: nothing left to give
  | .loadPre g gb =>                                        -- 7890 (names re-read here)
      match s.cur with
      | some a => persistCall fx s a ok (.load g gb)
      | none => s
  | .loadRestore g gb v => l4 fx s g gb v
  | .offerGet g a =>                                        -- 5676-5677
      match a with
      | some a' => if s.cur = some g then push s (.offerCheck g a' (s.idb g)) else s
      | none => s
  | .offerCheck g a v =>                                    -- 5677-5679
      if a.saveSig = v ∧ s.cur = some g then { s with toast := some (g, a) } else s
  | .tapCheck g a v =>                                      -- 5683-5688
      if a.saveSig = v ∧ s.cur = some g then
        applyState { s with resumes := s.resumes ++ [(g, a, v)] } a.core
      else s
  | .unloadPre g flush thenDelete =>
      -- fx: unloadGame re-checks, after its awaits, that the game it set out
      -- to close is still the one loaded.
      if fx && s.cur != some g then s
      else
        let s1 := { s with cur := none }                     -- 9644-9645
        if flush then persistCall fx s1 g ok .unload         -- 9646
        else
          let s2 := { s1 with fs := none, paused := true }  -- 9648, 9651
          if thenDelete then push s2 (.delSaves g) else s2   -- 1930 deleteGameEverywhere
  | .delSaves g =>
      push { s with idb := upd s.idb g none, wiped := upd s.wiped g (some s.clock),
                    floor := upd s.floor g 0 } (.delRest g)
  | .delRest g =>
      { s with slot := upd s.slot g none, auto := upd s.auto g none, deletes := s.deletes ++ [g] }
  | .resetRest g loaded gb =>
      let s1 := { s with slot := upd s.slot g none, auto := upd s.auto g none,
                         deletes := s.deletes ++ [g] }
      if loaded then l3 fx s1 g gb else s1                  -- 1864 the reboot: loadRom
  | .slotGet _ v =>                                         -- 5617-5618 (no name re-check)
      match v with
      | some sc => applyState { s with clock := s.clock + 1 } (restamp s.clock sc)
      | none => s
  | .importPut _ =>                                         -- 5321 loadRom(current names)
      match s.cur with
      | some g' => launchCall fx s g' (gbOf s)
      | none => s
  | .pull g b =>                                            -- 3011 writeSyncBytes
      raise { s with idb := upd s.idb g (some b) } b

def step (fx : Bool) (s : St) : Ev → St
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
      | some g => persistCall fx s g ok .none
      | none => s
  | .hide => autoSnap s
  | .launch g gb => launchCall fx s g gb
  | .resume i ok =>
      match s.pend[i]? with
      | some p => resumeP fx { s with pend := s.pend.eraseIdx i } p ok
      | none => s
  | .close =>                                               -- 9637-9641
      match s.cur with
      | some g => push (autoSnap s) (.unloadPre g true false)
      | none => s
  | .delete g =>                                            -- 1921-1930
      if s.cur = some g then push s (.unloadPre g false true) else push s (.delSaves g)
  | .reset g =>
      -- 1858-1860: a loaded game is detached first (detachLoadedGame 1578-1585:
      -- unlink the FS .sav, null the names), in the same segment as the first
      -- delete (resetGameSaves 3146 -> deleteSaveData 1548: save:g).
      let loaded := decide (s.cur = some g)
      let s0 := if loaded then { s with fs := none, cur := none } else s
      push { s0 with idb := upd s0.idb g none, wiped := upd s0.wiped g (some s0.clock),
                     floor := upd s0.floor g 0 } (.resetRest g loaded (gbOf s))
  | .tapResume =>
      match s.toast with
      | some (g, a) =>
        let s1 := { s with toast := none }
        if s.cur = some g then push s1 (.tapCheck g a (s.idb g)) else s1   -- 5682
      | none => s
  | .slotSave =>
      match s.cur, s.core with
      | some g, some c => { s with slot := upd s.slot g (some c) }
      | _, _ => s
  | .slotLoad =>
      match s.cur with
      | some g => push s (.slotGet g (s.slot g))
      | none => s
  | .importSave =>                                          -- 5316-5317
      match s.cur, s.core with
      | some g, some _ =>
        let b : Bytes := ⟨g, s.clock⟩
        push (raise { s with fs := some b, idb := upd s.idb g (some b), clock := s.clock + 1 } b)
          (.importPut g)
      | _, _ => s
  | .pullStart g =>
      if s.cur = some g then s                              -- 3005 isRomLoaded
      else push { s with clock := s.clock + 1 } (.pull g ⟨g, s.clock⟩)

inductive Reachable (fx : Bool) : St → Prop
  | init : Reachable fx init
  | step {s : St} (e : Ev) : Reachable fx s → Reachable fx (step fx s e)

def run (fx : Bool) (s : St) : List Ev → St
  | [] => s
  | e :: es => run fx (step fx s e) es

theorem run_reachable (fx : Bool) (s : St) (es : List Ev) (h : Reachable fx s) :
    Reachable fx (run fx s es) := by
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

/-! ## The repaired machine keeps provenance

`fx = true`: (1) loadRom fetches the incoming save before it switches
anything, and then, in the one synchronous segment that switches the names and
runs initFromEmscripten, replaces `rom.sav` by exactly that save (unlinking it
when there is none); (2) initFromEmscripten no longer `mbc_save`s the outgoing
GB core into the file; (3) unloadGame re-checks after its awaits that the game
it is closing is still the loaded one. -/

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

theorem l3_inv {s : St} (g : Nat) (gb : Bool) (h : FInv s) : FInv (l3 true s g gb) := by
  simp only [l3, ite_true]
  exact push_inv h (fun b hb => h.idb g b hb)

theorem finish_inv {s : St} (k : After) (h : FInv s) : FInv (finish true s k) := by
  cases k with
  | none => exact h
  | load g gb => exact l3_inv g gb h
  | unload =>
    constructor
    · exact h.idb
    · intro b hb; simp [finish] at hb
    · exact h.cur
    · exact h.core
    · exact h.auto
    · exact h.slot
    · exact h.toast
    · exact h.pend

theorem persistCall_inv {s : St} (g : Nat) (ok : Bool) (k : After) (h : FInv s)
    (hfs : ∀ b, s.fs = some b → b.game = g) : FInv (persistCall true s g ok k) := by
  unfold persistCall
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
    constructor
    · exact h.idb
    · exact h.fs
    · exact h.cur
    · exact h.core
    · intro g' a ha
      simp only [upd_apply] at ha
      split at ha
      · cases ha; exact h.core c hc
      · exact h.auto g' a ha
    · exact h.slot
    · exact h.toast
    · exact h.pend
  · exact h

theorem launchCall_inv {s : St} (g : Nat) (gb : Bool) (h : FInv s) :
    FInv (launchCall true s g gb) := by
  unfold launchCall
  split
  · exact push_inv (autoSnap_inv h) trivial
  · exact l3_inv g gb h

theorem offerStart_inv {s : St} (h : FInv s) : FInv (offerStart s) := by
  unfold offerStart
  split
  · rename_i n _
    exact push_inv h (fun a' ha => h.auto n a' ha)
  · exact h

theorem l4_inv {s : St} (g : Nat) (gb : Bool) (v : Option Bytes) (h : FInv s)
    (hv : ∀ b, v = some b → b.game = g) : FInv (l4 true s g gb v) := by
  simp only [l4, ite_true]
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
    FInv (resumeP true s p ok) := by
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
    · exact applyState_inv _ (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl) hp
    · exact h
  | unloadPre g flush thenDelete =>
    simp only [resumeP, Bool.true_and]
    split
    · exact h
    · rename_i hne
      have hc : s.cur = some g := by
        simpa using hne
      have hfs := fs_of_cur h hc
      split
      · refine persistCall_inv (s := { s with cur := none }) g ok _ ?_ (fun b hb => hfs b hb)
        constructor
        · exact h.idb
        · exact h.fs
        · intro g' hg'; simp at hg'
        · exact h.core
        · exact h.auto
        · exact h.slot
        · exact h.toast
        · exact h.pend
      · have h2 : FInv { s with cur := none, fs := none, paused := true } := by
          constructor
          · exact h.idb
          · intro b hb; simp at hb
          · intro g' hg'; simp at hg'
          · exact h.core
          · exact h.auto
          · exact h.slot
          · exact h.toast
          · exact h.pend
        split
        · exact push_inv (p := .delSaves g) h2 trivial
        · exact h2
  | delSaves g =>
    simp only [resumeP]
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
    · exact l3_inv g gb h1
    · exact h1
  | slotGet g v =>
    simp only [resumeP]
    split
    · rename_i sc
      exact applyState_inv _ (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl)
        (restamp_wf _ _ (hp sc rfl))
    · exact h
  | importPut g =>
    simp only [resumeP]
    split
    · exact launchCall_inv _ _ h
    · exact h
  | pull g b =>
    simp only [resumeP]
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

theorem step_inv {s : St} (e : Ev) (h : FInv s) : FInv (step true s e) := by
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
    · exact push_inv (autoSnap_inv h) trivial
    · exact h
  | delete g =>
    simp only [step]
    split
    · exact push_inv (p := .unloadPre g false true) h trivial
    · exact push_inv (p := .delSaves g) h trivial
  | reset g =>
    simp only [step]
    have h0 : FInv (if decide (s.cur = some g) = true then { s with fs := none, cur := none }
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
    generalize (if decide (s.cur = some g) = true then { s with fs := none, cur := none }
                else s) = s0 at h0 ⊢
    refine push_inv ?_ trivial
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
      refine push_inv (p := .importPut g) ?_ trivial
      apply raise_inv
      obtain ⟨c', hc', hg'⟩ := h.cur g hg
      constructor
      · intro g' b' hb'
        simp only [upd_apply] at hb'
        split at hb'
        · rename_i hgg; cases hb'; exact hgg.symm
        · exact h.idb g' b' hb'
      · intro b hb
        simp only [Option.some.injEq] at hb
        subst hb
        exact ⟨c', hc', hg'⟩
      · exact h.cur
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

theorem fixed_reachable_inv {s : St} (h : Reachable true s) : FInv s := by
  induction h with
  | init => exact finv_init
  | step e _ ih => exact step_inv e ih

/-- With the three repairs, `save:<g>` never receives another game's bytes,
    under every interleaving of timers, page events, taps and awaits. -/
theorem fixed_provenance {s : St} (h : Reachable true s) : Prov s :=
  (fixed_reachable_inv h).idb

/-! ## What the shipped code does keep

Both hold for the shipped machine (`fx = false`) under every interleaving. -/

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

theorem ginv_l3 {s : St} (fx : Bool) (g : Nat) (gb : Bool) (h : GInv s) : GInv (l3 fx s g gb) := by
  unfold l3
  split
  · exact ginv_push _ h
  · exact ginv_push _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))

theorem ginv_finish {s : St} (fx : Bool) (k : After) (h : GInv s) : GInv (finish fx s k) := by
  cases k with
  | none => exact h
  | load g gb => exact ginv_l3 fx g gb h
  | unload => exact ginv_congr h rfl rfl rfl (fun _ hq => hq)

theorem ginv_persistCall {s : St} (fx : Bool) (g : Nat) (ok : Bool) (k : After) (h : GInv s) :
    GInv (persistCall fx s g ok k) := by
  unfold persistCall
  split
  · exact ginv_finish fx k h
  · rename_i b _
    split
    · exact ginv_finish fx k h
    · split
      · exact ginv_write g b k h _ rfl rfl rfl rfl
      · exact ginv_push _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))

theorem ginv_autoSnap {s : St} (h : GInv s) : GInv (autoSnap s) := by
  unfold autoSnap
  split
  · exact ginv_congr h rfl rfl rfl (fun _ hq => hq)
  · exact h

theorem ginv_launchCall {s : St} (fx : Bool) (g : Nat) (gb : Bool) (h : GInv s) :
    GInv (launchCall fx s g gb) := by
  unfold launchCall
  split
  · exact ginv_push _ (ginv_autoSnap h)
  · exact ginv_l3 fx g gb h

theorem ginv_offerStart {s : St} (h : GInv s) : GInv (offerStart s) := by
  unfold offerStart
  split
  · exact ginv_push _ h
  · exact h

theorem ginv_raiseOpt {s : St} (o : Option Bytes) (h : GInv s) : GInv (raiseOpt s o) := by
  cases o <;> exact ginv_congr h rfl rfl rfl (fun _ hq => hq)

theorem ginv_l4 {s : St} (fx : Bool) (g : Nat) (gb : Bool) (v : Option Bytes) (h : GInv s) :
    GInv (l4 fx s g gb v) := by
  unfold l4
  split
  · exact ginv_offerStart (ginv_congr h rfl rfl rfl (fun _ hq => hq))
  · apply ginv_offerStart
    have h' := ginv_raiseOpt (gbFlush s.core (match v with | some b => some b | none => s.fs)) h
    exact ginv_congr h' rfl rfl rfl (fun _ hq => hq)

theorem ginv_applyState {s : St} (sc : Core) (h : GInv s) : GInv (applyState s sc) := by
  unfold applyState
  split
  · split
    · exact ginv_congr h rfl rfl rfl (fun _ hq => hq)
    · exact h
  · exact h

theorem ginv_resumeP {s : St} (fx : Bool) (p : Pending) (ok : Bool) (s0 : St) (i : Nat)
    (hs : s = { s0 with pend := s0.pend.eraseIdx i }) (hi : s0.pend[i]? = some p)
    (h0 : GInv s0) : GInv (resumeP fx s p ok) := by
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
      apply ginv_applyState
      constructor
      · intro x hx
        rw [List.mem_append, List.mem_singleton] at hx
        rcases hx with hx | rfl
        · exact h.guard x hx
        · exact hc.1
      · exact h.upload
    · exact h
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
      | exact ginv_finish fx _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_persistCall fx _ ok _ h
      | exact ginv_persistCall fx _ ok _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_l4 fx _ _ _ h
      | exact ginv_push _ h
      | exact h
      | exact ginv_launchCall fx _ _ h
      | exact ginv_applyState _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_write _ _ _ h _ rfl rfl rfl rfl
      | exact ginv_push _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_congr h rfl rfl rfl (fun _ hq => hq)
      | exact ginv_l3 fx _ _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | split

theorem ginv_init : GInv init := by
  constructor
  · intro x hx; simp [init] at hx
  · intro x hx; simp [init] at hx

theorem ginv_step {s : St} (fx : Bool) (e : Ev) (h : GInv s) : GInv (step fx s e) := by
  cases e with
  | resume i ok =>
    simp only [step]
    split
    · rename_i p hp
      exact ginv_resumeP fx p ok s i rfl hp h
    · exact h
  | tick ok =>
    simp only [step]
    split
    · exact ginv_persistCall fx _ ok _ h
    · exact h
  | launch g gb => exact ginv_launchCall fx g gb h
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
      | exact ginv_push _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_congr h rfl rfl rfl (fun _ hq => hq)
      | split

theorem shipped_ginv {s : St} (h : Reachable false s) : GInv s := by
  induction h with
  | init => exact ginv_init
  | step e _ ih => exact ginv_step false e ih

/-- Shipped code: a Resume is applied only when its `saveSig` matched the
    stored `save:<g>` read by a check issued after the tap. -/
theorem resume_only_on_sig_match {s : St} (h : Reachable false s) : ResumeGuard s :=
  (shipped_ginv h).guard

/-- Shipped code: every save `persistSave` wrote to `save:<g>` reaches
    `markUpload("save:"+g)` with the same bytes (or is about to: the
    continuation after the put is still pending). -/
theorem persist_marks_upload {s : St} (h : Reachable false s) : UploadInv s :=
  (shipped_ginv h).upload

/-! ## Counterexamples in the shipped code (`fx = false`)

Game 0 and game 1 are two library games; `false`/`true` after `launch` is
GBA/GB. Pending indices are positions in `pend` (new continuations are
appended). -/

open Ev in
/-- Play A (0) and save in game; go home; tap B (1), which has no save on
    this device. `rom.sav` still holds A's save, B's core boots on it, and
    the next 5 s flush writes it to `save:B` and queues it for Drive. -/
def trSwitch : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,     -- A boots (no save yet)
   play, frame, tick true, resume 0 true,             -- A saves; flushed to save:A
   pause,                                             -- home screen
   launch 1 false, resume 0 true,                     -- tap B: outgoing persist, names switch
   resume 0 true,                                     -- restoreSave: B has none -> rom.sav untouched; init
   tick true, resume 1 true]                          -- the 5 s flush

theorem bug_switch_writes_other_games_save :
    let s := run false init trSwitch
    Reachable false s ∧ s.idb 1 = some ⟨0, 1⟩ ∧ (1, (⟨0, 1⟩ : Bytes)) ∈ s.uploads ∧
      s.core = some ⟨1, false, some ⟨0, 1⟩, false⟩ ∧ ¬ Prov s := by
  refine ⟨run_reachable _ _ _ .init, by decide, by decide, by decide, fun h => ?_⟩
  have := h 1 ⟨0, 1⟩ (by decide)
  simp at this

open Ev in
/-- B (1) has its own save (from an earlier Drive pull). Switching A -> B,
    the page is hidden (pagehide: persistSave with the CURRENT names) in the
    window between the name switch and restoreSave's dbGet resolving:
    `rom.sav` is still A's, so A's bytes are written to `save:B`. -/
def trSwitchWindow : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,     -- A boots
   pullStart 1, resume 0 true,                        -- B's save arrives from Drive
   play, frame, tick true, resume 0 true,             -- A saves; flushed
   pause,
   launch 1 false, resume 0 true,                     -- tap B: names switch, restoreSave's dbGet in flight
   tick true]                                         -- pagehide / the 5 s tick lands here

theorem bug_switch_window_overwrites_save :
    (run false init (trSwitchWindow.take 12)).idb 1 = some ⟨1, 1⟩ ∧
    let s := run false init trSwitchWindow
    Reachable false s ∧ s.idb 1 = some ⟨0, 2⟩ ∧ ¬ Prov s := by
  refine ⟨by decide, run_reachable _ _ _ .init, by decide, fun h => ?_⟩
  have := h 1 ⟨0, 2⟩ (by decide)
  simp at this

open Ev in
/-- A (0) is a GB game whose cart RAM is dirty when it is left (written after
    the frame's `handle_saves`). B (1) has a save. restoreSave writes B's save
    to `rom.sav`, then initFromEmscripten `mbc_save`s the outgoing GB core over
    it, B boots on A's RAM, and the next flush replaces `save:B` for good. -/
def trGbInitFlush : List Ev :=
  [launch 0 true, resume 0 true, resume 0 true,      -- A (GB) boots
   pullStart 1, resume 0 true,                        -- B's save arrives from Drive
   play, frame, tick true, resume 0 true,             -- A saves; flushed
   play, pause,                                       -- A writes cart RAM; home before the next flush
   launch 1 false, resume 0 true, resume 0 true,      -- tap B; restore + init (outgoing mbc_save)
   tick true, resume 1 true]

theorem bug_gb_init_flush_replaces_save :
    let s := run false init trGbInitFlush
    Reachable false s ∧ s.idb 1 = some ⟨0, 3⟩ ∧ s.fs = some ⟨0, 3⟩ ∧
      ¬ Prov s ∧ ¬ Durable s 1 := by
  refine ⟨run_reachable _ _ _ .init, by decide, by decide, fun h => ?_, ?_⟩
  · have := h 1 ⟨0, 3⟩ (by decide)
    simp at this
  · simp only [Durable]; decide

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
   resume 0 true]                                     -- restoreSave finds nothing

theorem regress_reset_undone_by_flush (fx : Bool) :
    let s := run fx init trResetUndone
    Reachable fx s ∧ s.idb 0 = none ∧ s.wiped 0 = some 3 ∧ s.cur = some 0 ∧
      s.core = some ⟨0, false, none, false⟩ ∧ 0 ∈ s.deletes ∧ NoResurrect s := by
  have hw : (run fx init trResetUndone).wiped = upd (fun _ => none) 0 (some 3) := by
    cases fx <;> rfl
  have hi : (run fx init trResetUndone).idb 0 = none := by cases fx <;> decide
  refine ⟨run_reachable _ _ _ .init, hi, by rw [hw]; rfl, by cases fx <;> decide,
    by cases fx <;> decide, by cases fx <;> decide, ?_⟩
  intro g b t hb ht
  rw [hw, upd_apply] at ht
  split at ht
  · subst_vars; rw [hi] at hb; cases hb
  · cases ht

open Ev in
/-- Close A, relaunch it: Resume is offered (the snapshot matches save:A).
    Within the toast's 8 s the player saves in game (rom.sav only; the 5 s
    flush has not run) and then taps Resume. The check compares with
    `save:A`, which still matches, so the older RAM is applied, marked dirty,
    and flushed over the newer save in `rom.sav`: it is gone everywhere. -/
def trResumeOverUnflushed : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,
   play, frame, tick true, resume 0 true,             -- save v1 persisted
   close, resume 0 true,                              -- Close: snapshot (saveSig v1), persist, unlink
   launch 0 false, resume 0 true, resume 0 true, resume 0 true, -- relaunch; offer checks; toast
   play, frame,                                       -- in-game save v2 (rom.sav only)
   tapResume, resume 0 true,                          -- the tap's check reads save:A = v1: match
   frame]                                             -- dirty v1 RAM flushed over v2

theorem bug_resume_over_unflushed_save :
    let s := run false init trResumeOverUnflushed
    Reachable false s ∧ s.floor 0 = 2 ∧ s.idb 0 = some ⟨0, 1⟩ ∧ s.fs = some ⟨0, 1⟩ ∧
      s.resumes.length = 1 ∧ ¬ Durable s 0 := by
  refine ⟨run_reachable _ _ _ .init, by decide, by decide, by decide, by decide, ?_⟩
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

theorem regress_quota_retry_writes_older_save (fx : Bool) :
    (run fx init trQuotaPre).idb 0 = some ⟨0, 2⟩ ∧
    let s := run fx init (trQuotaPre ++ trQuotaPost)
    Reachable fx s ∧ s.idb 0 = some ⟨0, 2⟩ ∧ s.uploads = [(0, ⟨0, 2⟩)] ∧ s.pend = [] := by
  refine ⟨by cases fx <;> decide, run_reachable _ _ _ .init, by cases fx <;> decide,
    by cases fx <;> decide, by cases fx <;> decide⟩

open Ev in
/-- App start on a second device: a Drive pull is downloading game 0's newer
    save (it checked `isRomLoaded` before `await driveDownload`) when the
    player taps game 0. The game boots on the stale local save, the download
    lands in `save:0`, and the first 5 s flush (lastSaveSig is null at page
    start) writes the stale bytes over it and queues them for Drive. -/
def trPullUnderLoaded : List Ev :=
  [pullStart 0, resume 0 true,                        -- an earlier sync left v1 here
   pullStart 0,                                       -- boot pull: v2 downloading
   launch 0 false, resume 1 true, resume 1 true,      -- tap game 0: boots on v1
   resume 0 true,                                     -- download lands: save:0 = v2
   tick true, resume 0 true]                          -- first flush: v1 over v2, markUpload

theorem bug_pull_overwritten_by_stale_flush :
    let s := run false init trPullUnderLoaded
    Reachable false s ∧ s.floor 0 = 2 ∧ s.idb 0 = some ⟨0, 1⟩ ∧
      s.uploads = [(0, ⟨0, 1⟩)] ∧ ¬ Durable s 0 := by
  refine ⟨run_reachable _ _ _ .init, by decide, by decide, by decide, ?_⟩
  simp only [Durable]; decide

/-- The repaired machine on the first counterexample's events: `save:B`
    stays empty (B never had a save). -/
theorem fixed_switch_trace_clean : (run true init trSwitch).idb 1 = none := by decide

end WebState.SavePersistence
