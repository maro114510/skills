# implement

## Overview

implement turns one Request into one Change Unit, committed and verified on its own branch. Every run ends by handing its Result back to the caller and stopping.

| Component | Does | Takes | Returns |
|---|---|---|---|
| Workspace | Works in the worktree the caller hands over. Without one, creates the branch and its worktree; for an Issue, that branch is the Lock | Request, and a worktree when the caller holds one | Worktree, Busy, or Questions |
| Contract | Derives the Implementation Contract from the sources | Request, repository, linked sources | Implementation Contract, or Questions |
| Playbook | Builds the unit test first through the procedure for its task type, and runs the checks the diff can affect | Implementation Contract, worktree | Commits, green, or Questions |
| Self-Review | Reviews a Range in a fresh session: first its scope against the Request alone, then its correctness | Range, Request | Findings, or not run |
| Reconciliation | Re-fetches the source, and settles with Evidence each Acceptance Criterion it now states and each derived one | Range, source, Acceptance Criteria | Outcome and Evidence per criterion |

| Left to others | Who |
|---|---|
| Scope, priority, and design direction no source settles | Whoever answers the Questions |
| Splitting work into Issues of one Change Unit each | Whoever files the Issues |
| Dropping an Acceptance Criterion or moving it to another Issue; implement only drafts the edit | A person, by editing the Issue |
| The worktree and the Lock once a run returns | The caller |
| Pushing, and opening and merging a pull request | The caller |

## Domain Model

| Concept | Definition |
|---|---|
| Request | What the requester asked for, with every answer given to its Questions since. It may trace to an Issue |
| Implementation Contract | The agreed reading of a Request: goal and actor, current and desired behavior, requirements, specification, scope and non-goals, Acceptance Criteria, constraints, prerequisites, and Decisions |
| Acceptance Criterion | A pass or fail outcome, quoted verbatim from the source or marked derived. A behavior criterion names what a user or caller observes; a structure or content criterion names what an artifact contains |
| Outcome | Satisfied, or unsatisfied with its reason, which is no evidence or failure observed |
| Decision | A choice no source settles, with its basis and the rejected alternative |
| Trigger | A condition under which a choice is not the run's to make: Acceptance in doubt, Premise in doubt, Sources contradict, or Unsettled critical decision. Acceptance in doubt includes a criterion that neither a checkout of the repository nor its CI can observe. Premise in doubt includes a Request that needs more than one Change Unit, whose Question asks to split its Issue |
| Question | One open choice in the shared template: its context, criteria, options, and a recommendation |
| Change Unit | One kind of change a reviewer verifies at once, such as a structure change, a behavior change, a bug fix, or a mechanical bulk change. Work needs separate units only by kind, by area, by independence, or by needing a separate revert. About 200 to 400 lines of production code is a guide, not a limit |
| Lock | The Issue's fixed-name branch on origin. Creating it fails when it exists, so one Issue has one branch at a time |
| Range | Every commit from the merge base with the base branch to HEAD |
| Finding | One problem a review reports in a Range |
| Evidence | An observation on the final state that settles one Acceptance Criterion, tagged behavior or static |
| Result | What a run hands back, with the branch and its worktree when they exist on this host. Busy: the Lock exists. Questions: the open choices. Built: the Range, the Outcome and Evidence per criterion, the Findings left, and whether Self-Review ran |

```mermaid
classDiagram
    class Request
    class Contract["Implementation Contract"]
    class Criterion["Acceptance Criterion"]
    class Unit["Change Unit"]
    class Branch
    class PullRequest["Pull Request"]
    class Commit
    class Evidence
    Request "1" -- "1" Contract
    Contract *-- "1..*" Criterion
    Contract *-- "0..*" Decision
    Request "1" -- "1" Unit
    Unit "1" -- "1" Branch
    Unit "1" -- "1" PullRequest
    Unit "1" -- "1..*" Commit
    Criterion "1" -- Evidence : settled by
```

## Scenarios

### Building a unit

A caller wants a request turned into one committed unit without being asked anything the sources settle.

```mermaid
sequenceDiagram
    autonumber
    participant K as Caller
    participant I as implement
    participant WS as Workspace
    participant CT as Contract
    participant PB as Playbook
    K->>I: Request, and a worktree when the caller holds one
    I->>WS: Request, worktree
    WS-->>I: Worktree, Busy, or Questions
    alt Busy
        I-->>K: Busy, with the branch and its worktree
    else Questions
        I-->>K: Questions
    else Worktree
        I->>CT: Request
        CT-->>I: Implementation Contract, or Questions
        alt Questions
            I-->>K: Questions, with the branch and worktree
        else Implementation Contract
            I->>PB: Implementation Contract, worktree
            PB-->>I: Commits, green, or Questions
            Note over I,PB: Questions end the run. Commits, green continues in Checking a unit
        end
    end
```

### Checking a unit

A caller wants the built unit reviewed and settled against the source before anyone relies on it.

```mermaid
sequenceDiagram
    autonumber
    participant K as Caller
    participant I as implement
    participant PB as Playbook
    participant SR as Self-Review
    participant RC as Reconciliation
    Note over I,PB: Continues from Building a unit
    I->>SR: Range, Request
    SR-->>I: Findings, or not run
    opt Findings
        I->>PB: Fix
        PB-->>I: Commits, green, or Questions
        I->>SR: The fix only
        SR-->>I: Findings, or not run
    end
    I->>RC: Range, source, Acceptance Criteria
    RC-->>I: Outcome and Evidence per criterion
    I-->>K: Built, with each unsatisfied criterion
```

## Invariants

- A run behaves the same whoever calls it. Only its inputs decide what it does.
- A run handed a worktree works there and takes no Lock. Otherwise a run for an Issue takes the Lock, and returns Busy when the Lock exists. A run without an Issue starts a new branch from the fetched base.
- A run resumes earlier work only in a worktree handed to it. When the Issue is still open and a pull request from its branch is merged, the run ends with Questions instead of Busy.
- A run works only in its worktree, and never switches, pulls, or stashes the shared checkout.
- Until the Implementation Contract exists with no Question open, a run creates nothing but the Lock and its worktree, and commits nothing.
- One Request is one Change Unit, one branch, and one pull request.
- A fact the repository or another source can establish is never asked.
- Only an explicit statement or an established repository convention settles a critical decision, never inference.
- When a Trigger fires in any component, the run ends with Questions, keeping the work done so far.
- A run that returns Built ends at a green commit.
- Every new or changed test was seen to fail at its assertion before the production change, except a test that pins preserved behavior, which is seen to fail against a deliberate break instead. A bug-fix test fails on the pre-fix code for the reported reason.
- A test is never weakened or deleted to reach green. A deleted test names where its coverage now lives.
- Self-Review is started on every run that returns Built. It never changes the worktree, and one that did not complete is reported as not run, never as clean.
- Self-Review reads only the Range and the Request, and Reconciliation only the Range, the source, and the Acceptance Criteria as written text, never the Decisions, so each can run apart from implement.
- A green check run is never Evidence for a criterion that does not name that check.
- An Acceptance Criterion without Evidence is unsatisfied.
- A Built Result names every unsatisfied Acceptance Criterion with its reason, and the caller passes them on to whoever verifies the change. A Result never reports an unsatisfied criterion as satisfied.

## References

- `orchestrate-epic.md` for pr-owner, which calls implement with a worktree, oe claim, which creates the same branch name, and pr-verify, which applies the same Evidence rules to the Issue's own criteria
- `development-pipeline.md` for where implementation sits in the pipeline
- `skill-evaluation.md` for the paired comparison a change to the skill passes before adoption
