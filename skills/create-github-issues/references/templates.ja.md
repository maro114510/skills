# Templates (ja)

## Step 1.5: Clarification Question Format

Write each question as `references/question.md` says, and start its decision line with the label of its unclear axis: `[粒度]`, `[受け入れ条件]`, `[仕様]`, or `[前提]`.

End the message with these lines:

```
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

Output this block and ask for approval. This is the main checkpoint for catching invented or misplaced content before it's written into a real Issue, and — by default — the *only* checkpoint before creation: Step 4.5's full-body re-display is skipped unless the user asks for it (see Step 4.5), so this summary must carry enough substance (background, full verification list) that approving it is equivalent to approving the final bodies.

Tasks that differ only in one value, such as a service name, may be shown as one full entry plus a table of each task's id, title, and value, since approving that still covers every body.

Use the same 12-task threshold as the Epic body template below: Mermaid for 12 or fewer tasks, the wave table for more. This preview must render in the same form the Epic will actually use — never show a Mermaid graph here if Step 4 is going to render a table, or vice versa.

In any Mermaid node label, a double quote in a title must be written as `#quot;` — never a raw `"` or a backslash-escaped `\"` (backslash escaping breaks rendering).

```
## 作成する Issue の構成

### Epic（親 Issue）
**タイトル**: <Epic タイトル>
**サマリー**: <目的を1行で>
**背景**: <この Epic が必要になった経緯を1〜2文で>
**スコープ（含む）**: <bullet> / <bullet>
**スコープ（含まない）**: <該当する場合のみ。ソースが後回し・対象外・別 Epic とした項目と、会話で明示的に除外された項目。ソースから外した項目には「<項目> — ソース: 「<外す根拠となるソースの文言>」」の形でその文言を添える。どれもなければこの行ごと省略>
**目標状態**: <すべての子 Issue が完了したときに成り立つ状態を1行で>
**検証**: <Epic 全体の完了を確かめる方法。下の子 Issue の検証から組み立て、ソースが Epic 全体の確認として挙げた、人が行う確認を加えてよい>

（会話で挙げられたタスク数と子 Issue 数が一致しない場合のみ記載: **会話からの構成変更**: <どのタスクをどう分割/統合したか、その理由を1〜2文で>）

（該当する場合のみ記載: **Epic分割の提案**: 依存関係が互いに独立した複数グループに分かれており件数も多いため、1つのEpicではなく<提案するEpic分割案>として別Epicに分けることも検討できます。このまま1つのEpicとして進めますか？）

（Step 1.5 で統合済み設計ドキュメント/実装計画を変更した場合のみ記載: **ドキュメント未同期**: <文書名> は現在、確定済みの回答と同期していません。T<doc>（Wave 1 / 依存: なし）が文書を更新し、回答で内容が変わった各 Tn はそれに直接または推移的に依存します。どちらになるかは各 Tn の依存行に明記します。）

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
- 背景: <このタスクが必要な理由・Epic との関係を1行で>
- 要件: <bullet> / <bullet>
- 仕様: <bullet>（決定済み事項がなければ「なし」と書く）
- 理想状態: <完了時に成り立つべき状態を1行で>
- 検証: <bullet>、またはなし（その場合は pr-verify が判定するものがないと添える）
- 全項目: <文書のパスと節>（このタスクがポイント方式を使う場合のみ）

#### T2: <タイトル>（Wave 2 / 依存: T1）
- 背景: <1行>
- 要件: <bullet>
- 仕様: なし
- 理想状態: <1行>
- 検証: <bullet>

Step 1.5 で統合済み文書が変更され、この Tn の内容が変わった場合は、見出しの依存部分を単純な「依存: ...」ではなく「依存: T<doc>（直接）」または「依存: T<via>（T<doc> に推移的）」と完全な形で書く — サマリーでどちらになるかを承認する必要がある。

コンテナに昇格した Tn がある場合のみ、以下の形で示す。要件・仕様・検証方法は Tn.m 側にのみ書く。

#### T3: <タイトル>（コンテナ / Wave 1 / 依存: なし）
- 背景: <このテーマが独立したまとまりとして必要な理由を1行で>
- スコープ: <T3.1, T3.2 が含まれる、など>

##### T3.1: <タイトル>（Wave 1 / 依存: なし）
- 背景・要件・仕様・理想状態・検証方法は通常の子 Issue と同じ形式

##### T3.2: <タイトル>（Wave 2 / 依存: T3.1）
- 同上

人手が要る作業を Step 2 でタスクから切り出した場合のみ、子 Issue の後に人手 Issue を示す。Epic のタスクにも依存関係プレビューにも含めない。

### 人手 Issue（N 件）

#### P1: <タイトル>（待つ対象: T1, T2）
- 背景: <作業が必要な理由を1行で>
- やること: <ソースの文言による、人の手順を1行ずつ>

ソースにない追加案がある場合のみ、次の節と、末尾の「追加案は」で始まる行を書く。追加案がなければ、どちらも書かない。

### 追加案
以下は上の各 Tn に含めていない。
- A1: <追加したい要件・仕様・検証、または追加タスク> — 対象: <Tn または新規タスク> — 理由: <1行>

この構成・依存関係・要件仕様・検証方法ドラフトで本文生成に進んでよいですか？
追加案は、返信で「A1 を採用」のように名前を挙げたものだけを含めます。追加案を挙げない承認では、どの追加案も含めません。
「作成してください」と返信すると、このまま Step 4（本文生成）→ 作成まで直接進みます。作成前に Issue 本文の全文を確認したい場合は「ドラフトを見せて」と伝えてください。
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

## Container Tn body (Step 4)

Step 2 で `Tn` がコンテナに昇格した場合のみ使う。要件・仕様・受け入れ条件は持たず、Epic 本文と同じ形で自分の孫 `Tn.m` だけを扱う縮小版。孫が12件以下なら Mermaid、それを超えるなら表を使う — 実際にはまず起きないが、閾値は Epic と揃える。

```markdown
## 背景

