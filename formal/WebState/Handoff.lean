-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/index.js: autoStateMatchesSave flushSyncInner handoffNews heldGameIsSent launchRom liveSaveSig loadRom markUpload persistAutoState persistSave pullSyncInner refreshHero renderClosedHero resumeGame resumeSessionFor runFullSync sessionBundle sessionFromBundle showMainMenu storeLastFrame switchToHandoff takeHandoff unloadGame on:visibilitychange

/-
# Picking a game up on another device (web/index.js)

Model of the cross-device hand-off as shipped in 43b30d1c (main 11025707),
and of the fixes this model led to (`Code.fixed`). Two devices share one game
and one Google Drive appDataFolder. What travels for the game is three Drive
files:

* `save:<game>`, the in-game battery save;
* `stateauto:<game>`, the session: the Resume snapshot, its `saveSig` (the
  battery it was taken with), the device that took it, and its picture, all
  in one file (`sessionBundle` / `sessionFromBundle`);
* `frame:<game>`, the library tile's picture (`storeLastFrame`).

The code modelled, by function:

* the game's life on one device: `launchRom` + `loadRom` (a tap on the tile
  or the hero: back into the session where `resumeSessionFor` offers one,
  else boot from the save), the RAF tick (`sessionMoved`), the in-game save
  (the core writes its FS .sav) and the 5 s `persistSave`, `showMainMenu`,
  `resumeGame`, the hero's Close (`unloadGame`), `pagehide` /
  `visibilitychange` (hidden), and a page killed and opened again;
* `persistAutoState` with its `sessionMoved` / `sessionSnapFor` gate,
  `persistSave` with `lastSaveSig`, `storeLastFrame` with `lastFrameSig`,
  `markUpload` with `syncRemarked`;
* the sync engine, one segment per event between awaits that matter:
  `runFullSync` (Sync now), `flushSyncInner` (the listing, then per queued
  file: read + the session hold-back + start the upload; then the upload
  lands), `pullSyncInner` (the listing, `handoffNews`, the decision after
  `heldGameIsSent`'s read, `takeHandoff` or the Switch offer with its
  `handoffStash`, then the files pass), and `switchToHandoff`;
* what the home screen shows for the game: the paused hero (the screen in
  memory), the closed hero (`renderClosedHero`: the session's picture where
  the session is resumable, else the library picture, cached by
  `heroDrawnFor`), or, on a visit where no game has been played yet, the
  tile (the library picture).

## Abstractions (and why they do not affect the stated properties)

* One game; both devices hold its ROM. Library merges, tombstones, renames,
  generations and ROM bytes are `DriveLibrary`'s; sign-in and the token are
  `DriveSession`'s. Here the account is signed in throughout.
* Bytes are opaque: a battery is a `Nat` (0 = no save), a moment of play is
  a `Nat` (0 = the boot screen, where a game booted from its save starts),
  and a session is `{ m, sig, dev }`. Content signatures are the contents
  themselves, so `sigOfBytes` equality is equality. Whether the bytes are
  compressed on the way is invisible at this level.
* A session's picture is the picture of its moment and always rides with it.
  (`persistAutoState` writes the picture after the record and queues the
  file again when it lands; a session sent in between goes up without a
  picture and is sent again with it, which ends in the same Drive file.)
* `clock` gives every fresh moment, battery and Drive modifiedTime.
* Drive has no compare-and-swap (`driveUploadFile` sends no precondition),
  modelled as is: an upload writes whatever Drive holds.
* A pull reads a file's bytes at the listing; Drive serving newer bytes to
  the later download only means the next pull fetches the file once more.
* The sync state (`gdrive_sync`: the queue, `sigs`, `rmt`) survives a page
  reload as it stood; `saveSyncState` writes it at every change that matters
  here. In-memory state (`syncRemarked`, `handoffForce`, `handoffStash`,
  the game in memory, a flush or pull in flight) does not.
* A load is one event: `launchRom`'s awaits race pulls through
  `loadingName`, which `DriveLibrary` and `GameLifecycle` model.
* The Sync button is on the home screen, so Sync now is not taken while
  the game runs. A sync asked for while a job runs is queued behind it
  (`runExclusive`) as one flush-then-pull (`chained`); a pull asked for
  behind a job collapses into it the same way (`pullQueued`), which here
  adds a flush before it - a flush with nothing queued sends nothing.
* The toast's Switch is offered once per newer copy (`handoffOffered`); it is
  the `switch` event, available while the stash is held, and timing it out is
  not tapping it.

## Results

* Matt's fourteen steps (`fourteen_steps`): for each of the four ways the
  second device opens, saving in game or not, device 2 shows device 1's
  picture, resumes device 1's moment on device 1's save, and device 1 then
  shows and resumes device 2's. The shipped code keeps them too
  (`fourteen_steps_shipped`): the story has no race in it.
* Safety, over every state and event:
  - `tap_never_rolls_back_save`, `tap_resumes`: a tap runs the core on the
    save stored now, going back into the session only where it was taken
    with that save, so no snapshot ever puts an older battery back;
  - `flush_holds_back_unseen_session`, `session_upload_was_approved`,
    `drive_session_written_only_by_upload`: Drive's session changes only
    when an upload lands, and an upload starts only from a flush's read of
    these bytes whose listing showed no copy this device had not seen
    (unless Switch waived it);
  - `pull_unloads_only_a_sent_game` (fixed code): besides Close, Switch and
    the page going, the game in memory is let go only by a pull, and only
    at home, unmoved, with nothing of its save or session waiting to go up
    and its battery the stored save - so a hand-off never discards play;
  - `handed_off_when_sent` + `take_lands` (fixed code): such a game is
    always handed over, every downloaded file landing as downloaded;
  - `pull_redraws_hero`: a pull that lands a file redraws the closed hero
    from what is stored now.
* Convergence (`converges_a_b_a`, `converges_b_a_b`): from each of the 686
  histories of three moves (sync stopped mid-pull, play, play and save,
  Close, Sync, page killed and reopened, Switch; alternating devices),
  syncing each device in turn leaves both resuming the same moment on the
  same save as Drive's copy, each hero showing where its tap goes.
* The shipped code's counterexamples (each reproduced against the real
  web/index.js by a test in web/tests/handoff.test.mjs, failing before the
  fix): `bug_switch_during_upload`, `bug_close_during_handoff`,
  `bug_resume_during_handoff`; the same traces end safely in the fixed code
  (`regress_*`).
* Open by design, when two devices played without syncing in between:
  `edge_concurrent_play_held_wins`, `edge_closed_copy_yields`,
  `edge_listing_race`.

## The fixes (`Code.fixed`)

* `switchToHandoff` re-marks what it re-queues (`syncRemarked`): a flush
  sending this device's own copy when Switch is tapped no longer takes the
  chosen copy off the queue as it lands.
* `pullSyncInner`'s hand-off section acts only on a game still held by the
  player's leave (`stillHeld`: not closed or closing since the section
  began, `loadGen` unmoved unless the game runs); a game closed during the
  downloads is left to the files pass, as any closed game.
* `heldGameIsSent` asks after its read, and the caller checks `running` and
  `loadGen` again in the run that takes the hand-off.
-/

namespace WebState.Handoff

/-! ## Values -/

inductive Dev | a | b
  deriving DecidableEq, Repr

inductive Key | save | sess | frame
  deriving DecidableEq, Repr

/-- One value per Drive file of the game. -/
structure KMap (α : Type) where
  save : α
  sess : α
  frame : α
  deriving DecidableEq, Repr

namespace KMap
def get {α : Type} (m : KMap α) : Key → α
  | .save => m.save
  | .sess => m.sess
  | .frame => m.frame
def set {α : Type} (m : KMap α) (k : Key) (v : α) : KMap α :=
  match k with
  | .save => { m with save := v }
  | .sess => { m with sess := v }
  | .frame => { m with frame := v }
def all {α : Type} (v : α) : KMap α := ⟨v, v, v⟩
end KMap

/-- A session (`stateauto:<game>`): the moment, `saveSig` (0 = taken with no
save, which counts: `sessionBundle` keeps `null`), and `by`/`dev`. -/
structure Sess where
  m : Nat
  sig : Nat
  dev : Dev
  deriving DecidableEq, Repr

/-- A Drive file's bytes. -/
inductive Blob
  | save (v : Nat)
  | sess (s : Sess)
  | frame (m : Nat)
  deriving DecidableEq, Repr

/-- One entry of `handoffNews`: a file, the newer bytes, Drive's modifiedTime. -/
structure News where
  k : Key
  b : Blob
  mt : Nat
  deriving DecidableEq, Repr

abbrev Listing := KMap (Option (Blob × Nat))

