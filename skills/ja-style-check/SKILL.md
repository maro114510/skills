---
name: ja-style-check
description: >
  Use this skill for Japanese writing and Japanese text revision unless the user only asks to
  inspect unrelated facts. Always trigger for requests to draft, rewrite, polish, summarize, or
  produce Japanese prose, including SKILL.md, PR descriptions, design docs, specs, README files,
  reviews, comments, and agent instructions. Holds Japanese output to near-zero parentheses and
  no bare Latin words inside a Japanese sentence.
  「日本語で書いて」「文章を修正して」「自然な日本語にして」「要約して」「括弧を減らして」「読みやすくして」「文体を整えて」でも起動。
  Do not trigger merely because the user says 「確認して」 or 「チェックして」 without asking for
  Japanese writing or style fixes.
---

# ja-style-check

Write or revise Japanese prose against a strict style standard.

## Modes

- `report`: return findings and suggestions, change no files.
- `fix`: edit files. Apply everything under Model-Applied Fixes in `references/fix-policy.md` even when it takes judgment, and report the rest.
- No mode given: use `fix` on an existing file. To write new Japanese prose, apply the rubric while drafting.

When the user wants new prose rather than a file edit, read `references/rubric.md` first, write directly in the requested format, and self-review against the rubric two or three times before answering.

## Target files

Use the path the user gives. With no path, use the modified Markdown files. If neither identifies a target, ask for the file or the text.

## Required reading

- `references/rubric.md` before judging prose or writing Japanese.
- `references/fix-policy.md` before editing a file.
- `references/output-schema.md` before returning a report.

## File workflow

1. Settle the mode and the target files.
2. Run the scanner. It reports candidates and never edits anything.

```bash
bash skills/ja-style-check/scripts/scan.sh [file...]
```

3. Apply the fixes yourself with Edit, including the line joins. `mechanical-wrap` comes marked `auto_fixable`; `line-break` does not, so read that pair before joining it. When you join two lines, add a space only if Latin script ends the first and begins the second; a Japanese join takes no separator.
4. Re-run the scanner after editing to pick up candidates the joins exposed. Stop once a run surfaces nothing new, and never exceed three runs.
5. Judge the context-dependent findings using the scanner output and `references/rubric.md`.
6. In `fix` mode, edit every Model-Applied Fix: brackets, Latin script in Japanese sentences, meta prose, passive voice, jargon, code identifiers, paragraph and section structure, weak argument, reader load, voice, and notation. Report the Automatic Fixes Forbidden items — vague thresholds, absent first-use definitions, a hidden actor's real identity — as manual suggestions.
7. Return the result in the shape `references/output-schema.md` defines.

## Compression

When the user also asks to shorten the text, finish this skill first, then hand the result to extreme-compact. That order is deliberate: unfolding brackets and translating Latin words lengthens the text, so compressing first only re-introduces what this skill removes.

## Non-negotiable

- Never guess a real-world fact the text doesn't state: a vague word's threshold, a term's definition, a hidden actor's identity. When a fix could change meaning, report it instead of editing (the Safety Rule in `references/fix-policy.md`).
- 「確認して」 and 「チェックして」 alone are not requests for style fixes.
- Never rely on the scanner alone. It only finds candidates; the agent makes the style call.
- The scanner reports `brackets` as `high` without knowing whether an exception applies. Decide per rubric Check #2 whether the bracket is a first-use definition, or Markdown syntax such as a link target, and clear the finding when it is.
- **Latin script in Japanese prose has no scanner rule.** Check #8 is yours to apply by reading. A deterministic version was attempted and withdrawn: telling a Japanese sentence containing English from an English sentence quoting Japanese kept producing missed violations, and this repo's own skill bodies are now English with Japanese examples, so the false positives landed on correct text. Read for it; do not expect a finding.
- The scanner sees paragraph text only. Headings, list items, blockquotes, table rows, and any line carrying a URL are skipped by every rule, so read those lines yourself rather than treating a short finding list as a clean bill of health.
- The scanner never writes. It has no `--fix`; the flag is accepted and ignored. Every edit goes through Edit so you can see and review it.
