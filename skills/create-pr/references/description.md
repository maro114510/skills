# PR Description

create-pr's Step 3 reads this file in full before writing the description.
Step numbers below are SKILL.md's.

## Template

When Step 1 printed a template, follow its contents without reading the file. Do not ignore it. Its checkboxes follow Step 3.2, which overrides every rule here.

- Fill in every section.
- Follow any inline comments or section-specific instructions.
- A template in another language keeps its structure, but fill it in natural `LANG` unless it explicitly requires otherwise.
- Write each template section by the Content of the section below serving the same purpose, such as Summary for "What", Background for "Why", and Test Plan for "How to test". Where the template's own instructions for a section explicitly require something else, they win; a prompt that only names the section's topic requires nothing else.
- Add the Manual Checks section at the end. Add any other section below there only for useful information that no template section holds, such as implementation details or risks.

## Sections

Each row's Content is the only rule for what its section holds, except where the template's own instructions win as above. Without a template, use these sections in this order as `##` headings: the `en` heading for `en`, the `ja` heading for `ja`.

| `en` | `ja` | Content |
|---|---|---|
| Background | 背景 | Why the change is needed, for a reviewer who lacks the surrounding context: the root problem, constraints, and why it matters now |
| Summary | 概要 | The outcome in 1-3 sentences: what is different once this merges and the problem it solves, such as "merged skills reach every local Claude Code, whatever branch is checked out" rather than "add X". Never how it is done, or the files touched or settings changed |
| Implementation Details | 実装方針 | Why this approach was chosen: the tradeoffs accepted and the alternatives rejected, when the diff, commits, or conversation show them. Never what each part does |
| Changes | 変更内容 | What changed, under `###` group headings by behavior or area rather than by code edit, each bullet giving the change's meaning to a user or reviewer |
| Impact | 影響範囲 | What merging affects: pages, features, APIs, data formats, configuration, workflows, or users, with breaking changes called out. Facts, not doubts |
| Concerns | 懸念点 | Unresolved uncertainty or open risk a reviewer should weigh, and where to focus review. Only when one genuinely exists, not merely because the change touches performance, defaults, existing behavior, compatibility, data formats, configuration, or APIs; when unsure, include it. Never an Impact fact restated, and never what was run |
| Future Considerations | 今後の検討事項 | Follow-up deliberately left out of this PR: what, why, and how it could improve things |
| Test Plan | テスト計画 | The verification performed and its result as terse evidence: commands run, tool limits hit, automated reviews passed. For UI changes, consider before/after screenshots |
| Manual Checks | 手動確認 | One unchecked box per line of Step 1's `== manual checks`, copied verbatim, adding `(#N)` only when several issues contribute. Omit the section when there are none |

## Writing Principles

Reviewers can read the diff. The PR description is valuable because it explains intent, judgment, risk, and context that the diff does not show.

- **One fact, one place**: Each fact, such as a file's purpose or a design decision, goes only in the section whose Content it fits. If it seems to fit two, keep it where the Content names it most specifically.
- **Omission**: Remove a section that is genuinely irrelevant, unless the template has it.
- **Large diffs**: When the diff has more than 20 files or 1,000 changed lines, organize the description into logical groups.
- **Line breaks**: Write each paragraph or bullet as a single source line, however long and even when the commit messages break lines, because GitHub renders every newline in a PR body as a line break.

## Compact Pass

Before Step 4, re-read the full draft once as a first-time reader with no other context, and check every sentence against the rule for the section that holds it, its Content or the template's instructions, and against Writing Principles. Move a sentence that fits another section's Content, delete one that fits none or restates a fact given earlier, and rejoin a broken line.

If nothing fails, keep the draft as written — depth is intentional for this skill's purpose as a design record, so do not cut content for brevity alone.

## Title

Step 4 writes the title by these rules.

- Use Conventional Commits format, with a scope when useful, e.g. `fix(location):`. For a breaking change add `!` after the type or scope, e.g. `feat(config)!:`.
- Keep it under 70 characters, and specific: `fix(auth): handle expired JWT on refresh`, not `fix: resolve crash`.
- For `en`, use the imperative mood: "add", not "added". For `ja`, keep the type and scope in English and write the subject in Japanese, e.g. `fix(auth): リフレッシュ時に期限切れの JWT を処理する`.