/-- Where the game is on the device: not loaded (the closed hero or the
tile), held paused at the Main Menu (`body.paused`), or running. -/
inductive Mode | closed | home | running
  deriving DecidableEq, Repr

/-- The sync engine of one device (`runExclusive` runs one job at a time). -/
inductive Eng
  | idle
  /-- A flush asked for (`flushSync`); `thenPull` when a pull follows it. -/
  | flushReady (thenPull : Bool)
  /-- `flushSyncInner` after `driveListMap`: the keys still to go through. -/
  | flushing (list : Listing) (todo : List Key) (thenPull : Bool)
  /-- An upload on the wire (`driveUploadFile`). -/
  | sending (list : Listing) (todo : List Key) (thenPull : Bool) (k : Key) (b : Blob)
  | pullReady
  /-- `pullSyncInner` after `driveListMap`, at the hand-off section. -/
  | pullHand (list : Listing)
  /-- `handoffNews` has downloaded; `g0` is `loadGen` as the section began. -/
  | pullNews (list : Listing) (news : List News) (g0 : Nat)
  /-- `heldGameIsSent` awaiting its `dbGet`; `sent1` is what it checked first. -/
  | pullCheck (list : Listing) (news : List News) (sent1 : Bool) (g0 : Nat)
  /-- The files pass. -/
  | pullFiles (list : Listing)
  deriving Repr

/-- Which code: as shipped in 43b30d1c, or with this model's fixes. -/
inductive Code | shipped | fixed
  deriving DecidableEq, Repr

/-- One device. -/
structure Dv where
  mode : Mode := .closed
  /-- The core's moment (meaningful while the game is loaded). -/
  moment : Nat := 0
  /-- The battery in the core's FS .sav (`liveSaveSig`); 0 = none. -/
  battery : Nat := 0
  /-- `sessionMoved`. -/
  moved : Bool := true
  /-- `sessionSnapFor === game`. -/
  snapped : Bool := false
  /-- `lastSaveSig` (0 = null). -/
  lastSave : Nat := 0
  /-- `lastFrameSig`. -/
  lastFrame : Option Nat := none
  /-- `loadGen`. -/
  gen : Nat := 0
  /-- IndexedDB: `save:`, `stateauto:` (+ `sessionpic:`), `frame:`. -/
  files : KMap (Option Blob) := KMap.all none
  /-- `syncState.queueUp`. -/
  queued : KMap Bool := KMap.all false
  /-- `syncRemarked`. -/
  remarked : KMap Bool := KMap.all false
  /-- `syncState.sigs`. -/
  sigs : KMap (Option Blob) := KMap.all none
  /-- `syncState.rmt` (0 = none). -/
  rmt : KMap Nat := KMap.all 0
  /-- `handoffForce` holds the session key. -/
  force : Bool := false
  /-- `handoffStash` (its news). -/
  stash : List News := []
  /-- The Switch toast was put up. -/
  offered : Bool := false
  /-- `playedThisVisit`: the hero is up (else the library opens on its tiles). -/
  heroUp : Bool := false
  /-- The closed hero's picture (a moment) and `heroDrawnFor === game`. -/
  drawn : Nat := 0
  drawnFor : Bool := false
  eng : Eng := .idle
  /-- A flush and a pull queued behind the running job (`runExclusive`). -/
  chained : Bool := false
  deriving Repr

structure S where
  a : Dv := {}
  b : Dv := {}
  drv : Listing := KMap.all none
  clock : Nat := 0
  deriving Repr

def init : S := {}

def S.dev (s : S) : Dev → Dv
  | .a => s.a
  | .b => s.b
def S.setDev (s : S) (d : Dev) (v : Dv) : S :=
  match d with
  | .a => { s with a := v }
  | .b => { s with b := v }

/-! ## What the device holds and shows -/

def saveVal : Option Blob → Nat
  | some (.save v) => v
  | _ => 0
def sessOf : Option Blob → Option Sess
  | some (.sess x) => some x
  | _ => none
def frameOf : Option Blob → Nat
  | some (.frame m) => m
  | _ => 0

/-- `resumeSessionFor` / `autoStateMatchesSave`: the session, while the save
stored now is the one it was taken with. -/
def resumable (v : Dv) : Option Sess :=
  match sessOf (v.files.get .sess) with
  | some x => if x.sig = saveVal (v.files.get .save) then some x else none
  | none => none

/-- The closed hero's picture as `renderClosedHero` draws it fresh: the
session's where it can be resumed, else the library picture. -/
def heroPic (v : Dv) : Nat :=
  match resumable v with
  | some x => x.m
  | none => frameOf (v.files.get .frame)

/-- What the home screen shows for the game: the paused screen, the closed
hero (as last drawn), or the tile's library picture. -/
def shown (v : Dv) : Nat :=
  if v.mode ≠ .closed then v.moment
  else if v.heroUp then v.drawn
  else frameOf (v.files.get .frame)

/-- Where a tap on the game goes: the game in memory, else the session's
moment where it is resumable, else the boot (0). -/
def resumePoint (v : Dv) : Nat :=
  if v.mode ≠ .closed then v.moment
  else match resumable v with
    | some x => x.m
    | none => 0

/-! ## The device's own writes -/

/-- `markUpload`: queued, or re-marked when already queued. -/
def mark (v : Dv) (k : Key) : Dv :=
  if v.queued.get k then { v with remarked := v.remarked.set k true }
  else { v with queued := v.queued.set k true }

/-- `persistAutoState` (the snapshot is skipped when the game has not moved
since the last one). -/
def persistAutoState (v : Dv) (d : Dev) : Dv :=
  if v.mode = .closed then v
  else if !v.moved && v.snapped then v
  else mark { v with files := v.files.set .sess (some (.sess ⟨v.moment, v.battery, d⟩)),
                     moved := false, snapped := true } .sess

/-- `persistSave`: the FS .sav into `save:<game>` when it changed since
`lastSaveSig`; an empty .sav is no save. -/
def persistSave (v : Dv) : Dv :=
  if v.mode = .closed || v.battery = 0 || v.battery = v.lastSave then v
  else mark { v with files := v.files.set .save (some (.save v.battery)),
                     lastSave := v.battery } .save

/-- `storeLastFrame({ force })`. -/
def storeFrame (force : Bool) (v : Dv) : Dv :=
  if v.mode = .closed then v
  else if !force && v.lastFrame = some v.moment then v
  else mark { v with lastFrame := some v.moment,
                     files := v.files.set .frame (some (.frame v.moment)) } .frame

/-- `refreshHomeRecent` -> `refreshHero` -> `renderClosedHero`: redraws only
when `heroDrawnFor` is not this game. -/
def refresh (v : Dv) : Dv :=
  if v.mode = .closed && v.heroUp && !v.drawnFor then
    { v with drawn := heroPic v, drawnFor := true }
  else v

/-! ## User events -/

/-- A tap on the tile or the hero (`openLibraryGame` / `heroPrimary`): the
game in memory carries on (`resumeGame`); otherwise `launchRom` with
`resume`, and `loadRom` installs the stored save, boots, and puts the
session back in the same run where its `saveSig` is the battery installed.
Applying a state restores the battery RAM it carries. -/
def tap (v : Dv) : Dv :=
  match v.mode with
  | .running => v
  | .home => { v with mode := .running, gen := v.gen + 1 }
  | .closed =>
    let bat := saveVal (v.files.get .save)
    let base : Dv := { v with mode := .running, gen := v.gen + 1, battery := bat,
                              lastSave := bat, lastFrame := none, moved := true,
                              heroUp := true, moment := 0 }
    match resumable v with
    | some x => if x.sig = bat then { base with moment := x.m, battery := x.sig } else base
    | none => base

/-- `showMainMenu`. -/
def mainMenu (v : Dv) (d : Dev) : Dv :=
  if v.mode ≠ .running then v
  else
    let v := persistSave (persistAutoState (storeFrame true v) d)
    { v with mode := .home, drawn := v.moment, drawnFor := true, heroUp := true }

/-- `pagehide` (and `visibilitychange` hidden, with the 5 s save). -/
def hide (v : Dv) (d : Dev) : Dv :=
  storeFrame false (persistAutoState (persistSave v) d)

/-- The hero's Close (`unloadGame`): shown only for the game paused at home. -/
def close (v : Dv) (d : Dev) : Dv :=
  if v.mode ≠ .home then v
  else
    let v := persistSave (storeFrame true (persistAutoState { v with gen := v.gen + 1 } d))
    refresh { v with mode := .closed, battery := 0 }

