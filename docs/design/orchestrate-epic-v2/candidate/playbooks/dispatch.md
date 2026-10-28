# Dispatch

`work` holds at most `max-parallel` items, each with `kind`, `issue`, `branch`, and `resume`. A `reverify` item spawns no worker, but a restarted Publisher has no path for its worktree: run step 2 for it, which spawns and charges nothing, then pin it with step 1 of `review.md` before anything is spent. Two cases the loop cannot repair stop for a person: report the Issue with Escalation, then `oe round defer --issue <N> --reason stale` so that no later round plans it again. One is a pull request with no Issue state, which a person opened and `oe worker worktree` refuses; the loop never adopts one. The other is a pin that answers `BOUND`, since the approval then still matches the recorded pair, and the staleness is a pull request head someone pushed outside the loop, which `oe ship publish` and `oe land merge` would only bounce back. Only after the pin answers `PINNED`, read the report file of the Issue, see step 6, and if it is gone stop for a person as step 6 says. Otherwise it goes on in `review.md`. A pull request head pushed outside the loop can still reach this point when the default branch also moved, because the approval is then stale and the pin answers `PINNED`. It costs one reviewer pass and no worker: `oe ship publish` refuses an unexplained remote head with an `external-push` note, which ship.md reports. An item with `resume` true may already hold a bound approval: a restart between `oe review verdict` and `oe ship publish` leaves an Issue with state, no pull request, and an approval, which the board plans as a resumed dispatch. Before any worker is reserved, make sure the Issue has a state with step 1, since a branch a person made by hand has none, then run step 2 for it and pin it with step 1 of `review.md`. `BOUND` means an approval holds the recorded pair: go to `ship.md` and spawn no worker, once the report file is read as for a `reverify` item. `PINNED` means the pair is new: read the report file the same way before the reviewer is reserved, and if it is gone, stop for a person as step 6 says, since a reviewer would be paid for a ship that `oe ship publish` refuses. Exit 8 means no head is recorded yet, because no worker has reported, so the item is dispatched below. A worker that then reports clears any approval, and its work is reviewed again. Every `dispatch` item goes through the steps below. Do steps 1 to 4 serially, then spawn every worker of the batch in one message, so that they run in parallel.

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

6. When a worker returns, write its final message, unchanged, to the report file of the Issue and route it, in one call. The file lives in the sessions directory of the `oe` state directory, `$XDG_STATE_HOME/oe/sessions` or, when that is unset, `$HOME/.local/state/oe/sessions`, written out as an absolute path. `oe round plan` creates that directory readable by its owner only, so nothing else can read the report or plant a link at its name, and every round plans before it dispatches. The name is `report-<OWNER>_<REPO>-<EPIC>-<N>.md`. A GitHub owner name holds no underscore, so the first underscore ends it and the name is the same for one repository only, and a restarted Publisher finds the file again. The heredoc ends at a delimiter line, and the message is agent output, so a fixed word could end it early and run the rest of the message as shell. Use the delimiter below with the twelve hex characters replaced by fresh random ones for every report, and check that no line of the message equals it:

```bash
f="<STATE_DIR>/sessions/report-<OWNER>_<REPO>-<EPIC>-<N>.md"
cat >"$f" <<'REPORT_8F3A9C1D27E4'
<the worker's final message, unchanged>
REPORT_8F3A9C1D27E4
oe worker report --issue <N> --worktree <WORKTREE> --repo-dir <REPO_DIR> --file "$f" --lease-token <TOKEN>
```

Keep the file until the Issue's pull request is merged, because `oe ship publish` reads the same report, and refuses without it. GitHub holds only the skips and decisions of a report, never its checks, so nothing can recreate it. A lost file is therefore a case for a person: spend nothing to rebuild it, report the Issue with Escalation, and `oe round defer --issue <N> --reason stale`.

## Judgment on a BLOCKED report

- A question is ship-class when it asks whether to go on with a suspected secret (`secret`), whether a change must be split before it ships (`split`), or whether something is in scope (`scope`). Add `--ship-class <kind>` to the call above. There is no exception for a scope dispute: every one parks the Issue, and you never pick a reading. A ship-class question is never answered by the loop.
- A question that asks to approve a commit takes `--commit-approval` and is never answered by the loop.
- Any other question you answer only from what is written down: the Epic body, the Issue body, its comments, and this conversation. When every question has a written answer, write the answer to a file the same way and add `--answer-file <ANSWER_FILE>`; `oe` posts it once for the session. When one has none, add nothing, and the Issue waits for a person. Never answer from your own judgment.

Then follow `next` in the router. A worker that returns nothing counts as FAILED: pass an empty report.
