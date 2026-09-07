---
name: orchestrate-epic
description: >
  Orchestrate implementation of a GitHub Epic created by create-github-issues.
  This session acts as the Publisher (run it on a strong model such as Opus): it dispatches ready child Issues to Sonnet worker subagents that run the implement skill in autonomous mode in isolated worktrees, and has an Opus reviewer check every diff (maker/checker).
  A human reviews the Run Plan once and signals go with the `oe:go` label; after that the loop ships review-clean Issues on its own and only surfaces on GitHub — a parked Issue, a frozen Epic, or completion — never through an interactive question.
  A task starts only after every Issue it depends on is merged and closed. All state lives in GitHub (issue state, labels, branches, PRs, comments), so re-running the skill with the same Epic resumes the loop from anywhere.
  Use when the user wants an Epic's child Issues implemented — "Epic を実装して", "この Epic を進めて", "Issue 群を順に実装して", "wave ごとに実装して", "オーケストレーションして".
allowed-tools: Agent, Bash, Read, Glob, Grep
argument-hint: "[epic <number|url>] [repo <owner/repo>] [max-parallel <n>]"
---

# orchestrate-epic

Drive a GitHub Epic from open Issues to merged PRs with a three-role loop:

| Role | Who | Model | Job |
|------|-----|-------|-----|
| Publisher | This session (this skill) | Session model — use a strong model (Opus etc.) | Read GitHub state, schedule ready Issues, ship review-clean work, post every human-relevant fact to GitHub |
| Worker | `skills:issue-implementer` subagent | sonnet (pinned in the agent definition) | Implement one Issue in an isolated worktree via the implement skill's autonomous mode; commits locally and reports `HEAD_SHA`, but never pushes and never opens a PR |
| Reviewer | `skills:issue-reviewer` subagent | opus (pinned in the agent definition) | Review each worker diff against the Issue's requirements and acceptance criteria before it ships |

Plugin agents register under their plugin-scoped name (`skills:<agent>`); if that doesn't resolve, look for the bare names in the available agent types before falling back to a general-purpose agent with the same prompt.

Rules that govern the whole loop:

- **GitHub is the single source of truth.** Issue state, labels, branches, PRs, and comments encode all progress; the loop never depends on conversation memory.
- **The loop asks nothing interactively.** No step blocks on an interactive question. Every human decision is a label the human adds (`oe:go`) or a comment the human leaves on an Issue or the Epic; the loop reads those on its next run.
- **One entry approval, then hands-off.** The human's only up-front gate is Step 3 (Run Plan + `oe:go`). After that, the human is needed again only when an Issue parks, the Epic freezes, or the Epic completes — see the Completion exit comment (Step 9).
- **Nothing ships until Step 6 review-approves it.** Ship (Step 7) runs automatically for every review-clean Issue in the round — there is no separate wave approval step.
- **Workers never talk to the human.** A worker's question becomes a comment on its Issue (Step 5); the Publisher never invents an answer that isn't already written down (Epic body, Issue body, its comments).
- **The Publisher never merges PRs.** A merge is the human's decision and the signal that unblocks dependent Issues.
- **The Publisher never edits code.** All implementation happens inside a worker's worktree; the Publisher's own file access is read-only (Read/Glob/Grep) plus `gh`/`git` bookkeeping through Bash. See the residual-risk note in Edge Cases — this is not tool-enforced.
- **Re-dispatch is always a fresh agent, never a continued one.** See "Always a Fresh Worker" under Step 4.
- **Cost is surfaced, not hidden.** The Run Plan (Step 3) states the bounds and a worst-case dispatch count once; the Completion exit comment (Step 9) reports what actually happened against it.

All user-facing output is Japanese, using the formats in `references/templates.md`.
Shell commands live in `references/commands.md`, split by section — read the section for the step you are on, not the whole file upfront.

---

## Step 1: Resolve Inputs

Parse `$ARGUMENTS`:

- `repo <owner/repo>` — else auto-detect from `git remote get-url origin`; store as `REPO`.
- `epic <number|url>` — else look for an Epic number in the recent conversation (e.g. a create-github-issues completion report); else stop and tell the user to supply one (`epic <number>`) or run create-github-issues first. Do not guess.
- `max-parallel <n>` — concurrent worker cap, default 3. Reject anything that isn't a positive integer (0, negative, non-numeric): fall back to the default and tell the user why.

