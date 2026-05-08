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

自分が作成した PR に付いたレビューコメントを収集・分析し、
技術・セキュリティ・組織固有の規約という3観点で教訓を抽出した Markdown を生成する。

---

## Step 1: 引数のパースとデフォルト値の決定

`$ARGUMENTS` から以下を解析する：

| 引数パターン | 例 | 意味 |
|---|---|---|
| `repo <owner/repo>` | `repo myorg/myapp` | 対象リポジトリを明示指定 |
| `since <YYYY-MM-DD>` | `since 2025-02-01` | 取得開始日を明示指定 |
| 省略 | — | 下記デフォルト値を使用 |

**デフォルト値の算出（Bash で実行）:**

```bash
# リポジトリ: git remote から自動判定（SSH/HTTPS 両対応）
git remote get-url origin \
  | sed 's|.*github.com[:/]\(.*\)\.git|\1|' \
  | sed 's|.*github.com[:/]\(.*\)|\1|'

# 取得開始日: 今日から 90 日前（macOS）
date -v-90d +%Y-%m-%d
# Linux の場合:
# date -d '90 days ago' +%Y-%m-%d
```

リポジトリが特定できない場合はユーザーに `repo <owner/repo>` を指定するよう案内して停止する。

---

## Step 2: 作業ディレクトリの準備

```bash
mkdir -p /tmp/pr-lessons/raw
```

---

## Step 3: PR 一覧の取得

```bash
gh pr list \
  --author @me \
  --repo <owner/repo> \
  --state all \
  --json number,title,url,createdAt,mergedAt,state \
  --limit 200 \
  > /tmp/pr-lessons/pr-list.json
```

取得後、`createdAt` が `<since>` 以降のものだけを `jq` でフィルタリングする：

```bash
jq '[.[] | select(.createdAt >= "<since>T00:00:00Z")]' \
  /tmp/pr-lessons/pr-list.json \
  > /tmp/pr-lessons/pr-list-filtered.json
```

**フィルタ後に PR が 0 件だった場合:** 期間を広げることを提案してユーザーに報告し、停止する。

---

## Step 4: 各 PR のレビューデータ取得

フィルタ後の PR 番号リストを取得し、1件ずつ以下を **順番に** 実行してデータを結合する。

```bash
# (a) PR 基本情報とディスカッションコメント
gh pr view <number> --repo <owner/repo> \
  --json number,title,body,comments \
  > /tmp/pr-lessons/raw/pr-<number>-base.json

# (b) レビュー本体（APPROVED / CHANGES_REQUESTED / COMMENTED などの review body）
gh api repos/<owner/repo>/pulls/<number>/reviews \
  > /tmp/pr-lessons/raw/pr-<number>-reviews.json

# (c) インラインレビューコメント（コード行に対する個別指摘）
gh api repos/<owner/repo>/pulls/<number>/comments \
  > /tmp/pr-lessons/raw/pr-<number>-inline.json
```

3ファイルを jq で結合して1つのファイルに保存する：

```bash
jq -s '{
  number:     .[0].number,
  title:      .[0].title,
  body:       .[0].body,
  discussion: .[0].comments,
  reviews:    .[1],
  inline:     .[2]
}' \
  /tmp/pr-lessons/raw/pr-<number>-base.json \
  /tmp/pr-lessons/raw/pr-<number>-reviews.json \
  /tmp/pr-lessons/raw/pr-<number>-inline.json \
  > /tmp/pr-lessons/raw/pr-<number>.json
```

一時ファイル（`*-base.json` / `*-reviews.json` / `*-inline.json`）は削除して構わない。

**レビューが一件もない PR はスキップ**: `reviews` と `inline` が両方空配列かつ `discussion` が空の場合。
スキップした PR 番号は後で一覧を報告する。

`gh` が認証エラーで失敗した場合は `gh auth status` を実行し、認証状態をユーザーに報告して停止する。

---

## Step 5: バッチ分割と順次 Agent 分析

レビューが存在する PR を **3 件ずつのバッチ** に分割する。

各バッチについて **順次（直列）** で Agent を起動する。並列起動は行わない。

### Agent に渡すプロンプトのテンプレート

