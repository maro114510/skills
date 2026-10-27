# Round

A round reads GitHub afresh. Nothing carries over from an earlier round except what `oe round` keeps for this session.

1. Plan the round. This also begins it:

```bash
oe round plan --lease-token <TOKEN>
```

The payload has `signals`, `freeze`, `work`, `landing`, `stale_waiting`, `left_out`, and `deferred`.

2. Apply the human decisions first, one call for each Issue in `signals`:

```bash
oe state apply-signals --issue <N> --lease-token <TOKEN>
```

3. If `freeze` is not null, freeze the Epic with its fields, render Frozen Epic, and stop the round. The call always exits 4:

```bash
oe ledger freeze --reason <REASON> --merge <MERGE> --health <HEALTH> --lease-token <TOKEN>
```

4. Update the base once, serially. Workers and `oe` never fetch it:

```bash
git fetch origin <DEFAULT_BRANCH>
```

5. Make a file for CHECKS_SET, then derive CHECKS_SET into it. Every later call of this round names that file as `--checks-set`:

```bash
mktemp
```

```bash
oe checks derive >"<CHECKS_FILE>"
```

6. Post the notes the board proposed, once each:

```bash
oe round notify --lease-token <TOKEN>
```

7. Go on with `work` in `dispatch.md`. When `work` and `landing` are both empty, go to `boundary.md`.

`left_out` names the Issues the cap left out. The next round starts them, and Round Boundary says so.
