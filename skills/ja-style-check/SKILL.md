---
name: ja-style-check
description: >
  Use this skill for Japanese writing and Japanese text revision unless the user only asks to
  inspect unrelated facts. Always trigger for requests to draft, rewrite, polish, summarize, or
  produce Japanese prose, including SKILL.md, PR descriptions, design docs, specs, README files,
  reviews, comments, and agent instructions. 必ず使う依頼: 「日本語で書いて」「文章を書いて」
  「説明文を書いて」「PR 文を書いて」「設計書を書いて」「README を書いて」「要約して」
  「自然な日本語にして」「日本語を直して」「文章を修正して」「読みやすくして」「文体を整えて」
  「曖昧表現をなくして」「括弧を減らして」「受動態を減らして」「実装っぽい文章を自然にして」.
  Do not trigger merely because the user says 「確認して」 or 「チェックして」 without asking for
  Japanese writing or style fixes.
---

# ja-style-check

Use this skill to write or revise Japanese prose with a strict style rubric.

## Mode

- `report`: do not edit files. Return findings and rewrite suggestions.
- `fix`: edit files. Apply only deterministic fixes, then report all judgment-based issues.
- no mode: use `fix` for existing files, and use the rubric while drafting new Japanese prose.

If the user asks to create Japanese text rather than edit files, read `references/rubric.md` before writing. Draft directly in the requested format, then run a self-review against the rubric 2 or 3 times before answering.

## Files

When file paths are provided, use them. Otherwise, target modified Markdown files. If no target file is discoverable, ask for the file or text.

## Required Resources

- Read `references/rubric.md` before judging prose or drafting Japanese prose.
- Read `references/fix-policy.md` before editing files.
- Read `references/output-schema.md` before returning report results.
- Run `scripts/scan.sh` for file-based work. The script performs deterministic detection and safe line-break fixes with standard shell tools.

## File Workflow

1. Determine the mode and target files.
2. Run the scanner:

```bash
bash skills/ja-style-check/scripts/scan.sh [--fix] [file...]
```

Use `--fix` only in `fix` mode.

3. Repeat the scanner 2 or 3 times:
   - Stop early if the JSON reports no applied fixes and no new deterministic candidates.
   - Never keep looping after the third pass.
4. Read the target files after the final pass.
5. Use the scanner JSON plus `references/rubric.md` to judge issues that need context.
6. In `fix` mode, do not edit judgment-based issues. Report them as manual suggestions.
7. Return the result using `references/output-schema.md`.

## Hard Limits

- Do not auto-rewrite meaning, intent, actor, terminology definitions, paragraph order, or implementation descriptions.
- Do not treat 「確認して」 or 「チェックして」 alone as a style-fix request.
- Do not rely on the scanner alone. It finds candidates; the agent still makes the final style judgment.
