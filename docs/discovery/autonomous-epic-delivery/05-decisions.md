# Decision points

Ten points, agreed one at a time. Points 8 to 10 were skipped as not needing agreement yet.

| Point | Status |
|---|---|
| 1 Done and scope | Agreed |
| 2 Where state lives | Agreed, amended at the end |
| 3 Review class | Agreed |
| 4 Dependencies | Agreed |
| 5 Merge conditions | Agreed |
| 6 Stop and notify | Agreed |
| 7 Authority and identity | Agreed |
| 8 Shape | Proposed |
| 9 Existing assets | Deferred |
| 10 Bootstrap order | Proposed |

## Premises fixed before the points

- Agents act under a GitHub App identity, not the owner's
- Approving a pull request is forbidden for every OpenCode agent. Bypass by other means is an accepted residual risk
- Runs on the owner's machine. Resuming after a stop is enough
- A controller judges state and merges. Not a model reading prose
- No money limit
- Notifications go to the resident agent
- No labels. They fall off and mean different things per repository

## 1 Done and scope

See 01.

## 2 Where state lives

| Rule | Reason |
|---|---|
| The only source of truth is what GitHub itself tracks. Issue state and body, linked pull requests, head commit, CI results, reviews, comments | Duplicate state diverges |
| No labels read or written | |
| No system-owned state record. Repair counts and repeated failures are recomputed from history each time. Local cache only | Recomputation gives the same answer after any loss |
| Exceptions. Which Epics run lives in a local config file. Human decisions stay as Issue comments | |
| Issue and pull request are linked by a closing reference in the body and the Issue number in the branch name. A hand-made pull request on the Issue means a person owns it | |

## 3 Review class

| Class | Person sees | Merge condition |
|---|---|---|
| Auto | Nothing | Reviewer pass |
| Approach check | Implementation approach | Approach approved, then reviewer pass |
| Human review | Pull request | Human approval |

| Rule |
|---|
| The creating agent proposes the class in a fixed Issue field. The person confirms it with the Issue |
| Missing or unreadable field means human review |
| Agents may only raise the class, never lower it, and notify the reason |
| A person editing the field is followed in either direction |

| Class | Guideline |
|---|---|
| Auto | No behavior change, or acceptance verifiable by automated tests |
| Approach check | Several reasonable implementations |
| Human review | Permissions, data, public interfaces, irreversible changes, security, or behavior CI cannot verify |

## 4 Dependencies

- Only leaf child Issues are worked
- GitHub dependencies are the source. Epic diagrams are not read
- Start when every dependency is closed as completed. Never stack on an unmerged pull request
- Independent chains run in parallel. Default limit 3, locally configurable

| Anomaly | Handling |
|---|---|
| Dependency closed as not planned | Stop dependents and notify |
| Dependency pull request closed unmerged | Notify and wait. A person rejected it |
| Cycle | Start none of the involved Issues and notify |
| Dependency outside the Epic | Wait for it to close. Never touch it |

## 5 Merge conditions

| Condition |
|---|
| The class's pass is met. Human approval counts only from a person with write access |
| No open change request from a person, in any class |
| CI green with the latest main merged into the pull request |
| Approval and reviewer pass stay valid while the pull request's own diff is unchanged |

| Merge rule |
|---|
| One at a time per repository |
| Merge only the verified commit. Abort if anyone pushed since |
| GitHub auto-merge is not used. Merge method follows the repository |
| Never bypass protection. Wait and notify |
| A red main after a merge stops new starts and merges in that repository until main is green |
| A repository with no CI treats every class as human review |

## 6 Stop and notify

| Stop one Issue when |
|---|
| The same check fails for the same reason twice in a row after a repair |
| Blocking findings do not decrease twice in a row |
| Agent crash or timeout twice on the same task. Default per-task timeout 60 minutes |
| The agent returns a question |

| Rule |
|---|
| Stopping posts the reason on the Issue |
| An owner comment resumes it and is passed as the next instruction. Counting restarts after that comment |
| Closing the Issue ends it |

| Notify on |
|---|
| Approach check waiting, review waiting, stop, class raised, main CI failed or recovered, protection unmet, Epic complete |

The record is a GitHub comment mentioning the owner, mirrored to the resident agent. No duplicate notification for an identical existing comment.

## 7 Authority and identity

| Rule | Reason |
|---|---|
| Only text by write-access people and the agent identity reaches agents | Anyone can comment on public repositories |
| Repositories without an agent identity are out of scope | Under the owner's name, system and owner comments are indistinguishable, and the owner cannot approve their own pull request |

## 8 Shape

Status Proposed.

- A scheduled local controller runs every few minutes. No webhooks. One controller at a time. No agent starts when nothing changed
- One process per agent per task, never inside the resident agent. Review in a fresh session
- A worktree per Issue from the latest remote main
- Controller in the skills repository, excluded from the distributed skills

## 9 Existing assets

Status Deferred. Candidate handling.

- Retire the orchestration skill after the new mechanism works
- Rewrite the Epic and children to the agreed points. Close those assuming labels or an open session
- Skill changes such as the class field become children of the rewritten Epic

## 10 Bootstrap order

Status Proposed.

- A person prepares only the agent identity
- Hand-build the minimum. One Issue to a pull request with review notification. No merge or repair loop
- The mechanism implements the rest from the rewritten Epic
- Until auto-merge exists, everything is human review
- No version pinning. Merged changes take effect when the owner reinstalls

## Amendment to point 2

Status Agreed. Class raises and stop-and-resume depend on comments the system wrote. Comments posted by the agent identity count as GitHub facts. No other record or marker is added.

## Open

- Adoption of points 8 and 10
- Which Issues to close under point 9
- The retrospective-to-Issue flow, in a later Epic
