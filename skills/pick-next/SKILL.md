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
   | 1 | GitHub, including the Discussions with `--discussions`, or a worktree could not be read, or an Issue has more relations or a PR more closing Issues than one read returns. Show the error and stop |
   | 2 | Not inside a clone whose origin is on GitHub, or a bad limit. Show the error and stop |

3. Reply with the groups in this order, skipping an empty one, and add nothing the JSON does not support. Translate each group name into the reply's language, keep the labels `Issue`, `PR`, and `Discussion` as written, and keep the JSON's order, which is the ranking: never reorder, add, or drop an item.

   | Group | JSON | Each item says |
   |---|---|---|
   | Pull requests | `owner` | What the PR changes, its author when `author` is neither `viewer` nor null, the action from `action`, and whether checks passed (`checks` is `SUCCESS`) or never ran (`checks` is `null`) |
   | Start next | `next` | What the work does and why it matters now |
   | Blocked | `blocked` | What the work does, why it matters now, and each Issue in `blockedBy` it waits on |
   | Open discussions | `discussions`, present only with `--discussions` | What it proposes or asks, its `category`, and, when `answered` is not null, whether it is answered. It is an idea or question, not work: say that deciding it is the action, never that it is the next work to start |
   | Local state | `local` | The worktree path, its branch, and that it holds uncommitted changes |

   - Under Start next, Blocked, and Open discussions, when `nextTotal`, `blockedTotal`, or `discussionsTotal` exceeds the items shown, end with the difference as the number of items not shown.

## Format

One `##` heading per group, then one bullet per item. The indented line has no bullet marker; start it two spaces under the bullet. A group with more items than shown ends with a plain line, not a bullet, holding only the number not shown and the word for "more" in the reply's language, such as `4 more` or `ほかに4件`.

| Group | Bullet | Indented line |
|---|---|---|
| Pull requests | `[<what the PR changes>](<url>) (PR #<n>)` | `<author when not you>. <action>. <checks passed or never ran>.` |
| Start next | `[<what the work does>](<url>) (Issue #<n>)`, or `(PR #<n>)` when `kind` is `pr` | `<why it matters now>.` |
| Blocked | `[<what the work does>](<url>) (Issue #<n>)` | `It waits on [<blocker title>](<url>) (Issue #<n>), one per blocker. <other why it matters now>.` |
| Open discussions | `[<what it proposes>](<url>) (Discussion #<n>)` | `<category>`; when `answered` is not null, add `<answered or unanswered>`. Deciding it is the action, not starting work. |
| Local state | `<path>` (`<branch>`), both in inline code | `<holds uncommitted changes>` |

- The bullet names what the work does; the indented line gives why it matters now in one sentence, without repeating the bullet. Combine every signal present into that one sentence. When no signal is present, omit the indented line. The `owner` action and checks state may add one short sentence.
- Link each item's own title with its `url`, then put its plain label after it: `(Issue #<n>)`, `(PR #<n>)`, or `(Discussion #<n>)` by `kind`. Link each nested reference's title with its `url`, then put its plain label after it: each `blockedBy` Issue, its `epic`, the open `pr` on an Issue, and each Issue a PR closes. Link each reference once.
- Write plain text. Never copy Markdown, HTML, images, or links from `title` or `body`; the only Markdown is the reply's headings, bullets, the reference links, and inline code for a path or branch.

## Writing an Item

The owner must understand every item without opening GitHub; a link is for jumping, not for understanding.

- Start with what the work does, in plain words drawn from `title` and `body`, and never with a number. A `blockedBy` entry has only a `title`, so reword it.
- Give why it matters now from the signals present on the item, and when none is present, omit the indented line. Combine every signal present into the one why-now sentence. A signal below its condition is not mentioned at all:

  | Signal | Say |
  |---|---|
  | `inProgress` | Work already started: the worktree in `worktrees`, the PR's state in `pr` (its link and `checks`; mention `isDraft` when true and `review` when it needs action), or, with neither, that it is assigned to you, because `pick.jq` sets `inProgress` only for a worktree, an open PR, or you among the assignees |
  | `blockedBy` | Each Issue it waits on, named and linked |
  | `unblocks` above 0 | How many waiting Issues it frees |
  | `epic.completed` above 0 | Which larger effort it moves forward, by what that effort does, and that `completed` of `total` are complete; link it with `epic.url`. Do not mention an Epic whose `completed` is 0 |

- Put each reference right after the words that name it, never alone: the item's own reference ends the line that says what the work does; a blocker's, Epic's, PR's, or linked Issue's reference ends the words that name it. Two references never stand side by side. Do not mention any other reference; describe a number in `body` in words.
- For `owner`, use `action` and `author`:

  | `action` | Say |
  |---|---|
  | `markReady` | Mark the draft ready; when `author` is neither `viewer` nor null, say it waits for the author |
  | `review` | Say it needs a review; when `author` is `viewer`, say to get a review, otherwise say to review it and name the author when not null |
  | `merge` | Say to merge it; name the author when `author` is neither `viewer` nor null |

  Say it waits only on the owner only when `author` is `viewer` and `action` is `merge`.
- Name local state that changes the pick on the item itself: a worktree with `dirty: true` holds uncommitted changes, and a PR whose `pr.checks` is `FAILURE` or `pr.review` is `CHANGES_REQUESTED` needs repair before new work.