Confirm `gh auth status` succeeds. If the main checkout is dirty, stop and tell the user — Step 4 needs to update `main`, and silently stashing someone's work is not acceptable.

---

## Step 2: Load State from GitHub

Read the whole board with the three `gh` calls in commands §1 — one for the Epic and its children, one for the open children's labels and `blockedBy` edges, one for every PR on a loop branch. The call count does not grow with the Epic. Never fetch children one at a time, and never pull the Epic or an Issue body into context at this step; §1's projections carry everything Step 2 classifies on.

`blockedBy` is the dependency ground truth; the Epic body's diagram is only the fallback described in §1. Recover branches and worktrees with the local git commands there. For a resumed Issue, read its orchestrate-epic comments only when you are about to dispatch it.

For any Issue carrying `loop:in-progress` with no PR, read its sticky state comment (§2.5) now, as part of classification, not only once dispatch is about to happen — whether it is `in-progress` or `parked` (below) depends on it. No state comment means this is still cycle 0 (the first attempt never finished) and there are no unresolved blockers. A state comment gives the recovered `cycle` count — the fix-cycle cap in Step 6 reads this instead of assuming 0 after a restart — `head_sha`, and `unresolved_blockers`. `head_sha: none` means no commit was recorded yet (the last report was BLOCKED or FAILED before committing) — there is nothing to compare, so resume normally. Otherwise compare `head_sha` against `git -C <worktree> rev-parse HEAD`: a match means the worktree is exactly what GitHub last recorded, so resume normally; a mismatch means the worktree diverged from that record (edited by hand, a different process, a stale local checkout) — stop and tell the user instead of either trusting the worktree's current state as authoritative or silently redoing the work.

Classify every child Issue:

| State | Meaning |
|-------|---------|
| `done` | Issue closed |
| `awaiting-merge` | Open Issue with an open PR — shipped, waiting for the human to merge |
| `rejected` | Open Issue whose PR(s) were all closed **without** merging — the human rejected the work. Never resume silently; escalate (§below) |
| `parked` | `loop:in-progress` label, no PR, and a state comment with non-empty `unresolved_blockers` and no newer human decision (§below) — a fix-cycle cap breach, a secret-screen hit, or a second FAILED result; never auto-resume it |
| `in-progress` | `loop:in-progress` label and/or an existing branch, no PR, and either no state comment or one with empty `unresolved_blockers` — an interrupted run with room to keep going; resume it |
| `ready` | Open, no PR, and every dependency `done` |
| `waiting` | Open with at least one non-`done` dependency |

A `parked` Issue stays out of Step 4's dispatch list on its own — it is a distinct state precisely so a capped or secret-screen-blocked Issue is never silently re-implemented from scratch. It reclassifies to `in-progress` only through the human-decision check below, never by simply reappearing next round.

**Un-parking a `parked` Issue**: every comment this loop itself posts — start, Q&A, blocked-question, parked-findings, secret-screen, failure — starts with `orchestrate-epic` (plain text) or `<!--` (a marker), by convention (§2, §2.5, §1.5). So: check whether the Issue has a comment, posted after the state comment's own timestamp (its `updated_at` from the §2.5 read), whose body does **not** start with either — that is what a human decision looks like, as opposed to this loop's own bookkeeping. If there is none, leave it parked and move on — nothing else touches it this round. If there is one, read it as the human's decision and upsert the state comment's `decisions` field with it, then act on it in this same round:

- **Retry** — reset `cycle` to 0 in the state comment (a human decision restarts the fix-cycle budget) and reclassify as `in-progress` so Step 4 dispatches it fresh this round, with the decision text included in the worker prompt.
- **Redo on a fresh branch** — handle exactly like the merged-PR-but-issue-open sanity check below: a new branch (e.g. `feat/issue-<number>-2`), fresh worktree, `cycle` reset to 0.
- **Drop it** — leave it parked, remove `loop:in-progress` if the human said to abandon it, and report it as failed at Completion (Step 9).

Also read each open child's risk tier: the `risk:low` or `risk:high` label. A child with neither label is treated as `risk:high` — this is a reporting/default rule only; it changes nothing about how the child is scheduled or shipped, it only changes what the Run Plan (Step 3) shows the human before they add `oe:go`.

Sanity checks — none of these block on a question; each names a concrete non-interactive resolution:

