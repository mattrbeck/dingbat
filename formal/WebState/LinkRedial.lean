-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/netplay.js: rbDropped rbWatchDisconnected rbBeginResume rsDetach rsRestart rsStop rsDial rsStartRtc rsAdopt rsResumeIn
-- @models web/signaling/server.nim: onText teardown notifyClosed normalizeId handleClient
-- @models web/signaling/server.js: attach leave closeRoom relayFrom normalizeId

/-
# Redialing a dropped link on the retry code (web/netplay.js `rs*`)

The control plane of the link resume protocol: what each player's page does
between "the connection is gone" and "the friend's RESUME arrived", and the
signaling server between them. The data plane (inputs, the RESUME's
contents, pause, BYE, what each screen says) is `LinkResume`'s; here the
RESUME is only a message that, arriving on a channel this side has adopted,
ends the redial (`rsStop`).

A session in progress holds one connection (`net.pc` / `net.dc`, here
`cur`). When it fails (`dc.onclose`, the pc's `failed`/`closed`, or the
10 s `disconnected` watchdog: `rbDropped`), each side begins redialing
(`rbBeginResume`): it detaches the dead connection (`rsDetach`), arms the
180 s give-up and dials the server (`rsDial`), whose rendezvous carries the
retry code both sides learnt at the start. The first to arrive waits; the
second pairs; host offers, guest answers (`rsStartRtc`); each side's new
DataChannel opens (`rsAdopt`: it becomes the session's connection and sends
RESUME); the friend's RESUME ends the redial (`rsResumeIn` → `rsStop`). Any
attempt that goes wrong restarts (`rsRestart`): detach, back off, dial again.

`Cfg.review` selects the code: `false` = netplay.js at fd7b0432 (the
prototype), `true` = d22e0527 (after the adversarial review). The
differences, by function:

