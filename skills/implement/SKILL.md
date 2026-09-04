---
name: implement
description: >
  A skill for executing implementation tasks with quality as the top priority. Grounds the request in the codebase, resolves requirements and acceptance criteria, obtains approval for an implementation plan, and applies TDD and Why validation as needed.
  Works in a worktree, asks for user approval before committing, and opens a difit review only if explicitly requested.
  Does not create a PR until the user explicitly requests it.
  Also runs in a non-interactive autonomous mode when invoked with `autonomous` by an orchestrator (e.g. orchestrate-epic) inside a subagent.
allowed-tools: AskUserQuestion, Bash, Read, Edit, Write, Glob, Grep
argument-hint: "[description of what to implement] [autonomous] [branch <name>]"
---

# implement

Prioritize implementation quality while auto-adjusting the flow based on task characteristics.
Skip unnecessary steps; go deep only where it matters.

---

## Autonomous Mode

Activated **only when the first token of `$ARGUMENTS` is exactly `autonomous`** — used when an orchestrator dispatches this skill inside a subagent, where no human is reachable.
The word appearing anywhere else (e.g. "implement autonomous reconnection") is task text, not a trigger.
The caller may pass `branch <name>` and `worktree <path>`. Everything not listed below runs as in the normal flow:

- **Before Phase 1**, resolve and validate the worktree. Capture and canonicalize every registered path from
  `git worktree list --porcelain` as `GIT_WORKTREES`. Use the caller-provided path; if none was given, run
  `git wt <branch>` and capture its printed path. After `git wt` succeeds, recapture and canonicalize
  `git worktree list --porcelain` as `GIT_WORKTREES` so the newly created worktree is included. If neither
  value is available, return BLOCKED. If worktree creation fails, return FAILED. Canonicalize the candidate
  with `git -C <path> rev-parse --show-toplevel`,
  then require an exact match in `GIT_WORKTREES`, reject the main checkout (the first `worktree` entry), and
  require a non-detached current branch. When `branch` was supplied, require it to equal
  `git -C <path> branch --show-current`; otherwise set `branch` to that verified value. A missing path, invalid
  repository, unregistered path, main checkout, detached HEAD, or branch mismatch must return FAILED before
  any repository inspection or edit. Never fall back to the current directory or another worktree. When
  blocking or failing before either value exists, emit `UNKNOWN` for its report field. Existing changes in a
  validated worktree are prior work — continue on top of them.
- **Phases 1–2 still run.** Inspect the resolved worktree and treat the Issue body, Epic body, caller prompt, and persisted user answers as the only authoritative product decisions. Do not run an interactive Why check. If a missing Why, requirement, acceptance criterion, constraint, or critical behavior could materially change the implementation, return a BLOCKED report with concrete questions and options. Never guess — the orchestrator relays questions and re-dispatches you with answers.
- **Phase 3**: build the implementation plan, but skip interactive approval only when every material decision is already supported by those authoritative sources. If the plan would introduce an unsupported product or technical decision, return BLOCKED instead.
- **Phase 4**: skip it — the orchestrator already updated the base, and parallel workers would race on the shared checkout. The worktree was resolved before Phase 1.
- **Phase 7 never runs** — no difit, no commit. Leave changes uncommitted; the orchestrator ships them after human approval.
- **Final output**: exactly this report — it is the return value the caller parses, not a human-facing message:

```
STATUS: DONE | BLOCKED | FAILED
ISSUE: #<number, when the caller supplied one; omit otherwise>
BRANCH: <branch, or UNKNOWN if unavailable>
WORKTREE: <absolute worktree path, or UNKNOWN if unavailable>
CHANGED_FILES: <one path per line; empty if BLOCKED before implementing>
TESTS: <checks run and their results>
SUMMARY: <what was implemented; key decisions and why>
QUESTIONS: <BLOCKED only — numbered, each with concrete answer options>
ERROR: <FAILED only — what failed, what was attempted>
```

---

## Phase 0: Assess the Request

Determine the execution mode and task type from `$ARGUMENTS` and conversation context. Record what the
user has already decided; do not make them repeat it. Defer the TDD decision until after inspecting the
repository and defining acceptance criteria.

