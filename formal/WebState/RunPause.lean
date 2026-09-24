/-
# Run/pause state of the emulator (web/index.js, web/netplay.js)

Written against dd7ba741f. `step` now models the code as fixed on this branch
(`git log -- formal/WebState/RunPause.lean`): "web: a pause is only ever
undone by whoever holds it", dad5ede17 (loadRom closes Report a Bug and the
Link Cable modal), and "web: the game keys act in the game view only; a load
ends a capture begun during it", at whose index.js the line numbers are.

The core steps in the rAF `tick` (index.js 11493) iff `!paused` and a game is
loaded; rAF does not fire while the tab is hidden. So "running" is
`loaded && !paused && visible`, and every pausing surface works by writing the
one global `paused` (index.js 7854). The writers are:

* the pause button / Space / Period       -> `togglePause`      (8356)
* the peer, in a rollback session         -> `applyRemotePause` (8370)
* Report a Bug, the rewind scrubber, the clip range picker: each snapshots
  `paused` into its own `*WasPaused` on open and writes it back on close
  (5953/5984, 6462/6494, 8865/8909)
* the home screen                         -> `showMainMenu` / `resumeGame` (9517/9532)
* the Link Cable modal                    -> `netFrozeGame` (netplay.js 200, 1556)
* a clip export's replay                  -> `startClipExport` snapshots `paused` into
  `clipExportWasPaused` and sets `paused = false` (8620-8621); `finishRetroClip`
  writes it back (8533)
* `loadRom` (8029), `unloadGame` (9819), `enterRollbackMode` (9419),
  `launchNetRom` (netplay.js 1436), `rbConnect` (1146).

The pause button's icon/title (`#pause.paused`, title "Resume") is `lit`.
There is no separate "the user's own pause choice" variable: `lit` is the
closest thing (only `togglePause` and `applyRemotePause` set it from a pause
choice), so the properties are stated against it.

The Screen Wake Lock (index.js 7871-7907) is re-synced on every rAF tick
(11497) and on `visibilitychange`; its `request()` is an await (the `.then` at
7885 is a separate event). netplay.js keeps a second, independent wake lock
for the Link Cable modal (`acquireWakeLock`, netplay.js 941-956), also behind
an await.

## Abstractions (and why they do not affect the properties)

* 2P local link (`linkMode`) and the SIO online path (`netMode`, `launchNetRom`)
  are not modelled; `rb` is the rollback session (`rollbackMode`), whose
  `currentRomName` stays set, so `rb -> loaded`. `emulationActive` (7876) is
  `loaded && !paused`. `rbConnect`'s `paused = true` (netplay.js 1146) happens
  while the Link Cable modal already froze the game, so it is not an event.
* One ROM identity: `loaded` = `!!currentRomName`. `loadRom` is two events:
  its first segment (`loadStart`: `abortRetroClip`, 7978), which a call makes
  at any time, and its synchronous commit (`loadRom`, 8007-8049), which may
  land at any later time outside a rollback session (a drop on `document`,
  8397, has no modal guard; a Drive download or IndexedDB read in flight
  under `launchRom`/a tile tap lands whenever it lands; `abandoned()`, 7976,
  drops it in a session). A commit with no `loadStart` before it only adds
  behaviours. The session teardown between them (7984) is `netEnd`.
* `unloadGame`'s final synchronous segment (9812-9834) is one event, enabled
  whenever a single-core game is loaded (its awaits let it land late).
* `netShutdown`'s post-await tail (`closeNetModal`, netplay.js 1610) is folded
  into its first segment; nothing in the tail touches `paused`/`lit`.
* Non-pausing modals (settings, save states, cheats...) are not modelled: they
  never write `paused`, and while one is open the pause button is covered too.
* User input (taps, keys) requires `visible`; network and timer events do not.
  The tick (and `finishRetroClip` inside it) requires `visible`: rAF stops.
  During a clip export's replay every control is inert (`body.clip-replaying`,
  styles.css 7462-7468: the playback controls and the menu) and
  `shortcutKeyHandler` ignores keys (9183), so no tap, key or menu item fires.
* Wake-lock grants follow the Screen Wake Lock spec: the grant task checks
  visibility and resolves in the same task, and the `.then` runs in that
  task's microtask checkpoint, so grant + `.then` is one event (`wakeGrant`),
  but any number of events may run between `request()` and it. A hide
  releases every lock and *queues* a `release` event per lock (`relQ`),
  dispatched later (`relFire`). `uaRevoke` is the UA dropping a held lock for
  its own reasons (battery). Lock identities are fresh naturals.
