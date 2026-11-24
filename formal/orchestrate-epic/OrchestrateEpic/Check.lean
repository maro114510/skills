import Std.Data.HashMap
import OrchestrateEpic.Model

/-!
# The search and the five properties

The properties are those of `docs/design/design-verification.md` § Properties. Each check returns the
shortest event path, from the start of the Issue, to the state that breaks it.
-/

namespace OE

structure Graph where
  states : Array St
  /-- Outgoing events of each state, by state index. -/
  edges : Array (Array (Event × Nat))
  /-- The event that first reached each state in breadth-first order, so a path back is a shortest one. -/
  parent : Array (Option (Nat × Event))

/-- Breadth-first search over every reachable state. Fails past `limit` states. -/
def explore (cfg : Config) (limit : Nat := 400000) : Except String Graph := Id.run do
  let s0 := normalize init
  let mut index : Std.HashMap St Nat := Std.HashMap.emptyWithCapacity.insert s0 0
  let mut states : Array St := #[s0]
  let mut parent : Array (Option (Nat × Event)) := #[none]
  let mut edges : Array (Array (Event × Nat)) := #[]
  let mut i := 0
  while i < states.size do
    if states.size > limit then return .error s!"more than {limit} states"
    let s := states[i]!
    let mut out : Array (Event × Nat) := #[]
    for (e, t) in step cfg s do
      match index[t]? with
      | some j => out := out.push (e, j)
      | none =>
        let j := states.size
        index := index.insert t j
        states := states.push t
        parent := parent.push (some (i, e))
        out := out.push (e, j)
    edges := edges.push out
    i := i + 1
  return .ok { states, edges, parent }

/-- A path as the events taken and the state each one reaches. -/
abbrev Path := List (Event × Nat)

def Graph.pathTo (g : Graph) (j : Nat) : Path := Id.run do
  let mut path : Path := []
  let mut k := j
  for _ in [0:g.states.size] do
    match g.parent[k]! with
    | some (p, e) => path := (e, k) :: path; k := p
    | none => break
  return path

/-- A shortest path from `src` to `dst` over the events `ok` allows. -/
def Graph.pathBetween (g : Graph) (ok : Event → Bool) (src dst : Nat) : Option Path := Id.run do
  let mut prev : Std.HashMap Nat (Nat × Event) := {}
  let mut queue : Array Nat := #[src]
  let mut i := 0
  while i < queue.size do
    let u := queue[i]!
    i := i + 1
    for (e, v) in g.edges[u]! do
      if !ok e || prev.contains v || v == src then continue
      prev := prev.insert v (u, e)
      if v == dst then
        let mut path : Path := []
        let mut k := dst
        for _ in [0:g.states.size] do
          match prev[k]? with
          | some (p, e') => path := (e', k) :: path; k := p; if k == src then break
          | none => break
        return some path
      queue := queue.push v
  return none

inductive Property
  | noDoubleStart
  | resultBelongsToStart
  | inputTakesEffect
  | noDeadEnd
  | startsBounded
  deriving BEq, Repr, DecidableEq

def Property.all : List Property :=
  [.noDoubleStart, .resultBelongsToStart, .inputTakesEffect, .noDeadEnd, .startsBounded]

def Property.name : Property → String
  | .noDoubleStart => "No double start"
  | .resultBelongsToStart => "A result belongs to its start"
  | .inputTakesEffect => "A person's input takes effect"
  | .noDeadEnd => "No dead end"
  | .startsBounded => "Starts are bounded"

/-- The first state in breadth-first order where `bad` holds, with the event that leads out of it. -/
def firstEdge (g : Graph) (bad : St → Event → Nat → Bool) : Option Path := Id.run do
  for i in [0:g.states.size] do
    for (e, j) in g.edges[i]! do
      if bad g.states[i]! e j then return some (g.pathTo i ++ [(e, j)])
  return none

def firstState (g : Graph) (bad : St → Bool) : Option Path := Id.run do
  for i in [0:g.states.size] do
    if bad g.states[i]! then return some (g.pathTo i)
  return none

/-- "No agent starts while the working marker is live" -/
def noDoubleStart (cfg : Config) (g : Graph) : Option Path :=
  firstEdge g fun s e _ => e.isStart && markerLive cfg s

/-- "A push, a question, or a verdict gives a result, or ends a marker, only for the start that produced
it" -/
def resultBelongsToStart (cfg : Config) (g : Graph) : Option Path :=
  firstState g fun s => s.marker.any fun m =>
    m.endedBy.any (· != m.start) || (resultSources cfg s m).any (· != m.start)

