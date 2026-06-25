---
name: create-pr
description: >
  Create a GitHub pull request with a high-signal English title and description.
  Analyze the branch diff and complete commit history to explain the motivation,
  impact, risks, implementation choices, and review focus before running
  `gh pr create`. Use this skill when the user asks to open, create, submit, or
  send a PR for review.
disable-model-invocation: false
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
- There are uncommitted changes. Ask whether they should be committed before creating the PR.

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

Extract `#NNN` references from the branch name and commit messages. Use `Closes #NNN` only when the PR should close the issue; otherwise use `Related: #NNN`.

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

<!-- Explain the implementation approach and why it was chosen. Mention tradeoffs or rejected alternatives when relevant. -->

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
- **Implementation Details**: Explain not only what was implemented, but why this approach was chosen.
- **Concerns**: Be candid about uncertainty, rejected alternatives, review focus areas, and long-term implications.
- **Omission rule**: Remove sections that are genuinely irrelevant. However, always include Concerns when the change affects performance, defaults, existing behavior, compatibility, data formats, configuration, or APIs.

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

Confirm that any issue numbers extracted in Step 2.3 are included in the description. Ask the user whether each issue should be closed with `Closes` or referenced with `Related`.

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
