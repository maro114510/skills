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

Repeated compression always cuts something. Push "make it shorter" without limit, and you eventually lose numbers, conditions, exceptions, and proper nouns — the things that hold the meaning together. The result still reads like natural prose, so the meaning shifts silently, which is more dangerous than simply running long.

To avoid this, fix a "safety list" of elements that must never be dropped before compression starts, and treat everything else as fair game for cutting. Never compressing past what the safety list allows is the only way to guarantee the meaning doesn't change — don't chase a higher compression ratio at the safety list's expense.

One more thing worth flagging: the goal isn't "fewer characters" as such — it's "the reader grasps the point fast." Watch only the character count, and stuffing several facts into parentheses to fit one sentence looks like a win: the visible length drops, but the reader now has to jump in and out of the parentheses to follow it, which makes the point harder to get, not easier. That's compression that shrinks the character count while making the text worse to read — a fake compression, and it should be avoided.

## Scope

Handles pasted chat text or a file path passed via `$ARGUMENTS`. Works regardless of length or language. Ask the user if the target isn't clear.

## Procedure

### Step 1: Extract the safety list

Before compressing anything, list out every element in the source text that falls into these categories.

- Numbers, units, dates, deadlines
- Conditional clauses: "if X", "unless", "except for", etc.
- Proper nouns, IDs, product names, personal names, URLs
- Negations and exceptions: "not X", "excluding X", etc.
- Conclusions, decisions, recommendations
- The skeleton of a causal claim, i.e. why something happens. This is limited to a concrete explanation that ties a specific cause to a specific effect. Generic boilerplate justification such as "for the sake of convenience" or "to improve efficiency" does not belong on the safety list — that is decorative preamble and can be cut.

Treat this list as a constraint that no later pass may violate. Rewording is fine; dropping the information is not.

### Step 2: Summarize block by block

Split the document into meaning-bearing blocks such as sections or paragraphs, and for each one, boil it down to "what is this block actually saying" in one or a few sentences. Keep the safety-list elements in the text at this stage too.

### Step 3: Compress the whole document to a fixed point

On the text produced by stitching the block summaries together, repeat the following.

1. Record the character count before this pass.
2. Cut redundant phrasing, repeated claims, tangents, and decorative preambles. Don't relocate the cut information into a side note just to shave off characters. The anti-pattern here isn't a specific punctuation mark — parentheses, em dashes, and colons can all be used this way — it's forcing the reader to jump in and out of an aside to follow the sentence. Test it that way: if reading the sentence straight through, aside and all, breaks comprehension, fold what you're keeping into the main clause, or split it onto its own line under Step 5's structuring instead.

   Example with parentheses:
   - Disallowed (forces a jump in and out): "We're revising the expense policy (purpose: reduce employee burden). Reimbursements (under $50 each) no longer need original receipts."
   - Allowed (reads straight through): "We're revising the expense policy. Reimbursements under $50 no longer need original receipts."

   Example with an em dash — the same problem, different punctuation:
   - Disallowed: "The page was slow — mainly on mobile Safari, where simultaneous image decodes caused jank — but fine elsewhere."
   - Allowed: "The page was slow on mobile Safari, where simultaneous image decodes caused jank; other browsers were fine."

   Both disallowed versions mistake decorative or explanatory content for something that has to be parked mid-sentence instead of just stated. The allowed versions fold the same information into a clause that reads linearly, with no aside to jump in and out of.
3. Check whether every safety-list item is still present in the compressed text — reworded is fine, dropped is not. If even one is missing, discard this pass, revert to the previous version, and try a different cut.
4. Compare the character count before and after this pass, and handle the result as exactly one of these three cases.
   - The pass didn't shrink the text — the count stayed the same or grew: discard this pass's output, revert to the version from before this pass, and try a different cut on the next pass.
   - The pass shrank the text by 5% or more: keep this pass's output and run another pass.
   - The pass shrank the text, but by less than 5%: keep this pass's output as final, and stop iterating — this is the fixed point.
5. As a safety margin, stop after 5 passes even if the fixed point hasn't been reached. When the cutoff hits, keep the output of the most recent pass that wasn't discarded under the first case above.

### Step 4: Final consistency check

Compare the compressed text against the original and confirm the following.

- No claim was added that isn't in the original, and nothing was fabricated
- Nothing contradicts the original's conclusions
- No safety-list item was lost

If any of these fail, roll back to the pass where it broke and compress again with a different approach.

### Step 5: Present the result

If the compressed result still contains several independent points — cause, response, deadline, condition, and so on — don't cram them into one sentence; split them into short lines or bullets instead. A single point can stay as plain prose. Even if this adds a few characters, splitting the points is what actually lets the reader grasp "what this is saying" quickly, so give it the same priority as keeping the safety list intact.

Present only the compressed text. Don't show the iteration process or a before/after diff. Be ready to explain the safety-list contents, or why nothing more could be cut, if asked.

Don't rewrite the original file. Only update it if the user explicitly asks for the change to be applied there.

## Don't

- Start compressing before the safety list is fixed
- Drop a safety-list item — numbers, conditions, proper nouns, and the like — on the theory that "the meaning is the same." These usually can't be replaced by a paraphrase.
- Skip the safety-list check on any pass
- Invent information that isn't in the source text to push the compression ratio higher
- Relocate cut information into a side note — parentheses, em dashes, or any other jump-in-jump-out construction — just to shave off characters. If reading the sentence straight through breaks because of it, that isn't compression, regardless of which punctuation mark carries the aside.
- Keep cramming multiple independent points into one sentence instead of structuring them
- Keep compressing past the maximum pass count
