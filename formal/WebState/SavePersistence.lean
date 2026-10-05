-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/index.js: addCheckpoint applyImportedSave applyStateBytes autoStateMatchesSave dbPutRoomy deleteGameAction deleteGameEverywhere deleteKeys deleteSaveData detachLoadedGame evictCheckpoints evictOldestRom flushSoloSave installSave isRomLoaded launchRom liveSaveSig loadFromSlot loadRom markDelete markUpload maybeCheckpoint offerAutoResume persistAutoState persistSave queueSaveDataDeletes resetCurrentSaveFile resetGameAction resetGameSaves resumeGame resumeMoment resumeSessionFor retireSavePuts saveToSlot showMainMenu sigOfSave storeCheckpoint storeLastFrame takeCheckpoint unloadGame writeSyncBytes on:visibilitychange

/-
# Battery-save and save-state persistence (web/index.js)

What a game's battery save goes through on its way from the wasm core to the
IndexedDB key `save:<game>` (and from there to Drive's upload queue), and back;
and the session snapshot (`stateauto:<game>`) and checkpoints that carry it.

`step` models the code at 03f88d6c (line numbers are at that commit). The
machine at dd7ba741f, and its seven counterexamples, are in this file's
history; each trace is replayed against `step` as a `regress_*` theorem. The
re-audit at 03f88d6c added the checkpoints (6ee01e88: `takeCheckpoint`,
`storeCheckpoint`, `addCheckpoint`, `evictCheckpoints`, the moments sheet's
`resumeMoment`), the hero's Resume that boots straight into the session
(`launchRom`'s `resume`, `loadRom`'s `opts.resume`), the session epochs, the
Saves panel's Reset as its own path, and the Drive pull's re-check of the
delete queue; it found three new counterexamples (`bug_*` below).

* The core keeps the cart's battery RAM in memory and marks it dirty when the
  game writes it (`ram_dirty`, gb.nim; `storage.dirty`, gba storage.nim). Once
  per emulated frame the dirty RAM is written to the emscripten MEMFS file
  next to the ROM (`handle_saves`: gb.nim 3443 `mbc_save`, gba.nim 2206
  `write_save`); a paused core runs no frames, so a state loaded while paused
  leaves its RAM in the core only. `wasm_flush_save` (dingbat_wasm.nim 461)
  writes it on demand: `flushSoloSave` (7433) calls it for the loaded solo
  game, and every reader of that game's file calls `flushSoloSave` first.
  Every solo ROM is the FS file `rom.<ext>` (written at the boot, loadRom
  11688), so there is ONE battery file, `rom.sav`, shared by every game.
* `persistSave(romName, originalName)` (7440) flushes the solo core when
  `romName` is the loaded game's (7443), reads that file synchronously, skips
  if its signature equals `lastSaveSig` for the same name (7447), else takes
  the next number in `persistSeq` (7426, 7448-7449) and
  `await dbPutRoomy("save:" + originalName, ...)` (6166; the put is issued in
  the same segment). On a QuotaExceededError dbPutRoomy first frees other
  games' checkpoints (`evictCheckpoints` 8448, 6181-6184) and puts again; if
  none were freed (or the put fails again) it evicts a ROM (`evictOldestRom`,
  6185) and puts again unless something has taken a later number for the same
  save meanwhile (`superseded()`, 6171, asked only once a ROM has gone:
  `freed`). Then it remembers the signature and calls
  `markUpload("save:" + originalName)` (7460-7463). A later persist, and a
  delete (`retireSavePuts` 7427: deleteKeys 1700, resetCurrentSaveFile 1728)
  or an import (7592) of the same save, each take a number.
  Callers: the 5 s `setInterval` (15921), the settle watch, `beforeunload`
  (15931), `visibilitychange` (15957), `pagehide` (15972) and Main Menu
  (`showMainMenu` 13491-13494) with the *current* names; `loadRom` (11672)
  for the outgoing game; `unloadGame` (14192) for the game it closes, before
  its names are nulled; `storeCheckpoint` (8341-8344) and `resumeMoment`
  (9098) for the loaded game.
* `loadRom` (11646): outgoing game: `await persistAutoState()`,
  `await storeLastFrame()`, `await persistSave(...)` (11666-11674); then
  `loadingName = g` and `await dbGet("save:" + g)` (11678-11679); then ONE
  segment (11688-11726) writes the ROM, `installSave` (7477: writes the FS
  `.sav`, or unlinks it when there is no stored save, and sets `lastSaveSig`
  to what it wrote), `initFromEmscripten` (builds the new core, which reads
  `rom.sav` if it exists, gba.nim 1847 `new_storage`, gb `mbc_load`; no flush
  of the outgoing core), clears `loadingName`, names the game, puts back the
  session the launch chose (`opts.resume`, 11702-11710: unless `force`, only
  when its `saveSig` is the battery just installed, `liveSaveSig`), and sets
  `paused = false`. Then `offerAutoResume` (11764, 8791) unless the launch
  chose (`skipResumeOffer`).
* Resume snapshot: `persistAutoState` (8126) stores `stateauto:<game>` with
  the FS `.sav` signature (`liveSaveSig` 8744, which flushes first: the
  signature is the battery the state carries) and stamps `sessionSnapTs`
  (8149); `offerAutoResume` and the toast's tap re-check it against
  `save:<game>` (`autoStateMatchesSave` 8752), and the tap also against the
  live battery (8806-8807) before `applyStateBytes` (7923), which marks the
  cart RAM dirty when it changed (gb savestate.nim 975, gba savestate.nim
  774). The hero's Resume (`launchRom(name, {resume: true})` 6456 ->
  `resumeSessionFor` 8760, the same check) hands the session to `loadRom`.
* Checkpoints: every minute of play `maybeCheckpoint` (8302) runs
  `takeCheckpoint` (8312): flush, capture, stamp `sessionSnapTs` and note the
  session epoch, pack in a worker. `storeCheckpoint` (8335) drops it if a
  newer snapshot was taken or the session deleted since (8337; the epoch is
  bumped by `deleteKeys` 1702-1705 where it deletes `stateauto:`); else, if
  the battery it carries is not the stored one, `await persistSave`
  (8341-8344); then the session put (8346), the picture's, and
  `addCheckpoint` (8411: read the index, re-check the epoch (8413), write
  the moment). The moments sheet's `resumeMoment` (9092) launches with an
  earlier moment, `force`: its battery goes back with it (the newer save
  kept aside).
* Slots: `saveToSlot` (7985), `loadFromSlot` (8025). Import:
  `applyImportedSave` (7572) detaches the game (as Reset), retires waiting
  puts, puts the imported bytes, `markUpload`s them and reboots. Delete:
  `deleteGameAction` (2151) -> `unloadGame({flushSave:false})` (14173) ->
  `deleteGameEverywhere` (4668: queues every key's Drive delete first, 4675).
  Close: `unloadGame` (14173): after its awaits, if no later load or close
  has taken the token, flush, detach and unlink in one segment
  (14192-14195). Reset: `resetGameAction` (2077) detaches a loaded game first
  (`detachLoadedGame` 1745: the token, unlink the FS .sav, null the names),
  then `resetGameSaves` (4659: queues the Drive deletes, 4665, then deletes,
  `deleteSaveData` 1712), then reboots it with `loadRom`. The Saves panel's
  Reset (`resetCurrentSaveFile` 1723) detaches, deletes the save, the session
  and the checkpoints (slots stay), and queues its Drive deletes only after
  those awaits (1733-1735), then reboots. Drive pull (`pullSyncInner` 4201):
  the `isRomLoaded || loadingName` guard before the download (4414) and again
  after it (4442), the delete queue (4449), then `writeSyncBytes` (4451,
  3215). Pulls and flushes run one at a time (`runExclusive` 3753).

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

* One slot (slot 0) stands for all nine, and one moment (`ckpt`) for the
  nine checkpoint slots and their index; `-p2` link saves, 2P link mode,
  rollback/netplay (all refuse or bypass `persistSave` and the snapshots),
  rename (which detaches the name before any await) and the thumbnail batch
  (scratch FS names) are not modelled. Neither is a page's restart (the last
  gasp taken in at boot, `takeLastGasp`, and the crash marks): the model is
  one page's lifetime.
