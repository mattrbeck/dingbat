-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/netplay.js: armManualFallback makeSession netFail netShutdown onSigMessage rtcGaveUp sigConnect sigDialAgain sigRedial sigRendezvous sigRewait startRtc wireChannel on:click
-- @models web/signaling/server.nim: onText teardown notifyClosed normalizeId handleClient
-- @models web/signaling/server.js: attach leave closeRoom relayFrom normalizeId

/-
# Pairing two players on one code (web/netplay.js + web/signaling)

`Netplay` models one browser's link session and folds the server into "a
reply arrives". This file models the other half: two browsers, A and B,
that typed the same code, the signaling server between them, and the network
under all three. It is the machine behind "it fails on the first try, then
connects on the second or third".

Both players type one code. Whoever's `rendezvous` reaches the server first
holds the room (`waiting`); the second arrival pairs (`paired`, host = first
arrival = WebRTC offerer), the server relays the offer and answer, and each
side's DataChannel opens (`wireChannel`'s `dc.onopen`), at which point each
closes its signaling socket. Everything else here is what can go wrong in
between.

`Cfg` selects the code: `client` = netplay.js at 29172ad4 (false) or with
the fixes this model led to (true), `server` = server.nim / server.js
likewise. Each `bug_*` theorem is a trace on the code as it was; each
`regress_*` replays the same trace on the fixed code and shows it link
without anyone pressing Connect again. The fixes, by function:

* `onSigMessage` "peer-closed": with the friend's description in hand
  (`sdpIn`) it is ignored (the friend most likely linked and released the
  room); without it, `sigRewait` (here `rewait`), not "The other side left".
* `rtcGaveUp` (the 20 s deadline, or ICE `failed`): a pairing whose
  descriptions crossed is a strike, and two strikes are the NAT verdict;
  anything else is `sigRewait`.
* `sigRewait`: close the pc and the socket, rendezvous again on the same
  code (`sigDialAgain`), one step of the redial ladder.
* `sigRendezvous`: every rendezvous carries the page's id (`NET_PAGE_ID`);
  the servers' rendezvous drops a seat held by the same id (`evict`). In
  server.js every close goes through `leave`, which ignores a socket that no
  longer holds a seat.
* The manual fallback is armed for the dial (4 s) and again for the reply
  (2 s from the socket opening). The model's timers fire whenever armed, so
  this changes nothing here; it narrows the window of
  `bug_fallback_after_pairing_fails_friend` in practice.

## What is modelled

* Clients (`Client`): the phase the modal is in, `net.ws`, `net.pc`, the
  three timers (`manualFallbackTimer`, `rtcDeadline`, the redial timer), the
  redial count, `strikes` (fixed client: pairings that exchanged
  descriptions and still never opened), the error shown, and whether iOS
  has suspended the page (`susp`: no JavaScript runs, and the page's
  network stack is frozen with it, so its peer connection cannot complete).
* Sockets (`Sock`): owner, the client's readyState, whether the server holds
  it, a FIFO each way (one TCP stream each), `dead` (the connection is gone
  under both ends: the server may hold it as live until the 90 s reaper, the
  client learns by its `onclose`), and `srvClosed` (the server closed it:
  the browser delivers what was sent first, then `onclose`).
* The server's one room for the code: host socket and maybe guest socket.
  Socket ownership is the fixed client's per-page id (`rendezvous.id`).
* Peer connections (`PC`): owner, role, which pc's description it holds,
  closed, opened. A side's channel can open once both pcs hold each other's
  description, neither is closed, neither page is suspended and the path is
  not NAT-blocked (`State.nat`). Which side opens first is free.

## Abstractions

* ICE candidates are not modelled: they ride the same FIFO socket after the
  description that carries them, and `addIceCandidate` is chained after
  `setRemoteDescription` on the pc's operations chain, so none is applied
  early. A pc either connects or does not.
* An async handler between awaits is one event: `startRtc`'s
  createOffer/setLocalDescription and the guest's setRemoteDescription /
  createAnswer / setLocalDescription each run to completion here. The
  socket's messages are processed in order either way.
* The Connect click covers openNetConnect + the click handler. The
  same-browser BroadcastChannel path and the manual code exchange are
  `Netplay`'s; here `manual` is a phase the client leaves the server path
  for. Rollback setup after the channel opens is `Netplay`'s too: `linked`
  means the DataChannel is open.
* Timers fire nondeterministically while armed, with one timing assumption:
  the 20 s pairing deadline does not fire on a side whose peer's channel is
  already open on it (`peerOpenOnMe`); that side's own channel follows
  within a round trip. Slow networks are otherwise free to let any timer
  win, and the server's room TTL and rate limits are not modelled.
* A dial that fails before opening is `die` on a connecting socket.

## Results

Refuted on the code as it was (`bug_*`), every trace from a fresh start
with an open path between the players:

* `bug_linked_close_fails_both`: no fault at all. A's channel opens first,
  A closes its signaling socket (the room is released), the server tells B
  `peer-closed`, and B, whose channel is a round trip behind, takes it for
  "The other side left" and closes its pc, which drops A's channel: "Connection
  lost during setup" on A.
* `bug_paired_with_own_ghost`: A waits, the phone suspends the page and the
  socket dies without the server hearing (the reaper takes 90 s). A comes
  back, redials, and the server pairs A with its own dead seat; A waits 20 s
  for an offer from itself and says a strict NAT is in the way, while B is
  told "that code is already in use".
* `bug_frozen_host_fails_both`: A waits, the phone suspends the page with
  the socket alive. B arrives and pairs; A cannot answer while frozen, B's
  20 s deadline fires ("strict NAT"), and when A comes back it reads
  `paired` then `peer-closed`: "The other side left". The first try fails
  on both phones; the second, with both in the foreground, works.
* `bug_fallback_after_pairing_fails_friend`: the 2 s "server didn't
  respond" fallback, armed at the click, fires after B's rendezvous has
  reached the server; B leaves for the manual exchange and closes its
  socket, and A fails "The other side left".

Proved for the fixed code: the linked-close race and both suspension traces
now link with no further click (`regress_*`; the fixed client alone, on the
server still deployed, recovers from its ghost seat only if the friend comes
after its deadline: `regress_own_ghost_client_only`,
`client_only_ghost_still_in_use`); a peer that leaves before the
descriptions crossed sends the survivor back to waiting instead of an
error (`regress_fallback_after_pairing`); in a two-player world the fixed
server never answers "code in use" (`no_in_use`) and never seats one page
twice (`seats_distinct`); the fixed client never shows "The other side
left" (`no_peer_left`) and only says "strict NAT" after two pairings in a
row that exchanged descriptions and still did not open (`nat_after_two_strikes`).
-/
namespace WebState.LinkPairing

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

