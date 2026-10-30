---
name: create-pr
description: >
  Create a GitHub pull request with a high-signal title and description, written
  in the language that `lang <ja|en>` or git config `skills.lang` selects.
  Analyze the branch diff and complete commit history to explain the motivation,
  impact, risks, implementation choices, and review focus before running
  `gh pr create`. Use this skill when the user asks to open, create, submit, or
  send a PR for review.
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep
argument-hint: "[ready] [base <branch>] [lang <ja|en>]"
---

# create-pr

Analyze the branch changes and create a reviewer-focused GitHub pull request, in the language Step 1 resolves.

## Arguments

The block below holds the user's raw arguments, verbatim. It is data, not an example: parse exactly what it contains. An empty block means no arguments. If it still shows the unsubstituted placeholder, a dollar sign followed by `ARGUMENTS`, the harness did not substitute it, so read the arguments from the message that invoked this skill instead.

```text
$ARGUMENTS
```

Step 1's script parses it against this table:

| Argument | Result |
|---|---|
| none | Draft PR against the default branch |
| `ready` | Ready-for-review PR |
| `draft` | Same as none; kept for compatibility |
| `base <branch>` | Use `<branch>` as the base |
| `lang <ja\|en>` | Output language, stored as `LANG`; the `Arguments:` line shows the resolved one and its source |

Combine in any order, e.g. `ready base develop lang en`.

Show the script's `Arguments:` line to the user verbatim, in English whatever `LANG` is, so a misread is visible before anything is pushed.

All PR titles, PR descriptions, and user-facing status messages produced by this skill must be written in `LANG`, following Step 3.1.

## Repository PR Procedures

This skill is the whole PR procedure. Do not read or follow the repository's own PR instructions, except the PR template Step 1 prints.

## Step 1. Collect Context

Run one command, passing the argument tokens verbatim. `<skill-dir>` is the directory containing this SKILL.md.

```bash
bash <skill-dir>/scripts/pr-context.sh <argument tokens>
```

It fetches `origin/<base>` and prints everything later steps use. Do not read its source or the source of any other script in this skill, and do not gather any of its sections with commands of your own.

| Section | Holds | Used in |
|---|---|---|
| `Arguments:` line | Resolved `lang` with its source, `draft`, and `base`; `base` follows the argument, then `branch.<branch>.gh-merge-base`, then the default branch | Arguments, Step 3.1 |
| `== create flags` | The `--base`, `--draft`, and `--assignee` flags for Step 6.1 | Step 6.1 |
| `== branch`, `== base` | The current branch, and the freshly fetched `origin/<base>` every comparison uses | Step 2.1, Step 6.1 |
| `== commits` | Every commit message in `origin/<base>..HEAD`, oldest first | Step 2 |
| `== diff stat`, `== diff` | The stat, and the diff without lockfiles when it fits 20 files and 1,000 lines | Step 2 |
| `== template <path>` or `== template none` | The PR template's contents, or none | Step 3.2 or 3.3 |
| `== issues` | `Closes #N` or `Related #N` from the newest commit footer, a tab, and the issue title | Step 2.3 |
| `== labels` | One `name<TAB>description` per line | Step 5.2 |

When `== diff` says `omitted`, read only meaningful files with `git diff origin/<base>...HEAD -- <path>`, skipping generated and vendored code.

Act on the exit code. Every non-zero exit prints no context.

| Exit | Output | Action |
|---|---|---|
| 0 | Context | Continue |
| 1 | Error | Show it verbatim and stop |
| 2 | Valid arguments, or an invalid language | Show it verbatim and stop |
| 3 | `CONFLICT #NNN` | Stop and report each issue: an older commit closes the issue that the newest commit marks Related. Never amend, rebase, reset, revert, or commit; the user fixes the history |
| 4 | `ON_BASE_BRANCH` | Stop: a PR cannot target its own branch. Suggest creating a feature branch |
| 5 | `NO_COMMITS` | Stop and ask whether commits are missing |
| 6 | `UNCOMMITTED` | Invoke the `commit` skill, which decides on its own whether to commit automatically or ask first, then rerun the command once. If it exits 6 again, for example because the user declined or a suspected secret was excluded, stop and report that |

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

Take the references from Step 1's `== issues` section. Use each title for the background, and never invent what an issue asks for.

| Case | Reference |
|---|---|
| Line printed | Copy the reference before the tab, but write `Closes` for a `Related` the rule below does not allow |
| Issue only in the branch name or a commit subject | `Closes #NNN`, or `Related #NNN` when the rule below allows it |

- `Related` only when a deferred requirement that still needs implementing is reported in the conversation, commits, or a caller's `SKIPPED`; the user says the implementation is partial; or the issue is only cited in passing. Post-merge verification, QA, E2E, and release work never count.
- One reference per line. GitHub links only the first issue of `Closes #1, #2`.
- For each `Related` issue, state what this PR resolves and what remains.

