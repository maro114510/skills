---
name: implement
description: >
  A skill for executing implementation tasks with quality as the top priority. Grounds the request
  in the codebase, resolves requirements and acceptance criteria, decides autonomously from the Issue and
  repository, and asks only when acceptance, a premise, or the sources are in doubt, or a critical decision
  is unsettled. Writes tests through one playbook per task type, commits each TDD cycle, and proves every
  bug fix with a reproduction test that fails on the pre-fix code.
  Trigger on requests like
  「これを実装して」「機能を追加して」「バグを修正して」「変更して」「これを作って」
  「リファクタリングして」「対応して」 and similar implementation requests.
  In normal mode implements only the first planned change unit per run, listing the rest as deferred.
  Works in a worktree, commits as it goes, and before push self-reviews the whole branch range on the first pass and only the fix delta on a second,
  then asks for user approval via difit over that range when the commit skill's classifier requires it.
  Claims an Issue locally first, so a second session handed the same Issue stops and asks instead of duplicating the work.
  Does not create a PR until the user explicitly requests it.
  Also runs in a non-interactive autonomous mode when invoked with `autonomous` by an orchestrator such as orchestrate-epic inside a subagent.
allowed-tools: AskUserQuestion, Bash, Read, Edit, Write, Glob, Grep
argument-hint: "[description of what to implement] [autonomous] [branch <name>]"
---

# implement

Prioritize implementation quality. Scale the flow to the task: skip steps that add nothing and go deep only where it matters.

The phases below are the core, and both modes run them.
The only difference between the modes is the shell around the core:

| Mode | Shell |
|---|---|
| Normal | Read `references/interactive.md` in full before Phase 1. It holds the Issue Claim, how to ask, Phase 4, Phase 6.5, and Phase 7's approval |
| Autonomous | Never read `references/interactive.md`. Autonomous Mode below holds everything the shell would add |

Relative paths and `<skill-dir>` name this skill's directory, the one containing this SKILL.md.

---

## Autonomous Mode

Autonomous mode is active only when the first token of `$ARGUMENTS` is exactly `autonomous`. An orchestrator uses it to dispatch this skill inside a subagent, where no human is reachable. The word anywhere else, such as "implement autonomous reconnection", is task text and not a trigger.

The caller may pass `branch <name>` and `worktree <path>`. Phases not listed below run as the core describes.

| Phase | Autonomous behavior |
|---|---|
| Before Phase 1 | Resolve and validate the worktree as described in Worktree Resolution. Take no Issue Claim, because the orchestrator owns the Issue |
| Phases 1 to 3 | Run them. The Issue body, Epic body, caller prompt, and persisted user answers are the only authoritative product decisions. When a Phase 2 ask trigger fires, return BLOCKED with concrete questions and options instead of asking. The orchestrator relays them and re-dispatches you with answers. Otherwise decide as Phase 2 directs and carry the decision log into `SUMMARY`. Do not stop at the first unit: Run One Unit does not apply, so implement every unit the plan lists, in order, defer none for being a later unit, and never return BLOCKED over the split |
| Phase 4 | Skip. The orchestrator already updated the base, parallel workers would race on the shared checkout, and the worktree is already resolved |
| Phase 6.5 | Skip. The orchestrator's reviewer already reviews every diff in a fresh context |
| Phase 7 | Skip the approval because no human can review it. Commit in the worktree with the `commit` skill, giving it the Issue number and whether `SKIPPED` is non-empty. If a commit hook rewrote any file, rerun Phase 6.9 on the committed state before the report. Never push and never open a PR. Leave the commit for the orchestrator to ship after human approval |
| Final output | Exactly the report below. The caller parses it, so it is not a human-facing message |

