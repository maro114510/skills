# Document Meta-Information Checklist

## Purpose

設計ドキュメント全種別 (ADR / RFC / Design Doc / 実装計画) に共通する
メタ情報 — 想定読者・Non-Goals・Definition of Done・ドキュメント種別 — の
完全性を検査する。
メタ情報の欠落はレビューコストの増加とスコープクリープを招く。

## Checklist

1. **Audience (想定読者)**
   - 「誰が読むか」が明示されているか (エンジニア / PM / SRE / 全員 など)。
   - 想定読者の前提知識レベルが推測可能か。

2. **Non-Goals (スコープ外)**
   - 今回の設計・変更がカバーしないことが箇条書きで列挙されているか。
   - 「〜は今回対応しない」という形で明示されているか。
   - 最低 1 件の Non-Goal が記述されていなければ `[must]`。

3. **Document Type (ドキュメント種別)**
   - ADR / RFC / Design Doc / 実装計画 / AI 仕様 のいずれかが明示されているか。
   - 種別が不明だと適切なレビュー観点を選べない。

4. **Definition of Done (DoD)**
   - 「この設計が完了した状態」を客観的に判定できる基準が記述されているか。
   - DoD が「レビュー完了」のみの場合は具体的な完了条件を追記するよう指摘する。

## Anti-patterns

- 「全員が知っているはずの前提」を無修飾で使う (暗黙の想定読者)。
- Non-Goals なし → スコープクリープを招く。
- Definition of Done が「実装完了」のみで検証可能な条件を欠く。
- ドキュメント種別の混在 (ADR と Design Doc のセクションが混在) で
  どのテンプレートが適用されるか不明。

## Sources

- RFC 2119 — Key words for use in RFCs to indicate requirement levels
  https://www.rfc-editor.org/rfc/rfc2119
- IEEE 830 — Recommended Practice for Software Requirements Specifications
  https://ieeexplore.ieee.org/document/720574
- Malte Ubl — Design Docs at Google (Non-Goals section)
  https://www.industrialempathy.com/posts/design-docs-at-google/
