/-
# Service worker, update check and update flow (web/sw.js, web/index.js @ dd7ba741f)

sw.js: `install` (42) fetches every asset once, each under `?v=<CACHE_VERSION>`
with `cache: "reload"`, into the cache `dingbat-<CACHE_VERSION>`; the worker
then waits until a page posts `skipWaiting` (61). `activate` (48) deletes every
other `dingbat-*` cache and `clients.claim()`s every tab. `fetch` (78) answers
from *its own* cache only (so an installed-but-waiting build is never mixed in),
falling back to the network. The `reinstall` message (67, the menu's Force
update) re-downloads every asset into the *live* cache.

index.js: `register` (55) shows the Update button if a worker is already
waiting, and on `updatefound` shows it when the new worker's `statechange`
finds it `installed` while the page has a controller (60-66).
`controllerchange` (79) reloads when `hadController || appUpdating`, once
(`refreshing`). `checkForUpdate` (106) awaits three fetches (the cached
version.txt through the worker, a no-store version.txt, a no-store sw.js) and
shows the button when the first two differ and sw.js's CACHE_VERSION equals the
fresh version.txt. `maybeCheckForUpdate` (133) runs at load and on
`visibilitychange`. The button (206) opens the confirm modal when a game is
loaded, else runs `applyUpdate` (165): `appUpdating = true`,
`await swRegistration.update()`, then `skipWaiting` to the waiting worker, or
wait for the installing one to reach `installed` (then `skipWaiting`) or
`redundant` (then `fullResetReload`, 149), or with neither, `fullResetReload`.

## What is modelled

* A build is a version number; `dep` is what the server serves now. A deploy
  bumps it. Two assets stand for all of them: index.js (with version.txt,
  fetched alongside) and em.wasm. A cache holds, per asset, the build its
  bytes came from.
* Two tabs of the app (`Bool`-indexed). Each tab is the current page instance:
  the build it booted (`running`, per asset), whether it is controlled and by
  which worker version, the index.js flags, and its in-flight continuations
  (applyUpdate between awaits, one checkForUpdate's three fetches).
* The registration: active / waiting / installing worker versions, the
  installing worker's per-asset fetches, a posted `skipWaiting`.
* `reload t` replaces tab t's page: it boots from the active worker's cache
  (or the network when there is no worker or the entry is missing).

## Abstractions

* `register()`'s promise and the updatefound/statechange listeners: the
  listener is attached when `register()` resolves (`regResolve`); the
  `installed` statechange is a queued event per tab (`instFire`) that re-reads
  `sw.state` (installed = still the waiting worker) and the controller, as the
  handler does.
* `fullResetReload`'s four awaits are one event (`resetFire`): nothing between
  them reads state this model tracks except other tabs' boots, which then hit
  the network (no worker), as modelled.
* `update()` rejecting (offline) and the Force-update failure/timeout paths go
  to `fullResetReload`; only the success paths are modelled for Force update.
* The page's own boot from the network is taken as consistent (`(dep, dep)`):
  a site without a worker has the same exposure, so it is not the worker's.
* Save flushing on reload is `pagehide`'s (index.js 11226, a synchronous IDB
  put); this file only tracks whether a tab was reloaded mid-game without its
  own user having agreed (`forcedMidGame`). What pagehide does *not* flush in a
  rollback session is Netplay.lean's `bug_pagehide_in_rollback_loses_progress`.
* `badPrompt` (the button shown for the build the tab runs) is tracked but no
  theorem is claimed about it: on a page with no controller the "cached"
  version.txt comes through the HTTP cache, which this model does not track.

## Results

Proved: with no Update / Force update accepted, no tab is ever reloaded by the
app (`no_reload_without_a_click`: no reload loop exists without a click);
the button is shown at most once per page (`shows_at_most_once`); without a
deploy inside an install and without Force update, no page boots a mixed
index.js/em.wasm pair (`no_mixed_boot_without_straddle`).
Refuted (`bug_*`): Update in one tab reloads a game in another; an install
straddling a deploy caches a mixed pair; Force update serves a half-written
cache.
-/
namespace WebState.ServiceWorker

inductive AK where
  | idle
  | awaitUpdate          -- applyUpdate suspended at `await swRegistration.update()`
  | watch (v : Nat)      -- statechange listener on installing worker v (186)
  | resetting            -- in fullResetReload
  | done                 -- skipWaiting posted; waiting for controllerchange
  deriving DecidableEq, Repr

structure Chk where
  cur    : Option Nat := none   -- cached version.txt (through the worker)
  latest : Option Nat := none   -- no-store version.txt
  sw     : Option Nat := none   -- CACHE_VERSION in a no-store sw.js
  deriving DecidableEq, Repr

structure Tab where
  running     : Nat × Nat := (0, 0)  -- (index.js, em.wasm) builds this page booted with
  controlled  : Bool := true         -- navigator.serviceWorker.controller
  ctrlV       : Nat := 0             -- the controller's CACHE_VERSION
  hadController : Bool := true       -- (73)
  appUpdating : Bool := false        -- (163)
  refreshing  : Bool := false        -- (74)
  updAvail    : Bool := false        -- updateAvailable / button shown (100)
  shows       : Nat := 0             -- ghost: hidden -> shown transitions this page
  promptV     : Option Nat := none   -- ghost: build the button was last shown for
  game        : Bool := false        -- currentRomName || linkMode
  modal       : Bool := false        -- update modal open
  applyK      : AK := .idle
  ccQ         : Bool := false        -- a controllerchange event queued
  regd        : Bool := false        -- register() resolved: listeners attached
  instQ       : Option Nat := none   -- an `installed` statechange queued for worker v
  chk         : Option Chk := none   -- a checkForUpdate in flight
  force       : Bool := false        -- Force update in flight (waiting for "reinstalled")
  deriving DecidableEq, Repr

