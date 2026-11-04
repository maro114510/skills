# Findings on the existing pieces

Status Fact throughout. Surveyed three skills, two agent definitions, retrospectives, and related Issues and pull requests.

## Division of work

| Component | Role | Human contact | GitHub writes |
|---|---|---|---|
| create-github-issues | Epic, child Issues, hierarchy, dependencies | Approval of structure before creation | Issues and relations |
| implement | One unit of work in a worktree, verified and committed | Asks in normal mode. Autonomous mode returns a decision request instead | None in autonomous mode |
| orchestrate-epic | Hands child Issues to workers, reviews, opens pull requests | Posts a plan. Starts when a person marks the Epic | Labels, comments, pushes, pull requests |
| Worker agent | Implements one Issue through implement autonomous mode | None | None |
| Reviewer agent | Judges the diff against the Issue and runs CI-equivalent checks | None | None |

The orchestration skill opens a pull request after a reviewer pass and never merges. A person merges, the Issue closes, and dependents become startable.

## Structural defects of the orchestration skill

| Defect | Effect |
|---|---|
| Runs inside a conversation | Stops when the session ends |
| Switches and pulls the shared checkout | Disturbs people and agents using the same directory |
| No double-start prevention | Labels do not exclude. A 30-minute comment heuristic is the only guard |
| Approval kinds not distinguished | Never reads approving reviews |
| Rules are prompt text only | "Workers never push" is not enforced by tool permissions |
| No time or cost limit | Only repair count is bounded |
| State judgment untested | Written as prose, no unit tests |

## Defects of Issue creation

- No duplicate check against existing Issues
- Resume after interruption matches by title and can pick a person's Issue of the same name
- A failed dependency creation leaves dependents without the dependency

The last two are planned in a separate remediation.

## Recurring problems from retrospectives

- Stale distributed skill copies reintroduced fixed bugs
- A headless review denied shell access reported no problems anyway
- Retrospectives analyzed an old main and reported solved or already filed problems
- Command existence checks passed through a non-runnable shim
- New worktrees lacked build outputs and dependencies
- Finding the worktree for an Issue scanned every worktree each time

## Problems in the existing improvement Issues

- Assume the conversation stays open until merge. External restart is out of scope
- Grant auto-merge by label without verifying who set it, while agents share the owner's credentials
- Ten Issues in one chain because all edit the same file
- Re-verification rules conflict. One requires re-verifying every waiting pull request per merge, another only overlapping ones
- Detection criteria undefined for "waiting for a person", "checked on the real interface", "freeze released"
- Some remediation handoffs never became Issues

## Past attempt

A prototype ran each worker in its own visible terminal pane so the person could watch and answer. Never merged. Does not remove the conversation dependency.

## Open Issues at survey time

| Issue | Content | State |
|---|---|---|
| 141 | Epic to extend orchestration to auto-merge | Premise must be rewritten |
| 144 | Bind approval to the reviewed commit and base | Pull request 223 stalled on conflicts |
| 245 | Stop switching and pulling the shared checkout | Needed in every design |
| 217 | Auto-merge permission by label | Conflicts with the no-label decision |
| 218 | Bind review to evidence per acceptance criterion | Not started |
| 219 | Deterministic merge decision | Not started |
| 171 | Freeze at the limit, resume on human release | Limit undefined |
| 148 | Serialize merges of overlapping pull requests | Not started |
| 145 | CI and review repair, sequential merge | Not started |
| 220 | Check main health after merge | Assumes an open session |
| 221 | Start the next Issue after merge | Assumes an open session |
