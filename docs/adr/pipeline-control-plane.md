# orchestrate-epic and oe are the only control plane in this repository

## Context

Two programs define what work is and when it may proceed. Intentline, a separate Go project, holds Outcomes, Grants, an Evaluator, and evidence records and runs its agents through one harness's sandbox profiles; it has stopped developing. orchestrate-epic with its `oe` scripts holds its state on GitHub and in host-local records and has shipped and run. The development pipeline needs one place that defines a unit of work and decides what starts next, because two such places reproduce the failure `goal-supervisor.md` names: the holder of the work also holds its definition, and the two disagree.

## Decision

orchestrate-epic and `oe` are the only control plane for delivery in this repository. Intentline is a separate project: no skill, agent, script, or Design Doc here references it or depends on it. An idea from it is adopted only when an observed failure here calls for it, and then as a change to `oe` or to a skill.

## Rationale

- `oe` is live, and its model of a Ticket, a claim, and a verdict with GitHub as the source of truth is the model the Tickets already use. Intentline's Outcome and Grant would be a second definition of the same work.
- Intentline's runtime is bound to one harness's sandbox, while the pipeline treats the harness as a replaceable Executor.
- Reviving a stopped codebase to replace a shipped one costs more than porting the ideas that have evidence behind them.

Alternatives considered:

- Intentline as the control plane, with orchestrate-epic reduced to a GitHub delivery adapter. It reopens a stopped codebase, keeps the single-harness binding, and discards a shipped loop.
- DeepSeek Harness's dsh-superagent as the control plane, with its Router and Workers, Tickets with Mandates, and `observe` mode. It is a developer preview that states breaking changes and runs with full operating-system access, and it binds the pipeline to one harness.
- Both programs for different scopes. The scopes overlap exactly: both decide which Ticket starts next and what counts as done.

## Consequences

- One definition of work, a Ticket under an approved Epic, read from GitHub by every stage.
- Whatever coordinates delivery in this repository, the Runner, the Modes, the Wait states, and the Board of `development-pipeline.md` included, belongs to `oe`; a second program would be a second control plane.
- Intentline's separation of run success, work acceptance, and outcome acceptance is not available until a failure shows it is needed. The pipeline's ceiling of Mergeable and a person's merge stand in for it.
- The pipeline runs on the repository owner's token, so a verdict can be forged, an Owner's unmarked comment reads as a person's and could answer its own Question, and a Ticket's Holder is a record rather than a separate identity. These stay the accepted risks of `orchestrate-epic.md`.
