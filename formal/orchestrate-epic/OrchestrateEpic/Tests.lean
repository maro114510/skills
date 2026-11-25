import OrchestrateEpic.Verify

/-!
# Tests of the checks themselves

Each `#eval` that throws fails the build.
-/

namespace OE.Tests

def expect (name : String) (ok : Bool) (detail : String := "") : IO Unit :=
  if ok then IO.println s!"test passes: {name}"
  else throw (IO.userError s!"test fails: {name}{if detail.isEmpty then "" else s!"\n{detail}"}")

/-- The path along `events` from the start of the Issue, each event picked by its label in `step`, and the
states it reaches. -/
def walk (cfg : Config) (events : List String) : Except String (Graph × Path) := do
  let mut states : Array St := #[normalize init]
  let mut path : Path := []
  for want in events do
    match (step cfg states[states.size - 1]!).find? (·.1.label == want) with
    | none => throw s!"no event {want}"
    | some (e, t) =>
      path := path ++ [(e, states.size)]
      states := states.push t
  return ({ states, edges := #[], parent := #[] }, path)

end OE.Tests

open OE OE.Tests

-- Three starts that can still write, so the ends of the two older starts, after both wrote, reach the
-- same state.
#eval show IO Unit from do
  let cfg : Config := { view := .codeFault, maxAgents := 3 }
  -- The Verifier, start 2, ends after its verdict, so the two older starts that wrote are Owners 1 and 3.
  -- Once commit 1 is dropped, the state numbers start 3 as 2.
  let toFourthPush := [
    "oe ready row 8: start an Owner", "Owner start 1 pushes", "CI on commit 1 succeeds",
    "oe ready row 11: start a Verifier", "Verifier start 2 writes a failure verdict",
    "start 2 ends, and oe end runs", "oe ready row 8: start an Owner", "Owner start 3 writes a question",
    "the person answers that the code must change", "oe ready row 8: start an Owner",
    "Owner start 4 pushes"]
  match walk cfg (toFourthPush ++ ["start 1 ends, and oe end runs"]),
      walk cfg (toFourthPush ++ ["start 2 ends, and oe end runs"]) with
  | .ok (g1, _), .ok (g, path) =>
    expect "the ends of start 1 and start 3 reach the same state" (g1.states.back! == g.states.back!)
    let shown := labels cfg g path
    expect "labels names the end the path took when another end reaches the same state"
      (shown.getLast? == some "start 3 ends, and oe end runs") (showPath shown)
  | .error e, _ | _, .error e => throw (IO.userError e)

namespace OE.Tests

/-- Whether `checkKnown` passes. A test turns on `rerunRerunsCi`, the fix of the known dead end, so that
only the property it tests can break. -/
def passesKnown (known : List Known) (view : View) (sw : Switches) : IO Bool := do
  try checkKnown known view false sw "test"; pure true
  catch _ => pure false

/-- The six events after which an expired Owner's late write counts for the next Owner. -/
def lateOwnerWrite (write : String) : List String := [
  "oe ready row 8: start an Owner, start 1",
  "6 hours pass since the marker's start",
  "oe ready row 7: hold the Issue",
  "the person answers that the code must change",
  "oe ready row 8: start an Owner, start 2",
  write]

def ownerFixUndone : Switches → Switches := ({ · with ownerResultFromAnyStart := false })

/-- The labels of the events that can happen after `events`. -/
def nextLabels (cfg : Config) (events : List String) : IO (List String) :=
  match walk cfg events with
  | .ok (g, _) => pure ((step cfg g.states.back!).map (·.1.label))
  | .error e => throw (IO.userError e)

/-- The events up to the push of the first commit after a repair starts, which is commit 2. -/
def toRepairPush : List String := [
  "oe ready row 8: start an Owner", "Owner start 1 pushes", "CI on commit 1 succeeds",
  "oe ready row 11: start a Verifier", "Verifier start 2 writes a failure verdict",
  "oe ready row 8: start an Owner", "Owner start 3 pushes"]

end OE.Tests

#eval show IO Unit from do
  let next ← nextLabels { view := .noFault } toRepairPush
  expect "CI can fail on the first commit after a repair starts for a person who sees no fault"
    (next.contains "CI on commit 2 fails") (toString next)

#eval show IO Unit from do
  let next ← nextLabels { view := .codeFault } ["oe ready row 8: start an Owner", "Owner start 1 pushes"]
  expect "CI cannot fail on the commit that opens the PR"
    (next.contains "CI on commit 1 succeeds" && !next.contains "CI on commit 1 fails") (toString next)

-- Two defects break "A result belongs to its start", and the known counterexample is only the shorter.
#eval show IO Unit from do
  let sw : Switches := { ownerResultFromAnyStart := true, verdictFromAnyStart := true, rerunRerunsCi := true }
  let known := [{ view := .noFault, skew := false, property := .resultBelongsToStart,
                  path := lateOwnerWrite "Owner start 1 pushes", fix := ownerFixUndone : Known }]
  expect "checkKnown fails when a known counterexample hides another violation of its property"
    !(← passesKnown known .noFault sw)

-- The late question is as short as the late push, which the search finds first.
#eval show IO Unit from do
  let sw : Switches := { ownerResultFromAnyStart := true, rerunRerunsCi := true }
  let known := [{ view := .noFault, skew := false, property := .resultBelongsToStart,
                  path := lateOwnerWrite "Owner start 1 writes a question", fix := ownerFixUndone : Known }]
  expect "checkKnown passes on a known counterexample as short as the one the search finds"
    (← passesKnown known .noFault sw)

-- The path stops before the late write, so it breaks nothing.
#eval show IO Unit from do
  let sw : Switches := { ownerResultFromAnyStart := true, rerunRerunsCi := true }
  let known := [{ view := .noFault, skew := false, property := .resultBelongsToStart,
                  path := (lateOwnerWrite "Owner start 1 pushes").dropLast ++ ["start 1 ends, and oe end runs"],
                  fix := ownerFixUndone : Known }]
  expect "checkKnown fails on a known path that does not break its property"
    !(← passesKnown known .noFault sw)
