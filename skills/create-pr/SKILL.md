---
name: create-pr
description: >
  Pull Request を作成するスキル。ブランチの差分とコミット履歴を分析し、変更理由・影響範囲・
  改善点・懸念事項を含む高品質な PR description を生成して `gh pr create` で作成する。
  /create-pr で呼び出す。引数にはベースブランチやドラフト指定などを渡せる。
  PR を作りたい、プルリクエストを出したい、レビューに出したい、といった依頼でも使うこと。
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep
argument-hint: "[draft] [base <branch>]"
---

# create-pr

ブランチの変更を分析し、レビュアーにとって価値ある PR を GitHub に作成する。

## 引数

`$ARGUMENTS` を解析する:

- 引数なし → ベースブランチ自動検出、通常 PR
- `draft` → ドラフト PR
- `base <branch>` → ベースブランチ指定
- 組み合わせ可（例: `draft base develop`）

## Step 1. コンテキスト収集 + PR テンプレートの検出

以下を並列で実行する:

**1.1 ブランチ・リモート状態の確認**

```bash
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "no upstream"
git remote show origin | grep 'HEAD branch'
git status --short
```

**1.2 PR テンプレートの検索**

以下の優先順で検索し、最初に見つかったものを Step 3 で使用する:

1. `.github/PULL_REQUEST_TEMPLATE.md`
2. `.github/pull_request_template.md`
3. `docs/pull_request_template.md`
4. `PULL_REQUEST_TEMPLATE.md`

テンプレートが見つかった場合はその内容を読み込んでおく（Step 3 で参照する）。

**1.3 ベースブランチ確定後に差分を取得**

```bash
git log --oneline <base>..HEAD
git diff --stat <base>...HEAD
git diff <base>...HEAD
```

**1.4 中断条件の確認**

以下のいずれかに該当したらユーザーに報告して停止する。メッセージはリポジトリの言語慣習に合わせる:

- 現在のブランチがベースブランチ自体（PR を作れない）→ ブランチ作成を提案
- コミットが 0 件（差分なし）→ コミット忘れがないか確認
- 未コミット変更がある → コミット忘れの可能性を確認（ユーザーの判断を仰ぐ）

## Step 2. 変更の分析

差分とコミット履歴（**最新コミットだけでなく全コミット**）から以下を読み取る:

**2.1 変更の種類と動機**

- 種類: feat / fix / refactor / docs / chore / deps / perf
- 動機: なぜこの変更が必要だったか（コミットメッセージ・コード変更・ブランチ名から推論）
- 根拠: 採用したアプローチの理由、検討した代替案があれば比較

**2.2 影響範囲とリスク**

- 影響範囲: 変更されたモジュール・ページ・API がアプリケーションのどこに波及するか
- 改善点: 何が良くなるか
- リスク: 破壊的変更、エッジケース、パフォーマンス影響、将来の技術的負債
- 示唆: この変更が示す将来的な方向性や含意

**2.3 関連 Issue の抽出**

ブランチ名・コミットメッセージから `#NNN` を抽出する。クローズするものは `Closes #NNN`、参照のみは `Related: #NNN` として使い分ける。

差分が大きい場合（20 ファイル超 or 1000 行超）は論理グループに分けて整理する。

## Step 3. PR description の生成

### 3.1 言語の決定

リポジトリの言語慣習を以下の順で判定し、PR description とユーザーへの全メッセージに適用する:

1. 既存 PR の description 言語（`gh pr list --limit 5` で確認）
2. コミットメッセージの言語
3. 判断つかなければ英語

### 3.2 テンプレートが存在する場合

Step 1.2 で取得したテンプレートの内容に必ず従う（テンプレートの無視は許容しない）:

- テンプレートの全セクションを埋める。各セクションのコメント指示があればそれに従う
- テンプレートにないが価値ある情報（背景、実装詳細、懸念事項、示唆）は末尾に追加セクションとして付与
- チェックリストは変更内容に照らして適切にチェック/アンチェック

