-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/index.js: abortRetroClip clipEncode closeClipScrubber closeReportModal closeRewindScrubber emulationActive endClipExport finishRetroClip holdForFlight launchRom loadRom openClipScrubber openReportModal openRewindScrubber playerPaused releaseFlight resumeFromHero resumeGame shortcutKeyHandler showMainMenu startClipExport syncWakeLock takePendingFlight takePlayerPause togglePause unloadGame on:visibilitychange on:pointerup
-- @models web/netplay.js: acquireWakeLock closeNetModal netDismissModal netFail netShutdown openNetConnect rbConnect rbStartIfReady rbTeardown releaseWakeLock

/-
# Run/pause state of the emulator (web/index.js, web/netplay.js)

Written against dd7ba741f, then remodelled at 03f88d6c: the clip export runs
off screen behind a progress panel, and the game's picture flies between the
home screen and the screen, holding the game while it does. `step` now
models the code as fixed in fbdb7975 ("web: a picture flight's hold is not
the player's pause; no drops over a recording clip"), at whose index.js and
netplay.js the line numbers are. The 03f88d6c counterexamples it fixed are
replayed below as `regress_*` theorems.

The core steps in the rAF `tick` (index.js 16148) iff `!paused` and a game is
loaded; rAF does not fire while the tab is hidden. So "running" is
`loaded && !paused && visible`, and every pausing surface works by writing the
one global `paused` (index.js 11540). The writers are:

* the pause button / Space / Period       -> `togglePause`      (12082)
* the peer, in a rollback session         -> `applyRemotePause` (12096)
* Report a Bug, the rewind scrubber, the clip range picker: each snapshots
  `paused` into its own `*WasPaused` on open and writes it back on close
  (9224/9255, 9822/9854, 12883/12927)
* the home screen                         -> `showMainMenu` / `resumeGame` (13551/13580)
* the Link Cable modal                    -> `netFrozeGame` (netplay.js 206, 1557)
* a clip export                           -> `startClipExport` snapshots `paused` into
  `clipExportWasPaused` and sets `paused = false` (12618-12619); `endClipExport`
  writes it back (12397). `endClipExport` runs from `finishRetroClip` (12407:
  the realtime recorder's end in the tick, 16248), from `abortRetroClip`
  (12417, via `finishRetroClip(false)`: the progress panel's Cancel 12635,
  `loadRom`, a failed start), and from the WebCodecs encode's `finally`
  (`clipEncode` 12514-12596, at 12593), guarded there by the export generation
  `clipExportGen` (12307) and `clipReplayActive`: the encode awaits between
  frame batches (12571), and a Cancel or a load landing in one of those awaits
  has already restored `paused`, so the encode's tail returns without touching it
* a flight (`holdForFlight` 14162 / `releaseFlight` 14167, `flightHeld` 14149):
  the hero's Resume (`resumeFromHero` 14196) and a launch from the home screen
  (`loadRom` -> `takePendingFlight` 11759 / 14219) set `paused = true` while the
  picture flies (`FLIGHT_MS` 460, 14058); the flight's end (or the launch's
  2.5 s safety timer, 14226) sets `paused = false` again if `body.running` and
  the pause button is not lit; `showMainMenu` (13559) and `unloadGame` (14288)
  release it first. The hold is not a choice: `playerPaused` (14152) reads the
  pause button while a flight holds, and `takePlayerPause` (14157-14161) also
  takes the run state over from the flight (`flightHeld = false`). Every
  surface that snapshots the player's choice takes it (Report a Bug 9226,
  the rewind scrubber 9827, the clip range picker 12894, the export 12618,
  `togglePause` 12083, netplay's `netFrozeGame`, netplay.js 206), and Period
  asks `playerPaused` (13287)
* `loadRom` (11738), `unloadGame` (14289), `enterRollbackMode` (13443),
  `launchNetRom` (netplay.js 1437), `rbConnect` (1147), and
  `updateForNewerState` (7884, which then reloads the page: not modelled).

The pause button's icon/title (`#pause.paused`, title "Resume") is `lit`.
There is no separate "the user's own pause choice" variable: `lit` is the
closest thing (only `togglePause` and `applyRemotePause` set it from a pause
choice), so the properties are stated against it.

The Screen Wake Lock (index.js 11560-11593) is re-synced on every rAF tick
(16152) and on `visibilitychange`; its `request()` is an await (the `.then` at
11571 is a separate event). netplay.js keeps a second, independent wake lock
for the Link Cable modal (`acquireWakeLock`, netplay.js 942-957), also behind
an await.

## Abstractions (and why they do not affect the properties)

* 2P local link (`linkMode`) and the SIO online path (`netMode`, `launchNetRom`)
  are not modelled; `rb` is the rollback session (`rollbackMode`), whose
  `currentRomName` stays set, so `rb -> loaded`. `emulationActive` (11562) is
  `loaded && !paused`. `rbConnect`'s `paused = true` (netplay.js 1147) happens
  while the Link Cable modal already froze the game, so it is not an event.
* One ROM identity: `loaded` = `!!currentRomName`. `loadRom` is two events:
  its first segment (`loadStart`: `abortRetroClip`, 11669), which a call makes
  at any time, and its synchronous commit (`loadRom`, 11692-11760, after the `dbGet` at 11691), which may
  land at any later time outside a rollback session (a drop on `document`,
  12061, has no modal guard, refusing only while a clip records; a Drive download or IndexedDB read in flight
  under `launchRom`/a tile tap lands whenever it lands; `abandoned()`, 11667,
  drops it in a session). A commit with no `loadStart` before it only adds
  behaviours. The session teardown between them (11676) is `netEnd`. A commit
  that ends in `takePendingFlight`'s hold is `loadRomFly`.
* `unloadGame`'s final synchronous segment (14281-14305) is one event, enabled
  whenever a single-core game is loaded (its awaits let it land late; a
  hand-off's Switch toast, z-index 600 over the progress panel's 500, can
  start one during a clip export).
* `netShutdown`'s post-await tail (`closeNetModal`, netplay.js 1611) is folded
  into its first segment; nothing in the tail touches `paused`/`lit`.
* Non-pausing modals (settings, save states, cheats...) are not modelled: they
  never write `paused`, and while one is open the pause button is covered too.
* User input (taps, keys) requires `visible`; network and timer events do not.
  The tick (and `finishRetroClip` inside it) requires `visible`: rAF stops.
  The WebCodecs encode is timer-driven and may end while hidden, so the
  export's end (`clipDone`) is enabled whenever a replay runs; both ends set
  the same state. During a clip export every control is inert
  (`body.clip-replaying`, styles.css 8645-8649), the progress panel covers the
  page and holds the focus trap, and `shortcutKeyHandler` ignores keys
  (13207), so the panel's Cancel (`clipCancel`) is the only control.
  A stale encode's tail never ends a later export (`clipExportGen`); ending
  a running export early is the same transition as its normal end, so the
  generation is not a field.
* A flight lasts the animation (460 ms) after `resumeGame` or the boot. The
  model lets its end (`flightEnd`) land at any time, also after something
  took the run state over from it or after a later flight began (an earlier
  flight's landing then ends the later hold: harmless, it only unpauses
  what the player left running).
  `resumeFly` is the hero's Resume with motion allowed (`canFly`: Web
  Animations, no `prefers-reduced-motion`); `resume` is the same tap without
  a flight. `body.running` is `loaded && !home`.
* Wake-lock grants follow the Screen Wake Lock spec: the grant task checks
  visibility and resolves in the same task, and the `.then` runs in that
  task's microtask checkpoint, so grant + `.then` is one event (`wakeGrant`),
  but any number of events may run between `request()` and it. A hide
  releases every lock and *queues* a `release` event per lock (`relQ`),
  dispatched later (`relFire`). `uaRevoke` is the UA dropping a held lock for
  its own reasons (battery). Lock identities are fresh naturals.