```
STATUS: DONE | BLOCKED | FAILED
ISSUE: #<number, when the caller supplied one; omit otherwise>
BRANCH: <branch, or UNKNOWN if unavailable>
WORKTREE: <absolute worktree path, or UNKNOWN if unavailable>
HEAD_SHA: <commit SHA of the worker's final commit, or UNKNOWN if unavailable>
CHANGED_FILES: <one path per line; empty if BLOCKED before implementing>
CHECKS: <one per line, `<command> -> exit <code>`>
CRITERIA: <every criterion from Phase 6.9, one per line, `<criterion verbatim from the source, or (derived) text> -> [behavior|static] <evidence>` as references/evidence.md defines; a criterion with no evidence is still listed, with `-> none`, and a manual check with `-> manual`>
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
- Existing commits and changes in a validated worktree are prior work. Continue on top of them, except for work Phase 3 says to undo.

---

## Phase 0: Assess the Request

Determine the execution mode and task type from `$ARGUMENTS` and the conversation.

- Record what the user already decided so they never have to repeat it.
- Defer the playbook choice until the repository is inspected and acceptance criteria exist.
- Do not mutate repository state in Phases 0 to 3. The exceptions are Worktree Resolution in autonomous mode and the Issue Claim in normal mode.

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

A manual check, as references/evidence.md section 4 defines, never fires trigger 1.

Decide everything else yourself. Follow repository conventions, prefer the smallest reversible option within scope, and record the choice in the decision log.

These triggers govern clarification only. Every operational stop elsewhere in this skill stays unchanged and returns the status its own section names. These stops include:

- Worktree Resolution in autonomous mode, which returns BLOCKED or FAILED
- The stops that `references/interactive.md` lists for normal mode
- The `commit` skill's own checks

When a trigger fires, raise every open triggered item before any repository mutation:

- Normal mode asks the user, as `references/interactive.md` § Asking describes.
- Autonomous mode returns BLOCKED instead of asking, as Autonomous Mode describes.
- Offer concrete, mutually exclusive options, put the recommended one first, and state the consequence of each.
- Ask again only when an answer raises a new trigger.
- If the requested change looks unnecessary or its premise wrong, say so candidly and let the user decide.

---

## Phase 3: Present the Plan

Before any repository mutation, present a decision-complete implementation plan that covers:

- The goal and observable success criteria
- Relevant evidence about the current state
- The implementation approach and affected interfaces or data flow
- Failure, compatibility, migration, and operational behavior where applicable
- The change units, decided here before any code is written. Read `references/change-units.md` in full first and list the units as it defines
- A test strategy mapped to the acceptance criteria
- Explicit non-goals, risks, and the decision log

Then proceed without waiting for approval, because approval gates the pushed range, not the plan.

If new information, repository drift, or a scope change raises a Phase 2 trigger later, stop, raise it as Phase 2 describes, and update the plan before continuing.

- In autonomous mode, return BLOCKED with the partial work, committed or not, listed in `CHANGED_FILES`.
- In either mode, once the answer arrives, inspect the branch's commits and the uncommitted changes including untracked files. Undo only the work that implements an option the answer rejected, reverting a commit with `git revert`, and keep everything else.

### Run One Unit

Normal mode implements only the first unit of the plan, the first one listed with `depends on: none`, so each unit is reviewed and merged before a dependent one starts and no unit's code is written on top of an unreviewed unit. A change the base branch already contains is done and is not planned again, and a dependency on it counts as `none`, so a later run starts at the next unit. Autonomous mode never splits: it implements every unit in order, as one run. The rules below are for normal mode.

- A unit ends only at a green commit that closes a complete playbook cycle, never between a test commit and the commit that makes it pass. Phase 6 then shows HEAD green.
- Every other unit is deferred. Make no edit for it in this run, and report it as Phase 6.9 describes.
- A deferred unit counts as deferred from the first commit, because the plan already knows it. A non-empty deferred list makes the `commit` skill write `Related #<N>` and not `Closes #<N>`.
- Start the next unit only after the earlier unit is merged and visible in the base, dependent or not. A run picks its unit from the base alone, so a second run begun earlier would pick the same unit again. Use no stack and no `gh-stack`.
- A run that follows a merged unit starts on a new branch from the fetched base, never on the merged unit's branch, so its PR carries only its own unit. Phase 4 in `references/interactive.md` sets this up.

---

## Phase 4: Set Up the Worktree

Autonomous mode skips this phase, because Worktree Resolution already ran.
Normal mode follows `references/interactive.md` § Phase 4.

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

Route each part of the task in the Phase 3 plan. A playbook, relative to this skill's directory, is the only procedure for writing its type's tests.

