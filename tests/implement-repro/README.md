# implement reproduction repository

A small shell repository that reproduces two failure patterns, to check that the test policy in `skills/implement` prevents them.
Nothing here is copied from another project.

| Case | Task type | Pattern the policy must prevent |
|---|---|---|
| `missing-precondition` | Bug fix | A regression test that omits the state the bug needs, so it passes on the unfixed code. Here `rates_set` leaves a stale cache entry that only a prior `rates_convert` fills |
| `order-dependence` | Behavior change | A test whose result depends on a shared mutable fixture and on execution order. Here `SHARED_CART` is what the other cart tests reuse |

| Path | Role |
|---|---|
| `template/` | The repository under test: `src/`, `tests/`, and the `.agents/skills.toml` that `gate-tests.sh` reads |
| `cases/<case>.md` | The task text an implement run receives |
| `seeds/<seed>/` | One ready-made commit: its files and a `message`. Seeds replay a defective or a correct run without an LLM |

## Rerun

Without an LLM, `bats tests/implement-repro.bats` shows that `gate-tests.sh` flags each seeded defect for the reason the policy names, and that the reference solutions pass.

With a harness, copy `template/` to a new directory, commit it on `main` with a bare `origin` whose `origin/main` is that commit, and set `refs/remotes/origin/HEAD`.
Then run implement on a case, in each mode:

| Mode | How |
|---|---|
| normal | Tell the harness to read this checkout's `skills/implement/SKILL.md`, never an installed copy, and give the case text as `$ARGUMENTS`. Nobody can answer, so it stops where the skill would ask or open difit |
| autonomous | The same, with a linked worktree made beforehand and `autonomous branch <branch> worktree <path>` as the first line of `$ARGUMENTS` |

Judge the commits it left, in its worktree, from outside the run:

```bash
bash tests/run.sh --seed 1    # also 2 to 5; every run must pass
bash <checkout>/skills/implement/scripts/gate-tests.sh origin/main
```

For `missing-precondition`, also run the final `tests/` against `src/` of `origin/main`: it must fail with a `FAIL:` line and no `ERROR:` line.

## Recorded runs

One run per row on 2026-10-26, on the last commit of this branch, with Claude Code 2.1.310 in headless mode (`claude -p`), on this checkout's own `skills/implement/SKILL.md`.
Every run passed all of the checks above: the suite in default order and shuffled for seeds 1 to 5, `gate-tests.sh` with exit 0, and for `missing-precondition` one `FAIL:` and no `ERROR:` on the unfixed `src/`.

| Harness | Mode | Case | Result | Commits |
|---|---|---|---|---|
| claude 2.1.310 | normal | `missing-precondition` | pass | `test:` that converts before `rates_set`, then `fix:` |
| claude 2.1.310 | autonomous | `missing-precondition` | pass | Same |
| claude 2.1.310 | normal | `order-dependence` | pass | Stub, `test:`, `feat:`, then a `test:` and `fix:` pair; `SHARED_CART` is not used |
| claude 2.1.310 | autonomous | `order-dependence` | pass | Stub, `test:`, `feat:`; `SHARED_CART` is not used |

## Limits

- A run depends on the model, the harness version, and the user's configuration, so a failing run is a result to read, not proof of a regression.
- "No third-party names" is checked as the absence of URLs, e-mail addresses, licence text, and the words GitHub and GitLab under `template/`, `seeds/`, and `cases/`.
- No control run without the skill was made, so a run that avoids both defects does not show that it would have fallen into them without the policy.
