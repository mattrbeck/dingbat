-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/index.js: adoptDriveAccount adoptGrantedToken armDriveRenewListener armDriveRenewOnGesture clearDriveToken driveCodeGrant driveEnrolled driveFetch driveLinked driveListMap driveRefreshSilently driveRegrantPopup driveRetryWait driveSessionGuard driveSessionResumed driveTokenSub driveUploadFile driveWantsUpgrade ensureDriveSignedIn flushSync flushSyncInner gdriveAcquireToken gdriveConnect gdriveFetchEmail gdriveSignOut hasUserActivation loadGisScript localSyncFiles markDelete markGameUpload markUpload parseDriveFileName pendingCount pullSync pullSyncInner readDriveLibrary readSyncBytes refreshSyncStatus rememberDriveEmail renewDriveToken resumeDriveOnBoot runExclusive runFullSync runPool saveSyncState scheduleFlush setSyncStatus startSyncTriggers syncActive syncPollTick writeDriveLibrary on:online on:offline on:visibilitychange

/-
# Google Drive sync: the upload queue and the session (web/index.js)

Two sub-models of the one machine, each carrying exactly the state its
properties need. First written on top of 7ca348ebf (the Drive sync fix
series); against dd7ba741f the same models refuted the properties below with
the `bug_*` traces in formal/FINDINGS.md (#8, #10, #11), each now a
`regress_*` theorem. Re-audited against 03f88d6c (2026-10-05), after the
token broker (92c9e49c: renewals through a refresh token, no popup;
6961bab6: a popup-flow device moved onto it by a consent screen at its next
tap; b7ddc0be: Sign out forgets the refresh token, invalid_grant signs the
device out), the parallel flush (da1d7c55) and driveFetch's retries
(fdc02cf1); then made to follow 6367e296, which fixed two of that audit's
findings (a consent re-grant for another account is refused; a refused
sign-in ends its session). Every line number below is web/index.js at
6367e296.

## `Queue`: the dirty queue, the flusher, the lamp (one account, linked)

JS: `markUpload` (3742), `scheduleFlush` (3728), `flushSync` (3790),
`runExclusive`/`syncChain` (3780-3785), `flushSyncInner` (3797-4025),
`pullSync`/`pullSyncInner` (4225-4581, opaque), `runFullSync` (4583),
`refreshSyncStatus`/`setSyncStatus` (3691-3723), the triggers
`syncPollTick`/`online`/`offline`/`visibilitychange` (5505-5534), and the
save writers that call `markUpload` after their IndexedDB write commits
(`persistSave` 7494-7522, `saveToSlot` 8039-8062).

`flushSyncInner` is split at every await that can matter to the queue:
the prelude (`driveListMap`, `readDriveLibrary`, renames, deletes: one await),
then per queued name `readSyncBytes` (the IndexedDB read itself is an event
`readSnap`, the continuation `readResume` another), `driveUploadFile` (sent
with whatever token is current at send time), the re-grant inside
`driveFetch` (2622-2646), `writeDriveLibrary`, and the final/`catch`
`saveSyncState`.

## `Session`: tokens, the broker, connect/sign-out, renewal, accounts

JS: `gdriveAcquireToken` (2277-2325, `gdriveTokenInFlight`), the broker
(`driveRefreshSilently` 2396-2424 and its shared `driveRefreshInFlight`;
`driveCodeGrant` 2486-2545, the consent screen; `driveWantsUpgrade` 2554;
`driveRegrantPopup` 2562-2572), `gdriveFetchEmail`/`adoptDriveAccount`
(2592-2609, 3163-3189), `gdriveSignOut` (2894-2910), `gdriveConnect`
(5247-5286), `armDriveRenewOnGesture` (5336) and `armDriveRenewListener`
(5347), `renewDriveToken` (5370-5439) and `driveSessionResumed` (5443),
`syncPollTick` (5505), the in-flight flush seen coarsely (it captures its
library at the start and writes it at the end, 3818 and 3989) and
`driveFetch`'s 401 path and retries (2622-2657). A session number
(`driveSession` 2257, `driveSessionGuard` 2266) that Sign out, a sign-in's
grant, a sign-in's end and an account switch each advance; the flush, the
pull, the renewal, the refresh and driveFetch's replay stop after any await
that finds it moved. `syncActive` (3192) needs a linked tab with no sign-in
mid-way; a GIS grant is kept only for the session that asked for it, or for a
sign-in waiting on it (`gdriveTokenForConnect`); a refresh's or a consent
re-grant's only for the session that asked; gdriveFetchEmail ignores an
answer about a token the tab no longer holds; a sign-in whose account cannot
be confirmed is refused.

## Abstractions (and why they do not affect the stated properties)

* Queue: every queued name is a live game's. The upload pass also skips a
  key whose game the merged library has deleted (dropped from the queue) or
  renamed away (left queued for the pull to move); that is library logic,
  modelled in DriveLibrary (`flush_uploads_only_live`), and `no_lost_upload`
  is about the keys of games that exist under their name.
* Queue: the upload pass now runs up to `SYNC_PARALLEL` keys at once
  (`runPool` 2811, 3895). Each key's segment touches only its own queue
  entry, `syncRemarked` entry, `sigs`, `rmt` and delete stamp, and a failure
  starts no further key but lets the running ones land; so what happens to
  each key is a run of this one-key-at-a-time pass with other events between
  its read, its upload and its landing, which the model already allows, and
  the properties are per key (`no_lost_upload`, `in_flight_is_queued`) or
  about the job (`mutual_exclusion`, `busy_iff_running`). A ROM Drive already
  holds (3930-3934) leaves the queue unread: its Drive copy is already the
  local one (a ROM never changes). A session another device wrote unseen
  stays queued, unsent (3936-3948, `WebState/Handoff`): what a held-back key
  does here is stay queued, which every property allows.
* Session: an account switch's grid swap (`adoptDriveAccount` ->
  `swapAccountGames`: tiles with nothing on this device but their picture go
  with the account that listed them, and that account's come back) is not
  modelled: this model has no library contents, only which account's state
  and token a flush holds, and the swap happens inside `gdriveConnect`'s
  identifying stretch, when no sync can start (`syncActive`). It is pinned by
  web/tests/drive-session.test.mjs instead.
* Queue: only `queueUp` is modelled; `queueDel`/`queueRen` and tombstones/
  renames (another model) are folded into the prelude await and into
  `libPending` (the flush proceeds with an empty `queueUp` when
  `syncState.tomb`/`ren` are non-empty, 3805). `pendingCount()` is
  `queueUp.length`; queued deletes/renames would only make the lamp *more*
  often "syncing".
* Queue: local bytes are a version counter per name (`ver`), Drive's copy is
  the version last uploaded (`drive`); FNV signatures are assumed injective
  and the "already on Drive with this sig" skip (3958-3959) is dropped:
  skipping never re-queues or un-queues anything, it only avoids a request.
  No local deletes (`ver` only grows).
* Queue: pull is opaque: it may run, fail (optionally clearing the token via
  `driveFetch`'s 401 path), and on success may queue a name
  ("reconcile upward", 4498-4509) and flip `libPending`. It does not model
  pull writing local bytes (merge logic, another model).
* Queue: the token is a Bool (live / null). How it comes back is the
  `Session` model's business; here `tokArrive` (a grant from a renewal, a
  broker refresh or `ensureDriveSignedIn`, optionally followed by the
  renewal's `driveSessionResumed` pull), `renewFail` (a spent strike,
  clearing the token at 3) and `tokLost` (any other `driveFetch` 401 that no
  refresh or popup answered) are free events; `up401 true` is a 401 a
  re-grant (the broker's, or a popup's with activation) is tried for.
* Queue: timers are Bools (armed or not) that may fire at any time; the
  3-minute poll interval is always armed (`startSyncTriggers`, never cleared).
  driveFetch's wait-and-retry on 429/5xx (2651-2657) only stretches an
  upload's time in flight.
* Queue: `runFullSync`'s save of the game in memory before it queues
  (4585-4590, new) is a `write` and a `mark` of those keys, events the model
  lets run at any time.
* Session: file contents are not modelled; the flush is a count of uploads
  plus the library it captured. The GIS popup is one in-flight request
  (`req`, with the login_hint it was issued with) resolved by `tokGrant a`
  (the account granted; with a hint, only that account, as the earlier audit
  took GIS's silent re-grant to keep it) or `tokDeny`. The broker refresh is
  one in-flight request (`rfr`, the account its refresh token is for and the
  session it was sent in) resolved by `rfrOk`/`rfrFail`. A consent screen is
  its caller's own request, answered by `renewCode`/`connCode`/`reauthCode`
  with any account or none: Google's page lets the person sign in as anyone
  when the hinted account is not signed in to that browser, and the code's
  own comments expect the account to change there (5302, 5435-5436). Whether the
  broker answers and the upgrade offer is not resting (`offerSet`), and the
  broker's back-off (`backoffSet`), are free flags. `navigator.onLine`, the
  GIS script load, driveTokenStale() and `hasUserActivation()` are event
  parameters. `appUpdating` is false.
* Session: `ensureDriveSignedIn` (5292) joins the same requests (the refresh,
  forced; the GIS request or a consent screen with activation) as a renewal
  and is not modelled separately; the trace `regress_refresh_of_refused_signin`
  uses `arm` for the refresh it can start.
* Queue: `markUpload`'s `driveEnrolled()`/`parseDriveFileName` guards are
  taken as passing (only syncable keys of an enrolled device are modelled).
  `markDelete`/`markGameUpload` are not modelled (see the report).
  `tap` is not guarded by the Sync now button's `disabled` (the Settings
  Sync button, 2996, never is).
* Session: the re-grant is modelled on uploads only; a 401 in the prelude
  or the library write is folded into `jobFail`. `resumeDriveOnBoot` is the
  initial state (expired persisted token, no refresh token: arm the gesture
  listener and wait), and its probe is `offerSet`.
* Session: the pull is coarse (it sends at its start); its own session checks
  are in the JS but not needed here, since the pull writes no library in this
  model; its 401 path is `pullDone true` (the token dropped, then
  armDriveRenewOnGesture), its own refresh or re-grant on the way is not
  modelled (another joiner of the requests above). `ensureDriveSignedIn`'s
  fall-through to `gdriveConnect` while linked is not modelled (`signIn`
  requires a signed-out tab); its grant is a connect's grant and takes a new
  session all the same. A library write the merge left unchanged is skipped
  since da1d7c55 (`libraryUnchanged` 3988); skipping only drops a request.
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
  while the tab is signed out and no sign-in is running (no assumption).
* `Session.no_cross_account`: no flush writes the library it captured under
  one account into another account's Drive, and `active_is_own_account`: a
  syncing tab holds its own account's token, in every reachable state where
  no broker refresh was adopted for another account (`stray` false; a
  consent re-grant never is since 6367e296). (Both via `Session.Safe`.)
* `Session.renewals_le_gestures`: popup renewals never outnumber user
  gestures; `silent_le_arms` + `renewal_never_arms`: every broker renewal is
  paid for by a call of armDriveRenewOnGesture, which no renewal, refresh or
  grant makes, so renewal cannot loop by itself.
* `Session.no_orphaned_token_waiter`: one GIS request and one broker
  refresh; every caller awaiting either has it in flight.
* `Session.broker_renews_without_gesture`: once the consent screen gave a
  refresh token, a lost token comes back with no gesture.

The findings' traces, fixed: `Queue.regress_redirty_kept`,
`Session.regress_renewal_after_signout`, `regress_signed_out_quiet`,
`regress_renewal_rollover`, `regress_no_cross_account` (+ `_then_sync`,
`_broker`), `regress_unconfirmed_signin`; and the 2026-10-05 findings, fixed
in 6367e296: `regress_consent_regrant_refused`,
`regress_consent_renewal_refused` (+ `consent_regrant_same_account`: the
upgrade for the linked account still works), `regress_refresh_of_refused_signin`.

Still refuted (not fixed here):
* `Queue.bug_spinner_without_work`, `bug_spinner_after_renewal`: "Syncing"
  spins, with the Sync now button disabled, while nothing is in flight (a
  device with no refresh token, or the broker down).
* `Session.bug_one_popup_two_strikes`: two renewals share one popup and one
  refusal costs two of the three strikes (popup flow only).
* `Session.bug_refresh_token_outlives_its_account` (found modelling the
  6367e296 fix): a broker sign-in that tokeninfo confirms for another
  token the tab came to hold meanwhile keeps its own refresh token, and
  every later broker renewal adopts that other account's token (two
  sign-ins at once plus a stale flush's 401 in the window; very unlikely).
  It is the only way left for a stray grant: `codeAccept_stray_same`.
-/
namespace WebState.DriveSession

/-- A function update, for version maps. -/
def upd (f : Nat → Nat) (i v : Nat) : Nat → Nat := fun j => if j = i then v else f j

namespace Queue

/-- `syncStatus` (3670). -/
inductive Status where
  | idle | syncing | done | offline | paused
  deriving DecidableEq, Repr

/-- `flushSyncInner`'s program counter (3797). -/
inductive FPc where
  /-- queued behind `syncChain`, body not entered -/
  | start
  /-- awaiting `driveListMap` / `readDriveLibrary` / renames / deletes (3815-3892) -/
  | prelude
  /-- awaiting `readSyncBytes(name)` (3935); `snap` = the IndexedDB read has run and saw it -/
  | read (name : Nat) (rest : List Nat) (snap : Option Nat)
  /-- awaiting `driveUploadFile(name, bytes)` (3960); `withTok`: gdriveToken was non-null at send -/
  | upload (name : Nat) (v : Nat) (withTok : Bool) (rest : List Nat)
  /-- `driveFetch` got 401: awaiting the broker's refresh, then (with
  activation) `driveRegrantPopup()` (2627-2631) -/
  | reauth (name : Nat) (v : Nat) (rest : List Nat)
  /-- awaiting `writeDriveLibrary(lib, await driveListMap())` (3988-3990) -/
  | libWrite
  /-- awaiting `saveSyncState()` on success (4013) -/
  | okSave
  /-- in `catch`: `syncBusy = false` done, awaiting `saveSyncState()` (4017-4024) -/
  | failSave
  deriving DecidableEq, Repr

/-- A job on `syncChain`. `after`: the caller chained `.then(() => pullSync(...))`
(poll/online/visible: silent; `runFullSync`: not silent). -/
inductive Job where
  | flush (pc : FPc) (after : Option Bool)
  | pull (started : Bool) (silent : Bool)
  deriving DecidableEq, Repr

/-- `runFullSync` (4583) after its `syncActive()` check. -/
inductive Rfs where
  /-- awaiting `localSyncFiles()` -/
  | listing
  /-- awaiting `saveSyncState()` -/
  | saving
  deriving DecidableEq, Repr

structure St where
  tok        : Bool          -- !!gdriveToken (syncActive, 3192)
  fails      : Nat           -- driveRenewFails (5329)
  ver        : Nat → Nat     -- the bytes under each IndexedDB key, as a version
  drive      : Nat → Nat     -- the version Drive holds for that name
  marks      : List Nat      -- committed writes whose markUpload has not run yet
  queueUp    : List Nat      -- syncState.queueUp
  remarked   : List Nat      -- syncRemarked: queued names saved again since their flush item began
  libPending : Bool          -- syncState.tomb.length || syncState.ren.length
  busy       : Bool          -- syncBusy (3058)
  status     : Status        -- syncStatus (3670)
  doneArmed  : Bool          -- syncDoneTimer (3062)
  debounce   : Bool          -- syncTimer (3059)
  cap        : Bool          -- syncCapTimer (3060)
  chain      : List Job      -- syncChain: head runs, the rest wait (runExclusive 3781)
  pullQueued : Bool          -- pullQueued (3787)
  pullCalls  : List Bool     -- pending `.then(() => pullSync(...))` / renewal's pullSync
  rfs        : List Rfs      -- runFullSync calls in flight
  held       : List Nat      -- keys that hold bytes (localSyncFiles)

def init : St :=
  { tok := true, fails := 0, ver := fun _ => 0, drive := fun _ => 0, marks := [],
    queueUp := [], remarked := [], libPending := false, busy := false,
    status := .idle, doneArmed := false, debounce := false, cap := false,
    chain := [], pullQueued := false, pullCalls := [], rfs := [], held := [] }

inductive Ev where
  /-- a save/state/frame write commits (persistSave 7504, saveToSlot 8049) -/
  | write (i : Nat)
  /-- its `markUpload(i)` continuation runs (7517, 8055) -/
  | mark (i : Nat)
  /-- syncTimer / syncCapTimer fire `flushSync` (3731-3733) -/
  | debounce | cap
  /-- syncPollTick (5505) -/
  | poll
  /-- window `online` (5521), `offline` (5526), visibilitychange->visible (5529) -/
  | online | offline | visible
  /-- a Sync button with a live token ("Sync now" 5620, Settings 2996): runFullSync -/
  | tap
  /-- runFullSync continuation #k resumes -/
  | rfsStep (k : Nat)
  /-- a token is granted (a renewal, a broker refresh); `pullAfter`: the renewal's
  `driveSessionResumed` tail (5383-5386, 5430-5438, 5443-5450) -/
  | tokArrive (pullAfter : Bool)
  /-- some other driveFetch hit 401 and no re-grant answered (2632-2640) -/
  | tokLost
  /-- renewDriveToken's catch (5408-5427) -/
  | renewFail
  /-- syncDoneTimer fires (3697) -/
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
  /-- the upload got 401; `activation`: a re-grant is tried (a refresh token
  for the broker, or user activation for a popup, 2627-2631) -/
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

/-- setSyncStatus (3691): also (re)arms the "done" -> idle timer. -/
def setStatus (s : St) (x : Status) : St := { s with status := x, doneArmed := x == .done }

/-- refreshSyncStatus (3714-3723), with driveLinked() true. -/
def refresh (s : St) : St :=
  if !s.tok && decide (s.fails ≥ 3) && decide (pending s > 0) then setStatus s .paused
  else if s.busy || decide (pending s > 0) then setStatus s .syncing
  else if s.status == .syncing then setStatus s .done
  else s

/-- scheduleFlush (3728-3735). -/
def scheduleFlush (s : St) : St := refresh { s with debounce := true, cap := true }

/-- markUpload: a name already queued is remembered as re-dirtied
(`syncRemarked.add(name)`), since the running flush may already have read it. -/
def markUpload (s : St) (i : Nat) : St :=
  let s := if i ∈ s.queueUp then { s with remarked := i :: s.remarked }
           else { s with queueUp := s.queueUp ++ [i] }
  scheduleFlush s

/-- flushSync (3790-3796): disarm both timers, append to the chain. -/
def flushSync (s : St) (after : Option Bool) : St :=
  { s with debounce := false, cap := false, chain := s.chain ++ [.flush .start after] }

/-- pullSync (4225-4232). -/
def pullSync (s : St) (silent : Bool) : St :=
  if s.pullQueued then s else { s with pullQueued := true, chain := s.chain ++ [.pull false silent] }

def setHead (s : St) (j : Job) : St := { s with chain := j :: s.chain.tail }
def popHead (s : St) : St := { s with chain := s.chain.tail }

/-- the flush's run promise settles; a chained `.then(pullSync)` becomes pending -/
def finish (s : St) (after : Option Bool) : St :=
  match after with
  | some sil => { popHead s with pullCalls := s.pullCalls ++ [sil] }
  | none => popHead s

