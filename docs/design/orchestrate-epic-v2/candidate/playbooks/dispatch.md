# Dispatch

`work` holds at most `max-parallel` items, each with `kind`, `issue`, `branch`, and `resume`. A `reverify` item spawns no worker, but a restarted Publisher has no path for its worktree: run step 2 for it, which spawns and charges nothing. Then check that the DONE report file of the Issue is still there, see the end of step 6. Only then does it go to `review.md`. Every `dispatch` item goes through the steps below. Do steps 1 to 4 serially, then spawn every worker of the batch in one message, so that they run in parallel.

A fresh worker for an Issue whose `next` is `redispatch` joins the same batch from step 2, in the same round. `oe` reserved the fix cycle already, but it never reserves a worker spawn: step 4 does, for every worker, a first dispatch and a re-dispatch alike. A worker is never spawned without it.

1. Make sure the Issue has a state, which only this command creates. An Issue that already has one is refused with exit 8 and the words "already has a state": that is fine, go on. Any other refusal means the Issue is not ready to dispatch: skip it.

```bash
oe state start --issue <N> --lease-token <TOKEN>
```

2. Create or reuse its worktree, and keep `worktree` from the payload:

```bash
oe worker worktree --issue <N> --repo-dir <REPO_DIR> --lease-token <TOKEN>
```

3. Render the worker's whole prompt. Exit 8 may mean a human comment is not consumed yet. Run `oe state apply-signals` for the Issue, then step 2 again, and only then this call: an `epic-redo` records a new branch, so the worktree has to be made again, and a decision that parked or dropped the Issue makes `oe worker worktree` refuse it, in which case skip the Issue. Never call `oe round plan` again for this, since that begins another round:

```bash
oe worker brief --issue <N> --worktree <WORKTREE> --implement <IMPLEMENT> --checks-set <CHECKS_FILE> --repo-dir <REPO_DIR> --lease-token <TOKEN>
```

4. Reserve once for the whole batch, before any spawn. Exit 4 means the Epic froze: spawn nothing, render Frozen Epic, and stop:

```bash
oe ledger reserve --worker-dispatches <COUNT> --lease-token <TOKEN>
```

5. Spawn one `issue-implementer` for each item, all in one message, passing the brief's `prompt` verbatim and nothing else. Never continue an agent that ran before.

6. When a worker returns, write its final message, unchanged, to a file of its own. Make the file, then write and route it in one call with the path `mktemp` printed:

```bash
mktemp
```

```bash
f="<REPORT_FILE>"
cat >"$f" <<'REPORT'
<the worker's final message, unchanged>
REPORT
oe worker report --issue <N> --worktree <WORKTREE> --repo-dir <REPO_DIR> --file "$f" --lease-token <TOKEN>
```

Keep the file until the Issue's pull request is merged, because `oe ship publish` reads the same report, and refuses without it. GitHub holds only the skips and decisions of a report, never its checks, so nothing can recreate the file. When a restart lost it, which is the usual case for a stale pull request planned in a later invocation, run steps 2 to 6 again with a fresh worker, reserved as step 4 says. It finds its work committed, and its new DONE report becomes the file. The Issue is then reviewed again before it ships.

## Judgment on a BLOCKED report

- A question is ship-class when it asks whether to go on with a suspected secret (`secret`), whether a change must be split before it ships (`split`), or whether something is in scope (`scope`). Add `--ship-class <kind>` to the call above. There is no exception for a scope dispute: every one parks the Issue, and you never pick a reading. A ship-class question is never answered by the loop.
- A question that asks to approve a commit takes `--commit-approval` and is never answered by the loop.
- Any other question you answer only from what is written down: the Epic body, the Issue body, its comments, and this conversation. When every question has a written answer, write the answer to a file the same way and add `--answer-file <ANSWER_FILE>`; `oe` posts it once for the session. When one has none, add nothing, and the Issue waits for a person. Never answer from your own judgment.

Then follow `next` in the router. A worker that returns nothing counts as FAILED: pass an empty report.
