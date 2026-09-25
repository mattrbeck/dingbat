-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models web/index.js: addRecentRom allPerGameKeys applyRemoteRename bumpRecentIndex confirmTombstones convertStaleGame dbMoveKeys deleteGameAction deleteGameEverywhere deletedIn downloadGame downloadGameAction driveListAll driveListMap driveUploadFile fileGen flushSyncInner genBound genOf getRecentMeta hasAnyLocalRecord keepOldSave libGen localLibrary markUpload mergeLibrary pendingCount pullSyncInner readDriveLibrary renameGame restoreKeptSave runExclusive runFullSync touchRecent updateRecent withGen writeDriveLibrary

/-
# The cross-device library on Google Drive (web/index.js)

Model of the Drive "library" file and the code that reads, merges and writes
it, as fixed on top of 7ca348ebf (the Drive sync fix series; line numbers are
web/index.js after the whole series). Against dd7ba741f the same model refuted
the properties below with the `bug_*` traces listed in formal/FINDINGS.md
(#6, #7); each is now a `regress_*` theorem.

* `mergeLibrary` (web/index.js 2619-2688): the pure join of two libraries,
  modelled line for line (`mergeLibrary` below), including JS `Map` insertion
  order and the stable sorts, because tie-breaking depends on both. Fixed: a
  marker's move claims its new name (`claim`: the entry at `to` carries
  `imp >= r.ts`) and spends a processed marker *from* that name (`done`).
* the protocol around it: `flushSyncInner` (2837-3002), `pullSyncInner`
  (3103-3270), `deleteGameEverywhere` (3358-3380), `renameGame` (3469-3598),
  `applyRemoteRename` (3010-3086), `bumpRecentIndex` (4702-4722) via import
  (`addRecentRom` 4737) and play (`touchRecent` 4756), and `downloadGame`
  (3282-3316). Every `await` that matters is an event boundary. Fixed: both
  commits re-merge the library they adopt with the device's library as it is
  *now*, in the same segment, under `updateRecent` (4556), the one lock every
  "recent" read-modify-write goes through; `renameGame` stamps the renamed
  entry `imp: ts` (3573).
* Fixed after a two-device UI run (the Sync button, `runFullSync` 3402, is
  the `syncTap` event): the flush's upload pass asks the library it merged
  (3025) and leaves a deleted game's keys off Drive, a renamed game's queued
  for the pull to move; the pull's commit queues the deletion of every Drive
  file of a game the library it adopts has deleted (3354). Before, a device
  that had not pulled a delete put the game back on Drive for good.
  (Line numbers in this file predate the integration of the fix series and
  may be off by a few dozen; the function names are what formal/anchors.mjs
  tracks.)

Layer 1 (pure merge) proves what *is* a semilattice (the recents join, the
tombstone join, the rename-marker join, and the whole merge on libraries
without rename markers, on timestamps), what survives a merge (tombstones,
markers), where outputs come from (no tombstone or marker is invented), and
that the whole merge, markers included, is idempotent (Layer 1d).

Layer 2 (protocol) models two devices and Drive with no compare-and-swap
(`driveUploadFile` 2209 sends no If-Match / revision precondition), proves the
Drive lost-update race only delays a tombstone, that no step drops a
tombstone a device holds except for a newer play or the person's own rename
or delete, and replays every finding's trace against the fixed code.

Results in one place:
* semilattice, no markers: `merge_comm_noren`, `merge_idem_noren`,
  `merge_assoc_ts_noren`, `merge_absorb_ts_noren`; marker join:
  `joinN_assoc`, `joinN_idem`, `joinN_comm_of_noTie`, `buildRen_sem`.
* merge, markers included: `merge_idem` (idempotent on every input, the order
  of every list included), via `merge_settled_out` + `merge_settled`;
  `merge_tomb_sub`, `merge_ren_sub`, `merge_tomb_survives`. Still refuted
  (not fixed here): `bug_merge_tie_not_comm`, `bug_merge_imp_not_assoc`.
  The pre-fix merge, kept as `mergeLibraryV1`: `bug_mergeV1_not_idempotent`
  (the finding) and `bug_mergeV1_chain_not_idempotent` (found by this model:
  the `renameGame` claim alone was not enough).