* Audio: only `audioCtx.state === "running"` (`ctxRunning`); the code does
  not promise to suspend it on pause (see `obs_pause_keeps_audio_context`).

## Results

* `inv_reachable`: the run/pause discipline (`Inv`) holds in every reachable
  state, flights included.
* At 03f88d6c a flight's hold was a plain `paused = true` that every surface
  read as the player's pause: an overlay opened during it ran the game behind
  it once the picture landed and then left it frozen under a Pause icon, the
  Link Cable modal did not freeze it, and Pause during it unpaused. The same
  traces now end safely: `regress_overlay_in_flight_runs_behind`,
  `regress_overlay_in_flight_sticks_paused`,
  `regress_link_modal_in_flight_runs_behind`, `regress_pause_in_flight_lost`.
* The wake-lock and Link Cable lock results hold in every reachable state.
-/
namespace WebState.RunPause

/-- The run/pause part of the state. -/
structure Pz where
  loaded     : Bool   -- !!currentRomName (index.js 11523)
  rb         : Bool   -- rollbackMode (enterRollbackMode 13432)
  paused     : Bool   -- paused (11540)
  lit        : Bool   -- pauseButton.classList "paused"/"active" + title "Resume"
  home       : Bool   -- a loaded game with body.running removed (showMainMenu 13551)
  report     : Bool   -- reportModal.classList "open"
  reportWas  : Bool   -- reportWasPaused (9163)
  rw         : Bool   -- rewindModal.classList "open"
  rwWas      : Bool   -- rwWasPaused (9743)
  clip       : Bool   -- clipModal.classList "open"
  clipWas    : Bool   -- clipWasPaused (12672)
  netModal   : Bool   -- netModal.classList "open" (netplay.js)
  netFroze   : Bool   -- netFrozeGame (netplay.js 172)
  replay     : Bool   -- clipReplayActive (12303), with the progress panel open
  exportWas  : Bool   -- clipExportWasPaused (12310)
  flight     : Bool   -- flightHeld (14149)

/-- The page-lifecycle, wake-lock and audio part of the state. -/
structure Wk where
  visible    : Bool          -- document.visibilityState === "visible"
  bfcache    : Bool          -- between pagehide and pageshow
  ctxRunning : Bool          -- audioCtx.state === "running"
  sentinel   : Option Nat    -- wakeSentinel (11560)
  requesting : Bool          -- wakeRequesting (11561) = the request's .then is pending
  netLock    : Option Nat    -- screenLock (netplay.js 941)
  netPending : Nat           -- acquireWakeLock() continuations in flight (netplay.js 942)
  idxLocks   : List Nat      -- UA-held screen locks obtained by syncWakeLock
  netLocks   : List Nat      -- UA-held screen locks obtained by acquireWakeLock
  relQ       : List Nat      -- queued WakeLockSentinel "release" events
  nextId     : Nat           -- fresh lock identities

structure State where
  p : Pz
  w : Wk

def init : State :=
  { p := { loaded := false, rb := false, paused := false, lit := false, home := false,
           report := false, reportWas := false, rw := false, rwWas := false,
           clip := false, clipWas := false, netModal := false, netFroze := false,
           replay := false, exportWas := false, flight := false },
    w := { visible := true, bfcache := false, ctxRunning := false, sentinel := none,
           requesting := false, netLock := none, netPending := 0, idxLocks := [],
           netLocks := [], relQ := [], nextId := 0 } }

inductive Event where
  | pauseTap              -- #pause pointerup/click (12119-12131); shown only in the game view (styles.css 1090-1096)
  | pauseKey              -- Space (13241) / Period (13283) -> pauseButton.click(), in the game view
  | remotePause (on : Bool) -- RB_PAUSE from the peer (netplay.js 1204) -> applyRemotePause (12096)
  | openReport | closeReport          -- 9224 / 9255
  | openRw | closeRw                  -- 9822 / 9854
  | openClip | closeClip              -- 12883 / 12927
  | clipSave                          -- clipSaveBtn (12936): closeClipScrubber + startClipExport
  | clipDone                          -- the export's end: tick -> finishRetroClip(true) (16248 / 12407),
                                      --   or the encode's finally -> endClipExport (12593 / 12394)
  | clipCancel                        -- the progress panel's Cancel (12635) -> abortRetroClip (12417)
  | mainMenu | resume                 -- showMainMenu 13551 / resumeGame 13580
  | resumeFly                         -- the hero's Resume, flying: resumeFromHero (14196-14203)
  | loadStart                         -- loadRom's first segment: abortRetroClip (11669)
  | loadRom                           -- loadRom's commit segment (11692-11760)
  | loadRomFly                        -- ...ending in takePendingFlight's hold (11759, 14219-14225)
  | flightEnd                         -- releaseFlight (14167) at the flight's end (14202, 14232)
                                      --   or the launch's safety timer (14226)
  | unload                            -- unloadGame's final segment (14281-14305)
  | openNet                           -- openNetConnect after its awaits (netplay.js 176-211)
  | netDismiss                        -- netDismissModal -> netShutdown, pre-session (netplay.js 1615)
  | netFailKeep                       -- netFail pre-session: netShutdown({ keepModal: true }) (netplay.js 236-244)
  | netStart                          -- rbStartIfReady: closeNetModal + enterRollbackMode (netplay.js 1301)
  | netEnd                            -- netShutdown of a session (netplay.js 1547-1568 + rbTeardown)
  | tabHide | tabShow                 -- visibilitychange (index 11593; netplay.js 959)
  | tick                              -- rAF tick -> syncWakeLock (16152)
  | wakeGrant | wakeDeny              -- wakeLock.request(...).then / .catch (11571 / 11583)
  | netGrant | netDeny                -- acquireWakeLock's await resumes / throws (netplay.js 944)
  | relFire                           -- a queued "release" event is dispatched (listener 11579)
  | uaRevoke                          -- the UA drops the page's held lock (battery, ...)
  | pagehide | pageshow | gesture     -- 16049 / 16069 / resumeAudio (15878) on a user gesture
  deriving DecidableEq, Repr

def anyModal (p : Pz) : Bool := p.report || p.rw || p.clip || p.netModal

/-- emulationActive (11562). -/
def active (p : Pz) : Bool := p.loaded && !p.paused
/-- syncWakeLock's `want` (11566): running and visible. -/
def want (s : State) : Bool := active s.p && s.w.visible

/-- `s.release()` on a sentinel the page holds: the spec removes it at once and
queues its "release" event. -/
def relIdx (w : Wk) (l : Nat) : Wk :=
  if l ∈ w.idxLocks then
    { w with idxLocks := w.idxLocks.filter (fun x => x != l), relQ := w.relQ ++ [l] }
  else w

/-- syncWakeLock (11564-11592), its synchronous part. -/
def syncW (p : Pz) (w : Wk) : Wk :=
  if active p && w.visible && w.sentinel.isNone && !w.requesting then
    { w with requesting := true }                                   -- 11567-11570
  else if !(active p && w.visible) then
    match w.sentinel with
    | some l => relIdx { w with sentinel := none } l                -- 11587-11590
    | none => w
  else w

/-- releaseWakeLock (netplay.js 953). -/
def releaseNetLock (w : Wk) : Wk :=
  match w.netLock with
  | some l =>
    if l ∈ w.netLocks then
      { w with netLock := none, netLocks := w.netLocks.filter (fun x => x != l),
               relQ := w.relQ ++ [l] }
    else { w with netLock := none }
  | none => w

section relproj
variable (w : Wk)
@[simp] theorem releaseNetLock_visible : (releaseNetLock w).visible = w.visible := by
  unfold releaseNetLock; split <;> (try split) <;> rfl
@[simp] theorem releaseNetLock_sentinel : (releaseNetLock w).sentinel = w.sentinel := by
  unfold releaseNetLock; split <;> (try split) <;> rfl
