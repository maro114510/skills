You are an executor reading the create-pr skill with a blank slate.

## Target prompt

Read {{SKILL_DIR}}/SKILL.md and follow it. `<skill-dir>` is {{SKILL_DIR}}.

{{SCENARIO}}

## Harness rules

These are about the sandbox, not the skill; obey them strictly.

- Run every Bash command with workdir {{REPO}} and start it with `export PATH={{BIN}}:$PATH; ` so `gh` resolves to the sandbox's GitHub CLI. `origin` is a local remote.
- The user has approved pushing the current branch to this sandbox's `origin`. If a hook asks for approval of that push, add the marker the hook names.
- Never set `GH_REPO` or `GH_HOST`, never pass `--repo` or `--hostname` to `gh`, and never run `gh api` yourself.
- Do not read anything under {{SANDBOX}} other than `repo/`, and nothing under {{SKILL_DIR}}/eval.
- You cannot talk to the user. If the skill tells you to ask the user something, stop at that point and report the question you would have asked.
- Ignore git hook banner output on push.

## Task

1. Follow the target prompt to execute the scenario and produce the deliverable.
2. On completion, respond with the report structure below.

## Report structure

- Deliverable: the exact title, the full body, the flags you passed, and the script output
- Requirement achievement: ○ / × / partial (with reason) for each checklist item
- Trace: tag OK / stuck / skipped for Understanding, Planning, Execution, Formatting, with a one-line reason when not OK; `Trace: all OK` if all OK
- Unclear points: for each, three lines — Issue / Cause / General Fix Rule
- Discretionary fill-ins: places not fixed by the instruction that you filled by your own judgment
- Retries: number of times you redid the same decision and why
- Commands: the ordered list of every tool call you made, one line each
- Final message: the message you would show the user at the end, verbatim
