import Std.Data.HashMap

/-!
# One Issue of orchestrate-epic

The model holds one Issue, as `docs/design/design-verification.md` § Scope says, and is written from
`docs/design/orchestrate-epic.md` alone. Each rule quotes the Design Doc text it encodes, marked `DD:`.

Times: every event GitHub records takes the next time `now + 4`. A time the host writes, the start and
end times of the working marker, is that time plus `5 * skew`, so with a skew it lands after the next
event or before the previous one. No two records share a time, so "newer than" is never a tie.
-/

namespace OE

inductive Role | owner | verifier
  deriving BEq, Hashable, Repr, DecidableEq

/-- What an answer asks for. -/
inductive Kind | change | noCode
  deriving BEq, Hashable, Repr, DecidableEq

/-- The view the person keeps for "No dead end" in `design-verification.md` § Properties. -/
inductive View | codeFault | noFault
  deriving BEq, Hashable, Repr, DecidableEq

inductive Ci | pending | success | failure
  deriving BEq, Hashable, Repr, DecidableEq

structure Verdict where
  time : Nat
  success : Bool
  src : Nat
  deriving BEq, Hashable, Repr

structure Commit where
  sha : Nat
  pushedAt : Nat
  src : Nat
  ci : Ci
  /-- Pushed by an Owner that started after an answer asking for a code change. -/
  fixed : Bool
  /-- The latest verify status other than pending. -/
  verdict : Option Verdict
  deriving BEq, Hashable, Repr

/-- DD: "One hidden line at the end of the Issue body, holding the role, the start time, the SHA for a
Verifier, ... and the end time once oe end records it" -/
structure Marker where
  role : Role
  start : Nat
  startAt : Nat
  sha : Option Nat
  endAt : Option Nat
  /-- The start whose oe end wrote `endAt`. -/
  endedBy : Option Nat
  /-- DD: "stays live for 2 minutes after the end" has passed. -/
  graceOver : Bool
  /-- DD: "6 hours pass since its start time" has passed. -/
  expired : Bool
  deriving BEq, Hashable, Repr

/-- An agent start that can still write its result or end. -/
structure Agent where
  id : Nat
  role : Role
  sha : Option Nat
  /-- The latest answer when it started, which the Owner reads on the Issue. -/
  answerAtStart : Option Kind
  /-- The decisions section was not empty when it started. -/
  decidedAtStart : Bool
  emitted : Bool
  ended : Bool
  deriving BEq, Hashable, Repr

structure Question where
  time : Nat
  src : Nat
  deriving BEq, Hashable, Repr

structure St where
  now : Nat := 10
  skew : Int := 0
  /-- The PR's commits, oldest first; the head is the last. Empty while no PR exists. -/
  commits : List Commit := []
  marker : Option Marker := none
  agents : List Agent := []
  questions : List Question := []
  /-- The latest hold or question. -/
  waitAt : Option Nat := none
  answer : Option (Nat × Kind) := none
  rerunAt : Option Nat := none
  /-- DD: "An answer or a re-run request recorded through oe appends its decision to a decisions section" -/
  decided : Bool := false
  merged : Bool := false
  deriving BEq, Hashable, Repr, Inhabited

/-- A switch changes one rule. All off is the Design Doc as written. -/
structure Switches where
  /-- Breaks "No double start": row 6 is gone. -/
  ignoreLiveMarker : Bool := false
  /-- Breaks "A result belongs to its start": oe end writes into whatever marker is there. -/
  endAnyMarker : Bool := false
  /-- Breaks "Starts are bounded": row 8 never holds on the cap. -/
  noFailureCap : Bool := false
  /-- Known defect: a re-run request that loses to an older working marker. -/
  inputKeepsMarker : Bool := false
  /-- Known defect: a late verdict from an older Verifier counted for a newer start. -/
  rerunWithoutFailureVerdict : Bool := false
  /-- Known defect: an answer that changes no code loops forever for a person who sees no fault. -/
  noRerun : Bool := false
  /-- A fix for a counterexample this model found, not in the Design Doc: a push or a question gives an
  Owner's marker its result only when the marker's own start wrote it. -/
  fixOwnerResultCarriesStart : Bool := false
  /-- A fix, not in the Design Doc: a re-run request newer than the latest answer clears that answer's
  repair signal. -/
  fixRerunClearsAnswer : Bool := false
  /-- A fix, not in the Design Doc: a verdict gives a Verifier's marker its result only when the marker's
  own start wrote it. -/
  fixVerdictCarriesStart : Bool := false
  /-- A fix, not in the Design Doc: oe question accepts a re-run request whenever the head has no success
  verdict, so a head whose Verifier died can be judged without an Owner. -/
  fixRerunWithoutSuccess : Bool := false
  deriving BEq, Hashable, Repr

