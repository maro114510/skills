# Output Schema

Return concise Markdown. For file-based work, include the structured summary first.

The section labels below are Japanese on purpose — the user reads them. Keep them verbatim even though the surrounding instructions are English.

## Report Mode

```text
結果:
- mode: report
- passes: N
- files: [path...]
- auto_applied: 0
- findings: M

指摘:
1. [severity / rule / path:line] Quote
   Reason.
   Suggestion: ...

総評:
...
```

## Fix Mode

```text
結果:
- mode: fix
- passes: N
- files: [path...]
- auto_applied: N
- manual_suggestions: M

自動修正:
- [rule / path:line] ...

要手動対応:
1. [severity / rule / path:line] Quote
   Reason.
   Suggestion: ...
```

## Drafting Mode

Return the requested prose directly. Do not include a rubric report unless the user asks for one.

## Issue Object

When passing data between tools or summarizing scanner output, use this shape:

```json
{
  "rule": "line-break | brackets | meta-prose | vague-claim | mechanical-wrap | paragraph-rhythm | first-use-definition | assignment-notation | reader-facing-japanese | implementation-transcription | structure-headings | argument-rigor | reader-load | voice-perspective | notation-emphasis",
  "severity": "high | medium | low",
  "path": "relative/path.md",
  "line": 12,
  "quote": "problematic text",
  "reason": "why this hurts readability",
  "suggestion": "rewrite direction",
  "auto_fixable": false
}
```

`auto_fixable` means the rewrite is uniquely determined by the text, so you can apply it without judgment. The scanner never applies it: `applied_fixes` in the scanner's output is always 0, and `auto_applied` in the Fix Mode report above counts what you applied with Edit.