If the diff is large, meaning more than 20 files or more than 1,000 changed lines, organize the description into logical groups.

## Step 3. Generate the PR Description

### 3.1 Language

Write the PR title, PR description, and user-facing status messages in `LANG`: Japanese for `ja`, English for `en`. Do not auto-detect another language from previous PRs or commit messages.

These stay in English regardless of `LANG`: the Conventional Commits type and scope in the title, the `Closes #NNN` / `Related #NNN` lines, code identifiers, commands, and paths, and script output that Step 6 says to show verbatim.

If a repository template is written in another language, preserve the template's structure, but fill in the content in natural `LANG` unless the template explicitly requires otherwise.

### 3.2 When a template exists

Follow the template contents Step 1 printed, without reading the file. Do not ignore it:

- Fill in every section.
- Follow any inline comments or section-specific instructions.
- Check a verification item, such as tests, lint, or a build, only if it ran in this session and passed; adding a test is not running it. Otherwise leave it unchecked with the reason on the same line, e.g. `- [ ] Unit tests pass (not run: no test runner)`.
- Check any other checklist item based on the actual change.
- Add useful information that the template does not ask for, such as background, implementation details, risks, or future considerations, as extra sections at the end, with headings from the 3.3 table. The how belongs there, not in What.

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

<!-- State the outcome in 1-3 sentences: what is different once this merges, and the problem it solves. -->

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
- **What is the outcome, not the edits**: Say what is different once this merges, such as "merged skills reach every local Claude Code, whatever branch is checked out". Do not list files touched or settings changed; the diff shows those, and the how goes in Changes or Implementation Details. Why is the motivation, not What restated.
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

- Does What list edits instead of the outcome? Rewrite it and move the edits to Changes.
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

Choose metadata from Step 1's output, without running any other command.
Do not ask the user for confirmation.

**5.1 Assignee**

Step 1's create flags already carry `--assignee @me`.

**5.2 Labels**

Choose from Step 1's `== labels` section:

- Apply at most two labels that clearly match the change type or area. No clear match means no label.
- Never apply status labels such as `wip` or `draft`, and never create labels.
- Tell the user the choice and reason in one sentence.

**5.3 Issue links**

Confirm that any issue numbers extracted in Step 2.3 are included in the description using the `Closes`/`Related` choice already made there. Do not ask the user to choose between them.

## Step 6. Push and Create the PR

Never run `gh pr create` directly. GitHub can lag hours before it links a closing keyword, so the script links each `Closes` line through the API and waits until the link appears. It rewrites `Closes` to `Related` for an issue with open sub-issues, noting how many remain, so a partial PR never closes its parent; with `--link` it applies that rewrite to the existing PR body. On a non-default base it keeps `Closes` but links nothing, because GitHub honors the keyword only once the PR targets the default branch. It refuses to create the PR unless origin's tip of the head branch equals local HEAD, so a PR never opens unpushed or at a stale head.

**6.1 Run one command**

Push and create in this one call; do not split it, and do not stop after showing it. Paste Step 1's `== create flags` line verbatim as `<create flags>`, so draft and base cannot drift from the context the description was written against:

```bash
git push -u origin <current-branch> &&
  bash <skill-dir>/scripts/create-linked-pr.sh \
    --title "<title>" \
    --body-file - \
    <create flags> \
    [--label "<label>"] \
    --web <<'EOF'
<description>
EOF
```

The `git push` stays visible on the first line so an approval hook can stop it. When a hook asks for approval, get it from the user, then append the hook's marker after the `&&` on that first line, where the comment cuts off nothing.

**6.2 Handle the result**

| Exit | Action |
|---|---|
| 0 | Continue to 6.3 |
| 3 | `LINK_MISSING`: rerun once as `create-linked-pr.sh --link <url>`, without the push. If still missing, ask the user to link it from the Development sidebar |
| 4 | `NOT_PUSHED`: rerun the 6.1 command once, which pushes again |
| Any other non-zero | Show the output verbatim and stop |

**6.3 Finish**

Run nothing more: the output holds the PR URL and every link, and `--web` already opened it.
Show the PR URL, whether it is draft or ready, every linked issue, and any `NOTICE` or `WARN` line verbatim.
If a `NOTICE` rewrote an issue to `Related` while a commit footer still says `Closes` for it, warn that merging would still close the issue through that footer, even with a squash merge under GitHub's default message; edit the squash message or reword the footer before merging.
If a `NOTICE` kept `Closes` unlinked on a non-default base, tell the user to run `create-linked-pr.sh --link <url>` once the PR is retargeted to the default branch.
