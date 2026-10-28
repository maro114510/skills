# Entry

1. Resolve the inputs once and keep `default_branch` from the payload:

```bash
oe resolve
```

2. Take the lease. `--pid` is the process id of your harness, so that a second Publisher on this host can tell the lease is held. `$PPID` in the same call is that process in Claude Code, Codex, and OpenCode:

```bash
oe lease acquire --pid "$PPID"
```

Keep `token` from the payload. To resume a session you hold the token of, add `--lease-token <TOKEN>`. Exit 7 means another session holds the lease: stop, and never take it over.

3. Pass the entry gate:

```bash
oe gate --lease-token <TOKEN>
```

| `status` | Exit | You |
|---|---|---|
| `run-plan-posted` | 8 | Render Approval Needed, end the lease, and stop. `oe` posted the Run Plan once |
| `awaiting-approval` | 8 | Render Approval Needed, end the lease, and stop |
| `frozen` | 4 | Render Frozen Epic, end the lease, and stop. The freeze note went out once, and you post nothing |
| `approved` | 0 | Go on. `merge_authorized` says whether landing may merge |

Any other status, or exit 1, 6, or 7, stops the run: report the verdict line. Ending the lease is one call. Skip it only when the verdict says another session holds the lease, that this session lost it, or that its lease was ended:

```bash
oe lease end --lease-token <TOKEN>
```
