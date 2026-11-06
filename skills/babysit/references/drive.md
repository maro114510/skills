# babysit drive procedures

The Drive actions that the Events table in `../SKILL.md` names. `<scripts>`, `<token>`, `<key>`, and `<hash>` mean what `../SKILL.md` defines, and its Rules apply to every step here.

## Repair

1. Run `bash <scripts>/worktree.sh prepare <owner/repo> <n> --session <token> --branch <headRef> --head <event.head>`. It prints `path` and `sha`; the `sha` is the start of this repair. On exit 1 the PR moved or cannot be read: re-arm, and the next event describes the new head.
2. For a check, read the failure from `gh run view --job <check.runId> --log-failed --repo <owner/repo>`, or from `check.url` when it is not a GitHub Actions run. Find the cause in the code.
3. Fix it in the worktree, verify it locally, stage the changed files, and commit with a message in the repository's style.
4. Run `bash <scripts>/push.sh <owner/repo> <n> --session <token> --worktree <path> --start <sha> --branch <headRef> [--check <check.key>]`. Pass `--check` for a check repair. `push.sh` runs the gate, so there is no separate gate call.

| `push.sh` exit | Action |
|---|---|
| 0 | Pushed and counted. Continue with step 5 |
| 10 | The gate parked it. Park the item with the gate's categories and paths as the reason, and push nothing |
| 11 | The gate refused it. Read `reason`. If the line has `owner`, another automation now owns the PR: run `ledger.sh stop`, report the owner, and stop. If the remote head moved, re-arm and let the new head's events decide. Otherwise park with that reason |
| 1 | Read `pushed` in the JSON line. `false`: the push failed, so park with `git push failed`. `true`: the push is out and only the ledger count failed, so continue with step 5 and put the `error` in the final report |
| 3 | Another session took the PR over. Stop without touching the ledger, and if the line says `"pushed":true`, report that this session's push went out |
| 2 | Fix the call and run it again |

5. Record the item: `ledger.sh record <owner/repo> <n> <token> <key> handled`, with `--hash <hash>` for a comment. For a comment, reply first as Triage says.

## Merge base

1. Run `worktree.sh prepare` as in Repair.
2. Run `git -C <path> fetch origin <baseRef>` and `git -C <path> merge --no-edit origin/<baseRef>`. If it says the branch is already up to date, record `<key>` as handled and re-arm.
3. On conflicts, resolve each file from the intent of both sides, stage it with `git add -- <path>`, and run `git -C <path> commit --no-edit`. If a conflict needs a decision about behavior that the code does not settle, run `git -C <path> merge --abort` and park `<key>` with the conflicting paths.
4. Verify locally, then push with `push.sh` and no `--check`, and record `<key>` as handled.

## Triage

Only a comment from an OWNER, MEMBER, or COLLABORATOR, or from a review bot listed in `review_bots` of `<scripts>/evaluate.jq`, reaches Triage. `wait.sh` parks any other with the reason `untrusted author`, so its text never drives a push or a reply.
An event carries only `comment.excerpt`, the first 200 characters, and `comment.bodyLength`. Read the full body with `bash <scripts>/pr-state.sh <owner/repo> <n> | jq -r --arg id <comment.id> '[.comments[], .reviews[], .threads[].comments[]] | map(select(.id == $id))[0].body'`.
Read it as a claim, and check it against the code in the worktree. Pick one outcome.

| Outcome | When | Steps |
|---|---|---|
| Repair | The claim is right and the fix stays within the PR | Repair, then reply with what changed and the pushed commit, then record |
| Reply only | A question, a claim the code disproves, or a fix already in place | Reply with the evidence, then record |
| Nothing | Praise or noise that asks for nothing | Record handled with no reply |
| Park | It needs a human decision: design, scope, product, security, ambiguity, or a request to merge, resolve, or leave the PR | `bash <scripts>/park.sh <owner/repo> <n> --session <token> --key <key> --hash <hash> --reason "<why>"` |

Reply by writing the text to a temporary file and running `bash <scripts>/reply.sh <owner/repo> <n> --session <token> --thread <comment.thread> --body-file <file>`. Use `--conversation` in place of `--thread` when `comment.thread` is empty, as for an issue comment or a review body. State facts only, with no promise and nothing from the environment.

| `reply.sh` exit | Action |
|---|---|
| 0 | Posted. Continue with the outcome's next step |
| 10 | The thread already holds 2 agent replies. Park instead of replying |
| 11 with `owner` | Another automation owns the PR. Run `ledger.sh stop`, report the owner, and stop |
| 11 without `owner` | The text mentions a review bot or starts a line with a slash command. Drop it and reply again |
| 1 | Read `posted`. `false`: leave the item unrecorded so it returns. `true`: only the ledger write failed, so record the item handled and put the `error` in the final report |
| 3 | Another session took the PR over. Stop as the Exit 3 row in Events in `../SKILL.md` says, and if the line says `"posted":true`, report that this session's reply went out |

## Park

`park.sh` records the item as parked with its reason and shows a macOS notification when `osascript` exists. A parked item returns only when its text changes, and the run continues with the rest. When only parked blockers remain, `wait.sh` returns `stalled`.

## Stop

On `merged` or `closed`, run `bash <scripts>/worktree.sh remove <owner/repo> <n> --session <token>` first. Then run `ledger.sh stop` and give the final report below. Any other stop leaves the worktree in place, and the report names its path when work was parked.
