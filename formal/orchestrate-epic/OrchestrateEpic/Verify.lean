import OrchestrateEpic.Check

/-!
# What `lake build` checks

The build fails when:

- the checked text of the Design Docs no longer has the recorded hash
- the Design Doc as written breaks a property with any event path other than a known counterexample below
- the model with every fix switch on breaks a property
- a switch no longer breaks the property it names, or a property has no switch
-/

namespace OE

/-! ## The hash of the checked text -/

/-- FNV-1a, 64 bits. -/
def fnv1a (s : String) : UInt64 :=
  s.toUTF8.foldl (fun h b => (h ^^^ b.toUInt64) * 0x100000001b3) 0xcbf29ce484222325

def hex (n : UInt64) : String :=
  let d := Nat.toDigits 16 n.toNat
  String.ofList (List.replicate (16 - d.length) '0' ++ d)

/-- The lines of the `## <title>` section, up to the next `## ` heading. -/
def section? (lines : List String) (title : String) : Option (List String) :=
  match lines.dropWhile (· != s!"## {title}") with
  | [] => none
  | h :: rest => some (h :: rest.takeWhile (!·.startsWith "## "))

/-- design-verification.md: "Checked sections | Every section of `orchestrate-epic.md` that a property
cites: Purpose, Invariants, and Source of Truth", and "of this document's Properties table" -/
def checkedText (epic verification : String) : Except String String := do
  let epicLines := epic.splitOn "\n"
  let mut parts : List String := []
  for title in ["Purpose", "Invariants", "Source of Truth"] do
    match section? epicLines title with
    | some ls => parts := parts ++ ls
    | none => throw s!"orchestrate-epic.md has no section {title}"
  match section? (verification.splitOn "\n") "Properties" with
  | some ls =>
    let table := (ls.dropWhile (!·.startsWith "|")).takeWhile (·.startsWith "|")
    if table.isEmpty then throw "design-verification.md has no Properties table"
    parts := parts ++ table
  | none => throw "design-verification.md has no section Properties"
  return String.intercalate "\n" parts

/-- Update only after reading the changed text and changing the model to match it. -/
def recordedHash : String := "b8d2b7e0d78eaef9"

def checkHash : IO Unit := do
  let epic ← IO.FS.readFile "../../docs/design/orchestrate-epic.md"
  let verification ← IO.FS.readFile "../../docs/design/design-verification.md"
  match checkedText epic verification with
  | .error e => throw (IO.userError e)
  | .ok text =>
    let h := hex (fnv1a text)
    if h != recordedHash then
      throw (IO.userError s!"the checked text changed: its hash is {h}, and the model records {recordedHash}. Check the model against the change, then record the new hash in OrchestrateEpic/Verify.lean")
    IO.println s!"checked text hash {h} matches"

/-! ## The runs -/

def View.name : View → String
  | .codeFault => "a person who sees a fault in the code"
  | .noFault => "a person who sees no fault in the code"

/-- The fixes for the counterexamples in the Design Doc as written. With all of them on, every property
holds, so a switch that breaks a property from here is what breaks it. -/
def fixes : Switches :=
  { fixOwnerResultCarriesStart := true, fixVerdictCarriesStart := true, fixRerunClearsAnswer := true,
    fixRerunWithoutSuccess := true }

def explored (cfg : Config) : IO Graph :=
  match explore cfg (limit := 3000000) with
  | .ok g => pure g
  | .error e => throw (IO.userError e)

def showPath (path : List String) : String :=
  String.intercalate "\n" ((path.zip (List.range path.length)).map fun (e, i) => s!"  {i + 1}. {e}")

/-- A counterexample in the Design Doc as written, shown in the pull request that found it. -/
structure Known where
  view : View
  skew : Bool
  property : Property
  path : List String

def checkKnown (known : List Known) (view : View) (skew : Bool) (sw : Switches) (label : String) :
    IO Unit := do
  let cfg : Config := { view, skew, sw }
  let g ← explored cfg
  IO.println s!"{label}, for {view.name}{if skew then ", with clock skew" else ""}: {g.states.size} states"
  let mut failed := false
  for p in Property.all do
    let expected := known.find? fun k => k.view == view && k.skew == skew && k.property == p
    match (p.check cfg g).map (labels cfg g), expected with
    | none, none => IO.println s!"  holds: {p.name}"
    | some path, some k =>
      if path == k.path then
        IO.println s!"  known counterexample: {p.name}\n{showPath path}"
      else
        failed := true
        IO.println s!"  BREAKS: {p.name}, on a path other than the known one\n{showPath path}"
    | some path, none =>
      failed := true
      IO.println s!"  BREAKS: {p.name}\n{showPath path}"
    | none, some _ =>
      failed := true
      IO.println s!"  holds, but a counterexample is recorded as known: {p.name}"
  if failed then throw (IO.userError s!"{label}: a property breaks other than as known")

/-- A switch and the property it must break: the property holds on `base` and breaks once the switch is
on. -/
structure Breaker where
  name : String
  view : View
  property : Property
  on : Switches → Switches
  base : Switches := fixes

def breakers : List Breaker := [
  { name := "Row 6 is gone", view := .noFault, property := .noDoubleStart,
    on := ({ · with ignoreLiveMarker := true }) },
  { name := "oe end writes into any marker", view := .codeFault, property := .resultBelongsToStart,
    on := ({ · with endAnyMarker := true }) },
  { name := "Row 8 has no cap", view := .codeFault, property := .startsBounded,
    on := ({ · with noFailureCap := true }) },
  { name := "Known defect: a re-run request loses to an older working marker", view := .noFault,
    property := .inputTakesEffect, on := ({ · with inputKeepsMarker := true }) },
  -- The Design Doc guards against this defect only by when it accepts a re-run request, so the base
  -- drops the two fixes that would guard it another way.
  { name := "Known defect: a late verdict from an older Verifier counts for a newer start", view := .noFault,
    property := .resultBelongsToStart, on := ({ · with rerunWithoutFailureVerdict := true }),
    base := { fixes with fixVerdictCarriesStart := false, fixRerunWithoutSuccess := false } },
  { name := "Known defect: an answer that changes no code loops forever", view := .noFault,
    property := .noDeadEnd, on := ({ · with noRerun := true }) }
]

def checkBreakers : IO Unit := do
  for p in Property.all do
    if !breakers.any (·.property == p) then throw (IO.userError s!"no switch breaks {p.name}")
  for b in breakers do
    let base : Config := { view := b.view, sw := b.base }
    if (b.property.check base (← explored base)).isSome then
      throw (IO.userError s!"switch \"{b.name}\": {b.property.name} already breaks without it")
    let cfg : Config := { view := b.view, sw := b.on b.base }
    let g ← explored cfg
    match (b.property.check cfg g).map (labels cfg g) with
    | some path => IO.println s!"switch \"{b.name}\" breaks {b.property.name}\n{showPath path}"
    | none => throw (IO.userError s!"switch \"{b.name}\" no longer breaks {b.property.name}")

end OE