{このテーマが独立したまとまりとして必要な理由 — 元の Tn のスコープとの関係を1〜2文で}

## スコープ

**含まれるもの:**
- {孫 Issue のタイトル一覧}

## 依存関係と実行計画

​```mermaid
flowchart LR
  subgraph Wave1[Wave 1: 並列着手可]
    T1_1["{{T1.1}} <タイトル>"]
  end
  subgraph Wave2[Wave 2: 並列着手可]
    T1_2["{{T1.2}} <タイトル>"]
  end
  T1_1 --> T1_2
​```
```

要件・仕様・検証方法セクションはここには書かない — それらは各 `Tn.m` 本文にのみ書く。依存図はこのコンテナ配下の孫だけを示し、他の `Tn` の孫とは混ぜない。

## Child Issue body (Step 4)

コンテナでない `Tn`（リーフ）と `Tn.m`（孫）の両方がこの形を使う。

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

{依存先は読者に見えない一時 ID `Tn` ではなく、タイトルで書く。`Tn` なら: "<タイトル> の完了後に着手可能。全体の依存関係は Epic を参照。" / `Tn.m` なら: "<タイトル> の完了後に着手可能。同じ親配下の依存関係は親 Issue を参照。" または "なし（並列着手可能）"。ステップ列挙や理由の詳細はここに書かない。Step 1.5 で統合済み文書が変更され、この Tn の内容が変わった場合は、代わりに文書更新タスクへの依存が直接か推移的かを明記する（直接: "文書更新タスク <文書更新のタイトル> の完了後に着手可能（直接依存）" / 推移的: "<タイトル> の完了後に着手可能。これは文書更新タスク <文書更新のタイトル> に依存する（推移的依存）"）。「全体の依存関係は Epic を参照」の一文は残す。}

## 受け入れ条件

### 理想状態
{What must be true when done — concrete and verifiable}

### 検証方法

- {Check an agent can run from a checkout or in CI: assert what, run which command}

{Up to 5 bullets. If it takes more than 5 to cover the real scenarios, that's a signal this Issue should be split — see Step 2 — unless an upstream authoritative document owns the full list: then keep 5 bullets chosen by failure mode rather than happy path, and add one prose line after the bullets (never a sixth bullet) pointing to that document as the authoritative full list. The pointer option is unavailable when no such document exists.}
```

## 人手 Issue 本文 (Step 4)

