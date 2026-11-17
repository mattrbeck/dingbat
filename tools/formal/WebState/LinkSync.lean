-- What this models, for tools/formal/anchors.mjs (which lists stale models):
-- @models web/netplay.js: rbSessionGen rbSyncPoll rbSyncCompare rbResyncBegin rbAtBarrier rbResyncStep rbResyncApply rbSyncMessage rbOnFrame rbDropped
-- (ios/Dingbat/Sources/NetLink.swift "sync checks" is the same protocol, method for method.)

/-
# Sync checks on an online link (web/netplay.js "Sync checks"; iOS NetLink)

Both sides of an online link run both games, and only inputs cross, so two
builds whose cores differ can drift apart in silence. Every 120 frames each
side fingerprints both games (rollback.nim `sync_flush`) and the two cross
(RB_SYNC). They differ: a re-sync. Each side proposes to stop a second
ahead (RB_RESYNC), both stop at the later proposal, each sends the friend
its own game's state there (RB_RESYNC_BEGIN/CHUNK), and with the friend's
in hand each starts the session again from the two states (rollback_init
and both loads, as at the start; every frame count back to 0) and says so
(RB_RESYNC_READY). A friend whose HELLO doesn't say it checks is sent none
of this.

## What is modelled

* Two sides, A and B. Each holds its frame count (`head`), the friend's
  inputs it has (`rx`), its own game and its copy of the friend's (values:
  equal copies are equal games), the re-syncs it has finished (`gen`),
  whether the friend checks (`peerSync`, from its HELLO), the re-sync under
  way (`rs`), its fingerprint and the friend's waiting to be compared, and
  how many of the new kinds (16-20) it has sent.
* One reliable, ordered channel each way (the DataChannel is `ordered`).
* An input carries the session it was played in, a ghost field (the wire
  has none): an input fed into another session's engine is the failure
  `inputs_in_session` rules out. `stale` records one.
* `drift` changes a side's copy of the friend's game: a divergence no input
  explains (a core that differs, or a bug).
* The window: a side plays at most `W` frames past the friend's inputs
  (rollback.nim `maxAhead`).
