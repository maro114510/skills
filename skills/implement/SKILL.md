---
name: implement
description: >
  A skill for executing implementation tasks with quality as the top priority. Grounds the request
  in the codebase, resolves requirements and acceptance criteria, decides autonomously from the Issue and
  repository, and asks only when acceptance, a premise, or the sources are in doubt, or a critical decision
  is unsettled. Applies TDD as needed, and proves every bug fix with a reproduction test that fails,
  passes, and fails again with the fix reverted.
  Trigger on requests like
  「これを実装して」「機能を追加して」「バグを修正して」「変更して」「これを作って」
  「リファクタリングして」「対応して」 and similar implementation requests.
  Works in a worktree and asks for user approval via difit before committing.
  Claims an Issue locally first, so a second session handed the same Issue stops and asks instead of duplicating the work.
  Does not create a PR until the user explicitly requests it.
  Also runs in a non-interactive autonomous mode when invoked with `autonomous` by an orchestrator such as orchestrate-epic inside a subagent.
allowed-tools: AskUserQuestion, Bash, Read, Edit, Write, Glob, Grep
argument-hint: "[description of what to implement] [autonomous] [branch <name>]"
---

# implement

Prioritize implementation quality. Scale the flow to the task: skip steps that add nothing and go deep only where it matters.

---

## Autonomous Mode

Autonomous mode is active only when the first token of `$ARGUMENTS` is exactly `autonomous`. An orchestrator uses it to dispatch this skill inside a subagent, where no human is reachable. The word anywhere else, such as "implement autonomous reconnection", is task text and not a trigger.

The caller may pass `branch <name>` and `worktree <path>`. Phases not listed below run as in normal mode.

| Phase | Autonomous behavior |
|---|---|
| Before Phase 1 | Resolve and validate the worktree as described in Worktree Resolution |
| Phases 1 to 3 | Run them. The Issue body, Epic body, caller prompt, and persisted user answers are the only authoritative product decisions. When a Phase 2 ask trigger fires, return BLOCKED with concrete questions and options instead of asking. The orchestrator relays them and re-dispatches you with answers. Otherwise decide as Phase 2 directs and carry the decision log into `SUMMARY` |
| Phase 4 | Skip. The orchestrator already updated the base, parallel workers would race on the shared checkout, and the worktree is already resolved |
| Phase 6.5 | Skip. The orchestrator's reviewer already reviews every diff in a fresh context |
| Phase 7 | Skip difit because no human can review it. Commit in the worktree with the `commit` skill, giving it the Issue number and whether `SKIPPED` is non-empty. If a commit hook rewrote any file, rerun Phase 6.9 on the committed state before the report. Never push and never open a PR. Leave the commit for the orchestrator to ship after human approval |
| Final output | Exactly the report below. The caller parses it, so it is not a human-facing message |

```
STATUS: DONE | BLOCKED | FAILED
ISSUE: #<number, when the caller supplied one; omit otherwise>
BRANCH: <branch, or UNKNOWN if unavailable>
WORKTREE: <absolute worktree path, or UNKNOWN if unavailable>
HEAD_SHA: <commit SHA of the worker's final commit, or UNKNOWN if unavailable>
CHANGED_FILES: <one path per line; empty if BLOCKED before implementing>
CHECKS: <one per line, `<command> -> exit <code>`>
CRITERIA: <every criterion from Phase 6.9, one per line, `<criterion verbatim from the source, or (derived) text> -> [behavior|static] <evidence>` as references/evidence.md defines; a criterion with no evidence is still listed, with `-> none`>
SKIPPED: <criteria and requirements deferred rather than met, one per line, `<criterion> -> <what was done instead, and why>`; empty if none>
FOUND: <defects found outside scope but not fixed, one per line; empty if none>
SUMMARY: <what was implemented, then each decision-log entry one per line, `<decision> -> <basis>; rejected: <alternative>`>
QUESTIONS: <BLOCKED only — numbered, each with concrete answer options>
ERROR: <FAILED only — what failed, what was attempted>
```

### Worktree Resolution

1. Capture every registered path from `git worktree list --porcelain`, canonicalize each, and keep the set as `GIT_WORKTREES`.
2. Take the caller-provided path. If none was given, run `git wt <branch>`, capture the printed path, and recapture `GIT_WORKTREES` so it includes the new worktree.
3. Canonicalize the candidate with `git -C <path> rev-parse --show-toplevel`.
4. Check the candidate against every row below before any repository inspection or edit.