/-- `catch (e) { syncBusy = false; await saveSyncState(); ... }` (4016-4024) -/
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
  -- syncPollTick (5513-5515): `if (!syncActive()) return; pending ? flush.then(pull) : pull`
  | .poll => if !s.tok then s else if pending s > 0 then flushSync s (some true) else pullSync s true
  -- online (5521-5525)
  | .online => if !s.tok then s else flushSync (refresh s) (some true)
  -- offline (5526-5528)
  | .offline => if pending s > 0 then setStatus s .offline else s
  -- visibilitychange (5533)
  | .visible => if s.tok then flushSync s (some true) else s
  -- runFullSync (4583-4596): `if (!syncActive()) return; ... await localSyncFiles()`
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
          -- flushSyncInner 3798-3813
          if !s.tok then finish s after
          else if pending s = 0 && !s.libPending then finish (refresh s) after
          else setHead (setStatus { s with busy := true } .syncing) (.flush .prelude after)
      | .pull false sil :: _ =>
          -- pullSync's job 4228-4231, pullSyncInner 4234-4239
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
          -- 3949-3986: Drive has v; sigs[name] = sig; queueUp.filter(name) unless re-dirtied
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
2629: e.g. a gamepad player after the hour, with no refresh token or the
broker down), a new save makes
refreshSyncStatus say "syncing" (it only says "paused" after 3 renewal
strikes), the debounce flush returns at `if (!syncActive()) return` (3798)
without touching the lamp, and nothing is left to run: the spinner turns
with nothing in flight, nothing scheduled, and the home Sync button disabled
(`accountSync.disabled = kind === "syncing"`, 5608). The poll does
nothing either (5513). -/
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
(`driveSessionResumed` 5449): the pull's refreshSyncStatus keeps "syncing", nothing flushes, and the
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
still waiting to start: `runExclusive` (3781) is the only way into
`flushSyncInner`/`pullSyncInner`, so no flush overlaps another flush or a
pull, and no name is being uploaded by two flushes. -/
theorem mutual_exclusion {s : St} (h : Reachable s) :
    ∀ j ∈ s.chain.tail, j.waiting = true :=
  (reachable_inv h).tailWaiting

/-- `queueUp` never holds a name twice (markUpload 3745, markGameUpload 3765,
runFullSync 4592 and the pull's reconcile 4506 all check `includes` first), so a flush's snapshot
uploads each name at most once. -/
theorem queue_nodup {s : St} (h : Reachable s) : s.queueUp.Nodup :=
  (reachable_inv h).qNodup

/-- `syncBusy` is exactly "a flush or pull body is between its start and its
end" (3812, 4014, 4017, 4238, 4571, 4577). -/
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
const syncRemarked = new Set();                                  // 3741
// markUpload (3742):
if (!syncState.queueUp.includes(name)) syncState.queueUp.push(name);
else syncRemarked.add(name);
// flushSyncInner, top of the queueUp loop body, before readSyncBytes (3926):
syncRemarked.delete(name);
// ...and the filter after the upload (3983):
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
  /-- awaiting `driveRefreshSilently()` (5383); `gest`: called by the gesture
  listener, not by armDriveRenewOnGesture (`{ gesture: false }`); `res` once
  the refresh settled (at once, `some false`, with no refresh token or while
  the broker backs off) -/
  | silent (was : Bool) (ep : Nat) (gest : Bool) (res : Option Bool)
  /-- awaiting `loadGisScript()` (5396) -/
  | gis (was : Bool) (ep : Nat)
  /-- awaiting `driveRegrantPopup()` (5406): the token flow's shared
  `gdriveAcquireToken("")` (`code = none`), or the consent screen,
  `driveCodeGrant` issued in session `iss` (`code = some iss`, its own popup);
  `up` = the renewal's `upgrade`; `res` once it settled -/
  | acq (was : Bool) (up : Bool) (ep : Nat) (code : Option Nat) (res : Option Bool)
  /-- awaiting `gdriveFetchEmail()` in `driveSessionResumed` (5444); the
  tokeninfo fetch carried `tokAt` -/
  | email (tokAt : Option Nat) (ep : Nat)
  deriving DecidableEq, Repr

/-- gdriveConnect's continuation. `acq` and `email` are the stretch where
`driveConnecting` counts it. -/
inductive CPc where
  /-- awaiting the grant: `gdriveAcquireToken(undefined, email, { connect: true })`
  (`code = false`, the one shared request) or `driveCodeGrant(email, { connect: true })`
  (`code = true`, its own consent popup through the broker) -/
  | acq (code : Bool) (res : Option Bool)
  /-- awaiting `gdriveFetchEmail()` -/
  | email (tokAt : Option Nat)
  /-- awaiting `saveSyncState()` -/
  | save
  /-- runFullSync: awaiting its persist, `localSyncFiles()` + `saveSyncState()` -/
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
  /-- driveFetch got 401: awaiting `driveRefreshSilently({ force: true })` -/
  | silent (own : Nat) (ep : Nat) (k : Nat) (res : Option Bool)
  /-- ...that failed, with activation: awaiting `driveRegrantPopup()`
  (`code` as in `RPc.acq`) -/
  | reauth (own : Nat) (ep : Nat) (k : Nat) (code : Option Nat) (res : Option Bool)
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
  refresh    : Option Nat       -- syncState.refresh, as the account whose grant it is
  offer      : Bool             -- the broker answers and the upgrade offer is not resting
  backoff    : Bool             -- Date.now() < driveBrokerRetryAt
  fails      : Nat              -- driveRenewFails
  armed      : Bool             -- driveRenewArmed
  req        : Option (Option Nat × Nat) -- gdriveTokenInFlight: its login_hint and the session it was issued in
  rfr        : Option (Nat × Nat) -- driveRefreshInFlight: its refresh token's account, and `issued`
  renews     : List RPc         -- renewDriveToken calls in flight
  connects   : List CPc         -- gdriveConnect calls in flight
  chain      : List Job         -- syncChain (head runs)
  pullQueued : Bool             -- pullQueued
  pullCalls  : Nat              -- pending `.then(() => pullSync())`
  epoch      : Nat              -- driveSession
  -- ghosts
  gestures   : Nat              -- window pointerdown/keydown/touchstart events
  renewCalls : Nat              -- renewDriveToken() calls from the gesture listener
  armCalls   : Nat              -- armDriveRenewOnGesture() calls
  silentCalls : Nat             -- renewDriveToken({ gesture: false }) calls
  denials    : Nat              -- token requests refused (popup closed/blocked, grant gone)
  outTraffic : Bool             -- a Drive request left with a live token while signed out, no sign-in running
  crossLib   : Bool             -- a library captured under one account was written to another account's Drive
  stray      : Bool             -- a grant no sign-in asked for (since 6367e296 only a broker
                                -- refresh can be) was adopted for an account other than the loaded one
  deriving DecidableEq, Repr

/-- Reload more than an hour after the last grant, account 1 linked on the
popup flow (no refresh token), the broker not (yet) answering:
resumeDriveOnBoot finds the persisted token expired and arms the gesture
renewal. -/
def init : St :=
  { connected := true, token := none, email := some 1, acct := 1, refresh := none,
    offer := false, backoff := false, fails := 0, armed := true,
    req := none, rfr := none, renews := [], connects := [], chain := [], pullQueued := false,
    pullCalls := 0, epoch := 0, gestures := 0, renewCalls := 0, armCalls := 0, silentCalls := 0,
    denials := 0, outTraffic := false, crossLib := false, stray := false }

inductive Ev where
  /-- a window pointerdown/keydown/touchstart reaches the armed capture listener;
  `online` = navigator.onLine at renewDriveToken's check -/
  | gesture (online : Bool)
  /-- armDriveRenewOnGesture from syncPollTick, visibilitychange or
  resumeDriveOnBoot (driveFetch's 401 path and the pull's are inside
  `up401`/`reauthRes`/`pullDone`) -/
  | arm (online : Bool)
  /-- armDriveRenewListener after a probe found the upgrade on offer
  (resumeDriveOnBoot 5459, syncPollTick 5509) -/
  | armListen
  /-- `probeDriveBroker` settles, or the upgrade offer's day of rest ends -/
  | offerSet (ok : Bool)
  /-- `driveBrokerRetryAt` passes (or is set by a refresh failure) -/
  | backoffSet (b : Bool)
  /-- renewal #k resumes after `driveRefreshSilently()`; `stale` =
  driveTokenStale(), `act` = hasUserActivation() -/
  | renewSilent (k : Nat) (stale : Bool) (act : Bool)
  /-- renewal #k: loadGisScript settled (`ok`), hasUserActivation() = `act` -/
  | renewGis (k : Nat) (ok : Bool) (act : Bool)
  /-- renewal #k's consent screen and broker exchange answer: a grant for
  account `g`, or a refusal (`none`: closed, declined, cancelled by a newer
  one, the exchange failed) -/
  | renewCode (k : Nat) (g : Option Nat)
  /-- renewal #k resumes after `driveRegrantPopup()` settled; `stale` as above -/
  | renewAcq (k : Nat) (stale : Bool)
  /-- renewal #k's gdriveFetchEmail settled; tokeninfo `ok` -/
  | renewEmail (k : Nat) (ok : Bool)
  /-- the broker's /oauth/refresh answers 200 -/
  | rfrOk
  /-- ...fails; `gone`: 400 invalid_grant -/
  | rfrFail (gone : Bool)
  /-- the GIS callback delivers a token for account `a` -/
  | tokGrant (a : Nat)
  /-- error_callback / resp.error -/
  | tokDeny
  /-- a Sign in button: gdriveConnect; `broker` = the probe's answer -/
  | signIn (broker : Bool)
  /-- connect #k's consent screen and exchange answer (account `g`, or none) -/
  | connCode (k : Nat) (g : Option Nat)
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
  /-- driveFetch's 429/5xx wait (driveRetryWait) ends: `live()`, then the
  request again -/
  | retry
  | up401
  /-- the flush's re-grant step resumes; `act` = hasUserActivation() -/
  | reauthRes (act : Bool)
  /-- the flush's consent screen and exchange answer -/
  | reauthCode (g : Option Nat)
  | libDone
  /-- a request of the running flush failed (network/HTTP): catch -/
  | jobFail
  /-- the pull settled; `clear`: its driveFetch hit 401 and no re-grant came -/
  | pullDone (clear : Bool)
  deriving DecidableEq, Repr

/-- armDriveRenewListener (5347). -/
def armL (s : St) : St :=
  if s.armed || !s.connected || decide (s.fails ≥ 3) then s else { s with armed := true }

/-- gdriveAcquireToken: join the request in flight, or issue one with this
hint, recording the session it was issued in. -/
def joinOrCreate (s : St) (hint : Option Nat) : St :=
  if s.req.isSome then s else { s with req := some (hint, s.epoch) }

/-- driveRefreshSilently goes to the broker (2397-2398): a refresh token,
and not backing off unless forced. -/
def refreshNow (s : St) (force : Bool) : Bool := s.refresh.isSome && (force || !s.backoff)

/-- `driveRefreshInFlight ??= ...` (2399): join the refresh in flight, or send
one with the refresh token held now, in this session. -/
def joinR (s : St) : St :=
  match s.rfr, s.refresh with
  | none, some r => { s with rfr := some (r, s.epoch) }
  | _, _ => s

/-- driveWantsUpgrade (2554). -/
def wantsUpgrade (s : St) : Bool := s.connected && s.refresh.isNone && s.offer

def CPc.ident : CPc → Bool
  | .acq _ _ => true
  | .email _ => true
  | _ => false

/-- A sign-in that has its grant and has not yet learned whose it is. -/
def CPc.granted : CPc → Bool
  | .acq _ (some true) => true
  | .email _ => true
  | _ => false

/-- `driveConnecting > 0`: a sign-in between asking for a token and knowing whose it is. -/
def identifying (s : St) : Bool := s.connects.any CPc.ident

/-- `gdriveTokenForConnect`: a sign-in is waiting on the request in flight. -/
def connectWaits (s : St) : Bool := s.connects.contains (.acq false none)

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

/-- renewDriveToken's first segment, up to `await driveRefreshSilently()`
(5370-5383). `gest`: from the gesture listener (`renewCall` counts it). -/
def renewStart (s : St) (online : Bool) (gest : Bool) : St :=
  if !s.connected then s
  else if !online then armL s
  else if refreshNow s false then
    { joinR s with renews := s.renews ++ [.silent s.token.isNone s.epoch gest none] }
  else { s with renews := s.renews ++ [.silent s.token.isNone s.epoch gest (some false)] }

def renewCall (s : St) (online : Bool) (gest : Bool) : St :=
  renewStart (if gest then { s with renewCalls := s.renewCalls + 1 }
              else { s with silentCalls := s.silentCalls + 1 }) online gest

/-- armDriveRenewOnGesture (5336-5343): renew now through the broker when
this device has a refresh token and the broker is not backing off, else arm
the listener. -/
def armOG (s : St) (online : Bool) : St :=
  let s := { s with armCalls := s.armCalls + 1 }
  if !s.connected then s
  else if s.refresh.isSome && !s.backoff then renewCall s online false
  else armL s

/-- gdriveSignOut (2894-2910): a new session, the refresh token forgotten. -/
def signOutFx (s : St) : St :=
  { s with refresh := none, email := none, connected := false, token := none,
           epoch := s.epoch + 1 }

/-- driveCodeGrant's tail for a re-grant (`connect` false, 2522-2543): since
6367e296 the grant's account is learned first (`driveTokenSub` 2576-2584, its
await folded into the answer, which `g` is), then it is kept only in the
session that asked, on a linked tab, and only for the loaded account
(2529-2537; a tokeninfo that fails is a refusal, `none`); the token and the
refresh token replaced, the broker's back-off cleared. Then
driveRegrantPopup (2565-2571): a failure rests the offer. The second
component is the outcome. -/
def codeAccept (s : St) (iss : Nat) (g : Option Nat) : St × Bool :=
  match g with
  | some a =>
    if s.connected && iss == s.epoch && a == s.acct then
      ({ s with token := some a, refresh := some a, backoff := false }, true)
    else ({ s with offer := false }, false)
  | none => ({ s with offer := false }, false)

def stampR (r : Bool) : RPc → RPc
  | .acq w u ep none none => .acq w u ep none (some r)
  | c => c
def stampC (r : Bool) : CPc → CPc
  | .acq false none => .acq false (some r)
  | c => c
def stampJ (r : Bool) : Job → Job
  | .flush (.reauth o ep k none none) a => .flush (.reauth o ep k none (some r)) a
  | j => j

/-- the GIS request settles: every caller awaiting it resumes with the outcome -/
def settle (s : St) (r : Bool) : St :=
  { s with req := none, renews := s.renews.map (stampR r), connects := s.connects.map (stampC r),
           chain := s.chain.map (stampJ r) }

def stampRS (r : Bool) : RPc → RPc
  | .silent w ep g none => .silent w ep g (some r)
  | c => c
def stampJS (r : Bool) : Job → Job
  | .flush (.silent o ep k none) a => .flush (.silent o ep k (some r)) a
  | j => j

/-- the broker refresh settles: every caller awaiting it resumes -/
def settleR (s : St) (r : Bool) : St :=
  { s with rfr := none, renews := s.renews.map (stampRS r), chain := s.chain.map (stampJS r) }

/-- The JS each branch follows (web/index.js at 6367e296): the gesture
listener (`armDriveRenewListener` 5347-5365) and `renewDriveToken` 5370-5439
(its `over()` 5378-5381, the silent refresh 5383-5387, the gesture-less fallback
5388, the upgrade check 5390-5392, the script 5396-5400, activation 5404,
the popup 5406, the consent decline 5413-5416, the strikes 5419-5427, the
tail 5430-5438) and `driveSessionResumed` 5443-5450; `armDriveRenewOnGesture`
5336-5343; `driveRefreshSilently` 2396-2424 (its `stale()` 2404, adoption
2408-2411, invalid_grant 2415-2418, back-off 2420); `driveCodeGrant` 2486-2545
(its account and session checks 2528-2537, the refresh token 2542-2543) and `driveRegrantPopup` 2562-2572; the GIS
callback in `gdriveAcquireToken` 2277-2325 (the session rule at 2304-2308);
`gdriveConnect` 5247-5286 (its grant 5255-5261, the refusal 5269-5277, the
new session 5278); `gdriveSignOut` 2894-2910; `syncPollTick` 5505-5516,
`online` 5521, `visibilitychange` 5529; `flushSyncInner` 3797-4025
(`live()` after every await) and `pullSync` 4225; `driveFetch` 2615-2660
(the 401 path 2622-2646, its replay's session check 2644, the 429/5xx
retries 2651-2657); `gdriveFetchEmail` 2592-2609 and `adoptDriveAccount`
3163-3189. -/
def step (s : St) : Ev → St
  | .gesture on =>
      let s := { s with gestures := s.gestures + 1 }
      if s.armed then renewCall { s with armed := false } on true else s
  | .arm on => armOG s on
  | .armListen => armL s
  | .offerSet ok => { s with offer := ok }
  | .backoffSet b => { s with backoff := b }
  | .renewSilent k stale act =>
      match s.renews[k]? with
      | some (.silent was ep gest (some r)) =>
          let s := { s with renews := s.renews.eraseIdx k }
          if r then
            -- `driveRenewFails = 0; if (wasSignedOut && !over()) await driveSessionResumed(over)`
            let s := { s with fails := 0 }
            if was && !(ep ≠ s.epoch || !s.connected) then
              { s with renews := s.renews ++ [.email s.token ep] }
            else s
          else if !gest then armL s
          else
            let up := wantsUpgrade s
            -- `if (!upgrade && !driveTokenStale()) return;`
            if !up && !(stale || s.token.isNone) then s
            else if up then
              if !act then armL s
              else { s with renews := s.renews ++ [.acq was true ep (some s.epoch) none] }
            else { s with renews := s.renews ++ [.gis was ep] }
      | _ => s
  | .renewGis k ok act =>
      match s.renews[k]? with
      | some (.gis was ep) =>
          let s := { s with renews := s.renews.eraseIdx k }
          if !ok then armL s
          -- `if (over()) return;` (signed out or in again while the script loaded)
          else if ep ≠ s.epoch || !s.connected then s
          else if !act then armL s
          -- driveRegrantPopup asks driveWantsUpgrade() again, now
          else if wantsUpgrade s then
            { s with renews := s.renews ++ [.acq was false ep (some s.epoch) none] }
          else let s := joinOrCreate s s.email
               { s with renews := s.renews ++ [.acq was false ep none none] }
      | _ => s
  | .renewCode k g =>
      match s.renews[k]? with
      | some (.acq was up ep (some iss) none) =>
          let r := codeAccept s iss g
          { r.1 with renews := r.1.renews.set k (.acq was up ep (some iss) (some r.2)) }
      | _ => s
  | .renewAcq k stale =>
      match s.renews[k]? with
      | some (.acq was up ep code (some r)) =>
          let s := { s with renews := s.renews.eraseIdx k }
          -- every path starts `if (over()) return;`: a refusal caused by the
          -- session ending is not a strike
          if ep ≠ s.epoch || !s.connected then s
          else if !r then
            match code with
            -- DriveUpgradeDeclined: no strike; the token flow takes the next tap
            | some _ => if stale || s.token.isNone then armL s else s
            | none =>
              let s := { s with fails := s.fails + 1 }
              if s.fails ≥ 3 then { s with token := none } else armL s
          else
            let s := { s with fails := 0 }
            if !was && !up then s else { s with renews := s.renews ++ [.email s.token ep] }
      | _ => s
  | .renewEmail k ok =>
      match s.renews[k]? with
      | some (.email t ep) =>
          let s := fetchEmail { s with renews := s.renews.eraseIdx k } t ok
          if ep ≠ s.epoch || !s.connected then s else pullSync s
      | _ => s
  | .rfrOk =>
      match s.rfr with
      | some (r, e) =>
          -- `if (stale()) return false;`: the old session's answer is refused
          if !s.connected || e ≠ s.epoch then settleR s false
          else settleR { s with token := some r, stray := s.stray || r != s.acct } true
      | none => s
  | .rfrFail gone =>
      match s.rfr with
      | some (r, e) =>
          -- invalid_grant for the refresh token still held: signed out
          if gone && s.connected && e = s.epoch && s.refresh = some r then settleR (signOutFx s) false
          else settleR { s with backoff := true } false
      | none => s
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
  | .signIn broker =>
      if s.connected then s
      else if broker then { s with connects := s.connects ++ [.acq true none] }
      else let s := joinOrCreate s s.email
           { s with connects := s.connects ++ [.acq false none] }
  | .connCode k g =>
      match s.connects[k]? with
      | some (.acq true none) =>
          match g with
          -- `if (connect) driveSession++;` the token and the refresh token adopted
          | some a => { s with token := some a, refresh := some a, backoff := false,
                               epoch := s.epoch + 1, connects := s.connects.set k (.acq true (some true)) }
          | none => { s with connects := s.connects.set k (.acq true (some false)) }
      | _ => s
  | .connAcq k =>
      match s.connects[k]? with
      | some (.acq c (some r)) =>
          let s := { s with connects := s.connects.eraseIdx k }
          -- the token flow: `syncState.refresh = null` (5260)
          if r then { s with connects := s.connects ++ [.email s.token],
                             refresh := if c then s.refresh else none }
          else s
      | _ => s
  | .connEmail k ok =>
      match s.connects[k]? with
      | some (.email t) =>
          let s := { s with connects := s.connects.eraseIdx k }
          -- `if (!acct && syncState.acct) { syncState.refresh = null; clearDriveToken();
          -- driveSession++; throw }` (5269-5277; the new session since 6367e296)
          if !identified s t ok then { s with token := none, refresh := none, epoch := s.epoch + 1 }
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
      -- rememberDriveEmail(null), connected = false, clearDriveToken(), the
      -- refresh token forgotten, a new session. syncChain and renewals untouched.
      if !s.connected then s else signOutFx s
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
  | .retry =>
      match s.chain with
      | .flush (.upload _ ep _) after :: _ => if ep ≠ s.epoch then finish s after else send s
      | .flush (.libWrite o ep) after :: _ => if ep ≠ s.epoch then finish s after else libSend s o
      | _ => s
  | .up401 =>
      match s.chain with
      | .flush (.upload o ep k) after :: _ =>
          -- signed out since it left: `clearDriveToken(); armDriveRenewOnGesture(); throw`
          if !s.connected then finish (armOG { s with token := none } true) after
          else if refreshNow s true then setHead (joinR s) (.flush (.silent o ep k none) after)
          else setHead s (.flush (.silent o ep k (some false)) after)
      | _ => s
  | .reauthRes act =>
      match s.chain with
      | .flush (.silent o ep k (some r)) after :: _ =>
          if r then
            -- the replay goes only in the session the request started in
            if ep ≠ s.epoch then finish s after
            else send (setHead s (.flush (.upload o ep k) after))
          -- `wasLinked && !driveLinked()`: this device signed itself out
          else if !s.connected then finish s after
          else if !act then finish (armOG { s with token := none } true) after
          else if wantsUpgrade s then setHead s (.flush (.reauth o ep k (some s.epoch) none) after)
          else setHead (joinOrCreate s s.email) (.flush (.reauth o ep k none none) after)
      | .flush (.reauth o ep k _ (some r)) after :: _ =>
          if !r then
            (if !s.connected then finish s after
             else finish (armOG { s with token := none } true) after)
          else if ep ≠ s.epoch then finish s after
          else send (setHead s (.flush (.upload o ep k) after))
      | _ => s
  | .reauthCode g =>
      match s.chain with
      | .flush (.reauth o ep k (some iss) none) after :: _ =>
          let r := codeAccept s iss g
          setHead r.1 (.flush (.reauth o ep k (some iss) (some r.2)) after)
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
      | .pull true :: _ => popHead (if clr then armOG { s with token := none } true else s)
      | _ => s