/-- The page is killed and opened again: what IndexedDB and the sync state
hold survives, nothing in memory does. -/
def reload (v : Dv) : Dv :=
  { v with mode := .closed, moment := 0, battery := 0, moved := true, snapped := false,
           lastSave := 0, lastFrame := none, gen := v.gen + 1,
           remarked := KMap.all false, force := false, stash := [], offered := false,
           heroUp := false, drawnFor := false, eng := .idle, chained := false }

/-- A flush then a pull: started now, or queued behind the running job. -/
def startSync (v : Dv) : Dv :=
  match v.eng with
  | .idle => { v with eng := .flushReady true }
  | _ => { v with chained := true }

/-- `runFullSync`: the game in memory stored now, every local file queued,
then a flush and a pull. -/
def syncNow (v : Dv) (d : Dev) : Dv :=
  if v.mode = .running then v
  else
    let v := persistSave (persistAutoState v d)
    let q (k : Key) := v.queued.get k || (v.files.get k).isSome
    startSync { v with queued := ⟨q .save, q .sess, q .frame⟩ }

/-! ## The hand-off -/

/-- `takeHandoff`: `unloadGame({ flushSave: false, picture: false })` - the
copy in memory goes and nothing of it is written - then the news lands, and
the closed hero is due a redraw. -/
def land (v : Dv) (n : News) : Dv :=
  { v with files := v.files.set n.k (some n.b), sigs := v.sigs.set n.k (some n.b),
           rmt := v.rmt.set n.k n.mt }
def take (v : Dv) (news : List News) : Dv :=
  news.foldl land { v with mode := .closed, battery := 0, gen := v.gen + 1, drawnFor := false }

/-- The offer (`handoffStash`, the session marked seen, the toast). -/
def markSeen (v : Dv) (n : News) : Dv :=
  if n.k = .sess then { v with rmt := v.rmt.set .sess n.mt } else v
def offer (v : Dv) (news : List News) : Dv :=
  let kept := v.stash.filter (fun o => !news.any (fun n => n.k == o.k))
  news.foldl markSeen { v with stash := kept ++ news, offered := true }

/-- `handoffNews`: Drive's save and session where they changed since this
device saw them and differ from what it holds (the same bytes are marked
seen instead). -/
def newsStep (list : Listing) (acc : Dv × List News) (k : Key) : Dv × List News :=
  let (v, news) := acc
  match list.get k with
  | none => (v, news)
  | some (b, mt) =>
    if v.rmt.get k = mt then (v, news)
    else if v.files.get k = some b then
      ({ v with sigs := v.sigs.set k (some b), rmt := v.rmt.set k mt }, news)
    else (v, news ++ [⟨k, b, mt⟩])
def handoffNews (v : Dv) (list : Listing) : Dv × List News :=
  [Key.save, Key.sess].foldl (newsStep list) (v, [])

/-- The synchronous half of `heldGameIsSent`, before its `dbGet`. -/
def sentBefore (v : Dv) : Bool :=
  !v.moved && v.snapped && !v.queued.get .save && !v.queued.get .sess

/-- The fixed code's "still the game in memory, by the player's leave": not
unloaded or being unloaded, and no load or Resume since - unless that was a
Resume and the game runs (the offer is for exactly that game). -/
def stillHeld (v : Dv) (g0 : Nat) : Bool :=
  v.mode != .closed && (v.gen == g0 || v.mode == .running)

/-- Switch's re-send of one file: queued again, its sig forgotten, the
session's hold-back waived (`handoffForce`); fixed: re-marked. -/
def resend (c : Code) (v : Dv) (n : News) : Dv :=
  let v := mark { v with sigs := v.sigs.set n.k none, force := v.force || n.k == .sess } n.k
  if c = .fixed then { v with remarked := v.remarked.set n.k true } else v

/-- `switchToHandoff`: the stash lands as the hand-off does, and is sent up
again over whatever this device sent meanwhile. Fixed: also re-marked, so a
flush that is sending this device's older copy right now keeps it queued. -/
def switch (c : Code) (v : Dv) : Dv :=
  if v.mode = .closed || v.stash.isEmpty then v
  else
    let news := v.stash
    let v : Dv := { v with stash := [], offered := false,
                           queued := (v.queued.set .save false).set .sess false }
    startSync (refresh (news.foldl (resend c) (take v news)))

/-! ## The engine -/

/-- The files pass of `pullSyncInner`: per Drive file, unless the game is
in memory or the file is unchanged since seen, the bytes are written where
they differ from what this device last agreed (`sigs`); then anything held
here that Drive lacks is queued; then the home screen renders. -/
def fileStep (list : Listing) (v : Dv) (k : Key) : Dv :=
  match list.get k with
  | none => v
  | some (b, mt) =>
    if v.mode ≠ .closed then v
    else if v.rmt.get k = mt then v
    else
      let v := if v.sigs.get k ≠ some b then
          { v with files := v.files.set k (some b), sigs := v.sigs.set k (some b),
                   drawnFor := false }
        else v
      { v with rmt := v.rmt.set k mt }
def pullFiles (v : Dv) (list : Listing) : Dv :=
  let v := [Key.save, Key.sess, Key.frame].foldl (fileStep list) v
  let up (k : Key) := v.queued.get k || ((list.get k).isNone && (v.files.get k).isSome)
  refresh { v with queued := ⟨up .save, up .sess, up .frame⟩,
                   eng := if v.chained then .flushReady true else .idle, chained := false }

/-- One segment of the device's engine. -/
def tick (c : Code) (s : S) (d : Dev) : S :=
  let v := s.dev d
  match v.eng with
  | .idle => s
  | .flushReady tp => s.setDev d { v with eng := .flushing s.drv [.save, .sess, .frame] tp }
  | .flushing _ [] tp =>
    s.setDev d { v with eng := if tp then .pullReady else if v.chained then .flushReady true else .idle,
                        chained := if tp then v.chained else false }
  | .flushing list (k :: rest) tp =>
    if !v.queued.get k then s.setDev d { v with eng := .flushing list rest tp }
    else
      -- `syncRemarked.delete`, `readSyncBytes`, `handoffForce.delete`.
      let forced := k == .sess && v.force
      let v : Dv := { v with remarked := v.remarked.set k false,
                             force := if k == .sess then false else v.force }
      let next := Eng.flushing list rest tp
      match v.files.get k with
      | none => s.setDev d { v with queued := v.queued.set k false, eng := next }
      | some b =>
        -- The session another device wrote since this one saw Drive's copy.
        let unseen := match list.get k with
          | some (_, mt) => v.rmt.get k != mt
          | none => false
        if k == .sess && unseen && v.sigs.get k != some b && !forced then
          s.setDev d { v with eng := next }
        else if (list.get k).isNone || v.sigs.get k != some b then
          s.setDev d { v with eng := .sending list rest tp k b }
        else
          s.setDev d { v with sigs := v.sigs.set k (some b),
                              queued := v.queued.set k false, eng := next }
  | .sending list rest tp k b =>
    let mt := s.clock + 1
    let v : Dv := { v with rmt := v.rmt.set k mt, sigs := v.sigs.set k (some b),
                           queued := if v.remarked.get k then v.queued else v.queued.set k false,
                           eng := .flushing list rest tp }
    { (s.setDev d v) with drv := s.drv.set k (some (b, mt)), clock := mt }
  | .pullReady => s.setDev d { v with eng := .pullHand s.drv }
  | .pullHand list =>
    if v.mode = .closed then s.setDev d { v with eng := .pullFiles list }
    else
      let (v, news) := handoffNews v list
      s.setDev d { v with eng := .pullNews list news v.gen }
  | .pullNews list news g0 =>
    if news.isEmpty then s.setDev d { v with eng := .pullFiles list }
    else match c with
    | .shipped =>
      -- `onHome` and `heldGameIsSent`'s first checks, then its `dbGet`.
      if v.mode ≠ .running then s.setDev d { v with eng := .pullCheck list news (sentBefore v) g0 }
      else s.setDev d { (offer v news) with eng := .pullFiles list }
    | .fixed =>
      if !stillHeld v g0 then s.setDev d { v with eng := .pullFiles list }
      else if v.mode ≠ .running then s.setDev d { v with eng := .pullCheck list news true g0 }
      else s.setDev d { (offer v news) with eng := .pullFiles list }
  | .pullCheck list news sent1 g0 =>
    match c with
    | .shipped =>
      let sent := sent1 && v.battery == saveVal (v.files.get .save)
      if sent && v.mode != .closed then s.setDev d { (take v news) with eng := .pullFiles list }
      else s.setDev d { (offer v news) with eng := .pullFiles list }
    | .fixed =>
      -- Asked again in the run that acts: nothing changed since the read.
      let sent := sentBefore v && v.battery == saveVal (v.files.get .save) &&
                  v.mode == .home && v.gen == g0
      if sent then s.setDev d { (take v news) with eng := .pullFiles list }
      else if stillHeld v g0 then s.setDev d { (offer v news) with eng := .pullFiles list }
      else s.setDev d { v with eng := .pullFiles list }
  | .pullFiles list => s.setDev d (pullFiles v list)