### 3.3 テンプレートがない場合のデフォルト構造

```markdown
## Background

<!-- なぜこの変更が必要か。問題の根本原因、背景となる経緯、制約。diff からは読み取れない「なぜ今か」を書く -->

## Summary

<!-- 何を・どう変えたか。1-3 文。問題 → 原因 → 解決策の流れで書く -->

## Implementation Details

<!-- 実装アプローチと採用した根拠。代替案を検討した場合はその比較と棄却理由 -->

## Changes

<!-- 変更内容。大きな変更は論理グループに分ける -->

### [グループ名]
- 変更の意味を伝える説明（コードレベルの詳細ではなく）

## Impact

<!-- 影響を受けるページ・機能・API。破壊的変更があれば明示 -->

## Concerns

<!-- レビュアーに注目してほしい点、既知リスク、トレードオフ、代替案を検討した経緯、この変更が示唆する将来的な含意 -->

## Future Considerations

<!-- この PR では対応しないが将来検討すべき事項。何を・なぜ・どう改善するか具体的に -->

## Test Plan

<!-- テスト方法と確認結果。UI なら before/after スクリーンショットも検討 -->
```

### 3.4 記述の原則

レビュアーは diff を読める。description の価値は diff からは読み取れない「意図」と「判断」を伝えること。

- **Background**: 変更の文脈を知らないレビュアーでも「なぜこれが必要か」を理解できるように書く
- **Summary**: 「〜を追加」ではなく「〜の問題を解決するために〜を追加」
- **Implementation Details**: 「こう実装した」だけでなく「なぜそう実装したか」「他に何を検討したか」を書く
- **Concerns**: 正直に書く。自信がない部分、代替案を捨てた理由、レビュアーが重点的に見るべき箇所、この変更が持つ将来への示唆
- **省略ルール**: 懸念や将来課題が本当にない場合はセクションごと省略してよい。ただし、パフォーマンスに影響する変更・デフォルト値の変更・既存動作の変更がある場合は必ず Concerns に記載する

## Step 4. PR タイトルの決定

**4.1 形式**

- **Conventional Commits 形式**: `feat:`, `fix:`, `refactor:` 等。スコープがあれば `fix(location):` のように付与
- **70 文字以内**
- **命令形**: "add" not "added"
- **具体的に**: "fix: resolve crash" ではなく "fix(auth): handle expired JWT on refresh"

**4.2 既存 PR との整合**

リポジトリに既存 PR があればそのタイトル慣習を確認して合わせる。

## Step 5. メタデータの検討

PR 作成前に以下を確認・提案する。ユーザーの判断を仰いだうえで `gh pr create` のオプションに反映する。

**5.1 Assignee**

`--assignee @me` を付与することを提案する。

**5.2 Labels**

```bash
gh label list
```

変更の種類（feat / fix / refactor 等）と影響範囲を照らし合わせ、適切なラベルを提案する。

**5.3 Milestone**

```bash
gh milestone list
```

オープンなマイルストーンがあれば、変更内容との関連を確認して紐づけを提案する。

**5.4 Issue リンク**

Step 2.3 で抽出した Issue 番号を description に含めていることを確認する。`Closes` で自動クローズするか `Related` で参照のみにするかをユーザーと確認する。

## Step 6. push と PR 作成

**6.1 push**

```bash
git push -u origin <current-branch>
```

**6.2 PR 作成**

```bash
gh pr create \
  --title "<title>" \
  --body "$(cat <<'EOF'
<description>
EOF
)" \
  [--draft] \
  [--base <base-branch>] \
  [--assignee @me] \
  [--label "<label>"] \
  [--milestone "<milestone>"]
```

**6.3 完了**

作成後、PR の URL を表示し `gh pr view --web` でブラウザを開く。
