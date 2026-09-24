-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/index.js: adoptDriveAccount armDriveRenewOnGesture clearDriveToken driveEnrolled driveFetch driveLinked driveListMap driveSessionGuard driveUploadFile ensureDriveSignedIn flushSync flushSyncInner gdriveAcquireToken gdriveConnect gdriveFetchEmail gdriveSignOut hasUserActivation loadGisScript localSyncFiles markDelete markGameUpload markUpload parseDriveFileName pendingCount pullSync pullSyncInner readDriveLibrary readSyncBytes refreshSyncStatus rememberDriveEmail renewDriveToken resumeDriveOnBoot runExclusive runFullSync saveSyncState scheduleFlush setSyncStatus startSyncTriggers syncActive syncPollTick writeDriveLibrary on:online on:offline on:visibilitychange

/-
# Google Drive sync: the upload queue and the session (web/index.js)

Two sub-models of the one machine, each carrying exactly the state its
properties need, as fixed on top of 7ca348ebf (the Drive sync fix series;
line numbers are web/index.js after the whole series). Against dd7ba741f the
same models refuted the properties below with the `bug_*` traces in
formal/FINDINGS.md (#8, #10, #11); each is now a `regress_*` theorem, and the
general property behind it is proved for every reachable state.

## `Queue`: the dirty queue, the flusher, the lamp (one account, linked)

JS: `markUpload` (2783), `scheduleFlush` (2769), `flushSync` (2830),
`runExclusive`/`syncChain` (2820-2826), `flushSyncInner` (2837-3003),
`pullSync`/`pullSyncInner` (3095-3270, opaque), `runFullSync` (3272),
`refreshSyncStatus`/`setSyncStatus` (2732-2764), the triggers
`syncPollTick`/`online`/`offline`/`visibilitychange` (4064-4091), and the
save writers that call `markUpload` after their IndexedDB write commits
(`persistSave` 5522-5545, `saveToSlot` 5842-5865).

`flushSyncInner` is split at every await that can matter to the queue:
the prelude (`driveListMap`, `readDriveLibrary`, renames, deletes: one await),
then per queued name `readSyncBytes` (the IndexedDB read itself is an event
`readSnap`, the continuation `readResume` another), `driveUploadFile` (sent
with whatever token is current at send time), the 401 re-grant inside
`driveFetch` (2129-2142), `writeDriveLibrary`, and the final/`catch`
`saveSyncState`.

## `Session`: tokens, connect/sign-out, renewal, accounts

JS: `gdriveAcquireToken` (2034-2085, `gdriveTokenInFlight`),
`gdriveFetchEmail`/`adoptDriveAccount` (2099-2116, 2430-2453),
`gdriveSignOut` (2257-2276), `gdriveConnect` (3885), `armDriveRenewOnGesture`
(3949), `renewDriveToken` (3970-4019), `syncPollTick` (4064), the in-flight
flush seen coarsely (it captures its library at the start and writes it at
the end, 2858 and 2967) and `driveFetch`'s 401 path. Fixed: a session number
(`driveSession` 2014, `driveSessionGuard` 2023) that Sign out, a sign-in's
grant, a sign-in's end and an account switch each advance; the flush, the
pull, the renewal and driveFetch's replay stop after any await that finds it
moved. `syncActive` (2456) needs a linked tab with no sign-in mid-way; a grant
is kept only for the session that asked for it, or for a sign-in waiting on
it (`gdriveTokenForConnect`); gdriveFetchEmail ignores an answer about a token
the tab no longer holds; a sign-in whose account cannot be confirmed is
refused.

## Abstractions (and why they do not affect the stated properties)

* Queue: only `queueUp` is modelled; `queueDel`/`queueRen` and tombstones/
  renames (another model) are folded into the prelude await and into
  `libPending` (the flush proceeds with an empty `queueUp` when
  `syncState.tomb`/`ren` are non-empty, 2845). `pendingCount()` is
  `queueUp.length`; queued deletes/renames would only make the lamp *more*
  often "syncing".
* Queue: local bytes are a version counter per name (`ver`), Drive's copy is
  the version last uploaded (`drive`); FNV signatures are assumed injective
  and the "already on Drive with this sig" skip (2942) is dropped: skipping
  never re-queues or un-queues anything, it only avoids a request.
  No local deletes (`ver` only grows).
* Queue: pull is opaque: it may run, fail (optionally clearing the token via
  `driveFetch`'s 401 path), and on success may queue a name
  ("reconcile upward", 3214-3223) and flip `libPending`. It does not model
  pull writing local bytes (merge logic, another model).
* Queue: the token is a Bool (live / null). How it comes back is the
  `Session` model's business; here `tokArrive` (a grant from a renewal or
  `ensureDriveSignedIn`, optionally followed by `renewDriveToken`'s
  `pullSync`), `renewFail` (a spent strike, clearing the token at 3) and
  `tokLost` (any other `driveFetch` 401 without activation) are free events.
* Queue: timers are Bools (armed or not) that may fire at any time; the
  3-minute poll interval is always armed (`startSyncTriggers`, never cleared).
* Session: file contents are not modelled; the flush is a count of uploads
  plus the library it captured. The GIS popup is one in-flight request
  (`req`, with the login_hint it was issued with) resolved by `tokGrant a`
  (the account granted; with a hint, only that account) or `tokDeny`.
  `navigator.onLine`, the GIS script load and `hasUserActivation()` are event
  parameters. `appUpdating` is false.
* Session: `ensureDriveSignedIn`'s tokenless path is another joiner of the
  same request as renewal and is not modelled separately.
* Queue: `markUpload`'s `driveEnrolled()`/`parseDriveFileName` guards are
  taken as passing (only syncable keys of an enrolled device are modelled).
  `markDelete`/`markGameUpload` are not modelled (see the report).
  `tap` is not guarded by the home button's `disabled` (the Settings Sync
  button, 2334, never is).
* Session: the 401 re-grant is modelled on uploads only; a 401 in the prelude
  or the library write is folded into `jobFail`. `resumeDriveOnBoot` is the
  initial state (expired persisted token: arm and wait for a gesture).
* Session: the pull is coarse (it sends at its start); its own session checks
  are in the JS but not needed here, since the pull writes no library in this
  model. `ensureDriveSignedIn`'s fall-through to `gdriveConnect` while linked
  is not modelled (`signIn` requires a signed-out tab); its grant is a
  connect's grant and takes a new session all the same.
* Both: every JS continuation is its own event, enabled whenever its await
  could have resolved; microtask ordering is not assumed (over-approximates
  interleavings, which is sound for the invariants; each counterexample was
  re-checked against the JS for being a real order).

## Results

Proved (every reachable state):
* `Queue.mutual_exclusion`: at most one flush/pull body runs (runExclusive).
* `Queue.queue_nodup`: `queueUp` never holds a name twice, so no flush uploads one twice.
* `Queue.busy_iff_running`: `syncBusy` is exactly "a Drive job body is running".
* `Queue.lamp_not_spinning_when_quiet`: nothing queued or running => not "syncing".
* `Queue.in_flight_is_queued`, `failed_upload_stays_queued`,
  `failed_regrant_stays_queued`: nothing leaves the queue before its own
  upload succeeds; a failure leaves the queue untouched.
* `Queue.no_lost_upload` / `quiet_means_synced`: a key whose Drive copy is
  stale is always queued (or its markUpload is pending); drained means synced.
* `Session.send_only_signed_in`: no Drive request leaves with a live token
  while the tab is signed out and no sign-in is running.
* `Session.no_cross_account`: no flush writes the library it captured under
  one account into another account's Drive; `active_is_own_account`: a
  syncing tab holds its own account's token. (Both via `Session.Safe`.)
* `Session.renewals_le_gestures` (+ `only_gesture_renews`,
  `gesture_renews_once`): renewal attempts never outnumber user gestures, so
  token renewal cannot loop by itself.
* `Session.no_orphaned_token_waiter`: one GIS request; every caller awaiting a
  token has it in flight.

The findings' traces, fixed: `Queue.regress_redirty_kept`,
`Session.regress_renewal_after_signout`, `regress_signed_out_quiet`,
`regress_renewal_rollover`, `regress_no_cross_account` (+ `_then_sync`),
`regress_unconfirmed_signin` (found while modelling the fix: a sign-in whose
tokeninfo failed kept the previous account's state loaded under the new
token).

Still refuted (not fixed here):
* `Queue.bug_spinner_without_work`, `bug_spinner_after_renewal`: "Syncing"
  spins, with the home Sync button disabled, while nothing is in flight.
* `Session.bug_one_popup_two_strikes`: two renewals share one popup and one
  refusal costs two of the three strikes.
-/
namespace WebState.DriveSession

/-- A function update, for version maps. -/
def upd (f : Nat → Nat) (i v : Nat) : Nat → Nat := fun j => if j = i then v else f j

namespace Queue

/-- `syncStatus` (2715). -/
inductive Status where
  | idle | syncing | done | offline | paused
  deriving DecidableEq, Repr

/-- `flushSyncInner`'s program counter (2837). -/
inductive FPc where
  /-- queued behind `syncChain`, body not entered -/
  | start
  /-- awaiting `driveListMap` / `readDriveLibrary` / renames / deletes (2855-2928) -/
  | prelude
  /-- awaiting `readSyncBytes(name)` (2935); `snap` = the IndexedDB read has run and saw it -/
  | read (name : Nat) (rest : List Nat) (snap : Option Nat)
  /-- awaiting `driveUploadFile(name, bytes)` (2943); `withTok`: gdriveToken was non-null at send -/
  | upload (name : Nat) (v : Nat) (withTok : Bool) (rest : List Nat)
  /-- `driveFetch` got 401 with activation: awaiting `gdriveAcquireToken("")` (2134) -/
  | reauth (name : Nat) (v : Nat) (rest : List Nat)
  /-- awaiting `writeDriveLibrary(lib, await driveListMap())` (2967) -/
  | libWrite
  /-- awaiting `saveSyncState()` on success (2990) -/
  | okSave
  /-- in `catch`: `syncBusy = false` done, awaiting `saveSyncState()` (2994-2998) -/
  | failSave
  deriving DecidableEq, Repr

/-- A job on `syncChain`. `after`: the caller chained `.then(() => pullSync(...))`
(poll/online/visible: silent; `runFullSync`: not silent). -/
inductive Job where
  | flush (pc : FPc) (after : Option Bool)
  | pull (started : Bool) (silent : Bool)
  deriving DecidableEq, Repr

/-- `runFullSync` (3272) after its `syncActive()` check. -/
inductive Rfs where
  /-- awaiting `localSyncFiles()` -/
  | listing
  /-- awaiting `saveSyncState()` -/
  | saving
  deriving DecidableEq, Repr

structure St where
  tok        : Bool          -- !!gdriveToken (syncActive, 2454)
  fails      : Nat           -- driveRenewFails (3944)
  ver        : Nat → Nat     -- the bytes under each IndexedDB key, as a version
  drive      : Nat → Nat     -- the version Drive holds for that name
  marks      : List Nat      -- committed writes whose markUpload has not run yet
  queueUp    : List Nat      -- syncState.queueUp
  remarked   : List Nat      -- syncRemarked: queued names saved again since their flush item began
  libPending : Bool          -- syncState.tomb.length || syncState.ren.length
  busy       : Bool          -- syncBusy (2369)
  status     : Status        -- syncStatus (2715)
  doneArmed  : Bool          -- syncDoneTimer (2738)
  debounce   : Bool          -- syncTimer (2772)
  cap        : Bool          -- syncCapTimer (2774)
  chain      : List Job      -- syncChain: head runs, the rest wait (runExclusive 2821)
  pullQueued : Bool          -- pullQueued (2827)
  pullCalls  : List Bool     -- pending `.then(() => pullSync(...))` / renewal's pullSync
  rfs        : List Rfs      -- runFullSync calls in flight
  held       : List Nat      -- keys that hold bytes (localSyncFiles)

def init : St :=
  { tok := true, fails := 0, ver := fun _ => 0, drive := fun _ => 0, marks := [],
    queueUp := [], remarked := [], libPending := false, busy := false,
    status := .idle, doneArmed := false, debounce := false, cap := false,
    chain := [], pullQueued := false, pullCalls := [], rfs := [], held := [] }

inductive Ev where
  /-- a save/state/frame write commits (persistSave 5529, saveToSlot 5852) -/
  | write (i : Nat)
  /-- its `markUpload(i)` continuation runs (5540, 5858) -/
  | mark (i : Nat)
  /-- syncTimer / syncCapTimer fire `flushSync` (2772-2774) -/
  | debounce | cap
  /-- syncPollTick (4064) -/
  | poll
  /-- window `online` (4077), `offline` (4082), visibilitychange->visible (4085) -/
  | online | offline | visible
  /-- a Sync button with a live token (4160, 2334): runFullSync -/
  | tap
  /-- runFullSync continuation #k resumes -/
  | rfsStep (k : Nat)
  /-- a token is granted; `pullAfter`: renewDriveToken's wasSignedOut tail (4011-4018) -/
  | tokArrive (pullAfter : Bool)
  /-- some other driveFetch hit 401 with no activation (2131-2137) -/
  | tokLost
  /-- renewDriveToken's catch (3994-4007) -/
  | renewFail
  /-- syncDoneTimer fires (2738) -/
  | doneTimer
  /-- pending pullSync call #k runs -/
  | callPull (k : Nat)
  /-- the chain head's body starts -/
  | jobStart
  | preludeOk
  | preludeFail (clear : Bool)
  | readSnap
  | readResume
  | upOk
  | up401 (activation : Bool)
  | upFail
  | reauthOk
  | reauthFail
  | libOk
  | libFail (clear : Bool)
  | saveDone
  | pullOk (push : Option Nat) (lib : Bool)
  | pullFail (clear : Bool)
  deriving DecidableEq, Repr

def pending (s : St) : Nat := s.queueUp.length

/-- setSyncStatus (2732): also (re)arms the "done" -> idle timer. -/
def setStatus (s : St) (x : Status) : St := { s with status := x, doneArmed := x == .done }

/-- refreshSyncStatus (2755-2764), with driveLinked() true. -/
def refresh (s : St) : St :=
  if !s.tok && decide (s.fails ≥ 3) && decide (pending s > 0) then setStatus s .paused
  else if s.busy || decide (pending s > 0) then setStatus s .syncing
  else if s.status == .syncing then setStatus s .done
  else s

/-- scheduleFlush (2769-2776). -/
def scheduleFlush (s : St) : St := refresh { s with debounce := true, cap := true }

/-- markUpload: a name already queued is remembered as re-dirtied
(`syncRemarked.add(name)`), since the running flush may already have read it. -/
def markUpload (s : St) (i : Nat) : St :=
  let s := if i ∈ s.queueUp then { s with remarked := i :: s.remarked }
           else { s with queueUp := s.queueUp ++ [i] }
  scheduleFlush s

/-- flushSync (2830-2836): disarm both timers, append to the chain. -/
def flushSync (s : St) (after : Option Bool) : St :=
  { s with debounce := false, cap := false, chain := s.chain ++ [.flush .start after] }

/-- pullSync (3095-3102). -/
def pullSync (s : St) (silent : Bool) : St :=
  if s.pullQueued then s else { s with pullQueued := true, chain := s.chain ++ [.pull false silent] }

def setHead (s : St) (j : Job) : St := { s with chain := j :: s.chain.tail }
def popHead (s : St) : St := { s with chain := s.chain.tail }

/-- the flush's run promise settles; a chained `.then(pullSync)` becomes pending -/
def finish (s : St) (after : Option Bool) : St :=
  match after with
  | some sil => { popHead s with pullCalls := s.pullCalls ++ [sil] }
  | none => popHead s

/-- `catch (e) { syncBusy = false; await saveSyncState(); ... }` (2993-2999) -/
def catchFail (s : St) (after : Option Bool) : St := setHead { s with busy := false } (.flush .failSave after)

/-- next iteration of `for (let name of syncState.queueUp.slice())`, or the library write.
Starting an item forgets that it was re-dirtied (`syncRemarked.delete(name)`,
just before `readSyncBytes`). -/
def nextItem (s : St) (rest : List Nat) (after : Option Bool) : St :=
  match rest with
  | [] => setHead s (.flush .libWrite after)
  | n :: r => setHead { s with remarked := s.remarked.filter (· != n) }
                (.flush (.read n r none) after)

/-- `if (!syncRemarked.has(name)) syncState.queueUp = syncState.queueUp.filter(...)`:
not if the name was re-dirtied while it was in flight. -/
def dropItem (s : St) (n : Nat) : St :=
  if n ∈ s.remarked then s else { s with queueUp := s.queueUp.filter (· != n) }

def step (s : St) : Ev → St
  | .write i => { s with ver := upd s.ver i (s.ver i + 1), marks := s.marks ++ [i],
                         held := if i ∈ s.held then s.held else s.held ++ [i] }
  | .mark i => if i ∈ s.marks then markUpload { s with marks := s.marks.erase i } i else s
  | .debounce => if s.debounce then flushSync s none else s
  | .cap => if s.cap then flushSync s none else s
  -- syncPollTick (4069-4071): `if (!syncActive()) return; pending ? flush.then(pull) : pull`
  | .poll => if !s.tok then s else if pending s > 0 then flushSync s (some true) else pullSync s true
  -- online (4077-4081)
  | .online => if !s.tok then s else flushSync (refresh s) (some true)
  -- offline (4082-4084)
  | .offline => if pending s > 0 then setStatus s .offline else s
  -- visibilitychange (4089)
  | .visible => if s.tok then flushSync s (some true) else s
  -- runFullSync (3272-3280): `if (!syncActive()) return; await localSyncFiles()`
  | .tap => if s.tok then { s with rfs := s.rfs ++ [.listing] } else s
  | .rfsStep k =>
      match s.rfs[k]? with
      | some .listing =>
          -- `for (let n of names) if (!queueUp.includes(n)) queueUp.push(n); await saveSyncState()`
          { s with rfs := s.rfs.set k .saving,
                   queueUp := s.queueUp ++ s.held.filter (fun n => !(n ∈ s.queueUp)) }
      | some .saving => flushSync { s with rfs := s.rfs.eraseIdx k } (some false)
      | none => s
  | .tokArrive pa =>
      let s' := { s with tok := true, fails := 0 }
      if pa then { s' with pullCalls := s'.pullCalls ++ [true] } else s'
  | .tokLost => { s with tok := false }
  | .renewFail =>
      if s.fails + 1 ≥ 3 then { s with fails := s.fails + 1, tok := false }
      else { s with fails := s.fails + 1 }
  | .doneTimer =>
      if s.doneArmed then
        (if s.status == .done then { s with status := .idle, doneArmed := false }
         else { s with doneArmed := false })
      else s
  | .callPull k =>
      match s.pullCalls[k]? with
      | some sil => pullSync { s with pullCalls := s.pullCalls.eraseIdx k } sil
      | none => s
  | .jobStart =>
      match s.chain with
      | .flush .start after :: _ =>
          -- flushSyncInner 2838-2854
          if !s.tok then finish s after
          else if pending s = 0 && !s.libPending then finish (refresh s) after
          else setHead (setStatus { s with busy := true } .syncing) (.flush .prelude after)
      | .pull false sil :: _ =>
          -- pullSync's job 3098-3100, pullSyncInner 3103-3109
          let s := { s with pullQueued := false }
          if !s.tok then popHead s
          else setHead (if sil then { s with busy := true } else setStatus { s with busy := true } .syncing)
                 (.pull true sil)
      | _ => s
  | .preludeOk =>
      match s.chain with
      | .flush .prelude after :: _ => nextItem s s.queueUp after
      | _ => s
  | .preludeFail clr =>
      match s.chain with
      | .flush .prelude after :: _ => catchFail (if clr then { s with tok := false } else s) after
      | _ => s
  | .readSnap =>
      match s.chain with
      | .flush (.read n r none) after :: _ => setHead s (.flush (.read n r (some (s.ver n))) after)
      | _ => s
  | .readResume =>
      match s.chain with
      | .flush (.read n r (some v)) after :: _ =>
          -- `if (bytes) { ... driveUploadFile ... }` else straight to the filter
          if v = 0 then nextItem (dropItem s n) r after
          else setHead s (.flush (.upload n v s.tok r) after)
      | _ => s
  | .upOk =>
      match s.chain with
      | .flush (.upload n v true r) after :: _ =>
          -- 2943-2966: Drive has v; sigs[name] = sig; queueUp.filter(name) unless re-dirtied
          nextItem (dropItem { s with drive := upd s.drive n v } n) r after
      | _ => s
  | .up401 act =>
      match s.chain with
      | .flush (.upload n v _ r) after :: _ =>
          if act then setHead s (.flush (.reauth n v r) after)
          else catchFail { s with tok := false } after   -- clearDriveToken(); throw
      | _ => s
  | .upFail =>
      match s.chain with
      | .flush (.upload _ _ _ _) after :: _ => catchFail s after
      | _ => s
  | .reauthOk =>
      match s.chain with
      | .flush (.reauth n v r) after :: _ => setHead { s with tok := true } (.flush (.upload n v true r) after)
      | _ => s
  | .reauthFail =>
      match s.chain with
      | .flush (.reauth _ _ _) after :: _ => catchFail { s with tok := false } after
      | _ => s
  | .libOk =>
      match s.chain with
      | .flush .libWrite after :: _ => setHead s (.flush .okSave after)
      | _ => s
  | .libFail clr =>
      match s.chain with
      | .flush .libWrite after :: _ => catchFail (if clr then { s with tok := false } else s) after
      | _ => s
  | .saveDone =>
      match s.chain with
      | .flush .okSave after :: _ => finish (setStatus { s with busy := false } .done) after
      | .flush .failSave after :: _ => finish (setStatus s .offline) after
      | _ => s
  | .pullOk push lib =>
      match s.chain with
      | .pull true _ :: _ =>
          let s1 := { s with busy := false, libPending := lib }
          match push with
          | some i =>
              if i ∈ s1.queueUp then popHead (refresh s1)
              else popHead (scheduleFlush (refresh { s1 with queueUp := s1.queueUp ++ [i] }))
          | none => popHead (refresh s1)
      | _ => s
  | .pullFail clr =>
      match s.chain with
      | .pull true _ :: _ =>
          popHead (setStatus { s with busy := false, tok := if clr then false else s.tok } .offline)
      | _ => s

