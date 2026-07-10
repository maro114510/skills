# Fix Policy

Use deterministic edits only when the result is uniquely determined by the existing text.

## Automatic Fixes Allowed

- Join a Japanese sentence split by a meaningless line break.
- Join mechanical 78-82 character wraps when the combined line remains readable and does not cross Markdown structure.

The scanner may apply these fixes with `--fix`.

## Model-Applied Fixes

Apply these in `fix` mode without asking. The text this skill processes is almost always AI-generated rather than human prose whose voice must be preserved, so prefer applying a fix over reporting it whenever the correct direction is grounded in what the document already says. Read the whole file before fixing so each rewrite is grounded in existing context, not invented.

- **Brackets**: Rewrite parenthetical supplements by integrating the content into surrounding prose or restructuring to express it without brackets. Preserve first-use definitions (rubric.md Check #2).
  - In headings, move the bracket content to the section body. Do not relocate the bracket within the heading string.
- **Meta prose**: Delete or rewrite prose that announces itself instead of saying the content, only when no information is lost (rubric.md Check #3).
- **Passive voice and inanimate subjects**: Rewrite to natural active Japanese using the actor already implied by context (rubric.md Check #8, #13). Do not invent a specific actor identity the text never states — that is forbidden below.
- **Jargon translation**: Translate English jargon into the Japanese term already used or implied elsewhere in the document (rubric.md Check #8).
- **Code identifiers and implementation transcription**: Rewrite toward the reader-facing behavior when that behavior is stated or clearly inferable elsewhere in the same document (rubric.md Check #8, #9).
- **Paragraph and section structure**: Split, reorder, or convert paragraphs to bullets, and reorder sections or headings, when the rubric's paragraph and structure checks indicate a clearer order (rubric.md Check #6, #10).
- **Argument rigor**: Narrow an overstated claim or restore a dropped causal mechanism when the correct scope is already evidenced in the text (rubric.md Check #11).
- **Reader load**: Remove decorative detail the later argument never uses (rubric.md Check #12).
- **Voice, perspective, and notation**: Rewrite fictional personas, generic actors, decorative dashes/bold, and packed headings (rubric.md Check #13, #14).

## Automatic Fixes Forbidden

Do not automatically edit the following. Report suggestions instead.

- Replacing vague words with concrete conditions, thresholds, or scope.
- Adding first-use definitions.
- Adding a hidden actor's specific, unstated identity (a named system, team, or component the text never states).

These require real-world facts — the actual threshold, the term's true meaning, the actor's real identity — that are usually absent from the text itself, regardless of whether the text is AI-generated or human-written. Guessing at them risks writing something false into the document.

## Recursive Passes

Run 2 or 3 passes for file-based work. A first pass may expose new line-break issues after joining lines. Stop after a pass with no applied fixes, or after the third pass. Report the number of passes.

## Safety Rule

If a candidate fix could change meaning, preserve the text and report it. The cost of a missed automatic fix is lower than the cost of silently corrupting meaning.

The Safety Rule takes priority over every Model-Applied Fix above. When the Safety Rule applies, always emit a manual suggestion explaining why the fix was skipped.