In normal mode, do not mutate repository state in Phases 0–3. Autonomous mode has only the worktree-resolution
exception described in Autonomous Mode.

---

## Phase 1: Ground in the Repository

Inspect before asking questions:

1. Read repository instructions and the relevant implementation, tests, types, configuration, schemas,
   documentation, and CI entrypoints.
2. Inspect Git status, the current branch, remotes, and the remote default branch without switching,
   pulling, stashing, or creating a worktree.
3. Summarize the current observable behavior, established conventions, affected interfaces, and constraints.
4. Separate facts discoverable from the repository from genuine product or design decisions. Never ask the
   user for a fact that can be established safely from available sources.

If the repository is unavailable or the relevant source cannot be identified, treat that as a material gap
in Phase 2 rather than inventing an implementation context.

---

## Phase 2: Establish the Implementation Contract

Establish all of the following for every task, using the request, conversation, repository evidence, and
linked specifications:

- **Goal and actor**: who needs what problem solved, and why it matters
- **Current and desired behavior**: the externally observable difference this change must create
- **Requirements**: the behaviors that must be true when the work is complete
- **Specification**: the necessary interfaces, inputs and outputs, state transitions, defaults, precedence,
  and error behavior
- **Scope and non-goals**: what is included and intentionally excluded
- **Acceptance criteria**: concrete, independently verifiable pass/fail outcomes, including relevant failure paths
- **Constraints and compatibility**: supported environments, public interfaces, data or migration obligations,
  performance or operational limits, and prohibited changes
- **Prerequisites and dependencies**: required services, data, permissions, tools, and upstream work
- **Assumptions**: every implementation-relevant belief not guaranteed by a requirement or repository evidence

Run the Why check only when the goal or value is missing and the answer could change whether or what to build.
Ask what problem is being solved, the cost of leaving it unsolved, and whether a smaller change achieves the
same outcome. If the proposed implementation is unnecessary, say so candidly and let the user decide.

### Scrutinize Critical Behavior

For every applicable area, define the required behavior rather than merely noting the risk:

- Authentication, authorization, privacy, secrets, and trust boundaries
- Destructive operations, data integrity, migrations, and backward compatibility
- Transaction boundaries, idempotency, concurrency, ordering, retries, and duplicate delivery
- Validation, partial failure, rollback, cancellation, timeout, and recovery behavior
- Resource limits, performance regressions, observability, rollout, and operational ownership

Surface contradictions between the request and the repository, requirements that cannot all be satisfied,
untestable acceptance criteria, and fatal flaws or logic gaps the user may not have noticed.

### Ask Only Decision-Relevant Questions

Classify each unresolved item:

- Resolve discoverable facts through further inspection.
- State low-risk, reversible defaults as proposed assumptions in the plan.
- Ask about any material decision whose alternatives change user-visible behavior, safety, compatibility,
  scope, architecture, data, or acceptance criteria.

Use `AskUserQuestion` with concrete, mutually exclusive options, a recommended default, and the consequence
of each option. Ask in small groups and continue until no **material** uncertainty remains. Never convert a
security, authorization, data-loss, irreversible, or otherwise potentially fatal gap into an assumption.

In autonomous mode, return a BLOCKED report instead of asking whenever a material decision lacks an
authoritative answer — see Autonomous Mode.

---

## Phase 3: Present and Approve the Plan

Before any repository mutation, decide the test approach using the TDD criteria in Phase 5, then present a decision-complete implementation plan containing:

- The goal and observable success criteria
- Relevant current-state evidence
- The implementation approach and affected interfaces or data flow
- Failure, compatibility, migration, and operational behavior where applicable
- The test strategy mapped to the acceptance criteria, and whether it follows TDD
- Explicit non-goals, assumptions, risks, and rejected alternatives that materially affect the decision

In normal mode, use `AskUserQuestion` to offer **Approve**, **Adjust**, or **Cancel**. Do not treat answers to
individual clarification questions as approval of the complete plan. If the user adjusts it, update the
implementation contract and present the complete revised plan again. Do not proceed without explicit approval.

In autonomous mode, skip the interactive approval only as described in Autonomous Mode.

If material new information, repository drift, or a scope change invalidates an approved plan, stop, update the
contract and plan, and obtain approval again before continuing.

