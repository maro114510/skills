---
name: orchestrate-epic
description: >
  Orchestrate implementation of a GitHub Epic created by create-github-issues.
  This session acts as the Publisher (run it on a strong model such as Opus): it dispatches ready child Issues to Sonnet worker subagents that run the implement skill in autonomous mode in isolated worktrees, has an Opus reviewer check every diff (maker/checker), and gates all commit/push/PR creation on one explicit human approval per wave.
  A task starts only after every Issue it depends on is merged and closed. All state lives in GitHub (issue state, labels, branches, PRs), so re-running the skill with the same Epic resumes the loop from anywhere.
  Use when the user wants an Epic's child Issues implemented — "Epic を実装して", "この Epic を進めて", "Issue 群を順に実装して", "wave ごとに実装して", "オーケストレーションして".
allowed-tools: AskUserQuestion, Agent, Bash, Read, Glob, Grep
argument-hint: "[epic <number|url>] [repo <owner/repo>] [max-parallel <n>]"
---

# orchestrate-epic

Drive a GitHub Epic from open Issues to merged PRs with a three-role loop:

| Role | Who | Model | Job |
|------|-----|-------|-----|
| Publisher | This session (this skill) | Session model — use a strong model (Opus etc.) | Read GitHub state, schedule ready Issues, relay questions, gate every commit/push/PR on human approval |
| Worker | `skills:issue-implementer` subagent | sonnet (pinned in the agent definition) | Implement one Issue in an isolated worktree via the implement skill's autonomous mode; never commit |
| Reviewer | `skills:issue-reviewer` subagent | opus (pinned in the agent definition) | Review each worker diff against the Issue's requirements and acceptance criteria before a human sees it |

Plugin agents register under their plugin-scoped name (`skills:<agent>`); if that doesn't resolve, look for the bare names in the available agent types before falling back to a general-purpose agent with the same prompt.

Rules that govern the whole loop:

- **GitHub is the single source of truth.** Issue state, labels, branches, and PRs encode all progress; the loop never depends on conversation memory.
- **Nothing is committed, pushed, or turned into a PR without the explicit wave approval in Step 7.** No configuration skips this gate.
- **Workers never talk to the human.** Questions flow worker → Publisher → human. The Publisher answers a worker's question itself only when the answer is already written down (Epic body, Issue body, or this conversation) — it never invents one.
- **The Publisher never merges PRs.** A merge is the human's decision and the signal that unblocks dependent Issues.
- **Cost is surfaced, not hidden.** Each round spawns up to `MAX_PARALLEL` Sonnet workers plus one Opus review per completed Issue; say so in the round plan.

All user-facing output is Japanese, using the formats in `references/templates.md`.
Shell commands live in `references/commands.md`, split by section — read the section for the step you are on, not the whole file upfront.

---

## Step 1: Resolve Inputs

Parse `$ARGUMENTS`:

- `repo <owner/repo>` — else auto-detect from `git remote get-url origin`; store as `REPO`.
- `epic <number|url>` — else look for an Epic number in the recent conversation (e.g. a create-github-issues completion report); else ask via AskUserQuestion whether to specify one or run create-github-issues first.
- `max-parallel <n>` — concurrent worker cap, default 3. Reject anything that isn't a positive integer (0, negative, non-numeric): fall back to the default and tell the user why.

Confirm `gh auth status` succeeds. If the main checkout is dirty, stop and tell the user — Step 4 needs to update `main`, and silently stashing someone's work is not acceptable.

---

## Step 2: Load State from GitHub

Using commands §1: fetch the Epic and its children via the native `subIssues` JSON field, each open child's `blockedBy` relations (the dependency ground truth; the Epic body's diagram is only the fallback described there), and each child's prior progress — a `feat/issue-<number>` branch, the `loop:in-progress` label, any PR, and for resumed Issues the orchestrate-epic comments carrying prior Q&A.

Classify every child Issue:

| State | Meaning |
|-------|---------|
| `done` | Issue closed |
| `awaiting-merge` | Open Issue with an open PR — shipped, waiting for the human to merge |
| `rejected` | Open Issue whose PR(s) were all closed **without** merging — the human rejected the work. Never resume silently; escalate (reopen the PR? redo on a fresh branch? close the Issue?) |
| `in-progress` | `loop:in-progress` label and/or an existing branch, and no PR of any state — an interrupted run; resume it |
| `ready` | Open, no PR, and every dependency `done` |
| `waiting` | Open with at least one non-`done` dependency |

Sanity checks — escalate instead of guessing:

