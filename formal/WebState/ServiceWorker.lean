-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/index.js: applyUpdate checkForUpdate fullResetReload maybeCheckForUpdate showUpdateButton on:visibilitychange
-- @models web/sw.js: fetchAndCache installAssets probeVersion reinstall on:activate on:fetch on:install on:message

/-
# Service worker, update check and update flow (web/sw.js, web/index.js)

Written against dd7ba741f. `step` now models the code as fixed by the commit
that turned the `bug_*` theorems below into `regress_*` ones ("web: an update
never reloads another tab's game, and never caches two builds";
`git log -- formal/WebState/ServiceWorker.lean`); line numbers are at that
commit.

sw.js: `install` (69) runs `installAssets` (55) into the cache
`dingbat-<CACHE_VERSION>`: a version probe (`probeVersion`, 39: version.txt
under a URL no edge has seen), every asset fetched once under
`?v=<CACHE_VERSION>` with `cache: "reload"`, then the cached version.txt and a
second probe; unless the first probe named CACHE_VERSION and all three agree,
it throws and the install fails. The worker then waits until a page posts
`skipWaiting` (110). `activate` (78) deletes every other `dingbat-*` cache
and `clients.claim()`s every tab. `fetch` (128) answers from *its own* cache
only (so an installed-but-waiting build is never mixed in), falling back to
the network. The `reinstall` message (the menu's Force update) runs
`reinstall` (97): the same bracketed download into a staging cache, then one
put per asset into the *live* cache.

index.js: `register` (55) shows the Update button if a worker is already
waiting, and on `updatefound` shows it when the new worker's `statechange`
finds it `installed` while the page has a controller (61-66).
`controllerchange` (83) acts when `hadController || appUpdating`, once
(`refreshing`): it reloads if this tab asked for the update (`appUpdating`)
or has no game in progress (`currentRomName || linkMode || rollbackMode ||
netActive()`); otherwise it sets `updateActivated` (177) and shows the
button, relabelled "Reload". `checkForUpdate` (117) awaits three fetches
(the cached version.txt through the worker, a no-store version.txt, a
no-store sw.js) and shows the button when the first two differ and sw.js's
CACHE_VERSION equals the fresh version.txt. `maybeCheckForUpdate` (144) runs
at load and on `visibilitychange`. The button (224) opens the confirm modal
when a game is loaded, else runs `applyUpdate` (179): `appUpdating = true`;
with `updateActivated`, `location.reload()`; else `await
swRegistration.update()`, then `skipWaiting` to the waiting worker, or wait
for the installing one to reach `installed` (then `skipWaiting`) or
`redundant` (then `fullResetReload`, 160), or with neither, `fullResetReload`.

## What is modelled

* A build is a version number; `dep` is what the origin serves now. A deploy
  bumps it (deploys only move forward). Two assets stand for all of them:
  index.js (with version.txt, fetched alongside) and em.wasm. A cache holds,
  per asset, the build its bytes came from. A version probe reads `dep`.
* Two tabs of the app (`Bool`-indexed). Each tab is the current page instance:
  the build it booted (`running`, per asset), whether it is controlled and by
  which worker version, the index.js flags, and its in-flight continuations
  (applyUpdate between awaits, one checkForUpdate's three fetches).
* The registration: active / waiting / installing worker versions, the
  installing worker's first probe and per-asset fetches, a posted
  `skipWaiting`.
* `reload t` replaces tab t's page: it boots from the active worker's cache
  (or the network when there is no worker or the entry is missing).

## Abstractions

* `register()`'s promise and the updatefound/statechange listeners: the
  listener is attached when `register()` resolves (`regResolve`); the
  `installed` statechange is a queued event per tab (`instFire`) that re-reads
  `sw.state` (installed = still the waiting worker) and the controller, as the
  handler does.
* `installAssets`'s tail (the `cache.match` of version.txt and the second
  probe) is one event, `installEnd`: nothing it reads changes in between
  except `dep`, and a deploy there only makes the check fail.
* `fullResetReload`'s four awaits are one event (`resetFire`): nothing between
  them reads state this model tracks except other tabs' boots, which then hit
  the network (no worker), as modelled.
* `update()` rejecting (offline) and the Force-update failure/timeout paths
  (including a reinstall whose download fails its check) go to
  `fullResetReload`; only the success paths are modelled for Force update.
  Two tabs' Force updates share one download (`rProbe`, `rsJs`, ...), as the
  one live worker's reinstalls would race on the one live cache.
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

Proved: no tab is ever reloaded mid-game unless its own user clicked Update
or Force update in it (`no_forced_midgame`, every interleaving); with no
Update / Force update accepted, no tab is ever reloaded by the app
(`no_reload_without_a_click`: no reload loop exists without a click); the
button is shown at most once per page (`shows_at_most_once`); without Force
update, no page ever boots a mixed index.js/em.wasm pair, whatever deploys
land inside installs (`no_mixed_boot_without_force`); a Force update's
download only goes live when it is one build (`force_stage_one_build`).
Fixed and now proved safe on their old traces (`regress_*`): Update in one tab
reloads a game in another; an install straddling a deploy caches a mixed
pair. Still refuted (`bug_*`): Force update's commit to the live cache is one
put per asset, so a tab booting between two puts gets a mixed pair (the window
is now the puts, not the download).
-/
namespace WebState.ServiceWorker

inductive AK where
  | idle
  | awaitUpdate          -- applyUpdate suspended at `await swRegistration.update()`
  | watch (v : Nat)      -- statechange listener on installing worker v (202)
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
  hadController : Bool := true       -- (81)
  appUpdating : Bool := false        -- (174)
  refreshing  : Bool := false        -- (82)
  ready       : Bool := false        -- updateActivated (177)
  updAvail    : Bool := false        -- updateAvailable / button shown (109)
  shows       : Nat := 0             -- ghost: hidden -> shown transitions this page
  promptV     : Option Nat := none   -- ghost: build the button was last shown for
  game        : Bool := false        -- currentRomName || linkMode (|| rollbackMode || netMode)
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
  probe0     : Option Nat             -- the installing worker's first version probe
  stageJs    : Option Nat             -- the installing worker's fetched index.js
  stageWasm  : Option Nat             -- ... and em.wasm
  cache      : Nat → Option (Nat × Nat)  -- dingbat-<v> : (index.js build, em.wasm build)
  skipQ      : Option Nat             -- skipWaiting posted to worker v
  rProbe     : Option Nat             -- reinstall: the first version probe
  rsJs       : Option Nat             -- reinstall: index.js in the staging cache
  rsWasm     : Option Nat             -- ... and em.wasm
  rOk        : Bool                   -- reinstall: the download passed its check
  rJs        : Bool                   -- a reinstall has put index.js into the live cache
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
  probe0 := none
  stageJs := none
  stageWasm := none
  cache := fun v => if v = 0 then some (0, 0) else none
  skipQ := none
  rProbe := none
  rsJs := none
  rsWasm := none
  rOk := false
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

/-- showUpdateButton (112). -/
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
    -- network fallback (sw.js 163)
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
    applyUpdate watching worker v then posts skipWaiting (204). -/
def onInstalled (v : Nat) (x : Tab) : Tab :=
  let x := if x.regd then { x with instQ := some v } else x
  if x.applyK == .watch v then { x with applyK := .done } else x

/-- The `redundant` statechange: an applyUpdate watching worker v falls back to
    fullResetReload (208). -/
def onRedundant (v : Nat) (x : Tab) : Tab :=
  if x.applyK == .watch v then { x with applyK := .resetting } else x

def mapTabs (g : Tab → Tab) (s : State) : State := { s with tabs := fun u => g (s.tabs u) }

/-- activate (sw.js 78): delete the other caches, claim every tab. -/
def activate (v : Nat) (s : State) : State :=
  mapTabs (claim v)
    { s with active := some v,
             waiting := if s.waiting = some v then none else s.waiting,
             cache := fun u => if u = v then s.cache u else none }

/-- A browser update check (navigation, periodic, or reg.update()): a changed
    sw.js starts an install. -/
def updCheck (s : State) : State :=
  if s.installing.isNone && s.active.isSome && s.active != some s.dep && s.waiting != some s.dep then
    { s with installing := some s.dep, probe0 := none, stageJs := none, stageWasm := none }
  else s

/-- The install fails (an asset fetch, or installAssets's check): the worker is
    redundant. -/
def installFailed (v : Nat) (s : State) : State :=
  mapTabs (onRedundant v)
    { s with installing := none, probe0 := none, stageJs := none, stageWasm := none }

inductive Event where
  | deploy
  | browserCheck                 -- the browser re-fetches sw.js
  | probeFirst                   -- installAssets's first probeVersion() lands (sw.js 56)
  | fetchJs                      -- the installing worker's index.js?v= fetch completes
  | fetchWasm                    -- ... em.wasm?v=
  | installEnd                   -- installAssets's tail: version.txt check, second probe (61-65)
  | installFail                  -- one asset fetch failed: worker redundant
  | regResolve (t : Bool)        -- register().then (55)
  | instFire (t : Bool)          -- the queued `installed` statechange (63)
  | skipDeliver                  -- the waiting worker handles skipWaiting and activates
  | ccFire (t : Bool)            -- controllerchange handler (83)
  | userReload (t : Bool)        -- the user reloads / reopens the tab
  | gameOn (t : Bool) | gameOff (t : Bool)
  | updClick (t : Bool)          -- #update-btn (224)
  | confirm (t : Bool)           -- #update-confirm (233)
  | notNow (t : Bool)
  | applyResume (t : Bool)       -- applyUpdate after `await update()` (193)
  | resetFire (t : Bool)         -- fullResetReload (160)
  | checkStart (t : Bool)        -- maybeCheckForUpdate at load / visibilitychange (144)
  | chkCur (t : Bool) | chkLatest (t : Bool) | chkSw (t : Bool)  -- the three fetches land
  | chkEval (t : Bool)           -- the rest of checkForUpdate
  | forceStart (t : Bool)        -- Force update, confirmed (268)
  | rProbe0                      -- reinstall: installAssets's first probe
  | rFetchJs | rFetchWasm        -- reinstall: one asset into the staging cache
  | rVerify                      -- reinstall: installAssets's check passes (the failure path
                                 --   replies ok:false -> fullResetReload, not modelled)
  | rPutJs | rPutWasm            -- reinstall: one put into the live cache (sw.js 104)
  | forceDone (t : Bool)         -- "reinstalled" ok: location.reload() (261)
  deriving DecidableEq, Repr

def anyForce (s : State) : Bool := (s.tabs true).force || (s.tabs false).force

def en (s : State) : Event → Bool
  | .deploy => true
  | .browserCheck => true
  | .probeFirst => s.installing.isSome && s.probe0.isNone
  | .fetchJs => s.installing.isSome && s.probe0.isSome && s.stageJs.isNone
  | .fetchWasm => s.installing.isSome && s.probe0.isSome && s.stageWasm.isNone
  | .installEnd => s.installing.isSome && s.stageJs.isSome && s.stageWasm.isSome
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
  | .rProbe0 => anyForce s && s.rProbe.isNone
  | .rFetchJs => anyForce s && s.rProbe.isSome && s.rsJs.isNone
  | .rFetchWasm => anyForce s && s.rProbe.isSome && s.rsWasm.isNone
  | .rVerify => anyForce s && !s.rOk &&
      (match s.rProbe, s.rsJs, s.rsWasm with
       | some p, some j, some _ => j == p && s.dep == p
       | _, _, _ => false)
  | .rPutJs => anyForce s && s.rOk && !s.rJs
  | .rPutWasm => anyForce s && s.rOk && !s.rWasm
  | .forceDone t => (s.tabs t).force && s.rJs && s.rWasm

/-- applyUpdate (179), first segment: flags, close the modal; then either the
    reload another tab's update left waiting (187), or `update()`. -/
def applyStart (t : Bool) (s : State) : State :=
  let x := s.tabs t
  let s := { s with intents := s.intents + 1 }
  let s := updT t (fun x => { x with appUpdating := true, modal := false }) s
  if x.ready then reload t true s
  else if x.regd then updT t (fun x => { x with applyK := .awaitUpdate }) (updCheck s)
  else updT t (fun x => { x with applyK := .resetting }) s

def step (s : State) : Event → State
  | .deploy => { s with dep := s.dep + 1 }
  | .browserCheck => updCheck s
  | .probeFirst => { s with probe0 := some s.dep }
  -- fetchAndCache: `?v=<CACHE_VERSION>` is a fresh URL; the server answers with
  -- whatever is deployed at that moment
  | .fetchJs => { s with stageJs := some s.dep }
  | .fetchWasm => { s with stageWasm := some s.dep }
  | .installEnd =>
    match s.installing, s.probe0, s.stageJs, s.stageWasm with
    | some v, some p, some j, some w =>
      -- 57-65: the first probe named this worker's build, and the cached
      -- version.txt and the second probe agree with it
      if j == p && s.dep == p && p == v then
        let anyWatch := (s.tabs true).applyK == .watch v || (s.tabs false).applyK == .watch v
        let s := mapTabs (onInstalled v)
          { s with cache := fun u => if u = v then some (j, w) else s.cache u,
                   installing := none, probe0 := none, stageJs := none, stageWasm := none }
        -- no active worker: activates at once (first install); else waits
        let s := match s.active with
          | none => activate v s
          | some _ => { s with waiting := some v }
        if anyWatch then { s with skipQ := some v } else s
      else installFailed v s
    | _, _, _, _ => s
  | .installFail =>
    match s.installing with
    | some v => installFailed v s
    | none => s
  -- register().then (55): if (reg.waiting) showUpdateButton(); a missing
  -- registration is created and installs
  | .regResolve t =>
    let s := updT t (fun x => { x with regd := true }) s
    match s.waiting with
    | some v => showBtn t v s
    | none =>
      if s.active.isNone && s.installing.isNone then
        { s with installing := some s.dep, probe0 := none, stageJs := none, stageWasm := none }
      else s
  -- statechange (63): sw.state === "installed" (still waiting) && controller
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
  -- controllerchange (83): reload only this tab's own update, or a tab with no
  -- game in progress; else updateActivated + the button (89-92)
  | .ccFire t =>
    let x := s.tabs t
    let s := updT t (fun x => { x with ccQ := false }) s
    if (x.hadController || x.appUpdating) && !x.refreshing then
      if x.appUpdating || !x.game then reload t true s
      else
        match s.active with
        | some v => showBtn t v (updT t (fun x => { x with ready := true, hadController := true }) s)
        | none => updT t (fun x => { x with ready := true, hadController := true }) s
    else updT t (fun x => { x with hadController := true }) s
  | .userReload t => reload t false s
  | .gameOn t => updT t (fun x => { x with game := true }) s
  | .gameOff t => updT t (fun x => { x with game := false }) s
  -- #update-btn (224): a game loaded -> confirm modal, else applyUpdate
  | .updClick t =>
    if (s.tabs t).game then updT t (fun x => { x with modal := true }) s else applyStart t s
  | .confirm t => applyStart t s
  | .notNow t => updT t (fun x => { x with modal := false }) s
  -- after `await swRegistration.update()` (193-216)
  | .applyResume t =>
    match s.waiting, s.installing with
    | some v, _ => updT t (fun x => { x with applyK := .done }) { s with skipQ := some v }
    | none, some v => updT t (fun x => { x with applyK := .watch v }) s
    | none, none => updT t (fun x => { x with applyK := .resetting }) s
  -- fullResetReload (160): delete every cache, unregister, reload
  | .resetFire t =>
    reload t true { s with cache := fun _ => none, active := none, waiting := none,
                           installing := none, probe0 := none, stageJs := none,
                           stageWasm := none, skipQ := none }
  | .checkStart t => updT t (fun x => { x with chk := some {} }) s
  -- fetch("version.txt"): the controller's own cache (sw.js 159-163), else network
  | .chkCur t =>
    let x := s.tabs t
    let v := if x.controlled then (match s.cache x.ctrlV with | some p => p.1 | none => s.dep) else s.dep
    updT t (fun x => { x with chk := x.chk.map (fun c => { c with cur := some v }) }) s
  | .chkLatest t => updT t (fun x => { x with chk := x.chk.map (fun c => { c with latest := some s.dep }) }) s
  | .chkSw t => updT t (fun x => { x with chk := x.chk.map (fun c => { c with sw := some s.dep }) }) s
  -- 132-138: current && latest && latest !== current && deployed === latest -> button
  | .chkEval t =>
    match (s.tabs t).chk with
    | some { cur := some c, latest := some l, sw := some d } =>
      let s := updT t (fun x => { x with chk := none }) s
      if c != l && d == l then showBtn t l s else s
    | _ => s
  -- Force update (268): appUpdating; the live worker re-downloads
  | .forceStart t =>
    updT t (fun x => { x with force := true, appUpdating := true })
      { s with intents := s.intents + 1, rProbe := none, rsJs := none, rsWasm := none,
               rOk := false, rJs := false, rWasm := false }
  | .rProbe0 => { s with rProbe := some s.dep }
  -- reinstall's download: `?v=<nonce>` reaches the origin
  | .rFetchJs => { s with rsJs := some s.dep }
  | .rFetchWasm => { s with rsWasm := some s.dep }
  | .rVerify => { s with rOk := true }
  -- reinstall's commit (sw.js 103-104): one cache.put per asset into CACHE_NAME
  | .rPutJs =>
    match s.active with
    | some v =>
      let j := s.rsJs.getD s.dep
      let c := fun u => if u = v then some (j, ((s.cache u).map Prod.snd).getD s.dep) else s.cache u
      { s with rJs := true, cache := c }
    | none => s
  | .rPutWasm =>
    match s.active with
    | some v =>
      let w := s.rsWasm.getD s.dep
      let c := fun u => if u = v then some (((s.cache u).map Prod.fst).getD s.dep, w) else s.cache u
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

/-! ## Counterexamples, and the old traces on the fixed code -/

/-- Was `bug_update_in_one_tab_reloads_the_other_midgame`. Two tabs; the game
    is running in tab B (`true`), tab A (`false`) is on the home screen. A
    deploy lands and the browser installs it; both tabs show Update. The user
    clicks Update in A: no game there, so no confirm, and applyUpdate posts
    skipWaiting. The worker activates and claims *both* tabs. B's
    controllerchange handler used to reload B (`hadController`) in the middle
    of its game; now B keeps its game and its button says Reload. -/
theorem regress_update_in_one_tab_reloads_the_other_midgame :
    witnesses [.gameOn true, .regResolve false, .regResolve true, .deploy, .browserCheck,
               .probeFirst, .fetchJs, .fetchWasm, .installEnd, .instFire false,
               .updClick false, .applyResume false, .skipDeliver, .ccFire true]
      (fun s => !s.forcedMidGame && (s.tabs true).ready && (s.tabs true).updAvail &&
                (s.tabs true).running == (0, 0)) = true := by decide

/-- ...and B's player clicking it, through the confirm, is what reloads B, onto
    the new build. -/
theorem regress_update_in_one_tab_then_reload_when_ready :
    witnesses [.gameOn true, .regResolve false, .regResolve true, .deploy, .browserCheck,
               .probeFirst, .fetchJs, .fetchWasm, .installEnd, .instFire false,
               .updClick false, .applyResume false, .skipDeliver, .ccFire true,
               .updClick true, .confirm true]
      (fun s => !s.forcedMidGame && (s.tabs true).running == (1, 1)) = true := by decide

/-- Was `bug_install_across_deploy_mixes_cache`. The install fetches each asset
    separately, and a deploy landing between two of those fetches (or a CDN
    still handing out the previous object for one of them) used to leave
    `dingbat-<v>` holding index.js from one build and em.wasm from another.
    Now the second probe sees the deploy and the install fails: no worker
    waits, nothing is cached, and the tab keeps booting the old build. -/
theorem regress_install_across_deploy_mixes_cache :
    witnesses [.regResolve false, .deploy, .browserCheck, .probeFirst, .fetchJs, .deploy,
               .fetchWasm, .installEnd, .userReload false]
      (fun s => !s.mixedBoot && s.waiting.isNone && s.installing.isNone &&
                s.cache 1 == none && (s.tabs false).running == (0, 0)) = true := by decide

/-- The browser tries again (the next update check finds sw.js still new) and,
    with no deploy inside, installs the latest build whole. -/
theorem regress_install_across_deploy_then_retry :
    witnesses [.regResolve false, .deploy, .browserCheck, .probeFirst, .fetchJs, .deploy,
               .fetchWasm, .installEnd, .browserCheck, .probeFirst, .fetchJs, .fetchWasm,
               .installEnd]
      (fun s => s.waiting == some 2 && s.cache 2 == some (2, 2)) = true := by decide

/-- Force update still commits to the *live* cache one put per asset. A tab
    booted between the two puts (opened, or reloaded by its user) gets the new
    index.js with the old em.wasm. The window is now the puts alone: the
    download goes to a staging cache first (and one that straddles a deploy
    never goes live, `force_stage_one_build`). -/
theorem bug_force_update_serves_half_written_cache :
    witnesses [.deploy, .forceStart false, .rProbe0, .rFetchJs, .rFetchWasm, .rVerify,
               .rPutJs, .userReload true]
      (fun s => s.mixedBoot) = true := by decide

/-- A Force update whose download straddles a deploy cannot pass its check. -/
theorem regress_force_update_straddle_not_verified :
    run init [.deploy, .forceStart false, .rProbe0, .rFetchJs, .deploy, .rFetchWasm,
              .rVerify] = none := by decide

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
  unfold applyStart; simp only []; (repeat' split) <;> simp
@[simp] theorem installFailed_intents : (installFailed v s).intents = s.intents := rfl
@[simp] theorem installFailed_tabs : (installFailed v s).tabs u = onRedundant v (s.tabs u) := rfl
@[simp] theorem installFailed_active : (installFailed v s).active = s.active := rfl
@[simp] theorem installFailed_skipQ : (installFailed v s).skipQ = s.skipQ := rfl
@[simp] theorem installFailed_autoReloads : (installFailed v s).autoReloads = s.autoReloads := rfl
@[simp] theorem installFailed_forced : (installFailed v s).forcedMidGame = s.forcedMidGame := rfl
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
  | probeFirst => exact qs
  | fetchJs => exact qs
  | fetchWasm => exact qs
  | installEnd =>
    simp only [step]
    split
    · rename_i v p j w _ _ _ _
      split
      · have i1 : (s.tabs true).applyK = .idle := (a5 true).1
        have i2 : (s.tabs false).applyK = .idle := (a5 false).1
        obtain ⟨av, hav⟩ := Option.isSome_iff_exists.mp a1
        simp only [hav, i1, i2, mapTabs]
        exact ⟨by simp, by simpa using a2, by simpa using a3, by simpa using a4,
          fun u => onInstalled_qt v _ (a5 u)⟩
      · exact ⟨by simpa using a1, by simpa using a2, by simpa using a3, by simpa using a4,
          fun u => by simpa using onRedundant_qt v _ (a5 u)⟩
    · exact qs
  | installFail =>
    simp only [step]
    split
    · exact ⟨by simpa using a1, by simpa using a2, by simpa using a3, by simpa using a4,
        fun u => by simpa using onRedundant_qt _ _ (a5 u)⟩
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
  | rProbe0 | rFetchJs | rFetchWasm | rVerify | rPutJs | rPutWasm =>
    have := (a5 true).2.2.2; have := (a5 false).2.2.2; simp_all [en, anyForce]
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
  · exact p_reload h1 t true
  · split
    · apply p_updT (p_updCheck h1); pt_triv
    · apply p_updT h1; pt_triv


theorem onInstalled_pt (v : Nat) (x : Tab) (h : PT x) : PT (onInstalled v x) := by
  unfold onInstalled PT at *; simp only []; split <;> split <;> simp_all

theorem onRedundant_pt (v : Nat) (x : Tab) (h : PT x) : PT (onRedundant v x) := by
  unfold onRedundant PT at *; split <;> simp_all

theorem p_installFailed {s : State} (h : P s) (v : Nat) : P (installFailed v s) :=
  fun u => by simpa using onRedundant_pt v _ (h u)

theorem p_step {s : State} (h : P s) (e : Event) : P (step s e) := by
  cases e with
  | deploy => exact h
  | browserCheck => exact p_updCheck h
  | probeFirst => exact h
  | fetchJs => exact h
  | fetchWasm => exact h
  | installEnd =>
    simp only [step]; split
    · rename_i v p j w _ _ _ _
      split
      · have h1 : P (mapTabs (onInstalled v) s) := p_mapTabs h (onInstalled v) (onInstalled_pt v)
        have h2 : P (activate v (mapTabs (onInstalled v) s)) := p_activate h1 v
        split
        · split
          · exact fun u => h2 u
          · exact fun u => h1 u
        · split
          · exact fun u => h2 u
          · exact fun u => h1 u
      · exact p_installFailed h v
    · exact h
  | installFail =>
    simp only [step]; split
    · exact p_installFailed h _
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
    · split
      · exact p_reload h1 t true
      · have h2 := p_updT h1 t (fun x => { x with ready := true, hadController := true }) (by pt_triv)
        split
        · exact p_showBtn h2 t _
        · exact h2
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
  | rProbe0 | rFetchJs | rFetchWasm | rVerify => exact h
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

/-! ### No tab reloaded mid-game unasked

The app reloads a tab by itself in four places: controllerchange, the end of
fullResetReload, Force update's "reinstalled", and applyUpdate's
`updateActivated` path. Each is now either this tab's own Update / Force
update (`appUpdating`, set by the click before any of them can run) or a tab
with no game in progress. -/

/-- Per tab: an update in flight in this tab is one its user asked for. -/
def TI (x : Tab) : Prop :=
  (x.applyK ≠ .idle → x.appUpdating = true) ∧ (x.force = true → x.appUpdating = true)

def FI (s : State) : Prop := s.forcedMidGame = false ∧ ∀ t, TI (s.tabs t)

theorem ti_simple (x : Tab) (h : TI x) (y : Tab) (e1 : y.applyK = x.applyK)
    (e2 : y.appUpdating = x.appUpdating) (e3 : y.force = x.force) : TI y := by
  obtain ⟨a, b⟩ := h
  exact ⟨fun hk => e2 ▸ a (e1 ▸ hk), fun hf => e2 ▸ b (e3 ▸ hf)⟩

macro "ti_triv" : tactic => `(tactic| (intro x hx; exact ti_simple x hx _ rfl rfl rfl))

theorem fi_updT {s : State} (h : FI s) (t : Bool) (f : Tab → Tab)
    (hf : ∀ x, TI x → TI (f x)) : FI (updT t f s) := by
  obtain ⟨a, b⟩ := h
  refine ⟨a, fun u => ?_⟩
  simp only [updT_tabs]; split
  · exact hf _ (b u)
  · exact b u

theorem fi_updT_at {s : State} (h : FI s) (t : Bool) (f : Tab → Tab)
    (hf : TI (f (s.tabs t))) : FI (updT t f s) := by
  obtain ⟨a, b⟩ := h
  refine ⟨a, fun u => ?_⟩
  simp only [updT_tabs]; split
  · rename_i hu; subst hu; exact hf
  · exact b u

/-- `updT` with a function that keeps applyK/appUpdating/force. -/
macro "fi_upd" h:term : tactic =>
  `(tactic| ((try simp only [step]); apply fi_updT; all_goals first | exact $h | ti_triv))

theorem fi_mapTabs {s : State} (h : FI s) (g : Tab → Tab) (hg : ∀ x, TI x → TI (g x))
    (s' : State) (e1 : s'.forcedMidGame = s.forcedMidGame) (e2 : ∀ u, s'.tabs u = g (s.tabs u)) :
    FI s' := ⟨e1 ▸ h.1, fun u => e2 u ▸ hg _ (h.2 u)⟩

/-- A reload is fine when it is not the app's, or this tab asked for the
    update, or no game is in progress in it; the page it loads is fresh. -/
theorem fi_reload {s : State} (h : FI s) (t : Bool) (auto : Bool)
    (hok : auto = false ∨ (s.tabs t).appUpdating = true ∨ (s.tabs t).game = false) :
    FI (reload t auto s) := by
  obtain ⟨a, b⟩ := h
  simp only [reload]
  generalize serve s = sv
  obtain ⟨c, p⟩ := sv
  refine ⟨?_, fun u => ?_⟩
  · simp only [updT_forced, a, Bool.false_or]
    rcases hok with hk | hk | hk <;> simp [hk]
  · simp only [updT_tabs]
    split
    · cases c <;> exact ⟨fun hk => absurd rfl hk, fun hf => by cases hf⟩
    · exact b u

theorem fi_showBtn {s : State} (h : FI s) (t : Bool) (v : Nat) : FI (showBtn t v s) := by
  simp only [showBtn]; apply fi_updT
  · exact h
  · ti_triv

theorem updCheck_tabs (s : State) : (updCheck s).tabs = s.tabs := by
  unfold updCheck; split <;> rfl

theorem fi_updCheck {s : State} (h : FI s) : FI (updCheck s) := by
  unfold updCheck; split
  · exact h
  · exact h

theorem onInstalled_ti (v : Nat) (x : Tab) (h : TI x) : TI (onInstalled v x) := by
  obtain ⟨a, b⟩ := h
  unfold onInstalled; simp only []
  split <;> split <;> simp_all [TI] <;> grind

theorem onRedundant_ti (v : Nat) (x : Tab) (h : TI x) : TI (onRedundant v x) := by
  obtain ⟨a, b⟩ := h
  unfold onRedundant
  split <;> simp_all [TI] <;> grind

theorem fi_activate {s : State} (h : FI s) (v : Nat) : FI (activate v s) :=
  fi_mapTabs h (claim v) (by ti_triv) _ rfl (fun _ => rfl)

theorem fi_installFailed {s : State} (h : FI s) (v : Nat) : FI (installFailed v s) :=
  fi_mapTabs h (onRedundant v) (onRedundant_ti v) _ rfl (fun _ => rfl)

theorem fi_applyStart {s : State} (h : FI s) (t : Bool) : FI (applyStart t s) := by
  unfold applyStart
  have h1 : FI (updT t (fun x => { x with appUpdating := true, modal := false })
      { s with intents := s.intents + 1 }) := by
    apply fi_updT
    · exact h
    · intro x hx; exact ⟨fun _ => rfl, fun _ => rfl⟩
  simp only []
  split
  · exact fi_reload h1 t true (Or.inr (Or.inl (by simp)))
  · -- the tab's appUpdating is already true
    split
    · apply fi_updT_at (fi_updCheck h1)
      refine ⟨fun _ => ?_, fun _ => ?_⟩ <;> simp [updCheck_tabs]
    · apply fi_updT_at h1
      refine ⟨fun _ => ?_, fun _ => ?_⟩ <;> simp

theorem fi_step {s : State} {e : Event} (h : FI s) (he : en s e = true) : FI (step s e) := by
  have hs := h
  obtain ⟨a, b⟩ := h
  cases e with
  | deploy => exact hs
  | browserCheck => exact fi_updCheck hs
  | probeFirst => exact hs
  | fetchJs => exact hs
  | fetchWasm => exact hs
  | installEnd =>
    simp only [step]; split
    · rename_i v p j w _ _ _ _
      split
      · have h1 : FI (mapTabs (onInstalled v) { s with
            cache := fun u => if u = v then some (j, w) else s.cache u, installing := none,
            probe0 := none, stageJs := none, stageWasm := none }) :=
          fi_mapTabs hs (onInstalled v) (onInstalled_ti v) _ rfl (fun _ => rfl)
        have h2 := fi_activate h1 v
        split
        · split
          · exact ⟨h2.1, h2.2⟩
          · exact ⟨h1.1, h1.2⟩
        · split
          · exact h2
          · exact h1
      · exact fi_installFailed hs v
    · exact hs
  | installFail =>
    simp only [step]; split
    · exact fi_installFailed hs _
    · exact hs
  | regResolve t =>
    have h1 := fi_updT hs t (fun x => { x with regd := true }) (by ti_triv)
    simp only [step]; split
    · exact fi_showBtn h1 t _
    · split
      · exact h1
      · exact h1
  | instFire t =>
    have h1 := fi_updT hs t (fun x => { x with instQ := none }) (by ti_triv)
    simp only [step]; split
    · split
      · exact fi_showBtn h1 t _
      · exact h1
    · exact h1
  | skipDeliver =>
    simp only [step]; split
    · split
      · exact fi_activate hs _
      · exact hs
    · exact hs
  | ccFire t =>
    have h1 := fi_updT hs t (fun x => { x with ccQ := false }) (by ti_triv)
    simp only [step]; split
    · split
      · rename_i hc
        apply fi_reload h1 t true
        right
        simp only [updT_tabs, ↓reduceIte]
        cases hu : (s.tabs t).appUpdating
        · simp_all
        · simp
      · have h2 := fi_updT h1 t (fun x => { x with ready := true, hadController := true })
          (by ti_triv)
        split
        · exact fi_showBtn h2 t _
        · exact h2
    · fi_upd h1
  | userReload t => exact fi_reload hs t false (Or.inl rfl)
  | gameOn t => fi_upd hs
  | gameOff t => fi_upd hs
  | updClick t =>
    simp only [step]; split
    · fi_upd hs
    · exact fi_applyStart hs t
  | confirm t => exact fi_applyStart hs t
  | notNow t => fi_upd hs
  | applyResume t =>
    -- the tab is suspended in applyUpdate, which its click started
    have hu : (s.tabs t).appUpdating = true := by
      apply (b t).1; simp [en] at he; simp [he]
    simp only [step]; split <;>
      (refine fi_updT_at ?_ t _ ?_
       · exact ⟨a, b⟩
       · exact ⟨fun _ => hu, fun hf => (b t).2 hf⟩)
  | resetFire t =>
    have hu : (s.tabs t).appUpdating = true := by
      apply (b t).1; simp [en] at he; simp [he]
    simp only [step]
    refine fi_reload ?_ t true (Or.inr (Or.inl hu))
    exact ⟨a, b⟩
  | checkStart t => fi_upd hs
  | chkCur t => fi_upd hs
  | chkLatest t => fi_upd hs
  | chkSw t => fi_upd hs
  | chkEval t =>
    simp only [step]; split
    · have h1 := fi_updT hs t (fun x => { x with chk := none }) (by ti_triv)
      split
      · exact fi_showBtn h1 t _
      · exact h1
    · exact hs
  | forceStart t =>
    simp only [step]
    refine fi_updT ?_ t _ ?_
    · exact ⟨a, b⟩
    · intro x _; exact ⟨fun _ => rfl, fun _ => rfl⟩
  | rProbe0 | rFetchJs | rFetchWasm | rVerify => exact hs
  | rPutJs => simp only [step]; split <;> exact hs
  | rPutWasm => simp only [step]; split <;> exact hs
  | forceDone t =>
    have hu : (s.tabs t).appUpdating = true := by
      apply (b t).2; simp only [en, Bool.and_eq_true] at he; exact he.1.1
    simp only [step]
    apply fi_reload (fi_updT hs t (fun x => { x with force := false }) ?_) t true
    · right; left; simp [hu]
    · intro x hx; exact ⟨hx.1, fun h => by cases h⟩

theorem fi_reachable {s : State} (h : Reachable s) : FI s := by
  induction h with
  | init => exact ⟨rfl, fun _ => ⟨fun h => absurd rfl h, fun h => by cases h⟩⟩
  | step e _ he ih => exact fi_step ih he

/-- **No tab is reloaded mid-game unless its own user asked**, in every
    interleaving of deploys, installs, both tabs' Update and Force update
    clicks, and the controllerchange each activation fires in every tab. -/
theorem no_forced_midgame {s : State} (h : Reachable s) : s.forcedMidGame = false :=
  (fi_reachable h).1

/-! ### No mixed build without Force update

Every cache holds one build and no page ever boots a mixed pair, whatever
deploys land inside an install: `installAssets`'s check fails an install whose
download straddled one. The fetch handler's own-cache-only lookup keeps a
waiting build out of the running one, and activation drops every other cache.
The check only reads version.txt (fetched alongside index.js here) and the two
probes, never em.wasm; what makes it sound is that deploys only move forward,
so em.wasm's build lies between the two probes (`w` below). -/

def benignC : Event → Bool
  | .forceStart _ => false
  | _ => true

inductive Reach3 : State → Prop
  | init : Reach3 init
  | step {s : State} (e : Event) : Reach3 s → en s e = true → benignC e = true → Reach3 (step s e)

/-- The non-tab part of the invariant. -/
def CS (s : State) : Prop :=
  (∀ v p, s.cache v = some p → p.1 = p.2) ∧
  (∀ p, s.probe0 = some p → s.installing.isSome = true ∧ p ≤ s.dep) ∧
  (∀ j, s.stageJs = some j → ∃ p, s.probe0 = some p ∧ p ≤ j ∧ j ≤ s.dep) ∧
  (∀ w, s.stageWasm = some w → ∃ p, s.probe0 = some p ∧ p ≤ w ∧ w ≤ s.dep) ∧
  s.mixedBoot = false

def CInv (s : State) : Prop := CS s ∧ ∀ t, (s.tabs t).force = false

theorem cinv_init : CInv init := by
  refine ⟨⟨?_, ?_, ?_, ?_, ?_⟩, ?_⟩ <;> simp [init]

/-- A step that leaves the cache, the install and dep alone, and keeps `force`. -/
theorem cinv_frame {s s' : State} (h : CInv s) (ec : s'.cache = s.cache)
    (ep : s'.probe0 = s.probe0) (ej : s'.stageJs = s.stageJs) (ew : s'.stageWasm = s.stageWasm)
    (ei : s'.installing = s.installing) (ed : s'.dep = s.dep) (em : s'.mixedBoot = s.mixedBoot)
    (ef : ∀ u, (s'.tabs u).force = (s.tabs u).force) : CInv s' := by
  obtain ⟨⟨a1, a2, a3, a4, a5⟩, b⟩ := h
  refine ⟨⟨?_, ?_, ?_, ?_, ?_⟩, fun u => ?_⟩
  · rw [ec]; exact a1
  · rw [ep, ei, ed]; exact a2
  · rw [ej, ep, ed]; exact a3
  · rw [ew, ep, ed]; exact a4
  · rw [em]; exact a5
  · rw [ef]; exact b u

theorem cinv_updT {s : State} (h : CInv s) (t : Bool) (f : Tab → Tab)
    (hf : ∀ x, (f x).force = x.force) : CInv (updT t f s) :=
  cinv_frame h rfl rfl rfl rfl rfl rfl rfl (fun u => by simp only [updT_tabs]; split <;> simp [hf])

macro "c_upd" h:term : tactic =>
  `(tactic| ((try simp only [step]); apply cinv_updT; all_goals first | exact $h | (intro _; rfl)))

theorem cinv_showBtn {s : State} (h : CInv s) (t : Bool) (v : Nat) : CInv (showBtn t v s) := by
  simp only [showBtn]
  apply cinv_updT
  · exact h
  · intro _; rfl

/-- Nothing installing: no probe and nothing staged. -/
theorem cinv_clearInstall {s s' : State} (h : CInv s) (ec : s'.cache = s.cache)
    (ep : s'.probe0 = none) (ej : s'.stageJs = none) (ew : s'.stageWasm = none)
    (em : s'.mixedBoot = s.mixedBoot)
    (ef : ∀ u, (s'.tabs u).force = (s.tabs u).force) : CInv s' := by
  obtain ⟨⟨a1, _, _, _, a5⟩, b⟩ := h
  refine ⟨⟨?_, ?_, ?_, ?_, ?_⟩, fun u => ?_⟩
  · rw [ec]; exact a1
  · intro p hp; rw [ep] at hp; cases hp
  · intro j hj; rw [ej] at hj; cases hj
  · intro w hw; rw [ew] at hw; cases hw
  · rw [em]; exact a5
  · rw [ef]; exact b u

theorem serve_consistent {s : State} (h : CS s) : (serve s).2.1 = (serve s).2.2 := by
  obtain ⟨a1, _, _, _, _⟩ := h
  unfold serve
  cases ha : s.active with
  | none => rfl
  | some v =>
    simp only []
    cases hc : s.cache v with
    | none => rfl
    | some p => exact a1 v p hc

theorem cinv_reload {s : State} (h : CInv s) (t : Bool) (auto : Bool) : CInv (reload t auto s) := by
  obtain ⟨⟨a1, a2, a3, a4, a5⟩, b⟩ := h
  have hs := serve_consistent ⟨a1, a2, a3, a4, a5⟩
  unfold reload
  simp only []
  generalize serve s = sv at hs ⊢
  obtain ⟨c, p⟩ := sv
  simp only at hs ⊢
  refine ⟨⟨a1, a2, a3, a4, ?_⟩, fun u => ?_⟩
  · simp [a5, hs]
  · simp only [updT_tabs]; split
    · cases c <;> rfl
    · exact b u

theorem cinv_activate {s : State} (h : CInv s) (v : Nat) : CInv (activate v s) := by
  obtain ⟨⟨a1, a2, a3, a4, a5⟩, b⟩ := h
  refine ⟨⟨fun u p hp => ?_, a2, a3, a4, a5⟩, fun u => b u⟩
  simp only [activate, mapTabs_cache] at hp
  split at hp
  · exact a1 u p hp
  · cases hp

theorem cinv_updCheck {s : State} (h : CInv s) : CInv (updCheck s) := by
  unfold updCheck; split
  · exact cinv_clearInstall h rfl rfl rfl rfl rfl (fun _ => rfl)
  · exact h

theorem cinv_installFailed {s : State} (h : CInv s) (v : Nat) : CInv (installFailed v s) :=
  cinv_clearInstall h rfl rfl rfl rfl rfl
    (fun u => by simp only [installFailed_tabs, onRedundant]; split <;> rfl)

theorem cinv_applyStart {s : State} (h : CInv s) (t : Bool) : CInv (applyStart t s) := by
  unfold applyStart
  have h1 : CInv (updT t (fun x => { x with appUpdating := true, modal := false })
      { s with intents := s.intents + 1 }) := by
    apply cinv_updT
    · exact h
    · intro _; rfl
  simp only []
  split
  · exact cinv_reload h1 t true
  · split
    · apply cinv_updT (cinv_updCheck h1); intro _; rfl
    · apply cinv_updT h1; intro _; rfl

theorem cinv_step {s : State} {e : Event} (h : CInv s) (he : en s e = true) (hb : benignC e = true) :
    CInv (step s e) := by
  have hs := h
  obtain ⟨⟨a1, a2, a3, a4, a5⟩, b⟩ := h
  cases e with
  | deploy =>
    -- dep only grows: every bound stays a bound
    refine ⟨⟨a1, fun p hp => ?_, fun j hj => ?_, fun w hw => ?_, a5⟩, b⟩
    · have := a2 p hp; exact ⟨this.1, by simp only [step]; omega⟩
    · obtain ⟨p, h1, h2, h3⟩ := a3 j hj; exact ⟨p, h1, h2, by simp only [step]; omega⟩
    · obtain ⟨p, h1, h2, h3⟩ := a4 w hw; exact ⟨p, h1, h2, by simp only [step]; omega⟩
  | browserCheck => exact cinv_updCheck hs
  | probeFirst =>
    have hi : s.installing.isSome = true := by simp only [en, Bool.and_eq_true] at he; exact he.1
    have hp0 : s.probe0 = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.2
    refine ⟨⟨a1, fun p hp => ?_, fun j hj => ?_, fun w hw => ?_, a5⟩, b⟩
    · simp only [step, Option.some.injEq] at hp; subst hp; exact ⟨hi, Nat.le_refl _⟩
    · obtain ⟨p, h1, _⟩ := a3 j hj; rw [hp0] at h1; cases h1
    · obtain ⟨p, h1, _⟩ := a4 w hw; rw [hp0] at h1; cases h1
  | fetchJs =>
    have hp : s.probe0.isSome = true := by
      simp only [en, Bool.and_eq_true] at he; exact he.1.2
    obtain ⟨p, hp⟩ := Option.isSome_iff_exists.mp hp
    refine ⟨⟨a1, a2, fun j hj => ?_, a4, a5⟩, b⟩
    simp only [step, Option.some.injEq] at hj; subst hj
    exact ⟨p, hp, (a2 p hp).2, Nat.le_refl _⟩
  | fetchWasm =>
    have hp : s.probe0.isSome = true := by
      simp only [en, Bool.and_eq_true] at he; exact he.1.2
    obtain ⟨p, hp⟩ := Option.isSome_iff_exists.mp hp
    refine ⟨⟨a1, a2, a3, fun w hw => ?_, a5⟩, b⟩
    simp only [step, Option.some.injEq] at hw; subst hw
    exact ⟨p, hp, (a2 p hp).2, Nat.le_refl _⟩
  | installEnd =>
    simp only [step]
    split
    · rename_i v p j w _ hp hj hw
      split
      · rename_i hok
        simp only [Bool.and_eq_true, beq_iff_eq] at hok
        obtain ⟨⟨hjp, hdp⟩, _⟩ := hok
        -- em.wasm's build is between the two probes, which agree
        have ew : w = j := by
          obtain ⟨p', hp', h1, h2⟩ := a4 w hw
          rw [hp] at hp'; cases hp'
          omega
        have c0 : ∀ u q, (if u = v then some (j, w) else s.cache u) = some q → q.1 = q.2 := by
          intro u q hq; split at hq
          · cases hq; simp [ew]
          · exact a1 u q hq
        have bt : ∀ u, (onInstalled v (s.tabs u)).force = false := by
          intro u; unfold onInstalled; simp only []; split <;> split <;> exact b u
        have base : CInv (mapTabs (onInstalled v) { s with
            cache := fun u => if u = v then some (j, w) else s.cache u, installing := none,
            probe0 := none, stageJs := none, stageWasm := none }) :=
          ⟨⟨c0, fun _ h => by simp [mapTabs] at h, fun _ h => by simp [mapTabs] at h,
            fun _ h => by simp [mapTabs] at h, a5⟩, bt⟩
        have act := cinv_activate base v
        split
        · split
          · exact act
          · exact base
        · split
          · exact act
          · exact base
      · exact cinv_installFailed hs v
    · exact hs
  | installFail =>
    simp only [step]; split
    · exact cinv_installFailed hs _
    · exact hs
  | regResolve t =>
    have h1 := cinv_updT hs t (fun x => { x with regd := true }) (fun _ => rfl)
    simp only [step]; split
    · exact cinv_showBtn h1 t _
    · split
      · exact cinv_clearInstall h1 rfl rfl rfl rfl rfl (fun _ => rfl)
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
    · split
      · exact cinv_reload h1 t true
      · have h2 := cinv_updT h1 t (fun x => { x with ready := true, hadController := true })
          (fun _ => rfl)
        split
        · exact cinv_showBtn h2 t _
        · exact h2
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
    · exact cinv_updT (s := { s with skipQ := some _ }) hs t _ (fun _ => rfl)
    · c_upd hs
    · c_upd hs
  | resetFire t =>
    simp only [step]
    apply cinv_reload
    exact ⟨⟨fun _ _ h => by simp at h, fun _ h => by simp at h, fun _ h => by simp at h,
      fun _ h => by simp at h, a5⟩, b⟩
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
  | rProbe0 | rFetchJs | rFetchWasm | rVerify | rPutJs | rPutWasm =>
    simp [en, anyForce, b] at he
  | forceDone t => simp [en, b] at he

theorem cinv_reach3 {s : State} (h : Reach3 s) : CInv s := by
  induction h with
  | init => exact cinv_init
  | step e _ he hb ih => exact cinv_step ih he hb

/-- Without Force update, no page ever boots index.js and em.wasm from
    different builds, however deploys interleave with installs. (With Force
    update: `bug_force_update_serves_half_written_cache`.) -/
theorem no_mixed_boot_without_force {s : State} (h : Reach3 s) : s.mixedBoot = false :=
  (cinv_reach3 h).1.2.2.2.2

/-! ### Force update only commits one build -/

def RI (s : State) : Prop :=
  (∀ p, s.rProbe = some p → p ≤ s.dep) ∧
  (∀ j, s.rsJs = some j → ∃ p, s.rProbe = some p ∧ p ≤ j ∧ j ≤ s.dep) ∧
  (∀ w, s.rsWasm = some w → ∃ p, s.rProbe = some p ∧ p ≤ w ∧ w ≤ s.dep) ∧
  (s.rOk = true → s.rsJs.isSome = true ∧ s.rsJs = s.rsWasm)

section rproj
variable (s : State) (t : Bool) (f : Tab → Tab) (g : Tab → Tab) (v : Nat) (auto : Bool)
@[simp] theorem updT_r : (updT t f s).rProbe = s.rProbe ∧ (updT t f s).rsJs = s.rsJs ∧
    (updT t f s).rsWasm = s.rsWasm ∧ (updT t f s).rOk = s.rOk := ⟨rfl, rfl, rfl, rfl⟩
@[simp] theorem reload_r : (reload t auto s).rProbe = s.rProbe ∧ (reload t auto s).rsJs = s.rsJs ∧
    (reload t auto s).rsWasm = s.rsWasm ∧ (reload t auto s).rOk = s.rOk ∧
    (reload t auto s).dep = s.dep := ⟨rfl, rfl, rfl, rfl, rfl⟩
@[simp] theorem showBtn_r : (showBtn t v s).rProbe = s.rProbe ∧ (showBtn t v s).rsJs = s.rsJs ∧
    (showBtn t v s).rsWasm = s.rsWasm ∧ (showBtn t v s).rOk = s.rOk ∧
    (showBtn t v s).dep = s.dep := ⟨rfl, rfl, rfl, rfl, rfl⟩
@[simp] theorem mapTabs_r : (mapTabs g s).rProbe = s.rProbe ∧ (mapTabs g s).rsJs = s.rsJs ∧
    (mapTabs g s).rsWasm = s.rsWasm ∧ (mapTabs g s).rOk = s.rOk ∧
    (mapTabs g s).dep = s.dep := ⟨rfl, rfl, rfl, rfl, rfl⟩
@[simp] theorem activate_r : (activate v s).rProbe = s.rProbe ∧ (activate v s).rsJs = s.rsJs ∧
    (activate v s).rsWasm = s.rsWasm ∧ (activate v s).rOk = s.rOk ∧
    (activate v s).dep = s.dep := ⟨rfl, rfl, rfl, rfl, rfl⟩
@[simp] theorem installFailed_r : (installFailed v s).rProbe = s.rProbe ∧
    (installFailed v s).rsJs = s.rsJs ∧ (installFailed v s).rsWasm = s.rsWasm ∧
    (installFailed v s).rOk = s.rOk ∧ (installFailed v s).dep = s.dep := ⟨rfl, rfl, rfl, rfl, rfl⟩
@[simp] theorem updCheck_r : (updCheck s).rProbe = s.rProbe ∧ (updCheck s).rsJs = s.rsJs ∧
    (updCheck s).rsWasm = s.rsWasm ∧ (updCheck s).rOk = s.rOk ∧ (updCheck s).dep = s.dep := by
  unfold updCheck; split <;> exact ⟨rfl, rfl, rfl, rfl, rfl⟩
@[simp] theorem applyStart_r : (applyStart t s).rProbe = s.rProbe ∧ (applyStart t s).rsJs = s.rsJs ∧
    (applyStart t s).rsWasm = s.rsWasm ∧ (applyStart t s).rOk = s.rOk ∧
    (applyStart t s).dep = s.dep := by
  unfold applyStart; simp only []; (repeat' split) <;> simp
end rproj

theorem ri_frame {s s' : State} (h : RI s) (e1 : s'.rProbe = s.rProbe) (e2 : s'.rsJs = s.rsJs)
    (e3 : s'.rsWasm = s.rsWasm) (e4 : s'.rOk = s.rOk) (e5 : s'.dep = s.dep) : RI s' := by
  obtain ⟨a1, a2, a3, a4⟩ := h
  refine ⟨?_, ?_, ?_, ?_⟩ <;> simp only [e1, e2, e3, e4, e5] <;> assumption

theorem ri_step {s : State} {e : Event} (h : RI s) (he : en s e = true) : RI (step s e) := by
  have hs := h
  obtain ⟨a1, a2, a3, a4⟩ := h
  cases e with
  | deploy =>
    refine ⟨fun p hp => ?_, fun j hj => ?_, fun w hw => ?_, a4⟩
    · have := a1 p hp; simp only [step]; omega
    · obtain ⟨p, q1, q2, q3⟩ := a2 j hj; exact ⟨p, q1, q2, by simp only [step]; omega⟩
    · obtain ⟨p, q1, q2, q3⟩ := a3 w hw; exact ⟨p, q1, q2, by simp only [step]; omega⟩
  | forceStart t =>
    refine ⟨fun p hp => ?_, fun j hj => ?_, fun w hw => ?_, fun ho => ?_⟩ <;> simp_all [step]
  | rProbe0 =>
    have hn : s.rProbe = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.2
    refine ⟨fun p hp => ?_, fun j hj => ?_, fun w hw => ?_, fun ho => ?_⟩
    · simp only [step, Option.some.injEq] at hp ⊢; omega
    · obtain ⟨p, q1, _⟩ := a2 j hj; rw [hn] at q1; cases q1
    · obtain ⟨p, q1, _⟩ := a3 w hw; rw [hn] at q1; cases q1
    · obtain ⟨q1, _⟩ := a4 ho
      obtain ⟨j, hj⟩ := Option.isSome_iff_exists.mp q1
      obtain ⟨p, q1, _⟩ := a2 j hj; rw [hn] at q1; cases q1
  | rFetchJs =>
    have hp : s.rProbe.isSome = true := by
      simp only [en, Bool.and_eq_true] at he; exact he.1.2
    have hn : s.rsJs = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.2
    obtain ⟨p, hp⟩ := Option.isSome_iff_exists.mp hp
    refine ⟨a1, fun j hj => ?_, a3, fun ho => ?_⟩
    · simp only [step, Option.some.injEq] at hj; subst hj
      exact ⟨p, hp, a1 p hp, Nat.le_refl _⟩
    · have := (a4 ho).1; rw [hn] at this; cases this
  | rFetchWasm =>
    have hp : s.rProbe.isSome = true := by
      simp only [en, Bool.and_eq_true] at he; exact he.1.2
    have hn : s.rsWasm = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.2
    obtain ⟨p, hp⟩ := Option.isSome_iff_exists.mp hp
    refine ⟨a1, a2, fun w hw => ?_, fun ho => ?_⟩
    · simp only [step, Option.some.injEq] at hw; subst hw
      exact ⟨p, hp, a1 p hp, Nat.le_refl _⟩
    · obtain ⟨q1, q2⟩ := a4 ho
      rw [hn] at q2; rw [q2] at q1; cases q1
  | rVerify =>
    refine ⟨a1, a2, a3, fun _ => ?_⟩
    simp only [en, Bool.and_eq_true] at he
    obtain ⟨_, hm⟩ := he
    simp only [step]
    revert hm
    rcases hp : s.rProbe with _ | p <;> rcases hj : s.rsJs with _ | j <;>
      rcases hw : s.rsWasm with _ | w <;> simp
    intro hjp hdp
    obtain ⟨p', q1, q2, q3⟩ := a3 w hw
    rw [hp] at q1; cases q1
    omega
  | _ =>
    apply ri_frame hs <;> simp only [step] <;> (repeat' split) <;> simp

theorem ri_reachable {s : State} (h : Reachable s) : RI s := by
  induction h with
  | init => refine ⟨?_, ?_, ?_, ?_⟩ <;> simp [init]
  | step e _ he ih => exact ri_step ih he

/-- A Force update's download only reaches the live cache as one build: once
    it passes its check, what is staged for index.js and for em.wasm is the
    same build, even when deploys landed during the download. (Its commit is
    still two puts: `bug_force_update_serves_half_written_cache`.) -/
theorem force_stage_one_build {s : State} (h : Reachable s) (ho : s.rOk = true) :
    s.rsJs.isSome = true ∧ s.rsJs = s.rsWasm :=
  (ri_reachable h).2.2.2 ho

end WebState.ServiceWorker
