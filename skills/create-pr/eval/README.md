# create-pr evaluation harness

Three fixed scenarios. A run of SKILL.md on them can be compared before and after a change, and nothing in a run reaches GitHub.
An executor follows SKILL.md from a blank slate inside a sandbox. Grading reads what the sandbox recorded, not what the executor reports.

| Scenario | Arguments | What it exercises |
|---|---|---|
| A | none, `skills.lang ja` in the clone | A Japanese PR template, a branch never pushed, one `Closes #12` footer |
| B | `lang en` | A stale local `main`, an upstream behind HEAD, and an unrelated `Closes #99` on `origin/main` |
| C | `lang en` | A stacked branch whose `branch.<b>.gh-merge-base` is `feat/export-api`, and no template |

| Path | Role |
|---|---|
| `setup.sh` | Builds one sandbox from scratch; its header holds the usage |
| `gh-stub.sh` | The `gh` that a sandbox puts on PATH. It answers from files and records every call; its header lists the records |
| `grade.sh` | Grades a sandbox from its records, one line per checklist item |
| `prompt.md`, `scenarios/<X>.md` | The executor prompt, and each scenario's text and fixed requirements checklist |
| `test-eval.bats` | Checks the harness itself without an LLM, through runs of create-pr's own scripts |

## Run

Build a sandbox. The command needs no network and no GitHub token:

```bash
bash skills/create-pr/eval/setup.sh A /tmp/cpr-eval/A [<skill-dir>]
```

Pass `<skill-dir>` to evaluate another copy of create-pr, such as the base branch's, from a second checkout.
Without it, the sandbox uses the create-pr directory that holds this harness.
`<dir>/prompt.md` is the whole executor prompt.

- OpenCode: start a fresh `general` subagent that reads `<dir>/prompt.md` and acts on it.
- Claude Code, from `<dir>/repo`:

  ```bash
  claude -p "$(cat <dir>/prompt.md)" --output-format json --no-session-persistence \
    --permission-mode acceptEdits --add-dir <skill-dir> --allowedTools "Bash,Read,Glob,Grep"
  ```

Then grade:

```bash
bash skills/create-pr/eval/grade.sh A /tmp/cpr-eval/A
```

`PASS` and `FAIL` come from the records. `MANUAL` names what to read in the executor's report, or the body lines to check for a manual wrap.
Rebuild before each run, because a sandbox keeps the previous run's push and records.

## Isolation

- `origin` is a local bare repository, so the real `gh` finds no GitHub host and stops before sending a request.
- Every URL the stub prints is on `github.invalid`, so replaying one with the real `gh` cannot reach GitHub either.
- `test-eval.bats` checks both cases with `GH_DEBUG=api`, signed in, with the stub left off PATH.
- Not covered: the real `gh` reaches GitHub when the executor's environment sets `GH_REPO` or `GH_HOST`, or when the executor passes `--repo` or runs `gh api` itself.
  The prompt forbids all of these, but only the executor's compliance enforces that.
  Run executors in a shell without those variables.

## Baseline

Recorded on 2026-10-30, one run per row, on `skills/create-pr/SKILL.md` at `741c121`.

| Harness | Model | Scenario | `[critical]` | Others | Tool calls |
|---|---|---|---|---|---|
| OpenCode 1.19.5, `general` subagent | anthropic/claude-opus-5-5 | A | 1-4 PASS | 5-8 PASS | 5 |
| OpenCode 1.19.5, `general` subagent | anthropic/claude-opus-5-5 | B | 1-4 PASS | 5-7 PASS | 5 |
| OpenCode 1.19.5, `general` subagent | anthropic/claude-opus-5-5 | C | 1-4 PASS | 5, 6, 8 PASS; 7 relayed | 4 |
| Claude Code 2.1.314, `claude -p` | claude-sonnet-5-5 | A | 1-4 PASS | 5-8 PASS | 4 turns |
| Claude Code 2.1.314, `claude -p` | claude-sonnet-5-5 | B | 1-4 PASS | 5-7 PASS | 4 turns |
| Claude Code 2.1.314, `claude -p` | claude-sonnet-5-5 | C | 1-4 PASS | 5, 6, 8 PASS; 7 relayed | 4 turns |

In C, every run opened the PR against `feat/export-api` with only `Closes #8`, and relayed the NOTICE that #8 stays unlinked with the `--link` step.
Unclear points the executors reported, for later changes to address:

- Whether the reason on an unchecked 動作確認 item may come from inspecting the repository, since Step 1 forbids gathering context with other commands. One OpenCode A run ran `ls` for it.
- Whether a newer `Closes` silently overrides an older `Related`, since Step 1 states only the reverse conflict. Reported in both B runs.
- Whether a `Closes` kept unlinked counts as "linked" in Step 6.3's report.

## Limits

- Each row is one run, so a single FAIL in a comparison is a result to read, not proof of a regression.
- An executor sees the checklist it is graded against, as in empirical-prompt-tuning. The checklist can therefore steer it, and the baseline measures a run that knew the bar.
- A run loads the user's own harness configuration, and Claude Code also loads installed skills, so other users' results can differ.
