---
name: pr-verify
description: >
  Verify one orchestrate-epic PR head SHA against every acceptance criterion of its Issue by running the code, then record the verdict with `oe verdict`.
  Started by orchestrate-epic with a brief holding the Issue, the head SHA, the base branch, and a detached worktree at that SHA.
  Never edits, commits, or pushes.
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep
argument-hint: "repo <owner/repo> issue <number> sha <sha> base <branch> worktree <path>"
---

# pr-verify

Check that the code at one SHA meets every acceptance criterion of its Issue, and record the result on that SHA.

`<skill-dir>` is the directory containing this file, and `<skills-root>` is its parent.

## Brief

`$ARGUMENTS` holds the brief: `repo <owner/repo> issue <number> sha <sha> base <branch> worktree <path>`.
If any of the five is missing, end without a verdict and say which.

## Rules

- Read only the Issue's title and body. Never read the PR, its body, or its comments, the Issue's comments, or any report from the Owner, because the verdict must come from the Issue and the code alone.
- Never change `<worktree>`: no edit, commit, push, stash, or checkout. Build and cache output from running a check is allowed, and so are the temporary directories outside it that evidence.md uses.
- Record the verdict only through `oe verdict`, once, for `<sha>`.

## Steps

1. Confirm the worktree: `git -C <worktree> rev-parse HEAD` prints `<sha>`, and `git -C <worktree> symbolic-ref -q HEAD` fails because HEAD is detached. Otherwise end without a verdict and say why.
2. Read the Issue:

   ```bash
   gh issue view <issue> --repo <repo> --json title,body
   ```

   List every acceptance criterion verbatim. If the Issue states none, derive them from its requirements and prefix each with `(derived)`.
3. Find what changed with `git -C <worktree> diff "$(git -C <worktree> merge-base origin/<base> HEAD)"`. If it fails, end without a verdict.
4. Read `<skills-root>/implement/references/evidence.md` and gather evidence for each criterion in the worktree as it defines. Write one line per criterion in its section 5 form. For a criterion with no evidence, write `-> none: <the evidence that would settle it>`. Put an input too long for its line after all criterion lines.
5. Decide the verdict. It is `success` only when every criterion is evidenced. Otherwise it is `failure`. A behavior criterion that nothing available can exercise, such as a UI no tool can drive, has no evidence, so it makes the verdict `failure`.
6. Confirm `git -C <worktree> rev-parse HEAD` still prints `<sha>`, then record the verdict with the criterion lines as findings:

   ```bash
   bash <skills-root>/orchestrate-epic/scripts/oe verdict <repo> <issue> <sha> <success|failure> <<'EOF'
   <one line per criterion>
   EOF
   ```

   Exit 0 means it was recorded. Any other exit means nothing was recorded: do not retry.

## Output

End with one line, `VERDICT: success`, `VERDICT: failure`, or `VERDICT: none`, followed by the reason when it is `none`, such as a missing brief item, a worktree not at `<sha>`, or `oe verdict` exiting non-zero.
