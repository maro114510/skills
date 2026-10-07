---
name: create-pr
description: >
  Create a GitHub pull request with a high-signal title and description, written
  in Japanese by default; pass `lang en` to write it in English instead.
  Analyze the branch diff and complete commit history to explain the motivation,
  impact, risks, implementation choices, and review focus before running
  `gh pr create`. Use this skill when the user asks to open, create, submit, or
  send a PR for review.
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep
argument-hint: "[ready] [base <branch>] [lang <ja|en>]"
---

# create-pr

Analyze the branch changes and create a reviewer-focused GitHub pull request in Japanese by default, or in English with `lang en`.

## Arguments

| `$ARGUMENTS` | Result |
|---|---|
| none | Draft PR against the default branch |
| `ready` | Ready-for-review PR |
| `draft` | Same as none; kept for compatibility |
| `base <branch>` | Use `<branch>` as the base |
| `lang <ja\|en>` | Output language, stored as `LANG`; `ja` when omitted |

Combine in any order, e.g. `ready base develop lang en`. Stop and list the valid arguments on `ready` with `draft`, an unknown token, `base` without a branch, or `lang` without `ja` or `en`.

All PR titles, PR descriptions, and user-facing status messages produced by this skill must be written in `LANG`, following Step 3.1.

## Step 1. Collect Context and Detect the PR Template

Run the following checks in parallel:

**1.1 Check branch and remote state**

```bash
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "no upstream"
git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || gh repo view --json defaultBranchRef --jq .defaultBranchRef.name
git status --short
```

Base: the `base` argument, else the detected default branch without `origin/`.

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
```

Within 20 files and 1,000 lines, run `git diff <base>...HEAD`. Otherwise read meaningful files with `-- <path>` and skip lockfiles, generated files, and vendored code.

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

Run `bash <skill-dir>/scripts/issue-refs.sh <base>`. `<skill-dir>` is the directory containing this SKILL.md.

| Case | Reference |
|---|---|
| Line printed | Copy it as is |
| Exit 3 with `CONFLICT #NNN` | Stop. An older commit closes the issue that the newest commit marks Related |
| Issue only in the branch name or a commit subject | `Closes #NNN`, or `Related #NNN` only when deferred items were reported, the user said the work is partial, or the issue is only cited in passing |

- One reference per line. GitHub links only the first issue of `Closes #1, #2`.
- For each `Related` issue, state what this PR resolves and what remains.

If the diff is large, meaning more than 20 files or more than 1,000 changed lines, organize the description into logical groups.

## Step 3. Generate the PR Description

### 3.1 Language

Write the PR title, PR description, and user-facing status messages in `LANG`: Japanese for `ja` (the default), English for `en`. Do not auto-detect another language from previous PRs or commit messages.

These stay in English regardless of `LANG`: the Conventional Commits type and scope in the title, the `Closes #NNN` / `Related #NNN` lines, code identifiers, commands, and paths, and script output that Step 6 says to show verbatim.

If a repository template is written in another language, preserve the template's structure, but fill in the content in natural `LANG` unless the template explicitly requires otherwise.

### 3.2 When a template exists

Follow the template found in Step 1.2. Do not ignore it:

- Fill in every section.
- Follow any inline comments or section-specific instructions.
- Check or leave unchecked checklist items based on the actual change.
- Add useful information that the template does not ask for, such as background, implementation details, risks, or future considerations, as extra sections at the end.

### 3.3 Default structure when no template exists

Use the structure below. For `ja`, replace each heading with its Japanese form; for `en`, keep the headings as written.

| `en` | `ja` |
|---|---|
| Background | 背景 |
| Summary | 概要 |
| Implementation Details | 実装方針 |
| Changes | 変更内容 |
| Impact | 影響範囲 |
| Concerns | 懸念点 |
| Future Considerations | 今後の検討事項 |
| Test Plan | テスト計画 |

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
- For `en`, use the imperative mood: "add", not "added".
- For `ja`, keep the type and scope in English and write the subject in Japanese, for example `fix(auth): リフレッシュ時に期限切れの JWT を処理する`.
- Be specific: prefer `fix(auth): handle expired JWT on refresh` over `fix: resolve crash`.

## Step 5. Consider Metadata

Before creating the PR, run the following `gh` commands and use the results to choose metadata.
Do not merely show the commands; execute them.
Do not ask the user for confirmation.

**5.1 Assignee**

Add `--assignee @me` by default.

**5.2 Labels**

Run:

```bash
gh label list --limit 200 --json name,description
```

- Apply at most two labels that clearly match the change type or area. No clear match means no label.
- Never apply status labels such as `wip` or `draft`, and never create labels.
- Tell the user the choice and reason in one sentence.

**5.3 Issue links**

Confirm that any issue numbers extracted in Step 2.3 are included in the description using the `Closes`/`Related` choice already made there. Do not ask the user to choose between them.

## Step 6. Push and Create the PR

**6.1 Push**

```bash
git push -u origin <current-branch>
```

**6.2 Create the PR**

Never run `gh pr create` directly. GitHub can lag hours before it links a closing keyword, so the script links each `Closes` line through the API and waits until the link appears. It rewrites `Closes` to `Related` for an issue with open sub-issues, so a partial PR never closes its parent. On a non-default base it keeps `Closes` but links nothing, because GitHub honors the keyword only once the PR targets the default branch.

Run the command; do not stop after showing it. Add `--draft` unless `ready` was given:

```bash
bash <skill-dir>/scripts/create-linked-pr.sh \
  --title "<title>" \
  --body-file - \
  [--draft] \
  [--base <base-branch>] \
  [--assignee @me] \
  [--label "<label>"] <<'EOF'
<description>
EOF
```

**6.3 Handle the result**

| Exit | Output | Action |
|---|---|---|
| 0 | PR URL, `LINKED #NNN`, `NOTICE` | Continue to 6.4 |
| 1 | PR already exists | Show its URL and stop. Do not edit it |
| 1 | Draft not supported | Ask: ready or abort. Ready reruns without `--draft` |
| 1 | Other | Show the error verbatim and stop |
| 2 | `ISSUE_NOT_FOUND #NNN` | No PR was created. Name the issues and stop |
| 3 | PR URL, `LINK_MISSING #NNN` | Rerun once with `--link <url>`. If still missing, ask the user to link it from the Development sidebar |

Never push again or retry blindly.

**6.4 Finish**

After creating the PR, run:

```bash
gh pr view --web
```

Show the PR URL, whether it is draft or ready, every linked issue, and any `NOTICE` line verbatim.
If a `NOTICE` rewrote an issue to `Related` while a commit footer still says `Closes` for it, warn that a merge commit would still close the issue; squash merging avoids that.
If a `NOTICE` kept `Closes` unlinked on a non-default base, tell the user to run `create-linked-pr.sh --link <url>` once the PR is retargeted to the default branch.