structure State where
  dep        : Nat                    -- the deployed build
  active     : Option Nat             -- registration.active
  waiting    : Option Nat
  installing : Option Nat
  stageJs    : Option Nat             -- the installing worker's fetched index.js
  stageWasm  : Option Nat             -- ... and em.wasm
  cache      : Nat → Option (Nat × Nat)  -- dingbat-<v> : (index.js build, em.wasm build)
  skipQ      : Option Nat             -- skipWaiting posted to worker v
  rJs        : Bool                   -- a reinstall has rewritten index.js in the live cache
  rWasm      : Bool                   -- ... and em.wasm
  tabs       : Bool → Tab
  intents    : Nat                    -- ghost: Update / Force update accepted
  autoReloads : Nat                   -- ghost: reloads the app itself triggered
  forcedMidGame : Bool                -- ghost: a tab reloaded mid-game its user never agreed to
  mixedBoot  : Bool                   -- ghost: a page booted index.js and em.wasm of different builds
  badPrompt  : Bool                   -- ghost: the button was shown for the build the tab runs

/-- Steady state: build 0 deployed, installed, both tabs booted from it. -/
def init : State where
  dep := 0
  active := some 0
  waiting := none
  installing := none
  stageJs := none
  stageWasm := none
  cache := fun v => if v = 0 then some (0, 0) else none
  skipQ := none
  rJs := false
  rWasm := false
  tabs := fun _ => {}
  intents := 0
  autoReloads := 0
  forcedMidGame := false
  mixedBoot := false
  badPrompt := false

def updT (t : Bool) (f : Tab → Tab) (s : State) : State :=
  { s with tabs := fun u => if u = t then f (s.tabs u) else s.tabs u }

/-- showUpdateButton (101). -/
def showBtn (t : Bool) (v : Nat) (s : State) : State :=
  let x := s.tabs t
  let s := { s with badPrompt := s.badPrompt || v == x.running.1 }
  updT t (fun x => { x with updAvail := true, promptV := some v,
                             shows := if x.updAvail then x.shows else x.shows + 1 }) s

/-- What a page boots with: the active worker's cache, else the network. -/
def serve (s : State) : Option Nat × Nat × Nat :=
  match s.active with
  | some v => match s.cache v with
    | some p => (some v, p)
    | none => (some v, (s.dep, s.dep))
    -- network fallback (sw.js 113)
  | none => (none, (s.dep, s.dep))

/-- A page (re)load of tab t. `auto`: the app called location.reload(). -/
def reload (t : Bool) (auto : Bool) (s : State) : State :=
  let x := s.tabs t
  let (c, p) := serve s
  let s := { s with
    forcedMidGame := s.forcedMidGame || (auto && x.game && !x.appUpdating),
    mixedBoot := s.mixedBoot || p.1 != p.2,
    autoReloads := if auto then s.autoReloads + 1 else s.autoReloads }
  updT t (fun _ => match c with
    | some v => { running := p, controlled := true, ctrlV := v, hadController := true }
    | none => { running := p, controlled := false, ctrlV := 0, hadController := false }) s

/-- clients.claim(): the tab is now controlled by worker v; controllerchange queued. -/
def claim (v : Nat) (x : Tab) : Tab := { x with controlled := true, ctrlV := v, ccQ := true }

/-- The `installed` statechange reaches a page that attached the listener; an
    applyUpdate watching worker v then posts skipWaiting (185). -/
def onInstalled (v : Nat) (x : Tab) : Tab :=
  let x := if x.regd then { x with instQ := some v } else x
  if x.applyK == .watch v then { x with applyK := .done } else x

/-- The `redundant` statechange: an applyUpdate watching worker v falls back to
    fullResetReload (190). -/
def onRedundant (v : Nat) (x : Tab) : Tab :=
  if x.applyK == .watch v then { x with applyK := .resetting } else x

def mapTabs (g : Tab → Tab) (s : State) : State := { s with tabs := fun u => g (s.tabs u) }

/-- activate (sw.js 48): delete the other caches, claim every tab. -/
def activate (v : Nat) (s : State) : State :=
  mapTabs (claim v)
    { s with active := some v,
             waiting := if s.waiting = some v then none else s.waiting,
             cache := fun u => if u = v then s.cache u else none }

/-- A browser update check (navigation, periodic, or reg.update()): a changed
    sw.js starts an install. -/
def updCheck (s : State) : State :=
  if s.installing.isNone && s.active.isSome && s.active != some s.dep && s.waiting != some s.dep then
    { s with installing := some s.dep, stageJs := none, stageWasm := none }
  else s

inductive Event where
  | deploy
  | browserCheck                 -- the browser re-fetches sw.js
  | fetchJs                      -- the installing worker's index.js?v= fetch completes
  | fetchWasm                    -- ... em.wasm?v=
  | installOk                    -- event.waitUntil resolved
  | installFail                  -- one asset fetch failed: worker redundant
  | regResolve (t : Bool)        -- register().then (55)
  | instFire (t : Bool)          -- the queued `installed` statechange (61)
  | skipDeliver                  -- the waiting worker handles skipWaiting and activates
  | ccFire (t : Bool)            -- controllerchange handler (79)
  | userReload (t : Bool)        -- the user reloads / reopens the tab
  | gameOn (t : Bool) | gameOff (t : Bool)
  | updClick (t : Bool)          -- #update-btn (206)
  | confirm (t : Bool)           -- #update-confirm (215)
  | notNow (t : Bool)
  | applyResume (t : Bool)       -- applyUpdate after `await update()` (175)
  | resetFire (t : Bool)         -- fullResetReload (149)
  | checkStart (t : Bool)        -- maybeCheckForUpdate at load / visibilitychange (133)
  | chkCur (t : Bool) | chkLatest (t : Bool) | chkSw (t : Bool)  -- the three fetches land
  | chkEval (t : Bool)           -- the rest of checkForUpdate
  | forceStart (t : Bool)        -- Force update, confirmed (250)
  | rPutJs | rPutWasm            -- the live worker's reinstall writes one asset
  | forceDone (t : Bool)         -- "reinstalled" ok: location.reload() (243)
  deriving DecidableEq, Repr

