import OrchestrateEpic.Verify

/-!
# The checks `lake build` runs

Each `#eval` that throws fails the build.
-/

namespace OE

/-- No counterexample of the Design Doc as written is known. -/
def known : List Known := []

end OE

open OE

#eval checkHash

#eval checkKnown known .codeFault false {} "The Design Doc as written"
#eval checkKnown known .noFault false {} "The Design Doc as written"
#eval checkKnown known .codeFault true {} "The Design Doc as written"
#eval checkKnown known .noFault true {} "The Design Doc as written"

#eval checkBreakers