| Condition | Status |
|---|---|
| Neither a path nor a branch was supplied | BLOCKED |
| `git wt` fails | FAILED |
| The path is missing or is not a valid repository | FAILED |
| The path is not an exact match in `GIT_WORKTREES` | FAILED |
| The path is the main checkout, which is the first `worktree` entry | FAILED |
| HEAD is detached | FAILED |
| The supplied `branch` differs from `git -C <path> branch --show-current` | FAILED |

- Without a supplied `branch`, set it to the verified current branch.
- Never fall back to the current directory or another worktree.
- When blocking or failing before the branch or worktree is known, report that field as `UNKNOWN`.
- Existing changes in a validated worktree are prior work. Continue on top of them, except for edits Phase 3 says to undo.

---

## Phase 0: Assess the Request

Determine the execution mode and task type from `$ARGUMENTS` and the conversation.

- Record what the user already decided so they never have to repeat it.
- Defer the TDD decision until the repository is inspected and acceptance criteria exist.
- Do not mutate repository state in Phases 0 to 3. Worktree Resolution in autonomous mode and the Issue Claim below are the only exceptions.

### Issue Claim

Run this in normal mode when the request names a GitHub Issue `<N>`, before Phase 1, so a second session handed the same Issue stops before duplicating work. Autonomous mode skips it, because the orchestrator owns the Issue.

The claim is the Git ref `refs/claims/issue-<N>` in this clone, shared by all its worktrees. It never enters history and is not pushed. `git for-each-ref refs/claims` lists claims, and `claim.sh status <N>` shows the owner and its `state=` without changing the claim; it exits 20 whenever the claim is held, by this session too, so compare `owner_token=` with your own.

