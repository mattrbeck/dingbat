/-
# Online link play: connection lifecycle (web/netplay.js, web/index.js @ dd7ba741f)

netplay.js keeps one module global `net` (39), the pending/active session
built by `makeSession` (66). Paths to a transport:

* signaling socket (`sigConnect` 251) + WebRTC DataChannel (`startRtc` 387,
  `wireChannel` 424), with a response deadline (`armManualFallback` 306),
  a redial ladder (`sigRedial` 318, `SIG_REDIAL_DELAYS` 101) and a
  "paired"-to-open deadline (`rtcDeadline`, 393);
* a same-browser BroadcastChannel (`startLocalLink` 540 / `LocalChannel` 478)
  racing the socket; `wireChannel` keeps the first channel and closes later
  ones ("the loser is torn down here", 425);
* the manual code exchange (`manualEnter` 759, `manualPrepare` 700,
  `manualConfirmGo` 816), entered when the server is (or was last seen) down.

`netShutdown` (1539) tears a session down; `netFail` (235) is a setup failure
that shuts down with the modal kept and re-arms a fresh session.

index.js side: `rollbackMode` (7154) is set by `enterRollbackMode` (9250) from
`rbStartIfReady` (netplay.js 1294), which also sets `netMode = false`; the rAF
`tick` runs exactly one branch: rollback, else netMode (SIO), else linkMode,
else the solo core (11321-11400). `loadRom` (7881) and the `pagehide` /
`beforeunload` handlers tear the session down `if (netActive() ||
rollbackMode)`. Those three, and loadRom's return when a session started
during its awaits, model the code as fixed by the commit "web: a rollback
session ends before a launch or a page close" (line numbers at that commit;
the rest of this file is still at dd7ba741f): at dd7ba741f they tore down only
`if (netMode)`, and `netMode` is false in a rollback session.

## What is modelled

* Sessions are numbered; `cur` is `net` (none = null). Sockets are numbered
  with the WebSocket readyState, whether `onopen` ran (`opened`, the closure
  variable in sigConnect 264), whether the handlers were nulled
  (`manualEnter` 776), and the queued `error`/`close` events. Per the
  WHATWG spec, `close()` on a CONNECTING socket *fails* it: `error` then
  `close` are queued; on an OPEN socket only `close` is queued; a socket not
  OPEN delivers no messages.
* The awaiting caller of each `sigConnect` promise (the Connect button 1384 or
  a redial timer 335) is a pending continuation on the socket, resumed by
  `resume` at any later point.
* Channels: `local sid` (the LocalChannel of session sid), `rtc p` (the
  DataChannel of peer connection p), `manual p` (the pre-created manual-exchange
  channel of p). `offered` = passed to `wireChannel`; `raceClosed` = closed by
  wireChannel's loser branch; `shutClosed` = closed by `netShutdown`.
* Saves: `store g` is the IndexedDB `save:<g>` record as (whose battery data,
  version). The solo core holds `solo`; the rollback session's own core
  (`rollback_init` builds fresh cores; `rollback_exit_to_single` promotes
  ours and writes its .sav, dingbat_wasm.nim 1509) holds `(sessGame, rbV)`.

## Abstractions

* rbConnect / the hello-state-ready exchange / `rbStartIfReady` are one event
  `rbStart` (enabled once the channel is open); `rb.inited` is identified with
  `started`. The SIO path (`?rollback=0`, `launchNetRom`) is not modelled.
