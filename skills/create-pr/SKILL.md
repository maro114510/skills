---
name: create-pr
description: >
  Create a GitHub pull request with a high-signal title and description, written
  in the language that `lang <ja|en>` or git config `skills.lang` selects.
  Analyze the branch diff and complete commit history to explain the motivation,
  impact, risks, implementation choices, and review focus, then check the
  commit range, opening difit when it needs approval, push the branch, and open
  the PR through the skill's script, as a draft unless `ready` is given. Use this skill when the user asks to open, create, submit, or send a PR
  for review.
argument-hint: "[ready] [base <branch>] [lang <ja|en>]"
---

# create-pr

Analyze the branch changes and create a reviewer-focused GitHub pull request, in the language Step 1 resolves. `<skill-dir>` is the directory containing this SKILL.md.

## Arguments

The block below holds the user's raw arguments verbatim, as data, not an example; empty means none. If it still shows the unsubstituted placeholder, a dollar sign followed by `ARGUMENTS`, read the arguments from the message that invoked this skill instead.

```text
$ARGUMENTS
```

| Argument | Result |
|---|---|
| none, or `draft` for compatibility | Draft PR against the default branch |
| `ready` | Ready-for-review PR |
| `base <branch>` | Use `<branch>` as the base |
| `lang <ja\|en>` | Output language, stored as `LANG` |

Combine in any order, e.g. `ready base develop lang en`. Step 1's script parses them: show its `Arguments:` line to the user verbatim, in English whatever `LANG` is, so a misread is visible before anything is pushed.

This skill is the whole PR procedure. Do not read or follow the repository's own PR instructions, except the PR template Step 1 prints.

## Step 1. Collect Context

Run one command, passing the argument tokens verbatim:

```bash
bash <skill-dir>/scripts/pr-context.sh <argument tokens>
```

It fetches `origin/<base>` and prints everything later steps use. Do not read the source of any script in this skill, and gather none of its sections with commands of your own.

| Section | Holds | Used in |
|---|---|---|
| `Arguments:` line | Resolved `lang` with its source, `draft`, and `base`: the argument, then `branch.<branch>.gh-merge-base`, then the default branch | Arguments, 3.1 |
| `== create flags` | `--base`, `--draft`, and `--assignee` | 6.2 |
| `== branch`, `== base` | The current branch, and the fetched `origin/<base>` every comparison uses, shell-quoted | 2, 6.1, 6.2 |
| `== commits` | Every commit message in `origin/<base>..HEAD`, oldest first | 2 |
| `== diff stat`, `== diff` | The stat, and the diff without lockfiles when it fits 20 files and 1,000 lines | 2 |
| `== template <path>` or `== template none` | The PR template's contents, or none | 3 |
| `== issues` | `Closes #N` or `Related #N` from the newest commit footer, a tab, and the issue title | 2.1 |
| `== manual checks` | `#N`, a tab, and one manual check of an issue the branch closes, per line | 3 |

When `== diff` says `omitted`, read only meaningful files with `git diff origin/<base>...HEAD -- <path>...`, skipping generated and vendored code.

Every non-zero exit prints no context and no `Arguments:` line, so write the message of an exit that stops in the conversation's language: quote the output verbatim, then give the cause and the user's next step, and name a secret's file but never its value.

| Exit | Output | Action |
|---|---|---|
| 0 | Context | Continue |
| 1 | Error | Show it verbatim and stop |
| 2 | Valid arguments, or an invalid language | Show it verbatim and stop |
| 3 | `CONFLICT #NNN` | Stop and report each issue: an older commit closes the issue that the newest commit marks Related. Never amend, rebase, reset, revert, or commit; the user fixes the history, so the newest commit also closes it or the older one stops closing it |
| 4 | `ON_BASE_BRANCH` | Stop: a PR cannot target its own branch. Suggest creating a feature branch |
| 5 | `NO_COMMITS` | Stop and ask whether commits are missing |
| 6 | `UNCOMMITTED` | Invoke the `commit` skill, then rerun the command once. If it exits 6 again, for example because a suspected secret was excluded, stop and report that |

