# Discovery: autonomous epic delivery

Record as of 2026-10-14 of the facts and agreements gathered before designing unattended delivery from an Epic to merge. Not a design and not a plan. The later orchestrate-epic rebuild changed the agent identity, auto-merge, and review-class decisions. The current designs are [development-pipeline.md](../../design/development-pipeline.md) and [orchestrate-epic.md](../../design/orchestrate-epic.md).

| Status tag | Meaning |
|---|---|
| Fact | Verified by inspection. No judgment |
| Agreed | Presented as a decision point and agreed by the owner |
| Proposed | Presented, agreement deferred to implementation |
| Deferred | Decision pushed to later work |

| Document | Question it answers |
|---|---|
| [01-problem-and-goal.md](01-problem-and-goal.md) | What hurts and what counts as done |
| [02-findings.md](02-findings.md) | What the existing pieces do and lack |
| [03-external-constraints.md](03-external-constraints.md) | What GitHub and OpenCode force on the design |
| [04-architecture-options.md](04-architecture-options.md) | Which shapes were possible and which was chosen |
| [05-decisions.md](05-decisions.md) | What was agreed per decision point and what remains |

| Assumption | Value |
|---|---|
| Survey date | 2026-10-14 |
| OpenCode version | 1.19.0 |
| Repository specifics | None, except the Issue list at the end of 02 |

| Term | Meaning |
|---|---|
| Epic | Parent Issue whose children are linked by GitHub sub-issues and dependencies |
| Controller | Deterministic program that judges state and writes to GitHub. No model |
| Worker | Model agent that implements, repairs, or drafts an approach |
| Reviewer | Model agent that judges a diff in a fresh session |
| Resident agent | The always-on agent session the owner talks to |
| Agent identity | A GitHub App identity separate from the owner's account |
| Review class | Three-level setting per Issue for how far a person checks |
| Human approval | Approving review by a person with write access. Agent identity does not count |
| Review pass | Reviewer found nothing that blocks a merge. Distinct from human approval |
