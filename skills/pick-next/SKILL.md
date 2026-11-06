---
name: pick-next
description: >
  Pick what to work on next in the current repository: what waits on the owner, the few Issues or PRs to start next, and what is blocked and on what, each explained in plain words.
  With discussions, also lists the open Discussions, the ideas and questions not yet turned into work.
  Use when the user asks "what should I work on next", "what's next", "which Issue next", "pick the next task", "次に何やる", "次どのIssueやればいい", "今やるべきことは", or "Discussionも含めて".
  Not for one Epic's run, which orchestrate-epic's oe ready covers.
allowed-tools: Bash, Read
argument-hint: "[lang <ja|en>] [limit <n>] [discussions]"
---

# pick-next

Answer "what should I work on next" from one read of the repository, so the order is the same in every session.
It only reads: never create, switch, edit, or close an Issue, PR, branch, or worktree.

`<scripts>` is the `scripts/` directory next to this file, and `<skills-root>` is the parent of this skill's directory.

## Steps

1. Run `bash <skills-root>/create-pr/scripts/lang.sh [<value after lang in $ARGUMENTS>]`. On a non-zero exit, show its output and stop. Write the whole reply, headings included, in the language its first word names.
2. Run `bash <scripts>/pick.sh [--limit <value after limit in $ARGUMENTS>] [--discussions]` from the repository, adding `--discussions` only when `$ARGUMENTS` holds the word `discussions`. It prints one JSON object, already grouped and ordered by `<scripts>/pick.jq`, holding at most 3 items each in `next`, `blocked`, and, with `--discussions`, `discussions`, unless a limit is given.

   | Exit | Action |
   |---|---|
   | 0 | Continue with step 3 |
   | 1 | GitHub, including the Discussions with `--discussions`, or a worktree could not be read, or an Issue has more relations than one read returns. Show the error and stop |
   | 2 | Not inside a clone whose origin is on GitHub, or a bad limit. Show the error and stop |

3. Reply with the groups in this order, skipping an empty one, and add nothing the JSON does not support. Translate each group name into the reply's language, and keep the reference forms under Writing an Item as written in every language.

   | Group | JSON | Each item says |
   |---|---|---|
   | Waits on you | `owner` | What the PR changes, then the owner's action: mark it ready when `isDraft` is true, otherwise review and merge it, and that it waits only on the owner because its checks passed (`checks` is `SUCCESS`) or never ran (`checks` is null) |
   | Start next | `next` | What the work does and why it matters now |
   | Blocked | `blocked` | What the work does, why it matters now, and each Issue in `blockedBy` it waits on |
   | Open discussions | `discussions`, present only with `--discussions` | What it proposes or asks, its `category`, and, when `answered` is not null, whether it is answered. It is an idea or question, not work: say that deciding it is the action, never that it is the next work to start |
   | Local state | `local` | The worktree path, its branch, and that it holds uncommitted changes |

   - Keep the JSON's order, which is the ranking. Never reorder, add, or drop an item.
   - Under Start next, Blocked, and Open discussions, when `nextTotal`, `blockedTotal`, or `discussionsTotal` exceeds the items shown, end with the difference as the number of items not shown.

## Writing an Item

The owner must understand every item without opening GitHub.

- Start with what the work does, in plain words drawn from `title` and `body`, and never with a number. A `blockedBy` entry has only a `title`, so reword it.
- Give why it matters now from the signals present on the item, and when none is present, say only what it does. A signal below its condition is not mentioned at all:

  | Signal | Say |
  |---|---|
  | `inProgress` | Work already started: the worktree in `worktrees`, the PR's state in `pr`, or, with neither, that it is assigned to you, because `pick.jq` sets `inProgress` only for a worktree, an open PR, or you among the assignees |
  | `unblocks` above 0 | How many waiting Issues it frees |
  | `epic` with `completed` above 0 | Which larger effort it moves forward, by what that effort does, and its progress as `completed` of `total` |

- Put each reference, as `(Issue <number>)`, `(PR <number>)`, or `(Discussion <number>)`, right after the words that describe what it names, never alone: the item's own reference ends the sentence that says what the work does, and a blocker's reference ends the words that name the blocker. Two references never stand side by side. An item carries no other reference: describe its Epic, its PR, its linked Issues, and any number in its `body` in words only.
- Name local state that changes the pick on the item itself: a worktree with `dirty: true` holds uncommitted changes, and a PR whose `pr.checks` is `FAILURE` needs repair before new work.
