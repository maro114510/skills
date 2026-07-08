# Templates

## Step 1.5: Clarification Question Format

Enumerate each unclear item and ask for a response using the following format:

```
以下の点が不明確です。回答してから続行します。

**[粒度] <タスク名>について**
<具体的な二択または選択肢を提示した質問>

**[受け入れ条件] <タスク名>について**
<「完了した状態を1文で書けますか？」などの具体的な質問>

**[仕様] <項目名>について**
<解釈の余地がある点を明示した二択または質問>

すべての質問に回答してから Issue 作成を続行します。
仕様が未確定のまま進める場合は「とりあえず作って」と返信してください（[要確認] タグを付与して進みます）。
```

## Step 1.5: Warning Format

Output this when the user instructs to proceed with unresolved items:

```
[!] 以下の仕様は未確定のまま Issue を作成します。Issue 本文の該当箇所に [要確認] タグを付与します。

- <未確定項目1>
- <未確定項目2>
```

## Step 3: Summary Format

Output this block and ask for approval. Show every task's requirement/spec bullets and its dependency here — this is the main checkpoint for catching invented or misplaced content before it's written into a real Issue.

Use the same 12-task threshold as the Epic body template below: Mermaid for 12 or fewer tasks, the wave table for more. This preview must render in the same form the Epic will actually use — never show a Mermaid graph here if Step 4 is going to render a table, or vice versa.

```
## 作成する Issue の構成

### Epic（親 Issue）
**タイトル**: <Epic タイトル>
**サマリー**: <目的を1行で>

（会話で挙げられたタスク数と子 Issue 数が一致しない場合のみ記載: **会話からの構成変更**: <どのタスクをどう分割/統合したか、その理由を1〜2文で>）

（該当する場合のみ記載: **Epic分割の提案**: 依存関係が互いに独立した複数グループに分かれており件数も多いため、1つのEpicではなく<提案するEpic分割案>として別Epicに分けることも検討できます。このまま1つのEpicとして進めますか？）

### 依存関係プレビュー（仮ID、実 Issue 番号は作成後に確定）

​```mermaid
flowchart LR
  subgraph Wave1[Wave 1: 並列着手可]
    T1["T1: <タイトル>"]
  end
  subgraph Wave2[Wave 2: 並列着手可]
    T2["T2: <タイトル>"]
  end
  T1 --> T2
​```

（13タスク以上の場合は、上記グラフの代わりに以下の表を使う）

| Wave | 仮ID | タイトル | 依存 |
|------|------|---------|------|
| 1 | T1 | <タイトル> | なし |
| 2 | T2 | <タイトル> | T1 |

### 子 Issue（N 件）

#### T1: <タイトル>（Wave 1 / 依存: なし）
- 要件: <bullet> / <bullet>
- 仕様: <bullet>（決定済み事項がなければ「なし」と書く）
- 受け入れ条件ドラフト: <Given X / When Y / Then Z 形式の1行>

#### T2: <タイトル>（Wave 2 / 依存: T1）
- 要件: <bullet>
- 仕様: なし
- 受け入れ条件ドラフト: <Given X / When Y / Then Z 形式の1行>

この構成・依存関係・要件仕様ドラフトで本文生成に進んでよいですか？
追加・削除・タイトル修正・依存関係の修正・要件仕様の修正があれば教えてください。
```

## Epic body (Step 4)

Use the Mermaid variant when there are 12 or fewer child Issues; otherwise use the table variant.

### Mermaid variant (≤12 child Issues)

```markdown
## 背景

{The context that created this Epic — specific details from the conversation}

## 目的

{What will be achieved when this Epic is complete}

## スコープ

**含まれるもの:**
- {List child Issue titles}

**含まれないもの:**
- {Intentionally excluded items — only ones actually discussed. Omit this subsection entirely if the conversation never named an exclusion; don't invent one just to fill the template.}

## 依存関係と並列実行計画

​```mermaid
flowchart LR
  subgraph Wave1[Wave 1: 並列着手可]
    T1["{{T1}} <タイトル>"]
  end
  subgraph Wave2[Wave 2: 並列着手可]
    T2["{{T2}} <タイトル>"]
  end
  T1 --> T2
​```

## 受け入れ条件

### 理想状態
{What must be true when all child Issues are done}

### 検証方法
{How to confirm completion — E2E or integration checks}
```

### Table variant (>12 child Issues)

Replace the `## 依存関係と並列実行計画` section with:

```markdown
## 依存関係と並列実行計画

子 Issue 数が多いため、グラフではなく表で示す。同じ Wave 内は並列着手可能。

| Wave | Issue | タイトル | 依存 |
|------|-------|---------|------|
| 1 | {{T1}} | <タイトル> | なし |
| 1 | {{T4}} | <タイトル> | なし |
| 2 | {{T2}} | <タイトル> | {{T1}} |
```

## Child Issue body (Step 4)

```markdown
## 背景

{Why this task is needed, how it connects to the Epic — 1〜3文}

## 要件

- {Observable/functional requirement grounded in the conversation. No implementation detail.}
- {Up to 5 bullets total}

## 仕様

- {Concrete technical decision already settled in the conversation}
- {Up to 5 bullets. Omit this entire section if nothing was actually settled — never invent one.}

## 依存関係

{"Tn の完了後に着手可能。全体の依存関係は Epic を参照。" または "なし（並列着手可能）"。ステップ列挙や理由の詳細はここに書かない。}

## 受け入れ条件

### 理想状態
{What must be true when done — concrete and verifiable}

### 検証方法
{Up to 5 items. Manual: numbered steps. Automated: assert what, run which command. If it takes more than 5 to cover the real scenarios, that's a signal this Issue should be split — see Step 2.}
```

**Banned in every section above:** lettered step sequences (`a→b→c→d`), pseudocode, function signatures, multi-level nested bullets. If a task genuinely needs that much detail to specify, split it into more child Issues, or add a single line linking to an existing design doc — never restate the doc inline.

## Step 4.5: Body Review Format

Show all Issue bodies in the following format and ask for approval:

```markdown
## Issue 本文レビュー

`{{Tn}}` は仮のプレースホルダーです。子 Issue 作成後、実際の Issue 番号（例: #123）に置換されて Epic に反映されます。

### Epic: <タイトル>

<Epic 本文全文（{{Tn}} プレースホルダーのまま）>

---

### 子 Issue T1: <タイトル>

<子 Issue T1 本文全文>

---

### 子 Issue T2: <タイトル>

<子 Issue T2 本文全文>

---

上記内容で Issue を作成します（Epic は子 Issue 番号確定後に作成されるため、Epic が最後に作成されます）。
修正があれば箇所を指定して教えてください。問題なければ「作成してください」と返信してください。
```
