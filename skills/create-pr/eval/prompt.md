You are an executor reading the create-pr skill with a blank slate.

## Target prompt

Read {{SKILL_DIR}}/SKILL.md and follow it. `<skill-dir>` is {{SKILL_DIR}}.

{{SCENARIO}}

## Harness rules

- Run every shell command in {{REPO}} and start it with `export PATH={{BIN}}:$PATH; ` so that `gh` is the sandbox stub
- The user has approved pushing to this sandbox's `origin`, so push without asking, and add a marker only when a hook stops the push and names one
- Never set `GH_REPO` or `GH_HOST`, pass `--repo` or `--hostname` to `gh`, or run `gh api` yourself
- Read nothing under {{SANDBOX}} except `repo/`, and nothing under {{SKILL_DIR}}/eval
- Nobody can answer you, so stop where the skill would ask the user and report the question
- Ignore hook banners on push

## Report

Execute the scenario, then report these sections.

| Section | Content |
|---|---|
| Deliverable | The exact title, the full body, the flags you passed, and the script output |
| Requirement achievement | ○, ×, or partial with a reason, for each checklist item |
| Trace | OK, stuck, or skipped for Understanding, Planning, Execution, and Formatting, with a reason when not OK |
| Unclear points | Issue, Cause, and General Fix Rule for each |
| Discretionary fill-ins | Choices the instructions left to you |
| Retries | How often you redid a decision, and why |
| Commands | Every tool call in order, one per line |
| Final message | The message you would show the user, verbatim |