* The barrier (`atBarrier`): during a re-sync a side plays to its stop frame
  (its own proposal until the friend's is in) and no further; once its state
  is sent it plays no more until it restarts (in the code head is then
  target + 1, past the stop, and the friend's one RESYNC is already in).

## Abstractions

* Fingerprints are of the two game values when taken, not of a numbered
  frame: both sides take them at the same confirmed frame in the code,
  which a value model can't name; a drift between two sides' takes shows as
  a difference, as a drift before that frame would.
* A frame count is a number; what a frame does to a game is not modelled
  (both sides do the same, which is what determinism is).
* `prop` is a ghost: each side's proposal for each re-sync.

`Cfg.onReceipt` selects when a restart happens. On (the code): the moment
the friend's state is complete, if ours has gone, or the moment ours goes if
theirs is in (rbResyncStep runs at the end of every message and every
frame). Off: on a later frame of its own (`apply`), which lets the friend's
first new inputs arrive first (`stale_input_if_restart_waits`).
-/

namespace WebState.LinkSync

inductive Cl where
  | a
  | b
  deriving DecidableEq, Repr

def Cl.other : Cl → Cl
  | .a => .b
  | .b => .a

@[simp] theorem Cl.other_other (c : Cl) : c.other.other = c := by cases c <;> rfl
@[simp] theorem Cl.other_ne (c : Cl) : c.other ≠ c := by cases c <;> decide
@[simp] theorem Cl.ne_other (c : Cl) : c ≠ c.other := by cases c <;> decide

/-- The window: at most this many frames past the friend's inputs. -/
def W : Nat := 3
/-- How far ahead a re-sync proposes to stop (RB_RESYNC_MARGIN, 60 frames). -/
def M : Nat := 2

inductive Msg where
  | inp (ep : Nat)          -- RB_INPUT; `ep` the session it was played in (ghost)
  | sync (g v0 v1 : Nat)    -- RB_SYNC: session g's fingerprint of game 0 and game 1
  | resync (g t : Nat)      -- RB_RESYNC: re-sync g, stop at frame t
  | state (g v : Nat)       -- RB_RESYNC_BEGIN/CHUNK: the sender's own game
  | ready (g : Nat)         -- RB_RESYNC_READY
  deriving DecidableEq, Repr

structure Rs where
  gen : Nat
  mineT : Nat
  target : Option Nat
  sent : Bool
  got : Option Nat
  applied : Bool
  friendReady : Bool
  deriving DecidableEq, Repr

structure Side where
  head : Nat
  rx : Nat
  own : Nat
  copy : Nat
  gen : Nat
  peerSync : Bool
  rs : Option Rs
  fp : Option (Nat × Nat)
  tfp : Option (Nat × Nat)
  newSent : Nat
  drifted : Bool
  stale : Bool
  deriving DecidableEq, Repr

structure State where
  sd : Cl → Side
  /-- On the way to each side, oldest first. -/
  ch : Cl → List Msg
  /-- Ghost: each side's proposal for each re-sync. -/
  prop : Cl → Nat → Option Nat

structure Cfg where
  onReceipt : Bool
  deriving DecidableEq, Repr

def Cfg.code : Cfg := ⟨true⟩
def Cfg.waits : Cfg := ⟨false⟩

/-- The session a side's engine is in (rbSessionGen): a re-sync's once it
    has restarted. -/
def sess (x : Side) : Nat :=
  match x.rs with
  | some r => if r.applied then r.gen else x.gen
  | none => x.gen

def limit (r : Rs) : Nat := r.target.getD r.mineT

/-- rbAtBarrier: no frame past the stop (or our own proposal), none once our
    state is out, until the restart. -/
def atBarrier (x : Side) : Bool :=
  match x.rs with
  | some r => !r.applied && (r.sent || decide (limit r < x.head))
  | none => false

/-- Game 0 is the host's (A's), game 1 the guest's. -/
def fpOf (c : Cl) (x : Side) : Nat × Nat :=
  match c with
  | .a => (x.own, x.copy)
  | .b => (x.copy, x.own)

def mkSide (own copy : Nat) (peerSync : Bool) : Side :=
  ⟨0, 0, own, copy, 0, peerSync, none, none, none, 0, false, false⟩

/-- A link in step: each side's copy of the friend's game is the friend's. -/
def init (pa pb : Bool) : State where
  sd := fun c => match c with
    | .a => mkSide 1 2 pa
    | .b => mkSide 2 1 pb
  ch := fun _ => []
  prop := fun _ _ => none

def updS (c : Cl) (f : Side → Side) (s : State) : State :=
  { s with sd := fun d => if d = c then f (s.sd d) else s.sd d }

/-- `c` sends `m` (it goes on the way to c.other). -/
def send (c : Cl) (m : Msg) (s : State) : State :=
  { s with ch := fun d => if d = c.other then s.ch d ++ [m] else s.ch d }

/-- One of the new kinds (16-20). -/
def sendNew (c : Cl) (m : Msg) (s : State) : State :=
  updS c (fun x => { x with newSent := x.newSent + 1 }) (send c m s)

/-- rbResyncBegin: propose to stop M frames ahead. -/
def begin (c : Cl) (s : State) : State :=
  let x := s.sd c
  if x.rs.isNone && x.peerSync then
    let g := x.gen + 1
    let t := x.head + M
    let s := updS c (fun x => { x with rs := some ⟨g, t, none, false, none, false, false⟩ }) s
    let s := { s with prop := fun d h => if d = c ∧ h = g then some t else s.prop d h }
    sendNew c (.resync g t) s
  else s

/-- rbSyncCompare: both fingerprints in hand; they differ: a re-sync. -/
def compare (c : Cl) (s : State) : State :=
  let x := s.sd c
  match x.fp, x.tfp with
  | some p, some q =>
    let s := updS c (fun x => { x with fp := none, tfp := none }) s
    if p = q then s else begin c s
  | _, _ => s

/-- rbResyncApply: start again from both states; frame counts back to 0. -/
def doApply (c : Cl) (s : State) : State :=
  match (s.sd c).rs with
  | some r =>
    match r.got with
    | some v =>
      if r.sent && !r.applied then
        let s := updS c (fun x => { x with copy := v, head := 0, rx := 0, drifted := false }) s
        let s := updS c (fun x => { x with fp := none, tfp := none, rs := some { r with applied := true } }) s
        sendNew c (.ready r.gen) s
      else s
    | none => s
  | none => s

def comparing (x : Side) : Bool :=
  match x.rs with
  | some r => r.applied
  | none => true

/-- What `c` does with one message (rbMessage / rbSyncMessage). -/
def recv (cfg : Cfg) (c : Cl) (m : Msg) (s : State) : State :=
  match m with
  | .inp ep => updS c (fun x => { x with rx := x.rx + 1, stale := x.stale || decide (ep ≠ sess x) }) s
  | .sync g v0 v1 =>
    if g = sess (s.sd c) && comparing (s.sd c) then
      compare c (updS c (fun x => { x with tfp := some (v0, v1) }) s)
    else s
  | .resync g t =>
    let s := if (s.sd c).rs.isNone && g = (s.sd c).gen + 1 then begin c s else s
    match (s.sd c).rs with
    | some r =>
      -- The friend sends one RESYNC a re-sync: the stop is set once.
      if r.gen = g ∧ ¬r.applied ∧ r.target = none then
        updS c (fun x => { x with rs := some { r with target := some (max r.mineT t) } }) s
      else s
    | none => s
  | .state g v =>
    match (s.sd c).rs with
    | some r =>
      if r.gen = g then
        let s := updS c (fun x => { x with rs := some { r with got := some v } }) s
        if cfg.onReceipt then doApply c s else s
      else s
    | none => s
  | .ready g =>
    match (s.sd c).rs with
    | some r => if r.gen = g then updS c (fun x => { x with rs := some { r with friendReady := true } }) s else s
    | none => s

inductive Event where
  | tick (c : Cl)        -- one frame, its input sent
  | check (c : Cl)       -- a fingerprint, sent to a checking friend
  | deliver (c : Cl)     -- the oldest message on the way to c
  | sendState (c : Cl)   -- at the stop frame with every input to it: our own game
  | apply (c : Cl)       -- the restart on a later frame (Cfg.waits only)
  | finish (c : Cl)      -- the friend has restarted too
  | drift (c : Cl)       -- this side's copy of the friend's game goes its own way
  deriving DecidableEq, Repr

def readyToSend (x : Side) : Bool :=
  match x.rs with
  | some r =>
    match r.target with
    | some t => !r.sent && decide (x.head = t + 1) && decide (t + 1 ≤ x.rx)
    | none => false
  | none => false

def en (cfg : Cfg) (s : State) : Event → Bool
  | .tick c => !atBarrier (s.sd c) && decide ((s.sd c).head < (s.sd c).rx + W)
  | .check c => comparing (s.sd c) && (s.sd c).fp.isNone
  | .deliver c => !(s.ch c).isEmpty
  | .sendState c => readyToSend (s.sd c)
  | .apply c =>
    !cfg.onReceipt &&
    match (s.sd c).rs with
    | some r => r.sent && !r.applied && r.got.isSome
    | none => false
  | .finish c =>
    match (s.sd c).rs with
    | some r => r.applied && r.friendReady
    | none => false
  | .drift _ => true

def step (cfg : Cfg) (s : State) : Event → State
  | .tick c =>
    let x := s.sd c
    send c (.inp (sess x)) (updS c (fun x => { x with head := x.head + 1 }) s)
  | .check c =>
    let x := s.sd c
    let s := updS c (fun x => { x with fp := some (fpOf c x) }) s
    let s := if x.peerSync then sendNew c (.sync (sess x) (fpOf c x).1 (fpOf c x).2) s else s
    compare c s
  | .deliver c =>
    match s.ch c with
    | m :: rest => recv cfg c m { s with ch := fun d => if d = c then rest else s.ch d }
    | [] => s
  | .sendState c =>
    match (s.sd c).rs with
    | some r =>
      let s := updS c (fun x => { x with rs := some { r with sent := true } }) s
      let s := sendNew c (.state r.gen (s.sd c).own) s
      if cfg.onReceipt then doApply c s else s
    | none => s
  | .apply c => doApply c s
  | .finish c =>
    match (s.sd c).rs with
    | some r => updS c (fun x => { x with gen := r.gen, rs := none }) s
    | none => s
  | .drift c => updS c (fun x => { x with copy := x.copy + 1, drifted := true }) s

inductive Reachable (cfg : Cfg) (pa pb : Bool) : State → Prop
  | init : Reachable cfg pa pb (init pa pb)
  | step {s : State} (e : Event) :
      Reachable cfg pa pb s → en cfg s e = true → Reachable cfg pa pb (step cfg s e)

def run (cfg : Cfg) (s : State) : List Event → Option State
  | [] => some s
  | e :: es => if en cfg s e then run cfg (step cfg s e) es else none

theorem run_reachable {cfg : Cfg} {pa pb : Bool} {s : State} (h : Reachable cfg pa pb s) :
    ∀ {es : List Event} {t : State}, run cfg s es = some t → Reachable cfg pa pb t := by
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
def witnesses (cfg : Cfg) (pa pb : Bool) (es : List Event) (p : State → Bool) : Bool :=
  match run cfg (init pa pb) es with
  | some t => p t
  | none => false

theorem witness_sound {cfg : Cfg} {pa pb : Bool} {es : List Event} {p : State → Bool}
    (h : witnesses cfg pa pb es p = true) : ∃ s, Reachable cfg pa pb s ∧ p s = true := by
  unfold witnesses at h
  split at h
  · rename_i t ht
    exact ⟨t, run_reachable Reachable.init ht, h⟩
  · cases h


/-! ## Every reachable state

Every event changes only its own side (`step_sd_other`); channels and the
ghost change only by sends. -/

@[simp] theorem updS_sd_self (c : Cl) (f : Side → Side) (s : State) : (updS c f s).sd c = f (s.sd c) := by
  simp [updS]
@[simp] theorem updS_sd_other {c d : Cl} (h : d ≠ c) (f : Side → Side) (s : State) :
    (updS c f s).sd d = s.sd d := by simp [updS, h]
@[simp] theorem updS_ch (c : Cl) (f : Side → Side) (s : State) : (updS c f s).ch = s.ch := rfl
@[simp] theorem updS_prop (c : Cl) (f : Side → Side) (s : State) : (updS c f s).prop = s.prop := rfl
@[simp] theorem send_sd (c : Cl) (m : Msg) (s : State) : (send c m s).sd = s.sd := rfl
@[simp] theorem send_prop (c : Cl) (m : Msg) (s : State) : (send c m s).prop = s.prop := rfl

/-- What the actor of an event is. -/
def Event.actor : Event → Cl
  | .tick c | .check c | .deliver c | .sendState c | .apply c | .finish c | .drift c => c

theorem begin_sd_other {c d : Cl} (h : d ≠ c) (s : State) : (begin c s).sd d = s.sd d := by
  simp only [begin]; split <;> simp [sendNew, h]
theorem compare_sd_other {c d : Cl} (h : d ≠ c) (s : State) : (compare c s).sd d = s.sd d := by
  simp only [compare]
  split
  · split
    · simp [h]
    · rw [begin_sd_other h]; simp [h]
  · rfl
theorem doApply_sd_other {c d : Cl} (h : d ≠ c) (s : State) : (doApply c s).sd d = s.sd d := by
  simp only [doApply]
  split
  · split
    · split
      · simp [sendNew, h]
      · rfl
    · rfl
  · rfl
theorem recv_sd_other (cfg : Cfg) {c d : Cl} (h : d ≠ c) (m : Msg) (s : State) :
    (recv cfg c m s).sd d = s.sd d := by
  cases m with
  | inp => simp [recv, h]
  | sync =>
    simp only [recv]
    split
    · rw [compare_sd_other h]; simp [h]
    · rfl
  | resync g t =>
    simp only [recv]
    have hb : ∀ (q : Prop) [Decidable q], (if q then begin c s else s).sd d = s.sd d := by
      intro q _
      split
      · exact begin_sd_other h s
      · rfl
    split
    · split
      · simp [h]; exact hb _
      · exact hb _
    · exact hb _
  | state =>
    simp only [recv]
    split
    · split
      · split
        · rw [doApply_sd_other h]; simp [h]
        · simp [h]
      · rfl
    · rfl
  | ready =>
    simp only [recv]
    split
    · split
      · simp [h]
      · rfl
    · rfl

theorem step_sd_other (cfg : Cfg) (s : State) (e : Event) {d : Cl} (h : d ≠ e.actor) :
    (step cfg s e).sd d = s.sd d := by
  cases e with
  | tick c => simp [step, Event.actor] at h ⊢; simp [h]
  | check c =>
    simp only [step, Event.actor] at h ⊢
    rw [compare_sd_other h]; split <;> simp [sendNew, h]
  | deliver c =>
    simp only [step, Event.actor] at h ⊢
    split
    · rw [recv_sd_other cfg h]
    · rfl
  | sendState c =>
    simp only [step, Event.actor] at h ⊢
    split
    · split <;> simp [doApply_sd_other, sendNew, h]
    · rfl
  | apply c => simp only [step, Event.actor] at h ⊢; exact doApply_sd_other h s
  | finish c => simp only [step, Event.actor] at h ⊢; split <;> simp [h]
  | drift c => simp [step, Event.actor] at h ⊢; simp [h]


/-! ### An older friend is sent nothing new, and no one's own game changes -/

structure Good (o : Nat) (p : Bool) (x : Side) : Prop where
  own : x.own = o
  ps : x.peerSync = p
  quiet : x.peerSync = false → x.newSent = 0 ∧ x.rs = none

theorem good_begin {o p} (c : Cl) (s : State) (h : Good o p (s.sd c)) : Good o p ((begin c s).sd c) := by
  simp only [begin]
  split
  · rename_i hg
    simp only [Bool.and_eq_true] at hg
    simp [sendNew]
    exact ⟨h.own, h.ps, by simp [hg.2]⟩
  · exact h

theorem good_compare {o p} (c : Cl) (s : State) (h : Good o p (s.sd c)) : Good o p ((compare c s).sd c) := by
  simp only [compare]
  split
  · have h' : Good o p ((updS c (fun x => { x with fp := none, tfp := none }) s).sd c) := by
      simp; exact ⟨h.own, h.ps, h.quiet⟩
    split
    · exact h'
    · exact good_begin c _ h'
  · exact h

theorem good_doApply {o p} (c : Cl) (s : State) (h : Good o p (s.sd c)) : Good o p ((doApply c s).sd c) := by
  simp only [doApply]
  split
  · rename_i r hr
    split
    · split
      · simp [sendNew]
        refine ⟨h.own, h.ps, fun hp => ?_⟩
        have := (h.quiet hp).2; rw [hr] at this; cases this
      · exact h
    · exact h
  · exact h

theorem good_recv {o p} (cfg : Cfg) (c : Cl) (m : Msg) (s : State) (h : Good o p (s.sd c)) :
    Good o p ((recv cfg c m s).sd c) := by
  cases m with
  | inp => simp [recv]; exact ⟨h.own, h.ps, h.quiet⟩
  | sync =>
    simp only [recv]
    split
    · exact good_compare c _ (by simp; exact ⟨h.own, h.ps, h.quiet⟩)
    · exact h
  | resync g t =>
    simp only [recv]
    have hb : ∀ (q : Prop) [Decidable q], Good o p ((if q then begin c s else s).sd c) := by
      intro q _; split
      · exact good_begin c s h
      · exact h
    split
    · rename_i r hr
      split
      · simp
        have hg := hb ((s.sd c).rs = none ∧ g = (s.sd c).gen + 1)
        refine ⟨hg.own, hg.ps, fun hp => ?_⟩
        have := (hg.quiet hp).2
        simp_all
      · exact hb _
    · exact hb _
  | state g v =>
    simp only [recv]
    split
    · rename_i r hr
      have h' : Good o p ((updS c (fun x => { x with rs := some { r with got := some v } }) s).sd c) := by
        simp
        refine ⟨h.own, h.ps, fun hp => ?_⟩
        have := (h.quiet hp).2; rw [hr] at this; cases this
      split
      · split
        · exact good_doApply c _ h'
        · exact h'
      · exact h
    · exact h
  | ready =>
    simp only [recv]
    split
    · rename_i r hr
      split
      · simp
        refine ⟨h.own, h.ps, fun hp => ?_⟩
        have := (h.quiet hp).2; rw [hr] at this; cases this
      · exact h
    · exact h


theorem good_step {o p} (cfg : Cfg) (s : State) (e : Event) (hen : en cfg s e = true)
    (h : Good o p (s.sd e.actor)) : Good o p ((step cfg s e).sd e.actor) := by
  cases e with
  | tick c => simp [step, Event.actor] at h ⊢; exact ⟨h.own, h.ps, h.quiet⟩
  | check c =>
    simp only [step, Event.actor] at h ⊢
    apply good_compare
    split
    · rename_i hp
      simp [sendNew]; exact ⟨h.own, h.ps, by simp [hp]⟩
    · simp; exact ⟨h.own, h.ps, h.quiet⟩
  | deliver c =>
    simp only [step, Event.actor] at h ⊢
    split
    · exact good_recv cfg c _ _ (by simpa using h)
    · exact h
  | sendState c =>
    simp only [step, Event.actor] at h ⊢
    split
    · rename_i r hr
      have h' : Good o p ((sendNew c (.state r.gen ((updS c (fun x => { x with rs := some { r with sent := true } }) s).sd c).own)
          (updS c (fun x => { x with rs := some { r with sent := true } }) s)).sd c) := by
        simp [sendNew]
        refine ⟨h.own, h.ps, fun hp => ?_⟩
        have := (h.quiet hp).2; rw [hr] at this; cases this
      split
      · exact good_doApply c _ h'
      · exact h'
    · exact h
  | apply c => exact good_doApply c s h
  | finish c =>
    simp only [step, Event.actor] at h ⊢
    split
    · simp; exact ⟨h.own, h.ps, fun hp => ⟨(h.quiet hp).1, rfl⟩⟩
    · exact h
  | drift c => simp [step, Event.actor] at h ⊢; exact ⟨h.own, h.ps, h.quiet⟩

