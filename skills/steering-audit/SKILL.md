---
name: steering-audit
description: >
  Audit a coding agent's steering files, such as AGENTS.md, skills, and memory notes,
  against how the current model actually behaves, and propose what to delete or rewrite.
  Use when the user asks to audit instructions, clean up AGENTS.md, migrate prompts to a new model,
  or says 指示の棚卸し, AGENTS.md を整理して, 古い指示を見直して, モデル移行の指示確認.
disable-model-invocation: true
argument-hint: "[scope: global | repo | path]"
---

Your job is an inventory of the steering files that guide a coding agent.
Recent models follow written instructions faithfully.
Old instructions can therefore cause needless approvals, skipped work, or stiff writing.
Find them and propose changes. Do not edit any file.

Scope: `$ARGUMENTS`. If empty, cover both the user's global scope and the current repository.

## Steps

1. Identify the harness.
   - Find out which harness is running and which model it uses.
   - Find the steering files that harness reads: instructions, skills, memory notes, and settings.
   - Find where it keeps session logs and in what format.
     Read the harness's own docs or skills first if they exist.
   - If several harnesses are in use, cover all of them.
   - Report briefly what you found and how.

2. Read the targets and count the rules.

3. Collect evidence per rule from the logs, opened read-only.
   - Cases where the rule was broken
   - Cases where it was obeyed and caused a side effect
   - Cases where it never mattered

4. Look for candidates in these categories. Add others if the evidence points there.

- **Absolute wording**: rules of "never" or "always" with no scope. Rewrite with scope, reason, and exception.
- **Piled-up caution**: warnings and notes whose reason no longer applies. Delete.
- **Approval scope**: approval rules that name a wider set of actions than intended. Narrow them.
- **Pasted boilerplate**: text the user pasted three or more times. Move it into a steering file or skill.
- **Standing delegation**: instructions to hand work to subagents. Compare actual spawns with what the task needed.
- **No-ops**: rules that do not change behavior. Delete.
- **Style rules**: limits that produce stiff text. Replace with a numeric target.
- **Mechanical rules**: formatting, naming, and file placement. Move to a linter or hook; keep prose only for judgement calls.

5. Present only candidates that have evidence, most severe first.

## Rules

- Do not report a candidate without evidence. Label a guess as a guess.
- Never propose deleting a safety rule. Examples: writes to production, destructive actions, secrets.
- List rules that conflict between the global scope and the repository as their own item.
- Report any instruction that changes mid-conversation, such as a working-directory switch or a model switch.
- Open logs read-only. Do not copy personal information into the output.

## Output

Open with three parts, in this order: the conclusion, the decision needed from the human, and the next step.
Then give a table with the columns category, target rule, evidence, and proposal.
