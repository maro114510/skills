---
name: commit
description: >
  Stage and commit the current working tree changes with a high-quality Conventional Commits message.
  Analyzes the diff to infer type, scope, and intent, screens for secrets and other risky changes, and pauses to ask only when the change is genuinely ambiguous or high-risk.
  Otherwise it commits automatically and reports what it did.
  Called by create-pr and implement when they need to commit changes.
  Can also be invoked directly with phrases like "commit this," "write a commit message," or "commit these changes."
allowed-tools: Bash(git status:*, git diff:*, git log:*, git add:*, git restore:*, git commit:*), Read, AskUserQuestion
argument-hint: "[optional hint, e.g. an issue number or message override]"
---

# commit

## Step 1. Inspect the working tree

```bash
git status --short
git diff --staged
git diff
git log -5 --format="%s"
```

If both `git status --short` and `git diff --staged` are empty, report "nothing to commit" and stop.

## Step 2. Screen for secrets (always blocks auto-commit)

This check covers both already-staged and unstaged/untracked changes — a suspected secret must never end up in a commit regardless of how it got into the working tree.

**Filenames**: from `git status --short`, flag paths matching common secret patterns.

- `.env*`
- `*.pem`
- `*.key`
- `id_rsa*`
- `*credentials*`
- `*secret*`
- `*.p12`
- `service-account*.json`
- and similar patterns

**Content**: filenames alone miss secrets embedded in ordinary files — for example, a token pasted into `config.yaml`.
Scan the diff content, staged and unstaged, for common secret-value patterns:

- AWS keys such as `AKIA[0-9A-Z]{16}`
- Private key headers such as `-----BEGIN [A-Z ]*PRIVATE KEY-----`
- GitHub tokens such as `gh[pousr]_[A-Za-z0-9]{20,}`
- OpenAI or Anthropic-style keys such as `sk-[A-Za-z0-9]{20,}`
- Slack tokens such as `xox[baprs]-`
- A literal-looking value assigned to `password` or `token`

This is a best-effort heuristic, not an exhaustive scanner — when in doubt, treat it as a match.

For every match found:
- If the file is already staged, unstage it first: `git restore --staged -- <path>`.
- Never add it with `git add`, even in auto-commit mode.
- Tell the user which files, or which lines for a content match, were excluded and why, and ask what to do with them — this always requires a human decision, independent of Step 6's outcome.
- Excluding a secret does not block the rest of the commit: continue with Steps 3-7 for the remaining, unaffected files, since a legitimate, unrelated change shouldn't be held hostage to an unrelated secret sitting in the same working tree.

## Step 3. Stage the change

- Changes may already be staged after Step 2's exclusions, meaning `git diff --staged` is non-empty. If so, commit only what is staged and leave unstaged changes untouched.
- If nothing is staged but unstaged or untracked changes exist, stage each specific file with `git add -- <path>`, skipping anything excluded in Step 2. Do not use `git add -A` or `git add .`.
- After staging, re-run `git diff --staged` — Steps 4 and 6 must work from this refreshed staged diff, not the one read in Step 1.

## Step 4. Compose the message

**Type and scope**: infer the type from the diff content and changed paths, choosing one of:

- `feat`
- `fix`
- `refactor`
- `docs`
- `chore`
- `perf`
- `test`
- `build`
- `ci`

Add a scope when a directory or module name naturally identifies the changed area, for example `fix(auth):`.
Omit the scope rather than inventing one when nothing naturally fits.

**Subject**: imperative mood, under 70 characters, specific rather than vague — `fix(auth): handle expired JWT on refresh`, not `fix: bug`.

**Body**: up to 4 bullets, one why fact each — problem, root cause, evidence, or a tradeoff that matters. Never what/how; no lead sentence.

| Item | Rule |
|---|---|
| Per bullet | One fact. A "because/since/so/which" chain hides a second — split or trim |
| Lines | 2 max, wrapped at ~72 columns, two-space hanging indent — intentional, unlike create-pr's Line Breaks rule |
| Overflow | Split into multiple commits, or keep the most load-bearing fact and defer the rest to the PR description |
| Trivial | Omit the body |

Good (why facts, one per bullet):
```
- Case 09 was a false positive: its integrity_concern
  justification restated "overextended" and "not_established."
- decision-rubric.md already treats both conditions as
  insufficient on their own.
```

Bad (what/how — cut this, the diff already shows it):
```
- Add a restatement check to integrity_concern: strip the
  judgment-name words from the stated reason before setting true.
```

Bad (verification narration — belongs in the PR's Test Plan, not here):
```
- Re-verified all 12 eval cases against the fixed SKILL.md; the
  9/9 overextension detection rate is preserved.
```

Bad (file enumeration — "what" wearing structure, not why):
```
- commit/SKILL.md: Step 4 body rules rewritten as bullets.
- create-pr/SKILL.md: cross-reference updated to match.
```

**Footer**: add `Closes #NNN` or `Related #NNN` when an issue number is inferable from the branch name or conversation context.
Add a `BREAKING CHANGE:` line when the change breaks an existing interface, config format, or behavior.

**No AI attribution trailer.** Do not add `Co-Authored-By` or similar provenance trailers — this matches the existing convention across this repository's entire commit history.

If `$ARGUMENTS` includes a hint — an issue number, a message override, or context the diff alone doesn't capture — incorporate it.

## Step 5. Compact Pass

Before moving to Step 6, re-read the bullets:

- What/how, verification results, or file enumeration? Cut.
- "Because/since/so/which" chaining a second fact? Split or trim.
- Over 4 bullets or 2 lines per bullet? Shorten, defer to the PR description, or split the change.

Otherwise keep as written.

## Step 6. Decide: auto-commit or ask first

Ask the user before committing — via `AskUserQuestion`, showing the staged diff summary and the message as finalized after Step 5's Compact Pass — if any of the following is true:

- The diff mixes clearly unrelated concerns, for example an unrelated `fix` bundled with a `feat`.
- The diff touches CI/CD workflow files under `.github/workflows/` or release configuration such as `Makefile`, `cliff.toml`, or plugin and version manifests.
- The diff is large: more than 20 files or more than 1,000 changed lines.
- The diff deletes tracked files that are not obviously superseded by the rest of the change.
- Some of the changed files look unrelated to what the rest of the diff is doing — possibly stray edits caught up in the same working tree.
- A confident Conventional Commits type/scope cannot be determined.

If none of these apply, skip straight to Step 7 and commit without asking.

## Step 7. Commit

```bash
git commit -m "$(cat <<'EOF'
<type>(<scope>): <subject>

<body>

<footer>
EOF
)"
```

## Step 8. Report

After committing — whether auto-committed or approved via Step 6 — show the user the commit hash and subject line in one short line.
Never commit silently without this confirmation, even in the auto-commit path.
