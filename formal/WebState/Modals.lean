-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/index.js: anyModalOpen askRomWarn buildSyncModal closeRomWarnModal closeSettingsModal closeUpdateModal confirmSuspectRom confirmTombstones handleRomFile openRenameModal openSettingsModal releaseFocus renameGame renameInventory runFullSync settleRomWarn trapFocus on:popstate on:drop

/-
# Modal focus management and modal plumbing (web/index.js @ dd7ba741f)

What the code has (there is no modal *stack*):

* ONE focus-trap slot: `modalTrapOverlay` (owner), `modalReturnFocus` (where
  focus goes back), `modalTrapHandler` (index.js 425-427). `trapFocus`
  (439) overwrites all three; `releaseFocus` (460) is a no-op unless its
  argument is the owner, else it restores `modalReturnFocus` if it is still
  connected and displayed, falling back to `menuBtn`.
* Static overlays with their own open flag: settings (`openSettingsModal`
  1112, `closeSettingsModal` 1146, also closed by the popstate/back handler
  943), update (206/201), the ROM-check prompt (`askRomWarn` 8057,
  `settleRomWarn` 8045, `closeRomWarnModal` 8053).
* Dynamic "sync" overlays built by `buildSyncModal` (3607): their Escape
  listener is document-*capture* and calls `stopPropagation`, so while one is
  up the global Escape handler (5213, document bubble) does not run. Two users:
  `openRenameModal` (3375, guarded by `renameModalOpen`) and
  `confirmTombstones` (3559, a Promise resolved by `done`).
