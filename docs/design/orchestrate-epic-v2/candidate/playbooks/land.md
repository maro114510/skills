# Land

Landing runs on every invocation after shipping, including one that dispatched nothing. It takes one pull request at a time, in the order of the plan's `landing`, which is ascending Issue number. A stale candidate goes through `review.md` first; the plan allows only one at a time.

For each candidate, merge it or settle it:

```bash
oe land merge --issue <N> --lease-token <TOKEN>
```

| Result | You |
|---|---|
| `MERGED`, `next` `rescan` | The pass ends. Go to the poll below |
| `HELD`, `next` `repair` | `oe land repair`, below |
| `HELD`, `next` `human` | Nothing more. `oe` posted the hold once |
| Exit 8 | Read the verdict line. When it says to run `oe ship publish` first or again, a publish was interrupted before it was recorded as linked, so the pull request is not landable yet: run `playbooks/ship.md` for the Issue, which resumes it, then land again. Otherwise it is no merge grant, or another failed precondition: leave the pull request open for the person |
| `HEAD_MOVED`, exit 3 | Pin again with `review.md` |
| Exit 5 | The last merge's checks are pending: poll |
| Exit 4 | Stop landing. Render Frozen Epic when the Epic froze |

Never run another merge before `oe land merge` has recorded the last one. Never retry a merge that came back `UNKNOWN`.

## Repair

A repair is a fix cycle under the same cap and budget:

```bash
oe land repair --issue <N> --lease-token <TOKEN>
```

`REPAIR` means the failed checks, the conflict, or the trusted review feedback were handed over. A fresh worker starts from the pending findings in the next dispatch. `PARKED` and `HELD` mean nothing more.

## Poll

After a pass that did not end in a merge, and after a merge:

```bash
oe round poll --lease-token <TOKEN>
```

| `decision` | You |
|---|---|
| `pass` | A merge was recorded. Land again at once |
| `sleep` | Sleep `sleep_seconds` in a call of its own, then land again |
| `stop` | Stop landing for this invocation and list `waiting` in Round Boundary |
| `settled` | Landing ends. `human` lists the pull requests only a person moves |

```bash
sleep 60
```
