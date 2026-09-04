---
name: create-pr
description: Create a high-signal GitHub pull request (English title and description) from the branch diff and commit history. Use when the user asks to open, create, submit, or send a PR for review.
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

Check for a template at `.github/PULL_REQUEST_TEMPLATE.md`, `.github/pull_request_template.md`, `docs/pull_request_template.md`, or `PULL_REQUEST_TEMPLATE.md`, in that order. If one exists, read it and use it in Step 3.

**1.3 Get the diff after choosing the base branch**

```bash
git log --oneline <base>..HEAD
git diff --stat <base>...HEAD
git diff <base>...HEAD
```

**1.4 Stop conditions**

Stop and report to the user if the current branch is the base branch itself (suggest creating a feature branch), if there are no commits on the branch (ask whether commits are missing), or if there are uncommitted changes. For uncommitted changes, invoke the `commit` skill to handle them, then re-check `git status --short` and continue only once the worktree is clean; stop and report if it isn't.

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

Use the structure in `references/default-template.md`.

### 3.4 Writing principles

Reviewers can already read the diff, so the description should carry intent, judgment, risk, and context the diff doesn't show.

- **Background**: make the reason for the change clear to a reviewer with no surrounding context.
- **Summary**: prefer "add X to solve Y" over vague wording like "add X."
- **Implementation Details**: explain why this approach was chosen; the "what" belongs in Changes only.
- **One fact, one place**: don't restate in Implementation Details a fact Changes already covers.
- **Concerns**: include only genuine unresolved uncertainty or risk, not every touched area; when unsure, include it.
- **Test Plan vs. Concerns**: execution narration goes in Test Plan, not Concerns.
- **Omission rule**: drop sections that are genuinely irrelevant.

### 3.5 Line Breaks

GitHub renders every single newline inside a PR/issue body as a hard line break. README files differ, since CommonMark treats a lone newline there as a soft break joined by a space. Do not manually wrap prose at ~72 columns the way a plain-text commit message is wrapped; that convention produces a choppy, broken-looking body on GitHub.

Within one paragraph or one bullet item, write the sentence as a single unbroken line in the source text no matter how long it is. Only start a new line at a real paragraph or bullet boundary.

Bad — manually wrapped, renders as 3 separate lines on GitHub:

```
Adds `chrome-adapter.js`, a factory that wraps `chrome.tabs` and
`chrome.bookmarks`, converting every bookmark node into the plain
`RawNode` shape the domain package already expects.
```

Good — one line in source, wraps naturally when rendered:

```
Adds `chrome-adapter.js`, a factory that wraps `chrome.tabs` and `chrome.bookmarks`, converting every bookmark node into the plain `RawNode` shape the domain package already expects.
```

### 3.6 Compact Pass

Re-read the full draft once as a first-time reader: delete any sentence restating a fact from an earlier section, move or delete anything in Concerns that fails the genuine-uncertainty bar above, and rejoin any line-broken paragraph or bullet. Otherwise keep the draft as written; depth is intentional here as a design record, so don't cut content for brevity alone.

## Step 4. Choose the PR Title

**4.1 Format**

Use Conventional Commits format, for example `feat:`, `fix:`, or `refactor:`. Add a scope when useful, such as `fix(location):`, and append `!` for breaking changes, such as `feat(config)!:`. Keep the title under 70 characters, use the imperative mood ("add", not "added"), and be specific: prefer `fix(auth): handle expired JWT on refresh` over `fix: resolve crash`.

**4.2 Match existing PRs**

If the repository has existing PRs, match their title style unless it conflicts with the rules above.

## Step 5. Consider Metadata

Before creating the PR, run the following `gh` commands and use the results to choose metadata automatically.
Do not merely show the commands; execute them.
Steps 5.2 and 5.3 do not require user confirmation because the AI chooses labels and the milestone automatically.

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

Compare open milestones with the Step 2 analysis and automatically attach the most appropriate one.
Tell the user which milestone was selected and why in one concise sentence.
If no milestone clearly matches, or several are equally plausible, continue without one.

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