* `rbBeginResume` on a side already redialing (its adopted channel closed
  before the friend's RESUME): returned (prototype); `rsRestart` (reviewed).
* `rsAdopt`: closed the server socket at once (prototype); keeps it until
  the friend's RESUME (reviewed), and arms the 10 s answer timer.
* The server socket's `onclose` and `peer-closed`: restarted unless the
  channel was open (prototype); also not once the friend's description is in
  (`rsSdpIn`, reviewed): the friend most likely opened and left.
* `waiting` arms the 25 s re-rendezvous (`rsRewait`, reviewed): a socket can
  die without either end hearing.
* The friend's RESUME arriving before our channel's `open` is parked and
  replayed at the open (`rsEarly`, reviewed); the prototype dropped it.

## What is modelled

* Clients (`Client`): the phase (`live` / `recon` = `rb.reconnecting` /
  `ended` = `netPeerGone`), `net.pc` (`cur`), `rb.rsWs`, `rb.rsPc`,
  `rb.rsDcOpen`, `rb.rsSdpIn`, the timers (`giveUpTimer`, `rsRetry`,
  `rsPairTimer`, `rsAnswerTimer`, `rsRewait`, each holding what its
  callback compares against), and iOS suspension (`susp`: no JavaScript
  runs, timers included, and the page's network stack is frozen).
* Sockets and the server: as `LinkPairing` (the fixed server, which drops a
  seat held by the same page id): FIFO frames each way, `dead` (gone under
  both ends, the server may not have heard), `srvClosed` (the server closed
  it). The room is the retry code's.
* Peer connections (`PC`): owner, role, the description it holds, closed,
  opened (its DataChannel opened), `broken` (the path under it failed),
  `rs` (its owner's RESUME on its channel: not yet sent, in flight,
  delivered) and `early` (the friend's RESUME parked before our open).
  The session's first connection is pcs 0 (A, host) and 1 (B, guest), open.

## Abstractions

* The rollback session, the retry code's exchange and `rbCanResume` are
  given: both sides hold the code, and every drop redials. The data plane
  (and `rbBeginResume`'s "the friend has surely given up" clock check) is
  `LinkResume`'s.
* Timers fire nondeterministically while armed (a backoff is a timer); the
  give-up and `rsRestart`'s wall-clock check are one event, `giveUp`.
* `failed`, `closed`, `dc.onclose` and the `disconnected` watchdog on the
  session's connection are one event, `dcClose`, enabled once the path is
  broken, the friend's pc closed, or the friend suspended (its ICE stops
  answering). ICE `failed` on a pairing not yet open is `pcFail`. Either
  may also never come: a channel that just sits there is modelled.
* ICE candidates ride the socket after the description and are not
  modelled (see `LinkPairing`). An async handler between awaits is one
  event.
* A RESUME's arrival (`arrive`) needs only that the friend sent it on the
  pc paired with ours and ours is not closed; a break or the friend closing
  afterwards does not stop it (more behaviours, so the invariant is
  stronger for it).
* `rsAdopt`'s guards (a second `open`, a pc no longer ours) never fail
  here: `dcOpen` is only enabled on our current, unopened pairing.

## Results

* `bug_dead_end` (prototype): a channel adopted, then broken before the
  friend's RESUME; the side's `onclose` reaches `rbBeginResume`, which
  returns: it is redialing with nothing armed but the give-up, and no
  socket, pairing or live channel. 3 minutes of "Reconnecting…" and then
  "Couldn't reconnect" with the friend there all along.
* `bug_linked_close` (prototype): no fault at all. A's channel opens first,
  A closes its server socket, the server tells B `peer-closed`, B restarts
  and closes its pc, A's channel closes: A is in the same dead end.
* `bug_early_resume_lost` (prototype): the friend's RESUME reaches a pc
  whose `open` has not run; it is dropped, and the side waits on a live
  channel for a RESUME that will never come (no answer timer then).
  Reachable on iOS, whose WebRTC callbacks are posted to the main queue;
  on the web the `open` event is queued first.
* `regress_*`: each trace on the reviewed code, continued with no user
  action, ends with both sides resumed on one new connection.
* `no_dead_end` (reviewed, every reachable state): a redialing side always
  has an armed timer (retry, pairing, answer, re-rendezvous) or a server
  socket that is not closed. So no state waits on the give-up alone
  (`no_dead_end'`: never the prototype's `deadEnd`). The proof is the
  invariant `Inv` (`inv_init`, `inv_step`): each timer's callback finds
  the state it was armed for, an adopted channel has its answer timer, a
  pairing not yet open its deadline, a retry is armed only with no socket.
* Witnesses (reviewed): `witness_happy`; `regress_early_resume` (the
  friend's RESUME before our open); `witness_unseen_socket_death` (a
  waiting socket dies unseen: re-rendezvous, the server drops the ghost
  seat); `witness_answer_timeout` (one channel opens 10 s before the
  other's: both redial); `witness_frozen_friend` (the friend's phone frozen
  across the drop); `regress_linked_close` (the friend leaving the server
  once resumed).

`no_dead_end` is not liveness: two sides can keep restarting each other
(a pairing deadline firing on a side whose friend just opened) until the
give-up. The witnesses show the schedules where nothing like that happens.

## iOS (ios/Dingbat/Sources/NetLink.swift)

The port follows the same machine, with two differences this model would
see. Retry, pairing deadline and answer timer share one slot (`rsTimer`);
they are never armed together here (a retry means no socket, a deadline a
pairing, an answer timer an adopted channel), so nothing changes. And
coming back to the foreground while redialing restarts at once
(`redialNowIfWaiting`) unless the channel is open, including mid-pairing
with the friend's description in hand: no dead end (it arms a retry), but
it can tear down a pairing that was about to open.
-/
namespace WebState.LinkRedial

set_option linter.unusedSimpArgs false
set_option linter.unusedVariables false

inductive Cl where
  | a | b
  deriving DecidableEq, Repr

def Cl.other : Cl → Cl
  | .a => .b
  | .b => .a

inductive Role where
  | host | guest
  deriving DecidableEq, Repr

/-- Client → server frames: `rendezvous` (retry code + page id), a pc's
    description, the WebSocket close frame. -/
inductive Up where
  | rz | sdp (p : Nat) | bye
  deriving DecidableEq, Repr

/-- Server → client frames. -/
inductive Down where
  | waiting | paired (r : Role) | sdp (p : Nat) | peerClosed | inUse
  deriving DecidableEq, Repr

inductive CSt where
  | connecting | opn | closed
  deriving DecidableEq, Repr

structure Sock where
  owner     : Cl := .a
  cst       : CSt := .closed      -- the client's readyState
  srv       : Bool := false       -- the server holds it open
  up        : List Up := []       -- client → server, in flight
  down      : List Down := []     -- server → client, in flight
  dead      : Bool := false       -- the connection is gone under both ends
  srvClosed : Bool := false       -- the server closed it (onclose after `down` drains)
  deriving DecidableEq, Repr

/-- A RESUME on a pc's channel. -/
inductive Rs where
  | none | sent | got
  deriving DecidableEq, Repr

structure PC where
  owner  : Cl := .a
  role   : Role := .host
  remote : Option Nat := none     -- the pc whose description it holds
  closed : Bool := true           -- unallocated pcs count as closed
  opened : Bool := false          -- its DataChannel opened
  broken : Bool := false          -- the path under it failed
  rs     : Rs := .none            -- its owner's RESUME, sent on this channel
  early  : Bool := false          -- the friend's RESUME, parked before our open (rsEarly)
  deriving DecidableEq, Repr

inductive Ph where
  | live | recon | ended
  deriving DecidableEq, Repr

structure Client where
  ph      : Ph := .live
  susp    : Bool := false
  cur     : Option Nat := none    -- net.pc (and its net.dc)
  ws      : Option Nat := none    -- rb.rsWs
  rsPc    : Option Nat := none    -- rb.rsPc
  dcOpen  : Bool := false         -- rb.rsDcOpen
  sdpIn   : Bool := false         -- rb.rsSdpIn (reviewed)
  giveUpT : Bool := false         -- rb.giveUpTimer
  retryT  : Bool := false         -- rb.rsRetry
  pairT   : Option Nat := none    -- rb.rsPairTimer, for this pc
  answerT : Option Nat := none    -- rb.rsAnswerTimer, for this pc's channel (reviewed)
  rewaitT : Option Nat := none    -- rb.rsRewait, for this socket (reviewed)
  resumes : Nat := 0              -- ghost: redials that ended in the friend's RESUME
  deriving DecidableEq, Repr

structure Room where
  host  : Nat
  guest : Option Nat
  deriving DecidableEq, Repr

structure Cfg where
  review : Bool
  deriving DecidableEq, Repr

/-- netplay.js at fd7b0432, the prototype. -/
def Cfg.pre : Cfg := ⟨false⟩
/-- netplay.js at d22e0527, after the adversarial review. -/
def Cfg.rev : Cfg := ⟨true⟩

structure State where
  cl       : Cl → Client
  socks    : Nat → Sock
  nextSock : Nat
  pcs      : Nat → PC
  nextPc   : Nat
  room     : Option Room

/-- Both players live on the session's first connection: pc 0 (A, host)
    and pc 1 (B, guest), each holding the other's description, open. -/
def init : State where
  cl := fun c => match c with
    | .a => { cur := some 0 }
    | .b => { cur := some 1 }
  socks := fun _ => {}
  nextSock := 0
  pcs := fun p =>
    if p = 0 then { owner := .a, role := .host, remote := some 1, closed := false, opened := true }
    else if p = 1 then { owner := .b, role := .guest, remote := some 0, closed := false, opened := true }
    else {}
  nextPc := 2
  room := none

def updC (c : Cl) (f : Client → Client) (s : State) : State :=
  { s with cl := fun d => if d = c then f (s.cl d) else s.cl d }

def updK (k : Nat) (f : Sock → Sock) (s : State) : State :=
  { s with socks := fun j => if j = k then f (s.socks j) else s.socks j }

def updP (p : Nat) (f : PC → PC) (s : State) : State :=
  { s with pcs := fun j => if j = p then f (s.pcs j) else s.pcs j }

/-! ## The server (server.nim `onText` / `teardown`; server.js `attach` / `leave`) -/

/-- The server sends `m` on `k`: lost if it no longer holds `k`, the
    connection is gone, or the client has closed its end. -/
def push (k : Nat) (m : Down) (s : State) : State :=
  let x := s.socks k
  if !x.srv || x.dead || x.cst == .closed then s
  else updK k (fun y => { y with down := y.down ++ [m] }) s

/-- The server closes `k` (after `peer-closed`). -/
def srvClose (k : Nat) (s : State) : State :=
  updK k (fun x => { x with srv := false, srvClosed := true }) s

/-- The server lets go of `k`: a room `k` sits in dies, and the other seat
    is told `peer-closed` and closed. -/
def teardown (k : Nat) (s : State) : State :=
  let s := updK k (fun x => { x with srv := false }) s
  match s.room with
  | some r =>
    if r.host = k then
      match r.guest with
      | some g => srvClose g (push g .peerClosed { s with room := none })
      | none => { s with room := none }
    else if r.guest = some k then
      srvClose r.host (push r.host .peerClosed { s with room := none })
    else s
  | none => s

/-- Second arrival: host = first arrival = offerer. -/
def pair (h k : Nat) (s : State) : State :=
  push k (.paired .guest) (push h (.paired .host) { s with room := some ⟨h, some k⟩ })

/-- Arrival `k` carries the page id of seat `j`: `j` is that page's stale
    socket. It is dropped without a word; the other seat `i`, if any, is
    told `peer-closed`; `k` waits. -/
def evict (j : Nat) (i : Option Nat) (k : Nat) (s : State) : State :=
  let s := updK j (fun x => { x with srv := false }) s
  let s := match i with
    | some i => srvClose i (push i .peerClosed s)
    | none => s
  push k .waiting { s with room := some ⟨k, none⟩ }

/-- The `rendezvous` branch. -/
def srvRz (k : Nat) (s : State) : State :=
  let o := (s.socks k).owner
  match s.room with
  | none => push k .waiting { s with room := some ⟨k, none⟩ }
  | some ⟨h, none⟩ =>
    if (s.socks h).owner == o then evict h none k s else pair h k s
  | some ⟨h, some g⟩ =>
    if (s.socks h).owner == o then evict h (some g) k s
    else if (s.socks g).owner == o then evict g (some h) k s
    else srvClose k (push k .inUse s)

/-- Post-pair relay, only between the room's two seats. -/
def relay (k p : Nat) (s : State) : State :=
  match s.room with
  | some ⟨h, some g⟩ =>
    if k = h then push g (.sdp p) s else if k = g then push h (.sdp p) s else s
  | _ => s

def srvRecv (k : Nat) (s : State) : State :=
  match (s.socks k).up with
  | [] => s
  | m :: rest =>
    let s := updK k (fun x => { x with up := rest }) s
    match m with
    | .rz => srvRz k s
    | .sdp p => relay k p s
    | .bye => teardown k s

/-! ## The client (web/netplay.js) -/

/-- `ws.send`: dropped unless the server holds the socket. -/
def send (k : Nat) (m : Up) (s : State) : State :=
  updK k (fun x => if x.srv && !x.dead then { x with up := x.up ++ [m] } else x) s

/-- `ws.close()` with the handlers cleared: the close frame follows whatever
    was sent; nothing more is delivered. -/
def closeOwn (k : Nat) (s : State) : State :=
  updK k (fun x => if x.cst = .closed then x else
    { x with cst := .closed, down := [],
             up := if x.srv && !x.dead then x.up ++ [.bye] else x.up }) s

/-- Close `rb.rsWs`, if any. -/
def closeWs (c : Cl) (s : State) : State :=
  match (s.cl c).ws with
  | some k => closeOwn k s
  | none => s

def closePc : Option Nat → State → State
  | some p, s => updP p (fun y => { y with closed := true }) s
  | none, s => s

/-- `rsDetach`: let go of the server socket, the pairing in flight, the
    adopted (or dead) connection, and their timers. -/
def Client.detached (x : Client) : Client :=
  { x with ws := none, rsPc := none, cur := none, dcOpen := false, sdpIn := false,
           retryT := false, pairT := none, answerT := none, rewaitT := none }

def detach (c : Cl) (s : State) : State :=
  let s := closeWs c s
  let x := s.cl c
  let s := closePc x.cur (closePc x.rsPc s)
  updC c Client.detached s

/-- `rsRestart`: this attempt is over; dial again after the backoff. -/
def restart (c : Cl) (s : State) : State :=
  if (s.cl c).ph = .recon then updC c (fun x => { x with retryT := true }) (detach c s) else s

/-- `rsDial`: a fresh CONNECTING socket becomes `rb.rsWs`. -/
def dial (c : Cl) (s : State) : State :=
  let k := s.nextSock
  let s := updK k (fun _ => { owner := c, cst := .connecting }) { s with nextSock := k + 1 }
  updC c (fun x => { x with ws := some k }) s

/-- `rbDropped` → `rbBeginResume`. -/
def begin (cfg : Cfg) (c : Cl) (s : State) : State :=
  match (s.cl c).ph with
  | .recon => if cfg.review then restart c s else s
  | .live => dial c (detach c (updC c (fun x => { x with ph := .recon, giveUpT := true }) s))
  | .ended => s

/-- `rsStop`: no more redialing; an adopted channel stays the session's. -/
def Client.stopped (x : Client) : Client :=
  { x with ph := (if x.ph = .recon then .live else x.ph), giveUpT := false, retryT := false,
           pairT := none, answerT := none, rewaitT := none, ws := none, rsPc := none }

def rsStop (c : Cl) (s : State) : State :=
  let s := closeWs c s
  let x := s.cl c
  let s := if x.rsPc ≠ x.cur then closePc x.rsPc s else s
  updC c Client.stopped s

/-- `rsResumeIn` with the friend's RESUME in hand: resumed. -/
def resumed (c : Cl) (s : State) : State :=
  updC c (fun x => { x with resumes := x.resumes + 1 }) (rsStop c s)

/-- `netPeerGone("Couldn't reconnect")`: `rsStop`, then the connection goes. -/
def endS (c : Cl) (s : State) : State :=
  let s := rsStop c s
  let s := closePc (s.cl c).cur s
  updC c (fun x => { x with ph := .ended, cur := none }) s

/-- `rsStartRtc`: a new pc; the host offers at once; the pairing deadline. -/
def startRtc (c : Cl) (k : Nat) (r : Role) (s : State) : State :=
  let p := s.nextPc
  let s := updP p (fun _ => { owner := c, role := r, closed := false }) { s with nextPc := p + 1 }
  let s := updC c (fun x => { x with rsPc := some p, dcOpen := false, sdpIn := false,
                                     pairT := some p, rewaitT := none }) s
  if r = .host then send k (.sdp p) s else s

/-- `rsDial`'s `ws.onmessage`, one message on c's socket `k`. -/
def onMsg (cfg : Cfg) (c : Cl) (k : Nat) (m : Down) (s : State) : State :=
  let x := s.cl c
  match m with
  | .waiting => if cfg.review then updC c (fun x => { x with rewaitT := some k }) s else s
  | .paired r => startRtc c k r s
  | .sdp q =>
    match x.rsPc with
    | some p =>
      let s := updC c (fun x => { x with sdpIn := true }) s
      let s := updP p (fun y => { y with remote := some q }) s
      if (s.pcs p).role = .guest then send k (.sdp p) s else s
    | none => s
  | .peerClosed =>
    if !x.dcOpen && !(cfg.review && x.sdpIn) then restart c s else s
  | .inUse => restart c s

/-- `rsAdopt`: the new channel is the session's; it carries our RESUME. -/
def adopt (cfg : Cfg) (c : Cl) (p : Nat) (s : State) : State :=
  let s := updP p (fun y => { y with opened := true, rs := .sent }) s
  let s := if cfg.review then s else closeWs c s
  let s := updC c (fun x => { x with dcOpen := true, pairT := none, cur := some p,
                                     answerT := (if cfg.review then some p else none),
                                     ws := (if cfg.review then x.ws else none) }) s
  -- rsEarly replayed: the friend's RESUME came first.
  if cfg.review && (s.pcs p).early then resumed c s else s

/-- The pc the friend's RESUME is read on: the adopted channel, or the
    pairing not yet open. -/
def target (x : Client) : Option Nat := if x.dcOpen then x.cur else x.rsPc

/-- The friend's RESUME reaches c's pc `p`. -/
def arrive (cfg : Cfg) (c : Cl) (s : State) : State :=
  let x := s.cl c
  match target x with
  | some p =>
    match (s.pcs p).remote with
    | some q =>
      let s := updP q (fun y => { y with rs := .got }) s
      if x.dcOpen && x.ph == .recon then resumed c s
      else if cfg.review && !x.dcOpen then updP p (fun y => { y with early := true }) s
      else s
    | none => s
  | none => s

/-- The path under c's pc `p` is failing: broken, the friend's pc closed,
    or the friend frozen. -/
def failing (s : State) (c : Cl) (p : Nat) : Bool :=
  match (s.pcs p).remote with
  | some q => (s.pcs q).closed || (s.pcs p).broken || (s.pcs q).broken || (s.cl c.other).susp
  | none => true

/-- c's new DataChannel can open. -/
def canOpen (s : State) (c : Cl) : Bool :=
  let x := s.cl c
  !x.susp && !(s.cl c.other).susp && x.ph == .recon && !x.dcOpen &&
  match x.rsPc with
  | some p => match (s.pcs p).remote with
    | some q => !(s.pcs p).closed && !(s.pcs q).closed && (s.pcs q).remote == some p &&
                !(s.pcs p).broken && !(s.pcs q).broken
    | none => false
  | none => false

inductive Event where
  | suspend (c : Cl)      -- iOS backgrounds / locks the page
  | wake (c : Cl)
  | cut (p : Nat)         -- fault: the path under pc p fails
  | open_ (k : Nat)       -- the server accepts; onopen sends the rendezvous
  | die (k : Nat)         -- fault: the socket's connection drops (either end may not hear)
  | cclose (k : Nat)      -- the client's onclose
  | srvRecv (k : Nat)     -- the server reads k's next frame
  | srvNotice (k : Nat)   -- the server learns k is gone (FIN, or the reaper)
  | deliver (k : Nat)     -- the client reads k's next server message
  | retry (c : Cl)        -- rsRetry: rsDial
  | pairT (c : Cl)        -- rsPairTimer (20 s)
  | answerT (c : Cl)      -- rsAnswerTimer (10 s)
  | rewaitT (c : Cl)      -- rsRewait (25 s)
  | giveUp (c : Cl)       -- giveUpTimer (180 s), or rsRestart's clock check
  | dcOpen (c : Cl)       -- the new channel's onopen: rsAdopt
  | dcClose (c : Cl)      -- the session's connection fails: rbDropped
  | pcFail (c : Cl)       -- ICE failed on the pairing not yet open
  | arrive (c : Cl)       -- the friend's RESUME reaches c
  deriving DecidableEq, Repr

def en (s : State) : Event → Bool
  | .suspend c => !(s.cl c).susp
  | .wake c => (s.cl c).susp
  | .cut p => !(s.pcs p).broken
  | .open_ k =>
    let x := s.socks k
    x.cst == .connecting && !x.dead && !(s.cl x.owner).susp && (s.cl x.owner).ws == some k
  | .die k => !(s.socks k).dead && (s.socks k).cst != .closed
  | .cclose k =>
    let x := s.socks k
    x.cst != .closed && !(s.cl x.owner).susp && (x.dead || (x.srvClosed && x.down.isEmpty))
  | .srvRecv k => (s.socks k).srv && !(s.socks k).up.isEmpty
  | .srvNotice k => (s.socks k).srv && (s.socks k).dead
  | .deliver k =>
    let x := s.socks k
    x.cst == .opn && !x.dead && !x.down.isEmpty && !(s.cl x.owner).susp &&
      (s.cl x.owner).ws == some k
  | .retry c => !(s.cl c).susp && (s.cl c).retryT
  | .pairT c => !(s.cl c).susp && (s.cl c).pairT.isSome
  | .answerT c => !(s.cl c).susp && (s.cl c).answerT.isSome
  | .rewaitT c => !(s.cl c).susp && (s.cl c).rewaitT.isSome
  | .giveUp c => !(s.cl c).susp && (s.cl c).giveUpT
  | .dcOpen c => canOpen s c
  | .dcClose c =>
    let x := s.cl c
    !x.susp && x.ph != .ended &&
      match x.cur with
      | some p => (s.pcs p).opened && !(s.pcs p).closed && failing s c p
      | none => false
  | .pcFail c =>
    let x := s.cl c
    !x.susp && x.ph == .recon && !x.dcOpen &&
      match x.rsPc with
      | some p => !(s.pcs p).closed && (s.pcs p).remote.isSome && failing s c p
      | none => false
  | .arrive c =>
    let x := s.cl c
    !x.susp && x.ph != .ended &&
      match target x with
      | some p => !(s.pcs p).closed &&
        match (s.pcs p).remote with
        | some q => (s.pcs q).rs == .sent && (s.pcs q).remote == some p
        | none => false
      | none => false

def step (cfg : Cfg) (s : State) : Event → State
  | .suspend c => updC c (fun x => { x with susp := true }) s
  | .wake c => updC c (fun x => { x with susp := false }) s
  | .cut p => updP p (fun y => { y with broken := true }) s
  | .open_ k => updK k (fun x => { x with cst := .opn, srv := true, up := [.rz] }) s
  | .die k => updK k (fun x => { x with dead := true, down := [], up := [] }) s
  | .cclose k =>
    let x := s.socks k
    let c := x.owner
    let s := updK k (fun y => { y with cst := .closed }) s
    if (s.cl c).ws != some k then s
    -- Reviewed: a pairing under way finishes on its own (or its deadline redials).
    else if cfg.review && ((s.cl c).dcOpen || (s.cl c).sdpIn) then
      updC c (fun y => { y with ws := none }) s
    else restart c s
  | .srvRecv k => srvRecv k s
  | .srvNotice k => teardown k (updK k (fun x => { x with up := [] }) s)
  | .deliver k =>
    let x := s.socks k
    match x.down with
    | [] => s
    | m :: rest => onMsg cfg x.owner k m (updK k (fun y => { y with down := rest }) s)
  | .retry c =>
    let s := updC c (fun x => { x with retryT := false }) s
    if (s.cl c).ph = .recon then dial c s else s
  | .pairT c =>
    let x := s.cl c
    let s := updC c (fun x => { x with pairT := none }) s
    if x.pairT = x.rsPc && !x.dcOpen then restart c s else s
  | .answerT c =>
    let x := s.cl c
    let s := updC c (fun x => { x with answerT := none }) s
    if x.answerT = x.cur then restart c s else s
  | .rewaitT c =>
    let x := s.cl c
    let s := updC c (fun x => { x with rewaitT := none }) s
    if x.rewaitT = x.ws && x.rsPc = none then restart c s else s
  | .giveUp c =>
    if (s.cl c).ph = .recon then endS c s else updC c (fun x => { x with giveUpT := false }) s
  | .dcOpen c =>
    match (s.cl c).rsPc with
    | some p => adopt cfg c p s
    | none => s
  | .dcClose c => begin cfg c s
  | .pcFail c => restart c s
  | .arrive c => arrive cfg c s

inductive Reachable (cfg : Cfg) : State → Prop
  | init : Reachable cfg init
  | step {s : State} (e : Event) : Reachable cfg s → en s e = true → Reachable cfg (step cfg s e)

def run (cfg : Cfg) (s : State) : List Event → Option State
  | [] => some s
  | e :: es => if en s e then run cfg (step cfg s e) es else none

theorem run_reachable {cfg : Cfg} {s : State} (h : Reachable cfg s) :
    ∀ {es : List Event} {t : State}, run cfg s es = some t → Reachable cfg t := by
  intro es
  induction es generalizing s with
  | nil => intro t ht; simp [run] at ht; subst ht; exact h
  | cons e es ih =>
    intro t ht
    simp only [run] at ht
    split at ht
    · exact ih (Reachable.step e h (by assumption)) ht
    · cases ht

/-- The trace runs (every event enabled) from `init` and ends in a state
    satisfying `p`. -/
def witnesses (cfg : Cfg) (es : List Event) (p : State → Bool) : Bool :=
  match run cfg init es with
  | some t => p t
  | none => false

theorem witness_sound {cfg : Cfg} {es : List Event} {p : State → Bool}
    (h : witnesses cfg es p = true) : ∃ s, Reachable cfg s ∧ p s = true := by
  unfold witnesses at h
  split at h
  · rename_i t ht
    exact ⟨t, run_reachable Reachable.init ht, h⟩
  · cases h

/-! ## Ways forward -/

/-- Something other than the give-up will move a redialing side: an armed
    timer, or a server socket that is not closed (it will deliver, or its
    `onclose` will run). This is what the reviewed code keeps. -/
def forward (s : State) (c : Cl) : Bool :=
  let x := s.cl c
  x.retryT || x.pairT.isSome || x.answerT.isSome || x.rewaitT.isSome ||
  match x.ws with
  | some k => (s.socks k).cst != .closed
  | none => false

/-- A weaker notion, for the counterexamples: `forward`, or a pairing not
    yet open whose pcs are both alive (it may still open), or an adopted
    channel whose path is alive (the friend's RESUME may still come). A
    redialing side without even this has only the give-up. -/
def wayOut (s : State) (c : Cl) : Bool :=
  let x := s.cl c
  forward s c ||
  (match x.rsPc with
   | some p => !x.dcOpen && !(s.pcs p).closed && !(s.pcs p).broken
   | none => false) ||
  (match x.cur with
   | some p => x.dcOpen && !(s.pcs p).closed && !failing s c p &&
     match (s.pcs p).remote with
     | some q => (s.pcs q).rs != .got
     | none => false
   | none => false)

/-- Both sides resumed on one new connection, each with the other's pc. -/
def bothResumed (s : State) : Bool :=
  let a := s.cl .a
  let b := s.cl .b
  a.ph == .live && b.ph == .live && a.resumes ≥ 1 && b.resumes ≥ 1 &&
  match a.cur, b.cur with
  | some p, some q => (s.pcs p).remote == some q && (s.pcs q).remote == some p &&
                      !(s.pcs p).closed && !(s.pcs q).closed
  | _, _ => false

def deadEnd (s : State) (c : Cl) : Bool := (s.cl c).ph == .recon && !wayOut s c

/-! ## The traces

Sockets and pcs are numbered in the order they are made; pcs 0 and 1 are
the session's first connection. -/

/-- The first connection's path fails; A notices first (socket 0), then B
    (socket 1). A waits; B pairs; A (pc 2) offers, B (pc 3) answers. -/
def handshake : List Event :=
  [.cut 0, .dcClose .a, .dcClose .b,
   .open_ 0, .srvRecv 0, .deliver 0,              -- A: "waiting"
   .open_ 1, .srvRecv 1,                          -- B pairs
   .deliver 0, .deliver 1,                        -- "paired": A offers
   .srvRecv 0, .deliver 1,                        -- B takes the offer, answers
   .srvRecv 1, .deliver 0]                        -- A takes the answer

/-- No fault in the redial: both open, both RESUMEs arrive. -/
theorem witness_happy : witnesses .rev (handshake ++
    [.dcOpen .a, .dcOpen .b, .arrive .a, .arrive .b]) bothResumed = true := by
  decide

/-- A's new channel opens; its path breaks before B's RESUME; A's `onclose`
    reaches `rbBeginResume`, which returns: redialing, and nothing left. -/
theorem bug_dead_end :
    witnesses .pre (handshake ++ [.dcOpen .a, .cut 2, .dcClose .a])
      (fun s => deadEnd s .a) = true := by
  decide

/-- Both redial again after the break: B's pairing fails (ICE), the server
    sockets close, both rendezvous on the code once more. Sockets `wa` and
    `wb`, A arriving first. -/
def redial2 (wa wb : Nat) : List Event :=
  [.retry .a, .retry .b, .open_ wa, .srvRecv wa, .deliver wa, .open_ wb, .srvRecv wb,
   .deliver wa, .deliver wb, .srvRecv wa, .deliver wb, .srvRecv wb, .deliver wa,
   .dcOpen .a, .dcOpen .b, .arrive .a, .arrive .b]

/-- Reviewed: A's `onclose` restarts; B's pairing fails; both redial and
    resume with no one pressing anything. -/
theorem regress_dead_end :
    witnesses .rev (handshake ++ [.dcOpen .a, .cut 2, .dcClose .a])
      (fun s => (s.cl .a).ph == .recon && forward s .a) = true ∧
    witnesses .rev (handshake ++ [.dcOpen .a, .cut 2, .dcClose .a,
        .pcFail .b, .srvRecv 0] ++ redial2 2 3) bothResumed = true := by
  decide

/-- No fault: A's channel opens first and A closes its server socket; the
    server tells B `peer-closed`; B, whose channel has not opened, restarts
    and closes its pc; A's channel closes and A is at a dead end. -/
theorem bug_linked_close :
    witnesses .pre (handshake ++ [.dcOpen .a, .srvRecv 0, .deliver 1, .dcClose .a])
      (fun s => deadEnd s .a && (s.cl .b).retryT) = true := by
  decide

/-- Reviewed: A keeps its socket until B's RESUME; B's `peer-closed`, once
    its own channel is open, is ignored. -/
theorem regress_linked_close :
    witnesses .rev (handshake ++ [.dcOpen .a, .dcOpen .b, .arrive .a, .srvRecv 0, .deliver 1,
        .arrive .b]) bothResumed = true := by
  decide

/-- A's RESUME reaches B's pc before B's `open` ran: dropped. B opens and
    waits on a live channel for a RESUME that already came. -/
theorem bug_early_resume_lost :
    witnesses .pre (handshake ++ [.dcOpen .a, .arrive .b, .dcOpen .b])
      (fun s => deadEnd s .b) = true := by
  decide

/-- Reviewed: parked, and replayed at the open. -/
theorem regress_early_resume :
    witnesses .rev (handshake ++ [.dcOpen .a, .arrive .b, .dcOpen .b, .arrive .a])
      bothResumed = true := by
  decide

/-- A waits on socket 0, which dies with neither end hearing. 25 s on A
    rendezvouses again (socket 1, same page id): the server drops the ghost
    seat and A waits on socket 1. B notices the drop late, dials (socket 2)
    and pairs with A. -/
theorem witness_unseen_socket_death :
    witnesses .rev
      [.cut 0, .dcClose .a, .open_ 0, .srvRecv 0, .deliver 0, .die 0,
       .rewaitT .a, .retry .a, .open_ 1, .srvRecv 1, .deliver 1,
       .dcClose .b, .open_ 2, .srvRecv 2, .deliver 1, .deliver 2, .srvRecv 1, .deliver 2,
       .srvRecv 2, .deliver 1, .dcOpen .a, .dcOpen .b, .arrive .a, .arrive .b]
      bothResumed = true := by
  decide

/-- A's channel opens and B's does not within 10 s: A's answer timer
    restarts, which fails B's pairing; both redial and resume. -/
theorem witness_answer_timeout :
    witnesses .rev (handshake ++ [.dcOpen .a, .answerT .a, .pcFail .b, .srvRecv 0]
        ++ redial2 2 3) bothResumed = true := by
  decide

/-- B's phone is frozen across the whole drop: A redials and waits; B wakes,
    its connection fails, it dials and pairs. -/
theorem witness_frozen_friend :
    witnesses .rev
      [.suspend .b, .dcClose .a, .open_ 0, .srvRecv 0, .deliver 0, .wake .b,
       .dcClose .b, .open_ 1, .srvRecv 1, .deliver 0, .deliver 1, .srvRecv 0, .deliver 1,
       .srvRecv 1, .deliver 0, .dcOpen .a, .dcOpen .b, .arrive .a, .arrive .b]
      bothResumed = true := by
  decide

/-! ## No dead end (reviewed code)

`CInv s c` is what each client's handlers keep; its second half is the
theorem: a redialing side always has a way `forward`. `RecOK` is what that
needs of the client's own fields: each timer's callback finds the state it
was armed for, so it restarts rather than doing nothing; an adopted channel
has its answer timer; a pairing not yet open has its deadline; a retry is
armed only with no socket. `Fr x` frames what client `x`'s handlers can
touch, `Keep` what the server's and the network's can. -/

section proj
variable (s : State) (c d : Cl) (k j p : Nat) (f : Client → Client) (g : Sock → Sock)
  (h : PC → PC) (o : Option Nat)

@[simp] theorem updC_cl : (updC c f s).cl d = if d = c then f (s.cl d) else s.cl d := rfl
@[simp] theorem updC_socks : (updC c f s).socks = s.socks := rfl
@[simp] theorem updC_pcs : (updC c f s).pcs = s.pcs := rfl
@[simp] theorem updC_nextSock : (updC c f s).nextSock = s.nextSock := rfl
@[simp] theorem updK_cl : (updK k g s).cl = s.cl := rfl
@[simp] theorem updK_socks : (updK k g s).socks j = if j = k then g (s.socks j) else s.socks j :=
  rfl
@[simp] theorem updK_nextSock : (updK k g s).nextSock = s.nextSock := rfl
@[simp] theorem updK_pcs : (updK k g s).pcs = s.pcs := rfl
@[simp] theorem updP_cl : (updP p h s).cl = s.cl := rfl
@[simp] theorem updP_socks : (updP p h s).socks = s.socks := rfl
@[simp] theorem updP_nextSock : (updP p h s).nextSock = s.nextSock := rfl
@[simp] theorem closeOwn_cl : (closeOwn k s).cl = s.cl := rfl
@[simp] theorem closeOwn_nextSock : (closeOwn k s).nextSock = s.nextSock := rfl
@[simp] theorem closeWs_cl : (closeWs c s).cl = s.cl := by unfold closeWs; split <;> rfl
@[simp] theorem closeWs_nextSock : (closeWs c s).nextSock = s.nextSock := by
  unfold closeWs; split <;> rfl
@[simp] theorem closePc_cl : (closePc o s).cl = s.cl := by cases o <;> rfl
@[simp] theorem closePc_socks : (closePc o s).socks = s.socks := by cases o <;> rfl
@[simp] theorem closePc_nextSock : (closePc o s).nextSock = s.nextSock := by cases o <;> rfl
end proj

theorem closeOwn_owner (k j : Nat) (s : State) :
    ((closeOwn k s).socks j).owner = (s.socks j).owner := by
  unfold closeOwn; simp only [updK_socks]; split <;> (try split) <;> rfl

theorem closeWs_owner (x : Cl) (j : Nat) (s : State) :
    ((closeWs x s).socks j).owner = (s.socks j).owner := by
  unfold closeWs; split
  · exact closeOwn_owner ..
  · rfl

/-! ### Frames -/

/-- `t` differs from `s` only where no client invariant looks: the server's
    side of the sockets, frames in flight, the pcs, the room. -/
structure Keep (s t : State) : Prop where
  cl : t.cl = s.cl
  ns : t.nextSock = s.nextSock
  owner : ∀ k, (t.socks k).owner = (s.socks k).owner
  cst : ∀ k, (t.socks k).cst = (s.socks k).cst

theorem Keep.refl (s : State) : Keep s s := ⟨rfl, rfl, fun _ => rfl, fun _ => rfl⟩

theorem Keep.trans {s t u : State} (a : Keep s t) (b : Keep t u) : Keep s u :=
  ⟨b.cl.trans a.cl, b.ns.trans a.ns, fun k => (b.owner k).trans (a.owner k),
   fun k => (b.cst k).trans (a.cst k)⟩

theorem keep_updK {s : State} (k : Nat) {g : Sock → Sock}
    (hg : ∀ y, (g y).owner = y.owner ∧ (g y).cst = y.cst) : Keep s (updK k g s) where
  cl := rfl
  ns := rfl
  owner j := by simp only [updK_socks]; split <;> simp [hg]
  cst j := by simp only [updK_socks]; split <;> simp [hg]

theorem keep_updP {s : State} (p : Nat) (h : PC → PC) : Keep s (updP p h s) :=
  ⟨rfl, rfl, fun _ => rfl, fun _ => rfl⟩

theorem keep_room {s : State} (r : Option Room) : Keep s { s with room := r } :=
  ⟨rfl, rfl, fun _ => rfl, fun _ => rfl⟩

theorem keep_push {s : State} (k : Nat) (m : Down) : Keep s (push k m s) := by
  unfold push; dsimp only; split
  · exact Keep.refl s
  · exact keep_updK k (fun _ => ⟨rfl, rfl⟩)

theorem keep_srvClose {s : State} (k : Nat) : Keep s (srvClose k s) :=
  keep_updK k (fun _ => ⟨rfl, rfl⟩)

theorem keep_send {s : State} (k : Nat) (u : Up) : Keep s (send k u s) :=
  keep_updK k (fun y => by split <;> exact ⟨rfl, rfl⟩)

theorem keep_srvOff {s : State} (k : Nat) :
    Keep s (updK k (fun x => { x with srv := false }) s) := keep_updK k (fun _ => ⟨rfl, rfl⟩)

theorem keep_teardown {s : State} (k : Nat) : Keep s (teardown k s) := by
  unfold teardown; dsimp only
  have h0 := keep_srvOff (s := s) k
  split
  · split
    · split
      · exact h0.trans ((keep_room _).trans ((keep_push _ _).trans (keep_srvClose _)))
      · exact h0.trans (keep_room _)
    · split
      · exact h0.trans ((keep_room _).trans ((keep_push _ _).trans (keep_srvClose _)))
      · exact h0
  · exact h0

theorem keep_pair {s : State} (h k : Nat) : Keep s (pair h k s) :=
  (keep_room _).trans ((keep_push _ _).trans (keep_push _ _))

theorem keep_evict {s : State} (j : Nat) (i : Option Nat) (k : Nat) :
    Keep s (evict j i k s) := by
  unfold evict; dsimp only
  have h0 := keep_srvOff (s := s) j
  cases i with
  | none => exact h0.trans ((keep_room _).trans (keep_push _ _))
  | some i =>
    exact h0.trans (((keep_push _ _).trans (keep_srvClose _)).trans
      ((keep_room _).trans (keep_push _ _)))

theorem keep_srvRz {s : State} (k : Nat) : Keep s (srvRz k s) := by
  unfold srvRz; dsimp only
  split
  · exact (keep_room _).trans (keep_push _ _)
  · split
    · exact keep_evict ..
    · exact keep_pair ..
  · split
    · exact keep_evict ..
    · split
      · exact keep_evict ..
      · exact (keep_push _ _).trans (keep_srvClose _)

theorem keep_relay {s : State} (k p : Nat) : Keep s (relay k p s) := by
  unfold relay
  split
  · split
    · exact keep_push ..
    · split
      · exact keep_push ..
      · exact Keep.refl s
  · exact Keep.refl s

theorem keep_srvRecv {s : State} (k : Nat) : Keep s (srvRecv k s) := by
  unfold srvRecv
  split
  · exact Keep.refl s
  · rename_i m rest _
    refine (keep_updK k (g := fun x => { x with up := rest }) (fun _ => ⟨rfl, rfl⟩)).trans ?_
    dsimp only
    split
    · exact keep_srvRz _
    · exact keep_relay _ _
    · exact keep_teardown _

/-- `t` is `s` after client `x`'s handler ran: the other client untouched,
    existing sockets keep their owners, and only `x`'s change state. -/
structure Fr (x : Cl) (s t : State) : Prop where
  cl : ∀ c, c ≠ x → t.cl c = s.cl c
  ns : s.nextSock ≤ t.nextSock
  owner : ∀ k, k < s.nextSock → (t.socks k).owner = (s.socks k).owner
  cst : ∀ k, k < s.nextSock → (s.socks k).owner ≠ x → (t.socks k).cst = (s.socks k).cst

theorem Fr.refl (x : Cl) (s : State) : Fr x s s :=
  ⟨fun _ _ => rfl, Nat.le_refl _, fun _ _ => rfl, fun _ _ _ => rfl⟩

theorem Fr.trans {x : Cl} {s t u : State} (a : Fr x s t) (b : Fr x t u) : Fr x s u where
  cl c hc := (b.cl c hc).trans (a.cl c hc)
  ns := Nat.le_trans a.ns b.ns
  owner k hk := (b.owner k (Nat.lt_of_lt_of_le hk a.ns)).trans (a.owner k hk)
  cst k hk ho := by
    rw [b.cst k (Nat.lt_of_lt_of_le hk a.ns) (by rw [a.owner k hk]; exact ho), a.cst k hk ho]

theorem Keep.fr {x : Cl} {s t : State} (h : Keep s t) : Fr x s t where
  cl c _ := by rw [h.cl]
  ns := by rw [h.ns]; exact Nat.le_refl _
  owner k _ := h.owner k
  cst k _ _ := h.cst k

theorem fr_updC (x : Cl) (f : Client → Client) (s : State) : Fr x s (updC x f s) where
  cl c hc := by simp [hc]
  ns := Nat.le_refl _
  owner _ _ := rfl
  cst _ _ _ := rfl

theorem fr_closeOwn {x : Cl} {s : State} {k : Nat} (h : (s.socks k).owner = x) :
    Fr x s (closeOwn k s) where
  cl _ _ := rfl
  ns := Nat.le_refl _
  owner j _ := closeOwn_owner ..
  cst j _ hj := by
    unfold closeOwn; simp only [updK_socks]; split
    · rename_i hjk; subst hjk; exact absurd h hj
    · rfl

theorem fr_dial (x : Cl) (s : State) : Fr x s (dial x s) where
  cl c hc := by simp [dial, hc]
  ns := by simp [dial]
  owner k hk := by simp [dial, Nat.ne_of_lt hk]
  cst k hk _ := by simp [dial, Nat.ne_of_lt hk]

/-- `x`'s server socket is `x`'s. -/
def WsOwn (x : Cl) (s : State) : Prop := ∀ k, (s.cl x).ws = some k → (s.socks k).owner = x

theorem wsOwn_updC {x : Cl} {s : State} {f : Client → Client} (h : WsOwn x s)
    (hf : (f (s.cl x)).ws = (s.cl x).ws ∨ (f (s.cl x)).ws = none) : WsOwn x (updC x f s) := by
  intro k hk
  simp only [updC_cl, ite_true] at hk
  rcases hf with hf | hf
  · rw [hf] at hk; exact h k hk
  · rw [hf] at hk; cases hk

theorem wsOwn_keep {x : Cl} {s t : State} (h : WsOwn x s) (hk : Keep s t) : WsOwn x t := by
  intro k hw; rw [hk.owner]; rw [hk.cl] at hw; exact h k hw

theorem wsOwn_closeWs {x : Cl} {s : State} (h : WsOwn x s) : WsOwn x (closeWs x s) := by
  intro k hk; rw [closeWs_owner]; rw [closeWs_cl] at hk; exact h k hk

theorem fr_closeWs {x : Cl} {s : State} (h : WsOwn x s) : Fr x s (closeWs x s) := by
  unfold closeWs; split
  · rename_i k hk; exact fr_closeOwn (h k hk)
  · exact Fr.refl x s

theorem fr_closePc (x : Cl) (o : Option Nat) (s : State) : Fr x s (closePc o s) := by
  cases o with
  | none => exact Fr.refl x s
  | some p => exact (keep_updP (s := s) p (fun y => { y with closed := true })).fr

theorem fr_detach {x : Cl} {s : State} (h : WsOwn x s) : Fr x s (detach x s) :=
  (fr_closeWs h).trans ((fr_closePc _ _ _).trans ((fr_closePc _ _ _).trans (fr_updC _ _ _)))

theorem fr_restart {x : Cl} {s : State} (h : WsOwn x s) : Fr x s (restart x s) := by
  unfold restart; split
  · exact (fr_detach h).trans (fr_updC _ _ _)
  · exact Fr.refl x s

theorem fr_begin (cfg : Cfg) {x : Cl} {s : State} (h : WsOwn x s) : Fr x s (begin cfg x s) := by
  unfold begin; split
  · split
    · exact fr_restart h
    · exact Fr.refl x s
  · exact (fr_updC _ _ _).trans ((fr_detach (wsOwn_updC h (Or.inl rfl))).trans (fr_dial _ _))
  · exact Fr.refl x s

theorem fr_rsStop {x : Cl} {s : State} (h : WsOwn x s) : Fr x s (rsStop x s) := by
  unfold rsStop; dsimp only
  refine (fr_closeWs h).trans ?_
  split
  · exact (fr_closePc _ _ _).trans (fr_updC _ _ _)
  · exact fr_updC _ _ _

theorem fr_resumed {x : Cl} {s : State} (h : WsOwn x s) : Fr x s (resumed x s) :=
  (fr_rsStop h).trans (fr_updC _ _ _)

theorem fr_endS {x : Cl} {s : State} (h : WsOwn x s) : Fr x s (endS x s) := by
  unfold endS; dsimp only
  exact (fr_rsStop h).trans ((fr_closePc _ _ _).trans (fr_updC _ _ _))

/-! ### The client invariant -/

/-- What `forward` needs of a client's own fields. -/
structure RecOK (y : Client) : Prop where
  pair : ∀ p, y.pairT = some p → y.rsPc = some p ∧ y.dcOpen = false
  pcT : y.ph = .recon → ∀ p, y.rsPc = some p → y.dcOpen = false → y.pairT = some p
  answer : ∀ p, y.answerT = some p → y.cur = some p
  opn : y.ph = .recon → y.dcOpen = true → y.answerT.isSome = true
  sdpPc : y.ph = .recon → y.sdpIn = true → y.rsPc.isSome = true
  rew : ∀ k, y.rewaitT = some k → y.ws = some k ∨ y.dcOpen = true ∨ y.sdpIn = true
  retryWs : y.retryT = true → y.ws = none ∧ y.rewaitT = none

structure Base (s : State) (c : Cl) : Prop where
  own : ∀ k, (s.cl c).ws = some k → (s.socks k).owner = c ∧ k < s.nextSock
  ok : RecOK (s.cl c)

def CInv (s : State) (c : Cl) : Prop :=
  Base s c ∧ ((s.cl c).ph = .recon → forward s c = true)

def Inv (s : State) : Prop := ∀ c, CInv s c

theorem Base.wsOwn {s : State} {c : Cl} (h : Base s c) : WsOwn c s := fun k hk => (h.own k hk).1

/-- The fields `RecOK` and `forward` read. -/
def Client.key (y : Client) :=
  (y.ph, y.cur, y.ws, y.rsPc, y.dcOpen, y.sdpIn, y.retryT, y.pairT, y.answerT, y.rewaitT)

theorem recOK_key {y z : Client} (h : y.key = z.key) (hz : RecOK z) : RecOK y := by
  cases y; cases z
  simp only [Client.key, Prod.mk.injEq] at h
  obtain ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩ := h
  exact ⟨hz.pair, hz.pcT, hz.answer, hz.opn, hz.sdpPc, hz.rew, hz.retryWs⟩

theorem forward_congr {s t : State} {c : Cl}
    (e : (t.cl c).key = (s.cl c).key)
    (hk : ∀ k, (s.cl c).ws = some k → (t.socks k).cst = (s.socks k).cst) :
    forward t c = forward s c := by
  simp only [Client.key, Prod.mk.injEq] at e
  obtain ⟨_, _, hws, _, _, _, hr, hp, ha, hw⟩ := e
  unfold forward
  simp only [hws, hr, hp, ha, hw]
  cases h : (s.cl c).ws with
  | none => rfl
  | some k => simp only [hk k h]

theorem forward_of_timer {s : State} {c : Cl}
    (h : (s.cl c).retryT = true ∨ (s.cl c).pairT.isSome = true ∨
      (s.cl c).answerT.isSome = true ∨ (s.cl c).rewaitT.isSome = true) :
    forward s c = true := by
  unfold forward; rcases h with h | h | h | h <;> simp [h]

theorem forward_of_ws {s : State} {c : Cl} {k : Nat} (hw : (s.cl c).ws = some k)
    (hc : (s.socks k).cst ≠ .closed) : forward s c = true := by
  simp [forward, hw, hc]

theorem cinv_other {c x : Cl} {s t : State} (hs : CInv s c) (hf : Fr x s t) (hc : c ≠ x) :
    CInv t c := by
  have e := hf.cl c hc
  obtain ⟨⟨own, ok⟩, fw⟩ := hs
  refine ⟨⟨fun k hk => ?_, e ▸ ok⟩, fun hr => ?_⟩
  · rw [e] at hk
    obtain ⟨ho, hlt⟩ := own k hk
    exact ⟨(hf.owner k hlt).trans ho, Nat.lt_of_lt_of_le hlt hf.ns⟩
  · rw [e] at hr
    rw [forward_congr (by rw [e]) (fun k hk => hf.cst k (own k hk).2
      (by rw [(own k hk).1]; exact hc))]
    exact fw hr

theorem Cl.ne_other (c : Cl) : c ≠ c.other := by cases c <;> decide

theorem cinv_keep {c : Cl} {s t : State} (hs : CInv s c) (hk : Keep s t) : CInv t c :=
  cinv_other hs (hk.fr (x := c.other)) (Cl.ne_other c)

theorem inv_keep {s t : State} (hs : Inv s) (hk : Keep s t) : Inv t := fun c => cinv_keep (hs c) hk

theorem inv_of_fr {x : Cl} {s t : State} (hs : ∀ c, c ≠ x → CInv s c) (hf : Fr x s t)
    (hx : CInv t x) : Inv t := by
  intro c; by_cases hc : c = x
  · subst hc; exact hx
  · exact cinv_other (hs c hc) hf hc

/-- The actor's record changed, its socket and the sockets did not. -/
theorem cinv_updC {x : Cl} {s : State} {f : Client → Client} (hb : Base s x)
    (hws : (f (s.cl x)).ws = (s.cl x).ws ∨ (f (s.cl x)).ws = none)
    (hrec : RecOK (f (s.cl x)))
    (hfw : (f (s.cl x)).ph = .recon → forward (updC x f s) x = true) : CInv (updC x f s) x := by
  refine ⟨⟨fun k hk => ?_, by simpa using hrec⟩, fun hr => hfw (by simpa using hr)⟩
  simp only [updC_cl, ite_true] at hk
  rcases hws with h | h
  · rw [h] at hk; exact hb.own k hk
  · rw [h] at hk; cases hk

@[simp] theorem updC_self (c : Cl) (f : Client → Client) (s : State) :
    (updC c f s).cl c = f (s.cl c) := by simp

/-- Only fields nothing here reads changed. -/
theorem cinv_updC_key {x : Cl} {s : State} {f : Client → Client} (hs : CInv s x)
    (hk : (f (s.cl x)).key = (s.cl x).key) : CInv (updC x f s) x := by
  obtain ⟨⟨own, ok⟩, fw⟩ := hs
  have hk' := hk
  simp only [Client.key, Prod.mk.injEq] at hk'
  refine cinv_updC ⟨own, ok⟩ (Or.inl hk'.2.2.1) (recOK_key hk ok) (fun hr => ?_)
  rw [forward_congr (t := updC x f s) (s := s) (by simpa using hk) (fun _ _ => rfl)]
  exact fw (hk'.1 ▸ hr)

theorem recOK_of {y : Client} (h1 : y.pairT = none) (h2 : y.answerT = none)
    (h3 : y.rewaitT = none) (h4 : y.rsPc = none) (h5 : y.dcOpen = false) (h6 : y.sdpIn = false)
    (h7 : y.retryT = true → y.ws = none) : RecOK y where
  pair _ h := by rw [h1] at h; cases h
  pcT _ _ h := by rw [h4] at h; cases h
  answer _ h := by rw [h2] at h; cases h
  opn _ h := by rw [h5] at h; cases h
  sdpPc _ h := by rw [h6] at h; cases h
  rew _ h := by rw [h3] at h; cases h
  retryWs h := ⟨h7 h, h3⟩

theorem recOK_stop {y : Client} (hph : y.ph ≠ .recon) (h1 : y.pairT = none)
    (h2 : y.answerT = none) (h3 : y.rewaitT = none) (hr : y.retryT = false) : RecOK y where
  pair _ h := by rw [h1] at h; cases h
  pcT h := absurd h hph
  answer _ h := by rw [h2] at h; cases h
  opn h := absurd h hph
  sdpPc h := absurd h hph
  rew _ h := by rw [h3] at h; cases h
  retryWs h := by rw [hr] at h; cases h

theorem stopped_ph (y : Client) : y.stopped.ph ≠ .recon := by
  cases hp : y.ph <;> simp [Client.stopped, hp]

theorem cinv_stop {t : State} {x : Cl} (hph : (t.cl x).ph ≠ .recon) (hws : (t.cl x).ws = none)
    (h1 : (t.cl x).pairT = none) (h2 : (t.cl x).answerT = none) (h3 : (t.cl x).rewaitT = none)
    (hr : (t.cl x).retryT = false) : CInv t x :=
  ⟨⟨fun k hk => (by rw [hws] at hk; cases hk), recOK_stop hph h1 h2 h3 hr⟩, fun h => absurd h hph⟩

/-! ### Each handler keeps it -/

theorem restart_ok {x : Cl} {s : State} (hs : ∀ c, c ≠ x → CInv s c) (hown : WsOwn x s)
    (hb : (s.cl x).ph ≠ .recon → Base s x) : Inv (restart x s) := by
  refine inv_of_fr hs (fr_restart hown) ?_
  by_cases h : (s.cl x).ph = .recon
  · have e : (restart x s).cl x = { (s.cl x).detached with retryT := true } := by
      simp [restart, h, detach]
    refine ⟨⟨fun k hk => (by rw [e] at hk; simp [Client.detached] at hk), ?_⟩, fun _ => ?_⟩
    · rw [e]; exact recOK_of rfl rfl rfl rfl rfl rfl (fun _ => rfl)
    · exact forward_of_timer (Or.inl (by rw [e]))
  · have e : restart x s = s := by simp [restart, h]
    rw [e]; exact ⟨hb h, fun hr => absurd hr h⟩

theorem rsStop_cl (x : Cl) (s : State) : (rsStop x s).cl x = (s.cl x).stopped := by
  unfold rsStop; dsimp only; split <;> simp

theorem resumed_ok {x : Cl} {s : State} (hs : Inv s) : Inv (resumed x s) := by
  refine inv_of_fr (fun c _ => hs c) (fr_resumed (hs x).1.wsOwn) ?_
  have e : (resumed x s).cl x = { (s.cl x).stopped with resumes := (s.cl x).stopped.resumes + 1 } := by
    simp [resumed, rsStop_cl]
  exact cinv_stop (by rw [e]; exact stopped_ph _) (by rw [e]; rfl) (by rw [e]; rfl)
    (by rw [e]; rfl) (by rw [e]; rfl) (by rw [e]; rfl)

theorem endS_ok {x : Cl} {s : State} (hs : Inv s) : Inv (endS x s) := by
  refine inv_of_fr (fun c _ => hs c) (fr_endS (hs x).1.wsOwn) ?_
  have e : (endS x s).cl x = { (s.cl x).stopped with ph := .ended, cur := none } := by
    simp [endS, rsStop_cl]
  exact cinv_stop (by rw [e]; simp) (by rw [e]; rfl) (by rw [e]; rfl) (by rw [e]; rfl)
    (by rw [e]; rfl) (by rw [e]; rfl)

theorem begin_ok {x : Cl} {s : State} (hs : Inv s) : Inv (begin .rev x s) := by
  have hoth : ∀ c, c ≠ x → CInv s c := fun c _ => hs c
  unfold begin
  split
  · exact restart_ok hoth (hs x).1.wsOwn (fun _ => (hs x).1)
  · refine inv_of_fr hoth ((fr_updC _ _ _).trans
      ((fr_detach (wsOwn_updC (hs x).1.wsOwn (Or.inl rfl))).trans (fr_dial _ _))) ?_
    -- a fresh connecting socket, everything else cleared
    have e : (dial x (detach x (updC x (fun y => { y with ph := .recon, giveUpT := true }) s))).cl x
        = { ({ s.cl x with ph := .recon, giveUpT := true } : Client).detached with
            ws := some s.nextSock } := by
      simp [dial, detach]
    have hk : (dial x (detach x (updC x (fun y => { y with ph := .recon, giveUpT := true }) s))).socks
        s.nextSock = { owner := x, cst := .connecting } := by
      simp [dial, detach]
    have hn : (dial x (detach x (updC x (fun y => { y with ph := .recon, giveUpT := true }) s))).nextSock
        = s.nextSock + 1 := by
      simp [dial, detach]
    refine ⟨⟨fun k hw => ?_, ?_⟩, fun _ => forward_of_ws (k := s.nextSock) (by rw [e]) (by rw [hk]; simp)⟩
    · rw [e] at hw
      obtain rfl : s.nextSock = k := by simpa using hw
      rw [hk, hn]; exact ⟨rfl, Nat.lt_succ_self _⟩
    · rw [e]; exact recOK_of rfl rfl rfl rfl rfl rfl (fun h => by cases h)
  · exact hs

theorem startRtc_ok {x : Cl} {s : State} (k : Nat) (r : Role) (hs : Inv s) :
    Inv (startRtc x k r s) := by
  unfold startRtc; dsimp only
  have h0 : Inv (updP s.nextPc (fun _ => { owner := x, role := r, closed := false })
      { s with nextPc := s.nextPc + 1 }) :=
    inv_keep hs ((show Keep s { s with nextPc := s.nextPc + 1 } from
      ⟨rfl, rfl, fun _ => rfl, fun _ => rfl⟩).trans (keep_updP _ _))
  have h1 : Inv (updC x (fun y => { y with rsPc := some s.nextPc, dcOpen := false,
                                           sdpIn := false, pairT := some s.nextPc,
                                           rewaitT := none })
      (updP s.nextPc (fun _ => { owner := x, role := r, closed := false })
        { s with nextPc := s.nextPc + 1 })) := by
    refine inv_of_fr (fun c _ => h0 c) (fr_updC _ _ _) (cinv_updC (h0 x).1 (Or.inl rfl) ?_ ?_)
    · have h := (h0 x).1.ok
      exact { pair := fun p hp => by cases hp; exact ⟨rfl, rfl⟩
              pcT := fun _ p hp _ => by cases hp; rfl
              answer := h.answer
              opn := fun _ hd => by cases hd
              sdpPc := fun _ hd => by cases hd
              rew := fun _ hw => by cases hw
              retryWs := fun hr => ⟨(h.retryWs hr).1, rfl⟩ }
    · exact fun _ => forward_of_timer (Or.inr (Or.inl (by simp)))
  split
  · exact inv_keep h1 (keep_send _ _)
  · exact h1

theorem onMsg_ok {x : Cl} {s : State} {k : Nat} (m : Down) (hs : Inv s)
    (hw : (s.cl x).ws = some k) (hc : (s.socks k).cst = .opn) : Inv (onMsg .rev x k m s) := by
  have hoth : ∀ c, c ≠ x → CInv s c := fun c _ => hs c
  have hb := (hs x).1
  cases m with
  | waiting =>
    show Inv (updC x (fun x => { x with rewaitT := some k }) s)
    refine inv_of_fr hoth (fr_updC _ _ _) (cinv_updC hb (Or.inl rfl) ?_ ?_)
    · have h := hb.ok
      have hr : (s.cl x).retryT = false := by
        cases h' : (s.cl x).retryT
        · rfl
        · have := (h.retryWs h').1; rw [hw] at this; cases this
      exact { pair := h.pair, pcT := h.pcT, answer := h.answer, opn := h.opn, sdpPc := h.sdpPc
              rew := fun _ hk => by cases hk; exact Or.inl hw
              retryWs := fun h' => by simp [hr] at h' }
    · exact fun _ => forward_of_timer (Or.inr (Or.inr (Or.inr (by simp))))
  | paired r => exact startRtc_ok k r hs
  | sdp q =>
    show Inv (match (s.cl x).rsPc with
      | some p =>
        if ((updP p (fun y => { y with remote := some q })
            (updC x (fun x => { x with sdpIn := true }) s)).pcs p).role = .guest
        then send k (.sdp p) (updP p (fun y => { y with remote := some q })
            (updC x (fun x => { x with sdpIn := true }) s))
        else updP p (fun y => { y with remote := some q })
            (updC x (fun x => { x with sdpIn := true }) s)
      | none => s)
    cases hp : (s.cl x).rsPc with
    | none => exact hs
    | some p =>
      dsimp only
      have h1 : Inv (updC x (fun x => { x with sdpIn := true }) s) := by
        refine inv_of_fr hoth (fr_updC _ _ _) (cinv_updC hb (Or.inl rfl) ?_ ?_)
        · have h := hb.ok
          exact { pair := h.pair, pcT := h.pcT, answer := h.answer, opn := h.opn
                  sdpPc := fun _ _ => by simp [hp]
                  rew := fun j hj => Or.inr (Or.inr rfl)
                  retryWs := h.retryWs }
        · exact fun _ => forward_of_ws (k := k) (by simpa using hw) (by simp [hc])
      have h2 := inv_keep h1 (keep_updP p (fun y => { y with remote := some q }))
      split
      · exact inv_keep h2 (keep_send _ _)
      · exact h2
  | peerClosed =>
    show Inv (if !(s.cl x).dcOpen && !(true && (s.cl x).sdpIn) then restart x s else s)
    split
    · exact restart_ok hoth hb.wsOwn (fun _ => hb)
    · exact hs
  | inUse => exact restart_ok hoth hb.wsOwn (fun _ => hb)

theorem adopt_ok {x : Cl} {s : State} (p : Nat) (hs : Inv s) : Inv (adopt .rev x p s) := by
  show Inv (let s := updP p (fun y => { y with opened := true, rs := .sent }) s
    let s := updC x (fun y => { y with dcOpen := true, pairT := none, cur := some p,
                                       answerT := some p, ws := y.ws }) s
    if (s.pcs p).early then resumed x s else s)
  dsimp only
  have h0 := inv_keep hs (keep_updP p (fun y => { y with opened := true, rs := .sent }))
  have h1 : Inv (updC x (fun y => { y with dcOpen := true, pairT := none, cur := some p,
                                           answerT := some p, ws := y.ws })
      (updP p (fun y => { y with opened := true, rs := .sent }) s)) := by
    refine inv_of_fr (fun c _ => h0 c) (fr_updC _ _ _) (cinv_updC (h0 x).1 (Or.inl rfl) ?_ ?_)
    · have h := (h0 x).1.ok
      exact { pair := fun _ hp => by cases hp
              pcT := fun _ _ _ hd => by cases hd
              answer := fun _ hp => by cases hp; rfl
              opn := fun _ _ => rfl
              sdpPc := h.sdpPc
              rew := fun _ _ => Or.inr (Or.inl rfl)
              retryWs := h.retryWs }
    · exact fun _ => forward_of_timer (Or.inr (Or.inr (Or.inl (by simp))))
  split
  · exact resumed_ok h1
  · exact h1

theorem arrive_ok {x : Cl} {s : State} (hs : Inv s) : Inv (arrive .rev x s) := by
  unfold arrive; dsimp only
  split
  · split
    · rename_i p _ q _
      have h0 := inv_keep hs (keep_updP q (fun y => { y with rs := .got }))
      split
      · exact resumed_ok h0
      · split
        · exact inv_keep h0 (keep_updP _ _)
        · exact h0
    · exact hs
  · exact hs

/-- With `rsPc` or a socket the rewait was armed for gone, the pairing
    deadline or the answer timer covers the side. -/
theorem fwd_rewait_noop {y : Client} (h : RecOK y) (hr : y.ph = .recon) {k : Nat}
    (hk : y.rewaitT = some k) (hg : ¬(y.rewaitT = y.ws ∧ y.rsPc = none)) :
    y.pairT.isSome = true ∨ y.answerT.isSome = true := by
  cases hd : y.dcOpen
  · cases hp : y.rsPc with
    | some p => exact Or.inl (by rw [h.pcT hr p hp hd]; rfl)
    | none =>
      rcases h.rew k hk with hw | hw | hw
      · exact absurd ⟨by rw [hk, hw], hp⟩ hg
      · rw [hd] at hw; cases hw
      · have := h.sdpPc hr hw; rw [hp] at this; cases this
  · exact Or.inr (h.opn hr hd)

/-- A socket whose state changed is not this client's. -/
theorem cinv_sockOther {c : Cl} {s : State} {k : Nat} {g : Sock → Sock} (hs : CInv s c)
    (hne : (s.cl c).ws ≠ some k) (hg : ∀ y, (g y).owner = y.owner) : CInv (updK k g s) c := by
  obtain ⟨⟨own, ok⟩, fw⟩ := hs
  refine ⟨⟨fun j hj => ?_, ok⟩, fun hr => ?_⟩
  · obtain ⟨ho, hlt⟩ := own j hj
    refine ⟨?_, hlt⟩
    simp only [updK_socks]; split
    · rw [hg]; exact ho
    · exact ho
  · rw [forward_congr (t := updK k g s) (s := s) rfl (fun j hj => by
      simp only [updK_socks]; split
      · subst_vars; exact absurd hj hne
      · rfl)]
    exact fw hr

theorem inv_step {s : State} (hs : Inv s) (e : Event) (he : en s e = true) :
    Inv (step .rev s e) := by
  cases e with
  | suspend c | wake c =>
    simp only [step]
    exact inv_of_fr (fun d _ => hs d) (fr_updC _ _ _) (cinv_updC_key (hs c) (by simp [Client.key]))
  | cut p => simp only [step]; exact inv_keep hs (keep_updP _ _)
  | open_ k =>
    intro c
    obtain ⟨⟨own, ok⟩, fw⟩ := hs c
    refine ⟨⟨fun j hj => ?_, ok⟩, fun hr => ?_⟩
    · obtain ⟨ho, hlt⟩ := own j hj
      refine ⟨?_, hlt⟩
      simp only [step, updK_socks]; split
      · exact ho
      · exact ho
    · by_cases hw : (s.cl c).ws = some k
      · exact forward_of_ws hw (by simp [step])
      · have := cinv_sockOther (g := fun x => { x with cst := .opn, srv := true, up := [.rz] })
          ⟨⟨own, ok⟩, fw⟩ hw (fun _ => rfl)
        exact this.2 hr
  | die k =>
    simp only [step]
    exact inv_keep hs (keep_updK k (g := fun x => { x with dead := true, down := [], up := [] })
      (fun _ => ⟨rfl, rfl⟩))
  | srvRecv k => simp only [step]; exact inv_keep hs (keep_srvRecv k)
  | srvNotice k =>
    simp only [step]
    exact inv_keep hs ((keep_updK k (g := fun x => { x with up := [] })
      (fun _ => ⟨rfl, rfl⟩)).trans (keep_teardown k))
  | cclose k =>
    simp only [step]
    generalize ho : (s.socks k).owner = o
    have hcl : ∀ c, (s.cl c).ws ≠ some k → CInv (updK k (fun y => { y with cst := .closed }) s) c :=
      fun c hne => cinv_sockOther (hs c) hne (fun _ => rfl)
    have hb1 : Base (updK k (fun y => { y with cst := .closed }) s) o := by
      obtain ⟨own, ok⟩ := (hs o).1
      refine ⟨fun j hj => ?_, ok⟩
      obtain ⟨h1, h2⟩ := own j hj
      refine ⟨?_, h2⟩
      simp only [updK_socks]; split <;> exact h1
    -- the other client's socket is never k
    have hoth : ∀ c, c ≠ o → (s.cl c).ws ≠ some k := by
      intro c hc hw
      have := ((hs c).1.own k hw).1
      rw [ho] at this; exact hc this.symm
    split
    · rename_i hne
      have hne' : (s.cl o).ws ≠ some k := by simpa using hne
      intro c
      by_cases hc : c = o
      · rw [hc]; exact hcl o hne'
      · exact hcl c (hoth c hc)
    · rename_i hwk
      have hwk : (s.cl o).ws = some k := by simpa using hwk
      split
      · rename_i hd
        refine inv_of_fr (fun c hc => hcl c (hoth c hc)) (fr_updC _ _ _)
          (cinv_updC hb1 (Or.inr rfl) ?_ ?_)
        · have h := hb1.ok
          simp only [updK_cl] at h
          have hd' : (s.cl o).dcOpen = true ∨ (s.cl o).sdpIn = true := by
            simpa [Cfg.rev] using hd
          exact { pair := h.pair, pcT := h.pcT, answer := h.answer, opn := h.opn
                  sdpPc := h.sdpPc
                  rew := fun j _ => Or.inr hd'
                  retryWs := fun hr => ⟨rfl, (h.retryWs hr).2⟩ }
        · intro hr
          have h := hb1.ok
          simp only [updK_cl] at h hr
          have hd' : (s.cl o).dcOpen = true ∨ (s.cl o).sdpIn = true := by simpa [Cfg.rev] using hd
          apply forward_of_timer
          rw [updC_self]; simp only [updK_cl]
          rcases hd' with hd' | hd'
          · exact Or.inr (Or.inr (Or.inl (h.opn hr hd')))
          · cases hdo : (s.cl o).dcOpen
            · obtain ⟨p, hp⟩ := Option.isSome_iff_exists.mp (h.sdpPc hr hd')
              exact Or.inr (Or.inl (by rw [h.pcT hr p hp hdo]; rfl))
            · exact Or.inr (Or.inr (Or.inl (h.opn hr hdo)))
      · exact restart_ok (fun c hc => hcl c (hoth c hc)) hb1.wsOwn (fun _ => hb1)
  | deliver k =>
    simp only [step]
    split
    · exact hs
    · rename_i m rest hm
      have h1 := inv_keep hs (keep_updK k (g := fun y => { y with down := rest })
        (fun _ => ⟨rfl, rfl⟩))
      simp only [en, Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true'] at he
      exact onMsg_ok m h1 (by simpa using he.2) (by simp [he.1.1.1.1])
  | retry c =>
    simp only [step]
    have hb := (hs c).1
    have h := hb.ok
    have hr : (s.cl c).retryT = true := by simp [en] at he; exact he.2
    split
    · rename_i hph
      have hph : (s.cl c).ph = .recon := by simpa using hph
      refine inv_of_fr (fun d _ => hs d) ((fr_updC _ _ _).trans (fr_dial _ _)) ?_
      have e : (dial c (updC c (fun x => { x with retryT := false }) s)).cl c =
          { s.cl c with retryT := false, ws := some s.nextSock } := by simp [dial]
      have hk : (dial c (updC c (fun x => { x with retryT := false }) s)).socks s.nextSock =
          { owner := c, cst := .connecting } := by simp [dial]
      have hn : (dial c (updC c (fun x => { x with retryT := false }) s)).nextSock =
          s.nextSock + 1 := by simp [dial]
      have hrw := h.retryWs hr
      refine ⟨⟨fun k hw => ?_, ?_⟩,
        fun _ => forward_of_ws (k := s.nextSock) (by rw [e]) (by rw [hk]; simp)⟩
      · rw [e] at hw
        obtain rfl : s.nextSock = k := by simpa using hw
        rw [hk, hn]; exact ⟨rfl, Nat.lt_succ_self _⟩
      · rw [e]
        exact { pair := h.pair, pcT := h.pcT, answer := h.answer, opn := h.opn, sdpPc := h.sdpPc
                rew := fun j hj => by simp [hrw.2] at hj
                retryWs := fun h' => by cases h' }
    · rename_i hph
      have hph : ¬(s.cl c).ph = .recon := by simpa using hph
      refine inv_of_fr (fun d _ => hs d) (fr_updC _ _ _)
        (cinv_updC hb (Or.inl rfl) ?_ (fun h' => absurd (by simpa using h') hph))
      exact { pair := h.pair, pcT := h.pcT, answer := h.answer, opn := h.opn, sdpPc := h.sdpPc
              rew := h.rew, retryWs := fun h' => by cases h' }
  | pairT c =>
    simp only [step]
    have hb := (hs c).1
    have h := hb.ok
    obtain ⟨p, hp⟩ : ∃ p, (s.cl c).pairT = some p :=
      Option.isSome_iff_exists.mp (by simp [en] at he; exact he.2)
    obtain ⟨hrs, hd⟩ := h.pair p hp
    split
    case isFalse hc => simp [hp, hrs, hd] at hc
    refine restart_ok (fun d hd => cinv_other (hs d) (fr_updC _ _ _) hd)
      (wsOwn_updC hb.wsOwn (Or.inl rfl)) (fun hph => ⟨fun k hk => ?_, ?_⟩)
    · simpa using hb.own k (by simpa using hk)
    · rw [updC_self]
      have hph' : (s.cl c).ph ≠ .recon := by simpa using hph
      exact { pair := fun _ h' => (by cases h'), pcT := fun h' => absurd h' hph'
              answer := h.answer, opn := fun h' => absurd h' hph'
              sdpPc := fun h' => absurd h' hph', rew := h.rew, retryWs := h.retryWs }
  | answerT c =>
    simp only [step]
    have hb := (hs c).1
    have h := hb.ok
    obtain ⟨p, hp⟩ : ∃ p, (s.cl c).answerT = some p :=
      Option.isSome_iff_exists.mp (by simp [en] at he; exact he.2)
    split
    case isFalse hc => simp [hp, h.answer p hp] at hc
    refine restart_ok (fun d hd => cinv_other (hs d) (fr_updC _ _ _) hd)
      (wsOwn_updC hb.wsOwn (Or.inl rfl)) (fun hph => ⟨fun k hk => ?_, ?_⟩)
    · simpa using hb.own k (by simpa using hk)
    · rw [updC_self]
      have hph' : (s.cl c).ph ≠ .recon := by simpa using hph
      exact { pair := h.pair, pcT := fun h' => absurd h' hph'
              answer := fun _ h' => (by cases h'), opn := fun h' => absurd h' hph'
              sdpPc := fun h' => absurd h' hph', rew := h.rew, retryWs := h.retryWs }
  | rewaitT c =>
    simp only [step]
    have hb := (hs c).1
    have h := hb.ok
    obtain ⟨k, hk⟩ : ∃ k, (s.cl c).rewaitT = some k :=
      Option.isSome_iff_exists.mp (by simp [en] at he; exact he.2)
    have hrec : RecOK { s.cl c with rewaitT := none } :=
      { pair := h.pair, pcT := h.pcT, answer := h.answer, opn := h.opn, sdpPc := h.sdpPc
        rew := fun _ h' => by cases h'
        retryWs := fun hr => ⟨(h.retryWs hr).1, rfl⟩ }
    split
    · refine restart_ok (fun d hd => cinv_other (hs d) (fr_updC _ _ _) hd)
        (wsOwn_updC hb.wsOwn (Or.inl rfl)) (fun _ => ⟨fun j hj => ?_, by rw [updC_self]; exact hrec⟩)
      simpa using hb.own j (by simpa using hj)
    · rename_i hg
      refine inv_of_fr (fun d _ => hs d) (fr_updC _ _ _) (cinv_updC hb (Or.inl rfl) hrec ?_)
      intro hr
      have hr' : (s.cl c).ph = .recon := by simpa using hr
      have hg' : ¬((s.cl c).rewaitT = (s.cl c).ws ∧ (s.cl c).rsPc = none) := by simpa using hg
      apply forward_of_timer
      rw [updC_self]
      rcases fwd_rewait_noop h hr' hk hg' with h' | h'
      · exact Or.inr (Or.inl h')
      · exact Or.inr (Or.inr (Or.inl h'))
  | giveUp c =>
    simp only [step]
    split
    · exact endS_ok hs
    · exact inv_of_fr (fun d _ => hs d) (fr_updC _ _ _) (cinv_updC_key (hs c) (by simp [Client.key]))
  | dcOpen c =>
    simp only [step]
    split
    · exact adopt_ok _ hs
    · exact hs
  | dcClose c => exact begin_ok hs
  | pcFail c => exact restart_ok (fun d _ => hs d) (hs c).1.wsOwn (fun _ => (hs c).1)
  | arrive c => exact arrive_ok hs


theorem inv_init : Inv init := by
  intro c
  cases c <;>
  exact ⟨⟨fun k hk => by simp [init] at hk,
    { pair := fun _ h => by simp [init] at h, pcT := fun h => by simp [init] at h
      answer := fun _ h => by simp [init] at h, opn := fun h => by simp [init] at h
      sdpPc := fun h => by simp [init] at h, rew := fun _ h => by simp [init] at h
      retryWs := fun h => by simp [init] at h }⟩, fun h => by simp [init] at h⟩

theorem inv_reachable {s : State} (h : Reachable .rev s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step e _ he ih => exact inv_step ih e he

/-- **No dead end.** On the reviewed code, in every reachable state, a side
    that is redialing has an armed timer other than the give-up (retry,
    pairing deadline, answer timer, re-rendezvous) or a server socket that is
    not closed. Whatever the network, the server or the friend does, it is
    never left waiting on the 180 s give-up alone. -/
theorem no_dead_end {s : State} (h : Reachable .rev s) (c : Cl) (hr : (s.cl c).ph = .recon) :
    forward s c = true :=
  (inv_reachable h c).2 hr

/-- ... and so never at the prototype's dead end. -/
theorem no_dead_end' {s : State} (h : Reachable .rev s) (c : Cl) : deadEnd s c = false := by
  unfold deadEnd wayOut
  by_cases hr : (s.cl c).ph = .recon
  · simp [hr, no_dead_end h c hr]
  · simp [hr]

end WebState.LinkRedial