@[simp] theorem releaseNetLock_idxLocks : (releaseNetLock w).idxLocks = w.idxLocks := by
  unfold releaseNetLock; split <;> (try split) <;> rfl
@[simp] theorem releaseNetLock_nextId : (releaseNetLock w).nextId = w.nextId := by
  unfold releaseNetLock; split <;> (try split) <;> rfl
@[simp] theorem releaseNetLock_requesting : (releaseNetLock w).requesting = w.requesting := by
  unfold releaseNetLock; split <;> (try split) <;> rfl
@[simp] theorem releaseNetLock_netPending : (releaseNetLock w).netPending = w.netPending := by
  unfold releaseNetLock; split <;> (try split) <;> rfl
end relproj

/-- playerPaused (14152): the pause button while a flight holds the game. -/
def playerP (p : Pz) : Bool := if p.flight then p.lit else p.paused

/-- togglePause (12082-12085): `paused = !takePlayerPause()`; the relay to the
peer is not state here. -/
def togglePause (p : Pz) : Pz :=
  { p with paused := !playerP p, lit := !playerP p, flight := false }

def closeReportM (p : Pz) : Pz :=      -- closeReportModal (9255)
  if p.report then { p with report := false, paused := p.reportWas } else p
def closeRwM (p : Pz) : Pz :=          -- closeRewindScrubber (9854)
  if p.rw then { p with rw := false, paused := p.rwWas } else p
def closeClipM (p : Pz) : Pz :=        -- closeClipScrubber (12927)
  if p.clip then { p with clip := false, paused := p.clipWas } else p

/-- netShutdown's thaw (netplay.js 1557-1563), outside netFail's keepModal. -/
def thaw (p : Pz) : Pz :=
  if p.netFroze then { p with netFroze := false, paused := false, lit := false } else p

/-- startClipExport (12607-12633), the arming path: it takes the player's
pause (12618-12619) and opens the progress panel. -/
def startClip (p : Pz) : Pz :=
  if !p.replay && p.loaded && !p.rb then
    { p with replay := true, exportWas := playerP p, paused := false, flight := false }
  else p

/-- netDismissModal, pre-session (netplay.js 1615): netShutdown's thaw and the
modal closed; the `netDismiss` event's effect. -/
def closeNetM (p : Pz) : Pz := if p.netModal then { thaw p with netModal := false } else p

/-- abortRetroClip -> finishRetroClip(false) -> endClipExport (12417 / 12407 / 12394). -/
def abortClip (p : Pz) : Pz :=
  if p.replay then { p with replay := false, paused := p.exportWas } else p

/-- releaseFlight (14167-14173): `paused = false` if `body.running` and the
pause button is not lit. -/
def releaseFlight (p : Pz) : Pz :=
  if p.flight then
    { p with flight := false, paused := if p.loaded && !p.home && !p.lit then false else p.paused }
  else p

/-- loadRom's commit (11692-11760): abortRetroClip (11725); closeRewindScrubber();
closeClipScrubber(); closeReportModal(); an open Link Cable modal:
netDismissModal (11737); paused = false; the button reset; body.running. -/
def commitLoad (p : Pz) : Pz :=
  { closeNetM (closeReportM (closeClipM (closeRwM (abortClip p)))) with
      loaded := true, paused := false, lit := false, home := false }

/-- What the commit leaves: every overlay and the replay closed, the new game
running with the icon to match, and the Link Cable freeze gone with the modal. -/
theorem commitLoad_fields (p : Pz) :
    (commitLoad p).report = false ∧ (commitLoad p).rw = false ∧ (commitLoad p).clip = false ∧
    (commitLoad p).netModal = false ∧ (commitLoad p).replay = false ∧
    (commitLoad p).loaded = true ∧ (commitLoad p).paused = false ∧
    (commitLoad p).lit = false ∧ (commitLoad p).home = false ∧ (commitLoad p).rb = p.rb ∧
    ((commitLoad p).netFroze = true → p.netFroze = true ∧ p.netModal = false) := by
  unfold commitLoad closeNetM closeReportM closeClipM closeRwM abortClip thaw
  (repeat' split) <;> simp_all

/-- netShutdown of a session (netplay.js 1547-1568): thaw (a no-op in a
session); the session hands the game back as it is; rbTeardown ->
leaveRollbackMode runs before rbTeardown's first await. -/
def endSession (p : Pz) : Pz := { thaw p with rb := false, netModal := false }

def stepP (p : Pz) : Event → Pz
  | .pauseTap => togglePause p
  | .pauseKey => if p.home then p else togglePause p     -- 13236-13244: the game view only
  -- 12096-12104: not on home; under Report a Bug, the choice closing it gives back
  | .remotePause on =>
    if p.home then p
    else if p.report then { p with reportWas := on, lit := on }
    else if p.paused != on then togglePause p else p
  -- 9226 / 9827 / 12894: takePlayerPause()
  | .openReport => { p with reportWas := playerP p, paused := true, report := true, flight := false }
  | .closeReport => closeReportM p
  | .openRw => { p with rwWas := playerP p, paused := true, rw := true, flight := false }
  | .closeRw => closeRwM p
  | .openClip => { p with clipWas := playerP p, paused := true, clip := true, flight := false }
  | .closeClip => closeClipM p
  | .clipSave => startClip (closeClipM p)
  | .clipDone => { p with replay := false, paused := p.exportWas }   -- endClipExport 12397
  | .clipCancel => abortClip p
  -- releaseFlight (13559), then paused = true; the button is untouched
  | .mainMenu => { p with paused := true, home := true, flight := false }
  | .resume => { p with paused := false, lit := false, home := false }
  -- resumeGame, then holdForFlight (14162): paused = true again, the button unlit
  | .resumeFly => { p with paused := true, lit := false, home := false, flight := true }
  | .loadStart => abortClip p
  | .loadRom => commitLoad p
  | .loadRomFly => { commitLoad p with paused := true, flight := true }
  | .flightEnd => releaseFlight p
  | .unload => { p with loaded := false, paused := true, lit := false, home := false,
                        flight := false }
  | .openNet =>
    -- netFrozeGame = !!currentRomName && !takePlayerPause() (netplay.js 206)
    let fr := p.loaded && !playerP p
    { p with netModal := true, netFroze := fr, paused := p.paused || fr, lit := p.lit || fr,
             flight := if p.loaded then false else p.flight }
  | .netDismiss => { thaw p with netModal := false }
  | .netFailKeep => p                                     -- the modal stays open: no thaw (1556)
  | .netStart =>                                          -- netFrozeGame = false; enterRollbackMode
    { p with netModal := false, netFroze := false, rb := true, paused := false, lit := false,
             home := false }
  | .netEnd => endSession p
  -- pagehide (16049-16051): netShutdown() in a session, as beforeunload
  | .pagehide => if p.rb then endSession p else p
  | _ => p

def stepW (p : Pz) (w : Wk) : Event → Wk
  | .openNet => { w with netPending := w.netPending + 1 }   -- acquireWakeLock() (netplay.js 189)
  | .netDismiss | .netStart | .netEnd => releaseNetLock w     -- closeNetModal (netplay.js 110)
  | .loadRom | .loadRomFly =>
    if p.netModal then releaseNetLock w else w               -- netDismissModal (11737)
  | .tabHide =>
    -- the UA releases every screen lock and queues their "release" events; then the
    -- visibilitychange listeners: syncWakeLock (11593); netplay's only stamps a time (959)
    syncW p { w with visible := false, relQ := w.relQ ++ w.idxLocks ++ w.netLocks,
                     idxLocks := [], netLocks := [] }
  | .tabShow =>
    let w := syncW p { w with visible := true }
    if p.netModal then { w with netPending := w.netPending + 1 } else w   -- netplay.js 965
  | .tick => syncW p w
  | .wakeGrant =>
    if !w.visible then { w with requesting := false }      -- rejected: .catch (11583)
    else
      let n := w.nextId
      if !active p then                                    -- 11574-11576: s.release()
        { w with requesting := false, nextId := n + 1, relQ := w.relQ ++ [n] }
      else                                                 -- 11578
        { w with requesting := false, nextId := n + 1, idxLocks := n :: w.idxLocks,
                 sentinel := some n }
  | .wakeDeny => { w with requesting := false }
  | .netGrant =>
    if !w.visible then { w with netPending := w.netPending - 1 }   -- rejected: catch {}
    else
      -- 943-949: releaseWakeLock(); keep the new lock only while the modal is up
      let w := releaseNetLock w
      let n := w.nextId
      if p.netModal then
        { w with netPending := w.netPending - 1, nextId := n + 1,
                 netLocks := n :: w.netLocks, netLock := some n }
      else
        { w with netPending := w.netPending - 1, nextId := n + 1, relQ := w.relQ ++ [n] }
  | .netDeny => { w with netPending := w.netPending - 1 }
  | .relFire =>
    match w.relQ with
    | [] => w
    | l :: r => { w with relQ := r,
                         sentinel := if w.sentinel == some l then none else w.sentinel }  -- 11580
  | .uaRevoke =>
    match w.idxLocks with
    | [] => w
    | l :: r => { w with idxLocks := r, relQ := w.relQ ++ [l] }
  -- pagehide: a session's netShutdown (16051; its closeNetModal is the folded
  -- tail); the context is suspended (16063)
  | .pagehide =>
    let w := if p.rb then releaseNetLock w else w
    { w with ctxRunning := false, bfcache := true }
  | .pageshow => { w with bfcache := false, ctxRunning := w.ctxRunning || p.loaded }  -- 16069
  | .gesture => { w with ctxRunning := true }
  | _ => w