```
以下のファイルに保存された GitHub PR のレビューデータを分析し、教訓を抽出してください。

対象ファイル（Read ツールで読み込む）:
- /tmp/pr-lessons/raw/pr-<N1>.json
- /tmp/pr-lessons/raw/pr-<N2>.json  ← バッチに含まれる場合
- /tmp/pr-lessons/raw/pr-<N3>.json  ← バッチに含まれる場合

JSON の構造:
- `reviews[].body`: レビュー全体コメント（state: APPROVED / CHANGES_REQUESTED / COMMENTED）
- `reviews[].user.login`: レビュアーのログイン名
- `inline[].body`: インラインコメント（コード行への個別指摘）
- `inline[].path`: 指摘対象のファイルパス
- `inline[].diff_hunk`: 指摘箇所の diff コンテキスト
- `discussion[].body`: PR ディスカッションの一般コメント

## 抽出する教訓の観点

以下の3観点を必ず使うこと。各観点の中で教訓を列挙する。

### 観点1: 技術的な指摘（コード品質・設計）
コードの構造、命名、型安全性、パフォーマンス、アーキテクチャ、テスト設計、
エラーハンドリング、DRY 原則など、技術的な内容に関する指摘。

### 観点2: セキュリティ・品質保証
セキュリティ脆弱性、入力バリデーション不足、シークレット露出リスク、
エラー時の挙動の不備、境界値・エッジケースの考慮漏れなど。

### 観点3: この組織固有の規約・文化的な慣習
「このプロジェクトでは」「チームのルールとして」「以前も同様の指摘があった」
などの文脈で言及された、チーム・組織特有のルール、暗黙知、慣習。
一般的なベストプラクティスと区別して分類すること。

## 出力フォーマット

以下の Markdown を /tmp/pr-lessons/batch-<B>.md に書き込む（Write ツールを使う）。
各教訓は H3 見出し＋説明段落＋参照行の3要素で構成し、`---` で区切ること。

---
## バッチ <B>（PR #<N1>「<タイトル>」, #<N2>「<タイトル>」, ...）

### 技術的な指摘

#### [教訓タイトル：動詞で始める短いフレーズ]

説明文。なぜ問題か・どうすればよいかを1〜3文で書く。
コード例があれば バッククォートで示す。

**参照 PR**: #<番号>「<PR タイトル>」（レビュアー: <名前>）

---

#### [次の教訓タイトル]

...

### セキュリティ・品質保証

#### [教訓タイトル]

説明文。

**参照 PR**: #<番号>「<PR タイトル>」（レビュアー: <名前>）

---

### 組織固有の規約・慣習

#### [教訓タイトル]

説明文。

**参照 PR**: #<番号>「<PR タイトル>」（レビュアー: <名前>）

---

レビューコメントが存在しない観点は見出しごと省略してよい。
教訓が読み取れないコメント（承認のみ、雑談など）は無視してよい。
```

---

## Step 6: 全バッチの統合

全バッチの処理が完了したら、全 `/tmp/pr-lessons/batch-*.md` を Read で読み込み、
以下のルールで統合し、カレントディレクトリの `lessons-summary.md` に Write で保存する。

### 統合ルール

1. **重複排除**: 同じ趣旨の指摘が複数バッチに存在する場合は1つにまとめ、`（複数PRで指摘: N回）` と注記する
2. **頻度順**: 同じ観点の中では、指摘回数の多い教訓を上位に配置する
3. **出典を保持**: 各教訓に「初出 PR: #xxx」を残す
4. **空の観点は省略**: 教訓が一件もない観点は見出しごと省略する

### 出力フォーマット

```markdown
# PR レビューから学んだ教訓

| 対象リポジトリ | `<owner/repo>` |
|---|---|
| 対象期間 | <since> 〜 <today> |
| 分析した PR 数 | <N> 件（レビューなしでスキップ: <M> 件） |
| 分析した PR 一覧 | #101「タイトル」, #102「タイトル」, ... |

---

## 1. 技術的な指摘（コード品質・設計）

### [教訓タイトル：動詞で始める短いフレーズ]

説明文（1〜3文）。

**参照 PR**: #xxx「PR タイトル」（レビュアー: xxx / 計 N 回指摘）

---

### [次の教訓]

...

---

## 2. セキュリティ・品質保証

### [教訓タイトル]

説明文。

**参照 PR**: #xxx「PR タイトル」

---

## 3. この組織固有の規約・文化的な慣習

### [教訓タイトル]

説明文。

**参照 PR**: #xxx「PR タイトル」

---

*生成日: <today> | スキル: pr-lessons*
```

---

## エラー処理まとめ

| 状況 | 対応 |
|---|---|
| `gh` 認証エラー | `gh auth status` を実行してユーザーに報告、停止 |
| フィルタ後 PR 0 件 | 期間拡大を提案してユーザーに報告、停止 |
| 個別 PR の取得失敗 | スキップし、最後にスキップ一覧を報告 |
| レビューなし PR | スキップ対象に含める |
| `/tmp/pr-lessons/` が書き込み不可 | ユーザーに報告して停止 |
