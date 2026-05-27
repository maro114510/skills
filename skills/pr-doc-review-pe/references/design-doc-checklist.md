# Design Doc Checklist

## Purpose

Google Design Doc 形式に基づき、設計ドキュメントの骨格完全性を検査する。
Malte Ubl の 10 セクション構成を照合し、Non-Goals・代替案・スコープ定義の欠落を指摘する。

## Checklist

**Malte Ubl — Google Design Doc 10 セクション**

1. **Overview / TL;DR** — 1〜2 段落で問題と提案解決策を要約しているか。
2. **Background / Context** — 現状の課題・制約・過去の決定を説明しているか。
3. **Goals** — 何を達成するかが SMART (Specific / Measurable) で記述されているか。
4. **Non-Goals** — 今回の設計がカバーしないことが明示されているか。非明示は `[must]`。
5. **Proposed Solution** — 採択案の詳細・コンポーネント・フロー・データ構造が記述されているか。
6. **Alternatives Considered** — 検討した代替案と棄却理由が比較されているか。1 件も書かれていなければ `[must]`。
7. **Security Considerations** — 認証・認可・データ保護・規制遵守について記述されているか。
8. **Operational Considerations** — デプロイ・監視・ロールバック・障害対応が記述されているか。
9. **Open Questions** — 未解決事項が明示されているか (設計のブロッカーを識別する)。
10. **Milestones / Timeline** — 段階的な実装計画が示されているか。

## Anti-patterns

- Non-Goals が空欄、または「なし」のみ (後でスコープクリープを招く)。
- Alternatives に「検討せず」と書く (読者に代替案が存在しないと誤解させる)。
- Overview が目次になっており、問題と解決策のサマリーになっていない。
- Security / Operational Considerations が「別途検討」のみ。
- Open Questions がなく、設計が「完全」であるかのように見える。

## Sources

- Malte Ubl — Design Docs at Google (increment.com, 2020)
  https://www.industrialempathy.com/posts/design-docs-at-google/
- Google Engineering Practices — Writing Design Docs
  https://google.github.io/eng-practices/
- Squarespace — A Practical Guide to Design Documents (2022)
  https://engineering.squarespace.com/blog/2019/the-anatomy-of-a-software-design-doc