inductive Reachable : St → Prop
  | init : Reachable init
  | step {s} (e : Ev) : Reachable s → Reachable (step s e)

def run (s : St) (es : List Ev) : St := es.foldl step s

theorem reachable_run (es : List Ev) : ∀ s, Reachable s → Reachable (run s es) := by
  induction es with
  | nil => intro s h; exact h
  | cons e es ih => intro s h; exact ih _ (Reachable.step e h)

/-! ### Traces -/

/-- A second save of the same key lands while its first upload is in flight
(`write 0; mark 0` between `readResume` and `upOk`). Against dd7ba741f
markUpload saw the name still queued and did nothing, and the upload's
completion filtered it out: Drive kept version 1 with nothing queued and the
lamp idle (`bug_redirty_dropped`). -/
def dropTrace : List Ev :=
  [.write 0, .mark 0, .debounce, .jobStart, .preludeOk, .readSnap, .readResume,
   .write 0, .mark 0,
   .upOk, .libOk, .saveDone, .debounce, .jobStart, .doneTimer]

/-- **Fixed: the re-dirtied key stays queued**, the debounce flush that the
second save scheduled is already under way, and when it finishes Drive holds
version 2 and nothing is left queued. -/
theorem regress_redirty_kept :
    let s := run init dropTrace
    let s' := run s [.preludeOk, .readSnap, .readResume, .upOk, .libOk, .saveDone]
    s.ver 0 = 2 ∧ s.drive 0 = 1 ∧ s.queueUp = [0] ∧
    s'.drive 0 = 2 ∧ s'.queueUp = [] ∧ s'.chain = [] := by
  decide

/-- With the token gone (a 401 on a background flush with no user activation,
2136: e.g. a gamepad player after the hour), a new save makes
refreshSyncStatus say "syncing" (it only says "paused" after 3 renewal
strikes), the debounce flush returns at `if (!syncActive()) return` (2838)
without touching the lamp, and nothing is left to run: the spinner turns
with nothing in flight, nothing scheduled, and the home Sync button disabled
(`homeSyncBtn.disabled = syncStatus === "syncing"`, 4107). The poll does
nothing either (4069). -/
def spinTrace : List Ev :=
  [.write 0, .mark 0, .debounce, .jobStart, .preludeOk, .readSnap, .readResume,
   .up401 false, .saveDone,
   .write 0, .mark 0, .debounce, .jobStart, .poll, .doneTimer]

theorem bug_spinner_without_work :
    let s := run init spinTrace
    s.status = .syncing ∧ s.tok = false ∧ s.chain = [] ∧ s.debounce = false ∧ s.cap = false ∧
    s.pullCalls = [] ∧ s.rfs = [] ∧ s.busy = false ∧ s.queueUp = [0] := by
  decide

/-- And once a gesture renews the token, renewDriveToken's tail only pulls
(4018): the pull's refreshSyncStatus keeps "syncing", nothing flushes, and the
disabled Sync button waits for the next 3-minute poll. -/
theorem bug_spinner_after_renewal :
    let s := run init (spinTrace ++ [.tokArrive true, .callPull 0, .jobStart, .pullOk none false])
    s.status = .syncing ∧ s.tok = true ∧ s.chain = [] ∧ s.debounce = false ∧ s.cap = false ∧
    s.pullCalls = [] ∧ s.rfs = [] ∧ s.queueUp = [0] := by
  decide

end Queue
end WebState.DriveSession

namespace WebState.DriveSession.Queue

/-! ### Invariants -/

/-- a job still waiting its turn on `syncChain` -/
def Job.waiting : Job → Bool
  | .flush .start _ => true
  | .pull false _ => true
  | _ => false

/-- the head's body has started and not yet reached its catch/end -/
def headRunning : List Job → Bool
  | .flush .start _ :: _ => false
  | .flush .failSave _ :: _ => false
  | .flush _ _ :: _ => true
  | .pull b _ :: _ => b
  | [] => false

def headFailSave : List Job → Bool
  | .flush .failSave _ :: _ => true
  | _ => false

/-- the name the running flush is working on, and the names after it in its snapshot -/
def flightName : List Job → Option (Nat × List Nat)
  | .flush (.read n r _) _ :: _ => some (n, r)
  | .flush (.upload n _ _ r) _ :: _ => some (n, r)
  | .flush (.reauth n _ r) _ :: _ => some (n, r)
  | _ => none

/-- the version the running flush read for that name -/
def flightVer : List Job → Option (Nat × Nat)
  | .flush (.read n _ (some v)) _ :: _ => some (n, v)
  | .flush (.upload n v _ _) _ :: _ => some (n, v)
  | .flush (.reauth n v _) _ :: _ => some (n, v)
  | _ => none

structure Inv (s : St) : Prop where
  tailWaiting : ∀ j ∈ s.chain.tail, j.waiting = true
  busyRun : s.busy = headRunning s.chain
  lamp : s.status = .syncing → s.queueUp ≠ [] ∨ s.busy = true ∨ headFailSave s.chain = true
  qNodup : s.queueUp.Nodup
  heldNodup : s.held.Nodup
  flight : ∀ n r, flightName s.chain = some (n, r) →
    n ∈ s.queueUp ∧ n ∉ r ∧ (∀ x ∈ r, x ∈ s.queueUp) ∧ r.Nodup

theorem inv_init : Inv init := by
  constructor <;> simp [init, headRunning, headFailSave, flightName]

