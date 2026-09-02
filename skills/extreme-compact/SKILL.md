---
name: extreme-compact
description: >
  Recursively compact AI-generated writing or an existing document down to its essential point,
  without changing the overall meaning. Strips redundant phrasing, repeated claims, tangents, and
  decorative preambles, leaving only what the text is actually trying to say. Numbers, dates,
  conditions, proper nouns, negations/exceptions, conclusions, and the causal chain behind them
  form a safety list that must never be dropped. Use this proactively for requests like
  "compress this", "make this more concise", "just give me the key points", "trim the fluff",
  "this AI output is too long", "the argument keeps wandering", "Extreme Compact", or "compact this as much as possible".
  Do not use it for simple typo fixes or general Japanese prose-style polishing — that's ja-style-check's job.
argument-hint: "[text | file path]"
allowed-tools: Read, Write
---

# extreme-compact

Compress a document, without changing its meaning, until only "what it's actually trying to say" remains.

## Why this process matters

Repeated compression always cuts something. Push "make it shorter" without limit and you lose numbers, conditions, exceptions, and proper nouns — the things holding the meaning together. The result still reads like natural prose, so the meaning shifts silently. That is more dangerous than running long.

So fix a safety list before compressing: the elements that must never be dropped. Everything else is fair game. Holding that line is the only guarantee the meaning survives, so never trade it for a higher compression ratio.

The goal is not fewer characters but a reader who grasps the point fast. Watch only the count, and stuffing several facts into parentheses to fit one sentence looks like a win: visible length drops while the reader now has to jump in and out of the aside to follow it. That is fake compression — shorter and worse to read.

## Scope

Handles pasted chat text or a file path passed via `$ARGUMENTS`. Works regardless of length or language. Ask the user if the target isn't clear.

**Japanese targets come out better if ja-style-check runs first.** It unfolds brackets into the sentence and replaces bare Latin words with Japanese, both of which lengthen the text, so compressing first only re-introduces what it would have removed.

This skill cannot run it: `allowed-tools` is Read and Write, with no Bash and no way to invoke another skill. So when the caller has already run ja-style-check, compress what it returned. Otherwise compress anyway and note in the reply that ja-style-check has not run and would improve the result. Never refuse the compression over this.

Either way its two rules bind the output: outside a first-use definition, the compressed Japanese carries no parenthetical supplement and no bare Latin word. See `skills/ja-style-check/references/rubric.md`, Checks #2 and #8.

## Procedure

### Step 1: Extract the safety list

Before compressing anything, list every element in the source text that falls into these categories.

- Numbers, units, dates, deadlines
- Conditional clauses: "if X", "unless", "except for"
- Proper nouns, IDs, product names, personal names, URLs
- Negations and exceptions: "not X", "excluding X"
- Conclusions, decisions, recommendations
- The skeleton of a causal claim: a concrete explanation tying a specific cause to a specific effect. Boilerplate justification such as "for convenience" or "to improve efficiency" is decorative preamble, not a safety-list item, and can be cut.

Treat this list as a constraint no later pass may violate. Rewording is fine; dropping the information is not.

### Step 2: Summarize block by block

Split the document into meaning-bearing blocks such as sections or paragraphs, and boil each down to what it is actually saying in one or a few sentences. Keep the safety-list elements at this stage too.

### Step 3: Structural redundancy check

Before touching individual sentences, compare the block summaries from Step 2 against each other for redundancy at the level of meaning, not wording. A block is redundant when it restates a claim, conclusion, or example another block already makes — an intro that previews what the body says, a conclusion that repeats the body verbatim, two paragraphs arguing the same point. Surface similarity between blocks that make genuinely distinct points is not redundancy; leave those alone.

For each redundant block found:

1. Decide which block is the fuller, primary statement and which is the restatement.
2. Check whether the restatement holds any safety-list element the primary block lacks — a number, condition, exception, or proper noun found only there. If so, merge that element into the primary block first.
3. Once nothing safety-list-relevant remains exclusively in the restatement, delete it.