/-! ## Events -/

inductive Ev
  | tap (d : Dev)
  /-- Frames run (the RAF tick): a new moment. -/
  | frames (d : Dev)
  /-- The game saves in game: the core writes its FS .sav. -/
  | gameSaves (d : Dev)
  /-- The 5 s `persistSave`. -/
  | autosave (d : Dev)
  | mainMenu (d : Dev)
  | hide (d : Dev)
  | close (d : Dev)
  | reload (d : Dev)
  | syncNow (d : Dev)
  /-- A flush then a pull (the debounce, the 3 min poll, the tab coming back). -/
  | trigger (d : Dev)
  /-- A pull alone (boot; the poll with nothing queued). -/
  | pull (d : Dev)
  | switch (d : Dev)
  /-- The device's engine runs its next segment. -/
  | tick (d : Dev)
  deriving DecidableEq, Repr

def onDev (s : S) (d : Dev) (f : Dv → Dv) : S := s.setDev d (f (s.dev d))

def step (c : Code) (s : S) : Ev → S
  | .tap d => onDev s d tap
  | .frames d =>
    if (s.dev d).mode = .running then
      { onDev s d (fun v => { v with moment := s.clock + 1, moved := true }) with clock := s.clock + 1 }
    else s
  | .gameSaves d =>
    if (s.dev d).mode = .running then
      { onDev s d (fun v => { v with battery := s.clock + 1 }) with clock := s.clock + 1 }
    else s
  | .autosave d => onDev s d persistSave
  | .mainMenu d => onDev s d (fun v => mainMenu v d)
  | .hide d => onDev s d (fun v => hide v d)
  | .close d => onDev s d (fun v => close v d)
  | .reload d => onDev s d reload
  | .syncNow d => onDev s d (fun v => syncNow v d)
  | .trigger d => onDev s d startSync
  | .pull d => onDev s d (fun v => match v.eng with
      | .idle => { v with eng := .pullReady }
      | _ => startSync v)
  | .switch d => onDev s d (switch c)
  | .tick d => tick c s d

def run (c : Code) (s : S) (es : List Ev) : S := es.foldl (step c) s

inductive Reachable (c : Code) : S → Prop
  | init : Reachable c init
  | step {s} (e : Ev) : Reachable c s → Reachable c (step c s e)

theorem reachable_run (c : Code) (es : List Ev) :
    ∀ s, Reachable c s → Reachable c (run c s es) := by
  induction es with
  | nil => intro s h; exact h
  | cons e es ih => intro s h; exact ih _ (Reachable.step e h)

/-! ## Stories -/

/-- Run the device's engine to idle: a flush and a pull take at most
1 + 2·3 + 1 + 4 segments here, and one more may be queued behind. -/
def settle (d : Dev) : List Ev := List.replicate 26 (.tick d)
def sync (d : Dev) : List Ev := .syncNow d :: settle d

/-- The moment `d` resumes, and Drive's session moment. -/
def driveMoment (s : S) : Nat :=
  match s.drv.get .sess with
  | some (.sess x, _) => x.m
  | _ => 0

/-! ## Matt's fourteen steps -/

