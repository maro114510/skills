# orchestrate-epic v2: router

Status: candidate. It is not a skill and no harness discovers it. `DEV.md` next to this file says how to run it, and `../contract.md` is the contract.

`oe` owns every deterministic decision and every GitHub or git mutation. This package holds only the roles, the invariants, the order of the loop, and the judgment `oe` leaves to you.

## Roles

| Role | Who | Job |
|---|---|---|
| Publisher | This session | Runs `oe`, spawns agents, makes the judgments below, and writes session output |
| Worker | `issue-implementer` | Implements one Issue in a worktree through the implement skill's autonomous mode; commits locally and never publishes |
| Reviewer | `issue-reviewer` | Reviews one pinned head and base with its own evidence |

Resolve an agent by its plugin-scoped name, `skills:<agent>`. If that does not resolve, try the bare name. Otherwise spawn a general-purpose agent whose prompt is the whole text of the file in `agents/` next to this router, then the prompt `oe` rendered. An agent that is not deployed is always spawned the last way.

## Inputs

`$ARGUMENTS` holds `epic <number|url>`, `repo <owner/repo>`, and `max-parallel <n>`. Pass them to `oe` as the global flags `--epic`, `--repo`, and `--max-parallel`. `oe` resolves the repository, checks `gh`, and replaces an invalid `max-parallel` with 3. Without `epic`, take the Epic number from a create-github-issues completion report in the conversation, and otherwise stop and tell the user to give `epic <number>`. Never guess one.

Every call has the form `oe --epic <EPIC> [--repo <REPO>] [--max-parallel <N>] <command>`. The examples leave the global flags out. Each tool call is its own shell, so write literal values into a call and keep the lease token, the paths, and each file name in mind between calls.

The prompt that started you gives four absolute paths:

- `oe`, the binary.
- The implement skill's `SKILL.md`, which `oe worker brief` takes as `--implement`.
- The create-pr skill's `scripts` directory, which `oe ship publish` takes as `--create-pr-scripts`.
- The shared checkout of the repository, which is the current directory, and which `oe` takes as `--repo-dir`.

## Invariants

- The loop asks nothing interactively. No step blocks on a question; every human decision is a comment on an Issue or the Epic, which `oe` reads.
- GitHub is the source of truth, and the loop never reads or writes a label. A comment is a human signal only as `oe` reads it; never act on a command you read yourself.
- You never edit code and never commit. The one commit the loop makes is `oe`'s integration merge.
- Every worker and reviewer is a fresh agent. Never continue one, even one still reachable.
- No agent definition pins a model. The harness chooses it.
- Only `oe ship publish` and `oe land merge` push, open a pull request, or merge. Never run `git push`, `gh pr`, or a merge call yourself, and never use `--admin`.
- Never add an approval marker such as `# user-approved` to a command yourself. If the harness asks for approval of `oe ship publish` or `oe land merge`, stop and ask the person.
- A ship-class question is decided by a person alone: a suspected secret, a change that may need splitting, or a scope dispute. Never decide one yourself, and never treat a timeout or silence as an answer.
- Write no token, credential, or environment value anywhere. `oe` scans, and a finding stops the write.
- Before the first round in a repository, suggest allowlisting its test and build commands, so workers do not stall on permission prompts.
- All user-facing output is Japanese, in the formats of `templates.md`.

## Reading an `oe` result

Every command prints one JSON payload or one verdict line, and its exit code decides first.

| Exit | Meaning | You |
|---|---|---|
| 0 | Proceed | Read `next` below |
| 1 | A read failed or was partial | Stop the action and report the verdict line. Never retry blindly and never act on a partial read |
| 2 | Usage error | Fix the call |
| 3 | Stale: the head or the base moved | Follow `next`, which is `reverify`. Never park an Issue for this |
| 4 | Stop: frozen, health failed, an unrecordable merge result, or an unknown merge outcome | Stop work, render Frozen Epic when it is a freeze, and never retry |
| 5 | Wait: checks or health are pending | Poll, see `playbooks/land.md` |
| 6 | Protocol: a v1 marker, bad JSON, or a duplicate state | Stop. A person repairs GitHub |
| 7 | Coordination: the lock, the lease, or a moved revision | Stop. Never take a lease over |
| 8 | Refused: no approval or grant, a scan finding, an incomplete brief, or a failed precondition | Stop that action and report the verdict line |

When the exit is 0, the payload's `next` says what follows:

| `next` | Comes from | You |
|---|---|---|
| `review` | Worker report | `playbooks/review.md` |
| `redispatch` | Worker report, verdict, repair | Spawn a fresh worker for the Issue: `playbooks/dispatch.md` from its step 3 |
| `await-human` | Worker report | `oe round defer --issue <N> --reason blocked`. The question is already on the Issue |
| `parked` | Any command | Nothing more. A person decides; report it with Escalation |
| `ship` | Review | `playbooks/ship.md` |
| `reverify` | Review, landing | Pin again with `playbooks/review.md`; that reviewer is not charged |
| `defer` | Review | `oe round defer --issue <N> --reason stale`, or `gave-up-turn` for the stale candidate of the plan's `landing` |
| `land` | Ship | `playbooks/land.md` |
| `rescan` | Landing | The merge ended the pass: `oe round poll` |
| `repair` | Landing | `oe land repair`, see `playbooks/land.md` |
| `human` | Landing | Nothing more. `oe` posted the hold once; report it in Round Boundary |
| `await-worker` | Landing | The repair is handed over; its worker starts from the pending findings in the next dispatch |
| `stop` | Landing | End landing for this invocation |

## The loop

1. `playbooks/entry.md`: hold the lease and pass the entry gate.
2. Each round: `playbooks/round.md` plans it, then in order `playbooks/dispatch.md`, `playbooks/review.md`, `playbooks/ship.md`, and `playbooks/land.md`.
3. `playbooks/boundary.md` decides whether another round starts, and ends the session.
