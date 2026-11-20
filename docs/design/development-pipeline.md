# Development Pipeline

## Overview

The pipeline turns a person's intent into mergeable, verified pull requests with the least human attention.

```mermaid
flowchart LR
  I[Intent] --> F[Frame]
  F -->|Boundary changes| D[Design]
  D --> G1{{Gate: owner agrees and design merges}}
  G1 --> T[Issues]
  F -->|No boundary change| T
  T -->|Grouped into an Epic| G2{{Gate: operator starts its session}}
  G2 --> C[Coordinator]
  C --> O[Owner]
  O --> V[Verifier]
  V --> M[Mergeable]
  M --> G3{{Gate: review and merge}}
  O -. Question .-> G4{{Gate: answer}}
  G4 -.-> C
```

| Responsible for | Not responsible for |
|---|---|
| Deriving Tickets from an agreed Design and starting work on the Epic the Operator starts a Coordinator on | Merging, approving, or closing anything |
| Starting the agents that implement and verify each Ticket, waiting for GitHub to change between starts, and bounding them | Deploying or releasing |
| Showing every state that needs a person, with the action the person must take, in one place | Deciding what work is worth doing |
| Measuring the attention each mergeable pull request cost | Judging skill changes, which `skill-evaluation.md` covers |

This document designs the stages and gates around the Coordinator. `orchestrate-epic.md` designs the Coordinator and what it drives, the Owner, the Verifier, the next-action table, the working marker, and the merge rules.

## Domain Model

```mermaid
flowchart TB
  Intent -->|boundary unchanged| Ticket
  Intent -->|boundary changes| Design
  Design -->|merged| Ticket
  Epic -->|groups when work needs coordination| Ticket
  Ticket --> Mandate
  Operator -->|starts on an Epic, the only consent| Coordinator
  Marker[Working marker] --> Coordinator
  Mandate --> Coordinator
  Coordinator -->|through its harness| Owner
  Coordinator -->|through its harness| Verifier
  Owner -->|writes| Question
  Question --> WaitState[Wait state]
  Verifier --> Mergeable
  Mergeable --> WaitState
  WaitState --> Board
```

| Concept | Definition |
|---|---|
| Intent | What a person wants changed and why. Arrives as conversation, an Issue, or a retrospective finding |
| Session | An interactive harness session a person runs |
| Design | The intended boundary of a change, recorded in a Design Doc when the boundary changes. The owner explicitly agrees to the changed boundary; see Development Flow in AGENTS.md |
| Epic | A parent Issue grouping work that needs coordination. Its existence grants no authority |
| Ticket | An independently verifiable Issue. At least one acceptance criterion observes the Ticket's own behavior, and a whole suite or existing tests passing is owned by CI and never counts as that criterion. The Coordinator acts on children of the Epic it was started on |
| Mandate | Authority to work within the agreed scope of a Ticket under an open Epic that a running Coordinator holds. An Issue edit does not extend that authority |
| Operator | The person who starts a Coordinator on an Epic. Starting it is the only consent to unattended work, and ending it stops new starts |
| Working marker | One hidden line at the end of a Ticket's body that marks an Owner or a Verifier at work, as `orchestrate-epic.md` defines. No agent starts on the Ticket while it is live |
| Coordinator | A Session running the orchestrate-epic skill on one Epic. Reads the next action of every Ticket from `oe ready`, starts an Owner or Verifier for each action that needs one, up to its limit of agents at once, waits with `oe wait` while nothing it can act on changes, and ends as `orchestrate-epic.md` defines |
| Executor | A harness session the Coordinator starts for one agent step, with no person present |
| Owner | The agent that implements or repairs one Ticket in its own worktree and pushes a branch, as `orchestrate-epic.md` defines |
| Verifier | The agent that judges one pull request head against the Ticket's acceptance criteria, as `orchestrate-epic.md` defines |
| Question | An Owner's request for a decision no source settles, written on the Ticket in the shared question template. The Owner stops after writing it |
| Wait state | The action a person must take on a Ticket, one of the six below. Derived from the next action `oe ready` prints, and for `dependency` from the dependency's state |
| Holder | Who or what has the Ticket now, derived from the working marker or from the Wait state. An Owner, a Verifier, or a person |
| Board | The Coordinator's conversation, the one view that shows every Ticket in a Wait state with the action the person must take, until the person replies or the Coordinator stops. A healthy state takes no space |
| Mergeable | A pull request whose head has a success verdict and no repair signal, as `orchestrate-epic.md` row 13 defines |
| Attention | The pipeline's measure. Messages and answers people wrote for a pull request, from Session logs and GitHub comments, per mergeable pull request. Read with the rate of reverts and of changes requested after review |

