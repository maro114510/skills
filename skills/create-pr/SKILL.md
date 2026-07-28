---
name: create-pr
description: >
  Create a GitHub pull request with a high-signal English title and description.
  Analyze the branch diff and complete commit history to explain the motivation,
  impact, risks, implementation choices, and review focus before running
  `gh pr create`. Use this skill when the user asks to open, create, submit, or
  send a PR for review.
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep
argument-hint: "[draft] [base <branch>]"
---

# create-pr

Analyze the branch changes and create a reviewer-focused GitHub pull request in English.

## Arguments

Parse `$ARGUMENTS` as follows:

- No arguments -> auto-detect the base branch and create a regular PR.
- `draft` -> create a draft PR.
- `base <branch>` -> use the specified base branch.
- Arguments may be combined, for example: `draft base develop`.

All PR titles, PR descriptions, and user-facing status messages produced by this skill must be written in English.

## Step 1. Collect Context and Detect the PR Template

Run the following checks in parallel:

**1.1 Check branch and remote state**

```bash
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "no upstream"
git remote show origin | grep 'HEAD branch'
git status --short
```

**1.2 Find the PR template**

Search in this order and use the first template found in Step 3:

1. `.github/PULL_REQUEST_TEMPLATE.md`
2. `.github/pull_request_template.md`
3. `docs/pull_request_template.md`
4. `PULL_REQUEST_TEMPLATE.md`

If a template exists, read it before generating the PR description.

**1.3 Get the diff after choosing the base branch**

```bash
git log --oneline <base>..HEAD
git diff --stat <base>...HEAD
git diff <base>...HEAD
```

**1.4 Stop conditions**

Stop and report the issue to the user if any of the following is true:

- The current branch is the base branch itself, so a PR cannot be created. Suggest creating a feature branch.
- There are no commits on the branch. Ask whether commits are missing.
- There are uncommitted changes. Invoke the `commit` skill to handle them — it decides on its own whether to commit automatically or ask first. Afterward, re-check `git status --short`: only re-run 1.3 and continue if the worktree is now clean. If uncommitted changes remain — for example the user declined, or a suspected secret was excluded — stop and report that instead of continuing.

## Step 2. Analyze the Change

Read the diff and the full commit history, not only the latest commit, to identify:

**2.1 Change type and motivation**

- Type: feat / fix / refactor / docs / chore / deps / perf
- Motivation: why this change was needed, inferred from commit messages, code changes, and the branch name
- Rationale: why this implementation approach was chosen, including tradeoffs or rejected alternatives when visible

**2.2 Impact and risk**

- Impact: which modules, pages, APIs, workflows, or users may be affected
- Benefit: what improves because of this change
- Risk: breaking changes, edge cases, performance impact, migration needs, or future maintenance costs
- Implications: what this change suggests for future direction or follow-up work

**2.3 Related issues**

