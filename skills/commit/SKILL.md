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

If `git status --short` holds any change this session did not make itself, touch nothing, including your own changes, and ask the user once via `AskUserQuestion`.
When no human can answer, as in an autonomous run, do not ask or wait: end with `STOPPED: foreign changes` and the paths.

## Step 2. Screen for secrets (always blocks auto-commit)

Cover staged, unstaged, and untracked changes: a suspected secret never ends up in a commit, however it got into the working tree.

- **Filenames** in `git status --short`: `.env*`, `*.pem`, `*.key`, `id_rsa*`, `*credentials*`, `*secret*`, `*.p12`, `service-account*.json`, and similar.
- **Content** of the staged and unstaged diff, since a token can sit in an ordinary file such as `config.yaml`: AWS keys `AKIA[0-9A-Z]{16}`, private key headers `-----BEGIN [A-Z ]*PRIVATE KEY-----`, GitHub tokens `gh[pousr]_[A-Za-z0-9]{20,}`, OpenAI or Anthropic-style keys `\bsk-[A-Za-z0-9_-]{20,}` (covers `sk-ant-api03-…` and `sk-proj-…`), Slack tokens `xox[baprs]-`, and a literal-looking value assigned to `password` or `token`.

This is a best-effort heuristic: when in doubt, treat it as a match. For every match:

- If the file is staged, unstage it: `git restore --staged -- <path>`.
- Never `git add` it, even in auto-commit mode.
- Tell the user which files, or which lines for a content match, were excluded and why, and ask what to do with them. This always needs a human decision, whatever Step 6 decides.
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

## Step 6. Decide: auto-commit or ask first

One classifier decides, `<skill-dir>/scripts/classify-approval.sh`; its header lists the conditions. Its path, size, and deletion conditions are mechanical, and no repository setting changes them. Pass what only you can judge as `--require <reason>`, one per finding:

- The diff mixes clearly unrelated concerns, such as an unrelated `fix` bundled with a `feat`.
- Some changed files look unrelated to the rest, possibly stray edits in the same working tree.
- A confident Conventional Commits type/scope cannot be determined.
- The caller reports a critical decision from its decision log: `--require "critical decision: <decision>"`.

```bash
bash <skill-dir>/scripts/classify-approval.sh --staged [--require "<reason>"]...
```

| Exit | Action |
|---|---|
| 0 | Go to Step 7 and commit without asking |
| 10 or any other | Ask via `AskUserQuestion` before committing, showing the `reason:` lines, the staged diff summary, and the message after Step 5 |

Two cases skip asking about the mechanical `reason:` lines and the caller's critical decisions; commit and list them in Step 8:

- The caller reports it classifies the whole `base..HEAD` range with this classifier before push and gets human approval when the range needs it, as implement does in normal mode. Leave its critical decisions out here: the range classification covers them, since a path counts when any commit in the range touches it.
- A difit window you opened closed with no comments, and `git status --porcelain` and the hash of `git diff HEAD`, both recorded when it opened, are unchanged at commit time.

Your own findings above are still asked about in both, since they concern how this commit is cut, which a range review cannot fix; for a type/scope you cannot determine confidently, ask about the message only.
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
A merge commit keeps red `test:` commits on the default branch, so bisect with `git bisect start --first-parent`.

## Step 8. Report

After every commit, auto or approved, show the commit hash and subject in one short line. Never commit silently.
