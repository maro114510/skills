# Layer-3: AI-Instruction Document Review Checklist

AI が実行する仕様書・プロンプト・スキル定義など「AI 向け指示文書」に特有の観点。
このチェックリストは、対象ドキュメントが AI 向けと判定された場合にのみ適用する。

---

## AI 仕様判定基準 (参考)

以下のいずれかを満たす場合は AI 向けと判定する:
- ファイルパスに `CLAUDE.md` / `SKILL.md` / `*prompt*` / `*spec*` が含まれる。
- 内容に「あなたは」「AI は」「モデルは」「Claude」「LLM」など AI 宛ての指示語が含まれる。
- § Ambiguity Vocabulary Detection に掲載の曖昧語を 3 件以上含む。

---

## § what/how 分離 — What / How Separation (SPDD: Structured-Prompt-Driven Development)

> Martin Fowler — Structured-Prompt-Driven Development (2025)

- **What (要件)** と **How (実装手順)** が混在していないか。
  - What: 「何を達成すべきか」の記述 (目的・受け入れ基準)。
  - How: 「どう実装するか」の記述 (具体的なステップ・コード例)。
- What のみを記述し How はモデルに委ねる箇所に、不要な How が混入していないか。
- 逆に、具体的な手順指示 (How) が必要な箇所に What だけが書かれていないか。

**Anti-patterns**
- 1 文の中に「〜を実現する (What) ために、〜という方法で実装する (How)」が混在する。
- 受け入れ基準と実装ステップが同じ箇条書きリストに混在する。

---

## § Golden Rule (Context-Free Reader Test)

> Anthropic Prompting Best Practices

- 文書を初めて見る AI (コンテキスト一切なし) が読んだとき、各指示を正確に実行できるか。
- 暗黙のドメイン知識・チーム慣習・過去会話を前提にした指示がないか。
- 指示の主語が明確か (誰が / どのツールが / どのエージェントが実行するか)。

**確認手順**
1. 文書の各指示文を取り出す。
2. そのツールやエージェントが初期状態でその指示を受け取ったとき、何が分からないかを列挙する。
3. 分からない点が 1 件でもあれば、コンテキスト不足として指摘する。

---

## § Ambiguity Vocabulary Detection

以下の曖昧語が **判断基準なしで** 使われていないかを検出する:

| 語 | 問題点 | 改善例 |
|---|--------|--------|
| 適切に | 「適切」の基準が不明 | 「〜の場合は A、〜の場合は B」と条件化 |
| 適切な | 「適切」の判断基準が不明 | 「〜の条件を満たす」と明示する |
| 必要に応じて | いつ「必要」かが不明 | 「〜のとき実行する」と条件化 |
| 十分に | 「十分」の閾値が不明 | 「N 件以上」など数値化 |
| いい感じに | 評価基準が完全に不明 | 受け入れ基準を明示する |
| だいたい | 許容範囲が不明 | 「±X%」など数値化 |
| 可能なら | 実行条件が不明 | 「〜の場合は行う、そうでなければスキップする」 |
| 考慮する | 何を・どう考慮するかが不明 | 「〜を確認し、〜の場合は X を行う」と手順化 |
| 担保する | 「担保」の手段・基準が不明 | 「〜を検証することで確認する」と手段を明示 |
| 基本的に | 例外条件が不明 | 「〜の場合を除き、常に X とする」と例外を明示 |

**判定基準**: 上記語が文書中に出現し、かつ同文または直後の文に具体的な条件・閾値・例外条件がない場合は指摘候補とする。

---

## § Negative-Only Instruction → Positive-Example Coverage

- 「〜してはならない」「〜を避ける」だけの禁止指示に、正しい代替例が添えられているか。
- Negative-only 指示は AI が禁止の外延 (何が許容されるか) を推測する必要があり、解釈ブレを生む。
- 少なくとも 1 件の positive example (こうする / こう書く) が必要。

**Anti-patterns**
- 「不適切な言葉を使わないこと」→ 何が不適切かの基準も例も示されていない。
- 「冗長な出力をしない」→ 「冗長」の定義がなく、ポジティブな出力例もない。
- 複数の禁止事項が並ぶが、全て Negative-only。

---

## § AI 仕様特有の Risk Register エントリー

AI 向け仕様書では、以下のリスクを Risk Register に含めることを推奨する:

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| 曖昧語によるモデル解釈ブレ | High | High | 曖昧語を条件・例に置換 |
| コンテキスト依存指示による誤動作 | Med | High | Golden Rule チェックで確認 |
| Negative-only 指示の過剰適用 | Med | Med | Positive example を追加 |
| What/How 混在による指示抜け・二重実装 | Med | Med | SPDD に従って分離 |

---

## Sources

- Martin Fowler — Structured-Prompt-Driven Development (2025) / SPDD
- Thoughtworks — Spec-Driven Development (2025)
- Anthropic — Prompting Best Practices (docs.anthropic.com)
- arXiv:2504.20781 — Design Rationale auto-generation