theorem head_cons_eq (a : Job) (l l' : List Job) :
    headRunning (a :: l) = headRunning (a :: l') ∧ headFailSave (a :: l) = headFailSave (a :: l') ∧
    flightName (a :: l) = flightName (a :: l') ∧ flightVer (a :: l) = flightVer (a :: l') := by
  rcases a with ⟨pc, a⟩ | ⟨b, c⟩
  · cases pc <;> simp [headRunning, headFailSave, flightName, flightVer]
    all_goals (rename_i snap; cases snap <;> simp)
  · cases b <;> simp [headRunning, headFailSave, flightName, flightVer]

theorem head_append (c : List Job) (j : Job) (hj : j.waiting = true) :
    headRunning (c ++ [j]) = headRunning c ∧ headFailSave (c ++ [j]) = headFailSave c ∧
    flightName (c ++ [j]) = flightName c ∧ flightVer (c ++ [j]) = flightVer c := by
  cases c with
  | nil =>
    rcases j with ⟨pc, a⟩ | ⟨b, c⟩
    · cases pc <;> simp_all [Job.waiting, headRunning, headFailSave, flightName, flightVer]
    · cases b <;> simp_all [Job.waiting, headRunning, headFailSave, flightName, flightVer]
  | cons a l => exact head_cons_eq a (l ++ [j]) l

theorem head_waiting (c : List Job) (hc : ∀ j ∈ c, j.waiting = true) :
    headRunning c = false ∧ headFailSave c = false ∧ flightName c = none ∧ flightVer c = none := by
  cases c with
  | nil => simp [headRunning, headFailSave, flightName, flightVer]
  | cons a l =>
    have ha := hc a (by simp)
    rcases a with ⟨pc, a⟩ | ⟨b, c⟩
    · cases pc <;> simp_all [Job.waiting, headRunning, headFailSave, flightName, flightVer]
    · cases b <;> simp_all [Job.waiting, headRunning, headFailSave, flightName, flightVer]

theorem tail_append (c : List Job) (j : Job) (hj : j.waiting = true)
    (hc : ∀ x ∈ c.tail, x.waiting = true) : ∀ x ∈ (c ++ [j]).tail, x.waiting = true := by
  cases c with
  | nil => simp
  | cons a l =>
    intro x hx
    simp at hx hc
    rcases hx with hx | rfl
    · exact hc x hx
    · exact hj

/-- Inv only looks at chain, busy, queueUp, held and whether status is syncing. -/
theorem inv_congr {s s' : St} (h : Inv s) (hc : s'.chain = s.chain) (hb : s'.busy = s.busy)
    (hq : s'.queueUp = s.queueUp) (hh : s'.held = s.held)
    (hs : s'.status = .syncing → s.status = .syncing) : Inv s' := by
  obtain ⟨h1, h2, h3, h4, h5, h6⟩ := h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · simp_all
  · simp_all
  · simp_all
  · simp_all
  · simp_all
  · intro n r hf; rw [hc] at hf; rw [hq]; exact h6 n r hf

theorem inv_flushSync {s : St} (h : Inv s) (a : Option Bool) : Inv (flushSync s a) := by
  obtain ⟨h1, h2, h3, h4, h5, h6⟩ := h
  have hj : (Job.flush .start a).waiting = true := rfl
  obtain ⟨e1, e2, e3, -⟩ := head_append s.chain _ hj
  refine ⟨tail_append _ _ hj h1, ?_, ?_, ?_, ?_, ?_⟩
  · simp_all [flushSync]
  · simp_all [flushSync]
  · simp_all [flushSync]
  · simp_all [flushSync]
  · intro n r hf; simp only [flushSync] at hf ⊢; rw [e3] at hf; exact h6 n r hf

theorem inv_pullSync {s : St} (h : Inv s) (b : Bool) : Inv (pullSync s b) := by
  unfold pullSync
  split
  · exact h
  obtain ⟨h1, h2, h3, h4, h5, h6⟩ := h
  have hj : (Job.pull false b).waiting = true := rfl
  obtain ⟨e1, e2, e3, -⟩ := head_append s.chain _ hj
  refine ⟨tail_append _ _ hj h1, ?_, ?_, ?_, ?_, ?_⟩
  · simp_all
  · simp_all
  · simp_all
  · simp_all
  · intro n r hf; simp only at hf ⊢; rw [e3] at hf; exact h6 n r hf

theorem refresh_fields (s : St) :
    (refresh s).chain = s.chain ∧ (refresh s).busy = s.busy ∧ (refresh s).queueUp = s.queueUp ∧
    (refresh s).held = s.held ∧ (refresh s).tok = s.tok ∧ (refresh s).ver = s.ver ∧
    (refresh s).drive = s.drive ∧ (refresh s).marks = s.marks ∧ (refresh s).remarked = s.remarked ∧
    (refresh s).debounce = s.debounce ∧ (refresh s).cap = s.cap ∧ (refresh s).pullCalls = s.pullCalls ∧
    (refresh s).rfs = s.rfs ∧ (refresh s).pullQueued = s.pullQueued ∧ (refresh s).fails = s.fails ∧
    (refresh s).libPending = s.libPending := by
  unfold refresh setStatus; split <;> (try split) <;> (try split) <;> simp

theorem refresh_syncing (s : St) : (refresh s).status = .syncing → s.busy = true ∨ s.queueUp ≠ [] := by
  unfold refresh setStatus pending
  split
  · simp
  split
  · rename_i hb; intro _; simp at hb
    rcases hb with hb | hb
    · exact Or.inl hb
    · right; intro hq; simp [hq] at hb
  split
  · simp
  · rename_i hs; intro h; simp_all

theorem inv_refresh {s : St} (h : Inv s) : Inv (refresh s) := by
  obtain ⟨f1, f2, f3, f4, -⟩ := refresh_fields s
  obtain ⟨h1, h2, h3, h4, h5, h6⟩ := h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · simp_all
  · simp_all
  · intro hs
    rw [f3, f2, f1]
    rcases refresh_syncing s hs with hb | hq
    · exact Or.inr (Or.inl hb)
    · exact Or.inl hq
  · simp_all
  · simp_all
  · intro n r hf; rw [f1] at hf; rw [f3]; exact h6 n r hf

theorem inv_scheduleFlush {s : St} (h : Inv s) : Inv (scheduleFlush s) :=
  inv_refresh (inv_congr h rfl rfl rfl rfl id)

theorem flight_add {s : St} (h6 : ∀ n r, flightName s.chain = some (n, r) →
    n ∈ s.queueUp ∧ n ∉ r ∧ (∀ x ∈ r, x ∈ s.queueUp) ∧ r.Nodup) (extra : List Nat) :
    ∀ n r, flightName s.chain = some (n, r) →
    n ∈ s.queueUp ++ extra ∧ n ∉ r ∧ (∀ x ∈ r, x ∈ s.queueUp ++ extra) ∧ r.Nodup := by
  intro n r hf
  obtain ⟨a, b, c, d⟩ := h6 n r hf
  exact ⟨List.mem_append_left _ a, b, fun x hx => List.mem_append_left _ (c x hx), d⟩

theorem inv_push {s : St} (h : Inv s) (i : Nat) (hi : i ∉ s.queueUp) :
    Inv { s with queueUp := s.queueUp ++ [i] } := by
  obtain ⟨h1, h2, h3, h4, h5, h6⟩ := h
  refine ⟨h1, h2, ?_, ?_, h5, flight_add h6 [i]⟩
  · intro hs; rcases h3 hs with h | h | h
    · left; simp
    · exact Or.inr (Or.inl h)
    · exact Or.inr (Or.inr h)
  · simp only [List.nodup_append]; refine ⟨h4, by simp, ?_⟩
    intro a ha b hb; simp at hb; subst hb; intro heq; subst heq; exact hi ha

theorem inv_markUpload {s : St} (h : Inv s) (i : Nat) : Inv (markUpload s i) := by
  unfold markUpload
  apply inv_scheduleFlush
  split
  · exact inv_congr h rfl rfl rfl rfl id
  · rename_i hi; exact inv_push h i hi

theorem inv_pushMany {s : St} (h : Inv s) (extra : List Nat) (hn : extra.Nodup)
    (hd : ∀ x ∈ extra, x ∉ s.queueUp) (r : List Rfs) :
    Inv { s with queueUp := s.queueUp ++ extra, rfs := r } := by
  obtain ⟨h1, h2, h3, h4, h5, h6⟩ := h
  refine ⟨h1, h2, ?_, ?_, h5, flight_add h6 extra⟩
  · intro hs; rcases h3 hs with h | h | h
    · left; simp [h]
    · exact Or.inr (Or.inl h)
    · exact Or.inr (Or.inr h)
  · simp only [List.nodup_append]; refine ⟨h4, hn, ?_⟩
    intro a ha b hb heq; subst heq; exact hd a hb ha

/-- popping the chain head: the next job has not started -/
theorem inv_popHead {s : St} (h1 : ∀ j ∈ s.chain.tail, j.waiting = true) (hb : s.busy = false)
    (hl : s.status = .syncing → s.queueUp ≠ []) (h4 : s.queueUp.Nodup) (h5 : s.held.Nodup) :
    Inv (popHead s) := by
  obtain ⟨w1, w2, w3, -⟩ := head_waiting s.chain.tail h1
  refine ⟨?_, ?_, ?_, h4, h5, ?_⟩
  · intro j hj; exact h1 j (List.mem_of_mem_tail hj)
  · simp [popHead, w1, hb]
  · intro hs; exact Or.inl (hl hs)
  · intro n r hf; simp [popHead, w3] at hf

theorem inv_finish {s : St} (h1 : ∀ j ∈ s.chain.tail, j.waiting = true) (hb : s.busy = false)
    (hl : s.status = .syncing → s.queueUp ≠ []) (h4 : s.queueUp.Nodup) (h5 : s.held.Nodup)
    (a : Option Bool) : Inv (finish s a) := by
  have hp := inv_popHead h1 hb hl h4 h5
  unfold finish; split
  · exact inv_congr hp rfl rfl rfl rfl id
  · exact hp

theorem inv_setHead {s : St} (j : Job) (h1 : ∀ j ∈ s.chain.tail, j.waiting = true)
    (hb : s.busy = headRunning (j :: s.chain.tail))
    (hl : s.status = .syncing → s.queueUp ≠ [] ∨ s.busy = true ∨ headFailSave (j :: s.chain.tail) = true)
    (h4 : s.queueUp.Nodup) (h5 : s.held.Nodup)
    (h6 : ∀ n r, flightName (j :: s.chain.tail) = some (n, r) →
      n ∈ s.queueUp ∧ n ∉ r ∧ (∀ x ∈ r, x ∈ s.queueUp) ∧ r.Nodup) : Inv (setHead s j) :=
  ⟨h1, hb, hl, h4, h5, h6⟩

theorem inv_catchFail {s : St} (h1 : ∀ j ∈ s.chain.tail, j.waiting = true)
    (h4 : s.queueUp.Nodup) (h5 : s.held.Nodup) (a : Option Bool) : Inv (catchFail s a) :=
  inv_setHead (s := { s with busy := false }) _ h1 (by simp [headRunning])
    (by intro _; simp [headFailSave]) h4 h5 (by intro n r hf; simp [flightName] at hf)

theorem inv_nextItem {s : St} (rest : List Nat) (after : Option Bool)
    (h1 : ∀ j ∈ s.chain.tail, j.waiting = true) (hb : s.busy = true)
    (h4 : s.queueUp.Nodup) (h5 : s.held.Nodup)
    (hr : ∀ x ∈ rest, x ∈ s.queueUp) (hrn : rest.Nodup) : Inv (nextItem s rest after) := by
  cases rest with
  | nil =>
    exact inv_setHead _ h1 (by simp [hb, headRunning]) (fun _ => Or.inr (Or.inl hb)) h4 h5
      (by intro n r hf; simp [flightName] at hf)
  | cons n r =>
    simp only [nextItem]
    refine inv_setHead (s := { s with remarked := _ }) _ h1 (by simp [hb, headRunning])
      (fun _ => Or.inr (Or.inl hb)) h4 h5 ?_
    intro n' r' hf
    simp [flightName] at hf
    rcases hf with ⟨rfl, rfl⟩
    simp only [List.nodup_cons] at hrn
    exact ⟨hr _ (by simp), hrn.1, fun x hx => hr x (by simp [hx]), hrn.2⟩

theorem dropItem_fields (s : St) (n : Nat) :
    (dropItem s n).chain = s.chain ∧ (dropItem s n).busy = s.busy ∧
    (dropItem s n).held = s.held ∧ (dropItem s n).status = s.status ∧
    (dropItem s n).drive = s.drive ∧ (dropItem s n).ver = s.ver ∧
    (dropItem s n).marks = s.marks ∧ (dropItem s n).remarked = s.remarked ∧
    ((dropItem s n).queueUp = s.queueUp ∨ (dropItem s n).queueUp = s.queueUp.filter (· != n)) := by
  unfold dropItem; split <;> simp

theorem dropItem_keeps (s : St) (n x : Nat) (hx : x ≠ n) (hq : x ∈ s.queueUp) :
    x ∈ (dropItem s n).queueUp := by
  rcases (dropItem_fields s n).2.2.2.2.2.2.2.2 with h | h <;> rw [h]
  · exact hq
  · simp [hq, hx]

theorem dropItem_nodup (s : St) (n : Nat) (h : s.queueUp.Nodup) :
    (dropItem s n).queueUp.Nodup := by
  rcases (dropItem_fields s n).2.2.2.2.2.2.2.2 with h' | h' <;> rw [h']
  · exact h
  · exact h.filter _

/-- the flush finished an item: drop it and move on -/
theorem inv_done_item {s : St} (hI : Inv s) (n : Nat) (r : List Nat) (after : Option Bool)
    (hf : flightName s.chain = some (n, r)) (s' : St) (hc : s'.chain = s.chain) (hb : s'.busy = s.busy)
    (hq : s'.queueUp = s.queueUp) (hh : s'.held = s.held) :
    Inv (nextItem (dropItem s' n) r after) := by
  obtain ⟨h1, h2, h3, h4, h5, h6⟩ := hI
  obtain ⟨_, hn, hr, hrn⟩ := h6 n r hf
  have hrun : headRunning s.chain = true := by
    cases hc' : s.chain with
    | nil => simp [hc', flightName] at hf
    | cons j t =>
      rw [hc'] at hf
      rcases j with ⟨pc, a⟩ | ⟨b, c⟩
      · cases pc <;> simp_all [flightName, headRunning]
      · simp [flightName] at hf
  obtain ⟨d1, d2, d3, -⟩ := dropItem_fields s' n
  apply inv_nextItem
  · rw [d1, hc]; exact h1
  · rw [d2, hb, h2, hrun]
  · exact dropItem_nodup s' n (hq ▸ h4)
  · rw [d3, hh]; exact h5
  · intro x hx
    exact dropItem_keeps s' n x (fun e => hn (e ▸ hx)) (hq ▸ hr x hx)
  · exact hrn

theorem inv_step (s : St) (e : Ev) (hI : Inv s) : Inv (step s e) := by
  have hI' := hI
  obtain ⟨h1, h2, h3, h4, h5, h6⟩ := hI'
  cases e with
  | write i =>
    refine ⟨h1, h2, h3, h4, ?_, h6⟩
    show (if i ∈ s.held then s.held else s.held ++ [i]).Nodup
    split
    · exact h5
    · rename_i hi; simp only [List.nodup_append]; refine ⟨h5, by simp, ?_⟩
      intro a ha b hb; simp at hb; subst hb; intro heq; subst heq; exact hi ha
  | mark i =>
    simp only [step]; split
    · exact inv_markUpload (inv_congr (s' := { s with marks := s.marks.erase i }) hI rfl rfl rfl rfl id) i
    · exact hI
  | debounce => simp only [step]; split
                · exact inv_flushSync hI _
                · exact hI
  | cap => simp only [step]; split
           · exact inv_flushSync hI _
           · exact hI
  | poll =>
    simp only [step]; split
    · exact hI
    · split
      · exact inv_flushSync hI _
      · exact inv_pullSync hI _
  | online => simp only [step]; split
              · exact hI
              · exact inv_flushSync (inv_refresh hI) _
  | offline => simp only [step]; split
               · exact inv_congr hI rfl rfl rfl rfl (by simp [setStatus])
               · exact hI
  | visible => simp only [step]; split
               · exact inv_flushSync hI _
               · exact hI
  | tap => simp only [step]; split
           · exact inv_congr hI rfl rfl rfl rfl id
           · exact hI
  | rfsStep k =>
    simp only [step]; split
    · apply inv_pushMany hI
      · exact h5.filter _
      · intro x hx; simp at hx; exact hx.2
    · exact inv_flushSync (inv_congr (s' := { s with rfs := s.rfs.eraseIdx k }) hI rfl rfl rfl rfl id) _
    · exact hI
  | tokArrive pa => simp only [step]; split
                    · exact inv_congr hI rfl rfl rfl rfl id
                    · exact inv_congr hI rfl rfl rfl rfl id
  | tokLost => exact inv_congr hI rfl rfl rfl rfl id
  | renewFail => simp only [step]; split
                 · exact inv_congr hI rfl rfl rfl rfl id
                 · exact inv_congr hI rfl rfl rfl rfl id
  | doneTimer =>
    simp only [step]; split
    · split
      · exact inv_congr hI rfl rfl rfl rfl (by simp)
      · exact inv_congr hI rfl rfl rfl rfl id
    · exact hI
  | callPull k => simp only [step]; split
                  · exact inv_pullSync (inv_congr (s' := { s with pullCalls := s.pullCalls.eraseIdx k }) hI rfl rfl rfl rfl id) _
                  · exact hI
  | jobStart =>
    simp only [step]; split
    · rename_i after rest hc
      have hb : s.busy = false := by rw [h2, hc]; rfl
      have hl : s.status = .syncing → s.queueUp ≠ [] := by
        intro hs; rcases h3 hs with h | h | h
        · exact h
        · simp [hb] at h
        · simp [hc, headFailSave] at h
      split
      · exact inv_finish h1 hb hl h4 h5 after
      · split
        · obtain ⟨f1, f2, f3, f4, -⟩ := refresh_fields s
          apply inv_finish (by rw [f1]; exact h1) (by rw [f2, hb]) _ (by rw [f3]; exact h4)
            (by rw [f4]; exact h5)
          intro hs; rw [f3]
          rcases refresh_syncing s hs with h | h
          · simp [hb] at h
          · exact h
        · refine inv_setHead (s := setStatus { s with busy := true } .syncing) _ ?_ ?_ ?_ h4 h5 ?_
          · simp [setStatus, hc] at h1 ⊢; exact h1
          · simp [setStatus, headRunning]
          · intro _; simp [setStatus]
          · intro n r hf; simp [flightName] at hf
    · rename_i sil rest hc
      have hb : s.busy = false := by rw [h2, hc]; rfl
      have hl : s.status = .syncing → s.queueUp ≠ [] := by
        intro hs; rcases h3 hs with h | h | h
        · exact h
        · simp [hb] at h
        · simp [hc, headFailSave] at h
      split
      · exact inv_popHead h1 hb hl h4 h5
      · split
        · refine inv_setHead (s := { s with pullQueued := false, busy := true }) _ h1
            (by simp [headRunning]) (fun _ => Or.inr (Or.inl rfl)) h4 h5
            (by intro n r hf; simp [flightName] at hf)
        · refine inv_setHead (s := setStatus { s with pullQueued := false, busy := true } .syncing) _ h1
            (by simp [setStatus, headRunning]) (fun _ => Or.inr (Or.inl rfl)) h4 h5
            (by intro n r hf; simp [flightName] at hf)
    · exact hI
  | preludeOk =>
    simp only [step]; split
    · rename_i after rest hc
      have hb : s.busy = true := by rw [h2, hc]; rfl
      exact inv_nextItem _ _ h1 hb h4 h5 (fun _ hx => hx) h4
    · exact hI
  | preludeFail clr =>
    simp only [step]; split
    · split
      · exact inv_catchFail (s := { s with tok := false }) h1 h4 h5 _
      · exact inv_catchFail h1 h4 h5 _
    · exact hI
  | readSnap =>
    simp only [step]; split
    · rename_i n r after rest hc
      refine inv_setHead _ h1 ?_ ?_ h4 h5 ?_
      · rw [h2, hc]; rfl
      · intro hs; rcases h3 hs with h | h | h
        · exact Or.inl h
        · exact Or.inr (Or.inl h)
        · simp [hc, headFailSave] at h
      · intro n' r' hf; apply h6; rw [hc]; simpa [flightName] using hf
    · exact hI
  | readResume =>
    simp only [step]; split
    · rename_i n r v after rest hc
      split
      · exact inv_done_item hI n r after (by rw [hc]; rfl) s rfl rfl rfl rfl
      · refine inv_setHead _ h1 ?_ ?_ h4 h5 ?_
        · rw [h2, hc]; rfl
        · intro hs; rcases h3 hs with h | h | h
          · exact Or.inl h
          · exact Or.inr (Or.inl h)
          · simp [hc, headFailSave] at h
        · intro n' r' hf; apply h6; rw [hc]; simpa [flightName] using hf
    · exact hI
  | upOk =>
    simp only [step]; split
    · rename_i n v r after rest hc
      exact inv_done_item hI n r after (by rw [hc]; rfl) _ rfl rfl rfl rfl
    · exact hI
  | up401 act =>
    simp only [step]; split
    · rename_i n v w r after rest hc
      split
      · refine inv_setHead _ h1 ?_ ?_ h4 h5 ?_
        · rw [h2, hc]; rfl
        · intro hs; rcases h3 hs with h | h | h
          · exact Or.inl h
          · exact Or.inr (Or.inl h)
          · simp [hc, headFailSave] at h
        · intro n' r' hf; apply h6; rw [hc]; simpa [flightName] using hf
      · exact inv_catchFail (s := { s with tok := false }) h1 h4 h5 _
    · exact hI
  | upFail =>
    simp only [step]; split
    · exact inv_catchFail h1 h4 h5 _
    · exact hI
  | reauthOk =>
    simp only [step]; split
    · rename_i n v r after rest hc
      refine inv_setHead (s := { s with tok := true }) _ h1 ?_ ?_ h4 h5 ?_
      · show s.busy = _; rw [h2, hc]; rfl
      · intro hs; rcases h3 hs with h | h | h
        · exact Or.inl h
        · exact Or.inr (Or.inl h)
        · simp [hc, headFailSave] at h
      · intro n' r' hf; apply h6; rw [hc]; simpa [flightName] using hf
    · exact hI
  | reauthFail =>
    simp only [step]; split
    · exact inv_catchFail (s := { s with tok := false }) h1 h4 h5 _
    · exact hI
  | libOk =>
    simp only [step]; split
    · rename_i after rest hc
      refine inv_setHead _ h1 ?_ ?_ h4 h5 ?_
      · rw [h2, hc]; rfl
      · intro hs; rcases h3 hs with h | h | h
        · exact Or.inl h
        · exact Or.inr (Or.inl h)
        · simp [hc, headFailSave] at h
      · intro n r hf; simp [flightName] at hf
    · exact hI
  | libFail clr =>
    simp only [step]; split
    · split
      · exact inv_catchFail (s := { s with tok := false }) h1 h4 h5 _
      · exact inv_catchFail h1 h4 h5 _
    · exact hI
  | saveDone =>
    simp only [step]; split
    · exact inv_finish (s := setStatus { s with busy := false } .done) h1 rfl (by simp [setStatus]) h4 h5 _
    · rename_i after rest hc
      have hb : s.busy = false := by rw [h2, hc]; rfl
      exact inv_finish (s := setStatus s .offline) h1 hb (by simp [setStatus]) h4 h5 _
    · exact hI
  | pullOk push lib =>
    simp only [step]; split
    · rename_i b rest hc
      split
      · rename_i i
        split
        · obtain ⟨f1, f2, f3, f4, -⟩ := refresh_fields { s with busy := false, libPending := lib }
          apply inv_popHead (by rw [f1]; exact h1) (by rw [f2]) _ (by rw [f3]; exact h4) (by rw [f4]; exact h5)
          intro hs; rw [f3]
          rcases refresh_syncing _ hs with h | h
          · simp at h
          · exact h
        · rename_i hi
          let s2 := refresh { s with busy := false, libPending := lib, queueUp := s.queueUp ++ [i] }
          obtain ⟨f1, f2, f3, f4, -⟩ := refresh_fields
            { s with busy := false, libPending := lib, queueUp := s.queueUp ++ [i] }
          obtain ⟨g1, g2, g3, g4, -⟩ := refresh_fields { s2 with debounce := true, cap := true }
          have hnd : (s.queueUp ++ [i]).Nodup := by
            simp only [List.nodup_append]; refine ⟨h4, by simp, ?_⟩
            intro a ha b hb heq; simp at hb; subst hb; subst heq; exact hi ha
          apply inv_popHead
          · simp only [scheduleFlush]; rw [g1]; simp only [s2]; rw [f1]; exact h1
          · simp only [scheduleFlush]; rw [g2]; simp only [s2]; rw [f2]
          · intro _; simp only [scheduleFlush]; rw [g3]; simp only [s2]; rw [f3]; simp
          · simp only [scheduleFlush]; rw [g3]; simp only [s2]; rw [f3]; exact hnd
          · simp only [scheduleFlush]; rw [g4]; simp only [s2]; rw [f4]; exact h5
      · obtain ⟨f1, f2, f3, f4, -⟩ := refresh_fields { s with busy := false, libPending := lib }
        apply inv_popHead (by rw [f1]; exact h1) (by rw [f2]) _ (by rw [f3]; exact h4) (by rw [f4]; exact h5)
        intro hs; rw [f3]
        rcases refresh_syncing _ hs with h | h
        · simp at h
        · exact h
    · exact hI
  | pullFail clr =>
    simp only [step]; split
    · exact inv_popHead (s := setStatus { s with busy := false, tok := _ } .offline) h1 rfl
        (by simp [setStatus]) h4 h5
    · exact hI

theorem reachable_inv {s : St} (h : Reachable s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step e _ ih => exact inv_step _ e ih

/-! ### Proved properties -/

/-- **No two Drive jobs run at once.** Every job behind the chain head is
still waiting to start: `runExclusive` (2821) is the only way into
`flushSyncInner`/`pullSyncInner`, so no flush overlaps another flush or a
pull, and no name is being uploaded by two flushes. -/
theorem mutual_exclusion {s : St} (h : Reachable s) :
    ∀ j ∈ s.chain.tail, j.waiting = true :=
  (reachable_inv h).tailWaiting

/-- `queueUp` never holds a name twice (markUpload 2786, markGameUpload 2806,
runFullSync 3275 and the pull's reconcile 3220 all check `includes` first), so a flush's snapshot
uploads each name at most once. -/
theorem queue_nodup {s : St} (h : Reachable s) : s.queueUp.Nodup :=
  (reachable_inv h).qNodup

/-- `syncBusy` is exactly "a flush or pull body is between its start and its
end" (2852, 2991, 2994, 3108, 3260, 3266). -/
theorem busy_iff_running {s : St} (h : Reachable s) :
    s.busy = headRunning s.chain :=
  (reachable_inv h).busyRun

/-- **The lamp does not spin over nothing.** With no Drive job queued or
running and an empty upload queue, the status is not "syncing". -/
theorem lamp_not_spinning_when_quiet {s : St} (h : Reachable s)
    (hc : s.chain = []) (hq : s.queueUp = []) : s.status ≠ .syncing := by
  intro hs
  have hI := reachable_inv h
  rcases hI.lamp hs with h' | h' | h'
  · exact h' hq
  · rw [hI.busyRun, hc] at h'; simp [headRunning] at h'
  · rw [hc] at h'; simp [headFailSave] at h'

/-- **The name being uploaded is still queued**, and so is the rest of the
flush's snapshot: nothing leaves `queueUp` before its own upload completes. -/
theorem in_flight_is_queued {s : St} (h : Reachable s) {n : Nat} {r : List Nat}
    (hf : flightName s.chain = some (n, r)) : n ∈ s.queueUp ∧ ∀ x ∈ r, x ∈ s.queueUp := by
  obtain ⟨a, -, c, -⟩ := (reachable_inv h).flight n r hf
  exact ⟨a, c⟩

/-- **A failed upload stays queued**: a network failure, a 401 without
activation, or a failed re-grant ends the flush in `catch` with `queueUp`
untouched, so the name being uploaded and every name after it remain queued
(they flush on the next trigger). -/
theorem failed_upload_stays_queued {s : St} (h : Reachable s)
    {n v w r a rest} (hc : s.chain = .flush (.upload n v w r) a :: rest)
    (e : Ev) (he : e = .upFail ∨ e = .up401 false) :
    (step s e).queueUp = s.queueUp ∧ n ∈ (step s e).queueUp ∧
    ∀ x ∈ r, x ∈ (step s e).queueUp := by
  have hq : (step s e).queueUp = s.queueUp := by
    rcases he with rfl | rfl <;> simp [step, hc, catchFail, setHead]
  rw [hq]
  exact ⟨rfl, in_flight_is_queued h (by rw [hc]; rfl)⟩

theorem failed_regrant_stays_queued {s : St} (h : Reachable s)
    {n v r a rest} (hc : s.chain = .flush (.reauth n v r) a :: rest) :
    (step s .reauthFail).queueUp = s.queueUp ∧ n ∈ s.queueUp := by
  refine ⟨by simp [step, hc, catchFail, setHead], (in_flight_is_queued h (by rw [hc]; rfl)).1⟩

/-! ### `markUpload` remembers a re-dirtied in-flight name

```js
const syncRemarked = new Set();                                  // 2782
// markUpload (2783):
if (!syncState.queueUp.includes(name)) syncState.queueUp.push(name);
else syncRemarked.add(name);
// flushSyncInner, top of the queueUp loop body, before readSyncBytes (2934):
syncRemarked.delete(name);
// ...and the filter after the upload (2963):
if (!syncRemarked.has(name))
  syncState.queueUp = syncState.queueUp.filter((n) => n !== name);
```
With it, every key whose Drive copy differs from its local bytes is queued
or has its markUpload still to run, in every reachable state. -/

structure FixInv (s : St) : Prop where
  le : ∀ i, s.drive i ≤ s.ver i
  good : ∀ i, s.drive i ≠ s.ver i → i ∈ s.queueUp ∨ i ∈ s.marks
  fv : ∀ n v, flightVer s.chain = some (n, v) →
    v ≤ s.ver n ∧ (v = s.ver n ∨ n ∈ s.marks ∨ n ∈ s.remarked)

theorem fixInv_init : FixInv init := by
  constructor <;> simp [init, flightVer]

theorem flightVer_name {c : List Job} {n v : Nat} (h : flightVer c = some (n, v)) :
    ∃ r, flightName c = some (n, r) := by
  cases c with
  | nil => simp [flightVer] at h
  | cons j t =>
    rcases j with ⟨pc, a⟩ | ⟨b, c⟩
    · cases pc with
      | read n' r snap =>
        cases snap <;> simp [flightVer] at h
        obtain ⟨rfl, -⟩ := h; exact ⟨r, by simp [flightName]⟩
      | upload n' v' w r => simp [flightVer] at h; obtain ⟨rfl, -⟩ := h; exact ⟨r, by simp [flightName]⟩
      | reauth n' v' r => simp [flightVer] at h; obtain ⟨rfl, -⟩ := h; exact ⟨r, by simp [flightName]⟩
      | _ => simp [flightVer] at h
    · simp [flightVer] at h

theorem fix_congr {s s' : St} (h : FixInv s) (hd : s'.drive = s.drive) (hv : s'.ver = s.ver)
    (hm : s'.marks = s.marks) (hq : ∀ x ∈ s.queueUp, x ∈ s'.queueUp)
    (hf : ∀ n v, flightVer s'.chain = some (n, v) →
      flightVer s.chain = some (n, v) ∧ (n ∈ s.remarked → n ∈ s'.remarked)) : FixInv s' := by
  obtain ⟨f1, f2, f3⟩ := h
  refine ⟨?_, ?_, ?_⟩
  · intro i; rw [hd, hv]; exact f1 i
  · intro i hi; rw [hd, hv] at hi; rw [hm]
    rcases f2 i hi with h | h
    · exact Or.inl (hq i h)
    · exact Or.inr h
  · intro n v hfv
    obtain ⟨e1, e2⟩ := hf n v hfv
    obtain ⟨a, b⟩ := f3 n v e1
    rw [hv, hm]
    refine ⟨a, ?_⟩
    rcases b with b | b | b
    · exact Or.inl b
    · exact Or.inr (Or.inl b)
    · exact Or.inr (Or.inr (e2 b))

theorem nextItem_fields (s : St) (r : List Nat) (a : Option Bool) :
    (nextItem s r a).drive = s.drive ∧ (nextItem s r a).ver = s.ver ∧
    (nextItem s r a).marks = s.marks ∧ (nextItem s r a).queueUp = s.queueUp ∧
    flightVer (nextItem s r a).chain = none := by
  cases r <;> simp [nextItem, setHead, flightVer]

/-- a congruence for the steps that leave every tracked field alone and do not
start a new in-flight version (they may append to the chain or pop it). -/
theorem fix_frame {s s' : St} (h : FixInv s) (hd : s'.drive = s.drive) (hv : s'.ver = s.ver)
    (hm : s'.marks = s.marks) (hq : ∀ x ∈ s.queueUp, x ∈ s'.queueUp)
    (hf : flightVer s'.chain = flightVer s.chain ∨ flightVer s'.chain = none)
    (hr : s'.remarked = s.remarked) : FixInv s' := by
  apply fix_congr h hd hv hm hq
  intro n v hfv
  rcases hf with hf | hf
  · rw [hf] at hfv; exact ⟨hfv, fun x => hr ▸ x⟩
  · rw [hf] at hfv; cases hfv

theorem fix_same {s s' : St} (h : FixInv s) (hd : s'.drive = s.drive) (hv : s'.ver = s.ver)
    (hm : s'.marks = s.marks) (hq : s'.queueUp = s.queueUp) (hc : s'.chain = s.chain)
    (hr : s'.remarked = s.remarked) : FixInv s' :=
  fix_frame h hd hv hm (by rw [hq]; exact fun _ hx => hx) (Or.inl (by rw [hc])) hr

theorem fix_refresh {s : St} (h : FixInv s) : FixInv (refresh s) := by
  obtain ⟨f1, -, f3, -, -, f6, f7, f8, f9, -⟩ := refresh_fields s
  exact fix_frame h f7 f6 f8 (by rw [f3]; exact fun _ hx => hx) (Or.inl (by rw [f1])) f9

theorem fix_flushSync {s : St} (h : FixInv s) (a : Option Bool) : FixInv (flushSync s a) :=
  fix_frame h rfl rfl rfl (fun _ hx => hx)
    (Or.inl (head_append s.chain (.flush .start a) rfl).2.2.2) rfl

theorem fix_pullSync {s : St} (h : FixInv s) (b : Bool) : FixInv (pullSync s b) := by
  unfold pullSync; split
  · exact h
  · exact fix_frame h rfl rfl rfl (fun _ hx => hx)
      (Or.inl (head_append s.chain (.pull false b) rfl).2.2.2) rfl

theorem fix_popHead {s : St} (ht : ∀ j ∈ s.chain.tail, j.waiting = true) (h : FixInv s) :
    FixInv (popHead s) :=
  fix_frame h rfl rfl rfl (fun _ hx => hx) (Or.inr (head_waiting s.chain.tail ht).2.2.2) rfl

theorem fix_finish {s : St} (ht : ∀ j ∈ s.chain.tail, j.waiting = true) (h : FixInv s)
    (a : Option Bool) : FixInv (finish s a) := by
  unfold finish; split
  · exact fix_frame h rfl rfl rfl (fun _ hx => hx) (Or.inr (head_waiting s.chain.tail ht).2.2.2) rfl
  · exact fix_popHead ht h

theorem fix_catchFail {s : St} (h : FixInv s) (a : Option Bool) : FixInv (catchFail s a) :=
  fix_frame h rfl rfl rfl (fun _ hx => hx) (Or.inr (by simp [catchFail, setHead, flightVer])) rfl

/-- the flush finished name `n` (read as `v`): Drive may now hold `v`. -/
theorem fix_done_item {s : St} (hI : Inv s) (h : FixInv s) (n v : Nat) (r : List Nat)
    (a : Option Bool) (hfv : flightVer s.chain = some (n, v)) (d : Nat → Nat)
    (hd : (d = s.drive ∧ v = 0) ∨ d = upd s.drive n v) :
    FixInv (nextItem (dropItem { s with drive := d } n) r a) := by
  obtain ⟨f1, f2, f3⟩ := h
  obtain ⟨hvle, hvcase⟩ := f3 n v hfv
  obtain ⟨r', hfn⟩ := flightVer_name hfv
  have hnq : n ∈ s.queueUp := (hI.flight n r' hfn).1
  -- with v = 0 the drive is untouched and v = ver n forces drive n = 0 = ver n
  obtain ⟨g1, g2, g3, g4, g5⟩ := nextItem_fields (dropItem { s with drive := d } n) r a
  obtain ⟨-, -, -, -, d5, d6, d7, d8, d9⟩ := dropItem_fields { s with drive := d } n
  refine ⟨?_, ?_, ?_⟩
  · intro i; rw [g1, g2, d5, d6]
    rcases hd with ⟨rfl, -⟩ | rfl
    · exact f1 i
    · simp only [upd]; split
      · subst_vars; exact hvle
      · exact f1 i
  · intro i hi; rw [g1, g2, d5, d6] at hi; rw [g3, g4, d7]
    dsimp only at hi
    by_cases hin : i = n
    · subst hin
      -- is it still queued?
      by_cases hrm : i ∈ s.remarked
      · left; simp [dropItem, hrm, hnq]
      · rcases hvcase with hv | hv | hv
        · -- Drive (or nothing) holds exactly the current bytes... unless it was not uploaded
          rcases hd with ⟨rfl, hv0⟩ | rfl
          · -- untouched drive: the v = 0 read (no bytes); ver i = 0 ≥ drive i
            exfalso; apply hi; have := f1 i; omega
          · simp [upd, hv] at hi
        · exact Or.inr hv
        · exact absurd hv hrm
    · have hi' : s.drive i ≠ s.ver i := by
        rcases hd with ⟨rfl, -⟩ | rfl
        · exact hi
        · simpa [upd, hin] using hi
      rcases f2 i hi' with h' | h'
      · left; exact dropItem_keeps _ n i hin h'
      · exact Or.inr h'
  · intro n' v' hf; rw [g5] at hf; cases hf

theorem fix_step (s : St) (e : Ev) (hI : Inv s) (hF : FixInv s) : FixInv (step s e) := by
  have hF' := hF
  obtain ⟨f1, f2, f3⟩ := hF'
  cases e with
  | write i =>
    simp only [step]
    refine ⟨?_, ?_, ?_⟩
    · intro j; simp only [upd]; split
      · subst_vars; have := f1 j; omega
      · exact f1 j
    · intro j hj
      by_cases hji : j = i
      · subst hji; right; simp
      · simp only [upd, hji, ite_false] at hj
        rcases f2 j hj with h | h
        · exact Or.inl h
        · right; simp [h]
    · intro n v hfv
      obtain ⟨a, b⟩ := f3 n v hfv
      simp only [upd]
      split
      · subst_vars; refine ⟨by omega, Or.inr (Or.inl (by simp))⟩
      · refine ⟨a, ?_⟩
        rcases b with b | b | b
        · exact Or.inl b
        · exact Or.inr (Or.inl (by simp [b]))
        · exact Or.inr (Or.inr b)
  | mark i =>
    simp only [step]; split
    · rename_i him
      -- markUpload true {s with marks := s.marks.erase i} i, then scheduleFlush
      unfold markUpload scheduleFlush
      apply fix_refresh
      split
      · rename_i hiq
        refine ⟨f1, ?_, ?_⟩
        · intro j hj
          rcases f2 j hj with h | h
          · exact Or.inl h
          · by_cases hji : j = i
            · subst hji; exact Or.inl hiq
            · right; exact (List.mem_erase_of_ne hji).2 h
        · intro n v hfv
          obtain ⟨a, b⟩ := f3 n v hfv
          refine ⟨a, ?_⟩
          by_cases hni : n = i
          · subst hni; exact Or.inr (Or.inr (by simp))
          · rcases b with b | b | b
            · exact Or.inl b
            · exact Or.inr (Or.inl ((List.mem_erase_of_ne hni).2 b))
            · exact Or.inr (Or.inr (by simp [b]))
      · rename_i hiq
        refine ⟨f1, ?_, ?_⟩
        · intro j hj
          rcases f2 j hj with h | h
          · exact Or.inl (by simp [h])
          · by_cases hji : j = i
            · subst hji; left; simp
            · right; exact (List.mem_erase_of_ne hji).2 h
        · intro n v hfv
          obtain ⟨a, b⟩ := f3 n v hfv
          refine ⟨a, ?_⟩
          by_cases hni : n = i
          · subst hni
            obtain ⟨r', hfn⟩ := flightVer_name hfv
            exact absurd (hI.flight n r' hfn).1 hiq
          · rcases b with b | b | b
            · exact Or.inl b
            · exact Or.inr (Or.inl ((List.mem_erase_of_ne hni).2 b))
            · exact Or.inr (Or.inr b)
    · exact hF
  | debounce => simp only [step]; split
                · exact fix_flushSync hF _
                · exact hF
  | cap => simp only [step]; split
           · exact fix_flushSync hF _
           · exact hF
  | poll =>
    simp only [step]; split
    · exact hF
    · split
      · exact fix_flushSync hF _
      · exact fix_pullSync hF _
  | online => simp only [step]; split
              · exact hF
              · exact fix_flushSync (fix_refresh hF) _
  | offline => simp only [step]; split
               · exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inl rfl) rfl
               · exact hF
  | visible => simp only [step]; split
               · exact fix_flushSync hF _
               · exact hF
  | tap => simp only [step]; split
           · exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inl rfl) rfl
           · exact hF
  | rfsStep k =>
    simp only [step]; split
    · exact fix_frame hF rfl rfl rfl (fun x hx => by simp [hx]) (Or.inl rfl) rfl
    · exact fix_flushSync (fix_frame (s' := { s with rfs := s.rfs.eraseIdx k }) hF rfl rfl rfl
        (fun _ hx => hx) (Or.inl rfl) rfl) _
    · exact hF
  | tokArrive pa => simp only [step]; split
                    · exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inl rfl) rfl
                    · exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inl rfl) rfl
  | tokLost => exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inl rfl) rfl
  | renewFail => simp only [step]; split
                 · exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inl rfl) rfl
                 · exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inl rfl) rfl
  | doneTimer =>
    simp only [step]; split
    · split
      · exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inl rfl) rfl
      · exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inl rfl) rfl
    · exact hF
  | callPull k =>
    simp only [step]; split
    · exact fix_pullSync (fix_frame (s' := { s with pullCalls := s.pullCalls.eraseIdx k }) hF rfl rfl rfl
        (fun _ hx => hx) (Or.inl rfl) rfl) _
    · exact hF
  | jobStart =>
    simp only [step]; split
    · rename_i after rest hc
      split
      · exact fix_finish hI.tailWaiting hF after
      · split
        · have hI' := inv_refresh hI
          exact fix_finish hI'.tailWaiting (fix_refresh hF) after
        · exact fix_frame hF rfl rfl rfl (fun _ hx => hx)
            (Or.inr (by simp [setHead, flightVer])) rfl
    · rename_i sil rest hc
      split
      · exact fix_popHead (s := { s with pullQueued := false })
          hI.tailWaiting
          (fix_same (s' := { s with pullQueued := false }) hF rfl rfl rfl rfl rfl rfl)
      · split
        · exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inr (by simp [setHead, flightVer])) rfl
        · exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inr (by simp [setHead, flightVer])) rfl
    · exact hF
  | preludeOk =>
    simp only [step]; split
    · rename_i after rest hc
      obtain ⟨g1, g2, g3, g4, g5⟩ := nextItem_fields s s.queueUp after
      exact fix_congr hF g1 g2 g3 (by rw [g4]; exact fun _ hx => hx)
        (by intro n v hfv; rw [g5] at hfv; cases hfv)
    · exact hF
  | preludeFail clr =>
    simp only [step]; split
    · split
      · exact fix_catchFail (fix_same (s' := { s with tok := false }) hF rfl rfl rfl rfl rfl rfl) _
      · exact fix_catchFail hF _
    · exact hF
  | readSnap =>
    simp only [step]; split
    · rename_i n r after rest hc
      refine ⟨f1, f2, ?_⟩
      intro n' v' hfv
      simp [setHead, flightVer] at hfv
      obtain ⟨rfl, rfl⟩ := hfv
      exact ⟨Nat.le_refl _, Or.inl rfl⟩
    · exact hF
  | readResume =>
    simp only [step]; split
    · rename_i n r v after rest hc
      have hfv : flightVer s.chain = some (n, v) := by rw [hc]; rfl
      split
      · rename_i hv0
        exact fix_done_item hI hF n v r after hfv s.drive (Or.inl ⟨rfl, hv0⟩)
      · exact fix_frame hF rfl rfl rfl (fun _ hx => hx)
          (Or.inl (by simp [setHead, flightVer, hc])) rfl
    · exact hF
  | upOk =>
    simp only [step]; split
    · rename_i n v r after rest hc
      have hfv : flightVer s.chain = some (n, v) := by rw [hc]; rfl
      exact fix_done_item hI hF n v r after hfv _ (Or.inr rfl)
    · exact hF
  | up401 act =>
    simp only [step]; split
    · rename_i n v w r after rest hc
      split
      · exact fix_frame hF rfl rfl rfl (fun _ hx => hx)
          (Or.inl (by simp [setHead, flightVer, hc])) rfl
      · exact fix_catchFail (fix_same (s' := { s with tok := false }) hF rfl rfl rfl rfl rfl rfl) _
    · exact hF
  | upFail =>
    simp only [step]; split
    · exact fix_catchFail hF _
    · exact hF
  | reauthOk =>
    simp only [step]; split
    · rename_i n v r after rest hc
      exact fix_frame (s' := setHead { s with tok := true } _) hF rfl rfl rfl (fun _ hx => hx)
          (Or.inl (by simp [setHead, flightVer, hc])) rfl
    · exact hF
  | reauthFail =>
    simp only [step]; split
    · exact fix_catchFail (fix_same (s' := { s with tok := false }) hF rfl rfl rfl rfl rfl rfl) _
    · exact hF
  | libOk =>
    simp only [step]; split
    · exact fix_frame hF rfl rfl rfl (fun _ hx => hx) (Or.inr (by simp [setHead, flightVer])) rfl
    · exact hF
  | libFail clr =>
    simp only [step]; split
    · split
      · exact fix_catchFail (fix_same (s' := { s with tok := false }) hF rfl rfl rfl rfl rfl rfl) _
      · exact fix_catchFail hF _
    · exact hF
  | saveDone =>
    simp only [step]; split
    · exact fix_finish (s := setStatus { s with busy := false } .done)
        hI.tailWaiting
        (fix_same (s' := setStatus { s with busy := false } .done) hF rfl rfl rfl rfl rfl rfl) _
    · exact fix_finish (s := setStatus s .offline)
        hI.tailWaiting
        (fix_same (s' := setStatus s .offline) hF rfl rfl rfl rfl rfl rfl) _
    · exact hF
  | pullOk push lib =>
    simp only [step]; split
    · split
      · split
        · exact fix_frame hF (by simp [popHead, (refresh_fields _).2.2.2.2.2.2.1])
            (by simp [popHead, (refresh_fields _).2.2.2.2.2.1])
            (by simp [popHead, (refresh_fields _).2.2.2.2.2.2.2.1])
            (by simp [popHead, (refresh_fields _).2.2.1])
            (Or.inr (by simp [popHead, (refresh_fields _).1]; exact (head_waiting _ hI.tailWaiting).2.2.2))
            (by simp [popHead, (refresh_fields _).2.2.2.2.2.2.2.2.1])
        · exact fix_frame hF
            (by simp [popHead, scheduleFlush, (refresh_fields _).2.2.2.2.2.2.1])
            (by simp [popHead, scheduleFlush, (refresh_fields _).2.2.2.2.2.1])
            (by simp [popHead, scheduleFlush, (refresh_fields _).2.2.2.2.2.2.2.1])
            (by intro x hx; simp [popHead, scheduleFlush, (refresh_fields _).2.2.1, hx])
            (Or.inr (by simp [popHead, scheduleFlush, (refresh_fields _).1]
                        exact (head_waiting _ hI.tailWaiting).2.2.2))
            (by simp [popHead, scheduleFlush, (refresh_fields _).2.2.2.2.2.2.2.2.1])
      · exact fix_frame hF (by simp [popHead, (refresh_fields _).2.2.2.2.2.2.1])
            (by simp [popHead, (refresh_fields _).2.2.2.2.2.1])
            (by simp [popHead, (refresh_fields _).2.2.2.2.2.2.2.1])
            (by simp [popHead, (refresh_fields _).2.2.1])
            (Or.inr (by simp [popHead, (refresh_fields _).1]; exact (head_waiting _ hI.tailWaiting).2.2.2))
            (by simp [popHead, (refresh_fields _).2.2.2.2.2.2.2.2.1])
    · exact hF
  | pullFail clr =>
    simp only [step]; split
    · exact fix_frame hF rfl rfl rfl (fun _ hx => hx)
        (Or.inr (by simp [popHead, setStatus]; exact (head_waiting _ hI.tailWaiting).2.2.2)) rfl
    · exact hF

theorem reachable_fixInv {s : St} (h : Reachable s) : FixInv s := by
  induction h with
  | init => exact fixInv_init
  | step e hr ih => exact fix_step _ e (reachable_inv hr) ih

/-- **No re-dirtied name is dropped**: in every reachable state, a key whose
Drive copy is not its current local bytes is queued for upload, or its
markUpload is still to run. -/
theorem no_lost_upload {s : St} (h : Reachable s) (i : Nat) (hi : s.drive i ≠ s.ver i) :
    i ∈ s.queueUp ∨ i ∈ s.marks :=
  (reachable_fixInv h).good i hi

/-- ...and so once everything has drained, Drive holds every key's latest bytes. -/
theorem quiet_means_synced {s : St} (h : Reachable s) (hq : s.queueUp = []) (hm : s.marks = []) :
    ∀ i, s.drive i = s.ver i := by
  intro i
  by_cases hi : s.drive i = s.ver i
  · exact hi
  · rcases no_lost_upload h i hi with h' | h' <;> simp_all

end WebState.DriveSession.Queue

namespace WebState.DriveSession.Session

/-- renewDriveToken's continuation. `was` = wasSignedOut; `ep` = the Drive
session it started in (`driveSessionGuard()` at its start). -/
inductive RPc where
  /-- awaiting `loadGisScript()` -/
  | gis (was : Bool) (ep : Nat)
  /-- awaiting `gdriveAcquireToken("")`; `res` once the shared request settled -/
  | acq (was : Bool) (ep : Nat) (res : Option Bool)
  /-- awaiting `gdriveFetchEmail()`; the tokeninfo fetch carried `tokAt` -/
  | email (tokAt : Option Nat) (ep : Nat)
  deriving DecidableEq, Repr

/-- gdriveConnect's continuation. `acq` and `email` are the stretch where
`driveConnecting` counts it. -/
inductive CPc where
  /-- awaiting `gdriveAcquireToken(undefined, email, { connect: true })` -/
  | acq (res : Option Bool)
  /-- awaiting `gdriveFetchEmail()` -/
  | email (tokAt : Option Nat)
  /-- awaiting `saveSyncState()` -/
  | save
  /-- runFullSync: awaiting `localSyncFiles()` + `saveSyncState()` -/
  | full
  deriving DecidableEq, Repr

/-- flushSyncInner, coarse: `own` is the account whose syncState (queues,
tombstones, renames) and Drive library the flush captured at its start, `ep`
the session it started in (`driveSessionGuard()`). -/
inductive FPc where
  | start
  | prelude (own : Nat) (ep : Nat)
  /-- an upload in flight, `k` more after it -/
  | upload (own : Nat) (ep : Nat) (k : Nat)
  /-- driveFetch got 401 with activation: awaiting `gdriveAcquireToken("")` -/
  | reauth (own : Nat) (ep : Nat) (k : Nat) (res : Option Bool)
  /-- `writeDriveLibrary(lib, ...)` in flight -/
  | libWrite (own : Nat) (ep : Nat)
  deriving DecidableEq, Repr

inductive Job where
  | flush (pc : FPc) (after : Bool)
  | pull (started : Bool)
  deriving DecidableEq, Repr

structure St where
  connected  : Bool             -- syncState.connected (driveLinked)
  token      : Option Nat       -- gdriveToken, as the Google account it was granted for
  email      : Option Nat       -- syncState.email: the login_hint (an account)
  acct       : Nat              -- syncState.acct: whose queues/tombstones are loaded
  fails      : Nat              -- driveRenewFails
  armed      : Bool             -- driveRenewArmed
  req        : Option (Option Nat × Nat) -- gdriveTokenInFlight: its login_hint and the session it was issued in
  renews     : List RPc         -- renewDriveToken calls in flight
  connects   : List CPc         -- gdriveConnect calls in flight
  chain      : List Job         -- syncChain (head runs)
  pullQueued : Bool             -- pullQueued
  pullCalls  : Nat              -- pending `.then(() => pullSync())`
  epoch      : Nat              -- driveSession
  -- ghosts
  gestures   : Nat              -- window pointerdown/keydown/touchstart events
  renewCalls : Nat              -- renewDriveToken() invocations
  denials    : Nat              -- token requests refused (popup closed/blocked, grant gone)
  outTraffic : Bool             -- a Drive request left with a live token while signed out, no sign-in running
  crossLib   : Bool             -- a library captured under one account was written to another account's Drive
  deriving DecidableEq, Repr

/-- Reload more than an hour after the last grant, account 1 linked:
resumeDriveOnBoot finds the persisted token expired and arms the gesture
renewal. -/
def init : St :=
  { connected := true, token := none, email := some 1, acct := 1, fails := 0, armed := true,
    req := none, renews := [], connects := [], chain := [], pullQueued := false, pullCalls := 0,
    epoch := 0, gestures := 0, renewCalls := 0, denials := 0, outTraffic := false, crossLib := false }

inductive Ev where
  /-- a window pointerdown/keydown/touchstart reaches the armed capture listener;
  `online` = navigator.onLine at renewDriveToken's check -/
  | gesture (online : Bool)
  /-- armDriveRenewOnGesture from syncPollTick, visibilitychange,
  resumeDriveOnBoot or driveFetch's 401 path -/
  | arm
  /-- renewal #k: loadGisScript settled (`ok`), hasUserActivation() = `act` -/
  | renewGis (k : Nat) (ok : Bool) (act : Bool)
  /-- renewal #k resumes after its token request settled -/
  | renewAcq (k : Nat)
  /-- renewal #k's gdriveFetchEmail settled; tokeninfo `ok` -/
  | renewEmail (k : Nat) (ok : Bool)
  /-- the GIS callback delivers a token for account `a` -/
  | tokGrant (a : Nat)
  /-- error_callback / resp.error -/
  | tokDeny
  /-- a Sign in button: gdriveConnect -/
  | signIn
  | connAcq (k : Nat)
  | connEmail (k : Nat) (ok : Bool)
  | connSave (k : Nat)
  | connFull (k : Nat)
  /-- the Sign out button: gdriveSignOut -/
  | signOut
  /-- syncPollTick's sync part: `withFlush` = pendingCount() -/
  | poll (withFlush : Bool)
  /-- visibilitychange -> visible, or window online -/
  | visible
  | callPull
  /-- the chain head's body starts; `proceed`: flushSyncInner found work -/
  | jobStart (proceed : Bool)
  /-- the flush's prelude settled; `k` names to upload -/
  | preludeOk (k : Nat)
  | upOk
  | up401 (activation : Bool)
  | reauthRes
  | libDone
  /-- a request of the running flush failed (network/HTTP): catch -/
  | jobFail
  /-- the pull settled; `clear`: its driveFetch hit 401 with no activation -/
  | pullDone (clear : Bool)
  deriving DecidableEq, Repr

/-- armDriveRenewOnGesture. -/
def arm (s : St) : St :=
  if s.armed || !s.connected || decide (s.fails ≥ 3) then s else { s with armed := true }

/-- gdriveAcquireToken: join the request in flight, or issue one with this
hint, recording the session it was issued in. -/
def joinOrCreate (s : St) (hint : Option Nat) : St :=
  if s.req.isSome then s else { s with req := some (hint, s.epoch) }

def CPc.ident : CPc → Bool
  | .acq _ => true
  | .email _ => true
  | _ => false

/-- `driveConnecting > 0`: a sign-in between asking for a token and knowing whose it is. -/
def identifying (s : St) : Bool := s.connects.any CPc.ident

/-- `gdriveTokenForConnect`: a sign-in is waiting on the request in flight. -/
def connectWaits (s : St) : Bool := s.connects.contains (.acq none)

/-- syncActive(): a token, a linked account, and no sign-in mid-way. -/
def syncActive (s : St) : Bool := s.token.isSome && s.connected && !identifying s

/-- a Drive request leaves with the current token -/
def send (s : St) : St :=
  if s.token.isSome && !s.connected && s.connects.isEmpty then { s with outTraffic := true } else s

/-- the library write leaves with the current token -/
def libSend (s : St) (own : Nat) : St :=
  let s := send s
  match s.token with
  | some b => if b = own then s else { s with crossLib := true }
  | none => s

/-- gdriveFetchEmail's tail: only if the tab still holds the token it asked
about; rememberDriveEmail + adoptDriveAccount, which takes a new session when
the account changes. -/
def fetchEmail (s : St) (tokAt : Option Nat) (ok : Bool) : St :=
  match tokAt, ok with
  | some a, true =>
    if s.token = some a then
      (if s.acct = a then { s with email := some a }
       else { s with email := some a, acct := a, epoch := s.epoch + 1 })
    else s
  | _, _ => s

/-- gdriveFetchEmail resolved to an account id. -/
def identified (s : St) (tokAt : Option Nat) (ok : Bool) : Bool :=
  match tokAt, ok with
  | some a, true => s.token == some a
  | _, _ => false

def flushSync (s : St) (after : Bool) : St := { s with chain := s.chain ++ [.flush .start after] }
def pullSync (s : St) : St :=
  if s.pullQueued then s else { s with pullQueued := true, chain := s.chain ++ [.pull false] }
def setHead (s : St) (j : Job) : St := { s with chain := j :: s.chain.tail }
def popHead (s : St) : St := { s with chain := s.chain.tail }
def finish (s : St) (after : Bool) : St :=
  if after then { popHead s with pullCalls := s.pullCalls + 1 } else popHead s

/-- renewDriveToken's first segment -/
def renewCall (s : St) (online : Bool) : St :=
  let s := { s with renewCalls := s.renewCalls + 1 }
  if !s.connected then s
  else if !online then arm s
  else { s with renews := s.renews ++ [.gis s.token.isNone s.epoch] }

def stampR (r : Bool) : RPc → RPc
  | .acq w ep none => .acq w ep (some r)
  | c => c
def stampC (r : Bool) : CPc → CPc
  | .acq none => .acq (some r)
  | c => c
def stampJ (r : Bool) : Job → Job
  | .flush (.reauth o ep k none) a => .flush (.reauth o ep k (some r)) a
  | j => j

/-- the request settles: every caller awaiting it resumes with the outcome -/
def settle (s : St) (r : Bool) : St :=
  { s with req := none, renews := s.renews.map (stampR r), connects := s.connects.map (stampC r),
           chain := s.chain.map (stampJ r) }

/-- The JS each branch follows (web/index.js): the gesture listener and
`renewDriveToken` 3949-4019 (its `over()` checks 3986, 3996, 4010, 4014); the
GIS callback 2049-2072 (the session rule at 2061); `gdriveConnect` 3885-3909
(its request 3889, the refusal 3897, the new session 3901); `gdriveSignOut`
2257; `syncPollTick` 4064, `online` 4077, `visibilitychange` 4085;
`flushSyncInner` 2837-3002 (`live()` after every await) and `pullSync` 3095;
`driveFetch`'s 401 path 2129-2146 (the replay's session check 2145);
`gdriveFetchEmail` 2099-2116 and `adoptDriveAccount` 2430-2453. -/
def step (s : St) : Ev → St
  | .gesture on =>
      let s := { s with gestures := s.gestures + 1 }
      if s.armed then renewCall { s with armed := false } on else s
  | .arm => arm s
  | .renewGis k ok act =>
      match s.renews[k]? with
      | some (.gis was ep) =>
          let s := { s with renews := s.renews.eraseIdx k }
          if !ok then arm s
          -- `if (over()) return;` (signed out or in again while the script loaded)
          else if ep ≠ s.epoch || !s.connected then s
          else if !act then arm s
          else let s := joinOrCreate s s.email
               { s with renews := s.renews ++ [.acq was ep none] }
      | _ => s
  | .renewAcq k =>
      match s.renews[k]? with
      | some (.acq was ep (some r)) =>
          let s := { s with renews := s.renews.eraseIdx k }
          -- both paths start `if (over()) return;`: a refusal caused by the
          -- session ending is not a strike
          if ep ≠ s.epoch || !s.connected then s
          else if !r then
            let s := { s with fails := s.fails + 1 }
            if s.fails ≥ 3 then { s with token := none } else arm s
          else
            let s := { s with fails := 0 }
            if !was then s else { s with renews := s.renews ++ [.email s.token ep] }
      | _ => s
  | .renewEmail k ok =>
      match s.renews[k]? with
      | some (.email t ep) =>
          let s := fetchEmail { s with renews := s.renews.eraseIdx k } t ok
          if ep ≠ s.epoch || !s.connected then s else pullSync s
      | _ => s
  | .tokGrant a =>
      match s.req with
      | some (h, e) =>
          -- with a login_hint the grant is for that account
          if h = none || h = some a then
            -- a sign-in waits on it: a new session, whichever account
            if connectWaits s then { settle s true with token := some a, epoch := s.epoch + 1 }
            -- otherwise only for the linked session that asked
            else if s.connected && e == s.epoch then { settle s true with token := some a }
            else settle s false
          else s
      | none => s
  | .tokDeny =>
      match s.req with
      | some _ => { settle s false with denials := s.denials + 1 }
      | none => s
  | .signIn =>
      if s.connected then s
      else let s := joinOrCreate s s.email
           { s with connects := s.connects ++ [.acq none] }
  | .connAcq k =>
      match s.connects[k]? with
      | some (.acq (some r)) =>
          let s := { s with connects := s.connects.eraseIdx k }
          if r then { s with connects := s.connects ++ [.email s.token] } else s
      | _ => s
  | .connEmail k ok =>
      match s.connects[k]? with
      | some (.email t) =>
          let s := { s with connects := s.connects.eraseIdx k }
          -- `if (!acct && syncState.acct) { clearDriveToken(); throw }`
          if !identified s t ok then { s with token := none }
          else
            let s := fetchEmail s t ok
            { s with fails := 0, connected := true, epoch := s.epoch + 1,
                     connects := s.connects ++ [.save] }
      | _ => s
  | .connSave k =>
      match s.connects[k]? with
      | some .save =>
          let s := { s with connects := s.connects.eraseIdx k }
          -- runFullSync: `if (!syncActive()) return;`
          if syncActive s then { s with connects := s.connects ++ [.full] } else s
      | _ => s
  | .connFull k =>
      match s.connects[k]? with
      | some .full => flushSync { s with connects := s.connects.eraseIdx k } true
      | _ => s
  | .signOut =>
      -- revoke (not modelled), rememberDriveEmail(null), connected = false,
      -- clearDriveToken(), a new session. syncChain and renewals untouched.
      if !s.connected then s
      else { s with email := none, connected := false, token := none, epoch := s.epoch + 1 }
  | .poll wf => if !syncActive s then s else if wf then flushSync s true else pullSync s
  | .visible => if syncActive s then flushSync s true else s
  | .callPull => if s.pullCalls > 0 then pullSync { s with pullCalls := s.pullCalls - 1 } else s
  | .jobStart p =>
      match s.chain with
      | .flush .start after :: _ =>
          if !syncActive s || !p then finish s after
          else send (setHead s (.flush (.prelude s.acct s.epoch) after))
      | .pull false :: _ =>
          let s := { s with pullQueued := false }
          if !syncActive s then popHead s else send (setHead s (.pull true))
      | _ => s
  | .preludeOk k =>
      match s.chain with
      | .flush (.prelude o ep) after :: _ =>
          -- `live(await ...)`: the session it started in is over
          if ep ≠ s.epoch then finish s after
          else if k = 0 then libSend (setHead s (.flush (.libWrite o ep) after)) o
          else send (setHead s (.flush (.upload o ep (k - 1)) after))
      | _ => s
  | .upOk =>
      match s.chain with
      | .flush (.upload o ep k) after :: _ =>
          if ep ≠ s.epoch then finish s after
          else if k = 0 then libSend (setHead s (.flush (.libWrite o ep) after)) o
          else send (setHead s (.flush (.upload o ep (k - 1)) after))
      | _ => s
  | .up401 act =>
      match s.chain with
      | .flush (.upload o ep k) after :: _ =>
          -- driveFetch: no popup without activation, nor for a signed-out tab
          if act && s.connected then setHead (joinOrCreate s s.email) (.flush (.reauth o ep k none) after)
          else finish (arm { s with token := none }) after
      | _ => s
  | .reauthRes =>
      match s.chain with
      | .flush (.reauth o ep k (some r)) after :: _ =>
          if !r then finish (arm { s with token := none }) after
          -- the replay is sent only in the session the request started in
          else if ep ≠ s.epoch then finish s after
          else send (setHead s (.flush (.upload o ep k) after))
      | _ => s
  | .libDone =>
      match s.chain with
      | .flush (.libWrite _ _) after :: _ => finish s after
      | _ => s
  | .jobFail =>
      match s.chain with
      | .flush (.prelude _ _) after :: _ => finish s after
      | .flush (.upload _ _ _) after :: _ => finish s after
      | .flush (.libWrite _ _) after :: _ => finish s after
      | _ => s
  | .pullDone clr =>
      match s.chain with
      | .pull true :: _ => popHead (if clr then arm { s with token := none } else s)
      | _ => s

inductive Reachable : St → Prop
  | init : Reachable init
  | step {s} (e : Ev) : Reachable s → Reachable (step s e)

def run (s : St) (es : List Ev) : St := es.foldl step s

theorem reachable_run (es : List Ev) : ∀ s, Reachable s → Reachable (run s es) := by
  induction es with
  | nil => intro s h; exact h
  | cons e es ih => intro s h; exact ih _ (Reachable.step e h)

/-! ### The findings' traces, against the fixed code -/

/-- A renewal in flight survives Sign out (null-token variant: a background
flush's 401 cleared the token and armed the renewal while Settings was open).
The user's first input is on "Sign out": its pointerdown runs the capture
listener first and the silent popup opens; then its click runs gdriveSignOut.
The grant lands after. Against dd7ba741f the GIS callback set and persisted
the token, the renewal re-remembered the email and pulled, with
`connected = false` (`bug_renewal_resurrects_token`). -/
def resurrectTrace : List Ev :=
  [.gesture true, .renewGis 0 true true, .signOut, .tokGrant 1, .renewAcq 0,
   .renewEmail 0 true, .jobStart true]

/-- **Fixed: the late grant is refused** (the session that asked for it is
over), the renewal ends without a strike, and nothing leaves the tab. -/
theorem regress_renewal_after_signout :
    let s := run init resurrectTrace
    s.connected = false ∧ s.token = none ∧ s.email = none ∧ s.outTraffic = false ∧
    s.req = none ∧ s.renews = [] ∧ s.connects = [] ∧ s.fails = 0 := by
  decide

/-- **Fixed: the signed-out tab stays quiet** (was
`bug_signed_out_tab_keeps_syncing`: every poll flushed and pulled with the
resurrected token). -/
theorem regress_signed_out_quiet :
    let s := run init (resurrectTrace ++ [.pullDone false, .poll true, .jobStart true, .preludeOk 1])
    s.connected = false ∧ s.token = none ∧ s.chain = [] ∧ s.outTraffic = false := by
  decide

/-- The rollover variant: a live but stale token, armed by the poll;
wasSignedOut is false so there is no immediate pull, but against dd7ba741f the
new token outlived the sign-out and the next poll used it. -/
def resurrectRolloverTrace : List Ev :=
  [.gesture true, .renewGis 0 true true, .tokGrant 1, .renewAcq 0, .renewEmail 0 true,
   .jobStart true, .pullDone false,
   .arm, .gesture true, .renewGis 0 true true, .signOut, .tokGrant 1, .renewAcq 0,
   .poll false, .jobStart true]

theorem regress_renewal_rollover :
    let s := run init resurrectRolloverTrace
    s.connected = false ∧ s.token = none ∧ s.outTraffic = false ∧ s.renews = [] ∧
    s.connects = [] := by
  decide

/-- A flush running when the user signs out and back in as another account.
Against dd7ba741f it finished under the new account's token and wrote the
library it merged from account 1's Drive, with account 1's tombstones and
renames, into account 2's Drive (`bug_flush_crosses_accounts`). -/
def crossTrace : List Ev :=
  [.gesture true, .renewGis 0 true true, .tokGrant 1, .renewAcq 0, .renewEmail 0 true,
   .jobStart true, .pullDone false,
   .poll true, .jobStart true, .preludeOk 1,
   .signOut, .signIn, .tokGrant 2, .connAcq 0, .connEmail 0 true,
   .upOk]

/-- **Fixed: the flush stops at its next await** (its session ended at Sign
out), account 2's own full sync runs next, and nothing crossed. -/
theorem regress_no_cross_account :
    let s := run init crossTrace
    s.crossLib = false ∧ s.acct = 2 ∧ s.token = some 2 ∧ s.connected = true ∧
    s.chain = [] ∧ s.connects = [.save] := by
  decide

/-- ...and account 2's own sync, run to the end, writes account 2's library. -/
theorem regress_no_cross_account_then_sync :
    let s := run init (crossTrace ++ [.connSave 0, .connFull 0, .jobStart true, .preludeOk 0])
    s.crossLib = false ∧ s.chain = [.flush (.libWrite 2 s.epoch) true] := by
  decide

/-- Two renewals can be in flight at once (the arm flag is cleared before the
first one's attempt, and a poll/visibilitychange/401 may re-arm while its
popup is open), and the second joins the first's popup. One refused popup
then costs two of the three strikes. Not fixed here. -/
def strikeTrace : List Ev :=
  [.gesture true, .renewGis 0 true true, .arm, .gesture true, .renewGis 1 true true,
   .tokDeny, .renewAcq 0, .renewAcq 0]

theorem bug_one_popup_two_strikes :
    let s := run init strikeTrace
    s.denials = 1 ∧ s.fails = 2 ∧ s.renewCalls = 2 := by
  decide

/-- Found while modelling the fix: a sign-in whose tokeninfo request fails
(account unknown) against dd7ba741f still became `connected` with the
previous account's queues and tombstones loaded under the new account's
token, and its runFullSync wrote them into that account's Drive, with no
race needed. Now the sign-in is refused and the token dropped. -/
def unconfirmedTrace : List Ev :=
  [.gesture true, .renewGis 0 true true, .tokGrant 1, .renewAcq 0, .renewEmail 0 true,
   .jobStart true, .pullDone false,
   .signOut, .signIn, .tokGrant 2, .connAcq 0, .connEmail 0 false]

theorem regress_unconfirmed_signin :
    let s := run init unconfirmedTrace
    s.connected = false ∧ s.token = none ∧ s.acct = 1 ∧ s.connects = [] ∧ s.crossLib = false := by
  decide


/-! ### Proved: renewal needs a gesture per attempt (no self-sustaining loop) -/

section counters
variable (s : St)
@[simp] theorem arm_c : (arm s).renewCalls = s.renewCalls ∧ (arm s).gestures = s.gestures := by
  unfold arm; split <;> simp
@[simp] theorem join_c (h : Option Nat) :
    (joinOrCreate s h).renewCalls = s.renewCalls ∧ (joinOrCreate s h).gestures = s.gestures := by
  unfold joinOrCreate; split <;> simp
@[simp] theorem send_c : (send s).renewCalls = s.renewCalls ∧ (send s).gestures = s.gestures := by
  unfold send; split <;> simp
@[simp] theorem libSend_c (o : Nat) :
    (libSend s o).renewCalls = s.renewCalls ∧ (libSend s o).gestures = s.gestures := by
  unfold libSend; simp only; split
  · split <;> simp
  · simp
@[simp] theorem fetchEmail_c (t : Option Nat) (ok : Bool) :
    (fetchEmail s t ok).renewCalls = s.renewCalls ∧ (fetchEmail s t ok).gestures = s.gestures := by
  unfold fetchEmail; split
  · split
    · split <;> simp
    · simp
  · simp
@[simp] theorem pullSync_c : (pullSync s).renewCalls = s.renewCalls ∧ (pullSync s).gestures = s.gestures := by
  unfold pullSync; split <;> simp
@[simp] theorem finish_c (a : Bool) :
    (finish s a).renewCalls = s.renewCalls ∧ (finish s a).gestures = s.gestures := by
  unfold finish; split <;> simp [popHead]
@[simp] theorem settle_c (r : Bool) :
    (settle s r).renewCalls = s.renewCalls ∧ (settle s r).gestures = s.gestures := by
  simp [settle]
end counters

/-- Every event other than a gesture leaves the renewal count alone:
`armDriveRenewOnGesture` only adds listeners, and `renewDriveToken`'s every
exit path (offline, script failure, no activation, refusal, session over)
re-arms or stops instead of retrying. -/
theorem only_gesture_renews (s : St) (e : Ev) (he : ∀ on, e ≠ .gesture on) :
    (step s e).renewCalls = s.renewCalls ∧ (step s e).gestures = s.gestures := by
  cases e with
  | gesture on => exact absurd rfl (he on)
  | _ =>
    simp only [step]
    repeat' split
    all_goals first
      | rfl
      | (constructor <;> rfl)
      | simp [setHead, popHead]
      | (simp only [arm_c, join_c, send_c, libSend_c, fetchEmail_c, pullSync_c, finish_c, settle_c,
          and_self])
      | skip

/-- A gesture starts at most one renewal. -/
theorem gesture_renews_once (s : St) (on : Bool) :
    (step s (.gesture on)).renewCalls ≤ s.renewCalls + 1 ∧
    (step s (.gesture on)).gestures = s.gestures + 1 := by
  simp only [step]; split
  · unfold renewCall; simp only; split
    · simp
    · split
      · have := arm_c { s with gestures := s.gestures + 1, armed := false, renewCalls := s.renewCalls + 1 }
        simp_all
      · simp
  · simp

/-- **Renewal attempts never outnumber user gestures**: token renewal cannot
loop on its own. -/
theorem renewals_le_gestures {s : St} (h : Reachable s) : s.renewCalls ≤ s.gestures := by
  induction h with
  | init => simp [init]
  | @step s e _ ih =>
    by_cases hg : ∃ on, e = .gesture on
    · obtain ⟨on, rfl⟩ := hg
      obtain ⟨a, b⟩ := gesture_renews_once s on
      omega
    · obtain ⟨a, b⟩ := only_gesture_renews s e (fun on h' => hg ⟨on, h'⟩)
      omega

/-! ### Proved: one token request, no orphaned caller

Overlapping `gdriveAcquireToken` calls must not orphan a popup's promise. In
every reachable state, a caller still waiting on a token (a renewal, a
connect, or a flush's 401 re-grant) has a request in flight to wait on. -/

def RPc.waitTok : RPc → Bool
  | .acq _ _ none => true
  | _ => false
def CPc.waitTok : CPc → Bool
  | .acq none => true
  | _ => false
def Job.waitTok : Job → Bool
  | .flush (.reauth _ _ _ none) _ => true
  | _ => false

def NoOrphan (s : St) : Prop :=
  s.req = none → (∀ c ∈ s.renews, c.waitTok = false) ∧ (∀ c ∈ s.connects, c.waitTok = false) ∧
    (∀ j ∈ s.chain, j.waitTok = false)

theorem noOrphan_of {s s' : St} (h : NoOrphan s) (hreq : s'.req = none → s.req = none)
    (hr : ∀ c ∈ s'.renews, c.waitTok = true → c ∈ s.renews)
    (hc : ∀ c ∈ s'.connects, c.waitTok = true → c ∈ s.connects)
    (hj : ∀ j ∈ s'.chain, j.waitTok = true → j ∈ s.chain) : NoOrphan s' := by
  intro hn
  obtain ⟨a, b, c⟩ := h (hreq hn)
  refine ⟨?_, ?_, ?_⟩
  · intro x hx; cases hw : x.waitTok
    · rfl
    · have := a x (hr x hx hw); rw [hw] at this; exact this
  · intro x hx; cases hw : x.waitTok
    · rfl
    · have := b x (hc x hx hw); rw [hw] at this; exact this
  · intro x hx; cases hw : x.waitTok
    · rfl
    · have := c x (hj x hx hw); rw [hw] at this; exact this

theorem noOrphan_req {s : St} (h : s.req.isSome = true) : NoOrphan s := by
  intro hn; rw [hn] at h; cases h

theorem joinOrCreate_req (s : St) (h : Option Nat) : (joinOrCreate s h).req.isSome = true := by
  unfold joinOrCreate; split
  · assumption
  · rfl

theorem stampR_wait (r : Bool) (c : RPc) : (stampR r c).waitTok = false := by
  rcases c with _ | ⟨w, ep, _ | _⟩ | _ <;> rfl
theorem stampC_wait (r : Bool) (c : CPc) : (stampC r c).waitTok = false := by
  rcases c with _ | _ | _ | _ <;> (try rename_i x; cases x) <;> rfl
theorem stampJ_wait (r : Bool) (j : Job) : (stampJ r j).waitTok = false := by
  rcases j with ⟨pc, a⟩ | ⟨b⟩
  · cases pc with
    | reauth o ep k res => cases res <;> rfl
    | _ => rfl
  · rfl

theorem noOrphan_settle (s : St) (r : Bool) (f : St → St) (hf : ∀ x, (f x).req = x.req ∧
    (f x).renews = x.renews ∧ (f x).connects = x.connects ∧ (f x).chain = x.chain) :
    NoOrphan (f (settle s r)) := by
  intro _
  obtain ⟨-, h2, h3, h4⟩ := hf (settle s r)
  refine ⟨?_, ?_, ?_⟩
  · intro c hc; rw [h2] at hc; simp [settle] at hc; obtain ⟨c', -, rfl⟩ := hc; exact stampR_wait r c'
  · intro c hc; rw [h3] at hc; simp [settle] at hc; obtain ⟨c', -, rfl⟩ := hc; exact stampC_wait r c'
  · intro j hj; rw [h4] at hj; simp [settle] at hj; obtain ⟨j', -, rfl⟩ := hj; exact stampJ_wait r j'

theorem mem_eraseIdx {α} {l : List α} {k : Nat} {x : α} (h : x ∈ l.eraseIdx k) : x ∈ l :=
  List.mem_of_mem_eraseIdx h

section frames
variable (s : St)
theorem arm_f : (arm s).req = s.req ∧ (arm s).renews = s.renews ∧ (arm s).connects = s.connects ∧
    (arm s).chain = s.chain := by unfold arm; split <;> simp
theorem send_f : (send s).req = s.req ∧ (send s).renews = s.renews ∧ (send s).connects = s.connects ∧
    (send s).chain = s.chain := by unfold send; split <;> simp
theorem libSend_f (o : Nat) : (libSend s o).req = s.req ∧ (libSend s o).renews = s.renews ∧
    (libSend s o).connects = s.connects ∧ (libSend s o).chain = s.chain := by
  unfold libSend; simp only; split
  · split
    · exact send_f s
    · simp [send_f s]
  · exact send_f s
theorem fetchEmail_f (t : Option Nat) (ok : Bool) : (fetchEmail s t ok).req = s.req ∧
    (fetchEmail s t ok).renews = s.renews ∧ (fetchEmail s t ok).connects = s.connects ∧
    (fetchEmail s t ok).chain = s.chain := by
  unfold fetchEmail; split
  · split
    · split <;> simp
    · simp
  · simp
theorem pullSync_f : (pullSync s).req = s.req ∧ (pullSync s).renews = s.renews ∧
    (pullSync s).connects = s.connects ∧ (∀ j ∈ (pullSync s).chain, j.waitTok = true → j ∈ s.chain) := by
  unfold pullSync; split
  · exact ⟨rfl, rfl, rfl, fun j hj _ => hj⟩
  · refine ⟨rfl, rfl, rfl, ?_⟩
    intro j hj hw; simp at hj; rcases hj with hj | rfl
    · exact hj
    · simp [Job.waitTok] at hw
theorem finish_f (a : Bool) : (finish s a).req = s.req ∧ (finish s a).renews = s.renews ∧
    (finish s a).connects = s.connects ∧ (∀ j ∈ (finish s a).chain, j ∈ s.chain) := by
  unfold finish; split <;> simp [popHead] <;> exact fun j hj => List.mem_of_mem_tail hj
end frames

theorem setHead_sub (s : St) (j : Job) (hj : j.waitTok = false) :
    ∀ x ∈ (setHead s j).chain, x.waitTok = true → x ∈ s.chain := by
  intro x hx hw; simp [setHead] at hx
  rcases hx with rfl | hx
  · rw [hj] at hw; cases hw
  · exact List.mem_of_mem_tail hx

/-- The frame most steps stay inside: the request unchanged or made, and no
new waiter. -/
theorem noOrphan_frame {s s' : St} (h : NoOrphan s)
    (hreq : s'.req = s.req ∨ s'.req.isSome = true)
    (hr : ∀ c ∈ s'.renews, c.waitTok = true → c ∈ s.renews)
    (hc : ∀ c ∈ s'.connects, c.waitTok = true → c ∈ s.connects)
    (hj : ∀ j ∈ s'.chain, j.waitTok = true → j ∈ s.chain) : NoOrphan s' := by
  rcases hreq with e | e
  · exact noOrphan_of h (by rw [e]; exact id) hr hc hj
  · exact noOrphan_req e

theorem noOrphan_arm {s : St} (h : NoOrphan s) : NoOrphan (arm s) := by
  obtain ⟨a1, a2, a3, a4⟩ := arm_f s
  exact noOrphan_frame h (Or.inl a1) (by rw [a2]; exact fun c hc _ => hc)
    (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact fun c hc _ => hc)

theorem noOrphan_finish {s : St} (h : NoOrphan s) (a : Bool) : NoOrphan (finish s a) := by
  obtain ⟨a1, a2, a3, a4⟩ := finish_f s a
  exact noOrphan_frame h (Or.inl a1) (by rw [a2]; exact fun c hc _ => hc)
    (by rw [a3]; exact fun c hc _ => hc) (fun j hj _ => a4 j hj)

theorem noOrphan_send_setHead {s : St} (h : NoOrphan s) (j : Job) (hj : j.waitTok = false) :
    NoOrphan (send (setHead s j)) := by
  obtain ⟨a1, a2, a3, a4⟩ := send_f (setHead s j)
  exact noOrphan_frame h (Or.inl a1) (by rw [a2]; exact fun c hc _ => hc)
    (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact setHead_sub s j hj)

theorem noOrphan_libSend_setHead {s : St} (h : NoOrphan s) (j : Job) (hj : j.waitTok = false) (o : Nat) :
    NoOrphan (libSend (setHead s j) o) := by
  obtain ⟨a1, a2, a3, a4⟩ := libSend_f (setHead s j) o
  exact noOrphan_frame h (Or.inl a1) (by rw [a2]; exact fun c hc _ => hc)
    (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact setHead_sub s j hj)

theorem noOrphan_pullSync {s : St} (h : NoOrphan s) : NoOrphan (pullSync s) := by
  obtain ⟨a1, a2, a3, a4⟩ := pullSync_f s
  exact noOrphan_frame h (Or.inl a1) (by rw [a2]; exact fun c hc _ => hc)
    (by rw [a3]; exact fun c hc _ => hc) a4

theorem noOrphan_step (s : St) (e : Ev) (h : NoOrphan s) : NoOrphan (step s e) := by
  have same : ∀ s' : St, s'.req = s.req → s'.renews = s.renews → s'.connects = s.connects →
      s'.chain = s.chain → NoOrphan s' := by
    intro s' a b c d
    exact noOrphan_frame h (Or.inl a) (by rw [b]; exact fun x hx _ => hx)
      (by rw [c]; exact fun x hx _ => hx) (by rw [d]; exact fun x hx _ => hx)
  -- erasing a continuation (and possibly re-arming / clearing the token)
  have erR : ∀ k, NoOrphan { s with renews := s.renews.eraseIdx k } :=
    fun k => noOrphan_frame h (Or.inl rfl) (fun c hc _ => mem_eraseIdx hc)
      (fun c hc _ => hc) (fun j hj _ => hj)
  have erC : ∀ k, NoOrphan { s with connects := s.connects.eraseIdx k } :=
    fun k => noOrphan_frame h (Or.inl rfl) (fun c hc _ => hc)
      (fun c hc _ => mem_eraseIdx hc) (fun j hj _ => hj)
  cases e with
  | gesture on =>
    simp only [step]; split
    · unfold renewCall; simp only; split
      · exact same _ rfl rfl rfl rfl
      · split
        · exact noOrphan_arm (same _ rfl rfl rfl rfl)
        · refine noOrphan_frame h (Or.inl rfl) ?_ (fun c hc _ => hc) (fun j hj _ => hj)
          intro c hc hw; simp at hc; rcases hc with hc | rfl
          · exact hc
          · simp [RPc.waitTok] at hw
    · exact same _ rfl rfl rfl rfl
  | arm => exact noOrphan_arm h
  | renewGis k ok act =>
    simp only [step]; split
    · rename_i was ep _
      split
      · exact noOrphan_arm (erR k)
      · split
        · exact erR k
        · split
          · exact noOrphan_arm (erR k)
          · exact noOrphan_req (joinOrCreate_req _ _)
    · exact h
  | renewAcq k =>
    simp only [step]; split
    · split
      · exact erR k
      · split
        · split
          · exact noOrphan_frame (erR k) (Or.inl rfl) (fun c hc _ => hc) (fun c hc _ => hc)
              (fun j hj _ => hj)
          · exact noOrphan_arm (noOrphan_frame (erR k) (Or.inl rfl) (fun c hc _ => hc)
              (fun c hc _ => hc) (fun j hj _ => hj))
        · split
          · exact noOrphan_frame (erR k) (Or.inl rfl) (fun c hc _ => hc) (fun c hc _ => hc)
              (fun j hj _ => hj)
          · refine noOrphan_frame (erR k) (Or.inl rfl) ?_ (fun c hc _ => hc) (fun j hj _ => hj)
            intro c hc hw; simp at hc; rcases hc with hc | rfl
            · exact hc
            · simp [RPc.waitTok] at hw
    · exact h
  | renewEmail k ok =>
    simp only [step]; split
    · rename_i t ep _
      have hF : NoOrphan (fetchEmail { s with renews := s.renews.eraseIdx k } t ok) := by
        obtain ⟨b1, b2, b3, b4⟩ := fetchEmail_f { s with renews := s.renews.eraseIdx k } t ok
        exact noOrphan_frame (erR k) (Or.inl b1) (by rw [b2]; exact fun c hc _ => hc)
          (by rw [b3]; exact fun c hc _ => hc) (by rw [b4]; exact fun c hc _ => hc)
      split
      · exact hF
      · exact noOrphan_pullSync hF
    · exact h
  | tokGrant a =>
    simp only [step]; split
    · split
      · split
        · exact noOrphan_settle s true (fun x => { x with token := some a, epoch := s.epoch + 1 })
            (fun _ => ⟨rfl, rfl, rfl, rfl⟩)
        · split
          · exact noOrphan_settle s true (fun x => { x with token := some a })
              (fun _ => ⟨rfl, rfl, rfl, rfl⟩)
          · exact noOrphan_settle s false id (fun _ => ⟨rfl, rfl, rfl, rfl⟩)
      · exact h
    · exact h
  | tokDeny =>
    simp only [step]; split
    · exact noOrphan_settle s false (fun x => { x with denials := s.denials + 1 })
        (fun _ => ⟨rfl, rfl, rfl, rfl⟩)
    · exact h
  | signIn =>
    simp only [step]; split
    · exact h
    · exact noOrphan_req (joinOrCreate_req _ _)
  | connAcq k =>
    simp only [step]; split
    · split
      · refine noOrphan_frame (erC k) (Or.inl rfl) (fun c hc _ => hc) ?_ (fun j hj _ => hj)
        intro c hc hw; simp at hc; rcases hc with hc | rfl
        · exact hc
        · simp [CPc.waitTok] at hw
      · exact erC k
    · exact h
  | connEmail k ok =>
    simp only [step]; split
    · rename_i t _
      split
      · exact noOrphan_frame (erC k) (Or.inl rfl) (fun c hc _ => hc) (fun c hc _ => hc)
          (fun j hj _ => hj)
      · obtain ⟨b1, b2, b3, b4⟩ := fetchEmail_f { s with connects := s.connects.eraseIdx k } t ok
        refine noOrphan_frame (erC k) (Or.inl (by simp only; exact b1)) (by simp only; rw [b2]; exact fun c hc _ => hc)
          ?_ (by simp only; rw [b4]; exact fun c hc _ => hc)
        intro c hc hw; simp only at hc; rw [b3] at hc; simp at hc; rcases hc with hc | rfl
        · exact hc
        · simp [CPc.waitTok] at hw
    · exact h
  | connSave k =>
    simp only [step]; split
    · split
      · refine noOrphan_frame (erC k) (Or.inl rfl) (fun c hc _ => hc) ?_ (fun j hj _ => hj)
        intro c hc hw; simp at hc; rcases hc with hc | rfl
        · exact hc
        · simp [CPc.waitTok] at hw
      · exact erC k
    · exact h
  | connFull k =>
    simp only [step]; split
    · refine noOrphan_frame (erC k) (Or.inl rfl) (fun c hc _ => hc) (fun c hc _ => hc) ?_
      intro j hj hw; simp [flushSync] at hj; rcases hj with hj | rfl
      · exact hj
      · simp [Job.waitTok] at hw
    · exact h
  | signOut =>
    simp only [step]; split
    · exact h
    · exact same _ rfl rfl rfl rfl
  | poll wf =>
    simp only [step]; split
    · exact h
    · split
      · refine noOrphan_frame h (Or.inl rfl) (fun c hc _ => hc) (fun c hc _ => hc) ?_
        intro j hj hw; simp [flushSync] at hj; rcases hj with hj | rfl
        · exact hj
        · simp [Job.waitTok] at hw
      · exact noOrphan_pullSync h
  | visible =>
    simp only [step]; split
    · refine noOrphan_frame h (Or.inl rfl) (fun c hc _ => hc) (fun c hc _ => hc) ?_
      intro j hj hw; simp [flushSync] at hj; rcases hj with hj | rfl
      · exact hj
      · simp [Job.waitTok] at hw
    · exact h
  | callPull =>
    simp only [step]; split
    · exact noOrphan_pullSync (same _ rfl rfl rfl rfl)
    · exact h
  | jobStart p =>
    simp only [step]; split
    · split
      · exact noOrphan_finish h _
      · exact noOrphan_send_setHead h _ rfl
    · split
      · exact noOrphan_frame h (Or.inl rfl) (fun c hc _ => hc) (fun c hc _ => hc)
          (fun j hj _ => List.mem_of_mem_tail hj)
      · exact noOrphan_send_setHead (same { s with pullQueued := false } rfl rfl rfl rfl) _ rfl
    · exact h
  | preludeOk k =>
    simp only [step]; split
    · split
      · exact noOrphan_finish h _
      · split
        · exact noOrphan_libSend_setHead h _ rfl _
        · exact noOrphan_send_setHead h _ rfl
    · exact h
  | upOk =>
    simp only [step]; split
    · split
      · exact noOrphan_finish h _
      · split
        · exact noOrphan_libSend_setHead h _ rfl _
        · exact noOrphan_send_setHead h _ rfl
    · exact h
  | up401 act =>
    simp only [step]; split
    · split
      · exact noOrphan_req (by simp only [setHead]; exact joinOrCreate_req s s.email)
      · exact noOrphan_finish (noOrphan_arm (same { s with token := none } rfl rfl rfl rfl)) _
    · exact h
  | reauthRes =>
    simp only [step]; split
    · split
      · exact noOrphan_finish (noOrphan_arm (same { s with token := none } rfl rfl rfl rfl)) _
      · split
        · exact noOrphan_finish h _
        · exact noOrphan_send_setHead h _ rfl
    · exact h
  | libDone =>
    simp only [step]; split
    · exact noOrphan_finish h _
    · exact h
  | jobFail =>
    simp only [step]; split
    all_goals first
      | exact h
      | exact noOrphan_finish h _
  | pullDone clr =>
    simp only [step]; split
    · split
      · obtain ⟨b1, b2, b3, b4⟩ := arm_f { s with token := none }
        exact noOrphan_frame h (Or.inl (by simp only [popHead]; rw [b1]))
          (by simp only [popHead]; rw [b2]; exact fun c hc _ => hc)
          (by simp only [popHead]; rw [b3]; exact fun c hc _ => hc)
          (by simp only [popHead]; rw [b4]; exact fun j hj _ => List.mem_of_mem_tail hj)
      · exact noOrphan_frame h (Or.inl rfl) (fun c hc _ => hc) (fun c hc _ => hc)
          (fun j hj _ => List.mem_of_mem_tail hj)
    · exact h

/-- **No orphaned token caller**: whoever is awaiting a token has the one
request in flight to wait on (gdriveTokenInFlight). -/
theorem no_orphaned_token_waiter {s : St} (h : Reachable s) : NoOrphan s := by
  induction h with
  | init => intro _; simp [init]
  | step e _ ih => exact noOrphan_step _ e ih

/-! ### Proved: a signed-out tab sends nothing, and no library crosses accounts

The two properties the sign-out findings broke, now proved over every
interleaving (they supersede the old `quiet_signOut_final`, which needed
nothing in flight at the click): `send_only_signed_in` (no Drive request
leaves with a live token while the tab is signed out and no sign-in is
running) and `no_cross_account` (a flush never writes the library it
captured under one account into another account's Drive). -/

def FPc.ownEp : FPc → Option (Nat × Nat)
  | .start => none
  | .prelude o ep => some (o, ep)
  | .upload o ep _ => some (o, ep)
  | .reauth o ep _ _ => some (o, ep)
  | .libWrite o ep => some (o, ep)

/-- A started flush's account and session. -/
def Job.ownEp : Job → Option (Nat × Nat)
  | .flush pc _ => pc.ownEp
  | .pull _ => none

def CPc.holds (b : Nat) (c : CPc) : Prop := c = .acq (some true) ∨ c = .email (some b)

structure Safe (s : St) : Prop where
  /-- linked means the hint names the loaded account -/
  email : s.connected = true → s.email = some s.acct
  reqLe : ∀ h e, s.req = some (h, e) → e ≤ s.epoch
  /-- a request of the current linked session asks for the loaded account -/
  req : ∀ h e, s.req = some (h, e) → e = s.epoch → s.connected = true → h = some s.acct
  /-- a linked tab's token is the loaded account's, unless a sign-in holding
  it is still finding out whose it is -/
  tok : ∀ b, s.token = some b → b ≠ s.acct → s.connected = true →
          ∃ c ∈ s.connects, CPc.holds b c
  jobLe : ∀ j ∈ s.chain, ∀ o ep, j.ownEp = some (o, ep) → ep ≤ s.epoch
  /-- a started flush still in its session is linked, and its account's token (or none) is live -/
  job : ∀ j ∈ s.chain, ∀ o ep, j.ownEp = some (o, ep) → ep = s.epoch →
          s.connected = true ∧ o = s.acct ∧ (s.token = none ∨ s.token = some o)
  out : s.outTraffic = false
  cross : s.crossLib = false

theorem safe_init : Safe init := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, rfl, rfl⟩ <;> simp [init]

theorem mem_eraseIdx_or {α : Type} : ∀ (l : List α) (k : Nat) {x c : α}, l[k]? = some x → c ∈ l →
    c ∈ l.eraseIdx k ∨ c = x := by
  intro l
  induction l with
  | nil => intro k x c _ hc; simp at hc
  | cons y ys ih =>
    intro k x c hk hc
    cases k with
    | zero =>
      simp at hk; subst hk
      simp only [List.eraseIdx_cons_zero]
      rcases List.mem_cons.1 hc with rfl | h
      · exact Or.inr rfl
      · exact Or.inl h
    | succ k =>
      simp only [List.eraseIdx_cons_succ, List.mem_cons]
      simp only [List.getElem?_cons_succ] at hk
      rcases List.mem_cons.1 hc with rfl | h
      · exact Or.inl (Or.inl rfl)
      · rcases ih k hk h with h' | h'
        · exact Or.inl (Or.inr h')
        · exact Or.inr h'

/-- The frame: the session, the account, the request and the connects'
token-holders unchanged; the token unchanged or dropped; started flushes only
ones that were there. -/
theorem safe_frame {s s' : St} (h : Safe s) (hc : s'.connected = s.connected) (he : s'.email = s.email)
    (ha : s'.acct = s.acct) (hep : s'.epoch = s.epoch) (hreq : s'.req = s.req)
    (ht : s'.token = s.token ∨ s'.token = none)
    (hcn : ∀ b, ∀ c ∈ s.connects, CPc.holds b c → c ∈ s'.connects)
    (hj : ∀ j ∈ s'.chain, ∀ o ep, j.ownEp = some (o, ep) → ∃ j' ∈ s.chain, j'.ownEp = some (o, ep))
    (ho : s'.outTraffic = s.outTraffic) (hx : s'.crossLib = s.crossLib) : Safe s' := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro c; rw [he, ha]; exact h1 (hc ▸ c)
  · intro x e hr; rw [hep]; exact h2 x e (hreq ▸ hr)
  · intro x e hr hee hcc; rw [ha]; exact h3 x e (hreq ▸ hr) (hep ▸ hee) (hc ▸ hcc)
  · intro b hb hne hcc
    rcases ht with ht | ht
    · rw [ht] at hb
      obtain ⟨c, hcm, hch⟩ := h4 b hb (ha ▸ hne) (hc ▸ hcc)
      exact ⟨c, hcn b c hcm hch, hch⟩
    · rw [ht] at hb; cases hb
  · intro j hjm o ep hown
    obtain ⟨j', hj', hown'⟩ := hj j hjm o ep hown
    rw [hep]; exact h5 j' hj' o ep hown'
  · intro j hjm o ep hown hee
    obtain ⟨j', hj', hown'⟩ := hj j hjm o ep hown
    obtain ⟨a1, a2, a3⟩ := h6 j' hj' o ep hown' (hep ▸ hee)
    refine ⟨hc ▸ a1, ha ▸ a2, ?_⟩
    rcases ht with ht | ht
    · rw [ht]; exact a3
    · left; exact ht
  · rw [ho]; exact h7
  · rw [hx]; exact h8

theorem hj_same {s : St} : ∀ j ∈ s.chain, ∀ o ep, j.ownEp = some (o, ep) → ∃ j' ∈ s.chain, j'.ownEp = some (o, ep) :=
  fun j hj _ _ h => ⟨j, hj, h⟩
theorem hcn_same {s : St} : ∀ b, ∀ c ∈ s.connects, CPc.holds b c → c ∈ s.connects := fun _ _ h _ => h

theorem safe_arm {s : St} (h : Safe s) : Safe (arm s) := by
  unfold arm; split
  · exact h
  · exact safe_frame h rfl rfl rfl rfl rfl (Or.inl rfl) hcn_same hj_same rfl rfl

theorem safe_clear {s : St} (h : Safe s) : Safe { s with token := none } :=
  safe_frame h rfl rfl rfl rfl rfl (Or.inr rfl) hcn_same hj_same rfl rfl

theorem hj_tail {s : St} : ∀ j ∈ s.chain.tail, ∀ o ep, j.ownEp = some (o, ep) → ∃ j' ∈ s.chain, j'.ownEp = some (o, ep) :=
  fun j hj _ _ h => ⟨j, List.mem_of_mem_tail hj, h⟩

theorem safe_popHead {s : St} (h : Safe s) : Safe (popHead s) :=
  safe_frame h rfl rfl rfl rfl rfl (Or.inl rfl) hcn_same hj_tail rfl rfl

theorem safe_finish {s : St} (h : Safe s) (a : Bool) : Safe (finish s a) := by
  unfold finish; split
  · exact safe_frame h rfl rfl rfl rfl rfl (Or.inl rfl) hcn_same hj_tail rfl rfl
  · exact safe_popHead h

theorem safe_append {s : St} (h : Safe s) (j : Job) (hj : j.ownEp = none) :
    Safe { s with chain := s.chain ++ [j] } := by
  refine safe_frame h rfl rfl rfl rfl rfl (Or.inl rfl) hcn_same ?_ rfl rfl
  intro j' hj' o ep hown
  simp only [List.mem_append, List.mem_singleton] at hj'
  rcases hj' with hj' | rfl
  · exact ⟨j', hj', hown⟩
  · rw [hj] at hown; cases hown

theorem safe_flushSync {s : St} (h : Safe s) (a : Bool) : Safe (flushSync s a) :=
  safe_append h _ rfl

theorem safe_pullSync {s : St} (h : Safe s) : Safe (pullSync s) := by
  unfold pullSync; split
  · exact h
  · have := safe_append (s := { s with pullQueued := true }) (safe_frame h rfl rfl rfl rfl rfl (Or.inl rfl)
      hcn_same hj_same rfl rfl) (.pull false) rfl
    exact this

/-- Replacing the head by a job of the same started flush. -/
theorem safe_setHead_same {s : St} (h : Safe s) (j : Job) (j0 : Job) (hj0 : s.chain.head? = some j0)
    (hown : j.ownEp = j0.ownEp) : Safe (setHead s j) := by
  refine safe_frame h rfl rfl rfl rfl rfl (Or.inl rfl) hcn_same ?_ rfl rfl
  intro x hx o ep hx'
  simp only [setHead, List.mem_cons] at hx
  rcases hx with rfl | hx
  · refine ⟨j0, ?_, hown ▸ hx'⟩
    cases hc : s.chain with
    | nil => rw [hc] at hj0; cases hj0
    | cons y ys => rw [hc] at hj0; simp at hj0; subst hj0; simp
  · exact ⟨x, List.mem_of_mem_tail hx, hx'⟩

/-- A send from a linked tab sets no ghost. -/
theorem safe_send {s : St} (h : Safe s) (hc : s.connected = true) : Safe (send s) := by
  unfold send; split
  · rename_i hh; simp [hc] at hh
  · exact h

theorem send_fields (s : St) : (send s).connected = s.connected ∧ (send s).token = s.token ∧
    (send s).crossLib = s.crossLib ∧ (send s).chain = s.chain := by
  unfold send; split <;> simp

/-- The library write of a flush whose account's token (or none) is live. -/
theorem safe_libSend {s : St} (h : Safe s) (hc : s.connected = true) (o : Nat)
    (ho : s.token = none ∨ s.token = some o) : Safe (libSend s o) := by
  have hs := safe_send h hc
  obtain ⟨_, ht, _, _⟩ := send_fields s
  unfold libSend; simp only
  split
  · rename_i b hb
    split
    · exact hs
    · rename_i hne
      rw [ht] at hb
      rcases ho with ho | ho <;> rw [ho] at hb <;> simp at hb
      exact absurd hb.symm hne
  · exact hs

/-- The chain head, if it is a started flush in the current session, may send. -/
theorem head_ok {s : St} (h : Safe s) (j : Job) (rest : List Job) (hc : s.chain = j :: rest) (o ep : Nat)
    (hown : j.ownEp = some (o, ep)) (hep : ep = s.epoch) :
    s.connected = true ∧ o = s.acct ∧ (s.token = none ∨ s.token = some o) :=
  h.job j (by rw [hc]; simp) o ep hown hep

theorem ident_of_holds {b : Nat} {c : CPc} (h : CPc.holds b c) : c.ident = true := by
  rcases h with rfl | rfl <;> rfl

/-- **syncActive means the loaded account's token.** -/
theorem active_token {s : St} (h : Safe s) (ha : syncActive s = true) : s.token = some s.acct := by
  simp only [syncActive, Bool.and_eq_true, Bool.not_eq_true'] at ha
  obtain ⟨⟨ht, hc⟩, hi⟩ := ha
  obtain ⟨b, hb⟩ := Option.isSome_iff_exists.1 ht
  rw [hb]
  by_cases hne : b = s.acct
  · rw [hne]
  · obtain ⟨c, hcm, hch⟩ := h.tok b hb hne hc
    have : identifying s = true := List.any_eq_true.2 ⟨c, hcm, ident_of_holds hch⟩
    rw [this] at hi; cases hi

theorem fetchEmail_cases (s : St) (t : Option Nat) (ok : Bool) :
    fetchEmail s t ok = s ∨
    ∃ a, s.token = some a ∧ fetchEmail s t ok =
      (if s.acct = a then { s with email := some a }
       else { s with email := some a, acct := a, epoch := s.epoch + 1 }) := by
  unfold fetchEmail
  split
  · rename_i a
    split
    · rename_i ht; exact Or.inr ⟨a, ht, rfl⟩
    · exact Or.inl rfl
  · exact Or.inl rfl

/-- adoptDriveAccount after tokeninfo named the token's account. -/
theorem safe_fetchEmail {s : St} (h : Safe s) (t : Option Nat) (ok : Bool) : Safe (fetchEmail s t ok) := by
  rcases fetchEmail_cases s t ok with e | ⟨a, ht, e⟩
  · rw [e]; exact h
  rw [e]
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  split
  · rename_i hacct
    refine ⟨?_, h2, ?_, ?_, h5, h6, h7, h8⟩
    · intro _; simp [hacct]
    · intro x e hr hee hcc; exact h3 x e hr hee hcc
    · intro b hb hne hcc; exact h4 b hb hne hcc
  · rename_i hacct
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, h7, h8⟩
    · intro _; rfl
    · intro x e hr; exact Nat.le_succ_of_le (h2 x e hr)
    · intro x e hr hee; have := h2 x e hr; simp only at hee; omega
    · intro b hb hne; simp only at hb hne; rw [ht] at hb; cases hb; exact absurd rfl hne
    · intro j hj o ep hown; exact Nat.le_succ_of_le (h5 j hj o ep hown)
    · intro j hj o ep hown hee; have := h5 j hj o ep hown; simp only at hee; omega

theorem connects_stampC (l : List CPc) (r : Bool) (b : Nat) :
    ∀ c ∈ l, CPc.holds b c → c ∈ l.map (stampC r) := by
  intro c hc hh
  rcases hh with rfl | rfl
  · exact List.mem_map.2 ⟨_, hc, rfl⟩
  · exact List.mem_map.2 ⟨_, hc, rfl⟩

theorem ownEp_stampJ (r : Bool) (j : Job) : (stampJ r j).ownEp = j.ownEp := by
  rcases j with ⟨pc, a⟩ | ⟨b⟩
  · cases pc with
    | reauth o ep k res => cases res <;> rfl
    | _ => rfl
  · rfl

theorem chain_stampJ (s : St) (r : Bool) : ∀ j ∈ s.chain.map (stampJ r), ∀ o ep,
    j.ownEp = some (o, ep) → ∃ j' ∈ s.chain, j'.ownEp = some (o, ep) := by
  intro j hj o ep hown
  obtain ⟨j', hj', rfl⟩ := List.mem_map.1 hj
  exact ⟨j', hj', by rw [← ownEp_stampJ r]; exact hown⟩

theorem safe_settle {s : St} (h : Safe s) (r : Bool) : Safe (settle s r) := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  refine ⟨h1, ?_, ?_, ?_, ?_, ?_, h7, h8⟩
  · intro x e hr; simp [settle] at hr
  · intro x e hr; simp [settle] at hr
  · intro b hb hne hcc
    obtain ⟨c, hcm, hch⟩ := h4 b hb hne hcc
    exact ⟨c, connects_stampC _ r b c hcm hch, hch⟩
  · intro j hj o ep hown
    obtain ⟨j', hj', hown'⟩ := chain_stampJ s r j hj o ep hown
    exact h5 j' hj' o ep hown'
  · intro j hj o ep hown hee
    obtain ⟨j', hj', hown'⟩ := chain_stampJ s r j hj o ep hown
    exact h6 j' hj' o ep hown' hee

theorem safe_joinOrCreate {s : St} (h : Safe s) (hc : s.connected = true) :
    Safe (joinOrCreate s s.email) := by
  unfold joinOrCreate; split
  · exact h
  · rename_i hn
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
    refine ⟨h1, ?_, ?_, h4, h5, h6, h7, h8⟩
    · intro x e hr; simp at hr ⊢; omega
    · intro x e hr _ _; simp at hr; rw [← hr.1]; exact h1 hc


/-- The frame with the token dropped: nothing about the connects is needed. -/
theorem safe_frame_cleared {s s' : St} (h : Safe s) (hc : s'.connected = s.connected)
    (he : s'.email = s.email) (ha : s'.acct = s.acct) (hep : s'.epoch = s.epoch) (hreq : s'.req = s.req)
    (ht : s'.token = none)
    (hj : ∀ j ∈ s'.chain, ∀ o ep, j.ownEp = some (o, ep) → ∃ j' ∈ s.chain, j'.ownEp = some (o, ep))
    (ho : s'.outTraffic = s.outTraffic) (hx : s'.crossLib = s.crossLib) : Safe s' := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro c; rw [he, ha]; exact h1 (hc ▸ c)
  · intro x e hr; rw [hep]; exact h2 x e (hreq ▸ hr)
  · intro x e hr hee hcc; rw [ha]; exact h3 x e (hreq ▸ hr) (hep ▸ hee) (hc ▸ hcc)
  · intro b hb; rw [ht] at hb; cases hb
  · intro j hjm o ep hown
    obtain ⟨j', hj', hown'⟩ := hj j hjm o ep hown
    rw [hep]; exact h5 j' hj' o ep hown'
  · intro j hjm o ep hown hee
    obtain ⟨j', hj', hown'⟩ := hj j hjm o ep hown
    obtain ⟨a1, a2, _⟩ := h6 j' hj' o ep hown' (hep ▸ hee)
    exact ⟨hc ▸ a1, ha ▸ a2, Or.inl ht⟩
  · rw [ho]; exact h7
  · rw [hx]; exact h8

/-- A new chain head that is fine where it stands. -/
theorem safe_setHead_new {s : St} (h : Safe s) (j : Job) (hj : ∀ o ep, j.ownEp = some (o, ep) →
    ep ≤ s.epoch ∧ (ep = s.epoch → s.connected = true ∧ o = s.acct ∧ (s.token = none ∨ s.token = some o))) :
    Safe (setHead s j) := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  refine ⟨h1, h2, h3, h4, ?_, ?_, h7, h8⟩
  · intro x hx o ep hown
    simp only [setHead, List.mem_cons] at hx
    rcases hx with rfl | hx
    · exact (hj o ep hown).1
    · exact h5 x (List.mem_of_mem_tail hx) o ep hown
  · intro x hx o ep hown hee
    simp only [setHead, List.mem_cons] at hx
    rcases hx with rfl | hx
    · exact (hj o ep hown).2 hee
    · exact h6 x (List.mem_of_mem_tail hx) o ep hown hee

/-- The linked state a sign-in reaches once tokeninfo named the token's account. -/
theorem safe_signed_in (s0 : St) (a : Nat) (ht : s0.token = some a)
    (h2 : ∀ h e, s0.req = some (h, e) → e ≤ s0.epoch)
    (h5 : ∀ j ∈ s0.chain, ∀ o ep, j.ownEp = some (o, ep) → ep ≤ s0.epoch)
    (h7 : s0.outTraffic = false) (h8 : s0.crossLib = false) :
    Safe (let s1 := fetchEmail s0 (some a) true
          { s1 with fails := 0, connected := true, epoch := s1.epoch + 1,
                    connects := s1.connects ++ [.save] }) := by
  simp only [fetchEmail, ht, ite_true]
  split
  · rename_i hacct
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, h7, h8⟩
    · intro _; simp [hacct]
    · intro x e hr; exact Nat.le_succ_of_le (h2 x e hr)
    · intro x e hr hee; have := h2 x e hr; simp only at hee; omega
    · intro b hb hne; simp only at hb hne; cases hb; exact absurd hacct.symm hne
    · intro j hj o ep hown; exact Nat.le_succ_of_le (h5 j hj o ep hown)
    · intro j hj o ep hown hee; have := h5 j hj o ep hown; simp only at hee; omega
  · refine ⟨?_, ?_, ?_, ?_, ?_, ?_, h7, h8⟩
    · intro _; rfl
    · intro x e hr; exact Nat.le_succ_of_le (Nat.le_succ_of_le (h2 x e hr))
    · intro x e hr hee; have := h2 x e hr; simp only at hee; omega
    · intro b hb hne; simp only at hb hne; cases hb; exact absurd rfl hne
    · intro j hj o ep hown; exact Nat.le_succ_of_le (Nat.le_succ_of_le (h5 j hj o ep hown))
    · intro j hj o ep hown hee; have := h5 j hj o ep hown; simp only at hee; omega

/-- The flush head moves on in its session: the same flush, and it may send. -/
theorem safe_flush_next {s : St} (h : Safe s) (pc : FPc) (after : Bool) (rest : List Job)
    (hc : s.chain = .flush pc after :: rest) (o ep : Nat) (hown : pc.ownEp = some (o, ep))
    (hep : ep = s.epoch) (pc' : FPc) (hown' : pc'.ownEp = some (o, ep)) (k : Nat) :
    Safe (if k = 0 then libSend (setHead s (.flush (.libWrite o ep) after)) o
          else send (setHead s (.flush pc' after))) := by
  obtain ⟨hcon, _, htok⟩ := head_ok h (.flush pc after) rest hc o ep hown hep
  split
  · exact safe_libSend (safe_setHead_same h _ (.flush pc after) (by simp [hc]) (by simp only [Job.ownEp]; rw [hown]; rfl))
      hcon o htok
  · exact safe_send (safe_setHead_same h _ (.flush pc after) (by simp [hc]) (by simp only [Job.ownEp]; rw [hown, hown']))
      hcon

theorem safe_step (s : St) (e : Ev) (h : Safe s) : Safe (step s e) := by
  have fr : ∀ s' : St, s'.connected = s.connected → s'.email = s.email → s'.acct = s.acct →
      s'.epoch = s.epoch → s'.req = s.req → s'.token = s.token → s'.connects = s.connects →
      s'.chain = s.chain → s'.outTraffic = s.outTraffic → s'.crossLib = s.crossLib → Safe s' := by
    intro s' a b c d e f g i j k
    exact safe_frame h a b c d e (Or.inl f) (by rw [g]; exact hcn_same) (by rw [i]; exact hj_same) j k
  have erR : ∀ k, Safe { s with renews := s.renews.eraseIdx k } :=
    fun k => fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  -- a connect erased that was not holding the token
  have erC : ∀ k x, s.connects[k]? = some x → (∀ b, ¬ CPc.holds b x) →
      Safe { s with connects := s.connects.eraseIdx k } := by
    intro k x hk hx
    refine safe_frame h rfl rfl rfl rfl rfl (Or.inl rfl) ?_ hj_same rfl rfl
    intro b c hcm hch
    rcases mem_eraseIdx_or s.connects k hk hcm with hm | rfl
    · exact hm
    · exact absurd hch (hx b)
  cases e with
  | gesture on =>
    simp only [step]; split
    · unfold renewCall; simp only; split
      · exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
      · split
        · exact safe_arm (fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
        · exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
    · exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  | arm => exact safe_arm h
  | renewGis k ok act =>
    simp only [step]; split
    · split
      · exact safe_arm (erR k)
      · split
        · exact erR k
        · split
          · exact safe_arm (erR k)
          · rename_i hne _
            have hc : s.connected = true := by
              cases hcs : s.connected
              · simp [hcs] at hne
              · rfl
            have hj := safe_joinOrCreate (erR k) hc
            exact safe_frame hj rfl rfl rfl rfl rfl (Or.inl rfl) hcn_same hj_same rfl rfl
    · exact h
  | renewAcq k =>
    simp only [step]; split
    · split
      · exact erR k
      · split
        · split
          · exact safe_clear (fr { s with renews := s.renews.eraseIdx k, fails := s.fails + 1 } rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
          · exact safe_arm (fr { s with renews := s.renews.eraseIdx k, fails := s.fails + 1 } rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
        · split
          · exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
          · exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
    · exact h
  | renewEmail k ok =>
    simp only [step]; split
    · rename_i t ep _
      have hF := safe_fetchEmail (erR k) t ok
      split
      · exact hF
      · exact safe_pullSync hF
    · exact h
  | tokGrant a =>
    simp only [step]; split
    · rename_i hh ee hreq
      split
      · rename_i hha
        split
        · -- a sign-in waits on the request: a new session, whichever account
          rename_i hw
          have hmem : CPc.acq none ∈ s.connects := by simpa [connectWaits] using hw
          have hS := safe_settle h true
          obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := hS
          refine ⟨h1, ?_, ?_, ?_, ?_, ?_, h7, h8⟩
          · intro x e hr; simp [settle] at hr
          · intro x e hr; simp [settle] at hr
          · intro b hb _ _
            simp only at hb; cases hb
            refine ⟨.acq (some true), ?_, Or.inl rfl⟩
            simp only [settle]
            exact List.mem_map.2 ⟨.acq none, hmem, rfl⟩
          · intro j hj o ep hown; have := h5 j hj o ep hown; simp [settle] at this ⊢; omega
          · intro j hj o ep hown hee; have := h5 j hj o ep hown; simp [settle] at this hee; omega
        · split
          · -- the linked session that asked: the hinted account
            rename_i hce
            simp only [Bool.and_eq_true, beq_iff_eq] at hce
            have hacct : hh = some s.acct := h.req hh ee hreq hce.2 hce.1
            have ha : a = s.acct := by
              have : hh = none ∨ hh = some a := by simpa using hha
              rcases this with h0 | h0
              · rw [h0] at hacct; cases hacct
              · rw [h0] at hacct; simpa using hacct
            have hS := safe_settle h true
            obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := hS
            refine ⟨h1, h2, h3, ?_, h5, ?_, h7, h8⟩
            · intro b hb hne _; simp only at hb; cases hb; simp [settle] at hne; exact absurd ha hne
            · intro j hj o ep hown hee
              obtain ⟨a1, a2, _⟩ := h6 j hj o ep hown hee
              refine ⟨a1, a2, Or.inr ?_⟩
              simp only [settle] at a2 ⊢
              rw [ha, a2]
          · exact safe_settle h false
      · exact h
    · exact h
  | tokDeny =>
    simp only [step]; split
    · exact safe_frame (safe_settle h false) rfl rfl rfl rfl rfl (Or.inl rfl) hcn_same hj_same rfl rfl
    · exact h
  | signIn =>
    simp only [step]; split
    · exact h
    · rename_i hc
      have hcf : s.connected = false := by simpa using hc
      have hj : Safe (joinOrCreate s s.email) := by
        unfold joinOrCreate; split
        · exact h
        · obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
          refine ⟨h1, ?_, ?_, h4, h5, h6, h7, h8⟩
          · intro x e hr; simp at hr ⊢; omega
          · intro x e hr _ hcc; simp only at hcc; rw [hcf] at hcc; cases hcc
      refine safe_frame hj rfl rfl rfl rfl rfl (Or.inl rfl) ?_ hj_same rfl rfl
      intro b c hc _; simp only [List.mem_append]; exact Or.inl hc
  | connAcq k =>
    simp only [step]; split
    · rename_i r hk
      split
      · -- the token moves with the connect into its tokeninfo stage
        obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
        refine ⟨h1, h2, h3, ?_, h5, h6, h7, h8⟩
        intro b hb hne hcc
        obtain ⟨c, hcm, hch⟩ := h4 b hb hne hcc
        rcases mem_eraseIdx_or s.connects k hk hcm with hm | rfl
        · exact ⟨c, by simp [hm], hch⟩
        · refine ⟨.email s.token, by simp, ?_⟩
          right; simp only at hb; rw [hb]
      · rename_i hr
        refine safe_frame h rfl rfl rfl rfl rfl (Or.inl rfl) ?_ hj_same rfl rfl
        intro b c hcm hch
        rcases mem_eraseIdx_or s.connects k hk hcm with hm | rfl
        · exact hm
        · rcases hch with hch | hch <;> simp at hch
          subst hch; simp at hr
    · exact h
  | connEmail k ok =>
    simp only [step]; split
    · rename_i t hk
      split
      · exact safe_frame_cleared h rfl rfl rfl rfl rfl rfl hj_same rfl rfl
      · rename_i hid
        have hid' : identified { s with connects := s.connects.eraseIdx k } t ok = true := by
          simpa using hid
        obtain ⟨a, rfl, rfl, htok⟩ : ∃ a, t = some a ∧ ok = true ∧ s.token = some a := by
          unfold identified at hid'; split at hid'
          · rename_i a; exact ⟨a, rfl, rfl, by simpa using hid'⟩
          · cases hid'
        exact safe_signed_in { s with connects := s.connects.eraseIdx k } a htok h.reqLe h.jobLe h.out h.cross
    · exact h
  | connSave k =>
    simp only [step]; split
    · rename_i hk
      have hE := erC k .save hk (fun b hb => by rcases hb with hb | hb <;> cases hb)
      split
      · refine safe_frame hE rfl rfl rfl rfl rfl (Or.inl rfl) ?_ hj_same rfl rfl
        intro b c hc _; simp only [List.mem_append]; exact Or.inl hc
      · exact hE
    · exact h
  | connFull k =>
    simp only [step]; split
    · rename_i hk
      exact safe_flushSync (erC k .full hk (fun b hb => by rcases hb with hb | hb <;> cases hb)) _
    · exact h
  | signOut =>
    simp only [step]; split
    · exact h
    · obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
      refine ⟨?_, ?_, ?_, ?_, ?_, ?_, h7, h8⟩
      · intro hc; cases hc
      · intro x e hr; exact Nat.le_succ_of_le (h2 x e hr)
      · intro x e hr _ hc; cases hc
      · intro b hb; cases hb
      · intro j hj o ep hown; exact Nat.le_succ_of_le (h5 j hj o ep hown)
      · intro j hj o ep hown hee; have := h5 j hj o ep hown; simp only at hee; omega
  | poll wf =>
    simp only [step]; split
    · exact h
    · split
      · exact safe_flushSync h _
      · exact safe_pullSync h
  | visible =>
    simp only [step]; split
    · exact safe_flushSync h _
    · exact h
  | callPull =>
    simp only [step]; split
    · exact safe_pullSync (fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
    · exact h
  | jobStart p =>
    simp only [step]; split
    · rename_i after rest hc
      split
      · exact safe_finish h _
      · rename_i hact
        have ha : syncActive s = true := by
          cases hs : syncActive s
          · simp [hs] at hact
          · rfl
        have htok := active_token h ha
        have hcon : s.connected = true := by
          simp only [syncActive, Bool.and_eq_true] at ha; exact ha.1.2
        refine safe_send (s := setHead s (.flush (.prelude s.acct s.epoch) after)) ?_ hcon
        apply safe_setHead_new h
        intro o ep hown
        simp only [Job.ownEp, FPc.ownEp, Option.some.injEq, Prod.mk.injEq] at hown
        obtain ⟨rfl, rfl⟩ := hown
        exact ⟨Nat.le_refl _, fun _ => ⟨hcon, rfl, Or.inr htok⟩⟩
    · rename_i rest hc
      split
      · exact safe_popHead (fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
      · rename_i hact
        have hcon : s.connected = true := by
          cases hs : syncActive { s with pullQueued := false }
          · simp [hs] at hact
          · simp only [syncActive, Bool.and_eq_true] at hs; exact hs.1.2
        refine safe_send (s := setHead { s with pullQueued := false } (.pull true)) ?_ hcon
        exact safe_setHead_same (fr { s with pullQueued := false } rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
          (.pull true) (.pull false) (by simp [hc]) rfl
    · exact h
  | preludeOk k =>
    simp only [step]; split
    · rename_i o ep after rest hc
      split
      · exact safe_finish h _
      · rename_i hep
        have hep' : ep = s.epoch := by simpa using hep
        exact safe_flush_next h (.prelude o ep) after rest hc o ep rfl hep' (.upload o ep (k - 1)) rfl k
    · exact h
  | upOk =>
    simp only [step]; split
    · rename_i o ep k after rest hc
      split
      · exact safe_finish h _
      · rename_i hep
        have hep' : ep = s.epoch := by simpa using hep
        exact safe_flush_next h (.upload o ep k) after rest hc o ep rfl hep' (.upload o ep (k - 1)) rfl k
    · exact h
  | up401 act =>
    simp only [step]; split
    · rename_i o ep k after rest hc
      split
      · rename_i hac
        have hcon : s.connected = true := by
          cases hcs : s.connected
          · simp [hcs] at hac
          · rfl
        exact safe_setHead_same (safe_joinOrCreate h hcon) _ (.flush (.upload o ep k) after)
          (by unfold joinOrCreate; split <;> simp [hc]) rfl
      · exact safe_finish (safe_arm (safe_clear h)) _
    · exact h
  | reauthRes =>
    simp only [step]; split
    · rename_i o ep k r after rest hc
      split
      · exact safe_finish (safe_arm (safe_clear h)) _
      · split
        · exact safe_finish h _
        · rename_i hep
          have hep' : ep = s.epoch := by simpa using hep
          obtain ⟨hcon, _, _⟩ := head_ok h _ rest hc o ep rfl hep'
          exact safe_send (safe_setHead_same h _ (.flush (.reauth o ep k (some r)) after)
            (by simp [hc]) rfl) hcon
    · exact h
  | libDone =>
    simp only [step]; split
    · exact safe_finish h _
    · exact h
  | jobFail =>
    simp only [step]; split
    all_goals first
      | exact h
      | exact safe_finish h _
  | pullDone clr =>
    simp only [step]; split
    · split
      · exact safe_popHead (safe_arm (safe_clear h))
      · exact safe_popHead h
    · exact h

theorem reachable_safe {s : St} (h : Reachable s) : Safe s := by
  induction h with
  | init => exact safe_init
  | step e _ ih => exact safe_step _ e ih

/-- **A signed-out tab sends nothing** (fixes `bug_renewal_resurrects_token`,
`bug_signed_out_tab_keeps_syncing` over every interleaving): no Drive request
ever leaves with a live token while the tab is signed out and no sign-in is
running. -/
theorem send_only_signed_in {s : St} (h : Reachable s) : s.outTraffic = false :=
  (reachable_safe h).out

/-- **No flush writes across accounts** (fixes `bug_flush_crosses_accounts`
over every interleaving): a library captured under one account is never
written to another account's Drive. -/
theorem no_cross_account {s : St} (h : Reachable s) : s.crossLib = false :=
  (reachable_safe h).cross

/-- ...and a linked tab that is syncing holds its own account's token. -/
theorem active_is_own_account {s : St} (h : Reachable s) (ha : syncActive s = true) :
    s.token = some s.acct :=
  active_token (reachable_safe h) ha

end WebState.DriveSession.Session
