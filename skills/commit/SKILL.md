---
name: commit
description: >
  Stage and commit the current working tree changes with a high-quality Conventional Commits message.
  Analyzes the diff to infer type, scope, and intent, and screens for secrets and other risky changes.
  It never asks: it leaves a suspected secret out, commits the rest, and reports what it did, excluded, or flagged.
  Called by create-pr and implement when they need to commit changes.
  Can also be invoked directly with phrases like "commit this," "write a commit message," or "commit these changes."
argument-hint: "[optional hint, e.g. an issue number or message override]"
---

# commit

`<skill-dir>` is this file's directory, and `<skills-root>` is its parent.

## Step 1. Inspect the working tree

```bash
git status --short
git diff --staged
git diff
git log -5 --no-merges --format="%s"
git log --format="--- %h%n%B" origin/HEAD..HEAD 2>/dev/null
```

If both `git status --short` and `git diff --staged` are empty, report "nothing to commit" and stop.

If `git status --short` holds any change this session did not make itself, touch nothing, including your own changes, and end with `STOPPED: foreign changes` and the paths.

This skill never asks the user and never waits for an answer, in a chat session or without a human. Every step below resolves its own findings and lists them in Step 8.

## Step 2. Screen for secrets

Cover staged, unstaged, and untracked changes: a suspected secret never ends up in a commit, however it got into the working tree.

Run the scanner, which reads the pattern list babysit's gate also screens with:

```bash
bash <skill-dir>/scripts/scan-secrets.sh
```

It prints one `excluded: <path>: <why>` line per match, with a line number for a content match and never the matched value, and exits 10 when it matched and 0 when it did not.

This is a best-effort heuristic: when in doubt, treat it as a match. For every `excluded:` line:

- If the file is staged, unstage it: `git restore --staged -- <path>`.
- Never `git add` it.
- List in Step 8 each excluded file and why, with the line number for a content match, never the matched value. What to do with it is the user's decision, so leave it uncommitted.
- Continue Steps 3-7 with the remaining files, so an unrelated change is not held hostage to the secret.

## Step 3. Stage the change

- If `git diff --staged` is non-empty, including after Step 2's exclusions, commit only what is staged and leave unstaged changes untouched.
- Otherwise stage each file with `git add -- <path>`, skipping Step 2's exclusions. Never `git add -A` or `git add .`.
- Re-run `git diff --staged`; Steps 4 and 6 work from this refreshed diff.

## Step 4. Compose the message

**Language**: the language most of Step 1's subjects use, ignoring quoted text. With no commits yet, the language `bash <skills-root>/create-pr/scripts/lang.sh` prints. The type, scope, trailers, and `Closes`/`Related` lines stay in English.

**Type and scope**: infer the type from the diff and changed paths: `feat`, `fix`, `refactor`, `docs`, `chore`, `perf`, `test`, `build`, or `ci`. Add a scope when a directory or module name naturally identifies the area, as in `fix(auth):`; omit it rather than invent one.

**Subject**: imperative mood, under 70 characters, specific: `fix(auth): handle expired JWT on refresh`, not `fix: bug`.

**Body**: up to 4 bullets, one why fact each: problem, root cause, evidence, or a tradeoff that matters. Never what/how, verification narration, or file enumeration; no lead sentence. The Commit log row of the artifact-role table in `../implement/SKILL.md` § Phase 5 assigns the body only why. Read `references/message-examples.md` when unsure whether a bullet is a why.

| Item | Rule |
|---|---|
| Per bullet | One fact. A "because/since/so/which" chain hides a second — split or trim |
| Lines | One sentence per line; never wrap by character count |
| Overflow | Split into multiple commits, or keep the most load-bearing fact and defer the rest to the PR description |
| Trivial | Omit the body |

A commit may hold only a failing test. The body states the type's why: `test:` the behavior or defect the test pins; `feat:` and `fix:` why the behavior is needed; `refactor:` why the structure changes.

**Footer**: when an issue number is inferable from the branch name, `$ARGUMENTS`, or the conversation, read `references/issue-footer.md` and add the `Closes #NNN` or `Related #NNN` line it decides.
Add a `BREAKING CHANGE:` line when the change breaks an existing interface, config format, or behavior.
Keep caller-supplied `Removed-Test:` trailers verbatim, as the last paragraph.
Add no `Co-Authored-By` or other AI attribution trailer, matching this repository's history.
Incorporate any hint in `$ARGUMENTS`: an issue number, a message override, or context the diff lacks.

## Step 5. Compact Pass

Re-read the bullets. Cut what/how, verification results, and file enumeration. Split or trim a "because/since/so/which" chain. Over 4 bullets, or one wrapped by character count: shorten, defer to the PR description, or split the change. Otherwise keep as written. Never remove a trailer such as `Removed-Test:`.

## Step 6. Check the staged change

Resolve each finding yourself and list it in Step 8:

- The diff mixes clearly unrelated concerns, such as an unrelated `fix` bundled with a `feat`: keep one concern staged, unstage the rest with `git restore --staged -- <path>`, commit it, then run Steps 3 to 8 again for the rest.
- Some changed files look unrelated to the rest, possibly stray edits: unstage them and leave them uncommitted.
- A confident Conventional Commits type/scope cannot be determined: use the closest type and omit the scope.

Then run the classifier; its header lists the conditions. Pass each critical decision the caller reports from its decision log:

```bash
bash <skill-dir>/scripts/classify-approval.sh --staged [--require "critical decision: <decision>"]...
```

Whatever it exits, go to Step 7, and list every printed `reason:` line in Step 8. Approval belongs to the push, through implement's range review or the PR review, and a local commit can still be undone before then.
A failing-test-only change is committed as `test:`.

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
A merge commit keeps red `test:` commits on the default branch, so bisect with `git bisect start --first-parent`.

## Step 8. Report

After every commit, show the commit hash and subject in one short line. Never commit silently.
Under it, list each file Step 2 or Step 6 left uncommitted and why, each type chosen without confidence, and each `reason:` line from Step 6.
