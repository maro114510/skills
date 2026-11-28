# Semantic Review

SKILL.md Step 2b runs this.
A model can use one vocabulary everywhere and still misstate the business, so consistent naming is necessary but not enough.
This file judges whether the vocabulary, the model's structure, its behavior, and its invariants express the same domain concepts.
Structural reachability of illegal states stays with the Step 2 checklist; this file does not restate it.

Never demand a universal glossary, a DDD architecture, or a mechanical rename.

This file extends `domain-master` instead of adding a skill.
`pr-review-pe` only checks a diff against the project's existing vocabulary, and `frame-problem` defines the vocabulary before work starts.
Neither judges whether the model enforces the rules the vocabulary names, so no rule here repeats theirs.

## 1. Establish the Evidence

Do this before judging any row, and name the bounded context the code belongs to.

| Source | Examples |
|---|---|
| A decision by a domain expert or the owner | An Issue or comment that states a rule; a Design Doc or ADR |
| Written requirements and glossary | Acceptance criteria, a glossary page, API documentation |
| Existing contracts and examples | Schemas, published event or API types, tests that pin a business case |

- The code under review is never evidence of the rule it implements, only of what it does.
- Quote the line that states each rule you rely on, with its location.
- Two sources that disagree, or no source for a rule the model depends on, make the rule an open question, never a finding. Never assume the rule.

## 2. Checks

| # | Check | Finding when | Not a finding when |
|---|---|---|---|
| S1 | Rule is modeled | The evidence states a rule, such as "an order cannot be cancelled after shipment", and the model permits what it prohibits, forbids what it permits, or has no place where the rule can hold | The evidence is silent, conflicting, or the rule is about another context |
| S2 | Rule holds at execution | The operation that would break a stated rule runs without checking it, because only a preflight predicate such as `canCancel()` or each caller's own `if` guards it | The operation itself rejects the violating call, whether or not a predicate also exists |
| S3 | Name and effect keep their promise | A type or method name, or its effect, promises more than its contract delivers or means something other than the evidence's wording: `cancel()` only flags a record, `validate()` returns a bool nobody must read, `Money` ignores its currency, a refund that deletes the order it refunds | The name is imprecise but the behavior is exactly what the evidence says |
| S4 | One meaning per label per context | Inside one bounded context, one label stands for two concepts with different rules, or two labels stand for one concept and the rules differ between them | The same label means different things in different bounded contexts; never force one shared model on them |
| S5 | Semantic, not cosmetic | A difference changes who may do what, when, or what is true: status values, quantities, identities, permitted transitions | A difference only changes spelling, casing, or a synonym with identical rules; mention it as a note at most, and never propose a rename as a fix |

S2 and S3 find the anemic or misleading abstraction: a correctly named entity whose constraints live in callers, or a method whose name promises more than its contract enforces.

## 3. Bounded Contexts

A context is bounded by the evidence: separate modules, services, or glossaries that the sources treat as separate vocabularies.
When the sources do not say whether two places share a context, that is an open question.

## 4. Output

Report each semantic finding with all five parts.

- Evidence: the quoted rule and its location
- Violated domain rule: the rule in one sentence
- Code: file and line of the concrete code that breaks it
- Impact: what goes wrong for the business or the caller
- Correction: the smallest change that makes the model hold the rule

Report each open question under `Open questions`, with the missing or conflicting evidence and the one question that would settle it.
Step 3 decides whether to ask now or leave it in the report.
Report a cosmetic difference, if at all, under `Notes` in one line.

## 5. Regression Examples

Each example is an input and its expected outcome.
A change to this file or to Step 2b keeps every outcome unchanged.

| # | Input | Expected |
|---|---|---|
| 1 | Evidence: "An order cannot be cancelled once shipped." `Order.cancel()` sets `status = CANCELLED` from any status, including `SHIPPED`. All names match the glossary. | S1 and S2 finding, with the quoted rule, `cancel()` as the code, and a correction that rejects the call in `cancel()` |
| 2 | Same evidence. `Order.cancel()` throws when `status == SHIPPED` before changing state. | Pass |
| 3 | Same evidence. `Order.canCancel()` returns false when shipped, `cancel()` does not call it, and a controller calls `canCancel()` before `cancel()`. | S2 finding; the predicate alone is insufficient, and another caller can skip it |
| 4 | Evidence for context A: "SKU identifies a sellable product variant." Evidence for context B: "SKU identifies a stocked physical item." Each context models its own `Sku`. | No finding; the contexts are not forced into one model |
| 5 | One context whose glossary says "SKU identifies a sellable variant", and a module in it that uses `sku` for a warehouse bin with different rules. | S4 finding |
| 6 | The DTO calls the buyer `client`, the entity calls it `customer`, the glossary treats them as one concept, and the rules are identical. | No finding; a note at most, with no rename proposed |
| 7 | The requirement says "cancel until shipped", the glossary says "cancel until delivered", and the code allows cancellation until delivered. | Open question naming both sources; no finding and no assumed rule |
| 8 | No source states a cancellation rule, and the code allows cancelling a shipped order. | Open question; no finding |
| 9 | Evidence: "Cancelling an order must refund the payment and release the reserved stock." `Order.cancel()` only sets a flag while the refund and stock release live in each caller, and they disagree. | S3 finding: the name promises a cancellation that the contract does not complete |
