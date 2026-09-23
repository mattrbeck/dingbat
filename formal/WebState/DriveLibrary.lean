/-
# The cross-device library on Google Drive (web/index.js)

Model of the Drive "library" file and the code that reads, merges and writes
it, at commit dd7ba741f:

* `mergeLibrary` (web/index.js 2508-2564): the pure join of two libraries,
  modelled line for line (`mergeLibrary` below), including JS `Map` insertion
  order and the stable sorts, because tie-breaking depends on both.
* the protocol around it: `flushSyncInner` (2706-2825), `pullSyncInner`
  (2920-3070), `deleteGameEverywhere` (3149-3163), `renameGame` (3252-3367),
  `applyRemoteRename` (2832-2903), `bumpRecentIndex` (4424-4445) via import
  (`addRecentRom` 4460) and play (`touchRecent` 4479), and `downloadGame`
  (3074-3107). Every `await` that matters is an event boundary.

Layer 1 (pure merge) proves what *is* a semilattice (the recents join, the
tombstone join, the rename-marker join, and the whole merge on libraries
without rename markers, on timestamps), what survives a merge (tombstones,
markers), where outputs come from (no tombstone or marker is invented), and
refutes CRDT-ness of the whole merge with concrete libraries.

Layer 2 (protocol) models two devices and Drive with no compare-and-swap
(`driveUploadFile` 2143 sends no If-Match / revision precondition), proves the
Drive lost-update race only delays a tombstone, and refutes the stronger
properties the code means to keep with concrete event traces (`bug_*`).
Layer 2c re-runs the failing traces against the suggested JS fixes.

Results in one place:
* semilattice, no markers: `merge_comm_noren`, `merge_idem_noren`,
  `merge_assoc_ts_noren`, `merge_absorb_ts_noren`; marker join:
  `joinN_assoc`, `joinN_idem`, `joinN_comm_of_noTie`, `buildRen_sem`.
* merge, markers included: `merge_tomb_sub`, `merge_ren_sub`,
  `merge_tomb_survives`; refuted: `bug_merge_not_idempotent`,
  `bug_merge_tie_not_comm`, `bug_merge_imp_not_assoc`.
* protocol: `step_tombs`, `tomb_origin`, `tomb_lost_forever`,
  `step_other_dev`, `resync_reasserts_tomb`, `rename_moves_everything`,
  `race_delays_tomb`; refuted: `bug_delete_during_flush_resurrects` (+
  `_permanent`), `bug_delete_during_pull_resurrects`,
  `bug_import_during_pull_orphans`, `bug_rename_during_pull_orphans`,
  `bug_rename_undo_oscillates`, `bug_rename_undo_loses_save`,
  `bug_rename_undo_freezes_recency`, `bug_rename_into_retired_name`.

## Abstractions (and why they do not affect the stated properties)

* Game names, timestamps, blobs are `Nat`. `imp = 0` is "no imp field";
  JS `e.ts || 0` / `e.imp || 0` make absent and 0 the same.
* JSON null/garbage filtering (`!e?.name`, non-array fields) is dropped:
  every modelled record is well formed.
* All devices share one clock `now` (Date.now()); real skew only adds cases.
* Per-game keys are two Drive kinds: 0 = `rom:`, 1 = `save:` (the saves,
  state and statemeta keys all behave like `save:` in every modelled branch;
  `art:`/`frame:`/`auto`/cheats are not needed for any stated property).
* A flush's three queue passes (renames, deletes, uploads) are one event,
  deciding against Drive as it is at that moment; the delete-stamp outrank
  (`delTs`) is not modelled (it only drops deletes, never adds tombstones).
* A pull's rename pass (one `dbMoveKeys` transaction per marker) is one
  event; the per-game save/picture download pass and the ROM byte budget are
  not modelled. `renPending` (a link session blocking a migration) is never
  set, as no link session is modelled.
* `deleteGameEverywhere`, `renameGame`, import and play are atomic events.
  The JS interleaves their awaits too; making them atomic only removes
  interleavings, so every `bug_*` below is still reachable, and the
  invariants proved are about merge/queue code that does not depend on it.
* The flush trigger guard (`pendingCount() || tomb || ren`) is dropped: any
  save a player makes queues an upload, so a flush can always be triggered.
* The "removed on another device" modal (`confirmTombstones` 3559) is the
  `restore` flag of `pullTombs`; the traces take "Continue". The wrappers
  `deleteGameAction` (1920) and `downloadGameAction` (1880) add only an
  unload and toasts. "Remove from this device" (3114) raises no tombstone
  and does not touch the library, so it is not an event here.
* The Drive listing is taken as complete. (Read, not modelled:
  `driveListAll` 2100 asks for one page of 1000 and ignores `nextPageToken`.)
-/

namespace WebState.DriveLibrary

/-! ## Records -/

/-- A `recents` entry `{ name, ts, imp? }`. -/
structure Entry where
  name : Nat
  ts : Nat
  imp : Nat
deriving DecidableEq, Repr

/-- A tombstone `{ name, ts }`. -/
structure Tomb where
  name : Nat
  ts : Nat
deriving DecidableEq, Repr

/-- A rename marker `{ from, to, ts }`. -/
structure Ren where
  src : Nat
  dst : Nat
  ts : Nat
deriving DecidableEq, Repr

/-- The Drive file "library": `{ recents, tomb, ren }` (web/index.js 2278). -/
structure Lib where
  recents : List Entry
  tomb : List Tomb
  ren : List Ren
deriving DecidableEq, Repr

def Lib.empty : Lib := ⟨[], [], []⟩

/-! ## JS `Map` with insertion order -/

/-- A JS `Map` keyed by name: the key list in insertion order plus lookup. -/
structure JMap (V : Type) where
  keys : List Nat
  get : Nat → Option V

namespace JMap
variable {V : Type}

def empty : JMap V := ⟨[], fun _ => none⟩

/-- `Map.prototype.set`: an existing key keeps its position. -/
def set (m : JMap V) (k : Nat) (v : V) : JMap V :=
  ⟨if (m.get k).isSome then m.keys else m.keys ++ [k],
   fun n => if n = k then some v else m.get n⟩

/-- `Map.prototype.delete`. -/
def del (m : JMap V) (k : Nat) : JMap V :=
  ⟨m.keys.filter (fun n => n != k), fun n => if n = k then none else m.get n⟩

/-- `[...m.values()]`. -/
def values (m : JMap V) : List V := m.keys.filterMap m.get

@[simp] theorem get_empty (n : Nat) : (empty : JMap V).get n = none := rfl
@[simp] theorem get_set (m : JMap V) (k n : Nat) (v : V) :
    (m.set k v).get n = if n = k then some v else m.get n := rfl
@[simp] theorem get_del (m : JMap V) (k n : Nat) :
    (m.del k).get n = if n = k then none else m.get n := rfl

/-- Well formed: every bound key is listed once, every listed key is bound. -/
def WF (m : JMap V) : Prop :=
  m.keys.Nodup ∧ ∀ n, (m.get n).isSome = true ↔ n ∈ m.keys

theorem wf_empty : (empty : JMap V).WF := by
  refine ⟨List.nodup_nil, ?_⟩
  intro n; simp [empty]

theorem wf_set {m : JMap V} (h : m.WF) (k : Nat) (v : V) : (m.set k v).WF := by
  obtain ⟨hnd, hmem⟩ := h
  refine ⟨?_, ?_⟩
  · simp only [set]
    split
    · exact hnd
    · rename_i hk
      rw [List.nodup_append]
      refine ⟨hnd, List.nodup_cons.2 ⟨List.not_mem_nil, List.nodup_nil⟩, ?_⟩
      intro a ha b hb
      simp at hb
      subst hb
      intro hab; subst hab
      exact hk ((hmem a).2 ha)
  · intro n
    simp only [set]
    by_cases hn : n = k
    · subst hn; simp
      split
      · rename_i hs; exact (hmem n).1 hs
      · simp
    · simp [hn]
      split
      · exact hmem n
      · rw [hmem n]; simp [hn]

theorem wf_del {m : JMap V} (h : m.WF) (k : Nat) : (m.del k).WF := by
  obtain ⟨hnd, hmem⟩ := h
  refine ⟨hnd.filter _, ?_⟩
  intro n
  by_cases hn : n = k
  · subst hn; simp [del]
  · simp [del, hn, hmem n]

theorem mem_values {m : JMap V} {x : V} (hx : x ∈ m.values) : ∃ n, m.get n = some x := by
  simp only [values, List.mem_filterMap] at hx
  obtain ⟨n, _, h⟩ := hx
  exact ⟨n, h⟩

theorem values_of_get {m : JMap V} (h : m.WF) {n : Nat} {x : V} (hx : m.get n = some x) :
    x ∈ m.values := by
  simp only [values, List.mem_filterMap]
  exact ⟨n, (h.2 n).1 (by simp [hx]), hx⟩

end JMap

/-! ## Stable sorts (`Array.prototype.sort` is stable since ES2019) -/

/-- Insert for the descending sort `(x, y) => y.ts - x.ts` (web/index.js 2560). -/
def insDesc (x : Entry) : List Entry → List Entry
  | [] => [x]
  | y :: ys => if y.ts ≤ x.ts then x :: y :: ys else y :: insDesc x ys

def sortDesc (l : List Entry) : List Entry := l.foldr insDesc []

/-- Insert for the ascending sort `(x, y) => x.ts - y.ts` (web/index.js 2531). -/
def insAsc (x : Ren) : List Ren → List Ren
  | [] => [x]
  | y :: ys => if x.ts ≤ y.ts then x :: y :: ys else y :: insAsc x ys

def sortAsc (l : List Ren) : List Ren := l.foldr insAsc []

theorem mem_insDesc {x y : Entry} {l : List Entry} : y ∈ insDesc x l ↔ y = x ∨ y ∈ l := by
  induction l with
  | nil => simp [insDesc]
  | cons z zs ih =>
    simp only [insDesc]; split <;> simp [ih, or_left_comm]

theorem mem_sortDesc {y : Entry} {l : List Entry} : y ∈ sortDesc l ↔ y ∈ l := by
  induction l with
  | nil => simp [sortDesc]
  | cons z zs ih =>
    simp only [sortDesc, List.foldr] at *
    rw [mem_insDesc, ih]; simp

theorem mem_insAsc {x y : Ren} {l : List Ren} : y ∈ insAsc x l ↔ y = x ∨ y ∈ l := by
  induction l with
  | nil => simp [insAsc]
  | cons z zs ih =>
    simp only [insAsc]; split <;> simp [ih, or_left_comm]

theorem mem_sortAsc {y : Ren} {l : List Ren} : y ∈ sortAsc l ↔ y ∈ l := by
  induction l with
  | nil => simp [sortAsc]
  | cons z zs ih =>
    simp only [sortAsc, List.foldr] at *
    rw [mem_insAsc, ih]; simp

/-- A fold whose step is right-commutative does not see the descending sort. -/
theorem foldl_insDesc {β : Type} (f : β → Entry → β)
    (hf : ∀ b x y, f (f b x) y = f (f b y) x) (x : Entry) :
    ∀ (l : List Entry) (b : β), (insDesc x l).foldl f b = (x :: l).foldl f b := by
  intro l
  induction l with
  | nil => intro b; rfl
  | cons y ys ih =>
    intro b
    simp only [insDesc]
    split
    · rfl
    · simp only [List.foldl]
      rw [ih]; simp only [List.foldl]; rw [hf]

theorem foldl_sortDesc {β : Type} (f : β → Entry → β)
    (hf : ∀ b x y, f (f b x) y = f (f b y) x) :
    ∀ (l : List Entry) (b : β), (sortDesc l).foldl f b = l.foldl f b := by
  intro l
  induction l with
  | nil => intro b; rfl
  | cons y ys ih =>
    intro b
    show (insDesc y (sortDesc ys)).foldl f b = _
    rw [foldl_insDesc f hf]
    simp only [List.foldl]
    exact ih _

/-! ## `mergeLibrary` (web/index.js 2511-2564), line for line -/

/-- One pass of the recents loop (2511-2521): the newest play wins the entry;
the newest import claim from either side is kept alongside it. -/
def recStep (m : JMap Entry) (e : Entry) : JMap Entry :=
  let prev := m.get e.name
  let imp := max (match prev with | some p => p.imp | none => 0) e.imp
  let m1 := match prev with
    | none => m.set e.name ⟨e.name, e.ts, 0⟩
    | some p => if e.ts > p.ts then m.set e.name ⟨e.name, e.ts, 0⟩ else m
  if imp ≠ 0 then
    match m1.get e.name with
    | some x => m1.set e.name { x with imp := imp }
    | none => m1
  else m1

/-- The marker loop (2523-2529): newest marker per old name wins; a tie keeps
the one seen first. Self-renames are skipped. -/
def renStep (m : JMap Ren) (r : Ren) : JMap Ren :=
  if r.src = r.dst then m else
  match m.get r.src with
  | none => m.set r.src r
  | some p => if r.ts > p.ts then m.set r.src r else m

