# Decision Question

implement's maintainers own this template. Other skills reference this file and never restate it.

It governs only how a decision question to a person is written. Whether to ask stays with each skill's own trigger.

## Structure

Write these parts in this order, with one decision per question.
When several decisions are open, ask each as its own question, the one blocking the work first.
Start each part with its label in the reader's language, and put a blank line between parts.
A line is at most about 15 words, or 40 characters in Japanese, in the text and in each option field alike.

1. Decision: one line naming the process, the problem in it, and what about it to decide.
2. Context: 3 lines, one each for the goal of the work, the stage it has reached, and why this question arises now, plus a fourth only for a serious consequence every option shares.
3. Criteria: 1 or 2 bullets naming what the choice must weigh.
4. Options: 2 to 4. The label says what it does; a separate line says how it fares on the criteria.
5. Recommendation: one line with the option, named by its label or a short form of it, and the criterion that decides it.
6. Agreement: one line asking whether the reader accepts the recommendation, and if not, which option they choose.

Leave out history and what every option shares, unless it is a serious consequence such as data loss.
Before asking, count each part's lines and cut any part that is over its cap.
With a question tool, each option's label and line go in the tool's label and description fields, and the text holds the other five parts.

## Reader

Write for a reader who has not seen the session, or has forgotten what the work is.

- Use no name made up during the work, unless choosing it is the decision; describe the thing instead.
- Say an internal term, such as a role name, in words the reader uses.
- Never point to "the above", "earlier", or anything else outside the question.
- Name a file, function, or other code identifier only when it is what is decided, or where the reader must go to decide.
- Never give an Issue, pull request, or option number alone; say in a few words what it is.

## Delegated Replies

A reply that explicitly hands the decision back, in any language, such as "you decide" or "go with your recommendation", takes the recommended option. Record it where the skill records decisions, and ask no follow-up question.
Any other reply, including "don't know", is not a delegation, because it can mean the question was not understood. What to do next is the calling skill's choice.

## Example

Decision: The nightly order export fails on a full folder: how should it respond?

Context:
- Goal: the sales team reads yesterday's orders each morning.
- Stage: the export runs nightly but has no handling for errors.
- Why now: last night the shared folder filled up, and nobody was told.

Criteria:
- Failures are noticed quickly.
- No file someone still needs is lost.

Options:
- Email the team on failure
  - Noticed within minutes; deletes nothing.
- Delete files over 30 days old and retry
  - Recovers alone; may delete needed files.
- Leave it as is
  - No work; failures found only the next morning.

Recommendation: Email the team on failure; it meets both criteria.

Agreement: Shall I email the team on failure? If not, which option?