inductive Reachable : St → Prop
  | init : Reachable init
  | step {s} (e : Ev) : Reachable s → Reachable (step s e)

def run (s : St) (es : List Ev) : St := es.foldl step s

theorem reachable_run (es : List Ev) : ∀ s, Reachable s → Reachable (run s es) := by
  induction es with
  | nil => intro s h; exact h
  | cons e es ih => intro s h; exact ih _ (Reachable.step e h)

/-! ### The findings' traces, against the code at 6367e296 -/

/-- A renewal in flight survives Sign out (null-token variant: a background
flush's 401 cleared the token and armed the renewal while Settings was open).
The user's first input is on "Sign out": its pointerdown runs the capture
listener first (no refresh token: the broker is not asked) and the silent
popup opens; then its click runs gdriveSignOut. The grant lands after.
Against dd7ba741f the GIS callback set and persisted the token, the renewal
re-remembered the email and pulled, with `connected = false`
(`bug_renewal_resurrects_token`). -/
def resurrectTrace : List Ev :=
  [.gesture true, .renewSilent 0 true true, .renewGis 0 true true, .signOut, .tokGrant 1,
   .renewAcq 0 true, .renewEmail 0 true, .jobStart true]

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

/-- The token is back (a gesture renewal on the popup flow), and the pull
its tail starts has run. -/
def signedInPrefix : List Ev :=
  [.gesture true, .renewSilent 0 true true, .renewGis 0 true true, .tokGrant 1,
   .renewAcq 0 true, .renewEmail 0 true, .jobStart true, .pullDone false]

/-- The rollover variant: a live but stale token, armed by the poll;
wasSignedOut is false so there is no immediate pull, but against dd7ba741f the
new token outlived the sign-out and the next poll used it. -/
def resurrectRolloverTrace : List Ev :=
  signedInPrefix ++
  [.arm true, .gesture true, .renewSilent 0 true true, .renewGis 0 true true, .signOut,
   .tokGrant 1, .renewAcq 0 true, .poll false, .jobStart true]

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
  signedInPrefix ++
  [.poll true, .jobStart true, .preludeOk 1,
   .signOut, .signIn false, .tokGrant 2, .connAcq 0, .connEmail 0 true,
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

/-- The same, signing in again through the broker (one consent screen). -/
theorem regress_no_cross_account_broker :
    let s := run init (signedInPrefix ++
      [.poll true, .jobStart true, .preludeOk 1,
       .signOut, .signIn true, .connCode 0 (some 2), .connAcq 0, .connEmail 0 true,
       .upOk, .connSave 0, .connFull 0, .jobStart true, .preludeOk 0])
    s.crossLib = false ∧ s.acct = 2 ∧ s.refresh = some 2 ∧
    s.chain = [.flush (.libWrite 2 s.epoch) true] := by
  decide +kernel

/-- Two renewals can be in flight at once (the arm flag is cleared before the
first one's attempt, and a poll/visibilitychange/401 may re-arm while its
popup is open), and the second joins the first's popup. One refused popup
then costs two of the three strikes. Not fixed; with a refresh token the
broker renews instead and no popup opens. -/
def strikeTrace : List Ev :=
  [.gesture true, .renewSilent 0 true true, .renewGis 0 true true, .arm true, .gesture true,
   .renewSilent 1 true true, .renewGis 1 true true, .tokDeny, .renewAcq 0 true, .renewAcq 0 true]

theorem bug_one_popup_two_strikes :
    let s := run init strikeTrace
    s.denials = 1 ∧ s.fails = 2 ∧ s.renewCalls = 2 := by
  decide

/-- Found while modelling the session fix: a sign-in whose tokeninfo request
fails (account unknown) against dd7ba741f still became `connected` with the
previous account's queues and tombstones loaded under the new account's
token, and its runFullSync wrote them into that account's Drive, with no
race needed. Now the sign-in is refused and the token dropped. -/
def unconfirmedTrace : List Ev :=
  signedInPrefix ++ [.signOut, .signIn false, .tokGrant 2, .connAcq 0, .connEmail 0 false]

theorem regress_unconfirmed_signin :
    let s := run init unconfirmedTrace
    s.connected = false ∧ s.token = none ∧ s.acct = 1 ∧ s.connects = [] ∧ s.crossLib = false := by
  decide

/-- The broker at work: once the consent screen gave this device a refresh
token (the first tap after the broker answered), a token lost to a pull's
401 comes back with no gesture at all: armDriveRenewOnGesture renews through
the broker, the renewal resumes the session and pulls. -/
def brokerTrace : List Ev :=
  signedInPrefix ++
  [.offerSet true, .armListen, .gesture true, .renewSilent 0 false true, .renewCode 0 (some 1),
   .renewAcq 0 false, .renewEmail 0 true, .jobStart true, .pullDone true,
   .rfrOk, .renewSilent 0 false false, .renewEmail 0 true]

theorem broker_renews_without_gesture :
    let s := run init brokerTrace
    s.refresh = some 1 ∧ s.token = some 1 ∧ s.gestures = 2 ∧ s.renewCalls = 2 ∧
    s.silentCalls = 1 ∧ s.armCalls = 1 ∧ s.chain = [.pull false] ∧ s.stray = false := by
  decide

/-! ### The 2026-10-05 findings, fixed in 6367e296 -/

/-- A popup-flow device (account 1, no refresh token) is syncing once the
broker answers. An upload of the flush gets 401 (the hour is up) while the
person is tapping: driveFetch asks the broker (no refresh token: no), then,
with activation, `driveRegrantPopup`, which opens Google's consent screen
(`driveWantsUpgrade`). The person ends up granting account 2 there (the
hinted account is not signed in to Google in this browser, so the page asks
for a sign-in and they use another one). Against 03f88d6c `driveCodeGrant`
checked only that the session was the one that asked, adopted account 2's
token and refresh token, and the flush's replay wrote account 1's library,
tombstones and renames into account 2's Drive; nothing on driveFetch's path
ever re-identified the account, so every later sync did the same
(`bug_consent_regrant_crosses_accounts`). -/
def consentTrace : List Ev :=
  signedInPrefix ++
  [.offerSet true, .poll true, .jobStart true, .preludeOk 1, .up401,
   .reauthRes true, .reauthCode (some 2), .reauthRes true, .upOk]

/-- **Fixed: the other account's grant is refused** (tokeninfo's `sub` is
learned before anything is adopted, 2528-2537): nothing adopted, no refresh
token stored, the flush ends on driveFetch's catch (token dropped, renewal
armed), and nothing reaches account 2's Drive. -/
theorem regress_consent_regrant_refused :
    let s := run init consentTrace
    s.crossLib = false ∧ s.stray = false ∧ s.acct = 1 ∧ s.token = none ∧ s.refresh = none ∧
    s.chain = [] := by
  decide

/-- The renewal's own consent screen (the upgrade offered at the first tap,
with a live token) landed on another account mid-flush, and the flush wrote
on with it (`bug_consent_renewal_crosses_accounts`). -/
def consentRenewTrace : List Ev :=
  signedInPrefix ++
  [.offerSet true, .armListen, .poll true, .jobStart true, .preludeOk 1,
   .gesture true, .renewSilent 0 false true, .renewCode 0 (some 2), .upOk]

/-- **Fixed: refused, and the flush finishes with account 1's own token.** -/
theorem regress_consent_renewal_refused :
    let s := run init consentRenewTrace
    s.crossLib = false ∧ s.stray = false ∧ s.acct = 1 ∧ s.token = some 1 ∧ s.refresh = none := by
  decide

/-- ...and a consent re-grant for the linked account is adopted as before:
the upgrade still moves the device onto the broker. -/
theorem consent_regrant_same_account :
    let s := run init (signedInPrefix ++
      [.offerSet true, .poll true, .jobStart true, .preludeOk 1, .up401,
       .reauthRes true, .reauthCode (some 1), .reauthRes true, .upOk])
    s.crossLib = false ∧ s.token = some 1 ∧ s.refresh = some 1 ∧
    s.chain = [.flush (.libWrite 1 s.epoch) true] := by
  decide

/-- Two sign-ins started while signed out (two taps on Sign in; the second's
consent screen opened after the first's code had arrived, so it did not
cancel it): the first finishes as account 1; the second's grant (account 2)
lands, a new session, its refresh token stored. A silent refresh starts in
that session (in the JS, a tap on a Drive-only tile calls ensureDriveSignedIn,
which refreshes whenever no sync is active, as during a sign-in). The second
sign-in's tokeninfo request then fails and it is refused. Against 03f88d6c
the refusal took no new session, the refresh landed as current, and account
2's token was adopted with account 1 loaded (`bug_refresh_of_refused_signin`). -/
def unconfirmedRefreshTrace : List Ev :=
  [.signOut, .signIn true, .signIn true, .connCode 0 (some 1), .connAcq 0, .connEmail 1 true,
   .connCode 0 (some 2), .arm true, .connAcq 0, .connEmail 1 false, .rfrOk,
   .poll true, .jobStart true, .preludeOk 0]

/-- **Fixed: the refusal ends its session** (5275), so the refresh's answer
is stale and refused; nothing syncs. -/
theorem regress_refresh_of_refused_signin :
    let s := run init unconfirmedRefreshTrace
    s.crossLib = false ∧ s.stray = false ∧ s.token = none ∧ s.acct = 1 ∧ s.chain = [] := by
  decide

/-! ### Still refuted after the fix (found while modelling it) -/