* `netShutdown`'s tail after `await rbTeardown()` (closing dc/pc/ws) is folded
  into its first segment. rbTeardown's `persistSave(currentRomName,
  currentOriginalName)` evaluates its arguments, reads the FS and issues the
  IndexedDB put synchronously (dbPutRoomy -> dbPut, index.js 4260/537), so the
  write's key is fixed at teardown time and is modelled there.
* `loadRom`'s awaits before its commit (7885-7897) are `launch`/`loadCommit`.
* One "waiting"/"paired" reply stands for any server message; SDP/ICE
  contents are not modelled (a pc either yields its channel or not).
* `navigator.onLine` is true; BroadcastChannel exists.
* Ghosts: `rdials` (redial dials since the last server reply) and `wired`
  (installed as a session's `net.dc`) only record history for the theorems.

## Results

Proved: at most one signaling socket is ever live and none survives leaving
(`at_most_one_live_socket`, `no_live_socket_after_leave`); redial / pairing
deadline / fallback timers only ever belong to the current session
(`timers_belong_to_current`); at most three reconnect dials between server
replies (`redial_bounded`); every channel offered to wireChannel is installed
or closed (`loser_closed`); under every interleaving of launches, page
teardowns and sessions, every save record holds its own game, no page dies
with a session's progress unstored, and ending a session persists it under
its own game (`saves_keyed`, `teardown_persists`, `pagehide_persists_session`).
Refuted (`bug_*`): a cancelled or locally-won dial's stale `onerror` marks the
server down; a retried manual Confirm closes its own channel. The two
rollback save traces found at dd7ba741f (launching a game, or closing the tab,
during a rollback session) are now safe (`regress_*`).
-/
namespace WebState.Netplay

-- The invariant proofs pass generous simp sets to many small goals.
set_option linter.unusedSimpArgs false
set_option linter.unusedVariables false

inductive Chan where
  | local (sid : Nat) | rtc (p : Nat) | manual (p : Nat)
  deriving DecidableEq, Repr

inductive SSt where
  | none | connecting | opn | closing | closed
  deriving DecidableEq, Repr

inductive Waiter where
  | none | join (sid : Nat) | redial (sid : Nat)
  deriving DecidableEq, Repr

structure Sock where
  st       : SSt := .none
  opened   : Bool := false       -- sigConnect's `opened` (264)
  detached : Bool := false       -- handlers nulled by manualEnter (776)
  errQ     : Bool := false       -- an `error` event queued
  closeQ   : Bool := false       -- a `close` event queued
  res      : Option Bool := none -- sigConnect's promise resolved with
  waiter   : Waiter := .none     -- who awaits it
  deriving DecidableEq, Repr

structure Sess where
  ws          : Option Nat := none   -- net.ws
  bc          : Bool := false        -- net.bc (discovery BroadcastChannel open)
  dc          : Option Chan := none  -- net.dc
  rtcConnected : Bool := false
  started     : Bool := false        -- net.started (= rb.inited here)
  code        : Bool := false        -- net.code set (a redial can re-rendezvous)
  redials     : Nat := 0
  redialT     : Bool := false        -- net.redialTimer pending
  deadline    : Bool := false        -- net.rtcDeadline pending
  pc          : Option Nat := none   -- net.pc
  manualReady : Bool := false        -- net.manualCode minted
  confirmed   : Bool := false        -- manual Confirm went through (input readOnly)
  rdials      : Nat := 0             -- ghost: redial dials since the server last answered
  deriving DecidableEq, Repr

structure State where
  cur        : Option Nat          -- net
  nextSid    : Nat
  modal      : Bool                -- netModal "open"
  manualView : Bool                -- netManualView visible
  sigUp      : Option Bool         -- sigServerUp (119)
  fallback   : Option Nat          -- manualFallbackTimer, armed for that session
  sess       : Nat → Sess
  socks      : Nat → Sock
  nextSock   : Nat
  nextPc     : Nat
  offered    : Chan → Bool
  raceClosed : Chan → Bool
  shutClosed : Chan → Bool
  wired      : Chan → Bool         -- ghost: installed as some session's net.dc
  -- index.js
  netMode      : Bool
  rollbackMode : Bool
  game       : Nat                 -- currentOriginalName
  solo       : Nat × Nat           -- the solo core's battery data (game, version)
  sessGame   : Nat                 -- the game the rollback session runs
  rbV        : Nat                 -- its battery version
  store      : Nat → Nat × Nat     -- IndexedDB save:<g>
  loadPending : Option Nat         -- loadRom between its first segment and its commit
  dead       : Bool                -- page gone (pagehide)
  lostProgress : Bool              -- the page died with unpersisted session progress

def init : State where
  cur := none
  nextSid := 0
  modal := false
  manualView := false
  sigUp := none
  fallback := none
  sess := fun _ => {}
  socks := fun _ => {}
  nextSock := 0
  nextPc := 0
  offered := fun _ => false
  raceClosed := fun _ => false
  shutClosed := fun _ => false
  wired := fun _ => false
  netMode := false
  rollbackMode := false
  game := 0
  solo := (0, 0)
  sessGame := 0
  rbV := 0
  store := fun g => (g, 0)
  loadPending := none
  dead := false
  lostProgress := false

def updS (sid : Nat) (f : Sess → Sess) (s : State) : State :=
  { s with sess := fun j => if j = sid then f (s.sess j) else s.sess j }

def updK (k : Nat) (f : Sock → Sock) (s : State) : State :=
  { s with socks := fun j => if j = k then f (s.socks j) else s.socks j }

def setF (c : Chan) (f : Chan → Bool) : Chan → Bool := fun d => if d = c then true else f d

def put (g : Nat) (v : Nat × Nat) (f : Nat → Nat × Nat) : Nat → Nat × Nat :=
  fun h => if h = g then v else f h

/-- `ws.close()`: CONNECTING fails (error + close queued), OPEN closes (close queued). -/
def closeF (x : Sock) : Sock :=
  match x.st with
  | .connecting => { x with st := .closing, errQ := true, closeQ := true }
  | .opn => { x with st := .closing, closeQ := true }
  | _ => x

def closeSock (k : Nat) (s : State) : State := updK k closeF s

def closeWsOpt : Option Nat → State → State
  | some k, s => closeSock k s
  | none, s => s

/-- A fresh session (makeSession 66). -/
def newSession (s : State) : State :=
  { s with cur := some s.nextSid, nextSid := s.nextSid + 1 }

/-- manualPrepare (700), first segment: close the old pc, mint a new pc and its
    unwired channel; the code is ready after `manualReady`. -/
def manualPrepare (s : State) : State :=
  match s.cur with
  | none => s
  | some sid =>
    let p := s.nextPc
    updS sid (fun x => { x with pc := some p, manualReady := false }) { s with nextPc := p + 1 }

/-- manualEnter (759): clear the three timers, null the socket's handlers and
    close it, drop the BroadcastChannel, show the manual view, then
    manualPrepare (a new pc). Written as one record update. -/
def manualEnter (s : State) : State :=
  if !s.modal then s else
  match s.cur with
  | none => s
  | some sid =>
    if s.manualView then s else
    { s with
      fallback := none, manualView := true, nextPc := s.nextPc + 1,
      sess := fun j => if j = sid then
          { s.sess j with redialT := false, deadline := false, ws := none, bc := false,
                          pc := some s.nextPc, manualReady := false }
        else s.sess j,
      socks := fun k => if (s.sess sid).ws = some k then closeF { s.socks k with detached := true }
        else s.socks k }

def curSess (s : State) : Sess :=
  match s.cur with
  | some sid => s.sess sid
  | none => {}

/-- netShutdown's effect on the session records: timers cleared, pc/bc closed. -/
def shutSess (s : State) (j : Nat) : Sess :=
  if s.cur = some j then { s.sess j with redialT := false, deadline := false, bc := false, pc := none }
  else s.sess j

/-- `net.ws`, if there is a session. -/
def curWs (s : State) : Option Nat :=
  match s.cur with
  | some sid => (s.sess sid).ws
  | none => none

/-- ... and on the sockets: `s.ws?.close()`. -/
def shutSock (s : State) (j : Nat) : Sock :=
  if curWs s = some j then closeF (s.socks j) else s.socks j

/-- netShutdown (1539). `keep` = `{ keepModal: true }`. rbTeardown (1317), when
    the session's rollback core is live, promotes it to the solo core, leaves
    rollback mode and persists it under `currentOriginalName`. -/
def shutdown (keep : Bool) (s : State) : State :=
  let x := curSess s
  let rb := x.started && s.rollbackMode
  { s with
    cur := none, fallback := none,
    sess := shutSess s, socks := shutSock s,
    shutClosed := (match s.cur, x.dc with
      | some _, some c => setF c s.shutClosed
      | _, _ => s.shutClosed),
    solo := if rb then (s.sessGame, s.rbV) else s.solo,
    rollbackMode := if rb then false else s.rollbackMode,
    store := if rb then put s.game (s.sessGame, s.rbV) s.store else s.store,
    modal := keep && s.modal, manualView := keep && s.manualView }

/-- netDismissModal (1605), as loadRom calls it when the modal is open: a
    session still pairing is shut down; otherwise the modal just closes. (The
    Dismiss event below is the same code.) -/
def dismissModal (s : State) : State :=
  if (curSess s).started || s.cur.isNone then { s with modal := false } else shutdown false s

/-- netFail (235): setup failure (or peer gone once started). -/
def netFail (s : State) : State :=
  match s.cur with
  | some sid => if (s.sess sid).started then shutdown false s else
      let s := shutdown true s
      if s.modal then newSession s else s
  | none =>
      let s := shutdown true s
      if s.modal then newSession s else s

/-- sigConnect (251): a new CONNECTING socket becomes net.ws. -/
def sigConnect (sid : Nat) (w : Waiter) (s : State) : State :=
  let k := s.nextSock
  let s := updK k (fun _ => { st := .connecting, waiter := w }) { s with nextSock := k + 1 }
  updS sid (fun x => { x with ws := some k }) s

/-- sigRedial (318). -/
def sigRedial (sid : Nat) (s : State) : State :=
  let x := s.sess sid
  if !x.code then s else
  let s := { s with fallback := none }
  let attempt := x.redials
  let s := updS sid (fun x => { x with redials := x.redials + 1 }) s
  if attempt ≥ 3 then manualEnter { s with sigUp := some false }
  else updS sid (fun x => { x with redialT := true }) s

/-- wireChannel (424): keep the first channel, close any later one. -/
def wireChannel (c : Chan) (s : State) : State :=
  match s.cur with
  | none => s
  | some sid =>
    let s := { s with offered := setF c s.offered }
    match (s.sess sid).dc with
    | some _ => { s with raceClosed := setF c s.raceClosed }
    | none =>
      -- abortLocal: a non-local winner closes the discovery BroadcastChannel
      let s := updS sid (fun x => { x with dc := some c }) { s with wired := setF c s.wired }
      match c with
      | .local _ => s
      | _ => updS sid (fun x => { x with bc := false }) s

/-- dc.onopen (436): linked; close the signaling socket and forget it. -/
def dcOnOpen (s : State) : State :=
  match s.cur with
  | none => s
  | some sid =>
    let x := s.sess sid
    let s := updS sid (fun x => { x with rtcConnected := true, deadline := false }) s
    let s := closeWsOpt x.ws s
    updS sid (fun x => { x with ws := none }) s

/-- hasAltPath (263). -/
def hasAltPath (s : State) : Bool :=
  match s.cur with
  | none => false
  | some sid => let x := s.sess sid; x.bc || x.dc.isSome || x.rtcConnected || x.started

inductive Event where
  | openModal                 -- Link Cable menu item -> openNetConnect (176)
  | joinClick                 -- Connect / Cancel (1384)
  | dismiss                   -- x, backdrop, Escape -> netDismissModal (1605)
  | sockOpen (k : Nat)        -- the server accepts
  | sockRefused (k : Nat)     -- the dial fails (server down)
  | sockDrop (k : Nat)        -- an open socket drops
  | sockErr (k : Nat)         -- its queued `error` event is dispatched
  | sockClose (k : Nat)       -- its queued `close` event is dispatched
  | sockMsg (k : Nat) (paired : Bool)  -- a server message ("waiting" / "paired")
  | resume (k : Nat)          -- the `await sigConnect()` continuation runs
  | fallbackFire             -- manualFallbackTimer (306)
  | redialFire (sid : Nat)    -- a redial timer (335)
  | deadlineFire (sid : Nat)  -- rtcDeadline (393 / 881)
  | localPair                 -- another tab answers on the BroadcastChannel (540-590)
  | rtcChannel                -- the pc's DataChannel appears (createDataChannel / ondatachannel)
  | dcOpen                    -- the wired RTC/manual channel opens
  | toManual                  -- "use codes instead" (1672)
  | manualReady               -- manualPrepare's awaits finish: the code is minted
  | remint                    -- manualPrepare again (45 s timer / return to foreground, 748/952)
  | confirmHost (srdOk : Bool) -- manualConfirmGo as the host (816); setRemoteDescription ok?
  | rbStart                   -- rbConnect .. rbStartIfReady: the rollback session runs
  | rbProgress                -- the linked game writes its battery (e.g. a trade)
  | disconnect                -- Disconnect (two-step), idle timeout, peer gone
  | launch (g : Nat)          -- tile tap / file drop -> loadRom, first segment
  | loadCommit                -- loadRom's commit (7893-7921)
  | pagehide                  -- tab closed / navigated (11226)
  deriving DecidableEq, Repr

def en (s : State) : Event → Bool
  | .openModal => !s.dead && !s.modal && s.cur.isNone
  | .joinClick => !s.dead && s.modal && !s.manualView && s.cur.isSome
  | .dismiss => !s.dead && s.modal
  | .sockOpen k => !s.dead && (s.socks k).st == .connecting
  | .sockRefused k => !s.dead && (s.socks k).st == .connecting
  | .sockDrop k => !s.dead && (s.socks k).st == .opn
  | .sockErr k => !s.dead && (s.socks k).errQ
  | .sockClose k => !s.dead && (s.socks k).closeQ
  | .sockMsg k _ => !s.dead && (s.socks k).st == .opn && !(s.socks k).detached
  | .resume k => !s.dead && (s.socks k).res.isSome && (s.socks k).waiter != .none
  | .fallbackFire => !s.dead && s.fallback.isSome
  | .redialFire sid => !s.dead && (s.sess sid).redialT
  | .deadlineFire sid => !s.dead && (s.sess sid).deadline
  | .localPair => !s.dead && (curSess s).bc && (curSess s).dc.isNone
  | .rtcChannel => !s.dead && (match (curSess s).pc with
      | some p => !s.offered (.rtc p) && !s.manualView | none => false)
  | .dcOpen => !s.dead && (match (curSess s).dc with
      | some (.local _) => false
      | some c => !s.raceClosed c && !s.shutClosed c && !(curSess s).rtcConnected
      | none => false)
  | .toManual => !s.dead && s.modal && !s.manualView
  | .manualReady => !s.dead && s.manualView && (curSess s).pc.isSome && !(curSess s).manualReady
  | .remint => !s.dead && s.manualView && (curSess s).manualReady && !(curSess s).confirmed
  | .confirmHost _ => !s.dead && s.manualView && (curSess s).manualReady && !(curSess s).confirmed
  | .rbStart => !s.dead && (curSess s).rtcConnected && !(curSess s).started
  | .rbProgress => !s.dead && s.rollbackMode
  | .disconnect => !s.dead && (curSess s).started
  | .launch _ => !s.dead && s.loadPending.isNone
  | .loadCommit => !s.dead && s.loadPending.isSome
  | .pagehide => !s.dead

def step (s : State) : Event → State
  -- openNetConnect (176): net = makeSession; open; if sigServerUp === false -> manualEnter()
  | .openModal =>
    let s := { newSession s with modal := true, manualView := false }
    if s.sigUp == some false then manualEnter s else s
  -- netJoinGo (1384): Cancel while dialing/listening, else rendezvous
  | .joinClick =>
    match s.cur with
    | none => s
    | some sid =>
      let x := s.sess sid
      if x.ws.isSome || x.bc then
        (if x.started then { s with modal := false } else shutdown false s)
      else
        let s := updS sid (fun x => { x with code := true, bc := true }) { s with fallback := some sid }
        sigConnect sid (.join sid) s
  -- netDismissModal (1605)
  | .dismiss =>
    if (curSess s).started || s.cur.isNone then { s with modal := false } else shutdown false s
  | .sockOpen k =>
    let y := s.socks k
    let s := updK k (fun y => { y with st := .opn }) s
    if y.detached then s
    else updK k (fun y => { y with opened := true, res := some true }) { s with sigUp := some true }
  | .sockRefused k => updK k (fun y => { y with st := .closed, errQ := true, closeQ := true }) s
  | .sockDrop k => updK k (fun y => { y with st := .closed, closeQ := true }) s
  -- ws.onerror (270)
  | .sockErr k =>
    let y := s.socks k
    let s := updK k (fun y => { y with errQ := false }) s
    if y.detached || y.opened then s
    else
      let s := { s with sigUp := some false }
      let s := if hasAltPath s then s else netFail s
      updK k (fun y => { y with res := some false }) s
  -- ws.onclose (284)
  | .sockClose k =>
    let y := s.socks k
    let s := updK k (fun y => { y with closeQ := false }) s
    if y.detached then s else
    match s.cur with
    | none => s
    | some sid =>
      let x := s.sess sid
      if x.ws != some k || x.rtcConnected || x.started || x.pc.isSome then s
      else sigRedial sid s
  -- onSigMessage (346): uses the global `net`, not the socket's session
  | .sockMsg _ paired =>
    match s.cur with
    | none => s
    | some sid =>
      let s := updS sid (fun x => { x with redials := 0, rdials := 0 }) { s with fallback := none, sigUp := some true }
      if paired && (s.sess sid).pc.isNone then
        -- startRtc (387): new pc, deadline armed
        let p := s.nextPc
        updS sid (fun x => { x with pc := some p, deadline := true }) { s with nextPc := p + 1 }
      else s
  -- the continuation after `await sigConnect()`
  | .resume k =>
    let y := s.socks k
    let s := updK k (fun y => { y with waiter := .none }) s
    match y.waiter, y.res with
    | .join sid, some ok =>
      if ok then s   -- (1406) rendezvous sent if still ours; nothing modelled changes
      else if s.cur == some sid && (s.sess sid).dc.isNone && !(s.sess sid).rtcConnected then
        manualEnter { s with fallback := none }
      else s
    | .redial sid, some ok =>
      if ok && s.cur == some sid && (s.sess sid).dc.isNone then { s with fallback := some sid } else s
    | _, _ => s
  | .fallbackFire =>
    match s.fallback with
    | none => s
    | some sid =>
      let s := { s with fallback := none }
      let x := s.sess sid
      if s.cur == some sid && x.dc.isNone && !x.rtcConnected && !x.started then
        manualEnter { s with sigUp := some false }
      else s
  | .redialFire sid =>
    let s := updS sid (fun x => { x with redialT := false }) s
    let x := s.sess sid
    if s.cur != some sid || x.dc.isSome || x.rtcConnected || x.started then s
    else sigConnect sid (.redial sid) (updS sid (fun x => { x with rdials := x.rdials + 1 }) s)
  | .deadlineFire sid =>
    let s := updS sid (fun x => { x with deadline := false }) s
    let x := s.sess sid
    if s.cur == some sid && !x.rtcConnected && !x.started then netFail s else s
  -- pair (568): LocalChannel wired, then chan.onopen() synchronously
  | .localPair =>
    match s.cur with
    | none => s
    | some sid => dcOnOpen (wireChannel (.local sid) s)
  | .rtcChannel =>
    match (curSess s).pc with
    | some p => wireChannel (.rtc p) s
    | none => s
  | .dcOpen => dcOnOpen s
  | .toManual => manualEnter s
  | .manualReady =>
    match s.cur with
    | some sid => updS sid (fun x => { x with manualReady := true }) s
    | none => s
  | .remint => manualPrepare s
  -- manualConfirmGo (816), host side: wireChannel(session.manualChan) BEFORE
  -- `await setRemoteDescription`; on failure it returns with the input editable.
  | .confirmHost ok =>
    match s.cur, (curSess s).pc with
    | some sid, some p =>
      let s := wireChannel (.manual p) s
      if ok then updS sid (fun x => { x with confirmed := true, deadline := true }) s else s
    | _, _ => s
  -- rbStartIfReady (1294) + enterRollbackMode (9250)
  | .rbStart =>
    match s.cur with
    | none => s
    | some sid =>
      let s := updS sid (fun x => { x with started := true }) s
      { s with netMode := false, rollbackMode := true, sessGame := s.game, rbV := s.solo.2,
               modal := false, manualView := false }
  | .rbProgress => { s with rbV := s.rbV + 1 }
  | .disconnect => shutdown false s
  -- loadRom (7881-7889): `if (netActive() || rollbackMode) await netShutdown()`:
  -- the session ends while currentOriginalName still names its game.
  | .launch g =>
    let s := if s.netMode || s.rollbackMode then shutdown false s else s
    { s with loadPending := some g }
  -- persistSave(outgoing) ... currentOriginalName = g; restoreSave; initFromEmscripten.
  -- 7897: a session that started during the awaits owns the core: the load
  -- returns without naming its game. 7932: an open Link Cable modal is
  -- dismissed in the segment that names the new game.
  | .loadCommit =>
    match s.loadPending with
    | none => s
    | some g =>
      if s.netMode || s.rollbackMode then { s with loadPending := none } else
      let s := if s.modal then dismissModal s else s
      let s := { s with store := put s.game s.solo s.store }
      { s with game := g, solo := s.store g, loadPending := none }
  -- pagehide (11235) / beforeunload (11209): `if (netActive() || rollbackMode)
  -- netShutdown()` (its put is issued synchronously), then
  -- persistSave(currentRomName, ...). `lostProgress`: the page died in a
  -- session whose progress is not in the store.
  | .pagehide =>
    let s1 := if s.netMode || s.rollbackMode then shutdown false s else s
    let s2 := { s1 with store := put s1.game s1.solo s1.store }
    { s2 with dead := true,
              lostProgress := s.rollbackMode && s2.store s.sessGame != (s.sessGame, s.rbV) }

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

/-! ## Invariants that hold

Timers, the redial ladder, sockets and the race's loser-closing are sound. -/

def ifT (b : Bool) : Nat := if b then 1 else 0

section proj
variable (s : State) (sid k j : Nat) (f : Sess → Sess) (g : Sock → Sock)
@[simp] theorem updS_cur : (updS sid f s).cur = s.cur := rfl
@[simp] theorem updS_fallback : (updS sid f s).fallback = s.fallback := rfl
@[simp] theorem updS_nextSid : (updS sid f s).nextSid = s.nextSid := rfl
@[simp] theorem updS_manualView : (updS sid f s).manualView = s.manualView := rfl
@[simp] theorem updS_modal : (updS sid f s).modal = s.modal := rfl
@[simp] theorem updS_socks : (updS sid f s).socks = s.socks := rfl
@[simp] theorem updS_nextSock : (updS sid f s).nextSock = s.nextSock := rfl
@[simp] theorem updS_offered : (updS sid f s).offered = s.offered := rfl
@[simp] theorem updS_raceClosed : (updS sid f s).raceClosed = s.raceClosed := rfl
@[simp] theorem updS_sess : (updS sid f s).sess j = if j = sid then f (s.sess j) else s.sess j := rfl
@[simp] theorem updK_cur : (updK k g s).cur = s.cur := rfl
@[simp] theorem updK_fallback : (updK k g s).fallback = s.fallback := rfl
@[simp] theorem updK_nextSid : (updK k g s).nextSid = s.nextSid := rfl
@[simp] theorem updK_manualView : (updK k g s).manualView = s.manualView := rfl
@[simp] theorem updK_modal : (updK k g s).modal = s.modal := rfl
@[simp] theorem updK_sess : (updK k g s).sess = s.sess := rfl
@[simp] theorem updK_nextSock : (updK k g s).nextSock = s.nextSock := rfl
@[simp] theorem updK_offered : (updK k g s).offered = s.offered := rfl
@[simp] theorem updK_raceClosed : (updK k g s).raceClosed = s.raceClosed := rfl
@[simp] theorem updK_socks : (updK k g s).socks j = if j = k then g (s.socks j) else s.socks j := rfl
end proj

def live (s : State) (k : Nat) : Prop :=
  (s.socks k).st = .connecting ∨ (s.socks k).st = .opn

/-- The socket / timer / ladder invariant. Per session `j`. -/
structure NInv (s : State) : Prop where
  freshS   : ∀ j, s.nextSid ≤ j → s.sess j = {}
  freshK   : ∀ k, s.nextSock ≤ k → s.socks k = {}
  curLt    : ∀ j, s.cur = some j → j < s.nextSid
  wsLt     : ∀ j k, (s.sess j).ws = some k → k < s.nextSock
  /-- Every live socket is the current session's `net.ws`: at most one socket
      is ever live, and none outlives its session. -/
  liveOwned : ∀ k, live s k → ∃ j, s.cur = some j ∧ (s.sess j).ws = some k
  /-- A pending redial never coexists with a live `net.ws`. -/
  redialDead : ∀ j k, (s.sess j).redialT = true → (s.sess j).ws = some k → ¬ live s k
  closeDead : ∀ k, (s.socks k).closeQ = true → ¬ live s k
  redialNoClose : ∀ j k, (s.sess j).redialT = true → (s.sess j).ws = some k → (s.socks k).closeQ = false
  /-- Timers belong to the current session only: a stale timer cannot fire into a new one. -/
  redialCur : ∀ j, (s.sess j).redialT = true → s.cur = some j
  deadlineCur : ∀ j, (s.sess j).deadline = true → s.cur = some j
  fallbackCur : ∀ j, s.fallback = some j → s.cur = some j
  modalCur : ∀ j, s.cur = some j → (s.sess j).started = false → s.modal = true
  manualNoWs : ∀ j, s.manualView = true → s.cur = some j → (s.sess j).ws = none
  manualNoRedial : ∀ j, s.manualView = true → (s.sess j).redialT = false
  redialWs : ∀ j, (s.sess j).redialT = true → (s.sess j).ws.isSome = true ∨ (s.sess j).bc = true
  redialPc : ∀ j, (s.sess j).redialT = true → (s.sess j).pc = none
  dcPc : ∀ j c, s.cur = some j → (s.sess j).dc = some c → (∀ i, c ≠ .local i) →
           (s.sess j).pc.isSome = true
  /-- The redial ladder: at most three reconnect dials between server replies. -/
  ladder : ∀ j, (s.sess j).redialT = true → (s.sess j).rdials + 1 ≤ (s.sess j).redials
  ladderLe : ∀ j, (s.sess j).rdials ≤ (s.sess j).redials
  ladderCap : ∀ j, (s.sess j).redialT = true → (s.sess j).redials ≤ 3
  rdCap : ∀ j, (s.sess j).rdials ≤ 3

theorem ninv_init : NInv init := by
  constructor <;> simp [init, live]

@[simp] theorem closeF_st (y : Sock) :
    (closeF y).st = (if y.st = .connecting ∨ y.st = .opn then .closing else y.st) := by
  unfold closeF; cases h : y.st <;> simp [h]
@[simp] theorem closeF_closeQ (y : Sock) :
    (closeF y).closeQ = (if y.st = .connecting ∨ y.st = .opn then true else y.closeQ) := by
  unfold closeF; cases h : y.st <;> simp [h]

/-- Fields NInv reads. -/
structure Obs (s t : State) : Prop where
  cur : t.cur = s.cur
  nextSid : t.nextSid = s.nextSid
  nextSock : t.nextSock = s.nextSock
  fallback : t.fallback = s.fallback
  modal : t.modal = s.modal
  manualView : t.manualView = s.manualView
  sess : t.sess = s.sess
  socks : t.socks = s.socks

theorem ninv_congr {s t : State} (h : NInv s) (o : Obs s t) : NInv t := by
  obtain ⟨o1, o2, o3, o4, o5, o6, o7, o8⟩ := o
  obtain ⟨i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15, i16, i17, i18, i19, i20, i21⟩ := h
  constructor <;> simp only [live, o1, o2, o3, o4, o5, o6, o7, o8] <;> assumption

syntax "ninv_tac" "[" Lean.Parser.Tactic.simpLemma,* "]" : tactic
macro_rules
  | `(tactic| ninv_tac [$ls,*]) => `(tactic| (
      obtain ⟨i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15, i16, i17, i18, i19, i20, i21⟩ := ‹NInv _›
      constructor <;> intros <;>
        simp only [live, updK_socks, updK_sess, updK_cur, updK_nextSock, updK_nextSid, updK_fallback,
          updK_modal, updK_manualView, updS_socks, updS_sess, updS_cur, updS_nextSock, updS_nextSid,
          updS_fallback, updS_modal, updS_manualView, closeF_st, closeF_closeQ, apply_ite Sock.st, apply_ite Sock.closeQ, apply_ite Sess.ws, apply_ite Sess.redialT, apply_ite Sess.deadline, apply_ite Sess.bc, apply_ite Sess.pc, apply_ite Sess.dc, apply_ite Sess.started, apply_ite Sess.redials, apply_ite Sess.rdials, apply_ite Sess.rtcConnected, $ls,*] at * <;> grind))

theorem ninv_newSession {s : State} (h : NInv s) (hc : s.cur = none) (hm : s.modal = true) :
    NInv (newSession s) := by
  ninv_tac [newSession]

theorem ninv_shutdown {s : State} (h : NInv s) (keep : Bool) : NInv (shutdown keep s) := by
  obtain ⟨i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15, i16, i17, i18, i19, i20, i21⟩ := h
  unfold shutdown shutSess shutSock curSess curWs
  cases hc : s.cur with
  | none =>
    constructor <;> intros <;> simp only [live, apply_ite Sock.st, apply_ite Sock.closeQ, apply_ite Sess.ws, apply_ite Sess.redialT, apply_ite Sess.deadline, apply_ite Sess.bc, apply_ite Sess.pc, apply_ite Sess.dc, apply_ite Sess.started, apply_ite Sess.redials, apply_ite Sess.rdials, apply_ite Sess.rtcConnected] at * <;> grind
  | some sid =>
    constructor <;> intros <;> simp only [live, closeF_st, closeF_closeQ, apply_ite Sock.st, apply_ite Sock.closeQ, apply_ite Sess.ws, apply_ite Sess.redialT, apply_ite Sess.deadline, apply_ite Sess.bc, apply_ite Sess.pc, apply_ite Sess.dc, apply_ite Sess.started, apply_ite Sess.redials, apply_ite Sess.rdials, apply_ite Sess.rtcConnected] at * <;> grind

@[simp] theorem shutdown_cur (keep : Bool) (s : State) : (shutdown keep s).cur = none := rfl
@[simp] theorem shutdown_modal (keep : Bool) (s : State) : (shutdown keep s).modal = (keep && s.modal) := rfl

theorem ninv_netFail {s : State} (h : NInv s) : NInv (netFail s) := by
  unfold netFail
  cases hc : s.cur with
  | some sid =>
    simp only
    split
    · exact ninv_shutdown h false
    · split
      · exact ninv_newSession (ninv_shutdown h true) rfl (by assumption)
      · exact ninv_shutdown h true
  | none =>
    simp only
    split
    · exact ninv_newSession (ninv_shutdown h true) rfl (by assumption)
    · exact ninv_shutdown h true

theorem ninv_manualEnter {s : State} (h : NInv s) : NInv (manualEnter s) := by
  unfold manualEnter
  split
  · exact h
  · cases hc : s.cur with
    | none => exact h
    | some sid =>
      simp only
      split
      · exact h
      · ninv_tac [hc]

theorem ninv_manualPrepare {s : State} (h : NInv s)
    (hr : ∀ j, s.cur = some j → (s.sess j).redialT = false) : NInv (manualPrepare s) := by
  unfold manualPrepare
  cases hc : s.cur with
  | none => exact h
  | some sid => simp only; ninv_tac [hc]

theorem ninv_sigConnect {s : State} (h : NInv s) (sid : Nat) (w : Waiter) (hc : s.cur = some sid)
    (hws : ∀ k, (s.sess sid).ws = some k → ¬ live s k) (hr : (s.sess sid).redialT = false)
    (hmv : s.manualView = false) : NInv (sigConnect sid w s) := by
  unfold sigConnect
  ninv_tac []

theorem ninv_sigRedial {s : State} (h : NInv s) (sid k : Nat) (hc : s.cur = some sid)
    (hws : (s.sess sid).ws = some k) (hk : ¬ live s k) (hcq : (s.socks k).closeQ = false)
    (hpc : (s.sess sid).pc = none) (hr : (s.sess sid).redialT = false) : NInv (sigRedial sid s) := by
  unfold sigRedial
  simp only
  split
  · exact h
  · have h1 : NInv (updS sid (fun x => { x with redials := x.redials + 1 }) { s with fallback := none }) := by
      ninv_tac []
    split
    · apply ninv_manualEnter
      exact ninv_congr h1 ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩
    · clear h1; ninv_tac []

theorem ninv_wireChannel {s : State} (h : NInv s) (c : Chan)
    (hpc : ∀ p, (c = .rtc p ∨ c = .manual p) → (curSess s).pc = some p) : NInv (wireChannel c s) := by
  unfold wireChannel
  cases hc : s.cur with
  | none => exact h
  | some sid =>
    simp only [curSess, hc] at hpc
    simp only
    split
    · ninv_tac [hc]
    · cases c with
      | «local» i => ninv_tac [hc]
      | rtc p => have := hpc p (Or.inl rfl); ninv_tac [hc]
      | manual p => have := hpc p (Or.inr rfl); ninv_tac [hc]

theorem ninv_dcOnOpen {s : State} (h : NInv s)
    (hb : ∀ sid, s.cur = some sid → (s.sess sid).redialT = true → (s.sess sid).bc = true) :
    NInv (dcOnOpen s) := by
  unfold dcOnOpen
  cases hc : s.cur with
  | none => exact h
  | some sid =>
    simp only
    cases hw : (s.sess sid).ws with
    | none => simp only [closeWsOpt]; ninv_tac []
    | some k => simp only [closeWsOpt, closeSock]; ninv_tac []

theorem ninv_updK_keep {s : State} (h : NInv s) (k : Nat) (hk : k < s.nextSock) (g : Sock → Sock)
    (hs : ∀ y, (g y).st = y.st) (hq : ∀ y, (g y).closeQ = y.closeQ) : NInv (updK k g s) := by
  ninv_tac []

@[simp] theorem wireChannel_cur (c : Chan) (s : State) : (wireChannel c s).cur = s.cur := by
  unfold wireChannel
  split
  · rfl
  · simp only; split
    · rfl
    · split <;> rfl

theorem wireChannel_local_bc (i j : Nat) (s : State) :
    ((wireChannel (.local i) s).sess j).bc = (s.sess j).bc := by
  unfold wireChannel
  split
  · rfl
  · simp only; split
    · rfl
    · simp only [updS_sess]; split <;> rfl

theorem netFail_nextSock (s : State) : (netFail s).nextSock = s.nextSock := by
  unfold netFail newSession
  split
  · split
    · rfl
    · simp only; split <;> rfl
  · simp only; split <;> rfl

theorem live_of_ws {s : State} (h : NInv s) {sid k : Nat} (hr : (s.sess sid).redialT = true)
    (hw : (s.sess sid).ws = some k) : ¬ live s k := h.redialDead sid k hr hw

theorem ninv_ev_openModal {s : State}  (h : NInv s) (he : en s (.openModal) = true) :
    NInv (step s (.openModal)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp [en] at he
  have h0 : NInv { newSession s with modal := true, manualView := false } := by
    have := he.2; unfold newSession; ninv_tac []
  simp only [step]
  split
  · exact ninv_manualEnter h0
  · exact h0

theorem ninv_ev_joinClick {s : State}  (h : NInv s) (he : en s (.joinClick) = true) :
    NInv (step s (.joinClick)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  cases hc : s.cur with
  | none => exact h
  | some sid =>
    simp only
    split
    · split
      · ninv_tac [hc]
      · exact ninv_shutdown h false
    · rename_i hn
      simp at hn
      simp [en] at he
      have hr : (s.sess sid).redialT = false := by
        cases hh : (s.sess sid).redialT
        · rfl
        · have := h.redialWs sid hh; simp [hn.1, hn.2] at this
      have h1 : NInv (updS sid (fun x => { x with code := true, bc := true }) { s with fallback := some sid }) := by
        ninv_tac [hc]
      have hmv : s.manualView = false := by grind
      have h2 := ninv_sigConnect h1 sid (.join sid) (by simpa using hc)
        (by intro k hk; simp [hn.1] at hk) (by simpa using hr) (by simpa using hmv)
      exact ninv_congr h2 ⟨by simp [sigConnect, hc], rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem ninv_ev_dismiss {s : State}  (h : NInv s) (he : en s (.dismiss) = true) :
    NInv (step s (.dismiss)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  split
  · rename_i hs
    have hcs := hs
    obtain ⟨i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15, i16, i17, i18, i19, i20, i21⟩ := h
    constructor <;> intros <;> simp only [live, curSess] at * <;> (try split at hcs) <;> grind
  · exact ninv_shutdown h false

theorem ninv_ev_sockOpen {s : State} (k : Nat) (h : NInv s) (he : en s (.sockOpen k) = true) :
    NInv (step s (.sockOpen k)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp [en] at he
  simp only [step]
  split <;> ninv_tac []

theorem ninv_ev_sockRefused {s : State} (k : Nat) (h : NInv s) (he : en s (.sockRefused k) = true) :
    NInv (step s (.sockRefused k)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  have hst : (s.socks k).st = .connecting := by simp [en] at he; grind
  clear he
  simp only [step]; ninv_tac []

theorem ninv_ev_sockDrop {s : State} (k : Nat) (h : NInv s) (he : en s (.sockDrop k) = true) :
    NInv (step s (.sockDrop k)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  have hst : (s.socks k).st = .opn := by simp [en] at he; grind
  clear he
  simp only [step]; ninv_tac []

theorem ninv_ev_sockErr {s : State} (k : Nat) (h : NInv s) (he : en s (.sockErr k) = true) :
    NInv (step s (.sockErr k)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  have hk : k < s.nextSock := by
    rcases Nat.lt_or_ge k s.nextSock with h' | h'
    · exact h'
    · have := h.freshK k h'; simp [en, this] at he
  have h1 : NInv (updK k (fun y => { y with errQ := false }) s) :=
    ninv_updK_keep h k hk _ (fun _ => rfl) (fun _ => rfl)
  simp only [step]
  split
  · exact h1
  · have h2 : NInv { (updK k (fun y => { y with errQ := false }) s) with sigUp := some false } :=
      ninv_congr h1 ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩
    split
    · exact ninv_updK_keep h2 k hk _ (fun _ => rfl) (fun _ => rfl)
    · have h3 := ninv_netFail h2
      exact ninv_updK_keep h3 k (by rw [netFail_nextSock]; exact hk) _ (fun _ => rfl) (fun _ => rfl)

theorem ninv_ev_sockClose {s : State} (k : Nat) (h : NInv s) (he' : en s (.sockClose k) = true) :
    NInv (step s (.sockClose k)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  have he : (s.socks k).closeQ = true := by simp [en] at he'; grind
  clear he'
  simp only [step]
  split
  · ninv_tac []
  · have h1 : NInv (updK k (fun y => { y with closeQ := false }) s) := by ninv_tac []
    cases hc : s.cur with
    | none => simpa [hc] using h1
    | some sid =>
      simp only [updK_cur, hc]
      split
      · exact h1
      · rename_i hcond
        simp at hcond
        obtain ⟨⟨⟨hw, hrtc⟩, hst⟩, hpc⟩ := hcond
        have hk : ¬ live s k := h.closeDead k he
        have hr : (s.sess sid).redialT = false := by
          cases hh : (s.sess sid).redialT
          · rfl
          · have := h.redialNoClose sid k hh hw; rw [he] at this; cases this
        apply ninv_sigRedial h1 sid k (by simpa using hc) (by simpa using hw)
        · simp only [live, updK_socks]; simpa [live] using hk
        · simp
        · simpa using hpc
        · simpa using hr

theorem ninv_ev_sockMsg {s : State} (k : Nat) (paired : Bool) (h : NInv s) (he : en s (.sockMsg k paired) = true) :
    NInv (step s (.sockMsg k paired)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  have hst : (s.socks k).st = .opn := by simp [en] at he; grind
  have hl : live s k := Or.inr hst
  obtain ⟨sid, hc, hw⟩ := h.liveOwned k hl
  have hr : (s.sess sid).redialT = false := by
    cases hh : (s.sess sid).redialT
    · rfl
    · exact absurd hl (h.redialDead sid k hh hw)
  simp only [step]
  split
  · rename_i hn; rw [hc] at hn; cases hn
  · rename_i sid' hc'
    rw [hc] at hc'; cases hc'
    split
    · ninv_tac []
    · ninv_tac []

theorem ninv_ev_resume {s : State} (k : Nat) (h : NInv s) (he : en s (.resume k) = true) :
    NInv (step s (.resume k)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  have h1 : NInv (updK k (fun y => { y with waiter := .none }) s) := by ninv_tac []
  split
  · split
    · exact h1
    · split
      · apply ninv_manualEnter; clear h1; ninv_tac []
      · exact h1
  · split
    · clear h1; ninv_tac []
    · exact h1
  · exact h1

theorem ninv_ev_fallbackFire {s : State}  (h : NInv s) (he : en s (.fallbackFire) = true) :
    NInv (step s (.fallbackFire)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  split
  · exact h
  · split
    · apply ninv_manualEnter; ninv_tac []
    · ninv_tac []

theorem ninv_ev_redialFire {s : State} (sid : Nat) (h : NInv s) (he' : en s (.redialFire sid) = true) :
    NInv (step s (.redialFire sid)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  have he : (s.sess sid).redialT = true := by simp [en] at he'; grind
  clear he'
  simp only [step]
  have h1 : NInv (updS sid (fun x => { x with redialT := false }) s) := by ninv_tac []
  split
  · exact h1
  · rename_i hcond
    simp at hcond
    have hc : s.cur = some sid := h.redialCur sid he
    have hmv : s.manualView = false := by
      cases hm : s.manualView
      · rfl
      · have := h.manualNoRedial sid hm; rw [he] at this; cases this
    have h2 : NInv (updS sid (fun x => { x with rdials := x.rdials + 1 })
        (updS sid (fun x => { x with redialT := false }) s)) := by
      clear h1
      have := h.ladder sid he; have := h.ladderCap sid he
      ninv_tac []
    apply ninv_sigConnect h2 sid _ (by simpa using hc)
    · intro k hk; simp at hk; simpa [live] using h.redialDead sid k he hk
    · simp
    · simpa using hmv

theorem ninv_ev_deadlineFire {s : State} (sid : Nat) (h : NInv s) (he : en s (.deadlineFire sid) = true) :
    NInv (step s (.deadlineFire sid)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  have h1 : NInv (updS sid (fun x => { x with deadline := false }) s) := by ninv_tac []
  split
  · exact ninv_netFail h1
  · exact h1

theorem ninv_ev_localPair {s : State}  (h : NInv s) (he : en s (.localPair) = true) :
    NInv (step s (.localPair)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  split
  · exact h
  · rename_i sid hc
    have hbc : (s.sess sid).bc = true := by simp [en, curSess, hc] at he; grind
    apply ninv_dcOnOpen (ninv_wireChannel h _ (by intro p hp; cases hp <;> cases ‹_ = _›))
    intro j hj _
    rw [wireChannel_cur, hc] at hj; cases hj
    rw [wireChannel_local_bc]; exact hbc

theorem ninv_ev_rtcChannel {s : State}  (h : NInv s) (he : en s (.rtcChannel) = true) :
    NInv (step s (.rtcChannel)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  split
  · rename_i p hp
    exact ninv_wireChannel h _ (by intro q hq; cases hq <;> simp_all)
  · exact h

theorem ninv_ev_dcOpen {s : State}  (h : NInv s) (he : en s (.dcOpen) = true) :
    NInv (step s (.dcOpen)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  apply ninv_dcOnOpen h
  intro sid hc hr
  have hpc := h.redialPc sid hr
  cases hd : (s.sess sid).dc with
  | none => simp [en, curSess, hc, hd] at he
  | some c =>
    cases c with
    | «local» i => simp [en, curSess, hc, hd] at he
    | rtc p =>
      have := h.dcPc sid _ hc hd (by intro i hi; cases hi)
      rw [hpc] at this; cases this
    | manual p =>
      have := h.dcPc sid _ hc hd (by intro i hi; cases hi)
      rw [hpc] at this; cases this

theorem ninv_ev_toManual {s : State}  (h : NInv s) (he : en s (.toManual) = true) :
    NInv (step s (.toManual)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  exact ninv_manualEnter h

theorem ninv_ev_manualReady {s : State}  (h : NInv s) (he : en s (.manualReady) = true) :
    NInv (step s (.manualReady)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  split
  · ninv_tac []
  · exact h

theorem ninv_ev_remint {s : State}  (h : NInv s) (he : en s (.remint) = true) :
    NInv (step s (.remint)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  have hmv : s.manualView = true := by simp [en] at he; grind
  exact ninv_manualPrepare h (fun j _ => h.manualNoRedial j hmv)

theorem ninv_ev_confirmHost {s : State} (ok : Bool) (h : NInv s) (he : en s (.confirmHost ok) = true) :
    NInv (step s (.confirmHost ok)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  split
  · rename_i sid p hc hp
    have hw := ninv_wireChannel h (.manual p) (by intro q hq; cases hq <;> simp_all)
    split
    · have hcur : (wireChannel (.manual p) s).cur = some sid := by
        unfold wireChannel; rw [hc]; simp only; split <;> (try split) <;> simp [hc]
      clear h; ninv_tac [hcur]
    · exact hw
  · exact h

theorem ninv_ev_rbStart {s : State}  (h : NInv s) (he : en s (.rbStart) = true) :
    NInv (step s (.rbStart)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  split
  · exact h
  · ninv_tac []

theorem ninv_ev_rbProgress {s : State}  (h : NInv s) (he : en s (.rbProgress) = true) :
    NInv (step s (.rbProgress)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  exact obs _ ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem ninv_ev_disconnect {s : State}  (h : NInv s) (he : en s (.disconnect) = true) :
    NInv (step s (.disconnect)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  exact ninv_shutdown h false

theorem ninv_ev_launch {s : State} (g : Nat) (h : NInv s) (he : en s (.launch g) = true) :
    NInv (step s (.launch g)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  split
  · exact ninv_congr (ninv_shutdown h false) ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩
  · exact obs _ ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem ninv_ev_loadCommit {s : State}  (h : NInv s) (he : en s (.loadCommit) = true) :
    NInv (step s (.loadCommit)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  split
  · exact h
  · split
    · exact obs _ ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩
    · have hd : NInv (if s.modal then dismissModal s else s) := by
        split
        · rename_i hm
          have hen : en s .dismiss = true := by
            simp only [en, Bool.and_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true] at he ⊢
            exact ⟨he.1, hm⟩
          exact ninv_ev_dismiss h hen
        · exact h
      generalize (if s.modal then dismissModal s else s) = t at hd ⊢
      exact ninv_congr hd ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem ninv_ev_pagehide {s : State}  (h : NInv s) (he : en s (.pagehide) = true) :
    NInv (step s (.pagehide)) := by
  have obs := fun (t : State) (o : Obs s t) => ninv_congr h o
  simp only [step]
  split
  · exact ninv_congr (ninv_shutdown h false) ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩
  · exact obs _ ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem ninv_step {s : State} {e : Event} (h : NInv s) (he : en s e = true) : NInv (step s e) := by
  cases e with
  | openModal => exact ninv_ev_openModal  h he
  | joinClick => exact ninv_ev_joinClick  h he
  | dismiss => exact ninv_ev_dismiss  h he
  | sockOpen k => exact ninv_ev_sockOpen k h he
  | sockRefused k => exact ninv_ev_sockRefused k h he
  | sockDrop k => exact ninv_ev_sockDrop k h he
  | sockErr k => exact ninv_ev_sockErr k h he
  | sockClose k => exact ninv_ev_sockClose k h he
  | sockMsg k paired => exact ninv_ev_sockMsg k paired h he
  | resume k => exact ninv_ev_resume k h he
  | fallbackFire => exact ninv_ev_fallbackFire  h he
  | redialFire sid => exact ninv_ev_redialFire sid h he
  | deadlineFire sid => exact ninv_ev_deadlineFire sid h he
  | localPair => exact ninv_ev_localPair  h he
  | rtcChannel => exact ninv_ev_rtcChannel  h he
  | dcOpen => exact ninv_ev_dcOpen  h he
  | toManual => exact ninv_ev_toManual  h he
  | manualReady => exact ninv_ev_manualReady  h he
  | remint => exact ninv_ev_remint  h he
  | confirmHost ok => exact ninv_ev_confirmHost ok h he
  | rbStart => exact ninv_ev_rbStart  h he
  | rbProgress => exact ninv_ev_rbProgress  h he
  | disconnect => exact ninv_ev_disconnect  h he
  | launch g => exact ninv_ev_launch g h he
  | loadCommit => exact ninv_ev_loadCommit  h he
  | pagehide => exact ninv_ev_pagehide  h he

theorem ninv_reachable {s : State} (h : Reachable s) : NInv s := by
  induction h with
  | init => exact ninv_init
  | step e _ he ih => exact ninv_step ih he

/-- Leaving online play leaves no live signaling socket behind. -/
theorem no_live_socket_after_leave {s : State} (h : Reachable s) (hc : s.cur = none) (k : Nat) :
    ¬ live s k := by
  intro hl
  obtain ⟨j, hj, _⟩ := (ninv_reachable h).liveOwned k hl
  rw [hc] at hj; cases hj

/-- At most one signaling socket is ever live. -/
theorem at_most_one_live_socket {s : State} (h : Reachable s) (k1 k2 : Nat)
    (h1 : live s k1) (h2 : live s k2) : k1 = k2 := by
  have hi := ninv_reachable h
  obtain ⟨j1, hj1, hw1⟩ := hi.liveOwned k1 h1
  obtain ⟨j2, hj2, hw2⟩ := hi.liveOwned k2 h2
  rw [hj1] at hj2; cases hj2
  rw [hw1] at hw2; cases hw2; rfl

/-- Pending redial / pairing-deadline / fallback timers only ever belong to the
    current session: after `netShutdown`, none from the old session remains. -/
theorem timers_belong_to_current {s : State} (h : Reachable s) (j : Nat) :
    ((s.sess j).redialT = true → s.cur = some j) ∧ ((s.sess j).deadline = true → s.cur = some j) ∧
    (s.fallback = some j → s.cur = some j) :=
  have hi := ninv_reachable h
  ⟨hi.redialCur j, hi.deadlineCur j, hi.fallbackCur j⟩

/-- The redial ladder is bounded: at most three reconnect dials between two
    server replies (each behind its own 1 s / 2 s / 4 s timer event), and no
    redial is pending while a socket is live. -/
theorem redial_bounded {s : State} (h : Reachable s) (j : Nat) :
    (s.sess j).rdials ≤ 3 ∧ ((s.sess j).redialT = true → (s.sess j).redials ≤ 3) :=
  have hi := ninv_reachable h
  ⟨hi.rdCap j, hi.ladderCap j⟩

/-! ### The race's loser is always closed -/

/-- Every channel offered to wireChannel was closed as the loser or installed
    as a session's `net.dc` (`wired`, set exactly where wireChannel assigns
    `net.dc`, which nothing ever unsets). -/
def LInv (s : State) : Prop :=
  ∀ c, s.offered c = true → s.raceClosed c = true ∨ s.wired c = true

theorem linv_init : LInv init := by intro c hc; simp [init] at hc

/-- The three fields LInv reads. -/
def Tr (s : State) : (Chan → Bool) × (Chan → Bool) × (Chan → Bool) := (s.offered, s.raceClosed, s.wired)

theorem linv_tr {s t : State} (h : LInv s) (e : Tr t = Tr s) : LInv t := by
  simp only [Tr, Prod.mk.injEq] at e
  obtain ⟨e1, e2, e3⟩ := e
  intro c hc; rw [e2, e3]; rw [e1] at hc; exact h c hc

section tr
variable (s : State)
@[simp] theorem tr_updS (sid : Nat) (f : Sess → Sess) : Tr (updS sid f s) = Tr s := rfl
@[simp] theorem tr_updK (k : Nat) (g : Sock → Sock) : Tr (updK k g s) = Tr s := rfl
@[simp] theorem tr_shutdown (keep : Bool) : Tr (shutdown keep s) = Tr s := rfl
@[simp] theorem tr_dismissModal : Tr (dismissModal s) = Tr s := by
  unfold dismissModal; split <;> rfl
@[simp] theorem tr_newSession : Tr (newSession s) = Tr s := rfl
@[simp] theorem tr_closeWsOpt (o : Option Nat) : Tr (closeWsOpt o s) = Tr s := by
  cases o <;> rfl
@[simp] theorem tr_netFail : Tr (netFail s) = Tr s := by
  unfold netFail; split
  · split
    · rfl
    · simp only; split <;> rfl
  · simp only; split <;> rfl
@[simp] theorem tr_manualEnter : Tr (manualEnter s) = Tr s := by
  unfold manualEnter; split
  · rfl
  · split
    · rfl
    · simp only; split <;> rfl
@[simp] theorem tr_manualPrepare : Tr (manualPrepare s) = Tr s := by
  unfold manualPrepare; split <;> rfl
@[simp] theorem tr_sigConnect (sid : Nat) (w : Waiter) : Tr (sigConnect sid w s) = Tr s := rfl
@[simp] theorem tr_sigRedial (sid : Nat) : Tr (sigRedial sid s) = Tr s := by
  unfold sigRedial; simp only; split
  · rfl
  · split
    · rw [tr_manualEnter]; rfl
    · rfl
@[simp] theorem tr_dcOnOpen : Tr (dcOnOpen s) = Tr s := by
  unfold dcOnOpen; split
  · rfl
  · simp only [tr_updS, tr_closeWsOpt]
end tr

theorem linv_wireChannel {s : State} (h : LInv s) (c : Chan) : LInv (wireChannel c s) := by
  unfold wireChannel
  split
  · exact h
  · rename_i sid _
    simp only
    split
    · intro d hd
      simp only [setF] at hd ⊢
      by_cases hdc : d = c
      · simp [hdc]
      · simp [hdc] at hd ⊢; exact h d hd
    · have base : LInv (updS sid (fun x => { x with dc := some c })
          { ({ s with offered := setF c s.offered }) with wired := setF c s.wired }) := by
        intro d hd
        simp only [updS_offered, setF] at hd
        by_cases hdc : d = c
        · right; simp [updS, setF, hdc]
        · simp [hdc] at hd
          rcases h d hd with h1 | h1
          · left; simpa [updS] using h1
          · right; simp [updS, setF, hdc, h1]
      split
      · exact base
      · exact linv_tr base rfl

theorem linv_step {s : State} (h : LInv s) (e : Event) : LInv (step s e) := by
  cases e with
  | localPair =>
    simp only [step]; split
    · exact h
    · exact linv_tr (linv_wireChannel h _) (tr_dcOnOpen _)
  | rtcChannel =>
    simp only [step]; split
    · exact linv_wireChannel h _
    · exact h
  | confirmHost ok =>
    simp only [step]; split
    · split
      · exact linv_tr (linv_wireChannel h _) (tr_updS _ _ _)
      · exact linv_wireChannel h _
    · exact h
  | loadCommit =>
    apply linv_tr h
    simp only [step]
    split
    · rfl
    · split
      · rfl
      · split
        · exact tr_dismissModal s
        · rfl
  | _ =>
    apply linv_tr h
    simp only [step]
    (repeat' split) <;>
      first
        | rfl
        | (simp only [tr_updS, tr_updK, tr_shutdown, tr_newSession, tr_closeWsOpt, tr_netFail,
            tr_manualEnter, tr_manualPrepare, tr_sigConnect, tr_sigRedial, tr_dcOnOpen, tr_dismissModal]; done)
        | (simp only [tr_updS, tr_updK, tr_shutdown, tr_newSession, tr_closeWsOpt, tr_netFail,
            tr_manualEnter, tr_manualPrepare, tr_sigConnect, tr_sigRedial, tr_dcOnOpen, tr_dismissModal]; rfl)

/-- Every channel ever handed to wireChannel is either installed as a
    session's `net.dc` or was closed by the race: the loser is always torn down.
    (Nothing here says the installed channel is itself still open: see
    `bug_manual_retry_closes_own_channel`.) -/
theorem loser_closed {s : State} (h : Reachable s) : LInv s := by
  induction h with
  | init => exact linv_init
  | step e _ _ ih => exact linv_step ih e

/-! ### Saves: every record holds its own game, whatever runs during a session

At dd7ba741f this held only with no launch or page teardown during a rollback
session (the traces at the end). A launch and a page teardown now end the
session first, and a load that a session overtook names nothing: every
IndexedDB save record holds its own game's data, and ending the session, by
Disconnect, a launch or the page going away, persists its progress. -/

structure SInv (s : State) : Prop where
  keyed   : ∀ g, (s.store g).1 = g
  soloOwn : s.solo.1 = s.game
  sessOwn : s.rollbackMode = true → s.sessGame = s.game
  rbLive  : s.rollbackMode = true → (curSess s).started = true
  noLoss  : s.lostProgress = false

/-- What SInv reads. -/
def Sv (s : State) := (s.store, s.solo, s.game, s.sessGame, s.rollbackMode, s.lostProgress, (curSess s).started)

theorem sinv_sv {s t : State} (h : SInv s) (e : Sv t = Sv s) : SInv t := by
  simp only [Sv, Prod.mk.injEq] at e
  obtain ⟨e1, e2, e3, e4, e5, e6, e7⟩ := e
  obtain ⟨a1, a2, a3, a4, a5⟩ := h
  exact ⟨by rw [e1]; exact a1, by rw [e2, e3]; exact a2, by rw [e5, e4, e3]; exact a3,
    by rw [e5, e7]; exact a4, by rw [e6]; exact a5⟩

section sv
variable (s : State)
theorem sv_updS (sid : Nat) (f : Sess → Sess) (hf : ∀ x, (f x).started = x.started) :
    Sv (updS sid f s) = Sv s := by
  simp only [Sv, curSess, updS_cur]
  split
  · simp only [updS_sess]; split <;> simp [hf, updS]
  · rfl
end sv

/-- Peel `updS` layers whose function keeps `started`, then close by `rfl`. -/
macro "sv_tac" : tactic => `(tactic| ((try simp only []) <;> (repeat' rw [sv_updS]) <;> first | rfl | (intro _; rfl)))

section sv2
variable (s : State)
theorem sv_updK (k : Nat) (g : Sock → Sock) : Sv (updK k g s) = Sv s := rfl
theorem sv_closeWsOpt (o : Option Nat) : Sv (closeWsOpt o s) = Sv s := by cases o <;> rfl
theorem sv_manualEnter : Sv (manualEnter s) = Sv s := by
  unfold manualEnter; split
  · rfl
  · split
    · rfl
    · rename_i sid hc
      simp only; split
      · rfl
      · simp only [Sv, curSess, hc]; simp
theorem sv_manualPrepare : Sv (manualPrepare s) = Sv s := by
  unfold manualPrepare; split
  · rfl
  · sv_tac
theorem sv_sigConnect (sid : Nat) (w : Waiter) : Sv (sigConnect sid w s) = Sv s := by
  unfold sigConnect; sv_tac
theorem sv_sigRedial (sid : Nat) : Sv (sigRedial sid s) = Sv s := by
  unfold sigRedial; simp only; split
  · rfl
  · have a : Sv (updS sid (fun x => { x with redials := x.redials + 1 }) { s with fallback := none }) = Sv s := by
      sv_tac
    split
    · rw [sv_manualEnter]; exact a
    · rw [sv_updS]
      · exact a
      · intro _; rfl
theorem sv_dcOnOpen : Sv (dcOnOpen s) = Sv s := by
  unfold dcOnOpen; split
  · rfl
  · simp only
    rw [sv_updS, sv_closeWsOpt]
    · sv_tac
    · intro _; rfl
theorem sv_wireChannel (c : Chan) : Sv (wireChannel c s) = Sv s := by
  unfold wireChannel; split
  · rfl
  · simp only; split
    · rfl
    · split
      · sv_tac
      · sv_tac
end sv2

theorem sinv_init : SInv init := by
  constructor <;> simp [init, curSess]

/-- netShutdown with a live rollback core persists it under its own game. -/
theorem sinv_shutdown {s : State} (h : SInv s) (keep : Bool) : SInv (shutdown keep s) := by
  obtain ⟨a1, a2, a3, a4, a5⟩ := h
  have hcur : curSess (shutdown keep s) = {} := by simp [curSess, shutdown]
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · intro g; simp only [shutdown]
    split
    · rename_i hrb
      simp only [Bool.and_eq_true] at hrb
      simp only [put]; split
      · subst_vars; rw [a3 hrb.2]
      · exact a1 g
    · exact a1 g
  · simp only [shutdown]; split
    · rename_i hrb; simp only [Bool.and_eq_true] at hrb; exact a3 hrb.2
    · exact a2
  · intro hr; simp only [shutdown] at hr ⊢
    split at hr
    · simp at hr
    · exact a3 hr
  · intro hr; simp only [shutdown] at hr
    split at hr
    · simp at hr
    · rename_i hrb
      exfalso; apply hrb; simp [a4 hr, hr]
  · exact a5

theorem sinv_newSession {s : State} (h : SInv s) (hr : s.rollbackMode = false) : SInv (newSession s) :=
  ⟨h.keyed, h.soloOwn, fun h' => by simp [newSession, hr] at h', fun h' => by simp [newSession, hr] at h',
   h.noLoss⟩

theorem shutdown_rb_false {s : State} (h : SInv s) (keep : Bool) : (shutdown keep s).rollbackMode = false := by
  simp only [shutdown]
  split
  · rfl
  · rename_i hrb
    cases hr : s.rollbackMode
    · rfl
    · exfalso; apply hrb; simp [h.rbLive hr, hr]

theorem sinv_netFail {s : State} (h : SInv s) : SInv (netFail s) := by
  unfold netFail
  split
  · split
    · exact sinv_shutdown h false
    · simp only; split
      · exact sinv_newSession (sinv_shutdown h true) (shutdown_rb_false h true)
      · exact sinv_shutdown h true
  · simp only; split
    · exact sinv_newSession (sinv_shutdown h true) (shutdown_rb_false h true)
    · exact sinv_shutdown h true

theorem sinv_step {s : State} {e : Event} (hn : NInv s) (h : SInv s) (he : en s e = true) :
    SInv (step s e) := by
  cases e with
  | openModal =>
    have hc : s.cur = none := by simp [en] at he; grind
    have hr : s.rollbackMode = false := by
      cases hh : s.rollbackMode
      · rfl
      · have := h.rbLive hh; simp [curSess, hc] at this
    have a : SInv { newSession s with modal := true, manualView := false } :=
      sinv_sv (sinv_newSession h hr) rfl
    simp only [step]; split
    · exact sinv_sv a (sv_manualEnter _)
    · exact a
  | joinClick =>
    simp only [step]; split
    · exact h
    · split
      · split
        · exact sinv_sv h rfl
        · exact sinv_shutdown h false
      · exact sinv_sv h (by rw [sv_sigConnect]; sv_tac)
  | dismiss =>
    simp only [step]; split
    · exact sinv_sv h rfl
    · exact sinv_shutdown h false
  | sockOpen k =>
    simp only [step]; split
    · exact sinv_sv h rfl
    · exact sinv_sv h rfl
  | sockRefused k => exact sinv_sv h rfl
  | sockDrop k => exact sinv_sv h rfl
  | sockErr k =>
    simp only [step]; split
    · exact sinv_sv h rfl
    · have a : SInv { (updK k (fun y => { y with errQ := false }) s) with sigUp := some false } :=
        sinv_sv h rfl
      split
      · exact sinv_sv a rfl
      · exact sinv_sv (sinv_netFail a) rfl
  | sockClose k =>
    simp only [step]; split
    · exact sinv_sv h rfl
    · split
      · exact sinv_sv h rfl
      · split
        · exact sinv_sv h rfl
        · exact sinv_sv h (by rw [sv_sigRedial]; rfl)
  | sockMsg k paired =>
    simp only [step]; split
    · exact h
    · split
      · exact sinv_sv h (by simp only [Sv, curSess, updS_cur]; split <;> simp only [updS_sess, apply_ite Sess.started] <;> (repeat' split) <;> simp [updS])
      · exact sinv_sv h (by simp only [Sv, curSess, updS_cur]; split <;> simp only [updS_sess, apply_ite Sess.started] <;> (repeat' split) <;> simp [updS])
  | resume k =>
    simp only [step]; split
    · split
      · exact sinv_sv h rfl
      · split
        · exact sinv_sv h (by rw [sv_manualEnter]; rfl)
        · exact sinv_sv h rfl
    · split
      · exact sinv_sv h rfl
      · exact sinv_sv h rfl
    · exact sinv_sv h rfl
  | fallbackFire =>
    simp only [step]; split
    · exact h
    · split
      · exact sinv_sv h (by rw [sv_manualEnter]; rfl)
      · exact sinv_sv h rfl
  | redialFire sid =>
    simp only [step]; split
    · exact sinv_sv h (by sv_tac)
    · exact sinv_sv h (by rw [sv_sigConnect]; sv_tac)
  | deadlineFire sid =>
    simp only [step]
    have a : SInv (updS sid (fun x => { x with deadline := false }) s) := sinv_sv h (by sv_tac)
    split
    · exact sinv_netFail a
    · exact a
  | localPair =>
    simp only [step]; split
    · exact h
    · exact sinv_sv h (by rw [sv_dcOnOpen, sv_wireChannel])
  | rtcChannel =>
    simp only [step]; split
    · exact sinv_sv h (sv_wireChannel _ _)
    · exact h
  | dcOpen => exact sinv_sv h (sv_dcOnOpen _)
  | toManual => exact sinv_sv h (sv_manualEnter _)
  | manualReady =>
    simp only [step]; split
    · exact sinv_sv h (by sv_tac)
    · exact h
  | remint => exact sinv_sv h (sv_manualPrepare _)
  | confirmHost ok =>
    simp only [step]; split
    · split
      · exact sinv_sv h (by rw [sv_updS, sv_wireChannel]; intro _; rfl)
      · exact sinv_sv h (sv_wireChannel _ _)
    · exact h
  | rbStart =>
    simp only [step]; split
    · exact h
    · rename_i sid hc
      obtain ⟨a1, a2, a3, a4, a5⟩ := h
      refine ⟨a1, a2, fun _ => rfl, fun _ => ?_, a5⟩
      simp [curSess, hc, updS]
  | rbProgress => exact ⟨h.keyed, h.soloOwn, h.sessOwn, h.rbLive, h.noLoss⟩
  | disconnect => exact sinv_shutdown h false
  | launch g =>
    simp only [step]; split
    · exact sinv_sv (sinv_shutdown h false) rfl
    · exact sinv_sv h rfl
  | loadCommit =>
    simp only [step]; split
    · exact h
    · rename_i g _
      split
      · exact sinv_sv h rfl
      · rename_i hn
        have hb : s.rollbackMode = false := by
          revert hn; cases s.netMode <;> cases s.rollbackMode <;> simp
        have ht : SInv (if s.modal then dismissModal s else s) := by
          split
          · unfold dismissModal; split
            · exact sinv_sv h rfl
            · exact sinv_shutdown h false
          · exact h
        have hrb : (if s.modal then dismissModal s else s).rollbackMode = false := by
          split
          · unfold dismissModal; split
            · exact hb
            · exact shutdown_rb_false h false
          · exact hb
        generalize (if s.modal then dismissModal s else s) = t at ht hrb ⊢
        obtain ⟨a1, a2, a3, a4, a5⟩ := ht
        refine ⟨?_, ?_, ?_, ?_, a5⟩
        · intro x; simp only [put]
          by_cases hx : x = t.game
          · subst hx; simp [a2]
          · simp [hx, a1 x]
        · simp only [put]
          by_cases hx : g = t.game
          · subst hx; simp [a2]
          · simp [hx, a1 g]
        · intro hr; simp [hrb] at hr
        · intro hr; simp [hrb] at hr
  | pagehide =>
    cases hr : s.rollbackMode with
    | false =>
      have ht : SInv (if s.netMode then shutdown false s else s) := by
        split
        · exact sinv_shutdown h false
        · exact h
      have hrb : (if s.netMode then shutdown false s else s).rollbackMode = false := by
        split
        · exact shutdown_rb_false h false
        · exact hr
      simp only [step, hr, Bool.or_false, Bool.false_and]
      generalize (if s.netMode then shutdown false s else s) = t at ht hrb ⊢
      obtain ⟨a1, a2, a3, a4, a5⟩ := ht
      refine ⟨?_, ?_, ?_, ?_, rfl⟩
      · intro x; simp only [put]
        by_cases hx : x = t.game
        · subst hx; simp [a2]
        · simp [hx, a1 x]
      · exact a2
      · intro h'; simp [hrb] at h'
      · intro h'; simp [hrb] at h'
    | true =>
      -- The session's core is promoted and persisted under its own game.
      have hs := h.rbLive hr
      have hg := h.sessOwn hr
      have a1 := h.keyed
      refine ⟨?_, ?_, ?_, ?_, ?_⟩
      · intro x
        simp only [step, hr, Bool.or_true, ite_true, shutdown, hs, Bool.and_self, put]
        by_cases hx : x = s.game
        · subst hx; simp [hg]
        · simp [hx, a1 x]
      · simp [step, hr, shutdown, hs, hg]
      · intro h'; simp [step, hr, shutdown, hs] at h'
      · intro h'; simp [step, hr, shutdown, hs] at h'
      · simp [step, hr, shutdown, hs, put, hg]

theorem sinv_reachable {s : State} (h : Reachable s) : SInv s := by
  induction h with
  | init => exact sinv_init
  | step e hr he ih => exact sinv_step (ninv_reachable hr) ih he

/-- Under every interleaving: every save record holds its own game's battery
    data, and the page never dies with a session's progress unstored. -/
theorem saves_keyed {s : State} (h : Reachable s) (g : Nat) :
    (s.store g).1 = g ∧ s.lostProgress = false :=
  ⟨(sinv_reachable h).keyed g, (sinv_reachable h).noLoss⟩

/-- Ending a session persists its progress under its own game. -/
theorem teardown_persists {s : State} (h : Reachable s) (hr : s.rollbackMode = true) (keep : Bool) :
    (shutdown keep s).store s.sessGame = (s.sessGame, s.rbV) := by
  have hi := sinv_reachable h
  have hs := hi.rbLive hr
  have hg := hi.sessOwn hr
  simp [shutdown, hs, hr, put, hg]

/-- Closing the tab during a session stores the session's progress. -/
theorem pagehide_persists_session {s : State} (h : Reachable s) (hr : s.rollbackMode = true) :
    (step s .pagehide).store s.sessGame = (s.sessGame, s.rbV) := by
  have hi := sinv_reachable h
  have hs := hi.rbLive hr
  have hg := hi.sessOwn hr
  simp [step, shutdown, hs, hr, put, hg]

/-- A launch during a session ends it before anything is loaded, with its
    progress stored under its own game. -/
theorem launch_ends_session {s : State} (h : Reachable s) (hr : s.rollbackMode = true) (g : Nat) :
    (step s (.launch g)).rollbackMode = false ∧
    (step s (.launch g)).store s.sessGame = (s.sessGame, s.rbV) := by
  have hi := sinv_reachable h
  have hs := hi.rbLive hr
  have hg := hi.sessOwn hr
  simp [step, shutdown, hs, hr, put, hg]

/-! ## Counterexamples -/

/-- Cancel while the signaling socket is still dialing: netShutdown's
    `s.ws.close()` fails the CONNECTING socket, whose `error` event then runs
    sigConnect's `onerror`. That handler checks only its own `opened` flag,
    not whether its session is still `net`, so it records the server as down
    (`sigServerUp = false`) and calls `netFail` against whatever `net` is now.
    The next time the Link Cable modal opens, openNetConnect sees
    `sigServerUp === false` and opens straight onto the manual code exchange,
    although the server was fine. -/
def staleDownBad (s : State) : Bool :=
  s.sigUp == some false && s.modal && s.manualView

theorem bug_cancel_while_dialing_forces_manual :
    witnesses [.openModal, .joinClick, .dismiss, .sockErr 0, .openModal] staleDownBad = true := by
  decide

/-- Same handler, other trigger: a second tab of this browser answers on the
    BroadcastChannel before the socket opens. The local channel's `onopen`
    closes the still-CONNECTING socket, its `error` fires, and a working,
    linked session marks the server down. -/
def localDownBad (s : State) : Bool :=
  s.sigUp == some false && (curSess s).rtcConnected && (curSess s).dc == some (.local 0)

theorem bug_local_win_marks_server_down :
    witnesses [.openModal, .joinClick, .localPair, .sockErr 0] localDownBad = true := by
  decide

/-- Manual exchange, host side: `manualConfirmGo` calls
    `wireChannel(session.manualChan)` *before* `await setRemoteDescription`.
    If that rejects (a code that decodes but does not apply), the user can fix
    the paste and Confirm again (the input stays editable, the button enabled),
    and the second `wireChannel` finds `net.dc` already set -- to the very same
    channel -- and closes it as the race's "loser". The pairing then connects
    ICE with no DataChannel and dies at the 20 s deadline ("Couldn't connect
    with those codes"). -/
def winnerClosedBad (s : State) : Bool :=
  match (curSess s).dc with
  | some c => s.raceClosed c
  | none => false

theorem bug_manual_retry_closes_own_channel :
    witnesses [.openModal, .toManual, .manualReady, .confirmHost false, .confirmHost true]
      winnerClosedBad = true := by decide

/-- Re-minting the code after that failed Confirm (the 45 s refresh or a return
    to the foreground) does not clear `net.dc` either: the fresh channel is
    then closed as a loser too, so the session can never pair until the modal
    is closed and reopened. -/
theorem bug_manual_remint_still_wedged :
    witnesses [.openModal, .toManual, .manualReady, .confirmHost false, .remint, .manualReady,
               .confirmHost true]
      (fun s => match (curSess s).pc with
        | some p => s.raceClosed (.manual p)
        | none => false) = true := by decide

/-! ### The rollback save traces found at dd7ba741f, now safe

Each `regress_*` runs the old counterexample's events (every one enabled) and
checks the state it ends in. -/

def wrongKeyBad (s : State) : Bool := (s.store 1).1 != 1

/-- At dd7ba741f a rollback session set `netMode = false` (rbStartIfReady
    1299), so `loadRom`'s `if (netMode) await netShutdown()` did not end it:
    tapping another game loaded it into the solo core while the session ran
    on, and when the session ended, rbTeardown persisted the session's core
    under `currentOriginalName` -- by then the other game -- so game 1's save
    was overwritten with game 0's battery data. The launch now ends the
    session first, persisting it under game 0 (so the old trace's final
    Disconnect is no longer there to press). -/
theorem regress_launch_during_rollback_corrupts_save :
    witnesses [.openModal, .joinClick, .localPair, .rbStart, .rbProgress,
               .launch 1, .loadCommit]
      (fun s => !wrongKeyBad s && s.store 0 == (0, 1) && s.game == 1 && !s.rollbackMode)
      = true := by decide

/-- ... and the game on screen and `currentOriginalName` no longer split. -/
theorem regress_launch_during_rollback_splits_identity :
    witnesses [.openModal, .joinClick, .localPair, .rbStart, .launch 1, .loadCommit]
      (fun s => !(s.rollbackMode && s.game != s.sessGame)) = true := by decide

/-- A session that starts while a load is between its first segment and its
    commit: the load names nothing (loadRom's return at 7897), and ending the
    session later persists it under its own game. -/
theorem regress_session_starts_mid_load :
    witnesses [.openModal, .joinClick, .localPair, .launch 1, .rbStart, .rbProgress,
               .loadCommit, .disconnect]
      (fun s => !wrongKeyBad s && s.game == 0 && s.store 0 == (0, 1)) = true := by decide

/-- At dd7ba741f `pagehide` tore down only `if (netMode)`: the session's core
    (whose battery held e.g. a finished trade) was never promoted or
    persisted, and closing the tab lost the session's progress. -/
theorem regress_pagehide_in_rollback_loses_progress :
    witnesses [.openModal, .joinClick, .localPair, .rbStart, .rbProgress, .pagehide]
      (fun s => !s.lostProgress && s.store 0 == (0, 1)) = true := by decide

/-- A game loaded under the Link Cable modal while a session is still pairing
    (RunPause's `bug_load_under_link_modal_runs`): the load dismisses the
    modal, shutting the pairing session down, in the segment that names it. -/
theorem load_dismisses_pairing_modal :
    witnesses [.openModal, .joinClick, .launch 1, .loadCommit]
      (fun s => !s.modal && s.cur.isNone && s.game == 1) = true := by decide

end WebState.Netplay