- **A dependency cycle among open Issues** → do not compute `ready` for any Issue in the cycle. Post one comment on the Epic naming the cyclic Issues and exit without dispatching (the Epic is effectively frozen until a human edits a `blockedBy` relation or a label); say the same in this session's own output.
- **A merged PR whose Issue is still open** → never re-dispatch onto a merged branch. Post a comment on the Issue describing the situation and the two resolutions (close the Issue, or start a fresh branch such as `feat/issue-<number>-2` for follow-up work); skip dispatching that Issue this round and continue with the rest.
- **`tokens: true`** from §1's first call — a leftover `{{Tn}}` in the Epic body means a child's creation failed during create-github-issues, so a task and its edges may be missing. Fetch the body, show the user which token remains, in this session's own output.
- **A `loop:in-progress` label with no branch anywhere** — stale. Report it in this session's own output; do not silently reset the label yourself.
- **A dispatch comment posted within the last 30 minutes that this session didn't post** — labels are not locks, so another Publisher session may be running this Epic right now. Skip dispatching that Issue this round and report it — two workers in one worktree corrupt each other's diff, so the safe default is not to dispatch, not to ask.
- **Fallback path only: an unparseable Epic dependency section** — post a comment on the Epic saying the dependency section could not be parsed and that `blockedBy`/`subIssues` support (or a corrected body) is needed; exit without dispatching. Never assume independence without that support.

---

## Step 3: Entry Gate — Run Plan and `oe:go`

This is the loop's only up-front human gate. It runs on every invocation, before any worktree is created or any worker is spawned.

1. **Look for the Run Plan comment** on the Epic (§1.5): a comment whose body starts with the marker `<!-- orchestrate-epic:run-plan -->`.
2. **If none exists**: gather the repository facts below, render the "Run Plan" template from Step 2's classification (state, risk tier, blockers, planned base branch per child — base branch is always the repository's default branch, since a `ready` Issue's dependencies are by definition already merged there; there is no branch stacking yet, see #148), post it as the marked comment on the Epic (§1.5), and **exit** — no worktree, no dispatch, nothing past this point runs this invocation.
3. **If a Run Plan comment exists but the Epic lacks the `oe:go` label**: exit, telling the user in this session's own output that the `oe:go` label must be added to the Epic before anything runs.
4. **If both exist**: proceed to Step 4.

### Repository Facts for the Run Plan

Gathered once, from commands §1.5 — these are facts, not derivations; deriving and enforcing a CI-equivalent check set is #143's job, not this step's:

- Branch protection on the default branch, and its required status checks and required-reviewer count (`gh api repos/$REPO/branches/$BASE/protection`; a 404 means no protection configured).
- Workflow files present under `.github/workflows` on the default branch (names only).
- When branch protection has no required checks and no required reviewers: state explicitly that this loop's own reviewer pass (Step 6) is the only merge gate the repository enforces.

### Bounds Block