structure Config where
  view : View
  /-- Clock skew between the host and GitHub is an event. -/
  skew : Bool := false
  sw : Switches := {}
  /-- Agent starts that can still write a result at once; a start past it drops the oldest, which never writes. -/
  maxAgents : Nat := 2
  deriving Repr

/-! ## Reading the state -/

def newer (t : Nat) : Option Nat → Bool
  | none => true
  | some u => t > u

def answerAt (s : St) : Option Nat := s.answer.map (·.1)

def head? (s : St) : Option Commit := s.commits.getLast?

def commit? (s : St) (sha : Nat) : Option Commit := s.commits.find? (·.sha == sha)

/-- DD: "A SHA's verdict is its latest verify status other than pending that is newer than the latest
re-run request, so the request is used once and an older verdict counts as none. Both times are GitHub's" -/
def verdictOf (s : St) (c : Commit) : Option Verdict :=
  match c.verdict with
  | some v => if newer v.time s.rerunAt then some v else none
  | none => none

def headVerdict (s : St) : Option Verdict := (head? s).bind (verdictOf s)

/-- The starts whose records give the marker its result. -/
def resultSources (cfg : Config) (s : St) (m : Marker) : List Nat :=
  let srcs := match m.role with
    | .owner =>
      -- DD: "An Owner's marker gives its result when an open PR from the branch has a head pushed after
      -- the start time, or the Issue gets a question after it"
      let push := match head? s with
        | some h => if h.pushedAt > m.startAt then [h.src] else []
        | none => []
      let srcs := push ++ (s.questions.filter (·.time > m.startAt)).map (·.src)
      if cfg.sw.fixOwnerResultCarriesStart then srcs.filter (· == m.start) else srcs
    | .verifier =>
      -- DD: "A Verifier's marker gives its result when its SHA gets a verdict, as Counting reads it"
      match m.sha.bind (commit? s) |>.bind (verdictOf s) with
      | some v => if cfg.sw.fixVerdictCarriesStart && v.src != m.start then [] else [v.src]
      | none => []
  srcs

inductive MarkerState | live | endedNoResult | over
  deriving BEq, Repr

def markerState (cfg : Config) (s : St) (m : Marker) : MarkerState :=
  -- DD: "A marker that gives its result never holds the Issue, whether or not it has an end time"
  if !(resultSources cfg s m).isEmpty then .over
  -- DD: "An answer or a re-run request newer than a marker ends it, so it starts the next agent instead
  -- of holding the Issue again"
  else if !cfg.sw.inputKeepsMarker &&
      ((answerAt s).any (· > m.startAt) || s.rerunAt.any (· > m.startAt)) then .over
  else match m.endAt with
    -- DD: "A marker with an end time and no result stays live for 2 minutes after the end, ... and ended
    -- with no result after that"
    | some _ => if m.graceOver then .endedNoResult else .live
    -- DD: "A marker with no end time is live until it gives its result or 6 hours pass since its start
    -- time, and expired with no result after that"
    | none => if m.expired then .endedNoResult else .live

def markerLive (cfg : Config) (s : St) : Bool :=
  s.marker.any (markerState cfg s · == .live)

/-! ## The next-action table -/

inductive Action | done | waitPerson | waitAgent | hold | startOwner | startVerifier | waitCi | waitMerge
  deriving BEq, Repr

def Action.name : Action → String
  | .done => "mark it done"
  | .waitPerson => "wait on the person"
  | .waitAgent => "wait for the agent"
  | .hold => "hold the Issue"
  | .startOwner => "start an Owner"
  | .startVerifier => "start a Verifier"
  | .waitCi => "wait for CI"
  | .waitMerge => "wait for an engineer to merge"

