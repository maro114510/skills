import OrchestrateEpic.Check

/-!
# What `lake build` checks

The build fails when:

- the checked text of the Design Docs no longer has the recorded hash
- the Design Doc as written breaks a property with any event path other than a known counterexample below
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
def recordedHash : String := "c2918738684c021e"

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
  /-- The Design Doc change that removes this counterexample. -/
  fix : Switches → Switches := id

/-- A known counterexample passes only when its path is a run that breaks its property, and its fix makes
the property hold, so it hides no other violation of the property, however short. -/
def checkKnown (known : List Known) (view : View) (skew : Bool) (sw : Switches) (label : String) :
    IO Unit := do
  let cfg : Config := { view, skew, sw }
  let g ← explored cfg
  IO.println s!"{label}, for {view.name}{if skew then ", with clock skew" else ""}: {g.states.size} states, with at most {cfg.maxAgents} starts that can still write"
  let mut failed := false
  for p in Property.all do
    let expected := known.find? fun k => k.view == view && k.skew == skew && k.property == p
    match (p.check cfg g).map (labels cfg g), expected with
    | none, none => IO.println s!"  holds: {p.name}"
    | some path, some k =>
      if !(replay cfg g k.path).any (p.breaksOn cfg g) then
        failed := true
        IO.println s!"  BREAKS: {p.name}, and the known path does not break it\n{showPath path}"
      else
        let fixed : Config := { cfg with sw := k.fix sw }
        let fg ← explored fixed
        match (p.check fixed fg).map (labels fixed fg) with
        | none => IO.println s!"  known counterexample: {p.name}\n{showPath k.path}"
        | some other =>
          failed := true
          IO.println s!"  BREAKS: {p.name}, on a path the known one's fix leaves\n{showPath other}"
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
  base : Switches := {}
  skew : Bool := false

def breakers : List Breaker := [
  { name := "Row 6 is gone", view := .noFault, property := .noDoubleStart,
    on := ({ · with ignoreLiveMarker := true }) },
  { name := "oe end writes into any marker", view := .codeFault, property := .resultBelongsToStart,
    on := ({ · with endAnyMarker := true }) },
  { name := "Row 8 has no cap", view := .codeFault, property := .startsBounded,
    on := ({ · with noFailureCap := true }) },
  { name := "Known defect: a re-run request loses to an older working marker", view := .noFault,
    property := .inputTakesEffect, on := ({ · with inputKeepsMarker := true }) },
  { name := "Known defect: a late verdict from an older Verifier counts for a newer start", view := .noFault,
    property := .resultBelongsToStart, on := ({ · with verdictFromAnyStart := true }) },
  { name := "Known defect: an answer that changes no code loops forever", view := .noFault,
    property := .noDeadEnd, on := ({ · with noRerun := true }) },
  -- The counterexamples this model found in the Design Doc before it was fixed: each switch undoes one fix.
  { name := "Fixed defect: a late push from an expired Owner gives a newer Owner its result",
    view := .codeFault, property := .resultBelongsToStart, on := ({ · with ownerResultFromAnyStart := true }) },
  { name := "Fixed defect: a re-run request after an answer that changes no code starts an Owner",
    view := .noFault, property := .inputTakesEffect, on := ({ · with answerOutlivesRerun := true }) },
  { name := "Fixed defect: a head with no verdict takes no re-run request", view := .noFault,
    property := .noDeadEnd, on := ({ · with rerunOnlyOnFailure := true }) }
]

def checkBreakers : IO Unit := do
  for p in Property.all do
    if !breakers.any (·.property == p) then throw (IO.userError s!"no switch breaks {p.name}")
  for b in breakers do
    let base : Config := { view := b.view, skew := b.skew, sw := b.base }
    if (b.property.check base (← explored base)).isSome then
      throw (IO.userError s!"switch \"{b.name}\": {b.property.name} already breaks without it")
    let cfg : Config := { view := b.view, skew := b.skew, sw := b.on b.base }
    let g ← explored cfg
    match (b.property.check cfg g).map (labels cfg g) with
    | some path => IO.println s!"switch \"{b.name}\" breaks {b.property.name}\n{showPath path}"
    | none => throw (IO.userError s!"switch \"{b.name}\" no longer breaks {b.property.name}")

end OE