def en (s : State) : Event → Bool
  | .deploy => true
  | .browserCheck => true
  | .fetchJs => s.installing.isSome && s.stageJs.isNone
  | .fetchWasm => s.installing.isSome && s.stageWasm.isNone
  | .installOk => s.installing.isSome && s.stageJs.isSome && s.stageWasm.isSome
  | .installFail => s.installing.isSome
  | .regResolve t => !(s.tabs t).regd
  | .instFire t => (s.tabs t).instQ.isSome
  | .skipDeliver => s.skipQ.isSome
  | .ccFire t => (s.tabs t).ccQ
  | .userReload _ => true
  | .gameOn t => !(s.tabs t).game
  | .gameOff t => (s.tabs t).game
  | .updClick t => (s.tabs t).updAvail && !(s.tabs t).appUpdating && !(s.tabs t).modal
  | .confirm t => (s.tabs t).modal
  | .notNow t => (s.tabs t).modal
  | .applyResume t => (s.tabs t).applyK == .awaitUpdate
  | .resetFire t => (s.tabs t).applyK == .resetting
  | .checkStart t => !(s.tabs t).updAvail && (s.tabs t).chk.isNone
  | .chkCur t => match (s.tabs t).chk with | some c => c.cur.isNone | none => false
  | .chkLatest t => match (s.tabs t).chk with | some c => c.latest.isNone | none => false
  | .chkSw t => match (s.tabs t).chk with | some c => c.sw.isNone | none => false
  | .chkEval t => match (s.tabs t).chk with
      | some c => c.cur.isSome && c.latest.isSome && c.sw.isSome | none => false
  | .forceStart t => (s.tabs t).controlled && !(s.tabs t).force && !(s.tabs t).appUpdating
  | .rPutJs => (s.tabs true).force || (s.tabs false).force
  | .rPutWasm => (s.tabs true).force || (s.tabs false).force
  | .forceDone t => (s.tabs t).force && s.rJs && s.rWasm

/-- applyUpdate (165), first segment: flags, close the modal, `update()`. -/
def applyStart (t : Bool) (s : State) : State :=
  let x := s.tabs t
  let s := { s with intents := s.intents + 1 }
  let s := updT t (fun x => { x with appUpdating := true, modal := false }) s
  if x.regd then updT t (fun x => { x with applyK := .awaitUpdate }) (updCheck s)
  else updT t (fun x => { x with applyK := .resetting }) s

def step (s : State) : Event → State
  | .deploy => { s with dep := s.dep + 1 }
  | .browserCheck => updCheck s
  -- fetchAndCache: `?v=<CACHE_VERSION>` is a fresh URL; the server answers with
  -- whatever is deployed at that moment
  | .fetchJs => { s with stageJs := some s.dep }
  | .fetchWasm => { s with stageWasm := some s.dep }
  | .installOk =>
    match s.installing, s.stageJs, s.stageWasm with
    | some v, some j, some w =>
      let anyWatch := (s.tabs true).applyK == .watch v || (s.tabs false).applyK == .watch v
      let s := mapTabs (onInstalled v)
        { s with cache := fun u => if u = v then some (j, w) else s.cache u,
                 installing := none, stageJs := none, stageWasm := none }
      -- no active worker: activates at once (first install); else waits
      let s := match s.active with
        | none => activate v s
        | some _ => { s with waiting := some v }
      if anyWatch then { s with skipQ := some v } else s
    | _, _, _ => s
  | .installFail =>
    match s.installing with
    | some v =>
      mapTabs (onRedundant v) { s with installing := none, stageJs := none, stageWasm := none }
    | none => s
  -- register().then (55): if (reg.waiting) showUpdateButton(); a missing
  -- registration is created and installs
  | .regResolve t =>
    let s := updT t (fun x => { x with regd := true }) s
    match s.waiting with
    | some v => showBtn t v s
    | none =>
      if s.active.isNone && s.installing.isNone then
        { s with installing := some s.dep, stageJs := none, stageWasm := none }
      else s
  -- statechange (61): sw.state === "installed" (still waiting) && controller
  | .instFire t =>
    let x := s.tabs t
    let s := updT t (fun x => { x with instQ := none }) s
    match x.instQ with
    | some v => if s.waiting == some v && x.controlled then showBtn t v s else s
    | none => s
  | .skipDeliver =>
    match s.skipQ with
    | some v => let s := { s with skipQ := none }
                if s.waiting == some v then activate v s else s
    | none => s
  -- controllerchange (79)
  | .ccFire t =>
    let x := s.tabs t
    let s := updT t (fun x => { x with ccQ := false }) s
    if (x.hadController || x.appUpdating) && !x.refreshing then reload t true s
    else updT t (fun x => { x with hadController := true }) s
  | .userReload t => reload t false s
  | .gameOn t => updT t (fun x => { x with game := true }) s
  | .gameOff t => updT t (fun x => { x with game := false }) s
  -- #update-btn (206): a game loaded -> confirm modal, else applyUpdate
  | .updClick t =>
    if (s.tabs t).game then updT t (fun x => { x with modal := true }) s else applyStart t s
  | .confirm t => applyStart t s
  | .notNow t => updT t (fun x => { x with modal := false }) s
  -- after `await swRegistration.update()` (175-197)
  | .applyResume t =>
    match s.waiting, s.installing with
    | some v, _ => updT t (fun x => { x with applyK := .done }) { s with skipQ := some v }
    | none, some v => updT t (fun x => { x with applyK := .watch v }) s
    | none, none => updT t (fun x => { x with applyK := .resetting }) s
  -- fullResetReload (149): delete every cache, unregister, reload
  | .resetFire t =>
    reload t true { s with cache := fun _ => none, active := none, waiting := none,
                           installing := none, stageJs := none, stageWasm := none, skipQ := none }
  | .checkStart t => updT t (fun x => { x with chk := some {} }) s
  -- fetch("version.txt"): the controller's own cache (sw.js 109), else network
  | .chkCur t =>
    let x := s.tabs t
    let v := if x.controlled then (match s.cache x.ctrlV with | some p => p.1 | none => s.dep) else s.dep
    updT t (fun x => { x with chk := x.chk.map (fun c => { c with cur := some v }) }) s
  | .chkLatest t => updT t (fun x => { x with chk := x.chk.map (fun c => { c with latest := some s.dep }) }) s
  | .chkSw t => updT t (fun x => { x with chk := x.chk.map (fun c => { c with sw := some s.dep }) }) s
  -- 114-125: current && latest && latest !== current && deployed === latest -> button
  | .chkEval t =>
    match (s.tabs t).chk with
    | some { cur := some c, latest := some l, sw := some d } =>
      let s := updT t (fun x => { x with chk := none }) s
      if c != l && d == l then showBtn t l s else s
    | _ => s
  -- Force update (250): appUpdating; the live worker re-downloads into its cache
  | .forceStart t =>
    updT t (fun x => { x with force := true, appUpdating := true })
      { s with intents := s.intents + 1, rJs := false, rWasm := false }
  -- installAssets(nonce) into CACHE_NAME: one cache.put per asset (sw.js 34)
  | .rPutJs =>
    match s.active with
    | some v =>
      let c := fun u => if u = v then some (s.dep, ((s.cache u).map Prod.snd).getD s.dep) else s.cache u
      { s with rJs := true, cache := c }
    | none => s
  | .rPutWasm =>
    match s.active with
    | some v =>
      let c := fun u => if u = v then some (((s.cache u).map Prod.fst).getD s.dep, s.dep) else s.cache u
      { s with rWasm := true, cache := c }
    | none => s
  | .forceDone t => reload t true (updT t (fun x => { x with force := false }) s)

