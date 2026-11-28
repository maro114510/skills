---
name: domain-master
description: >
  Reviews domain model, entity, and state-transition code for whether an invalid state can be constructed or reached,
  and whether the model's names, operations, and invariants match the business rules.
  Catches bypassable validators, public fields, scattered transition tables, and misleading abstractions.
argument-hint: "[pr-number | file-path] (empty = current diff)"
---

# domain-master

Question: can an invalid state be constructed or reached despite existing validation, and does the model mean what the business says?
A bypassable validator is not an invariant, and a consistent name is not evidence that the model is right.

## Step 1. Scope

Parse `$ARGUMENTS`:
- Number → `gh pr diff <n>`
- File path → `Read` the file
- Empty → `git diff origin/main...HEAD`, fallback `git diff HEAD`

Review domain types only: entities, value objects, state/status types, transition tables, input/update DTOs.

For any state/status type, find the full state space outside the diff first: linked issue, design doc, or sibling writers via `Grep`.
A table can be internally consistent and still be incomplete.
If none of those sources exist, say so in the report and scope row 3 to internal consistency only, not full coverage.

## Step 2. Checklist (structure)

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

## Step 2b. Semantic review

Read `references/semantic-review.md` in full, then run its checks S1 to S5 on the same domain types.
It first establishes the bounded context and the authoritative domain evidence, and states the output shape and the regression examples.
Never assume a business rule the evidence does not state: missing or conflicting evidence is an open question, not a finding.

## Step 3. Ambiguous calls go to the user

- Row 3, **only if** breadth is genuinely undetermined, no evidence either way: ask. If concrete code already performs an unlisted transition, that's a Step 2 finding, not this.
- Row 4/5 shape: always ask.
- Semantic open question from Step 2b: ask the one question that settles it.

Use `AskUserQuestion` with the concrete states/fields and trade-offs. Don't decide silently.

## Step 4. Report

The checklist table is for evaluation, not the output shape. Per structural finding: check #, file/line, the concrete bad-state code, fix from the table.
Per semantic finding: the five parts `references/semantic-review.md` § Output lists, then `Open questions` and `Notes` when there are any.
Skip passing rows — don't reproduce the tables. No findings → say so.