/-- How device 2 comes to step 4 (web/e2e/fourteen-steps.e2e.mjs's four):
a browser that never opened the game; one that played it before and is
opened again; a tab left open on the library; a tab left open with the game
paused in memory at an older moment. -/
inductive Opening | new | reopened | tabOpen | tabPaused
  deriving DecidableEq, Repr

/-- Device 2's history before the story, and step 4 itself. -/
def before : Opening → List Ev
  | .new => []
  | .reopened => [.tap .b, .frames .b, .mainMenu .b] ++ sync .b ++ [.close .b] ++ sync .b
  | .tabOpen => [.tap .b, .frames .b, .mainMenu .b] ++ sync .b ++ [.close .b] ++ sync .b
  | .tabPaused => [.tap .b, .frames .b, .mainMenu .b] ++ sync .b
def opens : Opening → List Ev
  | .new => .pull .b :: settle .b ++ [.trigger .b] ++ settle .b      -- resumeDriveOnBoot
  | .reopened => [.hide .b, .reload .b, .pull .b] ++ settle .b ++ [.trigger .b] ++ settle .b
  | .tabOpen | .tabPaused => .trigger .b :: settle .b                -- the tab comes back

/-- Play on `d`: frames, an in-game save when `saving`, more frames. -/
def play (d : Dev) (saving : Bool) : List Ev :=
  [.frames d] ++ (if saving then [.gameSaves d, .autosave d] else []) ++ [.frames d]

/-- Steps 1-3 (device 2's history first, then device 1 picks the game up
from Drive as it stands). -/
def steps1to3 (o : Opening) (saving : Bool) : List Ev :=
  before o ++ sync .a ++ [.tap .a] ++ play .a saving ++ [.mainMenu .a] ++ sync .a
def steps4to5 (o : Opening) : List Ev := opens o ++ sync .b
def steps7to11 (saving : Bool) : List Ev :=
  [.tap .b] ++ play .b saving ++ [.mainMenu .b] ++ sync .b ++ sync .a

/-- Every SHOULD of the fourteen steps, checked on one run. -/
def fourteen (c : Code) (o : Opening) (saving : Bool) : Bool :=
  let s3 := run c init (steps1to3 o saving)
  let m1 := s3.a.moment
  let bat1 := s3.a.battery
  let s5 := run c s3 (steps4to5 o)
  let s7 := step c s5 (.tap .b)
  let s11 := run c s5 (steps7to11 saving)
  let s13 := step c s11 (.tap .a)
  -- step 2: device 1 paused at a moment of its own
  m1 != 0 &&
  -- step 6: device 2 shows device 1's picture
  shown s5.b == m1 &&
  -- step 7: device 2 resumes there, on device 1's save
  s7.b.mode == .running && s7.b.moment == m1 && s7.b.battery == bat1 &&
  -- step 12: device 1 shows device 2's picture
  shown s11.a == s11.b.moment && s11.b.moment != m1 &&
  -- step 14: device 1 picks up where device 2 left off, on its save
  s13.a.mode == .running && s13.a.moment == s11.b.moment &&
  s13.a.battery == s11.b.battery

/-- **Matt's fourteen steps hold**, for every way device 2 opens, saving in
game or not. -/
theorem fourteen_steps (o : Opening) (saving : Bool) : fourteen .fixed o saving = true := by
  cases o <;> cases saving <;> decide +kernel

/-- The shipped code keeps them too: the story has no race in it. -/
theorem fourteen_steps_shipped (o : Opening) (saving : Bool) :
    fourteen .shipped o saving = true := by
  cases o <;> cases saving <;> decide +kernel

/-! ## Safety, over every state -/


@[simp] theorem dev_setDev (s : S) (d : Dev) (v : Dv) : (s.setDev d v).dev d = v := by
  cases d <;> rfl
@[simp] theorem dev_setDev_ne (s : S) {d d' : Dev} (v : Dv) (h : d' ≠ d) :
    (s.setDev d v).dev d' = s.dev d' := by
  cases d <;> cases d' <;> simp_all [S.setDev, S.dev]
@[simp] theorem setDev_drv (s : S) (d : Dev) (v : Dv) : (s.setDev d v).drv = s.drv := by
  cases d <;> rfl
@[simp] theorem setDev_clock (s : S) (d : Dev) (v : Dv) : (s.setDev d v).clock = s.clock := by
  cases d <;> rfl

/-- **A Resume never rolls the save back**: the core runs on the save stored
now, whether it boots or goes back into a session. -/
theorem tap_never_rolls_back_save (v : Dv) (h : v.mode = .closed) :
    (tap v).battery = saveVal (v.files.get .save) := by
  unfold tap; rw [h]
  cases hr : resumable v with
  | none => rfl
  | some x => simp only; split <;> simp_all

/-- What a tap goes back into: the session where `resumeSessionFor` offers
it, else the boot. -/
theorem tap_resumes (v : Dv) (h : v.mode = .closed) :
    (tap v).moment = (match resumable v with | some x => x.m | none => 0) := by
  unfold tap; rw [h]
  cases hr : resumable v with
  | none => rfl
  | some x =>
    have : x.sig = saveVal (v.files.get .save) := by
      unfold resumable at hr
      split at hr <;> (try split at hr) <;> simp_all
    simp [this]

theorem tick_drv (c : Code) (s : S) (d : Dev) :
    (tick c s d).drv = (match (s.dev d).eng with
      | .sending _ _ _ k b => s.drv.set k (some (b, s.clock + 1))
      | _ => s.drv) := by
  simp only [tick]
  split <;> rename_i heq <;> simp only [heq] <;> (repeat' split) <;> simp

/-- **A flush never starts a session upload over a copy its listing shows and
this device has not seen** (the hold-back), unless Switch forced it: the key
stays queued and Drive is untouched. -/
theorem flush_holds_back_unseen_session (c : Code) (s : S) (d : Dev) (list : Listing)
    (rest : List Key) (tp : Bool) (b b0 : Blob) (mt : Nat)
    (he : (s.dev d).eng = .flushing list (.sess :: rest) tp)
    (hq : (s.dev d).queued.sess = true) (hf : (s.dev d).files.sess = some b)
    (hl : list.sess = some (b0, mt)) (hr : (s.dev d).rmt.sess ≠ mt)
    (hs : (s.dev d).sigs.sess ≠ some b) (hfo : (s.dev d).force = false) :
    (tick c s d).drv = s.drv ∧ ((tick c s d).dev d).eng = .flushing list rest tp ∧
    ((tick c s d).dev d).queued.sess = true := by
  simp only [tick, he]
  simp [KMap.get, KMap.set, hq, hf, hl, hr, hs, hfo]

/-- **Drive's session changes only when an upload of it lands**, and what lands
is what the flush read. -/
theorem drive_session_written_only_by_upload (c : Code) (s : S) (e : Ev)
    (h : (step c s e).drv.sess ≠ s.drv.sess) :
    ∃ d list rest tp b, e = .tick d ∧ (s.dev d).eng = .sending list rest tp .sess b ∧
      (step c s e).drv.sess = some (b, s.clock + 1) := by
  cases e with
  | tick d =>
    simp only [step, tick_drv] at h ⊢
    cases he : (s.dev d).eng with
    | sending list rest tp k b =>
      simp only at h ⊢
      cases k with
      | sess => exact ⟨d, list, rest, tp, b, rfl, he, rfl⟩
      | save => simp [KMap.set, he] at h
      | frame => simp [KMap.set, he] at h
    | _ => simp [he] at h
  | frames d => exfalso; apply h; simp only [step]; split <;> simp [onDev]
  | gameSaves d => exfalso; apply h; simp only [step]; split <;> simp [onDev]
  | _ => exfalso; apply h; simp [step, onDev]

/-! ### What the user's own events leave alone -/

@[simp] theorem mark_eng (v : Dv) (k : Key) : (mark v k).eng = v.eng := by
  unfold mark; split <;> rfl
@[simp] theorem persistAutoState_eng (v : Dv) (d : Dev) : (persistAutoState v d).eng = v.eng := by
  unfold persistAutoState; split <;> (try split) <;> simp
@[simp] theorem persistSave_eng (v : Dv) : (persistSave v).eng = v.eng := by
  unfold persistSave; split <;> simp
@[simp] theorem storeFrame_eng (f : Bool) (v : Dv) : (storeFrame f v).eng = v.eng := by
  unfold storeFrame; split <;> (try split) <;> simp
@[simp] theorem refresh_eng (v : Dv) : (refresh v).eng = v.eng := by
  unfold refresh; split <;> rfl
theorem foldl_eng {β : Type} (f : Dv → β → Dv) (hf : ∀ v x, (f v x).eng = v.eng) :
    ∀ (l : List β) (w : Dv), (l.foldl f w).eng = w.eng := by
  intro l; induction l with
  | nil => intro w; rfl
  | cons x l ih => intro w; simp only [List.foldl]; rw [ih, hf]
@[simp] theorem land_eng (v : Dv) (n : News) : (land v n).eng = v.eng := rfl
@[simp] theorem resend_eng (c : Code) (v : Dv) (n : News) : (resend c v n).eng = v.eng := by
  unfold resend; split <;> simp
@[simp] theorem take_eng (v : Dv) (news : List News) : (take v news).eng = v.eng := by
  unfold take; rw [foldl_eng _ land_eng]
@[simp] theorem tap_eng (v : Dv) : (tap v).eng = v.eng := by
  unfold tap; split <;> simp only [] <;> (repeat' split) <;> rfl
@[simp] theorem mainMenu_eng (v : Dv) (d : Dev) : (mainMenu v d).eng = v.eng := by
  unfold mainMenu; split <;> simp
@[simp] theorem hide_eng (v : Dv) (d : Dev) : (hide v d).eng = v.eng := by simp [hide]
@[simp] theorem close_eng (v : Dv) (d : Dev) : (close v d).eng = v.eng := by
  unfold close; split <;> simp

@[simp] theorem dev_with (t : S) (d : Dev) (x : Listing) (y : Nat) :
    ({ t with drv := x, clock := y } : S).dev d = t.dev d := by cases d <;> rfl

theorem pullFiles_eng (v : Dv) (list : Listing) :
    (pullFiles v list).eng = .idle ∨ (pullFiles v list).eng = .flushReady true := by
  unfold pullFiles; simp only [refresh_eng]; split <;> simp

/-- A session upload starts only from a flush's read of it whose listing
showed no unseen copy (or Switch forced it). -/
theorem tick_starts_upload (c : Code) (s : S) (d : Dev) (list : Listing) (rest : List Key)
    (tp : Bool) (b : Blob)
    (h : ((tick c s d).dev d).eng = .sending list rest tp .sess b) :
    (s.dev d).eng = .flushing list (.sess :: rest) tp ∧ (s.dev d).files.sess = some b ∧
      ∀ b0 mt, list.sess = some (b0, mt) → (s.dev d).rmt.sess = mt ∨ (s.dev d).force = true := by
  simp only [tick] at h
  split at h <;> rename_i heq
  all_goals (try simp only [dev_setDev, dev_with] at h)
  all_goals (repeat' (split at h))
  all_goals (try (simp_all; done))
  all_goals (try (exfalso; rcases pullFiles_eng (s.dev d) ‹Listing› with e | e <;> rw [e] at h <;> simp at h; done))
  all_goals
    rw [dev_setDev] at h
    simp only [Eng.sending.injEq] at h
    obtain ⟨rfl, rfl, rfl, rfl, rfl⟩ := h
    refine ⟨?_, ?_, ?_⟩
    · simp_all
    · simp_all [KMap.get]
    · intro b0 mt hl
      by_cases hf : (s.dev d).force = true
      · exact Or.inr hf
      · by_cases hr : (s.dev d).rmt.sess = mt
        · exact Or.inl hr
        · exfalso; simp_all [KMap.get]

theorem tick_other (c : Code) (s : S) {d d' : Dev} (hd : d ≠ d') :
    (tick c s d').dev d = s.dev d := by
  simp only [tick]
  split <;> (repeat' split) <;> simp [dev_setDev_ne _ _ hd]

theorem startSync_eng (v : Dv) : (startSync v).eng = v.eng ∨ (startSync v).eng = .flushReady true := by
  unfold startSync; split <;> simp
theorem switch_eng (c : Code) (v : Dv) :
    (switch c v).eng = v.eng ∨ (switch c v).eng = .flushReady true := by
  unfold switch; split
  · simp
  · simp only []
    refine (startSync_eng _).imp (fun h => ?_) id
    rw [h, refresh_eng, foldl_eng _ (resend_eng c)]; simp
theorem syncNow_eng (v : Dv) (d : Dev) :
    (syncNow v d).eng = v.eng ∨ (syncNow v d).eng = .flushReady true := by
  unfold syncNow startSync; split
  · simp
  · simp only [persistSave_eng, persistAutoState_eng]; split <;> simp

/-- **Every session upload began as a flush's approved read**: no event puts a
device into sending its session except the flush segment that read it, saw
no unseen copy in its listing (or had Switch's leave), and read these bytes. -/
theorem session_upload_was_approved (c : Code) (s : S) (e : Ev) (d : Dev) (list : Listing)
    (rest : List Key) (tp : Bool) (b : Blob)
    (h : ((step c s e).dev d).eng = .sending list rest tp .sess b) :
    (s.dev d).eng = .sending list rest tp .sess b ∨
    (e = .tick d ∧ (s.dev d).eng = .flushing list (.sess :: rest) tp ∧
      (s.dev d).files.sess = some b ∧
      ∀ b0 mt, list.sess = some (b0, mt) → (s.dev d).rmt.sess = mt ∨ (s.dev d).force = true) := by
  cases e with
  | tick d' =>
    by_cases hd : d' = d
    · subst hd; exact Or.inr ⟨rfl, tick_starts_upload c s d' list rest tp b h⟩
    · left; simp only [step] at h; rwa [tick_other c s (Ne.symm hd)] at h
  | frames d' =>
    left; simp only [step] at h
    by_cases hd : d' = d
    · subst hd; split at h <;> simpa [onDev] using h
    · split at h <;> simpa [onDev, dev_setDev_ne _ _ (Ne.symm hd)] using h
  | gameSaves d' =>
    left; simp only [step] at h
    by_cases hd : d' = d
    · subst hd; split at h <;> simpa [onDev] using h
    · split at h <;> simpa [onDev, dev_setDev_ne _ _ (Ne.symm hd)] using h
  | reload d' =>
    left; simp only [step] at h
    by_cases hd : d' = d
    · subst hd; simp [onDev, reload] at h
    · simpa [onDev, dev_setDev_ne _ _ (Ne.symm hd)] using h
  | syncNow d' =>
    left; simp only [step] at h
    by_cases hd : d' = d
    · subst hd; simp only [onDev, dev_setDev] at h
      rcases syncNow_eng (s.dev d') d' with e | e <;> rw [e] at h
      · exact h
      · simp at h
    · simpa [onDev, dev_setDev_ne _ _ (Ne.symm hd)] using h
  | trigger d' =>
    left; simp only [step] at h
    by_cases hd : d' = d
    · subst hd; simp only [onDev, dev_setDev] at h
      rcases startSync_eng (s.dev d') with e | e <;> rw [e] at h
      · exact h
      · simp at h
    · simpa [onDev, dev_setDev_ne _ _ (Ne.symm hd)] using h
  | pull d' =>
    left; simp only [step] at h
    by_cases hd : d' = d
    · subst hd; simp only [onDev, dev_setDev] at h
      split at h
      · simp at h
      · rcases startSync_eng (s.dev d') with e | e <;> rw [e] at h
        · exact h
        · simp at h
    · simpa [onDev, dev_setDev_ne _ _ (Ne.symm hd)] using h
  | switch d' =>
    left; simp only [step] at h
    by_cases hd : d' = d
    · subst hd; simp only [onDev, dev_setDev] at h
      rcases switch_eng c (s.dev d') with e | e <;> rw [e] at h
      · exact h
      · simp at h
    · simpa [onDev, dev_setDev_ne _ _ (Ne.symm hd)] using h
  | _ d' =>
    left; simp only [step] at h
    by_cases hd : d' = d
    · subst hd; simpa [onDev] using h
    · simpa [onDev, dev_setDev_ne _ _ (Ne.symm hd)] using h

/-! ### Where the game is -/

theorem foldl_pres {α β : Type} (P : Dv → α) (f : Dv → β → Dv) (hf : ∀ v x, P (f v x) = P v) :
    ∀ (l : List β) (w : Dv), P (l.foldl f w) = P w := by
  intro l; induction l with
  | nil => intro w; rfl
  | cons x l ih => intro w; simp only [List.foldl]; rw [ih, hf]

@[simp] theorem mark_mode (v : Dv) (k : Key) : (mark v k).mode = v.mode := by
  unfold mark; split <;> rfl
@[simp] theorem persistAutoState_mode (v : Dv) (d : Dev) : (persistAutoState v d).mode = v.mode := by
  unfold persistAutoState; split <;> (try split) <;> simp
@[simp] theorem persistSave_mode (v : Dv) : (persistSave v).mode = v.mode := by
  unfold persistSave; split <;> simp
@[simp] theorem storeFrame_mode (f : Bool) (v : Dv) : (storeFrame f v).mode = v.mode := by
  unfold storeFrame; split <;> (try split) <;> simp
@[simp] theorem refresh_mode (v : Dv) : (refresh v).mode = v.mode := by
  unfold refresh; split <;> rfl
@[simp] theorem markSeen_mode (v : Dv) (n : News) : (markSeen v n).mode = v.mode := by
  unfold markSeen; split <;> rfl
@[simp] theorem offer_mode (v : Dv) (news : List News) : (offer v news).mode = v.mode := by
  unfold offer; rw [foldl_pres Dv.mode _ markSeen_mode]
theorem newsStep_mode (list : Listing) (acc : Dv × List News) (k : Key) :
    (newsStep list acc k).1.mode = acc.1.mode := by
  unfold newsStep; split <;> (try split) <;> (try split) <;> (try split) <;> rfl
@[simp] theorem handoffNews_mode (v : Dv) (list : Listing) : (handoffNews v list).1.mode = v.mode := by
  simp [handoffNews, List.foldl, newsStep_mode]
@[simp] theorem fileStep_mode (list : Listing) (v : Dv) (k : Key) : (fileStep list v k).mode = v.mode := by
  unfold fileStep; split <;> (try split) <;> (try split) <;> (try split) <;> simp
@[simp] theorem pullFiles_mode (v : Dv) (list : Listing) : (pullFiles v list).mode = v.mode := by
  unfold pullFiles; simp only [refresh_mode]; rw [foldl_pres Dv.mode _ (fileStep_mode list)]
@[simp] theorem land_mode (v : Dv) (n : News) : (land v n).mode = v.mode := rfl
@[simp] theorem take_mode (v : Dv) (news : List News) : (take v news).mode = .closed := by
  unfold take; rw [foldl_pres Dv.mode _ land_mode]

@[simp] theorem startSync_mode (v : Dv) : (startSync v).mode = v.mode := by
  unfold startSync; split <;> rfl
theorem tap_not_closed (v : Dv) (h : v.mode ≠ .closed) : (tap v).mode ≠ .closed := by
  unfold tap; split <;> simp_all

/-- **A pull lets the game in memory go only at home, unmoved, with its save
and session sent** (the fixed code). The other ways a game closes are the
player's: Close, Switch, or the page going. -/
theorem pull_unloads_only_a_sent_game (s : S) (e : Ev) (d : Dev)
    (h0 : (s.dev d).mode ≠ .closed) (h1 : ((step .fixed s e).dev d).mode = .closed) :
    e = .close d ∨ e = .reload d ∨ e = .switch d ∨
    (e = .tick d ∧ (s.dev d).mode = .home ∧ (s.dev d).moved = false ∧
      (s.dev d).queued.save = false ∧ (s.dev d).queued.sess = false ∧
      (s.dev d).battery = saveVal ((s.dev d).files.get .save)) := by
  cases e with
  | tick d' =>
    by_cases hd : d' = d
    · subst hd
      right; right; right; refine ⟨rfl, ?_⟩
      simp only [step, tick] at h1
      split at h1 <;> rename_i heq
      all_goals (try simp only [dev_setDev, dev_with] at h1)
      all_goals (repeat' (split at h1))
      all_goals (try (simp_all; done))
      all_goals
        rename_i hs
        clear h1
        simp only [sentBefore, Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true'] at hs
        simp_all [KMap.get]
    · exfalso; simp only [step] at h1; rw [tick_other _ _ (Ne.symm hd)] at h1; exact h0 h1
  | close d' =>
    by_cases hd : d' = d
    · subst hd; left; rfl
    · exfalso; simp [step, onDev, dev_setDev_ne _ _ (Ne.symm hd)] at h1; exact h0 h1
  | reload d' =>
    by_cases hd : d' = d
    · subst hd; right; left; rfl
    · exfalso; simp [step, onDev, dev_setDev_ne _ _ (Ne.symm hd)] at h1; exact h0 h1
  | switch d' =>
    by_cases hd : d' = d
    · subst hd; right; right; left; rfl
    · exfalso; simp [step, onDev, dev_setDev_ne _ _ (Ne.symm hd)] at h1; exact h0 h1
  | tap d' =>
    exfalso
    by_cases hd : d' = d
    · subst hd; simp only [step, onDev, dev_setDev] at h1; exact tap_not_closed _ h0 h1
    · simp [step, onDev, dev_setDev_ne _ _ (Ne.symm hd)] at h1; exact h0 h1
  | frames d' | gameSaves d' =>
    exfalso; simp only [step] at h1
    by_cases hd : d' = d
    · subst hd; split at h1 <;> simp_all [onDev]
    · split at h1 <;> simp_all [onDev, dev_setDev_ne _ _ (Ne.symm hd)]
  | mainMenu d' =>
    exfalso
    by_cases hd : d' = d
    · subst hd; simp only [step, onDev, dev_setDev, mainMenu] at h1; split at h1 <;> simp_all
    · simp [step, onDev, dev_setDev_ne _ _ (Ne.symm hd)] at h1; exact h0 h1
  | syncNow d' =>
    exfalso
    by_cases hd : d' = d
    · subst hd; simp only [step, onDev, dev_setDev, syncNow] at h1; split at h1 <;> simp_all
    · simp [step, onDev, dev_setDev_ne _ _ (Ne.symm hd)] at h1; exact h0 h1
  | trigger d' =>
    exfalso
    by_cases hd : d' = d
    · subst hd; simp_all [step, onDev]
    · simp [step, onDev, dev_setDev_ne _ _ (Ne.symm hd)] at h1; exact h0 h1
  | pull d' =>
    exfalso
    by_cases hd : d' = d
    · subst hd; simp only [step, onDev, dev_setDev] at h1; split at h1 <;> simp_all
    · simp [step, onDev, dev_setDev_ne _ _ (Ne.symm hd)] at h1; exact h0 h1
  | _ d' =>
    exfalso
    by_cases hd : d' = d
    · subst hd; simp_all [step, onDev, hide]
    · simp [step, onDev, dev_setDev_ne _ _ (Ne.symm hd)] at h1; exact h0 h1

/-! ### The hand-off lands -/

theorem KMap.get_set_same {α : Type} (m : KMap α) (k : Key) (x : α) : (m.set k x).get k = x := by
  cases k <;> rfl
theorem KMap.get_set_ne {α : Type} (m : KMap α) {k k' : Key} (x : α) (h : k' ≠ k) :
    (m.set k x).get k' = m.get k' := by
  cases k <;> cases k' <;> simp_all [KMap.set, KMap.get]

theorem foldl_land_other (l : List News) (k : Key) (hl : ∀ m ∈ l, m.k ≠ k) :
    ∀ w : Dv, (l.foldl land w).files.get k = w.files.get k := by
  induction l with
  | nil => intro w; rfl
  | cons n l ih =>
    intro w; simp only [List.foldl]
    rw [ih (fun m hm => hl m (List.mem_cons_of_mem _ hm))]
    simp only [land]; exact KMap.get_set_ne _ _ (Ne.symm (hl n (List.mem_cons_self ..)))

/-- What `takeHandoff` writes: every file of the news, as downloaded (the
news holds one entry per file). -/
theorem take_lands (v : Dv) (news : List News) (hd : news.Pairwise (fun x y => x.k ≠ y.k)) :
    ∀ n ∈ news, (take v news).files.get n.k = some n.b := by
  unfold take
  generalize ({ v with mode := .closed, battery := 0, gen := v.gen + 1, drawnFor := false } : Dv) = w
  induction news generalizing w with
  | nil => intro n hn; cases hn
  | cons x l ih =>
    intro n hn
    rw [List.pairwise_cons] at hd
    simp only [List.foldl]
    rcases List.mem_cons.mp hn with rfl | hn
    · rw [foldl_land_other l n.k (fun m hm => Ne.symm (hd.1 m hm))]
      exact KMap.get_set_same _ _ _
    · exact ih hd.2 _ n hn

theorem foldl_land_eng (l : List News) :
    ∀ (w : Dv) (e : Eng), l.foldl land { w with eng := e } = { (l.foldl land w) with eng := e } := by
  induction l with
  | nil => intro w e; rfl
  | cons n l ih => intro w e; simp only [List.foldl]; exact ih (land w n) e

theorem take_with_eng (v : Dv) (news : List News) (e e' : Eng) :
    ({ (take { v with eng := e } news) with eng := e' } : Dv) = { (take v news) with eng := e' } := by
  unfold take
  show ({ (List.foldl land ({ ({ v with mode := .closed, battery := 0, gen := v.gen + 1, drawnFor := false } : Dv) with eng := e } : Dv) news) with eng := e' } : Dv) = _
  rw [foldl_land_eng]

/-- **A game held at home, unmoved, its save and session sent, is always
handed over** (fixed code): with nothing done in between, the pull's next
two segments let the copy in memory go and land the other device's files. -/
theorem handed_off_when_sent (s : S) (d : Dev) (list : Listing) (news : List News) (g0 : Nat)
    (he : (s.dev d).eng = .pullNews list news g0) (hn : news ≠ [])
    (hm : (s.dev d).mode = .home) (hg : (s.dev d).gen = g0) (hs : sentBefore (s.dev d) = true)
    (hb : (s.dev d).battery = saveVal ((s.dev d).files.get .save)) :
    (tick .fixed (tick .fixed s d) d).dev d = { (take (s.dev d) news) with eng := .pullFiles list } := by
  have hne : news.isEmpty = false := by cases news <;> simp_all
  have h1 : tick .fixed s d = s.setDev d { s.dev d with eng := .pullCheck list news true g0 } := by
    simp only [tick, he, hne, stillHeld]
    simp [hm, hg]
  rw [h1]
  simp only [tick, dev_setDev]
  have hc : (sentBefore { s.dev d with eng := .pullCheck list news true g0 } &&
      (s.dev d).battery == saveVal ((s.dev d).files.get .save) && (s.dev d).mode == .home &&
      (s.dev d).gen == g0) = true := by
    simp only [sentBefore] at hs ⊢; simp [hs, hb, hm, hg]
  simp only [hc, ↓reduceIte]
  simp only [dev_setDev, take_with_eng]

/-! ### The picture follows -/

theorem fileStep_drawn (list : Listing) (w : Dv) (k : Key) :
    ((fileStep list w k).files ≠ w.files → (fileStep list w k).drawnFor = false) ∧
    (w.drawnFor = false → (fileStep list w k).drawnFor = false) := by
  unfold fileStep
  split
  · simp_all
  · split
    · simp_all
    · split
      · simp_all
      · split <;> simp_all

theorem foldl_fileStep_drawn (list : Listing) (l : List Key) :
    ∀ w : Dv, ((l.foldl (fileStep list) w).files ≠ w.files ∨ w.drawnFor = false) →
      (l.foldl (fileStep list) w).drawnFor = false := by
  induction l with
  | nil => intro w h; simp_all
  | cons k l ih =>
    intro w h
    simp only [List.foldl] at h ⊢
    apply ih
    by_cases hf : (fileStep list w k).files = w.files
    · rcases h with h | h
      · left; rwa [hf]
      · right; exact (fileStep_drawn list w k).2 h
    · right; exact (fileStep_drawn list w k).1 hf

/-- **A pull that lands a file redraws the closed hero from what is stored
now** (`heroDrawnFor` let go in the same run): the session's picture where
it can be resumed, else the library picture. -/
theorem pull_redraws_hero (v : Dv) (list : Listing) (hm : v.mode = .closed) (hu : v.heroUp = true)
    (hf : (pullFiles v list).files ≠ v.files) :
    shown (pullFiles v list) = heroPic (pullFiles v list) := by
  have hd := foldl_fileStep_drawn list [Key.save, Key.sess, Key.frame] v
  have hmode := foldl_pres Dv.mode (fileStep list) (fileStep_mode list) [Key.save, Key.sess, Key.frame] v
  have hhero := foldl_pres Dv.heroUp (fileStep list) (by
    intro w k; unfold fileStep; split <;> (try split) <;> (try split) <;> (try split) <;> rfl)
    [Key.save, Key.sess, Key.frame] v
  unfold pullFiles at hf ⊢
  simp only [refresh] at hf ⊢
  generalize hw : List.foldl (fileStep list) v [Key.save, Key.sess, Key.frame] = w at hd hmode hhero hf ⊢
  have hdf : w.drawnFor = false := hd (Or.inl (by
    intro h; apply hf; split <;> simp_all))
  simp [hdf, hmode, hhero, hm, hu, shown, heroPic, resumable]

/-! ## The shipped code's counterexamples, and the fixed code on the same traces -/

/-- Device 1 pauses and syncs; device 2 picks it up, plays on, pauses and
syncs. Device 1 still holds its older moment, paused at home. -/
def handPrefix : List Ev :=
  [.tap .a, .frames .a, .mainMenu .a] ++ sync .a ++
  sync .b ++ [.tap .b, .frames .b, .mainMenu .b] ++ sync .b

/-- Device 1 plays on from its own copy and pauses, unsent; its Sync holds
the session back and offers Switch (`sync .a`); the flush the offer
schedules starts sending device 1's session (`trigger`, three segments)... -/
def switchPre : List Ev :=
  handPrefix ++ [.tap .a, .frames .a, .mainMenu .a] ++ sync .a ++
  [.trigger .a, .tick .a, .tick .a, .tick .a]
/-- ...and the player taps Switch while it is on the wire. Then both sync. -/
def switchTrace : List Ev := switchPre ++ [.switch .a] ++ settle .a ++ sync .b

/-- The player chose device 2's moment, and device 1 resumes it; but Drive
ends up holding the moment turned down, and device 2 picks that up. -/
theorem bug_switch_during_upload :
    let s := run .shipped init switchTrace
    let chosen := (run .shipped init handPrefix).b.moment
    let turnedDown := (run .shipped init switchPre).a.moment
    turnedDown ≠ chosen ∧ resumePoint s.a = chosen ∧ driveMoment s = turnedDown ∧
    resumePoint s.b = turnedDown := by
  decide +kernel

/-- **Fixed** (`syncRemarked` in `switchToHandoff`): the chosen copy goes up
after the turned-down one lands, and both devices resume it. -/
theorem regress_switch_during_upload :
    let s := run .fixed init switchTrace
    let chosen := (run .fixed init handPrefix).b.moment
    resumePoint s.a = chosen ∧ driveMoment s = chosen ∧ resumePoint s.b = chosen := by
  decide +kernel

/-- Device 1, paused at home with everything sent, taps Sync; the pull is
downloading device 2's newer session (`pullNews`) when the player taps the
hero's Close. Then both sync again. -/
def closeTrace : List Ev :=
  handPrefix ++ [.syncNow .a] ++ List.replicate 7 (.tick .a) ++ [.close .a] ++ settle .a ++
  sync .a ++ sync .b

/-- The pull went on as if the game were still held: it offered Switch and
marked device 2's session seen, so the files pass skipped it. Device 1
resumes its own older moment for good. -/
theorem bug_close_during_handoff :
    let s := run .shipped init closeTrace
    let p := run .shipped init handPrefix
    p.a.moment ≠ p.b.moment ∧ resumePoint s.a = p.a.moment ∧ shown s.a = p.a.moment ∧
    driveMoment s = p.b.moment ∧ resumePoint s.b = p.b.moment ∧ s.a.offered = true := by
  decide +kernel

/-- **Fixed** (`stillHeld` in `pullSyncInner`): a game closed during the
download is a closed game, and the files pass lands the newer copy. -/
theorem regress_close_during_handoff :
    let s := run .fixed init closeTrace
    let p := run .fixed init handPrefix
    resumePoint s.a = p.b.moment ∧ shown s.a = p.b.moment ∧
    driveMoment s = p.b.moment ∧ s.a.offered = false := by
  decide +kernel

/-- Device 1, paused at home with everything sent, syncs; while
`heldGameIsSent` reads the stored save (`pullCheck`), the player taps Resume
and frames run; then the pull goes on. -/
def resumePre : List Ev :=
  handPrefix ++ [.syncNow .a] ++ List.replicate 8 (.tick .a) ++ [.tap .a, .frames .a]

/-- The pull had decided "at home" before the read, and unloads the game the
player went back into: the moment just played is in no file anywhere. -/
theorem bug_resume_during_handoff :
    let p := run .shipped init resumePre
    let s := step .shipped p (.tick .a)
    p.a.mode = .running ∧ s.a.mode = .closed ∧
    resumePoint s.a ≠ p.a.moment ∧ driveMoment s ≠ p.a.moment := by
  decide +kernel

/-- **Fixed** (`heldGameIsSent` asks after its read; the caller checks
`running` and `loadGen` in the run that acts): play goes on, with the offer. -/
theorem regress_resume_during_handoff :
    let s := run .fixed init (resumePre ++ [.tick .a])
    s.a.mode = .running ∧ s.a.offered = true := by
  decide +kernel

/-! ## Open by design: two devices played without syncing in between

Each device's save and session follow one rule: what Drive holds and this
device has not seen beats what this device has not sent, except for the
game held in memory, whose copy is kept (Switch offered) and goes up next.
Two copies made apart cannot both survive under it; these traces show which
one goes. Drive has no compare-and-swap, so a flush can also write over a
copy uploaded after its listing. -/

/-- Both devices play on from the same moment and save in game, without
syncing in between; then each syncs in turn. -/
def concurrentPre : List Ev :=
  [.tap .a, .frames .a, .mainMenu .a] ++ sync .a ++ sync .b ++
  [.tap .a, .frames .a, .gameSaves .a, .autosave .a, .mainMenu .a] ++
  [.tap .b, .frames .b, .gameSaves .b, .autosave .b, .mainMenu .b]
def concurrentPost : List Ev :=
  sync .a ++ sync .b ++ [.trigger .b] ++ settle .b ++ sync .a ++ sync .b

/-- A battery value is still somewhere: in a device's store or core, or on Drive. -/
def kept (s : S) (bat : Nat) : Bool :=
  [s.a, s.b].any (fun v => saveVal (v.files.get .save) == bat || v.battery == bat) ||
  saveVal ((s.drv.get .save).map (·.1)) == bat

/-- The device that syncs last while holding the game wins: device 1's in-game
save is gone from both devices and from Drive. -/
theorem edge_concurrent_play_held_wins :
    let p := run .fixed init concurrentPre
    let s := run .fixed p concurrentPost
    kept s p.a.battery = false ∧ kept s p.b.battery = true ∧
    resumePoint s.a = p.b.moment ∧ resumePoint s.b = p.b.moment := by
  decide +kernel

/-- Device 1 saves in game and its page is killed before the flush; device 2,
from the older copy, saves and syncs; device 1 opens again. The boot pull
lands device 2's save over device 1's unsent one. -/
def closedYieldsPre : List Ev :=
  [.tap .a, .frames .a, .mainMenu .a] ++ sync .a ++ sync .b ++
  [.tap .a, .frames .a, .gameSaves .a, .autosave .a, .hide .a, .reload .a] ++
  [.tap .b, .frames .b, .gameSaves .b, .autosave .b, .mainMenu .b] ++ sync .b
def closedYieldsPost : List Ev := [.pull .a] ++ settle .a ++ [.trigger .a] ++ settle .a

theorem edge_closed_copy_yields :
    let p := run .fixed init closedYieldsPre
    let s := run .fixed p closedYieldsPost
    p.a.queued.save = true ∧ kept s (saveVal (p.a.files.get .save)) = false := by
  decide +kernel

/-- Device 1's flush lists Drive; device 2 then syncs its newer session; device
1's upload lands over it, unseen. -/
def listingRacePre : List Ev :=
  [.tap .a, .frames .a, .mainMenu .a] ++ sync .a ++ sync .b ++
  [.tap .a, .frames .a, .mainMenu .a, .tap .b, .frames .b, .mainMenu .b] ++
  [.trigger .a, .tick .a] ++ sync .b

theorem edge_listing_race :
    let p := run .fixed init listingRacePre
    let s := run .fixed p (settle .a)
    driveMoment p = p.b.moment ∧ driveMoment s = p.a.moment := by
  decide +kernel

/-! ## Convergence -/

/-- One move of one device: sync and stop mid-pull (at the hand-off), play,
play and save in game, Close, a full Sync, the page killed and opened again,
Switch. -/
def move (d : Dev) : Fin 7 → List Ev
  | 0 => [.syncNow d] ++ List.replicate 7 (.tick d)
  | 1 => [.tap d, .frames d, .mainMenu d]
  | 2 => [.tap d, .frames d, .gameSaves d, .autosave d, .mainMenu d]
  | 3 => [.close d]
  | 4 => sync d
  | 5 => [.hide d, .reload d, .pull d] ++ settle d
  | 6 => [.switch d]

/-- Each device syncs in turn, three times: enough for a held copy that was
offered Switch to go up, and the other device to take it. -/
def finalRound : List Ev := sync .a ++ sync .b ++ sync .a ++ sync .b ++ sync .a ++ sync .b

/-- Where Drive's copy resumes: its session where it was taken with Drive's save. -/
def driveResume (s : S) : Nat :=
  match s.drv.get .sess with
  | some (.sess x, _) => if x.sig = saveVal ((s.drv.get .save).map (·.1)) then x.m else 0
  | _ => 0

/-- The hero, where it is up, shows where a tap goes. -/
def truePicture (v : Dv) : Bool :=
  v.mode != .closed || !v.heroUp || resumePoint v == 0 || shown v == resumePoint v

def agree (s : S) : Bool :=
  resumePoint s.a == resumePoint s.b && resumePoint s.a == driveResume s &&
  saveVal (s.a.files.get .save) == saveVal (s.b.files.get .save) &&
  truePicture s.a && truePicture s.b

def moves : List (Fin 7) := [0, 1, 2, 3, 4, 5, 6]

def converges (c : Code) (d e : Dev) : Bool :=
  moves.all fun x => moves.all fun y => moves.all fun z =>
    agree (run c init (move d x ++ move e y ++ move d z ++ finalRound))

/-- **Both devices end up agreeing**: from all 343 histories of three moves
(device 1, device 2, device 1), syncing each in turn leaves both resuming the
same moment, on the same save, as Drive holds, each hero showing where its
tap goes. -/
theorem converges_a_b_a : converges .fixed .a .b = true := by decide +kernel
/-- The same, device 2 first. -/
theorem converges_b_a_b : converges .fixed .b .a = true := by decide +kernel

end WebState.Handoff
