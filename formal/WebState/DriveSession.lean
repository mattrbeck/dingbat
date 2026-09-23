/-
# Google Drive sync: the upload queue and the session (web/index.js @ dd7ba741f)

Two sub-models of the one machine, each carrying exactly the state its
properties need.

## `Queue`: the dirty queue, the flusher, the lamp (one account, linked)

JS: `markUpload` (2653), `scheduleFlush` (2645), `flushSync` (2699),
`runExclusive`/`syncChain` (2689-2695), `flushSyncInner` (2706-2825),
`pullSync`/`pullSyncInner` (2912-3062, opaque), `runFullSync` (3064),
`refreshSyncStatus`/`setSyncStatus` (2608-2640), the triggers
`syncPollTick`/`online`/`offline`/`visibilitychange` (3807-3834), and the
save writers that call `markUpload` after their IndexedDB write commits
(`persistSave` 5245-5268, `saveToSlot` 5565-5588).

`flushSyncInner` is split at every await that can matter to the queue:
the prelude (`driveListMap`, `readDriveLibrary`, renames, deletes: one await),
then per queued name `readSyncBytes` (the IndexedDB read itself is an event
`readSnap`, the continuation `readResume` another), `driveUploadFile` (sent
with whatever token is current at send time), the 401 re-grant inside
`driveFetch` (2081-2092), `writeDriveLibrary`, and the final/`catch`
`saveSyncState`.

## `Session`: tokens, connect/sign-out, renewal, accounts

JS: `gdriveAcquireToken` (2011-2045, `gdriveTokenInFlight`),
`gdriveFetchEmail`/`adoptDriveAccount` (2058-2069, 2361-2381),
`gdriveSignOut` (2191-2207), `gdriveConnect` (3654), `armDriveRenewOnGesture`
(3704), `renewDriveToken` (3725-3762), `syncPollTick` (3807), the in-flight
flush seen coarsely (it captures its library at the start and writes it at
the end, 2718 and 2801) and `driveFetch`'s 401 path.

## Abstractions (and why they do not affect the stated properties)

* Queue: only `queueUp` is modelled; `queueDel`/`queueRen` and tombstones/
  renames (another model) are folded into the prelude await and into
  `libPending` (the flush proceeds with an empty `queueUp` when
  `syncState.tomb`/`ren` are non-empty, 2708). `pendingCount()` is
  `queueUp.length`; queued deletes/renames would only make the lamp *more*
  often "syncing".
* Queue: local bytes are a version counter per name (`ver`), Drive's copy is
  the version last uploaded (`drive`); FNV signatures are assumed injective
  and the "already on Drive with this sig" skip (2792) is dropped: skipping
  never re-queues or un-queues anything, it only avoids a request.
  No local deletes (`ver` only grows).
* Queue: pull is opaque: it may run, fail (optionally clearing the token via
  `driveFetch`'s 401 path), and on success may queue a name
  ("reconcile upward", 3019-3028) and flip `libPending`. It does not model
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
  button, 2265, never is).
* Session: the 401 re-grant is modelled on uploads only; a 401 in the prelude
  or the library write is folded into `jobFail`. `resumeDriveOnBoot` is the
  initial state (expired persisted token: arm and wait for a gesture).
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
* `Queue.fix_no_lost_upload` / `fix_quiet_means_synced`: with the proposed
  3-line fix, a key whose Drive copy is stale is always queued (or its
  markUpload is pending).
* `Session.renewals_le_gestures` (+ `only_gesture_renews`,
  `gesture_renews_once`): renewal attempts never outnumber user gestures, so
  token renewal cannot loop by itself.
* `Session.no_orphaned_token_waiter`: one GIS request; every caller awaiting a
  token has it in flight.
* `Session.quiet_signOut_final`: a sign-out with no token request,
  renewal, connect or started Drive job in flight is final until Sign in.

Refuted (concrete traces from the initial state, checked by `decide`):
* `Queue.bug_redirty_dropped`: a save made while its own upload is in flight
  is never uploaded; the lamp says "Synced".
* `Queue.bug_spinner_without_work`, `bug_spinner_after_renewal`: "Syncing"
  spins, with the home Sync button disabled, while nothing is in flight.
* `Session.bug_renewal_resurrects_token` (+ `_rollover`,
  `bug_signed_out_tab_keeps_syncing`): a renewal in flight at Sign out gives
  the signed-out tab a live token and it keeps syncing.
* `Session.bug_flush_crosses_accounts`: a flush running across Sign out +
  Sign in as another account writes the old account's library into the new
  account's Drive.
* `Session.bug_one_popup_two_strikes`: two renewals share one popup and one
  refusal costs two of the three strikes.
-/
namespace WebState.DriveSession

/-- A function update, for version maps. -/
def upd (f : Nat → Nat) (i v : Nat) : Nat → Nat := fun j => if j = i then v else f j

namespace Queue

/-- `syncStatus` (2591). -/
inductive Status where
  | idle | syncing | done | offline | paused
  deriving DecidableEq, Repr

/-- `flushSyncInner`'s program counter (2706). -/
inductive FPc where
  /-- queued behind `syncChain`, body not entered -/
  | start
  /-- awaiting `driveListMap` / `readDriveLibrary` / renames / deletes (2715-2783) -/
  | prelude
  /-- awaiting `readSyncBytes(name)` (2785); `snap` = the IndexedDB read has run and saw it -/
  | read (name : Nat) (rest : List Nat) (snap : Option Nat)
  /-- awaiting `driveUploadFile(name, bytes)` (2793); `withTok`: gdriveToken was non-null at send -/
  | upload (name : Nat) (v : Nat) (withTok : Bool) (rest : List Nat)
  /-- `driveFetch` got 401 with activation: awaiting `gdriveAcquireToken("")` (2084) -/
  | reauth (name : Nat) (v : Nat) (rest : List Nat)
  /-- awaiting `writeDriveLibrary(lib, await driveListMap())` (2801) -/
  | libWrite
  /-- awaiting `saveSyncState()` on success (2815) -/
  | okSave
  /-- in `catch`: `syncBusy = false` done, awaiting `saveSyncState()` (2819-2820) -/
  | failSave
  deriving DecidableEq, Repr

/-- A job on `syncChain`. `after`: the caller chained `.then(() => pullSync(...))`
(poll/online/visible: silent; `runFullSync`: not silent). -/
inductive Job where
  | flush (pc : FPc) (after : Option Bool)
  | pull (started : Bool) (silent : Bool)
  deriving DecidableEq, Repr

/-- `runFullSync` (3064) after its `syncActive()` check. -/
inductive Rfs where
  /-- awaiting `localSyncFiles()` -/
  | listing
  /-- awaiting `saveSyncState()` -/
  | saving
  deriving DecidableEq, Repr

structure St where
  tok        : Bool          -- !!gdriveToken (syncActive, 2382)
  fails      : Nat           -- driveRenewFails (3699)
  ver        : Nat → Nat     -- the bytes under each IndexedDB key, as a version
  drive      : Nat → Nat     -- the version Drive holds for that name
  marks      : List Nat      -- committed writes whose markUpload has not run yet
  queueUp    : List Nat      -- syncState.queueUp
  remarked   : List Nat      -- the proposed fix's Set (only used when fix = true)
  libPending : Bool          -- syncState.tomb.length || syncState.ren.length
  busy       : Bool          -- syncBusy (2300)
  status     : Status        -- syncStatus (2591)
  doneArmed  : Bool          -- syncDoneTimer (2614)
  debounce   : Bool          -- syncTimer (2648)
  cap        : Bool          -- syncCapTimer (2650)
  chain      : List Job      -- syncChain: head runs, the rest wait (runExclusive 2690)
  pullQueued : Bool          -- pullQueued (2696)
  pullCalls  : List Bool     -- pending `.then(() => pullSync(...))` / renewal's pullSync
  rfs        : List Rfs      -- runFullSync calls in flight
  held       : List Nat      -- keys that hold bytes (localSyncFiles)

def init : St :=
  { tok := true, fails := 0, ver := fun _ => 0, drive := fun _ => 0, marks := [],
    queueUp := [], remarked := [], libPending := false, busy := false,
    status := .idle, doneArmed := false, debounce := false, cap := false,
    chain := [], pullQueued := false, pullCalls := [], rfs := [], held := [] }

inductive Ev where
  /-- a save/state/frame write commits (persistSave 5252, saveToSlot 5575) -/
  | write (i : Nat)
  /-- its `markUpload(i)` continuation runs (5263, 5581) -/
  | mark (i : Nat)
  /-- syncTimer / syncCapTimer fire `flushSync` (2648-2650) -/
  | debounce | cap
  /-- syncPollTick (3807) -/
  | poll
  /-- window `online` (3820), `offline` (3825), visibilitychange->visible (3828) -/
  | online | offline | visible
  /-- a Sync button with a live token (3903, 2265): runFullSync -/
  | tap
  /-- runFullSync continuation #k resumes -/
  | rfsStep (k : Nat)
  /-- a token is granted; `pullAfter`: renewDriveToken's wasSignedOut tail (3755-3761) -/
  | tokArrive (pullAfter : Bool)
  /-- some other driveFetch hit 401 with no activation (2083-2087) -/
  | tokLost
  /-- renewDriveToken's catch (3741-3752) -/
  | renewFail
  /-- syncDoneTimer fires (2614) -/
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