inductive Reachable : State → Prop
  | init : Reachable init
  | step {s : State} (e : Event) : Reachable s → en s e = true → Reachable (step s e)

def run (s : State) : List Event → Option State
  | [] => some s
  | e :: es => if en s e then run (step s e) es else none

theorem run_reachable {s : State} (h : Reachable s) :
    ∀ {es : List Event} {t : State}, run s es = some t → Reachable t := by
  intro es
  induction es generalizing s with
  | nil => intro t ht; simp [run] at ht; subst ht; exact h
  | cons e es ih =>
    intro t ht
    simp only [run] at ht
    split at ht
    · exact ih (Reachable.step e h (by assumption)) ht
    · cases ht

def witnesses (es : List Event) (bad : State → Bool) : Bool :=
  match run init es with
  | some t => bad t
  | none => false

theorem witness_sound {es : List Event} {bad : State → Bool}
    (h : witnesses es bad = true) : ∃ s, Reachable s ∧ bad s = true := by
  unfold witnesses at h
  split at h
  · exact ⟨_, run_reachable Reachable.init (by assumption), h⟩
  · cases h


/-! ## Invariants that hold -/

section proj
variable (s : State) (t u : Bool) (f : Tab → Tab) (g : Tab → Tab) (v : Nat) (auto : Bool)
@[simp] theorem updT_tabs : (updT t f s).tabs u = if u = t then f (s.tabs u) else s.tabs u := rfl
@[simp] theorem mapTabs_tabs : (mapTabs g s).tabs u = g (s.tabs u) := rfl
@[simp] theorem updT_intents : (updT t f s).intents = s.intents := rfl
@[simp] theorem updT_active : (updT t f s).active = s.active := rfl
@[simp] theorem updT_waiting : (updT t f s).waiting = s.waiting := rfl
@[simp] theorem updT_installing : (updT t f s).installing = s.installing := rfl
@[simp] theorem updT_skipQ : (updT t f s).skipQ = s.skipQ := rfl
@[simp] theorem updT_cache : (updT t f s).cache = s.cache := rfl
@[simp] theorem updT_autoReloads : (updT t f s).autoReloads = s.autoReloads := rfl
@[simp] theorem updT_forced : (updT t f s).forcedMidGame = s.forcedMidGame := rfl
@[simp] theorem updT_mixed : (updT t f s).mixedBoot = s.mixedBoot := rfl
@[simp] theorem updT_dep : (updT t f s).dep = s.dep := rfl
@[simp] theorem updT_stageJs : (updT t f s).stageJs = s.stageJs := rfl
@[simp] theorem updT_stageWasm : (updT t f s).stageWasm = s.stageWasm := rfl
@[simp] theorem mapTabs_active : (mapTabs g s).active = s.active := rfl
@[simp] theorem mapTabs_skipQ : (mapTabs g s).skipQ = s.skipQ := rfl
@[simp] theorem mapTabs_cache : (mapTabs g s).cache = s.cache := rfl
@[simp] theorem mapTabs_autoReloads : (mapTabs g s).autoReloads = s.autoReloads := rfl
@[simp] theorem mapTabs_forced : (mapTabs g s).forcedMidGame = s.forcedMidGame := rfl
@[simp] theorem mapTabs_mixed : (mapTabs g s).mixedBoot = s.mixedBoot := rfl
@[simp] theorem mapTabs_intents : (mapTabs g s).intents = s.intents := rfl
@[simp] theorem activate_intents : (activate v s).intents = s.intents := rfl
@[simp] theorem updCheck_intents : (updCheck s).intents = s.intents := by
  unfold updCheck; split <;> rfl
@[simp] theorem showBtn_intents : (showBtn t v s).intents = s.intents := rfl
@[simp] theorem reload_intents : (reload t auto s).intents = s.intents := rfl
@[simp] theorem applyStart_intents : (applyStart t s).intents = s.intents + 1 := by
  unfold applyStart; simp only []; split <;> simp
end proj