structure Decision where
  row : Nat
  action : Action
  deriving BEq, Repr

/-- DD: "no re-run request came since the latest answer" -/
def rerunSinceAnswer (s : St) : Bool :=
  match s.rerunAt, answerAt s with
  | some r, some a => r > a
  | some _, none => true
  | none, _ => false

/-- Commits of the PR pushed since the latest answer. -/
def sinceAnswer (s : St) : List Commit := s.commits.filter (newer ·.pushedAt (answerAt s))

def failedCheck (c : Commit) : Bool := c.ci == .failure

/-- DD: "Repair signals" -/
def repairSignal (cfg : Config) (s : St) : Bool :=
  match head? s with
  -- DD: "No PR exists yet"
  | none => true
  | some h =>
    -- DD: "A check on the PR's head SHA failed"
    failedCheck h ||
    -- DD: "The PR's head SHA has a failure verdict, no re-run request came since the latest answer, and
    -- no other commit of the PR committed since the latest answer had a failure verdict"
    ((headVerdict s).any (!·.success) && !rerunSinceAnswer s &&
      !((sinceAnswer s).any fun c => c.sha != h.sha && (verdictOf s c).any (!·.success))) ||
    -- DD: "Since the PR's head was pushed, one of these was given: An answer recorded through oe"
    ((answerAt s).any (· > h.pushedAt) && !(cfg.sw.fixRerunClearsAnswer && rerunSinceAnswer s))

/-- DD: "For each Issue, oe ready reads this table from the top and outputs the action of the first row
that matches." Rows 3, 4, and 5 are absent: the Issue has no dependency, and the person closes nothing,
as "No dead end" assumes. The conflict signal and rows 9 and 10 on a head with no checks are absent, since
no property cited needs them. -/
def decide (cfg : Config) (s : St) : Decision :=
  -- DD row 1: "The Issue is closed | Mark it done"
  if s.merged then ⟨1, .done⟩
  -- DD row 2: "A hold or a question is newer than the latest answer and the latest re-run request | Wait
  -- on the person"
  else if s.waitAt.any (fun w => newer w (answerAt s) && newer w s.rerunAt) then ⟨2, .waitPerson⟩
  -- DD row 6: "The working marker is live | Wait for the agent"
  else if !cfg.sw.ignoreLiveMarker && markerLive cfg s then ⟨6, .waitAgent⟩
  -- DD row 7: "The working marker ended or expired with no result | Hold the Issue"
  else if s.marker.any (markerState cfg s · == .endedNoResult) then ⟨7, .hold⟩
  -- DD row 8: "A repair signal below is present | Hold the Issue when 3 commits of the PR since the latest
  -- answer had a failed check. Otherwise start an Owner"
  else if repairSignal cfg s then
    if !cfg.sw.noFailureCap && ((sinceAnswer s).filter failedCheck).length ≥ 3 then ⟨8, .hold⟩
    else ⟨8, .startOwner⟩
  else match head? s with
    | none => ⟨8, .startOwner⟩
    | some h =>
      -- DD row 9: "A check on the PR's head SHA is pending ... | Wait for CI"
      if h.ci == .pending then ⟨9, .waitCi⟩
      else match verdictOf s h with
        -- DD row 11: "The PR's head SHA has no verdict | Start a Verifier"
        | none => ⟨11, .startVerifier⟩
        -- DD row 12: "The PR's head SHA has a failure verdict | Hold the Issue"
        | some ⟨_, false, _⟩ => ⟨12, .hold⟩
        -- DD row 13: "The PR's head SHA has a success verdict | Wait for an engineer to merge"
        | some ⟨_, true, _⟩ => ⟨13, .waitMerge⟩

/-- DD: "oe question accepts it only while the Issue waits on the person and the PR's head has a failure
verdict, as Counting reads it" -/
def rerunAccepted (cfg : Config) (s : St) : Bool :=
  !cfg.sw.noRerun && (decide cfg s).action == .waitPerson && (head? s).isSome &&
    (cfg.sw.rerunWithoutFailureVerdict ||
      (headVerdict s).any (!·.success) ||
      (cfg.sw.fixRerunWithoutSuccess && !(headVerdict s).any (·.success)))