* generations (Layer 3, a game deleted and loaded again): `mergeName_gen0`
  (at generation 0 the merge is Layers 1-2's), `mergeName_tomb_beside_newer`,
  `mergeName_entry_survives`, `pullG_applies_current_gen`,
  `flushG_uploads_current_gen`; the finding `bug_reimport_gets_deleted_save`
  and its fixed trace `regress_reimport_keeps_deleted_save_aside`, with
  `regress_reimport_before_sync`.
* uploads and orphans: `flush_uploads_only_live`, `step_flushFiles_live`
  (a flush uploads nothing the library it merged deletes or renames away),
  `pull_queues_orphans`; traces `regress_sync_tap_after_remote_delete`,
  `regress_sync_tap_after_remote_rename`, `regress_orphans_removed`.
* protocol: `step_tombs`, `tomb_origin`, `tomb_lost_forever`,
  `step_other_dev`, `step_keeps_tomb`, `resync_reasserts_tomb`, `run_flush`,
  `rename_moves_everything`, `race_delays_tomb`.
* the findings' traces, fixed: `regress_delete_during_flush`,
  `regress_delete_during_pull`, `regress_import_during_pull`,
  `regress_rename_during_pull`, `regress_rename_undo_settles` (a sync cycle is
  then a fixed point of the whole state), `regress_rename_undo_keeps_save`,
  `regress_rename_undo_recency`, `regress_rename_into_retired_name`,
  `regress_revived_chain`, `regress_merge_rename_into_vacated`.

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
  event; the per-game save/picture download pass (and its check that a key
  queued for deletion is not written back, 3202) and the ROM byte budget are
  not modelled. `renPending` (a link session blocking a migration) is never
  set, as no link session is modelled.
* `deleteGameEverywhere`, `renameGame`, import and play are atomic events:
  each writes "recent" (and the sync state) inside one `updateRecent`
  section, which the commits also take, so no commit interleaves with them.
* The flush trigger guard (`pendingCount() || tomb || ren`) is dropped: any
  save a player makes queues an upload, so a flush can always be triggered.
* The "removed on another device" modal (`confirmTombstones` 3790) is the
  `restore` flag of `pullTombs`; the traces take "Continue". The wrappers
  `deleteGameAction` (1919) and `downloadGameAction` (1879) add only an
  unload and toasts. "Remove from this device" (3322) raises no tombstone
  and does not touch the library, so it is not an event here.
* The Drive listing is taken as complete and as holding one "library" file:
  `driveListAll` (2155) follows `nextPageToken`, and `driveListMap` /
  `readDriveLibrary` / `writeDriveLibrary` (2566-2617) merge every copy two
  devices created, write the oldest and delete the ones they merged.
* Sessions (sign out / in, another account) are `DriveSession`'s: here one
  account throughout.
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

/-- The Drive file "library": `{ recents, tomb, ren }` (web/index.js 2348). -/
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

/-- Insert for the descending sort `(x, y) => y.ts - x.ts` (web/index.js 2684). -/
def insDesc (x : Entry) : List Entry → List Entry
  | [] => [x]
  | y :: ys => if y.ts ≤ x.ts then x :: y :: ys else y :: insDesc x ys

def sortDesc (l : List Entry) : List Entry := l.foldr insDesc []

/-- Insert for the ascending sort `(x, y) => x.ts - y.ts` (web/index.js 2643). -/
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

/-! ## `mergeLibrary` (web/index.js 2619-2688), line for line -/

/-- One pass of the recents loop (2621-2631): the newest play wins the entry;
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

/-- The marker loop (2633-2640): newest marker per old name wins; a tie keeps
the one seen first. Self-renames are skipped. -/
def renStep (m : JMap Ren) (r : Ren) : JMap Ren :=
  if r.src = r.dst then m else
  match m.get r.src with
  | none => m.set r.src r
  | some p => if r.ts > p.ts then m.set r.src r else m

/-- The claim a rename makes on its new name: whatever holds `n` carries an
import mark no older than `ts` (`if (r.ts > (at.imp || 0)) at.imp = r.ts`). -/
def claim (m : JMap Entry) (n ts : Nat) : JMap Entry :=
  match m.get n with
  | some x => if ts > x.imp then m.set n { x with imp := ts } else m
  | none => m

/-- One marker applied, oldest first. The state is the entries, the surviving
markers, and the old names whose markers have been processed (`done`).
`reimported` spends the marker. A move claims the new name (`claim`) and
spends a processed marker *from* the new name: that rename's game left the
name before this one arrived. -/
def applyRen (st : JMap Entry × JMap Ren × List Nat) (r : Ren) : JMap Entry × JMap Ren × List Nat :=
  match st.1.get r.src with
  | none => (st.1, st.2.1, st.2.2 ++ [r.src])
  | some e =>
    if e.imp > r.ts then (st.1, st.2.1.del r.src, st.2.2 ++ [r.src])
    else
      let bn := st.1.del r.src
      let bn' := match bn.get r.dst with
        | none => bn.set r.dst ⟨r.dst, e.ts, e.imp⟩
        | some t => if t.ts < e.ts then bn.set r.dst ⟨r.dst, e.ts, e.imp⟩ else bn
      (claim bn' r.dst r.ts, if r.dst ∈ st.2.2 then st.2.1.del r.dst else st.2.1, st.2.2 ++ [r.src])

/-- The tombstone loop (2672-2677): newest per name, a tie keeps the first. -/
def tombStep (m : JMap Tomb) (t : Tomb) : JMap Tomb :=
  match m.get t.name with
  | none => m.set t.name t
  | some p => if t.ts > p.ts then m.set t.name t else m

/-- The prune loop (2678-2682): a newer entry supersedes the tombstone,
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
  let res := (sortAsc rm.values).foldl applyRen (buildRecents (a.recents ++ b.recents), rm, [])
  (res.1, res.2.1)

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

theorem claim_ok {m : JMap Entry} (h : m.WF ∧ NameOK m) (n ts : Nat) :
    (claim m n ts).WF ∧ NameOK (claim m n ts) := by
  obtain ⟨hw, hn⟩ := h
  unfold claim
  split
  · rename_i x hx
    split
    · exact ⟨JMap.wf_set hw _ _, keyOK_set hn _ _ (hn _ x hx)⟩
    · exact ⟨hw, hn⟩
  · exact ⟨hw, hn⟩

theorem applyRen_ok (st : JMap Entry × JMap Ren × List Nat) (r : Ren) (h : st.1.WF ∧ NameOK st.1) :
    (applyRen st r).1.WF ∧ NameOK (applyRen st r).1 := by
  obtain ⟨hw, hn⟩ := h
  unfold applyRen
  split
  · exact ⟨hw, hn⟩
  · split
    · exact ⟨hw, hn⟩
    · simp only
      apply claim_ok
      split
      · exact ⟨JMap.wf_set (JMap.wf_del hw _) _ _, keyOK_set (keyOK_del hn _) _ _ rfl⟩
      · split
        · exact ⟨JMap.wf_set (JMap.wf_del hw _) _ _, keyOK_set (keyOK_del hn _) _ _ rfl⟩
        · exact ⟨JMap.wf_del hw _, keyOK_del hn _⟩

theorem applyRen_prov (st : JMap Entry × JMap Ren × List Nat) (r : Ren) (S : List Ren)
    (h : Prov st.2.1 S) : Prov (applyRen st r).2.1 S := by
  unfold applyRen
  split
  · exact h
  · split
    · exact prov_del h _
    · simp only
      split
      · exact prov_del h _
      · exact h

theorem foldl_applyRen (L : List Ren) : ∀ (st : JMap Entry × JMap Ren × List Nat) (S : List Ren),
    (st.1.WF ∧ NameOK st.1) → Prov st.2.1 S →
    ((L.foldl applyRen st).1.WF ∧ NameOK (L.foldl applyRen st).1) ∧
      Prov (L.foldl applyRen st).2.1 S := by
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

It is not commutative on a same-millisecond tie, nor associative on `imp`
(neither fixed here). It is idempotent since the fix (Layer 1d), which the
old merge was not (`bug_mergeV1_not_idempotent`, the finding).

Game names: 1, 2, 3 are the names "B", "A", "C" of the scenario in each
statement; timestamps are milliseconds. -/

def names (l : List Entry) : List Nat := l.map (·.name)

/-- The library on Drive after game "B" (1) was renamed to "C" (3) at t=10;
game "A" (2) was imported at t=5. -/
def libB2C : Lib := ⟨[⟨3, 10, 0⟩, ⟨2, 5, 0⟩], [], [⟨1, 3, 10⟩]⟩
/-- The same device after renaming "A" (2) to the freed name "B" (1) at t=20
(`renameGame` before the fix wrote the new entry with a fresh ts and no
`imp`, and dropped its own copy of the old 1→3 marker). -/
def libA2B : Lib := ⟨[⟨1, 20, 0⟩, ⟨3, 10, 0⟩], [], [⟨2, 1, 20⟩]⟩

/-- **Fixed: renaming into a vacated name keeps both games.** With the claim
`renameGame` now stamps (`imp` = the rename's time), the stale 1→3 marker is
spent by the renamed game and both B (the renamed A) and C survive, and the
result is a fixed point (`merge_idem`). The old merge on the old library
folded B into C on the second merge (`bug_mergeV1_not_idempotent`). -/
def libA2Bfix : Lib := ⟨[⟨1, 20, 20⟩, ⟨3, 10, 0⟩], [], [⟨2, 1, 20⟩]⟩

theorem regress_merge_rename_into_vacated :
    let m := mergeLibrary libB2C libA2Bfix
    names m.recents = [1, 3] ∧ mergeLibrary m m = m := by decide

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
retires the tombstone; one in the same millisecond does not (`>` at 2680). -/
theorem merge_readd_after_delete :
    (mergeLibrary ⟨[], [⟨1, 5⟩], []⟩ ⟨[⟨1, 7, 7⟩], [], []⟩) = ⟨[⟨1, 7, 7⟩], [], []⟩ ∧
    (mergeLibrary ⟨[], [⟨1, 5⟩], []⟩ ⟨[⟨1, 5, 5⟩], [], []⟩) = ⟨[], [⟨1, 5⟩], []⟩ := by decide

/-- A play of the old name by a device that has not pulled the rename is
migrated (it is not an argument about the name); a fresh import spends it. -/
theorem merge_play_vs_import_after_rename :
    names (mergeLibrary ⟨[⟨2, 10, 0⟩], [], [⟨1, 2, 10⟩]⟩ ⟨[⟨1, 12, 0⟩], [], []⟩).recents = [2] ∧
    (mergeLibrary ⟨[⟨2, 10, 0⟩], [], [⟨1, 2, 10⟩]⟩ ⟨[⟨1, 12, 12⟩], [], []⟩).ren = [] := by decide

/-! ## Layer 1d: the merge is idempotent, markers included

The fixed merge (a move claims its new name and spends a processed marker
from that name) is idempotent on everything: `merge_idem`. So a pull after a
flush (a re-merge of what was just written) changes nothing, which is what
`bug_mergeV1_not_idempotent` showed the old merge could not promise. The proof
shows that a merge's output is *settled* (no surviving marker has an entry at
its old name, no name has both an entry and a tombstone, names are unique and
the recents are sorted), and that merging a settled library with itself
rebuilds it verbatim, JS `Map` insertion order included. -/

namespace JMap
variable {V : Type}

theorem ext' {m m' : JMap V} (hk : m.keys = m'.keys) (hg : ∀ n, m.get n = m'.get n) : m = m' := by
  cases m; cases m'; simp only at hk hg; subst hk; rw [funext hg]

theorem set_same (m : JMap V) (k : Nat) (v : V) (hv : m.get k = some v) : m.set k v = m := by
  apply ext'
  · simp [set, hv]
  · intro n; by_cases hn : n = k <;> simp [hn, hv]

theorem set_set (m : JMap V) (k : Nat) (v w : V) : (m.set k v).set k w = m.set k w := by
  apply ext'
  · simp [set]
  · intro n; by_cases hn : n = k <;> simp [hn]

theorem del_absent (m : JMap V) (h : m.WF) (k : Nat) (hk : m.get k = none) : m.del k = m := by
  apply ext'
  · simp only [del]
    apply List.filter_eq_self.2
    intro n hn
    have : n ≠ k := by
      intro e; subst e
      have := (h.2 n).2 hn
      simp [hk] at this
    simpa using this
  · intro n; by_cases hn : n = k <;> simp [hn, hk]

/-- The values of a well-formed map whose keys are its values' keys, in order. -/
theorem values_map_key {m : JMap V} (key : V → Nat) (h : m.WF) (hk : ∀ n x, m.get n = some x → key x = n) :
    m.values.map key = m.keys := by
  unfold values
  have : ∀ L : List Nat, (∀ n ∈ L, (m.get n).isSome = true) → (L.filterMap m.get).map key = L := by
    intro L
    induction L with
    | nil => intro _; rfl
    | cons n ns ih =>
      intro hL
      obtain ⟨x, hx⟩ := Option.isSome_iff_exists.1 (hL n (by simp))
      simp only [List.filterMap_cons, hx, List.map_cons, hk n x hx]
      rw [ih (fun y hy => hL y (by simp [hy]))]
  exact this _ (fun n hn => (h.2 n).2 hn)

end JMap

/-! ### Building a map from a list with distinct keys -/

section build
variable {V : Type} (key : V → Nat) (f : JMap V → V → JMap V) (P : V → Prop)

/-- A step that inserts a value under a fresh key, and leaves a map alone that
already holds that very value. `recStep`, `tombStep` and `renStep` (on a
non-self rename) are all such steps. -/
def FreshStep : Prop :=
  (∀ m x, P x → m.get (key x) = none → f m x = m.set (key x) x) ∧
  (∀ m x, P x → m.WF → m.get (key x) = some x → f m x = m)

theorem build_fresh (hf : FreshStep key f P) :
    ∀ (l : List V) (m : JMap V), m.WF → (∀ x ∈ l, P x) → (l.map key).Nodup →
      (∀ x ∈ l, m.get (key x) = none) →
      (l.foldl f m).WF ∧ (l.foldl f m).keys = m.keys ++ l.map key ∧
      (∀ x ∈ l, (l.foldl f m).get (key x) = some x) ∧
      (∀ n, n ∉ l.map key → (l.foldl f m).get n = m.get n) := by
  intro l
  induction l with
  | nil => intro m hw _ _ _; simp [hw]
  | cons x xs ih =>
    intro m hw hP hnd hfr
    have hx := hfr x (by simp)
    rw [List.map_cons, List.nodup_cons] at hnd
    have hnd' := hnd.2
    have hxk : key x ∉ xs.map key := hnd.1
    simp only [List.foldl, hf.1 m x (hP x (by simp)) hx]
    have hw' := JMap.wf_set hw (key x) x
    obtain ⟨i1, i2, i3, i4⟩ := ih (m.set (key x) x) hw' (fun y hy => hP y (by simp [hy])) hnd'
      (by
        intro y hy
        have : key y ≠ key x := fun e => hxk (e ▸ List.mem_map_of_mem hy)
        simp [this, hfr y (by simp [hy])])
    refine ⟨i1, ?_, ?_, ?_⟩
    · rw [i2]; simp [JMap.set, hx]
    · intro y hy
      simp only [List.mem_cons] at hy
      rcases hy with rfl | hy
      · rw [i4 _ hxk]; simp
      · exact i3 y hy
    · intro n hn
      simp only [List.map_cons, List.mem_cons, not_or] at hn
      rw [i4 n hn.2]; simp [hn.1]

theorem build_again (hf : FreshStep key f P) :
    ∀ (l : List V) (m : JMap V), m.WF → (∀ x ∈ l, P x) → (∀ x ∈ l, m.get (key x) = some x) →
      l.foldl f m = m := by
  intro l
  induction l with
  | nil => intro _ _ _ _; rfl
  | cons x xs ih =>
    intro m hw hP hs
    simp only [List.foldl, hf.2 m x (hP x (by simp)) hw (hs x (by simp))]
    exact ih m hw (fun y hy => hP y (by simp [hy])) (fun y hy => hs y (by simp [hy]))

theorem values_build (hf : FreshStep key f P) (l : List V) (hP : ∀ x ∈ l, P x) (hnd : (l.map key).Nodup) :
    (l.foldl f JMap.empty).values = l := by
  obtain ⟨_, hk, hg, _⟩ := build_fresh key f P hf l JMap.empty JMap.wf_empty hP hnd (by simp)
  rw [JMap.values, hk]
  simp only [JMap.empty, List.nil_append, List.filterMap_map]
  have : ∀ L : List V, (∀ x ∈ L, (l.foldl f JMap.empty).get (key x) = some x) →
      L.filterMap ((l.foldl f JMap.empty).get ∘ key) = L := by
    intro L
    induction L with
    | nil => intro _; rfl
    | cons y ys ih =>
      intro h
      simp only [List.filterMap_cons, Function.comp, h y (by simp)]
      rw [ih (fun z hz => h z (by simp [hz]))]
  exact this l hg

/-- Building from a list twice over is building from it once. -/
theorem build_twice (hf : FreshStep key f P) (l : List V) (hP : ∀ x ∈ l, P x) (hnd : (l.map key).Nodup) :
    (l ++ l).foldl f JMap.empty = l.foldl f JMap.empty := by
  obtain ⟨hw, _, hg, _⟩ := build_fresh key f P hf l JMap.empty JMap.wf_empty hP hnd (by simp)
  rw [List.foldl_append]
  exact build_again key f P hf l _ hw hP hg

end build

theorem recStep_fresh : FreshStep Entry.name recStep (fun _ => True) := by
  refine ⟨?_, ?_⟩
  · intro m e _ h
    obtain ⟨n, ts, i⟩ := e
    unfold recStep
    by_cases hi : i = 0
    · subst hi; simp_all
    · simp_all [JMap.set_set]
  · intro m e _ hw h
    have hs : m.set e.name e = m := JMap.set_same m e.name _ h
    obtain ⟨n, ts, i⟩ := e
    unfold recStep
    simp_all

theorem tombStep_fresh : FreshStep Tomb.name tombStep (fun _ => True) := by
  refine ⟨?_, ?_⟩
  · intro m t _ h; unfold tombStep; simp [h]
  · intro m t _ _ h; unfold tombStep; simp [h]

theorem renStep_fresh : FreshStep Ren.src renStep (fun r => r.src ≠ r.dst) := by
  refine ⟨?_, ?_⟩
  · intro m r hr h; unfold renStep; simp [hr, h]
  · intro m r hr _ h; unfold renStep; simp [hr, h]

/-! ### The sorts are permutations; the descending sort's output is sorted -/

theorem perm_insDesc (x : Entry) : ∀ l : List Entry, (insDesc x l).Perm (x :: l) := by
  intro l
  induction l with
  | nil => exact List.Perm.refl _
  | cons y ys ih =>
    simp only [insDesc]
    split
    · exact List.Perm.refl _
    · exact (List.Perm.cons y ih).trans (List.Perm.swap x y ys)

theorem perm_sortDesc : ∀ l : List Entry, (sortDesc l).Perm l := by
  intro l
  induction l with
  | nil => exact List.Perm.refl _
  | cons y ys ih =>
    show (insDesc y (sortDesc ys)).Perm (y :: ys)
    exact (perm_insDesc y _).trans (List.Perm.cons y ih)

theorem perm_insAsc (x : Ren) : ∀ l : List Ren, (insAsc x l).Perm (x :: l) := by
  intro l
  induction l with
  | nil => exact List.Perm.refl _
  | cons y ys ih =>
    simp only [insAsc]
    split
    · exact List.Perm.refl _
    · exact (List.Perm.cons y ih).trans (List.Perm.swap x y ys)

theorem perm_sortAsc : ∀ l : List Ren, (sortAsc l).Perm l := by
  intro l
  induction l with
  | nil => exact List.Perm.refl _
  | cons y ys ih =>
    show (insAsc y (sortAsc ys)).Perm (y :: ys)
    exact (perm_insAsc y _).trans (List.Perm.cons y ih)

def DescTs (l : List Entry) : Prop := l.Pairwise (fun x y => y.ts ≤ x.ts)

theorem desc_insDesc (x : Entry) : ∀ l : List Entry, DescTs l → DescTs (insDesc x l) := by
  intro l
  induction l with
  | nil => intro _; simp [insDesc, DescTs]
  | cons y ys ih =>
    intro h
    simp only [DescTs, List.pairwise_cons] at h
    simp only [insDesc]
    split
    · rename_i hyx
      simp only [DescTs, List.pairwise_cons]
      refine ⟨?_, h.1, h.2⟩
      intro z hz
      simp only [List.mem_cons] at hz
      rcases hz with rfl | hz
      · exact hyx
      · exact Nat.le_trans (h.1 z hz) hyx
    · rename_i hyx
      simp only [DescTs, List.pairwise_cons]
      refine ⟨?_, ih h.2⟩
      intro z hz
      rcases mem_insDesc.1 hz with rfl | hz
      · omega
      · exact h.1 z hz

theorem desc_sortDesc : ∀ l : List Entry, DescTs (sortDesc l) := by
  intro l
  induction l with
  | nil => simp [sortDesc, DescTs]
  | cons y ys ih => exact desc_insDesc y _ ih

theorem sortDesc_of_desc : ∀ l : List Entry, DescTs l → sortDesc l = l := by
  intro l
  induction l with
  | nil => intro _; rfl
  | cons y ys ih =>
    intro h
    have h' := h
    simp only [DescTs, List.pairwise_cons] at h'
    show insDesc y (sortDesc ys) = y :: ys
    rw [ih h'.2]
    cases ys with
    | nil => rfl
    | cons z zs => simp [insDesc, h'.1 z (by simp)]

/-! ### Merging a settled library with itself rebuilds it -/

/-- What a merge's output looks like. -/
structure Settled (m : Lib) : Prop where
  rnodup : (m.recents.map Entry.name).Nodup
  rsorted : DescTs m.recents
  tnodup : (m.tomb.map Tomb.name).Nodup
  mnodup : (m.ren.map Ren.src).Nodup
  noself : ∀ r ∈ m.ren, r.src ≠ r.dst
  /-- no surviving marker has an entry at its old name -/
  renFree : ∀ r ∈ m.ren, ∀ x ∈ m.recents, x.name ≠ r.src
  /-- no name has both an entry and a tombstone -/
  tombFree : ∀ t ∈ m.tomb, ∀ x ∈ m.recents, x.name ≠ t.name

theorem foldl_applyRen_absent (E : JMap Entry) (rm : JMap Ren) :
    ∀ (L : List Ren) (d : List Nat), (∀ r ∈ L, E.get r.src = none) →
      L.foldl applyRen (E, rm, d) = (E, rm, d ++ L.map Ren.src) := by
  intro L
  induction L with
  | nil => intro d _; simp
  | cons r rs ih =>
    intro d h
    simp only [List.foldl]
    have : applyRen (E, rm, d) r = (E, rm, d ++ [r.src]) := by
      simp [applyRen, h r (by simp)]
    rw [this, ih _ (fun r' hr' => h r' (by simp [hr']))]
    simp

theorem foldl_pruneStep_absent (E : JMap Entry) (hE : E.WF) (tm : JMap Tomb) :
    ∀ (K : List Nat), (∀ n ∈ K, E.get n = none) → K.foldl pruneStep (E, tm) = (E, tm) := by
  intro K
  induction K with
  | nil => intro _; rfl
  | cons n ns ih =>
    intro h
    simp only [List.foldl]
    have : pruneStep (E, tm) n = (E, tm) := by
      unfold pruneStep
      simp only
      split
      · rfl
      · simp only [h n (by simp), JMap.del_absent E hE n (h n (by simp))]
    rw [this]
    exact ih (fun m hm => h m (by simp [hm]))

theorem merge_settled (m : Lib) (h : Settled m) : mergeLibrary m m = m := by
  have fR := build_fresh Entry.name recStep _ recStep_fresh m.recents JMap.empty JMap.wf_empty
    (fun _ _ => trivial) h.rnodup (by simp)
  have fT := build_fresh Tomb.name tombStep _ tombStep_fresh m.tomb JMap.empty JMap.wf_empty
    (fun _ _ => trivial) h.tnodup (by simp)
  have fM := build_fresh Ren.src renStep _ renStep_fresh m.ren JMap.empty JMap.wf_empty
    h.noself h.mnodup (by simp)
  have hE2 : buildRecents (m.recents ++ m.recents) = buildRecents m.recents :=
    build_twice Entry.name recStep _ recStep_fresh m.recents (fun _ _ => trivial) h.rnodup
  have hT2 : buildTomb (m.tomb ++ m.tomb) = buildTomb m.tomb :=
    build_twice Tomb.name tombStep _ tombStep_fresh m.tomb (fun _ _ => trivial) h.tnodup
  have hM2 : buildRen (m.ren ++ m.ren) = buildRen m.ren :=
    build_twice Ren.src renStep _ renStep_fresh m.ren h.noself h.mnodup
  have vR : (buildRecents m.recents).values = m.recents :=
    values_build Entry.name recStep _ recStep_fresh m.recents (fun _ _ => trivial) h.rnodup
  have vT : (buildTomb m.tomb).values = m.tomb :=
    values_build Tomb.name tombStep _ tombStep_fresh m.tomb (fun _ _ => trivial) h.tnodup
  have vM : (buildRen m.ren).values = m.ren :=
    values_build Ren.src renStep _ renStep_fresh m.ren h.noself h.mnodup
  -- a name no entry holds is absent from the rebuilt recents
  have absent : ∀ n, (∀ x ∈ m.recents, x.name ≠ n) → (buildRecents m.recents).get n = none := by
    intro n hn
    have : n ∉ m.recents.map Entry.name := by
      simp only [List.mem_map, not_exists, not_and]
      intro x hx e; exact hn x hx e
    rw [show buildRecents m.recents = m.recents.foldl recStep JMap.empty from rfl, fR.2.2.2 n this]
    rfl
  have hRen : afterRen m m = (buildRecents m.recents, buildRen m.ren) := by
    unfold afterRen
    simp only [hE2, hM2, vM]
    rw [foldl_applyRen_absent]
    intro r hr
    exact absent r.src (h.renFree r (mem_sortAsc.1 hr))
  have hPrune : afterPrune m m = (buildRecents m.recents, buildTomb m.tomb) := by
    unfold afterPrune
    rw [hRen, hT2]
    simp only
    apply foldl_pruneStep_absent _ fR.1
    intro n hn
    rw [show buildTomb m.tomb = m.tomb.foldl tombStep JMap.empty from rfl, fT.2.1] at hn
    simp only [JMap.empty, List.nil_append, List.mem_map] at hn
    obtain ⟨t, ht, rfl⟩ := hn
    exact absent t.name (h.tombFree t ht)
  unfold mergeLibrary
  rw [hPrune, hRen]
  simp only [vR, vT, vM, sortDesc_of_desc _ h.rsorted]

/-! ### Every merge output is settled -/

theorem JMap.get_none_of_not_mem {V : Type} {m : JMap V} (h : m.WF) {n : Nat} (hk : n ∉ m.keys) :
    m.get n = none := by
  cases hg : m.get n with
  | none => rfl
  | some v => exact absurd ((h.2 n).1 (by simp [hg])) hk

def NoSelf (m : JMap Ren) : Prop := ∀ n r, m.get n = some r → r.src ≠ r.dst

theorem noSelf_del {m : JMap Ren} (h : NoSelf m) (k : Nat) : NoSelf (m.del k) := by
  intro n r hr
  by_cases hn : n = k <;> simp [hn] at hr
  exact h n r hr

theorem renStep_ok {m : JMap Ren} (h1 : m.WF) (h2 : KeyOK Ren.src m) (h3 : NoSelf m) (r : Ren) :
    (renStep m r).WF ∧ KeyOK Ren.src (renStep m r) ∧ NoSelf (renStep m r) := by
  unfold renStep
  split
  · exact ⟨h1, h2, h3⟩
  · rename_i hs
    have hset : NoSelf (m.set r.src r) := by
      intro n x hx
      by_cases hn : n = r.src <;> simp [hn] at hx
      · subst hx; exact hs
      · exact h3 n x hx
    split
    · exact ⟨JMap.wf_set h1 _ _, keyOK_set h2 _ _ rfl, hset⟩
    · split
      · exact ⟨JMap.wf_set h1 _ _, keyOK_set h2 _ _ rfl, hset⟩
      · exact ⟨h1, h2, h3⟩

theorem buildRen_ok (l : List Ren) :
    (buildRen l).WF ∧ KeyOK Ren.src (buildRen l) ∧ NoSelf (buildRen l) := by
  have : ∀ (l : List Ren) (m : JMap Ren), m.WF → KeyOK Ren.src m → NoSelf m →
      (l.foldl renStep m).WF ∧ KeyOK Ren.src (l.foldl renStep m) ∧ NoSelf (l.foldl renStep m) := by
    intro l
    induction l with
    | nil => intro m a b c; exact ⟨a, b, c⟩
    | cons r rs ih =>
      intro m a b c
      obtain ⟨a', b', c'⟩ := renStep_ok a b c r
      exact ih _ a' b' c'
  exact this l JMap.empty JMap.wf_empty (keyOK_empty _) (by intro n r h; simp at h)

theorem claim_get_ne (m : JMap Entry) (k ts n : Nat) (hn : n ≠ k) : (claim m k ts).get n = m.get n := by
  unfold claim
  split
  · split
    · simp [hn]
    · rfl
  · rfl

/-- The marker loop's invariant: a processed marker still standing has no
entry at its old name. `done` is the processed prefix of `L`'s old names. -/
structure RenInv (L : List Ren) (rm : JMap Ren) (st : JMap Entry × JMap Ren × List Nat)
    (rest : List Ren) : Prop where
  free : ∀ n ∈ st.2.2, (st.2.1.get n).isSome = true → st.1.get n = none
  done : st.2.2 ++ rest.map Ren.src = L.map Ren.src
  sub : ∀ n, (st.2.1.get n).isSome = true → (rm.get n).isSome = true
  wf : st.2.1.WF
  key : KeyOK Ren.src st.2.1
  noself : NoSelf st.2.1

theorem renInv_step (L : List Ren) (rm : JMap Ren) (hnd : (L.map Ren.src).Nodup)
    (hself : ∀ r ∈ L, r.src ≠ r.dst) (st : JMap Entry × JMap Ren × List Nat) (r : Ren) (rest : List Ren)
    (hI : RenInv L rm st (r :: rest)) (hr : r ∈ L) : RenInv L rm (applyRen st r) rest := by
  obtain ⟨E, Mk, D⟩ := st
  obtain ⟨i1, i2, i3, iw, ik, isf⟩ := hI
  simp only at i1 i2 i3 iw ik isf
  have hnd' : (D ++ r.src :: rest.map Ren.src).Nodup := by
    rw [← List.map_cons, i2]; exact hnd
  have hrD : r.src ∉ D := by
    intro h; rw [List.nodup_append] at hnd'
    exact hnd'.2.2 r.src h r.src (by simp) rfl
  have hdone : D ++ [r.src] ++ rest.map Ren.src = L.map Ren.src := by
    rw [← i2]; simp
  have hsd : r.src ≠ r.dst := hself r hr
  unfold applyRen
  simp only
  split
  · rename_i he
    refine ⟨?_, hdone, i3, iw, ik, isf⟩
    intro n hn hs
    simp only [List.mem_append, List.mem_singleton] at hn
    rcases hn with hn | rfl
    · exact i1 n hn hs
    · exact he
  · rename_i e he
    split
    · refine ⟨?_, hdone, ?_, JMap.wf_del iw _, keyOK_del ik _, noSelf_del isf _⟩
      · intro n hn hs
        simp only [List.mem_append, List.mem_singleton] at hn
        by_cases hns : n = r.src
        · simp [hns] at hs
        · rcases hn with hn | hn
          · simp [hns] at hs; exact i1 n hn hs
          · exact absurd hn hns
      · intro n hs; by_cases hns : n = r.src <;> simp [hns] at hs; exact i3 n hs
    · have getE : ∀ n, n ≠ r.dst → (claim (match (E.del r.src).get r.dst with
            | none => (E.del r.src).set r.dst ⟨r.dst, e.ts, e.imp⟩
            | some t => if t.ts < e.ts then (E.del r.src).set r.dst ⟨r.dst, e.ts, e.imp⟩
                        else E.del r.src) r.dst r.ts).get n =
            if n = r.src then none else E.get n := by
        intro n hn
        rw [claim_get_ne _ _ _ _ hn]
        split
        · simp [hn]
        · split <;> simp [hn]
      have hMk : ∀ n, ((if r.dst ∈ D then Mk.del r.dst else Mk).get n).isSome = true →
          (Mk.get n).isSome = true ∧ (n = r.dst → r.dst ∉ D) := by
        intro n hs
        split at hs
        · by_cases hnd : n = r.dst <;> simp [hnd] at hs
          exact ⟨hs, fun e => absurd e hnd⟩
        · rename_i hdD
          exact ⟨hs, fun _ => hdD⟩
      refine ⟨?_, hdone, ?_, ?_, ?_, ?_⟩
      · intro n hn hs
        obtain ⟨hs', hnd⟩ := hMk n hs
        simp only [List.mem_append, List.mem_singleton] at hn
        by_cases hnt : n = r.dst
        · rcases hn with hn | hn
          · exact absurd (hnt ▸ hn) (hnd hnt)
          · exact absurd (hn ▸ hnt) hsd
        · rw [getE n hnt]
          split
          · rfl
          · rename_i hns
            rcases hn with hn | hn
            · exact i1 n hn hs'
            · exact absurd hn hns
      · intro n hs; exact i3 n (hMk n hs).1
      · dsimp only; split
        · exact JMap.wf_del iw _
        · exact iw
      · dsimp only; split
        · exact keyOK_del ik _
        · exact ik
      · dsimp only; split
        · exact noSelf_del isf _
        · exact isf

theorem renInv_fold (L : List Ren) (rm : JMap Ren) (hnd : (L.map Ren.src).Nodup)
    (hself : ∀ r ∈ L, r.src ≠ r.dst) :
    ∀ (rest : List Ren) (st : JMap Entry × JMap Ren × List Nat), (∀ r ∈ rest, r ∈ L) →
      RenInv L rm st rest → RenInv L rm (rest.foldl applyRen st) [] := by
  intro rest
  induction rest with
  | nil => intro st _ h; exact h
  | cons r rs ih =>
    intro st hsub h
    exact ih _ (fun x hx => hsub x (by simp [hx]))
      (renInv_step L rm hnd hself st r rs h (hsub r (by simp)))

/-- **After the marker loop, no surviving marker has an entry at its old name**
(each was moved away, and a later move into that name spent the marker). -/
theorem afterRen_free (a b : Lib) :
    (∀ n, ((afterRen a b).2.get n).isSome = true → (afterRen a b).1.get n = none) ∧
    (afterRen a b).2.WF ∧ KeyOK Ren.src (afterRen a b).2 ∧ NoSelf (afterRen a b).2 := by
  obtain ⟨rw', rk, rs⟩ := buildRen_ok (a.ren ++ b.ren)
  have hperm : ((sortAsc (buildRen (a.ren ++ b.ren)).values).map Ren.src).Perm
      (buildRen (a.ren ++ b.ren)).keys := by
    rw [← JMap.values_map_key Ren.src rw' rk]; exact (perm_sortAsc _).map _
  have hnd := hperm.nodup_iff.2 rw'.1
  have hself : ∀ r ∈ sortAsc (buildRen (a.ren ++ b.ren)).values, r.src ≠ r.dst := by
    intro r hr
    obtain ⟨n, hn⟩ := JMap.mem_values (mem_sortAsc.1 hr)
    exact rs n r hn
  have h0 : RenInv (sortAsc (buildRen (a.ren ++ b.ren)).values) (buildRen (a.ren ++ b.ren))
      (buildRecents (a.recents ++ b.recents), buildRen (a.ren ++ b.ren), [])
      (sortAsc (buildRen (a.ren ++ b.ren)).values) :=
    ⟨by simp, by simp, fun _ h => h, rw', rk, rs⟩
  have hF := renInv_fold _ _ hnd hself _ _ (fun _ h => h) h0
  obtain ⟨f1, f2, f3, f4, f5, f6⟩ := hF
  simp only [List.map_nil, List.append_nil] at f2
  refine ⟨?_, f4, f5, f6⟩
  intro n hs
  apply f1 n _ hs
  rw [f2]
  exact hperm.mem_iff.2 ((rw'.2 n).1 (f3 n hs))

theorem afterPrune_facts (a b : Lib) :
    (afterPrune a b).1.WF ∧ NameOK (afterPrune a b).1 ∧ (afterPrune a b).2.WF ∧
      KeyOK Tomb.name (afterPrune a b).2 ∧
    (∀ n x, (afterPrune a b).1.get n = some x → (afterRen a b).1.get n = some x) ∧
    (∀ n, (afterPrune a b).1.get n = none ∨ (afterPrune a b).2.get n = none) := by
  have hR := (afterRen_ok a b).1
  have hT := foldl_tombStep_ok (a.tomb ++ b.tomb) JMap.empty JMap.wf_empty (keyOK_empty _)
  have hP := foldl_pruneStep_ok (buildTomb (a.tomb ++ b.tomb)).keys
    ((afterRen a b).1, buildTomb (a.tomb ++ b.tomb)) ⟨hR.1, hR.2, hT.1, hT.2⟩
  refine ⟨hP.1, hP.2.1, hP.2.2.1, hP.2.2.2, ?_, ?_⟩
  · intro n x hx
    have hG := foldl_pruneStep_get n (buildTomb (a.tomb ++ b.tomb)).keys hT.1.1
      ((afterRen a b).1, buildTomb (a.tomb ++ b.tomb))
    simp only [afterPrune] at hx
    split at hG
    · rw [Prod.mk.injEq] at hG
      rw [hG.1] at hx
      revert hx
      unfold pruneAt
      split
      · exact id
      · split
        · split
          · rename_i e _ _; intro hx; simp at hx; subst hx; assumption
          · intro hx; simp at hx
        · intro hx; simp at hx
    · rw [Prod.mk.injEq] at hG
      rw [hG.1] at hx; exact hx
  · intro n
    have hG := foldl_pruneStep_get n (buildTomb (a.tomb ++ b.tomb)).keys hT.1.1
      ((afterRen a b).1, buildTomb (a.tomb ++ b.tomb))
    simp only [afterPrune]
    split at hG
    · rw [Prod.mk.injEq] at hG
      rw [hG.1, hG.2]
      unfold pruneAt
      split
      · right; rfl
      · split
        · split
          · right; rfl
          · left; rfl
        · left; rfl
    · rename_i hk
      rw [Prod.mk.injEq] at hG
      right; rw [hG.2]
      exact JMap.get_none_of_not_mem hT.1 hk

/-- **Every merge output is settled.** -/
theorem merge_settled_out (a b : Lib) : Settled (mergeLibrary a b) := by
  obtain ⟨free, mw, mk, ms⟩ := afterRen_free a b
  obtain ⟨p1w, p1k, p2w, p2k, pdel, pdis⟩ := afterPrune_facts a b
  have nameOf : ∀ x ∈ (afterPrune a b).1.values, (afterPrune a b).1.get x.name = some x := by
    intro x hx
    obtain ⟨n, hn⟩ := JMap.mem_values hx
    rw [← p1k n x hn] at hn; exact hn
  refine ⟨?_, desc_sortDesc _, ?_, ?_, ?_, ?_, ?_⟩
  · show ((sortDesc (afterPrune a b).1.values).map Entry.name).Nodup
    rw [((perm_sortDesc _).map Entry.name).nodup_iff, JMap.values_map_key Entry.name p1w p1k]
    exact p1w.1
  · show ((afterPrune a b).2.values.map Tomb.name).Nodup
    rw [JMap.values_map_key Tomb.name p2w p2k]; exact p2w.1
  · show ((afterRen a b).2.values.map Ren.src).Nodup
    rw [JMap.values_map_key Ren.src mw mk]; exact mw.1
  · intro r hr
    obtain ⟨n, hn⟩ := JMap.mem_values hr
    exact ms n r hn
  · intro r hr x hx hxr
    obtain ⟨n, hn⟩ := JMap.mem_values hr
    have hn' : (afterRen a b).2.get r.src = some r := by rw [← mk n r hn] at hn; exact hn
    have hnone := free r.src (by simp [hn'])
    have hx' := nameOf x (mem_sortDesc.1 hx)
    rw [hxr] at hx'
    rw [pdel _ _ hx'] at hnone
    cases hnone
  · intro t ht x hx hxt
    have hx' := nameOf x (mem_sortDesc.1 hx)
    obtain ⟨n, hn⟩ := JMap.mem_values ht
    have ht' : (afterPrune a b).2.get t.name = some t := by rw [← p2k n t hn] at hn; exact hn
    rw [hxt] at hx'
    rcases pdis t.name with h | h
    · rw [h] at hx'; cases hx'
    · rw [h] at ht'; cases ht'

/-- **The merge is idempotent, markers included**: merging a merge's output
with itself gives it back, entry for entry and in the same order. -/
theorem merge_idem (a b : Lib) :
    mergeLibrary (mergeLibrary a b) (mergeLibrary a b) = mergeLibrary a b :=
  merge_settled _ (merge_settled_out a b)

/-! ### The pre-fix merge, kept to state what it got wrong

`mergeLibraryV1` is `mergeLibrary` as it was at dd7ba741f: a move neither
claimed its new name nor spent a processed marker from it. -/

def applyRenV1 (st : JMap Entry × JMap Ren) (r : Ren) : JMap Entry × JMap Ren :=
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

def mergeLibraryV1 (a b : Lib) : Lib :=
  let rm := buildRen (a.ren ++ b.ren)
  let ar := (sortAsc rm.values).foldl applyRenV1 (buildRecents (a.recents ++ b.recents), rm)
  let tm := buildTomb (a.tomb ++ b.tomb)
  let ap := tm.keys.foldl pruneStep (ar.1, tm)
  ⟨sortDesc ap.1.values, ap.2.values, ar.2.values⟩

/-- **The old merge was not idempotent** (the finding, restated against the
kept copy): merging its output with itself folds the renamed game into C. -/
theorem bug_mergeV1_not_idempotent :
    let m := mergeLibraryV1 libB2C libA2B
    names m.recents = [3, 1] ∧ names (mergeLibraryV1 m m).recents = [3] := by decide

/-- **...and `imp` on the renamed entry alone did not make it so.** Found by
the model of `renameGame`'s claim without the merge fix (the trace is
`regress_revived_chain` below): device 0 renamed A (1) to B (2) at t=3;
device 1 renamed X (3) into the freed A at t=4 and deleted A at t=5; device 0,
not having pulled, played X at t=6. Device 0's flush merges Drive's library
`D` with its own `L`: X arrives at A by the 3→1 marker, after the older 1→2
marker has run, so the output holds both A and 1→2, and the next merge folds
X into B. -/
theorem bug_mergeV1_chain_not_idempotent :
    let D : Lib := ⟨[⟨2, 3, 3⟩], [⟨1, 5⟩], [⟨3, 1, 4⟩, ⟨1, 2, 3⟩]⟩
    let L : Lib := ⟨[⟨3, 6, 2⟩, ⟨2, 3, 3⟩], [], [⟨1, 2, 3⟩]⟩
    let m := mergeLibraryV1 D L
    names m.recents = [1, 2] ∧ names (mergeLibraryV1 m m).recents = [2] ∧
    names (mergeLibrary D L).recents = [1, 2] := by decide

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
  /-- flushSyncInner after `driveListMap` + `readDriveLibrary` (2855-2858). -/
  | fRead (d : Lib)
  /-- ...after `localLibrary` and the merge; queues settled (2858-2885). -/
  | fMerged (lib : Lib) (revived : List Nat)
  /-- ...after the rename/delete/upload passes (2887-2966). -/
  | fFiles (lib : Lib) (revived : List Nat)
  /-- ...after `writeDriveLibrary` landed (2967). -/
  | fWritten (lib : Lib) (revived : List Nat)
  /-- pullSyncInner after `driveListMap` + `readDriveLibrary` (3113-3114). -/
  | pRead (d : Lib) (remote : List Item)
  | pMerged (lib : Lib) (remote : List Item)
  /-- ...after the remote-rename pass (3116-3142). -/
  | pRenamed (lib : Lib) (remote : List Item)
  /-- ...after the "removed on another device" modal (3144-3166). -/
  | pTombed (lib : Lib) (remote : List Item)
  /-- ...after tomb/ren/recent were adopted; `writeDriveLibrary` pending (3233-3255). -/
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
  /-- ghost: "…is now…— renamed on another device" toasts shown (3139) -/
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

/-- `localLibrary()` (2690-2694). -/
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
  /-- the Sync button (`runFullSync`): every local file queued for upload;
  its flush and pull are the ordinary events -/
  | syncTap (d : Bool)
deriving DecidableEq, Repr

/-! ### flushSyncInner (2837-3002) -/

/-- 2858-2885: merge, then cancel the queued deletes of revived games and the
queued renames of spent markers. -/
def flushMergeDev (dv : Dev) (D : Lib) : Dev :=
  let lib := mergeLibrary D (localLib dv)
  let revived := (dv.tomb.filter (fun t => !lib.tomb.any (fun x => x.name == t.name))).map (·.name)
  let spent := (dv.ren.filter (fun r => !lib.ren.any (fun x => x.src == r.src))).map (·.src)
  { dv with qDel := dv.qDel.filter (fun k => !revived.contains k.1),
            qRen := dv.qRen.filter (fun q => !spent.contains q.1.1),
            pend := .fMerged lib revived }

/-- One queued file rename (2888-2910). -/
def renFile (acc : Dev × List Item) (q : Key × Key) : Dev × List Item :=
  let (dv, files) := acc
  if hasKey files q.1 then
    if hasKey files q.2 then (dv, files.filter (fun i => i.key != q.1))   -- raced: delete the old
    else (dv, files.map (fun i => if i.key == q.1 then { i with game := q.2.1, kind := q.2.2 } else i))
  else if !hasKey files q.2 && !dv.qUp.contains q.2 && hasKey dv.store q.2 then
    ({ dv with qUp := dv.qUp ++ [q.2] }, files)                            -- upload instead
  else (dv, files)

/-- One queued upload (2929-2966): a missing file uploads; a present ROM is
never re-sent; anything else re-uploads. -/
def upFile (dv : Dev) (files : List Item) (k : Key) : List Item :=
  match dv.store.find? (fun i => i.key == k) with
  | none => files
  | some it => if hasKey files k && k.2 == 0 then files else putItem files it

/-- The merged library overrules a queued key: its game is deleted (no later
play), or renamed and not yet migrated here. -/
def tombed (lib : Lib) (k : Key) : Bool := lib.tomb.any (fun t => t.name == k.1)
def renamedAway (lib : Lib) (k : Key) : Bool := lib.ren.any (fun r => r.src == k.1)

/-- The rename and delete passes. -/
def flushPrePass (dv : Dev) (files : List Item) : Dev × List Item :=
  let (dv1, f1) := dv.qRen.foldl renFile (dv, files)
  (dv1, f1.filter (fun i => !dv1.qDel.contains i.key))

/-- 2888-2966 as one event: renames, then deletes, then uploads. The upload
pass asks the library the flush merged (`lib`): a deleted game's keys leave
the queue unsent, a renamed game's wait in it for the pull to move them. -/
def flushFilesDev (dv : Dev) (files : List Item) (lib : Lib) : Dev × List Item :=
  let (dv1, f2) := flushPrePass dv files
  let f3 := (dv1.qUp.filter (fun k => !tombed lib k && !renamedAway lib k)).foldl (upFile dv1) f2
  ({ dv1 with qRen := [], qDel := [], qUp := dv1.qUp.filter (fun k => !tombed lib k && renamedAway lib k) }, f3)

/-- The commit (under `updateRecent`): merge the library the flush wrote with
this device's library *as it is now*, adopt that merge's tombstones and
markers, and put revived games back, all in one segment. -/
def flushCommitDev (dv : Dev) (lib : Lib) (revived : List Nat) : Dev :=
  let L := mergeLibrary lib (localLib dv)
  let add := L.recents.filter (fun r => revived.contains r.name &&
                                        !dv.recent.any (fun h => h.name == r.name))
  { dv with tomb := L.tomb, ren := L.ren,
            recent := if revived.isEmpty || add.isEmpty then dv.recent else sortDesc (dv.recent ++ add),
            pend := .idle }

/-! ### pullSyncInner (3103-3270) -/

/-- `applyRemoteRename(r.from, r.to)` (3010-3086) plus the queueing of
old-name Drive files that follows it (3128-3137). -/
def remoteRename (remote : List Item) (dv : Dev) (r : Ren) : Dev :=
  if !dv.store.any (fun i => i.game == r.src) then dv else           -- hasAnyLocalRecord
  -- dbMoveKeys(..., { skipCollisions: true })
  let mv : List Item × Nat → Nat → List Item × Nat := fun acc k =>
    if hasKey acc.1 (r.src, k) && !hasKey acc.1 (r.dst, k) then
      (acc.1.map (fun i => if i.key == (r.src, k) then { i with game := r.dst } else i), acc.2 + 1)
    else acc
  let (st1, moved) := kinds.foldl mv (dv.store, 0)
  -- collided pairs holding identical bytes: the old-name copy is dropped (3076-3083)
  let st2 := st1.filter (fun i => !(i.game == r.src &&
                st1.any (fun j => j.key == (r.dst, i.kind) && j.blob == i.blob)))
  let mapKey : Key → Key := fun k => if k.1 == r.src then (r.dst, k.2) else k
  let qRen1 := dv.qRen.map (fun q => (mapKey q.1, q.2))
  let qRen2 := kinds.foldl (fun q k =>
    if hasKey remote (r.src, k) && !q.any (fun x => x.1 == (r.src, k))
    then q ++ [((r.src, k), (r.dst, k))] else q) qRen1
  { dv with store := st2, qUp := dedup (dv.qUp.map mapKey), qDel := dedup (dv.qDel.map mapKey),
            qRen := qRen2, toasts := dv.toasts + (if moved > 0 then 1 else 0) }

/-- 3144-3166: "Games removed on another device". -/
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

/-- Reconcile upward, then (under `updateRecent`) merge the pull's library
with this device's library as it is now and adopt that merge: tombstones,
markers and "recent" in one segment. The merge is what is written to Drive. -/
def pullCommitDev (dv : Dev) (lib : Lib) (remote : List Item) : Dev :=
  let missing := (dv.store.filter (fun i => !hasKey remote i.key &&
                    !lib.tomb.any (fun t => t.name == i.game))).map Item.key
  let L := mergeLibrary lib (localLib dv)
  -- Drive files of a game the adopted library has deleted: queued for
  -- deletion (`markDelete`, which also unqueues them)
  let orphans := (remote.filter (fun i => tombed L i.key)).map Item.key
  { dv with qUp := (missing.foldl addUniq dv.qUp).filter (fun k => !orphans.contains k),
            qDel := orphans.foldl addUniq dv.qDel, tomb := L.tomb, ren := L.ren,
            recent := L.recents, pend := .pCommitted L }

/-! ### The user's actions -/

/-- `deleteGameEverywhere` (3358-3380), signed in. -/
def deleteDev (dv : Dev) (g now : Nat) : Dev :=
  { dv with store := dv.store.filter (fun i => i.game != g),
            recent := dv.recent.filter (fun r => r.name != g),
            qDel := (keysOf g).foldl addUniq dv.qDel,
            qUp := dv.qUp.filter (fun k => k.1 != g),
            tomb := dv.tomb.filter (fun t => t.name != g) ++ [⟨g, now⟩] }

/-- `renameGame` (3469-3598) past its checks: one `dbMoveKeys` transaction
moves every record, writes "recent" and the new sync state. -/
def renameOk (dv : Dev) (a b : Nat) : Bool :=
  a != b && !dv.recent.any (fun r => r.name == b) && !dv.store.any (fun i => i.game == b)

def renameDev (dv : Dev) (a b now : Nat) : Dev :=
  let mirrored := (keysOf a).filter (fun k => !dv.qDel.contains k)
  let newOf : Key → Key := fun k => if mirrored.contains k then (b, k.2) else k
  { dv with
    store := dv.store.map (fun i => if i.game == a then { i with game := b } else i),
    -- the new entry claims its name at the rename's moment (`imp: ts`)
    recent := if dv.recent.any (fun r => r.name == a)
              then ⟨b, now, now⟩ :: dv.recent.filter (fun r => r.name != a) else dv.recent,
    qUp := dedup (dv.qUp.map newOf),
    qDel := dv.qDel.filter (fun k => !(mirrored.map newOf).contains k),
    qRen := dv.qRen ++ mirrored.map (fun k => (k, (b, k.2))),
    tomb := dv.tomb.filter (fun t => t.name != a && t.name != b),
    ren := dv.ren.filter (fun r => r.src != a && r.src != b) ++ [⟨a, b, now⟩] }

/-- `bumpRecentIndex` (4702-4722). -/
def bump (dv : Dev) (g now : Nat) (fresh : Bool) : List Entry :=
  let prev := dv.recent.find? (fun r => r.name == g)
  let ts := if fresh then now else
    match dv.ren.find? (fun r => r.src == g) with
    | some m => if m.ts != 0 && now ≥ m.ts then m.ts - 1 else now
    | none => now
  let imp := if fresh then now else (prev.map (·.imp)).getD 0
  ⟨g, ts, imp⟩ :: dv.recent.filter (fun r => r.name != g)

/-- `addRecentRom` (4737-4753): ROM bytes, then a fresh import, then upload. -/
def importDev (dv : Dev) (g blob now : Nat) : Dev :=
  let st := putItem dv.store ⟨g, 0, blob⟩
  { dv with store := st, recent := bump dv g now true,
            qUp := ((st.filter (fun i => i.game == g)).map Item.key).foldl addUniq dv.qUp }

/-- A launch (`touchRecent`) and a battery save (`persistSave` + `markUpload`). -/
def playDev (dv : Dev) (g blob now : Nat) : Dev :=
  { dv with recent := bump dv g now false, store := putItem dv.store ⟨g, 1, blob⟩,
            qUp := addUniq dv.qUp (g, 1) }

/-- `downloadGame` (3282-3316). -/
def downloadDev (dv : Dev) (files : List Item) (g now : Nat) : Dev :=
  let fs := files.filter (fun f => f.game == g)
  if fs.isEmpty then dv
  else { dv with store := fs.foldl putItem dv.store, recent := bump dv g now false }

/-- `runFullSync`'s queueing: every key this device holds. -/
def syncTapDev (dv : Dev) : Dev := { dv with qUp := (dv.store.map Item.key).foldl addUniq dv.qUp }

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
      let r := flushFilesDev (s.dev d) s.files lib
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
  | .syncTap d => s.setDev d (syncTapDev (s.dev d))

def run (s : St) (es : List Ev) : St := es.foldl step s

inductive Reachable : St → Prop
  | init : Reachable init
  | step {s : St} (e : Ev) : Reachable s → Reachable (step s e)

/-- One uninterrupted sync of each kind. -/
def flush (d : Bool) : List Ev := [.flushRead d, .flushMerge d, .flushFiles d, .flushWrite d, .flushCommit d]
def pull (d : Bool) : List Ev :=
  [.pullRead d, .pullMerge d, .pullRenames d, .pullTombs d false, .pullCommit d, .pullWrite d]

/-! ## Layer 2a: what the protocol keeps -/

@[simp] theorem dev_with_lib (s : St) (L : Lib) (d : Bool) : ({ s with lib := L } : St).dev d = s.dev d := by
  cases d <;> rfl
@[simp] theorem dev_with_files (s : St) (F : List Item) (d : Bool) :
    ({ s with files := F } : St).dev d = s.dev d := by
  cases d <;> rfl
@[simp] theorem localLib_pend (dv : Dev) (p : Pend) : localLib { dv with pend := p } = localLib dv := rfl

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

theorem flushFilesDev_tomb (dv : Dev) (files : List Item) (lib : Lib) :
    (flushFilesDev dv files lib).1.tomb = dv.tomb := by
  unfold flushFilesDev flushPrePass
  exact foldl_renFile_tomb dv.qRen (dv, files)

/-- The file passes leave the device's library alone. -/
theorem renFile_lib (acc : Dev × List Item) (q : Key × Key) :
    localLib (renFile acc q).1 = localLib acc.1 := by
  unfold renFile
  repeat' split
  all_goals rfl

theorem foldl_renFile_lib (L : List (Key × Key)) :
    ∀ acc : Dev × List Item, localLib (L.foldl renFile acc).1 = localLib acc.1 := by
  induction L with
  | nil => intro acc; rfl
  | cons q qs ih => intro acc; simp only [List.foldl]; rw [ih, renFile_lib]

@[simp] theorem flushFilesDev_lib (dv : Dev) (files : List Item) (lib : Lib) :
    localLib (flushFilesDev dv files lib).1 = localLib dv := by
  have h := foldl_renFile_lib dv.qRen (dv, files)
  unfold flushFilesDev flushPrePass
  simp only [localLib] at h ⊢
  exact h

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
    (flushCommitDev dv lib rv).tomb = (mergeLibrary lib (localLib dv)).tomb := rfl
@[simp] theorem flushCommitDev_pend (dv : Dev) (lib : Lib) (rv : List Nat) :
    (flushCommitDev dv lib rv).pend = .idle := rfl
@[simp] theorem pullCommitDev_tomb (dv : Dev) (lib : Lib) (R : List Item) :
    (pullCommitDev dv lib R).tomb = (mergeLibrary lib (localLib dv)).tomb := rfl
@[simp] theorem pullCommitDev_pend (dv : Dev) (lib : Lib) (R : List Item) :
    (pullCommitDev dv lib R).pend = .pCommitted (mergeLibrary lib (localLib dv)) := rfl
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
    (hp : dv.pend = .fMerged lib rv) : DSub { (flushFilesDev dv F lib).1 with pend := .fFiles lib rv } dv := by
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

/-- A commit's re-merge only draws on the continuation's library and the
device's own tombstones. -/
theorem remerge_tomb_sub (dv : Dev) (lib : Lib) {t : Tomb}
    (hlib : ∀ t ∈ lib.tomb, t ∈ devTombs dv) (ht : t ∈ (mergeLibrary lib (localLib dv)).tomb) :
    t ∈ devTombs dv := by
  rcases List.mem_append.1 (merge_tomb_sub _ _ ht) with h | h
  · exact hlib t h
  · exact tomb_sub h

theorem dsub_flushCommit (dv : Dev) (lib : Lib) (rv : List Nat) (hp : dv.pend = .fWritten lib rv) :
    DSub (flushCommitDev dv lib rv) dv := by
  intro t ht
  simp only [devTombs, List.mem_append, flushCommitDev_tomb, flushCommitDev_pend, pendTombs,
    List.not_mem_nil, or_false] at ht
  exact remerge_tomb_sub dv lib (fun t h => pend_sub (by rw [hp]; exact h)) ht

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
  exact remerge_tomb_sub dv lib (fun t h => pend_sub (by rw [hp]; exact h)) ht

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
  | syncTap d =>
    left; dsimp only [step] at ht
    exact setDev_sub s d (syncTapDev (s.dev d)) (dsub_same _ _ rfl rfl) ht

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
  | .syncTap d => d

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

/-! The steps of one flush, each from the continuation it resumes. -/

/-! ### No commit drops a tombstone the device holds

This is what the stale commits broke (`regress_delete_during_flush`,
`regress_delete_during_pull`): now, over every interleaving, a tombstone a
device holds is only ever given up for a newer play of that name in the
library the commit adopts ("a later play says the delete was not meant"),
or by the person renaming or deleting that game on this device. -/

/-- The library a commit about to run on this device would adopt: the
continuation's library re-merged with the device's library as it is now. -/
def adopting (dv : Dev) : Option Lib :=
  match dv.pend with
  | .fWritten lib _ => some (mergeLibrary lib (localLib dv))
  | .pTombed lib _ => some (mergeLibrary lib (localLib dv))
  | _ => none

theorem pullTombsDev_tomb (dv : Dev) (lib : Lib) (R : List Item) (r : Bool) (n : Nat) :
    (pullTombsDev dv lib R r n).tomb = dv.tomb := by
  unfold pullTombsDev; simp only; split
  · rfl
  · split <;> rfl

theorem step_keeps_tomb (s : St) (e : Ev) (d : Bool) (t : Tomb) (ht : t ∈ (s.dev d).tomb) :
    (∃ t' ∈ ((step s e).dev d).tomb, t'.name = t.name ∧ t.ts ≤ t'.ts) ∨
    (∃ L, adopting (s.dev d) = some L ∧ ∃ x ∈ L.recents, x.name = t.name ∧ t.ts < x.ts) ∨
    (∃ b, e = .rename d t.name b ∨ e = .rename d b t.name) ∨
    e = .delete d t.name := by
  have keep : ((step s e).dev d).tomb = (s.dev d).tomb →
      (∃ t' ∈ ((step s e).dev d).tomb, t'.name = t.name ∧ t.ts ≤ t'.ts) :=
    fun h => ⟨t, h ▸ ht, rfl, Nat.le_refl _⟩
  by_cases hd : e.dev ≠ d
  · exact Or.inl (keep (by rw [step_other_dev s e d hd]))
  have hd : e.dev = d := by simpa using hd
  have hmem : t ∈ (localLib (s.dev d)).tomb := ht
  cases e with
  | flushRead d' =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by simp only [step]; split <;> first | rfl | (cases d' <;> simp [St.setDev, St.dev])))
  | flushMerge d' =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by simp only [step]; split <;> first | rfl | (cases d' <;> simp [St.setDev, St.dev])))
  | flushFiles d' =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by simp only [step]; split <;> first | rfl | (cases d' <;> simp [St.setDev, St.dev, flushFilesDev_tomb])))
  | flushWrite d' =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by simp only [step]; split <;> first | rfl | (cases d' <;> simp [St.setDev, St.dev])))
  | flushCommit d' =>
    simp only [Ev.dev] at hd; subst hd
    cases hp : (s.dev d').pend with
    | fWritten lib rv =>
      have hs : (step s (.flushCommit d')).dev d' = flushCommitDev (s.dev d') lib rv := by
        simp only [step, hp]; simp
      rcases merge_tomb_survives lib (localLib (s.dev d')) t (List.mem_append_right _ hmem) with h | h
      · left; rw [hs, flushCommitDev_tomb]; exact h
      · right; left; exact ⟨_, by simp [adopting, hp], h⟩
    | _ => exact Or.inl (keep (by simp [step, hp]))
  | pullRead d' =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by simp only [step]; split <;> first | rfl | (cases d' <;> simp [St.setDev, St.dev])))
  | pullMerge d' =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by simp only [step]; split <;> first | rfl | (cases d' <;> simp [St.setDev, St.dev])))
  | pullRenames d' =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by simp only [step]; split <;> first | rfl | (cases d' <;> simp [St.setDev, St.dev, foldl_remoteRename_tomb])))
  | pullTombs d' restore =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by simp only [step]; split <;> first | rfl | (cases d' <;> simp [St.setDev, St.dev, pullTombsDev_tomb])))
  | pullCommit d' =>
    simp only [Ev.dev] at hd; subst hd
    cases hp : (s.dev d').pend with
    | pTombed lib R =>
      have hs : (step s (.pullCommit d')).dev d' = pullCommitDev (s.dev d') lib R := by
        simp only [step, hp]; simp
      rcases merge_tomb_survives lib (localLib (s.dev d')) t (List.mem_append_right _ hmem) with h | h
      · left; rw [hs, pullCommitDev_tomb]; exact h
      · right; left; exact ⟨_, by simp [adopting, hp], h⟩
    | _ => exact Or.inl (keep (by simp [step, hp]))
  | pullWrite d' =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by simp only [step]; split <;> first | rfl | (cases d' <;> simp [St.setDev, St.dev])))
  | delete d' g =>
    simp only [Ev.dev] at hd; subst hd
    by_cases hg : g = t.name
    · subst hg; exact Or.inr (Or.inr (Or.inr rfl))
    · left
      refine ⟨t, ?_, rfl, Nat.le_refl _⟩
      have : ((step s (.delete d' g)).dev d') = deleteDev (s.dev d') g s.now := by
        cases d' <;> rfl
      rw [this, deleteDev_tomb]
      simp only [List.mem_append, List.mem_filter]
      left; exact ⟨ht, by simpa using fun h => hg h.symm⟩
  | rename d' a b =>
    simp only [Ev.dev] at hd; subst hd
    by_cases ha : a = t.name
    · subst ha; exact Or.inr (Or.inr (Or.inl ⟨b, Or.inl rfl⟩))
    by_cases hb : b = t.name
    · subst hb; exact Or.inr (Or.inr (Or.inl ⟨a, Or.inr rfl⟩))
    left
    refine ⟨t, ?_, rfl, Nat.le_refl _⟩
    simp only [step]
    split
    · have : (({ s.setDev d' (renameDev (s.dev d') a b s.now) with now := s.now + 1 } : St).dev d') =
          renameDev (s.dev d') a b s.now := by cases d' <;> rfl
      rw [this, renameDev_tomb, List.mem_filter]
      refine ⟨ht, ?_⟩
      simp only [Bool.and_eq_true, bne_iff_ne, ne_eq]
      exact ⟨fun h => ha h.symm, fun h => hb h.symm⟩
    · exact ht
  | importRom d' g blob =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by
      have : ((step s (.importRom d' g blob)).dev d') = importDev (s.dev d') g blob s.now := by
        cases d' <;> rfl
      rw [this]; rfl))
  | play d' g blob =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by
      simp only [step]; split
      · have : (({ s.setDev d' (playDev (s.dev d') g blob s.now) with now := s.now + 1 } : St).dev d') =
            playDev (s.dev d') g blob s.now := by cases d' <;> rfl
        rw [this]; rfl
      · rfl))
  | download d' g =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by
      have : ((step s (.download d' g)).dev d') = downloadDev (s.dev d') s.files g s.now := by
        cases d' <;> rfl
      rw [this, downloadDev_tomb]))
  | syncTap d' =>
    simp only [Ev.dev] at hd; subst hd
    exact Or.inl (keep (by
      have : ((step s (.syncTap d')).dev d') = syncTapDev (s.dev d') := by cases d' <;> rfl
      rw [this]; rfl))


theorem step_flushRead_of (s : St) (d : Bool) (h : (s.dev d).pend = .idle) :
    (step s (.flushRead d)).dev d = { s.dev d with pend := .fRead s.lib } ∧
    (step s (.flushRead d)).lib = s.lib := by
  simp only [step, h]; exact ⟨by simp, by simp⟩
theorem step_flushMerge_of (s : St) (d : Bool) (D : Lib) (h : (s.dev d).pend = .fRead D) :
    (step s (.flushMerge d)).dev d = flushMergeDev (s.dev d) D ∧ (step s (.flushMerge d)).lib = s.lib := by
  simp only [step, h]; exact ⟨by simp, by simp⟩
theorem step_flushFiles_of (s : St) (d : Bool) (lib : Lib) (rv : List Nat)
    (h : (s.dev d).pend = .fMerged lib rv) :
    (step s (.flushFiles d)).dev d = { (flushFilesDev (s.dev d) s.files lib).1 with pend := .fFiles lib rv } ∧
    (step s (.flushFiles d)).lib = s.lib := by
  simp only [step, h]; constructor <;> cases d <;> first | rfl | trivial
theorem step_flushWrite_of (s : St) (d : Bool) (lib : Lib) (rv : List Nat)
    (h : (s.dev d).pend = .fFiles lib rv) :
    (step s (.flushWrite d)).dev d = { s.dev d with pend := .fWritten lib rv } ∧
    (step s (.flushWrite d)).lib = lib := by
  simp only [step, h]; constructor <;> cases d <;> first | rfl | trivial
theorem step_flushCommit_of (s : St) (d : Bool) (lib : Lib) (rv : List Nat)
    (h : (s.dev d).pend = .fWritten lib rv) :
    (step s (.flushCommit d)).dev d = flushCommitDev (s.dev d) lib rv ∧
    (step s (.flushCommit d)).lib = s.lib := by
  simp only [step, h]; exact ⟨by simp, by simp⟩

/-- **An uninterrupted flush** writes the merge of Drive's library and the
device's, then commits it into a device whose library is the one it started
with (the file passes do not touch it). -/
theorem run_flush (s : St) (d : Bool) (hidle : (s.dev d).pend = .idle) :
    (run s (flush d)).lib = mergeLibrary s.lib (localLib (s.dev d)) ∧
    ∃ dv' rv, (run s (flush d)).dev d =
        flushCommitDev dv' (mergeLibrary s.lib (localLib (s.dev d))) rv ∧
      localLib dv' = localLib (s.dev d) := by
  have e : run s (flush d) = step (step (step (step (step s (.flushRead d)) (.flushMerge d))
      (.flushFiles d)) (.flushWrite d)) (.flushCommit d) := rfl
  rw [e]
  obtain ⟨d1, l1⟩ := step_flushRead_of s d hidle
  generalize step s (.flushRead d) = s1 at d1 l1
  obtain ⟨d2, l2⟩ := step_flushMerge_of s1 d s.lib (by rw [d1])
  generalize step s1 (.flushMerge d) = s2 at d2 l2
  obtain ⟨rv, hrv⟩ : ∃ rv, (s2.dev d).pend = .fMerged (mergeLibrary s.lib (localLib (s.dev d))) rv := by
    rw [d2, d1]; exact ⟨_, rfl⟩
  have loc2 : localLib (s2.dev d) = localLib (s.dev d) := by rw [d2, d1]; rfl
  obtain ⟨d3, l3⟩ := step_flushFiles_of s2 d _ rv hrv
  generalize step s2 (.flushFiles d) = s3 at d3 l3
  obtain ⟨d4, l4⟩ := step_flushWrite_of s3 d _ rv (by rw [d3])
  generalize step s3 (.flushWrite d) = s4 at d4 l4
  obtain ⟨d5, l5⟩ := step_flushCommit_of s4 d _ rv (by rw [d4])
  generalize step s4 (.flushCommit d) = s5 at d5 l5
  refine ⟨by rw [l5, l4], _, rv, d5, ?_⟩
  rw [d4, localLib_pend, d3, localLib_pend, flushFilesDev_lib, loc2]

/-- **A device's next uninterrupted flush re-asserts every tombstone it
holds** (or the library now holds a newer entry for that name: a later play
revived the game). So a Drive lost update delays a tombstone, never loses it,
as long as it was in `syncState.tomb` when the flush merged. -/
theorem resync_reasserts_tomb (s : St) (d : Bool) (hidle : (s.dev d).pend = .idle)
    (t : Tomb) (ht : t ∈ (s.dev d).tomb) :
    ((∃ t' ∈ (run s (flush d)).lib.tomb, t'.name = t.name ∧ t.ts ≤ t'.ts) ∨
     (∃ e ∈ (run s (flush d)).lib.recents, e.name = t.name ∧ t.ts < e.ts)) ∧
    ((∃ t' ∈ ((run s (flush d)).dev d).tomb, t'.name = t.name ∧ t.ts ≤ t'.ts) ∨
     (∃ e ∈ (mergeLibrary (run s (flush d)).lib (localLib (s.dev d))).recents,
        e.name = t.name ∧ t.ts < e.ts)) := by
  obtain ⟨hlib, dv', rv, hdev, hloc⟩ := run_flush s d hidle
  have hmem : t ∈ (localLib (s.dev d)).tomb := by simp [localLib, ht]
  refine ⟨?_, ?_⟩
  · rw [hlib]; exact merge_tomb_survives _ _ t (List.mem_append_right _ hmem)
  · rw [hdev, hlib, flushCommitDev_tomb, hloc]
    exact merge_tomb_survives _ _ t (List.mem_append_right _ hmem)

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

/-! ## Layer 2b: the findings' traces, run against the fixed code

Each trace is a list of events run from `init`; every event is one JS
segment between awaits, fired in an order a browser allows. Each was a
`bug_*` against dd7ba741f; each is now a `regress_*` showing the same trace
ends safely. The general statements behind them are `step_keeps_tomb`
(Layer 2a) and `merge_idem` (Layer 1d). -/

set_option maxRecDepth 8000

/-- Device 0 imports game 7 (ROM bytes 70) and syncs; device 1 pulls the
library and downloads the game. -/

def setupA : List Ev := [.importRom false 7 70] ++ flush false ++ pull true ++ [.download true 7]

/-- Device 0 plays 7 (save 71), which schedules a flush. While that flush is
still in flight (past its merge, while the save is uploading or the library
write is awaiting) the person taps Delete on 7. -/
def raceA : List Ev :=
  [.play false 7 71, .flushRead false, .flushMerge false, .flushFiles false,
   .delete false 7, .flushWrite false, .flushCommit false]

/-- Ordinary syncs afterwards (triggers: 2s debounce, visibilitychange, the
3-minute poll). -/
def settleA : List Ev := flush false ++ pull false ++ pull true ++ flush true ++ pull false

/-- **Fixed: a delete made while a flush is in flight sticks** (was
`bug_delete_during_flush_resurrects`, where the commit's stale merge dropped
the tombstone for good and ordinary syncs brought 7 back everywhere). The
commit's re-merge keeps the tombstone; the syncs carry it to Drive and to
device 1, which removes the game and its files. -/
theorem regress_delete_during_flush :
    let s1 := run init (setupA ++ raceA)
    let s2 := run s1 settleA
    s1.deleted = [⟨7, 4⟩] ∧ (⟨7, 4⟩ : Tomb) ∈ s1.d0.tomb ∧
    s2.lib.tomb = [⟨7, 4⟩] ∧ names s2.lib.recents = [] ∧ names s2.d0.recent = [] ∧
    names s2.d1.recent = [] ∧ s2.d1.store = [] ∧ s2.files = [] := by
  decide

/-- The trace is a run of the model. -/
theorem raceA_reachable : Reachable (run init (setupA ++ raceA ++ settleA)) :=
  run_reachable Reachable.init _

/-- A pull in flight on device 0; the person deletes 7 while it is downloading
saves/pictures, after its merge. -/
def raceB : List Ev :=
  [.pullRead false, .pullMerge false, .pullRenames false, .pullTombs false false,
   .delete false 7, .pullCommit false]

/-- **Fixed: a delete made while a pull is in flight stays deleted** (was
`bug_delete_during_pull_resurrects`): no tile comes back, the tombstone is
kept, and the pull's own library write already carries it to Drive. -/
theorem regress_delete_during_pull :
    let s := run init (setupA ++ raceB ++ [.pullWrite false])
    names s.d0.recent = [] ∧ s.d0.tomb = [⟨7, 3⟩] ∧ s.lib.tomb = [⟨7, 3⟩] := by
  decide

/-- A pull in flight on device 0; the person imports game 9 (ROM 90), e.g.
the file picker closing fires visibilitychange, whose flush-then-pull races
the import. -/
def raceC : List Ev :=
  [.pullRead false, .pullMerge false, .importRom false 9 90, .pullRenames false,
   .pullTombs false false, .pullCommit false, .pullWrite false]

/-- **Fixed: a game imported while a pull is in flight keeps its tile and
reaches the library** (was `bug_import_during_pull_orphans`). -/
theorem regress_import_during_pull :
    let s := run init (raceC ++ flush false ++ pull false)
    names s.d0.recent = [9] ∧ names s.lib.recents = [9] ∧ hasKey s.files (9, 0) = true := by
  decide

/-- Import game 1 (ROM 10, save 11); rename 1→2 and sync; rename it back
2→1 and flush. -/
def setupD : List Ev := [.importRom false 1 10, .play false 1 11] ++ flush false ++
  [.rename false 1 2] ++ flush false ++ pull false ++ [.rename false 2 1] ++ flush false

def cycleD : List Ev := pull false ++ flush false

/-- **Fixed: renaming a game back settles** (was `bug_rename_undo_oscillates`,
where every pull re-applied 1→2 then 2→1, toasting twice, and the Drive files
flipped names on every sync). The undo's entry claims name 1, which spends the
old 1→2 marker: after one sync cycle nothing changes any more. -/
theorem regress_rename_undo_settles :
    let s1 := run init (setupD ++ cycleD)
    run s1 cycleD = s1 ∧ s1.d0.toasts = 0 ∧ s1.files.map (·.game) = [1, 1] ∧
    names s1.lib.recents = [1] ∧ s1.d0.store.map (·.game) = [1, 1] := by
  decide +kernel

/-- **Fixed: a save made after the undo reaches Drive and stays** (was
`bug_rename_undo_loses_save`, where the churn deleted the newest save as a
"raced duplicate" and a second device downloaded the old one). -/
theorem regress_rename_undo_keeps_save :
    let s := run init (setupD ++ cycleD ++ [.play false 1 12] ++ flush false ++ cycleD ++
      [.download true 1])
    (⟨1, 1, 12⟩ : Item) ∈ s.d0.store ∧ (⟨1, 1, 12⟩ : Item) ∈ s.files ∧
    (⟨1, 1, 11⟩ : Item) ∉ s.files ∧ (⟨1, 1, 12⟩ : Item) ∈ s.d1.store := by
  decide

/-- **Fixed: after the undo, a play moves the game up again** (was
`bug_rename_undo_freezes_recency`: the never-retired 1→2 marker pinned every
play under it). -/
theorem regress_rename_undo_recency :
    let s1 := run init (setupD ++ cycleD ++ [.play false 1 12])
    let s2 := run s1 (flush false ++ pull false)
    s1.now = 6 ∧ s1.d0.recent = [⟨1, 5, 4⟩] ∧ s2.lib.recents = [⟨1, 5, 4⟩] := by
  decide

/-- Games "B" (1, ROM 10, no save) and "A" (2, ROM 20, save 21); rename B→C
(1→3) and sync. -/
def setupE : List Ev := [.importRom false 1 10, .importRom false 2 20, .play false 2 21] ++
  flush false ++ pull false ++ [.rename false 1 3] ++ flush false ++ pull false

/-- **Fixed: renaming a game into a name another game was renamed away from
keeps the two apart** (was `bug_rename_into_retired_name`, where the stale
B→C marker captured the renamed game and moved its save onto C's ROM). -/
theorem regress_rename_into_retired_name :
    let s1 := run init (setupE ++ [.rename false 2 1] ++ flush false ++ pull false)
    let s2 := run s1 (flush false)
    names s1.d0.recent = [1, 3] ∧ names s1.lib.recents = [1, 3] ∧
    (⟨1, 0, 20⟩ : Item) ∈ s1.d0.store ∧ (⟨1, 1, 21⟩ : Item) ∈ s1.d0.store ∧
    s2.files = [⟨3, 0, 10⟩, ⟨1, 0, 20⟩, ⟨1, 1, 21⟩] := by
  decide

/-- Device 0 imports 5 and syncs; device 1 pulls and downloads it. -/
def setupF : List Ev := [.importRom false 5 50] ++ flush false ++ pull true ++ [.download true 5]

/-- Device 1 reads the library; device 0 deletes 5 and flushes (Drive now
has the tombstone); device 1 finishes its flush and overwrites the library
with its stale merge. No If-Match / revision check on the library write. -/
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

/-- A pull in flight; the person renames game 1 to 2 while it downloads. -/
def raceG : List Ev := [.importRom false 1 10] ++ flush false ++
  [.pullRead false, .pullMerge false, .rename false 1 2, .pullRenames false,
   .pullTombs false false, .pullCommit false, .pullWrite false]

/-- **Fixed: a rename made while a pull is in flight keeps its marker and its
tile** (was `bug_rename_during_pull_orphans`). -/
theorem regress_rename_during_pull :
    let s := run init (raceG ++ flush false ++ pull false)
    names s.d0.recent = [2] ∧ s.d0.store = [⟨2, 0, 10⟩] ∧ s.d0.ren = [⟨1, 2, 2⟩] ∧
    s.lib.ren = [⟨1, 2, 2⟩] ∧ s.files = [⟨2, 0, 10⟩] := by
  decide

/-- Found by the model of the first fix (`renameGame`'s claim alone): device 0
renames A (1) to B (2); device 1 renames X (3) into the freed A, then deletes
A; device 0, not having pulled, plays X (a later play overrules the delete, so
X lives on as A). -/
def chainH : List Ev :=
  [.importRom false 1 10, .importRom false 3 30] ++ flush false ++ pull true ++
  [.rename false 1 2] ++ flush false ++ pull true ++
  [.rename true 3 1] ++ flush true ++ [.delete true 1] ++ flush true ++
  [.play false 3 31] ++ flush false

/-- **Fixed: the game renamed into a retired name by another device is not
folded on by the old marker.** With the claim on `renameGame` only, the next
merge applied the stale 1→2 marker to X (now A): the library lost X, and X's
save (31) was moved under B beside B's ROM (10) (`bug_mergeV1_chain_not_idempotent`
is the merge that did it). With the merge's claim, X stays A, with its own ROM
and save, on the device and on Drive. -/
theorem regress_revived_chain :
    let s := run init (chainH ++ pull false ++ flush false ++ pull false)
    names s.d0.recent = [1, 2] ∧ names s.lib.recents = [1, 2] ∧
    s.d0.store = [⟨2, 0, 10⟩, ⟨1, 0, 30⟩, ⟨1, 1, 31⟩] ∧
    s.files = [⟨2, 0, 10⟩, ⟨1, 1, 31⟩, ⟨1, 0, 30⟩] := by
  decide


/-! ### What a flush may put on Drive, and what a pull takes back down

Found by a two-device UI run: a device that had not pulled a delete re-uploaded
the deleted game on a Sync tap (its flush uploaded every queued key Drive
lacked, without asking the library it had just merged), and nothing ever took
those files down. -/

theorem mem_putItem {l : List Item} {it i : Item} (h : i ∈ putItem l it) : i ∈ l ∨ i = it := by
  simp only [putItem, List.mem_append, List.mem_filter, List.mem_singleton] at h
  rcases h with ⟨h, _⟩ | h
  · exact Or.inl h
  · exact Or.inr h

theorem upFile_mem (dv : Dev) (f : List Item) (k : Key) {i : Item} (h : i ∈ upFile dv f k) :
    i ∈ f ∨ i.key = k := by
  unfold upFile at h
  split at h
  · exact Or.inl h
  · rename_i it hit
    have hk : (it.key == k) = true := List.find?_some (p := fun (i : Item) => i.key == k) hit
    split at h
    · exact Or.inl h
    · rcases mem_putItem h with h | rfl
      · exact Or.inl h
      · exact Or.inr (by simpa using hk)

theorem foldl_upFile_mem (dv : Dev) (P : Key → Prop) : ∀ (ks : List Key) (f : List Item),
    (∀ k ∈ ks, P k) → ∀ i ∈ ks.foldl (upFile dv) f, i ∈ f ∨ P i.key := by
  intro ks
  induction ks with
  | nil => intro f _ i hi; exact Or.inl hi
  | cons k ks ih =>
    intro f hP i hi
    rcases ih (upFile dv f k) (fun k' hk' => hP k' (by simp [hk'])) i hi with h | h
    · rcases upFile_mem dv f k h with h | h
      · exact Or.inl h
      · exact Or.inr (h ▸ hP k (by simp))
    · exact Or.inr h

/-- **A flush uploads nothing the library it merged overrules**: every file
Drive holds after the flush's file passes was there after its renames and
deletes, or is a key whose game the merged library neither deleted nor
renamed away. -/
theorem flush_uploads_only_live (dv : Dev) (files : List Item) (lib : Lib) :
    ∀ i ∈ (flushFilesDev dv files lib).2,
      i ∈ (flushPrePass dv files).2 ∨ (tombed lib i.key = false ∧ renamedAway lib i.key = false) := by
  intro i hi
  unfold flushFilesDev at hi
  simp only at hi
  rcases foldl_upFile_mem _ (fun k => tombed lib k = false ∧ renamedAway lib k = false) _ _
      (by intro k hk; simp only [List.mem_filter, Bool.and_eq_true, Bool.not_eq_true'] at hk; exact hk.2)
      i hi with h | h
  · exact Or.inl h
  · exact Or.inr h

/-- ...and in the protocol: the step's new Drive files are the pre-passes' or live. -/
theorem step_flushFiles_live (s : St) (d : Bool) (lib : Lib) (rv : List Nat)
    (h : (s.dev d).pend = .fMerged lib rv) :
    ∀ i ∈ (step s (.flushFiles d)).files,
      i ∈ (flushPrePass (s.dev d) s.files).2 ∨ (tombed lib i.key = false ∧ renamedAway lib i.key = false) := by
  have e : (step s (.flushFiles d)).files = (flushFilesDev (s.dev d) s.files lib).2 := by
    simp only [step, h]
  rw [e]; exact flush_uploads_only_live _ _ _

/-- **A pull queues the deletion of every Drive file of a game the library it
adopts has deleted**, however it got there (a device that had not pulled the
delete, or a build without `flush_uploads_only_live`). -/
theorem pull_queues_orphans (dv : Dev) (lib : Lib) (remote : List Item) :
    ∀ i ∈ remote, tombed (mergeLibrary lib (localLib dv)) i.key = true →
      i.key ∈ (pullCommitDev dv lib remote).qDel := by
  intro i hi ht
  simp only [pullCommitDev]
  have : i.key ∈ (remote.filter (fun i => tombed (mergeLibrary lib (localLib dv)) i.key)).map Item.key :=
    List.mem_map.2 ⟨i, List.mem_filter.2 ⟨hi, ht⟩, rfl⟩
  generalize (remote.filter (fun i => tombed (mergeLibrary lib (localLib dv)) i.key)).map Item.key = os at this
  have hos := this
  have addUniq_mem : ∀ (l : List Key) (x y : Key), y ∈ l → y ∈ addUniq l x := by
    intro l x y hy; unfold addUniq; split
    · exact hy
    · exact List.mem_append_left _ hy
  have addUniq_self : ∀ (l : List Key) (x : Key), x ∈ addUniq l x := by
    intro l x; unfold addUniq; split
    · assumption
    · simp
  have : ∀ (os : List Key) (acc : List Key), i.key ∈ os ∨ i.key ∈ acc → i.key ∈ os.foldl addUniq acc := by
    intro os
    induction os with
    | nil => intro acc h; simpa using h
    | cons o os ih =>
      intro acc h
      apply ih
      rcases h with h | h
      · simp only [List.mem_cons] at h
        rcases h with rfl | h
        · exact Or.inr (addUniq_self _ _)
        · exact Or.inl h
      · exact Or.inr (addUniq_mem _ _ _ h)
  exact this os dv.qDel (Or.inl hos)

/-- Device 0 imports 7 and saves, syncs; device 1 pulls and downloads it;
device 0 then deletes 7 and flushes. Device 1 has not pulled since. -/
def setupT : List Ev := [.importRom false 7 70, .play false 7 71] ++ flush false ++ pull true ++
  [.download true 7, .delete false 7] ++ flush false

/-- **Fixed: a Sync tap on a device that missed a delete puts nothing back**
(the UI run's d2: its flush uploaded 7's ROM and save again, for good). The
tap queues every local file; the flush's merge knows 7 is deleted and leaves
them off Drive; the pull takes the delete here. -/
theorem regress_sync_tap_after_remote_delete :
    let s0 := run init setupT
    let s := run s0 ([.syncTap true] ++ flush true ++ pull true)
    s0.files = [] ∧ s.files = [] ∧ names s.d1.recent = [] ∧ s.d1.store = [] ∧
    s.lib.tomb.map (·.name) = [7] := by
  decide

/-- Files of a deleted game that are on Drive anyway (an old build put them
there): the next pull queues them and its flush deletes them. -/
theorem regress_orphans_removed :
    let s := run { init with files := [⟨7, 0, 70⟩, ⟨7, 1, 71⟩], lib := ⟨[], [⟨7, 1⟩], []⟩, now := 2 }
      (pull true ++ flush true)
    s.files = [] ∧ s.lib.tomb = [⟨7, 1⟩] := by
  decide

/-- Device 0 renames 1 to 2 after device 1 downloaded it. -/
def setupR : List Ev := [.importRom false 1 10, .play false 1 11] ++ flush false ++ pull true ++
  [.download true 1, .rename false 1 2] ++ flush false

/-- **Fixed: a Sync tap on a device that missed a rename uploads nothing under
the old name** (the UI run's d1); the pull then moves its files and nothing
is left to send. -/
theorem regress_sync_tap_after_remote_rename :
    let s1 := run init (setupR ++ [.syncTap true] ++ flush true)
    let s2 := run s1 (pull true ++ flush true)
    s1.files.map (·.game) = [2, 2] ∧ s2.files.map (·.game) = [2, 2] ∧
    s2.d1.store.map (·.game) = [2, 2] ∧ names s2.d1.recent = [2] ∧ s2.d1.qUp = [] := by
  decide


/-! ## Layer 3: generations (a game deleted and loaded again)

The UI pass left one question open (FINDINGS.md, "a deleted game loaded again
can get its deleted save back"): device 0 deletes a game and loads it again
from its file; device 1, which has not pulled the delete, syncs its save; and
device 0's next pull puts that save into the game it has just loaded again.
`mergeLibrary` drops a tombstone once a newer entry exists, and cannot tell a
fresh load from a play elsewhere; the pull's download pass (not in Layer 2)
then applies any newer save of a game held here. Matt's decision: respect the
delete, and keep the save from before it restorable for 30 days.

The fix (web/index.js, the block above `mergeLibrary` that starts with
`genOf`): every entry and tombstone has a generation (absent is 0); loading a
game again after its delete starts the next one (`bumpRecentIndex`); a
tombstone stands beside an entry of a newer generation (`mergeLibrary`); a
Drive file carries the generation it was written for (`appProperties.gen`,
`driveUploadFile`); a device never uploads a game's files while it holds the
game at an older generation than the library's (`flushSyncInner`); the pull
keeps aside, instead of applying, a save written for an older generation
(`pullSyncInner`, `keepOldSave`), and a device holding the older generation
gives way, keeping its save aside too (`convertStaleGame`); Restore swaps the
kept save with the game's (`restoreKeptSave`).

* Layer 3a, the merge name by name (the JS keeps one `Map` slot per name, so
  a name's result depends only on the records of that name): at generation 0
  it is Layer 1's merge (`mergeName_gen0`), so every property proved above
  holds of every library in which no deleted game was loaded again; and a
  tombstone stands beside a newer generation (`mergeName_tomb_beside_newer`).
* Layer 3b, a protocol small enough to run the finding: two devices, every
  flush and every pull one atomic event (Layer 2 has the interleavings), the
  download pass included, under the rules before (`gens := false`) and after
  (`gens := true`). `bug_reimport_gets_deleted_save` is the finding;
  `regress_reimport_keeps_deleted_save_aside` the same trace fixed, the save
  kept aside, reaching the deleting device and restorable there. In general
  (`pullG_applies_current_gen`, `flushG_uploads_current_gen`) a pull writes
  into a game's save only a Drive file written for the library's generation
  of it, and a flush sends a save only at the generation this device holds,
  never one the library has moved past.

Abstractions beyond Layer 2's: no rename markers (Layers 1-2 cover them; a
rename carries its generation to the new name, `mergeLibrary` 2769); the
library's lists up to order; a kept save is the kind-2 file of its game
(`oldsave:`), synced like any other, its newer-wins rule (`storeKeptRecord`)
and the 30-day expiry (`expireKeptSaves`) not modelled (each trace keeps one
save, within the 30 days); no game is open while a pull runs (the pinned
generation of a running game is web/tests/deleted-save.test.mjs's). -/

/-- A `recents` entry with its generation (`gen` absent is 0). -/
structure EntryG where
  name : Nat
  ts : Nat
  imp : Nat
  gen : Nat
deriving DecidableEq, Repr

/-- A tombstone with the generation it deleted. -/
structure TombG where
  name : Nat
  ts : Nat
  gen : Nat
deriving DecidableEq, Repr

/-! ### Layer 3a: the merge with generations, name by name -/

/-- The recents loop, one name: a newer generation wins the entry outright,
within one the newest play; the newest `imp` from either is kept. -/
def recStepG (acc : Option EntryG) (e : EntryG) : Option EntryG :=
  match acc with
  | none => some e
  | some p =>
    let w := if e.gen > p.gen || (e.gen == p.gen && e.ts > p.ts) then e else p
    some { w with imp := max p.imp e.imp }

/-- The tombstone loop, one name: a newer generation, then the newest. -/
def tombStepG (acc : Option TombG) (t : TombG) : Option TombG :=
  match acc with
  | none => some t
  | some p => if t.gen > p.gen || (t.gen == p.gen && t.ts > p.ts) then some t else acc

/-- The prune loop, one name: an entry of a newer generation stands beside the
tombstone; within one, a newer play supersedes it; otherwise the tombstone
removes the entry. -/
def pruneG : Option EntryG → Option TombG → Option EntryG × Option TombG
  | some e, some t =>
    if e.gen > t.gen then (some e, some t)
    else if e.gen == t.gen && e.ts > t.ts then (some e, none)
    else (none, some t)
  | e, t => (e, t)

/-- `mergeLibrary` (markers aside) for the records of one name. -/
def mergeName (es : List EntryG) (ts : List TombG) : Option EntryG × Option TombG :=
  pruneG (es.foldl recStepG none) (ts.foldl tombStepG none)

def EntryG.old (e : EntryG) : Entry := ⟨e.name, e.ts, e.imp⟩
def TombG.old (t : TombG) : Tomb := ⟨t.name, t.ts⟩

def projEG (x : Option EntryG) : Option (Nat × Nat) := x.map (fun e => (e.ts, e.imp))
def projTG (x : Option TombG) : Option Nat := x.map (·.ts)

theorem foldl_recStepG_gen0 (n : Nat) : ∀ (es : List EntryG) (acc : Option EntryG),
    (∀ e ∈ es, e.gen = 0 ∧ e.name = n) → (∀ p, acc = some p → p.gen = 0) →
    projEG (es.foldl recStepG acc) = (es.map EntryG.old).foldl (semStep n) (projEG acc) ∧
    (∀ p, es.foldl recStepG acc = some p → p.gen = 0) := by
  intro es
  induction es with
  | nil => intro acc _ h; exact ⟨rfl, h⟩
  | cons e es ih =>
    intro acc hes hacc
    have he := hes e (List.mem_cons_self ..)
    have hes' : ∀ x ∈ es, x.gen = 0 ∧ x.name = n := fun x hx => hes x (List.mem_cons_of_mem _ hx)
    have hstep : projEG (recStepG acc e) = semStep n (projEG acc) e.old ∧
        (∀ p, recStepG acc e = some p → p.gen = 0) := by
      cases acc with
      | none =>
        refine ⟨?_, ?_⟩
        · simp [recStepG, projEG, semStep, EntryG.old, he.2]
        · intro p hp; simp [recStepG] at hp; subst hp; exact he.1
      | some p =>
        have hp := hacc p rfl
        refine ⟨?_, ?_⟩
        · by_cases hlt : e.ts > p.ts
          · simp [recStepG, projEG, semStep, EntryG.old, he.2, he.1, hp, hlt, joinO,
                  Nat.max_def]
            omega
          · simp [recStepG, projEG, semStep, EntryG.old, he.2, he.1, hp, hlt, joinO,
                  Nat.max_def]
            omega
        · intro q hq
          by_cases hlt : e.ts > p.ts
          · simp [recStepG, he.1, hp, hlt] at hq; subst hq; rfl
          · simp [recStepG, he.1, hp, hlt] at hq; subst hq; rfl
    simp only [List.foldl, List.map]
    have := ih (recStepG acc e) hes' hstep.2
    rw [this.1, hstep.1]
    exact ⟨rfl, this.2⟩

theorem foldl_tombStepG_gen0 (n : Nat) : ∀ (ts : List TombG) (acc : Option TombG),
    (∀ t ∈ ts, t.gen = 0 ∧ t.name = n) → (∀ p, acc = some p → p.gen = 0) →
    projTG (ts.foldl tombStepG acc) = (ts.map TombG.old).foldl (semTStep n) (projTG acc) ∧
    (∀ p, ts.foldl tombStepG acc = some p → p.gen = 0) := by
  intro ts
  induction ts with
  | nil => intro acc _ h; exact ⟨rfl, h⟩
  | cons t ts ih =>
    intro acc hts hacc
    have ht := hts t (List.mem_cons_self ..)
    have hts' : ∀ x ∈ ts, x.gen = 0 ∧ x.name = n := fun x hx => hts x (List.mem_cons_of_mem _ hx)
    have hstep : projTG (tombStepG acc t) = semTStep n (projTG acc) t.old ∧
        (∀ p, tombStepG acc t = some p → p.gen = 0) := by
      cases acc with
      | none =>
        refine ⟨?_, ?_⟩
        · simp [tombStepG, projTG, semTStep, TombG.old, ht.2]
        · intro p hp; simp [tombStepG] at hp; subst hp; exact ht.1
      | some p =>
        have hp := hacc p rfl
        refine ⟨?_, ?_⟩
        · by_cases hlt : t.ts > p.ts
          · simp [tombStepG, projTG, semTStep, TombG.old, ht.2, ht.1, hp, hlt, joinT,
                  Nat.max_def]
            omega
          · simp [tombStepG, projTG, semTStep, TombG.old, ht.2, ht.1, hp, hlt, joinT,
                  Nat.max_def]
            omega
        · intro q hq
          by_cases hlt : t.ts > p.ts
          · simp [tombStepG, ht.1, hp, hlt] at hq; subst hq; exact ht.1
          · simp [tombStepG, ht.1, hp, hlt] at hq; subst hq; exact hp
    simp only [List.foldl, List.map]
    have := ih (tombStepG acc t) hts' hstep.2
    rw [this.1, hstep.1]
    exact ⟨rfl, this.2⟩

/-- **At generation 0 the merge is Layer 1's**: for the records of one name,
none with a generation, the result is Layer 1's name-by-name meaning (join
both sides' newest play, newest import and newest tombstone, then prune;
`merge_sem_noren`). Libraries written before generations existed, and every
library in which no deleted game was loaded again, merge as they always did. -/
theorem mergeName_gen0 (n : Nat) (es : List EntryG) (ts : List TombG)
    (he : ∀ e ∈ es, e.gen = 0 ∧ e.name = n) (ht : ∀ t ∈ ts, t.gen = 0 ∧ t.name = n) :
    (projEG (mergeName es ts).1, projTG (mergeName es ts).2) =
      normP (semR (es.map EntryG.old) n) (semT (ts.map TombG.old) n) := by
  have hE := foldl_recStepG_gen0 n es none he (by intro p h; cases h)
  have hT := foldl_tombStepG_gen0 n ts none ht (by intro p h; cases h)
  have hE1 : projEG (es.foldl recStepG none) = (es.map EntryG.old).foldl (semStep n) none := hE.1
  have hT1 : projTG (ts.foldl tombStepG none) = (ts.map TombG.old).foldl (semTStep n) none := hT.1
  unfold mergeName semR semT
  rw [← hE1, ← hT1]
  have hE2 := hE.2
  have hT2 := hT.2
  generalize es.foldl recStepG none = x at hE2
  generalize ts.foldl tombStepG none = y at hT2
  rcases x with _ | e <;> rcases y with _ | t
  · rfl
  · rfl
  · rfl
  · have he0 := hE2 e rfl
    have ht0 := hT2 t rfl
    by_cases hlt : e.ts > t.ts <;> simp [pruneG, normP, projEG, projTG, he0, ht0, hlt]

/-- **A tombstone stands beside a newer generation**: whenever the winning
entry is of a newer generation than the winning tombstone, both survive the
merge. It is how a device holding the deleted game learns that it was. -/
theorem mergeName_tomb_beside_newer (es : List EntryG) (ts : List TombG) (e : EntryG) (t : TombG)
    (he : es.foldl recStepG none = some e) (ht : ts.foldl tombStepG none = some t)
    (hg : e.gen > t.gen) : mergeName es ts = (some e, some t) := by
  simp [mergeName, he, ht, pruneG, hg]

/-- **Nothing of a generation at or below a tombstone's outlives it**, unless
a later play of the very generation it deleted overruled it (as before). -/
theorem mergeName_entry_survives (es : List EntryG) (ts : List TombG) (e : EntryG) (t : TombG)
    (ht : ts.foldl tombStepG none = some t) (hr : (mergeName es ts).1 = some e) :
    e.gen > t.gen ∨ (e.gen = t.gen ∧ e.ts > t.ts) := by
  unfold mergeName at hr
  rw [ht] at hr
  generalize es.foldl recStepG none = x at hr
  rcases x with _ | x
  · simp [pruneG] at hr
  · simp only [pruneG] at hr
    split at hr
    · rename_i h1; simp at hr; subst hr; exact Or.inl h1
    · split at hr
      · rename_i h2; simp at hr; subst hr; simp at h2; exact Or.inr ⟨h2.1, h2.2⟩
      · simp at hr

/-- The cases web/tests/deleted-save.test.mjs's merge test runs. -/
theorem mergeName_cases :
    -- no generations: a newer play drops the tombstone, an older one is dropped
    mergeName [⟨1, 20, 0, 0⟩] [⟨1, 10, 0⟩] = (some ⟨1, 20, 0, 0⟩, none) ∧
    mergeName [⟨1, 5, 0, 0⟩] [⟨1, 10, 0⟩] = (none, some ⟨1, 10, 0⟩) ∧
    -- loaded again after the delete: both stand
    mergeName [⟨1, 20, 20, 1⟩] [⟨1, 10, 0⟩] = (some ⟨1, 20, 20, 1⟩, some ⟨1, 10, 0⟩) ∧
    -- a play of the deleted generation, however late, does not replace it
    mergeName [⟨1, 20, 20, 1⟩, ⟨1, 30, 0, 0⟩] [⟨1, 10, 0⟩] =
      (some ⟨1, 20, 20, 1⟩, some ⟨1, 10, 0⟩) ∧
    -- a delete of generation 1 supersedes generation 0's and removes either
    mergeName [⟨1, 20, 20, 1⟩] [⟨1, 10, 0⟩, ⟨1, 25, 1⟩] = (none, some ⟨1, 25, 1⟩) ∧
    mergeName [⟨1, 40, 0, 0⟩] [⟨1, 25, 1⟩] = (none, some ⟨1, 25, 1⟩) := by
  decide

/-! ### Layer 3b: two devices, one Drive, the download pass -/

/-- The Drive-side library, markers aside, up to order. -/
structure LibG where
  recents : List EntryG
  tomb : List TombG
deriving DecidableEq, Repr

/-- A per-game record or Drive file: kind 0 `rom:`, 1 `save:`, 2 `oldsave:`
(the kept save). `gen` is the Drive file's `appProperties.gen`; a local record
has none (0): what a device holds is of the generation its entry says. -/
structure FileG where
  game : Nat
  kind : Nat
  blob : Nat
  gen : Nat
deriving DecidableEq, Repr

def FileG.key (f : FileG) : Nat × Nat := (f.game, f.kind)

def putF (l : List FileG) (f : FileG) : List FileG := l.filter (fun j => j.key != f.key) ++ [f]
def findF (l : List FileG) (k : Nat × Nat) : Option FileG := l.find? (fun j => j.key == k)

/-- `mergeLibrary`, name by name. -/
def mergeG (a b : LibG) : LibG :=
  let es := a.recents ++ b.recents
  let ts := a.tomb ++ b.tomb
  let ns := dedup (es.map (·.name) ++ ts.map (·.name))
  let res := ns.map (fun n => mergeName (es.filter (·.name == n)) (ts.filter (·.name == n)))
  ⟨res.filterMap (·.1), res.filterMap (·.2)⟩

/-- `genOf` of a game's entry in a list (0 when absent). -/
def genIn (l : List EntryG) (g : Nat) : Nat := ((l.find? (·.name == g)).map (·.gen)).getD 0

/-- `deletedIn`: tombstoned, with no entry beside it. -/
def deadIn (L : LibG) (g : Nat) : Bool := L.tomb.any (·.name == g) && !L.recents.any (·.name == g)

structure DevG where
  /-- IndexedDB "recent" -/
  recent : List EntryG
  /-- syncState.tomb -/
  tomb : List TombG
  /-- the per-game records -/
  store : List FileG
  /-- syncState.queueUp -/
  qUp : List (Nat × Nat)
  /-- syncState.queueDel -/
  qDel : List (Nat × Nat)
deriving DecidableEq, Repr

def DevG.empty : DevG := ⟨[], [], [], [], []⟩

structure StG where
  d0 : DevG
  d1 : DevG
  lib : LibG
  files : List FileG
  now : Nat
deriving DecidableEq, Repr

def StG.init : StG := ⟨DevG.empty, DevG.empty, ⟨[], []⟩, [], 1⟩

def StG.dev (s : StG) : Bool → DevG
  | false => s.d0
  | true => s.d1

def StG.setDev (s : StG) : Bool → DevG → StG
  | false, v => { s with d0 := v }
  | true, v => { s with d1 := v }

def localLibG (dv : DevG) : LibG := ⟨dv.recent, dv.tomb⟩

/-- `bumpRecentIndex`: the entry to the front, its generation carried (or
raised to `atLeast`); with `gens`, a fresh import after this device deleted
the game starts the generation after the one deleted. -/
def bumpG (gens : Bool) (dv : DevG) (g now : Nat) (fresh : Bool) (atLeast : Nat) : List EntryG :=
  let prev := dv.recent.find? (·.name == g)
  let g0 := if gens then max ((prev.map (·.gen)).getD 0) atLeast else 0
  let gen := if gens && fresh then
      match dv.tomb.find? (·.name == g) with
      | some t => max g0 (t.gen + 1)
      | none => g0
    else g0
  let imp := if fresh then now else (prev.map (·.imp)).getD 0
  ⟨g, now, imp, gen⟩ :: dv.recent.filter (·.name != g)

def keysOfG (g : Nat) : List (Nat × Nat) := [(g, 0), (g, 1), (g, 2)]

/-- `addRecentRom` (+ `markGameUpload`, which queues every record of it). -/
def importG (gens : Bool) (dv : DevG) (g blob now : Nat) : DevG :=
  let st := putF dv.store ⟨g, 0, blob, 0⟩
  { dv with store := st, recent := bumpG gens dv g now true 0,
            qUp := ((st.filter (·.game == g)).map FileG.key).foldl addUniq dv.qUp }

/-- A launch and a battery save. -/
def playG (gens : Bool) (dv : DevG) (g blob now : Nat) : DevG :=
  { dv with recent := bumpG gens dv g now false 0, store := putF dv.store ⟨g, 1, blob, 0⟩,
            qUp := addUniq dv.qUp (g, 1) }

/-- `deleteGameEverywhere`: the tombstone records the generation deleted. -/
def deleteG (dv : DevG) (g now : Nat) : DevG :=
  { dv with store := dv.store.filter (·.game != g),
            recent := dv.recent.filter (·.name != g),
            qDel := (keysOfG g).foldl addUniq dv.qDel,
            qUp := dv.qUp.filter (·.1 != g),
            tomb := dv.tomb.filter (·.name != g) ++ [⟨g, now, genIn dv.recent g⟩] }

/-- One queued upload (`flushSyncInner`'s upload pass), against the merged
library `L`. With `gens`: a game held here at an older generation than the
library's sends nothing (its save is the deleted game's); a file goes up
stamped with the generation held here, and one on Drive stamped older is
replaced whatever its bytes. A ROM present on Drive is never re-sent; a
kept save (kind 2) is no generation's. -/
def upG (gens : Bool) (dv : DevG) (L : LibG) (files : List FileG) (k : Nat × Nat) : List FileG :=
  if deadIn L k.1 then files
  else if gens && k.2 == 1 && genIn L.recents k.1 > genIn dv.recent k.1 then files
  else match findF dv.store k with
    | none => files
    | some it =>
      let here := if gens then genIn dv.recent k.1 else 0
      match findF files k with
      | none => putF files { it with gen := here }
      | some r =>
        if (gens && r.gen < here) || (k.2 != 0 && r.blob != it.blob)
        then putF files { it with gen := here } else files

/-- `flushSyncInner` as one event: merge; cancel the queued deletes of games
a newer play revived; delete; upload; write the library; adopt its
tombstones (and put revived games back on the grid). -/
def flushG (gens : Bool) (dv : DevG) (lib : LibG) (files : List FileG) : DevG × LibG × List FileG :=
  let L := mergeG lib (localLibG dv)
  let revived := (dv.tomb.filter (fun t => !L.tomb.any (·.name == t.name))).map (·.name)
  let qDel := dv.qDel.filter (fun k => !revived.contains k.1)
  let f1 := files.filter (fun f => !qDel.contains f.key)
  let f2 := dv.qUp.foldl (upG gens dv L) f1
  let add := L.recents.filter (fun r => revived.contains r.name && !dv.recent.any (·.name == r.name))
  ({ dv with qDel := [], qUp := [], tomb := L.tomb, recent := dv.recent ++ add }, L, f2)

/-- `convertStaleGame`: the device holds `g` at an older generation than the
library's; its save is kept aside (kind 2) and queued up, the rest goes. -/
def convertG (dv : DevG) (g : Nat) : DevG :=
  let kept := match findF dv.store (g, 1) with
    | some s => [⟨g, 2, s.blob, 0⟩]
    | none => (dv.store.filter (fun f => f.key == (g, 2)))
  { dv with store := dv.store.filter (·.game != g) ++ kept,
            qUp := (dv.qUp.filter (·.1 != g)) ++ kept.map FileG.key }

/-- One Drive file in the download pass. A save or a kept save of a game this
device holds; with `gens`, a save written for an older generation than the
library's is kept aside (kind 2, queued up) and never applied, and Drive's
copy is queued to be replaced by this device's or taken down. -/
def downG (gens : Bool) (L : LibG) (dv : DevG) (f : FileG) : DevG :=
  if f.kind == 0 then dv
  -- a game held here; or a kept save held here, which follows Drive's
  else if findF dv.store (f.game, 0) == none &&
          !(f.kind == 2 && (findF dv.store f.key).isSome) then dv
  else if dv.qDel.contains f.key then dv
  else if gens && f.kind == 1 && f.gen < genIn L.recents f.game then
    let fix := if (findF dv.store f.key).isSome
      then { dv with qUp := addUniq dv.qUp f.key } else { dv with qDel := addUniq dv.qDel f.key }
    { fix with store := putF fix.store ⟨f.game, 2, f.blob, 0⟩, qUp := addUniq fix.qUp (f.game, 2) }
  else { dv with store := putF dv.store { f with gen := 0 } }

/-- `pullSyncInner` as one event: merge; the tombstone pass ("Continue");
with `gens`, the stale-generation pass; the download pass; reconcile
upward; queue the deleted games' Drive files for deletion; adopt the merge. -/
def pullG (gens : Bool) (dv : DevG) (lib : LibG) (files : List FileG) : DevG × LibG :=
  let L := mergeG lib (localLibG dv)
  let d1 := { dv with store := dv.store.filter (fun i => !deadIn L i.game) }
  let stale := if gens then (L.recents.filter (fun e => e.gen > genIn dv.recent e.name &&
                  d1.store.any (fun i => i.game == e.name && i.kind != 2))).map (·.name) else []
  let d2 := stale.foldl convertG d1
  let d3 := files.foldl (downG gens L) d2
  let missing := (d3.store.filter (fun i => !files.any (·.key == i.key) && !deadIn L i.game)).map FileG.key
  let orphans := (files.filter (fun f => deadIn L f.game)).map FileG.key
  ({ d3 with qUp := (missing.foldl addUniq d3.qUp).filter (fun k => !orphans.contains k),
             qDel := orphans.foldl addUniq d3.qDel, tomb := L.tomb, recent := L.recents }, L)

/-- `downloadGame`: every file of the game, at the newest generation any of
them was written for; with `gens`, a save of an older one is kept aside. -/
def downloadG (gens : Bool) (dv : DevG) (files : List FileG) (g now : Nat) : DevG :=
  let fs := files.filter (·.game == g)
  if fs.isEmpty then dv else
  let top := fs.foldl (fun m f => max m f.gen) (genIn dv.recent g)
  let st := fs.foldl (fun st f =>
    if gens && f.kind == 1 && f.gen < top then putF st ⟨g, 2, f.blob, 0⟩
    else putF st { f with gen := 0 }) dv.store
  { dv with store := st, recent := bumpG gens dv g now false (if gens then top else 0) }

/-- `restoreKeptSave`: the kept save and the game's save change places. With
no save to put aside, the kept record becomes one that offers nothing (blob
0, the JS `data: null`), which replaces the older copies other devices hold. -/
def restoreG (dv : DevG) (g : Nat) : DevG :=
  match findF dv.store (g, 2) with
  | none => dv
  | some k =>
    if k.blob == 0 then dv else
    let cur := ((findF dv.store (g, 1)).map (·.blob)).getD 0
    let st := putF (putF dv.store ⟨g, 1, k.blob, 0⟩) ⟨g, 2, cur, 0⟩
    { dv with store := st, qUp := addUniq (addUniq dv.qUp (g, 1)) (g, 2) }

inductive EvG where
  | importRom (d : Bool) (g blob : Nat)
  | play (d : Bool) (g blob : Nat)
  | delete (d : Bool) (g : Nat)
  | flush (d : Bool)
  | pull (d : Bool)
  | download (d : Bool) (g : Nat)
  | restore (d : Bool) (g : Nat)
deriving DecidableEq, Repr

def stepG (gens : Bool) (s : StG) : EvG → StG
  | .importRom d g blob => { s.setDev d (importG gens (s.dev d) g blob s.now) with now := s.now + 1 }
  | .play d g blob =>
    if (findF (s.dev d).store (g, 0)).isSome
    then { s.setDev d (playG gens (s.dev d) g blob s.now) with now := s.now + 1 } else s
  | .delete d g => { s.setDev d (deleteG (s.dev d) g s.now) with now := s.now + 1 }
  | .flush d =>
    let r := flushG gens (s.dev d) s.lib s.files
    { s.setDev d r.1 with lib := r.2.1, files := r.2.2 }
  | .pull d =>
    let r := pullG gens (s.dev d) s.lib s.files
    { s.setDev d r.1 with lib := r.2 }
  | .download d g => { s.setDev d (downloadG gens (s.dev d) s.files g s.now) with now := s.now + 1 }
  | .restore d g => s.setDev d (restoreG (s.dev d) g)

def runG (gens : Bool) (s : StG) (es : List EvG) : StG := es.foldl (stepG gens) s

/-- Device 0 imports game 1 and saves (11), syncs; device 1 pulls,
downloads it and plays on (12, not yet sent); device 0 deletes the game,
syncs, loads it again from its file (10) and syncs; device 1, not having
pulled, syncs; device 0 pulls. -/
def reimportTrace : List EvG :=
  [.importRom false 1 10, .play false 1 11, .flush false, .pull true, .download true 1,
   .play true 1 12, .delete false 1, .flush false, .importRom false 1 10, .flush false,
   .flush true, .pull false]

def saves (dv : DevG) (k : Nat) : List Nat := (dv.store.filter (·.kind == k)).map (·.blob)

/-- **The finding** (the UI pass; FINDINGS.md "a design question"): with the
rules before generations, device 0's game, loaded again after its delete,
gets the deleted game's save back from device 1. -/
theorem bug_reimport_gets_deleted_save :
    let s := runG false StG.init reimportTrace
    saves s.d0 1 = [12] ∧ s.lib.tomb = [] := by
  decide

/-- **Fixed.** The same trace starts the game loaded again without a save;
device 1's sync sent nothing, and Drive holds no save. Once device 1 pulls
(its copy gives way, its save kept aside) and syncs, device 0 pulls the kept
save, not applied, and Restore makes it the game's save, on Drive at the new
generation; the kept record then offers nothing, on either device. The
tombstone of the deleted generation stands beside the new one throughout. -/
theorem regress_reimport_keeps_deleted_save_aside :
    let s := runG true StG.init reimportTrace
    let s2 := runG true s [.pull true, .flush true, .pull false]
    let s3 := runG true s2 [.restore false 1, .flush false, .pull true, .pull false]
    saves s.d0 1 = [] ∧ (s.files.filter (·.kind == 1)) = [] ∧
    s.lib.tomb = [⟨1, 5, 0⟩] ∧ s.lib.recents.map (·.gen) = [1] ∧
    saves s2.d1 1 = [] ∧ saves s2.d1 2 = [12] ∧ saves s2.d1 0 = [] ∧
    saves s2.d0 1 = [] ∧ saves s2.d0 2 = [12] ∧
    saves s3.d0 1 = [12] ∧ saves s3.d0 2 = [0] ∧ saves s3.d1 2 = [0] ∧
    (s3.files.filter (·.kind == 1)).map (fun f => (f.blob, f.gen)) = [(12, 1)] ∧
    s3.lib.tomb = [⟨1, 5, 0⟩] := by
  decide

/-- Deleted and loaded again on one device before a sync: the old save still
leaves Drive (the flush used to read the newer entry as "the delete was not
meant" and cancel the queued deletes), and a device downloading the game
later gets no save. -/
theorem regress_reimport_before_sync :
    let es := [EvG.importRom false 1 10, .play false 1 11, .flush false,
               .delete false 1, .importRom false 1 10, .flush false,
               .pull true, .download true 1]
    let old := runG false StG.init es
    let s := runG true StG.init es
    saves old.d1 1 = [11] ∧
    s.files.map FileG.key = [(1, 0)] ∧ saves s.d1 1 = [] := by
  decide

/-! What the pull may write into a game's save, and what the flush may send. -/

theorem mem_putF {l : List FileG} {f i : FileG} (h : i ∈ putF l f) : i ∈ l ∨ i = f := by
  unfold putF at h
  rcases List.mem_append.1 h with h | h
  · exact Or.inl (List.mem_filter.1 h).1
  · exact Or.inr (List.mem_singleton.1 h)

theorem mem_filter_append_kept {l : List FileG} {p : FileG → Bool} {k : List FileG}
    (hk : ∀ x ∈ k, x.kind = 2) {i : FileG} (h : i ∈ l.filter p ++ k) (h1 : i.kind = 1) : i ∈ l := by
  rcases List.mem_append.1 h with h | h
  · exact (List.mem_filter.1 h).1
  · have := hk i h; omega

/-- A save of the conversion's output was in its input. -/
theorem convertG_save (dv : DevG) (g : Nat) (i : FileG) (hi : i ∈ (convertG dv g).store)
    (h1 : i.kind = 1) : i ∈ dv.store := by
  unfold convertG at hi
  simp only at hi
  apply mem_filter_append_kept _ hi h1
  intro x hx
  split at hx
  · simp at hx; subst hx; rfl
  · have := (List.mem_filter.1 hx).2
    simp [FileG.key] at this
    exact this.2

theorem foldl_convertG_save (L : List Nat) : ∀ (dv : DevG) (i : FileG),
    i ∈ (L.foldl convertG dv).store → i.kind = 1 → i ∈ dv.store := by
  induction L with
  | nil => intro dv i h _; exact h
  | cons g gs ih => intro dv i h h1; exact convertG_save dv g i (ih _ i h h1) h1

/-- The download pass writes a save only from a Drive file of this pass,
and, with generations, only one written for the library's generation of it. -/
theorem downG_save (L : LibG) (dv : DevG) (f : FileG) (i : FileG)
    (hi : i ∈ (downG true L dv f).store) (h1 : i.kind = 1) :
    i ∈ dv.store ∨ (i = { f with gen := 0 } ∧ f.gen ≥ genIn L.recents f.game) := by
  unfold downG at hi
  split at hi
  · exact Or.inl hi
  split at hi
  · exact Or.inl hi
  split at hi
  · exact Or.inl hi
  split at hi
  · simp only at hi
    rcases mem_putF hi with h | h
    · left; split at h <;> simpa using h
    · subst h; simp at h1
  · rename_i hold
    rcases mem_putF hi with h | h
    · exact Or.inl h
    · refine Or.inr ⟨h, ?_⟩
      subst h
      have hk : f.kind = 1 := by simpa using h1
      simp [hk] at hold
      omega

theorem foldl_downG_save (L : LibG) (files : List FileG) : ∀ (dv : DevG) (i : FileG),
    i ∈ (files.foldl (downG true L) dv).store → i.kind = 1 →
    i ∈ dv.store ∨ ∃ f ∈ files, i = { f with gen := 0 } ∧ f.gen ≥ genIn L.recents f.game := by
  induction files with
  | nil => intro dv i h _; exact Or.inl h
  | cons f fs ih =>
    intro dv i h h1
    rcases ih _ i h h1 with h | ⟨f', hf', he⟩
    · rcases downG_save L dv f i h h1 with h | h
      · exact Or.inl h
      · exact Or.inr ⟨f, List.mem_cons_self .., h⟩
    · exact Or.inr ⟨f', List.mem_cons_of_mem _ hf', he⟩

/-- **A pull writes into a game's save only a Drive file written for the
library's generation of that game** (the library it merges). Every save
after the pull was already here, or is such a file: a save written for an
older generation, the deleted game's, is never applied. -/
theorem pullG_applies_current_gen (dv : DevG) (lib : LibG) (files : List FileG) (i : FileG)
    (hi : i ∈ (pullG true dv lib files).1.store) (h1 : i.kind = 1) :
    i ∈ dv.store ∨ ∃ f ∈ files, i = { f with gen := 0 } ∧
      f.gen ≥ genIn (mergeG lib (localLibG dv)).recents f.game := by
  simp only [pullG] at hi
  rcases foldl_downG_save _ files _ i hi h1 with h | h
  · exact Or.inl (List.mem_filter.1 (foldl_convertG_save _ _ i h h1)).1
  · exact Or.inr h

theorem upG_save (dv : DevG) (L : LibG) (files : List FileG) (k : Nat × Nat) (i : FileG)
    (hi : i ∈ upG true dv L files k) :
    i ∈ files ∨ (i.gen = genIn dv.recent i.game ∧
      (i.kind = 1 → genIn L.recents i.game ≤ genIn dv.recent i.game)) := by
  unfold upG at hi
  split at hi
  · exact Or.inl hi
  split at hi
  · exact Or.inl hi
  rename_i hnot
  cases hit : findF dv.store k with
  | none => rw [hit] at hi; exact Or.inl hi
  | some it =>
  rw [hit] at hi
  have hkey : it.key = k := by
    have h' : dv.store.find? (fun j => j.key == k) = some it := hit
    simpa using List.find?_some h'
  have hg : it.game = k.1 := by rw [← hkey]; rfl
  have hkd : it.kind = k.2 := by rw [← hkey]; rfl
  have fresh : ∀ j, j = { it with gen := genIn dv.recent k.1 } →
      j.gen = genIn dv.recent j.game ∧
        (j.kind = 1 → genIn L.recents j.game ≤ genIn dv.recent j.game) := by
    intro j hj
    subst hj
    refine ⟨by simp [hg], fun hk1 => ?_⟩
    have : k.2 = 1 := by rw [← hkd]; exact hk1
    simp [this] at hnot
    simpa [hg] using hnot
  simp only [↓reduceIte] at hi
  cases hr : findF files k with
  | none =>
    rw [hr] at hi; dsimp only at hi
    rcases mem_putF hi with h | h
    · exact Or.inl h
    · exact Or.inr (fresh i h)
  | some r =>
    rw [hr] at hi; dsimp only at hi
    split at hi
    · rcases mem_putF hi with h | h
      · exact Or.inl h
      · exact Or.inr (fresh i h)
    · exact Or.inl hi

theorem foldl_upG_save (dv : DevG) (L : LibG) : ∀ (ks : List (Nat × Nat)) (files : List FileG) (i : FileG),
    i ∈ ks.foldl (upG true dv L) files →
    i ∈ files ∨ (i.gen = genIn dv.recent i.game ∧
      (i.kind = 1 → genIn L.recents i.game ≤ genIn dv.recent i.game)) := by
  intro ks
  induction ks with
  | nil => intro files i h; exact Or.inl h
  | cons k ks ih =>
    intro files i h
    rcases ih _ i h with h | h
    · exact upG_save dv L files k i h
    · exact Or.inr h

/-- **A flush sends a save only at the generation this device holds its game,
and only when the library has not moved past it**: every file on Drive after
the flush was there before, or is stamped with this device's generation of
its game, which for a save is no older than the merged library's. A device
that missed a delete and a reload elsewhere sends nothing of the deleted
game. -/
theorem flushG_uploads_current_gen (dv : DevG) (lib : LibG) (files : List FileG) (i : FileG)
    (hi : i ∈ (flushG true dv lib files).2.2) :
    i ∈ files ∨ (i.gen = genIn dv.recent i.game ∧
      (i.kind = 1 → genIn (mergeG lib (localLibG dv)).recents i.game ≤ genIn dv.recent i.game)) := by
  simp only [flushG] at hi
  rcases foldl_upG_save dv _ _ _ i hi with h | h
  · exact Or.inl (List.mem_filter.1 h).1
  · exact Or.inr h
end WebState.DriveLibrary