---

## Phase 4: Set Up the Worktree

In autonomous mode, follow the worktree rules in Autonomous Mode and skip the normal-mode base update below.

For normal mode:

1. Verify the checkout is still clean. Never stash, discard, or overwrite existing changes. If it is dirty,
   stop and ask how the user wants to preserve that work.
2. Resolve the base branch from an explicit approved choice or `refs/remotes/origin/HEAD`. Do not assume `main`.
   If no trustworthy base can be resolved, ask before changing Git state.
3. Switch to the base branch and update it only with a fast-forward pull:
   ```bash
   git switch <base-branch>
   git pull --ff-only origin <base-branch>
   ```
   If either command would overwrite work, diverges, or fails, stop and report the state; do not force it.
4. Choose a GitHub Flow-compliant branch name (e.g., `feat/add-login`, `fix/null-pointer-on-checkout`) and run:
   ```bash
   git wt <branch-name>
   ```

Capture the worktree path printed by `git wt`; its location is configuration-dependent. Run every subsequent
command relative to that path. Because shell state does not persist between tool calls, prefix commands that
need the worktree with `cd <worktree-path> && <command>`.

Recheck the relevant files after setup. If the updated base changed a material premise of the approved plan,
return to Phase 2.

---

## Phase 5: Implement

Follow the test approach decided and approved in Phase 3, using the criteria below. If repository facts discovered during implementation contradict that decision, stop and return to Phase 3 to revise and re-approve the plan rather than silently switching approach.

**Proceed with TDD when all conditions are met:**

- The change involves business logic, API handlers, or data transformation.
- A test framework already exists without disproportionate setup cost.
- Inputs and expected outputs can be defined from the acceptance criteria.

**Do not force TDD when any condition applies:**

- The change is limited to UI styling, a migration, configuration, or a one-shot operation.
- No suitable test framework exists and adding one is outside the approved scope.
- Another verification method maps more directly to the acceptance criteria.

### With TDD

Follow t-wada's TDD cycle strictly:

1. **Write the test list** — enumerate all test cases you can think of before writing any code
2. **Red** — write one failing test
3. **Green** — write the minimum code to make it pass
4. **Refactor** — clean up the design while tests stay green
5. Repeat 2–4 until the test list is exhausted

If a test is hard to write, treat it as a signal to revisit the design.

### Without TDD

Implement with the minimum changes. Touch nothing beyond what is required.

---

## Phase 6: Verify CI Locally

Determine the project's CI checks from its workflow, build, and package configuration, and run the equivalent lint, test, and build steps locally. Fix any errors before moving on to commit.

---

## Phase 6.5: CodeRabbit Self-Review (conditional)

If neither `coderabbit` nor `cr` is on `PATH`, skip this phase and go to Phase 7 in normal mode, or emit the structured report in autonomous mode.

Otherwise select and run it in the same Bash call, since shell variables do not persist between tool calls:

```bash
CODERABBIT_BIN=$(command -v coderabbit || command -v cr)
"$CODERABBIT_BIN" review --agent --type uncommitted
```

If the command errors out, note it briefly and follow the same mode-aware path as the missing-tool case. Otherwise treat the output as a self-review: fix genuine issues with the minimum change required, and briefly note any finding left as-is because it's a false positive or an intentional design choice. If you applied a fix, rerun Phase 6, then rerun the review above, and repeat until it's clean or every remaining finding is judged not to need action. Then follow the same mode-aware path.

---

## Phase 7: Commit

In autonomous mode, skip this phase entirely and emit the structured report — see Autonomous Mode.

Invoke the `commit` skill to compose and make the commit — it decides on its own whether to commit automatically or ask first, and that is what authorizes the commit.

Do not open `difit` by default. Only run it when the user explicitly requests a difit review, per the `difit` skill's own opt-in rule.

If the user did explicitly request a difit review, do it before invoking `commit`:

```bash
# Review uncommitted changes in the worktree
difit .
```

Use `difit` if `command -v difit` succeeds, otherwise use `npx difit`. If review comments come back, address them and run again; once it exits clean, proceed to invoke `commit`.

**Do not create a PR until the user explicitly says "create a PR."**
