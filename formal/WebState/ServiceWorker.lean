-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/index.js: applyUpdate checkForUpdate fullResetReload maybeCheckForUpdate probeBuilds refuseState registerServiceWorker showUpdateButton updateForNewerState on:visibilitychange
-- @models web/sw.js: hex digest fetchManifest fetchFresh verified heldCopy collect commit collectDev install reinstall on:activate on:fetch on:install on:message

/-
# Service worker, update check and update flow (web/sw.js, web/index.js)

Brought to the sw-dedupe design (branch sw-dedupe, on e3dbc604): line
numbers are at that branch's sw.js and index.js. The update flow is the one
5901c517 fixed (the `regress_*` theorems below), with the update a too-new
save state asks for (df47a452) and e3dbc604's registration timing.

## The two install designs, side by side

A worker's install runs the code of its own build, so a browser holds
workers of both designs while the change rolls out. `Env.N` is the first
build with the manifest; builds below it are *old*, the rest *new*. The page
side (`skipWaiting`, the `reinstall`/`reinstalled` messages, controllerchange,
checkForUpdate's regex on `CACHE_VERSION = "..."`) is the same in both, so
an old page under a new worker and a new page under an old worker run the
same protocol; the model's pages are build-agnostic and every pairing is
reachable (`old_page_force_under_new_worker`,
`old_worker_force_then_new_worker_reuses`).

*Old* (origin/main's sw.js): `installAssets` probes version.txt under a URL
no edge has seen, fetches every asset under `?v=<CACHE_VERSION>` with
`cache: "reload"`, then checks the cached version.txt and a second probe;
unless all three name CACHE_VERSION the install fails. Its correctness rests
on fresh URLs reaching the origin's current build (`fetchJs`/`fetchWasm`
read `dep`) and on deploys only moving forward. Force update (`reinstall`)
is the same bracketed download into a staging cache, then one put per asset
into the live cache.

*New* (sw.js 34-176): `install` (163) fetches asset-manifest.json fresh
(`fetchManifest` 52; refused unless its version is CACHE_VERSION), then
`collect` (110) takes each asset from the first copy whose bytes hash to
the manifest's digest (`heldCopy` 89: every dingbat-* cache, then the HTTP
cache through only-if-cached), else downloads it (`fetchFresh` 70, under
`?v=`) and checks that download too; then `commit` (139) puts them all into
`dingbat-<v>` and checks the cache under that name still holds every one.
Force update (`reinstall` 202) downloads every asset under a nonce, checks
each against the manifest the origin serves now (any build), and puts them
into the live cache one by one.

The registration (index.js `registerServiceWorker` 96): a controlled page
registers at load, an uncontrolled one (a first visit) only once its core is
in (19389), so its HTTP cache holds em.wasm by the time the install looks.

## What is modelled

* A build is a version number; `dep` is what the origin serves now, and a
  deploy bumps it. Two assets stand for all of them: index.js (with
  version.txt) and em.wasm. Their bytes are `Env.C a b`, a parameter: any
  asset may be unchanged between builds (an index.js-only update keeps
  em.wasm's bytes). `Env.H` is the SHA-256 digest, a parameter too; the
  consistency theorems assume it injective (`Injective`), the one
  assumption the new design adds. The manifest of build m lists
  `H (C a m)`.
* Caches hold bytes, per name `dingbat-<v>`, both assets together. The HTTP
  cache holds bytes per asset: a page booted off the network puts index.js
  there and its em.wasm once its core is in (`coreLoaded`); `httpFill`
  puts any older or current build's bytes there at any time (a stale edge,
  another tab), `httpEvict` drops one: what the install finds there is
  anything at all.
* The new install's manifest may come from any build up to `dep` (a stale
  edge cannot make it pass, its version is checked); its downloads may get
  any build up to `dep` (`nNet a b`): the new design's consistency does not
  rest on fresh URLs reaching the origin. Its lookup (`nLook`) is one event
  that reads every cache and the HTTP cache at once; the code reads them one
  `await` apart, so the theorem is about copies held throughout the lookup
  (one that appears mid-lookup can be missed, one that goes can be missed,
  and either way the asset is downloaded, never kept wrong). The code reads
  the caches named when `collect` starts; the model reads those there at the
  lookup (a cache created in between belongs to another install or a
  reinstall).
* `commit`'s puts are one event (`nCommit`) and its presence check another
  (`nCheck`). Another worker's activation (atomic here: `activate`) can land
  between them and delete the cache; then the check fails the install
  (`regress_activation_mid_commit_fails_install`). In a browser the
  activation's `caches.keys()` and its `caches.delete()` are two steps, and
  a commit and check landing between them is not caught: that window is
  not modelled (FINDINGS, 2026-11-09). Nor is the old design's version of
  the race: its `installEnd` writes the cache in one event here, while its
  code puts each asset as it arrives into a Cache handle held across the
  whole download, which an activation anywhere in it orphans.
* Two tabs of the app (`Bool`-indexed), each the current page instance: the
  bytes it booted (`running`), whether it is controlled and by which worker
  version, the index.js flags, and its in-flight continuations.
* `reload t` replaces tab t's page: it boots from the active worker's cache
  (or the network when there is no worker or the entry is missing).

## Abstractions

* `register()`'s promise and the updatefound/statechange listeners: the
  listener is attached when `register()` resolves (`regResolve`); the
  `installed` statechange is a queued event per tab (`instFire`).
* The old `installAssets`'s tail is one event, `installEnd`.
* `fullResetReload`'s four awaits are one event (`resetFire`). Its
  unregister makes the installing worker redundant, which another tab's
  applyUpdate watching it sees (`onRedundant`).
* `update()` rejecting goes to `fullResetReload`. A reinstall that fails
  (a download failing, or one whose bytes do not match) replies ok:false and
  the asking tab takes `fullResetReload` (`rFail`, `rFailed`). Two tabs'
  Force updates share one download (`rProbe`, `rMan`, `rsJs`, ...), run by
  the worker that was active when the last one started (`rW`); its puts go
  to that worker's cache.
* `updateForNewerState` is two events, `newerStart` and `newerApply`.
* A page's own boot off the network is taken as one build (`dep`'s): a site
  without a worker has the same exposure, so it is not the worker's.
* Save flushing on reload is `pagehide`'s; this file only tracks whether a
  tab was reloaded mid-game without its own user having agreed
  (`forcedMidGame`).
* Not modelled: Chromium's reload after Force update can run the index.js
  the page before it ran from its memory cache (same worker, a copy younger
  than its max-age); found in the e2e, and on origin/main's sw.js too.
* Not modelled: a dev build (`CACHE_VERSION === "dev"`, no manifest).

## Results

Proved, for every interleaving and both designs side by side: no tab is
reloaded mid-game unless its own user asked (`no_forced_midgame`); with
nothing asked, no tab is reloaded at all (`no_reload_without_a_click`); the
button shows at most once per page (`shows_at_most_once`); an applyUpdate
watching an install always has that install to wait on
(`watching_has_install`). Without Force update and with H injective, every
cache `dingbat-<v>` holds exactly build v's bytes (`cache_is_its_build`),
however deploys, stale edges, older caches and the HTTP cache interleave
with installs, so no page boots anything but one build
(`no_mixed_boot_without_force`). With Force update, every cache holds
builds' bytes (`cache_holds_builds`) and a reinstall's download only goes
live as one build (`force_stage_one_build`). No double download: a new
install's lookup takes a held copy whenever one has the right bytes
(`lookup_takes_held`), an asset is marked for download only by a lookup that
found none (`net_only_after_a_miss`), and downloaded at most once
(`downloaded_once`). Liveness: from any reachable state with a worker
active, a deploy-free run installs the deployed build whole
(`stable_deploy_installs`). Still refuted: Force update's commit to the
live cache is one put per asset (`bug_force_update_serves_half_written_cache`).
-/
namespace WebState.ServiceWorker

/-! ## The environment: bytes, digests, which builds are new -/

inductive Asset where
  | js    -- index.js (and version.txt)
  | wasm  -- em.wasm
  deriving DecidableEq, Repr

structure Env where
  C : Asset → Nat → Nat   -- asset a's bytes in build b
  H : Nat → Nat           -- SHA-256 of some bytes
  N : Nat                 -- the first build whose sw.js uses the manifest

/-- The assumption the digest check rests on: different bytes, different
    digests. -/
def Injective (f : Nat → Nat) : Prop := ∀ x y, f x = f y → x = y

def Env.newGen (E : Env) (v : Nat) : Bool := decide (E.N ≤ v)
def Env.bytes (E : Env) (b : Nat) : Nat × Nat := (E.C .js b, E.C .wasm b)

def pick : Asset → Nat × Nat → Nat
  | .js, p => p.1
  | .wasm, p => p.2

/-! ## State -/

inductive AK where
  | idle
  | awaitUpdate          -- applyUpdate suspended at `await swRegistration.update()`
  | watch (v : Nat)      -- statechange listener on installing worker v (index.js 266)
  | resetting            -- in fullResetReload
  | done                 -- skipWaiting posted; waiting for controllerchange
  deriving DecidableEq, Repr

structure Chk where
  cur    : Option Nat := none   -- cached version.txt (through the worker)
  latest : Option Nat := none   -- no-store version.txt
  sw     : Option Nat := none   -- CACHE_VERSION in a no-store sw.js
  deriving DecidableEq, Repr

structure Tab where
  running     : Nat × Nat := (0, 0)  -- the bytes (index.js, em.wasm) this page booted
  controlled  : Bool := true         -- navigator.serviceWorker.controller
  ctrlV       : Nat := 0             -- the controller's CACHE_VERSION
  hadController : Bool := true       -- (index.js 130)
  appUpdating : Bool := false        -- (238)
  refreshing  : Bool := false        -- (131)
  ready       : Bool := false        -- updateActivated (241)
  updAvail    : Bool := false        -- updateAvailable / button shown (162)
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
  newer       : Bool := false        -- updateForNewerState between its probe and applyUpdate
  coreIn      : Bool := false        -- the core is in (onRuntimeInitialized, 19389)
  deriving DecidableEq, Repr

/-- A new install's asset: not looked up yet, to download, or in hand. -/
inductive Slot where
  | none
  | net
  | have (x : Nat)
  deriving DecidableEq, Repr

def Slot.isHave : Slot → Bool
  | .have _ => true
  | _ => false