def ownOf : Cl → Nat
  | .a => 1
  | .b => 2

def psOf (pa pb : Bool) : Cl → Bool
  | .a => pa
  | .b => pb

theorem good_reachable {cfg : Cfg} {pa pb : Bool} {s : State} (h : Reachable cfg pa pb s) :
    ∀ c, Good (ownOf c) (psOf pa pb c) (s.sd c) := by
  induction h with
  | init => intro c; cases c <;> exact ⟨rfl, rfl, fun _ => ⟨rfl, rfl⟩⟩
  | step e _ hen ih =>
    intro c
    by_cases hc : c = e.actor
    · subst hc; exact good_step cfg _ e hen (ih _)
    · rw [step_sd_other cfg _ e hc]; exact ih c

/-- A friend whose HELLO doesn't say it checks (an older build) is sent none
    of the new kinds, whatever happens, and no re-sync starts on its account. -/
theorem older_friend_sent_nothing {cfg : Cfg} {pa pb : Bool} {s : State} (h : Reachable cfg pa pb s)
    (c : Cl) (hp : (s.sd c).peerSync = false) : (s.sd c).newSent = 0 ∧ (s.sd c).rs = none :=
  (good_reachable h c).quiet hp

/-- Each player's own game is never touched: a re-sync changes only a side's
    copy of the friend's game. -/