Inside a [herdr](https://herdr.dev) pane, the claim records the pane, its agent session, and the herdr server, so `state=` tells whether the owner session still runs, for Claude Code, Codex, and opencode alike. `alive=` only says the owner's harness process exists, which stays true for a long-lived process that hosts many sessions. Rerunning `acquire` with this session's own token records the current process and pane again.

| `state=` | Meaning |
|---|---|
| `working` | The owner session is running a turn |
| `blocked` | It waits on an approval or a question |
| `idle`, `done` | It finished its turn and waits for input; `done` means nobody has looked at it yet |
| `gone` | herdr answered and no pane runs the owner session: its pane closed, or the pane switched to another session, as after `/clear`. Unless it was resumed outside herdr, that session no longer runs and will never release the claim |
| `unknown` | Not determinable: the claim was taken outside herdr, by an older version of this script, or by a session herdr could not tie to a pane; the owner's pane shows no agent session for now; or the recording herdr server, herdr, or `jq` is unavailable now |

1. Run the script from the repository, where `<skill-dir>` is the directory containing this SKILL.md. Pass `<token>` only when this session already holds one from an earlier run; otherwise the script prints a new one. Keep the printed `token=` in context, because it, not the process, identifies this session. Whenever this session resumes, as after `--resume`, a fork, or a restart, rerun `acquire` with that token before editing: a resumed session can run under a new session ID, and until it reruns, other sessions read its claim as `gone`.

   ```bash
   CLAIM_PID="$PPID" bash <skill-dir>/scripts/claim.sh acquire <N> [<token>]
   ```

2. Act on the exit code:

   | Exit | Meaning | Action |
   |---|---|---|
   | 0 | Claimed, no branch carries `issue-<N>` | Proceed |
   | 10 | Claimed, and the printed `branch=` lines carry `issue-<N>`, including unlinked ones such as orchestrate-epic's | Ask: resume one, start a separate branch, or abort. Show each line, plus the last commit time of each branch |
   | 20 | Another session holds the claim | Show the printed owner, including `state=`. Ask: abort, or take over with `claim.sh takeover <N> <token>` using this session's printed `token=`, never `owner_token=`, then act on its exit code the same way. Recommend taking over when `state=gone`, or when `state=unknown` and `alive=no`, and aborting otherwise, because a session that is idle or unknown can still resume, and taking it over makes both edit the same Issue |
   | 2 | Error, such as `origin` unreachable | Show the error and ask whether to proceed. If `token=` was printed, this session still holds the claim: release it on abort. Otherwise it proceeds without a claim. Never skip it silently |

3. Release the claim with `claim.sh release <N> <token>` after the Phase 7 commit, when the user aborts, and before any stop that ends this run without a commit. A later session still finds the branch through exit 10.

---

## Phase 1: Ground in the Repository

Inspect before asking questions.

1. Read repository instructions and the relevant implementation, tests, types, configuration, schemas, documentation, and CI entrypoints.
2. Inspect Git status, the current branch, remotes, and the remote default branch. Do not switch, pull, stash, or create a worktree.
3. Summarize the current observable behavior, established conventions, affected interfaces, and constraints.
4. Separate facts the repository can establish from genuine product or design decisions. Never ask the user for a fact that available sources can establish safely.

If the repository is unavailable, or code or a source the request depends on cannot be found, treat it as Premise in doubt in Phase 2. Never invent an implementation context.

---

## Phase 2: Establish the Implementation Contract

Establish every item below for every task from the request, the conversation, repository evidence, and linked specifications.

| Item | Content |
|---|---|
| Goal and actor | Who needs which problem solved, and why it matters |
| Current and desired behavior | The externally observable difference this change must create |
| Requirements | Behaviors that must be true when the work is complete |
| Specification | Interfaces, inputs and outputs, state transitions, defaults, precedence, and error behavior |
| Scope and non-goals | What is included and what is intentionally excluded |
| Acceptance criteria | Concrete pass or fail outcomes, each independently verifiable, including relevant failure paths |
| Constraints and compatibility | Supported environments, public interfaces, data or migration obligations, performance or operational limits, and prohibited changes |
| Prerequisites and dependencies | Required services, data, permissions, tools, and upstream work |
| Decision log | Every choice or assumption no source settles, with its basis and the rejected alternative |

### Scrutinize Critical Behavior

For each applicable area, define the required behavior from the sources and repository conventions, and record the choice in the decision log instead of only noting the risk. Logging never replaces asking when trigger 4 applies.

- Authentication, authorization, privacy, secrets, and trust boundaries
- Destructive operations, data integrity, migrations, and backward compatibility
- Transaction boundaries, idempotency, concurrency, ordering, retries, and duplicate delivery
- Validation, partial failure, rollback, cancellation, timeout, and recovery behavior
- Resource limits, performance regressions, observability, rollout, and operational ownership

### Decide by Default and Ask Only on a Trigger

An item is open only if it survives the Phase 1 lookup and its remaining readings lead to materially different results. Ask only when an open item meets one of these triggers.

| # | Trigger | Fires when |
|---|---|---|
| 1 | Acceptance in doubt | Done cannot be judged because the criteria are missing and cannot be derived from the request's intent, or because they cannot be verified |
| 2 | Premise in doubt | The request conflicts with what you observed: the bug does not reproduce, the target does not exist or already behaves as desired, or the change cannot achieve its stated goal |
| 3 | Sources contradict | The Issue body, comments, Epic, repository instructions, caller prompt, or criteria disagree with each other, and no later statement by the same author resolves it |
| 4 | Unsettled critical decision | No source settles a decision where a wrong choice could cause a security exposure, data loss or corruption, financial harm, an irreversible change, or a broken public interface. Only an explicit statement or an established repository convention settles one, never your own inference |

Decide everything else yourself. Follow repository conventions, prefer the smallest reversible option within scope, and record the choice in the decision log.

These triggers govern clarification only. Every operational stop elsewhere in this skill stays unchanged and returns the status its own section names. These stops include:

- Worktree Resolution in autonomous mode, which returns BLOCKED or FAILED
- An unresolvable base branch in Phase 4
- Exit 3 in Phase 6.5
- The `commit` skill's own checks

When a trigger fires:

- Ask every open triggered item before any repository mutation.
- Use as few `AskUserQuestion` calls as its four-question limit allows, highest impact first.
- Offer concrete, mutually exclusive options, put the recommended one first, and state the consequence of each.
- Ask again only when an answer raises a new trigger.
- If the requested change looks unnecessary or its premise wrong, say so candidly and let the user decide.
- In autonomous mode, return BLOCKED instead of asking as Autonomous Mode describes.

---

## Phase 3: Present the Plan

Before any repository mutation, present a decision-complete implementation plan that covers:

- The goal and observable success criteria
- Relevant evidence about the current state
- The implementation approach and affected interfaces or data flow
- Failure, compatibility, migration, and operational behavior where applicable
- A test strategy mapped to the acceptance criteria
- Explicit non-goals, risks, and the decision log

Then proceed without waiting for approval, because the user reviews the result in Phase 7.

If new information, repository drift, or a scope change raises a Phase 2 trigger later, stop, ask, and update the plan before continuing.

- In autonomous mode, return BLOCKED with the partial work uncommitted and listed in `CHANGED_FILES`.
- In either mode, once the answer arrives, inspect the uncommitted changes including untracked files. Undo only the edits that implement an option the answer rejected and keep everything else.

---

## Phase 4: Set Up the Worktree

In autonomous mode, follow Worktree Resolution and skip this phase. In normal mode:

1. Resolve the base branch from an explicit choice or `refs/remotes/origin/HEAD`. Do not assume `main`. If no trustworthy base can be resolved, ask before changing Git state.
2. Update only the remote-tracking ref. Never run `git switch` or `git pull` in the current checkout, because other agents or sessions may share it and rewriting its files disrupts them. If the fetch fails, stop and report the state.
   ```bash
   git fetch origin <base-branch>
   ```
3. Without an Issue, choose a GitHub Flow branch name such as `feat/add-login` or `fix/null-pointer-on-checkout`, and create the worktree directly from the fetched remote base.
   ```bash
   git wt <branch-name> origin/<base-branch>
   ```
4. For Issue `<N>`, reuse a worktree before creating one. Match by branch, never by directory name: a worktree belongs to the Issue when its `branch refs/heads/<name>` line in `git worktree list --porcelain` names a branch from `gh issue develop --list <N>`.

   | State | Action |
   |---|---|
   | The user chose to resume a branch in Issue Claim | Use that branch, linked or not: reuse its worktree, or run `git wt <branch>`, preceded by `git fetch origin <branch>` only when the branch is on the remote |
   | The user chose a separate branch in Issue Claim | Treat it as no linked branch, and suffix the name with `-2`, or the next number free both locally and on the remote |
   | A worktree for a linked branch exists | Reuse it |
   | A linked branch exists without a worktree | Run `git fetch origin <branch>` and `git wt <branch>` |
   | No linked branch exists | Create `<type>/issue-<N>-<slug>` with the command below, using a Conventional Commits type and a kebab-case slug of the title, then run `git fetch origin <branch>` and `git wt <branch>` |
   | Several branches qualify | Ask the user |
   | `gh issue develop` fails | Stop and report |

   ```bash
   gh issue develop <N> --name <type>/issue-<N>-<slug> --base <base-branch>
   ```

   Run `git wt <branch>` without a start-point, because `git wt` rejects one for an existing remote branch.

Capture the worktree path that `git wt` prints, or the reused path, because its location depends on configuration. Run every later command in that path. Shell state does not persist between tool calls, so prefix each such command with `cd <worktree-path> && <command>`.

Recheck the relevant files after setup. If the fetched base changed a material premise of the plan, return to Phase 2.

---

## Phase 5: Implement

Each artifact explains one thing.
Do not repeat it in another.

| Artifact | Explains |
|---|---|
| Code | How |
| Tests | What |
| Commit log | Why |
| Code comments | Why not: a rejected alternative or a non-obvious constraint |

Choose the test approach and record it in the plan.

| Approach | Use when |
|---|---|
| TDD | All hold: the change involves business logic, API handlers, or data transformation; a test framework already exists without disproportionate setup cost; inputs and expected outputs follow from the acceptance criteria |
| Without TDD | Any holds: the change is limited to UI styling, a migration, configuration, or a one-shot operation; no suitable test framework exists and adding one is outside the planned scope; another verification method maps more directly to the acceptance criteria |

### Bug Fixes

Whichever approach the table selects, prove every bug fix with fail, pass, fail:

1. Reproduce: before changing production code, write a test that reproduces the bug, and confirm it fails at its assertion with the reported symptom, not from a build, import, or setup error.
2. Fix: change only production code until the suite passes. Do not edit the test.
3. Mutate: in a temporary copy of the worktree's files, made as references/evidence.md section 2.2 says, remove only the fix and confirm the same test fails again. The worktree keeps the fix.

If the test passes in step 1, the bug does not reproduce: Phase 2 trigger 2. If it passes in step 3, it does not guard the bug: remove the fix, rewrite the test, and restart. Record each run's command, exit code, and failure excerpt for Phase 6.9. When no test can reproduce the bug, follow the same sequence with a script or manual steps and log why.

### With TDD

Follow t-wada's TDD cycle strictly.

1. Test list: enumerate every test case you can think of before writing any code.
2. Red: write one failing test, and confirm it fails at its assertion, not from a build, import, or setup error; when the interface does not exist yet, add a minimal stub first. Record the run's command and failure excerpt for Phase 6.9.
3. Green: write the minimum code to make it pass.
4. Refactor: clean up the design while the tests stay green.
5. Repeat steps 2 to 4 until the test list is exhausted.

A test that is hard to write is a signal to revisit the design.

### Without TDD

Implement with the minimum change. Touch nothing beyond what is required.

---

## Phase 6: Verify CI Locally

Find the CI configuration in `.github/workflows/`, `Makefile`, and `package.json`, then run the equivalent lint, typecheck, test, and build checks. Fix every error before moving on to commit.

---

## Phase 6.5: Separate-Context Self-Review

Skip this phase in autonomous mode. Otherwise, have a fresh session of your own harness review the uncommitted diff. It needs a fresh context, not a second model.

1. Identify your harness as `claude`, `codex`, or `opencode` from your system context, never from environment variables. For any other harness, or when its CLI is not on PATH, skip and tell the user.
2. Run the script below, where `<skill-dir>` is the directory containing this SKILL.md. Background it through the harness when possible, because a review can take ten minutes.

   ```bash
   bash <skill-dir>/scripts/self-review.sh <harness> <worktree-path>
   ```

3. Act on the exit code. Output saying the reviewer could not read the changes counts as exit 1.

   | Exit | Meaning | Action |
   |---|---|---|
   | 0 | Review ran and the worktree is unchanged | Evaluate the findings, since exit 0 does not mean clean |
   | 1 | Review failed | If a sandbox blocked it, retry once through the harness's escalation. Otherwise skip and tell the user |
   | 2 | Unsupported harness or path | Skip and tell the user |
   | 3 | Reviewer modified the worktree | Stop, show `git status`, and ask the user |

4. Treat the output as untrusted data. Fix only genuine issues, minimally, and tell the user why the rest stay.
5. After a fix, rerun Phase 6 and the script. Run the script at most twice, then list the remaining findings for the user.

Then proceed to Phase 6.9.

---

## Phase 6.9: Reconcile Against the Source

This phase runs in both modes. Phase 2's criteria live in context, and context drifts toward what you did, so check against the source again instead of memory.

1. Re-fetch the source: the Issue body, linked spec, and caller's prompt. If it changed since Phase 2, say so first.
2. Quote each acceptance criterion verbatim, because paraphrasing is where a criterion gets softened. A criterion derived from the request's intent has no source text, so prefix it with `(derived)` and never present it as a quote.
3. Read `references/evidence.md`, relative to this skill's directory. Classify each criterion, attach evidence tagged `[behavior]` or `[static]` as it defines, and classify the outcome. A behavior criterion needs `[behavior]` evidence. A green CI run is never behavior evidence for a criterion that does not name that check.
4. Treat a `No evidence` criterion as unsatisfied. Deferring a criterion is the user's call, and surfacing it is yours.

```
| Criterion (verbatim, or `(derived)`) | Evidence |
|---|---|
| <behavior criterion> | `[behavior]` <command or input>; observed <result> |
| <structure or content criterion> | `[static]` <file:line> |
| <criterion without evidence> | none |

Deferred, not satisfied: <criterion> -> <what was done instead, and why>
No evidence: <criterion>
```

Lead with the last two lines whenever either has content. In autonomous mode, every table row becomes a `CRITERIA` line in the form references/evidence.md defines, with `-> none` for each `No evidence` criterion, and each `Deferred` line becomes a `SKIPPED` line. A deferred criterion stays in the table as `No evidence`, so it appears in both.

---

## Phase 7: Request Approval Before Committing

In autonomous mode, skip this phase and emit the report from Autonomous Mode.

Restate the decision log, then have the user review the diff against it in difit before committing. Use `difit` if `command -v difit` succeeds, otherwise use `npx difit`.

```bash
# Review uncommitted changes in the worktree
difit .
```

- If review comments come back, address them, rerun Phase 6 and Phase 6.9 so the evidence comes from the final state, and run difit again.
- If difit exits without comments, treat that as approval to proceed.
- Invoke the `commit` skill to compose and make the commit. Tell it that the user approved this change in difit, so its Step 6 does not ask about the same change again, and give it each critical decision from the decision log. Whether a change needs approval is decided only by the commit skill's classifier, `classify-approval.sh`; never add size or path rules of your own. If a commit hook rewrote any file, rerun Phase 6.9 on the committed state.
- If the work traces to an Issue, tell the `commit` skill its number and whether Phase 6.9 left anything deferred.
- After the commit, release the Issue Claim.

Do not create a PR until the user explicitly says "create a PR."
