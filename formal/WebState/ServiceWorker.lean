-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/index.js: applyUpdate beginUpdating checkForUpdate endUpdating failUpdating forceUpdate fullResetReload maybeCheckForUpdate probeBuilds refuseState registerServiceWorker reloadAfterUpdate showUpdateButton startForceUpdate updateForNewerState on:visibilitychange
-- @models web/sw.js: hex sha256 digest fetchManifest fetchFresh verified assetCaches heldCopy tell tracker assetBytes countInto manifestResponse collect commit liveName setLive collectDev install dropCaches dropLater reinstall cached lazyFrom on:activate on:fetch on:install on:message

/-
# Service worker, update check and update flow (web/sw.js, web/index.js)

Brought to the sw-limits design (branch sw-limits, on 0b7f1b57), then to
the page side of branch update-ui (febce5a0, b22ed55c, 2243d6d9, on
42a555d5): sw.js is named by function below, index.js's line numbers are at
2243d6d9. The
update flow is the one 5901c517 fixed (the `regress_*` theorems below), with
the update a too-new save state asks for (df47a452), e3dbc604's registration
timing, and update-ui's card, wingbeat and Force update failure (below).

## The page side of an update (update-ui)

* **The shield** (`shield`: #updating not hidden, from beginUpdating to
  endUpdating or the reload) holds every tap: the Update button, the
  confirm modal and the Force update row are disabled under it. A game
  cannot be started while `appUpdating` (launchRom, handleRomFile,
  handleDroppedFile return at once): `gameOn` is disabled then
  (`no_game_start_while_updating`). The guard sits in GameLifecycle's
  functions, which that model anchors.
* **Every update reload goes through reloadAfterUpdate**, which may wait up
  to one wingbeat of the logo's flap (667 ms) first: whenever the home
  brand is on screen, under any update. The model makes every such reload a
  pending one (`pend`), landed by its own later step (`landReload`), with
  any other step allowed between; the immediate reload is that step with
  nothing between. The five triggers: controllerchange for this tab's own
  update (with `refreshing` set, so a second controllerchange in the wait
  adds nothing), applyUpdate's `updateActivated` path, Force update's
  ok:true, and the end of fullResetReload (`resetFire`, which leaves the
  tab waiting). controllerchange in a tab with no game and no update of its
  own still reloads at once.
* **Force update** (startForceUpdate, `startForce`): appUpdating, the
  shield, then forceUpdate: no controller takes fullResetReload; a
  controller's reply ok:false (`rFail`, or the reinstall's own check failing
  in `rNet`) throws to startForceUpdate's catch (`failTab`): with an
  update's reload already coming in the tab (`coming`: updateReloadComing,
  set by applyUpdate and by reloadAfterUpdate, never cleared) it goes on
  updating (beginUpdating("update"): shield up, appUpdating on); else the
  failed card (`failed`), appUpdating back to false and nothing touched,
  however many times in a row and online or not. No reply and no progress
  for forceSilenceMs (`rStop`: the worker stopped at any point) takes
  fullResetReload as before. The card's Try Again (`forceRetry`) starts
  again; Close (`failClose`) takes the shield down.
* **Progress messages** (sw.js `tell`, `tracker`, `assetBytes`,
  `countInto`; the manifest's `sizes`) add no state: they read a clone of
  each download's body and post to pages; no cache is read or written by
  them and no control flow depends on them. On the page they fill the card's
  bar and re-arm forceUpdate's silence timer, which the model does not time
  (`rStop` may fire whenever a Force update is in flight): one more message
  only makes a timeout later, which is a run the model already has.
* Not modelled: the card's half-second delay for Update and the bat's
  animation (no state a property reads); a key or pad press reaching
  something other than launchRom under the shield; a slow worker that
  outlives the silence timer and commits after the page's full reset (as
  before, `rStop` ends the run).

## Three designs side by side

A worker's install runs the code of its own build, so a browser holds
workers of every design still in the wild while a change rolls out.
`Env.N` is the first build with the manifest, `Env.M` the first of this
design (`Env.curGen`: both); builds below N are *old*, the rest *new*, and
the new ones from M on are *current*. The page side (`skipWaiting`, the
`reinstall`/`reinstalled` messages, controllerchange, checkForUpdate's regex
on `CACHE_VERSION = "..."`) is the same in all three, so any page under any
worker runs the same protocol; the model's pages are build-agnostic and
every pairing is reachable (`old_page_force_under_new_worker`,
`old_worker_force_then_new_worker_reuses`, `old_page_force_under_cur_worker`,
`v1_worker_force_then_cur_worker_reuses`, `old_worker_ds_core_carried_over`).

*Old* (before 0b7f1b57): `installAssets` probes version.txt under a URL no
edge has seen, fetches every asset under `?v=<CACHE_VERSION>` with
`cache: "reload"`, then checks the cached version.txt and a second probe;
unless all three name CACHE_VERSION the install fails. Its correctness rests
on fresh URLs reaching the origin's current build (`fetchJs`/`fetchWasm`
read `dep`) and on deploys only moving forward. Force update (`reinstall`)
is the same bracketed download into a staging cache, then one put per asset
into the live cache.

*New* (0b7f1b57): `install` fetches asset-manifest.json fresh
(`fetchManifest`; refused unless its version is CACHE_VERSION), then
`collect` takes each asset from the first copy whose bytes hash to the
manifest's digest (`heldCopy`: every dingbat-* cache, then the HTTP cache
through only-if-cached), else downloads it (`fetchFresh`, under `?v=`) and
checks that download too; then `commit` puts them all into `dingbat-<v>` and
checks the cache under that name still holds every one. Force update
downloads every asset under a nonce, checks each against the manifest the
origin serves now (any build), and puts them into the live cache one by one.
Its fetch handler matches the exact URL (a load with a query string misses)
and keeps any DS core file the network answers, unchecked.

*Current* (sw-limits): the install as 0b7f1b57's, plus the DS core files
(LAZY: nds.js, nds.wasm, gpu3d.js) held with the manifest's `lazy` digests,
never downloaded, into an emptied cache that also keeps the manifest. The
fetch handler answers every load of the app with "./" whatever its query
(`shell`), serves a DS core file from the live cache or downloads it and
keeps it only when it hashes to that cache's manifest (`lazyFrom`). Force
update downloads into a cache of its own (`dingbat-<v>-<nonce>`), the DS
core files the live cache holds too, and once that holds everything moves
the pointer (`setLive`: one put into `dingbat-live`) the fetch handler reads
the live cache's name from (`liveName`, read again by a worker started
cold); the old cache goes after a grace (`dropLater`).

The registration (index.js `registerServiceWorker` 96): a controlled page
registers at load, an uncontrolled one (a first visit) only once its core is
in (19574), so its HTTP cache holds em.wasm by the time the install looks.

## What is modelled

* A build is a version number; `dep` is what the origin serves now, and a
  deploy bumps it. Two assets stand for all of them: index.js (with
  index.html, the shell, and version.txt) and em.wasm. Their bytes are
  `Env.C a b`, a parameter: any asset may be unchanged between builds (an
  index.js-only update keeps em.wasm's bytes). The DS core is two files,
  nds.js (with gpu3d.js) and nds.wasm, with bytes `Env.L l b`. `Env.H` is the
  SHA-256 digest, a parameter too; the consistency theorems assume it
  injective (`Injective`), the one assumption the manifest designs add. The
  manifest of build m lists `H (C a m)` and, from this design on,
  `H (L l m)`.
* `cache v` is the cache serving worker v's fetches: `dingbat-<v>`, or for
  this design the one v's pointer names. A cache of this design keeps the
  manifest it was filled under (`cman v`, its build: a Force update's can be
  another build than v) and holds DS core files (`lazy v`); an older
  design's holds DS core files as its fetch handler kept them. The HTTP
  cache holds bytes per asset: a page booted off the network puts index.js
  there and its em.wasm once its core is in (`coreLoaded`); `httpFill` puts
  any older or current build's bytes there at any time (a stale edge,
  another tab), `httpEvict` drops one: what the install finds there is
  anything at all.
* A new install's manifest may come from any build up to `dep` (a stale
  edge cannot make it pass, its version is checked); its downloads may get
  any build up to `dep` (`nNet a b`): the new designs' consistency does not
  rest on fresh URLs reaching the origin. Its lookup (`nLook`, and for the DS
  core `nLookLz`) is one event that reads every cache (and, for an asset,
  the HTTP cache) at once; the code reads them one `await` apart, so the
  theorems are about copies held throughout the lookup (one that appears
  mid-lookup can be missed, one that goes can be missed, and either way the
  asset is downloaded, or the DS core file left to its lazy fetch, never kept
  wrong). The code reads the caches named when `collect` starts; the model
  reads those there at the lookup.
* `commit`'s puts are one event (`nCommit`; this design's into an emptied
  cache, with its pointer) and its presence check another (`nCheck`).
  Another worker's activation (atomic here: `activate`) can land between
  them and delete the cache; then the check fails the install
  (`regress_activation_mid_commit_fails_install`). In a browser the
  activation's `caches.keys()` and its `caches.delete()` are two steps, and
  a commit and check landing between them is not caught: that window is
  not modelled (FINDINGS, 2026-11-09). Nor is the old design's version of
  the race: its `installEnd` writes the cache in one event here, while its
  code puts each asset as it arrives into a Cache handle held across the
  whole download, which an activation anywhere in it orphans.
* This design's Force update: its downloads (`rMan`, `rNet`, `rNetLz`), the
  check (`rVerify`), the puts into its own cache (`rPutJs`, `rPutWasm`: they
  change nothing a fetch reads), then the pointer (`rCommit`: `cache w`,
  `cman w` and `lazy w` become the new cache's at once). `rFail` is a
  download or check failing (the reply ok:false) and `rStop` the worker
  stopped anywhere in the run (no reply, no progress: the page's silence
  timer); both are enabled at every point. A cache it left part-way is an orphan no fetch reads
  (dropped by the next Force update or activation), not modelled as a
  lookup source: one source fewer, never a wrong copy.
* A DS core fetch in a worker of this design: a hit (`lzHit`), or a miss that
  reads the cache's manifest (`lzStart`) and then a download (`lzNet l b put`:
  any build up to `dep`, the bare URL or the retry under a fresh one, each
  one event), checked against that manifest; kept only in the cache that
  manifest came from, and maybe not at all (`put`). An older worker's
  (`lzOld`) keeps whatever arrives.
* Two tabs of the app (`Bool`-indexed), each the current page instance: the
  bytes it booted (`running`), whether it is controlled and by which worker
  version, the index.js flags, and its in-flight continuations.
* `reload t` replaces tab t's page: it boots from the active worker's cache
  (or the network when there is no worker or the entry is missing). `navQ t`
  is a load with a query string: this design's worker serves it as `reload`
  (`serveQ`); an older one takes the shell off the network.

## Abstractions

* `register()`'s promise and the updatefound/statechange listeners: the
  listener is attached when `register()` resolves (`regResolve`); the
  `installed` statechange is a queued event per tab (`instFire`).
* The old `installAssets`'s tail is one event, `installEnd`.
* `fullResetReload`'s four awaits are one event (`resetFire`). Its
  unregister makes the installing worker redundant, which another tab's
  applyUpdate watching it sees (`onRedundant`).
* `update()` rejecting goes to `fullResetReload`. A reinstall that fails
  replies ok:false to every tab waiting on it (`rFail`, `rFailed`: each
  tab's startForceUpdate catch, `failTab`); one that says nothing leaves
  them to fullResetReload (`rStop`, `rSilent`). Two tabs' Force updates share one download (`rProbe`,
  `rMan`, `rsJs`, ...; this design's `reinstalling`), run by the worker that
  was active when the last one started (`rW`).
* A page's boot is one event. sw.js keeps that true across this design's
  pointer move: each page's later requests go to the cache its navigation
  came from (`pins`), which stays for a grace after the move (`dropLater`).
  Across an activation's claim it is not (another worker's cache serves the
  rest of a boot in progress), in every design alike.
* `updateForNewerState` is two events, `newerStart` and `newerApply`.
* A page's own boot off the network is taken as one build (`dep`'s): a site
  without a worker has the same exposure, so it is not the worker's.
* Save flushing on reload is `pagehide`'s; this file only tracks whether a
  tab was reloaded mid-game without its own user having agreed
  (`forcedMidGame`).
* Not modelled: Chromium's reload after Force update can run the index.js
  the page before it ran from its memory cache (same worker, a copy younger
  than its max-age); found in the e2e, and on 0b7f1b57's sw.js too.
* Not modelled: a dev build (`CACHE_VERSION === "dev"`, no manifest); the
  HTTP cache as a source of DS core files; the DS core a page has loaded
  (what is proved is what the worker serves it).

## Results

Proved, for every interleaving and all three designs side by side, the
wingbeat's wait before every update reload included: with nothing asked, no
tab is reloaded at all (`no_reload_without_a_click`); the button shows at
most once per page (`shows_at_most_once`); an applyUpdate watching an
install always has that install to wait on (`watching_has_install`); no game
starts while an update is under way (`no_game_start_while_updating`); a
Force update's failure, however often, changes no cache, worker or page, and
when it shows the failed card leaves nothing to reload
(`force_failure_changes_nothing`, `force_failure_no_reload`); no tab is
reloaded mid-game unless its own user asked (`no_forced_midgame`), and every
pending reload is its own update's (`pending_is_asked`).

With H injective, and with this design's Force update in, stopped wherever:
every cache of this design holds exactly one build, its kept manifest's, DS
core files included (`cache_is_one_build`); every DS core file it serves is
that build's (`lazy_served_is_its_build`); and no page boots two builds
(`no_mixed_boot`), the only steps left out being an older worker's Force
update and its answer to a query navigation; a reload that waits for the
wingbeat boots one build whatever lands in the wait
(`pending_reload_one_build`, `wingbeat_wait_spans_activation`). A load with any query string is
a bare load under this design (`navigation_query_is_the_shell`) and never
goes to the network while a cache is live (`navigation_never_net_while_live`).
This design's Force update leaves every cache as it was until the pointer
moves (`force_leaves_live_cache_until_pointer`). Without any Force update,
every cache `dingbat-<v>` holds exactly build v's bytes
(`cache_is_its_build`, `no_mixed_boot_without_force`). With an older design's
Force update too, every cache holds builds' bytes (`cache_holds_builds`) and
a reinstall's download only goes live as one build (`force_stage_one_build`).

No double download: a new install's lookup takes a held copy whenever one has
the right bytes (`lookup_takes_held`, `lookupLz_takes_held`), an asset is
marked for download only by a lookup that found none
(`net_only_after_a_miss`), and downloaded at most once (`downloaded_once`); a
DS core file is never downloaded by an install (`lazy_never_downloaded`).
Liveness: from any reachable state with a worker active, a deploy-free run
installs the deployed build whole (`stable_deploy_installs`).

Was refuted, now regressions: Force update's commit into the live cache
(`regress_force_update_serves_half_written_cache`), a query navigation's
mixed boot (`regress_query_navigation_after_deploy`), an unchecked DS core
file (`regress_tampered_lazy_refused`). The older designs keep doing all
three until their worker updates (`legacy_*`).

Was refuted on update-ui, fixed in 2243d6d9:
`bug_force_failure_mid_update_reloads_midgame` (a Force update's failure
took appUpdating down under the same tab's own Update, so a game started
after Close was reloaded away) is `regress_force_failure_mid_update_keeps_updating`
and `regress_force_failure_mid_update_no_close`; its milder form, a failure
inside the wingbeat's wait after another tab's claim, is
`regress_force_failure_in_wingbeat_wait` and `..._lands`. Traces of the new
behaviour: `force_failure_close_then_play`, `force_failure_never_resets`,
`no_game_behind_force_update`, `wingbeat_wait_spans_activation`.
-/
namespace WebState.ServiceWorker

/-! ## The environment: bytes, digests, which builds are new -/

inductive Asset where
  | js    -- index.js (and version.txt)
  | wasm  -- em.wasm
  deriving DecidableEq, Repr

/-- A file of the DS core (sw.js LAZY): nds/nds.js (with nds/gpu3d.js, which
    behaves the same) and nds/nds.wasm. -/
inductive Lz where
  | js
  | wasm
  deriving DecidableEq, Repr

structure Env where
  C : Asset → Nat → Nat   -- asset a's bytes in build b
  H : Nat → Nat           -- SHA-256 of some bytes
  N : Nat                 -- the first build whose sw.js uses the manifest
  M : Nat                 -- the first build with the pointer and the DS core's digests (sw-limits)
  L : Lz → Nat → Nat      -- DS core file l's bytes in build b

/-- The assumption the digest check rests on: different bytes, different
    digests. -/
def Injective (f : Nat → Nat) : Prop := ∀ x y, f x = f y → x = y

def Env.newGen (E : Env) (v : Nat) : Bool := decide (E.N ≤ v)
/-- This design (sw-limits): a manifest build (so its install is the manifest
    one) at or past `M`. -/
def Env.curGen (E : Env) (v : Nat) : Bool := decide (E.N ≤ v) && decide (E.M ≤ v)
def Env.bytes (E : Env) (b : Nat) : Nat × Nat := (E.C .js b, E.C .wasm b)

theorem Env.newGen_of_cur {E : Env} {v : Nat} (h : E.curGen v = true) : E.newGen v = true := by
  simp only [Env.curGen, Env.newGen, Bool.and_eq_true, decide_eq_true_eq] at *; simp [h.1]

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
  appUpdating : Bool := false        -- (377)
  refreshing  : Bool := false        -- (131)
  ready       : Bool := false        -- updateActivated (380)
  updAvail    : Bool := false        -- updateAvailable / button shown (161)
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
  pend        : Bool := false        -- reloadAfterUpdate's wingbeat timer set: location.reload() to come
  shield      : Bool := false        -- #updating not hidden (beginUpdating .. endUpdating): holds every tap
  failed      : Bool := false        -- its .failed card (failUpdating): Close and Try Again
  coming      : Bool := false        -- updateReloadComing: applyUpdate or reloadAfterUpdate began
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
  cache      : Nat → Option (Nat × Nat)  -- the cache serving v (dingbat-<v>, or the one v's
                                      --   pointer names) : (index.js bytes, em.wasm bytes)
  cman       : Nat → Option Nat       -- the manifest that cache keeps (this design): its build
  lazy       : Nat → Lz → Option Nat  -- the DS core files that cache holds
  lslot      : Lz → Option Nat        -- this design's install: the DS core copies it holds
  lzF        : Lz → Option (Nat × Nat)  -- a DS core fetch in flight in a worker of this design:
                                      --   (that worker, the build of the manifest it read)
  http       : Asset → Option Nat     -- the HTTP cache's copy of each asset
  skipQ      : Option Nat             -- skipWaiting posted to worker v
  rW         : Option Nat             -- the worker running the Force update
  rProbe     : Option Nat             -- old reinstall: the first version probe
  rMan       : Option Nat             -- new reinstall: the manifest's build
  rsJs       : Option Nat             -- reinstall: the build index.js's download came from
  rsWasm     : Option Nat             -- ... and em.wasm's
  rOk        : Bool                   -- reinstall: the download passed its check
  rJs        : Bool                   -- a reinstall has put index.js into its cache (the live
                                      --   one for older designs, its own for this one)
  rWasm      : Bool                   -- ... and em.wasm
  rsLz       : Lz → Option Nat        -- this design's reinstall: the DS core files downloaded again
  rFlip      : Bool                   -- this design's reinstall: the pointer moved
  tabs       : Bool → Tab
  intents    : Nat                    -- ghost: Update / Force update / a newer build's state accepted
  autoReloads : Nat                   -- ghost: reloads the app itself triggered
  forcedMidGame : Bool                -- ghost: a tab reloaded mid-game its user never agreed to
  mixedBoot  : Bool                   -- ghost: a page booted bytes other than the build it booted
                                      --   from (its cache's: the manifest it keeps, else its
                                      --   worker's own; or the deployed one off the network)
  dl         : Nat                    -- ghost: downloads by new installs
  lzBad      : Bool                   -- ghost: a worker of this design served a DS core file
                                      --   that is not its cache's build

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
  cman := fun v => if v = 0 && E.curGen 0 then some 0 else none
  lazy := fun _ _ => none
  lslot := fun _ => none
  lzF := fun _ => none
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
  rsLz := fun _ => none
  rFlip := false
  tabs := fun _ => { running := E.bytes 0, coreIn := true }
  intents := 0
  autoReloads := 0
  forcedMidGame := false
  mixedBoot := false
  dl := 0
  lzBad := false

/-- A first visit: build d deployed, no worker, no cache, both tabs booted
    off the network (index.js in the HTTP cache, the core still coming). -/
def initFresh (E : Env) (d : Nat) : State :=
  { init E with
    dep := d, active := none, cache := fun _ => none, cman := fun _ => none,
    http := fun a => if a = .js then some (E.C .js d) else none,
    tabs := fun _ => { running := E.bytes d, controlled := false, ctrlV := 0, hadController := false } }

def updT (t : Bool) (f : Tab → Tab) (s : State) : State :=
  { s with tabs := fun u => if u = t then f (s.tabs u) else s.tabs u }

def setSlot (f : Asset → Slot) (a : Asset) (y : Slot) : Asset → Slot :=
  fun b => if b = a then y else f b

def setHttp (f : Asset → Option Nat) (a : Asset) (x : Option Nat) : Asset → Option Nat :=
  fun b => if b = a then x else f b

/-- showUpdateButton (163). -/
def showBtn (t : Bool) (v : Nat) (s : State) : State :=
  updT t (fun x => { x with updAvail := true, promptV := some v,
                             shows := if x.updAvail then x.shows else x.shows + 1 }) s

/-- What a page boots with: (controller, the build it boots from, the bytes):
    the active worker's cache, else the network (sw.js, the fetch handler's
    fallback). A cache of this design keeps the manifest it was filled under,
    which names its build (a Force update's may be another build than the
    worker's); an older design's cache is its worker's build. -/
def serve (E : Env) (s : State) : Option Nat × Nat × (Nat × Nat) :=
  match s.active with
  | some v => match s.cache v with
    | some p => (some v, (s.cman v).getD v, p)
    | none => (some v, s.dep, E.bytes s.dep)
  | none => (none, s.dep, E.bytes s.dep)

/-- A load of the app with a query string (?2p, ?gpu3d=1). This design's
    worker answers it with "./" (`serve`, the same entry as a bare load). An
    older worker's matches the exact URL, misses, and takes the page shell
    (index.html, here with the js asset) off the network beside its cache's
    em.wasm. -/
def serveQ (E : Env) (s : State) : Option Nat × Nat × (Nat × Nat) :=
  match s.active with
  | some v =>
    if E.curGen v then serve E s
    else match s.cache v with
      | some q => (some v, v, (E.C .js s.dep, q.2))
      | none => (some v, s.dep, E.bytes s.dep)
  | none => serve E s

/-- A page boot of tab t from `sv` (controller, build, bytes). `auto`: the
    app called location.reload(). A page off the network leaves its index.js
    in the HTTP cache. -/
def bootFrom (E : Env) (t : Bool) (auto : Bool) (sv : Option Nat × Nat × (Nat × Nat)) (s : State) : State :=
  let x := s.tabs t
  match sv with
  | (c, b, p) =>
    let s := { s with
      forcedMidGame := s.forcedMidGame || (auto && x.game && !x.appUpdating),
      mixedBoot := s.mixedBoot || p != E.bytes b,
      autoReloads := if auto then s.autoReloads + 1 else s.autoReloads,
      http := match c with | none => setHttp s.http .js (some p.1) | some _ => s.http }
    updT t (fun _ => match c with
      | some v => { running := p, controlled := true, ctrlV := v, hadController := true }
      | none => { running := p, controlled := false, ctrlV := 0, hadController := false }) s

/-- A page (re)load of tab t at its bare URL. -/
def reload (E : Env) (t : Bool) (auto : Bool) (s : State) : State := bootFrom E t auto (serve E s) s

/-- clients.claim(): the tab is now controlled by worker v; controllerchange queued. -/
def claim (v : Nat) (x : Tab) : Tab := { x with controlled := true, ctrlV := v, ccQ := true }

/-- The `installed` statechange reaches a page that attached the listener; an
    applyUpdate watching worker v then posts skipWaiting (409). -/
def onInstalled (v : Nat) (x : Tab) : Tab :=
  let x := if x.regd then { x with instQ := some v } else x
  if x.applyK == .watch v then { x with applyK := .done } else x

/-- The `redundant` statechange: an applyUpdate watching worker v falls back to
    fullResetReload (413). -/
def onRedundant (v : Nat) (x : Tab) : Tab :=
  if x.applyK == .watch v then { x with applyK := .resetting } else x

def mapTabs (g : Tab → Tab) (s : State) : State := { s with tabs := fun u => g (s.tabs u) }

/-- activate (sw.js): delete the other caches (the DS core files and kept
    manifest inside them too), claim every tab. -/
def activate (v : Nat) (s : State) : State :=
  mapTabs (claim v)
    { s with active := some v,
             waiting := if s.waiting = some v then none else s.waiting,
             cache := fun u => if u = v then s.cache u else none,
             cman := fun u => if u = v then s.cman u else none,
             lazy := fun u => if u = v then s.lazy u else fun _ => none }

/-- Nothing installing, nothing staged. -/
def clearInst (s : State) : State :=
  { s with installing := none, probe0 := none, stageJs := none, stageWasm := none,
           man := none, slot := fun _ => .none, committed := false, lslot := fun _ => none }

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
    HTTP cache's (heldCopy). Caches exist only for deployed
    builds (`bounds_reachable`), so builds up to `dep` are all of them. -/
def heldBytes (E : Env) (s : State) (a : Asset) (m : Nat) : Option Nat :=
  let ok := fun x => E.H x == E.H (E.C a m)
  match ((List.range (s.dep + 1)).filterMap (fun u => (s.cache u).map (pick a))).find? ok with
  | some x => some x
  | none => match s.http a with
    | some x => if ok x then some x else none
    | none => none

/-- The first DS core file held on the device whose bytes hash to build m's
    digest: any dingbat-* cache's (heldCopy, through `collect`'s LAZY pass).
    The HTTP cache, which `heldCopy` also reads, is not modelled as a source
    of DS core files: one source fewer, never a wrong copy. -/
