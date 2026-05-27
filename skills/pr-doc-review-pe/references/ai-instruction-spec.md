# AI Instruction Specification Checklist

## Purpose

AI が実行する仕様書・プロンプト・スキル定義など「AI 向け指示文書」に特有の観点を検査する。
SPDD (what/how 分離)・Golden Rule (コンテキスト不要テスト)・曖昧語検出・
Negative-only 指示の 4 軸で評価する。

## Checklist

**what/how 分離 — SPDD (Structured-Prompt-Driven Development)**

- **What (要件)** と **How (実装手順)** が混在していないか。
  - What: 「何を達成すべきか」の記述 (目的・受け入れ基準)。
  - How: 「どう実装するか」の記述 (具体的なステップ・コード例)。
- What のみを記述し How はモデルに委ねるべき箇所に、不要な How が混入していないか。

**Golden Rule (Context-Free Reader Test)**

- 文書を初めて見る AI (コンテキスト一切なし) が読んだとき、各指示を正確に実行できるか。
- 暗黙のドメイン知識・チーム慣習・過去会話を前提にした指示がないか。
- 指示の主語が明確か (誰が / どのツールが / どのエージェントが実行するか)。

**曖昧語の有無** (判断基準なしで使われていないか)

`適切に` / `必要に応じて` / `十分に` / `いい感じに` / `可能なら` / `考慮する`
`担保する` / `基本的に` — これらが判断基準・条件・数値なしで使われていれば指摘する。

**Negative-only 指示の positive-example 欠如**

- 「〜してはならない」だけの禁止指示に、正しい代替例が添えられているか。
- Negative-only 指示は AI が禁止の外延を推測する必要があり、解釈ブレを生む。
- 少なくとも 1 件の positive example が必要。

## Anti-patterns

- 1 文の中に What と How が混在する。
- 受け入れ基準と実装ステップが同じ箇条書きリストに混在する。
- 背景を知る人しか理解できない暗黙参照を含む指示。
- 「〜しないこと」だけで終わり、正しい代替例を示さない。

## Sources

- Martin Fowler — Structured-Prompt-Driven Development (2025)
  https://martinfowler.com/articles/2025-spec-driven-prompting.html
- Anthropic — Prompting Best Practices
  https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/overview
- arXiv:2504.20781 — Design Rationale auto-generation
  https://arxiv.org/abs/2504.20781
