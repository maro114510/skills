# orchestrate-epic Design

A concept-level design, not a detailed one. Child Issues and code fill in the details.

## Purpose

Turn an Epic's child Issues into verified PRs in dependency order, with every state derived from GitHub, and leave merging to humans or repository automation.

## Responsibilities

| Part | Responsibility |
|---|---|
| orchestrate-epic | Repeats `oe ready`, starts one fresh agent per next action, at most 3 at once, then `oe wait`; it ends when every child Issue is closed or nothing changes for 4 hours |
| pr-owner | Moves one Issue one step: implements a new Issue with `implement autonomous`, or repairs every signal named in its brief, then pushes and opens or updates the PR, or asks a question and pushes nothing |
| pr-verify | Checks one head SHA against the Issue's acceptance criteria in a detached worktree and records a verdict on that SHA |
| `oe` | The only part that reads the loop's state from GitHub or writes it there: `ready`, `claim`, attempts, questions, briefs, `verdict`, and `wait` |
| Human | Answers questions, reviews, merges, closes Issues, and restarts a parked Issue by deleting its branch |

## Invariants

Each row names the row of the safety-condition table in Epic #403 that it covers.

| # | Invariant | Safety row |
|---|---|---|
| 1 | The AI never merges and never enables auto-merge | Merge grant, expected-SHA merge, reconciliation, freeze, budget, one merge at a time: dropped |
| 2 | An Issue starts only when every blocked-by Issue is closed as completed | Dependencies done before starting |
| 3 | A claim is the creation of `feat/issue-<n>` on origin, which fails when the ref exists | No double claim |
| 4 | A verdict is the commit status `orchestrate-epic/verify` on the SHA checked, and is written only while that SHA is the PR head | Verdict bound to the SHA |
| 5 | A Verifier's brief, built by `oe`, holds only the Issue, the head SHA, and the base | Verifier never sees the worker's report |
| 6 | Every Owner and Verifier is a fresh agent that ends after one step | A fresh agent per step |
| 7 | Owner attempts are counted from GitHub, and the 4th is refused | Retry cap survives restarts |
| 8 | Agents work only in their own worktrees, never in the shared checkout | Never touch the shared checkout |
| 9 | Human input is an unmarked comment or review by OWNER, MEMBER, or COLLABORATOR; every AI write carries the marker; labels mean nothing | No labels or loose words; trusted input only |
| 10 | A failed GitHub read decides nothing: `oe ready` exits non-zero and proposes nothing | A failed read decides nothing |
| 11 | Invoking the skill is consent, and ending the session stops every agent | Entry gate: dropped |
| 12 | Real CI decides; nothing starts while the default-branch head lacks passing checks | Locally reproduced CHECKS_SET: dropped |

The secret-scan row maps to the accepted risks.

## Source of Truth

Every AI write is marked by its first line, `<!-- orchestrate-epic:<kind> -->`, where kind is `claim`, `attempt`, `question`, or `findings`.
A record counts only when it follows the Issue's latest `claim`, or always when no `claim` exists, so deleting the branch starts the Issue over.
Within the session, `oe ready` also excludes Issues whose agent is still running.

The board stops first when the default-branch head:

- Has no checks 10 minutes after it appeared: the session exits with that reason
- Has a pending or failing check, or no checks yet: start nothing and wait

Otherwise a closed child Issue is done, and each open one takes the first matching action.

| # | GitHub shows | Next action |
|---|---|---|
| 1 | After the latest claim, a merged PR, or the branch with only a closed unmerged PR | Wait for a human |
| 2 | No branch, and a blocker is open or closed other than as completed | Blocked; a non-completed blocker waits for a human |
| 3 | No branch, and every blocker closed as completed | Claim, then start an Owner |
| 4 | The latest `question` on the Issue has no trusted Issue comment after it | Wait for the answer |
| 5 | No PR; a conflict; a failing check; a `failure` verdict on the head; or, newer than the latest `attempt`, a trusted answer to the latest `question`, a CHANGES_REQUESTED review, or review-thread comment | Start an Owner, or park at 3 attempts |
| 6 | A pending check, unknown mergeability, or no checks within 10 minutes of the head | Wait for CI |
| 7 | No checks 10 minutes after the head appeared | Park |
| 8 | Every check passes, and the head has no `success` or `failure` verdict | Start a Verifier, or park at 2 `pending` verify statuses on this SHA; `oe` writes `pending` before each Verifier starts |
| 9 | A `success` verdict on the head | Wait for the merge |

`orchestrate-epic/verify` itself never counts as a check.

## Worked Examples

| Case | What happens |
|---|---|
| Normal path | A is ready, `oe claim` creates its branch, and `oe` records attempt 1. The Owner pushes and opens a PR that closes A. CI passes, and a Verifier records `success` on the head. A human merges and A closes. B, blocked by A, becomes ready |
| Lost agent | The Owner ends without a PR, or the session dies. Nothing on GitHub says done, so the next `oe ready` starts attempt 2 on the same branch, and a rerun resumes from the same state |
| Failed verification | The Verifier records `failure` and a `findings` comment. Row 5 starts an Owner with those findings, its push creates a new head without a verdict, and CI and verification run again |
| Failed CI | A check fails on the head, and row 5 starts an Owner to fix it on the same branch |
| Reached cap | After 3 attempts row 5 still matches, so the Issue is parked and its dependents stay blocked. A human fixes it by hand, or deletes the branch to start over |
| Red default branch | A check on the default-branch head fails, so no claim, Owner, or Verifier starts and PRs spend no attempts. Once it passes, the loop continues |

## Accepted Risks

- Verdicts can be forged under the shared token
- A verified PR is not verified again after its base moves
- Workflows changed by the AI run with secrets
- `oe` does not scan for secrets; the commit skill screens each commit
- An unmarked AI write reads as human input
- The session lock is host-local, so a second session on another host is not refused and its agents can work the same branch

## Decisions

| Topic | Decision |
|---|---|
| Blocker closed as not planned or duplicate | The dependent waits for a human |
| Signals that start a repair Owner | Failing checks, a `failure` verdict, merge conflicts, and trusted CHANGES_REQUESTED reviews or review-thread comments newer than the latest attempt. Plain PR comments and bot reviews start nothing |
| Restart after a reached cap | Records count only after the latest `claim`, so deleting the branch resets the cap. The branch is created before the `claim` record, so a lost record over-counts, which parks rather than retries |
| Re-dispatch after an answer | Counts toward the cap of 3, like every Owner dispatch |
| Verifier ends without a verdict | Retried once; 2 `pending` verify statuses on one SHA park the Issue |
| `oe wait` and idle limit | One call waits at most 25 minutes; after 4 hours without change the session ends with a summary |
| Parallel agents | At most 3 Owners and Verifiers together, overridable by argument |
| Worktrees | Each agent's worktree is removed when the agent ends; unpushed work is lost, because only GitHub holds state |
| Verdict findings | A marked `findings` comment on the PR, read by the next Owner |
| Checks not yet registered | 10 minutes of grace before no checks counts as no CI |
| Merged PR on an open Issue | Waits for a human, never claimed again |
