# implement reproduction repository

A small shell repository that reproduces two failure patterns, to see how an implement run handles them under the test policy in `skills/implement`.
It shows that the template's runner exposes the seeded defects, not that the policy is what prevents them; see Limits.
Nothing here is copied from another project.

| Case | Task type | Pattern the policy must prevent |
|---|---|---|
| `missing-precondition` | Bug fix | A regression test that omits the state the bug needs, so it passes on the unfixed code. Here `rates_set` leaves a stale cache entry that only a prior `rates_convert` fills |
| `order-dependence` | Behavior change | A test whose result depends on a shared mutable fixture and on execution order. Here `SHARED_CART` is what the other cart tests reuse |

| Path | Role |
|---|---|
| `template/` | The repository under test: `src/` and `tests/` |
| `cases/<case>.md` | The task text an implement run receives |
| `seeds/<seed>/` | One ready-made commit: its files and a `message`. Seeds replay a defective or a correct run without an LLM |

## Rerun

Without an LLM, `bats tests/implement-repro.bats` shows that the template's runner exposes each seeded defect for the reason the policy names, and that the reference solutions pass.

With a harness, copy `template/` to a new directory, commit it on `main` with a bare `origin` whose `origin/main` is that commit, and set `refs/remotes/origin/HEAD`.
Then run implement on a case, from that repository, where `<co>` is this checkout:

```bash
claude -p "Follow <co>/skills/implement/SKILL.md, and <co>/skills/commit/SKILL.md for commits, on the repository in the current directory. Nobody can answer: where the skill would ask or open difit, stop and print it. Never push or open a PR; there is no Issue. \$ARGUMENTS is the text after the line ARGUMENTS.

ARGUMENTS
$(cat <co>/tests/implement-repro/cases/<case>.md)" \
  --no-session-persistence --permission-mode acceptEdits --add-dir <co> \
  --allowedTools "Bash,Read,Edit,Write,Glob,Grep,Skill,Task"
```

For autonomous mode, make a linked worktree first and add `autonomous branch <branch> worktree <path>` as the line after `ARGUMENTS`.

The agent can run any command with your credentials.
Run it in a throwaway environment, without `gh` signed in, and with the skills directory read-only.

Judge the commits it left, in its worktree, from outside the run:

```bash
bash tests/run.sh --seed 1    # also 2 to 5; every run must pass
bash tests/run.sh --only <test> <file>    # each new or changed test must also pass alone
```

For `missing-precondition`, also run the final `tests/` against `src/` of `origin/main`: it must fail with a `FAIL:` line and no `ERROR:` line.

## Recorded runs

One run per row on 2026-10-26, on the last commit of this branch, with Claude Code 2.1.310 in headless mode (`claude -p`) and the model `sonnet`, on this checkout's own `skills/implement/SKILL.md`.
The recorded runs used the same instructions as the command above, worded a little longer, and also told the agent to use no installed copy of either skill.
Every run passed the suite in default order and shuffled for seeds 1 to 5, and for `missing-precondition` one `FAIL:` and no `ERROR:` on the unfixed `src/`.

| Harness | Model | Mode | Case | Result | Commits |
|---|---|---|---|---|---|
| claude 2.1.310 | sonnet | normal | `missing-precondition` | pass | `test:` that converts before `rates_set`, then `fix:` |
| claude 2.1.310 | sonnet | autonomous | `missing-precondition` | pass | Same |
| claude 2.1.310 | sonnet | normal | `order-dependence` | pass | Stub, `test:`, `feat:`, then a `test:` and `fix:` pair; `SHARED_CART` is not used |
| claude 2.1.310 | sonnet | autonomous | `order-dependence` | pass | Stub, `test:`, `feat:`; `SHARED_CART` is not used |

## Limits

- This shows no cause. No control run without the skill was made, each case ran once, and every run loaded the user's own configuration, which includes a TDD instruction file, so the policy cannot be told apart from it. Showing the cause needs a control, several runs per arm, and a clean configuration, and waits for #345 to #347, which still change implement's flow.
- A run depends on the model, the harness version, and the user's configuration, so a failing run is a result to read, not proof of a regression.
- "No third-party names" is checked as the absence of URLs, e-mail addresses, licence text, and the words GitHub and GitLab under `template/`, `seeds/`, and `cases/`.
