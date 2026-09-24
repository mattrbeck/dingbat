-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/index.js: addRecentRom applyLibFilter buildTileMenuHead closeThumbsModal closeTileMenu deleteGameEverywhere deleteGameLocalData deleteKeys frameBlobFromFb getRomArt getRomFrame launchRom loadRom openThumbsOffer openTileMenu persistAutoState refreshHomeRecent removeGameFromDevice renameGame runThumbnailBatch setRomsSort showMainMenu storeLastFrame thumbsPictureOne togglePause unloadGame updatePausedCard writeSyncBytes on:visibilitychange on:contextmenu

/-
# Thumbnails and library pictures (web/index.js)

The library tile's picture: the last screen a game showed ("frame:<name>",
a JPEG Blob) or its box art ("art:<name>"), fetched lazily by the grid and
by the per-game menu's head, shown through object URLs.

Line numbers are web/index.js at commit dd7ba741f, except the load path
(`loadBegin`/`loadOutDone`/`loadInit`), which models loadRom as fixed by the
commit "web: a game is named only once its core and save are in; loads and
closes take a token", at the lines of "web: flush the solo core wherever its file
is read; Reset, Delete and Import retire a waiting quota retry".

## Writers of "frame:<name>"
* `storeLastFrame` (4359–4381): copies the wasm framebuffer and the name
  `currentOriginalName` synchronously, then on `frameStoreChain` (a FIFO
  promise chain) awaits `frameBlobFromFb` (canvas `toBlob`, 4332–4349) and
  then `dbPut(frameKey(name))` + `markUpload`. Callers: the 60 s tick (4384,
  only `!paused`), `visibilitychange` (11217), `pagehide`/`beforeunload`
  (11203–11235), `togglePause` (8219), `showMainMenu` (9365), `saveToSlot`
  (5573), `loadRom`'s outgoing capture (7889), `unloadGame` (9642).
* `thumbsPictureOne` (9786–9832), one game of the "Library pictures, in one
  go" batch (`runThumbnailBatch`, 9835–9878).
* The Drive pull (2999–3016 → `writeSyncBytes`, 2454–2458), for every
  library game whose remote frame changed.

## Readers / object URLs
* `refreshHomeRecent` (5005–5209): `homeRenderGen` (4557) generation,
  `homeArtUrls` (4554) array of the committed render's URLs, per-tile
  `getRomFrame(..) → showPicture || getRomArt(..) → showPicture` (5094–5109),
  one `replaceChildren` commit then revoke the old array (5200–5207). Sort
  (`setRomsSort`, 1627) re-renders; the filter (`applyLibFilter`, 1702) only
  toggles `hidden` and never touches a picture, so it is not an event here.
* The menu head `buildTileMenuHead` (4800–4841): `tileMenuPicUrl` (4575),
  guarded by `tileMenuFor !== name`; `closeTileMenu` (4586) revokes it;
  `openTileMenu` (4873) closes, awaits, then sets `tileMenuFor`.
* The paused card `updatePausedCard` (9593–9611) paints the framebuffer
  synchronously under `currentOriginalName`'s label (no URL).

## How the model follows the method
Every `await` above is a split point; pending work is state:
`chain` (the frame store chain), `sess` (loadRom / unloadGame / renameGame
suspended at an await), `pulls` (Drive downloads in flight), `tJob` (the
batch's game in flight), `renders` (refreshHomeRecent suspended at one of its
three awaits), each tile's `fetch` stage (its IndexedDB read in flight), the
menu's `opens` and each menu picture element's `fetch`.

**IndexedDB.** `dbGet` / `dbPut` / `dbDelete` each open their own
transaction synchronously (530–554), all on the one store "blobs". A
read-only transaction sees every read-write transaction created before it
and none created after, so a read is modelled as taking its value *when it
is issued* (the snapshot is carried in the pending continuation) and a write
as taking effect *when it is issued*; the resolutions then fire in any order.
Arbitrary order over-approximates the browser (which in practice delivers in
issue order), so every invariant below holds a fortiori; every `bug_*` trace
was checked by hand to also respect issue order (see the report per bug).

**Pixels.** A picture is `Pic`: `owner` = the game whose screen the pixels
are, `stamp` = unique capture order. `core` is the game whose framebuffer
`wasm_fb_ptr` returns (the core `initFromEmscripten` last loaded; it is left
in place by `unloadGame` and by the batch, 9634–9635, 9682). A rename
relabels `owner` (the same game under a new name) – a modelling device only.

**Fixes.** `step` takes `fix : Bool`. `fix = false` is the code as it is;
`fix = true` adds the three smallest changes proposed in the report:
(1) `storeLastFrame`/`updatePausedCard` bail unless the core holds
`currentOriginalName` (a JS `fbGame` set right after `initFromEmscripten`)
-- no longer needed: loadRom now names a game only in the segment that
boots it (the load events of `step`, both `fix`), and `fix1_redundant`
proves the guard never fires;
(2) a synchronous `goneNames` set, filled at the start of delete and rename,
emptied by an import / a rename onto the name, checked right before every
frame `dbPut` (the chain, the batch, the pull);
(3) the batch writes with `store.add` (fails if a frame already exists), and
the menu paints only into a still-connected `pic`.
`gone` is maintained in both models but only consulted when `fix`.

## Abstractions (and why they do not affect the properties)
* Game names are `Nat`; the IndexedDB value is abstracted to its `Pic`.
* `lastFrameSig` (the tick's "unchanged" skip) is dropped: the tick always
  stores. More stores = more behaviours; bug traces use `forced`
  (visibilitychange), which never skips.
* `frameBlobFromFb` resolving `null` and quota aborts are dropped (they only
  remove a write).
* `sess` allows one of loadRom / unloadGame / renameGame at a time (the UI
  runs them one after another); `delKeys`/`importGame`/`thumbStart` need it
  idle. `loadBegin b` needs `b` in the library and not mid-delete (the ROM
  record is deleted first — `perGameKeys` lists it first, 1533 — so
  `launchRom` finds no bytes).
* The thumbs modal is focus-trapped over the library and the paused card
  (`openThumbsOffer` 9724–9731, `trapFocus`); closing it cancels the run
  (`closeThumbsModal` 9716–9720). So `unloadBegin`, `renBegin`, `openStart` need the modal
  down (`modalUp`). `loadBegin` and `delKeys` are NOT gated (a Drive download
  finishing launches; a pull's tombstone deletes).
* `renameGame`'s reads before its detach are merged into `renBegin`
  (captures before it are equivalent); a collision at `dbMoveKeys` time
  rolls back whole (`dbMoveKeys` aborts on an occupied target, 562–570).
* `deleteGameEverywhere` = `delKeys` (the `deleteKeys` loop; a write landing
  between its individual deletes is deleted anyway) then `delRecent`
  (the "recent" put + `markDelete`).
* Drive: only the frame upload queue `upQ` (`syncState.queueUp ∋ frame:n`)
  is kept, to show what a resurrected frame does next. The pull's own
  "recent" rewrite (3048) belongs to the Drive-library machine; its frame
  loop is modelled with the local library standing in for `lib.recents`.
* The batch's per-chunk checks (9815) are merged into the one in the capture
  segment (9822): one check instead of many allows more interleavings.
* Every menu open builds a head here, the paused card's session open too
  (it builds none, 4883–4891): more fetches, more URL traffic, a superset.
* A revoked blob URL on an <img> that already decoded may keep painting in
  some engines; "shown while revoked" is the property, not "broken image".
-/

namespace WebState.Thumbnails

/-! ## Values -/

/-- A picture's pixels: whose screen, and when captured. -/
structure Pic where
  owner : Nat
  stamp : Nat
  deriving DecidableEq, Repr

/-- The IndexedDB key a picture was read from. -/
inductive Key where
  | frame (n : Nat)
  | art (n : Nat)
  deriving DecidableEq, Repr

def Key.game : Key → Nat
  | .frame n => n
  | .art n => n

/-- Which array an object URL was pushed to: a render's `artUrls` (which
becomes `homeArtUrls` on commit), or `tileMenuPicUrl`. -/
inductive Arr where
  | grid (g : Nat)
  | menu
  deriving DecidableEq, Repr

structure Url where
  pic : Pic
  key : Key
  arr : Arr
  revoked : Nat   -- how many times URL.revokeObjectURL was called on it
  deriving DecidableEq, Repr

/-- A picture element's lazy fetch: `getRomFrame` in flight (with the value
its transaction will return), then `getRomArt` in flight, then settled. -/
inductive Fetch where
  | frameWait (snap : Option Pic)
  | artWait (snap : Option Pic)
  | done
  deriving DecidableEq, Repr

/-- A `.home-tile` built by one render (5058–5109). -/
structure Tile where
  gen : Nat           -- the closure's `gen`
  name : Nat          -- the closure's `romName`
  img : Option Nat    -- the URL its <img> shows
  fetch : Fetch
  deriving DecidableEq, Repr

/-- A `.tile-menu-pic` span built by `buildTileMenuHead` (4800–4819). -/
structure MPic where
  name : Nat
  img : Option Nat
  fetch : Fetch
  deriving DecidableEq, Repr

/-- `refreshHomeRecent` suspended at `getRecentMeta` (5007, before `++gen`),
at `dbKeys` (5038) or at `loadRomSizes` (5046). -/
inductive RStage where
  | pending
  | keys (g : Nat)
  | sizes (g : Nat)
  deriving DecidableEq, Repr

structure Render where
  roms : List Nat
  stage : RStage
  deriving DecidableEq, Repr

/-- A `frameStoreChain` link: name + pixels copied at call time; `put` once
`toBlob` called back and `dbPut` was issued. -/
structure Job where
  name : Nat
  pic : Pic
  put : Bool
  deriving DecidableEq, Repr

/-- The session transition in flight. `Option Nat` is the stamp of the
frame capture it awaits (`none`: storeLastFrame bailed, nothing awaited). -/
inductive Sess where
  | idle
  | loadOut (b : Nat) (w : Option Nat)   -- loadRom, awaiting outgoing store (7887–7890)
  | loadRestore (b : Nat)                -- loadRom, awaiting restoreSave (7920)
  | unloading (w : Option Nat)           -- unloadGame, awaiting its store (9642)
  | renaming (x y : Nat) (loaded : Bool) -- renameGame, awaiting dbMoveKeys (3344)
  deriving DecidableEq, Repr

/-- The batch's game in flight: booting/stepping (`enc = none`) or encoded. -/
structure TJob where
  name : Nat
  enc : Option Pic
  deriving DecidableEq, Repr

/-! ## State -/

structure State where
  -- IndexedDB
  lib : List Nat                       -- "recent" (names only)
  frame : Nat → Option Pic             -- "frame:<n>"
  art : Nat → Option Pic               -- "art:<n>"
  upQ : Nat → Bool                     -- syncState.queueUp ∋ "frame:<n>"
  -- the session
  cur : Option Nat                     -- currentOriginalName (∧ currentRomName)
  core : Option Nat                    -- whose framebuffer wasm_fb_ptr returns
  paused : Bool                        -- paused
  card : Option (Nat × Nat)            -- #home-paused: (label, pixel owner)
  sess : Sess
  chain : List Job                     -- frameStoreChain
  clock : Nat                          -- capture stamps
  gone : Nat → Bool                    -- (fix) goneNames
  delPending : List Nat                -- deleteGameEverywhere between its deletes and its "recent" put
  -- Drive pull: frame downloads in flight (2999–3016)
  pulls : Nat → Option (Nat × Pic)
  nPulls : Nat
  -- the batch (thumbsRun, 9703)
  tRun : Bool
  tCancel : Bool                       -- run.cancelled
  tCands : List Nat                    -- cands, from the index i on
  tJob : Option TJob
  clobbered : Bool                     -- ghost: the batch overwrote an existing frame
  -- the grid
  gen : Nat                            -- homeRenderGen
  shown : Nat                          -- gen of the tiles in #home-recent
  homeGen : Nat                        -- gen of the artUrls array homeArtUrls is
  renders : Nat → Option Render
  nRenders : Nat
  tiles : Nat → Option Tile
  nTiles : Nat
  urls : Nat → Option Url              -- every object URL ever created
  nUrls : Nat
  wsc : Bool                           -- ghost: a frame/art record changed since the last commit
  -- the per-game menu
  menuOpen : Bool                      -- !tileMenu.hidden
  menuFor : Option Nat                 -- tileMenuFor
  menuHead : Option Nat                -- the .tile-menu-pic attached in #tile-menu-head
  menuUrl : Option Nat                 -- tileMenuPicUrl
  opens : Nat → Option Nat             -- openTileMenu awaiting Promise.all (4875)
  nOpens : Nat
  mpics : Nat → Option MPic
  nPics : Nat

def init : State where
  lib := []
  frame := fun _ => none
  art := fun _ => none
  upQ := fun _ => false
  cur := none
  core := none
  paused := false
  card := none
  sess := .idle
  chain := []
  clock := 0
  gone := fun _ => false
  delPending := []
  pulls := fun _ => none
  nPulls := 0
  tRun := false
  tCancel := false
  tCands := []
  tJob := none
  clobbered := false
  gen := 0
  shown := 0
  homeGen := 0
  renders := fun _ => none
  nRenders := 0
  tiles := fun _ => none
  nTiles := 0
  urls := fun _ => none
  nUrls := 0
  wsc := false
  menuOpen := false
  menuFor := none
  menuHead := none
  menuUrl := none
  opens := fun _ => none
  nOpens := 0
  mpics := fun _ => none
  nPics := 0

/-! ## Events -/