def step (s : State) (e : Event) : State := { p := stepP s.p e, w := stepW s.p s.w e }

/-- When the event can happen. -/
def en (s : State) : Event → Bool
  | .pauseTap => s.w.visible && s.p.loaded && !anyModal s.p && !s.p.home && !s.p.replay
  | .pauseKey => s.w.visible && s.p.loaded && !anyModal s.p && !s.p.replay  -- 13207, 13227, 13236
  | .remotePause _ => s.p.rb
  | .openReport => s.w.visible && !anyModal s.p && !s.p.replay   -- the menu, or the hero's ⋯ (6711)
  | .closeReport | .closeRw | .closeClip => s.w.visible  -- buttons; Escape runs every closer (7396-7415)
  | .openRw => s.w.visible && s.p.loaded && !s.p.rb && !s.p.home && !anyModal s.p && !s.p.replay  -- 9822-9825, styles 1159
  | .openClip => s.w.visible && s.p.loaded && !s.p.rb && !s.p.home && !anyModal s.p && !s.p.replay
  | .clipSave => s.w.visible && s.p.clip
  | .clipDone => s.p.replay
  | .clipCancel => s.w.visible && s.p.replay
  | .mainMenu => s.w.visible && s.p.loaded && !s.p.home && !anyModal s.p && !s.p.replay
  | .resume => s.w.visible && s.p.loaded && s.p.home && !anyModal s.p
  -- in a session drawPausedHero hides the hero (13931): no flight from it
  | .resumeFly => s.w.visible && s.p.loaded && s.p.home && !anyModal s.p && !s.p.rb
  | .loadStart => true
  | .loadRom | .loadRomFly => !s.p.rb
  | .flightEnd => true
  | .unload => s.p.loaded && !s.p.rb
  | .openNet => s.w.visible && !anyModal s.p && !s.p.rb && !s.p.replay
  | .netDismiss => s.w.visible && s.p.netModal && !s.p.rb
  | .netFailKeep => s.p.netModal && !s.p.rb
  | .netStart => s.p.netModal && s.p.loaded && !s.p.rb
  | .netEnd => s.p.rb
  | .tabHide => s.w.visible
  | .tabShow => !s.w.visible && !s.w.bfcache
  | .tick => s.w.visible
  | .wakeGrant | .wakeDeny => s.w.requesting
  | .netGrant | .netDeny => decide (s.w.netPending > 0)
  | .relFire => !s.w.relQ.isEmpty
  | .uaRevoke => !s.w.idxLocks.isEmpty
  | .pagehide => !s.w.visible && !s.w.bfcache
  | .pageshow => s.w.bfcache
  | .gesture => s.w.visible

inductive Reachable : State → Prop
  | init : Reachable init
  | step {s e} : Reachable s → en s e = true → Reachable (step s e)

def run (s : State) : List Event → Option State
  | [] => some s
  | e :: es => if en s e then run (step s e) es else none

theorem run_reachable {s t : State} {es : List Event} (hs : Reachable s)
    (h : run s es = some t) : Reachable t := by
  induction es generalizing s with
  | nil => simp [run] at h; exact h ▸ hs
  | cons e es ih =>
    simp only [run] at h
    split at h
    · exact ih (Reachable.step hs (by assumption)) h
    · cases h

/-- A trace from `init`, enabled at every step, that ends in a `bad` state. -/
def witnesses (es : List Event) (bad : State → Bool) : Bool :=
  match run init es with
  | some s => bad s
  | none => false

theorem witness_sound {es : List Event} {bad : State → Bool}
    (h : witnesses es bad = true) : ∃ s, Reachable s ∧ bad s = true := by
  unfold witnesses at h
  split at h
  · exact ⟨_, run_reachable Reachable.init (by assumption), h⟩
  · cases h

/-! ## Part 1: the run/pause discipline -/

/-- The intended properties, plus the bookkeeping that makes them inductive.
* `frozen`:  a loaded game never steps behind a pausing overlay or the home screen.
* `label`:   with nothing over the game, the button's icon/title matches `paused`
  (a clip export's replay, which greys every control out, runs regardless; a
  flight holds the game paused under the unlit icon until it lands).
* `restore*`: each open overlay, and a running clip export, remembers exactly
  the user's own choice, so closing it gives that choice back (neither sticks
  the game paused nor unpauses a game the user paused).
* `fly`: a flight holds the game in view with nothing over it and the icon
  unlit, so its end (`paused = false`) gives the player's choice back. -/
structure Inv (p : Pz) : Prop where
  rbLoaded : p.rb = true → p.loaded = true
  excl1    : p.report = true → p.rw = false ∧ p.clip = false ∧ p.netModal = false
  excl2    : p.rw = true → p.clip = false ∧ p.netModal = false
  excl3    : p.clip = true → p.netModal = false
  rwHome   : p.rw = true → p.home = false ∧ p.rb = false
  clipHome : p.clip = true → p.home = false ∧ p.rb = false
  netRb    : p.netModal = true → p.rb = false
  frozen   : p.loaded = true → (p.report || p.rw || p.clip || p.netModal || p.home) = true →
               p.paused = true
  label    : p.loaded = true → (p.report || p.rw || p.clip || p.netModal) = false →
               p.home = false → p.replay = false → p.flight = false → p.paused = p.lit
  restoreReport : p.loaded = true → p.report = true → p.reportWas = (p.lit || p.home)
  restoreRw     : p.loaded = true → p.rw = true → p.rwWas = p.lit
  restoreClip   : p.loaded = true → p.clip = true → p.clipWas = p.lit
  restoreExport : p.loaded = true → p.replay = true → p.exportWas = p.lit
  replayQuiet : p.replay = true → p.rb = false ∧ p.home = false ∧
                  (p.report || p.rw || p.clip || p.netModal) = false
  netFroze1 : p.netFroze = true → p.netModal = true ∧ (p.loaded = true → p.home = false ∧ p.lit = true)
  netOwn    : p.loaded = true → p.netModal = true → p.netFroze = false → p.home = false →
                p.lit = true
  fly       : p.flight = true → p.loaded = true ∧ p.rb = false ∧ p.home = false ∧
                p.lit = false ∧ p.replay = false ∧ (p.report || p.rw || p.clip || p.netModal) = false

