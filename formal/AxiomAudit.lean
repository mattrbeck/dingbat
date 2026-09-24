import Lean
import WebState
import DesktopState
open Lean Elab Command

/-! Fails the build if any theorem under `WebState` or `DesktopState` rests on
anything but Lean's three standard axioms: a stray `sorry` (`sorryAx`), a
`native_decide` (`Lean.ofReduceBool`) or a new `axiom` would all show up here.
Each library must contribute theorems, so a root file that stops importing its
models fails too. -/

def allowedAxioms : List Name := [``propext, ``Classical.choice, ``Quot.sound]

def auditedLibs : List Name := [`WebState, `DesktopState]

elab "#audit_models" : command => do
  let env ← getEnv
  let mut bad : Array (Name × Array Name) := #[]
  let mut counts : Array (Name × Nat) := #[]
  for lib in auditedLibs do
    let mut checked := 0
    for (n, ci) in env.constants.toList do
      unless lib.isPrefixOf n do continue
      unless ci matches .thmInfo _ do continue
      checked := checked + 1
      let axs ← liftCoreM (Lean.collectAxioms n)
      let extra := axs.filter (fun a => !allowedAxioms.contains a)
      unless extra.size == 0 do bad := bad.push (n, extra)
    if checked == 0 then throwError m!"axiom audit found no {lib} theorems"
    counts := counts.push (lib, checked)
  unless bad.size == 0 do
    throwError m!"theorems resting on non-standard axioms: {bad.toList}"
  logInfo m!"axiom audit: {counts.toList} theorems, standard axioms only"

#audit_models
