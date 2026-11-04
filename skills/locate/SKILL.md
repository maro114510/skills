---
name: locate
description: >
  Find the local worktree and branch for a GitHub pull request or Issue URL, and
  state whether it is open or merged, its unresolved review threads, and its
  failing checks, before any work on it starts. Use whenever a PR or Issue URL
  arrives without the worktree named, such as a pasted URL alone, "pick this PR
  back up", "find the worktree for this PR", "address the review on <url>",
  "このPRのworktreeどこ", or "このIssueの続きをやって". Not inside implement,
  which resolves its own worktree.
allowed-tools: Bash, Read
argument-hint: "<pr-url | issue-url>"
---

# locate

Turn a URL into the worktree, branch, and current state, so the user never has to name them.
It only reads: never create, switch, reset, or remove a worktree or branch.

## Steps

1. Take the PR or Issue URL from `$ARGUMENTS` or the conversation. If there is none, ask for it.
2. Run `bash <scripts>/locate.sh <url>` from the repository, where `<scripts>` is the `scripts/` directory next to this file. It prints one JSON line.

   | Exit | Action |
   |---|---|
   | 0 | Continue with step 3 |
   | 1 | GitHub could not be read. Show the error and stop |
   | 2 | Not a PR or Issue URL, or not inside a clone. Show the error and stop |
   | 3 | The URL belongs to another repository than this clone's origin. Ask the user for the path of that repository's clone and rerun there |

3. Begin the first reply with the resolution, before any other action:

   ```
   <PR or Issue> <repo>#<number>: <state>
   Worktree: <path> (branch <branch>)
   Threads unresolved: <unresolvedThreads> / Checks failing: <failingChecks names, or none> / Pending: <pendingChecks>
   ```

   - Write one `Worktree:` line per entry in `worktrees`. With none, write `Worktree: none (branches <branches, or none>)`.
   - The thread and check line is for a PR only. For an Issue, add `stateReason` when it is set.

4. Act on `match` and `state` together, top row first:

   | Condition | Action |
   |---|---|
   | `state` is `MERGED` or `CLOSED` | Report it and start no work on any listed branch. A merged branch is spent: new work belongs on a new branch from the base |
   | `match` is `many` | List every worktree with its branch and ask which one to use. Never pick one yourself |
   | `match` is `none` | Name the candidate branches, say no worktree has them checked out, and ask before creating one |
   | `match` is `one` | Continue the user's request in that worktree. Prefix each command with `cd <path> &&` |

   `isCrossRepository: true` means the PR comes from a fork, so a local branch of the same name may be unrelated. Say so.