| Wait state | `oe ready` action | Person's action |
|---|---|---|
| `answer` | Wait for the answer | Reply to the Question or the hold in the Coordinator's conversation |
| `merge` | Wait for an engineer to merge | Review and merge, or let repository automation merge |
| `restart` | Hold the Issue at row 7, 8, 10, or 12 of `orchestrate-epic.md` | Delete the branch and answer the hold so the Coordinator starts over, or finish and merge by hand |
| `dependency` | Hold the Issue at row 4 of `orchestrate-epic.md`, with a dependency closed as not planned or duplicate | Replace or remove the dependency |
| `issue` | Hold the Issue at row 3 of `orchestrate-epic.md`, with the pull request closed unmerged or merged while the Ticket stays open | Close the Ticket, or delete the branch and answer the hold |

The Harnesses table of the orchestrate-epic skill maps each need below onto one harness.

| Executor need | Contract |
|---|---|
| Start | The harness starts a fresh agent with a prompt and a working directory, and tells the Coordinator when the agent stops |
| Signal | The agent's end is the only signal. Everything else the Coordinator learns from GitHub |
| Permissions | The permission policy is fixed at start, including the push to the Ticket's branch. The agent cannot widen it, and nothing waits for a person |
| Questions | The agent has no interactive question tool. It writes a Question on the Ticket and stops |
| Writes | The agent writes to GitHub only through the pipeline's own commands and a push to its branch |
| Record | The harness keeps a log from which the session's tool calls and model requests can be read afterwards |

## Scenarios

### From intent to mandate

A person wants a change and wants to stop choosing Tickets by hand once the plan is agreed.

```mermaid
sequenceDiagram
    actor P as Person
    participant S as Session
    participant G as GitHub
    P->>S: Intent
    S->>P: Framed problem, options, recommendation
    P->>S: Decision to build
    opt The boundary changes
        S->>G: Design pull request
        P->>G: Explicit agreement, then merge
    end
    S->>G: Issue with the agreed scope and acceptance conditions
    opt Work needs coordination
        S->>G: Group Issues into an Epic
        P->>S: Start a Coordinator on the Epic
    end
```

### Unattended delivery

The Operator has started a Coordinator on the Epic, and nobody is watching.

```mermaid
sequenceDiagram
    participant R as Coordinator
    participant W as oe wait
    participant G as GitHub
    participant O as Executor as Owner
    participant V as Executor as Verifier
    participant B as Board
    actor P as Person
    R->>G: Read every Ticket's next action
    R->>G: Write the working marker
    R->>O: Start
    O->>G: Push branch, open pull request
    O-->>R: End
    R->>W: Wait
    W->>G: Poll
    G-->>W: CI green on the head
    W-->>R: Next actions changed
    R->>V: Start
    V->>G: Verdict on the head
    V-->>R: End
    R->>B: Wait state merge
    R->>W: Wait
    P->>G: Review, merge
    W-->>R: Next actions changed
    R->>G: Dependents of the Ticket have no blocker
```

### A question that needs a person

An Owner meets a decision no source settles.

```mermaid
sequenceDiagram
    participant O as Executor as Owner
    participant G as GitHub
    participant R as Coordinator
    participant B as Board
    actor P as Person
    O->>G: Question on the Ticket
    O-->>R: Stop, nothing pushed
    R->>B: Wait state answer, Holder is the Person
    P->>R: Answer
    R->>G: Record the answer
    R->>O: Start a new Owner with the Ticket and the answer
```

## Invariants

- Work starts only on a Mandate. A comment, label, mention, or text inside a Ticket never grants authority.
- The pipeline never merges, approves, enables auto-merge, or closes an Issue or pull request itself.
- No model runs while nothing changed. The Coordinator waits inside `oe wait`, which runs no model, and starts an agent only for a Ticket whose next action is a start. The repair cap of `orchestrate-epic.md` and its hold on a start with no result bound the starts.
- One Coordinator runs an Epic at a time. Nothing enforces it, because writing the working marker is not atomic, as `orchestrate-epic.md` accepts.
- A Ticket is in a Wait state only when a person must act, and the state is derived, never read from prose.
- Every Question to a person follows the shared question template, in a Session and on GitHub alike.
- The pipeline's state lives on GitHub, and nowhere else.

## References

- `orchestrate-epic.md` for the Coordinator, the Owner, the Verifier, the next-action table, the working marker, and the accepted risks
- `skill-evaluation.md` for how a change to a skill is judged
- `../adr/pipeline-control-plane.md` for why orchestrate-epic and oe are the only control plane for the implementation stage