* Audio: only `audioCtx.state === "running"` (`ctxRunning`); the code does
  not promise to suspend it on pause (see `obs_pause_keeps_audio_context`).
-/
namespace WebState.RunPause

/-- The run/pause part of the state. -/
structure Pz where
  loaded     : Bool   -- !!currentRomName (index.js 7837)
  rb         : Bool   -- rollbackMode (enterRollbackMode 9409)
  paused     : Bool   -- paused (7854)
  lit        : Bool   -- pauseButton.classList "paused"/"active" + title "Resume"
  home       : Bool   -- a loaded game with body.running removed (showMainMenu 9517)
  report     : Bool   -- reportModal.classList "open"
  reportWas  : Bool   -- reportWasPaused (5892)
  rw         : Bool   -- rewindModal.classList "open"
  rwWas      : Bool   -- rwWasPaused (6383)
  clip       : Bool   -- clipModal.classList "open"
  clipWas    : Bool   -- clipWasPaused (8655)
  netModal   : Bool   -- netModal.classList "open" (netplay.js)
  netFroze   : Bool   -- netFrozeGame (netplay.js 172)
  replay     : Bool   -- clipReplayActive (8514)
  exportWas  : Bool   -- clipExportWasPaused (8517)

/-- The page-lifecycle, wake-lock and audio part of the state. -/
structure Wk where
  visible    : Bool          -- document.visibilityState === "visible"
  bfcache    : Bool          -- between pagehide and pageshow
  ctxRunning : Bool          -- audioCtx.state === "running"
  sentinel   : Option Nat    -- wakeSentinel (7874)
  requesting : Bool          -- wakeRequesting (7875) = the request's .then is pending
  netLock    : Option Nat    -- screenLock (netplay.js 940)
  netPending : Nat           -- acquireWakeLock() continuations in flight (netplay.js 941)
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
           replay := false, exportWas := false },
    w := { visible := true, bfcache := false, ctxRunning := false, sentinel := none,
           requesting := false, netLock := none, netPending := 0, idxLocks := [],
           netLocks := [], relQ := [], nextId := 0 } }

inductive Event where
  | pauseTap              -- #pause pointerup/click (8391-8405); hidden on home (styles.css 1110)
  | pauseKey              -- Space (9217) / Period (9259) -> pauseButton.click(), in the game view
  | remotePause (on : Bool) -- RB_PAUSE from the peer (netplay.js 1203) -> applyRemotePause (8370)
  | openReport | closeReport          -- 5953 / 5984
  | openRw | closeRw                  -- 6462 / 6494
  | openClip | closeClip              -- 8865 / 8909
  | clipSave                          -- clipSaveBtn (8918): closeClipScrubber + startClipExport
  | clipDone                          -- tick -> finishRetroClip(true) (11577 / 8531)
  | mainMenu | resume                 -- showMainMenu 9517 / resumeGame 9532
  | loadStart                         -- loadRom's first segment: abortRetroClip (7978)
  | loadRom                           -- loadRom's commit segment (8007-8049)
  | unload                            -- unloadGame's final segment (9812-9834)
  | openNet                           -- openNetConnect after its awaits (netplay.js 176-205)
  | netDismiss                        -- netDismissModal -> netShutdown, pre-session (netplay.js 1614)
  | netFailKeep                       -- netFail pre-session: netShutdown({ keepModal: true }) (netplay.js 235-243)
  | netStart                          -- rbStartIfReady: closeNetModal + enterRollbackMode (netplay.js 1300)
  | netEnd                            -- netShutdown of a session (netplay.js 1546-1567 + rbTeardown)
  | tabHide | tabShow                 -- visibilitychange (index 7907; netplay.js 958)
  | tick                              -- rAF tick -> syncWakeLock (11497)
  | wakeGrant | wakeDeny              -- wakeLock.request(...).then / .catch (7885 / 7897)
  | netGrant | netDeny                -- acquireWakeLock's await resumes / throws (netplay.js 943)
  | relFire                           -- a queued "release" event is dispatched (listener 7893)
  | uaRevoke                          -- the UA drops the page's held lock (battery, ...)
  | pagehide | pageshow | gesture     -- 11397 / 11414 / resumeAudio (11247) on a user gesture
  deriving DecidableEq, Repr

def anyModal (p : Pz) : Bool := p.report || p.rw || p.clip || p.netModal

/-- emulationActive (7876). -/
def active (p : Pz) : Bool := p.loaded && !p.paused
/-- syncWakeLock's `want` (7880): running and visible. -/
def want (s : State) : Bool := active s.p && s.w.visible

