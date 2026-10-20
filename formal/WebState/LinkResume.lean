-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/netplay.js: rbOfferResume rbResumeInfoIn rbCanResume rbLogSent rbDropped rbBeginResume rsDetach rsRestart rsStop rsAdopt rsResumeIn rbResumeState rbStartIfReady rbSendInput rbSendInputWire rbSend rbSendPause rbNewReg rbBeats rbPress rbPressIn rbMessage netShutdown netPeerGone rbLeaveNote rsDial rbRenderCard rbReconnecting
-- @models web/index.js: togglePause setSpeed2x

/-
# Resuming a dropped link (web/netplay.js, the rollback layer)

When the connection under an online link drops, both sides redial on a
retry code the host dealt at the start, open a new DataChannel, and swap
RESUME [sid][last input frame received][flags]. Each resends the inputs the
friend missed from a 128-entry log, the pause state is reconciled, and play
goes on. A deliberate end says BYE first, so the friend doesn't redial,
and leaves a goodbye note on the retry code for a friend the BYE can't
reach; after 180 s of redialing a side gives up.

This file models that protocol's data plane: what crosses the channels and
what each side does with it. How the two sides find each other again (the
signaling server on the retry code, sockets, the pairing timers) is
`LinkRedial`'s; here a pairing is one event that hands both reconnecting
sides a fresh channel, and every way a redial attempt fails (pair deadline,
no RESUME in 10 s, ICE failure, the server dropping a socket) is one
`restart` event that may fire whenever a side is redialing.

`Cfg` selects the code:
* `early`: the friend's messages before our channel's `onopen` are queued
  and replayed at it (`rb.rsEarly`, d22e0527). Off: dropped, as the iOS port
  did before the review.
* `fix`: what this model led to (below): pause and 2x after a resume taken
  from both RESUMEs' flags, a press after our RESUME relayed, and the
  keepalive (`RB_PING`). Off: d22e0527.
* `iosB`: B is the iPhone app, whose pause follows the app's background
  state (GameSession.appDidEnterBackground / appWillEnterForeground) and
  whose resume refuses to unpause in the background (NetLink.resumeIn).
* `freeze`: the game is held while redialing: the frame loop doesn't tick
  (no inputs) and Pause and 2x are off (`rbRenderCard`, `togglePause`,
  `setSpeed2x`; iOS `togglePause`, `toggleDouble`, `linkedFrames`). The
  iPhone's own pause for the background still happens. Off: b94cc418.
* `note`: the signaling server keeps goodbye notes (`POST /bye`,
  server.js `leaveNote`). Every session end of a side holding the retry
  code, other than on the friend's goodbye, posts one (`shutdown`); with
  `note`, a redialing friend's rendezvous is answered with it (`noteIn`).
  Off: the server at d22e0527, which keeps none.
* `seq`: numbered presses (`rbPress`, `rbPressIn`; iOS `NetLink.press`,
  `pressIn`). Each pause press carries a number one past the highest its
  side has seen (`press`), and a friend's press is taken only if it beats
  the one held (`Reg.beats`: a higher number, or the same number from the
  host); a resume restarts both from the shared decision as the host's
  press 0. Off: through 8362053b, where whichever message arrived last won.

## What is modelled

* Two sides, A (the host, which deals the retry code) and B. Each holds
  the JS variables of `net.rb` this protocol reads: `resume` (code + sid
  known), `resumeOk`, `byeIn`, `net.dc`, `rsPc` and `rsDcOpen`, `rsEarly`,
  `sentCount` (the log), `lastRx`, `paused`, `reconnectAt`, `lastMsgAt`.
* Channels: one per pairing, numbered as made (0 is the session's first).
  Each is reliable and ordered (the DataChannel is `ordered: true`), with
  a queue to each side. A side that closes its end reads nothing more; what
  it sent may still arrive. `die` loses everything in flight.
* Inputs: frame `f` is `RB_INPUT [f][bits]`; the bits are abstracted, since
  the frames are what can go missing or repeat. A side produces frame
  `sent` only while it is fewer than `W` = 12 frames ahead of the friend's
  input it holds (`rollback.nim` `tick`: `head - confirmed > maxAhead`
  stalls, maxAhead 12), and not while paused or in the background.
* A clock (`tick`), for the 180 s give-up and the `lastMsgAt` check.
* The goodbye note each side left on the retry code (`note`), and its
  reason ("left" for Disconnect or leaving the page, "gave-up" otherwise).

## Abstractions

* One session, so sid checks always pass; the retry code is in `resume`.
* The rollback cores are deterministic given the same inputs; that both
  cores stay byte-identical after a resume follows from both receiving the
  friend's inputs exactly, which is what is proved here.
* `dropped` (dc.onclose, connection `failed`/`closed`, 10 s
  `disconnected`) may fire whenever a side holds a channel, live or not:
  the 10 s "disconnected" redial fires on a channel that may still work.
* A channel can open on a side whether or not the friend still holds it
  (it may open and close at once).
* The early messages are put back in front of the channel's queue at the
  open and read before any other event, which is what replaying them is.
* 2x is the same code as pause with "slow wins" and no background case
  (its own register, `rb.speedReg`); away (RB_AWAY) is only the card it
  shows, so neither is modelled.
* The goodbye note reaches the server as the side ends, and is read by a
  redialing friend between attempts (`noteIn`: dialing or waiting on the
  code; a pairing in hand fails or opens first). The beacon in flight, the
  rooms and the leaver's stale seat are `LinkRedial`'s. Its 10-minute
  expiry is not modelled: a friend redials for at most 180 s, starting at
  most 180 s after the last thing it heard.
* A pause someone else holds is not modelled: `applyRemotePause` (the home
  screen, Report a Bug) and `GameSession.remotePause` (a sheet, the home
  screen) keep the friend's choice until it is released, on a live link and
  after a resume alike.

## Results

Proved for every `Cfg` and every reachable state (`Inv`, `inv_reachable`):

* `inputs_exact`: every input a side reads is exactly the next frame it
  needs: never past it (a gap stalls the window for good, or desyncs),
  never one it has. Through any drops, channel deaths, restarts, early
  messages and one-sided resumes. With deterministic cores, this is why
  both games stay byte-identical after a resume.
* `log_covers_gap`: when a RESUME reaches a redialing side, it has sent at
  most `2 W` = 24 frames past what the friend says it has, so the 128-entry
  log always covers the gap and "Couldn't resume the link" is unreachable.
* `frames_bounded`: a side never holds more of the friend's frames than
  the friend sent, nor runs more than the window ahead.

Refuted on d22e0527 (`bug_*`), fixed, and proved for the fix:

* `bug_resume_pause_swap_ios`: the iPhone pauses for the background, the
  pause is lost with the connection, both redial while it is still in the
  background. Each side answered the other's RESUME with its own pause
  state; the answers cross, and the browser ends paused while the app
  runs, in the background, and stays running when it comes back.
  `bug_resume_pause_swap_web`: the same swap web↔web, from a Pause press in
  the round trip between a side's channel opening and the friend's RESUME.
  The fix (`Cfg.fix`): both sides set pause (and 2x) from the two RESUMEs'
  flags (`finalPause`) and send nothing more. `resume_agrees` (`PInv`,
  `pinv_reachable`): once both are live on one channel, with no Pause press
  (or background change) on either side since its own resume, they agree.
  `regress_resume_pause_swap_ios/_web` replay both traces. A pause change
  after a side's own RESUME went out is newer than that decision: it holds
  and is relayed (`bug_bg_after_open_ios` / `regress_bg_after_open_ios`: an
  app backgrounded in that window ended unpaused in the background).
* `bug_long_quiet_then_drop_ends`: paused together past 180 s, nothing
  crosses the link, and a drop reads as a friend that gave up: both end
  without a redial. The fix's keepalive (`ping`) keeps the silence clock
  fresh: `regress_long_quiet_keepalive`.
* `bug_early_resume_lost` (`Cfg.noEarly`, the iOS port before the review):
  a RESUME before the open was dropped. `early_resume_kept` on d22e0527.
* `bug_quit_while_redialing_unheard`: Disconnect while redialing had no
  channel to say BYE on, and the friend showed "Reconnecting…" for 180 s,
  then "Couldn't reconnect". The goodbye note (`Cfg.note`) fixes it:
  `quit_heard` (`QInv`, `qinv_reachable`): for every `Cfg`, whenever a side
  has ended other than killed while its friend is redialing, it has left a
  note (the friend never redials past a BYE, and a redialing side's friend
  holds the code); `quit_heard_next`: with `Cfg.note` the friend's next
  attempt is answered with it, unless its own give-up comes first.
  `regress_quit_while_redialing_heard` replays the trace (and B not yet
  aware of the drop, B mid-pairing, the iPhone). The same note shortens two
  other trade-offs: `regress_start_window_heard` (the host ending in the
  start window) and `regress_give_up_clocks_drift` (the friend still
  redialing after a give-up).
* `pause_in_drop_undone` (trade-off, through b94cc418): a Pause pressed
  during the drop was undone at the reconnect if the friend kept running.
  With `Cfg.freeze` the game is held while redialing and Pause and 2x are
  off (`no_press_in_drop`), so there is no press to undo
  (`regress_no_press_in_drop`); a pause both had at the drop stays.
* `bug_pause_presses_cross` (trade-off, through 8362053b; not the
  resume's): two Pause presses on one side and one on the other, within a
  round trip, crossed on a live link and split the pause, each side
  taking whichever message arrived last. With numbered presses
  (`Cfg.seq`), `presses_agree` (`SInv`, `sinv_reachable`): whenever both
  are live on one working channel with no press on its way either way,
  both are paused or both running, whatever presses crossed before, on a
  live link or across any number of resumes. Stronger, at every moment
  the two will hold the same press once they have read what is on its way
  (`SCore.conv`). `regress_pause_presses_cross` replays the trace.

Shown by trace, as designed but worth knowing (`FINDINGS.md`):
`pause_in_drop_undone`,
`fix_paused_and_away_stays_paused` (now only for the iPhone's background
pause and a hidden tab: a press can't happen), `kill_strands_friend` (the note can't
help: nothing runs), `quit_after_open_reaches_friend`,
`start_window_one_sided`, `give_up_clocks_drift`,
`give_up_reads_as_disconnect`, `reconnect_clocks_differ`; and the happy
paths `resume_happy`, `resume_twice`, `early_resume_kept`.
-/
namespace WebState.LinkResume

set_option linter.unusedSimpArgs false
set_option linter.unusedVariables false

inductive Cl where
  | a | b
  deriving DecidableEq, Repr

def Cl.other : Cl → Cl
  | .a => .b
  | .b => .a

@[simp] theorem Cl.other_other (c : Cl) : c.other.other = c := by cases c <;> rfl
@[simp] theorem Cl.other_ne (c : Cl) : c.other ≠ c := by cases c <;> decide
@[simp] theorem Cl.ne_other (c : Cl) : c ≠ c.other := by cases c <;> decide
theorem Cl.eq_or (c d : Cl) : d = c ∨ d = c.other := by cases c <;> cases d <;> simp [Cl.other]

/-- The rollback window, in frames (`rollback.nim` maxAhead). -/
def W : Nat := 12
/-- `RB_SENT_LOG`: inputs kept for the friend's gap. -/
def LOG : Nat := 128
/-- `rbResumeGiveUpMs`, in seconds (one clock tick is a second). -/
def G : Nat := 180

/-- What crosses a channel, of what this machine reads. -/
inductive Msg where
  | info                                   -- RB_RESUME_INFO [sid][retry code]
  | inp (f : Nat)                          -- RB_INPUT [frame][bits]
  | resume (rx : Nat) (p : Bool) (a : Bool) -- RB_RESUME: rx = lastRx + 1; flags 2 (paused), 1 (away)
  | pause (on : Bool) (n : Nat)            -- RB_PAUSE [on][n]: the press's number (the sender is its author)
  | bye                                    -- RB_BYE
  | ping                                   -- RB_PING (the fix's keepalive)
  deriving DecidableEq, Repr

def Msg.isResume : Msg → Bool
  | .resume .. => true
  | _ => false

/-- A pause press, as the numbered presses keep it (`rb.pauseReg`): its
    number, whether the host (A) made it, and the state it asks for. -/
structure Reg where
  n   : Nat
  byA : Bool
  on  : Bool
  deriving DecidableEq, Repr

/-- `rbPressBeats`: a higher number wins; the same number, the host's. -/
def Reg.beats (x y : Reg) : Bool := decide (x.n > y.n) || (x.n == y.n && x.byA && !y.byA)

/-- What both sides start a session on, and reset to on a resume: number 0,
    the host's. -/
def Reg.base (on : Bool) : Reg := ⟨0, true, on⟩

structure Chan where
  q      : Cl → List Msg := fun _ => []   -- in flight to each side, in order
  closed : Cl → Bool := fun _ => false    -- that side closed its end
  dead   : Bool := false                  -- the connection died; nothing more arrives

inductive Ph where
  | live | recon | ended
  deriving DecidableEq, Repr

/-- Why the session ended, as the toast says it. -/
inductive End where
  | quit      -- this player pressed Disconnect or left the page
  | peerBye   -- "Peer disconnected": the friend's BYE
  | lost      -- "Peer connection lost" / "Peer disconnected": closed, and no resume possible
  | gaveUp    -- "Couldn't reconnect"
  | noResume  -- "Couldn't resume the link": the friend's gap is older than the log
  | killed    -- the page or app was killed; nothing ran
  deriving DecidableEq, Repr

/-- A goodbye note's reason (`POST /bye` "why"): the player's own end, or
    the session failing on this side. -/
inductive Bye where
  | left | gaveUp
  deriving DecidableEq, Repr

structure Side where
  ph      : Ph := .live
  why     : Option End := none
  res     : Bool := false        -- rb.resume (the retry code and sid)
  ok      : Bool := false        -- rb.resumeOk: both sides know it
  bye     : Bool := false        -- rb.byeIn
  dc      : Option Nat := some 0 -- net.dc
  rsPc    : Option Nat := none   -- rb.rsPc: the redial's pairing, by its channel
  rsOpen  : Bool := false        -- rb.rsDcOpen
  early   : List Msg := []       -- rb.rsEarly
  sent    : Nat := 0             -- rb.sentCount: frames 0 .. sent-1 sent (or held), all logged
  rx      : Nat := 0             -- rb.lastRx + 1
  paused  : Bool := false        -- paused (web) / GameSession.paused (iOS)
  away    : Bool := false        -- document.hidden (web) / in the background (iOS)
  pfb     : Bool := false        -- iOS GameSession.pausedForBackground
  reg     : Reg := Reg.base false -- rb.pauseReg: the winning press (read only with `Cfg.seq`)
  since   : Nat := 0             -- rb.reconnectAt
  lastMsg : Nat := 0             -- rb.lastMsgAt
  -- ghosts: no JS variable
  fP      : Bool := false        -- the paused flag our last RESUME carried
  fA      : Bool := false        -- the away flag our last RESUME carried
  livePress : Bool := false      -- paused/background changed while live since our last open
  gap     : Bool := false        -- an input arrived past the next frame needed
  dup     : Bool := false        -- an input arrived that we already had
  deriving DecidableEq, Repr

structure Cfg where
  early  : Bool
  fix    : Bool
  iosB   : Bool
  note   : Bool
  freeze : Bool
  seq    : Bool
  deriving DecidableEq, Repr

/-- d22e0527, both sides web. -/
def Cfg.web : Cfg := ⟨true, false, false, false, false, false⟩
/-- d22e0527, B the iPhone app. -/
def Cfg.ios : Cfg := ⟨true, false, true, false, false, false⟩
/-- With the pause fix (7b970ead). -/
def Cfg.webFix : Cfg := ⟨true, true, false, false, false, false⟩
def Cfg.iosFix : Cfg := ⟨true, true, true, false, false, false⟩
/-- With the goodbye note too (b94cc418). -/
def Cfg.webNote : Cfg := ⟨true, true, false, true, false, false⟩
def Cfg.iosNote : Cfg := ⟨true, true, true, true, false, false⟩
/-- With the game held while redialing (1d493ac0). -/
def Cfg.webNow : Cfg := ⟨true, true, false, true, true, false⟩
def Cfg.iosNow : Cfg := ⟨true, true, true, true, true, false⟩
/-- With numbered presses: the current code. -/
def Cfg.webSeq : Cfg := ⟨true, true, false, true, true, true⟩
def Cfg.iosSeq : Cfg := ⟨true, true, true, true, true, true⟩
/-- fd7b0432's iOS port: messages before the open dropped. -/
def Cfg.noEarly : Cfg := ⟨false, false, false, false, false, false⟩

structure State where
  sd     : Cl → Side
  ch     : Nat → Chan
  nextCh : Nat
  now    : Nat
  note   : Cl → Option Bye := fun _ => none  -- the goodbye each side left on the retry code

/-- Both sides have started on channel 0; A, the host, has just dealt the
    retry code (`rbStartIfReady` → `rbOfferResume`), which is in flight. -/
def init : State where
  sd := fun c => if c = .a then { res := true } else {}
  ch := fun k => if k = 0 then { q := fun c => if c = .b then [.info] else [] } else {}
  nextCh := 1
  now := 0

def updS (c : Cl) (f : Side → Side) (s : State) : State :=
  { s with sd := fun d => if d = c then f (s.sd d) else s.sd d }

def updCh (k : Nat) (f : Chan → Chan) (s : State) : State :=
  { s with ch := fun j => if j = k then f (s.ch j) else s.ch j }

/-- `rbSend`: on c's channel, to the friend. Lost if the channel died or c
    closed its end. -/
def send (c : Cl) (m : Msg) (s : State) : State :=
  match (s.sd c).dc with
  | some k =>
    if (s.ch k).dead || (s.ch k).closed c then s
    else updCh k (fun x => { x with q := fun d => if d = c.other then x.q d ++ [m] else x.q d }) s
  | none => s

def sendAll (c : Cl) : List Msg → State → State
  | [] => fun s => s
  | m :: ms => fun s => sendAll c ms (send c m s)

/-- Frames `t .. n-1`. -/
def frames (t n : Nat) : List Msg := (List.range' t (n - t)).map Msg.inp

def closeEnd (c : Cl) (k : Nat) (s : State) : State :=
  updCh k (fun x => { x with closed := fun d => if d = c then true else x.closed d }) s

/-- `rsDetach`: let go of the channel, adopted or still pairing. -/
def detach (c : Cl) (s : State) : State :=
  let x := s.sd c
  let s := match x.rsPc with
    | some k => closeEnd c k s
    | none => s
  let s := match x.dc with
    | some k => closeEnd c k s
    | none => s
  updS c (fun y => { y with rsPc := none, rsOpen := false, early := [], dc := none }) s

/-- The session is over for c (`net = null`): every channel let go. -/
def finish (c : Cl) (w : End) (s : State) : State :=
  updS c (fun y => { y with ph := .ended, why := some w }) (detach c s)

/-- `rbLeaveNote`: a side that knows the retry code, ending without the
    friend's goodbye, leaves one on the code ("left" for its own end,
    "gave-up" for a failure). The beacon's flight is `LinkRedial`'s; here it
    is at the server at once, and whether the server keeps it is `Cfg.note`
    (an older server answers `POST /bye` with its health line). -/
def leaveNote (c : Cl) (w : End) (x : Side) (s : State) : State :=
  if x.res && !x.bye then
    { s with note := fun d => if d = c then some (if w = .quit then .left else .gaveUp) else s.note d }
  else s

/-- `netPeerGone` → `netShutdown`: unless the friend said BYE, say BYE on
    the open channel (none while redialing before a channel opened), finish,
    and leave the goodbye note. -/
def shutdown (c : Cl) (w : End) (s : State) : State :=
  leaveNote c w (s.sd c) (finish c w (if (s.sd c).bye then s else send c .bye s))

/-- `rbSendPause` / `NetLink.sendPause`: a press, numbered one past the
    highest this side has seen; it becomes this side's winning press. -/
def press (c : Cl) (p : Bool) (s : State) : State :=
  let n := (s.sd c).reg.n + 1
  updS c (fun y => { y with reg := ⟨n, c == .a, p⟩ }) (send c (.pause p n) s)

/-- `setPaused(p, relay)` (iOS) / `togglePause` (web): set the state, relay
    it unless it came from the friend or the link is redialing
    (`rbSendPause` returns while `reconnecting`). -/
def setPaused (c : Cl) (p relay : Bool) (s : State) : State :=
  if (s.sd c).paused = p then s
  else
    let s := updS c (fun y => { y with paused := p, pfb := false }) s
    if relay && (s.sd c).ph == .live then press c p s else s

/-- `applyRemotePause` (web) / `GameSession.remotePause` (iOS): match the
    friend, without echoing. -/
def remotePause (c : Cl) (v : Bool) (s : State) : State := setPaused c v false s

/-- The fix: both sides compute the same state from the two RESUMEs' flags.
    Running wins, except that a side that was paused and away (a hidden tab,
    an app in the background) keeps both paused. -/
def finalPause (pa aa pb ab : Bool) : Bool := (pa && pb) || (aa && pa) || (ab && pb)

/-- The pause half of `rsResumeIn`: the friend's RESUME said paused `p`,
    away `a`. -/
def pauseAfterResume (cfg : Cfg) (c : Cl) (p a : Bool) (s : State) : State :=
  if cfg.fix then
    let x := s.sd c
    let final := finalPause x.fP x.fA p a
    if x.paused != x.fP then
      -- Paused or unpaused (a press, the background) after our RESUME went
      -- out: newer than that decision, it holds, and is relayed like any
      -- press (c is live now).
      let s := updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) s
      if x.paused != final then press c x.paused s else s
    else remotePause c final s
  else
    -- d22e0527: a side that says it's running unpauses this one, never the
    -- reverse (nor, on iOS, while the app is in the background); then each
    -- sends where it ended up.
    let x := s.sd c
    let ios := cfg.iosB && c == .b
    let s := if !p && x.paused && !(ios && x.away) then remotePause c false s else s
    send c (.pause (s.sd c).paused 0) s

/-- `rsResumeIn`: the friend's RESUME with its `lastRx + 1` = `t`. -/
def resumeIn (cfg : Cfg) (c : Cl) (t : Nat) (p a : Bool) (s : State) : State :=
  let x := s.sd c
  if !(x.ph == .recon && x.res && x.rsOpen) then s
  else if x.sent > t + LOG then shutdown c .noResume s
  else
    -- Both registers restart from the decision both sides make from the
    -- same two RESUMEs (`finalPause`), as the host's press number 0.
    let s := updS c (fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) }) s
    -- rsStop: redialing stops; the adopted channel stays the session's.
    let s := updS c (fun y => { y with ph := .live, rsPc := none }) s
    -- The friend's gap, from the log, in order.
    let s := sendAll c (frames t x.sent) s
    pauseAfterResume cfg c p a s

/-- `rbMessage`, one message from the friend on c's channel. -/
def recv (cfg : Cfg) (c : Cl) (m : Msg) (s : State) : State :=
  let s := updS c (fun y => { y with lastMsg := s.now }) s
  match m with
  | .info =>
    -- rbResumeInfoIn: the guest takes the code and echoes it; the host's
    -- echo back means the guest has it.
    if (s.sd c).res then updS c (fun y => { y with ok := true }) s
    else send c .info (updS c (fun y => { y with res := true, ok := true }) s)
  | .inp f =>
    updS c (fun y => { y with rx := max y.rx (f + 1), gap := y.gap || decide (f > y.rx),
                              dup := y.dup || decide (f < y.rx) }) s
  | .resume t p a => resumeIn cfg c t p a s
  | .pause v n =>
    -- Numbered: taken only if it beats the press this side holds (the
    -- friend made it). Before: whatever arrives last.
    if cfg.seq then
      let r : Reg := ⟨n, c.other == .a, v⟩
      if r.beats (s.sd c).reg then remotePause c v (updS c (fun y => { y with reg := r }) s) else s
    else remotePause c v s
  | .bye => shutdown c .peerBye (updS c (fun y => { y with bye := true }) s)
  | .ping => s

/-- The next message in flight to c on channel k arrives: read if k is c's
    channel; queued if k is the pairing whose channel hasn't opened on c yet
    (`rb.rsEarly`); otherwise dropped. -/
def deliver (cfg : Cfg) (c : Cl) (k : Nat) (s : State) : State :=
  match (s.ch k).q c with
  | [] => s
  | m :: rest =>
    let s := updCh k (fun x => { x with q := fun d => if d = c then rest else x.q d }) s
    if (s.ch k).closed c then s
    else if (s.sd c).dc = some k then recv cfg c m s
    else if (s.sd c).rsPc = some k then
      if cfg.early then updS c (fun y => { y with early := y.early ++ [m] }) s else s
    else s

def deliverN (cfg : Cfg) (c : Cl) (k : Nat) : Nat → State → State
  | 0 => fun s => s
  | n + 1 => fun s => deliverN cfg c k n (deliver cfg c k s)

/-- What `rsAdopt` sets on the side: the channel is open and is `net.dc`;
    the ghosts record the flags the RESUME carries. -/
def openSide (k : Nat) (y : Side) : Side :=
  { y with rsOpen := true, dc := some k, early := [], fP := y.paused, fA := y.away, livePress := false }

section openSide
variable (k : Nat) (y : Side)
@[simp] theorem openSide_ph : (openSide k y).ph = y.ph := rfl
@[simp] theorem openSide_dc : (openSide k y).dc = some k := rfl
@[simp] theorem openSide_rsPc : (openSide k y).rsPc = y.rsPc := rfl
@[simp] theorem openSide_rsOpen : (openSide k y).rsOpen = true := rfl
@[simp] theorem openSide_early : (openSide k y).early = [] := rfl
@[simp] theorem openSide_paused : (openSide k y).paused = y.paused := rfl
@[simp] theorem openSide_fP : (openSide k y).fP = y.paused := rfl
@[simp] theorem openSide_fA : (openSide k y).fA = y.away := rfl
@[simp] theorem openSide_livePress : (openSide k y).livePress = false := rfl
end openSide

/-- `rsAdopt`: c's new channel opens. It becomes `net.dc`, says RESUME, and
    the friend's messages that came first are read. -/
def adopt (cfg : Cfg) (c : Cl) (s : State) : State :=
  match (s.sd c).rsPc with
  | none => s
  | some k =>
    let x := s.sd c
    let s := updCh k (fun y => { y with q := fun d => if d = c then x.early ++ y.q d else y.q d }) s
    let s := updS c (openSide k) s
    let s := send c (.resume x.rx x.paused x.away) s
    deliverN cfg c k x.early.length s

/-- `rsRestart`: this attempt is over. Past the give-up by the clock (a
    suspended page's timer may not have run) it ends; else it lets go and
    dials again. -/
def restart (c : Cl) (s : State) : State :=
  if (s.sd c).since + G < s.now then shutdown c .gaveUp s else detach c s

/-- `rbDropped`: the channel is gone. Redial if both sides know the retry
    code and the friend didn't say BYE; else end. -/
def dropped (c : Cl) (s : State) : State :=
  let x := s.sd c
  if x.ok && !x.bye then
    -- rbBeginResume
    if x.ph == .recon then restart c s
    else if x.lastMsg + G < s.now then shutdown c .lost s
    else updS c (fun y => { y with ph := .recon, since := s.now }) (detach c s)
  else shutdown c .lost s

/-- A new pairing on the retry code: a fresh channel for both. -/
def pair (s : State) : State :=
  let k := s.nextCh
  updS .b (fun y => { y with rsPc := some k })
    (updS .a (fun y => { y with rsPc := some k }) { s with nextCh := k + 1 })

def isIos (cfg : Cfg) (c : Cl) : Bool := cfg.iosB && c == .b

/-- The tab hides / the app goes to the background (`on`), or comes back.
    The iPhone app pauses for the background and unpauses on return if it
    was its own pause. -/
def setAway (cfg : Cfg) (c : Cl) (on : Bool) (s : State) : State :=
  let x := s.sd c
  let s := updS c (fun y => { y with away := on,
                                     livePress := y.livePress || y.ph == .live }) s
  if !isIos cfg c then s
  else if on then
    if x.paused then s else updS c (fun y => { y with pfb := true }) (setPaused c true true s)
  else if x.pfb then setPaused c false true (updS c (fun y => { y with pfb := false }) s)
  else s

inductive Event where
  | input (c : Cl)          -- rollback_tick advanced: the frame is sent, or held while redialing
  | deliver (c : Cl) (k : Nat)
  | die (k : Nat)           -- the connection under channel k dies
  | dropped (c : Cl)        -- c's channel closes under it, or stays "disconnected" 10 s
  | pair                    -- both rendezvous on the retry code
  | adopt (c : Cl)          -- c's new channel opens
  | restart (c : Cl)        -- a redial attempt fails (any of its timers or errors)
  | giveUp (c : Cl)         -- the 180 s give-up timer
  | quit (c : Cl)           -- Disconnect, or leaving the page (netShutdown)
  | kill (c : Cl)           -- the page or app dies without running anything
  | toggle (c : Cl)         -- the player presses Pause
  | away (c : Cl) (on : Bool)
  | tick (n : Nat)          -- n seconds pass
  | ping (c : Cl)           -- the fix's keepalive (RB_PING every 20 s while live)
  | noteIn (c : Cl)         -- c's rendezvous on the retry code is answered with the friend's goodbye
  deriving DecidableEq, Repr

def holds (s : State) (c : Cl) (k : Nat) : Prop :=
  (s.sd c).dc = some k ∨ (s.sd c).rsPc = some k

def en (cfg : Cfg) (s : State) : Event → Bool
  | .input c =>
    let x := s.sd c
    x.ph != .ended && !x.paused && !x.away && decide (x.sent < x.rx + W) &&
      !(cfg.freeze && x.ph == .recon)
  | .deliver c k => !(s.ch k).dead && !((s.ch k).q c).isEmpty
  | .die k => !(s.ch k).dead && decide (k < s.nextCh)
  | .dropped c => (s.sd c).ph != .ended && (s.sd c).dc.isSome
  | .pair =>
    (s.sd .a).ph == .recon && (s.sd .b).ph == .recon &&
      (s.sd .a).rsPc.isNone && (s.sd .b).rsPc.isNone &&
      (s.sd .a).dc.isNone && (s.sd .b).dc.isNone
  | .adopt c =>
    let x := s.sd c
    x.ph == .recon && !x.rsOpen &&
      match x.rsPc with
      | some k => !(s.ch k).dead
      | none => false
  | .restart c => (s.sd c).ph == .recon
  | .giveUp c => (s.sd c).ph == .recon && decide ((s.sd c).since + G ≤ s.now)
  | .quit c => (s.sd c).ph != .ended
  | .kill c => (s.sd c).ph != .ended
  -- With `freeze` the Pause button is off while redialing.
  | .toggle c => (s.sd c).ph != .ended && !(cfg.freeze && (s.sd c).ph == .recon)
  | .away c on => (s.sd c).ph != .ended && (s.sd c).away != on
  | .tick _ => true
  | .ping c => cfg.fix && (s.sd c).ph == .live
  -- Between attempts (dialing, or waiting on the code): a pairing in hand
  -- fails or opens first, and its `restart` comes back here.
  | .noteIn c =>
    cfg.note && (s.sd c).ph == .recon && (s.sd c).rsPc.isNone && (s.sd c).dc.isNone &&
      (s.note c.other).isSome

def step (cfg : Cfg) (s : State) : Event → State
  | .input c =>
    let n := (s.sd c).sent
    let s := updS c (fun y => { y with sent := n + 1 }) s
    -- rbSendInput: logged always; held while redialing.
    if (s.sd c).ph == .live then send c (.inp n) s else s
  | .deliver c k => deliver cfg c k s
  | .die k => updCh k (fun x => { x with dead := true, q := fun _ => [] }) s
  | .dropped c => dropped c s
  | .pair => pair s
  | .adopt c => adopt cfg c s
  | .restart c => restart c s
  | .giveUp c => shutdown c .gaveUp s
  | .quit c => shutdown c .quit s
  | .kill c => finish c .killed s
  | .toggle c =>
    let s := updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) s
    setPaused c (!(s.sd c).paused) true s
  | .away c on => setAway cfg c on s
  | .tick n => { s with now := s.now + n }
  | .ping c => send c .ping s
  | .noteIn c =>
    -- rsDial's "bye": byeIn, then netPeerGone with the friend's reason.
    match s.note c.other with
    | some w => shutdown c (if w = .left then .peerBye else .gaveUp)
        (updS c (fun y => { y with bye := true }) s)
    | none => s

inductive Reachable (cfg : Cfg) : State → Prop
  | init : Reachable cfg init
  | step {s : State} (e : Event) : Reachable cfg s → en cfg s e = true → Reachable cfg (step cfg s e)

def run (cfg : Cfg) (s : State) : List Event → Option State
  | [] => some s
  | e :: es => if en cfg s e then run cfg (step cfg s e) es else none

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

/-- The trace runs from the start (every event enabled) and ends in a state
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

/-! ## What each player sees -/

inductive View where
  | playing
  | pausedV
  | reconnecting (since : Nat)  -- the card: "Reconnecting… Trying for m:ss" from `since`
  | ended (w : End)             -- the toast
  deriving DecidableEq, Repr

def view (s : State) (c : Cl) : View :=
  let x := s.sd c
  match x.ph with
  | .live => if x.paused then .pausedV else .playing
  | .recon => .reconnecting x.since
  | .ended => .ended (x.why.getD .lost)

/-! ## The traces

Channel 0 is the session's first; pairings make 1, 2, ... -/

/-- The retry code reaches B, B's echo reaches A: both can resume. -/
def handshake : List Event := [.deliver .b 0, .deliver .a 0]

/-- Both sides notice the drop, pair, open, and swap RESUMEs. -/
def redial (k : Nat) : List Event :=
  [.dropped .a, .dropped .b, .pair, .adopt .a, .adopt .b, .deliver .a k, .deliver .b k]

def bothPlaying (s : State) : Bool := view s .a == .playing && view s .b == .playing

def onSameChannel (s : State) : Bool :=
  (s.sd .a).dc.isSome && (s.sd .a).dc == (s.sd .b).dc

/-- No gap, no repeat, and each side has every frame the other sent. -/
def inputsWhole (s : State) : Bool :=
  !(s.sd .a).gap && !(s.sd .b).gap && !(s.sd .a).dup && !(s.sd .b).dup &&
    (s.sd .a).rx == (s.sd .b).sent && (s.sd .b).rx == (s.sd .a).sent

/-- The happy case: A sends three frames, B reads one, the connection dies
    with two in flight (and B's one unread); both redial and resume, the
    lost frames are resent from the log, and every frame arrives once. -/
theorem resume_happy :
    witnesses .web (handshake ++
      [.input .a, .input .a, .input .a, .input .b, .deliver .b 0, .die 0] ++ redial 1 ++
      [.deliver .b 1, .deliver .b 1, .deliver .a 1])
      (fun s => bothPlaying s && onSameChannel s && inputsWhole s &&
                (s.sd .a).sent == 3 && (s.sd .b).sent == 1) = true := by
  decide

/-- A drop in the middle of a resume: A resumes and resends, the new channel
    dies before any of it lands, and both redial again. Every frame still
    arrives once. -/
theorem resume_twice :
    witnesses .web (handshake ++
      [.input .a, .input .a, .input .b, .deliver .b 0, .die 0] ++
      [.dropped .a, .dropped .b, .pair, .adopt .a, .adopt .b, .deliver .a 1, .die 1] ++
      [.input .a, .input .b] ++ redial 2 ++
      [.deliver .b 2, .deliver .b 2, .deliver .a 2, .deliver .a 2])
      (fun s => bothPlaying s && onSameChannel s && inputsWhole s) = true := by
  decide

/-! ### The friend's RESUME before our channel opens -/

/-- B's channel opens first and its RESUME reaches A before A's `onopen`:
    queued, and read at A's open. Both resume. -/
theorem early_resume_kept :
    witnesses .web (handshake ++
      [.die 0, .dropped .a, .dropped .b, .pair, .adopt .b, .deliver .a 1, .adopt .a,
       .deliver .b 1])
      (fun s => bothPlaying s && onSameChannel s) = true := by
  decide

/-- Before the review, the iOS port dropped it: B resumes on A's RESUME
    while A waits for one that will never come, until its 10 s answer timer
    redials (which drops B's channel too). -/
theorem bug_early_resume_lost :
    witnesses .noEarly (handshake ++
      [.die 0, .dropped .a, .dropped .b, .pair, .adopt .b, .deliver .a 1, .adopt .a,
       .deliver .b 1])
      (fun s => view s .a == .reconnecting 0 && view s .b == .playing &&
                !(((s.ch 1).q .a).any Msg.isResume) && (s.sd .a).early.isEmpty) = true := by
  decide

/-! ### Pause across a resume -/

def pausedOf (s : State) (c : Cl) : Bool := (s.sd c).paused

/-- Both live on one channel, and neither player has touched Pause (or the
    background) since resuming on it, yet one is paused and the other not:
    the paused side shows the pause screen, the running side stalls at the
    window ("waiting for peer") until someone presses Pause twice. -/
def splitPause (s : State) : Bool :=
  onSameChannel s && (s.sd .a).ph == .live && (s.sd .b).ph == .live &&
    !(s.sd .a).livePress && !(s.sd .b).livePress && pausedOf s .a != pausedOf s .b

/-- The link drops and, while both redial, the iPhone (B) goes to the
    background: it pauses (the relay is held while redialing). Both pair
    while the app still runs in the background (iOS suspends it ~30 s in).
    (Its pause lost with a dying connection does the same.) A's RESUME says running;
    B won't unpause in the background, so it keeps paused and says so; A,
    told B is paused, keeps running (running wins) and says so. The two
    pause messages cross: A pauses, B unpauses, in the background. Back in
    the foreground B stays running: A sees its game paused, B sees it stall. -/
theorem bug_resume_pause_swap_ios :
    witnesses .ios (handshake ++
      [.die 0, .dropped .a, .dropped .b, .away .b true, .pair, .adopt .a, .adopt .b,
       .deliver .a 1, .deliver .b 1, .deliver .a 1, .deliver .b 1])
      (fun s => splitPause s && pausedOf s .a && !pausedOf s .b) = true ∧
    witnesses .ios (handshake ++
      [.die 0, .dropped .a, .dropped .b, .away .b true, .pair, .adopt .a, .adopt .b,
       .deliver .a 1, .deliver .b 1, .deliver .a 1, .deliver .b 1, .away .b false])
      (fun s => pausedOf s .a && !pausedOf s .b && ((s.ch 1).q .a).isEmpty) = true := by
  decide

/-- Web on both sides: B pauses while redialing; A presses Pause in the
    instant between its channel opening and B's RESUME arriving (both held).
    A's RESUME said running, B's said paused. A keeps paused (B is paused)
    and says paused; B unpauses (A said running) and says running. They
    cross: A ends running, B paused. -/
theorem bug_resume_pause_swap_web :
    witnesses .web (handshake ++
      [.die 0, .dropped .a, .dropped .b, .toggle .b, .pair, .adopt .a, .toggle .a, .adopt .b,
       .deliver .a 1, .deliver .b 1, .deliver .b 1, .deliver .a 1])
      (fun s => splitPause s && !pausedOf s .a && pausedOf s .b) = true := by
  decide

/-- With the fix both compute one state from the two RESUMEs' flags. The
    iPhone was paused and in the background, so both stay paused; back in
    the foreground the app's own unpause reaches A, and both run. -/
theorem regress_resume_pause_swap_ios :
    witnesses .iosFix (handshake ++
      [.die 0, .dropped .a, .dropped .b, .away .b true, .pair, .adopt .a, .adopt .b,
       .deliver .a 1, .deliver .b 1])
      (fun s => onSameChannel s && pausedOf s .a && pausedOf s .b &&
                ((s.ch 1).q .a).isEmpty && ((s.ch 1).q .b).isEmpty) = true ∧
    witnesses .iosFix (handshake ++
      [.die 0, .dropped .a, .dropped .b, .away .b true, .pair, .adopt .a, .adopt .b,
       .deliver .a 1, .deliver .b 1, .away .b false, .deliver .a 1])
      bothPlaying = true := by
  decide

/-- With the fix, web: both decide "running" from the flags; A's press,
    newer than its RESUME, holds and reaches B as a pause: both paused. -/
theorem regress_resume_pause_swap_web :
    witnesses .webFix (handshake ++
      [.die 0, .dropped .a, .dropped .b, .toggle .b, .pair, .adopt .a, .toggle .a, .adopt .b,
       .deliver .a 1, .deliver .b 1, .deliver .b 1])
      (fun s => onSameChannel s && pausedOf s .a && pausedOf s .b &&
                ((s.ch 1).q .a).isEmpty && ((s.ch 1).q .b).isEmpty) = true := by
  decide

/-- The iPhone goes to the background after its channel opened, before A's
    RESUME arrives. On d22e0527 it kept paused in the background and said
    so, while A said running: they cross, and the app ends unpaused in the
    background. Without the press relay, the fix would unpause it there too.
    With it: the background pause is newer than B's RESUME, so it holds and
    reaches A: both paused. -/
theorem bug_bg_after_open_ios :
    witnesses .ios (handshake ++
      [.die 0, .dropped .a, .dropped .b, .pair, .adopt .a, .adopt .b, .away .b true,
       .deliver .a 1, .deliver .b 1, .deliver .a 1, .deliver .b 1])
      (fun s => onSameChannel s && pausedOf s .a && !pausedOf s .b && (s.sd .b).away) = true := by
  decide

theorem regress_bg_after_open_ios :
    witnesses .iosFix (handshake ++
      [.die 0, .dropped .a, .dropped .b, .pair, .adopt .a, .adopt .b, .away .b true,
       .deliver .a 1, .deliver .b 1, .deliver .a 1])
      (fun s => onSameChannel s && pausedOf s .a && pausedOf s .b && (s.sd .b).away &&
                ((s.ch 1).q .a).isEmpty && ((s.ch 1).q .b).isEmpty) = true := by
  decide

/-- Not the resume's: two Pause presses on one side and one on the other,
    within a round trip, cross on a live link and leave A paused, B running:
    each side took whichever arrived last, and each one's last was the
    other's. The same with the pause fix and the hold (8362053b). -/
theorem bug_pause_presses_cross :
    witnesses .web (handshake ++
      [.toggle .a, .toggle .a, .toggle .b, .deliver .b 0, .deliver .b 0, .deliver .a 0])
      (fun s => pausedOf s .a && !pausedOf s .b) = true ∧
    witnesses .webNow (handshake ++
      [.toggle .a, .toggle .a, .toggle .b, .deliver .b 0, .deliver .b 0, .deliver .a 0])
      (fun s => pausedOf s .a && !pausedOf s .b && ((s.ch 0).q .a).isEmpty &&
                ((s.ch 0).q .b).isEmpty) = true := by
  decide

/-- With numbered presses: A's presses are #1 (pause) and #2 (resume), B's
    is #1 (pause). B takes A's #1 (the same number, the host's) and then
    its #2; A drops B's #1, older than its own #2. Both run, as A's last
    press asked. `presses_agree` is the general statement. -/
theorem regress_pause_presses_cross :
    witnesses .webSeq (handshake ++
      [.toggle .a, .toggle .a, .toggle .b, .deliver .b 0, .deliver .b 0, .deliver .a 0])
      (fun s => !pausedOf s .a && !pausedOf s .b && ((s.ch 0).q .a).isEmpty &&
                ((s.ch 0).q .b).isEmpty) = true ∧
    witnesses .iosSeq (handshake ++
      [.toggle .a, .toggle .a, .toggle .b, .deliver .b 0, .deliver .b 0, .deliver .a 0])
      bothPlaying = true := by
  decide

/-! ### Design trade-offs a player can see -/

/-- A Pause pressed while the link is down is undone on reconnect if the
    friend kept running: "running wins" (so an iPhone's unpause on coming
    back, lost with the connection, still gets through). The same with the
    fix. -/
theorem pause_in_drop_undone :
    witnesses .web (handshake ++
      [.die 0, .dropped .a, .dropped .b, .toggle .a, .pair, .adopt .a, .adopt .b,
       .deliver .a 1, .deliver .b 1])
      bothPlaying = true ∧
    witnesses .webFix (handshake ++
      [.die 0, .dropped .a, .dropped .b, .toggle .a, .pair, .adopt .a, .adopt .b,
       .deliver .a 1, .deliver .b 1])
      bothPlaying = true := by
  decide

/-- ... except, with the fix, when the player who paused is also away
    (hidden tab): both stay paused, rather than the game running on with
    nobody at it. -/
theorem fix_paused_and_away_stays_paused :
    witnesses .webFix (handshake ++
      [.die 0, .dropped .a, .dropped .b, .toggle .a, .away .a true, .pair, .adopt .a,
       .adopt .b, .deliver .a 1, .deliver .b 1])
      (fun s => onSameChannel s && pausedOf s .a && pausedOf s .b) = true := by
  decide

/-- With the game held while redialing (`Cfg.freeze`), the Pause button
    and the game's buttons do nothing during the drop. -/
theorem no_press_in_drop {cfg : Cfg} (hf : cfg.freeze = true) {s : State} {c : Cl}
    (hr : (s.sd c).ph = .recon) : en cfg s (.toggle c) = false ∧ en cfg s (.input c) = false := by
  simp [en, hf, hr]

/-- So the press `pause_in_drop_undone` undoes can't be made; a pause both
    had when the link dropped is still theirs after the reconnect. The
    iPhone's own pause for the background is not a press: it still counts,
    and the reconnect still decides it. -/
theorem regress_no_press_in_drop :
    (run .webNow init (handshake ++ [.die 0, .dropped .a, .dropped .b, .toggle .a])).isNone = true ∧
    witnesses .webNow (handshake ++
      [.toggle .a, .deliver .b 0, .die 0, .dropped .a, .dropped .b, .pair, .adopt .a, .adopt .b,
       .deliver .a 1, .deliver .b 1])
      (fun s => onSameChannel s && pausedOf s .a && pausedOf s .b) = true ∧
    witnesses .iosNow (handshake ++
      [.die 0, .dropped .a, .dropped .b, .away .b true, .pair, .adopt .a, .adopt .b,
       .deliver .a 1, .deliver .b 1])
      (fun s => onSameChannel s && pausedOf s .a && pausedOf s .b) = true ∧
    witnesses .iosNow (handshake ++
      [.die 0, .dropped .a, .dropped .b, .away .b true, .pair, .adopt .a, .adopt .b,
       .deliver .a 1, .deliver .b 1, .away .b false, .deliver .a 1])
      bothPlaying = true := by
  decide

/-- Disconnect pressed while redialing, before a new channel opened, has
    nothing to say BYE on: on d22e0527 (no goodbye note) the friend keeps
    showing "Reconnecting…" until its own give-up, 180 s after it started,
    then "Couldn't reconnect". -/
theorem bug_quit_while_redialing_unheard :
    witnesses .web (handshake ++ [.die 0, .dropped .a, .dropped .b, .quit .a])
      (fun s => view s .a == .ended .quit && view s .b == .reconnecting 0) = true ∧
    witnesses .web (handshake ++ [.die 0, .dropped .a, .dropped .b, .quit .a, .tick 179])
      (fun s => !en .web s (.giveUp .b) && view s .b == .reconnecting 0) = true ∧
    witnesses .web (handshake ++ [.die 0, .dropped .a, .dropped .b, .quit .a, .tick 180,
                                  .giveUp .b])
      (fun s => view s .b == .ended .gaveUp) = true := by
  decide

/-- With the goodbye note, A's Disconnect leaves a goodbye on the retry
    code, and B's rendezvous on it is answered with it: "Peer disconnected"
    at once. The same when B had not yet noticed the drop, when B held a
    pairing (it fails or times out first, and its restart dials again), and
    from the iPhone. `quit_heard` is the general statement. -/
theorem regress_quit_while_redialing_heard :
    witnesses .webNote (handshake ++ [.die 0, .dropped .a, .dropped .b, .quit .a, .noteIn .b])
      (fun s => view s .a == .ended .quit && view s .b == .ended .peerBye) = true ∧
    witnesses .webNote (handshake ++ [.die 0, .dropped .a, .quit .a, .dropped .b, .noteIn .b])
      (fun s => view s .b == .ended .peerBye) = true ∧
    witnesses .webNote (handshake ++
        [.die 0, .dropped .a, .dropped .b, .pair, .adopt .b, .quit .a, .restart .b, .noteIn .b])
      (fun s => view s .b == .ended .peerBye) = true ∧
    witnesses .iosNote (handshake ++ [.die 0, .dropped .a, .dropped .b, .quit .b, .noteIn .a])
      (fun s => view s .a == .ended .peerBye) = true := by
  decide

/-- A page or app killed outright says nothing, even on a live link: the
    friend redials for 180 s. The goodbye note can't help (nothing ran). -/
theorem kill_strands_friend :
    witnesses .web (handshake ++ [.kill .a, .dropped .b])
      (fun s => view s .a == .ended .killed && view s .b == .reconnecting 0) = true ∧
    witnesses .webNote (handshake ++ [.kill .a, .dropped .b])
      (fun s => view s .b == .reconnecting 0 && !en .webNote s (.noteIn .b)) = true := by
  decide

/-- Once the new channel has opened, Disconnect says BYE on it: the friend
    reads A's RESUME (a "Reconnected" toast), then the BYE ("Peer
    disconnected"). -/
theorem quit_after_open_reaches_friend :
    witnesses .web (handshake ++
      [.die 0, .dropped .a, .dropped .b, .pair, .adopt .a, .adopt .b, .quit .a, .deliver .b 1])
      (fun s => view s .b == .playing) = true ∧
    witnesses .web (handshake ++
      [.die 0, .dropped .a, .dropped .b, .pair, .adopt .a, .adopt .b, .quit .a, .deliver .b 1,
       .deliver .b 1])
      (fun s => view s .b == .ended .peerBye) = true := by
  decide

/-- The host deals the retry code when the session starts; until B's echo
    is back (a round trip), only B can resume. A drop in that window ends
    A ("Peer connection lost") while B redials alone for 180 s. -/
theorem start_window_one_sided :
    witnesses .web [.deliver .b 0, .die 0, .dropped .a, .dropped .b]
      (fun s => view s .a == .ended .lost && view s .b == .reconnecting 0) = true := by
  decide

/-- With the goodbye note: A, which holds the code it dealt, leaves a
    "gave-up" note as it ends; B's first rendezvous gets it ("Couldn't
    reconnect") instead of 180 s alone. -/
theorem regress_start_window_heard :
    witnesses .webNote [.deliver .b 0, .die 0, .dropped .a, .dropped .b, .noteIn .b]
      (fun s => view s .a == .ended .lost && view s .b == .ended .gaveUp) = true := by
  decide

/-- The two sides' give-up clocks drift. Both redial at 0 s; at 100 s A
    reads B's RESUME and resumes, but the new channel dies before A's RESUME
    reaches B, and the network stays down. A starts a fresh 180 s; B, still
    on its first, runs out at 180 s ("Couldn't reconnect"), and A keeps
    showing "Reconnecting…" alone until 280 s. -/
theorem give_up_clocks_drift :
    witnesses .web (handshake ++
      [.die 0, .dropped .a, .dropped .b, .tick 100, .pair, .adopt .a, .adopt .b, .deliver .a 1,
       .die 1, .dropped .a, .restart .b, .tick 80, .giveUp .b])
      (fun s => view s .b == .ended .gaveUp && view s .a == .reconnecting 100 &&
                s.now == 180 && !en .web s (.giveUp .a)) = true := by
  decide

/-- With the goodbye note, B's give-up leaves a "gave-up" note: A's next
    rendezvous gets it, and A ends at 180 s too ("Couldn't reconnect"). -/
theorem regress_give_up_clocks_drift :
    witnesses .webNote (handshake ++
      [.die 0, .dropped .a, .dropped .b, .tick 100, .pair, .adopt .a, .adopt .b, .deliver .a 1,
       .die 1, .dropped .a, .restart .b, .tick 80, .giveUp .b, .noteIn .a])
      (fun s => view s .b == .ended .gaveUp && view s .a == .ended .gaveUp && s.now == 180) = true := by
  decide

/-- A side whose 180 s run out just after its new channel opened says BYE
    on it; a friend that just resumed on that channel reads "Peer
    disconnected", as if Disconnect had been pressed. -/
theorem give_up_reads_as_disconnect :
    witnesses .web (handshake ++
      [.die 0, .dropped .a, .dropped .b, .tick 179, .pair, .adopt .a, .adopt .b, .deliver .a 1,
       .tick 1, .giveUp .b, .deliver .a 1])
      (fun s => view s .b == .ended .gaveUp && view s .a == .ended .peerBye) = true := by
  decide

/-- The "Trying for m:ss" clocks differ: each counts from its own side's
    notice of the drop. -/
theorem reconnect_clocks_differ :
    witnesses .web (handshake ++ [.die 0, .dropped .a, .tick 16, .dropped .b])
      (fun s => view s .a == .reconnecting 0 && view s .b == .reconnecting 16) = true := by
  decide

/-- Paused together for more than 180 s, nothing crosses the link; a drop
    then reads as a friend silent past its give-up, and both end ("Peer
    connection lost") without a redial. -/
theorem bug_long_quiet_then_drop_ends :
    witnesses .web (handshake ++ [.toggle .a, .deliver .b 0, .tick 200, .die 0, .dropped .a, .dropped .b])
      (fun s => view s .a == .ended .lost && view s .b == .ended .lost) = true := by
  decide

/-- With the keepalive (a ping every 20 s while live), the same drop
    redials on both sides. -/
theorem regress_long_quiet_keepalive :
    witnesses .webFix (handshake ++ [.toggle .a, .deliver .b 0] ++
      (List.replicate 10 [.tick 20, .ping .a, .ping .b, .deliver .a 0, .deliver .b 0]).flatten ++
      [.die 0, .dropped .a, .dropped .b])
      (fun s => view s .a == .reconnecting 200 && view s .b == .reconnecting 200) = true := by
  decide

/-! ## Invariants: the inputs

What the friend receives is exactly what was sent: every input that
arrives is the next frame the side needs, never one past it (a gap would
stall the window for good, or desync) and never one it has (wasted). The
argument is a pipe: on the channel both hold, the inputs in flight to a side
(and queued before its open) are the frames from its `lastRx + 1` on, in
order, up to what the friend has sent. A redialing side sends no inputs on
its new channel, so the friend's `lastRx` in its RESUME is still exact when
it arrives, and the resend from the log refills the pipe. -/

def Msg.frame? : Msg → Option Nat
  | .inp f => some f
  | _ => none

def insOf (l : List Msg) : List Nat := l.filterMap Msg.frame?

/-- The fields of a side the input argument reads. -/
structure Core where
  ph     : Ph
  dc     : Option Nat
  rsPc   : Option Nat
  rsOpen : Bool
  early  : List Msg
  sent   : Nat
  rx     : Nat
  gap    : Bool
  dup    : Bool

def Side.core (x : Side) : Core := ⟨x.ph, x.dc, x.rsPc, x.rsOpen, x.early, x.sent, x.rx, x.gap, x.dup⟩

section inv
variable (cs : Cl → Core) (ch : Nat → Chan) (n : Nat)

/-- c holds channel k: its open channel, or the pairing it is opening. -/
def hdC (c : Cl) (k : Nat) : Prop := (cs c).dc = some k ∨ (cs c).rsPc = some k

/-- What is on its way to c on channel k: queued before the open, then in flight. -/
def inbC (c : Cl) (k : Nat) : List Msg :=
  (if (cs c).rsPc = some k then (cs c).early else []) ++ (ch k).q c

structure InvC : Prop where
  liveSh   : ∀ c, (cs c).ph = .live → (cs c).rsPc = none ∧ (cs c).dc ≠ none
  endSh    : ∀ c, (cs c).ph = .ended → (cs c).dc = none ∧ (cs c).rsPc = none
  reconDc  : ∀ c k, (cs c).ph = .recon → (cs c).dc = some k →
               (cs c).rsPc = some k ∧ (cs c).rsOpen = true
  reconOpen : ∀ c, (cs c).ph = .recon → (cs c).dc = none → (cs c).rsOpen = false
  earlySh  : ∀ c, (cs c).early ≠ [] → (cs c).dc = none ∧ (cs c).rsPc ≠ none
  hold     : ∀ c k, hdC cs c k → k < n ∧ (ch k).closed c = false
  same     : ∀ c k j, hdC cs c k → hdC cs c.other j → k = j
  fresh    : ∀ k, n ≤ k → (ch k).dead = false ∧ ∀ c, (ch k).q c = [] ∧ (ch k).closed c = false
  deadQ    : ∀ k c, (ch k).dead = true → (ch k).q c = []
  rxLe     : ∀ c, (cs c).rx ≤ (cs c.other).sent
  win      : ∀ c, (cs c).sent ≤ (cs c).rx + W
  /-- The pipe. -/
  pipe     : ∀ c k, hdC cs c k → ∃ m, insOf (inbC cs ch c k) = List.range' (cs c).rx m ∧
               (cs c).rx + m ≤ (cs c.other).sent ∧
               ((cs c.other).ph = .live → (cs c.other).dc = some k → (ch k).dead = false →
                 (cs c).rx + m = (cs c.other).sent)
  /-- A redialing side has sent no inputs on the channel it holds. -/
  quiet    : ∀ c k, (cs c).ph = .recon → hdC cs c k → insOf (inbC cs ch c.other k) = []
  /-- Nothing is sent on a channel before it opens on the sender. -/
  silent   : ∀ c k, hdC cs c k → (cs c).dc ≠ some k → inbC cs ch c.other k = []
  /-- No input reaches a side before its channel opens. -/
  preOpen  : ∀ c k, hdC cs c k → (cs c).dc ≠ some k → insOf (inbC cs ch c k) = []
  /-- A side live on a channel the friend holds has had the friend's RESUME on it. -/
  liveOpen : ∀ c k, (cs c).ph = .live → (cs c).dc = some k → hdC cs c.other k →
               (cs c.other).dc = some k
  /-- A RESUME still on its way to a redialing side carries the sender's `lastRx`. -/
  resT     : ∀ c k t p a, Msg.resume t p a ∈ inbC cs ch c k → (cs c).ph = .recon → hdC cs c k →
               t = (cs c.other).rx
  noGap    : ∀ c, (cs c).gap = false ∧ (cs c).dup = false

end inv

def State.cs (s : State) : Cl → Core := fun c => (s.sd c).core

def Inv (s : State) : Prop := InvC s.cs s.ch s.nextCh

def holdsC (s : State) (c : Cl) (k : Nat) : Prop := hdC s.cs c k
def inb (s : State) (c : Cl) (k : Nat) : List Msg := inbC s.cs s.ch c k

section simps
variable (s : State) (c d : Cl) (k j : Nat) (f : Side → Side) (g : Chan → Chan) (x : Side)

@[simp] theorem core_ph : x.core.ph = x.ph := rfl
@[simp] theorem core_dc : x.core.dc = x.dc := rfl
@[simp] theorem core_rsPc : x.core.rsPc = x.rsPc := rfl
@[simp] theorem core_rsOpen : x.core.rsOpen = x.rsOpen := rfl
@[simp] theorem core_early : x.core.early = x.early := rfl
@[simp] theorem core_sent : x.core.sent = x.sent := rfl
@[simp] theorem core_rx : x.core.rx = x.rx := rfl
@[simp] theorem core_gap : x.core.gap = x.gap := rfl
@[simp] theorem core_dup : x.core.dup = x.dup := rfl
theorem cs_apply : s.cs c = (s.sd c).core := rfl

@[simp] theorem updS_sd : (updS c f s).sd d = if d = c then f (s.sd d) else s.sd d := rfl
@[simp] theorem updS_ch : (updS c f s).ch = s.ch := rfl
@[simp] theorem updS_nextCh : (updS c f s).nextCh = s.nextCh := rfl
@[simp] theorem updS_now : (updS c f s).now = s.now := rfl
@[simp] theorem updCh_sd : (updCh k g s).sd = s.sd := rfl
@[simp] theorem updCh_ch : (updCh k g s).ch j = if j = k then g (s.ch j) else s.ch j := rfl
@[simp] theorem updCh_nextCh : (updCh k g s).nextCh = s.nextCh := rfl
@[simp] theorem updCh_now : (updCh k g s).now = s.now := rfl

end simps

@[simp] theorem insOf_nil : insOf [] = [] := rfl
@[simp] theorem insOf_append (l l' : List Msg) : insOf (l ++ l') = insOf l ++ insOf l' := by
  simp [insOf, List.filterMap_append]
@[simp] theorem insOf_cons_inp (f : Nat) (l : List Msg) : insOf (.inp f :: l) = f :: insOf l := rfl
theorem insOf_cons_other (m : Msg) (l : List Msg) (h : m.frame? = none) :
    insOf (m :: l) = insOf l := by
  simp [insOf, List.filterMap_cons, h]
@[simp] theorem insOf_singleton_other (m : Msg) (h : m.frame? = none) : insOf [m] = [] := by
  simp [insOf, List.filterMap_cons, h]
@[simp] theorem insOf_frames (t n : Nat) : insOf (frames t n) = List.range' t (n - t) := by
  unfold insOf frames
  induction (List.range' t (n - t)) with
  | nil => rfl
  | cons x xs ih => simp [List.filterMap_cons, Msg.frame?, ih]

/-- Two states whose sides agree on the core fields and whose channels agree
    satisfy the invariant alike. -/
theorem Inv.congr {s t : State} (hc : ∀ c, (t.sd c).core = (s.sd c).core) (hch : t.ch = s.ch)
    (hn : t.nextCh = s.nextCh) (h : Inv s) : Inv t := by
  have : t.cs = s.cs := funext hc
  unfold Inv at *
  rw [this, hch, hn]
  exact h

/-- Updating fields of a side outside the core keeps the invariant. -/
theorem Inv.updS_noncore {s : State} {c : Cl} {f : Side → Side} (hf : ∀ y, (f y).core = y.core)
    (h : Inv s) : Inv (updS c f s) := by
  refine Inv.congr (s := s) (t := updS c f s) (fun d => ?_) rfl rfl h
  simp only [updS_sd]
  split <;> simp [hf]

theorem inv_init : Inv init := by
  have h0 : ∀ c, (init.sd c).dc = some 0 ∧ (init.sd c).rsPc = none ∧ (init.sd c).early = [] ∧
      (init.sd c).ph = .live ∧ (init.sd c).sent = 0 ∧ (init.sd c).rx = 0 ∧
      (init.sd c).gap = false ∧ (init.sd c).dup = false ∧ (init.sd c).rsOpen = false := by
    intro c; cases c <;> simp [init]
  have hd : ∀ c k, hdC init.cs c k ↔ k = 0 := by
    intro c k; simp [hdC, cs_apply, h0, eq_comm]
  have hq : ∀ c, insOf ((init.ch 0).q c) = [] := by
    intro c; cases c <;> simp [init, insOf, Msg.frame?]
  have hres : ∀ c t p a, Msg.resume t p a ∉ (init.ch 0).q c := by
    intro c; cases c <;> simp [init]
  constructor
  · intro c h; simp [cs_apply, h0]
  · intro c h; simp [cs_apply, h0] at h
  · intro c k h; simp [cs_apply, h0] at h
  · intro c h; simp [cs_apply, h0] at h
  · intro c h; simp [cs_apply, h0] at h
  · intro c k h; rw [hd] at h; subst h; cases c <;> simp [init]
  · intro c k j h1 h2; rw [hd] at h1 h2; omega
  · intro k hk; have : k ≠ 0 := by simp [init] at hk; omega
    simp [init, this]
  · intro k c h; by_cases hk : k = 0 <;> simp [init, hk] at h
  · intro c; simp [cs_apply, h0]
  · intro c; simp [cs_apply, h0, W]
  · intro c k h; rw [hd] at h; subst h
    exact ⟨0, by simp [inbC, cs_apply, h0, hq], by simp [cs_apply, h0], by simp [cs_apply, h0]⟩
  · intro c k h; simp [cs_apply, h0] at h
  · intro c k h1 h2; rw [hd] at h1; subst h1; simp [cs_apply, h0] at h2
  · intro c k h1 h2; rw [hd] at h1; subst h1; simp [cs_apply, h0] at h2
  · intro c k h1 h2 h3; rw [hd] at h3; subst h3; simp [cs_apply, h0]
  · intro c k t p a h1 h2; simp [cs_apply, h0] at h2
  · intro c; simp [cs_apply, h0]

/-! ### Sending -/

/-- Messages `ms` join the queue to `d` on channel `k`. -/
def appendQ (k : Nat) (d : Cl) (ms : List Msg) (s : State) : State :=
  updCh k (fun x => { x with q := fun e => if e = d then x.q e ++ ms else x.q e }) s

@[simp] theorem updCh_cs (s : State) (k : Nat) (g : Chan → Chan) : (updCh k g s).cs = s.cs := rfl
@[simp] theorem appendQ_sd (s : State) (k : Nat) (d : Cl) (ms : List Msg) :
    (appendQ k d ms s).sd = s.sd := rfl
@[simp] theorem appendQ_cs (s : State) (k : Nat) (d : Cl) (ms : List Msg) :
    (appendQ k d ms s).cs = s.cs := rfl
@[simp] theorem appendQ_nextCh (s : State) (k : Nat) (d : Cl) (ms : List Msg) :
    (appendQ k d ms s).nextCh = s.nextCh := rfl
@[simp] theorem appendQ_now (s : State) (k : Nat) (d : Cl) (ms : List Msg) :
    (appendQ k d ms s).now = s.now := rfl
@[simp] theorem appendQ_dead (s : State) (k j : Nat) (d : Cl) (ms : List Msg) :
    ((appendQ k d ms s).ch j).dead = (s.ch j).dead := by
  simp [appendQ]; split <;> rfl
@[simp] theorem appendQ_closed (s : State) (k j : Nat) (d : Cl) (ms : List Msg) :
    ((appendQ k d ms s).ch j).closed = (s.ch j).closed := by
  simp [appendQ]; split <;> rfl
theorem appendQ_q (s : State) (k j : Nat) (d e : Cl) (ms : List Msg) :
    ((appendQ k d ms s).ch j).q e = if j = k ∧ e = d then (s.ch j).q e ++ ms else (s.ch j).q e := by
  simp only [appendQ, updCh_ch]
  by_cases hj : j = k <;> by_cases he : e = d <;> simp [hj, he]

theorem inbC_appendQ (s : State) (k j : Nat) (d e : Cl) (ms : List Msg) :
    inbC s.cs (appendQ k d ms s).ch e j =
      if j = k ∧ e = d then inbC s.cs s.ch e j ++ ms else inbC s.cs s.ch e j := by
  unfold inbC
  rw [appendQ_q]
  by_cases h : j = k ∧ e = d <;> simp [h]

/-- `send` either drops the message or appends it to the friend's queue on
    c's open, live channel. -/
theorem send_cases (c : Cl) (m : Msg) (s : State) :
    send c m s = s ∨ ∃ k, (s.sd c).dc = some k ∧ (s.ch k).dead = false ∧
      (s.ch k).closed c = false ∧ send c m s = appendQ k c.other [m] s := by
  unfold send
  split
  · rename_i k hk
    split
    · exact Or.inl rfl
    · rename_i hc
      simp only [Bool.or_eq_true, not_or, Bool.not_eq_true] at hc
      exact Or.inr ⟨k, hk, hc.1, hc.2, rfl⟩
  · exact Or.inl rfl

/-- Appending messages that are neither inputs nor RESUMEs, on the
    sender's open channel, keeps the invariant. -/
theorem Inv.appendQ_misc {s : State} {k : Nat} {d : Cl} {ms : List Msg} (h : Inv s)
    (hdc : (s.sd d.other).dc = some k) (hdead : (s.ch k).dead = false)
    (hins : insOf ms = []) (hres : ∀ t p a, Msg.resume t p a ∉ ms) : Inv (appendQ k d ms s) := by
  have hk : k < s.nextCh := (h.hold d.other k (Or.inl (by simpa [cs_apply] using hdc))).1
  unfold Inv at *
  simp only [appendQ_cs, appendQ_nextCh]
  obtain ⟨h1, h2, h3, h4, h5, hhold, hsame, hfresh, hdeadQ, h10, h11, hpipe, hquiet, hsilent,
    hpre, hlive, hresT, h18⟩ := h
  refine ⟨h1, h2, h3, h4, h5, ?_, hsame, ?_, ?_, h10, h11, ?_, ?_, ?_, ?_, hlive, ?_, h18⟩
  · intro c j hc; simpa using hhold c j hc
  · intro j hj
    have hne : j ≠ k := by omega
    obtain ⟨a1, a2⟩ := hfresh j hj
    refine ⟨by simpa using a1, fun c => ?_⟩
    rw [appendQ_q]; simp [hne, a2 c]
  · intro j c hj
    rw [appendQ_dead] at hj
    rw [appendQ_q]
    by_cases hjk : j = k
    · subst hjk; simp [hdead] at hj
    · simp [hjk, hdeadQ j c hj]
  · intro c j hc
    obtain ⟨m, a1, a2, a3⟩ := hpipe c j hc
    refine ⟨m, ?_, a2, by simpa using a3⟩
    rw [inbC_appendQ]; split <;> simp [a1, hins]
  · intro c j hr hc
    rw [inbC_appendQ]; split <;> simp [hquiet c j hr hc, hins]
  · intro c j hc hne
    rw [inbC_appendQ]
    split
    · rename_i hjk
      obtain ⟨rfl, he⟩ := hjk
      have : c = d.other := by rw [← he]; simp
      subst this; exact absurd hdc hne
    · exact hsilent c j hc hne
  · intro c j hc hne
    rw [inbC_appendQ]; split <;> simp [hpre c j hc hne, hins]
  · intro c j t p a hm hr hc
    rw [inbC_appendQ] at hm
    split at hm
    · simp only [List.mem_append] at hm
      rcases hm with hm | hm
      · exact hresT c j t p a hm hr hc
      · exact absurd hm (hres t p a)
    · exact hresT c j t p a hm hr hc

theorem Inv.send_misc {s : State} {c : Cl} {m : Msg} (h : Inv s) (hm : m.frame? = none)
    (hr : m.isResume = false) : Inv (send c m s) := by
  rcases send_cases c m s with e | ⟨k, hk, hdead, _, e⟩
  · rw [e]; exact h
  · rw [e]
    refine h.appendQ_misc (d := c.other) (by simpa using hk) hdead (by simp [hm]) ?_
    intro t p a hmem
    simp at hmem; subst hmem; simp [Msg.isResume] at hr

theorem Inv.sendAll_misc {s : State} {c : Cl} {ms : List Msg} (h : Inv s)
    (hm : ∀ m ∈ ms, m.frame? = none ∧ m.isResume = false) : Inv (sendAll c ms s) := by
  induction ms generalizing s with
  | nil => exact h
  | cons m ms ih =>
    simp only [sendAll]
    have := hm m (by simp)
    exact ih (h.send_misc this.1 this.2) (fun x hx => hm x (by simp [hx]))

/-! ### Pause, away, and the other fields outside the core -/

theorem Inv.press {s : State} {c : Cl} {p : Bool} (h : Inv s) : Inv (press c p s) := by
  unfold LinkResume.press
  exact (h.send_misc rfl rfl).updS_noncore (fun y => rfl)

theorem Inv.setPaused {s : State} {c : Cl} {p r : Bool} (h : Inv s) : Inv (setPaused c p r s) := by
  unfold LinkResume.setPaused
  split
  · exact h
  · have h' : Inv (updS c (fun y => { y with paused := p, pfb := false }) s) :=
      h.updS_noncore (fun y => rfl)
    dsimp only
    split
    · exact h'.press
    · exact h'

theorem Inv.remotePause {s : State} {c : Cl} {v : Bool} (h : Inv s) : Inv (remotePause c v s) :=
  h.setPaused

theorem Inv.pauseAfterResume {s : State} {cfg : Cfg} {c : Cl} {p a : Bool} (h : Inv s) :
    Inv (pauseAfterResume cfg c p a s) := by
  unfold LinkResume.pauseAfterResume
  split
  · dsimp only
    split
    · have h1 : Inv (updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) s) :=
        h.updS_noncore (fun y => rfl)
      split
      · exact h1.press
      · exact h1
    · exact h.remotePause
  · have : Inv (if !p && (s.sd c).paused && !(cfg.iosB && c == .b && (s.sd c).away) then
        LinkResume.remotePause c false s else s) := by
      split
      · exact h.remotePause
      · exact h
    exact this.send_misc rfl rfl

theorem Inv.setAway {s : State} {cfg : Cfg} {c : Cl} {on : Bool} (h : Inv s) :
    Inv (setAway cfg c on s) := by
  unfold LinkResume.setAway
  have h' := h.updS_noncore (c := c)
    (f := fun y => { y with away := on, livePress := y.livePress || y.ph == .live }) (fun y => rfl)
  simp only
  split
  · exact h'
  · split
    · split
      · exact h'
      · exact (h'.setPaused).updS_noncore (fun y => rfl)
    · split
      · exact (h'.updS_noncore (f := fun y => { y with pfb := false }) (fun y => rfl)).setPaused
      · exact h'

/-! ### Letting go of a channel -/

section detach
variable (s : State) (c e : Cl) (k j : Nat)

@[simp] theorem closeEnd_sd : (closeEnd c k s).sd = s.sd := rfl
@[simp] theorem closeEnd_cs : (closeEnd c k s).cs = s.cs := rfl
@[simp] theorem closeEnd_nextCh : (closeEnd c k s).nextCh = s.nextCh := rfl
@[simp] theorem closeEnd_now : (closeEnd c k s).now = s.now := rfl
@[simp] theorem closeEnd_q : ((closeEnd c k s).ch j).q = (s.ch j).q := by
  simp [closeEnd]; split <;> rfl
@[simp] theorem closeEnd_dead : ((closeEnd c k s).ch j).dead = (s.ch j).dead := by
  simp [closeEnd]; split <;> rfl
theorem closeEnd_closed : ((closeEnd c k s).ch j).closed e =
    if j = k ∧ e = c then true else (s.ch j).closed e := by
  simp only [closeEnd, updCh_ch]
  by_cases hj : j = k <;> by_cases he : e = c <;> simp [hj, he]
theorem closeEnd_ch_ne (h : j ≠ k) : (closeEnd c k s).ch j = s.ch j := by
  simp [closeEnd, h]

/-- What `detach` leaves of the channels: the same queues and deaths, and
    c's ends closed on what it held. -/
theorem detach_parts : (detach c s).nextCh = s.nextCh ∧ (detach c s).now = s.now ∧
    (∀ j, ((detach c s).ch j).q = (s.ch j).q) ∧ (∀ j, ((detach c s).ch j).dead = (s.ch j).dead) ∧
    (∀ j e, e ≠ c → ((detach c s).ch j).closed e = (s.ch j).closed e) ∧
    (∀ j, ¬ hdC s.cs c j → (detach c s).ch j = s.ch j) ∧
    (detach c s).sd c = { s.sd c with rsPc := none, rsOpen := false, early := [], dc := none } ∧
    (detach c s).sd c.other = s.sd c.other := by
  unfold detach
  cases hr : (s.sd c).rsPc <;> cases hd : (s.sd c).dc <;>
    simp [closeEnd_closed, closeEnd_ch_ne, hdC, cs_apply, hr, hd] <;>
    (try refine ⟨?_, ?_⟩) <;> (try intros) <;> (try (split <;> simp_all)) <;>
    (try simp_all [closeEnd_closed, closeEnd_ch_ne, cs_apply, eq_comm])
end detach

theorem inbC_suffix (cs : Cl → Core) (ch : Nat → Chan) (c : Cl) (k : Nat) :
    ∃ pre, inbC cs ch c k = pre ++ (ch k).q c := ⟨_, rfl⟩

theorem insOf_eq_nil_of_suffix {pre l : List Msg} (h : insOf (pre ++ l) = []) : insOf l = [] := by
  simp at h; exact h.2

/-- c lets go of its channel and pairing, and is no longer live. -/
theorem Inv.release {s : State} {c : Cl} {f : Side → Side} {p : Ph} (h : Inv s) (hp : p ≠ .live)
    (hf : ∀ y, (f y).core = { y.core with ph := p }) : Inv (updS c f (detach c s)) := by
  obtain ⟨hn, -, hq, hdead, hclosed, -, hsc, hso⟩ := detach_parts s c
  have tc : (updS c f (detach c s)).cs c =
      { s.cs c with ph := p, dc := none, rsPc := none, rsOpen := false, early := [] } := by
    show ((updS c f (detach c s)).sd c).core = _
    rw [updS_sd, if_pos rfl, hf, hsc]; rfl
  have to : (updS c f (detach c s)).cs c.other = s.cs c.other := by
    show ((updS c f (detach c s)).sd c.other).core = (s.sd c.other).core
    rw [updS_sd, if_neg (Cl.other_ne c), hso]
  have tq : ∀ j e, ((updS c f (detach c s)).ch j).q e = (s.ch j).q e := by simp [hq]
  have hdc : ∀ j, ¬ hdC (updS c f (detach c s)).cs c j := by intro j; rw [hdC, tc]; simp
  have hdo : ∀ j, hdC (updS c f (detach c s)).cs c.other j ↔ hdC s.cs c.other j := by
    intro j; rw [hdC, hdC, to]
  have ibo : ∀ j, inbC (updS c f (detach c s)).cs (updS c f (detach c s)).ch c.other j =
      inbC s.cs s.ch c.other j := by
    intro j; rw [inbC, inbC, to, tq]
  have ibc : ∀ j, inbC (updS c f (detach c s)).cs (updS c f (detach c s)).ch c j = (s.ch j).q c := by
    intro j; rw [inbC, tc, tq]; simp
  unfold Inv at *
  obtain ⟨h1, h2, h3, h4, h5, hhold, hsame, hfresh, hdeadQ, h10, h11, hpipe, hquiet, hsilent,
    hpre, hlive, hresT, h18⟩ := h
  rw [updS_nextCh, hn]
  constructor
  · intro e he; rcases Cl.eq_or c e with rfl | rfl
    · simp [tc] at he; exact absurd he hp
    · rw [to] at he ⊢; exact h1 _ he
  · intro e he; rcases Cl.eq_or c e with rfl | rfl
    · simp [tc]
    · rw [to] at he ⊢; exact h2 _ he
  · intro e k he hk; rcases Cl.eq_or c e with rfl | rfl
    · simp [tc] at hk
    · rw [to] at he hk ⊢; exact h3 _ k he hk
  · intro e he hk; rcases Cl.eq_or c e with rfl | rfl
    · simp [tc]
    · rw [to] at he hk ⊢; exact h4 _ he hk
  · intro e he; rcases Cl.eq_or c e with rfl | rfl
    · simp [tc] at he
    · rw [to] at he ⊢; exact h5 _ he
  · intro e k he; rcases Cl.eq_or c e with rfl | rfl
    · exact absurd he (hdc k)
    · rw [hdo] at he
      obtain ⟨a1, a2⟩ := hhold _ k he
      exact ⟨a1, by rw [updS_ch, hclosed k _ (Cl.other_ne c)]; exact a2⟩
  · intro e k j he hj; rcases Cl.eq_or c e with rfl | rfl
    · exact absurd he (hdc k)
    · simp only [Cl.other_other] at hj; exact absurd hj (hdc j)
  · intro k hk
    obtain ⟨a1, a2⟩ := hfresh k hk
    refine ⟨by rw [updS_ch, hdead]; exact a1, fun e => ⟨by rw [tq]; exact (a2 e).1, ?_⟩⟩
    rcases Cl.eq_or c e with rfl | rfl
    · have : ¬ hdC s.cs e k := fun hh => by have := (hhold e k hh).1; omega
      obtain ⟨-, -, -, -, -, hnh, -, -⟩ := detach_parts s e
      simp [hnh k this, (a2 e).2]
    · simp [hclosed k _ (Cl.other_ne c), (a2 _).2]
  · intro k e hk; simp only [updS_ch] at hk ⊢; rw [hdead] at hk; rw [hq]; exact hdeadQ k e hk
  · intro e; rcases Cl.eq_or c e with rfl | rfl
    · rw [tc]; simpa [to] using h10 e
    · rw [to]; have := h10 c.other; simp only [Cl.other_other] at this; simpa [tc] using this
  · intro e; rcases Cl.eq_or c e with rfl | rfl
    · rw [tc]; exact h11 e
    · rw [to]; exact h11 _
  · intro e k he; rcases Cl.eq_or c e with rfl | rfl
    · exact absurd he (hdc k)
    · rw [hdo] at he
      obtain ⟨m, a1, a2, a3⟩ := hpipe _ k he
      refine ⟨m, by rw [ibo, to]; exact a1, by simpa [to, tc] using a2, ?_⟩
      intro hl; simp only [Cl.other_other, tc] at hl; exact absurd hl hp
  · intro e k he hk; rcases Cl.eq_or c e with rfl | rfl
    · exact absurd hk (hdc k)
    · rw [hdo] at hk; rw [to] at he
      simp only [Cl.other_other, ibc]
      have := hquiet _ k he hk; simp only [Cl.other_other, inbC] at this
      exact insOf_eq_nil_of_suffix this
  · intro e k he hne; rcases Cl.eq_or c e with rfl | rfl
    · exact absurd he (hdc k)
    · rw [hdo] at he; rw [to] at hne
      simp only [Cl.other_other, ibc]
      have := hsilent _ k he hne
      simp only [Cl.other_other, inbC, List.append_eq_nil_iff] at this
      exact this.2
  · intro e k he hne; rcases Cl.eq_or c e with rfl | rfl
    · exact absurd he (hdc k)
    · rw [hdo] at he; rw [to] at hne; rw [ibo]; exact hpre _ k he hne
  · intro e k he hk ho; rcases Cl.eq_or c e with rfl | rfl
    · simp [tc] at he; exact absurd he hp
    · simp only [Cl.other_other] at ho; exact absurd ho (hdc k)
  · intro e k t' p' a' hm he hk; rcases Cl.eq_or c e with rfl | rfl
    · exact absurd hk (hdc k)
    · rw [hdo] at hk; rw [to] at he; rw [ibo] at hm
      simp only [Cl.other_other, tc]
      have := hresT _ k t' p' a' hm he hk
      simpa using this
  · intro e; rcases Cl.eq_or c e with rfl | rfl
    · rw [tc]; exact h18 e
    · rw [to]; exact h18 _

theorem Inv.finish {s : State} {c : Cl} {w : End} (h : Inv s) : Inv (finish c w s) :=
  h.release (p := .ended) (by decide) (fun y => rfl)

theorem Inv.leaveNote {s : State} {c : Cl} {w : End} {x : Side} (h : Inv s) :
    Inv (leaveNote c w x s) := by
  unfold LinkResume.leaveNote; split
  · exact Inv.congr (s := s) (fun _ => rfl) rfl rfl h
  · exact h

theorem Inv.shutdown {s : State} {c : Cl} {w : End} (h : Inv s) : Inv (shutdown c w s) := by
  unfold LinkResume.shutdown
  refine Inv.leaveNote ?_
  split
  · exact h.finish
  · exact (h.send_misc rfl rfl).finish

theorem Inv.restart {s : State} {c : Cl} (h : Inv s) (hr : (s.sd c).ph = .recon) :
    Inv (restart c s) := by
  unfold LinkResume.restart
  split
  · exact h.shutdown
  · have h' := h.release (c := c) (p := .recon) (f := fun y => { y with ph := .recon }) (by decide)
      (fun y => rfl)
    refine Inv.congr (s := updS c (fun y => { y with ph := .recon }) (detach c s)) (t := detach c s)
      ?_ rfl rfl h'
    intro d
    obtain ⟨-, -, -, -, -, -, hsc, hso⟩ := detach_parts s c
    rcases Cl.eq_or c d with rfl | rfl
    · simp [hsc, Side.core, hr]
    · simp [hso]

theorem Inv.dropped {s : State} {c : Cl} (h : Inv s) : Inv (dropped c s) := by
  unfold LinkResume.dropped
  dsimp only
  split
  · split
    · rename_i hr
      exact h.restart (by simpa using hr)
    · split
      · exact h.shutdown
      · exact h.release (p := .recon) (by decide) (fun y => rfl)
  · exact h.shutdown

theorem updS_congr {s : State} {c : Cl} {f g : Side → Side} (h : f (s.sd c) = g (s.sd c)) :
    updS c f s = updS c g s := by
  unfold updS; congr 1; funext d; split <;> simp_all

theorem updS_cs (s : State) (c e : Cl) (f : Side → Side) :
    (updS c f s).cs e = if e = c then (f (s.sd c)).core else s.cs e := by
  simp only [cs_apply, updS_sd]; split <;> simp_all

/-- A frame produced and not sent: held while redialing, or lost on a dead
    channel. -/
theorem Inv.bumpSent {s : State} {c : Cl} (h : Inv s) (hw : (s.sd c).sent < (s.sd c).rx + W)
    (hq : (s.sd c).ph = .live → ∀ k, (s.sd c).dc = some k → (s.ch k).dead = true) :
    Inv (updS c (fun y => { y with sent := y.sent + 1 }) s) := by
  have tc : ∀ e, (updS c (fun y => { y with sent := y.sent + 1 }) s).cs e =
      if e = c then { s.cs c with sent := (s.cs c).sent + 1 } else s.cs e := by
    intro e; rw [updS_cs]; split <;> rfl
  have tf : ∀ e, ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).ph = (s.cs e).ph ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).dc = (s.cs e).dc ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).rsPc = (s.cs e).rsPc ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).rsOpen = (s.cs e).rsOpen ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).early = (s.cs e).early ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).rx = (s.cs e).rx ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).gap = (s.cs e).gap ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).dup = (s.cs e).dup ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).sent =
        (s.cs e).sent + (if e = c then 1 else 0) := by
    intro e; rw [tc]; by_cases he : e = c
    · subst he; simp
    · simp [he]
  have thd : ∀ e j, hdC (updS c (fun y => { y with sent := y.sent + 1 }) s).cs e j ↔ hdC s.cs e j := by
    intro e j; simp only [hdC, (tf e).2.1, (tf e).2.2.1]
  have tib : ∀ e j, inbC (updS c (fun y => { y with sent := y.sent + 1 }) s).cs s.ch e j =
      inbC s.cs s.ch e j := by
    intro e j; simp only [inbC, (tf e).2.2.1, (tf e).2.2.2.2.1]
  unfold Inv at *
  obtain ⟨h1, h2, h3, h4, h5, hhold, hsame, hfresh, hdeadQ, h10, h11, hpipe, hquiet, hsilent,
    hpre, hlive, hresT, h18⟩ := h
  simp only [updS_ch, updS_nextCh]
  constructor
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1]; exact h1 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1]; exact h2 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1, (tf e).2.2.2.1]; exact h3 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.2.1]; exact h4 e
  · intro e; simp only [(tf e).2.2.2.2.1, (tf e).2.1, (tf e).2.2.1]; exact h5 e
  · intro e j; rw [thd]; exact hhold e j
  · intro e j i; rw [thd, thd]; exact hsame e j i
  · exact hfresh
  · exact hdeadQ
  · intro e; rw [(tf e).2.2.2.2.2.1, (tf e.other).2.2.2.2.2.2.2.2]
    have := h10 e; omega
  · intro e; rw [(tf e).2.2.2.2.2.1, (tf e).2.2.2.2.2.2.2.2]
    have := h11 e
    by_cases he : e = c
    · subst he; simp only [if_true, cs_apply, core_rx, core_sent] at hw this ⊢; omega
    · simp only [he, if_false, Nat.add_zero]; omega
  · intro e j hj
    rw [thd] at hj
    obtain ⟨m, a1, a2, a3⟩ := hpipe e j hj
    refine ⟨m, ?_, ?_, ?_⟩
    · rw [tib, (tf e).2.2.2.2.2.1]; exact a1
    · rw [(tf e).2.2.2.2.2.1, (tf e.other).2.2.2.2.2.2.2.2]; omega
    · intro hl hd hdd
      rw [(tf e.other).1] at hl; rw [(tf e.other).2.1] at hd
      rw [(tf e).2.2.2.2.2.1, (tf e.other).2.2.2.2.2.2.2.2]
      by_cases he : e.other = c
      · have := hq (by rw [← he]; simpa [cs_apply] using hl) j (by rw [← he]; simpa [cs_apply] using hd)
        rw [this] at hdd; cases hdd
      · simp only [he, if_false, Nat.add_zero]; exact a3 hl hd hdd
  · intro e j hr hj; rw [(tf e).1] at hr; rw [thd] at hj; rw [tib]; exact hquiet e j hr hj
  · intro e j hj hne; rw [thd] at hj; rw [(tf e).2.1] at hne; rw [tib]; exact hsilent e j hj hne
  · intro e j hj hne; rw [thd] at hj; rw [(tf e).2.1] at hne; rw [tib]; exact hpre e j hj hne
  · intro e j hl hd ho
    rw [(tf e).1] at hl; rw [(tf e).2.1] at hd; rw [thd] at ho; rw [(tf e.other).2.1]
    exact hlive e j hl hd ho
  · intro e j t p a hm hr hj
    rw [tib] at hm; rw [(tf e).1] at hr; rw [thd] at hj; rw [(tf e.other).2.2.2.2.2.1]
    exact hresT e j t p a hm hr hj
  · intro e; rw [(tf e).2.2.2.2.2.2.1, (tf e).2.2.2.2.2.2.2.1]; exact h18 e

/-- A frame produced by a live side and sent on its open, live channel. -/
theorem Inv.sendFrame {s : State} {c : Cl} {k : Nat} (h : Inv s) (hw : (s.sd c).sent < (s.sd c).rx + W)
    (hl : (s.sd c).ph = .live) (hdc : (s.sd c).dc = some k) (hdead : (s.ch k).dead = false) :
    Inv (appendQ k c.other [.inp (s.sd c).sent] (updS c (fun y => { y with sent := y.sent + 1 }) s)) := by
  -- t's sides are bumpSent's; t's channels are s's with the frame queued.
  have tc : ∀ e, (updS c (fun y => { y with sent := y.sent + 1 }) s).cs e =
      if e = c then { s.cs c with sent := (s.cs c).sent + 1 } else s.cs e := by
    intro e; rw [updS_cs]; split <;> rfl
  have tf : ∀ e, ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).ph = (s.cs e).ph ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).dc = (s.cs e).dc ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).rsPc = (s.cs e).rsPc ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).rsOpen = (s.cs e).rsOpen ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).early = (s.cs e).early ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).rx = (s.cs e).rx ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).gap = (s.cs e).gap ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).dup = (s.cs e).dup ∧
      ((updS c (fun y => { y with sent := y.sent + 1 }) s).cs e).sent =
        (s.cs e).sent + (if e = c then 1 else 0) := by
    intro e; rw [tc]; by_cases he : e = c
    · subst he; simp
    · simp [he]
  have thd : ∀ e j, hdC (updS c (fun y => { y with sent := y.sent + 1 }) s).cs e j ↔ hdC s.cs e j := by
    intro e j; simp only [hdC, (tf e).2.1, (tf e).2.2.1]
  have tib : ∀ e j, inbC (updS c (fun y => { y with sent := y.sent + 1 }) s).cs
      (appendQ k c.other [.inp (s.sd c).sent] (updS c (fun y => { y with sent := y.sent + 1 }) s)).ch e j =
      if j = k ∧ e = c.other then inbC s.cs s.ch e j ++ [.inp (s.sd c).sent] else inbC s.cs s.ch e j := by
    intro e j
    rw [inbC_appendQ]
    simp only [inbC, (tf e).2.2.1, (tf e).2.2.2.2.1, updS_ch]
  have hk : k < s.nextCh := (h.hold c k (Or.inl (by simpa [cs_apply] using hdc))).1
  have hdc' : (s.cs c).dc = some k := by simpa [cs_apply] using hdc
  have hl' : (s.cs c).ph = .live := by simpa [cs_apply] using hl
  have hsent : (s.cs c).sent = (s.sd c).sent := rfl
  unfold Inv at *
  obtain ⟨h1, h2, h3, h4, h5, hhold, hsame, hfresh, hdeadQ, h10, h11, hpipe, hquiet, hsilent,
    hpre, hlive, hresT, h18⟩ := h
  simp only [appendQ_cs, appendQ_nextCh, updS_nextCh]
  constructor
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1]; exact h1 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1]; exact h2 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1, (tf e).2.2.2.1]; exact h3 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.2.1]; exact h4 e
  · intro e; simp only [(tf e).2.2.2.2.1, (tf e).2.1, (tf e).2.2.1]; exact h5 e
  · intro e j hj; rw [thd] at hj; rw [appendQ_closed, updS_ch]; exact hhold e j hj
  · intro e j i; rw [thd, thd]; exact hsame e j i
  · intro j hj
    have hne : j ≠ k := by omega
    obtain ⟨a1, a2⟩ := hfresh j hj
    refine ⟨by rw [appendQ_dead, updS_ch]; exact a1, fun e => ⟨?_, by rw [appendQ_closed, updS_ch]; exact (a2 e).2⟩⟩
    rw [appendQ_q]; simp [hne, (a2 e).1]
  · intro j e hj
    rw [appendQ_dead, updS_ch] at hj
    rw [appendQ_q]
    by_cases hjk : j = k
    · subst hjk; rw [hdead] at hj; cases hj
    · simp [hjk, hdeadQ j e hj]
  · intro e; rw [(tf e).2.2.2.2.2.1, (tf e.other).2.2.2.2.2.2.2.2]
    have := h10 e; omega
  · intro e; rw [(tf e).2.2.2.2.2.1, (tf e).2.2.2.2.2.2.2.2]
    have := h11 e
    by_cases he : e = c
    · subst he; simp only [if_true, cs_apply, core_rx, core_sent] at hw this ⊢; omega
    · simp only [he, if_false, Nat.add_zero]; omega
  · intro e j hj
    rw [thd] at hj
    obtain ⟨m, a1, a2, a3⟩ := hpipe e j hj
    rw [tib, (tf e).2.2.2.2.2.1, (tf e.other).2.2.2.2.2.2.2.2, (tf e.other).1, (tf e.other).2.1,
      appendQ_dead, updS_ch]
    by_cases hjk : j = k ∧ e = c.other
    · obtain ⟨rfl, rfl⟩ := hjk
      simp only [Cl.other_other] at a2 a3 ⊢
      have heq := a3 hl' hdc' hdead
      refine ⟨m + 1, ?_, ?_, ?_⟩
      · simp only [and_self, if_true, insOf_append, a1]
        rw [List.range'_concat]; simp [Msg.frame?, insOf, heq, hsent]
      · simp only [if_true]; omega
      · intro _ _ _; simp only [if_true]; omega
    · simp only [hjk, if_false]
      refine ⟨m, a1, ?_, ?_⟩
      · split <;> omega
      · intro hl2 hd2 hdd
        by_cases he : e.other = c
        · exfalso
          have : e = c.other := by rw [← he]; simp
          subst this
          simp only [Cl.other_other] at hd2
          rw [hdc'] at hd2; cases hd2
          exact hjk ⟨rfl, rfl⟩
        · simp only [he, if_false, Nat.add_zero]; exact a3 hl2 hd2 hdd
  · intro e j hr hj
    rw [(tf e).1] at hr; rw [thd] at hj; rw [tib]
    have := hquiet e j hr hj
    split
    · rename_i hjk
      obtain ⟨rfl, he⟩ := hjk
      have : e = c := by have := congrArg Cl.other he; simpa using this
      subst this; rw [hl'] at hr; cases hr
    · exact this
  · intro e j hj hne
    rw [thd] at hj; rw [(tf e).2.1] at hne; rw [tib]
    split
    · rename_i hjk
      obtain ⟨rfl, he⟩ := hjk
      have : e = c := by have := congrArg Cl.other he; simpa using this
      subst this; exact absurd hdc' hne
    · exact hsilent e j hj hne
  · intro e j hj hne
    rw [thd] at hj; rw [(tf e).2.1] at hne; rw [tib]
    split
    · rename_i hjk
      obtain ⟨rfl, rfl⟩ := hjk
      exact absurd (hlive c j hl' hdc' hj) hne
    · exact hpre e j hj hne
  · intro e j hl2 hd hoth
    rw [(tf e).1] at hl2; rw [(tf e).2.1] at hd; rw [thd] at hoth; rw [(tf e.other).2.1]
    exact hlive e j hl2 hd hoth
  · intro e j t p a hm hr hj
    rw [tib] at hm; rw [(tf e).1] at hr; rw [thd] at hj; rw [(tf e.other).2.2.2.2.2.1]
    split at hm
    · simp only [List.mem_append, List.mem_singleton] at hm
      rcases hm with hm | hm
      · exact hresT e j t p a hm hr hj
      · cases hm
    · exact hresT e j t p a hm hr hj
  · intro e; rw [(tf e).2.2.2.2.2.2.1, (tf e).2.2.2.2.2.2.2.1]; exact h18 e

theorem inbC_pre_insOf {cs : Cl → Core} {ch : Nat → Chan} {c : Cl} {k : Nat}
    (h : insOf (inbC cs ch c k) = []) :
    insOf (if (cs c).rsPc = some k then (cs c).early else []) = [] := by
  unfold inbC at h; simp at h; exact h.1

/-- The connection under channel k dies: everything in flight is lost. -/
theorem Inv.die {s : State} {k : Nat} (h : Inv s) (hk : k < s.nextCh) :
    Inv (updCh k (fun x => { x with dead := true, q := fun _ => [] }) s) := by
  have tib : ∀ e j, inbC s.cs (updCh k (fun x => { x with dead := true, q := fun _ => [] }) s).ch e j =
      if j = k then (if (s.cs e).rsPc = some j then (s.cs e).early else []) else inbC s.cs s.ch e j := by
    intro e j; unfold inbC; by_cases hj : j = k <;> simp [hj]
  unfold Inv at *
  obtain ⟨h1, h2, h3, h4, h5, hhold, hsame, hfresh, hdeadQ, h10, h11, hpipe, hquiet, hsilent,
    hpre, hlive, hresT, h18⟩ := h
  simp only [updCh_cs, updCh_nextCh]
  -- What was queued before an open has no inputs.
  have hearly : ∀ e, hdC s.cs e k →
      insOf (if (s.cs e).rsPc = some k then (s.cs e).early else []) = [] := by
    intro e he
    by_cases hd : (s.cs e).dc = some k
    · have : (s.cs e).early = [] := by
        cases hl : (s.cs e).early with
        | nil => rfl
        | cons x xs => have := (h5 e (by rw [hl]; simp)).1; rw [hd] at this; cases this
      simp [this]
    · exact inbC_pre_insOf (hpre e k he hd)
  refine ⟨h1, h2, h3, h4, h5, ?_, hsame, ?_, ?_, h10, h11, ?_, ?_, ?_, ?_, hlive, ?_, h18⟩
  · intro e j he; refine ⟨(hhold e j he).1, ?_⟩
    simp only [updCh_ch]; split <;> exact (hhold e j he).2
  · intro j hj
    have hne : j ≠ k := by omega
    simp only [updCh_ch, hne, if_false]; exact hfresh j hj
  · intro j e hj
    simp only [updCh_ch] at hj ⊢
    split
    · rfl
    · rename_i hjk; simp only [hjk, if_false] at hj; exact hdeadQ j e hj
  · intro e j he
    rw [tib]
    by_cases hjk : j = k
    · subst hjk
      refine ⟨0, by simp only [if_true]; exact hearly e he, by have := h10 e; omega, ?_⟩
      intro _ _ hdd; simp at hdd
    · simp only [hjk, if_false, updCh_ch]; exact hpipe e j he
  · intro e j hr he
    rw [tib]
    by_cases hjk : j = k
    · subst hjk; simp only [if_true]
      exact inbC_pre_insOf (hquiet e j hr he)
    · simp only [hjk, if_false]; exact hquiet e j hr he
  · intro e j he hne
    rw [tib]
    by_cases hjk : j = k
    · subst hjk; simp only [if_true]
      have := hsilent e j he hne; unfold inbC at this; simp at this
      split <;> simp_all
    · simp only [hjk, if_false]; exact hsilent e j he hne
  · intro e j he hne
    rw [tib]
    by_cases hjk : j = k
    · subst hjk; simp only [if_true]; exact hearly e he
    · simp only [hjk, if_false]; exact hpre e j he hne
  · intro e j t p a hm hr he
    rw [tib] at hm
    by_cases hjk : j = k
    · subst hjk; simp only [if_true] at hm
      exact hresT e j t p a (by unfold inbC; simp [hm]) hr he
    · simp only [hjk, if_false] at hm; exact hresT e j t p a hm hr he

/-- A pairing on the retry code: both sides, redialing with nothing held,
    get the fresh channel `nextCh`. -/
theorem Inv.pair {s : State} (h : Inv s) (hen : en cfg s .pair = true) : Inv (pair s) := by
  simp only [en, Bool.and_eq_true, beq_iff_eq, Option.isNone_iff_eq_none] at hen
  obtain ⟨⟨⟨⟨⟨hra, hrb⟩, hpa⟩, hpb⟩, hda⟩, hdb⟩ := hen
  have hr : ∀ e, (s.sd e).ph = .recon ∧ (s.sd e).rsPc = none ∧ (s.sd e).dc = none := by
    intro e; cases e <;> simp_all
  have tc : ∀ e, (LinkResume.pair s).cs e = { s.cs e with rsPc := some s.nextCh } := by
    intro e; cases e <;> simp [LinkResume.pair, cs_apply, Side.core]
  have tn : (LinkResume.pair s).nextCh = s.nextCh + 1 := by simp [LinkResume.pair]
  have tch : (LinkResume.pair s).ch = s.ch := by simp [LinkResume.pair]
  have hinv := h
  unfold Inv at hinv
  have hearly : ∀ e, (s.cs e).early = [] := by
    intro e
    cases hl : (s.cs e).early with
    | nil => rfl
    | cons x xs =>
      have := (hinv.earlySh e (by rw [hl]; simp)).2; simp [cs_apply, (hr e).2.1] at this
  have thd : ∀ e j, hdC (LinkResume.pair s).cs e j ↔ j = s.nextCh := by
    intro e j; simp [hdC, tc, cs_apply, (hr e).2.2, eq_comm]
  have tib : ∀ e, inbC (LinkResume.pair s).cs (LinkResume.pair s).ch e s.nextCh = [] := by
    intro e
    have := (hinv.fresh s.nextCh (Nat.le_refl _)).2 e
    simp [inbC, tc, tch, hearly, this.1]
  have hfr := hinv.fresh s.nextCh (Nat.le_refl _)
  unfold Inv
  rw [tn, tch]
  obtain ⟨h1, h2, h3, h4, h5, hhold, hsame, hfresh, hdeadQ, h10, h11, hpipe, hquiet, hsilent,
    hpre, hlive, hresT, h18⟩ := hinv
  constructor
  · intro e he; rw [tc] at he; simp [cs_apply, (hr e).1] at he
  · intro e he; rw [tc] at he; simp [cs_apply, (hr e).1] at he
  · intro e j _ hd; rw [tc] at hd; simp [cs_apply, (hr e).2.2] at hd
  · intro e _ _; rw [tc]; exact h4 e (by simp [cs_apply, (hr e).1]) (by simp [cs_apply, (hr e).2.2])
  · intro e he; rw [tc] at he ⊢; simp [hearly] at he
  · intro e j he; rw [thd] at he; subst he; exact ⟨by omega, (hfr.2 e).2⟩
  · intro e j i he hi; rw [thd] at he hi; rw [he, hi]
  · intro j hj; exact hfresh j (by omega)
  · exact hdeadQ
  · intro e; rw [tc, tc]; exact h10 e
  · intro e; rw [tc]; exact h11 e
  · intro e j he; rw [thd] at he; subst he
    rw [← tch, tib]
    refine ⟨0, rfl, by rw [tc, tc]; have := h10 e; simpa using this, ?_⟩
    intro hl; rw [tc] at hl; simp [cs_apply, (hr e.other).1] at hl
  · intro e j _ he; rw [thd] at he; subst he; rw [← tch, tib]; rfl
  · intro e j he _; rw [thd] at he; subst he; rw [← tch, tib]
  · intro e j he _; rw [thd] at he; subst he; rw [← tch, tib]; rfl
  · intro e j hl; rw [tc] at hl; simp [cs_apply, (hr e).1] at hl
  · intro e j t p a hm _ he; rw [thd] at he; subst he; rw [← tch, tib] at hm; cases hm
  · intro e; rw [tc]; exact h18 e

/-! ### Delivery -/

def popQ (k : Nat) (c : Cl) (rest : List Msg) (s : State) : State :=
  updCh k (fun x => { x with q := fun d => if d = c then rest else x.q d }) s

@[simp] theorem popQ_cs (s : State) (k : Nat) (c : Cl) (rest : List Msg) : (popQ k c rest s).cs = s.cs := rfl
@[simp] theorem popQ_sd (s : State) (k : Nat) (c : Cl) (rest : List Msg) : (popQ k c rest s).sd = s.sd := rfl
@[simp] theorem popQ_nextCh (s : State) (k : Nat) (c : Cl) (rest : List Msg) :
    (popQ k c rest s).nextCh = s.nextCh := rfl
@[simp] theorem popQ_now (s : State) (k : Nat) (c : Cl) (rest : List Msg) : (popQ k c rest s).now = s.now := rfl
@[simp] theorem popQ_dead (s : State) (k j : Nat) (c : Cl) (rest : List Msg) :
    ((popQ k c rest s).ch j).dead = (s.ch j).dead := by simp [popQ]; split <;> rfl
@[simp] theorem popQ_closed (s : State) (k j : Nat) (c : Cl) (rest : List Msg) :
    ((popQ k c rest s).ch j).closed = (s.ch j).closed := by simp [popQ]; split <;> rfl
theorem popQ_q (s : State) (k j : Nat) (c e : Cl) (rest : List Msg) :
    ((popQ k c rest s).ch j).q e = if j = k ∧ e = c then rest else (s.ch j).q e := by
  simp only [popQ, updCh_ch]; by_cases hj : j = k <;> by_cases he : e = c <;> simp [hj, he]

theorem inbC_popQ (s : State) (k j : Nat) (c e : Cl) (rest : List Msg) :
    inbC s.cs (popQ k c rest s).ch e j =
      if j = k ∧ e = c then (if (s.cs e).rsPc = some j then (s.cs e).early else []) ++ rest
      else inbC s.cs s.ch e j := by
  unfold inbC; rw [popQ_q]; by_cases h : j = k ∧ e = c <;> simp [h]

theorem insOf_drop_mid {pre rest : List Msg} {m : Msg} (h : insOf (pre ++ m :: rest) = []) :
    insOf (pre ++ rest) = [] := by
  unfold insOf at *
  simp only [List.filterMap_append, List.filterMap_cons, List.append_eq_nil_iff] at h ⊢
  refine ⟨h.1, ?_⟩
  have := h.2; split at this <;> simp_all

theorem mem_drop_mid {pre rest : List Msg} {m x : Msg} (h : x ∈ pre ++ rest) : x ∈ pre ++ m :: rest := by
  simp only [List.mem_append, List.mem_cons] at h ⊢
  rcases h with h | h
  · exact Or.inl h
  · exact Or.inr (Or.inr h)

/-- The head of the queue to c on k leaves it (read, queued early, or
    dropped). Fine unless it is an input c is about to read. -/
theorem Inv.pop {s : State} {c : Cl} {k : Nat} {m : Msg} {rest : List Msg} (h : Inv s)
    (hq : (s.ch k).q c = m :: rest) (hm : (s.sd c).dc = some k → m.frame? = none) :
    Inv (popQ k c rest s) := by
  have hib : ∀ e j, inbC s.cs (popQ k c rest s).ch e j =
      if j = k ∧ e = c then (if (s.cs e).rsPc = some j then (s.cs e).early else []) ++ rest
      else inbC s.cs s.ch e j := fun e j => inbC_popQ s k j c e rest
  have hold : inbC s.cs s.ch c k = (if (s.cs c).rsPc = some k then (s.cs c).early else []) ++ m :: rest := by
    unfold inbC; rw [hq]
  unfold Inv at *
  obtain ⟨h1, h2, h3, h4, h5, hhold, hsame, hfresh, hdeadQ, h10, h11, hpipe, hquiet, hsilent,
    hpre, hlive, hresT, h18⟩ := h
  -- c holds k ⇒ m is not an input.
  have hmi : hdC s.cs c k → m.frame? = none := by
    intro hc
    by_cases hd : (s.cs c).dc = some k
    · exact hm (by simpa [cs_apply] using hd)
    · have := hpre c k hc hd
      rw [hold] at this
      simp only [insOf_append, List.append_eq_nil_iff] at this
      have h2 := this.2
      cases m <;> first | rfl | (simp [insOf, Msg.frame?] at h2)
  have hk : k < s.nextCh := Nat.lt_of_not_le fun hk => by
    have := ((hfresh k hk).2 c).1; rw [hq] at this; cases this
  simp only [popQ_cs, popQ_nextCh]
  refine ⟨h1, h2, h3, h4, h5, ?_, hsame, ?_, ?_, h10, h11, ?_, ?_, ?_, ?_, hlive, ?_, h18⟩
  · intro e j he; rw [popQ_closed]; exact hhold e j he
  · intro j hj
    have hne : j ≠ k := by omega
    refine ⟨by rw [popQ_dead]; exact (hfresh j hj).1, fun e => ⟨?_, by rw [popQ_closed]; exact ((hfresh j hj).2 e).2⟩⟩
    rw [popQ_q]; simp [hne, ((hfresh j hj).2 e).1]
  · intro j e hj; rw [popQ_dead] at hj; rw [popQ_q]
    have := hdeadQ j e hj
    split
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk; rw [hq] at this; cases this
    · exact this
  · intro e j he
    obtain ⟨n, a1, a2, a3⟩ := hpipe e j he
    refine ⟨n, ?_, a2, by simpa using a3⟩
    rw [hib]; split
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk
      rw [hold] at a1; rw [← a1]
      simp [insOf_cons_other m rest (hmi he)]
    · exact a1
  · intro e j hr he
    rw [hib]; split
    · rename_i hjk; obtain ⟨rfl, he2⟩ := hjk
      subst he2
      have := hquiet e j hr he; rw [hold] at this
      exact insOf_drop_mid this
    · exact hquiet e j hr he
  · intro e j he hne
    rw [hib]; split
    · rename_i hjk; obtain ⟨rfl, he2⟩ := hjk
      subst he2
      have := hsilent e j he hne; rw [hold] at this; simp at this
    · exact hsilent e j he hne
  · intro e j he hne
    rw [hib]; split
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk
      have := hpre e j he hne; rw [hold] at this
      exact insOf_drop_mid this
    · exact hpre e j he hne
  · intro e j t p a hmem hr he
    rw [hib] at hmem; split at hmem
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk
      exact hresT e j t p a (by rw [hold]; exact mem_drop_mid hmem) hr he
    · exact hresT e j t p a hmem hr he

/-- A side holds only its open channel, if it has one. -/
theorem held_eq {cs : Cl → Core} {c : Cl} {j k : Nat}
    (h1 : ∀ c, (cs c).ph = .live → (cs c).rsPc = none ∧ (cs c).dc ≠ none)
    (h2 : ∀ c, (cs c).ph = .ended → (cs c).dc = none ∧ (cs c).rsPc = none)
    (h3 : ∀ c k, (cs c).ph = .recon → (cs c).dc = some k → (cs c).rsPc = some k ∧ (cs c).rsOpen = true)
    (hj : hdC cs c j) (hk : (cs c).dc = some k) : j = k := by
  rcases hj with hj | hj
  · rw [hk] at hj; cases hj; rfl
  · cases hp : (cs c).ph with
    | live => rw [(h1 c hp).1] at hj; cases hj
    | recon => rw [(h3 c k hp hk).1] at hj; cases hj; rfl
    | ended => rw [(h2 c hp).1] at hk; cases hk

/-- c reads the next input on its open channel: by the pipe it is exactly
    the frame c needs. -/
theorem Inv.recvInput {s : State} {c : Cl} {k f : Nat} {rest : List Msg} (h : Inv s)
    (hq : (s.ch k).q c = .inp f :: rest) (hdc : (s.sd c).dc = some k) (g : Side → Side)
    (hg : ∀ y, (g y).core = { y.core with rx := max y.rx (f + 1), gap := y.gap || decide (f > y.rx),
                                           dup := y.dup || decide (f < y.rx) }) :
    Inv (updS c g (popQ k c rest s)) ∧ f = (s.sd c).rx := by
  have hinv := h
  unfold Inv at hinv
  obtain ⟨h1, h2, h3, h4, h5, hhold, hsame, hfresh, hdeadQ, h10, h11, hpipe, hquiet, hsilent,
    hpre, hlive, hresT, h18⟩ := hinv
  have hdc' : (s.cs c).dc = some k := by simpa [cs_apply] using hdc
  have hc : hdC s.cs c k := Or.inl hdc'
  have hearly : (s.cs c).early = [] := by
    cases hl : (s.cs c).early with
    | nil => rfl
    | cons x xs => have := (h5 c (by rw [hl]; simp)).1; rw [hdc'] at this; cases this
  have hold : inbC s.cs s.ch c k = .inp f :: rest := by unfold inbC; rw [hq, hearly]; simp
  obtain ⟨n, a1, a2, a3⟩ := hpipe c k hc
  rw [hold] at a1
  simp only [insOf_cons_inp] at a1
  obtain ⟨n', rfl⟩ : ∃ n', n = n' + 1 := by
    cases n with
    | zero => simp at a1
    | succ n' => exact ⟨n', rfl⟩
  rw [List.range'_succ] at a1
  obtain ⟨hf, hrest⟩ := List.cons.inj a1
  have hf' : f = (s.sd c).rx := hf
  refine ⟨?_, hf'⟩
  -- The new side: rx one on, nothing else in the core moved.
  have tc : ∀ e, (updS c g (popQ k c rest s)).cs e =
      if e = c then { s.cs c with rx := (s.cs c).rx + 1 } else s.cs e := by
    intro e; rw [updS_cs]
    by_cases he : e = c
    · subst he; simp only [if_true, popQ_sd, hg]
      simp [cs_apply, Side.core, ← hf', Nat.max_def]
    · simp [he]
  have tf : ∀ e, ((updS c g (popQ k c rest s)).cs e).ph = (s.cs e).ph ∧
      ((updS c g (popQ k c rest s)).cs e).dc = (s.cs e).dc ∧
      ((updS c g (popQ k c rest s)).cs e).rsPc = (s.cs e).rsPc ∧
      ((updS c g (popQ k c rest s)).cs e).rsOpen = (s.cs e).rsOpen ∧
      ((updS c g (popQ k c rest s)).cs e).early = (s.cs e).early ∧
      ((updS c g (popQ k c rest s)).cs e).sent = (s.cs e).sent ∧
      ((updS c g (popQ k c rest s)).cs e).gap = (s.cs e).gap ∧
      ((updS c g (popQ k c rest s)).cs e).dup = (s.cs e).dup ∧
      ((updS c g (popQ k c rest s)).cs e).rx = (s.cs e).rx + (if e = c then 1 else 0) := by
    intro e; rw [tc]; by_cases he : e = c
    · subst he; simp
    · simp [he]
  have thd : ∀ e j, hdC (updS c g (popQ k c rest s)).cs e j ↔ hdC s.cs e j := by
    intro e j; simp only [hdC, (tf e).2.1, (tf e).2.2.1]
  have tib : ∀ e j, inbC (updS c g (popQ k c rest s)).cs (popQ k c rest s).ch e j =
      if j = k ∧ e = c then rest else inbC s.cs s.ch e j := by
    intro e j
    have : inbC (updS c g (popQ k c rest s)).cs (popQ k c rest s).ch e j =
        inbC s.cs (popQ k c rest s).ch e j := by
      simp only [inbC, (tf e).2.2.1, (tf e).2.2.2.2.1]
    rw [this, inbC_popQ]
    split
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk; simp [hearly]
    · rfl
  -- Inputs to c were in flight: whoever holds k on the other side is not redialing.
  have hnq : ¬ ((s.cs c.other).ph = .recon ∧ hdC s.cs c.other k) := by
    intro ⟨hr, ho⟩
    have := hquiet c.other k hr ho
    simp only [Cl.other_other, hold, insOf_cons_inp] at this; cases this
  unfold Inv
  simp only [updS_ch, updS_nextCh, popQ_nextCh]
  constructor
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1]; exact h1 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1]; exact h2 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1, (tf e).2.2.2.1]; exact h3 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.2.1]; exact h4 e
  · intro e; simp only [(tf e).2.2.2.2.1, (tf e).2.1, (tf e).2.2.1]; exact h5 e
  · intro e j he; rw [thd] at he; rw [popQ_closed]; exact hhold e j he
  · intro e j i; rw [thd, thd]; exact hsame e j i
  · intro j hj
    have hk : k < s.nextCh := (hhold c k hc).1
    have hne : j ≠ k := by omega
    refine ⟨by rw [popQ_dead]; exact (hfresh j hj).1, fun e => ⟨?_, by rw [popQ_closed]; exact ((hfresh j hj).2 e).2⟩⟩
    rw [popQ_q]; simp [hne, ((hfresh j hj).2 e).1]
  · intro j e hj; rw [popQ_dead] at hj; rw [popQ_q]
    have := hdeadQ j e hj
    split
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk; rw [hq] at this; cases this
    · exact this
  · intro e; rw [(tf e).2.2.2.2.2.2.2.2, (tf e.other).2.2.2.2.2.1]
    by_cases he : e = c
    · subst he; simp only [if_true]; omega
    · simp only [he, if_false, Nat.add_zero]; exact h10 e
  · intro e; rw [(tf e).2.2.2.2.2.1, (tf e).2.2.2.2.2.2.2.2]
    have := h11 e; split <;> omega
  · intro e j he
    rw [thd] at he
    rw [tib, (tf e).2.2.2.2.2.2.2.2, (tf e.other).2.2.2.2.2.1, (tf e.other).1, (tf e.other).2.1,
      popQ_dead]
    by_cases hjk : j = k ∧ e = c
    · obtain ⟨rfl, rfl⟩ := hjk
      refine ⟨n', by simp only [and_self, if_true]; rw [hrest], ?_, ?_⟩
      · simp only [if_true]; omega
      · intro hl hd hdd; simp only [if_true]; have := a3 hl hd hdd; omega
    · simp only [hjk, if_false]
      by_cases he2 : e = c
      · subst he2
        exact absurd ⟨held_eq h1 h2 h3 he hdc', rfl⟩ hjk
      · obtain ⟨m', b1, b2, b3⟩ := hpipe e j he
        exact ⟨m', by simp only [he2, if_false, Nat.add_zero]; exact b1,
          by simp only [he2, if_false, Nat.add_zero]; exact b2,
          by simp only [he2, if_false, Nat.add_zero]; exact b3⟩
  · intro e j hr he
    rw [(tf e).1] at hr; rw [thd] at he; rw [tib]
    split
    · rename_i hjk; obtain ⟨rfl, he2⟩ := hjk
      have : e = c.other := by rw [← he2]; simp
      subst this; exact absurd ⟨hr, he⟩ hnq
    · exact hquiet e j hr he
  · intro e j he hne
    rw [thd] at he; rw [(tf e).2.1] at hne; rw [tib]
    split
    · rename_i hjk; obtain ⟨rfl, he2⟩ := hjk
      have : e = c.other := by rw [← he2]; simp
      subst this
      have := hsilent c.other j he hne; simp only [Cl.other_other, hold] at this; cases this
    · exact hsilent e j he hne
  · intro e j he hne
    rw [thd] at he; rw [(tf e).2.1] at hne; rw [tib]
    split
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk; exact absurd hdc' hne
    · exact hpre e j he hne
  · intro e j hl hd ho
    rw [(tf e).1] at hl; rw [(tf e).2.1] at hd; rw [thd] at ho; rw [(tf e.other).2.1]
    exact hlive e j hl hd ho
  · intro e j t p a hm hr he
    rw [tib] at hm; rw [(tf e).1] at hr; rw [thd] at he; rw [(tf e.other).2.2.2.2.2.2.2.2]
    split at hm
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk
      simp only [Cl.other_ne, if_false, Nat.add_zero]
      exact hresT e j t p a (by rw [hold]; exact List.mem_cons_of_mem _ hm) hr he
    · by_cases he2 : e.other = c
      · have : e = c.other := by rw [← he2]; simp
        subst this
        have hjk := hsame c k j hc he; subst hjk; exact absurd ⟨hr, he⟩ hnq
      · simp only [he2, if_false, Nat.add_zero]; exact hresT e j t p a hm hr he
  · intro e; rw [(tf e).2.2.2.2.2.2.1, (tf e).2.2.2.2.2.2.2.1]; exact h18 e

theorem appendQ_appendQ (s : State) (k : Nat) (d : Cl) (ms1 ms2 : List Msg) :
    appendQ k d ms2 (appendQ k d ms1 s) = appendQ k d (ms1 ++ ms2) s := by
  unfold appendQ updCh
  congr 1; funext j
  by_cases hj : j = k
  · subst hj; simp only [if_true]; congr 1; funext e; split <;> simp [List.append_assoc]
  · simp [hj]

theorem appendQ_nil (s : State) (k : Nat) (d : Cl) : appendQ k d [] s = s := by
  unfold appendQ updCh
  cases s with
  | mk sd ch n now =>
    simp only [List.append_nil, ite_self]

/-- `sendAll` on c's open, live channel queues the whole list; otherwise nothing. -/
theorem sendAll_eq (c : Cl) (ms : List Msg) (s : State) :
    sendAll c ms s = match (s.sd c).dc with
      | some k => if (s.ch k).dead || (s.ch k).closed c then s else appendQ k c.other ms s
      | none => s := by
  induction ms generalizing s with
  | nil =>
    cases hk : (s.sd c).dc with
    | none => rfl
    | some k =>
      simp only [sendAll]
      split
      · rfl
      · exact (appendQ_nil s k c.other).symm
  | cons m ms ih =>
    simp only [sendAll]
    rw [ih]
    cases hk : (s.sd c).dc with
    | none =>
      have : send c m s = s := by simp [send, hk]
      simp [this, hk]
    | some k =>
      by_cases ha : ((s.ch k).dead || (s.ch k).closed c) = true
      · have : send c m s = s := by simp only [send, hk, ha, if_true]
        simp only [this, hk, ha, if_true]
      · have : send c m s = appendQ k c.other [m] s := by
          simp only [send, hk, ha, Bool.false_eq_true, if_false]; rfl
        rw [this]
        simp only [appendQ_sd, hk, appendQ_dead, appendQ_closed, ha, Bool.false_eq_true, if_false,
          appendQ_appendQ]
        rfl

theorem frames_mem {t n : Nat} {x : Msg} (h : x ∈ frames t n) : ∃ f, x = .inp f := by
  unfold frames at h; simp at h; obtain ⟨f, -, rfl⟩ := h; exact ⟨f, rfl⟩

/-- `rsResumeIn`'s core: c, redialing on its open channel k, goes live and
    resends the friend's gap from `t`, the friend's `lastRx + 1`. -/
theorem Inv.resumeLive {s : State} {c : Cl} {k t : Nat} {g : Side → Side} (h : Inv s)
    (hr : (s.sd c).ph = .recon) (hdc : (s.sd c).dc = some k) (ht : t = (s.sd c.other).rx)
    (hod : hdC s.cs c.other k → (s.sd c.other).dc = some k)
    (hg : ∀ y, (g y).core = { y.core with ph := .live, rsPc := none }) :
    Inv (sendAll c (frames t (s.sd c).sent) (updS c g s)) := by
  have hinv := h
  unfold Inv at hinv
  obtain ⟨h1, h2, h3, h4, h5, hhold, hsame, hfresh, hdeadQ, h10, h11, hpipe, hquiet, hsilent,
    hpre, hlive, hresT, h18⟩ := hinv
  have hdc' : (s.cs c).dc = some k := by simpa [cs_apply] using hdc
  have hr' : (s.cs c).ph = .recon := by simpa [cs_apply] using hr
  have hc : hdC s.cs c k := Or.inl hdc'
  have hrs : (s.cs c).rsPc = some k := (h3 c k hr' hdc').1
  have hearly : (s.cs c).early = [] := by
    cases hl : (s.cs c).early with
    | nil => rfl
    | cons x xs => have := (h5 c (by rw [hl]; simp)).1; rw [hdc'] at this; cases this
  have hcl : (s.ch k).closed c = false := (hhold c k hc).2
  have hk : k < s.nextCh := (hhold c k hc).1
  have hod' : hdC s.cs c.other k → (s.cs c.other).dc = some k := fun x => by
    simpa [cs_apply] using hod x
  have hq0 : insOf (inbC s.cs s.ch c.other k) = [] := hquiet c k hr' hc
  have hrx : (s.cs c.other).rx ≤ (s.cs c).sent := by have := h10 c.other; simpa using this
  have ht' : t = (s.cs c.other).rx := ht
  -- The sides after: c live, no pairing; nothing else moved.
  have tc : ∀ e, (updS c g s).cs e =
      if e = c then { s.cs c with ph := .live, rsPc := none } else s.cs e := by
    intro e; rw [updS_cs]
    by_cases he : e = c
    · subst he; simp only [if_true, hg]; rfl
    · simp only [he, if_false]
  have tf : ∀ e, ((updS c g s).cs e).dc = (s.cs e).dc ∧
      ((updS c g s).cs e).rsOpen = (s.cs e).rsOpen ∧
      ((updS c g s).cs e).early = (s.cs e).early ∧
      ((updS c g s).cs e).sent = (s.cs e).sent ∧
      ((updS c g s).cs e).rx = (s.cs e).rx ∧
      ((updS c g s).cs e).gap = (s.cs e).gap ∧
      ((updS c g s).cs e).dup = (s.cs e).dup := by
    intro e; rw [tc]; by_cases he : e = c
    · subst he; simp
    · simp [he]
  have tph : ∀ e, ((updS c g s).cs e).ph = if e = c then .live else (s.cs e).ph := by
    intro e; rw [tc]; split <;> simp
  have trs : ∀ e, ((updS c g s).cs e).rsPc = if e = c then none else (s.cs e).rsPc := by
    intro e; rw [tc]; split <;> simp
  have thd : ∀ e j, hdC (updS c g s).cs e j ↔ hdC s.cs e j := by
    intro e j; simp only [hdC, (tf e).1, trs]
    by_cases he : e = c
    · subst he; simp only [if_true, hdc', hrs]; simp
    · simp [he]
  have tpre : ∀ e j, (if ((updS c g s).cs e).rsPc = some j then ((updS c g s).cs e).early else []) =
      (if (s.cs e).rsPc = some j then (s.cs e).early else []) := by
    intro e j; simp only [trs, (tf e).2.2.1]
    by_cases he : e = c
    · subst he; simp only [if_true, hrs, hearly]; simp
    · simp only [he, if_false]
  -- The channels after.
  have hsend : sendAll c (frames t (s.sd c).sent) (updS c g s) =
      if (s.ch k).dead then updS c g s else appendQ k c.other (frames t (s.sd c).sent) (updS c g s) := by
    rw [sendAll_eq]
    have : ((updS c g s).sd c).dc = some k := by
      have := (tf c).1; simp only [cs_apply, core_dc] at this; rw [this, hdc]
    simp only [this, updS_ch, hcl, Bool.or_false]
  rw [hsend]
  unfold Inv
  -- One proof for both: with `F` what joined the friend's queue.
  have key : ∀ (F : List Msg) (ch' : Nat → Chan),
      ((s.ch k).dead = true ∧ F = [] ∨
        (s.ch k).dead = false ∧ insOf F = List.range' t ((s.cs c).sent - t)) →
      (∀ x ∈ F, x.isResume = false) →
      (∀ j, (ch' j).dead = (s.ch j).dead) → (∀ j e, (ch' j).closed e = (s.ch j).closed e) →
      (∀ j e, (ch' j).q e = if j = k ∧ e = c.other then (s.ch j).q e ++ F else (s.ch j).q e) →
      InvC (updS c g s).cs ch' s.nextCh := by
    intro F ch' hF hres hd' hc' hq'
    have hFd : (s.ch k).dead = true → F = [] := by
      intro hdk; rcases hF with ⟨_, hF⟩ | ⟨hF, _⟩
      · exact hF
      · rw [hdk] at hF; cases hF
    have tib : ∀ e j, inbC (updS c g s).cs ch' e j =
        if j = k ∧ e = c.other then inbC s.cs s.ch e j ++ F else inbC s.cs s.ch e j := by
      intro e j
      unfold inbC; rw [tpre, hq']
      by_cases hjk : j = k ∧ e = c.other
      · simp only [hjk, and_self, if_true, List.append_assoc]
      · simp only [hjk, if_false]
    constructor
    · intro e he; rw [tph] at he; rw [trs, (tf e).1]
      by_cases hec : e = c
      · subst hec; simp [hdc']
      · simp only [hec, if_false] at he ⊢; exact h1 e he
    · intro e he; rw [tph] at he; rw [trs, (tf e).1]
      by_cases hec : e = c
      · subst hec; simp at he
      · simp only [hec, if_false] at he ⊢; exact h2 e he
    · intro e j he hd; rw [tph] at he; rw [(tf e).1] at hd; rw [trs, (tf e).2.1]
      by_cases hec : e = c
      · subst hec; simp at he
      · simp only [hec, if_false] at he ⊢; exact h3 e j he hd
    · intro e he hd; rw [tph] at he; rw [(tf e).1] at hd; rw [(tf e).2.1]
      by_cases hec : e = c
      · subst hec; simp at he
      · simp only [hec, if_false] at he; exact h4 e he hd
    · intro e he; rw [(tf e).2.2.1] at he; rw [(tf e).1, trs]
      by_cases hec : e = c
      · subst hec; exact absurd hearly he
      · simp only [hec, if_false]; exact h5 e he
    · intro e j he; rw [thd] at he; rw [hc']; exact hhold e j he
    · intro e j i he hi; rw [thd] at he hi; exact hsame e j i he hi
    · intro j hj
      have hne : j ≠ k := by omega
      refine ⟨by rw [hd']; exact (hfresh j hj).1, fun e => ⟨?_, by rw [hc']; exact ((hfresh j hj).2 e).2⟩⟩
      rw [hq']; simp [hne, ((hfresh j hj).2 e).1]
    · intro j e hj; rw [hd'] at hj; rw [hq']
      have := hdeadQ j e hj
      split
      · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk; simp [this, hFd hj]
      · exact this
    · intro e; rw [(tf e).2.2.2.2.1, (tf e.other).2.2.2.1]; exact h10 e
    · intro e; rw [(tf e).2.2.2.2.1, (tf e).2.2.2.1]; exact h11 e
    · intro e j he
      rw [thd] at he
      rw [tib, (tf e).2.2.2.2.1, (tf e.other).2.2.2.1, tph, (tf e.other).1, hd']
      by_cases hjk : j = k ∧ e = c.other
      · obtain ⟨rfl, rfl⟩ := hjk
        simp only [Cl.other_other, Cl.other_ne, and_self, if_true, insOf_append, hq0, List.nil_append]
        rcases hF with ⟨hdk, hF⟩ | ⟨hlive', hF⟩
        · refine ⟨0, by rw [hF]; rfl, by omega, ?_⟩
          intro _ _ hdd; rw [hdk] at hdd; cases hdd
        · refine ⟨(s.cs c).sent - t, by rw [hF, ht'], by omega, by intro; omega⟩
      · simp only [hjk, if_false]
        by_cases hec : e = c
        · subst hec
          obtain ⟨m, a1, a2, a3⟩ := hpipe e j he
          refine ⟨m, a1, a2, ?_⟩
          simp only [Cl.other_ne, if_false]; exact a3
        · have he' : e = c.other := by rcases Cl.eq_or c e with h' | h'; exact absurd h' hec; exact h'
          subst he'
          have : j = k := (hsame c k j hc he).symm
          exact absurd ⟨this, rfl⟩ hjk
    · intro e j hr2 he
      rw [tph] at hr2; rw [thd] at he; rw [tib]
      by_cases hec : e = c
      · subst hec; simp at hr2
      · simp only [hec, if_false] at hr2
        split
        · rename_i hjk; obtain ⟨_, he2⟩ := hjk
          have : e = c := by have := congrArg Cl.other he2; simpa using this
          exact absurd this hec
        · exact hquiet e j hr2 he
    · intro e j he hne
      rw [thd] at he; rw [(tf e).1] at hne; rw [tib]
      split
      · rename_i hjk; obtain ⟨rfl, he2⟩ := hjk
        have : e = c := by have := congrArg Cl.other he2; simpa using this
        subst this; exact absurd hdc' hne
      · exact hsilent e j he hne
    · intro e j he hne
      rw [thd] at he; rw [(tf e).1] at hne; rw [tib]
      split
      · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk; exact absurd (hod' he) hne
      · exact hpre e j he hne
    · intro e j hl hd ho
      rw [tph] at hl; rw [(tf e).1] at hd; rw [thd] at ho; rw [(tf e.other).1]
      by_cases hec : e = c
      · subst hec; rw [hdc'] at hd; cases hd; exact hod' ho
      · simp only [hec, if_false] at hl; exact hlive e j hl hd ho
    · intro e j t' p a hm hr2 he
      rw [tib] at hm; rw [tph] at hr2; rw [thd] at he; rw [(tf e.other).2.2.2.2.1]
      by_cases hec : e = c
      · subst hec; simp at hr2
      · simp only [hec, if_false] at hr2
        split at hm
        · simp only [List.mem_append] at hm
          rcases hm with hm | hm
          · exact hresT e j t' p a hm hr2 he
          · have := hres _ hm; simp [Msg.isResume] at this
        · exact hresT e j t' p a hm hr2 he
    · intro e; rw [(tf e).2.2.2.2.2.1, (tf e).2.2.2.2.2.2]; exact h18 e
  by_cases hdd : (s.ch k).dead = true
  · rw [if_pos hdd]
    exact key [] _ (Or.inl ⟨hdd, rfl⟩) (by simp) (fun j => by simp) (fun j e => by simp)
      (fun j e => by simp only [updS_ch, List.append_nil, ite_self])
  · rw [if_neg hdd]
    exact key (frames t (s.sd c).sent) _
      (Or.inr ⟨by simpa using hdd, by rw [insOf_frames]; rfl⟩)
      (fun x hx => by obtain ⟨f, rfl⟩ := frames_mem hx; rfl)
      (fun j => by simp) (fun j e => by simp) (fun j e => by rw [appendQ_q]; simp)

theorem updS_updS (s : State) (c : Cl) (f g : Side → Side) :
    updS c g (updS c f s) = updS c (g ∘ f) s := by
  unfold updS; congr 1; funext d; split <;> simp_all

/-- A message for the pairing c is still opening goes to `rb.rsEarly`: what
    is on its way to c is the same list. -/
theorem Inv.earlyPush {s : State} {c : Cl} {k : Nat} {m : Msg} {rest : List Msg} (h : Inv s)
    (hq : (s.ch k).q c = m :: rest) (hdc : (s.sd c).dc ≠ some k) (hrs : (s.sd c).rsPc = some k) :
    Inv (updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)) := by
  have hinv := h
  unfold Inv at hinv
  obtain ⟨h1, h2, h3, h4, h5, hhold, hsame, hfresh, hdeadQ, h10, h11, hpipe, hquiet, hsilent,
    hpre, hlive, hresT, h18⟩ := hinv
  have hrs' : (s.cs c).rsPc = some k := by simpa [cs_apply] using hrs
  have hdc' : (s.cs c).dc ≠ some k := by simpa [cs_apply] using hdc
  have hdn : (s.cs c).dc = none := by
    cases hd : (s.cs c).dc with
    | none => rfl
    | some j =>
      exfalso
      cases hp : (s.cs c).ph with
      | live => rw [(h1 c hp).1] at hrs'; cases hrs'
      | recon => have := (h3 c j hp hd).1; rw [hrs'] at this; cases this; exact hdc' hd
      | ended => rw [(h2 c hp).1] at hd; cases hd
  have tc : ∀ e, (updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)).cs e =
      if e = c then { s.cs c with early := (s.cs c).early ++ [m] } else s.cs e := by
    intro e; rw [updS_cs]; split <;> rfl
  have tf : ∀ e,
      ((updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)).cs e).ph = (s.cs e).ph ∧
      ((updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)).cs e).dc = (s.cs e).dc ∧
      ((updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)).cs e).rsPc = (s.cs e).rsPc ∧
      ((updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)).cs e).rsOpen = (s.cs e).rsOpen ∧
      ((updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)).cs e).sent = (s.cs e).sent ∧
      ((updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)).cs e).rx = (s.cs e).rx ∧
      ((updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)).cs e).gap = (s.cs e).gap ∧
      ((updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)).cs e).dup = (s.cs e).dup := by
    intro e; rw [tc]; by_cases he : e = c
    · subst he; simp
    · simp [he]
  have thd : ∀ e j, hdC (updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)).cs e j ↔
      hdC s.cs e j := by
    intro e j; simp only [hdC, (tf e).2.1, (tf e).2.2.1]
  have tib : ∀ e j, inbC (updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)).cs
      (popQ k c rest s).ch e j = inbC s.cs s.ch e j := by
    intro e j
    simp only [inbC]; rw [popQ_q, tc]
    by_cases he : e = c
    · subst he
      by_cases hj : j = k
      · subst hj; simp [hrs', hq]
      · have hne : (s.cs e).rsPc ≠ some j := by
          rw [hrs']; intro h'; exact hj (Option.some.inj h').symm
        simp [hj, hne]
    · simp only [he, if_false, and_false]
  unfold Inv
  simp only [updS_ch, updS_nextCh, popQ_nextCh]
  have hk : k < s.nextCh := (hhold c k (Or.inr hrs')).1
  constructor
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1]; exact h1 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1]; exact h2 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.1, (tf e).2.2.2.1]; exact h3 e
  · intro e; simp only [(tf e).1, (tf e).2.1, (tf e).2.2.2.1]; exact h4 e
  · intro e he; rw [(tf e).2.1, (tf e).2.2.1]
    by_cases hec : e = c
    · subst hec; exact ⟨hdn, by rw [hrs']; simp⟩
    · rw [tc] at he; simp only [hec, if_false] at he; exact h5 e he
  · intro e j he; rw [thd] at he; rw [popQ_closed]; exact hhold e j he
  · intro e j i; rw [thd, thd]; exact hsame e j i
  · intro j hj
    have hne : j ≠ k := by omega
    refine ⟨by rw [popQ_dead]; exact (hfresh j hj).1, fun e => ⟨?_, by rw [popQ_closed]; exact ((hfresh j hj).2 e).2⟩⟩
    rw [popQ_q]; simp [hne, ((hfresh j hj).2 e).1]
  · intro j e hj; rw [popQ_dead] at hj; rw [popQ_q]
    have := hdeadQ j e hj
    split
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk; rw [hq] at this; cases this
    · exact this
  · intro e; rw [(tf e).2.2.2.2.2.1, (tf e.other).2.2.2.2.1]; exact h10 e
  · intro e; rw [(tf e).2.2.2.2.2.1, (tf e).2.2.2.2.1]; exact h11 e
  · intro e j he
    rw [thd] at he; rw [tib, (tf e).2.2.2.2.2.1, (tf e.other).2.2.2.2.1, (tf e.other).1, (tf e.other).2.1,
      popQ_dead]
    exact hpipe e j he
  · intro e j hr he; rw [(tf e).1] at hr; rw [thd] at he; rw [tib]; exact hquiet e j hr he
  · intro e j he hne; rw [thd] at he; rw [(tf e).2.1] at hne; rw [tib]; exact hsilent e j he hne
  · intro e j he hne; rw [thd] at he; rw [(tf e).2.1] at hne; rw [tib]; exact hpre e j he hne
  · intro e j hl hd ho
    rw [(tf e).1] at hl; rw [(tf e).2.1] at hd; rw [thd] at ho; rw [(tf e.other).2.1]
    exact hlive e j hl hd ho
  · intro e j t p a hm hr he
    rw [tib] at hm; rw [(tf e).1] at hr; rw [thd] at he; rw [(tf e.other).2.2.2.2.2.1]
    exact hresT e j t p a hm hr he
  · intro e; rw [(tf e).2.2.2.2.2.2.1, (tf e).2.2.2.2.2.2.2]; exact h18 e

/-- Reading one message on the open channel keeps the invariant. -/
theorem Inv.deliver {cfg : Cfg} {s : State} {c : Cl} {k : Nat} (h : Inv s) :
    Inv (deliver cfg c k s) := by
  unfold LinkResume.deliver
  split
  · exact h
  · rename_i m rest hq
    have hinv := h
    unfold Inv at hinv
    dsimp only
    -- the popped state is `popQ`
    have hpop : updCh k (fun x => { x with q := fun d => if d = c then rest else x.q d }) s =
        popQ k c rest s := rfl
    rw [hpop]
    split
    · rename_i hcl
      refine h.pop hq (fun hd => ?_)
      have := (hinv.hold c k (Or.inl (by simpa [cs_apply] using hd))).2
      rw [popQ_closed] at hcl; rw [this] at hcl; cases hcl
    · split
      · rename_i hd
        have hd : (s.sd c).dc = some k := by simpa using hd
        have hc : hdC s.cs c k := Or.inl (by simpa [cs_apply] using hd)
        -- The message, read.
        cases m with
        | inp f =>
          simp only [recv, popQ_now, updS_updS]
          exact (h.recvInput hq hd _ (fun y => rfl)).1
        | info =>
          have h1 : Inv (popQ k c rest s) := h.pop hq (fun _ => rfl)
          have h2 := h1.updS_noncore (c := c) (f := fun y => { y with lastMsg := (popQ k c rest s).now })
            (fun y => rfl)
          simp only [recv]
          split
          · refine Inv.updS_noncore ?_ h2; intro y; rfl
          · refine Inv.send_misc ?_ rfl rfl; refine Inv.updS_noncore ?_ h2; intro y; rfl
        | ping =>
          have h1 : Inv (popQ k c rest s) := h.pop hq (fun _ => rfl)
          simp only [recv]
          refine Inv.updS_noncore ?_ h1; intro y; rfl
        | pause v n =>
          have h1 : Inv (popQ k c rest s) := h.pop hq (fun _ => rfl)
          have h2 := h1.updS_noncore (c := c) (f := fun y => { y with lastMsg := (popQ k c rest s).now })
            (fun y => rfl)
          simp only [recv]
          split
          · split
            · exact (h2.updS_noncore (c := c) (f := fun y => { y with reg := ⟨n, c.other == .a, v⟩ })
                (fun y => rfl)).remotePause
            · exact h2
          · exact h2.remotePause
        | bye =>
          have h1 : Inv (popQ k c rest s) := h.pop hq (fun _ => rfl)
          simp only [recv]
          refine Inv.shutdown ?_
          refine Inv.updS_noncore ?_ ?_; · intro y; rfl
          refine Inv.updS_noncore ?_ h1; intro y; rfl
        | resume t p a =>
          have h1 : Inv (popQ k c rest s) := h.pop hq (fun _ => rfl)
          have h2 := h1.updS_noncore (c := c) (f := fun y => { y with lastMsg := (popQ k c rest s).now })
            (fun y => rfl)
          have hmem : Msg.resume t p a ∈ inbC s.cs s.ch c k := by unfold inbC; rw [hq]; simp
          show Inv (resumeIn cfg c t p a
            (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s)))
          unfold resumeIn
          dsimp only
          split
          · exact h2
          · rename_i hg
            split
            · exact h2.shutdown
            · have hr : (s.sd c).ph = .recon := by
                simp only [Bool.not_eq_true', Bool.not_eq_false, Bool.and_eq_true, beq_iff_eq] at hg
                simpa using hg.1.1
              have ht := hinv.resT c k t p a hmem (by simpa [cs_apply] using hr) hc
              have hod : hdC (updS c (fun y => { y with lastMsg := (popQ k c rest s).now })
                  (popQ k c rest s)).cs c.other k →
                  ((updS c (fun y => { y with lastMsg := (popQ k c rest s).now })
                    (popQ k c rest s)).sd c.other).dc = some k := by
                intro ho
                have ho' : hdC s.cs c.other k := by simpa [hdC, cs_apply] using ho
                simp only [updS_sd, Cl.other_ne, if_false, popQ_sd]
                by_cases hdo : (s.sd c.other).dc = some k
                · exact hdo
                · have := hinv.silent c.other k ho' (by simpa [cs_apply] using hdo)
                  simp only [Cl.other_other] at this; rw [this] at hmem; cases hmem
              have h3 := h2.updS_noncore (c := c)
                (f := fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) }) (fun y => rfl)
              refine Inv.pauseAfterResume ?_
              have h4 := h3.resumeLive (c := c) (k := k) (t := t)
                (g := fun y => { y with ph := .live, rsPc := none })
                (by simpa using hr) (by simpa using hd)
                (by simpa [cs_apply] using ht)
                (fun ho => by simpa using hod (by simpa [hdC, cs_apply] using ho)) (fun y => rfl)
              rw [show ∀ (S : State) (f : Side → Side), (∀ y, (f y).sent = y.sent) →
                ((updS c f S).sd c).sent = (S.sd c).sent from fun S f hf => by simp [hf]] at h4
              · exact h4
              · intro y; rfl
      · split
        · rename_i hd hrs
          split
          · exact h.earlyPush hq (by simpa using hd) (by simpa using hrs)
          · exact h.pop hq (fun hd' => absurd (by simpa using hd') hd)
        · rename_i hd _
          exact h.pop hq (fun hd' => absurd (by simpa using hd') hd)

theorem Inv.deliverN {cfg : Cfg} {s : State} {c : Cl} {k : Nat} (n : Nat) (h : Inv s) :
    Inv (deliverN cfg c k n s) := by
  induction n generalizing s with
  | zero => exact h
  | succ n ih => exact ih h.deliver

/-- `rsAdopt` up to the replay: the early messages go back in front of the
    queue, the channel becomes `net.dc`, and RESUME goes out on it. -/
theorem Inv.adoptPrefix {s : State} {c : Cl} {k : Nat} {g : Side → Side} {msg : Msg} (h : Inv s)
    (hr : (s.sd c).ph = .recon) (hro : (s.sd c).rsOpen = false) (hrs : (s.sd c).rsPc = some k)
    (hdead : (s.ch k).dead = false)
    (hg : ∀ y, (g y).core = { y.core with rsOpen := true, dc := some k, early := [] })
    (hmsg : msg = .resume (s.sd c).rx (s.sd c).paused (s.sd c).away) :
    Inv (send c msg (updS c g
      (updCh k (fun y => { y with q := fun d => if d = c then (s.sd c).early ++ y.q d else y.q d }) s))) := by
  have hinv := h
  unfold Inv at hinv
  obtain ⟨h1, h2, h3, h4, h5, hhold, hsame, hfresh, hdeadQ, h10, h11, hpipe, hquiet, hsilent,
    hpre, hlive, hresT, h18⟩ := hinv
  have hr' : (s.cs c).ph = .recon := by simpa [cs_apply] using hr
  have hrs' : (s.cs c).rsPc = some k := by simpa [cs_apply] using hrs
  have hdn : (s.cs c).dc = none := by
    cases hd : (s.cs c).dc with
    | none => rfl
    | some j => have := (h3 c j hr' hd).2; simp [cs_apply, hro] at this
  have hc : hdC s.cs c k := Or.inr hrs'
  have hk : k < s.nextCh := (hhold c k hc).1
  have hcl : (s.ch k).closed c = false := (hhold c k hc).2
  -- The state before the send.
  let s1 := updS c g
    (updCh k (fun y => { y with q := fun d => if d = c then (s.sd c).early ++ y.q d else y.q d }) s)
  have hsend : send c msg s1 = appendQ k c.other [msg] s1 := by
    have hd1 : (s1.sd c).dc = some k := by
      have := congrArg Core.dc (hg (s.sd c)); simpa [s1] using this
    simp only [send, hd1]
    have : (s1.ch k).dead = false ∧ (s1.ch k).closed c = false := by simp [s1, hdead, hcl]
    simp only [this.1, this.2, Bool.or_false, Bool.false_eq_true, if_false]; rfl
  rw [hsend]
  have tc : ∀ e, (appendQ k c.other [msg] s1).cs e =
      if e = c then { s.cs c with rsOpen := true, dc := some k, early := [] } else s.cs e := by
    intro e; simp only [appendQ_cs, s1]; rw [updS_cs]
    by_cases he : e = c
    · subst he; simp only [if_true, updCh_sd, hg]; rfl
    · simp only [he, if_false]; rfl
  have tf : ∀ e, ((appendQ k c.other [msg] s1).cs e).ph = (s.cs e).ph ∧
      ((appendQ k c.other [msg] s1).cs e).rsPc = (s.cs e).rsPc ∧
      ((appendQ k c.other [msg] s1).cs e).sent = (s.cs e).sent ∧
      ((appendQ k c.other [msg] s1).cs e).rx = (s.cs e).rx ∧
      ((appendQ k c.other [msg] s1).cs e).gap = (s.cs e).gap ∧
      ((appendQ k c.other [msg] s1).cs e).dup = (s.cs e).dup := by
    intro e; rw [tc]; by_cases he : e = c
    · subst he; simp
    · simp [he]
  have tdc : ∀ e, ((appendQ k c.other [msg] s1).cs e).dc = if e = c then some k else (s.cs e).dc := by
    intro e; rw [tc]; split <;> simp
  have thd : ∀ e j, hdC (appendQ k c.other [msg] s1).cs e j ↔ hdC s.cs e j := by
    intro e j; simp only [hdC, tdc, (tf e).2.1]
    by_cases he : e = c
    · subst he; simp only [if_true, hdn, hrs']; simp
    · simp [he]
  have tq : ∀ j e, ((appendQ k c.other [msg] s1).ch j).q e =
      if j = k then (if e = c then (s.sd c).early ++ (s.ch j).q e else (s.ch j).q e ++ [msg])
      else (s.ch j).q e := by
    intro j e; rw [appendQ_q]
    by_cases hj : j = k
    · subst hj; by_cases he : e = c
      · subst he; simp [s1]
      · have : e = c.other := by rcases Cl.eq_or c e with h' | h'; exact absurd h' he; exact h'
        subst this; simp [s1]
    · simp [s1, hj]
  have tib : ∀ e j, inbC (appendQ k c.other [msg] s1).cs (appendQ k c.other [msg] s1).ch e j =
      if j = k ∧ e = c.other then inbC s.cs s.ch e j ++ [msg] else inbC s.cs s.ch e j := by
    intro e j
    simp only [inbC, tq, tc]
    by_cases he : e = c
    · subst he
      by_cases hj : j = k
      · subst hj; simp [hrs, hrs', cs_apply]
      · have hne : (s.cs e).rsPc ≠ some j := by
          rw [hrs']; intro h'; exact hj (Option.some.inj h').symm
        simp [hj, hne]
    · have : e = c.other := by rcases Cl.eq_or c e with h' | h'; exact absurd h' he; exact h'
      subst this
      by_cases hj : j = k
      · subst hj; simp [List.append_assoc]
      · simp [hj]
  have hdd : ∀ j, ((appendQ k c.other [msg] s1).ch j).dead = (s.ch j).dead := by
    intro j; simp [s1]; split <;> rfl
  have hcc : ∀ j e, ((appendQ k c.other [msg] s1).ch j).closed e = (s.ch j).closed e := by
    intro j e; simp [s1]; split <;> rfl
  have hmr : msg.frame? = none := by rw [hmsg]; rfl
  unfold Inv
  simp only [appendQ_nextCh]
  have hn1 : s1.nextCh = s.nextCh := rfl
  rw [hn1]
  constructor
  · intro e he; rw [(tf e).1] at he; rw [(tf e).2.1, tdc]
    by_cases hec : e = c
    · subst hec; rw [hr'] at he; cases he
    · simp only [hec, if_false]; exact h1 e he
  · intro e he; rw [(tf e).1] at he; rw [(tf e).2.1, tdc]
    by_cases hec : e = c
    · subst hec; rw [hr'] at he; cases he
    · simp only [hec, if_false]; exact h2 e he
  · intro e j he hd; rw [(tf e).1] at he; rw [tdc] at hd; rw [(tf e).2.1, tc]
    by_cases hec : e = c
    · subst hec; simp only [if_true] at hd ⊢; cases hd; simp [hrs']
    · simp only [hec, if_false] at hd ⊢; exact h3 e j he hd
  · intro e he hd; rw [(tf e).1] at he; rw [tdc] at hd; rw [tc]
    by_cases hec : e = c
    · subst hec; simp at hd
    · simp only [hec, if_false] at hd ⊢; exact h4 e he hd
  · intro e he; rw [tc] at he; rw [tdc, (tf e).2.1]
    by_cases hec : e = c
    · subst hec; simp at he
    · simp only [hec, if_false] at he ⊢; exact h5 e he
  · intro e j he; rw [thd] at he; rw [hcc]; exact hhold e j he
  · intro e j i he hi; rw [thd] at he hi; exact hsame e j i he hi
  · intro j hj
    have hne : j ≠ k := by omega
    refine ⟨by rw [hdd]; exact (hfresh j hj).1, fun e => ⟨?_, by rw [hcc]; exact ((hfresh j hj).2 e).2⟩⟩
    rw [tq]; simp [hne, ((hfresh j hj).2 e).1]
  · intro j e hj; rw [hdd] at hj; rw [tq]
    have := hdeadQ j e hj
    by_cases hjk : j = k
    · subst hjk; rw [hdead] at hj; cases hj
    · simp [hjk, this]
  · intro e; rw [(tf e).2.2.2.1, (tf e.other).2.2.1]; exact h10 e
  · intro e; rw [(tf e).2.2.2.1, (tf e).2.2.1]; exact h11 e
  · intro e j he
    rw [thd] at he
    obtain ⟨n, a1, a2, a3⟩ := hpipe e j he
    rw [tib, (tf e).2.2.2.1, (tf e.other).2.2.1, (tf e.other).1, tdc, hdd]
    refine ⟨n, ?_, a2, ?_⟩
    · split <;> simp [a1, hmr]
    · intro hl hd hdd'
      by_cases hec : e.other = c
      · rw [hec] at hl; rw [hr'] at hl; cases hl
      · simp only [hec, if_false] at hd; exact a3 hl hd hdd'
  · intro e j hr2 he
    rw [(tf e).1] at hr2; rw [thd] at he; rw [tib]
    have := hquiet e j hr2 he
    split <;> simp [this, hmr]
  · intro e j he hne
    rw [thd] at he; rw [tdc] at hne; rw [tib]
    by_cases hec : e = c
    · subst hec
      have : j = k := by
        rcases he with he | he
        · rw [hdn] at he; cases he
        · rw [hrs'] at he; cases he; rfl
      subst this; simp at hne
    · simp only [hec, if_false] at hne
      have := hsilent e j he hne
      split
      · rename_i hjk; obtain ⟨_, he2⟩ := hjk
        exact absurd (by have := congrArg Cl.other he2; simpa using this) hec
      · exact this
  · intro e j he hne
    rw [thd] at he; rw [tdc] at hne; rw [tib]
    by_cases hec : e = c
    · subst hec
      have : j = k := by
        rcases he with he | he
        · rw [hdn] at he; cases he
        · rw [hrs'] at he; cases he; rfl
      subst this; simp at hne
    · simp only [hec, if_false] at hne
      have := hpre e j he hne
      split <;> simp [this, hmr]
  · intro e j hl hd ho
    rw [(tf e).1] at hl; rw [tdc] at hd; rw [thd] at ho; rw [tdc]
    by_cases hec : e = c
    · subst hec; rw [hr'] at hl; cases hl
    · simp only [hec, if_false] at hd
      have he' : e = c.other := by rcases Cl.eq_or c e with h' | h'; exact absurd h' hec; exact h'
      subst he'
      simp only [Cl.other_other, if_true] at ho ⊢
      rcases ho with ho | ho
      · rw [hdn] at ho; cases ho
      · rw [hrs'] at ho; exact ho
  · intro e j t p a hm hr2 he
    rw [tib] at hm; rw [(tf e).1] at hr2; rw [thd] at he; rw [(tf e.other).2.2.2.1]
    split at hm
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk
      simp only [List.mem_append, List.mem_singleton] at hm
      rcases hm with hm | hm
      · exact hresT _ _ t p a hm hr2 he
      · rw [hmsg] at hm; cases hm; simp [cs_apply]
    · exact hresT e j t p a hm hr2 he
  · intro e; rw [(tf e).2.2.2.2.1, (tf e).2.2.2.2.2]; exact h18 e

theorem Inv.adopt {cfg : Cfg} {s : State} {c : Cl} (h : Inv s) (hen : en cfg s (.adopt c) = true) :
    Inv (adopt cfg c s) := by
  simp only [en, Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true'] at hen
  obtain ⟨⟨hr, hro⟩, hk⟩ := hen
  unfold LinkResume.adopt
  split
  · exact h
  · rename_i k hrs
    rw [hrs] at hk
    simp only [Bool.not_eq_true'] at hk
    exact Inv.deliverN _ (h.adoptPrefix hr hro hrs hk (fun y => rfl) rfl)

/-- The input event: the frame is sent on the open channel, or held. -/
theorem Inv.input {cfg : Cfg} {s : State} {c : Cl} (h : Inv s) (hen : en cfg s (.input c) = true) :
    Inv (step cfg s (.input c)) := by
  simp only [en, Bool.and_eq_true, bne_iff_ne, ne_eq, Bool.not_eq_true', decide_eq_true_eq] at hen
  obtain ⟨⟨⟨⟨hne, -⟩, -⟩, hw⟩, -⟩ := hen
  simp only [step]
  have hu : updS c (fun y => { y with sent := (s.sd c).sent + 1 }) s =
      updS c (fun y => { y with sent := y.sent + 1 }) s := updS_congr rfl
  rw [hu]
  have hph : ((updS c (fun y => { y with sent := y.sent + 1 }) s).sd c).ph = (s.sd c).ph := by simp
  rw [hph]
  by_cases hl : (s.sd c).ph = .live
  · rw [if_pos (by simp [hl])]
    have hinv := h
    unfold Inv at hinv
    obtain ⟨k, hk⟩ : ∃ k, (s.sd c).dc = some k := by
      have := (hinv.liveSh c (by simpa [cs_apply] using hl)).2
      simp only [cs_apply, core_dc] at this
      exact Option.ne_none_iff_exists'.mp this
    have hcl : (s.ch k).closed c = false :=
      (hinv.hold c k (Or.inl (by simpa [cs_apply] using hk))).2
    have hdc1 : ((updS c (fun y => { y with sent := y.sent + 1 }) s).sd c).dc = some k := by simp [hk]
    simp only [send, hdc1, updS_ch, hcl, Bool.or_false]
    by_cases hd : (s.ch k).dead = true
    · rw [if_pos hd]
      exact h.bumpSent hw (fun _ j hj => by rw [hk] at hj; cases hj; exact hd)
    · rw [if_neg hd]
      exact h.sendFrame (k := k) hw hl hk (by simpa using hd)
  · rw [if_neg (by simp [hl])]
    exact h.bumpSent hw (fun h' => absurd h' hl)

theorem Inv.step {cfg : Cfg} {s : State} (h : Inv s) (e : Event) (hen : en cfg s e = true) :
    Inv (step cfg s e) := by
  cases e with
  | input c => exact h.input hen
  | deliver c k => exact h.deliver
  | die k =>
    simp only [en, Bool.and_eq_true, Bool.not_eq_true', decide_eq_true_eq] at hen
    exact h.die hen.2
  | dropped c => exact h.dropped
  | pair => exact h.pair hen
  | adopt c => exact h.adopt hen
  | restart c =>
    simp only [en, beq_iff_eq] at hen
    exact h.restart hen
  | giveUp c => exact h.shutdown
  | quit c => exact h.shutdown
  | kill c => exact h.finish
  | toggle c =>
    simp only [LinkResume.step]
    refine Inv.setPaused ?_
    refine Inv.updS_noncore ?_ h; intro y; rfl
  | away c on => exact h.setAway
  | tick n => exact Inv.congr (s := s) (fun _ => rfl) rfl rfl h
  | ping c => exact h.send_misc rfl rfl
  | noteIn c =>
    simp only [LinkResume.step]
    split
    · exact (h.updS_noncore (c := c) (f := fun y => { y with bye := true }) (fun y => rfl)).shutdown
    · exact h

theorem inv_reachable {cfg : Cfg} {s : State} (h : Reachable cfg s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step e _ hen ih => exact ih.step e hen

/-! ### What the invariant gives -/

/-- **Every input arrives exactly once, in order.** Whatever drops, deaths
    and redials happen, an input that reaches a side is the very next frame
    it needs: never one past it (a gap, which would stall the window for
    good), never one it already has. Holds for every `Cfg`. -/
theorem inputs_exact {cfg : Cfg} {s : State} (h : Reachable cfg s) (c : Cl) :
    (s.sd c).gap = false ∧ (s.sd c).dup = false := by
  have := (inv_reachable h).noGap c
  simpa [cs_apply] using this

/-- A side never holds more of the friend's frames than the friend sent, and
    never runs more than the window ahead of what it holds. -/
theorem frames_bounded {cfg : Cfg} {s : State} (h : Reachable cfg s) (c : Cl) :
    (s.sd c).rx ≤ (s.sd c.other).sent ∧ (s.sd c).sent ≤ (s.sd c).rx + W := by
  have hi := inv_reachable h
  exact ⟨by simpa [cs_apply] using hi.rxLe c, by simpa [cs_apply] using hi.win c⟩

/-- **The 128-entry log always covers the friend's gap.** While a RESUME is
    on its way to a redialing side (in flight on the channel it holds, or
    queued before its open), the side has sent at most
    `2 W` = 24 frames past what the friend says it has, so `rsResumeIn`'s
    "Couldn't resume the link" (gap older than the log) is never taken; 24
    entries would do. -/
theorem log_covers_gap {cfg : Cfg} {s : State} (h : Reachable cfg s) {c : Cl} {k t : Nat}
    {p a : Bool} (hm : Msg.resume t p a ∈ inb s c k) (hr : (s.sd c).ph = .recon)
    (hk : holdsC s c k) :
    (s.sd c).sent ≤ t + 2 * W ∧ 2 * W ≤ LOG ∧ ¬ (s.sd c).sent > t + LOG := by
  have hi := inv_reachable h
  have ht := hi.resT c k t p a hm (by simpa [cs_apply] using hr) hk
  have h1 := hi.win c
  have h2 := hi.rxLe c
  have h3 := hi.win c.other
  simp only [cs_apply, core_sent, core_rx] at ht h1 h2 h3
  refine ⟨by omega, by decide, ?_⟩
  simp only [W, LOG] at *; omega

/-! ## Invariants: pause after a resume, with the fix

With the fix, each side sets its pause from the same two RESUMEs' flags,
so once both have resumed they agree, unless someone pressed Pause (or
backgrounded the app) after resuming, which then reaches the friend as a
normal pause message. The invariant: a RESUME carries its sender's recorded
flags; a pause message on the channel means its sender pressed since its
open; and a side live on the friend's channel, with no press on either
side since, is paused exactly when `finalPause` of the flags says so. -/

/-- The part of a message the pause argument reads. -/
def Msg.pr : Msg → Option Msg
  | .pause v _ => some (.pause v 0)
  | .resume _ p a => some (.resume 0 p a)
  | _ => none

def pinb (s : State) (c : Cl) (k : Nat) : List Msg := (inbC s.cs s.ch c k).filterMap Msg.pr

structure PInv (s : State) : Prop where
  resFlags  : ∀ c k p a, Msg.resume 0 p a ∈ pinb s c k → hdC s.cs c k →
                p = (s.sd c.other).fP ∧ a = (s.sd c.other).fA
  pauseFrom : ∀ c k v, Msg.pause v 0 ∈ pinb s c k → hdC s.cs c k → (s.sd c.other).livePress = true
  agree     : ∀ c k, (s.sd c).ph = .live → (s.sd c).dc = some k → hdC s.cs c.other k →
                (s.sd c).livePress = false → (s.sd c.other).livePress = false →
                (s.sd c).paused = finalPause (s.sd c).fP (s.sd c).fA (s.sd c.other).fP (s.sd c.other).fA

theorem finalPause_comm (pa aa pb ab : Bool) : finalPause pa aa pb ab = finalPause pb ab pa aa := by
  cases pa <;> cases aa <;> cases pb <;> cases ab <;> rfl

/-- The fields of a side the pause argument reads. -/
def Side.pc (x : Side) : Ph × Option Nat × Option Nat × Bool × Bool × Bool × Bool × List Msg :=
  (x.ph, x.dc, x.rsPc, x.paused, x.fP, x.fA, x.livePress, x.early)

theorem PInv.congr {s t : State} (hc : ∀ c, (t.sd c).pc = (s.sd c).pc)
    (hp : ∀ c k, (inbC t.cs t.ch c k).filterMap Msg.pr = (inbC s.cs s.ch c k).filterMap Msg.pr)
    (h : PInv s) : PInv t := by
  have e : ∀ c, (t.sd c).ph = (s.sd c).ph ∧ (t.sd c).dc = (s.sd c).dc ∧ (t.sd c).rsPc = (s.sd c).rsPc ∧
      (t.sd c).paused = (s.sd c).paused ∧ (t.sd c).fP = (s.sd c).fP ∧ (t.sd c).fA = (s.sd c).fA ∧
      (t.sd c).livePress = (s.sd c).livePress := by
    intro c; have := hc c; simp only [Side.pc, Prod.mk.injEq] at this
    exact ⟨this.1, this.2.1, this.2.2.1, this.2.2.2.1, this.2.2.2.2.1, this.2.2.2.2.2.1,
      this.2.2.2.2.2.2.1⟩
  have hd : ∀ c k, hdC t.cs c k ↔ hdC s.cs c k := by
    intro c k; simp only [hdC, cs_apply, core_dc, core_rsPc, (e c).2.1, (e c).2.2.1]
  have hpi : ∀ c k, pinb t c k = pinb s c k := hp
  refine ⟨fun c k p a hm hc' => ?_, fun c k v hm hc' => ?_, fun c k hl hk ho h1 h2 => ?_⟩
  · rw [hpi] at hm; rw [hd] at hc'; rw [(e _).2.2.2.2.1, (e _).2.2.2.2.2.1]
    exact h.resFlags c k p a hm hc'
  · rw [hpi] at hm; rw [hd] at hc'; rw [(e _).2.2.2.2.2.2]; exact h.pauseFrom c k v hm hc'
  · rw [(e c).1] at hl; rw [(e c).2.1] at hk; rw [hd] at ho
    rw [(e c).2.2.2.2.2.2] at h1; rw [(e c.other).2.2.2.2.2.2] at h2
    rw [(e c).2.2.2.1, (e c).2.2.2.2.1, (e c).2.2.2.2.2.1, (e c.other).2.2.2.2.1, (e c.other).2.2.2.2.2.1]
    exact h.agree c k hl hk ho h1 h2

theorem pinit : PInv init := by
  have hq : ∀ c k, pinb init c k = [] := by
    intro c k
    unfold pinb inbC
    by_cases hk : k = 0
    · subst hk; cases c <;> simp [init, cs_apply, Msg.pr]
    · cases c <;> simp [init, cs_apply, hk]
  constructor
  · intro c k p a hm _; rw [hq] at hm; cases hm
  · intro c k v hm _; rw [hq] at hm; cases hm
  · intro c k _ _ _ _ _; cases c <;> simp [init, finalPause, Cl.other]

/-- With the same pause fields, and nothing pause-like on its way that
    wasn't before, the pause invariant carries over. -/
theorem PInv.mono {s t : State}
    (e : ∀ c, (t.sd c).ph = (s.sd c).ph ∧ (t.sd c).dc = (s.sd c).dc ∧ (t.sd c).rsPc = (s.sd c).rsPc ∧
      (t.sd c).paused = (s.sd c).paused ∧ (t.sd c).fP = (s.sd c).fP ∧ (t.sd c).fA = (s.sd c).fA ∧
      (t.sd c).livePress = (s.sd c).livePress)
    (hp : ∀ c k x, x ∈ pinb t c k → x ∈ pinb s c k) (h : PInv s) : PInv t := by
  have hd : ∀ c k, hdC t.cs c k ↔ hdC s.cs c k := by
    intro c k; simp only [hdC, cs_apply, core_dc, core_rsPc, (e c).2.1, (e c).2.2.1]
  refine ⟨fun c k p a hm hc' => ?_, fun c k v hm hc' => ?_, fun c k hl hk ho h1 h2 => ?_⟩
  · rw [hd] at hc'; rw [(e _).2.2.2.2.1, (e _).2.2.2.2.2.1]
    exact h.resFlags c k p a (hp _ _ _ hm) hc'
  · rw [hd] at hc'; rw [(e _).2.2.2.2.2.2]; exact h.pauseFrom c k v (hp _ _ _ hm) hc'
  · rw [(e c).1] at hl; rw [(e c).2.1] at hk; rw [hd] at ho
    rw [(e c).2.2.2.2.2.2] at h1; rw [(e c.other).2.2.2.2.2.2] at h2
    rw [(e c).2.2.2.1, (e c).2.2.2.2.1, (e c).2.2.2.2.2.1, (e c.other).2.2.2.2.1, (e c.other).2.2.2.2.2.1]
    exact h.agree c k hl hk ho h1 h2

theorem updS_sd_self (s : State) (c : Cl) (f : Side → Side) : (updS c f s).sd c = f (s.sd c) := by
  simp
theorem updS_sd_other (s : State) (c : Cl) (f : Side → Side) : (updS c f s).sd c.other = s.sd c.other := by
  simp

theorem PInv.updS_np {s : State} {c : Cl} {f : Side → Side} (hf : ∀ y, (f y).pc = y.pc)
    (h : PInv s) : PInv (updS c f s) := by
  have hc : ∀ d, ((updS c f s).sd d).pc = (s.sd d).pc := by
    intro d; simp only [updS_sd]; split <;> simp [hf]
  refine PInv.congr hc (fun d k => ?_) h
  have h1 : ((updS c f s).sd d).rsPc = (s.sd d).rsPc := by
    have := hc d; simp only [Side.pc, Prod.mk.injEq] at this; exact this.2.2.1
  have h2 : ((updS c f s).sd d).early = (s.sd d).early := by
    have := hc d; simp only [Side.pc, Prod.mk.injEq] at this; exact this.2.2.2.2.2.2.2
  simp only [inbC, cs_apply, core_rsPc, core_early, h1, h2, updS_ch]; rfl

theorem pinb_appendQ (s : State) (k j : Nat) (d e : Cl) (ms : List Msg) :
    pinb (appendQ k d ms s) e j =
      if j = k ∧ e = d then pinb s e j ++ ms.filterMap Msg.pr else pinb s e j := by
  unfold pinb; rw [appendQ_cs, inbC_appendQ]; split <;> simp [List.filterMap_append]

theorem PInv.appendQ_np {s : State} {k : Nat} {d : Cl} {ms : List Msg}
    (hms : ms.filterMap Msg.pr = []) (h : PInv s) : PInv (appendQ k d ms s) := by
  refine PInv.congr (fun c => by simp) (fun c j => ?_) h
  have := pinb_appendQ s k j d c ms
  unfold pinb at this; rw [this]; split <;> simp [hms, pinb]

theorem PInv.send_np {s : State} {c : Cl} {m : Msg} (hm : m.pr = none) (h : PInv s) :
    PInv (send c m s) := by
  rcases send_cases c m s with e | ⟨k, -, -, -, e⟩
  · rw [e]; exact h
  · rw [e]; exact h.appendQ_np (by simp [hm])

theorem PInv.sendAll_frames {s : State} {c : Cl} {t n : Nat} (h : PInv s) :
    PInv (sendAll c (frames t n) s) := by
  rw [sendAll_eq]
  split
  · split
    · exact h
    · refine h.appendQ_np ?_
      unfold frames; induction (List.range' t (n - t)) with
      | nil => rfl
      | cons x xs ih => simp [List.filterMap_cons, Msg.pr, ih]
  · exact h

/-- c lets go of its channel and is no longer live. -/
theorem PInv.release {s : State} {c : Cl} {f : Side → Side} {p : Ph} (h : PInv s) (hp : p ≠ .live)
    (hf : ∀ y, (f y).pc = (p, y.dc, y.rsPc, y.paused, y.fP, y.fA, y.livePress, y.early)) :
    PInv (updS c f (detach c s)) := by
  obtain ⟨-, -, hq, -, -, -, hsc, hso⟩ := detach_parts s c
  have hx := hf ((detach c s).sd c)
  simp only [Side.pc, Prod.mk.injEq] at hx
  obtain ⟨x1, x2, x3, -, x5, x6, x7, x8⟩ := hx
  have tc : ((updS c f (detach c s)).sd c).ph = p ∧ ((updS c f (detach c s)).sd c).dc = none ∧
      ((updS c f (detach c s)).sd c).rsPc = none ∧ ((updS c f (detach c s)).sd c).early = [] ∧
      ((updS c f (detach c s)).sd c).fP = (s.sd c).fP ∧ ((updS c f (detach c s)).sd c).fA = (s.sd c).fA ∧
      ((updS c f (detach c s)).sd c).livePress = (s.sd c).livePress := by
    rw [updS_sd_self, x1, x2, x3, x8, x5, x6, x7, hsc]; simp
  have to : (updS c f (detach c s)).sd c.other = s.sd c.other := by
    rw [updS_sd_other, hso]
  have hdc : ∀ j, ¬ hdC (updS c f (detach c s)).cs c j := by
    intro j; simp only [hdC, cs_apply, core_dc, core_rsPc]; rw [tc.2.1, tc.2.2.1]; simp
  have hdo : ∀ j, hdC (updS c f (detach c s)).cs c.other j ↔ hdC s.cs c.other j := by
    intro j; simp only [hdC, cs_apply, to]
  have hpo : ∀ j, pinb (updS c f (detach c s)) c.other j = pinb s c.other j := by
    intro j; simp only [pinb, inbC, cs_apply, to, updS_ch, hq]; rfl
  refine ⟨fun e k pp a hm he => ?_, fun e k v hm he => ?_, fun e k hl hk ho h1 h2 => ?_⟩
  · rcases Cl.eq_or c e with rfl | rfl
    · exact absurd he (hdc k)
    · rw [hdo] at he; rw [hpo] at hm; simp only [Cl.other_other]
      rw [tc.2.2.2.2.1, tc.2.2.2.2.2.1]
      have := h.resFlags _ k pp a hm he; simpa using this
  · rcases Cl.eq_or c e with rfl | rfl
    · exact absurd he (hdc k)
    · rw [hdo] at he; rw [hpo] at hm; simp only [Cl.other_other]
      rw [tc.2.2.2.2.2.2]
      have := h.pauseFrom _ k v hm he; simpa using this
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [tc.1] at hl; exact absurd hl hp
    · simp only [Cl.other_other] at ho; exact absurd ho (hdc k)

theorem PInv.finish {s : State} {c : Cl} {w : End} (h : PInv s) : PInv (finish c w s) :=
  h.release (p := .ended) (by decide) (fun y => rfl)

theorem PInv.leaveNote {s : State} {c : Cl} {w : End} {x : Side} (h : PInv s) :
    PInv (leaveNote c w x s) := by
  unfold LinkResume.leaveNote; split
  · exact PInv.congr (s := s) (fun _ => rfl) (fun _ _ => rfl) h
  · exact h

theorem PInv.shutdown {s : State} {c : Cl} {w : End} (h : PInv s) : PInv (shutdown c w s) := by
  unfold LinkResume.shutdown
  refine PInv.leaveNote ?_
  split
  · exact h.finish
  · exact (h.send_np rfl).finish

theorem PInv.restart {s : State} {c : Cl} (h : PInv s) (hr : (s.sd c).ph = .recon) :
    PInv (restart c s) := by
  unfold LinkResume.restart
  split
  · exact h.shutdown
  · have h' := h.release (c := c) (p := .recon) (f := fun y => { y with ph := .recon }) (by decide)
      (fun y => rfl)
    refine PInv.congr (s := updS c (fun y => { y with ph := .recon }) (detach c s)) (t := detach c s)
      (fun d => ?_) (fun d k => ?_) h'
    · obtain ⟨-, -, -, -, -, -, hsc, hso⟩ := detach_parts s c
      rcases Cl.eq_or c d with rfl | rfl
      · simp [hsc, Side.pc, hr]
      · simp [hso]
    · unfold inbC; rcases Cl.eq_or c d with rfl | rfl <;> simp [cs_apply, updS_sd_self, updS_sd_other] <;> rfl

theorem PInv.dropped {s : State} {c : Cl} (h : PInv s) : PInv (dropped c s) := by
  unfold LinkResume.dropped
  dsimp only
  split
  · split
    · rename_i hr
      exact h.restart (by simpa using hr)
    · split
      · exact h.shutdown
      · exact h.release (p := .recon) (by decide) (fun y => rfl)
  · exact h.shutdown

theorem PInv.die {s : State} {k : Nat} (h : PInv s) :
    PInv (updCh k (fun x => { x with dead := true, q := fun _ => [] }) s) := by
  refine PInv.mono (s := s) (fun c => ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩) (fun c j x hx => ?_) h
  unfold pinb at hx ⊢
  rw [List.mem_filterMap] at hx ⊢
  obtain ⟨y, hy, hxy⟩ := hx
  refine ⟨y, ?_, hxy⟩
  unfold inbC at hy ⊢
  simp only [updCh_cs, List.mem_append] at hy ⊢
  rcases hy with hy | hy
  · exact Or.inl hy
  · right
    simp only [updCh_ch] at hy
    by_cases hjk : j = k
    · simp [hjk] at hy
    · simpa [hjk] using hy

theorem PInv.pair {s : State} {cfg : Cfg} (hi : Inv s) (h : PInv s) (hen : en cfg s .pair = true) :
    PInv (pair s) := by
  simp only [en, Bool.and_eq_true, beq_iff_eq, Option.isNone_iff_eq_none] at hen
  obtain ⟨⟨⟨⟨⟨hra, hrb⟩, hpa⟩, hpb⟩, hda⟩, hdb⟩ := hen
  have hr : ∀ e, (s.sd e).ph = .recon ∧ (s.sd e).rsPc = none ∧ (s.sd e).dc = none := by
    intro e; cases e <;> simp_all
  have ts : ∀ e, (LinkResume.pair s).sd e = { s.sd e with rsPc := some s.nextCh } := by
    intro e; cases e <;> simp [LinkResume.pair]
  have tch : (LinkResume.pair s).ch = s.ch := by simp [LinkResume.pair]
  have hearly : ∀ e, (s.sd e).early = [] := by
    intro e
    cases hl : (s.sd e).early with
    | nil => rfl
    | cons x xs =>
      have := (hi.earlySh e (by simp [cs_apply, hl])).2; simp [cs_apply, (hr e).2.1] at this
  have thd : ∀ e j, hdC (LinkResume.pair s).cs e j ↔ j = s.nextCh := by
    intro e j; simp [hdC, cs_apply, ts, (hr e).2.2, eq_comm]
  have tpi : ∀ e, pinb (LinkResume.pair s) e s.nextCh = [] := by
    intro e
    have := ((hi.fresh s.nextCh (Nat.le_refl _)).2 e).1
    simp [pinb, inbC, cs_apply, ts, tch, hearly, this]
  refine ⟨fun e k p a hm he => ?_, fun e k v hm he => ?_, fun e k hl _ _ _ _ => ?_⟩
  · rw [thd] at he; subst he; rw [tpi] at hm; cases hm
  · rw [thd] at he; subst he; rw [tpi] at hm; cases hm
  · rw [ts] at hl; simp [(hr e).1] at hl

theorem PInv.input {cfg : Cfg} {s : State} {c : Cl} (h : PInv s) : PInv (step cfg s (.input c)) := by
  simp only [step]
  have h1 : PInv (updS c (fun y => { y with sent := (s.sd c).sent + 1 }) s) := h.updS_np (fun y => rfl)
  split
  · exact h1.send_np rfl
  · exact h1

/-- c's press marks it (if live): from then on its pause messages may
    reach the friend. -/
theorem PInv.markPress {s : State} {c : Cl} {f : Side → Side}
    (hf : ∀ y, (f y).pc = (y.ph, y.dc, y.rsPc, y.paused, y.fP, y.fA, y.livePress || y.ph == .live, y.early))
    (h : PInv s) : PInv (updS c f s) := by
  have tc : ∀ d, ((updS c f s).sd d).ph = (s.sd d).ph ∧ ((updS c f s).sd d).dc = (s.sd d).dc ∧
      ((updS c f s).sd d).rsPc = (s.sd d).rsPc ∧ ((updS c f s).sd d).paused = (s.sd d).paused ∧
      ((updS c f s).sd d).fP = (s.sd d).fP ∧ ((updS c f s).sd d).fA = (s.sd d).fA ∧
      ((updS c f s).sd d).early = (s.sd d).early ∧
      ((updS c f s).sd d).livePress = ((s.sd d).livePress || (d == c && (s.sd d).ph == .live)) := by
    intro d; simp only [updS_sd]
    by_cases hd : d = c
    · subst hd; have := hf (s.sd d); simp only [Side.pc, Prod.mk.injEq] at this; simp [this]
    · simp [hd]
  have hd : ∀ d k, hdC (updS c f s).cs d k ↔ hdC s.cs d k := by
    intro d k; simp only [hdC, cs_apply, core_dc, core_rsPc, (tc d).2.1, (tc d).2.2.1]
  have hp : ∀ d k, pinb (updS c f s) d k = pinb s d k := by
    intro d k; simp only [pinb, inbC, cs_apply, core_rsPc, core_early, (tc d).2.2.1, (tc d).2.2.2.2.2.2.1,
      updS_ch]; rfl
  refine ⟨fun e k p a hm he => ?_, fun e k v hm he => ?_, fun e k hl hk ho h1 h2 => ?_⟩
  · rw [hp] at hm; rw [hd] at he; rw [(tc _).2.2.2.2.1, (tc _).2.2.2.2.2.1]
    exact h.resFlags e k p a hm he
  · rw [hp] at hm; rw [hd] at he; rw [(tc _).2.2.2.2.2.2.2]
    simp [h.pauseFrom e k v hm he]
  · rw [(tc e).1] at hl; rw [(tc e).2.1] at hk; rw [hd] at ho
    rw [(tc e).2.2.2.2.2.2.2] at h1; rw [(tc e.other).2.2.2.2.2.2.2] at h2
    simp only [Bool.or_eq_false_iff] at h1 h2
    rw [(tc e).2.2.2.1, (tc e).2.2.2.2.1, (tc e).2.2.2.2.2.1, (tc e.other).2.2.2.2.1,
      (tc e.other).2.2.2.2.2.1]
    exact h.agree e k hl hk ho h1.1 h2.1

/-- A pause message from a side that has pressed: nothing claimed about it,
    and the friend may take it. -/
theorem PInv.sendPause_lp {s : State} {c : Cl} {v : Bool} {n : Nat} (h : PInv s)
    (hlp : (s.sd c).livePress = true) : PInv (send c (.pause v n) s) := by
  rcases send_cases c (.pause v n) s with heq | ⟨k, hk, -, -, heq⟩
  · rw [heq]; exact h
  · rw [heq]
    refine ⟨fun e k' p a hm' he => ?_, fun e k' w hm' he => ?_, fun e k' hl2 hk2 ho h1' h2' => ?_⟩
    · rw [pinb_appendQ] at hm'; simp only [appendQ_sd, appendQ_cs] at he ⊢
      split at hm'
      · simp [Msg.pr] at hm'; exact h.resFlags e k' p a hm' he
      · exact h.resFlags e k' p a hm' he
    · rw [pinb_appendQ] at hm'; simp only [appendQ_sd, appendQ_cs] at he ⊢
      split at hm'
      · rename_i hjk; obtain ⟨rfl, he2⟩ := hjk
        simp only [List.mem_append, List.filterMap_cons, Msg.pr, List.filterMap_nil,
          List.mem_singleton] at hm'
        rcases hm' with hm' | hm'
        · exact h.pauseFrom e k' w hm' he
        · have : e.other = c := by rw [he2]; simp
          rw [this]; exact hlp
      · exact h.pauseFrom e k' w hm' he
    · simp only [appendQ_sd, appendQ_cs] at hl2 hk2 ho h1' h2' ⊢
      exact h.agree e k' hl2 hk2 ho h1' h2'

theorem PInv.press_lp {s : State} {c : Cl} {v : Bool} (h : PInv s)
    (hlp : (s.sd c).livePress = true) : PInv (press c v s) := by
  unfold LinkResume.press
  exact (h.sendPause_lp (n := (s.sd c).reg.n + 1) (v := v) hlp).updS_np (c := c)
    (f := fun y => { y with reg := ⟨(s.sd c).reg.n + 1, c == .a, v⟩ }) (fun y => rfl)

/-- A press already marked: the state changes and is relayed if live. -/
theorem PInv.setPaused_pressed {s : State} {c : Cl} {v : Bool} (h : PInv s)
    (hm : (s.sd c).ph = .live → (s.sd c).livePress = true) : PInv (setPaused c v true s) := by
  unfold LinkResume.setPaused
  split
  · exact h
  · dsimp only
    -- the state after the change, before the relay
    have tc : ∀ d, ((updS c (fun y => { y with paused := v, pfb := false }) s).sd d).pc =
        if d = c then ((s.sd c).ph, (s.sd c).dc, (s.sd c).rsPc, v, (s.sd c).fP, (s.sd c).fA,
          (s.sd c).livePress, (s.sd c).early) else (s.sd d).pc := by
      intro d; simp only [updS_sd]; split <;> simp_all [Side.pc]
    have h1 : PInv (updS c (fun y => { y with paused := v, pfb := false }) s) := by
      have hd : ∀ d k, hdC (updS c (fun y => { y with paused := v, pfb := false }) s).cs d k ↔
          hdC s.cs d k := by
        intro d k; simp only [hdC, cs_apply, core_dc, core_rsPc, updS_sd]; split <;> simp_all
      have hp : ∀ d k, pinb (updS c (fun y => { y with paused := v, pfb := false }) s) d k = pinb s d k := by
        intro d k; simp only [pinb, inbC, cs_apply, core_rsPc, core_early, updS_sd, updS_ch]
        split <;> simp_all <;> rfl
      refine ⟨fun e k p a hm' he => ?_, fun e k w hm' he => ?_, fun e k hl hk ho h1 h2 => ?_⟩
      · rw [hp] at hm'; rw [hd] at he
        have := h.resFlags e k p a hm' he
        simp only [updS_sd]; split <;> simp_all
      · rw [hp] at hm'; rw [hd] at he
        have := h.pauseFrom e k w hm' he
        simp only [updS_sd]; split <;> simp_all
      · rw [hd] at ho
        by_cases hec : e = c
        · subst hec; simp only [updS_sd, if_pos rfl] at hl h1
          rw [hm hl] at h1; cases h1
        · have hoc : e.other = c := by rcases Cl.eq_or c e with h' | h'; exact absurd h' hec; simp [h']
          simp only [updS_sd, hec, if_false, hoc, if_pos rfl] at hl hk h1 h2 ⊢
          have := h.agree e k hl hk ho h1 (by rw [hoc]; exact h2)
          rw [hoc] at this; exact this
    split
    · rename_i hl
      -- the relayed press: from a pressed side
      have hl' : (s.sd c).ph = .live := by simpa using hl
      exact h1.press_lp (by simpa using hm hl')
    · exact h1

theorem PInv.toggle {cfg : Cfg} {s : State} {c : Cl} (h : PInv s) : PInv (step cfg s (.toggle c)) := by
  simp only [step]
  refine PInv.setPaused_pressed (h.markPress (fun y => rfl)) ?_
  intro hl; simp only [updS_sd_self] at hl ⊢; simp [hl]

theorem PInv.setAway {cfg : Cfg} {s : State} {c : Cl} {on : Bool} (h : PInv s) :
    PInv (setAway cfg c on s) := by
  unfold LinkResume.setAway
  have h' := h.markPress (c := c)
    (f := fun y => { y with away := on, livePress := y.livePress || y.ph == .live }) (fun y => rfl)
  have hm : ((updS c (fun y => { y with away := on, livePress := y.livePress || y.ph == .live }) s).sd c).ph =
      .live → ((updS c (fun y => { y with away := on, livePress := y.livePress || y.ph == .live }) s).sd c).livePress
        = true := by
    intro hl; simp only [updS_sd_self] at hl ⊢; simp [hl]
  dsimp only
  split
  · exact h'
  · split
    · split
      · exact h'
      · exact (h'.setPaused_pressed hm).updS_np (fun y => rfl)
    · split
      · refine PInv.setPaused_pressed (h'.updS_np (fun y => rfl)) ?_
        intro hl
        have := hm (by simpa [updS_sd_self] using hl)
        simpa [updS_sd_self] using this
      · exact h'

/-- The head of a queue leaves it. -/
theorem PInv.pop {s : State} {c : Cl} {k : Nat} {m : Msg} {rest : List Msg} (h : PInv s)
    (hq : (s.ch k).q c = m :: rest) : PInv (popQ k c rest s) := by
  refine PInv.mono (s := s) (fun c => ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩) (fun e j x hx => ?_) h
  unfold pinb at hx ⊢
  rw [popQ_cs, inbC_popQ] at hx
  rw [List.mem_filterMap] at hx ⊢
  obtain ⟨y, hy, hxy⟩ := hx
  refine ⟨y, ?_, hxy⟩
  split at hy
  · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk
    unfold inbC; rw [hq]; exact mem_drop_mid hy
  · exact hy

/-- c takes the friend's pause message: the friend pressed, so nothing is
    claimed about c. -/
theorem PInv.setPaused_lpOther {s : State} {c : Cl} {v : Bool} (h : PInv s)
    (hlp : (s.sd c.other).livePress = true) : PInv (setPaused c v false s) := by
  unfold LinkResume.setPaused
  split
  · exact h
  · dsimp only
    simp only [Bool.false_and, Bool.false_eq_true, if_false]
    have hd : ∀ d k, hdC (updS c (fun y => { y with paused := v, pfb := false }) s).cs d k ↔
        hdC s.cs d k := by
      intro d k; simp only [hdC, cs_apply, core_dc, core_rsPc, updS_sd]; split <;> simp_all
    have hp : ∀ d k, pinb (updS c (fun y => { y with paused := v, pfb := false }) s) d k = pinb s d k := by
      intro d k; simp only [pinb, inbC, cs_apply, core_rsPc, core_early, updS_sd, updS_ch]
      split <;> simp_all <;> rfl
    refine ⟨fun e k p a hm' he => ?_, fun e k w hm' he => ?_, fun e k hl hk ho h1 h2 => ?_⟩
    · rw [hp] at hm'; rw [hd] at he
      have := h.resFlags e k p a hm' he
      simp only [updS_sd]; split <;> simp_all
    · rw [hp] at hm'; rw [hd] at he
      have := h.pauseFrom e k w hm' he
      simp only [updS_sd]; split <;> simp_all
    · rw [hd] at ho
      by_cases hec : e = c
      · subst hec; simp only [updS_sd_other] at h2; rw [hlp] at h2; cases h2
      · have hoc : e.other = c := by rcases Cl.eq_or c e with h' | h'; exact absurd h' hec; simp [h']
        simp only [updS_sd, hec, if_false, hoc, if_pos rfl] at hl hk h1 h2 ⊢
        have := h.agree e k hl hk ho h1 (by rw [hoc]; exact h2)
        rw [hoc] at this; exact this

def liveP (x : Side) (v : Bool) : Side := { x with ph := .live, rsPc := none, paused := v }

theorem frames_pr_nil (t n : Nat) : (frames t n).filterMap Msg.pr = [] := by
  unfold frames; induction (List.range' t (n - t)) with
  | nil => rfl
  | cons x xs ih => simp [List.filterMap_cons, Msg.pr, ih]

/-- With the fix: c, redialing on its open channel k, reads the friend's
    RESUME, goes live, resends the gap, and takes `finalPause` of the flags. -/
theorem PInv.resumeFix {s : State} {c : Cl} {k t : Nat} {p a : Bool} {g : Side → Side} (hi : Inv s)
    (h : PInv s) (hr : (s.sd c).ph = .recon) (hdc : (s.sd c).dc = some k)
    (hp : p = (s.sd c.other).fP) (ha : a = (s.sd c.other).fA)
    (hg : ∀ y, g y = { y with ph := .live, rsPc := none }) :
    PInv (remotePause c (finalPause (s.sd c).fP (s.sd c).fA p a)
      (sendAll c (frames t (s.sd c).sent) (updS c g s))) := by
  have hdc' : (s.cs c).dc = some k := by simpa [cs_apply] using hdc
  have hrs : (s.sd c).rsPc = some k := by
    have := (hi.reconDc c k (by simpa [cs_apply] using hr) hdc').1; simpa [cs_apply] using this
  have hearly : (s.sd c).early = [] := by
    cases hl : (s.sd c).early with
    | nil => rfl
    | cons x xs =>
      have := (hi.earlySh c (by simp [cs_apply, hl])).1; simp [cs_apply, hdc] at this
  have hcl : (s.ch k).closed c = false := (hi.hold c k (Or.inl hdc')).2
  -- The resend: queued on k if it's alive.
  have hsend : sendAll c (frames t (s.sd c).sent) (updS c g s) =
      if (s.ch k).dead then updS c g s else appendQ k c.other (frames t (s.sd c).sent) (updS c g s) := by
    rw [sendAll_eq]
    have : ((updS c g s).sd c).dc = some k := by rw [updS_sd_self, hg]; exact hdc
    simp only [this, updS_ch, hcl, Bool.or_false]
  have hS : ∀ S, (S = updS c g s ∨ S = appendQ k c.other (frames t (s.sd c).sent) (updS c g s)) →
      (∀ e, S.sd e = if e = c then { s.sd c with ph := .live, rsPc := none } else s.sd e) ∧
      (∀ e j, pinb S e j = pinb s e j) := by
    intro S hSe
    have hsd : ∀ e, S.sd e = if e = c then { s.sd c with ph := .live, rsPc := none } else s.sd e := by
      intro e
      rcases hSe with rfl | rfl <;>
        (simp only [appendQ_sd, updS_sd, hg]; by_cases hec : e = c
         · subst hec; simp
         · simp [hec])
    refine ⟨hsd, fun e j => ?_⟩
    have hpre : (inbC S.cs S.ch e j).filterMap Msg.pr = (inbC s.cs S.ch e j).filterMap Msg.pr := by
      unfold inbC; simp only [cs_apply, core_rsPc, core_early, hsd]
      by_cases hec : e = c
      · subst hec; simp [hrs, hearly]
      · simp only [hec, if_false]; rfl
    unfold pinb; rw [hpre]
    rcases hSe with rfl | rfl
    · rfl
    · unfold inbC; rw [appendQ_q]; simp only [updS_ch]
      by_cases hjk : j = k ∧ e = c.other
      · simp only [hjk, and_self, if_true, ← List.append_assoc, List.filterMap_append, frames_pr_nil,
          List.append_nil]
      · simp only [hjk, if_false]
  have hS4 := hS (sendAll c (frames t (s.sd c).sent) (updS c g s)) (by
    rw [hsend]; split
    · exact Or.inl rfl
    · exact Or.inr rfl)
  obtain ⟨h3, hpi⟩ := hS4
  generalize sendAll c (frames t (s.sd c).sent) (updS c g s) = S4 at h3 hpi ⊢
  -- The final state: c live with `finalPause`, the rest as before.
  have hfin : ∀ (t' : State),
      (∀ e, (t'.sd e).ph = (if e = c then .live else (s.sd e).ph) ∧ (t'.sd e).dc = (s.sd e).dc ∧
        (t'.sd e).rsPc = (if e = c then none else (s.sd e).rsPc) ∧
        (t'.sd e).paused = (if e = c then finalPause (s.sd c).fP (s.sd c).fA p a else (s.sd e).paused) ∧
        (t'.sd e).fP = (s.sd e).fP ∧ (t'.sd e).fA = (s.sd e).fA ∧
        (t'.sd e).livePress = (s.sd e).livePress) →
      (∀ e j, pinb t' e j = pinb s e j) → PInv t' := by
    intro t' tf hpt
    have thd : ∀ e j, hdC t'.cs e j ↔ hdC s.cs e j := by
      intro e j; simp only [hdC, cs_apply, core_dc, core_rsPc, (tf e).2.1, (tf e).2.2.1]
      by_cases hec : e = c
      · subst hec; simp only [if_true]; rw [hdc, hrs]; simp
      · simp [hec]
    refine ⟨fun e j p' a' hm he => ?_, fun e j v hm he => ?_, fun e j hl hk ho h1 h2 => ?_⟩
    · rw [hpt] at hm; rw [thd] at he; rw [(tf _).2.2.2.2.1, (tf _).2.2.2.2.2.1]
      exact h.resFlags e j p' a' hm he
    · rw [hpt] at hm; rw [thd] at he; rw [(tf _).2.2.2.2.2.2]
      exact h.pauseFrom e j v hm he
    · rw [thd] at ho
      rw [(tf e).2.2.2.2.1, (tf e).2.2.2.2.2.1, (tf e.other).2.2.2.2.1, (tf e.other).2.2.2.2.2.1,
        (tf e).2.2.2.1]
      by_cases hec : e = c
      · subst hec; simp only [if_true, hp, ha]
      · rw [(tf e).1] at hl; rw [(tf e).2.1] at hk
        rw [(tf e).2.2.2.2.2.2] at h1; rw [(tf e.other).2.2.2.2.2.2] at h2
        simp only [hec, if_false] at hl ⊢
        exact h.agree e j hl hk ho h1 h2
  unfold LinkResume.remotePause LinkResume.setPaused
  dsimp only
  by_cases heq : (S4.sd c).paused = finalPause (s.sd c).fP (s.sd c).fA p a
  · rw [if_pos heq]
    refine hfin S4 (fun e => ?_) hpi
    rw [h3]; by_cases hec : e = c
    · subst hec
      have hpe := heq; rw [h3] at hpe; simp only [if_true] at hpe
      simp [hpe]
    · simp [hec]
  · rw [if_neg heq]
    simp only [Bool.false_and, Bool.false_eq_true, if_false]
    refine hfin _ (fun e => ?_) (fun e j => ?_)
    · simp only [updS_sd, h3]; by_cases hec : e = c
      · subst hec; simp
      · simp [hec]
    · rw [← hpi e j]; unfold pinb inbC
      simp only [cs_apply, core_rsPc, core_early, updS_sd, updS_ch]
      split <;> simp_all <;> rfl

/-- With the fix, when c's pause changed after its RESUME went out: c keeps
    it, counts as having pressed, and relays it if the friend decided
    otherwise. -/
theorem PInv.resumePress {s : State} {c : Cl} {k t : Nat} {g : Side → Side} {v : Bool} (hi : Inv s)
    (h : PInv s) (hr : (s.sd c).ph = .recon) (hdc : (s.sd c).dc = some k)
    (hg : ∀ y, g y = { y with ph := .live, rsPc := none }) (snd : Bool) :
    PInv ((fun S => if snd then press c v S else S)
      (updS c (fun y => { y with livePress := y.livePress || y.ph == .live })
        (sendAll c (frames t (s.sd c).sent) (updS c g s)))) := by
  have hdc' : (s.cs c).dc = some k := by simpa [cs_apply] using hdc
  have hrs : (s.sd c).rsPc = some k := by
    have := (hi.reconDc c k (by simpa [cs_apply] using hr) hdc').1; simpa [cs_apply] using this
  have hearly : (s.sd c).early = [] := by
    cases hl : (s.sd c).early with
    | nil => rfl
    | cons x xs =>
      have := (hi.earlySh c (by simp [cs_apply, hl])).1; simp [cs_apply, hdc] at this
  have hcl : (s.ch k).closed c = false := (hi.hold c k (Or.inl hdc')).2
  -- The resend: queued on k if it's alive.
  have hsend : sendAll c (frames t (s.sd c).sent) (updS c g s) =
      if (s.ch k).dead then updS c g s else appendQ k c.other (frames t (s.sd c).sent) (updS c g s) := by
    rw [sendAll_eq]
    have : ((updS c g s).sd c).dc = some k := by rw [updS_sd_self, hg]; exact hdc
    simp only [this, updS_ch, hcl, Bool.or_false]
  have hS : ∀ S, (S = updS c g s ∨ S = appendQ k c.other (frames t (s.sd c).sent) (updS c g s)) →
      (∀ e, S.sd e = if e = c then { s.sd c with ph := .live, rsPc := none } else s.sd e) ∧
      (∀ e j, pinb S e j = pinb s e j) := by
    intro S hSe
    have hsd : ∀ e, S.sd e = if e = c then { s.sd c with ph := .live, rsPc := none } else s.sd e := by
      intro e
      rcases hSe with rfl | rfl <;>
        (simp only [appendQ_sd, updS_sd, hg]; by_cases hec : e = c
         · subst hec; simp
         · simp [hec])
    refine ⟨hsd, fun e j => ?_⟩
    have hpre : (inbC S.cs S.ch e j).filterMap Msg.pr = (inbC s.cs S.ch e j).filterMap Msg.pr := by
      unfold inbC; simp only [cs_apply, core_rsPc, core_early, hsd]
      by_cases hec : e = c
      · subst hec; simp [hrs, hearly]
      · simp only [hec, if_false]; rfl
    unfold pinb; rw [hpre]
    rcases hSe with rfl | rfl
    · rfl
    · unfold inbC; rw [appendQ_q]; simp only [updS_ch]
      by_cases hjk : j = k ∧ e = c.other
      · simp only [hjk, and_self, if_true, ← List.append_assoc, List.filterMap_append, frames_pr_nil,
          List.append_nil]
      · simp only [hjk, if_false]
  have hS4 := hS (sendAll c (frames t (s.sd c).sent) (updS c g s)) (by
    rw [hsend]; split
    · exact Or.inl rfl
    · exact Or.inr rfl)
  obtain ⟨h3, hpi⟩ := hS4

  generalize sendAll c (frames t (s.sd c).sent) (updS c g s) = S4 at h3 hpi ⊢
  -- c marked as having pressed; nothing else in the pause picture moved.
  have hT : PInv (updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) S4) := by
    have tf : ∀ e, ((updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) S4).sd e).dc
          = (s.sd e).dc ∧
        ((updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) S4).sd e).rsPc
          = (if e = c then none else (s.sd e).rsPc) ∧
        ((updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) S4).sd e).fP = (s.sd e).fP ∧
        ((updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) S4).sd e).fA = (s.sd e).fA ∧
        ((updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) S4).sd e).livePress
          = (if e = c then true else (s.sd e).livePress) ∧
        ((updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) S4).sd e).paused
          = (s.sd e).paused ∧
        ((updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) S4).sd e).ph
          = (if e = c then .live else (s.sd e).ph) := by
      intro e; simp only [updS_sd, h3]
      by_cases hec : e = c
      · subst hec; simp
      · simp [hec]
    have thd : ∀ e j, hdC (updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) S4).cs e j ↔
        hdC s.cs e j := by
      intro e j; simp only [hdC, cs_apply, core_dc, core_rsPc, (tf e).1, (tf e).2.1]
      by_cases hec : e = c
      · subst hec; simp only [if_true]; rw [hdc, hrs]; simp
      · simp [hec]
    have hpt : ∀ e j, pinb (updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) S4) e j =
        pinb s e j := by
      intro e j; rw [← hpi e j]; unfold pinb inbC
      simp only [cs_apply, core_rsPc, core_early, updS_sd, updS_ch]
      split <;> simp_all <;> rfl
    refine ⟨fun e j p' a' hm he => ?_, fun e j w hm he => ?_, fun e j hl hk ho h1 h2 => ?_⟩
    · rw [hpt] at hm; rw [thd] at he; rw [(tf _).2.2.1, (tf _).2.2.2.1]
      exact h.resFlags e j p' a' hm he
    · rw [hpt] at hm; rw [thd] at he; rw [(tf _).2.2.2.2.1]
      have := h.pauseFrom e j w hm he
      split <;> simp_all
    · rw [(tf e).2.2.2.2.1] at h1; rw [(tf e.other).2.2.2.2.1] at h2
      by_cases hec : e = c
      · subst hec; simp at h1
      · have hoc : e.other = c := by rcases Cl.eq_or c e with h' | h'; exact absurd h' hec; simp [h']
        simp [hoc] at h2
  cases snd
  · exact hT
  · exact hT.press_lp (by simp [updS_sd_self, h3])

/-- A message for the pairing c is still opening goes to `rsEarly`. -/
theorem PInv.earlyPush {s : State} {c : Cl} {k : Nat} {m : Msg} {rest : List Msg} (h : PInv s)
    (hq : (s.ch k).q c = m :: rest) (hrs : (s.sd c).rsPc = some k) :
    PInv (updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)) := by
  refine PInv.mono (s := s) (fun e => ?_) (fun e j x hx => ?_) h
  · simp only [updS_sd, popQ_sd]; split <;> simp
  · unfold pinb inbC at hx ⊢
    rw [List.mem_filterMap] at hx ⊢
    obtain ⟨y, hy, hxy⟩ := hx
    refine ⟨y, ?_, hxy⟩
    simp only [cs_apply, core_rsPc, core_early, updS_sd, popQ_sd, updS_ch] at hy
    rw [popQ_q] at hy
    simp only [cs_apply, core_rsPc, core_early]
    by_cases hec : e = c
    · subst hec
      simp only [if_true] at hy
      by_cases hj : j = k
      · subst hj; simp only [hrs, if_true, and_self] at hy ⊢; rw [hq]
        simp only [List.mem_append, List.mem_cons, List.not_mem_nil, or_false] at hy ⊢
        rcases hy with (hy | hy) | hy
        · exact Or.inl hy
        · exact Or.inr (Or.inl hy)
        · exact Or.inr (Or.inr hy)
      · have hne : (s.sd e).rsPc ≠ some j := by
          rw [hrs]; intro h'; exact hj (Option.some.inj h').symm
        simp only [hj, false_and, if_false, hne] at hy ⊢; exact hy
    · simp only [hec, if_false, and_false] at hy ⊢; exact hy

theorem send_sd (c : Cl) (m : Msg) (s : State) : (send c m s).sd = s.sd := by
  rcases send_cases c m s with e | ⟨k, -, -, -, e⟩ <;> rw [e]; rfl

theorem sendAll_sd (c : Cl) (ms : List Msg) (s : State) : (sendAll c ms s).sd = s.sd := by
  induction ms generalizing s with
  | nil => rfl
  | cons m ms ih => simp only [sendAll]; rw [ih, send_sd]

/-- Reading one message keeps the pause invariant, with the fix. -/
theorem PInv.deliver {cfg : Cfg} (hfix : cfg.fix = true) {s : State} {c : Cl} {k : Nat} (hi : Inv s)
    (h : PInv s) : PInv (deliver cfg c k s) := by
  unfold LinkResume.deliver
  split
  · exact h
  · rename_i m rest hq
    dsimp only
    have hpop : updCh k (fun x => { x with q := fun d => if d = c then rest else x.q d }) s =
        popQ k c rest s := rfl
    rw [hpop]
    have hp1 : PInv (popQ k c rest s) := h.pop hq
    have hmem : ∀ x, x.pr ≠ none → (m.pr = some x) → x ∈ pinb s c k := by
      intro x _ hx; unfold pinb inbC; rw [hq, List.mem_filterMap]
      exact ⟨m, by simp, hx⟩
    split
    · exact hp1
    · split
      · rename_i hd
        have hd : (s.sd c).dc = some k := by simpa using hd
        have hc : hdC s.cs c k := Or.inl (by simpa [cs_apply] using hd)
        cases m with
        | inp f =>
          simp only [recv]
          refine PInv.updS_np ?_ ?_
          · intro y; rfl
          · refine PInv.updS_np ?_ hp1; intro y; rfl
        | info =>
          have h2 : PInv (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s)) := by
            refine PInv.updS_np ?_ hp1; intro y; rfl
          simp only [recv]
          split
          · refine PInv.updS_np ?_ h2; intro y; rfl
          · refine PInv.send_np rfl ?_; refine PInv.updS_np ?_ h2; intro y; rfl
        | ping =>
          simp only [recv]
          refine PInv.updS_np ?_ hp1; intro y; rfl
        | pause v n =>
          have h2 : PInv (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s)) := by
            refine PInv.updS_np ?_ hp1; intro y; rfl
          have hlp := h.pauseFrom c k v (hmem _ (by simp [Msg.pr]) rfl) hc
          simp only [recv]
          split
          · split
            · refine PInv.setPaused_lpOther (h2.updS_np (c := c)
                (f := fun y => { y with reg := ⟨n, c.other == .a, v⟩ }) (fun y => rfl)) ?_
              rw [updS_sd_other, updS_sd_other]; exact hlp
            · exact h2
          · refine PInv.setPaused_lpOther h2 ?_
            rw [updS_sd_other]; exact hlp
        | bye =>
          simp only [recv]
          refine PInv.shutdown ?_
          refine PInv.updS_np ?_ ?_
          · intro y; rfl
          · refine PInv.updS_np ?_ hp1; intro y; rfl
        | resume t p a =>
          have hi1 : Inv (popQ k c rest s) := hi.pop hq (fun _ => rfl)
          have hi2 : Inv (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s)) := by
            refine Inv.updS_noncore ?_ hi1; intro y; rfl
          have h2 : PInv (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s)) := by
            refine PInv.updS_np ?_ hp1; intro y; rfl
          have hfl := h.resFlags c k p a (hmem _ (by simp [Msg.pr]) rfl) hc
          show PInv (resumeIn cfg c t p a
            (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s)))
          unfold resumeIn
          dsimp only
          split
          · exact h2
          · rename_i hg
            split
            · exact h2.shutdown
            · have hr : (s.sd c).ph = .recon := by
                simp only [Bool.not_eq_true', Bool.not_eq_false, Bool.and_eq_true, beq_iff_eq] at hg
                simpa using hg.1.1
              -- the registers' reset touches nothing the pause argument reads
              have hi3 := hi2.updS_noncore (c := c)
                (f := fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) }) (fun y => rfl)
              have h3 := h2.updS_np (c := c)
                (f := fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) }) (fun y => rfl)
              rw [show ((updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s)).sd c).sent
                = ((updS c (fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) })
                    (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s))).sd c).sent
                by simp]
              have hr3 : ((updS c (fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) })
                  (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s))).sd c).ph
                  = .recon := by simpa using hr
              have hd3 : ((updS c (fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) })
                  (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s))).sd c).dc
                  = some k := by simpa using hd
              have hfl3 : p = ((updS c (fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) })
                    (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s))).sd c.other).fP ∧
                  a = ((updS c (fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) })
                    (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s))).sd c.other).fA := by
                simpa using hfl
              generalize updS c (fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) })
                (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s)) = S3
                at hi3 h3 hr3 hd3 hfl3 ⊢
              unfold pauseAfterResume
              rw [if_pos hfix]
              dsimp only
              rw [sendAll_sd, updS_sd_self]
              split
              · split
                · exact PInv.resumePress (c := c) (k := k) hi3 h3 hr3 hd3 (fun y => rfl) true
                · exact PInv.resumePress (c := c) (k := k) (v := false) hi3 h3 hr3 hd3 (fun y => rfl) false
              · exact PInv.resumeFix (c := c) (k := k) hi3 h3 hr3 hd3 hfl3.1 hfl3.2 (fun y => rfl)
      · split
        · rename_i hd hrs
          split
          · exact h.earlyPush hq (by simpa using hrs)
          · exact hp1
        · exact hp1

theorem PInv.deliverN {cfg : Cfg} (hfix : cfg.fix = true) {s : State} {c : Cl} {k : Nat} (n : Nat)
    (hi : Inv s) (h : PInv s) : PInv (deliverN cfg c k n s) ∧ Inv (deliverN cfg c k n s) := by
  induction n generalizing s with
  | zero => exact ⟨h, hi⟩
  | succ n ih => exact ih hi.deliver (h.deliver hfix hi)

/-- `rsAdopt` up to the replay, for the pause invariant: c records the flags
    its RESUME carries, and nothing else is on the channel from c yet. -/
theorem PInv.adoptPrefix {s : State} {c : Cl} {k : Nat} {msg : Msg} (hi : Inv s) (h : PInv s)
    (hr : (s.sd c).ph = .recon) (hro : (s.sd c).rsOpen = false) (hrs : (s.sd c).rsPc = some k)
    (hdead : (s.ch k).dead = false)
    (hmsg : msg = .resume (s.sd c).rx (s.sd c).paused (s.sd c).away) :
    PInv (send c msg (updS c (openSide k)
      (updCh k (fun y => { y with q := fun d => if d = c then (s.sd c).early ++ y.q d else y.q d }) s))) := by
  have hr' : (s.cs c).ph = .recon := by simpa [cs_apply] using hr
  have hrs' : (s.cs c).rsPc = some k := by simpa [cs_apply] using hrs
  have hdn : (s.sd c).dc = none := by
    cases hd : (s.sd c).dc with
    | none => rfl
    | some j =>
      have := (hi.reconDc c j hr' (by simpa [cs_apply] using hd)).2; simp [cs_apply, hro] at this
  have hc : hdC s.cs c k := Or.inr hrs'
  have hsil : inbC s.cs s.ch c.other k = [] := hi.silent c k hc (by simp [cs_apply, hdn])
  have hnl : ¬ ((s.sd c.other).ph = .live ∧ (s.sd c.other).dc = some k) := by
    intro ⟨hl, hd⟩
    have := hi.liveOpen c.other k (by simpa [cs_apply] using hl) (by simpa [cs_apply] using hd)
      (by simpa using hc)
    simp [cs_apply, hdn] at this
  generalize hS1 : updS c (openSide k) (updCh k (fun y => { y with q := fun d => if d = c then (s.sd c).early ++ y.q d else y.q d }) s) = S1
  have s1c : S1.sd c = openSide k (s.sd c) := by rw [← hS1, updS_sd_self]; rfl
  have s1o : S1.sd c.other = s.sd c.other := by rw [← hS1, updS_sd_other]; rfl
  have s1q : ∀ j e, (S1.ch j).q e = if j = k ∧ e = c then (s.sd c).early ++ (s.ch j).q e else (s.ch j).q e := by
    intro j e; rw [← hS1]; simp only [updS_ch, updCh_ch]
    by_cases hj : j = k <;> by_cases he : e = c <;> simp [hj, he]
  have s1d : ∀ j, (S1.ch j).dead = (s.ch j).dead := by
    intro j; rw [← hS1]; simp only [updS_ch, updCh_ch]; split <;> rfl
  have s1cl : ∀ j, (S1.ch j).closed = (s.ch j).closed := by
    intro j; rw [← hS1]; simp only [updS_ch, updCh_ch]; split <;> rfl
  -- The send: RESUME on k.
  have hsend : send c msg S1 = appendQ k c.other [msg] S1 := by
    have hcl : (s.ch k).closed c = false := (hi.hold c k hc).2
    simp only [send, s1c, openSide_dc, s1d, s1cl, hcl, hdead, Bool.or_false, Bool.false_eq_true, if_false]; rfl
  rw [hsend]
  have thd : ∀ e j, hdC (appendQ k c.other [msg] S1).cs e j ↔ hdC s.cs e j := by
    intro e j; simp only [hdC, cs_apply, core_dc, core_rsPc, appendQ_sd]
    rcases Cl.eq_or c e with rfl | rfl
    · rw [s1c]; simp [hdn, hrs]
    · rw [s1o]
  have tpc : ∀ j, pinb (appendQ k c.other [msg] S1) c j = pinb s c j := by
    intro j; unfold pinb inbC
    simp only [cs_apply, core_rsPc, core_early, appendQ_sd, s1c]
    rw [appendQ_q, s1q]
    simp only [Cl.ne_other, and_false, if_false]
    by_cases hj : j = k
    · subst hj; simp [hrs]
    · have hne : (s.sd c).rsPc ≠ some j := by
        rw [hrs]; intro h'; exact hj (Option.some.inj h').symm
      simp [hj, hne]
  have tpo : ∀ j, pinb (appendQ k c.other [msg] S1) c.other j =
      if j = k then [Msg.resume 0 (s.sd c).paused (s.sd c).away] else pinb s c.other j := by
    intro j; unfold pinb inbC
    rw [appendQ_q, s1q]
    simp only [cs_apply, core_rsPc, core_early, appendQ_sd, s1o, Cl.other_ne, and_false, if_false]
    have hsil' : (if (s.sd c.other).rsPc = some k then (s.sd c.other).early else []) ++
        (s.ch k).q c.other = [] := hsil
    by_cases hj : j = k
    · subst hj
      simp only [and_self, if_true]
      rw [← List.append_assoc, hsil', hmsg]; simp [Msg.pr]
    · simp only [hj, false_and, if_false]; rfl
  have tsc : (appendQ k c.other [msg] S1).sd c = S1.sd c := rfl
  have tso : (appendQ k c.other [msg] S1).sd c.other = s.sd c.other := by rw [appendQ_sd, s1o]
  refine ⟨fun e j p a hm he => ?_, fun e j v hm he => ?_, fun e j hl hk ho h1 h2 => ?_⟩
  · rw [thd] at he
    rcases Cl.eq_or c e with rfl | rfl
    · rw [tpc] at hm; rw [tso]; exact h.resFlags e j p a hm he
    · rw [tpo] at hm; simp only [Cl.other_other, tsc, s1c]
      by_cases hj : j = k
      · rw [if_pos hj] at hm; simp at hm; exact ⟨hm.1, hm.2⟩
      · exact absurd (hi.same c k j hc he) (Ne.symm hj)
  · rw [thd] at he
    rcases Cl.eq_or c e with rfl | rfl
    · rw [tpc] at hm; rw [tso]; exact h.pauseFrom e j v hm he
    · rw [tpo] at hm
      by_cases hj : j = k
      · rw [if_pos hj] at hm; simp at hm
      · exact absurd (hi.same c k j hc he) (Ne.symm hj)
  · rw [thd] at ho
    rcases Cl.eq_or c e with rfl | rfl
    · rw [tsc, s1c] at hl; simp [hr] at hl
    · rw [tso] at hl hk
      simp only [Cl.other_other] at ho
      have : j = k := by
        rcases ho with ho | ho
        · simp [cs_apply, hdn] at ho
        · simp [cs_apply, hrs] at ho; exact ho.symm
      subst this; exact absurd ⟨hl, hk⟩ hnl


theorem PInv.adopt {cfg : Cfg} (hfix : cfg.fix = true) {s : State} {c : Cl} (hi : Inv s) (h : PInv s)
    (hen : en cfg s (.adopt c) = true) : PInv (adopt cfg c s) := by
  simp only [en, Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true'] at hen
  obtain ⟨⟨hr, hro⟩, hk⟩ := hen
  unfold LinkResume.adopt
  split
  · exact h
  · rename_i k hrs
    rw [hrs] at hk
    simp only [Bool.not_eq_true'] at hk
    exact (PInv.deliverN hfix _ (hi.adoptPrefix hr hro hrs hk (fun y => rfl) rfl)
      (h.adoptPrefix hi hr hro hrs hk rfl)).1

theorem PInv.step {cfg : Cfg} (hfix : cfg.fix = true) {s : State} (hi : Inv s) (h : PInv s) (e : Event)
    (hen : en cfg s e = true) : PInv (step cfg s e) := by
  cases e with
  | input c => exact h.input
  | deliver c k => exact h.deliver hfix hi
  | die k => exact h.die
  | dropped c => exact h.dropped
  | pair => exact h.pair hi hen
  | adopt c => exact h.adopt hfix hi hen
  | restart c =>
    simp only [en, beq_iff_eq] at hen
    exact h.restart hen
  | giveUp c => exact h.shutdown
  | quit c => exact h.shutdown
  | kill c => exact h.finish
  | toggle c => exact h.toggle
  | away c on => exact h.setAway
  | tick n => exact PInv.congr (s := s) (fun _ => rfl) (fun _ _ => rfl) h
  | ping c => exact h.send_np rfl
  | noteIn c =>
    simp only [LinkResume.step]
    split
    · exact (h.updS_np (c := c) (f := fun y => { y with bye := true }) (fun y => rfl)).shutdown
    · exact h

theorem pinv_reachable {cfg : Cfg} (hfix : cfg.fix = true) {s : State} (h : Reachable cfg s) :
    PInv s := by
  have : PInv s ∧ Inv s := by
    induction h with
    | init => exact ⟨pinit, inv_init⟩
    | step e _ hen ih => exact ⟨ih.1.step hfix ih.2 e hen, ih.2.step e hen⟩
  exact this.1

/-- **With the fix, a resume leaves both sides agreeing on pause.** Once
    both are live on the same channel, unless a player has since pressed
    Pause (or the app changed background state) while live, both are paused
    or both are running: the state `finalPause` of the two RESUMEs' flags.
    (`bug_resume_pause_swap_*` show the code without the fix breaks this.) -/
theorem resume_agrees {cfg : Cfg} (hfix : cfg.fix = true) {s : State} (h : Reachable cfg s)
    (ha : (s.sd .a).ph = .live) (hb : (s.sd .b).ph = .live) {k : Nat}
    (hka : (s.sd .a).dc = some k) (hkb : (s.sd .b).dc = some k)
    (hpa : (s.sd .a).livePress = false) (hpb : (s.sd .b).livePress = false) :
    (s.sd .a).paused = (s.sd .b).paused := by
  have hp := pinv_reachable hfix h
  have h1 := hp.agree .a k ha hka (Or.inl (by simpa [cs_apply, Cl.other] using hkb)) hpa hpb
  have h2 := hp.agree .b k hb hkb (Or.inl (by simpa [cs_apply, Cl.other] using hka)) hpb hpa
  simp only [Cl.other] at h1 h2
  rw [h1, h2, finalPause_comm]

/-! ## Invariants: a goodbye is heard

With the goodbye note, a side that ends (other than killed) while its
friend is redialing has left a note on the retry code, for the friend's
next rendezvous to be answered with (`quit_heard`). What it rests on: a
note is only left by a side that has ended, and an ended side never
changes again; a goodbye (BYE, or the note) only reaches a side whose
friend has ended; and a side redialing has had the friend's echo of the
code, so the friend holds the code and could leave the note.

`QStep s t`: `t` keeps the invariant, every message on its way in `t` was
on its way in `s` or is one its sender may send (a BYE only once ended,
the code only once holding it), ended sides are untouched, and holding the
code is never lost. Steps compose. -/

/-- `m` is on its way to `c`: queued to it on a channel, or parked before
    its open. -/
def InPool (s : State) (c : Cl) (m : Msg) : Prop :=
  m ∈ (s.sd c).early ∨ ∃ k, m ∈ (s.ch k).q c

structure QInv (s : State) : Prop where
  endSh   : ∀ c, (s.sd c).ph = .ended → (s.sd c).dc = none ∧ (s.sd c).rsPc = none
  reconOk : ∀ c, (s.sd c).ph = .recon → (s.sd c).ok = true
  okRes   : ∀ c, (s.sd c).ok = true → (s.sd c.other).res = true
  infoQ   : ∀ c, (s.sd c.other).res = false → ¬ InPool s c .info
  byeEnd  : ∀ c, (s.sd c).bye = true → (s.sd c.other).ph = .ended
  byeQ    : ∀ c, (s.sd c.other).ph ≠ .ended → ¬ InPool s c .bye
  noteEnd : ∀ c, (s.note c).isSome → (s.sd c).ph = .ended
  endNote : ∀ c, (s.sd c).ph = .ended → (s.sd c).why ≠ some .killed → (s.sd c).bye = false →
              (s.sd c).res = true → (s.note c).isSome

/-- What may newly be on its way to `c`: a BYE once the sender has ended,
    the code once the sender holds it, anything else. -/
def Sc (t : State) (c : Cl) (m : Msg) : Prop :=
  (m = .bye → (t.sd c.other).ph = .ended) ∧ (m = .info → (t.sd c.other).res = true)

structure QStep (s t : State) : Prop where
  inv    : QInv t
  pool   : ∀ c m, InPool t c m → InPool s c m ∨ Sc t c m
  frozen : ∀ e, (s.sd e).ph = .ended → t.sd e = s.sd e ∧ t.note e = s.note e
  resM   : ∀ e, (s.sd e).res = true → (t.sd e).res = true

theorem QStep.refl {s : State} (h : QInv s) : QStep s s :=
  ⟨h, fun _ _ hm => Or.inl hm, fun _ _ => ⟨rfl, rfl⟩, fun _ h => h⟩

theorem QStep.trans {s t u : State} (h1 : QStep s t) (h2 : QStep t u) : QStep s u where
  inv := h2.inv
  pool c m hm := by
    rcases h2.pool c m hm with h | h
    · rcases h1.pool c m h with h' | ⟨hb, hi⟩
      · exact Or.inl h'
      · refine Or.inr ⟨fun e => ?_, fun e => h2.resM _ (hi e)⟩
        have he := hb e
        rw [(h2.frozen _ he).1]; exact he
    · exact Or.inr h
  frozen e he := by
    obtain ⟨a1, b1⟩ := h1.frozen e he
    have he' : (t.sd e).ph = .ended := by rw [a1]; exact he
    obtain ⟨a2, b2⟩ := h2.frozen e he'
    exact ⟨a2.trans a1, b2.trans b1⟩
  resM e hr := h2.resM e (h1.resM e hr)

theorem Ph.ne_ended_of {p : Ph} (h : p = .live ∨ p = .recon) : p ≠ .ended := by
  rcases h with rfl | rfl <;> decide

/-- The sides and notes as they were, and nothing new on its way. -/
theorem QStep.ofPool {s t : State} (h : QInv s) (hsd : t.sd = s.sd) (hn : t.note = s.note)
    (hp : ∀ c m, InPool t c m → InPool s c m) : QStep s t where
  inv := by
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp only [hsd, hn]
    · exact h.endSh
    · exact h.reconOk
    · exact h.okRes
    · exact fun c hr hm => h.infoQ c hr (hp c _ hm)
    · exact h.byeEnd
    · exact fun c hr hm => h.byeQ c hr (hp c _ hm)
    · exact h.noteEnd
    · exact h.endNote
  pool c m hm := Or.inl (hp c m hm)
  frozen e _ := by simp [hsd, hn]
  resM e hr := by simp only [hsd]; exact hr

/-- One side `d`, not ended, changes; the friend, the notes, and the
    channels' queues do not (beyond shrinking). -/
theorem QStep.gen {s t : State} {d : Cl} (h : QInv s) (hne : (s.sd d).ph ≠ .ended)
    (ho : t.sd d.other = s.sd d.other) (hn : t.note = s.note)
    (hp : ∀ c m, InPool t c m → InPool s c m)
    (hph : (t.sd d).ph ≠ .ended)
    (hrec : (t.sd d).ph = .recon → (t.sd d).ok = true)
    (hok : (t.sd d).ok = true → (s.sd d.other).res = true)
    (hres : (s.sd d).res = true → (t.sd d).res = true)
    (hbye : (t.sd d).bye = true → (s.sd d.other).ph = .ended) : QStep s t where
  inv := by
    have hres' : (t.sd d).res = false → (s.sd d).res = false := by
      intro hf; cases hs : (s.sd d).res
      · rfl
      · rw [hres hs] at hf; cases hf
    refine ⟨fun c => ?_, fun c => ?_, fun c => ?_, fun c => ?_, fun c => ?_, fun c => ?_,
      fun c => ?_, fun c => ?_⟩ <;> rcases Cl.eq_or d c with rfl | rfl
    · exact fun hc => absurd hc hph
    · rw [ho]; exact h.endSh _
    · exact hrec
    · rw [ho]; exact h.reconOk _
    · intro hk; rw [ho]; exact hok hk
    · intro hk; rw [ho] at hk; simp only [Cl.other_other] at hk ⊢
      exact hres (by simpa using h.okRes _ hk)
    · intro hr hm; rw [ho] at hr; exact h.infoQ _ hr (hp _ _ hm)
    · intro hr hm; simp only [Cl.other_other] at hr
      exact h.infoQ d.other (by simpa using hres' hr) (hp _ _ hm)
    · intro hb; rw [ho]; exact hbye hb
    · intro hb; rw [ho] at hb
      have := h.byeEnd _ hb; simp only [Cl.other_other] at this; exact absurd this hne
    · intro hr hm; rw [ho] at hr; exact h.byeQ _ hr (hp _ _ hm)
    · intro _ hm; exact h.byeQ d.other (by simpa using hne) (hp _ _ hm)
    · intro hs; rw [hn] at hs; exact absurd (h.noteEnd _ hs) hne
    · intro hs; rw [hn] at hs; rw [ho]; exact h.noteEnd _ hs
    · exact fun hc => absurd hc hph
    · intro hc hw hb hr; rw [ho] at hc hw hb hr; rw [hn]; exact h.endNote _ hc hw hb hr
  pool c m hm := Or.inl (hp c m hm)
  frozen e he := by
    rcases Cl.eq_or d e with rfl | rfl
    · exact absurd he hne
    · exact ⟨ho, by rw [hn]⟩
  resM e hr := by
    rcases Cl.eq_or d e with rfl | rfl
    · exact hres hr
    · rw [ho]; exact hr

theorem inPool_updS {s : State} {d c : Cl} {f : Side → Side} {m : Msg}
    (hf : ∀ x, x ∈ (f (s.sd d)).early → x ∈ (s.sd d).early)
    (hm : InPool (updS d f s) c m) : InPool s c m := by
  rcases hm with hm | hm
  · left; simp only [updS_sd] at hm; split at hm
    · subst c; exact hf _ hm
    · exact hm
  · right; simpa using hm

/-- `updS` on a side that is not ended, by the `gen` conditions. -/
theorem QStep.updS {s : State} {d : Cl} {f : Side → Side} (h : QInv s) (hne : (s.sd d).ph ≠ .ended)
    (hearly : ∀ x, x ∈ (f (s.sd d)).early → x ∈ (s.sd d).early)
    (hph : (f (s.sd d)).ph ≠ .ended)
    (hrec : (f (s.sd d)).ph = .recon → (f (s.sd d)).ok = true)
    (hok : (f (s.sd d)).ok = true → (s.sd d.other).res = true)
    (hres : (s.sd d).res = true → (f (s.sd d)).res = true)
    (hbye : (f (s.sd d)).bye = true → (s.sd d.other).ph = .ended) : QStep s (LinkResume.updS d f s) :=
  QStep.gen h hne (updS_sd_other s d f) rfl (fun _ _ hm => inPool_updS hearly hm)
    (by rw [updS_sd_self]; exact hph) (by rw [updS_sd_self]; exact hrec)
    (by rw [updS_sd_self]; exact hok) (by rw [updS_sd_self]; exact hres)
    (by rw [updS_sd_self]; exact hbye)

/-- The fields the goodbye argument reads, as they were (and the early
    queue no longer). -/
theorem QStep.quiet {s : State} {d : Cl} {f : Side → Side} (h : QInv s) (hne : (s.sd d).ph ≠ .ended)
    (hf : (f (s.sd d)).ph = (s.sd d).ph ∧ (f (s.sd d)).ok = (s.sd d).ok ∧
      (f (s.sd d)).res = (s.sd d).res ∧ (f (s.sd d)).bye = (s.sd d).bye ∧
      (f (s.sd d)).early = (s.sd d).early) : QStep s (LinkResume.updS d f s) := by
  obtain ⟨h1, h2, h3, h4, h5⟩ := hf
  refine QStep.updS h hne (by rw [h5]; exact fun _ x => x) (by rw [h1]; exact hne)
    (by rw [h1, h2]; exact h.reconOk d) (by rw [h2]; exact h.okRes d) (by rw [h3]; exact id)
    (by rw [h4]; exact h.byeEnd d)

theorem inPool_appendQ {s : State} {k : Nat} {d c : Cl} {ms : List Msg} {m : Msg}
    (hm : InPool (appendQ k d ms s) c m) : InPool s c m ∨ (c = d ∧ m ∈ ms) := by
  rcases hm with hm | ⟨j, hm⟩
  · exact Or.inl (Or.inl (by simpa using hm))
  · rw [appendQ_q] at hm
    split at hm
    · rename_i hj
      simp only [List.mem_append] at hm
      rcases hm with hm | hm
      · exact Or.inl (Or.inr ⟨j, hm⟩)
      · exact Or.inr ⟨hj.2, hm⟩
    · exact Or.inl (Or.inr ⟨j, hm⟩)

theorem send_note (c : Cl) (m : Msg) (s : State) : (send c m s).note = s.note := by
  rcases send_cases c m s with e | ⟨k, -, -, -, e⟩ <;> rw [e]; rfl

theorem inPool_send {s : State} {d c : Cl} {m x : Msg} (hm : InPool (send d m s) c x) :
    InPool s c x ∨ (c = d.other ∧ x = m) := by
  rcases send_cases d m s with e | ⟨k, -, -, -, e⟩ <;> rw [e] at hm
  · exact Or.inl hm
  · rcases inPool_appendQ hm with h | ⟨h1, h2⟩
    · exact Or.inl h
    · exact Or.inr ⟨h1, by simpa using h2⟩

/-- Sending anything but a BYE; the code only while holding it. -/
theorem QStep.send {s : State} (h : QInv s) (d : Cl) (m : Msg) (hb : m ≠ .bye)
    (hi : m = .info → (s.sd d).res = true) : QStep s (LinkResume.send d m s) := by
  have hsd := send_sd d m s
  have hn := send_note d m s
  have hsc : ∀ c x, InPool (LinkResume.send d m s) c x → InPool s c x ∨ Sc (LinkResume.send d m s) c x := by
    intro c x hx
    rcases inPool_send hx with hx | ⟨rfl, rfl⟩
    · exact Or.inl hx
    · refine Or.inr ⟨fun e => absurd e hb, fun e => ?_⟩
      simp only [hsd, Cl.other_other]; exact hi e
  refine ⟨?_, hsc, fun e _ => by simp [hsd, hn], fun e hr => by simp only [hsd]; exact hr⟩
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp only [hsd, hn]
  · exact h.endSh
  · exact h.reconOk
  · exact h.okRes
  · intro c hr hx
    rcases hsc c _ hx with hx | ⟨-, hi'⟩
    · exact h.infoQ c hr hx
    · rw [hsd] at hi'; rw [hi' rfl] at hr; cases hr
  · exact h.byeEnd
  · intro c hr hx
    rcases inPool_send hx with hx | ⟨-, e⟩
    · exact h.byeQ c hr hx
    · exact hb e.symm
  · exact h.noteEnd
  · exact h.endNote

theorem QStep.sendAll {s : State} (h : QInv s) (d : Cl) (t n : Nat) :
    QStep s (LinkResume.sendAll d (frames t n) s) := by
  suffices ∀ (l : List Nat) (s : State), QInv s → QStep s (LinkResume.sendAll d (l.map Msg.inp) s) from
    this _ s h
  intro l
  induction l with
  | nil => intro s h; exact QStep.refl h
  | cons x xs ih =>
    intro s h
    have h1 := QStep.send h d (.inp x) (by simp) (by simp)
    exact h1.trans (ih _ h1.inv)

@[simp] theorem updS_note (s : State) (c : Cl) (f : Side → Side) : (updS c f s).note = s.note := rfl
@[simp] theorem updCh_note (s : State) (k : Nat) (g : Chan → Chan) : (updCh k g s).note = s.note := rfl
@[simp] theorem closeEnd_note (s : State) (c : Cl) (k : Nat) : (closeEnd c k s).note = s.note := rfl

theorem detach_note (c : Cl) (s : State) : (detach c s).note = s.note := by
  unfold detach
  cases hr : (s.sd c).rsPc <;> cases hd : (s.sd c).dc <;> simp [hr, hd]

theorem sendAll_sd' (c : Cl) (ms : List Msg) (s : State) : (LinkResume.sendAll c ms s).sd = s.sd := by
  rw [sendAll_eq]; split
  · split <;> rfl
  · rfl

theorem inPool_detach {s : State} {d c : Cl} {m : Msg} (hm : InPool (detach d s) c m) :
    InPool s c m := by
  obtain ⟨-, -, hq, -, -, -, hsc, hso⟩ := detach_parts s d
  rcases hm with hm | ⟨j, hm⟩
  · left; rcases Cl.eq_or d c with rfl | rfl
    · rw [hsc] at hm; cases hm
    · rw [hso] at hm; exact hm
  · right; exact ⟨j, by rw [← hq]; exact hm⟩

theorem QStep.detach {s : State} {d : Cl} (h : QInv s) (hne : (s.sd d).ph ≠ .ended) :
    QStep s (detach d s) := by
  obtain ⟨-, -, -, -, -, -, hsc, hso⟩ := detach_parts s d
  exact QStep.gen h hne hso (detach_note d s) (fun _ _ hm => inPool_detach hm)
    (by rw [hsc]; exact hne) (by rw [hsc]; exact h.reconOk d) (by rw [hsc]; exact h.okRes d)
    (by rw [hsc]; exact id) (by rw [hsc]; exact h.byeEnd d)

section finish
variable (s : State) (d : Cl) (w : End)
theorem finish_sd_self : (finish d w s).sd d =
    { s.sd d with rsPc := none, rsOpen := false, early := [], dc := none, ph := .ended, why := some w } := by
  obtain ⟨-, -, -, -, -, -, hsc, -⟩ := detach_parts s d
  simp only [finish, updS_sd_self, hsc]
theorem finish_sd_other : (finish d w s).sd d.other = s.sd d.other := by
  obtain ⟨-, -, -, -, -, -, -, hso⟩ := detach_parts s d
  simp only [finish, updS_sd_other, hso]
theorem finish_note : (finish d w s).note = s.note := by
  simp only [finish]; exact detach_note d s
theorem inPool_finish {c : Cl} {m : Msg} (hm : InPool (finish d w s) c m) : InPool s c m :=
  inPool_detach (inPool_updS (fun _ x => by simpa using x) hm)
end finish

section leaveNote
variable (s : State) (c : Cl) (w : End) (x : Side)
@[simp] theorem leaveNote_sd : (LinkResume.leaveNote c w x s).sd = s.sd := by
  unfold LinkResume.leaveNote; split <;> rfl
@[simp] theorem leaveNote_ch : (LinkResume.leaveNote c w x s).ch = s.ch := by
  unfold LinkResume.leaveNote; split <;> rfl
theorem leaveNote_note_other : (LinkResume.leaveNote c w x s).note c.other = s.note c.other := by
  unfold LinkResume.leaveNote; split <;> simp
theorem leaveNote_note_self (hr : x.res = true) (hb : x.bye = false) :
    (LinkResume.leaveNote c w x s).note c = some (if w = .quit then .left else .gaveUp) := by
  unfold LinkResume.leaveNote; simp [hr, hb]
theorem inPool_leaveNote {d : Cl} {m : Msg} (hm : InPool (LinkResume.leaveNote c w x s) d m) :
    InPool s d m := by
  rcases hm with hm | ⟨j, hm⟩
  · left; simpa using hm
  · right; exact ⟨j, by simpa using hm⟩
end leaveNote

/-- Side `d` ends: its channel let go, perhaps a BYE to the friend. -/
theorem QStep.ending {s t : State} {d : Cl} (h : QInv s) (hne : (s.sd d).ph ≠ .ended)
    (hd : (t.sd d).ph = .ended ∧ (t.sd d).dc = none ∧ (t.sd d).rsPc = none ∧
      (t.sd d).res = (s.sd d).res ∧ (t.sd d).ok = (s.sd d).ok ∧ (t.sd d).bye = (s.sd d).bye)
    (ho : t.sd d.other = s.sd d.other) (hno : t.note d.other = s.note d.other)
    (hnd : (t.sd d).why ≠ some .killed → (t.sd d).bye = false → (t.sd d).res = true →
      (t.note d).isSome)
    (hp : ∀ c m, InPool t c m → InPool s c m ∨ (c = d.other ∧ m = .bye)) : QStep s t := by
  obtain ⟨he, hdc, hrs, hr, hk, hb⟩ := hd
  have hpi : ∀ c, InPool t c .info → InPool s c .info := by
    intro c hm; rcases hp c _ hm with hm | ⟨-, e⟩
    · exact hm
    · cases e
  refine ⟨?_, fun c m hm => ?_, fun e he' => ?_, fun e hre => ?_⟩
  · refine ⟨fun c => ?_, fun c => ?_, fun c => ?_, fun c => ?_, fun c => ?_, fun c => ?_,
      fun c => ?_, fun c => ?_⟩ <;> rcases Cl.eq_or d c with rfl | rfl
    · exact fun _ => ⟨hdc, hrs⟩
    · rw [ho]; exact h.endSh _
    · intro hc; rw [he] at hc; cases hc
    · rw [ho]; exact h.reconOk _
    · intro hc; rw [ho]; rw [hk] at hc; exact h.okRes _ hc
    · intro hc; rw [ho] at hc; simp only [Cl.other_other] at hc ⊢; rw [hr]
      simpa using h.okRes _ hc
    · intro hc hm; rw [ho] at hc; exact h.infoQ _ hc (hpi _ hm)
    · intro hc hm; simp only [Cl.other_other] at hc; rw [hr] at hc
      exact h.infoQ d.other (by simpa using hc) (hpi _ hm)
    · intro hc; rw [ho]; rw [hb] at hc; exact h.byeEnd _ hc
    · intro _; simpa using he
    · intro hc hm; rw [ho] at hc
      rcases hp _ _ hm with hm | ⟨e, -⟩
      · exact h.byeQ _ hc hm
      · exact absurd e (Cl.ne_other _)
    · intro hc; simp only [Cl.other_other] at hc; exact absurd he hc
    · exact fun _ => he
    · intro hc; rw [hno] at hc; rw [ho]; exact h.noteEnd _ hc
    · exact fun _ => hnd
    · intro hc hw hb' hr'; rw [ho] at hc hw hb' hr'; rw [hno]; exact h.endNote _ hc hw hb' hr'
  · rcases hp c m hm with hm | ⟨rfl, rfl⟩
    · exact Or.inl hm
    · exact Or.inr ⟨fun _ => by simpa using he, fun e => by cases e⟩
  · rcases Cl.eq_or d e with rfl | rfl
    · exact absurd he' hne
    · exact ⟨ho, hno⟩
  · rcases Cl.eq_or d e with rfl | rfl
    · rw [hr]; exact hre
    · rw [ho]; exact hre

theorem QStep.shutdown {s : State} {d : Cl} {w : End} (h : QInv s) (hne : (s.sd d).ph ≠ .ended) :
    QStep s (LinkResume.shutdown d w s) := by
  obtain ⟨s1, e1⟩ : ∃ s1, s1 = (if (s.sd d).bye then s else LinkResume.send d .bye s) := ⟨_, rfl⟩
  have hs1 : s1.sd = s.sd := by rw [e1]; split; rfl; exact send_sd ..
  have hn1 : s1.note = s.note := by rw [e1]; split; rfl; exact send_note ..
  have hp1 : ∀ c m, InPool s1 c m → InPool s c m ∨ (c = d.other ∧ m = .bye) := by
    intro c m hm
    rw [e1] at hm
    split at hm
    · exact Or.inl hm
    · exact inPool_send hm
  have ht : LinkResume.shutdown d w s = LinkResume.leaveNote d w (s.sd d) (finish d w s1) := by
    rw [e1]; rfl
  rw [ht]
  have hself : (LinkResume.leaveNote d w (s.sd d) (finish d w s1)).sd d =
      { s.sd d with rsPc := none, rsOpen := false, early := [], dc := none, ph := .ended,
                    why := some w } := by
    rw [leaveNote_sd, finish_sd_self, hs1]
  refine QStep.ending h hne ?_ ?_ ?_ ?_ ?_
  · rw [hself]; exact ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩
  · rw [leaveNote_sd, finish_sd_other, hs1]
  · rw [leaveNote_note_other, finish_note, hn1]
  · intro _ hb hr
    rw [hself] at hb hr
    rw [leaveNote_note_self (finish d w s1) d w (s.sd d) hr hb]; rfl
  · intro c m hm
    exact hp1 c m (inPool_finish _ _ _ (inPool_leaveNote _ _ _ _ hm))

theorem QStep.kill {s : State} {d : Cl} (h : QInv s) (hne : (s.sd d).ph ≠ .ended) :
    QStep s (finish d .killed s) := by
  refine QStep.ending h hne ?_ (finish_sd_other s d _) (by rw [finish_note]) ?_
    (fun c m hm => Or.inl (inPool_finish _ _ _ hm))
  · rw [finish_sd_self]; exact ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩
  · intro hw; rw [finish_sd_self] at hw; exact absurd rfl hw

theorem QStep.press {s : State} {c : Cl} {p : Bool} (h : QInv s) (hne : (s.sd c).ph ≠ .ended) :
    QStep s (press c p s) := by
  unfold LinkResume.press
  have h1 := QStep.send h c (.pause p ((s.sd c).reg.n + 1)) (by simp) (by simp)
  exact h1.trans (QStep.quiet (d := c) (f := fun y => { y with reg := ⟨(s.sd c).reg.n + 1, c == .a, p⟩ })
    h1.inv (by rw [send_sd]; exact hne) ⟨rfl, rfl, rfl, rfl, rfl⟩)

theorem QStep.setPaused {s : State} {c : Cl} {p r : Bool} (h : QInv s) (hne : (s.sd c).ph ≠ .ended) :
    QStep s (setPaused c p r s) := by
  unfold LinkResume.setPaused
  split
  · exact QStep.refl h
  · have h1 := QStep.quiet (f := fun y => { y with paused := p, pfb := false }) h hne
      ⟨rfl, rfl, rfl, rfl, rfl⟩
    dsimp only
    split
    · exact h1.trans (QStep.press h1.inv (by rw [updS_sd_self]; exact hne))
    · exact h1

theorem QStep.remotePause {s : State} {c : Cl} {v : Bool} (h : QInv s) (hne : (s.sd c).ph ≠ .ended) :
    QStep s (remotePause c v s) := QStep.setPaused h hne

theorem QStep.pauseAfterResume {s : State} {cfg : Cfg} {c : Cl} {p a : Bool} (h : QInv s)
    (hne : (s.sd c).ph ≠ .ended) : QStep s (pauseAfterResume cfg c p a s) := by
  unfold LinkResume.pauseAfterResume
  split
  · dsimp only
    split
    · have h1 := QStep.quiet (f := fun y => { y with livePress := y.livePress || y.ph == .live })
        h hne ⟨rfl, rfl, rfl, rfl, rfl⟩
      split
      · exact h1.trans (QStep.press h1.inv (by rw [updS_sd_self]; exact hne))
      · exact h1
    · exact QStep.remotePause h hne
  · dsimp only
    have h1 : QStep s (if (!p && (s.sd c).paused && !(cfg.iosB && c == .b && (s.sd c).away)) = true
        then LinkResume.remotePause c false s else s) := by
      split
      · exact QStep.remotePause h hne
      · exact QStep.refl h
    exact h1.trans (QStep.send h1.inv c _ (by simp) (by simp))

theorem QStep.resumeIn {s : State} {cfg : Cfg} {c : Cl} {t : Nat} {p a : Bool} (h : QInv s) :
    QStep s (resumeIn cfg c t p a s) := by
  unfold LinkResume.resumeIn
  dsimp only
  split
  · exact QStep.refl h
  · rename_i hg
    have hr : (s.sd c).ph = .recon := by
      simp only [Bool.not_eq_true', Bool.not_eq_false, Bool.and_eq_true, beq_iff_eq] at hg
      exact hg.1.1
    have hne : (s.sd c).ph ≠ .ended := by rw [hr]; decide
    split
    · exact QStep.shutdown h hne
    · have h0 := QStep.quiet (d := c) (f := fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) })
        h hne ⟨rfl, rfl, rfl, rfl, rfl⟩
      have hne0 : ((LinkResume.updS c (fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) }) s).sd c).ph
          ≠ .ended := by rw [updS_sd_self]; exact hne
      have h1 := h0.trans (QStep.updS (f := fun y => { y with ph := .live, rsPc := none }) h0.inv hne0
        (fun _ x => x) (by simp) (by intro e; cases e) (h0.inv.okRes c) id (h0.inv.byeEnd c))
      have h2 := h1.trans (QStep.sendAll h1.inv c t (s.sd c).sent)
      have hl : ((LinkResume.sendAll c (frames t (s.sd c).sent)
          (LinkResume.updS c (fun y => { y with ph := .live, rsPc := none })
            (LinkResume.updS c (fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) }) s))).sd c).ph
            ≠ .ended := by
        rw [sendAll_sd', updS_sd_self]; simp
      exact h2.trans (QStep.pauseAfterResume h2.inv hl)

/-- `rbMessage` on a side that is not ended, for a message that was on its
    way to it (so a BYE means the friend has ended, the code that the friend
    holds it). -/
theorem QStep.recv {s : State} {cfg : Cfg} {c : Cl} {m : Msg} (h : QInv s) (hne : (s.sd c).ph ≠ .ended)
    (hb : m = .bye → (s.sd c.other).ph = .ended) (hi : m = .info → (s.sd c.other).res = true) :
    QStep s (recv cfg c m s) := by
  have h1 := QStep.quiet (f := fun y => { y with lastMsg := s.now }) h hne ⟨rfl, rfl, rfl, rfl, rfl⟩
  have hne1 : ((LinkResume.updS c (fun y => { y with lastMsg := s.now }) s).sd c).ph ≠ .ended := by
    rw [updS_sd_self]; exact hne
  have ho1 : (LinkResume.updS c (fun y => { y with lastMsg := s.now }) s).sd c.other = s.sd c.other :=
    updS_sd_other ..
  unfold LinkResume.recv
  dsimp only
  cases m with
  | info =>
    dsimp only
    split
    · refine h1.trans (QStep.updS h1.inv hne1 (fun _ x => x) hne1 (fun _ => rfl)
        (fun _ => by rw [ho1]; exact hi rfl) id ?_)
      exact h1.inv.byeEnd c
    · have h2 := QStep.updS (f := fun y => { y with res := true, ok := true }) h1.inv hne1
        (fun _ x => x) hne1 (fun _ => rfl) (fun _ => by rw [ho1]; exact hi rfl) (fun _ => rfl)
        (h1.inv.byeEnd c)
      exact h1.trans (h2.trans (QStep.send h2.inv c .info (by simp) (fun _ => by simp)))
  | inp f =>
    exact h1.trans (QStep.quiet h1.inv hne1 ⟨rfl, rfl, rfl, rfl, rfl⟩)
  | resume t p a => exact h1.trans (QStep.resumeIn h1.inv)
  | pause v n =>
    dsimp only
    split
    · split
      · have h2 := QStep.quiet (d := c) (f := fun y => { y with reg := ⟨n, c.other == .a, v⟩ }) h1.inv hne1
          ⟨rfl, rfl, rfl, rfl, rfl⟩
        exact h1.trans (h2.trans (QStep.remotePause h2.inv (by rw [updS_sd_self]; exact hne1)))
      · exact h1
    · exact h1.trans (QStep.remotePause h1.inv hne1)
  | bye =>
    have h2 := QStep.updS (f := fun y => { y with bye := true }) h1.inv hne1 (fun _ x => x) hne1
      (h1.inv.reconOk c) (h1.inv.okRes c) id (fun _ => by rw [ho1]; exact hb rfl)
    exact h1.trans (h2.trans (QStep.shutdown h2.inv (by rw [updS_sd_self]; exact hne1)))
  | ping => exact h1

theorem inPool_popQ {s : State} {k : Nat} {c d : Cl} {m : Msg} {rest : List Msg}
    (hq : (s.ch k).q c = m :: rest) {x : Msg} (hx : InPool (popQ k c rest s) d x) : InPool s d x := by
  rcases hx with hx | ⟨j, hx⟩
  · left; simpa using hx
  · right; refine ⟨j, ?_⟩
    rw [popQ_q] at hx
    split at hx
    · rename_i hj; obtain ⟨rfl, rfl⟩ := hj; rw [hq]; exact List.mem_cons_of_mem _ hx
    · exact hx

theorem QStep.deliver {s : State} {cfg : Cfg} {c : Cl} {k : Nat} (h : QInv s) :
    QStep s (deliver cfg c k s) := by
  unfold LinkResume.deliver
  split
  · exact QStep.refl h
  · rename_i m rest hq
    dsimp only
    have hpop : updCh k (fun x => { x with q := fun d => if d = c then rest else x.q d }) s =
        popQ k c rest s := rfl
    rw [hpop]
    have hm : InPool s c m := Or.inr ⟨k, by rw [hq]; exact List.mem_cons_self ..⟩
    have h1 : QStep s (popQ k c rest s) :=
      QStep.ofPool h rfl rfl (fun _ _ hx => inPool_popQ hq hx)
    have hne_of : ∀ j, ((s.sd c).dc = some j ∨ (s.sd c).rsPc = some j) → (s.sd c).ph ≠ .ended := by
      intro j hj he
      obtain ⟨h1, h2⟩ := h.endSh c he
      rcases hj with hj | hj
      · rw [h1] at hj; cases hj
      · rw [h2] at hj; cases hj
    split
    · exact h1
    · split
      · rename_i hd
        have hne : (s.sd c).ph ≠ .ended := hne_of k (Or.inl (by simpa using hd))
        refine h1.trans (QStep.recv h1.inv (by simpa using hne) (fun e => ?_) (fun e => ?_))
        · subst e
          by_cases hc : (s.sd c.other).ph = .ended
          · simpa using hc
          · exact absurd hm (h.byeQ c hc)
        · subst e
          cases hc : (s.sd c.other).res
          · exact absurd hm (h.infoQ c hc)
          · simpa using hc
      · split
        · rename_i hd hrs
          have hne : (s.sd c).ph ≠ .ended := hne_of k (Or.inr (by simpa using hrs))
          split
          · refine QStep.gen (d := c) h hne (by simp) rfl (fun d x hx => ?_) (by simpa using hne)
              (by simpa using h.reconOk c) (by simpa using h.okRes c) (by simp)
              (by simpa using h.byeEnd c)
            rcases hx with hx | hx
            · simp only [updS_sd, popQ_sd] at hx
              split at hx
              · rename_i hdc; subst hdc
                simp only [List.mem_append, List.mem_singleton] at hx
                rcases hx with hx | rfl
                · exact Or.inl hx
                · exact hm
              · exact Or.inl hx
            · exact inPool_popQ hq (Or.inr (by simpa using hx))
          · exact h1
        · exact h1

theorem QStep.deliverN {s : State} {cfg : Cfg} {c : Cl} {k : Nat} (n : Nat) (h : QInv s) :
    QStep s (deliverN cfg c k n s) := by
  induction n generalizing s with
  | zero => exact QStep.refl h
  | succ n ih =>
    have h1 : QStep s (LinkResume.deliver cfg c k s) := QStep.deliver h
    exact h1.trans (ih h1.inv)

/-- `rsAdopt` up to the replay. -/
theorem QStep.adoptPrefix {s : State} {c : Cl} {k : Nat} (h : QInv s) (hr : (s.sd c).ph = .recon) :
    QStep s (LinkResume.send c (.resume (s.sd c).rx (s.sd c).paused (s.sd c).away)
      (LinkResume.updS c (openSide k)
        (updCh k (fun y => { y with q := fun d => if d = c then (s.sd c).early ++ y.q d else y.q d }) s))) := by
  have hne : (s.sd c).ph ≠ .ended := by rw [hr]; decide
  let s1 := updCh k (fun y => { y with q := fun d => if d = c then (s.sd c).early ++ y.q d else y.q d }) s
  have h2 : QStep s (LinkResume.updS c (openSide k) s1) := by
    refine QStep.gen (d := c) h hne (by simp [s1]) rfl (fun d x hx => ?_) (by simpa [s1] using hne)
      (by simpa [s1, openSide] using h.reconOk c) (by simpa [s1, openSide] using h.okRes c)
      (by simp [s1, openSide]) (by simpa [s1, openSide] using h.byeEnd c)
    rcases hx with hx | ⟨j, hx⟩
    · simp only [updS_sd] at hx
      split at hx
      · simp at hx
      · exact Or.inl (by simpa [s1] using hx)
    · simp only [updS_ch, s1, updCh_ch] at hx
      split at hx
      · rename_i hj; subst hj
        dsimp only at hx
        split at hx
        · rename_i hd; subst hd
          simp only [List.mem_append] at hx
          rcases hx with hx | hx
          · exact Or.inl hx
          · exact Or.inr ⟨_, hx⟩
        · exact Or.inr ⟨_, hx⟩
      · exact Or.inr ⟨j, hx⟩
  exact h2.trans (QStep.send h2.inv c (.resume (s.sd c).rx (s.sd c).paused (s.sd c).away)
    (by simp) (by simp))

theorem QStep.adopt {s : State} {cfg : Cfg} {c : Cl} (h : QInv s) (hr : (s.sd c).ph = .recon) :
    QStep s (adopt cfg c s) := by
  unfold LinkResume.adopt
  split
  · exact QStep.refl h
  · rename_i k hrs
    have h3 := QStep.adoptPrefix (k := k) h hr
    exact h3.trans (QStep.deliverN _ h3.inv)

theorem QStep.restart {s : State} {c : Cl} (h : QInv s) (hr : (s.sd c).ph = .recon) :
    QStep s (restart c s) := by
  have hne : (s.sd c).ph ≠ .ended := by rw [hr]; decide
  unfold LinkResume.restart
  split
  · exact QStep.shutdown h hne
  · exact QStep.detach h hne

theorem QStep.dropped {s : State} {c : Cl} (h : QInv s) (hne : (s.sd c).ph ≠ .ended) :
    QStep s (dropped c s) := by
  unfold LinkResume.dropped
  dsimp only
  split
  · rename_i hok
    simp only [Bool.and_eq_true, Bool.not_eq_true'] at hok
    split
    · rename_i hr; exact QStep.restart h (by simpa using hr)
    · split
      · exact QStep.shutdown h hne
      · have h1 := QStep.detach h hne
        obtain ⟨-, -, -, -, -, -, hsc, -⟩ := detach_parts s c
        refine h1.trans (QStep.updS h1.inv (by rw [hsc]; exact hne) (by simp) (by simp)
          (fun _ => by rw [hsc]; exact hok.1) ?_ (by simp) ?_)
        · intro hk; rw [(detach_parts s c).2.2.2.2.2.2.2]; exact h.okRes c (by simpa [hsc] using hk)
        · intro hb; rw [(detach_parts s c).2.2.2.2.2.2.2]
          rw [hsc] at hb; simp only at hb; rw [hok.2] at hb; cases hb
  · exact QStep.shutdown h hne

theorem QStep.pair {s : State} {cfg : Cfg} (h : QInv s) (hen : en cfg s .pair = true) :
    QStep s (pair s) := by
  simp only [en, Bool.and_eq_true, beq_iff_eq] at hen
  obtain ⟨⟨⟨⟨⟨ha, hb⟩, -⟩, -⟩, -⟩, -⟩ := hen
  unfold LinkResume.pair
  dsimp only
  have h0 : QStep s { s with nextCh := s.nextCh + 1 } := QStep.ofPool h rfl rfl (fun _ _ hx => hx)
  have h1 := h0.trans (QStep.quiet (d := .a) (f := fun y => { y with rsPc := some s.nextCh }) h0.inv
    (by show (s.sd .a).ph ≠ .ended; rw [ha]; decide) ⟨rfl, rfl, rfl, rfl, rfl⟩)
  exact h1.trans (QStep.quiet (d := .b) (f := fun y => { y with rsPc := some s.nextCh }) h1.inv
    (by simp; rw [hb]; decide) ⟨rfl, rfl, rfl, rfl, rfl⟩)

theorem setPaused_sd_ph (c : Cl) (p r : Bool) (s : State) :
    ((LinkResume.setPaused c p r s).sd c).ph = (s.sd c).ph := by
  unfold LinkResume.setPaused
  split
  · rfl
  · dsimp only; split <;> simp [LinkResume.press, send_sd]

theorem QStep.setAway {s : State} {cfg : Cfg} {c : Cl} {on : Bool} (h : QInv s)
    (hne : (s.sd c).ph ≠ .ended) : QStep s (setAway cfg c on s) := by
  unfold LinkResume.setAway
  dsimp only
  have h1 := QStep.quiet (d := c)
    (f := fun y => { y with away := on, livePress := y.livePress || y.ph == .live }) h hne
    ⟨rfl, rfl, rfl, rfl, rfl⟩
  have hne1 : ((LinkResume.updS c (fun y => { y with away := on, livePress := y.livePress || y.ph == .live }) s).sd c).ph ≠ .ended := by
    simpa using hne
  split
  · exact h1
  · split
    · split
      · exact h1
      · have h2 := h1.trans (QStep.setPaused (p := true) (r := true) h1.inv hne1)
        refine h2.trans (QStep.quiet h2.inv ?_ ⟨rfl, rfl, rfl, rfl, rfl⟩)
        rw [setPaused_sd_ph]; exact hne1
    · split
      · have h2 := h1.trans (QStep.quiet (f := fun y => { y with pfb := false }) h1.inv hne1
          ⟨rfl, rfl, rfl, rfl, rfl⟩)
        exact h2.trans (QStep.setPaused h2.inv (by simpa using hne))
      · exact h1

theorem QStep.step {s : State} {cfg : Cfg} (h : QInv s) (e : Event) (hen : en cfg s e = true) :
    QStep s (step cfg s e) := by
  have ne_of : ∀ {c : Cl}, ((s.sd c).ph != .ended) = true → (s.sd c).ph ≠ .ended := by
    intro c hc; simpa using hc
  cases e with
  | input c =>
    simp only [en, Bool.and_eq_true] at hen
    have hne := ne_of hen.1.1.1.1
    simp only [LinkResume.step]
    have h1 := QStep.quiet (f := fun y => { y with sent := (s.sd c).sent + 1 }) h hne
      ⟨rfl, rfl, rfl, rfl, rfl⟩
    split
    · exact h1.trans (QStep.send h1.inv c _ (by simp) (by simp))
    · exact h1
  | deliver c k => exact QStep.deliver h
  | die k =>
    simp only [LinkResume.step]
    exact QStep.ofPool h rfl rfl (fun d x hx => by
      rcases hx with hx | ⟨j, hx⟩
      · exact Or.inl (by simpa using hx)
      · simp only [updCh_ch] at hx
        split at hx
        · simp at hx
        · exact Or.inr ⟨j, hx⟩)
  | dropped c =>
    simp only [en, Bool.and_eq_true] at hen
    exact QStep.dropped h (ne_of hen.1)
  | pair => exact QStep.pair h hen
  | adopt c =>
    simp only [en, Bool.and_eq_true, beq_iff_eq] at hen
    exact QStep.adopt h hen.1.1
  | restart c =>
    simp only [en, beq_iff_eq] at hen
    exact QStep.restart h hen
  | giveUp c =>
    simp only [en, Bool.and_eq_true, beq_iff_eq] at hen
    exact QStep.shutdown h (by rw [hen.1]; decide)
  | quit c => exact QStep.shutdown h (ne_of hen)
  | kill c => exact QStep.kill h (ne_of hen)
  | toggle c =>
    simp only [en, Bool.and_eq_true] at hen
    have hne := ne_of hen.1
    simp only [LinkResume.step]
    have h1 := QStep.quiet (f := fun y => { y with livePress := y.livePress || y.ph == .live }) h hne
      ⟨rfl, rfl, rfl, rfl, rfl⟩
    exact h1.trans (QStep.setPaused h1.inv (by simpa using hne))
  | away c on =>
    simp only [en, Bool.and_eq_true] at hen
    exact QStep.setAway h (ne_of hen.1)
  | tick n => exact QStep.ofPool h rfl rfl (fun _ _ hx => hx)
  | ping c => exact QStep.send h c .ping (by simp) (by simp)
  | noteIn c =>
    simp only [en, Bool.and_eq_true, beq_iff_eq] at hen
    have hne : (s.sd c).ph ≠ .ended := by rw [hen.1.1.1.2]; decide
    have hoe : (s.sd c.other).ph = .ended := h.noteEnd _ hen.2
    simp only [LinkResume.step]
    split
    · have h1 := QStep.updS (f := fun y => { y with bye := true }) h hne (fun _ x => x) hne
        (h.reconOk c) (h.okRes c) id (fun _ => hoe)
      exact h1.trans (QStep.shutdown h1.inv (by simpa using hne))
    · exact QStep.refl h

theorem qinit : QInv init := by
  have hpool : ∀ c m, InPool init c m → c = .b ∧ m = .info := by
    intro c m hm
    rcases hm with hm | ⟨j, hm⟩
    · cases c <;> simp [init] at hm
    · by_cases hj : j = 0
      · subst hj; cases c <;> simp [init] at hm; exact ⟨rfl, hm⟩
      · simp [init, hj] at hm
  refine ⟨fun c hc => ?_, fun c hc => ?_, fun c hc => ?_, fun c hr hm => ?_, fun c hc => ?_,
    fun c _ hm => ?_, fun c hc => ?_, fun c hc => ?_⟩
  · cases c <;> simp [init] at hc
  · cases c <;> simp [init] at hc
  · cases c <;> simp [init] at hc
  · obtain ⟨rfl, -⟩ := hpool c _ hm; simp [init, Cl.other] at hr
  · cases c <;> simp [init] at hc
  · obtain ⟨-, e⟩ := hpool c _ hm; cases e
  · simp [init] at hc
  · cases c <;> simp [init] at hc

theorem qinv_reachable {cfg : Cfg} {s : State} (h : Reachable cfg s) : QInv s := by
  induction h with
  | init => exact qinit
  | step e _ hen ih => exact (QStep.step ih e hen).inv

/-- **A goodbye is never missing when the friend is redialing.** Whenever a
    side has ended, other than killed (Disconnect, leaving the page, the
    give-up, a failure), while its friend is still redialing, it has left a
    goodbye note on the retry code. (The friend never redials past its
    friend's own BYE, and a side redialing has had the friend's echo of the
    code, so the friend held the code to leave it with.) With `Cfg.note` the
    server answers the friend's rendezvous with it: `quit_heard_next`. -/
theorem quit_heard {cfg : Cfg} {s : State} (h : Reachable cfg s) {c : Cl}
    (hc : (s.sd c).ph = .ended) (hk : (s.sd c).why ≠ some .killed)
    (hr : (s.sd c.other).ph = .recon) : (s.note c).isSome := by
  have q := qinv_reachable h
  have hres : (s.sd c).res = true := by simpa using q.okRes _ (q.reconOk _ hr)
  have hbye : (s.sd c).bye = false := by
    cases hb : (s.sd c).bye
    · rfl
    · have := q.byeEnd c hb; rw [hr] at this; cases this
  exact q.endNote c hc hk hbye hres

/-- ...and is heard: the friend's next attempt (a `restart`, which every
    failing attempt is, and which is always possible while redialing) ends
    with its rendezvous answered by the goodbye, unless its own give-up
    came first. -/
theorem quit_heard_next {cfg : Cfg} (hn : cfg.note = true) {s : State} (h : Reachable cfg s) {c : Cl}
    (hc : (s.sd c).ph = .ended) (hk : (s.sd c).why ≠ some .killed)
    (hr : (s.sd c.other).ph = .recon) :
    en cfg s (.restart c.other) = true ∧
    (en cfg (step cfg s (.restart c.other)) (.noteIn c.other) = true ∨
      ((step cfg s (.restart c.other)).sd c.other).ph = .ended) := by
  have hnote := quit_heard h hc hk hr
  refine ⟨by simp [en, hr], ?_⟩
  simp only [LinkResume.step, LinkResume.restart]
  split
  · right
    rw [LinkResume.shutdown, leaveNote_sd, finish_sd_self]
  · left
    obtain ⟨-, -, -, -, -, -, hsc, hso⟩ := detach_parts s c.other
    simp only [Cl.other_other] at hso
    simp [en, hn, hsc, hr, detach_note, hnote]


/-! ## Invariants: numbered presses agree (`Cfg.seq`)

Each side holds the winning press (`reg`); its own press is numbered one
past it, and a friend's press is taken only if it beats it. Reading a queue
of presses is a fold of `Reg.take`, so what a side will hold once its queue
is read is `settle reg queue`. The invariant: on a channel both are live on,
the two settles are equal (a press changes both by the same `take`, since it
beats everything its author has seen and differs from everything the
friend authored); a redialing side sends no presses and reads none before
the friend's RESUME; and a side live on a channel the friend is still
resuming on holds what the friend will get by restarting from the same
`finalPause` base and reading its queue. So once nothing is in flight both
hold the same press, and with it the same pause. -/

/-- A press's rank: the number, then the host. -/
def Reg.key (r : Reg) : Nat := 2 * r.n + (if r.byA then 1 else 0)

theorem Reg.beats_iff (x y : Reg) : x.beats y = true ↔ y.key < x.key := by
  unfold Reg.beats Reg.key
  cases hx : x.byA <;> cases hy : y.byA <;> simp <;> omega

/-- `rbPressIn`: take the press if it beats the one held. -/
def Reg.take (r x : Reg) : Reg := if x.beats r then x else r

/-- What a side holding `r` holds once it has read the presses `l`. -/
def settle (r : Reg) (l : List Reg) : Reg := l.foldl Reg.take r

@[simp] theorem settle_nil (r : Reg) : settle r [] = r := rfl
@[simp] theorem settle_cons (r x : Reg) (l : List Reg) : settle r (x :: l) = settle (r.take x) l := rfl
theorem settle_append (r : Reg) (l l' : List Reg) : settle r (l ++ l') = settle (settle r l) l' := by
  simp [settle, List.foldl_append]

theorem take_key (r x : Reg) : r.key ≤ (r.take x).key := by
  unfold Reg.take; split
  · rename_i h; exact Nat.le_of_lt ((Reg.beats_iff _ _).1 h)
  · exact Nat.le_refl _

theorem settle_key (r : Reg) (l : List Reg) : r.key ≤ (settle r l).key := by
  induction l generalizing r with
  | nil => exact Nat.le_refl _
  | cons x l ih => exact Nat.le_trans (take_key r x) (ih _)

/-- A press `p` that beats what its author held (`r0`), against presses the
    other side made: reading them from `p` ends where reading them from
    `r0` and then taking `p` does. -/
theorem settle_press (p : Reg) (l : List Reg) (hl : ∀ x ∈ l, x.byA ≠ p.byA) :
    ∀ r0 : Reg, r0.key < p.key → settle p l = (settle r0 l).take p := by
  induction l with
  | nil => intro r0 h0; simp [Reg.take, (Reg.beats_iff _ _).2 h0]
  | cons x l ih =>
    intro r0 h0
    have hx := hl x (by simp)
    have hl' : ∀ y ∈ l, y.byA ≠ p.byA := fun y hy => hl y (by simp [hy])
    simp only [settle_cons]
    by_cases hb : x.beats p = true
    · have hpx := (Reg.beats_iff _ _).1 hb
      have hpr : p.take x = x := by simp [Reg.take, hb]
      have hrx : r0.take x = x := by simp [Reg.take, (Reg.beats_iff _ _).2 (Nat.lt_trans h0 hpx)]
      rw [hpr, hrx]
      have hge := settle_key x l
      have hnb : ¬ (p.beats (settle x l) = true) := by
        rw [Reg.beats_iff]; omega
      simp [Reg.take, hnb]
    · have hne : x.key ≠ p.key := by
        unfold Reg.key; intro h
        cases hxa : x.byA <;> cases hpa : p.byA <;> simp_all <;> omega
      have hlt : x.key < p.key := by
        have : ¬ (p.key < x.key) := fun h' => hb ((Reg.beats_iff x p).2 h'); omega
      have hpr : p.take x = p := by simp [Reg.take, hb]
      rw [hpr]
      refine ih hl' _ ?_
      unfold Reg.take; split
      · exact hlt
      · exact h0

/-- A message's press, made by `byA`'s side. -/
def Msg.press? (byA : Bool) : Msg → Option Reg
  | .pause v n => some ⟨n, byA, v⟩
  | _ => none

/-- The presses on their way to c on channel k (the friend made them). -/
def pqC (cs : Cl → Core) (ch : Nat → Chan) (c : Cl) (k : Nat) : List Reg :=
  (inbC cs ch c k).filterMap (Msg.press? (c.other == .a))

def pq (s : State) (c : Cl) (k : Nat) : List Reg := pqC s.cs s.ch c k

/-- The friend's RESUME is the next thing c reads. -/
def resHead : List Msg → Bool
  | .resume .. :: _ => true
  | _ => false

theorem resHead_append {l : List Msg} (h : resHead l = true) (ms : List Msg) :
    resHead (l ++ ms) = true := by
  cases l with
  | nil => cases h
  | cons m l => cases m <;> simp_all [resHead]

/-- The press-agreement invariant, apart from `Sync`. -/
structure SCore (s : State) : Prop where
  /-- A redialing side has sent no presses on the channel it holds. -/
  quiet : ∀ c k, (s.sd c).ph = .recon → hdC s.cs c k → hdC s.cs c.other k → pq s c.other k = []
  /-- On a channel c has opened, a friend still redialing reads c's RESUME next. -/
  head  : ∀ c k, (s.sd c).dc = some k → (s.sd c.other).ph = .recon → hdC s.cs c.other k →
            (s.ch k).dead = false → resHead (inbC s.cs s.ch c.other k) = true
  /-- ...and in any case before any press. -/
  head2 : ∀ c k, (s.sd c).ph = .recon → hdC s.cs c k → pq s c k ≠ [] →
            resHead (inbC s.cs s.ch c k) = true
  /-- Live on a channel the friend is resuming on: what the friend will hold. -/
  half  : ∀ c k, (s.sd c).ph = .live → (s.sd c).dc = some k → (s.sd c.other).ph = .recon →
            hdC s.cs c.other k → (s.ch k).dead = false →
            settle (Reg.base (finalPause (s.sd c).fP (s.sd c).fA (s.sd c.other).fP (s.sd c.other).fA))
              (pq s c.other k) = (s.sd c).reg
  /-- Both live on a working channel: they will hold the same press. -/
  conv  : ∀ c k, (s.sd c).ph = .live → (s.sd c.other).ph = .live → (s.sd c).dc = some k →
            (s.sd c.other).dc = some k → (s.ch k).dead = false →
            settle (s.sd c).reg (pq s c k) = settle (s.sd c.other).reg (pq s c.other k)

/-- A live side's pause is its winning press's. -/
def Sync (s : State) : Prop := ∀ c, (s.sd c).ph = .live → (s.sd c).paused = (s.sd c).reg.on

def SInv (s : State) : Prop := SCore s ∧ Sync s

/-- The fields of a side the press argument reads (with `paused`, for `Sync`). -/
def Side.sv (x : Side) : Ph × Option Nat × Option Nat × Reg × Bool × Bool :=
  (x.ph, x.dc, x.rsPc, x.reg, x.fP, x.fA)

/-- With the same press fields, and only non-presses added behind what a
    holder had on its way, the core carries over. -/
theorem SCore.frame {s t : State} (h : SCore s)
    (e : ∀ c, (t.sd c).sv = (s.sd c).sv) (hd : ∀ k, (t.ch k).dead = (s.ch k).dead)
    (hq : ∀ c k, hdC s.cs c k → ∃ ms, inbC t.cs t.ch c k = inbC s.cs s.ch c k ++ ms ∧
      ms.filterMap (Msg.press? (c.other == .a)) = []) : SCore t := by
  have ef : ∀ c, (t.sd c).ph = (s.sd c).ph ∧ (t.sd c).dc = (s.sd c).dc ∧ (t.sd c).rsPc = (s.sd c).rsPc ∧
      (t.sd c).reg = (s.sd c).reg ∧ (t.sd c).fP = (s.sd c).fP ∧ (t.sd c).fA = (s.sd c).fA := by
    intro c; have := e c; simp only [Side.sv, Prod.mk.injEq] at this; exact this
  have thd : ∀ c k, hdC t.cs c k ↔ hdC s.cs c k := by
    intro c k; simp only [hdC, cs_apply, core_dc, core_rsPc, (ef c).2.1, (ef c).2.2.1]
  have tpq : ∀ c k, hdC s.cs c k → pq t c k = pq s c k := by
    intro c k hc; obtain ⟨ms, h1, h2⟩ := hq c k hc
    simp [pq, pqC, h1, List.filterMap_append, h2]
  have thead : ∀ c k, hdC s.cs c k → resHead (inbC s.cs s.ch c k) = true →
      resHead (inbC t.cs t.ch c k) = true := by
    intro c k hc hr; obtain ⟨ms, h1, -⟩ := hq c k hc; rw [h1]; exact resHead_append hr ms
  refine ⟨fun c k hr hc ho => ?_, fun c k hk hr ho hdk => ?_, fun c k hr hc hp => ?_,
    fun c k hl hk hr ho hdk => ?_, fun c k hl ho hk hko hdk => ?_⟩
  · rw [thd] at hc ho; rw [(ef c).1] at hr; rw [tpq _ _ ho]; exact h.quiet c k hr hc ho
  · rw [thd] at ho; rw [(ef c).2.1] at hk; rw [(ef _).1] at hr; rw [hd] at hdk
    exact thead _ _ ho (h.head c k hk hr ho hdk)
  · rw [thd] at hc; rw [(ef c).1] at hr; rw [tpq _ _ hc] at hp
    exact thead _ _ hc (h.head2 c k hr hc hp)
  · rw [thd] at ho; rw [(ef c).1] at hl; rw [(ef c).2.1] at hk; rw [(ef _).1] at hr; rw [hd] at hdk
    rw [tpq _ _ ho, (ef c).2.2.2.1, (ef c).2.2.2.2.1, (ef c).2.2.2.2.2, (ef c.other).2.2.2.2.1,
      (ef c.other).2.2.2.2.2]
    exact h.half c k hl hk hr ho hdk
  · rw [(ef c).1] at hl; rw [(ef _).1] at ho; rw [(ef c).2.1] at hk; rw [(ef _).2.1] at hko
    rw [hd] at hdk
    have hc : hdC s.cs c k := Or.inl (by simpa [cs_apply] using hk)
    have hco : hdC s.cs c.other k := Or.inl (by simpa [cs_apply] using hko)
    rw [tpq _ _ hc, tpq _ _ hco, (ef c).2.2.2.1, (ef c.other).2.2.2.1]
    exact h.conv c k hl ho hk hko hdk

theorem pq_mem_byA {s : State} {c : Cl} {k : Nat} {x : Reg} (hx : x ∈ pq s c k) :
    x.byA = (c.other == .a) := by
  unfold pq pqC at hx
  rw [List.mem_filterMap] at hx
  obtain ⟨m, -, hm⟩ := hx
  cases m with
  | pause v n => simp only [Msg.press?, Option.some.injEq] at hm; subst hm; rfl
  | _ => simp [Msg.press?] at hm

theorem byA_other_ne (c : Cl) : (c.other == .a) ≠ (c == .a) := by cases c <;> decide

theorem press_beats (r : Reg) (b v : Bool) : (⟨r.n + 1, b, v⟩ : Reg).beats r = true := by
  rw [Reg.beats_iff]; unfold Reg.key; dsimp only; split <;> split <;> omega

theorem cs_updS_nc {s : State} {c : Cl} {f : Side → Side} (hf : ∀ y, (f y).core = y.core) :
    (updS c f s).cs = s.cs := by
  funext d; simp only [State.cs, updS_sd]; split <;> simp [hf]

theorem SCore.of_eq {s t : State} (h : SCore s) (hsd : t.sd = s.sd) (hch : t.ch = s.ch) : SCore t := by
  have hcs : t.cs = s.cs := by funext d; simp [State.cs, hsd]
  exact h.frame (fun c => by rw [hsd]) (fun k => by rw [hch])
    (fun c k _ => ⟨[], by rw [hcs, hch]; simp, rfl⟩)

theorem SCore.send_np {s : State} {c : Cl} {m : Msg} (h : SCore s) (hm : ∀ b, m.press? b = none) :
    SCore (send c m s) := by
  rcases send_cases c m s with e | ⟨k, -, -, -, e⟩
  · rw [e]; exact h
  · rw [e]
    refine h.frame (fun _ => rfl) (fun j => appendQ_dead ..) (fun d j _ => ?_)
    rw [appendQ_cs, inbC_appendQ]
    split
    · exact ⟨[m], rfl, by simp [hm]⟩
    · exact ⟨[], by simp, rfl⟩

theorem SCore.sendAll_frames {s : State} {c : Cl} {t n : Nat} (h : SCore s) :
    SCore (sendAll c (frames t n) s) := by
  rw [sendAll_eq]
  split
  · split
    · exact h
    · refine h.frame (fun _ => rfl) (fun j => appendQ_dead ..) (fun d j _ => ?_)
      rw [appendQ_cs, inbC_appendQ]
      split
      · refine ⟨_, rfl, ?_⟩
        unfold frames
        induction (List.range' t (n - t)) with
        | nil => rfl
        | cons x xs ih => simp [List.filterMap_cons, Msg.press?, ih]
      · exact ⟨[], by simp, rfl⟩
  · exact h

theorem SCore.updS_nv {s : State} {c : Cl} {f : Side → Side} (h : SCore s) (hf : ∀ y, (f y).sv = y.sv)
    (he : ∀ y, (f y).early = y.early) : SCore (updS c f s) := by
  have hr : ∀ y, (f y).rsPc = y.rsPc := fun y => by
    have := hf y; simp only [Side.sv, Prod.mk.injEq] at this; exact this.2.2.1
  refine h.frame (fun d => ?_) (fun _ => rfl) (fun d k _ => ⟨[], ?_, rfl⟩)
  · simp only [updS_sd]; split <;> simp [hf]
  · rw [List.append_nil]; unfold inbC; simp only [cs_apply, core_rsPc, core_early, updS_sd, updS_ch]
    split <;> simp [hr, he] <;> rfl

theorem Sync.upd {s : State} {c : Cl} {f : Side → Side} (h : Sync s)
    (hf : ∀ y, (f y).ph = y.ph ∧ (f y).paused = y.paused ∧ (f y).reg = y.reg) : Sync (updS c f s) := by
  intro d hl; simp only [updS_sd] at hl ⊢
  split at hl
  · rename_i hd; subst hd; simp only [if_true]; rw [(hf _).2.1, (hf _).2.2]; rw [(hf _).1] at hl; exact h _ hl
  · rename_i hd; simp only [hd, if_false]; exact h d hl

theorem Sync.of_eq {s t : State} (h : Sync s) (hsd : t.sd = s.sd) : Sync t := by
  intro c hl; rw [hsd] at hl ⊢; exact h c hl

/-- c holds no channel, and nothing about the friend moved. -/
theorem SCore.loose {s t : State} {c : Cl} (h : SCore s) (hdc : (t.sd c).dc = none)
    (hrs : (t.sd c).rsPc = none) (hso : t.sd c.other = s.sd c.other)
    (inbo : ∀ j, inbC t.cs t.ch c.other j = inbC s.cs s.ch c.other j)
    (hdo : ∀ j, (t.ch j).dead = (s.ch j).dead) : SCore t := by
  have hnot : ∀ j, ¬ hdC t.cs c j := by intro j; simp [hdC, cs_apply, hdc, hrs]
  have hno : ∀ j, ¬ ((t.sd c).dc = some j) := by intro j; simp [hdc]
  have to : ∀ j, hdC t.cs c.other j ↔ hdC s.cs c.other j := by intro j; simp [hdC, cs_apply, hso]
  have pqo : ∀ j, pq t c.other j = pq s c.other j := by intro j; simp only [pq, pqC, inbo]
  refine ⟨fun e k hr hc ho => ?_, fun e k hk hr ho hd => ?_, fun e k hr hc hp => ?_,
    fun e k hl hk hr ho hd => ?_, fun e k hl ho hk hko hd => ?_⟩
  · rcases Cl.eq_or c e with rfl | rfl
    · exact absurd hc (hnot k)
    · simp only [Cl.other_other] at ho; exact absurd ho (hnot k)
  · rcases Cl.eq_or c e with rfl | rfl
    · exact absurd hk (hno k)
    · simp only [Cl.other_other] at ho; exact absurd ho (hnot k)
  · rcases Cl.eq_or c e with rfl | rfl
    · exact absurd hc (hnot k)
    · rw [to] at hc; rw [pqo] at hp; rw [hso] at hr; rw [inbo]; exact h.head2 _ k hr hc hp
  · rcases Cl.eq_or c e with rfl | rfl
    · exact absurd hk (hno k)
    · simp only [Cl.other_other] at ho; exact absurd ho (hnot k)
  · rcases Cl.eq_or c e with rfl | rfl
    · exact absurd hk (hno k)
    · simp only [Cl.other_other] at hko; exact absurd hko (hno k)

theorem SCore.onDetach {s : State} {c : Cl} (h : SCore s) : SCore (detach c s) := by
  obtain ⟨-, -, hq, hdd, -, -, hsc, hso⟩ := detach_parts s c
  refine h.loose (c := c) (by simp [hsc]) (by simp [hsc]) hso (fun j => ?_) hdd
  unfold inbC; simp only [cs_apply, hso, hq]; rfl

theorem Sync.onDetach {s : State} {c : Cl} (h : Sync s) : Sync (detach c s) := by
  obtain ⟨-, -, -, -, -, -, hsc, hso⟩ := detach_parts s c
  intro e hl
  rcases Cl.eq_or c e with rfl | rfl
  · rw [hsc] at hl ⊢; exact h _ hl
  · rw [hso] at hl ⊢; exact h _ hl

/-- A side holding nothing changes, keeping it so. -/
theorem SCore.updS_free {s : State} {c : Cl} {f : Side → Side} (h : SCore s)
    (hdc : (s.sd c).dc = none) (hrs : (s.sd c).rsPc = none)
    (hf : ∀ y, (f y).dc = y.dc ∧ (f y).rsPc = y.rsPc) : SCore (updS c f s) := by
  refine h.loose (c := c) (by simp [(hf _).1, hdc]) (by simp [(hf _).2, hrs]) (by simp) (fun j => ?_)
    (fun _ => rfl)
  unfold inbC; simp [cs_apply]; try rfl

theorem Sync.updS_free {s : State} {c : Cl} {f : Side → Side} (h : Sync s)
    (hf : (f (s.sd c)).ph ≠ .live) : Sync (updS c f s) := by
  intro e hl
  rcases Cl.eq_or c e with rfl | rfl
  · simp only [updS_sd_self] at hl; exact absurd hl hf
  · simp only [updS_sd_other] at hl ⊢; exact h _ hl

theorem SCore.onFinish {s : State} {c : Cl} {w : End} (h : SCore s) : SCore (finish c w s) := by
  unfold LinkResume.finish
  obtain ⟨-, -, -, -, -, -, hsc, -⟩ := detach_parts s c
  exact h.onDetach.updS_free (by simp [hsc]) (by simp [hsc]) (fun y => ⟨rfl, rfl⟩)

theorem Sync.onFinish {s : State} {c : Cl} {w : End} (h : Sync s) : Sync (finish c w s) := by
  unfold LinkResume.finish; exact h.onDetach.updS_free (by simp)

theorem SInv.onShutdown {s : State} {c : Cl} {w : End} (h : SInv s) : SInv (shutdown c w s) := by
  unfold LinkResume.shutdown
  have h1 : SInv (if (s.sd c).bye then s else send c .bye s) := by
    split
    · exact h
    · exact ⟨h.1.send_np (fun _ => rfl), h.2.of_eq (send_sd ..)⟩
  have h2 : SInv (finish c w (if (s.sd c).bye then s else send c .bye s)) := ⟨h1.1.onFinish, h1.2.onFinish⟩
  unfold LinkResume.leaveNote
  split
  · exact ⟨h2.1.of_eq rfl rfl, h2.2.of_eq rfl⟩
  · exact h2

theorem SInv.onRestart {s : State} {c : Cl} (h : SInv s) : SInv (restart c s) := by
  unfold LinkResume.restart
  split
  · exact h.onShutdown
  · exact ⟨h.1.onDetach, h.2.onDetach⟩

theorem SInv.onDropped {s : State} {c : Cl} (h : SInv s) : SInv (dropped c s) := by
  unfold LinkResume.dropped
  dsimp only
  split
  · split
    · exact h.onRestart
    · split
      · exact h.onShutdown
      · obtain ⟨-, -, -, -, -, -, hsc, -⟩ := detach_parts s c
        exact ⟨h.1.onDetach.updS_free (by simp [hsc]) (by simp [hsc]) (fun y => ⟨rfl, rfl⟩),
          h.2.onDetach.updS_free (by simp)⟩
  · exact h.onShutdown

theorem SInv.onPair {s : State} {cfg : Cfg} (h : SInv s) (hi : Inv s) (hen : en cfg s .pair = true) :
    SInv (pair s) := by
  simp only [en, Bool.and_eq_true, beq_iff_eq, Option.isNone_iff_eq_none] at hen
  obtain ⟨⟨⟨⟨⟨hra, hrb⟩, hpa⟩, hpb⟩, hda⟩, hdb⟩ := hen
  have hr : ∀ e, (s.sd e).ph = .recon ∧ (s.sd e).rsPc = none ∧ (s.sd e).dc = none := by
    intro e; cases e <;> simp_all
  have tsd : ∀ e, (LinkResume.pair s).sd e = { s.sd e with rsPc := some s.nextCh } := by
    intro e; cases e <;> simp [LinkResume.pair]
  have tch : (LinkResume.pair s).ch = s.ch := by simp [LinkResume.pair]
  have hearly : ∀ e, (s.sd e).early = [] := by
    intro e
    cases hl : (s.sd e).early with
    | nil => rfl
    | cons x xs =>
      have := (hi.earlySh e (by simp [cs_apply, hl])).2; simp [cs_apply, (hr e).2.1] at this
  have thd : ∀ e j, hdC (LinkResume.pair s).cs e j → j = s.nextCh := by
    intro e j hj; simp [hdC, cs_apply, tsd, (hr e).2.2] at hj; exact hj.symm
  have tpq : ∀ e, pq (LinkResume.pair s) e s.nextCh = [] := by
    intro e
    have hq := ((hi.fresh s.nextCh (Nat.le_refl _)).2 e).1
    simp [pq, pqC, inbC, cs_apply, tsd, tch, hearly, hq]
  refine ⟨⟨fun e k hre hc ho => ?_, fun e k hk => ?_, fun e k hre hc hp => ?_,
    fun e k hl => ?_, fun e k hl => ?_⟩, fun e hl => ?_⟩
  · rw [thd e k hc]; exact tpq _
  · rw [tsd] at hk; simp [(hr e).2.2] at hk
  · rw [thd e k hc] at hp; exact absurd (tpq e) hp
  · rw [tsd] at hl; simp [(hr e).1] at hl
  · rw [tsd] at hl; simp [(hr e).1] at hl
  · rw [tsd] at hl; simp [(hr e).1] at hl

/-- c's own press on the live channel k. -/
theorem SCore.onPress {s : State} {c : Cl} {k : Nat} {p : Bool} (h : SCore s)
    (hl : (s.sd c).ph = .live) (hk : (s.sd c).dc = some k) (hrs : (s.sd c).rsPc = none)
    (hcl : (s.ch k).closed c = false) (hsame : ∀ j, hdC s.cs c.other j → j = k) :
    SCore (press c p s) := by
  unfold LinkResume.press
  dsimp only
  generalize hn : (s.sd c).reg.n + 1 = n
  generalize hr : (⟨n, c == .a, p⟩ : Reg) = r
  have hrb : r.beats (s.sd c).reg = true := by rw [← hr, ← hn]; exact press_beats _ _ _
  have hrt : (s.sd c).reg.take r = r := by simp [Reg.take, hrb]
  have hra : r.byA = (c == .a) := by rw [← hr]
  have hrk : (s.sd c).reg.key < r.key := (Reg.beats_iff _ _).1 hrb
  have hcj : ∀ j, hdC s.cs c j → j = k := by
    intro j hj; simp [hdC, cs_apply, hk, hrs] at hj; exact hj.symm
  have hcs : (updS c (fun y => { y with reg := r }) s).cs = s.cs := cs_updS_nc (fun y => rfl)
  -- c's other fields
  have tsc : ∀ (S : State), S.sd = s.sd → (updS c (fun y => { y with reg := r }) S).sd c =
      { s.sd c with reg := r } := by intro S hS; simp [hS]
  have tso : ∀ (S : State), S.sd = s.sd → (updS c (fun y => { y with reg := r }) S).sd c.other =
      s.sd c.other := by intro S hS; simp [hS]
  by_cases hdk : (s.ch k).dead = true
  · -- lost with the channel: only c's register moved, and every claim on it needs k alive
    have hs : send c (.pause p n) s = s := by unfold send; simp [hk, hdk]
    rw [hs]
    have hcs' : (updS c (fun y => { y with reg := r }) s).cs = s.cs := hcs
    refine ⟨fun e j hre hc ho => ?_, fun e j hj hre ho hd => ?_, fun e j hre hc hp => ?_,
      fun e j hle hj hre ho hd => ?_, fun e j hle ho hj hjo hd => ?_⟩
    · rw [hcs'] at hc ho; simp only [pq, hcs', updS_ch]
      rcases Cl.eq_or c e with rfl | rfl
      · rw [tsc s rfl] at hre; simp [hl] at hre
      · rw [tso s rfl] at hre; exact h.quiet _ j hre hc ho
    · rw [hcs'] at ho; simp only [hcs', updS_ch] at hd ⊢
      rcases Cl.eq_or c e with rfl | rfl
      · rw [tsc s rfl] at hj; simp only at hj; rw [hk] at hj; cases hj; rw [hdk] at hd; cases hd
      · simp only [Cl.other_other] at hre ho ⊢; rw [tsc s rfl] at hre; simp [hl] at hre
    · rw [hcs'] at hc; simp only [pq, hcs', updS_ch] at hp ⊢
      rcases Cl.eq_or c e with rfl | rfl
      · rw [tsc s rfl] at hre; simp [hl] at hre
      · rw [tso s rfl] at hre; exact h.head2 _ j hre hc hp
    · rcases Cl.eq_or c e with rfl | rfl
      · rw [tsc s rfl] at hj; simp only at hj; rw [hk] at hj; cases hj; simp only [updS_ch] at hd
        rw [hdk] at hd; cases hd
      · simp only [Cl.other_other] at hre; rw [tsc s rfl] at hre; simp [hl] at hre
    · rcases Cl.eq_or c e with rfl | rfl
      · rw [tsc s rfl] at hj; simp only at hj; rw [hk] at hj; cases hj; simp only [updS_ch] at hd
        rw [hdk] at hd; cases hd
      · simp only [Cl.other_other] at hjo; rw [tsc s rfl] at hjo; simp only at hjo; rw [hk] at hjo
        cases hjo; simp only [updS_ch] at hd; rw [hdk] at hd; cases hd
  · have hdk' : (s.ch k).dead = false := by simpa using hdk
    have hs : send c (.pause p n) s = appendQ k c.other [.pause p n] s := by
      unfold send appendQ; simp [hk, hdk', hcl]
    rw [hs]
    generalize hT : updS c (fun y => { y with reg := r }) (appendQ k c.other [.pause p n] s) = T
    have Tcs : T.cs = s.cs := by
      rw [← hT, cs_updS_nc (f := fun y => { y with reg := r }) (fun y => rfl), appendQ_cs]
    have Tc : T.sd c = { s.sd c with reg := r } := by rw [← hT]; exact tsc _ rfl
    have To : T.sd c.other = s.sd c.other := by rw [← hT]; exact tso _ rfl
    have Tdead : ∀ j, (T.ch j).dead = (s.ch j).dead := by intro j; rw [← hT]; simp
    have Tinb : ∀ e j, inbC T.cs T.ch e j =
        if j = k ∧ e = c.other then inbC s.cs s.ch e j ++ [.pause p n] else inbC s.cs s.ch e j := by
      intro e j; rw [Tcs, ← hT, updS_ch, inbC_appendQ]
    have Tpqc : ∀ j, pq T c j = pq s c j := by
      intro j; simp only [pq, pqC, Tinb, Cl.ne_other, and_false, if_false]
    have Tpqo : pq T c.other k = pq s c.other k ++ [r] := by
      simp only [pq, pqC, Tinb, and_self, if_true, List.filterMap_append, Cl.other_other]
      rw [← hr]; simp [Msg.press?]
    have Tpqj : ∀ j, j ≠ k → pq T c.other j = pq s c.other j := by
      intro j hj; simp only [pq, pqC, Tinb, hj, false_and, if_false]
    have Thd : ∀ e j, hdC T.cs e j ↔ hdC s.cs e j := by intro e j; rw [Tcs]
    have hauth : ∀ x ∈ pq s c k, x.byA ≠ r.byA := by
      intro x hx; rw [pq_mem_byA hx, hra]; exact byA_other_ne c
    -- both live on k: the press moves both settles by `take r`
    have hconv : (s.sd c.other).ph = .live → (s.sd c.other).dc = some k →
        settle r (pq s c k) = settle (s.sd c.other).reg (pq s c.other k ++ [r]) := by
      intro hlo hko
      rw [settle_append, ← h.conv c k hl hlo hk hko hdk', settle_press r _ hauth _ hrk]
      rfl
    refine ⟨fun e j hre hc ho => ?_, fun e j hj hre ho hd => ?_, fun e j hre hc hp => ?_,
      fun e j hle hj hre ho hd => ?_, fun e j hle ho hj hjo hd => ?_⟩
    · rw [Thd] at hc ho
      rcases Cl.eq_or c e with rfl | rfl
      · rw [Tc] at hre; simp [hl] at hre
      · rw [To] at hre; simp only [Cl.other_other] at ho ⊢; rw [Tpqc]
        simpa using h.quiet _ j hre hc (by simpa using ho)
    · rw [Thd] at ho; rw [Tdead] at hd
      rcases Cl.eq_or c e with rfl | rfl
      · rw [Tc] at hj; simp only at hj; rw [hk] at hj; cases hj
        rw [To] at hre
        rw [Tinb]; simp only [and_self, if_true]
        exact resHead_append (h.head _ _ hk hre ho hd) _
      · simp only [Cl.other_other] at hre; rw [Tc] at hre; simp [hl] at hre
    · rw [Thd] at hc
      rcases Cl.eq_or c e with rfl | rfl
      · rw [Tc] at hre; simp [hl] at hre
      · rw [To] at hre
        by_cases hjk : j = k
        · subst hjk
          rw [Tinb]; simp only [and_self, if_true]
          exact resHead_append (h.head _ _ hk (by simpa using hre) (by simpa using hc) hdk') _
        · rw [Tpqj j hjk] at hp; rw [Tinb]; simp only [hjk, false_and, if_false]
          exact h.head2 _ j hre hc hp
    · rcases Cl.eq_or c e with rfl | rfl
      · rw [Tc] at hle hj ⊢; simp only at hle hj ⊢; rw [hk] at hj; cases hj
        rw [To] at hre ⊢; rw [Thd] at ho; rw [Tpqo, settle_append, h.half _ _ hl hk hre ho hdk', settle_cons, settle_nil, hrt]
      · simp only [Cl.other_other] at hre; rw [Tc] at hre; simp [hl] at hre
    · rcases Cl.eq_or c e with rfl | rfl
      · rw [Tc] at hle hj ⊢; simp only at hle hj ⊢; rw [hk] at hj; cases hj
        rw [To] at ho hjo ⊢
        rw [Tpqc, Tpqo]; exact hconv ho hjo
      · simp only [Cl.other_other] at ho hjo ⊢
        rw [Tc] at hjo ho ⊢; simp only at hjo ho ⊢; rw [hk] at hjo; cases hjo
        rw [To] at hle hj ⊢
        rw [Tpqc, Tpqo]; exact (hconv hle hj).symm

theorem Sync.onPress {s : State} {c : Cl} {p : Bool} (h : Sync s) (hp : (s.sd c).paused = p) :
    Sync (press c p s) := by
  unfold LinkResume.press
  intro e hl
  rcases Cl.eq_or c e with rfl | rfl
  · simp only [updS_sd_self, send_sd] at hl ⊢; exact hp
  · simp only [updS_sd_other, send_sd] at hl ⊢; exact h _ hl

/-! ### A side that knows the code is resumable has it

`ok` (`rb.resumeOk`) is only ever set with `res` (`rb.resume`), so a
redialing side always passes `rsResumeIn`'s check. -/

def OkRes (s : State) : Prop := ∀ c, (s.sd c).ok = true → (s.sd c).res = true

/-- Neither side's `ok` nor `res` moved. -/
def SameOR (s t : State) : Prop := ∀ c, (t.sd c).ok = (s.sd c).ok ∧ (t.sd c).res = (s.sd c).res

theorem SameOR.refl (s : State) : SameOR s s := fun _ => ⟨rfl, rfl⟩
theorem SameOR.trans {s t u : State} (h1 : SameOR s t) (h2 : SameOR t u) : SameOR s u :=
  fun c => ⟨(h2 c).1.trans (h1 c).1, (h2 c).2.trans (h1 c).2⟩
theorem SameOR.of_sd {s t : State} (h : t.sd = s.sd) : SameOR s t := fun c => by rw [h]; exact ⟨rfl, rfl⟩
theorem OkRes.of {s t : State} (h : OkRes s) (hs : SameOR s t) : OkRes t := by
  intro c hc; rw [(hs c).1] at hc; rw [(hs c).2]; exact h c hc

theorem SameOR.updS (s : State) (c : Cl) {f : Side → Side} (hf : ∀ y, (f y).ok = y.ok ∧ (f y).res = y.res) :
    SameOR s (updS c f s) := by
  intro d; simp only [updS_sd]; split <;> simp [hf]

theorem SameOR.send (s : State) (c : Cl) (m : Msg) : SameOR s (send c m s) := SameOR.of_sd (send_sd ..)
theorem SameOR.sendAll (s : State) (c : Cl) (ms : List Msg) : SameOR s (sendAll c ms s) :=
  SameOR.of_sd (sendAll_sd ..)

theorem SameOR.detach (s : State) (c : Cl) : SameOR s (detach c s) := by
  obtain ⟨-, -, -, -, -, -, hsc, hso⟩ := detach_parts s c
  intro d; rcases Cl.eq_or c d with rfl | rfl
  · rw [hsc]; exact ⟨rfl, rfl⟩
  · rw [hso]; exact ⟨rfl, rfl⟩

theorem SameOR.finish (s : State) (c : Cl) (w : End) : SameOR s (finish c w s) :=
  (SameOR.detach s c).trans (SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩))

theorem SameOR.shutdown (s : State) (c : Cl) (w : End) : SameOR s (shutdown c w s) := by
  unfold LinkResume.shutdown
  have h1 : SameOR s (if (s.sd c).bye then s else LinkResume.send c .bye s) := by
    split
    · exact SameOR.refl s
    · exact SameOR.send s c _
  exact (h1.trans (SameOR.finish _ c w)).trans (SameOR.of_sd (leaveNote_sd ..))

theorem SameOR.press (s : State) (c : Cl) (p : Bool) : SameOR s (press c p s) := by
  unfold LinkResume.press
  exact (SameOR.send s c _).trans (SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩))

theorem SameOR.setPaused (s : State) (c : Cl) (p r : Bool) : SameOR s (setPaused c p r s) := by
  unfold LinkResume.setPaused
  split
  · exact SameOR.refl s
  · have h1 := SameOR.updS s c (f := fun y => { y with paused := p, pfb := false }) (by intro y; exact ⟨rfl, rfl⟩)
    dsimp only; split
    · exact h1.trans (SameOR.press _ c p)
    · exact h1

theorem SameOR.pauseAfterResume (s : State) (cfg : Cfg) (c : Cl) (p a : Bool) :
    SameOR s (pauseAfterResume cfg c p a s) := by
  unfold LinkResume.pauseAfterResume
  split
  · dsimp only; split
    · have h1 := SameOR.updS s c (f := fun y => { y with livePress := y.livePress || y.ph == .live })
        (by intro y; exact ⟨rfl, rfl⟩)
      split
      · exact h1.trans (SameOR.press _ c _)
      · exact h1
    · exact SameOR.setPaused s c _ _
  · dsimp only
    have h1 : SameOR s (if (!p && (s.sd c).paused && !(cfg.iosB && c == .b && (s.sd c).away)) = true
        then LinkResume.remotePause c false s else s) := by
      split
      · exact SameOR.setPaused s c _ _
      · exact SameOR.refl s
    exact h1.trans (SameOR.send _ c _)

theorem SameOR.resumeIn (s : State) (cfg : Cfg) (c : Cl) (t : Nat) (p a : Bool) :
    SameOR s (resumeIn cfg c t p a s) := by
  unfold LinkResume.resumeIn
  dsimp only
  split
  · exact SameOR.refl s
  · split
    · exact SameOR.shutdown s c _
    · exact (((SameOR.updS s c (by intro y; exact ⟨rfl, rfl⟩)).trans (SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩))).trans
        (SameOR.sendAll _ c _)).trans (SameOR.pauseAfterResume _ cfg c p a)

theorem OkRes.recv {s : State} {cfg : Cfg} {c : Cl} {m : Msg} (h : OkRes s) : OkRes (recv cfg c m s) := by
  have h1 : OkRes (updS c (fun y => { y with lastMsg := s.now }) s) :=
    h.of (SameOR.updS s c (by intro y; exact ⟨rfl, rfl⟩))
  unfold LinkResume.recv
  dsimp only
  cases m with
  | info =>
    dsimp only
    split
    · rename_i hr
      intro d hd; simp only [updS_sd] at hd ⊢
      split
      · rename_i hdc; subst hdc; simpa using hr
      · rename_i hdc; simp only [hdc, if_false] at hd; exact h d hd
    · refine OkRes.of ?_ (SameOR.send _ c _)
      intro d hd; simp only [updS_sd] at hd ⊢
      split
      · rfl
      · rename_i hdc; simp only [hdc, if_false] at hd; exact h d hd
  | inp f => exact h1.of (SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩))
  | resume t p a => exact h1.of (SameOR.resumeIn _ cfg c t p a)
  | pause v n =>
    dsimp only
    split
    · split
      · exact h1.of ((SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩)).trans (SameOR.setPaused _ c _ _))
      · exact h1
    · exact h1.of (SameOR.setPaused _ c _ _)
  | bye => exact h1.of ((SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩)).trans (SameOR.shutdown _ c _))
  | ping => exact h1

theorem OkRes.deliver {s : State} {cfg : Cfg} {c : Cl} {k : Nat} (h : OkRes s) :
    OkRes (deliver cfg c k s) := by
  unfold LinkResume.deliver
  split
  · exact h
  · rename_i m rest _
    have hp : OkRes (updCh k (fun x => { x with q := fun d => if d = c then rest else x.q d }) s) :=
      h.of (SameOR.of_sd rfl)
    dsimp only
    split
    · exact hp
    · split
      · exact hp.recv
      · split
        · split
          · exact hp.of (SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩))
          · exact hp
        · exact hp

theorem OkRes.deliverN {s : State} {cfg : Cfg} {c : Cl} {k : Nat} (n : Nat) (h : OkRes s) :
    OkRes (deliverN cfg c k n s) := by
  induction n generalizing s with
  | zero => exact h
  | succ n ih => exact ih h.deliver

theorem OkRes.step {s : State} {cfg : Cfg} (h : OkRes s) (e : Event) : OkRes (step cfg s e) := by
  cases e with
  | input c =>
    simp only [LinkResume.step]
    have h1 := h.of (SameOR.updS s c (f := fun y => { y with sent := (s.sd c).sent + 1 }) (by intro y; exact ⟨rfl, rfl⟩))
    split
    · exact h1.of (SameOR.send _ c _)
    · exact h1
  | deliver c k => exact h.deliver
  | die k => exact h.of (SameOR.of_sd rfl)
  | dropped c =>
    simp only [LinkResume.step, LinkResume.dropped]
    split
    · split
      · simp only [LinkResume.restart]; split
        · exact h.of (SameOR.shutdown _ c _)
        · exact h.of (SameOR.detach _ c)
      · split
        · exact h.of (SameOR.shutdown _ c _)
        · exact h.of ((SameOR.detach _ c).trans (SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩)))
    · exact h.of (SameOR.shutdown _ c _)
  | pair =>
    simp only [LinkResume.step, LinkResume.pair]
    refine h.of ?_
    intro d; cases d <;> simp
  | adopt c =>
    simp only [LinkResume.step, LinkResume.adopt]
    split
    · exact h
    · refine OkRes.deliverN _ (h.of ?_)
      refine (SameOR.of_sd rfl).trans ((SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩)).trans (SameOR.send _ c _))
  | restart c =>
    simp only [LinkResume.step, LinkResume.restart]; split
    · exact h.of (SameOR.shutdown _ c _)
    · exact h.of (SameOR.detach _ c)
  | giveUp c => exact h.of (SameOR.shutdown _ c _)
  | quit c => exact h.of (SameOR.shutdown _ c _)
  | kill c => exact h.of (SameOR.finish _ c _)
  | toggle c =>
    simp only [LinkResume.step]
    exact h.of ((SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩)).trans (SameOR.setPaused _ c _ _))
  | away c on =>
    simp only [LinkResume.step, LinkResume.setAway]
    have h1 := h.of (SameOR.updS s c
      (f := fun y => { y with away := on, livePress := y.livePress || y.ph == .live })
      (by intro y; exact ⟨rfl, rfl⟩))
    split
    · exact h1
    · split
      · split
        · exact h1
        · exact h1.of ((SameOR.setPaused _ c _ _).trans (SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩)))
      · split
        · exact h1.of ((SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩)).trans (SameOR.setPaused _ c _ _))
        · exact h1
  | tick n => exact h.of (SameOR.of_sd rfl)
  | ping c => exact h.of (SameOR.send _ c _)
  | noteIn c =>
    simp only [LinkResume.step]
    split
    · exact h.of ((SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩)).trans (SameOR.shutdown _ c _))
    · exact h

theorem okres_reachable {cfg : Cfg} {s : State} (h : Reachable cfg s) : OkRes s := by
  induction h with
  | init => intro c; cases c <;> simp [init]
  | step e _ _ ih => exact ih.step e

/-! ### Reading a message -/

theorem resHead_cons (m : Msg) (l : List Msg) : resHead (m :: l) = resHead [m] := by cases m <;> rfl

theorem resHead_drop {pre rest : List Msg} {m : Msg} (h : resHead (pre ++ m :: rest) = true)
    (hm : resHead [m] = false) : resHead (pre ++ rest) = true := by
  cases pre with
  | nil => simp only [List.nil_append] at h; rw [resHead_cons, hm] at h; cases h
  | cons x xs => simp only [List.cons_append] at h ⊢; rw [resHead_cons] at h ⊢; exact h

theorem Sync.mk {s t : State} {c : Cl} (h : Sync s) (ho : t.sd c.other = s.sd c.other)
    (hc : (t.sd c).ph = .live → (t.sd c).paused = (t.sd c).reg.on) : Sync t := by
  intro e hl
  rcases Cl.eq_or c e with rfl | rfl
  · exact hc hl
  · rw [ho] at hl ⊢; exact h _ hl

/-- `remotePause`: only c's pause moves. -/
theorem setPaused_nr (c : Cl) (v : Bool) (S : State) :
    (setPaused c v false S).ch = S.ch ∧ (setPaused c v false S).sd c.other = S.sd c.other ∧
      ((setPaused c v false S).sd c).sv = (S.sd c).sv ∧ ((setPaused c v false S).sd c).paused = v ∧
      ((setPaused c v false S).sd c).early = (S.sd c).early := by
  unfold LinkResume.setPaused
  split
  · rename_i hv; exact ⟨rfl, rfl, rfl, hv, rfl⟩
  · simp [Side.sv]

/-- A message for a channel c doesn't hold (it closed its end) is dropped. -/
theorem SCore.popOut {s : State} {c : Cl} {k : Nat} {rest : List Msg} (h : SCore s)
    (hn : ¬ hdC s.cs c k) : SCore (popQ k c rest s) := by
  refine h.frame (fun _ => rfl) (fun j => popQ_dead ..) (fun d j hd => ⟨[], ?_, rfl⟩)
  rw [popQ_cs, inbC_popQ]
  split
  · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk; exact absurd hd hn
  · simp

/-- c reads a message that is no press: nothing it will hold moves; and it
    is not the friend's RESUME a redialing c waits for (or c is live). -/
theorem SCore.popNp {s : State} {c : Cl} {k : Nat} {m : Msg} {rest : List Msg} (h : SCore s)
    (hq : (s.ch k).q c = m :: rest) (hm : ∀ b, m.press? b = none)
    (hr : resHead [m] = false ∨ (s.sd c).ph = .live) : SCore (popQ k c rest s) := by
  have hib : ∀ e j, inbC (popQ k c rest s).cs (popQ k c rest s).ch e j =
      if j = k ∧ e = c then (if (s.cs c).rsPc = some k then (s.cs c).early else []) ++ rest
      else inbC s.cs s.ch e j := by
    intro e j; rw [popQ_cs, inbC_popQ]; split
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk; simp
    · simp_all
  have hin : inbC s.cs s.ch c k = (if (s.cs c).rsPc = some k then (s.cs c).early else []) ++ m :: rest := by
    unfold inbC; rw [hq]
  have tpq : ∀ e j, pq (popQ k c rest s) e j = pq s e j := by
    intro e j; unfold pq pqC; rw [hib]; split
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk; rw [hin]
      simp [List.filterMap_append, List.filterMap_cons, hm]
    · rfl
  have thd : ∀ e j, hdC (popQ k c rest s).cs e j ↔ hdC s.cs e j := by intro e j; rw [popQ_cs]
  have thead : ∀ e j, (s.sd e).ph = .recon → resHead (inbC s.cs s.ch e j) = true →
      resHead (inbC (popQ k c rest s).cs (popQ k c rest s).ch e j) = true := by
    intro e j hre hrh
    rw [hib]; split
    · rename_i hjk; obtain ⟨rfl, rfl⟩ := hjk
      rw [hin] at hrh
      rcases hr with hr | hr
      · exact resHead_drop hrh hr
      · rw [hr] at hre; cases hre
    · exact hrh
  refine ⟨fun e j hre hc ho => ?_, fun e j hk hre ho hd => ?_, fun e j hre hc hp => ?_,
    fun e j hl hk hre ho hd => ?_, fun e j hl ho hk hko hd => ?_⟩
  · rw [thd] at hc ho; rw [tpq]; exact h.quiet e j hre hc ho
  · rw [thd] at ho; rw [popQ_dead] at hd
    exact thead _ _ hre (h.head e j hk hre ho hd)
  · rw [thd] at hc; rw [tpq] at hp
    exact thead _ _ hre (h.head2 e j hre hc hp)
  · rw [thd] at ho; rw [popQ_dead] at hd; rw [tpq]; exact h.half e j hl hk hre ho hd
  · rw [popQ_dead] at hd; rw [tpq, tpq]; exact h.conv e j hl ho hk hko hd

/-- Live c reads the friend's press: it takes it if it beats its own. -/
theorem SCore.takePress {s T : State} {c : Cl} {k n : Nat} {v : Bool} {rest : List Msg} (h : SCore s)
    (hq : (s.ch k).q c = .pause v n :: rest) (hl : (s.sd c).ph = .live) (hk : (s.sd c).dc = some k)
    (hrs : (s.sd c).rsPc = none)
    (hTc : (T.sd c).sv = ((s.sd c).ph, (s.sd c).dc, (s.sd c).rsPc,
      (s.sd c).reg.take ⟨n, c.other == .a, v⟩, (s.sd c).fP, (s.sd c).fA))
    (hTe : (T.sd c).early = (s.sd c).early)
    (hTo : T.sd c.other = s.sd c.other) (hTch : T.ch = (popQ k c rest s).ch) : SCore T := by
  have ef : (T.sd c).ph = (s.sd c).ph ∧ (T.sd c).dc = (s.sd c).dc ∧ (T.sd c).rsPc = (s.sd c).rsPc ∧
      (T.sd c).reg = (s.sd c).reg.take ⟨n, c.other == .a, v⟩ ∧ (T.sd c).fP = (s.sd c).fP ∧
      (T.sd c).fA = (s.sd c).fA := by
    simpa [Side.sv] using hTc
  have hcj : ∀ j, hdC T.cs c j → j = k := by
    intro j hj; simp [hdC, cs_apply, ef.2.1, ef.2.2.1, hk, hrs] at hj; exact hj.symm
  have hcs : hdC s.cs c k := Or.inl (by simpa [cs_apply] using hk)
  have hoj : ∀ j, hdC T.cs c.other j ↔ hdC s.cs c.other j := by intro j; simp [hdC, cs_apply, hTo]
  have inbc : inbC T.cs T.ch c k = rest := by
    unfold inbC; simp [cs_apply, ef.2.2.1, hrs, hTch, popQ_q]
  have inbcs : inbC s.cs s.ch c k = .pause v n :: rest := by
    unfold inbC; simp [cs_apply, hrs, hq]
  have inbo : ∀ j, inbC T.cs T.ch c.other j = inbC s.cs s.ch c.other j := by
    intro j; unfold inbC; simp [cs_apply, hTo, hTch, popQ_q] <;> rfl
  have pqc : pq s c k = ⟨n, c.other == .a, v⟩ :: pq T c k := by
    simp only [pq, pqC, inbc, inbcs, List.filterMap_cons, Msg.press?]
  have pqo : ∀ j, pq T c.other j = pq s c.other j := by intro j; simp only [pq, pqC, inbo]
  have hdT : ∀ j, (T.ch j).dead = (s.ch j).dead := by intro j; rw [hTch]; exact popQ_dead ..
  have hnotq : (s.sd c.other).ph = .recon → hdC s.cs c.other k → False := by
    intro hre ho
    have := h.quiet c.other k hre ho (by simpa using hcs)
    simp only [Cl.other_other] at this; rw [pqc] at this; cases this
  have hconv : (s.sd c.other).ph = .live → (s.sd c.other).dc = some k → (s.ch k).dead = false →
      settle (T.sd c).reg (pq T c k) = settle (T.sd c.other).reg (pq T c.other k) := by
    intro hlo hko hdk
    have := h.conv c k hl hlo hk hko hdk
    rw [pqc, settle_cons] at this
    rw [ef.2.2.2.1, hTo, pqo, this]
  refine ⟨fun e j hre hc ho => ?_, fun e j hj hre ho hd => ?_, fun e j hre hc hp => ?_,
    fun e j hle hj hre ho hd => ?_, fun e j hle ho hj hjo hd => ?_⟩
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [ef.1, hl] at hre; cases hre
    · rw [hTo] at hre; rw [hoj] at hc; simp only [Cl.other_other] at ho ⊢
      rw [hcj j ho] at hc; exact (hnotq hre hc).elim
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [ef.2.1] at hj; rw [hTo] at hre; rw [hoj] at ho; rw [hdT] at hd; rw [inbo]
      exact h.head _ j hj hre ho hd
    · simp only [Cl.other_other] at hre; rw [ef.1, hl] at hre; cases hre
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [ef.1, hl] at hre; cases hre
    · rw [hTo] at hre; rw [hoj] at hc; rw [pqo] at hp; rw [inbo]; exact h.head2 _ j hre hc hp
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [ef.2.1, hk] at hj; cases hj; rw [hTo] at hre; rw [hoj] at ho
      exact (hnotq hre ho).elim
    · simp only [Cl.other_other] at hre; rw [ef.1, hl] at hre; cases hre
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [ef.2.1, hk] at hj; cases hj; rw [hTo] at ho hjo; rw [hdT] at hd
      exact hconv ho hjo hd
    · simp only [Cl.other_other] at ho hjo ⊢
      rw [ef.2.1, hk] at hjo; cases hjo; rw [hTo] at hle hj; rw [hdT] at hd
      exact (hconv hle hj hd).symm

/-- Redialing c reads the friend's RESUME and goes live from the shared
    base; the friend, if live, holds what settling from that base gives. -/
theorem SCore.resumed {s V : State} {c : Cl} {k t : Nat} {p a : Bool} {rest : List Msg} (h : SCore s)
    (hi : Inv s) (hp : PInv s) (hq : (s.ch k).q c = .resume t p a :: rest) (hr : (s.sd c).ph = .recon)
    (hk : (s.sd c).dc = some k)
    (hVc : (V.sd c).sv = (.live, some k, none, Reg.base (finalPause (s.sd c).fP (s.sd c).fA p a),
      (s.sd c).fP, (s.sd c).fA))
    (hVe : (V.sd c).early = [])
    (hVo : V.sd c.other = s.sd c.other) (hVch : V.ch = (popQ k c rest s).ch) : SCore V := by
  have ef : (V.sd c).ph = .live ∧ (V.sd c).dc = some k ∧ (V.sd c).rsPc = none ∧
      (V.sd c).reg = Reg.base (finalPause (s.sd c).fP (s.sd c).fA p a) ∧ (V.sd c).fP = (s.sd c).fP ∧
      (V.sd c).fA = (s.sd c).fA := by
    simpa [Side.sv] using hVc
  have hk' : (s.cs c).dc = some k := by simpa [cs_apply] using hk
  have hrs : (s.sd c).rsPc = some k := by
    have := (hi.reconDc c k (by simpa [cs_apply] using hr) hk').1; simpa [cs_apply] using this
  have hearly : (s.sd c).early = [] := by
    cases hl : (s.sd c).early with
    | nil => rfl
    | cons x xs => have := (hi.earlySh c (by simp [cs_apply, hl])).1; simp [cs_apply, hk] at this
  have hcs : hdC s.cs c k := Or.inl hk'
  have hdk : (s.ch k).dead = false := by
    cases hd : (s.ch k).dead
    · rfl
    · have := hi.deadQ k c hd; rw [hq] at this; cases this
  have inbcs : inbC s.cs s.ch c k = .resume t p a :: rest := by
    unfold inbC; simp [cs_apply, hrs, hearly, hq]
  have hfl := hp.resFlags c k p a (by unfold pinb; rw [inbcs]; simp [Msg.pr]) hcs
  have hcj : ∀ j, hdC V.cs c j → j = k := by
    intro j hj; simp [hdC, cs_apply, ef.2.1, ef.2.2.1] at hj; exact hj.symm
  have hoj : ∀ j, hdC V.cs c.other j ↔ hdC s.cs c.other j := by intro j; simp [hdC, cs_apply, hVo]
  have inbc : inbC V.cs V.ch c k = rest := by
    unfold inbC; simp [cs_apply, ef.2.2.1, hVch, popQ_q]
  have inbo : ∀ j, inbC V.cs V.ch c.other j = inbC s.cs s.ch c.other j := by
    intro j; unfold inbC; simp [cs_apply, hVo, hVch, popQ_q] <;> rfl
  have pqc : pq V c k = pq s c k := by
    simp only [pq, pqC, inbc, inbcs, List.filterMap_cons, Msg.press?]
  have pqo : ∀ j, pq V c.other j = pq s c.other j := by intro j; simp only [pq, pqC, inbo]
  have hdV : ∀ j, (V.ch j).dead = (s.ch j).dead := by intro j; rw [hVch]; exact popQ_dead ..
  -- c sent no presses while redialing
  have hq0 : hdC s.cs c.other k → pq s c.other k = [] := fun ho => h.quiet c k hr hcs ho
  have hconv : (s.sd c.other).ph = .live → (s.sd c.other).dc = some k →
      settle (V.sd c).reg (pq V c k) = settle (V.sd c.other).reg (pq V c.other k) := by
    intro hlo hko
    have ho : hdC s.cs c.other k := Or.inl (by simpa [cs_apply] using hko)
    have := h.half c.other k hlo hko (by simpa using hr) (by simpa using hcs) hdk
    simp only [Cl.other_other] at this
    rw [ef.2.2.2.1, pqc, hVo, pqo, hq0 ho, settle_nil, ← this, finalPause_comm, hfl.1, hfl.2]
  refine ⟨fun e j hre hc ho => ?_, fun e j hj hre ho hd => ?_, fun e j hre hc hp' => ?_,
    fun e j hle hj hre ho hd => ?_, fun e j hle ho hj hjo hd => ?_⟩
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [ef.1] at hre; cases hre
    · rw [hVo] at hre; rw [hoj] at hc; simp only [Cl.other_other] at ho ⊢
      rw [hcj j ho] at hc ⊢; rw [pqc]; simpa using h.quiet _ k hre hc (by simpa using hcs)
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [ef.2.1] at hj; cases hj; rw [hVo] at hre; rw [hoj] at ho; rw [hdV] at hd; rw [inbo]
      exact h.head _ _ hk hre ho hd
    · simp only [Cl.other_other] at hre; rw [ef.1] at hre; cases hre
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [ef.1] at hre; cases hre
    · rw [hVo] at hre; rw [hoj] at hc; rw [pqo] at hp'; rw [inbo]; exact h.head2 _ j hre hc hp'
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [ef.2.1] at hj; cases hj; rw [hVo] at hre ⊢; rw [hoj] at ho
      rw [pqo, hq0 ho, settle_nil, ef.2.2.2.1, ef.2.2.2.2.1, ef.2.2.2.2.2, hfl.1, hfl.2]
    · simp only [Cl.other_other] at hre; rw [ef.1] at hre; cases hre
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [ef.2.1] at hj; cases hj; rw [hVo] at ho hjo
      exact hconv ho hjo
    · simp only [Cl.other_other] at ho hjo ⊢
      rw [ef.2.1] at hjo; cases hjo; rw [hVo] at hle hj
      exact (hconv hle hj).symm

theorem Sync.two {t : State} (c : Cl) (hc : (t.sd c).ph = .live → (t.sd c).paused = (t.sd c).reg.on)
    (ho : (t.sd c.other).ph = .live → (t.sd c.other).paused = (t.sd c.other).reg.on) : Sync t := by
  intro e hl
  rcases Cl.eq_or c e with rfl | rfl
  · exact hc hl
  · exact ho hl

theorem sendAll_closed (c : Cl) (ms : List Msg) (s : State) (j : Nat) :
    ((sendAll c ms s).ch j).closed = (s.ch j).closed := by
  rw [sendAll_eq]; split
  · split
    · rfl
    · exact appendQ_closed ..
  · rfl

/-- The pause half of a resume, from the shared base: whatever branch, c's
    pause is its register's, and a press after its RESUME goes out numbered. -/
theorem SInv.pauseAfter {cfg : Cfg} (hfix : cfg.fix = true) {U : State} {c : Cl} {k : Nat} {p a : Bool}
    (hU : SCore U) (hl : (U.sd c).ph = .live) (hk : (U.sd c).dc = some k) (hrs : (U.sd c).rsPc = none)
    (hcl : (U.ch k).closed c = false) (hsame : ∀ j, hdC U.cs c.other j → j = k)
    (hreg : (U.sd c).reg = Reg.base (finalPause (U.sd c).fP (U.sd c).fA p a))
    (hso : (U.sd c.other).ph = .live → (U.sd c.other).paused = (U.sd c.other).reg.on) :
    SInv (pauseAfterResume cfg c p a U) := by
  unfold LinkResume.pauseAfterResume
  rw [if_pos hfix]
  dsimp only
  split
  · rename_i hne
    have h1 : SCore (updS c (fun y => { y with livePress := y.livePress || y.ph == .live }) U) :=
      hU.updS_nv (by intro y; rfl) (by intro y; rfl)
    split
    · refine ⟨h1.onPress (by simpa using hl) (by simpa using hk) (by simpa using hrs) (by simpa using hcl)
        (fun j hj => hsame j (by simpa [hdC, cs_apply] using hj)), Sync.two c ?_ ?_⟩
      · intro _; simp [LinkResume.press, send_sd]
      · simpa [LinkResume.press, send_sd] using hso
    · rename_i hf
      refine ⟨h1, Sync.two c (fun _ => ?_) (by simpa using hso)⟩
      simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hf
      simp [hreg, Reg.base, hf]
  · rename_i heq
    obtain ⟨n1, n2, n3, n4, n5⟩ := setPaused_nr c (finalPause (U.sd c).fP (U.sd c).fA p a) U
    refine ⟨hU.frame (fun e => ?_) (fun j => by rw [remotePause, n1])
      (fun e j _ => ⟨[], ?_, rfl⟩), Sync.two c (fun _ => ?_) ?_⟩
    · rcases Cl.eq_or c e with rfl | rfl
      · exact n3
      · rw [remotePause, n2]
    · rw [List.append_nil]; unfold inbC remotePause
      have hr' : ((setPaused c (finalPause (U.sd c).fP (U.sd c).fA p a) false U).sd c).rsPc =
          (U.sd c).rsPc := by
        have := n3; simp only [Side.sv, Prod.mk.injEq] at this; exact this.2.2.1
      rcases Cl.eq_or c e with rfl | rfl
      · simp only [cs_apply, core_rsPc, core_early, n1, hr', n5] <;> rfl
      · simp only [cs_apply, n1, n2] <;> rfl
    · have hr' : ((setPaused c (finalPause (U.sd c).fP (U.sd c).fA p a) false U).sd c).reg = (U.sd c).reg := by
        have := n3; simp only [Side.sv, Prod.mk.injEq] at this; exact this.2.2.2.1
      unfold remotePause; rw [n4, hr', hreg]; rfl
    · unfold remotePause; rw [n2]; exact hso

/-- A message for the pairing c is still opening waits in `rsEarly`. -/
theorem SCore.earlyPush {s : State} {c : Cl} {k : Nat} {m : Msg} {rest : List Msg} (h : SCore s)
    (hq : (s.ch k).q c = m :: rest) (hrs : (s.sd c).rsPc = some k) :
    SCore (updS c (fun y => { y with early := y.early ++ [m] }) (popQ k c rest s)) := by
  refine h.frame (fun d => ?_) (fun j => popQ_dead ..) (fun d j _ => ⟨[], ?_, rfl⟩)
  · simp only [updS_sd, popQ_sd]; split <;> rfl
  · rw [List.append_nil]; unfold inbC
    simp only [cs_apply, core_rsPc, core_early, updS_sd, popQ_sd, updS_ch, popQ_q]
    by_cases hdc : d = c
    · subst hdc
      by_cases hj : j = k
      · subst hj; simp [hrs, hq]
      · have hne : (s.sd d).rsPc ≠ some j := by rw [hrs]; intro h'; exact hj (Option.some.inj h').symm
        simp [hj, hne]
    · simp [hdc] <;> rfl

theorem SInv.onDeliver {cfg : Cfg} (hseq : cfg.seq = true) (hfix : cfg.fix = true)
    (hearly : cfg.early = true) {s : State} {c : Cl} {k : Nat} (hi : Inv s) (hp : PInv s) (hQ : QInv s)
    (hor : OkRes s) (h : SInv s) : SInv (deliver cfg c k s) := by
  unfold LinkResume.deliver
  split
  · exact h
  · rename_i m rest hq
    dsimp only
    have hpop : updCh k (fun x => { x with q := fun d => if d = c then rest else x.q d }) s =
        popQ k c rest s := rfl
    rw [hpop]
    have hdk : (s.ch k).dead = false := by
      cases hd : (s.ch k).dead
      · rfl
      · have := hi.deadQ k c hd; rw [hq] at this; cases this
    split
    · rename_i hcl
      have hn : ¬ hdC s.cs c k := fun hc => by
        have := (hi.hold c k hc).2; rw [popQ_closed] at hcl; rw [this] at hcl; cases hcl
      exact ⟨h.1.popOut hn, h.2.of_eq rfl⟩
    · split
      · rename_i hd
        have hd : (s.sd c).dc = some k := by simpa using hd
        have hk' : (s.cs c).dc = some k := by simpa [cs_apply] using hd
        have hc : hdC s.cs c k := Or.inl hk'
        have hne : (s.sd c).ph ≠ .ended := fun he => by
          have := (hi.endSh c (by simpa [cs_apply] using he)).1; simp [cs_apply, hd] at this
        have hearly' : (s.sd c).early = [] := by
          cases hl : (s.sd c).early with
          | nil => rfl
          | cons x xs => have := (hi.earlySh c (by simp [cs_apply, hl])).1; simp [cs_apply, hd] at this
        have hS1 : SInv (popQ k c rest s) →
            SInv (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s)) :=
          fun h1 => ⟨h1.1.updS_nv (by intro y; rfl) (by intro y; rfl),
            h1.2.upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
        cases m with
        | inp f =>
          have h1 := hS1 ⟨h.1.popNp hq (fun _ => rfl) (Or.inl rfl), h.2.of_eq rfl⟩
          simp only [recv]
          exact ⟨h1.1.updS_nv (by intro y; rfl) (by intro y; rfl), h1.2.upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
        | info =>
          have h1 := hS1 ⟨h.1.popNp hq (fun _ => rfl) (Or.inl rfl), h.2.of_eq rfl⟩
          simp only [recv]
          split
          · exact ⟨h1.1.updS_nv (by intro y; rfl) (by intro y; rfl),
              h1.2.upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
          · have h2 : SInv (updS c (fun y => { y with res := true, ok := true })
                (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s))) :=
              ⟨h1.1.updS_nv (by intro y; rfl) (by intro y; rfl), h1.2.upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
            exact ⟨h2.1.send_np (fun _ => rfl), h2.2.of_eq (send_sd ..)⟩
        | ping =>
          have h1 := hS1 ⟨h.1.popNp hq (fun _ => rfl) (Or.inl rfl), h.2.of_eq rfl⟩
          simp only [recv]; exact h1
        | bye =>
          have h1 := hS1 ⟨h.1.popNp hq (fun _ => rfl) (Or.inl rfl), h.2.of_eq rfl⟩
          simp only [recv]
          exact SInv.onShutdown ⟨h1.1.updS_nv (by intro y; rfl) (by intro y; rfl),
            h1.2.upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
        | pause v n =>
          have hlive : (s.sd c).ph = .live := by
            cases hph : (s.sd c).ph with
            | live => rfl
            | ended => exact absurd hph hne
            | recon =>
              exfalso
              have hpq : pq s c k ≠ [] := by
                simp [pq, pqC, inbC, cs_apply, hq, hearly', Msg.press?]
              have := h.1.head2 c k hph hc hpq
              simp [inbC, cs_apply, hq, hearly', resHead] at this
          have hrs : (s.sd c).rsPc = none := by
            have := (hi.liveSh c (by simpa [cs_apply] using hlive)).1; simpa [cs_apply] using this
          simp only [recv, hseq, ↓reduceIte]
          split
          · rename_i hb
            simp only [updS_sd_self, popQ_sd] at hb
            generalize hS : updS c (fun y => { y with reg := ⟨n, c.other == .a, v⟩ })
              (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s)) = S
            have Sc : S.sd c = { s.sd c with lastMsg := s.now, reg := ⟨n, c.other == .a, v⟩ } := by
              rw [← hS]; simp
            have So : S.sd c.other = s.sd c.other := by rw [← hS]; simp
            have Sch : S.ch = (popQ k c rest s).ch := by rw [← hS]; rfl
            obtain ⟨n1, n2, n3, n4, n5⟩ := setPaused_nr c v S
            refine ⟨h.1.takePress hq hlive hd hrs ?_ ?_ ?_ ?_, ?_⟩
            · rw [remotePause, n3, Sc]; simp [Side.sv, Reg.take, hb]
            · rw [remotePause, n5, Sc]
            · rw [remotePause, n2, So]
            · rw [remotePause, n1, Sch]
            · refine Sync.mk (c := c) h.2 (by rw [remotePause, n2, So]) (fun _ => ?_)
              have hr' : ((setPaused c v false S).sd c).reg = (S.sd c).reg := by
                have := n3; simp only [Side.sv, Prod.mk.injEq] at this; exact this.2.2.2.1
              unfold remotePause; rw [n4, hr', Sc]
          · rename_i hb
            simp only [updS_sd_self, popQ_sd] at hb
            refine ⟨h.1.takePress hq hlive hd hrs ?_ ?_ ?_ ?_, ?_⟩
            · simp [Side.sv, Reg.take, hb]
            · simp
            · simp
            · rfl
            · exact (Sync.of_eq (t := popQ k c rest s) h.2 rfl).upd (by intro y; exact ⟨rfl, rfl, rfl⟩)
        | resume t p a =>
          cases hph : (s.sd c).ph with
          | ended => exact absurd hph hne
          | live =>
            have h1 := hS1 ⟨h.1.popNp hq (fun _ => rfl) (Or.inr hph), h.2.of_eq rfl⟩
            simp only [recv]
            unfold resumeIn
            simpa [hph] using h1
          | recon =>
            have hro : (s.sd c).rsOpen = true := by
              have := (hi.reconDc c k (by simpa [cs_apply] using hph) hk').2; simpa [cs_apply] using this
            have hres : (s.sd c).res = true := hor c (hQ.reconOk c hph)
            have hlog : ¬ (s.sd c).sent > t + LOG := by
              have hm : Msg.resume t p a ∈ inbC s.cs s.ch c k := by unfold inbC; rw [hq]; simp
              have ht := hi.resT c k t p a hm (by simpa [cs_apply] using hph) hc
              have h1 := hi.win c
              have h2 := hi.rxLe c
              have h3 := hi.win c.other
              simp only [cs_apply, core_sent, core_rx] at ht h1 h2 h3
              simp only [W, LOG] at *; omega
            have hrs : (s.sd c).rsPc = some k := by
              have := (hi.reconDc c k (by simpa [cs_apply] using hph) hk').1; simpa [cs_apply] using this
            simp only [recv]
            unfold resumeIn
            dsimp only
            rw [if_neg (by simp [hph, hres, hro]), if_neg (by simpa using hlog)]
            have hV := h.1.resumed (V := updS c (fun y => { y with ph := .live, rsPc := none })
              (updS c (fun y => { y with reg := Reg.base (finalPause y.fP y.fA p a) })
                (updS c (fun y => { y with lastMsg := (popQ k c rest s).now }) (popQ k c rest s))))
              hi hp hq hph hd (by simp [Side.sv, hd]) (by simp [hearly']) (by simp) rfl
            refine SInv.pauseAfter hfix (k := k) hV.sendAll_frames ?_ ?_ ?_ ?_ ?_ ?_ ?_
            · simp [sendAll_sd]
            · simp [sendAll_sd, hd]
            · simp [sendAll_sd]
            · rw [sendAll_closed]; simp only [updS_ch, popQ_closed]; exact (hi.hold c k hc).2
            · intro j hj
              have hj' : hdC s.cs c.other j := by simpa [hdC, cs_apply, sendAll_sd] using hj
              exact (hi.same c k j hc hj').symm
            · simp [sendAll_sd]
            · intro hl; simp only [sendAll_sd, updS_sd_other, popQ_sd] at hl ⊢; exact h.2 _ hl
      · split
        · rename_i hd hrs
          exact ⟨h.1.earlyPush hq (by simpa using hrs),
            (Sync.of_eq (t := popQ k c rest s) h.2 rfl).upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
        · rename_i hd hrs
          have hn : ¬ hdC s.cs c k := by
            intro hc; rcases hc with hc | hc
            · exact hd (by simpa [cs_apply] using hc)
            · exact hrs (by simpa [cs_apply] using hc)
          exact ⟨h.1.popOut hn, h.2.of_eq rfl⟩

theorem SInv.onDeliverN {cfg : Cfg} (hseq : cfg.seq = true) (hfix : cfg.fix = true)
    (hearly : cfg.early = true) {c : Cl} {k : Nat} (n : Nat) :
    ∀ {s : State}, Inv s → PInv s → QInv s → OkRes s → SInv s → SInv (deliverN cfg c k n s) := by
  induction n with
  | zero => intro s _ _ _ _ h; exact h
  | succ n ih =>
    intro s hi hp hQ hor h
    exact ih hi.deliver (hp.deliver hfix hi) (QStep.deliver hQ).inv hor.deliver
      (h.onDeliver hseq hfix hearly hi hp hQ hor)

/-- `rsAdopt` up to the replay: the RESUME is the first thing on the new
    channel, and c's flags are recorded. -/
theorem SInv.adoptPrefix {s : State} {c : Cl} {k : Nat} (hi : Inv s) (h : SInv s)
    (hr : (s.sd c).ph = .recon) (hro : (s.sd c).rsOpen = false) (hrs : (s.sd c).rsPc = some k)
    (hdead : (s.ch k).dead = false) :
    SInv (send c (.resume (s.sd c).rx (s.sd c).paused (s.sd c).away) (updS c (openSide k)
      (updCh k (fun y => { y with q := fun d => if d = c then (s.sd c).early ++ y.q d else y.q d }) s))) := by
  have hr' : (s.cs c).ph = .recon := by simpa [cs_apply] using hr
  have hrs' : (s.cs c).rsPc = some k := by simpa [cs_apply] using hrs
  have hdn : (s.sd c).dc = none := by
    cases hd : (s.sd c).dc with
    | none => rfl
    | some j =>
      have := (hi.reconDc c j hr' (by simpa [cs_apply] using hd)).2; simp [cs_apply, hro] at this
  have hc : hdC s.cs c k := Or.inr hrs'
  have hsil : inbC s.cs s.ch c.other k = [] := hi.silent c k hc (by simp [cs_apply, hdn])
  have hnl : ¬ ((s.sd c.other).ph = .live ∧ (s.sd c.other).dc = some k) := by
    intro ⟨hl, hd⟩
    have := hi.liveOpen c.other k (by simpa [cs_apply] using hl) (by simpa [cs_apply] using hd)
      (by simpa using hc)
    simp [cs_apply, hdn] at this
  generalize hS1 : updS c (openSide k) (updCh k (fun y => { y with q := fun d => if d = c then (s.sd c).early ++ y.q d else y.q d }) s) = S1
  have s1c : S1.sd c = openSide k (s.sd c) := by rw [← hS1, updS_sd_self]; rfl
  have s1o : S1.sd c.other = s.sd c.other := by rw [← hS1, updS_sd_other]; rfl
  have s1q : ∀ j e, (S1.ch j).q e = if j = k ∧ e = c then (s.sd c).early ++ (s.ch j).q e else (s.ch j).q e := by
    intro j e; rw [← hS1]; simp only [updS_ch, updCh_ch]
    by_cases hj : j = k <;> by_cases he : e = c <;> simp [hj, he]
  have s1d : ∀ j, (S1.ch j).dead = (s.ch j).dead := by
    intro j; rw [← hS1]; simp only [updS_ch, updCh_ch]; split <;> rfl
  have s1cl : ∀ j, (S1.ch j).closed = (s.ch j).closed := by
    intro j; rw [← hS1]; simp only [updS_ch, updCh_ch]; split <;> rfl
  have hsend : send c (.resume (s.sd c).rx (s.sd c).paused (s.sd c).away) S1 =
      appendQ k c.other [.resume (s.sd c).rx (s.sd c).paused (s.sd c).away] S1 := by
    have hcl : (s.ch k).closed c = false := (hi.hold c k hc).2
    simp only [send, s1c, openSide_dc, s1d, s1cl, hcl, hdead, Bool.or_false, Bool.false_eq_true, if_false]; rfl
  rw [hsend]
  generalize hA : appendQ k c.other [.resume (s.sd c).rx (s.sd c).paused (s.sd c).away] S1 = A
  have Ac : A.sd c = openSide k (s.sd c) := by rw [← hA, appendQ_sd, s1c]
  have Ao : A.sd c.other = s.sd c.other := by rw [← hA, appendQ_sd, s1o]
  have Ad : ∀ j, (A.ch j).dead = (s.ch j).dead := by intro j; rw [← hA, appendQ_dead, s1d]
  have hcj : ∀ j, hdC A.cs c j → j = k := by
    intro j hj; simp [hdC, cs_apply, Ac, openSide] at hj
    rcases hj with hj | hj
    · exact hj.symm
    · rw [hrs] at hj; exact (Option.some.inj hj).symm
  have hoj : ∀ j, hdC A.cs c.other j ↔ hdC s.cs c.other j := by intro j; simp [hdC, cs_apply, Ao]
  have inbc : ∀ j, inbC A.cs A.ch c j = inbC s.cs s.ch c j := by
    intro j; unfold inbC
    rw [← hA, appendQ_cs, appendQ_q, s1q]
    simp only [Cl.ne_other, and_false, if_false, cs_apply, core_rsPc, core_early, appendQ_sd, s1c, openSide_rsPc,
      openSide_early]
    by_cases hj : j = k
    · subst hj; simp [hrs]
    · have hne : (s.sd c).rsPc ≠ some j := by rw [hrs]; intro h'; exact hj (Option.some.inj h').symm
      simp [hj, hne]
  have inbo : ∀ j, inbC A.cs A.ch c.other j =
      if j = k then [.resume (s.sd c).rx (s.sd c).paused (s.sd c).away] else inbC s.cs s.ch c.other j := by
    intro j; unfold inbC
    rw [← hA, appendQ_cs, appendQ_q, s1q]
    simp only [cs_apply, core_rsPc, core_early, appendQ_sd, s1o, Cl.other_ne, and_false, if_false]
    have hsil' : (if (s.sd c.other).rsPc = some k then (s.sd c.other).early else []) ++
        (s.ch k).q c.other = [] := hsil
    by_cases hj : j = k
    · subst hj; simp only [and_self, if_true]; rw [← List.append_assoc, hsil']; rfl
    · simp only [hj, false_and, if_false]; rfl
  have pqc : ∀ j, pq A c j = pq s c j := by intro j; simp only [pq, pqC, inbc]
  have pqo : ∀ j, pq A c.other j = if j = k then [] else pq s c.other j := by
    intro j; simp only [pq, pqC, inbo]; split <;> simp [Msg.press?]
  refine ⟨⟨fun e j hre hc' ho => ?_, fun e j hj hre ho hd => ?_, fun e j hre hc' hp => ?_,
    fun e j hl hj hre ho hd => ?_, fun e j hl ho hj hjo hd => ?_⟩, Sync.mk (c := c) h.2 Ao ?_⟩
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [hcj j hc', pqo]; simp
    · simp only [Cl.other_other] at ho ⊢; rw [hcj j ho] at hc' ⊢; rw [Ao] at hre; rw [hoj] at hc'
      rw [pqc]; simpa using h.1.quiet _ k hre hc' (by simpa using hc)
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [Ac, openSide_dc] at hj; cases hj; rw [inbo]; simp [resHead]
    · simp only [Cl.other_other] at hre ho ⊢; rw [hcj j ho] at hj hd ⊢; rw [Ao] at hj; rw [Ad] at hd
      rw [inbc]; rw [Ac] at hre; simpa using h.1.head _ k hj (by simpa using hre) (by simpa using hc) hd
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [hcj j hc'] at hp ⊢; rw [pqc] at hp; rw [inbc]; rw [Ac] at hre
      exact h.1.head2 _ k (by simpa using hre) hc hp
    · rw [Ao] at hre; rw [hoj] at hc'
      by_cases hjk : j = k
      · rw [pqo, if_pos hjk] at hp; exact absurd rfl hp
      · rw [pqo, if_neg hjk] at hp; rw [inbo, if_neg hjk]; exact h.1.head2 _ j hre hc' hp
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [Ac] at hl; simp [openSide, hr] at hl
    · simp only [Cl.other_other] at hre ho; rw [hcj j ho] at hj; rw [Ao] at hl hj
      exact absurd ⟨hl, hj⟩ hnl
  · rcases Cl.eq_or c e with rfl | rfl
    · rw [Ac] at hl; simp [openSide, hr] at hl
    · simp only [Cl.other_other] at ho; rw [Ac] at ho; simp [openSide, hr] at ho
  · intro hl; rw [Ac] at hl; simp [openSide, hr] at hl

theorem SInv.onAdopt {cfg : Cfg} (hseq : cfg.seq = true) (hfix : cfg.fix = true) (hearly : cfg.early = true)
    {s : State} {c : Cl} (hi : Inv s) (hp : PInv s) (hQ : QInv s) (hor : OkRes s) (h : SInv s)
    (hen : en cfg s (.adopt c) = true) : SInv (adopt cfg c s) := by
  simp only [en, Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true'] at hen
  obtain ⟨⟨hr, hro⟩, hk⟩ := hen
  unfold LinkResume.adopt
  split
  · exact h
  · rename_i k hrs
    rw [hrs] at hk
    simp only [Bool.not_eq_true'] at hk
    refine SInv.onDeliverN hseq hfix hearly _ (hi.adoptPrefix hr hro hrs hk (fun y => rfl) rfl)
      (hp.adoptPrefix hi hr hro hrs hk rfl) (QStep.adoptPrefix (k := k) hQ hr).inv ?_
      (SInv.adoptPrefix hi h hr hro hrs hk)
    exact hor.of ((SameOR.of_sd rfl).trans ((SameOR.updS _ c (by intro y; exact ⟨rfl, rfl⟩)).trans
      (SameOR.send _ c _)))

/-- `setPaused(p, relay)` with the relay: a press if live. -/
theorem SInv.onSetPaused {s : State} {c : Cl} {p : Bool} (hi : Inv s) (h : SInv s) :
    SInv (setPaused c p true s) := by
  unfold LinkResume.setPaused
  split
  · exact h
  · dsimp only
    have h1 : SCore (updS c (fun y => { y with paused := p, pfb := false }) s) :=
      h.1.updS_nv (by intro y; rfl) (by intro y; rfl)
    split
    · rename_i hl
      have hl' : (s.sd c).ph = .live := by simpa using hl
      have hls := hi.liveSh c (by simpa [cs_apply] using hl')
      obtain ⟨k, hk⟩ : ∃ k, (s.sd c).dc = some k := by
        cases hd : (s.sd c).dc with
        | none => exact absurd (by simpa [cs_apply] using hd) hls.2
        | some k => exact ⟨k, rfl⟩
      have hrs : (s.sd c).rsPc = none := by simpa [cs_apply] using hls.1
      have hc : hdC s.cs c k := Or.inl (by simpa [cs_apply] using hk)
      refine ⟨h1.onPress (by simpa using hl') (by simpa using hk) (by simpa using hrs)
        (by simpa using (hi.hold c k hc).2)
        (fun j hj => (hi.same c k j hc (by simpa [hdC, cs_apply] using hj)).symm), ?_⟩
      exact Sync.mk (c := c) h.2 (by simp [LinkResume.press, send_sd]) (fun _ => by
        simp [LinkResume.press, send_sd])
    · rename_i hl
      refine ⟨h1, Sync.mk (c := c) h.2 (by simp) (fun hl2 => ?_)⟩
      simp at hl2 hl; exact absurd hl2 hl

theorem SInv.onSetAway {s : State} {cfg : Cfg} {c : Cl} {on : Bool} (hi : Inv s) (h : SInv s) :
    SInv (setAway cfg c on s) := by
  unfold LinkResume.setAway
  have h1 : SInv (updS c (fun y => { y with away := on, livePress := y.livePress || y.ph == .live }) s) :=
    ⟨h.1.updS_nv (by intro y; rfl) (by intro y; rfl), h.2.upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
  have hi1 : Inv (updS c (fun y => { y with away := on, livePress := y.livePress || y.ph == .live }) s) :=
    hi.updS_noncore (fun y => rfl)
  dsimp only
  split
  · exact h1
  · split
    · split
      · exact h1
      · have h2 := SInv.onSetPaused (c := c) (p := true) hi1 h1
        exact ⟨h2.1.updS_nv (by intro y; rfl) (by intro y; rfl), h2.2.upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
    · split
      · have hi2 : Inv (updS c (fun y => { y with pfb := false })
            (updS c (fun y => { y with away := on, livePress := y.livePress || y.ph == .live }) s)) :=
          hi1.updS_noncore (fun y => rfl)
        have h2 : SInv (updS c (fun y => { y with pfb := false })
            (updS c (fun y => { y with away := on, livePress := y.livePress || y.ph == .live }) s)) :=
          ⟨h1.1.updS_nv (by intro y; rfl) (by intro y; rfl), h1.2.upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
        exact SInv.onSetPaused hi2 h2
      · exact h1

theorem resHead_pre {pre l : List Msg} (h : resHead (pre ++ l) = true) (hp : pre ≠ []) :
    resHead pre = true := by
  cases pre with
  | nil => exact absurd rfl hp
  | cons x xs => simp only [List.cons_append] at h; rw [resHead_cons] at h ⊢; exact h

theorem SInv.onDie {s : State} {k : Nat} (h : SInv s) :
    SInv (updCh k (fun x => { x with dead := true, q := fun _ => [] }) s) := by
  generalize hT : updCh k (fun x => { x with dead := true, q := fun _ => [] }) s = T
  have Tsd : T.sd = s.sd := by rw [← hT]; rfl
  have Tcs : T.cs = s.cs := by rw [← hT]; rfl
  have Tdead : ∀ j, (T.ch j).dead = if j = k then true else (s.ch j).dead := by
    intro j; rw [← hT]; simp only [updCh_ch]; split <;> rfl
  have Tinb : ∀ e j, inbC T.cs T.ch e j = if j = k then (if (s.cs e).rsPc = some j then (s.cs e).early else [])
      else inbC s.cs s.ch e j := by
    intro e j; unfold inbC; rw [Tcs, ← hT]; simp only [updCh_ch]; by_cases hj : j = k <;> simp [hj] <;> rfl
  have hpre : ∀ e, inbC s.cs s.ch e k = (if (s.cs e).rsPc = some k then (s.cs e).early else []) ++ (s.ch k).q e :=
    fun e => rfl
  have Tpq : ∀ e j, j ≠ k → pq T e j = pq s e j := by
    intro e j hj; simp only [pq, pqC, Tinb, hj, if_false]
  have Tpqk : ∀ e, pq s e k = [] → pq T e k = [] := by
    intro e he; simp only [pq, pqC, Tinb, if_true] at he ⊢
    rw [hpre, List.filterMap_append, List.append_eq_nil_iff] at he; exact he.1
  have Thd : ∀ e j, hdC T.cs e j ↔ hdC s.cs e j := by intro e j; rw [Tcs]
  refine ⟨⟨fun e j hre hc ho => ?_, fun e j hj hre ho hd => ?_, fun e j hre hc hp => ?_,
    fun e j hl hj hre ho hd => ?_, fun e j hl ho hj hjo hd => ?_⟩, h.2.of_eq Tsd⟩
  · rw [Thd] at hc ho; rw [Tsd] at hre
    by_cases hjk : j = k
    · subst hjk; exact Tpqk _ (h.1.quiet e _ hre hc ho)
    · rw [Tpq _ _ hjk]; exact h.1.quiet e j hre hc ho
  · rw [Tdead] at hd; split at hd
    · cases hd
    · rename_i hjk; rw [Tinb, if_neg hjk]; rw [Thd] at ho; rw [Tsd] at hj hre
      exact h.1.head e j hj hre ho hd
  · rw [Thd] at hc; rw [Tsd] at hre
    by_cases hjk : j = k
    · subst hjk
      have hp' : pq s e j ≠ [] := by
        intro he; exact hp (Tpqk _ he)
      have hrh := h.1.head2 e j hre hc hp'
      rw [Tinb, if_pos rfl]
      rw [hpre] at hrh
      refine resHead_pre hrh ?_
      intro hnil; apply hp; simp only [pq, pqC, Tinb, if_true, hnil]; rfl
    · rw [Tpq _ _ hjk] at hp; rw [Tinb, if_neg hjk]; exact h.1.head2 e j hre hc hp
  · rw [Tdead] at hd; split at hd
    · cases hd
    · rename_i hjk; rw [Thd] at ho; rw [Tsd] at hl hj hre ⊢; rw [Tpq _ _ hjk]
      exact h.1.half e j hl hj hre ho hd
  · rw [Tdead] at hd; split at hd
    · cases hd
    · rename_i hjk; rw [Tsd] at hl ho hj hjo ⊢; rw [Tpq _ _ hjk, Tpq _ _ hjk]
      exact h.1.conv e j hl ho hj hjo hd

theorem sinit : SInv init := by
  have hq : ∀ c k, pq init c k = [] := by
    intro c k; unfold pq pqC inbC
    by_cases hk : k = 0
    · subst hk; cases c <;> simp [init, cs_apply, Msg.press?]
    · cases c <;> simp [init, cs_apply, hk]
  have hl : ∀ c, (init.sd c).ph = .live := by intro c; cases c <;> rfl
  refine ⟨⟨fun c k hr => ?_, fun c k _ hr => ?_, fun c k hr => ?_, fun c k _ _ hr => ?_,
    fun c k _ _ _ _ _ => ?_⟩, fun c _ => ?_⟩
  · rw [hl] at hr; cases hr
  · rw [hl] at hr; cases hr
  · rw [hl] at hr; cases hr
  · rw [hl] at hr; cases hr
  · rw [hq, hq]; cases c <;> rfl
  · cases c <;> rfl

theorem SInv.step {cfg : Cfg} (hseq : cfg.seq = true) (hfix : cfg.fix = true) (hearly : cfg.early = true)
    {s : State} (hi : Inv s) (hp : PInv s) (hQ : QInv s) (hor : OkRes s) (h : SInv s) (e : Event)
    (hen : en cfg s e = true) : SInv (step cfg s e) := by
  cases e with
  | input c =>
    simp only [LinkResume.step]
    have h1 : SInv (updS c (fun y => { y with sent := (s.sd c).sent + 1 }) s) :=
      ⟨h.1.updS_nv (by intro y; rfl) (by intro y; rfl), h.2.upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
    split
    · exact ⟨h1.1.send_np (fun _ => rfl), h1.2.of_eq (send_sd ..)⟩
    · exact h1
  | deliver c k => exact h.onDeliver hseq hfix hearly hi hp hQ hor
  | die k => exact h.onDie
  | dropped c => exact h.onDropped
  | pair => exact h.onPair hi hen
  | adopt c => exact h.onAdopt hseq hfix hearly hi hp hQ hor hen
  | restart c => exact h.onRestart
  | giveUp c => exact h.onShutdown
  | quit c => exact h.onShutdown
  | kill c => exact ⟨h.1.onFinish, h.2.onFinish⟩
  | toggle c =>
    simp only [LinkResume.step]
    exact SInv.onSetPaused (hi.updS_noncore (fun y => rfl))
      ⟨h.1.updS_nv (by intro y; rfl) (by intro y; rfl), h.2.upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
  | away c on => exact h.onSetAway hi
  | tick n => exact ⟨h.1.of_eq rfl rfl, h.2.of_eq rfl⟩
  | ping c => exact ⟨h.1.send_np (fun _ => rfl), h.2.of_eq (send_sd ..)⟩
  | noteIn c =>
    simp only [LinkResume.step]
    split
    · exact SInv.onShutdown ⟨h.1.updS_nv (by intro y; rfl) (by intro y; rfl),
        h.2.upd (by intro y; exact ⟨rfl, rfl, rfl⟩)⟩
    · exact h

theorem sinv_reachable {cfg : Cfg} (hseq : cfg.seq = true) (hfix : cfg.fix = true)
    (hearly : cfg.early = true) {s : State} (h : Reachable cfg s) : SInv s := by
  induction h with
  | init => exact sinit
  | step e hr hen ih =>
    exact ih.step hseq hfix hearly (inv_reachable hr) (pinv_reachable hfix hr) (qinv_reachable hr)
      (okres_reachable hr) e hen

/-- **With numbered presses, both sides agree on pause once no press is on
    its way.** Both live on the same working channel, nothing pressed in
    flight either way: both paused or both running, whatever presses
    crossed before, on a live link or across resumes. (Stronger: they will
    hold the same press, `SCore.conv`, at every moment.) `bug_pause_presses_cross`
    shows the code without the numbers splits. -/
theorem presses_agree {cfg : Cfg} (hseq : cfg.seq = true) (hfix : cfg.fix = true)
    (hearly : cfg.early = true) {s : State} (h : Reachable cfg s) {k : Nat}
    (ha : (s.sd .a).ph = .live) (hb : (s.sd .b).ph = .live)
    (hka : (s.sd .a).dc = some k) (hkb : (s.sd .b).dc = some k) (hd : (s.ch k).dead = false)
    (hqa : pq s .a k = []) (hqb : pq s .b k = []) :
    (s.sd .a).paused = (s.sd .b).paused := by
  have hs := sinv_reachable hseq hfix hearly h
  have := hs.1.conv .a k ha hb hka hkb hd
  simp only [Cl.other, hqa, hqb, settle_nil] at this
  rw [hs.2 .a ha, hs.2 .b hb, this]


end WebState.LinkResume