* The load token (`loadGen`) is not modelled here (GameLifecycle has it): any
  number of loads may be in flight and each may boot. That is a superset of
  the JS, where only the latest does; `unloadGame`'s token check is modelled
  as "the game it set out to close is still the one named". The session a
  load carries (`opts.resume`) is kept per game (`boot`), set by the load's
  first segment: the latest load of a game is the one that boots in the JS,
  and it reads its own.
* `storeLastFrame`, cheats, art, `recent`, the session's picture, Drive's own
  queue processing: no effect on the modelled keys; their awaits are merged
  with adjacent awaits (merging two awaits between which only effect-free
  code runs loses no behaviour of the modelled state). `launchRom`'s awaits
  before `loadRom` are merged likewise, and `resumeMoment`'s persist,
  `dbGet` and `keepOldSave` (a copy under `oldsave:`, not modelled) are left
  to `tick` and the moment read.
* `persistAutoState`'s skips are not modelled: with no frame, state load or
  boot since the last snapshot and no checkpoint in flight (8133) the record
  it would write is the one already stored (but for its ts); a session held
  after a refused too-new state (`sessionHeldFor`) only arises from a refusal
  this model does not have (the core's version check). The snapshot always
  writes here.
* `markUpload` is recorded with the bytes the persist wrote (`uploads`); what
  Drive does with its queue is the Drive machine's business. `markDelete` of
  a save is recorded as `deletes`, and the delete queue's `save:<g>` entry as
  `queued g`, cleared by `driveFlush g`, which cannot run while a pull is in
  flight (`runExclusive`).
* Every cart is modelled as having a battery. A save-less cart only narrows
  the core-side paths; `persistSave` reads `rom.sav` whatever the cart is.
* The frame loop is allowed whenever `!paused` and a core exists (rAF is
  throttled when hidden; allowing more frames only adds behaviours), and so
  is a checkpoint.
* The core's state-header check (`stateRejectMessage`) is modelled as
  "a state applies only to a core of the same game"; a state load marks the
  RAM dirty always (the cores do when it changed: a flush of unchanged RAM
  writes what the file holds, or what a dirty core would have flushed anyway).
* A Resume toast never expires in the model (it lives 8 s in the page); the
  first check of the hero's Resume (`resumeSessionFor`) is the `ok` of its
  continuation (passed: the session goes to the load; failed: none).
* `pullStart g` is the Drive pull reaching `save:<g>` (the other device's
  newer save, a fresh version); only its interaction with `save:<g>` is modelled.
* The Saves panel's Reset keeps the slots; `resetGameAction` deletes them.
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

/-- A `stateauto:<game>` record (persistAutoState 8157), or a checkpoint's
    (takeCheckpoint 8316-8319): the captured core and `saveSig`. -/
structure Snap where
  core    : Core
  saveSig : Option Bytes   -- sigOfSave(FS .sav at capture); none = no .sav
deriving DecidableEq, Repr

/-- What the awaiting caller of a `persistSave` does when it returns. -/
inductive After where
  | none                      -- the setInterval / pagehide / beforeunload / unloadGame call
  | load (g : Nat) (gb : Bool) -- loadRom 11672: the rest of loadRom
deriving DecidableEq, Repr

inductive Pending where
  /-- persistSave 7450: `dbPutRoomy` put issued and accepted; awaiting it. -/
  | persist (g : Nat) (b : Bytes) (k : After)
  /-- dbPutRoomy 6179-6184: the put failed with QuotaExceededError; awaiting
      `evictCheckpoints`. Resumed `ok`: a checkpoint was freed and the put,
      issued again (`continue`), is accepted, with no `superseded()` check
      (6171 asks only once a ROM has gone). Otherwise (nothing freed, or the
      put failed again) on to a ROM: `evict`. -/
  | evictCk (g : Nat) (b : Bytes) (k : After) (t : Nat)
  /-- dbPutRoomy 6185: awaiting `evictOldestRom`, after which the same bytes
      are put again, unless something has taken a number for this save past
      `t` (6171). -/
  | evict (g : Nat) (b : Bytes) (k : After) (t : Nat)
  /-- loadRom 11668-11672: awaiting persistAutoState + storeLastFrame. -/
  | loadPre (g : Nat) (gb : Bool)
  /-- loadRom 11679: awaiting `dbGet("save:"+g)` (= v). -/
  | loadRestore (g : Nat) (gb : Bool) (v : Option Bytes)
  /-- offerAutoResume 8796: awaiting `dbGet(stateauto)` (= a). -/
  | offerGet (g : Nat) (a : Option Snap)
  /-- offerAutoResume 8799 / autoStateMatchesSave: awaiting `dbGet(save)`. -/
  | offerCheck (g : Nat) (a : Snap) (v : Option Bytes)
  /-- the Resume toast's handler 8806: awaiting `dbGet(save)`. -/
  | tapCheck (g : Nat) (a : Snap) (v : Option Bytes)
  /-- unloadGame 14180-14184: awaiting persistAutoState + storeLastFrame. -/
  | unloadPre (g : Nat) (flush : Bool) (thenDelete : Bool)
  /-- deleteGameEverywhere 4676 -> deleteKeys: awaiting the rom/art/frame deletes. -/
  | delSaves (g : Nat)
  /-- ... save:g deleted; awaiting the slot, session and checkpoint deletes. -/
  | delRest (g : Nat)
  /-- resetGameAction 2081 / resetCurrentSaveFile 1729: save:g deleted; awaiting
      the other deletes. `loaded`: the game was loaded and has been detached;
      `gb`: its core's kind; `file`: the Saves panel's Reset. -/
  | resetRest (g : Nat) (loaded : Bool) (gb : Bool) (file : Bool)
  /-- loadFromSlot: awaiting `dbGet(state:g)` (= v). -/
  | slotGet (g : Nat) (v : Option Core)
  /-- applyImportedSave 7593: awaiting `dbPut(save:g)` of the imported bytes. -/
  | importPut (g : Nat) (gb : Bool)
  /-- Drive pull 4414-4438: passed the guard, awaiting the download. -/
  | pull (g : Nat) (b : Bytes)
  /-- takeCheckpoint 8327: the worker packing; then storeCheckpoint's first
      segment. `n`: the `sessionSnapTs` it stamped; `e`: the epoch it noted. -/
  | ckStore (g : Nat) (a : Snap) (n e : Nat)
  /-- storeCheckpoint 8343: awaiting persistSave; then the session put (8346). -/
  | ckPut (g : Nat) (a : Snap) (e : Nat)
  /-- storeCheckpoint 8346-8358 -> addCheckpoint 8412: awaiting the puts and
      readCheckpointIndex; then the epoch re-check (8413) and the write. -/
  | ckAdd (g : Nat) (a : Snap) (e : Nat)
  /-- launchRom 6448-6456 with `resume`: awaiting resumeSessionFor (its
      `dbGet(stateauto)` read `a`) and the ROM. -/
  | heroGet (g : Nat) (gb : Bool) (a : Option Snap)
  /-- resumeMoment 9099-9110: awaiting momentRecord (read `m`), the save
      read and keepOldSave; then launchRom with the moment, `force`. -/
  | momGet (g : Nat) (gb : Bool) (m : Option Snap)
deriving DecidableEq, Repr

def Pending.isPull : Pending → Bool
  | .pull _ _ => true
  | _ => false

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
  seq     : Nat → Nat            -- persistSeq (7426): the last number taken for save:g
  loading : Option Nat           -- loadingName
  pend    : List Pending         -- in-flight continuations
  toast   : Option (Nat × Snap)  -- the Resume action toast
  ckpt    : Nat → Option Snap    -- IndexedDB "ckpt<slot>:<g>" + "ckpts:<g>" (one moment)
  snapTs  : Nat → Nat            -- sessionSnapTs (8122): the newest snapshot's stamp
  epoch   : Nat → Nat            -- sessionEpochs (8123)
  boot    : Nat → Option (Snap × Bool) -- the session g's load carries (opts.resume; force)
  queued  : Nat → Bool           -- syncState.queueDel holds "save:<g>"
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
    loading := none, pend := [], toast := none, ckpt := fun _ => none, snapTs := fun _ => 0,
    epoch := fun _ => 0, boot := fun _ => none, queued := fun _ => false,
    writes := [], uploads := [], resumes := [],
    deletes := [], wiped := fun _ => none, floor := fun _ => 0 }