/-- `s.release()` on a sentinel the page holds: the spec removes it at once and
queues its "release" event. -/
def relIdx (w : Wk) (l : Nat) : Wk :=
  if l ∈ w.idxLocks then
    { w with idxLocks := w.idxLocks.filter (fun x => x != l), relQ := w.relQ ++ [l] }
  else w

/-- syncWakeLock (7878-7906), its synchronous part. -/
def syncW (p : Pz) (w : Wk) : Wk :=
  if active p && w.visible && w.sentinel.isNone && !w.requesting then
    { w with requesting := true }                                   -- 7882-7884
  else if !(active p && w.visible) then
    match w.sentinel with
    | some l => relIdx { w with sentinel := none } l                -- 7901-7904
    | none => w
  else w

/-- releaseWakeLock (netplay.js 952). -/
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

/-- togglePause (8356); the relay to the peer is not state here. -/
def togglePause (p : Pz) : Pz := { p with paused := !p.paused, lit := !p.paused }

def closeReportM (p : Pz) : Pz :=      -- closeReportModal (5984)
  if p.report then { p with report := false, paused := p.reportWas } else p
def closeRwM (p : Pz) : Pz :=          -- closeRewindScrubber (6494)
  if p.rw then { p with rw := false, paused := p.rwWas } else p
def closeClipM (p : Pz) : Pz :=        -- closeClipScrubber (8909)
  if p.clip then { p with clip := false, paused := p.clipWas } else p

/-- netShutdown's thaw (netplay.js 1556-1562), outside netFail's keepModal. -/
def thaw (p : Pz) : Pz :=
  if p.netFroze then { p with netFroze := false, paused := false, lit := false } else p

/-- startClipExport (8567-8623), the arming path. -/
def startClip (p : Pz) : Pz :=
  if !p.replay && p.loaded && !p.rb then
    { p with replay := true, exportWas := p.paused, paused := false }
  else p

/-- netDismissModal, pre-session (netplay.js 1614): netShutdown's thaw and the
modal closed; the `netDismiss` event's effect. -/
def closeNetM (p : Pz) : Pz := if p.netModal then { thaw p with netModal := false } else p

/-- abortRetroClip -> finishRetroClip(false) (8544 / 8531). -/
def abortClip (p : Pz) : Pz :=
  if p.replay then { p with replay := false, paused := p.exportWas } else p

/-- loadRom's commit (8007-8049): abortRetroClip (8016); closeRewindScrubber();
closeClipScrubber(); closeReportModal(); an open Link Cable modal:
netDismissModal (8028); paused = false; the button reset; body.running. -/
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

/-- netShutdown of a session (netplay.js 1546-1567): thaw (a no-op in a
session); the session hands the game back as it is; rbTeardown ->
leaveRollbackMode runs before rbTeardown's first await. -/
def endSession (p : Pz) : Pz := { thaw p with rb := false, netModal := false }

def stepP (p : Pz) : Event → Pz
  | .pauseTap => togglePause p
  | .pauseKey => if p.home then p else togglePause p     -- 9212-9218: the game view only
  -- 8370-8378: not on home; under Report a Bug, the choice closing it gives back
  | .remotePause on =>
    if p.home then p
    else if p.report then { p with reportWas := on, lit := on }
    else if p.paused != on then togglePause p else p
  | .openReport => { p with reportWas := p.paused, paused := true, report := true }
  | .closeReport => closeReportM p
  | .openRw => { p with rwWas := p.paused, paused := true, rw := true }
  | .closeRw => closeRwM p
  | .openClip => { p with clipWas := p.paused, paused := true, clip := true }
  | .closeClip => closeClipM p
  | .clipSave => startClip (closeClipM p)
  | .clipDone => { p with replay := false, paused := p.exportWas }   -- finishRetroClip 8533
  | .mainMenu => { p with paused := true, home := true } -- the button is untouched
  | .resume => { p with paused := false, lit := false, home := false }
  | .loadStart => abortClip p
  | .loadRom => commitLoad p
  | .unload => { p with loaded := false, paused := true, lit := false, home := false }
  | .openNet =>
    let fr := p.loaded && !p.paused                      -- netFrozeGame (netplay.js 200)
    { p with netModal := true, netFroze := fr, paused := p.paused || fr, lit := p.lit || fr }
  | .netDismiss => { thaw p with netModal := false }
  | .netFailKeep => p                                     -- the modal stays open: no thaw (1556)
  | .netStart =>                                          -- netFrozeGame = false; enterRollbackMode
    { p with netModal := false, netFroze := false, rb := true, paused := false, lit := false,
             home := false }
  | .netEnd => endSession p
  -- pagehide (11397-11399): netShutdown() in a session, as beforeunload
  | .pagehide => if p.rb then endSession p else p
  | _ => p