theorem own_game_untouched {cfg : Cfg} {pa pb : Bool} {s : State} (h : Reachable cfg pa pb s)
    (c : Cl) : (s.sd c).own = ownOf c :=
  (good_reachable h c).own


/-! ### Every input reaches the engine of the session it was played in

The channel to a side carries, in order, the friend's inputs of the
receiver's current session; then, once the friend has sent its state, that
state; then only inputs of the new session (the friend has restarted). The
receiver restarts the moment it has the state and has sent its own (the
friend's state can't come before ours went: the friend sends only once it
has our proposal and every input to the stop frame). -/

def Ok : List Msg → Nat → Prop
  | [], _ => True
  | m :: t, e =>
    match m with
    | .inp k => k = e ∧ Ok t e
    | .state g _ => Ok t g
    | _ => Ok t e

def lastSeg : List Msg → Nat → Nat
  | [], e => e
  | m :: t, e =>
    match m with
    | .state g _ => lastSeg t g
    | _ => lastSeg t e

def NoInp (l : List Msg) : Prop := ∀ k, Msg.inp k ∉ l

theorem ok_noinp {l : List Msg} : ∀ (e : Nat), NoInp l → Ok l e := by
  induction l with
  | nil => intro _ _; trivial
  | cons m t ih =>
    intro e h
    have ht : NoInp t := fun k hk => h k (List.mem_cons_of_mem _ hk)
    cases m with
    | inp k => exact absurd List.mem_cons_self (h k)
    | state g v => show Ok t g; exact ih g ht
    | sync => show Ok t e; exact ih e ht
    | resync => show Ok t e; exact ih e ht
    | ready => show Ok t e; exact ih e ht