inductive Ev where
  | play                    -- the running game writes its cart battery RAM
  | frame                   -- handle_saves: dirty RAM -> rom.sav (once per frame)
  | pause                   -- showMainMenu (home) / pause button
  | unpause                 -- resumeGame (13503): needs a loaded game
  | tick (ok : Bool)        -- setInterval 15921 / pagehide 15972 / beforeunload 15931 /
                            -- Main Menu 13493: persistSave(current names); ok = the put is accepted
  | hide                    -- visibilitychange 15957 / pagehide / Main Menu 13492: persistAutoState()
  | launch (g : Nat) (gb : Bool) -- loadRom("rom.<ext>", g): tile tap (launchRom 6444), file drop, restart
  | resume (i : Nat) (ok : Bool) -- the i-th pending continuation runs
  | close                   -- "Close" on the paused card: unloadGame() (14173)
  | delete (g : Nat)        -- deleteGameAction(g) (2151)
  | reset (g : Nat) (file : Bool) -- resetGameAction(g) (2077); file: the Saves panel's resetCurrentSaveFile (1723)
  | tapResume               -- tap "Resume" on the toast
  | slotSave                -- saveToSlot(0)
  | slotLoad                -- loadFromSlot(0)
  | importSave              -- applyImportedSave, after the confirms (7590)
  | pullStart (g : Nat)     -- Drive pull reaches save:g (4414)
  | ckpt                    -- maybeCheckpoint (8302) -> takeCheckpoint (8312), from a running tick
  | hero (g : Nat) (gb : Bool)   -- the hero's Resume: launchRom(g, {resume: true}) (6444)
  | moment (g : Nat) (gb : Bool) -- "Resume from earlier": resumeMoment(g, m) (9092)
  | driveFlush (g : Nat)    -- a Drive flush sends save:g's queued delete (flushSyncInner)
deriving DecidableEq, Repr

def push (s : St) (p : Pending) : St := { s with pend := s.pend ++ [p] }

/-- ghost: g's save at version b.ver has been written somewhere durable-ish. -/
def raise (s : St) (b : Bytes) : St :=
  { s with floor := upd s.floor b.game (max (s.floor b.game) b.ver) }

/-- `flushSoloSave` (7433) -> `wasm_flush_save`: with a game loaded, the core's
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

/-- loadRom 11677-11679 after the outgoing persist: `loadingName = g`, the
    dbGet of the incoming save. Nothing is switched yet: the outgoing game
    stays named, on its own `rom.sav`, until the boot (`l4`). -/
def l3 (s : St) (g : Nat) (gb : Bool) : St :=
  push { s with loading := some g } (.loadRestore g gb (s.idb g))

def finish (s : St) : After → St
  | .none => s
  | .load g gb => l3 s g gb