def stepW (p : Pz) (w : Wk) : Event → Wk
  | .openNet => { w with netPending := w.netPending + 1 }   -- acquireWakeLock() (netplay.js 189)
  | .netDismiss | .netStart | .netEnd => releaseNetLock w     -- closeNetModal (netplay.js 110)
  | .loadRom => if p.netModal then releaseNetLock w else w    -- netDismissModal (8028)
  | .tabHide =>
    -- the UA releases every screen lock and queues their "release" events; then the
    -- visibilitychange listeners: syncWakeLock (7907); netplay's only stamps a time (958)
    syncW p { w with visible := false, relQ := w.relQ ++ w.idxLocks ++ w.netLocks,
                     idxLocks := [], netLocks := [] }
  | .tabShow =>
    let w := syncW p { w with visible := true }
    if p.netModal then { w with netPending := w.netPending + 1 } else w   -- netplay.js 964
  | .tick => syncW p w
  | .wakeGrant =>
    if !w.visible then { w with requesting := false }      -- rejected: .catch (7897)
    else
      let n := w.nextId
      if !active p then                                    -- 7888-7890: s.release()
        { w with requesting := false, nextId := n + 1, relQ := w.relQ ++ [n] }
      else                                                 -- 7892
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
                         sentinel := if w.sentinel == some l then none else w.sentinel }  -- 7824
  | .uaRevoke =>
    match w.idxLocks with
    | [] => w
    | l :: r => { w with idxLocks := r, relQ := w.relQ ++ [l] }
  -- pagehide: a session's netShutdown (11399; its closeNetModal is the folded
  -- tail); the context is suspended (11407)
  | .pagehide =>
    let w := if p.rb then releaseNetLock w else w
    { w with ctxRunning := false, bfcache := true }
  | .pageshow => { w with bfcache := false, ctxRunning := w.ctxRunning || p.loaded }  -- 11414
  | .gesture => { w with ctxRunning := true }
  | _ => w

def step (s : State) (e : Event) : State := { p := stepP s.p e, w := stepW s.p s.w e }

/-- When the event can happen. -/
def en (s : State) : Event → Bool
  | .pauseTap => s.w.visible && s.p.loaded && !anyModal s.p && !s.p.home && !s.p.replay
  | .pauseKey => s.w.visible && s.p.loaded && !anyModal s.p && !s.p.replay  -- 9183, 9203, 9206
  | .remotePause _ => s.p.rb
  | .openReport => s.w.visible && !anyModal s.p && !s.p.replay   -- hamburger, or the paused card's ⋯ (4769)
  | .closeReport | .closeRw | .closeClip => s.w.visible  -- buttons; Escape runs every closer (5255)
  | .openRw => s.w.visible && s.p.loaded && !s.p.rb && !s.p.home && !anyModal s.p && !s.p.replay  -- 6466, styles 1173
  | .openClip => s.w.visible && s.p.loaded && !s.p.rb && !s.p.home && !anyModal s.p && !s.p.replay
  | .clipSave => s.w.visible && s.p.clip
  | .clipDone => s.w.visible && s.p.replay
  | .mainMenu => s.w.visible && s.p.loaded && !s.p.home && !anyModal s.p && !s.p.replay
  | .resume => s.w.visible && s.p.loaded && s.p.home && !anyModal s.p
  | .loadStart => true
  | .loadRom => !s.p.rb
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
  (a clip export's replay, which greys every control out, runs regardless).
* `restore*`: each open overlay, and a running clip export, remembers exactly
  the user's own choice, so closing it gives that choice back (neither sticks
  the game paused nor unpauses a game the user paused). -/
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
               p.home = false → p.replay = false → p.paused = p.lit
  restoreReport : p.loaded = true → p.report = true → p.reportWas = (p.lit || p.home)
  restoreRw     : p.loaded = true → p.rw = true → p.rwWas = p.lit
  restoreClip   : p.loaded = true → p.clip = true → p.clipWas = p.lit
  restoreExport : p.loaded = true → p.replay = true → p.exportWas = p.lit
  replayQuiet : p.replay = true → p.rb = false ∧ p.home = false ∧
                  (p.report || p.rw || p.clip || p.netModal) = false
  netFroze1 : p.netFroze = true → p.netModal = true ∧ (p.loaded = true → p.home = false ∧ p.lit = true)
  netOwn    : p.loaded = true → p.netModal = true → p.netFroze = false → p.home = false →
                p.lit = true

