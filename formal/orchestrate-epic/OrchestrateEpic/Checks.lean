import OrchestrateEpic.Verify

/-!
# The checks `lake build` runs

Each `#eval` that throws fails the build.
-/

namespace OE

/-- An Owner whose marker expired pushes after the answer started the next Owner, and the push gives the
next Owner's marker its result. -/
def lateOwnerPush : List String := [
  "oe ready row 8: start an Owner, start 1",
  "6 hours pass since the marker's start",
  "oe ready row 7: hold the Issue",
  "the person answers that the code must change",
  "oe ready row 8: start an Owner, start 2",
  "Owner start 1 pushes"
]

/-- A re-run request after an answer that changes no code starts an Owner, because the answer is newer
than the head and stays a repair signal. -/
def rerunAfterNoCodeAnswer : List String := [
  "oe ready row 8: start an Owner, start 1",
  "Owner start 1 pushes",
  "CI on commit 1 succeeds",
  "oe ready row 11: start a Verifier, start 2",
  "6 hours pass since the marker's start",
  "oe ready row 7: hold the Issue",
  "the person answers that no code changes",
  "oe ready row 8: start an Owner, start 3",
  "Verifier start 2 writes a failure verdict",
  "Owner start 3 writes a question",
  "the person asks for a re-run"
]

/-- A head with no verdict cannot take a re-run request, so a person who sees no fault can only answer
that no code changes, and each Owner then pushes nothing. -/
def headWithoutVerdict : List String := [
  "oe ready row 8: start an Owner, start 1",
  "6 hours pass since the marker's start",
  "oe ready row 7: hold the Issue",
  "Owner start 1 pushes"
]

/-- The same dead end with the host clock ahead: the push is older than the marker's start, so it gives
no result, and the Owner's end then holds the Issue. -/
def headWithoutVerdictSkewed : List String := [
  "the host clock runs ahead of GitHub",
  "oe ready row 8: start an Owner, start 1",
  "Owner start 1 pushes"
]

/-- The counterexamples in the Design Doc as written. Only these paths pass the build. -/
def known : List Known :=
  [false, true].flatMap fun skew =>
    [ { view := .codeFault, skew, property := .resultBelongsToStart, path := lateOwnerPush },
      { view := .noFault, skew, property := .resultBelongsToStart, path := lateOwnerPush },
      { view := .noFault, skew, property := .inputTakesEffect, path := rerunAfterNoCodeAnswer },
      { view := .noFault, skew, property := .noDeadEnd,
        path := if skew then headWithoutVerdictSkewed else headWithoutVerdict } ]

end OE

open OE

#eval checkHash

#eval checkKnown known .codeFault false {} "The Design Doc as written"
#eval checkKnown known .noFault false {} "The Design Doc as written"
#eval checkKnown known .codeFault true {} "The Design Doc as written"
#eval checkKnown known .noFault true {} "The Design Doc as written"

#eval checkKnown [] .codeFault false fixes "With every fix"
#eval checkKnown [] .noFault false fixes "With every fix"
#eval checkKnown [] .codeFault true fixes "With every fix"
#eval checkKnown [] .noFault true fixes "With every fix"

#eval checkBreakers