structure State where
  dep        : Nat                    -- the deployed build
  active     : Option Nat             -- registration.active
  waiting    : Option Nat
  installing : Option Nat
  probe0     : Option Nat             -- old install: the first version probe
  stageJs    : Option Nat             -- old install: the build index.js came from
  stageWasm  : Option Nat             -- ... and em.wasm
  man        : Option Nat             -- new install: the manifest it accepted (its build)
  slot       : Asset → Slot           -- new install: each asset's copy
  committed  : Bool                   -- new install: commit's puts done, its check to come
  cache      : Nat → Option (Nat × Nat)  -- dingbat-<v> : (index.js bytes, em.wasm bytes)
  http       : Asset → Option Nat     -- the HTTP cache's copy of each asset
  skipQ      : Option Nat             -- skipWaiting posted to worker v
  rW         : Option Nat             -- the worker running the Force update
  rProbe     : Option Nat             -- old reinstall: the first version probe
  rMan       : Option Nat             -- new reinstall: the manifest's build
  rsJs       : Option Nat             -- reinstall: the build index.js's download came from
  rsWasm     : Option Nat             -- ... and em.wasm's
  rOk        : Bool                   -- reinstall: the download passed its check
  rJs        : Bool                   -- a reinstall has put index.js into the live cache
  rWasm      : Bool                   -- ... and em.wasm
  tabs       : Bool → Tab
  intents    : Nat                    -- ghost: Update / Force update / a newer build's state accepted
  autoReloads : Nat                   -- ghost: reloads the app itself triggered
  forcedMidGame : Bool                -- ghost: a tab reloaded mid-game its user never agreed to
  mixedBoot  : Bool                   -- ghost: a page booted bytes other than the build it booted
                                      --   from (its worker's own, or the deployed one off the network)
  dl         : Nat                    -- ghost: downloads by new installs

/-- Steady state: build 0 deployed, installed, both tabs booted from it. -/
def init (E : Env) : State where
  dep := 0
  active := some 0
  waiting := none
  installing := none
  probe0 := none
  stageJs := none
  stageWasm := none
  man := none
  slot := fun _ => .none
  committed := false
  cache := fun v => if v = 0 then some (E.bytes 0) else none
  http := fun _ => none
  skipQ := none
  rW := none
  rProbe := none
  rMan := none
  rsJs := none
  rsWasm := none
  rOk := false
  rJs := false
  rWasm := false
  tabs := fun _ => { running := E.bytes 0, coreIn := true }
  intents := 0
  autoReloads := 0
  forcedMidGame := false
  mixedBoot := false
  dl := 0

/-- A first visit: build d deployed, no worker, no cache, both tabs booted
    off the network (index.js in the HTTP cache, the core still coming). -/
def initFresh (E : Env) (d : Nat) : State :=
  { init E with
    dep := d, active := none, cache := fun _ => none,
    http := fun a => if a = .js then some (E.C .js d) else none,
    tabs := fun _ => { running := E.bytes d, controlled := false, ctrlV := 0, hadController := false } }

def updT (t : Bool) (f : Tab → Tab) (s : State) : State :=
  { s with tabs := fun u => if u = t then f (s.tabs u) else s.tabs u }

def setSlot (f : Asset → Slot) (a : Asset) (y : Slot) : Asset → Slot :=
  fun b => if b = a then y else f b

def setHttp (f : Asset → Option Nat) (a : Asset) (x : Option Nat) : Asset → Option Nat :=
  fun b => if b = a then x else f b

/-- showUpdateButton (161). -/
def showBtn (t : Bool) (v : Nat) (s : State) : State :=
  updT t (fun x => { x with updAvail := true, promptV := some v,
                             shows := if x.updAvail then x.shows else x.shows + 1 }) s

/-- What a page boots with: (controller, the build it boots from, the bytes):
    the active worker's cache, else the network (sw.js 268, the fallback). -/
def serve (E : Env) (s : State) : Option Nat × Nat × (Nat × Nat) :=
  match s.active with
  | some v => match s.cache v with
    | some p => (some v, v, p)
    | none => (some v, s.dep, E.bytes s.dep)
  | none => (none, s.dep, E.bytes s.dep)

/-- A page (re)load of tab t. `auto`: the app called location.reload(). A
    page off the network leaves its index.js in the HTTP cache. -/
def reload (E : Env) (t : Bool) (auto : Bool) (s : State) : State :=
  let x := s.tabs t
  match serve E s with
  | (c, b, p) =>
    let s := { s with
      forcedMidGame := s.forcedMidGame || (auto && x.game && !x.appUpdating),
      mixedBoot := s.mixedBoot || p != E.bytes b,
      autoReloads := if auto then s.autoReloads + 1 else s.autoReloads,
      http := match c with | none => setHttp s.http .js (some p.1) | some _ => s.http }
    updT t (fun _ => match c with
      | some v => { running := p, controlled := true, ctrlV := v, hadController := true }
      | none => { running := p, controlled := false, ctrlV := 0, hadController := false }) s

/-- clients.claim(): the tab is now controlled by worker v; controllerchange queued. -/
def claim (v : Nat) (x : Tab) : Tab := { x with controlled := true, ctrlV := v, ccQ := true }

/-- The `installed` statechange reaches a page that attached the listener; an
    applyUpdate watching worker v then posts skipWaiting (268). -/
def onInstalled (v : Nat) (x : Tab) : Tab :=
  let x := if x.regd then { x with instQ := some v } else x
  if x.applyK == .watch v then { x with applyK := .done } else x

/-- The `redundant` statechange: an applyUpdate watching worker v falls back to
    fullResetReload (272). -/
def onRedundant (v : Nat) (x : Tab) : Tab :=
  if x.applyK == .watch v then { x with applyK := .resetting } else x

def mapTabs (g : Tab → Tab) (s : State) : State := { s with tabs := fun u => g (s.tabs u) }

/-- activate (sw.js 178): delete the other caches, claim every tab. -/
def activate (v : Nat) (s : State) : State :=
  mapTabs (claim v)
    { s with active := some v,
             waiting := if s.waiting = some v then none else s.waiting,
             cache := fun u => if u = v then s.cache u else none }

/-- Nothing installing, nothing staged. -/
def clearInst (s : State) : State :=
  { s with installing := none, probe0 := none, stageJs := none, stageWasm := none,
           man := none, slot := fun _ => .none, committed := false }

/-- An install of the deployed build starts. -/
def startInst (s : State) : State := { clearInst s with installing := some s.dep }

/-- A browser update check (navigation, periodic, or reg.update()): a changed
    sw.js starts an install. -/
def updCheck (s : State) : State :=
  if s.installing.isNone && s.active.isSome && s.active != some s.dep && s.waiting != some s.dep then
    startInst s
  else s

/-- The install fails: the worker is redundant. -/
def installFailed (v : Nat) (s : State) : State := mapTabs (onRedundant v) (clearInst s)

/-- The install of v succeeded: `installed`; with no active worker it
    activates at once (a first install), else it waits. -/
def installed (v : Nat) (s : State) : State :=
  let anyWatch := (s.tabs true).applyK == .watch v || (s.tabs false).applyK == .watch v
  let s := mapTabs (onInstalled v) (clearInst s)
  let s := match s.active with
    | none => activate v s
    | some _ => { s with waiting := some v }
  if anyWatch then { s with skipQ := some v } else s

/-- The first copy of asset a already on the device whose bytes hash to
    build m's digest: a dingbat-* cache's (any build's, any layout), then the
    HTTP cache's (heldCopy, sw.js 89). Caches exist only for deployed
    builds (`bounds_reachable`), so builds up to `dep` are all of them. -/
def heldBytes (E : Env) (s : State) (a : Asset) (m : Nat) : Option Nat :=
  let ok := fun x => E.H x == E.H (E.C a m)
  match ((List.range (s.dep + 1)).filterMap (fun u => (s.cache u).map (pick a))).find? ok with
  | some x => some x
  | none => match s.http a with
    | some x => if ok x then some x else none
    | none => none

def oldInst (E : Env) (s : State) : Bool :=
  match s.installing with | some v => !E.newGen v | none => false
def newInst (E : Env) (s : State) : Bool :=
  match s.installing with | some v => E.newGen v | none => false
def oldR (E : Env) (s : State) : Bool :=
  match s.rW with | some w => !E.newGen w | none => false
def newR (E : Env) (s : State) : Bool :=
  match s.rW with | some w => E.newGen w | none => false

def staged (s : State) : Asset → Option Nat
  | .js => s.rsJs
  | .wasm => s.rsWasm

def setStaged (s : State) (a : Asset) (b : Nat) : State :=
  match a with
  | .js => { s with rsJs := some b }
  | .wasm => { s with rsWasm := some b }

def rClear (s : State) : State :=
  { s with rProbe := none, rMan := none, rsJs := none, rsWasm := none,
           rOk := false, rJs := false, rWasm := false }

/-- A reinstall fails: the "reinstalled" ok:false reply sends every tab
    waiting on it into fullResetReload (index.js 324-329). -/
def rFailed (s : State) : State :=
  mapTabs (fun x => if x.force then { x with force := false, applyK := .resetting } else x) (rClear s)

inductive Event where
  | deploy
  | browserCheck                 -- the browser re-fetches sw.js
  | probeFirst                   -- old install: the first probeVersion()
  | fetchJs                      -- old install: index.js?v= arrives (from the origin)
  | fetchWasm                    -- ... em.wasm?v=
  | installEnd                   -- old install's tail: version.txt check, second probe
  | installFail                  -- an asset fetch failed: worker redundant
  | nManifest (b : Nat)          -- new install: fetchManifest gets build b's manifest (52-63)
  | nLook (a : Asset)            -- new install: heldCopy for asset a (89-104)
  | nNet (a : Asset) (b : Nat)   -- new install: a's download (?v=) answers build b's bytes (124-127)
  | nCommit                      -- new install: commit's puts (140-141)
  | nCheck                       -- new install: commit's presence check (142-144)
  | regResolve (t : Bool)        -- register().then (99)
  | coreLoaded (t : Bool)        -- the core is in (19389): an uncontrolled page registers now
  | httpFill (a : Asset) (b : Nat) -- the HTTP cache gets build b's copy of a
  | httpEvict (a : Asset)
  | instFire (t : Bool)          -- the queued `installed` statechange (104)
  | skipDeliver                  -- the waiting worker handles skipWaiting and activates
  | ccFire (t : Bool)            -- controllerchange handler (132)
  | userReload (t : Bool)        -- the user reloads / reopens the tab
  | gameOn (t : Bool) | gameOff (t : Bool)
  | updClick (t : Bool)          -- #update-btn (288)
  | confirm (t : Bool)           -- #update-confirm (297)
  | notNow (t : Bool)
  | applyResume (t : Bool)       -- applyUpdate after `await update()` (257)
  | resetFire (t : Bool)         -- fullResetReload (224)
  | checkStart (t : Bool)        -- maybeCheckForUpdate at load / visibilitychange (203)
  | chkCur (t : Bool) | chkLatest (t : Bool) | chkSw (t : Bool)  -- the three fetches land
  | chkEval (t : Bool)           -- the rest of checkForUpdate
  | forceStart (t : Bool)        -- Force update, confirmed (forceUpdate 308)
  | rProbe0                      -- old reinstall: the first probe
  | rFetchJs | rFetchWasm        -- old reinstall: one asset into the staging cache
  | rMan (b : Nat)               -- new reinstall: the deployed manifest (build b's)
  | rNet (a : Asset) (b : Nat)   -- new reinstall: a's download answers build b's bytes
  | rVerify                      -- reinstall: the download passed its check
  | rPutJs | rPutWasm            -- reinstall: one put into the worker's live cache (sw.js 207)
  | rFail                        -- reinstall: a download failed: ok:false
  | forceDone (t : Bool)         -- "reinstalled" ok: location.reload()
  | newerStart (t : Bool)        -- a too-new state refused; updateForNewerState passes its checks
  | newerApply (t : Bool)        -- ...its awaits done: applyUpdate()
  deriving DecidableEq, Repr

def anyForce (s : State) : Bool := (s.tabs true).force || (s.tabs false).force

def en (E : Env) (s : State) : Event → Bool
  | .deploy => true
  | .browserCheck => true
  | .probeFirst => oldInst E s && s.probe0.isNone
  | .fetchJs => oldInst E s && s.probe0.isSome && s.stageJs.isNone
  | .fetchWasm => oldInst E s && s.probe0.isSome && s.stageWasm.isNone
  | .installEnd => oldInst E s && s.stageJs.isSome && s.stageWasm.isSome
  | .installFail => s.installing.isSome
  | .nManifest b => newInst E s && s.man.isNone && decide (b ≤ s.dep)
  | .nLook a => newInst E s && s.man.isSome && s.slot a == .none
  | .nNet a b => newInst E s && s.man.isSome && s.slot a == .net && decide (b ≤ s.dep)
  | .nCommit => newInst E s && (s.slot .js).isHave && (s.slot .wasm).isHave && !s.committed
  | .nCheck => newInst E s && s.committed
  | .regResolve t => !(s.tabs t).regd && ((s.tabs t).controlled || (s.tabs t).coreIn)
  | .coreLoaded t => !(s.tabs t).coreIn
  | .httpFill _ b => decide (b ≤ s.dep)
  | .httpEvict _ => true
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
  | .rProbe0 => anyForce s && oldR E s && s.rProbe.isNone
  | .rFetchJs => anyForce s && oldR E s && s.rProbe.isSome && s.rsJs.isNone
  | .rFetchWasm => anyForce s && oldR E s && s.rProbe.isSome && s.rsWasm.isNone
  | .rMan b => anyForce s && newR E s && s.rMan.isNone && decide (b ≤ s.dep)
  | .rNet a b => anyForce s && newR E s && s.rMan.isSome && (staged s a).isNone && decide (b ≤ s.dep)
  | .rVerify => anyForce s && !s.rOk &&
      (if oldR E s then
        (match s.rProbe, s.rsJs, s.rsWasm with
         | some p, some j, some _ => j == p && s.dep == p
         | _, _, _ => false)
      else newR E s && s.rMan.isSome && s.rsJs.isSome && s.rsWasm.isSome)
  | .rPutJs => anyForce s && s.rOk && !s.rJs
  | .rPutWasm => anyForce s && s.rOk && !s.rWasm
  | .rFail => anyForce s
  | .forceDone t => (s.tabs t).force && s.rJs && s.rWasm
  | .newerStart t => (s.tabs t).game && !(s.tabs t).appUpdating && !(s.tabs t).newer
  | .newerApply t => (s.tabs t).newer

/-- applyUpdate (243), first segment: flags, close the modal; then either the
    reload another tab's update left waiting (251), or `update()`. -/
def applyStart (E : Env) (t : Bool) (s : State) : State :=
  let x := s.tabs t
  let s := { s with intents := s.intents + 1 }
  let s := updT t (fun x => { x with appUpdating := true, modal := false }) s
  if x.ready then reload E t true s
  else if x.regd then updT t (fun x => { x with applyK := .awaitUpdate }) (updCheck s)
  else updT t (fun x => { x with applyK := .resetting }) s

/-- fullResetReload's unregister: the installing worker goes redundant. -/
def redund (s : State) : State :=
  match s.installing with
  | some v => mapTabs (onRedundant v) s
  | none => s

def step (E : Env) (s : State) : Event → State
  | .deploy => { s with dep := s.dep + 1 }
  | .browserCheck => updCheck s
  | .probeFirst => { s with probe0 := some s.dep }
  -- old fetchAndCache: `?v=<CACHE_VERSION>` is a fresh URL; the origin
  -- answers with whatever is deployed at that moment
  | .fetchJs => { s with stageJs := some s.dep }
  | .fetchWasm => { s with stageWasm := some s.dep }
  | .installEnd =>
    match s.installing, s.probe0, s.stageJs, s.stageWasm with
    | some v, some p, some j, some w =>
      -- old installAssets: the first probe named this worker's build, and
      -- the cached version.txt and the second probe agree with it
      if j == p && s.dep == p && p == v then
        installed v { s with cache := fun u => if u = v then some (E.C .js j, E.C .wasm w) else s.cache u }
      else installFailed v s
    | _, _, _, _ => s
  | .installFail =>
    match s.installing with
    | some v => installFailed v s
    | none => s
  -- fetchManifest(CACHE_VERSION) (52-63): refused unless it is this build's
  | .nManifest b =>
    match s.installing with
    | some v => if b == v then { s with man := some b } else installFailed v s
    | none => s
  -- heldCopy (89-104): the first held copy with the manifest's digest, else
  -- to download
  | .nLook a =>
    match s.man with
    | some m => match heldBytes E s a m with
      | some x => { s with slot := setSlot s.slot a (.have x) }
      | none => { s with slot := setSlot s.slot a .net }
    | none => s
  -- collect (124-127): the download, checked; a mismatch throws
  | .nNet a b =>
    match s.installing, s.man with
    | some v, some m =>
      let s := { s with dl := s.dl + 1 }
      if E.H (E.C a b) == E.H (E.C a m) then { s with slot := setSlot s.slot a (.have (E.C a b)) }
      else installFailed v s
    | _, _ => s
  -- commit (139-141): caches.open(name) and the puts
  | .nCommit =>
    match s.installing, s.slot .js, s.slot .wasm with
    | some v, .have xj, .have xw =>
      { s with cache := fun u => if u = v then some (xj, xw) else s.cache u, committed := true }
    | _, _, _ => s
  -- commit (142-144): the cache under that name still holds them
  | .nCheck =>
    match s.installing with
    | some v => if (s.cache v).isSome then installed v s else installFailed v s
    | none => s
  -- register().then (99): if (reg.waiting) showUpdateButton(); a missing
  -- registration is created and installs
  | .regResolve t =>
    let s := updT t (fun x => { x with regd := true }) s
    match s.waiting with
    | some v => showBtn t v s
    | none => if s.active.isNone && s.installing.isNone then startInst s else s
  -- onRuntimeInitialized: an uncontrolled page's em.wasm is in its HTTP cache
  | .coreLoaded t =>
    let x := s.tabs t
    let s := if x.controlled then s else { s with http := setHttp s.http .wasm (some x.running.2) }
    updT t (fun x => { x with coreIn := true }) s
  | .httpFill a b => { s with http := setHttp s.http a (some (E.C a b)) }
  | .httpEvict a => { s with http := setHttp s.http a none }
  -- statechange (104): sw.state === "installed" (still waiting) && controller
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
  -- controllerchange (132): reload only this tab's own update, or a tab with no
  -- game in progress; else updateActivated + the button
  | .ccFire t =>
    let x := s.tabs t
    let s := updT t (fun x => { x with ccQ := false }) s
    if (x.hadController || x.appUpdating) && !x.refreshing then
      if x.appUpdating || !x.game then reload E t true s
      else
        match s.active with
        | some v => showBtn t v (updT t (fun x => { x with ready := true, hadController := true }) s)
        | none => updT t (fun x => { x with ready := true, hadController := true }) s
    else updT t (fun x => { x with hadController := true }) s
  | .userReload t => reload E t false s
  | .gameOn t => updT t (fun x => { x with game := true }) s
  | .gameOff t => updT t (fun x => { x with game := false }) s
  -- #update-btn (288): a game loaded -> confirm modal, else applyUpdate
  | .updClick t =>
    if (s.tabs t).game then updT t (fun x => { x with modal := true }) s else applyStart E t s
  | .confirm t => applyStart E t s
  | .notNow t => updT t (fun x => { x with modal := false }) s
  -- after `await swRegistration.update()` (257-276)
  | .applyResume t =>
    match s.waiting, s.installing with
    | some v, _ => updT t (fun x => { x with applyK := .done }) { s with skipQ := some v }
    | none, some v => updT t (fun x => { x with applyK := .watch v }) s
    | none, none => updT t (fun x => { x with applyK := .resetting }) s
  -- fullResetReload (224): delete every cache, unregister, reload
  | .resetFire t =>
    reload E t true { clearInst (redund s) with cache := fun _ => none, active := none,
                                                 waiting := none, skipQ := none }
  | .checkStart t => updT t (fun x => { x with chk := some {} }) s
  -- fetch("version.txt"): the controller's own cache (sw.js 268), else network
  | .chkCur t =>
    let x := s.tabs t
    let v := if x.controlled then (match s.cache x.ctrlV with | some p => p.1 | none => s.dep) else s.dep
    updT t (fun x => { x with chk := x.chk.map (fun c => { c with cur := some v }) }) s
  | .chkLatest t => updT t (fun x => { x with chk := x.chk.map (fun c => { c with latest := some s.dep }) }) s
  | .chkSw t => updT t (fun x => { x with chk := x.chk.map (fun c => { c with sw := some s.dep }) }) s
  -- checkForUpdate 188-200: current && latest && latest !== current && deployed === latest -> button
  | .chkEval t =>
    match (s.tabs t).chk with
    | some { cur := some c, latest := some l, sw := some d } =>
      let s := updT t (fun x => { x with chk := none }) s
      if c != l && d == l then showBtn t l s else s
    | _ => s
  -- Force update (308): appUpdating; the live worker re-downloads
  | .forceStart t =>
    updT t (fun x => { x with force := true, appUpdating := true })
      { rClear s with intents := s.intents + 1, rW := s.active }
  | .rProbe0 => { s with rProbe := some s.dep }
  -- old reinstall's download: `?v=<nonce>` reaches the origin
  | .rFetchJs => { s with rsJs := some s.dep }
  | .rFetchWasm => { s with rsWasm := some s.dep }
  | .rMan b => { s with rMan := some b }
  -- new reinstall (collect without reuse): each download checked against
  -- the manifest the origin served
  | .rNet a b =>
    match s.rMan with
    | some m => if E.H (E.C a b) == E.H (E.C a m) then setStaged s a b else rFailed s
    | none => s
  | .rVerify => { s with rOk := true }
  -- reinstall's commit (sw.js 206-207): one cache.put per asset into CACHE_NAME
  | .rPutJs =>
    match s.rW with
    | some w =>
      let j := E.C .js (s.rsJs.getD s.dep)
      let c := fun u => if u = w then some (j, ((s.cache u).map Prod.snd).getD (E.C .wasm s.dep)) else s.cache u
      { s with rJs := true, cache := c }
    | none => s
  | .rPutWasm =>
    match s.rW with
    | some w =>
      let x := E.C .wasm (s.rsWasm.getD s.dep)
      let c := fun u => if u = w then some (((s.cache u).map Prod.fst).getD (E.C .js s.dep), x) else s.cache u
      { s with rWasm := true, cache := c }
    | none => s
  | .rFail => rFailed s
  | .forceDone t => reload E t true (updT t (fun x => { x with force := false }) s)
  -- refuseState (8958) / updateForNewerState (8970): the player's own load is the intent
  | .newerStart t =>
    updT t (fun x => { x with newer := true }) { s with intents := s.intents + 1 }
  | .newerApply t => applyStart E t (updT t (fun x => { x with newer := false }) s)

inductive Reachable (E : Env) : State → Prop
  | init : Reachable E (init E)
  | fresh (d : Nat) : Reachable E (initFresh E d)
  | step {s : State} (e : Event) : Reachable E s → en E s e = true → Reachable E (step E s e)

def run (E : Env) (s : State) : List Event → Option State
  | [] => some s
  | e :: es => if en E s e then run E (step E s e) es else none

theorem run_reachable {E : Env} {s : State} (h : Reachable E s) :
    ∀ {es : List Event} {t : State}, run E s es = some t → Reachable E t := by
  intro es
  induction es generalizing s with
  | nil => intro t ht; simp [run] at ht; subst ht; exact h
  | cons e es ih =>
    intro t ht
    simp only [run] at ht
    split at ht
    · exact ih (Reachable.step e h (by assumption)) ht
    · cases ht

def witnesses (E : Env) (es : List Event) (bad : State → Bool) : Bool :=
  match run E (init E) es with
  | some t => bad t
  | none => false

def witnessesFresh (E : Env) (d : Nat) (es : List Event) (bad : State → Bool) : Bool :=
  match run E (initFresh E d) es with
  | some t => bad t
  | none => false

theorem witness_sound {E : Env} {es : List Event} {bad : State → Bool}
    (h : witnesses E es bad = true) : ∃ s, Reachable E s ∧ bad s = true := by
  unfold witnesses at h
  split at h
  · exact ⟨_, run_reachable Reachable.init (by assumption), h⟩
  · cases h

theorem witnessFresh_sound {E : Env} {d : Nat} {es : List Event} {bad : State → Bool}
    (h : witnessesFresh E d es bad = true) : ∃ s, Reachable E s ∧ bad s = true := by
  unfold witnessesFresh at h
  split at h
  · exact ⟨_, run_reachable (Reachable.fresh d) (by assumption), h⟩
  · cases h

/-! ## Traces

`E0`: build 0 has the old sw.js, every later build the new one (N = 1).
index.js changes in every build, em.wasm every second one (builds 0 and 1
share it, 2 and 3 do). `E1`: every build in these traces is old (N = 10),
for the old design's traces. The digest is the identity: injective. -/

def E0 : Env where
  C := fun a b => match a with | .js => b | .wasm => 100 + b / 2
  H := id
  N := 1

def E1 : Env := { E0 with N := 10 }

/-- Some build up to d has exactly these bytes. -/
def oneBuild (E : Env) (d : Nat) (p : Nat × Nat) : Bool :=
  (List.range (d + 1)).any (fun b => p == E.bytes b)

/-- Was `bug_update_in_one_tab_reloads_the_other_midgame`. Two tabs; the game
    is running in tab B (`true`), tab A (`false`) is on the home screen. A
    deploy (the first new build, under the old worker) lands and the browser
    installs it: em.wasm from build 0's cache, index.js downloaded. Both tabs
    show Update. The user clicks Update in A: no game there, so no confirm,
    and applyUpdate posts skipWaiting. The worker activates and claims *both*
    tabs. B keeps its game, the old page under the new worker, its button
    saying Reload. -/
theorem regress_update_in_one_tab_reloads_the_other_midgame :
    witnesses E0 [.gameOn true, .regResolve false, .regResolve true, .deploy, .browserCheck,
               .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1, .nCommit, .nCheck,
               .instFire false, .updClick false, .applyResume false, .skipDeliver, .ccFire true]
      (fun s => !s.forcedMidGame && (s.tabs true).ready && (s.tabs true).updAvail &&
                (s.tabs true).running == E0.bytes 0 && (s.tabs true).ctrlV == 1) = true := by decide

/-- ...and B's player clicking it, through the confirm, is what reloads B, onto
    the new build: page and worker one build. -/
theorem regress_update_in_one_tab_then_reload_when_ready :
    witnesses E0 [.gameOn true, .regResolve false, .regResolve true, .deploy, .browserCheck,
               .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1, .nCommit, .nCheck,
               .instFire false, .updClick false, .applyResume false, .skipDeliver, .ccFire true,
               .updClick true, .confirm true]
      (fun s => !s.forcedMidGame && (s.tabs true).running == E0.bytes 1 &&
                (s.tabs true).ctrlV == 1) = true := by decide

/-- An old page under an old worker updates to the new build: the new
    worker's install downloads index.js alone (em.wasm is build 0's bytes,
    in build 0's cache), and the page reloads onto build 1 under it. -/
theorem old_to_new_update_downloads_only_what_changed :
    witnesses E0 [.regResolve false, .deploy, .browserCheck, .nManifest 1, .nLook .js,
               .nLook .wasm, .nNet .js 1, .nCommit, .nCheck, .instFire false, .updClick false,
               .applyResume false, .skipDeliver, .ccFire false]
      (fun s => !s.forcedMidGame && !s.mixedBoot && s.dl == 1 &&
                (s.tabs false).running == E0.bytes 1 && (s.tabs false).ctrlV == 1 &&
                s.cache 1 == some (E0.bytes 1) && s.cache 0 == none) = true := by decide

/-- A first visit: the page booted build 1 off the network, its core came,
    and only then it registered; the install takes both assets from the HTTP
    cache and downloads nothing. -/
theorem first_visit_downloads_nothing_twice :
    witnessesFresh E0 1 [.coreLoaded false, .regResolve false, .nManifest 1, .nLook .js,
               .nLook .wasm, .nCommit, .nCheck]
      (fun s => s.dl == 0 && s.active == some 1 && s.cache 1 == some (E0.bytes 1) &&
                (s.tabs false).ccQ) = true := by decide

/-- ...and an uncontrolled page cannot register before its core is in. -/
theorem first_visit_registers_after_the_core :
    run E0 (initFresh E0 1) [.regResolve false] = none := by decide

/-- Was `bug_install_across_deploy_mixes_cache` (the old design, `E1`). The
    install fetches each asset separately, and a deploy landing between two
    of those fetches used to leave `dingbat-<v>` holding index.js from one
    build and em.wasm from another. The second probe sees the deploy and the
    install fails: nothing is cached, and the tab keeps booting the old build. -/
theorem regress_install_across_deploy_mixes_cache :
    witnesses E1 [.regResolve false, .deploy, .browserCheck, .probeFirst, .fetchJs, .deploy,
               .fetchWasm, .installEnd, .userReload false]
      (fun s => !s.mixedBoot && s.waiting.isNone && s.installing.isNone &&
                s.cache 1 == none && (s.tabs false).running == E1.bytes 0) = true := by decide

/-- The old design tries again and, with no deploy inside, installs whole. -/
theorem regress_install_across_deploy_then_retry :
    witnesses E1 [.regResolve false, .deploy, .browserCheck, .probeFirst, .fetchJs, .deploy,
               .fetchWasm, .installEnd, .browserCheck, .probeFirst, .fetchJs, .fetchWasm,
               .installEnd]
      (fun s => s.waiting == some 2 && s.cache 2 == some (E1.bytes 2)) = true := by decide

/-- The same straddle in the new design: build 1's install has em.wasm (build
    0's bytes, held) and is downloading index.js when build 2 deploys; the
    download is build 2's index.js, its digest is not build 1's, and the
    install fails. -/
theorem regress_new_install_across_deploy :
    witnesses E0 [.regResolve false, .deploy, .browserCheck, .nManifest 1, .nLook .js,
               .nLook .wasm, .deploy, .nNet .js 2, .userReload false]
      (fun s => !s.mixedBoot && s.waiting.isNone && s.installing.isNone &&
                s.cache 1 == none && (s.tabs false).running == E0.bytes 0) = true := by decide

/-- ...the retry installs build 2 whole: em.wasm changed too, so both download. -/
theorem regress_new_install_across_deploy_then_retry :
    witnesses E0 [.regResolve false, .deploy, .browserCheck, .nManifest 1, .nLook .js,
               .nLook .wasm, .deploy, .nNet .js 2, .browserCheck, .nManifest 2, .nLook .js,
               .nLook .wasm, .nNet .js 2, .nNet .wasm 2, .nCommit, .nCheck]
      (fun s => s.waiting == some 2 && s.cache 2 == some (E0.bytes 2)) = true := by decide

/-- A stale edge's sw.js names build 1 while the origin is on 2: the manifest
    is refused before anything downloads. -/
theorem stale_worker_refuses_the_manifest :
    witnesses E0 [.deploy, .browserCheck, .deploy, .nManifest 2]
      (fun s => s.installing.isNone && s.dl == 0 && s.cache 1 == none) = true := by decide

/-- Build 1 waits; build 2 installs; the user's Update activates build 1
    between build 2's puts and its check, deleting build 2's cache. The check
    sees it and the install fails, instead of leaving build 2 waiting over an
    empty cache. (The old design had this race across its whole download.) -/
theorem regress_activation_mid_commit_fails_install :
    witnesses E0 [.deploy, .browserCheck, .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1,
               .nCommit, .nCheck, .regResolve false, .deploy, .browserCheck, .nManifest 2,
               .nLook .js, .nLook .wasm, .nNet .js 2, .nNet .wasm 2, .nCommit,
               .updClick false, .applyResume false, .skipDeliver, .nCheck]
      (fun s => s.active == some 1 && s.waiting.isNone && s.installing.isNone &&
                s.cache 2 == none && s.cache 1 == some (E0.bytes 1)) = true := by decide

/-- Force update still commits to the live cache one put per asset. A tab
    booted between the two puts gets the new index.js with the old em.wasm:
    bytes no build has. -/
theorem bug_force_update_serves_half_written_cache :
    witnesses E0 [.deploy, .deploy, .forceStart false, .rProbe0, .rFetchJs, .rFetchWasm, .rVerify,
               .rPutJs, .userReload true]
      (fun s => !oneBuild E0 s.dep (s.tabs true).running) = true := by decide

/-- An old worker's Force update while build 1 is deployed: build 1's bytes go
    into build 0's cache and the page reloads onto them, the new page under the
    old worker. Build 1's worker then installs with nothing to download: every
    asset is in build 0's cache, with build 1's digest. -/
theorem old_worker_force_then_new_worker_reuses :
    witnesses E0 [.regResolve false, .deploy, .forceStart false, .rProbe0, .rFetchJs, .rFetchWasm,
               .rVerify, .rPutJs, .rPutWasm, .forceDone false, .browserCheck, .nManifest 1,
               .nLook .js, .nLook .wasm, .nCommit, .nCheck]
      (fun s => (s.tabs false).running == E0.bytes 1 && (s.tabs false).ctrlV == 0 &&
                s.dl == 0 && s.waiting == some 1 && s.cache 1 == some (E0.bytes 1)) = true := by decide

/-- The old page left under the new worker by another tab's Update (B mid-game)
    asks it for a Force update after build 2 deploys: the new worker's
    reinstall checks each download against build 2's manifest and B reloads
    onto build 2's bytes. -/
theorem old_page_force_under_new_worker :
    witnesses E0 [.gameOn true, .regResolve false, .regResolve true, .deploy, .browserCheck,
               .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1, .nCommit, .nCheck,
               .instFire false, .updClick false, .applyResume false, .skipDeliver, .ccFire true,
               .deploy, .gameOff true, .forceStart true, .rMan 2, .rNet .js 2, .rNet .wasm 2,
               .rVerify, .rPutJs, .rPutWasm, .forceDone true]
      (fun s => !s.forcedMidGame && (s.tabs true).running == E0.bytes 2 &&
                (s.tabs true).ctrlV == 1) = true := by decide

/-- A save state from a newer build loaded in tab B's game while tab A has a
    game too: B reloads onto the new build, A keeps its game, its button
    relabelled Reload. Neither reload is forced. -/
theorem newer_state_update_reloads_only_its_tab :
    witnesses E0 [.gameOn true, .gameOn false, .regResolve true, .regResolve false, .deploy,
               .browserCheck, .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1, .nCommit,
               .nCheck, .newerStart true, .newerApply true, .applyResume true, .skipDeliver,
               .ccFire true, .ccFire false]
      (fun s => !s.forcedMidGame && (s.tabs true).running == E0.bytes 1 &&
                (s.tabs false).ready && (s.tabs false).running == E0.bytes 0) = true := by decide

/-- The old design: a Force update whose download straddles a deploy cannot
    pass its check. -/
theorem regress_force_update_straddle_not_verified :
    run E1 (init E1) [.deploy, .forceStart false, .rProbe0, .rFetchJs, .deploy, .rFetchWasm,
              .rVerify] = none := by decide

/-- The new design: the new worker's Force update reads build 2's manifest,
    then a deploy changes em.wasm and the download is build 4's: it fails
    the check, the reply is ok:false, and the tab takes its full reset. -/
theorem regress_new_force_update_straddle_fails :
    witnesses E0 [.deploy, .browserCheck, .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1,
               .nCommit, .nCheck, .regResolve false, .updClick false, .applyResume false,
               .skipDeliver, .ccFire false, .deploy, .forceStart false, .rMan 2, .rNet .js 2,
               .deploy, .deploy, .rNet .wasm 4]
      (fun s => !anyForce s && (s.tabs false).applyK == .resetting && !s.rOk &&
                s.cache 1 == some (E0.bytes 1)) = true := by decide

/-! ## Invariants that hold -/

section proj
variable (E : Env) (s : State) (t u : Bool) (f g : Tab → Tab) (v : Nat) (auto : Bool)
@[simp] theorem updT_tabs : (updT t f s).tabs u = if u = t then f (s.tabs u) else s.tabs u := rfl
@[simp] theorem mapTabs_tabs : (mapTabs g s).tabs u = g (s.tabs u) := rfl
@[simp] theorem clearInst_tabs : (clearInst s).tabs = s.tabs := rfl
@[simp] theorem rClear_tabs : (rClear s).tabs = s.tabs := rfl
@[simp] theorem startInst_tabs : (startInst s).tabs = s.tabs := rfl
@[simp] theorem updCheck_tabs : (updCheck s).tabs = s.tabs := by unfold updCheck; split <;> rfl
@[simp] theorem activate_tabs : (activate v s).tabs u = claim v (s.tabs u) := rfl
@[simp] theorem setStaged_tabs (a : Asset) (b : Nat) : (setStaged s a b).tabs = s.tabs := by
  cases a <;> rfl
@[simp] theorem updT_dep : (updT t f s).dep = s.dep := rfl
@[simp] theorem mapTabs_dep : (mapTabs g s).dep = s.dep := rfl
@[simp] theorem updT_active : (updT t f s).active = s.active := rfl
@[simp] theorem mapTabs_active : (mapTabs g s).active = s.active := rfl
@[simp] theorem updT_waiting : (updT t f s).waiting = s.waiting := rfl
@[simp] theorem mapTabs_waiting : (mapTabs g s).waiting = s.waiting := rfl
@[simp] theorem updT_installing : (updT t f s).installing = s.installing := rfl
@[simp] theorem mapTabs_installing : (mapTabs g s).installing = s.installing := rfl
@[simp] theorem updT_probe0 : (updT t f s).probe0 = s.probe0 := rfl
@[simp] theorem mapTabs_probe0 : (mapTabs g s).probe0 = s.probe0 := rfl
@[simp] theorem updT_stageJs : (updT t f s).stageJs = s.stageJs := rfl
@[simp] theorem mapTabs_stageJs : (mapTabs g s).stageJs = s.stageJs := rfl
@[simp] theorem updT_stageWasm : (updT t f s).stageWasm = s.stageWasm := rfl
@[simp] theorem mapTabs_stageWasm : (mapTabs g s).stageWasm = s.stageWasm := rfl
@[simp] theorem updT_man : (updT t f s).man = s.man := rfl
@[simp] theorem mapTabs_man : (mapTabs g s).man = s.man := rfl
@[simp] theorem updT_slot : (updT t f s).slot = s.slot := rfl
@[simp] theorem mapTabs_slot : (mapTabs g s).slot = s.slot := rfl
@[simp] theorem updT_committed : (updT t f s).committed = s.committed := rfl
@[simp] theorem mapTabs_committed : (mapTabs g s).committed = s.committed := rfl
@[simp] theorem updT_cache : (updT t f s).cache = s.cache := rfl
@[simp] theorem mapTabs_cache : (mapTabs g s).cache = s.cache := rfl
@[simp] theorem updT_http : (updT t f s).http = s.http := rfl
@[simp] theorem mapTabs_http : (mapTabs g s).http = s.http := rfl
@[simp] theorem updT_skipQ : (updT t f s).skipQ = s.skipQ := rfl
@[simp] theorem mapTabs_skipQ : (mapTabs g s).skipQ = s.skipQ := rfl
@[simp] theorem updT_rW : (updT t f s).rW = s.rW := rfl
@[simp] theorem mapTabs_rW : (mapTabs g s).rW = s.rW := rfl
@[simp] theorem updT_rProbe : (updT t f s).rProbe = s.rProbe := rfl
@[simp] theorem mapTabs_rProbe : (mapTabs g s).rProbe = s.rProbe := rfl
@[simp] theorem updT_rMan : (updT t f s).rMan = s.rMan := rfl
@[simp] theorem mapTabs_rMan : (mapTabs g s).rMan = s.rMan := rfl
@[simp] theorem updT_rsJs : (updT t f s).rsJs = s.rsJs := rfl
@[simp] theorem mapTabs_rsJs : (mapTabs g s).rsJs = s.rsJs := rfl
@[simp] theorem updT_rsWasm : (updT t f s).rsWasm = s.rsWasm := rfl
@[simp] theorem mapTabs_rsWasm : (mapTabs g s).rsWasm = s.rsWasm := rfl
@[simp] theorem updT_rOk : (updT t f s).rOk = s.rOk := rfl
@[simp] theorem mapTabs_rOk : (mapTabs g s).rOk = s.rOk := rfl
@[simp] theorem updT_rJs : (updT t f s).rJs = s.rJs := rfl
@[simp] theorem mapTabs_rJs : (mapTabs g s).rJs = s.rJs := rfl
@[simp] theorem updT_rWasm : (updT t f s).rWasm = s.rWasm := rfl
@[simp] theorem mapTabs_rWasm : (mapTabs g s).rWasm = s.rWasm := rfl
@[simp] theorem updT_autoReloads : (updT t f s).autoReloads = s.autoReloads := rfl
@[simp] theorem mapTabs_autoReloads : (mapTabs g s).autoReloads = s.autoReloads := rfl
@[simp] theorem updT_forcedMidGame : (updT t f s).forcedMidGame = s.forcedMidGame := rfl
@[simp] theorem mapTabs_forcedMidGame : (mapTabs g s).forcedMidGame = s.forcedMidGame := rfl
@[simp] theorem updT_mixedBoot : (updT t f s).mixedBoot = s.mixedBoot := rfl
@[simp] theorem mapTabs_mixedBoot : (mapTabs g s).mixedBoot = s.mixedBoot := rfl
@[simp] theorem updT_dl : (updT t f s).dl = s.dl := rfl
@[simp] theorem mapTabs_dl : (mapTabs g s).dl = s.dl := rfl
@[simp] theorem updT_intents : (updT t f s).intents = s.intents := rfl
@[simp] theorem mapTabs_intents : (mapTabs g s).intents = s.intents := rfl
@[simp] theorem clearInst_intents : (clearInst s).intents = s.intents := rfl
@[simp] theorem rClear_intents : (rClear s).intents = s.intents := rfl
@[simp] theorem startInst_intents : (startInst s).intents = s.intents := rfl
@[simp] theorem activate_intents : (activate v s).intents = s.intents := rfl
@[simp] theorem updCheck_intents : (updCheck s).intents = s.intents := by unfold updCheck; split <;> rfl
@[simp] theorem showBtn_intents : (showBtn t v s).intents = s.intents := rfl
@[simp] theorem reload_intents : (reload E t auto s).intents = s.intents := rfl
@[simp] theorem installFailed_intents : (installFailed v s).intents = s.intents := rfl
@[simp] theorem installed_intents : (installed v s).intents = s.intents := by
  unfold installed; simp only []; (repeat' split) <;> rfl
@[simp] theorem rFailed_intents : (rFailed s).intents = s.intents := rfl
@[simp] theorem redund_intents : (redund s).intents = s.intents := by unfold redund; split <;> rfl
@[simp] theorem setStaged_intents (a : Asset) (b : Nat) : (setStaged s a b).intents = s.intents := by
  cases a <;> rfl
@[simp] theorem applyStart_intents : (applyStart E t s).intents = s.intents + 1 := by
  unfold applyStart; simp only []; (repeat' split) <;> simp
end proj

theorem step_intents_mono (E : Env) (s : State) (e : Event) : s.intents ≤ (step E s e).intents := by
  cases e <;> simp only [step] <;> (repeat' split) <;> simp

/-! ### No reload without a click -/

/-- The per-tab part: no update in progress in this tab; a controllerchange
    queued only in a page that never had a controller (a first install's
    claim, which reloads nothing). -/
def QT (x : Tab) : Prop :=
  x.applyK = .idle ∧ x.appUpdating = false ∧ x.force = false ∧ (x.ccQ = true → x.hadController = false)

/-- Per tab, with what it needs of the registration. -/
def QS (s : State) (t : Bool) : Prop :=
  QT (s.tabs t) ∧ (s.active = none → (s.tabs t).hadController = false) ∧
  ((s.tabs t).ccQ = true → s.active.isSome = true)

/-- The quiescent state: no update in progress anywhere. -/
def Q (s : State) : Prop :=
  s.skipQ = none ∧ s.autoReloads = 0 ∧ s.forcedMidGame = false ∧ ∀ t, QS s t

/-- A step that keeps everything Q reads but one tab, which keeps its QT
    fields and hadController/ccQ. -/
theorem q_frame {s s' : State} (h : Q s) (e1 : s'.skipQ = s.skipQ) (e2 : s'.autoReloads = s.autoReloads)
    (e3 : s'.forcedMidGame = s.forcedMidGame) (e4 : s'.active = s.active)
    (et : ∀ u, (s'.tabs u).applyK = (s.tabs u).applyK ∧ (s'.tabs u).appUpdating = (s.tabs u).appUpdating ∧
      (s'.tabs u).force = (s.tabs u).force ∧ (s'.tabs u).ccQ = (s.tabs u).ccQ ∧
      (s'.tabs u).hadController = (s.tabs u).hadController) : Q s' := by
  obtain ⟨a1, a2, a3, a4⟩ := h
  refine ⟨e1 ▸ a1, e2 ▸ a2, e3 ▸ a3, fun u => ?_⟩
  obtain ⟨⟨b1, b2, b3, b4⟩, b5, b6⟩ := a4 u
  obtain ⟨c1, c2, c3, c4, c5⟩ := et u
  refine ⟨⟨c1 ▸ b1, c2 ▸ b2, c3 ▸ b3, fun hc => c5 ▸ b4 (c4 ▸ hc)⟩, fun ha => c5 ▸ b5 (e4 ▸ ha),
    fun hc => e4 ▸ b6 (c4 ▸ hc)⟩

macro "q_fr" h:term : tactic => `(tactic| ((refine q_frame $h ?_ ?_ ?_ ?_ ?_) <;> (try rfl) <;> (intro u; first | (simp [claim]; done) | (simp only [updT_tabs, mapTabs_tabs, startInst_tabs, clearInst_tabs]; split <;> simp))))

section tabfields
variable (v : Nat) (x : Tab)
@[simp] theorem onInstalled_appUpdating : (onInstalled v x).appUpdating = x.appUpdating := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
@[simp] theorem onInstalled_force : (onInstalled v x).force = x.force := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
@[simp] theorem onInstalled_ccQ : (onInstalled v x).ccQ = x.ccQ := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
@[simp] theorem onInstalled_hadController : (onInstalled v x).hadController = x.hadController := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
@[simp] theorem onInstalled_shows : (onInstalled v x).shows = x.shows := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
@[simp] theorem onInstalled_updAvail : (onInstalled v x).updAvail = x.updAvail := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
theorem onInstalled_applyK : (onInstalled v x).applyK =
    if x.applyK = .watch v then .done else x.applyK := by
  unfold onInstalled; simp only []; split <;> split <;> simp_all
@[simp] theorem onRedundant_appUpdating : (onRedundant v x).appUpdating = x.appUpdating := by
  unfold onRedundant; split <;> rfl
@[simp] theorem onRedundant_force : (onRedundant v x).force = x.force := by
  unfold onRedundant; split <;> rfl
@[simp] theorem onRedundant_ccQ : (onRedundant v x).ccQ = x.ccQ := by
  unfold onRedundant; split <;> rfl
@[simp] theorem onRedundant_hadController : (onRedundant v x).hadController = x.hadController := by
  unfold onRedundant; split <;> rfl
@[simp] theorem onRedundant_shows : (onRedundant v x).shows = x.shows := by
  unfold onRedundant; split <;> rfl
@[simp] theorem onRedundant_updAvail : (onRedundant v x).updAvail = x.updAvail := by
  unfold onRedundant; split <;> rfl
theorem onRedundant_applyK : (onRedundant v x).applyK =
    if x.applyK = .watch v then .resetting else x.applyK := by
  unfold onRedundant; split <;> simp_all
end tabfields

theorem q_installFailed {s : State} (h : Q s) (v : Nat) : Q (installFailed v s) := by
  refine q_frame (s' := installFailed v s) h rfl rfl rfl rfl ?_
  intro u; have := (h.2.2.2 u).1.1
  simp [installFailed, onRedundant_applyK, this]

theorem q_installed {s : State} (h : Q s) (v : Nat) : Q (installed v s) := by
  obtain ⟨a1, a2, a3, a4⟩ := h
  have i1 : (s.tabs true).applyK = .idle := (a4 true).1.1
  have i2 : (s.tabs false).applyK = .idle := (a4 false).1.1
  unfold installed
  simp only [i1, i2]
  cases ha : s.active with
  | none =>
    simp only [mapTabs, clearInst, ha, activate]
    refine ⟨a1, a2, a3, fun u => ?_⟩
    obtain ⟨⟨b1, b2, b3, _⟩, b5, _⟩ := a4 u
    have hh := b5 ha
    refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_, ?_⟩ <;> simp [claim, onInstalled_applyK, b1, b2, b3, hh]
  | some w =>
    simp only [mapTabs, clearInst, ha]
    refine ⟨a1, a2, a3, fun u => ?_⟩
    obtain ⟨⟨b1, b2, b3, b4⟩, b5, b6⟩ := a4 u
    refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_, ?_⟩ <;> simp_all [onInstalled_applyK]

theorem q_showBtn {s : State} (h : Q s) (t : Bool) (v : Nat) : Q (showBtn t v s) := by
  unfold showBtn; q_fr h

theorem q_updCheck {s : State} (h : Q s) : Q (updCheck s) := by
  unfold updCheck; split
  · exact q_frame (s' := startInst s) h rfl rfl rfl rfl (fun u => by simp)
  · exact h

theorem serve_ctrl {E : Env} {s : State} {c : Option Nat} {b : Nat} {p : Nat × Nat}
    (hs : serve E s = (c, b, p)) : c = s.active := by
  unfold serve at hs
  cases ha : s.active with
  | none => simp only [ha] at hs; cases hs; rfl
  | some w => simp only [ha] at hs; split at hs <;> (cases hs; rfl)

theorem q_reload_user {E : Env} {s : State} (h : Q s) (t : Bool) : Q (reload E t false s) := by
  obtain ⟨a1, a2, a3, a4⟩ := h
  simp only [QS, QT] at a4
  unfold reload
  generalize hs : serve E s = sv
  obtain ⟨c, b, p⟩ := sv
  have hc := serve_ctrl hs
  refine ⟨a1, by simpa using a2, by simpa using a3, fun u => ?_⟩
  simp only [QS, QT, updT_tabs, updT_active]
  split
  · subst hc; cases ha : s.active <;> simp
  · exact a4 u

/-- With no Update or Force-update accepted in any tab, the app never reloads a
    tab by itself: there is no reload loop without a user's click. -/
def I0 (s : State) : Prop := s.intents = 0 → Q s

theorem i0_init (E : Env) : I0 (init E) := fun _ => by
  refine ⟨rfl, rfl, rfl, fun u => ⟨⟨rfl, rfl, rfl, ?_⟩, ?_, ?_⟩⟩ <;> intro h <;> cases h

theorem i0_fresh (E : Env) (d : Nat) : I0 (initFresh E d) := fun _ => by
  refine ⟨rfl, rfl, rfl, fun u => ⟨⟨rfl, rfl, rfl, ?_⟩, fun _ => rfl, ?_⟩⟩ <;> intro h <;> cases h

theorem i0_step {E : Env} {s : State} {e : Event} (h : I0 s) (he : en E s e = true) : I0 (step E s e) := by
  intro hz
  have hz0 : s.intents = 0 := by have := step_intents_mono E s e; omega
  have qs := h hz0
  have a4 := qs.2.2.2
  cases e with
  | deploy => simp only [step]; q_fr qs
  | browserCheck => exact q_updCheck qs
  | probeFirst | fetchJs | fetchWasm | nCommit | httpFill _ _ | httpEvict _ | rMan _ =>
    (try simp only [step]); (repeat' split) <;> q_fr qs
  | installEnd =>
    simp only [step]; split
    · split
      · apply q_installed; q_fr qs
      · exact q_installFailed qs _
    · exact qs
  | installFail => simp only [step]; split
                   · exact q_installFailed qs _
                   · exact qs
  | nManifest b =>
    simp only [step]; split
    · split
      · q_fr qs
      · exact q_installFailed qs _
    · exact qs
  | nLook a => simp only [step]; (repeat' split) <;> q_fr qs
  | nNet a b =>
    simp only [step]; split
    · split
      · q_fr qs
      · apply q_installFailed; q_fr qs
    · exact qs
  | nCheck =>
    simp only [step]; split
    · split
      · exact q_installed qs _
      · exact q_installFailed qs _
    · exact qs
  | regResolve t =>
    have q1 : Q (updT t (fun x => { x with regd := true }) s) := by q_fr qs
    simp only [step]; split
    · exact q_showBtn q1 t _
    · split
      · q_fr q1
      · exact q1
  | coreLoaded t =>
    simp only [step]; split
    · q_fr qs
    · q_fr qs
  | instFire t =>
    have q1 : Q (updT t (fun x => { x with instQ := none }) s) := by q_fr qs
    simp only [step]; split
    · split
      · exact q_showBtn q1 t _
      · exact q1
    · exact q1
  | skipDeliver => simp [en, qs.1] at he
  | ccFire t =>
    obtain ⟨⟨b1, b2, b3, b4⟩, b5, b6⟩ := a4 t
    have hc : (s.tabs t).ccQ = true := by simpa [en] using he
    have hh := b4 hc
    have hact := b6 hc
    simp only [step, hh, b2, Bool.or_self, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
    obtain ⟨a1, a2, a3, _⟩ := qs
    refine ⟨a1, a2, a3, fun u => ?_⟩
    have hu4 := a4 u
    simp only [QS, QT, updT_tabs, updT_active] at hu4 ⊢
    by_cases hu : u = t
    · subst hu; simp_all; intro h; simp [h] at b6
    · simp only [hu, ↓reduceIte]; exact hu4
  | userReload t => exact q_reload_user qs t
  | gameOn t => simp only [step]; q_fr qs
  | gameOff t => simp only [step]; q_fr qs
  | updClick t =>
    simp only [step] at hz ⊢
    split
    · q_fr qs
    · rename_i hg; simp only [hg, Bool.false_eq_true, ↓reduceIte, applyStart_intents] at hz; omega
  | confirm t => simp only [step, applyStart_intents] at hz; omega
  | notNow t => simp only [step]; q_fr qs
  | applyResume t => have := (a4 t).1.1; simp [en, this] at he
  | resetFire t => have := (a4 t).1.1; simp [en, this] at he
  | checkStart t => simp only [step]; q_fr qs
  | chkCur t => simp only [step]; q_fr qs
  | chkLatest t => simp only [step]; q_fr qs
  | chkSw t => simp only [step]; q_fr qs
  | chkEval t =>
    simp only [step]; split
    · have q1 : Q (updT t (fun x => { x with chk := none }) s) := by q_fr qs
      split
      · exact q_showBtn q1 t _
      · exact q1
    · exact qs
  | forceStart t => simp [step] at hz
  | rProbe0 | rFetchJs | rFetchWasm | rNet _ _ | rVerify | rPutJs | rPutWasm | rFail =>
    have := (a4 true).1.2.2.1; have := (a4 false).1.2.2.1; simp_all [en, anyForce]
  | forceDone t => have := (a4 t).1.2.2.1; simp [en, this] at he
  | newerStart t => simp [step] at hz
  | newerApply t => simp only [step, applyStart_intents, updT_intents] at hz; omega

theorem i0_reachable {E : Env} {s : State} (h : Reachable E s) : I0 s := by
  induction h with
  | init => exact i0_init E
  | fresh d => exact i0_fresh E d
  | step e _ he ih => exact i0_step ih he

theorem no_reload_without_a_click {E : Env} {s : State} (h : Reachable E s) (hz : s.intents = 0) :
    s.autoReloads = 0 ∧ s.forcedMidGame = false := by
  obtain ⟨_, a2, a3, _⟩ := i0_reachable h hz
  exact ⟨a2, a3⟩

/-! ### At most one prompt per page -/

def PT (x : Tab) : Prop := x.shows = if x.updAvail then 1 else 0
def P (s : State) : Prop := ∀ t, PT (s.tabs t)

theorem p_frame {s s' : State} (h : P s)
    (et : ∀ u, (s'.tabs u).shows = (s.tabs u).shows ∧ (s'.tabs u).updAvail = (s.tabs u).updAvail) :
    P s' := by
  intro u; obtain ⟨e1, e2⟩ := et u; unfold PT; rw [e1, e2]; exact h u

macro "p_fr" h:term : tactic => `(tactic| ((refine p_frame $h ?_) <;>
  (intro u; first | (simp [claim]; done) | (simp only [updT_tabs, mapTabs_tabs, startInst_tabs, clearInst_tabs, rClear_tabs]; split <;> simp))))

theorem p_showBtn {s : State} (h : P s) (t : Bool) (v : Nat) : P (showBtn t v s) := by
  intro u; simp only [showBtn, updT_tabs]
  split
  · have := h u; unfold PT at *; cases hu : (s.tabs u).updAvail <;> simp_all
  · exact h u

theorem p_reload {E : Env} {s : State} (h : P s) (t : Bool) (auto : Bool) : P (reload E t auto s) := by
  unfold reload
  generalize serve E s = sv
  obtain ⟨c, b, p⟩ := sv
  intro u; simp only [updT_tabs]
  split
  · cases c <;> simp [PT]
  · exact h u

theorem p_installFailed {s : State} (h : P s) (v : Nat) : P (installFailed v s) :=
  p_frame h (fun u => by simp [installFailed])

theorem p_installed {s : State} (h : P s) (v : Nat) : P (installed v s) := by
  unfold installed; simp only []
  split <;> split <;> (refine p_frame h ?_; intro u; simp [mapTabs, activate, clearInst, claim, *])

theorem p_updCheck {s : State} (h : P s) : P (updCheck s) := p_frame h (fun u => by simp)

theorem p_rFailed {s : State} (h : P s) : P (rFailed s) := by
  refine p_frame h ?_; intro u; simp only [rFailed, mapTabs_tabs, rClear_tabs]
  by_cases hf : (s.tabs u).force <;> simp [hf]

theorem p_applyStart {E : Env} {s : State} (h : P s) (t : Bool) : P (applyStart E t s) := by
  unfold applyStart
  have h1 : P (updT t (fun x => { x with appUpdating := true, modal := false }) { s with intents := s.intents + 1 }) := by
    p_fr h
  simp only []
  split
  · exact p_reload h1 t true
  · split
    · have := p_updCheck h1; p_fr this
    · p_fr h1

theorem p_redund {s : State} (h : P s) : P (redund s) := by
  unfold redund; split
  · p_fr h
  · exact h

theorem p_step {E : Env} {s : State} (h : P s) (e : Event) : P (step E s e) := by
  cases e with
  | regResolve t =>
    have h1 : P (updT t (fun x => { x with regd := true }) s) := by p_fr h
    simp only [step]; split
    · exact p_showBtn h1 t _
    · split
      · p_fr h1
      · exact h1
  | instFire t =>
    have h1 : P (updT t (fun x => { x with instQ := none }) s) := by p_fr h
    simp only [step]; split
    · split
      · exact p_showBtn h1 t _
      · exact h1
    · exact h1
  | skipDeliver =>
    simp only [step]; split
    · split
      · p_fr h
      · exact h
    · exact h
  | ccFire t =>
    have h1 : P (updT t (fun x => { x with ccQ := false }) s) := by p_fr h
    simp only [step]; split
    · split
      · exact p_reload h1 t true
      · have h2 : P (updT t (fun x => { x with ready := true, hadController := true })
            (updT t (fun x => { x with ccQ := false }) s)) := by p_fr h1
        split
        · exact p_showBtn h2 t _
        · exact h2
    · p_fr h1
  | userReload t => exact p_reload h t false
  | updClick t =>
    simp only [step]; split
    · p_fr h
    · exact p_applyStart h t
  | confirm t => exact p_applyStart h t
  | resetFire t =>
    simp only [step]; apply p_reload
    have := p_redund h
    p_fr this
  | chkEval t =>
    simp only [step]; split
    · have h1 : P (updT t (fun x => { x with chk := none }) s) := by p_fr h
      split
      · exact p_showBtn h1 t _
      · exact h1
    · exact h
  | forceDone t =>
    have h1 : P (updT t (fun x => { x with force := false }) s) := by p_fr h
    exact p_reload h1 t true
  | newerApply t =>
    have h1 : P (updT t (fun x => { x with newer := false }) s) := by p_fr h
    exact p_applyStart h1 t
  | browserCheck => exact p_updCheck h
  | installEnd =>
    simp only [step]; split
    · split
      · apply p_installed; p_fr h
      · exact p_installFailed h _
    · exact h
  | installFail => simp only [step]; split
                   · exact p_installFailed h _
                   · exact h
  | nManifest b =>
    simp only [step]; split
    · split
      · p_fr h
      · exact p_installFailed h _
    · exact h
  | nNet a b =>
    simp only [step]; split
    · split
      · p_fr h
      · apply p_installFailed; p_fr h
    · exact h
  | nCheck =>
    simp only [step]; split
    · split
      · exact p_installed h _
      · exact p_installFailed h _
    · exact h
  | rNet a b =>
    simp only [step]; split
    · split
      · p_fr h
      · exact p_rFailed h
    · exact h
  | rFail => exact p_rFailed h
  | coreLoaded t => simp only [step]; split <;> p_fr h
  | applyResume t => simp only [step]; split <;> p_fr h
  | _ => (try simp only [step]); (repeat' split) <;> p_fr h

/-- The Update button is shown at most once per page, however many checks,
    updatefound events and register() callbacks race. -/
theorem shows_at_most_once {E : Env} {s : State} (h : Reachable E s) (t : Bool) :
    (s.tabs t).shows ≤ 1 := by
  have hp : P s := by
    induction h with
    | init => intro u; simp [init, PT]
    | fresh d => intro u; simp [initFresh, init, PT]
    | step e _ _ ih => exact p_step ih e
  have := hp t
  unfold PT at this
  split at this <;> omega

/-! ### No tab reloaded mid-game unasked

The app reloads a tab by itself in five places: controllerchange, the end of
fullResetReload, Force update's "reinstalled", applyUpdate's
`updateActivated` path, and (through fullResetReload) a failed reinstall.
Each is this tab's own Update / Force update (`appUpdating`, set by the click
before any of them can run) or a tab with no game in progress. -/

/-- Per tab: an update in flight in this tab is one its user asked for. -/
def TI (x : Tab) : Prop :=
  (x.applyK ≠ .idle → x.appUpdating = true) ∧ (x.force = true → x.appUpdating = true)

def FI (s : State) : Prop := s.forcedMidGame = false ∧ ∀ t, TI (s.tabs t)

theorem fi_frame {s s' : State} (h : FI s) (e1 : s'.forcedMidGame = s.forcedMidGame)
    (et : ∀ u, TI (s.tabs u) → TI (s'.tabs u)) : FI s' :=
  ⟨e1 ▸ h.1, fun u => et u (h.2 u)⟩

theorem ti_onInstalled (v : Nat) (x : Tab) (h : TI x) : TI (onInstalled v x) := by
  obtain ⟨a, b⟩ := h
  refine ⟨fun hk => ?_, fun hf => ?_⟩
  · simp only [onInstalled_appUpdating]; apply a
    intro h0; rw [onInstalled_applyK] at hk; split at hk
    · rename_i hw; rw [hw] at h0; cases h0
    · exact hk h0
  · simp only [onInstalled_appUpdating, onInstalled_force] at *; exact b hf

theorem ti_onRedundant (v : Nat) (x : Tab) (h : TI x) : TI (onRedundant v x) := by
  obtain ⟨a, b⟩ := h
  refine ⟨fun hk => ?_, fun hf => ?_⟩
  · simp only [onRedundant_appUpdating]; apply a
    intro h0; rw [onRedundant_applyK] at hk; split at hk
    · rename_i hw; rw [hw] at h0; cases h0
    · exact hk h0
  · simp only [onRedundant_appUpdating, onRedundant_force] at *; exact b hf

/-- A tab function that keeps applyK, appUpdating and force keeps TI. -/
theorem ti_same {x y : Tab} (h : TI x) (e1 : y.applyK = x.applyK) (e2 : y.appUpdating = x.appUpdating)
    (e3 : y.force = x.force) : TI y := by
  obtain ⟨a, b⟩ := h; exact ⟨fun hk => e2 ▸ a (e1 ▸ hk), fun hf => e2 ▸ b (e3 ▸ hf)⟩

macro "fi_fr" h:term : tactic => `(tactic| ((refine fi_frame $h ?_ ?_) <;> (try rfl) <;>
  (intro u hu; first
    | (refine ti_same hu ?_ ?_ ?_ <;> simp [claim] <;> done)
    | (simp only [updT_tabs, mapTabs_tabs, startInst_tabs, clearInst_tabs, rClear_tabs];
       split <;>
       refine ti_same hu ?_ ?_ ?_ <;> simp_all [claim] <;> done))))

theorem fi_reload {E : Env} {s : State} (h : FI s) (t : Bool) (auto : Bool)
    (hok : auto = false ∨ (s.tabs t).appUpdating = true ∨ (s.tabs t).game = false) :
    FI (reload E t auto s) := by
  obtain ⟨a, b⟩ := h
  unfold reload
  generalize serve E s = sv
  obtain ⟨c, bb, p⟩ := sv
  refine ⟨?_, fun u => ?_⟩
  · simp only [updT_forcedMidGame, a, Bool.false_or]
    rcases hok with hk | hk | hk <;> simp [hk]
  · simp only [updT_tabs]
    split
    · cases c <;> exact ⟨fun hk => absurd rfl hk, fun hf => by cases hf⟩
    · exact b u

theorem fi_showBtn {s : State} (h : FI s) (t : Bool) (v : Nat) : FI (showBtn t v s) := by
  unfold showBtn; fi_fr h

theorem fi_updCheck {s : State} (h : FI s) : FI (updCheck s) :=
  fi_frame h (by unfold updCheck; split <;> rfl) (fun u hu => by simpa using hu)

theorem fi_installFailed {s : State} (h : FI s) (v : Nat) : FI (installFailed v s) :=
  fi_frame h rfl (fun u hu => by simpa [installFailed] using ti_onRedundant v _ hu)

theorem fi_installed {s : State} (h : FI s) (v : Nat) : FI (installed v s) := by
  unfold installed; simp only []
  split <;> split <;>
  · refine fi_frame h rfl ?_
    intro u hu
    have := ti_onInstalled v _ hu
    first
    | exact this
    | (refine ti_same this ?_ ?_ ?_ <;> simp [mapTabs, activate, clearInst, claim])

theorem fi_rFailed {s : State} (h : FI s) : FI (rFailed s) := by
  refine fi_frame h rfl ?_
  intro u hu
  simp only [rFailed, mapTabs_tabs, rClear_tabs]
  by_cases hf : (s.tabs u).force = true
  · simp only [hf, ↓reduceIte]; exact ⟨fun _ => hu.2 hf, fun h => by cases h⟩
  · simp only [hf]; exact hu

theorem fi_redund {s : State} (h : FI s) : FI (redund s) := by
  unfold redund; split
  · exact fi_frame h rfl (fun u hu => by simpa using ti_onRedundant _ _ hu)
  · exact h

theorem fi_applyStart {E : Env} {s : State} (h : FI s) (t : Bool) : FI (applyStart E t s) := by
  unfold applyStart
  have h1 : FI (updT t (fun x => { x with appUpdating := true, modal := false })
      { s with intents := s.intents + 1 }) := by
    refine fi_frame h rfl ?_
    intro u hu; simp only [updT_tabs]; split
    · exact ⟨fun _ => rfl, fun _ => rfl⟩
    · exact hu
  simp only []
  split
  · exact fi_reload h1 t true (Or.inr (Or.inl (by simp)))
  · have fm : ∀ X : State, (updCheck X).forcedMidGame = X.forcedMidGame := by
      intro X; unfold updCheck; split <;> rfl
    split
    · refine fi_frame h (by simp [fm]) ?_
      intro u hu; simp only [updT_tabs, updCheck_tabs]
      by_cases hut : u = t
      · subst hut; simp only [↓reduceIte]; exact ⟨fun _ => rfl, fun _ => rfl⟩
      · simp only [hut, ↓reduceIte]; exact hu
    · refine fi_frame h (by simp) ?_
      intro u hu; simp only [updT_tabs]
      by_cases hut : u = t
      · subst hut; simp only [↓reduceIte]; exact ⟨fun _ => rfl, fun _ => rfl⟩
      · simp only [hut, ↓reduceIte]; exact hu

theorem fi_step {E : Env} {s : State} {e : Event} (h : FI s) (he : en E s e = true) : FI (step E s e) := by
  have hs := h
  obtain ⟨a, b⟩ := h
  cases e with
  | browserCheck => exact fi_updCheck hs
  | installEnd =>
    simp only [step]; split
    · split
      · apply fi_installed; fi_fr hs
      · exact fi_installFailed hs _
    · exact hs
  | installFail => simp only [step]; split
                   · exact fi_installFailed hs _
                   · exact hs
  | nManifest b =>
    simp only [step]; split
    · split
      · fi_fr hs
      · exact fi_installFailed hs _
    · exact hs
  | nNet a b =>
    simp only [step]; split
    · split
      · fi_fr hs
      · apply fi_installFailed; fi_fr hs
    · exact hs
  | nCheck =>
    simp only [step]; split
    · split
      · exact fi_installed hs _
      · exact fi_installFailed hs _
    · exact hs
  | regResolve t =>
    have h1 : FI (updT t (fun x => { x with regd := true }) s) := by fi_fr hs
    simp only [step]; split
    · exact fi_showBtn h1 t _
    · split
      · fi_fr h1
      · exact h1
  | instFire t =>
    have h1 : FI (updT t (fun x => { x with instQ := none }) s) := by fi_fr hs
    simp only [step]; split
    · split
      · exact fi_showBtn h1 t _
      · exact h1
    · exact h1
  | skipDeliver =>
    simp only [step]; split
    · split
      · fi_fr hs
      · exact hs
    · exact hs
  | ccFire t =>
    have h1 : FI (updT t (fun x => { x with ccQ := false }) s) := by fi_fr hs
    simp only [step]; split
    · split
      · rename_i hc
        apply fi_reload h1 t true
        right
        simp only [updT_tabs, ↓reduceIte]
        cases hu : (s.tabs t).appUpdating
        · simp_all
        · simp
      · have h2 : FI (updT t (fun x => { x with ready := true, hadController := true })
            (updT t (fun x => { x with ccQ := false }) s)) := by fi_fr h1
        split
        · exact fi_showBtn h2 t _
        · exact h2
    · fi_fr h1
  | userReload t => exact fi_reload hs t false (Or.inl rfl)
  | updClick t =>
    simp only [step]; split
    · fi_fr hs
    · exact fi_applyStart hs t
  | confirm t => exact fi_applyStart hs t
  | applyResume t =>
    -- the tab is suspended in applyUpdate, which its click started
    have hu : (s.tabs t).appUpdating = true := by
      apply (b t).1; simp [en] at he; simp [he]
    simp only [step]; split <;>
      (refine fi_frame hs rfl ?_; intro u hu'; simp only [updT_tabs]; split
       · rename_i e; subst e; exact ⟨fun _ => hu, fun hf => (b u).2 hf⟩
       · exact hu')
  | resetFire t =>
    have hu : (s.tabs t).appUpdating = true := by
      apply (b t).1; simp [en] at he; simp [he]
    simp only [step]
    have h1 := fi_redund hs
    apply fi_reload ?_ t true (Or.inr (Or.inl ?_))
    · exact fi_frame h1 rfl (fun u hu => hu)
    · show ((redund s).tabs t).appUpdating = true
      unfold redund; split <;> simp [hu]
  | chkEval t =>
    simp only [step]; split
    · have h1 : FI (updT t (fun x => { x with chk := none }) s) := by fi_fr hs
      split
      · exact fi_showBtn h1 t _
      · exact h1
    · exact hs
  | forceStart t =>
    simp only [step]
    refine fi_frame hs rfl ?_
    intro u hu; simp only [updT_tabs, rClear_tabs]; split
    · exact ⟨fun _ => rfl, fun _ => rfl⟩
    · exact hu
  | rNet a b =>
    simp only [step]; split
    · split
      · cases a <;> fi_fr hs
      · exact fi_rFailed hs
    · exact hs
  | rFail => exact fi_rFailed hs
  | forceDone t =>
    have hu : (s.tabs t).appUpdating = true := by
      apply (b t).2; simp only [en, Bool.and_eq_true] at he; exact he.1.1
    simp only [step]
    apply fi_reload (fi_frame hs rfl (s' := updT t (fun x => { x with force := false }) s) ?_) t true
    · right; left; simp [hu]
    · intro u hx; simp only [updT_tabs]; split
      · exact ⟨hx.1, fun h => by cases h⟩
      · exact hx
  | newerStart t => simp only [step]; fi_fr hs
  | newerApply t =>
    have h1 : FI (updT t (fun x => { x with newer := false }) s) := by fi_fr hs
    exact fi_applyStart h1 t
  | coreLoaded t => simp only [step]; split <;> fi_fr hs
  | _ => (try simp only [step]); (repeat' split) <;> fi_fr hs

theorem fi_reachable {E : Env} {s : State} (h : Reachable E s) : FI s := by
  induction h with
  | init => exact ⟨rfl, fun _ => ⟨fun h => absurd rfl h, fun h => by cases h⟩⟩
  | fresh d => exact ⟨rfl, fun _ => ⟨fun h => absurd rfl h, fun h => by cases h⟩⟩
  | step e _ he ih => exact fi_step ih he

/-- **No tab is reloaded mid-game unless its own user asked**, in every
    interleaving of deploys, installs of both designs, both tabs' Update and
    Force update clicks, failed reinstalls, and the controllerchange each
    activation fires in every tab. -/
theorem no_forced_midgame {E : Env} {s : State} (h : Reachable E s) : s.forcedMidGame = false :=
  (fi_reachable h).1

/-! ### An applyUpdate watching an install has it to wait on

applyUpdate's statechange listener ends in skipWaiting (`installed`) or the
full reset (`redundant`); it hangs only if the install it watches goes away
without telling it. Every way an install ends tells it: success, failure,
and another tab's full reset, whose unregister makes the worker redundant. So
a watching tab always has its install under way, which can always still end
(`installFail` is enabled whenever one is): Update lands or visibly fails. -/

def W (s : State) : Prop := ∀ t v, (s.tabs t).applyK = .watch v → s.installing = some v

theorem w_none {s : State} (h : W s) (hn : s.installing = none) (t : Bool) (v : Nat) :
    (s.tabs t).applyK ≠ .watch v := by
  intro hw; have := h t v hw; rw [hn] at this; cases this

theorem w_frame {s s' : State} (h : W s) (e1 : s'.installing = s.installing)
    (et : ∀ u v, (s'.tabs u).applyK = .watch v → (s.tabs u).applyK = .watch v) : W s' :=
  fun u v hw => e1 ▸ h u v (et u v hw)

macro "w_fr" h:term : tactic => `(tactic| ((refine w_frame $h ?_ ?_) <;> (try rfl) <;>
  (intro u v hw; first
    | (simpa [claim] using hw)
    | (simp only [updT_tabs, mapTabs_tabs, startInst_tabs, clearInst_tabs, rClear_tabs] at hw;
       split at hw <;> simp_all <;> done))))

/-- Nothing installing: nobody watches, so an install may start. -/
theorem w_start {s : State} (h : W s) (hn : s.installing = none) : W (startInst s) := by
  intro u v hw; exact absurd hw (w_none h hn u v)

theorem w_updCheck {s : State} (h : W s) : W (updCheck s) := by
  unfold updCheck; split
  · rename_i hc; simp only [Bool.and_eq_true, Option.isNone_iff_eq_none] at hc
    exact w_start h hc.1.1.1
  · exact h

theorem w_installFailed {s : State} (h : W s) (v : Nat) (hv : s.installing = some v) :
    W (installFailed v s) := by
  intro u w hw
  simp only [installFailed, mapTabs_tabs, clearInst_tabs, onRedundant_applyK] at hw
  split at hw
  · cases hw
  · have := h u w hw; rw [hv] at this; cases this; simp_all

theorem w_installed {s : State} (h : W s) (v : Nat) (hv : s.installing = some v) :
    W (installed v s) := by
  have key : ∀ u w, (onInstalled v (s.tabs u)).applyK = .watch w → False := by
    intro u w hw; rw [onInstalled_applyK] at hw; split at hw
    · cases hw
    · have := h u w hw; rw [hv] at this; cases this; simp_all
  unfold installed; simp only []
  split <;> split <;>
  · intro u w hw
    simp only [mapTabs, activate, clearInst, claim] at hw
    exact (key u w hw).elim

theorem w_reload {E : Env} {s : State} (h : W s) (t : Bool) (auto : Bool) : W (reload E t auto s) := by
  unfold reload
  generalize serve E s = sv
  obtain ⟨c, bb, p⟩ := sv
  intro u w hw
  simp only [updT_tabs] at hw
  split at hw
  · cases c <;> simp at hw
  · exact h u w hw

theorem w_applyStart {E : Env} {s : State} (h : W s) (t : Bool) : W (applyStart E t s) := by
  unfold applyStart
  have h1 : W (updT t (fun x => { x with appUpdating := true, modal := false })
      { s with intents := s.intents + 1 }) := by w_fr h
  simp only []
  split
  · exact w_reload h1 t true
  · split
    · have h2 := w_updCheck h1
      intro u w hw; simp only [updT_tabs] at hw
      split at hw
      · cases hw
      · exact h2 u w hw
    · w_fr h1

theorem w_rFailed {s : State} (h : W s) : W (rFailed s) := by
  intro u w hw
  simp only [rFailed, mapTabs_tabs, rClear_tabs] at hw
  by_cases hf : (s.tabs u).force = true
  · simp [hf] at hw
  · simp only [hf] at hw; exact h u w (by simpa using hw)

theorem w_step {E : Env} {s : State} {e : Event} (h : W s) : W (step E s e) := by
  cases e with
  | browserCheck => exact w_updCheck h
  | installEnd =>
    simp only [step]; split
    · rename_i v p j ww hv _ _ _
      split
      · apply w_installed; exact w_frame h rfl (fun _ _ hw => hw); exact hv
      · exact w_installFailed h v hv
    · exact h
  | installFail =>
    simp only [step]; split
    · rename_i v hv; exact w_installFailed h v hv
    · exact h
  | nManifest b =>
    simp only [step]; split
    · rename_i v hv; split
      · w_fr h
      · exact w_installFailed h v hv
    · exact h
  | nNet a b =>
    simp only [step]; split
    · rename_i v m hv _; split
      · w_fr h
      · exact w_installFailed (s := { s with dl := s.dl + 1 }) h v hv
    · exact h
  | nCheck =>
    simp only [step]; split
    · rename_i v hv; split
      · exact w_installed h v hv
      · exact w_installFailed h v hv
    · exact h
  | regResolve t =>
    have h1 : W (updT t (fun x => { x with regd := true }) s) := by w_fr h
    simp only [step]; split
    · unfold showBtn; w_fr h1
    · split
      · rename_i hc; simp only [Bool.and_eq_true, Option.isNone_iff_eq_none] at hc
        exact w_start h1 hc.2
      · exact h1
  | applyResume t =>
    simp only [step]; split
    · w_fr h
    · rename_i v hw hi
      intro u w hw'; simp only [updT_tabs] at hw'
      split at hw'
      · cases hw'; exact hi
      · exact h u w hw'
    · w_fr h
  | resetFire t =>
    simp only [step]
    apply w_reload
    intro u w hw
    exfalso
    simp only [clearInst_tabs, redund] at hw
    split at hw
    · rename_i v hv
      simp only [mapTabs_tabs, onRedundant_applyK] at hw
      split at hw
      · cases hw
      · have := h u w hw; rw [hv] at this; cases this; simp_all
    · rename_i hv
      exact w_none h (by cases hh : s.installing <;> simp_all) u w hw
  | userReload t => exact w_reload h t false
  | forceDone t =>
    simp only [step]; apply w_reload; w_fr h
  | ccFire t =>
    simp only [step]; split
    · split
      · apply w_reload; w_fr h
      · split
        · unfold showBtn; w_fr h
        · w_fr h
    · w_fr h
  | updClick t =>
    simp only [step]; split
    · w_fr h
    · exact w_applyStart h t
  | confirm t => exact w_applyStart h t
  | newerApply t =>
    have h1 : W (updT t (fun x => { x with newer := false }) s) := by w_fr h
    exact w_applyStart h1 t
  | instFire t =>
    have h1 : W (updT t (fun x => { x with instQ := none }) s) := by w_fr h
    simp only [step]; split
    · split
      · unfold showBtn; w_fr h1
      · exact h1
    · exact h1
  | chkEval t =>
    simp only [step]; split
    · have h1 : W (updT t (fun x => { x with chk := none }) s) := by w_fr h
      split
      · unfold showBtn; w_fr h1
      · exact h1
    · exact h
  | skipDeliver =>
    simp only [step]; split
    · split
      · w_fr h
      · exact h
    · exact h
  | rNet a b =>
    simp only [step]; split
    · split
      · cases a <;> w_fr h
      · exact w_rFailed h
    · exact h
  | rFail => exact w_rFailed h
  | coreLoaded t => simp only [step]; split <;> w_fr h
  | _ => (try simp only [step]); (repeat' split) <;> w_fr h

theorem w_reachable {E : Env} {s : State} (h : Reachable E s) : W s := by
  induction h with
  | init => intro u w hw; simp [init] at hw
  | fresh d => intro u w hw; simp [initFresh, init] at hw
  | step e _ _ ih => exact w_step ih

/-- An applyUpdate that is watching an install for its `installed` or
    `redundant` statechange always has that install still under way. -/
theorem watching_has_install {E : Env} {s : State} (h : Reachable E s) (t : Bool) (v : Nat)
    (hw : (s.tabs t).applyK = .watch v) : s.installing = some v ∧ en E s .installFail = true := by
  have := w_reachable h t v hw
  exact ⟨this, by simp [en, this]⟩

/-! ### Every cache holds its own build, without Force update

With H injective, every cache `dingbat-<v>` holds exactly build v's bytes,
whatever deploys land inside installs, whatever older objects stale edges,
older caches or the HTTP cache hold, and with workers of both designs
installing side by side. The old design gets there by its probes (deploys only
move forward, so em.wasm's build lies between them); the new one by the
digests, whatever its sources answer: its manifest is refused unless it is
the worker's own build's, and nothing is kept whose digest is not that
manifest's. The fetch handler's own-cache-only lookup keeps a waiting build out
of the running one, and activation drops every other cache. -/

def benignC : Event → Bool
  | .forceStart _ => false
  | _ => true

inductive Reach3 (E : Env) : State → Prop
  | init : Reach3 E (init E)
  | fresh (d : Nat) : Reach3 E (initFresh E d)
  | step {s : State} (e : Event) : Reach3 E s → en E s e = true → benignC e = true → Reach3 E (step E s e)

def CS (E : Env) (s : State) : Prop :=
  (∀ v p, s.cache v = some p → p = E.bytes v) ∧
  (∀ p, s.probe0 = some p → s.installing.isSome = true ∧ p ≤ s.dep) ∧
  (∀ j, s.stageJs = some j → ∃ p, s.probe0 = some p ∧ p ≤ j ∧ j ≤ s.dep) ∧
  (∀ w, s.stageWasm = some w → ∃ p, s.probe0 = some p ∧ p ≤ w ∧ w ≤ s.dep) ∧
  (∀ m, s.man = some m → s.installing = some m) ∧
  (∀ a x, s.slot a = .have x → ∃ v, s.installing = some v ∧ E.H x = E.H (E.C a v)) ∧
  s.mixedBoot = false

def CInv (E : Env) (s : State) : Prop := CS E s ∧ ∀ t, (s.tabs t).force = false

theorem cinv_frame {E : Env} {s s' : State} (h : CInv E s) (ec : s'.cache = s.cache)
    (ep : s'.probe0 = s.probe0) (ej : s'.stageJs = s.stageJs) (ew : s'.stageWasm = s.stageWasm)
    (ei : s'.installing = s.installing) (ed : s'.dep = s.dep) (em : s'.mixedBoot = s.mixedBoot)
    (eman : s'.man = s.man) (es : s'.slot = s.slot)
    (ef : ∀ u, (s'.tabs u).force = (s.tabs u).force) : CInv E s' := by
  obtain ⟨⟨a1, a2, a3, a4, a5, a6, a7⟩, b⟩ := h
  refine ⟨⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, fun u => ?_⟩
  · rw [ec]; exact a1
  · rw [ep, ei, ed]; exact a2
  · rw [ej, ep, ed]; exact a3
  · rw [ew, ep, ed]; exact a4
  · rw [eman, ei]; exact a5
  · rw [es, ei]; exact a6
  · rw [em]; exact a7
  · rw [ef]; exact b u

macro "c_fr" h:term : tactic => `(tactic| ((refine cinv_frame $h ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_) <;> (try rfl) <;>
  (intro u; first | (simp [claim]; done) |
    (simp only [updT_tabs, mapTabs_tabs, startInst_tabs, clearInst_tabs]; split <;> simp))))

/-- Nothing installing, nothing staged. -/
theorem cinv_clear {E : Env} {s : State} (h : CInv E s) : CInv E (clearInst s) := by
  obtain ⟨⟨a1, _, _, _, _, _, a7⟩, b⟩ := h
  refine ⟨⟨a1, ?_, ?_, ?_, ?_, ?_, a7⟩, b⟩ <;> intros <;> simp_all [clearInst]

theorem cinv_start {E : Env} {s : State} (h : CInv E s) : CInv E (startInst s) := by
  obtain ⟨⟨a1, _, _, _, _, _, a7⟩, b⟩ := h
  refine ⟨⟨a1, ?_, ?_, ?_, ?_, ?_, a7⟩, b⟩ <;> intros <;> simp_all [startInst, clearInst]

theorem cinv_updCheck {E : Env} {s : State} (h : CInv E s) : CInv E (updCheck s) := by
  unfold updCheck; split
  · exact cinv_start h
  · exact h

theorem cinv_installFailed {E : Env} {s : State} (h : CInv E s) (v : Nat) : CInv E (installFailed v s) := by
  have h1 := cinv_clear h
  exact cinv_frame h1 rfl rfl rfl rfl rfl rfl rfl rfl rfl (fun u => by simp [installFailed])

theorem cinv_activate {E : Env} {s : State} (h : CInv E s) (v : Nat) : CInv E (activate v s) := by
  obtain ⟨⟨a1, a2, a3, a4, a5, a6, a7⟩, b⟩ := h
  refine ⟨⟨fun u p hp => ?_, a2, a3, a4, a5, a6, a7⟩, fun u => by simp [claim, b u]⟩
  simp only [activate, mapTabs_cache] at hp
  split at hp
  · exact a1 u p hp
  · cases hp

theorem cinv_installed {E : Env} {s : State} (h : CInv E s) (v : Nat) : CInv E (installed v s) := by
  have h1 : CInv E (mapTabs (onInstalled v) (clearInst s)) :=
    cinv_frame (cinv_clear h) rfl rfl rfl rfl rfl rfl rfl rfl rfl (fun u => by simp)
  have hw : ∀ X : State, CInv E X → CInv E { X with waiting := some v } :=
    fun X h => cinv_frame h rfl rfl rfl rfl rfl rfl rfl rfl rfl (fun _ => rfl)
  have hq : ∀ X : State, CInv E X → CInv E { X with skipQ := some v } :=
    fun X h => cinv_frame h rfl rfl rfl rfl rfl rfl rfl rfl rfl (fun _ => rfl)
  unfold installed; simp only []
  split <;> split <;> first
    | exact cinv_activate h1 v
    | exact hw _ h1
    | exact hq _ (cinv_activate h1 v)
    | exact hq _ (hw _ h1)

theorem serve_build {E : Env} {s : State} (h : CS E s) {c : Option Nat} {b : Nat} {p : Nat × Nat}
    (hs : serve E s = (c, b, p)) : p = E.bytes b := by
  unfold serve at hs
  split at hs
  · split at hs
    · cases hs; exact h.1 _ _ (by assumption)
    · cases hs; rfl
  · cases hs; rfl

theorem cinv_reload {E : Env} {s : State} (h : CInv E s) (t : Bool) (auto : Bool) :
    CInv E (reload E t auto s) := by
  obtain ⟨hc, b⟩ := h
  unfold reload
  generalize hsv : serve E s = sv
  obtain ⟨c, bb, p⟩ := sv
  have hp := serve_build hc hsv
  obtain ⟨a1, a2, a3, a4, a5, a6, a7⟩ := hc
  refine ⟨⟨a1, a2, a3, a4, a5, a6, ?_⟩, fun u => ?_⟩
  · simp [a7, hp]
  · simp only [updT_tabs]; split
    · cases c <;> rfl
    · exact b u

theorem cinv_showBtn {E : Env} {s : State} (h : CInv E s) (t : Bool) (v : Nat) : CInv E (showBtn t v s) := by
  unfold showBtn; c_fr h

theorem cinv_applyStart {E : Env} {s : State} (h : CInv E s) (t : Bool) : CInv E (applyStart E t s) := by
  unfold applyStart
  have h1 : CInv E (updT t (fun x => { x with appUpdating := true, modal := false })
      { s with intents := s.intents + 1 }) := by c_fr h
  simp only []
  split
  · exact cinv_reload h1 t true
  · split
    · have := cinv_updCheck h1; c_fr this
    · c_fr h1

theorem cinv_step {E : Env} (hH : Injective E.H) {s : State} {e : Event} (h : CInv E s)
    (he : en E s e = true) (hb : benignC e = true) : CInv E (step E s e) := by
  have hs := h
  obtain ⟨⟨a1, a2, a3, a4, a5, a6, a7⟩, b⟩ := h
  cases e with
  | deploy =>
    -- dep only grows: every bound stays a bound
    refine ⟨⟨a1, fun p hp => ?_, fun j hj => ?_, fun w hw => ?_, a5, a6, a7⟩, b⟩
    · have := a2 p hp; exact ⟨this.1, by simp only [step]; omega⟩
    · obtain ⟨p, h1, h2, h3⟩ := a3 j hj; exact ⟨p, h1, h2, by simp only [step]; omega⟩
    · obtain ⟨p, h1, h2, h3⟩ := a4 w hw; exact ⟨p, h1, h2, by simp only [step]; omega⟩
  | browserCheck => exact cinv_updCheck hs
  | probeFirst =>
    have hi : s.installing.isSome = true := by
      simp only [en, oldInst, Bool.and_eq_true] at he
      obtain ⟨h1, _⟩ := he; split at h1 <;> simp_all
    have hp0 : s.probe0 = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.2
    refine ⟨⟨a1, fun p hp => ?_, fun j hj => ?_, fun w hw => ?_, a5, a6, a7⟩, b⟩
    · simp only [step, Option.some.injEq] at hp; subst hp; exact ⟨hi, Nat.le_refl _⟩
    · obtain ⟨p, h1, _⟩ := a3 j hj; rw [hp0] at h1; cases h1
    · obtain ⟨p, h1, _⟩ := a4 w hw; rw [hp0] at h1; cases h1
  | fetchJs =>
    have hp : s.probe0.isSome = true := by
      simp only [en, Bool.and_eq_true] at he; exact he.1.2
    obtain ⟨p, hp⟩ := Option.isSome_iff_exists.mp hp
    refine ⟨⟨a1, a2, fun j hj => ?_, a4, a5, a6, a7⟩, b⟩
    simp only [step, Option.some.injEq] at hj; subst hj
    exact ⟨p, hp, (a2 p hp).2, Nat.le_refl _⟩
  | fetchWasm =>
    have hp : s.probe0.isSome = true := by
      simp only [en, Bool.and_eq_true] at he; exact he.1.2
    obtain ⟨p, hp⟩ := Option.isSome_iff_exists.mp hp
    refine ⟨⟨a1, a2, a3, fun w hw => ?_, a5, a6, a7⟩, b⟩
    simp only [step, Option.some.injEq] at hw; subst hw
    exact ⟨p, hp, (a2 p hp).2, Nat.le_refl _⟩
  | installEnd =>
    simp only [step]
    split
    · rename_i v p j w _ hp hj hw
      split
      · rename_i hok
        simp only [Bool.and_eq_true, beq_iff_eq] at hok
        obtain ⟨⟨hjp, hdp⟩, hpv⟩ := hok
        -- em.wasm's build is between the two probes, which agree
        have ew : w = j := by
          obtain ⟨p', hp', h1, h2⟩ := a4 w hw
          rw [hp] at hp'; cases hp'
          omega
        apply cinv_installed
        refine ⟨⟨fun u q hq => ?_, a2, a3, a4, a5, a6, a7⟩, b⟩
        simp only [] at hq
        split at hq
        · rename_i hu; subst hu; cases hq; simp [Env.bytes, ew, hjp, hpv]
        · exact a1 u q hq
      · exact cinv_installFailed hs v
    · exact hs
  | installFail =>
    simp only [step]; split
    · exact cinv_installFailed hs _
    · exact hs
  | nManifest bb =>
    simp only [step]; split
    · rename_i v hv; split
      · rename_i hbv; simp only [beq_iff_eq] at hbv; subst hbv
        refine ⟨⟨a1, a2, a3, a4, fun m hm => ?_, a6, a7⟩, b⟩
        simp only [Option.some.injEq] at hm; subst hm; exact hv
      · exact cinv_installFailed hs v
    · exact hs
  | nLook a =>
    simp only [step]; split
    · rename_i m hm
      have hi := a5 m hm
      split
      · rename_i x hx
        have hok : E.H x = E.H (E.C a m) := by
          unfold heldBytes at hx; simp only [] at hx
          split at hx
          · rename_i y hy; cases hx; have := List.find?_some hy; simpa using this
          · split at hx
            · split at hx
              · cases hx; simpa using (by assumption : (E.H x == E.H (E.C a m)) = true)
              · cases hx
            · cases hx
        refine ⟨⟨a1, a2, a3, a4, a5, fun a' x' hx' => ?_, a7⟩, b⟩
        simp only [setSlot] at hx'; split at hx'
        · rename_i ha; subst ha; cases hx'; exact ⟨m, hi, hok⟩
        · exact a6 a' x' hx'
      · refine ⟨⟨a1, a2, a3, a4, a5, fun a' x' hx' => ?_, a7⟩, b⟩
        simp only [setSlot] at hx'; split at hx'
        · cases hx'
        · exact a6 a' x' hx'
    · exact hs
  | nNet a bb =>
    simp only [step]; split
    · rename_i v m hv hm
      have hmv : m = v := by have := a5 m hm; rw [hv] at this; cases this; rfl
      subst hmv
      split
      · rename_i hok; simp only [beq_iff_eq] at hok
        refine ⟨⟨a1, a2, a3, a4, a5, fun a' x' hx' => ?_, a7⟩, b⟩
        simp only [setSlot] at hx'; split at hx'
        · rename_i ha; subst ha; cases hx'; exact ⟨m, hv, hok⟩
        · exact a6 a' x' hx'
      · exact cinv_installFailed (s := { s with dl := s.dl + 1 }) ⟨⟨a1, a2, a3, a4, a5, a6, a7⟩, b⟩ _
    · exact hs
  | nCommit =>
    simp only [step]; split
    · rename_i v xj xw hv hj hw
      obtain ⟨v1, hv1, hj'⟩ := a6 .js xj hj
      obtain ⟨v2, hv2, hw'⟩ := a6 .wasm xw hw
      rw [hv] at hv1 hv2; cases hv1; cases hv2
      have e1 := hH _ _ hj'
      have e2 := hH _ _ hw'
      refine ⟨⟨fun u q hq => ?_, a2, a3, a4, a5, a6, a7⟩, b⟩
      simp only [] at hq; split at hq
      · rename_i hu; subst hu; cases hq; simp [Env.bytes, e1, e2]
      · exact a1 u q hq
    · exact hs
  | nCheck =>
    simp only [step]; split
    · split
      · exact cinv_installed hs _
      · exact cinv_installFailed hs _
    · exact hs
  | regResolve t =>
    have h1 : CInv E (updT t (fun x => { x with regd := true }) s) := by c_fr hs
    simp only [step]; split
    · exact cinv_showBtn h1 t _
    · split
      · exact cinv_start h1
      · exact h1
  | coreLoaded t => simp only [step]; split <;> c_fr hs
  | httpFill a bb => simp only [step]; c_fr hs
  | httpEvict a => simp only [step]; c_fr hs
  | instFire t =>
    have h1 : CInv E (updT t (fun x => { x with instQ := none }) s) := by c_fr hs
    simp only [step]; split
    · split
      · exact cinv_showBtn h1 t _
      · exact h1
    · exact h1
  | skipDeliver =>
    simp only [step]; split
    · split
      · exact cinv_activate (s := { s with skipQ := none }) hs _
      · exact hs
    · exact hs
  | ccFire t =>
    have h1 : CInv E (updT t (fun x => { x with ccQ := false }) s) := by c_fr hs
    simp only [step]; split
    · split
      · exact cinv_reload h1 t true
      · have h2 : CInv E (updT t (fun x => { x with ready := true, hadController := true })
            (updT t (fun x => { x with ccQ := false }) s)) := by c_fr h1
        split
        · exact cinv_showBtn h2 t _
        · exact h2
    · c_fr h1
  | userReload t => exact cinv_reload hs t false
  | gameOn t => simp only [step]; c_fr hs
  | gameOff t => simp only [step]; c_fr hs
  | updClick t =>
    simp only [step]; split
    · c_fr hs
    · exact cinv_applyStart hs t
  | confirm t => exact cinv_applyStart hs t
  | notNow t => simp only [step]; c_fr hs
  | applyResume t => simp only [step]; split <;> c_fr hs
  | resetFire t =>
    simp only [step]
    apply cinv_reload
    have hr : ∀ u, ((redund s).tabs u).force = false := by
      intro u; unfold redund; split <;> simp [b u]
    refine ⟨⟨fun _ _ h => by simp at h, fun _ h => by simp [clearInst] at h,
      fun _ h => by simp [clearInst] at h, fun _ h => by simp [clearInst] at h,
      fun _ h => by simp [clearInst] at h, fun _ _ h => by simp [clearInst] at h, ?_⟩, fun u => hr u⟩
    show (redund s).mixedBoot = false
    unfold redund; split <;> simpa using a7
  | checkStart t => simp only [step]; c_fr hs
  | chkCur t => simp only [step]; c_fr hs
  | chkLatest t => simp only [step]; c_fr hs
  | chkSw t => simp only [step]; c_fr hs
  | chkEval t =>
    simp only [step]; split
    · have h1 : CInv E (updT t (fun x => { x with chk := none }) s) := by c_fr hs
      split
      · exact cinv_showBtn h1 t _
      · exact h1
    · exact hs
  | forceStart t => simp [benignC] at hb
  | rProbe0 | rFetchJs | rFetchWasm | rMan _ | rNet _ _ | rVerify | rPutJs | rPutWasm | rFail =>
    simp [en, anyForce, b] at he
  | forceDone t => simp [en, b] at he
  | newerStart t => simp only [step]; c_fr hs
  | newerApply t =>
    have h1 : CInv E (updT t (fun x => { x with newer := false }) s) := by c_fr hs
    exact cinv_applyStart h1 t

theorem cinv_reach3 {E : Env} (hH : Injective E.H) {s : State} (h : Reach3 E s) : CInv E s := by
  induction h with
  | init =>
    refine ⟨⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, ?_⟩ <;> simp [init]
  | fresh d => refine ⟨⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, ?_⟩ <;> simp [initFresh, init]
  | step e _ he hb ih => exact cinv_step hH ih he hb

/-- **Consistency.** Without Force update, and with the digest injective,
    every cache `dingbat-<v>` holds exactly build v's bytes, in every
    interleaving of deploys with installs of either design, stale edges,
    older caches and the HTTP cache. In particular so does the active
    worker's, the only one the fetch handler serves. -/
theorem cache_is_its_build {E : Env} (hH : Injective E.H) {s : State} (h : Reach3 E s) {v : Nat}
    {p : Nat × Nat} (hc : s.cache v = some p) : p = E.bytes v :=
  (cinv_reach3 hH h).1.1 v p hc

/-- Without Force update, every page boots exactly the bytes of the build it
    boots from: its worker's own build, or the deployed one off the network.
    (With Force update: `bug_force_update_serves_half_written_cache`.) -/
theorem no_mixed_boot_without_force {E : Env} (hH : Injective E.H) {s : State} (h : Reach3 E s) :
    s.mixedBoot = false :=
  (cinv_reach3 hH h).1.2.2.2.2.2.2

/-! ### Force update only commits one build

An old worker's reinstall is version-probed as its install was; a new
worker's checks each download against the manifest the origin served, so a
deploy landing mid-download fails it (`regress_new_force_update_straddle_fails`). -/

def RI (E : Env) (s : State) : Prop :=
  (∀ p, s.rProbe = some p → p ≤ s.dep) ∧
  (oldR E s = true →
    (∀ j, s.rsJs = some j → ∃ p, s.rProbe = some p ∧ p ≤ j ∧ j ≤ s.dep) ∧
    (∀ w, s.rsWasm = some w → ∃ p, s.rProbe = some p ∧ p ≤ w ∧ w ≤ s.dep)) ∧
  (newR E s = true → ∀ a b, staged s a = some b → ∃ m, s.rMan = some m ∧ E.H (E.C a b) = E.H (E.C a m)) ∧
  (s.rOk = true → ∃ j w, s.rsJs = some j ∧ s.rsWasm = some w ∧
     ((oldR E s = true ∧ j = w) ∨ (newR E s = true ∧ s.rMan.isSome = true)))

theorem ri_frame {E : Env} {s s' : State} (h : RI E s) (e1 : s'.rProbe = s.rProbe) (e2 : s'.rMan = s.rMan)
    (e3 : s'.rsJs = s.rsJs) (e4 : s'.rsWasm = s.rsWasm) (e5 : s'.rOk = s.rOk) (e6 : s'.rW = s.rW)
    (e7 : s'.dep = s.dep) : RI E s' := by
  have eo : oldR E s' = oldR E s := by simp [oldR, e6]
  have en' : newR E s' = newR E s := by simp [newR, e6]
  have est : staged s' = staged s := by funext a; cases a <;> simp [staged, e3, e4]
  obtain ⟨a1, a2, a3, a4⟩ := h
  refine ⟨?_, ?_, ?_, ?_⟩ <;> simp only [e1, e2, e3, e4, e5, e7, eo, en', est] <;> assumption

theorem old_new_excl {E : Env} {s : State} (h1 : oldR E s = true) (h2 : newR E s = true) : False := by
  unfold oldR newR at *; split at h1 <;> simp_all

theorem old_of_not_new {E : Env} {s : State} (h : newR E s = true) : oldR E s = false := by
  cases h' : oldR E s
  · rfl
  · exact (old_new_excl h' h).elim

macro "r_fr" h:term : tactic => `(tactic| (exact ri_frame $h rfl rfl rfl rfl rfl rfl rfl))

theorem ri_updCheck {E : Env} {s : State} (h : RI E s) : RI E (updCheck s) := by
  unfold updCheck; split
  · r_fr h
  · exact h

theorem ri_installed {E : Env} {s : State} (h : RI E s) (v : Nat) : RI E (installed v s) := by
  unfold installed; simp only []; split <;> split <;> r_fr h

theorem ri_reload {E : Env} {s : State} (h : RI E s) (t : Bool) (auto : Bool) : RI E (reload E t auto s) := by
  unfold reload; generalize serve E s = sv; obtain ⟨c, bb, p⟩ := sv; r_fr h

theorem ri_applyStart {E : Env} {s : State} (h : RI E s) (t : Bool) : RI E (applyStart E t s) := by
  have h1 : RI E (updT t (fun x => { x with appUpdating := true, modal := false })
      { s with intents := s.intents + 1 }) := by r_fr h
  unfold applyStart; simp only []; split
  · exact ri_reload h1 t true
  · split
    · have := ri_updCheck h1; r_fr this
    · r_fr h1

theorem ri_rFailed {E : Env} {s : State} (h : RI E s) : RI E (rFailed s) := by
  obtain ⟨a1, _, _, _⟩ := h
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro p hp; simp [rFailed, rClear] at hp
  · intro _; refine ⟨?_, ?_⟩ <;> intro _ hj <;> simp [rFailed, rClear] at hj
  · intro _ a b hb; cases a <;> simp [rFailed, rClear, staged] at hb
  · intro ho; simp [rFailed, rClear] at ho

theorem ri_step {E : Env} {s : State} {e : Event} (h : RI E s) (he : en E s e = true) : RI E (step E s e) := by
  have hs := h
  obtain ⟨a1, a2, a3, a4⟩ := h
  cases e with
  | deploy =>
    refine ⟨fun p hp => ?_, fun ho => ⟨fun j hj => ?_, fun w hw => ?_⟩, a3, a4⟩
    · have := a1 p hp; simp only [step]; omega
    · obtain ⟨p, q1, q2, q3⟩ := (a2 ho).1 j hj; exact ⟨p, q1, q2, by simp only [step]; omega⟩
    · obtain ⟨p, q1, q2, q3⟩ := (a2 ho).2 w hw; exact ⟨p, q1, q2, by simp only [step]; omega⟩
  | forceStart t =>
    refine ⟨?_, ?_, ?_, ?_⟩
    · intro p hp; simp [step, rClear] at hp
    · intro _; refine ⟨?_, ?_⟩ <;> intro _ hj <;> simp [step, rClear] at hj
    · intro _ a b hb; cases a <;> simp [step, rClear, staged] at hb
    · intro ho; simp [step, rClear] at ho
  | rProbe0 =>
    have hn : s.rProbe = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.2
    refine ⟨fun p hp => ?_, fun ho => ⟨fun j hj => ?_, fun w hw => ?_⟩, a3, fun ho => ?_⟩
    · simp only [step, Option.some.injEq] at hp ⊢; omega
    · obtain ⟨p, q1, _⟩ := (a2 ho).1 j hj; rw [hn] at q1; cases q1
    · obtain ⟨p, q1, _⟩ := (a2 ho).2 w hw; rw [hn] at q1; cases q1
    · obtain ⟨j, w, hj, hw, hc⟩ := a4 ho
      have hold : oldR E s = true := by simp only [en, Bool.and_eq_true] at he; exact he.1.2
      obtain ⟨p, q1, _⟩ := (a2 hold).1 j hj; rw [hn] at q1; cases q1
  | rFetchJs =>
    have hold : oldR E s = true := by simp only [en, Bool.and_eq_true] at he; exact he.1.1.2
    have hp : s.rProbe.isSome = true := by simp only [en, Bool.and_eq_true] at he; exact he.1.2
    have hn : s.rsJs = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.2
    obtain ⟨p, hp⟩ := Option.isSome_iff_exists.mp hp
    refine ⟨a1, fun _ => ⟨fun j hj => ?_, (a2 hold).2⟩, fun hnew => ?_, fun ho => ?_⟩
    · simp only [step, Option.some.injEq] at hj; subst hj
      exact ⟨p, hp, a1 p hp, Nat.le_refl _⟩
    · exact (old_new_excl hold hnew).elim
    · obtain ⟨j, _, hj, _⟩ := a4 ho; rw [hn] at hj; cases hj
  | rFetchWasm =>
    have hold : oldR E s = true := by simp only [en, Bool.and_eq_true] at he; exact he.1.1.2
    have hp : s.rProbe.isSome = true := by simp only [en, Bool.and_eq_true] at he; exact he.1.2
    have hn : s.rsWasm = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.2
    obtain ⟨p, hp⟩ := Option.isSome_iff_exists.mp hp
    refine ⟨a1, fun _ => ⟨(a2 hold).1, fun w hw => ?_⟩, fun hnew => ?_, fun ho => ?_⟩
    · simp only [step, Option.some.injEq] at hw; subst hw
      exact ⟨p, hp, a1 p hp, Nat.le_refl _⟩
    · exact (old_new_excl hold hnew).elim
    · obtain ⟨_, w, _, hw, _⟩ := a4 ho; rw [hn] at hw; cases hw
  | rMan b =>
    have hnew : newR E s = true := by simp only [en, Bool.and_eq_true] at he; exact he.1.1.2
    have hn : s.rMan = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.1.2
    have hold : oldR E s = false := old_of_not_new hnew
    refine ⟨a1, fun ho => ?_, fun _ a bb hb => ?_, fun ho => ?_⟩
    · change oldR E s = true at ho; rw [hold] at ho; cases ho
    · obtain ⟨m, hm, _⟩ := a3 hnew a bb (by cases a <;> simpa [step, staged] using hb)
      rw [hn] at hm; cases hm
    · obtain ⟨j, w, hj, hw, hc⟩ := a4 ho
      rcases hc with hc | hc
      · rw [hold] at hc; cases hc.1
      · rw [hn] at hc; cases hc.2
  | rNet a b =>
    have hnew : newR E s = true := by simp only [en, Bool.and_eq_true] at he; exact he.1.1.1.2
    have hna : staged s a = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.1.2
    have hold : oldR E s = false := old_of_not_new hnew
    simp only [step]; split
    · rename_i m hm
      split
      · rename_i hok; simp only [beq_iff_eq] at hok
        have nok : s.rOk = false := by
          cases hk : s.rOk
          · rfl
          · obtain ⟨j, w, hj, hw, _⟩ := a4 hk; cases a <;> simp_all [staged]
        refine ⟨?_, ?_, ?_, ?_⟩
        · intro p hp; cases a <;> exact a1 p (by simpa [setStaged] using hp)
        · intro ho; cases a <;> simp [setStaged, oldR] at ho <;> simp_all [oldR]
        · intro _ a' bb hb
          by_cases ha : a' = a
          · subst ha; cases a' <;> (simp [setStaged, staged] at hb; subst hb; exact ⟨m, by simpa [setStaged] using hm, hok⟩)
          · have : staged (setStaged s a b) a' = staged s a' := by
              cases a <;> cases a' <;> simp_all [setStaged, staged]
            rw [this] at hb
            obtain ⟨m', hm', hh⟩ := a3 hnew a' bb hb
            exact ⟨m', by cases a <;> simpa [setStaged] using hm', hh⟩
        · intro ho; cases a <;> simp [setStaged, nok] at ho
      · exact ri_rFailed hs
    · exact hs
  | rVerify =>
    refine ⟨a1, fun ho => a2 ho, fun hn => a3 hn, fun _ => ?_⟩
    simp only [en, Bool.and_eq_true] at he
    obtain ⟨_, hm⟩ := he
    simp only [step] at *
    split at hm
    · rename_i hold
      revert hm
      rcases hp : s.rProbe with _ | p <;> rcases hj : s.rsJs with _ | j <;>
        rcases hw : s.rsWasm with _ | w <;> simp
      intro hjp hdp
      obtain ⟨p', q1, q2, q3⟩ := (a2 hold).2 w hw
      rw [hp] at q1; cases q1
      exact Or.inl ⟨hold, by omega⟩
    · simp only [Bool.and_eq_true] at hm
      obtain ⟨⟨⟨hnew, hman⟩, hj⟩, hw⟩ := hm
      obtain ⟨j, hj⟩ := Option.isSome_iff_exists.mp hj
      obtain ⟨w, hw⟩ := Option.isSome_iff_exists.mp hw
      exact ⟨j, w, hj, hw, Or.inr ⟨hnew, hman⟩⟩
  | rFail => exact ri_rFailed hs
  | rPutJs => simp only [step]; split <;> r_fr hs
  | rPutWasm => simp only [step]; split <;> r_fr hs
  | browserCheck => exact ri_updCheck hs
  | installEnd =>
    simp only [step]; split
    · split
      · apply ri_installed; r_fr hs
      · r_fr hs
    · exact hs
  | installFail => simp only [step]; split <;> r_fr hs
  | nManifest b => simp only [step]; split
                   · split <;> r_fr hs
                   · exact hs
  | nNet a b => simp only [step]; split
                · split <;> r_fr hs
                · exact hs
  | nCheck =>
    simp only [step]; split
    · split
      · exact ri_installed hs _
      · r_fr hs
    · exact hs
  | regResolve t =>
    simp only [step]; split
    · r_fr hs
    · split <;> r_fr hs
  | skipDeliver => simp only [step]; split
                   · split <;> r_fr hs
                   · exact hs
  | ccFire t =>
    simp only [step]; split
    · split
      · exact ri_reload (s := updT t _ s) (by r_fr hs) t true
      · split <;> r_fr hs
    · r_fr hs
  | userReload t => exact ri_reload hs t false
  | updClick t => simp only [step]; split
                  · r_fr hs
                  · exact ri_applyStart hs t
  | confirm t => exact ri_applyStart hs t
  | newerApply t => exact ri_applyStart (s := updT t _ s) (by r_fr hs) t
  | resetFire t =>
    simp only [step]
    apply ri_reload
    unfold redund; split <;> r_fr hs
  | forceDone t => exact ri_reload (s := updT t _ s) (by r_fr hs) t true
  | applyResume t => simp only [step]; split <;> r_fr hs
  | chkEval t => simp only [step]; split
                 · split <;> r_fr hs
                 · exact hs
  | instFire t => simp only [step]; split
                  · split <;> r_fr hs
                  · r_fr hs
  | coreLoaded t => simp only [step]; split <;> r_fr hs
  | _ => (try simp only [step]); (repeat' split) <;> r_fr hs

theorem ri_reachable {E : Env} {s : State} (h : Reachable E s) : RI E s := by
  induction h with
  | init => refine ⟨?_, ?_, ?_, ?_⟩ <;> simp [init, oldR, newR, staged]
  | fresh d => refine ⟨?_, ?_, ?_, ?_⟩ <;> simp [initFresh, init, oldR, newR, staged]
  | step e _ he ih => exact ri_step ih he

/-- A Force update's download only reaches the live cache as one build: once
    it passes its check, what is staged for index.js and for em.wasm is one
    build's bytes, even when deploys landed during the download (an old
    worker's: by its probes; a new worker's: by the digests, with H
    injective). Its commit is still two puts:
    `bug_force_update_serves_half_written_cache`. -/
theorem force_stage_one_build {E : Env} (hH : Injective E.H) {s : State} (h : Reachable E s)
    (ho : s.rOk = true) :
    ∃ j w b, s.rsJs = some j ∧ s.rsWasm = some w ∧ E.C .js j = E.C .js b ∧ E.C .wasm w = E.C .wasm b := by
  obtain ⟨_, _, a3, a4⟩ := ri_reachable h
  obtain ⟨j, w, hj, hw, hc⟩ := a4 ho
  rcases hc with ⟨_, hjw⟩ | ⟨hnew, hm⟩
  · exact ⟨j, w, j, hj, hw, rfl, by rw [hjw]⟩
  · obtain ⟨m, hm', h1⟩ := a3 hnew .js j hj
    obtain ⟨m2, hm2, h2⟩ := a3 hnew .wasm w hw
    rw [hm'] at hm2; cases hm2
    exact ⟨j, w, m, hj, hw, hH _ _ h1, hH _ _ h2⟩

/-! ### Every cache holds builds' bytes, and only deployed builds have one

With Force update too: nothing the worker stores is anything but some
build's copy of that asset (no garbage, whatever the HTTP cache and the
sources hand it), and every cache, worker and install is of a build already
deployed, so the lookup's search over builds up to `dep` is over all of them. -/

def IsB (E : Env) (a : Asset) (x : Nat) : Prop := ∃ b, x = E.C a b

def Wf (E : Env) (s : State) : Prop :=
  (∀ v, s.installing = some v → v ≤ s.dep) ∧
  (∀ v, s.waiting = some v → v ≤ s.dep) ∧
  (∀ v, s.active = some v → v ≤ s.dep) ∧
  (∀ w, s.rW = some w → w ≤ s.dep) ∧
  (∀ u p, s.cache u = some p → u ≤ s.dep ∧ IsB E .js p.1 ∧ IsB E .wasm p.2) ∧
  (∀ a x, s.http a = some x → IsB E a x) ∧
  (∀ a x, s.slot a = .have x → IsB E a x) ∧
  (∀ t, IsB E .js (s.tabs t).running.1 ∧ IsB E .wasm (s.tabs t).running.2)

theorem wf_frame {E : Env} {s s' : State} (h : Wf E s) (e1 : s'.installing = s.installing)
    (e2 : s'.waiting = s.waiting) (e3 : s'.active = s.active) (e4 : s'.rW = s.rW)
    (e5 : s'.cache = s.cache) (e6 : s'.http = s.http) (e7 : s'.slot = s.slot) (e8 : s'.dep = s.dep)
    (et : ∀ u, (s'.tabs u).running = (s.tabs u).running) : Wf E s' := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8⟩ := h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, fun u => ?_⟩
  · rw [e1, e8]; exact a1
  · rw [e2, e8]; exact a2
  · rw [e3, e8]; exact a3
  · rw [e4, e8]; exact a4
  · rw [e5, e8]; exact a5
  · rw [e6]; exact a6
  · rw [e7]; exact a7
  · rw [et]; exact a8 u

macro "wf_fr" h:term : tactic => `(tactic| ((refine wf_frame $h ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_) <;> (try rfl) <;>
  (intro u; first | (simp [claim]; done) |
    (simp only [updT_tabs, mapTabs_tabs, startInst_tabs, clearInst_tabs, rClear_tabs]; split <;> simp))))

theorem isB_pick {E : Env} {p : Nat × Nat} (h1 : IsB E .js p.1) (h2 : IsB E .wasm p.2) (a : Asset) :
    IsB E a (pick a p) := by cases a <;> assumption

theorem heldBytes_src {E : Env} {s : State} {a : Asset} {m x : Nat} (h : heldBytes E s a m = some x) :
    (∃ u p, s.cache u = some p ∧ pick a p = x) ∨ s.http a = some x := by
  unfold heldBytes at h; simp only [] at h
  split at h
  · rename_i y hy; cases h
    have := List.mem_of_find?_eq_some hy
    simp only [List.mem_filterMap, Option.map_eq_some_iff] at this
    obtain ⟨u, _, p, hp, hpy⟩ := this
    exact Or.inl ⟨u, p, hp, hpy⟩
  · split at h
    · split at h
      · cases h; exact Or.inr (by assumption)
      · cases h
    · cases h

theorem heldBytes_ok {E : Env} {s : State} {a : Asset} {m x : Nat} (h : heldBytes E s a m = some x) :
    E.H x = E.H (E.C a m) := by
  unfold heldBytes at h; simp only [] at h
  split at h
  · rename_i y hy; cases h; have := List.find?_some hy; simpa using this
  · split at h
    · split at h
      · cases h; simpa using (by assumption : (E.H x == E.H (E.C a m)) = true)
      · cases h
    · cases h

theorem wf_clear {E : Env} {s : State} (h : Wf E s) : Wf E (clearInst s) := by
  obtain ⟨_, a2, a3, a4, a5, a6, _, a8⟩ := h
  refine ⟨?_, a2, a3, a4, a5, a6, ?_, a8⟩ <;> intros <;> simp_all [clearInst]

theorem wf_start {E : Env} {s : State} (h : Wf E s) : Wf E (startInst s) := by
  obtain ⟨_, a2, a3, a4, a5, a6, _, a8⟩ := h
  refine ⟨?_, a2, a3, a4, a5, a6, ?_, a8⟩ <;> intros <;> simp_all [startInst, clearInst]

theorem wf_updCheck {E : Env} {s : State} (h : Wf E s) : Wf E (updCheck s) := by
  unfold updCheck; split
  · exact wf_start h
  · exact h

theorem wf_activate {E : Env} {s : State} (h : Wf E s) (v : Nat) (hv : v ≤ s.dep) : Wf E (activate v s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8⟩ := h
  refine ⟨a1, fun w hw => ?_, fun w hw => ?_, a4, fun u p hp => ?_, a6, a7, fun u => a8 u⟩
  · simp only [activate, mapTabs_waiting] at hw; split at hw
    · cases hw
    · exact a2 w hw
  · simp only [activate, mapTabs_active, Option.some.injEq] at hw; subst hw; exact hv
  · simp only [activate, mapTabs_cache] at hp; split at hp
    · exact a5 u p hp
    · cases hp

theorem wf_installFailed {E : Env} {s : State} (h : Wf E s) (v : Nat) : Wf E (installFailed v s) :=
  wf_frame (wf_clear h) rfl rfl rfl rfl rfl rfl rfl rfl (fun u => by simp [installFailed]; unfold onRedundant; split <;> rfl)

theorem wf_installed {E : Env} {s : State} (h : Wf E s) (v : Nat) (hv : v ≤ s.dep) : Wf E (installed v s) := by
  have h1 : Wf E (mapTabs (onInstalled v) (clearInst s)) :=
    wf_frame (wf_clear h) rfl rfl rfl rfl rfl rfl rfl rfl
      (fun u => by simp only [mapTabs_tabs, clearInst_tabs]; unfold onInstalled; simp only []; split <;> split <;> rfl)
  have hw : ∀ X : State, Wf E X → X.dep = s.dep → Wf E { X with waiting := some v } := by
    intro X h e
    obtain ⟨a1, _, a3, a4, a5, a6, a7, a8⟩ := h
    refine ⟨a1, fun w hw => ?_, a3, a4, a5, a6, a7, a8⟩
    simp only [Option.some.injEq] at hw; subst hw; rw [e]; exact hv
  have hq : ∀ X : State, Wf E X → Wf E { X with skipQ := some v } :=
    fun X h => wf_frame h rfl rfl rfl rfl rfl rfl rfl rfl (fun _ => rfl)
  have ha := wf_activate h1 v hv
  unfold installed; simp only []
  split <;> split <;> first
    | exact ha
    | exact hw _ h1 rfl
    | exact hq _ ha
    | exact hq _ (hw _ h1 rfl)

theorem wf_reload {E : Env} {s : State} (h : Wf E s) (t : Bool) (auto : Bool) : Wf E (reload E t auto s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8⟩ := h
  have hb : IsB E .js (E.bytes s.dep).1 ∧ IsB E .wasm (E.bytes s.dep).2 := ⟨⟨_, rfl⟩, ⟨_, rfl⟩⟩
  unfold reload
  generalize hsv : serve E s = sv
  obtain ⟨c, bb, p⟩ := sv
  have hp : IsB E .js p.1 ∧ IsB E .wasm p.2 := by
    unfold serve at hsv
    split at hsv
    · split at hsv
      · cases hsv; exact (a5 _ _ (by assumption)).2
      · cases hsv; exact hb
    · cases hsv; exact hb
  refine ⟨a1, a2, a3, a4, a5, fun a x hx => ?_, a7, fun u => ?_⟩
  · simp only [updT_http] at hx
    split at hx
    · simp only [setHttp] at hx; split at hx
      · rename_i ha; subst ha; cases hx; exact hp.1
      · exact a6 a x hx
    · exact a6 a x hx
  · simp only [updT_tabs]; split
    · cases c <;> exact hp
    · exact a8 u

theorem wf_showBtn {E : Env} {s : State} (h : Wf E s) (t : Bool) (v : Nat) : Wf E (showBtn t v s) := by
  unfold showBtn; wf_fr h

theorem wf_applyStart {E : Env} {s : State} (h : Wf E s) (t : Bool) : Wf E (applyStart E t s) := by
  have h1 : Wf E (updT t (fun x => { x with appUpdating := true, modal := false })
      { s with intents := s.intents + 1 }) := by wf_fr h
  unfold applyStart; simp only []; split
  · exact wf_reload h1 t true
  · split
    · have := wf_updCheck h1; wf_fr this
    · wf_fr h1

theorem wf_rFailed {E : Env} {s : State} (h : Wf E s) : Wf E (rFailed s) := by
  refine wf_frame h rfl rfl rfl rfl rfl rfl rfl rfl (fun u => ?_)
  simp only [rFailed, mapTabs_tabs, rClear_tabs]
  by_cases hf : (s.tabs u).force = true <;> simp [hf]

theorem wf_step {E : Env} {s : State} {e : Event} (h : Wf E s) (he : en E s e = true) : Wf E (step E s e) := by
  have hs := h
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8⟩ := h
  cases e with
  | deploy =>
    refine ⟨fun v hv => ?_, fun v hv => ?_, fun v hv => ?_, fun w hw => ?_, fun u p hp => ?_,
      a6, a7, a8⟩ <;> simp only [step]
    · have := a1 v hv; omega
    · have := a2 v hv; omega
    · have := a3 v hv; omega
    · have := a4 w hw; omega
    · have := a5 u p hp; exact ⟨by omega, this.2⟩
  | browserCheck => exact wf_updCheck hs
  | installEnd =>
    simp only [step]; split
    · rename_i v p j w hv _ _ _
      split
      · apply wf_installed _ v
        · exact a1 v hv
        refine ⟨a1, a2, a3, a4, fun u q hq => ?_, a6, a7, a8⟩
        simp only [] at hq; split at hq
        · rename_i hu; subst hu; cases hq; exact ⟨a1 _ hv, ⟨_, rfl⟩, ⟨_, rfl⟩⟩
        · exact a5 u q hq
      · exact wf_installFailed hs v
    · exact hs
  | installFail => simp only [step]; split
                   · exact wf_installFailed hs _
                   · exact hs
  | nManifest b =>
    simp only [step]; split
    · split
      · wf_fr hs
      · exact wf_installFailed hs _
    · exact hs
  | nLook a =>
    simp only [step]; split
    · split
      · rename_i x hx
        refine ⟨a1, a2, a3, a4, a5, a6, fun a' x' hx' => ?_, a8⟩
        simp only [setSlot] at hx'; split at hx'
        · rename_i ha; subst ha; cases hx'
          rcases heldBytes_src hx with ⟨u, p, hp, hpx⟩ | hh
          · rw [← hpx]; exact isB_pick (a5 u p hp).2.1 (a5 u p hp).2.2 a'
          · exact a6 a' x hh
        · exact a7 a' x' hx'
      · refine ⟨a1, a2, a3, a4, a5, a6, fun a' x' hx' => ?_, a8⟩
        simp only [setSlot] at hx'; split at hx'
        · cases hx'
        · exact a7 a' x' hx'
    · exact hs
  | nNet a b =>
    simp only [step]; split
    · split
      · refine ⟨a1, a2, a3, a4, a5, a6, fun a' x' hx' => ?_, a8⟩
        simp only [setSlot] at hx'; split at hx'
        · rename_i ha; subst ha; cases hx'; exact ⟨_, rfl⟩
        · exact a7 a' x' hx'
      · exact wf_installFailed (s := { s with dl := s.dl + 1 }) ⟨a1, a2, a3, a4, a5, a6, a7, a8⟩ _
    · exact hs
  | nCommit =>
    simp only [step]; split
    · rename_i v xj xw hv hj hw
      refine ⟨a1, a2, a3, a4, fun u q hq => ?_, a6, a7, a8⟩
      simp only [] at hq; split at hq
      · rename_i hu; subst hu; cases hq; exact ⟨a1 _ hv, a7 _ _ hj, a7 _ _ hw⟩
      · exact a5 u q hq
    · exact hs
  | nCheck =>
    simp only [step]; split
    · rename_i v hv; split
      · exact wf_installed hs v (a1 v hv)
      · exact wf_installFailed hs _
    · exact hs
  | regResolve t =>
    have h1 : Wf E (updT t (fun x => { x with regd := true }) s) := by wf_fr hs
    simp only [step]; split
    · exact wf_showBtn h1 t _
    · split
      · exact wf_start h1
      · exact h1
  | coreLoaded t =>
    simp only [step]; split
    · wf_fr hs
    · refine ⟨a1, a2, a3, a4, a5, fun a x hx => ?_, a7, fun u => ?_⟩
      · simp only [updT_http, setHttp] at hx; split at hx
        · rename_i ha; subst ha; cases hx; exact (a8 t).2
        · exact a6 a x hx
      · simp only [updT_tabs]; split
        · exact a8 u
        · exact a8 u
  | httpFill a b =>
    refine ⟨a1, a2, a3, a4, a5, fun a' x hx => ?_, a7, a8⟩
    simp only [step, setHttp] at hx; split at hx
    · rename_i ha; subst ha; cases hx; exact ⟨_, rfl⟩
    · exact a6 a' x hx
  | httpEvict a =>
    refine ⟨a1, a2, a3, a4, a5, fun a' x hx => ?_, a7, a8⟩
    simp only [step, setHttp] at hx; split at hx
    · cases hx
    · exact a6 a' x hx
  | skipDeliver =>
    simp only [step]; split
    · rename_i v hq; split
      · rename_i hw; simp only [beq_iff_eq] at hw
        exact wf_activate (s := { s with skipQ := none }) hs v (a2 v hw)
      · exact hs
    · exact hs
  | ccFire t =>
    have h1 : Wf E (updT t (fun x => { x with ccQ := false }) s) := by wf_fr hs
    simp only [step]; split
    · split
      · exact wf_reload h1 t true
      · have h2 : Wf E (updT t (fun x => { x with ready := true, hadController := true })
            (updT t (fun x => { x with ccQ := false }) s)) := by wf_fr h1
        split
        · exact wf_showBtn h2 t _
        · exact h2
    · wf_fr h1
  | userReload t => exact wf_reload hs t false
  | updClick t =>
    simp only [step]; split
    · wf_fr hs
    · exact wf_applyStart hs t
  | confirm t => exact wf_applyStart hs t
  | newerApply t =>
    have h1 : Wf E (updT t (fun x => { x with newer := false }) s) := by wf_fr hs
    exact wf_applyStart h1 t
  | applyResume t => simp only [step]; split <;> wf_fr hs
  | resetFire t =>
    simp only [step]
    apply wf_reload
    have hr : ∀ u, ((redund s).tabs u).running = (s.tabs u).running := by
      intro u; unfold redund; split
      · simp only [mapTabs_tabs]; unfold onRedundant; split <;> rfl
      · rfl
    have hd : (redund s).dep = s.dep := by unfold redund; split <;> rfl
    have hh : (redund s).http = s.http := by unfold redund; split <;> rfl
    refine ⟨fun _ h => by simp [clearInst] at h, fun _ h => by simp at h, fun _ h => by simp at h,
      fun w hw => ?_, fun _ _ h => by simp at h, fun a x hx => ?_, fun _ _ h => by simp [clearInst] at h,
      fun u => ?_⟩
    · have : (redund s).rW = s.rW := by unfold redund; split <;> rfl
      simp only [clearInst] at hw; rw [this] at hw; simp only [clearInst, hd]; exact a4 w hw
    · simp only [clearInst, hh] at hx; exact a6 a x hx
    · simp only [clearInst_tabs]; rw [hr]; exact a8 u
  | chkEval t =>
    simp only [step]; split
    · have h1 : Wf E (updT t (fun x => { x with chk := none }) s) := by wf_fr hs
      split
      · exact wf_showBtn h1 t _
      · exact h1
    · exact hs
  | instFire t =>
    have h1 : Wf E (updT t (fun x => { x with instQ := none }) s) := by wf_fr hs
    simp only [step]; split
    · split
      · exact wf_showBtn h1 t _
      · exact h1
    · exact h1
  | forceStart t =>
    simp only [step]
    refine ⟨a1, a2, a3, fun w hw => ?_, a5, a6, a7, fun u => ?_⟩
    · simp only [updT_rW] at hw; exact a3 w hw
    · simp only [updT_tabs, rClear_tabs]; split
      · exact a8 u
      · exact a8 u
  | rPutJs =>
    simp only [step]; split
    · rename_i w hw
      refine ⟨a1, a2, a3, a4, fun u q hq => ?_, a6, a7, a8⟩
      simp only [] at hq; split at hq
      · rename_i hu; subst hu; cases hq
        refine ⟨a4 _ hw, ⟨_, rfl⟩, ?_⟩
        simp only []
        cases hc : s.cache u with
        | none => exact ⟨_, rfl⟩
        | some q => exact (a5 u q hc).2.2
      · exact a5 u q hq
    · exact hs
  | rPutWasm =>
    simp only [step]; split
    · rename_i w hw
      refine ⟨a1, a2, a3, a4, fun u q hq => ?_, a6, a7, a8⟩
      simp only [] at hq; split at hq
      · rename_i hu; subst hu; cases hq
        refine ⟨a4 _ hw, ?_, ⟨_, rfl⟩⟩
        simp only []
        cases hc : s.cache u with
        | none => exact ⟨_, rfl⟩
        | some q => exact (a5 u q hc).2.1
      · exact a5 u q hq
    · exact hs
  | rNet a b =>
    simp only [step]; split
    · split
      · cases a <;> wf_fr hs
      · exact wf_rFailed hs
    · exact hs
  | rFail => exact wf_rFailed hs
  | forceDone t =>
    have h1 : Wf E (updT t (fun x => { x with force := false }) s) := by wf_fr hs
    exact wf_reload h1 t true
  | _ => (try simp only [step]); (repeat' split) <;> wf_fr hs

theorem wf_reachable {E : Env} {s : State} (h : Reachable E s) : Wf E s := by
  induction h with
  | init =>
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [init] <;> exact ⟨⟨0, rfl⟩, ⟨0, rfl⟩⟩
  | fresh d =>
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [initFresh, init]
    · exact ⟨d, rfl⟩
    · exact ⟨⟨d, rfl⟩, ⟨d, rfl⟩⟩
  | step e _ he ih => exact wf_step ih he

/-- With Force update too, every cache holds some build's index.js and some
    build's em.wasm, and only deployed builds have a cache. -/
theorem cache_holds_builds {E : Env} {s : State} (h : Reachable E s) {v : Nat} {p : Nat × Nat}
    (hc : s.cache v = some p) : v ≤ s.dep ∧ (∃ b, p.1 = E.C .js b) ∧ (∃ b, p.2 = E.C .wasm b) :=
  (wf_reachable h).2.2.2.2.1 v p hc

/-! ### No double download

A new install's lookup of an asset takes a copy already held whenever one
has the manifest's digest: in any `dingbat-*` cache, whatever build and
whichever design wrote it, or in the HTTP cache, which a first visit's page
filled before it registered (`first_visit_downloads_nothing_twice`). An asset
is marked for download only by a lookup that found none, and downloaded at
most once. What the lookup sees is what is held at that moment: the code
reads each source one `await` apart, so a copy that arrives or goes during
the lookup may be missed and downloaded; never kept wrong. -/

theorem lookup_takes_held {E : Env} {s : State} (h : Reachable E s) {a : Asset} {m : Nat}
    (hm : s.man = some m)
    (held : (∃ u p, s.cache u = some p ∧ E.H (pick a p) = E.H (E.C a m)) ∨
            (∃ x, s.http a = some x ∧ E.H x = E.H (E.C a m))) :
    ∃ x, (step E s (.nLook a)).slot a = .have x ∧ E.H x = E.H (E.C a m) := by
  have hb : ∃ x, heldBytes E s a m = some x := by
    unfold heldBytes; simp only []
    split
    · exact ⟨_, rfl⟩
    · rename_i hn
      rw [List.find?_eq_none] at hn
      rcases held with ⟨u, p, hp, hok⟩ | ⟨x, hx, hok⟩
      · exfalso
        have hu := ((wf_reachable h).2.2.2.2.1 u p hp).1
        apply hn (pick a p)
        · simp only [List.mem_filterMap, List.mem_range, Option.map_eq_some_iff]
          exact ⟨u, by omega, p, hp, rfl⟩
        · simp [hok]
      · rw [hx]; simp [hok]
  obtain ⟨x, hx⟩ := hb
  refine ⟨x, ?_, heldBytes_ok hx⟩
  simp [step, hm, hx, setSlot]

section slotlemmas
variable (E : Env) (s : State) (v : Nat) (t : Bool) (auto : Bool)
@[simp] theorem installed_slot : (installed v s).slot = fun _ => .none := by
  unfold installed; simp only []; split <;> split <;> rfl
@[simp] theorem installFailed_slot : (installFailed v s).slot = fun _ => .none := rfl
@[simp] theorem startInst_slot : (startInst s).slot = fun _ => .none := rfl
@[simp] theorem clearInst_slot : (clearInst s).slot = fun _ => .none := rfl
@[simp] theorem reload_slot : (reload E t auto s).slot = s.slot := by
  unfold reload; generalize serve E s = sv; obtain ⟨c, bb, p⟩ := sv; rfl
@[simp] theorem showBtn_slot : (showBtn t v s).slot = s.slot := rfl
@[simp] theorem activate_slot : (activate v s).slot = s.slot := rfl
@[simp] theorem rFailed_slot : (rFailed s).slot = s.slot := rfl
@[simp] theorem rClear_slot : (rClear s).slot = s.slot := rfl
@[simp] theorem setStaged_slot (a : Asset) (b : Nat) : (setStaged s a b).slot = s.slot := by
  cases a <;> rfl
end slotlemmas

theorem updCheck_slot_net {s : State} {a : Asset} (h : (updCheck s).slot a = .net) : s.slot a = .net := by
  unfold updCheck at h; split at h
  · simp at h
  · exact h

theorem applyStart_slot_net {E : Env} {s : State} {t : Bool} {a : Asset}
    (h : (applyStart E t s).slot a = .net) : s.slot a = .net := by
  unfold applyStart at h; simp only [] at h
  split at h
  · simpa using h
  · split at h
    · simpa using updCheck_slot_net (s := updT t _ { s with intents := s.intents + 1 }) (by simpa using h)
    · simpa using h

/-- Only a lookup that found no held copy with the right bytes marks an
    asset for download. -/
theorem net_only_after_a_miss {E : Env} {s : State} {e : Event} {a : Asset}
    (h : (step E s e).slot a = .net) :
    s.slot a = .net ∨ (e = .nLook a ∧ ∃ m, s.man = some m ∧ heldBytes E s a m = none) := by
  cases e with
  | nLook a' =>
    simp only [step] at h
    split at h
    · rename_i m hm
      split at h
      · simp only [setSlot] at h; split at h
        · cases h
        · exact Or.inl h
      · rename_i hn
        simp only [setSlot] at h; split at h
        · rename_i ha; subst ha; exact Or.inr ⟨rfl, m, hm, hn⟩
        · exact Or.inl h
    · exact Or.inl h
  | nNet a' b =>
    simp only [step] at h; left
    split at h
    · split at h
      · simp only [setSlot] at h; split at h
        · cases h
        · exact h
      · simp at h
    · exact h
  | browserCheck => exact Or.inl (updCheck_slot_net (by simpa [step] using h))
  | updClick t =>
    simp only [step] at h; split at h
    · exact Or.inl h
    · exact Or.inl (applyStart_slot_net h)
  | confirm t => exact Or.inl (applyStart_slot_net (by simpa [step] using h))
  | newerApply t =>
    exact Or.inl (by simpa using applyStart_slot_net (s := updT t _ s) (by simpa [step] using h))
  | resetFire t => simp [step] at h
  | regResolve t =>
    simp only [step] at h; split at h
    · exact Or.inl h
    · split at h
      · simp at h
      · exact Or.inl h
  | _ =>
    left
    simp only [step] at h
    (repeat' split at h) <;> simp_all <;> (try (cases ‹Asset› <;> simp_all))

/-- A new install downloads each asset at most once: the download leaves it
    in hand (or fails the install). -/
theorem downloaded_once {E : Env} {s : State} {a : Asset} {b : Nat} (he : en E s (.nNet a b) = true) :
    (step E s (.nNet a b)).slot a ≠ .net ∧ en E (step E s (.nNet a b)) (.nNet a b) = false := by
  have hi : s.installing.isSome = true := by
    simp only [en, newInst, Bool.and_eq_true] at he; obtain ⟨⟨⟨h1, _⟩, _⟩, _⟩ := he
    split at h1 <;> simp_all
  have hm : s.man.isSome = true := by simp only [en, Bool.and_eq_true] at he; exact he.1.1.2
  obtain ⟨v, hv⟩ := Option.isSome_iff_exists.mp hi
  obtain ⟨m, hm⟩ := Option.isSome_iff_exists.mp hm
  have hne : (step E s (.nNet a b)).slot a ≠ .net := by
    simp only [step, hv, hm]; split
    · simp [setSlot]
    · simp
  refine ⟨hne, ?_⟩
  simp only [en]
  cases hs : (step E s (.nNet a b)).slot a <;> simp_all

/-! ### Liveness: a stable deploy installs

From any reachable state with a worker active and the deployed build neither
active nor waiting, some run without a deploy (each source answering the
deployed build) ends with the deployed build waiting over a cache holding
exactly its bytes: an install under way is failed first, then the browser's
update check starts the deployed build's install, of either design. With
no worker at all (after a full reset) the page's registration installs
instead; that path is the first visit's (`first_visit_downloads_nothing_twice`). -/

def Leads (E : Env) (s t : State) : Prop := ∃ es : List Event, (∀ e ∈ es, e ≠ .deploy) ∧ run E s es = some t

theorem leads_refl (E : Env) (s : State) : Leads E s s := ⟨[], by simp, rfl⟩

theorem leads_step {E : Env} {s : State} (e : Event) (he : en E s e = true) (hd : e ≠ .deploy) :
    Leads E s (step E s e) := ⟨[e], by simp [hd], by simp [run, he]⟩

theorem run_append (E : Env) (s : State) (xs ys : List Event) :
    run E s (xs ++ ys) = (run E s xs).bind (fun t => run E t ys) := by
  induction xs generalizing s with
  | nil => rfl
  | cons e es ih => simp only [List.cons_append, run]; split <;> simp [ih]

theorem leads_trans {E : Env} {s t u : State} (h1 : Leads E s t) (h2 : Leads E t u) : Leads E s u := by
  obtain ⟨xs, hx, rx⟩ := h1
  obtain ⟨ys, hy, ry⟩ := h2
  refine ⟨xs ++ ys, fun e he => ?_, by rw [run_append, rx]; simpa using ry⟩
  rcases List.mem_append.mp he with h | h
  · exact hx e h
  · exact hy e h

/-- What the rest of the install reads, kept by a lookup or a download. -/
def Same (X Y : State) : Prop :=
  Y.installing = X.installing ∧ Y.man = X.man ∧ Y.cache = X.cache ∧ Y.active = X.active ∧
  Y.dep = X.dep ∧ Y.committed = X.committed

theorem same_refl (X : State) : Same X X := ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- A new install's asset gets into hand: a held copy, or its download. -/
theorem look_gets {E : Env} (hH : Injective E.H) {X : State} {d : Nat} (a : Asset)
    (hi : X.installing = some d) (hn : E.newGen d = true) (hm : X.man = some d)
    (hs : X.slot a = .none) (hdep : d ≤ X.dep) :
    ∃ Y, Leads E X Y ∧ Same X Y ∧ Y.slot a = .have (E.C a d) ∧ (∀ a', a' ≠ a → Y.slot a' = X.slot a') := by
  have en1 : en E X (.nLook a) = true := by simp [en, newInst, hi, hn, hm, hs]
  let Y := step E X (.nLook a)
  have l1 : Leads E X Y := leads_step _ en1 (by simp)
  cases hb : heldBytes E X a d with
  | some x =>
    have hx : x = E.C a d := hH _ _ (heldBytes_ok hb)
    refine ⟨Y, l1, ?_, ?_, ?_⟩
    · refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [Y, step, hm, hb]
    · simp [Y, step, hm, hb, setSlot, hx]
    · intro a' ha'; simp [Y, step, hm, hb, setSlot, ha']
  | none =>
    have hY : Y.slot a = .net := by simp [Y, step, hm, hb, setSlot]
    have en2 : en E Y (.nNet a d) = true := by
      simp [en, newInst, Y, step, hm, hb, setSlot, hi, hn, hdep]
    let Z := step E Y (.nNet a d)
    refine ⟨Z, leads_trans l1 (leads_step _ en2 (by simp)), ?_, ?_, ?_⟩
    · refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [Z, Y, step, hm, hb, hi]
    · simp [Z, Y, step, hm, hb, hi, setSlot]
    · intro a' ha'; simp [Z, Y, step, hm, hb, hi, setSlot, ha']

theorem stable_deploy_installs {E : Env} (hH : Injective E.H) {s : State}
    (ha : s.active.isSome = true) (hna : s.active ≠ some s.dep) (hnw : s.waiting ≠ some s.dep) :
    ∃ t, Leads E s t ∧ t.dep = s.dep ∧ t.waiting = some s.dep ∧ t.cache s.dep = some (E.bytes s.dep) := by
  obtain ⟨w, hw⟩ := Option.isSome_iff_exists.mp ha
  -- an install under way fails first
  obtain ⟨s1, l1, i1, a1, w1, d1⟩ : ∃ s1, Leads E s s1 ∧ s1.installing = none ∧ s1.active = s.active ∧
      s1.waiting = s.waiting ∧ s1.dep = s.dep := by
    cases hi : s.installing with
    | none => exact ⟨s, leads_refl E s, hi, rfl, rfl, rfl⟩
    | some v =>
      refine ⟨step E s .installFail, leads_step _ (by simp [en, hi]) (by simp), ?_, ?_, ?_, ?_⟩ <;>
        simp [step, hi, installFailed, clearInst]
  -- the browser's update check starts the deployed build's install
  obtain ⟨s2, l2, i2, d2, a2, m2, sl2, k2, p2, j2, w2⟩ : ∃ s2, Leads E s1 s2 ∧
      s2.installing = some s.dep ∧ s2.dep = s.dep ∧ s2.active = s.active ∧ s2.man = none ∧
      (∀ a, s2.slot a = .none) ∧ s2.committed = false ∧ s2.probe0 = none ∧ s2.stageJs = none ∧
      s2.stageWasm = none := by
    have hs2 : step E s1 .browserCheck = startInst s1 := by
      show updCheck s1 = startInst s1
      have c : (s1.installing.isNone && s1.active.isSome && s1.active != some s1.dep &&
          s1.waiting != some s1.dep) = true := by
        rw [i1, a1, w1, d1]; simp [ha, hna, hnw]
      unfold updCheck; simp only [c, ↓reduceIte]
    refine ⟨step E s1 .browserCheck, leads_step _ rfl (by simp), ?_⟩
    rw [hs2]; simp [startInst, clearInst, d1, a1]
  have l12 := leads_trans l1 l2
  by_cases hg : E.newGen s.dep = true
  · -- the new design: the manifest, each asset held or downloaded, commit, check
    obtain ⟨s3, l3, i3, m3, d3, a3, sl3, k3⟩ : ∃ s3, Leads E s2 s3 ∧ s3.installing = some s.dep ∧
        s3.man = some s.dep ∧ s3.dep = s.dep ∧ s3.active = s.active ∧ (∀ a, s3.slot a = .none) ∧
        s3.committed = false := by
      refine ⟨step E s2 (.nManifest s.dep), leads_step _ ?_ (by simp), ?_⟩
      · simp [en, newInst, i2, hg, m2, d2]
      · simp [step, i2, d2, a2, sl2, k2]
    obtain ⟨s4, l4, ⟨i4, m4, c4, a4, d4, k4⟩, j4, o4⟩ :=
      look_gets hH .js i3 hg m3 (sl3 _) (by omega)
    obtain ⟨s5, l5, ⟨i5, m5, c5, a5, d5, k5⟩, w5, o5⟩ :=
      look_gets hH .wasm (i4.trans i3) hg (m4.trans m3) (by rw [o4 .wasm (by simp)]; exact sl3 _)
        (by rw [d4, d3]; omega)
    have j5 : s5.slot .js = .have (E.C .js s.dep) := by rw [o5 .js (by simp)]; exact j4
    have k5' : s5.committed = false := by rw [k5, k4, k3]
    have i5' : s5.installing = some s.dep := by rw [i5, i4, i3]
    have a5' : s5.active = some w := by rw [a5, a4, a3, hw]
    have d5' : s5.dep = s.dep := by rw [d5, d4, d3]
    obtain ⟨s6, l6, i6, a6, d6, c6, k6⟩ : ∃ s6, Leads E s5 s6 ∧ s6.installing = some s.dep ∧
        s6.active = some w ∧ s6.dep = s.dep ∧ s6.cache s.dep = some (E.bytes s.dep) ∧
        s6.committed = true := by
      refine ⟨step E s5 .nCommit, leads_step _ ?_ (by simp), ?_⟩
      · simp [en, newInst, i5', hg, j5, w5, k5', Slot.isHave]
      · simp [step, i5', j5, w5, a5', d5', Env.bytes]
    refine ⟨step E s6 .nCheck, leads_trans l12 (leads_trans l3 (leads_trans l4 (leads_trans l5
      (leads_trans l6 (leads_step _ ?_ (by simp)))))), ?_, ?_, ?_⟩
    · simp [en, newInst, i6, hg, k6]
    · simp only [step, i6, c6, Option.isSome_some, ↓reduceIte, installed]
      split <;> simp [mapTabs, clearInst, a6, d6]
    · simp only [step, i6, c6, Option.isSome_some, ↓reduceIte, installed]
      split <;> simp [mapTabs, clearInst, a6]
    · simp only [step, i6, c6, Option.isSome_some, ↓reduceIte, installed]
      split <;> simp [mapTabs, clearInst, a6, c6]
  · -- the old design: probe, both downloads from the origin, the tail
    have hg' : E.newGen s.dep = false := by simpa using hg
    let s3 := { s2 with probe0 := some s2.dep, stageJs := some s2.dep, stageWasm := some s2.dep }
    have l3 : Leads E s2 (step E s3 .installEnd) := by
      refine leads_trans (leads_step .probeFirst ?_ (by simp)) (leads_trans (leads_step .fetchJs ?_ (by simp))
        (leads_trans (leads_step .fetchWasm ?_ (by simp)) (leads_step .installEnd ?_ (by simp))))
      · simp [en, oldInst, i2, hg', p2]
      · simp [en, oldInst, step, i2, hg', j2]
      · simp [en, oldInst, step, i2, hg', w2]
      · simp [en, oldInst, step, i2, hg']
    refine ⟨step E s3 .installEnd, leads_trans l12 l3, ?_, ?_, ?_⟩ <;>
      simp only [s3, step, i2, d2, beq_self_eq_true, Bool.and_self, ↓reduceIte, installed] <;>
      split <;> simp_all [mapTabs, clearInst, Env.bytes]

end WebState.ServiceWorker