Extract `#NNN` references from the branch name and commit messages. Default to `Closes #NNN` for every extracted issue. Use `Related: #NNN` instead only when the diff, commit messages, or branch name make it clear the issue is not actually resolved by this PR (for example, it covers only part of the issue's scope).

If the diff is large, meaning more than 20 files or more than 1,000 changed lines, organize the description into logical groups.

## Step 3. Generate the PR Description

### 3.1 Language

Write the PR title, PR description, and user-facing status messages in English by default. Do not auto-detect another language from previous PRs or commit messages.

If a repository template is written in another language, preserve the template's structure, but fill in the content in natural English unless the template explicitly requires otherwise.

### 3.2 When a template exists

Follow the template found in Step 1.2. Do not ignore it:

- Fill in every section.
- Follow any inline comments or section-specific instructions.
- Check or leave unchecked checklist items based on the actual change.
- Add useful information that the template does not ask for, such as background, implementation details, risks, or future considerations, as extra sections at the end.

### 3.3 Default structure when no template exists

```markdown
## Background

<!-- Explain why this change is needed. Include the root problem, relevant context, constraints, and why this matters now. -->

## Summary

<!-- Explain what changed and how it solves the problem in 1-3 sentences. -->

## Implementation Details

<!-- Explain why this implementation approach was chosen, and tradeoffs or rejected alternatives. Do not restate what each file/group does here — that belongs only in Changes. -->

## Changes

<!-- Group meaningful changes by behavior or area, not by low-level code edits. -->

### [Group name]
- Explain the user-facing or reviewer-relevant meaning of the change.

## Impact

<!-- List affected pages, features, APIs, data formats, configuration, or workflows. Call out breaking changes explicitly. -->

## Concerns

<!-- Note review focus areas, known risks, tradeoffs, uncertainty, and future implications. -->

## Future Considerations

<!-- Describe follow-up work that is intentionally out of scope for this PR. Be specific about what, why, and how it could improve. -->

## Test Plan

<!-- Describe the verification performed and the result. For UI changes, consider before/after screenshots. -->
```

### 3.4 Writing principles

Reviewers can read the diff. The PR description is valuable because it explains intent, judgment, risk, and context that the diff does not show.

- **Background**: Make the reason for the change clear to a reviewer who lacks the surrounding context.
- **Summary**: Avoid vague wording like "add X"; prefer "add X to solve Y."
- **Implementation Details**: Explain why this approach was chosen, not what it does — the "what" belongs in Changes.
- **One fact, one place**: Each fact (a file's purpose, a design decision) belongs in exactly one section. If Implementation Details would restate what Changes already says, keep only the reasoning Changes does not capture.
- **Concerns**: Include only when genuine unresolved uncertainty, risk, or a deliberate tradeoff actually exists — not merely because the change touches performance, defaults, existing behavior, compatibility, data formats, configuration, or APIs. When unsure whether something qualifies, include it rather than omit it.
- **Test Plan vs. Concerns**: Execution narration (commands run, tool limitations hit, which automated review already passed) belongs in Test Plan as terse evidence, not in Concerns. Concerns is for judgment calls and open risk, not an execution log.
- **Omission rule**: Remove sections that are genuinely irrelevant.

### 3.5 Line Breaks

GitHub renders every single newline inside a PR/issue body as a hard line break (`<br>`), unlike README files where CommonMark treats a lone newline as a soft break joined by a space. Do not manually wrap prose the way a plain-text commit message is wrapped (for example at ~72 columns) — that convention produces a choppy, broken-looking body on GitHub.

Within one paragraph or one bullet item, write the sentence as a single unbroken line in the source text no matter how long it is. Only start a new line at a real paragraph or bullet boundary.

Bad (manually wrapped, renders as 3 separate lines on GitHub):

```
Adds `chrome-adapter.js`, a factory that wraps `chrome.tabs` and
`chrome.bookmarks`, converting every bookmark node into the plain
`RawNode` shape the domain package already expects.
```

Good (one line in source, wraps naturally when rendered):

```
Adds `chrome-adapter.js`, a factory that wraps `chrome.tabs` and `chrome.bookmarks`, converting every bookmark node into the plain `RawNode` shape the domain package already expects.
```

### 3.6 Compact Pass

Before moving to Step 4, re-read the full draft once as a first-time reader with no other context:

- Does any sentence restate a fact already given in an earlier section? Delete the later occurrence.
- Does anything in Concerns fail the genuine-uncertainty bar above? Move it to Test Plan or delete it.
- Does any paragraph or bullet contain a newline that is not a real paragraph/bullet boundary? Rejoin it into one line.

If none of these apply, keep the draft as written — depth is intentional for this skill's purpose as a design record, so do not cut content for brevity alone.

## Step 4. Choose the PR Title

**4.1 Format**

- Use Conventional Commits format: `feat:`, `fix:`, `refactor:`, and so on. Add a scope when useful, for example `fix(location):`.
- For breaking changes, add `!` after the type or scope, for example `feat(config)!:` or `fix(api)!:`.
- Keep the title under 70 characters.
- Use the imperative mood: "add", not "added".
- Be specific: prefer `fix(auth): handle expired JWT on refresh` over `fix: resolve crash`.

**4.2 Match existing PRs**

If the repository has existing PRs, check their title style and stay consistent unless it conflicts with the rules above.

## Step 5. Consider Metadata

Before creating the PR, run the following `gh` commands and use the results to propose choices to the user.
Do not merely show the commands; execute them.
Complete 5.3 and 5.4, including user confirmation, before continuing to Step 6.
Step 5.2 does not require user confirmation because the AI chooses labels automatically.

**5.1 Assignee**

Add `--assignee @me` by default.

**5.2 Labels**

Run:

```bash
gh label list
```

Compare the available labels with the Step 2 analysis and automatically choose the most appropriate labels.
Tell the user which labels were selected and why in one concise sentence.
If no label matches, continue without labels.

**5.3 Milestone**

Run:

```bash
gh api repos/{owner}/{repo}/milestones
```

If open milestones exist, compare them with the change and ask the user whether to attach one.

**5.4 Issue links**

Confirm that any issue numbers extracted in Step 2.3 are included in the description using the `Closes`/`Related` choice already made there. Do not ask the user to choose between them.

## Step 6. Push and Create the PR

**6.1 Push**

```bash
git push -u origin <current-branch>
```

**6.2 Create the PR**

Run the following command. Do not stop after merely showing the command to the user:

```bash
gh pr create \
  --title "<title>" \
  --body "$(cat <<'EOF'
<description>
EOF
)" \
  [--draft] \
  [--base <base-branch>] \
  [--assignee @me] \
  [--label "<label>"] \
  [--milestone "<milestone>"]
```

**6.3 Finish**

After creating the PR, run:

```bash
gh pr view --web
```

Show the PR URL to the user.
