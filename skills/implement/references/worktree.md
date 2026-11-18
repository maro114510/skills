# Worktree

What a run does when the Request names no worktree: the Issue Lock and Phase 4.
A run whose Request names the worktree to work in never reads this file.
Each section below belongs to the SKILL.md phase it names, so Phase numbers match.
The run never asks: wherever a choice is open, it returns Questions as SKILL.md § Questions says, and where another run holds the Issue, it returns Busy.

`<skill-dir>` is the directory containing SKILL.md, the parent of the directory holding this file.

---

## Issue Lock (Phase 0)

Run this when the Request names a GitHub Issue `<N>`, before Phase 1, so a second session handed the same Issue returns Busy before duplicating work.

The Lock is the branch `feat/issue-<N>` on origin, the name `oe claim` creates, so a person's run and the orchestrator see each other. Only one run creates it; nothing releases it, because a Result that leaves the branch in place is how a caller finds the work again.

1. Resolve the base branch from an explicit choice or `refs/remotes/origin/HEAD`. Do not assume `main`. If no trustworthy base can be resolved, end the run before changing Git state, with no Result.
2. Run the script from the repository. It fetches the base and creates the branch on origin at its head only when the branch is absent.

   ```bash
   bash <skill-dir>/scripts/lock.sh <N> <base-branch>
   ```

3. Act on the exit code:

   | Exit | Meaning | Action |
   |---|---|---|
   | 0 | Locked: this run created the branch | Make its worktree as step 4 says, then proceed |
   | 10 | The branch exists, its pull request is merged, and the Issue is still open | Return Questions, because the earlier unit is spent and a new one needs a branch of its own: show the printed `branch=` line and the merged pull request, and recommend splitting the rest of the Issue into a new Issue, or deleting the merged branch on origin so a rerun can lock again |
   | 20 | The branch exists | Return Busy with the printed `branch=` line and, when printed, its `worktree=` line. Take nothing over, and never reuse that worktree or branch: a run resumes earlier work only in a worktree its caller hands it |
   | 2 | Error, such as `origin` unreachable | End the run with the error and no Result |

4. After exit 0, make the worktree now, so that a Questions Result in Phases 1 to 3 can hand the branch and its worktree back. Run `git wt` without a start-point, because `git wt` rejects one for an existing remote branch. If `git wt` fails, the branch stays locked: end the run with the state and no Result.

   ```bash
   git fetch origin feat/issue-<N>
   git wt feat/issue-<N>
   ```

---

## Phase 4: Set Up the Worktree

Skip this phase for an Issue, because step 4 of Issue Lock already made its worktree.

1. Resolve the base branch from an explicit choice or `refs/remotes/origin/HEAD`. Do not assume `main`. If no trustworthy base can be resolved, end the run before changing Git state, with no Result.
2. Update only the remote-tracking ref. Never run `git switch` or `git pull` in the current checkout, because other agents or sessions may share it and rewriting its files disrupts them. If the fetch fails, end the run and report the state.
   ```bash
   git fetch origin <base-branch>
   ```
3. Choose a GitHub Flow branch name such as `feat/add-login` or `fix/null-pointer-on-checkout`, and create the worktree directly from the fetched remote base.
   ```bash
   git wt <branch-name> origin/<base-branch>
   ```

Capture the worktree path that `git wt` prints, because its location depends on configuration. Run every later command in that path. Shell state does not persist between tool calls, so prefix each such command with `cd <worktree-path> && <command>`.

Recheck the relevant files after setup. If the fetched base changed a material premise of the plan, return to Phase 2.