* The global Escape handler closes every static modal blindly (5213).
* Promise-returning modals: `confirmTombstones` (3559) and `askRomWarn` (8057).
* There is no body scroll-lock or `inert` flag tied to modals: overlays are
  `position: fixed; inset: 0; z-index: 500` (styles.css 3361) and
  `anyModalOpen()` (8999) is computed from the DOM (`.modal-overlay.open`), so
  "flag set iff stack non-empty" holds by construction and is not modelled.
  (`inert` is used only for the settings sheet's off-stage screen, 889.)

## Abstractions

* Elements are `page` (whatever had focus outside any modal), `menuBtn`, the
  control that opened overlay `o` (`opener o`), "something inside `o`"
  (`inside o`) and `body` (focus lost: `document.activeElement === body`).
  `visible (inside o)` iff `o` is open; `page`/`menuBtn`/`opener` are taken as
  visible (the only property that uses this is the positive theorem, and an
  invisible opener only turns a restore into the `menuBtn` fallback).
* Focus fix-up: when an overlay closes while focus is inside it, the browser
  moves focus to `body` (`fixup`, applied at the end of every event).
* Every overlay has a focusable element, so `trapFocus` always focuses inside.
* Saves/states/cheats/report/rewind/clip/thumbs modals are the same pattern as
  settings/update (flag + trapFocus/releaseFocus + closed by Escape); settings
  and update stand for them.
* `openRenameModal`'s two storage reads (3380-3383) are one await
  (`renameLoaded`/`renameLoadFail`); `renameGame` (3514) is one await
  (`renameResult`). `handleRomFile`'s FileReader + `confirmSuspectRom` is one
  event (`dropSuspect`): nothing between them touches modal state.
* A pending `runFullSync` is one flag; it reaches `confirmTombstones` at most
  once per sync (`syncTomb`) and finishes when the promise settles. Only one
  sync at a time (the Drive sync machine's `runExclusive` chain, 2912).
* Escape with two sync overlays up fires both capture listeners; the model
  lets `escSync o` close one at a time (an over-approximation, sound for the
  invariants; no counterexample below needs two sync overlays under Escape).
* User clicks inside an overlay are enabled whenever it is open (the model
  does not track z-order), again an over-approximation.
-/
namespace WebState.Modals

inductive Ov where
  | settings | update | romWarn
  | rename (i : Nat)   -- the i-th overlay built by openRenameModal
  | tomb (i : Nat)     -- the i-th overlay built by confirmTombstones
  deriving DecidableEq, Repr

inductive El where
  | page | menuBtn | opener (o : Ov) | inside (o : Ov) | body
  deriving DecidableEq, Repr

inductive RPhase where
  | idle     -- not created
  | loading  -- openRenameModal awaiting libraryNames/renameInventory (3380)
  | shown    -- overlay in the DOM
  | gone     -- dismissed (or the load failed)
  deriving DecidableEq, Repr

structure RInst where
  phase    : RPhase := .idle
  inflight : Bool := false   -- the Rename button's `await renameGame` (3514)
  deriving DecidableEq, Repr

inductive PSt where
  | none | pending | settled
  deriving DecidableEq, Repr

structure TInst where
  shown   : Bool := false    -- overlay in the DOM
  settles : Nat := 0         -- times `resolve` took effect
  deriving DecidableEq, Repr

structure State where
  settingsOpen : Bool          -- settingsModal.classList "open"
  updateOpen   : Bool          -- updateModal.classList "open"
  romWarnOpen  : Bool          -- romWarnModal.classList "open"
  owner        : Option Ov     -- modalTrapOverlay (427)
  ret          : Option El     -- modalReturnFocus (425)
  focus        : El            -- document.activeElement
  warnResolve  : Option Nat    -- romWarnResolve (8043): which promise it resolves
  warnP        : Nat → PSt     -- the promises askRomWarn returned
  nextWarn     : Nat
  renameFlag   : Bool          -- renameModalOpen (3373)
  ren          : Nat → RInst
  nextRen      : Nat
  syncPending  : Bool          -- a runFullSync in flight
  tombWaiting  : Bool          -- that sync is awaiting confirmTombstones
  tomb         : Nat → TInst
  nextTomb     : Nat
  errorLost    : Bool          -- a rename failure rendered into a detached overlay

def init : State where
  settingsOpen := false
  updateOpen := false
  romWarnOpen := false
  owner := none
  ret := none
  focus := .page
  warnResolve := none
  warnP := fun _ => .none
  nextWarn := 0
  renameFlag := false
  ren := fun _ => {}
  nextRen := 0
  syncPending := false
  tombWaiting := false
  tomb := fun _ => {}
  nextTomb := 0
  errorLost := false

def isOpen (s : State) : Ov → Bool
  | .settings => s.settingsOpen
  | .update => s.updateOpen
  | .romWarn => s.romWarnOpen
  | .rename i => (s.ren i).phase == .shown
  | .tomb i => (s.tomb i).shown

def anySync (s : State) : Bool :=
  (List.range s.nextRen).any (fun i => (s.ren i).phase == .shown) ||
  (List.range s.nextTomb).any (fun i => (s.tomb i).shown)

/-- anyModalOpen() (8999). -/
def anyOpen (s : State) : Bool :=
  s.settingsOpen || s.updateOpen || s.romWarnOpen || anySync s

/-- `isConnected && offsetParent !== null` (468). -/
def visible (s : State) : El → Bool
  | .inside o => isOpen s o
  | .body => false
  | _ => true

/-- trapFocus (439). -/
def trapFocus (o : Ov) (s : State) : State :=
  { s with owner := some o, ret := some s.focus, focus := .inside o }

/-- releaseFocus (460). -/
def releaseFocus (o : Ov) (s : State) : State :=
  if s.owner = some o then
    { s with owner := none, ret := none,
             focus := match s.ret with
               | some e => if visible s e then e else .menuBtn
               | none => s.focus }
  else s

/-- The browser's focus fix-up for a focused element that stopped being rendered. -/
def fixup (s : State) : State :=
  match s.focus with
  | .inside o => if isOpen s o then s else { s with focus := .body }
  | _ => s

def setRen (i : Nat) (r : RInst) (s : State) : State :=
  { s with ren := fun j => if j = i then r else s.ren j }

def setTomb (i : Nat) (t : TInst) (s : State) : State :=
  { s with tomb := fun j => if j = i then t else s.tomb j }

/-- closeSettingsModal (1146): remove "open", then releaseFocus. -/
def closeSettings (s : State) : State :=
  releaseFocus .settings { s with settingsOpen := false }

/-- closeUpdateModal (201). -/
def closeUpdate (s : State) : State :=
  releaseFocus .update { s with updateOpen := false }

/-- settleRomWarn (8045): take the resolver, clear it, close, release, resolve. -/
def settleRomWarn (s : State) : State :=
  let r := s.warnResolve
  let s := releaseFocus .romWarn { s with warnResolve := none, romWarnOpen := false }
  match r with
  | some n => { s with warnP := fun j => if j = n then .settled else s.warnP j }
  | none => s

/-- closeRomWarnModal (8053). -/
def closeRomWarn (s : State) : State :=
  if s.warnResolve.isSome then settleRomWarn s else s

/-- askRomWarn (8057): a new promise; the resolver slot is overwritten. -/
def askRomWarn (s : State) : State :=
  let n := s.nextWarn
  trapFocus .romWarn
    { s with warnP := fun j => if j = n then .pending else s.warnP j,
             nextWarn := n + 1, warnResolve := some n, romWarnOpen := true }

/-- The rename modal's `close` (3392): clear the flag, then `m.dismiss()`
    (3645: remove the Escape listener, releaseFocus, overlay.remove()). -/
def renameClose (i : Nat) (s : State) : State :=
  let s := { s with renameFlag := false }
  let s := setRen i { s.ren i with phase := .gone } s
  releaseFocus (.rename i) s

/-- confirmTombstones' `done` (3562): dismiss, then resolve. The sync resumes. -/
def tombDone (i : Nat) (s : State) : State :=
  let s := setTomb i { shown := false, settles := (s.tomb i).settles + 1 } s
  let s := releaseFocus (.tomb i) s
  { s with syncPending := false, tombWaiting := false }

inductive Event where
  | openSettings          -- #settings-btn / #open-settings click
  | closeSettings         -- close button, swipe, or Android back (popstate 943)
  | openUpdate            -- #update-btn with a game loaded (206)
  | closeUpdate           -- Not now / x / backdrop (216-221)
  | dropSuspect           -- a file failing looksLikeValidRom dropped (drop 8210 has no modal guard)
  | romWarnLoad           -- "Load anyway" (8073)
  | romWarnCancel         -- Cancel / x / backdrop (8074-8078)
  | escGlobal             -- Escape reaching the document-bubble handler (5213)
  | escSync (o : Ov)      -- Escape caught by a sync overlay's capture listener (3633)
  | syncStart             -- Sync in the settings Drive section (2265) or on the home screen (3904)
  | syncTomb              -- that sync's pull reaches confirmTombstones (2961)
  | tombChoose (i : Nat)  -- Restore / Continue / x / backdrop on tomb overlay i
  | renameMenu            -- tile menu "Rename" (4751) -> openRenameModal, first segment
  | renameLoaded (i : Nat)  -- its storage reads resolve: build the overlay (3396)
  | renameLoadFail (i : Nat)
  | renameGo (i : Nat)      -- "Rename" in the confirm pane (3511)
  | renameResult (i : Nat) (ok : Bool)  -- `await renameGame` resumes
  | renameCancel (i : Nat)  -- Cancel / Close / x / backdrop
  deriving DecidableEq, Repr

/-- Only the settings modal is up (its own buttons are reachable). -/
def onlySettings (s : State) : Bool :=
  s.settingsOpen && !s.updateOpen && !s.romWarnOpen && !anySync s

def isSyncOv : Ov → Bool
  | .rename _ | .tomb _ => true
  | _ => false

def en (s : State) : Event → Bool
  | .openSettings => !anyOpen s
  | .closeSettings => s.settingsOpen
  | .openUpdate => !anyOpen s
  | .closeUpdate => s.updateOpen
  | .dropSuspect => true
  | .romWarnLoad => s.romWarnOpen
  | .romWarnCancel => s.romWarnOpen
  | .escGlobal => !anySync s
  | .escSync o => isSyncOv o && isOpen s o
  | .syncStart => !s.syncPending && (!anyOpen s || onlySettings s)
  | .syncTomb => s.syncPending && !s.tombWaiting
  | .tombChoose i => (s.tomb i).shown
  | .renameMenu => !anyOpen s
  | .renameLoaded i => (s.ren i).phase == .loading
  | .renameLoadFail i => (s.ren i).phase == .loading
  | .renameGo i => (s.ren i).phase == .shown && !(s.ren i).inflight
  | .renameResult i _ => (s.ren i).inflight
  | .renameCancel i => (s.ren i).phase == .shown

def step (s : State) : Event → State
  | .openSettings => fixup (trapFocus .settings { s with settingsOpen := true, focus := .opener .settings })
  | .closeSettings => fixup (closeSettings s)
  | .openUpdate => fixup (trapFocus .update { s with updateOpen := true, focus := .opener .update })
  | .closeUpdate => fixup (closeUpdate s)
  | .dropSuspect => fixup (askRomWarn s)
  | .romWarnLoad => fixup (settleRomWarn s)
  | .romWarnCancel => fixup (closeRomWarn s)
  -- 5213: closeSettingsModal(); ...; closeUpdateModal(); ...; closeRomWarnModal(); ...
  | .escGlobal => fixup (closeRomWarn (closeUpdate (closeSettings s)))
  | .escSync o => match o with
    | .rename i => fixup (renameClose i s)
    | .tomb i => fixup (tombDone i s)
    | _ => s
  | .syncStart => { s with syncPending := true }
  | .syncTomb =>
    let n := s.nextTomb
    fixup (trapFocus (.tomb n)
      (setTomb n { shown := true, settles := 0 } { s with nextTomb := n + 1, tombWaiting := true }))
  | .tombChoose i => fixup (tombDone i s)
  -- 3375: if (renameModalOpen) return; renameModalOpen = true; ...await
  | .renameMenu =>
    if s.renameFlag then s
    else setRen s.nextRen { phase := .loading } { s with renameFlag := true, nextRen := s.nextRen + 1 }
  | .renameLoaded i => fixup (trapFocus (.rename i) (setRen i { s.ren i with phase := .shown } s))
  | .renameLoadFail i => setRen i { s.ren i with phase := .gone } { s with renameFlag := false }
  | .renameGo i => setRen i { s.ren i with inflight := true } s
  -- 3514: let res = await renameGame(...); if (!res.ok) { showErrorStep(...); return; } close(); ...
  | .renameResult i ok =>
    let s' := setRen i { s.ren i with inflight := false } s
    if ok then fixup (renameClose i s')
    else if (s.ren i).phase == .shown then s' else { s' with errorLost := true }
  | .renameCancel i => fixup (renameClose i s)

inductive Reachable : State → Prop
  | init : Reachable init
  | step {s : State} (e : Event) : Reachable s → en s e = true → Reachable (step s e)

/-- Run a trace, failing (none) at the first disabled event. -/
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

/-! ## Invariants that hold -/

structure Inv (s : State) : Prop where
  /-- The trap owner is always an open overlay. -/
  ownerOpen : ∀ o, s.owner = some o → isOpen s o = true
  renFresh  : ∀ i, s.nextRen ≤ i → s.ren i = {}
  tombFresh : ∀ i, s.nextTomb ≤ i → s.tomb i = {}
  /-- Every tombstone promise settles at most once, and is pending exactly
      while its overlay (whose buttons and Escape all call `done`) is up. -/
  tombOnce  : ∀ i, i < s.nextTomb → (s.tomb i).settles ≤ 1 ∧
                ((s.tomb i).shown = true ↔ (s.tomb i).settles = 0)
  tombWait  : s.tombWaiting = true → s.syncPending = true
  warnFresh : ∀ n, s.nextWarn ≤ n → s.warnP n = .none
  /-- romWarnResolve always resolves a live promise, and the prompt is up iff it is held. -/
  warnRes   : ∀ n, s.warnResolve = some n → s.warnP n = .pending ∧ n < s.nextWarn
  warnOpen  : s.romWarnOpen = true ↔ s.warnResolve.isSome = true

theorem inv_init : Inv init := by
  constructor <;> simp [init, isOpen]

@[simp] theorem isOpen_settings (s : State) : isOpen s .settings = s.settingsOpen := rfl
@[simp] theorem isOpen_update (s : State) : isOpen s .update = s.updateOpen := rfl
@[simp] theorem isOpen_romWarn (s : State) : isOpen s .romWarn = s.romWarnOpen := rfl
@[simp] theorem isOpen_rename (s : State) (i) : isOpen s (.rename i) = ((s.ren i).phase == .shown) := rfl
@[simp] theorem isOpen_tomb (s : State) (i) : isOpen s (.tomb i) = (s.tomb i).shown := rfl

/-- `fixup` and `releaseFocus` change only focus/owner/ret. -/
theorem fixup_eq (s : State) : ∃ f, fixup s = { s with focus := f } := by
  unfold fixup
  split
  · split
    · exact ⟨s.focus, rfl⟩
    · exact ⟨_, rfl⟩
  · exact ⟨s.focus, rfl⟩

/-- Inv only mentions fields that fixup leaves alone (owner, open flags, etc.). -/
theorem inv_fixup {s : State} (h : Inv s) : Inv (fixup s) := by
  obtain ⟨f, hf⟩ := fixup_eq s
  rw [hf]
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  exact ⟨fun o ho => by have := h1 o ho; cases o <;> simpa [isOpen] using this,
    h2, h3, h4, h5, h6, h7, h8⟩

/-! ### Field lemmas: fixup / releaseFocus / trapFocus touch only focus, owner, ret -/

section fields
variable (s : State) (o : Ov)

@[simp] theorem fixup_owner : (fixup s).owner = s.owner := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_settings : (fixup s).settingsOpen = s.settingsOpen := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_update : (fixup s).updateOpen = s.updateOpen := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_romWarn : (fixup s).romWarnOpen = s.romWarnOpen := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_ren : (fixup s).ren = s.ren := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_nextRen : (fixup s).nextRen = s.nextRen := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_tomb : (fixup s).tomb = s.tomb := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_nextTomb : (fixup s).nextTomb = s.nextTomb := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_tombWaiting : (fixup s).tombWaiting = s.tombWaiting := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_syncPending : (fixup s).syncPending = s.syncPending := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_warnP : (fixup s).warnP = s.warnP := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_nextWarn : (fixup s).nextWarn = s.nextWarn := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_warnResolve : (fixup s).warnResolve = s.warnResolve := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_renameFlag : (fixup s).renameFlag = s.renameFlag := by
  unfold fixup; split <;> (try split) <;> rfl
@[simp] theorem fixup_errorLost : (fixup s).errorLost = s.errorLost := by
  unfold fixup; split <;> (try split) <;> rfl

@[simp] theorem rel_owner :
    (releaseFocus o s).owner = if s.owner = some o then none else s.owner := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_settings : (releaseFocus o s).settingsOpen = s.settingsOpen := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_update : (releaseFocus o s).updateOpen = s.updateOpen := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_romWarn : (releaseFocus o s).romWarnOpen = s.romWarnOpen := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_ren : (releaseFocus o s).ren = s.ren := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_nextRen : (releaseFocus o s).nextRen = s.nextRen := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_tomb : (releaseFocus o s).tomb = s.tomb := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_nextTomb : (releaseFocus o s).nextTomb = s.nextTomb := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_tombWaiting : (releaseFocus o s).tombWaiting = s.tombWaiting := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_syncPending : (releaseFocus o s).syncPending = s.syncPending := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_warnP : (releaseFocus o s).warnP = s.warnP := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_nextWarn : (releaseFocus o s).nextWarn = s.nextWarn := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_warnResolve : (releaseFocus o s).warnResolve = s.warnResolve := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_renameFlag : (releaseFocus o s).renameFlag = s.renameFlag := by
  unfold releaseFocus; split <;> rfl
@[simp] theorem rel_errorLost : (releaseFocus o s).errorLost = s.errorLost := by
  unfold releaseFocus; split <;> rfl

end fields

theorem isOpen_congr {s t : State} (h1 : s.settingsOpen = t.settingsOpen)
    (h2 : s.updateOpen = t.updateOpen) (h3 : s.romWarnOpen = t.romWarnOpen)
    (h4 : s.ren = t.ren) (h5 : s.tomb = t.tomb) (o : Ov) : isOpen s o = isOpen t o := by
  cases o <;> simp [isOpen, *]

@[simp] theorem isOpen_fixup (s : State) (o : Ov) : isOpen (fixup s) o = isOpen s o :=
  isOpen_congr (by simp) (by simp) (by simp) (by simp) (by simp) o

@[simp] theorem isOpen_rel (s : State) (o o' : Ov) : isOpen (releaseFocus o' s) o = isOpen s o :=
  isOpen_congr (by simp) (by simp) (by simp) (by simp) (by simp) o

/-- `ownerOpen` is handled by cases on the overlay; everything else by simp + grind. -/
syntax "inv_tac" "[" Lean.Parser.Tactic.simpLemma,* "]" : tactic
macro_rules
  | `(tactic| inv_tac [$ls,*]) => `(tactic| (
      obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := ‹Inv _›
      constructor
      case ownerOpen =>
        intro o ho
        simp [$ls,*] at ho ⊢
        cases o <;> (repeat' split at ho) <;> simp_all [isOpen] <;> grind
      all_goals (simp [$ls,*] <;> (repeat' split) <;> simp_all <;> grind)))

section helpers
variable {s : State} (h : Inv s)
include h

theorem inv_closeSettings : Inv (closeSettings s) := by inv_tac [closeSettings]
theorem inv_closeUpdate : Inv (closeUpdate s) := by inv_tac [closeUpdate]
theorem inv_settleRomWarn : Inv (settleRomWarn s) := by inv_tac [settleRomWarn]
theorem inv_closeRomWarn : Inv (closeRomWarn s) := by
  unfold closeRomWarn; split
  · exact inv_settleRomWarn h
  · exact h
theorem inv_askRomWarn : Inv (askRomWarn s) := by inv_tac [askRomWarn, trapFocus]
theorem inv_openSettings : Inv (trapFocus .settings { s with settingsOpen := true, focus := .opener .settings }) := by
  inv_tac [trapFocus]
theorem inv_openUpdate : Inv (trapFocus .update { s with updateOpen := true, focus := .opener .update }) := by
  inv_tac [trapFocus]
theorem inv_renameClose (i : Nat) (hi : i < s.nextRen) : Inv (renameClose i s) := by
  inv_tac [renameClose, setRen]
theorem inv_tombDone (i : Nat) (hs : (s.tomb i).shown = true) : Inv (tombDone i s) := by
  inv_tac [tombDone, setTomb]
theorem inv_syncStart : Inv { s with syncPending := true } := by inv_tac []
theorem inv_syncTomb (hp : s.syncPending = true) :
    Inv (trapFocus (.tomb s.nextTomb)
      (setTomb s.nextTomb { shown := true, settles := 0 } { s with nextTomb := s.nextTomb + 1, tombWaiting := true })) := by
  inv_tac [trapFocus, setTomb]
theorem inv_renameMenu : Inv (step s .renameMenu) := by inv_tac [step, setRen]
theorem inv_renameLoaded (i : Nat) (hl : (s.ren i).phase = .loading) :
    Inv (trapFocus (.rename i) (setRen i { s.ren i with phase := .shown } s)) := by
  inv_tac [trapFocus, setRen]
theorem inv_renameLoadFail (i : Nat) (hl : (s.ren i).phase = .loading) :
    Inv (step s (.renameLoadFail i)) := by inv_tac [step, setRen]
theorem inv_renameGo (i : Nat) (hl : (s.ren i).phase = .shown) :
    Inv (step s (.renameGo i)) := by inv_tac [step, setRen]
theorem inv_setInflight (i : Nat) (hf : (s.ren i).inflight = true) :
    Inv (setRen i { s.ren i with inflight := false } s) := by inv_tac [setRen]
end helpers

theorem ren_lt {s : State} {i : Nat} (h : Inv s) (hne : s.ren i ≠ {}) : i < s.nextRen := by
  rcases Nat.lt_or_ge i s.nextRen with hl | hl
  · exact hl
  · exact absurd (h.renFresh i hl) hne

theorem inv_step {s : State} {e : Event} (h : Inv s) (he : en s e = true) : Inv (step s e) := by
  cases e with
  | openSettings => exact inv_fixup (inv_openSettings h)
  | closeSettings => exact inv_fixup (inv_closeSettings h)
  | openUpdate => exact inv_fixup (inv_openUpdate h)
  | closeUpdate => exact inv_fixup (inv_closeUpdate h)
  | dropSuspect => exact inv_fixup (inv_askRomWarn h)
  | romWarnLoad => exact inv_fixup (inv_settleRomWarn h)
  | romWarnCancel => exact inv_fixup (inv_closeRomWarn h)
  | escGlobal => exact inv_fixup (inv_closeRomWarn (inv_closeUpdate (inv_closeSettings h)))
  | escSync o =>
    cases o <;> simp [en, isSyncOv] at he
    · exact inv_fixup (inv_renameClose h _ (ren_lt h (by intro hc; simp [hc] at he)))
    · exact inv_fixup (inv_tombDone h _ he)
  | syncStart => exact inv_syncStart h
  | syncTomb =>
    simp [en] at he
    exact inv_fixup (inv_syncTomb h he.1)
  | tombChoose i =>
    simp [en] at he
    exact inv_fixup (inv_tombDone h i he)
  | renameMenu => exact inv_renameMenu h
  | renameLoaded i =>
    simp [en] at he
    exact inv_fixup (inv_renameLoaded h i he)
  | renameLoadFail i =>
    simp [en] at he
    exact inv_renameLoadFail h i he
  | renameGo i =>
    simp [en] at he
    exact inv_renameGo h i he.1
  | renameResult i ok =>
    simp [en] at he
    have h' := inv_setInflight h i he
    simp only [step]
    split
    · exact inv_fixup (inv_renameClose h' i (by simpa [setRen] using ren_lt h (by intro hc; simp [hc] at he)))
    · split
      · exact h'
      · obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h'
        exact ⟨fun o ho => by have := h1 o ho; cases o <;> simpa [isOpen] using this,
          h2, h3, h4, h5, h6, h7, h8⟩
  | renameCancel i =>
    simp [en] at he
    exact inv_fixup (inv_renameClose h i (ren_lt h (by intro hc; simp [hc] at he)))

theorem inv_reachable {s : State} (h : Reachable s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step e _ he ih => exact inv_step ih he

/-- Every tombstone prompt's promise settles exactly once, and it is pending
    exactly while its overlay (all of whose exits call `done`) is up. -/
theorem tomb_settles_once {s : State} (h : Reachable s) (i : Nat) (hi : i < s.nextTomb) :
    (s.tomb i).settles ≤ 1 ∧ ((s.tomb i).settles = 0 ↔ (s.tomb i).shown = true) := by
  have := (inv_reachable h).tombOnce i hi
  exact ⟨this.1, this.2.symm⟩

/-- The trap owner is always an open overlay (no dangling trap). -/
theorem owner_open {s : State} (h : Reachable s) (o : Ov) (ho : s.owner = some o) :
    isOpen s o = true := (inv_reachable h).ownerOpen o ho

/-- An askRomWarn promise that is pending but not held by `romWarnResolve`
    can never be settled: no event resolves it. -/
def Orphan (s : State) (n : Nat) : Prop :=
  s.warnP n = .pending ∧ s.warnResolve ≠ some n ∧ n < s.nextWarn

section orphan
variable {s : State} {n : Nat} (h : Orphan s n)
include h

theorem orph_fixup : Orphan (fixup s) n := by
  obtain ⟨a, b, c⟩ := h; exact ⟨by simp [a], by simp [b], by simp [c]⟩
theorem orph_rel (o : Ov) : Orphan (releaseFocus o s) n := by
  obtain ⟨a, b, c⟩ := h; exact ⟨by simp [a], by simp [b], by simp [c]⟩
theorem orph_settle : Orphan (settleRomWarn s) n := by
  obtain ⟨a, b, c⟩ := h
  cases hr : s.warnResolve with
  | none => simp [settleRomWarn, hr, Orphan, a, c]
  | some m =>
    have : m ≠ n := by intro hm; subst hm; exact b hr
    simp [settleRomWarn, hr, Orphan, a, c, Ne.symm this]
theorem orph_closeRomWarn : Orphan (closeRomWarn s) n := by
  unfold closeRomWarn; split
  · exact orph_settle h
  · exact h
theorem orph_closeSettings : Orphan (closeSettings s) n := by
  obtain ⟨a, b, c⟩ := h; unfold closeSettings; exact ⟨by simp [a], by simp [b], by simp [c]⟩
theorem orph_closeUpdate : Orphan (closeUpdate s) n := by
  obtain ⟨a, b, c⟩ := h; unfold closeUpdate; exact ⟨by simp [a], by simp [b], by simp [c]⟩
end orphan

theorem orphan_stable {s : State} {n : Nat} (ho : Orphan s n) (e : Event) :
    Orphan (step s e) n := by
  have ho' := ho
  obtain ⟨a, b, c⟩ := ho'
  cases e with
  | dropSuspect =>
    simp only [step]
    apply orph_fixup
    simp only [askRomWarn, trapFocus, Orphan]
    refine ⟨?_, ?_, ?_⟩
    · simp [Nat.ne_of_lt c, a]
    · simp; omega
    · omega
  | romWarnLoad => exact orph_fixup (orph_settle ho)
  | romWarnCancel => exact orph_fixup (orph_closeRomWarn ho)
  | escGlobal => exact orph_fixup (orph_closeRomWarn (orph_closeUpdate (orph_closeSettings ho)))
  | closeSettings => exact orph_fixup (orph_closeSettings ho)
  | closeUpdate => exact orph_fixup (orph_closeUpdate ho)
  | escSync o =>
    cases o <;> simp only [step]
    · exact ho
    · exact ho
    · exact ho
    · apply orph_fixup; unfold renameClose; apply orph_rel; exact ⟨by simp [setRen, a], by simp [setRen, b], by simp [setRen, c]⟩
    · apply orph_fixup; unfold tombDone; simp only [Orphan, setTomb]; refine ⟨?_, ?_, ?_⟩ <;> simp [a, b, c]
  | renameMenu =>
    simp only [step]; split
    · exact ho
    · exact ⟨by simp [setRen, a], by simp [setRen, b], by simp [setRen, c]⟩
  | renameResult i ok =>
    simp only [step]; split
    · apply orph_fixup; unfold renameClose; apply orph_rel
      exact ⟨by simp [setRen, a], by simp [setRen, b], by simp [setRen, c]⟩
    · split
      · exact ⟨by simp [setRen, a], by simp [setRen, b], by simp [setRen, c]⟩
      · exact ⟨by simp [setRen, a], by simp [setRen, b], by simp [setRen, c]⟩
  | renameCancel i =>
    apply orph_fixup; unfold renameClose; apply orph_rel
    exact ⟨by simp [setRen, a], by simp [setRen, b], by simp [setRen, c]⟩
  | tombChoose i =>
    apply orph_fixup; unfold tombDone; simp only [Orphan, setTomb]; refine ⟨?_, ?_, ?_⟩ <;> simp [a, b, c]
  | _ =>
    simp only [step]
    all_goals first
      | exact ho
      | (apply orph_fixup; simp only [Orphan, trapFocus, setRen, setTomb]; exact ⟨by simp [a], by simp [b], by simp [c]⟩)
      | exact ⟨by simp [setRen, a], by simp [setRen, b], by simp [setRen, c]⟩

/-- Hence an orphaned `askRomWarn` promise stays pending forever. -/
theorem orphan_forever {s : State} {n : Nat} (ho : Orphan s n) (es : List Event) :
    Orphan (es.foldl step s) n := by
  induction es generalizing s with
  | nil => exact ho
  | cons e es ih => exact ih (orphan_stable ho e)

/-! ## Focus restore holds when modals do not nest

The single trap slot is correct as long as no overlay opens while another is
up. `nests` names the three events that can open an overlay over another one
(a file drop, a sync reaching the tombstone prompt, a rename modal finishing
its load); every other opener is only reachable with nothing open (the
overlay covers the page). With those excluded, a modal is open only while it
owns the trap, and closing it always returns focus to an element outside any
modal: the one focused when it opened (for Settings/Update: their opener). -/

def nests (s : State) : Event → Bool
  | .dropSuspect | .syncTomb | .renameLoaded _ => anyOpen s
  | _ => false

inductive Reach1 : State → Prop
  | init : Reach1 init
  | step {s : State} (e : Event) : Reach1 s → en s e = true → nests s e = false → Reach1 (step s e)

theorem reach1_reachable {s : State} (h : Reach1 s) : Reachable s := by
  induction h with
  | init => exact .init
  | step e _ he _ ih => exact .step e ih he

def outside : El → Bool
  | .page | .menuBtn | .opener _ => true
  | _ => false

theorem anyOpen_false {s : State} (h : Inv s) (ha : anyOpen s = false) (o : Ov) :
    isOpen s o = false := by
  simp [anyOpen, anySync] at ha
  obtain ⟨⟨⟨hs, hu⟩, hw⟩, hr, ht⟩ := ha
  cases o with
  | settings => simp [hs]
  | update => simp [hu]
  | romWarn => simp [hw]
  | rename i =>
    rcases Nat.lt_or_ge i s.nextRen with hl | hl
    · simpa using hr i hl
    · simp [h.renFresh i hl]
  | tomb i =>
    rcases Nat.lt_or_ge i s.nextTomb with hl | hl
    · simpa using ht i hl
    · simp [h.tombFresh i hl]

structure Inv1 (s : State) : Prop where
  /-- Whatever is open owns the trap (so at most one overlay is open). -/
  openOwns : ∀ o, isOpen s o = true → s.owner = some o
  /-- The saved return target is outside every modal. -/
  retOut   : ∀ o, s.owner = some o → ∃ e, s.ret = some e ∧ outside e = true
  /-- Settings/Update return to their own opener. -/
  retSettings : s.owner = some .settings → s.ret = some (.opener .settings)
  retUpdate   : s.owner = some .update → s.ret = some (.opener .update)
  /-- Focus is inside the trap owner, or (no trap) outside every modal: never lost. -/
  focusIn  : ∀ o, s.owner = some o → s.focus = .inside o
  focusOut : s.owner = none → outside s.focus = true

theorem inv1_init : Inv1 init := by
  constructor <;> (try intro o) <;> (try cases o) <;> simp [init, isOpen, outside]

theorem inv1_congr {u v : State} (h : Inv1 u) (ho : v.owner = u.owner) (hr : v.ret = u.ret)
    (hf : v.focus = u.focus) (hopen : ∀ o, isOpen v o = isOpen u o) : Inv1 v := by
  obtain ⟨a1, a2, a3, a4, a5, a6⟩ := h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro o hv; rw [ho]; exact a1 o (by rw [← hopen]; exact hv)
  · intro o hv; rw [hr]; exact a2 o (by rw [← ho]; exact hv)
  · intro hv; rw [hr]; exact a3 (by rw [← ho]; exact hv)
  · intro hv; rw [hr]; exact a4 (by rw [← ho]; exact hv)
  · intro o hv; rw [hf]; exact a5 o (by rw [← ho]; exact hv)
  · intro hv; rw [hf]; exact a6 (by rw [← ho]; exact hv)

theorem fixup_id {u : State} (hi : Inv u) (h : Inv1 u) : fixup u = u := by
  unfold fixup
  split
  · rename_i o hfo
    cases hown : u.owner with
    | none => have := h.focusOut hown; rw [hfo] at this; simp [outside] at this
    | some o' =>
      have h1 := h.focusIn o' hown
      rw [hfo] at h1
      cases h1
      simp [hi.ownerOpen o hown]
  · rfl

theorem outside_visible (s : State) (e : El) (h : outside e = true) : visible s e = true := by
  cases e <;> simp_all [outside, visible]

/-- Closing overlay `x` (its flag already cleared in `t`) and releasing it keeps Inv1. -/
theorem inv1_close {s t : State} (i1 : Inv1 s) (x : Ov)
    (hx : isOpen t x = false) (hoth : ∀ o, o ≠ x → isOpen t o = isOpen s o)
    (hown : t.owner = s.owner) (hret : t.ret = s.ret) (hfoc : t.focus = s.focus) :
    Inv1 (releaseFocus x t) := by
  by_cases hsx : s.owner = some x
  · obtain ⟨e, he, heo⟩ := i1.retOut x hsx
    have hr : releaseFocus x t =
        { t with owner := none, ret := none, focus := if visible t e then e else .menuBtn } := by
      unfold releaseFocus; simp [hown, hsx, hret, he]
    rw [hr]
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro o ho
      have ho' : isOpen t o = true := by
        rw [← ho]; exact isOpen_congr rfl rfl rfl rfl rfl o
      by_cases hox : o = x
      · subst hox; rw [hx] at ho'; cases ho'
      · have := i1.openOwns o (by rw [← hoth o hox]; exact ho')
        rw [hsx] at this; cases this; exact absurd rfl hox
    · intro o h; cases h
    · intro h; cases h
    · intro h; cases h
    · intro o h; cases h
    · intro _
      simp [outside_visible t e heo, heo]
  · have hr : releaseFocus x t = t := by
      unfold releaseFocus; simp [hown, hsx]
    rw [hr]
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro o ho
      by_cases hox : o = x
      · subst hox; rw [hx] at ho; cases ho
      · rw [hown]; exact i1.openOwns o (by rw [← hoth o hox]; exact ho)
    · intro o h; rw [hret]; exact i1.retOut o (by rw [← hown]; exact h)
    · intro h; rw [hret]; exact i1.retSettings (by rw [← hown]; exact h)
    · intro h; rw [hret]; exact i1.retUpdate (by rw [← hown]; exact h)
    · intro o h; rw [hfoc]; exact i1.focusIn o (by rw [← hown]; exact h)
    · intro h; rw [hfoc]; exact i1.focusOut (by rw [← hown]; exact h)

/-- Everything closed: the precondition of every opener in Reach1. -/
theorem closed_facts {s : State} (hi : Inv s) (i1 : Inv1 s) (ha : anyOpen s = false) :
    s.owner = none ∧ outside s.focus = true := by
  have hc := anyOpen_false hi ha
  have hown : s.owner = none := by
    cases h : s.owner with
    | none => rfl
    | some o => have := hi.ownerOpen o h; rw [hc o] at this; cases this
  exact ⟨hown, i1.focusOut hown⟩

/-- Opening overlay `x` over nothing (trapFocus from an outside focus `f`). -/
theorem inv1_open {s t : State} (hi : Inv s) (ha : anyOpen s = false) (x : Ov)
    (f : El) (hf : outside f = true)
    (hx : isOpen t x = true) (hoth : ∀ o, o ≠ x → isOpen t o = isOpen s o)
    (hS : x = .settings → f = .opener .settings) (hU : x = .update → f = .opener .update) :
    Inv1 (trapFocus x { t with focus := f }) := by
  have hc := anyOpen_false hi ha
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro o ho
    by_cases hox : o = x
    · subst hox; rfl
    · have : isOpen t o = true := by
        rw [← ho]; exact (isOpen_congr rfl rfl rfl rfl rfl o).symm
      rw [hoth o hox, hc o] at this; cases this
  · intro o _; exact ⟨f, rfl, hf⟩
  · intro h; simp [trapFocus] at h; subst h; simp [trapFocus, hS rfl]
  · intro h; simp [trapFocus] at h; subst h; simp [trapFocus, hU rfl]
  · intro o h; simp [trapFocus] at h; subst h; rfl
  · intro h; simp [trapFocus] at h

section single
variable {s : State} (i1 : Inv1 s)
include i1

theorem inv1_closeSettings : Inv1 (closeSettings s) :=
  inv1_close i1 .settings (by simp [isOpen]) (by intro o ho; cases o <;> simp_all [isOpen]) rfl rfl rfl
theorem inv1_closeUpdate : Inv1 (closeUpdate s) :=
  inv1_close i1 .update (by simp [isOpen]) (by intro o ho; cases o <;> simp_all [isOpen]) rfl rfl rfl
theorem inv1_settle : Inv1 (settleRomWarn s) := by
  have h := inv1_close i1 .romWarn (t := { s with warnResolve := none, romWarnOpen := false })
    (by simp [isOpen]) (by intro o ho; cases o <;> simp_all [isOpen]) rfl rfl rfl
  unfold settleRomWarn
  cases s.warnResolve with
  | none => exact h
  | some n => exact inv1_congr h rfl rfl rfl (fun o => isOpen_congr rfl rfl rfl rfl rfl o)
theorem inv1_closeRomWarn : Inv1 (closeRomWarn s) := by
  unfold closeRomWarn; split
  · exact inv1_settle i1
  · exact i1
theorem inv1_renameClose (i : Nat) : Inv1 (renameClose i s) :=
  inv1_close i1 (.rename i) (by simp [isOpen, setRen])
    (by intro o ho; cases o <;> simp_all [isOpen, setRen]) rfl rfl rfl
theorem inv1_tombDone (i : Nat) : Inv1 (tombDone i s) := by
  have h := inv1_close i1 (.tomb i) (t := setTomb i { shown := false, settles := (s.tomb i).settles + 1 } s)
    (by simp [isOpen, setTomb]) (by intro o ho; cases o <;> simp_all [isOpen, setTomb]) rfl rfl rfl
  exact inv1_congr h rfl rfl rfl (fun o => isOpen_congr rfl rfl rfl rfl rfl o)
end single

theorem fx {u : State} (a : Inv u) (b : Inv1 u) : Inv1 (fixup u) := by rw [fixup_id a b]; exact b

theorem inv1_step {s : State} {e : Event} (hi : Inv s) (i1 : Inv1 s) (he : en s e = true)
    (hn : nests s e = false) : Inv1 (step s e) := by
  have hI := inv_step hi he
  cases e with
  | openSettings =>
    simp [en] at he
    have := inv1_open hi he .settings (.opener .settings) rfl (t := { s with settingsOpen := true })
      (by simp [isOpen]) (by intro o ho; cases o <;> simp_all [isOpen]) (fun _ => rfl) (by intro h; cases h)
    exact fx (inv_openSettings hi) this
  | openUpdate =>
    simp [en] at he
    have := inv1_open hi he .update (.opener .update) rfl (t := { s with updateOpen := true })
      (by simp [isOpen]) (by intro o ho; cases o <;> simp_all [isOpen]) (by intro h; cases h) (fun _ => rfl)
    exact fx (inv_openUpdate hi) this
  | dropSuspect =>
    simp [nests] at hn
    have hc := closed_facts hi i1 hn
    have := inv1_open hi hn .romWarn s.focus hc.2
      (t := { s with warnP := fun j => if j = s.nextWarn then .pending else s.warnP j,
                     nextWarn := s.nextWarn + 1, warnResolve := some s.nextWarn, romWarnOpen := true })
      (by simp [isOpen]) (by intro o ho; cases o <;> simp_all [isOpen]) (by intro h; cases h) (by intro h; cases h)
    exact fx (inv_askRomWarn hi) this
  | syncTomb =>
    simp [nests] at hn
    have hc := closed_facts hi i1 hn
    have := inv1_open hi hn (.tomb s.nextTomb) s.focus hc.2
      (t := setTomb s.nextTomb { shown := true, settles := 0 } { s with nextTomb := s.nextTomb + 1, tombWaiting := true })
      (by simp [isOpen, setTomb]) (by intro o ho; cases o <;> simp_all [isOpen, setTomb]) (by intro h; cases h) (by intro h; cases h)
    have e1 : { (setTomb s.nextTomb { shown := true, settles := 0 } { s with nextTomb := s.nextTomb + 1, tombWaiting := true }) with focus := s.focus } =
        setTomb s.nextTomb { shown := true, settles := 0 } { s with nextTomb := s.nextTomb + 1, tombWaiting := true } := rfl
    rw [e1] at this
    simp [en] at he
    exact fx (inv_syncTomb hi he.1) this
  | renameLoaded i =>
    simp [nests] at hn
    have hc := closed_facts hi i1 hn
    have := inv1_open hi hn (.rename i) s.focus hc.2
      (t := setRen i { s.ren i with phase := .shown } s)
      (by simp [isOpen, setRen]) (by intro o ho; cases o <;> simp_all [isOpen, setRen]) (by intro h; cases h) (by intro h; cases h)
    have e1 : { (setRen i { s.ren i with phase := .shown } s) with focus := s.focus } =
        setRen i { s.ren i with phase := .shown } s := rfl
    rw [e1] at this
    simp [en] at he
    exact fx (inv_renameLoaded hi i he) this
  | closeSettings => exact fx (inv_closeSettings hi) (inv1_closeSettings i1)
  | closeUpdate => exact fx (inv_closeUpdate hi) (inv1_closeUpdate i1)
  | romWarnLoad => exact fx (inv_settleRomWarn hi) (inv1_settle i1)
  | romWarnCancel => exact fx (inv_closeRomWarn hi) (inv1_closeRomWarn i1)
  | escGlobal =>
    have a1 := inv_closeSettings hi
    have b1 := inv1_closeSettings i1
    have a2 := inv_closeUpdate a1
    have b2 := inv1_closeUpdate b1
    exact fx (inv_closeRomWarn a2) (inv1_closeRomWarn b2)
  | escSync o =>
    cases o <;> simp [en, isSyncOv] at he
    · exact fx (inv_renameClose hi _ (ren_lt hi (by intro hc; simp [hc] at he))) (inv1_renameClose i1 _)
    · exact fx (inv_tombDone hi _ he) (inv1_tombDone i1 _)
  | syncStart => exact inv1_congr i1 rfl rfl rfl (fun o => isOpen_congr rfl rfl rfl rfl rfl o)
  | tombChoose i =>
    simp [en] at he
    exact fx (inv_tombDone hi i he) (inv1_tombDone i1 i)
  | renameMenu =>
    simp only [step]; split
    · exact i1
    · refine inv1_congr i1 rfl rfl rfl (fun o => ?_)
      cases o <;> simp [isOpen, setRen]
      split
      · subst_vars; simp [hi.renFresh _ (Nat.le_refl _)] <;> decide
      · rfl
  | renameLoadFail i =>
    simp [en] at he
    refine inv1_congr i1 rfl rfl rfl (fun o => ?_)
    cases o <;> simp [step, isOpen, setRen]
    split
    · subst_vars; simp [he] <;> decide
    · rfl
  | renameGo i =>
    refine inv1_congr i1 rfl rfl rfl (fun o => ?_)
    cases o <;> simp [step, isOpen, setRen]
    split
    · subst_vars; rfl
    · rfl
  | renameResult i ok =>
    simp [en] at he
    have hs' : Inv1 (setRen i { s.ren i with inflight := false } s) := by
      refine inv1_congr i1 rfl rfl rfl (fun o => ?_)
      cases o <;> simp [isOpen, setRen]
      split
      · subst_vars; rfl
      · rfl
    have hI' := inv_setInflight hi i he
    simp only [step]
    split
    · exact fx (inv_renameClose hI' i (by simpa [setRen] using ren_lt hi (by intro hc; simp [hc] at he)))
        (inv1_renameClose hs' i)
    · split
      · exact hs'
      · exact inv1_congr hs' rfl rfl rfl (fun o => isOpen_congr rfl rfl rfl rfl rfl o)
  | renameCancel i =>
    simp [en] at he
    exact fx (inv_renameClose hi i (ren_lt hi (by intro hc; simp [hc] at he))) (inv1_renameClose i1 i)

theorem inv1_reach {s : State} (h : Reach1 s) : Inv s ∧ Inv1 s := by
  induction h with
  | init => exact ⟨inv_init, inv1_init⟩
  | step e _ he hn ih => exact ⟨inv_step ih.1 he, inv1_step ih.1 ih.2 he hn⟩

/-- Without nesting, focus is never lost: with no modal open it is on an element
    outside every modal, and every open modal holds the trap. -/
theorem single_focus_never_lost {s : State} (h : Reach1 s) (hc : anyOpen s = false) :
    outside s.focus = true := by
  have ⟨hi, i1⟩ := inv1_reach h
  exact (closed_facts hi i1 hc).2

theorem single_open_trapped {s : State} (h : Reach1 s) (o : Ov) (ho : isOpen s o = true) :
    s.owner = some o := (inv1_reach h).2.openOwns o ho

/-- Without nesting, closing Settings returns focus to the control that opened it. -/
theorem single_settings_restores {s : State} (h : Reach1 s) (ho : s.settingsOpen = true) :
    (step s .closeSettings).focus = .opener .settings := by
  have ⟨hi, i1⟩ := inv1_reach h
  have hown : s.owner = some .settings := i1.openOwns .settings (by simp [ho])
  have hret := i1.retSettings hown
  have hI := inv_closeSettings hi
  have h1 := inv1_closeSettings i1
  simp only [step]
  rw [fixup_id hI h1]
  simp [closeSettings, releaseFocus, hown, hret, visible]

end WebState.Modals
