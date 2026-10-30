---
name: create-pr
description: >
  Create a GitHub pull request with a high-signal title and description, written
  in the language that `lang <ja|en>` or git config `skills.lang` selects.
  Analyze the branch diff and complete commit history to explain the motivation,
  impact, risks, implementation choices, and review focus, then push the branch
  and open the PR through the skill's script, as a draft unless `ready` is
  given. Use this skill when the user asks to open, create, submit, or send a PR
  for review.
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
| `== branch`, `== base` | The current branch, and the freshly fetched `origin/<base>` every comparison uses | Step 2, Step 6.1 |
| `== commits` | Every commit message in `origin/<base>..HEAD`, oldest first | Step 2 |
| `== diff stat`, `== diff` | The stat, and the diff without lockfiles when it fits 20 files and 1,000 lines | Step 2 |
| `== template <path>` or `== template none` | The PR template's contents, or none | Step 3.2 or 3.3 |
| `== issues` | `Closes #N` or `Related #N` from the newest commit footer, a tab, and the issue title | Step 2.1 |
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

Read the diff and the full commit history, not only the latest commit, together with the branch name. From them, gather what each section in Step 3.3 asks for, and the type and scope Step 4 needs.

**2.1 Related issues**

Take the references from Step 1's `== issues` section and write each in the description. Use each title for the background, and never invent what an issue asks for.

| Case | Reference |
|---|---|
| Line printed | Copy the reference before the tab, but write `Closes` for a `Related` the rule below does not allow |
| Issue only in the branch name or a commit subject | `Closes #NNN`, or `Related #NNN` when the rule below allows it |

- `Related` only when a deferred requirement that still needs implementing is reported in the conversation, commits, or a caller's `SKIPPED`; the user says the implementation is partial; or the issue is only cited in passing. Post-merge verification, QA, E2E, and release work never count.
- Write each reference alone on its own line, never inside a sentence or after another reference, because Step 6's script links only a reference that stands alone on its line.
- For each `Related` issue, state what this PR resolves and what remains.

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
- Write each template section by the 3.3 Content of the section serving the same purpose, such as Summary for "What", Background for "Why", and Test Plan for "How to test".
- Add a 3.3 section at the end only for useful information that no template section holds, such as implementation details or risks.

### 3.3 Sections

Each row's Content is the only rule for what its section holds. Without a template, use these sections in this order as `##` headings: the `en` heading for `en`, the `ja` heading for `ja`.

| `en` | `ja` | Content |
|---|---|---|
| Background | 背景 | Why the change is needed, for a reviewer who lacks the surrounding context: the root problem, constraints, and why it matters now |
| Summary | 概要 | The outcome in 1-3 sentences: what is different once this merges and the problem it solves, such as "merged skills reach every local Claude Code, whatever branch is checked out" rather than "add X". Never how it is done, or the files touched or settings changed |
| Implementation Details | 実装方針 | Why this approach was chosen: the tradeoffs accepted and the alternatives rejected. Never what each part does |
| Changes | 変更内容 | What changed, under `###` group headings by behavior or area rather than by code edit, each bullet giving the change's meaning to a user or reviewer |
| Impact | 影響範囲 | What merging affects: pages, features, APIs, data formats, configuration, workflows, or users, with breaking changes called out. Facts, not doubts |
| Concerns | 懸念点 | Unresolved uncertainty or open risk a reviewer should weigh, and where to focus review. Only when one genuinely exists, not merely because the change touches performance, defaults, existing behavior, compatibility, data formats, configuration, or APIs; when unsure, include it. Never an Impact fact restated, and never what was run |
| Future Considerations | 今後の検討事項 | Follow-up deliberately left out of this PR: what, why, and how it could improve things |
| Test Plan | テスト計画 | The verification performed and its result as terse evidence: commands run, tool limits hit, automated reviews passed. For UI changes, consider before/after screenshots |

### 3.4 Writing principles

Reviewers can read the diff. The PR description is valuable because it explains intent, judgment, risk, and context that the diff does not show.

- **One fact, one place**: Each fact, such as a file's purpose or a design decision, goes only in the section whose 3.3 Content it fits. If it seems to fit two, keep it where the Content names it most specifically.
- **Omission**: Remove a section that is genuinely irrelevant, unless the template has it.

### 3.5 Line Breaks

Write each paragraph or bullet as a single source line, however long and even when the commit messages break lines, because GitHub renders every newline in a PR body as a line break.

### 3.6 Compact Pass

Before moving to Step 4, re-read the full draft once as a first-time reader with no other context, and check every sentence against the 3.3 Content of the section that holds it, and against 3.4 and 3.5. Move a sentence that fits another section's Content, delete one that restates a fact given earlier, and rejoin a broken line.

If nothing fails, keep the draft as written — depth is intentional for this skill's purpose as a design record, so do not cut content for brevity alone.

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

## Step 6. Push and Create the PR

**6.1 Run one command**

Run this as one call. Never run `gh pr create` directly, and do not stop after showing the command. Paste Step 1's `== create flags` line verbatim as `<create flags>`:

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
