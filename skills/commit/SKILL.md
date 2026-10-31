---
name: commit
description: >
  Stage and commit the current working tree changes with a high-quality Conventional Commits message.
  Analyzes the diff to infer type, scope, and intent, screens for secrets and other risky changes, and pauses to ask only when the change is genuinely ambiguous or high-risk.
  Otherwise it commits automatically and reports what it did.
  Called by create-pr and implement when they need to commit changes.
  Can also be invoked directly with phrases like "commit this," "write a commit message," or "commit these changes."
allowed-tools: Bash(git status:*, git diff:*, git log:*, git add:*, git restore:*, git commit:*, gh issue view:*), Read, AskUserQuestion
argument-hint: "[optional hint, e.g. an issue number or message override]"
---

# commit

## Step 1. Inspect the working tree

```bash
git status --short
git diff --staged
git diff
git log -5 --no-merges --format="%s"
git log --format="--- %h%n%B" origin/HEAD..HEAD 2>/dev/null
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
- OpenAI or Anthropic-style keys such as `\bsk-[A-Za-z0-9_-]{20,}` (covers `sk-ant-api03-…` and `sk-proj-…`)
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

**Language**: write the subject and body in the language most of Step 1's subjects use, ignoring quoted text.
With no commits yet, use the language `bash <skills-root>/create-pr/scripts/lang.sh` prints, where `<skills-root>` is the parent of this skill's directory.
The type, scope, trailers, and `Closes`/`Related` lines stay in English.

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

**Body**: up to 4 bullets, one why fact each — problem, root cause, evidence, or a tradeoff that matters.
Never what/how; no lead sentence.
The Commit log row of the artifact-role table in `../implement/SKILL.md` § Phase 5 assigns the body only why.

| Item | Rule |
|---|---|
| Per bullet | One fact. A "because/since/so/which" chain hides a second — split or trim |
| Lines | One sentence per line; never wrap by character count |
| Overflow | Split into multiple commits, or keep the most load-bearing fact and defer the rest to the PR description |
| Trivial | Omit the body |

A commit may hold only a failing test. Each type's body states its own why:

| Type | Why |
|---|---|
| `test:` | The behavior or defect the test pins |
| `feat:`, `fix:` | Why the behavior is needed |
| `refactor:` | Why the structure changes |

Good (why facts, one per bullet):
```
- Case 09 was a false positive: its integrity_concern justification restated "overextended" and "not_established."
- decision-rubric.md already treats both conditions as insufficient on their own.
```

Bad (what/how — cut this, the diff already shows it):
```
- Add a restatement check to integrity_concern: strip the judgment-name words from the stated reason before setting true.
```

Bad (verification narration — belongs in the PR's Test Plan, not here):
```
- Re-verified all 12 eval cases against the fixed SKILL.md; the 9/9 overextension detection rate is preserved.
- The new test fails as expected.
```

Bad (file enumeration — "what" wearing structure, not why):
```
- commit/SKILL.md: Step 4 body rules rewritten as bullets.
- create-pr/SKILL.md: cross-reference updated to match.
```

**Footer**: when an issue number is inferable from the branch name, `$ARGUMENTS`, or conversation context, judge whether merging the whole branch resolves the issue, not this commit alone:

- `Closes #NNN` by default, unless `gh issue view NNN --json subIssuesSummary` shows open sub-issues, where `completed` is below `total`; a partial branch must not close a parent, and a squash merge keeps commit footers by default. If the command fails, keep `Closes`
- `Related #NNN` only when the branch leaves part of the issue's required implementation undone, or the issue is only cited in passing rather than being the one this branch works on. Implementation is left undone only on an explicit signal: the caller reports a deferred requirement or criterion that still needs implementing, such as one in `SKIPPED`, or the user says the implementation is partial

