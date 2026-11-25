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
  let toThirdPush := [
    "oe ready row 8: start an Owner", "Owner start 1 pushes", "CI on commit 1 fails",
    "oe ready row 8: start an Owner", "Owner start 2 writes a question",
    "the person answers that the code must change", "oe ready row 8: start an Owner",
    "Owner start 3 pushes"]
  match walk cfg (toThirdPush ++ ["start 1 ends, and oe end runs"]),
      walk cfg (toThirdPush ++ ["start 2 ends, and oe end runs"]) with
  | .ok (g1, _), .ok (g, path) =>
    expect "the ends of start 1 and start 2 reach the same state" (g1.states.back! == g.states.back!)
    let shown := labels cfg g path
    expect "labels names the end the path took when another end reaches the same state"
      (shown.getLast? == some "start 2 ends, and oe end runs") (showPath shown)
  | .error e, _ | _, .error e => throw (IO.userError e)
