# Review

For each Issue whose `next` is `review`, and for each `reverify` item of the plan:

1. Pin the pair. `oe` merges the pinned default branch into the branch, the one commit the loop makes, and prints the reviewer's whole prompt:

```bash
oe review pin --issue <N> --worktree <WORKTREE> --checks-set <CHECKS_FILE> --repo-dir <REPO_DIR> --lease-token <TOKEN>
```

`PINNED` with `next` `review` goes on. `BOUND` with `next` `ship` means an approval already holds the pair: go to `ship.md`. A conflict or an uncommitted change comes back with a `next`: follow it.

2. Reserve once for the whole batch of reviewers, before any spawn. A staleness re-verification, which is a `reverify` pass, is not charged: leave it out of the count. Exit 4 means the Epic froze: spawn nothing and stop:

```bash
oe ledger reserve --reviewer-passes <COUNT> --lease-token <TOKEN>
```

3. Spawn one `issue-reviewer` for each pinned Issue, all in one message, passing `prompt` verbatim. Never add the worker's report.

4. When a reviewer returns, write its final message, unchanged, to a file the way `dispatch.md` writes a report, and bind it:

```bash
oe review verdict --issue <N> --worktree <WORKTREE> --checks-set <CHECKS_FILE> --repo-dir <REPO_DIR> --file "$f" --lease-token <TOKEN>
```

Add `--ship-class <kind>` when a finding is ship-class, judged as in `dispatch.md`. A finding that holds a suspected secret is parked by `oe` itself.

| `route` | `next` | You |
|---|---|---|
| `BOUND` | `ship` | `ship.md` |
| `FIX` | `redispatch` | A fresh worker with the findings, which `oe` reserved as a fix cycle |
| `STALE` | `reverify` or `defer` | Pin again, or defer, as the router says |
| `PARKED` | `parked` | Nothing more |
| `MALFORMED` | none | Exit 8, nothing written. Spawn a fresh reviewer |