/-- One marker applied (2531-2547), oldest first. `reimported` spends it. -/
def applyRen (st : JMap Entry × JMap Ren) (r : Ren) : JMap Entry × JMap Ren :=
  match st.1.get r.src with
  | none => st
  | some e =>
    if e.imp > r.ts then (st.1, st.2.del r.src)
    else
      let bn := st.1.del r.src
      let bn' := match bn.get r.dst with
        | none => bn.set r.dst ⟨r.dst, e.ts, e.imp⟩
        | some t => if t.ts < e.ts then bn.set r.dst ⟨r.dst, e.ts, e.imp⟩ else bn
      (bn', st.2)

/-- The tombstone loop (2549-2553): newest per name, a tie keeps the first. -/
def tombStep (m : JMap Tomb) (t : Tomb) : JMap Tomb :=
  match m.get t.name with
  | none => m.set t.name t
  | some p => if t.ts > p.ts then m.set t.name t else m

/-- The prune loop (2554-2558): a newer entry supersedes the tombstone,
otherwise the tombstone removes the entry. -/
def pruneStep (st : JMap Entry × JMap Tomb) (n : Nat) : JMap Entry × JMap Tomb :=
  match st.2.get n with
  | none => st
  | some t =>
    match st.1.get n with
    | some e => if e.ts > t.ts then (st.1, st.2.del n) else (st.1.del n, st.2)
    | none => (st.1.del n, st.2)

def buildRecents (l : List Entry) : JMap Entry := l.foldl recStep JMap.empty
def buildRen (l : List Ren) : JMap Ren := l.foldl renStep JMap.empty
def buildTomb (l : List Tomb) : JMap Tomb := l.foldl tombStep JMap.empty

/-- The recents after the markers have been applied, and the surviving markers. -/
def afterRen (a b : Lib) : JMap Entry × JMap Ren :=
  let rm := buildRen (a.ren ++ b.ren)
  (sortAsc rm.values).foldl applyRen (buildRecents (a.recents ++ b.recents), rm)

def afterPrune (a b : Lib) : JMap Entry × JMap Tomb :=
  let tm := buildTomb (a.tomb ++ b.tomb)
  tm.keys.foldl pruneStep ((afterRen a b).1, tm)

/-- `mergeLibrary(a, b)`. -/
def mergeLibrary (a b : Lib) : Lib :=
  ⟨sortDesc (afterPrune a b).1.values, (afterPrune a b).2.values, (afterRen a b).2.values⟩


/-! ## Layer 1a: what the merge means, name by name

`semR l n` is what a list of recents entries says about name `n`: the newest
`ts` and the newest `imp` among entries named `n` (none if there are none).
`semT` is the same for tombstones. These are the *meanings* the JS maps
compute; the lemmas below show `recStep`/`tombStep` compute exactly them. -/

/-- Join of two `(ts, imp)` claims: componentwise max. -/
def joinO : Option (Nat × Nat) → Option (Nat × Nat) → Option (Nat × Nat)
  | none, y => y
  | x, none => x
  | some p, some q => some (max p.1 q.1, max p.2 q.2)

def semStep (n : Nat) (acc : Option (Nat × Nat)) (e : Entry) : Option (Nat × Nat) :=
  if e.name = n then joinO acc (some (e.ts, e.imp)) else acc

def semR (l : List Entry) (n : Nat) : Option (Nat × Nat) := l.foldl (semStep n) none

def projE (x : Option Entry) : Option (Nat × Nat) := x.map (fun e => (e.ts, e.imp))

/-- Join of two tombstone claims: max. -/
def joinT : Option Nat → Option Nat → Option Nat
  | none, y => y
  | x, none => x
  | some p, some q => some (max p q)

def semTStep (n : Nat) (acc : Option Nat) (t : Tomb) : Option Nat :=
  if t.name = n then joinT acc (some t.ts) else acc

def semT (l : List Tomb) (n : Nat) : Option Nat := l.foldl (semTStep n) none

def projT (x : Option Tomb) : Option Nat := x.map (·.ts)

theorem joinO_comm (x y : Option (Nat × Nat)) : joinO x y = joinO y x := by
  rcases x with _ | ⟨a, b⟩ <;> rcases y with _ | ⟨c, d⟩ <;> simp [joinO, Nat.max_comm]

theorem joinO_assoc (x y z : Option (Nat × Nat)) :
    joinO (joinO x y) z = joinO x (joinO y z) := by
  rcases x with _ | ⟨a, b⟩ <;> rcases y with _ | ⟨c, d⟩ <;> rcases z with _ | ⟨e, f⟩ <;>
    simp [joinO, Nat.max_assoc]

theorem joinO_idem (x : Option (Nat × Nat)) : joinO x x = x := by
  rcases x with _ | ⟨a, b⟩ <;> simp [joinO]

@[simp] theorem joinO_none_left (x : Option (Nat × Nat)) : joinO none x = x := by
  cases x <;> rfl
@[simp] theorem joinO_none_right (x : Option (Nat × Nat)) : joinO x none = x := by
  cases x <;> rfl

theorem joinT_comm (x y : Option Nat) : joinT x y = joinT y x := by
  rcases x with _ | a <;> rcases y with _ | c <;> simp [joinT, Nat.max_comm]

theorem joinT_assoc (x y z : Option Nat) : joinT (joinT x y) z = joinT x (joinT y z) := by
  rcases x with _ | a <;> rcases y with _ | c <;> rcases z with _ | e <;>
    simp [joinT, Nat.max_assoc]

theorem joinT_idem (x : Option Nat) : joinT x x = x := by
  rcases x with _ | a <;> simp [joinT]

@[simp] theorem joinT_none_left (x : Option Nat) : joinT none x = x := by cases x <;> rfl
@[simp] theorem joinT_none_right (x : Option Nat) : joinT x none = x := by cases x <;> rfl

/-- Names stored in a map match their keys. -/
def KeyOK {V : Type} (key : V → Nat) (m : JMap V) : Prop := ∀ k x, m.get k = some x → key x = k
abbrev NameOK (m : JMap Entry) : Prop := KeyOK Entry.name m

theorem keyOK_empty {V : Type} (key : V → Nat) : KeyOK key (JMap.empty : JMap V) := by
  intro k x h; simp at h

theorem keyOK_del {V : Type} {key : V → Nat} {m : JMap V} (h : KeyOK key m) (k : Nat) :
    KeyOK key (m.del k) := by
  intro n x hx
  by_cases hn : n = k <;> simp [hn] at hx
  exact h _ _ hx

theorem keyOK_set {V : Type} {key : V → Nat} {m : JMap V} (h : KeyOK key m) (k : Nat) (v : V)
    (hv : key v = k) : KeyOK key (m.set k v) := by
  intro n x hx
  by_cases hn : n = k <;> simp [hn] at hx
  · subst hx; exact hn ▸ hv
  · exact h _ _ hx

theorem recStep_get (m : JMap Entry) (e : Entry) (n : Nat) :
    projE ((recStep m e).get n) = semStep n (projE (m.get n)) e := by
  unfold recStep semStep
  cases hm : m.get e.name with
  | none =>
    by_cases hn : e.name = n
    · subst hn
      by_cases hi : e.imp = 0 <;> simp [hm, hi, projE, joinO]
    · have : n ≠ e.name := fun h => hn h.symm
      by_cases hi : e.imp = 0 <;> simp [hi, this, hn]
  | some p =>
    by_cases hn : e.name = n
    · subst hn
      by_cases hlt : e.ts > p.ts
      · by_cases hi : max p.imp e.imp = 0
        · simp [hm, hi, hlt, projE, joinO]; omega
        · simp [hm, hi, hlt, projE, joinO]; omega
      · by_cases hi : max p.imp e.imp = 0
        · simp [hm, hi, hlt, projE, joinO]; omega
        · simp [hm, hi, hlt, projE, joinO]; omega
    · have : n ≠ e.name := fun h => hn h.symm
      by_cases hlt : e.ts > p.ts <;> by_cases hi : max p.imp e.imp = 0 <;>
        simp [hm, hi, hlt, this, hn]

theorem recStep_nameOK {m : JMap Entry} (h : NameOK m) (e : Entry) : NameOK (recStep m e) := by
  intro k x hx
  unfold recStep at hx
  cases hm : m.get e.name with
  | none =>
    by_cases hi : e.imp = 0 <;> by_cases hk : k = e.name <;> simp [hm, hi, hk] at hx <;>
      first | (subst hx; simp [hk]) | exact h k x hx
  | some p =>
    by_cases hlt : e.ts > p.ts <;> by_cases hi : max p.imp e.imp = 0 <;>
      by_cases hk : k = e.name <;> simp [hm, hi, hlt, hk] at hx <;>
      first | (subst hx; simp [hk]) | exact h k x hx | (rw [← hx]; simp [hk]) |
        (subst hk; rw [← hx]; exact h _ _ hm) | (subst hk; exact h _ _ (hm ▸ hx ▸ rfl)) |
        (subst hk; obtain ⟨y, hy, rfl⟩ := hx; simp [h _ _ hy]) | exact h _ _ hm
    all_goals exact h _ _ hm

theorem recStep_wf {m : JMap Entry} (h : m.WF) (e : Entry) : (recStep m e).WF := by
  unfold recStep
  simp only
  repeat' split
  all_goals (repeat' apply JMap.wf_set)
  all_goals exact h

theorem foldl_recStep_get (l : List Entry) : ∀ (m : JMap Entry) (n : Nat),
    projE ((l.foldl recStep m).get n) = l.foldl (semStep n) (projE (m.get n)) := by
  induction l with
  | nil => intro m n; rfl
  | cons e l ih => intro m n; simp only [List.foldl]; rw [ih, recStep_get]

theorem foldl_recStep_wf (l : List Entry) : ∀ (m : JMap Entry), m.WF → NameOK m →
    (l.foldl recStep m).WF ∧ NameOK (l.foldl recStep m) := by
  induction l with
  | nil => intro m h1 h2; exact ⟨h1, h2⟩
  | cons e l ih => intro m h1 h2; exact ih _ (recStep_wf h1 e) (recStep_nameOK h2 e)

theorem foldl_semStep (n : Nat) (l : List Entry) :
    ∀ acc, l.foldl (semStep n) acc = joinO acc (semR l n) := by
  induction l with
  | nil => intro acc; simp [semR]
  | cons e l ih =>
    intro acc
    simp only [semR, List.foldl]
    rw [ih (semStep n acc e), ih (semStep n none e)]
    unfold semStep; split <;> simp [joinO_assoc]

theorem semR_append (a b : List Entry) (n : Nat) :
    semR (a ++ b) n = joinO (semR a n) (semR b n) := by
  simp only [semR, List.foldl_append]
  exact foldl_semStep n b _

theorem semStep_rc (n : Nat) (b : Option (Nat × Nat)) (x y : Entry) :
    semStep n (semStep n b x) y = semStep n (semStep n b y) x := by
  unfold semStep
  by_cases hx : x.name = n <;> by_cases hy : y.name = n <;> simp [hx, hy]
  rw [joinO_assoc, joinO_comm (some (x.ts, x.imp)), ← joinO_assoc]

theorem foldl_filterMap_semStep (g : Nat → Option Entry) (n : Nat) :
    ∀ (L : List Nat), L.Nodup → (∀ k x, g k = some x → x.name = k) → ∀ acc,
      (L.filterMap g).foldl (semStep n) acc = if n ∈ L then joinO acc (projE (g n)) else acc := by
  intro L
  induction L with
  | nil => intro _ _ acc; simp
  | cons k ks ih =>
    intro hnd hg acc
    have hk : k ∉ ks := (List.nodup_cons.1 hnd).1
    have hnd' := (List.nodup_cons.1 hnd).2
    cases hgk : g k with
    | none =>
      simp only [List.filterMap_cons, hgk]
      rw [ih hnd' hg]
      by_cases hn : n = k
      · subst hn; simp [hk, hgk, projE]
      · simp [hn]
    | some x =>
      simp only [List.filterMap_cons, hgk, List.foldl]
      rw [ih hnd' hg]
      have hxn := hg k x hgk
      by_cases hn : n = k
      · subst hn; simp [hk, hgk, projE, semStep, hxn]
      · have : x.name ≠ n := by rw [hxn]; exact fun h => hn h.symm
        simp [hn, semStep, this]

theorem semR_values {m : JMap Entry} (hw : m.WF) (hn : NameOK m) (n : Nat) :
    semR m.values n = projE (m.get n) := by
  unfold semR JMap.values
  rw [foldl_filterMap_semStep m.get n m.keys hw.1 hn]
  split
  · simp
  · rename_i hk
    have : m.get n = none := by
      cases h : m.get n with
      | none => rfl
      | some v => exact absurd ((hw.2 n).1 (by simp [h])) hk
    simp [this, projE]

theorem semR_sortDesc (l : List Entry) (n : Nat) : semR (sortDesc l) n = semR l n := by
  unfold semR
  exact foldl_sortDesc (semStep n) (semStep_rc n) l none

/-! ### Tombstones, the same way -/

theorem tombStep_get (m : JMap Tomb) (t : Tomb) (n : Nat) :
    projT ((tombStep m t).get n) = semTStep n (projT (m.get n)) t := by
  unfold tombStep semTStep
  cases hm : m.get t.name with
  | none =>
    by_cases hn : t.name = n
    · subst hn; simp [hm, projT]
    · have : n ≠ t.name := fun h => hn h.symm
      simp [this, hn]
  | some p =>
    by_cases hn : t.name = n
    · subst hn
      by_cases hlt : t.ts > p.ts
      · simp [hm, hlt, projT, joinT]; omega
      · simp [hm, hlt, projT, joinT]; omega
    · have : n ≠ t.name := fun h => hn h.symm
      by_cases hlt : t.ts > p.ts <;> simp [hlt, this, hn]

theorem tombStep_ok {m : JMap Tomb} (h1 : m.WF) (h2 : KeyOK Tomb.name m) (t : Tomb) :
    (tombStep m t).WF ∧ KeyOK Tomb.name (tombStep m t) := by
  unfold tombStep
  split
  · exact ⟨JMap.wf_set h1 _ _, keyOK_set h2 _ _ rfl⟩
  · split
    · exact ⟨JMap.wf_set h1 _ _, keyOK_set h2 _ _ rfl⟩
    · exact ⟨h1, h2⟩

theorem foldl_tombStep (l : List Tomb) : ∀ (m : JMap Tomb) (n : Nat),
    projT ((l.foldl tombStep m).get n) = l.foldl (semTStep n) (projT (m.get n)) := by
  induction l with
  | nil => intro m n; rfl
  | cons e l ih => intro m n; simp only [List.foldl]; rw [ih, tombStep_get]

theorem foldl_tombStep_ok (l : List Tomb) : ∀ (m : JMap Tomb), m.WF → KeyOK Tomb.name m →
    (l.foldl tombStep m).WF ∧ KeyOK Tomb.name (l.foldl tombStep m) := by
  induction l with
  | nil => intro m h1 h2; exact ⟨h1, h2⟩
  | cons e l ih =>
    intro m h1 h2
    obtain ⟨a, b⟩ := tombStep_ok h1 h2 e
    exact ih _ a b

theorem foldl_semTStep (n : Nat) (l : List Tomb) :
    ∀ acc, l.foldl (semTStep n) acc = joinT acc (semT l n) := by
  induction l with
  | nil => intro acc; simp [semT]
  | cons e l ih =>
    intro acc
    simp only [semT, List.foldl]
    rw [ih (semTStep n acc e), ih (semTStep n none e)]
    unfold semTStep; split <;> simp [joinT_assoc]

theorem semT_append (a b : List Tomb) (n : Nat) :
    semT (a ++ b) n = joinT (semT a n) (semT b n) := by
  simp only [semT, List.foldl_append]
  exact foldl_semTStep n b _

theorem foldl_filterMap_semTStep (g : Nat → Option Tomb) (n : Nat) :
    ∀ (L : List Nat), L.Nodup → (∀ k x, g k = some x → x.name = k) → ∀ acc,
      (L.filterMap g).foldl (semTStep n) acc = if n ∈ L then joinT acc (projT (g n)) else acc := by
  intro L
  induction L with
  | nil => intro _ _ acc; simp
  | cons k ks ih =>
    intro hnd hg acc
    have hk : k ∉ ks := (List.nodup_cons.1 hnd).1
    have hnd' := (List.nodup_cons.1 hnd).2
    cases hgk : g k with
    | none =>
      simp only [List.filterMap_cons, hgk]
      rw [ih hnd' hg]
      by_cases hn : n = k
      · subst hn; simp [hk, hgk, projT]
      · simp [hn]
    | some x =>
      simp only [List.filterMap_cons, hgk, List.foldl]
      rw [ih hnd' hg]
      have hxn := hg k x hgk
      by_cases hn : n = k
      · subst hn; simp [hk, hgk, projT, semTStep, hxn]
      · have : x.name ≠ n := by rw [hxn]; exact fun h => hn h.symm
        simp [hn, semTStep, this]

theorem semT_values {m : JMap Tomb} (hw : m.WF) (hn : KeyOK Tomb.name m) (n : Nat) :
    semT m.values n = projT (m.get n) := by
  unfold semT JMap.values
  rw [foldl_filterMap_semTStep m.get n m.keys hw.1 hn]
  split
  · simp
  · rename_i hk
    have : m.get n = none := by
      cases h : m.get n with
      | none => rfl
      | some v => exact absurd ((hw.2 n).1 (by simp [h])) hk
    simp [this, projT]

/-! ### The prune loop, name by name -/

def pruneAt (e : Option Entry) (t : Option Tomb) : Option Entry × Option Tomb :=
  match t with
  | none => (e, none)
  | some tt =>
    match e with
    | some x => if x.ts > tt.ts then (some x, none) else (none, some tt)
    | none => (none, some tt)

theorem pruneStep_get (st : JMap Entry × JMap Tomb) (k n : Nat) :
    ((pruneStep st k).1.get n, (pruneStep st k).2.get n) =
      if n = k then pruneAt (st.1.get n) (st.2.get n) else (st.1.get n, st.2.get n) := by
  unfold pruneStep
  by_cases hn : n = k
  · subst hn
    cases h2 : st.2.get n with
    | none => simp [h2, pruneAt]
    | some t =>
      cases h1 : st.1.get n with
      | none => simp [h2, pruneAt]
      | some e => by_cases hlt : e.ts > t.ts <;> simp [h1, h2, hlt, pruneAt]
  · cases h2 : st.2.get k with
    | none => simp [hn]
    | some t =>
      cases h1 : st.1.get k with
      | none => simp [hn]
      | some e => by_cases hlt : e.ts > t.ts <;> simp [hlt, hn]

theorem foldl_pruneStep_get (n : Nat) : ∀ (L : List Nat), L.Nodup →
    ∀ st : JMap Entry × JMap Tomb,
      ((L.foldl pruneStep st).1.get n, (L.foldl pruneStep st).2.get n) =
        if n ∈ L then pruneAt (st.1.get n) (st.2.get n) else (st.1.get n, st.2.get n) := by
  intro L
  induction L with
  | nil => intro _ st; simp
  | cons k ks ih =>
    intro hnd st
    have hk : k ∉ ks := (List.nodup_cons.1 hnd).1
    simp only [List.foldl]
    rw [ih (List.nodup_cons.1 hnd).2]
    have hs := pruneStep_get st k n
    by_cases hn : n = k
    · subst hn
      simp only [hk, ite_false, List.mem_cons, true_or, ite_true]
      simpa using hs
    · have hm : (n ∈ k :: ks) ↔ n ∈ ks := by simp [hn]
      simp only [hn, ite_false] at hs
      by_cases hin : n ∈ ks
      · simp only [hin, ite_true, hm]
        rw [Prod.mk.injEq] at hs
        rw [hs.1, hs.2]
      · simp only [hin, ite_false, hm]
        exact hs

theorem pruneStep_ok (st : JMap Entry × JMap Tomb) (k : Nat)
    (h : st.1.WF ∧ NameOK st.1 ∧ st.2.WF ∧ KeyOK Tomb.name st.2) :
    (pruneStep st k).1.WF ∧ NameOK (pruneStep st k).1 ∧ (pruneStep st k).2.WF ∧
      KeyOK Tomb.name (pruneStep st k).2 := by
  obtain ⟨a, b, c, d⟩ := h
  unfold pruneStep
  split
  · exact ⟨a, b, c, d⟩
  · split
    · split
      · exact ⟨a, b, JMap.wf_del c _, keyOK_del d _⟩
      · exact ⟨JMap.wf_del a _, keyOK_del b _, c, d⟩
    · exact ⟨JMap.wf_del a _, keyOK_del b _, c, d⟩

theorem foldl_pruneStep_ok : ∀ (L : List Nat) (st : JMap Entry × JMap Tomb),
    (st.1.WF ∧ NameOK st.1 ∧ st.2.WF ∧ KeyOK Tomb.name st.2) →
    ((L.foldl pruneStep st).1.WF ∧ NameOK (L.foldl pruneStep st).1 ∧
      (L.foldl pruneStep st).2.WF ∧ KeyOK Tomb.name (L.foldl pruneStep st).2) := by
  intro L
  induction L with
  | nil => intro st h; exact h
  | cons k ks ih => intro st h; exact ih _ (pruneStep_ok st k h)

/-! ### The merge without rename markers, name by name -/

/-- The prune rule on meanings: a newer play supersedes the tombstone,
otherwise the tombstone removes the entry. -/
def normP : Option (Nat × Nat) → Option Nat → Option (Nat × Nat) × Option Nat
  | some x, some t => if x.1 > t then (some x, none) else (none, some t)
  | e, t => (e, t)

/-- What a library says about one name: its recents claim and its tombstone. -/
def semL (L : Lib) (n : Nat) : Option (Nat × Nat) × Option Nat :=
  (semR L.recents n, semT L.tomb n)

theorem pruneAt_proj (e : Option Entry) (t : Option Tomb) :
    (projE (pruneAt e t).1, projT (pruneAt e t).2) = normP (projE e) (projT t) := by
  rcases t with _ | tt <;> rcases e with _ | x
  · rfl
  · rfl
  · rfl
  · by_cases h : x.ts > tt.ts <;> simp [pruneAt, projE, projT, normP, h]

theorem afterRen_noren (a b : Lib) (ha : a.ren = []) (hb : b.ren = []) :
    afterRen a b = (buildRecents (a.recents ++ b.recents), JMap.empty) := by
  simp [afterRen, ha, hb, buildRen, JMap.values, JMap.empty, sortAsc]

theorem merge_ren_noren (a b : Lib) (ha : a.ren = []) (hb : b.ren = []) :
    (mergeLibrary a b).ren = [] := by
  simp [mergeLibrary, afterRen_noren a b ha hb, JMap.values, JMap.empty]

theorem projE_buildRecents (l : List Entry) (n : Nat) :
    projE ((buildRecents l).get n) = semR l n := by
  unfold buildRecents semR
  rw [foldl_recStep_get]; rfl

theorem projT_buildTomb (l : List Tomb) (n : Nat) :
    projT ((buildTomb l).get n) = semT l n := by
  unfold buildTomb semT
  rw [foldl_tombStep]; rfl

/-- **The merge without markers, name by name**: join both sides' claims
(newest play, newest import, newest tombstone), then prune. -/
theorem merge_sem_noren (a b : Lib) (ha : a.ren = []) (hb : b.ren = []) (n : Nat) :
    semL (mergeLibrary a b) n =
      normP (joinO (semR a.recents n) (semR b.recents n))
            (joinT (semT a.tomb n) (semT b.tomb n)) := by
  have hR := foldl_recStep_wf (a.recents ++ b.recents) JMap.empty JMap.wf_empty (keyOK_empty _)
  have hT := foldl_tombStep_ok (a.tomb ++ b.tomb) JMap.empty JMap.wf_empty (keyOK_empty _)
  have hP := foldl_pruneStep_ok (buildTomb (a.tomb ++ b.tomb)).keys
    (buildRecents (a.recents ++ b.recents), buildTomb (a.tomb ++ b.tomb)) ⟨hR.1, hR.2, hT.1, hT.2⟩
  have hG := foldl_pruneStep_get n (buildTomb (a.tomb ++ b.tomb)).keys hT.1.1
    (buildRecents (a.recents ++ b.recents), buildTomb (a.tomb ++ b.tomb))
  have hAP : afterPrune a b = (buildTomb (a.tomb ++ b.tomb)).keys.foldl pruneStep
      (buildRecents (a.recents ++ b.recents), buildTomb (a.tomb ++ b.tomb)) := by
    simp [afterPrune, afterRen_noren a b ha hb]
  have key : (((buildTomb (a.tomb ++ b.tomb)).keys.foldl pruneStep
      (buildRecents (a.recents ++ b.recents), buildTomb (a.tomb ++ b.tomb))).1.get n,
      ((buildTomb (a.tomb ++ b.tomb)).keys.foldl pruneStep
      (buildRecents (a.recents ++ b.recents), buildTomb (a.tomb ++ b.tomb))).2.get n) =
      pruneAt ((buildRecents (a.recents ++ b.recents)).get n) ((buildTomb (a.tomb ++ b.tomb)).get n) := by
    rw [hG]
    split
    · rfl
    · rename_i hk
      have : (buildTomb (a.tomb ++ b.tomb)).get n = none := by
        cases h : (buildTomb (a.tomb ++ b.tomb)).get n with
        | none => rfl
        | some v => exact absurd ((hT.1.2 n).1 (Option.isSome_iff_exists.mpr ⟨v, h⟩)) hk
      simp [this, pruneAt]
  simp only [semL, mergeLibrary]
  rw [semR_sortDesc, hAP, semR_values hP.1 hP.2.1, semT_values hP.2.2.1 hP.2.2.2]
  have h2 := congrArg (fun p => (projE p.1, projT p.2)) key
  simp only at h2
  rw [h2, pruneAt_proj, projE_buildRecents, projT_buildTomb, semR_append, semT_append]

/-- Without rename markers the merge is **commutative**, name by name. -/
theorem merge_comm_noren (a b : Lib) (ha : a.ren = []) (hb : b.ren = []) (n : Nat) :
    semL (mergeLibrary a b) n = semL (mergeLibrary b a) n := by
  rw [merge_sem_noren a b ha hb, merge_sem_noren b a hb ha, joinO_comm, joinT_comm]

theorem normP_normal (e : Option (Nat × Nat)) (t : Option Nat) :
    normP (normP e t).1 (normP e t).2 = normP e t := by
  rcases e with _ | ⟨x, i⟩ <;> rcases t with _ | tt
  · rfl
  · rfl
  · rfl
  · by_cases h : x > tt <;> simp [normP, h]

/-- Without markers the merge is **idempotent** on what it outputs. -/
theorem merge_idem_noren (a b : Lib) (ha : a.ren = []) (hb : b.ren = []) (n : Nat) :
    semL (mergeLibrary (mergeLibrary a b) (mergeLibrary a b)) n = semL (mergeLibrary a b) n := by
  have hm := merge_ren_noren a b ha hb
  rw [merge_sem_noren _ _ hm hm, joinO_idem, joinT_idem]
  have e := merge_sem_noren a b ha hb n
  have h1 : semR (mergeLibrary a b).recents n = (normP (joinO (semR a.recents n) (semR b.recents n))
      (joinT (semT a.tomb n) (semT b.tomb n))).1 := congrArg Prod.fst e
  have h2 : semT (mergeLibrary a b).tomb n = (normP (joinO (semR a.recents n) (semR b.recents n))
      (joinT (semT a.tomb n) (semT b.tomb n))).2 := congrArg Prod.snd e
  rw [e, h1, h2, normP_normal]

/-- The timestamps a library states about a name: newest live play, tombstone. -/
def tsOf (p : Option (Nat × Nat) × Option Nat) : Option Nat × Option Nat :=
  (p.1.map Prod.fst, p.2)

/-- The prune rule on timestamps alone. -/
def nf : Option Nat → Option Nat → Option Nat × Option Nat
  | some x, some t => if x > t then (some x, none) else (none, some t)
  | e, t => (e, t)

theorem tsOf_normP (e : Option (Nat × Nat)) (t : Option Nat) :
    tsOf (normP e t) = nf (e.map Prod.fst) t := by
  rcases e with _ | ⟨x, i⟩ <;> rcases t with _ | tt
  · rfl
  · rfl
  · rfl
  · by_cases h : x > tt <;> simp [normP, nf, tsOf, h]

theorem map_fst_joinO (x y : Option (Nat × Nat)) :
    (joinO x y).map Prod.fst = joinT (x.map Prod.fst) (y.map Prod.fst) := by
  rcases x with _ | ⟨a, b⟩ <;> rcases y with _ | ⟨c, d⟩ <;> rfl

/-- `Option Nat` as `Nat`: none is 0, `some x` is `x + 1`. Under it
`joinT` is `max` and `nf` is a plain `if`. -/
def enc : Option Nat → Nat
  | none => 0
  | some x => x + 1

theorem enc_inj {A B : Option Nat} (h : enc A = enc B) : A = B := by
  rcases A with _ | a <;> rcases B with _ | b <;> simp_all [enc]

theorem enc_joinT (A B : Option Nat) : enc (joinT A B) = max (enc A) (enc B) := by
  rcases A with _ | a <;> rcases B with _ | b <;> simp [enc, joinT] <;> omega

def nfN (e t : Nat) : Nat × Nat := if e > t then (e, 0) else (0, t)

theorem enc_nf (A B : Option Nat) :
    (enc (nf A B).1, enc (nf A B).2) = nfN (enc A) (enc B) := by
  rcases A with _ | a <;> rcases B with _ | b
  · rfl
  · simp [nf, nfN, enc]
  · simp [nf, nfN, enc]
  · by_cases h : a > b <;> simp [nf, nfN, enc, h] <;> omega

theorem nfN_absorb (a b z u : Nat) :
    nfN (max (nfN a b).1 z) (max (nfN a b).2 u) = nfN (max a z) (max b u) := by
  unfold nfN
  by_cases h1 : a > b
  · simp only [h1, ite_true]
    split <;> split <;> simp only [Prod.mk.injEq, true_and] <;> omega
  · simp only [h1, ite_false]
    split <;> split <;> simp only [Prod.mk.injEq, and_true] <;> omega

theorem nf_absorb (A B Z u : Option Nat) :
    nf (joinT (nf A B).1 Z) (joinT (nf A B).2 u) = nf (joinT A Z) (joinT B u) := by
  have key : (enc (nf (joinT (nf A B).1 Z) (joinT (nf A B).2 u)).1,
              enc (nf (joinT (nf A B).1 Z) (joinT (nf A B).2 u)).2) =
             (enc (nf (joinT A Z) (joinT B u)).1, enc (nf (joinT A Z) (joinT B u)).2) := by
    rw [enc_nf, enc_nf, enc_joinT, enc_joinT, enc_joinT, enc_joinT]
    have e := enc_nf A B
    rw [Prod.mk.injEq] at e
    rw [e.1, e.2]
    exact nfN_absorb _ _ _ _
  rw [Prod.mk.injEq] at key
  exact Prod.ext (enc_inj key.1) (enc_inj key.2)

theorem nf_assoc (X Y Z s t u : Option Nat) :
    nf (joinT (nf (joinT X Y) (joinT s t)).1 Z) (joinT (nf (joinT X Y) (joinT s t)).2 u) =
    nf (joinT X (nf (joinT Y Z) (joinT t u)).1) (joinT s (nf (joinT Y Z) (joinT t u)).2) := by
  rw [nf_absorb, joinT_comm X (nf (joinT Y Z) (joinT t u)).1,
    joinT_comm s (nf (joinT Y Z) (joinT t u)).2, nf_absorb,
    joinT_comm (joinT Y Z) X, joinT_comm (joinT t u) s, joinT_assoc, joinT_assoc]

theorem normP_assoc_ts (x y z : Option (Nat × Nat)) (s t u : Option Nat) :
    tsOf (normP (joinO (normP (joinO x y) (joinT s t)).1 z) (joinT (normP (joinO x y) (joinT s t)).2 u)) =
    tsOf (normP (joinO x (normP (joinO y z) (joinT t u)).1) (joinT s (normP (joinO y z) (joinT t u)).2)) := by
  have h1 : ∀ e t, (normP e t).1.map Prod.fst = (nf (e.map Prod.fst) t).1 := fun e t =>
    congrArg Prod.fst (tsOf_normP e t)
  have h2 : ∀ e t, (normP e t).2 = (nf (e.map Prod.fst) t).2 := fun e t =>
    congrArg Prod.snd (tsOf_normP e t)
  rw [tsOf_normP, tsOf_normP, map_fst_joinO, map_fst_joinO, h1, h1, h2, h2, map_fst_joinO,
    map_fst_joinO]
  exact nf_assoc _ _ _ _ _ _

/-- Without markers the merge is **associative** on timestamps: which games
exist and which are deleted, and as of when, does not depend on the order in
which libraries meet. (The `imp` mark is not: `bug_merge_imp_not_assoc`.) -/
theorem merge_assoc_ts_noren (a b c : Lib) (ha : a.ren = []) (hb : b.ren = []) (hc : c.ren = [])
    (n : Nat) :
    tsOf (semL (mergeLibrary (mergeLibrary a b) c) n) =
      tsOf (semL (mergeLibrary a (mergeLibrary b c)) n) := by
  have hab := merge_ren_noren a b ha hb
  have hbc := merge_ren_noren b c hb hc
  rw [merge_sem_noren _ _ hab hc, merge_sem_noren _ _ ha hbc]
  have e1 := merge_sem_noren a b ha hb n
  have e2 := merge_sem_noren b c hb hc n
  have a1 : semR (mergeLibrary a b).recents n = _ := congrArg Prod.fst e1
  have a2 : semT (mergeLibrary a b).tomb n = _ := congrArg Prod.snd e1
  have b1 : semR (mergeLibrary b c).recents n = _ := congrArg Prod.fst e2
  have b2 : semT (mergeLibrary b c).tomb n = _ := congrArg Prod.snd e2
  rw [a1, a2, b1, b2]
  exact normP_assoc_ts _ _ _ _ _ _

/-- **Convergence without markers**: merging in a library whose content is
already in the result changes nothing (on timestamps). So once each device's
library has been merged into Drive's and read back, further syncs are no-ops;
with commutativity and associativity, the order of the exchanges does not
matter. -/
theorem merge_absorb_ts_noren (a b : Lib) (ha : a.ren = []) (hb : b.ren = []) (n : Nat) :
    tsOf (semL (mergeLibrary a (mergeLibrary a b)) n) = tsOf (semL (mergeLibrary a b) n) := by
  rw [← merge_assoc_ts_noren a a b ha ha hb]
  have haa := merge_ren_noren a a ha ha
  rw [merge_sem_noren _ _ haa hb, merge_sem_noren a b ha hb]
  have e := merge_sem_noren a a ha ha n
  have e1 : semR (mergeLibrary a a).recents n = _ := congrArg Prod.fst e
  have e2 : semT (mergeLibrary a a).tomb n = _ := congrArg Prod.snd e
  rw [e1, e2, joinO_idem, joinT_idem, tsOf_normP, tsOf_normP, map_fst_joinO, map_fst_joinO]
  have h1 : ∀ e t, (normP e t).1.map Prod.fst = (nf (e.map Prod.fst) t).1 := fun e t =>
    congrArg Prod.fst (tsOf_normP e t)
  have h2 : ∀ e t, (normP e t).2 = (nf (e.map Prod.fst) t).2 := fun e t =>
    congrArg Prod.snd (tsOf_normP e t)
  rw [h1, h2, nf_absorb]

/-! ### The rename-marker join -/

/-- Join of two marker claims `(to, ts)` for one old name: the newer wins,
a tie keeps the left one (`renStep`: `r.ts > prev.ts`). -/
def joinN : Option (Nat × Nat) → Option (Nat × Nat) → Option (Nat × Nat)
  | none, y => y
  | x, none => x
  | some p, some q => if q.2 > p.2 then some q else some p

theorem joinN_assoc (x y z : Option (Nat × Nat)) :
    joinN (joinN x y) z = joinN x (joinN y z) := by
  rcases x with _ | ⟨a, b⟩ <;> rcases y with _ | ⟨c, d⟩ <;> rcases z with _ | ⟨e, f⟩
  · rfl
  · rfl
  · rfl
  · rfl
  · rfl
  · rfl
  · by_cases h1 : d > b <;> simp [joinN, h1]
  · by_cases h1 : d > b <;> by_cases h2 : f > d <;> by_cases h3 : f > b <;>
      simp [joinN, h1, h2, h3] <;> omega

theorem joinN_idem (x : Option (Nat × Nat)) : joinN x x = x := by
  rcases x with _ | ⟨a, b⟩ <;> simp [joinN]

/-- Two claims that never tie on a timestamp with different targets. -/
def NoTie (x y : Option (Nat × Nat)) : Prop :=
  ∀ p q, x = some p → y = some q → p.2 = q.2 → p = q

theorem joinN_comm_of_noTie (x y : Option (Nat × Nat)) (h : NoTie x y) :
    joinN x y = joinN y x := by
  rcases x with _ | ⟨a, b⟩ <;> rcases y with _ | ⟨c, d⟩
  · rfl
  · rfl
  · rfl
  · simp only [joinN]
    by_cases h1 : d > b
    · have : ¬ b > d := by omega
      simp [h1, this]
    · by_cases h2 : b > d
      · simp [h1, h2]
      · have hbd : b = d := by omega
        have := h (a, b) (c, d) rfl rfl hbd
        simp [h1, h2, this]

/-- What a marker list says about one old name. -/
def semNStep (n : Nat) (acc : Option (Nat × Nat)) (r : Ren) : Option (Nat × Nat) :=
  if r.src = n ∧ r.src ≠ r.dst then joinN acc (some (r.dst, r.ts)) else acc

def semN (l : List Ren) (n : Nat) : Option (Nat × Nat) := l.foldl (semNStep n) none

def projN (x : Option Ren) : Option (Nat × Nat) := x.map (fun r => (r.dst, r.ts))

theorem renStep_get (m : JMap Ren) (r : Ren) (n : Nat) :
    projN ((renStep m r).get n) = semNStep n (projN (m.get n)) r := by
  unfold renStep semNStep
  by_cases hs : r.src = r.dst
  · simp [hs]
  · simp only [hs, ite_false]
    cases hm : m.get r.src with
    | none =>
      by_cases hn : r.src = n
      · subst hn; simp [hm, projN, joinN, hs]
      · have : n ≠ r.src := fun h => hn h.symm
        simp [this, hn]
    | some p =>
      by_cases hn : r.src = n
      · subst hn
        by_cases hlt : r.ts > p.ts <;> simp [hm, hlt, projN, joinN, hs]
      · have : n ≠ r.src := fun h => hn h.symm
        by_cases hlt : r.ts > p.ts <;> simp [hlt, this, hn]

theorem foldl_renStep (l : List Ren) : ∀ (m : JMap Ren) (n : Nat),
    projN ((l.foldl renStep m).get n) = l.foldl (semNStep n) (projN (m.get n)) := by
  induction l with
  | nil => intro m n; rfl
  | cons e l ih => intro m n; simp only [List.foldl]; rw [ih, renStep_get]

theorem foldl_semNStep (n : Nat) (l : List Ren) :
    ∀ acc, l.foldl (semNStep n) acc = joinN acc (semN l n) := by
  induction l with
  | nil => intro acc; cases acc <;> rfl
  | cons e l ih =>
    intro acc
    simp only [semN, List.foldl]
    rw [ih (semNStep n acc e), ih (semNStep n none e)]
    unfold semNStep
    split
    · rw [joinN_assoc]; rfl
    · cases acc <;> rfl

/-- The marker map built from `a ++ b` is the join of what each side says. -/
theorem buildRen_sem (a b : List Ren) (n : Nat) :
    projN ((buildRen (a ++ b)).get n) = joinN (semN a n) (semN b n) := by
  unfold buildRen
  rw [foldl_renStep, List.foldl_append]
  exact foldl_semNStep n b _

/-! ## Layer 1b: provenance and survival through the whole merge (markers included) -/

/-- Every value a map holds came from `S`. -/
def Prov {V : Type} (m : JMap V) (S : List V) : Prop := ∀ n x, m.get n = some x → x ∈ S

theorem prov_del {V : Type} {m : JMap V} {S : List V} (h : Prov m S) (k : Nat) : Prov (m.del k) S := by
  intro n x hx
  by_cases hn : n = k <;> simp [hn] at hx
  exact h _ _ hx

theorem prov_values {V : Type} {m : JMap V} {S : List V} (h : Prov m S) {x : V}
    (hx : x ∈ m.values) : x ∈ S := by
  obtain ⟨n, hn⟩ := JMap.mem_values hx
  exact h _ _ hn

theorem prov_buildTomb (l : List Tomb) : Prov (buildTomb l) l := by
  have : ∀ (l' : List Tomb) (m : JMap Tomb) (S : List Tomb), Prov m S → (∀ x ∈ l', x ∈ S) →
      Prov (l'.foldl tombStep m) S := by
    intro l'
    induction l' with
    | nil => intro m S h _; exact h
    | cons t ts ih =>
      intro m S h hs
      apply ih _ S _ (fun x hx => hs x (List.mem_cons_of_mem _ hx))
      intro n x hx
      unfold tombStep at hx
      split at hx
      · by_cases hn : n = t.name <;> simp [hn] at hx
        · subst hx; exact hs _ List.mem_cons_self
        · exact h _ _ hx
      · split at hx
        · by_cases hn : n = t.name <;> simp [hn] at hx
          · subst hx; exact hs _ List.mem_cons_self
          · exact h _ _ hx
        · exact h _ _ hx
  exact this l JMap.empty l (by intro n x h; simp at h) (fun x hx => hx)

theorem prov_buildRen (l : List Ren) : Prov (buildRen l) l := by
  have : ∀ (l' : List Ren) (m : JMap Ren) (S : List Ren), Prov m S → (∀ x ∈ l', x ∈ S) →
      Prov (l'.foldl renStep m) S := by
    intro l'
    induction l' with
    | nil => intro m S h _; exact h
    | cons t ts ih =>
      intro m S h hs
      apply ih _ S _ (fun x hx => hs x (List.mem_cons_of_mem _ hx))
      intro n x hx
      unfold renStep at hx
      split at hx
      · exact h _ _ hx
      · split at hx
        · by_cases hn : n = t.src <;> simp [hn] at hx
          · subst hx; exact hs _ List.mem_cons_self
          · exact h _ _ hx
        · split at hx
          · by_cases hn : n = t.src <;> simp [hn] at hx
            · subst hx; exact hs _ List.mem_cons_self
            · exact h _ _ hx
          · exact h _ _ hx
  exact this l JMap.empty l (by intro n x h; simp at h) (fun x hx => hx)

theorem applyRen_ok (st : JMap Entry × JMap Ren) (r : Ren) (h : st.1.WF ∧ NameOK st.1) :
    (applyRen st r).1.WF ∧ NameOK (applyRen st r).1 := by
  obtain ⟨hw, hn⟩ := h
  unfold applyRen
  split
  · exact ⟨hw, hn⟩
  · split
    · exact ⟨hw, hn⟩
    · simp only
      split
      · exact ⟨JMap.wf_set (JMap.wf_del hw _) _ _, keyOK_set (keyOK_del hn _) _ _ rfl⟩
      · split
        · exact ⟨JMap.wf_set (JMap.wf_del hw _) _ _, keyOK_set (keyOK_del hn _) _ _ rfl⟩
        · exact ⟨JMap.wf_del hw _, keyOK_del hn _⟩

theorem applyRen_prov (st : JMap Entry × JMap Ren) (r : Ren) (S : List Ren) (h : Prov st.2 S) :
    Prov (applyRen st r).2 S := by
  unfold applyRen
  split
  · exact h
  · split
    · exact prov_del h _
    · exact h

theorem foldl_applyRen (L : List Ren) : ∀ (st : JMap Entry × JMap Ren) (S : List Ren),
    (st.1.WF ∧ NameOK st.1) → Prov st.2 S →
    ((L.foldl applyRen st).1.WF ∧ NameOK (L.foldl applyRen st).1) ∧ Prov (L.foldl applyRen st).2 S := by
  induction L with
  | nil => intro st S h1 h2; exact ⟨h1, h2⟩
  | cons r rs ih =>
    intro st S h1 h2
    exact ih _ S (applyRen_ok st r h1) (applyRen_prov st r S h2)

theorem afterRen_ok (a b : Lib) :
    ((afterRen a b).1.WF ∧ NameOK (afterRen a b).1) ∧ Prov (afterRen a b).2 (a.ren ++ b.ren) := by
  unfold afterRen
  exact foldl_applyRen _ _ _
    (foldl_recStep_wf _ JMap.empty JMap.wf_empty (keyOK_empty _)) (prov_buildRen _)

theorem prov_pruneStep (st : JMap Entry × JMap Tomb) (k : Nat) (S : List Tomb) (h : Prov st.2 S) :
    Prov (pruneStep st k).2 S := by
  unfold pruneStep
  split
  · exact h
  · split
    · split
      · exact prov_del h _
      · exact h
    · exact h

theorem prov_foldl_pruneStep (L : List Nat) : ∀ (st : JMap Entry × JMap Tomb) (S : List Tomb),
    Prov st.2 S → Prov (L.foldl pruneStep st).2 S := by
  induction L with
  | nil => intro st S h; exact h
  | cons k ks ih => intro st S h; exact ih _ S (prov_pruneStep st k S h)

/-- **No tombstone is invented**: every tombstone the merge outputs is one of
its inputs, verbatim. -/
theorem merge_tomb_sub (a b : Lib) {t : Tomb} (ht : t ∈ (mergeLibrary a b).tomb) :
    t ∈ a.tomb ++ b.tomb := by
  simp only [mergeLibrary, afterPrune] at ht
  exact prov_values (prov_foldl_pruneStep _ _ _ (prov_buildTomb _)) ht

/-- **No rename marker is invented**: every marker the merge outputs is one of
its inputs, verbatim. -/
theorem merge_ren_sub (a b : Lib) {r : Ren} (hr : r ∈ (mergeLibrary a b).ren) :
    r ∈ a.ren ++ b.ren := by
  simp only [mergeLibrary] at hr
  exact prov_values (afterRen_ok a b).2 hr

theorem semT_ge (n : Nat) (l : List Tomb) (t : Tomb) (ht : t ∈ l) (hn : t.name = n) :
    ∃ v, semT l n = some v ∧ t.ts ≤ v := by
  induction l with
  | nil => simp at ht
  | cons x xs ih =>
    have hs : semT (x :: xs) n = joinT (semTStep n none x) (semT xs n) := by
      simp only [semT, List.foldl]; exact foldl_semTStep n xs _
    rw [hs]
    rcases List.mem_cons.1 ht with h | h
    · subst h
      simp only [semTStep, hn, ite_true, joinT_none_left]
      cases semT xs n with
      | none => exact ⟨t.ts, rfl, Nat.le_refl _⟩
      | some w => exact ⟨max t.ts w, rfl, Nat.le_max_left _ _⟩
    · obtain ⟨v, hv, hle⟩ := ih h
      rw [hv]
      cases semTStep n none x with
      | none => exact ⟨v, rfl, hle⟩
      | some w => exact ⟨max w v, rfl, Nat.le_trans hle (Nat.le_max_right _ _)⟩

/-- **A tombstone survives the merge** — the same name keeps a tombstone at
least as new — unless the merged library holds a strictly newer entry under
that name (a later play or import, possibly one carried there by a rename
marker), which is the documented "a later play says the delete was not
meant". Holds for any inputs, markers included. -/
theorem merge_tomb_survives (a b : Lib) (t : Tomb) (ht : t ∈ a.tomb ++ b.tomb) :
    (∃ t' ∈ (mergeLibrary a b).tomb, t'.name = t.name ∧ t.ts ≤ t'.ts) ∨
    (∃ e ∈ (mergeLibrary a b).recents, e.name = t.name ∧ t.ts < e.ts) := by
  have hT := foldl_tombStep_ok (a.tomb ++ b.tomb) JMap.empty JMap.wf_empty (keyOK_empty _)
  have hR := (afterRen_ok a b).1
  obtain ⟨v, hv, hle⟩ := semT_ge t.name _ t ht rfl
  have hproj := projT_buildTomb (a.tomb ++ b.tomb) t.name
  rw [hv] at hproj
  obtain ⟨t0, ht0, ht0ts⟩ : ∃ t0, (buildTomb (a.tomb ++ b.tomb)).get t.name = some t0 ∧ t0.ts = v := by
    cases h : (buildTomb (a.tomb ++ b.tomb)).get t.name with
    | none => rw [h] at hproj; simp [projT] at hproj
    | some t0 => rw [h] at hproj; simp [projT] at hproj; exact ⟨t0, rfl, hproj⟩
  have hkey : t.name ∈ (buildTomb (a.tomb ++ b.tomb)).keys :=
    (hT.1.2 _).1 (Option.isSome_iff_exists.mpr ⟨t0, ht0⟩)
  have hP := foldl_pruneStep_ok (buildTomb (a.tomb ++ b.tomb)).keys
    ((afterRen a b).1, buildTomb (a.tomb ++ b.tomb)) ⟨hR.1, hR.2, hT.1, hT.2⟩
  have hG := foldl_pruneStep_get t.name (buildTomb (a.tomb ++ b.tomb)).keys hT.1.1
    ((afterRen a b).1, buildTomb (a.tomb ++ b.tomb))
  simp only [hkey, ite_true, ht0] at hG
  have hname0 : t0.name = t.name := hT.2 _ _ ht0
  simp only [mergeLibrary, afterPrune]
  cases he : (afterRen a b).1.get t.name with
  | none =>
    simp only [he, pruneAt, Prod.mk.injEq] at hG
    left
    exact ⟨t0, JMap.values_of_get hP.2.2.1 hG.2, hname0, by omega⟩
  | some e =>
    by_cases hlt : e.ts > t0.ts
    · simp only [he, pruneAt, hlt, ite_true, Prod.mk.injEq] at hG
      right
      refine ⟨e, mem_sortDesc.2 (JMap.values_of_get hP.1 hG.1), hR.2 _ _ he, by omega⟩
    · simp only [he, pruneAt, hlt, ite_false, Prod.mk.injEq] at hG
      left
      exact ⟨t0, JMap.values_of_get hP.2.2.1 hG.2, hname0, by omega⟩

/-! ## Layer 1c: the whole merge (markers included) is not a CRDT join

Game names: 1, 2, 3 are the names "B", "A", "C" of the scenario in each
statement; timestamps are milliseconds. -/

def names (l : List Entry) : List Nat := l.map (·.name)

/-- The library on Drive after game "B" (1) was renamed to "C" (3) at t=10;
game "A" (2) was imported at t=5. -/
def libB2C : Lib := ⟨[⟨3, 10, 0⟩, ⟨2, 5, 0⟩], [], [⟨1, 3, 10⟩]⟩
/-- The same device after renaming "A" (2) to the freed name "B" (1) at t=20
(`renameGame` 3280-3284 writes the new entry with a fresh ts and no `imp`,
and drops its own copy of the old 1→3 marker, 3336). -/
def libA2B : Lib := ⟨[⟨1, 20, 0⟩, ⟨3, 10, 0⟩], [], [⟨2, 1, 20⟩]⟩

/-- **Not idempotent.** Merging the merged library with itself changes it:
the first merge keeps "B" (the renamed A); merging that result again applies
the stale 1→3 marker to it and folds it into "C". A pull followed by a flush
is exactly such a re-merge, so the renamed game vanishes from the library. -/
theorem bug_merge_not_idempotent :
    let m := mergeLibrary libB2C libA2B
    names m.recents = [3, 1] ∧ names (mergeLibrary m m).recents = [3] := by decide

/-- **Not commutative on a timestamp tie**: two devices renaming the same
game to different names in the same millisecond end on whichever marker the
merge saw first. -/
theorem bug_merge_tie_not_comm :
    names (mergeLibrary ⟨[⟨1, 1, 0⟩], [], [⟨1, 2, 5⟩]⟩ ⟨[], [], [⟨1, 3, 5⟩]⟩).recents = [2] ∧
    names (mergeLibrary ⟨[], [], [⟨1, 3, 5⟩]⟩ ⟨[⟨1, 1, 0⟩], [], [⟨1, 2, 5⟩]⟩).recents = [3] := by
  decide

/-- **Not associative on the `imp` mark.** An import at t=5 (a), a delete at
t=6 (b), a play at t=7 (c): grouped (a·b)·c the tombstone first kills the
imported entry and its `imp` with it; grouped a·(b·c) the `imp` survives. Met
with a rename marker 1→2 made at t=4, the two groupings then disagree on
whether game 1 is renamed. -/
theorem bug_merge_imp_not_assoc :
    let a : Lib := ⟨[⟨1, 5, 5⟩], [], []⟩
    let b : Lib := ⟨[], [⟨1, 6⟩], []⟩
    let c : Lib := ⟨[⟨1, 7, 0⟩], [], []⟩
    let d : Lib := ⟨[], [], [⟨1, 2, 4⟩]⟩
    names (mergeLibrary (mergeLibrary (mergeLibrary a b) c) d).recents = [2] ∧
    names (mergeLibrary (mergeLibrary a (mergeLibrary b c)) d).recents = [1] := by
  decide

/-! ### What the merge does in the cases the code's comments promise -/

/-- A chain A→B (t=10, one device) then B→C (t=20, another) lands on C. -/
theorem merge_chain_lands :
    names (mergeLibrary (mergeLibrary ⟨[⟨1, 5, 0⟩], [], []⟩ ⟨[⟨2, 10, 0⟩], [], [⟨1, 2, 10⟩]⟩)
      ⟨[⟨3, 20, 0⟩], [], [⟨2, 3, 20⟩]⟩).recents = [3] := by decide

/-- Two devices renaming the same game A→B (t=10) and A→C (t=11): the newer
marker wins, but the library keeps both names — the game forks into two
entries (no data is lost; the A→B marker is dropped). -/
theorem merge_concurrent_renames_fork :
    let m := mergeLibrary (mergeLibrary ⟨[⟨1, 5, 0⟩], [], []⟩ ⟨[⟨2, 10, 0⟩], [], [⟨1, 2, 10⟩]⟩)
      ⟨[⟨3, 11, 0⟩], [], [⟨1, 3, 11⟩]⟩
    names m.recents = [3, 2] ∧ m.ren = [⟨1, 3, 11⟩] := by decide

/-- Rename A→B (t=10) against a later delete of A (t=11) on a device that had
not seen the rename: the game lives on as B; the tombstone only names A. -/
theorem merge_rename_beats_delete_of_old_name :
    let m := mergeLibrary (mergeLibrary ⟨[⟨1, 5, 0⟩], [], []⟩ ⟨[⟨2, 10, 0⟩], [], [⟨1, 2, 10⟩]⟩)
      ⟨[], [⟨1, 11⟩], []⟩
    names m.recents = [2] ∧ m.tomb = [⟨1, 11⟩] := by decide

/-- Delete then re-add: an import after the tombstone revives the game and
retires the tombstone; one in the same millisecond does not (`>` at 2556). -/
theorem merge_readd_after_delete :
    (mergeLibrary ⟨[], [⟨1, 5⟩], []⟩ ⟨[⟨1, 7, 7⟩], [], []⟩) = ⟨[⟨1, 7, 7⟩], [], []⟩ ∧
    (mergeLibrary ⟨[], [⟨1, 5⟩], []⟩ ⟨[⟨1, 5, 5⟩], [], []⟩) = ⟨[], [⟨1, 5⟩], []⟩ := by decide

/-- A play of the old name by a device that has not pulled the rename is
migrated (it is not an argument about the name); a fresh import spends it. -/
theorem merge_play_vs_import_after_rename :
    names (mergeLibrary ⟨[⟨2, 10, 0⟩], [], [⟨1, 2, 10⟩]⟩ ⟨[⟨1, 12, 0⟩], [], []⟩).recents = [2] ∧
    (mergeLibrary ⟨[⟨2, 10, 0⟩], [], [⟨1, 2, 10⟩]⟩ ⟨[⟨1, 12, 12⟩], [], []⟩).ren = [] := by decide

/-! ## Layer 2: two devices, one Drive, no compare-and-swap -/

/-- One per-game IndexedDB record / Drive file: `rom:<game>` (kind 0) or
`save:<game>` (kind 1), holding bytes `blob`. -/
structure Item where
  game : Nat
  kind : Nat
  blob : Nat
deriving DecidableEq, Repr

abbrev Key := Nat × Nat

def Item.key (i : Item) : Key := (i.game, i.kind)

/-- The Drive-mirrored kinds of `allPerGameKeys` that the model keeps. -/
def kinds : List Nat := [0, 1]

def keysOf (g : Nat) : List Key := kinds.map (fun k => (g, k))

def addUniq {α : Type} [DecidableEq α] (l : List α) (x : α) : List α :=
  if x ∈ l then l else l ++ [x]

/-- `[...new Set(l)]`. -/
def dedup {α : Type} [DecidableEq α] (l : List α) : List α := l.foldl addUniq []

def hasKey (l : List Item) (k : Key) : Bool := l.any (fun i => i.key == k)

/-- Write one record / file, replacing any under the same key. -/
def putItem (l : List Item) (i : Item) : List Item := l.filter (fun j => j.key != i.key) ++ [i]

/-- The continuation a device's `runExclusive` chain has in flight. -/
inductive Pend where
  | idle
  /-- flushSyncInner after `driveListMap` + `readDriveLibrary` (2715-2718). -/
  | fRead (d : Lib)
  /-- ...after `localLibrary` and the merge; queues settled (2718-2746). -/
  | fMerged (lib : Lib) (revived : List Nat)
  /-- ...after the rename/delete/upload passes (2748-2800). -/
  | fFiles (lib : Lib) (revived : List Nat)
  /-- ...after `writeDriveLibrary` landed (2801). -/
  | fWritten (lib : Lib) (revived : List Nat)
  /-- pullSyncInner after `driveListMap` + `readDriveLibrary` (2927-2928). -/
  | pRead (d : Lib) (remote : List Item)
  | pMerged (lib : Lib) (remote : List Item)
  /-- ...after the remote-rename pass (2932-2955). -/
  | pRenamed (lib : Lib) (remote : List Item)
  /-- ...after the "removed on another device" modal (2957-2980). -/
  | pTombed (lib : Lib) (remote : List Item)
  /-- ...after tomb/ren/recent were adopted; `writeDriveLibrary` pending (3031-3049). -/
  | pCommitted (lib : Lib)
deriving DecidableEq, Repr

structure Dev where
  /-- IndexedDB "recent" (getRecentMeta). -/
  recent : List Entry
  /-- IndexedDB per-game records. -/
  store : List Item
  /-- syncState.tomb -/
  tomb : List Tomb
  /-- syncState.ren -/
  ren : List Ren
  /-- syncState.queueUp -/
  qUp : List Key
  /-- syncState.queueDel -/
  qDel : List Key
  /-- syncState.queueRen `[{ from, to }]` -/
  qRen : List (Key × Key)
  /-- the op in flight on `syncChain` -/
  pend : Pend
  /-- ghost: "…is now…— renamed on another device" toasts shown (2950) -/
  toasts : Nat
deriving DecidableEq, Repr

def Dev.empty : Dev := ⟨[], [], [], [], [], [], [], .idle, 0⟩

structure St where
  d0 : Dev
  d1 : Dev
  /-- the Drive file "library" -/
  lib : Lib
  /-- the per-game files in appDataFolder -/
  files : List Item
  /-- Date.now(), shared -/
  now : Nat
  /-- ghost: every tombstone `deleteGameEverywhere` ever raised -/
  deleted : List Tomb
deriving DecidableEq, Repr

def init : St := ⟨Dev.empty, Dev.empty, Lib.empty, [], 1, []⟩

def St.dev (s : St) : Bool → Dev
  | false => s.d0
  | true => s.d1

def St.setDev (s : St) : Bool → Dev → St
  | false, v => { s with d0 := v }
  | true, v => { s with d1 := v }

@[simp] theorem dev_setDev_same (s : St) (d : Bool) (v : Dev) : (s.setDev d v).dev d = v := by
  cases d <;> rfl
@[simp] theorem dev_setDev_other (s : St) (d d' : Bool) (v : Dev) (h : d' ≠ d) :
    (s.setDev d v).dev d' = s.dev d' := by
  cases d <;> cases d' <;> simp_all [St.setDev, St.dev]
@[simp] theorem setDev_lib (s : St) (d : Bool) (v : Dev) : (s.setDev d v).lib = s.lib := by
  cases d <;> rfl
@[simp] theorem setDev_files (s : St) (d : Bool) (v : Dev) : (s.setDev d v).files = s.files := by
  cases d <;> rfl
@[simp] theorem setDev_now (s : St) (d : Bool) (v : Dev) : (s.setDev d v).now = s.now := by
  cases d <;> rfl
@[simp] theorem setDev_deleted (s : St) (d : Bool) (v : Dev) :
    (s.setDev d v).deleted = s.deleted := by
  cases d <;> rfl

/-- `localLibrary()` (2566-2570). -/
def localLib (dv : Dev) : Lib := ⟨dv.recent, dv.tomb, dv.ren⟩

inductive Ev where
  | flushRead (d : Bool)
  | flushMerge (d : Bool)
  | flushFiles (d : Bool)
  | flushWrite (d : Bool)
  | flushCommit (d : Bool)
  | pullRead (d : Bool)
  | pullMerge (d : Bool)
  | pullRenames (d : Bool)
  | pullTombs (d : Bool) (restore : Bool)
  | pullCommit (d : Bool)
  | pullWrite (d : Bool)
  | delete (d : Bool) (g : Nat)
  | rename (d : Bool) (a b : Nat)
  | importRom (d : Bool) (g blob : Nat)
  | play (d : Bool) (g blob : Nat)
  | download (d : Bool) (g : Nat)
deriving DecidableEq, Repr

/-! ### flushSyncInner (2707-2818) -/

/-- 2718-2746: merge, then cancel the queued deletes of revived games and the
queued renames of spent markers. -/
def flushMergeDev (dv : Dev) (D : Lib) : Dev :=
  let lib := mergeLibrary D (localLib dv)
  let revived := (dv.tomb.filter (fun t => !lib.tomb.any (fun x => x.name == t.name))).map (·.name)
  let spent := (dv.ren.filter (fun r => !lib.ren.any (fun x => x.src == r.src))).map (·.src)
  { dv with qDel := dv.qDel.filter (fun k => !revived.contains k.1),
            qRen := dv.qRen.filter (fun q => !spent.contains q.1.1),
            pend := .fMerged lib revived }

/-- One queued file rename (2748-2771). -/
def renFile (acc : Dev × List Item) (q : Key × Key) : Dev × List Item :=
  let (dv, files) := acc
  if hasKey files q.1 then
    if hasKey files q.2 then (dv, files.filter (fun i => i.key != q.1))   -- raced: delete the old
    else (dv, files.map (fun i => if i.key == q.1 then { i with game := q.2.1, kind := q.2.2 } else i))
  else if !hasKey files q.2 && !dv.qUp.contains q.2 && hasKey dv.store q.2 then
    ({ dv with qUp := dv.qUp ++ [q.2] }, files)                            -- upload instead
  else (dv, files)

/-- One queued upload (2786-2800): a missing file uploads; a present ROM is
never re-sent; anything else re-uploads. -/
def upFile (dv : Dev) (files : List Item) (k : Key) : List Item :=
  match dv.store.find? (fun i => i.key == k) with
  | none => files
  | some it => if hasKey files k && k.2 == 0 then files else putItem files it

/-- 2748-2800 as one event: renames, then deletes, then uploads. -/
def flushFilesDev (dv : Dev) (files : List Item) : Dev × List Item :=
  let (dv1, f1) := dv.qRen.foldl renFile (dv, files)
  let f2 := f1.filter (fun i => !dv1.qDel.contains i.key)
  let f3 := dv1.qUp.foldl (upFile dv1) f2
  ({ dv1 with qRen := [], qDel := [], qUp := [] }, f3)

/-- 2802-2814: adopt the merged tombstones and markers; put revived games back. -/
def flushCommitDev (dv : Dev) (lib : Lib) (revived : List Nat) : Dev :=
  let add := lib.recents.filter (fun r => revived.contains r.name &&
                                          !dv.recent.any (fun h => h.name == r.name))
  { dv with tomb := lib.tomb, ren := lib.ren,
            recent := if revived.isEmpty || add.isEmpty then dv.recent else sortDesc (dv.recent ++ add),
            pend := .idle }

/-! ### pullSyncInner (2919-3063) -/

/-- `applyRemoteRename(r.from, r.to)` (2832-2903) plus the queueing of
old-name Drive files that follows it (2940-2950). -/
def remoteRename (remote : List Item) (dv : Dev) (r : Ren) : Dev :=
  if !dv.store.any (fun i => i.game == r.src) then dv else           -- hasAnyLocalRecord
  -- dbMoveKeys(..., { skipCollisions: true })
  let mv : List Item × Nat → Nat → List Item × Nat := fun acc k =>
    if hasKey acc.1 (r.src, k) && !hasKey acc.1 (r.dst, k) then
      (acc.1.map (fun i => if i.key == (r.src, k) then { i with game := r.dst } else i), acc.2 + 1)
    else acc
  let (st1, moved) := kinds.foldl mv (dv.store, 0)
  -- collided pairs holding identical bytes: the old-name copy is dropped (2895-2900)
  let st2 := st1.filter (fun i => !(i.game == r.src &&
                st1.any (fun j => j.key == (r.dst, i.kind) && j.blob == i.blob)))
  let mapKey : Key → Key := fun k => if k.1 == r.src then (r.dst, k.2) else k
  let qRen1 := dv.qRen.map (fun q => (mapKey q.1, q.2))
  let qRen2 := kinds.foldl (fun q k =>
    if hasKey remote (r.src, k) && !q.any (fun x => x.1 == (r.src, k))
    then q ++ [((r.src, k), (r.dst, k))] else q) qRen1
  { dv with store := st2, qUp := dedup (dv.qUp.map mapKey), qDel := dedup (dv.qDel.map mapKey),
            qRen := qRen2, toasts := dv.toasts + (if moved > 0 then 1 else 0) }

/-- 2957-2980: "Games removed on another device". -/
def pullTombsDev (dv : Dev) (lib : Lib) (remote : List Item) (restore : Bool) (now : Nat) : Dev :=
  let pending := (lib.tomb.filter (fun t => dv.store.any (fun i => i.game == t.name))).map (·.name)
  if pending.isEmpty then { dv with pend := .pTombed lib remote }
  else if restore then
    let lib' : Lib := { lib with
      tomb := lib.tomb.filter (fun t => !pending.contains t.name),
      recents := pending.foldl (fun rs g => ⟨g, now, 0⟩ :: rs.filter (fun r => r.name != g)) lib.recents }
    let ups := (dv.store.filter (fun i => pending.contains i.game)).map Item.key
    { dv with qUp := ups.foldl addUniq dv.qUp, pend := .pTombed lib' remote }
  else
    { dv with store := dv.store.filter (fun i => !pending.contains i.game), pend := .pTombed lib remote }

/-- 3017-3048: reconcile upward, then adopt tomb/ren and write "recent". -/
def pullCommitDev (dv : Dev) (lib : Lib) (remote : List Item) : Dev :=
  let missing := (dv.store.filter (fun i => !hasKey remote i.key &&
                    !lib.tomb.any (fun t => t.name == i.game))).map Item.key
  { dv with qUp := missing.foldl addUniq dv.qUp, tomb := lib.tomb, ren := lib.ren,
            recent := lib.recents, pend := .pCommitted lib }

/-! ### The user's actions -/

/-- `deleteGameEverywhere` (3149-3163), signed in. -/
def deleteDev (dv : Dev) (g now : Nat) : Dev :=
  { dv with store := dv.store.filter (fun i => i.game != g),
            recent := dv.recent.filter (fun r => r.name != g),
            qDel := (keysOf g).foldl addUniq dv.qDel,
            qUp := dv.qUp.filter (fun k => k.1 != g),
            tomb := dv.tomb.filter (fun t => t.name != g) ++ [⟨g, now⟩] }

/-- `renameGame` (3252-3367) past its checks: one `dbMoveKeys` transaction
moves every record, writes "recent" and the new sync state. -/
def renameOk (dv : Dev) (a b : Nat) : Bool :=
  a != b && !dv.recent.any (fun r => r.name == b) && !dv.store.any (fun i => i.game == b)

def renameDev (dv : Dev) (a b now : Nat) : Dev :=
  let mirrored := (keysOf a).filter (fun k => !dv.qDel.contains k)
  let newOf : Key → Key := fun k => if mirrored.contains k then (b, k.2) else k
  { dv with
    store := dv.store.map (fun i => if i.game == a then { i with game := b } else i),
    recent := if dv.recent.any (fun r => r.name == a)
              then ⟨b, now, 0⟩ :: dv.recent.filter (fun r => r.name != a) else dv.recent,
    qUp := dedup (dv.qUp.map newOf),
    qDel := dv.qDel.filter (fun k => !(mirrored.map newOf).contains k),
    qRen := dv.qRen ++ mirrored.map (fun k => (k, (b, k.2))),
    tomb := dv.tomb.filter (fun t => t.name != a && t.name != b),
    ren := dv.ren.filter (fun r => r.src != a && r.src != b) ++ [⟨a, b, now⟩] }

/-- `bumpRecentIndex` (4424-4445). -/
def bump (dv : Dev) (g now : Nat) (fresh : Bool) : List Entry :=
  let prev := dv.recent.find? (fun r => r.name == g)
  let ts := if fresh then now else
    match dv.ren.find? (fun r => r.src == g) with
    | some m => if m.ts != 0 && now ≥ m.ts then m.ts - 1 else now
    | none => now
  let imp := if fresh then now else (prev.map (·.imp)).getD 0
  ⟨g, ts, imp⟩ :: dv.recent.filter (fun r => r.name != g)

/-- `addRecentRom` (4460-4476): ROM bytes, then a fresh import, then upload. -/
def importDev (dv : Dev) (g blob now : Nat) : Dev :=
  let st := putItem dv.store ⟨g, 0, blob⟩
  { dv with store := st, recent := bump dv g now true,
            qUp := ((st.filter (fun i => i.game == g)).map Item.key).foldl addUniq dv.qUp }

/-- A launch (`touchRecent`) and a battery save (`persistSave` + `markUpload`). -/
def playDev (dv : Dev) (g blob now : Nat) : Dev :=
  { dv with recent := bump dv g now false, store := putItem dv.store ⟨g, 1, blob⟩,
            qUp := addUniq dv.qUp (g, 1) }

/-- `downloadGame` (3074-3107). -/
def downloadDev (dv : Dev) (files : List Item) (g now : Nat) : Dev :=
  let fs := files.filter (fun f => f.game == g)
  if fs.isEmpty then dv
  else { dv with store := fs.foldl putItem dv.store, recent := bump dv g now false }

/-! ### The step function -/

def step (s : St) : Ev → St
  | .flushRead d =>
    match (s.dev d).pend with
    | .idle => s.setDev d { s.dev d with pend := .fRead s.lib }
    | _ => s
  | .flushMerge d =>
    match (s.dev d).pend with
    | .fRead D => s.setDev d (flushMergeDev (s.dev d) D)
    | _ => s
  | .flushFiles d =>
    match (s.dev d).pend with
    | .fMerged lib rv =>
      let r := flushFilesDev (s.dev d) s.files
      { s.setDev d { r.1 with pend := .fFiles lib rv } with files := r.2 }
    | _ => s
  | .flushWrite d =>
    match (s.dev d).pend with
    | .fFiles lib rv => { s.setDev d { s.dev d with pend := .fWritten lib rv } with lib := lib }
    | _ => s
  | .flushCommit d =>
    match (s.dev d).pend with
    | .fWritten lib rv => s.setDev d (flushCommitDev (s.dev d) lib rv)
    | _ => s
  | .pullRead d =>
    match (s.dev d).pend with
    | .idle => s.setDev d { s.dev d with pend := .pRead s.lib s.files }
    | _ => s
  | .pullMerge d =>
    match (s.dev d).pend with
    | .pRead D remote => s.setDev d { s.dev d with pend := .pMerged (mergeLibrary D (localLib (s.dev d))) remote }
    | _ => s
  | .pullRenames d =>
    match (s.dev d).pend with
    | .pMerged lib remote =>
      s.setDev d { (sortAsc lib.ren).foldl (remoteRename remote) (s.dev d) with pend := .pRenamed lib remote }
    | _ => s
  | .pullTombs d restore =>
    match (s.dev d).pend with
    | .pRenamed lib remote => s.setDev d (pullTombsDev (s.dev d) lib remote restore s.now)
    | _ => s
  | .pullCommit d =>
    match (s.dev d).pend with
    | .pTombed lib remote => s.setDev d (pullCommitDev (s.dev d) lib remote)
    | _ => s
  | .pullWrite d =>
    match (s.dev d).pend with
    | .pCommitted lib => { s.setDev d { s.dev d with pend := .idle } with lib := lib }
    | _ => s
  | .delete d g =>
    { s.setDev d (deleteDev (s.dev d) g s.now) with
      now := s.now + 1, deleted := s.deleted ++ [⟨g, s.now⟩] }
  | .rename d a b =>
    if renameOk (s.dev d) a b then
      { s.setDev d (renameDev (s.dev d) a b s.now) with now := s.now + 1 }
    else s
  | .importRom d g blob => { s.setDev d (importDev (s.dev d) g blob s.now) with now := s.now + 1 }
  | .play d g blob =>
    if hasKey (s.dev d).store (g, 0) then
      { s.setDev d (playDev (s.dev d) g blob s.now) with now := s.now + 1 }
    else s
  | .download d g => { s.setDev d (downloadDev (s.dev d) s.files g s.now) with now := s.now + 1 }

def run (s : St) (es : List Ev) : St := es.foldl step s

inductive Reachable : St → Prop
  | init : Reachable init
  | step {s : St} (e : Ev) : Reachable s → Reachable (step s e)

/-- One uninterrupted sync of each kind. -/
def flush (d : Bool) : List Ev := [.flushRead d, .flushMerge d, .flushFiles d, .flushWrite d, .flushCommit d]
def pull (d : Bool) : List Ev :=
  [.pullRead d, .pullMerge d, .pullRenames d, .pullTombs d false, .pullCommit d, .pullWrite d]

/-! ## Layer 2a: what the protocol keeps -/

/-- Tombstones a continuation carries (its snapshot or its merged library). -/
def pendTombs : Pend → List Tomb
  | .idle => []
  | .fRead D => D.tomb
  | .fMerged lib _ => lib.tomb
  | .fFiles lib _ => lib.tomb
  | .fWritten lib _ => lib.tomb
  | .pRead D _ => D.tomb
  | .pMerged lib _ => lib.tomb
  | .pRenamed lib _ => lib.tomb
  | .pTombed lib _ => lib.tomb
  | .pCommitted lib => lib.tomb

def devTombs (dv : Dev) : List Tomb := dv.tomb ++ pendTombs dv.pend

/-- Every tombstone anywhere: on Drive, in either device's sync state, and in
anything either device has in flight. -/
def allTombs (s : St) : List Tomb := s.lib.tomb ++ devTombs (s.dev false) ++ devTombs (s.dev true)

def noTombFor (g : Nat) (s : St) : Bool := (allTombs s).all (fun t => t.name != g)

theorem devTombs_sub (s : St) (d : Bool) {t : Tomb} (h : t ∈ devTombs (s.dev d)) :
    t ∈ allTombs s := by
  cases d <;> simp [allTombs, h]

theorem allTombs_setDev (s : St) (d : Bool) (v : Dev) (L : Lib)
    (hv : ∀ t ∈ devTombs v, t ∈ allTombs s) (hL : ∀ t ∈ L.tomb, t ∈ allTombs s) :
    ∀ t ∈ allTombs { s.setDev d v with lib := L }, t ∈ allTombs s := by
  intro t ht
  cases d <;> simp only [allTombs, St.setDev, St.dev, List.mem_append] at ht
  · rcases ht with (h | h) | h
    · exact hL t h
    · exact hv t h
    · exact devTombs_sub s true h
  · rcases ht with (h | h) | h
    · exact hL t h
    · exact devTombs_sub s false h
    · exact hv t h

theorem allTombs_setDev' (s : St) (d : Bool) (v : Dev)
    (hv : ∀ t ∈ devTombs v, t ∈ allTombs s) :
    ∀ t ∈ allTombs (s.setDev d v), t ∈ allTombs s := by
  have := allTombs_setDev s d v s.lib hv (fun t h => by simp [allTombs, h])
  cases d <;> exact this

theorem renFile_tomb (acc : Dev × List Item) (q : Key × Key) : (renFile acc q).1.tomb = acc.1.tomb := by
  unfold renFile
  repeat' split
  all_goals rfl

theorem foldl_renFile_tomb (L : List (Key × Key)) :
    ∀ acc : Dev × List Item, (L.foldl renFile acc).1.tomb = acc.1.tomb := by
  induction L with
  | nil => intro acc; rfl
  | cons q qs ih => intro acc; simp only [List.foldl]; rw [ih, renFile_tomb]

theorem flushFilesDev_tomb (dv : Dev) (files : List Item) : (flushFilesDev dv files).1.tomb = dv.tomb := by
  unfold flushFilesDev
  exact foldl_renFile_tomb dv.qRen (dv, files)

theorem remoteRename_tomb (remote : List Item) (dv : Dev) (r : Ren) :
    (remoteRename remote dv r).tomb = dv.tomb := by
  unfold remoteRename
  split
  · rfl
  · rfl

theorem foldl_remoteRename_tomb (remote : List Item) (L : List Ren) :
    ∀ dv : Dev, (L.foldl (remoteRename remote) dv).tomb = dv.tomb := by
  induction L with
  | nil => intro dv; rfl
  | cons r rs ih => intro dv; simp only [List.foldl]; rw [ih, remoteRename_tomb]

/-! Per-device facts: which tombstones each device-level function leaves. -/

@[simp] theorem flushMergeDev_tomb (dv : Dev) (D : Lib) : (flushMergeDev dv D).tomb = dv.tomb := rfl
@[simp] theorem flushMergeDev_pendTombs (dv : Dev) (D : Lib) :
    pendTombs (flushMergeDev dv D).pend = (mergeLibrary D (localLib dv)).tomb := rfl
@[simp] theorem flushCommitDev_tomb (dv : Dev) (lib : Lib) (rv : List Nat) :
    (flushCommitDev dv lib rv).tomb = lib.tomb := rfl
@[simp] theorem flushCommitDev_pend (dv : Dev) (lib : Lib) (rv : List Nat) :
    (flushCommitDev dv lib rv).pend = .idle := rfl
@[simp] theorem pullCommitDev_tomb (dv : Dev) (lib : Lib) (R : List Item) :
    (pullCommitDev dv lib R).tomb = lib.tomb := rfl
@[simp] theorem pullCommitDev_pend (dv : Dev) (lib : Lib) (R : List Item) :
    (pullCommitDev dv lib R).pend = .pCommitted lib := rfl
@[simp] theorem deleteDev_tomb (dv : Dev) (g n : Nat) :
    (deleteDev dv g n).tomb = dv.tomb.filter (fun t => t.name != g) ++ [⟨g, n⟩] := rfl
@[simp] theorem deleteDev_pend (dv : Dev) (g n : Nat) : (deleteDev dv g n).pend = dv.pend := rfl
@[simp] theorem renameDev_tomb (dv : Dev) (a b n : Nat) :
    (renameDev dv a b n).tomb = dv.tomb.filter (fun t => t.name != a && t.name != b) := rfl
@[simp] theorem renameDev_pend (dv : Dev) (a b n : Nat) : (renameDev dv a b n).pend = dv.pend := rfl
@[simp] theorem importDev_tomb (dv : Dev) (g b n : Nat) : (importDev dv g b n).tomb = dv.tomb := rfl
@[simp] theorem importDev_pend (dv : Dev) (g b n : Nat) : (importDev dv g b n).pend = dv.pend := rfl
@[simp] theorem playDev_tomb (dv : Dev) (g b n : Nat) : (playDev dv g b n).tomb = dv.tomb := rfl
@[simp] theorem playDev_pend (dv : Dev) (g b n : Nat) : (playDev dv g b n).pend = dv.pend := rfl
theorem downloadDev_tp (dv : Dev) (F : List Item) (g n : Nat) :
    (downloadDev dv F g n).tomb = dv.tomb ∧ (downloadDev dv F g n).pend = dv.pend := by
  dsimp only [downloadDev]; split <;> exact ⟨rfl, rfl⟩
@[simp] theorem downloadDev_tomb (dv : Dev) (F : List Item) (g n : Nat) :
    (downloadDev dv F g n).tomb = dv.tomb := (downloadDev_tp dv F g n).1
@[simp] theorem downloadDev_pend (dv : Dev) (F : List Item) (g n : Nat) :
    (downloadDev dv F g n).pend = dv.pend := (downloadDev_tp dv F g n).2

theorem pullTombsDev_sub (dv : Dev) (lib : Lib) (R : List Item) (r : Bool) (n : Nat) :
    ∀ t ∈ devTombs (pullTombsDev dv lib R r n), t ∈ dv.tomb ∨ t ∈ lib.tomb := by
  intro t ht
  dsimp only [pullTombsDev] at ht
  split at ht
  · simpa [devTombs, pendTombs] using ht
  · split at ht
    · simp only [devTombs, pendTombs, List.mem_append, List.mem_filter] at ht
      rcases ht with h | ⟨h, _⟩
      · exact Or.inl h
      · exact Or.inr h
    · simpa [devTombs, pendTombs] using ht

/-- `v`'s tombstones are among `dv`'s. -/
def DSub (v dv : Dev) : Prop := ∀ t ∈ devTombs v, t ∈ devTombs dv

theorem mem_allTombs_setDev (s : St) (d : Bool) (v : Dev) {t : Tomb}
    (ht : t ∈ allTombs (s.setDev d v)) : t ∈ allTombs s ∨ t ∈ devTombs v := by
  cases d <;> simp only [allTombs, St.setDev, St.dev, List.mem_append] at ht ⊢ <;> grind

theorem mem_allTombs_lib (s : St) (L : Lib) {t : Tomb}
    (ht : t ∈ allTombs { s with lib := L }) : t ∈ allTombs s ∨ t ∈ L.tomb := by
  simp only [allTombs, St.dev, List.mem_append] at ht ⊢; grind

theorem setDev_sub (s : St) (d : Bool) (v : Dev) (h : DSub v (s.dev d)) {t : Tomb}
    (ht : t ∈ allTombs (s.setDev d v)) : t ∈ allTombs s := by
  rcases mem_allTombs_setDev s d v ht with h1 | h1
  · exact h1
  · exact devTombs_sub s d (h t h1)

theorem pend_sub {dv : Dev} {t : Tomb} (h : t ∈ pendTombs dv.pend) : t ∈ devTombs dv := by
  simp [devTombs, h]

theorem tomb_sub {dv : Dev} {t : Tomb} (h : t ∈ dv.tomb) : t ∈ devTombs dv := by
  simp [devTombs, h]

theorem dsub_flushMerge (dv : Dev) (D : Lib) (hp : dv.pend = .fRead D) : DSub (flushMergeDev dv D) dv := by
  intro t ht
  simp only [devTombs, List.mem_append, flushMergeDev_tomb, flushMergeDev_pendTombs] at ht
  rcases ht with h | h
  · exact tomb_sub h
  · rcases List.mem_append.1 (merge_tomb_sub _ _ h) with h' | h'
    · exact pend_sub (by rw [hp]; exact h')
    · exact tomb_sub h'

theorem dsub_flushFiles (dv : Dev) (F : List Item) (lib : Lib) (rv : List Nat)
    (hp : dv.pend = .fMerged lib rv) : DSub { (flushFilesDev dv F).1 with pend := .fFiles lib rv } dv := by
  intro t ht
  simp only [devTombs, List.mem_append, flushFilesDev_tomb, pendTombs] at ht
  rcases ht with h | h
  · exact tomb_sub h
  · exact pend_sub (by rw [hp]; exact h)

theorem dsub_pend (dv : Dev) (p : Pend) (hp : ∀ t ∈ pendTombs p, t ∈ devTombs dv) :
    DSub { dv with pend := p } dv := by
  intro t ht
  simp only [devTombs, List.mem_append] at ht
  rcases ht with h | h
  · exact tomb_sub h
  · exact hp t h

theorem dsub_flushCommit (dv : Dev) (lib : Lib) (rv : List Nat) (hp : dv.pend = .fWritten lib rv) :
    DSub (flushCommitDev dv lib rv) dv := by
  intro t ht
  simp only [devTombs, List.mem_append, flushCommitDev_tomb, flushCommitDev_pend, pendTombs,
    List.not_mem_nil, or_false] at ht
  exact pend_sub (by rw [hp]; exact ht)

theorem dsub_pullMerge (dv : Dev) (D : Lib) (R : List Item) (hp : dv.pend = .pRead D R) :
    DSub { dv with pend := .pMerged (mergeLibrary D (localLib dv)) R } dv := by
  apply dsub_pend
  intro t h
  simp only [pendTombs] at h
  rcases List.mem_append.1 (merge_tomb_sub _ _ h) with h' | h'
  · exact pend_sub (by rw [hp]; exact h')
  · exact tomb_sub h'

theorem dsub_pullRenames (dv : Dev) (lib : Lib) (R : List Item) (hp : dv.pend = .pMerged lib R) :
    DSub { (sortAsc lib.ren).foldl (remoteRename R) dv with pend := .pRenamed lib R } dv := by
  intro t ht
  simp only [devTombs, List.mem_append, foldl_remoteRename_tomb, pendTombs] at ht
  rcases ht with h | h
  · exact tomb_sub h
  · exact pend_sub (by rw [hp]; exact h)

theorem dsub_pullTombs (dv : Dev) (lib : Lib) (R : List Item) (r : Bool) (n : Nat)
    (hp : dv.pend = .pRenamed lib R) : DSub (pullTombsDev dv lib R r n) dv := by
  intro t ht
  rcases pullTombsDev_sub dv lib R r n t ht with h | h
  · exact tomb_sub h
  · exact pend_sub (by rw [hp]; exact h)

theorem dsub_pullCommit (dv : Dev) (lib : Lib) (R : List Item) (hp : dv.pend = .pTombed lib R) :
    DSub (pullCommitDev dv lib R) dv := by
  intro t ht
  simp only [devTombs, List.mem_append, pullCommitDev_tomb, pullCommitDev_pend, pendTombs, or_self] at ht
  exact pend_sub (by rw [hp]; exact ht)

theorem dsub_rename (dv : Dev) (a b n : Nat) : DSub (renameDev dv a b n) dv := by
  intro t ht
  simp only [devTombs, List.mem_append, renameDev_tomb, renameDev_pend, List.mem_filter] at ht
  rcases ht with ⟨h, _⟩ | h
  · exact tomb_sub h
  · exact pend_sub h

theorem dsub_same (v dv : Dev) (h1 : v.tomb = dv.tomb) (h2 : v.pend = dv.pend) : DSub v dv := by
  intro t ht; simpa [devTombs, h1, h2] using ht

/-- **Where tombstones come from.** One step never produces a tombstone that
was not already somewhere, except the one `deleteGameEverywhere` raises. -/
theorem step_tombs (s : St) (e : Ev) :
    ∀ t ∈ allTombs (step s e), t ∈ allTombs s ∨ ∃ d g, e = .delete d g ∧ t = ⟨g, s.now⟩ := by
  intro t ht
  cases e with
  | flushRead d =>
    left; dsimp only [step] at ht; split at ht
    · rcases mem_allTombs_setDev s d _ ht with h | h
      · exact h
      · simp only [devTombs, pendTombs, List.mem_append] at h
        rcases h with h | h
        · exact devTombs_sub s d (tomb_sub h)
        · simp [allTombs, h]
    · exact ht
  | flushMerge d =>
    left; dsimp only [step] at ht; split at ht
    · rename_i D hp; exact setDev_sub s d _ (dsub_flushMerge _ _ hp) ht
    · exact ht
  | flushFiles d =>
    left; dsimp only [step] at ht; split at ht
    · rename_i lib rv hp; exact setDev_sub s d _ (dsub_flushFiles _ _ _ _ hp) ht
    · exact ht
  | flushWrite d =>
    left; dsimp only [step] at ht; split at ht
    · rename_i lib rv hp
      rcases mem_allTombs_lib _ _ ht with h | h
      · exact setDev_sub s d _ (dsub_pend _ _ (fun t h => pend_sub (by rw [hp]; simpa [pendTombs] using h))) h
      · exact devTombs_sub s d (pend_sub (by rw [hp]; exact h))
    · exact ht
  | flushCommit d =>
    left; dsimp only [step] at ht; split at ht
    · rename_i lib rv hp; exact setDev_sub s d _ (dsub_flushCommit _ _ _ hp) ht
    · exact ht
  | pullRead d =>
    left; dsimp only [step] at ht; split at ht
    · rcases mem_allTombs_setDev s d _ ht with h | h
      · exact h
      · simp only [devTombs, pendTombs, List.mem_append] at h
        rcases h with h | h
        · exact devTombs_sub s d (tomb_sub h)
        · simp [allTombs, h]
    · exact ht
  | pullMerge d =>
    left; dsimp only [step] at ht; split at ht
    · rename_i D R hp; exact setDev_sub s d _ (dsub_pullMerge _ _ _ hp) ht
    · exact ht
  | pullRenames d =>
    left; dsimp only [step] at ht; split at ht
    · rename_i lib R hp; exact setDev_sub s d _ (dsub_pullRenames _ _ _ hp) ht
    · exact ht
  | pullTombs d restore =>
    left; dsimp only [step] at ht; split at ht
    · rename_i lib R hp; exact setDev_sub s d _ (dsub_pullTombs _ _ _ _ _ hp) ht
    · exact ht
  | pullCommit d =>
    left; dsimp only [step] at ht; split at ht
    · rename_i lib R hp; exact setDev_sub s d _ (dsub_pullCommit _ _ _ hp) ht
    · exact ht
  | pullWrite d =>
    left; dsimp only [step] at ht; split at ht
    · rename_i lib hp
      rcases mem_allTombs_lib _ _ ht with h | h
      · exact setDev_sub s d _ (dsub_pend _ _ (fun t h => by simp [pendTombs] at h)) h
      · exact devTombs_sub s d (pend_sub (by rw [hp]; exact h))
    · exact ht
  | delete d g =>
    dsimp only [step] at ht
    have ht' : t ∈ allTombs (s.setDev d (deleteDev (s.dev d) g s.now)) := ht
    rcases mem_allTombs_setDev s d _ ht' with h | h
    · exact Or.inl h
    · simp only [devTombs, List.mem_append, deleteDev_tomb, deleteDev_pend, List.mem_filter,
        List.mem_singleton] at h
      rcases h with (⟨h, _⟩ | h) | h
      · exact Or.inl (devTombs_sub s d (tomb_sub h))
      · exact Or.inr ⟨d, g, rfl, h⟩
      · exact Or.inl (devTombs_sub s d (pend_sub h))
  | rename d a b =>
    left; dsimp only [step] at ht; split at ht
    · exact setDev_sub s d _ (dsub_rename _ _ _ _) ht
    · exact ht
  | importRom d g blob =>
    left; dsimp only [step] at ht
    exact setDev_sub s d (importDev (s.dev d) g blob s.now) (dsub_same _ _ rfl rfl) ht
  | play d g blob =>
    left; dsimp only [step] at ht; split at ht
    · exact setDev_sub s d (playDev (s.dev d) g blob s.now) (dsub_same _ _ rfl rfl) ht
    · exact ht
  | download d g =>
    left; dsimp only [step] at ht
    exact setDev_sub s d _ (dsub_same _ _ (downloadDev_tomb _ _ _ _) (downloadDev_pend _ _ _ _)) ht

theorem step_deleted_sub (s : St) (e : Ev) : ∀ t ∈ s.deleted, t ∈ (step s e).deleted := by
  intro t ht
  cases e <;> dsimp only [step] <;> (try split) <;> simp [ht]

/-- **Every tombstone anywhere was raised by a delete.** -/
theorem tomb_origin {s : St} (h : Reachable s) : ∀ t ∈ allTombs s, t ∈ s.deleted := by
  induction h with
  | init => intro t ht; simp [allTombs, init, Lib.empty, devTombs, Dev.empty, pendTombs, St.dev] at ht
  | @step s0 e _ ih =>
    intro t ht
    rcases step_tombs s0 e t ht with h | ⟨d, g, rfl, rfl⟩
    · exact step_deleted_sub s0 _ t (ih t h)
    · simp [step]

/-- **A tombstone gone from everywhere is gone for good**: once no copy is
left on Drive, in either device's sync state or in anything in flight, no
sequence of syncs, plays, imports, downloads or renames brings one back; only
deleting the game again does. -/
theorem tomb_lost_forever (g : Nat) : ∀ (es : List Ev) (s : St), noTombFor g s = true →
    (∀ e ∈ es, ∀ d, e ≠ .delete d g) → noTombFor g (run s es) = true := by
  intro es
  induction es with
  | nil => intro s h _; exact h
  | cons e es ih =>
    intro s h hes
    apply ih (step s e) _ (fun e' he' d => hes e' (List.mem_cons_of_mem _ he') d)
    simp only [noTombFor, List.all_eq_true, bne_iff_ne, ne_eq] at h ⊢
    intro t ht
    rcases step_tombs s e t ht with h1 | ⟨d, g', rfl, rfl⟩
    · exact h t h1
    · intro hg
      exact hes _ List.mem_cons_self d (by simp only at hg; rw [hg])

/-- The device an event runs on. -/
def Ev.dev : Ev → Bool
  | .flushRead d | .flushMerge d | .flushFiles d | .flushWrite d | .flushCommit d => d
  | .pullRead d | .pullMerge d | .pullRenames d | .pullTombs d _ | .pullCommit d | .pullWrite d => d
  | .delete d _ | .rename d _ _ | .importRom d _ _ | .play d _ _ | .download d _ => d

/-- **The other device cannot touch this one's sync state**: in particular a
Drive lost update can take a tombstone or marker off Drive, never out of the
`syncState` of the device that holds it. -/
theorem step_other_dev (s : St) (e : Ev) (d : Bool) (h : e.dev ≠ d) : (step s e).dev d = s.dev d := by
  have h' : d ≠ e.dev := fun x => h x.symm
  cases e <;> simp only [Ev.dev] at h' <;> dsimp only [step] <;> (try split) <;>
    first
    | rfl
    | (cases d <;> rename_i d' <;> cases d' <;> simp_all [St.setDev, St.dev])
    | (cases d <;> simp_all [St.setDev, St.dev])

/-- **A device's next uninterrupted flush re-asserts every tombstone it
holds** (or the library now holds a newer entry for that name: a later play
revived the game). So a Drive lost update delays a tombstone, never loses it,
as long as it was in `syncState.tomb` when the flush merged. -/
theorem resync_reasserts_tomb (s : St) (d : Bool) (hidle : (s.dev d).pend = .idle)
    (t : Tomb) (ht : t ∈ (s.dev d).tomb) :
    ((∃ t' ∈ (run s (flush d)).lib.tomb, t'.name = t.name ∧ t.ts ≤ t'.ts) ∨
     (∃ e ∈ (run s (flush d)).lib.recents, e.name = t.name ∧ t.ts < e.ts)) ∧
    ((run s (flush d)).dev d).tomb = (run s (flush d)).lib.tomb := by
  have key := merge_tomb_survives s.lib (localLib (s.dev d)) t (by simp [localLib, ht])
  cases d <;> simp only [run, flush, List.foldl, step, St.dev, St.setDev] at hidle ⊢ <;>
    simp only [hidle] <;> simpa [flushMergeDev, flushCommitDev, localLib, St.dev] using key

/-- **A rename moves everything, in one transaction**: every record under the
old name is under the new one, bytes unchanged, and nothing is left under the
old name. `dbMoveKeys` (570-616) is a single IndexedDB transaction that also
writes recent and the sync state, so a page that dies mid-rename leaves the
whole rename or none of it: no key can be orphaned by it. -/
theorem rename_moves_everything (s : St) (d : Bool) (a b : Nat) (h : renameOk (s.dev d) a b = true) :
    ((step s (.rename d a b)).dev d).store.map (·.blob) = (s.dev d).store.map (·.blob) ∧
    (∀ i ∈ ((step s (.rename d a b)).dev d).store, i.game ≠ a) ∧
    (∀ i ∈ (s.dev d).store, i.game = a → ⟨b, i.kind, i.blob⟩ ∈ ((step s (.rename d a b)).dev d).store) := by
  have hab : a ≠ b := by
    simp only [renameOk, Bool.and_eq_true, bne_iff_ne] at h; exact h.1.1
  have e1 : ((step s (.rename d a b)).dev d) = renameDev (s.dev d) a b s.now := by
    cases d <;> simp only [St.dev] at h <;> simp [step, h, St.setDev, St.dev]
  rw [e1]
  refine ⟨?_, ?_, ?_⟩
  · simp only [renameDev, List.map_map]
    congr 1; funext i; simp only [Function.comp]; split <;> rfl
  · intro i hi
    simp only [renameDev, List.mem_map] at hi
    obtain ⟨j, _, rfl⟩ := hi
    split
    · exact fun x => hab x.symm
    · rename_i hj; simpa using hj
  · intro i hi hg
    simp only [renameDev, List.mem_map]
    exact ⟨i, hi, by simp [hg]⟩

theorem run_reachable {s : St} (h : Reachable s) : ∀ es : List Ev, Reachable (run s es) := by
  intro es
  induction es generalizing s with
  | nil => exact h
  | cons e es ih => exact ih (Reachable.step e h)

/-! ## Layer 2b: what the protocol does not keep (concrete traces)

Each trace is a list of events run from `init`; every event is one JS
segment between awaits, fired in an order a browser allows. -/

/-- Device 0 imports game 7 (ROM bytes 70) and syncs; device 1 pulls the
library and downloads the game. -/
def setupA : List Ev := [.importRom false 7 70] ++ flush false ++ pull true ++ [.download true 7]

/-- Device 0 plays 7 (save 71), which schedules a flush. While that flush is
still in flight — past its merge, e.g. while the save or a ROM is uploading
(2786-2800) or `writeDriveLibrary` is awaiting (2801) — the person taps
Delete on 7. The flush then writes its stale library and runs
`syncState.tomb = lib.tomb` (2802), dropping the tombstone the delete just
pushed (3158-3159). -/
def raceA : List Ev :=
  [.play false 7 71, .flushRead false, .flushMerge false, .flushFiles false,
   .delete false 7, .flushWrite false, .flushCommit false]

/-- Ordinary syncs afterwards (triggers: 2s debounce, visibilitychange, the
3-minute poll). -/
def settleA : List Ev := flush false ++ pull false ++ pull true ++ flush true ++ pull false

/-- **BUG: a delete made while a flush is in flight is undone everywhere.**
Right after the race no tombstone for 7 exists anywhere (Drive, either
device, anything in flight) though the delete happened; after ordinary syncs
7 is back in the library, back on device 0's grid, and its ROM is back on
Drive (device 1 re-uploads its copy, 3017-3029). Device 0 said "Deleted from
all your devices". -/
theorem bug_delete_during_flush_resurrects :
    let s1 := run init (setupA ++ raceA)
    let s2 := run s1 settleA
    s1.deleted = [⟨7, 4⟩] ∧ noTombFor 7 s1 = true ∧
    names s2.lib.recents = [7] ∧ names s2.d0.recent = [7] ∧ names s2.d1.recent = [7] ∧
    hasKey s2.files (7, 0) = true ∧ noTombFor 7 s2 = true := by
  decide

/-- ...and it is permanent: from that state no sequence of events other than
deleting 7 again ever brings a tombstone for 7 back. -/
theorem bug_delete_during_flush_permanent (es : List Ev) (h : ∀ e ∈ es, ∀ d, e ≠ .delete d 7) :
    noTombFor 7 (run (run init (setupA ++ raceA)) es) = true :=
  tomb_lost_forever 7 es _ (by decide) h

/-- The trace is a run of the model. -/
theorem raceA_reachable : Reachable (run init (setupA ++ raceA ++ settleA)) :=
  run_reachable Reachable.init _

/-- A pull (visibilitychange, the poll) in flight on device 0; the person
deletes 7 while it is downloading saves/pictures (2981-3015), after its merge
(2928). Its commit then runs `syncState.tomb = lib.tomb` (3031) and writes
"recent" (3048) from the stale merge. -/
def raceB : List Ev :=
  [.pullRead false, .pullMerge false, .pullRenames false, .pullTombs false false,
   .delete false 7, .pullCommit false]

/-- **BUG: a delete made while a pull is in flight comes straight back** as
a tile on this device's grid, with its tombstone gone for good. -/
theorem bug_delete_during_pull_resurrects :
    let s := run init (setupA ++ raceB)
    names s.d0.recent = [7] ∧ s.d0.store = [] ∧ s.deleted = [⟨7, 3⟩] ∧
    noTombFor 7 (run s [.pullWrite false]) = true := by
  decide

/-- A pull in flight on device 0; the person imports game 9 (ROM 90) — e.g.
the file picker closing fires visibilitychange, whose flush-then-pull (3823)
races the import. `addRecentRom` writes "recent" (4444); the pull's commit
writes its stale "recent" over it (3048). -/
def raceC : List Ev :=
  [.pullRead false, .pullMerge false, .importRom false 9 90, .pullRenames false,
   .pullTombs false false, .pullCommit false, .pullWrite false]

/-- **BUG: a game imported while a pull is in flight is orphaned**: its ROM
is on the device and (after the flush) on Drive, but no library anywhere
lists it, so no tile can open it. Only `adoptSaveOnlyGames` at the next
boot recovers it, and only once it has a save. -/
theorem bug_import_during_pull_orphans :
    let s := run init (raceC ++ flush false ++ pull false)
    hasKey s.d0.store (9, 0) = true ∧ hasKey s.files (9, 0) = true ∧
    names s.d0.recent = [] ∧ names s.lib.recents = [] := by
  decide

/-- Import game 1 (ROM 10, save 11); rename 1→2 and sync; rename it back
2→1 and flush. Every step is the documented flow. -/
def setupD : List Ev := [.importRom false 1 10, .play false 1 11] ++ flush false ++
  [.rename false 1 2] ++ flush false ++ pull false ++ [.rename false 2 1] ++ flush false

def cycleD : List Ev := pull false ++ flush false

/-- **BUG: renaming a game back (an undo) never settles.** The old 1→2
marker is never retired (renameGame drops it only locally, 3336; the merge
brings it back from Drive), so every pull re-applies 1→2 then 2→1 to the
device's own records (toasting "renamed on another device" twice) and queues
the Drive files for 1→2 renames, which the next flush performs: the Drive
files flip between the two names on every sync, forever, while the library
says 1. -/
theorem bug_rename_undo_oscillates :
    let s1 := run init (setupD ++ cycleD)
    let s2 := run s1 cycleD
    let s3 := run s2 cycleD
    s1.d0.toasts = 2 ∧ s1.files.map (·.game) = [2, 2] ∧
    s2.d0.toasts = 4 ∧ s2.files.map (·.game) = [1, 1] ∧
    s3.d0.toasts = 6 ∧ s3.files.map (·.game) = [2, 2] ∧
    names s3.lib.recents = [1] ∧ s3.d0.store.map (·.game) = [1, 1] := by
  decide

set_option maxRecDepth 8000 in
/-- **BUG: ...and the churn deletes the newest save from Drive.** After one
flip, the person saves (12). It uploads as a new `save:1` beside the flipped
`save:2` (11); the next pull queues both directions, and the flush deletes
the new `save:1` as the "raced duplicate" (2758-2761), then renames the old
`save:2` onto `save:1`. Drive now holds progress 11 while the device holds
12; a second device downloading the game gets 11. -/
theorem bug_rename_undo_loses_save :
    let s := run init (setupD ++ cycleD ++ [.play false 1 12] ++ flush false ++ cycleD ++
      [.download true 1])
    (⟨1, 1, 12⟩ : Item) ∈ s.d0.store ∧ (⟨1, 1, 11⟩ : Item) ∈ s.files ∧
    (⟨1, 1, 12⟩ : Item) ∉ s.files ∧ (⟨1, 1, 11⟩ : Item) ∈ s.d1.store := by
  decide

/-- **BUG (minor): after an undo, the game's recency is frozen.** A play at
t=5 is stamped t=2 (`bumpRecentIndex` pins a play under any marker whose
`from` is the game, 4432-4435, and the 1→2 marker never retires), so the
library keeps the undo's t=4 on every later play: the tile never moves up
the grid and the ROM byte budget (4394-4420) treats the game as stale. -/
theorem bug_rename_undo_freezes_recency :
    let s1 := run init (setupD ++ cycleD ++ [.play false 1 12])
    let s2 := run s1 (flush false ++ pull false)
    s1.now = 6 ∧ s1.d0.recent = [⟨1, 2, 0⟩] ∧ s2.lib.recents = [⟨1, 4, 0⟩] := by
  decide

/-- Games "B" (1, ROM 10, no save) and "A" (2, ROM 20, save 21); rename B→C
(1→3) and sync. -/
def setupE : List Ev := [.importRom false 1 10, .importRom false 2 20, .play false 2 21] ++
  flush false ++ pull false ++ [.rename false 1 3] ++ flush false ++ pull false

/-- **BUG: renaming a game to a name another game was renamed away from
merges the two.** Rename A→B (2→1): the stale B→C marker (1→3) captures the
renamed game on the next merge (`bug_merge_not_idempotent`). After the pull,
A is gone from the library and the grid, its ROM is an orphan record under
B, and its save has been moved under C — C's ROM now opens A's save. After
the next flush Drive agrees: A's ROM is deleted there as a "raced
duplicate" and A's save is C's save. -/
theorem bug_rename_into_retired_name :
    let s1 := run init (setupE ++ [.rename false 2 1] ++ flush false ++ pull false)
    let s2 := run s1 (flush false)
    names s1.d0.recent = [3] ∧ names s1.lib.recents = [3] ∧
    (⟨1, 0, 20⟩ : Item) ∈ s1.d0.store ∧ (⟨3, 1, 21⟩ : Item) ∈ s1.d0.store ∧
    s2.files = [⟨3, 0, 10⟩, ⟨3, 1, 21⟩] := by
  decide

/-- Device 0 imports 5 and syncs; device 1 pulls and downloads it. -/
def setupF : List Ev := [.importRom false 5 50] ++ flush false ++ pull true ++ [.download true 5]

/-- Device 1 reads the library; device 0 deletes 5 and flushes (Drive now
has the tombstone); device 1 finishes its flush and overwrites the library
with its stale merge. No If-Match / revision check (2143-2147). -/
def raceF : List Ev := [.flushRead true, .delete false 5] ++ flush false ++
  [.flushMerge true, .flushFiles true, .flushWrite true, .flushCommit true]

/-- **The Drive lost-update race only delays a tombstone.** Device 1's stale
write takes the tombstone off Drive, but device 0 still holds it
(`step_other_dev`) and its next flush puts it back (`resync_reasserts_tomb`);
device 1's next pull then removes the game. -/
theorem race_delays_tomb :
    let s1 := run init (setupF ++ raceF)
    let s2 := run s1 (flush false ++ pull true)
    s1.lib.tomb = [] ∧ s1.d0.tomb = [⟨5, 3⟩] ∧
    s2.lib.tomb = [⟨5, 3⟩] ∧ s2.d1.store = [] ∧ names s2.d1.recent = [] := by
  decide

/-- A pull in flight; the person renames game 1 to 2 while it downloads.
`renameGame` installs its marker (`syncState = nextSync`, 3354) and writes
"recent"; the pull's commit then runs `syncState.ren = lib.ren` (3032) and
writes its stale "recent" (3048). -/
def raceG : List Ev := [.importRom false 1 10] ++ flush false ++
  [.pullRead false, .pullMerge false, .rename false 1 2, .pullRenames false,
   .pullTombs false false, .pullCommit false, .pullWrite false]

/-- **BUG: a rename made while a pull is in flight is half-undone**: the
marker is gone for good, the grid shows the old name (whose files are gone
from the device and, after the flush, from Drive), and the renamed records
are orphans no tile opens. -/
theorem bug_rename_during_pull_orphans :
    let s := run init (raceG ++ flush false ++ pull false)
    names s.d0.recent = [1] ∧ s.d0.store = [⟨2, 0, 10⟩] ∧ s.d0.ren = [] ∧
    s.lib.ren = [] ∧ s.files = [⟨2, 0, 10⟩] := by
  decide

/-! ## Layer 2c: the suggested fixes, checked on the same traces

* Commit (2802-2803, 3031-3032, 3048): re-merge the adopted library with the
  device's *current* library in the same synchronous segment as the
  assignment (for "recent", read-merge-write in one IDB transaction):
  `lib = mergeLibrary(lib, { recents: <current recent>, tomb: syncState.tomb,
  ren: syncState.ren })` before `syncState.tomb = lib.tomb` etc.
* `renameGame` (3283): stamp the new entry as a claim on the name,
  `{ name: newName, ts, imp: ts }`, so the merge spends any older marker
  whose `from` is the new name (the same rule a fresh import uses). -/

set_option maxRecDepth 8000

def flushCommitFix (dv : Dev) (lib : Lib) (rv : List Nat) : Dev :=
  let L := mergeLibrary lib (localLib dv)
  { flushCommitDev dv lib rv with tomb := L.tomb, ren := L.ren }

def pullCommitFix (dv : Dev) (lib : Lib) (remote : List Item) : Dev :=
  let L := mergeLibrary lib (localLib dv)
  { pullCommitDev dv lib remote with tomb := L.tomb, ren := L.ren, recent := L.recents }

def renameDevFix (dv : Dev) (a b now : Nat) : Dev :=
  let v := renameDev dv a b now
  { v with recent := v.recent.map (fun r => if r.name == b then { r with imp := now } else r) }

def stepFix (s : St) : Ev → St
  | .flushCommit d =>
    match (s.dev d).pend with
    | .fWritten lib rv => s.setDev d (flushCommitFix (s.dev d) lib rv)
    | _ => s
  | .pullCommit d =>
    match (s.dev d).pend with
    | .pTombed lib remote => s.setDev d (pullCommitFix (s.dev d) lib remote)
    | _ => s
  | .rename d a b =>
    if renameOk (s.dev d) a b then
      { s.setDev d (renameDevFix (s.dev d) a b s.now) with now := s.now + 1 }
    else s
  | e => step s e

def runFix (s : St) (es : List Ev) : St := es.foldl stepFix s

/-- Fixed: the delete made during a flush sticks on every device. -/
theorem fix_delete_during_flush :
    let s := runFix init (setupA ++ raceA ++ settleA)
    noTombFor 7 s = false ∧ names s.lib.recents = [] ∧ names s.d0.recent = [] ∧
    names s.d1.recent = [] ∧ s.d1.store = [] ∧ s.files = [] := by
  decide

/-- Fixed: the delete made during a pull stays deleted. -/
theorem fix_delete_during_pull :
    let s := runFix init (setupA ++ raceB ++ [.pullWrite false] ++ flush false)
    names s.d0.recent = [] ∧ s.lib.tomb = [⟨7, 3⟩] := by
  decide

/-- Fixed: the game imported during a pull keeps its tile and reaches the library. -/
theorem fix_import_during_pull :
    let s := runFix init (raceC ++ flush false ++ pull false)
    names s.d0.recent = [9] ∧ names s.lib.recents = [9] := by
  decide

/-- Fixed: the rename made during a pull keeps its marker and its tile. -/
theorem fix_rename_during_pull :
    let s := runFix init (raceG ++ flush false ++ pull false)
    names s.d0.recent = [2] ∧ names s.lib.recents = [2] := by
  decide

/-- Fixed: renaming back settles — no toasts, the files stay put. -/
theorem fix_rename_undo_settles :
    let s1 := runFix init (setupD ++ cycleD)
    let s2 := runFix s1 cycleD
    s1.d0.toasts = 0 ∧ s1.files.map (·.game) = [1, 1] ∧
    s2.d0.toasts = 0 ∧ s2.files.map (·.game) = [1, 1] := by
  decide

/-- Fixed: renaming into a retired name keeps the two games apart. -/
theorem fix_rename_into_retired_name :
    let s := runFix init (setupE ++ [.rename false 2 1] ++ flush false ++ pull false ++ flush false)
    names s.d0.recent = [1, 3] ∧
    (⟨1, 0, 20⟩ : Item) ∈ s.d0.store ∧ (⟨1, 1, 21⟩ : Item) ∈ s.d0.store ∧
    (⟨1, 1, 21⟩ : Item) ∈ s.files ∧ (⟨3, 0, 10⟩ : Item) ∈ s.files := by
  decide

end WebState.DriveLibrary
