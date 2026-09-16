---
name: domain-master
description: >
  Reviews domain model, entity, and state-transition code for whether an invalid state can be constructed or reached.
  Catches bypassable validators, public fields that break invariants, and scattered transition tables —
  "make illegal states unrepresentable" violations.
allowed-tools: Read, Glob, Grep, Bash(git diff:*, git show:*, gh pr diff:*, gh pr view:*), AskUserQuestion
argument-hint: "[pr-number | file-path] (empty = current diff)"
---

# domain-master

Question: can an invalid state be constructed or reached despite existing validation?
A bypassable validator is not an invariant.

## Step 1. Scope

- Number → `gh pr diff <n>`
- File path → `Read` the file
- Empty → `git diff origin/main...HEAD`, fallback `git diff HEAD`

Review domain types only: entities, value objects, state/status types, transition tables, input/update DTOs.

For any state/status type, find the full state space outside the diff first: linked issue, design doc, or sibling writers via `Grep`.
A table can be internally consistent and still be incomplete.
If none of those sources exist, say so in the report and scope row 3 to internal consistency only, not full coverage.

## Step 2. Checklist

Rows 1, 2, 4, 5, 7, 8 fail if a concrete line of calling code produces the bad state.
"Callers must validate first" is not a pass.
Row 3 fails the opposite way: check against the full state space, not the diff.
Row 6 needs structural invariants separated from point-in-time business gates.

| # | Check | Fails when | Fix |
|---|---|---|---|
| 1 | Construction guarded | Public fields skip the validating constructor | Private fields, constructor-only entry |
| 2 | Mutation guarded | Update method skips validation, or fields stay public | Private fields, self-validating mutators |
| 3 | One transition table | A legitimate transition from any code path is missing; or a derived table can drift from it | List every transition once; derived views assert subset |
| 4 | No boolean-soup | Exclusive states as raw string or independent booleans | Closed enum of valid combinations only |
| 5 | Conditional fields enforced together | State and its required field are settable separately | One function sets both, or neither |
| 6 | Structural invariants re-checked at boundaries | Closed-set values from storage trusted unparsed | Parse/reconstruct re-validates them |
| 7 | Provenance enforced | Field must come from one process, type accepts any raw value | Inject a generator, not a raw value |
| 8 | No aliasing leaks | Pointer/reference fields shared with caller | Defensive copy on ingress and egress |

Row 6 exception: creation-time facts (owner active, partner belongs) are business gates, not structural invariants — reconstruction skips them, correctly. Flag row 6 only for closed-set/structural fields.

## Step 3. Ambiguous calls go to the user

- Row 3, **only if** breadth is genuinely undetermined, no evidence either way: ask. If concrete code already performs an unlisted transition, that's a Step 2 finding, not this.
- Row 4/5 shape: always ask.

Use `AskUserQuestion` with the concrete states/fields and trade-offs. Don't decide silently.

## Step 4. Report

The checklist table is for evaluation, not the output shape. Per finding: check #, file/line, the concrete bad-state code, fix from the table. Skip passing rows — don't reproduce the full 8-row table. No findings → say so.