theorem step_intents_mono (s : State) (e : Event) : s.intents ≤ (step s e).intents := by
  cases e <;> simp only [step] <;> (repeat' split) <;> simp

/-! ### No reload without a click -/

/-- The per-tab part: no update in progress in this tab. -/
def QT (x : Tab) : Prop :=
  x.applyK = .idle ∧ x.appUpdating = false ∧ x.ccQ = false ∧ x.force = false

/-- The quiescent state: no update in progress anywhere. -/
def Q (s : State) : Prop :=
  s.active.isSome = true ∧ s.skipQ = none ∧ s.autoReloads = 0 ∧ s.forcedMidGame = false ∧
  ∀ t, QT (s.tabs t)

theorem q_updT {s : State} (h : Q s) (t : Bool) (f : Tab → Tab)
    (hf : ∀ x, QT x → QT (f x)) : Q (updT t f s) := by
  obtain ⟨a1, a2, a3, a4, a5⟩ := h
  refine ⟨a1, a2, a3, a4, fun u => ?_⟩
  simp only [updT_tabs]; split
  · exact hf _ (a5 u)
  · exact a5 u

theorem qt_simple (x : Tab) (h : QT x) (y : Tab) (e1 : y.applyK = x.applyK)
    (e2 : y.appUpdating = x.appUpdating) (e3 : y.ccQ = x.ccQ) (e4 : y.force = x.force) : QT y := by
  obtain ⟨a, b, c, d⟩ := h; exact ⟨e1 ▸ a, e2 ▸ b, e3 ▸ c, e4 ▸ d⟩

macro "qt_triv" : tactic => `(tactic| (intro x hx; exact qt_simple x hx _ rfl rfl rfl rfl))

theorem q_showBtn {s : State} (h : Q s) (t : Bool) (v : Nat) : Q (showBtn t v s) := by
  simp only [showBtn]
  apply q_updT
  · exact h
  · qt_triv

theorem q_updCheck {s : State} (h : Q s) : Q (updCheck s) := by
  unfold updCheck; split
  · exact h
  · exact h

theorem onInstalled_qt (v : Nat) (x : Tab) (h : QT x) : QT (onInstalled v x) := by
  obtain ⟨a, b, c, d⟩ := h
  unfold onInstalled
  simp only []
  split <;> split <;> simp_all [QT]

theorem onRedundant_qt (v : Nat) (x : Tab) (h : QT x) : QT (onRedundant v x) := by
  obtain ⟨a, b, c, d⟩ := h
  unfold onRedundant
  split <;> simp_all [QT]

/-- With no Update or Force-update accepted in any tab, the app never reloads a
    tab by itself: there is no reload loop without a user's click, whatever the
    deploys, browser update checks, installs and overlapping checkForUpdate
    calls do. -/
def I0 (s : State) : Prop := s.intents = 0 → Q s

theorem i0_init : I0 init := fun _ => by simp [Q, QT, init]

theorem i0_step {s : State} {e : Event} (h : I0 s) (he : en s e = true) : I0 (step s e) := by
  intro hz
  have hz0 : s.intents = 0 := by have := step_intents_mono s e; omega
  have qs := h hz0
  obtain ⟨a1, a2, a3, a4, a5⟩ := qs
  have qs : Q s := ⟨a1, a2, a3, a4, a5⟩
  cases e with
  | deploy => exact qs
  | browserCheck => exact q_updCheck qs
  | fetchJs => exact qs
  | fetchWasm => exact qs
  | installOk =>
    simp only [step]
    split
    · rename_i v j w _ _ _
      have i1 : (s.tabs true).applyK = .idle := (a5 true).1
      have i2 : (s.tabs false).applyK = .idle := (a5 false).1
      obtain ⟨av, hav⟩ := Option.isSome_iff_exists.mp a1
      simp only [hav, i1, i2, mapTabs]
      exact ⟨by simp, by simpa using a2, by simpa using a3, by simpa using a4,
        fun u => onInstalled_qt v _ (a5 u)⟩
    · exact qs
  | installFail =>
    simp only [step]
    split
    · exact ⟨a1, a2, a3, a4, fun u => onRedundant_qt _ _ (a5 u)⟩
    · exact qs
  | regResolve t =>
    have q1 : Q (updT t (fun x => { x with regd := true }) s) := q_updT qs t _ (by qt_triv)
    simp only [step]
    split
    · exact q_showBtn q1 t _
    · split
      · rename_i hh; simp at hh; rw [hh.1] at a1; cases a1
      · exact q1
  | instFire t =>
    have q1 : Q (updT t (fun x => { x with instQ := none }) s) := q_updT qs t _ (by qt_triv)
    simp only [step]
    split
    · split
      · exact q_showBtn q1 t _
      · exact q1
    · exact q1
  | skipDeliver => simp [en, a2] at he
  | ccFire t => have := (a5 t).2.2.1; simp [en, this] at he
  | userReload t =>
    simp only [step, reload]
    refine ⟨by simpa using a1, by simpa using a2, by simpa using a3, by simpa using a4, fun u => ?_⟩
    simp only [updT_tabs]
    split
    · split <;> simp [QT]
    · exact a5 u
  | gameOn t => exact q_updT qs t _ (by qt_triv)
  | gameOff t => exact q_updT qs t _ (by qt_triv)
  | updClick t =>
    simp only [step] at hz ⊢
    split
    · exact q_updT qs t _ (by qt_triv)
    · rename_i hg; simp only [hg, Bool.false_eq_true, ↓reduceIte, applyStart_intents] at hz; omega
  | confirm t => simp only [step, applyStart_intents] at hz; omega
  | notNow t => exact q_updT qs t _ (by qt_triv)
  | applyResume t => have := (a5 t).1; simp [en, this] at he
  | resetFire t => have := (a5 t).1; simp [en, this] at he
  | checkStart t => exact q_updT qs t _ (by qt_triv)
  | chkCur t => exact q_updT qs t _ (by qt_triv)
  | chkLatest t => exact q_updT qs t _ (by qt_triv)
  | chkSw t => exact q_updT qs t _ (by qt_triv)
  | chkEval t =>
    simp only [step]
    split
    · have q1 : Q (updT t (fun x => { x with chk := none }) s) := q_updT qs t _ (by qt_triv)
      split
      · exact q_showBtn q1 t _
      · exact q1
    · exact qs
  | forceStart t => simp [step] at hz
  | rPutJs => have := (a5 true).2.2.2; have := (a5 false).2.2.2; simp_all [en]
  | rPutWasm => have := (a5 true).2.2.2; have := (a5 false).2.2.2; simp_all [en]
  | forceDone t => have := (a5 t).2.2.2; simp [en, this] at he

theorem i0_reachable {s : State} (h : Reachable s) : I0 s := by
  induction h with
  | init => exact i0_init
  | step e _ he ih => exact i0_step ih he

theorem no_reload_without_a_click {s : State} (h : Reachable s) (hz : s.intents = 0) :
    s.autoReloads = 0 ∧ s.forcedMidGame = false := by
  obtain ⟨_, _, a3, a4, _⟩ := i0_reachable h hz
  exact ⟨a3, a4⟩

/-! ### At most one prompt per page -/

def PT (x : Tab) : Prop := x.shows = if x.updAvail then 1 else 0
def P (s : State) : Prop := ∀ t, PT (s.tabs t)

theorem pt_simple (x y : Tab) (h : PT x) (e1 : y.shows = x.shows) (e2 : y.updAvail = x.updAvail) : PT y := by
  unfold PT at *; rw [e1, e2]; exact h

macro "pt_triv" : tactic => `(tactic| (intro x hx; exact pt_simple x _ hx rfl rfl))

theorem p_updT {s : State} (h : P s) (t : Bool) (f : Tab → Tab) (hf : ∀ x, PT x → PT (f x)) :
    P (updT t f s) := by
  intro u; simp only [updT_tabs]; split
  · exact hf _ (h u)
  · exact h u

/-- `updT` with a function that keeps shows/updAvail, on the goal as it stands. -/
macro "p_upd" h:term : tactic => `(tactic| ((try simp only [step]); apply p_updT; all_goals first | exact $h | pt_triv))

theorem p_mapTabs {s : State} (h : P s) (g : Tab → Tab) (hg : ∀ x, PT x → PT (g x)) :
    P (mapTabs g s) := fun u => hg _ (h u)

theorem p_showBtn {s : State} (h : P s) (t : Bool) (v : Nat) : P (showBtn t v s) := by
  simp only [showBtn]
  apply p_updT
  · exact h
  intro x hx
  unfold PT at *
  cases hu : x.updAvail <;> simp_all

theorem p_reload {s : State} (h : P s) (t : Bool) (auto : Bool) : P (reload t auto s) := by
  simp only [reload]
  split <;> (apply p_updT; all_goals first | exact h | (intro x _; simp [PT]))

theorem p_activate {s : State} (h : P s) (v : Nat) : P (activate v s) :=
  p_mapTabs h (claim v) (by pt_triv)

theorem p_updCheck {s : State} (h : P s) : P (updCheck s) := by
  unfold updCheck; split
  · exact h
  · exact h

theorem p_applyStart {s : State} (h : P s) (t : Bool) : P (applyStart t s) := by
  unfold applyStart
  have h1 : P (updT t (fun x => { x with appUpdating := true, modal := false }) { s with intents := s.intents + 1 }) := by
    apply p_updT
    · exact h
    · pt_triv
  simp only []
  split
  · apply p_updT (p_updCheck h1); pt_triv
  · apply p_updT h1; pt_triv

theorem onInstalled_pt (v : Nat) (x : Tab) (h : PT x) : PT (onInstalled v x) := by
  unfold onInstalled PT at *; simp only []; split <;> split <;> simp_all

theorem onRedundant_pt (v : Nat) (x : Tab) (h : PT x) : PT (onRedundant v x) := by
  unfold onRedundant PT at *; split <;> simp_all

theorem p_step {s : State} (h : P s) (e : Event) : P (step s e) := by
  cases e with
  | deploy => exact h
  | browserCheck => exact p_updCheck h
  | fetchJs => exact h
  | fetchWasm => exact h
  | installOk =>
    simp only [step]; split
    · rename_i v j w _ _ _
      have h1 : P (mapTabs (onInstalled v) s) := p_mapTabs h (onInstalled v) (onInstalled_pt v)
      have h2 : P (activate v (mapTabs (onInstalled v) s)) := p_activate h1 v
      split
      · split
        · exact fun u => h2 u
        · exact fun u => h1 u
      · split
        · exact fun u => h2 u
        · exact fun u => h1 u
    · exact h
  | installFail =>
    simp only [step]; split
    · rename_i v _
      exact fun u => p_mapTabs h (onRedundant v) (onRedundant_pt v) u
    · exact h
  | regResolve t =>
    have h1 := p_updT h t (fun x => { x with regd := true }) (by pt_triv)
    simp only [step]; split
    · exact p_showBtn h1 t _
    · split
      · exact h1
      · exact h1
  | instFire t =>
    have h1 := p_updT h t (fun x => { x with instQ := none }) (by pt_triv)
    simp only [step]; split
    · split
      · exact p_showBtn h1 t _
      · exact h1
    · exact h1
  | skipDeliver =>
    simp only [step]; split
    · split
      · exact p_activate h _
      · exact h
    · exact h
  | ccFire t =>
    have h1 := p_updT h t (fun x => { x with ccQ := false }) (by pt_triv)
    simp only [step]; split
    · exact p_reload h1 t true
    · p_upd h1
  | userReload t => exact p_reload h t false
  | gameOn t => p_upd h
  | gameOff t => p_upd h
  | updClick t =>
    simp only [step]; split
    · p_upd h
    · exact p_applyStart h t
  | confirm t => exact p_applyStart h t
  | notNow t => p_upd h
  | applyResume t =>
    simp only [step]; split
    · p_upd h
    · p_upd h
    · p_upd h
  | resetFire t => simp only [step]; apply p_reload; exact h
  | checkStart t => p_upd h
  | chkCur t => p_upd h
  | chkLatest t => p_upd h
  | chkSw t => p_upd h
  | chkEval t =>
    simp only [step]; split
    · have h1 := p_updT h t (fun x => { x with chk := none }) (by pt_triv)
      split
      · exact p_showBtn h1 t _
      · exact h1
    · exact h
  | forceStart t => p_upd h
  | rPutJs => simp only [step]; split <;> exact h
  | rPutWasm => simp only [step]; split <;> exact h
  | forceDone t => exact p_reload (p_updT h t (fun x => { x with force := false }) (by pt_triv)) t true

/-- The Update button is shown at most once per page (it is never hidden again,
    and `shows` counts hidden -> shown transitions), however many checks,
    updatefound events and register() callbacks race. -/
theorem shows_at_most_once {s : State} (h : Reachable s) (t : Bool) :
    (s.tabs t).shows ≤ 1 := by
  have hp : P s := by
    induction h with
    | init => intro u; simp [init, PT]
    | step e _ _ ih => exact p_step ih e
  have := hp t
  unfold PT at this
  split at this <;> omega

/-! ### No mixed build, when no deploy lands inside an install

Excluding exactly the two mixing paths (a deploy while an install is fetching,
and Force update), every cache holds one build and no page ever boots a mixed
pair: the fetch handler's own-cache-only lookup keeps a waiting build out of
the running one, and activation drops every other cache. -/

def benignC (s : State) : Event → Bool
  | .deploy => s.installing.isNone
  | .forceStart _ => false
  | _ => true

inductive Reach3 : State → Prop
  | init : Reach3 init
  | step {s : State} (e : Event) : Reach3 s → en s e = true → benignC s e = true → Reach3 (step s e)

/-- The non-tab part of the invariant. -/
def CS (s : State) : Prop :=
  (∀ v p, s.cache v = some p → p.1 = p.2) ∧
  (∀ j, s.stageJs = some j → s.installing.isSome = true ∧ j = s.dep) ∧
  (∀ w, s.stageWasm = some w → s.installing.isSome = true ∧ w = s.dep) ∧
  s.mixedBoot = false

def CInv (s : State) : Prop := CS s ∧ ∀ t, (s.tabs t).force = false

theorem cinv_init : CInv init := by
  refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_⟩ <;> simp [init]
  all_goals (intro v a b h; split at h <;> simp_all)

theorem cinv_updT {s : State} (h : CInv s) (t : Bool) (f : Tab → Tab) (hf : ∀ x, (f x).force = x.force) :
    CInv (updT t f s) := by
  obtain ⟨a, b⟩ := h
  refine ⟨a, fun u => ?_⟩
  simp only [updT_tabs]; split
  · rw [hf]; exact b u
  · exact b u

macro "c_upd" h:term : tactic => `(tactic| ((try simp only [step]); apply cinv_updT; all_goals first | exact $h | (intro _; rfl)))

theorem cinv_showBtn {s : State} (h : CInv s) (t : Bool) (v : Nat) : CInv (showBtn t v s) := by
  simp only [showBtn]
  apply cinv_updT
  · exact h
  · intro _; rfl

theorem serve_consistent {s : State} (h : CS s) : (serve s).2.1 = (serve s).2.2 := by
  obtain ⟨a1, _, _, _⟩ := h
  unfold serve
  cases ha : s.active with
  | none => rfl
  | some v =>
    simp only []
    cases hc : s.cache v with
    | none => rfl
    | some p => exact a1 v p hc

theorem cinv_reload {s : State} (h : CInv s) (t : Bool) (auto : Bool) : CInv (reload t auto s) := by
  obtain ⟨⟨a1, a2, a3, a4⟩, b⟩ := h
  have hs := serve_consistent ⟨a1, a2, a3, a4⟩
  unfold reload
  simp only []
  generalize serve s = sv at hs ⊢
  obtain ⟨c, p⟩ := sv
  simp only at hs ⊢
  refine ⟨⟨a1, a2, a3, ?_⟩, fun u => ?_⟩
  · simp [a4, hs]
  · simp only [updT_tabs]; split
    · cases c <;> rfl
    · exact b u

theorem cinv_activate {s : State} (h : CInv s) (v : Nat) : CInv (activate v s) := by
  obtain ⟨⟨a1, a2, a3, a4⟩, b⟩ := h
  refine ⟨⟨fun u p hp => ?_, a2, a3, a4⟩, fun u => b u⟩
  simp only [activate, mapTabs_cache] at hp
  split at hp
  · exact a1 u p hp
  · cases hp

theorem cinv_updCheck {s : State} (h : CInv s) : CInv (updCheck s) := by
  obtain ⟨⟨a1, a2, a3, a4⟩, b⟩ := h
  unfold updCheck; split
  · exact ⟨⟨a1, fun j hj => by simp at hj, fun w hw => by simp at hw, a4⟩, b⟩
  · exact ⟨⟨a1, a2, a3, a4⟩, b⟩

theorem cinv_applyStart {s : State} (h : CInv s) (t : Bool) : CInv (applyStart t s) := by
  unfold applyStart
  have h1 : CInv (updT t (fun x => { x with appUpdating := true, modal := false }) { s with intents := s.intents + 1 }) := by
    apply cinv_updT
    · exact h
    · intro _; rfl
  simp only []
  split
  · apply cinv_updT (cinv_updCheck h1); intro _; rfl
  · apply cinv_updT h1; intro _; rfl

theorem cinv_skipQ {X : State} (h : CInv X) (q : Option Nat) : CInv { X with skipQ := q } := h

theorem cinv_step {s : State} {e : Event} (h : CInv s) (he : en s e = true) (hb : benignC s e = true) :
    CInv (step s e) := by
  obtain ⟨⟨a1, a2, a3, a4⟩, b⟩ := h
  have hs : CInv s := ⟨⟨a1, a2, a3, a4⟩, b⟩
  cases e with
  | deploy =>
    simp [benignC] at hb
    refine ⟨⟨a1, fun j hj => ?_, fun w hw => ?_, a4⟩, b⟩
    · have := (a2 j hj).1; rw [hb] at this; cases this
    · have := (a3 w hw).1; rw [hb] at this; cases this
  | browserCheck => exact cinv_updCheck hs
  | fetchJs =>
    have hi : s.installing.isSome = true := by simp [en] at he; grind
    refine ⟨⟨a1, fun j hj => ?_, a3, a4⟩, b⟩
    simp [step] at hj; subst hj; exact ⟨hi, rfl⟩
  | fetchWasm =>
    have hi : s.installing.isSome = true := by simp [en] at he; grind
    refine ⟨⟨a1, a2, fun w hw => ?_, a4⟩, b⟩
    simp [step] at hw; subst hw; exact ⟨hi, rfl⟩
  | installOk =>
    simp only [step]
    split
    · rename_i v j w _ hj hw
      have ej := (a2 j hj).2
      have ew := (a3 w hw).2
      have c0 : ∀ u p, (if u = v then some (j, w) else s.cache u) = some p → p.1 = p.2 := by
        intro u p hp; split at hp
        · cases hp; simp [ej, ew]
        · exact a1 u p hp
      have bt : ∀ u, (onInstalled v (s.tabs u)).force = false := by
        intro u; unfold onInstalled; simp only []; split <;> split <;> exact b u
      have act : ∀ (X : State), X.cache = (fun u => if u = v then some (j, w) else s.cache u) →
          (∀ u, (X.tabs u).force = false) → X.stageJs = none → X.stageWasm = none → X.mixedBoot = false →
          CInv (activate v X) := by
        intro X hc ht hj' hw' hm
        have e1 : (activate v X).stageJs = none := hj'
        have e2 : (activate v X).stageWasm = none := hw'
        refine ⟨⟨?_, ?_, ?_, hm⟩, ?_⟩
        · intro u p hp
          have hp' : (if u = v then X.cache u else none) = some p := hp
          rw [hc] at hp'
          split at hp'
          · exact c0 u p hp'
          · cases hp'
        · intro j' h; rw [e1] at h; cases h
        · intro w' h; rw [e2] at h; cases h
        · intro u
          show (claim v (X.tabs u)).force = false
          exact ht u
      have plain : ∀ (X : State), X.cache = (fun u => if u = v then some (j, w) else s.cache u) →
          (∀ u, (X.tabs u).force = false) → X.stageJs = none → X.stageWasm = none → X.mixedBoot = false →
          CInv X := by
        intro X hc ht hj' hw' hm
        refine ⟨⟨?_, ?_, ?_, hm⟩, ht⟩
        · intro u p hp; rw [hc] at hp; exact c0 u p hp
        · intro j' h; rw [hj'] at h; cases h
        · intro w' h; rw [hw'] at h; cases h
      split
      · apply cinv_skipQ
        split
        · apply act <;> first | rfl | (intro u; exact bt u) | exact a4
        · apply plain <;> first | rfl | (intro u; exact bt u) | exact a4
      · split
        · apply act <;> first | rfl | (intro u; exact bt u) | exact a4
        · apply plain <;> first | rfl | (intro u; exact bt u) | exact a4
    · exact hs
  | installFail =>
    simp only [step]; split
    · refine ⟨⟨a1, fun _ h => by simp [mapTabs] at h, fun _ h => by simp [mapTabs] at h, a4⟩, fun u => ?_⟩
      have := b u
      simp only [mapTabs_tabs, onRedundant]
      split <;> simp_all
    · exact hs
  | regResolve t =>
    have h1 := cinv_updT hs t (fun x => { x with regd := true }) (fun _ => rfl)
    simp only [step]; split
    · exact cinv_showBtn h1 t _
    · split
      · obtain ⟨⟨c1, _, _, c4⟩, c5⟩ := h1
        exact ⟨⟨c1, fun _ h => by simp at h, fun _ h => by simp at h, c4⟩, c5⟩
      · exact h1
  | instFire t =>
    have h1 := cinv_updT hs t (fun x => { x with instQ := none }) (fun _ => rfl)
    simp only [step]; split
    · split
      · exact cinv_showBtn h1 t _
      · exact h1
    · exact h1
  | skipDeliver =>
    simp only [step]; split
    · split
      · exact cinv_activate hs _
      · exact hs
    · exact hs
  | ccFire t =>
    have h1 := cinv_updT hs t (fun x => { x with ccQ := false }) (fun _ => rfl)
    simp only [step]; split
    · exact cinv_reload h1 t true
    · c_upd h1
  | userReload t => exact cinv_reload hs t false
  | gameOn t => c_upd hs
  | gameOff t => c_upd hs
  | updClick t =>
    simp only [step]; split
    · c_upd hs
    · exact cinv_applyStart hs t
  | confirm t => exact cinv_applyStart hs t
  | notNow t => c_upd hs
  | applyResume t =>
    simp only [step]; split
    · c_upd hs
    · c_upd hs
    · c_upd hs
  | resetFire t =>
    simp only [step]
    apply cinv_reload
    exact ⟨⟨fun _ _ h => by simp at h, fun _ h => by simp at h, fun _ h => by simp at h, a4⟩, b⟩
  | checkStart t => c_upd hs
  | chkCur t => c_upd hs
  | chkLatest t => c_upd hs
  | chkSw t => c_upd hs
  | chkEval t =>
    simp only [step]; split
    · have h1 := cinv_updT hs t (fun x => { x with chk := none }) (fun _ => rfl)
      split
      · exact cinv_showBtn h1 t _
      · exact h1
    · exact hs
  | forceStart t => simp [benignC] at hb
  | rPutJs => simp [en, b] at he
  | rPutWasm => simp [en, b] at he
  | forceDone t => simp [en, b] at he