人、別のマシン、実機、または環境が要る作業用。Epic のサブ Issue にはせず、要件・仕様・受け入れ条件の節は持たない。

```markdown
## 背景

{この作業が必要な理由と、待つタスクをタイトルで — 1〜3文}

## やること

- {人の手順。ソースの文言で1行}
```

**Banned in every section above:** lettered step sequences (`a→b→c→d`), pseudocode, function signatures, multi-level nested bullets. If a task genuinely needs that much detail to specify, split it into more child Issues, or add a single line linking to an existing design doc — never restate the doc inline.

## Step 4.5: Body Review Format

Only used when the user explicitly asked to see the full draft (see Step 4.5 in SKILL.md). Show all Issue bodies in the following format and ask for approval:

```markdown
## Issue 本文レビュー

`{{Tn}}` と `{{Tn.m}}` は仮のプレースホルダーです。`{{Tn}}` は子 Issue 作成後に実際の Issue 番号（例: #123）へ置換されて Epic に反映され、`{{Tn.m}}` は孫 Issue 作成後にコンテナ化された Tn 本文へ同様に反映されます。

### Epic: <タイトル>

<Epic 本文全文（{{Tn}} プレースホルダーのまま）>

---

### 子 Issue T1: <タイトル>

<子 Issue T1 本文全文>

---

### 子 Issue T2: <タイトル>

<子 Issue T2 本文全文>

---

コンテナ化された Tn がある場合のみ、以下も示す。

### 子 Issue T3（コンテナ）: <タイトル>

<T3 本文全文（{{T3.m}} プレースホルダーのまま）>

### 孫 Issue T3.1: <タイトル>

<孫 Issue T3.1 本文全文>

---

人手 Issue がある場合のみ、以下も示す。

### 人手 Issue P1: <タイトル>

<人手 Issue P1 本文全文>

---

上記内容で Issue を作成します。Epic を先に作成し、Tn はその番号を親として順に作成し、コンテナ化された Tn がある場合はその番号を親として孫 Issue を作成し、人手 Issue がある場合は親なしで待つタスクの番号を blocked-by として作成するため、作成順は Epic → Tn → Tn.m → Pn になります。
修正があれば箇所を指定して教えてください。問題なければ「作成してください」と返信してください。
```

## Step 6: Completion Report

```
## 作成完了

### Epic
- #<number> <title>  (<URL>)
  Epic を先に作成しているため、Epic の番号は子 Issue より小さくなります。子 Issue は wave 順に続きます<。孫はすべての子 Issue の後に続きます — コンテナがある場合のみ。人手 Issue は最後です — ある場合のみ>。

### 子Issue
- #<number> <title>
- #<number> <title>（コンテナ）
  - #<number> <title>（孫）
  - #<number> <title>（孫）
...

（人手 Issue がある場合のみ:
### 人手 Issue
- #<number> <title> — 待つ対象 #<number>, #<number>（Epic のサブ Issue ではない）
...）

Epic と各Tn、コンテナ化されたTnと各孫Issueは `gh issue create --parent` による Sub-issue 関係で紐づけました。
依存関係は `--blocked-by` による Blocked-by/Blocking 関係として設定済みです — 孫同士の依存は同じ親Tn配下のみで、人手 Issue は待つタスクにブロックされます。
GitHub 上の Issue サイドバー（Sub-issues / Relationships）で確認できます。
Epic 本文の依存関係図（または表）とコンテナ化されたTn本文の依存関係図は、いずれも実際の Issue 番号で確定済みです。

（作成に失敗した Issue がある場合のみ:
### 作成失敗
- <タイトル>: <gh が出力したエラー>。本来これに依存する <Issue 番号> はこれにブロックされていません。親 #<Epic またはコンテナ>、blocked-by <自身の依存先の番号> で手動作成し、それらの Issue に blocked-by として追加し、Epic 本文の「(creation failed)」をその番号に置き換えてください。）

（文書更新 Tn への依存を推移的に配線した場合のみ: <Tn群> は文書更新 Tn に直接ブロックされておらず、<Tvia> を介して推移的に依存しています。この順序は意図的なものです。エッジの追加/削除で"修正"しないでください。）
```