- A dependency cycle among open Issues.
- A **merged** PR whose Issue is still open — never re-dispatch onto a merged branch; ask whether to close the Issue or start a fresh branch (e.g. `feat/issue-<number>-2`) for follow-up work.
- Leftover `{{Tn}}` tokens in the Epic body — a child's creation failed during create-github-issues, so a task and its edges may be missing.
- A `loop:in-progress` label with no branch anywhere — stale; propose resetting to `ready`.
- A dispatch comment posted within the last 30 minutes that this session didn't post — labels are not locks, so another Publisher session may be running this Epic right now; confirm with the user before dispatching the same Issue (two workers in one worktree corrupt each other's diff).
- Fallback path only: an unparseable Epic dependency section (offer to treat all open children as independent, only with explicit consent).

---

## Step 3: Present the Round Plan

Render the "Round Plan" template: every child with its state, what gets dispatched this round (`in-progress` resumes first, then `ready`, up to `MAX_PARALLEL`), and the cost note.
Confirm via AskUserQuestion (開始 / 調整 / 中止) before dispatching anything.

If nothing is dispatchable but Issues are `awaiting-merge` or `waiting`, skip to Step 9 — the loop is blocked on merges, not on work.

---

## Step 4: Dispatch Workers

1. Update the base once, serially: `git switch main && git pull origin main` (workers must not — parallel pulls on the shared checkout race).
2. Create every worktree serially before dispatch: `git wt feat/issue-<number>` per Issue, capturing each printed path (concurrent creation by workers can collide on the shared `.git`). Reuse existing worktrees; deterministic branch names make resumed runs find them.
3. Per Issue: apply the `loop:in-progress` label and leave a start comment (commands §2).
4. Spawn one `skills:issue-implementer` subagent per Issue, **all in a single message** so they run in parallel, then wait.

### Worker Prompt

Each prompt must contain:

- Repo root absolute path, `REPO`, Issue number and title.
- The full Issue body plus a 2–3 line Epic summary.
- The branch (`feat/issue-<number>`) and the **already-created worktree path** — the worker works there and creates nothing.
- Any user answers (also persisted as Issue comments — on resume, recover them from there) or reviewer findings from the current cycle. Reviewer findings need no persistence: a resumed run re-derives them by re-reviewing in Step 6.
- The instruction: "Follow the `implement` skill preloaded in your context in Autonomous Mode, as if invoked with `autonomous branch feat/issue-<number> worktree <path> <task description>`. If the skill content is missing, read `<orchestrate-epic base dir>/../implement/SKILL.md` and follow its Autonomous Mode section." (Fill the path from this skill's base directory, which the harness states on invocation.)
- The report contract below, noting the final message must be the report and nothing else.

### Worker Report Contract

```
STATUS: DONE | BLOCKED | FAILED
ISSUE: #<number>
BRANCH: <branch>
WORKTREE: <absolute path>
CHANGED_FILES: <one per line; empty if BLOCKED before implementing>
TESTS: <checks run and results>
SUMMARY: <what was implemented; key decisions and why>
QUESTIONS: <BLOCKED only — numbered, each with concrete options>
ERROR: <FAILED only>
```

---

## Step 5: Triage Worker Reports

- **DONE** → queue for review (Step 6).
- **BLOCKED** → answer only from documented sources (Epic body, Issue body, its comments, this conversation); batch everything else from all blocked workers into one AskUserQuestion call (up to 4, highest impact first, rest in a follow-up call) using the "Blocked Questions" template. **Post each question and its answer as a comment on the Issue** (commands §2) — human answers exist nowhere else, and without the comment a resumed session would re-dispatch the worker blind and get the same questions again. Then re-dispatch with the answers — same Issue, same worktree.
- **FAILED** (or a worker that returned nothing) → re-dispatch once with the error context. On second failure: comment the failure on the Issue, drop it from the round, report at the wave gate, continue with the rest.

---

## Step 6: Reviewer Pass (maker/checker)

Per DONE Issue, first run `git -C <worktree> add -N .` — plain diff skips untracked files, and a worker's newly created files must not escape review. Then spawn a `skills:issue-reviewer` subagent (parallel is fine) with the worktree path, the Issue's requirements and acceptance criteria, and the diff command `git -C <worktree> diff $(git -C <worktree> merge-base main HEAD)` — the merge-base baseline catches uncommitted changes, intent-to-add files, and any commits a worker made despite instructions, without dragging in changes merged to main after a resumed worktree was created.
If `git -C <worktree> log main..HEAD` shows commits, the worker broke its no-commit rule: still review everything, and flag the violation at the wave gate.

Reviewer output:

```
VERDICT: APPROVE | REQUEST_CHANGES
FINDINGS: numbered; each has severity (blocking|nit), file:line, defect, concrete failure scenario, fix direction
```

Blocking findings → re-dispatch the worker with them (same worktree), then re-review. Cap 2 fix cycles per Issue; unresolved blockers go to the wave gate for the human to decide.
Nits become gate-summary notes, not fix cycles.

---

## Step 7: Wave Gate — Human Review and the One Approval

When every dispatched Issue is review-clean or explicitly parked, render the "Wave Gate" template: per Issue — branch, worktree, changed files, tests, reviewer verdict — plus a **file-overlap warning** for any file touched by two or more branches this wave, or by a branch this wave and an `awaiting-merge` PR from an earlier one, with a recommended merge order.

Offer a difit walkthrough per worktree: `cd <worktree> && difit .` (fall back to `npx difit`). difit comments are fix requests: route to the worker (Step 4), re-review (Step 6), return here.

Then ask the explicit approval via AskUserQuestion per the "Wave Approval" template: commit + push + PR creation for the listed Issues as one batch. Options: 一括承認 / 一部のみ承認 / 中断.
**This question alone authorizes Step 8. Never treat difit exiting cleanly as this approval.**

---

## Step 8: Ship the Wave

Per approved Issue, following commands §3:

1. **Secret screen** the diff (same patterns as the commit skill's Step 2). Any hit: exclude the file, tell the user what and why, ask — and stage the remainder via explicit paths, never `add -A`, so a flagged file cannot ride along. A suspected secret never ships on autopilot.
2. Stage and commit in the worktree with a Conventional Commits message derived from the Issue.
3. Push and create the PR with `gh pr create --head <branch>` — body carries the worker summary, test evidence, `Closes #<number>`, and the Epic reference.
4. Remove the `loop:in-progress` label.

Ship is the loop's only irreversible stretch, so every sub-step is written to be idempotent (commands §3 checks whether each one already happened). If a sub-step fails mid-way — pushed but the PR creation errored, say — fix the cause and rerun Step 8 for that Issue; already-completed sub-steps are skipped, never repeated.

Report PR URLs with the "Ship Report" template. One Issue's failure doesn't stop the rest — flag it and continue.

---

## Step 9: Wave Boundary — Merges Unblock the Next Round

Render the "Wave Boundary" template: PRs awaiting merge, Issues that unlock when they close, and the two ways to continue — merge now and say continue (rescan from Step 2), or end here and re-run `/orchestrate-epic epic <number>` later; Step 2 rebuilds everything from GitHub.
If `ready` Issues were left out only because of `MAX_PARALLEL`, say so explicitly — the user can start the next batch immediately with "続けて", no merge required.

On every rescan, first clean up Issues that are closed with a merged PR (commands §4): remove the worktree, delete the local branch. `git worktree remove` refusing a dirty tree means ask, not force.

---

## Step 10: Completion

When every child is closed: render the "Completion Report" template — shipped, merged, skipped/failed.
Ask whether to close the Epic; never close it automatically.

---

## Edge Cases and Failure Policy

- **Dirty main checkout** at Step 4 → stop and ask; never stash or discard user work.
- **Dependency cycle** → AskUserQuestion with the cycle spelled out; never break it silently.
- **`gh` failures** (rate limit, network, missing relation support) → show the error, retry once, then ask.
- **Same-file overlap inside one wave** → allowed, but surfaced at the gate with a merge order; the later PR likely needs a rebase after the first merges.
- **Human rejects the wave** → collect per-Issue directions, route through Steps 4/6, return to the gate. Rejection without direction parks the wave; nothing ships.
- **Partial approval** → ship the approved subset; parked Issues keep their worktrees and labels and reappear as `in-progress`.
- **Token budget** — many waves means many rounds; the user can lower `max-parallel` or stop between waves at no cost, since the loop resumes from GitHub state.
- **Worker permission prompts** — worker Bash calls go through the session's permission system, and an un-allowlisted command stalls that worker on an approval prompt mid-parallel-run. Before the first round on a repo, suggest allowlisting its test/build commands (or running with a permission mode that covers them) so workers don't sit waiting.
- **Residual risk — worker invariants are instruction-level.** Workers need broad Bash for builds and tests, so "never commit/push/PR" cannot be tool-enforced. Compensating controls: reviews diff against `main`, Step 8 checks `git log main..HEAD`, Step 2 detects branches/PRs that appeared outside the flow. If a worker pushed or opened a PR on its own, stop and tell the user before anything else ships.