inductive Ev where
  -- session and frame capture
  | loadBegin (b : Nat)   -- loadRom 7881–7890 (to the outgoing store's await / names)
  | loadOutDone           -- loadRom 7891–7920: outgoing store awaited; names set; restoreSave issued
  | loadInit              -- loadRom 7921: restoreSave resolved, initFromEmscripten
  | unloadBegin           -- unloadGame 9636–9642 (Close, and Delete/Remove of the loaded game)
  | unloadFinish          -- unloadGame 9643–9668
  | tick                  -- setInterval 4384
  | forced                -- visibilitychange 11217 / pagehide / beforeunload / saveToSlot 5573
  | pause                 -- showMainMenu 9358–9372 / togglePause 8217–8219 (+ updatePausedCard)
  | resume                -- resumeGame
  | encodeDone            -- chain head: toBlob called back → dbPut issued (4373–4375)
  | putDone               -- chain head: dbPut resolved → markUpload (4376)
  -- library
  | importGame (n : Nat)  -- addRecentRom 4460–4474 (ROM, art, index)
  | delKeys (n : Nat)     -- deleteGameEverywhere 3150 (deleteGameLocalData) / pull tombstone 2975
  | delRecent (n : Nat)   -- deleteGameEverywhere 3151–3161 ("recent" put, markDelete)
  | renBegin (x y : Nat)  -- renameGame 3252–3273
  | renMove               -- renameGame 3344–3366 (dbMoveKeys, one transaction)
  | removeLocal (n : Nat) -- removeGameFromDevice 3134–3135 (art goes, frame stays)
  | pullList (n : Nat)    -- pull 2999–3009: frame listed, download issued
  | pullWrite (i : Nat)   -- pull 3010–3013: download resolved, writeSyncBytes
  -- the batch
  | thumbStart            -- runThumbnailBatch 9835–9851
  | thumbInit             -- thumbsPictureOne 9786–9805 (check, initFromEmscripten)
  | thumbCapture          -- thumbsPictureOne 9806–9826 (last check, framebuffer copy, toBlob issued)
  | thumbPut              -- thumbsPictureOne 9827–9831 (dbPut, markUpload)
  | thumbCancel           -- closeThumbsModal 9716 / Stop 9884
  | thumbEnd              -- runThumbnailBatch finally 9866–9870
  -- the grid
  | renderStart           -- refreshHomeRecent 5005–5007 (getRecentMeta issued)
  | renderMeta (i : Nat)  -- 5008–5037 (++homeRenderGen; empty-library branch; dbKeys issued)
  | renderKeys (i : Nat)  -- 5039–5046 (gen check; loadRomSizes)
  | renderCommit (i : Nat) -- 5047–5209 (gen check; tiles + fetches; commit; revoke old array)
  | fetchFrame (t : Nat)  -- 5106–5108: getRomFrame resolved → showPicture || getRomArt
  | fetchArt (t : Nat)    -- 5108: getRomArt resolved → showPicture
  -- the menu
  | openStart (n : Nat)   -- openTileMenu 4873–4875 (closeTileMenu, Promise.all issued)
  | openDone (i : Nat)    -- openTileMenu 4876–4903 (tileMenuFor, buildTileMenuHead issues getRomFrame)
  | menuClose             -- closeTileMenu 4586–4603
  | mFetchFrame (e : Nat) -- 4809: getRomFrame resolved → frame || getRomArt
  | mFetchArt (e : Nat)   -- 4810–4818: blob → revoke old, create, paint
  deriving DecidableEq, Repr

/-! ## Step -/

def upd {α : Type} (f : Nat → α) (k : Nat) (v : α) : Nat → α :=
  fun m => if m = k then v else f m

theorem ifn {c : Prop} [Decidable c] (h : ¬c) {α : Sort _} {t e : α} :
    (if c then t else e) = e := by simp [h]

theorem ifp {c : Prop} [Decidable c] (h : c) {α : Sort _} {t e : α} :
    (if c then t else e) = t := by simp [h]

@[simp] theorem upd_apply {α : Type} (f : Nat → α) (k : Nat) (v : α) (m : Nat) :
    upd f k v m = if m = k then v else f m := rfl

def modalUp (s : State) : Bool := s.tRun && !s.tCancel

/-- `storeLastFrame` (4359–4381), the synchronous part: copy the framebuffer
and the name, append a link to the chain. Returns the stamp awaited. -/
def storeFrame (fix : Bool) (s : State) : State × Option Nat :=
  match s.cur, s.core with
  | some g, some c =>
    if fix && c != g then (s, none)
    else ({ s with chain := s.chain ++ [⟨g, ⟨c, s.clock⟩, false⟩], clock := s.clock + 1 },
          some s.clock)
  | _, _ => (s, none)

/-- The awaited chain promise has settled: no link at or before it is left. -/
def ready (s : State) : Option Nat → Bool
  | none => true
  | some v => s.chain.all (fun j => decide (v < j.pic.stamp))

/-- `updatePausedCard` (9593–9611). -/
def cardOf (fix : Bool) (s : State) : Option (Nat × Nat) :=
  match s.cur, s.core with
  | some g, some c => if fix && c != g then none else some (g, c)
  | _, _ => none

/-- Revoke every URL in the array `a` (`homeArtUrls.forEach(revoke)`). -/
def revokeArr (a : Arr) (urls : Nat → Option Url) : Nat → Option Url :=
  fun u => (urls u).map (fun r => if r.arr = a then { r with revoked := r.revoked + 1 } else r)

/-- Revoke one URL, if any (`if (tileMenuPicUrl) URL.revokeObjectURL(..)`). -/
def revokeOne (o : Option Nat) (urls : Nat → Option Url) : Nat → Option Url :=
  fun u => if o = some u then (urls u).map (fun r => { r with revoked := r.revoked + 1 }) else urls u

/-- `closeTileMenu` (4586–4603). -/
def closeMenu (s : State) : State :=
  if s.menuOpen then
    { s with menuOpen := false, menuHead := none, menuFor := none, menuUrl := none,
             urls := revokeOne s.menuUrl s.urls }
  else s

def relabel (x y : Nat) (m : Nat) : Nat := if m = x then y else m

/-- The tiles one render builds, at indices `base ..< base + roms.length`,
each with its `getRomFrame` issued now (5106). -/
def mkTiles (s : State) (g : Nat) (roms : List Nat) : Nat → Option Tile :=
  fun t =>
    if s.nTiles ≤ t ∧ t < s.nTiles + roms.length then
      some ⟨g, roms.getD (t - s.nTiles) 0, none, .frameWait (s.frame (roms.getD (t - s.nTiles) 0))⟩
    else s.tiles t

/-- `showPicture` succeeding (5094–5104): a URL into this render's array,
the tile's <img>. -/
def paintTile (s : State) (t : Nat) (tile : Tile) (p : Pic) (k : Key) : State :=
  { s with urls := upd s.urls s.nUrls (some ⟨p, k, .grid tile.gen, 0⟩),
           nUrls := s.nUrls + 1,
           tiles := upd s.tiles t (some { tile with img := some s.nUrls, fetch := .done }) }

/-- The menu head's `.then((blob) => ..)` (4810–4818). -/
def paintMenu (fix : Bool) (s : State) (e : Nat) (mp : MPic) (p : Pic) (k : Key) : State :=
  let s1 := { s with mpics := upd s.mpics e (some { mp with fetch := .done }) }
  if s.menuFor = some mp.name ∧ (fix = false ∨ s.menuHead = some e) then
    { s1 with urls := upd (revokeOne s.menuUrl s.urls) s.nUrls (some ⟨p, k, .menu, 0⟩),
              menuUrl := some s.nUrls, nUrls := s.nUrls + 1,
              mpics := upd s.mpics e (some { mp with img := some s.nUrls, fetch := .done }) }
  else s1

def step (fix : Bool) (s : State) : Ev → State
  -- loadRom 8012–8029: with a game in, persistAutoState then storeLastFrame
  -- (the outgoing picture) is awaited; with none, straight to 8036. (The load
  -- path, loadBegin/loadOutDone/loadInit, is as of the commit "web: a game is
  -- named only once its core and save are in; loads and closes take a token";
  -- at dd7ba741f the names switched before `await restoreSave`.)
  | .loadBegin b =>
    if s.sess = .idle ∧ b ∈ s.lib ∧ b ∉ s.delPending then
      match s.cur with
      | some _ => let r := storeFrame fix s; { r.1 with sess := .loadOut b r.2 }
      | none => { s with sess := .loadRestore b }
    else s
  -- loadRom 8030–8038: persistSave awaited; `await dbGet(save:b)`. The
  -- outgoing game stays named (and paused as it was) until the boot.
  | .loadOutDone =>
    match s.sess with
    | .loadOut b w => if ready s w then { s with sess := .loadRestore b } else s
    | _ => s
  -- loadRom 8039–8065: initFromEmscripten, and in the same segment
  -- currentRomName/currentOriginalName := b, lastFrameSig := null, paused := false.
  | .loadInit =>
    match s.sess with
    | .loadRestore b => { s with core := some b, cur := some b, paused := false, sess := .idle }
    | _ => s
  -- unloadGame 9636–9642: await storeLastFrame({force:true}).
  | .unloadBegin =>
    if s.sess = .idle ∧ s.cur.isSome ∧ modalUp s = false then
      let r := storeFrame fix s; { r.1 with sess := .unloading r.2 }
    else s
  -- unloadGame 9643–9656: names := null, paused := true; the core stays.
  | .unloadFinish =>
    match s.sess with
    | .unloading w => if ready s w then { s with cur := none, paused := true, sess := .idle } else s
    | _ => s
  -- 4384: setInterval(() => { if (!paused) storeLastFrame(); }, 60000)
  | .tick => if s.paused = false then (storeFrame fix s).1 else s
  -- 11217–11221 visibilitychange (and pagehide, beforeunload, saveToSlot):
  -- storeLastFrame({force:true}) whatever `paused` says.
  | .forced => (storeFrame fix s).1
  -- showMainMenu 9358–9372 / togglePause 8217–8219.
  | .pause =>
    if s.cur.isSome then
      let s2 := (storeFrame fix { s with paused := true }).1
      { s2 with card := cardOf fix s2 }
    else s
  | .resume => if s.cur.isSome then { s with paused := false } else s
  -- 4373–4375: the head link's toBlob called back; dbPut issued.
  -- (fix: skip the write if the name has gone.)
  | .encodeDone =>
    match s.chain with
    | j :: rest =>
      if j.put then s
      else if fix && s.gone j.name then { s with chain := rest }
      else { s with frame := upd s.frame j.name (some j.pic), wsc := true,
                    chain := { j with put := true } :: rest }
    | [] => s
  -- 4376: markUpload(frameKey(name)); the link settles.
  | .putDone =>
    match s.chain with
    | j :: rest => if j.put then { s with chain := rest, upQ := upd s.upQ j.name true } else s
    | [] => s
  -- addRecentRom 4460–4474.
  | .importGame n =>
    if s.sess = .idle ∧ n ∉ s.delPending then
      { s with lib := if n ∈ s.lib then s.lib else n :: s.lib,
               art := upd s.art n (some ⟨n, s.clock⟩), clock := s.clock + 1,
               gone := upd s.gone n false, wsc := true }
    else s
  -- deleteGameEverywhere 3150 → deleteGameLocalData → deleteKeys (rom, art,
  -- frame, ...). deleteGameAction (1920) unloads a loaded game first; the
  -- pull's tombstone path (2973) skips a loaded one.
  | .delKeys n =>
    if s.sess = .idle ∧ s.cur ≠ some n ∧ n ∉ s.delPending then
      { s with frame := upd s.frame n none, art := upd s.art n none, wsc := true,
               gone := upd s.gone n true, delPending := n :: s.delPending }
    else s
  -- deleteGameEverywhere 3151–3161: "recent" without it; markDelete.
  | .delRecent n =>
    if n ∈ s.delPending then
      { s with lib := s.lib.filter (· ≠ n), delPending := s.delPending.filter (· ≠ n),
               upQ := upd s.upQ n false }
    else s
  -- renameGame 3252–3273: a loaded game is detached (currentOriginalName := null).
  | .renBegin x y =>
    if s.sess = .idle ∧ modalUp s = false ∧ x ∈ s.lib ∧ x ≠ y ∧ x ∉ s.delPending ∧ y ∉ s.delPending then
      let l := decide (s.cur = some x)
      { s with cur := if l then none else s.cur, gone := upd s.gone x true,
               sess := .renaming x y l }
    else s
  -- renameGame 3344–3366: dbMoveKeys moves every key and "recent" in one
  -- transaction; a collision aborts it whole and the session is put back.
  | .renMove =>
    match s.sess with
    | .renaming x y l =>
      if y ∈ s.lib ∨ (s.frame y).isSome ∨ (s.art y).isSome then
        { s with cur := if l then some x else s.cur, gone := upd s.gone x false, sess := .idle }
      else
        let rl := relabel x y
        { s with
          frame := upd (upd s.frame y ((s.frame x).map fun p => { p with owner := rl p.owner })) x none,
          art := upd (upd s.art y ((s.art x).map fun p => { p with owner := rl p.owner })) x none,
          lib := y :: s.lib.filter (· ≠ x),
          core := s.core.map rl,
          card := s.card.map (fun c => (rl c.1, rl c.2)),
          cur := if l then some y else s.cur,
          gone := upd s.gone y false,
          upQ := upd (upd s.upQ y (s.upQ x)) x false,
          wsc := true, sess := .idle }
    | _ => s
  -- removeGameFromDevice 3134–3135: bytes (not the frame) and session go.
  | .removeLocal n =>
    if n ∈ s.lib then { s with art := upd s.art n none, wsc := true } else s
  -- pull 2999–3009: a library game's remote frame, not the loaded game.
  | .pullList n =>
    if n ∈ s.lib ∧ s.cur ≠ some n then
      { s with pulls := upd s.pulls s.nPulls (some (n, ⟨n, s.clock⟩)),
               nPulls := s.nPulls + 1, clock := s.clock + 1 }
    else s
  -- pull 3010–3013: driveDownload resolved; writeSyncBytes → dbPut.
  | .pullWrite i =>
    match s.pulls i with
    | some (n, p) =>
      let s1 := { s with pulls := upd s.pulls i none }
      if fix && s.gone n then s1 else { s1 with frame := upd s.frame n (some p), wsc := true }
    | none => s
  -- runThumbnailBatch 9835–9851: candidates = library games with no frame.
  | .thumbStart =>
    if s.tRun = false ∧ s.cur = none ∧ s.sess = .idle then
      { s with tRun := true, tCancel := false,
               tCands := s.lib.filter (fun n => (s.frame n).isNone), tJob := none }
    else s
  -- thumbsPictureOne 9800–9805: `if (run.cancelled || currentRomName ..)
  -- return false`, then initFromEmscripten(thumb.<ext>).
  | .thumbInit =>
    if s.tRun ∧ s.tJob = none then
      match s.tCands with
      | n :: rest =>
        if s.tCancel ∨ s.cur ≠ none then { s with tCands := rest }
        else { s with core := some n, tJob := some ⟨n, none⟩ }
      | [] => s
    else s
  -- thumbsPictureOne 9813–9826: the stepping loop's checks, the last one in
  -- the same segment as the framebuffer copy; frameBlobFromFb issued.
  | .thumbCapture =>
    match s.tJob, s.core with
    | some ⟨n, none⟩, some c =>
      if s.tCancel ∨ s.cur ≠ none then { s with tJob := none, tCands := s.tCands.tail }
      else { s with tJob := some ⟨n, some ⟨c, s.clock⟩⟩, clock := s.clock + 1 }
    | some ⟨_, none⟩, none => { s with tJob := none, tCands := s.tCands.tail }
    | _, _ => s
  -- thumbsPictureOne 9827–9831: dbPut(frameKey(name)), markUpload — no
  -- re-check of anything. (fix: add-only, and skip a gone name.)
  | .thumbPut =>
    match s.tJob with
    | some ⟨n, some p⟩ =>
      let s1 := { s with tJob := none, tCands := s.tCands.tail }
      if fix && (s.gone n || (s.frame n).isSome) then s1
      else { s1 with frame := upd s.frame n (some p), clobbered := s.clobbered || (s.frame n).isSome,
                     upQ := upd s.upQ n true, wsc := true }
    | _ => s
  | .thumbCancel => if s.tRun then { s with tCancel := true } else s
  | .thumbEnd =>
    if s.tRun ∧ s.tJob = none ∧ (s.tCands = [] ∨ s.tCancel) then { s with tRun := false } else s
  -- refreshHomeRecent 5005–5007: getRecentMeta issued (gen NOT yet taken).
  | .renderStart =>
    { s with renders := upd s.renders s.nRenders (some ⟨s.lib, .pending⟩), nRenders := s.nRenders + 1 }
  -- 5008–5037: gen = ++homeRenderGen. Empty library: commit nothing,
  -- revoke homeArtUrls, homeArtUrls = artUrls (5011–5024).
  | .renderMeta i =>
    match s.renders i with
    | some ⟨roms, .pending⟩ =>
      if roms = [] then
        { s with gen := s.gen + 1, shown := s.gen + 1, homeGen := s.gen + 1,
                 urls := revokeArr (.grid s.homeGen) s.urls, renders := upd s.renders i none,
                 wsc := false }
      else { s with gen := s.gen + 1, renders := upd s.renders i (some ⟨roms, .keys (s.gen + 1)⟩) }
    | _ => s
  -- 5039: `if (gen !== homeRenderGen) return;`
  | .renderKeys i =>
    match s.renders i with
    | some ⟨roms, .keys g⟩ =>
      if g = s.gen then { s with renders := upd s.renders i (some ⟨roms, .sizes g⟩) }
      else { s with renders := upd s.renders i none }
    | _ => s
  -- 5047–5207: gen check; build every tile and issue its getRomFrame;
  -- replaceChildren; revoke homeArtUrls; homeArtUrls = artUrls.
  | .renderCommit i =>
    match s.renders i with
    | some ⟨roms, .sizes g⟩ =>
      if g = s.gen then
        { s with tiles := mkTiles s g roms, nTiles := s.nTiles + roms.length,
                 urls := revokeArr (.grid s.homeGen) s.urls, homeGen := g, shown := g,
                 wsc := false, renders := upd s.renders i none }
      else { s with renders := upd s.renders i none }
    | _ => s
  -- 5094–5108: showPicture(frame, ..) — `if (!blob || gen !== homeRenderGen)
  -- return false` — else getRomArt issued.
  | .fetchFrame t =>
    match s.tiles t with
    | some tile =>
      match tile.fetch with
      | .frameWait (some p) =>
        if tile.gen = s.gen then paintTile s t tile p (.frame tile.name)
        else { s with tiles := upd s.tiles t (some { tile with fetch := .artWait (s.art tile.name) }) }
      | .frameWait none =>
        { s with tiles := upd s.tiles t (some { tile with fetch := .artWait (s.art tile.name) }) }
      | _ => s
    | none => s
  | .fetchArt t =>
    match s.tiles t with
    | some tile =>
      match tile.fetch with
      | .artWait (some p) =>
        if tile.gen = s.gen then paintTile s t tile p (.art tile.name)
        else { s with tiles := upd s.tiles t (some { tile with fetch := .done }) }
      | .artWait none => { s with tiles := upd s.tiles t (some { tile with fetch := .done }) }
      | _ => s
    | none => s
  -- openTileMenu 4873–4875 (the long-press timer 4954 calls it with no
  -- tileMenuFor check).
  | .openStart n =>
    if modalUp s = false then
      let s1 := closeMenu s
      { s1 with opens := upd s1.opens s1.nOpens (some n), nOpens := s1.nOpens + 1 }
    else s
  -- 4876–4899: tileMenuFor := name; buildTileMenuHead: a new pic span,
  -- getRomFrame issued, tileMenuHead.replaceChildren(pic, text).
  | .openDone i =>
    match s.opens i with
    | some n =>
      { s with opens := upd s.opens i none, menuOpen := true, menuFor := some n,
               menuHead := some s.nPics,
               mpics := upd s.mpics s.nPics (some ⟨n, none, .frameWait (s.frame n)⟩),
               nPics := s.nPics + 1 }
    | none => s
  | .menuClose => closeMenu s
  | .mFetchFrame e =>
    match s.mpics e with
    | some mp =>
      match mp.fetch with
      | .frameWait (some p) => paintMenu fix s e mp p (.frame mp.name)
      | .frameWait none => { s with mpics := upd s.mpics e (some { mp with fetch := .artWait (s.art mp.name) }) }
      | _ => s
    | none => s
  | .mFetchArt e =>
    match s.mpics e with
    | some mp =>
      match mp.fetch with
      | .artWait (some p) => paintMenu fix s e mp p (.art mp.name)
      | .artWait none => { s with mpics := upd s.mpics e (some { mp with fetch := .done }) }
      | _ => s
    | none => s

def run (fix : Bool) (s : State) : List Ev → State
  | [] => s
  | e :: es => run fix (step fix s e) es

inductive Reachable (fix : Bool) : State → Prop
  | init : Reachable fix init
  | step {s} (e : Ev) : Reachable fix s → Reachable fix (step fix s e)

theorem reachable_run (fix : Bool) (es : List Ev) :
    ∀ s, Reachable fix s → Reachable fix (run fix s es) := by
  induction es with
  | nil => intro s h; exact h
  | cons e es ih => intro s h; exact ih _ (Reachable.step e h)

/-! ## Counterexamples (the code as it is, `fix = false`) -/

/-- A tile on screen shows pixels that are not its game's. -/
def tileShowsForeign (s : State) (t : Nat) : Bool :=
  match s.tiles t with
  | some tile =>
    tile.gen == s.shown &&
    match tile.img with
    | some u => match s.urls u with
      | some url => url.pic.owner != tile.name
      | none => false
    | none => false
  | none => false

/-- Game 0 running; launch game 1. At dd7ba741f its names were set before its
core was loaded, and the tab hidden during `await restoreSave`
(visibilitychange → storeLastFrame({force:true})) filed game 0's
framebuffer as "frame:1": the grid showed game 0's screen on game 1's tile.
Game 1 is now named only in the segment that boots it, so the capture in
that window files game 0's screen under game 0. (`cur_is_core` below: for
every reachable state, whatever `fix`, the named game is the one in the core.) -/
def switchTrace : List Ev :=
  [.importGame 0, .importGame 1, .loadBegin 0, .loadInit,   -- game 0 running
   .loadBegin 1,                  -- launch game 1: outgoing capture of 0 queued
   .encodeDone, .putDone,         -- game 0's picture filed as frame:0
   .loadOutDone,                  -- await dbGet(save:1): game 0 still named
   .forced,                       -- visibilitychange: files game 0's screen as 0's
   .loadInit,                     -- initFromEmscripten(game 1), names := 1
   .encodeDone, .putDone,
   .renderStart, .renderMeta 0, .renderKeys 0, .renderCommit 0,
   .fetchFrame 0, .fetchFrame 1]

theorem regress_switch_files_old_pixels_under_new_name :
    (run false init switchTrace).frame 1 = none ∧
    ((run false init switchTrace).frame 0).map Pic.owner = some 0 ∧
    (run false init switchTrace).upQ 1 = false ∧
    tileShowsForeign (run false init switchTrace) 0 = false ∧
    tileShowsForeign (run false init switchTrace) 1 = false := by decide

/-- The same window from a closed game: the core keeps the closed game
(unloadGame), and at dd7ba741f the next launch named game 1 at once, so the
60 s tick filed game 0's screen as "frame:1". The launch no longer names
anything before its boot, and the closed game stays paused. -/
def switchAfterCloseTrace : List Ev :=
  [.importGame 0, .importGame 1, .loadBegin 0, .loadInit,
   .unloadBegin, .encodeDone, .putDone, .unloadFinish,       -- Close game 0
   .loadBegin 1,                                           -- await dbGet(save:1)
   .tick,                                                  -- the 60 s tick
   .encodeDone]

theorem regress_switch_after_close :
    (run false init switchAfterCloseTrace).frame 1 = none := by decide

/-- At dd7ba741f the paused card could be labelled with one game and painted
with another in the same window; now it is game 0's, both ways. -/
theorem regress_card_label_mismatch :
    (run false init [.importGame 0, .importGame 1, .loadBegin 0, .loadInit,
       .loadBegin 1, .encodeDone, .putDone, .loadOutDone, .pause]).card = some (0, 0) := by
  decide

/-- An orphan frame: a picture record for a game that is not in the library
and not being deleted or renamed. -/
def orphan (s : State) (n : Nat) : Bool :=
  (s.frame n).isSome && !(s.lib.contains n) && !(s.delPending.contains n)

