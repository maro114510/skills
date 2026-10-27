# Round boundary

1. Clean up the Issues closed with a merged pull request. A worktree `oe` kept is reported in the output, and never forced:

```bash
oe round cleanup --repo-dir <REPO_DIR> --lease-token <TOKEN>
```

2. Decide whether another round starts. It reads only fresh state:

```bash
oe round next --lease-token <TOKEN>
```

- `continue`: render Round Continuation and go to `round.md`.
- `end`: go on, and render Round Boundary with `reasons`. A merge, or a freeze, may also be what ended it.

3. Check for completion. It posts the completion comment once, and only when every Issue is done or dropped:

```bash
oe round complete --lease-token <TOKEN>
```

`complete` with `posted` renders the completion in the output. Closing the Epic and its containers is the person's own action.

4. End the session cleanly:

```bash
oe lease end --lease-token <TOKEN>
```
