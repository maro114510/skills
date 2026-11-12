# japanese-writing states the goal and checks against the source instead of listing rules

## Context

Model-written Japanese fails in two ways. It is hard to read, with meaning tucked into brackets, dashes, and bold. Its meaning drifts from the source, most often when a paraphrase drops a hedge, a hearsay marker, a statistical qualifier, or a condition.

`ja-style-check` fought these as symptoms with a 14-check rubric, a scanner, automatic fixes, and CI. Its rules kept leaking at the edges, its fixes damaged text, and it was retired unused. A later goal-based draft grew back toward the same catalog of form rules while its evaluation grew into the work itself.

## Decision

The skill holds three things and nothing else:

- The goal: a reader without the writer's context reads the text once and takes from the source exactly what they need, in no more words than that takes. Without the second half, outputs repeated every qualifier and grew past what the reader needed.
- A picture of the Japanese that serves that reader, which says in passing where meaning must not go.
- One check before finishing: read the text against the source claim by claim, fix any claim whose strength, attribution, or conditions changed, and cut any the source and the request do not call for.

When the skill fails, revise the picture or the check first. A rule for one form is added only when rewording the picture cannot stop a failure that recurs.

## Rationale

| Alternative | Why it lost |
|---|---|
| A catalog of form rules, with or without a scanner | `ja-style-check` showed that such rules leak at the edges, grow without end, and become the target themselves |
| A goal sentence alone | In the evaluation of the earlier draft, a goal that named no form left most bold and brackets in place. Naming where meaning must not go stopped them |
| An instruction to preserve qualifiers while writing | Every variant tried, including no instruction, kept dropping hedges such as 「らしい」 and 「ほぼ」 |
| Leave it to each user's global writing preferences | Covers form only, and does not travel with the skill |

| Decisive reason |
|---|
| Adding the claim-by-claim check to the earlier draft raised the share of runs that kept every critical item on new tasks from 74% to 83%, the largest gain any single change made |
| A picture of the result can be revised as a whole when it fails, so it does not accumulate exceptions the way a rule list does |

## Consequences

- The skill stays a few sentences long, so every task that loads it pays little.
- The picture names brackets, dashes, and bold. A reader may see that as a form rule; it is part of the description of the goal and is revised with it.
- The evidence is limited. The evaluation ran without the user's global instructions, on tasks seen while the check was written, with one person judging readability. How much the skill adds to a setup whose global instructions already cover form is unmeasured, and this change runs no new paired comparison.