/-- setSyncStatus (2608): also (re)arms the "done" -> idle timer. -/
def setStatus (s : St) (x : Status) : St := { s with status := x, doneArmed := x == .done }

/-- refreshSyncStatus (2631-2640), with driveLinked() true. -/
def refresh (s : St) : St :=
  if !s.tok && decide (s.fails ≥ 3) && decide (pending s > 0) then setStatus s .paused
  else if s.busy || decide (pending s > 0) then setStatus s .syncing
  else if s.status == .syncing then setStatus s .done
  else s

/-- scheduleFlush (2645-2652). -/
def scheduleFlush (s : St) : St := refresh { s with debounce := true, cap := true }

/-- markUpload (2653-2659). With `fix`: a name already queued is remembered as re-dirtied. -/
def markUpload (fix : Bool) (s : St) (i : Nat) : St :=
  let s := if i ∈ s.queueUp then (if fix then { s with remarked := i :: s.remarked } else s)
           else { s with queueUp := s.queueUp ++ [i] }
  scheduleFlush s

/-- flushSync (2699-2705): disarm both timers, append to the chain. -/
def flushSync (s : St) (after : Option Bool) : St :=
  { s with debounce := false, cap := false, chain := s.chain ++ [.flush .start after] }

/-- pullSync (2912-2919). -/
def pullSync (s : St) (silent : Bool) : St :=
  if s.pullQueued then s else { s with pullQueued := true, chain := s.chain ++ [.pull false silent] }

def setHead (s : St) (j : Job) : St := { s with chain := j :: s.chain.tail }
def popHead (s : St) : St := { s with chain := s.chain.tail }

/-- the flush's run promise settles; a chained `.then(pullSync)` becomes pending -/
def finish (s : St) (after : Option Bool) : St :=
  match after with
  | some sil => { popHead s with pullCalls := s.pullCalls ++ [sil] }
  | none => popHead s

/-- `catch (e) { syncBusy = false; await saveSyncState(); ... }` (2818-2821) -/
def catchFail (s : St) (after : Option Bool) : St := setHead { s with busy := false } (.flush .failSave after)

/-- next iteration of `for (let name of syncState.queueUp.slice())` (2784), or the library write.
With `fix`, starting an item forgets that it was re-dirtied (`syncRemarked.delete(name)`). -/
def nextItem (fix : Bool) (s : St) (rest : List Nat) (after : Option Bool) : St :=
  match rest with
  | [] => setHead s (.flush .libWrite after)
  | n :: r => setHead { s with remarked := if fix then s.remarked.filter (· != n) else s.remarked }
                (.flush (.read n r none) after)

/-- `syncState.queueUp = syncState.queueUp.filter((n) => n !== name)` (2799).
With `fix`, not if the name was re-dirtied while it was in flight. -/
def dropItem (fix : Bool) (s : St) (n : Nat) : St :=
  if fix && n ∈ s.remarked then s else { s with queueUp := s.queueUp.filter (· != n) }

def step (fix : Bool) (s : St) : Ev → St
  | .write i => { s with ver := upd s.ver i (s.ver i + 1), marks := s.marks ++ [i],
                         held := if i ∈ s.held then s.held else s.held ++ [i] }
  | .mark i => if i ∈ s.marks then markUpload fix { s with marks := s.marks.erase i } i else s
  | .debounce => if s.debounce then flushSync s none else s
  | .cap => if s.cap then flushSync s none else s
  -- syncPollTick (3812-3814): `if (!syncActive()) return; pending ? flush.then(pull) : pull`
  | .poll => if !s.tok then s else if pending s > 0 then flushSync s (some true) else pullSync s true
  -- online (3820-3824)
  | .online => if !s.tok then s else flushSync (refresh s) (some true)
  -- offline (3825-3827)
  | .offline => if pending s > 0 then setStatus s .offline else s
  -- visibilitychange (3832)
  | .visible => if s.tok then flushSync s (some true) else s
  -- runFullSync (3064-3072): `if (!syncActive()) return; await localSyncFiles()`
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
          -- flushSyncInner 2707-2714
          if !s.tok then finish s after
          else if pending s = 0 && !s.libPending then finish (refresh s) after
          else setHead (setStatus { s with busy := true } .syncing) (.flush .prelude after)
      | .pull false sil :: _ =>
          -- pullSync's job 2915-2917, pullSyncInner 2920-2923
          let s := { s with pullQueued := false }
          if !s.tok then popHead s
          else setHead (if sil then { s with busy := true } else setStatus { s with busy := true } .syncing)
                 (.pull true sil)
      | _ => s
  | .preludeOk =>
      match s.chain with
      | .flush .prelude after :: _ => nextItem fix s s.queueUp after
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
          if v = 0 then nextItem fix (dropItem fix s n) r after
          else setHead s (.flush (.upload n v s.tok r) after)
      | _ => s
  | .upOk =>
      match s.chain with
      | .flush (.upload n v true r) after :: _ =>
          -- 2793-2799: Drive has v; sigs[name] = sig; queueUp.filter(name)
          nextItem fix (dropItem fix { s with drive := upd s.drive n v } n) r after
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

inductive Reachable (fix : Bool) : St → Prop
  | init : Reachable fix init
  | step {s} (e : Ev) : Reachable fix s → Reachable fix (step fix s e)

def run (fix : Bool) (s : St) (es : List Ev) : St := es.foldl (step fix) s

theorem reachable_run (fix : Bool) (es : List Ev) : ∀ s, Reachable fix s → Reachable fix (run fix s es) := by
  induction es with
  | nil => intro s h; exact h
  | cons e es ih => intro s h; exact ih _ (Reachable.step e h)

/-! ### Counterexamples (the JS as written: `fix = false`) -/

/-- A second save of the same key lands while its first upload is in flight
(`write 0; mark 0` between `readResume` and `upOk`). markUpload sees the name
still queued and does nothing; the upload's completion then filters the name
out. Every timer fires, the chain drains, the lamp goes "Synced" then idle,
and Drive keeps version 1 of a key whose local bytes are version 2, with
nothing queued. -/
def dropTrace : List Ev :=
  [.write 0, .mark 0, .debounce, .jobStart, .preludeOk, .readSnap, .readResume,
   .write 0, .mark 0,
   .upOk, .libOk, .saveDone, .debounce, .jobStart, .doneTimer]

theorem bug_redirty_dropped :
    let s := run false init dropTrace
    s.ver 0 = 2 ∧ s.drive 0 = 1 ∧ s.queueUp = [] ∧ s.marks = [] ∧ s.chain = [] ∧
    s.debounce = false ∧ s.cap = false ∧ s.pullCalls = [] ∧ s.rfs = [] ∧
    s.status = .idle ∧ s.tok = true := by
  decide

/-- The same trace with the proposed fix keeps the key queued. -/
theorem fix_keeps_redirty : (run true init dropTrace).queueUp = [0] := by decide

/-- With the token gone (a 401 on a background flush with no user activation,
2086: e.g. a gamepad player after the hour), a new save makes
refreshSyncStatus say "syncing" (it only says "paused" after 3 renewal
strikes), the debounce flush returns at `if (!syncActive()) return` (2707)
without touching the lamp, and nothing is left to run: the spinner turns
with nothing in flight, nothing scheduled, and the home Sync button disabled
(`homeSyncBtn.disabled = syncStatus === "syncing"`, 3850). The poll does
nothing either (3812). -/
def spinTrace : List Ev :=
  [.write 0, .mark 0, .debounce, .jobStart, .preludeOk, .readSnap, .readResume,
   .up401 false, .saveDone,
   .write 0, .mark 0, .debounce, .jobStart, .poll, .doneTimer]

theorem bug_spinner_without_work (fix : Bool) :
    let s := run fix init spinTrace
    s.status = .syncing ∧ s.tok = false ∧ s.chain = [] ∧ s.debounce = false ∧ s.cap = false ∧
    s.pullCalls = [] ∧ s.rfs = [] ∧ s.busy = false ∧ s.queueUp = [0] := by
  cases fix <;> decide

/-- And once a gesture renews the token, renewDriveToken's tail only pulls
(3761): the pull's refreshSyncStatus keeps "syncing", nothing flushes, and the
disabled Sync button waits for the next 3-minute poll. -/
theorem bug_spinner_after_renewal (fix : Bool) :
    let s := run fix init (spinTrace ++ [.tokArrive true, .callPull 0, .jobStart, .pullOk none false])
    s.status = .syncing ∧ s.tok = true ∧ s.chain = [] ∧ s.debounce = false ∧ s.cap = false ∧
    s.pullCalls = [] ∧ s.rfs = [] ∧ s.queueUp = [0] := by
  cases fix <;> decide

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

theorem inv_markUpload {s : St} (h : Inv s) (fix : Bool) (i : Nat) : Inv (markUpload fix s i) := by
  unfold markUpload
  apply inv_scheduleFlush
  split
  · split
    · exact inv_congr h rfl rfl rfl rfl id
    · exact h
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

