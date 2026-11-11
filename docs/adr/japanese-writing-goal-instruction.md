# Japanese writing quality is governed by a short goal-based instruction, not a symptom catalog

## Context

AI-generated Japanese shows defects of several kinds, not one kind called readability:

| Kind | Observed defects |
|---|---|
| Meaning | Dropped exceptions, conditions, or limits. Added claims without a source. Shifted certainty |
| Language | Words or metaphors that do not fit the context or collocate. Unclear predicate-argument roles, modification targets, or references |
| Discourse | Supplements pushed into brackets. Abstract filler and restatement. Leaps in reasoning |
| Notation | ASCII spaces beside Latin script inside Japanese. Paragraph structure confused with indentation or Markdown rendering |

The retired `ja-style-check` skill attacked these defects as symptoms, and it failed:

| What happened | Why it matters |
|---|---|
| It grew to 14 checks in a 243-line rubric, a 332-line scanner, a 272-line test suite, and a CI job, then was retired unused | Maintenance outgrew the value |
| The bracket rule went from risk signal to near-zero to violation. Each allowlist leaked, and the exceptions the agent did invoke were overridden by the user in almost every batch where it invoked them | A count of a surface form became the goal, and every tightening found a new edge |
| The automatic line join damaged documents: a byte threshold fired at 26 Japanese characters, joins fused Latin words, file modes and symlinks were overwritten | A program editing prose corrupted the text it checked |
| Three designs for detecting Latin script in Japanese were withdrawn. Each inverted the rule, missed real cases, or flagged correct English | Static detection could not separate the cases that matter |
| The scanner skipped headings, lists, tables, and URL lines, so an empty finding list was read as clean | A detector's silence passed for quality |
| The same class of document had code identifiers kept in one session and paraphrased away in another | Rules gave no stable target to judge by |
| Fix mode was widened to auto-apply judgment edits, with a meaning-safety rule as a backstop | Rewriting for style and keeping meaning pulled in opposite directions |

The same symptom rules still live on in `extreme-compact`, which forbids every non-definition bracket and every bare Latin word in Japanese output.

## Decision

Japanese writing quality is governed by one short Quality Instruction, as `docs/design/japanese-writing.md` defines it: the goal, the Quality Axes, and at most a few concrete conditions the axes alone fail to produce. Research, comparisons, and failure history are kept in full as a Reference Corpus that maintainers read and the model never receives. A condition enters the instruction only for an Observed Failure, and only after a paired comparison shows it helps.

## Rationale

| Decisive reason |
|---|
| A goal survives model updates and changes of context. A list of forms breaks with them, and each fix adds an edge |
| Meaning first gives one answer when rules conflict. A catalog has no such order, so brevity or a lower finding count can justify dropping meaning |
| Many defects start where the text was planned: wrong Purpose, wrong Reader, missing relations. A post-pass on the surface cannot repair these |
| A short instruction costs little on every task, and the Reference Corpus keeps what was learned without loading it |

| Alternative | Strength | Why it lost |
|---|---|---|
| Revision pass with lint, diff, and checks, as in [yomiyasu](https://github.com/nanaism/yomiyasu) | Puts meaning, weight, certainty, and no additions first. Catches fine-grained symptoms | Large rule set and scripts, maintained symptom by symptom. A lint pass proves neither kept meaning nor understanding, which its author also states |
| Generation-time constitution with document types, static detection, and rubric reviews, as in [natural-japanese](https://github.com/coji/natural-japanese) | Returns to purpose, material, and paragraph design at generation time | Steps, document types, scores, and multiple agents are too heavy for every task, and a score target becomes a proxy. Its own corpus work reports no universal reader-load threshold that avoids flagging good text |
| Clarity-only revision, as in [meiseki](https://github.com/bamboo-nova/meiseki) | Narrow goal. Refuses to invent the writer's voice | Covers clarity only, not argument, notation, or fit to the Medium. Its direction is adopted as part of the Language and Line axes |
| Writer-presence rules on stance, specificity, and rhythm, as in [stop-ai-slop-jp](https://github.com/iKora128/stop-ai-slop-jp) | Asks what the text claims | Demanding stance or experience in a neutral explanation or a faithful summary invents claims. Scoring invites Goodhart's law |
| Symptom catalogs of 20 to 25 patterns or about 300 words, as in [humanizer-ja](https://github.com/gonta223/humanizer-ja), its [variant](https://github.com/makotofalcon/humanizer-ja), and [deslop-ja](https://github.com/nakashimatakaya/deslop-ja) | Fast to start. Finds known surface symptoms | Weak causal link between changing words or rhythm and quality. Domain-dependent and outdated by model updates. `ja-style-check` was this approach and failed |
| Genre rules for technical manuscripts, as in [japanese-tech-writing](https://gist.github.com/k16shikano/fd287c3133457c4fd8f5601d34aa817d) | Clear goal for one genre. Paragraph as one step of an argument | Its manuscript and Markdown conventions are not general Japanese rules. Usable as a Narrow Exception for that genre |
| An intermediate meaning representation projected into prose | Separates meaning from wording | Equivalence and completeness of meaning across languages are unsolved. Building it exceeds the problem |
| No instruction | No cost, no rule conflicts | Kept as the baseline every candidate instruction is compared against, not chosen, because the observed defects occur without one |

## Consequences

- One small instruction to maintain instead of rules, scripts, tests, and CI.
- The instruction does not guarantee typesetting. A Notation defect that the axes fail to prevent becomes a concrete condition only after an Observed Failure and a comparison.
- Without a detector, nothing reports a defect automatically. A person or the comparison of `skill-evaluation.md` finds failures.
- Bracketed asides disappear because they fail the one-pass reading the goal demands, not because a form is forbidden. The `extreme-compact` and `shakedown` bracket rules reach the same result by naming a form.
- The model judges against goals, so two runs may word the same text differently. Only a change of meaning counts as a failure.