/-- persistSave 7440-7451, its synchronous first segment: the flush (for the
    loaded game's file), then the read. -/
def persistCall (s : St) (g : Nat) (ok : Bool) (k : After) : St :=
  let s := if s.cur = some g then flushCore s else s        -- 7443
  match s.fs with
  | none => finish s k                                     -- 7444-7445 no FS file
  | some b =>
    if s.lastSig = some (g, b) then finish s k              -- 7447 unchanged
    else
      let t := s.seq g + 1                                  -- 7448-7449 persistSeq
      let s := { s with seq := upd s.seq g t }
      if ok then                                            -- 7450-7451 put issued, accepted
        push (raise { s with idb := upd s.idb g (some b), writes := s.writes ++ [(g, b)] } b)
          (.persist g b k)
      else push s (.evictCk g b k t)                        -- 6179-6184 quota: checkpoints first

/-- persistAutoState 8126-8161 (the dbPut's effect; nobody awaits its tail):
    the state captured, then `liveSaveSig` flushes and reads the file; the
    snapshot's stamp (8149). -/
def autoSnap (s : St) : St :=
  match s.cur, s.core with
  | some g, some c =>
    let s1 := flushCore s
    { s1 with auto := upd s1.auto g (some ⟨c, s1.fs⟩),
              snapTs := upd s1.snapTs g (s1.snapTs g + 1) }
  | _, _ => s

/-- loadRom 11646-11668, first segment: the load token (which clears
    `loadingName`), the session it carries (`opts.resume`, `r`), then the
    outgoing game's snapshot and await. -/
def launchCall (s : St) (g : Nat) (gb : Bool) (r : Option (Snap × Bool)) : St :=
  let s := { s with loading := none, boot := upd s.boot g r }
  match s.cur with
  | some _ => push (autoSnap s) (.loadPre g gb)
  | none => l3 s g gb          -- nothing loaded: straight to the dbGet

/-- offerAutoResume 8791-8796: first segment. -/
def offerStart (s : St) : St :=
  match s.cur with
  | some n => push s (.offerGet n (s.auto n))
  | none => s

/-- applyStateBytes with the core's header check. -/
def applyState (s : St) (sc : Core) : St :=
  match s.core with
  | some c => if sc.game = c.game then { s with core := some { sc with dirty := true } } else s
  | none => s

/-- An explicit state load is the user's choice of save: a fresh version. -/
def restamp (t : Nat) (sc : Core) : Core :=
  { sc with ram := sc.ram.map (fun r => ⟨r.game, t⟩) }

/-- loadRom 11688-11726, one segment: installSave replaces `rom.sav` by exactly
    the incoming save (unlinks it when there is none) and remembers its
    signature; initFromEmscripten builds the new core on it (and flushes no
    outgoing core); `loadingName` is cleared and the game named. Then the
    session the launch chose goes in (11702-11710): unless forced, only when
    its `saveSig` is the battery just installed (`liveSaveSig`: the new core
    is clean, so the file is `v`); a forced moment is the user's choice of
    save, a fresh version. With none, offerAutoResume's start (11764). -/
def l4 (s : St) (g : Nat) (gb : Bool) (v : Option Bytes) : St :=
  let s1 := { s with fs := v, cur := some g, paused := false, core := some ⟨g, gb, v, false⟩,
                     loading := none, lastSig := v.map (fun b => (g, b)) }
  match s1.boot g with
  | none => offerStart s1
  | some (a, false) =>
    if a.saveSig = v then applyState { s1 with resumes := s1.resumes ++ [(g, a, v)] } a.core
    else s1
  | some (a, true) => applyState { s1 with clock := s1.clock + 1 } (restamp s1.clock a.core)

def gbOf (s : St) : Bool := match s.core with | some c => c.gb | none => false

/-- A delete or an import of save:g takes a `persistSeq` number
    (`retireSavePuts` 7427): a put waiting on an eviction gives way. -/
def retire (s : St) (g : Nat) : St := { s with seq := upd s.seq g (s.seq g + 1) }

/-- storeCheckpoint 8341-8342: the battery the checkpoint carries is not the
    stored one, so it awaits persistSave first. -/
def ckNeeds (s : St) (g : Nat) (a : Snap) : Bool :=
  decide (s.cur = some g) &&
    (match a.saveSig with
     | some b => decide (s.lastSig ≠ some (g, b))
     | none => true)

/-- The session put of a checkpoint (8346), then addCheckpoint's awaits. -/
def ckSession (s : St) (g : Nat) (a : Snap) (e : Nat) : St :=
  push { s with auto := upd s.auto g (some a) } (.ckAdd g a e)

def resumeP (s : St) (p : Pending) (ok : Bool) : St :=
  match p with
  | .persist g b k =>                                       -- 7460-7463
      finish { s with lastSig := some (g, b), uploads := s.uploads ++ [(g, b)] } k
  | .evictCk g b k t =>
      if ok then                                            -- 6183 `continue`: put again,
        push (raise { s with idb := upd s.idb g (some b), writes := s.writes ++ [(g, b)] } b)
          (.persist g b k)                                  -- no superseded() (freed = 0)
      else push s (.evict g b k t)                          -- 6185: a ROM next
  | .evict g b k t =>
      if ok then                                            -- 6185-6186: evicted one
        if s.seq g ≠ t then finish s k                      -- 6171, 7452: taken over
        else                                                -- 6176: put again
          push (raise { s with idb := upd s.idb g (some b), writes := s.writes ++ [(g, b)] } b)
            (.persist g b k)
      else finish { s with lastSig := none } k               -- 7453-7458: nothing left to give
  | .loadPre g gb =>                                        -- 11672 (names re-read here)
      match s.cur with
      | some a => persistCall s a ok (.load g gb)
      | none => s
  | .loadRestore g gb v => l4 s g gb v
  | .offerGet g a =>                                        -- 8798-8799
      match a with
      | some a' => if s.cur = some g then push s (.offerCheck g a' (s.idb g)) else s
      | none => s
  | .offerCheck g a v =>                                    -- 8799-8801
      if a.saveSig = v ∧ s.cur = some g then { s with toast := some (g, a) } else s
  | .tapCheck g a v =>                                      -- 8806-8811: stored and live save
      if a.saveSig = v ∧ s.cur = some g then
        let s := flushCore s                                -- liveSaveSig flushes first
        if a.saveSig = s.fs then applyState { s with resumes := s.resumes ++ [(g, a, v)] } a.core
        else s
      else s
  | .unloadPre g flush thenDelete =>
      -- 14181-14185: a later load or close has taken the token: the game it
      -- set out to close is no longer the one named.
      if s.cur != some g then s
      else if flush then
        -- 14192-14195: the flush (the core's RAM, then the file), while the
        -- name still says the core is g's; then detach and unlink, one segment
        let s2 := persistCall s g ok .none
        { s2 with cur := none, fs := none, paused := true }
      else
        let s2 := { s with cur := none, fs := none, paused := true }  -- 14193-14200
        -- 2160 deleteGameEverywhere: the Drive deletes queued first (4675)
        if thenDelete then push { s2 with queued := upd s2.queued g true } (.delSaves g) else s2
  | .delSaves g =>                                          -- deleteKeys 1700, 1706
      push (retire { s with idb := upd s.idb g none, wiped := upd s.wiped g (some s.clock),
                            floor := upd s.floor g 0 } g) (.delRest g)
  | .delRest g =>                                           -- the slots, the session (the
      { s with slot := upd s.slot g none, auto := upd s.auto g none,  -- epoch, 1702-1705),
               epoch := upd s.epoch g (s.epoch g + 1), ckpt := upd s.ckpt g none, -- checkpoints
               deletes := s.deletes ++ [g] }
  | .resetRest g loaded gb file =>
      -- 1730-1736 / 4666 -> deleteSaveData 1714: the slots (resetGameAction
      -- only), the session (with its epoch) and the checkpoints; the Saves
      -- panel's Reset queues its Drive deletes only now (1733-1735)
      let s1 := { s with slot := if file then s.slot else upd s.slot g none,
                         auto := upd s.auto g none,
                         epoch := upd s.epoch g (s.epoch g + 1), ckpt := upd s.ckpt g none,
                         queued := if file then upd s.queued g true else s.queued,
                         deletes := s.deletes ++ [g] }
      if loaded then launchCall s1 g gb none else s1        -- 2083 / 1736 the reboot: loadRom
  | .slotGet _ v =>                                         -- loadFromSlot (no name re-check)
      match v with
      | some sc => applyState { s with clock := s.clock + 1 } (restamp s.clock sc)
      | none => s
  | .importPut g gb =>                                      -- 7594-7598: markUpload, reboot
      launchCall s g gb none
  | .pull g b =>                                            -- 4442, 4449-4451: re-checked, written
      if s.cur = some g ∨ s.loading = some g ∨ s.queued g = true then s
      else raise { s with idb := upd s.idb g (some b) } b
  | .ckStore g a n e =>
      -- 8337: a newer snapshot, or a delete, since: dropped
      if s.snapTs g = n ∧ s.epoch g = e then
        if ckNeeds s g a then push (persistCall s g ok .none) (.ckPut g a e)  -- 8341-8343
        else ckSession s g a e                              -- 8346 in this segment
      else s
  | .ckPut g a e => ckSession s g a e                       -- 8346: no re-check after the await
  | .ckAdd g a e =>                                         -- 8413: re-checked, 8423-8433
      if s.epoch g = e then { s with ckpt := upd s.ckpt g (some a) } else s
  | .heroGet g gb a =>                                      -- 6456-6472: the session, if it passed
      launchCall s g gb (if ok then a.map (fun a => (a, false)) else none)
  | .momGet g gb m =>                                       -- 9100-9110
      match m with
      | some a => launchCall s g gb (some (a, true))
      | none => s

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
  | .launch g gb => launchCall s g gb none
  | .resume i ok =>
      match s.pend[i]? with
      | some p => resumeP { s with pend := s.pend.eraseIdx i } p ok
      | none => s
  | .close =>                                               -- 14173-14180: the token, then
      match s.cur with
      | some g => push (autoSnap { s with loading := none }) (.unloadPre g true false)
      | none => s
  | .delete g =>                                            -- 2152-2160
      if s.cur = some g then push { s with loading := none } (.unloadPre g false true)
      else push { s with queued := upd s.queued g true } (.delSaves g)   -- 4675 queued first
  | .reset g file =>
      -- resetGameAction 2078-2081: a loaded game is detached first
      -- (detachLoadedGame 1745-1753: the token, unlink the FS .sav, null the
      -- names), in the same segment as the queue (4665) and the first delete
      -- (deleteSaveData -> deleteKeys 1700, 1706: the persistSeq number, then
      -- save:g). resetCurrentSaveFile 1725-1729: the same for the loaded game
      -- (none loaded: it returns), without the queue.
      let loaded := decide (s.cur = some g)
      if file && !loaded then s else
      let s0 := if loaded then { s with fs := none, cur := none, loading := none } else s
      let s0 := if file then s0 else { s0 with queued := upd s0.queued g true }
      push (retire { s0 with idb := upd s0.idb g none, wiped := upd s0.wiped g (some s0.clock),
                             floor := upd s0.floor g 0 } g) (.resetRest g loaded (gbOf s) file)
  | .tapResume =>
      match s.toast with
      | some (g, a) =>
        let s1 := { s with toast := none }
        if s.cur = some g then push s1 (.tapCheck g a (s.idb g)) else s1   -- 8802-8806
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
      -- 7590-7593: detached (as Reset), the persistSeq number, the put issued
      match s.cur, s.core with
      | some g, some c =>
        let b : Bytes := ⟨g, s.clock⟩
        push (raise (retire { s with fs := none, cur := none, loading := none,
                                     idb := upd s.idb g (some b), clock := s.clock + 1 } g) b)
          (.importPut g c.gb)
      | _, _ => s
  | .pullStart g =>
      if s.cur = some g ∨ s.loading = some g then s         -- 4414
      else push { s with clock := s.clock + 1 } (.pull g ⟨g, s.clock⟩)
  | .ckpt =>
      -- takeCheckpoint 8313-8331: flush, capture, read the file, the stamp
      -- and the epoch; the pack goes to the worker
      if s.paused then s else
      match s.cur, s.core with
      | some g, some c =>
        let s1 := flushCore s
        let n := s1.snapTs g + 1
        push { s1 with snapTs := upd s1.snapTs g n } (.ckStore g ⟨c, s1.fs⟩ n (s1.epoch g))
      | _, _ => s
  | .hero g gb => push s (.heroGet g gb (s.auto g))          -- resumeSessionFor 8761
  | .moment g gb => push s (.momGet g gb (s.ckpt g))         -- momentRecord 9099
  | .driveFlush g =>                                        -- runExclusive: not mid-pull
      if s.pend.any Pending.isPull then s else { s with queued := upd s.queued g false }

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
  | .evictCk g b _ _ => b.game = g
  | .evict g b _ _ => b.game = g
  | .loadRestore g _ v => ∀ b, v = some b → b.game = g
  | .offerGet _ a => ∀ a', a = some a' → WF a'.core
  | .offerCheck _ a _ => WF a.core
  | .tapCheck _ a _ => WF a.core
  | .slotGet _ v => ∀ c, v = some c → WF c
  | .pull g b => b.game = g
  | .ckStore _ a _ _ => WF a.core
  | .ckPut _ a _ => WF a.core
  | .ckAdd _ a _ => WF a.core
  | .heroGet _ _ a => ∀ a', a = some a' → WF a'.core
  | .momGet _ _ m => ∀ a', m = some a' → WF a'.core
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
  ckpt  : ∀ g a, s.ckpt g = some a → WF a.core
  boot  : ∀ g a f, s.boot g = some (a, f) → WF a.core

theorem finv_congr {s s' : St} (h : FInv s) (h1 : s'.idb = s.idb) (h2 : s'.fs = s.fs)
    (h3 : s'.cur = s.cur) (h4 : s'.core = s.core) (h5 : s'.auto = s.auto)
    (h6 : s'.slot = s.slot) (h7 : s'.toast = s.toast) (h8 : s'.pend = s.pend)
    (h9 : s'.ckpt = s.ckpt) (h10 : s'.boot = s.boot) : FInv s' := by
  constructor
  · rw [h1]; exact h.idb
  · rw [h2, h4]; exact h.fs
  · rw [h3, h4]; exact h.cur
  · rw [h4]; exact h.core
  · rw [h5]; exact h.auto
  · rw [h6]; exact h.slot
  · rw [h7]; exact h.toast
  · rw [h8]; exact h.pend
  · rw [h9]; exact h.ckpt
  · rw [h10]; exact h.boot

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
  · exact h.ckpt
  · exact h.boot

theorem raise_inv {s : St} (b : Bytes) (h : FInv s) : FInv (raise s b) :=
  finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl

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
  · exact h.ckpt
  · exact h.boot

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
  · exact h.ckpt
  · exact h.boot

theorem l3_inv {s : St} (g : Nat) (gb : Bool) (h : FInv s) : FInv (l3 s g gb) := by
  simp only [l3]
  exact push_inv (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl) (fun b hb => h.idb g b hb)

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
        · exact h.ckpt
        · exact h.boot
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
        · exact h.ckpt
        · exact h.boot
      · exact push_inv (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl) hbg

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
    · exact h1.ckpt
    · exact h1.boot
  · exact h

theorem launchCall_inv {s : St} (g : Nat) (gb : Bool) (r : Option (Snap × Bool)) (h : FInv s)
    (hr : ∀ a f, r = some (a, f) → WF a.core) : FInv (launchCall s g gb r) := by
  have h' : FInv { s with loading := none, boot := upd s.boot g r } := by
    constructor
    · exact h.idb
    · exact h.fs
    · exact h.cur
    · exact h.core
    · exact h.auto
    · exact h.slot
    · exact h.toast
    · exact h.pend
    · exact h.ckpt
    · intro g' a f ha
      simp only [upd_apply] at ha
      split at ha
      · exact hr a f ha
      · exact h.boot g' a f ha
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
      · exact h.ckpt
      · exact h.boot
    · exact h
  · exact h

theorem restamp_wf (t : Nat) (sc : Core) (h : WF sc) : WF (restamp t sc) := by
  intro r hr
  simp only [restamp, Option.map_eq_some_iff] at hr
  obtain ⟨r0, h0, rfl⟩ := hr
  exact h r0 h0

theorem l4_inv {s : St} (g : Nat) (gb : Bool) (v : Option Bytes) (h : FInv s)
    (hv : ∀ b, v = some b → b.game = g) : FInv (l4 s g gb v) := by
  have h1 : FInv { s with fs := v, cur := some g, paused := false,
                          core := some ⟨g, gb, v, false⟩, loading := none,
                          lastSig := v.map (fun b => (g, b)) } := by
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
    · exact h.ckpt
    · exact h.boot
  simp only [l4]
  split
  · exact offerStart_inv h1
  · rename_i a hb
    split
    · exact applyState_inv _ (finv_congr h1 rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
        (h.boot g a false hb)
    · exact h1
  · rename_i a hb
    exact applyState_inv _ (finv_congr h1 rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
      (restamp_wf _ _ (h.boot g a true hb))

theorem mem_eraseIdx_or {α : Type} {l : List α} {i : Nat} {p q : α}
    (hi : l[i]? = some p) (hq : q ∈ l) : q ∈ l.eraseIdx i ∨ q = p := by
  obtain ⟨j, hj⟩ := List.mem_iff_getElem?.mp hq
  by_cases hji : j = i
  · subst hji; rw [hi] at hj; cases hj; exact Or.inr rfl
  · exact Or.inl (List.mem_eraseIdx_iff_getElem?.mpr ⟨j, hji, hj⟩)

/-- A put of game `g`'s own bytes under `save:<g>`. -/
theorem finv_put {s : St} (h : FInv s) (g : Nat) (b : Bytes) (hb : b.game = g)
    (w : List (Nat × Bytes)) : FInv { s with idb := upd s.idb g (some b), writes := w } := by
  constructor
  · intro g' b' hb'
    simp only [upd_apply] at hb'
    split at hb'
    · rename_i hgg; cases hb'; rw [hgg]; exact hb
    · exact h.idb g' b' hb'
  · exact h.fs
  · exact h.cur
  · exact h.core
  · exact h.auto
  · exact h.slot
  · exact h.toast
  · exact h.pend
  · exact h.ckpt
  · exact h.boot

/-- A snapshot of game `g`'s core under `stateauto:<g>`. -/
theorem finv_auto {s : St} (h : FInv s) (g : Nat) (a : Snap) (ha : WF a.core) :
    FInv { s with auto := upd s.auto g (some a) } := by
  constructor
  · exact h.idb
  · exact h.fs
  · exact h.cur
  · exact h.core
  · intro g' a' ha'
    simp only [upd_apply] at ha'
    split at ha'
    · cases ha'; exact ha
    · exact h.auto g' a' ha'
  · exact h.slot
  · exact h.toast
  · exact h.pend
  · exact h.ckpt
  · exact h.boot

/-- The slots (or not), the session and the checkpoints of `g` deleted. -/
theorem finv_drop {s : St} (h : FInv s) (g : Nat) (sl : Nat → Option Core)
    (hsl : ∀ g c, sl g = some c → WF c) (ep : Nat → Nat) (q : Nat → Bool) (d : List Nat) :
    FInv { s with slot := sl, auto := upd s.auto g none, epoch := ep,
                  ckpt := upd s.ckpt g none, queued := q, deletes := d } := by
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
  · exact hsl
  · exact h.toast
  · exact h.pend
  · intro g' a ha
    simp only [upd_apply] at ha
    split at ha
    · cases ha
    · exact h.ckpt g' a ha
  · exact h.boot

theorem ckSession_inv {s : St} (g : Nat) (a : Snap) (e : Nat) (h : FInv s) (ha : WF a.core) :
    FInv (ckSession s g a e) :=
  push_inv (p := .ckAdd g a e) (finv_auto h g a ha) ha

theorem resumeP_inv {s : St} (p : Pending) (ok : Bool) (h : FInv s) (hp : POK p) :
    FInv (resumeP s p ok) := by
  cases p with
  | persist g b k => exact finish_inv k (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
  | evictCk g b k t =>
    simp only [resumeP]
    split
    · exact push_inv (raise_inv b (finv_put h g b hp _)) (show POK (.persist g b k) from hp)
    · exact push_inv h (show POK (.evict g b k t) from hp)
  | evict g b k t =>
    simp only [resumeP]
    split
    · split
      · exact finish_inv k h
      exact push_inv (raise_inv b (finv_put h g b hp _)) (show POK (.persist g b k) from hp)
    · exact finish_inv k (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
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
      · exact h.ckpt
      · exact h.boot
    · exact h
  | tapCheck g a v =>
    simp only [resumeP]
    split
    · have h1 := flushCore_inv h
      split
      · exact applyState_inv _ (finv_congr h1 rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl) hp
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
        · exact push_inv (p := .delSaves g)
            (finv_congr h2 rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl) trivial
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
    · exact h.ckpt
    · exact h.boot
  | delRest g =>
    simp only [resumeP]
    refine finv_drop h g _ (fun g' c hc => ?_) _ _ _
    simp only [upd_apply] at hc
    split at hc
    · cases hc
    · exact h.slot g' c hc
  | resetRest g loaded gb file =>
    simp only [resumeP]
    have h1 := finv_drop h g (if file then s.slot else upd s.slot g none)
      (fun g' c hc => by
        split at hc
        · exact h.slot g' c hc
        · simp only [upd_apply] at hc
          split at hc
          · cases hc
          · exact h.slot g' c hc)
      (upd s.epoch g (s.epoch g + 1)) (if file then upd s.queued g true else s.queued)
      (s.deletes ++ [g])
    split
    · exact launchCall_inv g gb none h1 (fun _ _ hr => by cases hr)
    · exact h1
  | slotGet g v =>
    simp only [resumeP]
    split
    · rename_i sc
      exact applyState_inv _ (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
        (restamp_wf _ _ (hp sc rfl))
    · exact h
  | importPut g gb =>
    exact launchCall_inv _ _ none h (fun _ _ hr => by cases hr)
  | pull g b =>
    simp only [resumeP]
    split
    · exact h
    exact raise_inv b (finv_put h g b hp _)
  | ckStore g a n e =>
    simp only [resumeP]
    split
    · split
      · have hfs : ∀ b, s.fs = some b → b.game = g := by
          intro b hb
          rename_i hn
          simp only [ckNeeds, Bool.and_eq_true, decide_eq_true_eq] at hn
          exact fs_of_cur h hn.1 b hb
        exact push_inv (persistCall_inv g ok .none h hfs) (show POK (.ckPut g a e) from hp)
      · exact ckSession_inv g a e h hp
    · exact h
  | ckPut g a e => exact ckSession_inv g a e h hp
  | ckAdd g a e =>
    simp only [resumeP]
    split
    · constructor
      · exact h.idb
      · exact h.fs
      · exact h.cur
      · exact h.core
      · exact h.auto
      · exact h.slot
      · exact h.toast
      · exact h.pend
      · intro g' a' ha'
        simp only [upd_apply] at ha'
        split at ha'
        · cases ha'; exact hp
        · exact h.ckpt g' a' ha'
      · exact h.boot
    · exact h
  | heroGet g gb a =>
    simp only [resumeP]
    apply launchCall_inv g gb _ h
    intro a' f hr
    split at hr
    · cases a with
      | none => cases hr
      | some a0 =>
        simp only [Option.map_some, Option.some.injEq, Prod.mk.injEq] at hr
        obtain ⟨rfl, _⟩ := hr
        exact hp a0 rfl
    · cases hr
  | momGet g gb m =>
    cases m with
    | none => exact h
    | some a0 =>
      simp only [resumeP]
      apply launchCall_inv g gb _ h
      intro a' f hr
      simp only [Option.some.injEq, Prod.mk.injEq] at hr
      obtain ⟨rfl, _⟩ := hr
      exact hp a0 rfl

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
        · exact h.ckpt
        · exact h.boot
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
            · exact h.ckpt
            · exact h.boot
          · exact h
        · exact h
      · exact h
  | pause => exact finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  | unpause =>
    simp only [step]
    split
    · exact finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
    · exact h
  | tick ok =>
    simp only [step]
    split
    · rename_i g hg
      exact persistCall_inv g ok _ h (fs_of_cur h hg)
    · exact h
  | hide => exact autoSnap_inv h
  | launch g gb => exact launchCall_inv g gb none h (fun _ _ hr => by cases hr)
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
      · exact h.ckpt
      · exact h.boot
    · exact h
  | close =>
    simp only [step]
    split
    · exact push_inv (autoSnap_inv (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)) trivial
    · exact h
  | delete g =>
    simp only [step]
    split
    · exact push_inv (p := .unloadPre g false true) (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl) trivial
    · exact push_inv (p := .delSaves g) (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl) trivial
  | reset g file =>
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
        · exact h.ckpt
        · exact h.boot
      · exact h
    split
    · exact h
    generalize (if decide (s.cur = some g) = true then { s with fs := none, cur := none, loading := none }
                else s) = s0 at h0 ⊢
    have h1 : FInv (if file = true then s0 else { s0 with queued := upd s0.queued g true }) := by
      split
      · exact h0
      · exact finv_congr h0 rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
    generalize (if file = true then s0 else { s0 with queued := upd s0.queued g true }) = s1 at h1 ⊢
    refine push_inv ?_ trivial
    simp only [retire]
    constructor
    · intro g' b' hb'
      simp only [upd_apply] at hb'
      split at hb'
      · cases hb'
      · exact h1.idb g' b' hb'
    · exact h1.fs
    · exact h1.cur
    · exact h1.core
    · exact h1.auto
    · exact h1.slot
    · exact h1.toast
    · exact h1.pend
    · exact h1.ckpt
    · exact h1.boot
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
        · exact h.ckpt
        · exact h.boot
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
      · exact h.ckpt
      · exact h.boot
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
      · exact h.ckpt
      · exact h.boot
    · exact h
  | pullStart g =>
    simp only [step]
    split
    · exact h
    · exact push_inv (finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl) (show (⟨g, s.clock⟩ : Bytes).game = g from rfl)
  | ckpt =>
    simp only [step]
    split
    · exact h
    · split
      · rename_i g c hg hc
        have h1 := flushCore_inv h
        refine push_inv (finv_congr h1 rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl) ?_
        exact h.core c hc
      · exact h
  | hero g gb => exact push_inv h (fun a ha => h.auto g a ha)
  | moment g gb => exact push_inv h (fun a ha => h.ckpt g a ha)
  | driveFlush g =>
    simp only [step]
    split
    · exact h
    · exact finv_congr h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl

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

theorem ginv_launchCall {s : St} (g : Nat) (gb : Bool) (r : Option (Snap × Bool)) (h : GInv s) :
    GInv (launchCall s g gb r) := by
  have h' : GInv { s with loading := none, boot := upd s.boot g r } :=
    ginv_congr h rfl rfl rfl (fun _ hq => hq)
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

theorem ginv_applyState {s : St} (sc : Core) (h : GInv s) : GInv (applyState s sc) := by
  unfold applyState
  split
  · split
    · exact ginv_congr h rfl rfl rfl (fun _ hq => hq)
    · exact h
  · exact h

theorem ginv_l4 {s : St} (g : Nat) (gb : Bool) (v : Option Bytes) (h : GInv s) :
    GInv (l4 s g gb v) := by
  have h1 : GInv { s with fs := v, cur := some g, paused := false,
                          core := some ⟨g, gb, v, false⟩, loading := none,
                          lastSig := v.map (fun b => (g, b)) } :=
    ginv_congr h rfl rfl rfl (fun _ hq => hq)
  simp only [l4]
  split
  · exact ginv_offerStart h1
  · split
    · rename_i a _ hsig
      apply ginv_applyState
      constructor
      · intro x hx
        rw [List.mem_append, List.mem_singleton] at hx
        rcases hx with hx | rfl
        · exact h1.guard x hx
        · exact hsig
      · exact h1.upload
    · exact h1
  · exact ginv_applyState _ (ginv_congr h1 rfl rfl rfl (fun _ hq => hq))

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
      | exact ginv_launchCall _ _ _ h
      | exact ginv_push _ (ginv_persistCall _ ok _ h)
      | exact ginv_applyState _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_write _ _ _ h _ rfl rfl rfl rfl
      | exact ginv_push _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_congr h rfl rfl rfl (fun _ hq => hq)
      | exact ginv_l3 _ _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
      | exact ginv_launchCall _ _ _ (ginv_congr h rfl rfl rfl (fun _ hq => hq))
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
  | launch g gb => exact ginv_launchCall g gb none h
  | hide => exact ginv_autoSnap h
  | ckpt =>
    simp only [step]
    split
    · exact h
    · split
      · exact ginv_push _ (ginv_congr (ginv_flushCore h) rfl rfl rfl (fun _ hq => hq))
      · exact h
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
   reset 0 false,                                     -- detached; save:0 deleted (clock 3)
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
    QuotaExceededError; no other game has a checkpoint to give up, so
    dbPutRoomy awaits evictOldestRom; a newer save is persisted meanwhile; the
    eviction completes. At dd7ba741f the OLD bytes were then put again, over
    the newer ones (and uploaded); the retry now sees the later persist's
    number and gives way. (When a checkpoint is what gave way, it does not:
    `bug_ckpt_evict_retry_writes_older_save`.) -/
def trQuotaPre : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,
   play, frame, tick false,                           -- v1: put rejected (quota) -> evict
   play, frame, tick true, resume 1 true]             -- v2 persisted
open Ev in
def trQuotaPost : List Ev :=
  [resume 0 false,                                    -- no checkpoint freed: a ROM next
   resume 0 true]                                     -- eviction done: gives way

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

A persist waiting on a ROM eviction re-puts its bytes unless a later number
has been taken for the save (`persistSeq`). A delete of the save (Reset,
Delete) and an import take one. In each trace below no other game has a
checkpoint, so the first eviction frees nothing (`resume 0 false`) and the
ROM eviction is the one that waits. -/

open Ev in
/-- A persist of game 0's save is waiting on a quota eviction when the player
    resets game 0. The Reset took no number before, so the retry found itself
    the latest and put the wiped save back (`NoResurrect` failed); now it gives
    way. -/
def trQuotaReset : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true, play, frame, tick false,  -- v1: quota
   reset 0 false,                                     -- save:0 deleted, a number taken
   resume 0 false,                                    -- no checkpoint freed: a ROM next
   resume 1 true]                                     -- eviction done: gives way

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
                       delete 0, resume 1 true, resume 1 true, resume 0 false, resume 1 true]
    Reachable s ∧ s.idb 0 = none ∧ s.wiped 0 = some 2 :=
  ⟨run_reachable _ _ .init, by decide, by decide⟩

open Ev in
/-- ...and with an import: the import stands. -/
theorem regress_quota_retry_over_import :
    let s := run init [launch 0 false, resume 0 true, resume 0 true, play, frame, tick false,
                       importSave, resume 0 false, resume 1 true]
    Reachable s ∧ s.idb 0 = some ⟨0, 2⟩ :=
  ⟨run_reachable _ _ .init, by decide⟩

/-! ## A quota retry after a checkpoint gave way (03f88d6c)

dbPutRoomy now gives up other games' checkpoints before any ROM (6181-6184),
and puts again straight after (`continue`). Its `superseded()` check (6171)
is asked only `if (freed && ...)`, and `freed` counts ROMs: the retry after
a checkpoint eviction puts the old bytes back unasked. Every trace that the
ROM path now survives, the checkpoint path still fails. A device is only
near full when it has been playing for a while, so other games' checkpoints
are there to give way. -/

open Ev in
/-- As `regress_quota_retry_writes_older_save`, but the eviction that the
    first put waits on frees another game's checkpoints: the older save goes
    back over the newer one in `save:0`, and is queued for Drive after it. -/
theorem bug_ckpt_evict_retry_writes_older_save :
    let s := run init (trQuotaPre ++ [resume 0 true, resume 0 true])
    Reachable s ∧ s.idb 0 = some ⟨0, 1⟩ ∧ s.fs = some ⟨0, 2⟩ ∧
      s.uploads = [(0, ⟨0, 2⟩), (0, ⟨0, 1⟩)] :=
  ⟨run_reachable _ _ .init, by decide, by decide, by decide⟩

open Ev in
/-- A Reset while the first put waits on the checkpoint eviction: the retry
    puts the wiped save back, and the Reset's reboot boots the game on it.
    The reset is undone. -/
def trCkReset : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true, play, frame, tick false,  -- v1: quota
   reset 0 false,                                     -- detached, save:0 deleted
   resume 0 true,                                     -- a checkpoint freed: v1 put again
   resume 0 true,                                     -- the rest of the deletes; the reboot
   resume 1 true]                                     -- the boot reads save:0

theorem bug_ckpt_evict_retry_undoes_reset :
    let s := run init trCkReset
    Reachable s ∧ s.idb 0 = some ⟨0, 1⟩ ∧ s.wiped 0 = some 2 ∧
      s.core = some ⟨0, false, some ⟨0, 1⟩, false⟩ ∧ ¬ NoResurrect s := by
  refine ⟨run_reachable _ _ .init, by decide, by decide, by decide, fun h => ?_⟩
  have := h 0 ⟨0, 1⟩ 2 (by decide) (by decide)
  exact absurd this (by decide)

open Ev in
/-- The same with Delete: the deleted game's save is back in IndexedDB (and
    queued for Drive by the retry's `markUpload`). -/
theorem bug_ckpt_evict_retry_resurrects_deleted_save :
    let s := run init [launch 0 false, resume 0 true, resume 0 true, play, frame, tick false,
                       delete 0, resume 1 true, resume 1 true, resume 0 true, resume 1 true]
    Reachable s ∧ s.idb 0 = some ⟨0, 1⟩ ∧ s.wiped 0 = some 2 ∧ (0, ⟨0, 1⟩) ∈ s.uploads ∧
      ¬ NoResurrect s := by
  refine ⟨run_reachable _ _ .init, by decide, by decide, by decide, fun h => ?_⟩
  have := h 0 ⟨0, 1⟩ 2 (by decide) (by decide)
  exact absurd this (by decide)

open Ev in
/-- ...and with an import: the replaced save goes back over the imported
    one, and the import's reboot boots on it. -/
theorem bug_ckpt_evict_retry_over_import :
    let s := run init [launch 0 false, resume 0 true, resume 0 true, play, frame, tick false,
                       importSave, resume 0 true, resume 0 true, resume 1 true]
    Reachable s ∧ s.idb 0 = some ⟨0, 1⟩ ∧ s.core = some ⟨0, false, some ⟨0, 1⟩, false⟩ :=
  ⟨run_reachable _ _ .init, by decide, by decide⟩

/-! ## A checkpoint's session after its battery's persist (03f88d6c)

storeCheckpoint checks that no newer snapshot was taken and the session was
not deleted (8337), then, when the battery it carries is not stored yet,
`await persistSave(...)` (8343), and only then puts the session (8346),
without asking again. addCheckpoint re-checks the epoch after its own await
(8413); the session put does not. Main Menu, a hide, a close, a switch, a
Reset or a Delete in that await is overwritten by, or undone by, the older
moment. The battery is unstored whenever the game saved in the last 5 s (the
autosave's period), so the await is there at most checkpoints that follow
an in-game save. -/

open Ev in
/-- A checkpoint is taken a few seconds after an in-game save; its persist is
    in flight when the player goes to Main Menu (`hide`: persistAutoState
    takes the newer session, v2). The checkpoint's session (v1) then lands
    over it: the session left at Main Menu is gone, here and, once queued,
    on Drive. -/
def trCkOverNewer : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,
   play, frame,                                       -- in-game save v1, not yet persisted
   ckpt,                                              -- takeCheckpoint: the session at v1
   resume 0 true,                                     -- storeCheckpoint: v1 unstored: persist
   play, frame,                                       -- the game moves on (v2)
   hide,                                              -- Main Menu / hide: the session at v2
   resume 1 true]                                     -- the persist resolves: v1's session put

theorem bug_ckpt_store_over_newer_session :
    ((run init (trCkOverNewer.take 10)).auto 0).map Snap.saveSig = some (some ⟨0, 2⟩) ∧
    let s := run init trCkOverNewer
    Reachable s ∧ (s.auto 0).map Snap.saveSig = some (some ⟨0, 1⟩) ∧ s.snapTs 0 = 2 :=
  ⟨by decide, run_reachable _ _ .init, by decide, by decide⟩

open Ev in
/-- The same await against a Reset: the Reset deletes the session (and bumps
    its epoch), and the checkpoint's put brings back the session from before
    it, carrying the wiped battery's signature (addCheckpoint's own re-check
    keeps the moment out). -/
def trCkReset2 : List Ev :=
  [launch 0 false, resume 0 true, resume 0 true,
   play, frame, ckpt, resume 0 true,                  -- the checkpoint's persist in flight
   reset 0 false,                                     -- detached, save:0 deleted
   resume 2 true,                                     -- the session and checkpoints deleted; reboot
   resume 1 true,                                     -- the session put: the pre-reset one
   resume 2 true]                                     -- addCheckpoint: epoch moved, refused

theorem bug_ckpt_store_undoes_session_reset :
    let s := run init trCkReset2
    Reachable s ∧ 0 ∈ s.deletes ∧ s.epoch 0 = 1 ∧
      (s.auto 0).map Snap.saveSig = some (some ⟨0, 1⟩) ∧ s.ckpt 0 = none :=
  ⟨run_reachable _ _ .init, by decide, by decide, by decide, by decide⟩

/-- Taken and stored with nothing in between, a checkpoint's session and
    moment land (the common case). -/
theorem ckpt_stores_session_and_moment :
    let s := run init [.launch 0 false, .resume 0 true, .resume 0 true, .play, .frame,
                       .tick true, .resume 0 true, .ckpt, .resume 0 true, .resume 0 true]
    Reachable s ∧ (s.auto 0).map Snap.saveSig = some (some ⟨0, 1⟩) ∧
      (s.ckpt 0).map Snap.saveSig = some (some ⟨0, 1⟩) :=
  ⟨run_reachable _ _ .init, by decide, by decide⟩

/-! ## The Drive pull against a Reset or a Delete

The pull's per-save write issues its put after an await. It re-checks that
the game is not loaded or loading (4442) and, since 6dd57564, that no delete
of the save is queued for Drive (4449): `resetGameSaves` and
`deleteGameEverywhere` queue theirs before they wipe. -/

open Ev in
/-- A Drive pull is downloading game 1's save when the player resets game 1
    (not loaded, so nothing to detach); the download lands. Before 6dd57564
    it wrote the old save back (the Drive deletes that Reset queued then
    removed Drive's copy, and the next sync's reconcile uploaded the
    resurrected local one). Now the write sees the queued delete and skips. -/
theorem regress_pull_resurrects_reset_save :
    let s := run init [pullStart 1, reset 1 false, resume 0 true, resume 0 true]
    Reachable s ∧ s.idb 1 = none ∧ s.wiped 1 = some 2 ∧ NoResurrect s := by
  have hw : (run init [pullStart 1, reset 1 false, resume 0 true, resume 0 true]).wiped =
      upd (fun _ => none) 1 (some 2) := rfl
  have hi : (run init [pullStart 1, reset 1 false, resume 0 true, resume 0 true]).idb 1 = none := by
    decide
  refine ⟨run_reachable _ _ .init, hi, by rw [hw]; rfl, ?_⟩
  intro g b t hb ht
  rw [hw, upd_apply] at ht
  split at ht
  · subst_vars; rw [hi] at hb; cases hb
  · cases ht

open Ev in
/-- The Saves panel's Reset (`resetCurrentSaveFile`) queues its Drive deletes
    only after its awaits (1733-1735), and the game is detached during them:
    a pull that started before the game was loaded, and whose download lands
    in that window, passes all three checks and writes the save back; the
    Reset's reboot then boots the game on it. -/
def trFileResetPull : List Ev :=
  [pullStart 0,                                       -- a pull is downloading save:0
   launch 0 false, resume 1 true, resume 1 true,      -- the player taps game 0: it boots
   reset 0 true,                                      -- Saves panel: Reset (detached, deleted)
   resume 0 true,                                     -- the download lands: written
   resume 0 true,                                     -- the deletes; queued now; the reboot
   resume 0 true]                                     -- the boot reads save:0

theorem bug_file_reset_undone_by_pull :
    let s := run init trFileResetPull
    Reachable s ∧ s.wiped 0 = some 2 ∧ s.idb 0 = some ⟨0, 1⟩ ∧
      s.core = some ⟨0, false, some ⟨0, 1⟩, false⟩ ∧ ¬ NoResurrect s := by
  refine ⟨run_reachable _ _ .init, by decide, by decide, by decide, fun h => ?_⟩
  have := h 0 ⟨0, 1⟩ 2 (by decide) (by decide)
  exact absurd this (by decide)

open Ev in
/-- The game menu's Reset (`resetGameAction`) on the same trace: its queue
    goes in with the detach, the download is skipped, and the game starts
    fresh. -/
theorem reset_game_action_holds_off_pull :
    let s := run init [pullStart 0, launch 0 false, resume 1 true, resume 1 true,
                       reset 0 false, resume 0 true, resume 0 true, resume 0 true]
    Reachable s ∧ s.idb 0 = none ∧ s.core = some ⟨0, false, none, false⟩ :=
  ⟨run_reachable _ _ .init, by decide, by decide⟩

end WebState.SavePersistence