/-- "After an answer or a re-run request, the next read starts the agent it asks for, unless a fact newer
than the input, or a fact about the Issue, its dependencies, the PR's state, or CI, decides first".
The read right after the input has no fact newer than it. The facts about CI are a pending or failed check
on the head and the cap on failed checks. -/
def inputTakesEffect (cfg : Config) (g : Graph) : Option Path :=
  firstEdge g fun _ e j =>
    let t := g.states[j]!
    let d := decide cfg t
    let ciFact := (head? t).any (fun h => h.ci != .success) || (d.row == 8 && d.action == .hold)
    match e with
    | .answer _ => d.action != .startOwner && !ciFact
    | .rerun => d.action != .startVerifier && !ciFact
    | _ => false

/-- The events a path to the merge may use: agent results, CI results, time passing, and the person's
replies the view allows. An agent dying and the clock moving are left out, since nobody can count on them. -/
def Event.helps : Event → Bool
  | .agentDies _ | .skewTo _ => false
  | _ => true

/-- "some sequence of agent results, CI results, and the person's answers, re-run requests, and merges ends
in a merge of a head with a success verdict" -/
def noDeadEnd (_cfg : Config) (g : Graph) : Option Path := Id.run do
  let n := g.states.size
  let mut back : Array (Array Nat) := Array.replicate n #[]
  for i in [0:n] do
    for (e, j) in g.edges[i]! do
      if e.helps then back := back.modify j (·.push i)
  let mut good : Array Bool := g.states.map (·.merged)
  let mut queue : Array Nat := (Array.range n).filter (good[·]!)
  let mut k := 0
  while k < queue.size do
    let v := queue[k]!
    k := k + 1
    for u in back[v]! do
      if !good[u]! then
        good := good.set! u true
        queue := queue.push u
  for i in [0:n] do
    if !good[i]! then return some (g.pathTo i)
  return none

/-- Strongly connected components over the events that are not the person's input, by Kosaraju's
algorithm, iterative so a long path does not overflow the stack. -/
def components (g : Graph) : Array Nat := Id.run do
  let n := g.states.size
  let fwd (i : Nat) : Array Nat := (g.edges[i]!.filter (!·.1.isInput)).map (·.2)
  let mut back : Array (Array Nat) := Array.replicate n #[]
  for i in [0:n] do
    for j in fwd i do back := back.modify j (·.push i)
  let mut seen : Array Bool := Array.replicate n false
  let mut order : Array Nat := #[]
  for r in [0:n] do
    if seen[r]! then continue
    seen := seen.set! r true
    let mut stack : Array (Nat × Nat) := #[(r, 0)]
    while h : stack.size > 0 do
      let (u, k) := stack[stack.size - 1]
      let next := fwd u
      if k < next.size then
        stack := stack.set! (stack.size - 1) (u, k + 1)
        let v := next[k]!
        if !seen[v]! then
          seen := seen.set! v true
          stack := stack.push (v, 0)
      else
        order := order.push u
        stack := stack.pop
  let mut comp : Array Nat := Array.replicate n n
  let mut c := 0
  for r in order.reverse do
    if comp[r]! != n then continue
    comp := comp.set! r c
    let mut stack : Array Nat := #[r]
    while h : stack.size > 0 do
      let u := stack[stack.size - 1]
      stack := stack.pop
      for v in back[u]! do
        if comp[v]! == n then
          comp := comp.set! v c
          stack := stack.push v
    c := c + 1
  return comp

/-- "Between two inputs from the person, the number of agent starts is bounded": no cycle of events that
are not the person's input holds a start. The path ends by going round that cycle once. -/
def startsBounded (_cfg : Config) (g : Graph) : Option Path := Id.run do
  let comp := components g
  for i in [0:g.states.size] do
    for (e, j) in g.edges[i]! do
      if e.isStart && comp[i]! == comp[j]! then
        let back := (g.pathBetween (!·.isInput) j i).getD []
        return some (g.pathTo i ++ [(e, j)] ++ back)
  return none

/-- The labels of a path, replayed from the start without renumbering, so a start or a commit keeps one
number along the whole path. -/
def labels (cfg : Config) (g : Graph) (path : Path) : List String := Id.run do
  let mut raw := init
  let mut out : Array String := #[]
  for (e, j) in path do
    match (rawStep cfg raw).find? (fun (_, t) => normalize t == g.states[j]!) with
    | some (e', t) =>
      let started := if e'.isStart then s!", start {nextId raw}" else ""
      out := out.push (e'.label ++ started); raw := t
    | none => out := out.push e.label; raw := g.states[j]!
  return out.toList

def Property.check (p : Property) (cfg : Config) (g : Graph) : Option Path :=
  match p with
  | .noDoubleStart => OE.noDoubleStart cfg g
  | .resultBelongsToStart => OE.resultBelongsToStart cfg g
  | .inputTakesEffect => OE.inputTakesEffect cfg g
  | .noDeadEnd => OE.noDeadEnd cfg g
  | .startsBounded => OE.startsBounded cfg g

end OE
