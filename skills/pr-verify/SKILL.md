---
name: pr-verify
description: >
  Verify one orchestrate-epic PR head SHA against its Issue's automated checks by running the code, leaving manual checks to the engineer, then record the verdict with `oe verdict`.
  Started by orchestrate-epic with a brief holding the Issue, the head SHA, the base branch, and a detached worktree at that SHA.
  Never edits, commits, or pushes.
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep
argument-hint: "repo <owner/repo> issue <number> sha <sha> base <branch> worktree <path>"
---

# pr-verify

Check that the code at one SHA meets every automated check of its Issue, and record the result on that SHA. Manual checks are the engineer's.

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

   List the checks to judge verbatim. When the `Verification` or `検証方法` section has an `Automated checks`, `自動確認`, `Manual checks`, or `手動確認` heading, judge only the items under the automated one, and list each manual item as `<item> -> manual`. Otherwise judge every acceptance criterion; if the Issue states none, derive them from its requirements and prefix each with `(derived)`.
3. Find what changed with `git -C <worktree> diff "$(git -C <worktree> merge-base origin/<base> HEAD)"`. If it fails, end without a verdict.
4. Read `<skills-root>/implement/references/evidence.md` and gather evidence for each check to judge in the worktree as it defines. Write one line per check in its section 5 form, the step 2 manual lines included. For a check with no evidence, write `-> none: <the evidence that would settle it>`. Put an input too long for its line after all check lines.
5. Decide the verdict. It is `success` only when every judged check is evidenced, including when none is judged. Otherwise it is `failure`. A behavior check that nothing available can exercise, such as a UI no tool can drive, has no evidence, so it makes the verdict `failure`.
6. Confirm `git -C <worktree> rev-parse HEAD` still prints `<sha>`, then record the verdict with the step 4 lines as findings:

   ```bash
   bash <skills-root>/orchestrate-epic/scripts/oe verdict <repo> <issue> <sha> <success|failure> <<'EOF'
   <the step 4 lines>
   EOF
   ```

   Exit 0 means it was recorded. Any other exit means nothing was recorded: do not retry.

## Output

End with one line, `VERDICT: success`, `VERDICT: failure`, or `VERDICT: none`, followed by the reason when it is `none`, such as a missing brief item, a worktree not at `<sha>`, or `oe verdict` exiting non-zero.