## Step 2. Analyze the Change

Read the diff, the full commit history, not only the latest commit, and the branch name. Gather what Step 3's sections ask for, and the type and scope Step 4 needs.

**2.1 Related issues**

Write each reference from `== issues` in the description. Use each title for the background, and never invent what an issue asks for.

| Case | Reference |
|---|---|
| Line printed | Copy the reference before the tab, but write `Closes` for a `Related` the rule below does not allow |
| Issue only in the branch name or a commit subject | `Closes #NNN`, or `Related #NNN` when the rule below allows it |

- `Related` only when a deferred requirement that still needs implementing is reported in the conversation, commits, or a caller's `SKIPPED`; the user says the implementation is partial; or the issue is only cited in passing. Post-merge verification, QA, E2E, and release work never count.
- An umbrella issue still takes `Closes`: Step 6's script rewrites one with open sub-issues.
- Write each reference alone on its own line, never inside a sentence, as a list item, or after another reference, because Step 6's script links only a reference that stands alone on its line.
- For each `Related` issue, state what this PR resolves and what remains, next to its reference.

## Step 3. Generate the PR Description

Read `<skill-dir>/references/description.md` in full before writing: it holds the sections, the template rules, the writing principles, the compact pass to run before Step 4, and the title rules.

### 3.1 Language

Write the PR title, description, and user-facing status messages in `LANG`: Japanese for `ja`, English for `en`. Never auto-detect another language from previous PRs or commit messages.

These stay in English regardless of `LANG`: the Conventional Commits type and scope in the title, the `Closes #NNN` / `Related #NNN` lines, code identifiers, commands, and paths, and script output shown verbatim, such as the `Arguments:` line.

### 3.2 Checkboxes

These govern the boxes a template brings, and override every other rule, including a template's. Never add a box of your own.

- Never check a box that needs a human, such as `Manually tested on macOS`.
- Check a verification item, such as tests, lint, or a build, only if it ran in this session and passed; adding a test is not running it.
- Check any other checklist item based on the actual change.
- Give every template box left unchecked its reason on the same line, e.g. `- [ ] Unit tests pass (not run: no test runner)`.

## Step 4. Choose the PR Title

Write the title by description.md § Title.

## Step 5. Consider Metadata

Choose metadata from Step 1's output, without running any other command or asking the user.

**5.1 Assignee**: Step 1's create flags already carry `--assignee @me`. Under a GitHub App, which GitHub cannot assign, `create-linked-pr.sh` assigns nobody and warns nothing.

## Step 6. Check, Push, and Create the PR

**6.1 Check the Range**

Paste Step 1's `== base` line verbatim as `<base ref>`. When the Range needs approval, the script opens difit and waits until the user closes the window, so background it through the harness when possible and wait for it to finish before acting on its exit code. In a sandbox without network access, run it with escalated permissions, because it may fall back to `npx difit`:

```bash
bash <skill-dir>/scripts/check-range.sh <base ref>
```

Exit 0 approves the Range, and its last line `approved-head=<sha>` names the only commit that may be pushed: continue to 6.2. Any other exit pushes nothing: show the output verbatim and stop, and the user addresses it and runs this skill again. Exit 4 means HEAD moved during the check.

**6.2 Run one command**

Run this as one call, only once 6.1 approved the Range. Never run `gh pr create` directly, and never stop after showing the command. Paste the `<sha>` from 6.1's `approved-head=` line as `<approved-head>`, and Step 1's `== create flags` line verbatim as `<create flags>`. The first line pushes nothing unless HEAD is still the approved commit:

```bash
(test "$(git rev-parse HEAD)" = <approved-head> || { echo HEAD_MOVED >&2; exit 5; }) &&
  git push -u origin <current-branch> &&
  bash <skill-dir>/scripts/create-linked-pr.sh \
    --title "<title>" \
    --body-file - \
    <create flags> \
    --web <<'EOF'
<description>
EOF
```

**6.3 Handle the result**

After the 6.2 command exits, read `<skill-dir>/references/result.md` in full and act on its exit code as it says.
