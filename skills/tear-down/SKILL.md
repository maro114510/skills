---
name: tear-down
description: Tear down the plan, design, or conclusion on the table instead of defending or polishing it — a blank-slate red-team pass that discards every premise surviving only because "that's what we already decided." Use when a proposal needs to be ruthlessly stress-tested for fatal flaws or gaps in the reasoning, not merely cleaned up. Not for business-strategy Why interrogation (why-man) or completeness review of an already-written Design Doc/ADR/RFC (pr-doc-review-pe).
allowed-tools: Read, Glob, Grep, Bash(gh pr view:*, gh pr diff:*, gh issue view:*), Agent, AskUserQuestion
argument-hint: "[optional: file path | PR number | issue URL]"
---

Tear down the design, plan, or conclusion just proposed instead of defending or polishing it. The only question that matters: would you arrive at this if you built it up again from scratch, using only what's actually true and actually required? Anything standing only because "that's what we already decided" gets discarded, not cleaned up.

If `$ARGUMENTS` points to a file, PR, or issue, read or `gh` it and tear that down instead of the live conversation; otherwise the target is whatever's currently on the table.

You reasoned your way to the current design, so you're anchored on it. A real blank slate can't come from inside your own context. Spawn a fresh general-purpose Agent that has never seen this conversation, hand it only the requirements and constraints, and let it derive an answer independently. Never use subagent_type: fork here — it inherits your conclusions and defeats the whole point of starting blank.

Before sending anything to that agent, separate fact from conclusion. A requirement only counts if you can point to where it actually came from: the user's own words, a file:line, a ticket. Anything you can't source is not ground truth, it's a premise the design is resting on — including a rationale stated in the design's own voice, like "because GDPR requires it." That phrasing explains why the design believes itself justified; it isn't evidence the claim is true. Treat unsourced items as suspect rather than handing them to the blank-slate agent as fact.

Compare what comes back against the current design, point by point. Every divergence is worth digging into: something assumed that wasn't actually required, something required that got dropped, a tradeoff nobody checked. Verify each one yourself against real evidence — read the code, grep for it, pull the PR or issue — rather than taking either side's word for it or asking the user something you could have checked yourself. What holds up under that scrutiny stands; what only survived because of inertia or an unverified premise falls, even if the rest of the design still leans on it.

If something that falls looks fatal — breaks correctness, is irreversible once shipped, contradicts a constraint someone stated earlier, or rests on a legal, security, or compliance claim nobody actually checked — stop and put it to the user directly with AskUserQuestion right then, not buried in a wall of text they might skim past.

Done when nothing is left standing only because no one re-checked it: every premise of the current design either holds up on its own, or has been named as one that doesn't. Say what falls and why; leave rebuilding the design to the user.
