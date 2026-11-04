# orchestrate-epic and oe are the only control plane in this repository

## Context

Two programs define what work is and when it may proceed. A pipeline with two such places reproduces the failure `goal-supervisor.md` names, where the holder of the work also holds its definition and the two disagree.

| Program | Model of work | State | Harness binding | Status |
|---|---|---|---|---|
| Intentline | Outcome, Grant, Evaluator, evidence records | Its own records | One harness's sandbox profiles | Development stopped |
| orchestrate-epic with `oe` | Ticket, claim, verdict | GitHub and host-local records | Replaceable Executor | Shipped and running |

## Decision

orchestrate-epic and `oe` are the only control plane for delivery in this repository. Intentline is a separate project that no skill, agent, script, or Design Doc here references or depends on. An idea from it is adopted only when an observed failure here calls for it, as a change to `oe` or to a skill.

## Rationale

| Alternative | Why it lost |
|---|---|
| Intentline as the control plane, orchestrate-epic as its GitHub delivery adapter | Reopens a stopped codebase, keeps the single-harness binding, discards a shipped loop |
| DeepSeek Harness dsh-superagent as the control plane | Developer preview that states breaking changes, runs with full operating-system access, binds the pipeline to one harness |
| Both programs for different scopes | The scopes overlap exactly. Both decide which Ticket starts next and what counts as done |

| Decisive reason |
|---|
| The Ticket, claim, and verdict model is the one the Tickets already use |
| A second definition of the same work costs more than porting the few intentline ideas with evidence behind them |

## Consequences

- One definition of work, a Ticket under an approved Epic, read from GitHub by every stage.
- The Runner of `development-pipeline.md` is an `oe` program and replaces the skill session that coordinated the loop. Modes, Wait states, and the Board are `oe` records and views. A second program would be a second control plane.
- Intentline's separation of run success, work acceptance, and outcome acceptance is unavailable until a failure shows it is needed. The Mergeable ceiling and a person's merge stand in for it.
- The pipeline runs on the repository owner's token. A verdict can be forged, an Owner's unmarked comment reads as a person's and could answer its own Question, and a Ticket's Holder is a record rather than a separate identity. These remain the accepted risks of `orchestrate-epic.md`.
