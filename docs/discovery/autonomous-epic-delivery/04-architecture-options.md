# Architecture options

## Criteria

- Continues after the conversation ends
- Adds nothing to the target repository
- Where the model key lives
- Operational burden
- Delay before reacting to a state change

## Candidates

Status Fact. Evaluated against 03.

| Candidate | After session end | Added to target repository | Key location | Main weakness |
|---|---|---|---|---|
| Current orchestration inside a conversation | Stops | None | Local | Cannot meet the done definition |
| Re-run the current skill on each state change | Continues | None | Local | A model reads prose to judge state and merge. A misread merges unapproved changes |
| GitHub-hosted runner per event | Continues | Workflow per repository | Repository secrets | Key on a public repository. Setup per repository |
| Local machine as a GitHub runner | Continues | Workflow per repository | Local | Discouraged on public repositories. Waiting jobs cancel after 24 hours |
| External webhook receiver with a queue | Continues | Webhook setting | Receiver | Needs a receiver and an executor plus loss compensation |
| Scheduled local controller starting an agent per task | While the machine runs | None | Local | Stops while asleep. Minutes of delay |

## Chosen direction

The last candidate.

- Handles several repositories without adding anything to them
- Reuses local credentials, skills, and worktrees
- Puts state judgment and merge eligibility in a deterministic program. Reviewer pass remains a model judgment

| Decision | Status |
|---|---|
| Run locally. Resuming after a stop is enough | Agreed |
| The controller judges state, merge eligibility, and GitHub writes. Models implement, repair, and review | Agreed |
| No labels | Agreed |
| Schedule-driven. No webhooks | Proposed |
| One process per agent per task, never inside the resident agent | Proposed |
| A worktree per task from the latest remote main. Never touch the owner's checkout | Proposed |
| Controller lives in the skills repository | Proposed |

## Accepted weaknesses

- No progress while the machine sleeps. The next run re-reads GitHub and resumes
- Reaction delayed by the schedule interval
- Single machine. No concurrent machines

## Future

If state judgment depends only on GitHub facts, execution can later move to GitHub-hosted runners. Undecided.
