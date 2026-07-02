---
name: implement
description: >
  A skill for executing implementation tasks with quality as the top priority. Assesses the nature
  of the task (new feature, bug fix, refactor) and testability, automatically applying TDD and Why
  validation as needed. Trigger on requests like "implement this", "add a feature", "fix a bug",
  "make a change", "build this", "I want to implement", "I need this feature",
  "please implement XXX", "refactor this", "handle this", and similar implementation requests.
  Works in a worktree and asks for user approval via difit before committing.
  Does not create a PR until the user explicitly requests it.
allowed-tools: AskUserQuestion, Bash, Read, Edit, Write, Glob, Grep
argument-hint: "[description of what to implement]"
---

# implement

Prioritize implementation quality while auto-adjusting the flow based on task characteristics.
Skip unnecessary steps; go deep only where it matters.

---

## Phase 0: Assess the Task

Make the following autonomous judgments from `$ARGUMENTS` and conversation context.

### Is a Why check needed?

**Not needed (skip to Phase 2)**
- Bug fix with clear reproduction steps
- Extension of existing functionality with an obvious goal
- User has already explained the Why

**Needed (execute Phase 1)**
- New feature addition with no stated Why
- Design change or refactor spanning multiple files
- Vague purpose such as "I just want to..."

### Is TDD effective?

**Proceed with TDD (when all conditions are met)**
- Involves business logic / API handlers / data transformation
- A test framework already exists
- Inputs and expected outputs can be defined

**No TDD (when any condition applies)**
- UI / style changes, DB migrations, config files
- No test framework or high setup cost
- Scripts or one-shot operations

### Is information missing before starting?

If required information (core spec, tech stack, constraints) is missing,
run Phase 3 questions first, then return to Phase 1 / 2.

---

## Phase 1: Confirm the Why (conditional)

Execute only when Phase 0 judges this as "needed."

Use `AskUserQuestion` to confirm:
- What specific problem does this implementation solve?
- What is the actual cost (user impact, business impact) if it is not solved?
- Is there a smaller means to achieve the same goal?

If the Why is thin or the implementation turns out to be unnecessary, tell the user candidly and stop.
Leave the decision to the user.

---

## Phase 2: Setup

### Bring main up to date

```bash
git switch main
git pull origin main
```

### Create a worktree

Choose a GitHub Flow-compliant branch name (e.g., `feat/add-login`, `fix/null-pointer-on-checkout`),
then create a worktree with `git-wt`:

```bash
git wt <branch-name>
```

`git-wt` places the worktree at `.wt/<branch-name>/` by default.
Run all subsequent Bash commands relative to this path. Because shell state does not persist between
tool calls, prefix commands that need a relative path with `cd .wt/<branch-name> && <command>`.

---

## Phase 3: Scrutinize and Reconcile the Implementation Plan

If Phase 1 was executed, wait for its answers before entering this phase. The scope of spec
clarification depends on the Why answers, so these must run sequentially.

1. Read the relevant codebase (existing implementation, tests, type definitions, config).
2. Surface gaps, contradictions, and undefined behaviors between the plan and the current state.
3. When any of the following are discovered, **always confirm with `AskUserQuestion` before proceeding**:
   - Transaction boundaries, idempotency, or concurrency safety are undefined
   - No rollback design on error
   - Auth/authorization handling is ambiguous
   - Potential fatal flaws or logic gaps the user may not have noticed

Keep asking until all uncertainty is resolved. Group multiple questions into a single `AskUserQuestion` call.

---

## Phase 4: Implement

### With TDD (when Phase 0 judged applicable)

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

## Phase 5: Verify CI Locally

Check `.github/workflows/` and `Makefile` / `package.json` for CI configuration, then run the
equivalent checks:
- lint / typecheck
- test suite
- build

Fix any errors before moving on to commit.

---

## Phase 5.5: CodeRabbit Self-Review (conditional)

Run only when the CodeRabbit CLI is available. Check with `command -v coderabbit` or `command -v cr`.
If neither is found, skip this phase entirely and proceed to Phase 6.

1. Request a review of the uncommitted diff:
   ```bash
   coderabbit review --agent --type uncommitted
   ```
   If the command errors out (e.g. not authenticated, network failure), note this briefly to the user
   and proceed to Phase 6 without blocking.
2. Treat the output as a self-review. Fix only genuine issues, with the minimum change required —
   do not piggyback unrelated cleanup.
   For findings that are false positives or reflect an intentional design decision,
   leave the code as is and note the reason briefly to the user.
3. If any fix was applied, rerun the same command to confirm the finding is resolved.
   Repeat until the review is clean or all remaining findings are judged as not requiring action.

---

## Phase 6: Request Approval Before Committing

Use `difit` to have the user review the diff before committing.
Use `difit` if `command -v difit` succeeds, otherwise use `npx difit`.

```bash
# Review uncommitted changes in the worktree
difit .
```

If review comments come back, address them and run again.
If it exits without comments, treat that as approval and proceed to commit.

**Do not create a PR until the user explicitly says "create a PR."**