def heldLazy (E : Env) (s : State) (l : Lz) (m : Nat) : Option Nat :=
  ((List.range (s.dep + 1)).filterMap (fun u => s.lazy u l)).find? (fun x => E.H x == E.H (E.L l m))

def oldInst (E : Env) (s : State) : Bool :=
  match s.installing with | some v => !E.newGen v | none => false
def newInst (E : Env) (s : State) : Bool :=
  match s.installing with | some v => E.newGen v | none => false
def curInst (E : Env) (s : State) : Bool :=
  match s.installing with | some v => E.curGen v | none => false
def oldR (E : Env) (s : State) : Bool :=
  match s.rW with | some w => !E.newGen w | none => false
def newR (E : Env) (s : State) : Bool :=
  match s.rW with | some w => E.newGen w | none => false
def curR (E : Env) (s : State) : Bool :=
  match s.rW with | some w => E.curGen w | none => false
/-- The reinstall's commit is over: this design's moved the pointer, an older
    one's has put both assets into the live cache. -/
def rDone (E : Env) (s : State) : Bool := if curR E s then s.rFlip else s.rJs && s.rWasm

def staged (s : State) : Asset → Option Nat
  | .js => s.rsJs
  | .wasm => s.rsWasm

def setStaged (s : State) (a : Asset) (b : Nat) : State :=
  match a with
  | .js => { s with rsJs := some b }
  | .wasm => { s with rsWasm := some b }

def rClear (s : State) : State :=
  { s with rProbe := none, rMan := none, rsJs := none, rsWasm := none,
           rOk := false, rJs := false, rWasm := false, rsLz := fun _ => none, rFlip := false }

/-- A reinstall fails: the worker's "reinstalled" ok:false reply (forceUpdate
    throws; startForceUpdate's catch, 500). With an update's reload already
    coming in the tab (updateReloadComing), it goes on updating: the shield
    stays, appUpdating stays (beginUpdating("update")). Else the failed card,
    with everything as it was: appUpdating back to false, no cache touched,
    nothing to reload (failUpdating), however often it fails. -/
def failTab (x : Tab) : Tab :=
  if x.force then
    if x.coming then { x with force := false, failed := false, shield := true }
    else { x with force := false, appUpdating := false, failed := true }
  else x

def rFailed (s : State) : State := mapTabs failTab (rClear s)

/-- No reply and no progress message for forceSilenceMs (the worker stopped
    at any point of the run): every tab waiting on it takes fullResetReload. -/
def rSilent (s : State) : State :=
  mapTabs (fun x => if x.force then { x with force := false, applyK := .resetting } else x) (rClear s)

/-- startForceUpdate: appUpdating, the card (beginUpdating("force")), then
    forceUpdate: a controller re-downloads (the reply and the silence timer
    are later events); none takes fullResetReload. -/
def startForce (t : Bool) (s : State) : State :=
  let s := updT t (fun x => { x with appUpdating := true, shield := true, failed := false })
    { s with intents := s.intents + 1 }
  if (s.tabs t).controlled then updT t (fun x => { x with force := true }) { rClear s with rW := s.active }
  else updT t (fun x => { x with applyK := .resetting }) s

inductive Event where
  | deploy
  | browserCheck                 -- the browser re-fetches sw.js
  | probeFirst                   -- old install: the first probeVersion()
  | fetchJs                      -- old install: index.js?v= arrives (from the origin)
  | fetchWasm                    -- ... em.wasm?v=
  | installEnd                   -- old install's tail: version.txt check, second probe
  | installFail                  -- an asset fetch failed: worker redundant
  | nManifest (b : Nat)          -- new install: fetchManifest gets build b's manifest
  | nLook (a : Asset)            -- new install: heldCopy for asset a
  | nNet (a : Asset) (b : Nat)   -- new install: a's download (?v=) answers build b's bytes
  | nCommit                      -- new install: commit's puts
  | nCheck                       -- new install: commit's presence check
  | regResolve (t : Bool)        -- register().then (99)
  | coreLoaded (t : Bool)        -- the core is in (19574): an uncontrolled page registers now
  | httpFill (a : Asset) (b : Nat) -- the HTTP cache gets build b's copy of a
  | httpEvict (a : Asset)
  | instFire (t : Bool)          -- the queued `installed` statechange (104)
  | skipDeliver                  -- the waiting worker handles skipWaiting and activates
  | ccFire (t : Bool)            -- controllerchange handler (132)
  | userReload (t : Bool)        -- the user reloads / reopens the tab
  | gameOn (t : Bool) | gameOff (t : Bool)
  | updClick (t : Bool)          -- #update-btn (429)
  | confirm (t : Bool)           -- #update-confirm (438)
  | notNow (t : Bool)
  | applyResume (t : Bool)       -- applyUpdate after `await update()` (398)
  | resetFire (t : Bool)         -- fullResetReload's awaits (226)
  | checkStart (t : Bool)        -- maybeCheckForUpdate at load / visibilitychange (205)
  | chkCur (t : Bool) | chkLatest (t : Bool) | chkSw (t : Bool)  -- the three fetches land
  | chkEval (t : Bool)           -- the rest of checkForUpdate
  | forceStart (t : Bool)        -- Force update, confirmed (forceUpdate 308)
  | rProbe0                      -- old reinstall: the first probe
  | rFetchJs | rFetchWasm        -- old reinstall: one asset into the staging cache
  | rMan (b : Nat)               -- new reinstall: the deployed manifest (build b's)
  | rNet (a : Asset) (b : Nat)   -- new reinstall: a's download answers build b's bytes
  | rVerify                      -- reinstall: the download passed its check
  | rPutJs | rPutWasm            -- reinstall: one put into its cache (older designs: the live one)
  | rFail                        -- reinstall: a download or check failed: the reply ok:false
  | rStop                        -- reinstall: the worker stopped at any point; no reply, no
                                 --   progress: the page's forceSilenceMs
  | forceDone (t : Bool)         -- "reinstalled" ok: reloadAfterUpdate
  | forceRetry (t : Bool)        -- the failed card's Try Again: startForceUpdate
  | failClose (t : Bool)         -- the failed card's Close: endUpdating
  | landReload (t : Bool)        -- reloadAfterUpdate's wingbeat lands: location.reload()
  | newerStart (t : Bool)        -- a too-new state refused; updateForNewerState passes its checks
  | newerApply (t : Bool)        -- ...its awaits done: applyUpdate()
  | navQ (t : Bool)              -- the user loads the app with a query string (?2p, ?gpu3d=1)
  | lzOld (l : Lz) (b : Nat)     -- an older worker's DS core fetch: a miss is kept unchecked,
                                 --   whatever build b the network answers
  | lzHit (l : Lz)               -- this design: a DS core file served from the cache (lazyFrom)
  | lzStart (l : Lz)             -- this design: a miss; the cache's manifest read (lazyFrom)
  | lzNet (l : Lz) (b : Nat) (put : Bool)
                                 -- ...the download answers build b's bytes: checked, then
                                 --   served and (put) kept in the cache it read
  | nLookLz (l : Lz)             -- this design's install: a held copy of DS core file l (collect)
  | rNetLz (l : Lz) (b : Nat)    -- this design's reinstall: a held DS core file downloaded again
  | rCommit                      -- this design's reinstall: commit into its own cache, then the
                                 --   pointer moves (setLive)
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
  | .gameOn t => !(s.tabs t).game && !(s.tabs t).appUpdating
  | .gameOff t => (s.tabs t).game
  | .updClick t => (s.tabs t).updAvail && !(s.tabs t).appUpdating && !(s.tabs t).modal && !(s.tabs t).shield
  | .confirm t => (s.tabs t).modal && !(s.tabs t).shield
  | .notNow t => (s.tabs t).modal && !(s.tabs t).shield
  | .applyResume t => (s.tabs t).applyK == .awaitUpdate
  | .resetFire t => (s.tabs t).applyK == .resetting
  | .checkStart t => !(s.tabs t).updAvail && (s.tabs t).chk.isNone
  | .chkCur t => match (s.tabs t).chk with | some c => c.cur.isNone | none => false
  | .chkLatest t => match (s.tabs t).chk with | some c => c.latest.isNone | none => false
  | .chkSw t => match (s.tabs t).chk with | some c => c.sw.isNone | none => false
  | .chkEval t => match (s.tabs t).chk with
      | some c => c.cur.isSome && c.latest.isSome && c.sw.isSome | none => false
  | .forceStart t => !(s.tabs t).force && !(s.tabs t).appUpdating && !(s.tabs t).shield && !(s.tabs t).modal
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
  | .rStop => anyForce s
  | .forceDone t => (s.tabs t).force && rDone E s
  | .forceRetry t => (s.tabs t).failed
  | .failClose t => (s.tabs t).failed
  | .landReload t => (s.tabs t).pend
  | .newerStart t => (s.tabs t).game && !(s.tabs t).appUpdating && !(s.tabs t).newer
  | .newerApply t => (s.tabs t).newer
  | .navQ _ => true
  | .lzOld _ b => (match s.active with | some v => !E.curGen v | none => false) && decide (b ≤ s.dep)
  | .lzHit l => match s.active with | some v => E.curGen v && (s.lazy v l).isSome | none => false
  | .lzStart l => (match s.active with
      | some v => E.curGen v && (s.lazy v l).isNone && (s.cman v).isSome | none => false) &&
      (s.lzF l).isNone
  | .lzNet l b _ => (s.lzF l).isSome && decide (b ≤ s.dep)
  | .nLookLz l => curInst E s && s.man.isSome && (s.lslot l).isNone
  | .rNetLz l b => anyForce s && curR E s && s.rMan.isSome && (s.rsLz l).isNone && !s.rFlip &&
      (match s.rW with | some w => (s.lazy w l).isSome | none => false) && decide (b ≤ s.dep)
  | .rCommit => anyForce s && curR E s && s.rOk && s.rJs && s.rWasm && !s.rFlip

/-- applyUpdate (382), first segment: appUpdating and updateReloadComing,
    close the modal, the shield up with no failed card (beginUpdating("update"));
    then either the reload another tab's update
    left waiting (reloadAfterUpdate, 393), or `update()`. -/
def applyStart (_E : Env) (t : Bool) (s : State) : State :=
  let x := s.tabs t
  let s := { s with intents := s.intents + 1 }
  let s := updT t (fun x => { x with appUpdating := true, modal := false, shield := true, coming := true, failed := false }) s
  if x.ready then updT t (fun x => { x with pend := true }) s
  else if x.regd then updT t (fun x => { x with applyK := .awaitUpdate }) (updCheck s)
  else updT t (fun x => { x with applyK := .resetting }) s

/-- fullResetReload's unregister: the installing worker goes redundant. -/
def redund (s : State) : State :=
  match s.installing with
  | some v => mapTabs (onRedundant v) s
  | none => s

/-- fullResetReload's awaits (226): every cache deleted, the registration
    gone (`redund`); then its reloadAfterUpdate. -/
def wipe (s : State) : State :=
  { clearInst (redund s) with cache := fun _ => none, active := none, waiting := none, skipQ := none,
                              cman := fun _ => none, lazy := fun _ _ => none }

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
  -- fetchManifest(CACHE_VERSION): refused unless it is this build's
  | .nManifest b =>
    match s.installing with
    | some v => if b == v then { s with man := some b } else installFailed v s
    | none => s
  -- heldCopy: the first held copy with the manifest's digest, else
  -- to download
  | .nLook a =>
    match s.man with
    | some m => match heldBytes E s a m with
      | some x => { s with slot := setSlot s.slot a (.have x) }
      | none => { s with slot := setSlot s.slot a .net }
    | none => s
  -- collect: the download, checked; a mismatch throws
  | .nNet a b =>
    match s.installing, s.man with
    | some v, some m =>
      let s := { s with dl := s.dl + 1 }
      if E.H (E.C a b) == E.H (E.C a m) then { s with slot := setSlot s.slot a (.have (E.C a b)) }
      else installFailed v s
    | _, _ => s
  -- commit: caches.open(name) and the puts
  -- (this design: into an emptied cache, with the manifest and the DS core
  -- files it holds; the pointer to it, setLive, is part of the same event)
  | .nCommit =>
    match s.installing, s.slot .js, s.slot .wasm with
    | some v, .have xj, .have xw =>
      { s with cache := fun u => if u = v then some (xj, xw) else s.cache u, committed := true,
               cman := fun u => if u = v && E.curGen v then some v else s.cman u,
               lazy := fun u => if u = v && E.curGen v then s.lslot else s.lazy u }
    | _, _, _ => s
  -- commit: the cache under that name still holds them
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
  -- controllerchange (132): this tab's own update reloads after the wingbeat
  -- (refreshing, reloadAfterUpdate), a tab with no game in progress at once;
  -- else updateActivated + the button
  | .ccFire t =>
    let x := s.tabs t
    let s := updT t (fun x => { x with ccQ := false }) s
    if (x.hadController || x.appUpdating) && !x.refreshing then
      if x.appUpdating then updT t (fun x => { x with refreshing := true, pend := true, coming := true }) s
      else if !x.game then reload E t true s
      else
        match s.active with
        | some v => showBtn t v (updT t (fun x => { x with ready := true, hadController := true }) s)
        | none => updT t (fun x => { x with ready := true, hadController := true }) s
    else updT t (fun x => { x with hadController := true }) s
  | .userReload t => reload E t false s
  -- launchRom (7564) / handleRomFile / handleDroppedFile: refused while
  -- appUpdating (`en`)
  | .gameOn t => updT t (fun x => { x with game := true }) s
  | .gameOff t => updT t (fun x => { x with game := false }) s
  -- #update-btn (429): a game loaded -> confirm modal, else applyUpdate
  | .updClick t =>
    if (s.tabs t).game then updT t (fun x => { x with modal := true }) s else applyStart E t s
  | .confirm t => applyStart E t s
  | .notNow t => updT t (fun x => { x with modal := false }) s
  -- after `await swRegistration.update()` (398-418)
  | .applyResume t =>
    match s.waiting, s.installing with
    | some v, _ => updT t (fun x => { x with applyK := .done }) { s with skipQ := some v }
    | none, some v => updT t (fun x => { x with applyK := .watch v }) s
    | none, none => updT t (fun x => { x with applyK := .resetting }) s
  -- fullResetReload (226): delete every cache, unregister; then reloadAfterUpdate
  | .resetFire t => updT t (fun x => { x with applyK := .idle, pend := true, coming := true }) (wipe s)
  | .checkStart t => updT t (fun x => { x with chk := some {} }) s
  -- fetch("version.txt"): the controller's own cache (sw.js fetch handler), else network
  | .chkCur t =>
    let x := s.tabs t
    let v := if x.controlled then (match s.cache x.ctrlV with | some p => p.1 | none => s.dep) else s.dep
    updT t (fun x => { x with chk := x.chk.map (fun c => { c with cur := some v }) }) s
  | .chkLatest t => updT t (fun x => { x with chk := x.chk.map (fun c => { c with latest := some s.dep }) }) s
  | .chkSw t => updT t (fun x => { x with chk := x.chk.map (fun c => { c with sw := some s.dep }) }) s
  -- checkForUpdate 190-202: current && latest && latest !== current && deployed === latest -> button
  | .chkEval t =>
    match (s.tabs t).chk with
    | some { cur := some c, latest := some l, sw := some d } =>
      let s := updT t (fun x => { x with chk := none }) s
      if c != l && d == l then showBtn t l s else s
    | _ => s
  -- the Force update row (515; and the core's own, showCoreFailed): confirmed,
  -- then startForceUpdate (495)
  | .forceStart t => startForce t s
  -- the failed card's Try Again (373): startForceUpdate
  | .forceRetry t => startForce t s
  -- the failed card's Close (372): endUpdating, the shield down
  | .failClose t => updT t (fun x => { x with shield := false, failed := false }) s
  -- reloadAfterUpdate (357): its timer's location.reload() (every update
  -- reload may wait for the logo's wingbeat; the one that does not is this
  -- step with nothing between)
  | .landReload t => reload E t true s
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
  -- an older design's reinstall: one cache.put per asset into the live cache;
  -- this design's: into a cache of its own (commit), which nothing serves
  | .rPutJs =>
    match s.rW with
    | some w =>
      if E.curGen w then { s with rJs := true } else
      let j := E.C .js (s.rsJs.getD s.dep)
      let c := fun u => if u = w then some (j, ((s.cache u).map Prod.snd).getD (E.C .wasm s.dep)) else s.cache u
      { s with rJs := true, cache := c }
    | none => s
  | .rPutWasm =>
    match s.rW with
    | some w =>
      if E.curGen w then { s with rWasm := true } else
      let x := E.C .wasm (s.rsWasm.getD s.dep)
      let c := fun u => if u = w then some (((s.cache u).map Prod.fst).getD (E.C .js s.dep), x) else s.cache u
      { s with rWasm := true, cache := c }
    | none => s
  | .rFail => rFailed s
  -- forceUpdate (455): no reply and no progress message for forceSilenceMs
  | .rStop => rSilent s
  -- forceUpdate: "reinstalled" ok:true -> reloadAfterUpdate
  | .forceDone t => updT t (fun x => { x with force := false, pend := true, coming := true }) s
  -- refuseState (9141) / updateForNewerState (9153): the player's own load is the intent
  | .newerStart t =>
    updT t (fun x => { x with newer := true }) { s with intents := s.intents + 1 }
  | .newerApply t => applyStart E t (updT t (fun x => { x with newer := false }) s)
  -- the fetch handler's `shell`: this design answers any query with "./"
  | .navQ t => bootFrom E t false (serveQ E s) s
  -- an older design's lazy branch: a miss is put as the network answers it
  | .lzOld l b =>
    match s.active with
    | some v => match s.lazy v l with
      | some _ => s
      | none => { s with lazy := fun u => if u = v then (fun k => if k = l then some (E.L l b) else s.lazy v k)
                                          else s.lazy u }
    | none => s
  -- lazyFrom: a hit is served as the cache holds it
  | .lzHit l =>
    match s.active with
    | some v => match s.lazy v l with
      | some x => { s with lzBad := s.lzBad || x != E.L l ((s.cman v).getD v) }
      | none => s
    | none => s
  -- lazyFrom: a miss reads the manifest that cache keeps, then downloads
  | .lzStart l =>
    match s.active with
    | some v => match s.cman v with
      | some m => { s with lzF := fun k => if k = l then some (v, m) else s.lzF k }
      | none => s
    | none => s
  -- ...the bare URL, then once more under a fresh one: bytes whose digest is
  -- not the manifest's are neither served nor kept (each try is one of these
  -- events; a miss on both fails the load). The put goes to the cache the
  -- fetch read, by its handle: when the pointer has moved since (`cman` no
  -- longer that manifest) it lands in a cache nothing serves; it may also not
  -- land at all (`put`).
  | .lzNet l b put =>
    match s.lzF l with
    | some (w, m) =>
      let s := { s with lzF := fun k => if k = l then none else s.lzF k }
      if E.H (E.L l b) == E.H (E.L l m) then
        let s := { s with lzBad := s.lzBad || E.L l b != E.L l m }
        if put && s.cman w == some m then
          { s with lazy := fun u => if u = w then (fun k => if k = l then some (E.L l b) else s.lazy w k)
                                     else s.lazy u }
        else s
      else s
    | none => s
  -- collect (reuse): a DS core file held with this build's digest; never a download
  | .nLookLz l =>
    match s.man with
    | some m => { s with lslot := fun k => if k = l then heldLazy E s l m else s.lslot k }
    | none => s
  -- reinstall: a DS core file the live cache holds, downloaded again and
  -- checked; a mismatch leaves it out (its next lazy fetch brings it)
  | .rNetLz l b =>
    match s.rMan with
    | some m =>
      if E.H (E.L l b) == E.H (E.L l m) then
        { s with rsLz := fun k => if k = l then some (E.L l b) else s.rsLz k }
      else s
    | none => s
  -- reinstall's commit into its own cache, then setLive: one put moves the
  -- pointer, and every fetch from then on reads the new cache whole
  | .rCommit =>
    match s.rW with
    | some w =>
      { s with rFlip := true,
               cache := fun u => if u = w then some (E.C .js (s.rsJs.getD s.dep), E.C .wasm (s.rsWasm.getD s.dep))
                                 else s.cache u,
               cman := fun u => if u = w then s.rMan else s.cman u,
               lazy := fun u => if u = w then s.rsLz else s.lazy u }
    | none => s

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
  M := 2
  L := fun l b => match l with | .js => 300 + b / 4 | .wasm => 400 + b / 4