theorem inv_nextItem (fix : Bool) {s : St} (rest : List Nat) (after : Option Bool)
    (h1 : ∀ j ∈ s.chain.tail, j.waiting = true) (hb : s.busy = true)
    (h4 : s.queueUp.Nodup) (h5 : s.held.Nodup)
    (hr : ∀ x ∈ rest, x ∈ s.queueUp) (hrn : rest.Nodup) : Inv (nextItem fix s rest after) := by
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

theorem dropItem_fields (fix : Bool) (s : St) (n : Nat) :
    (dropItem fix s n).chain = s.chain ∧ (dropItem fix s n).busy = s.busy ∧
    (dropItem fix s n).held = s.held ∧ (dropItem fix s n).status = s.status ∧
    (dropItem fix s n).drive = s.drive ∧ (dropItem fix s n).ver = s.ver ∧
    (dropItem fix s n).marks = s.marks ∧ (dropItem fix s n).remarked = s.remarked ∧
    ((dropItem fix s n).queueUp = s.queueUp ∨ (dropItem fix s n).queueUp = s.queueUp.filter (· != n)) := by
  unfold dropItem; split <;> simp

theorem dropItem_keeps (fix : Bool) (s : St) (n x : Nat) (hx : x ≠ n) (hq : x ∈ s.queueUp) :
    x ∈ (dropItem fix s n).queueUp := by
  rcases (dropItem_fields fix s n).2.2.2.2.2.2.2.2 with h | h <;> rw [h]
  · exact hq
  · simp [hq, hx]

