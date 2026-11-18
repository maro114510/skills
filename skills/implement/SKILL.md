---
name: implement
description: >
  A skill for executing implementation tasks with quality as the top priority. Grounds the request
  in the codebase, resolves requirements and acceptance criteria, decides autonomously from the Issue and
  repository, and returns Questions only when acceptance, a premise, or the sources are in doubt, or a critical
  decision is unsettled. Writes tests through one playbook per task type, commits each TDD cycle, and proves every
  fix that goes through the bug-fix playbook with a reproduction test that fails on the pre-fix code.
  Trigger on requests like
  「これを実装して」「機能を追加して」「バグを修正して」「変更して」「これを作って」
  「リファクタリングして」「対応して」 and similar implementation requests.
  Builds one Request as one change unit for one PR, and returns Questions asking to split the Issue or request when it needs more.
  Works in a worktree, commits as it goes, and before it returns has a fresh context check that the branch adds nothing the request did not ask for and lacks nothing it asks for,
  then self-reviews the whole branch range on the first pass and only the fix delta on a second.
  Locks an Issue by creating its branch `feat/issue-<N>` on origin first, so a second session handed the same Issue returns Busy instead of duplicating the work.
  Behaves the same whoever calls it: it never asks and never waits, and ends by returning Busy, Questions, or Built.
  Never pushes a commit and does not create a PR; both are the caller's. The only thing it writes to origin is the Issue's branch, as the Lock.
argument-hint: "[description of what to implement]"
---

# implement

Prioritize implementation quality. Scale the flow to the task: skip steps that add nothing and go deep only where it matters.

Read `references/worktree.md` in full before Phase 1, unless the caller names the worktree to work in.

Relative paths and `<skill-dir>` name this skill's directory, the one containing this SKILL.md, and `<skills-root>` is its parent.

## Result

A run behaves the same whoever calls it, a person's session or another skill. It never asks and never waits for an answer: it ends by returning one Result as its final message and stopping.

| Result | When | The message holds |
|---|---|---|
| Busy | The Issue's branch already exists on origin | The `branch=` line the script printed, and its `worktree=` line when one exists on this host |
| Questions | A Phase 2 trigger fired, or another stop below says to return Questions | Each open question, written as Questions says, and the branch and worktree when this run created them |
| Built | Phase 6.9 finished | Phase 7's report, and the branch and worktree |

Start the message with one line, `IMPLEMENT: busy`, `IMPLEMENT: questions`, or `IMPLEMENT: built`, so a caller reads the Result without parsing the rest.
The Lock stays on origin when the run returns, so the caller hands the worktree back in the Request to resume.

The Request is `$ARGUMENTS` with every answer the caller relays from an earlier Questions. It may also name the worktree to work in and the base branch. Work in the named worktree, take no Lock and create no branch, and skip Phase 4.

### Questions

A caller that can reach a person shows the Questions to them, and one that cannot writes them where it has to. Either way it runs this skill again with the answers in the Request.

- Read `references/question.md` in full, and write each question as it says.
- Raise every open triggered item before any repository mutation, the one blocking the work first.
- Offer concrete, mutually exclusive options, put the recommended one first, and state the consequence of each.
- Never choose the answer for the person.

An operational stop elsewhere in this skill, such as a failed fetch, ends the run with a message stating the state and no Result.

---

## Phase 0: Assess the Request

Determine the task type from `$ARGUMENTS` and the conversation.

- Record what the user already decided so they never have to repeat it.
- Defer the playbook choice until the repository is inspected and acceptance criteria exist.
- Do not mutate repository state in Phases 0 to 3. The exception is the Issue Lock, which `references/worktree.md` § Issue Lock takes when the Request names an Issue and no worktree.

---

## Phase 1: Ground in the Repository

Inspect before asking questions.

1. Read repository instructions and the relevant implementation, tests, types, configuration, schemas, documentation, and CI entrypoints.
2. Inspect Git status, the current branch, remotes, and the remote default branch. Do not switch, pull, stash, or create a worktree other than the Issue Lock's.
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

### Decide by Default and Return Questions Only on a Trigger

An item is open only if it survives the Phase 1 lookup and its remaining readings lead to materially different results. Return Questions only when an open item meets one of these triggers.

| # | Trigger | Fires when |
|---|---|---|
| 1 | Acceptance in doubt | Done cannot be judged because the criteria are missing and cannot be derived from the request's intent, or because they cannot be verified. This includes a criterion that neither a checkout of the repository nor its CI can observe, such as one that needs a deploy or a person; its question's recommended option drafts an Issue for that criterion, naming its title and the criterion, and when an Issue backs the request, the edit that removes the criterion from it |
| 2 | Premise in doubt | The request conflicts with what you observed: the bug does not reproduce, the target does not exist or already behaves as desired, the change cannot achieve its stated goal, or the request needs more than one change unit, as Split Check below says |
| 3 | Sources contradict | The Issue body, comments, Epic, repository instructions, caller prompt, or criteria disagree with each other, and no later statement by the same author resolves it |
| 4 | Unsettled critical decision | No source settles a decision where a wrong choice could cause a security exposure, data loss or corruption, financial harm, an irreversible change, or a broken public interface. Only an explicit statement or an established repository convention settles one, never your own inference |

Decide everything else yourself. Follow repository conventions, prefer the smallest reversible option within scope, and record the choice in the decision log.

These triggers govern clarification only. Every operational stop elsewhere in this skill stays unchanged and ends the run as its own section says. These stops include:

- An unresolvable base branch or a failed fetch in Phase 4
- Exit 3 in Phase 6.5
- The `commit` skill's own checks

