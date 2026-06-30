---
name: create-github-issues
description: >
  Create GitHub Issues from a conversation, plan, or TODO list.
  Produces one Epic parent Issue and child Issues per task, each with background, requirements, specs, and acceptance criteria, linked to the Epic via the GitHub GraphQL addSubIssue mutation.
  Use this skill when the user asks to track tasks with an Epic, turn TODOs or a plan into GitHub Issues, or extract action items from a review or investigation.
allowed-tools: Bash(gh:*), Bash(git remote get-url:*)
argument-hint: "[repo <owner/repo>]"
---

# create-github-issues

Create a GitHub Epic and child Issues from conversation context.
Write structured bodies with background, requirements, specs, and acceptance criteria, then link via GraphQL.

---

## Step 1: Identify Repository

Check `$ARGUMENTS`:

- If `repo <owner/repo>` is provided, use that repository.
- Otherwise, auto-detect from the remote URL:

```bash
git remote get-url origin
```

Extract `owner/repo` from `https://github.com/owner/repo.git` or `git@github.com:owner/repo.git` and store it as `REPO`.

---

## Step 1.5: Specification Clarification

Scan the conversation context across three axes and determine whether enough information is available to write high-quality Issues.

### Evaluation Axes

| Axis | Criterion |
|------|-----------|
| Granularity | Can each task be implemented and merged as an independent PR? |
| Acceptance criteria | Can completion be confirmed with numbered verification steps? |
| Specification | Are there implementation choices that could be interpreted more than one way? |

### Decision Branches

**All axes are clear:**
Skip to Step 2. Do not ask any questions.

**One or more axes are unclear:**
Use **AskUserQuestion** to surface the ambiguities. For each unclear item, present specific answer choices (e.g., "(A) include JWT refresh in the same Issue / (B) split into a separate Issue"). Batch all unclear items into a single AskUserQuestion call (up to 4 questions); if more than 4 items are unclear, prioritize the ones with the highest impact on Issue scope.

**Stop after calling AskUserQuestion. Do not proceed to Step 2 until the user has responded.**

**User instructs to proceed with unresolved items:**
Output the warning using the "Step 1.5: Warning Format" template in `references/templates.md`, then proceed to Step 2.
Mark unresolved sections in Issue bodies with `[要確認]`.

---

## Step 2: Structure Tasks

Analyze the current conversation context (recent plans, investigations, TODO lists) and extract:

**Epic (parent Issue)**
- Title: one phrase that captures the entire work stream
- Purpose: why this work is needed (background, motivation)
- Scope: what is included in this Epic

**Child Issue list**
- Split each task into independently implementable and verifiable units
- Title and a one-line summary of each task's role in the Epic

A sequential dependency ("do A before B") can still be two separate Issues — note the dependency in the acceptance criteria.

---

## Step 3: Show Summary and Get Approval

Use the "Step 3: Summary Format" in `references/templates.md` and ask for approval.

**End your response here and wait for the user's reply.**
**Do not proceed to Step 4 until approval is received.**
If the user requests changes, update the summary and show it again before proceeding.

---

## Step 4: Generate Issue Bodies

After approval, write the Markdown body for the Epic and each child Issue using the templates in `references/templates.md`.

Write **concrete content** drawn from the conversation context — not boilerplate. Acceptance criteria are especially important: write verifiable statements equivalent to "Given X, When Y, Then Z", not vague phrases like "works correctly".

---

## Step 4.5: Issue Body Review

After generating all Issue bodies, present the full text to the user before creating anything.

Use the "Step 4.5: Body Review Format" template in `references/templates.md` to display the Epic and all child Issues in order.

**Stop after presenting. Do not proceed to Step 5 until the user explicitly approves.**

If the user requests changes, apply them and re-display the updated bodies before proceeding.

---

## Step 5: Create Issues

See `references/commands.md` for the exact shell commands.

1. Create the Epic first and capture its number and Node ID.
2. Create each child Issue in order and capture each number and Node ID.

---

## Step 6: Link Issues via GraphQL

For each child Issue, run the `addSubIssue` mutation shown in `references/commands.md`.

If GraphQL returns an error, print the error message and continue with the remaining child Issues — don't abort the whole run.

---

## Step 7: Report Completion

Use the completion report template in `references/commands.md`.