/-- **A refresh token kept from a sign-in can outlive the account it was
for.** Two sign-ins started while signed out: the token flow's (account 1)
finishes; the broker's grant (account 2) lands, a new session, its token
and refresh token stored. A flush from before the sign-out, still out, gets
401: driveFetch's forced refresh fails (the broker is down), and with
activation the token flow re-grants account 1 in the current session (the
linked tab's request, hinted with account 1). The broker sign-in's tokeninfo
then asks about the token the tab holds now, account 1's, and confirms it:
the sign-in completes as account 1, keeping account 2's refresh token
(gdriveConnect clears `syncState.refresh` only on the token flow, 5260, or
on refusal). From then on every broker renewal adopts account 2's token
with account 1 loaded and nothing identifying (driveRefreshSilently keeps a
refresh's answer for any linked session it was sent in, 2403-2410), and the
next sync writes account 1's library into account 2's Drive. Needs two
sign-ins at once, a stale flush's 401 with activation and the broker down
inside one sign-in's window: very unlikely. -/
def unboundRefreshTrace : List Ev :=
  signedInPrefix ++
  [.poll true, .jobStart true, .preludeOk 1,
   .signOut, .signIn true, .signIn false, .tokGrant 1, .connAcq 1, .connEmail 1 true,
   .connCode 0 (some 2), .up401, .rfrFail false, .reauthRes true, .tokGrant 1, .reauthRes true,
   .connAcq 0, .connEmail 1 true,
   .backoffSet false, .arm true, .rfrOk, .poll true, .jobStart true, .preludeOk 0]

theorem bug_refresh_token_outlives_its_account :
    let s := run init unboundRefreshTrace
    s.crossLib = true ∧ s.stray = true ∧ s.acct = 1 ∧ s.refresh = some 2 ∧ s.token = some 2 := by
  decide +kernel

/-! ### Proved: a popup renewal needs a gesture, and nothing renews in a loop

`renewCalls` counts renewDriveToken calls from the gesture listener (the
only ones that may open a popup), `silentCalls` the broker-only ones
armDriveRenewOnGesture makes (`{ gesture: false }`), `armCalls` the calls of
armDriveRenewOnGesture itself. A renewal's own fallbacks go to
armDriveRenewListener, never back through armDriveRenewOnGesture (5337-5342,
5388), so a failing broker cannot loop: every silent renewal is paid for by
an armDriveRenewOnGesture call, and those come only from outside a renewal
(the poll, visibilitychange, boot, and a 401 that no re-grant answered). -/

/-- The four counters. -/
def cnt (s : St) : Nat × Nat × Nat × Nat := (s.renewCalls, s.gestures, s.armCalls, s.silentCalls)

section counters
variable (s : St)
@[simp] theorem armL_cnt : cnt (armL s) = cnt s := by unfold armL; split <;> rfl
@[simp] theorem join_cnt (h : Option Nat) : cnt (joinOrCreate s h) = cnt s := by
  unfold joinOrCreate; split <;> rfl
@[simp] theorem joinR_cnt : cnt (joinR s) = cnt s := by unfold joinR; split <;> rfl
@[simp] theorem send_cnt : cnt (send s) = cnt s := by unfold send; split <;> rfl
@[simp] theorem libSend_cnt (o : Nat) : cnt (libSend s o) = cnt s := by
  have := send_cnt s
  unfold libSend; simp only; split
  · split
    · exact this
    · simp only [cnt] at this ⊢; exact this
  · exact this
@[simp] theorem fetchEmail_cnt (t : Option Nat) (ok : Bool) : cnt (fetchEmail s t ok) = cnt s := by
  unfold fetchEmail; split
  · split
    · split <;> rfl
    · rfl
  · rfl
@[simp] theorem pullSync_cnt : cnt (pullSync s) = cnt s := by unfold pullSync; split <;> rfl
@[simp] theorem finish_cnt (a : Bool) : cnt (finish s a) = cnt s := by unfold finish; split <;> rfl
@[simp] theorem settle_cnt (r : Bool) : cnt (settle s r) = cnt s := rfl
@[simp] theorem settleR_cnt (r : Bool) : cnt (settleR s r) = cnt s := rfl
@[simp] theorem setHead_cnt (j : Job) : cnt (setHead s j) = cnt s := rfl
@[simp] theorem popHead_cnt : cnt (popHead s) = cnt s := rfl
@[simp] theorem signOutFx_cnt : cnt (signOutFx s) = cnt s := rfl
@[simp] theorem codeAccept_cnt (iss : Nat) (g : Option Nat) : cnt (codeAccept s iss g).1 = cnt s := by
  unfold codeAccept; split
  · split <;> rfl
  · rfl
end counters

section counterFields
variable (s : St)
@[simp] theorem armL_cnt_renewCalls : (armL s).renewCalls = s.renewCalls := congrArg Prod.fst (armL_cnt s)
@[simp] theorem armL_cnt_gestures : (armL s).gestures = s.gestures := congrArg (·.2.1) (armL_cnt s)
@[simp] theorem armL_cnt_armCalls : (armL s).armCalls = s.armCalls := congrArg (·.2.2.1) (armL_cnt s)
@[simp] theorem armL_cnt_silentCalls : (armL s).silentCalls = s.silentCalls := congrArg (·.2.2.2) (armL_cnt s)
@[simp] theorem join_cnt_renewCalls (h : Option Nat) : (joinOrCreate s h).renewCalls = s.renewCalls := congrArg Prod.fst (join_cnt s h)
@[simp] theorem join_cnt_gestures (h : Option Nat) : (joinOrCreate s h).gestures = s.gestures := congrArg (·.2.1) (join_cnt s h)
@[simp] theorem join_cnt_armCalls (h : Option Nat) : (joinOrCreate s h).armCalls = s.armCalls := congrArg (·.2.2.1) (join_cnt s h)
@[simp] theorem join_cnt_silentCalls (h : Option Nat) : (joinOrCreate s h).silentCalls = s.silentCalls := congrArg (·.2.2.2) (join_cnt s h)
@[simp] theorem joinR_cnt_renewCalls : (joinR s).renewCalls = s.renewCalls := congrArg Prod.fst (joinR_cnt s)
@[simp] theorem joinR_cnt_gestures : (joinR s).gestures = s.gestures := congrArg (·.2.1) (joinR_cnt s)
@[simp] theorem joinR_cnt_armCalls : (joinR s).armCalls = s.armCalls := congrArg (·.2.2.1) (joinR_cnt s)
@[simp] theorem joinR_cnt_silentCalls : (joinR s).silentCalls = s.silentCalls := congrArg (·.2.2.2) (joinR_cnt s)
@[simp] theorem send_cnt_renewCalls : (send s).renewCalls = s.renewCalls := congrArg Prod.fst (send_cnt s)
@[simp] theorem send_cnt_gestures : (send s).gestures = s.gestures := congrArg (·.2.1) (send_cnt s)
@[simp] theorem send_cnt_armCalls : (send s).armCalls = s.armCalls := congrArg (·.2.2.1) (send_cnt s)
@[simp] theorem send_cnt_silentCalls : (send s).silentCalls = s.silentCalls := congrArg (·.2.2.2) (send_cnt s)
@[simp] theorem libSend_cnt_renewCalls (o : Nat) : (libSend s o).renewCalls = s.renewCalls := congrArg Prod.fst (libSend_cnt s o)
@[simp] theorem libSend_cnt_gestures (o : Nat) : (libSend s o).gestures = s.gestures := congrArg (·.2.1) (libSend_cnt s o)
@[simp] theorem libSend_cnt_armCalls (o : Nat) : (libSend s o).armCalls = s.armCalls := congrArg (·.2.2.1) (libSend_cnt s o)
@[simp] theorem libSend_cnt_silentCalls (o : Nat) : (libSend s o).silentCalls = s.silentCalls := congrArg (·.2.2.2) (libSend_cnt s o)
@[simp] theorem fetchEmail_cnt_renewCalls (t : Option Nat) (ok : Bool) : (fetchEmail s t ok).renewCalls = s.renewCalls := congrArg Prod.fst (fetchEmail_cnt s t ok)
@[simp] theorem fetchEmail_cnt_gestures (t : Option Nat) (ok : Bool) : (fetchEmail s t ok).gestures = s.gestures := congrArg (·.2.1) (fetchEmail_cnt s t ok)
@[simp] theorem fetchEmail_cnt_armCalls (t : Option Nat) (ok : Bool) : (fetchEmail s t ok).armCalls = s.armCalls := congrArg (·.2.2.1) (fetchEmail_cnt s t ok)
@[simp] theorem fetchEmail_cnt_silentCalls (t : Option Nat) (ok : Bool) : (fetchEmail s t ok).silentCalls = s.silentCalls := congrArg (·.2.2.2) (fetchEmail_cnt s t ok)
@[simp] theorem pullSync_cnt_renewCalls : (pullSync s).renewCalls = s.renewCalls := congrArg Prod.fst (pullSync_cnt s)
@[simp] theorem pullSync_cnt_gestures : (pullSync s).gestures = s.gestures := congrArg (·.2.1) (pullSync_cnt s)
@[simp] theorem pullSync_cnt_armCalls : (pullSync s).armCalls = s.armCalls := congrArg (·.2.2.1) (pullSync_cnt s)
@[simp] theorem pullSync_cnt_silentCalls : (pullSync s).silentCalls = s.silentCalls := congrArg (·.2.2.2) (pullSync_cnt s)
@[simp] theorem finish_cnt_renewCalls (a : Bool) : (finish s a).renewCalls = s.renewCalls := congrArg Prod.fst (finish_cnt s a)
@[simp] theorem finish_cnt_gestures (a : Bool) : (finish s a).gestures = s.gestures := congrArg (·.2.1) (finish_cnt s a)
@[simp] theorem finish_cnt_armCalls (a : Bool) : (finish s a).armCalls = s.armCalls := congrArg (·.2.2.1) (finish_cnt s a)
@[simp] theorem finish_cnt_silentCalls (a : Bool) : (finish s a).silentCalls = s.silentCalls := congrArg (·.2.2.2) (finish_cnt s a)
@[simp] theorem settle_cnt_renewCalls (r : Bool) : (settle s r).renewCalls = s.renewCalls := congrArg Prod.fst (settle_cnt s r)
@[simp] theorem settle_cnt_gestures (r : Bool) : (settle s r).gestures = s.gestures := congrArg (·.2.1) (settle_cnt s r)
@[simp] theorem settle_cnt_armCalls (r : Bool) : (settle s r).armCalls = s.armCalls := congrArg (·.2.2.1) (settle_cnt s r)
@[simp] theorem settle_cnt_silentCalls (r : Bool) : (settle s r).silentCalls = s.silentCalls := congrArg (·.2.2.2) (settle_cnt s r)
@[simp] theorem settleR_cnt_renewCalls (r : Bool) : (settleR s r).renewCalls = s.renewCalls := congrArg Prod.fst (settleR_cnt s r)
@[simp] theorem settleR_cnt_gestures (r : Bool) : (settleR s r).gestures = s.gestures := congrArg (·.2.1) (settleR_cnt s r)
@[simp] theorem settleR_cnt_armCalls (r : Bool) : (settleR s r).armCalls = s.armCalls := congrArg (·.2.2.1) (settleR_cnt s r)
@[simp] theorem settleR_cnt_silentCalls (r : Bool) : (settleR s r).silentCalls = s.silentCalls := congrArg (·.2.2.2) (settleR_cnt s r)
@[simp] theorem setHead_cnt_renewCalls (j : Job) : (setHead s j).renewCalls = s.renewCalls := congrArg Prod.fst (setHead_cnt s j)
@[simp] theorem setHead_cnt_gestures (j : Job) : (setHead s j).gestures = s.gestures := congrArg (·.2.1) (setHead_cnt s j)
@[simp] theorem setHead_cnt_armCalls (j : Job) : (setHead s j).armCalls = s.armCalls := congrArg (·.2.2.1) (setHead_cnt s j)
@[simp] theorem setHead_cnt_silentCalls (j : Job) : (setHead s j).silentCalls = s.silentCalls := congrArg (·.2.2.2) (setHead_cnt s j)
@[simp] theorem popHead_cnt_renewCalls : (popHead s).renewCalls = s.renewCalls := congrArg Prod.fst (popHead_cnt s)
@[simp] theorem popHead_cnt_gestures : (popHead s).gestures = s.gestures := congrArg (·.2.1) (popHead_cnt s)
@[simp] theorem popHead_cnt_armCalls : (popHead s).armCalls = s.armCalls := congrArg (·.2.2.1) (popHead_cnt s)
@[simp] theorem popHead_cnt_silentCalls : (popHead s).silentCalls = s.silentCalls := congrArg (·.2.2.2) (popHead_cnt s)
@[simp] theorem signOutFx_cnt_renewCalls : (signOutFx s).renewCalls = s.renewCalls := congrArg Prod.fst (signOutFx_cnt s)
@[simp] theorem signOutFx_cnt_gestures : (signOutFx s).gestures = s.gestures := congrArg (·.2.1) (signOutFx_cnt s)
@[simp] theorem signOutFx_cnt_armCalls : (signOutFx s).armCalls = s.armCalls := congrArg (·.2.2.1) (signOutFx_cnt s)
@[simp] theorem signOutFx_cnt_silentCalls : (signOutFx s).silentCalls = s.silentCalls := congrArg (·.2.2.2) (signOutFx_cnt s)
@[simp] theorem codeAccept_cnt_renewCalls (iss : Nat) (g : Option Nat) : ((codeAccept s iss g).1).renewCalls = s.renewCalls := congrArg Prod.fst (codeAccept_cnt s iss g)
@[simp] theorem codeAccept_cnt_gestures (iss : Nat) (g : Option Nat) : ((codeAccept s iss g).1).gestures = s.gestures := congrArg (·.2.1) (codeAccept_cnt s iss g)
@[simp] theorem codeAccept_cnt_armCalls (iss : Nat) (g : Option Nat) : ((codeAccept s iss g).1).armCalls = s.armCalls := congrArg (·.2.2.1) (codeAccept_cnt s iss g)
@[simp] theorem codeAccept_cnt_silentCalls (iss : Nat) (g : Option Nat) : ((codeAccept s iss g).1).silentCalls = s.silentCalls := congrArg (·.2.2.2) (codeAccept_cnt s iss g)
end counterFields

theorem cnt_eq {s t : St} : cnt s = cnt t ↔
    s.renewCalls = t.renewCalls ∧ s.gestures = t.gestures ∧ s.armCalls = t.armCalls ∧
    s.silentCalls = t.silentCalls := by
  simp [cnt]

/-- A renewal from armDriveRenewOnGesture's broker path. -/
theorem renewCall_silent_cnt (s : St) (on : Bool) :
    (renewCall s on false).renewCalls = s.renewCalls ∧ (renewCall s on false).gestures = s.gestures ∧
    (renewCall s on false).armCalls = s.armCalls ∧
    (renewCall s on false).silentCalls = s.silentCalls + 1 := by
  unfold renewCall renewStart
  simp only [Bool.false_eq_true, ite_false]
  repeat' split
  all_goals simp

/-- armDriveRenewOnGesture: one call, at most one silent renewal. -/
theorem armOG_cnt (s : St) (on : Bool) :
    (armOG s on).renewCalls = s.renewCalls ∧ (armOG s on).gestures = s.gestures ∧
    (armOG s on).armCalls = s.armCalls + 1 ∧ (armOG s on).silentCalls ≤ s.silentCalls + 1 := by
  unfold armOG
  simp only
  split
  · simp
  · split
    · obtain ⟨a, b, c, d⟩ := renewCall_silent_cnt { s with armCalls := s.armCalls + 1 } on
      simp only at a b c d; omega
    · simp

/-- The events that resume a renewal, settle a token or refresh request, or
answer a consent screen: none of them calls armDriveRenewOnGesture or starts
a renewal. -/
def Ev.renewalSide : Ev → Bool
  | .renewSilent .. | .renewGis .. | .renewCode .. | .renewAcq .. | .renewEmail ..
  | .rfrOk | .rfrFail _ | .tokGrant _ | .tokDeny => true
  | _ => false

theorem renewal_never_arms (s : St) (e : Ev) (he : e.renewalSide = true) :
    cnt (step s e) = cnt s := by
  cases e <;> simp [Ev.renewalSide] at he <;> simp only [step] <;>
    (repeat' split) <;> simp [cnt]

/-- The events that may call armDriveRenewOnGesture: the trigger itself, and
the 401 paths of a flush and of a pull. -/
def Ev.armsOG : Ev → Bool
  | .arm _ | .up401 | .reauthRes _ | .pullDone _ => true
  | _ => false

theorem step_cnt_same (s : St) (e : Ev) (h1 : ∀ on, e ≠ .gesture on) (h2 : e.armsOG = false) :
    cnt (step s e) = cnt s := by
  cases e <;> simp [Ev.armsOG] at h2 <;> (try exact absurd rfl (h1 _)) <;> simp only [step] <;>
    (repeat' split) <;> simp [cnt, flushSync]

/-- What a call of armDriveRenewOnGesture (or none) does to the counters. -/
def ArmStep (s t : St) : Prop :=
  t.renewCalls = s.renewCalls ∧ t.gestures = s.gestures ∧
  ((t.armCalls = s.armCalls ∧ t.silentCalls = s.silentCalls) ∨
   (t.armCalls = s.armCalls + 1 ∧ t.silentCalls ≤ s.silentCalls + 1))

theorem armStep_same {s t : St} (h : cnt t = cnt s) : ArmStep s t := by
  simp only [cnt, Prod.mk.injEq] at h
  exact ⟨h.1, h.2.1, Or.inl h.2.2⟩

theorem armStep_armOG {s t : St} (h : cnt t = cnt s) (on : Bool) : ArmStep s (armOG t on) := by
  simp only [cnt, Prod.mk.injEq] at h
  obtain ⟨a, b, c, d⟩ := armOG_cnt t on
  exact ⟨by omega, by omega, Or.inr ⟨by omega, by omega⟩⟩

theorem armStep_finish {s t : St} (h : ArmStep s t) (a : Bool) : ArmStep s (finish t a) := by
  have := finish_cnt t a; simp only [cnt, Prod.mk.injEq] at this
  obtain ⟨h1, h2, h3⟩ := h
  refine ⟨by omega, by omega, ?_⟩
  rcases h3 with ⟨x, y⟩ | ⟨x, y⟩
  · exact Or.inl ⟨by omega, by omega⟩
  · exact Or.inr ⟨by omega, by omega⟩

theorem armStep_popHead {s t : St} (h : ArmStep s t) : ArmStep s (popHead t) := h

theorem step_cnt_arm (s : St) (e : Ev) (h : e.armsOG = true) : ArmStep s (step s e) := by
  cases e <;> simp [Ev.armsOG] at h <;> simp only [step] <;> (repeat' split) <;>
    first
    | exact armStep_armOG rfl _
    | exact armStep_finish (armStep_armOG rfl _) _
    | exact armStep_popHead (armStep_armOG rfl _)
    | (apply armStep_same; simp [cnt])

theorem gesture_cnt (s : St) (on : Bool) :
    (step s (.gesture on)).renewCalls ≤ s.renewCalls + 1 ∧
    (step s (.gesture on)).gestures = s.gestures + 1 ∧
    (step s (.gesture on)).armCalls = s.armCalls ∧
    (step s (.gesture on)).silentCalls = s.silentCalls := by
  simp only [step]; split
  · unfold renewCall renewStart; simp only [ite_true]
    repeat' split
    all_goals simp
  · simp

/-- **Popup renewals never outnumber user gestures**: only the gesture
listener starts one. -/
theorem renewals_le_gestures {s : St} (h : Reachable s) : s.renewCalls ≤ s.gestures := by
  induction h with
  | init => simp [init]
  | @step s e _ ih =>
    by_cases hg : ∃ on, e = .gesture on
    · obtain ⟨on, rfl⟩ := hg
      have := gesture_cnt s on; omega
    · have hg' : ∀ on, e ≠ .gesture on := fun on h' => hg ⟨on, h'⟩
      cases ha : e.armsOG
      · have := step_cnt_same s e hg' ha; simp only [cnt, Prod.mk.injEq] at this; omega
      · have := step_cnt_arm s e ha; obtain ⟨a, b, -⟩ := this; omega

/-- **Every silent renewal is paid for by a call of armDriveRenewOnGesture**,
and (`renewal_never_arms`) no renewal, refresh or grant makes such a call:
the broker path cannot loop on its own. -/
theorem silent_le_arms {s : St} (h : Reachable s) : s.silentCalls ≤ s.armCalls := by
  induction h with
  | init => simp [init]
  | @step s e _ ih =>
    by_cases hg : ∃ on, e = .gesture on
    · obtain ⟨on, rfl⟩ := hg
      have := gesture_cnt s on; omega
    · have hg' : ∀ on, e ≠ .gesture on := fun on h' => hg ⟨on, h'⟩
      cases ha : e.armsOG
      · have := step_cnt_same s e hg' ha; simp only [cnt, Prod.mk.injEq] at this; omega
      · obtain ⟨-, -, h3⟩ := step_cnt_arm s e ha
        rcases h3 with ⟨x, y⟩ | ⟨x, y⟩ <;> omega

/-! ### Proved: one token request, one refresh, no orphaned caller

Overlapping `gdriveAcquireToken` calls must not orphan a popup's promise, and
overlapping `driveRefreshSilently` calls share `driveRefreshInFlight`. In every
reachable state, a caller still waiting on a token (a renewal, a connect, or
a flush's 401 re-grant) has the GIS request in flight to wait on, and one
waiting on the broker (a renewal, a flush's 401) has the refresh in flight.
A consent screen (`driveCodeGrant`) is its own request, carried by its
caller; a newer one cancels an older one's wait (`waitForDriveCode`), which
is a refusal (`renewCode`/`connCode`/`reauthCode` with `none`), not an orphan. -/

def RPc.waitTok : RPc → Bool
  | .acq _ _ _ none none => true
  | _ => false
def CPc.waitTok : CPc → Bool
  | .acq false none => true
  | _ => false
def Job.waitTok : Job → Bool
  | .flush (.reauth _ _ _ none none) _ => true
  | _ => false
def RPc.waitR : RPc → Bool
  | .silent _ _ _ none => true
  | _ => false
def Job.waitR : Job → Bool
  | .flush (.silent _ _ _ none) _ => true
  | _ => false

def NoOrphan (s : St) : Prop :=
  (s.req = none → (∀ c ∈ s.renews, c.waitTok = false) ∧ (∀ c ∈ s.connects, c.waitTok = false) ∧
    (∀ j ∈ s.chain, j.waitTok = false)) ∧
  (s.rfr = none → (∀ c ∈ s.renews, c.waitR = false) ∧ (∀ j ∈ s.chain, j.waitR = false))

/-- `l'`'s members satisfying `P` were all in `l`. -/
def Sub {α : Type} (P : α → Bool) (l' l : List α) : Prop := ∀ c ∈ l', P c = true → c ∈ l

namespace Sub
variable {α : Type} {P : α → Bool}
theorem refl (l : List α) : Sub P l l := fun _ h _ => h
theorem erase (l : List α) (k : Nat) : Sub P (l.eraseIdx k) l :=
  fun _ h _ => List.mem_of_mem_eraseIdx h
theorem tail (l : List α) : Sub P l.tail l := fun _ h _ => List.mem_of_mem_tail h
theorem app {l' l : List α} (h : Sub P l' l) {x : α} (hx : P x = false) : Sub P (l' ++ [x]) l := by
  intro c hc hw
  rcases List.mem_append.1 hc with hc | hc
  · exact h c hc hw
  · rw [List.mem_singleton.1 hc, hx] at hw; cases hw
theorem cons {l' l : List α} (h : Sub P l' l) {x : α} (hx : P x = false) : Sub P (x :: l') l := by
  intro c hc hw
  rcases List.mem_cons.1 hc with rfl | hc
  · rw [hx] at hw; cases hw
  · exact h c hc hw
theorem set (l : List α) (k : Nat) {x : α} (hx : P x = false) : Sub P (l.set k x) l := by
  intro c hc hw
  rcases List.mem_or_eq_of_mem_set hc with hc | rfl
  · exact hc
  · rw [hx] at hw; cases hw
theorem map (l : List α) {f : α → α} (hf : ∀ c, P (f c) = true → f c = c) : Sub P (l.map f) l := by
  intro c hc hw
  obtain ⟨c', hc', rfl⟩ := List.mem_map.1 hc
  rw [hf c' hw]; exact hc'
theorem trans {l'' l' l : List α} (h1 : Sub P l'' l') (h2 : Sub P l' l) : Sub P l'' l :=
  fun c hc hw => h2 c (h1 c hc hw) hw
end Sub

theorem noOrphan_frame {s s' : St} (h : NoOrphan s)
    (hG : s'.req.isSome = true ∨ (s'.req = s.req ∧ Sub RPc.waitTok s'.renews s.renews ∧
        Sub CPc.waitTok s'.connects s.connects ∧ Sub Job.waitTok s'.chain s.chain))
    (hR : s'.rfr.isSome = true ∨ (s'.rfr = s.rfr ∧ Sub RPc.waitR s'.renews s.renews ∧
        Sub Job.waitR s'.chain s.chain)) : NoOrphan s' := by
  obtain ⟨hG0, hR0⟩ := h
  constructor
  · intro hn
    rcases hG with e | ⟨e, a, b, c⟩
    · rw [hn] at e; cases e
    · obtain ⟨a0, b0, c0⟩ := hG0 (e ▸ hn)
      refine ⟨fun x hx => ?_, fun x hx => ?_, fun x hx => ?_⟩
      · cases hw : x.waitTok
        · rfl
        · have := a0 x (a x hx hw); rw [hw] at this; exact this
      · cases hw : x.waitTok
        · rfl
        · have := b0 x (b x hx hw); rw [hw] at this; exact this
      · cases hw : x.waitTok
        · rfl
        · have := c0 x (c x hx hw); rw [hw] at this; exact this
  · intro hn
    rcases hR with e | ⟨e, a, c⟩
    · rw [hn] at e; cases e
    · obtain ⟨a0, c0⟩ := hR0 (e ▸ hn)
      refine ⟨fun x hx => ?_, fun x hx => ?_⟩
      · cases hw : x.waitR
        · rfl
        · have := a0 x (a x hx hw); rw [hw] at this; exact this
      · cases hw : x.waitR
        · rfl
        · have := c0 x (c x hx hw); rw [hw] at this; exact this

/-- The frame most steps stay inside: no request changed, and each list a
`Sub` of the old one for both kinds of waiter. -/
theorem noOrphan_lists {s s' : St} (h : NoOrphan s) (hq : s'.req = s.req) (hf : s'.rfr = s.rfr)
    (hr : ∀ c ∈ s'.renews, c.waitTok = true ∨ c.waitR = true → c ∈ s.renews)
    (hc : Sub CPc.waitTok s'.connects s.connects)
    (hj : ∀ j ∈ s'.chain, j.waitTok = true ∨ j.waitR = true → j ∈ s.chain) : NoOrphan s' :=
  noOrphan_frame h (Or.inr ⟨hq, fun c m w => hr c m (Or.inl w), hc, fun j m w => hj j m (Or.inl w)⟩)
    (Or.inr ⟨hf, fun c m w => hr c m (Or.inr w), fun j m w => hj j m (Or.inr w)⟩)

/-- Nothing about requests or waiters changed. -/
theorem noOrphan_same {s s' : St} (h : NoOrphan s) (hq : s'.req = s.req) (hf : s'.rfr = s.rfr)
    (hr : s'.renews = s.renews) (hc : s'.connects = s.connects) (hj : s'.chain = s.chain) : NoOrphan s' :=
  noOrphan_lists h hq hf (fun c m _ => hr ▸ m) (by rw [hc]; exact Sub.refl _) (fun j m _ => hj ▸ m)

/-- The renews list changed by dropping or appending non-waiters. -/
theorem noOrphan_renews {s : St} (h : NoOrphan s) (l : List RPc)
    (hl : ∀ c ∈ l, c.waitTok = true ∨ c.waitR = true → c ∈ s.renews) :
    NoOrphan { s with renews := l } :=
  noOrphan_lists h rfl rfl hl (Sub.refl _) (fun _ m _ => m)

theorem noOrphan_connects {s : St} (h : NoOrphan s) (l : List CPc) (hl : Sub CPc.waitTok l s.connects) :
    NoOrphan { s with connects := l } :=
  noOrphan_lists h rfl rfl (fun _ m _ => m) hl (fun _ m _ => m)

theorem noOrphan_chain {s : St} (h : NoOrphan s) (l : List Job)
    (hl : ∀ j ∈ l, j.waitTok = true ∨ j.waitR = true → j ∈ s.chain) :
    NoOrphan { s with chain := l } :=
  noOrphan_lists h rfl rfl (fun _ m _ => m) (Sub.refl _) hl

/-- Membership facts for the list shapes the steps build. -/
theorem sub2_erase {α : Type} (P Q : α → Bool) (l : List α) (k : Nat) :
    ∀ c ∈ l.eraseIdx k, P c = true ∨ Q c = true → c ∈ l := fun _ m _ => List.mem_of_mem_eraseIdx m
theorem sub2_app {α : Type} {P Q : α → Bool} {l' l : List α}
    (h : ∀ c ∈ l', P c = true ∨ Q c = true → c ∈ l) {x : α} (hp : P x = false) (hq : Q x = false) :
    ∀ c ∈ l' ++ [x], P c = true ∨ Q c = true → c ∈ l := by
  intro c hc hw
  rcases List.mem_append.1 hc with hc | hc
  · exact h c hc hw
  · rw [List.mem_singleton.1 hc, hp, hq] at hw; simp at hw
theorem sub2_set {α : Type} {P Q : α → Bool} (l : List α) (k : Nat) {x : α}
    (hp : P x = false) (hq : Q x = false) :
    ∀ c ∈ l.set k x, P c = true ∨ Q c = true → c ∈ l := by
  intro c hc hw
  rcases List.mem_or_eq_of_mem_set hc with hc | rfl
  · exact hc
  · rw [hp, hq] at hw; simp at hw
theorem sub2_setHead {s : St} {j : Job} (hp : j.waitTok = false) (hq : j.waitR = false) :
    ∀ c ∈ (setHead s j).chain, c.waitTok = true ∨ c.waitR = true → c ∈ s.chain := by
  intro c hc hw
  simp only [setHead, List.mem_cons] at hc
  rcases hc with rfl | hc
  · rw [hp, hq] at hw; simp at hw
  · exact List.mem_of_mem_tail hc

section helpers
variable {s : St} (h : NoOrphan s)
include h

theorem noOrphan_armL : NoOrphan (armL s) := by
  unfold armL; split
  · exact h
  · exact noOrphan_same h rfl rfl rfl rfl rfl
theorem noOrphan_send : NoOrphan (send s) := by
  unfold send; split
  · exact noOrphan_same h rfl rfl rfl rfl rfl
  · exact h
theorem noOrphan_libSend (o : Nat) : NoOrphan (libSend s o) := by
  have hs := noOrphan_send h
  unfold libSend; simp only; split
  · split
    · exact hs
    · exact noOrphan_same hs rfl rfl rfl rfl rfl
  · exact hs
theorem noOrphan_fetchEmail (t : Option Nat) (ok : Bool) : NoOrphan (fetchEmail s t ok) := by
  unfold fetchEmail; split
  · split
    · split
      · exact noOrphan_same h rfl rfl rfl rfl rfl
      · exact noOrphan_same h rfl rfl rfl rfl rfl
    · exact h
  · exact h
theorem noOrphan_pullSync : NoOrphan (pullSync s) := by
  unfold pullSync; split
  · exact h
  · exact noOrphan_lists h rfl rfl (fun _ m _ => m) (Sub.refl _)
      (sub2_app (fun _ m _ => m) rfl rfl)
theorem noOrphan_popHead : NoOrphan (popHead s) :=
  noOrphan_lists h rfl rfl (fun _ m _ => m) (Sub.refl _) (fun _ m _ => List.mem_of_mem_tail m)
theorem noOrphan_finish (a : Bool) : NoOrphan (finish s a) := by
  unfold finish; split
  · exact noOrphan_same (noOrphan_popHead h) rfl rfl rfl rfl rfl
  · exact noOrphan_popHead h
theorem noOrphan_setHead (j : Job) (hp : j.waitTok = false) (hq : j.waitR = false) :
    NoOrphan (setHead s j) :=
  noOrphan_lists h rfl rfl (fun _ m _ => m) (Sub.refl _) (sub2_setHead hp hq)
theorem noOrphan_signOutFx : NoOrphan (signOutFx s) := noOrphan_same h rfl rfl rfl rfl rfl
theorem noOrphan_codeAccept (iss : Nat) (g : Option Nat) : NoOrphan (codeAccept s iss g).1 := by
  unfold codeAccept; split
  · split
    · exact noOrphan_same h rfl rfl rfl rfl rfl
    · exact noOrphan_same h rfl rfl rfl rfl rfl
  · exact noOrphan_same h rfl rfl rfl rfl rfl
theorem noOrphan_flushSync (a : Bool) : NoOrphan (flushSync s a) :=
  noOrphan_lists h rfl rfl (fun _ m _ => m) (Sub.refl _) (sub2_app (fun _ m _ => m) rfl rfl)
end helpers

theorem joinOrCreate_req (s : St) (h : Option Nat) : (joinOrCreate s h).req.isSome = true := by
  unfold joinOrCreate; split
  · assumption
  · rfl

theorem joinR_rfr (s : St) (h : s.refresh.isSome = true) : (joinR s).rfr.isSome = true := by
  unfold joinR
  cases hr : s.rfr <;> cases hf : s.refresh <;> simp_all

theorem joinR_fields (s : St) : (joinR s).req = s.req ∧ (joinR s).renews = s.renews ∧
    (joinR s).connects = s.connects ∧ (joinR s).chain = s.chain := by
  unfold joinR; split <;> simp

theorem joinOrCreate_fields (s : St) (h : Option Nat) : (joinOrCreate s h).rfr = s.rfr ∧
    (joinOrCreate s h).renews = s.renews ∧ (joinOrCreate s h).connects = s.connects ∧
    (joinOrCreate s h).chain = s.chain := by
  unfold joinOrCreate; split <;> simp

/-- A renewal starting: either nothing waits, or it waits on the refresh it
joined or sent. -/
theorem noOrphan_renewStart {s : St} (h : NoOrphan s) (on gest : Bool) :
    NoOrphan (renewStart s on gest) := by
  unfold renewStart; split
  · exact h
  · split
    · exact noOrphan_armL h
    · split
      · rename_i hn
        obtain ⟨f1, f2, f3, f4⟩ := joinR_fields s
        have hr : s.refresh.isSome = true := by
          simp only [refreshNow, Bool.and_eq_true] at hn; exact hn.1
        refine noOrphan_frame h (Or.inr ⟨f1, ?_, by rw [f3]; exact Sub.refl _, by rw [f4]; exact Sub.refl _⟩)
          (Or.inl (joinR_rfr s hr))
        exact Sub.app (Sub.refl _) rfl
      · exact noOrphan_renews h _ (sub2_app (fun _ m _ => m) rfl rfl)

theorem noOrphan_renewCall {s : St} (h : NoOrphan s) (on gest : Bool) : NoOrphan (renewCall s on gest) := by
  unfold renewCall
  apply noOrphan_renewStart
  split <;> exact noOrphan_same h rfl rfl rfl rfl rfl

theorem noOrphan_armOG {s : St} (h : NoOrphan s) (on : Bool) : NoOrphan (armOG s on) := by
  unfold armOG; simp only
  have h' : NoOrphan { s with armCalls := s.armCalls + 1 } := noOrphan_same h rfl rfl rfl rfl rfl
  split
  · exact h'
  · split
    · exact noOrphan_renewCall h' on false
    · exact noOrphan_armL h'

theorem noOrphan_settle {s : St} (h : NoOrphan s) (r : Bool) : NoOrphan (settle s r) := by
  obtain ⟨-, hR⟩ := h
  constructor
  · intro _
    refine ⟨fun c hc => ?_, fun c hc => ?_, fun j hj => ?_⟩
    · obtain ⟨c', -, rfl⟩ := List.mem_map.1 hc
      rcases c' with ⟨⟩ | ⟨⟩ | ⟨w, u, ep, _ | _, _ | _⟩ | ⟨⟩ <;> rfl
    · obtain ⟨c', -, rfl⟩ := List.mem_map.1 hc
      rcases c' with ⟨_ | _, _ | _⟩ | ⟨⟩ | ⟨⟩ | ⟨⟩ <;> rfl
    · obtain ⟨j', -, rfl⟩ := List.mem_map.1 hj
      rcases j' with ⟨pc, a⟩ | ⟨b⟩
      · cases pc with
        | reauth o ep k c res => cases c <;> cases res <;> rfl
        | _ => rfl
      · rfl
  · intro hn
    obtain ⟨a, b⟩ := hR hn
    refine ⟨fun c hc => ?_, fun j hj => ?_⟩
    · obtain ⟨c', hc', rfl⟩ := List.mem_map.1 hc
      have := a c' hc'
      rcases c' with ⟨⟩ | ⟨⟩ | ⟨w, u, ep, _ | _, _ | _⟩ | ⟨⟩ <;> simp_all [stampR, RPc.waitR]
    · obtain ⟨j', hj', rfl⟩ := List.mem_map.1 hj
      have := b j' hj'
      rcases j' with ⟨pc, a⟩ | ⟨b⟩
      · cases pc with
        | reauth o ep k c res => cases c <;> cases res <;> simp_all [stampJ, Job.waitR]
        | _ => simp_all [stampJ, Job.waitR]
      · simp_all [stampJ, Job.waitR]

theorem noOrphan_settleR {s : St} (h : NoOrphan s) (r : Bool) : NoOrphan (settleR s r) := by
  obtain ⟨hG, -⟩ := h
  constructor
  · intro hn
    obtain ⟨a, b, c⟩ := hG hn
    refine ⟨fun x hx => ?_, b, fun j hj => ?_⟩
    · obtain ⟨x', hx', rfl⟩ := List.mem_map.1 hx
      have := a x' hx'
      rcases x' with ⟨w, ep, g, _ | _⟩ | ⟨⟩ | ⟨⟩ | ⟨⟩ <;> simp_all [stampRS, RPc.waitTok]
    · obtain ⟨j', hj', rfl⟩ := List.mem_map.1 hj
      have := c j' hj'
      rcases j' with ⟨pc, a⟩ | ⟨b⟩
      · cases pc with
        | silent o ep k res => cases res <;> simp_all [stampJS, Job.waitTok]
        | _ => simp_all [stampJS, Job.waitTok]
      · simp_all [stampJS, Job.waitTok]
  · intro _
    refine ⟨fun c hc => ?_, fun j hj => ?_⟩
    · obtain ⟨c', -, rfl⟩ := List.mem_map.1 hc
      rcases c' with ⟨w, ep, g, _ | _⟩ | ⟨⟩ | ⟨⟩ | ⟨⟩ <;> rfl
    · obtain ⟨j', -, rfl⟩ := List.mem_map.1 hj
      rcases j' with ⟨pc, a⟩ | ⟨b⟩
      · cases pc with
        | silent o ep k res => cases res <;> rfl
        | _ => rfl
      · rfl

theorem noOrphan_step (s : St) (e : Ev) (h : NoOrphan s) : NoOrphan (step s e) := by
  have same : ∀ s' : St, s'.req = s.req → s'.rfr = s.rfr → s'.renews = s.renews →
      s'.connects = s.connects → s'.chain = s.chain → NoOrphan s' :=
    fun s' a b c d f => noOrphan_same h a b c d f
  have erR : ∀ k, NoOrphan { s with renews := s.renews.eraseIdx k } :=
    fun k => noOrphan_renews h _ (sub2_erase _ _ _ k)
  have erC : ∀ k, NoOrphan { s with connects := s.connects.eraseIdx k } :=
    fun k => noOrphan_connects h _ (Sub.erase _ k)
  -- append a continuation that waits on nothing to the renewals left after #k
  have appR : ∀ k (x : RPc), x.waitTok = false → x.waitR = false →
      NoOrphan { s with renews := s.renews.eraseIdx k ++ [x] } :=
    fun k x a b => noOrphan_renews h _ (sub2_app (sub2_erase _ _ _ k) a b)
  cases e with
  | gesture on =>
    simp only [step]; split
    · exact noOrphan_renewCall (same { s with gestures := s.gestures + 1, armed := false } rfl rfl rfl rfl rfl) on true
    · exact same _ rfl rfl rfl rfl rfl
  | arm on => exact noOrphan_armOG h on
  | armListen => exact noOrphan_armL h
  | offerSet ok => exact same _ rfl rfl rfl rfl rfl
  | backoffSet b => exact same _ rfl rfl rfl rfl rfl
  | renewSilent k stale act =>
    simp only [step]; split
    · split
      · split
        · exact noOrphan_same (appR k _ rfl rfl) rfl rfl rfl rfl rfl
        · exact noOrphan_same (erR k) rfl rfl rfl rfl rfl
      · split
        · exact noOrphan_armL (erR k)
        · split
          · exact erR k
          · split
            · split
              · exact noOrphan_armL (erR k)
              · exact appR k _ rfl rfl
            · exact appR k _ rfl rfl
    · exact h
  | renewGis k ok act =>
    simp only [step]; split
    · split
      · exact noOrphan_armL (erR k)
      · split
        · exact erR k
        · split
          · exact noOrphan_armL (erR k)
          · split
            · exact appR k _ rfl rfl
            · obtain ⟨f1, f2, f3, f4⟩ := joinOrCreate_fields { s with renews := s.renews.eraseIdx k }
                (s.email)
              refine noOrphan_frame h (Or.inl (joinOrCreate_req _ _)) (Or.inr ⟨f1, ?_, ?_⟩)
              · simp only [f2]; exact Sub.app (Sub.erase _ k) rfl
              · simp only [f4]; exact Sub.refl _
    · exact h
  | renewCode k g =>
    simp only [step]; split
    · exact noOrphan_renews (noOrphan_codeAccept h _ _) _ (sub2_set _ k rfl rfl)
    · exact h
  | renewAcq k stale =>
    simp only [step]; split
    · split
      · exact erR k
      · split
        · split
          · split
            · exact noOrphan_armL (erR k)
            · exact erR k
          · split
            · exact noOrphan_same (erR k) rfl rfl rfl rfl rfl
            · exact noOrphan_armL (noOrphan_same (erR k) rfl rfl rfl rfl rfl)
        · split
          · exact noOrphan_same (erR k) rfl rfl rfl rfl rfl
          · exact noOrphan_same (appR k _ rfl rfl) rfl rfl rfl rfl rfl
    · exact h
  | renewEmail k ok =>
    simp only [step]; split
    · rename_i t ep _
      have hF := noOrphan_fetchEmail (erR k) t ok
      split
      · exact hF
      · exact noOrphan_pullSync hF
    · exact h
  | rfrOk =>
    simp only [step]; split
    · split
      · exact noOrphan_settleR h false
      · exact noOrphan_settleR (same _ rfl rfl rfl rfl rfl) true
    · exact h
  | rfrFail gone =>
    simp only [step]; split
    · split
      · exact noOrphan_settleR (noOrphan_signOutFx h) false
      · exact noOrphan_settleR (same _ rfl rfl rfl rfl rfl) false
    · exact h
  | tokGrant a =>
    simp only [step]; split
    · split
      · split
        · exact noOrphan_same (noOrphan_settle h true) rfl rfl rfl rfl rfl
        · split
          · exact noOrphan_same (noOrphan_settle h true) rfl rfl rfl rfl rfl
          · exact noOrphan_settle h false
      · exact h
    · exact h
  | tokDeny =>
    simp only [step]; split
    · exact noOrphan_same (noOrphan_settle h false) rfl rfl rfl rfl rfl
    · exact h
  | signIn broker =>
    simp only [step]; split
    · exact h
    · split
      · exact noOrphan_connects h _ (Sub.app (Sub.refl _) rfl)
      · obtain ⟨f1, f2, f3, f4⟩ := joinOrCreate_fields s s.email
        refine noOrphan_frame h (Or.inl (joinOrCreate_req _ _)) (Or.inr ⟨f1, ?_, ?_⟩)
        · simp only [f2]; exact Sub.refl _
        · simp only [f4]; exact Sub.refl _
  | connCode k g =>
    simp only [step]; split
    · split
      · exact noOrphan_lists h rfl rfl (fun _ m _ => m) (Sub.set _ k rfl) (fun _ m _ => m)
      · exact noOrphan_connects h _ (Sub.set _ k rfl)
    · exact h
  | connAcq k =>
    simp only [step]; split
    · split
      · exact noOrphan_lists h rfl rfl (fun _ m _ => m) (Sub.app (Sub.erase _ k) rfl) (fun _ m _ => m)
      · exact erC k
    · exact h
  | connEmail k ok =>
    simp only [step]; split
    · rename_i t _
      split
      · exact noOrphan_same (erC k) rfl rfl rfl rfl rfl
      · have hF := noOrphan_fetchEmail (erC k) t ok
        exact noOrphan_connects hF _ (Sub.app (Sub.refl _) rfl)
    · exact h
  | connSave k =>
    simp only [step]; split
    · split
      · exact noOrphan_connects h _ (Sub.app (Sub.erase _ k) rfl)
      · exact erC k
    · exact h
  | connFull k =>
    simp only [step]; split
    · exact noOrphan_flushSync (erC k) true
    · exact h
  | signOut =>
    simp only [step]; split
    · exact h
    · exact noOrphan_signOutFx h
  | poll wf =>
    simp only [step]; split
    · exact h
    · split
      · exact noOrphan_flushSync h true
      · exact noOrphan_pullSync h
  | visible =>
    simp only [step]; split
    · exact noOrphan_flushSync h true
    · exact h
  | callPull =>
    simp only [step]; split
    · exact noOrphan_pullSync (same _ rfl rfl rfl rfl rfl)
    · exact h
  | jobStart p =>
    simp only [step]; split
    · split
      · exact noOrphan_finish h _
      · exact noOrphan_send (noOrphan_setHead h _ rfl rfl)
    · split
      · exact noOrphan_popHead (same _ rfl rfl rfl rfl rfl)
      · exact noOrphan_send (noOrphan_setHead (same _ rfl rfl rfl rfl rfl) _ rfl rfl)
    · exact h
  | preludeOk k =>
    simp only [step]; split
    · split
      · exact noOrphan_finish h _
      · split
        · exact noOrphan_libSend (noOrphan_setHead h _ rfl rfl) _
        · exact noOrphan_send (noOrphan_setHead h _ rfl rfl)
    · exact h
  | upOk =>
    simp only [step]; split
    · split
      · exact noOrphan_finish h _
      · split
        · exact noOrphan_libSend (noOrphan_setHead h _ rfl rfl) _
        · exact noOrphan_send (noOrphan_setHead h _ rfl rfl)
    · exact h
  | retry =>
    simp only [step]; split
    · split
      · exact noOrphan_finish h _
      · exact noOrphan_send h
    · split
      · exact noOrphan_finish h _
      · exact noOrphan_libSend h _
    · exact h
  | up401 =>
    simp only [step]; split
    · split
      · exact noOrphan_finish (noOrphan_armOG (same { s with token := none } rfl rfl rfl rfl rfl) true) _
      · split
        · rename_i hn
          obtain ⟨f1, f2, f3, f4⟩ := joinR_fields s
          have hr : s.refresh.isSome = true := by
            simp only [refreshNow, Bool.and_eq_true] at hn; exact hn.1
          refine noOrphan_frame h (Or.inr ⟨f1, ?_, ?_, ?_⟩) (Or.inl (joinR_rfr s hr))
          · simp only [setHead, f2]; exact Sub.refl _
          · simp only [setHead, f3]; exact Sub.refl _
          · intro j hj hw
            simp only [setHead, f4, List.mem_cons] at hj
            rcases hj with rfl | hj
            · simp [Job.waitTok] at hw
            · exact List.mem_of_mem_tail hj
        · exact noOrphan_setHead h _ rfl rfl
    · exact h
  | reauthRes act =>
    simp only [step]; split
    · split
      · split
        · exact noOrphan_finish h _
        · exact noOrphan_send (noOrphan_setHead h _ rfl rfl)
      · split
        · exact noOrphan_finish h _
        · split
          · exact noOrphan_finish (noOrphan_armOG (same { s with token := none } rfl rfl rfl rfl rfl) true) _
          · split
            · exact noOrphan_setHead h _ rfl rfl
            · obtain ⟨f1, f2, f3, f4⟩ := joinOrCreate_fields s s.email
              refine noOrphan_frame h (Or.inl (by simp only [setHead]; exact joinOrCreate_req _ _))
                (Or.inr ⟨f1, ?_, ?_⟩)
              · simp only [setHead, f2]; exact Sub.refl _
              · intro j hj hw
                simp only [setHead, f4, List.mem_cons] at hj
                rcases hj with rfl | hj
                · simp [Job.waitR] at hw
                · exact List.mem_of_mem_tail hj
    · split
      · split
        · exact noOrphan_finish h _
        · exact noOrphan_finish (noOrphan_armOG (same { s with token := none } rfl rfl rfl rfl rfl) true) _
      · split
        · exact noOrphan_finish h _
        · exact noOrphan_send (noOrphan_setHead h _ rfl rfl)
    · exact h
  | reauthCode g =>
    simp only [step]; split
    · rename_i o ep k iss after rest hc
      exact noOrphan_setHead (noOrphan_codeAccept h iss g) _ rfl rfl
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
      · exact noOrphan_popHead (noOrphan_armOG (same { s with token := none } rfl rfl rfl rfl rfl) true)
      · exact noOrphan_popHead h
    · exact h

/-- **No orphaned caller**: whoever is awaiting a token has the one GIS
request in flight to wait on (gdriveTokenInFlight), and whoever is awaiting
the broker has the one refresh in flight (driveRefreshInFlight). -/
theorem no_orphaned_token_waiter {s : St} (h : Reachable s) : NoOrphan s := by
  induction h with
  | init => exact ⟨fun _ => by simp [init], fun _ => by simp [init]⟩
  | step e _ ih => exact noOrphan_step _ e ih

/-! ### Proved: a signed-out tab sends nothing, and no library crosses accounts

The two properties the sign-out findings broke, proved over every
interleaving (they supersede the old `quiet_signOut_final`, which needed
nothing in flight at the click): `send_only_signed_in` (no Drive request
leaves with a live token while the tab is signed out and no sign-in is
running) and `no_cross_account` (a flush never writes the library it
captured under one account into another account's Drive).

Since the token broker (92c9e49c, 6961bab6) two grants reach a linked tab
without a sign-in to ask whose they are: a consent screen opened as a
re-grant (`driveRegrantPopup` -> `driveCodeGrant`), and a broker refresh
(`driveRefreshSilently`). Since 6367e296 the consent re-grant is kept only
for the loaded account (`codeAccept_stray_same`), but a refresh is kept for
whatever account its refresh token is, and a broker sign-in can leave a
refresh token that is not the loaded account's
(`bug_refresh_token_outlives_its_account`). So the guarantee holds for
every reachable state in which no refresh was adopted for an account other
than the loaded one (the ghost `stray`). -/

def FPc.ownEp : FPc → Option (Nat × Nat)
  | .start => none
  | .prelude o ep => some (o, ep)
  | .upload o ep _ => some (o, ep)
  | .silent o ep _ _ => some (o, ep)
  | .reauth o ep _ _ _ => some (o, ep)
  | .libWrite o ep => some (o, ep)

/-- A started flush's account and session. -/
def Job.ownEp : Job → Option (Nat × Nat)
  | .flush pc _ => pc.ownEp
  | .pull _ => none

structure Safe (s : St) : Prop where
  /-- linked means the hint names the loaded account -/
  email : s.connected = true → s.email = some s.acct
  reqLe : ∀ h e, s.req = some (h, e) → e ≤ s.epoch
  /-- a token request of the current linked session asks for the loaded account -/
  req : ∀ h e, s.req = some (h, e) → e = s.epoch → s.connected = true → h = some s.acct
  /-- a linked tab's token is the loaded account's, unless a sign-in that has
  its grant is still finding out whose it is -/
  tok : ∀ b, s.token = some b → b ≠ s.acct → s.connected = true →
          ∃ c ∈ s.connects, c.granted = true
  jobLe : ∀ j ∈ s.chain, ∀ o ep, j.ownEp = some (o, ep) → ep ≤ s.epoch
  /-- a started flush still in its session is linked, its account's, and no
  sign-in is under way -/
  job : ∀ j ∈ s.chain, ∀ o ep, j.ownEp = some (o, ep) → ep = s.epoch →
          s.connected = true ∧ o = s.acct ∧ identifying s = false
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

theorem mem_set_or {α : Type} : ∀ (l : List α) (k : Nat) {x c : α} (y : α), l[k]? = some x → c ∈ l →
    c ∈ l.set k y ∨ c = x := by
  intro l
  induction l with
  | nil => intro k x c _ _ hc; simp at hc
  | cons z zs ih =>
    intro k x c y hk hc
    cases k with
    | zero =>
      simp at hk; subst hk
      simp only [List.set_cons_zero, List.mem_cons]
      rcases List.mem_cons.1 hc with rfl | h
      · exact Or.inr rfl
      · exact Or.inl (Or.inr h)
    | succ k =>
      simp only [List.set_cons_succ, List.mem_cons]
      simp only [List.getElem?_cons_succ] at hk
      rcases List.mem_cons.1 hc with rfl | h
      · exact Or.inl (Or.inl rfl)
      · rcases ih k y hk h with h' | h'
        · exact Or.inl (Or.inr h')
        · exact Or.inr h'

theorem ident_of_granted {c : CPc} (h : c.granted = true) : c.ident = true := by
  rcases c with ⟨_, _ | _ | _⟩ | _ | _ | _ <;> simp_all [CPc.granted, CPc.ident]

/-- The frame: the session, the account, the hint unchanged; the request
unchanged or settled; the token unchanged or dropped; granted sign-ins kept;
no new sign-in under way; started flushes only ones that were there. -/
theorem safe_frame {s s' : St} (h : Safe s) (hc : s'.connected = s.connected) (he : s'.email = s.email)
    (ha : s'.acct = s.acct) (hep : s'.epoch = s.epoch) (hreq : s'.req = s.req ∨ s'.req = none)
    (ht : s'.token = s.token ∨ s'.token = none)
    (hg : ∀ c ∈ s.connects, c.granted = true → c ∈ s'.connects)
    (hi : identifying s' = true → identifying s = true)
    (hj : ∀ j ∈ s'.chain, ∀ o ep, j.ownEp = some (o, ep) → ∃ j' ∈ s.chain, j'.ownEp = some (o, ep))
    (ho : s'.outTraffic = s.outTraffic) (hx : s'.crossLib = s.crossLib) : Safe s' := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro c; rw [he, ha]; exact h1 (hc ▸ c)
  · intro x e hr
    rcases hreq with hq | hq
    · rw [hep]; exact h2 x e (hq ▸ hr)
    · rw [hq] at hr; cases hr
  · intro x e hr hee hcc
    rcases hreq with hq | hq
    · rw [ha]; exact h3 x e (hq ▸ hr) (hep ▸ hee) (hc ▸ hcc)
    · rw [hq] at hr; cases hr
  · intro b hb hne hcc
    rcases ht with ht | ht
    · rw [ht] at hb
      obtain ⟨c, hcm, hcg⟩ := h4 b hb (ha ▸ hne) (hc ▸ hcc)
      exact ⟨c, hg c hcm hcg, hcg⟩
    · rw [ht] at hb; cases hb
  · intro j hjm o ep hown
    obtain ⟨j', hj', hown'⟩ := hj j hjm o ep hown
    rw [hep]; exact h5 j' hj' o ep hown'
  · intro j hjm o ep hown hee
    obtain ⟨j', hj', hown'⟩ := hj j hjm o ep hown
    obtain ⟨a1, a2, a3⟩ := h6 j' hj' o ep hown' (hep ▸ hee)
    refine ⟨hc ▸ a1, ha ▸ a2, ?_⟩
    cases hid : identifying s'
    · rfl
    · rw [hi hid] at a3; cases a3
  · rw [ho]; exact h7
  · rw [hx]; exact h8

theorem hj_same {s : St} : ∀ j ∈ s.chain, ∀ o ep, j.ownEp = some (o, ep) → ∃ j' ∈ s.chain, j'.ownEp = some (o, ep) :=
  fun j hj _ _ h => ⟨j, hj, h⟩
theorem hg_same {s : St} : ∀ c ∈ s.connects, c.granted = true → c ∈ s.connects := fun _ h _ => h
theorem hi_same {s : St} : identifying s = true → identifying s = true := id
theorem hj_tail {s : St} : ∀ j ∈ s.chain.tail, ∀ o ep, j.ownEp = some (o, ep) → ∃ j' ∈ s.chain, j'.ownEp = some (o, ep) :=
  fun j hj _ _ h => ⟨j, List.mem_of_mem_tail hj, h⟩

/-- Nothing Safe reads changed. -/
theorem safe_same {s s' : St} (h : Safe s) (hc : s'.connected = s.connected) (he : s'.email = s.email)
    (ha : s'.acct = s.acct) (hep : s'.epoch = s.epoch) (hreq : s'.req = s.req) (ht : s'.token = s.token)
    (hcn : s'.connects = s.connects) (hch : s'.chain = s.chain)
    (ho : s'.outTraffic = s.outTraffic) (hx : s'.crossLib = s.crossLib) : Safe s' := by
  refine safe_frame h hc he ha hep (Or.inl hreq) (Or.inl ht) ?_ ?_ ?_ ho hx
  · rw [hcn]; exact hg_same
  · unfold identifying; rw [hcn]; exact id
  · rw [hch]; exact hj_same

theorem safe_clear {s : St} (h : Safe s) : Safe { s with token := none } :=
  safe_frame h rfl rfl rfl rfl (Or.inl rfl) (Or.inr rfl) hg_same hi_same hj_same rfl rfl

section helpers
variable {s : St} (h : Safe s)
include h

theorem safe_armL : Safe (armL s) := by
  unfold armL; split
  · exact h
  · exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
theorem safe_joinR : Safe (joinR s) := by
  unfold joinR; split
  · exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  · exact h
theorem safe_joinOrCreate : Safe (joinOrCreate s s.email) := by
  unfold joinOrCreate; split
  · exact h
  · obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
    refine ⟨h1, ?_, ?_, h4, h5, h6, h7, h8⟩
    · intro x e hr; simp at hr ⊢; omega
    · intro x e hr _ hcc; simp at hr; rw [← hr.1]; exact h1 hcc
theorem safe_renews (l : List RPc) : Safe { s with renews := l } :=
  safe_same h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
theorem safe_renewStart (on gest : Bool) : Safe (renewStart s on gest) := by
  unfold renewStart; split
  · exact h
  · split
    · exact safe_armL h
    · split
      · exact safe_same (safe_joinR h) rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
      · exact safe_renews h _
theorem safe_renewCall (on gest : Bool) : Safe (renewCall s on gest) := by
  unfold renewCall; apply safe_renewStart
  split <;> exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
theorem safe_armOG (on : Bool) : Safe (armOG s on) := by
  unfold armOG; simp only
  have h' : Safe { s with armCalls := s.armCalls + 1 } := safe_same h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  split
  · exact h'
  · split
    · exact safe_renewCall h' on false
    · exact safe_armL h'
theorem safe_popHead : Safe (popHead s) :=
  safe_frame h rfl rfl rfl rfl (Or.inl rfl) (Or.inl rfl) hg_same hi_same hj_tail rfl rfl
theorem safe_finish (a : Bool) : Safe (finish s a) := by
  unfold finish; split
  · exact safe_frame h rfl rfl rfl rfl (Or.inl rfl) (Or.inl rfl) hg_same hi_same hj_tail rfl rfl
  · exact safe_popHead h
theorem safe_append (j : Job) (hj : j.ownEp = none) : Safe { s with chain := s.chain ++ [j] } := by
  refine safe_frame h rfl rfl rfl rfl (Or.inl rfl) (Or.inl rfl) hg_same hi_same ?_ rfl rfl
  intro j' hj' o ep hown
  simp only [List.mem_append, List.mem_singleton] at hj'
  rcases hj' with hj' | rfl
  · exact ⟨j', hj', hown⟩
  · rw [hj] at hown; cases hown
theorem safe_flushSync (a : Bool) : Safe (flushSync s a) := safe_append h _ rfl
theorem safe_pullSync : Safe (pullSync s) := by
  unfold pullSync; split
  · exact h
  · exact safe_append (s := { s with pullQueued := true })
      (safe_same h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl) (.pull false) rfl
end helpers

/-- Replacing the head by a job of the same started flush. -/
theorem safe_setHead_same {s : St} (h : Safe s) (j : Job) (j0 : Job) (hj0 : s.chain.head? = some j0)
    (hown : j.ownEp = j0.ownEp) : Safe (setHead s j) := by
  refine safe_frame h rfl rfl rfl rfl (Or.inl rfl) (Or.inl rfl) hg_same hi_same ?_ rfl rfl
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
    (send s).crossLib = s.crossLib ∧ (send s).chain = s.chain ∧ (send s).acct = s.acct ∧
    (send s).connects = s.connects := by
  unfold send; split <;> simp

/-- The library write of a flush of the loaded account, no sign-in under way. -/
theorem safe_libSend {s : St} (h : Safe s) (hc : s.connected = true) (o : Nat) (ho : o = s.acct)
    (hi : identifying s = false) : Safe (libSend s o) := by
  have hs := safe_send h hc
  obtain ⟨_, ht, _, _, _, hcn⟩ := send_fields s
  unfold libSend; simp only
  split
  · rename_i b hb
    split
    · exact hs
    · rename_i hne
      rw [ht] at hb
      obtain ⟨c, hcm, hcg⟩ := h.tok b hb (by rw [← ho]; exact hne) hc
      have : identifying s = true := List.any_eq_true.2 ⟨c, hcm, ident_of_granted hcg⟩
      rw [this] at hi; cases hi
  · exact hs

/-- The chain head, if it is a started flush in the current session, may send. -/
theorem head_ok {s : St} (h : Safe s) (j : Job) (rest : List Job) (hc : s.chain = j :: rest) (o ep : Nat)
    (hown : j.ownEp = some (o, ep)) (hep : ep = s.epoch) :
    s.connected = true ∧ o = s.acct ∧ identifying s = false :=
  h.job j (by rw [hc]; simp) o ep hown hep

/-- **syncActive means the loaded account's token.** -/
theorem active_token {s : St} (h : Safe s) (ha : syncActive s = true) : s.token = some s.acct := by
  simp only [syncActive, Bool.and_eq_true, Bool.not_eq_true'] at ha
  obtain ⟨⟨ht, hc⟩, hi⟩ := ha
  obtain ⟨b, hb⟩ := Option.isSome_iff_exists.1 ht
  rw [hb]
  by_cases hne : b = s.acct
  · rw [hne]
  · obtain ⟨c, hcm, hcg⟩ := h.tok b hb hne hc
    have : identifying s = true := List.any_eq_true.2 ⟨c, hcm, ident_of_granted hcg⟩
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
    refine ⟨?_, h2, ?_, ?_, h5, ?_, h7, h8⟩
    · intro _; simp [hacct]
    · intro x e hr hee hcc; exact h3 x e hr hee hcc
    · intro b hb hne hcc; exact h4 b hb hne hcc
    · intro j hj o ep hown hee; exact h6 j hj o ep hown hee
  · rename_i hacct
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, h7, h8⟩
    · intro _; rfl
    · intro x e hr; exact Nat.le_succ_of_le (h2 x e hr)
    · intro x e hr hee; have := h2 x e hr; simp only at hee; omega
    · intro b hb hne; simp only at hb hne; rw [ht] at hb; cases hb; exact absurd rfl hne
    · intro j hj o ep hown; exact Nat.le_succ_of_le (h5 j hj o ep hown)
    · intro j hj o ep hown hee; have := h5 j hj o ep hown; simp only at hee; omega

theorem ownEp_stampJ (r : Bool) (j : Job) : (stampJ r j).ownEp = j.ownEp := by
  rcases j with ⟨pc, a⟩ | ⟨b⟩
  · cases pc with
    | reauth o ep k c res => cases c <;> cases res <;> rfl
    | _ => rfl
  · rfl

theorem ownEp_stampJS (r : Bool) (j : Job) : (stampJS r j).ownEp = j.ownEp := by
  rcases j with ⟨pc, a⟩ | ⟨b⟩
  · cases pc with
    | silent o ep k res => cases res <;> rfl
    | _ => rfl
  · rfl

theorem granted_stampC (r : Bool) (c : CPc) (h : c.granted = true) : stampC r c = c := by
  rcases c with ⟨_ | _, _ | _ | _⟩ | _ | _ | _ <;> simp_all [CPc.granted, stampC]

theorem ident_stampC (r : Bool) (c : CPc) : (stampC r c).ident = c.ident := by
  rcases c with ⟨_ | _, _ | _⟩ | _ | _ | _ <;> rfl

theorem identifying_settle (s : St) (r : Bool) : identifying (settle s r) = identifying s := by
  simp only [identifying, settle, List.any_map]
  congr 1; funext c; exact ident_stampC r c

theorem safe_settle {s : St} (h : Safe s) (r : Bool) : Safe (settle s r) := by
  refine safe_frame h rfl rfl rfl rfl (Or.inr rfl) (Or.inl rfl) ?_ ?_ ?_ rfl rfl
  · intro c hc hg; simp only [settle]
    exact List.mem_map.2 ⟨c, hc, granted_stampC r c hg⟩
  · rw [identifying_settle]; exact id
  · intro j hj o ep hown
    obtain ⟨j', hj', rfl⟩ := List.mem_map.1 hj
    exact ⟨j', hj', by rw [← ownEp_stampJ r]; exact hown⟩

theorem safe_settleR {s : St} (h : Safe s) (r : Bool) : Safe (settleR s r) := by
  refine safe_frame h rfl rfl rfl rfl (Or.inl rfl) (Or.inl rfl) hg_same hi_same ?_ rfl rfl
  intro j hj o ep hown
  obtain ⟨j', hj', rfl⟩ := List.mem_map.1 hj
  exact ⟨j', hj', by rw [← ownEp_stampJS r]; exact hown⟩

theorem safe_signOutFx {s : St} (h : Safe s) : Safe (signOutFx s) := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, h7, h8⟩
  · intro hc; cases hc
  · intro x e hr; exact Nat.le_succ_of_le (h2 x e hr)
  · intro x e hr _ hc; cases hc
  · intro b hb; cases hb
  · intro j hj o ep hown; exact Nat.le_succ_of_le (h5 j hj o ep hown)
  · intro j hj o ep hown hee; have := h5 j hj o ep hown; simp only [signOutFx] at hee; omega

/-- A re-grant through the consent screen: since 6367e296 only ever for the
loaded account. -/
theorem safe_codeAccept {s : St} (h : Safe s) (iss : Nat) (g : Option Nat) :
    Safe (codeAccept s iss g).1 := by
  unfold codeAccept
  cases g with
  | none => exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  | some a =>
    simp only
    split
    · rename_i hc
      have ha : a = s.acct := by simp only [Bool.and_eq_true, beq_iff_eq] at hc; exact hc.2
      obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
      refine ⟨h1, h2, h3, ?_, h5, h6, h7, h8⟩
      intro b hb hne _; simp only at hb hne; cases hb; exact absurd ha hne
    · exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl

/-- **A consent re-grant is never stray** (6367e296): only a broker refresh
can adopt a token for an account other than the loaded one. -/
theorem codeAccept_stray_same (s : St) (iss : Nat) (g : Option Nat) :
    (codeAccept s iss g).1.stray = s.stray := by
  unfold codeAccept; split
  · split <;> rfl
  · rfl

/-- A sign-in refused: the token dropped and a new session (6367e296). -/
theorem safe_refused {s : St} (h : Safe s) (l : List CPc) :
    Safe { s with connects := l, token := none, refresh := none, epoch := s.epoch + 1 } := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  refine ⟨h1, ?_, ?_, ?_, ?_, ?_, h7, h8⟩
  · intro x e hr; exact Nat.le_succ_of_le (h2 x e hr)
  · intro x e hr hee; have := h2 x e hr; simp only at hee; omega
  · intro b hb; cases hb
  · intro j hj o ep hown; exact Nat.le_succ_of_le (h5 j hj o ep hown)
  · intro j hj o ep hown hee; have := h5 j hj o ep hown; simp only at hee; omega

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
  obtain ⟨hcon, ho, hi⟩ := head_ok h (.flush pc after) rest hc o ep hown hep
  split
  · exact safe_libSend (safe_setHead_same h _ (.flush pc after) (by simp [hc]) (by simp only [Job.ownEp]; rw [hown]; rfl))
      hcon o ho hi
  · exact safe_send (safe_setHead_same h _ (.flush pc after) (by simp [hc]) (by simp only [Job.ownEp]; rw [hown, hown']))
      hcon

/-- A new chain head of the same flush (the head's account and session). -/
theorem safe_setHead_head {s : St} (h : Safe s) (pc : FPc) (after : Bool) (rest : List Job)
    (hc : s.chain = .flush pc after :: rest) (pc' : FPc) (hown : pc'.ownEp = pc.ownEp) (a : Bool) :
    Safe (setHead s (.flush pc' a)) :=
  safe_setHead_same h _ (.flush pc after) (by simp [hc]) (by simp only [Job.ownEp]; exact hown)

theorem codeAccept_chain (s : St) (iss : Nat) (g : Option Nat) : (codeAccept s iss g).1.chain = s.chain := by
  unfold codeAccept; split
  · split <;> rfl
  · rfl

theorem joinR_chain (s : St) : (joinR s).chain = s.chain := (joinR_fields s).2.2.2
theorem joinOrCreate_chain (s : St) (h : Option Nat) : (joinOrCreate s h).chain = s.chain :=
  (joinOrCreate_fields s h).2.2.2

theorem mem_set_self' {α : Type} : ∀ (l : List α) (k : Nat) {y : α} (x : α), l[k]? = some y → x ∈ l.set k x := by
  intro l
  induction l with
  | nil => intro k y x h; simp at h
  | cons z zs ih =>
    intro k y x h
    cases k with
    | zero => simp
    | succ k => simp only [List.set_cons_succ, List.mem_cons]; exact Or.inr (ih k x h)

theorem ident_at {s : St} {k : Nat} {c : CPc} (hk : s.connects[k]? = some c) (hc : c.ident = true) :
    identifying s = true :=
  List.any_eq_true.2 ⟨c, List.mem_of_getElem? hk, hc⟩

/-- A signed-out tab: nothing it does to its connects or its request can
break anything (no flush of the current session exists). -/
theorem safe_disconnected {s s' : St} (h : Safe s) (hcf : s.connected = false) (hc : s'.connected = false)
    (hep : s'.epoch = s.epoch) (hreq : ∀ x e, s'.req = some (x, e) → e ≤ s'.epoch)
    (hch : s'.chain = s.chain) (ho : s'.outTraffic = s.outTraffic) (hx : s'.crossLib = s.crossLib) :
    Safe s' := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  refine ⟨?_, hreq, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro c; rw [hc] at c; cases c
  · intro _ _ _ _ c; rw [hc] at c; cases c
  · intro _ _ _ c; rw [hc] at c; cases c
  · intro j hj o ep hown; rw [hep]; exact h5 j (hch ▸ hj) o ep hown
  · intro j hj o ep hown hee
    have := (h6 j (hch ▸ hj) o ep hown (hep ▸ hee)).1; rw [hcf] at this; cases this
  · rw [ho]; exact h7
  · rw [hx]; exact h8

/-- The frame with the token dropped: what the connects hold no longer matters. -/
theorem safe_frame_cleared {s s' : St} (h : Safe s) (hc : s'.connected = s.connected)
    (he : s'.email = s.email) (ha : s'.acct = s.acct) (hep : s'.epoch = s.epoch) (hreq : s'.req = s.req)
    (ht : s'.token = none) (hi : identifying s' = true → identifying s = true)
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
    obtain ⟨a1, a2, a3⟩ := h6 j' hj' o ep hown' (hep ▸ hee)
    refine ⟨hc ▸ a1, ha ▸ a2, ?_⟩
    cases hid : identifying s'
    · rfl
    · rw [hi hid] at a3; cases a3
  · rw [ho]; exact h7
  · rw [hx]; exact h8

theorem safe_step (s : St) (e : Ev) (h : Safe s) (hs : (step s e).stray = false) : Safe (step s e) := by
  have fr : ∀ s' : St, s'.connected = s.connected → s'.email = s.email → s'.acct = s.acct →
      s'.epoch = s.epoch → s'.req = s.req → s'.token = s.token → s'.connects = s.connects →
      s'.chain = s.chain → s'.outTraffic = s.outTraffic → s'.crossLib = s.crossLib → Safe s' :=
    fun s' a b c d e f g i j k => safe_same h a b c d e f g i j k
  have erR : ∀ k, Safe { s with renews := s.renews.eraseIdx k } := fun k => safe_renews h _
  -- a connect erased that had no grant
  have erC : ∀ k x, s.connects[k]? = some x → x.granted = false →
      Safe { s with connects := s.connects.eraseIdx k } := by
    intro k x hk hx
    refine safe_frame h rfl rfl rfl rfl (Or.inl rfl) (Or.inl rfl) ?_ ?_ hj_same rfl rfl
    · intro c hcm hcg
      rcases mem_eraseIdx_or s.connects k hk hcm with hm | rfl
      · exact hm
      · rw [hx] at hcg; cases hcg
    · intro hi
      obtain ⟨c, hc, hci⟩ := List.any_eq_true.1 hi
      exact List.any_eq_true.2 ⟨c, List.mem_of_mem_eraseIdx hc, hci⟩
  cases e with
  | gesture on =>
    simp only [step]; split
    · apply safe_renewCall; apply fr <;> rfl
    · exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  | arm on => exact safe_armOG h on
  | armListen => exact safe_armL h
  | offerSet ok => exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  | backoffSet b => exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
  | renewSilent k stale act =>
    simp only [step]; split
    · split
      · split
        · exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
        · exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
      · split
        · exact safe_armL (erR k)
        · split
          · exact erR k
          · split
            · split
              · exact safe_armL (erR k)
              · exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
            · exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
    · exact h
  | renewGis k ok act =>
    simp only [step]; split
    · split
      · exact safe_armL (erR k)
      · split
        · exact erR k
        · split
          · exact safe_armL (erR k)
          · split
            · exact fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
            · exact safe_renews (safe_joinOrCreate (erR k)) _
    · exact h
  | renewCode k g =>
    simp only [step]; split
    · rename_i was up ep iss heq
      exact safe_renews (safe_codeAccept h iss g) _
    · exact h
  | renewAcq k stale =>
    simp only [step]; split
    · split
      · exact erR k
      · split
        · split
          · split
            · exact safe_armL (erR k)
            · exact erR k
          · split
            · exact safe_clear (s := { s with renews := s.renews.eraseIdx k, fails := s.fails + 1 })
                (fr _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl)
            · apply safe_armL; apply fr <;> rfl
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
  | rfrOk =>
    simp only [step]; split
    · rename_i r e heq
      split
      · exact safe_settleR h false
      · rename_i hc
        have hs' : (s.stray || r != s.acct) = false := by
          have hs2 := hs
          simp only [step, heq] at hs2
          split at hs2
          · contradiction
          · exact hs2
        simp only [Bool.or_eq_false_iff, bne_eq_false_iff_eq] at hs'
        apply safe_settleR
        obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
        refine ⟨h1, h2, h3, ?_, h5, h6, h7, h8⟩
        intro b hb hne _; simp only at hb hne; cases hb; exact absurd hs'.2 hne
    · exact h
  | rfrFail gone =>
    simp only [step]; split
    · split
      · exact safe_settleR (safe_signOutFx h) false
      · apply safe_settleR; apply fr <;> rfl
    · exact h
  | tokGrant a =>
    simp only [step]; split
    · rename_i hh ee hreq
      split
      · rename_i hha
        split
        · -- a sign-in waits on the request: a new session, whichever account
          rename_i hw
          have hmem : CPc.acq false none ∈ s.connects := by simpa [connectWaits] using hw
          have hS := safe_settle h true
          obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := hS
          refine ⟨h1, ?_, ?_, ?_, ?_, ?_, h7, h8⟩
          · intro x e hr; simp [settle] at hr
          · intro x e hr; simp [settle] at hr
          · intro b _ _ _
            refine ⟨.acq false (some true), ?_, rfl⟩
            simp only [settle]
            exact List.mem_map.2 ⟨.acq false none, hmem, rfl⟩
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
            refine ⟨h1, h2, h3, ?_, h5, h6, h7, h8⟩
            intro b hb hne _; simp only at hb; cases hb; simp [settle] at hne; exact absurd ha hne
          · exact safe_settle h false
      · exact h
    · exact h
  | tokDeny =>
    simp only [step]; split
    · exact safe_frame (safe_settle h false) rfl rfl rfl rfl (Or.inl rfl) (Or.inl rfl) hg_same hi_same
        hj_same rfl rfl
    · exact h
  | signIn broker =>
    simp only [step]; split
    · exact h
    · rename_i hc
      have hcf : s.connected = false := by simpa using hc
      split
      · exact safe_disconnected h hcf hcf rfl h.reqLe rfl rfl rfl
      · unfold joinOrCreate; split
        · exact safe_disconnected h hcf hcf rfl h.reqLe rfl rfl rfl
        · refine safe_disconnected h hcf hcf rfl ?_ rfl rfl rfl
          intro x e hr; simp at hr ⊢; omega
  | connCode k g =>
    simp only [step]; split
    · rename_i heq
      split
      · obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
        refine ⟨h1, ?_, ?_, ?_, ?_, ?_, h7, h8⟩
        · intro x e hr; exact Nat.le_succ_of_le (h2 x e hr)
        · intro x e hr hee; have := h2 x e hr; simp only at hee; omega
        · intro b _ _ _; exact ⟨.acq true (some true), mem_set_self' _ k _ heq, rfl⟩
        · intro j hj o ep hown; exact Nat.le_succ_of_le (h5 j hj o ep hown)
        · intro j hj o ep hown hee; have := h5 j hj o ep hown; simp only at hee; omega
      · refine safe_frame h rfl rfl rfl rfl (Or.inl rfl) (Or.inl rfl) ?_ ?_ hj_same rfl rfl
        · intro c hcm hcg
          rcases mem_set_or s.connects k _ heq hcm with hm | rfl
          · exact hm
          · cases hcg
        · intro _; exact ident_at heq rfl
    · exact h
  | connAcq k =>
    simp only [step]; split
    · rename_i c r heq
      split
      · obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
        refine ⟨h1, h2, h3, ?_, h5, ?_, h7, h8⟩
        · intro b _ _ _; exact ⟨.email s.token, by simp, rfl⟩
        · intro j hj o ep hown hee
          have := (h6 j hj o ep hown hee).2.2
          rw [ident_at heq rfl] at this; cases this
      · rename_i hr
        exact erC k _ heq (by revert hr; cases r <;> simp [CPc.granted])
    · exact h
  | connEmail k ok =>
    simp only [step]; split
    · rename_i t hk
      split
      · exact safe_refused h _
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
      have hE := erC k .save hk rfl
      split
      · refine safe_frame hE rfl rfl rfl rfl (Or.inl rfl) (Or.inl rfl) ?_ ?_ hj_same rfl rfl
        · intro c hc _; simp only [List.mem_append]; exact Or.inl hc
        · intro hi
          simp only [identifying, List.any_append, Bool.or_eq_true] at hi
          rcases hi with hi | hi
          · exact hi
          · simp [CPc.ident] at hi
      · exact hE
    · exact h
  | connFull k =>
    simp only [step]; split
    · rename_i hk
      exact safe_flushSync (erC k .full hk rfl) _
    · exact h
  | signOut =>
    simp only [step]; split
    · exact h
    · exact safe_signOutFx h
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
    · apply safe_pullSync; apply fr <;> rfl
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
        have hcon : s.connected = true := by
          simp only [syncActive, Bool.and_eq_true] at ha; exact ha.1.2
        have hid : identifying s = false := by
          simp only [syncActive, Bool.and_eq_true, Bool.not_eq_true'] at ha; exact ha.2
        refine safe_send (s := setHead s (.flush (.prelude s.acct s.epoch) after)) ?_ hcon
        obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
        refine ⟨h1, h2, h3, h4, ?_, ?_, h7, h8⟩
        · intro x hx o ep hown
          simp only [setHead, List.mem_cons] at hx
          rcases hx with rfl | hx
          · simp only [Job.ownEp, FPc.ownEp, Option.some.injEq, Prod.mk.injEq] at hown
            obtain ⟨rfl, rfl⟩ := hown; exact Nat.le_refl _
          · exact h5 x (List.mem_of_mem_tail hx) o ep hown
        · intro x hx o ep hown hee
          simp only [setHead, List.mem_cons] at hx
          rcases hx with rfl | hx
          · simp only [Job.ownEp, FPc.ownEp, Option.some.injEq, Prod.mk.injEq] at hown
            obtain ⟨rfl, rfl⟩ := hown; exact ⟨hcon, rfl, hid⟩
          · exact h6 x (List.mem_of_mem_tail hx) o ep hown hee
    · rename_i rest hc
      split
      · apply safe_popHead; apply fr <;> rfl
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
  | retry =>
    simp only [step]; split
    · rename_i o ep k after rest hc
      split
      · exact safe_finish h _
      · rename_i hep
        have hep' : ep = s.epoch := by simpa using hep
        exact safe_send h (head_ok h _ rest hc o ep rfl hep').1
    · rename_i o ep after rest hc
      split
      · exact safe_finish h _
      · rename_i hep
        have hep' : ep = s.epoch := by simpa using hep
        obtain ⟨hcon, ho, hi⟩ := head_ok h _ rest hc o ep rfl hep'
        exact safe_libSend h hcon o ho hi
    · exact h
  | up401 =>
    simp only [step]; split
    · rename_i o ep k after rest hc
      split
      · exact safe_finish (safe_armOG (safe_clear h) true) _
      · split
        · exact safe_setHead_head (safe_joinR h) (.upload o ep k) after rest
            (by rw [joinR_chain]; exact hc) (.silent o ep k none) rfl after
        · exact safe_setHead_head h (.upload o ep k) after rest hc (.silent o ep k (some false)) rfl after
    · exact h
  | reauthRes act =>
    simp only [step]; split
    · rename_i o ep k r after rest hc
      split
      · split
        · exact safe_finish h _
        · rename_i hep
          have hep' : ep = s.epoch := by simpa using hep
          exact safe_send (safe_setHead_head h (.silent o ep k (some r)) after rest hc (.upload o ep k)
            rfl after) (head_ok h _ rest hc o ep rfl hep').1
      · split
        · exact safe_finish h _
        · split
          · exact safe_finish (safe_armOG (safe_clear h) true) _
          · split
            · exact safe_setHead_head h (.silent o ep k (some r)) after rest hc
                (.reauth o ep k (some s.epoch) none) rfl after
            · exact safe_setHead_head (safe_joinOrCreate h) (.silent o ep k (some r)) after rest
                (by rw [joinOrCreate_chain]; exact hc) (.reauth o ep k none none) rfl after
    · rename_i o ep k c r after rest hc
      split
      · split
        · exact safe_finish h _
        · exact safe_finish (safe_armOG (safe_clear h) true) _
      · split
        · exact safe_finish h _
        · rename_i hep
          have hep' : ep = s.epoch := by simpa using hep
          exact safe_send (safe_setHead_head h (.reauth o ep k c (some r)) after rest hc (.upload o ep k)
            rfl after) (head_ok h _ rest hc o ep rfl hep').1
    · exact h
  | reauthCode g =>
    simp only [step]; split
    · rename_i o ep k iss after rest hc
      exact safe_setHead_head (safe_codeAccept h iss g) (.reauth o ep k (some iss) none) after rest
        (by rw [codeAccept_chain]; exact hc) (.reauth o ep k (some iss) (some (codeAccept s iss g).2))
        rfl after
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
      · exact safe_popHead (safe_armOG (safe_clear h) true)
      · exact safe_popHead h
    · exact h

/-! `stray` only ever turns on. -/
section strayKeep
variable (s : St)
theorem armL_stray : (armL s).stray = s.stray := by unfold armL; split <;> rfl
theorem joinR_stray : (joinR s).stray = s.stray := by unfold joinR; split <;> rfl
theorem joinOrCreate_stray (h : Option Nat) : (joinOrCreate s h).stray = s.stray := by
  unfold joinOrCreate; split <;> rfl
theorem send_stray : (send s).stray = s.stray := by unfold send; split <;> rfl
theorem libSend_stray (o : Nat) : (libSend s o).stray = s.stray := by
  unfold libSend; simp only; split
  · split
    · exact send_stray s
    · exact send_stray s
  · exact send_stray s
theorem fetchEmail_stray (t : Option Nat) (ok : Bool) : (fetchEmail s t ok).stray = s.stray := by
  unfold fetchEmail; split
  · split
    · split <;> rfl
    · rfl
  · rfl
theorem pullSync_stray : (pullSync s).stray = s.stray := by unfold pullSync; split <;> rfl
theorem finish_stray (a : Bool) : (finish s a).stray = s.stray := by unfold finish; split <;> rfl
theorem renewStart_stray (on g : Bool) : (renewStart s on g).stray = s.stray := by
  unfold renewStart; split
  · rfl
  · split
    · exact armL_stray s
    · split
      · exact joinR_stray s
      · rfl
theorem renewCall_stray (on g : Bool) : (renewCall s on g).stray = s.stray := by
  unfold renewCall; rw [renewStart_stray]; split <;> rfl
theorem armOG_stray (on : Bool) : (armOG s on).stray = s.stray := by
  unfold armOG; simp only; split
  · rfl
  · split
    · exact renewCall_stray _ on false
    · exact armL_stray _
theorem codeAccept_stray (iss : Nat) (g : Option Nat) (h : s.stray = true) :
    (codeAccept s iss g).1.stray = true := by
  unfold codeAccept; split
  · split
    · simp [h]
    · exact h
  · exact h
end strayKeep

theorem stray_keep (s : St) (e : Ev) (h : s.stray = true) : (step s e).stray = true := by
  cases e <;> simp only [step] <;> (repeat' split) <;>
    simp_all [armL_stray, joinR_stray, joinOrCreate_stray, send_stray, libSend_stray, fetchEmail_stray,
      pullSync_stray, finish_stray, renewCall_stray, armOG_stray, codeAccept_stray, settle, settleR,
      setHead, popHead, signOutFx, flushSync]

theorem reachable_safe {s : St} (h : Reachable s) (hs : s.stray = false) : Safe s := by
  induction h with
  | init => exact safe_init
  | @step s e _ ih =>
    have hs0 : s.stray = false := by
      cases h0 : s.stray
      · rfl
      · have := stray_keep s e h0; rw [hs] at this; cases this
    exact safe_step _ e (ih hs0) hs

/-- **No flush writes across accounts** (fixes `bug_flush_crosses_accounts`
over every interleaving) unless a broker refresh was adopted for another
account: then it does (`bug_refresh_token_outlives_its_account`). -/
theorem no_cross_account {s : St} (h : Reachable s) (hs : s.stray = false) : s.crossLib = false :=
  (reachable_safe h hs).cross

/-- ...and a linked tab that is syncing holds its own account's token. -/
theorem active_is_own_account {s : St} (h : Reachable s) (hs : s.stray = false)
    (ha : syncActive s = true) : s.token = some s.acct :=
  active_token (reachable_safe h hs) ha

/-! ### Proved with no assumption: a signed-out tab sends nothing

`Safe` carries `out` beside the account properties and so needs `stray`
false; sending while signed out does not: every send is a flush or pull of
the current session, and those run only on a linked tab. -/

structure Quiet (s : St) : Prop where
  jobLe : ∀ j ∈ s.chain, ∀ o ep, j.ownEp = some (o, ep) → ep ≤ s.epoch
  jobC : ∀ j ∈ s.chain, ∀ o ep, j.ownEp = some (o, ep) → ep = s.epoch → s.connected = true
  out : s.outTraffic = false

theorem quiet_frame {s s' : St} (h : Quiet s) (hep : s.epoch ≤ s'.epoch)
    (hc : s'.epoch = s.epoch → s.connected = true → s'.connected = true)
    (hj : ∀ j ∈ s'.chain, ∀ o ep, j.ownEp = some (o, ep) → ∃ j' ∈ s.chain, j'.ownEp = some (o, ep))
    (ho : s'.outTraffic = s.outTraffic) : Quiet s' := by
  obtain ⟨h1, h2, h3⟩ := h
  refine ⟨?_, ?_, ?_⟩
  · intro j hjm o ep hown
    obtain ⟨j', hj', hown'⟩ := hj j hjm o ep hown
    exact Nat.le_trans (h1 j' hj' o ep hown') hep
  · intro j hjm o ep hown hee
    obtain ⟨j', hj', hown'⟩ := hj j hjm o ep hown
    have hle := h1 j' hj' o ep hown'
    have heq : s'.epoch = s.epoch := by omega
    exact hc heq (h2 j' hj' o ep hown' (by omega))
  · rw [ho]; exact h3

/-- Anything that keeps the session, the link and the started flushes. -/
theorem quiet_same {s s' : St} (h : Quiet s) (hep : s'.epoch = s.epoch) (hc : s'.connected = s.connected)
    (hj : ∀ j ∈ s'.chain, ∀ o ep, j.ownEp = some (o, ep) → ∃ j' ∈ s.chain, j'.ownEp = some (o, ep))
    (ho : s'.outTraffic = s.outTraffic) : Quiet s' :=
  quiet_frame h (by omega) (fun _ c => hc ▸ c) hj ho

/-- The session moved on: whatever it did to the link, no flush is in it. -/
theorem quiet_bump {s s' : St} (h : Quiet s) (hep : s'.epoch = s.epoch + 1)
    (hj : ∀ j ∈ s'.chain, ∀ o ep, j.ownEp = some (o, ep) → ∃ j' ∈ s.chain, j'.ownEp = some (o, ep))
    (ho : s'.outTraffic = s.outTraffic) : Quiet s' :=
  quiet_frame h (by omega) (fun e _ => by omega) hj ho

theorem quiet_send {s : St} (h : Quiet s) (hc : s.connected = true) : Quiet (send s) := by
  unfold send; split
  · rename_i hh; simp [hc] at hh
  · exact h

theorem quiet_libSend {s : St} (h : Quiet s) (hc : s.connected = true) (o : Nat) : Quiet (libSend s o) := by
  have hs := quiet_send h hc
  unfold libSend; simp only; split
  · split
    · exact hs
    · exact quiet_same hs rfl rfl hj_same rfl
  · exact hs

/-- The fields Quiet reads, for the helpers that do not touch them. -/
def qv (s : St) : Nat × Bool × List Job × Bool := (s.epoch, s.connected, s.chain, s.outTraffic)

theorem quiet_qv {s s' : St} (h : Quiet s) (e : qv s' = qv s) : Quiet s' := by
  simp only [qv, Prod.mk.injEq] at e
  obtain ⟨a, b, c, d⟩ := e
  exact quiet_same h a b (by rw [c]; exact hj_same) d

section qhelpers
variable (s : St)
theorem armL_qv : qv (armL s) = qv s := by unfold armL; split <;> rfl
theorem joinR_qv : qv (joinR s) = qv s := by unfold joinR; split <;> rfl
theorem joinOrCreate_qv (h : Option Nat) : qv (joinOrCreate s h) = qv s := by
  unfold joinOrCreate; split <;> rfl
theorem renewStart_qv (on g : Bool) : qv (renewStart s on g) = qv s := by
  unfold renewStart; split
  · rfl
  · split
    · exact armL_qv s
    · split
      · have := joinR_qv s; simp only [qv] at this ⊢; exact this
      · rfl
theorem renewCall_qv (on g : Bool) : qv (renewCall s on g) = qv s := by
  unfold renewCall; rw [renewStart_qv]; split <;> rfl
theorem armOG_qv (on : Bool) : qv (armOG s on) = qv s := by
  unfold armOG; simp only; split
  · rfl
  · split
    · exact renewCall_qv _ on false
    · exact armL_qv _
theorem codeAccept_qv (iss : Nat) (g : Option Nat) : qv (codeAccept s iss g).1 = qv s := by
  unfold codeAccept; split
  · split <;> rfl
  · rfl
end qhelpers

theorem quiet_finish {s : St} (h : Quiet s) (a : Bool) : Quiet (finish s a) := by
  unfold finish; split
  · exact quiet_same h rfl rfl hj_tail rfl
  · exact quiet_same h rfl rfl hj_tail rfl

theorem quiet_append {s : St} (h : Quiet s) (j : Job) (hj : j.ownEp = none) :
    Quiet { s with chain := s.chain ++ [j] } := by
  refine quiet_same h rfl rfl ?_ rfl
  intro j' hj' o ep hown
  simp only [List.mem_append, List.mem_singleton] at hj'
  rcases hj' with hj' | rfl
  · exact ⟨j', hj', hown⟩
  · rw [hj] at hown; cases hown

theorem quiet_pullSync {s : St} (h : Quiet s) : Quiet (pullSync s) := by
  unfold pullSync; split
  · exact h
  · exact quiet_append (s := { s with pullQueued := true }) (quiet_same h rfl rfl hj_same rfl) _ rfl

theorem quiet_setHead {s : St} (h : Quiet s) (pc : FPc) (after : Bool) (rest : List Job)
    (hc : s.chain = .flush pc after :: rest) (pc' : FPc) (hown : pc'.ownEp = pc.ownEp) (a : Bool) :
    Quiet (setHead s (.flush pc' a)) := by
  refine quiet_same h rfl rfl ?_ rfl
  intro x hx o ep hx'
  simp only [setHead, List.mem_cons] at hx
  rcases hx with rfl | hx
  · exact ⟨.flush pc after, by rw [hc]; simp, by simp only [Job.ownEp] at hx' ⊢; rw [← hown]; exact hx'⟩
  · exact ⟨x, List.mem_of_mem_tail hx, hx'⟩

theorem quiet_head {s : St} (h : Quiet s) (pc : FPc) (after : Bool) (rest : List Job)
    (hc : s.chain = .flush pc after :: rest) (o ep : Nat) (hown : pc.ownEp = some (o, ep))
    (hep : ep = s.epoch) : s.connected = true :=
  h.jobC (.flush pc after) (by rw [hc]; simp) o ep hown hep

theorem quiet_settle {s : St} (h : Quiet s) (r : Bool) : Quiet (settle s r) := by
  refine quiet_same h rfl rfl ?_ rfl
  intro j hj o ep hown
  obtain ⟨j', hj', rfl⟩ := List.mem_map.1 hj
  exact ⟨j', hj', by rw [← ownEp_stampJ r]; exact hown⟩

theorem quiet_settleR {s : St} (h : Quiet s) (r : Bool) : Quiet (settleR s r) := by
  refine quiet_same h rfl rfl ?_ rfl
  intro j hj o ep hown
  obtain ⟨j', hj', rfl⟩ := List.mem_map.1 hj
  exact ⟨j', hj', by rw [← ownEp_stampJS r]; exact hown⟩

theorem quiet_fetchEmail {s : St} (h : Quiet s) (t : Option Nat) (ok : Bool) : Quiet (fetchEmail s t ok) := by
  rcases fetchEmail_cases s t ok with e | ⟨a, _, e⟩
  · rw [e]; exact h
  rw [e]; split
  · exact quiet_same h rfl rfl hj_same rfl
  · exact quiet_bump h rfl hj_same rfl

theorem quiet_step (s : St) (e : Ev) (h : Quiet s) : Quiet (step s e) := by
  have q : ∀ s', qv s' = qv s → Quiet s' := fun _ e => quiet_qv h e
  have same : ∀ s' : St, s'.epoch = s.epoch → s'.connected = s.connected → s'.chain = s.chain →
      s'.outTraffic = s.outTraffic → Quiet s' :=
    fun s' a b c d => quiet_same h a b (by rw [c]; exact hj_same) d
  cases e with
  | gesture on =>
    simp only [step]; split
    · apply quiet_qv h; rw [renewCall_qv]; rfl
    · exact same _ rfl rfl rfl rfl
  | arm on => exact q _ (armOG_qv s on)
  | armListen => exact q _ (armL_qv s)
  | offerSet ok => exact same _ rfl rfl rfl rfl
  | backoffSet b => exact same _ rfl rfl rfl rfl
  | renewSilent k stale act =>
    simp only [step]; split
    · split
      · split <;> exact same _ rfl rfl rfl rfl
      · split
        · apply quiet_qv h; rw [armL_qv]; rfl
        · split
          · exact same _ rfl rfl rfl rfl
          · split
            · split
              · apply quiet_qv h; rw [armL_qv]; rfl
              · exact same _ rfl rfl rfl rfl
            · exact same _ rfl rfl rfl rfl
    · exact h
  | renewGis k ok act =>
    simp only [step]; split
    · split
      · apply quiet_qv h; rw [armL_qv]; rfl
      · split
        · exact same _ rfl rfl rfl rfl
        · split
          · apply quiet_qv h; rw [armL_qv]; rfl
          · split
            · exact same _ rfl rfl rfl rfl
            · apply quiet_qv h
              have := joinOrCreate_qv { s with renews := s.renews.eraseIdx k } s.email
              simp only [qv] at this ⊢; exact this
    · exact h
  | renewCode k g =>
    simp only [step]; split
    · rename_i was up ep iss _
      apply quiet_qv h
      have := codeAccept_qv s iss g
      simp only [qv] at this ⊢; exact this
    · exact h
  | renewAcq k stale =>
    simp only [step]; split
    · split
      · exact same _ rfl rfl rfl rfl
      · split
        · split
          · split
            · apply quiet_qv h; rw [armL_qv]; rfl
            · exact same _ rfl rfl rfl rfl
          · split
            · exact same _ rfl rfl rfl rfl
            · apply quiet_qv h; rw [armL_qv]; rfl
        · split <;> exact same _ rfl rfl rfl rfl
    · exact h
  | renewEmail k ok =>
    simp only [step]; split
    · rename_i t ep _
      have hF := quiet_fetchEmail (same { s with renews := s.renews.eraseIdx k } rfl rfl rfl rfl) t ok
      split
      · exact hF
      · exact quiet_pullSync hF
    · exact h
  | rfrOk =>
    simp only [step]; split
    · split
      · exact quiet_settleR h false
      · apply quiet_settleR; apply same <;> rfl
    · exact h
  | rfrFail gone =>
    simp only [step]; split
    · split
      · exact quiet_settleR (quiet_bump (s' := signOutFx s) h rfl hj_same rfl) false
      · apply quiet_settleR; apply same <;> rfl
    · exact h
  | tokGrant a =>
    simp only [step]; split
    · split
      · split
        · exact quiet_bump (quiet_settle h true) rfl hj_same rfl
        · split
          · exact quiet_same (quiet_settle h true) rfl rfl hj_same rfl
          · exact quiet_settle h false
      · exact h
    · exact h
  | tokDeny =>
    simp only [step]; split
    · exact quiet_same (quiet_settle h false) rfl rfl hj_same rfl
    · exact h
  | signIn broker =>
    simp only [step]; split
    · exact h
    · split
      · exact same _ rfl rfl rfl rfl
      · apply quiet_qv h
        have := joinOrCreate_qv s s.email
        simp only [qv] at this ⊢; exact this
  | connCode k g =>
    simp only [step]; split
    · split
      · exact quiet_bump h rfl hj_same rfl
      · exact same _ rfl rfl rfl rfl
    · exact h
  | connAcq k =>
    simp only [step]; split
    · split <;> exact same _ rfl rfl rfl rfl
    · exact h
  | connEmail k ok =>
    simp only [step]; split
    · rename_i t _
      split
      · exact quiet_bump h rfl hj_same rfl
      · have hF := quiet_fetchEmail (same { s with connects := s.connects.eraseIdx k } rfl rfl rfl rfl) t ok
        exact quiet_frame hF (by simp) (fun e _ => rfl) hj_same rfl
    · exact h
  | connSave k =>
    simp only [step]; split
    · split <;> exact same _ rfl rfl rfl rfl
    · exact h
  | connFull k =>
    simp only [step]; split
    · exact quiet_append (same { s with connects := s.connects.eraseIdx k } rfl rfl rfl rfl) _ rfl
    · exact h
  | signOut =>
    simp only [step]; split
    · exact h
    · exact quiet_bump h rfl hj_same rfl
  | poll wf =>
    simp only [step]; split
    · exact h
    · split
      · exact quiet_append h _ rfl
      · exact quiet_pullSync h
  | visible =>
    simp only [step]; split
    · exact quiet_append h _ rfl
    · exact h
  | callPull =>
    simp only [step]; split
    · exact quiet_pullSync (same _ rfl rfl rfl rfl)
    · exact h
  | jobStart p =>
    simp only [step]; split
    · rename_i after rest hc
      split
      · exact quiet_finish h _
      · rename_i hact
        have hcon : s.connected = true := by
          cases hs : syncActive s
          · simp [hs] at hact
          · simp only [syncActive, Bool.and_eq_true] at hs; exact hs.1.2
        refine quiet_send ?_ hcon
        obtain ⟨h1, h2, h3⟩ := h
        refine ⟨?_, ?_, h3⟩
        · intro x hx o ep hown
          simp only [setHead, List.mem_cons] at hx
          rcases hx with rfl | hx
          · simp only [Job.ownEp, FPc.ownEp, Option.some.injEq, Prod.mk.injEq] at hown
            obtain ⟨rfl, rfl⟩ := hown; exact Nat.le_refl _
          · exact h1 x (List.mem_of_mem_tail hx) o ep hown
        · intro x hx o ep hown hee
          simp only [setHead, List.mem_cons] at hx
          rcases hx with rfl | hx
          · exact hcon
          · exact h2 x (List.mem_of_mem_tail hx) o ep hown hee
    · rename_i rest hc
      split
      · exact quiet_same h rfl rfl hj_tail rfl
      · rename_i hact
        have hcon : s.connected = true := by
          cases hs : syncActive { s with pullQueued := false }
          · simp [hs] at hact
          · simp only [syncActive, Bool.and_eq_true] at hs; exact hs.1.2
        refine quiet_send ?_ hcon
        refine quiet_same h rfl rfl ?_ rfl
        intro x hx o ep hown
        simp only [setHead, List.mem_cons] at hx
        rcases hx with rfl | hx
        · simp [Job.ownEp] at hown
        · exact ⟨x, List.mem_of_mem_tail hx, hown⟩
    · exact h
  | preludeOk k =>
    simp only [step]; split
    · rename_i o ep after rest hc
      split
      · exact quiet_finish h _
      · rename_i hep
        have hcon := quiet_head h _ after rest hc o ep rfl (by simpa using hep)
        split
        · exact quiet_libSend (quiet_setHead h _ after rest hc (.libWrite o ep) rfl after) hcon o
        · exact quiet_send (quiet_setHead h _ after rest hc (.upload o ep (k - 1)) rfl after) hcon
    · exact h
  | upOk =>
    simp only [step]; split
    · rename_i o ep k after rest hc
      split
      · exact quiet_finish h _
      · rename_i hep
        have hcon := quiet_head h _ after rest hc o ep rfl (by simpa using hep)
        split
        · exact quiet_libSend (quiet_setHead h _ after rest hc (.libWrite o ep) rfl after) hcon o
        · exact quiet_send (quiet_setHead h _ after rest hc (.upload o ep (k - 1)) rfl after) hcon
    · exact h
  | retry =>
    simp only [step]; split
    · rename_i o ep k after rest hc
      split
      · exact quiet_finish h _
      · rename_i hep
        exact quiet_send h (quiet_head h _ after rest hc o ep rfl (by simpa using hep))
    · rename_i o ep after rest hc
      split
      · exact quiet_finish h _
      · rename_i hep
        exact quiet_libSend h (quiet_head h _ after rest hc o ep rfl (by simpa using hep)) o
    · exact h
  | up401 =>
    simp only [step]; split
    · rename_i o ep k after rest hc
      split
      · exact quiet_finish (quiet_qv h (by rw [armOG_qv]; rfl)) _
      · split
        · have hq : Quiet (joinR s) := quiet_qv h (joinR_qv s)
          exact quiet_setHead hq (.upload o ep k) after rest (by rw [joinR_chain]; exact hc)
            (.silent o ep k none) rfl after
        · exact quiet_setHead h (.upload o ep k) after rest hc (.silent o ep k (some false)) rfl after
    · exact h
  | reauthRes act =>
    simp only [step]; split
    · rename_i o ep k r after rest hc
      split
      · split
        · exact quiet_finish h _
        · rename_i hep
          have hcon := quiet_head h _ after rest hc o ep rfl (by simpa using hep)
          exact quiet_send (quiet_setHead h _ after rest hc (.upload o ep k) rfl after) hcon
      · split
        · exact quiet_finish h _
        · split
          · exact quiet_finish (quiet_qv h (by rw [armOG_qv]; rfl)) _
          · split
            · exact quiet_setHead h _ after rest hc (.reauth o ep k (some s.epoch) none) rfl after
            · have hq : Quiet (joinOrCreate s s.email) := quiet_qv h (joinOrCreate_qv s s.email)
              exact quiet_setHead hq (.silent o ep k (some r)) after rest
                (by rw [joinOrCreate_chain]; exact hc) (.reauth o ep k none none) rfl after
    · rename_i o ep k c r after rest hc
      split
      · split
        · exact quiet_finish h _
        · exact quiet_finish (quiet_qv h (by rw [armOG_qv]; rfl)) _
      · split
        · exact quiet_finish h _
        · rename_i hep
          have hcon := quiet_head h _ after rest hc o ep rfl (by simpa using hep)
          exact quiet_send (quiet_setHead h _ after rest hc (.upload o ep k) rfl after) hcon
    · exact h
  | reauthCode g =>
    simp only [step]; split
    · rename_i o ep k iss after rest hc
      have hq : Quiet (codeAccept s iss g).1 := quiet_qv h (codeAccept_qv s iss g)
      exact quiet_setHead hq (.reauth o ep k (some iss) none) after rest
        (by rw [codeAccept_chain]; exact hc) (.reauth o ep k (some iss) (some (codeAccept s iss g).2))
        rfl after
    · exact h
  | libDone =>
    simp only [step]; split
    · exact quiet_finish h _
    · exact h
  | jobFail =>
    simp only [step]; split
    all_goals first
      | exact h
      | exact quiet_finish h _
  | pullDone clr =>
    simp only [step]; split
    · split
      · have hq : Quiet (armOG { s with token := none } true) := quiet_qv h (by rw [armOG_qv]; rfl)
        exact quiet_same hq rfl rfl hj_tail rfl
      · exact quiet_same h rfl rfl hj_tail rfl
    · exact h

theorem reachable_quiet {s : St} (h : Reachable s) : Quiet s := by
  induction h with
  | init => exact ⟨by simp [init], by simp [init], rfl⟩
  | step e _ ih => exact quiet_step _ e ih

/-- **A signed-out tab sends nothing** (fixes `bug_renewal_resurrects_token`,
`bug_signed_out_tab_keeps_syncing` over every interleaving): no Drive request
ever leaves with a live token while the tab is signed out and no sign-in is
running, whatever grants it adopted. -/
theorem send_only_signed_in {s : St} (h : Reachable s) : s.outTraffic = false :=
  (reachable_quiet h).out

end WebState.DriveSession.Session
