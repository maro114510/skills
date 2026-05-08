---
name: pr-lessons
description: >
  過去の PR レビューコメントを GitHub から収集し、技術的な指摘・セキュリティ・組織固有の規約という
  3観点で教訓をまとめた Markdown を生成するスキル。
  「PRレビューの教訓をまとめて」「過去のレビューから学びを抽出して」「PR履歴から気をつけるべきことを整理して」
  「コードレビューのフィードバックを観点別にまとめたい」「PRのレビューコメントを分析して」
  「過去のレビューで指摘されたことを整理したい」「自分の PR の傾向を知りたい」
  「開発の振り返りをしたい」「PR履歴から改善点を抽出して」「指摘パターンを洗い出して」
  「レビューで何を学んだかまとめて」「振り返りドキュメントを作りたい」「コードレビューで繰り返し指摘されたことを教えて」
  「repo <owner/repo> のPRレビューから振り返りを作って」といった依頼で積極的に使うこと。
  引数に `repo <owner/repo>` でリポジトリ、`since <YYYY-MM-DD>` で取得開始日を指定できる。
  指定がない場合はカレントディレクトリの git リポジトリ・直近3か月がデフォルト。
allowed-tools: Bash, Read, Write, Agent
argument-hint: "[repo <owner/repo>] [since <YYYY-MM-DD>]"
---

# pr-lessons

PR レビュー教訓まとめ。責務の分担：

| 担当 | 処理内容 |
|---|---|
| `scripts/fetch-pr-reviews.sh` | データ収集（決定論的: gh 呼び出し・jq 変換） |
| `references/batch-agent-prompt.md` | バッチ分析 Agent へのプロンプトテンプレート |
| `references/summary-format.md` | 最終 Markdown のフォーマット仕様 |
| この SKILL.md | 引数解釈・スクリプト起動・Agent 管理・統合判断 |

## Step 0: スキルディレクトリの特定

```bash
SKILL_DIR=$(find ~/.claude/plugins -path "*/pr-lessons" -type d 2>/dev/null | head -1)
[ -z "$SKILL_DIR" ] && SKILL_DIR=$(find "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" \
  -path "*/pr-lessons" -type d 2>/dev/null | head -1)
```

以降 `$SKILL_DIR/scripts/` と `$SKILL_DIR/references/` を使う。

---

## Step 1: 引数のパースとデフォルト値の決定

`$ARGUMENTS` から以下を解析する：

| 引数パターン | 例 | 意味 |
|---|---|---|
| `repo <owner/repo>` | `repo myorg/myapp` | 対象リポジトリを明示指定 |
| `since <YYYY-MM-DD>` | `since 2025-02-01` | 取得開始日を明示指定 |
| 省略 | — | 下記デフォルト値を使用 |

```bash
# リポジトリ: git remote から自動判定（SSH/HTTPS 両対応）
git remote get-url origin \
  | sed 's|.*github.com[:/]\(.*\)\.git|\1|' \
  | sed 's|.*github.com[:/]\(.*\)|\1|'

# 取得開始日: 今日から 90 日前（macOS / Linux 自動判定）
date -v-90d +%Y-%m-%d 2>/dev/null || date -d '90 days ago' +%Y-%m-%d
```

リポジトリが特定できない場合はユーザーに `repo <owner/repo>` を指定するよう案内して停止する。

---

## Step 2: データ収集

```bash
bash "$SKILL_DIR/scripts/fetch-pr-reviews.sh" "<owner/repo>" "<since>"
```

終了コードに応じた処理：

| 終了コード | 意味 | 対応 |
|---|---|---|
| 0 | 成功 | Step 3 へ |
| 1 | 期間内に自分の PR が 0 件 | 期間拡大を提案して停止 |
| 2 | 全 PR がスキップ（レビューなし） | `skipped.json` を Read してスキップ一覧を報告して停止 |
| 3 | 引数不足 / gh 認証エラー | エラーメッセージを報告して停止 |

成功後に `/tmp/pr-lessons/summary.json` を Read してリポジトリ・期間・件数を確認する。

---

## Step 3: バッチ分割と順次 Agent 分析

`/tmp/pr-lessons/raw/pr-*.json` を確認し、**3 件ずつのバッチ**に分割する。

`$SKILL_DIR/references/batch-agent-prompt.md` を Read してプロンプトテンプレートを取得し、
対象ファイルパスとバッチ番号を差し替えて各 Agent に渡す。

**順次（直列）**で Agent を起動する。並列起動は行わない。

---

## Step 4: 全バッチの統合

`$SKILL_DIR/references/summary-format.md` を Read してフォーマット仕様を確認する。

全 `/tmp/pr-lessons/batch-*.md` を Read で読み込み、フォーマット仕様に従って統合し、
カレントディレクトリの `lessons-summary.md` に Write で保存する。
