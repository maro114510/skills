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

厳格なスタイル基準に従って、日本語の文章を書く、または修正する。

## モード

- `report`: ファイルを変更しない。指摘と修正案だけを返す。
- `fix`: ファイルを変更する。決定的な修正だけを適用し、判断が必要な問題は報告する。
- モード指定なし: 既存ファイルには `fix` を使う。日本語の文章を新規に書く場合は、ルーブリックを適用して作成する。

ユーザーがファイル編集ではなく日本語の文章作成を求めている場合は、書く前に `references/rubric.md` を読む。依頼された形式で直接書き、回答前にルーブリックに照らして 2〜3 回自己レビューする。

## 対象ファイル

ファイルパスが指定されている場合は、そのファイルを対象にする。指定がない場合は、変更済みの Markdown ファイルを対象にする。対象ファイルを特定できない場合は、ファイルまたは本文をユーザーに確認する。

## 必須リソース

- 文章を判定する、または日本語の文章を書く前に `references/rubric.md` を読む。
- ファイルを編集する前に `references/fix-policy.md` を読む。
- レポートを返す前に `references/output-schema.md` を読む。
- ファイルを対象にする作業では `scripts/scan.sh` を実行する。このスクリプトは、標準的な shell ツールで決定的な検出と安全な改行修正を行う。

## ファイル処理

1. モードと対象ファイルを決める。
2. スキャナーを実行する。

```bash
bash skills/ja-style-check/scripts/scan.sh [--fix] [file...]
```

`--fix` は `fix` モード、または既存ファイルを対象にするモード指定なしの実行で使う。

3. スキャナーを 2〜3 回繰り返す。
   - JSON の `applied_fixes` が 0 で、新しい決定的候補もない場合は早期終了する。
   - 3 回を超えて繰り返さない。
4. 最後の実行後に対象ファイルを読み直す。
5. スキャナーの JSON と `references/rubric.md` を使い、文脈判断が必要な問題を判定する。
6. `fix` モードでも、判断が必要な問題は編集しない。手動対応の提案として報告する。
7. `references/output-schema.md` に従って結果を返す。

## 厳守事項

- 意味、意図、行為者、用語定義、段落順、実装説明を自動で書き換えない。
- 「確認して」「チェックして」だけを文章スタイル修正の依頼として扱わない。
- スキャナーだけに依存しない。スキャナーは候補を見つけるだけであり、最終的なスタイル判断はエージェントが行う。