def E1 : Env := { E0 with N := 10, M := 10 }

/-- Every build of this design (the worker in `init` included). -/
def E3 : Env := { E0 with N := 0, M := 0 }

/-- Every build 0b7f1b57's design: the manifest, no pointer, no DS core digests. -/
def E4 : Env := { E0 with N := 0, M := 10 }

/-- Build 0 is 0b7f1b57's, every later one this design's: the update now
    rolling out. -/
def E5 : Env := { E0 with N := 0, M := 1 }

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
               .updClick true, .confirm true, .landReload true]
      (fun s => !s.forcedMidGame && (s.tabs true).running == E0.bytes 1 &&
                (s.tabs true).ctrlV == 1) = true := by decide

/-- An old page under an old worker updates to the new build: the new
    worker's install downloads index.js alone (em.wasm is build 0's bytes,
    in build 0's cache), and the page reloads onto build 1 under it. -/
theorem old_to_new_update_downloads_only_what_changed :
    witnesses E0 [.regResolve false, .deploy, .browserCheck, .nManifest 1, .nLook .js,
               .nLook .wasm, .nNet .js 1, .nCommit, .nCheck, .instFire false, .updClick false,
               .applyResume false, .skipDeliver, .ccFire false, .landReload false]
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

/-- Was `bug_force_update_serves_half_written_cache`, which stands for the
    older designs (`legacy_force_update_serves_half_written_cache`). This
    design's Force update puts nothing into the live cache: its downloads go
    into a cache of its own, so a tab booted between its two puts boots the
    old build whole (`E3`: every build this design). -/
theorem regress_force_update_serves_half_written_cache :
    witnesses E3 [.deploy, .deploy, .forceStart false, .rMan 2, .rNet .js 2, .rNet .wasm 2, .rVerify,
               .rPutJs, .userReload true]
      (fun s => (s.tabs true).running == E3.bytes 0 && !s.mixedBoot &&
                s.cache 0 == some (E3.bytes 0) && s.cman 0 == some 0) = true := by decide

/-- ...and once both puts are in, the pointer moves in one step: the next
    boot is the new build whole, under the same worker, its cache keeping
    build 2's manifest. -/
theorem force_commit_switches_whole :
    witnesses E3 [.deploy, .deploy, .forceStart false, .rMan 2, .rNet .js 2, .rNet .wasm 2, .rVerify,
               .rPutJs, .userReload true, .rPutWasm, .rCommit, .userReload true, .forceDone false,
               .landReload false]
      (fun s => (s.tabs true).running == E3.bytes 2 && (s.tabs false).running == E3.bytes 2 &&
                (s.tabs true).ctrlV == 0 && !s.mixedBoot && s.cman 0 == some 2) = true := by decide

/-- The worker stopped mid-commit (after one put, before the pointer moves):
    no reply and no progress come, the asking tab's forceSilenceMs takes its
    full reset, and a tab loading meanwhile boots the old cache whole. -/
theorem force_kill_mid_commit_old_cache_serves :
    witnesses E3 [.deploy, .deploy, .forceStart false, .rMan 2, .rNet .js 2, .rNet .wasm 2, .rVerify,
               .rPutJs, .rPutWasm, .rStop, .userReload true]
      (fun s => (s.tabs true).running == E3.bytes 0 && !s.mixedBoot && !anyForce s &&
                (s.tabs false).applyK == .resetting && s.cache 0 == some (E3.bytes 0)) = true := by decide

/-- The older designs' Force update still commits to the live cache one put
    per asset, and runs in a browser until its worker updates to this design.
    0b7f1b57's (`E4`: every build that design): a tab booted between the two
    puts gets the new index.js with the old em.wasm, bytes no build has. -/
theorem legacy_force_update_serves_half_written_cache :
    witnesses E4 [.deploy, .deploy, .forceStart false, .rMan 2, .rNet .js 2, .rNet .wasm 2, .rVerify,
               .rPutJs, .userReload true]
      (fun s => !oneBuild E4 s.dep (s.tabs true).running) = true := by decide

/-- The same for the design before the manifest. -/
theorem legacy_probed_force_update_serves_half_written_cache :
    witnesses E0 [.deploy, .deploy, .forceStart false, .rProbe0, .rFetchJs, .rFetchWasm, .rVerify,
               .rPutJs, .userReload true]
      (fun s => !oneBuild E0 s.dep (s.tabs true).running) = true := by decide

/-- 0b7f1b57's worker answers a load with a query string (here after two
    deploys, em.wasm changed) by the network's index.html beside its cache's
    em.wasm: bytes no build has. -/
theorem legacy_query_navigation_mixes_builds :
    witnesses E4 [.deploy, .deploy, .navQ true]
      (fun s => !oneBuild E4 s.dep (s.tabs true).running && s.mixedBoot) = true := by decide

/-- This design answers it with "./": the cached build, whole, nothing off
    the network (`navigation_never_net_while_live`). -/
theorem regress_query_navigation_after_deploy :
    witnesses E3 [.deploy, .deploy, .navQ true]
      (fun s => (s.tabs true).running == E3.bytes 0 && !s.mixedBoot && (s.tabs true).ctrlV == 0 &&
                s.http .js == none) = true := by decide

/-- 0b7f1b57's worker keeps whatever the network answers for a DS core file:
    after deploys that changed the DS core, an edge still on the old nds.js
    and the origin's new nds.wasm leave a DS core of two builds in its cache. -/
theorem legacy_lazy_unchecked :
    witnesses E4 [.deploy, .deploy, .deploy, .deploy, .lzOld .js 0, .lzOld .wasm 4]
      (fun s => s.lazy 0 .js == some (E4.L .js 0) && s.lazy 0 .wasm == some (E4.L .wasm 4) &&
                E4.L .wasm 4 != E4.L .wasm 0) = true := by decide