When a trigger fires, raise every open triggered item before any repository mutation, and return them as Questions says. A later run returns Questions again only when an answer raises a new trigger.
If the requested change looks unnecessary or its premise wrong, say so candidly in the Questions and let the person decide.

### Split Check

Read `<skills-root>/create-github-issues/references/change-units.md` in full before judging trigger 2. The request needs more than one change unit when that file splits it, or when a repository rule requires a split. Then the question asks to split the Issue, or the request when no Issue backs it. A fix to the unit's own pull request, such as a repair, stays in that unit and never fires this check.

---

## Phase 3: Present the Plan

Before any repository mutation, present a decision-complete implementation plan that covers:

- The goal and observable success criteria
- Relevant evidence about the current state
- The implementation approach and affected interfaces or data flow
- Failure, compatibility, migration, and operational behavior where applicable
- The one change unit this run builds, as Phase 2 trigger 2 checked it; never split or defer it here
- A test strategy mapped to the acceptance criteria
- Explicit non-goals, risks, and the decision log

Then proceed without waiting for approval of the plan: the PR is where the change is reviewed.

If new information, repository drift, or a scope change raises a Phase 2 trigger later, stop and return Questions, leaving the partial work in the worktree.

- A run that receives the answer inspects the branch's commits and the uncommitted changes including untracked files. Undo only the work that implements an option the answer rejected, reverting a commit with `git revert`, and keep everything else.

---

## Phase 4: Set Up the Worktree

Skip this phase when the Request names the worktree or the Issue Lock made one. Otherwise follow `references/worktree.md` § Phase 4.

---

## Phase 5: Implement

Each artifact explains one thing.
Do not repeat it in another.

| Artifact | Explains | Reader, and how long it stays true |
|---|---|---|
| Code | How | Everyone; always current |
| Tests | What | Whoever changes the behavior; fails once untrue |
| Commit log | Why | Whoever asks why a line changed; fixed to that change |
| Code comments | Why not: a rejected alternative or a non-obvious constraint | The next editor of that line; as long as the line stands |

- A doc comment says what its name is for, not what the name already says.
- History, motive, and the measurements behind a value go in the commit body. A comment keeps only its Why not, even when shortened.

Route each part of the task in the Phase 3 plan. A playbook, relative to this skill's directory, is the only procedure for writing its type's tests.

| Task type | Playbook |
|---|---|
| Adds, changes, or removes behavior a user or caller can observe | `references/playbooks/behavior-change.md` |
| Corrects behavior that differs from what was specified or intended | `references/playbooks/bug-fix.md` |
| Changes structure while observable behavior stays the same | `references/playbooks/refactor.md` |

- A part no row fits follows Tests Not to Write. A task that spans types runs each part through its own playbook, each ending on a green commit.
- A fix made after a green commit, from a later phase or a re-dispatch, is routed the same way. A test changed alone, for behavior the code already has, is a pin under `refactor.md` step 2.

Before the first edit, read `references/test-policy.md` and the routed playbook, and put the playbook's steps verbatim at the top of the todo list. Mark a step you skip `skip: <reason>`.

Commit each step with the `commit` skill, giving it the type the playbook names, because it infers `test:` for a test-only diff, any `Removed-Test` trailer, and, when the work traces to an Issue, its number. Never push a commit.
The `commit` skill never asks, so carry every file it left uncommitted and every type it chose without confidence into your final report.

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

Scope the test run to what the diff can affect: the suites that exercise the files it touches, plus every check a criterion names. Run the whole suite only when it finishes within a few minutes on this machine. Leave the rest to CI, and report it as not run, never as passed.

---

## Phase 6.5: Separate-Context Self-Review

Follow `references/self-review.md`, then proceed to Phase 6.9, unless a question it raised stopped the run.

---

## Phase 6.9: Reconcile Against the Source

This phase always runs. Phase 2's criteria live in context, and context drifts toward what you did, so check against the source again instead of memory.

1. Re-fetch the source: the Issue body, linked spec, and caller's prompt. If it changed since Phase 2, say so first.
2. Quote each acceptance criterion verbatim, because paraphrasing is where a criterion gets softened. A criterion derived from the request's intent has no source text, so prefix it with `(derived)` and never present it as a quote.
3. Read `references/evidence.md`, relative to this skill's directory. Classify each criterion, attach evidence tagged `[behavior]` or `[static]` as it defines, and classify the outcome. A behavior criterion needs `[behavior]` evidence. A green CI run is never behavior evidence for a criterion that does not name that check.
4. Treat a `No evidence` criterion, and one whose run observed the opposite of what it names, as unsatisfied. List each in Built with its reason, `no evidence` or `failure observed`, and still return Built, because the caller passes them on to whoever verifies the change. Never report one as satisfied.

```
| Criterion (verbatim, or `(derived)`) | Evidence |
|---|---|
| <behavior criterion> | `[behavior]` <command or input>; observed <result> |
| <structure or content criterion> | `[static]` <file:line> |
| <criterion without evidence> | none |

Unsatisfied: <criterion> -> <reason>
```

---

## Phase 7: Finish

1. Commit any uncommitted work with the `commit` skill, so the range holds the whole change. Give it the Issue number, as Phase 5 says. If a commit hook rewrote any file, rerun Phase 6.9 on the committed state.
2. Return Built: the Phase 6.9 table, the Phase 6.5 outcome with its reviewed HEAD, every commit in `<reviewed-head>..HEAD` as unreviewed, or all of the range when the outcome is `not-run` or `git merge-base --is-ancestor <reviewed-head> HEAD` fails, and every file the `commit` skill left uncommitted with every `reason:` line it listed.

Never push a commit, and never create a PR. The Lock branch on origin is the only remote write. The caller checks the range before it publishes anything.