Post-merge verification, QA, E2E tests, and release or deploy work never make an issue `Related`, even when the caller reports them as deferred or lists them in `SKIPPED`: they happen after merge by nature, so a branch whose only remaining work is of that kind resolves the issue and takes `Closes`.
A criterion that lacks evidence but was not deferred does not by itself make it `Related`.
On a follow-up commit, such as a review fix, keep `Closes` if an earlier branch commit, from the `origin/HEAD..HEAD` log, already carries it for the issue; never downgrade it to `Related` without one of the signals above. An earlier `Related` does not carry forward — judge afresh.
create-pr copies this keyword into the PR, and a merge commit closes the issue from it alone.
Add a `BREAKING CHANGE:` line when the change breaks an existing interface, config format, or behavior.
Keep caller-supplied `Removed-Test:` trailers verbatim, as the last paragraph.

**No AI attribution trailer.** Do not add `Co-Authored-By` or similar provenance trailers — this matches the existing convention across this repository's entire commit history.

If `$ARGUMENTS` includes a hint — an issue number, a message override, or context the diff alone doesn't capture — incorporate it.

## Step 5. Compact Pass

Before moving to Step 6, re-read the bullets:

- What/how, verification results, or file enumeration? Cut.
- "Because/since/so/which" chaining a second fact? Split or trim.
- Over 4 bullets, or a bullet wrapped by character count? Shorten, defer to the PR description, or split the change.

Otherwise keep as written.
Never remove a trailer such as `Removed-Test:`.

## Step 6. Decide: auto-commit or ask first

One classifier decides, `scripts/classify-approval.sh` in this skill's directory; its header lists the conditions.
Its path, size, and deletion conditions are mechanical, and no repository setting changes them.
Pass what only you can judge as `--require <reason>`, one per finding:

- The diff mixes clearly unrelated concerns, for example an unrelated `fix` bundled with a `feat`.
- Some of the changed files look unrelated to what the rest of the diff is doing — possibly stray edits caught up in the same working tree.
- A confident Conventional Commits type/scope cannot be determined.
- The caller reports a critical decision from its decision log; pass it as `--require "critical decision: <decision>"`.

```bash
bash <skill-dir>/scripts/classify-approval.sh --staged [--require "<reason>"]...
```

| Exit | Action |
|---|---|
| 0 | Skip straight to Step 7 and commit without asking |
| 10 or any other | Ask the user before committing via `AskUserQuestion`, showing the printed `reason:` lines, the staged diff summary, and the message as finalized after Step 5's Compact Pass |

When the caller reports that it classifies the whole `base..HEAD` range with this classifier before push and gets human approval when the range needs it, as implement does in normal mode, leave out the caller's critical decisions here and do not ask about the mechanical `reason:` lines: commit, and list them in Step 8.
The range classification covers them, since a path counts when any commit in the range touches it, and the caller passes its critical decisions to it.
Still ask about your own findings above, because they concern how this commit is cut, which the range review cannot fix; for a type/scope you cannot determine confidently, ask about the message only.
A difit window you opened that closed with no comments approves the diff it showed, provided `git status --porcelain` and the hash of `git diff HEAD`, both recorded when it opened, are unchanged at commit time.
Then commit without asking about the `reason:` lines or the caller's critical decisions, and list them in Step 8; your own findings above are still asked about.
A failing-test-only change is not by itself a reason to ask; commit it as `test:`.

## Step 7. Commit

```bash
git commit -m "$(cat <<'EOF'
<type>(<scope>): <subject>

<body>

<footer>
EOF
)"
```

Never pass `--no-verify`.
If a hook rejects a test-only commit because the test fails, stage the implementation files the caller names, redo Steps 2 to 6, and commit both as one `feat:` or `fix:`; if none are named, leave the test staged and report back.
Merged with a merge commit, red `test:` commits stay on the default branch, so bisect with `git bisect start --first-parent`.

## Step 8. Report

After committing — whether auto-committed or approved via Step 6 — show the user the commit hash and subject line in one short line.
Never commit silently without this confirmation, even in the auto-commit path.