Run this once, on the full set of block summaries, before entering the sentence-level loop below — it is a separate unit of cutting (whole blocks) from Step 4's (words and phrases), and the two must not be interleaved.

### Step 4: Compress the whole document to a fixed point

Stitch the surviving block summaries together, then repeat the following.

1. Record the character count before this pass.
2. Cut redundant phrasing, repeated claims, tangents, and decorative preambles. Don't relocate the cut information into a side note just to shave off characters. The anti-pattern isn't a specific punctuation mark — parentheses, em dashes, and colons all do it — it's forcing the reader to jump in and out of an aside. Test it that way: if reading the sentence straight through, aside and all, breaks comprehension, fold what you're keeping into the main clause, or split it onto its own line under Step 6.

   With parentheses:
   - Disallowed: "We're revising the expense policy (purpose: reduce employee burden). Reimbursements (under $50 each) no longer need original receipts."
   - Allowed: "We're revising the expense policy. Reimbursements under $50 no longer need original receipts."

   With an em dash, the same problem under different punctuation:
   - Disallowed: "The page was slow — mainly on mobile Safari, where simultaneous image decodes caused jank — but fine elsewhere."
   - Allowed: "The page was slow on mobile Safari, where simultaneous image decodes caused jank; other browsers were fine."

   Both disallowed versions park explanatory content mid-sentence instead of just stating it. The allowed versions fold the same information into a clause that reads linearly.

   Japanese sets a higher bar than the jump test: every parenthetical except a first-use definition is disallowed outright, and dashes inside a Japanese sentence fall under rubric.md Check #14. The jump test still governs English.
3. Check that every safety-list item is still present — reworded is fine, dropped is not. If even one is missing, discard this pass, revert, and try a different cut.
4. Compare the character count before and after, and handle the result as exactly one of three cases.
   - The count stayed the same or grew: discard this pass's output, revert to the version from before it, and try a different cut next pass.
   - The text shrank by 5% or more: keep this output and run another pass.
   - The text shrank by less than 5%: keep this output as final and stop. This is the fixed point.

   Measure against the text you were handed, which for Japanese is ja-style-check's output. Length added by a style rule — a bracket unfolded into the sentence, a Latin word replaced by its Japanese term — is not a failed pass. Never re-introduce a bracket or a bare Latin word to reach the 5% threshold; stop iterating instead.
5. As a safety margin, stop after 5 passes even if the fixed point hasn't been reached, keeping the most recent output that wasn't discarded under the first case above.

### Step 5: Final consistency check

Compare the compressed text against the original and confirm the following.

- No claim was added that isn't in the original, and nothing was fabricated
- Nothing contradicts the original's conclusions
- No safety-list item was lost

If any of these fail, roll back to the pass where it broke and compress again with a different approach.

### Step 6: Present the result

If the result holds several independent points such as cause, response, deadline, and condition, split them into short lines or bullets rather than cramming them into one sentence. A single point can stay plain prose. This costs a few characters and is what lets the reader grasp the text quickly, so give it the same priority as keeping the safety list intact.

Present only the compressed text. Don't show the iteration process or a before/after diff. Be ready to explain the safety-list contents, or why nothing more could be cut, if asked.

If the input was a file path, ask whether to overwrite that file with the compressed result after presenting it, and write it only once the user agrees. Chat-pasted text has no file to write back to, so it's presented only.

## Don't

- Start compressing before the safety list is fixed
- Compress Japanese that ja-style-check has not seen without saying so in the reply
- Drop a safety-list item — numbers, conditions, proper nouns — on the theory that "the meaning is the same". A paraphrase usually can't replace them.
- Skip the safety-list check on any pass
- Delete a block in the structural redundancy check without first confirming no safety-list element exists only there
- Invent information that isn't in the source text to push the compression ratio higher
- Relocate cut information into a side note — parentheses, em dashes, or any other jump-in-jump-out construction — just to shave off characters
- Re-introduce a parenthetical or a bare Latin word into Japanese output to shave off characters
- Keep cramming multiple independent points into one sentence instead of structuring them
- Keep compressing past the maximum pass count