/-- Client → server frames. `rz` is `{"t":"rendezvous","code","id"}`, `sdp p` the
    description of pc `p` (an offer from a host pc, an answer from a guest's),
    `bye` the WebSocket close frame. -/
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
  redial    : Bool := false       -- dialed by the redial ladder / back-to-waiting, not Connect
  deriving DecidableEq, Repr

structure PC where
  owner  : Cl := .a
  role   : Role := .host
  remote : Option Nat := none     -- the pc whose description it holds
  closed : Bool := true           -- unallocated pcs count as closed
  opened : Bool := false          -- its DataChannel opened
  deriving DecidableEq, Repr

inductive Ph where
  | idle | dialing | rz | waiting | pairing | linked | failed | manual
  deriving DecidableEq, Repr

/-- What the modal says when a pairing ends badly. -/
inductive Err where
  | peerLeft   -- "The other side left"
  | lostLink   -- "Connection lost during setup"
  | inUse      -- "that code is already in use — pick another"
  | nat        -- "Could not connect peer-to-peer (a strict NAT ...)"
  | noServer   -- the manual view's "the linking server didn't respond"
  deriving DecidableEq, Repr

structure Client where
  ph       : Ph := .idle
  susp     : Bool := false
  ws       : Option Nat := none   -- net.ws
  pc       : Option Nat := none   -- net.pc
  deadline : Bool := false        -- net.rtcDeadline
  fallback : Bool := false        -- manualFallbackTimer
  redialT  : Bool := false        -- net.redialTimer
  redials  : Nat := 0             -- net.redials
  strikes  : Nat := 0             -- net.strikes (fixed client)
  err      : Option Err := none
  deriving DecidableEq, Repr

structure Room where
  host  : Nat
  guest : Option Nat
  deriving DecidableEq, Repr

structure Cfg where
  client : Bool
  server : Bool
  deriving DecidableEq, Repr

def Cfg.old : Cfg := ⟨false, false⟩
def Cfg.new : Cfg := ⟨true, true⟩
/-- The fixed web app against the server still deployed. -/
def Cfg.newClient : Cfg := ⟨true, false⟩

structure State where
  cl       : Cl → Client
  socks    : Nat → Sock
  nextSock : Nat
  pcs      : Nat → PC
  nextPc   : Nat
  room     : Option Room
  nat      : Bool                 -- no peer-to-peer path between the two networks
  cancels  : Nat                  -- ghost: Cancel / Disconnect presses

def init (nat : Bool) : State where
  cl := fun _ => {}
  socks := fun _ => {}
  nextSock := 0
  pcs := fun _ => {}
  nextPc := 0
  room := none
  nat := nat
  cancels := 0

def updC (c : Cl) (f : Client → Client) (s : State) : State :=
  { s with cl := fun d => if d = c then f (s.cl d) else s.cl d }

def updK (k : Nat) (f : Sock → Sock) (s : State) : State :=
  { s with socks := fun j => if j = k then f (s.socks j) else s.socks j }

def updP (p : Nat) (f : PC → PC) (s : State) : State :=
  { s with pcs := fun j => if j = p then f (s.pcs j) else s.pcs j }

/-! ## The server (server.nim `onText` / `teardown`; server.js `attach`) -/

/-- The server sends `m` on `k`: lost if it no longer holds `k`, the
    connection is gone, or the client has closed its end. -/
def push (k : Nat) (m : Down) (s : State) : State :=
  let x := s.socks k
  if !x.srv || x.dead || x.cst == .closed then s
  else updK k (fun y => { y with down := y.down ++ [m] }) s

/-- The server closes `k` (after an error or `peer-closed`). -/
def srvClose (k : Nat) (s : State) : State :=
  updK k (fun x => { x with srv := false, srvClosed := true }) s

/-- `teardown` (server.nim) / `ws.onclose` (server.js): the server lets go of
    `k`; a room `k` sits in dies, and the other seat is told `peer-closed`
    and closed. -/
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

/-- Second arrival: host and guest are told their roles. -/
def pair (h k : Nat) (s : State) : State :=
  push k (.paired .guest) (push h (.paired .host) { s with room := some ⟨h, some k⟩ })

/-- Fixed server: arrival `k` carries the id of seat `j`'s page, so `j` is that
    page's stale socket (it redialed). `j` is dropped without a word; the other
    seat `i`, if any, is told `peer-closed` (its pairing was with the stale
    socket) and goes back to waiting; `k` holds the room. -/
def evict (j : Nat) (i : Option Nat) (k : Nat) (s : State) : State :=
  let s := updK j (fun x => { x with srv := false }) s
  let s := match i with
    | some i => srvClose i (push i .peerClosed s)
    | none => s
  push k .waiting { s with room := some ⟨k, none⟩ }

/-- The `rendezvous` branch of `onText`. -/
def srvRz (cfg : Cfg) (k : Nat) (s : State) : State :=
  let o := (s.socks k).owner
  match s.room with
  | none => push k .waiting { s with room := some ⟨k, none⟩ }
  | some ⟨h, none⟩ =>
    if cfg.server && (s.socks h).owner == o then evict h none k s
    else pair h k s
  | some ⟨h, some g⟩ =>
    if cfg.server && (s.socks h).owner == o then evict h (some g) k s
    else if cfg.server && (s.socks g).owner == o then evict g (some h) k s
    else srvClose k (push k .inUse s)

/-- Post-pair relay: only between the room's two seats. -/
def relay (k p : Nat) (s : State) : State :=
  match s.room with
  | some ⟨h, some g⟩ =>
    if k = h then push g (.sdp p) s else if k = g then push h (.sdp p) s else s
  | _ => s

/-- The server reads `k`'s next frame. -/
def srvRecv (cfg : Cfg) (k : Nat) (s : State) : State :=
  match (s.socks k).up with
  | [] => s
  | m :: rest =>
    let s := updK k (fun x => { x with up := rest }) s
    match m with
    | .rz => srvRz cfg k s
    | .sdp p => relay k p s
    | .bye => teardown k s

/-! ## The client (web/netplay.js) -/

/-- `sigSend`: dropped unless the socket is up (a frame on a socket the server
    has let go of is never read). -/
def send (k : Nat) (m : Up) (s : State) : State :=
  updK k (fun x => if x.srv && !x.dead then { x with up := x.up ++ [m] } else x) s

/-- `sigConnect`: a fresh CONNECTING socket becomes `net.ws`. -/
def dial (c : Cl) (redial : Bool) (s : State) : State :=
  let k := s.nextSock
  let s := updK k (fun _ => { owner := c, cst := .connecting, redial := redial })
    { s with nextSock := k + 1 }
  updC c (fun x => { x with ws := some k, ph := .dialing }) s

/-- `ws.close()` on our own socket: the close frame follows whatever was sent
    before it; nothing more is delivered; our handlers ignore the `close`. -/
def closeOwn (k : Nat) (s : State) : State :=
  updK k (fun x => if x.cst = .closed then x else
    { x with cst := .closed, down := [],
             up := if x.srv && !x.dead then x.up ++ [.bye] else x.up }) s

/-- `netShutdown`'s effect on what this machine sees: pc and socket closed,
    timers cleared. -/
def shutdown (c : Cl) (s : State) : State :=
  let x := s.cl c
  let s := match x.pc with
    | some p => updP p (fun y => { y with closed := true }) s
    | none => s
  let s := match x.ws with
    | some k => closeOwn k s
    | none => s
  updC c (fun x => { x with ws := none, pc := none, deadline := false, fallback := false,
                            redialT := false }) s

/-- `netFail`: the session ends with the modal up and an error; Connect retries. -/
def fail (c : Cl) (e : Err) (s : State) : State :=
  updC c (fun x => { x with ph := .failed, err := some e }) (shutdown c s)

/-- `manualEnter(true)`: off the server path, "the linking server didn't respond". -/
def toManual (c : Cl) (s : State) : State :=
  updC c (fun x => { x with ph := .manual, err := some .noServer }) (shutdown c s)

/-- `sigRewait` (fixed client): this pairing is over but the friend may still
    come; drop the pc and the socket and rendezvous again on the same code. -/
def rewait (c : Cl) (s : State) : State :=
  -- The dial counts against the redial ladder.
  if (s.cl c).redials ≥ 3 then toManual c s
  else updC c (fun x => { x with fallback := true, redials := x.redials + 1 })
    (dial c true (shutdown c s))

/-- `sigRedial`: the socket dropped before pairing; redial at 1/2/4 s, then
    give up into the manual exchange. -/
def sigRedial (c : Cl) (s : State) : State :=
  if (s.cl c).redials ≥ 3 then toManual c s
  else updC c (fun x => { x with redials := x.redials + 1, redialT := true, fallback := false,
                                 ph := .dialing, ws := none }) s

/-- The pc's description, if it has the peer's. -/
def remoteOf (s : State) (c : Cl) : Option Nat :=
  match (s.cl c).pc with
  | some p => (s.pcs p).remote
  | none => none

/-- `onSigMessage`, one server message on c's socket `k`. -/
def onMsg (cfg : Cfg) (c : Cl) (k : Nat) (m : Down) (s : State) : State :=
  match m with
  | .waiting => updC c (fun x => { x with ph := .waiting }) s
  | .paired r =>
    -- startRtc: a new pc; the host offers at once; the deadline is armed.
    let p := s.nextPc
    let s := updP p (fun _ => { owner := c, role := r, closed := false }) { s with nextPc := p + 1 }
    let s := updC c (fun x => { x with pc := some p, deadline := true, ph := .pairing }) s
    if r = .host then send k (.sdp p) s else s
  | .sdp p =>
    match (s.cl c).pc with
    | some q =>
      let s := updP q (fun y => { y with remote := some p }) s
      if (s.pcs q).role = .guest then send k (.sdp q) s else s
    | none => s
  | .peerClosed =>
    if (s.cl c).ph == .linked then s
    else if cfg.client then
      -- Fixed: with the descriptions crossed the peer has most likely linked
      -- and released the room, so leave it to our channel (or the deadline);
      -- without them the peer left before pairing: wait for it again.
      if (remoteOf s c).isSome then s else rewait c s
    else fail c .peerLeft s
  | .inUse => fail c .inUse s

/-- Once one side's channel is open the other's follows within a round trip,
    long before a 20 s timer: the deadline is not modelled as beating it. -/
def peerOpenOnMe (s : State) (c : Cl) : Bool :=
  match (s.cl c.other).pc, (s.cl c).pc with
  | some q, some p => (s.cl c.other).ph == .linked && (s.pcs q).remote == some p
  | _, _ => false

/-- c's DataChannel can open. -/
def canOpen (s : State) (c : Cl) : Bool :=
  let x := s.cl c
  !x.susp && !(s.cl c.other).susp && !s.nat && x.ph == .pairing &&
  match x.pc with
  | some p => match (s.pcs p).remote with
    | some q => !(s.pcs p).closed && !(s.pcs q).closed && (s.pcs q).remote == some p
    | none => false
  | none => false

inductive Event where
  | click (c : Cl)        -- Connect (openNetConnect + the click handler), or a retry
  | cancel (c : Cl)       -- Cancel / ×, or Disconnect once linked: netShutdown
  | suspend (c : Cl)      -- iOS backgrounds / locks the page
  | resume (c : Cl)
  | open_ (k : Nat)       -- the server accepts; onopen + the rendezvous it sends
  | die (k : Nat)         -- fault: the connection drops (the server may not hear)
  | cclose (k : Nat)      -- the client's onerror/onclose for a dropped or server-closed socket
  | srvRecv (k : Nat)     -- the server reads k's next frame
  | srvNotice (k : Nat)   -- the server learns k is gone (FIN, or the 90 s reaper)
  | deliver (k : Nat)     -- the client reads k's next server message
  | fallback (c : Cl)     -- manualFallbackTimer
  | redial (c : Cl)       -- the redial timer
  | deadline (c : Cl)     -- rtcDeadline (20 s)
  | dcOpen (c : Cl)       -- c's DataChannel opens (dc.onopen)
  | dcClose (c : Cl)      -- c's open channel drops because the peer's pc closed
  deriving DecidableEq, Repr

def en (s : State) : Event → Bool
  | .click c => !(s.cl c).susp && ((s.cl c).ph == .idle || (s.cl c).ph == .failed)
  | .cancel c => !(s.cl c).susp && (s.cl c).ph != .idle
  | .suspend c => !(s.cl c).susp
  | .resume c => (s.cl c).susp
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
  | .fallback c =>
    let x := s.cl c
    !x.susp && x.fallback && (x.ph == .dialing || x.ph == .rz)
  | .redial c => !(s.cl c).susp && (s.cl c).redialT
  | .deadline c =>
    let x := s.cl c
    !x.susp && x.deadline && x.ph == .pairing && !peerOpenOnMe s c
  | .dcOpen c => canOpen s c
  | .dcClose c =>
    let x := s.cl c
    !x.susp && x.ph == .linked &&
      match x.pc with
      | some p => match (s.pcs p).remote with
        | some q => (s.pcs q).closed
        | none => false
      | none => false

def step (cfg : Cfg) (s : State) : Event → State
  | .click c =>
    -- A fresh session: the fallback is armed for the dial (fixed: re-armed at
    -- open for the reply; the model's timers fire whenever armed, either way).
    dial c false (updC c (fun x => { x with err := none, strikes := 0, redials := 0,
                                            fallback := true }) s)
  | .cancel c =>
    updC c (fun x => { x with ph := .idle, err := none })
      { shutdown c s with cancels := s.cancels + 1 }
  | .suspend c => updC c (fun x => { x with susp := true }) s
  | .resume c => updC c (fun x => { x with susp := false }) s
  | .open_ k =>
    let c := (s.socks k).owner
    let s := updK k (fun x => { x with cst := .opn, srv := true, up := [.rz] }) s
    updC c (fun x => { x with ph := .rz, fallback := true }) s
  | .die k => updK k (fun x => { x with dead := true, down := [], up := [] }) s
  | .cclose k =>
    let x := s.socks k
    let c := x.owner
    let s := updK k (fun y => { y with cst := .closed }) s
    if (s.cl c).ws != some k then s
    else if x.cst == .connecting then
      -- The Connect dial's failure goes to the manual exchange; a redial's
      -- failure lands back in sigRedial.
      if x.redial then sigRedial c s else toManual c s
    else if (s.cl c).ph == .linked || (s.cl c).pc.isSome then s
    else sigRedial c s
  | .srvRecv k => srvRecv cfg k s
  | .srvNotice k => teardown k (updK k (fun x => { x with up := [] }) s)
  | .deliver k =>
    let x := s.socks k
    let c := x.owner
    match x.down with
    | [] => s
    | m :: rest =>
      let s := updK k (fun y => { y with down := rest }) s
      -- Any reply is proof of life: disarm the fallback, refill the ladder.
      let s := updC c (fun y => { y with fallback := false, redials := 0 }) s
      onMsg cfg c k m s
  | .fallback c => toManual c s
  | .redial c =>
    dial c true (updC c (fun x => { x with redialT := false, fallback := cfg.client }) s)
  | .deadline c =>
    if cfg.client then
      -- Fixed: a pairing whose descriptions crossed and still never opened is
      -- a strike; two in a row is a NAT verdict. Otherwise the peer stopped
      -- answering (suspended, gone): wait for it again.
      let st := (s.cl c).strikes + (if (remoteOf s c).isSome then 1 else 0)
      let s := updC c (fun x => { x with strikes := st }) s
      if st ≥ 2 then fail c .nat s else rewait c s
    else fail c .nat s
  | .dcOpen c =>
    match (s.cl c).pc with
    | some p =>
      let s := updP p (fun y => { y with opened := true }) s
      let s := match (s.cl c).ws with
        | some k => closeOwn k s
        | none => s
      updC c (fun x => { x with ph := .linked, deadline := false, ws := none }) s
    | none => s
  | .dcClose c => fail c .lostLink s

inductive Reachable (cfg : Cfg) : State → Prop
  | init (nat : Bool) : Reachable cfg (init nat)
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

/-- The trace runs (every event enabled) from a fresh start with an open
    peer-to-peer path, and ends in a state satisfying `p`. -/
def witnesses (cfg : Cfg) (es : List Event) (p : State → Bool) : Bool :=
  match run cfg (init false) es with
  | some t => !t.nat && p t
  | none => false

theorem witness_sound {cfg : Cfg} {es : List Event} {p : State → Bool}
    (h : witnesses cfg es p = true) : ∃ s, Reachable cfg s ∧ s.nat = false ∧ p s = true := by
  unfold witnesses at h
  split at h
  · rename_i t ht
    simp only [Bool.and_eq_true, Bool.not_eq_true'] at h
    exact ⟨t, run_reachable (Reachable.init false) ht, h.1, h.2⟩
  · cases h

/-! ## The traces

Sockets and pcs are numbered in the order they are made. -/

def errOf (s : State) (c : Cl) : Option Err := (s.cl c).err

/-- Both channels open, no error on either side. -/
def bothLinked (s : State) : Bool :=
  (s.cl .a).ph == .linked && (s.cl .b).ph == .linked &&
    (s.cl .a).err == none && (s.cl .b).err == none

/-- A reaches the server first and waits; B pairs; the offer and the answer
    cross. Socket 0 is A's, 1 is B's; pc 0 is A's (host), 1 is B's. -/
def handshake : List Event :=
  [.click .a, .open_ 0, .srvRecv 0, .deliver 0,   -- A: "waiting"
   .click .b, .open_ 1, .srvRecv 1,               -- B pairs
   .deliver 0, .deliver 1,                        -- "paired": A offers
   .srvRecv 0, .deliver 1,                        -- B takes the offer, answers
   .srvRecv 1, .deliver 0]                        -- A takes the answer

/-- No fault anywhere: A's channel opens a round trip before B's, A closes its
    signaling socket, and the server's `peer-closed` reaches B first. B fails
    "The other side left" and closes its pc; A's channel drops: "Connection
    lost during setup". -/
theorem bug_linked_close_fails_both :
    witnesses .old (handshake ++ [.dcOpen .a, .srvRecv 0, .deliver 1, .dcClose .a])
      (fun s => errOf s .a == some .lostLink && errOf s .b == some .peerLeft) = true := by
  decide

/-- Fixed client: B has the offer, so `peer-closed` means A most likely linked;
    B's channel opens. Holds on the server still deployed. -/
theorem regress_linked_close :
    witnesses .newClient (handshake ++ [.dcOpen .a, .srvRecv 0, .deliver 1, .dcOpen .b])
      bothLinked = true ∧
    witnesses .new (handshake ++ [.dcOpen .a, .srvRecv 0, .deliver 1, .dcOpen .b])
      bothLinked = true := by
  decide

/-- A waits (socket 0); the phone suspends the page and the connection dies
    without the server hearing. Back in the foreground, A's `onclose` redials
    (socket 1), and the server pairs socket 1 as guest of the dead socket 0:
    A with itself. -/
def ghostPrefix : List Event :=
  [.click .a, .open_ 0, .srvRecv 0, .deliver 0,
   .suspend .a, .die 0, .resume .a, .cclose 0, .redial .a, .open_ 1, .srvRecv 1]

/-- ... B (socket 2) is told the code is in use; A's deadline blames a strict
    NAT. -/
theorem bug_paired_with_own_ghost :
    witnesses .old (ghostPrefix ++ [.deliver 1, .click .b, .open_ 2, .srvRecv 2, .deliver 2,
                                    .deadline .a])
      (fun s => errOf s .a == some .nat && errOf s .b == some .inUse) = true := by
  decide

/-- Fixed server: socket 1 carries the page id of the dead seat, which is
    dropped; A waits on socket 1 and B pairs with it. -/
theorem regress_paired_with_own_ghost :
    witnesses .new (ghostPrefix ++ [.deliver 1,
        .click .b, .open_ 2, .srvRecv 2,
        .deliver 1, .deliver 2, .srvRecv 1, .deliver 2, .srvRecv 2, .deliver 1,
        .dcOpen .a, .dcOpen .b])
      bothLinked = true := by
  decide

/-- The fixed client alone (old server) recovers when B comes after A's
    deadline: no description ever came, so A rendezvouses again rather than
    blaming the NAT. -/
theorem regress_own_ghost_client_only :
    witnesses .newClient (ghostPrefix ++ [.deliver 1, .deadline .a, .srvRecv 1,
        .open_ 2, .srvRecv 2, .deliver 2,
        .click .b, .open_ 3, .srvRecv 3,
        .deliver 2, .deliver 3, .srvRecv 2, .deliver 3, .srvRecv 3, .deliver 2,
        .dcOpen .a, .dcOpen .b])
      bothLinked = true := by
  decide

/-- ... but B arriving while A is paired with its ghost is still "in use" on
    the old server: the server half of the fix is needed for that. -/
theorem client_only_ghost_still_in_use :
    witnesses .newClient (ghostPrefix ++ [.deliver 1, .click .b, .open_ 2, .srvRecv 2,
                                          .deliver 2])
      (fun s => errOf s .b == some .inUse) = true := by
  decide

/-- A waits; the phone suspends the page with the socket alive. B pairs and
    waits for an offer A cannot make; B's deadline says "strict NAT" and B
    leaves. -/
def frozenPrefix : List Event :=
  [.click .a, .open_ 0, .srvRecv 0, .deliver 0, .suspend .a,
   .click .b, .open_ 1, .srvRecv 1, .deliver 1, .deadline .b, .srvRecv 1]

/-- ... A wakes to `paired` then `peer-closed`: "The other side left". -/
theorem bug_frozen_host_fails_both :
    witnesses .old (frozenPrefix ++ [.resume .a, .deliver 0, .deliver 0])
      (fun s => errOf s .a == some .peerLeft && errOf s .b == some .nat) = true := by
  decide

/-- Fixed client: B's deadline saw no offer, so B waits again (socket 2); A
    wakes, sees its pairing is gone before any answer, and rendezvouses again
    (socket 3), as guest of B this time. -/
def frozenRest : List Event :=
  [.open_ 2, .srvRecv 2, .deliver 2, .resume .a, .deliver 0, .deliver 0,
   .open_ 3, .srvRecv 3, .deliver 2, .deliver 3, .srvRecv 2, .deliver 3, .srvRecv 3,
   .deliver 2, .dcOpen .b, .dcOpen .a]

theorem regress_frozen_host :
    witnesses .newClient (frozenPrefix ++ frozenRest) bothLinked = true ∧
    witnesses .new (frozenPrefix ++ frozenRest) bothLinked = true := by
  decide

/-- The 2 s fallback fires on B after its rendezvous reached the server; B
    takes the manual exchange and closes its socket; A fails. -/
def fallbackPrefix : List Event :=
  [.click .a, .open_ 0, .srvRecv 0, .deliver 0,
   .click .b, .open_ 1, .srvRecv 1, .fallback .b, .deliver 0, .srvRecv 1, .deliver 0]

theorem bug_fallback_after_pairing_fails_friend :
    witnesses .old fallbackPrefix
      (fun s => errOf s .a == some .peerLeft && (s.cl .b).ph == .manual) = true := by
  decide

/-- Fixed client: A goes back to waiting on the code, with no error. -/
theorem regress_fallback_after_pairing :
    witnesses .new (fallbackPrefix ++ [.open_ 2, .srvRecv 2, .deliver 2])
      (fun s => (s.cl .a).ph == .waiting && errOf s .a == none) = true := by
  decide

/-! ## Invariants -/

section proj
variable (s : State) (c d : Cl) (k j p : Nat) (f : Client → Client) (g : Sock → Sock)
  (h : PC → PC) (m : Down) (u : Up)

@[simp] theorem updC_cl : (updC c f s).cl d = if d = c then f (s.cl d) else s.cl d := rfl
@[simp] theorem updC_socks : (updC c f s).socks = s.socks := rfl
@[simp] theorem updC_pcs : (updC c f s).pcs = s.pcs := rfl
@[simp] theorem updC_room : (updC c f s).room = s.room := rfl
@[simp] theorem updC_nextSock : (updC c f s).nextSock = s.nextSock := rfl
@[simp] theorem updC_nextPc : (updC c f s).nextPc = s.nextPc := rfl
@[simp] theorem updC_cancels : (updC c f s).cancels = s.cancels := rfl
@[simp] theorem updK_cl : (updK k g s).cl = s.cl := rfl
@[simp] theorem updK_socks : (updK k g s).socks j = if j = k then g (s.socks j) else s.socks j := rfl
@[simp] theorem updK_pcs : (updK k g s).pcs = s.pcs := rfl
@[simp] theorem updK_room : (updK k g s).room = s.room := rfl
@[simp] theorem updK_nextSock : (updK k g s).nextSock = s.nextSock := rfl
@[simp] theorem updK_nextPc : (updK k g s).nextPc = s.nextPc := rfl
@[simp] theorem updK_cancels : (updK k g s).cancels = s.cancels := rfl
@[simp] theorem updP_cl : (updP p h s).cl = s.cl := rfl
@[simp] theorem updP_socks : (updP p h s).socks = s.socks := rfl
@[simp] theorem updP_room : (updP p h s).room = s.room := rfl
@[simp] theorem updP_nextSock : (updP p h s).nextSock = s.nextSock := rfl
@[simp] theorem updP_cancels : (updP p h s).cancels = s.cancels := rfl

theorem push_cl : (push k m s).cl = s.cl := by unfold push; dsimp only; split <;> rfl
theorem push_room : (push k m s).room = s.room := by unfold push; dsimp only; split <;> rfl
theorem push_nextSock : (push k m s).nextSock = s.nextSock := by unfold push; dsimp only; split <;> rfl
theorem push_pcs : (push k m s).pcs = s.pcs := by unfold push; dsimp only; split <;> rfl
theorem push_owner : ((push k m s).socks j).owner = (s.socks j).owner := by
  unfold push; dsimp only; split <;> simp; split <;> rfl
theorem srvClose_cl : (srvClose k s).cl = s.cl := rfl
theorem send_cl : (send k u s).cl = s.cl := rfl

theorem teardown_cl : (teardown k s).cl = s.cl := by
  unfold teardown; simp only []; split
  · split
    · split <;> simp [srvClose, push_cl]
    · split <;> simp [srvClose, push_cl]
  · rfl
theorem evict_cl (i : Option Nat) : (evict j i k s).cl = s.cl := by
  unfold evict; cases i <;> simp [srvClose, push_cl]
theorem pair_cl : (pair j k s).cl = s.cl := by simp [pair, push_cl]
theorem srvRz_cl (cfg : Cfg) : (srvRz cfg k s).cl = s.cl := by
  unfold srvRz; simp only []
  split
  · simp [push_cl]
  · split <;> simp [evict_cl, pair_cl]
  · split
    · simp [evict_cl]
    · split <;> simp [evict_cl, srvClose, push_cl]
theorem relay_cl : (relay k p s).cl = s.cl := by
  unfold relay; split
  · split
    · simp [push_cl]
    · split <;> simp [push_cl]
  · rfl
theorem srvRecv_cl (cfg : Cfg) : (srvRecv cfg k s).cl = s.cl := by
  unfold srvRecv; split
  · rfl
  · split <;> simp [srvRz_cl, relay_cl, teardown_cl]

theorem closeOwn_cl : (closeOwn k s).cl = s.cl := rfl

/-- What a client-side helper leaves of each client's error and strikes. -/
theorem shutdown_err : ((shutdown c s).cl d).err = (s.cl d).err := by
  unfold shutdown; simp only []; split <;> split <;> simp [closeOwn] <;> split <;> rfl
theorem shutdown_strikes : ((shutdown c s).cl d).strikes = (s.cl d).strikes := by
  unfold shutdown; simp only []; split <;> split <;> simp [closeOwn] <;> split <;> rfl
theorem dial_err (r : Bool) : ((dial c r s).cl d).err = (s.cl d).err := by
  unfold dial; simp; split <;> rfl
theorem dial_strikes (r : Bool) : ((dial c r s).cl d).strikes = (s.cl d).strikes := by
  unfold dial; simp; split <;> rfl
theorem rewait_strikes : ((rewait c s).cl d).strikes = (s.cl d).strikes := by
  unfold rewait; split
  · unfold toManual; simp only [updC_cl]; split <;> simp [shutdown_strikes]
  · simp only [updC_cl]; split <;> simp [dial_strikes, shutdown_strikes]

theorem fail_err (e : Err) : ((fail c e s).cl d).err = if d = c then some e else (s.cl d).err := by
  unfold fail; simp only [updC_cl]; split <;> simp [shutdown_err]
theorem fail_strikes (e : Err) : ((fail c e s).cl d).strikes = (s.cl d).strikes := by
  unfold fail; simp only [updC_cl]; split <;> simp [shutdown_strikes]
theorem toManual_err : ((toManual c s).cl d).err = if d = c then some .noServer else (s.cl d).err := by
  unfold toManual; simp only [updC_cl]; split <;> simp [shutdown_err]
theorem toManual_strikes : ((toManual c s).cl d).strikes = (s.cl d).strikes := by
  unfold toManual; simp only [updC_cl]; split <;> simp [shutdown_strikes]
theorem rewait_err :
    ((rewait c s).cl d).err = (s.cl d).err ∨ ((rewait c s).cl d).err = some .noServer := by
  unfold rewait; split
  · rw [toManual_err]; split
    · right; rfl
    · left; rfl
  · left; simp only [updC_cl]; split <;> simp [dial_err, shutdown_err]
theorem sigRedial_err :
    ((sigRedial c s).cl d).err = (if d = c then some .noServer else (s.cl d).err) ∨
    ((sigRedial c s).cl d).err = (s.cl d).err := by
  unfold sigRedial; split
  · exact Or.inl (toManual_err ..)
  · right; simp only [updC_cl]; split <;> simp_all
theorem sigRedial_strikes : ((sigRedial c s).cl d).strikes = (s.cl d).strikes := by
  unfold sigRedial; split
  · exact toManual_strikes ..
  · simp only [updC_cl]; split <;> simp_all

end proj

/-- The errors a client can be left showing, as a predicate preserved by every
    step (`P` closed under the errors that step can set). -/
def ErrsIn (P : Option Err → Prop) (s : State) : Prop := ∀ d, P (s.cl d).err

theorem onMsg_err (cfg : Cfg) (c : Cl) (k : Nat) (m : Down) (s : State) (d : Cl) :
    ((onMsg cfg c k m s).cl d).err = (s.cl d).err ∨
    (d = c ∧ m = .inUse ∧ ((onMsg cfg c k m s).cl d).err = some .inUse) ∨
    (d = c ∧ cfg.client = false ∧ ((onMsg cfg c k m s).cl d).err = some .peerLeft) ∨
    ((onMsg cfg c k m s).cl d).err = some .noServer := by
  unfold onMsg
  cases m with
  | waiting => left; simp only [updC_cl]; split <;> simp_all
  | paired r =>
    left; simp only []
    split <;> simp [send_cl] <;> split <;> simp_all
  | sdp p =>
    left; simp only []
    split
    · split <;> simp [send_cl]
    · rfl
  | peerClosed =>
    simp only []
    split
    · left; rfl
    · split
      · split
        · left; rfl
        · rcases rewait_err (c := c) (d := d) (s := s) with h | h
          · left; exact h
          · right; right; right; exact h
      · rw [fail_err]; split
        · right; right; left; subst_vars; simp_all
        · left; rfl
  | inUse =>
    rw [fail_err]; split
    · right; left; simp_all
    · left; rfl

/-- Every step leaves each client's error as it was, or sets it to one this
    event can produce. -/
theorem step_err (cfg : Cfg) (s : State) (e : Event) (d : Cl) :
    ((step cfg s e).cl d).err = (s.cl d).err ∨
    ((step cfg s e).cl d).err = none ∨
    (∃ k, e = .deliver k ∧ Down.inUse ∈ (s.socks k).down ∧
      ((step cfg s e).cl d).err = some .inUse) ∨
    ((step cfg s e).cl d).err = some .noServer ∨
    ((step cfg s e).cl d).err = some .lostLink ∨
    ((step cfg s e).cl d).err = some .nat ∨
    (cfg.client = false ∧ ((step cfg s e).cl d).err = some .peerLeft) := by
  cases e with
  | click c =>
    rw [step, dial_err]; simp only [updC_cl]; split <;> simp
  | cancel c =>
    simp only [step, updC_cl]; split
    · simp
    · left; exact shutdown_err ..
  | suspend c => simp only [step, updC_cl]; split <;> simp
  | resume c => simp only [step, updC_cl]; split <;> simp
  | open_ k => simp only [step, updC_cl, updK_cl]; split <;> simp
  | die k => simp [step]
  | cclose k =>
    simp only [step]
    split
    · left; rfl
    · split
      · split
        · rcases sigRedial_err (c := (s.socks k).owner) (d := d)
            (s := updK k (fun y => { y with cst := .closed }) s) with h | h <;>
            rw [h] <;> (try split) <;> simp
        · rw [toManual_err]; split <;> simp
      · split
        · left; rfl
        · rcases sigRedial_err (c := (s.socks k).owner) (d := d)
            (s := updK k (fun y => { y with cst := .closed }) s) with h | h <;>
            rw [h] <;> (try split) <;> simp
  | srvRecv k => left; simp [step, srvRecv_cl]
  | srvNotice k => left; simp [step, teardown_cl]
  | deliver k =>
    simp only [step]
    split
    · left; rfl
    · rename_i m rest hdown
      rcases onMsg_err cfg (s.socks k).owner k m (updC (s.socks k).owner
          (fun y => { y with fallback := false, redials := 0 })
          (updK k (fun y => { y with down := rest }) s)) d with h | ⟨_, hm, h⟩ | ⟨_, hc, h⟩ | h
      · left; rw [h]; simp only [updC_cl, updK_cl]; split <;> rfl
      · right; right; left; subst hm; exact ⟨k, rfl, by simp [hdown], h⟩
      · right; right; right; right; right; right; exact ⟨hc, h⟩
      · right; right; right; left; exact h
  | fallback c => simp only [step]; rw [toManual_err]; split <;> simp
  | redial c => rw [step, dial_err]; simp only [updC_cl]; split <;> simp
  | deadline c =>
    simp only [step]
    repeat' split
    all_goals first
      | (rw [fail_err]; split <;> simp_all)
      | (rcases rewait_err (c := c) (d := d) (s := updC c (fun x => { x with strikes := _ }) s)
            with h | h
         · left; rw [h]; simp only [updC_cl]; split <;> simp_all
         · right; right; right; left; exact h)
  | dcOpen c =>
    left; simp only [step]
    split
    · simp only [updC_cl]; split
      · split <;> simp [closeOwn_cl] <;> simp_all
      · split <;> simp [closeOwn_cl]
    · rfl
  | dcClose c => simp only [step]; rw [fail_err]; split <;> simp

/-- The fixed client never says "The other side left": a peer that goes away
    before the channel opens sends it back to waiting, or leaves it to its own
    channel once the descriptions have crossed. -/
theorem no_peer_left {cfg : Cfg} (hc : cfg.client = true) {s : State} (h : Reachable cfg s)
    (d : Cl) : (s.cl d).err ≠ some .peerLeft := by
  induction h generalizing d with
  | init nat => simp [init]
  | @step s e _ _ ih =>
    rcases step_err cfg s e d with h | h | ⟨_, _, _, h⟩ | h | h | h | ⟨h1, _⟩ <;> simp_all

theorem onMsg_strikes (cfg : Cfg) (c : Cl) (k : Nat) (m : Down) (s : State) (d : Cl) :
    ((onMsg cfg c k m s).cl d).strikes = (s.cl d).strikes := by
  unfold onMsg
  cases m with
  | waiting => simp only [updC_cl]; split <;> simp_all
  | paired r => simp only []; split <;> simp [send_cl] <;> split <;> simp_all
  | sdp p => simp only []; split
             · split <;> simp [send_cl]
             · rfl
  | peerClosed =>
    simp only []
    repeat' split
    all_goals first | rfl | exact rewait_strikes .. | exact fail_strikes ..
  | inUse => exact fail_strikes ..

theorem rewait_nat {s : State} {c d : Cl}
    (h : (s.cl d).err = some .nat → (s.cl d).strikes ≥ 2) :
    ((rewait c s).cl d).err = some .nat → ((rewait c s).cl d).strikes ≥ 2 := by
  rw [rewait_strikes]
  rcases rewait_err (c := c) (d := d) (s := s) with h' | h' <;> rw [h'] <;> simp_all

/-- The fixed client's NAT verdict: each client's strikes only grow between
    Connects, and "strict NAT" is only shown at two. -/
def NatOK (s : State) : Prop := ∀ d, (s.cl d).err = some .nat → (s.cl d).strikes ≥ 2

theorem natOK_step {cfg : Cfg} (hc : cfg.client = true) {s : State} (h : NatOK s) (e : Event) :
    NatOK (step cfg s e) := by
  intro d
  unfold NatOK at h
  cases e with
  | click c => rw [step, dial_err, dial_strikes]; simp only [updC_cl]; split <;> simp_all
  | cancel c =>
    simp only [step, updC_cl]; split
    · simp
    · rw [shutdown_err, shutdown_strikes]; exact h d
  | suspend c => simp only [step, updC_cl]; split <;> simp_all
  | resume c => simp only [step, updC_cl]; split <;> simp_all
  | open_ k => simp only [step, updC_cl, updK_cl]; split <;> simp_all
  | die k => simpa [step] using h d
  | cclose k =>
    simp only [step]
    repeat' split
    all_goals first
      | exact h d
      | (rw [toManual_err, toManual_strikes]; split <;> simp_all)
      | (rcases sigRedial_err (c := (s.socks k).owner) (d := d)
            (s := updK k (fun y => { y with cst := .closed }) s) with h' | h' <;>
          rw [h', sigRedial_strikes] <;> (try split) <;> simp_all)
  | srvRecv k => simpa [step, srvRecv_cl] using h d
  | srvNotice k => simpa [step, teardown_cl] using h d
  | deliver k =>
    simp only [step]
    split
    · exact h d
    · rename_i m rest hdown
      rw [onMsg_strikes]
      rcases onMsg_err cfg (s.socks k).owner k m (updC (s.socks k).owner
          (fun y => { y with fallback := false, redials := 0 })
          (updK k (fun y => { y with down := rest }) s)) d with h' | ⟨_, _, h'⟩ | ⟨_, hc', _⟩ | h'
      · rw [h']; simp only [updC_cl, updK_cl]; split <;> simp_all
      · simp [h']
      · simp_all
      · simp [h']
  | fallback c => simp only [step]; rw [toManual_err, toManual_strikes]; split <;> simp_all
  | redial c => rw [step, dial_err, dial_strikes]; simp only [updC_cl]; split <;> simp_all
  | deadline c =>
    have hcc := h c
    simp only [step, hc]
    repeat' split
    all_goals first
      | (rw [fail_err, fail_strikes]; split <;> simp_all)
      | (apply rewait_nat
         simp only [updC_cl]
         split <;> (try subst_vars) <;> (intro he; have := h _ he; simp_all; try omega))
  | dcOpen c =>
    simp only [step]
    split
    · simp only [updC_cl]; split
      · split <;> simp [closeOwn_cl] <;> simp_all
      · split <;> simp [closeOwn_cl] <;> exact h d
    · exact h d
  | dcClose c => simp only [step]; rw [fail_err, fail_strikes]; split <;> simp_all

theorem nat_after_two_strikes {cfg : Cfg} (hc : cfg.client = true) {s : State}
    (h : Reachable cfg s) : NatOK s := by
  induction h with
  | init nat => intro d; simp [init]
  | step e _ _ ih => exact natOK_step hc ih e

/-! ### The fixed server never seats a page twice, nor says "in use" to two players

`Mono s t`: what a step may do to the sockets without the server's rendezvous
logic: allocate fresh ones, close, drain, append anything but `inUse`. -/

structure Mono (s t : State) : Prop where
  ns  : s.nextSock ≤ t.nextSock
  own : ∀ j, j < s.nextSock → (t.socks j).owner = (s.socks j).owner
  cst : ∀ j, (t.socks j).cst ≠ .closed →
    (s.socks j).cst ≠ .closed ∨ (s.nextSock ≤ j ∧ j < t.nextSock)
  srv : ∀ j, (t.socks j).srv = true →
    (s.socks j).srv = true ∨ (s.socks j).cst ≠ .closed ∨ (s.nextSock ≤ j ∧ j < t.nextSock)
  dn  : ∀ j, Down.inUse ∈ (t.socks j).down → Down.inUse ∈ (s.socks j).down

theorem Mono.refl (s : State) : Mono s s :=
  ⟨Nat.le_refl _, fun _ _ => rfl, fun _ h => Or.inl h, fun _ h => Or.inl h, fun _ h => h⟩

theorem Mono.trans {s t u : State} (a : Mono s t) (b : Mono t u) : Mono s u where
  ns := Nat.le_trans a.ns b.ns
  own j hj := by rw [b.own j (Nat.lt_of_lt_of_le hj a.ns), a.own j hj]
  cst j hj := by
    rcases b.cst j hj with h | ⟨h1, h2⟩
    · rcases a.cst j h with h' | ⟨h1', h2'⟩
      · exact Or.inl h'
      · exact Or.inr ⟨h1', Nat.lt_of_lt_of_le h2' b.ns⟩
    · exact Or.inr ⟨Nat.le_trans a.ns h1, h2⟩
  srv j hj := by
    rcases b.srv j hj with h | h | ⟨h1, h2⟩
    · rcases a.srv j h with h' | h' | ⟨h1', h2'⟩
      · exact Or.inl h'
      · exact Or.inr (Or.inl h')
      · exact Or.inr (Or.inr ⟨h1', Nat.lt_of_lt_of_le h2' b.ns⟩)
    · rcases a.cst j h with h' | ⟨h1', h2'⟩
      · exact Or.inr (Or.inl h')
      · exact Or.inr (Or.inr ⟨h1', Nat.lt_of_lt_of_le h2' b.ns⟩)
    · exact Or.inr (Or.inr ⟨Nat.le_trans a.ns h1, h2⟩)
  dn j hj := a.dn j (b.dn j hj)

/-- A socket rewrite that keeps the owner, opens nothing, starts nothing on
    the server and appends no `inUse`. -/
def SockP (x y : Sock) : Prop :=
  y.owner = x.owner ∧ (y.cst ≠ .closed → x.cst ≠ .closed) ∧
    (y.srv = true → x.srv = true ∨ x.cst ≠ .closed) ∧
    (Down.inUse ∈ y.down → Down.inUse ∈ x.down)

def SockOK (g : Sock → Sock) : Prop := ∀ x, SockP x (g x)

theorem mono_updK' {s : State} (k : Nat) {g : Sock → Sock}
    (hg : SockP (s.socks k) (g (s.socks k))) : Mono s (updK k g s) where
  ns := Nat.le_refl _
  own j _ := by simp only [updK_socks]; split <;> simp_all [hg.1]
  cst j h := by
    left; simp only [updK_socks] at h; split at h
    · subst_vars; exact hg.2.1 h
    · exact h
  srv j h := by
    simp only [updK_socks] at h; split at h
    · subst_vars; rcases hg.2.2.1 h with h' | h'
      · exact Or.inl h'
      · exact Or.inr (Or.inl h')
    · exact Or.inl h
  dn j h := by
    simp only [updK_socks] at h; split at h
    · subst_vars; exact hg.2.2.2 h
    · exact h

theorem mono_updK {s : State} (k : Nat) {g : Sock → Sock} (hg : SockOK g) : Mono s (updK k g s) :=
  mono_updK' k (hg _)

theorem mono_updC {s : State} (c : Cl) (f : Client → Client) : Mono s (updC c f s) :=
  ⟨Nat.le_refl _, fun _ _ => rfl, fun _ h => Or.inl h, fun _ h => Or.inl h, fun _ h => h⟩
theorem mono_updP {s : State} (p : Nat) (f : PC → PC) : Mono s (updP p f s) :=
  ⟨Nat.le_refl _, fun _ _ => rfl, fun _ h => Or.inl h, fun _ h => Or.inl h, fun _ h => h⟩

theorem mono_push {s : State} (k : Nat) {m : Down} (hm : m ≠ .inUse) : Mono s (push k m s) := by
  unfold push; dsimp only; split
  · exact Mono.refl s
  · apply mono_updK
    intro x; refine ⟨rfl, id, Or.inl, ?_⟩
    intro h; simp only [List.mem_append, List.mem_singleton] at h; rcases h with h | h
    · exact h
    · exact absurd h.symm hm

theorem mono_srvClose {s : State} (k : Nat) : Mono s (srvClose k s) :=
  mono_updK k (fun x => ⟨rfl, id, by simp, id⟩)
theorem mono_send {s : State} (k : Nat) (u : Up) : Mono s (send k u s) :=
  mono_updK k (fun x => by
    split
    · exact ⟨rfl, id, Or.inl, id⟩
    · exact ⟨rfl, id, Or.inl, id⟩)
theorem mono_closeOwn {s : State} (k : Nat) : Mono s (closeOwn k s) :=
  mono_updK k (fun x => by
    split
    · exact ⟨rfl, id, Or.inl, id⟩
    · exact ⟨rfl, fun h => absurd rfl h, Or.inl, fun h => by simp at h⟩)
theorem mono_dial {s : State} (c : Cl) (r : Bool) : Mono s (dial c r s) where
  ns := by simp [dial]
  own j hj := by
    simp only [dial, updC_socks, updK_socks]; rw [ite_eq_right_iff.mpr (fun h => absurd h (by omega))]
  cst j h := by
    simp [dial] at h ⊢; by_cases hj : j = s.nextSock
    · right; omega
    · left; simp [hj] at h; exact h
  srv j h := by
    simp [dial] at h ⊢; by_cases hj : j = s.nextSock
    · simp [hj] at h
    · simp [hj] at h; exact Or.inl h
  dn j h := by
    simp [dial] at h; by_cases hj : j = s.nextSock
    · simp [hj] at h
    · simp [hj] at h; exact h

theorem mono_shutdown {s : State} (c : Cl) : Mono s (shutdown c s) := by
  unfold shutdown; dsimp only
  split <;> split
  all_goals first
    | exact Mono.trans (Mono.trans (mono_updP _ _) (mono_closeOwn _)) (mono_updC _ _)
    | exact Mono.trans (mono_updP _ _) (mono_updC _ _)
    | exact Mono.trans (mono_closeOwn _) (mono_updC _ _)
    | exact mono_updC _ _
theorem mono_fail {s : State} (c : Cl) (e : Err) : Mono s (fail c e s) :=
  Mono.trans (mono_shutdown c) (mono_updC _ _)
theorem mono_toManual {s : State} (c : Cl) : Mono s (toManual c s) :=
  Mono.trans (mono_shutdown c) (mono_updC _ _)
theorem mono_rewait {s : State} (c : Cl) : Mono s (rewait c s) := by
  unfold rewait; split
  · exact mono_toManual c
  · exact Mono.trans (Mono.trans (mono_shutdown c) (mono_dial c true)) (mono_updC _ _)
theorem mono_sigRedial {s : State} (c : Cl) : Mono s (sigRedial c s) := by
  unfold sigRedial; split
  · exact mono_toManual c
  · exact mono_updC _ _

theorem mono_onMsg {s : State} (cfg : Cfg) (c : Cl) (k : Nat) (m : Down) :
    Mono s (onMsg cfg c k m s) := by
  unfold onMsg
  cases m with
  | waiting => exact mono_updC _ _
  | paired r =>
    dsimp only
    have h0 : Mono s (updC c (fun x => { x with pc := some s.nextPc, deadline := true, ph := .pairing })
        (updP s.nextPc (fun _ => { owner := c, role := r, closed := false })
          { s with nextPc := s.nextPc + 1 })) :=
      ⟨Nat.le_refl _, fun _ _ => rfl, fun _ h => Or.inl h, fun _ h => Or.inl h, fun _ h => h⟩
    split
    · exact Mono.trans h0 (mono_send _ _)
    · exact h0
  | sdp p =>
    dsimp only; split
    · split
      · exact Mono.trans (mono_updP _ _) (mono_send _ _)
      · exact mono_updP _ _
    · exact Mono.refl s
  | peerClosed =>
    dsimp only
    repeat' split
    all_goals first | exact Mono.refl s | exact mono_rewait c | exact mono_fail c _
  | inUse => exact mono_fail c _

/-- Client-side helpers never touch the room. -/
theorem shutdown_room (s : State) (c : Cl) : (shutdown c s).room = s.room := by
  unfold shutdown; dsimp only; split <;> split <;> rfl
theorem dial_room (s : State) (c : Cl) (r : Bool) : (dial c r s).room = s.room := rfl
theorem fail_room (s : State) (c : Cl) (e : Err) : (fail c e s).room = s.room := by
  simp [fail, shutdown_room]
theorem toManual_room (s : State) (c : Cl) : (toManual c s).room = s.room := by
  simp [toManual, shutdown_room]
theorem rewait_room (s : State) (c : Cl) : (rewait c s).room = s.room := by
  unfold rewait; split
  · exact toManual_room s c
  · simp [dial_room, shutdown_room]
theorem sigRedial_room (s : State) (c : Cl) : (sigRedial c s).room = s.room := by
  unfold sigRedial; split
  · exact toManual_room s c
  · rfl
theorem send_room (s : State) (k : Nat) (u : Up) : (send k u s).room = s.room := rfl
theorem closeOwn_room (s : State) (k : Nat) : (closeOwn k s).room = s.room := rfl
theorem onMsg_room (cfg : Cfg) (c : Cl) (k : Nat) (m : Down) (s : State) :
    (onMsg cfg c k m s).room = s.room := by
  unfold onMsg
  cases m with
  | waiting => rfl
  | paired r => dsimp only; split <;> rfl
  | sdp p => dsimp only; split
             · split <;> rfl
             · rfl
  | peerClosed =>
    dsimp only
    repeat' split
    all_goals first | rfl | exact rewait_room s c | exact fail_room s c _
  | inUse => exact fail_room s c _

/-- What the server keeps true: sockets in use are allocated, room seats
    are distinct pages, and nobody is (or will be) told "in use". -/
structure SInv (s : State) : Prop where
  b1 : ∀ k, (s.socks k).cst ≠ .closed → k < s.nextSock
  b2 : ∀ k, (s.socks k).srv = true → k < s.nextSock
  seats : ∀ r, s.room = some r → r.host < s.nextSock ∧ ∀ g, r.guest = some g → g < s.nextSock
  owners : ∀ h g, s.room = some ⟨h, some g⟩ → (s.socks h).owner ≠ (s.socks g).owner
  noInUse : ∀ k, Down.inUse ∉ (s.socks k).down
  errs : ∀ d, (s.cl d).err ≠ some .inUse

theorem sinv_init (nat : Bool) : SInv (init nat) where
  b1 k h := by simp [init] at h
  b2 k h := by simp [init] at h
  seats r h := by simp [init] at h
  owners h g hr := by simp [init] at hr
  noInUse k := by simp [init]
  errs d := by simp [init]

/-- Sockets and room bookkeeping carried over a `Mono` step, given the new
    room is sound. -/
theorem sinv_mono {s t : State} (h : SInv s) (m : Mono s t)
    (hseats : ∀ r, t.room = some r → r.host < s.nextSock ∧ ∀ g, r.guest = some g → g < s.nextSock)
    (howners : ∀ hh g, t.room = some ⟨hh, some g⟩ → (s.socks hh).owner ≠ (s.socks g).owner)
    (herr : ∀ d, (t.cl d).err ≠ some .inUse) : SInv t where
  b1 k hk := by
    rcases m.cst k hk with h' | ⟨_, h2⟩
    · exact Nat.lt_of_lt_of_le (h.b1 k h') m.ns
    · exact h2
  b2 k hk := by
    rcases m.srv k hk with h' | h' | ⟨_, h2⟩
    · exact Nat.lt_of_lt_of_le (h.b2 k h') m.ns
    · exact Nat.lt_of_lt_of_le (h.b1 k h') m.ns
    · exact h2
  seats r hr := by
    obtain ⟨h1, h2⟩ := hseats r hr
    exact ⟨Nat.lt_of_lt_of_le h1 m.ns, fun g hg => Nat.lt_of_lt_of_le (h2 g hg) m.ns⟩
  owners hh g hr := by
    obtain ⟨h1, h2⟩ := hseats _ hr
    rw [m.own hh h1, m.own g (h2 g rfl)]
    exact howners hh g hr
  noInUse k hk := h.noInUse k (m.dn k hk)
  errs := herr

theorem Cl.three (x y z : Cl) (h1 : x ≠ y) (h2 : z ≠ x) (h3 : z ≠ y) : False := by
  cases x <;> cases y <;> cases z <;> simp_all

/-- Room changes leave the other socket fields to `Mono`. -/
theorem mono_room {s : State} (r : Option Room) : Mono s { s with room := r } :=
  ⟨Nat.le_refl _, fun _ _ => rfl, fun _ h => Or.inl h, fun _ h => Or.inl h, fun _ h => h⟩

/-- A step that leaves the room alone keeps `SInv`. -/
theorem sinv_same_room {s t : State} (h : SInv s) (m : Mono s t) (hr : t.room = s.room)
    (herr : ∀ d, (t.cl d).err ≠ some .inUse) : SInv t :=
  sinv_mono h m (fun r hr' => h.seats r (hr ▸ hr')) (fun hh g hr' => h.owners hh g (hr ▸ hr')) herr

theorem mono_srvOff {s : State} (k : Nat) : Mono s (updK k (fun x => { x with srv := false }) s) :=
  mono_updK k (fun x => ⟨rfl, id, by simp, id⟩)

theorem mono_teardown {s : State} (k : Nat) : Mono s (teardown k s) := by
  unfold teardown; dsimp only
  have h0 := mono_srvOff (s := s) k
  split
  · split
    · split
      · exact Mono.trans h0 (Mono.trans (Mono.trans (mono_room _) (mono_push _ (by simp)))
          (mono_srvClose _))
      · exact Mono.trans h0 (mono_room _)
    · split
      · exact Mono.trans h0 (Mono.trans (Mono.trans (mono_room _) (mono_push _ (by simp)))
          (mono_srvClose _))
      · exact h0
  · exact h0

theorem teardown_room (s : State) (k : Nat) :
    (teardown k s).room = none ∨ (teardown k s).room = s.room := by
  unfold teardown; dsimp only
  split
  · split
    · split
      · left; simp [srvClose, push_room]
      · left; rfl
    · split
      · left; simp [srvClose, push_room]
      · right; simp_all
  · right; simp_all

theorem sinv_teardown {s : State} (h : SInv s) (k : Nat) : SInv (teardown k s) := by
  rcases teardown_room s k with hr | hr
  · exact sinv_mono h (mono_teardown k) (by simp [hr]) (by simp [hr])
      (by simp [teardown_cl, h.errs])
  · exact sinv_same_room h (mono_teardown k) hr (by simp [teardown_cl, h.errs])

theorem sinv_relay {s : State} (h : SInv s) (k p : Nat) : SInv (relay k p s) := by
  have hm : Mono s (relay k p s) := by
    unfold relay; split
    · split
      · exact mono_push _ (by simp)
      · split
        · exact mono_push _ (by simp)
        · exact Mono.refl s
    · exact Mono.refl s
  have hr : (relay k p s).room = s.room := by
    unfold relay; split
    · split
      · exact push_room ..
      · split
        · exact push_room ..
        · rfl
    · rfl
  exact sinv_same_room h hm hr (by simp [relay_cl, h.errs])

/-- `evict` leaves only the arrival `k` in the room. -/
theorem sinv_evict {s : State} (h : SInv s) (j : Nat) (i : Option Nat) (k : Nat)
    (hk : k < s.nextSock) : SInv (evict j i k s) := by
  have hm : Mono s (evict j i k s) := by
    unfold evict; dsimp only
    have h0 := mono_srvOff (s := s) j
    cases i with
    | none => exact Mono.trans h0 (Mono.trans (mono_room _) (mono_push _ (by simp)))
    | some i =>
      exact Mono.trans h0 (Mono.trans (Mono.trans (mono_push i (by simp)) (mono_srvClose i))
        (Mono.trans (mono_room _) (mono_push _ (by simp))))
  have hr : (evict j i k s).room = some ⟨k, none⟩ := by
    unfold evict; cases i <;> simp [push_room, srvClose]
  refine sinv_mono h hm ?_ ?_ (by simp [evict_cl, h.errs])
  · intro r hr'; rw [hr] at hr'; cases hr'; exact ⟨hk, by simp⟩
  · intro hh g hr'; rw [hr] at hr'; cases hr'

/-- The fixed server's rendezvous: the arrival waits alone, takes back its
    own page's stale seat, or pairs with a different page. "In use" cannot
    happen with two pages. -/
theorem sinv_srvRz {cfg : Cfg} (hs : cfg.server = true) {s : State} (h : SInv s) (k : Nat)
    (hk : k < s.nextSock) : SInv (srvRz cfg k s) := by
  unfold srvRz; dsimp only
  split
  · -- an empty room: k waits alone
    refine sinv_mono h (Mono.trans (mono_room _) (mono_push _ (by simp))) ?_ ?_
      (by simp [push_cl, h.errs])
    · intro r hr; rw [push_room] at hr; cases hr; exact ⟨hk, by simp⟩
    · intro hh g hr; rw [push_room] at hr; cases hr
  · rename_i hh hroom
    split
    · exact sinv_evict h _ _ _ hk
    · rename_i hne
      simp [hs] at hne
      have hho := (h.seats _ hroom).1
      refine sinv_mono h ?_ ?_ ?_ (by simp [pair_cl, h.errs])
      · unfold pair
        exact Mono.trans (Mono.trans (mono_room _) (mono_push _ (by simp)))
          (mono_push _ (by simp))
      · intro r hr; simp [pair, push_room] at hr; subst hr; exact ⟨hho, by simp [hk]⟩
      · intro a g hr; simp [pair, push_room] at hr; obtain ⟨rfl, rfl⟩ := hr; exact hne
  · rename_i hh gg hroom
    split
    · exact sinv_evict h _ _ _ hk
    · split
      · exact sinv_evict h _ _ _ hk
      · rename_i h1 h2
        simp [hs] at h1 h2
        exact (Cl.three _ _ _ (h.owners hh gg hroom) (Ne.symm h1) (Ne.symm h2)).elim

theorem sinv_srvRecv {cfg : Cfg} (hs : cfg.server = true) {s : State} (h : SInv s) (k : Nat)
    (hk : (s.socks k).srv = true) : SInv (srvRecv cfg k s) := by
  unfold srvRecv
  split
  · exact h
  · rename_i m rest hup
    have h' : SInv (updK k (fun x => { x with up := rest }) s) :=
      sinv_same_room h (mono_updK k (fun x => ⟨rfl, id, Or.inl, id⟩)) rfl (by simp [h.errs])
    cases m with
    | rz => exact sinv_srvRz hs h' k (h.b2 k hk)
    | sdp p => exact sinv_relay h' k p
    | bye => exact sinv_teardown h' k

/-- No step says "in use" unless a socket carried it there. -/
theorem errs_step {cfg : Cfg} {s : State} (h : SInv s) (e : Event) (d : Cl) :
    ((step cfg s e).cl d).err ≠ some .inUse := by
  rcases step_err cfg s e d with h' | h' | ⟨k, _, hk, _⟩ | h' | h' | h' | ⟨_, h'⟩
  · rw [h']; exact h.errs d
  all_goals first | (rw [h']; decide) | exact absurd hk (h.noInUse k)

theorem mono_cancel {s : State} (c : Cl) :
    Mono s (updC c (fun x => { x with ph := .idle, err := none })
      { shutdown c s with cancels := s.cancels + 1 }) :=
  Mono.trans (mono_shutdown c)
    (Mono.trans (⟨Nat.le_refl _, fun _ _ => rfl, fun _ h => Or.inl h, fun _ h => Or.inl h,
      fun _ h => h⟩ : Mono (shutdown c s) { shutdown c s with cancels := s.cancels + 1 })
      (mono_updC _ _))

/-- Every client-side event: the sockets move by `Mono` and the room stays. -/
def MR (s t : State) : Prop := Mono s t ∧ t.room = s.room

theorem MR.trans {s t u : State} (a : MR s t) (b : MR t u) : MR s u :=
  ⟨a.1.trans b.1, b.2.trans a.2⟩
theorem mr_updC {s : State} (c : Cl) (f : Client → Client) : MR s (updC c f s) := ⟨mono_updC c f, rfl⟩
theorem mr_updP {s : State} (p : Nat) (f : PC → PC) : MR s (updP p f s) := ⟨mono_updP p f, rfl⟩
theorem mr_dial {s : State} (c : Cl) (r : Bool) : MR s (dial c r s) := ⟨mono_dial c r, rfl⟩
theorem mr_closeOwn {s : State} (k : Nat) : MR s (closeOwn k s) := ⟨mono_closeOwn k, rfl⟩
theorem mr_fail {s : State} (c : Cl) (e : Err) : MR s (fail c e s) := ⟨mono_fail c e, fail_room ..⟩
theorem mr_toManual {s : State} (c : Cl) : MR s (toManual c s) := ⟨mono_toManual c, toManual_room ..⟩
theorem mr_rewait {s : State} (c : Cl) : MR s (rewait c s) := ⟨mono_rewait c, rewait_room ..⟩
theorem mr_sigRedial {s : State} (c : Cl) : MR s (sigRedial c s) :=
  ⟨mono_sigRedial c, sigRedial_room ..⟩

theorem step_mr {cfg : Cfg} {s : State} (e : Event) (he : en s e = true)
    (h1 : ∀ k, e ≠ .srvRecv k) (h2 : ∀ k, e ≠ .srvNotice k) : MR s (step cfg s e) := by
  cases e with
  | click c => exact (mr_updC _ _).trans (mr_dial _ _)
  | cancel c => exact ⟨mono_cancel c, by simp [step, shutdown_room]⟩
  | suspend c => simp only [step]; exact mr_updC _ _
  | resume c => simp only [step]; exact mr_updC _ _
  | open_ k =>
    simp [en] at he; simp only [step]
    refine MR.trans ⟨mono_updK' k ?_, rfl⟩ (mr_updC _ _)
    exact ⟨rfl, fun _ => by simp [he.1], fun _ => Or.inr (by simp [he.1]), by simp⟩
  | die k => simp only [step]; exact ⟨mono_updK k (fun x => ⟨rfl, id, Or.inl, by simp⟩), rfl⟩
  | cclose k =>
    have h0 : MR s (updK k (fun y => { y with cst := .closed }) s) :=
      ⟨mono_updK k (fun x => ⟨rfl, by simp, Or.inl, id⟩), rfl⟩
    simp only [step]
    repeat' split
    all_goals first
      | exact h0
      | exact h0.trans (mr_sigRedial _)
      | exact h0.trans (mr_toManual _)
  | srvRecv k => exact absurd rfl (h1 k)
  | srvNotice k => exact absurd rfl (h2 k)
  | deliver k =>
    simp only [step]
    split
    · exact ⟨Mono.refl s, rfl⟩
    · rename_i m rest hdown
      refine MR.trans (MR.trans ⟨mono_updK' k ?_, rfl⟩ (mr_updC _ _))
        ⟨mono_onMsg _ _ _ _, onMsg_room ..⟩
      exact ⟨rfl, id, Or.inl, fun hm => by simp [hdown, hm]⟩
  | fallback c => exact mr_toManual c
  | redial c => exact (mr_updC _ _).trans (mr_dial _ _)
  | deadline c =>
    simp only [step]
    repeat' split
    all_goals first
      | exact (mr_updC _ _).trans (mr_fail _ _)
      | exact (mr_updC _ _).trans (mr_rewait _)
      | exact mr_fail _ _
  | dcOpen c =>
    simp only [step]
    split
    · split
      · exact ((mr_updP _ _).trans (mr_closeOwn _)).trans (mr_updC _ _)
      · exact (mr_updP _ _).trans (mr_updC _ _)
    · exact ⟨Mono.refl s, rfl⟩
  | dcClose c => exact mr_fail _ _

theorem sinv_step {cfg : Cfg} (hs : cfg.server = true) {s : State} (h : SInv s) (e : Event)
    (he : en s e = true) : SInv (step cfg s e) := by
  have herr := errs_step (cfg := cfg) h e
  cases e with
  | srvRecv k =>
    simp [en] at he; simp only [step]
    exact sinv_srvRecv hs h k he.1
  | srvNotice k =>
    have h' : SInv (updK k (fun x => { x with up := [] }) s) :=
      sinv_same_room h (mono_updK k (fun x => ⟨rfl, id, Or.inl, id⟩)) rfl (by simp [h.errs])
    exact sinv_teardown h' k
  | _ =>
    obtain ⟨m, hr⟩ := step_mr (cfg := cfg) _ he (by simp) (by simp)
    exact sinv_same_room h m hr herr

theorem sinv_reachable {cfg : Cfg} (hs : cfg.server = true) {s : State} (h : Reachable cfg s) :
    SInv s := by
  induction h with
  | init nat => exact sinv_init nat
  | step e _ he ih => exact sinv_step hs ih e he

/-- With two players, the fixed server never tells either one "that code is
    already in use": a page that redials takes its own stale seat back. -/
theorem no_in_use {cfg : Cfg} (hs : cfg.server = true) {s : State} (h : Reachable cfg s)
    (d : Cl) : (s.cl d).err ≠ some .inUse :=
  (sinv_reachable hs h).errs d

/-- ... and never seats one page against itself. -/
theorem seats_distinct {cfg : Cfg} (hs : cfg.server = true) {s : State} (h : Reachable cfg s)
    (hh g : Nat) (hr : s.room = some ⟨hh, some g⟩) : (s.socks hh).owner ≠ (s.socks g).owner :=
  (sinv_reachable hs h).owners hh g hr

end WebState.LinkPairing