theorem inv_init : Inv init.p := by
  constructor <;> simp [init]

theorem commitLoad_flight (p : Pz) : (commitLoad p).flight = p.flight := by
  unfold commitLoad closeNetM closeReportM closeClipM closeRwM abortClip thaw
  (repeat' split) <;> rfl

theorem inv_commitLoad {p : Pz} (h : Inv p) (hrb : p.rb = false) : Inv (commitLoad p) := by
  obtain ⟨c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11⟩ := commitLoad_fields p
  have c12 := commitLoad_flight p
  have nf : (commitLoad p).netFroze = false := by
    cases hf : (commitLoad p).netFroze
    · rfl
    · obtain ⟨a, b⟩ := c11 hf; rw [(h.netFroze1 a).1] at b; cases b
  constructor <;> simp [c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c12, hrb, nf]

/-- A boot that lands under the launch's flight. -/
theorem inv_commitLoadFly {p : Pz} (h : Inv p) (hrb : p.rb = false) :
    Inv { commitLoad p with paused := true, flight := true } := by
  obtain ⟨c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11⟩ := commitLoad_fields p
  have nf : (commitLoad p).netFroze = false := by
    cases hf : (commitLoad p).netFroze
    · rfl
    · obtain ⟨a, b⟩ := c11 hf; rw [(h.netFroze1 a).1] at b; cases b
  constructor <;> simp [c1, c2, c3, c4, c5, c6, c8, c9, c10, hrb, nf]

set_option maxHeartbeats 4000000 in
theorem inv_step {s : State} {e : Event} (h : Inv s.p) (he : en s e = true) :
    Inv (step s e).p := by
  cases e
  case loadRom =>
    simp only [en, Bool.not_eq_eq_eq_not, Bool.not_true] at he
    exact inv_commitLoad h he
  case loadRomFly =>
    simp only [en, Bool.not_eq_eq_eq_not, Bool.not_true] at he
    exact inv_commitLoadFly h he
  all_goals
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17⟩ := h
    simp only [en, anyModal] at he
    constructor <;> simp only [step, stepP, togglePause, playerP, closeReportM, closeRwM,
      closeClipM, thaw, endSession, startClip, abortClip, releaseFlight] <;> (repeat' split) <;> grind

/-- **The run/pause discipline holds in every reachable state**, whatever the
interleaving of taps, keys, the peer, overlays, the home screen, loads, closes,
link sessions, clip exports (and their Cancel, and their ends landing late),
flights (and whatever the player does while one holds the game), hides and
page lifecycle. -/
theorem inv_reachable {s : State} (h : Reachable s) : Inv s.p := by
  induction h with
  | init => exact inv_init
  | step _ he ih => exact inv_step ih he

/-- Corollary (frozen): a loaded game never runs behind Report a Bug, a
scrubber, the Link Cable modal or the home screen. -/
theorem frozen_reachable {s : State} (h : Reachable s) (hl : s.p.loaded = true)
    (ho : (anyModal s.p || s.p.home) = true) : active s.p = false := by
  have := (inv_reachable h).frozen hl
  simp only [anyModal] at ho
  simp [active, this ho]

/-- Corollary (label): with nothing over the game and no flight on its way,
the icon says what the core does. -/
theorem label_reachable {s : State} (h : Reachable s) (hl : s.p.loaded = true)
    (hm : anyModal s.p = false) (hh : s.p.home = false) (hr : s.p.replay = false)
    (hf : s.p.flight = false) : s.p.paused = s.p.lit :=
  (inv_reachable h).label hl hm hh hr hf

/-- Corollary: a pause tap always flips the player's choice, and the core
follows it, during a flight too (the flight's hold is not the choice). -/
theorem pause_tap_flips {s : State} (h : Reachable s) (he : en s .pauseTap = true) :
    (step s .pauseTap).p.lit = !s.p.lit ∧ (step s .pauseTap).p.paused = (step s .pauseTap).p.lit ∧
    (step s .pauseTap).p.flight = false := by
  have hI := inv_reachable h
  simp only [en, anyModal, Bool.and_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true] at he
  obtain ⟨⟨⟨⟨hv, hl⟩, hm⟩, hh⟩, hr⟩ := he
  have hm' : (s.p.report || s.p.rw || s.p.clip || s.p.netModal) = false := hm
  cases hf : s.p.flight
  · have := hI.label hl hm' hh hr hf
    simp [step, stepP, togglePause, playerP, hf, this]
  · simp [step, stepP, togglePause, playerP, hf]

/-! ### The old traces, on the fixed code -/

/-- The core steps (visible, loaded, unpaused) with a pausing overlay or the home
screen in front of it. -/
def runsBehind (s : State) : Bool :=
  s.p.loaded && (anyModal s.p || s.p.home) && !s.p.paused && s.w.visible

/-- Nothing covers the game, no flight is on its way to it, and the pause
button's icon/title contradicts `paused`. -/
def labelWrong (s : State) : Bool :=
  s.p.loaded && !anyModal s.p && !s.p.home && !s.p.replay && !s.p.flight && (s.p.paused != s.p.lit)

/-- Was `bug_space_on_home_runs_game`: Space (or Period) on the home screen.
`shortcutKeyHandler` now acts on the game keys only with `body.running`
(13236-13238), so the game `showMainMenu` froze stays frozen. -/
theorem regress_space_on_home_runs_game :
    witnesses [.loadRom, .mainMenu, .pauseKey] (fun s => s.p.home && !runsBehind s) = true := by
  decide

/-- Was `bug_remote_resume_under_report_runs`: in a rollback session the peer
pauses, the player opens Report a Bug, the peer resumes. `applyRemotePause`
now leaves the core frozen under the report... -/
theorem regress_remote_resume_under_report_runs :
    witnesses [.loadRom, .openNet, .netStart, .remotePause true, .openReport,
               .remotePause false] (fun s => s.p.report && !runsBehind s) = true := by decide

/-- ...and closing the report gives back the peer's latest choice (running), with
the icon to match. -/
theorem regress_remote_resume_under_report_sticks_paused :
    witnesses [.loadRom, .openNet, .netStart, .remotePause true, .openReport,
               .remotePause false, .closeReport]
      (fun s => !labelWrong s && !s.p.paused) = true := by decide

/-- Was `bug_remote_resume_on_home_runs`: Main Menu during a session, then the
peer pauses and resumes: the home screen keeps its pause. -/
theorem regress_remote_resume_on_home_runs :
    witnesses [.loadRom, .openNet, .netStart, .mainMenu, .remotePause true,
               .remotePause false] (fun s => s.p.home && !runsBehind s) = true := by decide

/-- Was `bug_link_end_keeps_resume_icon`: paused in a session, then the peer
leaves. The session now hands the game back paused, as the icon says. -/
theorem regress_link_end_keeps_resume_icon :
    witnesses [.loadRom, .openNet, .netStart, .pauseTap, .netEnd]
      (fun s => !labelWrong s && s.p.paused && s.p.lit) = true := by decide

/-- Was `bug_link_end_on_home_runs`: on the home screen during a session, the
peer leaving no longer unpauses the core behind the library. -/
theorem regress_link_end_on_home_runs :
    witnesses [.loadRom, .openNet, .netStart, .mainMenu, .netEnd]
      (fun s => s.p.home && !runsBehind s) = true := by decide

/-- Was `bug_clip_export_drops_pause`: a clip exported from a paused game. The
replay still runs unpaused, and its end (`endClipExport`, 12397) now puts the
player's pause back. -/
theorem regress_clip_export_drops_pause :
    witnesses [.loadRom, .pauseTap, .openClip, .clipSave, .clipDone]
      (fun s => !labelWrong s && s.p.paused && s.p.lit && !s.p.replay) = true := by decide

/-- Was `bug_link_setup_error_thaws_under_modal`: a setup failure (netFail ->
`netShutdown({ keepModal: true })`) no longer thaws the game under the modal
that stays up for the retry; dismissing the modal does. -/
theorem regress_link_setup_error_thaws_under_modal :
    witnesses [.loadRom, .openNet, .netFailKeep]
      (fun s => s.p.netModal && !runsBehind s) = true := by decide

theorem regress_link_setup_error_then_dismiss :
    witnesses [.loadRom, .openNet, .netFailKeep, .netDismiss]
      (fun s => !s.p.netModal && !s.p.paused && !labelWrong s) = true := by decide

/-- Was `bug_load_under_report_runs`: a ROM dropped on the page (or a launch
whose download was in flight) while Report a Bug is open. `loadRom`'s commit now
closes the report (11736) before `paused = false`, restoring the old session's
state first, so the new game does not run under it... -/
theorem regress_load_under_report_runs :
    witnesses [.loadRom, .pauseTap, .openReport, .loadStart, .loadRom]
      (fun s => !s.p.report && !runsBehind s && !labelWrong s) = true := by decide

/-- ...and a later close of the report (Escape runs every closer) finds it
closed: the new game keeps running, with the icon to match. -/
theorem regress_load_under_report_sticks_paused :
    witnesses [.loadRom, .pauseTap, .openReport, .loadStart, .loadRom, .closeReport]
      (fun s => !labelWrong s && !s.p.paused && !s.p.lit) = true := by decide

/-- Was `bug_load_under_link_modal_runs`: a paused game (so `netFrozeGame`
stayed false) replaced by a dropped ROM under the Link Cable modal. The commit
now dismisses the modal (11737), and with it the modal's wake lock. -/
theorem regress_load_under_link_modal_runs :
    witnesses [.loadRom, .pauseTap, .openNet, .netGrant, .loadStart, .loadRom]
      (fun s => !s.p.netModal && !runsBehind s && !labelWrong s &&
                s.w.netLocks.isEmpty) = true := by decide

/-- A clip export started on the outgoing game while a load is in flight
(between `loadRom`'s first segment and its commit): the commit ends it too
(11725), so the capture does not run on into the new game, and its end does not
write the old game's pause onto the new one. (Without that abort the replay is
still running here, and its end, `clipDone`, froze the new game under a Pause
icon.) -/
theorem regress_load_during_clip_export :
    witnesses [.loadRom, .pauseTap, .loadStart, .openClip, .clipSave, .loadRom]
      (fun s => !s.p.replay && !s.p.paused && !labelWrong s) = true := by decide

/-! ### The off-screen export (fa62cc6b): Cancel, and a load mid-encode -/

/-- Cancel on the progress panel, from a paused game: `abortRetroClip` puts
the player's pause back, with the icon to match. -/
theorem clip_cancel_restores_pause :
    witnesses [.loadRom, .pauseTap, .openClip, .clipSave, .clipCancel]
      (fun s => !s.p.replay && s.p.paused && s.p.lit && !labelWrong s) = true := by decide

/-- A ROM dropped (or a download landing) while the WebCodecs encode is
between frame batches: the load's first segment aborts the export, restoring
the old game's pause, and the commit runs the new game. The encode's tail then
finds `clipReplayActive` false (or a newer `clipExportGen`) and returns without
touching `paused`: no export end is pending (`clipDone` is not enabled). -/
theorem clip_load_mid_encode :
    witnesses [.loadRom, .pauseTap, .openClip, .clipSave, .loadStart, .loadRom]
      (fun s => !s.p.replay && !s.p.paused && !s.p.lit && !labelWrong s &&
                !en s .clipDone) = true := by decide

/-- A Cancel's restore is final: the encode's tail cannot end the export a
second time, whatever lands in between (here a fresh pause and resume). -/
theorem clip_cancel_then_tail :
    witnesses [.loadRom, .openClip, .clipSave, .clipCancel, .pauseTap]
      (fun s => s.p.paused && s.p.lit && !en s .clipDone) = true := by decide

/-! ### Flights: the 03f88d6c counterexamples, on the fixed code

At 03f88d6c `holdForFlight` (14162) wrote the one global `paused`, and every
other pausing surface read that global as the player's choice. Each surface
now takes the player's choice from the flight (`takePlayerPause`, 14157). -/

/-- Was `bug_overlay_in_flight_runs_behind`: the player resumes from the hero
and, while the picture is still flying, double-taps Rewind (or opens Report a
Bug, or Clip that!). The scrubber used to snapshot the flight's pause as the
player's, and the landing ran the game behind it. The scrubber now takes the
run state over from the flight: the landing lets go of nothing. -/
theorem regress_overlay_in_flight_runs_behind :
    witnesses [.loadRom, .mainMenu, .resumeFly, .openRw, .flightEnd]
      (fun s => s.p.rw && !runsBehind s) = true := by
  decide

/-- Was `bug_overlay_in_flight_sticks_paused`: closing the overlay used to give
back the flight's pause, freezing the game under a Pause icon. It now gives
back the player's choice (running). The same from a launch's flight with
Report a Bug. -/
theorem regress_overlay_in_flight_sticks_paused :
    witnesses [.loadRom, .mainMenu, .resumeFly, .openRw, .flightEnd, .closeRw]
      (fun s => !labelWrong s && !s.p.paused && !s.p.lit) = true ∧
    witnesses [.loadStart, .loadRomFly, .openReport, .flightEnd, .closeReport]
      (fun s => !labelWrong s && !s.p.paused && !s.p.lit) = true := by
  decide

/-- Was `bug_link_modal_in_flight_runs_behind`: the Link Cable modal opened
during a launch's flight saw the game paused and did not freeze it; the
landing ran it behind the modal. `netFrozeGame` now reads the player's choice
(netplay.js 206): the modal freezes the game, and dismissing it thaws it. -/
theorem regress_link_modal_in_flight_runs_behind :
    witnesses [.loadStart, .loadRomFly, .openNet, .flightEnd]
      (fun s => s.p.netModal && s.p.netFroze && !runsBehind s) = true ∧
    witnesses [.loadStart, .loadRomFly, .openNet, .flightEnd, .netDismiss]
      (fun s => !s.p.paused && !s.p.lit && !labelWrong s) = true := by
  decide

/-- Was `bug_pause_in_flight_lost`: Pause (the button, Space) while the picture
is flying used to flip the flight's hold and run the game at once. It now
pauses, lights the button, and the landing keeps it (Period asks the same
choice, 13287, and pauses rather than stepping). -/
theorem regress_pause_in_flight_lost :
    witnesses [.loadRom, .mainMenu, .resumeFly]
      (fun s => en s .pauseTap && s.p.lit != (step s .pauseTap).p.lit &&
                !active (step s .pauseTap).p &&
                !active (step (step s .pauseTap) .flightEnd).p) = true := by decide

/-- A flight left alone lands on the player's choice. -/
theorem flight_alone_lands :
    witnesses [.loadRom, .mainMenu, .resumeFly, .tick, .flightEnd]
      (fun s => !s.p.flight && !s.p.paused && !s.p.lit && !labelWrong s) = true ∧
    witnesses [.loadRom, .pauseTap, .mainMenu, .resume, .loadStart, .loadRomFly, .flightEnd]
      (fun s => !s.p.paused && !s.p.lit && !labelWrong s) = true := by decide

/-! ## Part 2: the Screen Wake Lock -/

/-- The wake-lock bookkeeping of index.js, which holds in every reachable state. -/
structure WInv (w : Wk) : Prop where
  held    : w.idxLocks = [] ∨ ∃ l, w.sentinel = some l ∧ w.idxLocks = [l] ∧ l ∉ w.relQ
  live    : ∀ l, w.sentinel = some l → w.idxLocks = [l] ∨ l ∈ w.relQ
  reqNone : w.requesting = true → w.sentinel = none
  relLt   : ∀ l ∈ w.relQ, l < w.nextId
  senLt   : ∀ l, w.sentinel = some l → l < w.nextId
  netLt   : ∀ l ∈ w.netLocks, l < w.nextId
  hidden  : w.visible = false → w.sentinel = none ∧ w.idxLocks = [] ∧ w.netLocks = []
  netSen  : ∀ l ∈ w.netLocks, w.sentinel ≠ some l

theorem winv_init : WInv init.w := by
  constructor <;> simp [init]

theorem winv_syncW (p : Pz) {w : Wk} (h : WInv w) : WInv (syncW p w) := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  unfold syncW
  split
  · constructor <;> simp_all
  · split
    · split
      · rename_i l hs
        have hid : w.idxLocks = [] ∨ w.idxLocks = [l] := by
          rcases h1 with h1 | ⟨l', hl', h1, _⟩
          · exact Or.inl h1
          · rw [hs] at hl'; cases hl'; exact Or.inr h1
        unfold relIdx
        split
        · rename_i hm
          have hid' : w.idxLocks = [l] := by
            rcases hid with hid | hid
            · rw [hid] at hm; simp at hm
            · exact hid
          constructor <;> simp only [hid'] <;> simp_all
          intro l' hl'; rcases hl' with hl' | rfl
          · exact h4 l' hl'
          · exact h5
        · constructor <;> simp_all
          all_goals grind
      · exact ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩
    · exact ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩

theorem winv_releaseNetLock {w : Wk} (h : WInv w) : WInv (releaseNetLock w) := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  unfold releaseNetLock
  split
  · split
    · rename_i l _ hm
      have hl := h6 l hm
      constructor <;> simp only [List.mem_append, List.mem_cons, List.mem_filter] <;>
        simp_all <;> grind
    · constructor <;> simp_all
  · exact ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩

theorem winv_step {s : State} {e : Event} (h : WInv s.w) (he : en s e = true) :
    WInv (step s e).w := by
  have hs := winv_syncW s.p h
  have hr := winv_releaseNetLock h
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  cases e <;> simp only [step, stepW, en] at he ⊢
  all_goals first
    | exact ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩
    | exact hs
    | exact hr
    | skip
  case loadRom => split; exact hr; exact ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩
  case loadRomFly => split; exact hr; exact ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩
  case pagehide =>
    obtain ⟨g1, g2, g3, g4, g5, g6, g7, g8⟩ : WInv (if s.p.rb = true then releaseNetLock s.w else s.w) := by
      split; exact hr; exact ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩
    exact ⟨g1, g2, g3, g4, g5, g6, g7, g8⟩
  case tabHide =>
    -- hidden, so syncWakeLock's `want` is false: it drops the sentinel, whose lock
    -- the UA already released
    have hsen : ∀ l, s.w.sentinel = some l → l ∈ s.w.relQ ++ s.w.idxLocks ++ s.w.netLocks := by
      intro l hl; rcases h2 l hl with h | h <;> simp [h]
    have hall : ∀ l, (l ∈ s.w.relQ ∨ l ∈ s.w.idxLocks) ∨ l ∈ s.w.netLocks → l < s.w.nextId := by
      intro l hl
      rcases hl with (hl | hl) | hl
      · exact h4 l hl
      · rcases h1 with h1 | ⟨l', hs', h1, _⟩
        · simp [h1] at hl
        · simp [h1] at hl; exact h5 l (hl ▸ hs')
      · exact h6 l hl
    unfold syncW relIdx
    simp only [Bool.and_false, Bool.false_and, Bool.not_false, ↓reduceIte,
      Bool.false_eq_true, List.not_mem_nil]
    split
    · constructor <;> simp only [List.mem_append] <;> simp_all
    · constructor <;> simp only [List.mem_append] <;> simp_all
      all_goals grind
  case tabShow =>
    have := winv_syncW s.p (w := { s.w with visible := true })
      ⟨h1, h2, h3, h4, h5, h6, by simp, h8⟩
    split
    · obtain ⟨g1, g2, g3, g4, g5, g6, g7, g8⟩ := this
      exact ⟨g1, g2, g3, g4, g5, g6, g7, g8⟩
    · exact this
  case wakeGrant =>
    split
    · constructor <;> simp_all
    · have hn := h3 he
      have hi : s.w.idxLocks = [] := by
        rcases h1 with h1 | ⟨l, hl, _⟩
        · exact h1
        · rw [hn] at hl; cases hl
      split
      · constructor <;> simp only [List.mem_append, List.mem_cons] <;> simp_all <;> grind
      · constructor <;> simp_all <;> grind
  case wakeDeny => constructor <;> simp_all
  case netGrant =>
    split
    · constructor <;> simp_all
    · obtain ⟨g1, g2, g3, g4, g5, g6, g7, g8⟩ := hr
      split
      · constructor <;> simp only [List.mem_cons] <;> simp_all <;> grind
      · constructor <;> simp only [List.mem_append, List.mem_cons] <;> simp_all <;> grind
  case relFire =>
    split
    · exact ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩
    · rename_i l r hq
      constructor <;> simp_all <;> grind
  case uaRevoke =>
    split
    · exact ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩
    · rename_i l r hq
      constructor <;> simp only [List.mem_append, List.mem_cons] <;> simp_all <;> grind

theorem winv_reachable {s : State} (h : Reachable s) : WInv s.w := by
  induction h with
  | init => exact winv_init
  | step _ he ih => exact winv_step ih he

/-- No leaked index.js lock: every screen lock the UA holds for syncWakeLock is the
one `wakeSentinel` points at, whatever interleaving of pauses, overlays, hides,
grants, denials, revocations and "release" events happened. -/
theorem wake_no_leak {s : State} (h : Reachable s) :
    ∀ l ∈ s.w.idxLocks, s.w.sentinel = some l := by
  intro l hl
  rcases (winv_reachable h).held with h1 | ⟨l', hs, h1, _⟩
  · simp [h1] at hl
  · simp [h1] at hl; exact hl ▸ hs

/-- `wakeSentinel` is never stale for long: its lock is held, or its "release" event
is queued and will clear it (the listener at 11579). -/
theorem wake_sentinel_live {s : State} (h : Reachable s) {l : Nat}
    (hs : s.w.sentinel = some l) : s.w.idxLocks = [l] ∨ l ∈ s.w.relQ :=
  (winv_reachable h).live l hs

/-- A hidden page holds no screen lock at all (neither file's). -/
theorem wake_hidden_none {s : State} (h : Reachable s) (hv : s.w.visible = false) :
    s.w.idxLocks = [] ∧ s.w.netLocks = [] :=
  let ⟨_, a, b⟩ := (winv_reachable h).hidden hv
  ⟨a, b⟩

/-- A request that resolves after its reason went away (paused, home, an overlay,
unloaded) is released in its `.then`: nothing is held afterwards. -/
theorem wake_late_grant_released {s : State} (h : Reachable s)
    (he : en s .wakeGrant = true) (ha : active s.p = false) :
    (step s .wakeGrant).w.idxLocks = [] ∧ (step s .wakeGrant).w.sentinel = none := by
  have hw := winv_reachable h
  simp only [en] at he
  have hn := hw.reqNone he
  have hi : s.w.idxLocks = [] := by
    rcases hw.held with h1 | ⟨l, hl, _⟩
    · exact h1
    · rw [hn] at hl; cases hl
  simp only [step, stepW, ha]
  split <;> simp [hi, hn]

theorem syncW_visible (p : Pz) (w : Wk) : (syncW p w).visible = w.visible := by
  unfold syncW relIdx
  split
  · rfl
  · split
    · split
      · split <;> rfl
      · rfl
    · rfl

/-- Progress: one rAF tick later the lock matches "running and visible" -- held
or requested when wanted, released when not. -/
theorem wake_tick_converges {s : State} (h : Reachable s) :
    (want (step s .tick) = true →
       (step s .tick).w.sentinel.isSome = true ∨ (step s .tick).w.requesting = true) ∧
    (want (step s .tick) = false →
       (step s .tick).w.sentinel = none ∧ (step s .tick).w.idxLocks = []) := by
  have hw := winv_reachable h
  have hid : ∀ l, s.w.sentinel = some l → s.w.idxLocks = [] ∨ s.w.idxLocks = [l] := by
    intro l hs
    rcases hw.held with h1 | ⟨l', hl', h1, _⟩
    · exact Or.inl h1
    · rw [hs] at hl'; cases hl'; exact Or.inr h1
  have hnone : s.w.sentinel = none → s.w.idxLocks = [] := by
    intro hs
    rcases hw.held with h1 | ⟨l', hl', _⟩
    · exact h1
    · rw [hs] at hl'; cases hl'
  have hwt : want (step s .tick) = (active s.p && s.w.visible) := by
    simp only [want, step, stepP, stepW, syncW_visible]
  rw [hwt]
  simp only [step, stepW]
  unfold syncW
  cases hwv : (active s.p && s.w.visible)
  · refine ⟨(fun h => by cases h), fun _ => ?_⟩
    simp only [Bool.false_and, Bool.false_eq_true, Bool.not_false, ↓reduceIte]
    rcases hs : s.w.sentinel with _ | l
    · simp [hs, hnone hs]
    · simp only [relIdx]
      rcases hid l hs with h' | h' <;> simp [h']
  · refine ⟨fun _ => ?_, (fun h => by cases h)⟩
    simp only [Bool.true_and, Bool.not_true, Bool.false_eq_true, ↓reduceIte]
    split
    · simp
    · rename_i hc
      rcases hs : s.w.sentinel with _ | l
      · cases hr : s.w.requesting <;> simp_all
      · simp

/-- netplay.js's modal lock, now: `acquireWakeLock` lets go of the lock it held
before storing a new one, and stores it only while the modal is up
(netplay.js 944-950). -/
def NI (s : State) : Prop :=
  (∀ l ∈ s.w.netLocks, s.w.netLock = some l) ∧ (s.p.netModal = false → s.w.netLocks = [])

theorem releaseNetLock_clears {w : Wk} (h : ∀ l ∈ w.netLocks, w.netLock = some l) :
    (releaseNetLock w).netLocks = [] ∧ (releaseNetLock w).netLock = none := by
  unfold releaseNetLock
  split
  · rename_i l hl
    split
    · refine ⟨?_, rfl⟩
      apply List.eq_nil_iff_forall_not_mem.mpr
      intro x hx
      simp only [List.mem_filter, bne_iff_ne, ne_eq] at hx
      have := h x hx.1; rw [hl] at this; cases this; exact hx.2 rfl
    · rename_i hn
      refine ⟨?_, rfl⟩
      apply List.eq_nil_iff_forall_not_mem.mpr
      intro x hx
      have := h x hx; rw [hl] at this; cases this; exact hn hx
  · rename_i hl
    refine ⟨?_, hl⟩
    apply List.eq_nil_iff_forall_not_mem.mpr
    intro x hx
    have := h x hx; rw [hl] at this; cases this

theorem syncW_net (p : Pz) (w : Wk) :
    (syncW p w).netLocks = w.netLocks ∧ (syncW p w).netLock = w.netLock := by
  unfold syncW relIdx
  split
  · exact ⟨rfl, rfl⟩
  · split
    · split
      · split <;> exact ⟨rfl, rfl⟩
      · exact ⟨rfl, rfl⟩
    · exact ⟨rfl, rfl⟩

theorem ni_step {s : State} {e : Event} (h : NI s) : NI (step s e) := by
  obtain ⟨a, b⟩ := h
  obtain ⟨r1, r2⟩ := releaseNetLock_clears a
  cases e <;> simp only [NI, step, stepP, stepW, closeReportM, closeRwM, closeClipM, startClip,
    abortClip, releaseFlight]
  all_goals first
    | exact ⟨a, b⟩
    | ((repeat' split) <;> exact ⟨a, b⟩)
    | exact ⟨by simp [r1], fun _ => r1⟩
    | skip
  case openNet => exact ⟨a, fun h => by cases h⟩
  case loadRom =>
    split
    · exact ⟨by simp [r1], fun _ => r1⟩
    · rename_i hn
      exact ⟨a, fun _ => b (by simpa using hn)⟩
  case loadRomFly =>
    split
    · exact ⟨by simp [r1], fun _ => r1⟩
    · rename_i hn
      exact ⟨a, fun _ => b (by simpa using hn)⟩
  case pagehide =>
    split
    · exact ⟨by simp [r1], fun _ => r1⟩
    · exact ⟨a, b⟩
  case tabHide =>
    have := syncW_net s.p { s.w with visible := false, relQ := s.w.relQ ++ s.w.idxLocks ++ s.w.netLocks,
                                     idxLocks := [], netLocks := [] }
    rw [this.1]; exact ⟨by simp, fun _ => rfl⟩
  case tabShow =>
    have := syncW_net s.p { s.w with visible := true }
    split
    · simp only [this.1, this.2]; exact ⟨a, b⟩
    · rw [this.1, this.2]; exact ⟨a, b⟩
  case tick => rw [(syncW_net _ _).1, (syncW_net _ _).2]; exact ⟨a, b⟩
  case netGrant =>
    split
    · exact ⟨a, b⟩
    · split
      · rename_i hm
        refine ⟨fun l hl => ?_, fun h => by rw [hm] at h; cases h⟩
        simp only [List.mem_cons, r1] at hl
        rcases hl with hl | hl
        · simp [hl]
        · simp at hl
      · rename_i hm
        exact ⟨by simp [r1], fun _ => r1⟩

theorem ni_reachable {s : State} (h : Reachable s) : NI s := by
  induction h with
  | init => unfold NI; simp [init]
  | step _ _ ih => exact ni_step ih

/-- **No leaked Link Cable lock**: once the modal is closed netplay.js holds no
screen lock, whatever the interleaving of opens, hides, returns (each re-arms a
request), grants and session starts; and while it is up, at most the one lock
`screenLock` points at. -/
theorem net_wake_no_leak {s : State} (h : Reachable s) :
    (s.p.netModal = false → s.w.netLocks = []) ∧ ∀ l ∈ s.w.netLocks, s.w.netLock = some l :=
  ⟨(ni_reachable h).2, (ni_reachable h).1⟩

/-- Was `bug_link_modal_wake_lock_leak`: the player backgrounds the tab while
waiting for a friend; on return the modal re-arms the lock (netplay.js 965),
and the peer's READY, queued while the tab was throttled, starts the session
(`rbStartIfReady` -> `closeNetModal`) before that request resolves. The late
lock used to be stored and never released; now it is let go on arrival, and
once the player pauses nothing keeps the screen awake. -/
theorem regress_link_modal_wake_lock_leak :
    witnesses [.loadRom, .openNet, .netGrant, .tabHide, .tabShow, .netStart,
               .netGrant, .pauseTap, .tick]
      (fun s => s.w.netLocks.isEmpty && s.w.idxLocks.isEmpty && !want s && s.w.visible) = true := by
  decide

/-! ## Part 3: audio -/

/-- Not a promise the code makes, recorded so nobody assumes it: pausing (by any
path) leaves the AudioContext running; only pagehide suspends it (16063). The
paused core just stops pushing buffers, so output falls silent once the queued
lead drains. -/
theorem obs_pause_keeps_audio_context :
    ∃ s, Reachable s ∧ (s.p.paused && s.p.loaded && s.w.ctxRunning && s.w.visible) = true :=
  witness_sound (es := [.gesture, .loadRom, .pauseTap]) (by decide)

/-- What pagehide does promise: a page entering the bfcache has suspended its
context (pageshow and gestures, the only resumers, cannot fire while cached). -/
theorem pagehide_suspends_audio (s : State) : (step s .pagehide).w.ctxRunning = false := rfl

end WebState.RunPause
