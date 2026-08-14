# Fix Policy

Use deterministic edits only when the result is uniquely determined by the existing text.

## Deterministic Fixes

- Join a Japanese sentence split by a meaningless line break.
- Join mechanical 78-82 character wraps when the combined line remains readable and does not cross Markdown structure.

Apply these yourself with Edit; the scanner is read-only and will not touch the file. It marks only the second one `auto_fixable`, because a fixed-width wrap is unambiguous. A `line-break` finding carries `auto_fixable: false` since a sentence can legitimately end without `。`, so read the pair before joining.

When joining, add a space only if Latin script ends the first line and begins the second. A Japanese join takes no separator, and inserting one — or omitting one between two Latin words — fabricates a word that was never in the document.

## Model-Applied Fixes

Apply these in `fix` mode without asking. This skill's input is almost always AI-generated, not human prose whose voice must be preserved, so prefer fixing over reporting whenever the document itself grounds the direction. Read the whole file first, so each rewrite draws on existing context rather than invention.

When every scanner candidate and every manually-checked location (SKILL.md's heading/list/blockquote/table/URL sweep) resolves to a cleared false positive, zero edits and zero manual suggestions is the correct, complete result. Do not rewrite text that already satisfies a fix's goal just to demonstrate effort.

- **Brackets**: Every parenthetical supplement except a first-use definition must go. Fold the content into the surrounding prose, or delete it (rubric.md Check #2). Moving a definition that is already inside a bracket out into the sentence is allowed — it relocates information rather than adding it. Writing a definition the text never gave is forbidden below.
  - In headings, move the bracket content to the section body. Do not relocate the bracket within the heading string.
  - "Matches this file's existing style," "consistent with a sibling document," and "this is a technical/design-doc genre" are not exceptions. Apply this fix the same way regardless of document type or established convention.
  - A sentence whose only content is justifying the document's own bracket usage (e.g. "for consistency with existing documents") carries no information once that justification is rejected — delete the whole sentence, not just its brackets.
- **Meta prose**: Delete or rewrite prose that announces itself instead of saying the content, only when no information is lost (rubric.md Check #3).
- **Passive voice and inanimate subjects**: Rewrite to natural active Japanese using the actor already implied by context (rubric.md Check #8, #13). Do not invent a specific actor identity the text never states — that is forbidden below.
- **Latin script in Japanese prose**: Translate a bare Latin word into the Japanese term already used or implied elsewhere in the document. When the word is a runtime literal such as a mode name, flag, or command, wrap it in backticks instead of translating it — translating breaks the interface (rubric.md Check #8).
- **Code identifiers and implementation transcription**: Rewrite toward the reader-facing behavior when that behavior is stated or clearly inferable elsewhere in the same document (rubric.md Check #8, #9). Two distinct cases:
  - The identifier is the sentence's subject or condition (assignment-notation, rubric.md Check #8): remove it and rewrite the sentence around the reader-facing behavior, the same as the rubric's own example (`isPaid = true のとき〜` → `支払いが完了した注文を〜`). When no other passage defines the identifier's meaning, a plain-language rendering of its own name (e.g. `isBoosted` → `ブースト対象の`) is the correct fix — but only when the name itself unambiguously states the reader-facing behavior. An unclear or generic name (`flag3`, `tmpVal`) supplies no such behavior to render; the Safety Rule applies instead — preserve the text and report it rather than guessing at what the name might mean.
  - The identifier is cited only as a traceability reference to where the behavior is implemented (comparable to a PR or issue number, rubric.md Check #7): keep it in backticks; do not silently drop it. Add a reader-facing description only if the sentence doesn't already have one — if the prose already explains what it does, leave the sentence as-is.
- **Paragraph and section structure**: Split, reorder, or convert paragraphs to bullets, and reorder sections or headings, when the rubric's paragraph and structure checks indicate a clearer order (rubric.md Check #6, #10).
- **Argument rigor**: Narrow an overstated claim or restore a dropped causal mechanism when the correct scope is already evidenced in the text (rubric.md Check #11).
- **Reader load**: Remove decorative detail the later argument never uses (rubric.md Check #12).
- **Voice, perspective, and notation**: Rewrite fictional personas, generic actors, decorative dashes/bold, and packed headings (rubric.md Check #13, #14).

## Automatic Fixes Forbidden

Do not automatically edit the following. Report suggestions instead.

- Replacing vague words with concrete conditions, thresholds, or scope.
- Writing a first-use definition the text never supplied. Moving one that already exists inside a bracket is allowed above.
- Adding a hidden actor's specific, unstated identity — a named system, team, or component the text never states.
- Translating a Latin word when the document offers no Japanese equivalent and the word is not a runtime literal. Report it instead; a guessed translation can name the wrong concept.

Each needs a real-world fact the text usually lacks: the actual threshold, the term's true meaning, the actor's real identity. That holds whether the text is AI-generated or human-written, and guessing writes something false into the document.

## Recursive Passes

Run 2 or 3 passes for file-based work. A first pass may expose new line-break issues after joining lines. Stop after a pass that surfaces nothing new, or after the third pass. Report the number of passes.

## Safety Rule

If a candidate fix could change meaning, preserve the text and report it. The cost of a missed automatic fix is lower than the cost of silently corrupting meaning.

The Safety Rule takes priority over every Model-Applied Fix above. When the Safety Rule applies, always emit a manual suggestion explaining why the fix was skipped.
