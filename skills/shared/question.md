# Decision Question

implement's maintainers own this template. Other skills reference this file and never restate it.

It governs only how a decision question to a person is written. Whether to ask stays with each skill's own trigger.

## Structure

Write these parts in this order, with one decision per question:

1. Current state: at most 3 sentences of the facts the decision rests on.
2. Options: 2 to 4, each in at most 2 lines saying what it does and what it costs or risks.
3. Recommendation: the recommended option and one reason.
4. Question: the decision the reader is asked to make.

## Reader

Write for a reader who has not seen the session.

- Use no name made up during the work; describe the thing instead.
- Never point to "the above", "earlier", or anything else outside the question.
- Name a file, function, or other code identifier only where the reader must go there to decide.

## Delegated Replies

A reply that explicitly hands the decision back, such as "you decide" or "go with your recommendation", takes the recommended option. Record it where the skill records decisions, and ask no follow-up question.
Any other reply, including "don't know", is not a delegation, because it can mean the question was not understood.

## Example

Current state: A nightly job exports the day's orders to a CSV file in a shared folder. When the folder is full, the job fails without telling anyone, and the missing file is noticed only the next morning.

- A. Email the team when the job fails. Alerts within minutes; adds one more automated email.
- B. Delete files older than 30 days, then retry once. Usually recovers unattended; deletes files someone may still need.
- C. Leave it as is. Costs nothing now; failures stay unnoticed until morning.

Recommendation: A, because it reports every failure without deleting anything.

How should the job handle a full folder?
