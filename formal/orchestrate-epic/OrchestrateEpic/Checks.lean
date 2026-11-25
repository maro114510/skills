import OrchestrateEpic.Verify

/-!
# The checks `lake build` runs

Each `#eval` that throws fails the build.
-/

namespace OE

/-- Three failed checks hold the Issue, and a re-run request from a person who sees no fault leaves the
failed check and row 8's cap in place, so it holds again. A person rerunning failed CI is not modeled, as
`ciEvents` says. -/
def deadEndAfterThreeFailedChecks : List String := [
  "oe ready row 8: start an Owner, start 1",
  "Owner start 1 pushes",
  "CI on commit 1 succeeds",
  "oe ready row 11: start a Verifier, start 2",
  "Verifier start 2 writes a failure verdict",
  "oe ready row 8: start an Owner, start 3",
  "Owner start 3 pushes",
  "CI on commit 2 fails",
  "oe ready row 8: start an Owner, start 4",
  "Owner start 4 pushes",
  "CI on commit 3 fails",
  "oe ready row 8: start an Owner, start 5",
  "Owner start 5 pushes",
  "CI on commit 4 fails"]

def known : List Known := [false, true].map fun skew =>
  { view := .noFault, skew, property := .noDeadEnd, path := deadEndAfterThreeFailedChecks,
    fix := ({ · with rerunRerunsCi := true }) }

end OE

open OE

#eval checkHash

#eval checkKnown known .codeFault false {} "The Design Doc as written"
#eval checkKnown known .noFault false {} "The Design Doc as written"
#eval checkKnown known .codeFault true {} "The Design Doc as written"
#eval checkKnown known .noFault true {} "The Design Doc as written"

#eval checkBreakers known