theorem cinv_reach3 {s : State} (h : Reach3 s) : CInv s := by
  induction h with
  | init => exact cinv_init
  | step e _ he hb ih => exact cinv_step ih he hb

/-- Without a deploy landing inside an install, and without Force update, no
    page ever boots index.js and em.wasm from different builds. -/
theorem no_mixed_boot_without_straddle {s : State} (h : Reach3 s) : s.mixedBoot = false :=
  (cinv_reach3 h).1.2.2.2

/-! ## Counterexamples -/

/-- Two tabs; the game is running in tab B (`true`), tab A (`false`) is on the
    home screen. A deploy lands and the browser installs it; both tabs show
    Update. The user clicks Update in A: no game there, so no confirm, and
    applyUpdate posts skipWaiting. The worker activates and claims *both*
    tabs, and B's controllerchange handler reloads B (`hadController`) in the
    middle of its game, which its user never agreed to. sw.js 44 promises the
    opposite ("an update never force-reloads a tab mid-game"). -/
theorem bug_update_in_one_tab_reloads_the_other_midgame :
    witnesses [.gameOn true, .regResolve false, .regResolve true, .deploy, .browserCheck,
               .fetchJs, .fetchWasm, .installOk, .instFire false,
               .updClick false, .applyResume false, .skipDeliver, .ccFire true]
      (fun s => s.forcedMidGame) = true := by decide

/-- The install fetches each asset separately under `?v=<CACHE_VERSION>`, and
    whatever the server answers is stored; nothing checks it is the build the
    cache is named for. A deploy landing between two of those fetches (or a CDN
    still handing out the previous object for one of them) leaves
    `dingbat-<v>` holding index.js from one build and em.wasm from another; the
    worker serves that pair on every launch until the next update. -/
theorem bug_install_across_deploy_mixes_cache :
    witnesses [.regResolve false, .deploy, .browserCheck, .fetchJs, .deploy, .fetchWasm,
               .installOk, .instFire false, .updClick false, .applyResume false, .skipDeliver,
               .ccFire false]
      (fun s => s.mixedBoot) = true := by decide

/-- Force update rewrites the *live* cache one asset at a time. A tab booted
    between the two writes (opened, or reloaded by its user) gets the new
    index.js with the old em.wasm. -/
theorem bug_force_update_serves_half_written_cache :
    witnesses [.deploy, .forceStart false, .rPutJs, .userReload true]
      (fun s => s.mixedBoot) = true := by decide

end WebState.ServiceWorker
