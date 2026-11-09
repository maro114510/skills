# Decision Question

implement's maintainers own this template. Other skills reference this file and never restate it.

It governs only how a decision question to a person is written. Whether to ask stays with each skill's own trigger.

## Structure

Write these parts in this order, with one decision per question.
Start each part with its label in the reader's language, and put a blank line between parts.
A line is at most about 15 words, or 40 characters in Japanese.

1. Decision: one line naming what to decide.
2. Context: 3 lines, one each for the goal of the work, the stage it has reached, and why this question arises now.
3. Criteria: 1 or 2 bullets naming what the choice must weigh.
4. Options: 2 to 4. The label says what it does; one line says how it fares on the criteria.
5. Recommendation: one line with the option's label and the criterion that decides it.

Leave out history and what every option shares.
Before asking, count each part's lines and cut any part that is over its cap.
With a question tool, the options go only in its fields, and the text holds the other four parts.

## Reader

Write for a reader who has not seen the session, or has forgotten what the work is.

- Use no name made up during the work; describe the thing instead.
- Say an internal term, such as a role name, in words the reader uses.
- Never point to "the above", "earlier", or anything else outside the question.
- Name a file, function, or other code identifier only where the reader must go there to decide.
- Never give an Issue, pull request, or option number alone; say in a few words what it is.

## Delegated Replies

A reply that explicitly hands the decision back, such as "you decide" or "go with your recommendation", takes the recommended option. Record it where the skill records decisions, and ask no follow-up question.
Any other reply, including "don't know", is not a delegation, because it can mean the question was not understood.

## Example

Decision: How should the nightly order export handle a full folder?

Context:
- Goal: the sales team reads yesterday's orders each morning.
- Stage: the export runs nightly but has no handling for errors.
- Why now: last night the shared folder filled up, and nobody was told.

Criteria:
- Failures are noticed quickly.
- No file someone still needs is lost.

Options:
- Email the team on failure: noticed within minutes; deletes nothing.
- Delete files over 30 days old and retry: recovers alone; may delete needed files.
- Leave it as is: no work; failures found only the next morning.

Recommendation: Email the team on failure; it meets both criteria.