| Task type | Playbook |
|---|---|
| Adds, changes, or removes behavior a user or caller can observe | `references/playbooks/behavior-change.md` |
| Corrects behavior that differs from what was specified or intended | `references/playbooks/bug-fix.md` |
| Changes structure while observable behavior stays the same | `references/playbooks/refactor.md` |

- A part no row fits follows Tests Not to Write. A task that spans types runs each part through its own playbook, each ending on a green commit.
- A fix made after a green commit, from a later phase or a re-dispatch, is routed the same way. A test changed alone, for behavior the code already has, is a pin under `refactor.md` step 2.

Before the first edit, read `references/test-policy.md` and the routed playbook, and put the playbook's steps verbatim at the top of the todo list. Mark a step you skip `skip: <reason>`.

Commit each step with the `commit` skill, giving it the type the playbook names, because it infers `test:` for a test-only diff, any `Removed-Test` trailer, and, when the work traces to an Issue, its number and whether anything is deferred so far, counting units Run One Unit deferred. Never push.

A test that is hard to write is a signal to revisit the design. Touch nothing beyond what the task requires.

### Tests Not to Write

Write no automated test when any of these holds, record which one in the decision log, and verify each criterion as `references/evidence.md` says.

- test-policy § Prohibitions excludes the code.
- No public interface lets a test observe the change, as with styling, a one-shot operation, or a configuration value no tested code reads.
- No suitable test framework exists, and adding one is outside the planned scope.
- The change is to an agent instruction file, which evidence.md section 2.3 verifies by a fresh-context run.

---

## Phase 6: Verify CI Locally

Find the CI configuration in `.github/workflows/`, `Makefile`, and `package.json`, then run the equivalent lint, typecheck, test, and build checks. Fix every error before moving on to Phase 6.5.

---

## Phase 6.5: Separate-Context Self-Review

Autonomous mode skips this phase.
Normal mode follows `references/interactive.md` § Phase 6.5, then proceeds to Phase 6.9.

---

## Phase 6.9: Reconcile Against the Source

This phase runs in both modes. Phase 2's criteria live in context, and context drifts toward what you did, so check against the source again instead of memory.

1. Re-fetch the source: the Issue body, linked spec, and caller's prompt. If it changed since Phase 2, say so first.
2. Quote each acceptance criterion verbatim, because paraphrasing is where a criterion gets softened. A criterion derived from the request's intent has no source text, so prefix it with `(derived)` and never present it as a quote.
3. Read `references/evidence.md`, relative to this skill's directory. Classify each criterion, attach evidence tagged `[behavior]` or `[static]` as it defines, and classify the outcome. A behavior criterion needs `[behavior]` evidence. A green CI run is never behavior evidence for a criterion that does not name that check.
4. Treat a `No evidence` criterion as unsatisfied. Deferring a criterion is the user's call, and surfacing it is yours. A manual check is never deferred.

```
| Criterion (verbatim, or `(derived)`) | Evidence |
|---|---|
| <behavior criterion> | `[behavior]` <command or input>; observed <result> |
| <structure or content criterion> | `[static]` <file:line> |
| <criterion without evidence> | none |
| <manual check> | manual |

Deferred, not satisfied: <criterion> -> <what was done instead, and why>
No evidence: <criterion>
```

Each unit Run One Unit deferred is one more `Deferred, not satisfied` entry of 5 to 10 lines: the first line names the unit, and its acceptance criteria that no earlier unit satisfies, and the lines under it give the goal, the dependency, the expected files, and the constraints. It uses no new field, and only normal mode writes it, because autonomous mode defers no unit.

```
Deferred, not satisfied: unit <n>, <its one sentence> -> not done in this run: <why it is separate>
  goal: <what the unit achieves>
  depends on: <unit numbers, or none>
  expected files: <paths>
  constraints: <what the next run must keep>
```

Lead with the last two lines whenever either has content. In autonomous mode, every table row becomes a `CRITERIA` line in the form references/evidence.md defines, with `-> none` for each `No evidence` criterion and `-> manual` for each manual check, and each `Deferred` line becomes a `SKIPPED` line. A deferred criterion stays in the table as `No evidence`, so it appears in both.

---

## Phase 7: Finish

Autonomous mode follows its Phase 7 row, then emits the report from Autonomous Mode.
Normal mode follows `references/interactive.md` § Phase 7.

Never push. Do not create a PR until the user explicitly says "create a PR."
