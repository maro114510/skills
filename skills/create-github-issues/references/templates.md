# Templates

## Summary format (Step 3)

Output this block and ask for approval:

```
## Issues to be created

### Epic (parent Issue)
**Title**: <Epic title>
**Summary**: <purpose in one line>

### Child Issues (N total)
| # | Title | Summary (one line) |
|---|-------|--------------------|
| 1 | <title> | <summary> |
| 2 | <title> | <summary> |

この内容で Issue を作成してよいですか？
追加・削除・タイトル修正があれば教えてください。
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
