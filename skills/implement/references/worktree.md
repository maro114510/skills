# Worktree

What a run does when the Request names no worktree: the Issue Claim and Phase 4.
A run whose Request names the worktree to work in never reads this file.
Each section below belongs to the SKILL.md phase it names, so Phase numbers match.
The run never asks: wherever a choice is open, it returns Questions as SKILL.md § Questions says, and where another run holds the Issue, it returns Busy.

`<skill-dir>` is the directory containing SKILL.md, the parent of the directory holding this file.

---

## Issue Claim (Phase 0)

Run this when the Request names a GitHub Issue `<N>`, before Phase 1, so a second session handed the same Issue returns Busy before duplicating work.

The claim is the Git ref `refs/claims/issue-<N>` in this clone, shared by all its worktrees. It never enters history and is not pushed. `git for-each-ref refs/claims` lists claims, and `claim.sh status <N>` shows the owner and its `state=` without changing the claim; it exits 20 whenever the claim is held, by this session too, so compare `owner_token=` with your own.

Inside a [herdr](https://herdr.dev) pane, the claim records the pane, its agent session, and the herdr server, so `state=` tells whether the owner session still runs, for Claude Code, Codex, and opencode alike. `alive=` only says the owner's harness process exists, which stays true for a long-lived process that hosts many sessions. Rerunning `acquire` with this session's own token records the current process and pane again.

| `state=` | Meaning |
|---|---|
| `working` | The owner session is running a turn |
| `blocked` | It waits on an approval or a question |
| `idle`, `done` | It finished its turn and waits for input; `done` means nobody has looked at it yet |
| `gone` | herdr answered and no pane runs the owner session: its pane closed, or the pane switched to another session, as after `/clear`. Unless it was resumed outside herdr, that session no longer runs and will never release the claim |
| `unknown` | Not determinable: the claim was taken outside herdr, by an older version of this script, or by a session herdr could not tie to a pane; the owner's pane shows no agent session for now; or the recording herdr server, herdr, or `jq` is unavailable now |

1. Run the script from the repository. Pass `<token>` only when this session already holds one from an earlier run; otherwise the script prints a new one. Keep the printed `token=` in context, because it, not the process, identifies this session. Whenever this session resumes, as after `--resume`, a fork, or a restart, rerun `acquire` with that token before editing: a resumed session can run under a new session ID, and until it reruns, other sessions read its claim as `gone`.

   ```bash
   CLAIM_PID="$PPID" bash <skill-dir>/scripts/claim.sh acquire <N> [<token>]
   ```

2. Act on the exit code:

   | Exit | Meaning | Action |
   |---|---|---|
   | 0 | Claimed, no branch carries `issue-<N>` | Proceed |
   | 10 | Claimed, and the printed `branch=` lines carry `issue-<N>`, including unlinked ones such as orchestrate-epic's | Unless the Request already chose, return Questions: resume one, or start a separate branch. Show each line, plus the last commit time of each branch, and release the claim first |
   | 20 | Another session holds the claim | Return Busy with the printed owner, including `state=`, and take nothing over. A Request that says to take the claim over runs `claim.sh takeover <N> <token>` with this session's printed `token=`, never `owner_token=`, then acts on its exit code the same way |
   | 2 | Error, such as `origin` unreachable | End the run with the error and no Result. If `token=` was printed, this session still holds the claim: release it. Never go on without a claim |

3. Release the claim with `claim.sh release <N> <token>` before the run returns Questions or Built, and before any other stop that ends it. A later session still finds the branch through exit 10.

---

## Phase 4: Set Up the Worktree

1. Resolve the base branch from an explicit choice or `refs/remotes/origin/HEAD`. Do not assume `main`. If no trustworthy base can be resolved, end the run before changing Git state, with no Result.
2. Update only the remote-tracking ref. Never run `git switch` or `git pull` in the current checkout, because other agents or sessions may share it and rewriting its files disrupts them. If the fetch fails, end the run and report the state.
   ```bash
   git fetch origin <base-branch>
   ```
3. Without an Issue, choose a GitHub Flow branch name such as `feat/add-login` or `fix/null-pointer-on-checkout`, and create the worktree directly from the fetched remote base.
   ```bash
   git wt <branch-name> origin/<base-branch>
   ```
4. For Issue `<N>`, reuse a worktree before creating one. Match by branch, never by directory name: a worktree belongs to the Issue when its `branch refs/heads/<name>` line in `git worktree list --porcelain` names a branch from `gh issue develop --list <N>`.

   A branch whose PR is merged is spent: `gh pr list --head <branch> --state merged` lists one. A squash merge leaves the branch's commits outside the updated base, so reusing it makes `create-pr`'s `<base>...HEAD` review include the earlier unit again. Drop spent branches from the match below, even when the Request chose to resume one in Issue Claim. Reuse a branch only when it has no merged PR.

   | State | Action |
   |---|---|
   | Every matching branch is spent, as when an earlier unit of this Issue merged | Start from the fetched base: create `<type>/issue-<N>-<slug>` as in the "No linked branch exists" row, suffixed with `-2`, or the next number free both locally and on the remote |
   | The Request chose to resume a branch in Issue Claim | Use that branch, linked or not: reuse its worktree, or run `git wt <branch>`, preceded by `git fetch origin <branch>` only when the branch is on the remote |
   | The Request chose a separate branch in Issue Claim | Treat it as no linked branch, and suffix the name with `-2`, or the next number free both locally and on the remote |
   | A worktree for a linked branch exists | Reuse it |
   | A linked branch exists without a worktree | Run `git fetch origin <branch>` and `git wt <branch>` |
   | No linked branch exists | Create `<type>/issue-<N>-<slug>` with the command below, using a Conventional Commits type and a kebab-case slug of the title, then run `git fetch origin <branch>` and `git wt <branch>` |
   | Several branches qualify | Return Questions |
   | `gh issue develop` fails | End the run and report |

   ```bash
   gh issue develop <N> --name <type>/issue-<N>-<slug> --base <base-branch>
   ```

   Run `git wt <branch>` without a start-point, because `git wt` rejects one for an existing remote branch.

Capture the worktree path that `git wt` prints, or the reused path, because its location depends on configuration. Run every later command in that path. Shell state does not persist between tool calls, so prefix each such command with `cd <worktree-path> && <command>`.

Recheck the relevant files after setup. If the fetched base changed a material premise of the plan, return to Phase 2.
