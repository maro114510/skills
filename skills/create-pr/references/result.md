# PR Creation Result

create-pr's Step 6.3 reads this file in full after the Step 6.2 command exits.
Step numbers below are SKILL.md's.

## 6.3 Handle the Exit

| Exit | Action |
|---|---|
| 0 | Continue to 6.4 |
| 3 | `LINK_MISSING`: rerun once as `bash <skill-dir>/scripts/create-linked-pr.sh --link <url>`, without the push. If still missing, ask the user to link it from the Development sidebar |
| 4 | `NOT_PUSHED`: rerun the 6.2 command once, which pushes again |
| Any other non-zero | Stop as SKILL.md Step 1 stops: the output verbatim, then the cause and the user's next step, such as updating a PR that already exists |

A rerun's own exit goes through this table again, except that a second 3 or 4 is not rerun: it takes that row's "if still missing" action, or for 4 stops as the last row says.

## 6.4 Finish

Run nothing more: the output holds the PR URL and every link, and `--web` already opened it. "The output" means every run's output from 6.2 and 6.3 together, since a `NOTICE` printed before a rerun is not printed again.
Show the PR URL, whether it is draft or ready, each issue as `Closes` and linked, `Related`, or still unlinked after the rerun, and every `NOTICE` or `WARN` line verbatim.
If a `NOTICE` rewrote an issue to `Related` while a commit footer still says `Closes` for it, warn that merging would still close the issue through that footer, even with a squash merge under GitHub's default message; edit the squash message or reword the footer before merging.
If a `NOTICE` kept `Closes` unlinked on a non-default base, tell the user to run `create-linked-pr.sh --link <url>` once the PR is retargeted to the default branch.
If a `NOTICE` skipped linking because the GraphQL rate limit is exhausted, say the link was skipped and tell the user to run `create-linked-pr.sh --link <url>` once the limit resets; until then only the body's `Closes` line links the issue, which GitHub can take hours to do.