theorem ok_append {l : List Msg} : ∀ {e : Nat} (m : Msg), Ok l e →
    (∀ k, m = .inp k → lastSeg l e = k) → Ok (l ++ [m]) e := by
  induction l with
  | nil =>
    intro e m _ hm
    cases m with
    | inp k => exact ⟨(hm k rfl).symm, trivial⟩
    | state => trivial
    | sync => trivial
    | resync => trivial
    | ready => trivial
  | cons x t ih =>
    intro e m h hm
    cases x with
    | inp k => exact ⟨h.1, ih m h.2 (fun k' hk => by simpa [lastSeg] using hm k' hk)⟩
    | state g v => show Ok (t ++ [m]) g; exact ih m h (fun k' hk => by simpa [lastSeg] using hm k' hk)
    | sync => show Ok (t ++ [m]) e; exact ih m h (fun k' hk => by simpa [lastSeg] using hm k' hk)
    | resync => show Ok (t ++ [m]) e; exact ih m h (fun k' hk => by simpa [lastSeg] using hm k' hk)
    | ready => show Ok (t ++ [m]) e; exact ih m h (fun k' hk => by simpa [lastSeg] using hm k' hk)

theorem lastSeg_nostate {l : List Msg} : ∀ (e : Nat), (∀ g v, Msg.state g v ∉ l) → lastSeg l e = e := by
  induction l with
  | nil => intro _ _; rfl
  | cons m t ih =>
    intro e h
    have ht : ∀ g v, Msg.state g v ∉ t := fun g v hg => h g v (List.mem_cons_of_mem _ hg)
    cases m with
    | state g v => exact absurd List.mem_cons_self (h g v)
    | inp => show lastSeg t e = e; exact ih e ht
    | sync => show lastSeg t e = e; exact ih e ht
    | resync => show lastSeg t e = e; exact ih e ht
    | ready => show lastSeg t e = e; exact ih e ht

