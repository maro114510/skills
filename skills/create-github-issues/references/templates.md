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

Output this block and ask for approval:

```
## 作成する Issue の構成

### Epic（親 Issue）
**タイトル**: <Epic タイトル>
**サマリー**: <目的を1行で>

### 子 Issue（N 件）
| # | タイトル | 受け入れ条件ドラフト |
|---|---------|---------------------|
| 1 | <title> | <Given X / When Y / Then Z 形式の1行> |
| 2 | <title> | <Given X / When Y / Then Z 形式の1行> |

この構成と受け入れ条件ドラフトで本文生成に進んでよいですか？
追加・削除・タイトル修正・受け入れ条件の修正があれば教えてください。
```

## Epic body (Step 4)

```markdown
## 背景

{The context that created this Epic — specific details from the conversation}

## 目的

{What will be achieved when this Epic is complete}

## スコープ

**含まれるもの:**
- {List child Issue titles}

**含まれないもの:**
- {Intentionally excluded items}

## 受け入れ条件

### 理想状態
{What must be true when all child Issues are done}

### 検証方法
{How to confirm completion — E2E or integration checks}
```

## Child Issue body (Step 4)

```markdown
## 背景

{Why this task is needed, how it connects to the Epic, what goes wrong if it's missing}

## 要求

{Requirements the implementer must satisfy}

## 要件・仕様

{Concrete implementation details. If blocked on another Issue, note "Start after #XX."}

## 受け入れ条件

### 理想状態
{What must be true when done — concrete and verifiable}

### 検証方法
{Steps to verify. Manual: numbered steps. Automated: assert what, run which command.}
```

## Step 4.5: Body Review Format

Show all Issue bodies in the following format and ask for approval:

```
## Issue 本文レビュー

### Epic: <タイトル>

<Epic 本文全文>

---

### 子 Issue 1: <タイトル>

<子 Issue 1 本文全文>

---

### 子 Issue 2: <タイトル>

<子 Issue 2 本文全文>

---

上記内容で Issue を作成します。
修正があれば箇所を指定して教えてください。問題なければ「作成してください」と返信してください。
```