/-! ## Events -/

inductive Event
  | read (d : Decision)
  | push (agent : Nat)
  | question (agent : Nat)
  | verdict (agent : Nat) (success : Bool)
  | agentEnd (agent : Nat)
  | agentDies (agent : Nat)
  | ci (sha : Nat) (success : Bool)
  | grace
  | expire
  | answer (k : Kind)
  | rerun
  | merge
  | skewTo (k : Int)
  deriving Repr

/-- The person's own inputs, which "Starts are bounded" counts between. -/
def Event.isInput : Event → Bool
  | .answer _ | .rerun | .merge => true
  | _ => false

def Event.isStart : Event → Bool
  | .read ⟨_, .startOwner⟩ | .read ⟨_, .startVerifier⟩ => true
  | _ => false

def Event.label : Event → String
  | .read d => s!"oe ready row {d.row}: {d.action.name}"
  | .push a => s!"Owner start {a} pushes"
  | .question a => s!"Owner start {a} writes a question"
  | .verdict a ok => s!"Verifier start {a} writes a {if ok then "success" else "failure"} verdict"
  | .agentEnd a => s!"start {a} ends, and oe end runs"
  | .agentDies a => s!"start {a} dies without writing"
  | .ci sha ok => s!"CI on commit {sha} {if ok then "succeeds" else "fails"}"
  | .grace => "2 minutes pass after the marker's end"
  | .expire => "6 hours pass since the marker's start"
  | .answer k => match k with
    | .change => "the person answers that the code must change"
    | .noCode => "the person answers that no code changes"
  | .rerun => "the person asks for a re-run"
  | .merge => "the person merges"
  | .skewTo k => if k > 0 then "the host clock runs ahead of GitHub" else "the host clock runs behind GitHub"

def tick (s : St) : St × Nat := ({ s with now := s.now + 4 }, s.now + 4)

/-- A time the host writes. -/
def stamp (s : St) (t : Nat) : Nat := ((t : Int) + 5 * s.skew).toNat

def nextId (s : St) : Nat :=
  let ids := s.agents.map (·.id) ++ s.marker.toList.map (·.start)
  ids.foldl max 0 + 1

def nextSha (s : St) : Nat := (s.commits.map (·.sha)).foldl max 0 + 1

def setAgent (s : St) (a : Agent) : St :=
  let agents := s.agents.map fun b => if b.id == a.id then a else b
  { s with agents := agents.filter fun b => !(b.emitted && b.ended) }

def setHead (s : St) (h : Commit) : St :=
  { s with commits := s.commits.dropLast ++ [h] }

/-- DD: "oe start | Runs every step that starts an Owner or a Verifier for one Issue, writes the working
marker" -/
def start (cfg : Config) (s : St) (role : Role) : St :=
  let (s, t) := tick s
  let id := nextId s
  let sha := if role == .verifier then (head? s).map (·.sha) else none
  let a : Agent := { id, role, sha, answerAtStart := s.answer.map (·.2), decidedAtStart := s.decided,
                     emitted := false, ended := false }
  let kept := if s.agents.length ≥ cfg.maxAgents then s.agents.drop 1 else s.agents
  { s with agents := kept ++ [a],
           marker := some { role, start := id, startAt := stamp s t, sha, endAt := none, endedBy := none,
                            graceOver := false, expired := false } }

/-- The Owner pushes only what the person's view allows. -/
def mayPush (cfg : Config) (a : Agent) : Bool :=
  match cfg.view with
  -- design-verification.md: "answers that no code changes, after which the Owner pushes nothing"
  | .noFault => a.answerAtStart != some .noCode
  | .codeFault => true

/-- The verdict a Verifier reaches on the commit it judges. -/
def passes (cfg : Config) (a : Agent) (c : Commit) : Bool :=
  match cfg.view with
  | .codeFault => c.fixed
  -- DD: "The Issue body's decisions section takes precedence over the criteria it contradicts"
  | .noFault => a.decidedAtStart

def ciMayFail (cfg : Config) (c : Commit) : Bool := cfg.view == .codeFault && !c.fixed

