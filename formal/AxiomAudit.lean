import Lean
import WebState
open Lean Elab Command

/-! Fails the build if any theorem under `WebState` rests on anything but
Lean's three standard axioms: a stray `sorry` (`sorryAx`), a `native_decide`
(`Lean.ofReduceBool`) or a new `axiom` would all show up here. -/

def allowedAxioms : List Name := [``propext, ``Classical.choice, ``Quot.sound]

elab "#audit_webstate" : command => do
  let env ← getEnv
  let mut checked := 0
  let mut bad : Array (Name × Array Name) := #[]
  for (n, ci) in env.constants.toList do
    unless (`WebState).isPrefixOf n do continue
    unless ci matches .thmInfo _ do continue
    checked := checked + 1
    let axs ← liftCoreM (Lean.collectAxioms n)
    let extra := axs.filter (fun a => !allowedAxioms.contains a)
    unless extra.size == 0 do bad := bad.push (n, extra)
  if checked == 0 then throwError "axiom audit found no WebState theorems"
  unless bad.size == 0 do
    throwError m!"theorems resting on non-standard axioms: {bad.toList}"
  logInfo m!"axiom audit: {checked} WebState theorems, standard axioms only"

#audit_webstate