State, from what is already fixed in this skill: `max-parallel` (from Step 1), the fix-cycle cap (2 reviewer cycles, per Step 6), and a worst-case bound for this round — `N` ready/in-progress children × up to 5 worker attempts each (1 initial + 1 answerable BLOCKED re-dispatch + 1 FAILED retry + 2 reviewer fix cycles, stacked worst case) × up to 3 reviewer passes each (a FAILED retry skips review). This is a worst case, not a prediction — most Issues finish in far fewer. There is no wall-clock or spend kill switch yet (see #171); say so.

---

## Step 4: Dispatch Workers

1. Update the base once, serially: `git switch main && git pull origin main` (workers must not — parallel pulls on the shared checkout race).
2. Create every worktree serially before dispatch: `git wt feat/issue-<number>` per Issue, capturing each printed path (concurrent creation by workers can collide on the shared `.git`). Reuse existing worktrees; deterministic branch names make resumed runs find them.
3. Per Issue: apply the `loop:in-progress` label and leave a start comment (commands §2).
4. Spawn one `skills:issue-implementer` subagent per Issue, **all in a single message** so they run in parallel, then wait.

Dispatch every `in-progress` Issue (resume) first, then `ready` Issues, up to `MAX_PARALLEL`. `parked` Issues are never included — see Step 2's un-parking check. If nothing is dispatchable but Issues are `awaiting-merge` or `waiting`, skip straight to Step 8 — the loop is blocked on merges, not on work. Say in this session's own output what was dispatched and, if `MAX_PARALLEL` left `ready` Issues out, say so — the human can start the next batch immediately by re-running the skill, no merge required.

### Worker Prompt

Pass identifiers, not content. The worker fetches the Issue itself, so the body never has to enter the Publisher's context and be paid for twice.

Each prompt must contain:

- Repo root absolute path, `REPO`, and the Issue number. Add the title only because it is already in hand from §1.
- The instruction to read its own Issue first: `gh issue view <number> --repo <REPO> --json title,body --jq .body`, plus its orchestrate-epic comments when the Issue carries the `loop:in-progress` label, which is where prior user answers live.
- The Epic number, as one line of context. Do not summarize the Epic — a child Issue's own background section is the scope the worker is allowed to act on.
- The branch (`feat/issue-<number>`) and the **already-created worktree path** — the worker works there and creates nothing.
- Any reviewer findings or user answers from the current cycle — the worker has no memory of an earlier cycle, so these must be spelled out in full even on a re-dispatch.
- The instruction: "Follow the `implement` skill preloaded in your context in Autonomous Mode, as if invoked with `autonomous branch feat/issue-<number> worktree <path> <task description>`. If the skill content is missing, read `<orchestrate-epic base dir>/../implement/SKILL.md` and follow its Autonomous Mode section." (Fill the path from this skill's base directory, which the harness states on invocation.)
- The report contract below, noting the final message must be the report and nothing else.

### Always a Fresh Worker

Every re-dispatch — a BLOCKED answer, a FAILED retry, or a REQUEST_CHANGES fix cycle — spawns a brand-new `skills:issue-implementer` subagent in the same worktree. Never continue an existing agent, even one still reachable.

Two things break if a worker is continued instead of respawned: the reviewer's independence relies on the worker not carrying its own prior reasoning forward as unstated context, and a continued agent that later dies or gets lost leaves no trace anywhere, since GitHub only reconstructs what was written down and a live agent's memory is not written down. A fresh respawn re-reading the Issue, its comments, and its state comment (§2.5) is the price paid for both properties, not a regression to work around.

### Worker Report Contract

```
STATUS: DONE | BLOCKED | FAILED
ISSUE: #<number, when the caller supplied one; omit otherwise>
BRANCH: <branch, or UNKNOWN if unavailable>
WORKTREE: <absolute worktree path, or UNKNOWN if unavailable>
HEAD_SHA: <commit SHA of the worker's final commit, or UNKNOWN if unavailable>
CHANGED_FILES: <one path per line; empty if BLOCKED before implementing>
CHECKS: <one per line, `<command> -> exit <code>`>
CRITERIA: <one per line, `<acceptance criterion> -> <test or manual check that covers it>`>
SKIPPED: <requirements judged out of scope, one per line, `<requirement> -> <reason>`; empty if none>
FOUND: <defects found outside scope but not fixed, one per line; empty if none>
SUMMARY: <what was implemented; key decisions and why>
QUESTIONS: <BLOCKED only — numbered, each with concrete answer options>
ERROR: <FAILED only — what failed, what was attempted>
```

---

## Step 5: Triage Worker Reports

- **DONE** → queue for review (Step 6).
- **BLOCKED** → answer only from documented sources (Epic body, Issue body, its comments, this conversation). Post the worker's `QUESTIONS`, and any answer already documented, as one comment on the Issue using the "Blocked Question" template (commands §2) — human answers exist nowhere else, and without the comment a resumed session would re-dispatch the worker blind and get the same questions again. If every question is answerable from documented sources, re-dispatch immediately with the answers (always a fresh agent, see Step 4). If not, **park it**: skip re-dispatching this round, leave the `loop:in-progress` label in place, and continue with the rest of the round — the next invocation's Step 4 will pick it up and the worker will read the comment, including any answer a human has since left there.
- **FAILED** (or a worker that returned nothing) → re-dispatch once with the error context, always a fresh agent. On second failure: comment the failure on the Issue (prefixed `orchestrate-epic:`, per Step 2's un-parking check), upsert the state comment's `unresolved_blockers` with it (so Step 2 classifies it `parked` next run instead of blindly retrying it a third time), drop it from the round, and continue with the rest.

Every re-dispatch here upserts the state comment (§2.5): `cycle` and `head_sha` carried forward unchanged (a BLOCKED or FAILED report has no new fix cycle or commit to record), `decisions` updated only if a human's answer counts as a decision worth recording there.

---

## Step 6: Reviewer Pass (maker/checker)

Per DONE Issue, first run `git -C <worktree> add -N .` — plain diff skips untracked files, and a worker's newly created files must not escape review. Then spawn a `skills:issue-reviewer` subagent (parallel is fine) with the worktree path, `REPO`, the Issue number — the reviewer reads the requirements and acceptance criteria itself, for the same reason the worker does — and the diff command `git -C <worktree> diff $(git -C <worktree> merge-base main HEAD)` — the merge-base baseline catches uncommitted changes, intent-to-add files, and any commits the worker made, without dragging in changes merged to main after a resumed worktree was created.
Workers are expected to commit in the worktree (Autonomous Mode Phase 7), so a commit on the branch is not itself a violation. Check instead whether the branch reached the remote outside this flow: `git -C <worktree> fetch origin "$BRANCH" && git -C <worktree> rev-parse --verify -q origin/"$BRANCH"` succeeding, before Step 7 has pushed anything itself, means the worker (or something else) pushed it — as does an existing PR from Step 2's projection not yet known to this round. That is the actual rule break — still review everything, and flag it in this session's own output before Step 7 touches that Issue.

Reviewer output:

```
VERDICT: APPROVE | REQUEST_CHANGES
FINDINGS: numbered; each has severity (blocking|nit), file:line, defect, concrete failure scenario, fix direction
```

Blocking findings → read the state comment's `cycle` field (§2.5) first, recovered in Step 2 for a resumed Issue rather than assumed to be 0: at 2 already, do not dispatch a third fix cycle — **park the Issue**: post the unresolved findings as a comment on the Issue (prefixed `orchestrate-epic:`, per Step 2's un-parking check), upsert the state comment's `unresolved_blockers` with them (this is what makes Step 2 classify it `parked` on the next run instead of blindly re-implementing it), leave `loop:in-progress` in place, skip Step 7 for it, and continue with the rest of the round. `cycle` counts only these reviewer fix cycles; a BLOCKED answer or FAILED retry in Step 5 never increments it, since the two-fix-cycle cap is specifically about the reviewer loop. Below the cap, re-dispatch a fresh worker with the findings (same worktree, per "Always a Fresh Worker" under Step 4), increment `cycle` by 1 in the state comment, then re-review.
Nits do not block shipping and are not fix cycles; carry them into Step 7's PR body as-is.

After every review — whether it triggers a fix cycle, a park, or an APPROVE — upsert the state comment (§2.5): `head_sha` from the worker's `HEAD_SHA`, `unresolved_blockers` as the reviewer's blocking findings (empty on APPROVE), `decisions` left as-is (nothing in this loop asks a human to decide something recorded there — see Edge Cases on what replaced that).

---

## Step 7: Ship the Round

Every reviewer-APPROVE Issue from this round ships immediately — there is no separate approval step. Per approved Issue, following commands §3:

1. **Secret screen** the diff (same patterns as the commit skill's Step 2). Any hit: exclude the file, post the finding as a comment on the Issue (prefixed `orchestrate-epic:`, per Step 2's un-parking check), upsert the state comment's `unresolved_blockers` with it (so Step 2 classifies it `parked` next run, not `in-progress`), leave `loop:in-progress` in place, **skip sub-steps 2–4 for this Issue entirely** — no commit, no push, no PR — and move on to the next Issue in the round. A suspected secret never ships on autopilot.
2. The worker already committed (its report's `HEAD_SHA`). If the worktree still has uncommitted changes, or `HEAD_SHA` is missing/`UNKNOWN`, or `git -C <worktree> rev-parse HEAD` doesn't match it, stage and commit the remainder yourself with a Conventional Commits message derived from the Issue. Otherwise there is nothing left to commit; proceed to push.
3. Push and create the PR with `gh pr create --head <branch>` — body carries the worker summary, check evidence (`CHECKS`/`CRITERIA`), any reviewer nits, `Closes #<number>`, and the Epic reference.
4. Remove the `loop:in-progress` label.

Ship is the loop's only irreversible stretch, so every sub-step is written to be idempotent (commands §3 checks whether each one already happened). If a sub-step fails mid-way — pushed but the PR creation errored, say — fix the cause and rerun Step 7 for that Issue; already-completed sub-steps are skipped, never repeated.

Report PR URLs with the "Ship Report" template, in this session's own output. One Issue's failure doesn't stop the rest — flag it and continue.

---

## Step 8: Round Boundary — Merges Unblock the Next Round

Render the "Round Boundary" template, in this session's own output: PRs awaiting merge, Issues that unlock when they close, and the two ways to continue — merge now and re-run `/orchestrate-epic epic <number>` (rescan from Step 2), or end here and re-run later; Step 2 rebuilds everything from GitHub.
If `ready` Issues were left out only because of `MAX_PARALLEL`, say so explicitly — the user can start the next batch immediately by re-running, no merge required.

On every rescan, first clean up Issues that are closed with a merged PR (commands §4): remove the worktree, delete the local branch. `git worktree remove` refusing a dirty tree means stop and report it, don't force.

---

## Step 9: Completion

When every child is closed, check the Epic for an existing completion comment (marker `<!-- orchestrate-epic:completion -->`, commands §1.5) — if one is already there, do not post a second one. Otherwise post one **exit comment** on the Epic (commands §1.5) using the "Completion Exit Comment" template, then render the same content in this session's own output:

- Shipped and merged Issues.
- Every recorded assumption — aggregated from each Issue's Q&A comments (Step 5) and `SKIPPED` entries in worker reports.
- Parked or failed Issues, each with the reason it never shipped.
- The six #141 metrics, best-effort from data this run already has (dispatch counts, state-comment `cycle` values, reviewer first-pass verdicts, round timestamps); where a metric depends on work not yet done (CI-failure attribution needs #143's derived check set), say so plainly instead of reporting a number.

The loop never closes the Epic. Closing it is the human's own exit check, stated as such in the exit comment.

---

## Edge Cases and Failure Policy

- **Dirty main checkout** at Step 4 → stop and tell the user; never stash or discard user work.
- **Dependency cycle** → handled in Step 2's sanity checks: an Epic comment naming the cycle, no dispatch.
- **`gh` failures** (rate limit, network, missing relation support) → show the error, retry once, then stop and report it.
- **Same-file overlap inside one round** → allowed; no overlap warning exists in this loop yet (#148 owns it). The later PR may need a rebase after the first merges — say so in the Ship Report when it's visible from the diffs.
- **Human rejects a shipped PR without merging** → Step 2 classifies it `rejected` and escalates per its sanity check; nothing auto-resumes it.
- **A BLOCKED Issue without a documented answer** (Step 5) keeps its worktree, its `loop:in-progress` label, and stays classified `in-progress` — it is cheap and self-correcting to redispatch, since the fresh worker just reads the same comment and blocks again if nothing new was left there.
- **A `parked` Issue** — one capped at 2 fix cycles, holding a secret-screen hit, or FAILED twice — keeps its worktree, its `loop:in-progress` label, and its comment explaining why, but is classified `parked` (Step 2) and is never redispatched on its own; it needs an explicit human decision comment to move again (Step 2's un-parking check).
- **Token budget** — many rounds means many dispatches; the user can lower `max-parallel` or stop between rounds at no cost, since the loop resumes from GitHub state.
- **Worker permission prompts** — worker Bash calls go through the session's permission system, and an un-allowlisted command stalls that worker on an approval prompt mid-parallel-run. Before the first round on a repo, suggest allowlisting its test/build commands (or running with a permission mode that covers them) so workers don't sit waiting.
- **Residual risk — worker invariants are instruction-level.** Workers need broad Bash for builds and tests, so "never commit/push/PR" cannot be tool-enforced. Compensating controls: reviews diff against `main`, Step 7 checks `git log main..HEAD`, Step 2 detects branches/PRs that appeared outside the flow. If a worker pushed or opened a PR on its own, stop and tell the user before anything else ships.
- **Residual risk — the Publisher's own tool boundary is instruction-level too.** This skill's `allowed-tools` omits `Edit`/`Write`, but a session's actual tool access is set by the harness's permission mode, not by this file — the omission is a declared intent, not an enforced guarantee. Compensating control: before Step 7 ships anything, run `git status --short` on the **main** checkout (not a worktree); any output there means files were edited directly on the shared checkout outside a worker's worktree — stop and tell the user, don't ship it.