theorem lastSeg_states {l : List Msg} : ∀ (e g : Nat), (∀ g' v, Msg.state g' v ∈ l → g' = g) →
    (∃ v, Msg.state g v ∈ l) → lastSeg l e = g := by
  induction l with
  | nil => intro _ _ _ ⟨_, hv⟩; exact absurd hv List.not_mem_nil
  | cons m t ih =>
    intro e g h hex
    have ht : ∀ g' v, Msg.state g' v ∈ t → g' = g := fun g' v hg => h g' v (List.mem_cons_of_mem _ hg)
    by_cases hs : ∃ v, Msg.state g v ∈ t
    · cases m with
      | state g' v' => show lastSeg t g' = g; exact ih g' g ht hs
      | inp => show lastSeg t e = g; exact ih e g ht hs
      | sync => show lastSeg t e = g; exact ih e g ht hs
      | resync => show lastSeg t e = g; exact ih e g ht hs
      | ready => show lastSeg t e = g; exact ih e g ht hs
    · have hnt : ∀ g' v, Msg.state g' v ∉ t := by
        intro g' v hg'
        have := ht g' v hg'
        subst this
        exact hs ⟨v, hg'⟩
      obtain ⟨v, hv⟩ := hex
      rcases List.mem_cons.mp hv with hm | hm
      · subst hm; show lastSeg t g = g; exact lastSeg_nostate g hnt
      · exact absurd ⟨v, hm⟩ hs


/-! ### No side plays past the stop frame

During a re-sync, until its restart, a side's frame count is at most its stop
frame + 1 (its own proposal until the friend's is in): where the state it
sends is taken (`sendState` needs exactly stop + 1). -/

def Bar (x : Side) : Prop := ∀ r, x.rs = some r → r.applied = false → x.head ≤ limit r + 1

theorem bar_begin (c : Cl) (s : State) (h : Bar (s.sd c)) : Bar ((begin c s).sd c) := by
  simp only [begin]
  split
  · simp only [sendNew, updS_sd_self, send_sd]
    intro r hr _
    simp at hr; subst hr
    simp [limit]; omega
  · exact h

theorem bar_fp (c : Cl) (s : State) (f : Side → Side) (hf : ∀ x, (f x).rs = x.rs ∧ (f x).head = x.head)
    (h : Bar (s.sd c)) : Bar ((updS c f s).sd c) := by
  simp only [updS_sd_self]
  intro r hr ha
  rw [(hf _).2]; exact h r (by rw [← (hf _).1]; exact hr) ha

theorem bar_compare (c : Cl) (s : State) (h : Bar (s.sd c)) : Bar ((compare c s).sd c) := by
  simp only [compare]
  split
  · have h' := bar_fp c s (fun x => { x with fp := none, tfp := none }) (fun _ => ⟨rfl, rfl⟩) h
    split
    · exact h'
    · exact bar_begin c _ h'
  · exact h

theorem bar_doApply (c : Cl) (s : State) (h : Bar (s.sd c)) : Bar ((doApply c s).sd c) := by
  simp only [doApply]
  split
  · split
    · split
      · simp only [sendNew, updS_sd_self, send_sd]
        intro r hr ha
        simp at hr; subst hr; simp at ha
      · exact h
    · exact h
  · exact h

theorem bar_recv (cfg : Cfg) (c : Cl) (m : Msg) (s : State) (h : Bar (s.sd c)) :
    Bar ((recv cfg c m s).sd c) := by
  cases m with
  | inp => simp only [recv]; exact bar_fp c s _ (fun _ => ⟨rfl, rfl⟩) h
  | sync =>
    simp only [recv]
    split
    · exact bar_compare c _ (bar_fp c s _ (fun _ => ⟨rfl, rfl⟩) h)
    · exact h
  | resync g t =>
    simp only [recv]
    have hb : ∀ (q : Prop) [Decidable q], Bar ((if q then begin c s else s).sd c) := by
      intro q _; split
      · exact bar_begin c s h
      · exact h
    split
    · rename_i r hr
      split
      · rename_i hc
        simp only [updS_sd_self]
        intro r' hr' ha
        simp at hr'; subst hr'
        have := hb _ r hr ha
        simp [limit] at this ⊢
        rw [hc.2.2] at this
        simp at this
        omega
      · exact hb _
    · exact hb _
  | state g v =>
    simp only [recv]
    split
    · rename_i r hr
      have h' : Bar ((updS c (fun x => { x with rs := some { r with got := some v } }) s).sd c) := by
        simp only [updS_sd_self]
        intro r' hr' ha
        simp at hr'; subst hr'
        have := h r hr ha
        simpa [limit] using this
      split
      · split
        · exact bar_doApply c _ h'
        · exact h'
      · exact h
    · exact h
  | ready g =>
    simp only [recv]
    split
    · rename_i r hr
      split
      · simp only [updS_sd_self]
        intro r' hr' ha
        simp at hr'; subst hr'
        have := h r hr ha
        simpa [limit] using this
      · exact h
    · exact h

theorem bar_step (cfg : Cfg) (s : State) (e : Event) (hen : en cfg s e = true)
    (h : Bar (s.sd e.actor)) : Bar ((step cfg s e).sd e.actor) := by
  cases e with
  | tick c =>
    simp only [Event.actor] at h ⊢
    simp only [step, send_sd, updS_sd_self]
    intro r hr ha
    simp only at hr
    have hb : atBarrier (s.sd c) = false := by
      simp only [en, Bool.and_eq_true, Bool.not_eq_true'] at hen; exact hen.1
    simp only [atBarrier, hr, ha] at hb
    simp at hb
    simp only [limit] at *
    omega
  | check c =>
    simp only [Event.actor] at h ⊢
    simp only [step]
    apply bar_compare
    split <;> (intro r hr ha; simp [sendNew] at hr ⊢; exact h r hr ha)
  | deliver c =>
    simp only [Event.actor] at h ⊢
    simp only [step]
    split
    · exact bar_recv cfg c _ _ (by simpa using h)
    · exact h
  | sendState c =>
    simp only [Event.actor] at h ⊢
    simp only [step]
    split
    · rename_i r hr
      have h' : Bar ((sendNew c (.state r.gen ((updS c (fun x => { x with rs := some { r with sent := true } }) s).sd c).own)
          (updS c (fun x => { x with rs := some { r with sent := true } }) s)).sd c) := by
        simp only [sendNew, updS_sd_self, send_sd]
        intro r' hr' ha
        simp at hr'; subst hr'
        have := h r hr ha
        simpa [limit] using this
      split
      · exact bar_doApply c _ h'
      · exact h'
    · exact h
  | apply c => simp only [Event.actor] at h ⊢; exact bar_doApply c s h
  | finish c =>
    simp only [Event.actor] at h ⊢
    simp only [step]
    split
    · intro r hr; simp at hr
    · exact h
  | drift c =>
    simp only [Event.actor] at h ⊢
    simp only [step, updS_sd_self]
    intro r hr ha; exact h r hr ha

theorem bar_reachable {cfg : Cfg} {pa pb : Bool} {s : State} (h : Reachable cfg pa pb s) :
    ∀ c, Bar (s.sd c) := by
  induction h with
  | init => intro c; cases c <;> (intro r hr; simp [init, mkSide] at hr)
  | step e _ hen ih =>
    intro c
    by_cases hc : c = e.actor
    · subst hc; exact bar_step cfg _ e hen (ih _)
    · rw [step_sd_other cfg _ e hc]; exact ih c

/-- Until it restarts, a side in a re-sync is at most one frame past its stop
    frame: no frame past the stop is played, so the state it sends is the
    stop frame's (`sendState` takes it at exactly stop + 1). -/
theorem never_past_the_stop {cfg : Cfg} {pa pb : Bool} {s : State} (h : Reachable cfg pa pb s)
    (c : Cl) (r : Rs) (hr : (s.sd c).rs = some r) (ha : r.applied = false) :
    (s.sd c).head ≤ limit r + 1 :=
  bar_reachable h c r hr ha

/-! ## Traces -/

def inStep (s : State) : Bool :=
  (s.sd .a).copy == (s.sd .b).own && (s.sd .b).copy == (s.sd .a).own

def settled (s : State) : Bool :=
  (s.sd .a).rs.isNone && (s.sd .b).rs.isNone && (s.ch .a).isEmpty && (s.ch .b).isEmpty

def noStale (s : State) : Bool := !(s.sd .a).stale && !(s.sd .b).stale

/-- Both play a frame and hear each other's. -/
def frame : List Event := [.tick .a, .tick .b, .deliver .a, .deliver .b]

/-- Everything on the way to `c`, `n` messages. -/
def drain (c : Cl) (n : Nat) : List Event := List.replicate n (.deliver c)

/-- B's copy of A's game drifts; the next fingerprints differ; both propose,
    play to the later proposal, send their own games, restart from them and
    hear each other's restart: back in step, and every input reached the
    engine of the session it was played in. -/
def resyncRun : List Event :=
  [.drift .b, .check .a, .check .b, .deliver .b, .deliver .a,  -- the fingerprints cross: both begin
   .deliver .b, .deliver .a] ++                                -- the proposals cross: both know the stop
  frame ++ frame ++ frame ++                                   -- play to it (frame 2)
  [.sendState .a, .sendState .b, .deliver .b, .deliver .a,     -- the states cross: both restart
   .deliver .b, .deliver .a, .finish .a, .finish .b] ++        -- the READYs cross
  frame

theorem resync_happy :
    witnesses .code true true resyncRun
      (fun s => inStep s && settled s && noStale s &&
                (s.sd .a).gen == 1 && (s.sd .b).gen == 1 && (s.sd .a).head == 1) = true := by
  decide

/-- The same with the proposals far apart: A plays two frames ahead before
    the check (its window allows it), so its proposal is the later. -/
theorem resync_proposals_differ :
    witnesses .code true true
      ([.drift .b, .tick .a, .tick .a, .check .a, .check .b] ++
       drain .b 3 ++ drain .a 1 ++    -- B: A's two inputs and fingerprint; A: B's: both begin
       drain .b 1 ++ drain .a 1 ++    -- the proposals (A 4, B 2): both stop at 4
       [.tick .b, .tick .b, .deliver .a, .deliver .a] ++ frame ++ frame ++ frame ++
       [.sendState .a, .sendState .b] ++ drain .b 1 ++ drain .a 1 ++  -- the states: both restart
       drain .b 1 ++ drain .a 1 ++ [.finish .a, .finish .b])          -- the READYs
      (fun s => inStep s && settled s && noStale s && (s.sd .a).gen == 1) = true := by
  decide

/-- A friend that doesn't check (an older build: neither HELLO says so) is
    sent nothing new, drift or not; the drift goes unnoticed, as before. -/
theorem old_friend_sent_nothing :
    witnesses .code false false
      [.drift .b, .check .a, .check .b, .tick .a, .deliver .b, .tick .b, .deliver .a]
      (fun s => (s.sd .a).newSent == 0 && (s.sd .b).newSent == 0 && !inStep s && settled s) = true := by
  decide

/-- The restart on a later frame of its own: A restarts and plays, and its
    first new input reaches B, whose engine is still on the old session (the
    code restarts on the state's arrival: `inputs_in_session`). -/
theorem stale_input_if_restart_waits :
    witnesses .waits true true
      ([.drift .b, .check .a, .check .b, .deliver .b, .deliver .a,
        .deliver .b, .deliver .a] ++ frame ++ frame ++ frame ++
       [.sendState .a, .sendState .b,
        .deliver .a,              -- B's state reaches A
        .apply .a,                -- A restarts...
        .tick .a,                 -- ...and plays its new frame 0
        .deliver .b,              -- A's state reaches B, which doesn't restart yet
        .deliver .b,              -- A's READY
        .deliver .b])             -- A's new input: into B's old session
      (fun s => (s.sd .b).stale) = true := by
  decide

end WebState.LinkSync