def agentEvents (cfg : Config) (s : St) (a : Agent) : List (Event × St) :=
  let writes : List (Event × St) :=
    if a.emitted then [] else
    match a.role with
    | .owner =>
      let push :=
        if mayPush cfg a then
          let (s', t) := tick s
          let c : Commit := { sha := nextSha s', pushedAt := t, src := a.id, ci := .pending,
                              fixed := a.answerAtStart == some .change, verdict := none }
          [(.push a.id, setAgent { s' with commits := s'.commits ++ [c] } { a with emitted := true })]
        else []
      let q :=
        let (s', t) := tick s
        (.question a.id, setAgent { s' with questions := s'.questions ++ [⟨t, a.id⟩], waitAt := some t }
          { a with emitted := true })
      push ++ [q]
    | .verifier =>
      match head? s with
      -- DD: "A verdict is written as a commit status on the SHA that was checked, and is not written once
      -- that SHA is no longer the PR's head"
      | some h =>
        if a.sha == some h.sha then
          let ok := passes cfg a h
          let (s', t) := tick s
          [(.verdict a.id ok, setAgent (setHead s' { h with verdict := some ⟨t, ok, a.id⟩ })
            { a with emitted := true })]
        else []
      | none => []
  let ending : List (Event × St) :=
    if a.ended then [] else
    let (s', t) := tick s
    -- DD: "when the Issue's marker has another start time, it writes nothing and removes nothing"
    let marker := s'.marker.map fun m =>
      if (m.start == a.id || cfg.sw.endAnyMarker) && m.endAt.isNone then
        { m with endAt := some (stamp s' t), endedBy := some a.id }
      else m
    [(.agentEnd a.id, setAgent { s' with marker } { a with ended := true })]
  let dies : List (Event × St) :=
    if a.emitted then [] else [(.agentDies a.id, { s with agents := s.agents.filter (·.id != a.id) })]
  writes ++ ending ++ dies

def sessionEvents (cfg : Config) (s : St) : List (Event × St) :=
  let d := decide cfg s
  match d.action with
  | .startOwner => [(.read d, start cfg s .owner)]
  | .startVerifier => [(.read d, start cfg s .verifier)]
  -- DD: "oe hold writes the reason on the Issue"
  | .hold => let (s', t) := tick s; [(.read d, { s' with waitAt := some t })]
  | _ => []

def ciEvents (cfg : Config) (s : St) : List (Event × St) :=
  s.commits.foldr (init := []) fun c acc =>
    if c.ci != .pending then acc else
    let set (r : Ci) : St := let (s', _) := tick s
      { s' with commits := s'.commits.map fun (d : Commit) => if d.sha == c.sha then { d with ci := r } else d }
    [(Event.ci c.sha true, set .success)] ++
    (if ciMayFail cfg c then [(Event.ci c.sha false, set .failure)] else []) ++ acc

def clockEvents (cfg : Config) (s : St) : List (Event × St) :=
  let marker := match s.marker with
    | some m =>
      if m.endAt.isSome && !m.graceOver then
        let (s', _) := tick s; [(.grace, { s' with marker := some { m with graceOver := true } })]
      else if m.endAt.isNone && !m.expired then
        let (s', _) := tick s; [(.expire, { s' with marker := some { m with expired := true } })]
      else []
    | none => []
  -- The host clock drifts once, ahead of or behind GitHub, and stays there.
  let skew := if cfg.skew && s.skew == 0 then [-1, 1].map fun k => (Event.skewTo k, { s with skew := k })
    else []
  marker ++ skew

/-- design-verification.md: "A person who sees a defect in the code answers that it must change. A person
who sees none asks for a re-run where the Issue accepts one, and otherwise answers that no code changes" -/
def personEvents (cfg : Config) (s : St) : List (Event × St) :=
  let replies :=
    -- DD: "The Issue waits on the person at row 2 until the session records an answer or a re-run request"
    if (decide cfg s).action != .waitPerson then [] else
    let answer (k : Kind) := let (s', t) := tick s
      -- DD: "It may carry a decision, which goes into the decisions section as an answer's does"
      (Event.answer k, { s' with answer := some (t, k), decided := s'.decided || k == .noCode })
    -- With no PR there is no code to see a fault in, so either person asks for the code.
    if (head? s).isNone then [answer .change] else
    match cfg.view with
    | .codeFault => [answer .change]
    | .noFault =>
      if rerunAccepted cfg s then
        let (s', t) := tick s
        [(.rerun, { s' with rerunAt := some t, decided := true })]
      else [answer .noCode]
  -- DD: "Approves and merges the PR"
  let merge := if !s.merged && (headVerdict s).any (·.success) then [(Event.merge, { s with merged := true })]
    else []
  replies ++ merge

/-! ## Keeping the state space finite

Records that no rule can read again are dropped, and identities and times are renumbered by their order,
so two states that differ only in numbering are one state. -/

def prune (s : St) : St :=
  let headSha := (head? s).map (·.sha)
  let markerSha := s.marker.bind (·.sha)
  -- A superseded commit matters only for row 8's cap and the once rule, so one whose check is still
  -- pending is dropped: the model gives CI results only to commits it keeps.
  let keep (c : Commit) := some c.sha == headSha || some c.sha == markerSha ||
    (newer c.pushedAt (answerAt s) && (c.ci == .failure || (verdictOf s c).any (!·.success)))
  -- Row 8's cap reads at most 3 failed commits since the answer, so older ones are dropped.
  let failed := ((s.commits.filter keep).filter fun c =>
    some c.sha != headSha && some c.sha != markerSha && c.ci == .failure).map (·.sha)
  let extra := failed.take (failed.length - 3)
  let commits := (s.commits.filter keep).filter (!extra.contains ·.sha)
  let shas := commits.map (·.sha)
  let agents := s.agents.map fun a => if a.sha.any (!shas.contains ·) then { a with sha := none } else a
  let questions := match s.marker with
    | some m => s.questions.filter (·.time > m.startAt)
    | none => []
  { s with commits, agents, questions }

def rank (xs : List Nat) : Nat → Nat :=
  let sorted := (xs.eraseDups).mergeSort (· ≤ ·)
  fun x => (sorted.idxOf x) + 1

def times (s : St) : List Nat :=
  s.commits.flatMap (fun c => c.pushedAt :: (c.verdict.toList.map (·.time))) ++
  s.marker.toList.flatMap (fun m => m.startAt :: m.endAt.toList) ++
  s.questions.map (·.time) ++ s.waitAt.toList ++ (answerAt s).toList ++ s.rerunAt.toList

def normalize (s : St) : St :=
  let s := prune s
  let ids := s.agents.map (·.id) ++ s.marker.toList.flatMap (fun m => m.start :: m.endedBy.toList) ++
    s.commits.flatMap (fun c => c.src :: c.verdict.toList.map (·.src)) ++ s.questions.map (·.src)
  let id := rank ids
  let sha := rank (s.commits.map (·.sha))
  let ts := times s
  let lows := ((ts.filter (· + 1 < s.now)).eraseDups).mergeSort (· ≤ ·)
  let now := lows.length + 10
  let t (x : Nat) : Nat := if x + 1 < s.now then lows.idxOf x else x + now - s.now
  { s with
    now
    commits := s.commits.map fun c =>
      { c with sha := sha c.sha, pushedAt := t c.pushedAt, src := id c.src,
               verdict := c.verdict.map fun v => { v with time := t v.time, src := id v.src } }
    marker := s.marker.map fun m =>
      { m with start := id m.start, startAt := t m.startAt, sha := m.sha.map sha,
               endAt := m.endAt.map t, endedBy := m.endedBy.map id }
    agents := s.agents.map fun a => { a with id := id a.id, sha := a.sha.map sha }
    questions := s.questions.map fun q => { time := t q.time, src := id q.src }
    waitAt := s.waitAt.map t
    answer := s.answer.map fun (x, k) => (t x, k)
    rerunAt := s.rerunAt.map t }

/-- Every event that can happen next, before renumbering. -/
def rawStep (cfg : Config) (s : St) : List (Event × St) :=
  if s.merged then [] else
  sessionEvents cfg s ++ s.agents.flatMap (agentEvents cfg s) ++ ciEvents cfg s ++ clockEvents cfg s ++
    personEvents cfg s

def step (cfg : Config) (s : St) : List (Event × St) :=
  (rawStep cfg s).map fun (e, t) => (e, normalize t)

def init : St := {}

end OE