/-- Delete the loaded game: unloadGame awaits the chain promise as it was
when it captured; a visibilitychange during that encode appends a second
link it does not await. deleteGameEverywhere's deletes are issued first,
then the second link's dbPut writes "frame:0" back, after the game has left
the library. (Here its markUpload lands before the delete's markDelete, the
likelier order, so Drive is spared; the local record is not.) -/
def deleteTrace : List Ev :=
  [.importGame 0, .loadBegin 0, .loadInit, .pause,
   .encodeDone, .putDone,                  -- the pause's picture
   .unloadBegin,                           -- Delete → unloadGame: link J1 awaited
   .forced,                                -- visibilitychange: link J2 (not awaited)
   .encodeDone, .putDone,                  -- J1 settles
   .unloadFinish,                          -- names := null
   .delKeys 0,                             -- deleteKeys: rom, art, frame, ...
   .encodeDone, .putDone,                  -- J2: dbPut(frame:0), markUpload
   .delRecent 0]                           -- "recent" without it, markDelete

theorem bug_delete_resurrects_frame :
    orphan (run false init deleteTrace) 0 = true := by decide

/-- A Drive pull downloading a library game's frame while the user deletes
it writes the frame back afterwards. -/
theorem bug_pull_resurrects_frame :
    orphan (run false init [.importGame 0, .pullList 0, .delKeys 0, .delRecent 0, .pullWrite 0]) 0
      = true := by decide

/-- The batch pictures a game that a delete (the pull's tombstone path, not
behind the modal) removes while it is being stepped; its dbPut has no
re-check. -/
theorem bug_thumbs_resurrects_frame :
    let s := run false init [.importGame 0, .thumbStart, .thumbInit,
                             .delKeys 0, .delRecent 0, .thumbCapture, .thumbPut]
    orphan s 0 = true ∧ s.upQ 0 = true := by decide

/-- The batch's candidate list is read once at the start; a frame that
arrives for a candidate before its turn (a Drive pull) is overwritten by the
batch's boot/title picture, and that is queued to overwrite Drive's. -/
theorem bug_thumbs_overwrites_frame :
    let s := run false init [.importGame 0, .thumbStart, .pullList 0, .pullWrite 0,
                             .thumbInit, .thumbCapture, .thumbPut]
    s.clobbered = true ∧ s.upQ 0 = true := by decide

/-- The menu shows a revoked URL: two opens of one game overlap (the
long-press timer at 450 ms, then Android's contextmenu, while the first
open's Promise.all is pending — the contextmenu guard reads tileMenuFor,
still null). The first head's getRomFrame misses, a frame lands (a pull),
the second head's getRomFrame hits and paints; then the first head's
getRomArt resolves, passes `tileMenuFor === name`, revokes the URL the
second head is showing and paints a detached span. -/
def menuTrace : List Ev :=
  [.importGame 0,                 -- art:0 exists, frame:0 does not
   .openStart 0, .openStart 0,    -- two openTileMenu(0) in flight
   .openDone 0,                   -- head pic 0, getRomFrame issued (none)
   .pullList 0, .pullWrite 0,     -- frame:0 lands
   .openDone 1,                   -- head pic 1 (pic 0 detached), getRomFrame issued (some)
   .mFetchFrame 0,                -- miss → getRomArt issued
   .mFetchFrame 1,                -- hit → URL 0 into pic 1
   .mFetchArt 0]                  -- revokes URL 0, URL 1 into detached pic 0

def menuShowsRevoked (s : State) : Bool :=
  match s.menuHead with
  | some e => match s.mpics e with
    | some mp => match mp.img with
      | some u => match s.urls u with
        | some url => decide (url.revoked ≥ 1)
        | none => false
      | none => false
    | none => false
  | none => false

theorem bug_menu_revokes_displayed_url :
    menuShowsRevoked (run false init menuTrace) = true := by decide

/-! ## The grid and its object URLs (any `fix`) -/

def RStage.gen? : RStage → Option Nat
  | .pending => none
  | .keys g => some g
  | .sizes g => some g

/-- An on-screen tile agrees with the database: its read in flight carries
the current record, and a settled tile shows the frame, else the art. -/
def FreshTile (s : State) (tile : Tile) : Prop :=
  match tile.fetch with
  | .frameWait snap => snap = s.frame tile.name
  | .artWait snap => s.frame tile.name = none ∧ snap = s.art tile.name
  | .done =>
    match s.frame tile.name with
    | some p => ∃ u url, tile.img = some u ∧ s.urls u = some url ∧ url.pic = p
    | none =>
      match s.art tile.name with
      | some p => ∃ u url, tile.img = some u ∧ s.urls u = some url ∧ url.pic = p
      | none => tile.img = none

structure GInv (s : State) : Prop where
  shownLe : s.shown ≤ s.gen
  home : s.homeGen = s.shown
  rendersFresh : ∀ i, s.nRenders ≤ i → s.renders i = none
  rendGen : ∀ i r g, s.renders i = some r → r.stage.gen? = some g → g ≤ s.gen ∧ (g = s.gen → s.shown < g)
  rendUniq : ∀ i j ri rj g, s.renders i = some ri → s.renders j = some rj →
    ri.stage.gen? = some g → rj.stage.gen? = some g → i = j
  live : s.shown = s.gen ∨ ∃ i r, s.renders i = some r ∧ r.stage.gen? = some s.gen
  tilesFresh : ∀ t, s.nTiles ≤ t → s.tiles t = none
  tileGen : ∀ t tile, s.tiles t = some tile → tile.gen ≤ s.shown
  urlsFresh : ∀ u, s.nUrls ≤ u → s.urls u = none
  tileImg : ∀ t tile u, s.tiles t = some tile → tile.img = some u →
    ∃ url, s.urls u = some url ∧ url.arr = .grid tile.gen ∧
      (url.key = .frame tile.name ∨ url.key = .art tile.name)
  urlGrid : ∀ u url g, s.urls u = some url → url.arr = .grid g →
    g ≤ s.shown ∧ (g = s.shown → url.revoked = 0) ∧ (g < s.shown → url.revoked = 1)
  menuUrlOk : ∀ u, s.menuUrl = some u → ∃ url, s.urls u = some url ∧ url.arr = .menu ∧ url.revoked = 0
  menuUrlOpen : s.menuUrl.isSome → s.menuOpen = true
  menuForOpen : s.menuFor.isSome → s.menuOpen = true
  urlMenu : ∀ u url, s.urls u = some url → url.arr = .menu →
    url.revoked ≤ 1 ∧ (url.revoked = 0 → s.menuUrl = some u)
  mpicsFresh : ∀ e, s.nPics ≤ e → s.mpics e = none
  mpicImg : ∀ e mp u, s.mpics e = some mp → mp.img = some u →
    ∃ url, s.urls u = some url ∧ url.arr = .menu ∧ (url.key = .frame mp.name ∨ url.key = .art mp.name)
  fresh : s.wsc = false → s.shown = s.gen → ∀ t tile, s.tiles t = some tile →
    tile.gen = s.shown → FreshTile s tile
  tilePend : ∀ t tile, s.tiles t = some tile → tile.fetch ≠ .done → tile.img = none
  mpicPend : ∀ e mp, s.mpics e = some mp → mp.fetch ≠ .done → mp.img = none

theorem ginv_init : GInv init := by
  constructor <;> simp [init, RStage.gen?]

/-- Everything `GInv` reads except the records and `wsc`. -/
def gview (s : State) :=
  (s.gen, s.shown, s.homeGen, s.renders, s.nRenders, s.tiles, s.nTiles, s.urls, s.nUrls,
   s.menuOpen, s.menuFor, s.menuUrl, s.mpics, s.nPics)

theorem ginv_same {s s' : State} (h : GInv s) (hv : gview s' = gview s)
    (hw : s'.wsc = true ∨ (s'.wsc = s.wsc ∧ s'.frame = s.frame ∧ s'.art = s.art)) : GInv s' := by
  simp only [gview, Prod.mk.injEq] at hv
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14⟩ := hv
  have hf : s'.wsc = false → s'.shown = s'.gen → ∀ t tile, s'.tiles t = some tile →
      tile.gen = s'.shown → FreshTile s' tile := by
    rcases hw with hw | ⟨hw, hf, ha⟩
    · intro h0; simp [hw] at h0
    · intro h0 hsg t tile ht htg
      have := h.fresh (by rw [← hw]; exact h0) (by rw [← h1, ← h2]; exact hsg) t tile
        (by rw [← h6]; exact ht) (by rw [← h2]; exact htg)
      unfold FreshTile at this ⊢
      rw [hf, ha, h8]; exact this
  exact {
    shownLe := by rw [h1, h2]; exact h.shownLe
    home := by rw [h3, h2]; exact h.home
    rendersFresh := by rw [h4, h5]; exact h.rendersFresh
    rendGen := by rw [h4, h1, h2]; exact h.rendGen
    rendUniq := by rw [h4]; exact h.rendUniq
    live := by rw [h4, h1, h2]; exact h.live
    tilesFresh := by rw [h6, h7]; exact h.tilesFresh
    tileGen := by rw [h6, h2]; exact h.tileGen
    urlsFresh := by rw [h8, h9]; exact h.urlsFresh
    tileImg := by rw [h6, h8]; exact h.tileImg
    urlGrid := by rw [h8, h2]; exact h.urlGrid
    menuUrlOk := by rw [h12, h8]; exact h.menuUrlOk
    menuUrlOpen := by rw [h12, h10]; exact h.menuUrlOpen
    menuForOpen := by rw [h11, h10]; exact h.menuForOpen
    urlMenu := by rw [h8, h12]; exact h.urlMenu
    mpicsFresh := by rw [h13, h14]; exact h.mpicsFresh
    mpicImg := by rw [h13, h8]; exact h.mpicImg
    fresh := hf
    tilePend := by rw [h6]; exact h.tilePend
    mpicPend := by rw [h13]; exact h.mpicPend }

theorem gview_storeFrame (fix : Bool) (s : State) : gview (storeFrame fix s).1 = gview s := by
  unfold storeFrame; split
  · split <;> rfl
  · rfl

theorem storeFrame_db (fix : Bool) (s : State) :
    (storeFrame fix s).1.wsc = s.wsc ∧ (storeFrame fix s).1.frame = s.frame ∧
    (storeFrame fix s).1.art = s.art := by
  unfold storeFrame; split
  · split <;> exact ⟨rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl⟩