theorem dropItem_nodup (fix : Bool) (s : St) (n : Nat) (h : s.queueUp.Nodup) :
    (dropItem fix s n).queueUp.Nodup := by
  rcases (dropItem_fields fix s n).2.2.2.2.2.2.2.2 with h' | h' <;> rw [h']
  · exact h
  · exact h.filter _

/-- the flush finished an item: drop it and move on -/
theorem inv_done_item (fix : Bool) {s : St} (hI : Inv s) (n : Nat) (r : List Nat) (after : Option Bool)
    (hf : flightName s.chain = some (n, r)) (s' : St) (hc : s'.chain = s.chain) (hb : s'.busy = s.busy)
    (hq : s'.queueUp = s.queueUp) (hh : s'.held = s.held) :
    Inv (nextItem fix (dropItem fix s' n) r after) := by
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
  obtain ⟨d1, d2, d3, -⟩ := dropItem_fields fix s' n
  apply inv_nextItem
  · rw [d1, hc]; exact h1
  · rw [d2, hb, h2, hrun]
  · exact dropItem_nodup fix s' n (hq ▸ h4)
  · rw [d3, hh]; exact h5
  · intro x hx
    exact dropItem_keeps fix s' n x (fun e => hn (e ▸ hx)) (hq ▸ hr x hx)
  · exact hrn

theorem inv_step (fix : Bool) (s : St) (e : Ev) (hI : Inv s) : Inv (step fix s e) := by
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
    · exact inv_markUpload (inv_congr (s' := { s with marks := s.marks.erase i }) hI rfl rfl rfl rfl id) fix i
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
      exact inv_nextItem fix _ _ h1 hb h4 h5 (fun _ hx => hx) h4
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
      · exact inv_done_item fix hI n r after (by rw [hc]; rfl) s rfl rfl rfl rfl
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
      exact inv_done_item fix hI n r after (by rw [hc]; rfl) _ rfl rfl rfl rfl
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

theorem reachable_inv {fix : Bool} {s : St} (h : Reachable fix s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step e _ ih => exact inv_step fix _ e ih

/-! ### Proved properties (the JS as written and the fix alike) -/

/-- **No two Drive jobs run at once.** Every job behind the chain head is
still waiting to start: `runExclusive` (2690) is the only way into
`flushSyncInner`/`pullSyncInner`, so no flush overlaps another flush or a
pull, and no name is being uploaded by two flushes. -/
theorem mutual_exclusion {fix : Bool} {s : St} (h : Reachable fix s) :
    ∀ j ∈ s.chain.tail, j.waiting = true :=
  (reachable_inv h).tailWaiting

/-- `queueUp` never holds a name twice (markUpload 2656, markGameUpload 2675,
runFullSync 3067 and the pull's reconcile 3025 all check `includes` first), so a flush's snapshot
uploads each name at most once. -/
theorem queue_nodup {fix : Bool} {s : St} (h : Reachable fix s) : s.queueUp.Nodup :=
  (reachable_inv h).qNodup

/-- `syncBusy` is exactly "a flush or pull body is between its start and its
end" (2712, 2816, 2819, 2922, 3054, 3058). -/
theorem busy_iff_running {fix : Bool} {s : St} (h : Reachable fix s) :
    s.busy = headRunning s.chain :=
  (reachable_inv h).busyRun

/-- **The lamp does not spin over nothing.** With no Drive job queued or
running and an empty upload queue, the status is not "syncing". -/
theorem lamp_not_spinning_when_quiet {fix : Bool} {s : St} (h : Reachable fix s)
    (hc : s.chain = []) (hq : s.queueUp = []) : s.status ≠ .syncing := by
  intro hs
  have hI := reachable_inv h
  rcases hI.lamp hs with h' | h' | h'
  · exact h' hq
  · rw [hI.busyRun, hc] at h'; simp [headRunning] at h'
  · rw [hc] at h'; simp [headFailSave] at h'

/-- **The name being uploaded is still queued**, and so is the rest of the
flush's snapshot: nothing leaves `queueUp` before its own upload completes. -/
theorem in_flight_is_queued {fix : Bool} {s : St} (h : Reachable fix s) {n : Nat} {r : List Nat}
    (hf : flightName s.chain = some (n, r)) : n ∈ s.queueUp ∧ ∀ x ∈ r, x ∈ s.queueUp := by
  obtain ⟨a, -, c, -⟩ := (reachable_inv h).flight n r hf
  exact ⟨a, c⟩

/-- **A failed upload stays queued**: a network failure, a 401 without
activation, or a failed re-grant ends the flush in `catch` with `queueUp`
untouched, so the name being uploaded and every name after it remain queued
(they flush on the next trigger). -/
theorem failed_upload_stays_queued {fix : Bool} {s : St} (h : Reachable fix s)
    {n v w r a rest} (hc : s.chain = .flush (.upload n v w r) a :: rest)
    (e : Ev) (he : e = .upFail ∨ e = .up401 false) :
    (step fix s e).queueUp = s.queueUp ∧ n ∈ (step fix s e).queueUp ∧
    ∀ x ∈ r, x ∈ (step fix s e).queueUp := by
  have hq : (step fix s e).queueUp = s.queueUp := by
    rcases he with rfl | rfl <;> simp [step, hc, catchFail, setHead]
  rw [hq]
  exact ⟨rfl, in_flight_is_queued h (by rw [hc]; rfl)⟩

theorem failed_regrant_stays_queued {fix : Bool} {s : St} (h : Reachable fix s)
    {n v r a rest} (hc : s.chain = .flush (.reauth n v r) a :: rest) :
    (step fix s .reauthFail).queueUp = s.queueUp ∧ n ∈ s.queueUp := by
  refine ⟨by simp [step, hc, catchFail, setHead], (in_flight_is_queued h (by rw [hc]; rfl)).1⟩

/-! ### The fix: `markUpload` remembers a re-dirtied in-flight name

```js
const syncRemarked = new Set();                       // beside syncState
// markUpload / markGameUpload / runFullSync's push:
if (!syncState.queueUp.includes(name)) syncState.queueUp.push(name);
else syncRemarked.add(name);
// flushSyncInner, top of the queueUp loop body (before readSyncBytes):
syncRemarked.delete(name);
// ...and the filter at 2799 becomes
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

theorem nextItem_fields (fix : Bool) (s : St) (r : List Nat) (a : Option Bool) :
    (nextItem fix s r a).drive = s.drive ∧ (nextItem fix s r a).ver = s.ver ∧
    (nextItem fix s r a).marks = s.marks ∧ (nextItem fix s r a).queueUp = s.queueUp ∧
    flightVer (nextItem fix s r a).chain = none := by
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
    FixInv (nextItem true (dropItem true { s with drive := d } n) r a) := by
  obtain ⟨f1, f2, f3⟩ := h
  obtain ⟨hvle, hvcase⟩ := f3 n v hfv
  obtain ⟨r', hfn⟩ := flightVer_name hfv
  have hnq : n ∈ s.queueUp := (hI.flight n r' hfn).1
  -- with v = 0 the drive is untouched and v = ver n forces drive n = 0 = ver n
  obtain ⟨g1, g2, g3, g4, g5⟩ := nextItem_fields true (dropItem true { s with drive := d } n) r a
  obtain ⟨-, -, -, -, d5, d6, d7, d8, d9⟩ := dropItem_fields true { s with drive := d } n
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
      · left; exact dropItem_keeps true _ n i hin h'
      · exact Or.inr h'
  · intro n' v' hf; rw [g5] at hf; cases hf

theorem fix_step (s : St) (e : Ev) (hI : Inv s) (hF : FixInv s) : FixInv (step true s e) := by
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
        simp only [ite_true]
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
      obtain ⟨g1, g2, g3, g4, g5⟩ := nextItem_fields true s s.queueUp after
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

theorem reachable_fixInv {s : St} (h : Reachable true s) : FixInv s := by
  induction h with
  | init => exact fixInv_init
  | step e hr ih => exact fix_step _ e (reachable_inv hr) ih

/-- **With the fix, no re-dirtied name is dropped**: in every reachable state,
a key whose Drive copy is not its current local bytes is queued for upload,
or its markUpload is still to run. -/
theorem fix_no_lost_upload {s : St} (h : Reachable true s) (i : Nat) (hi : s.drive i ≠ s.ver i) :
    i ∈ s.queueUp ∨ i ∈ s.marks :=
  (reachable_fixInv h).good i hi

/-- ...and so with the fix, once everything has drained, Drive holds every key's latest bytes. -/
theorem fix_quiet_means_synced {s : St} (h : Reachable true s) (hq : s.queueUp = []) (hm : s.marks = []) :
    ∀ i, s.drive i = s.ver i := by
  intro i
  by_cases hi : s.drive i = s.ver i
  · exact hi
  · rcases fix_no_lost_upload h i hi with h' | h' <;> simp_all

/-- The JS as written breaks exactly that. -/
theorem js_loses_upload : ∃ s, Reachable false s ∧ s.queueUp = [] ∧ s.marks = [] ∧ s.chain = [] ∧
    s.drive 0 ≠ s.ver 0 :=
  ⟨run false init dropTrace, reachable_run false dropTrace init .init, by decide, by decide, by decide,
   by decide⟩

end WebState.DriveSession.Queue

namespace WebState.DriveSession.Session

/-- renewDriveToken's continuation (3725-3762). `was` = wasSignedOut (3729). -/
inductive RPc where
  /-- awaiting `loadGisScript()` (3732) -/
  | gis (was : Bool)
  /-- awaiting `gdriveAcquireToken("")` (3740); `res` once the shared request settled -/
  | acq (was : Bool) (res : Option Bool)
  /-- awaiting `gdriveFetchEmail()` (3757); the tokeninfo fetch carried `tokAt` -/
  | email (tokAt : Option Nat)
  deriving DecidableEq, Repr

/-- gdriveConnect's continuation (3654-3664). -/
inductive CPc where
  /-- awaiting `gdriveAcquireToken()` (3655) -/
  | acq (res : Option Bool)
  /-- awaiting `gdriveFetchEmail()` (3656) -/
  | email (tokAt : Option Nat)
  /-- awaiting `saveSyncState()` (3659) -/
  | save
  /-- runFullSync: awaiting `localSyncFiles()` + `saveSyncState()` (3066-3068) -/
  | full
  deriving DecidableEq, Repr

/-- flushSyncInner, coarse: `own` is the account whose syncState (queues,
tombstones, renames) and Drive library the flush captured at its start (2718). -/
inductive FPc where
  | start
  | prelude (own : Nat)
  /-- an upload in flight, `k` more after it -/
  | upload (own : Nat) (k : Nat)
  /-- driveFetch got 401 with activation: awaiting `gdriveAcquireToken("")` (2084) -/
  | reauth (own : Nat) (k : Nat) (res : Option Bool)
  /-- `writeDriveLibrary(lib, ...)` in flight (2801) -/
  | libWrite (own : Nat)
  deriving DecidableEq, Repr

inductive Job where
  | flush (pc : FPc) (after : Bool)
  | pull (started : Bool)
  deriving DecidableEq, Repr

structure St where
  connected  : Bool             -- syncState.connected (driveLinked)
  token      : Option Nat       -- gdriveToken, as the Google account it was granted for
  email      : Option Nat       -- syncState.email: the login_hint (an account)
  acct       : Nat              -- syncState.acct: whose queues/tombstones are loaded (2361)
  fails      : Nat              -- driveRenewFails (3699)
  armed      : Bool             -- driveRenewArmed (3698)
  req        : Option (Option Nat) -- gdriveTokenInFlight (2006), with the login_hint it was issued with
  renews     : List RPc         -- renewDriveToken calls in flight
  connects   : List CPc         -- gdriveConnect calls in flight
  chain      : List Job         -- syncChain (head runs)
  pullQueued : Bool             -- pullQueued (2696)
  pullCalls  : Nat              -- pending `.then(() => pullSync())`
  -- ghosts
  gestures   : Nat              -- window pointerdown/keydown/touchstart events
  renewCalls : Nat              -- renewDriveToken() invocations
  denials    : Nat              -- token requests refused (popup closed/blocked, grant gone)
  outTraffic : Bool             -- a Drive request left with a live token while signed out, no sign-in running
  crossLib   : Bool             -- a library captured under one account was written to another account's Drive
  deriving DecidableEq, Repr

/-- Reload more than an hour after the last grant, account 1 linked:
resumeDriveOnBoot (3766) finds the persisted token expired and arms the
gesture renewal (3800). -/
def init : St :=
  { connected := true, token := none, email := some 1, acct := 1, fails := 0, armed := true,
    req := none, renews := [], connects := [], chain := [], pullQueued := false, pullCalls := 0,
    gestures := 0, renewCalls := 0, denials := 0, outTraffic := false, crossLib := false }

inductive Ev where
  /-- a window pointerdown/keydown/touchstart reaches the armed capture listener (3710-3719);
  `online` = navigator.onLine at renewDriveToken's check (3728) -/
  | gesture (online : Bool)
  /-- armDriveRenewOnGesture from syncPollTick (3810), visibilitychange (3831),
  resumeDriveOnBoot (3795, 3800) or driveFetch's 401 path (2087) -/
  | arm
  /-- renewal #k: loadGisScript settled (`ok`), hasUserActivation() = `act` (3731-3737) -/
  | renewGis (k : Nat) (ok : Bool) (act : Bool)
  /-- renewal #k resumes after its token request settled (3739-3756) -/
  | renewAcq (k : Nat)
  /-- renewal #k's gdriveFetchEmail settled; tokeninfo `ok` (3757-3761) -/
  | renewEmail (k : Nat) (ok : Bool)
  /-- the GIS callback delivers a token for account `a` (2021-2031) -/
  | tokGrant (a : Nat)
  /-- error_callback / resp.error (2022, 2032) -/
  | tokDeny
  /-- a Sign in button (2249, 3912, 3881): gdriveConnect -/
  | signIn
  | connAcq (k : Nat)
  | connEmail (k : Nat) (ok : Bool)
  | connSave (k : Nat)
  | connFull (k : Nat)
  /-- the Sign out button (2269): gdriveSignOut (2191) -/
  | signOut
  /-- syncPollTick's sync part (3812-3814): `withFlush` = pendingCount() -/
  | poll (withFlush : Bool)
  /-- visibilitychange -> visible (3832) or window online (3823) -/
  | visible
  | callPull
  /-- the chain head's body starts; `proceed`: flushSyncInner found work (2708) -/
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

/-- armDriveRenewOnGesture (3704-3708). -/
def arm (s : St) : St :=
  if s.armed || !s.connected || decide (s.fails ≥ 3) then s else { s with armed := true }

/-- gdriveAcquireToken (2011-2013): join the request in flight, or issue one with this hint. -/
def joinOrCreate (s : St) (hint : Option Nat) : St :=
  if s.req.isSome then s else { s with req := some hint }

/-- a Drive request leaves with the current token -/
def send (s : St) : St :=
  if s.token.isSome && !s.connected && s.connects.isEmpty then { s with outTraffic := true } else s

/-- the library write (2801) leaves with the current token -/
def libSend (s : St) (own : Nat) : St :=
  let s := send s
  match s.token with
  | some b => if b = own then s else { s with crossLib := true }
  | none => s

/-- gdriveFetchEmail's tail (2064-2066): rememberDriveEmail + adoptDriveAccount -/
def fetchEmail (s : St) (tokAt : Option Nat) (ok : Bool) : St :=
  match tokAt, ok with
  | some a, true => { s with email := some a, acct := a }
  | _, _ => s

def flushSync (s : St) (after : Bool) : St := { s with chain := s.chain ++ [.flush .start after] }
def pullSync (s : St) : St :=
  if s.pullQueued then s else { s with pullQueued := true, chain := s.chain ++ [.pull false] }
def setHead (s : St) (j : Job) : St := { s with chain := j :: s.chain.tail }
def popHead (s : St) : St := { s with chain := s.chain.tail }
def finish (s : St) (after : Bool) : St :=
  if after then { popHead s with pullCalls := s.pullCalls + 1 } else popHead s

/-- renewDriveToken's first segment (3725-3732) -/
def renewCall (s : St) (online : Bool) : St :=
  let s := { s with renewCalls := s.renewCalls + 1 }
  if !s.connected then s
  else if !online then arm s
  else { s with renews := s.renews ++ [.gis s.token.isNone] }

def stampR (r : Bool) : RPc → RPc
  | .acq w none => .acq w (some r)
  | c => c
def stampC (r : Bool) : CPc → CPc
  | .acq none => .acq (some r)
  | c => c
def stampJ (r : Bool) : Job → Job
  | .flush (.reauth o k none) a => .flush (.reauth o k (some r)) a
  | j => j

/-- the request settles: every caller awaiting it resumes with the outcome -/
def settle (s : St) (r : Bool) : St :=
  { s with req := none, renews := s.renews.map (stampR r), connects := s.connects.map (stampC r),
           chain := s.chain.map (stampJ r) }

def step (s : St) : Ev → St
  | .gesture on =>
      let s := { s with gestures := s.gestures + 1 }
      -- onGesture: listeners removed, driveRenewArmed = false, renewDriveToken()
      if s.armed then renewCall { s with armed := false } on else s
  | .arm => arm s
  | .renewGis k ok act =>
      match s.renews[k]? with
      | some (.gis was) =>
          let s := { s with renews := s.renews.eraseIdx k }
          if !ok || !act then arm s
          else let s := joinOrCreate s s.email
               { s with renews := s.renews ++ [.acq was none] }
      | _ => s
  | .renewAcq k =>
      match s.renews[k]? with
      | some (.acq was (some r)) =>
          let s := { s with renews := s.renews.eraseIdx k }
          if !r then
            -- `if (++driveRenewFails >= DRIVE_RENEW_MAX_FAILS) clearDriveToken() else arm`
            let s := { s with fails := s.fails + 1 }
            if s.fails ≥ 3 then { s with token := none } else arm s
          else
            let s := { s with fails := 0 }
            if !was then s else { s with renews := s.renews ++ [.email s.token] }
      | _ => s
  | .renewEmail k ok =>
      match s.renews[k]? with
      | some (.email t) => pullSync (fetchEmail { s with renews := s.renews.eraseIdx k } t ok)
      | _ => s
  | .tokGrant a =>
      match s.req with
      | some h =>
          -- with a login_hint the grant is for that account
          if h = none || h = some a then { settle s true with token := some a } else s
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
          let s := fetchEmail { s with connects := s.connects.eraseIdx k } t ok
          { s with fails := 0, connected := true, connects := s.connects ++ [.save] }
      | _ => s
  | .connSave k =>
      match s.connects[k]? with
      | some .save =>
          let s := { s with connects := s.connects.eraseIdx k }
          -- runFullSync: `if (!syncActive()) return;`
          if s.token.isSome then { s with connects := s.connects ++ [.full] } else s
      | _ => s
  | .connFull k =>
      match s.connects[k]? with
      | some .full => flushSync { s with connects := s.connects.eraseIdx k } true
      | _ => s
  | .signOut =>
      -- revoke (not modelled), rememberDriveEmail(null), connected = false, clearDriveToken(),
      -- syncTimer/syncCapTimer cleared. syncPollTimer, syncChain, renewals: untouched.
      if !s.connected then s else { s with email := none, connected := false, token := none }
  | .poll wf => if s.token.isNone then s else if wf then flushSync s true else pullSync s
  | .visible => if s.token.isSome then flushSync s true else s
  | .callPull => if s.pullCalls > 0 then pullSync { s with pullCalls := s.pullCalls - 1 } else s
  | .jobStart p =>
      match s.chain with
      | .flush .start after :: _ =>
          if s.token.isNone || !p then finish s after
          else send (setHead s (.flush (.prelude s.acct) after))
      | .pull false :: _ =>
          let s := { s with pullQueued := false }
          if s.token.isNone then popHead s else send (setHead s (.pull true))
      | _ => s
  | .preludeOk k =>
      match s.chain with
      | .flush (.prelude o) after :: _ =>
          if k = 0 then libSend (setHead s (.flush (.libWrite o) after)) o
          else send (setHead s (.flush (.upload o (k - 1)) after))
      | _ => s
  | .upOk =>
      match s.chain with
      | .flush (.upload o k) after :: _ =>
          if k = 0 then libSend (setHead s (.flush (.libWrite o) after)) o
          else send (setHead s (.flush (.upload o (k - 1)) after))
      | _ => s
  | .up401 act =>
      match s.chain with
      | .flush (.upload o k) after :: _ =>
          if act then setHead (joinOrCreate s s.email) (.flush (.reauth o k none) after)
          else finish (arm { s with token := none }) after
      | _ => s
  | .reauthRes =>
      match s.chain with
      | .flush (.reauth o k (some r)) after :: _ =>
          if r then send (setHead s (.flush (.upload o k) after))
          else finish (arm { s with token := none }) after
      | _ => s
  | .libDone =>
      match s.chain with
      | .flush (.libWrite _) after :: _ => finish s after
      | _ => s
  | .jobFail =>
      match s.chain with
      | .flush (.prelude _) after :: _ => finish s after
      | .flush (.upload _ _) after :: _ => finish s after
      | .flush (.libWrite _) after :: _ => finish s after
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

/-! ### Counterexamples -/

/-- A renewal in flight survives Sign out and hands the signed-out tab a live
token (null-token variant: e.g. a background flush's 401 cleared it, 2086,
and armed the renewal, 2087, while Settings was open). The user's first input
is on "Sign out": its pointerdown/keydown runs the capture listener first
(3710-3719) and the silent popup opens; then its click runs gdriveSignOut (no
revoke: the token is null). The grant lands after: the GIS callback sets and
*persists* gdriveToken (2026-2029), renewDriveToken re-remembers the email the
sign-out just cleared and calls pullSync (3758-3761), and the pull runs
against Drive with `connected = false`. -/
def resurrectTrace : List Ev :=
  [.gesture true, .renewGis 0 true true, .signOut, .tokGrant 1, .renewAcq 0,
   .renewEmail 0 true, .jobStart true]

theorem bug_renewal_resurrects_token :
    let s := run init resurrectTrace
    s.connected = false ∧ s.token = some 1 ∧ s.email = some 1 ∧ s.outTraffic = true ∧
    s.req = none ∧ s.renews = [] ∧ s.connects = [] := by
  decide

/-- ...and it keeps going: every 3-minute poll (the interval is never
cleared, 3818) flushes and pulls with it (3812 gates on syncActive(), not on
driveLinked()). -/
theorem bug_signed_out_tab_keeps_syncing :
    let s := run init (resurrectTrace ++ [.pullDone false, .poll true, .jobStart true, .preludeOk 1])
    s.connected = false ∧ s.token = some 1 ∧ s.chain = [.flush (.upload 1 0) true] := by
  decide

/-- The rollover variant: a live but stale token (within 10 minutes of
expiry, 3694) armed by the poll (3810); wasSignedOut is false so there is no
immediate pull, but the new token outlives the sign-out and the next poll
uses it. -/
def resurrectRolloverTrace : List Ev :=
  [.gesture true, .renewGis 0 true true, .tokGrant 1, .renewAcq 0, .renewEmail 0 true,
   .jobStart true, .pullDone false,
   .arm, .gesture true, .renewGis 0 true true, .signOut, .tokGrant 1, .renewAcq 0,
   .poll false, .jobStart true]

theorem bug_renewal_resurrects_token_rollover :
    let s := run init resurrectRolloverTrace
    s.connected = false ∧ s.token = some 1 ∧ s.outTraffic = true ∧ s.renews = [] ∧
    s.connects = [] := by
  decide

/-- A flush running when the user signs out and back in as another account
finishes under the new account's token: after its in-flight upload it writes
the library it merged from account 1's Drive plus account 1's tombstones and
renames into account 2's Drive (2801), then stores them in account 2's
syncState (2802). Neither gdriveSignOut nor gdriveConnect touches syncChain;
account 2's own runFullSync queues behind it. -/
def crossTrace : List Ev :=
  [.gesture true, .renewGis 0 true true, .tokGrant 1, .renewAcq 0, .renewEmail 0 true,
   .jobStart true, .pullDone false,
   .poll true, .jobStart true, .preludeOk 1,
   .signOut, .signIn, .tokGrant 2, .connAcq 0, .connEmail 0 true,
   .upOk]

theorem bug_flush_crosses_accounts :
    let s := run init crossTrace
    s.crossLib = true ∧ s.acct = 2 ∧ s.token = some 2 ∧ s.connected = true := by
  decide

/-- Two renewals can be in flight at once (the arm flag is cleared before the
first one's attempt, 3718, and a poll/visibilitychange/401 may re-arm while
its popup is open), and the second joins the first's popup (2012). One
refused popup then costs two of the three strikes (3744). -/
def strikeTrace : List Ev :=
  [.gesture true, .renewGis 0 true true, .arm, .gesture true, .renewGis 1 true true,
   .tokDeny, .renewAcq 0, .renewAcq 0]

theorem bug_one_popup_two_strikes :
    let s := run init strikeTrace
    s.denials = 1 ∧ s.fails = 2 ∧ s.renewCalls = 2 := by
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
  unfold fetchEmail; split <;> simp
@[simp] theorem pullSync_c : (pullSync s).renewCalls = s.renewCalls ∧ (pullSync s).gestures = s.gestures := by
  unfold pullSync; split <;> simp
@[simp] theorem finish_c (a : Bool) :
    (finish s a).renewCalls = s.renewCalls ∧ (finish s a).gestures = s.gestures := by
  unfold finish; split <;> simp [popHead]
end counters

/-- Every event other than a gesture leaves the renewal count alone:
`armDriveRenewOnGesture` only adds listeners, and `renewDriveToken`'s every
exit path (offline, script failure, no activation, refusal) re-arms instead
of retrying. -/
theorem only_gesture_renews (s : St) (e : Ev) (he : ∀ on, e ≠ .gesture on) :
    (step s e).renewCalls = s.renewCalls ∧ (step s e).gestures = s.gestures := by
  cases e with
  | gesture on => exact absurd rfl (he on)
  | arm => simp [step]
  | renewGis k ok act =>
    simp only [step]; split
    · split
      · exact arm_c _
      · simp only; exact join_c _ _
    · simp
  | renewAcq k =>
    simp only [step]; split
    · split
      · split
        · simp
        · exact arm_c _
      · split <;> simp
    · simp
  | renewEmail k ok =>
    simp only [step]; split
    · rename_i t _
      have := pullSync_c (fetchEmail { s with renews := s.renews.eraseIdx k } t ok)
      have := fetchEmail_c { s with renews := s.renews.eraseIdx k } t ok
      simp_all
    · simp
  | tokGrant a => simp only [step]; split
                  · split <;> simp [settle]
                  · simp
  | tokDeny => simp only [step]; split <;> simp [settle]
  | signIn => simp only [step]; split
              · simp
              · simp only; exact join_c _ _
  | connAcq k => simp only [step]; split
                 · split <;> simp
                 · simp
  | connEmail k ok =>
    simp only [step]; split
    · rename_i t _
      have := fetchEmail_c { s with connects := s.connects.eraseIdx k } t ok
      simp_all
    · simp
  | connSave k => simp only [step]; split
                  · split <;> simp
                  · simp
  | connFull k => simp only [step]; split <;> simp [flushSync]
  | signOut => simp only [step]; split <;> simp
  | poll wf => simp only [step]; split
               · simp
               · split
                 · simp [flushSync]
                 · exact pullSync_c _
  | visible => simp only [step]; split <;> simp [flushSync]
  | callPull => simp only [step]; split
                · have := pullSync_c { s with pullCalls := s.pullCalls - 1 }; simp_all
                · simp
  | jobStart p =>
    simp only [step]; split
    · split
      · exact finish_c _ _
      · have := send_c (setHead s (.flush (.prelude s.acct) (by assumption))); simp_all [setHead]
    · split
      · simp [popHead]
      · have := send_c (setHead { s with pullQueued := false } (.pull true)); simp_all [setHead]
    · simp
  | preludeOk k =>
    simp only [step]; split
    · split
      · have := libSend_c (setHead s (.flush (.libWrite (by assumption)) (by assumption))) (by assumption)
        simp_all [setHead]
      · have := send_c (setHead s (.flush (.upload (by assumption) (k - 1)) (by assumption)))
        simp_all [setHead]
    · simp
  | upOk =>
    simp only [step]; split
    · rename_i o k a _ _
      split
      · have := libSend_c (setHead s (.flush (.libWrite o) a)) o; simp_all [setHead]
      · have := send_c (setHead s (.flush (.upload o (k - 1)) a)); simp_all [setHead]
    · simp
  | up401 act =>
    simp only [step]; split
    · rename_i o k a _ _
      split
      · have := join_c s s.email; simp_all [setHead]
      · have := finish_c (arm { s with token := none }) a
        have := arm_c { s with token := none }
        simp_all
    · simp
  | reauthRes =>
    simp only [step]; split
    · rename_i o k r a _ _
      split
      · have := send_c (setHead s (.flush (.upload o k) a)); simp_all [setHead]
      · have := finish_c (arm { s with token := none }) a
        have := arm_c { s with token := none }
        simp_all
    · simp
  | libDone => simp only [step]; split
               · exact finish_c _ _
               · simp
  | jobFail => simp only [step]; split
               · exact finish_c _ _
               · exact finish_c _ _
               · exact finish_c _ _
               · simp
  | pullDone clr =>
    simp only [step]; split
    · split
      · have := arm_c { s with token := none }; simp_all [popHead]
      · simp [popHead]
    · simp

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
loop on its own (the 2026-09 offline microtask loop, where renewDriveToken's
offline branch re-entered itself, is impossible in this shape: the offline
branch only re-arms). -/
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

/-! ### Proved: a sign-out with nothing in flight is final

What the two sign-out counterexamples need is exactly something in flight at
the click: a token request or a renewal/connect continuation (resurrection),
or a started flush/pull (cross-account). Without those, nothing but a new
Sign in can put a token back or send a request. -/

def Job.waiting : Job → Bool
  | .flush .start _ => true
  | .pull false => true
  | _ => false

structure QuietOut (s : St) : Prop where
  out      : s.connected = false
  tok      : s.token = none
  req      : s.req = none
  renews   : s.renews = []
  connects : s.connects = []
  chain    : ∀ j ∈ s.chain, j.waiting = true

theorem waiting_head {c : List Job} (h : ∀ j ∈ c, j.waiting = true) :
    c = [] ∨ (∃ a t, c = .flush .start a :: t) ∨ (∃ t, c = .pull false :: t) := by
  cases c with
  | nil => exact Or.inl rfl
  | cons j t =>
    have hj := h j (by simp)
    rcases j with ⟨pc, a⟩ | ⟨b⟩
    · cases pc <;> simp [Job.waiting] at hj
      exact Or.inr (Or.inl ⟨a, t, rfl⟩)
    · cases b <;> simp [Job.waiting] at hj
      exact Or.inr (Or.inr ⟨t, rfl⟩)

theorem quiet_tail {s : St} (h : QuietOut s) : ∀ j ∈ s.chain.tail, j.waiting = true :=
  fun j hj => h.chain j (List.mem_of_mem_tail hj)

theorem quiet_step (s : St) (e : Ev) (hq : QuietOut s) (he : e ≠ .signIn) :
    QuietOut (step s e) ∧ (step s e).outTraffic = s.outTraffic ∧ (step s e).crossLib = s.crossLib := by
  obtain ⟨q1, q2, q3, q4, q5, q6⟩ := hq
  have hq : QuietOut s := ⟨q1, q2, q3, q4, q5, q6⟩
  -- the chain-driven events cannot fire: the head has not started
  have stuck : ∀ e', (∀ a t, s.chain = .flush .start a :: t → step s e' = s) →
      (∀ t, s.chain = .pull false :: t → step s e' = s) → (s.chain = [] → step s e' = s) →
      QuietOut (step s e') ∧ (step s e').outTraffic = s.outTraffic ∧ (step s e').crossLib = s.crossLib := by
    intro e' h1 h2 h3
    rcases waiting_head q6 with hc | ⟨a, t, hc⟩ | ⟨t, hc⟩
    · rw [h3 hc]; exact ⟨hq, rfl, rfl⟩
    · rw [h1 a t hc]; exact ⟨hq, rfl, rfl⟩
    · rw [h2 t hc]; exact ⟨hq, rfl, rfl⟩
  have simple : ∀ e', (step s e').connected = s.connected → (step s e').token = s.token →
      (step s e').req = s.req → (step s e').renews = s.renews → (step s e').connects = s.connects →
      (step s e').chain = s.chain → (step s e').outTraffic = s.outTraffic →
      (step s e').crossLib = s.crossLib →
      QuietOut (step s e') ∧ (step s e').outTraffic = s.outTraffic ∧ (step s e').crossLib = s.crossLib := by
    intro e' h1 h2 h3 h4 h5 h6 h7 h8
    exact ⟨⟨h1.trans q1, h2.trans q2, h3.trans q3, h4.trans q4, h5.trans q5, h6 ▸ q6⟩, h7, h8⟩
  cases e with
  | gesture on =>
    apply simple <;> simp only [step] <;> split <;> simp [renewCall, q1]
  | arm => apply simple <;> simp [step, arm, q1]
  | renewGis k ok act => apply simple <;> simp [step, q4]
  | renewAcq k => apply simple <;> simp [step, q4]
  | renewEmail k ok => apply simple <;> simp [step, q4]
  | tokGrant a => apply simple <;> simp [step, q3]
  | tokDeny => apply simple <;> simp [step, q3]
  | signIn => exact absurd rfl he
  | connAcq k => apply simple <;> simp [step, q5]
  | connEmail k ok => apply simple <;> simp [step, q5]
  | connSave k => apply simple <;> simp [step, q5]
  | connFull k => apply simple <;> simp [step, q5]
  | signOut => apply simple <;> simp [step, q1]
  | poll wf => apply simple <;> simp [step, q2]
  | visible => apply simple <;> simp [step, q2]
  | callPull =>
    simp only [step]; split
    · unfold pullSync; split
      · exact ⟨⟨q1, q2, q3, q4, q5, q6⟩, rfl, rfl⟩
      · refine ⟨⟨q1, q2, q3, q4, q5, ?_⟩, rfl, rfl⟩
        intro j hj; simp at hj
        rcases hj with hj | rfl
        · exact q6 j hj
        · rfl
    · exact ⟨hq, rfl, rfl⟩
  | jobStart p =>
    rcases waiting_head q6 with hc | ⟨a, t, hc⟩ | ⟨t, hc⟩
    · have e1 : step s (.jobStart p) = s := by simp [step, hc]
      rw [e1]; exact ⟨hq, rfl, rfl⟩
    · have ht : ∀ j ∈ t, j.waiting = true := fun j hj => q6 j (by rw [hc]; simp [hj])
      have e1 : step s (.jobStart p) = finish s a := by simp [step, hc, q2]
      rw [e1]; unfold finish; split
      · exact ⟨⟨q1, q2, q3, q4, q5, by simpa [popHead, hc] using ht⟩, rfl, rfl⟩
      · exact ⟨⟨q1, q2, q3, q4, q5, by simpa [popHead, hc] using ht⟩, rfl, rfl⟩
    · have ht : ∀ j ∈ t, j.waiting = true := fun j hj => q6 j (by rw [hc]; simp [hj])
      have e1 : step s (.jobStart p) = popHead { s with pullQueued := false } := by simp [step, hc, q2]
      rw [e1]
      exact ⟨⟨q1, q2, q3, q4, q5, by simpa [popHead, hc] using ht⟩, rfl, rfl⟩
  | preludeOk k => exact stuck _ (by intro a t hc; simp [step, hc]) (by intro t hc; simp [step, hc])
                     (by intro hc; simp [step, hc])
  | upOk => exact stuck _ (by intro a t hc; simp [step, hc]) (by intro t hc; simp [step, hc])
              (by intro hc; simp [step, hc])
  | up401 act => exact stuck _ (by intro a t hc; simp [step, hc]) (by intro t hc; simp [step, hc])
                   (by intro hc; simp [step, hc])
  | reauthRes => exact stuck _ (by intro a t hc; simp [step, hc]) (by intro t hc; simp [step, hc])
                   (by intro hc; simp [step, hc])
  | libDone => exact stuck _ (by intro a t hc; simp [step, hc]) (by intro t hc; simp [step, hc])
                 (by intro hc; simp [step, hc])
  | jobFail => exact stuck _ (by intro a t hc; simp [step, hc]) (by intro t hc; simp [step, hc])
                 (by intro hc; simp [step, hc])
  | pullDone clr => exact stuck _ (by intro a t hc; simp [step, hc]) (by intro t hc; simp [step, hc])
                      (by intro hc; simp [step, hc])

/-- Sign out with no token request, renewal or connect in flight and no
Drive job started leaves a quiet state. -/
theorem signOut_quiet (s : St) (hc : s.connected = true) (hr : s.req = none) (hn : s.renews = [])
    (hk : s.connects = []) (hj : ∀ j ∈ s.chain, j.waiting = true) : QuietOut (step s .signOut) := by
  simp only [step, hc]
  exact ⟨rfl, rfl, hr, hn, hk, hj⟩

/-- **A quiet sign-out is final**: until the user signs in again, no token
comes back and no Drive request leaves the tab. -/
theorem quiet_signOut_final (es : List Ev) (hes : ∀ e ∈ es, e ≠ .signIn) :
    ∀ s, QuietOut s → QuietOut (run s es) ∧ (run s es).outTraffic = s.outTraffic ∧
      (run s es).crossLib = s.crossLib := by
  induction es with
  | nil => intro s h; exact ⟨h, rfl, rfl⟩
  | cons e es ih =>
    intro s h
    obtain ⟨h1, h2, h3⟩ := quiet_step s e h (hes e (by simp))
    obtain ⟨g1, g2, g3⟩ := ih (fun e' he' => hes e' (by simp [he'])) _ h1
    exact ⟨g1, g2.trans h2, g3.trans h3⟩

/-! ### Proved: one token request, no orphaned caller

The comment at 2002-2006 is the promise: overlapping `gdriveAcquireToken`
calls must not orphan a popup's promise. In every reachable state, a caller
still waiting on a token (a renewal, a connect, or a flush's 401 re-grant) has
a request in flight to wait on. -/

def RPc.waitTok : RPc → Bool
  | .acq _ none => true
  | _ => false
def CPc.waitTok : CPc → Bool
  | .acq none => true
  | _ => false
def Job.waitTok : Job → Bool
  | .flush (.reauth _ _ none) _ => true
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
  rcases c with _ | ⟨w, _ | _⟩ | _ <;> rfl
theorem stampC_wait (r : Bool) (c : CPc) : (stampC r c).waitTok = false := by
  rcases c with _ | _ | _ | _ <;> (try rename_i x; cases x) <;> rfl
theorem stampJ_wait (r : Bool) (j : Job) : (stampJ r j).waitTok = false := by
  rcases j with ⟨pc, a⟩ | ⟨b⟩
  · cases pc with
    | reauth o k res => cases res <;> rfl
    | _ => rfl
  · rfl

theorem noOrphan_settle (s : St) (r : Bool) (t : Option Nat) (d : Nat) :
    NoOrphan { settle s r with token := t, denials := d } := by
  intro _
  refine ⟨?_, ?_, ?_⟩
  · intro c hc; simp [settle] at hc; obtain ⟨c', -, rfl⟩ := hc; exact stampR_wait r c'
  · intro c hc; simp [settle] at hc; obtain ⟨c', -, rfl⟩ := hc; exact stampC_wait r c'
  · intro j hj; simp [settle] at hj; obtain ⟨j', -, rfl⟩ := hj; exact stampJ_wait r j'

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
    (fetchEmail s t ok).chain = s.chain := by unfold fetchEmail; split <;> simp
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

theorem noOrphan_arm {s : St} (h : NoOrphan s) : NoOrphan (arm s) := by
  obtain ⟨a1, a2, a3, a4⟩ := arm_f s
  exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
    (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact fun c hc _ => hc)

theorem setHead_sub (s : St) (j : Job) (hj : j.waitTok = false) :
    ∀ x ∈ (setHead s j).chain, x.waitTok = true → x ∈ s.chain := by
  intro x hx hw; simp [setHead] at hx
  rcases hx with rfl | hx
  · rw [hj] at hw; cases hw
  · exact List.mem_of_mem_tail hx

theorem noOrphan_step (s : St) (e : Ev) (h : NoOrphan s) : NoOrphan (step s e) := by
  cases e with
  | gesture on =>
    simp only [step]; split
    · unfold renewCall; simp only; split
      · exact noOrphan_of h id (fun c hc _ => hc) (fun c hc _ => hc) (fun c hc _ => hc)
      · split
        · exact noOrphan_arm (noOrphan_of h id (fun c hc _ => hc) (fun c hc _ => hc) (fun c hc _ => hc))
        · refine noOrphan_of h id ?_ (fun c hc _ => hc) (fun c hc _ => hc)
          intro c hc hw; simp at hc; rcases hc with hc | rfl
          · exact hc
          · simp [RPc.waitTok] at hw
    · exact noOrphan_of h id (fun c hc _ => hc) (fun c hc _ => hc) (fun c hc _ => hc)
  | arm =>
    obtain ⟨a1, a2, a3, a4⟩ := arm_f s
    exact noOrphan_of h (by simp only [step]; rw [a1]; exact id) (by simp only [step]; rw [a2]; exact fun c hc _ => hc)
      (by simp only [step]; rw [a3]; exact fun c hc _ => hc) (by simp only [step]; rw [a4]; exact fun c hc _ => hc)
  | renewGis k ok act =>
    simp only [step]; split
    · split
      · obtain ⟨a1, a2, a3, a4⟩ := arm_f { s with renews := s.renews.eraseIdx k }
        exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => mem_eraseIdx hc)
          (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact fun c hc _ => hc)
      · exact noOrphan_req (joinOrCreate_req _ _)
    · exact h
  | renewAcq k =>
    simp only [step]; split
    · split
      · split
        · exact noOrphan_of h id (fun c hc _ => mem_eraseIdx hc) (fun c hc _ => hc) (fun c hc _ => hc)
        · obtain ⟨a1, a2, a3, a4⟩ := arm_f { s with renews := s.renews.eraseIdx k, fails := s.fails + 1 }
          exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => mem_eraseIdx hc)
            (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact fun c hc _ => hc)
      · split
        · exact noOrphan_of h id (fun c hc _ => mem_eraseIdx hc) (fun c hc _ => hc) (fun c hc _ => hc)
        · refine noOrphan_of h id ?_ (fun c hc _ => hc) (fun c hc _ => hc)
          intro c hc hw; simp at hc; rcases hc with hc | rfl
          · exact mem_eraseIdx hc
          · simp [RPc.waitTok] at hw
    · exact h
  | renewEmail k ok =>
    simp only [step]; split
    · rename_i t _
      obtain ⟨b1, b2, b3, b4⟩ := fetchEmail_f { s with renews := s.renews.eraseIdx k } t ok
      obtain ⟨a1, a2, a3, a4⟩ := pullSync_f (fetchEmail { s with renews := s.renews.eraseIdx k } t ok)
      exact noOrphan_of h (by rw [a1, b1]; exact id) (by rw [a2, b2]; exact fun c hc _ => mem_eraseIdx hc)
        (by rw [a3, b3]; exact fun c hc _ => hc) (by intro j hj hw; have := a4 j hj hw; rw [b4] at this; exact this)
    · exact h
  | tokGrant a =>
    simp only [step]; split
    · split
      · exact noOrphan_settle s true _ _
      · exact h
    · exact h
  | tokDeny =>
    simp only [step]; split
    · exact noOrphan_settle s false _ _
    · exact h
  | signIn =>
    simp only [step]; split
    · exact h
    · exact noOrphan_req (joinOrCreate_req _ _)
  | connAcq k =>
    simp only [step]; split
    · split
      · refine noOrphan_of h id (fun c hc _ => hc) ?_ (fun c hc _ => hc)
        intro c hc hw; simp at hc; rcases hc with hc | rfl
        · exact mem_eraseIdx hc
        · simp [CPc.waitTok] at hw
      · exact noOrphan_of h id (fun c hc _ => hc) (fun c hc _ => mem_eraseIdx hc) (fun c hc _ => hc)
    · exact h
  | connEmail k ok =>
    simp only [step]; split
    · rename_i t _
      obtain ⟨b1, b2, b3, b4⟩ := fetchEmail_f { s with connects := s.connects.eraseIdx k } t ok
      refine noOrphan_of h (by simp only; rw [b1]; exact id) (by simp only; rw [b2]; exact fun c hc _ => hc) ?_
        (by simp only; rw [b4]; exact fun c hc _ => hc)
      intro c hc hw; simp only at hc; rw [b3] at hc; simp at hc; rcases hc with hc | rfl
      · exact mem_eraseIdx hc
      · simp [CPc.waitTok] at hw
    · exact h
  | connSave k =>
    simp only [step]; split
    · split
      · refine noOrphan_of h id (fun c hc _ => hc) ?_ (fun c hc _ => hc)
        intro c hc hw; simp at hc; rcases hc with hc | rfl
        · exact mem_eraseIdx hc
        · simp [CPc.waitTok] at hw
      · exact noOrphan_of h id (fun c hc _ => hc) (fun c hc _ => mem_eraseIdx hc) (fun c hc _ => hc)
    · exact h
  | connFull k =>
    simp only [step]; split
    · refine noOrphan_of h id (fun c hc _ => hc) (fun c hc _ => mem_eraseIdx hc) ?_
      intro j hj hw; simp [flushSync] at hj; rcases hj with hj | rfl
      · exact hj
      · simp [Job.waitTok] at hw
    · exact h
  | signOut =>
    simp only [step]; split
    · exact h
    · exact noOrphan_of h id (fun c hc _ => hc) (fun c hc _ => hc) (fun c hc _ => hc)
  | poll wf =>
    simp only [step]; split
    · exact h
    · split
      · refine noOrphan_of h id (fun c hc _ => hc) (fun c hc _ => hc) ?_
        intro j hj hw; simp [flushSync] at hj; rcases hj with hj | rfl
        · exact hj
        · simp [Job.waitTok] at hw
      · obtain ⟨a1, a2, a3, a4⟩ := pullSync_f s
        exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
          (by rw [a3]; exact fun c hc _ => hc) a4
  | visible =>
    simp only [step]; split
    · refine noOrphan_of h id (fun c hc _ => hc) (fun c hc _ => hc) ?_
      intro j hj hw; simp [flushSync] at hj; rcases hj with hj | rfl
      · exact hj
      · simp [Job.waitTok] at hw
    · exact h
  | callPull =>
    simp only [step]; split
    · obtain ⟨a1, a2, a3, a4⟩ := pullSync_f { s with pullCalls := s.pullCalls - 1 }
      exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
        (by rw [a3]; exact fun c hc _ => hc) a4
    · exact h
  | jobStart p =>
    simp only [step]; split
    · rename_i a _ _
      split
      · obtain ⟨a1, a2, a3, a4⟩ := finish_f s a
        exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
          (by rw [a3]; exact fun c hc _ => hc) (fun j hj _ => a4 j hj)
      · obtain ⟨a1, a2, a3, a4⟩ := send_f (setHead s (.flush (.prelude s.acct) a))
        exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
          (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact setHead_sub s _ rfl)
    · split
      · exact noOrphan_of h id (fun c hc _ => hc) (fun c hc _ => hc)
          (fun j hj _ => List.mem_of_mem_tail hj)
      · obtain ⟨a1, a2, a3, a4⟩ := send_f (setHead { s with pullQueued := false } (.pull true))
        exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
          (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact setHead_sub { s with pullQueued := false } _ rfl)
    · exact h
  | preludeOk k =>
    simp only [step]; split
    · rename_i o a _ _
      split
      · obtain ⟨a1, a2, a3, a4⟩ := libSend_f (setHead s (.flush (.libWrite o) a)) o
        exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
          (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact setHead_sub s _ rfl)
      · obtain ⟨a1, a2, a3, a4⟩ := send_f (setHead s (.flush (.upload o (k - 1)) a))
        exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
          (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact setHead_sub s _ rfl)
    · exact h
  | upOk =>
    simp only [step]; split
    · rename_i o k a _ _
      split
      · obtain ⟨a1, a2, a3, a4⟩ := libSend_f (setHead s (.flush (.libWrite o) a)) o
        exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
          (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact setHead_sub s _ rfl)
      · obtain ⟨a1, a2, a3, a4⟩ := send_f (setHead s (.flush (.upload o (k - 1)) a))
        exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
          (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact setHead_sub s _ rfl)
    · exact h
  | up401 act =>
    simp only [step]; split
    · rename_i o k a _ _
      split
      · exact noOrphan_req (by simp only [setHead]; exact joinOrCreate_req s s.email)
      · obtain ⟨b1, b2, b3, b4⟩ := arm_f { s with token := none }
        obtain ⟨a1, a2, a3, a4⟩ := finish_f (arm { s with token := none }) a
        exact noOrphan_of h (by rw [a1, b1]; exact id) (by rw [a2, b2]; exact fun c hc _ => hc)
          (by rw [a3, b3]; exact fun c hc _ => hc) (fun j hj _ => by have := a4 j hj; rw [b4] at this; exact this)
    · exact h
  | reauthRes =>
    simp only [step]; split
    · rename_i o k r a _ _
      split
      · obtain ⟨a1, a2, a3, a4⟩ := send_f (setHead s (.flush (.upload o k) a))
        exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
          (by rw [a3]; exact fun c hc _ => hc) (by rw [a4]; exact setHead_sub s _ rfl)
      · obtain ⟨b1, b2, b3, b4⟩ := arm_f { s with token := none }
        obtain ⟨a1, a2, a3, a4⟩ := finish_f (arm { s with token := none }) a
        exact noOrphan_of h (by rw [a1, b1]; exact id) (by rw [a2, b2]; exact fun c hc _ => hc)
          (by rw [a3, b3]; exact fun c hc _ => hc) (fun j hj _ => by have := a4 j hj; rw [b4] at this; exact this)
    · exact h
  | libDone =>
    simp only [step]; split
    · rename_i a _ _
      obtain ⟨a1, a2, a3, a4⟩ := finish_f s a
      exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
        (by rw [a3]; exact fun c hc _ => hc) (fun j hj _ => a4 j hj)
    · exact h
  | jobFail =>
    simp only [step]; split
    all_goals first
      | exact h
      | (rename_i a _ _
         obtain ⟨a1, a2, a3, a4⟩ := finish_f s a
         exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
           (by rw [a3]; exact fun c hc _ => hc) (fun j hj _ => a4 j hj))
      | (rename_i a _ _ _
         obtain ⟨a1, a2, a3, a4⟩ := finish_f s a
         exact noOrphan_of h (by rw [a1]; exact id) (by rw [a2]; exact fun c hc _ => hc)
           (by rw [a3]; exact fun c hc _ => hc) (fun j hj _ => a4 j hj))
  | pullDone clr =>
    simp only [step]; split
    · split
      · obtain ⟨b1, b2, b3, b4⟩ := arm_f { s with token := none }
        exact noOrphan_of h (by simp only [popHead]; rw [b1]; exact id)
          (by simp only [popHead]; rw [b2]; exact fun c hc _ => hc)
          (by simp only [popHead]; rw [b3]; exact fun c hc _ => hc)
          (by simp only [popHead]; rw [b4]; exact fun j hj _ => List.mem_of_mem_tail hj)
      · exact noOrphan_of h id (fun c hc _ => hc) (fun c hc _ => hc)
          (fun j hj _ => List.mem_of_mem_tail hj)
    · exact h

/-- **No orphaned token caller**: whoever is awaiting a token has the one
request in flight to wait on (gdriveTokenInFlight, 2006-2013). -/
theorem no_orphaned_token_waiter {s : St} (h : Reachable s) : NoOrphan s := by
  induction h with
  | init => intro _; simp [init]
  | step e _ ih => exact noOrphan_step _ e ih

end WebState.DriveSession.Session