theorem inv_init : Inv init.p := by
  constructor <;> simp [init]

theorem inv_commitLoad {p : Pz} (h : Inv p) (hrb : p.rb = false) : Inv (commitLoad p) := by
  obtain ⟨c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11⟩ := commitLoad_fields p
  have nf : (commitLoad p).netFroze = false := by
    cases hf : (commitLoad p).netFroze
    · rfl
    · obtain ⟨a, b⟩ := c11 hf; rw [(h.netFroze1 a).1] at b; cases b
  constructor <;> simp [c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, hrb, nf]

set_option maxHeartbeats 4000000 in
theorem inv_step {s : State} {e : Event} (h : Inv s.p) (he : en s e = true) :
    Inv (step s e).p := by
  cases e
  case loadRom =>
    simp only [en, Bool.not_eq_eq_eq_not, Bool.not_true] at he
    exact inv_commitLoad h he
  all_goals
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16⟩ := h
    simp only [en, anyModal] at he
    constructor <;> simp only [step, stepP, togglePause, closeReportM, closeRwM, closeClipM,
      thaw, endSession, startClip, abortClip] <;> (repeat' split) <;> grind

/-- **The run/pause discipline holds in every reachable state**, whatever the
interleaving of taps, keys, the peer, overlays, the home screen, loads, closes,
link sessions, clip exports, hides and page lifecycle. -/
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

/-- Corollary (label): with nothing over the game, the icon says what the core does. -/
theorem label_reachable {s : State} (h : Reachable s) (hl : s.p.loaded = true)
    (hm : anyModal s.p = false) (hh : s.p.home = false) (hr : s.p.replay = false) :
    s.p.paused = s.p.lit :=
  (inv_reachable h).label hl hm hh hr

/-! ### The old traces, on the fixed code -/

/-- The core steps (visible, loaded, unpaused) with a pausing overlay or the home
screen in front of it. -/
def runsBehind (s : State) : Bool :=
  s.p.loaded && (anyModal s.p || s.p.home) && !s.p.paused && s.w.visible

/-- Nothing covers the game, and the pause button's icon/title contradicts `paused`. -/
def labelWrong (s : State) : Bool :=
  s.p.loaded && !anyModal s.p && !s.p.home && !s.p.replay && (s.p.paused != s.p.lit)

/-- Was `bug_space_on_home_runs_game`: Space (or Period) on the home screen.
`shortcutKeyHandler` now acts on the game keys only with `body.running`
(9212-9214), so the game `showMainMenu` froze stays frozen. -/
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
replay still runs unpaused, and `finishRetroClip` now puts the player's pause
back. -/
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
closes the report (8027) before `paused = false`, restoring the old session's
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
now dismisses the modal (8028), and with it the modal's wake lock. -/
theorem regress_load_under_link_modal_runs :
    witnesses [.loadRom, .pauseTap, .openNet, .netGrant, .loadStart, .loadRom]
      (fun s => !s.p.netModal && !runsBehind s && !labelWrong s &&
                s.w.netLocks.isEmpty) = true := by decide

/-- A clip export started on the outgoing game while a load is in flight
(between `loadRom`'s first segment and its commit): the commit ends it too
(8016), so the capture does not run on into the new game, and its end does not
write the old game's pause onto the new one. (Without that abort the replay is
still running here, and its end, `clipDone`, froze the new game under a Pause
icon.) -/
theorem regress_load_during_clip_export :
    witnesses [.loadRom, .pauseTap, .loadStart, .openClip, .clipSave, .loadRom]
      (fun s => !s.p.replay && !s.p.paused && !labelWrong s) = true := by decide

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
is queued and will clear it (the listener at 7893). -/
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
(netplay.js 943-949). -/
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
    abortClip]
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
waiting for a friend; on return the modal re-arms the lock (netplay.js 964),
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
path) leaves the AudioContext running; only pagehide suspends it (11407). The
paused core just stops pushing buffers, so output falls silent once the queued
lead drains. -/
theorem obs_pause_keeps_audio_context :
    ∃ s, Reachable s ∧ (s.p.paused && s.p.loaded && s.w.ctxRunning && s.w.visible) = true :=
  witness_sound (es := [.gesture, .loadRom, .pauseTap]) (by decide)

/-- What pagehide does promise: a page entering the bfcache has suspended its
context (pageshow and gestures, the only resumers, cannot fire while cached). -/
theorem pagehide_suspends_audio (s : State) : (step s .pagehide).w.ctxRunning = false := rfl

end WebState.RunPause
