# PR Creation Result

create-pr's Step 6.2 reads this file in full after the Step 6.1 command exits.
Step numbers below are SKILL.md's.

## 6.2 Handle the Exit

| Exit | Action |
|---|---|
| 0 | Continue to 6.3 |
| 3 | `LINK_MISSING`: rerun once as `create-linked-pr.sh --link <url>`, without the push. If still missing, ask the user to link it from the Development sidebar |
| 4 | `NOT_PUSHED`: rerun the 6.1 command once, which pushes again |
| Any other non-zero | Show the output verbatim and stop |

## 6.3 Finish

Run nothing more: the output holds the PR URL and every link, and `--web` already opened it.
Show the PR URL, whether it is draft or ready, every linked issue, and any `NOTICE` or `WARN` line verbatim.
If a `NOTICE` rewrote an issue to `Related` while a commit footer still says `Closes` for it, warn that merging would still close the issue through that footer, even with a squash merge under GitHub's default message; edit the squash message or reword the footer before merging.
If a `NOTICE` kept `Closes` unlinked on a non-default base, tell the user to run `create-linked-pr.sh --link <url>` once the PR is retargeted to the default branch.