/-- This design's: the origin is on build 4, whose nds.wasm is not build 0's;
    the download is neither served nor kept, and the next try (here an edge
    still on build 0's object, or after the update) is. -/
theorem regress_tampered_lazy_refused :
    witnesses E3 [.deploy, .deploy, .deploy, .deploy, .lzStart .wasm, .lzNet .wasm 4 true,
               .lzStart .wasm, .lzNet .wasm 0 true]
      (fun s => s.lazy 0 .wasm == some (E3.L .wasm 0) && !s.lzBad && s.lzF .wasm == none) = true := by
  decide

/-- 0b7f1b57 → this design (`E5`: build 0 is 0b7f1b57's, every later build
    this design's). The old worker has fetched the DS core; build 1 deploys
    with the same DS core and em.wasm. Its install carries the DS core over
    from the old cache with nothing downloaded but index.js, and the page
    reloads onto build 1 with the DS core still there. -/
theorem old_worker_ds_core_carried_over :
    witnesses E5 [.regResolve false, .lzOld .js 0, .lzOld .wasm 0, .deploy, .browserCheck,
               .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1, .nLookLz .js, .nLookLz .wasm,
               .nCommit, .nCheck, .instFire false, .updClick false, .applyResume false, .skipDeliver,
               .ccFire false, .landReload false]
      (fun s => s.dl == 1 && s.active == some 1 && s.cache 1 == some (E5.bytes 1) &&
                s.lazy 1 .js == some (E5.L .js 1) && s.lazy 1 .wasm == some (E5.L .wasm 1) &&
                s.cache 0 == none && (s.tabs false).running == E5.bytes 1 && !s.mixedBoot) = true := by
  decide

/-- 0b7f1b57's worker runs a Force update while this design's build 1 is
    deployed (the old page's own button): build 1's bytes go into its cache
    one put at a time, the page reloads onto them, and build 1's worker then
    installs with nothing to download. -/
theorem v1_worker_force_then_cur_worker_reuses :
    witnesses E5 [.regResolve false, .deploy, .forceStart false, .rMan 1, .rNet .js 1, .rNet .wasm 1,
               .rVerify, .rPutJs, .rPutWasm, .forceDone false, .landReload false, .browserCheck, .nManifest 1,
               .nLook .js, .nLook .wasm, .nCommit, .nCheck]
      (fun s => (s.tabs false).running == E5.bytes 1 && (s.tabs false).ctrlV == 0 &&
                s.dl == 0 && s.waiting == some 1 && s.cache 1 == some (E5.bytes 1)) = true := by decide

/-- 0b7f1b57's page left under this design's worker by another tab's Update
    (B mid-game) asks it for a Force update after build 2 deploys: the
    reinstall commits build 2 into a cache of its own, moves the pointer, and
    B reloads onto build 2 whole. -/
theorem old_page_force_under_cur_worker :
    witnesses E5 [.gameOn true, .regResolve false, .regResolve true, .deploy, .browserCheck,
               .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1, .nCommit, .nCheck,
               .instFire false, .updClick false, .applyResume false, .skipDeliver, .ccFire true,
               .deploy, .gameOff true, .forceStart true, .rMan 2, .rNet .js 2, .rNet .wasm 2,
               .rVerify, .rPutJs, .rPutWasm, .rCommit, .forceDone true, .landReload true]
      (fun s => !s.forcedMidGame && !s.mixedBoot && (s.tabs true).running == E5.bytes 2 &&
                (s.tabs true).ctrlV == 1 && s.cman 1 == some 2) = true := by decide

/-- This design's Force update downloads again the DS core files its live
    cache holds (nds.js here, after a DS game), checked against the new
    manifest, and leaves the rest to their lazy fetch. -/
theorem force_update_brings_held_ds_core_again :
    witnesses E3 [.lzStart .js, .lzNet .js 0 true, .deploy, .deploy, .deploy, .deploy,
               .forceStart false, .rMan 4, .rNet .js 4, .rNet .wasm 4, .rNetLz .js 4, .rVerify,
               .rPutJs, .rPutWasm, .rCommit]
      (fun s => s.lazy 0 .js == some (E3.L .js 4) && s.lazy 0 .wasm == none &&
                s.cman 0 == some 4 && s.cache 0 == some (E3.bytes 4)) = true := by decide

/-- An old worker's Force update while build 1 is deployed: build 1's bytes go
    into build 0's cache and the page reloads onto them, the new page under the
    old worker. Build 1's worker then installs with nothing to download: every
    asset is in build 0's cache, with build 1's digest. -/
theorem old_worker_force_then_new_worker_reuses :
    witnesses E0 [.regResolve false, .deploy, .forceStart false, .rProbe0, .rFetchJs, .rFetchWasm,
               .rVerify, .rPutJs, .rPutWasm, .forceDone false, .landReload false, .browserCheck, .nManifest 1,
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
               .rVerify, .rPutJs, .rPutWasm, .forceDone true, .landReload true]
      (fun s => !s.forcedMidGame && (s.tabs true).running == E0.bytes 2 &&
                (s.tabs true).ctrlV == 1) = true := by decide

/-- A save state from a newer build loaded in tab B's game while tab A has a
    game too: B reloads onto the new build, A keeps its game, its button
    relabelled Reload. Neither reload is forced. -/
theorem newer_state_update_reloads_only_its_tab :
    witnesses E0 [.gameOn true, .gameOn false, .regResolve true, .regResolve false, .deploy,
               .browserCheck, .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1, .nCommit,
               .nCheck, .newerStart true, .newerApply true, .applyResume true, .skipDeliver,
               .ccFire true, .ccFire false, .landReload true]
      (fun s => !s.forcedMidGame && (s.tabs true).running == E0.bytes 1 &&
                (s.tabs false).ready && (s.tabs false).running == E0.bytes 0) = true := by decide

/-- The old design: a Force update whose download straddles a deploy cannot
    pass its check. -/
theorem regress_force_update_straddle_not_verified :
    run E1 (init E1) [.deploy, .forceStart false, .rProbe0, .rFetchJs, .deploy, .rFetchWasm,
              .rVerify] = none := by decide

/-- The new design: the new worker's Force update reads build 2's manifest,
    then a deploy changes em.wasm and the download is build 4's: it fails
    the check and the reply is ok:false. The tab's failure: the failed
    card, nothing changed (its cache, no reload coming, appUpdating off). -/
theorem regress_new_force_update_straddle_fails :
    witnesses E0 [.deploy, .browserCheck, .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1,
               .nCommit, .nCheck, .regResolve false, .updClick false, .applyResume false,
               .skipDeliver, .ccFire false, .landReload false, .deploy, .forceStart false, .rMan 2,
               .rNet .js 2, .deploy, .deploy, .rNet .wasm 4]
      (fun s => !anyForce s && (s.tabs false).applyK == .idle && !(s.tabs false).pend &&
                (s.tabs false).failed && !(s.tabs false).appUpdating && !s.rOk &&
                s.cache 1 == some (E0.bytes 1)) = true := by decide

/-- A Force update's failure (`E3`): the failed card, nothing changed.
    The person closes it and plays: the game starts, the cache is the one it
    was, no reload comes. -/
theorem force_failure_close_then_play :
    witnesses E3 [.deploy, .forceStart false, .rMan 1, .rNet .js 1, .rFail, .failClose false, .gameOn false]
      (fun s => (s.tabs false).game && !(s.tabs false).shield && !(s.tabs false).pend &&
                (s.tabs false).applyK == .idle && s.autoReloads == 0 &&
                s.cache 0 == some (E3.bytes 0) && s.cman 0 == some 0) = true := by decide

/-- Try Again, failing again, and again: the failed card each time, never
    the full reset (2243d6d9: a second try's reset once threw away a working
    offline copy); the cache and worker as they were. -/
theorem force_failure_never_resets :
    witnesses E3 [.forceStart false, .rFail, .forceRetry false, .rFail, .forceRetry false, .rFail]
      (fun s => (s.tabs false).failed && !(s.tabs false).appUpdating && (s.tabs false).applyK == .idle &&
                !(s.tabs false).pend && s.active == some 0 && s.autoReloads == 0 &&
                s.cache 0 == some (E3.bytes 0)) = true := by decide

/-- A game cannot be started behind an update: launchRom refuses while
    appUpdating. -/
theorem no_game_behind_force_update :
    run E3 (init E3) [.forceStart false, .gameOn false] = none := by decide

/-- The wait before an update's reload is open to everything else (`E3`).
    Tab A's Force update to build 1 is done and its reload waits for the
    wingbeat; meanwhile build 2 deploys and installs, and tab B's Update
    activates it, deleting the cache A's Force update had just made live. A's
    reload lands on build 2, whole, under the new worker. -/
theorem wingbeat_wait_spans_activation :
    witnesses E3 [.deploy, .forceStart false, .rMan 1, .rNet .js 1, .rNet .wasm 1, .rVerify, .rPutJs,
               .rPutWasm, .rCommit, .forceDone false, .deploy, .browserCheck, .nManifest 2, .nLook .js,
               .nLook .wasm, .nNet .js 2, .nNet .wasm 2, .nCommit, .nCheck, .regResolve true,
               .updClick true, .applyResume true, .skipDeliver, .landReload false]
      (fun s => (s.tabs false).running == E3.bytes 2 && (s.tabs false).ctrlV == 2 && !s.mixedBoot &&
                !s.forcedMidGame && s.cache 0 == none && s.cache 2 == some (E3.bytes 2)) = true := by decide

/-- Was `bug_force_failure_mid_update_reloads_midgame`. Tab A has a game; a
    save state from the new build is loaded, and updateForNewerState passes
    its checks and awaits its writes (persistSave, dbPut). Force update is
    tapped from the menu meanwhile (nothing holds taps yet). The writes land
    and applyUpdate runs: its update() finds the new worker installing and
    watches it. The Force update's download fails. The tab used to show the
    failed card with appUpdating false, so a game started after Close was
    then reloaded away when the install failed and fullResetReload ran.
    Now an update's reload is coming (updateReloadComing, set by
    applyUpdate): the tab goes on updating, shield up, appUpdating on, no
    failed card. -/
theorem regress_force_failure_mid_update_keeps_updating :
    witnesses E0 [.gameOn false, .regResolve false, .deploy, .newerStart false, .forceStart false,
               .newerApply false, .rFail]
      (fun s => (s.tabs false).appUpdating && (s.tabs false).shield && !(s.tabs false).failed &&
                (s.tabs false).applyK == .awaitUpdate) = true := by decide

/-- ...so no Close, and no game start, until the Update's reload, which
    takes only the game its user agreed to the update in. -/
theorem regress_force_failure_mid_update_no_close :
    run E0 (init E0) [.gameOn false, .regResolve false, .deploy, .newerStart false, .forceStart false,
              .newerApply false, .rFail, .failClose false] = none ∧
    run E0 (init E0) [.gameOn false, .regResolve false, .deploy, .newerStart false, .forceStart false,
              .newerApply false, .rFail, .gameOff false, .gameOn false] = none ∧
    witnesses E0 [.gameOn false, .regResolve false, .deploy, .newerStart false, .forceStart false,
               .newerApply false, .rFail, .applyResume false, .installFail, .resetFire false,
               .landReload false]
      (fun s => !s.forcedMidGame) = true := by decide

/-- The milder form (`E3`): tab A's Force update is in flight when tab B's
    Update activates the new worker and claims A, whose reload then waits
    for the wingbeat. A's Force update fails inside that wait. It used to
    show the failed card and then reload anyway; now (reloadAfterUpdate set
    updateReloadComing) A stays updating and the reload lands whole. -/
theorem regress_force_failure_in_wingbeat_wait :
    witnesses E3 [.deploy, .browserCheck, .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1, .nCommit,
               .nCheck, .regResolve true, .forceStart false, .rMan 1, .updClick true, .applyResume true,
               .skipDeliver, .ccFire false, .rFail]
      (fun s => (s.tabs false).appUpdating && !(s.tabs false).failed && (s.tabs false).pend) = true := by
  decide

theorem regress_force_failure_in_wingbeat_wait_lands :
    witnesses E3 [.deploy, .browserCheck, .nManifest 1, .nLook .js, .nLook .wasm, .nNet .js 1, .nCommit,
               .nCheck, .regResolve true, .forceStart false, .rMan 1, .updClick true, .applyResume true,
               .skipDeliver, .ccFire false, .rFail, .landReload false]
      (fun s => !s.forcedMidGame && !s.mixedBoot && (s.tabs false).running == E3.bytes 1 &&
                (s.tabs false).ctrlV == 1) = true := by decide

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
@[simp] theorem updT_cman : (updT t f s).cman = s.cman := rfl
@[simp] theorem mapTabs_cman : (mapTabs g s).cman = s.cman := rfl
@[simp] theorem updT_lazy : (updT t f s).lazy = s.lazy := rfl
@[simp] theorem mapTabs_lazy : (mapTabs g s).lazy = s.lazy := rfl
@[simp] theorem updT_lslot : (updT t f s).lslot = s.lslot := rfl
@[simp] theorem mapTabs_lslot : (mapTabs g s).lslot = s.lslot := rfl
@[simp] theorem updT_lzF : (updT t f s).lzF = s.lzF := rfl
@[simp] theorem mapTabs_lzF : (mapTabs g s).lzF = s.lzF := rfl
@[simp] theorem updT_rsLz : (updT t f s).rsLz = s.rsLz := rfl
@[simp] theorem mapTabs_rsLz : (mapTabs g s).rsLz = s.rsLz := rfl
@[simp] theorem updT_rFlip : (updT t f s).rFlip = s.rFlip := rfl
@[simp] theorem mapTabs_rFlip : (mapTabs g s).rFlip = s.rFlip := rfl
@[simp] theorem updT_lzBad : (updT t f s).lzBad = s.lzBad := rfl
@[simp] theorem mapTabs_lzBad : (mapTabs g s).lzBad = s.lzBad := rfl
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
@[simp] theorem wipe_intents : (wipe s).intents = s.intents := by unfold wipe redund; split <;> rfl
@[simp] theorem rSilent_intents : (rSilent s).intents = s.intents := rfl
@[simp] theorem rSilent_tabs : (rSilent s).tabs u =
    if (s.tabs u).force then { s.tabs u with force := false, applyK := .resetting } else s.tabs u := rfl
@[simp] theorem rFailed_tabs : (rFailed s).tabs u = failTab (s.tabs u) := rfl
@[simp] theorem startForce_intents : (startForce t s).intents = s.intents + 1 := by
  unfold startForce; simp only []; split <;> rfl
@[simp] theorem redund_intents : (redund s).intents = s.intents := by unfold redund; split <;> rfl
@[simp] theorem setStaged_intents (a : Asset) (b : Nat) : (setStaged s a b).intents = s.intents := by
  cases a <;> rfl
@[simp] theorem applyStart_intents : (applyStart E t s).intents = s.intents + 1 := by
  unfold applyStart; simp only []; (repeat' split) <;> simp
end proj

@[simp] theorem bootFrom_intents (E : Env) (s : State) (t auto : Bool) (sv : Option Nat × Nat × (Nat × Nat)) :
    (bootFrom E t auto sv s).intents = s.intents := by
  unfold bootFrom; split; rfl

theorem step_intents_mono (E : Env) (s : State) (e : Event) : s.intents ≤ (step E s e).intents := by
  cases e <;> simp only [step] <;> (repeat' split) <;> simp

/-! ### No reload without a click -/

/-- The per-tab part: no update in progress in this tab; a controllerchange
    queued only in a page that never had a controller (a first install's
    claim, which reloads nothing). -/
def QT (x : Tab) : Prop :=
  x.applyK = .idle ∧ x.appUpdating = false ∧ x.force = false ∧ (x.ccQ = true → x.hadController = false) ∧
  x.pend = false

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
      (s'.tabs u).hadController = (s.tabs u).hadController ∧ (s'.tabs u).pend = (s.tabs u).pend) : Q s' := by
  obtain ⟨a1, a2, a3, a4⟩ := h
  refine ⟨e1 ▸ a1, e2 ▸ a2, e3 ▸ a3, fun u => ?_⟩
  obtain ⟨⟨b1, b2, b3, b4, b7⟩, b5, b6⟩ := a4 u
  obtain ⟨c1, c2, c3, c4, c5, c6⟩ := et u
  refine ⟨⟨c1 ▸ b1, c2 ▸ b2, c3 ▸ b3, fun hc => c5 ▸ b4 (c4 ▸ hc), c6 ▸ b7⟩, fun ha => c5 ▸ b5 (e4 ▸ ha),
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
@[simp] theorem onInstalled_pend : (onInstalled v x).pend = x.pend := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
@[simp] theorem onRedundant_pend : (onRedundant v x).pend = x.pend := by
  unfold onRedundant; split <;> rfl
@[simp] theorem onInstalled_game : (onInstalled v x).game = x.game := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
@[simp] theorem onRedundant_game : (onRedundant v x).game = x.game := by
  unfold onRedundant; split <;> rfl
@[simp] theorem onInstalled_failed : (onInstalled v x).failed = x.failed := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
@[simp] theorem onRedundant_failed : (onRedundant v x).failed = x.failed := by
  unfold onRedundant; split <;> rfl
@[simp] theorem onInstalled_shield : (onInstalled v x).shield = x.shield := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
@[simp] theorem onRedundant_shield : (onRedundant v x).shield = x.shield := by
  unfold onRedundant; split <;> rfl
@[simp] theorem onInstalled_running : (onInstalled v x).running = x.running := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
@[simp] theorem onRedundant_running : (onRedundant v x).running = x.running := by
  unfold onRedundant; split <;> rfl
@[simp] theorem onInstalled_coming : (onInstalled v x).coming = x.coming := by
  unfold onInstalled; simp only []; split <;> split <;> rfl
@[simp] theorem onRedundant_coming : (onRedundant v x).coming = x.coming := by
  unfold onRedundant; split <;> rfl
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

section failfields
variable (x : Tab)
@[simp] theorem failTab_coming : (failTab x).coming = x.coming := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_applyK : (failTab x).applyK = x.applyK := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_force : (failTab x).force = false := by
  unfold failTab; split <;> (try split) <;> simp_all
@[simp] theorem failTab_shows : (failTab x).shows = x.shows := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_updAvail : (failTab x).updAvail = x.updAvail := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_running : (failTab x).running = x.running := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_pend : (failTab x).pend = x.pend := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_game : (failTab x).game = x.game := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_ccQ : (failTab x).ccQ = x.ccQ := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_hadController : (failTab x).hadController = x.hadController := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_controlled : (failTab x).controlled = x.controlled := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_ready : (failTab x).ready = x.ready := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_refreshing : (failTab x).refreshing = x.refreshing := by
  unfold failTab; split <;> (try split) <;> rfl
@[simp] theorem failTab_ctrlV : (failTab x).ctrlV = x.ctrlV := by
  unfold failTab; split <;> (try split) <;> rfl
end failfields

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
    obtain ⟨⟨b1, b2, b3, _, b7⟩, b5, _⟩ := a4 u
    have hh := b5 ha
    refine ⟨⟨?_, ?_, ?_, ?_, ?_⟩, ?_, ?_⟩ <;> simp [claim, onInstalled_applyK, b1, b2, b3, hh, b7]
  | some w =>
    simp only [mapTabs, clearInst, ha]
    refine ⟨a1, a2, a3, fun u => ?_⟩
    obtain ⟨⟨b1, b2, b3, b4, b7⟩, b5, b6⟩ := a4 u
    refine ⟨⟨?_, ?_, ?_, ?_, ?_⟩, ?_, ?_⟩ <;> simp_all [onInstalled_applyK]

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

theorem serveQ_ctrl {E : Env} {s : State} {c : Option Nat} {b : Nat} {p : Nat × Nat}
    (hs : serveQ E s = (c, b, p)) : c = s.active := by
  unfold serveQ at hs
  cases ha : s.active with
  | none => simp only [ha] at hs; exact (serve_ctrl hs).trans ha
  | some w =>
    simp only [ha] at hs; split at hs
    · exact (serve_ctrl hs).trans ha
    · split at hs <;> (cases hs; rfl)

theorem q_boot_user {E : Env} {s : State} (h : Q s) (t : Bool) {c : Option Nat} {b : Nat} {p : Nat × Nat}
    (hc : c = s.active) : Q (bootFrom E t false (c, b, p) s) := by
  obtain ⟨a1, a2, a3, a4⟩ := h
  simp only [QS, QT] at a4
  unfold bootFrom
  refine ⟨a1, by simpa using a2, by simpa using a3, fun u => ?_⟩
  simp only [QS, QT, updT_tabs, updT_active]
  split
  · subst hc; cases ha : s.active <;> simp
  · exact a4 u

theorem q_reload_user {E : Env} {s : State} (h : Q s) (t : Bool) : Q (reload E t false s) := by
  unfold reload
  generalize hs : serve E s = sv
  obtain ⟨c, b, p⟩ := sv
  exact q_boot_user h t (serve_ctrl hs)

theorem q_navQ {E : Env} {s : State} (h : Q s) (t : Bool) : Q (step E s (.navQ t)) := by
  simp only [step]
  generalize hs : serveQ E s = sv
  obtain ⟨c, b, p⟩ := sv
  exact q_boot_user h t (serveQ_ctrl hs)

/-- With no Update or Force-update accepted in any tab, the app never reloads a
    tab by itself: there is no reload loop without a user's click. -/
def I0 (s : State) : Prop := s.intents = 0 → Q s

theorem i0_init (E : Env) : I0 (init E) := fun _ => by
  refine ⟨rfl, rfl, rfl, fun u => ⟨⟨rfl, rfl, rfl, ?_, rfl⟩, ?_, ?_⟩⟩ <;> intro h <;> cases h

theorem i0_fresh (E : Env) (d : Nat) : I0 (initFresh E d) := fun _ => by
  refine ⟨rfl, rfl, rfl, fun u => ⟨⟨rfl, rfl, rfl, ?_, rfl⟩, fun _ => rfl, ?_⟩⟩ <;> intro h <;> cases h

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
    obtain ⟨⟨b1, b2, b3, b4, b7⟩, b5, b6⟩ := a4 t
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
  | rProbe0 | rFetchJs | rFetchWasm | rNet _ _ | rVerify | rPutJs | rPutWasm | rFail | rStop =>
    have := (a4 true).1.2.2.1; have := (a4 false).1.2.2.1; simp_all [en, anyForce]
  | forceDone t => have := (a4 t).1.2.2.1; simp [en, this] at he
  | forceRetry t => simp [step] at hz
  | landReload t => have := (a4 t).1.2.2.2.2; simp [en, this] at he
  | failClose t => simp only [step]; q_fr qs
  | newerStart t => simp [step] at hz
  | newerApply t => simp only [step, applyStart_intents, updT_intents] at hz; omega
  | navQ t => exact q_navQ qs t
  | lzOld _ _ | lzHit _ | lzStart _ | lzNet _ _ _ | nLookLz _ =>
    (try simp only [step]); (repeat' split) <;> q_fr qs
  | rNetLz _ _ | rCommit =>
    have := (a4 true).1.2.2.1; have := (a4 false).1.2.2.1; simp_all [en, anyForce]

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

theorem p_boot {E : Env} {s : State} (h : P s) (t : Bool) (auto : Bool) (sv : Option Nat × Nat × (Nat × Nat)) :
    P (bootFrom E t auto sv s) := by
  obtain ⟨c, b, p⟩ := sv
  unfold bootFrom
  intro u; simp only [updT_tabs]
  split
  · cases c <;> simp [PT]
  · exact h u

theorem p_reload {E : Env} {s : State} (h : P s) (t : Bool) (auto : Bool) : P (reload E t auto s) :=
  p_boot h t auto _

theorem p_installFailed {s : State} (h : P s) (v : Nat) : P (installFailed v s) :=
  p_frame h (fun u => by simp [installFailed])

theorem p_installed {s : State} (h : P s) (v : Nat) : P (installed v s) := by
  unfold installed; simp only []
  split <;> split <;> (refine p_frame h ?_; intro u; simp [mapTabs, activate, clearInst, claim, *])

theorem p_updCheck {s : State} (h : P s) : P (updCheck s) := p_frame h (fun u => by simp)

theorem p_rFailed {s : State} (h : P s) : P (rFailed s) := by
  refine p_frame h ?_; intro u; simp

theorem p_rSilent {s : State} (h : P s) : P (rSilent s) := by
  refine p_frame h ?_; intro u; simp only [rSilent_tabs]
  by_cases hf : (s.tabs u).force <;> simp [hf]

theorem p_startForce {s : State} (h : P s) (t : Bool) : P (startForce t s) := by
  have h1 : P (updT t (fun x => { x with appUpdating := true, shield := true, failed := false })
      { s with intents := s.intents + 1 }) := by p_fr h
  unfold startForce; simp only []; split
  · p_fr h1
  · p_fr h1

theorem p_applyStart {E : Env} {s : State} (h : P s) (t : Bool) : P (applyStart E t s) := by
  unfold applyStart
  have h1 : P (updT t (fun x => { x with appUpdating := true, modal := false, shield := true, coming := true, failed := false }) { s with intents := s.intents + 1 }) := by
    p_fr h
  simp only []
  split
  · p_fr h1
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
      · p_fr h1
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
  | confirm t => exact p_applyStart (E := E) h t
  | resetFire t =>
    simp only [step]
    have := p_redund h
    have h1 : P (wipe s) := by unfold wipe; p_fr this
    p_fr h1
  | chkEval t =>
    simp only [step]; split
    · have h1 : P (updT t (fun x => { x with chk := none }) s) := by p_fr h
      split
      · exact p_showBtn h1 t _
      · exact h1
    · exact h
  | forceDone t => simp only [step]; p_fr h
  | landReload t => exact p_reload h t true
  | forceStart t =>
    have h1 := h
    exact p_startForce h1 t
  | forceRetry t => exact p_startForce h t
  | rStop => exact p_rSilent h
  | newerApply t =>
    have h1 : P (updT t (fun x => { x with newer := false }) s) := by p_fr h
    exact p_applyStart (E := E) h1 t
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
  | navQ t => exact p_boot h t false _
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

The app reloads a tab by itself in five places, each through a pending
reload (`pend`, reloadAfterUpdate's wingbeat) but one: controllerchange (a
tab with no game reloads at once), the end of fullResetReload, Force
update's "reinstalled" ok:true, applyUpdate's `updateActivated` path, and
(through fullResetReload) a Force update's silence or no controller. Each is
this tab's own Update / Force update (`appUpdating`, set by the click before
any of them can run) or a tab with no game in progress, and no game starts
while `appUpdating` (launchRom refuses).

A Force update's failure sets `appUpdating` back to false only when no
update's reload is coming in the tab (`coming`, updateReloadComing); then
nothing else is under way in it (`TI`), and the failed card is the end of it.
With one coming, the tab goes on updating
(`regress_force_failure_mid_update_keeps_updating`). -/

/-- Per tab: an update in flight in this tab is one its user asked for; a
    pending reload sets `coming`; a Force update in flight with no reload
    coming has no applyUpdate beside it; the failed card is shown only with
    appUpdating off. -/
def TI (x : Tab) : Prop :=
  (x.applyK ≠ .idle → x.appUpdating = true) ∧ (x.force = true → x.appUpdating = true) ∧
  (x.pend = true → x.appUpdating = true) ∧ (x.pend = true → x.coming = true) ∧
  (x.force = true → x.coming = false → x.applyK = .idle) ∧
  (x.failed = true → x.appUpdating = false)

def FI (s : State) : Prop := s.forcedMidGame = false ∧ ∀ t, TI (s.tabs t)

theorem fi_frame {s s' : State} (h : FI s) (e1 : s'.forcedMidGame = s.forcedMidGame)
    (et : ∀ u, TI (s.tabs u) → TI (s'.tabs u)) : FI s' :=
  ⟨e1 ▸ h.1, fun u => et u (h.2 u)⟩

/-- An updating tab shows no failed card. -/
theorem ti_failed_false {x : Tab} (h : TI x) (hu : x.appUpdating = true) : x.failed = false := by
  cases hf : x.failed
  · rfl
  · have := h.2.2.2.2.2 hf; rw [hu] at this; cases this

theorem ti_onInstalled (v : Nat) (x : Tab) (h : TI x) : TI (onInstalled v x) := by
  obtain ⟨a, b, c, d, e, f⟩ := h
  refine ⟨fun hk => ?_, fun hf => ?_, fun hp => ?_, fun hp => ?_, fun hf hc => ?_, fun hf => ?_⟩
  · simp only [onInstalled_appUpdating]; apply a
    intro h0; rw [onInstalled_applyK] at hk; split at hk
    · rename_i hw; rw [hw] at h0; cases h0
    · exact hk h0
  · simp only [onInstalled_appUpdating, onInstalled_force] at *; exact b hf
  · simp only [onInstalled_appUpdating, onInstalled_pend] at *; exact c hp
  · simp only [onInstalled_coming, onInstalled_pend] at *; exact d hp
  · simp only [onInstalled_coming, onInstalled_force] at *
    have := e hf hc; rw [onInstalled_applyK]; simp [this]
  · simp only [onInstalled_appUpdating, onInstalled_failed] at *; exact f hf

theorem ti_onRedundant (v : Nat) (x : Tab) (h : TI x) : TI (onRedundant v x) := by
  obtain ⟨a, b, c, d, e, f⟩ := h
  refine ⟨fun hk => ?_, fun hf => ?_, fun hp => ?_, fun hp => ?_, fun hf hc => ?_, fun hf => ?_⟩
  · simp only [onRedundant_appUpdating]; apply a
    intro h0; rw [onRedundant_applyK] at hk; split at hk
    · rename_i hw; rw [hw] at h0; cases h0
    · exact hk h0
  · simp only [onRedundant_appUpdating, onRedundant_force] at *; exact b hf
  · simp only [onRedundant_appUpdating, onRedundant_pend] at *; exact c hp
  · simp only [onRedundant_coming, onRedundant_pend] at *; exact d hp
  · simp only [onRedundant_coming, onRedundant_force] at *
    have := e hf hc; rw [onRedundant_applyK]; simp [this]
  · simp only [onRedundant_appUpdating, onRedundant_failed] at *; exact f hf

/-- A tab function that keeps what TI reads keeps TI. -/
theorem ti_same {x y : Tab} (h : TI x) (e1 : y.applyK = x.applyK) (e2 : y.appUpdating = x.appUpdating)
    (e3 : y.force = x.force) (e4 : y.pend = x.pend) (e5 : y.coming = x.coming) (e6 : y.failed = x.failed) :
    TI y := by
  obtain ⟨a, b, c, d, e, f⟩ := h
  refine ⟨fun hk => e2 ▸ a (e1 ▸ hk), fun hf => e2 ▸ b (e3 ▸ hf), fun hp => e2 ▸ c (e4 ▸ hp),
    fun hp => e5 ▸ d (e4 ▸ hp), fun hf hc => e1 ▸ e (e3 ▸ hf) (e5 ▸ hc), fun hf => e2 ▸ f (e6 ▸ hf)⟩

/-- A tab updating with a reload coming and no failed card: TI holds. -/
theorem ti_upd {x : Tab} (h : x.appUpdating = true) (hc : x.coming = true) (hfl : x.failed = false) : TI x :=
  ⟨fun _ => h, fun _ => h, fun _ => h, fun _ => hc, fun _ h' => (by rw [hc] at h'; cases h'),
    fun h' => by rw [hfl] at h'; cases h'⟩

macro "fi_fr" h:term : tactic => `(tactic| ((refine fi_frame $h ?_ ?_) <;> (try rfl) <;>
  (intro u hu; first
    | (refine ti_same hu ?_ ?_ ?_ ?_ ?_ ?_ <;> simp [claim] <;> done)
    | (simp only [updT_tabs, mapTabs_tabs, startInst_tabs, clearInst_tabs, rClear_tabs];
       split <;>
       refine ti_same hu ?_ ?_ ?_ ?_ ?_ ?_ <;> simp_all [claim] <;> done))))

theorem fi_boot {E : Env} {s : State} (h : FI s) (t : Bool) (auto : Bool) (sv : Option Nat × Nat × (Nat × Nat))
    (hok : auto = false ∨ (s.tabs t).appUpdating = true ∨ (s.tabs t).game = false) :
    FI (bootFrom E t auto sv s) := by
  obtain ⟨a, b⟩ := h
  obtain ⟨c, bb, p⟩ := sv
  unfold bootFrom
  refine ⟨?_, fun u => ?_⟩
  · simp only [updT_forcedMidGame, a, Bool.false_or]
    rcases hok with hk | hk | hk <;> simp [hk]
  · simp only [updT_tabs]
    split
    · cases c <;> exact ⟨fun hk => absurd rfl hk, fun hf => (by cases hf), fun hp => (by cases hp),
        fun hp => (by cases hp), fun hf => (by cases hf), fun hf => (by cases hf)⟩
    · exact b u

theorem fi_reload {E : Env} {s : State} (h : FI s) (t : Bool) (auto : Bool)
    (hok : auto = false ∨ (s.tabs t).appUpdating = true ∨ (s.tabs t).game = false) :
    FI (reload E t auto s) := fi_boot h t auto _ hok

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
    | (refine ti_same this ?_ ?_ ?_ ?_ ?_ ?_ <;> simp [mapTabs, activate, clearInst, claim])

/-- A failure reply: with a reload coming the tab goes on updating; with
    none, nothing else is under way in it, and the failed card ends it. -/
theorem fi_rFailed {s : State} (h : FI s) : FI (rFailed s) := by
  refine fi_frame h rfl ?_
  intro u hu
  obtain ⟨a, b, c, d, e, f⟩ := hu
  simp only [rFailed_tabs]
  unfold failTab
  by_cases hf : (s.tabs u).force = true
  · simp only [hf, ↓reduceIte]
    split
    · rename_i hc; exact ti_upd (b hf) hc rfl
    · rename_i hc
      have hk := e hf (by simpa using hc)
      have hp : (s.tabs u).pend = false := by
        cases hpp : (s.tabs u).pend
        · rfl
        · have := d hpp; simp_all
      exact ⟨fun h => absurd hk h, fun h => (by cases h), fun h => (by simp [hp] at h),
        fun h => (by simp [hp] at h), fun h => (by cases h), fun _ => rfl⟩
  · simp only [hf]; exact ⟨a, b, c, d, e, f⟩

theorem fi_rSilent {s : State} (h : FI s) : FI (rSilent s) := by
  refine fi_frame h rfl ?_
  intro u hu
  simp only [rSilent_tabs]
  by_cases hf : (s.tabs u).force = true
  · obtain ⟨a, b, c, d, e, f⟩ := hu
    have hfl := ti_failed_false ⟨a, b, c, d, e, f⟩ (b hf)
    simp only [hf, ↓reduceIte]
    exact ⟨fun _ => b hf, fun h => (by cases h), fun hp => c hp, fun hp => d hp,
      fun h => (by cases h), fun h' => (by simp [hfl] at h')⟩
  · simp only [hf]; exact hu

/-- startForce from a tab with no update under way: the Force update row
    (under no shield) or the failed card's Try Again. -/
theorem fi_startForce {s : State} (h : FI s) (t : Bool) (hok : (s.tabs t).appUpdating = false) :
    FI (startForce t s) := by
  obtain ⟨a, b, c, d, e, f⟩ := h.2 t
  have hk : (s.tabs t).applyK = .idle := by
    cases hkk : (s.tabs t).applyK <;> simp_all
  have hfo : (s.tabs t).force = false := by
    cases hh : (s.tabs t).force
    · rfl
    · have := b hh; simp_all
  unfold startForce; simp only []
  split
  · refine fi_frame h rfl ?_
    intro u hu; simp only [updT_tabs, rClear_tabs]
    by_cases hut : u = t
    · subst hut; simp only [↓reduceIte]
      exact ⟨fun _ => rfl, fun _ => rfl, fun _ => rfl, fun hp => d hp, fun _ _ => hk,
        fun h' => (by cases h')⟩
    · simp only [hut, ↓reduceIte]; exact hu
  · refine fi_frame h rfl ?_
    intro u hu; simp only [updT_tabs]
    by_cases hut : u = t
    · subst hut; simp only [↓reduceIte]
      exact ⟨fun _ => rfl, fun _ => rfl, fun _ => rfl, fun hp => d hp,
        fun h' _ => (by simp [hfo] at h'), fun h' => (by cases h')⟩
    · simp only [hut, ↓reduceIte]; exact hu

theorem fi_redund {s : State} (h : FI s) : FI (redund s) := by
  unfold redund; split
  · exact fi_frame h rfl (fun u hu => by simpa using ti_onRedundant _ _ hu)
  · exact h

theorem fi_applyStart {E : Env} {s : State} (h : FI s) (t : Bool) : FI (applyStart E t s) := by
  unfold applyStart
  have fm : ∀ X : State, (updCheck X).forcedMidGame = X.forcedMidGame := by
    intro X; unfold updCheck; split <;> rfl
  simp only []
  split
  · refine fi_frame h rfl ?_
    intro u hu; simp only [updT_tabs]
    by_cases hut : u = t
    · subst hut; simp only [↓reduceIte]; exact ti_upd rfl rfl rfl
    · simp only [hut, ↓reduceIte]; exact hu
  · split
    · refine fi_frame h (by simp [fm]) ?_
      intro u hu; simp only [updT_tabs, updCheck_tabs]
      by_cases hut : u = t
      · subst hut; simp only [↓reduceIte]; exact ti_upd rfl rfl rfl
      · simp only [hut, ↓reduceIte]; exact hu
    · refine fi_frame h (by simp) ?_
      intro u hu; simp only [updT_tabs]
      by_cases hut : u = t
      · subst hut; simp only [↓reduceIte]; exact ti_upd rfl rfl rfl
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
      · refine fi_frame hs rfl ?_
        intro u hx; simp only [updT_tabs]
        by_cases hut : u = t
        · subst hut; simp only [↓reduceIte]
          have hu := ‹(s.tabs u).appUpdating = true›
          exact ti_upd hu rfl (ti_failed_false (x := s.tabs u) hx hu)
        · simp only [hut, ↓reduceIte]; exact hx
      · split
        · rename_i hu hg
          apply fi_reload h1 t true
          right; right
          simpa using hg
        · have h2 : FI (updT t (fun x => { x with ready := true, hadController := true })
              (updT t (fun x => { x with ccQ := false }) s)) := by fi_fr h1
          split
          · exact fi_showBtn h2 t _
          · exact h2
    · fi_fr h1
  | userReload t => exact fi_reload hs t false (Or.inl rfl)
  | landReload t =>
    -- the pending reload is this tab's own update's
    have hu : (s.tabs t).appUpdating = true := by
      apply (b t).2.2.1; simpa [en] using he
    exact fi_reload hs t true (Or.inr (Or.inl hu))
  | updClick t =>
    simp only [step]; split
    · fi_fr hs
    · exact fi_applyStart hs t
  | confirm t => exact fi_applyStart (E := E) hs t
  | applyResume t =>
    -- the tab is suspended in applyUpdate, which its click started
    have hk : (s.tabs t).applyK ≠ .idle := by simp [en] at he; simp [he]
    have hu : (s.tabs t).appUpdating = true := (b t).1 hk
    obtain ⟨_, b2, b3, b4, b5, b6⟩ := b t
    have key : ∀ k : AK, TI { s.tabs t with applyK := k } := fun k =>
      ⟨fun _ => hu, b2, b3, b4, fun hf hc => absurd (b5 hf hc) hk, b6⟩
    simp only [step]; split <;>
      (refine fi_frame hs rfl ?_; intro u hu'; simp only [updT_tabs]; split
       · rename_i e; subst e; exact key _
       · exact hu')
  | resetFire t =>
    have hu : (s.tabs t).appUpdating = true := by
      apply (b t).1; simp [en] at he; simp [he]
    simp only [step]
    have h1 : FI (wipe s) := by unfold wipe; have := fi_redund hs; fi_fr this
    have hw : ((wipe s).tabs t).appUpdating = true := by
      unfold wipe redund; split <;> simp [hu]
    refine fi_frame h1 rfl ?_
    intro u hx; simp only [updT_tabs]; split
    · rename_i hut; subst hut
      exact ti_upd (by simpa using hw) rfl (by simpa using ti_failed_false hx hw)
    · exact hx
  | chkEval t =>
    simp only [step]; split
    · have h1 : FI (updT t (fun x => { x with chk := none }) s) := by fi_fr hs
      split
      · exact fi_showBtn h1 t _
      · exact h1
    · exact hs
  | forceStart t =>
    exact fi_startForce hs t (by simp only [en, Bool.and_eq_true, Bool.not_eq_true'] at he; exact he.1.1.2)
  | forceRetry t =>
    exact fi_startForce hs t ((b t).2.2.2.2.2 (by simpa [en] using he))
  | failClose t =>
    simp only [step]
    refine fi_frame hs rfl ?_
    intro u hx; simp only [updT_tabs]; split
    · rename_i hut; subst hut
      obtain ⟨b1, b2, b3, b4, b5, _⟩ := hx
      exact ⟨b1, b2, b3, b4, b5, fun h => (by cases h)⟩
    · exact hx
  | rNet a b =>
    simp only [step]; split
    · split
      · cases a <;> fi_fr hs
      · exact fi_rFailed hs
    · exact hs
  | rFail => exact fi_rFailed hs
  | rStop => exact fi_rSilent hs
  | forceDone t =>
    have hu : (s.tabs t).appUpdating = true := by
      apply (b t).2.1; simp only [en, Bool.and_eq_true] at he; exact he.1
    simp only [step]
    refine fi_frame hs rfl ?_
    intro u hx; simp only [updT_tabs]; split
    · rename_i hut; subst hut; exact ti_upd hu rfl (ti_failed_false (x := s.tabs u) hx hu)
    · exact hx
  | newerStart t => simp only [step]; fi_fr hs
  | newerApply t =>
    have h1 : FI (updT t (fun x => { x with newer := false }) s) := by fi_fr hs
    exact fi_applyStart (E := E) h1 t
  | coreLoaded t => simp only [step]; split <;> fi_fr hs
  | navQ t => exact fi_boot hs t false _ (Or.inl rfl)
  | _ => (try simp only [step]); (repeat' split) <;> fi_fr hs

theorem fi_reachable {E : Env} {s : State} (h : Reachable E s) : FI s := by
  induction h with
  | init => exact ⟨rfl, fun _ => ⟨fun hk => absurd rfl hk, fun h => (by cases h), fun h => (by cases h),
      fun h => (by cases h), fun h => (by cases h), fun h => (by cases h)⟩⟩
  | fresh d => exact ⟨rfl, fun _ => ⟨fun hk => absurd rfl hk, fun h => (by cases h), fun h => (by cases h),
      fun h => (by cases h), fun h => (by cases h), fun h => (by cases h)⟩⟩
  | step e _ he ih => exact fi_step ih he

/-- **No tab is reloaded mid-game unless its own user asked**, in every
    interleaving of deploys, installs of all three designs, both tabs'
    Update and Force update clicks, Try Again and Close, failed and silent
    reinstalls (landing on a tab whose own Update is under way too), the
    wingbeat's wait before every update reload, and the controllerchange
    each activation fires in every tab. -/
theorem no_forced_midgame {E : Env} {s : State} (h : Reachable E s) : s.forcedMidGame = false :=
  (fi_reachable h).1

/-- And every reload a tab has pending (the wingbeat's wait) is its own
    update's, with updateReloadComing set. -/
theorem pending_is_asked {E : Env} {s : State} (h : Reachable E s) (t : Bool) (hp : (s.tabs t).pend = true) :
    (s.tabs t).appUpdating = true ∧ (s.tabs t).coming = true :=
  ⟨((fi_reachable h).2 t).2.2.1 hp, ((fi_reachable h).2 t).2.2.2.1 hp⟩

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

theorem w_boot {E : Env} {s : State} (h : W s) (t : Bool) (auto : Bool) (sv : Option Nat × Nat × (Nat × Nat)) :
    W (bootFrom E t auto sv s) := by
  obtain ⟨c, bb, p⟩ := sv
  unfold bootFrom
  intro u w hw
  simp only [updT_tabs] at hw
  split at hw
  · cases c <;> simp at hw
  · exact h u w hw

theorem w_reload {E : Env} {s : State} (h : W s) (t : Bool) (auto : Bool) : W (reload E t auto s) :=
  w_boot h t auto _

theorem w_applyStart {E : Env} {s : State} (h : W s) (t : Bool) : W (applyStart E t s) := by
  unfold applyStart
  have h1 : W (updT t (fun x => { x with appUpdating := true, modal := false, shield := true, coming := true, failed := false })
      { s with intents := s.intents + 1 }) := by w_fr h
  simp only []
  split
  · w_fr h1
  · split
    · have h2 := w_updCheck h1
      intro u w hw; simp only [updT_tabs] at hw
      split at hw
      · cases hw
      · exact h2 u w hw
    · w_fr h1

theorem w_rFailed {s : State} (h : W s) : W (rFailed s) := by
  intro u w hw
  simp only [rFailed_tabs, failTab_applyK] at hw
  exact h u w hw

theorem w_rSilent {s : State} (h : W s) : W (rSilent s) := by
  intro u w hw
  simp only [rSilent_tabs] at hw
  by_cases hf : (s.tabs u).force = true
  · simp [hf] at hw
  · simp only [hf] at hw; exact h u w (by simpa using hw)

theorem w_startForce {s : State} (h : W s) (t : Bool) : W (startForce t s) := by
  unfold startForce; simp only []
  split <;>
  · intro u w hw
    simp only [updT_tabs, rClear_tabs] at hw
    by_cases hut : u = t
    · subst hut; simp only [↓reduceIte] at hw
      first | cases hw | exact h u w hw
    · simp only [hut, ↓reduceIte] at hw; exact h u w hw

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
    intro u w hw
    exfalso
    simp only [updT_tabs] at hw
    split at hw
    · cases hw
    simp only [wipe, clearInst_tabs, redund] at hw
    split at hw
    · rename_i v hv
      simp only [mapTabs_tabs, onRedundant_applyK] at hw
      split at hw
      · cases hw
      · have := h u w hw; rw [hv] at this; cases this; simp_all
    · rename_i hv
      exact w_none h (by cases hh : s.installing <;> simp_all) u w hw
  | userReload t => exact w_reload h t false
  | forceDone t => simp only [step]; w_fr h
  | landReload t => exact w_reload h t true
  | forceStart t => exact w_startForce (by w_fr h) t
  | forceRetry t => exact w_startForce h t
  | rStop => exact w_rSilent h
  | ccFire t =>
    simp only [step]; split
    · split
      · w_fr h
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
  | confirm t => exact w_applyStart (E := E) h t
  | newerApply t =>
    have h1 : W (updT t (fun x => { x with newer := false }) s) := by w_fr h
    exact w_applyStart (E := E) h1 t
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
  | navQ t => exact w_boot h t false _
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
  have h1 : RI E (updT t (fun x => { x with appUpdating := true, modal := false, shield := true, coming := true, failed := false })
      { s with intents := s.intents + 1 }) := by r_fr h
  unfold applyStart; simp only []; split
  · r_fr h1
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

theorem ri_rSilent {E : Env} {s : State} (h : RI E s) : RI E (rSilent s) := by
  obtain ⟨a1, _, _, _⟩ := h
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro p hp; simp [rSilent, rClear] at hp
  · intro _; refine ⟨?_, ?_⟩ <;> intro _ hj <;> simp [rSilent, rClear] at hj
  · intro _ a b hb; cases a <;> simp [rSilent, rClear, staged] at hb
  · intro ho; simp [rSilent, rClear] at ho

theorem ri_startForce {E : Env} {s : State} (h : RI E s) (t : Bool) : RI E (startForce t s) := by
  unfold startForce; simp only []; split
  · refine ⟨?_, ?_, ?_, ?_⟩
    · intro p hp; simp [rClear] at hp
    · intro _; refine ⟨?_, ?_⟩ <;> intro _ hj <;> simp [rClear] at hj
    · intro _ a b hb; cases a <;> simp [rClear, staged] at hb
    · intro ho; simp [rClear] at ho
  · r_fr h

theorem ri_step {E : Env} {s : State} {e : Event} (h : RI E s) (he : en E s e = true) : RI E (step E s e) := by
  have hs := h
  obtain ⟨a1, a2, a3, a4⟩ := h
  cases e with
  | deploy =>
    refine ⟨fun p hp => ?_, fun ho => ⟨fun j hj => ?_, fun w hw => ?_⟩, a3, a4⟩
    · have := a1 p hp; simp only [step]; omega
    · obtain ⟨p, q1, q2, q3⟩ := (a2 ho).1 j hj; exact ⟨p, q1, q2, by simp only [step]; omega⟩
    · obtain ⟨p, q1, q2, q3⟩ := (a2 ho).2 w hw; exact ⟨p, q1, q2, by simp only [step]; omega⟩
  | forceStart t => exact ri_startForce (by r_fr hs) t
  | forceRetry t => exact ri_startForce hs t
  | rStop => exact ri_rSilent hs
  | landReload t => exact ri_reload hs t true
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
  | rPutJs => simp only [step]; (repeat' split) <;> r_fr hs
  | rPutWasm => simp only [step]; (repeat' split) <;> r_fr hs
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
      · r_fr hs
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
    simp only [step, wipe]
    unfold redund; split <;> r_fr hs
  | forceDone t => simp only [step]; r_fr hs
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
    injective). An older design's commit is still two puts into the live
    cache (`legacy_force_update_serves_half_written_cache`); this design's
    moves the pointer once (`cache_is_one_build`). -/
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
  wf_frame (wf_clear h) rfl rfl rfl rfl rfl rfl rfl rfl (fun u => by simp [installFailed])

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

theorem serve_isB {E : Env} {s : State} (h : Wf E s) {c : Option Nat} {bb : Nat} {p : Nat × Nat}
    (hsv : serve E s = (c, bb, p)) : IsB E .js p.1 ∧ IsB E .wasm p.2 := by
  have hb : IsB E .js (E.bytes s.dep).1 ∧ IsB E .wasm (E.bytes s.dep).2 := ⟨⟨_, rfl⟩, ⟨_, rfl⟩⟩
  unfold serve at hsv
  split at hsv
  · split at hsv
    · cases hsv; exact (h.2.2.2.2.1 _ _ (by assumption)).2
    · cases hsv; exact hb
  · cases hsv; exact hb

theorem serveQ_isB {E : Env} {s : State} (h : Wf E s) {c : Option Nat} {bb : Nat} {p : Nat × Nat}
    (hsv : serveQ E s = (c, bb, p)) : IsB E .js p.1 ∧ IsB E .wasm p.2 := by
  unfold serveQ at hsv
  cases ha : s.active with
  | none => simp only [ha] at hsv; exact serve_isB h hsv
  | some v =>
    by_cases hg : E.curGen v = true
    · simp only [ha, hg, ↓reduceIte] at hsv; exact serve_isB h hsv
    · cases hc : s.cache v with
      | none => simp only [ha, hg, hc, Bool.false_eq_true, ↓reduceIte] at hsv; cases hsv; exact ⟨⟨_, rfl⟩, ⟨_, rfl⟩⟩
      | some q =>
        have hq := (h.2.2.2.2.1 v q hc).2.2
        simp only [ha, hg, hc, Bool.false_eq_true, ↓reduceIte] at hsv; cases hsv
        exact ⟨⟨_, rfl⟩, hq⟩

theorem wf_boot {E : Env} {s : State} (h : Wf E s) (t : Bool) (auto : Bool) {c : Option Nat} {bb : Nat}
    {p : Nat × Nat} (hp : IsB E .js p.1 ∧ IsB E .wasm p.2) : Wf E (bootFrom E t auto (c, bb, p) s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8⟩ := h
  unfold bootFrom
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

theorem wf_reload {E : Env} {s : State} (h : Wf E s) (t : Bool) (auto : Bool) : Wf E (reload E t auto s) := by
  unfold reload
  generalize hsv : serve E s = sv
  obtain ⟨c, bb, p⟩ := sv
  exact wf_boot h t auto (serve_isB h hsv)

theorem wf_showBtn {E : Env} {s : State} (h : Wf E s) (t : Bool) (v : Nat) : Wf E (showBtn t v s) := by
  unfold showBtn; wf_fr h

theorem wf_applyStart {E : Env} {s : State} (h : Wf E s) (t : Bool) : Wf E (applyStart E t s) := by
  have h1 : Wf E (updT t (fun x => { x with appUpdating := true, modal := false, shield := true, coming := true, failed := false })
      { s with intents := s.intents + 1 }) := by wf_fr h
  unfold applyStart; simp only []; split
  · wf_fr h1
  · split
    · have := wf_updCheck h1; wf_fr this
    · wf_fr h1

theorem wf_rFailed {E : Env} {s : State} (h : Wf E s) : Wf E (rFailed s) :=
  wf_frame h rfl rfl rfl rfl rfl rfl rfl rfl (fun u => by simp)

theorem wf_rSilent {E : Env} {s : State} (h : Wf E s) : Wf E (rSilent s) := by
  refine wf_frame h rfl rfl rfl rfl rfl rfl rfl rfl (fun u => ?_)
  simp only [rSilent_tabs]
  by_cases hf : (s.tabs u).force = true <;> simp [hf]

theorem wf_startForce {E : Env} {s : State} (h : Wf E s) (t : Bool) : Wf E (startForce t s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8⟩ := h
  unfold startForce; simp only []; split
  · refine ⟨a1, a2, a3, fun w hw => ?_, a5, a6, a7, fun u => ?_⟩
    · simp only [updT_rW] at hw; exact a3 w hw
    · by_cases hut : u = t <;> simp only [hut, ↓reduceIte, updT_tabs, rClear_tabs] <;> exact a8 _
  · refine ⟨a1, a2, a3, a4, a5, a6, a7, fun u => ?_⟩
    by_cases hut : u = t <;> simp only [hut, ↓reduceIte, updT_tabs] <;> exact a8 _

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
      · wf_fr h1
      · split
        · exact wf_reload h1 t true
        · have h2 : Wf E (updT t (fun x => { x with ready := true, hadController := true })
              (updT t (fun x => { x with ccQ := false }) s)) := by wf_fr h1
          split
          · exact wf_showBtn h2 t _
          · exact h2
    · wf_fr h1
  | userReload t => exact wf_reload hs t false
  | landReload t => exact wf_reload hs t true
  | forceRetry t => exact wf_startForce hs t
  | rStop => exact wf_rSilent hs
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
    suffices hw : Wf E (wipe s) by wf_fr hw
    unfold wipe
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
  | forceStart t => exact wf_startForce (by wf_fr hs) t
  | rPutJs =>
    simp only [step]; split
    · rename_i w hw
      split
      · wf_fr hs
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
      split
      · wf_fr hs
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
  | forceDone t => simp only [step]; wf_fr hs
  | navQ t =>
    simp only [step]
    generalize hsv : serveQ E s = sv
    obtain ⟨c, bb, p⟩ := sv
    exact wf_boot hs t false (serveQ_isB hs hsv)
  | rCommit =>
    simp only [step]; split
    · rename_i w hw
      refine ⟨a1, a2, a3, a4, fun u q hq => ?_, a6, a7, a8⟩
      simp only [] at hq; split at hq
      · rename_i hu; subst hu; cases hq; exact ⟨a4 _ hw, ⟨_, rfl⟩, ⟨_, rfl⟩⟩
      · exact a5 u q hq
    · exact hs
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
/-! ### This design's caches each hold one build, Force update and all

With H injective, every cache of this design holds exactly one build's
bytes, the build of the manifest it keeps, DS core files included: for every
interleaving of deploys, installs of all three designs, stale edges, the HTTP
cache, this design's Force update (whatever build it brings in) and its
worker stopped at any point of one (`rFail`, enabled throughout). The install
commits into an emptied cache, whose assets and DS core files each hash to
its manifest; Force update commits into a cache of its own and moves the
pointer only once that holds everything (`rCommit`), so the cache a fetch
reads is always the old one whole or the new one whole; a DS core file is
kept only when its digest is that cache's manifest's, and put only into the
cache whose manifest it was checked against. Every DS core file this design
serves is therefore its cache's build (`lzBad`). -/

def NI (E : Env) (s : State) : Prop :=
  (∀ v p, E.curGen v = true → s.cache v = some p → ∃ m, s.cman v = some m ∧ p = E.bytes m) ∧
  (∀ v l x, E.curGen v = true → s.lazy v l = some x → ∃ m, s.cman v = some m ∧ x = E.L l m) ∧
  (∀ v m, s.cman v = some m → E.curGen v = true) ∧
  (∀ m, s.man = some m → s.installing = some m) ∧
  (∀ a x, s.slot a = .have x → ∃ v, s.installing = some v ∧ E.H x = E.H (E.C a v)) ∧
  (∀ l x, s.lslot l = some x → ∃ v, s.installing = some v ∧ E.H x = E.H (E.L l v)) ∧
  (∀ l x, s.rsLz l = some x → ∃ m, s.rMan = some m ∧ E.H x = E.H (E.L l m)) ∧
  s.lzBad = false ∧
  (∀ u l x, s.lazy u l = some x → u ≤ s.dep) ∧
  (∀ l w m, s.lzF l = some (w, m) → w ≤ s.dep)

theorem ni_frame {E : Env} {s s' : State} (h : NI E s) (e1 : s'.cache = s.cache) (e2 : s'.cman = s.cman)
    (e3 : s'.lazy = s.lazy) (e4 : s'.man = s.man) (e5 : s'.installing = s.installing) (e6 : s'.slot = s.slot)
    (e7 : s'.lslot = s.lslot) (e8 : s'.rsLz = s.rsLz) (e9 : s'.rMan = s.rMan) (e10 : s'.lzBad = s.lzBad)
    (e11 : s'.dep = s.dep) (e12 : s'.lzF = s.lzF) : NI E s' := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9, a10⟩ := h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    simp only [e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12] <;> assumption

macro "n_fr" h:term : tactic => `(tactic| (exact ni_frame $h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl))

theorem cur_false_of_not_new {E : Env} {v : Nat} (h : E.newGen v = false) : E.curGen v = false := by
  cases hc : E.curGen v
  · rfl
  · rw [Env.newGen_of_cur hc] at h; cases h

theorem ni_clear {E : Env} {s : State} (h : NI E s) : NI E (clearInst s) := by
  obtain ⟨a1, a2, a3, _, _, _, a7, a8, a9, a10⟩ := h
  refine ⟨a1, a2, a3, ?_, ?_, ?_, a7, a8, a9, a10⟩ <;> intros <;> simp_all [clearInst]

theorem ni_start {E : Env} {s : State} (h : NI E s) : NI E (startInst s) := by
  obtain ⟨a1, a2, a3, _, _, _, a7, a8, a9, a10⟩ := h
  refine ⟨a1, a2, a3, ?_, ?_, ?_, a7, a8, a9, a10⟩ <;> intros <;> simp_all [startInst, clearInst]

theorem ni_updCheck {E : Env} {s : State} (h : NI E s) : NI E (updCheck s) := by
  unfold updCheck; split
  · exact ni_start h
  · exact h

theorem ni_installFailed {E : Env} {s : State} (h : NI E s) (v : Nat) : NI E (installFailed v s) := by
  have h1 := ni_clear h
  exact ni_frame h1 rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl

theorem ni_activate {E : Env} {s : State} (h : NI E s) (v : Nat) : NI E (activate v s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9, a10⟩ := h
  refine ⟨fun u p hg hp => ?_, fun u l x hg hx => ?_, fun u m hm => ?_, a4, a5, a6, a7, a8,
    fun u l x hx => ?_, a10⟩
  · simp only [activate, mapTabs_cache, mapTabs_cman] at hp ⊢
    by_cases hu : u = v
    · subst hu; simp only [↓reduceIte] at hp ⊢; exact a1 _ _ hg hp
    · simp only [hu, ↓reduceIte] at hp; cases hp
  · simp only [activate, mapTabs_lazy, mapTabs_cman] at hx ⊢
    by_cases hu : u = v
    · subst hu; simp only [↓reduceIte] at hx ⊢; exact a2 _ _ _ hg hx
    · simp only [hu, ↓reduceIte] at hx; cases hx
  · simp only [activate, mapTabs_cman] at hm
    by_cases hu : u = v
    · subst hu; simp only [↓reduceIte] at hm; exact a3 _ _ hm
    · simp only [hu, ↓reduceIte] at hm; cases hm
  · simp only [activate, mapTabs_lazy] at hx
    by_cases hu : u = v
    · subst hu; simp only [↓reduceIte] at hx; exact a9 _ _ _ hx
    · simp only [hu, ↓reduceIte] at hx; cases hx

theorem ni_installed {E : Env} {s : State} (h : NI E s) (v : Nat) : NI E (installed v s) := by
  have h1 : NI E (mapTabs (onInstalled v) (clearInst s)) :=
    ni_frame (ni_clear h) rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  have hw : ∀ X : State, NI E X → NI E { X with waiting := some v } :=
    fun X h => ni_frame h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  have hq : ∀ X : State, NI E X → NI E { X with skipQ := some v } :=
    fun X h => ni_frame h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  unfold installed; simp only []
  split <;> split <;> first
    | exact ni_activate h1 v
    | exact hw _ h1
    | exact hq _ (ni_activate h1 v)
    | exact hq _ (hw _ h1)

theorem ni_boot {E : Env} {s : State} (h : NI E s) (t : Bool) (auto : Bool) (sv : Option Nat × Nat × (Nat × Nat)) :
    NI E (bootFrom E t auto sv s) := by
  obtain ⟨c, b, p⟩ := sv; unfold bootFrom; n_fr h

theorem ni_reload {E : Env} {s : State} (h : NI E s) (t : Bool) (auto : Bool) : NI E (reload E t auto s) :=
  ni_boot h t auto _

theorem ni_rFailed {E : Env} {s : State} (h : NI E s) : NI E (rFailed s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, _, a8, a9, a10⟩ := h
  exact ⟨a1, a2, a3, a4, a5, a6, fun l x hx => by simp [rFailed, rClear] at hx, a8, a9, a10⟩

theorem ni_applyStart {E : Env} {s : State} (h : NI E s) (t : Bool) : NI E (applyStart E t s) := by
  unfold applyStart
  have h1 : NI E (updT t (fun x => { x with appUpdating := true, modal := false, shield := true, coming := true, failed := false })
      { s with intents := s.intents + 1 }) := by n_fr h
  simp only []
  split
  · n_fr h1
  · split
    · have := ni_updCheck h1; n_fr this
    · n_fr h1

theorem ni_rSilent {E : Env} {s : State} (h : NI E s) : NI E (rSilent s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, _, a8, a9, a10⟩ := h
  exact ⟨a1, a2, a3, a4, a5, a6, fun l x hx => by simp [rSilent, rClear] at hx, a8, a9, a10⟩

theorem ni_startForce {E : Env} {s : State} (h : NI E s) (t : Bool) : NI E (startForce t s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9, a10⟩ := h
  unfold startForce; simp only []; split
  · exact ⟨a1, a2, a3, a4, a5, a6, fun l x hx => by simp [rClear] at hx, a8, a9, a10⟩
  · exact ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9, a10⟩

theorem ni_step {E : Env} (hH : Injective E.H) {s : State} {e : Event} (h : NI E s) (hw : Wf E s)
    (hr : RI E s) (he : en E s e = true) : NI E (step E s e) := by
  have hs := h
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9, a10⟩ := h
  cases e with
  | deploy =>
    refine ⟨a1, a2, a3, a4, a5, a6, a7, a8, fun u l x hx => ?_, fun l w m hf => ?_⟩
    · have := a9 u l x hx; simp only [step]; omega
    · have := a10 l w m hf; simp only [step]; omega
  | browserCheck => exact ni_updCheck hs
  | probeFirst | fetchJs | fetchWasm | httpFill _ _ | httpEvict _ | rProbe0 | rFetchJs | rFetchWasm | rVerify
  | gameOn _ | gameOff _ | notNow _ | checkStart _ | chkCur _ | chkLatest _ | chkSw _ | newerStart _ =>
    simp only [step]; n_fr hs
  | installEnd =>
    simp only [step]; split
    · rename_i v p j w hv _ _ _
      have hg : E.curGen v = false := by
        apply cur_false_of_not_new
        simp only [en, oldInst, hv, Bool.and_eq_true, Bool.not_eq_true'] at he; exact he.1.1
      split
      · apply ni_installed
        refine ⟨fun u q hgu hq => ?_, a2, a3, a4, a5, a6, a7, a8, a9, a10⟩
        simp only [] at hq; split at hq
        · rename_i hu; subst hu; rw [hg] at hgu; cases hgu
        · exact a1 u q hgu hq
      · exact ni_installFailed hs v
    · exact hs
  | installFail =>
    simp only [step]; split
    · exact ni_installFailed hs _
    · exact hs
  | nManifest bb =>
    simp only [step]; split
    · rename_i v hv; split
      · rename_i hbv; simp only [beq_iff_eq] at hbv; subst hbv
        refine ⟨a1, a2, a3, fun m hm => ?_, a5, a6, a7, a8, a9, a10⟩
        simp only [Option.some.injEq] at hm; subst hm; exact hv
      · exact ni_installFailed hs v
    · exact hs
  | nLook a =>
    simp only [step]; split
    · rename_i m hm
      have hi := a4 m hm
      split
      · rename_i x hx
        have hok : E.H x = E.H (E.C a m) := heldBytes_ok hx
        refine ⟨a1, a2, a3, a4, fun a' x' hx' => ?_, a6, a7, a8, a9, a10⟩
        simp only [setSlot] at hx'; split at hx'
        · rename_i ha; subst ha; cases hx'; exact ⟨m, hi, hok⟩
        · exact a5 a' x' hx'
      · refine ⟨a1, a2, a3, a4, fun a' x' hx' => ?_, a6, a7, a8, a9, a10⟩
        simp only [setSlot] at hx'; split at hx'
        · cases hx'
        · exact a5 a' x' hx'
    · exact hs
  | nNet a bb =>
    simp only [step]; split
    · rename_i v m hv hm
      have hmv : m = v := by have := a4 m hm; rw [hv] at this; cases this; rfl
      subst hmv
      split
      · rename_i hok; simp only [beq_iff_eq] at hok
        refine ⟨a1, a2, a3, a4, fun a' x' hx' => ?_, a6, a7, a8, a9, a10⟩
        simp only [setSlot] at hx'; split at hx'
        · rename_i ha; subst ha; cases hx'; exact ⟨m, hv, hok⟩
        · exact a5 a' x' hx'
      · exact ni_installFailed (s := { s with dl := s.dl + 1 }) ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9, a10⟩ _
    · exact hs
  | nCommit =>
    simp only [step]; split
    · rename_i v xj xw hv hj hw'
      obtain ⟨v1, hv1, hj'⟩ := a5 .js xj hj
      obtain ⟨v2, hv2, hw''⟩ := a5 .wasm xw hw'
      rw [hv] at hv1 hv2; cases hv1; cases hv2
      have e1 := hH _ _ hj'
      have e2 := hH _ _ hw''
      have hvd : v ≤ s.dep := hw.1 v hv
      have hl : ∀ l x, s.lslot l = some x → x = E.L l v := by
        intro l x hx; obtain ⟨v', hv', hh⟩ := a6 l x hx; rw [hv] at hv'; cases hv'; exact hH _ _ hh
      refine ⟨fun u q hg hq => ?_, fun u l x hg hx => ?_, fun u m hm => ?_, a4, a5, a6, a7, a8,
        fun u l x hx => ?_, a10⟩
      · by_cases hu : u = v
        · subst hu; simp only [↓reduceIte, Option.some.injEq] at hq; subst hq
          exact ⟨u, by simp [hg], by simp [Env.bytes, e1, e2]⟩
        · simp only [hu, ↓reduceIte] at hq; simp only [hu, decide_false, Bool.false_and, Bool.false_eq_true,
            ↓reduceIte]; exact a1 u q hg hq
      · by_cases hu : u = v
        · subst hu; simp only [hg, decide_true, Bool.and_self, ↓reduceIte] at hx ⊢
          exact ⟨u, rfl, hl l x hx⟩
        · simp only [hu, decide_false, Bool.false_and, Bool.false_eq_true, ↓reduceIte] at hx ⊢
          exact a2 u l x hg hx
      · by_cases hu : u = v
        · subst hu; by_cases hg : E.curGen u = true
          · exact hg
          · simp only [hg, decide_true, Bool.and_false, Bool.false_eq_true, ↓reduceIte] at hm; exact a3 u m hm
        · simp only [hu, decide_false, Bool.false_and, Bool.false_eq_true, ↓reduceIte] at hm; exact a3 u m hm
      · by_cases hu : u = v
        · subst hu; exact hvd
        · simp only [hu, decide_false, Bool.false_and, Bool.false_eq_true, ↓reduceIte] at hx; exact a9 u l x hx
    · exact hs
  | nCheck =>
    simp only [step]; split
    · split
      · exact ni_installed hs _
      · exact ni_installFailed hs _
    · exact hs
  | regResolve t =>
    have h1 : NI E (updT t (fun x => { x with regd := true }) s) := by n_fr hs
    simp only [step]; split
    · unfold showBtn; n_fr h1
    · split
      · exact ni_start h1
      · exact h1
  | coreLoaded t => simp only [step]; split <;> n_fr hs
  | instFire t =>
    have h1 : NI E (updT t (fun x => { x with instQ := none }) s) := by n_fr hs
    simp only [step]; split
    · split
      · unfold showBtn; n_fr h1
      · exact h1
    · exact h1
  | skipDeliver =>
    simp only [step]; split
    · split
      · exact ni_activate (s := { s with skipQ := none }) hs _
      · exact hs
    · exact hs
  | ccFire t =>
    have h1 : NI E (updT t (fun x => { x with ccQ := false }) s) := by n_fr hs
    simp only [step]; split
    · split
      · n_fr h1
      · split
        · exact ni_reload h1 t true
        · split
          · unfold showBtn; n_fr h1
          · n_fr h1
    · n_fr h1
  | userReload t => exact ni_reload hs t false
  | landReload t => exact ni_reload hs t true
  | forceRetry t => exact ni_startForce hs t
  | rStop => exact ni_rSilent hs
  | failClose t => simp only [step]; n_fr hs
  | updClick t =>
    simp only [step]; split
    · n_fr hs
    · exact ni_applyStart hs t
  | confirm t => exact ni_applyStart hs t
  | applyResume t => simp only [step]; split <;> n_fr hs
  | resetFire t =>
    simp only [step]
    suffices hw : NI E (wipe s) by n_fr hw
    unfold wipe
    refine ⟨fun _ _ _ h => by simp at h, fun _ _ _ _ h => by simp at h, fun _ _ h => by simp at h,
      fun _ h => by simp [clearInst] at h, fun _ _ h => by simp [clearInst] at h,
      fun _ _ h => by simp [clearInst] at h, ?_, ?_, fun _ _ _ h => by simp at h, fun l w m hf => ?_⟩
    · intro l x hx; have : (redund s).rsLz = s.rsLz := by unfold redund; split <;> rfl
      simp only [clearInst, this] at hx ⊢
      have : (redund s).rMan = s.rMan := by unfold redund; split <;> rfl
      rw [this]; exact a7 l x hx
    · show (redund s).lzBad = false
      unfold redund; split <;> simpa using a8
    · have e1 : (redund s).lzF = s.lzF := by unfold redund; split <;> rfl
      have e2 : (redund s).dep = s.dep := by unfold redund; split <;> rfl
      simp only [clearInst, e1, e2] at hf ⊢; exact a10 l w m hf
  | chkEval t =>
    simp only [step]; split
    · have h1 : NI E (updT t (fun x => { x with chk := none }) s) := by n_fr hs
      split
      · unfold showBtn; n_fr h1
      · exact h1
    · exact hs
  | forceStart t => exact ni_startForce (by n_fr hs) t
  | rMan b =>
    have hn : s.rMan = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.1.2
    refine ⟨a1, a2, a3, a4, a5, a6, fun l x hx => ?_, a8, a9, a10⟩
    obtain ⟨m, hm, _⟩ := a7 l x hx; rw [hn] at hm; cases hm
  | rNet a b =>
    simp only [step]; split
    · split
      · cases a <;> n_fr hs
      · exact ni_rFailed hs
    · exact hs
  | rFail => exact ni_rFailed hs
  | rPutJs | rPutWasm =>
    simp only [step]; split
    · rename_i w hw'
      split
      · n_fr hs
      · rename_i hg
        refine ⟨fun u q hgu hq => ?_, a2, a3, a4, a5, a6, a7, a8, a9, a10⟩
        simp only [] at hq; split at hq
        · rename_i hu; subst hu; simp [hg] at hgu
        · exact a1 u q hgu hq
    · exact hs
  | forceDone t => simp only [step]; n_fr hs
  | newerApply t => exact ni_applyStart (s := updT t _ s) (by n_fr hs) t
  | navQ t => exact ni_boot hs t false _
  | lzOld l b =>
    simp only [step]; split
    · rename_i v hv
      have hg : E.curGen v = false := by
        simp only [en, hv, Bool.and_eq_true, Bool.not_eq_true'] at he; exact he.1
      split
      · exact hs
      · refine ⟨a1, fun u k x hgu hx => ?_, a3, a4, a5, a6, a7, a8, fun u k x hx => ?_, a10⟩
        · simp only [] at hx; split at hx
          · rename_i hu; subst hu; simp [hg] at hgu
          · exact a2 u k x hgu hx
        · simp only [] at hx; split at hx
          · rename_i hu; subst hu; exact hw.2.2.1 _ hv
          · exact a9 u k x hx
    · exact hs
  | lzHit l =>
    simp only [step]; split
    · rename_i v hv
      have hg : E.curGen v = true := by simp only [en, hv, Bool.and_eq_true] at he; exact he.1
      split
      · rename_i x hx
        obtain ⟨m, hm, hxm⟩ := a2 v l x hg hx
        exact ⟨a1, a2, a3, a4, a5, a6, a7, by simp [a8, hm, hxm], a9, a10⟩
      · exact hs
    · exact hs
  | lzStart l =>
    simp only [step]; split
    · rename_i v hv
      split
      · refine ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9, fun k w m hf => ?_⟩
        simp only [] at hf; split at hf
        · simp only [Option.some.injEq, Prod.mk.injEq] at hf; obtain ⟨rfl, -⟩ := hf; exact hw.2.2.1 _ hv
        · exact a10 k w m hf
      · exact hs
    · exact hs
  | lzNet l b put =>
    simp only [step]; split
    · rename_i w m hf
      have hwd : w ≤ s.dep := a10 l w m hf
      have b10 : ∀ k w' m', (if k = l then none else s.lzF k) = some (w', m') → w' ≤ s.dep := by
        intro k w' m' h'; split at h'
        · cases h'
        · exact a10 k w' m' h'
      split
      · rename_i hok; simp only [beq_iff_eq] at hok
        have hb : E.L l b = E.L l m := hH _ _ hok
        split
        · rename_i hp; simp only [Bool.and_eq_true, beq_iff_eq] at hp
          refine ⟨a1, fun u k x hgu hx => ?_, a3, a4, a5, a6, a7, by simp [a8, hb], fun u k x hx => ?_, b10⟩
          · simp only [] at hx; split at hx
            · rename_i hu; subst hu; dsimp only at hx; split at hx
              · rename_i hk; subst hk; cases hx; exact ⟨m, hp.2, hb⟩
              · exact a2 u k x hgu hx
            · exact a2 u k x hgu hx
          · simp only [] at hx; split at hx
            · rename_i hu; subst hu; exact hwd
            · exact a9 u k x hx
        · exact ⟨a1, a2, a3, a4, a5, a6, a7, by simp [a8, hb], a9, b10⟩
      · exact ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9, b10⟩
    · exact hs
  | nLookLz l =>
    simp only [step]; split
    · rename_i m hm
      have hi := a4 m hm
      refine ⟨a1, a2, a3, a4, a5, fun k x hx => ?_, a7, a8, a9, a10⟩
      simp only [] at hx; split at hx
      · rename_i hk; subst hk
        refine ⟨m, hi, ?_⟩
        unfold heldLazy at hx
        have := List.find?_some hx; simpa using this
      · exact a6 k x hx
    · exact hs
  | rNetLz l b =>
    simp only [step]; split
    · rename_i m hm
      split
      · rename_i hok; simp only [beq_iff_eq] at hok
        refine ⟨a1, a2, a3, a4, a5, a6, fun k x hx => ?_, a8, a9, a10⟩
        simp only [] at hx; split at hx
        · rename_i hk; subst hk; cases hx; exact ⟨m, hm, hok⟩
        · exact a7 k x hx
      · exact hs
    · exact hs
  | rCommit =>
    have hcur : curR E s = true := by simp only [en, Bool.and_eq_true] at he; exact he.1.1.1.1.2
    have hok : s.rOk = true := by simp only [en, Bool.and_eq_true] at he; exact he.1.1.1.2
    simp only [step]; split
    · rename_i w hrw
      have hg : E.curGen w = true := by simpa [curR, hrw] using hcur
      have hnew : newR E s = true := by simp [newR, hrw, Env.newGen_of_cur hg]
      obtain ⟨_, _, r3, r4⟩ := hr
      obtain ⟨j, ww, hj, hww, hc⟩ := r4 hok
      have hm : s.rMan.isSome = true := by
        rcases hc with ⟨ho, _⟩ | ⟨_, hm⟩
        · simp [oldR, hrw, Env.newGen_of_cur hg] at ho
        · exact hm
      obtain ⟨m, hm⟩ := Option.isSome_iff_exists.mp hm
      obtain ⟨m1, hm1, hj'⟩ := r3 hnew .js j (by simp [staged, hj])
      obtain ⟨m2, hm2, hw'⟩ := r3 hnew .wasm ww (by simp [staged, hww])
      rw [hm] at hm1 hm2; cases hm1; cases hm2
      have e1 := hH _ _ hj'
      have e2 := hH _ _ hw'
      have hwd : w ≤ s.dep := hw.2.2.2.1 w hrw
      refine ⟨fun u q hgu hq => ?_, fun u k x hgu hx => ?_, fun u m' hm' => ?_, a4, a5, a6, a7, a8,
        fun u k x hx => ?_, a10⟩
      · simp only [] at hq ⊢; split at hq
        · rename_i hu; subst hu; simp only [↓reduceIte, Option.some.injEq] at hq ⊢; subst hq
          exact ⟨m, hm, by simp [Env.bytes, hj, hww, e1, e2]⟩
        · rename_i hu; simp only [hu, ↓reduceIte]; exact a1 u q hgu hq
      · simp only [] at hx ⊢; split at hx
        · rename_i hu; subst hu; simp only [↓reduceIte]
          obtain ⟨m', hm', hx'⟩ := a7 k x hx; rw [hm] at hm'; cases hm'
          exact ⟨m, hm, hH _ _ hx'⟩
        · rename_i hu; simp only [hu, ↓reduceIte]; exact a2 u k x hgu hx
      · simp only [] at hm'; split at hm'
        · rename_i hu; subst hu; exact hg
        · exact a3 u m' hm'
      · simp only [] at hx; split at hx
        · rename_i hu; subst hu; exact hwd
        · exact a9 u k x hx
    · exact hs

theorem ni_reachable {E : Env} (hH : Injective E.H) {s : State} (h : Reachable E s) : NI E s := by
  induction h with
  | init =>
    refine ⟨fun v p hg hp => ?_, ?_, fun v m hm => ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> try (simp [init]; done)
    · simp only [init] at hp ⊢; split at hp
      · rename_i hv; subst hv; cases hp; exact ⟨0, by simp [hg], rfl⟩
      · cases hp
    · simp only [init] at hm; split at hm
      · rename_i hv; simp only [Bool.and_eq_true, decide_eq_true_eq] at hv; rw [hv.1]; exact hv.2
      · cases hm
  | fresh d => refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [initFresh, init]
  | step e hreach he ih => exact ni_step hH ih (wf_reachable hreach) (ri_reachable hreach) he

/-- **One build per cache, Force update and all.** With the digest
    injective, every cache of this design holds exactly the bytes of one
    build, the one whose manifest it keeps, its DS core files included, in
    every reachable state: whatever deploys, stale edges and older designs'
    workers do, and wherever this design's Force update is stopped. The fetch
    handler reads only the active worker's cache, so no fetch observes a
    cache holding two builds. -/
theorem cache_is_one_build {E : Env} (hH : Injective E.H) {s : State} (h : Reachable E s) {v : Nat}
    (hv : E.curGen v = true) {p : Nat × Nat} (hc : s.cache v = some p) :
    ∃ m, s.cman v = some m ∧ p = E.bytes m ∧ ∀ l x, s.lazy v l = some x → x = E.L l m := by
  obtain ⟨a1, a2, _⟩ := ni_reachable hH h
  obtain ⟨m, hm, hp⟩ := a1 v p hv hc
  refine ⟨m, hm, hp, fun l x hx => ?_⟩
  obtain ⟨m', hm', hx'⟩ := a2 v l x hv hx
  rw [hm] at hm'; cases hm'; exact hx'

/-- **Every DS core file this design serves is its cache's build**: a copy
    from the cache (checked when it was kept) or a download whose digest is
    the manifest's. A stale edge's nds.wasm beside a fresh nds.js is refused
    (`regress_tampered_lazy_refused`). -/
theorem lazy_served_is_its_build {E : Env} (hH : Injective E.H) {s : State} (h : Reachable E s) :
    s.lzBad = false :=
  (ni_reachable hH h).2.2.2.2.2.2.2.1

/-- Wherever this design's Force update is stopped before the pointer moves,
    the old cache serves as it was: no step of its download, check or commit
    but `rCommit` writes any cache, kept manifest or DS core file. -/
theorem force_leaves_live_cache_until_pointer {E : Env} {s : State} (hc : curR E s = true) (e : Event)
    (he : e = .rProbe0 ∨ e = .rFetchJs ∨ e = .rFetchWasm ∨ (∃ b, e = .rMan b) ∨ (∃ a b, e = .rNet a b) ∨
      (∃ l b, e = .rNetLz l b) ∨ e = .rVerify ∨ e = .rPutJs ∨ e = .rPutWasm ∨ e = .rFail ∨ e = .rStop) :
    (step E s e).cache = s.cache ∧ (step E s e).cman = s.cman ∧ (step E s e).lazy = s.lazy := by
  have hw : ∃ w, s.rW = some w ∧ E.curGen w = true := by
    unfold curR at hc; split at hc
    · rename_i w hw; exact ⟨w, hw, hc⟩
    · cases hc
  obtain ⟨w, hrw, hg⟩ := hw
  rcases he with rfl | rfl | rfl | ⟨b, rfl⟩ | ⟨a, b, rfl⟩ | ⟨l, b, rfl⟩ | rfl | rfl | rfl | rfl | rfl
  all_goals simp only [step, hrw, hg, ↓reduceIte]
  all_goals (try (repeat' split) <;> (try (cases ‹Asset›)) <;> simp [setStaged, rFailed, rSilent, rClear])
  all_goals (try exact ⟨rfl, rfl, rfl⟩)

/-! ### Loads of the app with a query string -/

/-- A load of the app with any query string is served from the same cache
    entry as "./": under a worker of this design it is the bare load, step
    for step, so every theorem about bare loads covers it. -/
theorem navigation_query_is_the_shell (E : Env) (s : State) (t : Bool) {v : Nat}
    (ha : s.active = some v) (hv : E.curGen v = true) :
    step E s (.navQ t) = step E s (.userReload t) := by
  simp only [step, reload, serveQ, ha, hv, ↓reduceIte]

/-- ...and while that worker's cache is there, no such load goes to the
    network: the page boots the cache's bytes and nothing reaches the HTTP
    cache. (An older worker's took index.html off the network:
    `legacy_query_navigation_mixes_builds`.) -/
theorem navigation_never_net_while_live (E : Env) (s : State) (t : Bool) {v : Nat} {p : Nat × Nat}
    (ha : s.active = some v) (hv : E.curGen v = true) (hc : s.cache v = some p) :
    ((step E s (.navQ t)).tabs t).running = p ∧ (step E s (.navQ t)).http = s.http := by
  simp [step, serveQ, serve, bootFrom, ha, hv, hc]

/-! ### The install carries the DS core over, never downloads it -/

section lslotlemmas
variable (E : Env) (s : State) (v : Nat) (t : Bool) (auto : Bool)
@[simp] theorem installed_lslot : (installed v s).lslot = fun _ => none := by
  unfold installed; simp only []; split <;> split <;> rfl
@[simp] theorem installFailed_lslot : (installFailed v s).lslot = fun _ => none := rfl
@[simp] theorem startInst_lslot : (startInst s).lslot = fun _ => none := rfl
@[simp] theorem clearInst_lslot : (clearInst s).lslot = fun _ => none := rfl
@[simp] theorem bootFrom_lslot (sv : Option Nat × Nat × (Nat × Nat)) : (bootFrom E t auto sv s).lslot = s.lslot := by
  obtain ⟨c, b, p⟩ := sv; rfl
@[simp] theorem reload_lslot : (reload E t auto s).lslot = s.lslot := bootFrom_lslot E s t auto _
@[simp] theorem showBtn_lslot : (showBtn t v s).lslot = s.lslot := rfl
@[simp] theorem activate_lslot : (activate v s).lslot = s.lslot := rfl
@[simp] theorem rFailed_lslot : (rFailed s).lslot = s.lslot := rfl
@[simp] theorem rSilent_lslot : (rSilent s).lslot = s.lslot := rfl
@[simp] theorem startForce_lslot : (startForce t s).lslot = s.lslot := by
  unfold startForce; simp only []; split <;> rfl
@[simp] theorem rClear_lslot : (rClear s).lslot = s.lslot := rfl
@[simp] theorem setStaged_lslot (a : Asset) (b : Nat) : (setStaged s a b).lslot = s.lslot := by
  cases a <;> rfl
@[simp] theorem updCheck_lslot_none (l : Lz) : (updCheck s).lslot l = none ∨ (updCheck s).lslot l = s.lslot l := by
  unfold updCheck; split <;> simp
end lslotlemmas

/-- Only an install's lookup of a DS core file gives it one, and the lookup
    takes the first held copy with the manifest's digest: no step of an
    install downloads a DS core file. -/
theorem lazy_never_downloaded {E : Env} {s : State} {e : Event} {l : Lz} {x : Nat}
    (h : (step E s e).lslot l = some x) :
    s.lslot l = some x ∨ (e = .nLookLz l ∧ ∃ m, s.man = some m ∧ heldLazy E s l m = some x) := by
  have upd : ∀ X : State, (updCheck X).lslot l = some x → X.lslot l = some x := by
    intro X hX; rcases updCheck_lslot_none X l with h1 | h1 <;> rw [h1] at hX
    · cases hX
    · exact hX
  have app : ∀ X : State, ∀ t, (applyStart E t X).lslot l = some x → X.lslot l = some x := by
    intro X t hX; unfold applyStart at hX; simp only [] at hX
    split at hX
    · simpa using hX
    · split at hX
      · have := upd _ (by simpa only [updT_lslot] using hX); simpa using this
      · simpa using hX
  cases e with
  | nLookLz l' =>
    simp only [step] at h; split at h
    · rename_i m hm
      simp only [] at h; split at h
      · rename_i hl; subst hl; exact Or.inr ⟨rfl, m, hm, h⟩
      · exact Or.inl h
    · exact Or.inl h
  | browserCheck => exact Or.inl (upd _ (by simpa [step] using h))
  | updClick t =>
    simp only [step] at h; split at h
    · exact Or.inl (by simpa using h)
    · exact Or.inl (app _ _ h)
  | confirm t => exact Or.inl (app _ _ (by simpa [step] using h))
  | newerApply t =>
    simp only [step] at h
    have := app _ _ h; exact Or.inl (by simpa using this)
  | resetFire t => simp [step, wipe] at h
  | regResolve t =>
    simp only [step] at h; split at h
    · exact Or.inl (by simpa using h)
    · split at h
      · simp at h
      · exact Or.inl (by simpa using h)
  | navQ t => exact Or.inl (by simpa [step] using h)
  | _ =>
    left
    simp only [step] at h
    (repeat' split at h) <;> simp_all <;> (try (cases ‹Asset› <;> simp_all))

/-- And the lookup finds a held copy whenever one has the manifest's digest,
    in any cache, whatever build and design wrote it
    (`old_worker_ds_core_carried_over`). -/
theorem lookupLz_takes_held {E : Env} (hH : Injective E.H) {s : State} (h : Reachable E s) {l : Lz}
    {m : Nat} (hm : s.man = some m) (held : ∃ u x, s.lazy u l = some x ∧ E.H x = E.H (E.L l m)) :
    ∃ x, (step E s (.nLookLz l)).lslot l = some x ∧ E.H x = E.H (E.L l m) := by
  have hb : ∃ x, heldLazy E s l m = some x := by
    unfold heldLazy
    cases hf : ((List.range (s.dep + 1)).filterMap (fun u => s.lazy u l)).find?
        (fun x => E.H x == E.H (E.L l m)) with
    | some x => exact ⟨x, rfl⟩
    | none =>
      exfalso
      rw [List.find?_eq_none] at hf
      obtain ⟨u, x, hx, hok⟩ := held
      have hu := (ni_reachable hH h).2.2.2.2.2.2.2.2.1 u l x hx
      apply hf x
      · simp only [List.mem_filterMap, List.mem_range]
        exact ⟨u, by omega, hx⟩
      · simp [hok]
  obtain ⟨x, hx⟩ := hb
  refine ⟨x, by simp [step, hm, hx], ?_⟩
  unfold heldLazy at hx
  have := List.find?_some hx; simpa using this

/-! ### No page boots two builds

The consistency of every boot, with this design's Force update and query
navigations in: the only steps left out are an older design's Force update
(one put per asset into its live cache:
`legacy_force_update_serves_half_written_cache`) and an older worker's
answer to a query navigation (`legacy_query_navigation_mixes_builds`), both
in code a browser runs only until its worker updates to this design. -/

def benign4 (E : Env) (s : State) : Event → Bool
  | .forceStart _ => match s.active with | some v => E.curGen v | none => true
  | .forceRetry _ => match s.active with | some v => E.curGen v | none => true
  | .navQ _ => match s.active with | some v => E.curGen v | none => true
  | _ => true

inductive Reach4 (E : Env) : State → Prop
  | init : Reach4 E (init E)
  | fresh (d : Nat) : Reach4 E (initFresh E d)
  | step {s : State} (e : Event) : Reach4 E s → en E s e = true → benign4 E s e = true → Reach4 E (step E s e)

theorem reach4_reachable {E : Env} {s : State} (h : Reach4 E s) : Reachable E s := by
  induction h with
  | init => exact .init
  | fresh d => exact .fresh d
  | step e _ he _ ih => exact .step e ih he

/-- What the older designs' caches and installs keep (this design's caches:
    `NI`), and that no older design's reinstall runs. -/
def CS (E : Env) (s : State) : Prop :=
  (∀ v p, E.curGen v = false → s.cache v = some p → p = E.bytes v) ∧
  (∀ p, s.probe0 = some p → s.installing.isSome = true ∧ p ≤ s.dep) ∧
  (∀ j, s.stageJs = some j → ∃ p, s.probe0 = some p ∧ p ≤ j ∧ j ≤ s.dep) ∧
  (∀ w, s.stageWasm = some w → ∃ p, s.probe0 = some p ∧ p ≤ w ∧ w ≤ s.dep) ∧
  (∀ w, s.rW = some w → E.curGen w = true) ∧
  s.mixedBoot = false

theorem cs_frame {E : Env} {s s' : State} (h : CS E s) (ec : s'.cache = s.cache)
    (ep : s'.probe0 = s.probe0) (ej : s'.stageJs = s.stageJs) (ew : s'.stageWasm = s.stageWasm)
    (ei : s'.installing = s.installing) (ed : s'.dep = s.dep) (em : s'.mixedBoot = s.mixedBoot)
    (er : s'.rW = s.rW) : CS E s' := by
  obtain ⟨a1, a2, a3, a4, a5, a6⟩ := h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [ec]; exact a1
  · rw [ep, ei, ed]; exact a2
  · rw [ej, ep, ed]; exact a3
  · rw [ew, ep, ed]; exact a4
  · rw [er]; exact a5
  · rw [em]; exact a6

macro "c_fr" h:term : tactic => `(tactic| (exact cs_frame $h rfl rfl rfl rfl rfl rfl rfl rfl))

theorem cs_clear {E : Env} {s : State} (h : CS E s) : CS E (clearInst s) := by
  obtain ⟨a1, _, _, _, a5, a6⟩ := h
  refine ⟨a1, ?_, ?_, ?_, a5, a6⟩ <;> intros <;> simp_all [clearInst]

theorem cs_start {E : Env} {s : State} (h : CS E s) : CS E (startInst s) := by
  obtain ⟨a1, _, _, _, a5, a6⟩ := h
  refine ⟨a1, ?_, ?_, ?_, a5, a6⟩ <;> intros <;> simp_all [startInst, clearInst]

theorem cs_updCheck {E : Env} {s : State} (h : CS E s) : CS E (updCheck s) := by
  unfold updCheck; split
  · exact cs_start h
  · exact h

theorem cs_installFailed {E : Env} {s : State} (h : CS E s) (v : Nat) : CS E (installFailed v s) := by
  have h1 := cs_clear h
  exact cs_frame h1 rfl rfl rfl rfl rfl rfl rfl rfl

theorem cs_activate {E : Env} {s : State} (h : CS E s) (v : Nat) : CS E (activate v s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6⟩ := h
  refine ⟨fun u p hg hp => ?_, a2, a3, a4, a5, a6⟩
  simp only [activate, mapTabs_cache] at hp
  split at hp
  · exact a1 u p hg hp
  · cases hp

theorem cs_installed {E : Env} {s : State} (h : CS E s) (v : Nat) : CS E (installed v s) := by
  have h1 : CS E (mapTabs (onInstalled v) (clearInst s)) :=
    cs_frame (cs_clear h) rfl rfl rfl rfl rfl rfl rfl rfl
  have hw : ∀ X : State, CS E X → CS E { X with waiting := some v } :=
    fun X h => cs_frame h rfl rfl rfl rfl rfl rfl rfl rfl
  have hq : ∀ X : State, CS E X → CS E { X with skipQ := some v } :=
    fun X h => cs_frame h rfl rfl rfl rfl rfl rfl rfl rfl
  unfold installed; simp only []
  split <;> split <;> first
    | exact cs_activate h1 v
    | exact hw _ h1
    | exact hq _ (cs_activate h1 v)
    | exact hq _ (hw _ h1)

/-- A bare load boots one build: a cache of this design is its manifest's
    build (`NI`), an older one its worker's. -/
theorem serve_build {E : Env} {s : State} (hn : NI E s) (h : CS E s) {c : Option Nat} {b : Nat}
    {p : Nat × Nat} (hs : serve E s = (c, b, p)) : p = E.bytes b := by
  unfold serve at hs
  cases ha : s.active with
  | none => simp only [ha] at hs; cases hs; rfl
  | some v =>
    cases hc : s.cache v with
    | none => simp only [ha, hc] at hs; cases hs; rfl
    | some q =>
      simp only [ha, hc, Prod.mk.injEq] at hs
      obtain ⟨-, hb, hp⟩ := hs
      subst hp; subst hb
      cases hg : E.curGen v
      · have hn' : s.cman v = none := by
          cases hm : s.cman v with
          | none => rfl
          | some m => have := hn.2.2.1 v m hm; rw [hg] at this; cases this
        rw [hn']; exact h.1 v q hg hc
      · obtain ⟨m, hm, hq⟩ := hn.1 v q hg hc
        rw [hm]; exact hq

theorem cs_boot {E : Env} {s : State} (h : CS E s) (t : Bool) (auto : Bool) {c : Option Nat} {b : Nat}
    {p : Nat × Nat} (hp : p = E.bytes b) : CS E (bootFrom E t auto (c, b, p) s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6⟩ := h
  unfold bootFrom
  exact ⟨a1, a2, a3, a4, a5, by simp [a6, hp]⟩

theorem cs_reload {E : Env} {s : State} (hn : NI E s) (h : CS E s) (t : Bool) (auto : Bool) :
    CS E (reload E t auto s) := by
  unfold reload
  generalize hsv : serve E s = sv
  obtain ⟨c, b, p⟩ := sv
  exact cs_boot h t auto (serve_build hn h hsv)

theorem cs_applyStart {E : Env} {s : State} (_hn : NI E s) (h : CS E s) (t : Bool) : CS E (applyStart E t s) := by
  unfold applyStart
  let s1 := updT t (fun x => { x with appUpdating := true, modal := false, shield := true, coming := true, failed := false })
    { s with intents := s.intents + 1 }
  have h1 : CS E s1 := by c_fr h
  simp only []
  split
  · c_fr h1
  · split
    · have := cs_updCheck h1; c_fr this
    · c_fr h1

/-- startForce: the worker running it is the active one (`benign4`: of this
    design, or none), or nothing runs (no controller: the full reset). -/
theorem cs_startForce {E : Env} {s : State} (h : CS E s) (t : Bool)
    (hb : ∀ w, s.active = some w → E.curGen w = true) : CS E (startForce t s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6⟩ := h
  unfold startForce; simp only []; split
  · exact ⟨a1, a2, a3, a4, fun w hw => hb w (by simpa using hw), a6⟩
  · exact ⟨a1, a2, a3, a4, a5, a6⟩

theorem cs_step {E : Env} (hH : Injective E.H) {s : State} {e : Event} (h : CS E s) (hn : NI E s)
    (he : en E s e = true) (hb : benign4 E s e = true) : CS E (step E s e) := by
  have hs := h
  obtain ⟨a1, a2, a3, a4, a5, a6⟩ := h
  cases e with
  | deploy =>
    refine ⟨a1, fun p hp => ?_, fun j hj => ?_, fun w hw => ?_, a5, a6⟩
    · have := a2 p hp; exact ⟨this.1, by simp only [step]; omega⟩
    · obtain ⟨p, h1, h2, h3⟩ := a3 j hj; exact ⟨p, h1, h2, by simp only [step]; omega⟩
    · obtain ⟨p, h1, h2, h3⟩ := a4 w hw; exact ⟨p, h1, h2, by simp only [step]; omega⟩
  | browserCheck => exact cs_updCheck hs
  | probeFirst =>
    have hi : s.installing.isSome = true := by
      simp only [en, oldInst, Bool.and_eq_true] at he
      obtain ⟨h1, _⟩ := he; split at h1 <;> simp_all
    have hp0 : s.probe0 = none := by
      simp only [en, Bool.and_eq_true, Option.isNone_iff_eq_none] at he; exact he.2
    refine ⟨a1, fun p hp => ?_, fun j hj => ?_, fun w hw => ?_, a5, a6⟩
    · simp only [step, Option.some.injEq] at hp; subst hp; exact ⟨hi, Nat.le_refl _⟩
    · obtain ⟨p, h1, _⟩ := a3 j hj; rw [hp0] at h1; cases h1
    · obtain ⟨p, h1, _⟩ := a4 w hw; rw [hp0] at h1; cases h1
  | fetchJs =>
    have hp : s.probe0.isSome = true := by
      simp only [en, Bool.and_eq_true] at he; exact he.1.2
    obtain ⟨p, hp⟩ := Option.isSome_iff_exists.mp hp
    refine ⟨a1, a2, fun j hj => ?_, a4, a5, a6⟩
    simp only [step, Option.some.injEq] at hj; subst hj
    exact ⟨p, hp, (a2 p hp).2, Nat.le_refl _⟩
  | fetchWasm =>
    have hp : s.probe0.isSome = true := by
      simp only [en, Bool.and_eq_true] at he; exact he.1.2
    obtain ⟨p, hp⟩ := Option.isSome_iff_exists.mp hp
    refine ⟨a1, a2, a3, fun w hw => ?_, a5, a6⟩
    simp only [step, Option.some.injEq] at hw; subst hw
    exact ⟨p, hp, (a2 p hp).2, Nat.le_refl _⟩
  | installEnd =>
    simp only [step]
    split
    · rename_i v p j w hv hp hj hw
      split
      · rename_i hok
        simp only [Bool.and_eq_true, beq_iff_eq] at hok
        obtain ⟨⟨hjp, hdp⟩, hpv⟩ := hok
        -- em.wasm's build is between the two probes, which agree
        have ew : w = j := by
          obtain ⟨p', hp', h1, h2⟩ := a4 w hw
          rw [hp] at hp'; cases hp'
          omega
        apply cs_installed
        refine ⟨fun u q _ hq => ?_, a2, a3, a4, a5, a6⟩
        simp only [] at hq
        split at hq
        · rename_i hu; subst hu; cases hq; simp [Env.bytes, ew, hjp, hpv]
        · exact a1 u q (by assumption) hq
      · exact cs_installFailed hs v
    · exact hs
  | installFail =>
    simp only [step]; split
    · exact cs_installFailed hs _
    · exact hs
  | nManifest bb =>
    simp only [step]; split
    · split
      · c_fr hs
      · exact cs_installFailed hs _
    · exact hs
  | nLook a => simp only [step]; (repeat' split) <;> c_fr hs
  | nNet a bb =>
    simp only [step]; split
    · split
      · c_fr hs
      · exact cs_installFailed (s := { s with dl := s.dl + 1 }) ⟨a1, a2, a3, a4, a5, a6⟩ _
    · exact hs
  | nCommit =>
    simp only [step]; split
    · rename_i v xj xw hv hj hw
      refine ⟨fun u q hg hq => ?_, a2, a3, a4, a5, a6⟩
      simp only [] at hq; split at hq
      · rename_i hu; subst hu; cases hq
        obtain ⟨v1, hv1, hj'⟩ := hn.2.2.2.2.1 .js xj hj
        obtain ⟨v2, hv2, hw'⟩ := hn.2.2.2.2.1 .wasm xw hw
        rw [hv] at hv1 hv2; cases hv1; cases hv2
        -- an older design's install keeps only its own build's bytes too
        simp [Env.bytes, hH _ _ hj', hH _ _ hw']
      · exact a1 u q hg hq
    · exact hs
  | nCheck =>
    simp only [step]; split
    · split
      · exact cs_installed hs _
      · exact cs_installFailed hs _
    · exact hs
  | regResolve t =>
    have h1 : CS E (updT t (fun x => { x with regd := true }) s) := by c_fr hs
    simp only [step]; split
    · unfold showBtn; c_fr h1
    · split
      · exact cs_start h1
      · exact h1
  | coreLoaded t => simp only [step]; split <;> c_fr hs
  | instFire t =>
    have h1 : CS E (updT t (fun x => { x with instQ := none }) s) := by c_fr hs
    simp only [step]; split
    · split
      · unfold showBtn; c_fr h1
      · exact h1
    · exact h1
  | skipDeliver =>
    simp only [step]; split
    · split
      · exact cs_activate (s := { s with skipQ := none }) hs _
      · exact hs
    · exact hs
  | ccFire t =>
    let s1 := updT t (fun x => { x with ccQ := false }) s
    have h1 : CS E s1 := by c_fr hs
    have hn1 : NI E s1 := by n_fr hn
    simp only [step]; split
    · split
      · c_fr h1
      · split
        · exact cs_reload hn1 h1 t true
        · split
          · unfold showBtn; c_fr h1
          · c_fr h1
    · c_fr h1
  | userReload t => exact cs_reload hn hs t false
  | updClick t =>
    simp only [step]; split
    · c_fr hs
    · exact cs_applyStart hn hs t
  | confirm t => exact cs_applyStart hn hs t
  | applyResume t => simp only [step]; split <;> c_fr hs
  | resetFire t =>
    simp only [step]
    suffices hw : CS E (wipe s) by c_fr hw
    unfold wipe
    have er : (redund s).rW = s.rW := by unfold redund; split <;> rfl
    refine ⟨fun _ _ _ h => by simp at h, fun _ h => by simp [clearInst] at h,
      fun _ h => by simp [clearInst] at h, fun _ h => by simp [clearInst] at h, ?_, ?_⟩
    · intro w hw; simp only [clearInst, er] at hw; exact a5 w hw
    · show (redund s).mixedBoot = false
      unfold redund; split <;> simpa using a6
  | landReload t =>
    -- the reload the wingbeat waited for boots whatever serves when it lands
    exact cs_reload hn hs t true
  | failClose t => simp only [step]; c_fr hs
  | checkStart t | chkCur t | chkLatest t | chkSw t | gameOn t | gameOff t | notNow t | newerStart t =>
    simp only [step]; c_fr hs
  | chkEval t =>
    simp only [step]; split
    · have h1 : CS E (updT t (fun x => { x with chk := none }) s) := by c_fr hs
      split
      · unfold showBtn; c_fr h1
      · exact h1
    · exact hs
  | forceStart t =>
    -- benign4: the worker running it is of this design (or there is none)
    refine cs_startForce (by c_fr hs) t (fun w hw => ?_)
    have hw' : s.active = some w := hw
    simp only [benign4, hw'] at hb; exact hb
  | forceRetry t =>
    refine cs_startForce hs t (fun w hw => ?_)
    simp only [benign4, hw] at hb; exact hb
  | rStop => exact cs_frame hs rfl rfl rfl rfl rfl rfl rfl rfl
  | rProbe0 | rFetchJs | rFetchWasm | rMan _ | rVerify => simp only [step]; c_fr hs
  | rNet a b =>
    simp only [step]; split
    · split
      · cases a <;> c_fr hs
      · exact cs_frame hs rfl rfl rfl rfl rfl rfl rfl rfl
    · exact hs
  | rFail => exact cs_frame hs rfl rfl rfl rfl rfl rfl rfl rfl
  | rPutJs | rPutWasm =>
    simp only [step]; split
    · rename_i w hw
      have := a5 w hw
      simp only [this, ↓reduceIte]; c_fr hs
    · exact hs
  | forceDone t => simp only [step]; c_fr hs
  | newerApply t =>
    exact cs_applyStart (s := updT t _ s) (by n_fr hn) (by c_fr hs) t
  | navQ t =>
    -- benign4: no worker, or one of this design: "./" (serve) answers it
    have hq : serveQ E s = serve E s := by
      unfold serveQ; simp only [benign4] at hb
      split
      · rename_i v hv; rw [hv] at hb; simp [hb]
      · rfl
    simp only [step, hq]
    generalize hsv : serve E s = sv
    obtain ⟨c, b, p⟩ := sv
    exact cs_boot hs t false (serve_build hn hs hsv)
  | httpFill _ _ | httpEvict _ | lzOld _ _ | lzHit _ | lzStart _ | lzNet _ _ _ | nLookLz _ | rNetLz _ _ =>
    simp only [step]; (repeat' split) <;> c_fr hs
  | rCommit =>
    simp only [step]; split
    · rename_i w hw
      refine ⟨fun u q hg hq => ?_, a2, a3, a4, a5, a6⟩
      simp only [] at hq; split at hq
      · rename_i hu; subst hu; rw [a5 _ hw] at hg; cases hg
      · exact a1 u q hg hq
    · exact hs


theorem cs_reach4 {E : Env} (hH : Injective E.H) {s : State} (h : Reach4 E s) : CS E s := by
  induction h with
  | init => refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> intros <;> simp_all [init]
  | fresh d => refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> intros <;> simp_all [initFresh, init]
  | step e hr he hb ih => exact cs_step hH ih (ni_reachable hH (reach4_reachable hr)) he hb

/-- **No page boots two builds.** With the digest injective, every page boots
    exactly the bytes of the build it boots from (its cache's, or the
    deployed one off the network), with this design's Force update in,
    stopped wherever, and with query navigations: an older design's Force
    update and its answer to a query navigation are the only steps left out. -/
theorem no_mixed_boot {E : Env} (hH : Injective E.H) {s : State} (h : Reach4 E s) :
    s.mixedBoot = false :=
  (cs_reach4 hH h).2.2.2.2.2

/-! ### Without any Force update, each cache is its own worker's build -/

def benignC (E : Env) (s : State) (e : Event) : Bool :=
  (match e with | .forceStart _ | .forceRetry _ => false | _ => true) && benign4 E s e

inductive Reach3 (E : Env) : State → Prop
  | init : Reach3 E (init E)
  | fresh (d : Nat) : Reach3 E (initFresh E d)
  | step {s : State} (e : Event) : Reach3 E s → en E s e = true → benignC E s e = true → Reach3 E (step E s e)

theorem reach3_reach4 {E : Env} {s : State} (h : Reach3 E s) : Reach4 E s := by
  induction h with
  | init => exact .init
  | fresh d => exact .fresh d
  | step e _ he hb ih =>
    refine .step e ih he ?_
    simp only [benignC, Bool.and_eq_true] at hb; exact hb.2

/-- No Force update in flight, and every kept manifest is its cache's own
    worker's build. -/
def K3 (s : State) : Prop := (∀ t, (s.tabs t).force = false) ∧ (∀ v m, s.cman v = some m → m = v)

theorem k3_frame {s s' : State} (h : K3 s) (ec : s'.cman = s.cman)
    (ef : ∀ u, (s'.tabs u).force = (s.tabs u).force) : K3 s' :=
  ⟨fun u => by rw [ef]; exact h.1 u, fun v m hm => h.2 v m (by rw [← ec]; exact hm)⟩

macro "k_fr" h:term : tactic => `(tactic| ((refine k3_frame $h ?_ ?_) <;> (try rfl) <;>
  (intro u; first | (simp [claim]; done) |
    (simp only [updT_tabs, mapTabs_tabs, startInst_tabs, clearInst_tabs, rClear_tabs]; split <;> simp))))

theorem k3_updCheck {s : State} (h : K3 s) : K3 (updCheck s) := by
  unfold updCheck; split
  · exact k3_frame h rfl (fun _ => rfl)
  · exact h

theorem k3_activate {s : State} (h : K3 s) (v : Nat) : K3 (activate v s) := by
  refine ⟨fun u => by simp [claim, h.1 u], fun u m hm => ?_⟩
  simp only [activate, mapTabs_cman] at hm; split at hm
  · exact h.2 u m hm
  · cases hm

theorem k3_installed {s : State} (h : K3 s) (v : Nat) : K3 (installed v s) := by
  have h1 : K3 (mapTabs (onInstalled v) (clearInst s)) := k3_frame h rfl (fun u => by simp)
  unfold installed; simp only []
  split <;> split <;> first
    | exact k3_activate h1 v
    | exact k3_frame h1 rfl (fun _ => rfl)
    | exact k3_frame (k3_activate h1 v) rfl (fun _ => rfl)

theorem k3_installFailed {s : State} (h : K3 s) (v : Nat) : K3 (installFailed v s) :=
  k3_frame h rfl (fun u => by simp [installFailed])

theorem k3_boot {E : Env} {s : State} (h : K3 s) (t : Bool) (auto : Bool) (sv : Option Nat × Nat × (Nat × Nat)) :
    K3 (bootFrom E t auto sv s) := by
  obtain ⟨c, b, p⟩ := sv; unfold bootFrom
  refine k3_frame h rfl (fun u => ?_)
  simp only [updT_tabs]; split
  · cases c <;> exact (h.1 u).symm
  · rfl

theorem k3_applyStart {E : Env} {s : State} (h : K3 s) (t : Bool) : K3 (applyStart E t s) := by
  unfold applyStart
  have h1 : K3 (updT t (fun x => { x with appUpdating := true, modal := false, shield := true, coming := true, failed := false })
      { s with intents := s.intents + 1 }) := by k_fr h
  simp only []
  split
  · k_fr h1
  · split
    · have := k3_updCheck h1; k_fr this
    · k_fr h1

theorem k3_step {E : Env} {s : State} {e : Event} (h : K3 s) (he : en E s e = true)
    (hb : benignC E s e = true) : K3 (step E s e) := by
  have hf := h.1
  cases e with
  | forceStart t | forceRetry t => simp [benignC] at hb
  | rProbe0 | rFetchJs | rFetchWasm | rMan _ | rNet _ _ | rVerify | rPutJs | rPutWasm | rFail | rStop
  | rNetLz _ _ | rCommit =>
    simp [en, anyForce, hf] at he
  | forceDone t => simp [en, hf] at he
  | nCommit =>
    simp only [step]; split
    · rename_i v xj xw hv _ _
      refine ⟨h.1, fun u m hm => ?_⟩
      simp only [] at hm; split at hm
      · rename_i hu; simp only [Bool.and_eq_true, decide_eq_true_eq] at hu
        simp only [Option.some.injEq] at hm; rw [← hm, hu.1]
      · exact h.2 u m hm
    · exact h
  | installEnd =>
    simp only [step]; split
    · split
      · apply k3_installed; exact k3_frame h rfl (fun _ => rfl)
      · exact k3_installFailed h _
    · exact h
  | installFail => simp only [step]; split
                   · exact k3_installFailed h _
                   · exact h
  | nManifest b =>
    simp only [step]; split
    · split
      · exact k3_frame h rfl (fun _ => rfl)
      · exact k3_installFailed h _
    · exact h
  | nNet a b =>
    simp only [step]; split
    · split
      · exact k3_frame h rfl (fun _ => rfl)
      · exact k3_installFailed (s := { s with dl := s.dl + 1 }) h _
    · exact h
  | nCheck =>
    simp only [step]; split
    · split
      · exact k3_installed h _
      · exact k3_installFailed h _
    · exact h
  | browserCheck => exact k3_updCheck h
  | regResolve t =>
    have h1 : K3 (updT t (fun x => { x with regd := true }) s) := by k_fr h
    simp only [step]; split
    · unfold showBtn; k_fr h1
    · split
      · exact k3_frame h1 rfl (fun _ => rfl)
      · exact h1
  | instFire t =>
    have h1 : K3 (updT t (fun x => { x with instQ := none }) s) := by k_fr h
    simp only [step]; split
    · split
      · unfold showBtn; k_fr h1
      · exact h1
    · exact h1
  | skipDeliver =>
    simp only [step]; split
    · split
      · exact k3_activate (s := { s with skipQ := none }) h _
      · exact h
    · exact h
  | ccFire t =>
    have h1 : K3 (updT t (fun x => { x with ccQ := false }) s) := by k_fr h
    simp only [step]; split
    · split
      · k_fr h1
      · split
        · exact k3_boot h1 t true _
        · split
          · unfold showBtn; k_fr h1
          · k_fr h1
    · k_fr h1
  | userReload t => exact k3_boot h t false _
  | landReload t => exact k3_boot h t true _
  | navQ t => exact k3_boot h t false _
  | updClick t =>
    simp only [step]; split
    · k_fr h
    · exact k3_applyStart h t
  | confirm t => exact k3_applyStart (E := E) h t
  | newerApply t =>
    have h1 : K3 (updT t (fun x => { x with newer := false }) s) := by k_fr h
    exact k3_applyStart (E := E) h1 t
  | resetFire t =>
    simp only [step]
    suffices hw : K3 (wipe s) by k_fr hw
    unfold wipe
    refine ⟨fun u => ?_, fun _ _ hm => by simp at hm⟩
    simp only [clearInst_tabs]; unfold redund; split
    · simp [hf u]
    · exact hf u
  | chkEval t =>
    simp only [step]; split
    · have h1 : K3 (updT t (fun x => { x with chk := none }) s) := by k_fr h
      split
      · unfold showBtn; k_fr h1
      · exact h1
    · exact h
  | _ => (try simp only [step]); (repeat' split) <;> k_fr h

theorem k3_reach3 {E : Env} {s : State} (h : Reach3 E s) : K3 s := by
  induction h with
  | init =>
    refine ⟨fun _ => rfl, fun v m hm => ?_⟩
    simp only [init] at hm; split at hm
    · rename_i hv; simp only [Bool.and_eq_true, decide_eq_true_eq] at hv
      simp only [Option.some.injEq] at hm; rw [← hm, hv.1]
    · cases hm
  | fresh d => exact ⟨fun _ => rfl, fun _ _ hm => by simp [initFresh, init] at hm⟩
  | step e _ he hb ih => exact k3_step ih he hb

/-- **Consistency without Force update.** With the digest injective and no
    Force update, every cache holds exactly its own worker's build, in every
    interleaving of deploys with installs of all three designs, stale edges,
    older caches, the HTTP cache and query navigations served by this
    design. In particular so does the active worker's, the only one the fetch
    handler serves. -/
theorem cache_is_its_build {E : Env} (hH : Injective E.H) {s : State} (h : Reach3 E s) {v : Nat}
    {p : Nat × Nat} (hc : s.cache v = some p) : p = E.bytes v := by
  cases hg : E.curGen v
  · exact (cs_reach4 hH (reach3_reach4 h)).1 v p hg hc
  · obtain ⟨m, hm, hp, _⟩ := cache_is_one_build hH (reach4_reachable (reach3_reach4 h)) hg hc
    rw [(k3_reach3 h).2 v m hm] at hp; exact hp

/-- `no_mixed_boot`, without any Force update. -/
theorem no_mixed_boot_without_force {E : Env} (hH : Injective E.H) {s : State} (h : Reach3 E s) :
    s.mixedBoot = false :=
  no_mixed_boot hH (reach3_reach4 h)



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
@[simp] theorem rSilent_slot : (rSilent s).slot = s.slot := rfl
@[simp] theorem startForce_slot : (startForce t s).slot = s.slot := by
  unfold startForce; simp only []; split <;> rfl
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
  | resetFire t => simp [step, wipe] at h
  | regResolve t =>
    simp only [step] at h; split at h
    · exact Or.inl h
    · split at h
      · simp at h
      · exact Or.inl h
  | navQ t =>
    left; simp only [step] at h
    generalize serveQ E s = sv at h; obtain ⟨c, bb, p⟩ := sv
    simpa [bootFrom] using h
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

/-! ### The page side of an update (update-ui)

A Force update's failure leaves everything as it was, however often; a
reload that waits for the wingbeat still boots one build, whatever lands in
the wait; no game starts while an update is under way. -/

theorem rFail_is_rFailed {E : Env} {s : State} {e : Event}
    (he : e = .rFail ∨ ∃ a b m, e = .rNet a b ∧ s.rMan = some m ∧ E.H (E.C a b) ≠ E.H (E.C a m)) :
    step E s e = rFailed s := by
  rcases he with rfl | ⟨a, b, m, rfl, hm, hne⟩
  · rfl
  · simp [step, hm, hne]

/-- **A Force update's failure changes nothing**, however many in a row,
    online or not. The failure reply (ok:false: a download or the check
    failed) moves no cache, kept manifest, DS core file, worker or install,
    reloads nothing, and leaves the tab's page the one it was and its other
    work as it was. With no update's reload coming the tab shows the failed
    card, appUpdating off; with one coming it goes on updating, appUpdating
    on, no failed card. -/
theorem force_failure_changes_nothing {E : Env} {s : State} {t : Bool} {e : Event}
    (he : e = .rFail ∨ ∃ a b m, e = .rNet a b ∧ s.rMan = some m ∧ E.H (E.C a b) ≠ E.H (E.C a m))
    (hf : (s.tabs t).force = true) :
    (step E s e).cache = s.cache ∧ (step E s e).cman = s.cman ∧ (step E s e).lazy = s.lazy ∧
    (step E s e).active = s.active ∧ (step E s e).waiting = s.waiting ∧
    (step E s e).installing = s.installing ∧ (step E s e).autoReloads = s.autoReloads ∧
    ((step E s e).tabs t).running = (s.tabs t).running ∧ ((step E s e).tabs t).force = false ∧
    ((step E s e).tabs t).applyK = (s.tabs t).applyK ∧ ((step E s e).tabs t).pend = (s.tabs t).pend ∧
    ((s.tabs t).coming = false →
      ((step E s e).tabs t).appUpdating = false ∧ ((step E s e).tabs t).failed = true) ∧
    ((s.tabs t).coming = true →
      ((step E s e).tabs t).appUpdating = (s.tabs t).appUpdating ∧ ((step E s e).tabs t).failed = false) := by
  rw [rFail_is_rFailed he]
  cases hc : (s.tabs t).coming <;> simp [rFailed, rClear, mapTabs, failTab, hf, hc]

/-- **...and the failed card is the end of it**: in every reachable state, a
    failure that shows the card (no reload coming) leaves no reload coming in
    that tab: no wingbeat wait, no full reset, no reply to wait for, no
    applyUpdate to resume. -/
theorem force_failure_no_reload {E : Env} {s : State} (h : Reachable E s) {t : Bool} {e : Event}
    (he : e = .rFail ∨ ∃ a b m, e = .rNet a b ∧ s.rMan = some m ∧ E.H (E.C a b) ≠ E.H (E.C a m))
    (hf : (s.tabs t).force = true) (hc : (s.tabs t).coming = false) :
    en E (step E s e) (.landReload t) = false ∧ en E (step E s e) (.resetFire t) = false ∧
    en E (step E s e) (.forceDone t) = false ∧ en E (step E s e) (.applyResume t) = false := by
  obtain ⟨-, -, -, d, e5, -⟩ := (fi_reachable h).2 t
  have hk := e5 hf hc
  have hp : (s.tabs t).pend = false := by
    cases hpp : (s.tabs t).pend
    · rfl
    · have := d hpp; rw [hc] at this; cases this
  obtain ⟨-, -, -, -, -, -, -, -, h1, h2, h3, -⟩ := force_failure_changes_nothing he hf
  simp [en, h1, h2, h3, hk, hp]

/-- **A reload that waits for the wingbeat still lands on one build.** On
    the runs `no_mixed_boot` covers, whatever lands in the wait (a deploy,
    an install, another tab's activation and claim, a full reset, the
    worker stopped), the pending reload boots exactly one build's bytes:
    it reads the cache when it lands, not when it was set
    (`wingbeat_wait_spans_activation`). -/
theorem pending_reload_one_build {E : Env} (hH : Injective E.H) {s : State} (h : Reach4 E s) (t : Bool)
    (he : en E s (.landReload t) = true) :
    (step E s (.landReload t)).mixedBoot = false ∧ ∃ b, ((step E s (.landReload t)).tabs t).running = E.bytes b := by
  have hcs := cs_reach4 hH h
  have hn := ni_reachable hH (reach4_reachable h)
  refine ⟨no_mixed_boot hH (.step _ h he rfl), ?_⟩
  simp only [step, reload]
  generalize hsv : serve E s = sv
  obtain ⟨c, b, p⟩ := sv
  have hp := serve_build hn hcs hsv
  refine ⟨b, ?_⟩
  unfold bootFrom; cases c <;> simp [hp]

section gamelemmas
variable (E : Env) (X : State) (t u : Bool) (v : Nat)
theorem bootFrom_game (auto : Bool) (sv : Option Nat × Nat × (Nat × Nat)) :
    ((bootFrom E u auto sv X).tabs t).game = (if t = u then false else (X.tabs t).game) := by
  obtain ⟨c, b, p⟩ := sv; unfold bootFrom
  by_cases hut : t = u <;> cases c <;> simp [hut]
theorem applyStart_game : ((applyStart E u X).tabs t).game = (X.tabs t).game := by
  unfold applyStart; simp only []
  split <;> (try split) <;> (by_cases hut : t = u <;> simp [hut])
theorem startForce_game : ((startForce u X).tabs t).game = (X.tabs t).game := by
  unfold startForce; simp only []
  split <;> (by_cases hut : t = u <;> simp [hut])
theorem installed_game : ((installed v X).tabs t).game = (X.tabs t).game := by
  unfold installed; simp only []; split <;> split <;> simp [mapTabs, activate, clearInst, claim]
theorem redund_game : ((redund X).tabs t).game = (X.tabs t).game := by
  unfold redund; split <;> simp
theorem installFailed_game : ((installFailed v X).tabs t).game = (X.tabs t).game := by
  simp [installFailed]
theorem showBtn_game : ((showBtn u v X).tabs t).game = (X.tabs t).game := by
  unfold showBtn; by_cases hut : t = u <;> simp [hut]
theorem updT_game_of (f : Tab → Tab) (hf : ∀ x, (f x).game = x.game) :
    ((updT u f X).tabs t).game = (X.tabs t).game := by
  by_cases hut : t = u <;> simp [hut, hf]
end gamelemmas

/-- **No game starts while an update is under way.** From a tab with an
    update in flight (appUpdating) and no game, no step starts one: launchRom,
    handleRomFile and handleDroppedFile refuse, and every reload boots a page
    with none. -/
theorem no_game_start_while_updating {E : Env} {s : State} {e : Event} {t : Bool} (he : en E s e = true)
    (hu : (s.tabs t).appUpdating = true) (hg : (s.tabs t).game = false) :
    ((step E s e).tabs t).game = false := by
  cases e with
  | gameOn u =>
    by_cases hut : u = t
    · subst hut; simp [en, hu] at he
    · simp [step, Ne.symm hut, hg]
  | resetFire u =>
    simp only [step]
    rw [updT_game_of (f := fun x => { x with applyK := .idle, pend := true, coming := true }) (hf := fun _ => rfl)]
    simp [wipe, redund_game, hg]
  | _ =>
    clear he
    simp only [step, reload]
    (repeat' split) <;>
      simp [bootFrom_game, applyStart_game, startForce_game, installed_game,
        installFailed_game, showBtn_game, rSilent_tabs, setStaged_tabs, activate_tabs, claim, hg] <;>
      (try (cases ‹Asset› <;> simp [hg])) <;>
      (try (split <;> simp [hg]))

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
