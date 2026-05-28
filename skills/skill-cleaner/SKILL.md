---
name: skill-cleaner
description: >
  Claude Code スキルのトークン予算圧迫・重複・冗長 description を監査してスリム化するスキル。
  スキルディレクトリを引数に渡すと、各スキルの description / body のトークンコスト一覧と
  重複検出レポートを生成し、description 圧縮案を提案する。承認後にファイルを編集する。
  スキルが増えて重くなってきた・context budget を節約したい・description を短くしたい
  といった場面で使う。/skill-cleaner <skills-dir> の形式で呼び出す。
allowed-tools: Bash(find:*, wc:*, awk:*, sort:*), Read, Glob, Edit
argument-hint: "<skills-dir>"
---

# skill-cleaner

Claude Code のスキルディレクトリを監査し、トークン予算を削減しながらトリガー精度を守る。

## Step 0 — 引数ガード

`$ARGUMENTS` が空なら即座に停止して案内を表示する:

```
⚠️  Usage: /skill-cleaner <skills-dir>

例:
  /skill-cleaner ./skills
  /skill-cleaner ~/.claude/plugins/cache/my-plugin/unknown/skills
  /skill-cleaner ~/.claude/plugins/cache
```

## Step 1 — スキャン

```bash
find "$ARGUMENTS" -name "SKILL.md" | sort
```

ファイルが 0 件なら「SKILL.md が見つかりませんでした」と表示して終了する。

各 SKILL.md を Read で読み取り、frontmatter（最初の `---` ペアで囲まれた YAML）から次を抽出する:
- `name` — スキル名（未定義なら親ディレクトリ名）
- `description` — 説明文（複数行 folded-block `>` も結合して 1 文字列に）
- `allowed-tools` — （参考情報として記録するだけ）

バイト数の取得:
```bash
wc -c < "path/to/SKILL.md"        # ファイル全体
echo -n "description string" | wc -c   # description のみ（先頭/末尾の空白・改行をトリムした文字列を渡す）
```

トークン推定（日本語・英語混在に対応した保守的な値）:
```
desc_tokens = ceil(desc_bytes / 3)
body_tokens = ceil((file_bytes - desc_bytes) / 3)
```

## Step 2 — 予算レポート

次の Markdown テーブルを出力する:

```
## Skill Budget Report — <skills-dir>

| スキル名 | パス（相対） | desc tokens | body tokens | フラグ |
|----------|------------|------------|------------|--------|
| pr-review-pe | pr-review-pe | 87 | 1,240 | ⚠️ desc >60 |
| create-pr    | create-pr    | 45 |   380 | —          |

**常時コンテキスト圧迫**: NNN tokens（description の合計）
**最大ボディ**: skill-name（NNN tokens、トリガー時のみ読込）
```

パス列は `$ARGUMENTS` をルートとした相対パス（`find` の出力から `$ARGUMENTS/` プレフィックスを除いたもの）を使う。

フラグ基準:
- `⚠️ desc >60` — description が 60 token 超（常時 context に乗るコスト）
- `⚠️ body >800` — body が 800 token 超（参考情報）
- `🔴 dup:<他のパス>` — 同じ `name:` 値が別ファイルにも存在する

重複検出: 収集した全 `name:` 値を比較し、同名が 2 件以上あれば全インスタンスにフラグを付ける。

## Step 3 — 圧縮案の提案

`⚠️ desc >60` のフラグが付いたスキルごとに、description の圧縮案を作成する。

**圧縮ルール**（守れない場合は圧縮しないほうがよい）:
1. トリガー名詞・動詞を必ず残す（ユーザーが言いそうな言葉、スキルが何をするか）
2. `argument-hint` や body、スキル名で自明な説明は削除してよい
3. 目標 ≤ 60 tokens（≈ 日本語 180 バイト・英語 240 バイト）

各提案を before/after 形式で表示する。提案文を書いたら、同じ `ceil(bytes/3)` 式でトークン数を概算してヘッダに付記する:

```
### pr-review-pe — description (87 → 42 tokens)

**変更前 (87 tokens):**
コード差分 PR (Layer-1) 専用の Principal Engineer 視点レビュースキル。...

**提案 (42 tokens):**
コード差分 PR の PE 視点レビュー。正確性・アーキテクチャ・セキュリティ等 7 観点 +
AI 固有リスクを検査。「コードレビューして」「PE レビュー」で起動。
Markdown 専用 PR は /pr-doc-review-pe を使う。
```

提案が 1 件もない場合は「圧縮対象なし — すべての description が 60 tokens 以下です」と表示して終了する。

## Step 4 — 適用

提案後、ユーザーに「どのスキルの変更を適用しますか？（例: "pr-review-pe と create-pr" または "すべて"）」と聞く。

ユーザーが承認したスキルのみ、Edit ツールで SKILL.md frontmatter の `description:` フィールドを更新する。
- body・`allowed-tools`・その他のフィールドは変更しない
- YAML の folded-block スタイル（`description: >`）を元のスタイルに合わせて維持する
- 1 スキルにつき 1 回の Edit 呼び出しでまとめる

適用後にサマリーを表示する:
```
適用完了: N スキル変更。description 予算: XXX → YYY tokens (−ZZZ)
```

## 編集ポリシー

- 提案のみ行い、明示的な承認なしには編集しない。
- スキルファイル・ディレクトリの削除・リネームは行わない。
- 重複スキルの削除はユーザーが手動で行う（このスキルは特定と案内のみ）。
