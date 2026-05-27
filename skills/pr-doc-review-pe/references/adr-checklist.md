# ADR Checklist

## Purpose

Architecture Decision Records (ADR) の構造的完全性を検査する。
Nygard 5 構成要素と Olaf Zimmermann 7 質問を照合し、設計根拠の欠落・代替案未検討・Consequences-negative の欠如を指摘する。

## Checklist

**Nygard 5 構成要素** (Documenting Architecture Decisions, 2011)

1. **Context** — 決定を行った状況・制約・優先事項が記述されているか。
2. **Decision** — 採択した設計選択が明確か。
3. **Status** — Proposed / Accepted / Deprecated / Superseded のいずれかが明示されているか。
4. **Consequences** — 正と負の両側が記述されているか。Consequences-negative の欠如は `[must]`。
5. **Alternatives** — 検討した代替案とその棄却理由が記述されているか。

**Olaf Zimmermann ADR レビュー 7 質問** (ozimmer.ch, 2023)

1. 決定の対象 (what) が明確か？
2. なぜこの決定が必要か (why)？
3. 採択の根拠 (justification) が示されているか？
4. 代替案とトレードオフが比較されているか？
5. ステークホルダーが識別されているか？
6. Consequences (positive / negative / risks) が記述されているか？
7. レビュー・改訂の基準が明示されているか？

**逆生成代替案チェック**

- 文書から 3 件の「書かれていない代替案」を逆生成し、採択案がそれらより優れている根拠が文書内にあるかを確認する。
- 根拠がない代替案があれば `[ask]` または `[must]` として指摘する。

## Anti-patterns

- Consequences に正の側しか記述されていない (trade-off 回避)。
- Alternatives 欄に「検討済み: なし」と書いてある (棄却理由なし)。
- Context が「～を実装するため」だけで制約・優先事項を欠く。
- Status 欄がなく、採択済みか提案中か分からない。
- 逆生成代替案への反論がドキュメントから読み取れない。

## Sources

- Nygard — Documenting Architecture Decisions (cognitect.com, 2011)
  https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions
- Zimmermann — How to review ADRs and how not to (ozimmer.ch, 2023)
  https://ozimmer.ch/practices/2023/04/03/ADRReviewHowTo.html
- Thoughtworks — Architecture Decision Records
  https://www.thoughtworks.com/radar/techniques/architecture-decision-records
