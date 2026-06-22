# Fix Policy

Use deterministic edits only when the result is uniquely determined by the existing text.

## Automatic Fixes Allowed

- Join a Japanese sentence split by a meaningless line break.
- Join mechanical 78-82 character wraps when the combined line remains readable and does not cross Markdown structure.

The scanner may apply these fixes with `--fix`.

## Model-Applied Fixes

Apply these in `fix` mode without asking. They require judgment but have a clear correct direction.

- **Brackets**: Rewrite parenthetical supplements by integrating the content into surrounding prose or restructuring to express it without brackets. Preserve first-use definitions (rubric.md Check #2).
  - In headings, move the bracket content to the section body. Do not relocate the bracket within the heading string.

## Automatic Fixes Forbidden

Do not automatically edit the following. Report suggestions instead.

- Deleting meta prose.
- Replacing vague words with concrete conditions.
- Adding first-use definitions.
- Adding hidden actors.
- Rewriting passive voice.
- Translating jargon.
- Replacing code identifiers with behavior.
- Reordering paragraphs.
- Reordering sections or headings.
- Rewriting implementation transcription.
- Strengthening or weakening uncertainty.
- Splitting causes, responsibilities, or concepts.
- Removing details as decorative.
- Rewriting voice, perspective, or actor framing.
- Changing notation, emphasis, or heading wording.

These require context, domain knowledge, or intent that may not exist in the text.

## Recursive Passes

Run 2 or 3 passes for file-based work. A first pass may expose new line-break issues after joining lines. Stop after a pass with no applied fixes, or after the third pass. Report the number of passes.

## Safety Rule

If a candidate fix could change meaning, preserve the text and report it. The cost of a missed automatic fix is lower than the cost of silently corrupting meaning.

The Safety Rule takes priority over Model-Applied Fixes. When the Safety Rule applies, always emit a manual suggestion explaining why the fix was skipped.