theorem freshTile_transfer {s s' : State} (tile : Tile) (hf : s'.frame = s.frame) (ha : s'.art = s.art)
    (hu : ∀ u url, s.urls u = some url → ∃ url', s'.urls u = some url' ∧ url'.pic = url.pic)
    (h : FreshTile s tile) : FreshTile s' tile := by
  unfold FreshTile at h ⊢
  rw [hf, ha]
  split at h
  · exact h
  · exact h
  · split at h
    · obtain ⟨u, url, h1, h2, h3⟩ := h
      obtain ⟨url', h4, h5⟩ := hu u url h2
      exact ⟨u, url', h1, h4, h5.trans h3⟩
    · split at h
      · obtain ⟨u, url, h1, h2, h3⟩ := h
        obtain ⟨url', h4, h5⟩ := hu u url h2
        exact ⟨u, url', h1, h4, h5.trans h3⟩
      · exact h

theorem revokeArr_some {a : Arr} {urls : Nat → Option Url} {u : Nat} {url' : Url}
    (h : revokeArr a urls u = some url') :
    ∃ url, urls u = some url ∧ url'.pic = url.pic ∧ url'.key = url.key ∧ url'.arr = url.arr ∧
      url'.revoked = (if url.arr = a then url.revoked + 1 else url.revoked) := by
  unfold revokeArr at h
  cases hu : urls u with
  | none => simp [hu] at h
  | some url =>
    simp only [hu, Option.map_some, Option.some.injEq] at h
    refine ⟨url, rfl, ?_⟩
    split at h <;> subst h <;> simp_all

theorem revokeArr_of {a : Arr} {urls : Nat → Option Url} {u : Nat} {url : Url}
    (h : urls u = some url) : ∃ url', revokeArr a urls u = some url' ∧ url'.pic = url.pic := by
  unfold revokeArr; rw [h]; simp only [Option.map_some, Option.some.injEq, exists_eq_left']
  split <;> rfl

theorem revokeArr_none {a : Arr} {urls : Nat → Option Url} {u : Nat}
    (h : urls u = none) : revokeArr a urls u = none := by
  unfold revokeArr; rw [h]; rfl

theorem revokeOne_some {o : Option Nat} {urls : Nat → Option Url} {u : Nat} {url' : Url}
    (h : revokeOne o urls u = some url') :
    ∃ url, urls u = some url ∧ url'.pic = url.pic ∧ url'.key = url.key ∧ url'.arr = url.arr ∧
      url'.revoked = (if o = some u then url.revoked + 1 else url.revoked) := by
  unfold revokeOne at h
  split at h
  · cases hu : urls u with
    | none => simp [hu] at h
    | some url =>
      simp only [hu, Option.map_some, Option.some.injEq] at h
      subst h; exact ⟨url, rfl, rfl, rfl, rfl, by simp_all⟩
  · exact ⟨url', h, rfl, rfl, rfl, by simp_all⟩

theorem revokeOne_of {o : Option Nat} {urls : Nat → Option Url} {u : Nat} {url : Url}
    (h : urls u = some url) : ∃ url', revokeOne o urls u = some url' ∧ url'.pic = url.pic := by
  unfold revokeOne; split
  · rw [h]; exact ⟨_, rfl, rfl⟩
  · exact ⟨url, h, rfl⟩

theorem revokeOne_none {o : Option Nat} {urls : Nat → Option Url} {u : Nat}
    (h : urls u = none) : revokeOne o urls u = none := by
  unfold revokeOne; rw [h]; split <;> rfl

section revoke
variable {s : State} (h : GInv s)
include h

theorem rv_urlGrid (g : Nat) (hlt : s.shown < g) :
    ∀ u url g', revokeArr (.grid s.homeGen) s.urls u = some url → url.arr = .grid g' →
      g' ≤ g ∧ (g' = g → url.revoked = 0) ∧ (g' < g → url.revoked = 1) := by
  intro u url' g' hu ha
  obtain ⟨url, h1, -, -, h3, h4⟩ := revokeArr_some hu
  rw [h3] at ha
  obtain ⟨g1, g2, g3⟩ := h.urlGrid u url g' h1 ha
  rw [h4, ha, h.home]
  refine ⟨by omega, by omega, fun _ => ?_⟩
  split
  · rename_i hg; cases hg; simp [g2 rfl]
  · rename_i hg; exact g3 (by
      have : g' ≠ s.shown := fun e => hg (by rw [e]); omega)

theorem rv_tileImg (t : Nat) (tile : Tile) (u : Nat) (ht : s.tiles t = some tile) (hi : tile.img = some u) :
    ∃ url, revokeArr (.grid s.homeGen) s.urls u = some url ∧ url.arr = .grid tile.gen ∧
      (url.key = .frame tile.name ∨ url.key = .art tile.name) := by
  obtain ⟨url, h1, h2, h3⟩ := h.tileImg t tile u ht hi
  obtain ⟨url', h4, -⟩ := revokeArr_of (a := .grid s.homeGen) h1
  refine ⟨url', h4, ?_⟩
  obtain ⟨url0, h6, -, h7, h8, -⟩ := revokeArr_some h4
  rw [h1] at h6; cases h6; rw [h7, h8]; exact ⟨h2, h3⟩

theorem rv_menuUrlOk : ∀ u, s.menuUrl = some u →
    ∃ url, revokeArr (.grid s.homeGen) s.urls u = some url ∧ url.arr = .menu ∧ url.revoked = 0 := by
  intro u hu
  obtain ⟨url, h1, h2, h3⟩ := h.menuUrlOk u hu
  obtain ⟨url', h4, -⟩ := revokeArr_of (a := .grid s.homeGen) h1
  obtain ⟨url0, h6, -, -, h8, h9⟩ := revokeArr_some h4
  rw [h1] at h6; cases h6
  exact ⟨url', h4, by rw [h8, h2], by rw [h9, h2]; simp [h3]⟩

theorem rv_urlMenu : ∀ u url, revokeArr (.grid s.homeGen) s.urls u = some url → url.arr = .menu →
    url.revoked ≤ 1 ∧ (url.revoked = 0 → s.menuUrl = some u) := by
  intro u url' hu ha
  obtain ⟨url, h1, -, -, h3, h4⟩ := revokeArr_some hu
  rw [h3] at ha
  rw [h4, ha]; simp only [reduceCtorEq, ite_false]
  exact h.urlMenu u url h1 ha

theorem rv_mpicImg : ∀ e mp u, s.mpics e = some mp → mp.img = some u →
    ∃ url, revokeArr (.grid s.homeGen) s.urls u = some url ∧ url.arr = .menu ∧
      (url.key = .frame mp.name ∨ url.key = .art mp.name) := by
  intro e mp u he hi
  obtain ⟨url, h1, h2, h3⟩ := h.mpicImg e mp u he hi
  obtain ⟨url', h4, -⟩ := revokeArr_of (a := .grid s.homeGen) h1
  obtain ⟨url0, h6, -, h7, h8, -⟩ := revokeArr_some h4
  rw [h1] at h6; cases h6
  exact ⟨url', h4, by rw [h8, h2], by rw [h7]; exact h3⟩

end revoke

local macro "om" : tactic => `(tactic| ((try dsimp only at *); omega))

theorem ginv_renderStart (fix : Bool) (s : State) (h : GInv s) : GInv (step fix s .renderStart) := by
  simp only [step]
  have hfr := h.rendersFresh s.nRenders (Nat.le_refl _)
  exact { h with
    rendersFresh := by
      intro i hi; simp only [upd_apply]
      rw [ifn (by om)]; exact h.rendersFresh i (by om)
    rendGen := by
      intro i r g hr hg; simp only [upd_apply] at hr
      split at hr
      · simp at hr; subst hr; simp [RStage.gen?] at hg
      · exact h.rendGen i r g hr hg
    rendUniq := by
      intro i j ri rj g hi hj gi gj; simp only [upd_apply] at hi hj
      split at hi
      · simp at hi; subst hi; simp [RStage.gen?] at gi
      · split at hj
        · simp at hj; subst hj; simp [RStage.gen?] at gj
        · exact h.rendUniq i j ri rj g hi hj gi gj
    live := by
      rcases h.live with hl | ⟨i, r, hr, hg⟩
      · exact Or.inl hl
      · refine Or.inr ⟨i, r, ?_, hg⟩
        simp only [upd_apply]; rw [ifn]; exact hr
        intro hi; subst hi; rw [hfr] at hr; cases hr }

theorem ginv_renderMeta (fix : Bool) (s : State) (h : GInv s) (i : Nat) :
    GInv (step fix s (.renderMeta i)) := by
  simp only [step]
  split
  · rename_i roms hri
    have hsl := h.shownLe
    split
    · -- the empty library: commit nothing, revoke homeArtUrls
      exact {
        shownLe := Nat.le_refl _
        home := rfl
        rendersFresh := by
          intro j hj; simp only [upd_apply]; split
          · rfl
          · exact h.rendersFresh j hj
        rendGen := by
          intro j r g hr hg; simp only [upd_apply] at hr
          split at hr
          · cases hr
          · have := h.rendGen j r g hr hg; om
        rendUniq := by
          intro j k rj rk g hj hk gj gk; simp only [upd_apply] at hj hk
          split at hj
          · cases hj
          · split at hk
            · cases hk
            · exact h.rendUniq j k rj rk g hj hk gj gk
        live := Or.inl rfl
        tilesFresh := h.tilesFresh
        tileGen := by intro t tile ht; have := h.tileGen t tile ht; om
        urlsFresh := fun u hu => revokeArr_none (h.urlsFresh u hu)
        tileImg := by
          intro t tile u ht hi
          obtain ⟨url, h1, h2, h3⟩ := h.tileImg t tile u ht hi
          obtain ⟨url', h4, h5⟩ := revokeArr_of (a := .grid s.homeGen) h1
          refine ⟨url', h4, ?_⟩
          obtain ⟨url0, h6, -, h7, h8, -⟩ := revokeArr_some h4
          rw [h1] at h6; cases h6; rw [h7, h8]; exact ⟨h2, h3⟩
        urlGrid := rv_urlGrid h _ (by om)
        menuUrlOk := by
          intro u hu
          obtain ⟨url, h1, h2, h3⟩ := h.menuUrlOk u hu
          obtain ⟨url', h4, -⟩ := revokeArr_of (a := .grid s.homeGen) h1
          obtain ⟨url0, h6, -, -, h8, h9⟩ := revokeArr_some h4
          rw [h1] at h6; cases h6
          exact ⟨url', h4, by rw [h8, h2], by rw [h9, h2]; simp [h3]⟩
        menuUrlOpen := h.menuUrlOpen
        menuForOpen := h.menuForOpen
        urlMenu := by
          intro u url' hu ha
          obtain ⟨url, h1, -, -, h3, h4⟩ := revokeArr_some hu
          rw [h3] at ha
          rw [h4, ha]; simp only [reduceCtorEq, ite_false]
          exact h.urlMenu u url h1 ha
        mpicsFresh := h.mpicsFresh
        mpicImg := by
          intro e mp u he hi
          obtain ⟨url, h1, h2, h3⟩ := h.mpicImg e mp u he hi
          obtain ⟨url', h4, -⟩ := revokeArr_of (a := .grid s.homeGen) h1
          obtain ⟨url0, h6, -, h7, h8, -⟩ := revokeArr_some h4
          rw [h1] at h6; cases h6
          exact ⟨url', h4, by rw [h8, h2], by rw [h7]; exact h3⟩
        fresh := by
          intro _ _ t tile ht hg
          have := h.tileGen t tile ht; simp only at hg; om
        tilePend := h.tilePend
        mpicPend := h.mpicPend }
    · -- dbKeys issued with gen = ++homeRenderGen
      exact { h with
        shownLe := by simp only; om
        rendersFresh := by
          intro j hj; simp only [upd_apply]; rw [ifn]; exact h.rendersFresh j hj
          intro hji; subst hji; rw [h.rendersFresh _ hj] at hri; cases hri
        rendGen := by
          intro j r g hr hg; simp only [upd_apply] at hr
          split at hr
          · cases hr; simp [RStage.gen?] at hg; om
          · have := h.rendGen j r g hr hg; om
        rendUniq := by
          intro j k rj rk g hj hk gj gk; simp only [upd_apply] at hj hk
          split at hj
          · split at hk
            · subst_vars; rfl
            · cases hj; simp [RStage.gen?] at gj
              have := h.rendGen k rk g hk gk; om
          · split at hk
            · cases hk; simp [RStage.gen?] at gk
              have := h.rendGen j rj g hj gj; om
            · exact h.rendUniq j k rj rk g hj hk gj gk
        live := Or.inr ⟨i, ⟨roms, .keys (s.gen + 1)⟩, by simp, rfl⟩
        fresh := by intro _ hg; simp only at hg; om }
  · exact h

theorem ginv_renderKeys (fix : Bool) (s : State) (h : GInv s) (i : Nat) :
    GInv (step fix s (.renderKeys i)) := by
  simp only [step]
  split
  · rename_i roms g hri
    split
    · exact { h with
        rendersFresh := by
          intro j hj; simp only [upd_apply]; rw [ifn]; exact h.rendersFresh j hj
          intro hji; subst hji; rw [h.rendersFresh _ hj] at hri; cases hri
        rendGen := by
          intro j r g' hr hg; simp only [upd_apply] at hr
          split at hr
          · cases hr; subst_vars; exact h.rendGen _ _ _ hri (by simp [RStage.gen?] at hg ⊢; exact hg)
          · exact h.rendGen j r g' hr hg
        rendUniq := by
          intro j k rj rk g' hj hk gj gk; simp only [upd_apply] at hj hk
          have hgi : (Render.mk roms (.keys g)).stage.gen? = some g := rfl
          by_cases hji : j = i <;> by_cases hki : k = i
          · rw [hji, hki]
          · rw [ifp hji] at hj; rw [ifn hki] at hk; cases hj; simp [RStage.gen?] at gj; subst gj
            exact hji ▸ h.rendUniq i k _ rk g hri hk hgi gk
          · rw [ifp hki] at hk; rw [ifn hji] at hj; cases hk; simp [RStage.gen?] at gk; subst gk
            exact hki ▸ h.rendUniq j i rj _ g hj hri gj hgi
          · rw [ifn hji] at hj; rw [ifn hki] at hk
            exact h.rendUniq j k rj rk g' hj hk gj gk
        live := by
          rcases h.live with hl | ⟨j, r, hr, hg⟩
          · exact Or.inl hl
          · refine Or.inr ?_
            by_cases hji : j = i
            · subst hji; exact ⟨j, ⟨roms, .sizes g⟩, by simp, by simp [RStage.gen?]; assumption⟩
            · exact ⟨j, r, by simp [hji, hr], hg⟩ }
    · exact { h with
        rendersFresh := by
          intro j hj; simp only [upd_apply]; split
          · rfl
          · exact h.rendersFresh j hj
        rendGen := by
          intro j r g' hr hg; simp only [upd_apply] at hr
          split at hr
          · cases hr
          · exact h.rendGen j r g' hr hg
        rendUniq := by
          intro j k rj rk g' hj hk gj gk; simp only [upd_apply] at hj hk
          split at hj
          · cases hj
          · split at hk
            · cases hk
            · exact h.rendUniq j k rj rk g' hj hk gj gk
        live := by
          rcases h.live with hl | ⟨j, r, hr, hg⟩
          · exact Or.inl hl
          · refine Or.inr ⟨j, r, ?_, hg⟩
            simp only [upd_apply]; rw [ifn]; exact hr
            intro hji; subst hji; rw [hri] at hr; cases hr; simp [RStage.gen?] at hg
            contradiction }
  · exact h


theorem ginv_renderCommit (fix : Bool) (s : State) (h : GInv s) (i : Nat) :
    GInv (step fix s (.renderCommit i)) := by
  simp only [step]
  split
  · rename_i roms g hri
    have hgi : (Render.mk roms (.sizes g)).stage.gen? = some g := rfl
    split
    · rename_i hg
      have hrg := h.rendGen i _ g hri hgi
      have hlt : s.shown < g := hrg.2 hg
      exact {
        shownLe := by om
        home := rfl
        rendersFresh := by
          intro j hj; simp only [upd_apply]; split
          · rfl
          · exact h.rendersFresh j hj
        rendGen := by
          intro j r g' hr hgj; simp only [upd_apply] at hr
          split at hr
          · cases hr
          · rename_i hji
            have := h.rendGen j r g' hr hgj
            refine ⟨by om, fun e => ?_⟩
            exact absurd (h.rendUniq j i r _ g hr hri (by rw [hgj]; simp only at e; rw [e, hg]) hgi) hji
        rendUniq := by
          intro j k rj rk g' hj hk gj gk; simp only [upd_apply] at hj hk
          split at hj
          · cases hj
          · split at hk
            · cases hk
            · exact h.rendUniq j k rj rk g' hj hk gj gk
        live := Or.inl hg
        tilesFresh := by
          intro t ht; simp only [mkTiles]; rw [ifn (by om)]; exact h.tilesFresh t (by om)
        tileGen := by
          intro t tile ht; simp only [mkTiles] at ht
          split at ht
          · cases ht; exact Nat.le_refl _
          · have := h.tileGen t tile ht; om
        urlsFresh := fun u hu => revokeArr_none (h.urlsFresh u hu)
        tileImg := by
          intro t tile u ht hi; simp only [mkTiles] at ht
          split at ht
          · cases ht; cases hi
          · exact rv_tileImg h t tile u ht hi
        urlGrid := rv_urlGrid h g hlt
        menuUrlOk := rv_menuUrlOk h
        menuUrlOpen := h.menuUrlOpen
        menuForOpen := h.menuForOpen
        urlMenu := rv_urlMenu h
        mpicsFresh := h.mpicsFresh
        mpicImg := rv_mpicImg h
        fresh := by
          intro _ _ t tile ht htg; simp only [mkTiles] at ht
          split at ht
          · cases ht; simp [FreshTile]
          · have := h.tileGen t tile ht; simp only at htg; om
        tilePend := by
          intro t tile ht; simp only [mkTiles] at ht
          split at ht
          · cases ht; intro; rfl
          · exact h.tilePend t tile ht
        mpicPend := h.mpicPend }
    · rename_i hg
      exact { h with
        rendersFresh := by
          intro j hj; simp only [upd_apply]; split
          · rfl
          · exact h.rendersFresh j hj
        rendGen := by
          intro j r g' hr hgj; simp only [upd_apply] at hr
          split at hr
          · cases hr
          · exact h.rendGen j r g' hr hgj
        rendUniq := by
          intro j k rj rk g' hj hk gj gk; simp only [upd_apply] at hj hk
          split at hj
          · cases hj
          · split at hk
            · cases hk
            · exact h.rendUniq j k rj rk g' hj hk gj gk
        live := by
          rcases h.live with hl | ⟨j, r, hr, hgj⟩
          · exact Or.inl hl
          · refine Or.inr ⟨j, r, ?_, hgj⟩
            simp only [upd_apply]; rw [ifn]; exact hr
            intro hji; subst hji; rw [hri] at hr; cases hr; simp [RStage.gen?] at hgj
            exact hg hgj }
  · exact h

theorem ginv_paintTile {s : State} (h : GInv s) {t : Nat} {tile : Tile} (ht : s.tiles t = some tile)
    (hgen : tile.gen = s.gen) (p : Pic) (k : Key) (hk : k = .frame tile.name ∨ k = .art tile.name)
    (hf : s.wsc = false → s.shown = s.gen →
      s.frame tile.name = some p ∨ (s.frame tile.name = none ∧ s.art tile.name = some p)) :
    GInv (paintTile s t tile p k) := by
  have hn := h.urlsFresh s.nUrls (Nat.le_refl _)
  have hlt : ∀ u url, s.urls u = some url → u ≠ s.nUrls := by
    intro u url hu e; subst e; rw [hn] at hu; cases hu
  have hts := h.tileGen t tile ht
  have hsl := h.shownLe
  have htl : t < s.nTiles := by
    apply Classical.byContradiction; intro hc
    rw [h.tilesFresh t (by omega)] at ht; cases ht
  unfold paintTile
  exact {
    shownLe := h.shownLe
    home := h.home
    rendersFresh := h.rendersFresh
    rendGen := h.rendGen
    rendUniq := h.rendUniq
    live := h.live
    tilesFresh := by
      intro t' ht'; simp only [upd_apply]; rw [ifn (by om)]; exact h.tilesFresh t' ht'
    tileGen := by
      intro t' tile' ht'; simp only [upd_apply] at ht'
      split at ht'
      · cases ht'; exact hts
      · exact h.tileGen _ _ ht'
    urlsFresh := by
      intro u hu; simp only [upd_apply]; rw [ifn (by om)]; exact h.urlsFresh u (by om)
    tileImg := by
      intro t' tile' u ht' hi; simp only [upd_apply] at ht' ⊢
      split at ht'
      · cases ht'; simp at hi; subst hi; simp; exact hk
      · obtain ⟨url, h1, h2⟩ := h.tileImg t' tile' u ht' hi
        rw [ifn (hlt u url h1)]; exact ⟨url, h1, h2⟩
    urlGrid := by
      intro u url g hu ha; simp only [upd_apply] at hu
      split at hu
      · cases hu; simp at ha; subst ha; exact ⟨hts, fun _ => rfl, fun hl => absurd hl (by om)⟩
      · exact h.urlGrid u url g hu ha
    menuUrlOk := by
      intro u hu; obtain ⟨url, h1, h2⟩ := h.menuUrlOk u hu
      simp only [upd_apply]; rw [ifn (hlt u url h1)]; exact ⟨url, h1, h2⟩
    menuUrlOpen := h.menuUrlOpen
    menuForOpen := h.menuForOpen
    urlMenu := by
      intro u url hu ha; simp only [upd_apply] at hu
      split at hu
      · cases hu; cases ha
      · exact h.urlMenu u url hu ha
    mpicsFresh := h.mpicsFresh
    mpicImg := by
      intro e mp u he hi; obtain ⟨url, h1, h2⟩ := h.mpicImg e mp u he hi
      simp only [upd_apply]; rw [ifn (hlt u url h1)]; exact ⟨url, h1, h2⟩
    fresh := by
      intro hw hs t' tile' ht' htg
      dsimp only at hw hs htg
      simp only [upd_apply] at ht'
      split at ht'
      · cases ht'; unfold FreshTile; simp only
        rcases hf hw hs with h1 | ⟨h1, h2⟩
        · rw [h1]; exact ⟨s.nUrls, ⟨p, k, .grid tile.gen, 0⟩, rfl, by simp, rfl⟩
        · rw [h1, h2]; exact ⟨s.nUrls, ⟨p, k, .grid tile.gen, 0⟩, rfl, by simp, rfl⟩
      · refine freshTile_transfer (s := s) tile' rfl rfl ?_ (h.fresh hw hs t' tile' ht' htg)
        intro u url hu
        exact ⟨url, by simp only [upd_apply]; rw [ifn (hlt u url hu)]; exact hu, rfl⟩
    tilePend := by
      intro t' tile' ht'; simp only [upd_apply] at ht'
      split at ht'
      · cases ht'; intro hc; exact absurd rfl hc
      · exact h.tilePend _ _ ht'
    mpicPend := h.mpicPend }

theorem ginv_setFetch {s : State} (h : GInv s) {t : Nat} {tile : Tile} (ht : s.tiles t = some tile)
    (f : Fetch) (hp : f ≠ .done → tile.img = none)
    (hf : s.wsc = false → s.shown = s.gen → tile.gen = s.shown → FreshTile s { tile with fetch := f }) :
    GInv { s with tiles := upd s.tiles t (some { tile with fetch := f }) } := by
  have htl : t < s.nTiles := by
    apply Classical.byContradiction; intro hc
    rw [h.tilesFresh t (by omega)] at ht; cases ht
  exact { h with
    tilesFresh := by
      intro t' ht'; simp only [upd_apply]; rw [ifn (by om)]; exact h.tilesFresh t' ht'
    tileGen := by
      intro t' tile' ht'; simp only [upd_apply] at ht'
      split at ht'
      · cases ht'; exact h.tileGen t tile ht
      · exact h.tileGen _ _ ht'
    tileImg := by
      intro t' tile' u ht' hi; simp only [upd_apply] at ht'
      split at ht'
      · cases ht'; exact h.tileImg t tile u ht hi
      · exact h.tileImg t' tile' u ht' hi
    fresh := by
      intro hw hs t' tile' ht' htg
      simp only [upd_apply] at ht'
      split at ht'
      · cases ht'; exact hf hw hs htg
      · exact h.fresh hw hs t' tile' ht' htg
    tilePend := by
      intro t' tile' ht'; simp only [upd_apply] at ht'
      split at ht'
      · cases ht'; exact hp
      · exact h.tilePend _ _ ht' }

theorem ginv_fetchFrame (fix : Bool) (s : State) (h : GInv s) (t : Nat) :
    GInv (step fix s (.fetchFrame t)) := by
  simp only [step]
  split
  · rename_i tile ht
    have hpend := h.tilePend t tile ht
    have hsl := h.shownLe
    have htg := h.tileGen t tile ht
    split
    · rename_i p hfe
      split
      · rename_i hg
        apply ginv_paintTile h ht hg p _ (Or.inl rfl)
        intro hw hs; left
        have := h.fresh hw hs t tile ht (by om)
        unfold FreshTile at this; rw [hfe] at this; exact this.symm
      · rename_i hg
        apply ginv_setFetch h ht
        · intro _; exact hpend (by rw [hfe]; simp)
        · intro _ hs hts; exact absurd (hts.trans hs) hg
    · rename_i hfe
      apply ginv_setFetch h ht
      · intro _; exact hpend (by rw [hfe]; simp)
      · intro hw hs hts
        have := h.fresh hw hs t tile ht hts
        unfold FreshTile at this ⊢; rw [hfe] at this; simp only
        exact ⟨this.symm, by trivial⟩
    · exact h
  · exact h

theorem ginv_fetchArt (fix : Bool) (s : State) (h : GInv s) (t : Nat) :
    GInv (step fix s (.fetchArt t)) := by
  simp only [step]
  split
  · rename_i tile ht
    have hpend := h.tilePend t tile ht
    split
    · rename_i p hfe
      split
      · rename_i hg
        apply ginv_paintTile h ht hg p _ (Or.inr rfl)
        intro hw hs; right
        have := h.fresh hw hs t tile ht (by have := h.tileGen t tile ht; have := h.shownLe; om)
        unfold FreshTile at this; rw [hfe] at this; exact ⟨this.1, this.2.symm⟩
      · rename_i hg
        apply ginv_setFetch h ht
        · intro hc; exact absurd rfl hc
        · intro _ hs hts; exact absurd (hts.trans hs) hg
    · rename_i hfe
      apply ginv_setFetch h ht
      · intro hc; exact absurd rfl hc
      · intro hw hs hts
        have := h.fresh hw hs t tile ht hts
        unfold FreshTile at this ⊢; rw [hfe] at this; simp only
        rw [this.1, ← this.2]
        exact hpend (by rw [hfe]; simp)
    · exact h
  · exact h

theorem ginv_closeMenu {s : State} (h : GInv s) : GInv (closeMenu s) := by
  unfold closeMenu; split
  · exact {
      shownLe := h.shownLe
      home := h.home
      rendersFresh := h.rendersFresh
      rendGen := h.rendGen
      rendUniq := h.rendUniq
      live := h.live
      tilesFresh := h.tilesFresh
      tileGen := h.tileGen
      urlsFresh := fun u hu => revokeOne_none (h.urlsFresh u hu)
      tileImg := by
        intro t tile u ht hi
        obtain ⟨url, h1, h2, h3⟩ := h.tileImg t tile u ht hi
        obtain ⟨url', h4, -⟩ := revokeOne_of (o := s.menuUrl) h1
        obtain ⟨url0, h6, -, h7, h8, -⟩ := revokeOne_some h4
        rw [h1] at h6; cases h6
        exact ⟨url', h4, by rw [h8]; exact h2, by rw [h7]; exact h3⟩
      urlGrid := by
        intro u url' g hu ha
        obtain ⟨url, h1, -, -, h3, h4⟩ := revokeOne_some hu
        rw [h3] at ha
        split at h4
        · rename_i he
          obtain ⟨url2, h5, h6, -⟩ := h.menuUrlOk u he
          rw [h1] at h5; cases h5; rw [h6] at ha; cases ha
        · rw [h4]; exact h.urlGrid u url g h1 ha
      menuUrlOk := by intro u hu; cases hu
      menuUrlOpen := by simp
      menuForOpen := by simp
      urlMenu := by
        intro u url' hu ha
        obtain ⟨url, h1, -, -, h3, h4⟩ := revokeOne_some hu
        rw [h3] at ha
        obtain ⟨r1, r2⟩ := h.urlMenu u url h1 ha
        split at h4
        · rename_i he
          obtain ⟨url2, h5, -, h7⟩ := h.menuUrlOk u he
          rw [h1] at h5; cases h5; rw [h4, h7]; simp
        · rename_i he; rw [h4]; exact ⟨r1, fun h0 => absurd (r2 h0) he⟩
      mpicsFresh := h.mpicsFresh
      mpicImg := by
        intro e mp u he hi
        obtain ⟨url, h1, h2, h3⟩ := h.mpicImg e mp u he hi
        obtain ⟨url', h4, -⟩ := revokeOne_of (o := s.menuUrl) h1
        obtain ⟨url0, h6, -, h7, h8, -⟩ := revokeOne_some h4
        rw [h1] at h6; cases h6
        exact ⟨url', h4, by rw [h8]; exact h2, by rw [h7]; exact h3⟩
      fresh := by
        intro hw hs t tile ht htg
        exact freshTile_transfer (s := s) tile rfl rfl (fun u url hu => revokeOne_of hu)
          (h.fresh hw hs t tile ht htg)
      tilePend := h.tilePend
      mpicPend := h.mpicPend }
  · exact h

theorem ginv_setMFetch {s : State} (h : GInv s) {e : Nat} {mp : MPic} (he : s.mpics e = some mp)
    (f : Fetch) (hp : f ≠ .done → mp.img = none) :
    GInv { s with mpics := upd s.mpics e (some { mp with fetch := f }) } := by
  have hel : e < s.nPics := by
    apply Classical.byContradiction; intro hc
    rw [h.mpicsFresh e (by omega)] at he; cases he
  exact { h with
    mpicsFresh := by
      intro e' he'; simp only [upd_apply]; rw [ifn (by om)]; exact h.mpicsFresh e' he'
    mpicImg := by
      intro e' mp' u he' hi; simp only [upd_apply] at he'
      split at he'
      · cases he'; exact h.mpicImg e mp u he hi
      · exact h.mpicImg e' mp' u he' hi
    mpicPend := by
      intro e' mp' he'; simp only [upd_apply] at he'
      split at he'
      · cases he'; exact hp
      · exact h.mpicPend _ _ he' }

theorem ginv_paintMenu {s : State} (h : GInv s) (fix : Bool) {e : Nat} {mp : MPic}
    (he : s.mpics e = some mp) (p : Pic) (k : Key) (hk : k = .frame mp.name ∨ k = .art mp.name) :
    GInv (paintMenu fix s e mp p k) := by
  have hn := h.urlsFresh s.nUrls (Nat.le_refl _)
  have hlt : ∀ u url, s.urls u = some url → u ≠ s.nUrls := by
    intro u url hu e; subst e; rw [hn] at hu; cases hu
  have hel : e < s.nPics := by
    apply Classical.byContradiction; intro hc
    rw [h.mpicsFresh e (by omega)] at he; cases he
  -- the old URLs, seen through revokeOne and the new slot
  have hold : ∀ u url, s.urls u = some url →
      ∃ url', upd (revokeOne s.menuUrl s.urls) s.nUrls (some ⟨p, k, .menu, 0⟩) u = some url' ∧
        url'.pic = url.pic ∧ url'.key = url.key ∧ url'.arr = url.arr := by
    intro u url hu
    obtain ⟨url', h4, -⟩ := revokeOne_of (o := s.menuUrl) hu
    obtain ⟨url0, h6, h7, h8, h9, -⟩ := revokeOne_some h4
    rw [hu] at h6; cases h6
    exact ⟨url', by simp only [upd_apply]; rw [ifn (hlt u _ hu)]; exact h4, h7, h8, h9⟩
  unfold paintMenu; dsimp only
  split
  · rename_i hc
    exact {
      shownLe := h.shownLe
      home := h.home
      rendersFresh := h.rendersFresh
      rendGen := h.rendGen
      rendUniq := h.rendUniq
      live := h.live
      tilesFresh := h.tilesFresh
      tileGen := h.tileGen
      urlsFresh := by
        intro u hu; simp only [upd_apply]; rw [ifn (by om)]
        exact revokeOne_none (h.urlsFresh u (by om))
      tileImg := by
        intro t tile u ht hi
        obtain ⟨url, h1, h2, h3⟩ := h.tileImg t tile u ht hi
        obtain ⟨url', h4, -, h7, h8⟩ := hold u url h1
        exact ⟨url', h4, by rw [h8]; exact h2, by rw [h7]; exact h3⟩
      urlGrid := by
        intro u url' g hu ha; simp only [upd_apply] at hu
        split at hu
        · cases hu; cases ha
        · obtain ⟨url, h1, -, -, h3, h4⟩ := revokeOne_some hu
          rw [h3] at ha
          split at h4
          · rename_i he'
            obtain ⟨url2, h5, h6, -⟩ := h.menuUrlOk u he'
            rw [h1] at h5; cases h5; rw [h6] at ha; cases ha
          · rw [h4]; exact h.urlGrid u url g h1 ha
      menuUrlOk := by
        intro u hu; cases hu; exact ⟨⟨p, k, .menu, 0⟩, by simp, rfl, rfl⟩
      menuUrlOpen := fun _ => h.menuForOpen (by rw [hc.1]; rfl)
      menuForOpen := h.menuForOpen
      urlMenu := by
        intro u url' hu ha; simp only [upd_apply] at hu
        split at hu
        · rename_i hu0; cases hu; subst hu0; exact ⟨by simp, fun _ => rfl⟩
        · rename_i hu0
          obtain ⟨url, h1, -, -, h3, h4⟩ := revokeOne_some hu
          rw [h3] at ha
          obtain ⟨r1, r2⟩ := h.urlMenu u url h1 ha
          split at h4
          · rename_i he'
            obtain ⟨url2, h5, -, h7⟩ := h.menuUrlOk u he'
            rw [h1] at h5; cases h5; rw [h4, h7]; simp
          · rename_i he'; rw [h4]; exact ⟨r1, fun h0 => absurd (r2 h0) he'⟩
      mpicsFresh := by
        intro e' he'; simp only [upd_apply]; rw [ifn (by om)]; exact h.mpicsFresh e' he'
      mpicImg := by
        intro e' mp' u he' hi; simp only [upd_apply] at he'
        split at he'
        · cases he'; simp at hi; subst hi
          exact ⟨⟨p, k, .menu, 0⟩, by simp, rfl, hk⟩
        · obtain ⟨url, h1, h2, h3⟩ := h.mpicImg e' mp' u he' hi
          obtain ⟨url', h4, -, h7, h8⟩ := hold u url h1
          exact ⟨url', h4, by rw [h8]; exact h2, by rw [h7]; exact h3⟩
      fresh := by
        intro hw hs t tile ht htg
        refine freshTile_transfer (s := s) tile rfl rfl ?_ (h.fresh hw hs t tile ht htg)
        intro u url hu; obtain ⟨url', h4, h5, -⟩ := hold u url hu; exact ⟨url', h4, h5⟩
      tilePend := h.tilePend
      mpicPend := by
        intro e' mp' he'; simp only [upd_apply] at he'
        split at he'
        · cases he'; intro hc'; exact absurd rfl hc'
        · exact h.mpicPend _ _ he' }
  · exact ginv_setMFetch h he .done (fun hc => absurd rfl hc)

theorem ginv_step (fix : Bool) (s : State) (h : GInv s) (e : Ev) : GInv (step fix s e) := by
  cases e
  case renderStart => exact ginv_renderStart fix s h
  case renderMeta i => exact ginv_renderMeta fix s h i
  case renderKeys i => exact ginv_renderKeys fix s h i
  case renderCommit i => exact ginv_renderCommit fix s h i
  case fetchFrame t => exact ginv_fetchFrame fix s h t
  case fetchArt t => exact ginv_fetchArt fix s h t
  case openStart n =>
    simp only [step]; split
    · exact ginv_same (ginv_closeMenu h) rfl (Or.inr ⟨rfl, rfl, rfl⟩)
    · exact h
  case openDone i =>
    simp only [step]; split
    · rename_i n _
      exact { h with
        menuUrlOpen := fun _ => rfl
        menuForOpen := fun _ => rfl
        mpicsFresh := by
          intro e he; simp only [upd_apply]; rw [ifn (by om)]; exact h.mpicsFresh e (by om)
        mpicImg := by
          intro e mp u he hi; simp only [upd_apply] at he
          split at he
          · cases he; cases hi
          · exact h.mpicImg e mp u he hi
        mpicPend := by
          intro e mp he; simp only [upd_apply] at he
          split at he
          · cases he; intro; rfl
          · exact h.mpicPend e mp he }
    · exact h
  case menuClose => exact ginv_closeMenu h
  case mFetchFrame e =>
    simp only [step]; split
    · rename_i mp he
      have hp := h.mpicPend e mp he
      split
      · exact ginv_paintMenu h fix he _ _ (Or.inl rfl)
      · rename_i hf; exact ginv_setMFetch h he _ (fun _ => hp (by rw [hf]; simp))
      · exact h
    · exact h
  case mFetchArt e =>
    simp only [step]; split
    · rename_i mp he
      split
      · exact ginv_paintMenu h fix he _ _ (Or.inr rfl)
      · exact ginv_setMFetch h he .done (fun hc => absurd rfl hc)
      · exact h
    · exact h
  all_goals
    apply ginv_same h
    all_goals
      simp only [step]
      repeat' split
      all_goals
        first
        | rfl
        | (left; rfl)
        | (right; exact ⟨rfl, rfl, rfl⟩)
        | exact gview_storeFrame _ _
        | (right; exact storeFrame_db _ _)
        | skip


theorem ginv_reachable {fix : Bool} {s : State} (h : Reachable fix s) : GInv s := by
  induction h with
  | init => exact ginv_init
  | step e _ ih => exact ginv_step fix _ ih e

/-! ### Grid and URL theorems (hold for the code as it is) -/

/-- A tile's picture was read from its own game's keys, into the URL array
of the render that built it (the fetch continuation paints only the tile its
closure built; `showPicture` checks `gen`). -/
theorem tile_reads_own_keys {fix : Bool} {s : State} (h : Reachable fix s)
    (t : Nat) (tile : Tile) (u : Nat) (ht : s.tiles t = some tile) (hi : tile.img = some u) :
    ∃ url, s.urls u = some url ∧ url.arr = .grid tile.gen ∧
      (url.key = .frame tile.name ∨ url.key = .art tile.name) :=
  (ginv_reachable h).tileImg t tile u ht hi

/-- Every object URL (grid or menu) is revoked at most once. -/
theorem url_revoked_at_most_once {fix : Bool} {s : State} (h : Reachable fix s)
    (u : Nat) (url : Url) (hu : s.urls u = some url) : url.revoked ≤ 1 := by
  have g := ginv_reachable h
  cases ha : url.arr with
  | grid g' =>
    obtain ⟨g1, g2, g3⟩ := g.urlGrid u url g' hu ha
    rcases Nat.lt_or_eq_of_le g1 with hl | hl
    · rw [g3 hl]; exact Nat.le_refl _
    · rw [g2 hl]; exact Nat.zero_le _
  | menu => exact (g.urlMenu u url hu ha).1

/-- No tile in the committed grid shows a revoked URL. -/
theorem grid_shown_url_live {fix : Bool} {s : State} (h : Reachable fix s)
    (t : Nat) (tile : Tile) (u : Nat) (ht : s.tiles t = some tile) (hs : tile.gen = s.shown)
    (hi : tile.img = some u) : ∃ url, s.urls u = some url ∧ url.revoked = 0 := by
  have g := ginv_reachable h
  obtain ⟨url, h1, h2, -⟩ := g.tileImg t tile u ht hi
  exact ⟨url, h1, ((g.urlGrid u url _ h1 h2).2.1 hs)⟩

/-- No leak: an unrevoked grid URL is in `homeArtUrls` (the next commit, or
the empty-library branch, revokes it); an unrevoked menu URL is
`tileMenuPicUrl` (the next paint or closeTileMenu revokes it). -/
theorem no_url_leak {fix : Bool} {s : State} (h : Reachable fix s)
    (u : Nat) (url : Url) (hu : s.urls u = some url) (h0 : url.revoked = 0) :
    url.arr = .grid s.homeGen ∨ (url.arr = .menu ∧ s.menuUrl = some u) := by
  have g := ginv_reachable h
  cases ha : url.arr with
  | grid g' =>
    left
    obtain ⟨g1, -, g3⟩ := g.urlGrid u url g' hu ha
    rw [g.home]; congr 1
    rcases Nat.lt_or_eq_of_le g1 with hl | hl
    · rw [g3 hl] at h0; cases h0
    · exact hl
  | menu => exact Or.inr ⟨rfl, (g.urlMenu u url hu ha).2 h0⟩


/-- A fetch issued by a render that is no longer the newest (a re-render,
re-sort, rename or delete started another) creates no URL and paints
nothing: `showPicture`'s `gen !== homeRenderGen` check. -/
theorem stale_fetch_paints_nothing (fix : Bool) (s : State) (t : Nat) (tile : Tile)
    (ht : s.tiles t = some tile) (hg : tile.gen ≠ s.gen) :
    (step fix s (.fetchFrame t)).urls = s.urls ∧ (step fix s (.fetchArt t)).urls = s.urls ∧
    ((step fix s (.fetchFrame t)).tiles t).map Tile.img = some tile.img ∧
    ((step fix s (.fetchArt t)).tiles t).map Tile.img = some tile.img := by
  refine ⟨?_, ?_, ?_, ?_⟩ <;> simp only [step, ht] <;> split <;> (try split) <;> simp_all

/-- Once nothing is in flight (no render, every on-screen tile settled) and
no picture record changed since the grid was committed, every on-screen
tile shows exactly what the database holds for its game: the frame, else
the art, else nothing. No older fetch can have overwritten a newer one. -/
theorem grid_settled_shows_db {fix : Bool} {s : State} (h : Reachable fix s)
    (hr : ∀ i, s.renders i = none)
    (hd : ∀ t tile, s.tiles t = some tile → tile.gen = s.shown → tile.fetch = .done)
    (hw : s.wsc = false) (t : Nat) (tile : Tile) (ht : s.tiles t = some tile)
    (hs : tile.gen = s.shown) :
    match s.frame tile.name with
    | some p => ∃ u url, tile.img = some u ∧ s.urls u = some url ∧ url.pic = p
    | none =>
      match s.art tile.name with
      | some p => ∃ u url, tile.img = some u ∧ s.urls u = some url ∧ url.pic = p
      | none => tile.img = none := by
  have g := ginv_reachable h
  have hsg : s.shown = s.gen := by
    rcases g.live with hl | ⟨i, r, hri, -⟩
    · exact hl
    · rw [hr i] at hri; cases hri
  have hf := g.fresh hw hsg t tile ht hs
  unfold FreshTile at hf
  rw [hd t tile ht hs] at hf
  exact hf


/-! ## The fixed model (`fix = true`): pixels, orphans, the batch -/

structure FCore (s : State) : Prop where
  ownFrame : ∀ n p, s.frame n = some p → p.owner = n
  ownArt : ∀ n p, s.art n = some p → p.owner = n
  ownChain : ∀ j ∈ s.chain, j.pic.owner = j.name
  ownPull : ∀ i n p, s.pulls i = some (n, p) → p.owner = n
  ownTJob : ∀ n p, s.tJob = some ⟨n, some p⟩ → p.owner = n
  thumbCore : s.tRun = true → s.tCancel = false → ∀ n, s.tJob = some ⟨n, none⟩ →
    s.cur = none → s.core = some n
  tjobRun : s.tJob.isSome → s.tRun = true
  modalSess : s.tRun = true → s.tCancel = false →
    (∀ w, s.sess ≠ .unloading w) ∧ (∀ x y l, s.sess ≠ .renaming x y l)
  curCore : ∀ g, s.cur = some g → s.core = some g
  card : ∀ g c, s.card = some (g, c) → g = c
  libFrame : ∀ n, (s.frame n).isSome → n ∈ s.lib ∨ n ∈ s.delPending
  delGone : ∀ n ∈ s.delPending, s.frame n = none ∧ s.gone n = true
  curLib : ∀ n, s.cur = some n → n ∈ s.lib ∧ n ∉ s.delPending
  outLib : ∀ b w, s.sess = .loadOut b w → b ∈ s.lib ∧ b ∉ s.delPending
  restLib : ∀ b, s.sess = .loadRestore b → b ∈ s.lib ∧ b ∉ s.delPending
  renLib : ∀ x y l, s.sess = .renaming x y l → x ∈ s.lib ∧ s.gone x = true ∧ x ∉ s.delPending ∧
    y ∉ s.delPending ∧ (l = true → s.cur = none ∧ s.core = some x) ∧ (l = false → s.cur ≠ some x)
  wChain : ∀ j ∈ s.chain, s.gone j.name = false → j.name ∈ s.lib
  wPull : ∀ i n p, s.pulls i = some (n, p) → s.gone n = false → n ∈ s.lib
  wTJob : ∀ n e, s.tJob = some ⟨n, e⟩ → s.gone n = false → n ∈ s.lib
  wCands : ∀ n ∈ s.tCands, s.gone n = false → n ∈ s.lib
  noClobber : s.clobbered = false

theorem fcore_init : FCore init := by
  constructor <;> simp [init]

theorem fcore_storeFrame {s : State} (h : FCore s) : FCore (storeFrame true s).1 := by
  unfold storeFrame
  split
  · rename_i g c hcur hcore
    split
    · exact h
    · rename_i hne
      have hgc : c = g := by simpa using hne
      exact { h with
        ownChain := by
          intro j hj; simp only [List.mem_append, List.mem_singleton] at hj
          rcases hj with hj | hj
          · exact h.ownChain j hj
          · subst hj; simp [hgc]
        wChain := by
          intro j hj; simp only [List.mem_append, List.mem_singleton] at hj
          rcases hj with hj | hj
          · exact h.wChain j hj
          · subst hj; intro _; exact (h.curLib g hcur).1 }
  · exact h

theorem storeFrame_fields (fix : Bool) (s : State) :
    (storeFrame fix s).1.cur = s.cur ∧ (storeFrame fix s).1.sess = s.sess ∧
    (storeFrame fix s).1.tRun = s.tRun ∧ (storeFrame fix s).1.tCancel = s.tCancel ∧
    (storeFrame fix s).1.core = s.core ∧ (storeFrame fix s).1.card = s.card := by
  unfold storeFrame; split
  · split <;> exact ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem storeFrame_eq (fix : Bool) (s : State) :
    ∃ c k, (storeFrame fix s).1 = { s with chain := c, clock := k } := by
  unfold storeFrame; split
  · split
    · exact ⟨s.chain, s.clock, rfl⟩
    · exact ⟨_, _, rfl⟩
  · exact ⟨s.chain, s.clock, rfl⟩

theorem mem_import {l : List Nat} {n m : Nat} (h : m ∈ l ∨ m = n) :
    m ∈ (if n ∈ l then l else n :: l) := by
  split
  · rcases h with h | h
    · exact h
    · subst h; assumption
  · rcases h with h | h
    · exact List.mem_cons_of_mem _ h
    · subst h; exact List.mem_cons_self

theorem fcore_step (s : State) (h : FCore s) (e : Ev) : FCore (step true s e) := by
  cases e
  case loadBegin b =>
    simp only [step]
    split
    · rename_i hg
      obtain ⟨hidle, hb, hbd⟩ := hg
      split
      · have h1 := fcore_storeFrame h
        obtain ⟨c, k, hsf⟩ := storeFrame_eq true s
        rw [hsf] at h1 ⊢
        exact { h1 with
          modalSess := fun _ _ => ⟨fun _ => by simp, fun _ _ _ => by simp⟩
          outLib := by intro b' w hb'; simp at hb'; obtain ⟨rfl, -⟩ := hb'; exact ⟨hb, hbd⟩
          restLib := by intro b' hb'; simp at hb'
          renLib := by intro x y l hr; simp at hr }
      · exact { h with
          modalSess := fun _ _ => ⟨fun _ => by simp, fun _ _ _ => by simp⟩
          outLib := by intro b' w hb'; simp at hb'
          restLib := by intro b' hb'; simp at hb'; subst hb'; exact ⟨hb, hbd⟩
          renLib := by intro x y l hr; simp at hr }
    · exact h
  case loadOutDone =>
    simp only [step]
    split
    · rename_i b w hs
      split
      · have hb := h.outLib b w hs
        exact { h with
          modalSess := fun _ _ => ⟨fun _ => by simp, fun _ _ _ => by simp⟩
          outLib := by intro b' w' hb'; simp at hb'
          restLib := by intro b' hb'; simp at hb'; subst hb'; exact hb
          renLib := by intro x y l hr; simp at hr }
      · exact h
    · exact h
  case loadInit =>
    simp only [step]
    split
    · rename_i b hs
      have hb := h.restLib b hs
      exact { h with
        thumbCore := by intro _ _ n _ hc; simp at hc
        modalSess := fun _ _ => ⟨fun _ => by simp, fun _ _ _ => by simp⟩
        curCore := by intro g hg; simp at hg; subst hg; rfl
        curLib := by intro n hn; simp at hn; subst hn; exact hb
        outLib := by intro b' w hb'; simp at hb'
        restLib := by intro b' hb'; simp at hb'
        renLib := by intro x y l hr; simp at hr }
    · exact h
  case unloadBegin =>
    simp only [step]
    split
    · rename_i hg
      obtain ⟨hidle, -, hm⟩ := hg
      have h1 := fcore_storeFrame h
      obtain ⟨c, k, hsf⟩ := storeFrame_eq true s
      rw [hsf] at h1 ⊢
      exact { h1 with
        modalSess := by
          intro ht hc; simp only [modalUp] at hm; dsimp only at ht hc; simp [ht, hc] at hm
        outLib := by intro b' w hb'; simp at hb'
        restLib := by intro b' hb'; simp at hb'
        renLib := by intro x y l hr; simp at hr }
    · exact h
  case unloadFinish =>
    simp only [step]
    split
    · rename_i w hs
      split
      · exact { h with
          thumbCore := by intro ht hc; exact absurd hs ((h.modalSess ht hc).1 w)
          modalSess := fun _ _ => ⟨fun _ => by simp, fun _ _ _ => by simp⟩
          curCore := by intro g hg; simp at hg
          curLib := by intro n hn; simp at hn
          outLib := by intro b' w hb'; simp at hb'
          restLib := by intro b' hb'; simp at hb'
          renLib := by intro x y l hr; simp at hr }
      · exact h
    · exact h
  case tick =>
    simp only [step]; split
    · exact fcore_storeFrame h
    · exact h
  case forced => exact fcore_storeFrame h
  case pause =>
    simp only [step]; split
    · have h1 : FCore (storeFrame true { s with paused := true }).1 := fcore_storeFrame { h with }
      exact { h1 with
        card := by
          intro g c hc; simp only [cardOf] at hc
          split at hc
          · split at hc
            · cases hc
            · rename_i hne; cases hc; exact (by simpa using hne : _ = _).symm
          · cases hc }
    · exact h
  case resume =>
    simp only [step]; split
    · exact { h with }
    · exact h
  case encodeDone =>
    simp only [step]
    split
    · rename_i j rest hch
      have hj := h.ownChain j (by rw [hch]; exact List.mem_cons_self)
      have hjw := h.wChain j (by rw [hch]; exact List.mem_cons_self)
      split
      · exact h
      · split
        · exact { h with
            ownChain := by intro j' hj'; exact h.ownChain j' (by rw [hch]; exact List.mem_cons_of_mem _ hj')
            wChain := by intro j' hj'; exact h.wChain j' (by rw [hch]; exact List.mem_cons_of_mem _ hj') }
        · rename_i _ hgone
          have hg : s.gone j.name = false := by simpa using hgone
          have hnl := hjw hg
          exact { h with
            ownFrame := by
              intro n p hp; simp only [upd_apply] at hp
              split at hp
              · cases hp; subst_vars; exact hj
              · exact h.ownFrame n p hp
            libFrame := by
              intro n hn; simp only [upd_apply] at hn
              split at hn
              · subst_vars; exact Or.inl hnl
              · exact h.libFrame n hn
            delGone := by
              intro n hn; simp only [upd_apply]
              split
              · subst_vars; rw [(h.delGone _ hn).2] at hg; cases hg
              · exact h.delGone n hn
            ownChain := by
              intro j' hj'; simp only [List.mem_cons] at hj'
              rcases hj' with hj' | hj'
              · subst hj'; exact hj
              · exact h.ownChain j' (by rw [hch]; exact List.mem_cons_of_mem _ hj')
            wChain := by
              intro j' hj'; simp only [List.mem_cons] at hj'
              rcases hj' with hj' | hj'
              · subst hj'; exact hjw
              · exact h.wChain j' (by rw [hch]; exact List.mem_cons_of_mem _ hj') }
    · exact h
  case putDone =>
    simp only [step]
    split
    · rename_i j rest hch
      split
      · exact { h with
          ownChain := by intro j' hj'; exact h.ownChain j' (by rw [hch]; exact List.mem_cons_of_mem _ hj')
          wChain := by intro j' hj'; exact h.wChain j' (by rw [hch]; exact List.mem_cons_of_mem _ hj') }
      · exact h
    · exact h
  case importGame n =>
    simp only [step]
    split
    · rename_i hg
      obtain ⟨hidle, hnd⟩ := hg
      exact { h with
        ownArt := by
          intro m p hp; simp only [upd_apply] at hp
          split at hp
          · cases hp; subst_vars; rfl
          · exact h.ownArt m p hp
        libFrame := by
          intro m hm; rcases h.libFrame m hm with hl | hl
          · exact Or.inl (mem_import (Or.inl hl))
          · exact Or.inr hl
        delGone := by
          intro m hm; simp only [upd_apply]
          split
          · subst_vars; exact absurd hm hnd
          · exact h.delGone m hm
        curLib := by
          intro m hm; obtain ⟨h1, h2⟩ := h.curLib m hm; exact ⟨mem_import (Or.inl h1), h2⟩
        outLib := by intro b w hb; rw [hidle] at hb; cases hb
        restLib := by intro b hb; rw [hidle] at hb; cases hb
        renLib := by intro x y l hr; rw [hidle] at hr; cases hr
        wChain := by
          intro j hj; simp only [upd_apply]; split
          · intro _; subst_vars; exact mem_import (Or.inr rfl)
          · intro hg; exact mem_import (Or.inl (h.wChain j hj hg))
        wPull := by
          intro i m p hp; simp only [upd_apply]; split
          · intro _; subst_vars; exact mem_import (Or.inr rfl)
          · intro hg; exact mem_import (Or.inl (h.wPull i m p hp hg))
        wTJob := by
          intro m e hm; simp only [upd_apply]; split
          · intro _; subst_vars; exact mem_import (Or.inr rfl)
          · intro hg; exact mem_import (Or.inl (h.wTJob m e hm hg))
        wCands := by
          intro m hm; simp only [upd_apply]; split
          · intro _; subst_vars; exact mem_import (Or.inr rfl)
          · intro hg; exact mem_import (Or.inl (h.wCands m hm hg)) }
    · exact h
  case delKeys n =>
    simp only [step]
    split
    · rename_i hg
      obtain ⟨hidle, hcur, hnd⟩ := hg
      exact { h with
        ownFrame := by
          intro m p hp; simp only [upd_apply] at hp
          split at hp
          · cases hp
          · exact h.ownFrame m p hp
        ownArt := by
          intro m p hp; simp only [upd_apply] at hp
          split at hp
          · cases hp
          · exact h.ownArt m p hp
        libFrame := by
          intro m hm; simp only [upd_apply] at hm
          split at hm
          · cases hm
          · rcases h.libFrame m hm with hl | hl
            · exact Or.inl hl
            · exact Or.inr (List.mem_cons_of_mem _ hl)
        delGone := by
          intro m hm; simp only [List.mem_cons] at hm; simp only [upd_apply]
          rcases hm with hm | hm
          · subst hm; simp
          · split
            · simp
            · exact h.delGone m hm
        curLib := by
          intro m hm; obtain ⟨h1, h2⟩ := h.curLib m hm
          refine ⟨h1, ?_⟩; simp only [List.mem_cons, not_or]
          exact ⟨fun e => hcur (e ▸ hm), h2⟩
        outLib := by intro b w hb; rw [hidle] at hb; cases hb
        restLib := by intro b hb; rw [hidle] at hb; cases hb
        renLib := by intro x y l hr; rw [hidle] at hr; cases hr
        wChain := by
          intro j hj; simp only [upd_apply]; split
          · intro hc; cases hc
          · exact h.wChain j hj
        wPull := by
          intro i m p hp; simp only [upd_apply]; split
          · intro hc; cases hc
          · exact h.wPull i m p hp
        wTJob := by
          intro m e hm; simp only [upd_apply]; split
          · intro hc; cases hc
          · exact h.wTJob m e hm
        wCands := by
          intro m hm; simp only [upd_apply]; split
          · intro hc; cases hc
          · exact h.wCands m hm }
    · exact h
  case delRecent n =>
    simp only [step]
    split
    · rename_i hnd
      have hng := (h.delGone n hnd).2
      have hnf := (h.delGone n hnd).1
      have keep : ∀ m, m ∈ s.lib → m ≠ n → m ∈ s.lib.filter (· ≠ n) := by
        intro m hm hmn; simp [List.mem_filter, hm, hmn]
      have gonel : ∀ m, s.gone m = false → m ∈ s.lib → m ∈ s.lib.filter (· ≠ n) := by
        intro m hg hm; apply keep m hm; intro e; subst e; rw [hng] at hg; cases hg
      exact { h with
        libFrame := by
          intro m hm
          rcases h.libFrame m hm with hl | hl
          · left; apply keep m hl; intro e; subst e; rw [hnf] at hm; cases hm
          · by_cases hmn : m = n
            · subst hmn; rw [hnf] at hm; cases hm
            · right; simp [List.mem_filter, hl, hmn]
        delGone := by
          intro m hm; simp only [List.mem_filter] at hm; exact h.delGone m hm.1
        curLib := by
          intro m hm; obtain ⟨h1, h2⟩ := h.curLib m hm
          have hmn : m ≠ n := fun e => h2 (e ▸ hnd)
          refine ⟨keep m h1 hmn, ?_⟩; simp only [List.mem_filter, not_and]; intro hc; exact absurd hc h2
        outLib := by
          intro b w hb; obtain ⟨h1, h2⟩ := h.outLib b w hb
          have hbn : b ≠ n := fun e => h2 (e ▸ hnd)
          refine ⟨keep b h1 hbn, ?_⟩; simp only [List.mem_filter, not_and]; intro hc; exact absurd hc h2
        restLib := by
          intro b hb; obtain ⟨h1, h2⟩ := h.restLib b hb
          have hbn : b ≠ n := fun e => h2 (e ▸ hnd)
          refine ⟨keep b h1 hbn, ?_⟩; simp only [List.mem_filter, not_and]; intro hc; exact absurd hc h2
        renLib := by
          intro x y l hr; obtain ⟨h1, h2, h3, h4, h5, h6⟩ := h.renLib x y l hr
          have hxn : x ≠ n := fun e => h3 (e ▸ hnd)
          refine ⟨keep x h1 hxn, h2, ?_, ?_, h5, h6⟩
          · simp only [List.mem_filter, not_and]; intro hc; exact absurd hc h3
          · simp only [List.mem_filter, not_and]; intro hc; exact absurd hc h4
        wChain := fun j hj hg => gonel _ hg (h.wChain j hj hg)
        wPull := fun i m p hp hg => gonel _ hg (h.wPull i m p hp hg)
        wTJob := fun m e hm hg => gonel _ hg (h.wTJob m e hm hg)
        wCands := fun m hm hg => gonel _ hg (h.wCands m hm hg) }
    · exact h
  case renBegin x y =>
    simp only [step]
    split
    · rename_i hg
      obtain ⟨hidle, hm, hx, hxy, hxd, hyd⟩ := hg
      have hmod : ¬ (s.tRun = true ∧ s.tCancel = false) := by
        intro ⟨a, b⟩; simp [modalUp, a, b] at hm
      have gonex : ∀ m, (upd s.gone x true) m = false → s.gone m = false ∧ m ≠ x := by
        intro m hg; simp only [upd_apply] at hg; split at hg
        · cases hg
        · rename_i hmx; exact ⟨hg, hmx⟩
      exact { h with
        thumbCore := by intro a b; exact absurd ⟨a, b⟩ hmod
        modalSess := by intro a b; exact absurd ⟨a, b⟩ hmod
        curCore := by
          intro m hc; dsimp only at hc; split at hc
          · cases hc
          · exact h.curCore m hc
        delGone := by
          intro m hmd; dsimp only at hmd; refine ⟨(h.delGone m hmd).1, ?_⟩
          simp only [upd_apply]; split
          · rfl
          · exact (h.delGone m hmd).2
        curLib := by
          intro m hc; dsimp only at hc; split at hc
          · cases hc
          · exact h.curLib m hc
        outLib := by intro b w hb; simp at hb
        restLib := by intro b hb; simp at hb
        renLib := by
          intro x' y' l hr; simp only [Sess.renaming.injEq] at hr
          obtain ⟨rfl, rfl, rfl⟩ := hr
          refine ⟨hx, by simp, hxd, hyd, ?_, ?_⟩
          · intro hl; dsimp only; rw [ifp hl]
            exact ⟨rfl, h.curCore x (of_decide_eq_true hl)⟩
          · intro hl; dsimp only; rw [ifn (by simp [hl])]; exact of_decide_eq_false hl
        wChain := fun j hj hg => h.wChain j hj (gonex _ hg).1
        wPull := fun i m p hp hg => h.wPull i m p hp (gonex _ hg).1
        wTJob := fun m e hm hg => h.wTJob m e hm (gonex _ hg).1
        wCands := fun m hm hg => h.wCands m hm (gonex _ hg).1 }
    · exact h
  case renMove =>
    simp only [step]
    split
    · rename_i x y l hs
      obtain ⟨hx, hgx, hxd, hyd, hl1, hl0⟩ := h.renLib x y l hs
      have hnomod : s.tRun = true → s.tCancel = false → False :=
        fun a b => (h.modalSess a b).2 x y l hs
      split
      · -- collision: rolled back whole
        exact { h with
          thumbCore := fun a b => (hnomod a b).elim
          modalSess := fun _ _ => ⟨fun _ => by simp, fun _ _ _ => by simp⟩
          curCore := by
            intro m hc; dsimp only at hc; split at hc
            · rename_i hlt; cases hc; exact (hl1 hlt).2
            · exact h.curCore m hc
          delGone := by
            intro m hmd; dsimp only at hmd; refine ⟨(h.delGone m hmd).1, ?_⟩
            simp only [upd_apply]; rw [ifn (fun (e : m = x) => hxd (e ▸ hmd))]; exact (h.delGone m hmd).2
          curLib := by
            intro m hc; dsimp only at hc; split at hc
            · cases hc; exact ⟨hx, hxd⟩
            · exact h.curLib m hc
          outLib := by intro b w hb; simp at hb
          restLib := by intro b hb; simp at hb
          renLib := by intro x' y' l' hr; simp at hr
          wChain := by
            intro j hj; simp only [upd_apply]; split
            · intro _; subst_vars; exact hx
            · exact h.wChain j hj
          wPull := by
            intro i m p hp; simp only [upd_apply]; split
            · intro _; subst_vars; exact hx
            · exact h.wPull i m p hp
          wTJob := by
            intro m e hm; simp only [upd_apply]; split
            · intro _; subst_vars; exact hx
            · exact h.wTJob m e hm
          wCands := by
            intro m hm; simp only [upd_apply]; split
            · intro _; subst_vars; exact hx
            · exact h.wCands m hm }
      · -- dbMoveKeys: every record moves to the new name
        have inl : ∀ m, m ∈ s.lib → m ≠ x → m ∈ y :: s.lib.filter (· ≠ x) := by
          intro m hm hmx; exact List.mem_cons_of_mem _ (by simp [List.mem_filter, hm, hmx])
        have goney : ∀ m, (upd s.gone y false) m = false → (m ≠ y → m ∈ s.lib) →
            m ∈ y :: s.lib.filter (· ≠ x) := by
          intro m hg hm; simp only [upd_apply] at hg; split at hg
          · subst_vars; exact List.mem_cons_self
          · rename_i hmy
            apply inl m (hm hmy); intro e; subst e; rw [hgx] at hg; cases hg
        have goney' : ∀ m, (upd s.gone y false) m = false → m ≠ y → s.gone m = false := by
          intro m hg hmy; simp only [upd_apply] at hg; rw [ifn hmy] at hg; exact hg
        exact { h with
          ownFrame := by
            intro m p hp; simp only [upd_apply] at hp
            split at hp
            · cases hp
            · split at hp
              · rename_i _ hmy; subst hmy
                cases hfx : s.frame x with
                | none => rw [hfx] at hp; cases hp
                | some p0 =>
                  rw [hfx] at hp; simp only [Option.map_some, Option.some.injEq] at hp; subst hp
                  simp [relabel, h.ownFrame x p0 hfx]
              · exact h.ownFrame m p hp
          ownArt := by
            intro m p hp; simp only [upd_apply] at hp
            split at hp
            · cases hp
            · split at hp
              · rename_i _ hmy; subst hmy
                cases hfx : s.art x with
                | none => rw [hfx] at hp; cases hp
                | some p0 =>
                  rw [hfx] at hp; simp only [Option.map_some, Option.some.injEq] at hp; subst hp
                  simp [relabel, h.ownArt x p0 hfx]
              · exact h.ownArt m p hp
          thumbCore := fun a b => (hnomod a b).elim
          modalSess := fun _ _ => ⟨fun _ => by simp, fun _ _ _ => by simp⟩
          curCore := by
            intro m hc; dsimp only at hc; split at hc
            · rename_i hlt; cases hc; rw [(hl1 hlt).2]; simp [relabel]
            · rename_i hlf
              have hmx : m ≠ x := fun e => hl0 (by simpa using hlf) (e ▸ hc)
              rw [h.curCore m hc]; simp [relabel, hmx]
          card := by
            intro g c hc
            cases hcd : s.card with
            | none => rw [hcd] at hc; cases hc
            | some gc =>
              rw [hcd] at hc; simp only [Option.map_some, Option.some.injEq, Prod.mk.injEq] at hc
              obtain ⟨rfl, rfl⟩ := hc
              rw [h.card gc.1 gc.2 (by rw [hcd])]
          libFrame := by
            intro m hm; simp only [upd_apply] at hm
            split at hm
            · cases hm
            · rename_i hmx
              split at hm
              · rename_i hmy; subst hmy; exact Or.inl List.mem_cons_self
              · rcases h.libFrame m hm with hl | hl
                · exact Or.inl (inl m hl hmx)
                · exact Or.inr hl
          delGone := by
            intro m hmd; dsimp only at hmd
            have hmx : m ≠ x := fun e => hxd (e ▸ hmd)
            have hmy : m ≠ y := fun e => hyd (e ▸ hmd)
            simp only [upd_apply, hmx, hmy, ite_false]
            exact h.delGone m hmd
          curLib := by
            intro m hc; dsimp only at hc
            cases l
            · rw [ifn (by simp)] at hc
              obtain ⟨h1, h2⟩ := h.curLib m hc
              exact ⟨inl m h1 (fun e => hl0 rfl (e ▸ hc)), h2⟩
            · rw [ifp rfl] at hc; cases hc; exact ⟨List.mem_cons_self, hyd⟩
          outLib := by intro b w hb; simp at hb
          restLib := by intro b hb; simp at hb
          renLib := by intro x' y' l' hr; simp at hr
          wChain := fun j hj hg => goney _ hg (fun hy => h.wChain j hj (goney' _ hg hy))
          wPull := fun i m p hp hg => goney _ hg (fun hy => h.wPull i m p hp (goney' _ hg hy))
          wTJob := fun m e hm hg => goney _ hg (fun hy => h.wTJob m e hm (goney' _ hg hy))
          wCands := fun m hm hg => goney _ hg (fun hy => h.wCands m hm (goney' _ hg hy)) }
    · exact h
  case removeLocal n =>
    simp only [step]; split
    · exact { h with
        ownArt := by
          intro m p hp; simp only [upd_apply] at hp
          split at hp
          · cases hp
          · exact h.ownArt m p hp }
    · exact h
  case pullList n =>
    simp only [step]; split
    · rename_i hg
      exact { h with
        ownPull := by
          intro i m p hp; simp only [upd_apply] at hp
          split at hp
          · cases hp; rfl
          · exact h.ownPull i m p hp
        wPull := by
          intro i m p hp; simp only [upd_apply] at hp
          split at hp
          · cases hp; intro _; exact hg.1
          · exact h.wPull i m p hp }
    · exact h
  case pullWrite i =>
    simp only [step]; split
    · rename_i n p hp
      have hpo := h.ownPull i n p hp
      have hpw := h.wPull i n p hp
      have hs1 : FCore { s with pulls := upd s.pulls i none } := { h with
        ownPull := by
          intro i' m q hq; simp only [upd_apply] at hq
          split at hq
          · cases hq
          · exact h.ownPull i' m q hq
        wPull := by
          intro i' m q hq; simp only [upd_apply] at hq
          split at hq
          · cases hq
          · exact h.wPull i' m q hq }
      split
      · exact hs1
      · rename_i hgone
        have hg : s.gone n = false := by simpa using hgone
        exact { hs1 with
          ownFrame := by
            intro m q hq; simp only [upd_apply] at hq
            split at hq
            · rename_i hmn; cases hq; rw [hmn]; exact hpo
            · exact h.ownFrame m q hq
          libFrame := by
            intro m hm; simp only [upd_apply] at hm
            split at hm
            · subst_vars; exact Or.inl (hpw hg)
            · exact h.libFrame m hm
          delGone := by
            intro m hm; simp only [upd_apply]
            split
            · subst_vars; rw [(h.delGone _ hm).2] at hg; cases hg
            · exact h.delGone m hm }
    · exact h
  case thumbStart =>
    simp only [step]; split
    · rename_i hg
      obtain ⟨-, -, hidle⟩ := hg
      exact { h with
        ownTJob := by intro n p hp; cases hp
        thumbCore := by intro _ _ n hn; cases hn
        tjobRun := fun _ => rfl
        modalSess := fun _ _ => ⟨fun w => by rw [hidle]; simp, fun _ _ _ => by rw [hidle]; simp⟩
        wTJob := by intro n e hn; cases hn
        wCands := by
          intro n hn _; simp only [List.mem_filter] at hn; exact hn.1 }
    · exact h
  case thumbInit =>
    simp only [step]; split
    · rename_i hg
      obtain ⟨hrun, hnone⟩ := hg
      split
      · rename_i n rest hc
        split
        · exact { h with
            wCands := by
              intro m hm; exact h.wCands m (by rw [hc]; exact List.mem_cons_of_mem _ hm) }
        · rename_i hnc
          have hcn : s.cur = none := by
            cases hcur : s.cur with
            | none => rfl
            | some _ => exact absurd (Or.inr (by simp [hcur])) hnc
          have htc : s.tCancel = false := by
            cases hh : s.tCancel with
            | false => rfl
            | true => exact absurd (Or.inl hh) hnc
          exact { h with
            ownTJob := by intro m p hp; simp at hp
            thumbCore := by intro _ _ m hm _; simp at hm; subst hm; rfl
            tjobRun := fun _ => hrun
            curCore := by intro g hg'; simp only [hcn] at hg'; cases hg'
            renLib := by
              intro x y l hr
              exact absurd hr ((h.modalSess hrun htc).2 x y l)
            wTJob := by
              intro m e hm; simp at hm; obtain ⟨rfl, -⟩ := hm
              exact h.wCands _ (by rw [hc]; exact List.mem_cons_self) }
      · exact h
    · exact h
  case thumbCapture =>
    simp only [step]; split
    · rename_i n c htj hcore
      split
      · exact { h with
          ownTJob := by intro m p hp; cases hp
          thumbCore := by intro _ _ m hm; cases hm
          tjobRun := by intro hc; cases hc
          wTJob := by intro m e hm; cases hm
          wCands := by intro m hm; exact h.wCands m (List.mem_of_mem_tail hm) }
      · rename_i hc
        have hrun := h.tjobRun (by rw [htj]; rfl)
        have hcn : s.tCancel = false ∧ s.cur = none := by
          simp only [not_or] at hc; exact ⟨by simpa using hc.1, by simpa using hc.2⟩
        have hcore' := h.thumbCore hrun hcn.1 n htj hcn.2
        rw [hcore] at hcore'; cases hcore'
        exact { h with
          ownTJob := by intro m p hp; simp at hp; obtain ⟨rfl, rfl⟩ := hp; rfl
          thumbCore := by intro _ _ m hm; simp at hm
          tjobRun := fun _ => hrun
          wTJob := by intro m e hm; simp at hm; obtain ⟨rfl, -⟩ := hm; exact h.wTJob _ _ htj }
    · rename_i n htj hcore
      exact { h with
        ownTJob := by intro m p hp; cases hp
        thumbCore := by intro _ _ m hm; cases hm
        tjobRun := by intro hc; cases hc
        wTJob := by intro m e hm; cases hm
        wCands := by intro m hm; exact h.wCands m (List.mem_of_mem_tail hm) }
    · exact h
  case thumbPut =>
    simp only [step]; split
    · rename_i n p htj
      have hpo := h.ownTJob n p htj
      have hpw := h.wTJob n (some p) htj
      have hs1 : FCore { s with tJob := none, tCands := s.tCands.tail } := { h with
          ownTJob := by intro m q hq; cases hq
          thumbCore := by intro _ _ m hm; cases hm
          tjobRun := by intro hc; cases hc
          wTJob := by intro m e hm; cases hm
          wCands := by intro m hm; exact h.wCands m (List.mem_of_mem_tail hm) }
      split
      · exact hs1
      · rename_i hgone
        have hg : s.gone n = false ∧ s.frame n = none := by
          constructor
          · cases h1 : s.gone n <;> simp_all
          · cases h2 : s.frame n <;> simp_all
        exact { hs1 with
          ownFrame := by
            intro m q hq; simp only [upd_apply] at hq
            split at hq
            · rename_i hmn; cases hq; rw [hmn]; exact hpo
            · exact h.ownFrame m q hq
          libFrame := by
            intro m hm; simp only [upd_apply] at hm
            split at hm
            · subst_vars; exact Or.inl (hpw hg.1)
            · exact h.libFrame m hm
          delGone := by
            intro m hm; simp only [upd_apply]
            split
            · subst_vars; rw [(h.delGone _ hm).2] at hg; cases hg.1
            · exact h.delGone m hm
          noClobber := by simp [h.noClobber, hg.2] }
    · exact h
  case thumbCancel =>
    simp only [step]; split
    · exact { h with
        thumbCore := by intro _ hc; cases hc
        modalSess := by intro _ hc; cases hc }
    · exact h
  case thumbEnd =>
    simp only [step]; split
    · rename_i hg
      exact { h with
        thumbCore := by intro hc; cases hc
        tjobRun := by intro hc; rw [hg.2.1] at hc; cases hc
        modalSess := by intro hc; cases hc }
    · exact h
  all_goals
    simp only [step]
    repeat' split
    all_goals first
      | exact h
      | exact { h with }
      | (unfold paintTile; exact { h with })
      | (unfold paintMenu; dsimp only; split <;> exact { h with })
      | (unfold closeMenu; split <;> exact { h with })

/-- What the grid and the menu hold is some game's pixels under that game's
key. -/
structure FView (s : State) : Prop where
  ownUrl : ∀ u url, s.urls u = some url → url.pic.owner = url.key.game
  ownTile : ∀ t tile p, s.tiles t = some tile →
    (tile.fetch = .frameWait (some p) ∨ tile.fetch = .artWait (some p)) → p.owner = tile.name
  ownMPic : ∀ e mp p, s.mpics e = some mp →
    (mp.fetch = .frameWait (some p) ∨ mp.fetch = .artWait (some p)) → p.owner = mp.name

/-- The menu head (fixed): the attached picture shows `tileMenuPicUrl`. -/
structure MInv (s : State) : Prop where
  head : ∀ e mp u, s.menuHead = some e → s.mpics e = some mp → mp.img = some u → s.menuUrl = some u

theorem fview_init : FView init := by constructor <;> simp [init]
theorem minv_init : MInv init := by constructor; simp [init]

theorem fview_setFetch {s : State} (h : FView s) {t : Nat} {tile : Tile} (f : Fetch)
    (hf : ∀ p, (f = .frameWait (some p) ∨ f = .artWait (some p)) → p.owner = tile.name) :
    FView { s with tiles := upd s.tiles t (some { tile with fetch := f }) } := { h with
  ownTile := by
    intro t' tile' p ht' hp; simp only [upd_apply] at ht'
    split at ht'
    · cases ht'; exact hf p hp
    · exact h.ownTile t' tile' p ht' hp }

theorem fview_setMFetch {s : State} (h : FView s) {e : Nat} {mp : MPic} (f : Fetch)
    (hf : ∀ p, (f = .frameWait (some p) ∨ f = .artWait (some p)) → p.owner = mp.name) :
    FView { s with mpics := upd s.mpics e (some { mp with fetch := f }) } := { h with
  ownMPic := by
    intro e' mp' p he' hp; simp only [upd_apply] at he'
    split at he'
    · cases he'; exact hf p hp
    · exact h.ownMPic e' mp' p he' hp }

theorem fview_revokeArr {s : State} (h : FView s) (a : Arr) :
    ∀ u url, revokeArr a s.urls u = some url → url.pic.owner = url.key.game := by
  intro u url hu
  obtain ⟨url0, h1, h2, h3, -⟩ := revokeArr_some hu
  rw [h2, h3]; exact h.ownUrl u url0 h1

theorem fview_revokeOne {s : State} (h : FView s) (o : Option Nat) :
    ∀ u url, revokeOne o s.urls u = some url → url.pic.owner = url.key.game := by
  intro u url hu
  obtain ⟨url0, h1, h2, h3, -⟩ := revokeOne_some hu
  rw [h2, h3]; exact h.ownUrl u url0 h1

theorem fview_closeMenu {s : State} (h : FView s) : FView (closeMenu s) := by
  unfold closeMenu; split
  · exact { h with ownUrl := fview_revokeOne h _ }
  · exact h

theorem fview_storeFrame {s : State} (h : FView s) : FView (storeFrame true s).1 := by
  unfold storeFrame; split
  · split
    · exact h
    · exact { h with }
  · exact h

theorem fview_step (s : State) (hc : FCore s) (h : FView s) (e : Ev) : FView (step true s e) := by
  cases e
  case renderMeta i =>
    simp only [step]; split
    · split
      · exact { h with ownUrl := fview_revokeArr h _ }
      · exact { h with }
    · exact h
  case renderCommit i =>
    simp only [step]; split
    · split
      · exact { h with
          ownUrl := fview_revokeArr h _
          ownTile := by
            intro t tile p ht hp; simp only [mkTiles] at ht
            split at ht
            · cases ht; simp at hp; exact hc.ownFrame _ p hp
            · exact h.ownTile t tile p ht hp }
      · exact { h with }
    · exact h
  case fetchFrame t =>
    simp only [step]; split
    · rename_i tile ht
      split
      · rename_i p hfe
        have hpo := h.ownTile t tile p ht (Or.inl hfe)
        split
        · unfold paintTile
          exact {
            ownUrl := by
              intro u url hu; simp only [upd_apply] at hu
              split at hu
              · cases hu; exact hpo
              · exact h.ownUrl u url hu
            ownTile := by
              intro t' tile' q ht' hq; simp only [upd_apply] at ht'
              split at ht'
              · cases ht'; simp at hq
              · exact h.ownTile t' tile' q ht' hq
            ownMPic := h.ownMPic }
        · exact fview_setFetch h _ (by
            intro q hq; simp at hq; exact hc.ownArt _ q hq)
      · exact fview_setFetch h _ (by
          intro q hq; simp at hq; exact hc.ownArt _ q hq)
      · exact h
    · exact h
  case fetchArt t =>
    simp only [step]; split
    · rename_i tile ht
      split
      · rename_i p hfe
        have hpo := h.ownTile t tile p ht (Or.inr hfe)
        split
        · unfold paintTile
          exact {
            ownUrl := by
              intro u url hu; simp only [upd_apply] at hu
              split at hu
              · cases hu; exact hpo
              · exact h.ownUrl u url hu
            ownTile := by
              intro t' tile' q ht' hq; simp only [upd_apply] at ht'
              split at ht'
              · cases ht'; simp at hq
              · exact h.ownTile t' tile' q ht' hq
            ownMPic := h.ownMPic }
        · exact fview_setFetch h _ (by intro q hq; simp at hq)
      · exact fview_setFetch h _ (by intro q hq; simp at hq)
      · exact h
    · exact h
  case openStart n =>
    simp only [step]; split
    · exact { fview_closeMenu h with }
    · exact h
  case openDone i =>
    simp only [step]; split
    · rename_i n _
      exact { h with
        ownMPic := by
          intro e mp p he hp; simp only [upd_apply] at he
          split at he
          · cases he; simp at hp; exact hc.ownFrame _ p hp
          · exact h.ownMPic e mp p he hp }
    · exact h
  case menuClose => exact fview_closeMenu h
  case mFetchFrame e =>
    simp only [step]; split
    · rename_i mp he
      split
      · rename_i p hfe
        have hpo := h.ownMPic e mp p he (Or.inl hfe)
        unfold paintMenu; dsimp only; split
        · exact {
            ownUrl := by
              intro u url hu; simp only [upd_apply] at hu
              split at hu
              · cases hu; exact hpo
              · exact fview_revokeOne h _ u url hu
            ownTile := h.ownTile
            ownMPic := by
              intro e' mp' q he' hq; simp only [upd_apply] at he'
              split at he'
              · cases he'; simp at hq
              · exact h.ownMPic e' mp' q he' hq }
        · exact fview_setMFetch h _ (by intro q hq; simp at hq)
      · exact fview_setMFetch h _ (by
          intro q hq; simp at hq; exact hc.ownArt _ q hq)
      · exact h
    · exact h
  case mFetchArt e =>
    simp only [step]; split
    · rename_i mp he
      split
      · rename_i p hfe
        have hpo := h.ownMPic e mp p he (Or.inr hfe)
        unfold paintMenu; dsimp only; split
        · exact {
            ownUrl := by
              intro u url hu; simp only [upd_apply] at hu
              split at hu
              · cases hu; exact hpo
              · exact fview_revokeOne h _ u url hu
            ownTile := h.ownTile
            ownMPic := by
              intro e' mp' q he' hq; simp only [upd_apply] at he'
              split at he'
              · cases he'; simp at hq
              · exact h.ownMPic e' mp' q he' hq }
        · exact fview_setMFetch h _ (by intro q hq; simp at hq)
      · exact fview_setMFetch h _ (by intro q hq; simp at hq)
      · exact h
    · exact h
  all_goals
    simp only [step]
    repeat' split
    all_goals first
      | exact h
      | exact { h with }
      | exact { fview_storeFrame h with }
      | exact { fview_storeFrame (s := { s with paused := true }) { h with } with }

theorem minv_storeFrame {s : State} (h : MInv s) : MInv (storeFrame true s).1 := by
  unfold storeFrame; split
  · split
    · exact h
    · exact { h with }
  · exact h

theorem minv_setMFetch {s : State} (h : MInv s) {e : Nat} {mp : MPic} (he : s.mpics e = some mp)
    (f : Fetch) : MInv { s with mpics := upd s.mpics e (some { mp with fetch := f }) } := ⟨by
  intro e' mp' u hh he' hi; simp only [upd_apply] at he'
  split at he'
  · cases he'; exact h.head _ mp u hh (by rename_i hee; rw [hee]; exact he) hi
  · exact h.head e' mp' u hh he' hi⟩

theorem minv_closeMenu {s : State} (h : MInv s) : MInv (closeMenu s) := by
  unfold closeMenu; split
  · exact ⟨by intro e mp u hh; cases hh⟩
  · exact h

theorem minv_step (s : State) (h : MInv s) (e : Ev) : MInv (step true s e) := by
  cases e
  case openStart n =>
    simp only [step]; split
    · exact { minv_closeMenu h with }
    · exact h
  case openDone i =>
    simp only [step]; split
    · exact ⟨by
        intro e mp u hh he hi; simp only [Option.some.injEq] at hh; subst hh
        simp only [upd_apply, ifp] at he; cases he; cases hi⟩
    · exact h
  case menuClose => exact minv_closeMenu h
  case mFetchFrame e =>
    simp only [step]; split
    · rename_i mp he
      split
      · unfold paintMenu; dsimp only; split
        · rename_i hc
          have hh : s.menuHead = some e := by simpa using hc.2
          exact ⟨by
            intro e' mp' u hh' he' hi
            rw [hh] at hh'; cases hh'
            simp only [upd_apply, ifp] at he'; cases he'; cases hi; rfl⟩
        · exact minv_setMFetch h he _
      · exact minv_setMFetch h he _
      · exact h
    · exact h
  case mFetchArt e =>
    simp only [step]; split
    · rename_i mp he
      split
      · unfold paintMenu; dsimp only; split
        · rename_i hc
          have hh : s.menuHead = some e := by simpa using hc.2
          exact ⟨by
            intro e' mp' u hh' he' hi
            rw [hh] at hh'; cases hh'
            simp only [upd_apply, ifp] at he'; cases he'; cases hi; rfl⟩
        · exact minv_setMFetch h he _
      · exact minv_setMFetch h he _
      · exact h
    · exact h
  all_goals
    simp only [step]
    repeat' split
    all_goals first
      | exact h
      | exact { h with }
      | exact { minv_storeFrame h with }
      | exact { minv_storeFrame (s := { s with paused := true }) { h with } with }
      | (unfold paintTile; exact { h with })

theorem fixed_inv {s : State} (h : Reachable true s) : FCore s ∧ FView s ∧ MInv s := by
  induction h with
  | init => exact ⟨fcore_init, fview_init, minv_init⟩
  | step e _ ih => exact ⟨fcore_step _ ih.1 e, fview_step _ ih.1 ih.2.1 e, minv_step _ ih.2.2 e⟩

/-! ### Theorems of the fixed model -/

/-- Every stored frame is its own game's screen. -/
theorem fixed_frame_is_its_game {s : State} (h : Reachable true s) (n : Nat) (p : Pic)
    (hp : s.frame n = some p) : p.owner = n :=
  (fixed_inv h).1.ownFrame n p hp

/-- A tile never shows another game's picture — on screen or not, however
its fetch interleaved with re-renders, re-sorts, renames, deletes, pulls,
the batch or game switches. -/
theorem fixed_tile_never_foreign {s : State} (h : Reachable true s) (t : Nat) (tile : Tile) (u : Nat)
    (ht : s.tiles t = some tile) (hi : tile.img = some u) :
    ∃ url, s.urls u = some url ∧ url.pic.owner = tile.name := by
  obtain ⟨url, h1, -, h3⟩ := (ginv_reachable h).tileImg t tile u ht hi
  refine ⟨url, h1, ?_⟩
  rw [(fixed_inv h).2.1.ownUrl u url h1]
  rcases h3 with h3 | h3 <;> rw [h3] <;> rfl

theorem fixed_no_foreign_tile {s : State} (h : Reachable true s) (t : Nat) :
    tileShowsForeign s t = false := by
  unfold tileShowsForeign
  split
  · rename_i tile ht
    cases hi : tile.img with
    | none => simp
    | some u =>
      obtain ⟨url, h1, h2⟩ := fixed_tile_never_foreign h t tile u ht hi
      simp [h1, h2]
  · rfl

/-- The menu's picture is never another game's either. -/
theorem fixed_menu_never_foreign {s : State} (h : Reachable true s) (e : Nat) (mp : MPic) (u : Nat)
    (he : s.mpics e = some mp) (hi : mp.img = some u) :
    ∃ url, s.urls u = some url ∧ url.pic.owner = mp.name := by
  obtain ⟨url, h1, -, h3⟩ := (ginv_reachable h).mpicImg e mp u he hi
  refine ⟨url, h1, ?_⟩
  rw [(fixed_inv h).2.1.ownUrl u url h1]
  rcases h3 with h3 | h3 <;> rw [h3] <;> rfl

/-- The paused card's label names the game whose screen it paints. -/
theorem fixed_card_consistent {s : State} (h : Reachable true s) (g c : Nat)
    (hc : s.card = some (g, c)) : g = c :=
  (fixed_inv h).1.card g c hc

/-- No frame record outlives its game: every stored frame belongs to a
library game, or to one whose delete is still running. -/
theorem fixed_no_orphan {s : State} (h : Reachable true s) (n : Nat) : orphan s n = false := by
  have hc := (fixed_inv h).1
  unfold orphan
  cases hf : (s.frame n).isSome
  · rfl
  · rcases hc.libFrame n hf with hl | hl <;> simp [hl]

/-- The batch never overwrites a frame that exists. -/
theorem fixed_no_clobber {s : State} (h : Reachable true s) : s.clobbered = false :=
  (fixed_inv h).1.noClobber

/-- The menu head never shows a revoked URL. -/
theorem fixed_menu_shown_live {s : State} (h : Reachable true s) (e : Nat) (mp : MPic) (u : Nat)
    (hh : s.menuHead = some e) (he : s.mpics e = some mp) (hi : mp.img = some u) :
    ∃ url, s.urls u = some url ∧ url.revoked = 0 := by
  have hm := (fixed_inv h).2.2.head e mp u hh he hi
  obtain ⟨url, h1, -, h3⟩ := (ginv_reachable h).menuUrlOk u hm
  exact ⟨url, h1, h3⟩

theorem fixed_no_menu_revoked {s : State} (h : Reachable true s) : menuShowsRevoked s = false := by
  unfold menuShowsRevoked
  split
  · rename_i e hh
    split
    · rename_i mp he
      split
      · rename_i u hi
        obtain ⟨url, h1, h2⟩ := fixed_menu_shown_live h e mp u hh he hi
        simp [h1, h2]
      · rfl
    · rfl
  · rfl

/-! ### The store chain writes in capture order (any `fix`) -/

def ChainOk (c : List Job) (k : Nat) : Prop :=
  c.Pairwise (fun a b => a.pic.stamp < b.pic.stamp) ∧ ∀ j ∈ c, j.pic.stamp < k

theorem chainOk_mono {c : List Job} {k k' : Nat} (h : ChainOk c k) (hk : k ≤ k') : ChainOk c k' :=
  ⟨h.1, fun j hj => Nat.lt_of_lt_of_le (h.2 j hj) hk⟩

theorem chainOk_storeFrame (fix : Bool) (s : State) (h : ChainOk s.chain s.clock) :
    ChainOk (storeFrame fix s).1.chain (storeFrame fix s).1.clock := by
  unfold storeFrame; split
  · split
    · exact h
    · refine ⟨?_, ?_⟩
      · rw [List.pairwise_append]
        refine ⟨h.1, List.pairwise_singleton _ _, ?_⟩
        intro a ha b hb; simp at hb; subst hb; exact h.2 a ha
      · intro j hj; simp only [List.mem_append, List.mem_singleton] at hj
        rcases hj with hj | hj
        · exact Nat.lt_succ_of_lt (h.2 j hj)
        · subst hj; exact Nat.lt_succ_self _
  · exact h

theorem chainOk_step (fix : Bool) (s : State) (h : ChainOk s.chain s.clock) (e : Ev) :
    ChainOk (step fix s e).chain (step fix s e).clock := by
  cases e
  case encodeDone =>
    simp only [step]; split
    · rename_i j rest hch
      rw [hch] at h
      split
      · rw [hch]; exact h
      · split
        · exact ⟨(List.pairwise_cons.mp h.1).2, fun j' hj' => h.2 j' (List.mem_cons_of_mem _ hj')⟩
        · obtain ⟨h1, h2⟩ := h
          refine ⟨?_, ?_⟩
          · dsimp only; rw [List.pairwise_cons] at h1 ⊢; exact h1
          · intro j' hj'; dsimp only at hj'; simp only [List.mem_cons] at hj'
            rcases hj' with hj' | hj'
            · subst hj'; exact h2 j List.mem_cons_self
            · exact h2 j' (List.mem_cons_of_mem _ hj')
    · exact h
  case putDone =>
    simp only [step]; split
    · rename_i j rest hch
      rw [hch] at h
      split
      · exact ⟨(List.pairwise_cons.mp h.1).2, fun j' hj' => h.2 j' (List.mem_cons_of_mem _ hj')⟩
      · rw [hch]; exact h
    · exact h
  all_goals
    simp only [step]
    repeat' split
    all_goals first
      | exact h
      | exact chainOk_storeFrame fix s h
      | exact chainOk_storeFrame fix { s with paused := true } h
      | exact chainOk_mono h (Nat.le_succ _)
      | (unfold paintTile; exact h)
      | (unfold paintMenu; dsimp only; split <;> exact h)
      | (unfold closeMenu; split <;> exact h)

theorem chainOk_reachable {fix : Bool} {s : State} (h : Reachable fix s) : ChainOk s.chain s.clock := by
  induction h with
  | init => exact ⟨List.Pairwise.nil, fun j hj => by cases hj⟩
  | step e _ ih => exact chainOk_step fix _ ih e

/-- The link `toBlob` resolves for and writes next is the oldest capture
still pending: a forced capture landing during the tick's encode stores
last (the comment at 4355–4358 holds). -/
theorem chain_writes_in_capture_order {fix : Bool} {s : State} (h : Reachable fix s)
    (j : Job) (rest : List Job) (hc : s.chain = j :: rest) :
    ∀ j' ∈ rest, j.pic.stamp < j'.pic.stamp := by
  have := (chainOk_reachable h).1
  rw [hc, List.pairwise_cons] at this
  exact this.1

/-! ### The named game is the game in the core (any `fix`)

loadRom names the new game in the segment that boots it (the load path of
`step`, as fixed), a close nulls the name, a rename relabels both, and the
batch boots its games only with no game named. So whenever a game is named,
the framebuffer is its own: `storeLastFrame` and `updatePausedCard` file and
paint the named game's pixels under its name, and fix (1) above, the `fbGame`
guard, never fires (`fix1_redundant`). -/

structure CInv (s : State) : Prop where
  cc : ∀ g, s.cur = some g → s.core = some g
  renT : ∀ x y, s.sess = .renaming x y true → s.cur = none ∧ s.core = some x
  renF : ∀ x y, s.sess = .renaming x y false → s.cur ≠ some x
  modal : s.tRun = true → s.tCancel = false → ∀ x y l, s.sess ≠ .renaming x y l

theorem cinv_of {s t : State} (h : CInv s) (hc : t.cur = s.cur) (hk : t.core = s.core)
    (hs : t.sess = s.sess) (hr : t.tRun = s.tRun) (hx : t.tCancel = s.tCancel) : CInv t :=
  ⟨by rw [hc, hk]; exact h.cc, by rw [hs, hc, hk]; exact h.renT, by rw [hs, hc]; exact h.renF,
   by rw [hr, hx, hs]; exact h.modal⟩

/-- A state whose session is no rename and whose named game is in the core. -/
theorem cinv_noRen {t : State} (hc : ∀ g, t.cur = some g → t.core = some g)
    (hs : ∀ x y l, t.sess ≠ .renaming x y l) : CInv t :=
  ⟨hc, fun x y h => absurd h (hs x y true), fun x y h => absurd h (hs x y false),
   fun _ _ => hs⟩

theorem cinv_storeFrame {s : State} (fix : Bool) (h : CInv s) : CInv (storeFrame fix s).1 := by
  obtain ⟨h1, h2, h3, h4, h5, -⟩ := storeFrame_fields fix s
  exact cinv_of h h1 h5 h2 h3 h4

theorem cinv_step (fix : Bool) (s : State) (h : CInv s) (e : Ev) : CInv (step fix s e) := by
  cases e
  case loadBegin b =>
    simp only [step]
    split
    · rename_i hg
      split
      · have h1 := cinv_storeFrame fix h
        obtain ⟨-, -, -, -, h5, -⟩ := storeFrame_fields fix s
        exact cinv_noRen (fun g hg' => h1.cc g hg') (fun _ _ _ => by simp)
      · exact cinv_noRen h.cc (fun _ _ _ => by simp)
    · exact h
  case loadOutDone =>
    simp only [step]
    split
    · split
      · exact cinv_noRen h.cc (fun _ _ _ => by simp)
      · exact h
    · exact h
  case loadInit =>
    simp only [step]
    split
    · exact cinv_noRen (fun g hg => by simp at hg; subst hg; rfl) (fun _ _ _ => by simp)
    · exact h
  case unloadBegin =>
    simp only [step]
    split
    · have h1 := cinv_storeFrame fix h
      exact cinv_noRen (fun g hg' => h1.cc g hg') (fun _ _ _ => by simp)
    · exact h
  case unloadFinish =>
    simp only [step]
    split
    · split
      · exact cinv_noRen (fun g hg => by simp at hg) (fun _ _ _ => by simp)
      · exact h
    · exact h
  case tick =>
    simp only [step]; split
    · exact cinv_storeFrame fix h
    · exact h
  case forced => exact cinv_storeFrame fix h
  case pause =>
    simp only [step]; split
    · have h1 := cinv_storeFrame fix (s := { s with paused := true }) (cinv_of h rfl rfl rfl rfl rfl)
      exact cinv_of h1 rfl rfl rfl rfl rfl
    · exact h
  case renBegin x y =>
    simp only [step]
    split
    · rename_i hg
      obtain ⟨hidle, hm, -, -, -, -⟩ := hg
      refine ⟨?_, ?_, ?_, ?_⟩
      · intro m hc; dsimp only at hc; split at hc
        · cases hc
        · exact h.cc m hc
      · intro x' y' hr; simp only [Sess.renaming.injEq] at hr
        obtain ⟨rfl, rfl, hl⟩ := hr
        dsimp only; rw [ifp hl]; exact ⟨rfl, h.cc x (of_decide_eq_true hl)⟩
      · intro x' y' hr; simp only [Sess.renaming.injEq] at hr
        obtain ⟨rfl, rfl, hl⟩ := hr
        dsimp only; rw [ifn (by simp [hl])]; exact of_decide_eq_false hl
      · intro ht hc; dsimp only at ht hc; simp [modalUp, ht, hc] at hm
    · exact h
  case renMove =>
    simp only [step]
    split
    · rename_i x y l hs
      split
      · refine cinv_noRen ?_ (fun _ _ _ => by simp)
        intro m hc; dsimp only at hc; split at hc
        · rename_i hlt; cases hc; subst hlt; exact (h.renT x y hs).2
        · exact h.cc m hc
      · refine cinv_noRen ?_ (fun _ _ _ => by simp)
        intro m hc; dsimp only at hc; split at hc
        · rename_i hlt; cases hc; subst hlt; rw [(h.renT x y hs).2]; simp [relabel]
        · rename_i hlf
          have hl : l = false := by simpa using hlf
          subst hl
          have hmx : m ≠ x := fun e => h.renF x y hs (e ▸ hc)
          rw [h.cc m hc]; simp [relabel, hmx]
    · exact h
  case thumbStart =>
    simp only [step]; split
    · rename_i hg
      obtain ⟨-, -, hidle⟩ := hg
      exact cinv_noRen h.cc (fun _ _ _ => by rw [hidle]; simp)
    · exact h
  case thumbInit =>
    simp only [step]; split
    · rename_i hg
      obtain ⟨hrun, -⟩ := hg
      split
      · split
        · exact cinv_of h rfl rfl rfl rfl rfl
        · rename_i hnc
          have hcn : s.cur = none := by
            cases hcur : s.cur with
            | none => rfl
            | some _ => exact absurd (Or.inr (by simp [hcur])) hnc
          have htc : s.tCancel = false := by
            cases hh : s.tCancel with
            | false => rfl
            | true => exact absurd (Or.inl hh) hnc
          exact cinv_noRen (fun g hg' => by simp only [hcn] at hg'; cases hg')
            (h.modal hrun htc)
      · exact h
    · exact h
  case thumbCancel =>
    simp only [step]; split
    · exact ⟨h.cc, h.renT, h.renF, fun _ hc => by simp at hc⟩
    · exact h
  case thumbEnd =>
    simp only [step]; split
    · exact ⟨h.cc, h.renT, h.renF, fun hr => by simp at hr⟩
    · exact h
  all_goals
    simp only [step]
    repeat' split
    all_goals first
      | exact h
      | exact cinv_of h rfl rfl rfl rfl rfl
      | (unfold paintTile; exact cinv_of h rfl rfl rfl rfl rfl)
      | (unfold paintMenu; dsimp only; split <;> exact cinv_of h rfl rfl rfl rfl rfl)
      | (unfold closeMenu; split <;> exact cinv_of h rfl rfl rfl rfl rfl)

theorem cinv_reachable {fix : Bool} {s : State} (h : Reachable fix s) : CInv s := by
  induction h with
  | init => exact ⟨fun _ h => by simp [init] at h, fun _ _ h => by simp [init] at h,
      fun _ _ h => by simp [init] at h, fun h => by simp [init] at h⟩
  | step e _ ih => exact cinv_step fix _ ih e

/-- Whatever `fix`: whenever a game is named, the core holds it. -/
theorem cur_is_core {fix : Bool} {s : State} (h : Reachable fix s) (g : Nat)
    (hc : s.cur = some g) : s.core = some g :=
  (cinv_reachable h).cc g hc

/-- ... so fix (1), the `fbGame` guard in `storeLastFrame` and
`updatePausedCard`, never fires: in every reachable state of the code as it
is, the capture and the card are what the guarded code would produce, and
every capture files the named game's own pixels, every card paints its
label's. -/
theorem fix1_redundant {fix : Bool} {s : State} (h : Reachable fix s) :
    storeFrame false s = storeFrame true s ∧ cardOf false s = cardOf true s ∧
    (∀ g c, cardOf fix s = some (g, c) → g = c) := by
  have hcc := cur_is_core h
  refine ⟨?_, ?_, ?_⟩
  · unfold storeFrame
    split
    · rename_i g c hg hco
      rw [hcc g hg] at hco; cases hco; simp
    · rfl
  · unfold cardOf
    split
    · rename_i g c hg hco
      rw [hcc g hg] at hco; cases hco; simp
    · rfl
  · intro g c hgc
    unfold cardOf at hgc
    split at hgc
    · rename_i g' c' hg hco
      rw [hcc g' hg] at hco; cases hco
      split at hgc
      · cases hgc
      · simp at hgc; obtain ⟨rfl, rfl⟩ := hgc; rfl
    · cases hgc

end WebState.Thumbnails
